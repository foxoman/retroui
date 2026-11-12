## Retro DNS -- change the DNS server of your phone or computer in one tap:
## 47 public resolvers (fast, private, secure, ad-blocking, family,
## unfiltered, regional), what each is good for, speed tests, and servers of
## your own.
##
## On Android it switches with a VPN that stays on the phone and carries DNS
## only, encrypted (DNS over HTTPS or TLS): retrodns/glue/java's DnsVpn, in a
## small process of its own, which retroapk puts in the APK or bundle
## (--java:examples/retrodns/glue) -- how an app brings Java of its own, a
## service or a receiver. On Windows, Linux and macOS it gives the computer
## the server's addresses as its administrator (retroui/admin), and on
## macOS and iOS a profile of encrypted DNS (retrodns/desktop.nim).
##
##   nim c -r -d:release examples/retrodns.nim           (Windows, macOS, Linux)
##   sh examples/retrodns/build.sh apk                   (Android, VPN included)
##   sh examples/retrodns/build.sh aab                   (Google Play)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net

import std/[strutils, sequtils, tables, os, algorithm, times]
import retroui
import retroui/[parallel, admin]
import retrodns/[catalog, androidglue, tester, vpn, desktop]

const
  retrodnsVersion {.strdefine.} = "1.1"   # (build.sh passes its VERSION)
  AppTitle = "Retro DNS"
  AppVersion = retrodnsVersion
  AppId = "RetroDNS"
  AppIconPng = staticRead("retrodns/icon.png")
  Chips = ["All", "Favourites", "Fast", "Privacy", "Security", "Ad-block", "Family",
           "Unfiltered", "Regional", "Mine"]

let
  cTeal = color(0, 96, 96)
  cNavy = color(0, 0, 128)
  cGrey = color(80, 80, 80)
  cGreen = color(0, 120, 0)
  cMaroon = color(128, 0, 0)

# ---- the app's state -----------------------------------------------------------------------------

var
  servers: seq[Server]
  timings: Table[string, int]           # key -> the last test's ms (-1 failed)
  testing: Table[string, bool]          # keys being tested now
  favs: seq[string]
  query = ""
  chip = 0
  selKey = ""
  listSel = 0                           # (controls are known by their variable's
                                        # address: these stay globals)
  sortBySpeed = false
  paneW = 470
  paneH = 360
  stateDirty = false
  lastSave = 0.0
  fastestAsked = false
  # the VPN
  vpnNow: VpnStatus
  vpnAsking = false                     # Android's consent dialog is up
  vpnKey = ""                           # the server the VPN was started for
  lastAsk = 0.0
  disclosed = false                     # the VPN notice was accepted once
  discloseOpen = false
  discloseAgreed = false
  pendingVpnKey = ""
  lastRead = 0.0
  wasPaused = false
  # this computer (or iPhone, iPad): the server Retro DNS gave it
  hereKey = ""                          # "" its network's own
  hereProfile = false                   # given with a profile (macOS, iOS)
  adminAsk = ""                         # "use" or "reset" while the system asks
  adminKey = ""
  adminCmd: (string, seq[string])
  # dialogs
  ipOpen = false
  ipKey = ""
  editOpen = false
  editKey = ""                          # "" for a new one
  eName, eDot, eDoh, eV4, eV6, eNote, editMsg: string
  eGroup = Groups.len - 1
  deleteOpen = false
  importOpen = false
  importText = ""
  helpOpen = false
  lookOpen = false
  aboutOpen = false
  failOpen = false
  failMsg = ""

proc appDir(): string = dataDir(AppId)
proc customPath(): string = appDir() / "servers.csv"
proc errorPath(): string = appDir() / "last-error.txt"
  ## (where the script run as the administrator says why it failed: Windows)

proc indexOfKey(key: string): int =
  for i, s in servers:
    if s.key == key: return i
  -1

proc speedOf(key: string): int =
  ## The last test's ms; -1 failed, int.high not tested.
  timings.getOrDefault(key, int.high)

proc speedText(key: string): string =
  if key in testing: return "..."
  let v = speedOf(key)
  if v == int.high: "-"
  elif v < 0: "fail"
  else: $v

proc saveState() =
  var s = loadSettings(AppId)
  s["favourites"] = favs.join(",")
  s["chip"] = $chip
  s["selected"] = selKey
  s["sortBySpeed"] = $sortBySpeed
  s["paneW"] = $paneW
  s["paneH"] = $paneH
  s["vpnNotice"] = $disclosed
  s["hereServer"] = hereKey
  s["hereProfile"] = $hereProfile
  discard saveSettings(AppId, s)
  stateDirty = false
  lastSave = epochTime()

proc loadState() =
  let s = loadSettings(AppId)
  favs = s.getOrDefault("favourites").split(',').filterIt(it.len > 0)
  try: chip = clamp(parseInt(s.getOrDefault("chip", "0")), 0, Chips.high)
  except ValueError: discard
  selKey = s.getOrDefault("selected")
  sortBySpeed = s.getOrDefault("sortBySpeed") == "true"
  try: paneW = parseInt(s.getOrDefault("paneW", "470"))
  except ValueError: discard
  try: paneH = parseInt(s.getOrDefault("paneH", "360"))
  except ValueError: discard
  disclosed = s.getOrDefault("vpnNotice") == "true"
  hereKey = s.getOrDefault("hereServer")
  hereProfile = s.getOrDefault("hereProfile") == "true"

proc saveCustomServers() =
  if not saveCustom(customPath(), servers.filterIt(it.custom)):
    failMsg = "Your servers could not be saved in " & customPath() & "."
    failOpen = true

proc readNow() =
  ## How the VPN is doing (every few seconds, and on coming back).
  if not onAndroid(): return
  vpnNow = vpnStatus()
  lastRead = epochTime()

# ---- the list ------------------------------------------------------------------------------------

proc matches(s: Server): bool =
  case Chips[chip]
  of "All": discard
  of "Favourites":
    if s.key notin favs: return false
  of "Mine":
    if not s.custom: return false
  else:
    if s.group != Chips[chip]: return false
  if query.len > 0:
    let hay = (s.name & " " & s.group & " " & s.note & " " & s.dot & " " & s.doh & " " &
               s.ipv4.join(" ") & " " & s.ipv6.join(" ")).toLowerAscii
    for word in query.toLowerAscii.splitWhitespace:
      if word notin hay: return false
  true

proc speedRank(key: string): int =
  let v = speedOf(key)
  if v < 0: int.high - 1 else: v

proc shownServers(): seq[int] =
  for i, s in servers:
    if matches(s): result.add i
  if sortBySpeed:
    result.sort(proc (a, b: int): int =
      cmp(speedRank(servers[a].key), speedRank(servers[b].key)))

proc testServer(s: Server) =
  if s.key in testing: return
  testing[s.key] = true
  # (where the VPN would send lookups; plain-only servers: their port 53)
  let (host, port) = if s.doh.len > 0: (urlHost(s.doh), 443)
                     elif s.dot.len > 0: (s.dot, 853)
                     elif s.ipv4.len + s.ipv6.len > 0: ((s.ipv4 & s.ipv6)[0], 53)
                     else: ("", 0)
  submitTest(TestJob(key: s.key, host: host, port: port))

proc testAll(list: seq[int]) =
  for i in list: testServer(servers[i])

proc toggleFav(key: string) =
  let at = favs.find(key)
  if at >= 0: favs.delete(at) else: favs.add key
  stateDirty = true

proc pickFastest() =
  var best = -1
  var bestMs = int.high
  for i in shownServers():
    let v = speedOf(servers[i].key)
    if v >= 0 and v < bestMs:
      best = i
      bestMs = v
  if best >= 0:
    selKey = servers[best].key
    stateDirty = true
    toast("Fastest from here: " & servers[best].name & ", " & $bestMs & " ms")
  else:
    toast("No server answered. Is the network on?")

proc handleResults() =
  for d in finishedTests():
    testing.del d.key
    timings[d.key] = d.ms
  if fastestAsked and testing.len == 0:
    fastestAsked = false
    pickFastest()

# ---- switching with the VPN --------------------------------------------------------------------

proc vpnServes(s: Server): bool =
  ## The VPN is on and sends lookups to `s`.
  vpnNow.state == vsOn and vpnNow.server == s.name

proc vpnStart(key: string) =
  ## Connects the VPN to `key`'s server (or moves it there): the notice
  ## first, the first time; then Android's consent dialog, the first time.
  let i = indexOfKey(key)
  if i < 0: return
  let s = servers[i]
  if not vpnReady(s):
    failMsg = s.name & " has no encrypted DNS (DNS over HTTPS or TLS), which the VPN " &
              "sends lookups with. Use it on Wi-Fi or a router instead: Use on Wi-Fi " &
              "in its details shows how."
    failOpen = true
    return
  if not onAndroid():
    toast("The VPN runs in the Android app; here you can browse and test.")
    return
  if not vpnNow.present:
    failMsg = "This build has no VPN in it. Build it with sh build.sh, which gives " &
              "retroapk the VPN's Java (--java:glue)."
    failOpen = true
    return
  if not disclosed:
    pendingVpnKey = key
    discloseAgreed = false
    discloseOpen = true
    return
  vpnKey = key
  let r = vpnConnect(vpnConfig(s))
  if r == "asking":
    vpnAsking = true
    lastAsk = epochTime()
  elif r.startsWith("error"):
    failMsg = "The VPN could not start: " & r.split('\t', 1)[^1]
    failOpen = true
  else:
    toast("VPN: " & s.name)
  vpnNow = vpnStatus()

proc vpnStop() =
  vpnDisconnect()
  vpnAsking = false
  vpnKey = ""
  vpnNow = vpnStatus()
  toast("VPN off: your network's own DNS again")

proc vpnWatch() =
  ## While Android's consent dialog is up: once allowed, connect.
  if not vpnAsking or epochTime() - lastAsk < 0.5: return
  lastAsk = epochTime()
  if vpnAllowed():
    vpnAsking = false
    vpnStart(vpnKey)

# ---- this computer: its own DNS (retroui/admin), or a profile -------------------------------------

proc deviceWord(): string =
  when defined(ios): "device" else: "computer"

proc useHere(key: string) =
  ## Gives this device `key`'s server: Android's VPN, a computer's own DNS
  ## (the system asks for its administrator), or a profile on macOS and iOS.
  let i = indexOfKey(key)
  if i < 0 or adminAsk.len > 0: return
  let s = servers[i]
  case hereWay(s)
  of hwVpn: vpnStart(key)
  of hwSystem:
    try: removeFile(errorPath()) except OSError: discard
    adminCmd = adminCommand(useScript(s, errorPath()))
    adminKey = key
    adminAsk = "use"
  of hwProfile:
    let path = profilePath(appDir(), s)
    try: writeFile(path, mobileConfig(s))
    except IOError:
      failMsg = "The profile could not be written in " & path & "."
      failOpen = true
      return
    hereKey = key
    hereProfile = true
    stateDirty = true
    when defined(ios):
      if not shareFile(path): toast("Saved: " & path)
      else: toast("Save it to Files and open it there; then Settings, Profile Downloaded")
    else:
      openFile(path)
      toast("System Settings shows the profile: install it there (Profiles)")
  of hwNone:
    when defined(wasm) or defined(js):
      failMsg = "In a web page Retro DNS can only show the servers and what they are good for."
    elif defined(ios):
      failMsg = s.name & " has no encrypted DNS, which a profile needs. Use it on Wi-Fi " &
                "instead: Use on Wi-Fi shows how."
    else:
      failMsg = if not canRunAsAdmin():
                  "Changing this computer's DNS needs its administrator, and there is no " &
                    "way to ask for one here (pkexec, polkit's)."
                else: s.name & " has no address a computer's DNS setting takes."
    failOpen = true

proc resetHere() =
  ## This device's network's own DNS again.
  if adminAsk.len > 0: return
  if hereProfile:
    when defined(ios):
      toast("Settings, General, VPN & Device Management: remove Retro DNS's profile")
    else:
      openUrl("x-apple.systempreferences:com.apple.Profiles-Settings.extension")
      toast("Remove Retro DNS's profile there")
    hereKey = ""
    hereProfile = false
    stateDirty = true
  else:
    try: removeFile(errorPath()) except OSError: discard
    adminCmd = adminCommand(resetScript(errorPath()))
    adminAsk = "reset"

proc adminWatch() =
  ## While the system asks for its administrator, and the script runs.
  if adminAsk.len == 0: return
  let r = runAsAdmin(adminAsk, adminCmd[0], adminCmd[1],
                     why = "Retro DNS changes the DNS server this computer uses.")
  if r.state == adWaiting: return
  let asked = adminAsk
  adminAsk = ""
  case r.state
  of adDone:
    if r.code == 0:
      if asked == "use":
        hereKey = adminKey
        hereProfile = false
        let i = indexOfKey(adminKey)
        toast("This " & deviceWord() & " asks " & (if i >= 0: servers[i].name else: "it") & " now")
      else:
        hereKey = ""
        toast("Back to the network's own DNS")
      stateDirty = true
    else:
      var why = try: readFile(errorPath()).strip except IOError: ""
      if why.len == 0: why = r.output
      failMsg = "The DNS servers were not changed" &
                (if why.len > 0: ": " & why else: " (" & $r.code & ").")
      failOpen = true
  of adRefused: toast("Not changed: the administrator was not given")
  else:
    failMsg = "The DNS servers were not changed: " & r.output
    failOpen = true

# ---- your own servers ----------------------------------------------------------------------------

proc startEdit(key: string) =
  editKey = key
  editMsg = ""
  let i = indexOfKey(key)
  if i >= 0:
    let s = servers[i]
    eName = s.name
    eDot = s.dot
    eDoh = s.doh
    eV4 = s.ipv4.join(" ")
    eV6 = s.ipv6.join(" ")
    eNote = s.note
    eGroup = max(0, Groups.find(s.group))
  else:
    eName = ""
    eDot = ""
    eDoh = ""
    eV4 = ""
    eV6 = ""
    eNote = ""
    eGroup = Groups.len - 1
  editOpen = true

proc cleanHost(s: string): string =
  result = s.strip.toLowerAscii
  if result.startsWith("tls://"): result = result[6 .. ^1]
  if result.endsWith(":853"): result = result[0 ..< result.len - 4]
  result = result.strip(chars = {'/'})

proc saveEdit() =
  let name = eName.strip
  let dot = cleanHost(eDot)
  let doh = eDoh.strip
  let v4 = splitAddrs(eV4)
  let v6 = splitAddrs(eV6)
  if name.len == 0:
    editMsg = "Give it a name."
    return
  if dot.len + doh.len + v4.len + v6.len == 0:
    editMsg = "Fill at least one address."
    return
  if dot.len > 0 and not goodHost(dot):
    editMsg = "The DNS-over-TLS host is a name like dns.example.com (no https://)."
    return
  if doh.len > 0 and not goodDohUrl(doh):
    editMsg = "The DoH address is an https:// address, like https://dns.example.com/dns-query"
    return
  for a in v4:
    if not goodIpv4(a):
      editMsg = a & " is not an IPv4 address."
      return
  for a in v6:
    if not goodIpv6(a):
      editMsg = a & " is not an IPv6 address."
      return
  let s = Server(key: customKey(name, dot), name: name, group: Groups[eGroup],
                 dot: dot, doh: doh, ipv4: v4, ipv6: v6, note: eNote.strip,
                 plain: true, custom: true)
  let old = indexOfKey(editKey)
  let clash = indexOfKey(s.key)
  if clash >= 0 and clash != old:
    editMsg = "There is a server with this name and host already."
    return
  if old >= 0:
    let fav = favs.find(editKey)
    if fav >= 0: favs[fav] = s.key
    servers[old] = s
  else:
    servers.add s
  selKey = s.key
  stateDirty = true
  saveCustomServers()
  editOpen = false

proc deleteSelected() =
  let i = indexOfKey(selKey)
  if i < 0 or not servers[i].custom: return
  let at = favs.find(selKey)
  if at >= 0: favs.delete(at)
  servers.delete(i)
  selKey = ""
  stateDirty = true
  saveCustomServers()

proc exportServers() =
  let mine = servers.filterIt(it.custom)
  if mine.len == 0:
    toast("Add a server of your own first (Server, Add).")
    return
  let path = appDir() / "RetroDNS-servers.csv"
  if not writeCsv(path, serversTable(mine)):
    failMsg = "Could not write " & path & "."
    failOpen = true
    return
  putClipboardText(toCsv(serversTable(mine)))
  if not shareFile(path):
    toast("Copied, and saved to " & path)

proc importServers(): int =
  for s in fromTable(parseCsv(importText)):
    if indexOfKey(s.key) < 0:
      servers.add s
      inc result
  if result > 0:
    stateDirty = true
    saveCustomServers()

# ---- what is on the screen -----------------------------------------------------------------------

proc menus(current: int) =
  let hasSel = current >= 0
  let mine = hasSel and servers[current].custom
  let isFav = hasSel and servers[current].key in favs
  menubar:
    menu "&File":
      if menuItem("&Import servers..."): importOpen = true
      if menuItem("&Export your servers"): exportServers()
      menuSeparator()
      if menuItem("E&xit"): quitApp()
    menu "&Server":
      if onAndroid():
        if menuItem("&Connect the VPN", enabled = hasSel and not vpnAsking):
          vpnStart(servers[current].key)
        if menuItem("&Disconnect the VPN", enabled = vpnNow.state in {vsOn, vsStarting}):
          vpnStop()
      else:
        if menuItem("&Use on This " & deviceWord().capitalizeAscii,
                    enabled = hasSel and adminAsk.len == 0 and hereWay(servers[current]) != hwNone):
          useHere(servers[current].key)
        if menuItem("&Back to Automatic", enabled = hereKey.len > 0 and adminAsk.len == 0):
          resetHere()
      if menuItem("&Favourite", checked = isFav, enabled = hasSel):
        toggleFav(servers[current].key)
      menuSeparator()
      if menuItem("&Add...", "Ctrl+N"): startEdit("")
      if menuItem("&Edit...", enabled = mine): startEdit(servers[current].key)
      if menuItem("&Delete...", enabled = mine): deleteOpen = true
    menu "&Test":
      if menuItem("Test &this server", enabled = hasSel): testServer(servers[current])
      if menuItem("Test &all shown", "Ctrl+T"): testAll(shownServers())
      if menuItem("Find the &fastest"):
        testAll(shownServers())
        fastestAsked = true
      menuSeparator()
      if menuItem("&Sort by speed", checked = sortBySpeed):
        sortBySpeed = not sortBySpeed
        stateDirty = true
    menu "&View":
      if menuItem("&Appearance..."): lookOpen = true
      if onAndroid() and menuItem("Android's &VPN settings"):
        openSettingsPage("android.settings.VPN_SETTINGS")
    menu "&Help":
      if menuItem("&How it works..."): helpOpen = true
      menuSeparator()
      if menuItem("&About Retro DNS..."): aboutOpen = true
  if hotkeyPressed("Ctrl+N"): startEdit("")
  if hotkeyPressed("Ctrl+T"): testAll(shownServers())

proc tools() =
  toolbar:
    if toolButton(pxGauge, "Test all shown", size = 1.3): testAll(shownServers())
    if toolButton(pxStar, "Find the fastest", size = 1.3):
      testAll(shownServers())
      fastestAsked = true
    toolSeparator()
    if toolButton(pxAdd, "Add a server", size = 1.3): startEdit("")
    if toolButton(pxPaste, "Import servers", size = 1.3): importOpen = true
    if toolButton(pxShare, "Export your servers", size = 1.3): exportServers()
    toolSeparator()
    if toolButton(pxHelp, "How it works", size = 1.3): helpOpen = true

proc vpnLine(): string =
  case vpnNow.state
  of vsOn: "VPN on: " & vpnNow.server & ", " & vpnNow.mode
  of vsStarting: "Starting the VPN..."
  of vsFailed: "The VPN stopped"
  of vsOff: "VPN off: this network's own DNS"

proc lookupLine(): string =
  result = "Lookups: " & $vpnNow.answered
  if vpnNow.avgMs >= 0: result &= ", " & $vpnNow.avgMs & " ms on average"
  if vpnNow.failed > 0: result &= ", " & $vpnNow.failed & " failed"

proc vpnPart() =
  if not vpnNow.present:
    paragraph("This build has no VPN in it: build it with sh build.sh, whose " &
              "--java gives retroapk the VPN.")
    return
  let on = vpnNow.state == vsOn
  row:
    led(on, "")
    label(vpnLine(), bold = true)
  if on: label(lookupLine())
  if on and vpnNow.memKb > 0:
    label("The VPN's own process: " & $((vpnNow.memKb + 512) div 1024) & " MB of memory")
  if vpnNow.state == vsFailed and vpnNow.error.len > 0: label(vpnNow.error, color = cMaroon)
  if vpnAsking:
    row:
      spinner()
      label("Waiting for Android's permission...")
      if button("Cancel"): vpnAsking = false
  else:
    let i = indexOfKey(selKey)
    let picked = if i >= 0: servers[i].name else: ""
    let connectText = if on and picked.len > 0 and picked != vpnNow.server: "&Switch to " & picked
                      elif on: "Connected"
                      else: "&Connect"
    row:
      if button(connectText, isDefault = true,
                enabled = i >= 0 and not (on and picked == vpnNow.server)):
        vpnStart(selKey)
      if on or vpnNow.state == vsStarting:
        if button("&Disconnect"): vpnStop()

proc herePart() =
  ## This computer's DNS (or an iPhone's, an iPad's), and Use and Back.
  when defined(wasm) or defined(js):
    paragraph("In a web page Retro DNS shows and tests nothing: its apps for Windows, " &
              "macOS, Linux, Android and iOS change the DNS.")
  else:
    let at = indexOfKey(hereKey)
    row:
      led(at >= 0, "")
      label("This " & deviceWord() & ": " &
            (if at >= 0: servers[at].name else: "its network's own DNS"), bold = true)
    if at >= 0 and hereProfile:
      label("Its profile sends the lookups there, encrypted.")
    if adminAsk.len > 0:
      row:
        spinner()
        label("Waiting for the system...")
      return
    let i = indexOfKey(selKey)
    let way = if i >= 0: hereWay(servers[i]) else: hwNone
    let useText = if way == hwProfile: "&Install Profile" else: "&Use on This " &
                                                                 deviceWord().capitalizeAscii
    row:
      if button(useText, isDefault = true,
                enabled = i >= 0 and way != hwNone and servers[i].key != hereKey):
        useHere(selKey)
      if at >= 0 and button("&Back to Automatic"): resetHere()

proc connection() =
  group "DNS":
    if onAndroid(): vpnPart()
    else: herePart()

proc filterBar() =
  discard searchBox(query, "Search servers")
  var picked: array[Chips.len, bool]
  picked[chip] = true
  let ev = chips(Chips, picked)
  if ev.clicked >= 0 and ev.clicked != chip:
    chip = ev.clicked
    stateDirty = true

proc serverList(list: seq[int]; rows: int) =
  if list.len == 0:
    let h = if rows < 0: -1 else: 160
    emptyState(pxSearch, "No server matches", h = h,
               detail = "Clear the search, or pick All.")
    return
  var items: seq[string]
  for i in list:
    let s = servers[i]
    let mark = if s.key in favs: "* " else: ""
    let inUse = if vpnServes(s): " (in use)" else: ""
    items.add mark & s.name & inUse & "\t" & s.group & "\t" & speedText(s.key)
  listSel = 0
  var found = false
  for n, i in list:
    if servers[i].key == selKey:
      listSel = n
      found = true
  if not found: selKey = servers[list[0]].key
  let tabs = if isCompact(): @[205, 300] else: @[300, 410]
  if listbox(items, listSel, rows = rows, tabs = tabs):
    selKey = servers[list[listSel]].key
    stateDirty = true

proc timingText(key: string): string =
  if key in testing: return "testing..."
  let v = speedOf(key)
  if v == int.high: "not tested yet: tap Test"
  elif v < 0: "did not answer from here"
  else: $v & " ms to reach"

proc details(i: int) =
  if i < 0:
    emptyState(pxGlobe, "Pick a server",
               detail = "Its addresses, what it is good for, and Connect.")
    return
  let s = servers[i]
  let way = hereWay(s)
  let inUse = vpnServes(s) or (not onAndroid() and s.key == hereKey)
  heading(s.name, 2)
  row:
    pill(s.group, cNavy)
    if inUse: pill("In use", cGreen)
    if s.dot.len > 0: pill("Private DNS", cTeal)
    if s.doh.len > 0: pill("DoH", cTeal)
    if s.ipv6.len > 0: pill("IPv6", cGrey)
    if not s.plain: pill("Encrypted only", cMaroon)
    if s.custom: pill("Yours", cGrey)
  if s.note.len > 0: paragraph(s.note)
  var facts: seq[(string, string)]
  if s.dot.len > 0: facts.add ("Private DNS", s.dot)
  if s.doh.len > 0: facts.add ("DoH", s.doh)
  if s.ipv4.len > 0: facts.add ("IPv4", s.ipv4.join(", "))
  if s.ipv6.len > 0: facts.add ("IPv6", s.ipv6.join(", "))
  facts.add ("Speed", timingText(s.key))
  factList(facts)
  space(6)
  let wifiOnly = (way == hwVpn and not vpnReady(s)) or
                 (way == hwNone and defined(ios) and addrsOf(s).len > 0)
  if wifiOnly: label("No encrypted DNS, so not for the " &
                     (if way == hwVpn: "VPN" else: "profile") & ": use it on Wi-Fi or a router.")
  row:
    if wifiOnly:
      if button("Use on &Wi-Fi...", isDefault = true):
        ipKey = s.key
        ipOpen = true
    else:
      let useLabel = if inUse: (if way == hwVpn: "Connected" else: "In Use")
                     elif way == hwVpn: "&Connect"
                     elif way == hwProfile: "&Install Profile"
                     else: "&Use Here"
      if button(useLabel, isDefault = not inUse,
                enabled = not inUse and not vpnAsking and adminAsk.len == 0 and way != hwNone):
        useHere(s.key)
    if button("&Test", enabled = s.key notin testing): testServer(s)
    let favLabel = if s.key in favs: "Un&favourite" else: "&Favourite"
    if button(favLabel): toggleFav(s.key)
  row:
    if s.dot.len > 0 and button("Copy &host"):
      putClipboardText(s.dot)
      toast("Copied: Android's Settings, Private DNS takes it too")
    if s.doh.len > 0 and button("Copy &DoH"):
      putClipboardText(s.doh)
      toast("Copied: paste it in your browser's secure DNS setting")
    if s.ipv4.len + s.ipv6.len > 0 and button("Copy &addresses"):
      putClipboardText((s.ipv4 & s.ipv6).join(", "))
      toast("Copied the addresses")
  if s.custom:
    row:
      if button("&Edit..."): startEdit(s.key)
      if button("De&lete..."): deleteOpen = true

proc dialogs() =
  # the VPN notice, before Android's own dialog (Google Play asks for it)
  dialog(discloseOpen, "About the VPN Connection", 460):
    paragraph("Retro DNS uses Android's VPN service to change the DNS server your " &
              "phone uses.")
    paragraph("The VPN stays on this device. It carries only DNS lookups (the names " &
              "of the sites and apps you open) and sends them to the server you chose. " &
              "No other traffic goes through it.")
    paragraph("Retro DNS does not collect, keep or share your lookups; it only counts " &
              "them on this device. The DNS server you pick sees your lookups: read its " &
              "privacy policy.")
    paragraph("Next, Android asks you to allow the connection. You can turn it off any " &
              "time here, or in Settings, VPN.")
    checkbox("&I understand", discloseAgreed)
    row:
      spring()
      if button("&Continue", isDefault = true, enabled = discloseAgreed):
        disclosed = true
        stateDirty = true
        discloseOpen = false
        vpnStart(pendingVpnKey)
      if button("Cancel"): discloseOpen = false

  # servers with addresses only
  let ipAt = indexOfKey(ipKey)
  let ipName = if ipAt >= 0: servers[ipAt].name else: "This server"
  let ipAddrs = if ipAt >= 0: (servers[ipAt].ipv4 & servers[ipAt].ipv6).join(", ") else: ""
  dialog(ipOpen, "Use on Wi-Fi or a Router", 440):
    paragraph(ipName & " has no encrypted DNS, so the VPN cannot use it.")
    paragraph("Set its addresses on a Wi-Fi network: Wi-Fi, your network, Edit, " &
              "Advanced, IP settings: Static, then DNS 1 and DNS 2 (not every phone " &
              "has it). Or set them on your router, for every device at home.")
    if ipAddrs.len > 0: paragraph("Addresses: " & ipAddrs)
    row:
      if button("&Copy addresses", isDefault = true, enabled = ipAddrs.len > 0):
        putClipboardText(ipAddrs)
        toast("Copied the addresses")
      if button("&Wi-Fi settings", enabled = onAndroid()):
        openSettingsPage("android.settings.WIFI_SETTINGS")
      spring()
      if button("Close"): ipOpen = false

  # add or edit
  let editTitle = if editKey.len == 0: "Add Server" else: "Edit Server"
  dialog(editOpen, editTitle, 460):
    form 0:
      field "&Name:": edit eName
      field "&Group:": combo(Groups, eGroup)
      field "DNS over &TLS host:": edit eDot
      field "Do&H address:": edit eDoh
      field "IPv&4:": edit eV4
      field "IPv&6:": edit eV6
      field "&Good for:": editArea(eNote, lines = 3)
    paragraph("Fill at least one address. The VPN needs the DoH address or the " &
              "DNS-over-TLS host, such as dns.example.com. NextDNS: " &
              "your-id.dns.nextdns.io.")
    if editMsg.len > 0: label(editMsg, color = cMaroon)
    row:
      spring()
      if button("&Save", isDefault = true): saveEdit()
      if button("Cancel"): editOpen = false

  # import
  dialog(importOpen, "Import Servers", 460):
    paragraph("Paste a CSV table: Name, Group, Private DNS host, DoH address, IPv4, " &
              "IPv6, Note (the first line holds the names). Export makes one.")
    editArea(importText, lines = 8)
    row:
      if button("&Paste"): importText = getClipboardText()
      spring()
      if button("&Import", isDefault = true, enabled = importText.strip.len > 0):
        let n = importServers()
        if n > 0:
          toast("Added " & $n & (if n == 1: " server" else: " servers"))
          importOpen = false
          importText = ""
          chip = Chips.high              # (Mine)
        else:
          toast("Nothing new to add")
      if button("Cancel"): importOpen = false

  # how it works
  dialog(helpOpen, "How Retro DNS Works", 480):
    paragraph("Every app asks a DNS server where a site or service lives. Retro DNS " &
              "changes which server answers, for every app on the phone.")
    paragraph("VPN: a VPN that stays on the phone and carries DNS lookups only, to " &
              "the server you pick, encrypted (DNS over HTTPS or TLS), with no setup. " &
              "Nothing else goes through it. A notification shows it is on, with " &
              "Open and Disconnect.")
    paragraph("On Windows, macOS and Linux: Use on This Computer gives the computer the " &
              "server's addresses (encrypted where the system can: Windows 11, " &
              "systemd-resolved), after the system asks for its administrator. Back to " &
              "Automatic gives it its network's own again. On a Mac and an iPhone or " &
              "iPad, a server with encrypted DNS comes as a profile that Settings " &
              "installs, and removes again.")
    paragraph("Servers with plain DNS only are for Wi-Fi or a router on a phone: Use on " &
              "Wi-Fi in their details shows how.")
    paragraph("No lookups counted? Android's own Private DNS, when set to a host " &
              "name in Settings, sends lookups there instead: set it to Automatic.")
    paragraph("Test measures how quickly each server can be reached from where you are.")
    paragraph("Retro DNS collects nothing: no account, no analytics, no ads. The " &
              "server you pick sees your lookups, so pick one whose privacy policy " &
              "you trust.")
    row:
      spring()
      if button("OK", isDefault = true): helpOpen = false

  dialog(lookOpen, "Appearance", 460):
    discard appearanceSettings()
    row:
      spring()
      if button("OK", isDefault = true): lookOpen = false

  # questions and problems
  let delAt = indexOfKey(selKey)
  let delName = if delAt >= 0: servers[delAt].name else: "this server"
  case msgBox(deleteOpen, "Delete Server", "Delete " & delName & " from your servers?",
              ["&Delete", "Cancel"], miWarning)
  of 1: deleteSelected()
  else: discard
  discard msgBox(failOpen, AppTitle, failMsg, ["OK"], miWarning)
  aboutBox(aboutOpen, AppTitle, AppVersion,
           ["Change the DNS server of your phone or computer in one tap.",
            "47 public servers with what each is good for, speed tests, and your own.",
            "A DNS-only VPN, encrypted. Collects nothing.",
            "Not affiliated with any DNS provider.",
            "Made with Retro Nim UI.",
            "Copyright (c) 2026 Sultan Al Isaiee @foxoman. www.foxoman.net"],
           tagline = "Switch DNS in one tap", iconPng = AppIconPng, glyph = pxGlobe,
           credits = [RetroFontCredit,
                      "Server list checked against the providers' pages, November 2026."])

proc statusText(list: seq[int]): string =
  result = $list.len & " of " & $servers.len & " servers"
  if favs.len > 0:
    result &= ", " & $favs.len & (if favs.len == 1: " favourite" else: " favourites")
  if testing.len > 0: result &= ", testing " & $testing.len

proc shell() =
  let list = shownServers()
  let compact = isCompact()
  menus(indexOfKey(selKey))
  if not compact: tools()
  let here = indexOfKey(hereKey)
  let right = if not onAndroid(): (if here >= 0: "DNS: " & servers[here].name else: "DNS: automatic")
              elif vpnNow.state == vsOn: "VPN: " & vpnNow.server
              else: "VPN off"
  statusbar(statusText(list), right)
  if compact:
    # a phone held upright: one page that scrolls
    panel:
      connection()
      filterBar()
      serverList(list, 8)
      row:
        if button("Test all"): testAll(list)
        if button("Fastest"):
          testAll(list)
          fastestAsked = true
        if button("Add..."): startEdit("")
      space(6)
      separator()
      details(indexOfKey(selKey))
  else:
    sidePane(true, paneW, paneH):
      connection()
      filterBar()
      serverList(list, -1)
    do:
      panel: details(indexOfKey(selKey))
  dialogs()

proc main() =
  setThreadCount(2)          # (drawing on 2 threads, not one a core: less memory)
  loadState()
  servers = builtinServers()
  createDir(appDir())
  for s in loadCustom(customPath()):
    if indexOfKey(s.key) < 0: servers.add s
  openApp(AppTitle, 1180, 760, id = AppId, icon = AppIconPng, look = AppId)
  readNow()
  var lastPane = (paneW, paneH)
  while beginFrame():
    if stoppedFrame():
      endFrame()
      continue
    captionBar()
    if wasPaused and not ui.paused: readNow()      # (back from Settings)
    wasPaused = ui.paused
    handleResults()
    vpnWatch()
    adminWatch()
    let every = if vpnAsking or vpnNow.state == vsStarting: 0.5 else: 2.5
    if onAndroid() and not ui.paused and epochTime() - lastRead > every: readNow()
    shell()
    if (paneW, paneH) != lastPane:
      lastPane = (paneW, paneH)
      stateDirty = true
    if testsPending > 0: wakeIn(150)
    elif vpnAsking or vpnNow.state == vsStarting: wakeIn(500)
    elif adminAsk.len > 0: wakeIn(200)
    elif onAndroid(): wakeIn(2600)
    if stateDirty and epochTime() - lastSave > 1.0: saveState()
    endFrame()
    appFrameDone()
  saveState()
  closeApp()

main()

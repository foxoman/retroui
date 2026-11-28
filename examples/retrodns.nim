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
import retroui/[parallel, admin, forcegraph, domains]
from retroui/system import homeWidget, notificationActions
import retrodns/[catalog, androidglue, tester, vpn, desktop]

const
  retrodnsVersion {.strdefine.} = "1.9.3"   # (build.sh passes its VERSION)
  AppTitle = "Retro DNS"
  AppVersion = retrodnsVersion
  AppId = "RetroDNS"
  LookKey = AppId & "-1.6"               # (1.6's look: phones start in Gloss once, whatever was kept)
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
  history: Table[string, seq[int]]      # key -> its tests' ms, the last 30 (-1 failed), kept
  lookupMs: seq[float]                  # the VPN's lookups: their time on average, a sample every 2 s
  lookupAt = 0                          # (when the last sample was taken)
  lookupsBefore = 0                     # (... how many had been answered then)
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
  lastVpnKey = ""                       # (the last one: the widget's Turn on)
  widgetShown = ""                      # (what the home screen's widget shows)
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
  autoSwitch = true                     # the VPN goes on to another server when one stops answering
  encryption = 0                        # how the VPN sends lookups: 0 automatic, 1 HTTPS, 2 TLS
  blockText = ""                        # the block list (a name a line, "!name" an exception)
  blockOpen = false
  blockEdit = ""
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
  s["lastVpn"] = lastVpnKey
  s["autoSwitch"] = $autoSwitch
  s["encryption"] = $encryption
  s["blockList"] = blockText
  var h: seq[string]
  for k, v in history:
    h.add k & "=" & v.mapIt($it).join(" ")
  s["history"] = h.join(";")
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
  lastVpnKey = s.getOrDefault("lastVpn")
  autoSwitch = s.getOrDefault("autoSwitch", "true") != "false"
  try: encryption = clamp(parseInt(s.getOrDefault("encryption", "0")), 0, 2)
  except ValueError: discard
  blockText = s.getOrDefault("blockList")
  for e in s.getOrDefault("history").split(';'):
    let eq = e.find('=')
    if eq <= 0: continue
    var v: seq[int]
    for n in e[eq + 1 .. ^1].splitWhitespace:
      try: v.add parseInt(n) except ValueError: discard
    if v.len > 0: history[e[0 ..< eq]] = v

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
    # (its tests over time: the graph in its details)
    var h = history.getOrDefault(d.key)
    h.add d.ms
    if h.len > 30: h.delete(0)
    history[d.key] = h
    stateDirty = true
  if fastestAsked and testing.len == 0:
    fastestAsked = false
    pickFastest()

# ---- switching with the VPN --------------------------------------------------------------------

proc vpnServes(s: Server): bool =
  ## The VPN is on and sends lookups to `s`.
  vpnNow.state == vsOn and vpnNow.server == s.name

proc nextServers(s: Server): seq[Server] =
  ## Where the VPN goes on to when `s` stops answering (blocked, down): the favourites with
  ## encrypted DNS, then the others that answered the tests -- the fastest first, three at most
  ## (none when Switch When a Server Stops Answering is off).
  if not autoSwitch: return
  var pool: seq[(int, int, int)]          # (not a favourite, its speed, its index)
  for i, o in servers:
    if o.key == s.key or not vpnReady(o): continue
    let v = speedOf(o.key)
    let fav = o.key in favs
    if not fav and (v < 0 or v == int.high): continue
    pool.add ((if fav: 0 else: 1), (if v < 0: int.high else: v), i)
  pool.sort()
  for k in 0 ..< min(3, pool.len): result.add servers[pool[k][2]]

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
  lastVpnKey = key
  stateDirty = true
  let prefer = case encryption
               of 1: "doh"
               of 2: "dot"
               else: ""
  let r = vpnConnect(vpnConfig(s, nextServers(s), blockLines(blockText), prefer))
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

proc widgetWatch() =
  ## The widget on the home screen (Android): on and the server, or off,
  ## with a button for the other -- as the VPN's own Java writes it while
  ## the app is closed; its buttons pressed come here.
  if not onAndroid(): return
  for (tag, action) in notificationActions():
    if tag != "widget": continue
    if action == "Turn off" and vpnNow.state in {vsOn, vsStarting}: vpnStop()
    elif action == "Turn on" and vpnNow.state notin {vsOn, vsStarting}:
      vpnStart(if indexOfKey(lastVpnKey) >= 0: lastVpnKey else: selKey)
  let on = vpnNow.state in {vsOn, vsStarting}
  let text = if on: "On: " & (if vpnNow.server.len > 0: vpnNow.server else: "a DNS server")
             else: "Off"
  if text != widgetShown:
    widgetShown = text
    homeWidget("Retro DNS", text, [if on: "Turn off" else: "Turn on"])

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
    if onAndroid():
      # (the VPN's own settings: a computer's DNS is set as its administrator, without them)
      menu "&VPN":
        if menuItem("&Switch When a Server Stops Answering", checked = autoSwitch):
          autoSwitch = not autoSwitch
          stateDirty = true
        if menuItem("&Block List..."):
          blockEdit = blockText
          blockOpen = true
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
  if vpnNow.blockedNames > 0: result &= ", " & $vpnNow.blockedNames & " blocked"

proc speedGraph(key: string) =
  ## Its tests over time, a line (the last 30; one that did not answer, a
  ## gap at the top), with the best and the usual.
  let h = history.getOrDefault(key)
  var ok: seq[int]
  for v in h:
    if v >= 0: ok.add v
  if ok.len < 2: return
  var vals: seq[float]
  let worst = max(ok)
  for v in h: vals.add(if v >= 0: v.float else: worst.float * 1.2)
  var sorted = ok
  sorted.sort()
  row:
    label("Its tests:", color = ui.theme.gray)
    sparkline(vals, w = dp(160), h = FontH + dp(8), color = cNavy)
    label("best " & $sorted[0] & " ms, usually " & $sorted[sorted.len div 2] & " ms",
          color = ui.theme.gray)

proc lookupGraph() =
  ## The VPN's lookups: their time on average, a sample every 2 seconds while
  ## lookups come (the last 4 minutes), as a line.
  if ui.now - lookupAt >= 2000:
    lookupAt = ui.now
    if vpnNow.avgMs >= 0 and vpnNow.answered != lookupsBefore:
      lookupMs.add vpnNow.avgMs.float
      if lookupMs.len > 120: lookupMs.delete(0)
    lookupsBefore = vpnNow.answered
  if lookupMs.len >= 2:
    row:
      label("Lookups' time:", color = ui.theme.gray)
      sparkline(lookupMs, w = dp(200), h = FontH + dp(10), color = cTeal)

var
  reach = newForceGraph(linkLength = 45)
  reachAt = 0
  reachSel = -1

proc appWord(pkg: string): string =
  ## "com.google.android.youtube" -> "youtube"; "" -> "This phone" (Android 9 and older).
  if pkg.len == 0: return "This phone"
  let parts = pkg.split('.')
  result = parts[^1]
  if result in ["android", "app", "mobile", "client"] and parts.len > 1: result = parts[^2]

proc reachGraph() =
  ## What this phone reached through the VPN: each app joined to the sites it looked up (their
  ## registrable domains: maps.google.com and mail.google.com are google.com), the last 2
  ## minutes, as a graph that lays itself out.
  if ui.now - reachAt >= 2000 or reachAt == 0:
    reachAt = ui.now
    let recent = vpnRecent()
    var fresh: seq[tuple[app, name: string]]
    for r in recent:
      if r.agoMs > 120_000: continue
      let site = registrableDomain(r.name)
      fresh.add (r.app, if site.len > 0: site else: r.name)
    let newest = if reach.len > 160 and fresh.len > 80: fresh.len - 80 else: 0
    if reach.len > 160:
      reach = newForceGraph(linkLength = 45)       # (too many: the newest only)
      reachSel = -1
    for (app, site) in fresh[newest .. ^1]:
      let a = reach.addNode("app:" & app, appWord(app), group = 0)
      let d = reach.addNode("site:" & site, site, group = 1)
      reach.link(a, d)
  if reach.len == 0: return
  label("What this phone reached (the last 2 minutes):", color = ui.theme.gray)
  discard graphView(reach, dp(220), reachSel)
  if reachSel >= 0:
    let n = reach.nodes[reachSel]
    var with: seq[string]
    for l in reach.links:
      if l.a == reachSel: with.add reach.nodes[l.b].label
      elif l.b == reachSel: with.add reach.nodes[l.a].label
    label(n.label & ": " & with.join(", "), color = ui.theme.gray)

proc vpnPart() =
  if not vpnNow.present:
    paragraph("This build has no VPN in it: build it with sh build.sh, whose " &
              "--java gives retroapk the VPN.")
    return
  let on = vpnNow.state == vsOn
  row:
    led(on, "")
    label(vpnLine(), bold = true)
  if on:
    label(lookupLine())
    # (why the last lookup failed; how it gets past a block; where it went on to)
    if vpnNow.failed > 0 and vpnNow.lastFailure.len > 0:
      label("The last that failed: " & vpnNow.lastFailure, color = cMaroon)
    if vpnNow.getsPast.len > 0:
      label("This network cut its hello: getting past it -- " & vpnNow.getsPast, color = cTeal)
    if vpnNow.switched.len > 0: label(vpnNow.switched, color = cNavy)
    lookupGraph()
    reachGraph()
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
  speedGraph(s.key)
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
                     else: "Use He&re"
      if button(useLabel, isDefault = not inUse,
                enabled = not inUse and not vpnAsking and adminAsk.len == 0 and way != hwNone):
        useHere(s.key)
    if button("T&est", enabled = s.key notin testing): testServer(s)
    let favLabel = if s.key in favs: "Unfav&ourite" else: "Fav&ourite"
    if button(favLabel): toggleFav(s.key)
  row:
    if s.dot.len > 0 and button("Cop&y host"):
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
  # the block list: names answered "no such name" on the phone (a hosts file without root)
  if blockOpen:
    var ok = false
    dialog(blockOpen, "Block List", 480):
      paragraph("Names the VPN answers with no such name right here, sending nothing: ads, trackers, " &
                "sites you choose. A name a line, its subdomains too; !name an exception; # a remark. A " &
                "hosts file's lines (0.0.0.0 name) work as they are. On Android, with the VPN.",
                color = ui.theme.gray)
      editArea(blockEdit, lines = 10)
      label($blockLines(blockEdit).len & " names", color = ui.theme.gray)
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)): ok = true
        if button("Cancel", w = dp(80)): blockOpen = false
    if ok:
      blockOpen = false
      blockText = blockEdit
      stateDirty = true
      if vpnNow.state == vsOn and vpnKey.len > 0: vpnStart(vpnKey)   # (the VPN takes it now)
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
      # (on a phone: a web address's keyboard for the addresses, Next from one box to the next)
      field "&Name:":
        textKeyboard(kbText, keNext)
        edit eName
      field "&Group:": combo(Groups, eGroup)
      field "DNS over &TLS host:":
        textKeyboard(kbUrl, keNext)
        edit eDot
      field "Do&H address:":
        textKeyboard(kbUrl, keNext)
        edit eDoh
      field "IPv&4:":
        textKeyboard(kbUrl, keNext)
        edit eV4
      field "IPv&6:":
        textKeyboard(kbUrl, keNext)
        edit eV6
      field "Good fo&r:": editArea(eNote, lines = 3)
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
    if not dialogsAsPages():      # (a page: Close on its bar)
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

# ---- a phone in the newer looks: tabs, pages and rows in groups, as phone apps are ---------------

type Section = enum
  secDns, secServers, secActivity, secFavourites, secMore

const SectionInfo: array[Section, tuple[glyph, name, home: string; tint: Color]] = [
  (nfShield, "DNS", "dns", color(38, 94, 196)), (nfServer, "Servers", "servers", color(84, 96, 118)),
  (nfHistory, "Activity", "activity", color(40, 150, 90)), (nfStar, "Favourites", "favourites", color(236, 150, 24)),
  (nfCog, "More", "more", color(128, 128, 136))]

var
  phoneSec = secDns
  phoneNav: array[Section, PageStack] = [initPages("dns"), initPages("servers"), initPages("activity"),
                                         initPages("favourites"), initPages("more")]
  phoneDetail = ""                      # the server whose page is open
  removeAsk = false
  rowMenuOpen = false                   # a server row held: what can be done to it
  rowMenuKey = ""
  favEditing = false                    # Favourites' Edit: the rows' minus and grip
  activityShown = 0                     # Activity: 0 the names looked up, 1 what reached what
  activityQuery = ""
  nameMenuOpen = false                  # a name of Activity held: Block, Copy
  nameMenuName = ""
  recentNow: seq[tuple[app, name: string; count, agoMs: int]]
  recentAt = -10_000
  showActivity = onAndroid()            # (Activity: the VPN's lookups -- Android's)
  layoutWanted = 0                      # (0: the screen's; 1 a phone's, 2 a tablet's: tests)

proc sections(): seq[Section] =
  for s in Section:
    if s != secActivity or showActivity: result.add s

proc phoneSpeed(key: string): string =
  if key in testing: return "testing..."
  let v = speedOf(key)
  if v == int.high: "" elif v < 0: "no answer" else: $v & " ms"

proc phoneFind(): seq[int] =
  ## (the servers the search finds, all of them while it is empty)
  for i, s in servers:
    if query.len == 0: result.add i
    else:
      let hay = (s.name & " " & s.group & " " & s.note & " " & s.dot & " " & s.doh).toLowerAscii
      var ok = true
      for word in query.toLowerAscii.splitWhitespace:
        if word notin hay: ok = false
      if ok: result.add i

proc openServer(key: string) =
  ## (a server's page, over the section's)
  phoneDetail = key
  phoneNav[phoneSec].push("server")

proc serverRow(i: int; detail = ""; glyph = ""; tint = Color()) =
  ## (a server's row: ticked when it is the one picked; its speed; a tap picks it, its info
  ## button opens its page, a finger held on it what can be done to it)
  let s = servers[i]
  let inUse = vpnServes(s) or (not onAndroid() and s.key == hereKey)
  let h = tableRow(s.name, if detail.len > 0: detail else: phoneSpeed(s.key), taInfo,
                   glyph = if glyph.len > 0: glyph elif s.key == selKey: nfCheck else: " ", tint = tint,
                   subtitle = if inUse: "In use" elif s.key in favs: "Favourite" else: "",
                   key = s.key)
  if h.clicked and s.key != selKey:
    selKey = s.key
    stateDirty = true
    # (the VPN on: it goes to the server picked)
    if onAndroid() and vpnNow.state == vsOn and vpnReady(s): vpnStart(s.key)
  if h.info: openServer(s.key)
  if h.menu:
    rowMenuKey = s.key
    rowMenuOpen = true

proc rowMenu() =
  ## (a server row held: Connect or Use, Test, Favourite, Copy, its page)
  let i = indexOfKey(rowMenuKey)
  if i < 0:
    rowMenuOpen = false
    return
  let s = servers[i]
  var acts: seq[string]
  let way = hereWay(s)
  let useWord = if way == hwVpn: "Connect" elif way == hwProfile: "Install Profile"
                else: "Use on This " & deviceWord().capitalizeAscii
  if way != hwNone and (way != hwVpn or vpnReady(s)): acts.add useWord
  acts.add "Test"
  acts.add(if s.key in favs: "Remove from Favourites" else: "Add to Favourites")
  if s.doh.len > 0: acts.add "Copy the DoH Address"
  elif s.dot.len > 0: acts.add "Copy the Host"
  acts.add "Details"
  let k = actionSheet(rowMenuOpen, s.name, acts)
  if k < 0: return
  case acts[k]
  of "Test": testServer(s)
  of "Add to Favourites", "Remove from Favourites": toggleFav(s.key)
  of "Copy the DoH Address":
    putClipboardText(s.doh)
    toast("Copied: paste it in your browser's secure DNS setting")
  of "Copy the Host":
    putClipboardText(s.dot)
    toast("Copied: Android's Settings, Private DNS takes it too")
  of "Details": openServer(s.key)
  else:
    selKey = s.key
    stateDirty = true
    useHere(s.key)

# (the colors of the state: on, on its way, off)
proc okColor(): Color =
  if glossLook(): color(46, 168, 64) else: color(48, 190, 92)
proc waitColor(): Color = color(232, 150, 32)
proc offColor(): Color = mixColor(ui.theme.field, ui.theme.fieldText, 0.35)

proc lineColor(): Color =
  ## (a line between parts of a card, as between its rows)
  if glossLook(): (if lumaOfColor(ui.theme.window) < 128: mixColor(ui.theme.field, color(255, 255, 255), 0.08)
                   else: color(217, 217, 217))
  else: mixColor(ui.theme.field, ui.theme.fieldText, 0.12)

proc emblem(cx, cy, d: int; c: Color; glyph: string) =
  ## (a round badge in `c`, lit from above, `glyph` white on it)
  let r = float(d) / 2
  disc(float(cx), float(cy) + 1, r, withAlpha(color(0, 0, 0), 40))
  discShaded(float(cx), float(cy), r, mixColor(c, color(255, 255, 255), 0.22), mixColor(c, color(0, 0, 0), 0.12))
  if glossLook():
    pushClip(rect(cx - d div 2, cy - d div 2, d, d div 2))
    disc(float(cx), float(cy), r - 1, withAlpha(color(255, 255, 255), 46))
    popClip()
  let gs = style(size = float(d) / float(FontH) * 0.5)
  text(cx - textWidth(glyph, gs) div 2, cy - lineHeight(gs) div 2, glyph, color(255, 255, 255), gs)

type DnsState = tuple[on, busy: bool; title, sub: string]

proc dnsState(): DnsState =
  ## (where the lookups go now, in words)
  if onAndroid():
    result.on = vpnNow.state == vsOn
    result.busy = vpnNow.state == vsStarting or vpnAsking
    result.title = if result.on: "Protected" elif result.busy: "Connecting..." else: "Not Protected"
    result.sub = if result.on: vpnNow.server & " · " & vpnNow.mode
                 elif vpnAsking: "Waiting for Android's permission"
                 elif vpnNow.state == vsFailed and vpnNow.error.len > 0: vpnNow.error
                 elif not vpnNow.present: "This build has no VPN in it"
                 else: "Your network's own DNS"
  else:
    let at = indexOfKey(hereKey)
    result.on = at >= 0
    result.busy = adminAsk.len > 0
    result.title = if result.busy: "Changing..." elif result.on: "DNS Changed" else: "Automatic DNS"
    result.sub = if result.busy: "Waiting for the system"
                 elif result.on: servers[at].name & (if hereProfile: " · a profile, encrypted" else: "")
                 else: "This " & deviceWord() & "'s network's own"

proc statusCard(small = false) =
  ## The head of the DNS page: a badge, the state in large words, where the lookups go; with
  ## the VPN on, its numbers under them -- lookups, their time, the names blocked. `small`: a
  ## tablet's, over its sections.
  let st = dnsState()
  let c = if st.on: okColor() elif st.busy: waitColor() else: offColor()
  let stats = onAndroid() and st.on and not small
  tableGroup(""):
    let pad = if fingers(): dp(14) else: dp(12)
    let headH = if small: max(dp(62), 2 * FontH + dp(24)) else: max(dp(84), 2 * FontH + dp(40))
    let r = place(0, headH + (if stats: max(dp(58), 2 * FontH + dp(18)) else: 0), fill = true)
    let d = if small: dp(38) else: dp(54)
    emblem(r.x + pad + d div 2, r.y + headH div 2, d, c, if st.on: nfShield else: nfGlobe)
    let tx = r.x + pad + d + dp(14)
    let tst = style(bold = true, size = if small: 1.15 else: 1.45)
    let room = r.x + r.w - pad - tx
    let ty = r.y + (headH - lineHeight(tst) - FontH - dp(3)) div 2
    let t = ellipsize(st.title, room - dp(16), tst)
    text(tx, ty, t, ui.theme.fieldText, tst)
    # (the dot: green on, amber on its way, gray off)
    let dr = float(max(dp(4), 3))
    disc(float(tx + textWidth(t, tst) + dp(10)), float(ty) + float(lineHeight(tst)) / 2, dr, c)
    text(tx, ty + lineHeight(tst) + dp(3), ellipsize(st.sub, room), ui.theme.gray)
    if accessOn: accessNode(arLabel, st.title & ", " & st.sub, r = r)
    if stats:
      let sy = r.y + headH
      hline(r.x + pad, sy, r.w - 2 * pad, lineColor())
      let parts = [($vpnNow.answered, "Lookups"),
                   ((if vpnNow.avgMs >= 0: $vpnNow.avgMs & " ms" else: "-"), "On Average"),
                   ($vpnNow.blockedNames, "Blocked")]
      let cw = r.w div parts.len
      let nst = style(bold = true, size = 1.25)
      let sh = r.y + r.h - sy
      for k, (n, what) in parts:
        let cx = r.x + k * cw
        if k > 0: vline(cx, sy + dp(10), sh - dp(20), lineColor())
        let ny = sy + (sh - lineHeight(nst) - FontH) div 2
        text(cx + (cw - textWidth(n, nst)) div 2, ny, n, ui.theme.fieldText, nst)
        text(cx + (cw - textWidth(what)) div 2, ny + lineHeight(nst), what, ui.theme.gray)

proc connectButton() =
  ## (the page's big button: Connect or Disconnect; on a computer, Use and Back to Automatic)
  let cur = indexOfKey(selKey)
  if onAndroid():
    if not vpnNow.present: return
    if vpnAsking or vpnNow.state == vsStarting:
      if bigButton("Cancel", btGray):
        vpnAsking = false
        vpnStop()
    elif vpnNow.state == vsOn:
      let picked = if cur >= 0: servers[cur].name else: ""
      if picked.len > 0 and picked != vpnNow.server and vpnReady(servers[cur]):
        if bigButton("Switch to " & picked, btBlue): vpnStart(selKey)
      if bigButton("Disconnect", btRed): vpnStop()
    elif bigButton("Connect", btGreen, enabled = cur >= 0): vpnStart(selKey)
  else:
    when not (defined(wasm) or defined(js)):
      let at = indexOfKey(hereKey)
      let way = if cur >= 0: hereWay(servers[cur]) else: hwNone
      if adminAsk.len == 0:
        if cur >= 0 and servers[cur].key != hereKey and way != hwNone:
          let useText = if way == hwProfile: "Install Profile" else: "Use on This " & deviceWord().capitalizeAscii
          if bigButton(useText, btBlue): useHere(selKey)
        if at >= 0 and bigButton("Back to Automatic", btGray): resetHere()

proc segmentRow(options: openArray[string]; sel: var int): bool =
  ## (a row of a group holding a segmented choice, as wide as it)
  let r = place(0, (if fingers(): dp(48) else: CtrlH + dp(14)), fill = true)
  let pad = if fingers(): dp(10) else: dp(8)
  pushFrame(rect(r.x + pad, r.y + (r.h - CtrlH) div 2, r.w - 2 * pad, 0))
  result = segmented(options, sel, w = r.w - 2 * pad)
  discard popFrame()

proc fastest(n: int): seq[int] =
  ## (the `n` servers that answered fastest from here, the fastest first)
  var tested: seq[(int, int)]
  for i, s in servers:
    let v = speedOf(s.key)
    if v >= 0 and v != int.high: tested.add (v, i)
  tested.sort()
  for k in 0 ..< min(n, tested.len): result.add tested[k][1]

proc pageNote(s: string) =
  ## (a gray note under the page's groups, in the middle)
  let lines = wrapLines(s, cellRoom())
  let lh = FontH + dp(1)
  let r = place(0, lines.len * lh, fill = true)     # (one place: its lines close together)
  let ink = if glossLook() and lumaOfColor(ui.theme.window) >= 128: color(76, 86, 108) else: ui.theme.gray
  for i, ln in lines:
    text(r.x + (r.w - textWidth(ln)) div 2, r.y + i * lh, ln, ink)

proc twoButtons(a, b: string; enabledB = true): int =
  ## (two buttons side by side under the groups, the first the default: 1 or 2 when clicked)
  let room = cellRoom()
  let bw = min((room - Gap) div 2, dp(200))
  let bh = if fingers(): dp(44) else: 0
  row:
    space((room - 2 * bw - Gap) div 2)
    if button(a, isDefault = true, w = bw, h = bh): result = 1
    if button(b, w = bw, h = bh, enabled = enabledB): result = 2

proc phoneDns() =
  let cur = indexOfKey(selKey)
  let curName = if cur >= 0: servers[cur].name else: "Pick one"
  statusCard()
  connectButton()
  if onAndroid() and not vpnNow.present:
    tableGroup("", "This build has no VPN in it: build it with build.sh, whose --java gives " &
                   "retroapk the VPN."):
      discard tableRow("VPN", "not here")
  tableGroup(if onAndroid(): "Server" else: "This " & deviceWord().capitalizeAscii):
    if tableRow("Server", curName, taChevron, glyph = nfServer, tint = color(84, 96, 118)).clicked:
      phoneSec = secServers
    if cur >= 0 and onAndroid():
      let s = servers[cur]
      let kinds = (if s.doh.len > 0: @["HTTPS"] else: @[]) & (if s.dot.len > 0: @["TLS"] else: @[])
      discard tableRow("Encrypted With", if kinds.len > 0: kinds.join(", ") else: "none: for Wi-Fi only",
                       glyph = nfLock, tint = color(40, 150, 90))
    if onAndroid() and tableSwitch("Switch When One Stops", autoSwitch, glyph = nfBolt,
                                   tint = color(232, 150, 32)):
      stateDirty = true
  if onAndroid():
    tableGroup("Encryption", case encryption
                             of 1: "DNS over HTTPS where the server has it: it looks like any web page."
                             of 2: "DNS over TLS where the server has it: Android's Private DNS way."
                             else: "HTTPS where the server has it, else TLS."):
      if segmentRow(["Automatic", "HTTPS", "TLS"], encryption):
        stateDirty = true
        if vpnNow.state == vsOn and vpnKey.len > 0: vpnStart(vpnKey)    # (the VPN takes it now)
  # the fastest from here, numbered; Test All and Use the Fastest
  let best = fastest(5)
  if best.len > 0:
    tableGroup("Fastest from Here"):
      for k, i in best:
        serverRow(i, $speedOf(servers[i].key) & " ms", glyph = $(k + 1),
                  tint = if k == 0: color(232, 150, 32) else: color(130, 138, 152))
  case twoButtons(if testing.len > 0: "Testing " & $testing.len & "..." else: "Test All Servers",
                  "Use the Fastest", enabledB = testing.len == 0)
  of 1: testAll(phoneFind())
  of 2:
    if best.len > 0:
      selKey = servers[best[0]].key
      stateDirty = true
      useHere(selKey)
    else:
      testAll(phoneFind())
      fastestAsked = true
  else: discard
  space(dp(4))
  pageNote(if best.len == 0: "Test the servers: the ones that answer fastest from this network come here."
           else: "Each server's time to answer from this network.")
  if onAndroid() and vpnNow.state == vsOn:
    if vpnNow.failed > 0 or vpnNow.memKb > 0 or vpnNow.getsPast.len > 0 or vpnNow.switched.len > 0:
      tableGroup("The VPN"):
        if vpnNow.failed > 0: discard tableRow("Failed", $vpnNow.failed, subtitle = vpnNow.lastFailure)
        if vpnNow.getsPast.len > 0: discard tableRow("Getting Past", "", subtitle = vpnNow.getsPast)
        if vpnNow.switched.len > 0: discard tableRow("Switched", "", subtitle = vpnNow.switched)
        if vpnNow.memKb > 0: discard tableRow("Its Memory", $((vpnNow.memKb + 512) div 1024) & " MB")
    lookupGraph()

proc phoneServers() =
  let found = phoneFind()
  if found.len == 0:
    emptyState(pxSearch, "No server matches", detail = "Try other words.")
    return
  for g in Groups:
    var list: seq[int]
    for i in found:
      if servers[i].group == g or (g == "Mine" and servers[i].custom and servers[i].group notin Groups):
        list.add i
    if sortBySpeed:
      list.sort(proc (a, b: int): int = cmp(speedRank(servers[a].key), speedRank(servers[b].key)))
    if list.len == 0: continue
    tableGroup(g):
      for i in list: serverRow(i)
  pageNote("Hold a server for what you can do with it.")

proc phoneServer() =
  let i = indexOfKey(phoneDetail)
  if i < 0:
    emptyState(pxGlobe, "Pick a server")
    return
  let s = servers[i]
  let way = hereWay(s)
  let inUse = vpnServes(s) or (not onAndroid() and s.key == hereKey)
  tableGroup("", s.note):
    discard tableRow("Kind", s.group)
    discard tableRow("Speed", timingText(s.key))
    var fav = s.key in favs
    if tableSwitch("Favourite", fav): toggleFav(s.key)
  if s.dot.len + s.doh.len + s.ipv4.len + s.ipv6.len > 0:
    tableGroup("Addresses", "Tap one to copy it."):
      if s.dot.len > 0 and tableRow("Private DNS", s.dot).clicked:
        putClipboardText(s.dot)
        toast("Copied: Android's Settings, Private DNS takes it too")
      if s.doh.len > 0 and tableRow("DoH", s.doh).clicked:
        putClipboardText(s.doh)
        toast("Copied: paste it in your browser's secure DNS setting")
      if s.ipv4.len > 0 and tableRow("IPv4", s.ipv4.join(", ")).clicked:
        putClipboardText(s.ipv4.join(", "))
        toast("Copied the addresses")
      if s.ipv6.len > 0 and tableRow("IPv6", s.ipv6.join(", ")).clicked:
        putClipboardText(s.ipv6.join(", "))
        toast("Copied the addresses")
  let wifiOnly = (way == hwVpn and not vpnReady(s)) or
                 (way == hwNone and defined(ios) and addrsOf(s).len > 0)
  tableGroup("", if wifiOnly: "No encrypted DNS, so not for the " &
                              (if way == hwVpn: "VPN" else: "profile") & ": use it on Wi-Fi or a router." else: ""):
    if wifiOnly:
      if tableButton("Use on Wi-Fi..."):
        ipKey = s.key
        ipOpen = true
    else:
      let useLabel = if inUse: (if way == hwVpn: "Connected" else: "In Use")
                     elif way == hwVpn: "Connect"
                     elif way == hwProfile: "Install Profile"
                     else: "Use Here"
      if tableButton(useLabel, enabled = not inUse and not vpnAsking and adminAsk.len == 0 and way != hwNone):
        selKey = s.key
        useHere(s.key)
    if tableButton("Test", enabled = s.key notin testing): testServer(s)
  if s.custom:
    tableGroup(""):
      if tableButton("Edit"): startEdit(s.key)
      if tableButton("Delete Server", destructive = true): removeAsk = true
  speedGraph(s.key)
  case alertBox(removeAsk, "Delete " & s.name & "?", "Your server goes from the list; you can add " &
                "it again.", ["Cancel", "Delete"], cancel = 0)
  of 1:
    selKey = s.key
    deleteSelected()
    discard phoneNav[phoneSec].pop()
  else: discard

proc phoneFavourites() =
  var list: seq[int]
  for k in favs:
    let i = indexOfKey(k)
    if i >= 0: list.add i
  if list.len == 0:
    favEditing = false
    emptyState(pxStar, "No favourites yet", detail = "Hold a server, Add to Favourites.")
    return
  if favEditing:
    # (Edit: a minus to take one away, a grip to put them in your order -- the VPN goes on to
    # the first of them when its server stops answering)
    var change = RowEdit()
    tableGroup("", "Drag them in your order: when a server stops answering, the VPN goes to " &
                   "the first of these that can take it."):
      for n, i in list:
        let e = editRow(servers[i].name, n, detail = phoneSpeed(servers[i].key), key = servers[i].key)
        if e.kind != reNone: change = e
    case change.kind
    of reDelete:
      favs.delete(change.index)
      stateDirty = true
    of reMove:
      let k = favs[change.index]
      favs.delete(change.index)
      favs.insert(k, change.to)
      stateDirty = true
    else: discard
    return
  tableGroup(""):
    for i in list: serverRow(i)

proc recentLookups(): seq[tuple[app, name: string; count, agoMs: int]] =
  ## (the VPN's names looked up lately, the newest first: asked every 2 seconds at most)
  if ui.now - recentAt >= 2000:
    recentAt = ui.now
    recentNow = vpnRecent()
  for k in countdown(recentNow.high, 0): result.add recentNow[k]

proc blocked(name: string): bool =
  for b in blockLines(blockText):
    if b == name: return true

proc agoText(ms: int): string =
  let s = ms div 1000
  if s < 5: "now" elif s < 60: $s & " s ago" elif s < 3600: $(s div 60) & " min ago" else: $(s div 3600) & " h ago"

proc phoneActivity() =
  ## The names this phone looked up through the VPN, the newest first (a tap or a finger held on
  ## one: Block it, Copy it), or what reached what, as a graph.
  tableGroup(""):
    discard segmentRow(["Lookups", "Apps and Sites"], activityShown)
  if activityShown == 1:
    reachGraph()
    if reach.len == 0: pageNote("Turn the VPN on: each app comes here with the sites it reached.")
    return
  if vpnNow.state != vsOn and recentNow.len == 0:
    emptyState(pxGlobe, "No lookups yet", detail = "Turn the VPN on: the names this phone looks up " &
                                                   "come here, and you can block them.")
    discard recentLookups()
    return
  var shown = 0
  tableGroup("The Last Minutes", "A name blocked is answered \"no such name\" on the phone; its " &
                                 "subdomains too."):
    for r in recentLookups():
      if activityQuery.len > 0 and activityQuery.toLowerAscii notin r.name and
         activityQuery.toLowerAscii notin r.app.toLowerAscii: continue
      inc shown
      if shown > 120: break
      let isBlocked = blocked(r.name)
      let h = tableRow(r.name, agoText(r.agoMs),
                       subtitle = appWord(r.app) & (if r.count > 1: " · " & $r.count & " times" else: "") &
                                  (if isBlocked: " · blocked" else: ""),
                       glyph = if isBlocked: nfBan else: " ", tint = color(214, 60, 52),
                       key = "name:" & r.name & r.app)
      if h.clicked or h.menu:
        nameMenuName = r.name
        nameMenuOpen = true
  if shown == 0: pageNote("No name matches.")
  let isBlocked = blocked(nameMenuName)
  let acts = [if isBlocked: "Unblock" else: "Block " & nameMenuName, "Copy the Name"]
  case actionSheet(nameMenuOpen, nameMenuName, acts, destructive = (if isBlocked: -1 else: 0))
  of 0:
    var lines: seq[string]
    for l in blockText.splitLines:
      if l.strip.toLowerAscii != nameMenuName: lines.add l
    if not isBlocked: lines.add nameMenuName
    blockText = lines.filterIt(it.strip.len > 0).join("\n")
    stateDirty = true
    toast(if isBlocked: nameMenuName & ": unblocked" else: nameMenuName & ": blocked")
    if vpnNow.state == vsOn and vpnKey.len > 0: vpnStart(vpnKey)   # (the VPN takes it now)
  of 1:
    putClipboardText(nameMenuName)
    toast("Copied")
  else: discard

proc phoneMore() =
  if onAndroid():
    tableGroup("VPN", "Blocked names are answered \"no such name\" on the phone, sending nothing."):
      var n = 0
      for l in blockText.splitLines:
        if l.strip.len > 0 and not l.strip.startsWith("#"): inc n
      if tableRow("Block List", $n & " names", taChevron, glyph = nfBan, tint = color(214, 60, 52)).clicked:
        blockEdit = blockText
        blockOpen = true
      if tableRow("Android's VPN Settings", "", taChevron, glyph = nfCog, tint = color(128, 128, 136)).clicked:
        openSettingsPage("android.settings.VPN_SETTINGS")
  tableGroup("Your Servers"):
    if tableRow("Add a Server", "", taChevron).clicked: startEdit("")
    if tableRow("Import Servers", "", taChevron).clicked: importOpen = true
    if tableRow("Export Your Servers", "", taChevron).clicked: exportServers()
    if tableSwitch("Sort by Speed", sortBySpeed): stateDirty = true
  tableGroup(""):
    if tableRow("Appearance", "", taChevron).clicked: lookOpen = true
    if tableRow("How It Works", "", taChevron).clicked: helpOpen = true
    if tableRow("About Retro DNS", AppVersion, taChevron).clicked: aboutOpen = true

proc phonePage(tablet = false) =
  ## (the section's page on top, under its navigation bar; on a tablet, beside the list, the
  ## page's groups in from its sides)
  template nav: untyped = phoneNav[phoneSec]
  let title = case nav.page
              of "dns": (if tablet: "DNS" else: "Retro DNS")
              of "server":
                let i = indexOfKey(phoneDetail)
                if i >= 0: servers[i].name else: "Server"
              else: SectionInfo[phoneSec].name
  let back = if nav.atHome: "" else: SectionInfo[phoneSec].name
  let action = if nav.page == "servers": "Add"
               elif nav.page == "favourites" and favs.len > 0: (if favEditing: "Done" else: "Edit")
               else: ""
  # (the search bar right under the navigation bar, from one side to the other as it is, its box
  # in it as it was -- not in the page, where it stood in from the sides)
  let searchOn = nav.page in ["servers", "activity"]
  let g = ui.m.gap
  if searchOn: ui.m.gap = 0
  case navBar(title, back = back, action = action, done = favEditing)
  of npBack: discard nav.pop()
  of npAction:
    if nav.page == "favourites": favEditing = not favEditing
    else: startEdit("")
  of npNone: discard
  if searchOn:
    if nav.page == "servers": searchBar(query, "Search servers")
    else: searchBar(activityQuery, "Search names and apps")
    ui.m.gap = g
  pageView(nav):
    beginPanel(-1, "phone:" & $phoneSec & ":" & nav.page, plain = true)
    # (Servers and Favourites pulled down: every server tested again, its time on its row)
    if nav.page in ["servers", "favourites", "dns"] and pullRefresh(testing.len > 0): testAll(phoneFind())
    let m = if tablet: dp(24) else: 0
    if m > 0:
      let (fx, _) = layoutOrigin()
      pushFrame(rect(fx + m, layoutY() + dp(4), layoutWidth() - 2 * m, 0))
    case nav.page
    of "dns": phoneDns()
    of "servers": phoneServers()
    of "activity": phoneActivity()
    of "favourites": phoneFavourites()
    of "more": phoneMore()
    of "server": phoneServer()
    else: discard
    if m > 0: discard place(0, popFrame() + dp(12))
    endPanel()
  rowMenu()

proc phoneShell() =
  ## A phone in the Glass, Matte or Gloss look: a tab bar, a navigation bar, pages that slide
  ## in, the servers in rows in groups.
  var tabs: seq[(string, string)]
  let shown = sections()
  for s in shown: tabs.add (SectionInfo[s].glyph, SectionInfo[s].name)
  var sel = max(0, shown.find(phoneSec))
  if bottomNav(tabs, sel): phoneSec = shown[sel]
  phonePage()

proc tabletShell() =
  ## A tablet in the newer looks, as tablets showed their settings: the state and the sections
  ## in a list down the left under the app's navigation bar, the page of the one picked beside
  ## it under its own, a line between them.
  let top = ui.barY
  let h = ui.bottom - top
  let x0 = ui.winX + ui.safe.left
  let w = ui.w - ui.safe.left - ui.safe.right
  let mw = min(dp(330), w * 2 div 5)
  pushFrame(rect(x0, top, mw, h))
  discard navBar("Retro DNS")
  beginPanel(-1, "tablet:sections", plain = true)
  let (fx, _) = layoutOrigin()
  pushFrame(rect(fx + dp(8), layoutY() + dp(6), layoutWidth() - dp(16), 0))
  statusCard(small = true)
  connectButton()
  tableGroup(""):
    for s in sections():
      let (glyph, name, _, tint) = SectionInfo[s]
      let detail = case s
                   of secServers: $servers.len
                   of secFavourites: (if favs.len > 0: $favs.len else: "")
                   else: ""
      if tableRow(name, detail, taChevron, glyph = glyph, tint = tint, selected = phoneSec == s).clicked:
        if phoneSec == s: phoneNav[s].goHome() else: phoneSec = s
  discard place(0, popFrame() + dp(12))
  endPanel()
  discard popFrame()
  vline(x0 + mw, top, h, if lumaOfColor(ui.theme.window) < 128 or glossLook(): color(0, 0, 0)
                         else: mixColor(ui.theme.window, ui.theme.text, 0.2))
  pushFrame(rect(x0 + mw + 1, top, w - mw - 1, h))
  phonePage(tablet = true)
  discard popFrame()

proc shell() =
  if layoutWanted > 0 or (glassLook() and (isCompact() or ui.touch)):
    if layoutWanted == 1 or (layoutWanted == 0 and isCompact()): phoneShell() else: tabletShell()
    dialogs()
    return
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
  # (phones and tablets: the Gloss look until the user picks another, the app's own bars in the
  # newer looks -- the window's caption left out)
  appNavBars = true
  when defined(android) or defined(ios):
    uiLook = lookGloss
    ui.theme = GlossLight
  loadState()
  servers = builtinServers()
  createDir(appDir())
  for s in loadCustom(customPath()):
    if indexOfKey(s.key) < 0: servers.add s
  openApp(AppTitle, 1180, 760, id = AppId, icon = AppIconPng, look = LookKey, version = AppVersion)
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
    widgetWatch()
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

when not defined(retrodnsTest): main()      # (tests/test_dnsapp.nim draws its pages itself)

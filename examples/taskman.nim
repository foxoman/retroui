## Retro Task Manager -- what the computer is doing: every program with
## its share of the processor, the memory and the disk (end one, or it
## with all it started; give it another priority), the processor's, the
## memory's, the disks' and the network's graphs, the programs that start
## with the system, the network's connections, and the last week's
## history. What Argus taught about doing it lightly is here: the system
## is read on a thread of its own, the graphs move their picture instead
## of drawing it again, the lists draw only the rows on the screen, and
## the system is read less often while nobody looks.
##
## Linux, Windows, macOS, Termux (a BSD: what its Linux /proc shows); an
## Android app sees its own process, the memory, the storage, the network
## and the battery (Android shows an app no other).
##
##   nimble taskman                  (nim c -r -d:release examples/taskman.nim)
##   nimble taskmanapk               (an APK)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, algorithm, times, os, math, tables, sequtils]
import retroui
import retroui/[sysmon, system]

const
  AppTitle = "Retro Task Manager"
  AppVersion* = "1.0"
  AppId = "RetroTaskManager"
  IconPng = staticRead("assets/taskman-icon.png")

type
  Page = enum pgProcesses, pgPerformance, pgStartup, pgNetwork, pgHistory

const
  pageNames = ["Processes", "Performance", "Startup", "Network", "History"]
  speeds = [500, 1000, 4000]          ## (how often the system is read, ms)
  speedNames = ["&High (twice a second)", "&Normal (every second)",
                "&Low (every 4 seconds)", "&Paused"]

var
  page = pgProcesses
  query = ""
  sel = -1                             ## the row selected in the list shown
  selKey: tuple[pid: int; started: float] = (-1, 0.0)   ## ... the process it is
  sortCol = 2
  sortDesc = true
  shown: seq[ProcInfo]                 ## the processes in the list, sorted, filtered
  shownOf = -1.0                       ## (the sample they come from)
  speed = 1                            ## 0 high, 1 normal, 2 low, 3 paused
  perfSel = 0                          ## the resource on the Performance page
  perfListW = 230
  status = ""
  statusAt = 0.0
  askEnd = false
  askTree = false
  aboutOpen = false
  propsOpen = false
  propsOf: ProcInfo
  startup: seq[StartupItem]
  startupSel = 0
  startupRead = -1e9
  conns: seq[Connection]
  connsWhy = ""
  connsRead = -1e9
  connSel = 0
  names: Table[int, string]            ## the programs' names by their ids (for the connections)
  namesOf = -1
  histRange = 0                        ## 0 the last hour, 1 the day, 2 the week
  hist: seq[HistoryPoint]
  histLabels: seq[string]              ## (its times as text, made when it is read)
  histRead = -1e9
  histFile = ""
  lastRecorded = 0.0
  current: Sample                      ## the sample shown (kept while paused)
  sampleNo = 0                         ## grows with each new sample (the graphs move)
  recent: seq[HistoryPoint]            ## the last minutes, for the graphs
  procCols = @[column("Name", 190), numberColumn("PID", 64), numberColumn("CPU", 58),
               numberColumn("Memory", 86), numberColumn("Disk", 86), numberColumn("Threads", 62),
               column("User", 90), column("Status", 72)]
  phoneCols = @[column("Name", 150), numberColumn("CPU", 54), numberColumn("Memory", 78)]
  startCols = @[checkColumn("On", 36), column("Name", 180), column("Command", 320),
                column("For", 76)]
  connCols = @[column("Protocol", 70), column("Local", 180), column("Remote", 180),
               column("State", 96), column("Program", 150), numberColumn("PID", 60)]

const phoneOf = [0, 2, 3]              ## (the phone's columns: name, CPU, memory)

proc say(s: string) =
  status = s
  statusAt = epochTime()

proc interval(): int =
  ## How often the system is read: as asked, every 5 seconds while the app
  ## is put away (a phone) or paused -- nobody looks.
  if speed == 3 or ui.paused: 5000 else: speeds[speed]

# ---- the processes ------------------------------------------------------------------------------

proc stateName(c: char): string =
  case c
  of 'R': "Running"
  of 'S': "Sleeping"
  of 'D': "Waiting"
  of 'T', 't': "Stopped"
  of 'Z': "Ended"
  of 'I': "Idle"
  else: ""

proc pct(v: float): string =
  if v < 0: "" elif v < 0.05: "0" elif v < 10: formatFloat(v, ffDecimal, 1) else: $int(v + 0.5)

proc procCell(p: ProcInfo; col: int): string =
  case col
  of 0: p.name
  of 1: $p.pid
  of 2: pct(p.cpu)
  of 3: bytesText(p.memory)
  of 4: (if p.readRate + p.writeRate > 0: rateText(p.readRate + p.writeRate) else: "")
  of 5: (if p.threads > 0: $p.threads else: "")
  of 6: p.user
  else: stateName(p.state)

proc findSelected() =
  sel = -1
  for i, p in shown:
    if p.pid == selKey.pid and p.started == selKey.started: sel = i

proc sortShown() =
  let c = sortCol
  let d = sortDesc
  shown.sort(proc (a, b: ProcInfo): int =
    result = case c
             of 0: cmp(a.name.toLowerAscii, b.name.toLowerAscii)
             of 1: cmp(a.pid, b.pid)
             of 2: cmp(a.cpu, b.cpu)
             of 3: cmp(a.memory, b.memory)
             of 4: cmp(a.readRate + a.writeRate, b.readRate + b.writeRate)
             of 5: cmp(a.threads, b.threads)
             of 6: cmp(a.user, b.user)
             else: cmp(a.state, b.state)
    if result == 0: result = cmp(a.pid, b.pid)
    if d: result = -result)

proc refreshShown(s: Sample) =
  ## The list from a sample: filtered, sorted, the selection kept on the
  ## same process (an id is used again: with its start time).
  shown.setLen(0)
  if s == nil: return
  let q = query.strip.toLowerAscii
  for p in s.processes:
    if q.len == 0 or q in p.name.toLowerAscii or q in $p.pid or q in p.user.toLowerAscii or
       q in p.command.toLowerAscii:
      shown.add p
  sortShown()
  findSelected()
  shownOf = s.at

proc selected(): ProcInfo =
  if sel in 0 ..< shown.len: shown[sel] else: ProcInfo(pid: -1)

proc endSelected(tree: bool) =
  let p = selected()
  if p.pid < 0: return
  let err = if tree: endProcessTree(p) else: endProcess(p)
  say(if err.len == 0: (if tree: "Ended " & p.name & " and what it started" else: "Ended " & p.name)
      else: "Could not end " & p.name & ": " & err)

proc prioritize(nice: int) =
  let p = selected()
  if p.pid < 0: return
  let err = setPriority(p, nice)
  say(if err.len == 0: p.name & ": its priority changed" else: "Could not: " & err)

proc copyProcess(p: ProcInfo) =
  putClipboardText(p.name & "\t" & $p.pid & "\t" & pct(p.cpu) & "\t" & bytesText(p.memory) &
                   (if p.command.len > 0: "\t" & p.command else: ""))
  say("Copied: " & p.name)

proc showProperties(p: ProcInfo) =
  propsOf = p
  propsOpen = true

proc processKeys() =
  ## (the keys the menu shows: Delete, Ctrl+C, Alt+Enter -- not while
  ## typing in the search box)
  if not canInput() or ui.keyUsed or ui.takesText: return
  let p = selected()
  if p.pid < 0: return
  case ui.key
  of KeyDelete:
    askEnd = true
    ui.keyUsed = true
  of KeyC:
    if CtrlPressed in ui.mods:
      copyProcess(p)
      ui.keyUsed = true
  of KeyEnter:
    if AltPressed in ui.mods:
      showProperties(p)
      ui.keyUsed = true
  else: discard

proc processMenu() =
  let p = selected()
  if menuItem("&End task", "Del", enabled = p.pid >= 0): askEnd = true
  if menuItem("End process &tree", enabled = p.pid >= 0): askTree = true
  menuSeparator()
  submenu "Set &priority":
    for (name, nice) in [("&High", -10), ("&Above normal", -5), ("&Normal", 0),
                         ("&Below normal", 5), ("&Low", 10)]:
      if menuItem(name, checked = p.pid >= 0 and p.nice == nice, enabled = p.pid >= 0):
        prioritize(nice)
  menuSeparator()
  if menuItem("Open file &location", enabled = p.exe.len > 0): revealFile(p.exe)
  if menuItem("&Copy", "Ctrl+C", enabled = p.pid >= 0): copyProcess(p)
  if menuItem("P&roperties", "Alt+Enter", enabled = p.pid >= 0): showProperties(p)

proc processesPage(s: Sample) =
  let compact = isCompact()
  row:
    if searchBox(query, "Search processes", w = (if compact: 0 else: dp(260))):
      refreshShown(s)
    if not compact:
      spring()
      if button("&End task", enabled = sel in 0 ..< shown.len, w = dp(96)): askEnd = true
  var cols = if compact: phoneCols else: procCols
  let ev = grid(cols, shown.len,
                proc (r, c: int): string =
                  if r >= shown.len: ""
                  elif compact: procCell(shown[r], phoneOf[c])
                  else: procCell(shown[r], c),
                sel, height = -1, sortColumn = (if compact: max(0, phoneOf.find(sortCol)) else: sortCol),
                sortDescending = sortDesc, typeToEdit = false,
                style = proc (r, c: int): CellStyle =
                  # (a busy process: its CPU cell yellower the busier)
                  let col = if compact: phoneOf[c] else: c
                  if r < shown.len and col == 2 and shown[r].cpu >= 1:
                    let k = clamp(shown[r].cpu / 50, 0.0, 1.0)
                    CellStyle(bg: color(255, uint8(255 - int(k * 60)), uint8(200 - int(k * 130))))
                  else: CellStyle())
  if compact: phoneCols = cols else: procCols = cols
  if ev.selChanged and sel in 0 ..< shown.len:
    selKey = (shown[sel].pid, shown[sel].started)
  if ev.sorted:
    sortCol = if compact: phoneOf[clamp(ev.sortColumn, 0, phoneOf.high)] else: ev.sortColumn
    sortDesc = ev.sortDescending
    sortShown()
    findSelected()
  if ev.activated and sel in 0 ..< shown.len: showProperties(shown[sel])
  contextMenu: processMenu()
  if s != nil and not s.seesAll:
    label "This system shows an app its own processes only."

# ---- performance ---------------------------------------------------------------------------------

proc resources(s: Sample): seq[tuple[name, value: string]] =
  result.add ("CPU", pct(s.cpu) & " %")
  result.add ("Memory", bytesText(s.memUsed) & " / " & bytesText(s.memTotal))
  for d in s.disks: result.add ("Disk " & d.name, pct(d.busy) & " %")
  for n in s.nets: result.add ("Network " & n.name, rateText(n.rxRate + n.txRate))
  if s.battery >= 0: result.add ("Battery", $s.battery & " %" & (if s.charging: ", charging" else: ""))

proc detail(name, value: string) =
  row([140, -1]):
    label name
    label value, bold = true

proc uptimeText(t: float): string =
  let d = int(t) div 86400
  let h = (int(t) div 3600) mod 24
  let m = (int(t) div 60) mod 60
  (if d > 0: $d & " d " else: "") & align($h, 2, '0') & ":" & align($m, 2, '0') & ":" &
    align($(int(t) mod 60), 2, '0')

proc graphOf(pick: proc (p: HistoryPoint): float): seq[float] =
  ## (the last 60 values of one resource, oldest first)
  for i in max(0, recent.len - 60) ..< recent.len: result.add pick(recent[i])

proc topOf(values: openArray[float]; least: float): float =
  ## (the top of a graph of bytes a second: a power of two over the most,
  ## so the graph is drawn again only when the most goes past it)
  var most = least
  for v in values: most = max(most, v)
  pow(2.0, ceil(log2(most * 1.1)))

proc perfDetail(s: Sample; res: seq[tuple[name, value: string]]) =
  let name = res[perfSel].name
  heading name, 2
  if name == "CPU":
    liveGraph("cpu", graphOf(proc (p: HistoryPoint): float = max(0.0, p.cpu)), sampleNo,
              h = dp(150), label = "% Utilization", caption = "60 seconds")
    if s.cores.len > 1:
      # each core, small
      let per = min(s.cores.len, if isCompact(): 4 else: 8)
      let w = max(dp(40), (available() - (per - 1) * Gap) div per)
      var i = 0
      while i < s.cores.len:
        row:
          for k in i ..< min(i + per, s.cores.len):
            let ci = k
            liveGraph("core" & $ci, graphOf(proc (p: HistoryPoint): float =
                        (if ci < p.cores.len: max(0.0, p.cores[ci]) else: 0.0)),
                      sampleNo, w = w, h = dp(44), step = 2)
        i += per
    space()
    detail "Utilization", pct(s.cpu) & " %"
    var mhz = 0
    for c in s.cores: mhz = max(mhz, c.mhz)
    if mhz > 0: detail "Speed", formatFloat(mhz / 1000, ffDecimal, 2) & " GHz"
    detail "Processes", $s.processes.len
    if s.threadCount > 0: detail "Threads", $s.threadCount
    detail "Cores", $s.cores.len
    if s.uptime > 0: detail "Up time", uptimeText(s.uptime)
  elif name == "Memory":
    liveGraph("mem", graphOf(proc (p: HistoryPoint): float = p.memPercent), sampleNo,
              h = dp(150), color = color(150, 110, 255), label = "Memory in use",
              caption = bytesText(s.memTotal), fillUnder = true)
    space()
    detail "In use", bytesText(s.memUsed)
    detail "Available", bytesText(s.memAvailable)
    if s.memCached > 0: detail "Cached", bytesText(s.memCached)
    if s.swapTotal > 0: detail "Swap", bytesText(s.swapUsed) & " / " & bytesText(s.swapTotal)
    detail "Total", bytesText(s.memTotal)
  elif name.startsWith("Disk "):
    let dn = name[5 .. ^1]
    for d in s.disks:
      if d.name != dn: continue
      let vals = graphOf(proc (p: HistoryPoint): float = p.diskRate)
      liveGraph("disk", vals, sampleNo, maxValue = topOf(vals, 1048576), h = dp(150),
                color = color(90, 210, 90), label = "Read and written (every disk)",
                caption = rateText(d.readRate + d.writeRate))
      space()
      detail "Active time", pct(d.busy) & " %"
      detail "Reading", rateText(d.readRate)
      detail "Writing", rateText(d.writeRate)
    for v in s.volumes:
      detail v.path, bytesText(v.total - v.free) & " used of " & bytesText(v.total)
  elif name.startsWith("Network "):
    let nn = name[8 .. ^1]
    for n in s.nets:
      if n.name != nn: continue
      let vals = graphOf(proc (p: HistoryPoint): float = p.netRate)
      liveGraph("net", vals, sampleNo, maxValue = topOf(vals, 65536), h = dp(150),
                color = color(255, 170, 50), label = "Received and sent (every network)",
                caption = rateText(n.rxRate + n.txRate))
      space()
      detail "Receiving", rateText(n.rxRate)
      detail "Sending", rateText(n.txRate)
      detail "Received", bytesText(n.rxTotal)
      detail "Sent", bytesText(n.txTotal)
  else:
    progress(s.battery / 100)
    detail "Charge", $s.battery & " %"
    detail "Charging", (if s.charging: "yes" else: "no")

proc performancePage(s: Sample) =
  if s == nil:
    label "Reading the system..."
    return
  let res = resources(s)
  perfSel = clamp(perfSel, 0, res.high)
  var items: seq[string]
  for r in res: items.add r.name & "\t" & r.value
  if isCompact():
    discard combo(items.mapIt(it.replace("\t", "  ")), perfSel)
    perfDetail(s, res)
  else:
    split(perfListW, -1):
      discard listbox(items, perfSel, rows = -1, tabs = [dp(110)])
    do:
      perfDetail(s, res)

# ---- startup, network, history --------------------------------------------------------------------

proc startupPage() =
  if epochTime() - startupRead > 10:
    startup = startupItems()
    startupRead = epochTime()
  if startup.len == 0:
    paragraph "Nothing starts with the system here for this app to show (on a phone, " &
              "the system decides)."
    return
  let ev = grid(startCols, startup.len,
                proc (r, c: int): string =
                  if r >= startup.len: ""
                  else:
                    case c
                    of 0: (if startup[r].enabled: "1" else: "0")
                    of 1: startup[r].name
                    of 2: startup[r].command
                    else: (if startup[r].forAll: "Everyone" else: "You"),
                startupSel, height = -1, typeToEdit = false)
  proc flip(i: int) =
    let it = startup[i]
    let err = setStartupEnabled(it, not it.enabled)
    say(if err.len == 0: it.name & (if it.enabled: " no longer starts" else: " starts again") &
          " with the system"
        else: it.name & ": " & err)
    startupRead = -1e9
  if ev.toggled and ev.row in 0 ..< startup.len: flip(ev.row)
  contextMenu:
    let ok = startupSel in 0 ..< startup.len
    if menuItem(if ok and startup[startupSel].enabled: "&Disable" else: "&Enable",
                enabled = ok and startup[startupSel].canChange):
      flip(startupSel)
    if menuItem("Open file &location", enabled = ok and fileExists(startup[startupSel].where)):
      revealFile(startup[startupSel].where)

proc networkPage(s: Sample) =
  if epochTime() - connsRead > (if speed == 3: 1e9 else: 3.0):
    (conns, connsWhy) = connections()
    connsRead = epochTime()
  if connsWhy.len > 0:
    paragraph connsWhy
  if s != nil and namesOf != sampleNo:
    # (the programs' names by their ids: once a sample, not once a frame)
    namesOf = sampleNo
    names.clear()
    for p in s.processes: names[p.pid] = p.name
  discard grid(connCols, conns.len,
               proc (r, c: int): string =
                 if r >= conns.len: ""
                 else:
                   let k = conns[r]
                   case c
                   of 0: k.proto
                   of 1: k.local
                   of 2: k.remote
                   of 3: k.state
                   of 4: names.getOrDefault(k.pid)
                   else: (if k.pid >= 0: $k.pid else: ""),
               connSel, height = -1, typeToEdit = false)

proc historyPage() =
  let span = [3600.0, 86400.0, 7 * 86400.0][histRange]
  row:
    label "Show:"
    if combo(["The last hour", "The last day", "The last week"], histRange, w = dp(160)):
      histRead = -1e9
    spring()
  if epochTime() - histRead > 10:
    hist = loadHistory(histFile, epochTime() - span)
    histRead = epochTime()
    histLabels.setLen(0)
    let fmt = if histRange < 2: "HH:mm" else: "ddd HH:mm"
    for p in hist: histLabels.add fromUnixFloat(p.at).local.format(fmt)
  if hist.len < 2:
    paragraph "The history fills while Retro Task Manager runs (a point every 5 seconds, " &
              "kept for 7 days)."
    return
  lineChart([hist.mapIt(it.cpu.float), hist.mapIt(it.memPercent)], histLabels,
            names = ["CPU %", "Memory %"], h = max(dp(160), remainingH() div 2 - Gap),
            title = "Processor and memory")
  lineChart([hist.mapIt(it.diskRate / 1048576), hist.mapIt(it.netRate / 1048576)], histLabels,
            names = ["Disk MB/s", "Network MB/s"], h = max(dp(160), remainingH()),
            title = "Disks and network")

# ---- the window ------------------------------------------------------------------------------------

proc menus() =
  menubar:
    menu "&File":
      if menuItem("E&xit", "Alt+F4"): requestClose()
    menu "&Options":
      submenu "&Update speed":
        for i, n in speedNames:
          if menuItem(n, checked = speed == i):
            speed = i
            setMonitorInterval(interval())
    menu "&View":
      for p in Page:
        if menuItem("&" & pageNames[ord(p)], checked = page == p): page = p
    menu "&Help":
      if menuItem("&About Retro Task Manager..."): aboutOpen = true

proc dialogs() =
  case msgBox(askEnd, AppTitle, "End " & selected().name & "?\n\nWhat it has not saved is lost.",
              ["&End task", "Cancel"], miWarning)
  of 1: endSelected(false)
  else: discard
  case msgBox(askTree, AppTitle, "End " & selected().name & " and every program it started?",
              ["&End process tree", "Cancel"], miWarning)
  of 1: endSelected(true)
  else: discard
  dialog propsOpen, propsOf.name & " Properties", 460:
    detail "Process id", $propsOf.pid
    detail "Started by", $propsOf.ppid
    if propsOf.user.len > 0: detail "User", propsOf.user
    if propsOf.started > 0:
      detail "Started", fromUnixFloat(propsOf.started).local.format("yyyy-MM-dd HH:mm:ss")
    detail "Processor time", formatFloat(propsOf.cpuSeconds, ffDecimal, 1) & " s"
    detail "Memory", bytesText(propsOf.memory)
    if propsOf.threads > 0: detail "Threads", $propsOf.threads
    detail "Priority", $propsOf.nice
    if propsOf.exe.len > 0: detail "File", propsOf.exe
    if propsOf.command.len > 0:
      label "Command line:"
      paragraph propsOf.command
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): propsOpen = false
  aboutBox(aboutOpen, AppTitle, AppVersion,
           ["What the computer is doing: the programs, the processor, the memory, the disks, " &
            "the network, what starts with the system, and the last week.",
            "Copyright (c) 2026 Sultan Al Isaiee. MIT licence."],
           tagline = "What the computer is doing", iconPng = IconPng, glyph = pxGauge,
           credits = ["What Argus (github.com/Ray-lea/Argus) shows, and how lightly it " &
                      "does it, taught this one."])

proc takeNewSample() =
  ## (the newest sample, when there is one: the graphs move, the list
  ## follows; every 5 seconds a point of the history written)
  let s = latestSample()
  if s == nil or (current != nil and s.at == current.at): return
  if s.at - lastRecorded >= 5:
    appendHistory(histFile, s)
    lastRecorded = s.at
  if speed == 3 and current != nil: return          # (paused: what is shown stays)
  current = s
  recent = monitorHistory()
  inc sampleNo
  refreshShown(s)

proc taskmanFrame*() =
  ## One frame of the program (between `beginFrame` and `endFrame`).
  if stoppedFrame(): return
  captionBar()
  setMonitorInterval(interval())
  takeNewSample()
  let s = current
  menus()
  let portrait = isCompact()
  if portrait:
    var nav = ord(page)
    if bottomNav([(pxDetails, "Processes"), (pxChart, "Performance"), (pxApp, "Startup"),
                  (pxGlobe, "Network"), (pxHistory, "History")], nav):
      page = Page(nav)
  else:
    let cpuText = if s != nil and s.cpu >= 0: "CPU " & pct(s.cpu) & " %" else: ""
    let memText = if s != nil and s.memTotal > 0:
                    "Memory " & $int(s.memUsed.float * 100 / s.memTotal.float) & " %" else: ""
    statusbar((if status.len > 0 and epochTime() - statusAt < 6: status
               elif s != nil: "Processes: " & $s.processes.len
               else: "Reading the system..."),
              cpuText, memText,
              (if s != nil and s.stale: "Not read: the last numbers" elif speed == 3: "Paused" else: ""))
  guarded("Retro Task Manager " & AppVersion):
    if portrait:
      panel:
        case page
        of pgProcesses: processesPage(s)
        of pgPerformance: performancePage(s)
        of pgStartup: startupPage()
        of pgNetwork: networkPage(s)
        of pgHistory: historyPage()
    else:
      var p = ord(page)
      tabs p, pageNames:
        case Page(p)
        of pgProcesses: processesPage(s)
        of pgPerformance: performancePage(s)
        of pgStartup: startupPage()
        of pgNetwork: networkPage(s)
        of pgHistory: historyPage()
      page = Page(p)
  dialogs()
  if page == pgProcesses and not askEnd and not askTree and not propsOpen: processKeys()
  # (the next sample: a wake soon after it is due)
  wakeIn(max(100, interval() div 2))

proc taskmanStart*() =
  histFile = dataDir(AppId) / "history.bin"
  try: createDir(dataDir(AppId)) except OSError: discard
  startMonitor(interval())
  windowIcon = windowIconFromPng(IconPng)
  startApp(AppTitle, 780, 560)

proc taskmanStop*() =
  stopMonitor()
  stopApp()

proc main() =
  taskmanStart()
  while beginFrame():
    taskmanFrame()
    endFrame()
  taskmanStop()

when isMainModule and not declared(taskmanUnderTest): main()

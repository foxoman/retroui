## A tour of real apps, driven (RETRO_DRIVE) as a person would use them:
## each started for real -- its own window, the system's driver -- then
## on every tab it shows, the keyboard alone: Tab through every control
## (the focus moves on, reaches each one, Shift+Tab comes back), a
## drop-down opened with Enter and Alt+Down and closed with Esc, a check
## box ticked with Space and back; every menu of its menu bar opened, its
## dialogs ("...") opened and closed with Esc; the app asked after each
## step that it is still there; at the end closed by its close box.
##
## A crash, the app gone, or the "stopped" screen fails it; what does not
## work as it should (a focus that sticks, a dialog Esc leaves open) is a
## finding, listed -- and fails it too with --strict.
##
##   nim c -d:release -o:build/tour tests/drive/tour.nim
##   xvfb-run -a build/tour build/smoke/gallery build/smoke/notepad
##   build/tour --port 7000 --name Gallery     (an app started already:
##                                              Android's, through adb forward)
##   build/tour --quick ...                    (tabs and menus only)
##
## Each app it starts runs in a home of its own (its settings and faults there).

import std/[os, osproc, json, net, strtabs, strutils, sets, times, monotimes]
import retroui/driveclient

proc freePort(): int =
  ## (a port no one listens on now)
  let s = newSocket()
  s.bindAddr(Port(0), "127.0.0.1")
  result = int(s.getLocalAddr()[1])
  s.close()

type
  Gone = object of CatchableError        ## the app is not there any more
  Tour = object
    app: DriveClient
    name: string
    steps: int
    findings: seq[string]
    alive: proc (): bool
    quick: bool

const
  # (roles the Tab key stops at: one stop each -- a list's items, a tab
  # strip's tabs, a grid's cells are reached with the arrows)
  TabStops = ["button", "toggleButton", "checkBox", "radioButton", "textField",
              "textArea", "passwordField", "comboBox", "slider", "spinButton", "list",
              "tree", "table", "link"]
  # (menu items that are not tried: they end, change or send something)
  Risky = ["exit", "quit", "delete", "remove", "close", "log off", "log out", "sign",
           "send", "empty", "erase", "format", "restart", "shut", "install", "update",
           "window", "reset", "clear", "purge", "wipe", "lock", "end task", "end process",
           "kill", "print", "share", "upload", "download", "connect", "camera",
           "record", "scan", "call"]

let verbose = getEnv("TOUR_VERBOSE").len > 0

proc ask(t: var Tour; req: JsonNode): JsonNode =
  inc t.steps
  try: result = t.app.ask(req, timeoutMs = 30000)
  except DriveError as e:
    raise newException(Gone, "no answer (" & e.msg & ")")
  if not t.alive(): raise newException(Gone, "its process ended")

proc cmd(t: var Tour; words: varargs[string]): JsonNode = t.ask(request(@words))

proc finding(t: var Tour; s: string) =
  if s notin t.findings:
    t.findings.add s
    echo "  finding: ", s

proc desc(n: JsonNode): string =
  var role = n{"role"}.getStr
  result = role & (if n{"name"}.getStr.len > 0: " \"" & n{"name"}.getStr & "\"" else:
                   " at " & $n{"x"}.getInt & "," & $n{"y"}.getInt)

proc hasState(n: JsonNode; s: string): bool =
  if n == nil or not n.hasKey("states"): return false
  for x in n["states"]:
    if x.getStr == s: return true

var focusWithin: seq[BiggestInt]
  ## (the ids of what the focused node is in, as the last `focused` saw it)

proc focused(t: var Tour): JsonNode =
  let r = t.cmd("info")
  focusWithin.setLen(0)
  if r{"within"} != nil:
    for x in r["within"]: focusWithin.add x.getBiggestInt
  r{"focused"}

proc byId(t: var Tour; id: BiggestInt): JsonNode =
  let r = t.ask(%*{"cmd": "find", "node": id})
  if r{"ok"}.getBool: r["node"] else: nil

proc dialogOpen(t: var Tour): JsonNode =
  let r = t.ask(%*{"cmd": "find", "role": "dialog"})
  if r{"ok"}.getBool: r["node"] else: nil

proc keyOn(t: var Tour; n: JsonNode) =
  ## (what the keyboard does on one control: a drop-down opened and
  ## closed, a check box ticked and back -- the focus kept)
  let id = n{"id"}.getBiggestInt
  let role = if n.hasState("expandable") and n{"role"}.getStr == "textField": "comboBox"
             else: n{"role"}.getStr        # (an editable drop-down: a box with a list)
  case role
  of "comboBox":
    for k in ["Enter", "alt+Down"]:
      discard t.cmd("key", k)
      let opened = t.byId(id)
      if opened == nil:
        t.finding(t.name & ": " & desc(n) & ": gone after " & k)
        return
      if not opened.hasState("expanded"):
        t.finding(t.name & ": " & desc(n) & ": " & k & " does not open it")
        continue
      discard t.cmd("key", "Escape")
      let closed = t.byId(id)
      if closed == nil or closed.hasState("expanded"):
        t.finding(t.name & ": " & desc(n) & ": Esc does not close it")
        discard t.cmd("key", "Escape")
      elif not closed.hasState("focused"):
        t.finding(t.name & ": " & desc(n) & ": Esc takes the focus from it")
  of "checkBox":
    let before = n.hasState("checked")
    discard t.cmd("key", "Space")
    let after = t.byId(id)
    if after == nil: return
    if after.hasState("checked") == before:
      t.finding(t.name & ": " & desc(n) & ": Space does not tick it")
    else:
      discard t.cmd("key", "Space")       # (back as it was)
  else: discard

proc tabWalk(t: var Tour; page: string) =
  ## (Tab through the page: every stop reached once, the focus never stuck)
  let tree = t.cmd("tree")
  var stops: seq[JsonNode]
  var dialog = false
  let nodes = tree["nodes"]
  proc inside(n: JsonNode): bool =
    ## (in a list, a grid, a tree, a bar: reached with the arrows, not Tab)
    var p = n{"parent"}.getInt(-1)
    var guard = 0
    while p >= 0 and p < nodes.len and guard < 64:
      if nodes[p]{"role"}.getStr in ["table", "list", "tree", "toolBar", "menuBar", "statusBar",
                                      "tabList", "menu", "row"]: return true
      p = nodes[p]{"parent"}.getInt(-1)
      inc guard
  for n in nodes:
    if n{"role"}.getStr == "dialog": dialog = true
    if n{"role"}.getStr in TabStops and n.hasState("focusable") and not n.hasState("disabled") and
       not inside(n):
      stops.add n
  if dialog or stops.len < 2: return       # (one stop: Tab stays on it, rightly)
  if t.focused() == nil:
    # (an app whose keys are its canvas's until a control is clicked --
    # Tab hides its panels then --: the first control given the focus, as
    # a screen reader would)
    discard t.ask(%*{"cmd": "focus", "node": stops[0]{"id"}.getBiggestInt})
  var seen = initHashSet[BiggestInt]()
  var holders = initHashSet[BiggestInt]()      # (what the focus was in)
  var order: seq[BiggestInt]
  var places: seq[JsonNode]        # (where the focus was: an item of a list reaches the list)
  var stuck = 0
  var last: BiggestInt = -1
  let rounds = min(stops.len * 2 + 4, 120)
  for _ in 0 ..< rounds:
    discard t.cmd("key", "Tab")
    let f = t.focused()
    if verbose: echo "    Tab -> ", (if f == nil: "nothing" else: desc(f) & " " & $f{"id"}.getBiggestInt)
    if f == nil: continue
    let id = f{"id"}.getBiggestInt
    if id == last:
      inc stuck
      if stuck == 3:
        t.finding(t.name & " (" & page & "): Tab is stuck on " & desc(f))
        break
      continue
    stuck = 0
    last = id
    for w in focusWithin: holders.incl w           # (a list's item: the list reached)
    if id in seen:
      if order.len > 0 and id == order[0]: break     # (round once)
      continue
    seen.incl id
    order.add id
    places.add f
    if f{"name"}.getStr.strip.len == 0 and f{"role"}.getStr in TabStops:
      t.finding(t.name & " (" & page & "): " & desc(f) & " has no name (screen readers " &
                "and drivers cannot tell it)")
    if not t.quick: t.keyOn(f)
    if t.dialogOpen() != nil:
      t.finding(t.name & " (" & page & "): the keys on " & desc(f) & " left a dialog open")
      discard t.cmd("key", "Escape")
  proc within(a, b: JsonNode): bool =
    a{"x"}.getInt >= b{"x"}.getInt and a{"y"}.getInt >= b{"y"}.getInt and
      a{"x"}.getInt + a{"w"}.getInt <= b{"x"}.getInt + b{"w"}.getInt and
      a{"y"}.getInt + a{"h"}.getInt <= b{"y"}.getInt + b{"h"}.getInt
  for n in stops:
    let id = n{"id"}.getBiggestInt
    var reached = id in seen or id in holders
    for f in places:
      if within(f, n): reached = true
    if n{"role"}.getStr == "radioButton":
      # (a group of radio buttons is one stop: the arrows move in it)
      for m in nodes:
        if m{"role"}.getStr == "radioButton" and m{"parent"}.getInt == n{"parent"}.getInt and
           m{"id"}.getBiggestInt in seen:
          reached = true
    if not reached and n{"w"}.getInt > 0 and n{"h"}.getInt > 0:
      # (one the walk did not reach: still there and still a stop?)
      let now = t.byId(id)
      if now != nil and now.hasState("focusable") and not now.hasState("disabled"):
        t.finding(t.name & " (" & page & "): Tab never reaches " & desc(n))
  # Shift+Tab goes back the way Tab came
  if order.len >= 3:
    let here = t.focused()
    if here != nil:
      let at = order.find(here{"id"}.getBiggestInt)
      discard t.cmd("key", "shift+Tab")
      let back = t.focused()
      if at > 0 and back != nil and back{"id"}.getBiggestInt != order[at - 1] and
         back{"id"}.getBiggestInt != here{"id"}.getBiggestInt:
        discard          # (a stop that is a group: the way back may land in it)
      elif back != nil and back{"id"}.getBiggestInt == here{"id"}.getBiggestInt:
        t.finding(t.name & " (" & page & "): Shift+Tab does not move from " & desc(here))

proc menuDialogs(t: var Tour; menu: int): int =
  ## (the menu's "..." items that open a dialog: each opened and closed with Esc)
  var r = t.ask(%*{"cmd": "click", "role": "menu", "nth": menu})
  if not r{"ok"}.getBool: return
  let menuName = r{"node"}{"name"}.getStr
  var items: seq[string]
  for n in t.cmd("tree")["nodes"]:
    if n{"role"}.getStr == "menuItem" and n{"name"}.getStr.endsWith("...") and
       not n.hasState("disabled") and not n.hasState("expandable"):
      let low = n{"name"}.getStr.toLowerAscii
      var risky = false
      for w in Risky:
        if w in low: risky = true
      if not risky: items.add n{"name"}.getStr
  discard t.cmd("key", "Escape")
  discard t.cmd("key", "Escape")
  for item in items:
    r = t.ask(%*{"cmd": "click", "role": "menu", "nth": menu})
    if not r{"ok"}.getBool: continue
    r = t.ask(%*{"cmd": "click", "name": item, "role": "menuItem"})
    if not r{"ok"}.getBool:
      discard t.cmd("key", "Escape")
      discard t.cmd("key", "Escape")
      continue
    r = t.ask(%*{"cmd": "wait", "role": "dialog", "timeout": 1500})
    if not r{"ok"}.getBool:
      # (not a dialog of the kit's: something else -- a page, a pane)
      discard t.cmd("key", "Escape")
      continue
    inc result
    let dlg = r["node"]{"name"}.getStr
    discard t.cmd("key", "Tab")
    discard t.cmd("key", "Escape")
    r = t.ask(%*{"cmd": "wait", "role": "dialog", "gone": true, "timeout": 1500})
    if not r{"ok"}.getBool:
      t.finding(t.name & ": " & menuName & " > " & item & ": Esc does not close \"" & dlg & "\"")
      for b in ["Cancel", "Close", "OK", "No"]:
        if t.ask(%*{"cmd": "click", "name": b, "role": "button"}){"ok"}.getBool: break

proc walk(t: var Tour): string =
  ## The tour of an app already connected; "" when it went well.
  var r = t.ask(%*{"cmd": "find", "name": "stopped the last time", "role": "label"})
  if r{"ok"}.getBool: return "it shows the \"stopped\" screen at its start"
  r = t.cmd("tree")
  var tabs, menus = 0
  for n in r["nodes"]:
    if n{"role"}.getStr == "tab": inc tabs
    elif n{"role"}.getStr == "menu": inc menus
  # the first page as it opens, then every tab
  t.tabWalk("its start")
  var clicked = 0
  for i in 0 ..< tabs:
    r = t.ask(%*{"cmd": "click", "role": "tab", "nth": i})
    if r{"ok"}.getBool:
      inc clicked     # (one out of sight -- tabs that scroll -- is left)
      t.tabWalk(r["node"]{"name"}.getStr)
  # every menu of its menu bar, opened and closed, its dialogs
  var opened, dialogs = 0
  for i in 0 ..< menus:
    r = t.ask(%*{"cmd": "click", "role": "menu", "nth": i})
    if r{"ok"}.getBool:
      inc opened
      discard t.cmd("key", "Escape")
      discard t.cmd("key", "Escape")     # (and the menu bar)
      if not t.quick: dialogs += t.menuDialogs(i)
  discard t.cmd("info")
  echo t.name, ": ", clicked, " of ", tabs, " tabs, ", opened, " of ", menus, " menus, ",
       dialogs, " dialogs, ", t.steps, " steps, ", t.findings.len, " findings"
  ""

proc tour(exe: string; quick: bool; findings: var seq[string]): string =
  ## Start `exe` in a home of its own and tour it; "" when it went well.
  let name = exe.splitFile.name
  let home = getTempDir() / "retro-tour-" & name & "-" & $getCurrentProcessId()
  createDir(home)
  defer: removeDir(home)
  let port = freePort()
  var env = newStringTable()
  for k, v in envPairs(): env[k] = v
  for k in ["HOME", "USERPROFILE"]: env[k] = home
  env["APPDATA"] = home / "AppData" / "Roaming"
  env["LOCALAPPDATA"] = home / "AppData" / "Local"
  env["XDG_CONFIG_HOME"] = home / ".config"
  env["XDG_DATA_HOME"] = home / ".local" / "share"
  env["XDG_CACHE_HOME"] = home / ".cache"
  env["RETRO_DRIVE"] = $port
  let p = startProcess(exe, env = env, options = {poParentStreams})
  defer:
    if p.running:
      sleep(3000)
      if p.running: p.kill()
    p.close()
  var t = Tour(name: name, quick: quick)
  try: t.app = driveConnect(port, timeoutMs = 90000, probe = true)
  except DriveError as e: return "it did not start: " & e.msg
  defer: t.app.close()
  t.alive = proc (): bool = p.running
  let t0 = getMonoTime()
  try:
    result = t.walk()
  except Gone as e:
    result = "it ended after " & $t.steps & " steps: " & e.msg
  findings.add t.findings
  if result.len > 0: return
  echo name, ": ", (getMonoTime() - t0).inSeconds, " s"
  # closed as a person closes it
  try: discard t.cmd("quit")
  except Gone: discard
  for _ in 0 ..< 50:
    if not p.running: break
    sleep(100)
  if p.running: echo name, ": still open after its close box (it may ask to save): stopped"
  elif p.peekExitCode > 2: return "it stopped with exit code " & $p.peekExitCode

proc tourPort(port: int; name: string; quick: bool; findings: var seq[string]): string =
  ## Tour an app started already (Android's, through adb forward).
  var t = Tour(name: name, quick: quick)
  try: t.app = driveConnect(port, timeoutMs = 60000)
  except DriveError as e: return "no app on port " & $port & ": " & e.msg
  defer: t.app.close()
  t.alive = proc (): bool = true
  try: result = t.walk()
  except Gone as e: result = "it ended after " & $t.steps & " steps: " & e.msg
  findings.add t.findings

when isMainModule:
  var failed = 0
  var findings: seq[string]
  var quick, strict = false
  var port = 0
  var name = "app"
  var exes: seq[string]
  let args = commandLineParams()
  var i = 0
  while i < args.len:
    case args[i]
    of "--quick": quick = true
    of "--strict": strict = true
    of "--port":
      inc i
      port = parseInt(args[i])
    of "--name":
      inc i
      name = args[i]
    else: exes.add args[i]
    inc i
  if port > 0:
    let why = tourPort(port, name, quick, findings)
    if why.len > 0:
      echo name, ": FAILED: ", why
      inc failed
  for exe in exes:
    echo "== ", exe
    let why = tour(exe, quick, findings)
    if why.len > 0:
      echo exe.splitFile.name, ": FAILED: ", why
      inc failed
  if findings.len > 0:
    echo "\n", findings.len, " findings:"
    for f in findings: echo "  ", f
  quit(if failed > 0 or (strict and findings.len > 0): 1 else: 0)

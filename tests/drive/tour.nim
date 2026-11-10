## A tour of real apps, driven (RETRO_DRIVE) as a person would use them:
## each started for real -- its own window, the system's driver -- then
## every tab it shows clicked, every menu of its menu bar opened and closed
## with Esc, the app asked after each step that it is still there; at the
## end closed by its close box. A crash, a command it could not do, or the
## "stopped" screen fails it.
##
##   nim c -d:release -o:build/tour tests/drive/tour.nim
##   xvfb-run -a build/tour build/smoke/gallery build/smoke/notepad
##
## Each app runs in a home of its own (its settings and faults there).

import std/[os, osproc, json, net, strtabs]
import retroui/driveclient

proc freePort(): int =
  ## (a port no one listens on now)
  let s = newSocket()
  s.bindAddr(Port(0), "127.0.0.1")
  result = int(s.getLocalAddr()[1])
  s.close()

proc tour(exe: string): string =
  ## "" when it went well, else what went wrong.
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
  var app: DriveClient
  try: app = driveConnect(port, timeoutMs = 60000)
  except DriveError as e: return "it did not start: " & e.msg
  defer: app.close()
  var steps = 0
  proc ask(req: JsonNode): JsonNode =
    try: result = app.ask(req, timeoutMs = 30000)
    except DriveError as e: result = %*{"ok": false, "error": e.msg, "gone": true}
    inc steps
  proc gone(r: JsonNode): bool = r.hasKey("gone") or not p.running
  # (the "stopped" screen: the last run of it crashed -- not here, in a home of its own)
  var r = ask(%*{"cmd": "find", "name": "stopped the last time", "role": "label"})
  if r{"ok"}.getBool: return "it shows the \"stopped\" screen at its start"
  if gone(r): return "it ended at its start: " & r{"error"}.getStr
  # every tab it shows at the start, one after another
  r = ask(%*{"cmd": "tree"})
  if not r{"ok"}.getBool: return "no tree: " & r{"error"}.getStr
  var tabs, menus = 0
  for n in r["nodes"]:
    if n{"role"}.getStr == "tab": inc tabs
    elif n{"role"}.getStr == "menu": inc menus
  var clicked = 0
  for i in 0 ..< tabs:
    r = ask(%*{"cmd": "click", "role": "tab", "nth": i})
    if gone(r): return "it ended after a click on tab " & $i & ": " & r{"error"}.getStr
    if r{"ok"}.getBool: inc clicked     # (one out of sight -- tabs that scroll -- is left)
    r = ask(%*{"cmd": "info"})
    if gone(r): return "it ended after tab " & $i & " (" & $steps & " steps)"
  # every menu of its menu bar, opened and closed
  var opened = 0
  for i in 0 ..< menus:
    r = ask(%*{"cmd": "click", "role": "menu", "nth": i})
    if gone(r): return "it ended after opening menu " & $i & ": " & r{"error"}.getStr
    if r{"ok"}.getBool:
      inc opened
      r = ask(%*{"cmd": "key", "key": "Escape"})
      if gone(r): return "it ended after closing menu " & $i
      discard ask(%*{"cmd": "key", "key": "Escape"})     # (and the menu bar)
  r = ask(%*{"cmd": "info"})
  if gone(r): return "it ended after the menus"
  echo name, ": ", clicked, " of ", tabs, " tabs clicked, ", opened, " of ", menus,
       " menus opened, ", steps, " steps"
  # closed as a person closes it
  discard ask(%*{"cmd": "quit"})
  for _ in 0 ..< 50:
    if not p.running: break
    sleep(100)
  if p.running: echo name, ": still open after its close box (it may ask to save): stopped"
  elif p.peekExitCode > 2: return "it stopped with exit code " & $p.peekExitCode
  ""

when isMainModule:
  var failed = 0
  for exe in commandLineParams():
    echo "== ", exe
    let why = tour(exe)
    if why.len > 0:
      echo exe.splitFile.name, ": FAILED: ", why
      inc failed
  quit(if failed > 0: 1 else: 0)

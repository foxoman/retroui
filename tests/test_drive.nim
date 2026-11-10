## The driver (RETRO_DRIVE): a program on the same machine finds the
## controls by name and clicks, types, presses keys and waits, as a person
## would, and each answer comes once the app has done it -- here the test is
## the app and the other end at once, its frames run while it waits.

import std/[json, strutils]
import retroui
import retroui/driveclient
import retroui/uirelays/[input, access]
import harness

fakeDriver()
startApp("Driven", W, H)

var name = "World"
var greeted = ""
var plan = 0
var news = false
var level = 3
var showSaved = false
var lastKey = ""
var closing = false

view = proc () =
  row([60, -1]):
    label "&Name:"
    edit name
  row:
    if button("&Greet", isDefault = true): greeted = "Hello, " & name & "!"
    if button("&Save"): showSaved = true
  combo(["Free", "Pro", "Business"], plan)
  checkbox("Send me &news", news)
  slider(level, 0, 10)
  label greeted
  if showSaved: label "Saved"
  if ui.key == KeyF5 and CtrlPressed in ui.mods: lastKey = "ctrl+F5"
  if closeRequested(): closing = true

run(2)
let port = startDriver(0)
doAssert port > 0 and drivePort() == port
run(2)

let app = driveConnect(port)
proc ask(words: varargs[string]): JsonNode =
  result = app.ask(request(@words), timeoutMs = 10000, idle = proc () = run())
proc askJson(j: JsonNode): JsonNode =
  app.ask(j, timeoutMs = 10000, idle = proc () = run())

block words:
  doAssert request(["click", "OK", "--role", "button"]) ==
           %*{"cmd": "click", "name": "OK", "role": "button"}
  doAssert request(["click", "10,20", "--right"]) ==
           %*{"cmd": "click", "x": 10, "y": 20, "button": "right"}
  doAssert request(["set", "Name:", "Ada", "Lovelace"]) ==
           %*{"cmd": "set", "name": "Name:", "value": "Ada Lovelace"}
  doAssert request(["wait", "250"]) == %*{"cmd": "wait", "ms": 250}
  doAssert request(["wait", "Saved", "--timeout=900"]) ==
           %*{"cmd": "wait", "name": "Saved", "timeout": 900}
  var k: KeyCode
  var m: set[Modifier]
  doAssert parseKey("ctrl+shift+s", k, m) and k == KeyS and m == {CtrlPressed, ShiftPressed}
  doAssert parseKey("Escape", k, m) and k == KeyEsc and m == {}
  doAssert not parseKey("hyper+x", k, m)
  doAssert parseRoles("button|text field") == {arButton, arTextField}

block tree:
  let r = ask("tree")
  doAssert r["ok"].getBool, $r
  var names: seq[string]
  for n in r["nodes"]: names.add n["name"].getStr
  doAssert "Greet" in names and "Name:" in names, $names
  let info = ask("info")
  doAssert info["w"].getInt == W and info["h"].getInt == H
  # a name with no role: the box the label names, not the label
  doAssert ask("find", "Name:")["node"]["role"].getStr == "textField"
  doAssert ask("find", "Name:", "--role", "label")["node"]["role"].getStr == "label"

block typing:
  doAssert ask("click", "Name:", "--role", "textField")["ok"].getBool
  doAssert ask("key", "ctrl+a")["ok"].getBool
  let r = ask("type", "Ada Lovelace — آدا")
  doAssert r["ok"].getBool, $r
  doAssert name == "Ada Lovelace — آدا", name
  let f = ask("find", "Name:", "--role", "textField")
  doAssert f["node"]["value"].getStr == name, $f

block clicking:
  let r = ask("click", "Greet")
  doAssert r["ok"].getBool and r["node"]["name"].getStr == "Greet", $r
  doAssert greeted == "Hello, Ada Lovelace — آدا!", greeted
  # the next command sees what it did
  doAssert ask("find", "Hello", "--role", "label")["ok"].getBool
  # by a point, as the inspector shows them
  let s = ask("find", "Save")["node"]
  doAssert ask("click", $(s["x"].getInt + 4) & "," & $(s["y"].getInt + 4))["ok"].getBool
  doAssert showSaved

block screenReaderWay:
  doAssert ask("press", "Send me news")["ok"].getBool
  doAssert news
  # (the slider has no name: the first slider)
  doAssert askJson(%*{"cmd": "set", "role": "slider", "value": 7})["ok"].getBool
  doAssert level == 7, $level
  doAssert ask("focus", "Greet")["ok"].getBool
  doAssert ask("info")["focused"]["name"].getStr == "Greet"

block keys:
  doAssert ask("key", "ctrl+F5")["ok"].getBool
  doAssert lastKey == "ctrl+F5"
  # the drop-down opened by Enter past the default button (#9), by keys alone
  doAssert ask("focus", "", "--role", "comboBox")["ok"].getBool
  doAssert ask("key", "Enter")["ok"].getBool
  doAssert ask("key", "Down")["ok"].getBool
  doAssert ask("key", "Enter")["ok"].getBool
  doAssert plan == 1, $plan
  doAssert greeted == "Hello, Ada Lovelace — آدا!", "and Enter did not greet again"

block waiting:
  showSaved = false
  run(2)
  let t0 = ticks
  let r = ask("wait", "Saved", "--timeout", "300")
  doAssert not r["ok"].getBool and "not there" in r["error"].getStr, $r
  doAssert ticks - t0 >= 300
  showSaved = true
  doAssert ask("wait", "Saved")["ok"].getBool
  showSaved = false
  doAssert ask("wait", "Saved", "--gone")["ok"].getBool
  doAssert ask("wait", "--frames", "3")["ok"].getBool

block errors:
  let r = ask("click", "Nothing like it")
  doAssert not r["ok"].getBool and "no control" in r["error"].getStr
  doAssert not ask("click", "9999,10")["ok"].getBool
  doAssert not ask("key", "hyper+x")["ok"].getBool
  doAssert not askJson(%*{"cmd": "fly"})["ok"].getBool
  doAssert app.ask(%*{"cmd": "info", "id": "mine"}, idle = proc () = run())["id"].getStr == "mine"

block quitting:
  doAssert ask("quit")["ok"].getBool
  run(2)
  doAssert closing, "the close box, as a person clicks it"

app.close()
echo "driver tests passed"

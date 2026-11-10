## The inspector (F12): it says why each frame ran -- the input, or the line
## that asked for it (`ui.redraw = true`, `wakeIn`) -- and what the next one
## waits for, finds the control under the mouse and by its name, and draws
## its panel over the app without taking its clicks.
##
## INSPECT_SHOT=file.png saves a picture of it over a small form.

import std/[os, strutils]
import retroui
import retroui/uirelays/[input, access]
import harness

fakeDriver()
startApp("Inspector", W, H)

var name = "World"
var clicks = 0
var wantWake = false
var wantRedraw = false
var causes: seq[string]                         # (each frame's, as its view saw it)
var withEdit = true
proc lineOf(s: string): int =
  ## (the line of this file `s` is on)
  var n = 0
  for l in readFile(currentSourcePath()).splitLines:
    inc n
    if s in l and "lineOf" notin l: return n
let wakeLine = lineOf("if wantWake: wakeIn(500)")
let redrawLine = lineOf("    ui.redraw = true")

view = proc () =
  causes.add frameCause
  row([60, -1]):
    label "&Name:"
    if withEdit: edit name
  if wantWake: wakeIn(500)
  if button("&Greet", isDefault = true): inc clicks
  label "Hello"
  if wantRedraw:
    wantRedraw = false
    ui.redraw = true

run(2)
let plain = @pixels

block shown:
  showInspector(true)
  doAssert inspectorShown() and whyFrames and accessKeep
  run(2)
  var changed = 0
  for i in 0 ..< W * H:
    if pixels[i] != plain[i]: inc changed
  doAssert changed > 1000, "its panel is drawn over the app: " & $changed
  if getEnv("INSPECT_SHOT").len > 0:
    move(40, 60)
    run(2)
    var b = newBitmap(W, H)
    for i in 0 ..< W * H: b.px[i] = pixels[i] or 0xFF000000'u32
    b.changed()
    discard savePng(b, getEnv("INSPECT_SHOT"))

proc saw(s: string): bool =
  for c in causes:
    if s in c: return true

block why:
  causes.setLen(0)
  key(KeyTab)
  run()
  doAssert saw("1 input event") or saw("input events"), $causes
  # a timer: its line (no caret blinking: it would wake first)
  withEdit = false
  ticks += 1000
  run(2)
  wantWake = true
  run()
  wantWake = false
  causes.setLen(0)
  ticks += 600
  run()
  doAssert saw("wakeIn at test_inspect.nim:" & $wakeLine), $causes
  withEdit = true
  # a redraw asked: its line
  causes.setLen(0)
  wantRedraw = true
  run(3)
  doAssert saw("ui.redraw = true at test_inspect.nim:" & $redrawLine), $causes

block findAndPoint:
  let b = findNode(accessLast, "Greet", {arButton})
  doAssert b > 0
  let r = nodeRect(accessLast[b])
  doAssert nodeAt(accessLast, r.x + 3, r.y + 3) == b, "the button under the mouse"
  doAssert nodeLine(accessLast[b]) == "Button \"Greet\""
  let e = findNode(accessLast, "name", {arTextField})
  doAssert e > 0 and accessLast[e].value == "World", "a text box by its label, its value"
  doAssert findNode(accessLast, "", {arLabel}, 1) > 0, "the second label"
  doAssert findNode(accessLast, "Nothing here") == -1
  # its clicks still reach the app under the panel's side
  click(r, dx = r.w div 2)
  run(2)
  doAssert clicks == 1

block f12:
  key(KeyF12)
  run(2)
  doAssert not inspectorShown(), "F12 hides it"
  var same = 0
  for i in 0 ..< W * H:
    if pixels[i] == plain[i]: inc same
  doAssert same > W * H * 9 div 10, "hidden: the app as it was"
  key(KeyF12)
  run(2)
  doAssert inspectorShown(), "F12 shows it again"

echo "inspector tests passed"

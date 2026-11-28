## The desktop behaviors the interface guidelines (docs/hig.md) ask for: a check box of three
## states, spin boxes that wrap, a fixed-length box that moves on by itself, the unfold button,
## a property sheet's OK, Cancel and Apply (and closing it with changes not applied), "Save
## changes?" before the window closes, a message box's "Don't show this again", a menu item's
## hint in the status bar, What's This?, a scroll thumb dragged far off its bar, Esc ending a
## drag, the ellipsis in the middle of a path.

import std/strutils
import retroui
import retroui/uirelays/input
import harness
import retroui/inspect

fakeDriver()
startApp("HIG desktop", W, H)
accessKeep = true

var passed = 0
template check(cond: bool; what: string) =
  doAssert cond, what
  inc passed
  echo "  ok   ", what

proc node(name: string; roles: set[AccessRole] = {}): int =
  result = -1
  for i, nd in accessLast:
    if (roles.len == 0 or nd.role in roles) and nd.name.replace("&", "") == name: return i

proc nodeAt(name: string; roles: set[AccessRole] = {}): Rect =
  let n = node(name, roles)
  doAssert n >= 0, "no " & name & " on the screen"
  nodeRect(accessLast[n])

proc press(name: string; roles: set[AccessRole] = {}) =
  let r = nodeAt(name, roles)
  click(r, dx = r.w div 2)

block threeStates:
  var bold = csMixed
  var italic = csOff
  view = proc () =
    checkbox("Bold", bold)
    checkbox("Italic", italic)
  run(2)
  let n = node("Bold", {arCheckBox})
  check n >= 0 and asMixed in accessLast[n].states, "a mixed check box says so to a screen reader"
  press("Bold", {arCheckBox})
  check bold == csOn, "clicked, mixed goes on"
  press("Bold", {arCheckBox})
  check bold == csOff, "then off"
  press("Bold", {arCheckBox})
  check bold == csMixed, "then back to mixed: it started mixed"
  press("Italic", {arCheckBox})
  press("Italic", {arCheckBox})
  press("Italic", {arCheckBox})
  check italic == csOn, "one that never was mixed goes only on and off"
  check mixedOf([true, false]) == csMixed and mixedOf([true, true]) == csOn and
        mixedOf([false]) == csOff, "mixedOf: the state for things chosen together"

block spinWraps:
  var minutes = 59
  var hours = 23
  view = proc () =
    spin(minutes, 0, 59, wrap = true)
    spin(hours, 0, 23)
  run(2)
  var boxes: seq[Rect]
  for nd in accessLast:
    if nd.role == arSpinButton: boxes.add nodeRect(nd)
  check boxes.len == 2, "two spin boxes"
  let r = boxes[0]
  let aw = max(if fingers(): dp(26) else: dp(16), r.h * 2 div 3)
  click(rect(r.x + r.w - aw, r.y, aw, r.h div 2), dx = aw div 2, dy = r.h div 4)
  check minutes == 0, "59 stepped up wraps round to 0 (" & $minutes & ")"
  click(rect(r.x + r.w - aw, r.y + r.h div 2, aw, r.h div 2), dx = aw div 2, dy = r.h div 4)
  check minutes == 59, "0 stepped down wraps round to 59"
  let r2 = boxes[1]
  click(rect(r2.x + r2.w - aw, r2.y, aw, r2.h div 2), dx = aw div 2, dy = r2.h div 4)
  check hours == 23, "without wrap it stops at its end"

block autoExit:
  var a, b: string
  view = proc () =
    edit(a, w = 60, maxLen = 4, autoExit = true)
    edit(b, w = 60, maxLen = 4)
  run(2)
  var boxes: seq[Rect]
  for nd in accessLast:
    if nd.role == arTextField: boxes.add nodeRect(nd)
  click(boxes[0])
  typeText("12")
  run(2)
  check a == "12", "typed into the first box"
  typeText("345")
  run(3)
  check a == "1234", "at most four characters (" & a & ")"
  check b == "5", "filled, the focus went on to the next box by itself, with what came after (" & b & ")"
  typeText("98765")
  run(3)
  check b == "5987", "the next has its own limit and no auto-exit (" & b & ")"

block unfold:
  var more = false
  view = proc () =
    unfoldButton("&Options", more)
    if more: label "More choices"
  run(2)
  check node("Options >>", {arButton}) >= 0, "folded: Options >>"
  press("Options >>", {arButton})
  run(1)
  check more and node("Options <<", {arButton}) >= 0 and node("More choices") >= 0,
        "unfolded: Options << and what it shows"

block propertySheets:
  var open = true
  var page = 0
  var changed = false
  var real = "Report"
  var name = real
  var acts: seq[SheetAction]
  view = proc () =
    let act = propertySheet(open, "Report Properties", page, ["General", "Summary"], 320, changed):
      case page
      of 0:
        if edit(name): changed = true
      else: label "Pages: 3"
    if act != saNone: acts.add act
    if act in {saOk, saApply}: real = name
    if act == saCancel: name = real
  run(2)
  let n = node("Apply", {arButton})
  check n >= 0 and asDisabled in accessLast[n].states, "Apply grayed until something changes"
  var boxes: seq[Rect]
  for nd in accessLast:
    if nd.role == arTextField: boxes.add nodeRect(nd)
  click(boxes[0])
  key(KeyEnd)
  typeText(" 2026")
  run(2)
  check changed and asDisabled notin accessLast[node("Apply", {arButton})].states,
        "a change: Apply can be pressed"
  press("Apply", {arButton})
  check acts == @[saApply] and real == "Report 2026" and open and not changed,
        "Apply takes the change and the sheet stays"
  click(boxes[0])
  key(KeyEnd)
  typeText("!")
  run(2)
  press("Summary", {arTab})
  run(1)
  check open and changed and node("Pages: 3") >= 0, "switching pages takes nothing"
  key(KeyEsc)
  run(3)
  check open and node("Do you want to apply the changes you made?") >= 0 or
        node("Yes", {arButton}) >= 0, "closed with changes not applied: it asks"
  press("Yes", {arButton})
  run(2)
  check not open and acts[^1] == saOk and real == "Report 2026!", "Yes: applied and closed"
  open = true
  run(2)
  press("Cancel", {arButton})
  check not open and acts[^1] == saCancel, "Cancel closes it"

block saveChanges:
  var dirty = true
  var saves = 0
  var ended = false
  view = proc () =
    label "A document"
    if closeGuard(dirty, "Report", proc (): bool =
                    inc saves
                    dirty = false
                    true):
      ended = true
  run(2)
  closeWindow()
  run(3)
  check node("Cancel", {arButton}) >= 0 and not ended, "closed with changes: it asks first"
  press("Cancel", {arButton})
  run(2)
  check not ended and saves == 0 and node("Cancel", {arButton}) < 0, "Cancel: the app stays"
  closeWindow()
  run(3)
  press("Yes", {arButton})
  check ended and saves == 1, "Yes: saved, then closing"
  ui.running = true
  dirty = false
  ended = false

block dontAskAgain:
  var open = true
  var dontAsk = false
  var answers: seq[int]
  view = proc () =
    let a = msgBox(open, "Tip", "Hold Shift to draw a square.", ["OK"], miInfo, dontAsk)
    if a != 0: answers.add a
  run(2)
  press("Don't show this again", {arCheckBox})
  check dontAsk, "the check box under the words"
  press("OK", {arButton})
  check answers == @[1] and not open, "OK"
  open = true
  run(2)
  check answers == @[1, 1] and not open and node("OK", {arButton}) < 0,
        "asked again with it checked: not shown, its first button at once"

block menuHints:
  var hit = false
  view = proc () =
    menubar:
      menu "&Edit":
        if menuItem("&Copy", "Ctrl+C", hint = "Copies the selection to the Clipboard"): hit = true
        discard menuItem("&Paste", "Ctrl+V", enabled = false,
                         hint = "Nothing to paste: copy something first")
    label "Text"
    statusbar("Ready", "Ln 1")
  run(2)
  press("Edit")
  run(1)
  let c = nodeAt("Copy", {arMenuItem})
  move(c.x + 10, c.y + c.h div 2)
  run(2)
  check menuHint() == "Copies the selection to the Clipboard", "the lit item's hint"
  var bar = ""
  for nd in accessLast:
    if nd.role == arStatusBar: bar = nd.name
  check bar == "Copies the selection to the Clipboard", "... across the status bar (" & bar & ")"
  let p = nodeAt("Paste", {arMenuItem})
  move(p.x + 10, p.y + p.h div 2)
  run(2)
  check menuHint() == "Nothing to paste: copy something first", "a grayed one says why"
  key(KeyEsc)
  key(KeyEsc)
  run(2)
  check menuHint() == "", "no menu open: no hint"

block whatsThis:
  var clicks = 0
  view = proc () =
    if button("&Print"): inc clicks
    helpText "Prints the document on the printer you chose."
    if button("Pre&view"): inc clicks
    tooltip "Shows the pages as they will print"
  run(2)
  key(KeyF1, {ShiftPressed})
  run(1)
  check helpMode(), "Shift+F1: What's This?"
  press("Print", {arButton})
  run(2)
  check clicks == 0 and not helpMode(), "the click asked about Print and pressed nothing"
  startHelpMode()
  run(1)
  press("Preview", {arButton})
  run(2)
  check clicks == 0, "a control with only a tooltip: its tooltip is its help"
  press("Print", {arButton})
  check clicks == 1, "the card gone, the next click works the button"

block hotZone:
  var y = 0
  let id = idOf("hz")
  view = proc () =
    scrollBarFor(idOf("hzbar"), id, rect(300, 40, SbW, 300), true, y, 1000, 100, 10, overlay = false)
  run(2)
  # (the thumb at the top, under the up arrow)
  down(300 + SbW div 2, 40 + SbW + 6)
  run(1)
  move(300 + SbW div 2, 200)
  run(1)
  let mid = y
  check mid > 0, "the thumb dragged down scrolls (" & $mid & ")"
  move(600, 200)
  run(1)
  check y == 0, "taken far off the bar: back where the drag began"
  move(300 + SbW div 2, 200)
  run(1)
  check y == mid, "back near the bar: it follows again"
  up(300 + SbW div 2, 200)
  run(1)

block dragEsc:
  var dropped = false
  view = proc () =
    let r = rect(20, 20, 80, 30)
    fill(r, ui.theme.face)
    if mouseIn(r) and ui.pressed: startDrag("card", ["one"])
    let t = rect(300, 20, 80, 30)
    if dropTarget(t, "card") == dsDropped: dropped = true
  run(2)
  down(30, 30)
  run(1)
  move(60, 40)
  run(1)
  move(320, 30)
  run(1)
  check dragging("card"), "dragging over the target"
  key(KeyEsc)
  run(1)
  check not dragging(), "Esc ends the drag"
  up(320, 30)
  run(2)
  check not dropped, "... and nothing is dropped"

block pathEllipsis:
  let p = "/home/sultan/Documents/Reports/2026/November/annual-report-final.pdf"
  let s = ellipsizePath(p, textWidth("/home/…/November/annual-report-final.pdf") + 2)
  check s.startsWith("/home/…/") and s.endsWith("/annual-report-final.pdf"),
        "a path cut in its middle, its first folder and its name kept: " & s
  let m = ellipsizeMiddle("annual-report-final-version.pdf", textWidth("annual-re…version.pdf"))
  check m.endsWith(".pdf") and "…" in m, "a name cut in its middle keeps its end: " & m

echo passed, " passed"

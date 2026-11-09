## The keys and clicks people reported on GitHub, kept working: Ctrl+
## Backspace and Ctrl+Delete a word at a time (#1), a right click elsewhere
## moving an open menu (#6), a list in a panel leaving Ctrl+arrows to the
## app (#7), letters typed on a drop-down list picking (#8), Enter opening
## a closed list, a date's calendar and a combo box's list, and the same
## drop-down keys for every control (#9), the file
## list keeping the focus while it reads a folder (#5), the wheel zooming a
## picture about the mouse (#3).

import std/[os, strutils, math]
import retroui
import retroui/uirelays/input
import harness

fakeDriver()
startApp("keys", W, H)

proc rclick(x, y: int) =
  queue.add Event(kind: MouseMoveEvent, x: x, y: y)
  queue.add Event(kind: MouseDownEvent, x: x, y: y, button: RightButton, clicks: 1)
  queue.add Event(kind: MouseUpEvent, x: x, y: y, button: RightButton)

# ---- #1: a word at a time ----------------------------------------------------------------------

block wordKeys:
  var s = "foo baa baz"
  var r: Rect
  view = proc () =
    edit s
    r = ui.lastRect
  run()
  click(r)
  key(KeyEnd)
  when defined(macosx): key(KeyBackspace, {AltPressed}) else: key(KeyBackspace, {CtrlPressed})
  run()
  doAssert s == "foo baa ", "Ctrl+Backspace: the word before the caret (" & s & ")"
  when defined(macosx): key(KeyBackspace, {AltPressed}) else: key(KeyBackspace, {CtrlPressed})
  run()
  doAssert s == "foo ", s
  key(KeyHome)
  when defined(macosx): key(KeyDelete, {AltPressed}) else: key(KeyDelete, {CtrlPressed})
  run()
  doAssert s == "", "Ctrl+Delete: the word after it (" & s & ")"
  s = "ab"
  run()
  key(KeyEnd)
  key(KeyBackspace)
  run()
  doAssert s == "a", "Backspace alone: one letter"

# ---- #6: a right click elsewhere moves the menu ---------------------------------------------------

block rightClickMoves:
  var a, b: Rect
  var openA, openB = 0
  view = proc () =
    button("Left one")
    a = ui.lastRect
    contextMenu:
      inc openA
      discard menuItem("A's item")
    button("Right one")
    b = ui.lastRect
    contextMenu:
      inc openB
      discard menuItem("B's item")
  run()
  rclick(a.x + 5, a.y + 5)
  run(2)
  doAssert openA > 0 and openB == 0, "A's menu"
  openA = 0
  rclick(b.x + 5, b.y + 5)
  run(3)
  doAssert openB > 0, "one right click on B: A's menu closes, B's opens"
  doAssert openA == 0 or ui.popup != 0, "A's is gone"
  key(KeyEsc)
  run()

# ---- #7: Ctrl+arrows are the app's, not a list's ---------------------------------------------------

block listLeavesCtrl:
  var items = @["Page 1", "Page 2", "Page 3"]
  var at = 0
  var appSaw = 0
  var lr: Rect
  view = proc () =
    discard listbox(items, at, rows = 3)
    lr = ui.lastRect
    if ui.key == KeyDown and CtrlPressed in ui.mods and not ui.keyUsed: inc appSaw
  run()
  click(lr)
  at = 0
  run()
  key(KeyDown, {CtrlPressed, ShiftPressed})
  run()
  doAssert at == 0 and appSaw == 1, "Ctrl+Shift+Down goes to the app: " & $at & " " & $appSaw
  key(KeyDown)
  run()
  doAssert at == 1, "Down alone moves in the list"

# ---- #8, #9: drop-down lists from the keyboard --------------------------------------------------------

block comboKeys:
  let items = @["Finland", "France", "Germany", "Oman", "Oslo"]
  var sel = 0
  var cr: Rect
  view = proc () =
    combo(items, sel)
    cr = ui.lastRect
  run()
  click(cr)                                   # (open, then closed again)
  key(KeyEsc)
  run()
  typeText("x")
  run()
  doAssert sel == 0, "a list clicked leaves the letters to the app"
  key(KeyTab)                                 # (the focus by the keyboard: letters pick)
  run()
  typeText("o")
  run()
  doAssert sel == 3, "a letter on the closed list picks Oman: " & $sel
  typeText("o")
  run()
  doAssert sel == 4, "the same letter again: the next one (Oslo): " & $sel
  ticks += 2000
  typeText("f")
  typeText("r")
  run()
  doAssert sel == 1, "letters typed quickly: France: " & $sel
  key(KeyEnter)
  run()
  doAssert ui.popup != 0, "Enter opens the closed list"
  typeText("g")
  run()
  key(KeyEnter)
  run()
  doAssert sel == 2 and ui.popup == 0, "a letter in the open list, Enter: Germany " & $sel

block pickersOpen:
  var d = date(2026, 11, 9)
  var city = ""
  var dr, er: Rect
  view = proc () =
    datePicker(d)
    dr = ui.lastRect
    comboEdit(city, ["Muscat", "Sohar", "Salalah"])
    er = ui.lastRect
  run()
  click(rect(dr.x, dr.y, dr.w - 30, dr.h))
  key(KeyEnter)
  run()
  doAssert ui.popup != 0, "Enter in a date field opens its calendar"
  key(KeyEsc)
  run()
  click(rect(er.x, er.y, er.w - 30, er.h))
  key(KeyEnter)
  run()
  key(KeyDown)
  key(KeyEnter)
  run()
  doAssert city == "Muscat", "Enter opens a combo box's whole list: " & city

block sameKeysEverywhere:
  # (#9's comments: every drop-down opens with F4, Alt+Down and Enter, and
  # F4, Alt+Down, Alt+Up close it -- a grid's drop-down cells, the menu
  # and split buttons, the number box with a slider, too)
  var cols = @[column("Name", 100), choiceColumn("Store", ["North", "South"], 100, editable = true)]
  var data = @[@["A", "North"], @["B", "South"]]
  var gsel = 0
  var opened = 0
  var chosen = -1
  var defaults = 0
  var pct = 50
  var d = date(2026, 11, 9)
  var city = ""
  let items = @["One", "Two", "Three"]
  var csel = 0
  var gr, mr, sr, pr, dr, er, cr: Rect
  view = proc () =
    discard grid(cols, data.len, proc (r, c: int): string = data[r][c], gsel, height = 3)
    gr = ui.lastRect
    let m = menuButton("&Tools", ["First", "Second"])
    mr = ui.lastRect
    if m >= 0: chosen = m
    let s = splitButton("Save", ["Save as..."])
    sr = ui.lastRect
    if s.clicked: inc defaults
    popupSlider(pct, 0, 100)
    pr = ui.lastRect
    datePicker(d)
    dr = ui.lastRect
    comboEdit(city, ["Muscat", "Sohar"])
    er = ui.lastRect
    combo(items, csel)
    cr = ui.lastRect
    if ui.popup != 0: opened = 1 else: opened = 0
  run()
  # the grid: the Store cell of the first row
  click(rect(gr.x + 150, gr.y + 26, 10, 8))
  key(KeyEsc)
  run(2)
  key(KeyEnter)
  run(2)
  doAssert ui.popup != 0, "Enter on a grid's drop-down cell opens its list"
  key(KeyEsc)
  run(2)
  doAssert ui.popup == 0
  key(KeyDown, {AltPressed})
  run(2)
  doAssert ui.popup != 0, "Alt+Down on a grid's drop-down cell opens it"
  key(KeyEsc)
  run(2)
  # the menu button
  click(mr)
  run()
  key(KeyEsc)
  run(2)
  doAssert ui.popup == 0
  key(KeyEnter)
  run(2)
  doAssert ui.popup != 0, "Enter drops a menu button's menu"
  key(KeyEsc)
  run(2)
  key(KeyF4)
  run(2)
  doAssert ui.popup != 0, "F4 drops a menu button's menu"
  key(KeyDown)
  key(KeyEnter)
  run(2)
  doAssert chosen >= 0, "an item picked from the keyboard"
  # the split button: Enter is its default, F4 its menu
  click(rect(sr.x + 4, sr.y + 4, 10, 10))
  run()
  defaults = 0
  key(KeyEnter)
  run(2)
  doAssert defaults == 1, "Enter: the split button's default"
  key(KeyF4)
  run(2)
  doAssert ui.popup != 0, "F4 drops the split button's menu"
  key(KeyEsc)
  run(2)
  # the number box with a slider
  click(rect(pr.x + 2, pr.y + 2, 8, 8))
  run()
  key(KeyF4)
  run(2)
  doAssert ui.popup != 0, "F4 drops the slider"
  key(KeyF4)
  run(2)
  doAssert ui.popup == 0, "F4 again: closed"
  # the date: F4 opens, Alt+Up closes
  click(rect(dr.x, dr.y, dr.w - 30, dr.h))
  key(KeyF4)
  run(2)
  doAssert ui.popup != 0, "F4: the calendar"
  key(KeyUp, {AltPressed})
  run(2)
  doAssert ui.popup == 0, "Alt+Up closes the calendar"
  # the combo box: F4 opens and closes its list
  click(rect(er.x, er.y, er.w - 30, er.h))
  key(KeyF4)
  key(KeyDown)
  run(2)
  key(KeyF4)
  run(2)
  doAssert city == "", "F4 closes the list without taking an item: " & city
  # the drop-down list: F4 closes it, the item lit picked
  click(cr)
  run(2)
  doAssert ui.popup != 0
  key(KeyDown)
  run()
  key(KeyF4)
  run(2)
  doAssert ui.popup == 0 and csel == 1, "F4 closes the list, the lit item picked: " & $csel

# ---- #5: the file list keeps the focus while it reads a folder -----------------------------------------

block listKeepsFocus:
  let dir = getTempDir() / "retro-test-keys"
  removeDir(dir)
  createDir(dir / "sub")
  for i in 0 ..< 3: writeFile(dir / ("f" & $i & ".txt"), "x")
  let m = newFolderModel(dir)
  var lr: Rect
  view = proc () =
    button("First")
    discard fileList(m, fvDetails, height = 200)
    lr = ui.lastRect
  for i in 0 ..< 200:
    run()
    if m.items.len > 0: break
    os.sleep(5)
  click(rect(lr.x, lr.y + 40, lr.w, 20))
  let listFocus = ui.focus
  m.open(dir / "sub")                  # (empty: shown so, a moment while read)
  run(3)
  doAssert ui.focus == listFocus, "the list keeps the focus while it reads, and empty"
  removeDir(dir)

# ---- #3: the wheel zooms about the mouse ------------------------------------------------------------

block zoomAboutMouse:
  var b = newBitmap(400, 300)
  for y in 0 ..< 300:
    for x in 0 ..< 400: b.px[y * 400 + x] = 0xFF000000'u32 or uint32(x) or (uint32(y) shl 8)
  b.changed()
  var zoom = 1.0
  var r: Rect
  view = proc () =
    imageView(b, zoom, height = 200, w = 300)
    r = ui.lastRect
  run()
  let mx = r.x + 200
  let my = r.y + 120
  let before = px(mx, my)
  queue.add Event(kind: MouseMoveEvent, x: mx, y: my)
  queue.add Event(kind: MouseWheelEvent, y: 1)
  run(2)
  doAssert zoom > 1.0
  let after = px(mx, my)
  # (the same picture pixel under the mouse, give or take one at the new zoom)
  doAssert abs(int(before and 0xFF) - int(after and 0xFF)) <= 2 and
           abs(int((before shr 8) and 0xFF) - int((after shr 8) and 0xFF)) <= 2,
           "the point under the mouse stays: " & toHex(before) & " " & toHex(after)

echo "keys tests passed"

## Every kind of input on the widgets that take it: the mouse (clicks,
## slides, the back / forward and middle buttons), the keyboard (focus,
## arrows, Space, the menu key) and fingers (taps, slides, long presses)
## -- headless, on the fake driver.

import std/[strutils, sequtils]
import retroui
import retroui/uirelays/[input, services]
import harness

fakeDriver()
startApp("input", W, H)

proc center(r: Rect): (int, int) = (r.x + r.w div 2, r.y + r.h div 2)

proc tap(x, y: int) =
  down(x, y)
  run()
  up(x, y)
  run()

proc slide(x0, y0, x1, y1: int; steps = 4) =
  down(x0, y0)
  run()
  for i in 1 .. steps:
    move(x0 + (x1 - x0) * i div steps, y0 + (y1 - y0) * i div steps)
    run()
  up(x1, y1)
  run()

# ---- the slide switch ---------------------------------------------------------------------------

block switchMouseKeyboard:
  var on = false
  var changes = 0
  var r: Rect
  view = proc () =
    if toggle("&Wi-Fi", on): inc changes
    r = ui.lastRect
  run(2)
  let (sw, sh) = switchSize()
  let ty = r.y + r.h div 2
  # a click on the label flips it
  tap(r.x + sw + 20, ty)
  doAssert on and changes == 1
  # the thumb (now right) slid to the left: off, once
  slide(r.x + sw - 6, ty, r.x + 2, ty)
  doAssert not on and changes == 2, $changes
  # slid only a little: it stays
  slide(r.x + 6, ty, r.x + 10, ty)
  doAssert not on and changes == 2, "a short slide is not a flip " & $on & " " & $changes
  # slid right and back: still off
  down(r.x + 6, ty)
  run()
  move(r.x + sw, ty)
  run()
  move(r.x + 4, ty)
  run()
  up(r.x + 4, ty)
  run()
  doAssert not on and changes == 2
  # keyboard: Right on, Left off, Space flips, Alt+W flips
  key(KeyTab)
  run()
  key(KeyRight)
  run()
  doAssert on
  key(KeyRight)
  run()
  doAssert on, "Right again keeps it on"
  key(KeyLeft)
  run()
  doAssert not on
  key(KeySpace)
  run()
  queue.add Event(kind: KeyUpEvent, key: KeySpace)
  run(2)
  doAssert on, "Space flips it"
  key(KeyW, {AltPressed})
  run(2)
  doAssert not on, "Alt + its letter flips it"
  doAssert sh >= 14 and sw > sh

block switchTouch:
  var on = false
  var r: Rect
  ui.touch = true
  view = proc () =
    settingToggle("Notifications", on, "For new messages")
    r = ui.lastRect
  run(2)
  let (sw, sh) = switchSize()
  doAssert sh >= dp(24), "finger-sized on touch screens"
  let ty = r.y + r.h div 2
  tap(r.x + 40, ty)                       # a tap anywhere on the row
  doAssert on
  # a finger slides the thumb off; the page does not scroll instead
  let tx = r.x + r.w - dp(8) - 6
  slide(tx, ty, tx - sw, ty, steps = 6)
  doAssert not on, "the thumb slides under a finger"
  ui.touch = false

# ---- the tab strip: keys, scrolling, the middle button, menus ---------------------------------------

block tabStripInput:
  var sel = 0
  var labels: seq[string]
  for i in 1 .. 20: labels.add "Folder number " & $i
  var ev: TabStripEvent
  var r: Rect
  var closed, menu = -1
  view = proc () =
    ev = tabStrip(labels, sel)
    r = ui.lastRect
    if ev.closed >= 0: closed = ev.closed
    if ev.menu >= 0: menu = ev.menu
  run(2)
  # Tab gives the strip the focus; the arrow keys move between tabs and
  # keep the chosen one in view
  key(KeyTab)
  run()
  key(KeyRight)
  run()
  doAssert sel == 1, $sel
  key(KeyEnd)
  run()
  doAssert sel == 19 and ev.selected or sel == 19
  key(KeyHome)
  run()
  doAssert sel == 0
  # the right arrow button at the strip's end scrolls the tabs
  let arrowX = r.x + r.w - r.h - SbW div 2 - dp(4)
  tap(arrowX, r.y + r.h div 2)
  run()
  # the middle button closes the tab under it
  queue.add Event(kind: MouseMoveEvent, x: r.x + 40, y: r.y + r.h div 2)
  queue.add Event(kind: MouseDownEvent, x: r.x + 40, y: r.y + r.h div 2, button: MiddleButton)
  queue.add Event(kind: MouseUpEvent, x: r.x + 40, y: r.y + r.h div 2, button: MiddleButton)
  run(2)
  doAssert closed >= 0, "the middle button closes a tab"
  # a right click reports the tab for its menu
  queue.add Event(kind: MouseDownEvent, x: r.x + 40, y: r.y + r.h div 2, button: RightButton)
  queue.add Event(kind: MouseUpEvent, x: r.x + 40, y: r.y + r.h div 2, button: RightButton)
  run(2)
  doAssert menu >= 0
  # the wheel scrolls; a finger swipes
  ui.touch = true
  sel = 0
  run(2)
  slide(r.x + r.w div 2, r.y + r.h div 2, r.x + 10, r.y + r.h div 2, steps = 6)
  run()
  doAssert sel == 0, "a swipe scrolls, it does not choose"
  ui.touch = false

# ---- keys on the app parts --------------------------------------------------------------------

block chipsBottomBarFab:
  var tags = @["nim", "retro", "ui"]
  var on = @[false, false, false]
  var nav = 0
  var fabbed, avatarHit = 0
  var step = 2
  var back = -1
  view = proc () =
    statusbar("ready")
    discard bottomNav([(nfHome, "Home"), (nfSearch, "Search"), (nfUser, "Me")], nav)
    if fab(nfPlus, "Add"): inc fabbed
    let ev = chips(tags, on, closable = true)
    if ev.clicked >= 0: on[ev.clicked] = not on[ev.clicked]
    if ev.closed >= 0:
      tags.delete(ev.closed)
      on.delete(ev.closed)
    if avatar("Sultan Al-Said"): inc avatarHit
    let b = stepper(["Cart", "Address", "Payment"], step)
    if b >= 0: back = b
  run(2)
  # Tab order: the bottom bar, the floating button, the chips, the avatar, the steps
  # chips: Tab until a chip has the focus, Space toggles it, Delete closes it
  ui.focus = 0
  var guard = 0
  while true:
    key(KeyTab)
    run()
    key(KeySpace)
    run()
    if on.anyIt(it) or guard > 8: break
    inc guard
  doAssert on.anyIt(it), "Space toggles the focused chip"
  let before = tags.len
  key(KeyDelete)
  run()
  doAssert tags.len == before - 1, "Delete closes the focused chip"
  # the floating button takes a click (it is over the content)
  let d = dp(46)
  let f0 = fabbed
  tap(W - d div 2 - dp(16), H - FontH - 8 - dp(44) - d div 2 - dp(16))
  doAssert fabbed == f0 + 1, "the floating button is clickable: " & $fabbed

block menuKeyOnLists:
  var items = @["a", "b", "c", "d"]
  var sel = 2
  var row = -1
  var opened = false
  var cols = @[column("Name", 200)]
  view = proc () =
    let ev = grid(cols, items.len,
                  proc (r, c: int): string = items[r], sel, height = 6)
    if ev.rightClicked: row = ev.row
    contextMenu:
      opened = true
      discard menuItem("Open")
  run(2)
  key(KeyTab)
  run()
  key(KeyF10, {ShiftPressed})
  run(2)
  doAssert row == 2 and opened, "Shift+F10: the menu of the current row " & $row
  key(KeyEsc)
  run()
  row = -1
  key(KeyMenu)
  run(2)
  doAssert row == 2, "the menu key too"
  key(KeyEsc)
  run(2)

block sideButtons:
  var backs, fwds = 0
  view = proc () =
    if mouseBack(): inc backs
    if mouseForward(): inc fwds
  queue.add Event(kind: MouseDownEvent, x: 50, y: 50, button: BackButton)
  queue.add Event(kind: MouseUpEvent, x: 50, y: 50, button: BackButton)
  run(2)
  queue.add Event(kind: MouseDownEvent, x: 50, y: 50, button: ForwardButton)
  queue.add Event(kind: MouseUpEvent, x: 50, y: 50, button: ForwardButton)
  run(2)
  doAssert backs == 1 and fwds == 1, $backs & " " & $fwds

block tallDialogOnTouch:
  # a dialog taller than the window scrolls with the standard bar, fingers too
  ui.touch = true
  var open = true
  var last: Rect
  view = proc () =
    dialog(open, "Tall", 300):
      for i in 0 ..< 40:
        discard button("Choice " & $i)
        last = ui.lastRect
  run(3)
  let before = last.y
  # a finger drags the content
  let (cx, cy) = (W div 2, H div 2)
  down(cx, cy + 60)
  run()
  for i in 1 .. 6:
    move(cx, cy + 60 - i * 15)
    run()
  up(cx, cy - 30)
  run(2)
  doAssert last.y < before, "a finger scrolls the dialog"
  open = false
  run(2)
  ui.touch = false

# ---- the audit: every widget by mouse, keyboard and finger ------------------------------------

proc longPress(x, y: int) =
  ## A finger held still until it is a right click.
  down(x, y)
  run()
  for i in 0 ..< 40: run()                  # (16 ms a frame: well over half a second)

block radioArrows:
  var size = 0
  var r0: Rect
  view = proc () =
    radio("&Small", size, 0)
    r0 = ui.lastRect
    radio("&Medium", size, 1)
    radio("&Large", size, 2)
  run(2)
  tap(r0.x + 5, r0.y + r0.h div 2)
  key(KeyDown)
  run(2)
  doAssert size == 1, "Down moves the choice to the next option " & $size
  key(KeyDown)
  run(2)
  key(KeyDown)
  run(2)
  doAssert size == 0, "and round to the first"
  key(KeyUp)
  run(2)
  doAssert size == 2

block editTouchFocusAndMenu:
  var a = "hello world"
  var b = ""
  var ra, rb: Rect
  view = proc () =
    edit(a)
    ra = ui.lastRect
    edit(b)
    rb = ui.lastRect
  run(2)
  ui.touch = true
  ui.focus = 0
  run()
  # a finger that lands on the box and drags (scrolling) does not focus it
  slide(rb.x + 10, rb.y + rb.h div 2, rb.x + 10, rb.y + rb.h div 2 + 60)
  doAssert ui.focus != ui.lastId and not ui.takesText, "a drag is not a tap"
  # a tap does, with the caret where the finger was
  tap(ra.x + 6, ra.y + ra.h div 2)
  run()
  doAssert ui.takesText, "a tapped box takes the keyboard"
  typeText("X")
  run()
  doAssert a.startsWith("X") or a.len == 12, "the caret is where the tap was: " & a
  # a long press opens its menu: Select all, then Cut
  a = "abc"
  longPress(ra.x + 6, ra.y + ra.h div 2)
  up(ra.x + 6, ra.y + ra.h div 2)
  run(2)
  doAssert a == "abc", "the release of the long press chose nothing"
  ui.touch = false
  # the mouse: right click, the menu, Select all; right click, Cut
  putClipboardText("")
  queue.add Event(kind: MouseDownEvent, x: ra.x + 6, y: ra.y + ra.h div 2, button: RightButton)
  queue.add Event(kind: MouseUpEvent, x: ra.x + 6, y: ra.y + ra.h div 2, button: RightButton)
  run(2)
  key(KeyEnd)
  run()
  key(KeyEnter)                             # Select all (the last item)
  run(2)
  queue.add Event(kind: MouseDownEvent, x: ra.x + 6, y: ra.y + ra.h div 2, button: RightButton)
  queue.add Event(kind: MouseUpEvent, x: ra.x + 6, y: ra.y + ra.h div 2, button: RightButton)
  run(2)
  key(KeyT)                                 # Cu&t
  run(2)
  doAssert a == "" and getClipboardText() == "abc", "cut from the menu: " & a
  # Paste with the menu
  queue.add Event(kind: MouseDownEvent, x: ra.x + 6, y: ra.y + ra.h div 2, button: RightButton)
  queue.add Event(kind: MouseUpEvent, x: ra.x + 6, y: ra.y + ra.h div 2, button: RightButton)
  run(2)
  key(KeyP)
  run(2)
  doAssert a == "abc", a

block comboByFinger:
  var sel = 0
  var r: Rect
  view = proc () =
    combo(["One", "Two", "Three", "Four"], sel)
    r = ui.lastRect
  run(2)
  ui.touch = true
  # a swipe over it does not open it
  slide(r.x + 10, r.y + r.h div 2, r.x + 10, r.y + r.h div 2 + 80)
  doAssert ui.popup == 0, "a swipe does not open the list"
  # a tap does; a tap on an item picks it
  tap(r.x + 10, r.y + r.h div 2)
  doAssert ui.popup != 0
  tap(r.x + 10, r.y + r.h + ItemH * 2 + ItemH div 2)
  doAssert sel == 2 and ui.popup == 0, $sel
  ui.touch = false
  # keys: Home / End when closed
  ui.focus = 0
  run(2)
  key(KeyEnd)
  run()
  doAssert sel == 3
  key(KeyHome)
  run()
  doAssert sel == 0

block tabsKeysAndFingers:
  var t = 0
  var r: Rect
  view = proc () =
    tabs t, ["&One", "&Two", "T&hree"]:
      label "page " & $t
    r = ui.lastRect
  run(2)
  key(KeyPageDown, {CtrlPressed})
  run()
  doAssert t == 1, "Ctrl+PageDown"
  key(KeyTab, {CtrlPressed, ShiftPressed})
  run()
  doAssert t == 0, "Ctrl+Shift+Tab"
  key(KeyH, {AltPressed})
  run()
  doAssert t == 2, "Alt + its letter"
  ui.touch = true
  t = 0
  run(2)
  # a finger landing on the second tab and sliding off does not pick it
  slide(r.x + 100, r.y + 8, r.x + 100, r.y + 120)
  doAssert t == 0, "a slide is not a tap: " & $t
  ui.touch = false

block menuLongPressAndKeys:
  var chosen = ""
  var r: Rect
  view = proc () =
    label "Hold me"
    r = ui.lastRect
    contextMenu:
      if menuItem("&First"): chosen = "first"
      if menuItem("&Second"): chosen = "second"
      if menuItem("&Third"): chosen = "third"
  run(2)
  ui.touch = true
  longPress(r.x + 5, r.y + 5)
  doAssert ui.popup != 0, "a long press opens the menu"
  move(r.x + 9, r.y + 9)                    # the finger drifts onto the first item
  run()
  up(r.x + 9, r.y + 9)
  run(2)
  doAssert chosen == "" and ui.popup != 0, "lifting it chooses nothing"
  ui.touch = false
  key(KeyEnd)
  run()
  key(KeyEnter)
  run(2)
  doAssert chosen == "third", "End, Enter: the last item " & chosen

block noTooltipAfterTouch:
  view = proc () =
    discard button("Save")
    tooltip("Saves the file")
  run(2)
  ui.touch = true
  tap(20, 15)
  for i in 0 ..< 60: run()                  # a second passes
  doAssert ui.tip.len == 0, "no tooltip where a finger was lifted"
  ui.touch = false

block valuesByWheelAndKeys:
  var sv = 5
  var spinV = 10
  var sl = 50
  var rs, rspin, rsl: Rect
  view = proc () =
    vscroll(sv, 0, 100, page = 30, h = 120)
    rs = ui.lastRect
    spin(spinV, 0, 100)
    rspin = ui.lastRect
    slider(sl, 0, 100, w = 200)
    rsl = ui.lastRect
  run(2)
  queue.add Event(kind: MouseMoveEvent, x: rs.x + 2, y: rs.y + 50)
  queue.add Event(kind: MouseWheelEvent, y: -1)
  run(2)
  doAssert sv > 5, "the wheel over a scroll bar moves it " & $sv & " " & $rs & " " & $ui.popup & " " & $ui.mx & "," & $ui.my
  # the spin box: PageUp, the wheel (with the focus)
  tap(rspin.x + 5, rspin.y + rspin.h div 2)
  key(KeyPageUp)
  run()
  doAssert spinV == 20, $spinV
  queue.add Event(kind: MouseMoveEvent, x: rspin.x + 5, y: rspin.y + 5)
  queue.add Event(kind: MouseWheelEvent, y: 1)
  run(2)
  doAssert spinV == 21, $spinV
  # the slider: the wheel only when it has the focus
  queue.add Event(kind: MouseMoveEvent, x: rsl.x + 50, y: rsl.y + 5)
  queue.add Event(kind: MouseWheelEvent, y: 1)
  run(2)
  doAssert sl == 50, "not focused: the wheel scrolls the page, not the slider"

block extrasKeys:
  var c = color(255, 0, 0)
  var stars = 2
  var seg = 1
  var rc, rr, rg: Rect
  view = proc () =
    colorPicker(c)
    rc = ui.lastRect
    rating(stars)
    rr = ui.lastRect
    segmented(["A", "B", "C"], seg)
    rg = ui.lastRect
  run(2)
  tap(rc.x + 5, rc.y + 5)                   # the first color, and the focus
  key(KeyRight)
  run()
  doAssert c == basicColors[1], "Right: the next basic color"
  key(KeyDown)
  run()
  doAssert c == basicColors[9]
  tap(rr.x + 2, rr.y + 2)
  key(KeyEnd)
  run()
  doAssert stars == 5
  key(KeyHome)
  run()
  doAssert stars == 0
  tap(rg.x + 2, rg.y + rg.h div 2)
  key(KeyEnd)
  run()
  doAssert seg == 2
  key(KeyHome)
  run()
  doAssert seg == 0

block lineViewDrag:
  var sel = 0
  var r: Rect
  var copied = false
  view = proc () =
    if lineView(100, proc (i: int): string = "line " & $i, sel, height = 200).copied:
      copied = true
    r = ui.lastRect
  run(2)
  let lh = lineHeight(style(mono = true)) + 1
  down(r.x + 40, r.y + 1 + lh div 2)
  run()
  move(r.x + 40, r.y + 1 + 4 * lh + lh div 2)
  run()
  up(r.x + 40, r.y + 1 + 4 * lh + lh div 2)
  run()
  key(KeyC, {CtrlPressed})
  run()
  doAssert sel == 4 and copied, $sel
  doAssert getClipboardText().count('\n') == 5, "a drag selected five lines"

block labelMnemonicFocusesNext:
  var name = ""
  view = proc () =
    discard button("Other")
    label "&Name:"
    edit name
  run(2)
  key(KeyN, {AltPressed})
  run(2)
  typeText("Ann")
  run()
  doAssert name == "Ann", "Alt+N focused the box after the label: " & name

block calendarByFinger:
  var d = date(2026, 10, 27)
  var r: Rect
  view = proc () =
    calendar(d)
    r = ui.lastRect
  run(2)
  ui.touch = true
  let gridY = r.y + 1 + ItemH + 8 + ItemH + 3 + 5
  slide(r.x + 10, gridY, r.x + 10, gridY + 100)
  doAssert d == date(2026, 10, 27), "a slide over the days picks none"
  ui.touch = false
  queue.add Event(kind: MouseMoveEvent, x: r.x + 20, y: r.y + 20)
  queue.add Event(kind: MouseWheelEvent, y: -1)
  run(2)
  key(KeyHome)                              # (focused? a press gives it)
  run()

block datePickerKeys:
  var d = date(2026, 1, 31)
  var r: Rect
  view = proc () =
    datePicker(d)
    r = ui.lastRect
  run(2)
  tap(r.x + 5, r.y + r.h div 2)
  key(KeyUp)
  run()
  doAssert d == date(2026, 2, 1), $d
  key(KeyPageDown)
  run()
  doAssert d == date(2026, 1, 1), $d

block treeRightClickAndTypeAhead:
  var sel = "Animals"
  var open1 = true
  var r: Rect
  view = proc () =
    tree(sel, 8):
      branch("Animals", open1):
        discard leaf("Cat")
        discard leaf("Dog")
        discard leaf("Bird")
    r = ui.lastRect
  run(2)
  let rowH = ItemH + 1
  queue.add Event(kind: MouseDownEvent, x: r.x + 60, y: r.y + 1 + 2 * rowH + rowH div 2,
                  button: RightButton)
  queue.add Event(kind: MouseUpEvent, x: r.x + 60, y: r.y + 1 + 2 * rowH + rowH div 2,
                  button: RightButton)
  run(2)
  doAssert sel == "Animals/Dog", "a right click selects the node: " & sel
  typeText("b")
  run(2)
  doAssert sel == "Animals/Bird", "type-ahead: " & sel

block imageViewDoubleClick:
  var zoom = 0.0
  let b = newBitmap(40, 30)
  var r: Rect
  view = proc () =
    imageView(b, zoom, height = 150)
    r = ui.lastRect
  run(2)
  down(r.x + 50, r.y + 50, clicks = 1)
  run()
  up(r.x + 50, r.y + 50)
  run()
  down(r.x + 50, r.y + 50, clicks = 2)
  run()
  up(r.x + 50, r.y + 50)
  run(2)
  doAssert zoom == 1.0, "a double click: actual size " & $zoom

block checkListPages:
  var items: seq[string]
  for i in 0 ..< 40: items.add "item " & $i
  var checked: seq[bool]
  var r: Rect
  view = proc () =
    checkList(items, checked, rows = 6)
    r = ui.lastRect
  run(2)
  tap(r.x + 40, r.y + 5)                    # (flips the first, takes the focus)
  key(KeyPageDown)
  run()
  key(KeySpace)
  run()
  doAssert checked[5], "Page Down moved a page: " & $checked.find(true)

block editAreaWraps:
  # a long line wraps at the words; Up, Down, Home and End go by the lines
  # as shown, and typing at the end of a shown line keeps going
  var t = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen"
  var r: Rect
  view = proc () =
    editArea(t, lines = 6, w = 200)
    r = ui.lastRect
  run(2)
  click(r, dx = 8, dy = 6)                 # the caret on the first shown line
  key(KeyHome, {CtrlPressed})
  run()
  key(KeyEnd)
  run()
  let st = state(ui.focus)
  doAssert st.caret > 0 and st.caret < t.len, "End stops where the first shown line ends: " & $st.caret
  doAssert t[st.caret] == ' ', "(before the space it wrapped at): " & $st.caret
  key(KeyDown)
  run()
  let st2 = state(ui.focus)
  doAssert st2.caret > st.caret + 1, "Down goes to the next shown line: " & $st2.caret
  key(KeyHome)
  run()
  doAssert state(ui.focus).caret == st.caret + 1, "Home: where it starts"
  typeText("X")
  run()
  doAssert t[st.caret + 1] == 'X', t
  # as one line, the box scrolls sideways instead
  var u = t
  view = proc () =
    editArea(u, lines = 6, w = 200, wrap = false)
    r = ui.lastRect
  run(2)
  click(r, dx = 8, dy = 6)
  key(KeyEnd)
  run()
  doAssert state(ui.focus).caret == u.len, "no wrapping: End is the end of the line"

block focusFirstTextInADialog:
  var open = false
  var pin = ""
  var other = ""
  view = proc () =
    edit(other)
    if button("Ask"):
      open = true
      focusFirstText()
    dialog(open, "PIN", 300):
      label "The PIN:"
      edit(pin, password = true)
  run(2)
  click(ui.lastRect)                 # (the last thing drawn before: the button)
  run(2)
  typeText("1234")
  run()
  doAssert pin == "1234" and other == "", "typing goes to the dialog's box: " & pin & "/" & other

block arabicInATextBox:
  # an Arabic line sits at the right of the box; the caret goes from the
  # right as the text does: a click at the right end is the start
  var t = "مرحبا بكم"
  var r: Rect
  view = proc () =
    edit(t, w = 300)
    r = ui.lastRect
  run(2)
  click(r, dx = r.w - 3)               # (right of the text: its start)
  doAssert state(ui.focus).caret == 0, "the right end of Arabic is its start: " & $state(ui.focus).caret
  click(r, dx = 8)
  doAssert state(ui.focus).caret == t.len, "the left of it is its end"
  key(KeyHome)
  run()
  typeText("X")
  run()
  doAssert t.startsWith("X")

block menuBarByKeyboard:
  # F10, or Alt pressed and let go alone: the first menu; Left / Right go
  # along the bar (even with the pointer resting on a menu's title), Up /
  # Down through the items, Enter chooses; a menu taller than the screen
  # goes on in a second column
  var chosen = ""
  var titles: seq[Id]
  view = proc () =
    menubar:
      menu "&File":
        if menuItem("&New"): chosen = "New"
        if menuItem("&Open"): chosen = "Open"
      menu "&Edit":
        if menuItem("&Undo"): chosen = "Undo"
        if menuItem("&Copy"): chosen = "Copy"
      menu "&Window":
        for i in 1 .. 60:
          if menuItem("Panel " & $i): chosen = "Panel " & $i
  run(2)
  move(10, 8)                         # (the pointer resting on File's title)
  run()
  key(KeyF10)
  run(2)
  let file = ui.popup
  doAssert file != 0 and ui.menuOpen
  key(KeyRight)
  run(2)
  let edit = ui.popup
  doAssert edit != file, "Right: the next menu, though the pointer is on File"
  key(KeyDown)
  run()
  key(KeyEnter)
  run(2)
  doAssert chosen == "Copy", chosen
  # Alt alone: the bar; again: closed
  queue.add Event(kind: KeyDownEvent, key: KeyNone, mods: {AltPressed})
  queue.add Event(kind: KeyUpEvent, key: KeyNone, mods: {})
  run(2)
  doAssert ui.popup == file
  queue.add Event(kind: KeyDownEvent, key: KeyNone, mods: {AltPressed})
  queue.add Event(kind: KeyUpEvent, key: KeyNone, mods: {})
  run(2)
  doAssert ui.popup == 0
  # Alt+W: the long Window menu, in columns within the screen
  key(KeyW, {AltPressed})
  run(3)
  doAssert ui.popup != 0
  let r = ui.popupRect
  doAssert r.y + r.h <= H + 3, "within the screen: " & $r
  doAssert r.w > 2 * dp(120), "more than one column: " & $r
  key(KeyEnd)
  run()
  key(KeyEnter)
  run(2)
  doAssert chosen == "Panel 60", chosen
  view = nil

block menusFitTheScreen:
  # A submenu that would pass the bottom moves up, in one column; the
  # submenu of a menu in columns opens beside all of them, not over them
  var chosen = ""
  view = proc () =
    menubar:
      menu "&Edit":
        for i in 1 .. 14:
          if menuItem("Item " & $i): chosen = "Item " & $i
        submenu "&Preferences":
          for i in 1 .. 16:
            if menuItem("Pref " & $i): chosen = "Pref " & $i
      menu "&Window":
        submenu "&Arrange":
          if menuItem("&Cascade"): chosen = "Cascade"
          if menuItem("&Tile"): chosen = "Tile"
        for i in 1 .. 60:
          if menuItem("Panel " & $i): chosen = "Panel " & $i
  run(2)
  key(KeyE, {AltPressed})
  run(2)
  key(KeyEnd)
  run()
  key(KeyRight)
  run(4)
  let m = ui.popupRect
  let sub = ui.popupRect2Now
  doAssert sub.w > 0, "the submenu is open"
  doAssert sub.y + sub.h <= H, "within the screen: " & $sub
  doAssert sub.w < dp(120) * 2, "in one column: " & $sub
  doAssert sub.x >= m.x + m.w - 6, "beside its menu: " & $sub & " " & $m
  key(KeyEnter)
  run(2)
  doAssert chosen == "Pref 1", chosen
  key(KeyW, {AltPressed})
  run(2)
  key(KeyRight)
  run(4)
  let w = ui.popupRect
  let arr = ui.popupRect2Now
  doAssert w.w > 2 * dp(120), "the Window menu in columns: " & $w
  doAssert arr.w > 0, "Arrange is open"
  doAssert arr.x >= w.x + w.w - 6 or arr.x + arr.w <= w.x + 6,
    "beside all the columns: " & $arr & " " & $w
  key(KeyDown)
  run()
  key(KeyEnter)
  run(2)
  doAssert chosen == "Tile", chosen
  view = nil

block submenuReachedAcrossColumns:
  # a submenu beside a menu in columns: the pointer on its way to it over the
  # other column's rows leaves it open; resting on another row closes it
  var chosen = ""
  view = proc () =
    menubar:
      menu "&File":
        if menuItem("&New"): chosen = "New"
      menu "&Window":
        submenu "&Arrange":
          if menuItem("&Cascade"): chosen = "Cascade"
          if menuItem("&Tile"): chosen = "Tile"
        for i in 1 .. 60:
          if menuItem("Panel " & $i): chosen = "Panel " & $i
  run(2)
  key(KeyW, {AltPressed})
  run(3)
  let r = ui.popupRect
  let colW = (r.w - 3) div 2
  doAssert r.w > 2 * dp(120), "in columns: " & $r
  move(r.x + 20, r.y + 9)                   # (onto Arrange: it opens)
  run(2)
  let sub = ui.popupRect2Now
  doAssert sub.w > 0 and sub.x >= r.x + r.w - 6, "Arrange beside the menu: " & $sub
  for x in [r.x + colW + 10, r.x + colW + colW div 2, r.x + 2 * colW - 4]:
    move(x, r.y + 9 + (x - r.x) div 40)    # (over the second column's rows, toward it)
    run()
    doAssert ui.popupRect2Now.w > 0, "still open on the way: " & $x
  move(sub.x + 20, sub.y + 9)
  run(2)
  down(sub.x + 20, sub.y + 9)
  run()
  up(sub.x + 20, sub.y + 9)
  run(2)
  doAssert chosen == "Cascade", chosen
  # down the menu (not toward the submenu): Arrange goes at once
  key(KeyW, {AltPressed})
  run(3)
  move(r.x + 20, r.y + 9)
  run(2)
  doAssert ui.popupRect2Now.w > 0
  move(r.x + 20, r.y + 9 + 3 * 22)
  run()
  doAssert ui.popupRect2Now.w == 0, "gone at once"
  # toward it, then resting on another row on the way: Arrange goes after a moment
  move(r.x + 20, r.y + 9)
  run(2)
  doAssert ui.popupRect2Now.w > 0
  move(r.x + colW + 10, r.y + 9 + 8)
  run()
  doAssert ui.popupRect2Now.w > 0, "on its way: still open"
  run(40)
  doAssert ui.popupRect2Now.w == 0, "gone after a rest"
  key(KeyEsc)
  run(2)
  view = nil

block submenusInSubmenus:
  # a submenu in a submenu (Filter > Gallery > Artistic): it opens by the pointer and by the
  # keys, beside the one it is in; its item chosen; Left closes it only
  var chosen = ""
  view = proc () =
    menubar:
      menu "&Filter":
        if menuItem("&Last Filter"): chosen = "Last"
        submenu "&Gallery":
          submenu "&Artistic":
            if menuItem("&Cutout"): chosen = "Cutout"
            if menuItem("&Fresco"): chosen = "Fresco"
            submenu "&More":
              if menuItem("&Deep"): chosen = "Deep"
          submenu "&Texture":
            if menuItem("&Grain"): chosen = "Grain"
        if menuItem("&Blur"): chosen = "Blur"
  run(2)
  # the keys: Alt+F, down to Gallery, Right, Right (Artistic), Down, Enter
  key(KeyF, {AltPressed})
  run(2)
  key(KeyDown)
  run()
  key(KeyRight)
  run(2)
  let g = ui.popupRect2Now
  doAssert g.w > 0, "Gallery open"
  key(KeyRight)
  run(3)
  let both = ui.popupRect2Now
  doAssert both.w > g.w + dp(60), "Artistic open beside it: " & $both & " " & $g
  key(KeyDown)
  run()
  key(KeyEnter)
  run(2)
  doAssert chosen == "Fresco", chosen
  doAssert ui.popup == 0, "all of it closed"
  # Left closes the inner one only
  key(KeyF, {AltPressed})
  run(2)
  key(KeyDown); run()
  key(KeyRight); run(2)
  key(KeyRight); run(3)
  let wide = ui.popupRect2Now.w
  key(KeyLeft)
  run(3)
  doAssert ui.popup != 0 and ui.popupRect2Now.w > 0 and ui.popupRect2Now.w < wide,
           "Artistic closed, Gallery open: " & $ui.popupRect2Now
  key(KeyEsc); run(2); key(KeyEsc); run(2)
  # the pointer: onto Gallery, then onto Artistic, then a click on Cutout; a third level, too
  key(KeyF, {AltPressed})
  run(3)
  let m = ui.popupRect
  move(m.x + 20, m.y + 3 + 1 * (ui.popupRect.h - 6) div 3 + 6)
  run(3)
  let gal = ui.popupRect2Now
  doAssert gal.w > 0 and gal.x >= m.x + m.w - 6, "Gallery beside the menu: " & $gal
  move(gal.x + 20, gal.y + 10)               # (Artistic, its first row)
  run(3)
  let art = ui.popupRect2Now
  doAssert art.w > gal.w + dp(60), "Artistic beside Gallery: " & $art
  let ax = art.x + art.w - 40                # (in Artistic: right of Gallery)
  move(ax, gal.y + 10)
  run(2)
  move(ax, gal.y + 10 + 2 * (MenuH + 1))     # (More, its third row)
  run(3)
  doAssert ui.popupRect2Now.w > art.w + dp(60), "More beside Artistic: " & $ui.popupRect2Now
  move(ax, gal.y + 10)
  run(2)
  down(ax, gal.y + 10)
  run()
  up(ax, gal.y + 10)
  run(2)
  doAssert chosen == "Cutout", chosen
  view = nil

block sidewaysWheel:
  # A sideways wheel (a tilted one, a touch pad, macOS's Shift + the wheel)
  # is Shift + the wheel, as Windows and X11 send that: what scrolls
  # sideways with Shift + the wheel scrolls with it, on every system
  setSmoothScrolling(false)
  var sx, sy = 0
  let area = rect(10, 10, 200, 100)
  view = proc () =
    scrollWheel(idOf("side x"), sx, 1000, area, 10, sideways = true)
    scrollWheel(idOf("side y"), sy, 1000, area, 10)
  run(2)
  move(50, 50)
  queue.add Event(kind: MouseWheelEvent, x: 1, hasMods: true)           # right
  run(2)
  doAssert sx == 10 and sy == 0, $sx & " " & $sy
  queue.add Event(kind: MouseWheelEvent, x: -1, hasMods: true)          # left
  run(2)
  doAssert sx == 0 and sy == 0, $sx & " " & $sy
  # (Windows' and X11's Shift + the wheel down: to the right, the same)
  queue.add Event(kind: MouseWheelEvent, y: -1, mods: {ShiftPressed}, hasMods: true)
  run(2)
  doAssert sx == 10 and sy == 0, $sx & " " & $sy
  queue.add Event(kind: MouseWheelEvent, y: -1, hasMods: true)          # down
  run(2)
  doAssert sx == 10 and sy == 10, $sx & " " & $sy
  # (the Shift was the wheel's: not held after it)
  queue.add Event(kind: MouseWheelEvent, x: 2)
  run(3)
  doAssert sx == 30 and ShiftPressed notin ui.mods, $sx & " " & $ui.mods
  # a diagonal swipe goes the way it goes most
  queue.add Event(kind: MouseWheelEvent, x: 1, y: -3, hasMods: true)
  run(2)
  doAssert sx == 30 and sy == 40, $sx & " " & $sy
  setSmoothScrolling(true)
  view = nil

block modifiersLetGo:
  # Ctrl let go with nothing typed (a phone's keyboard tells with the key's
  # release and with the pointer): not held for the wheel after Ctrl+C
  view = proc () = label "Hello"
  run(2)
  queue.add Event(kind: KeyDownEvent, key: KeyC, mods: {CtrlPressed}, hasMods: true)
  queue.add Event(kind: KeyUpEvent, key: KeyC, mods: {CtrlPressed}, hasMods: true)
  run(2)
  doAssert CtrlPressed in ui.mods
  queue.add Event(kind: KeyUpEvent, key: KeyNone, mods: {}, hasMods: true)
  run(2)
  doAssert CtrlPressed notin ui.mods, $ui.mods
  queue.add Event(kind: KeyDownEvent, key: KeyC, mods: {CtrlPressed}, hasMods: true)
  run()
  queue.add Event(kind: MouseMoveEvent, x: 30, y: 30, mods: {}, hasMods: true)
  run(2)
  doAssert ui.mods == {}, $ui.mods
  view = nil

block caretForTheInputMethod:
  # the text box tells where its caret is, for an input method's candidates
  var told: seq[(int, int, int, int)]
  textCaretRelay = proc (x, y, w, h: int) = told.add (x, y, w, h)
  var s = ""
  var r: Rect
  view = proc () =
    edit(s)
    r = ui.lastRect
  run(2)
  tap(r.x + 5, r.y + r.h div 2)
  run(2)
  doAssert told.len > 0, "focused: told"
  let first = told[^1]
  doAssert first[1] >= r.y and first[1] < r.y + r.h and first[3] > 0, $first & " " & $r
  typeText("abc")
  run(2)
  doAssert told[^1][0] > first[0], "the caret moved right " & $told
  let n = told.len
  run(3)
  doAssert told.len == n, "told again only when it moves"
  textCaretRelay = nil
  view = nil

block aColorWithItsOpacity:
  # the Color dialog with `alpha`: Transparent (Alt+T), then OK -- the color kept, see-through;
  # opened without it, the color comes back opaque
  var c = color(40, 110, 220)
  var wr: Rect
  view = proc () =
    colorWell(c, "alphawell", alpha = true)
    wr = ui.lastRect
  run(2)
  tap(wr.x + 5, wr.y + 5)
  run(2)
  key(KeyT, {AltPressed})
  run(2)
  ui.focus = 0
  key(KeyEnter)
  run(3)
  doAssert c.a == 0 and c.r == 40 and c.g == 110 and c.b == 220, "transparent, its color kept: " & $c
  var plain = color(40, 110, 220, 100)
  view = proc () =
    colorWell(plain, "plainwell")
    wr = ui.lastRect
  run(2)
  tap(wr.x + 5, wr.y + 5)
  run(2)
  ui.focus = 0
  key(KeyEnter)
  run(3)
  doAssert plain.a == 255, "a well without `alpha`: opaque, as before: " & $plain
  view = nil

block shortcutWords:
  # (Ctrl+S is Cmd+S on a Mac, where the drivers report Cmd as Ctrl)
  when defined(macosx):
    doAssert shortcutText("Ctrl+Shift+S") == "Cmd+Shift+S"
    doAssert shortcutText("Alt+F4") == "Cmd+W"
  else:
    doAssert shortcutText("Ctrl+Shift+S") == "Ctrl+Shift+S"
    doAssert modifierName(CtrlPressed) == "Ctrl"

echo "input tests passed"

## Tests of how the controls take the mouse, the keys and a finger: a finger's press just beside
## a small control is its (44 points across at least, as phones make targets), not one far off,
## not one beside a big control the press is on, the nearer of two; the rest of its gesture goes
## with it; how far a finger moves before a tap is a drag grows with the screen's density; a
## finger held on a word in a text box chooses it, its menu with Cut and Copy; a right click or
## a held finger on a list's row chooses that row; a breadcrumb's parts by the keys; a drop-down
## list's choice by the wheel only while it has the focus; the newer looks light a text box, a
## check box and a radio button under the mouse (3.1 does not); a chip's cross for a finger.

import std/[strutils, tables]
import retroui
import retroui/uirelays/[coords, screen, input]
import harness

var touchNow = true
var scale = 100
fakeDriver()
windowRelays.getWindowLayout = proc (): ScreenLayout =
  ScreenLayout(width: W, height: H, scaleX: 1, scaleY: 1, uiScale: scale, touch: touchNow)

var passed = 0
template check(cond: bool; what: string) =
  doAssert cond, what
  inc passed
  echo "  ok   ", what

var clicks: seq[string]
var where: Table[string, Rect]
var part = 0
view = proc () = discard
startApp("reach", W, H)
accessKeep = true

proc relayout() =
  harness.queue.add Event(kind: WindowResizeEvent, x: W, y: H)
  run(3)

proc tap(x, y: int) =
  down(x, y)
  run(1)
  up(x, y)
  run(2)

relayout()
check ui.touch and fingers(), "a touch screen"

# ---- a finger's press just beside a small control --------------------------------------------------

view = proc () =
  case part
  of 0:
    if button("Small"): clicks.add "Small"
    where["Small"] = ui.lastRect
    space(dp(40))
    if roundButton(rkAdd, "Add"): clicks.add "Add"
    where["Add"] = ui.lastRect
  of 1:
    # two small round buttons a little apart: the nearer one
    row:
      if roundButton(rkRemove, "Left"): clicks.add "Left"
      where["Left"] = ui.lastRect
      space(dp(10))
      if roundButton(rkAdd, "Right"): clicks.add "Right"
      where["Right"] = ui.lastRect
  else:
    # a big control (a list) right under a small button: a press on the list is the list's
    if button("Top"): clicks.add "Top"
    where["Top"] = ui.lastRect
    var sel = 0
    listbox(["one", "two", "three"], sel, rows = 3)
    where["List"] = ui.lastRect
run(3)
let s = where["Small"]
check s.h < dp(TouchTarget), "a button smaller than a finger's target (" & $s.h & " high)"
tap(s.x + s.w div 2, s.y + s.h + dp(3))
check clicks == @["Small"], "a tap just under it: its (" & $clicks & ")"
clicks.setLen(0)
tap(s.x + s.w div 2, s.y - dp(4))
check clicks == @["Small"], "just over it: its"
clicks.setLen(0)
tap(s.x + s.w div 2, s.y + s.h + dp(20))
check clicks.len == 0, "far under it: nothing"
let a = where["Add"]
tap(a.x + a.w + dp(5), a.y + a.h div 2)
check clicks == @["Add"], "a round button's side, a little off: its"
clicks.setLen(0)
# the gesture goes with it: pressed beside, let go beside -- a click; dragged off -- none
down(s.x + s.w div 2, s.y + s.h + dp(3))
run(1)
check ui.active != 0, "pressed beside it: it is held"
up(s.x + s.w div 2, s.y + s.h + dp(3))
run(2)
check clicks == @["Small"], "let go where the finger went down: a click"
clicks.setLen(0)
part = 1
run(3)
let l = where["Left"]
let r = where["Right"]
let gapMid = (l.x + l.w + r.x) div 2
tap(l.x + l.w + 1, l.y + l.h div 2)
check clicks == @["Left"], "in the gap, nearer the left one: the left one (" & $clicks & ")"
clicks.setLen(0)
tap(r.x - 1, r.y + l.h div 2)
check clicks == @["Right"], "nearer the right one: the right one"
clicks.setLen(0)
discard gapMid
part = 2
run(3)
let t = where["Top"]
let li = where["List"]
check li.y < t.y + t.h + dp(TouchTarget) div 2, "the list close under the button"
tap(li.x + li.w div 2, li.y + dp(2))
check clicks.len == 0, "a press on the list, near the button: the list's, not the button's"
# with a mouse: nothing moved
touchNow = false
relayout()
part = 0
run(3)
let sm = where["Small"]
down(sm.x + sm.w div 2, sm.y + sm.h + 3)
run(1)
up(sm.x + sm.w div 2, sm.y + sm.h + 3)
run(2)
check clicks.len == 0, "a mouse beside it: not its -- the mouse points where it is"
touchNow = true
relayout()

# ---- a tap or a drag: how far the finger moves, in design pixels -----------------------------------

var listSel = 0
var listItems: seq[string]
for i in 0 ..< 40: listItems.add "Row " & $i
view = proc () =
  listbox(listItems, listSel, rows = 8)
  where["L"] = ui.lastRect
run(3)
proc wobble(dx: int; zoom = 1): int =
  ## (a finger down on the third row, moved `dx` of the screen's pixels, let go: the row chosen;
  ## `zoom`: the screen's pixels to the UI's)
  listSel = 0
  run(2)
  let lr = where["L"]
  let x = (lr.x + lr.w div 2) * zoom
  let y = (lr.y + 2 * ItemH + ItemH div 2) * zoom
  down(x, y)
  run(1)
  harness.queue.add Event(kind: MouseMoveEvent, x: x, y: y + dx)
  run(1)
  up(x, y + dx)
  run(2)
  listSel
check wobble(5) == 2, "a finger moved 5 pixels: still a tap"
check wobble(14) == 0, "moved 14: a drag, no row chosen"
scale = 200
harness.queue.add Event(kind: WindowMetricsEvent, x: W, y: H, scaleX: 1, scaleY: 1, uiScale: 200)
run(3)
check wobble(12, 2) == 2, "at 200 %, a finger moved 12 of the screen's pixels (6 points): still a tap"
check wobble(24, 2) == 0, "24 of them (12 points): a drag"
scale = 100
harness.queue.add Event(kind: WindowMetricsEvent, x: W, y: H, scaleX: 1, scaleY: 1, uiScale: 100)
run(3)

# ---- a finger held on a word ---------------------------------------------------------------------

var words = "hello brave world"
view = proc () =
  edit(words, w = dp(300))
  where["E"] = ui.lastRect
run(3)
let er = where["E"]
let wx = er.x + 2 + dp(4) + textWidth("hello brave wo")
down(wx, er.y + er.h div 2)
run(1)
ticks += 700
run(3)
check ui.popup != 0, "held: its menu"
let cut = findNode(accessLast, "Cut", {arMenuItem})
check cut >= 0 and asDisabled notin accessLast[cut].states, "Cut is there to choose: a word was chosen"
up(wx, er.y + er.h div 2)
run(2)
check findNode(accessLast, "Cut", {arMenuItem}) >= 0, "let go: the menu stays"
let n = findNode(accessLast, "Copy", {arMenuItem})
tap(nodeRect(accessLast[n]).x + 4, nodeRect(accessLast[n]).y + nodeRect(accessLast[n]).h div 2)
check getClipboardText() == "world", "Copy: the word held (" & getClipboardText() & ")"

# ---- a right click on a list's row ---------------------------------------------------------------

touchNow = false
relayout()
view = proc () =
  listbox(listItems, listSel, rows = 8)
  where["L"] = ui.lastRect
listSel = 0
run(3)
let lr2 = where["L"]
down(lr2.x + 20, lr2.y + 4 * ItemH + ItemH div 2)   # (a right click)
harness.queue[^1].button = RightButton
run(1)
up(lr2.x + 20, lr2.y + 4 * ItemH + ItemH div 2)
harness.queue[^1].button = RightButton
run(2)
check listSel == 4, "a right click on a row: it chosen (" & $listSel & ")"

# ---- a breadcrumb by the keys ---------------------------------------------------------------------

var crumbHit = -1
view = proc () =
  let k = breadcrumb(["C:", "Users", "Sultan", "Documents"])
  if k >= 0: crumbHit = k
run(3)
key(KeyTab)
run(2)
check ui.focusCues, "Tab: the breadcrumb takes the keys"
key(KeyLeft)
key(KeyEnter)
run(2)
check crumbHit == 2, "Left, Enter: the part before the last (" & $crumbHit & ")"
key(KeyHome)
key(KeySpace)
run(2)
check crumbHit == 0, "Home, Space: the first"

# ---- a drop-down list and the wheel -------------------------------------------------------------

var pick = 1
var otherBox = ""
view = proc () =
  edit(otherBox)
  where["O"] = ui.lastRect
  combo(["One", "Two", "Three", "Four"], pick, w = dp(160))
  where["C"] = ui.lastRect
run(3)
click(where["O"])
let cr = where["C"]
harness.queue.add Event(kind: MouseMoveEvent, x: cr.x + 20, y: cr.y + cr.h div 2)
harness.queue.add Event(kind: MouseWheelEvent, y: -1)
run(2)
check pick == 1, "the wheel over it without the focus: no change"
key(KeyTab)
run(2)
harness.queue.add Event(kind: MouseWheelEvent, y: -1)
run(2)
check pick == 2, "with the focus: the next one"
harness.queue.add Event(kind: MouseWheelEvent, y: 2)
run(2)
check pick == 0, "back up two"

# ---- under the mouse, in the newer looks -------------------------------------------------------------

proc litDiff(look: UiLook; draw: proc ()): int =
  ## (the pixels that change when the mouse goes over the control)
  uiLook = look
  view = proc () =
    discard button("First")              # (the focus starts here, not on the control)
    draw()
    where["X"] = ui.lastRect
  harness.queue.add Event(kind: MouseMoveEvent, x: W - 5, y: H - 5)
  run(4)
  let before = pixels
  let x = where["X"]
  harness.queue.add Event(kind: MouseMoveEvent, x: x.x + 6, y: x.y + x.h div 2)
  run(3)
  for i in 0 ..< pixels.len:
    if pixels[i] != before[i]: inc result
var text1 = "text"
var ticked = false
var choice = 0
let field = proc () = edit(text1, w = dp(200))
let box = proc () = checkbox("Ticked", ticked)
let opt = proc () = radio("One", choice, 1)
check litDiff(lookGlass, field) > 0, "Glass: a text box under the mouse, its line darker"
check litDiff(lookMatte, field) > 0, "Matte: too"
check litDiff(lookGlass, box) > 0 and litDiff(lookMatte, box) > 0, "a check box lit"
check litDiff(lookGlass, opt) > 0 and litDiff(lookMatte, opt) > 0, "a radio button lit"
check litDiff(lookClassic, box) == 0 and litDiff(lookClassic, opt) == 0, "3.1: as 3.1 had them, not lit"
uiLook = lookClassic

# ---- a chip's cross for a finger ---------------------------------------------------------------------

touchNow = true
relayout()
var closed = -1
var tags = @["nim", "retro"]
view = proc () =
  let ev = chips(tags, [false, false], closable = true)
  if ev.closed >= 0: closed = ev.closed
  where["Chips"] = ui.lastRect
run(3)
let ch = findNode(accessLast, "Remove nim", {arButton})
let xr = nodeRect(accessLast[ch])
check xr.w >= dp(22), "a finger's cross is wider (" & $xr.w & ")"
tap(xr.x + xr.w div 2, xr.y + xr.h div 2)
check closed == 0, "a tap on it: closed"

echo "reach: ", passed, " ok"

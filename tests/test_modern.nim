## The newer parts (retroui/modern and the keys' sheet): a large title that gives way to the bar's
## as the page scrolls, placeholders while content loads, an item lifted with its menu (a right
## click here), a page growing out of its card, the sheet of key shortcuts while Ctrl is held.

import std/strutils
import retroui
import retroui/uirelays/input
import retroui/inspect
import harness

fakeDriver()
startApp("Modern", W, H)
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

block largeTitles:
  view = proc () =
    discard navBar("Library")
    beginPanel(-1, "lib", plain = true)
    largeTitle("Library", "12 albums")
    for i in 0 ..< 60: label "Album " & $i
    endPanel()
  run(3)
  check largeTitleShown("Library"), "the large title on the screen"
  var headings = 0
  for nd in accessLast:
    if nd.role == arHeading and nd.name == "Library": inc headings
  check headings == 2, "said once by it, once by the bar (" & $headings & ")"
  move(W div 2, H div 2)
  for k in 0 ..< 4:
    harness.queue.add Event(kind: MouseWheelEvent, y: -1)
    run(2)
  run(30)
  check not largeTitleShown("Library"), "scrolled up under the bar: the bar's own title back"

block placeholders:
  view = proc () =
    label "Loading"
    skeletonRows(4)
    skeletonBlock(120, 80, round = true)
  run(2)
  var loading = 0
  for nd in accessLast:
    if nd.role == arProgressBar and nd.name == "Loading": inc loading
  check loading == 2, "placeholders say they are loading"
  let before = pixels
  ticks += 400
  run(2)
  check pixels != before, "the light sweeps over them"

block lift:
  var picked = -2
  var r: Rect
  view = proc () =
    label "Songs"
    let row = place(300, 40)
    fill(row, ui.theme.face)
    r = row
    let a = liftMenu(row, "song1", ["Play Next", "Add to Library", "Delete"], destructive = 2)
    if a >= 0: picked = a
  run(2)
  harness.queue.add Event(kind: MouseDownEvent, x: r.x + 20, y: r.y + 10, button: RightButton)
  run(1)
  harness.queue.add Event(kind: MouseUpEvent, x: r.x + 20, y: r.y + 10, button: RightButton)
  run(12)
  check liftedItem() == "song1" and node("Add to Library", {arMenuItem}) >= 0, "a right click: the item lifted, its menu"
  let m = nodeAt("Add to Library", {arMenuItem})
  check m.y >= r.y + r.h, "its menu under it"
  click(m, dx = m.w div 2)
  check picked == 1 and liftedItem() == "", "an action picked: it settles back"

block grows:
  var shownR: Rect
  let card = rect(40, 60, 100, 80)
  view = proc () =
    growing("album7", card):
      let r = place(0, 300, fill = true)
      fill(r, color(200, 30, 30))
      shownR = r
  run(1)
  var red = 0
  for y in 0 ..< H:
    for x in 0 ..< W:
      if px(x, y) == 0xC81E1E'u32: inc red
  check red > 0 and red < shownR.w * shownR.h div 3, "first it shows only round its card (" & $red & ")"
  ticks += 400
  run(3)
  red = 0
  for y in 0 ..< H:
    for x in 0 ..< W:
      if px(x, y) == 0xC81E1E'u32: inc red
  check red >= shownR.w * shownR.h - 10, "a quarter of a second on: all of it"

block keysSheet:
  view = proc () =
    menubar:
      menu "&File":
        discard menuItem("&New", "Ctrl+N")
        discard menuItem("&Open...", "Ctrl+O")
      menu "&Edit":
        discard menuItem("&Copy", "Ctrl+C")
    label "A document"
  run(2)
  harness.queue.add Event(kind: KeyDownEvent, key: KeyNone, mods: {CtrlPressed}, hasMods: true)
  run(1)
  check not shortcutSheetShown(), "Ctrl just pressed: nothing yet"
  ticks += 1000
  run(3)
  check shortcutSheetShown() and node("Keys", {arDialog}) >= 0, "Ctrl held: the sheet of keys"
  harness.queue.add Event(kind: KeyUpEvent, key: KeyNone, mods: {}, hasMods: true)
  run(2)
  check not shortcutSheetShown(), "let go of: gone"

echo passed, " passed"

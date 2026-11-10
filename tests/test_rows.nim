## `visibleRows`: a list drawn by hand costs the rows on the screen, not its
## length. Only the rows in view are drawn; the others keep their room (the
## panel's scroll range and what comes after are where they would be); rows
## of their own heights are kept from when they were drawn; and it is
## measured against drawing every row.

import std/[monotimes, times, strutils, sets]
import retroui
import retroui/uirelays/input
import harness

fakeDriver()
startApp("Rows", W, H)

var
  n = 3000
  useHelper = true
  varying = false
  drawn: HashSet[int]
  rowAt: seq[int]                 # where each drawn row's first cell was (y)
  afterY = 0                      # where the cell after the list was
  panelRect: Rect

proc rowText(i: int): string =
  if varying and i mod 7 == 0: "Row " & $i & " " & repeat("long words that wrap ", 12)
  else: "Row " & $i

proc listView() =
  drawn.clear()
  rowAt.setLen(n)
  for i in 0 ..< n: rowAt[i] = -1
  beginPanel(300, key = "rows")
  if useHelper:
    for i in visibleRows(n, key = "list", varying = varying):
      withId(i):
        rowAt[i] = layoutY()
        drawn.incl i
        if varying: paragraph(rowText(i)) else: label(rowText(i))
  else:
    for i in 0 ..< n:
      withId(i):
        rowAt[i] = layoutY()
        drawn.incl i
        label(rowText(i))
  afterY = layoutY()
  label("the end")
  endPanel()
  panelRect = ui.lastRect

view = proc () =
  listView()

proc wheelDown(notches: int) =
  queue.add Event(kind: MouseMoveEvent, x: 100, y: 100)
  for _ in 0 ..< notches: queue.add Event(kind: MouseWheelEvent, y: -1)
  run(80)                         # (the wheel glides: frames for it to get there)

block sameHeight:
  run(3)
  # (300 pixels of rows, ItemH each: about 20 of 3,000)
  doAssert drawn.len > 5 and drawn.len < 40, $drawn.len
  doAssert 0 in drawn
  let pitch = rowAt[1] - rowAt[0]
  doAssert pitch > 0
  # the room of all of them kept: the cell after them is 3,000 rows down
  doAssert afterY - rowAt[0] == n * pitch, $(afterY - rowAt[0]) & " " & $(n * pitch)
  # drawn all, the same places
  useHelper = false
  run(2)
  let allPitch = rowAt[1] - rowAt[0]
  let allAfter = afterY - rowAt[0]
  doAssert drawn.len == n
  doAssert allPitch == pitch and allAfter == n * pitch
  useHelper = true
  run(2)

block scrolled:
  # the wheel goes down: other rows drawn, at the places they had
  wheelDown(30)
  doAssert 0 notin drawn, "row 0 is out of view"
  var first = n
  for i in drawn: first = min(first, i)
  doAssert first > 0 and first < n
  let top = rowAt[first]
  let pitch = rowAt[first + 1] - rowAt[first]
  # (row 0 would be `first` rows above it)
  doAssert top - first * pitch < panelRect.y, "rows above keep their room"

block toTheEnd:
  # far down: the last rows and the cell after them
  wheelDown(2000)
  doAssert (n - 1) in drawn, "the last row is drawn at the bottom"
  doAssert drawn.len < 40

block varyingHeights:
  varying = true
  n = 400
  queue.add Event(kind: MouseMoveEvent, x: 100, y: 100)
  for _ in 0 ..< 3000: queue.add Event(kind: MouseWheelEvent, y: 1)   # (back to the top)
  run(80)
  doAssert 0 in drawn and drawn.len < 60, $drawn.len
  # row 0 wraps (i mod 7 == 0): taller than row 1
  let h0 = rowAt[1] - rowAt[0]
  let h1 = rowAt[2] - rowAt[1]
  doAssert h0 > h1, $h0 & " " & $h1
  # down and back: the heights of the rows drawn are kept, so the top comes
  # back where it was
  let top0 = rowAt[0]
  wheelDown(40)
  queue.add Event(kind: MouseMoveEvent, x: 100, y: 100)
  for _ in 0 ..< 40: queue.add Event(kind: MouseWheelEvent, y: 1)
  run(80)
  doAssert 0 in drawn and rowAt[0] == top0, $rowAt[0] & " " & $top0
  varying = false
  n = 3000

block inARow:
  # (in a row the cells go across: every row drawn)
  var got = 0
  view = proc () =
    got = 0
    row:
      for i in visibleRows(5): inc got
  run(2)
  doAssert got == 5
  view = proc () = listView()

block speed:
  # a frame with every row drawn against one with the rows in view
  proc timeIt(all: bool; count: int): float =
    n = count
    useHelper = not all
    run(3)
    let t0 = getMonoTime()
    for _ in 0 ..< 20:
      ui.redraw = true
      run(1)
    (getMonoTime() - t0).inMicroseconds.float / 20 / 1000
  for count in [3000, 10000]:
    let full = timeIt(true, count)
    let shown = timeIt(false, count)
    echo "  ", count, " rows: ", formatFloat(full, ffDecimal, 2), " ms a frame drawn all, ",
         formatFloat(shown, ffDecimal, 2), " ms with visibleRows"
    doAssert shown * 5 < full, "visibleRows is not cheaper"

echo "rows tests passed"

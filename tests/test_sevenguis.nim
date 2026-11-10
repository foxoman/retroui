## The 7GUIs example (examples/sevenguis.nim) does what each task asks,
## driven by its controls' names (the inspector's `findNode`), as a person
## would: the counter counts; the temperatures follow each other and not
## what is no number; the flight is booked only when the dates allow it;
## the timer stops at its duration; the names are created, filtered,
## updated and deleted; a circle is made, made larger and undone; a cell's
## change reaches the formulas that read it, a cycle is said so.
##
## SEVENGUIS_SHOTS=folder saves a picture of each task.

import std/[os, strutils, math]
import retroui/uirelays/[input, access]
import harness

const sevenGuisUnderTest = true
include ../examples/sevenguis

fakeDriver()
startApp("7GUIs", W, H)
accessKeep = true
view = proc () = sevenGuisFrame()

let shots = getEnv("SEVENGUIS_SHOTS")
proc shot(name: string) =
  if shots.len == 0: return
  ui.redraw = true                     # (the last frame shown: all of it)
  run(4)
  createDir(shots)
  var b = newBitmap(W, H)
  for i in 0 ..< W * H: b.px[i] = pixels[i] or 0xFF000000'u32
  b.changed()
  discard savePng(b, shots / name & ".png")

proc at(name: string; roles: set[AccessRole] = {}; nth = 0): Rect =
  let i = findNode(accessLast, name, roles, nth)
  doAssert i >= 0, "no control called " & name
  nodeRect(accessLast[i])

proc press(name: string; roles: set[AccessRole] = {arButton}) =
  click(at(name, roles), dx = at(name, roles).w div 2)
  run(2)

proc tab(name: string) =
  let r = at(name, {arTab})
  click(r, dx = r.w div 2)
  run(3)

proc fieldNo(n: int): Rect =
  ## (the n-th text box of the page, from the top)
  let i = findNode(accessLast, "", {arTextField}, n)
  doAssert i >= 0, "no text box " & $n
  nodeRect(accessLast[i])

proc typeInto(r: Rect; s: string) =
  click(r)
  key(KeyA, {CtrlPressed})
  run()
  typeText(s)
  run(2)

run(3)

block counter:
  tab("Counter")
  press("Count")
  press("Count")
  doAssert count == 2
  shot("1-counter")

block temperature:
  tab("Temperature")
  typeInto(fieldNo(0), "100")
  doAssert fahrenheit == "212", fahrenheit
  typeInto(fieldNo(1), "-40")
  doAssert celsius == "-40", celsius
  typeInto(fieldNo(0), "abc")
  doAssert fahrenheit == "-40", "not a number: the other stays"
  typeInto(fieldNo(0), "37")
  shot("2-temperature")

block flight:
  tab("Flight Booker")
  typeInto(fieldNo(0), "31.02.2026")
  let b = findNode(accessLast, "Book", {arButton})
  doAssert asDisabled in accessLast[b].states, "not a date: no booking"
  typeInto(fieldNo(0), "27.03.2026")
  press("Book")
  doAssert booked and "one-way flight on 27.03.2026" in bookedText, bookedText
  key(KeyEnter)
  run(2)
  doAssert not booked
  flightKind = 1
  run(2)
  typeInto(fieldNo(1), "20.03.2026")
  doAssert asDisabled in accessLast[findNode(accessLast, "Book", {arButton})].states,
           "back before out: no booking"
  doAssert findNode(accessLast, "before the flight out", {arLabel}) >= 0, "and it says why"
  shot("3-flight")
  typeInto(fieldNo(1), "02.04.2026")
  press("Book")
  doAssert "return flight from 27.03.2026 to 02.04.2026" in bookedText, bookedText
  key(KeyEnter)
  run(2)

block timer:
  tab("Timer")
  durationTenths = 20                  # 2 s
  elapsedMs = 0
  lastTick = -1
  for _ in 0 ..< 30:
    ticks += 100
    run()
  doAssert elapsedMs == 2000, "it stops at the duration: " & $elapsedMs
  durationTenths = 30
  for _ in 0 ..< 5:
    ticks += 100
    run()
  doAssert elapsedMs > 2000 and elapsedMs <= 3000, "a longer duration: on again " & $elapsedMs
  shot("4-timer")
  press("Reset")
  doAssert elapsedMs < 200

block crud:
  tab("CRUD")
  typeInto(fieldNo(1), "Ada")
  typeInto(fieldNo(2), "Lovelace")
  press("Create")
  doAssert people.len == 4 and people[^1].surname == "Lovelace"
  typeInto(fieldNo(0), "m")
  doAssert pick == -1
  # (the list shows Mustermann alone)
  let list = at("", {arList})
  click(list, dy = 6)
  run(2)
  doAssert firstName == "Max" and lastName == "Mustermann", firstName & " " & lastName
  typeInto(fieldNo(1), "Maxi")
  press("Update")
  doAssert people[1].name == "Maxi"
  shot("5-crud")
  press("Delete")
  doAssert people.len == 3 and people[1].surname == "Tisch"
  typeInto(fieldNo(0), "")

block circleDrawer:
  tab("Circle Drawer")
  let undoAt = at("Undo", {arButton})
  # (the canvas: below the buttons)
  let cx = undoAt.x + 80
  let cy = undoAt.y + undoAt.h + 80
  click(rect(cx, cy, 1, 1), dx = 0, dy = 0)
  run(2)
  click(rect(cx + 100, cy + 30, 1, 1), dx = 0, dy = 0)
  run(2)
  doAssert circles.len == 2, $circles.len
  # a right click on the first one: Adjust diameter
  queue.add Event(kind: MouseMoveEvent, x: cx, y: cy)
  run()
  doAssert chosen == 0
  queue.add Event(kind: MouseDownEvent, x: cx, y: cy, button: RightButton, clicks: 1)
  queue.add Event(kind: MouseUpEvent, x: cx, y: cy, button: RightButton)
  run(2)
  let item = at("Adjust diameter", {arMenuItem})
  click(item, dx = item.w div 2)
  run(3)
  doAssert adjusting
  for _ in 0 ..< 10: key(KeyRight)
  run(2)
  doAssert circles[0].d > 30, $circles[0].d
  shot("6-circles")
  press("Close")
  doAssert not adjusting and undoSteps.len == 3
  press("Undo")
  doAssert circles[0].d == 30, "the diameter undone"
  press("Undo")
  doAssert circles.len == 1
  press("Redo")
  doAssert circles.len == 2

block cells:
  tab("Cells")
  doAssert cellText(3 * Cols + 3) == "7", cellText(3 * Cols + 3)        # D3 = 3.50 * 2
  doAssert cellText(5 * Cols + 3) == "17.5", cellText(5 * Cols + 3)     # D5 = SUM(D1:D3)
  # a change reaches the cells that read it
  setCell(1 * Cols + 2, "10")                                            # C1 = 10
  doAssert cellText(1 * Cols + 3) == "12" and cellText(5 * Cols + 3) == "24.7"
  # an edit in the grid: F2 starts from the formula, not its value
  run(2)
  cellPick = 1
  run(2)
  shot("7-cells")
  # cycles and errors
  setCell(0 * Cols + 5, "=F1+1")
  setCell(1 * Cols + 5, "=F0*2")
  doAssert cellText(5) == "#CYCLE", cellText(5)
  setCell(2 * Cols + 5, "=1/0")
  doAssert cellText(2 * Cols + 5) == "#DIV/0"
  setCell(3 * Cols + 5, "=FOO(A1)")
  doAssert cellText(3 * Cols + 5) == "#NAME"
  setCell(4 * Cols + 5, "=A1+1")
  doAssert cellText(4 * Cols + 5) == "#VALUE", "a text cell in a sum"
  setCell(6 * Cols + 5, "=MAX(B1:B3) - MIN(B1:B3)")
  doAssert cellText(6 * Cols + 5) == "2.55", cellText(6 * Cols + 5)

echo "7GUIs tests passed"

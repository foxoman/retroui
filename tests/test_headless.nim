## Tests of a program run without a window (retroui/headless): its frames drawn into memory,
## the input it is given used, what it drew taken as a picture.

import retroui, retroui/headless
import retroui/uirelays/input

useHeadless(320, 200)
startApp("Headless", 320, 200)
var clicked = 0
proc frame() =
  label "Drawn without a window"
  if button("Press"): inc clicked
for i in 0 ..< 3:
  discard beginFrame()
  frame()
  endFrame()
let shot = headlessShot()
doAssert shot.w == 320 and shot.h == 200
var colors: seq[uint32]
for p in shot.px:
  if p notin colors: colors.add p
  if colors.len > 3: break
doAssert colors.len > 3, "something drawn"
# a click on the button, given as a person would
headlessInput(Event(kind: MouseMoveEvent, x: 30, y: 40))
headlessInput(Event(kind: MouseDownEvent, x: 30, y: 40, button: LeftButton, clicks: 1))
for i in 0 ..< 2:
  discard beginFrame()
  frame()
  endFrame()
headlessInput(Event(kind: MouseUpEvent, x: 30, y: 40, button: LeftButton))
for i in 0 ..< 2:
  discard beginFrame()
  frame()
  endFrame()
doAssert clicked == 1, "the button pressed: " & $clicked
# a label that ends in ':' goes to the next line with its field, not alone at the end of one
var lab, field, lab2, field2, other: Rect
proc wrapFrame() =
  row:
    discard place(200, 20)
    label "Name:"
    lab = ui.lastRect
    field = place(90, 20)
  row:
    discard place(100, 20)
    label "A:"
    lab2 = ui.lastRect
    field2 = place(50, 20)
  row:
    discard place(200, 20)
    label "units"                 # (no ':': not a field's name, stays where it fits)
    other = ui.lastRect
    discard place(90, 20)
proc sameLine(a, b: Rect): bool = abs((a.y + a.h div 2) - (b.y + b.h div 2)) <= 2
for i in 0 ..< 3:
  discard beginFrame()
  wrapFrame()
  endFrame()
doAssert lab.sameLine(field) and lab.x < field.x and lab.x < 100, "the label with its field: " & $lab & " " & $field
doAssert lab2.sameLine(field2) and lab2.x > 100, "a label and field that fit stay: " & $lab2
doAssert other.x > 200, "a label that names nothing stays: " & $other
stopApp()
echo "test_headless: ok"

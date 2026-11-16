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
stopApp()
echo "test_headless: ok"

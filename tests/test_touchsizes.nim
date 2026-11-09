## Control sizes asked for in the environment: RETRO_TOUCH=1 gives
## finger-sized controls on a screen as big as a tablet's (where automatic
## sizes stay a desktop's), RETRO_CONTROLS chooses the sizes alone.

import std/os
import retroui
import retroui/uirelays/screen
import harness

fakeDriver()
# a tablet's screen (1280 x 800): automatic sizes would be a desktop's
windowRelays.createWindow = proc (l: var ScreenLayout; icon: pointer; iconLen: int) =
  l.width = 1280; l.height = 800; l.scaleX = 1; l.scaleY = 1; l.uiScale = 100
windowRelays.getWindowLayout = proc (): ScreenLayout =
  ScreenLayout(width: 1280, height: 800, scaleX: 1, scaleY: 1, uiScale: 100)
drawRelays.blitRGBA = proc (p: ptr UncheckedArray[uint32]; w, h: int;
                            dst: Rect; f: RGBAFormat): bool =
  for y in 0 ..< h:
    for x in 0 ..< w:
      if dst.y + y < H and dst.x + x < W: pixels[(dst.y + y) * W + dst.x + x] = p[y * w + x]
  true

var btnH = 0
view = proc () =
  if button("Tap me"): discard
  btnH = ui.lastRect.h

# what the environment asks
for (touch, controls, want) in [("", "", ""), ("1", "", "Touch"), ("", "desktop", "Desktop"),
                                ("1", "desktop", "Desktop"), ("", "AUTO", "Automatic"),
                                ("", "fingers", "Touch"), ("0", "", "")]:
  putEnv("RETRO_TOUCH", touch)
  putEnv("RETRO_CONTROLS", controls)
  doAssert sizesFromEnv() == want, touch & "/" & controls & ": " & sizesFromEnv()
putEnv("RETRO_CONTROLS", "")

# RETRO_TOUCH=1 on a tablet: a finger, and controls a finger can hit
putEnv("RETRO_TOUCH", "1")
startApp("touchsizes", 1280, 800)
run(3)
doAssert ui.touch and controlSizes() == csTouch and fingers(), $controlSizes()
let touchH = btnH
# the same screen with desktop sizes: smaller
setControlSizes(csDesktop)
run(3)
doAssert not fingers() and btnH < touchH, $btnH & " " & $touchH
# automatic on a tablet: a desktop's sizes (the screen holds a desktop layout)
setControlSizes(csAuto)
run(3)
doAssert not fingers() and btnH < touchH
echo "test_touchsizes: ok (", touchH, " px touch, ", btnH, " px desktop)"

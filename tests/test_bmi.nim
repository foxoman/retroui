## BMI Studio (examples/bmi.nim) without a window: the numbers (rounded to
## a decimal before they are classed, both unit systems), and the window's
## frame run -- Calculate BMI the default button, in the accent colour and
## taller than a button is; the units' option boxes pressed anywhere in
## the box; the numbers following the units; another colour scheme taken
## by the bands, the tag and the accent button; a phone's layout.

import std/math
import retroui/uirelays/[coords, screen]
import harness

const bmiUnderTest = true
include "../examples/bmi.nim"

# the numbers
resetAll()
doAssert bmi.isNaN and resultText().startsWith("Enter your height")
doAssert computeBmi() == 24.5                         # 75 kg, 1.75 m: 24.49
weightKg = 80
heightCm = 179
doAssert computeBmi() == 25.0 and bandOf(Classes, computeBmi()) == 2   # 24.97 shows 25.0: overweight, as shown
weightKg = 50
doAssert bandOf(Classes, computeBmi()) == 0
weightKg = 120
doAssert bandOf(Classes, computeBmi()) == 3
resetAll()
units = 1
doAssert abs(computeBmi() - 24.4) < 1e-9              # 165 lb, 69 in
resetAll()

# (a window the app's own size -- the harness's is smaller -- and its pixels)
var winW = 680
var winH = 610
var shot = newSeq[uint32](winW * winH)
fakeDriver()
windowRelays.createWindow = proc (l: var ScreenLayout; icon: pointer; iconLen: int) =
  l.width = winW; l.height = winH; l.scaleX = 1; l.scaleY = 1; l.uiScale = 100
windowRelays.getWindowLayout = proc (): ScreenLayout =
  ScreenLayout(width: winW, height: winH, scaleX: 1, scaleY: 1, uiScale: 100)
drawRelays.blitRGBA = proc (p: ptr UncheckedArray[uint32]; w, h: int; dst: Rect; f: RGBAFormat): bool =
  for y in 0 ..< h:
    for x in 0 ..< w:
      if dst.y + y < winH and dst.x + x < winW: shot[(dst.y + y) * winW + dst.x + x] = p[y * w + x]
  true
startApp("bmi", winW, winH, StudioTheme)
var calcBtn: Rect
view = proc () =
  bmiFrame()
run(4)

proc find(c: Color): tuple[n, x0, y0, x1, y1: int] =
  ## (the pixels of one colour: how many, and their box)
  result = (0, high(int), high(int), -1, -1)
  let want = (uint32(c.r) shl 16) or (uint32(c.g) shl 8) or uint32(c.b)
  for y in 0 ..< ui.h:
    for x in 0 ..< ui.w:
      if (shot[y * winW + x] and 0xFFFFFF'u32) == want:
        inc result.n
        result.x0 = min(result.x0, x)
        result.y0 = min(result.y0, y)
        result.x1 = max(result.x1, x)
        result.y1 = max(result.y1, y)

# Calculate BMI: in the accent colour, 42 high -- a button of the kit, by its options
let acc = find(StudioTheme.accent)
doAssert acc.n > 4000, $acc.n
doAssert acc.y1 - acc.y0 + 1 >= dp(42) - 10 and acc.y1 - acc.y0 + 1 <= dp(42), $acc   # (its face, inside the bevel)
calcBtn = rect(acc.x0, acc.y0, acc.x1 - acc.x0 + 1, acc.y1 - acc.y0 + 1)

# Enter presses it (the default button)
doAssert bmi.isNaN
key(KeyEnter)
run(2)
doAssert bmi == 24.5 and "within the healthy" in resultText()
# the healthy band's colour is on the dial, the range bar and the tag
doAssert find(goodColor()).n > 1500

# a click on it too, after the numbers change
weightKg = 95
run(1)
click(calcBtn)
run(2)
doAssert abs(bmi - 31.0) < 1e-9 and "obese" in resultText()

# the units: View > Imperial's twin on the page is a boxed option -- pressed anywhere in its box
units = 1
run(2)
doAssert heightIn == 69 and weightLb == 209           # (the numbers follow the units)
units = 0
run(2)
doAssert heightCm == 175 and weightKg == 95

# another scheme: the accent button, the bands and the tag are that scheme's
resetAll()
calculate()
ui.theme = Dusk
run(3)
doAssert find(StudioTheme.accent).n == 0 and find(accentColor()).n > 4000
doAssert find(goodColor()).n > 1500
ui.theme = StudioTheme

# Ctrl+R resets; F5 calculates
key(KeyR, {CtrlPressed})
run(2)
doAssert bmi.isNaN
key(KeyF5)
run(2)
doAssert bmi == 24.5

# on a phone: one column, nothing off the right edge
winW = 380
winH = 760
shot = newSeq[uint32](winW * winH)
queue.add Event(kind: WindowResizeEvent, x: winW, y: winH)
run(4)
doAssert isCompact() and ui.w == 380
doAssert find(accentColor()).x1 < 380 - 4 and find(accentColor()).n > 3000   # (Calculate BMI whole, on the page)
echo "bmi ok"

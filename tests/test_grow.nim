## Grow (examples/grow.nim) without a window: the plan's numbers, the
## plan page's main button at the foot (spring() in a column), and the
## result page's timeline played to its end -- every bar risen to its
## year's height, one after another, the coin there, the goal felt -- then
## Back to the plan.

import std/math
import harness

const growUnderTest = true
include "../examples/grow.nim"

# the plan's numbers
let flat = compute(100, 1000, 2, 0)          # no growth: what was put in
doAssert flat.years == @[1200.0, 2400.0]
doAssert flat.total == 2400 and flat.paidIn == 2400
doAssert flat.goalMonth == 10                # 1,000 reached after the 10th month
let grown = compute(100, 1e9, 10, 6)         # 6% a year, monthly: the annuity's formula
let r = 0.06 / 12
doAssert abs(grown.total - 100 * ((1 + r).pow(120) - 1) / r) < 1e-6
doAssert grown.goalMonth == 0 and grown.years.len == 10

fakeDriver()
startApp("grow", 400, 820)
var buttonRect: Rect
view = proc () =
  pageView(nav):
    case nav.page
    of "result": resultPage()
    else:
      planPage()
      buttonRect = ui.lastRect
run(4)
doAssert nav.page == "plan"
doAssert buttonRect.y + buttonRect.h >= ui.h - Pad - 2 and buttonRect.y > ui.h div 2,
  "See my plan at the foot of the page: " & $buttonRect

# See my plan (Enter: the default button)
key(KeyEnter)
run(2)
doAssert nav.page == "result", "the result page"
let n = plan.years.len
doAssert n == years and coin == n + 1    # (the bars, the floor, the coin)
# a little in: the first bar rising, the last not yet
run(25)                                 # (400 ms)
doAssert scene.meshes[0].scale.y > 0.01 and scene.meshes[n - 1].scale.y < 0.01,
  "one after another: " & $scene.meshes[0].scale.y & " " & $scene.meshes[n - 1].scale.y
# the end: every bar at its year's height, the coin all there, the goal felt
run(200)
for i in 0 ..< n:
  doAssert abs(scene.meshes[i].scale.y - plan.years[i] * unitH) < 1e-6, "bar " & $i
doAssert scene.meshes[coin].scale.x == 1.0
doAssert felt and plan.goalMonth > 0
# Back: the plan again
nav.pop()
run(30)
doAssert nav.page == "plan"
echo "test_grow: ok"

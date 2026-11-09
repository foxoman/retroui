## The 3D view drawn on the GPU (`view3dgl`) against the same scene drawn
## by the CPU (`render3d`): a car of materials (paint, tires, glass), its
## parts tinted and hidden, a clip at a moment -- the two pictures alike
## (the GPU's own rounding apart). Run under a display with OpenGL
## (Xvfb and Mesa will do), frames on the GPU:
##
##   RETRO_GPU=gpu xvfb-run -a build/gpu3dcheck
##
## Exit code: the failures (2: no GPU here).

import std/[math, strutils]
import retroui, retroui/[gfx, view3d]

include "../carscene.nim"

var car = carScene()
var cam = camera3(yaw = 35, pitch = 18)
fitView(car, cam)
var step = 0
var frames = 0
var failed = 0

proc compare(what: string) =
  if not view3dOnGpu():
    echo "FAIL ", what, ": the view was not drawn by the GPU"
    inc failed
    return
  let g = view3dPicture()
  if g == nil:
    echo "FAIL ", what, ": no picture from the view"
    inc failed
    return
  let c = render3d(car, cam, g.w, g.h)
  var total = 0
  var far = 0
  for i in 0 ..< g.w * g.h:
    var worst = 0
    for sh in [0, 8, 16]:
      let d = abs(int((g.px[i] shr sh) and 255) - int((c.px[i] shr sh) and 255))
      total += d
      worst = max(worst, d)
    if worst > 40: inc far
  let mean = total.float / float(g.w * g.h * 3)
  let farShare = far.float / float(g.w * g.h)
  let ok = mean < 4 and farShare < 0.02
  echo (if ok: "PASS " else: "FAIL "), what, ": mean difference ", formatFloat(mean, ffDecimal, 2),
       ", pixels far apart ", formatFloat(farShare * 100, ffDecimal, 2), " %"
  if not ok: inc failed

app "gpu3d", 820, 560:
  discard view3d(car, cam, controls = false)
  inc frames
  if frames == 5 and not drawnWithGpu():
    echo "no GPU here (frames drawn by the CPU)"
    quit 2
  if frames mod 6 == 0:
    case step
    of 0: compare("the car")
    of 1:
      car.tint("Car", color(0, 90, 200))
      sceneChanged(car)
    of 2: compare("tinted")
    of 3:
      car.tint("Car", Color())
      car.setVisible("Door", false)
      car.seekAnimation("WheelsTurn", 0.7)
    of 4: compare("a part hidden, a clip at a moment")
    of 5:
      cam.yaw = 200
      cam.pitch = -10
    of 6: compare("from behind and below")
    else:
      echo "DONE ", failed
      quit failed
    inc step
  wakeIn(16)

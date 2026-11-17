## Tests of Relight and Upscale (retroui/photorelight): lights where they are put, the relief
## of a depth map; a picture made bigger that is, made smaller again, the picture it was.

import retroui/[photo, photofx, photorelight]

proc lum(p: uint32): int = int((p shr 16) and 255) + int((p shr 8) and 255) + int(p and 255)

block lights:
  var img = newImg(200, 100)
  for v in img.px.mitems: v = 0xFF808080'u32
  filterOrigin = (0, 0)
  filterSize = (0, 0)
  let lit = relight(@[RelightLight(kind: rlPoint, x: 0.1, y: 0.5, height: 0.2, radius: 0.6, intensity: 1.5,
                                   color: 0xFFFFFFFF'u32)], ambient = 0.4)(img, rect(0, 0, 200, 100))
  doAssert lum(lit.px[50 * 200 + 20]) > lum(lit.px[50 * 200 + 180]) + 100        # (bright by the light)
  doAssert lum(lit.px[50 * 200 + 190]) < lum(img.px[0])                          # (dim far off: the ambient)
  # a warm light: warm where it falls
  let warm = relight(@[RelightLight(x: 0.5, y: 0.5, intensity: 1, color: 0xFFFF8000'u32)],
                     ambient = 0.3)(img, rect(0, 0, 200, 100))
  let c = warm.px[50 * 200 + 100]
  doAssert ((c shr 16) and 255) > (c and 255) + 60
  # a spot pointing right: its pool of light where it points (half its reach on: x 130), not
  # under the light nor behind it, round the way it points (an ellipse), not a wedge from the light
  let spot = relight(@[RelightLight(kind: rlSpot, x: 0.3, y: 0.5, angle: 0, cone: 40, intensity: 1.5,
                                    color: 0xFFFFFFFF'u32)], ambient = 0.3)(img, rect(0, 0, 200, 100))
  doAssert lum(spot.px[50 * 200 + 130]) > lum(spot.px[50 * 200 + 30]) + 60
  doAssert lum(spot.px[50 * 200 + 130]) > lum(spot.px[50 * 200 + 60]) + 60
  doAssert lum(spot.px[50 * 200 + 130]) > lum(spot.px[5 * 200 + 130])          # (narrower than a wedge there)
  # the sun with a relief: the side of a mound toward it lit, the side away in shade
  var depth = newSeq[uint8](200 * 100)
  for y in 0 ..< 100:
    for x in 0 ..< 200:
      let d = abs(x - 100) + abs(y - 50)
      depth[y * 200 + x] = uint8(clamp(255 - (60 - d) * 4, 0, 255))      # (a mound: near in its middle)
  let sun = relight(@[RelightLight(kind: rlSun, angle: 180, height: 0.4, intensity: 1.2, color: 0xFFFFFFFF'u32)],
                    ambient = 0.3, depth = depth, depthW = 200, depthH = 100, relief = 2)(img, rect(0, 0, 200, 100))
  doAssert lum(sun.px[50 * 200 + 75]) > lum(sun.px[50 * 200 + 125]) + 30      # (lit from the left)
  let j = RelightLight(kind: rlSpot, x: 0.2, y: 0.7, angle: 45, cone: 30, intensity: 2, color: 0xFF00FF00'u32).toJson
  doAssert relightLightFrom(j).kind == rlSpot and relightLightFrom(j).cone == 30

block upscale:
  var img = newImg(40, 30)
  for y in 0 ..< 30:
    for x in 0 ..< 40:
      # (a slanted edge and some texture)
      img.px[y * 40 + x] = if x > y + 5: 0xFFE0E0E0'u32 else: 0xFF202020'u32 + uint32((x * 7 + y * 3) mod 9) * 0x010101'u32
  let big = upscaleDetail(img, 2)
  doAssert big.w == 80 and big.h == 60
  # made smaller again: the picture it came from (within a little)
  var worst = 0
  for y in 0 ..< 30:
    for x in 0 ..< 40:
      var s = 0
      for j in 0 .. 1:
        for i in 0 .. 1: s += lum(big.px[(y * 2 + j) * 80 + x * 2 + i])
      worst = max(worst, abs(s div 4 - lum(img.px[y * 40 + x])))
  doAssert worst < 3 * 40, $worst
  # its edge as sharp as the picture's: from dark to light in about two of its pixels
  let row = 40
  var steps = 0
  for x in 0 ..< 79:
    if abs(lum(big.px[row * 80 + x + 1]) - lum(big.px[row * 80 + x])) > 120: inc steps
  doAssert steps >= 1
  doAssert upscaleDetail(img, 3).w == 120 and upscaleDetail(img, 4).h == 120

block shadows:
  # a box on a light floor, its shadow to its right: found with it, not the floor far off
  var img = newImg(200, 120)
  for v in img.px.mitems: v = 0xFFD8D0C0'u32
  var sel = newSeq[uint8](200 * 120)
  for y in 40 ..< 80:
    for x in 60 ..< 100:
      img.px[y * 200 + x] = 0xFF2050A0'u32
      sel[y * 200 + x] = 255
  for y in 50 ..< 82:
    for x in 100 ..< 140: img.px[y * 200 + x] = 0xFF6E6A62'u32      # (its shadow)
  for y in 10 ..< 20:
    for x in 10 ..< 20: img.px[y * 200 + x] = 0xFF505050'u32         # (something dark far off)
  let s = shadowOf(img, sel)
  doAssert s[60 * 200 + 120] >= 200                                  # (in the shadow)
  doAssert s[60 * 200 + 160] == 0 and s[15 * 200 + 15] == 0          # (the floor; the far thing)
  doAssert s[60 * 200 + 80] == 0                                     # (not the object itself)
  doAssert shadowOf(img, newSeq[uint8](200 * 120)).len == 200 * 120

echo "relight ok"

## Tests of `retroui/photoblurs`: Average, Box Blur, Shape Blur, Smart Blur
## and Lens Blur -- the kernels' runs, the means they give, transparency,
## a depth map keeping what is in focus, and big radii.

import std/math
import retroui/[gfx, photo, photofx, photoblurs, photoshapes]

proc picture(w, h: int): Img =
  result = newImg(w, h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let v = if (x div 8 + y div 8) mod 2 == 0: 40 else: 210
      result.px[y * w + x] = argb(255, (v + x) mod 256, (v + y * 2) mod 256, (x * 3 + y) mod 256)

let im = picture(96, 72)
let whole = rect(0, 0, im.w, im.h)

proc meanOf(im: Img; x0, y0, x1, y1: int): tuple[r, g, b: float] =
  var n = 0
  for y in y0 .. y1:
    for x in x0 .. x1:
      let p = im.px[clamp(y, 0, im.h - 1) * im.w + clamp(x, 0, im.w - 1)]
      result.r += rOf(p).float; result.g += gOf(p).float; result.b += bOf(p).float
      inc n
  result = (result.r / n.float, result.g / n.float, result.b / n.float)

block average:
  let o = averageBlur()(im, whole)
  let m = meanOf(im, 0, 0, im.w - 1, im.h - 1)
  for p in o.px:
    doAssert p == o.px[0], "one color"
  doAssert abs(rOf(o.px[0]).float - m.r) <= 1 and abs(bOf(o.px[0]).float - m.b) <= 1

block boxIsTheSquaresMean:
  for r in [1, 3, 7]:
    let o = boxBlurImg(im, r)
    for (x, y) in [(10, 10), (40, 30), (0, 0), (95, 71), (50, 2)]:
      let m = meanOf(im, x - r, y - r, x + r, y + r)
      let p = o.px[y * im.w + x]
      doAssert abs(rOf(p).float - m.r) <= 1.5 and abs(gOf(p).float - m.g) <= 1.5 and abs(bOf(p).float - m.b) <= 1.5,
               "radius " & $r & " at " & $(x, y)
  # a huge radius: everything the picture's mean, no fault
  let big = boxBlurImg(im, 2000)
  doAssert big.px.len == im.px.len

block transparencyWeighted:
  # a clear pixel's color never leaks in: half clear, half red
  var t = newImg(20, 20)
  for i in 0 ..< t.px.len: t.px[i] = if i mod 20 < 10: 0x0000FF00'u32 else: 0xFFFF0000'u32
  for o in [boxBlurImg(t, 4), shapeBlurImg(t, 4, @[], 0), lensBlurImg(t, LensBlur(radius: 4, blades: 6))]:
    let p = o.px[10 * 20 + 9]
    doAssert aOf(p) > 0 and aOf(p) < 255, "the edge half covered"
    doAssert gOf(p) == 0 and rOf(p) >= 250, "red, no green from the clear pixels"

block irisShapes:
  let c = irisRuns(10, 0)
  doAssert abs(c.count.float - PI * 100) < 40, "a circle's area: " & $c.count
  let tri = irisRuns(10, 3)
  let hex = irisRuns(10, 6)
  doAssert tri.count < hex.count and hex.count < c.count, "fewer blades, less area"
  let bent = irisRuns(10, 6, 100)
  doAssert bent.count == c.count, "blades bent all the way: a circle"
  doAssert irisRuns(0).count == 1

block shapeBlurOfAShape:
  # a ring kernel: the mean of a ring, not of the disc
  var spot = newImg(41, 41)
  for i in 0 ..< spot.px.len: spot.px[i] = 0xFF000000'u32
  spot.px[20 * 41 + 20] = 0xFFFFFFFF'u32
  let ring = shapeMask(customPath(CustomShapes.len - 1, 0, 0, 21, 21), 21, 21)
  let o = shapeBlurImg(spot, 10, ring, 21)
  var lit = 0
  for p in o.px:
    if rOf(p) > 0: inc lit
  doAssert lit > 4, "the spot spread into the kernel's shape"

block lensDepth:
  # the depth map: what is at the focal distance stays as it is; the far half blurs
  var depth = newSeq[uint8](im.w * im.h)
  for y in 0 ..< im.h:
    for x in 0 ..< im.w: depth[y * im.w + x] = if x < 48: 0 else: 255
  let o = lensBlurImg(im, LensBlur(radius: 6, blades: 5), depth)
  for y in 0 ..< im.h:
    for x in 0 ..< 40: doAssert o.px[y * im.w + x] == im.px[y * im.w + x], "in focus: kept"
  var changed = 0
  for y in 0 ..< im.h:
    for x in 56 ..< im.w:
      if o.px[y * im.w + x] != im.px[y * im.w + x]: inc changed
  doAssert changed > (im.h * 40) div 2, "out of focus: blurred"
  # inverted: the other half
  let inv = lensBlurImg(im, LensBlur(radius: 6, blades: 5, invert: true), depth)
  doAssert inv.px[10 * im.w + 90] == im.px[10 * im.w + 90]

block lensHighlights:
  # a bright point on black: the specular lights make its disc brighter
  var s = newImg(40, 40)
  for i in 0 ..< s.px.len: s.px[i] = 0xFF000000'u32
  s.px[20 * 40 + 20] = 0xFFFFFFFF'u32
  let plain = lensBlurImg(s, LensBlur(radius: 5, blades: 6))
  let bright = lensBlurImg(s, LensBlur(radius: 5, blades: 6, brightness: 100, threshold: 200))
  doAssert rOf(bright.px[20 * 40 + 22]) > rOf(plain.px[20 * 40 + 22])
  # as light: the disc's pixels brighter than a mean of levels would make them
  doAssert rOf(plain.px[20 * 40 + 22]) > 255 div 70

block lensNoise:
  let a = lensBlurImg(im, LensBlur(radius: 3, noise: 20, mono: true))
  let b = lensBlurImg(im, LensBlur(radius: 3))
  doAssert a.px != b.px
  for p in a.px:
    doAssert rOf(p) >= 0
  let again = lensBlurImg(im, LensBlur(radius: 3, noise: 20, mono: true))
  doAssert again.px == a.px, "the same noise each time"

block bigRadii:
  var big = picture(300, 200)
  for f in [lensBlur(LensBlur(radius: 100, blades: 6)), shapeBlur(200, @[], 0), boxBlur(300)]:
    let o = f(big, rect(0, 0, 300, 200))
    doAssert o.w == 300 and o.h == 200

block depthFromTheLayer:
  # a depth map of the whole layer: the filter finds its part by filterOrigin
  var depth = newSeq[uint8](200 * 100)
  for i in 0 ..< depth.len: depth[i] = if i mod 200 < 100: 0 else: 255
  filterOrigin = (100, 0)
  let o = lensBlur(LensBlur(radius: 4), depth, 200, 100)(im, whole)
  var changed = 0
  for i in 0 ..< o.px.len:
    if o.px[i] != im.px[i]: inc changed
  doAssert changed > o.px.len div 2, "its part is all far: blurred"
  filterOrigin = (0, 0)
  let k = lensBlur(LensBlur(radius: 4), depth, 200, 100)(im, whole)
  doAssert k.px == im.px, "its part is all near: kept"

block smart:
  # flat areas blurred, the edge between them kept; Edge Only: white on black
  var t = newImg(40, 20)
  for i in 0 ..< t.px.len:
    let x = i mod 40
    let v = (if x < 20: 60 else: 200) + (i * 7919 mod 9) - 4
    t.px[i] = argb(255, v, v, v)
  let o = smartBlur(4, 20)(t, rect(0, 0, 40, 20))
  doAssert abs(int(rOf(o.px[10 * 40 + 18])) - 60) <= 4 and abs(int(rOf(o.px[10 * 40 + 21])) - 200) <= 4
  let e = smartBlur(4, 20, 2, 1)(t, rect(0, 0, 40, 20))
  doAssert (e.px[10 * 40 + 19] and 0xFFFFFF'u32) == 0xFFFFFF'u32 and (e.px[10 * 40 + 5] and 0xFFFFFF'u32) == 0

echo "test_photoblurs: ok"

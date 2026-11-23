## Tests of what 0.71 added to the image editor's engine (retroui/photomore and its neighbours):
## the new filters and adjustments, the masks from a range, Shake Reduction's estimate and its
## sharpening, the stars stacked and lined up, the 360 views, the gradient taken out, the relief
## mesh; the new live shapes, letters turned one by one and the Type on a Path effects, Area
## Type's frame, the Scatter chart and the two extra Hue Curves.

import std/[math, random, json, strutils, sequtils]
import retroui/[gfx, photo, photofx, photomore, photodevelop, liveshapes, photoshapes, textengine,
                infographics, photowarp, photostyles]

proc textured(w, h: int; seed = 1): Img =
  ## (a picture with detail everywhere: soft blobs of color over a gradient)
  var rng = initRand(seed)
  result = newImg(w, h)
  for y in 0 ..< h:
    for x in 0 ..< w: result.px[y * w + x] = argb(255, 60 + x * 120 div w, 80 + y * 100 div h, 120)
  for k in 0 ..< (w * h) div 60:
    let cx = rng.rand(w - 1)
    let cy = rng.rand(h - 1)
    let c = argb(255, rng.rand(255), rng.rand(255), rng.rand(255))
    for dy in -2 .. 2:
      for dx in -2 .. 2:
        let x = cx + dx
        let y = cy + dy
        if x >= 0 and y >= 0 and x < w and y < h and dx * dx + dy * dy <= 5: result.px[y * w + x] = c

proc meanDiff(a, b: Img): float =
  for i in 0 ..< a.px.len: result += abs(lumaOf(a.px[i]) - lumaOf(b.px[i])).float
  result /= float(a.px.len)

let im = textured(160, 120)
let all = rect(0, 0, im.w, im.h)

block filtersRun:
  # every new filter keeps the size and changes the picture
  for (n, f) in [("Texture Detail", textureDetail(60)), ("Multi Band Sharpen", multiBandSharpen(100, 100, 50, 1)),
                 ("Bilateral Blur", bilateralBlur(6, 30)), ("Ambient Occlusion", ambientOcclusion(8, 60)),
                 ("Mixed Light Correction", mixedLightCorrection(80)), ("Tone Compression", toneCompression(50, 20)),
                 ("Color Grading", colorGrading((220.0, 40.0, 0.0), (30.0, 10.0, 0.0), (45.0, 40.0, 0.0))),
                 ("Channel Inversion", channelInversion(0)), ("Glitch", glitch()),
                 ("Adaptive Wide Angle", adaptiveWideAngle(0, 12)), ("Shake Reduction", shakeReduction(30, 8)),
                 ("Flame", flame(@[(20.0, 110.0), (140.0, 110.0)])), ("Tree", tree(rect(20, 10, 120, 110))),
                 ("Picture Frame", pictureFrame(all)), ("Remove Background Gradient", removeGradient())]:
    let o = f(im, all)
    doAssert o.w == im.w and o.h == im.h, n
    doAssert meanDiff(o, im) > 0.05, n & " changed nothing"

block toneAndColor:
  # Tone Stretch: a dull picture made to use the whole range
  var dull = newImg(64, 64)
  for i in 0 ..< dull.px.len: dull.px[i] = grayPx(100 + (i mod 64))
  let s = toneStretch(0, 0)(dull, rect(0, 0, 64, 64))
  var lo = 255
  var hi = 0
  for p in s.px:
    lo = min(lo, lumaOf(p))
    hi = max(hi, lumaOf(p))
  doAssert lo <= 2 and hi >= 253, $lo & ".." & $hi
  # Channel Inversion's Invert Channels: each channel the other way up
  let inv = channelInversion(3)(im, all)
  doAssert rOf(inv.px[10]) == 255 - rOf(im.px[10]) and bOf(inv.px[10]) == 255 - bOf(im.px[10])
  # Split Toning: warm highlights, cool shadows
  let st = splitToning(220, 60, 40, 60)(im, all)
  var wh = newImg(4, 1)
  wh.px = @[grayPx(20), grayPx(20), grayPx(235), grayPx(235)]
  let t2 = splitToning(220, 80, 40, 80)(wh, rect(0, 0, 4, 1))
  doAssert bOf(t2.px[0]) > rOf(t2.px[0]) and rOf(t2.px[2]) > bOf(t2.px[2]), "cool shadows, warm highlights"
  doAssert st.w == im.w
  # the adjustment layers that take numbers
  for n in ["Split Toning", "Color Grading", "Infrared"]:
    doAssert isParamAdjust(n) and n in paramAdjustNames(), n
    doAssert adjustmentFn(Adjustment(kind: n, args: @[])) != nil, n
  # Hue Curves' two more: Saturation vs Saturation down at the top -- the bright colors duller
  var flat = newSeq[(int, int)]()
  flat.add (0, 128)
  flat.add (255, 128)
  let hc = hueCurves([flat, flat, flat, @[(0, 128), (255, 0)], flat])
  var red = newImg(1, 1)
  red.px[0] = argb(255, 240, 20, 20)
  let r2 = hc(red, rect(0, 0, 1, 1))
  doAssert rOf(r2.px[0]) - gOf(r2.px[0]) < 200, "less saturated"

block bilateralKeepsEdges:
  # a noisy edge: the noise goes, the edge stays
  var rng = initRand(5)
  var e = newImg(80, 40)
  for y in 0 ..< 40:
    for x in 0 ..< 80:
      let v = (if x < 40: 50 else: 200) + rng.rand(30) - 15
      e.px[y * 80 + x] = grayPx(clamp(v, 0, 255))
  let o = bilateralBlur(5, 20)(e, rect(0, 0, 80, 40))
  var spread = 0.0
  for y in 5 ..< 35:
    for x in 5 ..< 30: spread += abs(lumaOf(o.px[y * 80 + x]) - 50).float
  doAssert spread / (30 * 25) < 5, $(spread / 750)
  doAssert lumaOf(o.px[20 * 80 + 36]) < 80 and lumaOf(o.px[20 * 80 + 44]) > 170, "the edge kept"

block rangeMasks:
  var g = newImg(256, 1)
  for x in 0 ..< 256: g.px[x] = grayPx(x)
  let m = luminosityMask(g, 100, 180, 0)
  doAssert m[50] == 0 and m[140] == 255 and m[220] == 0
  var c = newImg(3, 1)
  c.px = @[argb(255, 230, 20, 20), argb(255, 20, 30, 230), grayPx(128)]
  let h = hueRangeMask(c, 0, 20, 10)
  doAssert h[0] == 255 and h[1] == 0 and h[2] == 0, "red, not blue, not gray"
  let a = @[0'u8, 255, 255, 0]
  let b = @[0'u8, 0, 255, 255]
  doAssert compoundMask(a, b, 0) == @[0'u8, 255, 255, 255]
  doAssert compoundMask(a, b, 1) == @[0'u8, 255, 0, 0]
  doAssert compoundMask(a, b, 2) == @[0'u8, 0, 255, 0]
  doAssert compoundMask(a, b, 3) == @[0'u8, 255, 0, 255]

block fourier:
  var re = newSeq[float32](64 * 64)
  var imv = newSeq[float32](64 * 64)
  for i in 0 ..< re.len: re[i] = float32(i mod 7)
  let orig = re
  fft2(re, imv, 64)
  fft2(re, imv, 64, inverse = true)
  var err = 0.0
  for i in 0 ..< re.len: err = max(err, abs(re[i] - orig[i]).float)
  doAssert err < 1e-3, $err

block shake:
  # a known shake: found, and taken out
  let sharp = textured(192, 192, 7)
  let shaken = motionBlur(30, 11)(sharp, rect(0, 0, 192, 192))
  let (a, l) = estimateShake(shaken)
  doAssert abs(a - 30) <= 6 or abs(a - 30) >= 174, "angle " & $a
  doAssert abs(l - 11) <= 3, "length " & $l
  let fixed = shakeReduction(30, 11)(shaken, rect(0, 0, 192, 192))
  doAssert meanDiff(fixed, sharp) < meanDiff(shaken, sharp), $meanDiff(fixed, sharp) & " vs " & $meanDiff(shaken, sharp)

block astro:
  # a shift found, noisy frames stacked
  var moved = newImg(im.w, im.h)
  for y in 0 ..< im.h:
    for x in 0 ..< im.w: moved.px[y * im.w + x] = im.at(x - 7, y + 5)
  doAssert phaseShift(im, moved) == (dx: 7, dy: -5), $phaseShift(im, moved)
  var rng = initRand(3)
  var frames: seq[Img]
  for k in 0 ..< 6:
    var f = newImg(im.w, im.h)
    for i, p in im.px:
      let n = rng.rand(80) - 40
      f.px[i] = argb(255, clamp(rOf(p) + n, 0, 255), clamp(gOf(p) + n, 0, 255), clamp(bOf(p) + n, 0, 255))
    frames.add f
  let st = astroStack(frames, mode = 2)
  doAssert meanDiff(st, im) < meanDiff(frames[0], im) * 0.6
  # the sky's glow taken out: a gradient becomes even
  var sky = newImg(120, 80)
  for y in 0 ..< 80:
    for x in 0 ..< 120: sky.px[y * 120 + x] = grayPx(20 + x div 2 + y div 3)
  let flat = removeGradient()(sky, rect(0, 0, 120, 80))
  var lo = 255
  var hi = 0
  for p in flat.px:
    lo = min(lo, lumaOf(p))
    hi = max(hi, lumaOf(p))
  doAssert hi - lo < 12, $lo & ".." & $hi

block panorama:
  # a view of a 360 picture, put back where it came from
  let pano = textured(400, 200, 9)
  let v = equirectView(pano, 30, 10, 90, 200, 150)
  doAssert v.w == 200 and v.h == 150
  var back = pano
  equirectApply(back, v, 30, 10, 90)
  var off = 0
  for i in 0 ..< back.px.len:
    if abs(lumaOf(back.px[i]) - lumaOf(pano.px[i])) > 30: inc off
  doAssert off < back.px.len div 200, $off

block relief:
  let m = heightfieldMesh(im, 40, 8)
  let cols = im.w div 8
  let rows = im.h div 8
  doAssert m.verts.len == (cols + 1) * (rows + 1) and m.tris.len == 2 * cols * rows and m.colors.len == m.tris.len
  for (x, y, z) in m.verts: doAssert z >= 0 and z <= 40

block newLiveShapes:
  for k in [lsDiamond, lsDoubleStar, lsSquareStar, lsSegment, lsCalloutRect, lsCalloutEllipse, lsTear, lsCrescent,
            lsCloudShape, lsCat]:
    let p = liveShapePath(defaultParams(k), 10, 20, 110, 140)
    doAssert p.subs.len > 0, $k
    let (x0, y0, x1, y1) = pathBounds(p)
    doAssert x0 >= 5 and y0 >= 15 and x1 <= 115 and y1 <= 145 and max(x1 - x0, y1 - y0) > 40, $k & " " & $(x0, y0, x1, y1)

block typeExtras:
  # letters turned one by one, kept in the file
  var st = defaultStyle()
  st.size = 30
  st.rotation = 30
  var t = newText("AB", st, 10, 40)
  let lay = layoutText(t)
  doAssert lay.glyphs.len >= 2 and lay.glyphs[0].spin == 30
  doAssert textFrom(t.toJson).spans[0].style.rotation == 30
  # Type on a Path's effects: kept, and each puts the letters somewhere else
  t.path = @[(10.0'f32, 100.0'f32), (60.0'f32, 60.0'f32), (110.0'f32, 100.0'f32), (160.0'f32, 60.0'f32)]
  st.rotation = 0
  t.spans[0].style = st
  var firsts: seq[float32]
  for e in PathTypeEffect:
    t.pathEffect = e
    doAssert textFrom(t.toJson).pathEffect == e
    let o = textOutlines(t, layoutText(t))
    doAssert o.len > 0, $e
    firsts.add o[0].polys[0][0][1]
  doAssert firsts.deduplicate.len >= 3, $firsts
  # Area Type's frame: kept
  var w = WrapOptions(frameOf: 42)
  doAssert wrapFromJson(wrapToJson(w)).frameOf == 42

block scatter:
  let c = ChartSpec(kind: ckScatter, labels: @["1", "2", "5"], series: @[("A", @[3.0, 5, 4])], w: 400, h: 300)
  let svg = chartSvg(c)
  doAssert "<circle" in svg and "<polyline" notin svg
  doAssert c.toJson["kind"].getStr == "Scatter"

block scaleStrokesAndEffects:
  # Scale Strokes & Effects: a shape made twice as big, its strokes and its style with it; off,
  # as they were
  let d = newDoc(400, 300, 0xFFFFFFFF'u32)
  var sd = ShapeData(path: rectPath(50, 50, 150, 100), fill: solidPaint(0xFF336699'u32),
                     stroke: solidPaint(0xFF000000'u32), strokeWidth: 4,
                     appearance: @[Appearance(kind: apStroke, width: 2, opacity: 100)])
  let L = d.addShapeLayer(sd, "box")
  L.fx.fx[fxDropShadow].on = true
  L.fx.fx[fxDropShadow].distance = 5
  L.fx.fx[fxDropShadow].size = 6
  let r = rect(50, 50, 100, 50)
  let q: Quad = [(50.0, 50.0), (250.0, 50.0), (250.0, 150.0), (50.0, 150.0)]
  doAssert abs(areaScale(r, q) - 2) < 1e-9
  var shots = d.shotsOf([L])
  d.carryShots(shots, r, q)
  doAssert L.shape.strokeWidth == 4 and L.fx.fx[fxDropShadow].distance == 5, "off: the stroke and style as they were"
  shots = d.shotsOf([L])
  shots[0].shape = sd                       # (from the shape as it began)
  d.carryShots(shots, r, q, strokes = true)
  doAssert L.shape.strokeWidth == 8 and L.shape.appearance[0].width == 4, $L.shape.strokeWidth
  doAssert L.fx.fx[fxDropShadow].distance == 10 and L.fx.fx[fxDropShadow].size == 12
  var fx = LayerFx()
  fx.fx[fxOuterGlow].size = 10
  fx.scaleEffects(50)
  doAssert fx.fx[fxOuterGlow].size == 5, "Scale Effects by percent, as before"

echo "photoextras: ok"

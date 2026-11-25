## Tests of Image Trace (retroui/imagetrace) -- a picture made vector
## shapes that look like it -- and of the Pencil Sketch filter; and of the
## presets and templates for new drawings and books
## (retroui/layouttemplates). With PHOTO_DUMP set to a folder, the traces
## are written there.

import std/[os, math, monotimes, times, strutils]
import retroui/[gfx, imaging, photo, photoshapes, photoartistic, photofx, imagetrace, svgimport, photobook,
                layouttemplates, textengine]

let dump = getEnv("PHOTO_DUMP")
if dump.len > 0: createDir(dump)

proc picture(w, h: int): seq[uint32] =
  ## (white, a red disc, a blue square with a white hole, a green triangle, a few specks)
  result = newSeq[uint32](w * h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      var c = 0xFFFFFFFF'u32
      if hypot(float(x - 70), float(y - 70)) < 50: c = 0xFFD02020'u32
      if x in 140 ..< 240 and y in 30 ..< 130 and not (x in 170 ..< 210 and y in 60 ..< 100): c = 0xFF2040C0'u32
      if y in 150 ..< 230 and abs(x - 120) < (y - 150): c = 0xFF20A040'u32
      result[y * w + x] = c
  for (x, y) in [(20, 200), (250, 180), (200, 220)]: result[y * w + x] = 0xFF000000'u32

proc drawn(r: TraceResult; bg = 0xFFFFFFFF'u32): seq[uint32] =
  let d = newDoc(r.w, r.h, bg)
  for s in r.shapes: discard d.addShapeLayer(ShapeData(path: s.path, fill: solidPaint(s.color)))
  d.toBitmap(bg).px

proc near(a, b: uint32): bool =
  abs(int((a shr 16) and 255) - int((b shr 16) and 255)) < 40 and
  abs(int((a shr 8) and 255) - int((b shr 8) and 255)) < 40 and abs(int(a and 255) - int(b and 255)) < 40

proc wrong(a, b: seq[uint32]): float =
  var n = 0
  for i in 0 ..< a.len:
    if not near(a[i], b[i]): inc n
  n / a.len

block tracedLooksLikeThePicture:
  let w = 280
  let h = 240
  let px = picture(w, h)
  var o = tracePreset(tp6Colors)
  o.colors = 4
  let r = traceImage(px, w, h, o)
  doAssert r.shapes.len == 4, $r.shapes.len
  doAssert r.shapes[0].area > r.shapes[^1].area, "the biggest color at the bottom"
  doAssert near(r.shapes[0].color, 0xFFFFFFFF'u32), "white is the background"
  let back = r.drawn
  let bad = wrong(px, back)
  doAssert bad < 0.02, "the trace looks like the picture: " & $(bad * 100) & "% of it differs"
  # the square keeps its hole, and its corners are corners
  doAssert (back[80 * w + 190] and 0xFFFFFF'u32) == 0xFFFFFF'u32, "the hole in the square"
  doAssert near(back[31 * w + 141], 0xFF2040C0'u32) and near(back[129 * w + 238], 0xFF2040C0'u32), "its corners"
  # the specks (one pixel) are left out at the preset's noise
  doAssert near(back[200 * w + 20], 0xFFFFFFFF'u32)
  # few points for such a picture: curves, not stairs
  doAssert r.points < 400, $r.points & " points"
  if dump.len > 0:
    discard Bitmap(w: w, h: h, px: back).savePng(dump / "trace-4colors.png")
    writeFile(dump / "trace.svg", tracedSvg(r))

block blackAndWhiteAndOptions:
  let w = 280
  let h = 240
  let px = picture(w, h)
  # black and white: the dark parts (blue, green, red at a high threshold) black
  var o = tracePreset(tpLogo)
  o.threshold = 200
  let r = traceImage(px, w, h, o)
  doAssert r.shapes.len == 2 and near(r.shapes[1].color, 0xFF000000'u32) or near(r.shapes[0].color, 0xFF000000'u32)
  # ignore white: no white shape
  o.ignoreWhite = true
  for s in traceImage(px, w, h, o).shapes: doAssert not near(s.color, 0xFFFFFFFF'u32)
  # grays
  let g = traceImage(px, w, h, tracePreset(tpGrays))
  for s in g.shapes:
    let c = s.color
    doAssert ((c shr 16) and 255) == ((c shr 8) and 255) and ((c shr 8) and 255) == (c and 255), "gray"
  # not stacked: the shapes lie side by side, each only its own color
  var side = tracePreset(tp6Colors)
  side.colors = 4
  side.stacked = false
  let sr = traceImage(px, w, h, side)
  doAssert wrong(px, sr.drawn) < 0.05
  # the noise option: the specks kept at 1
  var keep = tracePreset(tpLogo)
  keep.noise = 1
  keep.threshold = 128
  let kr = traceImage(px, w, h, keep)
  doAssert not near(kr.drawn[200 * w + 20], 0xFFFFFFFF'u32), "a speck kept"
  # how closely: more points when it follows the pixels more closely
  var loose = tracePreset(tp6Colors)
  loose.paths = 0
  var tight = loose
  tight.paths = 1
  doAssert traceImage(px, w, h, tight).points > traceImage(px, w, h, loose).points

block transparentBigTinyAndOdd:
  # transparent pixels are left out
  var px = newSeq[uint32](100 * 80)
  for y in 20 ..< 60:
    for x in 30 ..< 70: px[y * 100 + x] = 0xFF804020'u32
  let r = traceImage(px, 100, 80, tracePreset(tp3Colors))
  doAssert r.shapes.len == 1
  let back = r.drawn(0'u32)
  doAssert (back[5 * 100 + 5] shr 24) == 0 and near(back[40 * 100 + 50], 0xFF804020'u32)
  # a big picture is traced smaller and the shapes scaled back
  let bw = 3000
  let bh = 1500
  var big = newSeq[uint32](bw * bh)
  for y in 0 ..< bh:
    for x in 0 ..< bw: big[y * bw + x] = if x < bw div 2: 0xFF000000'u32 else: 0xFFFFFFFF'u32
  var o = tracePreset(tpLogo)
  o.maxSide = 600
  let t0 = getMonoTime()
  let br = traceImage(big, bw, bh, o)
  doAssert (getMonoTime() - t0).inMilliseconds < 3000
  var maxX = 0.0
  for s in br.shapes:
    for sp in s.path.subs:
      for q in sp.pts: maxX = max(maxX, q.p[0])
  doAssert abs(maxX - bw.float) < 1, "in the picture's own pixels: " & $maxX
  # nothing to trace, nothing given, one pixel
  doAssert traceImage(newSeq[uint32](0), 0, 0, tracePreset(tpDefault)).shapes.len == 0
  doAssert traceImage(newSeq[uint32](10), 5, 5, tracePreset(tpDefault)).shapes.len == 0, "too few pixels: nothing"
  doAssert traceImage(@[0xFF123456'u32], 1, 1, tracePreset(tp16Colors)).shapes.len <= 1
  # noise everywhere: it ends, quickly
  var noise = newSeq[uint32](400 * 300)
  var s = 12345'u32
  for i in 0 ..< noise.len:
    s = s * 1103515245'u32 + 12345'u32
    noise[i] = 0xFF000000'u32 or (s shr 8)
  let t1 = getMonoTime()
  discard traceImage(noise, 400, 300, tracePreset(tpHighPhoto))
  doAssert (getMonoTime() - t1).inMilliseconds < 8000

block tracedSvgReadBack:
  let w = 280
  let h = 240
  let px = picture(w, h)
  var o = tracePreset(tp6Colors)
  o.colors = 4
  let svg = tracedSvg(traceImage(px, w, h, o))
  let b = rasterizeSvg(svg, w, h)
  doAssert b.w == w and wrong(px, b.px) < 0.03, "the SVG draws the same picture"

block pencilSketch:
  # a flat area becomes paper; an edge a line in the pencil's color
  let w = 120
  let h = 80
  var im = Img(w: w, h: h, px: newSeq[uint32](w * h))
  for y in 0 ..< h:
    for x in 0 ..< w: im.px[y * w + x] = if x < 60: 0xFF303030'u32 else: 0xFFE0E0E0'u32
  let o = pencilSketch(6, 50, 0, 0xFF000000'u32, 0xFFFFFFFF'u32)(im, rect(0, 0, w, h))
  let flat = o.px[40 * w + 100] and 255
  var edge = 255'u32
  for x in 50 ..< 70: edge = min(edge, o.px[40 * w + x] and 255)   # (the line is on the dark side of the edge)
  doAssert flat > 230, "paper where it is flat: " & $flat
  doAssert (o.px[40 * w + 20] and 255) > 230, "on the dark side too, away from the edge"
  doAssert edge < flat - 60, "a stroke at the edge: " & $edge
  # its colors kept, at Color 100
  var c = im
  for i in 0 ..< c.px.len: c.px[i] = if i mod w < 60: 0xFFC02020'u32 else: 0xFFF0F0F0'u32
  let oc = pencilSketch(6, 50, 100, 0xFF000000'u32, 0xFFFFFFFF'u32)(c, rect(0, 0, w, h))
  var p = 0xFFFFFFFF'u32
  for x in 50 ..< 60:
    if (oc.px[40 * w + x] and 255) < (p and 255): p = oc.px[40 * w + x]
  doAssert ((p shr 16) and 255) > (p and 255) + 20, "reddish where the picture is red"

block newDrawingsAndBooks:
  for c in DrawingCategory:
    doAssert drawingPresets(c).len >= 4
    for p in drawingPresets(c): doAssert p.w > 0 and p.h > 0 and sizeOk(p.w, p.h)
  for t in drawingTemplates():
    let b = rasterizeSvg(t.svg, t.w div 4, t.h div 4)
    var ink = 0
    for q in b.px:
      if (q shr 24) > 0: inc ink
    doAssert ink > b.px.len div 2, t.name & " draws"
    let d = newDoc(t.w, t.h, 0'u32)
    let made = d.placeSvg(t.svg, rect(0, 0, t.w, t.h), asGroup = false)
    doAssert made.len >= 3, t.name & ": its parts are layers (" & $made.len & ")"
    var texts = 0
    for L in d.layers:
      if L.isText: inc texts
    doAssert texts >= 1 or t.name in ["Flat Landscape", "App Icon"], t.name & ": its words are type"
  for c in BookCategory:
    doAssert bookPresets(c).len >= 4
    for p in bookPresets(c): doAssert p.pages >= 1 and sizeOk(p.setup.w, p.setup.h)
  doAssert bookPresets(bcBooks)[1].setup.binding == bindRight, "an Arabic book is bound on the right"
  for t in bookTemplates():
    let t0 = getMonoTime()
    let b = t.build()
    doAssert b.pages.len >= 2, t.name
    doAssert b.setup.facing == t.facing
    doAssert b.thumb(0, 120) != nil
    doAssert not b.changed, t.name & ": made, nothing to save yet"
    # its masters number its pages
    var numbered = false
    for i in 0 ..< b.pages.len:
      for L in b.doc(i).layers:
        if L.fromMaster != 0 and L.isText and "<#" in L.text.plainText: numbered = true
      b.park()
    doAssert numbered, t.name & " has page numbers"
    if dump.len > 0:
      discard b.spreadPicture(min(1, b.pages.high)).savePng(dump / ("template-" & t.name & ".png"))
    b.close()
    doAssert (getMonoTime() - t0).inMilliseconds < (when defined(retroSanitized): 80_000 else: 20_000)

echo "test_imagetrace: ok"

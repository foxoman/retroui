## Tests of `retroui/photosvg`: a shape layer as an SVG path, type as text
## (each run in its look, its lines one text, text along a path), pixels
## as a picture, groups as groups; and the way back (`openPicture` of what
## was written): the same layers, by name, the same picture -- with their
## masks, clipping (as masks), drop shadows, a type layer's stroke,
## pattern fills, blending modes, and the layers that are off; type as
## outlines; what an SVG does not hold said (`svgLosses`).

import std/[strutils, os]
import retroui/[gfx, photo, photosvg, photofiles, textengine]
import std/json
{.push warning[UnusedImport]: off.}
import retroui/photoshapes   # (imported for what it sets up in retroui/photo: how shape layers are drawn)
{.pop.}

proc box(x0, y0, x1, y1: float): Path =
  var sp = SubPath(closed: true)
  for (x, y) in [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]:
    sp.pts.add PathPoint(p: (x, y), inH: (x, y), outH: (x, y))
  Path(subs: @[sp])

let d = newDoc(200, 100)
var sh = ShapeData(kind: "Ellipse", fill: ShapePaint(kind: spColor, color: 0xFFFF0000'u32),
                   stroke: ShapePaint(kind: spColor, color: 0xFF000000'u32), strokeWidth: 3)
sh.path = box(10, 10, 90, 60)
let L = d.addLayer("Box")
d.setShape(L, sh)
let T = d.addTextLayer(newText("Hello مرحبا", CharStyle(family: "DejaVu Sans", style: "Book", size: 20,
                                                       color: 0xFF0000FF'u32, hScale: 1, vScale: 1), 10, 90))
let P = d.addLayer("Dots")
for y in 70 ..< 80:
  for x in 150 ..< 170: P.px[y * 200 + x] = (if (x + y) mod 2 == 0: 0xFF00AA00'u32 else: 0x80FFAA00'u32)
inc P.ver
let s = d.svgOf()
writeFile(getTempDir() / "retro-test.svg", s)
echo s.len
doAssert "<path" in s and "M10 10L90 10" in s and "<text" in s and "Hello" in s and "<image" in s
doAssert "<rect id=\"Background\"" in s and "fill=\"#ffffff\"" in s      # (one color all over: no picture needed)
doAssert "data-name=\"Box\"" in s and "<title>" in s
doAssert d.svgOf(pixels = false).count("<image") == 0
echo "svg ok"

# ---- there and back --------------------------------------------------------------------------------------------

block roundTrip:
  let d = newDoc(320, 240, 0'u32)
  # a group of two shapes, half shown
  let g = d.addGroup("Badge")
  var a = ShapeData(kind: "Rectangle", fill: ShapePaint(kind: spColor, color: 0xFF2040A0'u32))
  a.path = box(20, 20, 140, 80)
  discard d.addShapeLayer(a, "Plate")
  var b = ShapeData(kind: "Rectangle", fill: ShapePaint(kind: spNone),
                    stroke: ShapePaint(kind: spColor, color: 0xFFFFCC00'u32), strokeWidth: 4)
  b.path = box(30, 30, 130, 70)
  let rim = d.addShapeLayer(b, "Rim")
  rim.opacity = 50
  g.collapsed = true                    # (closed: what comes next goes above it, not into it)
  d.cur = d.layers.find(g)
  # two lines, centered, the second word bold and red
  var t = newText("Retro Photo\nvector", CharStyle(family: "FreeSans", style: "Regular", size: 18,
                                                   color: 0xFF000000'u32, hScale: 1, vScale: 1), 220, 60)
  t.para.align = textCenter
  t.restyle(6, 11, proc (st: var CharStyle) =
    st.style = "Bold"
    st.color = 0xFFC00000'u32)
  let two = d.addTextLayer(t)
  two.name = "Two lines"
  # along a slope
  var onPath = newText("on a path", CharStyle(family: "FreeSerif", style: "Italic", size: 16,
                                              color: 0xFF006000'u32, hScale: 1, vScale: 1), 40, 200)
  onPath.path = @[(40'f32, 200'f32), (280'f32, 140'f32)]
  discard d.addTextLayer(onPath)
  # pixels
  let px = d.addLayer("Dots")
  for y in 150 ..< 170:
    for x in 20 ..< 60: px.px[y * 320 + x] = 0xFFAA00AA'u32
  inc px.ver
  doAssert d.svgLosses.len == 0

  let path = getTempDir() / "retro-roundtrip.svg"
  writeFile(path, d.svgOf())
  let e = openPicture(path)
  doAssert e.w == 320 and e.h == 240 and e.format == "svg"
  var names, kinds: seq[string]
  for L in e.layers:
    names.add L.name
    kinds.add (if L.group: "group" elif L.isText: "text" elif L.isShape: "shape" else: "pixels") & $L.depth
  doAssert names == @["Plate", "Rim", "Badge", "Two lines", "on a path", "Dots"], $names
  doAssert kinds == @["shape1", "shape1", "group0", "text0", "text0", "pixels0"], $kinds
  doAssert e.layers[1].opacity == 50
  doAssert e.layers[1].shape.align == saInside and e.layers[1].shape.strokeWidth == 4   # (inside its outline still)
  let back = e.layers[3].text
  doAssert back.plainText == "Retro Photo\nvector" and back.para.align == textCenter and back.x == 220
  doAssert back.styleAt(0).family == "FreeSans" and back.styleAt(0).size == 18
  doAssert back.styleAt(7).style == "Bold" and back.styleAt(7).color == 0xFFC00000'u32
  doAssert back.styleAt(13).style == "Regular" and back.styleAt(13).color == 0xFF000000'u32
  let along = e.layers[4].text
  doAssert along.path.len == 2 and along.path[1] == (280'f32, 140'f32) and along.styleAt(0).family == "FreeSerif" and
           along.styleAt(0).style == "Italic"
  # the same picture
  let p0 = d.toBitmap()
  let p1 = e.toBitmap()
  var apart = 0
  for i in 0 ..< p0.px.len:
    let x = p0.px[i]
    let y = p1.px[i]
    for shf in [24, 16, 8, 0]:
      if abs(int((x shr shf) and 255) - int((y shr shf) and 255)) > 40:
        inc apart
        break
  doAssert apart < 60, $apart        # (edges of letters and strokes: a few)
  # written again: the same file
  let again = e.svgOf()
  let f = openPicture(path)
  doAssert f.svgOf() == again
  writeFile(path, again)
  doAssert openPicture(path).svgOf() == again
  removeFile(path)

  # what an SVG does not hold
  let h = newDoc(20, 20)
  let m = h.addLayer("Masked")
  h.setShape(m, a)
  h.addLayerMask()
  h.layers[^1].mode = bmLinearBurn
  h.layers[^1].fx.fx[fxBevel] = Effect(on: true, opacity: 75, size: 5)
  h.layers[^1].fx.fx[fxDropShadow] = Effect(on: true, opacity: 75, size: 5, distance: 3, color: 0xFF000000'u32)
  # (kept for Retro Photo alone: no other program shows a bevel, or burns)
  doAssert h.svgOwn == @["layer effects (Bevel and Emboss)", "some blending modes"], $h.svgOwn
  doAssert h.svgLosses.len == 0, $h.svgLosses
  h.layers[^1].mode = bmMultiply
  doAssert "mix-blend-mode:multiply" in h.svgOf() and h.svgOwn == @["layer effects (Bevel and Emboss)"]
echo "there and back ok"

# ---- what Retro Photo keeps for itself: every effect, every blending mode, adjustment layers -----------------

block:
  let d = newDoc(320, 240, 0xFFFFFFFF'u32)
  var a = ShapeData(kind: "Rectangle", fill: ShapePaint(kind: spColor, color: 0xFFC02020'u32))
  a.path = box(40, 40, 200, 160)
  let plate = d.addShapeLayer(a, "Plate")
  plate.fx.fx[fxBevel] = Effect(on: true, mode: bmScreen, mode2: bmMultiply, opacity: 75, opacity2: 60, size: 7,
                                depth: 120, angle: 130, altitude: 35, soften: 2, color: 0xFFFFFFFF'u32,
                                color2: 0xFF000000'u32)
  plate.fx.fx[fxInnerShadow] = Effect(on: true, mode: bmMultiply, opacity: 50, size: 6, distance: 4, angle: 120,
                                      color: 0xFF000040'u32)
  plate.fx.fx[fxDropShadow] = Effect(on: true, mode: bmMultiply, opacity: 70, size: 5, distance: 3, angle: 135,
                                     color: 0xFF000000'u32)
  plate.mode = bmLinearBurn
  inc plate.ver
  let ty = d.addTextLayer(newText("Glow", CharStyle(family: "FreeSans", style: "Bold", size: 40,
                                                    color: 0xFF2040C0'u32, hScale: 1, vScale: 1), 60, 220))
  ty.fx.fx[fxColorOverlay] = Effect(on: true, mode: bmNormal, opacity: 100, color: 0xFF008040'u32)
  ty.fx.fx[fxSatin] = Effect(on: true, mode: bmMultiply, opacity: 40, size: 5, distance: 6, angle: 20,
                             color: 0xFF000000'u32)
  inc ty.ver
  discard d.newAdjustmentLayer(Adjustment(kind: "Hue/Saturation", args: @[30.0, -20, 10, 0]), "Warmer")
  let lv = d.newAdjustmentLayer(Adjustment(kind: "Invert"))
  lv.opacity = 40
  lv.visible = false
  d.markAll()
  doAssert d.svgOwn.len == 3 and d.svgLosses.len == 0, $d.svgOwn & $d.svgLosses
  let written = d.svgOf()
  doAssert "data-retro-fx='" in written and "data-retro-mode=\"Linear Burn\"" in written and
           written.count("data-retro-adjust='") == 2 and "feDropShadow" in written
  let path = getTempDir() / "retro-own.svg"
  writeFile(path, written)
  let e = openPicture(path)
  proc looks(d: Doc): seq[string] =
    for L in d.layers:
      result.add L.name & "|" & $L.mode & "|" & $L.opacity & "|" & $L.visible & "|" & L.adjust.kind & $L.adjust.args &
                 "|" & $toJson(L.fx)
  doAssert looks(e) == looks(d), $looks(e) & "\n" & $looks(d)
  doAssert e.layers[1].isShape and e.layers[2].isText and e.layers[3].adjust.kind == "Hue/Saturation" and
           e.layers[3].adjust.args == @[30.0, -20, 10, 0]
  # the same picture, the adjustments at work in both
  let p0 = d.toBitmap()
  let p1 = e.toBitmap()
  var apart = 0
  for i in 0 ..< p0.px.len:
    for shf in [16, 8, 0]:
      if abs(int((p0.px[i] shr shf) and 255) - int((p1.px[i] shr shf) and 255)) > 40:
        inc apart
        break
  doAssert apart < 60, $apart
  # written again and again: the same file
  let again = e.svgOf()
  writeFile(path, again)
  doAssert openPicture(path).svgOf() == again
  # damaged words of its own: read as far as they go, never a crash
  writeFile(path, written.replace("data-retro-fx='{", "data-retro-fx='{{").replace("\"args\":[", "\"args\":[[],"))
  discard openPicture(path).toBitmap()
  removeFile(path)
echo "its own there and back ok"

# ---- masks, clipping, effects, patterns, what is off: there and back -----------------------------------------

block looks:
  let d = newDoc(320, 240, 0'u32)   # (256 across or more: opened at its own size)
  proc kindsOf(d: Doc): seq[string] =
    for L in d.layers:
      result.add L.name & ":" & (if L.group: "group" elif L.isText: "text" elif L.isShape: "shape" else: "pixels") &
                 $L.depth & (if L.mask != nil: " mask" else: "") & (if L.hasFx: " fx" else: "") &
                 (if L.visible: "" else: " off") & (if L.mode != bmNormal: " " & $L.mode else: "") &
                 (if L.opacity < 100: " " & $L.opacity else: "")
  # a shape with a mask that fades it out to the right, and a shadow
  var a = ShapeData(kind: "Rectangle", fill: ShapePaint(kind: spColor, color: 0xFF2060C0'u32))
  a.path = box(20, 20, 120, 80)
  let plate = d.addShapeLayer(a, "Plate")
  plate.mask = d.grayLayer("Layer Mask", proc (k: int): int = clamp(255 - (k mod 320 - 20) * 255 div 100, 0, 255))
  plate.fx.fx[fxDropShadow] = Effect(on: true, mode: bmNormal, opacity: 60, color: 0xFF200040'u32, angle: 135,
                                     distance: 6, size: 4)
  inc plate.ver
  # pixels clipped to it
  let dots = d.addLayer("Dots")
  for y in 10 ..< 90:
    for x in 60 ..< 200: dots.px[y * 320 + x] = (if (x div 6 + y div 6) mod 2 == 0: 0xFFFFD000'u32 else: 0'u32)
  dots.clipped = true
  inc dots.ver
  # a pattern fill
  var pat = ShapeData(kind: "Rectangle", fill: ShapePaint(kind: spPattern, pw: 4, ph: 4, scale: 100, opacity: 100,
                                                          pattern: newSeq[uint32](16)))
  for k in 0 ..< 16: pat.fill.pattern[k] = (if k mod 4 < 2: 0xFF008040'u32 else: 0xFFFFFFFF'u32)
  pat.path = box(140, 100, 220, 180)
  discard d.addShapeLayer(pat, "Stripes")
  # type with a stroke, all capitals
  var st = CharStyle(family: "FreeSans", style: "Bold", size: 30, color: 0xFFFFE000'u32, hScale: 1, vScale: 1,
                     allCaps: true)
  let ty = d.addTextLayer(newText("caps", st, 20, 150))
  ty.fx.fx[fxStroke] = Effect(on: true, mode: bmNormal, opacity: 100, color: 0xFF000000'u32, size: 2, style: 2)
  inc ty.ver
  # a layer that is off; a group at 60%, multiplied
  let off = d.addShapeLayer(a, "Off")
  off.visible = false
  let i1 = d.layers.find(d.addShapeLayer(pat, "In 1"))
  var b = a
  b.path = box(150, 20, 230, 60)
  let i2 = d.layers.find(d.addShapeLayer(b, "In 2"))
  let g = d.groupLayers(@[i1, i2], "Pair")
  doAssert g != nil and g.group
  g.opacity = 60
  g.mode = bmMultiply
  g.passThrough = false
  d.markAll()
  doAssert d.svgLosses.len == 0, $d.svgLosses
  let before = kindsOf(d)

  let path = getTempDir() / "retro-looks.svg"
  let written = d.svgOf()
  doAssert "<mask" in written and "<pattern" in written and "feDropShadow" in written and
           "visibility=\"hidden\"" in written and "text-transform:uppercase" in written
  writeFile(path, written)
  let e = openPicture(path)
  let after = kindsOf(e)
  # the same layers: the clipped one's clipping a mask now
  doAssert after == @["Plate:shape0 mask fx", "Dots:pixels0 mask", "Stripes:shape0", "caps:text0 fx", "Off:shape0 off",
                      "In 1:shape1", "In 2:shape1", "Pair:group0 Multiply 60"], $after & "\n" & $before
  let pl = e.layers[0]
  doAssert (pl.mask.px[50 * 320 + 25] and 255) > 230 and (pl.mask.px[50 * 320 + 115] and 255) < 30
  let sh = pl.fx.fx[fxDropShadow]
  doAssert sh.on and sh.distance == 6 and sh.size == 4 and sh.opacity == 60 and sh.color == 0xFF200040'u32 and
           sh.angle == 135
  doAssert e.layers[2].shape.fill.kind == spPattern and e.layers[2].shape.fill.pw == 4 and
           e.layers[2].shape.fill.pattern[0] == 0xFF008040'u32 and e.layers[2].shape.fill.pattern[3] == 0xFFFFFFFF'u32
  let sk = e.layers[3].fx.fx[fxStroke]
  doAssert sk.on and sk.size == 2 and sk.style == 2 and sk.color == 0xFF000000'u32 and
           e.layers[3].text.styleAt(0).allCaps and e.layers[3].text.plainText == "caps"
  # the same picture
  let p0 = d.toBitmap()
  let p1 = e.toBitmap()
  var apart = 0
  for i in 0 ..< p0.px.len:
    for shf in [24, 16, 8, 0]:
      if abs(int((p0.px[i] shr shf) and 255) - int((p1.px[i] shr shf) and 255)) > 48:
        inc apart
        break
  doAssert apart < 250, $apart          # (the edges of the letters' stroke, the shadow's blur)
  # written again and again: the same file
  let again = e.svgOf()
  writeFile(path, again)
  doAssert openPicture(path).svgOf() == again
  removeFile(path)

  # type as outlines: paths in its colors, no text; the same picture
  let o = d.svgOf(outlines = true)
  doAssert "<text" notin o and o.count("<path") > written.count("<path")
  writeFile(path, o)
  let f = openPicture(path)
  doAssert not f.layers[3].isText and f.layers[3].isShape
  removeFile(path)
echo "looks there and back ok"

# ---- type that is its outline alone, type that runs down -----------------------------------------------------

block:
  let d = newDoc(320, 240, 0xFFFFFFFF'u32)
  let st = CharStyle(family: "FreeSans", style: "Bold", size: 48, color: 0xFF0000C0'u32, hScale: 1, vScale: 1)
  let hollow = d.addTextLayer(newText("Hollow", st, 20, 70))
  hollow.fx.fx[fxStroke] = Effect(on: true, mode: bmNormal, opacity: 100, color: 0xFF0000C0'u32, size: 2, style: 2)
  hollow.fill = 0
  inc hollow.ver
  var down = newText("down", CharStyle(family: "FreeSans", style: "Regular", size: 24, color: 0xFF000000'u32,
                                       hScale: 1, vScale: 1), 280, 30)
  down.vertical = true
  discard d.addTextLayer(down)
  d.markAll()
  doAssert d.svgLosses.len == 0, $d.svgLosses
  let written = d.svgOf()
  doAssert "fill-opacity=\"0\"" in written and "writing-mode=\"vertical-rl\"" in written
  let path = getTempDir() / "retro-hollow.svg"
  writeFile(path, written)
  let e = openPicture(path)
  doAssert e.layers.len == d.layers.len
  let h2 = e.layers[1]
  doAssert h2.isText and h2.fill == 0 and h2.fx.fx[fxStroke].on and h2.fx.fx[fxStroke].size == 2 and
           h2.fx.fx[fxStroke].style == 2 and h2.fx.fx[fxStroke].color == 0xFF0000C0'u32 and
           h2.text.plainText == "Hollow"
  let d2 = e.layers[2]
  doAssert d2.isText and d2.text.vertical and abs(d2.text.x - 280) < 0.01 and abs(d2.text.y - 30) < 0.01
  # the same picture: the letters' middle white in both
  let p0 = d.toBitmap()
  let p1 = e.toBitmap()
  var apart, blue = 0
  for i in 0 ..< p0.px.len:
    if abs(int(p0.px[i] and 255) - int(p1.px[i] and 255)) > 64 or
       abs(int((p0.px[i] shr 16) and 255) - int((p1.px[i] shr 16) and 255)) > 64: inc apart
    if ((p1.px[i] shr 16) and 255) < 60 and (p1.px[i] and 255) > 150: inc blue
  doAssert apart < 150 and blue > 400 and blue < 4000, $apart & " " & $blue
  let again = e.svgOf()
  writeFile(path, again)
  doAssert openPicture(path).svgOf() == again
  # as outlines: lines round the letters, nothing in them
  let o = d.svgOf(outlines = true)
  doAssert "<text" notin o and "fill=\"none\"" in o and "stroke=\"#0000c0\"" in o.toLowerAscii
  writeFile(path, o)
  let fd = openPicture(path)
  doAssert fd.layers[1].isShape and fd.layers[1].shape.strokeWidth == 2 and fd.layers[1].shape.fill.kind == spNone
  let f = fd.toBitmap()
  var apart2 = 0
  for i in 0 ..< p0.px.len:
    if abs(int(p0.px[i] and 255) - int(f.px[i] and 255)) > 96 or
       abs(int((p0.px[i] shr 16) and 255) - int((f.px[i] shr 16) and 255)) > 96: inc apart2
  doAssert apart2 < 400, $apart2        # (a line drawn as a line, and as a layer's Stroke: their edges)
  removeFile(path)
echo "hollow and vertical type there and back ok"

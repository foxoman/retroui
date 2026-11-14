## Tests of `retroui/photosvg`: a shape layer as an SVG path, type as text
## (each run in its look, its lines one text, text along a path), pixels
## as a picture, groups as groups; and the way back (`openPicture` of what
## was written): the same layers, by name, the same picture; what an SVG
## does not hold said (`svgLosses`).

import std/[strutils, os]
import retroui/[gfx, photo, photosvg, photofiles, textengine]
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
  doAssert h.svgLosses == @["masks on shapes, type and groups", "some blending modes"], $h.svgLosses
  h.layers[^1].mode = bmMultiply
  doAssert "mix-blend-mode:multiply" in h.svgOf()
echo "there and back ok"

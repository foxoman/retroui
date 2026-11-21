## Dimensions (`retroui/dimensions`): a distance between two corners of a box fixed to them, its
## label in millimetres; the box moved and made wider -- the dimension drawn again and its
## label changed; an angle between two lines; a circle's radius; the label in another unit;
## undone with the step that moved the box; kept in the file.

import std/[strutils, math]
import retroui/[gfx, photo, photoshapes, textengine, photowidgets, dimensions]

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

let d = newDoc(1000, 800, 0xFFFFFFFF'u32, dpi = 254)   # (10 pixels a millimetre)
var s = ShapeData(kind: "Rectangle", fill: solidPaint(0xFFDDDDDD'u32))
s.path = rectPath(100, 100, 400, 300)
let B = d.addShapeLayer(s, "Box")

block distance:
  let a = d.anchorAt(101, 99)
  let b = d.anchorAt(399, 101)
  check a.uid == B.uidOf and a.fx == 0 and a.fy == 0 and b.fx == 1 and b.fy == 0, "fixed to the box's top corners"
  let free = d.anchorAt(700, 700)
  check free.uid == 0 and free.fx == 700, "a point on nothing: the point itself"
  d.beginStep("Dimension")
  d.touchLayers()
  let L = d.addDimension(Dimension(kind: dkDistance, a: a, b: b, offset: -30), ruMillimeters)
  d.endStep()
  let (ok, dm) = dimensionOf(L)
  check ok and dm.kind == dkDistance and dm.label != 0, "a dimension, its label linked"
  let T = d.layerOfUid(dm.label)
  check T != nil and T.isText and T.text.spans[0].text == "30.0 mm", "its label: 30.0 mm (" &
        (if T != nil: T.text.spans[0].text else: "?") & ")"
  check L.shape.path.subs.len == 5, "two extension lines, the line and two arrowheads"
  # the box moved and made wider: the dimension follows
  d.beginStep("Move")
  d.touchLayers()
  var s2 = B.shape
  s2.path = rectPath(150, 200, 550, 400)
  d.setShape(B, s2)
  check d.updateDimensions(ruMillimeters) == 1, "one dimension drawn again"
  d.endStep()
  check T.text.spans[0].text == "40.0 mm", "its label now 40.0 mm"
  let lb = pathBounds(L.shape.path)
  check lb[0] < 160 and lb[2] > 540, "its lines where the box is now"
  d.updateDimensions(ruPixels)
  check T.text.spans[0].text == "400 px", "in pixels when the rulers are"
  d.undo()
  check B.shape.path.subs[0].pts[0].p[0] == 100 and T.text.spans[0].text == "30.0 mm",
        "undone with the step that moved the box"
  check d.updateDimensions(ruMillimeters) == 0, "nothing to draw again when nothing moved"

block angleAndRadius:
  let v = DimAnchor(fx: 500, fy: 600)
  let p1 = DimAnchor(fx: 700, fy: 600)
  let p2 = DimAnchor(fx: 500, fy: 400)
  let A = d.addDimension(Dimension(kind: dkAngle, a: v, b: p1, c: p2, offset: 60), ruMillimeters)
  let T = d.layerOfUid(dimensionOf(A).dim.label)
  check T.text.spans[0].text == "90.0°", "an angle of 90 degrees: " & T.text.spans[0].text
  var c = ShapeData(kind: "Ellipse", fill: solidPaint(0xFF88AAFF'u32))
  c.path = ellipsePath(700, 100, 900, 300)
  let C = d.addShapeLayer(c, "Circle")
  let R = d.addDimension(Dimension(kind: dkRadius, a: DimAnchor(uid: C.uidOf, fx: 0.5, fy: 0.5), offset: 45),
                         ruMillimeters)
  let RT = d.layerOfUid(dimensionOf(R).dim.label)
  check RT.text.spans[0].text == "R 10.0 mm", "a circle's radius: " & RT.text.spans[0].text

if failures > 0:
  echo "test_dimensions: ", failures, " failed"
  quit(1)
echo "test_dimensions: all passed"

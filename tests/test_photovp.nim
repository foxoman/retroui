## Tests of `retroui/photovp`: a plane in perspective, a picture pasted on it,
## its texture cloned along it.

import std/math
import retroui/[photo, photofx, photovp]

let d = newDoc(200, 150, 0xFFFFFFFF'u32)
# a floor going back: wide at the bottom, narrow at the top
let p = vpPlane([(70.0, 20.0), (130.0, 20.0), (190.0, 140.0), (10.0, 140.0)])
doAssert p.ok
let (u, v) = p.toPlane(100, 80)
let (x, y) = p.toImage(u, v)
doAssert abs(x - 100) < 1e-6 and abs(y - 80) < 1e-6
doAssert p.inside(100, 80) and not p.inside(5, 5)
doAssert p.localScale(0.5, 0.05) < p.localScale(0.5, 0.95), "smaller as it goes back"
# a red square pasted on all of it
var red = Img(w: 20, h: 20, px: newSeq[uint32](400))
for c in red.px.mitems: c = 0xFFFF0000'u32
d.beginStep("Vanishing Point")
d.vpPaste(d.layer, p, red, (0.0, 0.0), 1.0)
d.endStep()
doAssert d.layer.px[80 * 200 + 100] == 0xFFFF0000'u32
doAssert d.layer.px[5 * 200 + 5] == 0xFFFFFFFF'u32, "outside the plane: as it was"
d.undo()
doAssert d.layer.px[80 * 200 + 100] == 0xFFFFFFFF'u32
# Stamp: a blue mark at the plane's left copied to its right
for yy in 120 ..< 130:
  for xx in 40 ..< 50: d.layer.px[yy * 200 + xx] = 0xFF0000FF'u32
inc d.layer.ver
let (su, sv) = p.toPlane(45, 125)
let (du, dv) = (su + 0.5, sv)
d.beginStep("Stamp")
d.vpClone(d.layer, p, (su, sv), (du, dv), 8, 100, 100)
d.endStep()
let (tx, ty) = p.toImage(du, dv)
doAssert d.layer.px[int(ty) * 200 + int(tx)] == 0xFF0000FF'u32, "the mark copied along the plane"
doAssert p.gridLines(4).len == 10
echo "photovp: all passed"

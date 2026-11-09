## Tests of `retroui/photosvg`: a shape layer as an SVG path, type as text, pixels as a picture.

import std/[strutils, os]
import retroui/[photo, photosvg, textengine]
let d = newDoc(200, 100)
var sh = ShapeData(kind: "Ellipse", fill: ShapePaint(kind: spColor, color: 0xFFFF0000'u32),
                   stroke: ShapePaint(kind: spColor, color: 0xFF000000'u32), strokeWidth: 3)
var sp = SubPath(closed: true)
for (x, y) in [(10.0, 10.0), (90.0, 10.0), (90.0, 60.0), (10.0, 60.0)]:
  sp.pts.add PathPoint(p: (x, y), inH: (x, y), outH: (x, y))
sh.path = Path(subs: @[sp])
let L = d.addLayer("Box")
d.setShape(L, sh)
let T = d.addTextLayer(newText("Hello مرحبا", CharStyle(family: "DejaVu Sans", style: "Book", size: 20,
                                                       color: 0xFF0000FF'u32, hScale: 1, vScale: 1), 10, 90))
let s = d.svgOf()
writeFile(getTempDir() / "retro-test.svg", s)
echo s.len
doAssert "<path" in s and "M10 10L90 10" in s and "<text" in s and "Hello" in s and "<image" in s
echo "svg ok"

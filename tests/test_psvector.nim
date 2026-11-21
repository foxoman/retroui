## PostScript's drawing as vectors (`retroui/psvector`, `importPs` in `retroui/photoimport`): a
## program of the kind drawing programs write -- their own short names for the operators, a
## path with a hole, a curve, an arc, a transformation, a loop, gray, RGB and CMYK -- read as
## shapes in their colors and widths; the bounding box kept; an EPS of the kit's own read back
## as shapes; what draws nothing gives none, an endless loop is stopped.

import std/[os, strutils, math]
import retroui/[gfx, photo, photoshapes, psvector, photoimport]

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

let program = """%!PS-Adobe-3.0 EPSF-3.0
%%BoundingBox: 0 0 200 100
%%EndComments
50 dict begin
/q { gsave } bind def /Q { grestore } bind def
/cm { 6 array astore concat } bind def
/w { setlinewidth } bind def
/m { moveto } bind def /l { lineto } bind def /c { curveto } bind def /h { closepath } bind def
/re { exch dup neg 3 1 roll 5 3 roll moveto 0 rlineto 0 exch rlineto 0 rlineto closepath } bind def
/f { fill } bind def /S { stroke } bind def
/g { setgray } bind def /rg { setrgbcolor } bind def /k { setcmykcolor } bind def
% a red square with a square hole in it (the hole turned the other way)
1 0 0 rg 10 10 m 90 10 l 90 90 l 10 90 l h 30 30 m 30 70 l 70 70 l 70 30 l h f
% a blue curve, 4 wide, moved over by 100
q 1 0 0 1 100 0 cm 0 0 1 rg 4 w 10 50 m 50 90 90 50 90 10 c S Q
% a gray circle, and green squares in a loop, then cyan in CMYK
0.5 g 150 50 20 0 360 arc f
0 1 2 { 0 1 0 rg 10 mul 100 add 0 5 5 re f } for
1 0 0 0 k 0 0 4 4 re f
showpage
end
"""

block shapes:
  let r = psShapes(program)
  check (r.x0, r.y0, r.x1, r.y1) == (0.0, 0.0, 200.0, 100.0), "its bounding box"
  check r.shapes.len == 7, "seven shapes (" & $r.shapes.len & ")"
  if r.shapes.len == 7:
    let sq = r.shapes[0]
    check sq.fill.kind == spColor and sq.fill.color == 0xFFFF0000'u32 and sq.path.subs.len == 2 and
          sq.path.subs[1].joined, "the red square, its hole a piece of the same part"
    let cv = r.shapes[1]
    check cv.stroke.kind == spColor and cv.stroke.color == 0xFF0000FF'u32 and cv.strokeWidth == 4 and
          cv.fill.kind == spNone and abs(pathBounds(cv.path)[0] - 110) < 1e-6, "the blue curve, moved over by 100"
    check r.shapes[2].fill.color == 0xFF808080'u32, "the gray circle"
    let b = pathBounds(r.shapes[2].path)
    check abs(b[0] - 130) < 0.5 and abs(b[2] - 170) < 0.5, "a circle 40 across"
    check r.shapes[3].fill.color == 0xFF00FF00'u32 and abs(pathBounds(r.shapes[5].path)[0] - 120) < 1e-6,
          "the green squares of the loop, each 10 further"
    check r.shapes[6].fill.color == 0xFF00FFFF'u32, "cyan from CMYK"
  # (drawn: the hole stays empty)
  var px = newSeq[uint32](200 * 100)
  var s = r.shapes[0]
  s.path.mapPoints(proc (x, y: float): (float, float) = (x, 100 - y))
  discard renderShape(s, px, 200, 100)
  check (px[50 * 200 + 20] shr 24) == 255 and (px[50 * 200 + 50] shr 24) == 0, "the hole empty when filled"

block opened:
  let d = importPs(program, "drawn")
  var shapes = 0
  for L in d.layers:
    if L.isShape: inc shapes
  check d.w == 417 and d.h == 209 and shapes >= 5, "opened as shape layers on a page of its size at 150 ppi (" &
        $d.w & " x " & $d.h & ", " & $shapes & ")"

block ownEps:
  # (an EPS written by the kit, its shapes as vectors: read back as shapes)
  let d = newDoc(300, 200, 0xFFFFFFFF'u32, name = "own")
  var e = ShapeData(kind: "Ellipse", fill: solidPaint(0xFF3366AA'u32))
  e.path = ellipsePath(50, 50, 250, 150)
  discard d.addShapeLayer(e)
  let p = getTempDir() / "retro-own.eps"
  d.savePs(p, eps = true)
  let r = psShapes(readFile(p))
  var blue = false
  for s in r.shapes:
    let c = s.fill.color
    if s.fill.kind == spColor and abs(int((c shr 16) and 255) - 0x33) < 3 and abs(int(c and 255) - 0xAA) < 3: blue = true
  check blue, "its ellipse read back in its color (" & $r.shapes.len & " shapes)"
  removeFile(p)

block nothingAndEndless:
  check psShapes("%!PS\n1 2 add pop\n").shapes.len == 0, "a program that draws nothing: no shapes"
  var stopped = false
  try: discard psShapes("%!PS\n{ 1 pop } loop\n0 0 moveto 1 1 lineto stroke\n")
  except PsError: stopped = true
  check true, "an endless loop stopped (" & (if stopped: "refused" else: "cut short") & ")"

if failures > 0:
  echo "test_psvector: ", failures, " failed"
  quit(1)
echo "test_psvector: all passed"

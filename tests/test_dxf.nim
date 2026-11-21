## DXF drawings (`retroui/dxf`): a drawing written by hand -- its layers and their colors, a
## line, a closed polyline with a bulge (an arc), a circle, an arc, an ellipse, a spline, a
## solid, text, and a block inserted twice, scaled and turned -- opened as shape layers, one
## for each layer and color, and type; y up made y down; the CAD palette; what is not a DXF
## refused.

import std/[strutils, math]
import retroui/[gfx, photo, photoshapes, dxf]

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

proc dxfOf(parts: varargs[string]): string =
  for p in parts: result.add p & "\n"

let drawing = dxfOf(
  "0", "SECTION", "2", "TABLES",
  "0", "TABLE", "2", "LAYER",
  "0", "LAYER", "2", "WALLS", "70", "0", "62", "1",
  "0", "LAYER", "2", "DOORS", "70", "0", "62", "5",
  "0", "LAYER", "2", "HIDDEN", "70", "0", "62", "-3",
  "0", "ENDTAB",
  "0", "ENDSEC",
  "0", "SECTION", "2", "BLOCKS",
  "0", "BLOCK", "8", "0", "2", "MARK", "10", "0", "20", "0",
  "0", "LINE", "8", "0", "10", "0", "20", "0", "11", "10", "21", "0",
  "0", "ENDBLK",
  "0", "ENDSEC",
  "0", "SECTION", "2", "ENTITIES",
  "0", "LINE", "8", "WALLS", "10", "0", "20", "0", "11", "100", "21", "0",
  "0", "LWPOLYLINE", "8", "WALLS", "90", "4", "70", "1",
    "10", "0", "20", "0", "10", "100", "20", "0", "42", "1", "10", "100", "20", "50", "10", "0", "20", "50",
  "0", "CIRCLE", "8", "DOORS", "10", "50", "20", "25", "40", "10",
  "0", "ARC", "8", "DOORS", "10", "20", "20", "20", "40", "5", "50", "0", "51", "90",
  "0", "ELLIPSE", "8", "DOORS", "10", "80", "20", "25", "11", "8", "21", "0", "40", "0.5", "41", "0", "42", "6.283185307",
  "0", "SPLINE", "8", "DOORS", "71", "3", "73", "4", "10", "0", "20", "60", "10", "30", "20", "80", "10", "60", "20", "40",
    "10", "100", "20", "60",
  "0", "SOLID", "8", "DOORS", "62", "3", "10", "40", "20", "0", "11", "60", "21", "0", "12", "40", "22", "10", "13", "60",
    "23", "10",
  "0", "TEXT", "8", "WALLS", "10", "5", "20", "40", "40", "4", "1", "Kitchen",
  "0", "LINE", "8", "HIDDEN", "10", "0", "20", "0", "11", "1", "21", "1",
  "0", "INSERT", "8", "WALLS", "2", "MARK", "10", "10", "20", "70", "41", "2", "42", "2", "50", "90",
  "0", "INSERT", "8", "WALLS", "2", "MARK", "10", "90", "20", "70",
  "0", "ENDSEC", "0", "EOF")

block palette:
  check aciColor(1) == 0xFFFF0000'u32 and aciColor(5) == 0xFF0000FF'u32 and aciColor(7) == 0xFF000000'u32,
        "the CAD palette's first colors (7 black on a white page)"
  check aciColor(10) == 0xFFFF0000'u32 and aciColor(250) == 0xFF333333'u32, "its hues and grays"

block opened:
  let d = importDxf(drawing, "plan", longSide = 1000)
  check d.w == 1000 and d.h > 100 and d.h < 1000, "fitted on a page (" & $d.w & " x " & $d.h & ")"
  var shapes, texts: seq[Layer]
  for L in d.layers:
    if L.isShape: shapes.add L
    elif L.isText: texts.add L
  var walls, doors: Layer
  for L in shapes:
    if L.name == "WALLS" and walls == nil: walls = L
    if L.name == "DOORS" and L.shape.stroke.kind != spNone and doors == nil: doors = L
  check walls != nil and walls.shape.stroke.color == 0xFFFF0000'u32, "WALLS in its layer's red"
  check doors != nil and doors.shape.stroke.color == 0xFF0000FF'u32, "DOORS in blue"
  var hidden = false
  for L in shapes:
    if L.name == "HIDDEN": hidden = true
  check not hidden, "a layer turned off: not drawn"
  var solid = false
  for L in shapes:
    if L.shape.fill.kind == spColor and L.shape.fill.color == 0xFF00FF00'u32: solid = true
  check solid, "the solid filled in its own green"
  check texts.len == 1 and texts[0].text.spans[0].text == "Kitchen", "its text as type"
  # (the walls: the line, the polyline, the two marks -- one turned, its line going up)
  check walls.shape.path.subs.len == 4, "the line, the polyline and the block twice (" & $walls.shape.path.subs.len & ")"
  let poly = walls.shape.path.subs[1]
  check poly.closed and poly.pts.len > 8, "the polyline closed, its bulge an arc of many points"
  # (y up made y down: the polyline's top -- y 50 -- above its bottom on the page)
  let (_, py0, _, py1) = pathBounds(Path(subs: @[poly]))
  check py1 - py0 > 0, "y down"
  let m1 = walls.shape.path.subs[2]
  check abs(m1.pts[0].p[0] - m1.pts[1].p[0]) < 0.5 and m1.pts[1].p[1] < m1.pts[0].p[1],
        "the block turned a quarter: its line going up"
  let m2 = walls.shape.path.subs[3]
  let len1 = hypot(m1.pts[1].p[0] - m1.pts[0].p[0], m1.pts[1].p[1] - m1.pts[0].p[1])
  let len2 = hypot(m2.pts[1].p[0] - m2.pts[0].p[0], m2.pts[1].p[1] - m2.pts[0].p[1])
  check abs(len1 - 2 * len2) < 0.5, "and twice as long as the other"

block refused:
  var bad = false
  try: discard importDxf("hello\nworld\n")
  except DxfError: bad = true
  check bad, "not a DXF: refused"
  bad = false
  try: discard importDxf(dxfOf("0", "SECTION", "2", "ENTITIES", "0", "ENDSEC", "0", "EOF"))
  except DxfError: bad = true
  check bad, "nothing drawn: refused"

if failures > 0:
  echo "test_dxf: ", failures, " failed"
  quit(1)
echo "test_dxf: all passed"

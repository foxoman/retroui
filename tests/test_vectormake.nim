## Tests of the drawing program's ways of making (retroui/vectormake): Global Edit, Live
## Paint, Intertwine, Pattern Options' tiles, Tidy Up, Flex Layout on a group; Envelope
## Distort (retroui/liveeffects).

import std/[tables, hashes]
import retroui/[photo, photoshapes, vectormake, liveeffects]

proc box(d: Doc; x, y, w, h: float; c: uint32; name = ""): Layer =
  d.addShapeLayer(ShapeData(path: rectPath(x, y, x + w, y + h), fill: solidPaint(c)), name)

proc disc(d: Doc; cx, cy, r: float; c: uint32): Layer =
  d.addShapeLayer(ShapeData(path: ellipsePath(cx - r, cy - r, cx + r, cy + r), fill: solidPaint(c)))

block globalEdit:
  let d = newDoc(400, 300, 0xFFFFFFFF'u32)
  let a = d.box(10, 10, 50, 30, 0xFFFF0000'u32)
  let b = d.box(200, 100, 50, 30, 0xFF00FF00'u32)
  let c = d.box(100, 200, 100, 60, 0xFF0000FF'u32)          # (twice as big)
  let e = d.disc(300, 50, 20, 0xFF000000'u32)
  doAssert d.similarLayers(a) == @[b]
  doAssert d.similarLayers(a, sameSize = false) == @[b, c]
  doAssert d.similarLayers(a, sameLook = true).len == 0
  discard e
  # a change to one: the others too, each where it is
  var s = a.shape
  s.fill = solidPaint(0xFFFFAA00'u32)
  s.path = rectPath(10, 10, 70, 40)                         # (wider)
  d.setShape(a, s)
  d.globalEdit(a, [b, c], sameSize = false)
  doAssert b.shape.fill.color == 0xFFFFAA00'u32 and c.shape.fill.color == 0xFFFFAA00'u32
  let (bx0, by0, bx1, _) = pathBounds(b.shape.path)
  doAssert abs(bx0 - 200) < 1e-6 and abs(by0 - 100) < 1e-6 and abs(bx1 - 250) < 1e-6   # (its own box)
  d.globalEdit(a, [b], sameSize = true)
  let (_, _, bx2, _) = pathBounds(b.shape.path)
  doAssert abs(bx2 - 260) < 1e-6                             # (as wide as the one changed)

block livePaint:
  let d = newDoc(300, 200, 0xFFFFFFFF'u32)
  let l = d.disc(100, 100, 60, 0x00000000'u32)
  let r = d.disc(180, 100, 60, 0x00000000'u32)
  if l.uid == 0: l.uid = 11
  if r.uid == 0: r.uid = 12
  var lp = LivePaint(shapes: @[l.uid, r.uid])
  doAssert d.faceMask(lp, 5, 5).len == 0                     # (outside them both: no face)
  let mid = d.faceMask(lp, 140, 100)
  doAssert mid[100 * 300 + 140] == 255 and mid[100 * 300 + 60] == 0 and mid[100 * 300 + 220] == 0
  lp.fillFace(140, 100, 0xFFFF0000'u32)
  lp.fillFace(60, 100, 0xFF0000FF'u32)
  var px = d.paintFaces(lp)
  doAssert px[100 * 300 + 140] == 0xFFFF0000'u32 and px[100 * 300 + 60] == 0xFF0000FF'u32
  doAssert (px[100 * 300 + 220] shr 24) == 0                # (the right one's own part: not painted)
  # the shape moved: the faces follow it, their colors kept
  d.setShape(r, ShapeData(path: ellipsePath(110, 40, 230, 160), fill: solidPaint(0'u32)))
  px = d.paintFaces(lp)
  doAssert px[100 * 300 + 140] == 0xFFFF0000'u32 and px[100 * 300 + 115] == 0xFFFF0000'u32
  lp.fillFace(140, 100, 0)                                   # (unpainted)
  doAssert lp.faces.len == 1
  doAssert livePaintFrom(lp.toJson).faces == lp.faces

block intertwine:
  let d = newDoc(300, 200, 0xFFFFFFFF'u32)
  let under = d.box(20, 80, 260, 40, 0xFF0000FF'u32)
  let over = d.box(130, 20, 40, 160, 0xFFFF0000'u32)
  let part = d.crossing(over, under, 150, 100)
  doAssert part.len == 300 * 200 and part[100 * 300 + 150] == 255 and part[100 * 300 + 50] == 0
  doAssert part[40 * 300 + 150] == 0                          # (only where they cross)
  doAssert d.crossing(over, under, 50, 100).len == 0

block patternTiles:
  var art = newSeq[uint32](10 * 10)
  for i in 0 ..< art.len: art[i] = 0xFF112233'u32
  var t = patternTile(art, 10, 10, PatternSpec(tile: ttGrid, hSpace: 4, vSpace: 2))
  doAssert t.w == 14 and t.h == 12
  doAssert t.px[1 * 14 + 2] == 0xFF112233'u32 and t.px[0] == 0   # (the art in its middle, room round it)
  t = patternTile(art, 10, 10, PatternSpec(tile: ttBrickRow))
  doAssert t.w == 10 and t.h == 20
  # (the second row half a tile across: it crosses the tile's edge and comes in at the other)
  doAssert t.px[15 * 10 + 0] == 0xFF112233'u32 and t.px[15 * 10 + 9] == 0xFF112233'u32
  t = patternTile(art, 10, 10, PatternSpec(tile: ttHexColumn, hSpace: 2, vSpace: 2))
  doAssert t.w == 18 and t.h == 12
  t = patternTile(art, 10, 10, PatternSpec(tile: ttHexRow))
  doAssert t.w == 10 and t.h == 16
  t = patternTile(art, 10, 10, PatternSpec(tile: ttBrickColumn, brickOffset: 3))
  doAssert t.w == 30 and t.h == 10

block tidy:
  let row = tidyUp([rect(10, 12, 40, 30), rect(70, 8, 40, 30), rect(150, 15, 40, 30)])
  doAssert row[0].x == 10 and row[2].x + 40 == 190
  doAssert row[1].x - (row[0].x + 40) == row[2].x - (row[1].x + 40)   # (even room)
  doAssert row[0].y == row[1].y and row[1].y == row[2].y
  let grid = tidyUp([rect(0, 0, 50, 50), rect(70, 5, 50, 50), rect(3, 72, 50, 50), rect(68, 66, 50, 50)], gap = 10)
  doAssert grid[0] == rect(0, 0, 50, 50) and grid[1] == rect(60, 0, 50, 50)
  doAssert grid[2] == rect(0, 60, 50, 50) and grid[3] == rect(60, 60, 50, 50)

block flexGroup:
  let d = newDoc(500, 300, 0xFFFFFFFF'u32)
  discard d.box(300, 200, 50, 40, 0xFFFF0000'u32, "a")
  discard d.box(10, 10, 80, 60, 0xFF00FF00'u32, "b")
  let g = d.groupLayers(@[1, 2], "Flex")
  let gi = d.layers.find(g)
  g.setFlex(FlexBox(dir: fdRow, gap: 10, w: 400, h: 100, align: faStart), 20, 30)
  doAssert g.flexOf.on and g.flexOf.x == 20
  doAssert d.arrangeFlex(gi)
  let kids = d.flexChildren(gi)
  doAssert kids.len == 2
  let first = d.layerBox(d.layers[kids[0]])
  let second = d.layerBox(d.layers[kids[1]])
  doAssert first.x == 20 and first.y == 30 and second.x == first.x + first.w + 10 and second.y == 30
  doAssert not d.arrangeFlex(gi)                       # (in place: nothing moves)
  g.setFlex(FlexBox(), 0, 0, on = false)
  doAssert not g.flexOf.on

block envelopes:
  let p = rectPath(100, 100, 200, 160)
  # Make with Mesh: a corner of the grid pulled, the shape with it; nothing moved, as it was
  var moved = newSeq[(float, float)](9)
  let same = envelopeMesh(p, 2, 2, moved)
  let (a0, b0, a1, b1) = pathBounds(same)
  doAssert abs(a0 - 100) < 0.5 and abs(b0 - 100) < 0.5 and abs(a1 - 200) < 0.5 and abs(b1 - 160) < 0.5
  moved[8] = (40.0, 30.0)                                      # (the bottom right corner)
  let (_, _, c1, d1) = pathBounds(envelopeMesh(p, 2, 2, moved))
  doAssert abs(c1 - 240) < 1 and abs(d1 - 190) < 1
  doAssert envelopeMesh(p, 2, 2, newSeq[(float, float)](4)) == p    # (a grid of another size: as it was)
  # Make with Top Object: fitted into a triangle's outline -- its top edge to the point
  var tri: seq[(float, float)]
  for i in 0 ..< 30: tri.add (300.0 + i.float * 10, 400.0)         # (the bottom, left to right)
  for i in 0 ..< 15: tri.add (600.0 - i.float * 10, 400.0 - i.float * 20)
  for i in 0 ..< 15: tri.add (450.0 - i.float * 10, 100.0 + i.float * 20)
  let fitted = envelopeTop(p, tri)
  let (e0, f0, e1, f1) = pathBounds(fitted)
  doAssert e0 >= 299 and e1 <= 601 and f0 >= 99 and f1 <= 401, $(e0, f0, e1, f1)
  doAssert f1 - f0 > 250                                         # (as tall as the triangle)
  doAssert envelopeTop(p, [(0.0, 0.0), (1.0, 1.0)]) == p          # (no outline: as it was)
  # live: through the effects, released by taking it away
  let live = applyEffects(p, @[LiveEffect(kind: leEnvelope, copies: 2, detail: 2, mesh: moved)])
  doAssert abs(pathBounds(live)[2] - 240) < 1
  doAssert applyEffects(p, @[LiveEffect(kind: leEnvelope, envelope: tri)]).pathBounds[3] > 390

block symbolsKeptAlike:
  # (a group made a symbol, two more instances placed; what is in one changed: the others the same,
  # each where it is; an instance moved: only moved; undone: all back; detached: on its own)
  let d = newDoc(400, 300, 0xFFFFFFFF'u32)
  d.beginStep("shapes")
  d.touchLayers()
  discard d.addShapeLayer(ShapeData(path: rectPath(20, 20, 60, 40), fill: solidPaint(0xFFFF0000'u32)), "Body")
  discard d.addShapeLayer(ShapeData(path: rectPath(25, 25, 35, 35), fill: solidPaint(0xFF0000FF'u32)), "Dot")
  let sym = d.makeSymbol(@[d.layers.len - 2, d.layers.len - 1], "Button")
  d.endStep()
  doAssert sym != nil and sym.symbolOf == (1, "Button"), "a symbol made"
  var seen: Table[int, Hash]
  discard d.keepSymbols(seen)
  d.beginStep("Insert")
  d.touchLayers()
  let b = d.insertSymbol(1, 100, 0)
  let c = d.insertSymbol(1, 0, 150)
  d.endStep()
  doAssert d.symbolInstances(1).len == 3 and b.symbolOf.id == 1 and c.symbolOf.id == 1, "three instances"
  doAssert not d.keepSymbols(seen), "alike: nothing to do"
  proc partNamed(g: Layer; name: string): Layer =
    let gi = d.layers.find(g)
    for j in d.blockStart(gi) ..< gi:
      if d.layers[j].name == name: return d.layers[j]
  # (the dot in the second made green and bigger)
  d.beginStep("Edit")
  d.touchLayers()
  var s = b.partNamed("Dot").shape
  s.fill = solidPaint(0xFF00FF00'u32)
  s.path = rectPath(125, 25, 140, 38)
  d.setShape(b.partNamed("Dot"), s)
  d.endStep()
  doAssert d.keepSymbols(seen), "changed: the others follow"
  for (g, ox, oy) in [(sym, 0, 0), (b, 100, 0), (c, 0, 150)]:
    let dot = g.partNamed("Dot")
    doAssert dot != nil and dot.shape.fill.color == 0xFF00FF00'u32, g.name & ": green"
    doAssert pathBounds(dot.shape.path) == (25.0 + ox.float, 25.0 + oy.float, 40.0 + ox.float, 38.0 + oy.float),
             g.name & ": where its instance is: " & $pathBounds(dot.shape.path)
  doAssert not d.keepSymbols(seen), "and alike again"
  # (an instance moved: only it)
  let gi = d.layers.find(c)
  var parts: seq[Layer]
  for j in d.blockStart(gi) .. gi: parts.add d.layers[j]
  d.beginStep("Move")
  d.shiftLayers(parts, 50, 0)
  d.endStep()
  doAssert not d.keepSymbols(seen), "moved: nothing else changes"
  doAssert pathBounds(sym.partNamed("Body").shape.path)[0] == 20.0, "the first where it was"
  # (undone: the edit gone from all)
  d.undo()                                   # (the move)
  d.undo()                                   # (the edit)
  discard d.keepSymbols(seen)
  for g in [sym, b, c]:
    doAssert g.partNamed("Dot").shape.fill.color == 0xFF0000FF'u32, g.name & ": blue again"
  detachSymbol(c)
  doAssert c.symbolOf.id == 0 and d.symbolInstances(1).len == 2, "detached: a plain group"

echo "vector making ok"

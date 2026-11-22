## The drawing program's ways of making with what is drawn:
##
## - Global Edit: the objects like one (the same outline, wherever it is; the same size or any)
##   found, and a change to one made to them all.
## - Live Paint: shapes that overlap make faces -- each part where the same shapes are over it
##   -- and the Live Paint Bucket fills a face; move a shape and the faces follow, keeping their
##   colors (a face is known by a point in it).
## - Intertwine: where two objects cross, the one under brought over in that part alone (a
##   ring through a ring, letters through a loop).
## - Pattern Options: art made a seamless tile -- in a grid, bricks by row or column, hexagons
##   by row or column, spaced, the copies overlapping as asked.
## - Tidy Up: what is picked put in a neat row, column or grid, the room between them even.
## - Flex Layout on a group: its frames kept in a row or a column (`retroui/flexlayout`) --
##   change one and the others move.
## - Symbols (Affinity's, Illustrator's): a group made a symbol, its copies (instances) placed
##   anywhere -- change what is in one and the others change the same, each where it is.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[math, algorithm, json, sequtils, strutils, tables, hashes]
import photo, photoshapes, parallel, flexlayout, textengine

export flexlayout

# ---- Global Edit -------------------------------------------------------------------------------------

proc outlineKey(p: Path; sameSize: bool): seq[(float, float)] =
  ## (a path's points from its box's corner -- or, any size, as parts of its box)
  let (x0, y0, x1, y1) = pathBounds(p)
  let w = max(1e-9, x1 - x0)
  let h = max(1e-9, y1 - y0)
  for sp in p.subs:
    for q in sp.pts:
      for v in [q.p, q.inH, q.outH]:
        if sameSize: result.add (v[0] - x0, v[1] - y0)
        else: result.add ((v[0] - x0) / w, (v[1] - y0) / h)

proc alike*(a, b: Layer; sameSize = true; sameLook = false; tolerance = 0.5): bool =
  ## Two shape layers with the same outline (moved; `sameSize`: and as big), and -- `sameLook`
  ## -- the same fill and stroke.
  if not a.isShape or not b.isShape: return false
  if a.shape.path.subs.len != b.shape.path.subs.len: return false
  for i in 0 ..< a.shape.path.subs.len:
    if a.shape.path.subs[i].pts.len != b.shape.path.subs[i].pts.len or
       a.shape.path.subs[i].closed != b.shape.path.subs[i].closed:
      return false
  if sameLook and (a.shape.fill != b.shape.fill or a.shape.stroke != b.shape.stroke or
                   a.shape.strokeWidth != b.shape.strokeWidth):
    return false
  let ka = outlineKey(a.shape.path, sameSize)
  let kb = outlineKey(b.shape.path, sameSize)
  if ka.len != kb.len: return false
  let (x0, y0, x1, y1) = pathBounds(a.shape.path)
  let tol = if sameSize: tolerance else: tolerance / max(1.0, max(x1 - x0, y1 - y0))
  for i in 0 ..< ka.len:
    if abs(ka[i][0] - kb[i][0]) > tol or abs(ka[i][1] - kb[i][1]) > tol: return false
  true

proc similarLayers*(d: Doc; L: Layer; sameSize = true; sameLook = false): seq[Layer] =
  ## Global Edit: the other shape layers like `L` (`alike`), on its artboard when it is on one.
  for M in d.layers:
    if M != L and not M.locked and alike(L, M, sameSize, sameLook): result.add M

proc globalEdit*(d: Doc; src: Layer; others: openArray[Layer]; sameSize = true) =
  ## The change made to `src` made to the others too: its look (fill, stroke, effects), and
  ## its outline, each where it is (as big as it is when not `sameSize`).
  let (sx0, sy0, sx1, sy1) = pathBounds(src.shape.path)
  for M in others:
    if M == src or not M.isShape: continue
    let (mx0, my0, mx1, my1) = pathBounds(M.shape.path)
    var s = src.shape
    if sameSize: s.path = translated(src.shape.path, mx0 - sx0, my0 - sy0)
    else:
      # (in its own box: the outline made as big as it was)
      let kx = (mx1 - mx0) / max(1e-9, sx1 - sx0)
      let ky = (my1 - my0) / max(1e-9, sy1 - sy0)
      s.path = src.shape.path
      for sp in s.path.subs.mitems:
        for q in sp.pts.mitems:
          for v in [addr q.p, addr q.inH, addr q.outH]:
            v[] = (mx0 + (v[][0] - sx0) * kx, my0 + (v[][1] - sy0) * ky)
    M.opacity = src.opacity
    M.mode = src.mode
    d.setShape(M, s)

# ---- Live Paint --------------------------------------------------------------------------------------

type
  LivePaintFace* = object
    ## A face painted: known by a point in it.
    x*, y*: int
    color*: uint32

  LivePaint* = object
    ## A Live Paint group: the shapes that make its faces (their layers' `uid`s), the faces
    ## painted.
    shapes*: seq[int]
    faces*: seq[LivePaintFace]

proc toJson*(lp: LivePaint): JsonNode =
  var fs = newJArray()
  for f in lp.faces: fs.add %*[f.x, f.y, int64(f.color)]
  %*{"shapes": lp.shapes, "faces": fs}

proc livePaintFrom*(j: JsonNode): LivePaint =
  if j == nil or j.kind != JObject: return
  for u in j{"shapes"}.getElems: result.shapes.add u.getInt
  for f in j{"faces"}.getElems:
    if f.kind == JArray and f.len == 3:
      result.faces.add LivePaintFace(x: f[0].getInt, y: f[1].getInt, color: uint32(f[2].getBiggestInt and 0xFFFFFFFF))

proc shapeMasks(d: Doc; lp: LivePaint): seq[seq[uint8]] =
  for u in lp.shapes:
    let L = d.layerOfUid(u)
    if L != nil and L.isShape: result.add shapeMask(L.shape.path, d.w, d.h)
  if result.len > 63: result.setLen(63)

proc signatureAt(masks: seq[seq[uint8]]; i: int): uint64 =
  for k, m in masks:
    if m[i] >= 128: result = result or (1'u64 shl k)

proc faceMask*(d: Doc; lp: LivePaint; x, y: int; masks: seq[seq[uint8]] = @[]): seq[uint8] =
  ## The face at `x`, `y`: how much of each pixel is in it (0..255; empty: no face there --
  ## outside every shape).
  let ms = if masks.len > 0: masks else: d.shapeMasks(lp)
  if x < 0 or y < 0 or x >= d.w or y >= d.h or ms.len == 0: return
  let w = d.w
  let h = d.h
  let sig = signatureAt(ms, y * w + x)
  if sig == 0: return
  # (the pixels of that signature joined to it)
  var inFace = newSeq[bool](w * h)
  var stack = @[y * w + x]
  inFace[y * w + x] = true
  while stack.len > 0:
    let i = stack.pop()
    let px = i mod w
    let py = i div w
    for (nx, ny) in [(px - 1, py), (px + 1, py), (px, py - 1), (px, py + 1)]:
      if nx < 0 or ny < 0 or nx >= w or ny >= h: continue
      let j = ny * w + nx
      if not inFace[j] and signatureAt(ms, j) == sig:
        inFace[j] = true
        stack.add j
  # (its soft edges: a pixel next to it as much in it as its shapes say)
  result = newSeq[uint8](w * h)
  let rp = cast[ptr UncheckedArray[uint8]](addr result[0])
  let fp = cast[ptr UncheckedArray[bool]](addr inFace[0])
  var mp = newSeq[ptr UncheckedArray[uint8]](ms.len)
  for k in 0 ..< ms.len: mp[k] = cast[ptr UncheckedArray[uint8]](unsafeAddr ms[k][0])
  let mpp = cast[ptr UncheckedArray[ptr UncheckedArray[uint8]]](addr mp[0])
  let nm = ms.len
  parallelRows(h, py):
    for px in 0 ..< w:
      let i = py * w + px
      var near = fp[i]
      if not near:
        for (nx, ny) in [(px - 1, py), (px + 1, py), (px, py - 1), (px, py + 1)]:
          if nx >= 0 and ny >= 0 and nx < w and ny < h and fp[ny * w + nx]: near = true
      if not near: continue
      var c = 1.0
      for k in 0 ..< nm:
        let v = float(mpp[k][i]) / 255
        c *= (if (sig and (1'u64 shl k)) != 0: v else: 1 - v)
      rp[i] = uint8(clamp(int(round(c * 255)), 0, 255))

proc paintFaces*(d: Doc; lp: LivePaint): seq[uint32] =
  ## The Live Paint group's faces in their colors (`d.w` x `d.h`, transparent elsewhere).
  result = newSeq[uint32](d.w * d.h)
  if lp.faces.len == 0: return
  let ms = d.shapeMasks(lp)
  for f in lp.faces:
    let m = d.faceMask(lp, f.x, f.y, ms)
    if m.len == 0: continue
    let a0 = int(f.color shr 24)
    for i in 0 ..< m.len:
      if m[i] == 0: continue
      let a = a0 * int(m[i]) div 255
      let o = result[i]
      let oa = int(o shr 24)
      # (over what another face put there)
      let na = a + oa * (255 - a) div 255
      if na <= 0: continue
      template ch(sh: int): uint32 =
        uint32((int((f.color shr sh) and 255) * a + int((o shr sh) and 255) * oa * (255 - a) div 255) div na)
      result[i] = (uint32(na) shl 24) or (ch(16) shl 16) or (ch(8) shl 8) or ch(0)

proc fillFace*(lp: var LivePaint; x, y: int; color: uint32) =
  ## The Live Paint Bucket: the face at `x`, `y` filled with `color` (a face painted before,
  ## there: its color changed; transparent: unpainted).
  var keep: seq[LivePaintFace]
  for f in lp.faces:
    if f.x != x or f.y != y: keep.add f
  lp.faces = keep
  if (color shr 24) > 0: lp.faces.add LivePaintFace(x: x, y: y, color: color)

# ---- Intertwine --------------------------------------------------------------------------------------

proc crossing*(d: Doc; over, under: Layer; x, y: int): seq[uint8] =
  ## Intertwine: the part where `over` and `under` cross that takes in `x`, `y` (0..255 a pixel;
  ## empty: they do not cross there) -- where `under` is to come over.
  let w = d.w
  let h = d.h
  if x < 0 or y < 0 or x >= w or y >= h or over.px.len != w * h or under.px.len != w * h: return
  template both(i: int): bool = (over.px[i] shr 24) >= 64 and (under.px[i] shr 24) >= 64
  if not both(y * w + x): return
  var inPart = newSeq[bool](w * h)
  var stack = @[y * w + x]
  inPart[y * w + x] = true
  while stack.len > 0:
    let i = stack.pop()
    let px = i mod w
    let py = i div w
    for (nx, ny) in [(px - 1, py), (px + 1, py), (px, py - 1), (px, py + 1)]:
      if nx < 0 or ny < 0 or nx >= w or ny >= h: continue
      let j = ny * w + nx
      if not inPart[j] and both(j):
        inPart[j] = true
        stack.add j
  result = newSeq[uint8](w * h)
  for i in 0 ..< w * h:
    if inPart[i]: result[i] = 255
  # (a pixel more round it: the edge of what comes over covers the edge under it)
  var grown = result
  for py in 0 ..< h:
    for px in 0 ..< w:
      if result[py * w + px] != 0: continue
      for (nx, ny) in [(px - 1, py), (px + 1, py), (px, py - 1), (px, py + 1)]:
        if nx >= 0 and ny >= 0 and nx < w and ny < h and result[ny * w + nx] != 0:
          grown[py * w + px] = 255
          break
  result = grown

# ---- Pattern Options ---------------------------------------------------------------------------------

type
  TileType* = enum
    ## How the copies of a pattern's art are set (Pattern Options' Tile Type).
    ttGrid = "Grid", ttBrickRow = "Brick by Row", ttBrickColumn = "Brick by Column",
    ttHexColumn = "Hex by Column", ttHexRow = "Hex by Row"

  PatternSpec* = object
    ## Pattern Options.
    tile*: TileType
    w*, h*: int                ## the tile's size (0: the art's)
    hSpace*, vSpace*: int      ## room between copies (negative: they overlap)
    brickOffset*: int          ## bricks: each row (column) moved 1/`brickOffset` of a tile (2..5;
                               ## 0: a half)
    overlapLeftOnTop*, overlapTopOnTop*: bool  ## which copy is over where they overlap

proc patternTile*(art: openArray[uint32]; aw, ah: int; s: PatternSpec): tuple[px: seq[uint32]; w, h: int] =
  ## The art (`aw` x `ah`, transparent round it) made a seamless tile as Pattern Options sets
  ## it: what repeats, wrapping round, every copy that falls in it drawn (in the overlap order).
  let tw = max(1, (if s.w > 0: s.w else: aw) + s.hSpace)
  let th = max(1, (if s.h > 0: s.h else: ah) + s.vSpace)
  let q = if s.brickOffset in 2 .. 5: s.brickOffset else: 2
  # (the tile that repeats, and where the copies go in it)
  var uw, uh: int
  var spots: seq[(float, float)]
  case s.tile
  of ttGrid:
    uw = tw; uh = th
    spots = @[(0.0, 0.0)]
  of ttBrickRow:
    uw = tw; uh = th * q
    for j in 0 ..< q: spots.add (float(j * tw) / float(q), float(j * th))
  of ttBrickColumn:
    uw = tw * q; uh = th
    for i in 0 ..< q: spots.add (float(i * tw), float(i * th) / float(q))
  of ttHexColumn:
    # (columns three quarters of a tile apart, every other half a tile down)
    let cx = max(1, int(round(tw.float * 0.75)))
    uw = 2 * cx; uh = th
    spots = @[(0.0, 0.0), (cx.float, th.float / 2)]
  of ttHexRow:
    let ry = max(1, int(round(th.float * 0.75)))
    uw = tw; uh = 2 * ry
    spots = @[(0.0, 0.0), (tw.float / 2, ry.float)]
  uw = min(uw, 8192); uh = min(uh, 8192)
  result.w = uw
  result.h = uh
  result.px = newSeq[uint32](uw * uh)
  if aw <= 0 or ah <= 0: return
  # (each copy, and its neighbours past the tile's edges, so what crosses an edge comes in at
  # the other: drawn in order, the overlap's top one last)
  var order: seq[(float, float)]
  for (sx, sy) in spots:
    for oy in -1 .. 1:
      for ox in -1 .. 1:
        order.add (sx + float(ox * uw) + float(tw - aw) / 2, sy + float(oy * uh) + float(th - ah) / 2)
  order.sort(proc (a, b: (float, float)): int =
    let ky = cmp(a[1], b[1])
    let kx = cmp(a[0], b[0])
    let byY = if s.overlapTopOnTop: -ky else: ky
    let byX = if s.overlapLeftOnTop: -kx else: kx
    if byY != 0: byY else: byX)
  for (fx, fy) in order:
    let ox = int(round(fx))
    let oy = int(round(fy))
    for y in 0 ..< ah:
      let ty = oy + y
      if ty < 0 or ty >= uh: continue
      for x in 0 ..< aw:
        let tx = ox + x
        if tx < 0 or tx >= uw: continue
        let p = art[y * aw + x]
        let a = int(p shr 24)
        if a == 0: continue
        let i = ty * uw + tx
        if a == 255: result.px[i] = p
        else:
          let o = result.px[i]
          let oa = int(o shr 24)
          let na = a + oa * (255 - a) div 255
          template ch(sh: int): uint32 =
            uint32((int((p shr sh) and 255) * a + int((o shr sh) and 255) * oa * (255 - a) div 255) div max(1, na))
          result.px[i] = (uint32(na) shl 24) or (ch(16) shl 16) or (ch(8) shl 8) or ch(0)

# ---- Tidy Up -----------------------------------------------------------------------------------------

proc tidyUp*(rects: openArray[Rect]; gap = -1): seq[Rect] =
  ## Tidy Up: boxes put neatly -- in a row or a column when they mostly are one (their middles
  ## lined up, the room between them even), else in a grid of the columns they come nearest
  ## to, each in its cell's middle. `gap` the room between them (-1: what they had, on the
  ## whole). The row starts where its first box did.
  let n = rects.len
  if n < 2: return @rects
  var xs, ys: seq[float]
  for r in rects:
    xs.add r.x.float + r.w.float / 2
    ys.add r.y.float + r.h.float / 2
  let spreadX = max(xs) - min(xs)
  let spreadY = max(ys) - min(ys)
  var hMax, wMax = 0
  for r in rects:
    hMax = max(hMax, r.h)
    wMax = max(wMax, r.w)
  var idx = toSeq(0 ..< n)
  result = @rects
  if spreadY <= hMax.float * 0.6 or spreadX <= wMax.float * 0.6:
    # a row (or a column)
    let row = spreadY <= hMax.float * 0.6 and spreadX > spreadY
    idx.sort(proc (a, b: int): int = (if row: cmp(xs[a], xs[b]) else: cmp(ys[a], ys[b])))
    var total = 0
    for i in idx: total += (if row: rects[i].w else: rects[i].h)
    let first = rects[idx[0]]
    let last = rects[idx[^1]]
    let span = if row: last.x + last.w - first.x else: last.y + last.h - first.y
    let g = if gap >= 0: gap.float else: max(0.0, (span - total).float / float(n - 1))
    var at = if row: first.x.float else: first.y.float
    var mid = 0.0
    for v in (if row: ys else: xs): mid += v
    mid /= n.float
    for i in idx:
      var r = rects[i]
      if row:
        r.x = int(round(at))
        r.y = int(round(mid - r.h.float / 2))
        at += r.w.float + g
      else:
        r.y = int(round(at))
        r.x = int(round(mid - r.w.float / 2))
        at += r.h.float + g
      result[i] = r
    return
  # a grid: as many columns as the boxes come nearest to, read along rows
  let cols = max(1, int(round(sqrt(n.float * spreadX / max(1.0, spreadY)))))
  idx.sort(proc (a, b: int): int =
    let ra = int(ys[a] / (hMax.float * 0.75))
    let rb = int(ys[b] / (hMax.float * 0.75))
    if ra != rb: cmp(ra, rb) else: cmp(xs[a], xs[b]))
  let g = if gap >= 0: gap.float else: max(4.0, min(wMax, hMax).float * 0.15)
  var x0 = 1 shl 30
  var y0 = 1 shl 30
  for r in rects:
    x0 = min(x0, r.x)
    y0 = min(y0, r.y)
  for k, i in idx:
    let c = k mod cols
    let rr = k div cols
    var r = rects[i]
    r.x = int(round(x0.float + c.float * (wMax.float + g) + float(wMax - r.w) / 2))
    r.y = int(round(y0.float + rr.float * (hMax.float + g) + float(hMax - r.h) / 2))
    result[i] = r

# ---- Flex Layout on a group ---------------------------------------------------------------------------

proc flexOf*(g: Layer): tuple[on: bool; box: FlexBox; x, y: float] =
  ## A group's Flex Layout (its `meta`): on, the box's settings, where its top left is.
  if g == nil or not g.group or g.meta.len == 0 or "\"flex\"" notin g.meta: return
  try:
    let j = parseJson(g.meta)
    let f = j{"flex"}
    if f == nil or f.kind != JObject: return
    result = (true, flexBoxFrom(f), f{"x"}.getFloat, f{"y"}.getFloat)
  except CatchableError: discard

proc setFlex*(g: Layer; box: FlexBox; x, y: float; on = true) =
  ## A group made a Flex Layout (or no longer, `on` false): its frames arranged in `box`, from
  ## `x`, `y`.
  var j = try: parseJson(g.meta) except CatchableError: newJObject()
  if j.kind != JObject: j = newJObject()
  if on:
    var f = box.toJson
    f["x"] = %x
    f["y"] = %y
    j["flex"] = f
  elif j.hasKey("flex"): j.delete("flex")
  g.meta = if j.len > 0: $j else: ""

proc flexChildren*(d: Doc; gi: int): seq[int] =
  ## The layers right inside group `gi`, as the Layers panel lists them (top first).
  let g = d.layers[gi]
  for j in countdown(gi - 1, d.blockStart(gi)):
    if d.layers[j].depth == g.depth + 1: result.add j

proc arrangeFlex*(d: Doc; gi: int): bool =
  ## Group `gi`'s frames put where its Flex Layout says (moved, not made bigger): true when one
  ## moved. (Undoable in a step: the caller's.)
  let g = d.layers[gi]
  let (on, box, ox, oy) = g.flexOf
  if not on: return
  let kids = d.flexChildren(gi)
  var items: seq[FlexItem]
  var boxes: seq[Rect]
  for j in kids:
    let r = d.layerBox(d.layers[j])
    boxes.add r
    items.add FlexItem(w: max(0, r.w).float, h: max(0, r.h).float)
  let laid = flexArrange(box, items)
  for k, j in kids:
    let r = boxes[k]
    if r.w <= 0 or r.h <= 0: continue
    let dx = int(round(ox + laid.rects[k].x)) - r.x
    let dy = int(round(oy + laid.rects[k].y)) - r.y
    if dx != 0 or dy != 0:
      d.shiftLayers(@[d.layers[j]], dx, dy)
      result = true

# ---- Symbols -------------------------------------------------------------------------------------------

proc symbolOf*(g: Layer): tuple[id: int; name: string] =
  ## The symbol a group is an instance of (its `meta`); id 0: none.
  if g == nil or not g.group or "\"symbol\"" notin g.meta: return
  try:
    let j = parseJson(g.meta){"symbol"}
    if j != nil and j.kind == JObject: result = (j{"id"}.getInt, j{"name"}.getStr)
  except CatchableError: discard

proc setSymbol(g: Layer; id: int; name: string) =
  var j = try: parseJson(g.meta) except CatchableError: newJObject()
  if j.kind != JObject: j = newJObject()
  if id > 0: j["symbol"] = %*{"id": id, "name": name}
  elif j.hasKey("symbol"): j.delete("symbol")
  g.meta = if j.len > 0: $j else: ""

proc symbols*(d: Doc): seq[tuple[id: int; name: string; instances: seq[int]]] =
  ## The document's symbols, each with its instances (their places in the layers, top first).
  for i in countdown(d.layers.high, 0):
    let (id, name) = d.layers[i].symbolOf
    if id == 0: continue
    var found = false
    for s in result.mitems:
      if s.id == id:
        s.instances.add i
        found = true
    if not found: result.add (id, name, @[i])

proc symbolInstances*(d: Doc; id: int): seq[int] =
  ## The instances of symbol `id` (their places in the layers, top first).
  for s in d.symbols:
    if s.id == id: return s.instances

proc makeSymbol*(d: Doc; idxs: seq[int]; name = ""): Layer =
  ## Create Symbol: the layers `idxs` (a group alone: it) made a symbol -- a group, its first instance.
  ## nil when they cannot be. (Undoable in a step: `touchLayers` first.)
  var nextId = 1
  for s in d.symbols: nextId = max(nextId, s.id + 1)
  var g: Layer
  if idxs.len == 1 and idxs[0] in 0 .. d.layers.high and d.layers[idxs[0]].group: g = d.layers[idxs[0]]
  else: g = d.groupLayers(idxs, if name.len > 0: name else: "Symbol " & $nextId)
  if g == nil: return nil
  g.setSymbol(nextId, if name.len > 0: name else: (if g.name.len > 0: g.name else: "Symbol " & $nextId))
  g

proc detachSymbol*(g: Layer) =
  ## Detach from Symbol: an instance made a plain group (what is in it no longer follows the others).
  g.setSymbol(0, "")

proc instanceParts(d: Doc; gi: int): seq[int] =
  ## (what is in an instance, bottom first)
  let g = d.layers[gi]
  for j in d.blockStart(gi) ..< gi:
    if d.layers[j].depth > g.depth: result.add j

proc instanceCorner(d: Doc; gi: int): (int, int) =
  ## (where an instance is: the top left of what is in it)
  var x0, y0 = high(int)
  for j in d.instanceParts(gi):
    let L = d.layers[j]
    if L.group: continue
    let b = d.layerBox(L)
    if b.w <= 0 or b.h <= 0: continue
    x0 = min(x0, b.x)
    y0 = min(y0, b.y)
  if x0 == high(int): (0, 0) else: (x0, y0)

proc partKey(d: Doc; L: Layer; ox, oy: int): Hash =
  ## (what a part of an instance is, wherever the instance is: its kind and content from the
  ## instance's corner)
  result = hash(L.name) !& hash(L.depth) !& hash(L.opacity) !& hash(ord(L.mode)) !& hash(L.visible)
  if L.isShape:
    var s = L.shape
    s.path = s.path.translated(-ox.float, -oy.float)
    result = result !& hash($s)
  elif L.isText:
    var t = L.text
    t.x -= ox.float32
    t.y -= oy.float32
    result = result !& hash($t)
  elif L.group: result = result !& hash("group")
  elif L.px.len == d.w * d.h:
    let b = d.layerBox(L)
    result = result !& hash(b.x - ox) !& hash(b.y - oy) !& hash(b.w) !& hash(b.h)
    for y in max(0, b.y) ..< min(d.h, b.y + b.h):
      for x in max(0, b.x) ..< min(d.w, b.x + b.w): result = result !& hash(L.px[y * d.w + x])
  result = !$result

proc instanceKey(d: Doc; gi: int): Hash =
  let (ox, oy) = d.instanceCorner(gi)
  for j in d.instanceParts(gi): result = result !& d.partKey(d.layers[j], ox, oy)
  result = !$result

proc copyInstance(d: Doc; src, dst: int) =
  ## (what is in instance `src` copied into instance `dst`, at `dst`'s corner)
  let (sx, sy) = d.instanceCorner(src)
  let (tx, ty) = d.instanceCorner(dst)
  let (dx, dy) = (tx - sx, ty - sy)
  let G = d.layers[dst]
  let keepCur = d.current
  let parts = d.instanceParts(src).mapIt(d.layers[it])
  let srcDepth = d.layers[src].depth
  # (its own parts out, copies of the source's in, under its group)
  let old = d.instanceParts(dst)
  for k in countdown(old.high, 0): d.layers.delete(old[k])
  var at = d.layers.find(G)
  var made: seq[Layer]
  for P in parts:
    let c = layerCopy(P, P.name)
    c.depth = G.depth + (P.depth - srcDepth)
    d.layers.insert(c, at)
    inc at
    made.add c
  for c in made:
    if dx == 0 and dy == 0: continue
    if c.isShape:
      var s = c.shape
      s.path = s.path.translated(dx.float, dy.float)
      d.setShape(c, s)
    elif c.isText:
      var t = c.text
      t.x += dx.float32
      t.y += dy.float32
      c.text = t
      d.drawText(c)
    elif not c.group: d.shiftLayers(@[c], dx, dy)
  d.cur = max(0, d.layers.find(keepCur))
  inc G.ver
  d.markAll()

proc keepSymbols*(d: Doc; seen: var Table[int, Hash]): bool =
  ## Each symbol's instances kept alike: when what is in one changed (not where it is: an instance
  ## moved is only moved), the others are made the same, each where it is. Not an undo step of its
  ## own -- undoing the change brings the others back with it. Call it when a step has ended (and
  ## after an undo or a redo); `seen` keeps what each symbol was. True when one was changed.
  if d.stepOpen: return
  for s in d.symbols:
    var keys: seq[Hash]
    for gi in s.instances: keys.add d.instanceKey(gi)
    let was = seen.getOrDefault(s.id, keys[0])
    var changed = -1
    var alike = true
    for k, key in keys:
      if key != keys[0]: alike = false
      if key != was and changed < 0: changed = k
    if alike or changed < 0:
      seen[s.id] = keys[0]
      continue
    # (the one changed made the others' content: the current one first, if it is one of those changed)
    for k, gi in s.instances:
      if keys[k] != was and d.cur in d.blockStart(gi) .. gi: changed = k
    let src = d.layers[s.instances[changed]]
    let target = keys[changed]
    for guard in 0 ..< 1000:
      # (one at a time, found again each time: a copy moves the layers' places)
      var did = false
      for gi in d.symbolInstances(s.id):
        let si = d.layers.find(src)
        if gi != si and d.instanceKey(gi) != target:
          d.copyInstance(si, gi)
          did = true
          break
      if not did: break
    seen[s.id] = keys[changed]
    result = true

proc insertSymbol*(d: Doc; id: int; dx = 24; dy = 24): Layer =
  ## A new instance of symbol `id`: a copy of its first instance (the lowest in the layers: the one
  ## made first), `dx`, `dy` from it, above it. (Undoable in a step: `touchLayers` first.)
  let ins = d.symbolInstances(id)
  if ins.len == 0: return nil
  let gi = ins[^1]
  let lo = d.blockStart(gi)
  var copies: seq[Layer]
  for j in lo .. gi: copies.add layerCopy(d.layers[j], d.layers[j].name)
  for c in countdown(copies.high, 0): d.layers.insert(copies[c], gi + 1)
  result = copies[^1]
  for c in copies:
    if c.isShape:
      var s = c.shape
      s.path = s.path.translated(dx.float, dy.float)
      d.setShape(c, s)
    elif c.isText:
      var t = c.text
      t.x += dx.float32
      t.y += dy.float32
      c.text = t
      d.drawText(c)
    elif not c.group: d.shiftLayers(@[c], dx, dy)
  d.cur = d.layers.find(result)
  d.markAll()

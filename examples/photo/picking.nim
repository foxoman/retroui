# (included by photo.nim) Several layers picked at once, shown and worked as the program a
# document is for shows them: a photo as the photo editor does (one box with handles round
# all the layers picked), a drawing as the drawing program does (each object's outline in its
# layer's color, with its anchor points, and one box round all), a layout as the layout
# program does (each frame's edge in its layer's color, and one box round all). Transformed
# together -- each layer as what it is: pixels warped, shapes carried sharp, type still type,
# Smart Objects from what they hold (retroui/photowarp: `LayerShot`) -- and picked by touch too
# (a long press on a layer begins it, then each tap adds or takes away).

type PickLook = enum
  plPhoto      ## a photo: Photoshop's way
  plDrawing    ## a drawing (SVG, AI, EPS): Illustrator's
  plLayout     ## a page of a book: InDesign's

var
  showLayerEdges = false            ## View > Show > Layer Edges: each picked layer outlined, any tool
  hoverLit: tuple[d: Doc; L: Layer] ## the layer under the pointer on the image (its row lit in Layers)
  rowLit: tuple[d: Doc; L: Layer]   ## the layer whose row the pointer is over (outlined on the image)
  touchPick = false                 ## picking several by taps (a long press on a layer began it)
  xfShots: seq[LayerShot]           ## several layers being transformed together, as they were
  boxCache: Table[pointer, tuple[lver, dver: int; r: Rect]]   ## (layers' boxes, while they are the same)

proc pickLook(dw: DocWin): PickLook =
  ## Which program's way the document shows what is picked.
  if dw == nil: return plPhoto
  if dw.isBookWin: return plLayout
  if dw.doc.format in ["svg", "ai", "eps"]: return plDrawing
  plPhoto

proc boxOf(d: Doc; L: Layer): Rect =
  ## A layer's box (`layerBox`), kept while it and the image are the same:
  ## a layer of pixels is looked through to find it.
  let k = cast[pointer](L)
  let c = boxCache.getOrDefault(k, (-1, -1, rect(0, 0, 0, 0)))
  if c.lver == L.ver and c.dver == d.ver: return c.r
  if boxCache.len > 256: boxCache.clear()
  # (a group: all it holds -- its box and handles as for a layer)
  result = if L.group: d.blockBox(d.layers.find(L)) else: d.layerBox(L)
  boxCache[k] = (L.ver, d.ver, result)

proc severalPicked(d: Doc): bool = d != nil and d.pickedLayers.len > 1
  ## More than the current layer is picked.

proc transformLayersOf(d: Doc): seq[Layer] =
  ## What a move or a transform of the picked layers changes: each picked,
  ## the layers in a group picked, those linked to them.
  for i in d.movedLayers:
    let L = d.layers[i]
    if L.group:
      for j in d.blockStart(i) ..< i:
        if not d.layers[j].group and d.layers[j] notin result: result.add d.layers[j]
    elif L notin result: result.add L

proc pickedBox(d: Doc): Rect =
  ## The box round all the layers picked (what Show Transform Controls
  ## shows, and Free Transform holds).
  for L in d.transformLayersOf:
    if L.background or L.adjust.kind.len > 0: continue
    let b = d.boxOf(L)
    if b.w > 0 and b.h > 0: result = if result.w > 0: union(result, b) else: b

proc moveBoxOf(d: Doc): Rect =
  ## The Move tool's box: the selection's, all the picked layers', or the
  ## current layer's.
  if d.hasSelection: d.clip(d.selBounds)
  elif d.severalPicked: d.pickedBox
  else: d.boxOf(d.current)

proc colorOfLabel(c: uint32): Color =
  ## (a layer's color, 0xAARRGGBB, to draw with)
  color(uint8((c shr 16) and 255), uint8((c shr 8) and 255), uint8(c and 255))

proc boxColorOf(dw: DocWin): Color =
  ## The box's color: the photo editor's blue; the drawing and layout
  ## programs draw it in the current layer's color.
  if dw.pickLook == plPhoto: return XfBlue
  colorOfLabel(dw.doc.labelColorOf(dw.doc.cur))

proc outlineLayer(dw: DocWin; i: int; c: Color; points: bool) =
  ## Layer `i`'s edge on the screen in `c`: a shape's own outline (with its
  ## anchor points, `points`), a Smart Object's corners, else its box.
  let d = dw.doc
  let v = dw.view
  let L = d.layers[i]
  if L.isShape and not L.isFill:
    for poly in L.shape.path.flatten(12):
      for k in 1 ..< poly.len:
        let (a, b) = v.toScreen(d, poly[k - 1][0], poly[k - 1][1])
        let (e, f) = v.toScreen(d, poly[k][0], poly[k][1])
        line(a, b, e, f, c)
    if points:
      for sp in L.shape.path.subs:
        for q in sp.pts:
          let (a, b) = v.toScreen(d, q.p[0], q.p[1])
          fill(rect(a - 2, b - 2, 5, 5), c)
    return
  if L.isSmart:
    var pts: array[4, (int, int)]
    for k in 0 .. 3: pts[k] = v.toScreen(d, L.smart.quad[k][0], L.smart.quad[k][1])
    for k in 0 .. 3: line(pts[k][0], pts[k][1], pts[(k + 1) mod 4][0], pts[(k + 1) mod 4][1], c)
    return
  let b = if L.group: d.blockBox(i) else: d.boxOf(L)
  if b.w <= 0 or b.h <= 0: return
  let (x0, y0) = v.toScreen(d, b.x.float, b.y.float)
  let (x1, y1) = v.toScreen(d, (b.x + b.w).float, (b.y + b.h).float)
  box(rect(x0, y0, max(1, x1 - x0), max(1, y1 - y0)), c)

proc drawPicked(dw: DocWin) =
  ## What is picked, on the image (the Move tool): in a drawing each
  ## object's outline and anchor points, in a layout each frame's edge --
  ## in its layer's color; a photo marks none of them (its box does), but
  ## with Layer Edges on.
  let d = dw.doc
  let look = dw.pickLook
  if look == plPhoto or dw.view.hideEdges: return
  if d.hasSelection or d.editMask or d.quickMask: return
  for i in d.pickedLayers:
    if d.layers[i].background: continue
    dw.outlineLayer(i, colorOfLabel(d.labelColorOf(i)), look == plDrawing)

proc layerEdgesOverlay(dw: DocWin) =
  ## View > Show > Layer Edges: each picked layer's edge, with any tool (as
  ## the photo editor shows it, in blue); the layer whose row the pointer is
  ## over in Layers, too.
  let d = dw.doc
  if showLayerEdges and not dw.view.hideEdges:
    for i in d.pickedLayers:
      if not d.layers[i].background: dw.outlineLayer(i, XfBlue, false)
  if rowLit.d == d and rowLit.L != nil:
    let i = d.layers.find(rowLit.L)
    if i >= 0 and not rowLit.L.background: dw.outlineLayer(i, XfBlue, false)

proc bandTouches(d: Doc; r: Rect): seq[int] =
  ## The layers a box dragged with the Move tool picks: those it touches
  ## (shown, not the Background, not locked, not a master page's).
  for i, L in d.layers:
    if L.background or L.group or not L.visible or L.fromMaster != 0 or L.locked: continue
    let b = d.boxOf(L)
    if b.w > 0 and b.h > 0 and b.x < r.x + r.w and b.x + b.w > r.x and b.y < r.y + r.h and b.y + b.h > r.y:
      result.add i

proc bandRect(): Rect =
  let x0 = int(floor(min(drag.x0, drag.x1)))
  let y0 = int(floor(min(drag.y0, drag.y1)))
  rect(x0, y0, int(ceil(max(drag.x0, drag.x1))) - x0, int(ceil(max(drag.y0, drag.y1))) - y0)

proc bandOverlay(dw: DocWin) =
  ## (while the box is dragged: what it would pick, outlined at once)
  let d = dw.doc
  let r = bandRect()
  if r.w < 3 and r.h < 3: return
  let look = dw.pickLook
  for i in d.bandTouches(r):
    dw.outlineLayer(i, (if look == plPhoto: XfBlue else: colorOfLabel(d.labelColorOf(i))), look == plDrawing)

proc togglePick(d: Doc; i: int) =
  ## Layer `i` picked with the others, or taken out of them (Shift+click on
  ## the image, a tap while picking by touch): the current layer taken out,
  ## another picked one becomes current.
  if i < 0 or i >= d.layers.len: return
  if i == d.cur:
    let others = d.pickedLayers.filterIt(it != i)
    if others.len == 0: return
    d.layers[i].picked = false
    d.cur = others[0]
    d.layers[d.cur].picked = others.len > 1
    if others.len == 1: d.clearPicks()
  elif d.layers[i].picked:
    d.layers[i].picked = false
    if d.pickedLayers.len <= 1: d.clearPicks()
  else:
    d.current.picked = true
    d.layers[i].picked = true
    d.cur = i
  # (not `inc d.ver`: what is picked is no change of the image -- a book would take it for one)
  ui.redraw = true

proc startTransformMany(kind: XfKind): bool =
  ## Free Transform (and Scale, Rotate, Skew, Distort, Perspective) with
  ## several layers picked: one box round them all, each changed as what it
  ## is, one step. False when fewer than two are to be changed (the usual
  ## transform of one).
  let dw = active
  if dw == nil: return false
  let d = dw.doc
  let ls = d.transformLayersOf
  if ls.len < 2: return false
  let shots = d.shotsOf(ls)
  if shots.len == 0:
    status = "None of the layers picked can be transformed (locked, an adjustment, or empty)"
    return true
  let r = shotsBox(shots)
  if r.w <= 0 or r.h <= 0: return true
  d.beginStep($kind)
  d.touchLayers()
  for s in shots:
    if s.kind != skPixels: d.touch(s.layer, d.bounds)   # (their pixels as they were: Undo, Esc)
  xfShots = shots
  xfSmart = nil
  xfText.on = false
  xf = (true, dw, kind, d.current, r, newSeq[uint32](), newSeq[uint8](), false, quadOf(r), quadOf(r), -1,
        (0.0, 0.0), 0'u32, ShapeData(), newSeq[uint32]())
  d.setLive(d.liveShots(shots, r, xf.quad))
  status = tr($kind) & " (" & $shots.len & tr(" layers together)") &
           tr(": drag the corners; Enter or a double-click inside to finish, Esc to cancel")
  true

proc xfApplyMany() =
  ## (the corners moved: the shapes, type and Smart Objects carried, the
  ## pixels shown stretched)
  let d = xf.dw.doc
  d.carryShots(xfShots, xf.r, xf.quad, proc (L: Layer) = d.renderSmartLayer(L), prefs.scaleStrokes)
  d.setLive(d.liveShots(xfShots, xf.r, xf.quad))

proc putDownMany() =
  ## (finished: the pixel layers warped into place at full size)
  let d = xf.dw.doc
  d.endLive()
  beginBusy("Transforming")
  try: d.putDownShots(xfShots, xf.r, xf.quad)
  finally: endBusy()

proc startTouchPick(d: Doc) =
  ## Picking several by taps (a phone, a tablet: no Shift to hold): each tap
  ## on a layer -- its row, or what it holds on the image -- adds it or takes
  ## it out, until Done.
  touchPick = true
  if d != nil: d.current.picked = d.severalPicked
  status = "Tap the layers to pick, here or on the image; tap Done when they are all picked"

proc endTouchPick() =
  touchPick = false
  status = ""

proc pickedLayersOf(d: Doc): seq[Layer] =
  ## (what a setting of the Layers panel goes to: every layer picked, the
  ## current one too -- not the Background)
  for i in d.pickedLayers:
    if not d.layers[i].background or d.pickedLayers.len == 1: result.add d.layers[i]

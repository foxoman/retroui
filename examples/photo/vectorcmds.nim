# (included by photo.nim) Type > Convert to Shape (the type layer made shape
# layers: its letters outlines of curves, with retroui/photovector's
# textShapes) and Layer > Path Operations > Make Blend (the shapes between
# two shape layers: blendShapes).

var
  blendDlg = false
  blendSpacing = 0          ## 0 Smooth Color, 1 Specified Steps
  blendSteps = 6
  blendPair: (Layer, Layer)
  blendEase = 0             ## the steps' spacing (`BlendEase`)
  blendColorEase = 0        ## the colors'
  blendStrength = 50        ## how much, %

proc convertTypeToShape() =
  ## Type > Convert to Shape: the current type layer made shape layers --
  ## one a color, in a group named as the layer when there are more -- its
  ## opacity, mode, style and mask kept; one step.
  let d = cur()
  if d == nil or not d.current.isText: return
  if te.on: commitType()
  let T = d.current
  if T.locked or T.fromMaster != 0 or T.fromSpan != 0:
    status = "The type layer is locked."
    return
  let shapes = textShapes(T.text)
  if shapes.len == 0:
    status = "Nothing to convert: the type layer says nothing."
    return
  d.beginStep("Convert to Shape")
  d.touchLayers()
  var at = d.layers.find(T)
  var idxs: seq[int]
  for k, s in shapes:
    let L = d.addShapeLayer(s, (if shapes.len == 1: T.name else: T.name & " " & $(k + 1)), above = at)
    at = d.layers.find(L)
    idxs.add at
  var top = d.layers[at]
  if shapes.len > 1:
    let g = d.groupLayers(idxs, T.name)
    if g != nil: top = g
  top.opacity = T.opacity
  top.mode = T.mode
  top.fx = T.fx
  top.clipped = T.clipped
  top.mask = if T.mask != nil: cloneLayer(T.mask) else: nil   # (its own: the type layer's stays with undo)
  top.maskOff = T.maskOff
  top.link = T.link
  top.wrap = T.wrap
  top.wrapGap = T.wrapGap
  if not top.group: top.fill = T.fill
  d.deleteLayer(d.layers.find(T))
  d.cur = d.layers.find(top)
  d.endStep()
  d.markAll()
  var pts = 0
  for s in shapes:
    for sp in s.path.subs: pts += sp.pts.len
  status = "Converted to shape: " & $shapes.len & (if shapes.len == 1: " shape, " else: " shapes, ") &
           $pts & " points"

var blendSeen: Table[pointer, int]   # (each live blend's ends as they were when its steps were made)

proc blendParts(d: Doc; g: Layer): tuple[ends, steps: seq[Layer]] =
  ## (a live blend group's two ends, the lower first, and its steps)
  let gi = d.layers.find(g)
  for i in countdown(gi - 1, 0):
    let M = d.layers[i]
    if M.depth <= g.depth: break
    if M.depth != g.depth + 1: continue
    if M.meta == BlendStepMeta: result.steps.add M
    elif M.isShape: result.ends.insert(M, 0)

proc keepLiveBlends(d: Doc) =
  ## Live blends (Make Blend's groups, Affinity's way): when an end's shape, color or opacity
  ## changed, the steps between are made again -- not an undo step of their own, so undoing the
  ## change brings the ends back and the steps follow them again.
  if d.stepOpen: return
  for g in d.layers:
    if not g.group or not g.meta.startsWith("{\"blend\""): continue
    let (ends, steps) = d.blendParts(g)
    if ends.len != 2: continue
    let sig = (ends[0].ver * 31 + ends[1].ver) * 31 + hash(g.meta) + ends[0].opacity * 7 + ends[1].opacity
    let key = cast[pointer](g)
    if not blendSeen.hasKey(key):
      blendSeen[key] = sig                 # (as made: nothing to do the first time it is seen)
      continue
    if blendSeen[key] == sig: continue
    blendSeen[key] = sig
    let j = try: parseJson(g.meta){"blend"} except CatchableError: nil
    if j == nil: continue
    let (lo, hi) = (ends[0], ends[1])
    let n = if j{"smooth"}.getBool: colorSteps(lo.shape, hi.shape) else: max(1, j{"n"}.getInt(6))
    let made = blendShapes(lo.shape, hi.shape, n, BlendEase(j{"ease"}.getInt), j{"strength"}.getInt(50) / 100,
                           BlendEase(j{"colorEase"}.getInt), j{"strength"}.getInt(50) / 100)
    let keepCur = d.current
    for S in steps:
      let k = d.layers.find(S)
      if k >= 0: d.deleteLayer(k)
    var at = d.layers.find(lo)
    for k, s in made:
      let L = d.addShapeLayer(s, "Blend " & $(k + 1), above = at)
      L.meta = BlendStepMeta
      L.opacity = lo.opacity + (hi.opacity - lo.opacity) * (k + 1) div (n + 1)
      at = d.layers.find(L)
    d.cur = max(0, d.layers.find(keepCur))
    blendSeen[key] = (ends[0].ver * 31 + ends[1].ver) * 31 + hash(g.meta) + ends[0].opacity * 7 + ends[1].opacity
    d.markAll()

proc expandBlend(d: Doc) =
  ## Expand Blend: the live blend picked made plain shapes -- its steps are kept as they are and no
  ## longer follow its ends.
  var g = d.current
  while g != nil and not (g.group and g.meta.startsWith("{\"blend\"")):
    let i = d.layers.find(g)
    var up: Layer = nil
    for k in i + 1 ..< d.layers.len:
      if d.layers[k].depth < g.depth:
        up = d.layers[k]
        break
    g = up
  if g == nil:
    status = "Expand Blend: pick a blend (its group, or a shape in it)"
    return
  d.layersChange("Expand Blend"):
    let (_, steps) = d.blendParts(g)
    for S in steps: S.meta = ""
    g.meta = ""
  status = "Blend expanded: its steps are shapes of their own"

proc blendLayers(d: Doc): (Layer, Layer) =
  ## (the two shape layers to blend: those picked, else the current one and the shape layer
  ## under it)
  var two: seq[Layer]
  for i in d.pickedLayers:
    if d.layers[i].isShape: two.add d.layers[i]
  if two.len == 2: return (two[0], two[1])
  let c = d.cur
  if c >= 0 and c < d.layers.len and d.layers[c].isShape:
    for i in countdown(c - 1, 0):
      if d.layers[i].isShape and d.layers[i].depth == d.layers[c].depth: return (d.layers[i], d.layers[c])
      if d.layers[i].depth < d.layers[c].depth: break

proc startMakeBlend() =
  let d = cur()
  if d == nil: return
  blendPair = blendLayers(d)
  if blendPair[0] == nil:
    status = "Make Blend: pick two shape layers (Ctrl+click in the Layers palette)."
    return
  blendDlg = true

proc makeBlend() =
  let d = cur()
  if d == nil: return
  let (a, b) = blendPair
  let ia = d.layers.find(a)
  let ib = d.layers.find(b)
  if ia < 0 or ib < 0: return
  let n = if blendSpacing == 0: colorSteps(a.shape, b.shape) else: blendSteps
  let made = blendShapes(a.shape, b.shape, n, BlendEase(blendEase), blendStrength / 100,
                         BlendEase(blendColorEase), blendStrength / 100)
  d.beginStep("Make Blend")
  d.touchLayers()
  # (the steps between the two in the stack, from the lower one up; the two and they in a group)
  let lo = min(ia, ib)
  let lower = d.layers[lo]
  var ordered = made
  if lower != a: ordered.reverse()
  var at = lo
  var idxs = @[lo]
  for k, s in ordered:
    let L = d.addShapeLayer(s, "Blend " & $(k + 1), above = at)
    L.opacity = (if lower == a: a.opacity + (b.opacity - a.opacity) * (k + 1) div (n + 1)
                 else: b.opacity + (a.opacity - b.opacity) * (k + 1) div (n + 1))
    at = d.layers.find(L)
    idxs.add at
  idxs.add d.layers.find(if lower == a: b else: a)
  for i in idxs[1 ..< ^1]: d.layers[i].meta = BlendStepMeta
  let g = d.groupLayers(idxs, "Blend")
  if g != nil:
    # (live: its settings kept on the group, the steps made again when either end changes)
    g.meta = $(%*{"blend": {"smooth": blendSpacing == 0, "n": blendSteps, "ease": blendEase,
                            "colorEase": blendColorEase, "strength": blendStrength}})
    d.cur = d.layers.find(g)
  d.endStep()
  d.markAll()
  status = "Blend: " & $n & (if n == 1: " step" else: " steps") & " between the two, in the group \"Blend\" " &
           "-- live: change either end and the steps follow (Expand Blend: shapes of their own)"

proc replaceSpine(orient: bool) =
  ## Blend > Replace Spine: a blend (its group) and a path picked -- the blend's shapes along the
  ## path, as the drawing program has it; the path goes into it (Align to Path: each turned with it).
  let d = cur()
  if d == nil: return
  var blendG: Layer = nil
  var spineL: Layer = nil
  for i in d.pickedLayers & @[d.cur]:
    if i < 0 or i >= d.layers.len: continue
    let L = d.layers[i]
    if L.group and blendG == nil: blendG = L
    elif L.isShape and spineL == nil: spineL = L
  if blendG == nil or spineL == nil:
    status = "Replace Spine: pick a blend (its group) and a path (Ctrl+click both in the Layers palette)."
    return
  let gi = d.layers.find(blendG)
  var members: seq[Layer]
  for i in countdown(gi - 1, 0):
    let M = d.layers[i]
    if M.depth <= blendG.depth: break
    if M.isShape and M != spineL: members.add M
  if members.len < 2:
    status = "Replace Spine: the group picked holds no blend (Make Blend makes one)."
    return
  members.reverse()                      # (bottom first: the blend's order)
  var shapes: seq[ShapeData]
  for M in members: shapes.add M.shape
  let moved = alongSpine(shapes, spineL.shape.path, orient)
  d.beginStep("Replace Spine")
  d.touchLayers()
  for k, M in members: d.setShape(M, moved[k])
  let si = d.layers.find(spineL)
  if si >= 0: d.deleteLayer(si)
  d.cur = d.layers.find(blendG)
  d.endStep()
  d.markAll()
  status = "Replace Spine: the blend follows the path (" & $members.len & " shapes)"

proc makeBlendDialog() =
  if not blendDlg: return
  var ok = false
  dialog(blendDlg, "Blend Options", 320):
    row:
      label "Spacing:"
      discard combo(["Smooth Color", "Specified Steps"], blendSpacing, w = dp(150))
    if blendSpacing == 1:
      row:
        label "Steps:"
        discard spin(blendSteps, 1, 1000, w = dp(70))
    else:
      let d = cur()
      if d != nil and blendPair[0] != nil:
        label($colorSteps(blendPair[0].shape, blendPair[1].shape) & " steps, as many as the colors need",
              color = ui.theme.gray)
    row:
      label "Steps:"
      discard combo(["Even", "Ease In", "Ease Out", "Ease In and Out"], blendEase, w = dp(150))
    row:
      label "Colors:"
      discard combo(["Even", "Ease In", "Ease Out", "Ease In and Out"], blendColorEase, w = dp(150))
    if blendEase != 0 or blendColorEase != 0:
      row([90, -1, 40]):
        label "Strength:"
        discard slider(blendStrength, 0, 100, ticks = 0)
        label $blendStrength & "%"
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): blendDlg = false
  if ok:
    blendDlg = false
    makeBlend()

# ---- Shape Builder ------------------------------------------------------------------------------------------

var
  sbDlg: tuple[open: bool; layers: seq[Layer]; merge, remove: seq[(float, float)]; removing: bool;
               key: string; pic: Bitmap; k: float; box: Rect]

proc scaledShape(s: ShapeData; k, ox, oy: float): ShapeData =
  result = s
  for sp in result.path.subs.mitems:
    for q in sp.pts.mitems:
      q.p = ((q.p[0] - ox) * k, (q.p[1] - oy) * k)
      q.inH = ((q.inH[0] - ox) * k, (q.inH[1] - oy) * k)
      q.outH = ((q.outH[0] - ox) * k, (q.outH[1] - oy) * k)

proc startShapeBuilder() =
  let d = cur()
  if d == nil: return
  var ls: seq[Layer]
  for i in d.pickedLayers:
    if d.layers[i].isShape and not d.layers[i].locked: ls.add d.layers[i]
  if ls.len < 2:
    status = "Shape Builder: pick two or more shape layers (Ctrl+click in the Layers palette)."
    return
  var x0, y0 = Inf
  var x1, y1 = -Inf
  for L in ls:
    let (a, b, c, e) = pathBounds(L.shape.path)
    x0 = min(x0, a); y0 = min(y0, b); x1 = max(x1, c); y1 = max(y1, e)
  sbDlg = (true, ls, @[], @[], false, "", nil, 1.0,
           rect(int(floor(x0)) - 2, int(floor(y0)) - 2, int(ceil(x1 - x0)) + 4, int(ceil(y1 - y0)) + 4))

proc sbShapes(k: float): seq[ShapeData] =
  for L in sbDlg.layers: result.add scaledShape(L.shape, k, sbDlg.box.x.float, sbDlg.box.y.float)

proc shapeBuilderOn(d: Doc; layers: seq[Layer]; merge, remove: seq[(float, float)]; box: Rect) =
  ## (Shape Builder: the regions under `merge` made one shape, those under `remove` gone, each of
  ## `layers` what is left of it -- one step)
  sbDlg.layers = layers
  sbDlg.merge = merge
  sbDlg.remove = remove
  sbDlg.box = box
  let b = sbDlg.box
  let shapes = sbShapes(1.0)
  var mg, rm: seq[(float, float)]
  for p in sbDlg.merge: mg.add (p[0] - b.x.float, p[1] - b.y.float)
  for p in sbDlg.remove: rm.add (p[0] - b.x.float, p[1] - b.y.float)
  var r: tuple[merged: Path; rest: seq[Path]]
  beginBusy("Shape Builder")
  try: r = buildShapes(shapes, b.w, b.h, mg, rm)
  finally: endBusy()
  proc back(p: Path): Path =
    result = p
    for sp in result.subs.mitems:
      for q in sp.pts.mitems:
        q.p = (q.p[0] + b.x.float, q.p[1] + b.y.float)
        q.inH = (q.inH[0] + b.x.float, q.inH[1] + b.y.float)
        q.outH = (q.outH[0] + b.x.float, q.outH[1] + b.y.float)
  d.beginStep("Shape Builder")
  d.touchLayers()
  var top = -1
  for L in sbDlg.layers: top = max(top, d.layers.find(L))
  if r.merged.subs.len > 0:
    # (the merged shape in the look of the first shape that had a merged region)
    var look = sbDlg.layers[0].shape
    let regs = shapeRegions(shapes, b.w, b.h)
    for (x, y) in mg:
      let key = regs[clamp(int(y), 0, b.h - 1) * b.w + clamp(int(x), 0, b.w - 1)]
      for i in countdown(min(63, sbDlg.layers.high), 0):
        if (key and (1'u64 shl i)) != 0:
          look = sbDlg.layers[i].shape
          break
      break
    look.path = back(r.merged)
    look.kind = ""
    let M = d.addShapeLayer(look, "Built Shape", above = top)
    d.cur = d.layers.find(M)
  for i, L in sbDlg.layers:
    if i >= r.rest.len: break
    if r.rest[i].subs.len == 0:
      let j = d.layers.find(L)
      if j >= 0: d.deleteLayer(j)
    else:
      var s = L.shape
      s.path = back(r.rest[i])
      s.kind = ""
      d.setShape(L, s)
  d.endStep()
  d.markAll()

proc shapeBuilderNow() =
  ## (the dialog's regions picked made one shape, those taken away gone)
  let d = cur()
  if d == nil or sbDlg.merge.len == 0 and sbDlg.remove.len == 0: return
  d.shapeBuilderOn(sbDlg.layers, sbDlg.merge, sbDlg.remove, sbDlg.box)
  status = "Shape Builder: " & $sbDlg.merge.len & " regions merged, " & $sbDlg.remove.len & " taken away"

proc shapeBuilderDrag(d: Doc; pts: seq[(float, float)]; remove: bool): bool =
  ## The Shape Builder Tool, as the drawing program has it: a drag across the regions of the
  ## shapes picked (or of those it goes over) makes them one shape; with Alt, takes them away.
  var picked: seq[Layer]
  for i in d.pickedLayers:
    if d.layers[i].isShape and not d.layers[i].locked and d.layers[i].visible: picked.add d.layers[i]
  var ls = if picked.len >= 2: picked else: @[]
  if picked.len < 2:
    # (none picked: the filled shapes under the drag)
    for L in d.layers:
      if not L.isShape or not L.visible or L.locked or L.shape.fill.kind == spNone: continue
      let (a, b, c, e) = pathBounds(L.shape.path)
      for p in pts:
        if p[0] >= a and p[0] <= c and p[1] >= b and p[1] <= e:
          ls.add L
          break
  if ls.len < 1 or pts.len == 0: return false
  var x0, y0 = Inf
  var x1, y1 = -Inf
  for L in ls:
    let (a, b, c, e) = pathBounds(L.shape.path)
    x0 = min(x0, a); y0 = min(y0, b); x1 = max(x1, c); y1 = max(y1, e)
  let box = rect(int(floor(x0)) - 2, int(floor(y0)) - 2, int(ceil(x1 - x0)) + 4, int(ceil(y1 - y0)) + 4)
  # (the drag's points a pixel or so apart: each region it crossed)
  var along: seq[(float, float)]
  for i, p in pts:
    if i == 0:
      along.add p
      continue
    let q = pts[i - 1]
    let n = max(1, int(hypot(p[0] - q[0], p[1] - q[1])))
    for k in 1 .. n: along.add (q[0] + (p[0] - q[0]) * k.float / n.float, q[1] + (p[1] - q[1]) * k.float / n.float)
  if remove: d.shapeBuilderOn(ls, @[], along, box) else: d.shapeBuilderOn(ls, along, @[], box)
  true

proc shapeBuilderDialog() =
  if not sbDlg.open: return
  let d = cur()
  if d == nil:
    sbDlg.open = false
    return
  var ok = false
  dialog(sbDlg.open, "Shape Builder", 560):
    label("Click the parts to make one shape; with Remove on (or Alt), the parts to take away.",
          color = ui.theme.gray)
    row:
      checkbox("Remove", sbDlg.removing)
      if button("Clear", w = dp(70)):
        sbDlg.merge.setLen(0)
        sbDlg.remove.setLen(0)
    let pr = place(dp(520), dp(360))
    let k = min(pr.w / sbDlg.box.w, pr.h / sbDlg.box.h)
    let pw = max(1, int(sbDlg.box.w.float * k))
    let ph = max(1, int(sbDlg.box.h.float * k))
    let key = $sbDlg.merge & $sbDlg.remove & $pw
    if key != sbDlg.key:
      # (each region a color: those merged blue, those taken away red, the others light)
      sbDlg.key = key
      sbDlg.k = k
      let regs = shapeRegions(sbShapes(k), pw, ph)
      var mk, rk: seq[uint64]
      for p in sbDlg.merge:
        let x = int((p[0] - sbDlg.box.x.float) * k)
        let y = int((p[1] - sbDlg.box.y.float) * k)
        if x in 0 ..< pw and y in 0 ..< ph: mk.add regs[y * pw + x]
      for p in sbDlg.remove:
        let x = int((p[0] - sbDlg.box.x.float) * k)
        let y = int((p[1] - sbDlg.box.y.float) * k)
        if x in 0 ..< pw and y in 0 ..< ph: rk.add regs[y * pw + x]
      var pic = newBitmap(pw, ph)
      for i, r in regs:
        pic.px[i] = if r == 0: 0xFFFFFFFF'u32
                    elif r in mk: 0xFF3A86FF'u32
                    elif r in rk: 0xFFE63946'u32
                    else: 0xFFD8D8D8'u32 - uint32((r * 0x9E3779B1'u64) and 0x1F1F1F'u64)
      # (the regions' edges)
      for y in 0 ..< ph:
        for x in 0 ..< pw:
          let r = regs[y * pw + x]
          if (x + 1 < pw and regs[y * pw + x + 1] != r) or (y + 1 < ph and regs[(y + 1) * pw + x] != r):
            pic.px[y * pw + x] = 0xFF333333'u32
      sbDlg.pic = pic
    let r0 = rect(pr.x + (pr.w - pw) div 2, pr.y + (pr.h - ph) div 2, pw, ph)
    if sbDlg.pic != nil: drawBitmap(r0, sbDlg.pic)
    box(pr, ui.theme.edge)
    let hit = interact(idOf("sbcanvas"), r0, focusable = false)
    if hit.clicked:
      let p = (sbDlg.box.x.float + (ui.mx - r0.x).float / k, sbDlg.box.y.float + (ui.my - r0.y).float / k)
      if sbDlg.removing or AltPressed in ui.mods: sbDlg.remove.add p else: sbDlg.merge.add p
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80), enabled = sbDlg.merge.len + sbDlg.remove.len > 0): ok = true
      if button("Cancel", w = dp(80)): sbDlg.open = false
  if ok:
    sbDlg.open = false
    shapeBuilderNow()

# ---- Freeform Gradient ---------------------------------------------------------------------------------------

var
  ffDlg: tuple[open: bool; layer: Layer; pts: seq[tuple[x, y: float; color: uint32]]; sel: int; was: ShapeData;
               diffuse: bool]
  ffPending = false
  ffApplied = ""                 ## (the points last put on the shape)

proc startFreeform() =
  let d = cur()
  if d == nil or not d.current.isShape:
    status = "Freeform Gradient: pick a shape layer."
    return
  let L = d.current
  var pts = L.shape.fill.points
  if pts.len == 0 or L.shape.fill.style != 5:
    let c = if L.shape.fill.kind == spColor: L.shape.fill.color else: 0xFF3A86FF'u32
    pts = @[(0.2, 0.2, c), (0.8, 0.3, fg or 0xFF000000'u32), (0.5, 0.85, bg or 0xFF000000'u32)]
  ffDlg = (true, L, pts, 0, L.shape, L.shape.fill.style == 5 and L.shape.fill.diffuse)
  ffApplied = $pts & $ffDlg.diffuse
  d.beginStep("Freeform Gradient")
  d.touchLayers()
  d.touch(L, d.bounds)
  ffPending = true

proc freeformDialog() =
  let d = cur()
  if not ffDlg.open:
    if ffPending:
      ffPending = false
      if d != nil and d.stepOpen:
        d.cancelStep()
        d.markAll()
    return
  if d == nil or d.layers.find(ffDlg.layer) < 0:
    ffDlg.open = false
    return
  let L = ffDlg.layer
  let before = ffDlg.pts
  var ok, cancel = false
  dialog(ffDlg.open, "Freeform Gradient", 420):
    label("Click to add a color point (the foreground color); a point: pick it, then its color.",
          color = ui.theme.gray)
    row:
      label "Method:"
      var m = ord(ffDlg.diffuse)
      combo(["Points (each color strongest round its point)", "Diffusion (spread smoothly, as heat)"], m,
            w = dp(300))
      ffDlg.diffuse = m == 1
    let pr = place(dp(380), dp(260))
    let (x0, y0, x1, y1) = pathBounds(L.shape.path)
    fill(pr, color(240, 240, 240))
    # (the gradient as it is, small)
    let k = min(pr.w.float / max(1.0, x1 - x0), pr.h.float / max(1.0, y1 - y0))
    let gw = max(1, int((x1 - x0) * k))
    let gh = max(1, int((y1 - y0) * k))
    let gr = rect(pr.x + (pr.w - gw) div 2, pr.y + (pr.h - gh) div 2, gw, gh)
    let step = max(4, dp(6))
    var yy = 0
    while yy < gh:
      var xx = 0
      while xx < gw:
        let (u, v) = ((xx.float + 0.5) / gw.float, (yy.float + 0.5) / gh.float)
        let c = if ffDlg.diffuse: freeformDiffusedAt(ffDlg.pts, u, v) else: freeformAt(ffDlg.pts, u, v)
        fill(rect(gr.x + xx, gr.y + yy, min(step, gw - xx), min(step, gh - yy)),
             color(uint8((c shr 16) and 255), uint8((c shr 8) and 255), uint8(c and 255)))
        xx += step
      yy += step
    box(gr, ui.theme.edge)
    for i, p in ffDlg.pts:
      let cx = gr.x + int(p.x * gw.float)
      let cy = gr.y + int(p.y * gh.float)
      let r = rect(cx - dp(5), cy - dp(5), dp(10), dp(10))
      fill(r, color(uint8((p.color shr 16) and 255), uint8((p.color shr 8) and 255), uint8(p.color and 255)))
      box(r, if i == ffDlg.sel: ui.theme.select else: color(0, 0, 0), (if i == ffDlg.sel: 2 else: 1))
    let hit = interact(idOf("ffcanvas"), gr, focusable = false)
    if hit.clicked:
      let u = (ui.mx - gr.x).float / gw.float
      let v = (ui.my - gr.y).float / gh.float
      var near = -1
      for i, p in ffDlg.pts:
        if abs(p.x - u) * gw.float < dp(8).float and abs(p.y - v) * gh.float < dp(8).float: near = i
      if near >= 0: ffDlg.sel = near
      elif ffDlg.pts.len < 32:
        ffDlg.pts.add (clamp(u, 0.0, 1.0), clamp(v, 0.0, 1.0), fg or 0xFF000000'u32)
        ffDlg.sel = ffDlg.pts.high
    if ffDlg.sel in 0 .. ffDlg.pts.high:
      row:
        label "Point " & $(ffDlg.sel + 1) & ":"
        var c = ffDlg.pts[ffDlg.sel].color
        if colorWell(c, "ffpoint", dp(40)): ffDlg.pts[ffDlg.sel].color = c or 0xFF000000'u32
        var xi = int(round(ffDlg.pts[ffDlg.sel].x * 100))
        var yi = int(round(ffDlg.pts[ffDlg.sel].y * 100))
        label "Across:"
        if spin(xi, 0, 100, w = dp(56)): ffDlg.pts[ffDlg.sel].x = xi / 100
        label "Down:"
        if spin(yi, 0, 100, w = dp(56)): ffDlg.pts[ffDlg.sel].y = yi / 100
        if button("Delete", w = dp(70), enabled = ffDlg.pts.len > 1):
          ffDlg.pts.delete(ffDlg.sel)
          ffDlg.sel = min(ffDlg.sel, ffDlg.pts.high)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): cancel = true
  discard before
  if ($ffDlg.pts & $ffDlg.diffuse != ffApplied or (ok and L.shape.fill.style != 5)) and not cancel and
     (ffDlg.open or ok):
    ffApplied = $ffDlg.pts & $ffDlg.diffuse
    var s = L.shape
    s.fill = freeformPaint(ffDlg.pts)
    s.fill.diffuse = ffDlg.diffuse
    d.setShape(L, s)
  if cancel or (not ffDlg.open and not ok):
    ffDlg.open = false
    ffPending = false
    if d.stepOpen: d.cancelStep()
    d.markAll()
  elif ok:
    ffDlg.open = false
    ffPending = false
    var s = L.shape
    s.fill = freeformPaint(ffDlg.pts)
    d.setShape(L, s)
    if d.stepOpen: d.endStep()

# ---- Gradient Mesh -------------------------------------------------------------------------------------------

var
  gmDlg: tuple[open: bool; layer: Layer; cols, rows: int; pts: seq[tuple[x, y: float; color: uint32]];
               sel: int; drag: bool]
  gmPending = false
  gmApplied = ""                 ## (the mesh last put on the shape)

proc startGradientMesh() =
  let d = cur()
  if d == nil or not d.current.isShape:
    status = "Gradient Mesh: pick a shape layer."
    return
  let L = d.current
  let f = L.shape.fill
  if f.style == 6 and f.meshCols >= 2 and f.points.len >= 4:
    gmDlg = (true, L, f.meshCols - 1, f.points.len div f.meshCols - 1, f.points, 0, false)
  else:
    let c = if f.kind == spColor: f.color else: 0xFF3A86FF'u32
    let m = meshPaint(2, 2, [c, 0xFFFFFFFF'u32, fg or 0xFF000000'u32])
    gmDlg = (true, L, 2, 2, m.points, 4, false)
  gmApplied = ""
  d.beginStep("Gradient Mesh")
  d.touchLayers()
  d.touch(L, d.bounds)
  gmPending = true

proc gradientMeshDialog() =
  let d = cur()
  if not gmDlg.open:
    if gmPending:
      gmPending = false
      if d != nil and d.stepOpen:
        d.cancelStep()
        d.markAll()
    return
  if d == nil or d.layers.find(gmDlg.layer) < 0:
    gmDlg.open = false
    gmPending = false
    return
  let L = gmDlg.layer
  var ok, cancel = false
  dialog(gmDlg.open, "Gradient Mesh", 440):
    label("A grid of color points: drag a point to bend the colors after it; pick one for its color.",
          color = ui.theme.gray)
    row:
      label "Columns:"
      var c = gmDlg.cols
      var r = gmDlg.rows
      let cc = spin(c, 1, 8, w = dp(56))
      label "Rows:"
      let rc = spin(r, 1, 8, w = dp(56))
      if cc or rc:
        # (a grid of another size: even again, the colors the corners had)
        let nc = gmDlg.cols + 1
        let corners = [gmDlg.pts[0].color, gmDlg.pts[nc - 1].color, gmDlg.pts[^nc].color, gmDlg.pts[^1].color]
        gmDlg.cols = c
        gmDlg.rows = r
        var m = meshPaint(c, r, [0xFFFFFFFF'u32])
        let w = c + 1
        m.points[0].color = corners[0]
        m.points[w - 1].color = corners[1]
        m.points[^w].color = corners[2]
        m.points[^1].color = corners[3]
        gmDlg.pts = m.points
        gmDlg.sel = 0
      if button("Even", w = dp(70)):
        let w = gmDlg.cols + 1
        for i in 0 ..< gmDlg.pts.len:
          gmDlg.pts[i].x = (i mod w) / gmDlg.cols
          gmDlg.pts[i].y = (i div w) / gmDlg.rows
    let pr = place(dp(400), dp(260))
    let (x0, y0, x1, y1) = pathBounds(L.shape.path)
    fill(pr, color(240, 240, 240))
    let k = min(pr.w.float / max(1.0, x1 - x0), pr.h.float / max(1.0, y1 - y0))
    let gw = max(1, int((x1 - x0) * k))
    let gh = max(1, int((y1 - y0) * k))
    let gr = rect(pr.x + (pr.w - gw) div 2, pr.y + (pr.h - gh) div 2, gw, gh)
    let step = max(4, dp(6))
    let cols = gmDlg.cols + 1
    var yy = 0
    while yy < gh:
      var xx = 0
      while xx < gw:
        let c = meshAt(gmDlg.pts, cols, (xx.float + 0.5) / gw.float, (yy.float + 0.5) / gh.float)
        fill(rect(gr.x + xx, gr.y + yy, min(step, gw - xx), min(step, gh - yy)),
             color(uint8((c shr 16) and 255), uint8((c shr 8) and 255), uint8(c and 255)))
        xx += step
      yy += step
    box(gr, ui.theme.edge)
    # (the grid's lines, then its points)
    for i, p in gmDlg.pts:
      let ax = gr.x + int(p.x * gw.float)
      let ay = gr.y + int(p.y * gh.float)
      if i mod cols < cols - 1:
        let q = gmDlg.pts[i + 1]
        line(ax, ay, gr.x + int(q.x * gw.float), gr.y + int(q.y * gh.float), color(60, 60, 60))
      if i + cols < gmDlg.pts.len:
        let q = gmDlg.pts[i + cols]
        line(ax, ay, gr.x + int(q.x * gw.float), gr.y + int(q.y * gh.float), color(60, 60, 60))
    for i, p in gmDlg.pts:
      let cx = gr.x + int(p.x * gw.float)
      let cy = gr.y + int(p.y * gh.float)
      let r = rect(cx - dp(5), cy - dp(5), dp(10), dp(10))
      fill(r, color(uint8((p.color shr 16) and 255), uint8((p.color shr 8) and 255), uint8(p.color and 255)))
      box(r, if i == gmDlg.sel: ui.theme.select else: color(0, 0, 0), (if i == gmDlg.sel: 2 else: 1))
    let hit = interact(idOf("gmcanvas"), gr, focusable = false)
    if hit.down and ui.pressed and not gmDlg.drag:
      let u = (ui.mx - gr.x).float / gw.float
      let v = (ui.my - gr.y).float / gh.float
      var near = -1
      var best = 1e9
      for i, p in gmDlg.pts:
        let dd = abs(p.x - u) * gw.float + abs(p.y - v) * gh.float
        if dd < best and dd < dp(14).float:
          best = dd
          near = i
      if near >= 0:
        gmDlg.sel = near
        gmDlg.drag = true
    if gmDlg.drag:
      if ui.mouseDown:
        gmDlg.pts[gmDlg.sel].x = clamp((ui.mx - gr.x).float / gw.float, 0.0, 1.0)
        gmDlg.pts[gmDlg.sel].y = clamp((ui.my - gr.y).float / gh.float, 0.0, 1.0)
      else: gmDlg.drag = false
    if gmDlg.sel in 0 .. gmDlg.pts.high:
      row:
        label "Point " & $(gmDlg.sel + 1) & ":"
        var c = gmDlg.pts[gmDlg.sel].color
        if colorWell(c, "gmpoint", dp(40)): gmDlg.pts[gmDlg.sel].color = c or 0xFF000000'u32
        var xi = int(round(gmDlg.pts[gmDlg.sel].x * 100))
        var yi = int(round(gmDlg.pts[gmDlg.sel].y * 100))
        label "Across:"
        if spin(xi, 0, 100, w = dp(56)): gmDlg.pts[gmDlg.sel].x = xi / 100
        label "Down:"
        if spin(yi, 0, 100, w = dp(56)): gmDlg.pts[gmDlg.sel].y = yi / 100
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): cancel = true
  let now = $gmDlg.cols & $gmDlg.pts
  if now != gmApplied and not cancel and (gmDlg.open or ok):
    gmApplied = now
    var s = L.shape
    s.fill = ShapePaint(kind: spGradient, style: 6, meshCols: gmDlg.cols + 1, points: gmDlg.pts, opacity: 100,
                        color: gmDlg.pts[0].color, color2: gmDlg.pts[^1].color)
    d.setShape(L, s)
  if cancel or (not gmDlg.open and not ok):
    gmDlg.open = false
    gmPending = false
    if d.stepOpen: d.cancelStep()
    d.markAll()
  elif ok:
    gmDlg.open = false
    gmPending = false
    if d.stepOpen: d.endStep()

# Retro Atelier -- included by photo.nim
#
# Making, as the drawing program, the photo editor and the quick-design programs have it
# (retroui/vectormake, liveeffects, photorelight, mockups, designstyles, aiconnect): Global
# Edit; Envelope Distort; Live Paint; Intertwine; Pattern Options; Relight with lights on the
# canvas (and Lighting Effects' light there too); Remove with its shadow; Upscale; Mockups;
# Styles and font pairs; Tidy Up; Lift Subject; photo placeholders; an AI service of your own.

var
  meshDlg: tuple[open: bool; cols, rows: int; moved: seq[(float, float)]; grab: int; layer: Layer]
  patOpts: tuple[tile, w, h, hs, vs, brick: int; leftTop, topTop: bool; key: string; prev: Bitmap;
                 tilePx: seq[uint32]; tw, th: int]
  rlDlg: tuple[open: bool; lights: seq[RelightLight]; sel, ambient, relief: int; useDepth: bool;
               depth: seq[uint8]; depthKey: string; shown: string; grab: int; doc: Doc]
  lightGrab = false               ## (Lighting Effects' light dragged on the canvas)
  upDlg: tuple[open: bool; factor, sharpen: int]
  mockDlg: tuple[open: bool; kind: int; color: uint32; size: int; thumbs: seq[Bitmap]]
  stylePick = -1
  styleColorsOn = true
  styleFontsOn = true
  aiDlg: tuple[open: bool; s: AiSettings; loaded, keyed: bool]
  imgAi: tuple[loaded, keyed: bool; s: AiImageSettings]   ## (the image service: photo/assist)
  genDlg: tuple[open: bool; kind: int; prompt: string; w, h: int]
    ## Generative Fill (0), Generative Expand (1), Generate Image (2): photo/assist
  assist: AiChat                  ## (the Assistant panel's conversation: photo/assist)
  liveSeen: Table[pointer, int]

proc genDialog()                  # (in photo/assist)

proc loadImgAi(withKey = true) =
  if imgAi.loaded and (imgAi.keyed or not withKey): return
  imgAi.s = loadAiImageSettings(AppData, withKey)
  imgAi.loaded = true
  imgAi.keyed = withKey

const
  TileNames = ["Grid", "Brick by Row", "Brick by Column", "Hex by Column", "Hex by Row"]
  BrickNames = ["1/2", "1/3", "1/4", "1/5"]
  LightKinds = ["Point", "Spot", "Sun"]

# ---- Global Edit -----------------------------------------------------------------------------------------

proc startGlobalEdit(d: Doc) =
  let L = d.current
  if not L.isShape:
    status = "Global Edit: pick a shape first"
    return
  let others = d.similarLayers(L, gEdit.sameSize)
  if others.len == 0:
    status = "Global Edit: no other shape like this one"
    return
  for M in d.layers: M.picked = M in others
  gEdit = (true, d, L, others, L.shape, gEdit.sameSize)
  inc d.ver
  status = "Global Edit: " & $others.len & (if others.len == 1: " other shape follows" else: " other shapes follow") &
           " what is done to this one (Stop Global Edit when done)"

proc globalEditAfterStep(d: Doc) =
  ## (as a step ends: what it did to the shape of a Global Edit done to the others, in that
  ## step -- undone with it)
  if not gEdit.on or gEdit.doc != d: return
  if gEdit.src notin d.layers:
    gEdit.on = false
    return
  if gEdit.src.shape == gEdit.last: return
  gEdit.last = gEdit.src.shape
  var alive: seq[Layer]
  for M in gEdit.others:
    if M in d.layers: alive.add M
  gEdit.others = alive
  d.touchLayers()
  d.globalEdit(gEdit.src, gEdit.others, gEdit.sameSize)

proc afterStep(d: Doc) =
  globalEditAfterStep(d)
  flexAfterStep(d)

stepEndHook = afterStep

# ---- Envelope Distort --------------------------------------------------------------------------------------

proc flatOutline(p: Path): seq[(float, float)] =
  ## (a path's first subpath as a polygon, its curves in pieces)
  if p.subs.len == 0: return
  let sp = p.subs[0]
  let n = sp.pts.len
  if n == 0: return
  let segs = if sp.closed: n else: n - 1
  for k in 0 ..< segs:
    let a = sp.pts[k]
    let b = sp.pts[(k + 1) mod n]
    for i in 0 ..< 12:
      let t = i / 12
      let u = 1 - t
      result.add (u * u * u * a.p[0] + 3 * u * u * t * a.outH[0] + 3 * u * t * t * b.inH[0] + t * t * t * b.p[0],
                  u * u * u * a.p[1] + 3 * u * u * t * a.outH[1] + 3 * u * t * t * b.inH[1] + t * t * t * b.p[1])

proc envelopeTopObject(d: Doc) =
  ## Make with Top Object: the shapes picked under the top one fitted into its outline; the
  ## top one goes (its outline kept in their envelopes).
  let top = d.current
  if not top.isShape:
    status = "Make with Top Object: the top object must be a shape"
    return
  let outline = flatOutline(top.shape.path)
  if outline.len < 3: return
  var targets: seq[Layer]
  for L in d.layers:
    if L != top and L.picked and L.isShape: targets.add L
  if targets.len == 0:
    let i = d.layers.find(top)
    if i > 0 and d.layers[i - 1].isShape: targets.add d.layers[i - 1]
  if targets.len == 0:
    status = "Make with Top Object: pick the shapes to fit, with the top object over them"
    return
  d.layersChange("Envelope Distort"):
    for L in targets:
      var s = L.shape
      s.effects.add LiveEffect(kind: leEnvelope, envelope: outline)
      d.setShape(L, s)
    d.deleteLayer(d.layers.find(top))
    d.cur = d.layers.find(targets[0])
  d.markAll()

proc startMeshEnvelope(d: Doc) =
  let L = d.current
  if not L.isShape:
    status = "Make with Mesh: pick a shape first"
    return
  var cols = 4
  var rows = 4
  var moved = newSeq[(float, float)](25)
  for e in L.shape.effects:
    if e.kind == leEnvelope and e.envelope.len == 0 and e.mesh.len == (e.copies + 1) * (int(e.detail) + 1):
      cols = e.copies
      rows = int(e.detail)
      moved = e.mesh
  meshDlg = (true, cols, rows, moved, -1, L)

proc meshDialog() =
  if not meshDlg.open: return
  let d = cur()
  if d == nil or meshDlg.layer notin d.layers:
    meshDlg.open = false
    return
  let L = meshDlg.layer
  var ok = false
  dialog(meshDlg.open, "Envelope Mesh", 460):
    row([90, 70, 90, 70, -1]):
      label "Columns:"
      var c = meshDlg.cols
      if spin(c, 1, 10, w = dp(56)) and c != meshDlg.cols:
        meshDlg.cols = c
        meshDlg.moved = newSeq[(float, float)]((c + 1) * (meshDlg.rows + 1))
      label "Rows:"
      var r = meshDlg.rows
      if spin(r, 1, 10, w = dp(56)) and r != meshDlg.rows:
        meshDlg.rows = r
        meshDlg.moved = newSeq[(float, float)]((meshDlg.cols + 1) * (r + 1))
    # the grid over the shape's box: drag its points
    let (x0, y0, x1, y1) = pathBounds(L.shape.path)
    let bw = max(1.0, x1 - x0)
    let bh = max(1.0, y1 - y0)
    let area = place(dp(420), dp(260))
    fill(area, color(250, 250, 250))
    box(area, ui.theme.frame)
    let k = min(area.w.float / (bw * 1.8), area.h.float / (bh * 1.8))
    let ox = area.x.float + (area.w.float - bw * k) / 2
    let oy = area.y.float + (area.h.float - bh * k) / 2
    let cols = meshDlg.cols
    let rows = meshDlg.rows
    proc pt(i, j: int): (float, float) =
      let m = meshDlg.moved[j * (cols + 1) + i]
      (ox + (bw * i.float / cols.float + m[0]) * k, oy + (bh * j.float / rows.float + m[1]) * k)
    # (the shape as it is now, small)
    let shown = applyEffects(L.shape.path, @[LiveEffect(kind: leEnvelope, copies: cols, detail: rows.float,
                                                        mesh: meshDlg.moved)])
    let outline = flatOutline(shown)
    pushClip(area)
    for q in 0 ..< outline.len:
      let a = outline[q]
      let b = outline[(q + 1) mod outline.len]
      thickLine(ox + (a[0] - x0) * k, oy + (a[1] - y0) * k, ox + (b[0] - x0) * k, oy + (b[1] - y0) * k, 2,
                color(40, 90, 160))
    for j in 0 .. rows:
      for i in 0 .. cols:
        if i < cols:
          let (ax, ay) = pt(i, j)
          let (bx, by) = pt(i + 1, j)
          thickLine(ax, ay, bx, by, 1, color(160, 160, 160))
        if j < rows:
          let (ax, ay) = pt(i, j)
          let (bx, by) = pt(i, j + 1)
          thickLine(ax, ay, bx, by, 1, color(160, 160, 160))
    let id = idOf("envmesh")
    let hit = interact(id, area, focusable = false)
    let mx = float(ui.mx)
    let my = float(ui.my)
    if hit.down and ui.pressed:
      var best = 1e9
      meshDlg.grab = -1
      for j in 0 .. rows:
        for i in 0 .. cols:
          let (px, py) = pt(i, j)
          let dd = hypot(px - mx, py - my)
          if dd < best and dd < dp(12).float:
            best = dd
            meshDlg.grab = j * (cols + 1) + i
    if ui.active == id and ui.mouseDown and meshDlg.grab >= 0:
      ui.dragsActive = true
      let g = meshDlg.grab
      let i = g mod (cols + 1)
      let j = g div (cols + 1)
      meshDlg.moved[g] = ((mx - ox) / k - bw * i.float / cols.float, (my - oy) / k - bh * j.float / rows.float)
    if not ui.mouseDown: meshDlg.grab = -1
    for j in 0 .. rows:
      for i in 0 .. cols:
        let (px, py) = pt(i, j)
        disc(px, py, dp(4).float, if meshDlg.grab == j * (cols + 1) + i: color(230, 40, 40) else: color(40, 40, 40))
    popClip()
    paragraph("Drag the points: the shape bends with its grid. Undone by Envelope Distort > Release.",
              color = ui.theme.gray)
    row:
      if button("Reset", w = dp(80)): meshDlg.moved = newSeq[(float, float)]((cols + 1) * (rows + 1))
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): meshDlg.open = false
  if ok:
    meshDlg.open = false
    d.layersChange("Envelope Distort"):
      var s = L.shape
      s.effects.keepItIf(it.kind != leEnvelope)
      s.effects.add LiveEffect(kind: leEnvelope, copies: meshDlg.cols, detail: meshDlg.rows.float, mesh: meshDlg.moved)
      d.setShape(L, s)
    d.markAll()

# ---- Live Paint ---------------------------------------------------------------------------------------------

proc livePaintOf(L: Layer): tuple[on: bool; lp: LivePaint] =
  if L == nil or L.meta.len == 0 or "livePaint" notin L.meta: return
  try:
    let j = parseJson(L.meta)
    if j.kind == JObject and j.hasKey("livePaint"): result = (true, livePaintFrom(j["livePaint"]))
  except CatchableError: discard

proc setLivePaint(L: Layer; lp: LivePaint) =
  var j = try: parseJson(L.meta) except CatchableError: newJObject()
  if j.kind != JObject: j = newJObject()
  j["livePaint"] = lp.toJson
  L.meta = $j

proc ensureUid(d: Doc; L: Layer): int =
  if L.uid == 0:
    var n = 1
    for M in d.layers: n = max(n, M.uid + 1)
    L.uid = n
  L.uid

proc makeLivePaint(d: Doc) =
  ## Object > Live Paint > Make: the shapes picked (and the current) make the faces of a Live
  ## Paint group: a layer under them that holds the faces' colors.
  var shapes: seq[Layer]
  for i, L in d.layers:
    if (L.picked or i == d.cur) and L.isShape: shapes.add L
  if shapes.len == 0:
    status = "Live Paint: pick shapes first (their outlines make the faces)"
    return
  var lowest = d.layers.len
  for L in shapes: lowest = min(lowest, d.layers.find(L))
  d.layersChange("Live Paint"):
    var lp = LivePaint()
    for L in shapes: lp.shapes.add d.ensureUid(L)
    let P = d.addLayer("Live Paint", above = lowest - 1)
    P.setLivePaint(lp)
    d.cur = d.layers.find(P)
  lpBucket = true
  status = "Live Paint: the Live Paint Bucket fills a face with the foreground color (Alt: empties it)"

proc keepLivePaint(d: Doc) =
  for P in d.layers:
    let (on, lp) = P.livePaintOf
    if not on: continue
    var sig = 0
    for u in lp.shapes:
      let L = d.layerOfUid(u)
      if L != nil: sig = sig * 31 + L.ver
    sig = sig * 31 + hash(P.meta)
    if liveSeen.getOrDefault(cast[pointer](P), -1) == sig: continue
    liveSeen[cast[pointer](P)] = sig
    P.px = d.paintFaces(lp)
    inc P.ver
    d.markAll()

proc expandLivePaint(d: Doc) =
  ## Live Paint > Expand: each painted face a shape layer of its own, the group's layer gone.
  let P = d.current
  let (on, lp) = P.livePaintOf
  if not on:
    status = "Expand: pick a Live Paint layer"
    return
  let keepSel = d.sel
  d.layersChange("Expand Live Paint"):
    var at = d.layers.find(P)
    for f in lp.faces:
      let m = d.faceMask(lp, f.x, f.y)
      if m.len == 0: continue
      d.sel = m
      let path = d.pathFromSelection(1.0)
      if path.subs.len == 0: continue
      let L = d.addShapeLayer(ShapeData(path: path, fill: solidPaint(f.color)), "Face", above = at)
      at = d.layers.find(L)
    d.sel = keepSel
    d.deleteLayer(d.layers.find(P))
  inc d.selVer
  d.markAll()

# ---- Intertwine --------------------------------------------------------------------------------------------

proc intertwineAt(d: Doc; x, y: int) =
  ## (where the two picked cross at `x`, `y`: the one under brought over there)
  var two: seq[int]
  for i, L in d.layers:
    if (L.picked or i == d.cur) and not L.group and not L.background and L.px.len == d.w * d.h: two.add i
  if two.len != 2:
    status = "Intertwine: pick the two objects that cross (Ctrl+click in the Layers panel)"
    return
  let under = d.layers[min(two[0], two[1])]
  let over = d.layers[max(two[0], two[1])]
  let part = d.crossing(over, under, x, y)
  if part.len == 0:
    status = "Intertwine: click where the two cross"
    return
  d.layersChange("Intertwine"):
    let C = cloneLayer(under)
    C.uid = 0
    C.name = under.name & " (over)"
    C.picked = false
    let M = Layer(name: "Layer Mask", pxRaw: newSeq[uint32](d.w * d.h), opacity: 100, visible: true, gray: true)
    for i in 0 ..< part.len:
      let v = uint32(part[i])
      M.px[i] = 0xFF000000'u32 or (v shl 16) or (v shl 8) or v
    C.mask = M
    d.insertLayer(C, d.layers.find(over))
  d.markAll()
  status = "Intertwine: " & under.name & " comes over " & over.name & " there (click another place where they cross)"

# ---- Pattern Options ------------------------------------------------------------------------------------------

proc patternArt(d: Doc): tuple[px: seq[uint32]; w, h: int] =
  ## (the art made a pattern: the current layer's pixels where it has some -- shapes as drawn)
  let L = d.current
  if L.px.len != d.w * d.h: return
  let r = d.layerBox(L)
  if r.w <= 0 or r.h <= 0: return
  result.w = r.w
  result.h = r.h
  result.px = newSeq[uint32](r.w * r.h)
  for y in 0 ..< r.h:
    for x in 0 ..< r.w: result.px[y * r.w + x] = L.px[(r.y + y) * d.w + r.x + x]

proc patternOptionsBody(d: Doc) =
  ## Window > Pattern Options: the current layer made a seamless pattern -- its tiles set in a
  ## grid, bricks, hexagons -- seen repeating as it is set; Save Pattern puts it in Patterns.
  if d == nil:
    label("No image open", color = ui.theme.gray)
    return
  let art = d.patternArt
  if art.w == 0:
    label("Pick a layer with art in it.", color = ui.theme.gray)
    return
  if patOpts.w == 0: patOpts.w = art.w
  if patOpts.h == 0: patOpts.h = art.h
  row([90, -1]):
    label "Tile Type:"
    combo(TileNames, patOpts.tile, w = dp(150))
  if patOpts.tile in 1 .. 2:
    row([90, -1]):
      label "Brick Offset:"
      combo(BrickNames, patOpts.brick, w = dp(80))
  row([90, 70, 30, 70]):
    label "Size:"
    discard spin(patOpts.w, 1, 4096, w = dp(64))
    label "x"
    discard spin(patOpts.h, 1, 4096, w = dp(64))
  row([90, 70, 30, 70]):
    label "Spacing:"
    discard spin(patOpts.hs, -2000, 2000, w = dp(64))
    label ""
    discard spin(patOpts.vs, -2000, 2000, w = dp(64))
  row:
    checkbox("Left in front", patOpts.leftTop)
    checkbox("Top in front", patOpts.topTop)
  let spec = PatternSpec(tile: TileType(patOpts.tile), w: patOpts.w, h: patOpts.h, hSpace: patOpts.hs,
                         vSpace: patOpts.vs, brickOffset: patOpts.brick + 2, overlapLeftOnTop: patOpts.leftTop,
                         overlapTopOnTop: patOpts.topTop)
  let key = $spec & $d.current.ver & $cast[int](d.current)
  if key != patOpts.key:
    patOpts.key = key
    let t = patternTile(art.px, art.w, art.h, spec)
    patOpts.tilePx = t.px
    patOpts.tw = t.w
    patOpts.th = t.h
    # (three times three of it: seen repeating)
    let n = 3
    let b = newBitmap(t.w * n, t.h * n)
    for y in 0 ..< b.h:
      for x in 0 ..< b.w:
        b.px[y * b.w + x] = blendPx(0xFFFFFFFF'u32, t.px[(y mod t.h) * t.w + (x mod t.w)], 255, bmNormal)
    b.changed()
    patOpts.prev = b
  let r = place(dp(200), dp(200))
  if patOpts.prev != nil: drawFit(r, patOpts.prev)
  box(r, ui.theme.frame)
  label($patOpts.tw & " x " & $patOpts.th & " pixels a tile", color = ui.theme.gray)
  if button("Save Pattern", w = dp(120)):
    userPatterns.add PatternPreset(name: d.current.name & " Pattern", w: patOpts.tw, h: patOpts.th,
                                   px: patOpts.tilePx)
    pattern = patOpts.tilePx
    patternW = patOpts.tw
    patternH = patOpts.th
    status = "Saved in Patterns: " & d.current.name & " Pattern"

# ---- Relight, Lighting Effects' light on the canvas, Remove with its shadow, Upscale ---------------------------

proc relightNow(d: Doc) =
  ## (the lights put on the current layer, in the open step: what the canvas shows)
  var depth: seq[uint8]
  if rlDlg.useDepth:
    let key = $cast[int](d.current) & ":" & $d.current.ver
    if rlDlg.depthKey != key or rlDlg.depth.len != d.w * d.h:
      rlDlg.depth = depthMapOf(Img(w: d.w, h: d.h, px: d.current.px))
      rlDlg.depthKey = key
    depth = rlDlg.depth
  let fn = relight(rlDlg.lights, rlDlg.ambient / 100, depth, d.w, d.h, rlDlg.relief / 50)
  d.applyFilter(0, fn)

proc startRelight(d: Doc) =
  if not d.pixelLayerOk:
    status = "Relight: pick a layer with pixels"
    return
  rlDlg.open = true
  if rlDlg.lights.len == 0:
    rlDlg.lights = @[RelightLight(kind: rlPoint, x: 0.3, y: 0.3, height: 0.35, radius: 0.8, intensity: 1.2,
                                  color: 0xFFFFE6C0'u32)]
    rlDlg.ambient = 55
    rlDlg.relief = 50
    rlDlg.useDepth = true
  rlDlg.sel = 0
  rlDlg.shown = ""
  rlDlg.doc = d
  d.beginStep("Relight")

proc relightDialog() =
  let d = rlDlg.doc
  if not rlDlg.open:
    if d != nil:
      # (closed from elsewhere: as it was)
      if d.stepOpen: d.cancelStep()
      d.markAll()
      rlDlg.doc = nil
    return
  if d == nil:
    rlDlg.open = false
    return
  var ok, cancel = false
  dialog(rlDlg.open, "Relight", 420):
    var names: seq[string]
    for i, l in rlDlg.lights: names.add tr("Light Source") & " " & $(i + 1) & " (" & tr(LightKinds[ord(l.kind)]) & ")"
    listbox(names, rlDlg.sel, rows = 4)
    row:
      if button("Add Light", w = dp(100), enabled = rlDlg.lights.len < 6):
        rlDlg.lights.add RelightLight(kind: rlPoint, x: 0.7, y: 0.4, height: 0.3, radius: 0.7, intensity: 1,
                                      color: 0xFFFFFFFF'u32)
        rlDlg.sel = rlDlg.lights.high
      if button("Remove", w = dp(80), enabled = rlDlg.lights.len > 1):
        rlDlg.lights.delete(clamp(rlDlg.sel, 0, rlDlg.lights.high))
        rlDlg.sel = clamp(rlDlg.sel, 0, rlDlg.lights.high)
    if rlDlg.sel in 0 .. rlDlg.lights.high:
      var l = rlDlg.lights[rlDlg.sel]
      row([100, -1]):
        label "Kind:"
        var k = ord(l.kind)
        if combo(LightKinds, k, w = dp(110)): l.kind = RelightKind(k)
      row([100, -1]):
        label "Color:"
        colorWell(l.color, "relightcolor", dp(50))
      var it = int(l.intensity * 50)
      row([100, -1, 40]):
        label "Intensity:"
        discard slider(it, 0, 150, ticks = 0)
        label $it
      l.intensity = it / 50
      if l.kind != rlSun:
        var rr = int(l.radius * 100)
        row([100, -1, 40]):
          label "Reach:"
          discard slider(rr, 5, 300, ticks = 0)
          label $rr & "%"
        l.radius = rr / 100
        var hh = int(l.height * 100)
        row([100, -1, 40]):
          label "Height:"
          discard slider(hh, 1, 150, ticks = 0)
          label $hh
        l.height = hh / 100
      if l.kind in {rlSpot, rlSun}:
        var a = int(l.angle)
        row([100, -1, 40]):
          label "Angle:"
          discard slider(a, -180, 180, ticks = 0)
          label $a & "°"
        l.angle = a.float
      if l.kind == rlSpot:
        var c = int(if l.cone > 0: l.cone else: 50)
        row([100, -1, 40]):
          label "Cone:"
          discard slider(c, 5, 170, ticks = 0)
          label $c & "°"
        l.cone = c.float
      rlDlg.lights[rlDlg.sel] = l
    row([100, -1, 40]):
      label "Ambient:"
      discard slider(rlDlg.ambient, 0, 150, ticks = 0)
      label $rlDlg.ambient
    checkbox("Use the photo's depth (its relief)", rlDlg.useDepth)
    if rlDlg.useDepth:
      row([100, -1, 40]):
        label "Relief:"
        discard slider(rlDlg.relief, 0, 150, ticks = 0)
        label $rlDlg.relief
    paragraph("Drag the lights on the image. Worked out here: no AI, nothing sent anywhere.", color = ui.theme.gray)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): cancel = true
  if not rlDlg.open: cancel = true
  if cancel:
    rlDlg.open = false
    rlDlg.doc = nil
    if d.stepOpen: d.cancelStep()
    d.markAll()
    return
  # (the image follows the settings, once the mouse is let go)
  let key = $rlDlg.lights & $rlDlg.ambient & $rlDlg.useDepth & $rlDlg.relief
  if key != rlDlg.shown and not ui.mouseDown:
    if d.stepOpen: d.cancelStep()
    d.beginStep("Relight")
    beginBusy("Relight")
    try: relightNow(d)
    finally: endBusy()
    rlDlg.shown = key
    d.markAll()
  if ok:
    rlDlg.open = false
    rlDlg.doc = nil
    if d.stepOpen: d.endStep()

proc upscaleDialog() =
  if not upDlg.open: return
  let d = cur()
  if d == nil:
    upDlg.open = false
    return
  var ok = false
  dialog(upDlg.open, "Upscale", 380):
    row([110, -1]):
      label "Make it:"
      combo(["2 times as big", "3 times as big", "4 times as big"], upDlg.factor, w = dp(150))
    let k = upDlg.factor + 2
    label($d.w & " x " & $d.h & " → " & $(d.w * k) & " x " & $(d.h * k) & " pixels", color = ui.theme.gray)
    row([110, -1, 40]):
      label "Sharpen:"
      discard slider(upDlg.sharpen, 0, 100, ticks = 0)
      label $upDlg.sharpen
    paragraph("Its edges kept sharp along their own lines, its detail made again from the picture itself -- " &
              "nothing invented, worked out here.", color = ui.theme.gray)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80), enabled = sizeOk(d.w * k, d.h * k)): ok = true
      if button("Cancel", w = dp(80)): upDlg.open = false
  if ok:
    upDlg.open = false
    let k = upDlg.factor + 2
    try:
      beginBusy("Upscale")
      try:
        d.change("Upscale"): d.upscaleDoc(k, upDlg.sharpen / 100)
      finally: endBusy()
      if active != nil: active.fitWindow()
      status = "Upscaled to " & $d.w & " x " & $d.h
    except CatchableError: status = "Could not upscale: " & getCurrentExceptionMsg()

proc removeWithShadow(d: Doc) =
  ## Remove with Its Shadow: the selection -- and the shadow it casts -- filled from what is
  ## round them.
  if not d.hasSelection:
    status = "Remove with Its Shadow: select the object first (Select Subject, the Lasso...)"
    return
  if not d.pixelLayerOk: return
  d.updateComposite()
  let sh = shadowOf(Img(w: d.w, h: d.h, px: d.compCopy), d.sel)
  var n = 0
  var m = d.sel
  for i in 0 ..< m.len:
    if sh[i] > m[i]:
      m[i] = sh[i]
      inc n
  d.paintStep("Remove with Its Shadow"):
    d.sel = m
    inc d.selVer
    d.contentAwareFill(int(epochTime() * 1000) mod 9973 + 1)
  status = if n > 0: "Removed, its shadow too" else: "Removed (no shadow found round it)"

# ---- Mockups, Styles, Tidy Up, Lift Subject, placeholders ------------------------------------------------------

proc mockupDialog() =
  if not mockDlg.open: return
  let d = cur()
  if d == nil:
    mockDlg.open = false
    return
  var ok = false
  dialog(mockDlg.open, "Mockups", 560):
    if mockDlg.thumbs.len == 0:
      var design = newSeq[uint32](60 * 40)
      for y in 0 ..< 40:
        for x in 0 ..< 60: design[y * 60 + x] = if ((x div 10) + (y div 10)) mod 2 == 0: 0xFF2A6F97'u32 else: 0xFFF2B33D'u32
      for k in MockupKind:
        let m = makeMockup(k, design, 60, 40, 200, 150)
        m.updateComposite()
        let b = newBitmap(200, 150)
        b.px = m.compCopy
        b.changed()
        mockDlg.thumbs.add b
    var i = 0
    for k in MockupKind:
      if i mod 4 == 0: row: discard
      inc i
    tileGrid(mockDlg.thumbs.len, dp(124), dp(100), "mockups", proc (j: int; r: Rect; hit: Hit) =
      drawFit(inset(r, dp(2)), mockDlg.thumbs[j])
      box(r, if j == mockDlg.kind: ui.theme.text else: ui.theme.frame)
      if j == mockDlg.kind: box(inset(r, 1), ui.theme.text)
      if hit.hover: ui.tip = tr($MockupKind(j))
      if hit.clicked: mockDlg.kind = j)
    row([110, -1]):
      label "Its color:"
      colorWell(mockDlg.color, "mockcolor", dp(50))
    row([110, -1]):
      label "Size:"
      combo(["1200 x 900", "1600 x 1200", "2400 x 1800"], mockDlg.size, w = dp(140))
    paragraph("A new document: the scene, your design a Smart Object in its place (double-click it to change " &
              "the design), the light and shade over it.", color = ui.theme.gray)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): mockDlg.open = false
  if ok:
    mockDlg.open = false
    d.updateComposite()
    let (w, h) = [(1200, 900), (1600, 1200), (2400, 1800)][clamp(mockDlg.size, 0, 2)]
    beginBusy("Mockups")
    try:
      let m = makeMockup(MockupKind(mockDlg.kind), d.compCopy, d.w, d.h, w, h, mockDlg.color or 0xFF000000'u32)
      m.name = d.name & " " & tr($MockupKind(mockDlg.kind))
      addDoc(m)
    finally: endBusy()

proc designStylesBody(d: Doc) =
  ## Window > Styles and Fonts: a palette and a font pair on the whole design in one click; font
  ## pairs that go together.
  if d == nil:
    label("No image open", color = ui.theme.gray)
    return
  let styles = builtInStyles()
  row:
    checkbox("Colors", styleColorsOn)
    checkbox("Fonts", styleFontsOn)
  tileGrid(styles.len, dp(78), dp(54), "dstyles", proc (i: int; r: Rect; hit: Hit) =
    let s = styles[i]
    fill(r, colorOf(s.colors[^1]))
    let sw = (r.w - dp(8)) div max(1, s.colors.len)
    for k, c in s.colors:
      fill(rect(r.x + dp(4) + k * sw, r.y + r.h - dp(16), sw, dp(12)), colorOf(c))
    text(r.x + dp(5), r.y + dp(4), "Aa", colorOf(s.colors[0]), style(size = 1.2, bold = true))
    box(r, if i == stylePick: ui.theme.text else: ui.theme.frame)
    if hit.hover: ui.tip = s.name & ": " & s.heading & " + " & s.body
    if hit.clicked:
      stylePick = i
      d.layersChange("Style: " & s.name):
        discard d.applyStyle(s, styleColorsOn, styleFontsOn))
  space(dp(6))
  label("Font Pairs", bold = true)
  for k, (h, b) in fontPairs(fontFamilies()):
    if k >= 12: break
    pushId("pair" & $k)
    if button(h & " + " & b, w = dp(220)):
      d.layersChange("Font Pair"):
        discard d.applyStyle(DesignStyle(name: h & " + " & b, heading: h, body: b), colors = false)
    popId()

proc tidyUpPicked(d: Doc) =
  ## Tidy Up: the layers picked put in a neat row, column or grid, the room between them even.
  var idxs: seq[int]
  for i, L in d.layers:
    if (L.picked or i == d.cur) and not L.background and not L.group and not L.locked: idxs.add i
  if idxs.len < 2:
    status = "Tidy Up: pick two or more layers (Ctrl+click in the Layers panel)"
    return
  var rs: seq[Rect]
  for i in idxs: rs.add d.layerBox(d.layers[i])
  let to = tidyUp(rs)
  d.layersChange("Tidy Up"):
    for k, i in idxs:
      d.shiftLayers(@[d.layers[i]], to[k].x - rs[k].x, to[k].y - rs[k].y)
  d.markAll()

proc liftSubject(d: Doc) =
  ## Lift Subject: the subject made a layer of its own -- picked up, to move -- and the place
  ## it was filled from what is round it.
  if not d.pixelLayerOk:
    status = "Lift Subject: pick a layer with pixels"
    return
  beginBusy("Lift Subject")
  try:
    let m = d.subjectOf("Lift Subject")
    if m.len == 0: return
    let src = d.current
    let si = d.cur
    var lifted = newSeq[uint32](d.w * d.h)
    for i in 0 ..< m.len:
      let a = int(src.px[i] shr 24) * int(m[i]) div 255
      if a > 0: lifted[i] = (src.px[i] and 0xFFFFFF'u32) or (uint32(a) shl 24)
    # (the hole a little bigger than the subject: its edge goes too)
    var hole = m
    for _ in 0 ..< 3:
      var g = hole
      for y in 0 ..< d.h:
        for x in 0 ..< d.w:
          let i = y * d.w + x
          if hole[i] >= 128: continue
          if (x > 0 and hole[i - 1] >= 128) or (x < d.w - 1 and hole[i + 1] >= 128) or
             (y > 0 and hole[i - d.w] >= 128) or (y < d.h - 1 and hole[i + d.w] >= 128): g[i] = 255
      hole = g
    let keepSel = d.sel
    d.beginStep("Lift Subject")
    d.touchLayers()
    d.sel = hole
    d.cur = si
    d.contentAwareFill(int(epochTime() * 1000) mod 9973 + 1)
    d.sel = keepSel
    let L = d.addLayer("Subject", above = si)
    L.px = lifted
    inc L.ver
    d.cur = d.layers.find(L)
    d.endStep()
    inc d.selVer
    d.markAll()
    status = "Lift Subject: the subject is a layer of its own -- move it; the place it was is filled"
  finally: endBusy()

# ---- the AI connector ------------------------------------------------------------------------------------------

proc loadAi(withKey = true) =
  ## (the key -- kept in the system's keyring -- only asked for when it is wanted: the
  ## keychain may wait for its password)
  if aiDlg.loaded and (aiDlg.keyed or not withKey): return
  aiDlg.s = loadAiSettings(AppData, withKey)
  aiDlg.loaded = true
  aiDlg.keyed = withKey

proc saveAi(): bool = saveAiSettings(AppData, aiDlg.s)

proc appCommands(): seq[string] =
  ## (every command of the menus, by the names `runCommand` takes -- not those that end the app
  ## or ask about files)
  mIndex.on = true
  mIndex.found.setLen(0)
  try: psMenus()
  finally: mIndex.on = false
  for (_, _, c) in mIndex.found:
    if c in result or c.len == 0: continue
    if c in ["Quit", "Exit", "Close All", "Close", "Revert", "Ask AI...", "AI Connector...", "Assistant",
             "Generative Fill...", "Generative Expand...", "Generate Image..."]: continue
    result.add c

proc aiDialogs() =
  if aiDlg.open:
    loadAi()
    loadImgAi()
    var ok = false
    dialog(aiDlg.open, "AI Connector", 460):
      paragraph("An AI service of your own -- on your computer (Ollama, LM Studio) or online -- turns what you " &
                "ask into Retro Atelier's own commands, shown before they run. Off until you set one; nothing " &
                "is sent anywhere before.", color = ui.theme.gray)
      row([100, -1]):
        label "Speaks:"
        var k = ord(aiDlg.s.kind)
        if combo([$akOpenAi, $akAnthropic], k, w = dp(260)):
          aiDlg.s.kind = AiKind(k)
          if aiDlg.s.url.len == 0: aiDlg.s.url = defaultUrl(aiDlg.s.kind)
      row([100, -1]):
        label "Address:"
        edit(aiDlg.s.url)
      row([100, -1]):
        label "Model:"
        edit(aiDlg.s.model)
      row([100, -1]):
        label "Key:"
        edit(aiDlg.s.key, password = true)
      label("Pictures (Generate Image, Generative Fill and Expand):", bold = true)
      paragraph("A service that speaks OpenAI's images API: its address and model (gpt-image-1, dall-e-2...); " &
                "the key, if it is not the one above.", color = ui.theme.gray)
      row([100, -1]):
        label "Address:"
        edit(imgAi.s.url)
      row([100, -1]):
        label "Model:"
        edit(imgAi.s.model)
      row([100, -1]):
        label "Key:"
        edit(imgAi.s.key, password = true)
      row:
        if button("Disconnect", w = dp(100), enabled = aiDlg.s.connected or imgAi.s.connected):
          aiDlg.s = AiSettings()
          imgAi.s = AiImageSettings()
          discard saveAi()
          saveAiImageSettings(AppData, imgAi.s)
        spring()
        if button("OK", isDefault = true, w = dp(80)): ok = true
        if button("Cancel", w = dp(80)):
          aiDlg.open = false
          aiDlg.loaded = false
          imgAi.loaded = false
    if ok:
      aiDlg.open = false
      if imgAi.s.url.strip.len > 0 and imgAi.s.key.len == 0: imgAi.s.key = aiDlg.s.key
      let pics = saveAiImageSettings(AppData, imgAi.s)
      if assist != nil: assist.settings = aiDlg.s
      status = if not saveAi() or not pics: "AI Connector: not kept -- the settings or the keyring could not be written"
               elif aiDlg.s.connected: "AI Connector: " & aiDlg.s.model
               else: "AI Connector: off"

# ---- on the canvas ----------------------------------------------------------------------------------------------

proc makersCanvas(dw: DocWin; ev: PhotoEvent): bool =
  ## (a press on the image these take before the tools: the Live Paint Bucket, Intertwine, a
  ## light of Relight or of Lighting Effects, a placeholder double-clicked)
  let d = dw.doc
  if dw != active: return
  let x = int(floor(ev.x))
  let y = int(floor(ev.y))
  if rlDlg.open and d == rlDlg.doc:
    if ev.pressed:
      rlDlg.grab = -1
      for i, l in rlDlg.lights:
        let (sx, sy) = dw.view.toScreen(d, l.x * d.w.float, l.y * d.h.float)
        if abs(sx - ui.mx) <= dp(10) and abs(sy - ui.my) <= dp(10):
          rlDlg.grab = i
          rlDlg.sel = i
      if rlDlg.grab >= 0: return true
    if rlDlg.grab >= 0 and ev.down:
      rlDlg.lights[rlDlg.grab].x = clamp(ev.x / d.w.float, -0.5, 1.5)
      rlDlg.lights[rlDlg.grab].y = clamp(ev.y / d.h.float, -0.5, 1.5)
      return true
    if ev.released: rlDlg.grab = -1
  if fOpen and fSpec.name == "Lighting Effects" and fVals.len >= 3:
    let lx = fVals[1] / 100 * d.w.float
    let ly = fVals[2] / 100 * d.h.float
    let (sx, sy) = dw.view.toScreen(d, lx, ly)
    if ev.pressed and abs(sx - ui.mx) <= dp(10) and abs(sy - ui.my) <= dp(10):
      lightGrab = true
      return true
    if lightGrab and ev.down:
      fVals[1] = clamp(round(ev.x / d.w.float * 100), 0, 100)
      fVals[2] = clamp(round(ev.y / d.h.float * 100), 0, 100)
      return true
    if ev.released and lightGrab:
      lightGrab = false
      return true
  if lpBucket and ev.pressed and not ev.right:
    let P = d.current
    let (on, lp0) = P.livePaintOf
    if on:
      var lp = lp0
      if d.faceMask(lp, x, y).len == 0:
        status = "Live Paint: click inside the shapes (a face)"
        return true
      # (a face painted before, this one: its point moved here)
      var keep: seq[LivePaintFace]
      let here = d.faceMask(lp, x, y)
      for f in lp.faces:
        if f.x >= 0 and f.y >= 0 and f.x < d.w and f.y < d.h and here[f.y * d.w + f.x] >= 128: continue
        keep.add f
      lp.faces = keep
      lp.fillFace(x, y, if ev.alt: 0'u32 else: fg or 0xFF000000'u32)
      d.layersChange("Live Paint Bucket"): P.setLivePaint(lp)
      return true
    else: lpBucket = false
  if intertwineOn and ev.pressed and not ev.right:
    d.intertwineAt(x, y)
    return true
  if ev.pressed and ev.clicks == 2 and tool in {tMove, tShape}:
    # (a photo placeholder double-clicked: a photo put in it)
    for i in countdown(d.layers.high, 0):
      let L = d.layers[i]
      if L.attrs.placeholder == 0 or not L.visible or L.px.len != d.w * d.h: continue
      if x >= 0 and y >= 0 and x < d.w and y < d.h and (L.px[y * d.w + x] shr 24) > 0:
        d.cur = i
        runCommand("Place Into...")
        return true

proc makersOverlay(dw: DocWin; ev: PhotoEvent) =
  ## (the lights of Relight and of Lighting Effects on the image; the Live Paint Bucket's
  ## and Intertwine's cursor)
  let d = dw.doc
  if dw != active: return
  if rlDlg.open and d == rlDlg.doc:
    for i, l in rlDlg.lights:
      let (sx, sy) = dw.view.toScreen(d, l.x * d.w.float, l.y * d.h.float)
      let c = colorOf(l.color)
      disc(sx.float, sy.float, dp(8).float, color(30, 30, 30))
      disc(sx.float, sy.float, dp(6).float, c)
      if i == rlDlg.sel: ring(sx.float, sy.float, dp(10).float, 2, color(230, 40, 40))
      if l.kind in {rlSpot, rlSun}:
        let a = degToRad(l.angle)
        thickLine(sx.float, sy.float, sx.float + cos(a) * dp(40).float, sy.float - sin(a) * dp(40).float, 2,
                  color(30, 30, 30))
      elif l.radius > 0:
        let (ex, _) = dw.view.toScreen(d, (l.x + l.radius) * d.w.float, l.y * d.h.float)
        ring(sx.float, sy.float, abs(ex - sx).float, 1, color(255, 255, 255))
  if fOpen and fSpec.name == "Lighting Effects" and fVals.len >= 6:
    let (sx, sy) = dw.view.toScreen(d, fVals[1] / 100 * d.w.float, fVals[2] / 100 * d.h.float)
    disc(sx.float, sy.float, dp(8).float, color(30, 30, 30))
    disc(sx.float, sy.float, dp(6).float, color(255, 240, 200))
    let a = degToRad(fVals[5])
    thickLine(sx.float, sy.float, sx.float + cos(a) * dp(40).float, sy.float - sin(a) * dp(40).float, 2,
              color(30, 30, 30))
    if ev.over: ui.tip = tr("Drag the light")
  if (lpBucket or intertwineOn) and ev.over: ui.cursor = curHand

# ---- each frame, the commands, the dialogs ------------------------------------------------------------------

proc keepLive(d: Doc) =
  if gEdit.on and gEdit.doc == d and not d.stepOpen and gEdit.src in d.layers:
    gEdit.last = gEdit.src.shape          # (an undo, a redo: not a change to follow)
  keepLivePaint(d)

proc makersCommand(name: string): bool =
  let d = cur()
  result = true
  case name
  of "Start Global Edit":
    if d != nil: d.startGlobalEdit()
  of "Stop Global Edit":
    gEdit.on = false
    if d != nil:
      for L in d.layers: L.picked = false
      inc d.ver
    status = "Global Edit: off"
  of "Envelope: Make with Warp...":
    if d != nil and d.current.isShape: startLiveEffect(leWarp)
    else: status = "Make with Warp: pick a shape first"
  of "Envelope: Make with Mesh...":
    if d != nil: d.startMeshEnvelope()
  of "Envelope: Make with Top Object":
    if d != nil: d.envelopeTopObject()
  of "Envelope: Release":
    if d != nil and d.current.isShape:
      let L = d.current
      d.layersChange("Release Envelope"):
        var s = L.shape
        s.effects.keepItIf(it.kind notin {leEnvelope, leWarp})
        d.setShape(L, s)
      d.markAll()
  of "Live Paint: Make":
    if d != nil: d.makeLivePaint()
  of "Live Paint Bucket":
    lpBucket = not lpBucket
    intertwineOn = false
    status = if lpBucket: "Live Paint Bucket: click a face (Alt: empty it)" else: ""
  of "Live Paint: Expand":
    if d != nil: d.expandLivePaint()
  of "Intertwine: Make":
    intertwineOn = not intertwineOn
    lpBucket = false
    status = if intertwineOn: "Intertwine: click where the two picked objects cross" else: ""
  of "Pattern Options": togglePanel("patternoptions")
  of "Relight...":
    if d != nil: d.startRelight()
  of "Remove with Its Shadow":
    if d != nil: d.removeWithShadow()
  of "Upscale...":
    if d != nil: upDlg = (true, 0, 35)
  of "Mockups...":
    if d != nil: mockDlg.open = true
    if mockDlg.color == 0: mockDlg.color = 0xFFF4F4F4'u32
  of "Styles and Fonts": togglePanel("designstyles")
  of "Tidy Up":
    if d != nil: d.tidyUpPicked()
  of "Lift Subject":
    if d != nil: d.liftSubject()
  of "Make Photo Placeholder":
    if d != nil:
      if d.current.isShape:
        let L = d.current
        d.layersChange("Photo Placeholder"): L.attrs.placeholder = 1
        status = "A photo placeholder: double-click it (Move tool) to put a photo in"
      else:
        let w = d.w.float
        let h = d.h.float
        d.layersChange("Photo Placeholder"):
          let L = d.addShapeLayer(ShapeData(path: rectPath(w * 0.25, h * 0.25, w * 0.75, h * 0.75),
                                            fill: solidPaint(0xFFC8C8C8'u32), kind: "Rectangle"), "Photo Placeholder")
          L.attrs.placeholder = 1
          d.cur = d.layers.find(L)
  of "Show Layer Sizes":
    prefs.layerSizes = not prefs.layerSizes
    savePrefs()
  of "AI Connector...": aiDlg.open = true
  of "Ask AI...": showPanel("assistant")
  of "Generative Fill...":
    if d != nil: genDlg = (true, 0, "", 0, 0)
  of "Generative Expand...":
    if d != nil: genDlg = (true, 1, "", d.w + d.w div 4, d.h + d.h div 4)
  of "Generate Image...":
    if d != nil: genDlg = (true, 2, genDlg.prompt, 0, 0)
  else: result = false

proc makersDialogs() =
  meshDialog()
  relightDialog()
  upscaleDialog()
  mockupDialog()
  aiDialogs()
  genDialog()

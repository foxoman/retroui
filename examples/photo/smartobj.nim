# (included by photo.nim) Smart Objects (Layer > Smart Objects: what a
# layer holds kept, scaled and turned again without loss, its filters
# changed later: Smart Filters), Warp, Puppet Warp, Perspective Warp (on
# the image, with handles) and the Blur Gallery. (The work is in
# retroui/photowarp.)

# ---- Smart Objects ------------------------------------------------------------------------------------------

const smartTransforms = ["Free", "Scale", "Skew", "Perspective", "Distort", "Flip Layer Horizontal",
                         "Flip Layer Vertical", "Warp", "Perspective Warp...", "Puppet Warp"]

var
  smartEdits: seq[tuple[child, parent: Doc; layer: Layer]]   ## Edit Contents: the windows open
  smartEditFilter = -1           ## the Smart Filter being changed in the filter's box (-1: a new one)
  replacePick = false
  replacePath = ""
  exportSmartPick = false
  exportSmartPath = ""

proc smartFilterFn(f: SmartFilter): FilterFn =
  if filters.hasKey(f.name): filters[f.name].make(f.args) else: nil

proc renderSmartLayer(d: Doc; L: Layer) =
  ## A Smart Object's pixels drawn again from what it holds.
  if L.smart == nil: return
  d.touch(L, d.bounds)
  L.px = renderSmart(L.smart, d.w, d.h, smartFilterFn)
  inc L.ver
  d.markAll()

proc smartOk(name: string): bool =
  ## What a Smart Object takes without being rasterized: its filters, the
  ## transforms.
  filters.hasKey(name.strip(chars = {'.'})) or name in smartTransforms

proc addSmartFilter(d: Doc; name: string; vals: seq[float]): bool =
  ## A filter on a Smart Object: a Smart Filter (true), done again whenever
  ## the object changes.
  let L = d.current
  if not L.isSmart or d.quickMask or d.editMask: return false
  var fs = L.smart.filters
  if smartEditFilter in 0 .. fs.high and fs[smartEditFilter].name == name:
    fs[smartEditFilter].args = vals
  else:
    fs.add SmartFilter(name: name, args: vals, opacity: 100)
  smartEditFilter = -1
  d.layersChange("Smart Filter: " & name):
    L.smart = L.smart.withFilters(fs)
    d.renderSmartLayer(L)
  true

proc editSmartFilter(d: Doc; L: Layer; k: int) =
  ## A Smart Filter's box again, with its settings (OK changes it).
  if not L.isSmart or k notin 0 .. L.smart.filters.high: return
  let f = L.smart.filters[k]
  if not filters.hasKey(f.name): return
  smartEditFilter = k
  lastFilter = (true, f.name, f.args)
  startFilter(f.name)

proc convertToSmart(d: Doc) =
  ## Layer > Smart Objects > Convert to Smart Object: the layer's pixels (all
  ## that is not transparent) kept as they are, to be scaled and filtered
  ## without loss.
  let L = d.current
  if L.group or L.adjust.kind.len > 0 or L.isSmart:
    status = "Pick a layer of pixels"
    return
  if L.isText or L.isShape:
    d.layersChange("Rasterize"):
      if L.isText: d.rasterizeText(L) else: d.rasterizeShape(L)
  let r = d.contentBounds(L)
  if r.w <= 0:
    status = "The layer is empty"
    return
  d.layersChange("Convert to Smart Object"):
    if L.background:
      L.background = false
      if L.name == "Background": L.name = "Layer 0"
    L.smart = smartOf(L.px, d.w, d.h, r, L.name)

proc rasterizeSmart(d: Doc) =
  let L = d.current
  if not L.isSmart: return
  d.layersChange("Rasterize Smart Object"): L.smart = nil

proc smartViaCopy(d: Doc) =
  ## New Smart Object via Copy: another, independent one.
  let L = d.current
  if not L.isSmart: return
  d.layersChange("New Smart Object via Copy"):
    let n = d.newLayer(L.name & " copy")
    n.px = L.px
    n.opacity = L.opacity
    n.mode = L.mode
    n.smart = L.smart.withQuad(L.smart.quad)
    d.insertLayer(n)

var placeInto = false   ## the next Place goes into the current layer (clipped to it, covering it)

proc placeSmart(d: Doc; path: string) =
  ## File > Place: the picture as a Smart Object in the middle (smaller to
  ## fit, only as shown: what it holds stays whole). Place Into: over the
  ## current layer (type, a shape, a frame), as big as it needs to cover
  ## it, clipped to it -- the photo inside the letters. An SVG comes in as
  ## shape layers (vectors), half the image's size.
  if path.toLowerAscii.endsWith(".svg") and not placeInto:
    try:
      let data = readFile(path)
      let side = min(d.w, d.h).float * 0.5
      let box = if d.hasSelection: d.clip(d.selBounds)
                else: rect(int((d.w.float - side) / 2), int((d.h.float - side) / 2), int(side), int(side))
      d.beginStep("Place SVG")
      d.touchLayers()
      discard d.placeSvg(data, box)
      d.endStep()
      status = path.extractFilename & ": shape layers (sharp at any size)"
    except CatchableError: status = "Could not place " & path.extractFilename & ": " & getCurrentExceptionMsg()
    return
  let into = placeInto
  placeInto = false
  let base = d.current
  let target = if into: d.layerBox(base) else: rect(0, 0, 0, 0)
  try:
    beginBusy("Placing " & path.extractFilename)
    try:
      let src = openPicture(path)
      let px = src.flattened()
      var file = ""
      if src.layers.len > 1 and src.w * src.h <= 25_000_000:
        let tmp = getTempDir() / "retro-photo-place.rpd"
        src.saveRpd(tmp)
        file = readFile(tmp)
        removeFile(tmp)
      var k = min(1.0, min(d.w / src.w, d.h / src.h))
      if target.w > 0 and target.h > 0: k = max(target.w / src.w, target.h / src.h)
      let w = src.w.float * k
      let h = src.h.float * k
      let x = if target.w > 0: target.x.float + (target.w.float - w) / 2 else: (d.w.float - w) / 2
      let y = if target.w > 0: target.y.float + (target.h.float - h) / 2 else: (d.h.float - h) / 2
      d.layersChange("Place"):
        let L = d.newLayer(path.splitFile.name)
        L.smart = SmartData(src: px, w: src.w, h: src.h, name: path.extractFilename, file: file,
                            quad: [(x, y), (x + w, y), (x + w, y + h), (x, y + h)])
        d.insertLayer(L)
        d.renderSmartLayer(L)
        if target.w > 0 and not base.background:
          L.clipped = true
          d.markAll()
    finally: endBusy()
    status = if target.w > 0: "Placed " & path.extractFilename & " into " & base.name &
                              " (clipped to it: move it with the Move tool, Ctrl+T to size it)"
             else: "Placed " & path.extractFilename & " (a Smart Object: Ctrl+T scales it without loss)"
  except CatchableError:
    status = "Could not place " & path.extractFilename & ": " & getCurrentExceptionMsg()

proc editSmartContents(d: Doc; L: Layer) =
  ## Layer > Smart Objects > Edit Contents: what it holds, in a window of
  ## its own; saving it (Ctrl+S) puts it back.
  if not L.isSmart: return
  for e in smartEdits:
    if e.layer == L:
      for dw in docs:
        if dw.doc == e.child:
          active = dw
          mdiActivate(dw.win, "ws")
          return
  var child: Doc = nil
  if L.smart.file.len > 0:
    try:
      let tmp = getTempDir() / "retro-photo-contents.rpd"
      writeFile(tmp, L.smart.file)
      child = loadRpd(tmp)
      removeFile(tmp)
    except CatchableError: child = nil
  if child == nil:
    child = newDoc(L.smart.w, L.smart.h, 0, d.dpi, L.name)
    child.layers[0].px = L.smart.src
    child.layers[0].background = false
    child.layers[0].name = "Layer 1"
    inc child.layers[0].ver
    child.markAll()
  child.name = L.name & " (contents)"
  child.path = ""
  child.modified = false
  child.clearHistory()
  smartEdits.add (child, d, L)
  addDoc(child)
  status = "Edit, then File > Save (Ctrl+S): the Smart Object takes it"

proc saveSmartChild(dw: DocWin): bool =
  ## Saving the contents of a Smart Object: into it (true), not a file.
  for i, e in smartEdits:
    if e.child != dw.doc: continue
    result = true
    var parentOpen = false
    for o in docs:
      if o.doc == e.parent: parentOpen = true
    if not parentOpen or e.layer notin e.parent.layers or not e.layer.isSmart:
      status = "The Smart Object is gone: save the image with File > Save As"
      smartEdits.delete(i)
      return false
    let c = dw.doc
    var file = ""
    if c.layers.len > 1 and c.w * c.h <= 25_000_000:
      let tmp = getTempDir() / "retro-photo-contents.rpd"
      c.saveRpd(tmp)
      file = readFile(tmp)
      removeFile(tmp)
    let p = e.parent
    let L = e.layer
    p.layersChange("Edit Contents"):
      L.smart = L.smart.withSource(c.flattened(), c.w, c.h, file)
      p.renderSmartLayer(L)
    c.modified = false
    status = "The Smart Object took the changes"
    return

proc smartCommand(d: Doc; name: string): bool =
  ## The Smart Object commands (true when `name` was one).
  result = true
  case name
  of "Convert to Smart Object": d.convertToSmart()
  of "Rasterize Smart Object": d.rasterizeSmart()
  of "New Smart Object via Copy": d.smartViaCopy()
  of "Edit Contents":
    if d.current.isSmart: d.editSmartContents(d.current)
  of "Replace Contents...":
    if d.current.isSmart:
      proc go() =
        if replacePath.len == 0: replacePath = picturesDir()
        replacePick = true
      if askStorage(AppName, filesWhy, go): go()
  of "Export Contents...":
    if d.current.isSmart:
      proc go() =
        exportSmartPath = picturesDir() / d.current.name & ".png"
        exportSmartPick = true
      if askStorage(AppName, filesWhy, go): go()
  else: result = false

proc smartObjectItems(d: Doc) =
  ## Layer > Smart Objects.
  let some = d != nil
  let sm = some and d.current.isSmart
  for (n, on) in [("Convert to Smart Object", some and not sm and not d.current.group and
                                              d.current.adjust.kind.len == 0),
                  ("New Smart Object via Copy", sm), ("Edit Contents", sm), ("Replace Contents...", sm),
                  ("Export Contents...", sm), ("Rasterize Smart Object", sm)]:
    if menuItem(n, enabled = on): runCommand(n)

proc smartFiles() =
  let d = cur()
  if filePicker(replacePick, replacePath, fmOpen, openPatterns, "Replace Contents"):
    if d != nil and d.current.isSmart:
      try:
        let src = openPicture(replacePath)
        let L = d.current
        d.layersChange("Replace Contents"):
          L.smart = L.smart.withSource(src.flattened(), src.w, src.h)
          d.renderSmartLayer(L)
      except CatchableError:
        status = "Could not read " & replacePath.extractFilename
  if filePicker(exportSmartPick, exportSmartPath, fmSave, ["*.png"], "Export Contents"):
    if d != nil and d.current.isSmart:
      var p = exportSmartPath
      if p.splitFile.ext.len == 0: p &= ".png"
      try:
        let b = newBitmap(d.current.smart.w, d.current.smart.h)
        b.px = d.current.smart.src
        writeFile(p, encodePng(b))
        status = "Saved " & p.extractFilename
      except CatchableError:
        status = "Could not save " & p.extractFilename

# ---- Warp, Puppet Warp, Perspective Warp: on the image ---------------------------------------------------------

type WarpKind = enum wkNone, wkWarp = "Warp", wkPuppet = "Puppet Warp", wkPersp = "Perspective Warp"

var wm: tuple[kind: WarpKind; dw: DocWin; layer: Layer; r: Rect; orig: seq[uint32]; smart0: SmartData;
              mesh: WarpMesh; style: int; bend, hd, vd: int; grab: int; start: (float, float); from0: MeshPt;
              pins, moved: seq[MeshPt]; mode: int; density: int; showMesh: bool;
              q0, q1: Quad; layout: bool; vacated: uint32]

proc modeOn(dw: DocWin): bool = wm.kind != wkNone and wm.dw == dw

proc wmApply() =
  ## The layer as the handles say.
  let d = wm.dw.doc
  let L = wm.layer
  case wm.kind
  of wkWarp:
    if wm.smart0 != nil:
      L.smart = wm.smart0.withWarp(if wm.mesh.isIdentity: @[] else: @(wm.mesh))
      d.renderSmartLayer(L)
      return
    L.px = warpRect(wm.orig, d.w, d.h, wm.r, wm.mesh, wm.vacated)
  of wkPuppet:
    if wm.pins.len == 0:
      L.px = wm.orig
    else:
      L.px = puppetWarp(wm.orig, d.w, d.h, wm.r, wm.pins, wm.moved, PuppetMode(clamp(wm.mode, 0, 2)),
                        [24, 12, 6][clamp(wm.density, 0, 2)])
      if L.background:
        for i in 0 ..< L.px.len:
          if (L.px[i] shr 24) < 255: L.px[i] = blendPx(wm.vacated, L.px[i], 255, bmNormal)
  of wkPersp:
    if wm.layout: return
    let h = squareToQuad(wm.q1) * inverse3(squareToQuad(wm.q0))
    if wm.smart0 != nil:
      var q: Quad
      for k in 0 .. 3: q[k] = h.apply(wm.smart0.quad[k][0], wm.smart0.quad[k][1])
      L.smart = wm.smart0.withQuad(q)
      d.renderSmartLayer(L)
      return
    L.px = warp(Img(w: d.w, h: d.h, px: wm.orig), h, d.w, d.h)
    if L.background:
      for i in 0 ..< L.px.len:
        if (L.px[i] shr 24) < 255: L.px[i] = blendPx(wm.vacated, L.px[i], 255, bmNormal)
  of wkNone: discard
  inc L.ver
  d.markAll()

proc startWarpMode(kind: WarpKind) =
  let dw = active
  if dw == nil: return
  let d = dw.doc
  let L = d.current
  if L.group or L.adjust.kind.len > 0 or L.isText or L.isShape:
    status = "Pick a layer of pixels or a Smart Object"
    return
  if L.locked:
    status = "\"" & L.name & "\" is locked"
    return
  if xf.on: finishTransform(true)
  var r = if d.hasSelection and not L.isSmart and kind == wkWarp: d.clip(d.selBounds) else: d.contentBounds(L)
  if L.isSmart:
    var x0, y0 = 1e18
    var x1, y1 = -1e18
    for (x, y) in L.smart.quad:
      x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
    r = rect(int(floor(x0)), int(floor(y0)), max(1, int(ceil(x1 - x0))), max(1, int(ceil(y1 - y0))))
  if r.w <= 1 or r.h <= 1:
    status = "The layer is empty"
    return
  d.beginStep($kind)
  d.touch(L, d.bounds)
  d.touchLayers()
  wm = (kind, dw, L, r, L.px, (if L.isSmart: L.smart else: nil), identityMesh(), 0, 50, 0, 0, -1, (0.0, 0.0),
        (0.0, 0.0), newSeq[MeshPt](), newSeq[MeshPt](), 0, 1, true, quadOf(r), quadOf(r), true,
        (if L.background: bg or 0xFF000000'u32 else: 0'u32))
  if kind == wkWarp and L.isSmart and L.smart.warp.len == 16:
    for k in 0 .. 15: wm.mesh[k] = L.smart.warp[k]
  if kind == wkPersp:
    # the plane at first: the middle half of the layer
    let q = quadOf(rect(r.x + r.w div 4, r.y + r.h div 4, max(2, r.w div 2), max(2, r.h div 2)))
    wm.q0 = q
    wm.q1 = q
  status = case kind
           of wkWarp: "Warp: drag the points of the grid, or pick a style in the options bar; Enter to finish"
           of wkPuppet: "Puppet Warp: click to put pins, drag them; Alt+click takes one away; Enter to finish"
           of wkPersp: "Perspective Warp: drag the corners onto a plane of the picture (Layout), then Warp"
           else: ""

proc modeFinish(ok: bool) =
  if wm.kind == wkNone: return
  let d = wm.dw.doc
  if ok:
    if wm.kind == wkPersp and wm.layout:
      wm.layout = false                      # (Enter in Layout: on to Warp)
      return
    d.endStep()
  else:
    d.cancelStep()
  wm.kind = wkNone
  wm.orig = @[]
  wm.smart0 = nil
  status = ""

proc meshScreen(m: WarpMesh; u, v: float): MeshPt =
  ## A point of the grid in the image (for the handles).
  let (bu, bv) = m.meshPoint(u, v)
  if wm.smart0 != nil:
    let q = squareToQuad(wm.smart0.quad)
    let w = q[6] * bu + q[7] * bv + q[8]
    let k = if abs(w) < 1e-12: 1e12 else: 1 / w
    return ((q[0] * bu + q[1] * bv + q[2]) * k, (q[3] * bu + q[4] * bv + q[5]) * k)
  (wm.r.x.float + bu * wm.r.w.float, wm.r.y.float + bv * wm.r.h.float)

proc toMesh(x, y: float): MeshPt =
  ## An image point in the grid's terms (0..1).
  if wm.smart0 != nil:
    let inv = inverse3(squareToQuad(wm.smart0.quad))
    let w = inv[6] * x + inv[7] * y + inv[8]
    let k = if abs(w) < 1e-12: 1e12 else: 1 / w
    return ((inv[0] * x + inv[1] * y + inv[2]) * k, (inv[3] * x + inv[4] * y + inv[5]) * k)
  ((x - wm.r.x.float) / max(1, wm.r.w).float, (y - wm.r.y.float) / max(1, wm.r.h).float)

proc modeMouse(dw: DocWin; ev: PhotoEvent) =
  let d = dw.doc
  let v = dw.view
  let near = dp(7)
  proc hits(x, y: float): bool =
    let (sx, sy) = v.toScreen(d, x, y)
    abs(sx - ui.mx) <= near and abs(sy - ui.my) <= near
  if ev.pressed:
    wm.grab = -1
    wm.start = (ev.x, ev.y)
    case wm.kind
    of wkWarp:
      for k in 0 .. 15:
        let p = meshScreen(wm.mesh, (k mod 4) / 3, (k div 4) / 3)
        if hits(p[0], p[1]):
          wm.grab = k
          wm.from0 = wm.mesh[k]
      if wm.grab < 0 and ev.clicks >= 2: modeFinish(true)
    of wkPuppet:
      for k in 0 ..< wm.moved.len:
        if hits(wm.moved[k][0], wm.moved[k][1]): wm.grab = k
      if wm.grab >= 0 and ev.alt:
        wm.pins.delete(wm.grab)
        wm.moved.delete(wm.grab)
        wm.grab = -1
        wmApply()
      elif wm.grab < 0 and not ev.alt:
        let x = ev.x
        let y = ev.y
        if x >= wm.r.x.float and y >= wm.r.y.float and x < (wm.r.x + wm.r.w).float and
           y < (wm.r.y + wm.r.h).float:
          # (a pin where the picture is now: where it was before the pins moved it)
          var sx = x
          var sy = y
          if wm.pins.len > 0:
            # (found by going back from the moved pins to where they were)
            let (bx, by) = puppetPoint(wm.moved, wm.pins, x, y, PuppetMode(clamp(wm.mode, 0, 2)))
            sx = bx
            sy = by
          wm.pins.add (sx, sy)
          wm.moved.add (x, y)
          wm.grab = wm.moved.high
      if wm.grab >= 0: wm.from0 = wm.moved[wm.grab]
    of wkPersp:
      let q = if wm.layout: wm.q0 else: wm.q1
      for k in 0 .. 3:
        if hits(q[k][0], q[k][1]): wm.grab = k
      if wm.grab < 0 and inQuad(q, ev.x, ev.y): wm.grab = 4      # (the whole of it, in Layout)
      if wm.grab >= 0: wm.from0 = (ev.x, ev.y)
      if wm.grab < 0 and ev.clicks >= 2: modeFinish(true)
    else: discard
    return
  if wm.grab < 0 or not ev.down: return
  let dx = ev.x - wm.start[0]
  let dy = ev.y - wm.start[1]
  case wm.kind
  of wkWarp:
    let a = toMesh(wm.start[0], wm.start[1])
    let b = toMesh(ev.x, ev.y)
    wm.mesh[wm.grab] = (wm.from0[0] + b[0] - a[0], wm.from0[1] + b[1] - a[1])
    wm.style = 0
    if ui.mouseMoved or ev.moved: wmApply()
  of wkPuppet:
    wm.moved[wm.grab] = (wm.from0[0] + dx, wm.from0[1] + dy)
    # (a big layer: drawn when the pin is let go)
    if wm.layer.px.len <= 3_000_000 or ev.released: wmApply()
  of wkPersp:
    if wm.layout:
      if wm.grab == 4:
        for k in 0 .. 3: wm.q0[k] = (wm.q0[k][0] + ev.x - wm.from0[0], wm.q0[k][1] + ev.y - wm.from0[1])
        wm.from0 = (ev.x, ev.y)
      else:
        var q = wm.q0
        q[wm.grab] = (ev.x, ev.y)
        if quadIsFine(q): wm.q0 = q
      wm.q1 = wm.q0
    elif wm.grab < 4:
      var q = wm.q1
      q[wm.grab] = (ev.x, ev.y)
      if quadIsFine(q):
        wm.q1 = q
        if wm.layer.px.len <= 4_000_000 or ev.released: wmApply()
  else: discard

proc modeOverlay(dw: DocWin) =
  let d = dw.doc
  let v = dw.view
  pushClip(v.view)
  proc handle(x, y: float; round = false) =
    let (hx, hy) = v.toScreen(d, x, y)
    if round:
      ellipseOnScreen(hx - 5, hy - 5, hx + 5, hy + 5, color(0, 0, 0))
      fill(rect(hx - 2, hy - 2, 5, 5), color(255, 255, 0))
      box(rect(hx - 3, hy - 3, 7, 7), color(0, 0, 0))
    else:
      fill(rect(hx - 3, hy - 3, 7, 7), color(255, 255, 255))
      box(rect(hx - 3, hy - 3, 7, 7), color(0, 0, 0))
  case wm.kind
  of wkWarp:
    # the grid's lines, bent as the picture is
    for k in 0 .. 3:
      for horizontal in [true, false]:
        var last = (0, 0)
        for s in 0 .. 24:
          let t = s / 24
          let (x, y) = if horizontal: meshScreen(wm.mesh, t, k / 3) else: meshScreen(wm.mesh, k / 3, t)
          let p = v.toScreen(d, x, y)
          if s > 0: dashedLine(last[0], last[1], p[0], p[1])
          last = p
    for k in 0 .. 15:
      let (x, y) = meshScreen(wm.mesh, (k mod 4) / 3, (k div 4) / 3)
      handle(x, y)
  of wkPuppet:
    if wm.showMesh:
      # (the grid the picture is bent on, every third line)
      let step = [24, 12, 6][clamp(wm.density, 0, 2)] * 3
      let cols = max(1, wm.r.w div step)
      let rows = max(1, wm.r.h div step)
      var pts = newSeq[(int, int)]((cols + 1) * (rows + 1))
      for j in 0 .. rows:
        for i in 0 .. cols:
          let x = wm.r.x.float + i.float * wm.r.w.float / cols.float
          let y = wm.r.y.float + j.float * wm.r.h.float / rows.float
          let (px, py) = if wm.pins.len > 0: puppetPoint(wm.pins, wm.moved, x, y, PuppetMode(clamp(wm.mode, 0, 2)))
                         else: (x, y)
          pts[j * (cols + 1) + i] = v.toScreen(d, px, py)
      for j in 0 .. rows:
        for i in 0 .. cols:
          let p = pts[j * (cols + 1) + i]
          if i < cols:
            let q = pts[j * (cols + 1) + i + 1]
            line(p[0], p[1], q[0], q[1], color(90, 90, 90))
          if j < rows:
            let q = pts[(j + 1) * (cols + 1) + i]
            line(p[0], p[1], q[0], q[1], color(90, 90, 90))
    for p in wm.moved: handle(p[0], p[1], true)
  of wkPersp:
    let q = if wm.layout: wm.q0 else: wm.q1
    var pts: array[4, (int, int)]
    for k in 0 .. 3: pts[k] = v.toScreen(d, q[k][0], q[k][1])
    for k in 0 .. 3:
      dashedLine(pts[k][0], pts[k][1], pts[(k + 1) mod 4][0], pts[(k + 1) mod 4][1])
    if wm.layout:
      # (a grid on the plane: to see that it lies on the picture's)
      let m = squareToQuad(q)
      for t in [0.25, 0.5, 0.75]:
        for horizontal in [true, false]:
          let (a0, b0) = if horizontal: (0.0, t) else: (t, 0.0)
          let (a1, b1) = if horizontal: (1.0, t) else: (t, 1.0)
          proc mp(u, w: float): (int, int) =
            let z = m[6] * u + m[7] * w + m[8]
            v.toScreen(d, (m[0] * u + m[1] * w + m[2]) / z, (m[3] * u + m[4] * w + m[5]) / z)
          let p0 = mp(a0, b0)
          let p1 = mp(a1, b1)
          dashedLine(p0[0], p0[1], p1[0], p1[1])
    for k in 0 .. 3: handle(q[k][0], q[k][1])
  else: discard
  popClip()
  wakeIn(140)

proc straightenPersp(vertical, horizontal: bool) =
  ## Perspective Warp: the plane's upright edges made upright, its level
  ## edges level.
  if wm.kind != wkPersp: return
  if wm.layout: wm.layout = false
  var q = wm.q1
  if vertical:
    let lx = (q[0][0] + q[3][0]) / 2
    let rx = (q[1][0] + q[2][0]) / 2
    q[0][0] = lx; q[3][0] = lx; q[1][0] = rx; q[2][0] = rx
  if horizontal:
    let ty = (q[0][1] + q[1][1]) / 2
    let by = (q[3][1] + q[2][1]) / 2
    q[0][1] = ty; q[1][1] = ty; q[3][1] = by; q[2][1] = by
  if quadIsFine(q):
    wm.q1 = q
    wmApply()

proc warpModeBar() =
  ## The options bar while warping: the style, its settings, OK.
  case wm.kind
  of wkWarp:
    label "Warp:"
    var names = @["Custom"]
    for s in WarpStyle:
      if s != wsNone: names.add $s
    combo(names, wm.style, w = dp(120))
    var changed = false
    label "Bend:"
    if popupSlider(wm.bend, -100, 100): changed = true
    label "H:"
    if popupSlider(wm.hd, -100, 100): changed = true
    label "V:"
    if popupSlider(wm.vd, -100, 100): changed = true
    var key {.global.} = ""
    let k2 = $wm.style & "/" & $wm.bend & "/" & $wm.hd & "/" & $wm.vd
    if wm.style > 0 and (k2 != key or changed):
      key = k2
      let r = wm.r
      wm.mesh = presetMesh(TextWarp(style: WarpStyle(wm.style), bend: wm.bend, hDistort: wm.hd, vDistort: wm.vd),
                           r.h / max(1, r.w))
      wmApply()
    if toolButton("Reset", "The grid flat again"):
      wm.mesh = identityMesh()
      wm.style = 0
      wmApply()
  of wkPuppet:
    label "Mode:"
    if combo(["Rigid", "Normal", "Distort"], wm.mode, w = dp(80)): wmApply()
    label "Density:"
    if combo(["Fewer Points", "Normal", "More Points"], wm.density, w = dp(110)): wmApply()
    checkbox("Show Mesh", wm.showMesh)
    if toolButton("Remove All Pins", enabled = wm.pins.len > 0):
      wm.pins.setLen(0)
      wm.moved.setLen(0)
      wmApply()
  of wkPersp:
    if toolButton("Layout", "Draw the plane: drag its corners onto the picture", down = wm.layout):
      wm.layout = true
      wm.q1 = wm.q0
      wm.layer.px = wm.orig
      if wm.smart0 != nil: wm.layer.smart = wm.smart0
      inc wm.layer.ver
      wm.dw.doc.markAll()
    if toolButton("Warp", "Move the plane's corners: the picture follows", down = not wm.layout):
      wm.layout = false
    toolSeparator()
    if toolButton("| |", "Make its upright edges upright"): straightenPersp(true, false)
    if toolButton("=", "Make its level edges level"): straightenPersp(false, true)
    if toolButton("#", "Both"): straightenPersp(true, true)
  else: discard
  toolSeparator()
  if toolButton("OK", "Finish (Enter)"): modeFinish(true)
  if toolButton("Cancel", "Leave it as it was (Esc)"): modeFinish(false)

# ---- the Blur Gallery ---------------------------------------------------------------------------------------

var
  bgOpen = false
  bgKind = 1                     ## Field, Iris, Tilt-Shift
  bgDoc: Doc
  bgSmall: Img
  bgK = 1.0                      ## small / full
  bgBlur = 15
  bgCx, bgCy = 0.5               ## the middle (0..1 of the image)
  bgSize = 30                    ## Iris: % of the image's shorter side
  bgAspect = 100                 ## Iris: its height, % of its width
  bgSharp = 50                   ## Iris: the sharp part, % of the way out
  bgAngle = 0                    ## Iris, Tilt-Shift: degrees
  bgBand = 10                    ## Tilt-Shift: % of the height each side
  bgFade = 15
  bgBokeh = 0                    ## Light Bokeh %
  bgPins: seq[(float, float, float)]   ## Field: x, y (0..1) and its blur
  bgPin = 0
  bgPreview: Bitmap
  bgKey = ""

proc startBlurGallery(kind: int) =
  let d = cur()
  if d == nil or not d.needPixels("Blur Gallery"): return
  bgDoc = d
  bgKind = kind
  let k = min(1.0, 340.0 / max(d.w, d.h).float)
  let pw = max(1, int(d.w.float * k))
  let ph = max(1, int(d.h.float * k))
  let small = thumbnailOf(d.layer.px, d.w, d.h, pw, ph, checker = false)
  bgSmall = Img(w: small.w, h: small.h, px: small.px)
  bgK = pw / d.w
  if bgPins.len == 0: bgPins = @[(0.3, 0.5, 0.0), (0.75, 0.5, 15.0)]
  bgKey = ""
  bgOpen = true

proc bgRadius(w, h: int; k: float): seq[float32] =
  ## The blur at each pixel, for an image `w` x `h` (`k`: its scale).
  let blur = bgBlur.float * k
  case bgKind
  of 0:
    var ps: seq[(float, float, float)]
    for (x, y, b) in bgPins: ps.add (x * w.float, y * h.float, b * k)
    fieldRadius(w, h, ps)
  of 1:
    let rx = bgSize / 100 * min(w, h).float
    irisRadius(w, h, bgCx * w.float, bgCy * h.float, rx, rx * bgAspect.float / 100, bgAngle.float, bgSharp / 100, blur)
  else:
    tiltShiftRadius(w, h, bgCx * w.float, bgCy * h.float, bgAngle.float, bgBand / 100 * h.float,
                    bgFade / 100 * h.float, blur)

proc bgMax(k: float): float =
  var m = bgBlur.float
  if bgKind == 0:
    m = 0
    for p in bgPins: m = max(m, p[2])
  max(0.0, m * k)

proc blurGalleryDialog() =
  if not bgOpen or bgDoc == nil: return
  let d = bgDoc
  var go = false
  dialog(bgOpen, "Blur Gallery", 660):
    row([350, -1]):
      col:
        let key = $bgKind & "/" & $bgBlur & "/" & $bgCx & "/" & $bgCy & "/" & $bgSize & "/" & $bgAspect & "/" &
                  $bgSharp & "/" & $bgAngle & "/" & $bgBand & "/" & $bgFade & "/" & $bgBokeh & "/" & $bgPins
        if key != bgKey or bgPreview == nil:
          let o = variableBlur(bgSmall, bgRadius(bgSmall.w, bgSmall.h, bgK), bgMax(bgK), bgBokeh / 100)
          bgPreview = newBitmap(o.w, o.h)
          bgPreview.px = o.px
          bgKey = key
        let pb = pictureBox("blurgallery", bgPreview, dp(342), dp(262))
        beginKeepSides(pb.box)
        if pb.pic.w > 0:
          # the handles: the middle (Iris, Tilt-Shift) or the pins (Field)
          pushClip(pb.box)
          let pw = pb.pic.w.float
          let ph = pb.pic.h.float
          proc at(u, v: float): (int, int) = (pb.pic.x + int(u * pw), pb.pic.y + int(v * ph))
          case bgKind
          of 0:
            for i, (x, y, b) in bgPins:
              let (hx, hy) = at(x, y)
              ellipseOnScreen(hx - 6, hy - 6, hx + 6, hy + 6, if i == bgPin: color(255, 255, 0) else: color(255, 255, 255))
              ellipseOnScreen(hx - 7, hy - 7, hx + 7, hy + 7, color(0, 0, 0))
          of 1:
            let (hx, hy) = at(bgCx, bgCy)
            let rx = int(bgSize / 100 * min(pw, ph))
            let ry = rx * bgAspect div 100
            ellipseOnScreen(hx - rx, hy - ry, hx + rx, hy + ry, color(255, 255, 255))
            let sx = rx * bgSharp div 100
            let sy = ry * bgSharp div 100
            ellipseOnScreen(hx - sx, hy - sy, hx + sx, hy + sy, color(0, 0, 0))
            fill(rect(hx - 3, hy - 3, 7, 7), color(255, 255, 255))
            box(rect(hx - 3, hy - 3, 7, 7), color(0, 0, 0))
          else:
            let (hx, hy) = at(bgCx, bgCy)
            let a = degToRad(bgAngle.float)
            let L = pw + ph
            for off in [-bgBand.float, bgBand.float, -(bgBand + bgFade).float, (bgBand + bgFade).float]:
              let o = off / 100 * ph
              let ox = -sin(a) * o
              let oy = cos(a) * o
              dashedLine(int(hx.float + ox - cos(a) * L), int(hy.float + oy - sin(a) * L),
                         int(hx.float + ox + cos(a) * L), int(hy.float + oy + sin(a) * L))
            fill(rect(hx - 3, hy - 3, 7, 7), color(255, 255, 255))
            box(rect(hx - 3, hy - 3, 7, 7), color(0, 0, 0))
          popClip()
          if pb.dragging or (ui.pressed and mouseIn(pb.pic)):
            let u = clamp((ui.mx - pb.pic.x).float / pw, 0.0, 1.0)
            let v = clamp((ui.my - pb.pic.y).float / ph, 0.0, 1.0)
            if bgKind == 0:
              if ui.pressed:
                # a pin near: picked; elsewhere: a new one
                var best = -1
                for i, (x, y, b) in bgPins:
                  if abs((x - u) * pw) < 9 and abs((y - v) * ph) < 9: best = i
                if best < 0:
                  bgPins.add (u, v, bgBlur.float)
                  best = bgPins.high
                bgPin = best
              elif bgPin in 0 .. bgPins.high:
                bgPins[bgPin] = (u, v, bgPins[bgPin][2])
            else:
              bgCx = u
              bgCy = v
        endKeepSides()
      col:
        row:
          label "Blur:"
          combo(["Field Blur", "Iris Blur", "Tilt-Shift"], bgKind, w = dp(140))
        if bgKind == 0:
          if bgPin in 0 .. bgPins.high:
            var b = int(bgPins[bgPin][2])
            if wideSlider("Pin's Blur:", b, 0, 200, " px"): bgPins[bgPin][2] = b.float
            if button("Delete the Pin", w = dp(140), enabled = bgPins.len > 1):
              bgPins.delete(bgPin)
              bgPin = 0
          label("Click the picture for a pin; drag one to move it.", color = ui.theme.gray)
        else:
          wideSlider("Blur:", bgBlur, 0, 200, " px")
          if bgKind == 1:
            wideSlider("Size:", bgSize, 2, 100, "%")
            wideSlider("Roundness:", bgAspect, 10, 300, "%")
            wideSlider("Sharp Part:", bgSharp, 0, 95, "%")
          else:
            wideSlider("Band:", bgBand, 0, 50, "%")
            wideSlider("Fade:", bgFade, 1, 60, "%")
          wideSlider("Angle:", bgAngle, -90, 90, "°")
          label("Drag on the picture to move its middle.", color = ui.theme.gray)
        group("Effects"):
          wideSlider("Light Bokeh:", bgBokeh, 0, 100, "%")
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): go = true
      if button("Cancel", w = dp(80)): bgOpen = false
  if go:
    bgOpen = false
    let name = ["Field Blur", "Iris Blur", "Tilt-Shift"][clamp(bgKind, 0, 2)]
    let rad = bgRadius(d.w, d.h, 1.0)
    let mx = bgMax(1.0)
    let bok = bgBokeh / 100
    let wr = d.workRect
    let dw0 = d.w
    let dh0 = d.h
    beginBusy(name)
    try:
      d.beginStep(name)
      d.applyFilter(int(mx * 2) + 2, proc (src: Img; inner: Rect): Img =
        # (`src` is the part worked on with room round it: where each of its
        # pixels is in the image)
        var rr = newSeq[float32](src.w * src.h)
        for y in 0 ..< src.h:
          for x in 0 ..< src.w:
            let ix = clamp(wr.x - inner.x + x, 0, dw0 - 1)
            let iy = clamp(wr.y - inner.y + y, 0, dh0 - 1)
            rr[y * src.w + x] = rad[iy * dw0 + ix]
        variableBlur(src, rr, mx, bok))
      d.endStep()
    finally: endBusy()

proc smartDialogs() =
  smartFiles()
  blurGalleryDialog()

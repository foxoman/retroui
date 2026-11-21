# (included by photo.nim) Quick design work, as the simple design apps have
# it: File > Resize for... (a design made again at many sizes at once),
# the Brand Kit (your colors, fonts and logo, a click away), Layout > Photo
# Grid (frames to drop pictures into), Type > Text Effects (ready looks for
# type) and Image > Recolor Design (the whole design in a palette).

type
  BrandKit = object
    colors: seq[uint32]
    heading, body: string        ## the fonts
    logo: string                 ## a picture file

var
  rsDlg: tuple[open: bool; picks: seq[bool]; cover: bool]
  brandDlg = false
  brand: BrandKit
  brandLoaded = false
  gridDlg: tuple[open: bool; layout, gap, radius, margin: int] = (false, 2, 12, 16, 24)
  fxDlg = false
  recolorDlg: tuple[open: bool; palette: int]
  recolorFrom: tuple[doc: int; name: string; cols: seq[uint32]]   ## (a palette taken from a picture)

const
  resizeTargets = [("Square Post", 1080, 1080), ("Portrait Post", 1080, 1350), ("Story", 1080, 1920),
                   ("Wide Post", 1200, 628), ("Cover, Wide", 1640, 624), ("Header, Narrow", 1500, 500),
                   ("Video Thumbnail", 1280, 720), ("Banner", 1584, 396), ("Presentation", 1920, 1080),
                   ("A4 Poster (150 ppi)", 1240, 1754), ("A5 Flyer (150 ppi)", 874, 1240),
                   ("Business Card (300 ppi)", 1004, 650)]
  gridLayouts = ["Two side by side", "Three side by side", "Two by two", "Three by three", "One big, two beside",
                 "One big, three under", "Two above, one wide under", "Mosaic of five"]
  textLooks = ["Shadow", "Lift", "Hollow", "Outline", "Neon", "Echo", "Glow", "Curve", "None"]
  palettes = [("Sea", [0xFF03045E'u32, 0xFF0077B6'u32, 0xFF00B4D8'u32, 0xFF90E0EF'u32, 0xFFCAF0F8'u32]),
              ("Desert", [0xFF5F0F40'u32, 0xFF9A031E'u32, 0xFFFB8B24'u32, 0xFFE36414'u32, 0xFFF3E9DC'u32]),
              ("Forest", [0xFF081C15'u32, 0xFF1B4332'u32, 0xFF40916C'u32, 0xFF95D5B2'u32, 0xFFD8F3DC'u32]),
              ("Candy", [0xFF3A0CA3'u32, 0xFF7209B7'u32, 0xFFF72585'u32, 0xFF4CC9F0'u32, 0xFFFFF1F9'u32]),
              ("Earth", [0xFF283618'u32, 0xFF606C38'u32, 0xFFBC6C25'u32, 0xFFDDA15E'u32, 0xFFFEFAE0'u32]),
              ("Gulf", [0xFF1F3A5F'u32, 0xFF8C6D1F'u32, 0xFFC8102E'u32, 0xFFE9B44C'u32, 0xFFFBF7F0'u32]),
              ("Mono", [0xFF111111'u32, 0xFF444444'u32, 0xFF888888'u32, 0xFFCCCCCC'u32, 0xFFFAFAFA'u32]),
              ("Night", [0xFF0B132B'u32, 0xFF1C2541'u32, 0xFF3A506B'u32, 0xFF5BC0BE'u32, 0xFFE8EEF5'u32])]

# ---- Resize for -------------------------------------------------------------------------------------------

proc copyOfDoc(d: Doc): Doc =
  ## (a document as it is, all of it, apart from it)
  let tmp = getTempDir() / "retro-photo-resize.rpd"
  d.saveRpd(tmp)
  result = loadRpd(tmp)
  removeFile(tmp)

proc resizedCopy*(d: Doc; tw, th: int; cover: bool): Doc =
  ## The design at another size: all of it scaled to fit (`cover`: to fill,
  ## cut at the sides), in the middle, the background drawn out to the edges.
  result = copyOfDoc(d)
  let k = if cover: max(tw / d.w, th / d.h) else: min(tw / d.w, th / d.h)
  let nw = max(1, int(d.w.float * k + 0.5))
  let nh = max(1, int(d.h.float * k + 0.5))
  result.imageSize(nw, nh)
  var bgc = 0xFFFFFFFF'u32
  if result.layers.len > 0 and result.layers[0].background and result.layers[0].px.len > 0:
    bgc = result.layers[0].px[0] or 0xFF000000'u32
  result.canvasSizeAt(tw, th, (tw - nw) div 2, (th - nh) div 2, bgc)

proc resizeDialog() =
  if not rsDlg.open: return
  let d = cur()
  if d == nil:
    rsDlg.open = false
    return
  if rsDlg.picks.len != resizeTargets.len: rsDlg.picks = newSeq[bool](resizeTargets.len)
  var go = false
  dialog(rsDlg.open, "Resize for", 420):
    label("The design made again at each size picked, each a document of its own:", color = ui.theme.gray)
    for i, (name, w, h) in resizeTargets:
      checkbox(tr(name) & "  (" & $w & " x " & $h & ")", rsDlg.picks[i])
    row:
      var c = if rsDlg.cover: 1 else: 0
      if radio("Fit all of it", c, 0) or radio("Fill the size (cut at the sides)", c, 1): rsDlg.cover = c == 1
    row:
      spring()
      var n = 0
      for p in rsDlg.picks:
        if p: inc n
      if button("Resize", isDefault = true, w = dp(90), enabled = n > 0): go = true
      if button("Cancel", w = dp(80)): rsDlg.open = false
  if go:
    rsDlg.open = false
    var made = 0
    beginBusy("Resizing")
    try:
      for i, (name, w, h) in resizeTargets:
        if not rsDlg.picks[i]: continue
        try:
          let r = resizedCopy(d, w, h, rsDlg.cover)
          r.name = d.name.changeFileExt("") & " - " & name
          r.path = ""
          r.modified = true
          addDoc(r)
          inc made
        except CatchableError: status = "Could not make " & name & ": " & getCurrentExceptionMsg()
    finally: endBusy()
    if made > 0: status = $made & (if made == 1: " size made" else: " sizes made") & ", each a document"

# ---- the Brand Kit ----------------------------------------------------------------------------------------

proc brandFile(): string = dataDir(AppData) / "Brand Kit.json"

proc loadBrand() =
  if brandLoaded: return
  brandLoaded = true
  try:
    let j = parseJson(readFile(brandFile()))
    for c in j{"colors"}.getElems: brand.colors.add uint32(c.getBiggestInt(0) and 0xFFFFFFFF'i64)
    brand.heading = j{"heading"}.getStr("")
    brand.body = j{"body"}.getStr("")
    brand.logo = j{"logo"}.getStr("")
  except CatchableError: discard
  if brand.colors.len == 0: brand.colors = @[0xFF1F3A5F'u32, 0xFFE9B44C'u32, 0xFFC8102E'u32, 0xFFFBF7F0'u32]

proc saveBrand() =
  var cs = newJArray()
  for c in brand.colors: cs.add %int64(c)
  try:
    createDir(brandFile().parentDir)
    writeFile(brandFile(), $(%*{"colors": cs, "heading": brand.heading, "body": brand.body, "logo": brand.logo}))
  except CatchableError: status = "Could not keep the Brand Kit: " & getCurrentExceptionMsg()

proc applyBrandFonts(d: Doc) =
  ## (every type layer: the heading font where its type is big, the body font elsewhere)
  if d == nil: return
  d.beginStep("Brand Fonts")
  d.touchLayers()
  var n = 0
  for L in d.layers:
    if not L.isText or L.locked or L.fromMaster != 0 or L.fromSpan != 0: continue
    var t = L.text
    for sp in t.spans.mitems:
      let f = if sp.style.size >= 24: brand.heading else: brand.body
      if f.len > 0:
        sp.style.family = f
        if fontStyles(f).find(sp.style.style) < 0: sp.style.style = "Regular"
    d.setText(L, t)
    inc n
  d.endStep()
  d.markAll()
  status = "Brand fonts on " & $n & (if n == 1: " type layer" else: " type layers")

proc recolor(d: Doc; pal: openArray[uint32]; name: string) =
  ## Recolor Design: the shapes' fills and strokes and the type's colors, the darkest to the
  ## palette's darkest and so on (light to light), in one step
  if d == nil or pal.len == 0: return
  proc lum(c: uint32): int = int((c shr 16) and 255) * 3 + int((c shr 8) and 255) * 6 + int(c and 255)
  var used: seq[uint32]
  for L in d.layers:
    if L.locked: continue
    if L.isShape:
      for c in [L.shape.fill.color, L.shape.stroke.color]:
        let cc = c or 0xFF000000'u32
        if (L.shape.fill.kind == spColor or L.shape.stroke.kind == spColor) and cc notin used: used.add cc
    elif L.isText:
      for sp in L.text.spans:
        let cc = sp.style.color or 0xFF000000'u32
        if cc notin used: used.add cc
  if used.len == 0:
    status = "Recolor: no shapes or type to recolor"
    return
  var byLum = used
  byLum.sort(proc (a, b: uint32): int = cmp(lum(a), lum(b)))
  var pl = @pal
  pl.sort(proc (a, b: uint32): int = cmp(lum(a), lum(b)))
  proc mapped(c: uint32): uint32 =
    let i = byLum.find(c or 0xFF000000'u32)
    if i < 0: return c
    let j = if byLum.len == 1: pl.high div 2 else: int(round(i / byLum.high * pl.high.float))
    (pl[clamp(j, 0, pl.high)] and 0x00FFFFFF'u32) or (c and 0xFF000000'u32)
  d.beginStep("Recolor Design")
  d.touchLayers()
  for L in d.layers:
    if L.locked: continue
    if L.isShape:
      var s = L.shape
      if s.fill.kind == spColor: s.fill.color = mapped(s.fill.color)
      if s.stroke.kind == spColor: s.stroke.color = mapped(s.stroke.color)
      d.setShape(L, s)
    elif L.isText:
      var t = L.text
      for sp in t.spans.mitems: sp.style.color = mapped(sp.style.color)
      d.setText(L, t)
  d.endStep()
  d.markAll()
  status = "Recolored in " & name & ": " & $used.len & " colors"

proc brandDialog() =
  if not brandDlg: return
  loadBrand()
  let d = cur()
  var changed = false
  dialog(brandDlg, "Brand Kit", 420):
    label("Colors (a click: the foreground color):", bold = true)
    row:
      var del = -1
      for i in 0 ..< brand.colors.len:
        var c = brand.colors[i]
        if colorWell(c, "brand" & $i, dp(36)):
          brand.colors[i] = c or 0xFF000000'u32
          changed = true
        if toolButton("×", "Take this color out"): del = i
      if del >= 0:
        brand.colors.delete(del)
        changed = true
      if brand.colors.len < 10 and button("+", w = dp(30)):
        brand.colors.add fg or 0xFF000000'u32
        changed = true
    row:
      for i, c in brand.colors:
        if button($(i + 1), w = dp(30)): fg = c
    row([110, -1]):
      label "Heading font:"
      var hf = if brand.heading.len > 0: brand.heading else: "FreeSans"
      if fontCombo(hf, w = dp(200)):
        brand.heading = hf
        changed = true
    row([110, -1]):
      label "Body font:"
      var bf = if brand.body.len > 0: brand.body else: "FreeSerif"
      if fontCombo(bf, w = dp(200)):
        brand.body = bf
        changed = true
    row([110, -1]):
      label "Logo:"
      if edit(brand.logo): changed = true
    row:
      if button("Brand fonts on the type", enabled = d != nil): d.applyBrandFonts()
      if button("Recolor in the brand", enabled = d != nil): d.recolor(brand.colors, "the brand's colors")
    row:
      if button("Place the logo", enabled = d != nil and brand.logo.len > 0 and fileExists(brand.logo)):
        d.placeSmart(brand.logo)
      spring()
      if button("Close", isDefault = true, w = dp(80)): brandDlg = false
  if changed: saveBrand()

# ---- Photo Grid -------------------------------------------------------------------------------------------

proc gridCells*(layout: int; r: Rect; gap: int): seq[Rect] =
  ## The frames of a photo grid's layout in `r`, `gap` apart.
  let g = gap
  proc cols(n: int; rr: Rect): seq[Rect] =
    let w = (rr.w - g * (n - 1)) div n
    for i in 0 ..< n: result.add rect(rr.x + i * (w + g), rr.y, w, rr.h)
  proc rows(n: int; rr: Rect): seq[Rect] =
    let h = (rr.h - g * (n - 1)) div n
    for i in 0 ..< n: result.add rect(rr.x, rr.y + i * (h + g), rr.w, h)
  case layout
  of 0: result = cols(2, r)
  of 1: result = cols(3, r)
  of 2:
    for rr in rows(2, r): result.add cols(2, rr)
  of 3:
    for rr in rows(3, r): result.add cols(3, rr)
  of 4:
    let big = rect(r.x, r.y, (r.w - g) * 2 div 3, r.h)
    result.add big
    result.add rows(2, rect(big.x + big.w + g, r.y, r.w - big.w - g, r.h))
  of 5:
    let big = rect(r.x, r.y, r.w, (r.h - g) * 2 div 3)
    result.add big
    result.add cols(3, rect(r.x, big.y + big.h + g, r.w, r.h - big.h - g))
  of 6:
    let top = rect(r.x, r.y, r.w, (r.h - g) div 2)
    result.add cols(2, top)
    result.add rect(r.x, top.y + top.h + g, r.w, r.h - top.h - g)
  else:
    let left = rect(r.x, r.y, (r.w - g) div 2, r.h)
    result.add rows(2, left)
    result.add rows(3, rect(left.x + left.w + g, r.y, r.w - left.w - g, r.h))

proc makePhotoGrid() =
  let d = cur()
  if d == nil: return
  var area = rect(gridDlg.margin, gridDlg.margin, d.w - 2 * gridDlg.margin, d.h - 2 * gridDlg.margin)
  let bw = curBook()
  if bw != nil: area = bw.book.marginBox(bw.page)
  if d.hasSelection: area = d.clip(d.selBounds)
  let cells = gridCells(gridDlg.layout, area, gridDlg.gap)
  d.beginStep("Photo Grid")
  d.touchLayers()
  var idxs: seq[int]
  for i, c in cells:
    if c.w < 2 or c.h < 2: continue
    let L = d.addShapeLayer(ShapeData(path: rectPath(c.x.float, c.y.float, float(c.x + c.w), float(c.y + c.h),
                                                     gridDlg.radius.float),
                                      fill: solidPaint(0xFFD6D6D6'u32), kind: "Rectangle",
                                      radius: gridDlg.radius.float), "Photo " & $(i + 1))
    idxs.add d.layers.find(L)
  let g = d.groupLayers(idxs, "Photo Grid")
  if g != nil: d.cur = d.layers.find(g)
  d.endStep()
  d.markAll()
  status = "A photo grid of " & $idxs.len & " frames: pick one, then Layer > Place Into puts a picture in it"

proc photoGridDialog() =
  if not gridDlg.open: return
  var ok = false
  dialog(gridDlg.open, "Photo Grid", 360):
    row([90, -1]):
      label "Layout:"
      combo(gridLayouts, gridDlg.layout, w = dp(220))
    let d = cur()
    row:
      label "Gap:"
      discard d.lengthField(gridDlg.gap, dp(60), 0, 2000)
      label "Corners:"
      discard d.lengthField(gridDlg.radius, dp(60), 0, 2000)
      label unitShort()
    row:
      label "Margin:"
      discard d.lengthField(gridDlg.margin, dp(60), 0, 8000)
      label(tr(unitShort()) & tr(" (a book's page: its margins)"), color = ui.theme.gray)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): gridDlg.open = false
  if ok:
    gridDlg.open = false
    makePhotoGrid()

# ---- Text Effects -----------------------------------------------------------------------------------------

proc textLook*(look: string; color, accent: uint32): tuple[fx: LayerFx; fill: int; warp: TextWarp] =
  ## A ready look for type: its layer style, its fill opacity, its warp.
  result.fill = 100
  template e(k: FxKind): var Effect = result.fx.fx[k]
  case look
  of "Shadow":
    e(fxDropShadow) = Effect(on: true, mode: bmMultiply, opacity: 55, color: 0xFF000000'u32, angle: 135,
                             distance: 6, size: 8)
  of "Lift":
    e(fxDropShadow) = Effect(on: true, mode: bmMultiply, opacity: 35, color: 0xFF000000'u32, angle: 90,
                             distance: 10, size: 22)
  of "Hollow":
    result.fill = 0
    e(fxStroke) = Effect(on: true, mode: bmNormal, opacity: 100, color: color, size: 3, style: 0)
  of "Outline":
    e(fxStroke) = Effect(on: true, mode: bmNormal, opacity: 100, color: accent, size: 5, style: 0)
  of "Neon":
    e(fxOuterGlow) = Effect(on: true, mode: bmScreen, opacity: 90, color: accent, size: 22, spread: 10)
    e(fxInnerGlow) = Effect(on: true, mode: bmScreen, opacity: 70, color: 0xFFFFFFFF'u32, size: 4)
  of "Echo":
    e(fxDropShadow) = Effect(on: true, mode: bmNormal, opacity: 45, color: accent, angle: 135, distance: 10, size: 0)
  of "Glow":
    e(fxOuterGlow) = Effect(on: true, mode: bmScreen, opacity: 75, color: accent, size: 14, spread: 0)
  of "Curve":
    result.warp = TextWarp(style: wsArc, bend: 40)
  else: discard

proc applyTextLook(look: string) =
  let d = cur()
  let L = if d != nil: d.current else: nil
  if L == nil or not L.isText:
    status = "Text Effects: pick a type layer"
    return
  if te.on: commitType()
  let (fx, fillOp, warp) = textLook(look, L.text.styleAt(0).color, fg or 0xFF000000'u32)
  d.beginStep("Text Effect: " & look)
  d.touchLayers()
  L.fx = fx
  L.fill = fillOp
  var t = L.text
  t.warp = warp
  d.setText(L, t)
  d.endStep()
  d.markAll()

proc textEffectsDialog() =
  if not fxDlg: return
  dialog(fxDlg, "Text Effects", 340):
    label("A look for the type layer (its color: the foreground color):", color = ui.theme.gray)
    adaptive(100):
      for look in textLooks:
        if button(tr(look), w = dp(96)): applyTextLook(look)
    row:
      spring()
      if button("Close", isDefault = true, w = dp(80)): fxDlg = false

proc recolorDialog() =
  if not recolorDlg.open: return
  var ok = false
  dialog(recolorDlg.open, "Recolor Design", 360):
    for i, (name, cols) in palettes:
      row:
        var p = recolorDlg.palette
        if radio(tr(name), p, i): recolorDlg.palette = i
        for c in cols:
          let r = place(dp(26), dp(18))
          fill(r, color(uint8((c shr 16) and 255), uint8((c shr 8) and 255), uint8(c and 255)))
    # (a palette from a picture: the colors that stand for an open image, as the drawing program
    # takes a palette from a photo)
    var names: seq[string]
    for dw in docs: names.add dw.doc.name
    if names.len > 0:
      row([90, 150, -1]):
        label "From:"
        recolorFrom.doc = clamp(recolorFrom.doc, 0, names.high)
        discard combo(names, recolorFrom.doc, w = dp(144))
        if button("Take Its Colors", w = dp(120)):
          let src = docs[recolorFrom.doc].doc
          recolorFrom.cols = medianCut(src.compCopy(), 5)
          recolorFrom.name = src.name
          recolorDlg.palette = palettes.len
      if recolorFrom.cols.len > 0:
        row:
          var p = recolorDlg.palette
          if radio(tr("From ") & recolorFrom.name, p, palettes.len): recolorDlg.palette = palettes.len
          for c in recolorFrom.cols:
            let r = place(dp(26), dp(18))
            fill(r, color(uint8((c shr 16) and 255), uint8((c shr 8) and 255), uint8(c and 255)))
    row:
      spring()
      if button("Recolor", isDefault = true, w = dp(90)): ok = true
      if button("Cancel", w = dp(80)): recolorDlg.open = false
  if ok:
    recolorDlg.open = false
    if recolorDlg.palette == palettes.len and recolorFrom.cols.len > 0:
      cur().recolor(recolorFrom.cols, "the colors of " & recolorFrom.name)
    else:
      let (name, cols) = palettes[clamp(recolorDlg.palette, 0, palettes.high)]
      cur().recolor(cols, name)

# ---- Check Document -------------------------------------------------------------------------------------

var
  pfDlg: tuple[open: bool; items: seq[PreflightItem]; ppi: int] = (false, @[], 300)

proc runPreflight() =
  let bw = curBook()
  let d = cur()
  if d == nil:
    pfDlg.items = @[]
    return
  beginBusy("Checking")
  try:
    pfDlg.items = if bw != nil: bw.book.preflight(pfDlg.ppi, bw.keepOf) else: d.preflight(pfDlg.ppi)
  finally: endBusy()

proc preflightDialog() =
  if not pfDlg.open: return
  var again = false
  dialog(pfDlg.open, "Check Document", 560):
    row:
      label "Print at:"
      if spin(pfDlg.ppi, 72, 1200, w = dp(70)): again = true
      label "ppi"
      spring()
      if button("Check Again", w = dp(110)): again = true
    if pfDlg.items.len == 0:
      label("Nothing found: it is ready to print.", bold = true)
    else:
      var n: array[PreflightKind, int]
      for it in pfDlg.items: inc n[it.severity]
      label(tr("Errors") & ": " & $n[pkError] & "    " & tr("Warnings") & ": " & $n[pkWarning] & "    " &
            tr("Notes") & ": " & $n[PreflightKind.pkInfo], bold = true)
      beginScroll(dp(300))
      for i, it in pfDlg.items:
        row:
          label(tr($it.severity), color = (if it.severity == pkError: color(200, 40, 40) else: ui.theme.gray))
          let where = (if it.page >= 0: tr("Page") & " " & $(it.page + 1) & " " else: "") &
                      (if it.layer.len > 0: "\"" & it.layer & "\"" else: "")
          label where
          spring()
          if it.uid != 0 and button("Go", w = dp(50)):
            let bw = curBook()
            if bw != nil and it.page >= 0 and it.page != bw.page: bw.showPage(it.page)
            let d = cur()
            if d != nil:
              for j, L in d.layers:
                if uidOf(L) == it.uid: d.cur = j
        label("    " & tr(it.message), color = ui.theme.gray)
      endScroll()
    row:
      spring()
      if button("Close", isDefault = true, w = dp(80)): pfDlg.open = false
  if again: runPreflight()

proc quickCommand(name: string): bool =
  result = true
  case name
  of "Resize for...": rsDlg.open = cur() != nil
  of "Brand Kit...": brandDlg = true
  of "Photo Grid...": gridDlg.open = cur() != nil
  of "Text Effects...": fxDlg = true
  of "Recolor Design...": recolorDlg.open = cur() != nil
  of "Check Document...", "Preflight...":
    pfDlg.open = cur() != nil
    if pfDlg.open: runPreflight()
  else: result = false

proc quickDialogs() =
  resizeDialog()
  brandDialog()
  photoGridDialog()
  textEffectsDialog()
  recolorDialog()
  preflightDialog()

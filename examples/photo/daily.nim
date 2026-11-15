# Retro Atelier -- included by photo.nim
#
# Everyday work, in one place: the Quick Actions panel (Remove Background,
# Blur Background, Black & White Background, Enhance, Smooth Skin, Restore
# an Old Photo, Frequency Separation...), the Color Themes panel, File >
# Share, File > Export > Layers to Files, File > Automate > Crop and
# Straighten Photos, Contact Sheet and Image Processor, Image >
# Adjustments > Match Color, Select > Focus Area, Type > Paste Lorem Ipsum
# and View > Before & After.

var
  qaBlur = 50                    ## Blur Background: how much (1..100)
  ctRule = 0                     ## Color Themes: the rule (`ColorHarmony`)
  ctBase = 0'u32                 ## ... the color it starts from (0: the foreground's)
  # Match Color
  mcOpen = false
  mcSrc = 0                      ## the documents: 0 (None: this one, Neutralize only), then each open one
  mcLum = 100
  mcIntensity = 100
  mcFade = 0
  mcNeutralize = false
  mcPreview = true
  mcDoc: Doc
  mcSeen = ""
  # Focus Area
  faOpen = false
  faRange = 50
  faNoise = 0
  faOutput = 0                   ## Selection, Layer Mask, New Layer with Layer Mask
  faSoften = true
  # Layers to Files
  ltfOpen = false
  ltfDir = ""
  ltfPick = false
  ltfPrefix = ""
  ltfFormat = 0                  ## PNG, JPEG, WebP
  ltfQuality = 90
  ltfVisible = true
  ltfTrim = true
  # Contact Sheet
  csheetOpen = false
  csheetSrc = ""
  csheetPick = false
  csheetSub = false
  csheetPaper = 0                    ## A4, Letter, A3, Square (Instagram)
  csheetCols = 4
  csheetRows = 5
  csheetCaption = true
  # Image Processor
  ipOpen = false
  ipSrc = ""
  ipDst = ""
  ipPickSrc = false
  ipPickDst = false
  ipSub = false
  ipFormat = 0                   ## JPEG, PNG, WebP
  ipQuality = 85
  ipResize = true
  ipW = 2048
  ipH = 2048
  ipMark = ""                    ## a watermark's words ("" none)
  ipMarkPos = 3                  ## top left, top right, bottom left, bottom right, middle
  ipMarkOpacity = 60
  ipLog: seq[string]
  # Before & After
  baSplit: Table[pointer, float]   ## (a window shown so: where the line is, 0..1 of the image)
  baShot: tuple[d: Doc; at: int; bmp: Bitmap]

const loremIpsum = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt " &
  "ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi " &
  "ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum " &
  "dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui " &
  "officia deserunt mollit anim id est laborum."

proc pixelLayerOk(d: Doc): bool =
  d != nil and d.current.px.len == d.w * d.h and not d.current.group and d.current.adjust.kind.len == 0

proc subjectOf(d: Doc; what: string): seq[uint8] =
  ## (the subject found; an empty mask, said in the status, when none is)
  result = d.selectSubject()
  for v in result:
    if v >= 128: return
  status = tr("No subject found") & " (" & tr(what) & ")"
  result.setLen(0)

# ---- File > Share ---------------------------------------------------------------------------------------

proc shareDoc(d: Doc) =
  ## The image as it looks, as a JPEG (a PNG when it has transparency),
  ## handed to another app (Android's share sheet); elsewhere saved and
  ## its folder opened.
  let px = d.flattened()
  var clear = false
  for p in px:
    if (p shr 24) < 255:
      clear = true
      break
  let dir = dataDir(AppData) / "share"
  try: createDir(dir)
  except OSError: discard
  let base = (if d.path.len > 0: d.path.splitFile.name else: d.name).multiReplace(("/", "-"), ("\\", "-"))
  let path = dir / base & (if clear: ".png" else: ".jpg")
  var o = defaultExport(if clear: efPng else: efJpeg)
  o.quality = 92
  try: d.exportPicture(path, o)
  except CatchableError:
    status = tr("Could not make the picture to share:") & " " & getCurrentExceptionMsg()
    return
  if shareFile(path):
    status = tr("Shared:") & " " & path.extractFilename
  else:
    discard openUrl("file://" & dir)
    status = tr("Saved to share:") & " " & path

# ---- Before & After -----------------------------------------------------------------------------------------

proc beforeShot(d: Doc): Bitmap =
  ## The image as it was opened (the oldest state History keeps), small.
  let at = d.historyAt
  if baShot.d == d and baShot.at == at and baShot.bmp != nil: return baShot.bmp
  let was = d.modified
  d.goToHistory(0)
  let px = d.compCopy
  d.goToHistory(at)
  d.modified = was
  let k = min(1.0, 2048 / max(d.w, d.h).float)
  let w = max(1, int(d.w.float * k))
  let h = max(1, int(d.h.float * k))
  result = newBitmap(w, h)
  let small = if k < 1: resample(px, d.w, d.h, w, h, rsBilinear) else: px
  for i in 0 ..< w * h: result.px[i] = blendPx(0xFFFFFFFF'u32, small[i], 255, bmNormal)
  result.changed()
  baShot = (d, at, result)

proc beforeAfter(dw: DocWin; ev: PhotoEvent): bool =
  ## View > Before & After: the image as it was opened left of a line, as
  ## it is now right of it; drag to move the line (the tools wait).
  let key = cast[pointer](dw)
  if key notin baSplit: return false
  let d = dw.doc
  if dw.view.angle != 0: dw.view.angle = 0
  let shot = d.beforeShot()
  let (x0, y0) = dw.view.toScreen(d, 0, 0)
  let (x1, y1) = dw.view.toScreen(d, d.w.float, d.h.float)
  let img = rect(x0, y0, max(1, x1 - x0), max(1, y1 - y0))
  let split = baSplit[key]
  let sx = img.x + int(split * img.w.float)
  let vr = dw.view.view
  let left = rect(img.x, img.y, max(0, sx - img.x), img.h)
  let clip = rect(max(vr.x, left.x), max(vr.y, left.y),
                  max(0, min(vr.x + vr.w, left.x + left.w) - max(vr.x, left.x)),
                  max(0, min(vr.y + vr.h, left.y + left.h) - max(vr.y, left.y)))
  if clip.w > 0 and clip.h > 0:
    pushClip(clip)
    drawBitmap(img, shot)
    popClip()
  let top = max(vr.y, img.y)
  let bottom = min(vr.y + vr.h, img.y + img.h)
  if sx >= vr.x and sx < vr.x + vr.w and bottom > top:
    fill(rect(sx - dp(1), top, dp(3), bottom - top), color(255, 255, 255))
    fill(rect(sx, top, dp(1), bottom - top), color(0, 0, 0))
    let my = (top + bottom) div 2
    fill(rect(sx - dp(7), my - dp(12), dp(15), dp(24)), color(255, 255, 255))
    box(rect(sx - dp(7), my - dp(12), dp(15), dp(24)), color(0, 0, 0))
  # (the labels)
  let st = style(bold = true, size = 0.9)
  for (s, atLeft) in [(tr("Before"), true), (tr("After"), false)]:
    let tw = textWidth(s, st) + dp(10)
    let lx = if atLeft: max(vr.x, img.x) + dp(8) else: min(vr.x + vr.w, img.x + img.w) - tw - dp(8)
    let ly = max(vr.y, img.y) + dp(8)
    fill(rect(lx, ly, tw, lineHeight(st) + dp(4)), color(0, 0, 0, 170))
    text(lx + dp(5), ly + dp(2), s, color(255, 255, 255), st)
  if ev.over:
    ui.cursor = curSizeWE
    if ev.down or ev.pressed:
      baSplit[key] = clamp(ev.x / max(1, d.w).float, 0.0, 1.0)
  true

# ---- Match Color --------------------------------------------------------------------------------------------

proc mcSources(): seq[Doc] =
  for dw in docs: result.add dw.doc

proc mcApply(d: Doc) =
  ## (the current settings, on the image: the step open)
  let srcs = mcSources()
  var stats: ColorStats
  if mcSrc in 1 .. srcs.len:
    let s = srcs[mcSrc - 1]
    stats = colorStatsOf(s.flattened())
  else:
    stats = colorStatsOf(d.current.px)
  if mcNeutralize:
    stats.mean[1] = 0
    stats.mean[2] = 0
  d.applyFilter(0, colorTransfer(stats, luminance = mcLum, intensity = mcIntensity, fade = mcFade))

proc startMatchColor() =
  let d = cur()
  if not pixelLayerOk(d): return
  mcDoc = d
  mcSrc = 0
  for i, dw in docs:
    if dw.doc != d:
      mcSrc = i + 1
      break
  mcSeen = ""
  d.beginStep("Match Color")
  mcOpen = true

proc matchColorDialog() =
  if not mcOpen: return
  let d = cur()
  if d == nil or d != mcDoc:
    mcOpen = false
    if mcDoc != nil and mcDoc.stepOpen: mcDoc.cancelStep()
    return
  var done, cancelled = false
  dialog(mcOpen, "Match Color", 420):
    group("Destination Image"):
      label(tr("Target:") & " " & d.name & " (" & d.current.name & ")")
    group("Image Options"):
      form 0:
        field "Luminance:":
          row([-1, 40]):
            slider(mcLum, 0, 100, ticks = 0)
            label $mcLum
        field "Color Intensity:":
          row([-1, 40]):
            slider(mcIntensity, 0, 200, ticks = 0)
            label $mcIntensity
        field "Fade:":
          row([-1, 40]):
            slider(mcFade, 0, 100, ticks = 0)
            label $mcFade
      checkbox("Neutralize", mcNeutralize)
    group("Image Statistics"):
      var names = @[tr("None")]
      for s in mcSources(): names.add(if s == d: s.name & " " & tr("(this image)") else: s.name)
      row:
        label "Source:"
        combo(names, mcSrc, w = dp(240))
      label(tr("The colors of the source taken by this image's layer (None: its own, to neutralize a cast)."),
            color = ui.theme.gray)
    row:
      checkbox("Preview", mcPreview)
      spring()
      if button("OK", isDefault = true, w = dp(80)): done = true
      if button("Cancel", w = dp(80)): cancelled = true
  let key = $mcSrc & "/" & $mcLum & "/" & $mcIntensity & "/" & $mcFade & "/" & $mcNeutralize & "/" & $mcPreview
  if not done and not cancelled and mcOpen and key != mcSeen:
    mcSeen = key
    d.cancelStep()
    d.beginStep("Match Color")
    if mcPreview: mcApply(d)
    d.markAll()
  if done:
    if not mcPreview:
      mcApply(d)
    d.endStep()
    mcOpen = false
  elif cancelled or not mcOpen:
    d.cancelStep()
    mcOpen = false
    d.markAll()

# ---- Focus Area ---------------------------------------------------------------------------------------------

proc focusAreaDialog() =
  if not faOpen: return
  let d = cur()
  if not pixelLayerOk(d):
    faOpen = false
    return
  dialog(faOpen, "Focus Area", 380):
    group("Parameters"):
      form 0:
        field "In-Focus Range:":
          row([-1, 40]):
            slider(faRange, 0, 100, ticks = 0)
            label $faRange
        field "Image Noise Level:":
          row([-1, 40]):
            slider(faNoise, 0, 100, ticks = 0)
            label $faNoise
    group("Output"):
      row:
        label "Output To:"
        combo(["Selection", "Layer Mask", "New Layer with Layer Mask"], faOutput, w = dp(200))
      checkbox("Soften Edge", faSoften)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)):
        faOpen = false
        beginBusy("Focus Area")
        try:
          let m = d.focusArea(d.current, faRange, faNoise, faSoften)
          case faOutput
          of 0:
            d.beginStep("Focus Area")
            d.touchSel()
            d.setSelection(m, soReplace)
            d.endStep()
          else:
            d.layersChange("Focus Area"):
              var L = d.current
              if faOutput == 2:
                let nl = d.addLayer(L.name & " " & tr("copy"), above = d.cur)
                nl.px = L.px
                inc nl.ver
                L = nl
              elif L.background:
                d.layerFromBackground(d.cur)
              if L.mask == nil: d.addLayerMask(mfRevealAll, d.layers.find(L))
              if L.mask != nil:
                for i in 0 ..< m.len: L.mask.px[i] = grayPx(int(m[i]))
                inc L.mask.ver
              d.cur = d.layers.find(L)
              d.editMask = false
              d.markAll()
        finally: endBusy()
      if button("Cancel", w = dp(80)): faOpen = false

# ---- Layers to Files ----------------------------------------------------------------------------------------

proc shortName(s: string; most: int): string =
  ## `s` cut to `most` bytes (at a whole character) with "...".
  if s.len <= most: return s
  var k = most
  while k > 0 and (ord(s[k]) and 0xC0) == 0x80: dec k
  s[0 ..< k] & "..."

proc safeName(s: string): string =
  for c in s:
    result.add(if c in {'/', '\\', ':', '*', '?', '"', '<', '>', '|'}: '_' else: c)

proc layersToFiles(d: Doc) =
  let dst = if ltfDir.len > 0: ltfDir elif d.path.len > 0: d.path.parentDir else: picturesDir()
  try: createDir(dst)
  except OSError: discard
  let ext = [".png", ".jpg", ".webp"][clamp(ltfFormat, 0, 2)]
  var n = 0
  var k = 0
  beginBusy("Layers to Files", cancel = true)
  try:
    for i in countdown(d.layers.high, 0):
      let L = d.layers[i]
      if L.group or L.adjust.kind.len > 0: continue
      if ltfVisible and not L.visible: continue
      inc k
      busyLabel = tr("Layers to Files:") & " " & L.name
      busyFraction = k / d.layers.len
      busyTick()
      var px = newSeq[uint32](d.w * d.h)
      let was = L.visible
      L.visible = true
      d.compositeInto(px, d.bounds, @[L])
      L.visible = was
      var r = rect(0, 0, d.w, d.h)
      if ltfTrim:
        var (ax, ay, bx, by) = (d.w, d.h, -1, -1)
        for y in 0 ..< d.h:
          for x in 0 ..< d.w:
            if (px[y * d.w + x] shr 24) > 0:
              ax = min(ax, x); ay = min(ay, y); bx = max(bx, x); by = max(by, y)
        if bx < 0: continue
        r = rect(ax, ay, bx - ax + 1, by - ay + 1)
      let o = newDoc(r.w, r.h, 0, d.dpi, L.name)
      for y in 0 ..< r.h:
        for x in 0 ..< r.w: o.layers[0].px[y * r.w + x] = px[(r.y + y) * d.w + r.x + x]
      inc o.layers[0].ver
      var opts = defaultExport([efPng, efJpeg, efWebp][clamp(ltfFormat, 0, 2)])
      opts.quality = ltfQuality
      let name = (if ltfPrefix.len > 0: ltfPrefix & "_" else: "") & align($k, 4, '0') & "_" & safeName(L.name) & ext
      o.exportPicture(dst / name, opts)
      inc n
  except BusyCancelled: discard
  except CatchableError:
    status = tr("Layers to Files:") & " " & getCurrentExceptionMsg()
    endBusy(cancel = true)
    return
  endBusy(cancel = true)
  status = tr("Layers to Files:") & " " & $n & " " & tr("files in") & " " & dst

proc layersToFilesDialog() =
  if ltfOpen:
    let d = cur()
    if d == nil:
      ltfOpen = false
      return
    dialog(ltfOpen, "Export Layers to Files", 440):
      group("Destination"):
        row([-1, 90]):
          let shown = if ltfDir.len > 0: ltfDir elif d.path.len > 0: d.path.parentDir else: picturesDir()
          label(ellipsize(shown, available()))
          if button("Choose...", w = dp(86)):
            proc go() =
              if ltfDir.len == 0: ltfDir = if d.path.len > 0: d.path.parentDir else: picturesDir()
              ltfPick = true
            if storageFor(go): go()
        row:
          label "File Name Prefix:"
          edit(ltfPrefix, w = dp(200))
      group("Options"):
        row:
          label "File Type:"
          combo(["PNG-24", "JPEG", "WebP"], ltfFormat, w = dp(110))
          if ltfFormat > 0:
            label "Quality:"
            spin(ltfQuality, 1, 100, w = dp(60))
        checkbox("Visible Layers Only", ltfVisible)
        checkbox("Trim Layers", ltfTrim)
      row:
        spring()
        if button("Run", isDefault = true, w = dp(80)):
          ltfOpen = false
          layersToFiles(d)
        if button("Cancel", w = dp(80)): ltfOpen = false
  if filePicker(ltfPick, ltfDir, fmFolder, [], "Layers to Files: Destination"): discard

# ---- Contact Sheet ------------------------------------------------------------------------------------------

proc contactSheet() =
  let files = batchFiles(csheetSrc, csheetSub)
  if files.len == 0:
    status = tr("No pictures in") & " " & csheetSrc
    return
  let (W, H, dpi) = [(2480, 3508, 300), (2550, 3300, 300), (3508, 4961, 300), (2160, 2160, 144)][clamp(csheetPaper, 0, 3)]
  let cols = max(1, csheetCols)
  let rows = max(1, csheetRows)
  let per = cols * rows
  let margin = W.float * 0.05
  let gap = W.float * 0.015
  let cellW = (W.float - 2 * margin - (cols - 1).float * gap) / cols.float
  let cellH = (H.float - 2 * margin - (rows - 1).float * gap) / rows.float
  let capH = if csheetCaption: min(cellH * 0.14, W.float * 0.03) else: 0.0
  var pages = 0
  beginBusy("Contact Sheet", cancel = true)
  try:
    var k = 0
    while k < files.len:
      inc pages
      inc untitled
      let d = newDoc(W, H, white, dpi.float, tr("Contact Sheet") & " " & $pages)
      let bgL = d.layers[0]
      for slot in 0 ..< per:
        if k >= files.len: break
        let f = files[k]
        inc k
        busyLabel = tr("Contact Sheet:") & " " & f.extractFilename & " (" & $k & " / " & $files.len & ")"
        busyFraction = k / files.len
        busyTick()
        var pic: Doc
        try: pic = openPicture(f)
        except CatchableError: continue
        let px = pic.flattened(white)
        let cx = margin + (slot mod cols).float * (cellW + gap)
        let cy = margin + (slot div cols).float * (cellH + gap)
        let s = min(cellW / pic.w.float, (cellH - capH) / pic.h.float)
        let tw = max(1, int(pic.w.float * s))
        let th = max(1, int(pic.h.float * s))
        let small = resample(px, pic.w, pic.h, tw, th, rsBicubic)
        let ox = int(cx + (cellW - tw.float) / 2)
        let oy = int(cy + (cellH - capH - th.float) / 2)
        for y in 0 ..< th:
          let yy = oy + y
          if yy < 0 or yy >= H: continue
          for x in 0 ..< tw:
            let xx = ox + x
            if xx >= 0 and xx < W: bgL.px[yy * W + xx] = small[y * tw + x]
        if csheetCaption:
          # (the name under it, drawn into the page)
          var st = defaultStyle()
          st.size = float32(capH * 0.55)
          st.color = 0xFF333333'u32
          var t = newText(shortName(f.splitFile.name, 48), st, float32(cx + cellW / 2), float32(cy + cellH - capH * 0.25))
          t.para.align = textCenter
          let tl = d.addTextLayer(t)
          for i in 0 ..< bgL.px.len:
            let a = tl.px[i] shr 24
            if a > 0: bgL.px[i] = blendPx(bgL.px[i], tl.px[i], 255, bmNormal)
          d.deleteLayer(d.layers.find(tl))
      inc bgL.ver
      d.cur = 0
      d.markAll()
      d.clearHistory()
      addDoc(d)
  except BusyCancelled: discard
  finally: endBusy(cancel = true)
  status = tr("Contact Sheet:") & " " & $pages & " " & tr("pages")

proc contactSheetDialog() =
  if csheetOpen:
    dialog(csheetOpen, "Contact Sheet", 440):
      group("Source Images"):
        row([-1, 90]):
          label(if csheetSrc.len > 0: ellipsize(csheetSrc, available()) else: tr("(a folder)"),
                color = if csheetSrc.len > 0: ui.theme.text else: ui.theme.gray)
          if button("Choose...", w = dp(86)):
            proc go() =
              if csheetSrc.len == 0: csheetSrc = picturesDir()
              csheetPick = true
            if storageFor(go): go()
        checkbox("Include All Subfolders", csheetSub)
        if csheetSrc.len > 0: label($batchFiles(csheetSrc, csheetSub).len & " " & tr("pictures"), color = ui.theme.gray)
      group("Document"):
        row:
          label "Page:"
          combo(["A4 (300 ppi)", "Letter (300 ppi)", "A3 (300 ppi)", "Square 2160 px"], csheetPaper, w = dp(170))
      group("Thumbnails"):
        row:
          label "Columns:"
          spin(csheetCols, 1, 12, w = dp(56))
          label "Rows:"
          spin(csheetRows, 1, 16, w = dp(56))
        checkbox("Use Filename as Caption", csheetCaption)
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80), enabled = csheetSrc.len > 0):
          csheetOpen = false
          contactSheet()
        if button("Cancel", w = dp(80)): csheetOpen = false
  if filePicker(csheetPick, csheetSrc, fmFolder, [], "Contact Sheet: Source Folder"): discard

# ---- Image Processor ----------------------------------------------------------------------------------------

proc imageProcessor() =
  let files = batchFiles(ipSrc, ipSub)
  ipLog.setLen(0)
  if files.len == 0:
    status = tr("No pictures in") & " " & ipSrc
    return
  let dst = if ipDst.len > 0: ipDst else: ipSrc / ["JPEG", "PNG", "WebP"][clamp(ipFormat, 0, 2)]
  try: createDir(dst)
  except OSError: discard
  let ext = [".jpg", ".png", ".webp"][clamp(ipFormat, 0, 2)]
  var done = 0
  beginBusy("Image Processor", cancel = true)
  try:
    for i, f in files:
      busyLabel = tr("Image Processor:") & " " & f.extractFilename & " (" & $(i + 1) & " / " & $files.len & ")"
      busyFraction = i / files.len
      busyTick()
      var d: Doc
      try: d = openPicture(f)
      except CatchableError:
        ipLog.add f.extractFilename & ": " & tr("could not be read")
        continue
      try:
        if ipResize: d.fitImage(ipW, ipH, true)
        if ipMark.strip.len > 0:
          var st = defaultStyle()
          st.style = "Bold"
          st.size = float32(max(8.0, min(d.w, d.h).float * 0.04))
          st.color = 0xFFFFFFFF'u32
          let m = min(d.w, d.h).float * 0.03
          let (x, y, al) = case ipMarkPos
                           of 0: (m, m + st.size.float, textLeft)
                           of 1: (d.w.float - m, m + st.size.float, textRight)
                           of 2: (m, d.h.float - m, textLeft)
                           of 4: (d.w / 2, d.h / 2, textCenter)
                           else: (d.w.float - m, d.h.float - m, textRight)
          var t = newText(ipMark.strip, st, float32(x), float32(y))
          t.para.align = al
          let L = d.addTextLayer(t)
          L.opacity = clamp(ipMarkOpacity, 1, 100)
        var o = defaultExport([efJpeg, efPng, efWebp][clamp(ipFormat, 0, 2)])
        o.quality = ipQuality
        let rel = if ipSub: f.parentDir.relativePath(ipSrc) else: ""
        let outDir = if rel.len > 0 and rel != ".": dst / rel else: dst
        createDir(outDir)
        d.exportPicture(outDir / f.splitFile.name & ext, o)
        inc done
      except BusyCancelled: raise
      except CatchableError:
        ipLog.add f.extractFilename & ": " & getCurrentExceptionMsg()
  except BusyCancelled:
    ipLog.add tr("Stopped.")
  finally:
    endBusy(cancel = true)
  status = tr("Image Processor:") & " " & $done & " / " & $files.len & " " & tr("pictures saved in") & " " & dst

proc imageProcessorDialog() =
  if ipOpen:
    dialog(ipOpen, "Image Processor", 470):
      group("1  Select the images to process"):
        row([-1, 90]):
          label(if ipSrc.len > 0: ellipsize(ipSrc, available()) else: tr("(a folder)"),
                color = if ipSrc.len > 0: ui.theme.text else: ui.theme.gray)
          if button("Choose...", w = dp(86)):
            proc go() =
              if ipSrc.len == 0: ipSrc = picturesDir()
              ipPickSrc = true
            if storageFor(go): go()
        checkbox("Include All Subfolders", ipSub)
        if ipSrc.len > 0: label($batchFiles(ipSrc, ipSub).len & " " & tr("pictures"), color = ui.theme.gray)
      group("2  Select location to save processed images"):
        row([-1, 90]):
          label(if ipDst.len > 0: ellipsize(ipDst, available())
                else: tr("(a folder in the source folder, named for the file type)"),
                color = if ipDst.len > 0: ui.theme.text else: ui.theme.gray)
          if button("Choose...", w = dp(86)):
            proc go() =
              if ipDst.len == 0: ipDst = if ipSrc.len > 0: ipSrc else: picturesDir()
              ipPickDst = true
            if storageFor(go): go()
      group("3  File Type"):
        row:
          combo(["JPEG", "PNG", "WebP"], ipFormat, w = dp(90))
          if ipFormat != 1:
            label "Quality:"
            spin(ipQuality, 1, 100, w = dp(60))
        row:
          checkbox("Resize to Fit", ipResize)
          label "W:"
          spin(ipW, 16, 30000, w = dp(76))
          label "H:"
          spin(ipH, 16, 30000, w = dp(76))
      group("4  Watermark"):
        row:
          label "Text:"
          edit(ipMark, w = dp(220))
        row:
          label "Position:"
          combo(["Top Left", "Top Right", "Bottom Left", "Bottom Right", "Center"], ipMarkPos, w = dp(120))
          label "Opacity:"
          spin(ipMarkOpacity, 1, 100, w = dp(60))
      if ipLog.len > 0:
        group("The last run"):
          for l in ipLog[0 ..< min(ipLog.len, 5)]: label(l, color = color(160, 0, 0))
      row:
        spring()
        if button("Run", isDefault = true, w = dp(80), enabled = ipSrc.len > 0):
          ipOpen = false
          imageProcessor()
        if button("Cancel", w = dp(80)): ipOpen = false
  if filePicker(ipPickSrc, ipSrc, fmFolder, [], "Image Processor: Source Folder"): discard
  if filePicker(ipPickDst, ipDst, fmFolder, [], "Image Processor: Destination Folder"): discard

# ---- QR Code ------------------------------------------------------------------------------------------------

var
  qrOpen = false
  qrKind = 0                     ## Link or Text, Wi-Fi, Phone, Email, Contact
  qrText = "https://"
  qrSsid = ""
  qrPass = ""
  qrPhone = ""
  qrMail = ""
  qrName = ""
  qrEcc = 1                      ## L, M, Q, H
  qrSize = 40                    ## % of the image's smaller side
  qrColor = 0xFF000000'u32
  qrBack = true                  ## a white square behind it (its quiet zone)

proc qrContent(): string =
  ## What the code says, from the fields of its kind.
  case qrKind
  of 1:
    proc esc(s: string): string =
      for c in s:
        if c in {'\\', ';', ',', ':', '"'}: result.add '\\'
        result.add c
    "WIFI:T:" & (if qrPass.len > 0: "WPA" else: "nopass") & ";S:" & esc(qrSsid) & ";P:" & esc(qrPass) & ";;"
  of 2: "tel:" & qrPhone.strip
  of 3: "mailto:" & qrMail.strip
  of 4: "BEGIN:VCARD\nVERSION:3.0\nFN:" & qrName.strip & "\nTEL:" & qrPhone.strip & "\nEMAIL:" &
        qrMail.strip & "\nEND:VCARD"
  else: qrText.strip

proc makeQrLayer(d: Doc) =
  ## The code as a shape layer -- sharp at any size -- in the middle of
  ## the selection, or of the image; a white square behind it.
  let text = qrContent()
  if text.len == 0: return
  var q: QrCode
  try: q = qrEncode(text, QrEcc(clamp(qrEcc, 0, 3)))
  except ValueError:
    status = tr("Too much for a QR code: make the text shorter")
    return
  let area = if d.hasSelection: d.clip(d.selBounds) else: rect(0, 0, d.w, d.h)
  let side = max(q.size + 8, int(min(area.w, area.h).float * clamp(qrSize, 5, 100).float / 100))
  let cell = side.float / (q.size + 8).float          # (a quiet zone of 4 cells round it)
  let x0 = area.x.float + (area.w.float - side.float) / 2
  let y0 = area.y.float + (area.h.float - side.float) / 2
  var path: Path
  for k, poly in qrPath(q, cell, x0 + 4 * cell, y0 + 4 * cell):
    var sp = SubPath(closed: true, joined: k > 0)
    for p in poly: sp.pts.add PathPoint(p: p, inH: p, outH: p)
    path.subs.add sp
  d.layersChange("QR Code"):
    if qrBack:
      discard d.addShapeLayer(ShapeData(path: rectPath(x0, y0, x0 + side.float, y0 + side.float),
                                        fill: solidPaint(0xFFFFFFFF'u32), kind: "Rectangle"), "QR Code Background")
    discard d.addShapeLayer(ShapeData(path: path, fill: solidPaint(qrColor or 0xFF000000'u32), kind: ""),
                            "QR Code")
    if d.hasSelection:
      d.touchSel()
      d.selectNone()
  status = tr("QR Code:") & " " & tr("version") & " " & $q.version & ", " & $q.size & " x " & $q.size & " " &
           tr("modules") & " -- " & shortName(text, 60)

proc qrDialog() =
  if not qrOpen: return
  let d = cur()
  if d == nil:
    qrOpen = false
    return
  dialog(qrOpen, "New QR Code", 420):
    row:
      label "Content:"
      combo(["Link or Text", "Wi-Fi", "Phone", "Email", "Contact Card"], qrKind, w = dp(160))
    case qrKind
    of 1:
      form 0:
        field "Network (SSID):": edit(qrSsid)
        field "Password:": edit(qrPass)
      label("Scanned with a phone's camera, it joins the network.", color = ui.theme.gray)
    of 2:
      form 0:
        field "Phone:": edit(qrPhone)
    of 3:
      form 0:
        field "Email:": edit(qrMail)
    of 4:
      form 0:
        field "Name:": edit(qrName)
        field "Phone:": edit(qrPhone)
        field "Email:": edit(qrMail)
    else:
      editArea(qrText, lines = 3)
    group("Look"):
      row:
        label "Error Correction:"
        combo(["Low (7%)", "Medium (15%)", "Quartile (25%)", "High (30%)"], qrEcc, w = dp(140))
      row([70, -1, 46]):
        label "Size:"
        slider(qrSize, 5, 100, ticks = 0)
        label $qrSize & "%"
      row:
        label "Color:"
        colorWell(qrColor, "qrcolor", dp(40))
        checkbox("White Background", qrBack)
    let text = qrContent()
    var info = ""
    try:
      let q = qrEncode(text, QrEcc(clamp(qrEcc, 0, 3)))
      info = tr("version") & " " & $q.version & ", " & $q.size & " x " & $q.size & " " & tr("modules")
    except ValueError: info = tr("Too much for a QR code: make the text shorter")
    label(info, color = ui.theme.gray)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80), enabled = text.len > 0):
        qrOpen = false
        makeQrLayer(d)
      if button("Cancel", w = dp(80)): qrOpen = false

# ---- the panels -----------------------------------------------------------------------------------------------

proc quickAction(name, what: string; enabled: bool; cmd = "") =
  if button(tr(name).replace("&", "&&"), w = available(), enabled = enabled):
    runCommand(if cmd.len > 0: cmd else: name)
  label(tr(what), color = ui.theme.gray)
  space(dp(4))

proc quickActionsBody() =
  ## Quick Actions (the usual Discover panel): an edit in one click, as a
  ## layer of its own where it can be.
  let d = cur()
  let ok = pixelLayerOk(d) and d.mode in {cmRGB, cmGray}
  beginScroll(0, "quickactions")
  quickAction("Remove Background", "The subject kept, the rest hidden by a layer mask", ok)
  quickAction("Blur Background", "A blurred copy over the background, the subject sharp", ok)
  row([-1, 36]):
    slider(qaBlur, 1, 100, ticks = 0)
    label $qaBlur
  quickAction("Black & White Background", "The subject in color, the rest black and white", ok)
  quickAction("Select Subject", "The main thing in the picture selected", d != nil, "Subject")
  quickAction("Enhance Image", "Light, contrast and color set as Camera Raw's Auto does", ok)
  quickAction("Smooth Skin", "Skin made smooth, the eyes and edges kept", ok)
  quickAction("Restore Old Photo", "Scratches, dust and noise taken out, faded color brought back", ok)
  quickAction("Frequency Separation", "Tone and texture on two layers, to retouch skin", ok)
  quickAction("Crop and Straighten Photos", "Each photo of a scan as a document of its own, straight", d != nil)
  quickAction("Share...", "The image to another app (as a JPEG or PNG)", d != nil)
  quickAction("Browse Assets...", "Free photos, icons, textures, brushes, styles and designs", true)
  endScroll()

proc colorThemesBody() =
  ## Color Themes: five colors that go together by a rule, from a base
  ## color; click one to paint with it.
  if ctBase == 0: ctBase = fg
  combo(ColorHarmony.mapIt(tr($it)), ctRule, w = available())
  let five = colorTheme(ctBase, ColorHarmony(clamp(ctRule, 0, ord(high(ColorHarmony)))))
  let r = place(available(), dp(56))
  let cw = r.w div 5
  for k in 0 .. 4:
    let cr = rect(r.x + k * cw, r.y, (if k == 4: r.w - 4 * cw else: cw), r.h)
    let hit = interact(idOf("ctswatch" & $k), cr, focusable = false)
    fill(cr, colorOf(five[k]))
    if k == 2: box(inset(cr, dp(2)), contrastInk(colorOf(five[k]), color(255, 255, 255), color(0, 0, 0)), 2)
    if hit.hover: box(cr, ui.theme.text)
    if hit.clicked: fg = five[k]
    ui.lastId = idOf("ctswatch" & $k)
    tooltip("#" & toHex(five[k] and 0xFFFFFF'u32, 6))
  row:
    if button(tr("From Foreground"), w = dp(120)): ctBase = fg
    if button(tr("Add to Swatches"), w = dp(120)):
      for c in five: swatches.add c
      status = tr("Five colors added to the Swatches")
  label(tr("The base color is in the middle; click a color to paint with it."), color = ui.theme.gray)

# ---- the commands -----------------------------------------------------------------------------------------------

proc dailyCommand(name: string): bool =
  ## The commands above (true: done here).
  let d = cur()
  result = true
  case name
  of "Quick Actions": togglePanel("quickactions")
  of "Color Themes": togglePanel("colorthemes")
  of "Share...":
    if d != nil: shareDoc(d)
  of "Blur Background", "Black & White Background":
    if d != nil and d.needPixels(name):
      let m = d.subjectOf(name)
      if m.len > 0:
        d.layersChange(name):
          if name == "Blur Background": discard d.blurBackground(qaBlur, m)
          else: discard d.bwBackground(m)
        status = tr(name) & ": " & tr("a layer with a mask (paint the mask to change where)")
  of "Enhance Image":
    if pixelLayerOk(d) and d.needPixels(name):
      let s = autoDevelop(Img(w: d.w, h: d.h, px: d.current.px))
      d.paintStep(name): d.applyFilter(developMargin(s), develop(s))
  of "Smooth Skin":
    if pixelLayerOk(d) and d.needPixels(name):
      d.paintStep(name): d.applyFilter(24, skinSmoothing(8, 60))
  of "Restore Old Photo":
    if pixelLayerOk(d) and d.needPixels(name):
      d.paintStep(name): d.applyFilter(16, photoRestoration())
  of "Frequency Separation":
    if pixelLayerOk(d) and d.needPixels(name):
      d.layersChange(name):
        discard d.frequencySeparation(d.current, max(3.0, min(d.w, d.h).float / 300))
      status = tr("Frequency Separation: smooth tones on Low Frequency, heal texture on High Frequency")
  of "Crop and Straighten Photos":
    if d != nil:
      let im = Img(w: d.w, h: d.h, px: d.flattened(white))
      let found = findPhotos(im)
      if found.len == 0:
        status = tr("No photos found on a plain background")
      else:
        for k, f in found:
          let c = cutPhoto(im, f)
          let nd = newDoc(c.w, c.h, white, d.dpi, d.name.splitFile.name & " " & tr("Copy") & " " & $(k + 1))
          nd.layers[0].px = c.px
          inc nd.layers[0].ver
          nd.markAll()
          nd.clearHistory()
          nd.modified = true
          addDoc(nd)
        status = $found.len & " " & tr("photos found, each in a document of its own")
  of "Match Color...": startMatchColor()
  of "Focus Area...":
    if pixelLayerOk(d): faOpen = true
  of "Layers to Files...":
    if d != nil:
      if ltfPrefix.len == 0 or true: ltfPrefix = (if d.path.len > 0: d.path.splitFile.name else: d.name)
      ltfOpen = true
  of "Contact Sheet...": csheetOpen = true
  of "New QR Code...":
    if d != nil: qrOpen = true
  of "Image Processor...": ipOpen = true
  of "Paste Lorem Ipsum":
    if d != nil:
      if d.current.isText:
        let L = d.current
        d.layersChange(name):
          var t = L.text
          let st = if t.spans.len > 0: t.spans[0].style else: defaultStyle()
          t.spans = @[TextSpan(text: loremIpsum, style: st)]
          L.text = t
          d.drawText(L)
          d.markAll()
      else:
        var st = defaultStyle()
        st.size = float32(max(8.0, min(d.w, d.h).float / 32))
        st.color = fg
        var t = newText(loremIpsum, st, float32(d.w.float * 0.1), float32(d.h.float * 0.1))
        t.boxW = float32(d.w.float * 0.8)
        t.boxH = float32(d.h.float * 0.8)
        d.layersChange(name): discard d.addTextLayer(t)
  of "Before & After":
    if active != nil:
      let key = cast[pointer](active)
      if key in baSplit: baSplit.del key
      else:
        baSplit[key] = 0.5
        status = tr("Before & After: drag across the image to move the line; View > Before & After again to end")
  else: result = false

proc dailyDialogs() =
  qrDialog()
  matchColorDialog()
  focusAreaDialog()
  layersToFilesDialog()
  contactSheetDialog()
  imageProcessorDialog()

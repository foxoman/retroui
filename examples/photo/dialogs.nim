# (included by photo.nim) The dialogs: New, Open and Save, Image Size,
# Canvas Size, Fill, Stroke, the adjustments (previewed on the image), the
# filters (previewed in their box), Color Range, Type, Variations, the
# layer, brush and file dialogs.

var
  closeAsk: tuple[on: bool; dw: DocWin]
  quitChecked = false

# ---- New ------------------------------------------------------------------------------------------

var
  newOpen = false
  newName = ""
  newW = 640
  newH = 480
  newDpi = 72
  newMode = 2                 ## Bitmap, Grayscale, RGB, CMYK, Lab (`newModeNames`)
  newBits = 0                 ## 8, 16 bits a channel
  newContents = 0             ## white, background color, transparent, black, a color
  newColor = 0xFFE0D0B0'u32   ## (Contents: Custom)

const newModeNames = ["Bitmap", "Grayscale", "RGB Color", "CMYK Color", "Lab Color"]

proc newDocDialog()            # (photo/newdoc)
proc startNewDocument()

proc newModeOf(k: int): ColorMode =
  [cmBitmap, cmGray, cmRGB, cmCMYK, cmLab][clamp(k, 0, 4)]

proc newDialog() =
  if not newOpen: return
  if not prefs.legacyNew:
    newDocDialog()
    return
  dialog(newOpen, "New", 380):
    form 0:
      field "Name:": edit(newName)
    let chans = case newModeOf(newMode)
                of cmBitmap, cmGray: 1
                of cmCMYK: 4
                else: 3
    group("Image Size: " & sizeText(newW * newH * chans * (if newBits == 1: 2 else: 1))):
      form 0:
        field "Width:":
          row:
            intEdit(newW, w = dp(80), lo = 1, hi = 30000)
            label "pixels"
        field "Height:":
          row:
            intEdit(newH, w = dp(80), lo = 1, hi = 30000)
            label "pixels"
        field "Resolution:":
          row:
            intEdit(newDpi, w = dp(80), lo = 1, hi = 9999)
            label "pixels/inch"
            if button("Screen", w = dp(60)): newDpi = prefs.screenRes
            if button("Print", w = dp(60)): newDpi = prefs.printRes
        field "Color Mode:":
          row:
            combo(newModeNames, newMode, w = dp(130))
            combo(["8 bit", "16 bit"], newBits, w = dp(70), enabled = newModeOf(newMode) != cmBitmap)
    group("Contents"):
      radio("White", newContents, 0)
      radio("Black", newContents, 3)
      radio("Background Color", newContents, 1)
      radio("Transparent", newContents, 2)
      row:
        radio("Custom:", newContents, 4)
        if colorWell(newColor, "newcontents", dp(50)): newContents = 4
    let fits = sizeOk(newW, newH)
    if not fits: label("Too big: at most " & $(maxPixels div 1_000_000) & " million pixels", color = color(160, 0, 0))
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80), enabled = fits):
        let c = case newContents
                of 0: white
                of 1: bg
                of 3: black
                of 4: newColor or 0xFF000000'u32
                else: 0'u32
        let d = newUntitled(max(1, newW), max(1, newH), c, newDpi.float, newModeOf(newMode),
                            newName.strip, if newBits == 1 and newModeOf(newMode) != cmBitmap: 16 else: 8)
        # (the working space of Preferences › Color Profiles; sRGB: none needed)
        if newModeOf(newMode) == cmRGB and prefs.workingSpace > 1 and prefs.workingSpace <= builtInProfileNames.len:
          d.icc = iccBytes(builtInProfile(builtInProfileNames[prefs.workingSpace - 1]))
        addDoc(d)
        newOpen = false
      if button("Cancel", w = dp(80)): newOpen = false

proc startNew() =
  newName = "Untitled-" & $(untitled + 1)
  if hasClip:
    newW = clip.w
    newH = clip.h
  startNewDocument()
  newOpen = true
  typeFirst()

# ---- Open, Save -------------------------------------------------------------------------------------

var
  openPick = false
  openPath = ""
  placePick = false
  savePick = false
  savePath = ""
  saveDoc: DocWin
  saveCopy = false
  jpegOpen = false
  jpegQuality = 8
  flatWarn = false
  infoOpen = false
  fileInfo: ImageInfo

proc startOpen() =
  ## (on Android the access to the user's files is asked for first)
  proc go() =
    if openPath.len == 0 or not dirExists(openPath.parentDir): openPath = picturesDir()
    openPick = true
  if askStorage(AppName, filesWhy, go): go()

const
  openPatterns = ["*.rpd", "*.rp3", "*.psd", "*.psb", "*.png", "*.jpg", "*.jpeg", "*.tif", "*.tiff", "*.bmp", "*.gif",
                  "*.tga", "*.dng", "*.pdf", "*.ai", "*.eps", "*.ps", "*.hdr", "*.pfm", "*.exr", "*.webp",
                  "*.nef", "*.nrw", "*.arw", "*.cr2", "*.cr3", "*.orf", "*.rw2", "*.pef", "*.raf", "*.heic", "*.heif",
                  "*.avif", "*.jxl", "*.svg"]
  savePatterns = ["*.rpd", "*.psd", "*.pdf", "*.eps", "*.ps", "*.png", "*.jpg", "*.tif", "*.bmp", "*.gif", "*.tga",
                  "*.hdr", "*.pfm", "*.exr", "*.webp", "*.jxl"]
  layeredFormats = ["rpd", "rp3", "psd", "psb"]

var bgSave: tuple[doc: Doc; copy: bool]   ## the document being saved in the background

proc rememberFile(path: string) =
  ## `path` first in File › Open Recent.
  var st = loadSettings(AppName)
  st.addRecentFile(path, prefs.recent)
  discard saveSettings(AppName, st)

proc writeDoc(dw: DocWin; path: string; quality = 85) =
  ## Saves the document: with its layers as Retro Photo or PSD, mixed
  ## in the other formats. A big one is saved in the background: what it
  ## holds is copied, the program goes on while it is written.
  let d = dw.doc
  var path = path
  if prefs.lowerExt:
    let sp = path.splitFile
    if sp.ext != sp.ext.toLowerAscii: path = sp.dir / sp.name & sp.ext.toLowerAscii
  let ext = path.splitFile.ext.toLowerAscii
  let fmt = formatOf(path)
  var layered = 0
  for L in d.layers:
    if not L.group: inc layered
  if not saveCopy: rememberFile(path)
  if prefs.bgSave and d.w * d.h * max(1, layered) >= 3_000_000:
    try:
      var o = defaultExport(case ext
                            of ".rpd", ".rp3": efRpd
                            of ".psd", ".psb": efPsd
                            else: fmt)
      o.quality = quality
      beginBusy("Saving " & path.extractFilename)
      var job: SaveJob
      try: job = prepareSave(d, path, o)
      finally: endBusy()
      startSave(move(job))
      bgSave = (d, saveCopy)
      if not saveCopy:
        d.path = path
        d.format = ext.strip(chars = {'.'})
        if d.format == "jpeg": d.format = "jpg"
        d.name = path.splitFile.name
        d.modified = false
      status = "Saving " & path.extractFilename & " in the background..."
    except CatchableError:
      status = "Could not save " & path.extractFilename & ": " & getCurrentExceptionMsg()
    return
  try:
    beginBusy("Saving " & path.extractFilename)
    try:
      case ext
      of ".rpd", ".rp3": d.saveRpd(path)
      of ".psd", ".psb": d.savePsd(path)
      else:
        var o = defaultExport(fmt)
        o.quality = quality
        d.exportPicture(path, o)
    finally: endBusy()
    if not saveCopy:
      d.path = path
      d.format = ext.strip(chars = {'.'})
      if d.format == "jpeg": d.format = "jpg"
      d.name = path.splitFile.name
      d.modified = false
    status = "Saved " & path.extractFilename
    if not saveCopy: dw.dropRecovery()
  except CatchableError:
    status = "Could not save " & path.extractFilename & ": " & getCurrentExceptionMsg()

proc startSaveAs(dw: DocWin; copy = false) =
  saveDoc = dw
  saveCopy = copy
  let layered = dw.doc.layers.len > 1 or dw.doc.alphas.len > 0
  let ext = if dw.doc.format in layeredFormats: "." & dw.doc.format
            elif layered: ".rpd"
            elif dw.doc.format.len > 0: "." & dw.doc.format
            else: ".rpd"
  proc go() =
    let dir = if dw.doc.path.len > 0 and dirExists(dw.doc.path.parentDir): dw.doc.path.parentDir
              else: picturesDir()
    savePath = dir / dw.doc.name & ext
    savePick = true
  if askStorage(AppName, filesWhy, go): go()

var
  pdfPick = false              ## File > Save as PDF: where
  pdfPath = ""
  pdfDoc: DocWin

proc startSavePdf(dw: DocWin) =
  ## File > Save as PDF: where, then the PDF's options (a preset: the web,
  ## print, a press).
  pdfDoc = dw
  proc go() =
    let dir = if dw.doc.path.len > 0 and dirExists(dw.doc.path.parentDir): dw.doc.path.parentDir
              else: picturesDir()
    pdfPath = dir / dw.doc.name.changeFileExt("") & ".pdf"
    pdfPick = true
  if askStorage(AppName, filesWhy, go): go()

proc save(dw: DocWin) =
  if saveSmartChild(dw): return
  if dw.doc.path.len == 0 or (dw.doc.format notin layeredFormats and dw.doc.layers.len > 1):
    dw.startSaveAs()
  else:
    saveCopy = false
    dw.writeDoc(dw.doc.path, 10 + jpegQuality * 9)

# ---- Export As ---------------------------------------------------------------------------------------

var
  exportOpen = false
  exportPick = false
  exportPath = ""
  exportDoc: DocWin
  exportFmt = 0                 ## index into ExportFormat (JPEG .. PSD)
  exportQuality = 85
  exportSmall = false           ## JPEG: colors at half size
  exportPngLevel = 1            ## Fast, Normal, Smallest
  exportColors = 256
  exportDither = true
  exportAlpha = true
  exportTiff = 1                ## None, LZW, ZIP, PackBits
  exportTiffLayers = false      ## TIFF: its layers kept too
  exportWebpLossless = false    ## WebP: every pixel kept
  exportRle = true
  exportScale = 100
  exportMatte = 0               ## White, Black, Background Color, Other
  exportMatteColor = 0xFFC0C0C0'u32
  exportProfile = true          ## the color profile in the file
  exportGuess: tuple[key: string; bytes: int]
  exportBmp32 = false           ## BMP: 32 bits (its transparency kept), else 24
  exportJxlEffort = 3           ## JPEG XL: 1 quick .. 9 smallest
  exportJxlLossy = true         ## JPEG XL: smaller, at the quality (else every pixel kept)

const exportFormats = [efJpeg, efPng, efPng8, efGif, efWebp, efJxl, efAvif, efHeic, efTiff, efBmp, efTga, efPsd,
                       efHdr, efExr, efPfm]

proc exportOptions(): ExportOptions =
  let f = exportFormats[clamp(exportFmt, 0, exportFormats.high)]
  result = defaultExport(f)
  result.quality = exportQuality
  result.chroma420 = exportSmall
  result.pngLevel = [2, 6, 9][clamp(exportPngLevel, 0, 2)]
  result.colors = exportColors
  result.dither = exportDither
  result.transparency = exportAlpha
  result.tiff = TiffCompression(clamp(exportTiff, 0, 3))
  result.tiffLayers = exportTiffLayers
  result.webpLossless = exportWebpLossless
  result.jxlEffort = exportJxlEffort
  result.jxlLossy = exportJxlLossy
  result.tgaRle = exportRle
  result.scale = exportScale / 100
  result.embedProfile = exportProfile
  result.bmpBits = if exportBmp32: 32 else: 24
  result.matte = case exportMatte
                 of 1: black
                 of 2: bg or 0xFF000000'u32
                 of 3: exportMatteColor or 0xFF000000'u32
                 else: white

proc startExport(dw: DocWin) =
  exportDoc = dw
  exportGuess = ("", 0)
  exportOpen = true

proc exportDialog() =
  if not exportOpen or exportDoc == nil: return
  let d = exportDoc.doc
  dialog(exportOpen, "Export As", 400):
    let f = exportFormats[clamp(exportFmt, 0, exportFormats.high)]
    form 0:
      field "Format:":
        var names: seq[string]
        for e in exportFormats: names.add $e & " (" & formatExts[e] & ")"
        combo(names, exportFmt, w = dp(200))
    case f
    of efJpeg:
      group("JPEG"):
        row([70, -1, 36]):
          label "Quality:"
          slider(exportQuality, 1, 100)
          label $exportQuality
        checkbox("Smaller file (colors at half size)", exportSmall)
    of efPng:
      group("PNG-24"):
        row:
          label "Compression:"
          combo(["Fast", "Normal", "Smallest"], exportPngLevel, w = dp(120))
        checkbox("Transparency", exportAlpha)
        label((if d.depth == 16: "48-bit color (16 bits a channel)" & (if exportAlpha: " and its transparency" else: "")
               elif exportAlpha: "24-bit color and its transparency (32 bits a pixel)"
               else: "24-bit color (8 bits a channel)"), color = ui.theme.gray)
    of efBmp:
      group("BMP"):
        var b = if exportBmp32: 1 else: 0
        if radio("24-bit color", b, 0): exportBmp32 = false
        if radio("32-bit (its transparency kept)", b, 1): exportBmp32 = true
        exportAlpha = exportBmp32 or exportAlpha
    of efHdr, efPfm, efExr:
      group($f):
        label((if d.depth == 32: "The light at 32 bits a channel, as it is."
               else: "The picture made light (32 bits a channel); brighter than white needs a 32-bit image."),
              color = ui.theme.gray)
    of efPng8, efGif:
      group($f):
        row([70, -1, 36]):
          label "Colors:"
          slider(exportColors, 2, 256)
          label $exportColors
        checkbox("Dither", exportDither)
        checkbox("Transparency", exportAlpha)
    of efJxl:
      group("JPEG XL"):
        var lossless = not exportJxlLossy
        checkbox("Lossless (every pixel kept)", lossless)
        exportJxlLossy = not lossless
        if exportJxlLossy:
          row([70, -1, 36]):
            label "Quality:"
            slider(exportQuality, 1, 99)
            label $exportQuality
          label("90 looks the same as the picture; less: smaller", color = ui.theme.gray)
        else:
          label("Every pixel kept, smaller than PNG.", color = ui.theme.gray)
        row([70, -1, 36]):
          label "Effort:"
          slider(exportJxlEffort, 1, 9)
          label $exportJxlEffort
        label("1 quick .. 9 smallest (and slow on big pictures)", color = ui.theme.gray)
        checkbox("Transparency", exportAlpha)
    of efAvif, efHeic:
      group($f):
        let ok = (if f == efAvif: "avif" else: "heic") in systemEncodeExts()
        if not ok:
          label("This system has no " & $f & " encoder (Linux: libavif / libheif with its plugins; " &
                "macOS writes HEIC).", color = color(160, 0, 0))
        row:
          label "Quality:"
          slider(exportQuality, 1, 100)
          label $exportQuality
        checkbox("Transparency", exportAlpha)
    of efWebp:
      group("WebP"):
        checkbox("Lossless (every pixel kept)", exportWebpLossless)
        if not exportWebpLossless:
          row:
            label "Quality:"
            slider(exportQuality, 1, 100)
            label $exportQuality
        checkbox("Transparency", exportAlpha)
    of efTiff:
      group("TIFF"):
        row:
          label "Compression:"
          combo(["None", "LZW", "ZIP", "PackBits"], exportTiff, w = dp(120))
        checkbox("Transparency", exportAlpha)
        checkbox("Layers (kept in the TIFF, for editors that read them)", exportTiffLayers)
    of efTga:
      group("Targa"):
        checkbox("Compressed (RLE)", exportRle)
        checkbox("Transparency", exportAlpha)
    of efPsd:
      group("PSD"):
        label("Layers, masks, adjustment, shape and fill layers, styles and", color = ui.theme.gray)
        label("clipping masks are kept; type as pixels.", color = ui.theme.gray)
    else: discard
    if f in {efJpeg, efPng, efPng8, efTiff}:
      checkbox("Embed Color Profile (" & d.profileName & ")", exportProfile)
    if f notin {efPsd}:
      group("Image Size"):
        row([70, -1, 46]):
          label "Scale:"
          slider(exportScale, 5, 400)
          label $exportScale & "%"
        let nw = max(1, int(round(d.w.float * exportScale.float / 100)))
        let nh = max(1, int(round(d.h.float * exportScale.float / 100)))
        label($nw & " x " & $nh & " pixels", color = ui.theme.gray)
        if not (exportAlpha and f in {efPng, efPng8, efGif, efTiff, efTga, efWebp, efJxl, efAvif, efHeic}) and
           f notin {efHdr, efPfm, efExr} and
           not (f == efBmp and exportBmp32):
          row:
            label "Matte:"
            combo(["White", "Black", "Background Color", "Other..."], exportMatte, w = dp(150))
            if exportMatte == 3: colorWell(exportMatteColor, "exportmatte", dp(40))
    row:
      spring()
      if button("Export...", isDefault = true, w = dp(90)):
        exportOpen = false
        proc go() =
          let dir = if d.path.len > 0 and dirExists(d.path.parentDir): d.path.parentDir else: picturesDir()
          exportPath = dir / d.name & formatExts[f]
          exportPick = true
        if askStorage(AppName, filesWhy, go): go()
      if button("Cancel", w = dp(80)): exportOpen = false

proc exportTo(dw: DocWin; path: string) =
  try:
    beginBusy("Exporting " & path.extractFilename)
    try: dw.doc.exportPicture(path, exportOptions())
    finally: endBusy()
    status = "Exported " & path.extractFilename
  except CatchableError:
    status = "Could not export " & path.extractFilename & ": " & getCurrentExceptionMsg()

proc quickExport(dw: DocWin; f: ExportFormat) =
  ## File > Export > Quick Export: next to the image (or in Pictures), as
  ## PNG or JPEG.
  let d = dw.doc
  proc go() =
    let dir = if d.path.len > 0 and dirExists(d.path.parentDir): d.path.parentDir else: picturesDir()
    var p = dir / d.name & formatExts[f]
    var k = 1
    while fileExists(p) and p == d.path:
      p = dir / d.name & "-" & $k & formatExts[f]
      inc k
    try:
      beginBusy("Exporting " & p.extractFilename)
      try: d.exportPicture(p, defaultExport(f))
      finally: endBusy()
      status = "Exported " & p
    except CatchableError:
      status = "Could not export " & p.extractFilename & ": " & getCurrentExceptionMsg()
  if askStorage(AppName, filesWhy, go): go()

# ---- Layer from File --------------------------------------------------------------------------------

var layerFilePick = false

proc startLayerFromFile() =
  proc go() =
    if openPath.len == 0 or not dirExists(openPath.parentDir): openPath = picturesDir()
    layerFilePick = true
  if askStorage(AppName, filesWhy, go): go()

proc layerFromFile(d: Doc; path: string) =
  ## Layer > New > Layer from File: the picture (all its layers mixed) as a
  ## new layer above the current one, in the middle (made smaller to fit).
  try:
    beginBusy("Opening " & path.extractFilename)
    var src: Doc = nil
    try: src = openPicture(path)
    finally: endBusy()
    var c = Clip(w: src.w, h: src.h, px: src.flattened())
    src = nil
    if c.w > d.w or c.h > d.h:
      let k = min(d.w / c.w, d.h / c.h)
      let nw = max(1, int(c.w.float * k))
      let nh = max(1, int(c.h.float * k))
      c.px = resample(c.px, c.w, c.h, nw, nh, rsBicubic)
      c.w = nw
      c.h = nh
    d.snapStep("Layer from File")
    discard d.pasteAsLayer(c, centered = true, name = path.splitFile.name)
    d.endStep()
    status = "Added " & path.extractFilename & " as a layer"
  except CatchableError:
    status = "Could not open " & path.extractFilename & ": " & getCurrentExceptionMsg()

# ---- a picture too big to edit whole ------------------------------------------------------------------

var
  bigAsk: tuple[on: bool; path: string; w, h: int]
    ## Open: a smaller copy of the big picture, or a part of it?
  bigPart: tuple[on: bool; path: string; w, h: int; preview: Bitmap; x, y, pw, ph: int]
    ## Open a Part: the part (`x`, `y`, `pw` x `ph`, in the picture's pixels) picked on a preview
  bigDrag: tuple[kind, mx, my, x, y: int]
    ## (0: nothing; 1: the part moved; 2: a new part drawn -- from where)

proc bigRoom(w, h: int): tuple[w, h: int] =
  ## (the largest a picture -- or a part -- of `w` x `h` can be opened at here)
  largestSize(w, h, freeMemory())

proc megapixels(w, h: int): string =
  let mp = w.float * h.float / 1e6
  if mp >= 100: $int(round(mp)) else: formatFloat(mp, ffDecimal, 1)

proc openBig(path: string; part: bool) =
  ## Opens a smaller copy of a big picture, or the part picked (`bigPart`),
  ## as a new image (saving it never writes over the big file).
  let name = path.extractFilename
  try:
    beginBusy("Opening " & name, cancel = true)
    var d: Doc
    try:
      d = if part: openPictureRegion(path, bigPart.x, bigPart.y, bigPart.pw, bigPart.ph, freeMemory())
          else: openPictureScaled(path, freeMemory())
    finally: endBusy(cancel = true)
    addDoc(d)
    status = (if part: tr("A part of ") else: tr("A smaller copy of ")) & name & " (" & $d.w & " x " & $d.h & ")"
    rememberFile(path)
  except BusyCancelled:
    status = ""
  except CatchableError:
    status = "Could not open " & name & ": " & getCurrentExceptionMsg()

proc startBigPart(path: string; w, h: int) =
  ## Open a Part: a preview of all of the picture; the part at first the
  ## largest that can be opened, in its middle.
  try:
    beginBusy("Opening " & path.extractFilename, cancel = true)
    var pv: Bitmap
    try: pv = readScaled(path, 720, 540)
    finally: endBusy(cancel = true)
    let (lw, lh) = bigRoom(w, h)
    bigPart = (true, path, w, h, pv, (w - lw) div 2, (h - lh) div 2, lw, lh)
  except BusyCancelled:
    status = ""
  except CatchableError:
    status = "Could not open " & path.extractFilename & ": " & getCurrentExceptionMsg()

proc bigPictureDialogs() =
  ## The questions of a picture too big to edit whole: a smaller copy, or a
  ## part (picked on a preview)?
  if bigAsk.on:
    let (w, h) = (bigAsk.w, bigAsk.h)
    let (lw, lh) = bigRoom(w, h)
    var choice = 0
    dialog(bigAsk.on, "Big Picture", 460):
      row:
        msgIcon(miQuestion)
        col:
          label(tr("This picture is ") & $w & " x " & $h & " (" & megapixels(w, h) & " MP)" &
                tr(" -- too big to edit whole on this device."), literal = true)
          space(6)
          label("Open:", bold = true)
          row([136, -1]):
            if button("A Smaller Copy", isDefault = true, w = dp(132)): choice = 1
            label($lw & " x " & $lh & tr(" pixels, all of the picture"), color = ui.theme.gray, literal = true)
          row([136, -1]):
            if button("A Part of It...", w = dp(132)): choice = 2
            label("at full size, picked on a preview", color = ui.theme.gray)
      row:
        spring()
        if button("Cancel", w = dp(80)): bigAsk.on = false
    if choice == 1:
      bigAsk.on = false
      openBig(bigAsk.path, part = false)
    elif choice == 2:
      bigAsk.on = false
      startBigPart(bigAsk.path, w, h)
  if bigPart.on:
    var go = false
    dialog(bigPart.on, "Open a Part", 480):
      label("Drag on the picture to pick a part; drag the part to move it.")
      let pv = bigPart.preview
      let (box, pic, hit, dragging) = pictureBox("bigpart", pv, dp(440), dp(300))
      if pic.w > 0 and pic.h > 0:
        beginKeepSides(box)            # (the part drawn over the picture as it is, right to left too)
        let kx = bigPart.w / pic.w     # (the picture's pixels a screen pixel)
        let ky = bigPart.h / pic.h
        proc toPic(sx, sy: int): (int, int) =
          (clamp(int((sx - pic.x).float * kx), 0, bigPart.w), clamp(int((sy - pic.y).float * ky), 0, bigPart.h))
        let r = rect(pic.x + int(bigPart.x.float / kx), pic.y + int(bigPart.y.float / ky),
                     max(2, int(bigPart.pw.float / kx)), max(2, int(bigPart.ph.float / ky)))
        let onPart = r.contains(point(ui.mx, ui.my))
        if hit.down and ui.pressed:
          let (px, py) = toPic(ui.mx, ui.my)
          bigDrag = ((if onPart: 1 else: 2), px, py, bigPart.x, bigPart.y)
        if dragging and bigDrag.kind > 0:
          let (px, py) = toPic(ui.mx, ui.my)
          if bigDrag.kind == 1:
            # (the part moved, kept on the picture)
            bigPart.x = clamp(bigDrag.x + px - bigDrag.mx, 0, bigPart.w - bigPart.pw)
            bigPart.y = clamp(bigDrag.y + py - bigDrag.my, 0, bigPart.h - bigPart.ph)
          elif abs(px - bigDrag.mx).float >= 3 * kx or abs(py - bigDrag.my).float >= 3 * ky:
            # (a new part from where the drag began -- a click alone keeps the
            # one there was: no bigger than can be opened)
            let (cw, ch) = bigRoom(max(1, abs(px - bigDrag.mx)), max(1, abs(py - bigDrag.my)))
            bigPart.pw = cw
            bigPart.ph = ch
            bigPart.x = clamp(if px >= bigDrag.mx: bigDrag.mx else: bigDrag.mx - cw, 0, bigPart.w - cw)
            bigPart.y = clamp(if py >= bigDrag.my: bigDrag.my else: bigDrag.my - ch, 0, bigPart.h - ch)
        elif not ui.mouseDown: bigDrag.kind = 0
        pushClip(inset(box, 1))
        box(r, color(0, 0, 0))
        box(inset(r, 1), color(255, 255, 255))
        popClip()
        endKeepSides()
        if hit.hover: ui.cursor = (if onPart: curHand else: curCrosshair)
      label(tr("The part: ") & $bigPart.pw & " x " & $bigPart.ph & tr(" pixels"), literal = true)
      row:
        spring()
        if button("Open", isDefault = true, w = dp(80)): go = true
        if button("Cancel", w = dp(80)): bigPart.on = false
    if go:
      bigPart.on = false
      openBig(bigPart.path, part = true)
    if not bigPart.on: bigPart.preview = nil

proc openFile(path: string) =
  ## Opens a picture in a window (a raw photo in Camera Raw first); it is
  ## first in File › Open Recent. A picture too big to edit whole asks
  ## first: a smaller copy of it, or a part?
  for o in docs:
    if o.doc.path == path and path.len > 0:
      o.showDoc()                       # (open already: brought forward)
      rememberFile(path)
      return
  let (bw, bh) = bigPictureSize(path)
  if bw > 0 and pictureTooBig(path, freeMemory()):
    bigAsk = (true, path, bw, bh)
    return
  try:
    # (a big file: its picture shown while it loads -- a document's own
    # small one, or the photo decoded small)
    let big = (try: getFileSize(path) > 3_000_000 except OSError: false)
    let quick = path.splitFile.ext.toLowerAscii in [".rpd", ".rp3", ".psd", ".psb", ".jpg", ".jpeg"]
    if big and quick: busyPicture = loadPicture(path, dp(320) * pxScale, dp(180) * pxScale)
    beginBusy("Opening " & path.extractFilename)
    try:
      if path.toLowerAscii.endsWith(".pdf") or path.toLowerAscii.endsWith(".ai"):
        endBusy()
        busyPicture = nil
        startPdfImport(path)
        return
      if path.splitFile.ext.toLowerAscii in rawExts:
        # (a camera's raw photo: opened as shot, Camera Raw to develop it)
        let raw = readRaw(readFile(path))
        let d = docOfRaw(raw, path.splitFile.name)
        d.path = path
        d.format = path.splitFile.ext.toLowerAscii[1 .. ^1]
        addDoc(d)
        startCameraRaw(raw)
      else:
        addDoc(openPicture(path))
    finally:
      endBusy()
      busyPicture = nil
    status = ""
    rememberFile(path)
  except CatchableError:
    status = "Could not open " & path.extractFilename & ": " & getCurrentExceptionMsg()

proc fileDialogs() =
  bigPictureDialogs()
  if filePicker(openPick, openPath, fmOpen, openPatterns, "Open"):
    openFile(openPath)
  if filePicker(placePick, openPath, fmOpen, openPatterns, "Place"):
    let d = cur()
    if d != nil: d.placeSmart(openPath)
  if filePicker(layerFilePick, openPath, fmOpen, openPatterns, "Layer from File"):
    let d = cur()
    if d != nil: d.layerFromFile(openPath)
  if filePicker(exportPick, exportPath, fmSave, ["*" & formatExts[exportFormats[clamp(exportFmt, 0, exportFormats.high)]]],
                "Export As"):
    if exportDoc != nil:
      var p = exportPath
      let want = formatExts[exportFormats[clamp(exportFmt, 0, exportFormats.high)]]
      if p.splitFile.ext.toLowerAscii != want and not (want == ".jpg" and p.splitFile.ext.toLowerAscii == ".jpeg"):
        p.add want
      exportDoc.exportTo(p)
  exportDialog()
  if filePicker(pdfPick, pdfPath, fmSave, ["*.pdf"], "Save as PDF"):
    if pdfDoc != nil:
      var p = pdfPath
      if p.splitFile.ext.toLowerAscii != ".pdf": p.add ".pdf"
      startPdfOptions(@[pdfDoc.doc], p)
  if filePicker(savePick, savePath, fmSave, savePatterns, "Save As"):
    if saveDoc != nil:
      var p = savePath
      if p.splitFile.ext.len == 0: p.add ".rpd"
      savePath = p
      let ext = p.splitFile.ext.toLowerAscii
      if ext in [".jpg", ".jpeg"]:
        jpegOpen = true
      elif ext == ".pdf":
        startPdfOptions(@[saveDoc.doc], p)
      elif ext in [".eps", ".ps"]:
        startEpsOptions(saveDoc, p)
      else:
        if ext notin [".rpd", ".rp3", ".psd", ".psb"] and saveDoc.doc.layers.len > 1: flatWarn = true
        saveDoc.writeDoc(p)
  if jpegOpen:
    dialog(jpegOpen, "JPEG Options", 340):
      label("Image Quality:", bold = true)
      row([36, -1, 64]):
        label "Low"
        slider(jpegQuality, 0, 10, ticks = 10)
        label "Maximum"
      label("Quality " & $jpegQuality & ": " &
            ["Low", "Low", "Low", "Medium", "Medium", "Medium", "High", "High", "Maximum", "Maximum", "Maximum"][jpegQuality],
            color = ui.theme.gray)
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)):
          jpegOpen = false
          if saveDoc != nil: saveDoc.writeDoc(savePath, 10 + jpegQuality * 9)
        if button("Cancel", w = dp(80)): jpegOpen = false
  case msgBox(flatWarn, AppName, "The layers were mixed into one picture in that file. Save as " &
              "Retro Photo (.rpd) or PSD (.psd) to keep them.", ["OK"], miInfo)
  else: discard
  if infoOpen:
    dialog(infoOpen, "File Info", 420):
      form 0:
        field "Caption:": edit(fileInfo.caption)
        field "Author:": edit(fileInfo.author)
        field "Title:": edit(fileInfo.title)
        field "Keywords:": edit(fileInfo.keywords)
        field "Copyright:": edit(fileInfo.copyright)
        field "URL:": edit(fileInfo.url)
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)):
          if cur() != nil:
            cur().info = fileInfo
            cur().modified = true
          infoOpen = false
        if button("Cancel", w = dp(80)): infoOpen = false

var
  psOpen = false
  psPaper = 0                  ## A4, Letter, Legal, A3
  psLandscape = 0
  psScale = 100
  psCaption = true
  psLabels = true
  psNegative = false
  texturePick = false
  texturePath = ""

proc pageOf(): PageSize =
  let p = [A4, Letter, Legal, A3][clamp(psPaper, 0, 3)]
  if psLandscape == 1: landscape(p) else: p

proc printDoc(d: Doc) =
  ## The image at its size (its resolution, Page Setup's scaling), with its
  ## name and caption when asked for.
  let r = newReport(d.name, page = pageOf())
  if psLabels: r.heading(d.name, level = 3)
  var b = d.toBitmap(white)
  if psNegative:
    for p in b.px.mitems: p = (p and 0xFF000000'u32) or (not p and 0xFFFFFF'u32)
  let k = psScale.float / 100 * 72 / max(1.0, d.dpi)
  r.image(b, w = d.w.float * k, h = d.h.float * k, align = alCenter)
  if psCaption and d.info.caption.len > 0: r.paragraph(d.info.caption, align = alCenter)
  let res = r.printReport(d.name)
  status = if res.ok: "Sent to the printer" else: res.message

proc pageSetupDialog() =
  if not psOpen: return
  dialog(psOpen, "Page Setup", 420):
    row([-1, 92]):
      col:
        group("Paper"):
          row:
            label "Size:"
            combo(["A4", "Letter", "Legal", "A3"], psPaper, w = dp(110))
          row:
            radio("Portrait", psLandscape, 0)
            radio("Landscape", psLandscape, 1)
        row:
          label "Scaling:"
          intEdit(psScale, w = dp(56), lo = 1, hi = 1000)
          label "%"
        row([-1, -1]):
          checkbox("Caption", psCaption)
          checkbox("Labels", psLabels)
        row([-1, -1]):
          checkbox("Negative", psNegative)
          var bars = false
          checkbox("Calibration Bars", bars, enabled = false)
      col:
        if button("OK", isDefault = true, w = dp(86)): psOpen = false
        if button("Cancel", w = dp(86)): psOpen = false
        space(dp(6))
        for b in ["Screens...", "Transfer...", "Border...", "Bleed..."]:
          discard button(b, w = dp(86), enabled = false)

proc textureDialogs() =
  ## Render > Texture Fill: a picture (made gray) tiled in the selection.
  if filePicker(texturePick, texturePath, fmOpen, ["*.png", "*.jpg", "*.jpeg", "*.bmp", "*.gif"],
                "Texture Fill"):
    let d = cur()
    if d != nil:
      let b = try: loadPicture(texturePath, 2000, 2000) except CatchableError: nil
      if b == nil or b.w <= 0:
        status = "Could not read " & texturePath.extractFilename
      else:
        let tw = b.w
        let th2 = b.h
        let px = b.px
        d.beginStep("Texture Fill")
        d.mapPixels(d.layer, d.bounds, proc (p: uint32; x, y: int): uint32 =
          grayPx(lumaOf(px[(y mod th2) * tw + (x mod tw)])))
        d.endStep()

# ---- adjustments: previewed on the image ---------------------------------------------------------------

type AdjKind = enum akLevels, akCurves, akBC, akBalance, akHS, akThreshold, akPosterize, akReplace,
                   akSelective, akShadows, akVibrance, akExposure, akPhotoFilter, akBlackWhite, akMixer,
                   akGradMap, akLookup

var
  adjOpen = false
  adjKind: AdjKind
  adjDoc: Doc
  adjLayer: Layer
  adjRect: Rect
  adjSrc: Img
  adjPreview = true
  adjSig = ""
  adjAt = 0
  # levels
  lvChan = 0
  lv: array[4, Levels]
  lvIn, lvOut: seq[int]
  lvHist: Histogram
  # curves
  cvChan = 0
  cv: array[4, seq[(int, int)]]
  # brightness / contrast
  bcB, bcC = 0
  # color balance
  balTone = 1
  bal: array[3, array[3, int]]
  balLum = true
  # hue / saturation
  hsH, hsS, hsL = 0
  hsColorize = false
  hsAdj: HueAdjust            ## per color range (Master, Reds...)
  hsEdit = 0                  ## the range the sliders edit
  # threshold, posterize
  thLevel = 128
  postLevels = 4
  # replace color
  rcFuzz = 40
  rcSample = 0xFFFF0000'u32
  rcMask: seq[uint8]
  rcMaskKey = ""
  # selective color
  scAdj: SelectiveColor
  scColors = 0
  scRelative = 0
  # shadows / highlights
  shAmount = 35
  hlAmount = 0
  # vibrance
  vibV, vibS = 0
  # exposure (hundredths of a stop; ten-thousandths; hundredths)
  exE, exOff = 0
  exGamma = 100
  # photo filter
  pfUse = 0                   ## a filter (0) or a color (1)
  pfKind = 0
  pfColor = 0xFFEC8A00'u32
  pfDensity = 25
  pfLum = true
  # black & white
  bwW: array[6, int]
  bwTint = false
  bwHue = 35
  bwSat = 25
  # channel mixer
  cmOut = 0
  cm: array[3, array[4, int]]
  cmMono = false
  adjShown = ""               ## what the image shows (adjSignature and Preview)
  adjOnLayer: Layer           ## an adjustment layer being made or changed (nil: pixels)
  adjNewLayer = false         ## (the adjustment layer is a new one: an action takes it)

const adjNames: array[AdjKind, string] = ["Levels", "Curves", "Brightness/Contrast", "Color Balance",
                                          "Hue/Saturation", "Threshold", "Posterize", "Replace Color",
                                          "Selective Color", "Shadows/Highlights", "Vibrance", "Exposure",
                                          "Photo Filter", "Black & White", "Channel Mixer", "Gradient Map",
                                          "Color Lookup"]

proc adjFn(): FilterFn =
  case adjKind
  of akLevels:
    applyLuts(levelsLut(lv[0]), levelsLut(lv[1]), levelsLut(lv[2]), levelsLut(lv[3]))
  of akCurves:
    applyLuts(curveLut(cv[0]), curveLut(cv[1]), curveLut(cv[2]), curveLut(cv[3]))
  of akBC: brightnessContrast(bcB, bcC)
  of akBalance: colorBalance(bal[0], bal[1], bal[2], balLum)
  of akHS:
    if hsColorize: hueSaturation(hsH, hsS, hsL, true)
    else:
      var a = hsAdj
      a[hsEdit] = [hsH, hsS, hsL]
      hueSaturation(a)
  of akThreshold: threshold(thLevel)
  of akPosterize: posterize(postLevels)
  of akReplace: hueSaturation(hsH, hsS, hsL)
  of akSelective: selectiveColor(scAdj, scRelative == 0)
  of akShadows: shadowsHighlights(shAmount, hlAmount)
  of akVibrance: vibranceFn(vibV, vibS)
  of akExposure: exposureFn(exE / 100, exOff / 10000, exGamma / 100)
  of akPhotoFilter: photoFilter((if pfUse == 0: photoFilters[pfKind][1] else: pfColor), pfDensity, pfLum)
  of akBlackWhite: blackAndWhite(bwW, bwTint, bwHue, bwSat)
  of akMixer: channelMixer(cm, cmMono)
  of akGradMap: gradientMap(gmStops, gmReverse, gmDither)
  of akLookup:
    let f = colorLookup(luData)
    if f == nil: (proc (src: Img; inner: Rect): Img = src) else: f

proc adjSignature(): string =
  case adjKind
  of akLevels: $lv
  of akCurves: $cv
  of akBC: $bcB & "," & $bcC
  of akBalance: $bal & $balLum
  of akHS: $hsH & "," & $hsS & "," & $hsL & $hsColorize & $hsAdj & $hsEdit
  of akThreshold: $thLevel
  of akPosterize: $postLevels
  of akReplace: $hsH & "," & $hsS & "," & $hsL & "," & $rcFuzz & "," & $rcSample
  of akSelective: $scAdj & $scRelative
  of akShadows: $shAmount & "," & $hlAmount
  of akVibrance: $vibV & "," & $vibS
  of akExposure: $exE & "," & $exOff & "," & $exGamma
  of akPhotoFilter: $pfUse & "," & $pfKind & "," & $pfColor & "," & $pfDensity & $pfLum
  of akBlackWhite: $bwW & $bwTint & $bwHue & "," & $bwSat
  of akMixer: $cm & $cmMono
  of akGradMap: $gmStops & $gmReverse & $gmDither
  of akLookup: $luData.len & "/" & $hash(luData)

proc adjArgs(): seq[float]
proc adjData(): string = (if adjKind == akLookup: luData else: "")

proc adjWrite(apply: bool) =
  ## The layer's part from the copy kept, changed by the adjustment
  ## (`apply`) or as it was. (On all the cores: a live preview even on a
  ## big photo.)
  let d = adjDoc
  if adjOnLayer != nil:
    # an adjustment layer: its settings, the image made again under it
    adjOnLayer.visible = apply
    d.setAdjustment(adjOnLayer, Adjustment(kind: adjNames[adjKind], args: adjArgs(), data: adjData()))
    adjShown = adjSignature() & $apply
    return
  let r = adjRect
  adjShown = adjSignature() & $apply
  if not apply:
    d.writeBack(adjLayer, r, adjSrc, base = adjSrc)
    return
  let o = adjFn()(adjSrc, rect(0, 0, r.w, r.h))
  if adjKind == akReplace:
    let key = $rcSample & "/" & $rcFuzz
    if key != rcMaskKey:
      # (from the layer as it was, not as the last preview left it)
      d.writeBack(adjLayer, r, adjSrc, base = adjSrc)
      rcMask = d.colorRangeMask(rcSample, rcFuzz, false)
      rcMaskKey = key
    d.writeBack(adjLayer, r, o, rcMask, base = adjSrc)
  else:
    d.writeBack(adjLayer, r, o, base = adjSrc)

proc resetAdjust(k: AdjKind; d: Doc)

proc startAdjust(k: AdjKind) =
  let d = cur()
  if d == nil: return
  adjDoc = d
  adjLayer = d.layer
  adjRect = d.workRect
  if adjRect.w <= 0 or adjRect.h <= 0: return
  adjKind = k
  adjSrc = d.filterImg(adjLayer, 0, proc (src: Img; inner: Rect): Img = src, adjRect)
  d.beginStep(adjNames[k])
  d.touch(adjLayer, adjRect)
  adjOnLayer = nil
  adjSig = adjSignature()
  resetAdjust(k, d)
  adjOpen = true
  adjSig = ""
  adjShown = ""
  adjAt = 0

proc resetAdjust(k: AdjKind; d: Doc) =
  ## An adjustment's settings as it starts (changing nothing).
  case k
  of akLevels:
    lvHist = d.histogram(merged = false)
    for c in 0 .. 3: lv[c] = defaultLevels()
    lvChan = 0
  of akCurves:
    for c in 0 .. 3: cv[c] = @[(0, 0), (255, 255)]
    cvChan = 0
  of akBC:
    bcB = 0; bcC = 0
  of akBalance:
    for t in 0 .. 2:
      for c in 0 .. 2: bal[t][c] = 0
  of akHS, akReplace:
    hsH = 0; hsS = 0; hsL = 0; hsColorize = false
    hsAdj = default(HueAdjust)
    hsEdit = 0
    rcSample = fg
    rcMaskKey = ""
  of akThreshold:
    lvHist = d.histogram(merged = false)
    thLevel = 128
  of akPosterize: postLevels = 4
  of akSelective:
    scAdj = default(SelectiveColor)
    scColors = 0
  of akShadows:
    shAmount = 35; hlAmount = 0
  of akVibrance:
    vibV = 0; vibS = 0
  of akExposure:
    exE = 0; exOff = 0; exGamma = 100
  of akPhotoFilter:
    pfUse = 0; pfKind = 0; pfDensity = 25; pfLum = true
  of akBlackWhite:
    bwW = defaultBlackAndWhite()
    bwTint = false
  of akMixer:
    cm = [[100, 0, 0, 0], [0, 100, 0, 0], [0, 0, 100, 0]]
    cmOut = 0
    cmMono = false
  of akGradMap:
    gmStops = @[GradientStop(at: 0, color: fg or 0xFF000000'u32), GradientStop(at: 1, color: bg or 0xFF000000'u32)]
    gmReverse = false
    gmDither = false
  of akLookup:
    if luData.len == 0: luData = "look:Film Stock"

const layerKinds = {akLevels, akCurves, akBC, akBalance, akHS, akThreshold, akPosterize, akSelective,
                    akVibrance, akExposure, akPhotoFilter, akBlackWhite, akMixer, akGradMap, akLookup}
  ## (the adjustments that can be adjustment layers)

proc adjArgs(): seq[float] =
  ## The settings as an adjustment layer keeps them (`adjustmentFn`).
  case adjKind
  of akLevels:
    for c in 0 .. 3:
      result.add [lv[c].inLo.float, lv[c].inHi.float, lv[c].gamma, lv[c].outLo.float, lv[c].outHi.float]
  of akCurves:
    for c in 0 .. 3:
      result.add cv[c].len.float
      for (x, y) in cv[c]: result.add [x.float, y.float]
  of akBC: result = @[bcB.float, bcC.float]
  of akBalance:
    for t in 0 .. 2:
      for c in 0 .. 2: result.add bal[t][c].float
    result.add(if balLum: 1.0 else: 0.0)
  of akHS:
    if hsColorize: result = @[1.0, hsH.float, hsS.float, hsL.float]
    else:
      var a = hsAdj
      a[hsEdit] = [hsH, hsS, hsL]
      result = @[0.0]
      for r in 0 .. 6:
        for k in 0 .. 2: result.add a[r][k].float
  of akSelective:
    result = @[(if scRelative == 0: 1.0 else: 0.0)]
    for r in 0 .. 8:
      for k in 0 .. 3: result.add scAdj[r][k].float
  of akVibrance: result = @[vibV.float, vibS.float]
  of akExposure: result = @[exE / 100, exOff / 10000, exGamma / 100]
  of akPhotoFilter:
    let c = if pfUse == 0: photoFilters[pfKind][1] else: pfColor
    result = @[rOf(c).float, gOf(c).float, bOf(c).float, pfDensity.float, (if pfLum: 1.0 else: 0.0)]
  of akBlackWhite:
    for v in bwW: result.add v.float
    result.add [(if bwTint: 1.0 else: 0.0), bwHue.float, bwSat.float]
  of akMixer:
    for o in 0 .. 2:
      for k in 0 .. 3: result.add cm[o][k].float
    result.add(if cmMono: 1.0 else: 0.0)
  of akThreshold: result = @[thLevel.float]
  of akPosterize: result = @[postLevels.float]
  of akGradMap: result = gradientMapArgs(gmStops, gmReverse, gmDither)
  else: discard

proc loadAdjArgs(a: seq[float]) =
  ## The dialog's settings from an adjustment layer's.
  template at(i: int): float = (if i < a.len: a[i] else: 0.0)
  template ai(i: int): int = int(round(at(i)))
  case adjKind
  of akLevels:
    if a.len >= 20:
      for c in 0 .. 3:
        lv[c] = Levels(inLo: ai(c * 5), inHi: ai(c * 5 + 1), gamma: at(c * 5 + 2), outLo: ai(c * 5 + 3),
                       outHi: ai(c * 5 + 4))
  of akCurves:
    var i = 0
    for c in 0 .. 3:
      cv[c] = @[]
      let n = ai(i)
      inc i
      for k in 0 ..< n:
        cv[c].add (ai(i), ai(i + 1))
        i += 2
      if cv[c].len < 2: cv[c] = @[(0, 0), (255, 255)]
  of akBC:
    bcB = ai(0); bcC = ai(1)
  of akBalance:
    for t in 0 .. 2:
      for c in 0 .. 2: bal[t][c] = ai(t * 3 + c)
    balLum = ai(9) != 0
  of akHS:
    hsColorize = ai(0) != 0
    hsEdit = 0
    if hsColorize:
      hsH = ai(1); hsS = ai(2); hsL = ai(3)
    else:
      for r in 0 .. 6:
        for k in 0 .. 2: hsAdj[r][k] = ai(1 + r * 3 + k)
      hsH = hsAdj[0][0]; hsS = hsAdj[0][1]; hsL = hsAdj[0][2]
  of akSelective:
    scRelative = if ai(0) != 0: 0 else: 1
    for r in 0 .. 8:
      for k in 0 .. 3: scAdj[r][k] = ai(1 + r * 4 + k)
  of akVibrance:
    vibV = ai(0); vibS = ai(1)
  of akExposure:
    exE = int(round(at(0) * 100)); exOff = int(round(at(1) * 10000)); exGamma = int(round(at(2) * 100))
  of akPhotoFilter:
    let c = argb(255, ai(0), ai(1), ai(2))
    pfUse = 1
    pfColor = c
    for k, (n, fc) in photoFilters:
      if fc == c:
        pfUse = 0
        pfKind = k
    pfDensity = ai(3)
    pfLum = ai(4) != 0
  of akBlackWhite:
    for k in 0 .. 5: bwW[k] = ai(k)
    bwTint = ai(6) != 0
    bwHue = ai(7); bwSat = ai(8)
  of akMixer:
    for o in 0 .. 2:
      for k in 0 .. 3: cm[o][k] = ai(o * 4 + k)
    cmMono = ai(12) != 0
  of akThreshold: thLevel = ai(0)
  of akPosterize: postLevels = ai(0)
  of akGradMap:
    let g = gradientMapOf(a)
    gmStops = g.stops
    gmReverse = g.reverse
    gmDither = g.dither
  else: discard

proc startAdjustLayer(k: AdjKind; L: Layer = nil) =
  ## An adjustment layer: a new one (`L` nil) above the current layer, or
  ## `L` changed -- previewed live, as the dialog's settings change it.
  let d = cur()
  if d == nil or k notin layerKinds: return
  adjDoc = d
  adjKind = k
  resetAdjust(k, d)
  adjNewLayer = L == nil
  if L == nil:
    d.beginStep("New Adjustment Layer")
    adjOnLayer = d.newAdjustmentLayer(Adjustment(kind: adjNames[k], args: adjArgs(), data: adjData()))
  else:
    d.beginStep(adjNames[k] & " Layer")
    d.touchLayers()
    adjOnLayer = L
    loadAdjArgs(L.adjust.args)
    if k == akLookup and L.adjust.data.len > 0: luData = L.adjust.data
  if k in {akLevels, akThreshold}:
    # (the image under the layer)
    let vis = adjOnLayer.visible
    adjOnLayer.visible = false
    d.markAll()
    lvHist = d.histogram(merged = true)
    adjOnLayer.visible = vis
    d.markAll()
  adjOpen = true
  adjSig = ""
  adjShown = ""
  adjAt = 0

proc editAdjustLayer(L: Layer) =
  if L.adjust.kind == "Invert": return            # (nothing to set)
  if L.adjust.kind in ["Clarity", "Dehaze", "Grain"]:
    showPanel("properties")                       # (set in Properties, as the usual)
    return
  for k in AdjKind:
    if adjNames[k] == L.adjust.kind and k in layerKinds:
      startAdjustLayer(k, L)

proc newAreaAdjustment(d: Doc; kind: string) =
  ## Clarity, Dehaze or Grain as a new adjustment layer (its settings in
  ## Properties, as the usual).
  let args = case kind
             of "Grain": @[25.0, 25, 50, float(1 + d.layers.len)]
             else: @[30.0]
  d.beginStep("New Adjustment Layer")
  discard d.newAdjustmentLayer(Adjustment(kind: kind, args: args))
  d.endStep()
  showPanel("properties")

proc adjustLayerMenu(d: Doc) =
  ## The kinds of adjustment layer, to make one.
  for k in [akLevels, akCurves, akBC, akBalance, akHS, akSelective, akVibrance, akExposure,
            akPhotoFilter, akBlackWhite, akMixer, akGradMap, akLookup, akThreshold, akPosterize]:
    if menuItem(adjNames[k].replace("&", "&&") & "...", enabled = d.mode in colorModes or k notin {akBalance, akHS, akSelective,
                                                                           akVibrance, akPhotoFilter,
                                                                           akBlackWhite, akMixer}):
      startAdjustLayer(k)
  if menuItem("Invert"):
    d.beginStep("New Adjustment Layer")
    discard d.newAdjustmentLayer(Adjustment(kind: "Invert"))
    d.endStep()
  menuSeparator()
  for k in ["Clarity", "Dehaze", "Grain"]:
    if menuItem(k & "...", enabled = d.mode in colorModes): newAreaAdjustment(d, k)

proc endAdjust(ok: bool) =
  adjOpen = false
  if adjDoc == nil: return
  adjDoc.endLive()
  if adjOnLayer != nil:
    if ok:
      adjOnLayer.visible = true
      adjDoc.setAdjustment(adjOnLayer, Adjustment(kind: adjNames[adjKind], args: adjArgs(), data: adjData()))
      adjDoc.endStep()
      if adjNewLayer and recording:
        record(ActStep(kind: acAdjustLayer, name: adjNames[adjKind], vals: adjArgs(), data: adjData()))
    else:
      adjDoc.cancelStep()
    adjOnLayer = nil
    adjDoc = nil
    return
  if ok:
    # (what the preview shows already, not worked out again)
    if adjShown != adjSignature() & "true": adjWrite(true)
    adjDoc.endStep()
    if recording and adjKind != akReplace:
      record(ActStep(kind: acAdjust, name: adjNames[adjKind], vals: adjArgs(), data: adjData()))
  else:
    adjWrite(false)
    adjDoc.cancelStep()
  adjSrc = Img()
  adjDoc = nil

proc adjButtons(): bool =
  ## OK, Cancel, Preview at the right of an adjustment dialog.
  col:
    if button("OK", isDefault = true, w = dp(86)):
      endAdjust(true)
      return true
    if button("Cancel", w = dp(86)):
      endAdjust(false)
      return true
    if adjKind in {akLevels}:
      if button("Auto", w = dp(86)):
        let a = autoLevels(lvHist)
        lv[0] = defaultLevels()
        for c in 0 .. 2: lv[c + 1] = a[c]
    if adjKind in {akLevels, akCurves}:
      # (the usual presets: .alv, .acv)
      let f = if adjKind == akLevels: pfLevels else: pfCurves
      if button("Load...", w = dp(86)): startPresetFile(f)
      if button("Save...", w = dp(86)): startPresetFile(f, save = true)
    space(dp(6))
    checkbox("Preview", adjPreview)

proc levelsBody() =
  row([-1, 92]):
    col:
      row:
        label "Channel:"
        combo(["RGB", "Red", "Green", "Blue"], lvChan, w = dp(110))
      var l = lv[lvChan]
      row:
        label "Input Levels:"
        intEdit(l.inLo, w = dp(48), lo = 0, hi = 253)
        var g = l.gamma
        numberEdit(g, decimals = 2, w = dp(56), lo = 0.1, hi = 9.99)
        l.gamma = g
        intEdit(l.inHi, w = dp(48), lo = 2, hi = 255)
      histogramView(lvHist.counts[lvChan], dp(256), dp(110))
      # the gray triangle sits where the gamma puts the middle
      let mid = l.inLo + int(round(pow(0.5, l.gamma) * (l.inHi - l.inLo).float))
      lvIn = @[l.inLo, clamp(mid, l.inLo + 1, l.inHi - 1), l.inHi]
      let moved = levelSlider(lvIn, dp(256))
      if moved == 0: l.inLo = lvIn[0]
      elif moved == 2: l.inHi = lvIn[2]
      elif moved == 1:
        let t = (lvIn[1] - l.inLo) / max(1, l.inHi - l.inLo)
        l.gamma = clamp(ln(0.5) / ln(clamp(t, 0.01, 0.99)), 0.1, 9.99)
      row:
        label "Output Levels:"
        intEdit(l.outLo, w = dp(48), lo = 0, hi = 255)
        intEdit(l.outHi, w = dp(48), lo = 0, hi = 255)
      gradientBar(dp(256), dp(10), color(0, 0, 0), color(255, 255, 255))
      lvOut = @[l.outLo, l.outHi]
      let mo = levelSlider(lvOut, dp(256))
      if mo >= 0:
        l.outLo = lvOut[0]
        l.outHi = lvOut[1]
      lv[lvChan] = l
    discard adjButtons()

proc curvesBody() =
  row([-1, 92]):
    col:
      row:
        label "Channel:"
        combo(["RGB", "Red", "Green", "Blue"], cvChan, w = dp(110))
      let lut = curveLut(cv[cvChan])
      curvesEditor(cv[cvChan], dp(256), lut)
      gradientBar(dp(256) + 2, dp(10), color(0, 0, 0), color(255, 255, 255))
      let inside = mouseIn(rect(ui.lastRect.x, ui.lastRect.y - dp(256) - 4, dp(256), dp(256)))
      let x = clamp((ui.mx - ui.lastRect.x) * 255 div max(1, dp(256)), 0, 255)
      label(if inside: "Input: " & $x & "   Output: " & $lut[x] else: "Click the curve to add a point; drag one out to remove it",
            color = ui.theme.gray)
    col:
      discard adjButtons()
      space(dp(6))
      if button("Reset", w = dp(86)):
        cv[cvChan] = @[(0, 0), (255, 255)]

proc bcBody() =
  row([300, -1]):
    col:
      optSlider("Brightness:", bcB, -100, 100, "")
      optSlider("Contrast:", bcC, -100, 100, "")
    discard adjButtons()

proc balanceBody() =
  row([330, -1]):
    col:
      group("Color Balance"):
        row:
          label "Color Levels:"
          for c in 0 .. 2: intEdit(bal[balTone][c], w = dp(48), lo = -100, hi = 100)
        for (c, a, b) in [(0, "Cyan", "Red"), (1, "Magenta", "Green"), (2, "Yellow", "Blue")]:
          row([60, -1, 46]):
            label a
            slider(bal[balTone][c], -100, 100, ticks = 0)
            label b
      group("Tone Balance"):
        row:
          radio("Shadows", balTone, 0)
          radio("Midtones", balTone, 1)
          radio("Highlights", balTone, 2)
        checkbox("Preserve Luminosity", balLum)
    discard adjButtons()

proc hsBody() =
  row((if adjKind == akHS: [96, 300, -1] else: [0, 330, -1])):
    if adjKind == akHS:
      col:
        # which colors the sliders change: all, or one range
        var e = hsEdit
        for k, n in ["Master", "R", "Y", "G", "C", "B", "M"]:
          row([60, 16]):
            pushId("hsedit" & $k)
            if radio(n, e, k, enabled = not hsColorize): discard
            popId()
            let sw = place(dp(14), dp(14))
            if k > 0:
              fill(sw, colorOf(fromHsb(float(k - 1) * 60, 1, 1)))
              box(sw, ui.theme.frame)
        if e != hsEdit:
          hsAdj[hsEdit] = [hsH, hsS, hsL]
          hsEdit = e
          hsH = hsAdj[e][0]; hsS = hsAdj[e][1]; hsL = hsAdj[e][2]
    else:
      space(0)
    col:
      if adjKind == akReplace:
        group("Selection"):
          row:
            label "Color:"
            colorWell(rcSample, "rcsample", dp(40))
            if toolButton("FG", "The foreground color"): rcSample = fg or 0xFF000000'u32
          optSlider("Fuzziness:", rcFuzz, 1, 200, "")
      optSlider("Hue:", hsH, (if hsColorize: 0 else: -180), (if hsColorize: 360 else: 180), "")
      optSlider("Saturation:", hsS, (if hsColorize: 0 else: -100), 100, "")
      optSlider("Lightness:", hsL, -100, 100, "")
      if adjKind == akHS:
        if checkbox("Colorize", hsColorize):
          if hsColorize:
            hsAdj[hsEdit] = [hsH, hsS, hsL]
            hsEdit = 0
            hsH = clamp(hsH, 0, 360)
            hsS = 25
          else:
            hsH = hsAdj[0][0]; hsS = hsAdj[0][1]; hsL = hsAdj[0][2]
      # the sample: the hue strip before and after
      let r = place(dp(300), dp(18))
      let f = adjFn()
      var one = newImg(1, 1)
      for x in 0 ..< r.w:
        let c = fromHsb(x / r.w * 360, 1, 1)
        one.px[0] = c
        vline(r.x + x, r.y, r.h div 2, colorOf(c))
        vline(r.x + x, r.y + r.h div 2, r.h - r.h div 2, colorOf(f(one, rect(0, 0, 1, 1)).px[0]))
      box(r, ui.theme.frame)
    discard adjButtons()

proc selectiveBody() =
  row([-1, 92]):
    col:
      row:
        label "Colors:"
        combo(["Reds", "Yellows", "Greens", "Cyans", "Blues", "Magentas", "Whites", "Neutrals", "Blacks"],
              scColors, w = dp(130))
      for k, n in ["Cyan:", "Magenta:", "Yellow:", "Black:"]:
        pushId("sc" & $k)
        optSlider(n, scAdj[scColors][k], -100, 100)
        popId()
      group("Method:"):
        row:
          radio("Relative", scRelative, 0)
          radio("Absolute", scRelative, 1)
    discard adjButtons()

proc thresholdBody() =
  row([-1, 92]):
    col:
      histogramView(lvHist.counts[0], dp(256), dp(110))
      var v = @[thLevel]
      if levelSlider(v, dp(256)) >= 0: thLevel = v[0]
      row:
        label "Threshold Level:"
        intEdit(thLevel, w = dp(56), lo = 1, hi = 255)
    discard adjButtons()

proc posterizeBody() =
  row([220, -1]):
    col:
      row:
        label "Levels:"
        intEdit(postLevels, w = dp(56), lo = 2, hi = 255)
    discard adjButtons()

proc shadowsBody() =
  row([-1, 92]):
    col:
      group("Shadows"):
        optSlider("Amount:", shAmount, 0, 100)
      group("Highlights"):
        optSlider("Amount:", hlAmount, 0, 100)
    discard adjButtons()

proc vibranceBody() =
  row([-1, 92]):
    col:
      optSlider("Vibrance:", vibV, -100, 100, "")
      optSlider("Saturation:", vibS, -100, 100, "")
    discard adjButtons()

proc exposureBody() =
  row([-1, 92]):
    col:
      row([86, -1, 56]):
        label "Exposure:"
        slider(exE, -500, 500, ticks = 0)
        label((if exE > 0: "+" else: "") & formatFloat(exE / 100, ffDecimal, 2))
      row([86, -1, 56]):
        label "Offset:"
        slider(exOff, -2500, 2500, ticks = 0)
        label((if exOff > 0: "+" else: "") & formatFloat(exOff / 10000, ffDecimal, 4))
      row([86, -1, 56]):
        label "Gamma:"
        slider(exGamma, 10, 400, ticks = 0)
        label(formatFloat(exGamma / 100, ffDecimal, 2))
    discard adjButtons()

proc photoFilterBody() =
  row([-1, 92]):
    col:
      group("Use"):
        row:
          radio("Filter:", pfUse, 0)
          var names: seq[string]
          for (n, c) in photoFilters: names.add n
          if combo(names, pfKind, w = dp(180)): pfUse = 0
        row:
          radio("Color:", pfUse, 1)
          if colorWell(pfColor, "pfcolor", dp(40)): pfUse = 1
          if toolButton("FG", "The foreground color"):
            pfColor = fg or 0xFF000000'u32
            pfUse = 1
      optSlider("Density:", pfDensity, 0, 100)
      checkbox("Preserve Luminosity", pfLum)
    discard adjButtons()

proc blackWhiteBody() =
  row([-1, 92]):
    col:
      for k, n in ["Reds:", "Yellows:", "Greens:", "Cyans:", "Blues:", "Magentas:"]:
        pushId("bw" & $k)
        optSlider(n, bwW[k], -200, 300)
        popId()
      checkbox("Tint", bwTint)
      if bwTint:
        optSlider("Hue:", bwHue, 0, 360, "°")
        optSlider("Saturation:", bwSat, 0, 100)
    col:
      discard adjButtons()
      space(dp(6))
      if button("Default", w = dp(86)): bwW = defaultBlackAndWhite()

proc mixerBody() =
  row([-1, 92]):
    col:
      row:
        label "Output Channel:"
        if cmMono:
          label "Gray"
        else:
          combo(["Red", "Green", "Blue"], cmOut, w = dp(100))
      let o = if cmMono: 0 else: cmOut
      group("Source Channels"):
        for k, n in ["Red:", "Green:", "Blue:"]:
          pushId("cm" & $k)
          optSlider(n, cm[o][k], -200, 200)
          popId()
      optSlider("Constant:", cm[o][3], -200, 200)
      if checkbox("Monochrome", cmMono):
        if cmMono:
          cm[0] = [40, 40, 20, 0]
          cmOut = 0
        else:
          cm = [[100, 0, 0, 0], [0, 100, 0, 0], [0, 0, 100, 0]]
    discard adjButtons()

proc gradMapBody() =
  row([-1, 92]):
    col:
      label "Gradient Used for Grayscale Mapping:"
      if gradientSwatch("gradmap", gmStops, dp(250), dp(28), false, gmReverse).clicked:
        startGradientEditor(1, gmStops)
      paragraph("Click the gradient to change it: the darks become its left color, the lights its right.",
                color = ui.theme.gray)
      checkbox("Reverse", gmReverse)
      checkbox("Dither", gmDither)
    if adjButtons(): return

proc lookupBody() =
  row([-1, 92]):
    col:
      var names = @LookNames
      var k = if luData.startsWith("look:"): max(0, names.find(luData[5 .. ^1])) else: -1
      label("Look:")
      var kk = max(0, k)
      if combo(names, kk, w = dp(220)) or (k < 0 and false):
        luData = "look:" & names[kk]
      row:
        if button("Load 3D LUT...", w = dp(130)):
          startOpenLut()
        label(if luData.startsWith("cube:"): luName else: "", color = ui.theme.gray)
      paragraph("A color look over the whole image: one of these, or a .cube table (a film emulation, " &
                "a grade from a video program).", color = ui.theme.gray)
    if adjButtons(): return

proc adjustDialog() =
  if not adjOpen: return
  var stillOpen = adjOpen
  dialog(stillOpen, adjNames[adjKind], (case adjKind
                                         of akLevels, akCurves: 420
                                         of akThreshold: 400
                                         of akPosterize: 340
                                         of akHS: 560
                                         of akSelective, akShadows, akVibrance: 400
                                         of akExposure, akBlackWhite, akMixer: 430
                                         of akPhotoFilter: 470
                                         else: 470)):
    case adjKind
    of akLevels: levelsBody()
    of akCurves: curvesBody()
    of akBC: bcBody()
    of akBalance: balanceBody()
    of akHS, akReplace: hsBody()
    of akThreshold: thresholdBody()
    of akPosterize: posterizeBody()
    of akSelective: selectiveBody()
    of akShadows: shadowsBody()
    of akVibrance: vibranceBody()
    of akExposure: exposureBody()
    of akPhotoFilter: photoFilterBody()
    of akBlackWhite: blackWhiteBody()
    of akMixer: mixerBody()
    of akGradMap: gradMapBody()
    of akLookup: lookupBody()
  if not stillOpen and adjOpen:
    endAdjust(false)          # (Esc, the close box)
  if adjOpen:
    let sig = adjSignature() & $adjPreview
    let d = adjDoc
    let size = if adjOnLayer != nil: d.w * d.h else: adjSrc.px.len
    let slow = size > 4_000_000 or (adjKind == akShadows and size > 1_500_000)
    # (a big photo while a slider moves: only the view's pixels are
    # adjusted -- live -- the whole image when it is let go; a change that
    # looks at its neighbours, or a mask of colors, the old way)
    let canLive = slow and adjPreview and adjKind notin {akShadows, akReplace} and
                  (adjOnLayer != nil or (adjLayer.px.len == d.w * d.h and adjLayer in d.layers))
    if ui.mouseDown and canLive:
      if sig != adjSig:
        if adjOnLayer != nil:
          d.setAdjustment(adjOnLayer, Adjustment(kind: adjNames[adjKind], args: adjArgs(), data: adjData()))
          adjOnLayer.visible = true
          if d.live.len == 0: d.setLive(@[LivePart(kind: lkMap)])   # (drawn from the layers)
          else: d.liveChanged()
        else:
          if adjShown.endsWith("true"): adjWrite(false)    # (the layer as it was, under the live change)
          let fn = adjFn()
          let L = adjLayer
          d.setLive(@[LivePart(layer: L, kind: lkMap, keepAlpha: L.background or L.lockAlpha,
                               map: proc (px: var seq[uint32]; w, h: int) =
                                 let o = fn(Img(w: w, h: h, px: px), rect(0, 0, w, h))
                                 if o.px.len == px.len: px = o.px)])
        adjSig = sig
    elif d.live.len > 0 and not ui.mouseDown:
      # (let go: the whole image)
      d.endLive()
      adjWrite(adjPreview)
      adjSig = sig
      adjAt = ui.now
    elif sig != adjSig and (not ui.mouseDown or (not slow and ui.now - adjAt > 60)):
      adjWrite(adjPreview)
      adjSig = sig
      adjAt = ui.now
    elif sig != adjSig: wakeIn(70)

# ---- filters: previewed in their box ------------------------------------------------------------------

type
  FParam = object
    label, unit: string
    lo, hi, val: float
    dec: int
    choices: seq[string]
  FSpec = object
    name: string
    params: seq[FParam]
    margin: proc (v: seq[float]): int
    make: proc (v: seq[float]): FilterFn

proc num(label: string; lo, hi, val: float; unit = ""; dec = 0): FParam =
  FParam(label: label, lo: lo, hi: hi, val: val, unit: unit, dec: dec)

proc pick(label: string; choices: openArray[string]; val = 0): FParam =
  FParam(label: label, choices: @choices, val: val.float, hi: (choices.len - 1).float)

proc noMargin(v: seq[float]): int = 0

var
  filters: Table[string, FSpec]
  fOpen = false
  fSpec: FSpec
  fVals: seq[float]
  fPreview: Bitmap
  fPreviewKey = ""
  fCenter: (int, int)
  fZoom = 1                    ## the preview's zoom (2: 2:1, -2: 1:2)
  fDragFrom: (int, int, int, int)
  fCanvas = true               ## Preview: the filter seen on the image itself, as it is set
  fCanvasOn: tuple[doc: Doc; key: string]   ## (the step holding what the image shows: open)
  lastFilter: tuple[set: bool; name: string; vals: seq[float]]

proc defFilter(name: string; params: seq[FParam]; make: proc (v: seq[float]): FilterFn;
               margin: proc (v: seq[float]): int = noMargin) =
  filters[name] = FSpec(name: name, params: params, make: make, margin: margin)

const
  galleryArtistic = ["Colored Pencil", "Cutout", "Dry Brush", "Film Grain", "Paint Daubs", "Plastic Wrap",
                     "Poster Edges", "Sponge", "Watercolor"]
  galleryBrush = ["Accented Edges", "Angled Strokes", "Crosshatch", "Ink Outlines", "Spatter", "Sumi-e"]
  gallerySketch = ["Bas Relief", "Charcoal", "Chrome", "Graphic Pen", "Halftone Pattern", "Photocopy",
                   "Reticulation", "Stamp", "Torn Edges"]
  galleryTexture = ["Craquelure", "Grain", "Mosaic Tiles", "Patchwork", "Stained Glass", "Texturizer"]

proc initGallery() =
  ## The Filter Gallery's filters and the others of photoartistic.
  template m(n: int): proc (v: seq[float]): int = (proc (v: seq[float]): int = n)
  defFilter("Colored Pencil", @[num("Pencil Width:", 1, 24, 4), num("Stroke Pressure:", 0, 15, 8),
                                num("Paper Brightness:", 0, 50, 25)],
            proc (v: seq[float]): FilterFn = coloredPencil(int(v[0]), int(v[1]), int(v[2]), bg), m(40))
  defFilter("Cutout", @[num("Number of Levels:", 2, 8, 4), num("Edge Simplicity:", 0, 10, 4),
                        num("Edge Fidelity:", 1, 3, 2)],
            proc (v: seq[float]): FilterFn = cutout(int(v[0]), int(v[1]), int(v[2])), m(30))
  defFilter("Dry Brush", @[num("Brush Size:", 0, 10, 2), num("Brush Detail:", 0, 10, 8), num("Texture:", 1, 3, 1)],
            proc (v: seq[float]): FilterFn = dryBrush(int(v[0]), int(v[1]), int(v[2])), m(14))
  defFilter("Film Grain", @[num("Grain:", 0, 20, 4), num("Highlight Area:", 0, 20, 0), num("Intensity:", 0, 10, 10)],
            proc (v: seq[float]): FilterFn = filmGrain(int(v[0]), int(v[1]), int(v[2])))
  defFilter("Paint Daubs", @[num("Brush Size:", 1, 50, 8), num("Sharpness:", 0, 40, 7)],
            proc (v: seq[float]): FilterFn = paintDaubs(int(v[0]), int(v[1])),
            proc (v: seq[float]): int = int(v[0]) + 6)
  defFilter("Plastic Wrap", @[num("Highlight Strength:", 0, 20, 15), num("Detail:", 1, 15, 9),
                              num("Smoothness:", 1, 15, 7)],
            proc (v: seq[float]): FilterFn = plasticWrap(int(v[0]), int(v[1]), int(v[2])), m(30))
  defFilter("Poster Edges", @[num("Edge Thickness:", 0, 10, 2), num("Edge Intensity:", 0, 10, 1),
                              num("Posterization:", 0, 6, 2)],
            proc (v: seq[float]): FilterFn = posterEdges(int(v[0]), int(v[1]), int(v[2])), m(12))
  defFilter("Sponge", @[num("Brush Size:", 0, 10, 2), num("Definition:", 0, 25, 12), num("Smoothness:", 1, 15, 5)],
            proc (v: seq[float]): FilterFn = sponge(int(v[0]), int(v[1]), int(v[2])), m(14))
  defFilter("Watercolor", @[num("Brush Detail:", 1, 14, 9), num("Shadow Intensity:", 0, 10, 1),
                            num("Texture:", 1, 3, 1)],
            proc (v: seq[float]): FilterFn = watercolor(int(v[0]), int(v[1]), int(v[2])), m(24))
  defFilter("Accented Edges", @[num("Edge Width:", 1, 14, 2), num("Edge Brightness:", 0, 50, 38),
                                num("Smoothness:", 1, 15, 5)],
            proc (v: seq[float]): FilterFn = accentedEdges(int(v[0]), int(v[1]), int(v[2])), m(14))
  defFilter("Angled Strokes", @[num("Direction Balance:", 0, 100, 50), num("Stroke Length:", 3, 50, 15),
                                num("Sharpness:", 0, 10, 3)],
            proc (v: seq[float]): FilterFn = angledStrokes(int(v[0]), int(v[1]), int(v[2])),
            proc (v: seq[float]): int = int(v[1]) + 2)
  defFilter("Crosshatch", @[num("Stroke Length:", 3, 50, 9), num("Sharpness:", 0, 20, 6), num("Strength:", 1, 3, 1)],
            proc (v: seq[float]): FilterFn = crosshatch(int(v[0]), int(v[1]), int(v[2])),
            proc (v: seq[float]): int = int(v[0]) + 2)
  defFilter("Ink Outlines", @[num("Stroke Length:", 1, 50, 4), num("Dark Intensity:", 0, 50, 20),
                              num("Light Intensity:", 0, 50, 10)],
            proc (v: seq[float]): FilterFn = inkOutlines(int(v[0]), int(v[1]), int(v[2])),
            proc (v: seq[float]): int = int(v[0]) + 2)
  defFilter("Spatter", @[num("Spray Radius:", 0, 25, 10), num("Smoothness:", 1, 15, 5)],
            proc (v: seq[float]): FilterFn = spatter(int(v[0]), int(v[1])),
            proc (v: seq[float]): int = int(v[0]) + 1)
  defFilter("Sumi-e", @[num("Stroke Width:", 3, 15, 10), num("Stroke Pressure:", 0, 15, 2), num("Contrast:", 0, 40, 16)],
            proc (v: seq[float]): FilterFn = sumiE(int(v[0]), int(v[1]), int(v[2])), m(16))
  defFilter("Bas Relief", @[num("Detail:", 1, 15, 13), num("Smoothness:", 1, 15, 3),
                            pick("Light:", ["Bottom", "Bottom Left", "Left", "Top Left", "Top", "Top Right",
                                            "Right", "Bottom Right"], 3)],
            proc (v: seq[float]): FilterFn =
              basRelief(int(v[0]), int(v[1]), [270.0, 225, 180, 135, 90, 45, 0, 315][int(v[2])], fg, bg), m(16))
  defFilter("Charcoal", @[num("Charcoal Thickness:", 1, 7, 1), num("Detail:", 0, 5, 5), num("Light/Dark Balance:", 0, 100, 50)],
            proc (v: seq[float]): FilterFn = charcoal(int(v[0]), int(v[1]), int(v[2]), fg, bg), m(16))
  defFilter("Chrome", @[num("Detail:", 0, 10, 4), num("Smoothness:", 0, 10, 7)],
            proc (v: seq[float]): FilterFn = chrome(int(v[0]), int(v[1])), m(20))
  defFilter("Graphic Pen", @[num("Stroke Length:", 1, 15, 15), num("Light/Dark Balance:", 0, 100, 50),
                             pick("Stroke Direction:", ["Right Diagonal", "Left Diagonal", "Horizontal", "Vertical"])],
            proc (v: seq[float]): FilterFn = graphicPen(int(v[0]), int(v[1]), int(v[2]), fg, bg))
  defFilter("Halftone Pattern", @[num("Size:", 1, 12, 1), num("Contrast:", 0, 50, 5),
                                  pick("Pattern Type:", ["Dot", "Circle", "Line"])],
            proc (v: seq[float]): FilterFn = halftonePattern(int(v[0]), int(v[1]), int(v[2]), fg, bg))
  defFilter("Photocopy", @[num("Detail:", 1, 24, 7), num("Darkness:", 1, 50, 8)],
            proc (v: seq[float]): FilterFn = photocopy(int(v[0]), int(v[1]), fg, bg), m(40))
  defFilter("Reticulation", @[num("Density:", 0, 50, 12), num("Foreground Level:", 0, 50, 40),
                              num("Background Level:", 0, 50, 5)],
            proc (v: seq[float]): FilterFn = reticulation(int(v[0]), int(v[1]), int(v[2]), fg, bg))
  defFilter("Stamp", @[num("Light/Dark Balance:", 0, 50, 25), num("Smoothness:", 1, 50, 5)],
            proc (v: seq[float]): FilterFn = stamp(int(v[0]), int(v[1]), fg, bg), m(24))
  defFilter("Torn Edges", @[num("Image Balance:", 0, 50, 25), num("Smoothness:", 1, 15, 11), num("Contrast:", 1, 25, 17)],
            proc (v: seq[float]): FilterFn = tornEdges(int(v[0]), int(v[1]), int(v[2]), fg, bg), m(8))
  defFilter("Craquelure", @[num("Crack Spacing:", 2, 100, 15), num("Crack Depth:", 0, 10, 6),
                            num("Crack Brightness:", 0, 10, 9)],
            proc (v: seq[float]): FilterFn = craquelure(int(v[0]), int(v[1]), int(v[2])))
  defFilter("Grain", @[num("Intensity:", 0, 100, 40), num("Contrast:", 0, 100, 50),
                       pick("Grain Type:", ["Regular", "Soft", "Sprinkles", "Clumped", "Contrasty", "Enlarged",
                                            "Stippled", "Horizontal", "Vertical", "Speckle"])],
            proc (v: seq[float]): FilterFn = grainTexture(int(v[0]), int(v[1]), GrainKind(int(v[2]))))
  defFilter("Mosaic Tiles", @[num("Tile Size:", 2, 100, 12), num("Grout Width:", 1, 15, 3), num("Lighten Grout:", 0, 10, 9)],
            proc (v: seq[float]): FilterFn = mosaicTiles(int(v[0]), int(v[1]), int(v[2])))
  defFilter("Patchwork", @[num("Square Size:", 0, 10, 4), num("Relief:", 0, 25, 8)],
            proc (v: seq[float]): FilterFn = patchwork(int(v[0]), int(v[1])))
  defFilter("Stained Glass", @[num("Cell Size:", 2, 50, 10), num("Border Thickness:", 1, 20, 4),
                               num("Light Intensity:", 0, 10, 3)],
            proc (v: seq[float]): FilterFn = stainedGlass(int(v[0]), int(v[1]), int(v[2]), fg))
  defFilter("Texturizer", @[pick("Texture:", ["Canvas", "Brick", "Burlap", "Sandstone"]),
                            num("Scaling:", 50, 200, 100, "%"), num("Relief:", 0, 50, 4),
                            pick("Light:", ["Bottom", "Bottom Left", "Left", "Top Left", "Top", "Top Right",
                                            "Right", "Bottom Right"], 3)],
            proc (v: seq[float]): FilterFn =
              texturizer(TextureKind(int(v[0])), int(v[1]), int(v[2]), [270.0, 225, 180, 135, 90, 45, 0, 315][int(v[3])]),
            m(4))
  defFilter("Oil Paint", @[num("Stylization:", 0.1, 10, 4, "", 1), num("Cleanliness:", 0, 10, 6, "", 1),
                           num("Scale:", 0.1, 10, 5, "", 1), num("Bristle Detail:", 0, 10, 3, "", 1),
                           num("Angle:", -180, 180, 135, "°"), num("Shine:", 0, 10, 3, "", 1)],
            proc (v: seq[float]): FilterFn = oilPaint(v[0], v[1], v[2], v[3], v[4], v[5]),
            proc (v: seq[float]): int = int(v[0] + v[1]) + 8)
  defFilter("Fibers", @[num("Variance:", 1, 64, 16), num("Strength:", 1, 64, 4)],
            proc (v: seq[float]): FilterFn = fibers(int(v[0]), int(v[1]), fg, bg, int(epochTime()) mod 9973))
  defFilter("Lighting Effects", @[pick("Light:", ["Spot", "Point", "Infinite"]), num("Across:", 0, 100, 50, "%"),
                                  num("Down:", 0, 100, 40, "%"), num("Intensity:", -100, 100, 35),
                                  num("Ambience:", -100, 100, 8), num("Angle:", -180, 180, 135, "°"),
                                  num("Texture Height:", 0, 100, 0)],
            proc (v: seq[float]): FilterFn =
              lightingEffects(LightKind(int(v[0])), v[1] / 100, v[2] / 100, int(v[3]), int(v[4]), v[5], int(v[6])),
            m(4))
  defFilter("Displace", @[num("Horizontal Scale:", -999, 999, 10, "%"), num("Vertical Scale:", -999, 999, 10, "%"),
                          pick("Undefined Areas:", ["Repeat Edge Pixels", "Wrap Around"])],
            proc (v: seq[float]): FilterFn = displace(int(v[0]), int(v[1]), wrap = v[2] > 0.5))
  defFilter("Smart Sharpen", @[num("Amount:", 1, 500, 150, "%"), num("Radius:", 0.1, 64, 1.0, "pixels", 1),
                               num("Reduce Noise:", 0, 100, 10, "%")],
            proc (v: seq[float]): FilterFn = smartSharpen(int(v[0]), v[1], int(v[2])),
            proc (v: seq[float]): int = int(v[1] * 3) + 4)

proc initFilters() =
  initGallery()
  defFilter("Blur", @[], proc (v: seq[float]): FilterFn = blur(), proc (v: seq[float]): int = 4)
  defFilter("Blur More", @[], proc (v: seq[float]): FilterFn = blurMore(), proc (v: seq[float]): int = 8)
  defFilter("Gaussian Blur", @[num("Radius:", 0.1, 250, 1.0, "pixels", 1)],
            proc (v: seq[float]): FilterFn = gaussianBlur(v[0]),
            proc (v: seq[float]): int = int(v[0] * 2) + 4)
  defFilter("Motion Blur", @[num("Angle:", -90, 90, 0, "°"), num("Distance:", 1, 999, 10, "pixels")],
            proc (v: seq[float]): FilterFn = motionBlur(v[0], int(v[1])),
            proc (v: seq[float]): int = int(v[1]) + 2)
  defFilter("Radial Blur", @[num("Amount:", 1, 100, 10), pick("Blur Method:", ["Spin", "Zoom"])],
            proc (v: seq[float]): FilterFn = radialBlur(int(v[0]), v[1] > 0.5))
  defFilter("Pinch", @[num("Amount:", -100, 100, 50, "%")],
            proc (v: seq[float]): FilterFn = pinch(int(v[0])))
  defFilter("Polar Coordinates", @[pick("", ["Rectangular to Polar", "Polar to Rectangular"])],
            proc (v: seq[float]): FilterFn = polarCoordinates(v[0] < 0.5))
  defFilter("Ripple", @[num("Amount:", -999, 999, 100), pick("Size:", ["Small", "Medium", "Large"], 1)],
            proc (v: seq[float]): FilterFn = ripple(int(v[0]), int(v[1])), proc (v: seq[float]): int = 30)
  defFilter("Spherize", @[num("Amount:", -100, 100, 100, "%"),
                          pick("Mode:", ["Normal", "Horizontal only", "Vertical only"])],
            proc (v: seq[float]): FilterFn = spherize(int(v[0]), int(v[1])))
  defFilter("Twirl", @[num("Angle:", -999, 999, 50, "°")], proc (v: seq[float]): FilterFn = twirl(v[0]))
  defFilter("Wave", @[num("Wavelength:", 2, 400, 60, "pixels"), num("Amplitude:", 1, 200, 8, "pixels"),
                      pick("Type:", ["Sine", "Square"])],
            proc (v: seq[float]): FilterFn = wave(int(v[0]), int(v[1]), v[2] > 0.5),
            proc (v: seq[float]): int = int(v[1]) + 2)
  defFilter("ZigZag", @[num("Amount:", -100, 100, 10), num("Ridges:", 1, 20, 5)],
            proc (v: seq[float]): FilterFn = zigzag(int(v[0]), int(v[1])))
  defFilter("Add Noise", @[num("Amount:", 1, 999, 32), pick("Distribution:", ["Uniform", "Gaussian"]),
                           pick("", ["Color", "Monochromatic"])],
            proc (v: seq[float]): FilterFn = addNoise(int(v[0]), v[1] > 0.5, v[2] > 0.5))
  defFilter("Despeckle", @[], proc (v: seq[float]): FilterFn = despeckle(), proc (v: seq[float]): int = 2)
  defFilter("Dust & Scratches", @[num("Radius:", 1, 16, 1, "pixels"), num("Threshold:", 0, 255, 0, "levels")],
            proc (v: seq[float]): FilterFn = dustAndScratches(int(v[0]), int(v[1])),
            proc (v: seq[float]): int = int(v[0]) + 1)
  defFilter("Reduce Noise", @[num("Strength:", 0, 100, 50), num("Reduce Color Noise:", 0, 100, 45, "%"),
                              num("Sharpen Details:", 0, 100, 25, "%")],
            proc (v: seq[float]): FilterFn =
              let (a, b, c) = (int(v[0]), int(v[1]), int(v[2]))
              result = proc (src: Img; inner: Rect): Img = detailImg(src, a, b, c),
            proc (v: seq[float]): int = 12)
  defFilter("Median", @[num("Radius:", 1, 16, 1, "pixels")],
            proc (v: seq[float]): FilterFn = median(int(v[0])), proc (v: seq[float]): int = int(v[0]) + 1)
  defFilter("Color Halftone", @[num("Max. Radius:", 4, 127, 8, "pixels")],
            proc (v: seq[float]): FilterFn = colorHalftone(int(v[0])), proc (v: seq[float]): int = int(v[0]) * 2)
  defFilter("Crystallize", @[num("Cell Size:", 3, 300, 10)],
            proc (v: seq[float]): FilterFn = crystallize(int(v[0])))
  defFilter("Facet", @[], proc (v: seq[float]): FilterFn = facet(), proc (v: seq[float]): int = 4)
  defFilter("Fragment", @[], proc (v: seq[float]): FilterFn = fragment(), proc (v: seq[float]): int = 5)
  defFilter("Mezzotint", @[pick("Type:", ["Fine Dots", "Short Lines", "Long Strokes"])],
            proc (v: seq[float]): FilterFn = mezzotint(int(v[0])))
  defFilter("Mosaic", @[num("Cell Size:", 2, 64, 8, "pixels")],
            proc (v: seq[float]): FilterFn = mosaic(int(v[0])))
  defFilter("Pointillize", @[num("Cell Size:", 3, 300, 5)],
            proc (v: seq[float]): FilterFn = pointillize(int(v[0]), bg))
  defFilter("Clouds", @[], proc (v: seq[float]): FilterFn = clouds(fg, bg, int(epochTime()) mod 9973))
  defFilter("Difference Clouds", @[],
            proc (v: seq[float]): FilterFn = clouds(fg, bg, int(epochTime()) mod 9973, difference = true))
  defFilter("Lens Flare", @[num("Brightness:", 10, 300, 100, "%"), num("Across:", 0, 100, 30, "%"),
                            num("Down:", 0, 100, 30, "%")],
            proc (v: seq[float]): FilterFn =
              let r = cur().workRect
              lensFlare(v[1] / 100 * r.w.float, v[2] / 100 * r.h.float, int(v[0])))
  defFilter("Sharpen", @[], proc (v: seq[float]): FilterFn = sharpen(), proc (v: seq[float]): int = 4)
  defFilter("Sharpen Edges", @[], proc (v: seq[float]): FilterFn = sharpenEdges(), proc (v: seq[float]): int = 4)
  defFilter("Sharpen More", @[], proc (v: seq[float]): FilterFn = sharpenMore(), proc (v: seq[float]): int = 4)
  defFilter("Unsharp Mask", @[num("Amount:", 1, 500, 50, "%"), num("Radius:", 0.1, 250, 1.0, "pixels", 1),
                              num("Threshold:", 0, 255, 0, "levels")],
            proc (v: seq[float]): FilterFn = unsharpMask(int(v[0]), v[1], int(v[2])),
            proc (v: seq[float]): int = int(v[1] * 2) + 4)
  defFilter("Diffuse", @[pick("Mode:", ["Normal", "Darken Only", "Lighten Only"])],
            proc (v: seq[float]): FilterFn = diffuse(int(v[0])), proc (v: seq[float]): int = 2)
  defFilter("Emboss", @[num("Angle:", -180, 180, 135, "°"), num("Height:", 1, 10, 3, "pixels"),
                        num("Amount:", 1, 500, 100, "%")],
            proc (v: seq[float]): FilterFn = emboss(v[0], int(v[1]), int(v[2])),
            proc (v: seq[float]): int = int(v[1]) + 2)
  defFilter("Extrude", @[pick("Type:", ["Blocks", "Pyramids"]), num("Size:", 2, 255, 30, "pixels"),
                         num("Depth:", 1, 255, 30), pick("", ["Random", "Level-based"], 1),
                         pick("", ["Image Front Faces", "Solid Front Faces"])],
            proc (v: seq[float]): FilterFn =
              extrude(int(v[1]), int(v[2]), pyramids = v[0] > 0.5, randomDepth = v[3] < 0.5,
                      frontsSolid = v[4] > 0.5, levelBased = v[3] > 0.5))
  defFilter("Find Edges", @[], proc (v: seq[float]): FilterFn = findEdges(), proc (v: seq[float]): int = 2)
  defFilter("Solarize", @[], proc (v: seq[float]): FilterFn = solarize())
  defFilter("Tiles", @[num("Number of Tiles:", 1, 99, 10), num("Maximum Offset:", 1, 99, 10, "%")],
            proc (v: seq[float]): FilterFn = tiles(int(v[0]), int(v[1]), bg))
  defFilter("Trace Contour", @[num("Level:", 0, 255, 128), pick("Edge:", ["Lower", "Upper"])],
            proc (v: seq[float]): FilterFn = traceContour(int(v[0]), v[1] > 0.5), proc (v: seq[float]): int = 2)
  defFilter("Wind", @[pick("Method:", ["Wind", "Blast"]), pick("Direction:", ["From the Right", "From the Left"])],
            proc (v: seq[float]): FilterFn = wind(v[0] > 0.5, v[1] > 0.5))
  defFilter("De-Interlace", @[pick("Eliminate:", ["Odd Fields", "Even Fields"]),
                              pick("Create New Fields by:", ["Duplication", "Interpolation"], 1)],
            proc (v: seq[float]): FilterFn = deInterlace(v[0] < 0.5, v[1] > 0.5), proc (v: seq[float]): int = 2)
  defFilter("NTSC Colors", @[], proc (v: seq[float]): FilterFn = ntscColors())
  defFilter("Surface Blur", @[num("Radius:", 1, 100, 5, "pixels"), num("Threshold:", 2, 255, 15, "levels")],
            proc (v: seq[float]): FilterFn = surfaceBlur(int(v[0]), int(v[1])),
            proc (v: seq[float]): int = int(v[0]) * 2 + 2)
  defFilter("Skin Smoothing", @[num("Blur:", 1, 30, 8, "pixels"), num("Smoothness:", 0, 100, 60, "%")],
            proc (v: seq[float]): FilterFn = skinSmoothing(int(v[0]), int(v[1])),
            proc (v: seq[float]): int = int(v[0]) * 3 + 4)
  defFilter("High Pass", @[num("Radius:", 0.1, 250, 10, "pixels", 1)],
            proc (v: seq[float]): FilterFn = highPass(v[0]), proc (v: seq[float]): int = int(v[0] * 2) + 4)
  defFilter("Maximum", @[num("Radius:", 1, 10, 1, "pixels")],
            proc (v: seq[float]): FilterFn = maximum(int(v[0])), proc (v: seq[float]): int = int(v[0]) + 1)
  defFilter("Minimum", @[num("Radius:", 1, 10, 1, "pixels")],
            proc (v: seq[float]): FilterFn = minimum(int(v[0])), proc (v: seq[float]): int = int(v[0]) + 1)
  defFilter("Offset", @[num("Horizontal:", -30000, 30000, 0, "pixels right"),
                        num("Vertical:", -30000, 30000, 0, "pixels down"),
                        pick("Undefined Areas:", ["Set to Background", "Repeat Edge Pixels", "Wrap Around"], 2)],
            proc (v: seq[float]): FilterFn = offsetFilter(int(v[0]), int(v[1]), int(v[2]), bg))

# ---- plug-ins: Filter Factory filters --------------------------------------------------------------------

var
  plugins: seq[FactoryFilter]          ## the plug-in filters, as listed in Filter > Plug-ins
  ffOpen = false
  ffEdit: FactoryFilter
  ffCompiled: CompiledFilter
  ffError = ""
  ffSource = ""                        ## (what was compiled)
  ffPreview: Bitmap
  ffPreviewKey = ""
  ffLoadPick = false
  ffLoadPath = ""

proc pluginsDir(): string = dataDir(AppName) / "Plug-ins"

proc registerPlugin(f: FactoryFilter) =
  ## A Filter Factory filter in the Filter menu (its sliders as the filter's
  ## settings).
  let cf = try: compileFilter(f) except FactoryError: return
  var params: seq[FParam]
  var idx: seq[int]
  for i in 0 .. 7:
    if f.sliders[i].len > 0:
      params.add num(f.sliders[i] & ":", 0, 255, f.values[i].float)
      idx.add i
  let base = f.values
  defFilter(f.name, params, proc (v: seq[float]): FilterFn =
    var ctl = base
    for k, i in idx:
      if k < v.len: ctl[i] = int(v[k])
    cf.filterFn(ctl))
  for k in countdown(plugins.high, 0):
    if plugins[k].name == f.name: plugins.delete(k)
  plugins.add f

proc initPlugins() =
  for f in builtInPlugins(): registerPlugin(f)
  for f in loadPlugins(pluginsDir()): registerPlugin(f)

proc pluginCategories(): seq[string] =
  for f in plugins:
    if f.category notin result: result.add f.category

proc startFilterFactory(f = FactoryFilter()) =
  ffEdit = f
  if ffEdit.name.len == 0:
    ffEdit = FactoryFilter(name: "My Filter", category: "Filter Factory", r: "r", g: "g", b: "b", a: "a")
    ffEdit.sliders = ["Amount", "", "", "", "", "", "", ""]
    ffEdit.values[0] = 128
  ffSource = ""
  ffError = ""
  ffPreviewKey = ""
  let d = cur()
  if d != nil:
    let r = d.workRect
    fCenter = (r.x + r.w div 2, r.y + r.h div 2)
  ffOpen = true

proc ffCompile(): bool =
  ## The formulas compiled when they changed (the error shown).
  let src = ffEdit.r & "\0" & ffEdit.g & "\0" & ffEdit.b & "\0" & ffEdit.a
  if src != ffSource:
    ffSource = src
    try:
      ffCompiled = compileFilter(ffEdit)
      ffError = ""
    except FactoryError as e:
      ffError = e.msg
  ffError.len == 0

proc filterFactoryDialog() =
  if filePicker(ffLoadPick, ffLoadPath, fmOpen, ["*" & pluginExt], "Load Filter"):
    try:
      startFilterFactory(filterFrom(parseJson(readFile(ffLoadPath))))
    except CatchableError:
      status = "Could not read " & ffLoadPath.extractFilename & ": " & getCurrentExceptionMsg()
  if not ffOpen: return
  let d = cur()
  if d == nil:
    ffOpen = false
    return
  dialog(ffOpen, "Filter Factory", 660):
    let ok = ffCompile()
    row([156, -1]):
      col:
        let side = dp(150)
        let r = place(side + 2, side + 2)
        let n = max(1, side * pxScale)
        var ctl: array[8, int]
        for i in 0 .. 7: ctl[i] = ffEdit.values[i]
        let key = ffSource & $ctl & $d.ver & $fCenter
        if ok and key != ffPreviewKey and not (ui.mouseDown and ffPreview != nil and ui.now mod 3 != 0):
          ffPreview = d.previewFilter(0, ffCompiled.filterFn(ctl), fCenter[0], fCenter[1], n, n)
          ffPreview.changed()
          ffPreviewKey = key
        box(r, ui.theme.frame)
        if ffPreview != nil: drawBitmap(inset(r, 1), ffPreview)
        space(dp(4))
        label("Values: r g b a c i u v", color = ui.theme.gray)
        label("x y X Y d m M z ctl(n)", color = ui.theme.gray)
        label("src(x,y,z) rad(d,m,z)", color = ui.theme.gray)
        label("sin cos sqr mix scl rnd", color = ui.theme.gray)
        label("min max abs add sub dif", color = ui.theme.gray)
        label("c2d c2m cnv val ?: == <", color = ui.theme.gray)
      col:
        row:
          label "Name:"
          edit(ffEdit.name, w = dp(170))
          label "Category:"
          edit(ffEdit.category, w = dp(120))
        group("Sliders"):
          for i in 0 .. 7:
            if i > 0 and ffEdit.sliders[i].len == 0 and ffEdit.sliders[i - 1].len == 0: continue
            pushId("ffs" & $i)
            row([110, -1, 36]):
              edit(ffEdit.sliders[i], w = dp(106))
              slider(ffEdit.values[i], 0, 255, ticks = 0)
              label $ffEdit.values[i]
            popId()
        group("Formulas"):
          for (lab, k) in [("R:", 0), ("G:", 1), ("B:", 2), ("A:", 3)]:
            pushId("fff" & $k)
            row([20, -1]):
              label lab
              case k
              of 0: edit(ffEdit.r)
              of 1: edit(ffEdit.g)
              of 2: edit(ffEdit.b)
              else: edit(ffEdit.a)
            popId()
        if ffError.len > 0: label(ffError, color = color(170, 0, 0))
        else: label("The formulas are fine.", color = ui.theme.gray)
    row:
      if button("Load...", w = dp(80)):
        if ffLoadPath.len == 0: ffLoadPath = pluginsDir()
        ffLoadPick = true
      if button("Save Plug-in", w = dp(110), enabled = ok and ffEdit.name.strip.len > 0):
        try:
          let path = ffEdit.savePlugin(pluginsDir())
          registerPlugin(ffEdit)
          status = "Saved as a plug-in: Filter > Plug-ins > " & ffEdit.category & " > " & ffEdit.name &
                   " (" & path.extractFilename & ")"
        except CatchableError:
          status = "Could not save the plug-in: " & getCurrentExceptionMsg()
      spring()
      if button("Apply", isDefault = true, w = dp(80), enabled = ok):
        ffOpen = false
        var ctl: array[8, int]
        for i in 0 .. 7: ctl[i] = ffEdit.values[i]
        d.beginStep(if ffEdit.name.len > 0: ffEdit.name else: "Filter Factory")
        d.applyFilter(0, ffCompiled.filterFn(ctl))
        d.endStep()
      if button("Cancel", w = dp(80)): ffOpen = false

proc runFilter(name: string; vals: seq[float]) =
  let d = cur()
  if d == nil or not filters.hasKey(name): return
  if d.current.isSmart and d.addSmartFilter(name, vals):
    lastFilter = (true, name, vals)
    if recording: record(ActStep(kind: acFilter, name: name, vals: vals))
    return
  let s = filters[name]
  d.beginStep(name)
  d.applyFilter(s.margin(vals), s.make(vals))
  d.endStep()
  lastFilter = (true, name, vals)
  if recording: record(ActStep(kind: acFilter, name: name, vals: vals))

proc startFilter(name: string) =
  if not filters.hasKey(name) or cur() == nil: return
  let s = filters[name]
  if s.params.len == 0:
    runFilter(name, @[])
    return
  fSpec = s
  fVals.setLen(0)
  # the values used last time with this filter
  if lastFilter.set and lastFilter.name == name: fVals = lastFilter.vals
  else:
    for p in s.params: fVals.add p.val
  let r = cur().workRect
  fCenter = (r.x + r.w div 2, r.y + r.h div 2)
  fPreviewKey = ""
  fOpen = true
  for p in s.params:
    if p.choices.len == 0:
      typeFirst()    # (the first number, ready to type over)
      break

proc dropCanvasPreview() =
  ## (the filter seen on the image taken back)
  let pd = fCanvasOn.doc
  if pd != nil and pd.stepOpen: pd.cancelStep()
  fCanvasOn = (nil, "")

proc filterDialog() =
  if not fOpen:
    if fCanvasOn.doc != nil: dropCanvasPreview()
    return
  let d = cur()
  if d == nil:
    fOpen = false
    dropCanvasPreview()
    return
  # Preview: the image shows the filter -- done for real in an open step,
  # taken back when a setting changes (once the slider is let go), kept by
  # OK, taken back by Cancel. (Not on a Smart Object: its filters show anyway.)
  let ck = $fVals & fSpec.name
  let canvasOk = fCanvas and not d.current.isSmart
  if canvasOk and (fCanvasOn.doc != d or fCanvasOn.key != ck) and not ui.mouseDown:
    dropCanvasPreview()
    d.beginStep(fSpec.name)
    try:
      beginBusy(fSpec.name, cancel = true)
      try: d.applyFilter(fSpec.margin(fVals), fSpec.make(fVals))
      finally: endBusy(cancel = true)
      fCanvasOn = (d, ck)
    except BusyCancelled:
      d.cancelStep()
      fCanvas = false
  elif not canvasOk and fCanvasOn.doc != nil:
    dropCanvasPreview()
  dialog(fOpen, fSpec.name, 470):
    row([156, -1, 86]):
      col:
        # the preview: a part of the image, filtered; drag it to see another part
        let side = dp(150)
        let r = place(side + 2, side + 2)
        let id = idOf("filterpreview")
        let hit = interact(id, r, focusable = false)
        if hit.down or ui.active == id: ui.dragsActive = true
        if hit.down and ui.pressed: fDragFrom = (ui.mx, ui.my, fCenter[0], fCenter[1])
        # (image pixels per screen pixel: 2:1 shows half as much, bigger)
        let k = if fZoom >= 1: 1 / fZoom.float else: (-fZoom).float
        if ui.active == id and ui.mouseDown:
          fCenter = (fDragFrom[2] - int(float((ui.mx - fDragFrom[0]) * pxScale) * k),
                     fDragFrom[3] - int(float((ui.my - fDragFrom[1]) * pxScale) * k))
        let n = max(1, int(float(side * pxScale) * k))
        let key = $fVals & $fCenter & $d.ver & $fZoom
        if key != fPreviewKey and (not ui.mouseDown or fPreview == nil or ui.active == id):
          fPreview = d.previewFilter(fSpec.margin(fVals), fSpec.make(fVals), fCenter[0], fCenter[1], n, n)
          fPreview.changed()
          fPreviewKey = key
        box(r, ui.theme.frame)
        if fPreview != nil: drawBitmap(inset(r, 1), fPreview)
        if hit.hover: ui.cursor = curHand
        # the zoom of the preview, as in 1994: minus, the ratio, plus
        row([28, -1, 28]):
          if button("-", w = dp(28), enabled = fZoom > -8):
            fZoom = case fZoom
                    of 1: -2
                    of 2: 1
                    else: (if fZoom > 1: fZoom - 1 else: fZoom * 2)
          label(zoomPercent(fZoom))
          if button("+", w = dp(28), enabled = fZoom < 8):
            fZoom = case fZoom
                    of -2: 1
                    else: (if fZoom >= 1: fZoom + 1 else: fZoom div 2)
      col:
        for i, p in fSpec.params:
          if p.choices.len > 0:
            if p.label.len > 0: label(p.label, bold = true)
            var k = int(fVals[i])
            pushId("choice" & $i)
            for j, c in p.choices:
              if radio(c, k, j): fVals[i] = j.float
            popId()
          else:
            row:
              label p.label
              if p.dec > 0:
                var v = fVals[i]
                if numberEdit(v, decimals = p.dec, w = dp(70), lo = p.lo, hi = p.hi): fVals[i] = v
              else:
                var v = int(fVals[i])
                if intEdit(v, w = dp(70), lo = int(p.lo), hi = int(p.hi)): fVals[i] = v.float
              label p.unit
            var sv = int(round((fVals[i] - p.lo) / (p.hi - p.lo) * 1000))
            pushId("fslider" & $i)
            if slider(sv, 0, 1000, ticks = 0):
              var v = p.lo + sv.float / 1000 * (p.hi - p.lo)
              if p.dec == 0: v = round(v)
              else: v = round(v * 10) / 10
              fVals[i] = v
            popId()
      col:
        if button("OK", isDefault = true, w = dp(80)):
          fOpen = false
          if fCanvasOn.doc == d and fCanvasOn.key == ck and d.stepOpen:
            # (what the image shows already: kept)
            d.endStep()
            fCanvasOn = (nil, "")
            lastFilter = (true, fSpec.name, fVals)
            if recording: record(ActStep(kind: acFilter, name: fSpec.name, vals: fVals))
          else:
            dropCanvasPreview()
            runFilter(fSpec.name, fVals)
        if button("Cancel", w = dp(80)):
          fOpen = false
          dropCanvasPreview()
        checkbox("Preview", fCanvas)

# ---- Develop: a photo's everyday corrections in one go, previewed in its box ------------------------------

var
  dvOpen = false
  dvS: Develop                ## the settings
  dvTab = 0
  dvRect: Rect                ## the part developed (the selection's rectangle)
  dvLayer: Layer
  dvSmall: Img                ## the part fitted to the box
  dvSmallFor = (0, 0)
  dvBaseImg: Img              ## ... smaller: the light around each pixel is worked out from it
  dvBase: DevelopBase
  dvBaseKey = ""
  dvBmp: Bitmap
  dvKey = ""
  dvAt = 0
  dvOneToOne = false          ## the box shows the pixels 1:1 (the detail)
  dvCenter = (0, 0)           ## ... around this point of the part
  dvDrag = (0, 0, 0, 0)
  dvMoved = false
  dvAfter = true              ## the box shows the result (or the photo as it was)
  dvPreset = 0
  dvPresetName = ""
  dvSaveOpen = false
  dvUser: seq[(string, Develop)]
  dvLoaded = false
  dvHist: array[256, int]     ## of what the box shows
  dvRawOn = false             ## Camera Raw: the settings start from a raw photo's light
  dvRaw: RawImage             ## ... all of it
  dvRawSmall: RawImage        ## ... smaller, for the box
  dvRawShown: Img             ## ... developed as the white balance and exposure say
  dvFloatKey = ""

proc effS(): Develop =
  ## What is done to pixels (with a raw photo: what is not done to its light).
  if dvRawOn: dvS.pixelPart else: dvS

proc dvRefreshFloat() =
  ## Camera Raw: the light developed again when its settings change.
  if not dvRawOn: return
  let k = $dvS.floatPart
  if k == dvFloatKey: return
  dvFloatKey = k
  dvRawShown = developRaw(dvRawSmall, dvS.floatPart)
  dvBaseImg = smallCopy(dvRawShown, 400)
  dvSmall = Img()
  dvSmallFor = (0, 0)

const dvFirstPresets = ["Custom", "Default", "Auto"]

proc loadDevelopPresets() =
  dvLoaded = true
  dvUser.setLen(0)
  for k, v in loadSettings(AppName):
    if k.startsWith("develop.preset."): dvUser.add (k[15 .. ^1], parseDevelop(v))

proc saveDevelopPreset(name: string; s: Develop) =
  var st = loadSettings(AppName)
  st["develop.preset." & name] = $s
  if not saveSettings(AppName, st): status = "The preset could not be saved"
  loadDevelopPresets()

proc dvAuto(): Develop =
  ## Auto: the tone and color settings of `autoDevelop`, the rest kept.
  let a = if dvRawOn: autoDevelop(smallCopy(developRaw(dvRawSmall.smaller(400), Develop()), 400))
          else: autoDevelop(dvBaseImg)
  result = dvS
  result.temperature = a.temperature; result.tint = a.tint; result.exposure = a.exposure
  result.contrast = a.contrast; result.highlights = a.highlights; result.shadows = a.shadows
  result.whites = a.whites; result.blacks = a.blacks; result.vibrance = a.vibrance

proc dvPresetList(): seq[(string, Develop)] =
  result.add ("Custom", dvS)
  result.add ("Default", Develop())
  result.add ("Auto", dvAuto())
  for p in developPresets(): result.add p
  for p in dvUser: result.add p

proc startDevelop() =
  let d = cur()
  if d == nil: return
  dvRawOn = false
  let r = d.workRect
  if r.w <= 0 or r.h <= 0: return
  if not dvLoaded: loadDevelopPresets()
  dvRect = r
  dvLayer = d.layer
  dvBaseImg = smallCopy(d.layer.px, d.w, r, 400)
  dvSmall = Img()
  dvSmallFor = (0, 0)
  dvS = Develop()
  dvPreset = 1
  dvBaseKey = ""
  dvKey = ""
  dvOneToOne = false
  dvAfter = true
  dvCenter = (r.w div 2, r.h div 2)
  dvOpen = true

proc startCameraRaw(raw: RawImage) =
  ## Camera Raw: the raw photo just opened (as shot) developed from its
  ## light, previewed; OK makes the image of it.
  startDevelop()
  if not dvOpen: return
  dvRawOn = true
  dvRaw = raw
  dvRawSmall = raw.smaller(1600)
  dvFloatKey = ""
  dvRefreshFloat()

proc dvSlider(lab: string; v: var int; lo, hi: int; shown = "") =
  row([84, -1, 44]):
    label lab
    slider(v, lo, hi, ticks = 0)
    label(if shown.len > 0: shown elif v > 0: "+" & $v else: $v)

proc dvPreview(d: Doc; pw, ph: int): Bitmap =
  ## The box's picture, `pw` x `ph` pixels at most.
  let r = dvRect
  let base = dvBase
  dvRefreshFloat()
  if not dvOneToOne:
    if dvSmallFor != (pw, ph) or dvSmall.w == 0:
      let f = max(1.0, max(r.w / pw, r.h / ph))
      dvSmall = if dvRawOn: smallCopy(dvRawShown, int(ceil(max(r.w, r.h).float / f)))
                else: smallCopy(d.layer.px, d.w, r, int(ceil(max(r.w, r.h).float / f)))
      dvSmallFor = (pw, ph)
    let im = if dvAfter: developImg(dvSmall, effS(), base, 0, 0, r.w / max(1, dvSmall.w))
             else: dvSmall
    result = newBitmap(im.w, im.h)
    for i in 0 ..< im.px.len: result.px[i] = blendPx(0xFFFFFFFF'u32, im.px[i], 255, bmNormal)
    for v in dvHist.mitems: v = 0
    for p in im.px: inc dvHist[lumaOf(p)]
  else:
    let cw = min(r.w, pw)
    let ch = min(r.h, ph)
    let x0 = clamp(dvCenter[0] - cw div 2, 0, r.w - cw)
    let y0 = clamp(dvCenter[1] - ch div 2, 0, r.h - ch)
    var crop = newImg(cw, ch)
    if dvRawOn:
      crop = developRaw(dvRaw.crop(x0, y0, cw, ch), dvS.floatPart)
    else:
      for y in 0 ..< ch:
        for x in 0 ..< cw: crop.px[y * cw + x] = d.layer.px[(r.y + y0 + y) * d.w + r.x + x0 + x]
    let im = if dvAfter: developImg(crop, effS(), base, x0.float, y0.float, 1.0) else: crop
    result = newBitmap(im.w, im.h)
    for i in 0 ..< im.px.len: result.px[i] = blendPx(0xFFFFFFFF'u32, im.px[i], 255, bmNormal)
  result.changed()

proc developDialog() =
  if not dvOpen: return
  let d = cur()
  if d == nil or d.layer != dvLayer or d.w * d.h != dvLayer.px.len:
    dvOpen = false
    return
  # the box as big as the screen allows
  let avail = int(ui.w.float / ui.k)
  let boxW = clamp(avail - 92 - 290 - 56, 200, 480)
  let boxH = boxW * 3 div 4
  let pw = max(16, dp(boxW) * pxScale)
  let ph = max(16, dp(boxH) * pxScale)
  dialog(dvOpen, if dvRawOn: "Camera Raw" else: "Develop", boxW + 92 + 290 + 44):
    row([boxW + 4, -1, 92]):
      col:
        let r = place(dp(boxW) + 2, dp(boxH) + 2)
        let id = idOf("devpreview")
        let hit = interact(id, r, focusable = false)
        if hit.down or ui.active == id: ui.dragsActive = true
        if hit.down and ui.pressed:
          dvDrag = (ui.mx, ui.my, dvCenter[0], dvCenter[1])
          dvMoved = false
        if dvOneToOne and ui.active == id and ui.mouseDown:
          let nx = dvDrag[2] - int(float(ui.mx - dvDrag[0]) * pxScale.float)
          let ny = dvDrag[3] - int(float(ui.my - dvDrag[1]) * pxScale.float)
          if abs(ui.mx - dvDrag[0]) + abs(ui.my - dvDrag[1]) > 3: dvMoved = true
          dvCenter = (clamp(nx, 0, dvRect.w), clamp(ny, 0, dvRect.h))
        if hit.clicked and not dvMoved:
          # a click: 1:1 there, or back to the whole
          if not dvOneToOne and dvBmp != nil:
            let k = min(float(r.w - 2) / (float(dvBmp.w) / pxScale.float), float(r.h - 2) / (float(dvBmp.h) / pxScale.float))
            let bw = float(dvBmp.w) / pxScale.float * k
            let bh = float(dvBmp.h) / pxScale.float * k
            let ix = (float(ui.mx - r.x - 1) - (float(r.w - 2) - bw) / 2) / bw
            let iy = (float(ui.my - r.y - 1) - (float(r.h - 2) - bh) / 2) / bh
            dvCenter = (clamp(int(ix * dvRect.w.float), 0, dvRect.w), clamp(int(iy * dvRect.h.float), 0, dvRect.h))
          dvOneToOne = not dvOneToOne
        fill(inset(r, 1), ui.theme.face)
        box(r, ui.theme.frame)
        # the settings worked out on the small copy, then the box's picture
        dvRefreshFloat()
        let bk = $dvS
        if bk != dvBaseKey:
          dvBase = developBase(dvBaseImg, effS(), dvRect.w, dvRect.h)
          dvBaseKey = bk
        let key = bk & $dvAfter & $dvOneToOne & $dvCenter & $pw & "x" & $ph
        if key != dvKey and (dvBmp == nil or not ui.mouseDown or ui.now - dvAt > 40):
          dvBmp = dvPreview(d, pw, ph)
          dvKey = key
          dvAt = ui.now
        elif key != dvKey: wakeIn(50)
        if dvBmp != nil:
          var bw = int(float(dvBmp.w) / pxScale.float)
          var bh = int(float(dvBmp.h) / pxScale.float)
          if not dvOneToOne:
            # (the whole picture as big as the box, a small one made bigger)
            let k = min((r.w - 2) / max(1, bw), (r.h - 2) / max(1, bh))
            bw = max(1, int(bw.float * k))
            bh = max(1, int(bh.float * k))
          drawBitmap(rect(r.x + 1 + (r.w - 2 - bw) div 2, r.y + 1 + (r.h - 2 - bh) div 2, bw, bh), dvBmp)
        if hit.hover: ui.cursor = (if dvOneToOne: curHand else: curCrosshair)
        row:
          if button("Fit", w = dp(56), enabled = dvOneToOne): dvOneToOne = false
          if button("1:1", w = dp(56), enabled = not dvOneToOne): dvOneToOne = true
          space(dp(8))
          checkbox("Preview", dvAfter)
        label(if dvOneToOne: "Drag to see another part; click for the whole picture"
              else: "Click the picture to see its pixels 1:1", color = ui.theme.gray)
        if not dvOneToOne:
          histogramView(dvHist, dp(boxW) + 2, dp(min(110, max(48, boxH div 4))))
      col:
        tabs(dvTab, ["Basic", "Detail", "Effects"], sameHeight = true):
          case dvTab
          of 0:
            label("White Balance", bold = true)
            dvSlider("Temperature:", dvS.temperature, -100, 100)
            dvSlider("Tint:", dvS.tint, -100, 100)
            label("Tone", bold = true)
            dvSlider("Exposure:", dvS.exposure, -500, 500,
                     (if dvS.exposure > 0: "+" else: "") & formatFloat(dvS.exposure / 100, ffDecimal, 2))
            dvSlider("Contrast:", dvS.contrast, -100, 100)
            dvSlider("Highlights:", dvS.highlights, -100, 100)
            dvSlider("Shadows:", dvS.shadows, -100, 100)
            dvSlider("Whites:", dvS.whites, -100, 100)
            dvSlider("Blacks:", dvS.blacks, -100, 100)
            label("Presence", bold = true)
            dvSlider("Clarity:", dvS.clarity, -100, 100)
            dvSlider("Dehaze:", dvS.dehaze, -100, 100)
            dvSlider("Vibrance:", dvS.vibrance, -100, 100)
            dvSlider("Saturation:", dvS.saturation, -100, 100)
          of 1:
            label("Sharpening", bold = true)
            dvSlider("Amount:", dvS.sharpen, 0, 150)
            var rad = if dvS.sharpenRadius == 0: 10 else: dvS.sharpenRadius
            dvSlider("Radius:", rad, 5, 30, formatFloat(rad / 10, ffDecimal, 1))
            dvS.sharpenRadius = if rad == 10: 0 else: rad
            label("Noise Reduction", bold = true)
            dvSlider("Luminance:", dvS.noise, 0, 100)
            dvSlider("Color:", dvS.colorNoise, 0, 100)
            space(dp(6))
            label(if dvOneToOne: "The box shows the pixels 1:1."
                  else: "See the detail 1:1: click the picture.", color = ui.theme.gray)
          else:
            label("Vignette", bold = true)
            dvSlider("Amount:", dvS.vignette, -100, 100)
            label("Grain", bold = true)
            dvSlider("Amount:", dvS.grain, 0, 100)
      col:
        if button("OK", isDefault = true, w = dp(86)):
          dvOpen = false
          if dvRawOn:
            # (the raw photo's light developed again, all of it, then the rest)
            beginBusy("Camera Raw")
            try:
              d.beginStep("Camera Raw")
              let L = d.layer
              d.touch(L, d.bounds)
              L.px = developRaw(dvRaw, dvS.floatPart).px
              inc L.ver
              d.markAll()
              let rest = dvS.pixelPart
              if not rest.isNeutral: d.applyFilter(developMargin(rest), develop(rest))
              d.endStep()
            finally: endBusy()
            dvRawOn = false
            dvRaw = RawImage()
            dvRawSmall = RawImage()
          else:
            let s2 = dvS
            if not s2.isNeutral:
              d.beginStep("Develop")
              d.applyFilter(developMargin(s2), develop(s2))
              d.endStep()
        if button("Cancel", w = dp(86)):
          dvOpen = false
          dvRawOn = false
        if button("Auto", w = dp(86)):
          dvS = dvAuto()
          dvPreset = 2
        if button("Default", w = dp(86)):
          dvS = Develop()
          dvPreset = 1
        space(dp(8))
        label "Preset:"
        let list = dvPresetList()
        var names: seq[string]
        for (n, p) in list: names.add n
        # (Custom when the settings are none of them)
        if dvPreset <= 0 or dvPreset >= list.len or list[dvPreset][1] != dvS: dvPreset = 0
        var k = dvPreset
        if combo(names, k, w = dp(86)) and k > 0:
          dvS = list[k][1]
          dvPreset = k
        if button("Save...", w = dp(86)):
          dvPresetName = ""
          dvSaveOpen = true
          typeFirst()
  if dvSaveOpen:
    case inputBox(dvSaveOpen, "Save Preset", "Name of the preset:", dvPresetName)
    of 1:
      let n = dvPresetName.strip
      if n.len > 0 and '=' notin n and '\n' notin n:
        saveDevelopPreset(n, dvS)
        status = "Preset \"" & n & "\" saved"
    else: discard

# ---- Liquify: push the picture around with a brush --------------------------------------------------------

var
  lqOpen = false
  lqMesh: LiquifyMesh
  lqSmall: Img                ## the layer fitted to the box
  lqSmallFor = (0, 0)
  lqScale = 1.0               ## image pixels per pixel of `lqSmall`
  lqLayer: Layer
  lqTool = 0
  lqSize = 100                ## the brush, in image pixels
  lqPressure = 50
  lqBmp: Bitmap
  lqDirty = true
  lqLast = (0.0, 0.0)
  lqHas = false
  lqShowMesh = false

const lqTools = ["Forward Warp", "Reconstruct", "Twirl Clockwise", "Twirl Counterclockwise", "Pucker", "Bloat",
                 "Smooth", "Push Left", "Freeze Mask", "Thaw Mask"]

proc startLiquify() =
  let d = cur()
  if d == nil: return
  lqLayer = d.layer
  lqMesh = newLiquifyMesh(d.w, d.h)
  lqSmall = Img()
  lqSmallFor = (0, 0)
  lqSize = clamp(min(d.w, d.h) div 8, 10, 600)
  lqHas = false
  lqDirty = true
  lqOpen = true

proc liquifyDialog() =
  if not lqOpen: return
  let d = cur()
  if d == nil or d.layer != lqLayer or d.w * d.h != lqLayer.px.len:
    lqOpen = false
    return
  let avail = int(ui.w.float / ui.k)
  let boxW = clamp(avail - 160 - 92 - 56, 200, 640)
  let boxH = boxW * 3 div 4
  let pw = max(16, dp(boxW) * pxScale)
  let ph = max(16, dp(boxH) * pxScale)
  if lqSmall.w == 0 or lqSmallFor != (pw, ph):
    let f = max(1.0, max(d.w / pw, d.h / ph))
    lqSmall = smallCopy(lqLayer.px, d.w, d.bounds, int(ceil(max(d.w, d.h).float / f)))
    lqSmallFor = (pw, ph)
    lqScale = d.w / max(1, lqSmall.w)
    lqDirty = true
  dialog(lqOpen, "Liquify", boxW + 160 + 92 + 40):
    row([160, boxW + 6, 92]):
      col:
        label("Tools", bold = true)
        pushId("lqtools")
        for k, n in lqTools: radio(n, lqTool, k)
        popId()
        space(dp(6))
        label("Brush Size:")
        row([-1, 40]):
          slider(lqSize, 5, max(20, max(d.w, d.h) div 2), ticks = 0)
          label $lqSize
        label("Brush Pressure:")
        row([-1, 40]):
          slider(lqPressure, 1, 100, ticks = 0)
          label $lqPressure
        space(dp(6))
        checkbox("Show Mesh", lqShowMesh)
        if button("Thaw All", w = dp(100)):
          lqMesh.frozen.setLen(0)
          lqDirty = true
      col:
        if lqDirty:
          let im = liquifyImg(lqSmall, lqMesh, 0, 0, lqScale)
          lqBmp = newBitmap(im.w, im.h)
          for i in 0 ..< im.px.len: lqBmp.px[i] = blendPx(0xFFFFFFFF'u32, im.px[i], 255, bmNormal)
          if lqMesh.frozen.len > 0:
            # (the frozen parts tinted red, as editors show its Freeze Mask)
            for y in 0 ..< im.h:
              for x in 0 ..< im.w:
                let f = lqMesh.frozenAt((x.float + 0.5) * lqScale, (y.float + 0.5) * lqScale)
                if f > 0.01:
                  lqBmp.px[y * im.w + x] = blendPx(lqBmp.px[y * im.w + x], 0xFFFF2020'u32, int(f * 110), bmNormal)
          lqBmp.changed()
          lqDirty = false
        let (box, pic, hit, dragging) = pictureBox("liquify", lqBmp, dp(boxW), dp(boxH))
        beginKeepSides(box)            # (the brush drawn over the picture as it is, right to left too)
        let k = pic.w.float / max(1, lqSmall.w).float / lqScale    # (screen pixels per image pixel)
        if lqShowMesh:
          # the mesh as it has moved
          pushClip(inset(box, 1))
          let st = max(1, lqMesh.w div 24)
          for gy in countup(0, lqMesh.h - 1, st):
            var prev = (-1, -1)
            for gx in 0 ..< lqMesh.w:
              let px = gx.float * lqMesh.step
              let py = gy.float * lqMesh.step
              let (mx, my) = lqMesh.at(px, py)
              let sx = pic.x + int((px - mx.float) * k)
              let sy = pic.y + int((py - my.float) * k)
              if prev[0] >= 0: line(prev[0], prev[1], sx, sy, color(0, 0, 160))
              prev = (sx, sy)
          for gx in countup(0, lqMesh.w - 1, st):
            var prev = (-1, -1)
            for gy in 0 ..< lqMesh.h:
              let px = gx.float * lqMesh.step
              let py = gy.float * lqMesh.step
              let (mx, my) = lqMesh.at(px, py)
              let sx = pic.x + int((px - mx.float) * k)
              let sy = pic.y + int((py - my.float) * k)
              if prev[0] >= 0: line(prev[0], prev[1], sx, sy, color(0, 0, 160))
              prev = (sx, sy)
          popClip()
        if mouseIn(box) and pic.w > 0:
          # the brush
          let rr = int(lqSize.float / 2 * k)
          pushClip(inset(box, 1))
          ellipseOnScreen(ui.mx - rr + 1, ui.my - rr + 1, ui.mx + rr + 1, ui.my + rr + 1, color(255, 255, 255))
          ellipseOnScreen(ui.mx - rr, ui.my - rr, ui.mx + rr, ui.my + rr, color(0, 0, 0))
          popClip()
          ui.cursor = curCrosshair
        if hit.down and ui.pressed: lqHas = false
        if dragging and pic.w > 0:
          let (sx, sy) = toPicture(pic, lqSmall.w, lqSmall.h, ui.mx, ui.my)
          let ix = sx * lqScale
          let iy = sy * lqScale
          let radius = lqSize.float / 2
          let pr = lqPressure / 100 * (if ui.pen: max(0.05, ui.pressure) else: 1.0)
          case lqTool
          of 0:
            if lqHas:
              let dx = ix - lqLast[0]
              let dy = iy - lqLast[1]
              let dist = hypot(dx, dy)
              if dist > 0.5:
                let n = max(1, int(ceil(dist / max(1.0, radius * 0.2))))
                for s2 in 0 ..< n:
                  lqMesh.push(lqLast[0] + dx * s2.float / n.float, lqLast[1] + dy * s2.float / n.float,
                              dx / n.float, dy / n.float, radius, pr)
                lqDirty = true
          of 1: lqMesh.reconstruct(ix, iy, radius, pr * 0.25)
          of 2, 3: lqMesh.twirl(ix, iy, radius, pr * 0.3, clockwise = lqTool == 2)
          of 4, 5: lqMesh.pucker(ix, iy, radius, pr * 0.3, bloat = lqTool == 5)
          of 6: lqMesh.smooth(ix, iy, radius, pr * 0.5)
          of 7:
            if lqHas:
              let dx = ix - lqLast[0]
              let dy = iy - lqLast[1]
              if hypot(dx, dy) > 0.5:
                let s = if AltPressed in ui.mods: -1.0 else: 1.0
                lqMesh.pushLeft(ix, iy, dx * s, dy * s, radius, pr)
          of 8, 9: lqMesh.freeze(ix, iy, radius, pr, thaw = lqTool == 9)
          else: discard
          if lqTool > 0:
            lqDirty = true
            wakeIn(30)                   # (they go on while the button is held)
          lqLast = (ix, iy)
          lqHas = true
        endKeepSides()
        label("Drag over the picture: " & lqTools[lqTool], color = ui.theme.gray)
      col:
        if button("OK", isDefault = true, w = dp(86)):
          lqOpen = false
          if not lqMesh.isFlat:
            status = "Liquifying..."
            let src = d.filterImg(lqLayer, 0, proc (src: Img; inner: Rect): Img = src, d.bounds)
            let o = liquifyImg(src, lqMesh)
            d.beginStep("Liquify")
            d.writeBack(lqLayer, d.bounds, o)
            d.endStep()
            status = ""
        if button("Cancel", w = dp(86)): lqOpen = false
        space(dp(8))
        if button("Restore All", w = dp(86)):
          lqMesh.reconstructAll()
          lqDirty = true

# ---- Lens Correction ----------------------------------------------------------------------------------------

var
  lcOpen = false
  lc: LensCorrection
  lcAngle = 0                 ## tenths of a degree
  lcRect: Rect
  lcLayer: Layer
  lcSmall: Img
  lcSmallFor = (0, 0)
  lcBmp: Bitmap
  lcKey = ""
  lcGrid = true
  lcEdge = 0

proc startLensCorrection() =
  let d = cur()
  if d == nil: return
  let r = d.workRect
  if r.w <= 0 or r.h <= 0: return
  lcRect = r
  lcLayer = d.layer
  lc = lensDefault()
  lcAngle = 0
  lcEdge = if lcLayer.background: 2 else: 0
  lcSmall = Img()
  lcSmallFor = (0, 0)
  lcKey = ""
  lcOpen = true

proc lensDialog() =
  if not lcOpen: return
  let d = cur()
  if d == nil or d.layer != lcLayer or d.w * d.h != lcLayer.px.len:
    lcOpen = false
    return
  let avail = int(ui.w.float / ui.k)
  let boxW = clamp(avail - 92 - 290 - 56, 200, 520)
  let boxH = boxW * 3 div 4
  let pw = max(16, dp(boxW) * pxScale)
  let ph = max(16, dp(boxH) * pxScale)
  if lcSmall.w == 0 or lcSmallFor != (pw, ph):
    let f = max(1.0, max(lcRect.w / pw, lcRect.h / ph))
    lcSmall = smallCopy(lcLayer.px, d.w, lcRect, int(ceil(max(lcRect.w, lcRect.h).float / f)))
    lcSmallFor = (pw, ph)
    lcKey = ""
  lc.angle = lcAngle / 10
  lc.edge = LensEdge(lcEdge)
  lc.edgeColor = bg
  dialog(lcOpen, "Lens Correction", boxW + 92 + 290 + 44):
    row([boxW + 6, -1, 92]):
      col:
        let key = $lc & $lcSmall.w
        if key != lcKey:
          let im = lensImg(lcSmall, lc, lcRect.w, lcRect.h, 0, 0, lcRect.w / max(1, lcSmall.w))
          lcBmp = newBitmap(im.w, im.h)
          for i in 0 ..< im.px.len:
            let chk = if (((i mod im.w) div 8) + ((i div im.w) div 8)) mod 2 == 0: 0xFFFFFFFF'u32 else: 0xFFCCCCCC'u32
            lcBmp.px[i] = blendPx(chk, im.px[i], 255, bmNormal)
          lcBmp.changed()
          lcKey = key
        let (box, pic, _, _) = pictureBox("lens", lcBmp, dp(boxW), dp(boxH))
        beginKeepSides(box)
        if lcGrid and pic.w > 0:
          # a grid to set lines by
          pushClip(pic)
          for k in 1 .. 7:
            vline(pic.x + pic.w * k div 8, pic.y, pic.h, color(80, 80, 80, 160))
            hline(pic.x, pic.y + pic.h * k div 8, pic.w, color(80, 80, 80, 160))
          popClip()
        endKeepSides()
        checkbox("Show Grid", lcGrid)
      col:
        group("Geometric Distortion"):
          dvSlider("Distortion:", lc.distortion, -100, 100)
        group("Chromatic Aberration"):
          dvSlider("Red/Cyan:", lc.redCyan, -100, 100)
          dvSlider("Blue/Yellow:", lc.blueYellow, -100, 100)
        group("Vignette"):
          dvSlider("Amount:", lc.vignette, -100, 100)
          dvSlider("Midpoint:", lc.vignetteMid, 0, 100, $lc.vignetteMid)
        group("Transform"):
          dvSlider("Vertical:", lc.vertical, -100, 100)
          dvSlider("Horizontal:", lc.horizontal, -100, 100)
          dvSlider("Angle:", lcAngle, -450, 450, formatFloat(lcAngle / 10, ffDecimal, 1) & "°")
          dvSlider("Scale:", lc.scale, 50, 150, $lc.scale & "%")
          row:
            label "Edge:"
            combo(["Transparency", "Edge Extension", "Background Color"], lcEdge, w = dp(150))
      col:
        if button("OK", isDefault = true, w = dp(86)):
          lcOpen = false
          if not lc.isNeutral:
            status = "Correcting..."
            d.beginStep("Lens Correction")
            d.applyFilter(0, lensCorrection(lc))
            d.endStep()
            status = ""
        if button("Cancel", w = dp(86)): lcOpen = false
        if button("Default", w = dp(86)):
          lc = lensDefault()
          lcAngle = 0

# ---- Shear: its own dialog (a line to bend) -------------------------------------------------------------

var
  shOpen = false
  shPts = @[(0.0, 0.0), (0.0, 1.0)]
  shWrap = 0                   ## wrap around, repeat the edge pixels
  shThumb: Img
  shPreview: Bitmap
  shKey = ""

proc startShear() =
  let d = cur()
  if d == nil: return
  let r = d.workRect
  if r.w <= 0 or r.h <= 0: return
  # the part filtered, small, for the preview
  let k = min(1.0, min(dp(120) * pxScale / r.w, dp(120) * pxScale / r.h))
  let tw = max(1, int(r.w.float * k))
  let th2 = max(1, int(r.h.float * k))
  var part = newSeq[uint32](r.w * r.h)
  for y in 0 ..< r.h:
    for x in 0 ..< r.w: part[y * r.w + x] = d.layer.px[(r.y + y) * d.w + r.x + x]
  shThumb = Img(w: tw, h: th2, px: resample(part, r.w, r.h, tw, th2, rsBilinear))
  shKey = ""
  shOpen = true

proc shearDialog() =
  if not shOpen: return
  let d = cur()
  if d == nil:
    shOpen = false
    return
  dialog(shOpen, "Shear", 470):
    row([140, -1, 92]):
      let pts = shPts
      shearEditor(shPts, dp(128), proc (y: float): float = shearCurve(pts, y))
      col:
        group("Undefined Areas:"):
          radio("Wrap Around", shWrap, 0)
          radio("Repeat Edge Pixels", shWrap, 1)
        # the whole part, small, sheared
        let key = $shPts & $shWrap
        if key != shKey or shPreview == nil:
          let o = shear(shPts, shWrap == 0)(shThumb, rect(0, 0, shThumb.w, shThumb.h))
          shPreview = newBitmap(o.w, o.h)
          shPreview.px = o.px
          for p in shPreview.px.mitems: p = blendPx(white, p, 255, bmNormal)
          shPreview.changed()
          shKey = key
        let pr = place(shThumb.w div pxScale + 2, shThumb.h div pxScale + 2)
        box(pr, ui.theme.frame)
        drawBitmap(inset(pr, 1), shPreview)
      col:
        if button("OK", isDefault = true, w = dp(86)):
          shOpen = false
          d.beginStep("Shear")
          d.applyFilter(0, shear(shPts, shWrap == 0))
          d.endStep()
        if button("Cancel", w = dp(86)): shOpen = false
        if button("Defaults", w = dp(86)): shPts = @[(0.0, 0.0), (0.0, 1.0)]

# ---- Apply Image, Calculations --------------------------------------------------------------------------

type Source = object
  doc, layer, chan: int        ## the document (of those as big), its layer (0: merged), the channel
  invert: bool

var
  aiOpen = false
  aiSrc: Source
  aiMode = 0
  aiOpacity = 100
  calcOpen = false
  calcA, calcB: Source
  calcMode = 0
  calcOpacity = 100
  calcResult = 0               ## new channel, selection, new document

proc sameSized(d: Doc): seq[DocWin] =
  for w in docs:
    if w.doc.w == d.w and w.doc.h == d.h: result.add w

proc sourcePicker(title: string; src: var Source; d: Doc; channels = false) =
  ## Which image, layer and channel a source is.
  let pool = sameSized(d)
  group(title):
    var names: seq[string]
    for w in pool: names.add w.doc.name
    src.doc = clamp(src.doc, 0, max(0, pool.high))
    pushId(title)
    form 0:
      field "Document:": combo(names, src.doc, w = dp(170))
      if pool.len > 0:
        let sd = pool[src.doc].doc
        var layers = @["Merged"]
        for i in countdown(sd.layers.high, 0): layers.add sd.layers[i].name
        src.layer = clamp(src.layer, 0, layers.high)
        field "Layer:": combo(layers, src.layer, w = dp(170))
      field "Channel:":
        row:
          combo(if channels: @["Gray", "Red", "Green", "Blue"] else: @["RGB", "Red", "Green", "Blue"],
                src.chan, w = dp(110))
          checkbox("Invert", src.invert)
    popId()

proc sourcePixels(src: Source; d: Doc): seq[uint32] =
  ## The pixels of a source (its channel as gray when one is chosen).
  let pool = sameSized(d)
  if pool.len == 0: return
  let sd = pool[clamp(src.doc, 0, pool.high)].doc
  let li = if src.layer == 0: -1 else: sd.layers.high - (src.layer - 1)
  var px = sd.sourcePixels(li)
  if src.chan > 0 or src.invert:
    let ch = channelOf(px, src.chan, src.invert)
    for i in 0 ..< px.len:
      px[i] = if src.chan == 0: argb(aOf(px[i]), 255 - rOf(px[i]), 255 - gOf(px[i]), 255 - bOf(px[i]))
              else: grayPx(int(ch[i]), aOf(px[i]))
  px

proc startApplyImage() =
  let d = cur()
  if d == nil: return
  aiSrc = Source(doc: max(0, sameSized(d).find(active)))
  aiMode = 0
  aiOpacity = 100
  aiOpen = true

proc applyImageDialog() =
  if not aiOpen: return
  let d = cur()
  if d == nil:
    aiOpen = false
    return
  dialog(aiOpen, "Apply Image", 470):
    row([-1, 92]):
      col:
        sourcePicker("Source", aiSrc, d)
        group("Target: " & d.name & " (" & d.layer.name & ")"):
          row:
            label "Blending:"
            combo(layerModeNames(), aiMode, w = dp(130))
            label "Opacity:"
            intEdit(aiOpacity, w = dp(52), lo = 0, hi = 100)
            label "%"
      col:
        if button("OK", isDefault = true, w = dp(86)):
          aiOpen = false
          let px = aiSrc.sourcePixels(d)
          if px.len == d.w * d.h:
            d.beginStep("Apply Image")
            d.applyImage(px, LayerModes[aiMode], aiOpacity)
            d.endStep()
        if button("Cancel", w = dp(86)): aiOpen = false

proc startCalculations() =
  let d = cur()
  if d == nil: return
  let me = max(0, sameSized(d).find(active))
  calcA = Source(doc: me, chan: 1)
  calcB = Source(doc: me, chan: 2)
  calcMode = 0
  calcOpacity = 100
  calcOpen = true

proc calculationsDialog() =
  if not calcOpen: return
  let d = cur()
  if d == nil:
    calcOpen = false
    return
  dialog(calcOpen, "Calculations", 470):
    row([-1, 92]):
      col:
        sourcePicker("Source 1", calcA, d, channels = true)
        sourcePicker("Source 2", calcB, d, channels = true)
        row:
          label "Blending:"
          combo(layerModeNames(), calcMode, w = dp(130))
          label "Opacity:"
          intEdit(calcOpacity, w = dp(52), lo = 0, hi = 100)
          label "%"
        row:
          label "Result:"
          combo(["New Channel", "Selection", "New Document"], calcResult, w = dp(140))
      col:
        if button("OK", isDefault = true, w = dp(86)):
          calcOpen = false
          let a = channelOf(calcA.sourcePixels(d), calcA.chan, false)
          let b = channelOf(calcB.sourcePixels(d), calcB.chan, false)
          if a.len == d.w * d.h and b.len == d.w * d.h:
            let m = calculate(a, b, LayerModes[calcMode], calcOpacity)
            case calcResult
            of 0:
              d.snapStep("Calculations")
              d.alphas.add AlphaChannel(name: "#" & $(d.alphas.len + 4), m: m)
              d.endStep()
            of 1:
              d.beginStep("Calculations")
              d.touchSel()
              d.setSelection(m)
              d.endStep()
            else:
              let n = newUntitled(d.w, d.h, white, d.dpi, cmGray, "Calculations")
              for i, v in m: n.layer.px[i] = grayPx(int(v))
              n.markAll()
              addDoc(n)
        if button("Cancel", w = dp(86)): calcOpen = false

# ---- Paste Layer ------------------------------------------------------------------------------------------

var
  plOpen = false
  plName = ""
  plOpacity = 100
  plMode = 0

proc pasteLayerDialog() =
  if not plOpen: return
  dialog(plOpen, "Paste Layer", 340):
    form 0:
      field "Name:": edit(plName)
    optSlider("Opacity:", plOpacity, 0, 100)
    row:
      label "Mode:"
      combo(layerModeNames(), plMode, w = dp(130))
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)):
        plOpen = false
        let d = cur()
        if d != nil and hasClip:
          d.snapStep("Paste Layer")
          let L = d.pasteAsLayer(clip, name = plName.strip)
          L.opacity = plOpacity
          L.mode = LayerModes[plMode]
          d.markAll()
          d.endStep()
      if button("Cancel", w = dp(80)): plOpen = false

# ---- image size, canvas size, rotate ---------------------------------------------------------------------

var
  isOpen = false
  isPW, isPH: float           ## the new size, in pixels
  isUnitW, isUnitH = 0        ## its units (`sizeUnits`)
  isDpi = 72.0
  isResUnit = 0               ## the resolution in pixels/inch, pixels/cm
  isKeep = true               ## Constrain Proportions (the link between width and height)
  isResample = true           ## off: the pixels stay, the print size and resolution change together
  isFit = 0                   ## Fit To (`fitToNames`)
  isMethod = 2                ## nearest, bilinear, bicubic, Lanczos, Preserve Details
  isNoise = 0                 ## Preserve Details: the noise taken out
  caOpen = false              ## Content-Aware Scale
  caW, caH = 100
  caSel = false
  caSkin = false
  csOpen = false
  csW, csH = 0
  csUnit = 0                  ## Canvas Size's unit (`sizeUnits`)
  csRelative = false          ## ... the size added (not the whole)
  csAx, csAy = 1
  csExt = 1                   ## the canvas extension color: foreground, background, white, black, gray, other
  csColor = 0xFF808080'u32
  rotOpen = false
  rotAngle = 15.0
  rotCw = 0

const
  sizeUnits = ["Pixels", "Percent", "Inches", "Centimeters", "Millimeters", "Points", "Picas"]
  fitToNames = ["Original Size", "640 x 480 px (72 ppi)", "800 x 600 px (72 ppi)",
                "1024 x 768 px (72 ppi)", "1280 x 800 px (72 ppi)", "1920 x 1080 px (72 ppi)",
                "3840 x 2160 px (72 ppi)", "4 x 6 in (300 ppi)", "5 x 7 in (300 ppi)",
                "8 x 10 in (300 ppi)", "A4: 210 x 297 mm (300 ppi)", "Custom"]
  fitToSizes: array[11, tuple[w, h, dpi: float; inches: bool]] = [
    (0.0, 0.0, 0.0, false), (640.0, 480.0, 72.0, false), (800.0, 600.0, 72.0, false),
    (1024.0, 768.0, 72.0, false), (1280.0, 800.0, 72.0, false), (1920.0, 1080.0, 72.0, false),
    (3840.0, 2160.0, 72.0, false), (6.0, 4.0, 300.0, true), (7.0, 5.0, 300.0, true),
    (10.0, 8.0, 300.0, true), (297.0 / 25.4, 210.0 / 25.4, 300.0, true)]

proc pxPerUnit(u: int; whole, dpi: float): float =
  ## Pixels in one `u` (`sizeUnits`): a percent of `whole` pixels; a
  ## length at `dpi`.
  case u
  of 1: whole / 100
  of 2: dpi
  of 3: dpi / 2.54
  of 4: dpi / 25.4
  of 5: dpi / 72
  of 6: dpi / 6
  else: 1.0

proc inchesPerUnit(u: int): float =
  ## (a length unit in inches; 0 for pixels and percent)
  case u
  of 2: 1.0
  of 3: 1 / 2.54
  of 4: 1 / 25.4
  of 5: 1 / 72
  of 6: 1 / 6
  else: 0.0

proc unitDecimals(u: int): int = (if u == 0: 0 elif u in {5, 6}: 1 else: 2)

proc startImageSize() =
  let d = cur()
  if d == nil: return
  isDpi = d.dpi
  isPW = d.w.float
  isPH = d.h.float
  isFit = 0
  isResample = true
  isOpen = true

proc sizeLink(keep: var bool; a, b: Rect) =
  ## The link between a width and a height (on: the proportions kept), with
  ## its bracket to the two fields `a` and `b`.
  if toolButton(glyphIcon(nfLink, ui.theme.text, dp(15)),
                if keep: "Constrain Proportions: on (click: off)" else: "Constrain Proportions: off (click: on)",
                down = keep):
    keep = not keep
  let r = ui.lastRect
  if a.h > 0 and b.h > 0:
    let c = if keep: ui.theme.text else: ui.theme.shadow
    let x = r.x + r.w div 2
    let y1 = a.y + a.h div 2
    let y2 = b.y + b.h div 2
    let x2 = r.x + r.w + dp(5)
    fill(rect(x, y1, x2 - x, 1), c)
    fill(rect(x, y1, 1, max(0, r.y - 2 - y1)), c)
    fill(rect(x, r.y + r.h + 2, 1, max(0, y2 - r.y - r.h - 2)), c)
    fill(rect(x, y2, x2 - x, 1), c)

var isFields: tuple[w, h: Rect]   ## (where the width and height were: the link's bracket)

proc imageSizeDialog() =
  if not isOpen: return
  let d = cur()
  if d == nil:
    isOpen = false
    return
  dialog(isOpen, "Image Size", 500):
    if not isResample:
      isPW = d.w.float
      isPH = d.h.float
    let pw = int(round(clamp(isPW, 1.0, 1e6)))
    let ph = int(round(clamp(isPH, 1.0, 1e6)))
    let aspect = d.h.float / max(1, d.w).float
    row([-1, 92]):
      col:
        group("Current Size: " & sizeText(d.w * d.h * 3)):
          label("Dimensions: " & $d.w & " x " & $d.h & " pixels  (" &
                formatFloat(d.w.float / d.dpi, ffDecimal, 2) & " x " &
                formatFloat(d.h.float / d.dpi, ffDecimal, 2) & " inches)")
          label("Resolution: " & $int(round(d.dpi)) & " pixels/inch")
        group("New Size: " & sizeText(pw * ph * 3) & "  (" & $pw & " x " & $ph & " px)"):
          # (the labels in one column, right of the link's)
          row([26, 66, -1]):
            label ""
            label "Fit To:"
            var f = isFit
            if combo(fitToNames, f, w = dp(214)) and f != isFit:
              isFit = f
              if f == 0:
                isPW = d.w.float
                isPH = d.h.float
                isDpi = d.dpi
              elif f < fitToSizes.len:
                let t = fitToSizes[f]
                if t.dpi > 0: isDpi = t.dpi
                # (the box turned as the image is; inside it, the proportions kept)
                var bw = if t.inches: t.w * isDpi else: t.w
                var bh = if t.inches: t.h * isDpi else: t.h
                if (d.w < d.h) != (bw < bh): swap(bw, bh)
                isResample = true
                if isKeep:
                  let k = min(bw / d.w.float, bh / d.h.float)
                  isPW = d.w.float * k
                  isPH = d.h.float * k
                else:
                  isPW = bw
                  isPH = bh
                if t.inches:
                  isUnitW = 2
                  isUnitH = 2
                else:
                  isUnitW = 0
                  isUnitH = 0
          row([26, -1]):
            col:
              # (halfway between the two rows)
              space(max(0, max(CtrlH, EditH) + Gap div 2 - (CtrlH - 1) div 2))
              sizeLink(isKeep, isFields.w, isFields.h)
              if not isResample: isKeep = true       # (the pixels stay: so do the proportions)
            col:
              for wide in [true, false]:
                row([66, 100, -1]):
                  label(if wide: "Width:" else: "Height:")
                  let u = if wide: isUnitW else: isUnitH
                  let whole = if wide: d.w.float else: d.h.float
                  let k = pxPerUnit(u, whole, isDpi)
                  var v = (if wide: isPW else: isPH) / k
                  # (the pixels kept: only a length changes, and with it the resolution)
                  let fixed = not isResample and u in {0, 1}
                  if numberEdit(v, decimals = unitDecimals(u), w = dp(96), lo = 0.0001,
                                enabled = not fixed):
                    isFit = fitToNames.high
                    if not isResample:
                      let inch = v * inchesPerUnit(u)
                      if inch > 0: isDpi = clamp(whole / inch, 1.0, 99999.0)
                    else:
                      let px = v * k
                      if wide:
                        isPW = px
                        if isKeep: isPH = px * aspect
                      else:
                        isPH = px
                        if isKeep: isPW = px / aspect
                  if wide: isFields.w = ui.lastRect else: isFields.h = ui.lastRect
                  var nu = u
                  if combo(sizeUnits, nu, w = dp(110)) and nu != u:
                    # (the two in the same unit: they change together)
                    if isUnitW == isUnitH:
                      isUnitW = nu
                      isUnitH = nu
                    elif wide: isUnitW = nu
                    else: isUnitH = nu
          row([26, 66, 100, -1]):
            label ""
            label "Resolution:"
            var r = if isResUnit == 1: isDpi / 2.54 else: isDpi
            if numberEdit(r, decimals = (if isResUnit == 1: 2 else: 0), w = dp(96), lo = 1, hi = 99999):
              let nd = if isResUnit == 1: r * 2.54 else: r
              if isResample:
                # (a print size stays a print size: its pixels follow)
                if isUnitW >= 2: isPW = isPW * nd / isDpi
                if isUnitH >= 2: isPH = isPH * nd / isDpi
              isDpi = nd
              isFit = fitToNames.high
            combo(["Pixels/Inch", "Pixels/Centimeter"], isResUnit, w = dp(130))
          if not sizeOk(pw, ph):
            label("Too big: at most " & $(maxPixels div 1_000_000) & " million pixels", color = color(160, 0, 0))
          row:
            if checkbox("Resample:", isResample) and isResample == false:
              isPW = d.w.float
              isPH = d.h.float
            combo(["Nearest Neighbor", "Bilinear", "Bicubic", "Lanczos (sharper)",
                   "Preserve Details (enlargement)"], isMethod, w = dp(200), enabled = isResample)
          if isMethod == 4 and isResample:
            optSlider("Reduce Noise:", isNoise, 0, 100)
      col:
        if button("OK", isDefault = true, w = dp(80), enabled = sizeOk(pw, ph)):
          isOpen = false
          if pw != d.w or ph != d.h or isDpi != d.dpi:
            d.snapStep("Image Size")
            if isMethod == 4 and (pw != d.w or ph != d.h): d.enlarge(pw, ph, isNoise, isDpi)
            else: d.imageSize(pw, ph, Resample(clamp(isMethod, 0, 3)), isDpi)
            d.endStep()
            if recording:
              record(ActStep(kind: acImageSize, name: "Image Size",
                             vals: @[pw.float, ph.float, isMethod.float, isDpi, isNoise.float]))
            if active != nil: active.fitWindow()
        if button("Cancel", w = dp(80)): isOpen = false
        if button("Reset", w = dp(80)):
          isPW = d.w.float
          isPH = d.h.float
          isDpi = d.dpi
          isFit = 0
          isResample = true

proc contentAwareScaleDialog() =
  if not caOpen: return
  let d = cur()
  if d == nil:
    caOpen = false
    return
  let nw = max(2, d.w * caW div 100)
  let nh = max(2, d.h * caH div 100)
  dialog(caOpen, "Content-Aware Scale", 400):
    row([-1, 92]):
      col:
        paragraph("Makes the image narrower or wider, shorter or taller, taking out (or doubling) " &
                  "the paths of least detail: people and things keep their shape.", color = ui.theme.gray)
        for (lab, v, n) in [("Width:", addr caW, nw), ("Height:", addr caH, nh)]:
          row([60, 70, -1]):
            label lab
            intEdit(v[], w = dp(64), lo = 10, hi = 300)
            label("% (" & $n & " pixels)")
        checkbox("Protect the selection", caSel, enabled = d.hasSelection)
        checkbox("Protect Skin Tones", caSkin)
        if not sizeOk(nw, nh):
          label("Too big: at most " & $(maxPixels div 1_000_000) & " million pixels", color = color(160, 0, 0))
      col:
        if button("OK", isDefault = true, w = dp(80), enabled = sizeOk(nw, nh) and (nw != d.w or nh != d.h)):
          caOpen = false
          var protect: seq[uint8] = @[]
          if caSel and d.hasSelection: protect = d.sel
          if caSkin:
            d.updateComposite()
            let skin = skinMask(Img(w: d.w, h: d.h, px: d.compCopy))
            if protect.len == 0: protect = skin
            else:
              for i in 0 ..< protect.len: protect[i] = max(protect[i], skin[i])
          status = "Scaling..."
          d.snapStep("Content-Aware Scale")
          d.contentAwareScale(nw, nh, protect)
          d.endStep()
          status = ""
          if active != nil: active.fitWindow()
        if button("Cancel", w = dp(80)): caOpen = false

proc canvasSizeDialog() =
  if not csOpen: return
  let d = cur()
  if d == nil:
    csOpen = false
    return
  dialog(csOpen, "Canvas Size", 420):
    row([-1, 92]):
      col:
        group("Current Size: " & sizeText(d.w * d.h * 3)):
          label("Width: " & $d.w & " pixels")
          label("Height: " & $d.h & " pixels")
        group("New Size: " & sizeText(csW * csH * 3) & "  (" & $csW & " x " & $csH & " px)"):
          for wide in [true, false]:
            row([58, 100, -1]):
              label(if wide: "Width:" else: "Height:")
              let whole = if wide: d.w else: d.h
              let k = pxPerUnit(csUnit, whole.float, d.dpi)
              let px = if wide: csW else: csH
              # (Relative: what is added -- less than 0 cuts)
              var v = (if csRelative: (px - whole).float else: px.float) / k
              if numberEdit(v, decimals = unitDecimals(csUnit), w = dp(96),
                            lo = (if csRelative: -whole.float / k + 1 / k else: 1 / k), hi = 30000 / k * 4):
                let n = clamp(int(round(v * k)) + (if csRelative: whole else: 0), 1, 30000)
                if wide: csW = n else: csH = n
              if wide: combo(sizeUnits, csUnit, w = dp(110))
              else: label tr(sizeUnits[csUnit]).toLowerAscii
          checkbox("Relative", csRelative)
          row:
            label "Anchor:"
            anchorGrid(csAx, csAy)
          row:
            label "Canvas extension color:"
            combo(["Foreground", "Background", "White", "Black", "Gray", "Other..."], csExt, w = dp(110))
            if csExt == 5: colorWell(csColor, "csext", dp(40))
      col:
        if button("OK", isDefault = true, w = dp(80), enabled = sizeOk(csW, csH)):
          csOpen = false
          d.snapStep("Canvas Size")
          d.canvasSize(csW, csH, csAx, csAy,
                       [fg, bg, white, black, 0xFF808080'u32, csColor][clamp(csExt, 0, 5)] or 0xFF000000'u32)
          d.endStep()
          if recording:
            record(ActStep(kind: acCanvasSize, name: "Canvas Size",
                           vals: @[csW.float, csH.float, csAx.float, csAy.float]))
          if active != nil: active.fitWindow()
        if button("Cancel", w = dp(80)): csOpen = false

proc rotateDialog() =
  if not rotOpen: return
  dialog(rotOpen, "Arbitrary Rotate Canvas", 320):
    row([-1, 92]):
      col:
        row:
          label "Angle:"
          numberEdit(rotAngle, decimals = 2, w = dp(80), lo = -359.99, hi = 359.99)
          label "°"
        radio("Clockwise", rotCw, 0)
        radio("Counterclockwise", rotCw, 1)
      col:
        if button("OK", isDefault = true, w = dp(80)):
          rotOpen = false
          let d = cur()
          if d != nil:
            d.snapStep("Rotate Canvas")
            try:
              d.rotateArbitrary(if rotCw == 0: rotAngle else: -rotAngle, bg)
              d.endStep()
              if recording:
                record(ActStep(kind: acRotate, name: "Rotate Canvas",
                               vals: @[if rotCw == 0: rotAngle else: -rotAngle]))
            except ValueError:
              d.cancelStep()
              status = "The turned image would be too big"
            if active != nil: active.fitWindow()
        if button("Cancel", w = dp(80)): rotOpen = false

# ---- fill, stroke, feather, modify --------------------------------------------------------------------

var
  fillOpen = false
  fillUse = 0                 ## foreground, background, pattern, black, 50% gray, white, a color
  fillColor = 0xFF3080C0'u32  ## (Use: Color...)
  fillOpacity = 100
  fillMode = 0
  strokeOpen = false
  strokeW = 1
  strokeLoc = 1
  strokeOpacity = 100
  strokeMode = 0
  strokeColor = 0'u32         ## (0: the foreground color, taken when the dialog opens)
  numOpen = false
  numTitle = ""
  numLabel = ""
  numVal = 1
  numHi = 250

proc fillDialog() =
  if not fillOpen: return
  dialog(fillOpen, "Fill", 360):
    row([-1, 92]):
      col:
        group("Contents"):
          row:
            label "Use:"
            combo(["Foreground Color", "Background Color", "Pattern", "Black", "50% Gray", "White",
                   "Color..."], fillUse, w = dp(150))
            if fillUse == 6: colorWell(fillColor, "fillusecolor", dp(40))
        group("Blending"):
          optSlider("Opacity:", fillOpacity, 1, 100)
          row:
            label "Mode:"
            combo(modeNames(), fillMode, w = dp(120))
      col:
        if button("OK", isDefault = true, w = dp(80)):
          fillOpen = false
          let d = cur()
          if d != nil:
            d.beginStep("Fill")
            if fillUse == 2 and pattern.len > 0:
              let o = PaintOpts(pattern: pattern, pw: patternW, ph: patternH)
              let op = fillOpacity * 255 div 100
              let m = PaintModes[fillMode]
              d.mapPixels(d.layer, d.bounds, proc (p: uint32; x, y: int): uint32 =
                blendPx(p, patternAt(o, x, y), op, m, x, y))
            else:
              let c = [fg, bg, fg, black, 0xFF808080'u32, white, fillColor][clamp(fillUse, 0, 6)]
              d.fillSelection(c, fillOpacity, PaintModes[fillMode])
            d.endStep()
            if recording:
              record(ActStep(kind: acFill, name: "Fill", vals: @[fillUse.float, fillOpacity.float, fillMode.float,
                                                                 fillColor.float]))
        if button("Cancel", w = dp(80)): fillOpen = false

proc strokeDialog() =
  if not strokeOpen: return
  dialog(strokeOpen, "Stroke", 360):
    row([-1, 92]):
      col:
        group("Stroke"):
          optNumber("Width:", strokeW, 1, 16, "pixels")
          if strokeColor == 0: strokeColor = fg or 0xFF000000'u32
          row:
            label "Color:"
            colorWell(strokeColor, "strokecolor", dp(60))
        group("Location"):
          row:
            radio("Inside", strokeLoc, 0)
            radio("Center", strokeLoc, 1)
            radio("Outside", strokeLoc, 2)
        group("Blending"):
          optSlider("Opacity:", strokeOpacity, 1, 100)
          row:
            label "Mode:"
            combo(modeNames(), strokeMode, w = dp(120))
      col:
        if button("OK", isDefault = true, w = dp(80)):
          strokeOpen = false
          let d = cur()
          if d != nil and d.hasSelection:
            d.beginStep("Stroke")
            d.strokeSelection(strokeColor, strokeW, strokeLoc, strokeOpacity, PaintModes[strokeMode])
            d.endStep()
        if button("Cancel", w = dp(80)): strokeOpen = false

proc askNumber(title, lab: string; v, hi: int) =
  numTitle = title
  numLabel = lab
  numVal = v
  numHi = hi
  numOpen = true
  typeFirst()

proc numberDialog() =
  if not numOpen: return
  dialog(numOpen, numTitle, 300):
    row([-1, 92]):
      col:
        row:
          label numLabel
          intEdit(numVal, w = dp(70), lo = 0, hi = numHi)
          label "pixels"
      col:
        if button("OK", isDefault = true, w = dp(80)):
          numOpen = false
          let d = cur()
          if d != nil:
            d.beginStep(numTitle)
            d.touchSel()
            case numTitle
            of "Feather": d.feather(numVal.float)
            of "Border": d.borderSelection(numVal)
            of "Smooth": d.smoothSelection(numVal)
            of "Expand": d.expandSelection(numVal)
            of "Contract": d.contractSelection(numVal)
            of "Grow": d.growSelection(numVal)
            of "Similar": d.growSelection(numVal, similar = true)
            else: discard
            d.endStep()
            if recording: record(ActStep(kind: acSelect, name: numTitle, vals: @[numVal.float]))
        if button("Cancel", w = dp(80)): numOpen = false

# ---- Color Range -----------------------------------------------------------------------------------------

var
  crOpen = false
  crSelect = 0
  crFuzz = 40
  crSample = 0xFFFF0000'u32
  crShow = 0                 ## the selection, the image
  crBmp: Bitmap
  crKey = ""

proc crMask(d: Doc): seq[uint8] =
  d.updateComposite()
  if crSelect == 0: return d.colorRangeMask(crSample, crFuzz)
  result = newSeq[uint8](d.w * d.h)
  for i, p in d.compCopy:
    var v = 0.0
    case crSelect
    of 1 .. 6:
      let hsb = toHsb(p)
      let target = [0.0, 60, 120, 180, 240, 300][crSelect - 1]
      var dh = abs(hsb.h - target)
      if dh > 180: dh = 360 - dh
      v = clamp(1 - dh / 45, 0.0, 1.0) * clamp(hsb.s * 2, 0.0, 1.0)
    of 7: v = clamp((lumaOf(p) - 170) / 60, 0.0, 1.0)
    of 8: v = clamp(1 - abs(lumaOf(p) - 128) / 70, 0.0, 1.0)
    else: v = clamp((85 - lumaOf(p)) / 60, 0.0, 1.0)
    result[i] = uint8(round(v * 255))

proc colorRangeDialog() =
  if not crOpen: return
  let d = cur()
  if d == nil:
    crOpen = false
    return
  dialog(crOpen, "Color Range", 470):
    row([-1, 92]):
      col:
        row:
          label "Select:"
          combo(["Sampled Colors", "Reds", "Yellows", "Greens", "Cyans", "Blues", "Magentas",
                 "Highlights", "Midtones", "Shadows"], crSelect, w = dp(150))
        if crSelect == 0:
          optSlider("Fuzziness:", crFuzz, 0, 200, "")
        # the preview: what would be selected (white), or the image
        let side = dp(200)
        let k = min(side / d.w, side / d.h)
        let pw = max(1, int(d.w.float * k))
        let ph = max(1, int(d.h.float * k))
        let r = place(pw + 2, ph + 2)
        let key = $crSelect & "/" & $crFuzz & "/" & $crSample & "/" & $crShow & "/" & $d.ver
        if key != crKey or crBmp == nil:
          let m = crMask(d)
          var px = newSeq[uint32](d.w * d.h)
          d.updateComposite()
          let cp = d.compPtr
          for i in 0 ..< px.len: px[i] = if crShow == 0: grayPx(int(m[i])) else: cp[i]
          crBmp = thumbnailOf(px, d.w, d.h, pw * pxScale, ph * pxScale, checker = false)
          crKey = key
        box(r, ui.theme.frame)
        drawBitmap(inset(r, 1), crBmp)
        let hit = interact(idOf("crpreview"), r, focusable = false)
        if hit.hover: ui.cursor = curCrosshair
        if hit.clicked and crSelect == 0:
          let ix = clamp(int((ui.mx - r.x - 1).float / k), 0, d.w - 1)
          let iy = clamp(int((ui.my - r.y - 1).float / k), 0, d.h - 1)
          crSample = d.pixelAt(ix, iy)
        row:
          radio("Selection", crShow, 0)
          radio("Image", crShow, 1)
        if crSelect == 0: label("Click the picture to take the color", color = ui.theme.gray)
      col:
        if button("OK", isDefault = true, w = dp(80)):
          crOpen = false
          var m = crMask(d)
          d.beginStep("Color Range")
          d.touchSel()
          d.setSelection(m)
          d.endStep()
        if button("Cancel", w = dp(80)): crOpen = false
        space(dp(8))
        let sw = place(dp(40), dp(20))
        fill(sw, colorOf(crSample))
        box(sw, ui.theme.frame)
        if button("Use Fg", w = dp(80)): crSample = fg

# ---- Variations ------------------------------------------------------------------------------------------

var
  varOpen = false
  varTone = 1                 ## shadows, midtones, highlights, saturation
  varFine = 3                 ## 0 fine .. 6 coarse
  varShift: array[3, int]
  varLight = 0
  varSat = 0
  varThumb: Img
  varThumbs: Table[string, Bitmap]
  varKey = ""

proc varFn(shift: array[3, int]; light, sat: int): FilterFn =
  variations(shift, light, sat, ToneRange(min(varTone, 2)))

proc startVariations() =
  let d = cur()
  if d == nil: return
  let r = d.workRect
  let k = min(dp(96) * pxScale / r.w, dp(72) * pxScale / r.h)
  let tw = max(1, int(r.w.float * min(1.0, k)))
  let th2 = max(1, int(r.h.float * min(1.0, k)))
  var part = newSeq[uint32](r.w * r.h)
  for y in 0 ..< r.h:
    for x in 0 ..< r.w: part[y * r.w + x] = d.layer.px[(r.y + y) * d.w + r.x + x]
  varThumb = Img(w: tw, h: th2, px: resample(part, r.w, r.h, tw, th2, rsBilinear))
  for c in 0 .. 2: varShift[c] = 0
  varLight = 0
  varSat = 0
  varKey = ""
  varOpen = true

proc varStep(): int = [4, 8, 14, 22, 32, 45, 60][clamp(varFine, 0, 6)]

proc variationsDialog() =
  if not varOpen: return
  let d = cur()
  if d == nil:
    varOpen = false
    return
  let st = varStep()
  proc thumb(name: string; shift: array[3, int]; light, sat: int): Bitmap =
    let key = name & $shift & $light & $sat & $varTone
    if varThumbs.hasKey(key): return varThumbs[key]
    let o = varFn(shift, light, sat)(varThumb, rect(0, 0, varThumb.w, varThumb.h))
    result = newBitmap(o.w, o.h)
    result.px = o.px
    for p in result.px.mitems: p = blendPx(white, p, 255, bmNormal)
    varThumbs[key] = result
  let key = $varShift & $varLight & $varSat & $varTone & $varFine
  if key != varKey:
    varThumbs.clear()
    varKey = key
  proc cell(name: string; shift: array[3, int]; light, sat: int): bool =
    col:
      let b = thumb(name, shift, light, sat)
      let r = place(dp(100), dp(76))
      fill(r, ui.theme.window)
      box(r, ui.theme.frame)
      let k = min((r.w - 4) / b.w, (r.h - 4) / b.h)
      let bw = int(b.w.float * k)
      let bh = int(b.h.float * k)
      drawBitmap(rect(r.x + (r.w - bw) div 2, r.y + (r.h - bh) div 2, bw, bh), b)
      result = interact(idOf("var:" & name), r, focusable = false).clicked
      label(name, color = ui.theme.gray)
  dialog(varOpen, "Variations", 640):
    let cur3 = varShift
    let none = [0, 0, 0]
    row([104, 104, -1, 92]):
      discard cell("Original", none, 0, 0)
      discard cell("Current Pick", cur3, varLight, varSat)
      col:
        row([-1, -1]):
          radio("Shadows", varTone, 0)
          radio("Midtones", varTone, 1)
        row([-1, -1]):
          radio("Highlights", varTone, 2)
          radio("Saturation", varTone, 3)
        row([36, -1, 48]):
          label "Fine"
          slider(varFine, 0, 6, ticks = 6)
          label "Coarse"
      col:
        if button("OK", isDefault = true, w = dp(86)):
          varOpen = false
          d.beginStep("Variations")
          d.applyFilter(0, varFn(varShift, varLight, varSat))
          d.endStep()
        if button("Cancel", w = dp(86)): varOpen = false
        if button("Reset", w = dp(86)):
          for c in 0 .. 2: varShift[c] = 0
          varLight = 0
          varSat = 0
    separator()
    row([-1, 104]):
      col:
        if varTone == 3:
          row([104, 104, 104]):
            if cell("Less Saturation", cur3, varLight, varSat - st): varSat -= st
            discard cell("Current Pick ", cur3, varLight, varSat)
            if cell("More Saturation", cur3, varLight, varSat + st): varSat += st
        else:
          # the colors around the pick, each across from its opposite
          row([104, 104, 104]):
            if cell("More Green", [cur3[0], cur3[1] + st, cur3[2]], varLight, varSat): varShift[1] += st
            discard place(dp(104), 1)
            if cell("More Yellow", [cur3[0], cur3[1], cur3[2] - st], varLight, varSat): varShift[2] -= st
          row([104, 104, 104]):
            if cell("More Cyan", [cur3[0] - st, cur3[1], cur3[2]], varLight, varSat): varShift[0] -= st
            discard cell("Current Pick  ", cur3, varLight, varSat)
            if cell("More Red", [cur3[0] + st, cur3[1], cur3[2]], varLight, varSat): varShift[0] += st
          row([104, 104, 104]):
            if cell("More Blue", [cur3[0], cur3[1], cur3[2] + st], varLight, varSat): varShift[2] += st
            discard place(dp(104), 1)
            if cell("More Magenta", [cur3[0], cur3[1] - st, cur3[2]], varLight, varSat): varShift[1] -= st
      col:
        if cell("Lighter", cur3, varLight + st, varSat): varLight += st
        discard cell("Current Pick   ", cur3, varLight, varSat)
        if cell("Darker", cur3, varLight - st, varSat): varLight -= st

# ---- modes -------------------------------------------------------------------------------------------------

var
  indexedOpen = false
  idxPalette = 3              ## exact, system, uniform, adaptive
  idxColors = 256
  idxDither = 1
  bitmapOpen = false
  bitmapMethod = 1
  tableOpen = false
  tableSel = -1
  tablePicker: ColorPickerState
  tablePickOpen = false
  tableColor: uint32

proc modeDialogs() =
  let d = cur()
  if indexedOpen:
    dialog(indexedOpen, "Indexed Color", 340):
      row([-1, 92]):
        col:
          group("Palette"):
            radio("Exact", idxPalette, 0)
            radio("System (16 colors)", idxPalette, 1)
            radio("Uniform (216 colors)", idxPalette, 2)
            radio("Adaptive", idxPalette, 3)
          row:
            label "Colors:"
            intEdit(idxColors, w = dp(60), lo = 2, hi = 256, enabled = idxPalette == 3)
          group("Dither"):
            radio("None", idxDither, 0)
            radio("Diffusion", idxDither, 1)
        col:
          if button("OK", isDefault = true, w = dp(80)) and d != nil:
            indexedOpen = false
            d.snapStep("Indexed Color")
            d.updateComposite()
            let pal = case idxPalette
                      of 0: medianCut(d.flattened(white), 256)
                      of 1: systemPalette()
                      of 2: uniformPalette()
                      else: medianCut(d.flattened(white), idxColors)
            d.toIndexed(pal, idxDither == 1)
            d.endStep()
          if button("Cancel", w = dp(80)): indexedOpen = false
  if bitmapOpen:
    dialog(bitmapOpen, "Bitmap", 320):
      row([-1, 92]):
        col:
          group("Method"):
            radio("50% Threshold", bitmapMethod, 0)
            radio("Diffusion Dither", bitmapMethod, 1)
        col:
          if button("OK", isDefault = true, w = dp(80)) and d != nil:
            bitmapOpen = false
            d.snapStep("Bitmap")
            d.toBitmapMode(bitmapMethod == 1)
            d.endStep()
          if button("Cancel", w = dp(80)): bitmapOpen = false
  if tableOpen and d != nil:
    dialog(tableOpen, "Color Table", 360):
      let cell = dp(18)
      let cols = 16
      let r = place(cols * cell, max(1, (d.palette.len + cols - 1) div cols) * cell)
      for i, c in d.palette:
        let cr = rect(r.x + (i mod cols) * cell, r.y + (i div cols) * cell, cell, cell)
        fill(inset(cr, 1), colorOf(c))
        if interact(idOf("ct" & $i), cr, focusable = false).clicked:
          tableSel = i
          tableColor = c
          tablePickOpen = true
      label("Click a color to change it", color = ui.theme.gray)
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)): tableOpen = false
  if colorPickerDialog(tablePickOpen, "Select table color", tableColor, tablePicker):
    if d != nil and tableSel >= 0 and tableSel < d.palette.len:
      let old = d.palette[tableSel]
      d.snapStep("Color Table")
      d.palette[tableSel] = tableColor
      for L in d.layers:
        for p in L.px.mitems:
          if (p and 0xFFFFFF'u32) == (old and 0xFFFFFF'u32): p = withAlpha(tableColor, aOf(p))
        inc L.ver
      d.markAll()
      d.endStep()

# ---- layers, brushes ----------------------------------------------------------------------------------------

proc layerDialogs() =
  let d = cur()
  if layerOptsOpen:
    dialog(layerOptsOpen, (if d != nil and d.current.group: "Group Properties" else: "Layer Options"), 360):
      form 0:
        field "Name:": edit(layerOptsName)
      optSlider("Opacity:", layerOptsOpacity, 0, 100)
      let isGroup = d != nil and d.current.group
      row:
        label "Mode:"
        combo((if isGroup: groupModeNames() else: layerModeNames()), layerOptsMode, w = dp(130))
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)) and d != nil:
          layerOptsOpen = false
          d.layersChange(if isGroup: "Group Properties" else: "Layer Options"):
            let L = d.layers[d.cur]
            L.name = layerOptsName.strip
            L.opacity = layerOptsOpacity
            if isGroup:
              L.passThrough = layerOptsMode == 0
              if layerOptsMode > 0: L.mode = LayerModes[clamp(layerOptsMode - 1, 0, LayerModes.high)]
            else:
              L.mode = LayerModes[clamp(layerOptsMode, 0, LayerModes.high)]
            d.markAll()
          if recording and not isGroup:
            record(ActStep(kind: acLayerProps, name: $LayerModes[clamp(layerOptsMode, 0, LayerModes.high)],
                           vals: @[layerOptsMode.float, layerOptsOpacity.float]))
        if button("Cancel", w = dp(80)): layerOptsOpen = false
  if newLayerOpen:
    dialog(newLayerOpen, "New Layer", 340):
      form 0:
        field "Name:": edit(newLayerName)
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)) and d != nil:
          newLayerOpen = false
          d.snapStep("New Layer")
          discard d.addLayer(newLayerName.strip)
          d.endStep()
          if recording: record(ActStep(kind: acNewLayer, name: newLayerName.strip))
        if button("Cancel", w = dp(80)): newLayerOpen = false
  if brushOptsOpen:
    dialog(brushOptsOpen, if brushOptsNew: "New Brush" else: "Brush Options", 380):
      row([250, -1]):
        col:
          optSlider("Diameter:", brushOpts.diameter, 1, MaxDiameter, "px")
          optSlider("Hardness:", brushOpts.hardness, 0, 100)
          var sp = brushOpts.spacing > 0
          row:
            if checkbox("Spacing:", sp): brushOpts.spacing = (if sp: 25 else: 0)
          if brushOpts.spacing > 0: optSlider("", brushOpts.spacing, 1, 999)
          optSlider("Angle:", brushOpts.angle, -180, 180, "°")
          optSlider("Roundness:", brushOpts.roundness, 1, 100)
        col:
          # the tip, as big as it fits
          let r = place(dp(80), dp(80))
          fill(r, ui.theme.window)
          box(r, ui.theme.frame)
          let m = tipMask(brushOpts, min(1.0, (r.w - 8).float / max(1, brushOpts.diameter).float))
          let b = newBitmap(m.w, m.h)
          for k, a in m.a: b.px[k] = argb(int(a * 255), 0, 0, 0)
          b.changed()
          drawBitmap(rect(r.x + (r.w - m.w) div 2, r.y + (r.h - m.h) div 2, m.w, m.h), b)
          if button("OK", isDefault = true, w = dp(80)):
            brushOptsOpen = false
            let t = brushOwner()
            opts[t].tip = brushOpts
            opts[t].preset = ""
            if brushOptsNew: presetDlg = (true, 0, "Brush " & $brushOpts.diameter, -1)
          if button("Cancel", w = dp(80)): brushOptsOpen = false

# ---- histogram, preferences ----------------------------------------------------------------------------------

var
  histOpen = false
  histChan = 0
  histData: Histogram
  prefsOpen = false

proc histogramDialog() =
  if not histOpen: return
  dialog(histOpen, "Histogram", 360):
    row:
      label "Channel:"
      combo(["Gray", "Red", "Green", "Blue"], histChan, w = dp(110))
    histogramView(histData.counts[histChan], dp(256), dp(120))
    let r = ui.lastRect
    gradientBar(dp(256), dp(10), color(0, 0, 0), color(255, 255, 255))
    let s = histData.stats(histChan)
    let over = mouseIn(r)
    let lvl = clamp((ui.mx - r.x) * 256 div max(1, r.w), 0, 255)
    var below = 0
    for v in 0 .. lvl: below += histData.counts[histChan][v]
    row([-1, -1]):
      col:
        label("Mean: " & formatFloat(s.mean, ffDecimal, 2))
        label("Std Dev: " & formatFloat(s.sd, ffDecimal, 2))
        label("Median: " & $s.median)
        label("Pixels: " & $histData.total)
      col:
        label("Level: " & (if over: $lvl else: ""))
        label("Count: " & (if over: $histData.counts[histChan][lvl] else: ""))
        label("Percentile: " & (if over: formatFloat(100 * below / max(1, histData.total), ffDecimal, 2) else: ""))
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): histOpen = false

# ---- closing --------------------------------------------------------------------------------------------------

proc closingDialogs() =
  if closeAsk.on:
    var open = true
    case msgBox(open, AppName, "Save changes to the document \"" & closeAsk.dw.doc.name & "\" before closing?",
                ["&Yes", "&No", "Cancel"], miQuestion)
    of 1:
      closeAsk.dw.save()
      if not closeAsk.dw.doc.modified: closeDoc(closeAsk.dw)
      closeAsk.on = false
    of 2:
      closeDoc(closeAsk.dw)
      closeAsk.on = false
    of 3:
      closeAsk.on = false
    else: discard
  if quitConfirm:
    # (documents open: the program does not just go)
    var open = true
    var changed = 0
    for dw in docs:
      if dw.doc.modified: inc changed
    let n = docs.len
    let what = $n & (if n == 1: " document is" else: " documents are") & " open" &
               (if changed > 0: " (" & $changed & " with changes not saved)" else: "") & "."
    let msg = if prefs.session: what & " They will open again, as they are now, the next time you start " &
                                AppName & "."
              else: what & " You will be asked to save the changes."
    case msgBox(open, "Quit " & AppName, msg, ["&Quit", "Cancel"], miQuestion)
    of 1:
      quitConfirm = false
      if prefs.session:
        writeSession()
        discard waitForSave()
        quitApp()
      else: quitAsked = true
    of 2: quitConfirm = false
    else:
      if not open: quitConfirm = false
  if quitAsked and not closeAsk.on:
    var unsaved: DocWin = nil
    for dw in docs:
      if dw.doc.modified:
        unsaved = dw
        break
    if unsaved == nil:
      discard waitForSave()                 # (a save in the background: finished first)
      quitApp()
    else:
      unsaved.win.open = false
      closeAsk = (true, unsaved)
      unsaved.win.open = true

# ---- Quick Mask Options ---------------------------------------------------------------------------------

var
  qmOpen = false
  qmShows = 0                  ## the color over: the masked areas, the selected areas
  qmColor = 0xFFFF0000'u32
  qmOpacity = 50
  qmPickOpen = false
  qmPicker: ColorPickerState

proc startQuickMaskOptions() =
  qmShows = ord(quickMaskOnSelected)
  qmColor = quickMaskColor
  qmOpacity = quickMaskOpacity
  qmOpen = true

proc quickMaskDialog() =
  if qmOpen:
    dialog(qmOpen, "Quick Mask Options", 340):
      row([-1, 92]):
        col:
          group("Color Indicates:"):
            radio("Masked Areas", qmShows, 0)
            radio("Selected Areas", qmShows, 1)
          group("Color"):
            row:
              let sw = place(dp(34), dp(22))
              fill(sw, colorOf(qmColor))
              box(sw, ui.theme.frame)
              if interact(idOf("qmcolor"), sw, focusable = false).clicked: qmPickOpen = true
              label "Opacity:"
              intEdit(qmOpacity, w = dp(52), lo = 0, hi = 100)
              label "%"
        col:
          if button("OK", isDefault = true, w = dp(86)):
            qmOpen = false
            quickMaskOnSelected = qmShows == 1
            quickMaskColor = qmColor
            quickMaskOpacity = qmOpacity
          if button("Cancel", w = dp(86)): qmOpen = false
  if colorPickerDialog(qmPickOpen, "Select quick mask color", qmColor, qmPicker): discard

# ---- the color pickers of the toolbox -----------------------------------------------------------------------------

proc colorDialogs() =
  if colorPickerDialog(showFgPicker, "Select foreground color", fg, fgPicker): discard
  if colorPickerDialog(showBgPicker, "Select background color", bg, bgPicker): discard

proc dialogs() =
  newDialog()
  editToolbarDialog()
  fileDialogs()
  adjustDialog()
  gradientDialogs()
  filterDialog()
  developDialog()
  liquifyDialog()
  lensDialog()
  imageSizeDialog()
  contentAwareScaleDialog()
  canvasSizeDialog()
  rotateDialog()
  fillDialog()
  strokeDialog()
  numberDialog()
  colorRangeDialog()
  typeDialogs()
  variationsDialog()
  modeDialogs()
  layerDialogs()
  histogramDialog()
  colorDialogs()
  quickMaskDialog()
  shearDialog()
  pasteLayerDialog()
  storageDialog()
  pageSetupDialog()
  textureDialogs()
  applyImageDialog()
  calculationsDialog()
  closingDialogs()
  layerCompDialog()
  neuralDialog()
  pdfDialogs()
  importDialogs()
  getFontsDialog()
  pathValueDialog()
  adjPresetDialogs()
  ccDialogs()
  dailyDialogs()
  assetsDialog()

# ---- Brush Dynamics ------------------------------------------------------------------------------------------

var
  dynOpen = false
  dynTool = tBrush
  dynEdit: BrushDynamics
  dynPreview: tuple[key: string; b: Bitmap]

proc startDynamics(t: Tool) =
  ## (Brush Settings: a palette now, as the usual)
  dynTool = t
  dynEdit = opts[t].dyn
  showPanel("brushsettings")
  palettesHidden = false

proc dynamicsPreview(w, h: int): Bitmap =
  ## A stroke painted with the dynamics (a wave across a white strip).
  let key = $dynEdit & "/" & $dynTool & "/" & $opts[dynTool].tip.diameter & "/" & $fg & "/" & $bg & "/" & $w & "x" & $h
  if dynPreview.b != nil and dynPreview.key == key: return dynPreview.b
  let d = newDoc(w, h, white)
  var o = paintOpts(dynTool, d)
  o.dyn = dynEdit
  o.dyn.symmetry = syNone
  o.fade = 0
  if o.tool == tkEraser: o.tool = tkBrush
  var tip = tipFor(dynTool)
  let k = min(1.0, (h.float * 0.35) / max(1, tip.diameter).float)
  if tip.custom.len == 0: tip.diameter = max(1, int(tip.diameter.float * k))
  d.beginStep("Preview")
  var st = d.beginStroke(o, tip, 12, h / 2)
  st.startStroke()
  for i in 1 .. 60:
    let x = 12 + (w - 24).float * i.float / 60
    st.strokeTo(x, h / 2 + sin(i.float / 60 * PI * 2) * h.float * 0.25)
  st.endStroke()
  d.endStep()
  result = d.toBitmap(white)
  dynPreview = (key, result)

proc dynSlider(lab: string; v: var int; lo, hi: int; unit = "%"): bool {.discardable.} =
  row([84, -1, 40]):
    label lab
    result = slider(v, lo, hi, ticks = 0)
    label $v & unit

proc dynamicsDialog() =
  if not dynOpen: return
  dialog(dynOpen, "Brush Dynamics", 520):
    row([-1, -1]):
      col:
        group("Shape Dynamics"):
          dynSlider("Size Jitter:", dynEdit.sizeJitter, 0, 100)
          dynSlider("Minimum:", dynEdit.minDiameter, 0, 100)
          dynSlider("Angle Jitter:", dynEdit.angleJitter, 0, 100)
          dynSlider("Round Jitter:", dynEdit.roundJitter, 0, 100)
        group("Scattering"):
          dynSlider("Scatter:", dynEdit.scatter, 0, 1000)
          checkbox("Both Axes", dynEdit.scatterBoth)
          var c = max(1, dynEdit.count)
          if dynSlider("Count:", c, 1, 16, ""): dynEdit.count = c
          dynSlider("Count Jitter:", dynEdit.countJitter, 0, 100)
      col:
        group("Transfer"):
          dynSlider("Opacity Jitter:", dynEdit.opacityJitter, 0, 100)
          var f = if dynEdit.flow <= 0: 100 else: dynEdit.flow
          if dynSlider("Flow:", f, 1, 100): dynEdit.flow = f
          dynSlider("Flow Jitter:", dynEdit.flowJitter, 0, 100)
        group("Color Dynamics"):
          dynSlider("Fg/Bg Jitter:", dynEdit.fgBgJitter, 0, 100)
          dynSlider("Hue Jitter:", dynEdit.hueJitter, 0, 100)
          dynSlider("Bright Jitter:", dynEdit.brightJitter, 0, 100)
    row([-1, -1]):
      col:
        group("Texture"):
          checkbox("Use the Pattern (Define Pattern)", dynEdit.textureOn, enabled = pattern.len > 0)
          if dynEdit.textureOn:
            var dd = if dynEdit.textureDepth <= 0: 100 else: dynEdit.textureDepth
            if dynSlider("Depth:", dd, 1, 100): dynEdit.textureDepth = dd
            var sc = if dynEdit.textureScale <= 0: 100 else: dynEdit.textureScale
            if dynSlider("Scale:", sc, 10, 400): dynEdit.textureScale = sc
            checkbox("Invert", dynEdit.textureInvert)
      col:
        group("Dual Brush"):
          var names = @["None"]
          for p in presets: names.add p.name
          var k = clamp(dynEdit.dualBrush, 0, names.high)
          row:
            label "Brush:"
            if combo(names, k, w = dp(130)): dynEdit.dualBrush = k
          if dynEdit.dualBrush > 0:
            dynSlider("Scatter:", dynEdit.dualScatter, 0, 400)
    let pw = available()
    let ph = dp(70)
    let r = place(pw, ph)
    drawBitmap(r, dynamicsPreview(max(40, r.w), max(20, r.h)))
    box(r, ui.theme.frame)
    row:
      if button("Reset", w = dp(80)): dynEdit = BrushDynamics()
      spring()
      if button("OK", isDefault = true, w = dp(80)):
        dynOpen = false
        opts[dynTool].dyn = dynEdit
      if button("Cancel", w = dp(80)): dynOpen = false


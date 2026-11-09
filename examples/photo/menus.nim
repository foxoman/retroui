# (included by photo.nim) The menus of the 1994 program -- File, Edit,
# Mode, Image, Filter, Select, Window, Help -- the keys, and the commands
# behind both (and behind the Commands palette).

var
  aboutOpen = false
  customOpen = false
  customK: array[25, int]
  customScale = 1
  customOffset = 0
  dupOpen = false
  dupName = ""
  dupMerged = false
  splashBmp: Bitmap
  helpOpen = false

proc noteNoImage(): bool =
  if cur() == nil:
    status = "Open or make an image first"
    return true

template change(d: Doc; name: string; body: untyped) =
  ## A change made as one undo step, the whole picture kept.
  d.snapStep(name)
  body
  d.endStep()

template paintStep(d: Doc; name: string; body: untyped) =
  ## A change made as one undo step, the touched tiles kept.
  d.beginStep(name)
  body
  d.endStep()

proc duplicateDoc(d: Doc; name: string; merged: bool): Doc =
  result = newDoc(d.w, d.h, 0, d.dpi, name)
  result.mode = d.mode
  result.palette = d.palette
  if merged:
    let L = result.layers[0]
    L.px = d.flattened(white)
    L.name = "Background"
    L.background = true
  else:
    result.layers.setLen(0)
    for L in d.layers:
      let n = newLayer(result, L.name)
      n.px = L.px
      n.opacity = L.opacity
      n.mode = L.mode
      n.visible = L.visible
      n.lockAlpha = L.lockAlpha
      n.background = L.background
      result.layers.add n
    result.cur = d.cur
    result.alphas = d.alphas
    result.paths = d.paths
  result.sel = d.sel
  result.info = d.info
  result.markAll()
  result.modified = true
  result.clearHistory()

proc copyToClip(d: Doc; merged: bool) =
  clip = d.copySelection(merged)
  hasClip = clip.w > 0 and clip.h > 0

proc paste(d: Doc; into: bool) =
  if not hasClip:
    status = "Nothing to paste"
    return
  let selBefore = d.sel
  d.change(if into: "Paste Into" else: "Paste"):
    let into2 = into and d.hasSelection
    let L = d.pasteAsLayer(clip, centered = into2, name = "")
    if into2:
      # what falls outside the selection is hidden
      for i in 0 ..< L.px.len:
        L.px[i] = withAlpha(L.px[i], aOf(L.px[i]) * int(selBefore[i]) div 255)
      inc L.ver
    d.selectNone()
    d.markAll()

proc definePattern(d: Doc) =
  let r = d.clip(d.selBounds)
  d.updateComposite()
  patternW = r.w
  patternH = r.h
  pattern = newSeq[uint32](r.w * r.h)
  for y in 0 ..< r.h:
    for x in 0 ..< r.w: pattern[y * r.w + x] = d.compPtr[(r.y + y) * d.w + r.x + x]
  status = "Pattern defined: " & $r.w & " x " & $r.h

proc revert(dw: DocWin) =
  let d = dw.doc
  if d.path.len == 0 or not fileExists(d.path): return
  try:
    let n = openPicture(d.path)
    dw.doc = n
    dw.fitWindow()
  except CatchableError:
    status = "Could not read " & d.path.extractFilename

proc nextZoom(dw: DocWin; inward: bool) =
  let d = dw.doc
  let v = dw.view
  let cx = v.view.x + v.view.w div 2
  let cy = v.view.y + v.view.h div 2
  let (ix, iy) = v.toImage(d, cx, cy)
  if inward: dw.view.zoomIn(d, ix, iy) else: dw.view.zoomOut(d, ix, iy)
  dw.afterZoom(ix, iy, false)

const pixelCommands = ["Cut", "Clear", "Fill...", "Stroke...", "Erase Image", "Invert", "Equalize",
                       "Threshold...", "Posterize...", "Levels...", "Curves...", "Brightness/Contrast...",
                       "Color Balance...", "Hue/Saturation...", "Replace Color...", "Auto Levels", "Auto Tone",
                       "Auto Contrast", "Auto Color", "Content-Aware Fill", "Shadows/Highlights...",
                       "Vibrance...", "Exposure...", "Photo Filter...", "Black & White...", "Channel Mixer...",
                       "Develop...", "Liquify...", "Lens Correction...", "Desaturate", "Variations...",
                       "Selective Color...", "Apply Image...", "Flip Layer Horizontal", "Flip Layer Vertical",
                       "Free", "Scale", "Skew", "Perspective", "Distort", "Last Filter", "Custom...",
                       "Texture Fill...", "Shear...", "Gradient Map...", "Color Lookup..."]
  ## (the commands that change the pixels of the current layer: type is
  ## rasterized first)

# ---- Duotone, Printing Inks Setup --------------------------------------------------------------------------

var
  duoOpen = false
  duoDoc: Doc
  duoKind = 1                    ## Monotone, Duotone, Tritone, Quadtone
  duoInks: seq[DuotoneInk]
  inksOpen = false
  inksGain = 20
  inksBlack = 2
  inksLimit = 300
  inksBlackLimit = 100

proc startDuotone(d: Doc) =
  duoDoc = d
  duoInks = if d.mode == cmDuotone and d.duotone.len > 0: d.duotone else: defaultDuotone(4)
  duoKind = if d.mode == cmDuotone: max(0, d.duotone.len - 1) else: 1
  while duoInks.len < 4: duoInks.add defaultDuotone(4)[duoInks.len]
  duoOpen = true

proc duotoneDialog() =
  if not duoOpen or duoDoc == nil: return
  dialog(duoOpen, "Duotone Options", 420):
    optCombo("Type:", ["Monotone", "Duotone", "Tritone", "Quadtone"], duoKind, dp(130))
    for i in 0 .. duoKind:
      group("Ink " & $(i + 1)):
        row:
          colorWell(duoInks[i].color, "duoink" & $i, dp(40))
          edit(duoInks[i].name, w = dp(150))
        var g = int(round(duoInks[i].gamma * 100))
        row([60, -1, 46]):
          label "Curve:"
          if slider(g, 20, 400): duoInks[i].gamma = g / 100
          label formatFloat(duoInks[i].gamma, ffDecimal, 2)
    label("How the grays print:", color = ui.theme.gray)
    let t = duotoneTable(duoInks[0 .. duoKind])
    let r = place(available(), dp(18))
    for x in 0 ..< r.w:
      let g = 255 - x * 255 div max(1, r.w - 1)
      vline(r.x + x, r.y, r.h, colorOf(t[g]))
    box(r, ui.theme.frame)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)):
        duoOpen = false
        let d = duoDoc
        let inks = duoInks[0 .. duoKind]
        if d.mode in {cmRGB, cmCMYK, cmLab}:
          d.snapStep("Duotone")
          d.toGrayscale()
          d.toDuotone(inks)
          d.endStep()
        else:
          d.change("Duotone"): d.toDuotone(inks)
      if button("Cancel", w = dp(80)): duoOpen = false

proc startInksSetup() =
  inksGain = inkSetup.dotGain
  inksBlack = ord(inkSetup.black)
  inksLimit = inkSetup.inkLimit
  inksBlackLimit = inkSetup.blackLimit
  inksOpen = true

proc inksDialog() =
  if not inksOpen: return
  dialog(inksOpen, "Printing Inks Setup", 400):
    label("Inks: SWOP (Coated)", bold = true)
    optSlider("Dot Gain:", inksGain, 0, 40)
    optCombo("Black Generation:", ["None", "Light", "Medium", "Heavy", "Maximum"], inksBlack, dp(110))
    optNumber("Total Ink Limit:", inksLimit, 200, 400, "%")
    optNumber("Black Ink Limit:", inksBlackLimit, 0, 100, "%")
    label("CMYK images, Proof Colors and the separations follow it.", color = ui.theme.gray)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)):
        inksOpen = false
        setInks(InkSetup(dotGain: inksGain, black: BlackGeneration(clamp(inksBlack, 0, 4)),
                         inkLimit: inksLimit, blackLimit: inksBlackLimit))
        for dw in docs: inc dw.doc.ver
      if button("Cancel", w = dp(80)): inksOpen = false

var
  colorSettingsOpen = false
  cmykProfilePick = false        ## Color Settings: Load CMYK Profile picking a file
  cmykProfilePath = ""

proc colorSettingsDialog() =
  ## Edit > Color Settings: the working spaces (the profile of new RGB
  ## images; the printing inks of CMYK), what is done with the profiles of
  ## pictures opened, and how colors are converted to inks.
  if filePicker(cmykProfilePick, cmykProfilePath, fmOpen, ["*.icc", "*.icm"], "Load CMYK Profile"):
    try:
      let data = readFile(cmykProfilePath)
      if useCmykProfile(data):
        createDir(cmykProfileFile().parentDir)
        writeFile(cmykProfileFile(), data)
        status = "CMYK: " & inkProfileName()
      else: status = cmykProfilePath.extractFilename & " is not a CMYK printing profile"
    except CatchableError:
      status = "Could not read " & cmykProfilePath.extractFilename & ": " & getCurrentExceptionMsg()
  if not colorSettingsOpen: return
  dialog(colorSettingsOpen, "Color Settings", 480):
    group("Working Spaces"):
      var names = @["sRGB (untagged)"]
      for n in builtInProfileNames: names.add n
      row:
        label "RGB:"
        combo(names, prefs.workingSpace, w = dp(220))
      let pname = inkProfileName()
      row:
        if pname.len > 0: label("CMYK: " & pname)
        else:
          label("CMYK: ink model, dot gain " & $inkSetup.dotGain & "%, ink limit " & $inkSetup.inkLimit & "%")
          if button("Inks...", w = dp(70)): startInksSetup()
      row:
        if button("Load CMYK Profile...", w = dp(150)):
          cmykProfilePath = ""
          cmykProfilePick = true
        if pname.len > 0 and button("Use the Ink Model", w = dp(130)):
          discard useCmykProfile("")
          try: removeFile(cmykProfileFile()) except OSError: discard
      label("A press's ICC profile (FOGRA39, GRACoL, SWOP...): CMYK, Proof Colors and PDF/X follow it.",
            color = ui.theme.gray)
      label("Gray: dot gain " & $inkSetup.dotGain & "% (the inks')", color = ui.theme.gray)
    group("Color Management Policies"):
      var pp = ord(profilePolicy)
      row:
        label "RGB pictures with a profile:"
        if combo(["Convert to Working RGB", "Preserve Embedded Profiles", "Off"], pp, w = dp(190)):
          profilePolicy = ProfilePolicy(pp)
      checkbox("Embed the profile in exported files", prefs.embedProfile)
    group("Conversion Options"):
      row:
        label "Intent:"
        if combo(["Perceptual", "Relative Colorimetric", "Saturation", "Absolute Colorimetric"], cmykIntent,
                 w = dp(170)) and inkProfile().len > 0:
          discard useCmykProfile(inkProfile())
        if checkbox("Black Point Compensation", cmykBpc) and inkProfile().len > 0:
          discard useCmykProfile(inkProfile())
      var bg = ord(inkSetup.black)
      row:
        label "Black Generation:"
        if combo(["None", "Light", "Medium", "Heavy", "Maximum"], bg, w = dp(110)):
          var s = inkSetup
          s.black = BlackGeneration(bg)
          setInks(s)
          for dw in docs: inc dw.doc.ver
      label("CMYK images, Proof Colors (Ctrl+Y), the Gamut Warning and the color picker's CMYK " &
            "follow these.", color = ui.theme.gray)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)):
        colorSettingsOpen = false
        savePrefs()
      if button("Cancel", w = dp(80)): colorSettingsOpen = false

proc doCommand(name: string) =
  ## Does what menu item `name` (without its "&") says.
  if xf.on: finishTransform(true)          # (another command: the transform is done)
  if wm.kind != wkNone and name notin ["OK", "Cancel"]: modeFinish(true)
  if te.on: commitType()                   # (and the text being typed)
  if psCommand(name): return               # (the modern menus' own: photo/pscc)
  if dailyCommand(name): return            # (everyday work: photo/daily)
  if assetsCommand(name): return           # (the Assets window: photo/assets)
  let dw = active
  let d = cur()
  if d != nil and (name in pixelCommands or filters.hasKey(name.strip(chars = {'.'}))) and
     not d.needPixels(name):
    return
  case name
  # ---- File
  of "New...": startNew()
  of "Open...", "Open As...": startOpen()
  of "Place...":
    if not noteNoImage():
      proc go() =
        if openPath.len == 0: openPath = picturesDir()
        placePick = true
      if askStorage(AppName, filesWhy, go): go()
  of "Close":
    if dw != nil: dw.win.open = false
  of "Save":
    if dw != nil: dw.save()
  of "Save As...":
    if dw != nil: dw.startSaveAs()
  of "Save a Copy...":
    if dw != nil: dw.startSaveAs(copy = true)
  of "Save as PDF...":
    if dw != nil: dw.startSavePdf()
  of "Export As...":
    if dw != nil: dw.startExport()
  of "Quick Export as PNG":
    if dw != nil: dw.quickExport(efPng)
  of "Quick Export as JPEG":
    if dw != nil: dw.quickExport(efJpeg)
  of "Layer from File...":
    if not noteNoImage(): startLayerFromFile()
  of "Create Clipping Mask":
    if d != nil and d.cur > 0 and not d.current.background:
      let L = d.current
      d.layersChange("Create Clipping Mask"): L.clipped = true
  of "Filter Factory...":
    if d != nil: startFilterFactory()
  of "Edit Plug-in...":
    if plugins.len > 0:
      # (the last one run, or the first)
      var f = plugins[0]
      for p in plugins:
        if lastFilter.set and p.name == lastFilter.name: f = p
      startFilterFactory(f)
  of "Toggle Clipping Mask":
    if d != nil: runCommand(if d.current.clipped: "Release Clipping Mask" else: "Create Clipping Mask")
  of "Release Clipping Mask":
    if d != nil and d.current.clipped:
      let L = d.current
      d.layersChange("Release Clipping Mask"): L.clipped = false
  of "Revert":
    if dw != nil: dw.revert()
  of "File Info...":
    if d != nil:
      fileInfo = d.info
      infoOpen = true
      typeFirst()
  of "Print...":
    if d != nil: printDoc(d)
  of "General...": startPrefs(ord(ppGeneral))
  of "Interface...": startPrefs(ord(ppInterface))
  of "Workspace...": startPrefs(ord(ppWorkspace))
  of "Tools...": startPrefs(ord(ppTools))
  of "History & Saving...": startPrefs(ord(ppFiles))
  of "Performance...": startPrefs(ord(ppPerformance))
  of "Scratch Disks...": startPrefs(ord(ppScratch))
  of "Cursors...": startPrefs(ord(ppCursors))
  of "Transparency & Gamut...": startPrefs(ord(ppTransparency))
  of "Units & Rulers...": startPrefs(ord(ppUnits))
  of "Guides, Grid & Slices...": startPrefs(ord(ppGuides))
  of "Type...": startPrefs(ord(ppType))
  of "Color Profiles...": startPrefs(ord(ppColor))
  of "Page Setup...": psOpen = true
  of "Texture Fill...":
    if d != nil:
      proc go() =
        if texturePath.len == 0: texturePath = picturesDir()
        texturePick = true
      if askStorage(AppName, filesWhy, go): go()
  of "Exit":
    if docs.len == 0 and not saving(): quitApp() else: quitConfirm = true
  # ---- Edit
  of "Undo":
    if d != nil and d.canUndo: d.undo()
    elif d != nil and d.canRedo: d.redo()
  of "Redo":
    if d != nil and d.canRedo: d.redo()
  of "Cut":
    if d != nil:
      d.copyToClip(false)
      d.paintStep("Cut"): d.clearSelection(bg)
  of "Copy":
    if d != nil: d.copyToClip(false)
  of "Copy Merged":
    if d != nil: d.copyToClip(true)
  of "Paste":
    if d != nil: d.paste(false)
    elif hasClip:
      addDoc(newUntitled(clip.w, clip.h, white))
      cur().paste(false)
  of "Paste Into":
    if d != nil: d.paste(true)
  of "Clear":
    if d != nil:
      d.paintStep("Clear"): d.clearSelection(bg)
  of "Fill...":
    if not noteNoImage(): fillOpen = true
  of "Stroke...":
    if d != nil and d.hasSelection: strokeOpen = true
  of "Crop":
    if d != nil and d.hasSelection:
      d.change("Crop"): d.crop(d.clip(d.selBounds))
      dw.fitWindow()
  of "Define Pattern":
    if d != nil: d.definePattern()
  of "Clipboard":
    clip = Clip()
    hasClip = false
  of "Undo History":
    if d != nil: d.clearHistory()
  of "Everything":
    # Purge > Everything: the histories, snapshots, clipboard and caches of every image
    let before = memoryUsed()
    for dw in docs:
      dw.doc.clearHistory()
      dw.doc.snapshots.setLen(0)
      dw.doc.purgeCaches()
      inc dw.doc.ver
    histSource = (false, 0)
    clip = Clip()
    hasClip = false
    navThumb = ("", nil)
    chanThumbs.clear()
    trimMemory()
    let after = memoryUsed()
    status = if before > 0 and after > 0: "Purged: " & sizeText(before) & " in use before, " & sizeText(after) & " now"
             else: "Purged"
  of "Take Snapshot", "New Snapshot":
    if d != nil:
      let k = d.takeSnapshot()
      histSource = (true, k)
      status = d.snapshots[k].name & " taken: the History Brush paints it back (History palette)"
  of "Snapshot":
    if d != nil:
      d.snapshots.setLen(0)
      histSource = (false, 0)
  of "New Document from State":
    if d != nil:
      let nd = d.duplicateDoc(d.name & " copy", false)
      addDoc(nd)
  of "History":
    togglePanel("history")
  of "Navigator":
    togglePanel("navigator")
  of "Actions":
    togglePanel("actions")
  of "Properties":
    togglePanel("properties")
  of "Brush Settings":
    palettesHidden = false
    togglePanel("brushsettings")
  of "Select and Mask...":
    startSelectAndMask()
  of "Show Guides", "Hide Guides":
    if dw != nil: dw.view.showGuides = not dw.view.showGuides
  of "Show Grid", "Hide Grid":
    if dw != nil:
      dw.view.showGrid = not dw.view.showGrid
      for o in docs: o.view.showGrid = dw.view.showGrid
  of "Snap":
    snapOn = not snapOn
  of "Guides":
    snapGuides = not snapGuides
  of "Grid":
    snapGrid = not snapGrid
  of "Document Bounds":
    snapBounds = not snapBounds
  of "Smart Guides":
    smartGuidesOn = not smartGuidesOn
    savePrefs()
  of "Lock Guides":
    for o in docs: o.view.lockGuides = not o.view.lockGuides
  of "Clear Guides":
    if d != nil: d.clearGuides()
  of "New Guide...":
    if d != nil:
      ngOpen = true
      typeFirst()
  of "Grid Settings...":
    gsOpen = true
  of "Layer via Copy", "Layer via Cut":
    if d != nil:
      let L = d.current
      if L.group or not d.hasSelection:
        d.layersChange("Duplicate Layer"): discard d.duplicateLayer()
      elif d.needPixels(name):
        let c = d.copySelection()
        d.layersChange(name):
          if name == "Layer via Cut":
            d.touch(L, d.bounds)
            d.clearSelection(if L.background: bg else: 0'u32)
          discard d.pasteAsLayer(c, name = "")
  of "Step Backward": runCommand("Undo")
  of "Step Forward": runCommand("Redo")
  of "Erase Image":
    if d != nil:
      d.change("Erase Image"):
        let L = d.layer
        let c = if L.background: bg or 0xFF000000'u32 else: 0'u32
        for p in L.px.mitems: p = c
        inc L.ver
        d.markAll()
  # ---- Mode
  of "Bitmap...":
    if d != nil:
      if d.mode != cmGray: status = "Change the image to Grayscale first"
      else: bitmapOpen = true
  of "8 Bits/Channel":
    if d != nil and d.depth == 32: toningDlg = (true, 8, 1, 0.0, 1.0, 30.0)
    elif d != nil and d.depth == 16:
      d.setDepth(8)
      d.modified = true
      status = "8 bits a channel"
  of "16 Bits/Channel":
    if d != nil and d.depth == 32: toningDlg = (true, 16, 1, 0.0, 1.0, 30.0)
    elif d != nil and d.depth != 16:
      d.setDepth(16)
      d.modified = true
      status = "16 bits a channel: kept and saved at 16 (PSD, PNG); edits are made at 8"
  of "32 Bits/Channel":
    if d != nil and d.depth != 32 and d.mode in {cmRGB, cmGray}:
      d.beginStep("32 Bits/Channel")
      d.touchLayers()
      d.toHdr()
      d.endStep()
      d.modified = true
      status = "32 bits a channel: the light kept as it is (save as .rpd, .hdr, .pfm); " &
               "View > 32-bit Preview Options shows it brighter or darker"
  of "32-bit Preview Options...":
    if d != nil and d.depth == 32: previewDlg = (true, d.exposure, (if d.viewGamma <= 0: 1.0 else: d.viewGamma))
  of "HDR Toning...":
    if d != nil and d.depth == 32: toningDlg = (true, 16, 1, 0.0, 1.0, 30.0)
  of "Grayscale":
    if d != nil and d.mode != cmGray:
      d.change("Grayscale"): d.toGrayscale()
  of "Indexed Color...":
    if d != nil and d.mode in {cmRGB, cmGray}: indexedOpen = true
  of "RGB Color":
    if d != nil and d.mode != cmRGB:
      d.change("RGB Color"): d.toRGB()
  of "CMYK Color":
    if d != nil and d.mode != cmCMYK:
      if d.mode in {cmIndexed, cmBitmap}: d.change("RGB Color"): d.toRGB()
      d.change("CMYK Color"): d.toCMYK()
  of "Lab Color":
    if d != nil and d.mode != cmLab:
      if d.mode in {cmIndexed, cmBitmap}: d.change("RGB Color"): d.toRGB()
      d.change("Lab Color"): d.toLab()
  of "Duotone...":
    if d != nil and d.mode in {cmGray, cmDuotone, cmRGB, cmCMYK, cmLab}: startDuotone(d)
  of "Printing Inks Setup...": startInksSetup()
  of "CMYK Preview":
    if d != nil and d.mode != cmCMYK:
      d.proof = not d.proof
      inc d.ver
  of "Gamut Warning":
    if d != nil:
      d.gamutWarning = not d.gamutWarning
      inc d.ver
  of "Color Table...":
    if d != nil and d.mode == cmIndexed: tableOpen = true
  # ---- Image
  of "Invert":
    if d != nil:
      d.paintStep("Invert"): d.applyFilter(0, invert())
  of "Equalize":
    if d != nil:
      let h = d.histogram(merged = false)
      d.paintStep("Equalize"): d.applyFilter(0, equalize(h))
  of "Threshold...": startAdjust(akThreshold)
  of "Posterize...": startAdjust(akPosterize)
  of "Levels...": startAdjust(akLevels)
  of "Curves...": startAdjust(akCurves)
  of "Brightness/Contrast...": startAdjust(akBC)
  of "Color Balance...": startAdjust(akBalance)
  of "Hue/Saturation...": startAdjust(akHS)
  of "Replace Color...": startAdjust(akReplace)
  of "Auto Levels", "Auto Tone", "Auto Contrast", "Auto Color":
    if d != nil:
      let step = if name == "Auto Levels": "Auto Tone" else: name
      let a = case step
              of "Auto Contrast": autoContrast(d.histogram(merged = false))
              of "Auto Color": autoColor(d.filterImg(d.layer, 0, proc (src: Img; inner: Rect): Img = src, d.workRect))
              else: autoTone(d.histogram(merged = false))
      d.paintStep(step):
        d.applyFilter(0, applyLuts(identityLut(), levelsLut(a[0]), levelsLut(a[1]), levelsLut(a[2])))
  of "Content-Aware Fill":
    if d != nil and d.hasSelection:
      status = "Filling..."
      d.paintStep("Content-Aware Fill"): d.contentAwareFill(int(epochTime() * 1000) mod 9973 + 1)
      status = ""
  of "Remove Background":
    # the usual Quick Action: the subject kept, what is behind it hidden by
    # a layer mask (its hair followed); the Background becomes a layer first
    if d != nil and d.needPixels(name):
      beginBusy("Remove Background")
      try:
        let m = d.removeBackground()
        var any = false
        for v in m:
          if v >= 128:
            any = true
            break
        if not any:
          status = "No subject found"
        else:
          d.layersChange("Remove Background"):
            if d.current.background: d.layerFromBackground(d.cur)
            let L = d.current
            if L.mask == nil: d.addLayerMask(mfRevealAll)
            if L.mask != nil:
              d.touch(L.mask, d.bounds)
              for i in 0 ..< m.len: L.mask.px[i] = grayPx(int(m[i]))
              inc L.mask.ver
            d.editMask = false
            d.markAll()
          status = "Background removed: a layer mask (paint it with black and white to change it)"
      finally: endBusy()
  of "Subject", "Sky":
    if d != nil:
      let m = if name == "Sky": d.selectSky() else: d.selectSubject()
      var any = false
      for v in m:
        if v >= 128:
          any = true
          break
      if not any:
        status = if name == "Sky": "No sky found" else: "No subject found"
      else:
        d.beginStep("Select " & name)
        d.touchSel()
        d.setSelection(m, soReplace)
        d.endStep()
  of "Shadows/Highlights...": startAdjust(akShadows)
  of "Vibrance...": startAdjust(akVibrance)
  of "Exposure...": startAdjust(akExposure)
  of "Photo Filter...": startAdjust(akPhotoFilter)
  of "Black & White...": startAdjust(akBlackWhite)
  of "Channel Mixer...": startAdjust(akMixer)
  of "Gradient Map...": startAdjust(akGradMap)
  of "Color Lookup...": startAdjust(akLookup)
  of "Solid Color...": startFillLayer(spColor)
  of "Gradient...": startFillLayer(spGradient)
  of "Pattern...": startFillLayer(spPattern)
  of "Develop...": startDevelop()
  of "Liquify...": startLiquify()
  of "Lens Correction...": startLensCorrection()
  of "Desaturate":
    if d != nil:
      d.paintStep("Desaturate"): d.applyFilter(0, desaturate())
  of "Variations...": startVariations()
  of "Selective Color...": startAdjust(akSelective)
  of "Apply Image...": startApplyImage()
  of "Calculations...": startCalculations()
  of "Shear...": startShear()
  of "Paste Layer...":
    if d != nil and hasClip:
      plName = "Layer " & $(d.layers.len)
      plOpacity = 100
      plMode = 0
      plOpen = true
      typeFirst()
  of "Pattern":
    pattern = @[]
    patternW = 0
    patternH = 0
  of "Duplicate...":
    if d != nil:
      dupName = d.name & " copy"
      dupMerged = false
      dupOpen = true
      typeFirst()
  of "Horizontal", "Vertical":
    if d != nil:
      d.change("Flip"): d.flipImage(name == "Horizontal")
  of "Flip Layer Horizontal", "Flip Layer Vertical":
    if d != nil and d.current.isSmart and not d.hasSelection:
      # (a Smart Object: its corners swapped, nothing lost)
      let L = d.current
      let q = L.smart.quad
      let nq: Quad = if name.endsWith("Horizontal"): [q[1], q[0], q[3], q[2]] else: [q[3], q[2], q[1], q[0]]
      d.layersChange("Flip"):
        L.smart = L.smart.withQuad(nq)
        d.renderSmartLayer(L)
    elif d != nil:
      d.paintStep("Flip"): d.flipSelection(name.endsWith("Horizontal"))
  of "180°", "90° CW", "90° CCW":
    if d != nil:
      d.change("Rotate Canvas"): d.rotateImage(case name
                                               of "180°": 2
                                               of "90° CW": 1
                                               else: 3)
      dw.fitWindow()
  of "Arbitrary...":
    if not noteNoImage(): rotOpen = true
  of "Free": startTransform(xkRotate)
  of "Scale": startTransform(xkScale)
  of "Skew": startTransform(xkSkew)
  of "Perspective": startTransform(xkPerspective)
  of "Distort": startTransform(xkDistort)
  of "Image Size...": startImageSize()
  of "Trim":
    if d != nil:
      let r = d.trimRect()
      if r.w < d.w or r.h < d.h:
        d.change("Trim"): d.crop(r)
        dw.fitWindow()
      else: status = "Nothing to trim"
  of "Convert to Smart Object", "Rasterize Smart Object", "New Smart Object via Copy", "Edit Contents",
     "Replace Contents...", "Export Contents...":
    if d != nil: discard d.smartCommand(name)
  of "Warp": startWarpMode(wkWarp)
  of "Puppet Warp": startWarpMode(wkPuppet)
  of "Perspective Warp...": startWarpMode(wkPersp)
  of "Field Blur...": startBlurGallery(0)
  of "Iris Blur...": startBlurGallery(1)
  of "Tilt-Shift...": startBlurGallery(2)
  of "Assign Profile...": startProfile(false)
  of "Convert to Profile...": startProfile(true)
  of "Photomerge...": startMerge(mkPanorama)
  of "Merge to HDR Pro...": startMerge(mkHdr)
  of "Load Files into Stack...": startMerge(mkStack)
  of "Auto-Align Layers...":
    if d != nil: aaOpen = true
  of "Auto-Blend Layers...":
    if d != nil: abOpen = true
  of "Sky Replacement...":
    if d != nil: startSky()
  of "Batch...":
    if not actionsLoaded: loadActions()
    batchAction = clamp(actSel, 0, max(0, actions.high))
    batchOpen = true
  of "Fit Image...":
    if d != nil:
      fitW = d.w
      fitH = d.h
      fitOpen = true
      typeFirst()
  of "Content-Aware Scale...":
    if d != nil:
      caW = 100
      caH = 100
      caSel = d.hasSelection
      caOpen = true
  of "Canvas Size...":
    if d != nil:
      csW = d.w
      csH = d.h
      csAx = 1
      csAy = 1
      csOpen = true
  of "Histogram...":
    if d != nil:
      histData = d.histogram()
      histOpen = true
  # ---- Filter
  of "Last Filter":
    if lastFilter.set: runFilter(lastFilter.name, lastFilter.vals)
  of "Custom...":
    if not noteNoImage():
      if customK == default(array[25, int]): customK[12] = 1
      customOpen = true
  # ---- Select
  of "All":
    if d != nil:
      d.paintStep("Select All"):
        d.touchSel()
        d.selectAll()
  of "None":
    if d != nil and d.hasSelection:
      reselect = (d, d.sel)
      d.paintStep("Select None"):
        d.touchSel()
        d.selectNone()
  of "Reselect":
    if d != nil and reselect.d == d and reselect.sel.len == d.w * d.h:
      d.paintStep("Reselect"):
        d.touchSel()
        d.setSelection(reselect.sel, soReplace)
  of "Select Layer Above", "Select Layer Below":
    if d != nil and d.layers.len > 1:
      if te.on: commitType()
      d.clearPicks()
      d.cur = clamp(d.cur + (if name == "Select Layer Above": 1 else: -1), 0, d.layers.high)
      d.editMask = false
      inc d.ver
      status = "Layer: " & d.current.name
  of "Reveal All", "Hide All", "Reveal Selection", "Hide Selection":
    if d != nil and not d.current.background and d.current.mask == nil:
      let how = case name
                of "Reveal All": mfRevealAll
                of "Hide All": mfHideAll
                of "Reveal Selection": mfRevealSelection
                else: mfHideSelection
      d.layersChange("Add Layer Mask"):
        d.addLayerMask(how)
        d.editMask = true
  of "Gradient Mask":
    # a mask (revealing all) to paint a gradient on: the Gradient tool, black
    # to white -- a drag across the picture fades the layer out there
    if d != nil and not d.current.background:
      if d.current.mask == nil:
        d.layersChange("Add Layer Mask"): d.addLayerMask(mfRevealAll)
      d.editMask = true
      inc d.ver
      fg = 0xFF000000'u32
      bg = 0xFFFFFFFF'u32
      gradPreset = 0
      selectTool(tGradient)
      status = "Drag across the picture: the layer fades out where the black is (on its mask)"
  of "Place Into...":
    # a picture into the current layer (type, a shape, a frame): clipped
    # to it, as big as it needs to cover it
    if d != nil and not d.current.background:
      placeInto = true
      runCommand("Place...")
  of "New Frame":
    # the usual Frame tool: a box (the selection's, else the middle of the
    # image; an ellipse with the elliptical marquee) to place a picture into
    if d != nil:
      let r = if d.hasSelection: d.clip(d.selBounds)
              else: rect(d.w div 4, d.h div 4, max(1, d.w div 2), max(1, d.h div 2))
      let ell = d.hasSelection and marqueeShape == 1
      var sd = ShapeData(fill: solidPaint(0xFFC8C8C8'u32), stroke: solidPaint(0xFF808080'u32), strokeWidth: 1,
                         kind: if ell: "Ellipse" else: "Rectangle")
      sd.path = if ell: ellipsePath(r.x.float, r.y.float, (r.x + r.w).float, (r.y + r.h).float)
                else: rectPath(r.x.float, r.y.float, (r.x + r.w).float, (r.y + r.h).float)
      var n = 1
      for L in d.layers:
        if L.name.startsWith("Frame "): inc n
      d.layersChange("New Frame"):
        discard d.addShapeLayer(sd, "Frame " & $n)
        if d.hasSelection:
          d.touchSel()
          d.selectNone()
      status = "A frame: Layer > Place Into... puts a picture inside it"
  of "Stamp Visible":
    if d != nil and d.needPixels(name):
      let px = d.flattened()
      d.layersChange("Stamp Visible"):
        let L = d.addLayer("", above = d.layers.high)
        if L.px.len == px.len: L.px = px
        inc L.ver
        d.markAll()
  of "Fill with Foreground Color", "Fill with Background Color":
    if d != nil and d.needPixels(name):
      d.paintStep("Fill"):
        d.fillSelection(if name == "Fill with Foreground Color": fg else: bg)
  of "Inverse":
    if d != nil:
      d.paintStep("Inverse"):
        d.touchSel()
        d.invertSelection()
  of "Color Range...":
    if d != nil:
      crSample = fg
      crKey = ""
      crOpen = true
  of "Feather...":
    if d != nil and d.hasSelection: askNumber("Feather", "Feather Radius:", 2, 250)
  of "Border...":
    if d != nil and d.hasSelection: askNumber("Border", "Width:", 8, 64)
  of "Smooth...":
    if d != nil and d.hasSelection: askNumber("Smooth", "Sample Radius:", 2, 16)
  of "Expand...":
    if d != nil and d.hasSelection: askNumber("Expand", "Expand By:", 1, 16)
  of "Contract...":
    if d != nil and d.hasSelection: askNumber("Contract", "Contract By:", 1, 16)
  of "Grow":
    if d != nil and d.hasSelection:
      d.paintStep("Grow"):
        d.touchSel()
        d.growSelection(wandTol)
  of "Similar":
    if d != nil and d.hasSelection:
      d.paintStep("Similar"):
        d.touchSel()
        d.growSelection(wandTol, similar = true)
  of "Hide Edges":
    if dw != nil: dw.view.hideEdges = not dw.view.hideEdges
  of "Load Selection":
    if d != nil and d.alphas.len > 0:
      d.paintStep("Load Selection"):
        d.touchSel()
        d.loadSelection(d.alphas.high)
  of "Save Selection":
    if d != nil and d.hasSelection:
      d.change("Save Selection"): discard d.saveSelection()
  of "Make Work Path":
    if d != nil and d.hasSelection:
      d.change("Make Path"):
        d.paths.add d.pathFromSelection()
        d.curPath = d.paths.high
  # ---- Window
  of "Color Settings...":
    colorSettingsOpen = true
  of "Keyboard Shortcuts...":
    keysWas = keymap
    keysOpen = true
  of "Toolbar...":
    editToolbarOpen = true
  of "Cascade": mdiCascade("ws")
  of "Tile": mdiTile("ws")
  of "Always on Top":
    # (a floating window kept over the others: a reference beside the work)
    if active != nil and not prefs.docTabs and active.floating and not active.win.maximized:
      active.win.pinned = not active.win.pinned
  of "Tabbed Documents", "Consolidate All to Tabs": setDocMode(true)
  of "Floating Windows (MDI)", "Float All in Windows", "Float in Window": setDocMode(false)
  of "Match Zoom":
    if dw != nil:
      for o in docs:
        if o != dw: o.view.setZoom(o.doc, dw.view.zoom)
  of "Match Location":
    if dw != nil:
      let (cx, cy) = dw.view.toImage(d, dw.view.view.x + dw.view.view.w div 2, dw.view.view.y + dw.view.view.h div 2)
      for o in docs:
        if o != dw: o.view.centerOn(o.doc, cx * o.doc.w.float / max(1, d.w).float, cy * o.doc.h.float / max(1, d.h).float)
  of "Next Document", "Previous Document":
    if dw != nil and docs.len > 1:
      let i = docs.find(dw)
      let k = if name == "Next Document": (i + 1) mod docs.len else: (i + docs.len - 1) mod docs.len
      docs[k].showDoc()
  of "Close All":
    for w in docs: w.win.open = false
  of "New Window":
    if dw != nil:
      let n = DocWin(doc: d, win: MdiWindow(title: d.name, open: true, flush: true, grip: true), floating: not prefs.docTabs)
      docs.add n
      n.placeWindow()
      n.showDoc()
  of "Zoom In":
    if dw != nil: dw.nextZoom(true)
  of "Zoom Out":
    if dw != nil: dw.nextZoom(false)
  of "Fit on Screen":
    if dw != nil: dw.view.fit(d)
  of "Actual Pixels":
    if dw != nil: dw.view.setZoom(d, 1)
  of "Show Rulers", "Hide Rulers":
    if dw != nil: dw.view.rulers = not dw.view.rulers
  of "Brushes": togglePanel("brushes")
  of "Options": togglePanel("options")
  of "Picker": togglePanel("color")
  of "Swatches": togglePanel("swatches")
  of "Scratch": togglePanel("scratch")
  of "Layers": togglePanel("layers")
  of "Channels": togglePanel("channels")
  of "Paths": togglePanel("paths")
  of "Info":
    togglePanel("info")
  of "Commands": togglePanel("commands")
  of "Tools":
    toolbox.open = true             # (the toolbar is not closed: brought back if it was)
    palettesHidden = false
  of "Hide Palettes", "Show Palettes": palettesHidden = not palettesHidden
  of "Options Bar": optionsBarOn = not optionsBarOn
  of "Reset Palettes", "Reset Workspace":
    palettesPlaced = false
    defaultDock()
  of "Save Workspace":
    saveWorkspace("saved")
    status = "The workspace is kept (Window > Workspace > Load Saved Workspace)"
  of "Load Saved Workspace":
    if not loadWorkspace("saved"): status = "No workspace kept for a window this size"
  # ---- Help
  of "About Retro Photo...": aboutOpen = true
  of "Contents": helpOpen = true
  # ---- the Commands palette
  of "Flatten Image":
    if d != nil and d.layers.len > 1:
      d.change("Flatten Image"): d.flatten(bg)
  of "Merge Down", "Merge Group":
    if d != nil and canMergeDown(d):
      if d.current.group:
        d.layersChange("Merge Group"): d.mergeGroup()
      else:
        d.layersChange("Merge Down"):
          d.touch(d.layers[d.cur - 1], d.bounds)
          d.mergeDown()
  of "Merge Layers":
    # (the layers picked made one: grouped, the group merged)
    if d != nil and d.pickedLayers.len > 1:
      d.layersChange("Merge Layers"):
        let g = d.groupLayers(d.pickedLayers)
        if g != nil:
          d.cur = d.layers.find(g)
          d.mergeGroup()
        else: status = "The Background cannot be merged that way: Merge Down, or Flatten Image."
  of "New Group...":
    if d != nil:
      d.layersChange("New Group"): discard d.addGroup()
  of "Group Layers":
    if d != nil:
      d.layersChange("Group Layers"):
        if d.groupLayers(d.pickedLayers) == nil: status = "The Background cannot be in a group."
  of "Ungroup Layers":
    if d != nil and d.current.group:
      d.layersChange("Ungroup Layers"): d.ungroup()
  of "Layer Options...", "Group Properties...":
    if d != nil:
      let l = d.current
      layerOptsName = l.name
      layerOptsOpacity = l.opacity
      layerOptsMode = if l.group: (if l.passThrough: 0 else: 1 + max(0, LayerModes.find(l.mode)))
                      else: max(0, LayerModes.find(l.mode))
      layerOptsOpen = true
      typeFirst()
  of "Bring to Front", "Bring Forward", "Send Backward", "Send to Back":
    if d != nil:
      var how = arFront
      for a in Arrange:
        if $a == name: how = a
      d.layersChange(name):
        if not d.arrange(how): status = "It cannot go further."
  of "Blending Options...":
    if d != nil: startLayerStyle(-1)
  of "Lock Layer", "Unlock Layer":
    if d != nil and not d.current.background:
      d.layersChange(name): d.current.locked = not d.current.locked
  of "Merge Visible":
    if d != nil and d.layers.len > 1:
      d.layersChange("Merge Visible"):
        for l in d.layers:
          if l.visible:
            d.touch(l, d.bounds)
            break
        d.mergeVisible()
  of "Rasterize Layer Style":
    if d != nil and d.current.hasStyle:
      let L = d.current
      d.layersChange("Rasterize Layer Style"):
        d.touch(L, d.bounds)
        var px = newSeq[uint32](d.w * d.h)
        let tmp = Layer(px: L.px, opacity: 100, mode: bmNormal, visible: true, fx: L.fx, mask: L.mask,
                        maskOff: L.maskOff)
        tmp.fill = L.fill
        d.compositeInto(px, d.bounds, @[tmp])
        L.px = px
        L.fx = LayerFx()
        L.fill = 100
        d.rasterizeText(L)
        d.markAll()
  of "New Layer...":
    if d != nil:
      newLayerName = ""
      newLayerOpen = true
      typeFirst()
  of "Duplicate Layer", "Duplicate Group":
    if d != nil:
      d.layersChange(name): discard d.duplicateLayer()
  of "Delete Layer", "Delete Group":
    if d != nil and d.layers.len > 1:
      d.layersChange(name): d.deleteLayer()
  of "Character": showTypePal(0)
  of "Paragraph": showTypePal(1)
  of "Select All": runCommand("All")
  else:
    if filters.hasKey(name.strip(chars = {'.'})):
      startFilter(name.strip(chars = {'.'}))

proc runCommand(name: string) =
  ## Does what menu item `name` says, named in the box that comes up when
  ## it takes a while.
  beginBusy(name.strip(chars = {'.'}))
  try: doCommand(name)
  finally: endBusy()
  recordCommand(name)

proc plain(label: string): string =
  ## A menu label without its mnemonic marks ("&&" is a "&").
  label.replace("&&", "\0").replace("&", "").replace("\0", "&")

proc item(label: string; shortcut = ""; enabled = true; checked = false) =
  let k = keymap.keyFor(plain(label))
  if menuItem(label, if k.len > 0: k elif plain(label) in mappedCmds: "" else: shortcut, checked, enabled):
    runCommand(plain(label))

proc filterItems(names: openArray[string]) =
  let d = cur()
  for n in names:
    let bare = plain(n).strip(chars = {'.'})
    item(n, enabled = d != nil and filters.hasKey(bare) and d.mode in editModes)

var settingsCache: tuple[at: int; st: Settings] = (-1, Settings())

proc loadSettingsCached(): Settings =
  ## The settings file, read again at most once a second (the menus show
  ## the recent files from it).
  if settingsCache.at < 0 or ui.now - settingsCache.at > 1000:
    settingsCache = (ui.now, loadSettings(AppName))
  settingsCache.st

proc classicMenus()

proc menus() =
  ## The menu bar: the modern (photo/pscc), or with the 1994 keys
  ## 1994's.
  if prefs.keySet == 0: psMenus() else: classicMenus()

proc classicMenus() =
  let d = cur()
  let dw = active
  let some = d != nil
  let sel = some and d.hasSelection
  let rgb = some and d.mode in colorModes
  let edits = some and d.mode in editModes
  menubar:
    menu "&File":
      item("&New...", "Ctrl+N")
      item("&Open...", "Ctrl+O")
      let recent = recentFiles(loadSettingsCached())
      submenu "Open &Recent":
        for i, f in recent:
          if i >= max(1, prefs.recent): break
          if menuItem("&" & $((i + 1) mod 10) & " " & f.extractFilename.replace("&", "&&")):
            openFile(f)
        if recent.len == 0: discard menuItem("(none)", enabled = false)
        menuSeparator()
        if menuItem("Clear Recent File List", enabled = recent.len > 0):
          var st = loadSettings(AppName)
          st.addRecentFile("", 0)
          discard saveSettings(AppName, st)
          settingsCache.at = -1
      item("Open &As...")
      item("&Place...", enabled = some)
      menuSeparator()
      item("&Close", "Ctrl+W", some)
      item("&Save", "Ctrl+S", some)
      item("Save As...", enabled = some)
      item("Save a Cop&y...", enabled = some)
      item("Save as P&DF...", enabled = some)
      item("Re&vert", enabled = some and d.path.len > 0 and d.modified)
      menuSeparator()
      submenu "Ac&quire":
        item("Anti-aliased PICT...", enabled = false)
        item("Quick Edit...", enabled = false)
        item("Select TWAIN Source...", enabled = false)
        item("TWAIN Acquire...", enabled = false)
      submenu "Au&tomate":
        item("&Batch...")
        item("&Fit Image...", enabled = some)
        menuSeparator()
        item("&Photomerge...")
        item("Merge to &HDR Pro...")
        item("&Load Files into Stack...")
      submenu "&Export":
        item("&Export As...", "Ctrl+Alt+Shift+W", some)
        item("Quick Export as &PNG", enabled = some)
        item("Quick Export as &JPEG", enabled = some)
        menuSeparator()
        item("Paths to Illustrator...", enabled = false)
        item("TWAIN Export...", enabled = false)
      menuSeparator()
      item("File &Info...", enabled = some)
      menuSeparator()
      item("Page Set&up...")
      item("&Print...", "Ctrl+P", some)
      menuSeparator()
      submenu "Pre&ferences":
        item("&General...", "Ctrl+K")
        item("&Interface...")
        item("&Workspace...")
        item("&Tools...")
        item("&History && Saving...")
        item("&Performance...")
        item("&Scratch Disks...")
        item("&Cursors...")
        item("T&ransparency && Gamut...")
        item("&Units && Rulers...")
        item("Guides, Gri&d && Slices...")
        item("T&ype...")
        item("Color &Profiles...")
        menuSeparator()
        item("Printing Inks Setup...")
      menuSeparator()
      item("E&xit", "Ctrl+Q")
    menu "&Edit":
      let un = some and d.canUndo
      let re = some and d.canRedo
      if re and not un:
        if menuItem("&Redo " & d.redoName, "Ctrl+Z"): runCommand("Redo")
      else:
        if menuItem("&Undo" & (if un: " " & d.undoName else: ""), "Ctrl+Z", enabled = un): runCommand("Undo")
        if re:
          if menuItem("Redo " & d.redoName, "Ctrl+Shift+Z"): runCommand("Redo")
      menuSeparator()
      item("Cu&t", "Ctrl+X", sel)
      item("&Copy", "Ctrl+C", some)
      item("Copy &Merged", enabled = some and d.layers.len > 1)
      item("&Paste", "Ctrl+V", some or hasClip)
      item("Paste &Into", enabled = sel and hasClip)
      item("Paste &Layer...", enabled = some and hasClip)
      item("Cl&ear", "Del", some)
      menuSeparator()
      item("&Fill...", "Shift+Backspace", some)
      item("Content-A&ware Fill", enabled = sel and d.mode in editModes)
      item("&Stroke...", enabled = sel)
      item("Crop", enabled = sel)
      item("Content-Aware Scale...", enabled = some and d.mode in editModes)
      item("Sk&y Replacement...", enabled = some and d.mode in colorModes)
      menuSeparator()
      item("Assign Profile...", enabled = some and d.mode in {cmRGB, cmIndexed})
      item("Convert to Profile...", enabled = some and d.mode in {cmRGB, cmIndexed})
      item("Auto-Align Layers...", enabled = some and d.layers.len > 1)
      item("Auto-Blend Layers...", enabled = some and d.layers.len > 1)
      menuSeparator()
      item("Define &Pattern", enabled = some and sel)
      presetItems()
      item("Color Se&ttings...", "Ctrl+Shift+K")
      item("&Keyboard Shortcuts...")
      item("Tool&bar...")
      item("Take Snapshot", enabled = some)
      submenu "P&urge":
        item("Undo History", enabled = some)
        item("Clipboard", enabled = hasClip)
        item("Snapshot", enabled = some and d.snapshots.len > 0)
        item("Pattern", enabled = pattern.len > 0)
        menuSeparator()
        item("Everything", enabled = some or hasClip)
    menu "&Mode":
      item("&Bitmap...", enabled = some and d.layers.len == 1 and d.mode == cmGray, checked = some and d.mode == cmBitmap)
      item("&Grayscale", enabled = some and d.mode != cmGray, checked = some and d.mode == cmGray)
      item("&Duotone...", enabled = some and d.mode in {cmGray, cmDuotone, cmRGB, cmCMYK, cmLab},
           checked = some and d.mode == cmDuotone)
      item("&Indexed Color...", enabled = some and d.mode in {cmRGB, cmGray},
           checked = some and d.mode == cmIndexed)
      item("&RGB Color", enabled = some and d.mode != cmRGB, checked = some and d.mode == cmRGB)
      item("&CMYK Color", enabled = some and d.mode != cmCMYK, checked = some and d.mode == cmCMYK)
      item("&Lab Color", enabled = some and d.mode != cmLab, checked = some and d.mode == cmLab)
      item("&Multichannel", enabled = false)
      menuSeparator()
      item("&8 Bits/Channel", enabled = some, checked = some and d.depth notin [16, 32])
      item("1&6 Bits/Channel", enabled = some and d.mode in {cmRGB, cmGray}, checked = some and d.depth == 16)
      item("&32 Bits/Channel", enabled = some and d.mode in {cmRGB, cmGray}, checked = some and d.depth == 32)
      menuSeparator()
      item("Color &Table...", enabled = some and d.mode == cmIndexed)
      item("&Printing Inks Setup...")
      menuSeparator()
      item("CMYK Pre&view", "Ctrl+Alt+Y", some and d.mode in {cmRGB, cmLab}, checked = some and d.proof)
      item("Gamut &Warning", "Ctrl+Shift+Y", some and d.mode in colorModes, checked = some and d.gamutWarning)
    menu "&Image":
      submenu "&Map":
        item("&Invert", "Ctrl+I", edits)
        item("&Equalize", enabled = edits)
        item("&Threshold...", "Ctrl+T", edits)
        item("&Posterize...", enabled = edits)
      submenu "&Adjust":
        item("&Levels...", "Ctrl+L", edits)
        item("&Curves...", "Ctrl+M", edits)
        item("&Brightness/Contrast...", "Ctrl+B", edits)
        item("Color &Balance...", "Ctrl+Y", rgb)
        item("&Hue/Saturation...", "Ctrl+U", rgb)
        item("&Replace Color...", enabled = rgb)
        item("&Selective Color...", enabled = rgb)
        menuSeparator()
        item("E&xposure...", enabled = edits)
        item("V&ibrance...", enabled = rgb)
        item("Shadows/Hi&ghlights...", enabled = edits)
        item("&Photo Filter...", enabled = rgb)
        item("Blac&k && White...", "Ctrl+Alt+Shift+B", rgb)
        item("Channel &Mixer...", enabled = rgb)
        item("Gradient &Map...", enabled = rgb)
        item("Color Loo&kup...", enabled = rgb)
        menuSeparator()
        item("Auto &Tone", "Ctrl+Shift+L", edits)
        item("Auto C&ontrast", "Ctrl+Alt+Shift+L", edits)
        item("Auto Co&lor", "Ctrl+Shift+B", rgb)
        item("&Desaturate", "Ctrl+Shift+U", rgb)
        item("&Variations...", enabled = rgb)
      menuSeparator()
      item("&Duplicate...", enabled = some)
      item("Appl&y Image...", enabled = edits)
      item("&Calculations...", enabled = edits)
      menuSeparator()
      submenu "&Flip":
        item("&Horizontal", enabled = some)
        item("&Vertical", enabled = some)
        menuSeparator()
        item("Flip Layer Horizontal", enabled = some)
        item("Flip Layer Vertical", enabled = some)
      submenu "&Rotate":
        item("&180°", enabled = some)
        item("90° C&W", enabled = some)
        item("90° CC&W", enabled = some)
        item("&Arbitrary...", enabled = some)
        menuSeparator()
        item("&Free", enabled = some)
      submenu "&Effects":
        item("&Scale", enabled = some)
        item("S&kew", enabled = some)
        item("&Perspective", enabled = some)
        item("&Distort", enabled = some)
        item("&Warp", enabled = some)
      item("Pu&ppet Warp", enabled = some)
      item("Perspective &Warp...", enabled = some)
      menuSeparator()
      item("Image &Size...", enabled = some)
      item("Ca&nvas Size...", enabled = some)
      item("Tri&m", enabled = some)
      menuSeparator()
      item("&Histogram...", enabled = some)
      item("&Trap...", enabled = false)
    menu "&Layer":
      let grp = some and d.current.group
      item("&New Layer...", "Ctrl+Shift+N", some)
      item("New &Group...", enabled = some)
      item("Layer via &Copy", "Ctrl+J", some)
      item("Layer via Cu&t", "Ctrl+Shift+J", some and d.hasSelection)
      item("Layer from &File...", enabled = some)
      item(if grp: "&Duplicate Group" else: "&Duplicate Layer", enabled = some)
      item(if grp: "Delete Group" else: "Delete Layer", enabled = some and d.layers.len > 1)
      menuSeparator()
      item(if grp: "Group &Properties..." else: "Layer &Options...", enabled = some)
      item("&Blending Options...", enabled = some and not d.current.background)
      menuSeparator()
      submenu "New &Adjustment Layer":
        if some: adjustLayerMenu(d)
      submenu "New Fi&ll Layer":
        item("&Solid Color...", enabled = some)
        item("&Gradient...", enabled = some)
        item("&Pattern...", enabled = some and pattern.len > 0)
      submenu "Layer St&yle":
        layerStyleMenu(d)
      submenu "&Type":
        typeMenu(d)
      submenu "Smart O&bjects":
        smartObjectItems(d)
      submenu "&Rasterize":
        if menuItem("Type", enabled = some and d.current.isText):
          if te.on: commitType()
          let L = d.current
          d.stepOnce("Rasterize Type", proc () = d.rasterizeText(L))
        if menuItem("Layer Style", enabled = some and d.current.hasStyle): runCommand("Rasterize Layer Style")
        if menuItem("Shape", enabled = some and d.current.isShape):
          let L = d.current
          d.stepOnce("Rasterize Shape", proc () = d.rasterizeShape(L))
      menuSeparator()
      item("Group &Layers", "Ctrl+G", some and not d.current.background)
      item("&Ungroup Layers", "Ctrl+Shift+G", grp)
      submenu "&Arrange":
        item("Bring to &Front", "Ctrl+Shift+]", some and not d.current.background)
        item("Bring For&ward", "Ctrl+]", some and not d.current.background)
        item("Send Back&ward", "Ctrl+[", some and not d.current.background)
        item("Send to &Back", "Ctrl+Shift+[", some and not d.current.background)
      submenu "Al&ign":
        alignItems(d)
      submenu "Dis&tribute":
        distributeItems(d)
      item(if some and d.current.locked: "Unlock Layer" else: "Loc&k Layer", "Ctrl+/",
           some and not d.current.background)
      menuSeparator()
      if some and d.current.clipped:
        item("Release &Clipping Mask", "Ctrl+Alt+G", true)
      else:
        item("Create &Clipping Mask", "Ctrl+Alt+G", some and d.cur > 0 and not d.current.background)
      let mk = some and not d.current.background and d.current.adjust.kind.len == 0
      submenu "Layer &Mask":
        item("&Reveal All", enabled = mk and d.current.mask == nil)
        item("&Hide All", enabled = mk and d.current.mask == nil)
        item("Reveal &Selection", enabled = mk and d.current.mask == nil and d.hasSelection)
        item("Hide S&election", enabled = mk and d.current.mask == nil and d.hasSelection)
        menuSeparator()
        item("&Gradient Mask", enabled = mk)
      item("&Place Into...", enabled = some and not d.current.background)
      item("New &Frame", enabled = some)
      menuSeparator()
      item(if grp: "Merge Grou&p" else: "Merge Do&wn", "Ctrl+E", some and canMergeDown(d))
      item("Merge &Visible", "Ctrl+Shift+E", some and d.layers.len > 1)
      item("&Flatten Image", enabled = some and d.layers.len > 1)
    menu "Fi&lter":
      if menuItem("Last Filter" & (if lastFilter.set: " (" & lastFilter.name & ")" else: ""), "Ctrl+F",
                  enabled = edits and lastFilter.set): runCommand("Last Filter")
      menuSeparator()
      item("Develo&p...", "Ctrl+Shift+A", edits and rgb)
      item("Lens C&orrection...", "Ctrl+Shift+R", edits)
      item("Li&quify...", "Ctrl+Shift+X", edits)
      menuSeparator()
      submenu "Blur":
        filterItems(["&Blur", "Blur &More", "&Gaussian Blur...", "M&otion Blur...", "&Radial Blur...",
                     "&Surface Blur..."])
      submenu "Blur Gallery":
        item("&Field Blur...", enabled = edits)
        item("&Iris Blur...", enabled = edits)
        item("&Tilt-Shift...", enabled = edits)
      submenu "Retouch":
        filterItems(["&Skin Smoothing..."])
      submenu "Distort":
        filterItems(["&Displace...", "&Pinch...", "Polar &Coordinates...", "&Ripple..."])
        item("&Shear...", enabled = edits)
        filterItems(["S&pherize...", "&Twirl...", "&Wave...", "&ZigZag..."])
      submenu "Noise":
        filterItems(["&Add Noise...", "&Despeckle", "D&ust && Scratches...", "&Median...", "&Reduce Noise..."])
      submenu "Gallery":
        submenu "Artistic": filterItems(galleryArtistic.mapIt(it & "..."))
        submenu "Brush Strokes": filterItems(galleryBrush.mapIt(it & "..."))
        submenu "Sketch": filterItems(gallerySketch.mapIt(it & "..."))
        submenu "Texture": filterItems(galleryTexture.mapIt(it & "..."))
      submenu "Pixelate":
        filterItems(["Color &Halftone...", "&Crystallize...", "&Facet", "F&ragment", "M&ezzotint...",
                     "&Mosaic...", "&Pointillize..."])
      submenu "Render":
        filterItems(["&Clouds", "&Difference Clouds", "F&ibers...", "&Lens Flare...", "Lighting &Effects..."])
        item("&Texture Fill...", enabled = edits)
      submenu "Sharpen":
        filterItems(["&Sharpen", "Sharpen &Edges", "Sharpen &More", "S&mart Sharpen...", "&Unsharp Mask..."])
      submenu "Stylize":
        filterItems(["&Oil Paint...", "&Diffuse...", "&Emboss..."])
        filterItems(["E&xtrude..."])
        filterItems(["&Find Edges", "&Solarize", "&Tiles...", "Trace &Contour...", "&Wind..."])
      submenu "Video":
        filterItems(["&De-Interlace...", "&NTSC Colors"])
      submenu "Other":
        item("&Custom...", enabled = edits)
        filterItems(["&High Pass...", "Ma&ximum...", "M&inimum...", "&Offset..."])
      menuSeparator()
      submenu "&Plug-ins":
        item("Filter &Factory...", enabled = edits)
        item("&Edit Plug-in...", enabled = plugins.len > 0)
        menuSeparator()
        for cat in pluginCategories():
          submenu cat:
            for f in plugins:
              if f.category != cat: continue
              let nm = f.name.replace("&", "&&") & (if f.sliders != default(array[8, string]): "..." else: "")
              if menuItem(nm, enabled = edits): runCommand(f.name & (if nm.endsWith("..."): "..." else: ""))
    menu "&Select":
      item("&All", "Ctrl+A", some)
      item("&None", "Ctrl+D", sel)
      item("&Reselect", "Ctrl+Shift+D", d != nil and reselect.d == d and reselect.sel.len == d.w * d.h)
      item("&Inverse", "Ctrl+Shift+I", sel)
      menuSeparator()
      item("&Color Range...", enabled = rgb)
      item("Su&bject", enabled = some and d.mode in editModes)
      item("Remove Bac&kground", enabled = some and d.mode in editModes)
      item("S&ky", enabled = some and d.mode in editModes)
      menuSeparator()
      item("&Feather...", "Ctrl+Shift+D", sel)
      submenu "&Modify":
        item("&Border...", enabled = sel)
        item("&Smooth...", enabled = sel)
        item("&Expand...", enabled = sel)
        item("&Contract...", enabled = sel)
      menuSeparator()
      item("Select and &Mask...", "Ctrl+Alt+R", sel)
      menuSeparator()
      item("&Grow", enabled = sel)
      item("Si&milar", enabled = sel)
      menuSeparator()
      item("&Hide Edges", "Ctrl+H", sel, checked = dw != nil and dw.view.hideEdges)
      item("&Load Selection", enabled = some and d.alphas.len > 0)
      item("&Save Selection", enabled = sel)
      item("Make &Work Path", enabled = sel)
    menu "&View":
      item("Zoom &In", "Ctrl++", some)
      item("Zoom &Out", "Ctrl+-", some)
      item("&Fit on Screen", "Ctrl+0", some)
      item("&Actual Pixels", "Ctrl+Alt+0", some)
      menuSeparator()
      item(if dw != nil and dw.view.rulers: "Hide &Rulers" else: "Show &Rulers", "Ctrl+R", some)
      item(if dw != nil and dw.view.showGuides: "Hide &Guides" else: "Show &Guides", "Ctrl+;", some)
      item(if dw != nil and dw.view.showGrid: "Hide Gri&d" else: "Show Gri&d", "Ctrl+'", some)
      menuSeparator()
      item("&Snap", "Ctrl+Shift+;", true, checked = snapOn)
      submenu "Snap &To":
        item("&Guides", checked = snapGuides)
        item("G&rid", checked = snapGrid)
        item("&Document Bounds", checked = snapBounds)
      item("S&mart Guides", checked = smartGuidesOn)
      menuSeparator()
      item("&Lock Guides", "Ctrl+Alt+;", some, checked = dw != nil and dw.view.lockGuides)
      item("&Clear Guides", enabled = some and d.guides.len > 0)
      item("&New Guide...", enabled = some)
      item("Grid Settings...")
    menu "&Window":
      submenu "&Arrange":
        item("T&abbed Documents", checked = prefs.docTabs)
        item("&Floating Windows (MDI)", checked = not prefs.docTabs)
        menuSeparator()
        item("&Cascade", "Shift+F5", not prefs.docTabs and docs.len > 0)
        item("&Tile", "Shift+F4", not prefs.docTabs and docs.len > 0)
        menuSeparator()
        item("&Match Zoom", enabled = some and docs.len > 1)
        item("Match &Location", enabled = some and docs.len > 1)
      item("Next &Document", "Ctrl+Tab", docs.len > 1)
      item("Pre&vious Document", "Ctrl+Shift+Tab", docs.len > 1)
      item("Close &All", enabled = docs.len > 0)
      menuSeparator()
      item("&New Window", enabled = some)
      submenu "&Palettes":
        item("Tools", checked = toolbox.open)
        menuSeparator()
        item("Brushes", checked = panelShown("brushes"))
        item("Options", checked = panelShown("options"))
        menuSeparator()
        item("Picker", checked = panelShown("color"))
        item("Swatches", checked = panelShown("swatches"))
        item("Scratch", checked = panelShown("scratch"))
        menuSeparator()
        item("Layers", checked = panelShown("layers"))
        item("Channels", checked = panelShown("channels"))
        item("Paths", checked = panelShown("paths"))
        menuSeparator()
        item("Info", checked = panelShown("info"))
        item("Commands", checked = panelShown("commands"))
        menuSeparator()
        item("Navigator", checked = panelShown("navigator"))
        item("History", checked = panelShown("history"))
        item("Actions", checked = panelShown("actions"))
        item("Properties", checked = panelShown("properties"))
        item("Brush Settings", "F5", checked = panelShown("brushsettings"))
        menuSeparator()
        item("Character", checked = panelShown("character"))
        item("Paragraph", checked = panelShown("paragraph"))
        menuSeparator()
        item(if palettesHidden: "Show Palettes" else: "Hide Palettes", "Tab")
        item("Reset Palettes")
      submenu "&Workspace":
        item("&Save Workspace")
        item("&Load Saved Workspace")
        item("&Reset Workspace")
      item("Options &Bar", checked = optionsBarOn)
      if docs.len > 0: menuSeparator()
      for i, w in docs:
        if i >= 9: break
        if menuItem("&" & $(i + 1) & " " & w.doc.name.replace("&", "&&"), checked = w == active):
          w.showDoc()
    menu "&Help":
      item("&Contents", "F1")
      item("&Search for Help on...", enabled = false)
      item("&How to Use Help", enabled = false)
      menuSeparator()
      item("&About Retro Photo...")
      submenu "About Plug-&in":
        for n in ["Gaussian Blur", "Unsharp Mask", "Lens Flare", "Mezzotint", "Twirl"]:
          if menuItem(n & "..."): aboutOpen = true

# ---- the dialogs of this part ------------------------------------------------------------------------------

proc customDialog() =
  if not customOpen: return
  dialog(customOpen, "Custom", 420):
    row([-1, 92]):
      col:
        for y in 0 .. 4:
          row:
            for x in 0 .. 4:
              pushId("k" & $(y * 5 + x))
              intEdit(customK[y * 5 + x], w = dp(44), lo = -999, hi = 999)
              popId()
        row:
          label "Scale:"
          intEdit(customScale, w = dp(56), lo = 1, hi = 9999)
          label "Offset:"
          intEdit(customOffset, w = dp(56), lo = -9999, hi = 9999)
      col:
        if button("OK", isDefault = true, w = dp(80)):
          customOpen = false
          let d = cur()
          if d != nil:
            var k: seq[float]
            for v in customK: k.add v.float
            let f = custom(k, customScale.float, customOffset.float)
            d.paintStep("Custom"): d.applyFilter(3, f)
        if button("Cancel", w = dp(80)): customOpen = false
        if button("Reset", w = dp(80)):
          for v in customK.mitems: v = 0
          customK[12] = 1
          customScale = 1
          customOffset = 0

proc duplicateDialog() =
  if not dupOpen: return
  dialog(dupOpen, "Duplicate Image", 360):
    form 0:
      field "As:": edit(dupName)
    let d = cur()
    checkbox("Merged Layers Only", dupMerged, enabled = d != nil and d.layers.len > 1)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)):
        dupOpen = false
        if d != nil: addDoc(d.duplicateDoc(dupName.strip, dupMerged))
      if button("Cancel", w = dp(80)): dupOpen = false

const AppIconPng = staticRead("../assets/photo-icon.png")

proc aboutDialog() =
  aboutBox(aboutOpen, AppName, AppVersion,
           ["An image editor in the manner of the paint programs of 1994: layers, channels, " &
            "Quick Mask, paths, artboards, type with Arabic, forty filters and the color adjustments.",
            "Its engine is Retro Nim UI's own: retroui/photo, retroui/photopaint, retroui/photofx.",
            "Not affiliated with any maker of image software."],
           tagline = "Layers, type and filters -- as in 1994",
           iconPng = AppIconPng, glyph = pxBrush,
           whatsNew = ["4.9.7: on a Mac it opens again (it stopped at the first click or key since 0.29 of the kit); minimized, it draws nothing",
                       "4.9.6: in Termux, pictures named after it on the command line open; a report of a " &
                       "fault says the version",
                       "4.9.5: filters, flattening and gradients at 16 and 32 bits work again (4.9.4 " &
                       "left the part that does them out)",
                       "4.9.4: the Move tool turns and sizes the layer from its box's handles and the " &
                       "corners' turning room, before Auto-Select picks what is under them; when Retro " &
                       "Photo stopped, the next start says why first, and can open without the pictures " &
                       "that were open",
                       "4.9.3: the menus answer at once -- a submenu waits only while the pointer heads for it; " &
                       "the letters drawn as in 4.9 (FreeSans, its heights on whole pixels), Sharp text a choice; " &
                       "the Windows 3.1 frame on every desktop; Arabic and other right-to-left text by the whole bidi rules",
                       "The Line tool: arrowheads and other ends (open, stealth, circle, square, diamond, bar) " &
                       "at its start and end; the line stays a line -- its ends dragged with the Move tool, its " &
                       "ends and weight changed in the options bar or Properties",
                       "Image Size: the link keeps the proportions; pixels, percent, inches, centimeters, " &
                       "millimeters, points, picas; Fit To; Resample off keeps the pixels. Canvas Size in those " &
                       "units too, and Relative",
                       "Esc lets go what is under way (a stroke, a box being drawn, a move, the Polygonal Lasso, " &
                       "the crop, the path being drawn), else the selection; File > Save as PDF",
                       "New Document: Transparent is transparent (it made black); the Libraries panel's New... " &
                       "button no longer cut off",
                       "The menus by the keyboard: Alt (pressed and let go) or F10 opens them, the arrows go " &
                       "along and through them; a menu taller than the screen (Window on a tablet) in even columns, " &
                       "a submenu moved up to fit and opened beside the whole menu",
                       "Type moved off the image: its box shows on the gray round it, to drag it back",
                       "The tools work on the image: a click on the gray round it does nothing (the Hand and the " &
                       "Zoom work anywhere, a box's handles still take the pointer)",
                       "Several layers picked: Group (a folder of their own), Merge -- in the bar under the image, " &
                       "a right click on the layers or on the image",
                       "The Move tool as today's editors have it: the box's handles light up under the pointer and take it " &
                       "from further away, the pointer shows what a drag does; double-click type to edit it; " &
                       "right-click: the layers there; Auto-Select: Layer or Group",
                       "Smart Guides: a move lines up with the other layers and the image (magenta lines, the room " &
                       "between, how far it went)",
                       "New tools: Selection Brush (paint a selection), Adjustment Brush (paint brightness, " &
                       "saturation, warmth... where it is wanted) and Content-Aware Tracing (an edge of the picture " &
                       "made a path)",
                       "The panels: drag the bar between the image and the panels to make the whole side " &
                       "wider or narrower",
                       "Always on Top (the pin in a floating image's title bar, Window > Arrange): an image " &
                       "kept over the others",
                       "Help > About: each page scrolls inside its tab; on Windows a tooltip is no longer " &
                       "under the mouse pointer",
                       "The memory given back to the system as the program lets go of it -- it no longer only " &
                       "grows the longer it is used",
                       "Dialogs fit tablets and phones: the controls at the right (Select and Mask, Layer Style, " &
                       "Export As...) are no longer cut off when the interface is scaled up",
                       "Pictures too big to edit whole (gigapixel scans, huge maps) open as A Smaller Copy " &
                       "or A Part of It, read a band at a time",
                       "Export As > JPEG XL: lossy too (a quality: 90 looks the same, about a tenth of the size)",
                       "Assets: Pexels and Unsplash photos, each with a free key (Assets > Settings)",
                       "Assets (File > Browse Assets): free photos, icons, SVG, textures and backgrounds from " &
                       "Openverse, Wikimedia, Iconify, Poly Haven, ambientCG (and Pixabay with a key) -- " &
                       "inserted straight into the image",
                       "The Retro Photo Library, offline and online: brushes, patterns (Islamic khatam, " &
                       "arabesque), gradients, swatches, styles and designs",
                       "File > New as today's editors have it: presets by use (Photo, Print, Social, Web, Mobile, " &
                       "Art, Film), Recent and Saved sizes, 23 ready-made templates (flyer, certificate, " &
                       "notice, National Day, Ramadan, Wi-Fi card, menu, social posts...) with editable type",
                       "New QR Code (a vector layer); JPEG XL and SVG files",
                       "Quick Actions: Remove Background, Blur Background, Black & White Background, Enhance, " &
                       "Smooth Skin, Restore Old Photo, Frequency Separation -- one click each",
                       "File > Share; Export > Layers to Files; Automate > Image Processor (resize, convert, " &
                       "watermark a folder), Contact Sheet, Crop and Straighten Photos",
                       "Match Color, Select > Focus Area, Color Themes (harmonies), View > Before & After, " &
                       "Type > Paste Lorem Ipsum; R picks Rotate View",
                       "Files: Canon CR3, HEIC/AVIF read (and AVIF/HEIC written) by the system's " &
                       "libraries on desktops too",
                       "The layers mixed on the GPU when it is quicker; the pen's pressure and tilt on Windows, " &
                       "macOS and Linux too",
                       "16 and 32 bits for real: Levels, Curves, the adjustments, blurs, sharpening and the " &
                       "Gradient at 16 bits; the 16 bits kept through undo, crops, resizing and .rpd files",
                       "OpenType: Arabic set by the font (FreeSerif built in: its ligatures, marks placed by " &
                       "the font), the OpenType panel (stylistic sets, ligatures), variable fonts' axes",
                       "Color management for print: load a press's ICC profile (FOGRA, GRACoL, SWOP); CMYK, " &
                       "Proof Colors and PDF/X follow it",
                       "The Arabic interface: menus, panels and dialogs in Arabic, right to left",
                       "Files: WebP, OpenEXR, camera raw (Nikon, Sony, Canon CR2, Olympus, Panasonic, Pentax, " &
                       "Fuji), HEIC and AVIF (by the system), layered TIFF, SVG; PSD type layers and " &
                       "Smart Objects kept editable",
                       "Scripts (File > Scripts): Retro Script, a JavaScript to automate the editor",
                       "Rotate View (R), the Art History Brush, Character and Paragraph Styles, Vanishing Point",
                       "The pen: pressure, tilt and rotation (Android, iPad); its eraser end erases",
                       "Liquify: Smooth, Push Left, Freeze and Thaw Mask; Select and Mask: Color Aware",
                       "Blurs and color adjustments on the GPU when it draws the frames",
                       "32 Bits/Channel (HDR): Radiance .hdr and PFM files, 32-bit Preview, HDR Toning; " &
                       "PNG-24 and 32-bit BMP",
                       "Press-ready PDF: PDF/X-4, registration marks, color bars, page information, bleed; " &
                       "type kept as text (its font in the file)",
                       "Arabic: kashida where the scribes put it, the tashkeel kept on its letter; " &
                       "text in columns, flowing on into another box",
                       "A new splash; Help > Report a Problem (a fault no longer closes the program)",
                       "The Filter Gallery: 30 filters (Artistic, Brush Strokes, Sketch, Texture); Oil Paint, " &
                       "Lighting Effects, Fibers, Displace, Smart Sharpen",
                       "109 custom shapes in 12 sets; Live Shape size, corners, flips in Properties",
                       "The Slice, Note and Count tools; Slices to Files",
                       "The toolbar docked at the left, its header as the panels'; tabs as the panels' everywhere",
                       "Faster: a 12-megapixel picture composites in half the time, opens and saves twice as fast",
                       "Documents as tabs in all the room between the toolbar and the panels; " &
                       "windows of their own (MDI) as an option (Window > Arrange)",
                       "Panels docked as today's editors have them: tabs, groups, a column of icons, floating",
                       "A status bar under each picture: its zoom, size and what its menu says",
                       "Adjustment Presets (36, and yours), Clarity, Dehaze and Grain",
                       "Layer Cleanup, Harmonize, Colorize with color hints, Content-Aware expand",
                       "Artboards, the Frame tool, the Triangle, the Magnetic Lasso",
                       "Type: right-to-left and left-to-right, Arabic kashida, dynamic text",
                       "Google Fonts fixed; Spot Healing and Patch as they work today"],
           credits = ["Retro Photo and Retro Nim UI: " & RetroCredit & " -- " & RetroWebsite & " -- " & RetroEmail,
                      "Assets: Openverse, Wikimedia Commons, Iconify and its icon sets, Poly Haven (Powered by " &
                      "Poly Haven), ambientCG, Pixabay -- each item's own licence and credit kept with it.",
                      RetroFontCredit,
                      "Icons: Nerd Fonts symbols (MIT / OFL) and Retro's own pixel icons.",
                      "Written in Nim."])

proc helpText(): string =
  result = "# " & AppName & " Help\n\n" &
    "Pick a tool in the toolbar (or press its letter), set it up in the options bar, then work on " &
    "the image. Every change can be undone with **Ctrl+Z**.\n\n" &
    "## Following a tutorial\n\n" &
    "The menus, panels, tools and keys are named and placed as in today's image editors, so a tutorial's " &
    "steps work as written: **Image > Adjustments > Curves** (Ctrl+M), **Edit > Free Transform** " &
    "(Ctrl+T: a corner keeps the proportions, **Shift** frees them, **Ctrl** moves a corner alone, " &
    "**Ctrl+Shift** on a side skews), **Layer > New > Layer** (Ctrl+Shift+N), **Select > Modify > " &
    "Feather** (Shift+F6), **Filter > Camera Raw Filter** (Ctrl+Shift+A), **Window > Histogram**...\n\n" &
    "- **Edit > Search** (Ctrl+F) finds any command, panel or tool by a few letters of its name\n" &
    "- **Window** lists the panels A to Z: Adjustments, Brushes, Channels, Character, Clone Source, " &
    "Color, Glyphs, Gradients, Histogram, History, Info, Layer Comps, Layers, Navigator, Paragraph, " &
    "Paths, Patterns, Properties, Shapes, Styles, Swatches, Tool Presets\n" &
    "- the **Contextual Task Bar** under the image offers the next steps (Select Subject, Remove " &
    "Background, Select and Mask, Invert, Mask, Fill...); Window > Contextual Task Bar hides it\n" &
    "- the **Ruler** (I group) measures; **Straighten Layer** levels the photo along its line; the " &
    "**Color Sampler** keeps up to four points' colors; the **Magic Eraser** (E group) clears a color\n" &
    "- Preferences > Tools > **Use Legacy Free Transform** makes Shift keep the proportions, as before 2019\n" &
    "- with Retro Photo 1994's keys (Preferences > Tools) the menus are 1994's\n\n" &
    "## The toolbar\n\n" &
    "As in today's editors: the tools in groups, one column (the **>>** at its top: two). A group shows " &
    "the tool used last; the small triangle at its corner means it holds more -- **hold the button " &
    "down** (or right-click it, or long-press it) and they open beside it, each with its name and key. " &
    "**Alt+click** a group: its next tool. A letter picks a group; **Shift** and the letter, the next " &
    "tool in it. **...** at the bottom holds the groups taken off; **Edit > Toolbar...** chooses them. " &
    "(With Retro Photo 1994's keys -- Preferences -- the letters are 1994's.)\n\n" &
    "| Tools | Key |\n|---|---|\n"
  for grp in toolGroups:
    var names: seq[string]
    for it in grp.items: names.add it.name
    result.add "| " & names.join(", ") & " | " & grp.key & " |\n"
  result.add "\n## The tools\n\n| Tool | Use |\n|---|---|\n"
  for t in Tool: result.add "| " & $t & " | " & toolHints[t] & " |\n"
  result.add "\n## Keys\n\n" &
    "- **X** swaps the colors, **D** makes them black and white\n" &
    "- **Q** turns Quick Mask on and off: paint the selection in red\n" &
    "- **Tab** hides the palettes, **F** changes the screen mode\n" &
    "- **1** to **0** set the opacity of the tool (10 % to 100 %)\n" &
    "- **[** and **]** make the brush smaller and bigger, **Shift+[** and **Shift+]** softer and " &
    "harder, **,** and **.** the brush preset before and after; Alt and the right button " &
    "dragged: sideways the size, up and down the hardness\n" &
    "- **Ctrl+Tab** goes to the next document, **F5** shows the Brush Settings\n" &
    "- held for a moment: **Space** the Hand (with Ctrl the Zoom, with Alt zooming out), " &
    "**Ctrl** the Move tool, **Alt** the Eyedropper with the painting tools\n" &
    "- **Alt+[** and **Alt+]** the layer below and above, **Ctrl+Alt+Shift+E** Stamp Visible, " &
    "**Alt+Backspace** / **Ctrl+Backspace** fill with the foreground / background color, " &
    "**Ctrl+Shift+D** Reselect\n" &
    "- drag a label (Opacity, Flow, Size) sideways to change its number\n" &
    "- Edit > **Keyboard Shortcuts...** changes any of them (today's keys, or 1994's)\n" &
    "- **Ctrl+1**, **2**, **3** (**4** in CMYK) show one color channel\n" &
    "- the arrow keys nudge the selection, a shape or type (Shift: by 10)\n" &
    "- **Ctrl+F** runs the last filter again\n" &
    "- **Ctrl+Alt+G** clips the layer to the one under it\n" &
    "- **Ctrl+Alt+Y** shows the image as it prints, **Ctrl+Shift+Y** what cannot print\n\n" &
    "## Shapes\n\n" &
    "The Shape tool (**N**; Alt+click it for the next shape) draws rectangles, rounded rectangles, " &
    "ellipses, polygons and stars, lines with arrowheads and custom shapes as **shape layers**: " &
    "sharp at any size, filled and stroked as the Options say (change them with the layer chosen), " &
    "moved with the Move tool, reshaped with Image > Effects. Combine adds a shape to the layer chosen " &
    "or cuts it out.\n\n" &
    "## Colors\n\n" &
    "Mode > CMYK Color keeps only the colors the printing inks can make (Printing Inks Setup says " &
    "how they print); Lab Color edits lightness apart from color; Duotone prints a gray picture in " &
    "one to four inks.\n\n" &
    "## Brushes\n\n" &
    "The brush presets are kept in folders (General, Dry Media, Wet Media, Special Effects and the " &
    "ones you load: .abr brush files), each shown as it paints, from 1 to 5000 pixels. " &
    "**Brush Settings** (F5) sets the tip (round, square, chalk, bristles... or one you make from " &
    "the selection: Define Brush Preset in the Brushes palette's menu), its spacing, angle and " &
    "roundness, and the dynamics: sizes, angles, scattering, texture, dual brush, color, flow and " &
    "wet edges that vary as you paint. The Options also have Smoothing and Symmetry (mirrored or " &
    "turned round the middle, up to 16 times).\n\n" &
    "## Moving and sizing\n\n" &
    "The Move tool (V) shows the current layer's box in blue: drag a handle to size it (Shift: " &
    "the same proportions, Alt: from the middle), just outside a corner to turn it, then Enter. Type " &
    "stays type (its letters get bigger), shapes stay sharp. **Auto-Select** picks the layer you " &
    "click and outlines the one under the mouse; **Alt+drag** moves a copy.\n\n" &
    "## Masks\n\n" &
    "Layer > Layer Mask: Reveal or Hide All or the selection, and **Gradient Mask** (the Gradient " &
    "tool on the mask: the layer fades out). Layer > **Place Into...** puts a picture inside the " &
    "current layer -- type, a shape, a frame (Layer > New Frame) -- clipped to it. Alt+click the line " &
    "between two layers to clip the upper one; Ctrl+click a thumbnail to select what is on it. The " &
    "Type tool's **Type Mask** makes the letters a selection.\n\n" &
    "## Smart selections\n\n" &
    "Select > **Remove Background** keeps the subject (a layer mask that follows hair). The Object " &
    "Selection tool's **Object Finder** shows the thing under the mouse; click it to select it. " &
    "Select and Mask has **Refine Hair**.\n\n" &
    "## Colors\n\n" &
    "File > New makes Bitmap, Grayscale, RGB, CMYK and Lab images at 8 or 16 bits. Edit > **Color " &
    "Settings** sets the working spaces and the inks. The color picker takes CMYK and Lab numbers; " &
    "**Color Libraries** in it show named colors from color books -- the web's, CSS's, process " &
    "tints, and the .acb books you load (Edit > Presets > Load Color Book: Pantone's and others').\n\n" &
    "## Documents\n\n" &
    "Pictures open as tabs, in all the room between the toolbar and the panels; drag a tab along " &
    "the strip to put it in another place, right-click it for Close Others. Window > Arrange > " &
    "Floating Windows (MDI) gives each picture a window of its own, as in 1994 (Cascade, Tile); " &
    "Tabbed Documents brings the tabs back (also in Preferences > Workspace). Each picture's status " &
    "bar shows the zoom (type a new one in it) and " &
    "what its menu says: the document's size, profile, dimensions, the tool, the time a command " &
    "took. Window > Workspace keeps where the palettes are.\n\n" &
    "## Saving and recovery\n\n" &
    "Every few minutes (Preferences > History & Saving) a changed picture is kept aside; if the " &
    "program did not end well, the next start offers it back. File > Open Recent lists the last " &
    "pictures. Image > Mode > **16 Bits/Channel** keeps a 16-bit PNG, TIFF or PSD file's " &
    "depth when it is saved again.\n\n" &
    "## Speed\n\n" &
    "With a graphics processor (Preferences > Performance > Use Graphics Processor), the window " &
    "and the picture are drawn by it: zooming and scrolling cost the processor nothing. Without " &
    "one, only what changed is drawn again, on all the processor's cores.\n\n" &
    "A big photo (tens of megapixels): while a layer is moved, transformed (Ctrl+T) or adjusted " &
    "with a slider, what you see is made from the layers at the screen's size; the whole picture " &
    "is changed once, when you let go (a moment, with the hourglass).\n\n" &
    "## Presets\n\n" &
    "Edit > Presets reads swatches (.aco, .ase), curves (.acv), levels (.alv), " &
    "gradients (.grd), patterns (.pat) and brushes (.abr); swatches, curves and levels are saved " &
    "in the same files.\n\n" &
    "## Plug-ins\n\n" &
    "Filter > Plug-ins > **Filter Factory...** makes a filter from four formulas, one a channel " &
    "(r, g, b, a, x, y, ctl(0)..., src(x, y, z), sin, mix, scl, rnd, ? :). **Save Plug-in** keeps " &
    "it and lists it in the menu with its sliders.\n\n" &
    "## Files\n\n" &
    "Retro Photo files (.rpd) keep the layers, channels and paths; PSD and PSB files (.psd, .psb) " &
    "keep the layers, groups, masks, shapes, clipping, adjustment layers and styles. PNG, JPEG, " &
    "TIFF, GIF, Targa and BMP keep the picture as it looks, its layers mixed into one: File > Export " &
    "> **Export As...** sets their options. Layer > **Layer from File...** puts a picture in as a " &
    "new layer above the one chosen.\n"

proc helpDialog() =
  if not helpOpen: return
  dialog(helpOpen, AppName & " Help", 620):
    markdownView(helpText(), height = dp(380))
    row:
      spring()
      if button("Close", isDefault = true, w = dp(80)): helpOpen = false

proc moreDialogs() =
  searchDialog()
  colorSettingsDialog()
  recoverDialog()
  prefsDialog()
  keysDialog()
  presetFileDialog()
  dynamicsDialog()
  filterFactoryDialog()
  duotoneDialog()
  inksDialog()
  proDialogs()
  combineDialogs()
  smartDialogs()
  helpDialog()
  customDialog()
  duplicateDialog()
  aboutDialog()

# ---- the splash --------------------------------------------------------------------------------------------

proc splashArt(w, h: int): Bitmap =
  ## The opening picture, painted with the program's own engine: a dusk
  ## sky with its first stars, a glint, the hills (the name goes over it).
  let d = newDoc(w, h, white)
  var o = PaintOpts(color: argb(255, 20, 16, 64), bg: argb(255, 214, 96, 54), opacity: 100, mode: bmNormal)
  d.gradient(0, 0, 0, h.float, o, gsFgToBg, gkLinear, 58, 0, true)
  d.applyFilter(0, lensFlare(w.float * 0.78, h.float * 0.30, 120))
  # the hills
  var hill: seq[(float, float)]
  for k in 0 .. 40:
    let x = k / 40 * w.float
    hill.add (x, h.float * 0.80 - sin(k / 40 * PI * 2.2) * h.float * 0.06 - sin(k / 40 * PI * 5) * h.float * 0.02)
  hill.add (w.float, h.float)
  hill.add (0.0, h.float)
  d.paintMask(d.polygonMask(hill, true), argb(255, 16, 12, 30))
  # (stars over the dusk)
  for k in 0 ..< 40:
    let x = (k * 7919 + 13) mod w
    let y = (k * 104729 + 7) mod max(1, h div 2)
    let b = 150 + (k * 37) mod 105
    d.layer.px[y * w + x] = argb(255, b, b, min(255, b + 20))
  inc d.layer.ver
  d.markAll()
  result = d.toBitmap(white)

proc splash() =
  ## The box shown while the program starts: the painted dusk, the icon, the
  ## name and version, a 3.1 progress bar.
  if ui.now >= splashUntil: return
  let w = min(dp(460), ui.w - dp(16))
  if splashBmp == nil: splashBmp = splashArt((w - 6) * pxScale, dp(170) * pxScale)
  let total = max(1, splashUntil - splashStart)
  let done = clamp((ui.now - splashStart) / total, 0.0, 1.0)
  let steps = ["Starting...", "Reading the brushes and presets...", "Loading the filters...",
               "Making the panels...", "Ready"]
  splashBox(AppName, AppVersion, "An image editor in the manner of 1994",
            ["Layers, Arabic type, 32-bit HDR, the Filter Gallery, press-ready PDF"],
            art = splashBmp, iconPng = AppIconPng, progress = done,
            note = steps[min(steps.high, int(done * steps.len.float))], width = 460)
  wakeIn(max(16, min(80, splashUntil - ui.now)))
  if ui.pressed: splashUntil = 0

# ---- keys --------------------------------------------------------------------------------------------------

var digitAt = -1_000_000            ## (when a number key was pressed: two make a value)
var digitFirst = -1

proc nudge(dx, dy: int) =
  let d = cur()
  if d == nil: return
  let L = d.current
  if (L.isShape or L.isText) and not d.hasSelection and not d.editMask and not d.quickMask:
    # (a shape or type layer: what it holds moves)
    d.beginStep("Nudge")
    d.touchLayers()
    if L.isShape:
      var s = L.shape
      s.path.mapPoints(proc (x, y: float): (float, float) = (x + dx.float, y + dy.float))
      d.setShape(L, s)
    else: d.setText(L, L.text.moved(dx.float32, dy.float32))
    d.endStep()
    return
  d.beginStep("Nudge")
  var l = d.beginMove(bg)
  d.moveTo(l, dx, dy)
  d.endMove(l)
  d.endStep()

proc cancelDrag() =
  ## Esc while the mouse is down: what it was doing is let go, the image as
  ## it was when it went down (the stroke, the move, the box, the gradient,
  ## the selection drawn...): finished as on a release, then taken back.
  let dw = drag.dw
  if dw == nil:
    drag = Drag()
    return
  let d = dw.doc
  if cropGrab.on or sliceGrab.on:
    # (the crop box or a slice held: back where it was -- a release would
    # crop, a click inside the box crops)
    cropGrab.on = false
    if sliceGrab.on and sliceSel in 0 .. slices.high: slices[sliceSel].r = sliceGrab.r0
    sliceGrab.on = false
  elif drag.tool notin {tHand, tZoom}:
    try: releaseOn(PhotoEvent(over: true, x: drag.x1, y: drag.y1, released: true))
    except CatchableError: discard
  drag = Drag()
  if d.stepOpen: d.cancelStep()
  # (the steps it made, taken back -- and not left to redo)
  let made = d.stepsMade - pressWas.steps
  var undone = 0
  for i in 0 ..< made:
    if not d.canUndo: break
    d.undo()
    inc undone
  if undone > 0: d.redoSteps.setLen(max(0, d.redoSteps.len - undone))
  pendingCrop = pressWas.crop
  ruler = pressWas.ruler
  slices = pressWas.slices
  sliceSel = min(sliceSel, slices.high)
  if te.on and not pressWas.typing: cancelType()     # (a type box drawn: dropped)
  if shapeDlg.on and not pressWas.shapeDlg: shapeDlg.on = false
  penDrag.on = false
  lineGrab.on = false
  textMove.on = false
  shapeMove.on = false
  sg.on = false
  inc d.ver
  status = "Cancelled"

proc escapeKey(): bool =
  ## Esc: what is under way is let go -- a drag (the image as it was), the
  ## Polygonal Lasso's corners, the crop box waiting, the path being drawn
  ## (ended: the next click starts another), the Ruler's line; else the
  ## selection goes (Deselect). True when it did something.
  let d = cur()
  if drag.on:
    cancelDrag()
    return true
  if polyLasso.on:
    finishPolyLasso(false)
    status = "Cancelled"
    return true
  if pendingCrop.on:
    pendingCrop.on = false
    status = "Crop cancelled"
    return true
  if d == nil: return false
  if tool == tPen and penMode in {1, 7} and not penEnded and d.curPath in 0 .. d.paths.high and
     d.paths[d.curPath].subs.len > 0 and not d.paths[d.curPath].subs[^1].closed:
    penEnded = true
    status = "The path is ended: the next click starts another"
    inc d.ver
    return true
  if ruler.on and ruler.d == d and tool == tEyedropper and dropKind == 2:
    ruler.on = false
    inc d.ver
    return true
  if d.hasSelection:
    runCommand("None")                # (Select > Deselect)
    status = "Deselected"
    return true
  if d.pickedLayers.len > 1:
    d.clearPicks()
    inc d.ver
    return true
  false

proc keys() =
  moreDialogs()
  if te.on and canInput():
    typeKeys()                     # (text being typed takes the keys)
    return
  if not canInput() or ui.keyUsed: return
  brushKeys()                      # ([ ] , . F5)
  if ui.keyUsed: return
  let ctrl = CtrlPressed in ui.mods
  let shift = ShiftPressed in ui.mods
  let alt = AltPressed in ui.mods
  let d = cur()
  # the shortcuts (the usual, or 1994's; the user's own over them)
  let cmd = keymap.keymapPressed()
  if cmd.len > 0:
    runCommand(cmd)
    return
  if ctrl or alt:
    # one color channel: Ctrl+3, 4, 5 (the usual), Ctrl+1, 2, 3 (1994's); all: Ctrl+2 (Ctrl+~)
    let first = if prefs.keySet == 0: Key3 else: Key1
    if d != nil and ctrl and not shift and ui.key in first .. Key5 and
       ord(ui.key) - ord(first) < d.channelCount and d.channelCount > 1:
      ui.keyUsed = true
      d.showChannel(ord(ui.key) - ord(first))
      inc d.ver
    elif d != nil and ctrl and not shift and prefs.keySet == 0 and ui.key == Key2:
      ui.keyUsed = true
      d.showChannel(-1)
      inc d.ver
    return
  if xf.on and ui.key in {KeyEnter, KeyEsc}:
    ui.keyUsed = true
    finishTransform(ui.key == KeyEnter)
    drag = Drag()                   # (a handle held: let go with it)
    return
  if wm.kind != wkNone and ui.key in {KeyEnter, KeyEsc}:
    ui.keyUsed = true
    modeFinish(ui.key == KeyEnter)
    drag = Drag()
    return
  case ui.key
  of KeyEnter:
    if polyLassoKeys(): return
    if pendingCrop.on and pendingCrop.dw != nil:
      ui.keyUsed = true
      commitCropNow()
  of KeyEsc:
    if escapeKey(): ui.keyUsed = true
  of KeyDelete, KeyBackspace:
    if polyLassoKeys(): return        # (the Polygonal Lasso's last corner taken back)
    if d != nil and not ui.takesText:
      ui.keyUsed = true
      if tool == tPen and penMode == 5 and pathSel >= 0:
        # (Path Selection: the picked shape of the path taken away)
        if d.curPath >= 0 and d.curPath < d.paths.len and pathSel < d.paths[d.curPath].subs.len:
          d.beginStep("Delete Path")
          d.touchPaths()
          d.paths[d.curPath].subs.delete(pathSel)
          d.endStep()
        elif d.current.isShape and not d.current.isFill and pathSel < d.current.shape.path.subs.len and
             d.current.shape.path.subs.len > 1:
          d.beginStep("Delete Shape")
          d.touchLayers()
          var sh = d.current.shape
          sh.path.subs.delete(pathSel)
          d.setShape(d.current, sh)
          d.endStep()
        pathSel = -1
        inc d.ver
      elif shift: runCommand("Fill...") else: runCommand("Clear")
  of KeyLeft, KeyRight, KeyUp, KeyDown:
    if d != nil and tool in {tMove, tMarquee, tLasso, tWand} and not ui.takesText:
      ui.keyUsed = true
      let n = if shift: 10 else: 1
      let (dx, dy) = case ui.key
                     of KeyLeft: (-n, 0)
                     of KeyRight: (n, 0)
                     of KeyUp: (0, -n)
                     else: (0, n)
      if tool != tMove and d.hasSelection:
        # (a selection tool: the outline moves, the pixels stay)
        d.beginStep("Nudge Selection")
        d.touchSel()
        let was = d.sel
        d.moveSelection(was, dx, dy)
        d.endStep()
      else: nudge(dx, dy)
  of KeyTab:
    if not ui.takesText:
      ui.keyUsed = true
      palettesHidden = not palettesHidden
  else:
    if ui.takesText: return
    if polyLassoKeys(): return
    # one letter: a tool -- the usual groups (Shift: the next tool in the
    # group); 1994's letters with that key set
    if prefs.keySet != 1:
      if ui.key in {KeyA .. KeyZ} and toolKeyPressed(ui.key, shift):
        ui.keyUsed = true
        return
    elif ui.key == KeyJ:
      # J: the healing tools, then the red eye, in turn
      ui.keyUsed = true
      if tool == tHeal and healMode < 4: inc healMode
      elif tool == tHeal: selectTool(tRedEye)
      elif tool == tRedEye:
        healMode = 0
        selectTool(tHeal)
      else: selectTool(tHeal)
      return
    if prefs.keySet == 1:
      for t in Tool:
        if ui.key == KeyCode(ord(KeyA) + ord(toolKeys[t]) - ord('A')):
          ui.keyUsed = true
          if tool == t or (shift and t in {tMarquee, tBlur, tDodge}):
            case t
            of tMarquee: marqueeShape = (marqueeShape + 1) mod 2
            of tBlur: blurMode = 1 - blurMode
            of tDodge: dodgeMode = (dodgeMode + 1) mod 3
            else: discard
          selectTool(t)
          return
    case ui.key
    of KeyX:
      ui.keyUsed = true
      swap(fg, bg)
    of KeyD:
      ui.keyUsed = true
      fg = black
      bg = white
    of KeyQ:
      if d != nil:
        ui.keyUsed = true
        if d.quickMask: d.leaveQuickMask() else: d.enterQuickMask()
    of KeyF:
      ui.keyUsed = true
      screenMode = (screenMode + 1) mod 3
      if active != nil: active.win.maximized = screenMode > 0
    of Key0 .. Key9:
      # the usual: the painting tool's opacity -- the layer's with the
      # other tools; 1 is 10 %, 0 is 100 %, two typed quickly: that (4 5: 45 %)
      ui.keyUsed = true
      let k = ord(ui.key) - ord(Key0)
      var v = if k == 0: 100 else: k * 10
      if ui.now - digitAt < 600 and digitFirst >= 0:
        v = max(1, digitFirst * 10 + k)
        digitFirst = -1
      else: digitFirst = k
      digitAt = ui.now
      if tool in paintTools + {tBucket, tGradient, tHeal}:
        opts[tool].opacity = v
        status = toolName(tool) & " opacity: " & $v & "%"
      elif d != nil and not d.current.background:
        d.layersChange("Layer Opacity"): discard
        d.current.opacity = v
        d.showOpacity()
        status = d.current.name & " opacity: " & $v & "%"
    else: discard

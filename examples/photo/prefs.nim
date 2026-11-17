# (included by photo.nim) Preferences (Edit › Preferences, Ctrl+K): the usual
# pages in a list at the left, kept in the settings file.

type PrefPage = enum
  ppGeneral = "General", ppInterface = "Interface", ppWorkspace = "Workspace", ppTools = "Tools",
  ppFiles = "History & Saving", ppPerformance = "Performance", ppScratch = "Scratch Disks",
  ppCursors = "Cursors", ppTransparency = "Transparency & Gamut", ppUnits = "Units & Rulers",
  ppGuides = "Guides, Grid & Slices", ppType = "Type", ppColor = "Color Profiles"

var
  cmykIntent = 1                 ## Color Settings: perceptual, relative colorimetric, saturation, absolute
  cmykBpc = true                 ## ... black point compensation

proc cmykProfileFile(): string = dataDir(AppData) / "profiles" / "cmyk.icc"
  ## (the CMYK profile in use, kept with the program's settings)

proc useCmykProfile(data: string): bool {.discardable.} =
  ## The inks from a press profile (empty: the built-in ink model).
  result = setInkProfile(data, RenderingIntent(clamp(cmykIntent, 0, 3)), cmykBpc)
  for dw in docs: inc dw.doc.ver

var
  keysOpen = false
  keysWas: Keymap
  prefPage = 0
  prefsWas: tuple[app: AppPrefs; view: ViewPrefs]     ## (as they were when the dialog opened: Cancel)
  scratchPick = false
  scratchPicked = ""
  defaultScratch = ""

const
  guideColors = [("Light Blue", color(74, 255, 255)), ("Cyan", color(0, 200, 255)),
                 ("Light Red", color(255, 74, 74)), ("Green", color(74, 255, 74)),
                 ("Medium Blue", color(74, 74, 255)), ("Yellow", color(255, 255, 0)),
                 ("Magenta", color(255, 0, 255)), ("Gray", color(128, 128, 128)),
                 ("Black", color(0, 0, 0))]
  autosaveSteps = [0, 1, 5, 10, 15, 30, 60]

proc colorIndex(c: Color): int =
  for i, (_, gc) in guideColors:
    if gc == c: return i
  -1

proc applyMemory() =
  ## The memory Retro Atelier may use: the biggest image, the undo steps kept
  ## in memory (the rest on the scratch disk).
  let budget = physicalMemory() * int64(clamp(prefs.memory, 20, 90)) div 100
  maxPixels = int(clamp(budget div 34, 16_000_000'i64, 400_000_000'i64))
  undoRamAll = int(clamp(budget div 11, 64'i64 shl 20, 2048'i64 shl 20))
  undoRamBudget = undoRamAll
  undoShared = -1                  # (shared again between the open images: the next frame)
  imaging.maxPicturePixels = maxPixels

proc applyLanguage()

proc applyPrefs() =
  ## Every setting where it acts.
  applyLanguage()
  isMethod = clamp(prefs.interp, 0, 3)
  optionsBarOn = prefs.optionsBar
  maxHistoryStates = clamp(prefs.history, 1, 1000)
  exportProfile = prefs.embedProfile
  psdMaximizeCompatibility = prefs.psdComposite
  if prefs.scratch.len > 0 and dirExists(prefs.scratch): scratchDir = prefs.scratch
  elif defaultScratch.len > 0: scratchDir = defaultScratch
  applyMemory()
  newDpi = clamp(prefs.screenRes, 1, 9999)
  if getEnv("RETRO_GPU").len == 0: setGpuMode(GpuMode(clamp(prefs.gpu, 0, 2)))

proc loadPrefs() =
  ## Preferences from the settings file (the defaults for what is not there).
  let st = loadSettings(AppData)
  var p = DefaultPrefs
  if st.getBool("pref.reset", false):
    prefs = p
    viewPrefs = ViewPrefs(checkerSize: ckMedium, checkerColors: ccLight, rulerUnit: ruPixels,
                          gridEvery: 64, gridUnit: ruPixels, gridSub: 4, gridColor: color(128, 128, 128),
                          guideColor: color(0, 200, 255))
    var clean: Settings
    for k, v in st:
      if not (k.startsWith("pref.") or k.startsWith("look.") or k == "color.profiles"): clean[k] = v
    discard saveSettings(AppData, clean)
    applyPrefs()
    return
  p.interp = st.getInt("pref.interp", p.interp)
  p.zoomResizes = st.getBool("pref.zoomResizes", p.zoomResizes)
  p.zoomCenter = st.getBool("pref.zoomCenter", p.zoomCenter)
  p.docTabs = not st.getBool("pref.docWindows", not p.docTabs)
  p.optionsBar = st.getBool("pref.optionsBar", p.optionsBar)
  p.history = st.getInt("pref.history", p.history)
  p.autosave = st.getInt("pref.autosave", p.autosave)
  p.session = st.getBool("pref.session", p.session)
  p.bgSave = st.getBool("pref.bgSave", p.bgSave)
  p.recent = st.getInt("pref.recent", p.recent)
  p.lowerExt = st.getBool("pref.lowerExt", p.lowerExt)
  p.psdComposite = st.getBool("pref.psdComposite", p.psdComposite)
  p.memory = st.getInt("pref.memory", p.memory)
  p.threads = st.getInt("pref.threads", p.threads)
  p.gpu = clamp(st.getInt("pref.gpu", p.gpu), 0, 2)
  p.scratch = st.getOrDefault("pref.scratch", "")
  p.paintCursor = st.getInt("pref.paintCursor", p.paintCursor)
  p.crosshair = st.getBool("pref.crosshair", p.crosshair)
  smartGuidesOn = st.getBool("pref.smartGuides", true)
  pixelGridOn = st.getBool("pref.pixelGrid", true)
  dynamicSpelling = st.getBool("pref.dynamicSpelling", false)
  moveAutoGroup = st.getBool("pref.autoSelectGroup", false)
  p.otherCursor = st.getInt("pref.otherCursor", p.otherCursor)
  p.printRes = st.getInt("pref.printRes", p.printRes)
  p.screenRes = st.getInt("pref.screenRes", p.screenRes)
  p.smartQuotes = st.getBool("pref.smartQuotes", p.smartQuotes)
  p.workingSpace = st.getInt("pref.workingSpace", p.workingSpace)
  p.embedProfile = st.getBool("pref.embed", p.embedProfile)
  p.keySet = st.getInt("pref.keyset", p.keySet)
  p.toolCols = st.getInt("pref.toolcols", p.toolCols)
  p.toolHidden = st.getOrDefault("pref.toolhidden", p.toolHidden)
  p.taskBar = st.getBool("pref.taskbar", p.taskBar)
  p.legacyXf = st.getBool("pref.legacyxf", p.legacyXf)
  p.legacyNew = st.getBool("pref.legacynew", p.legacyNew)
  p.language = if st.getOrDefault("pref.language") == "ar": 1 else: 0
  p.lorem = st.getOrDefault("pref.lorem", "")
  p.layerSizes = st.getBool("pref.layerSizes", p.layerSizes)
  prefs = p
  restoreKeymap(st, keymap)
  applyKeySet()
  for pp in ProfilePolicy:
    if st.getOrDefault("color.profiles") == $pp: profilePolicy = pp
  cmykIntent = clamp(st.getInt("color.cmykIntent", 1), 0, 3)
  cmykBpc = st.getBool("color.cmykBpc", true)
  if fileExists(cmykProfileFile()):
    try: discard useCmykProfile(readFile(cmykProfileFile())) except CatchableError: discard
  template enumOf[T](key: string; dflt: T): T =
    var r = dflt
    for e in T:
      if st.getOrDefault(key) == $e: r = e
    r
  viewPrefs.checkerSize = enumOf("pref.checkerSize", viewPrefs.checkerSize)
  viewPrefs.checkerColors = enumOf("pref.checkerColors", viewPrefs.checkerColors)
  viewPrefs.rulerUnit = enumOf("pref.rulerUnit", viewPrefs.rulerUnit)
  viewPrefs.gridUnit = enumOf("pref.gridUnit", viewPrefs.gridUnit)
  viewPrefs.gridStyle = enumOf("pref.gridStyle", viewPrefs.gridStyle)
  viewPrefs.guideStyle = enumOf("pref.guideStyle", viewPrefs.guideStyle)
  try: viewPrefs.gridEvery = parseFloat(st.getOrDefault("pref.gridEvery", "64"))
  except ValueError: discard
  viewPrefs.gridSub = st.getInt("pref.gridSub", viewPrefs.gridSub)
  viewPrefs.wheelZooms = st.getBool("pref.wheelZooms", false)
  let gc = st.getInt("pref.gridColor", -1)
  if gc >= 0: viewPrefs.gridColor = color(uint8(gc shr 16 and 255), uint8(gc shr 8 and 255), uint8(gc and 255))
  let uc = st.getInt("pref.guideColor", -1)
  if uc >= 0: viewPrefs.guideColor = color(uint8(uc shr 16 and 255), uint8(uc shr 8 and 255), uint8(uc and 255))
  let gw = st.getInt("pref.gamutColor", -1)
  if gw >= 0: gamutColor = 0xFF000000'u32 or uint32(gw)
  applyPrefs()

proc savePrefs() =
  ## Preferences into the settings file (with the look).
  var st = loadSettings(AppData)
  let p = prefs
  st["pref.interp"] = $p.interp
  st["pref.zoomResizes"] = $p.zoomResizes
  st["pref.zoomCenter"] = $p.zoomCenter
  st["pref.docWindows"] = $(not p.docTabs)
  st["pref.optionsBar"] = $p.optionsBar
  st["pref.history"] = $p.history
  st["pref.autosave"] = $p.autosave
  st["pref.session"] = $p.session
  st["pref.bgSave"] = $p.bgSave
  st["pref.recent"] = $p.recent
  st["pref.lowerExt"] = $p.lowerExt
  st["pref.psdComposite"] = $p.psdComposite
  st["pref.memory"] = $p.memory
  st["pref.threads"] = $p.threads
  st["pref.gpu"] = $p.gpu
  st["pref.scratch"] = p.scratch
  st["pref.paintCursor"] = $p.paintCursor
  st["pref.crosshair"] = $p.crosshair
  st["pref.smartGuides"] = $smartGuidesOn
  st["pref.pixelGrid"] = $pixelGridOn
  st["pref.dynamicSpelling"] = $dynamicSpelling
  st["pref.autoSelectGroup"] = $moveAutoGroup
  st["pref.otherCursor"] = $p.otherCursor
  st["pref.printRes"] = $p.printRes
  st["pref.screenRes"] = $p.screenRes
  st["pref.smartQuotes"] = $p.smartQuotes
  st["pref.lorem"] = p.lorem
  st["pref.layerSizes"] = $p.layerSizes
  st["pref.workingSpace"] = $p.workingSpace
  st["pref.embed"] = $p.embedProfile
  st["pref.keyset"] = $p.keySet
  st["pref.toolcols"] = $p.toolCols
  st["pref.toolhidden"] = p.toolHidden
  st["pref.taskbar"] = $p.taskBar
  st["pref.legacyxf"] = $p.legacyXf
  st["pref.legacynew"] = $p.legacyNew
  st["pref.language"] = (if p.language == 1: "ar" else: "en")
  storeKeymap(st, keymap)
  st["pref.reset"] = $p.resetOnQuit
  st["color.profiles"] = $profilePolicy
  st["color.cmykIntent"] = $cmykIntent
  st["color.cmykBpc"] = $cmykBpc
  st["pref.checkerSize"] = $viewPrefs.checkerSize
  st["pref.checkerColors"] = $viewPrefs.checkerColors
  st["pref.rulerUnit"] = $viewPrefs.rulerUnit
  st["pref.gridUnit"] = $viewPrefs.gridUnit
  st["pref.gridStyle"] = $viewPrefs.gridStyle
  st["pref.guideStyle"] = $viewPrefs.guideStyle
  st["pref.gridEvery"] = $viewPrefs.gridEvery
  st["pref.gridSub"] = $viewPrefs.gridSub
  st["pref.wheelZooms"] = $viewPrefs.wheelZooms
  template rgb(c: Color): int = (int(c.r) shl 16) or (int(c.g) shl 8) or int(c.b)
  st["pref.gridColor"] = $rgb(viewPrefs.gridColor)
  st["pref.guideColor"] = $rgb(viewPrefs.guideColor)
  st["pref.gamutColor"] = $(int(gamutColor and 0xFFFFFF))
  storeAppearance(st)
  discard saveSettings(AppData, st)

# ---- the pages ---------------------------------------------------------------------------------------

proc unitNames(): seq[string] =
  for u in RulerUnit: result.add $u

proc gridPrefsRows() =
  ## The grid's settings (Preferences › Guides, Grid & Slices; View › Grid Settings).
  form 0:
    field "Gridline Every:":
      row:
        var every = viewPrefs.gridEvery
        if numberEdit(every, decimals = 2, w = dp(70), lo = 0.01, hi = 30000): viewPrefs.gridEvery = every
        var u = ord(viewPrefs.gridUnit)
        if combo(unitNames(), u, w = dp(110)): viewPrefs.gridUnit = RulerUnit(u)
    field "Subdivisions:":
      var sub = viewPrefs.gridSub
      if spin(sub, 1, 64, w = dp(70)): viewPrefs.gridSub = sub
    field "Color:":
      row:
        var ci = colorIndex(viewPrefs.gridColor)
        var names: seq[string]
        for (n, _) in guideColors: names.add n
        names.add "Custom"
        var k = if ci >= 0: ci else: names.high
        if combo(names, k, w = dp(110)) and k < guideColors.len: viewPrefs.gridColor = guideColors[k][1]
        var c = argb(255, viewPrefs.gridColor.r.int, viewPrefs.gridColor.g.int, viewPrefs.gridColor.b.int)
        if colorWell(c, "prefgrid", w = dp(40)):
          viewPrefs.gridColor = color(uint8(c shr 16 and 255), uint8(c shr 8 and 255), uint8(c and 255))
    field "Style:":
      var s = ord(viewPrefs.gridStyle)
      if combo(["Lines", "Dashed Lines", "Dots"], s, w = dp(110)): viewPrefs.gridStyle = LineStyle(s)
  for o in docs:
    o.view.gridStep = 0                 # (the Preferences' grid in every window)

proc pageGeneral() =
  group("Image Interpolation"):
    combo(["Nearest Neighbor (hard edges)", "Bilinear", "Bicubic (smooth gradients)",
           "Lanczos (sharper)"], prefs.interp, w = dp(220))
  group("Options"):
    checkbox("Zoom Resizes Windows", prefs.zoomResizes)
    checkbox("Zoom Clicked Point to Center", prefs.zoomCenter)
    checkbox("Zoom with Scroll Wheel", viewPrefs.wheelZooms)
    checkbox("Reset Preferences on Quit", prefs.resetOnQuit)
    checkbox("Use Legacy \"New Document\" Interface", prefs.legacyNew)
  label("Preferences take effect at once; Reset Preferences on Quit brings back every default the " &
        "next time Retro Atelier starts.", color = ui.theme.gray)

proc applyLanguage() =
  ## The menus, panels and dialogs in the language chosen (Arabic: right to
  ## left, mirrored, as the usual Middle East version).
  if prefs.language == 1: setUiLanguage("ar", @toolkitArabic, @photoArabic)
  else: setUiLanguage("")

proc pageInterface() =
  group("Language"):
    row:
      label "Language:"
      if combo(["English", "العربية (Arabic, right to left)"], prefs.language, w = dp(240)):
        applyLanguage()
    label("Arabic: the menus, panels and dialogs in Arabic, laid out right to left; the image itself " &
          "keeps its left and right.", color = ui.theme.gray)
  appearanceSettings()

proc pageWorkspace() =
  group("Documents"):
    var m = if prefs.docTabs: 0 else: 1
    if radio("&Tabs, in all the room between the toolbar and the panels", m, 0): setDocMode(true)
    if radio("&Windows of their own (MDI), as in 1994", m, 1): setDocMode(false)
  group("Panels"):
    checkbox("Show the Options Bar", prefs.optionsBar)
    checkbox("Show the Contextual Task Bar", prefs.taskBar)
    var s = smoothScrolling
    if checkbox("Smooth Scrolling and Flick Panning", s): setSmoothScrolling(s)

proc pageTools() =
  group("Keyboard Shortcuts"):
    row:
      label "Set:"
      if combo(["Today's", "Retro Atelier 1994"], prefs.keySet, w = dp(220)):
        applyKeySet()
    label("(the menus follow: today's, or 1994's)", color = ui.theme.gray)
    if button("Keyboard Shortcuts...", w = dp(160)):
      keysWas = keymap
      keysOpen = true
  group("Free Transform"):
    checkbox("Use Legacy Free Transform (Shift keeps the proportions)", prefs.legacyXf)
  group("Zoom"):
    checkbox("Zoom with Scroll Wheel (Ctrl or Alt + the wheel: scroll)", viewPrefs.wheelZooms)
    checkbox("Zoom Clicked Point to Center", prefs.zoomCenter)
  group("Snapping"):
    checkbox("Snap to Guides", snapGuides)
    checkbox("Snap to Grid", snapGrid)
    checkbox("Snap to Document Bounds", snapBounds)
    checkbox("Smart Guides (a move lines up with the other layers; Ctrl held: free)", smartGuidesOn)
  group("Type"):
    checkbox("Use Smart Quotes", prefs.smartQuotes)

proc pageFiles() =
  group("File Saving Options"):
    row:
      label "Automatically Save Recovery Information Every:"
    var k = max(0, autosaveSteps.find(prefs.autosave))
    if combo(["Never", "1 Minute", "5 Minutes", "10 Minutes", "15 Minutes", "30 Minutes", "1 Hour"], k,
             w = dp(140)):
      prefs.autosave = autosaveSteps[k]
    checkbox("Save in Background (big documents)", prefs.bgSave)
    checkbox("Reopen Documents at Start (unsaved changes kept)", prefs.session)
    checkbox("File Extension in Lower Case", prefs.lowerExt)
  group("File Compatibility"):
    checkbox("Maximize PSD and PSB Compatibility (a merged picture in the file)", prefs.psdComposite)
  group("Recent Files"):
    row:
      label "Recent File List Contains:"
      spin(prefs.recent, 0, 30, w = dp(70))
      label "files"
    if button("Clear Recent File List", w = dp(170)):
      var st = loadSettings(AppData)
      st.addRecentFile("", 0)
      discard saveSettings(AppData, st)

proc pageMemory() =
  let phys = physicalMemory()
  let mb = proc (b: int64): string = $(b div (1024 * 1024)) & " MB"
  group("Memory Usage"):
    label("Memory in this device: " & mb(phys))
    label("In use now: " & mb(int64(memoryUsed())))
    row:
      label "Let Retro Atelier Use:"
      if slider(prefs.memory, 20, 90, w = dp(160), ticks = 0): applyMemory()
      label($prefs.memory & "% (" & mb(phys * prefs.memory div 100) & ")")
    label("Largest image: " & $(maxPixels div 1_000_000) & " million pixels; undo steps kept in " &
          "memory: " & mb(undoRamAll.int64) & ", all open images together (the rest go to the scratch " &
          "disk).", color = ui.theme.gray)
  group("History && Cache"):
    row:
      label "History States:"
      spin(prefs.history, 1, 1000, w = dp(80))
    checkbox("Show Each Layer's Size in the Layers Panel", prefs.layerSizes)
  group("Processor"):
    var t = prefs.threads
    var names = @["Automatic (" & $countProcessors() & " cores)"]
    for n in [1, 2, 4, 8, 16]: names.add $n & (if n == 1: " thread" else: " threads")
    var k = if t <= 0: 0 else: max(0, [1, 2, 4, 8, 16].find(t) + 1)
    row:
      label "Use:"
      if combo(names, k, w = dp(170)): prefs.threads = if k == 0: 0 else: [1, 2, 4, 8, 16][k - 1]
    label("(takes effect when Retro Atelier starts again)", color = ui.theme.gray)
  group("Graphics Processor Settings"):
    label("Detected: " & gpuDescription())
    var useGpu = prefs.gpu != 2
    if checkbox("Use Graphics Processor", useGpu):
      prefs.gpu = if useGpu: 0 else: 2
      setGpuMode(GpuMode(prefs.gpu))
    if useGpu:
      var k = prefs.gpu
      row:
        label "When to use it:"
        if combo(["Automatic (a real GPU only)", "Always (a software one too)"], k, w = dp(220)):
          prefs.gpu = k
          setGpuMode(GpuMode(k))
    label("With the GPU, zooming and scrolling the picture and drawing the window cost the " &
          "processor nothing; without it, everything is drawn on the processor's cores.",
          color = ui.theme.gray)

proc pageScratch() =
  group("Scratch Disk"):
    label("Old undo steps of big images go here, out of memory.")
    let dir = if prefs.scratch.len > 0: prefs.scratch else: defaultScratch
    label("Folder: " & dir)
    let (free, total) = diskSpace(if dirExists(dir): dir else: getTempDir())
    if total > 0:
      label("Free: " & $(free div (1024 * 1024 * 1024)) & " GB of " & $(total div (1024 * 1024 * 1024)) & " GB")
    row:
      if button("Choose...", w = dp(90)):
        scratchPicked = dir
        scratchPick = true
      if button("Use the Default", w = dp(120), enabled = prefs.scratch.len > 0): prefs.scratch = ""

proc pageCursors() =
  row([-1, -1]):
    col:
      group("Painting Cursors"):
        radio("Standard", prefs.paintCursor, 0)
        radio("Precise", prefs.paintCursor, 1)
        radio("Normal Brush Tip", prefs.paintCursor, 2)
        radio("Full Size Brush Tip", prefs.paintCursor, 3)
        checkbox("Show Crosshair in Brush Tip", prefs.crosshair, enabled = prefs.paintCursor >= 2)
    col:
      group("Other Cursors"):
        radio("Standard", prefs.otherCursor, 0)
        radio("Precise", prefs.otherCursor, 1)
  label("Normal Brush Tip: the outline where a soft brush paints at least half; Full Size: all of it.",
        color = ui.theme.gray)

proc pageTransparency() =
  group("Transparency Settings"):
    form 0:
      field "Grid Size:":
        var s = ord(viewPrefs.checkerSize)
        if combo(["None", "Small", "Medium", "Large"], s, w = dp(110)): viewPrefs.checkerSize = CheckerSize(s)
      field "Grid Colors:":
        var c = ord(viewPrefs.checkerColors)
        var names: seq[string]
        for e in CheckerColors: names.add $e
        if combo(names, c, w = dp(110)): viewPrefs.checkerColors = CheckerColors(c)
    # (a sample of the checkerboard)
    let r = place(dp(96), dp(48))
    let (c0, c1) = checkerPair(viewPrefs.checkerColors)
    let n = if viewPrefs.checkerSize == ckNone: 0 else: 1 shl checkerShift(viewPrefs.checkerSize)
    if n == 0: fill(r, colorOf(c0))
    else:
      var y = 0
      while y < r.h:
        var x = 0
        while x < r.w:
          fill(rect(r.x + x, r.y + y, min(n, r.w - x), min(n, r.h - y)),
               colorOf(if ((x div n) + (y div n)) mod 2 == 0: c0 else: c1))
          x += n
        y += n
    box(r, ui.theme.frame)
  group("Gamut Warning"):
    row:
      label "Color:"
      colorWell(gamutColor, "prefgamut", w = dp(40))

proc pageUnits() =
  group("Units"):
    form 0:
      field "Rulers:":
        var u = ord(viewPrefs.rulerUnit)
        if combo(unitNames(), u, w = dp(130)): viewPrefs.rulerUnit = RulerUnit(u)
  group("New Document Preset Resolutions"):
    form 0:
      field "Print Resolution:":
        row:
          intEdit(prefs.printRes, w = dp(70), lo = 1, hi = 9999)
          label "pixels/inch"
      field "Screen Resolution:":
        row:
          intEdit(prefs.screenRes, w = dp(70), lo = 1, hi = 9999)
          label "pixels/inch"

proc pageGuides() =
  group("Guides"):
    form 0:
      field "Color:":
        row:
          var names: seq[string]
          for (n, _) in guideColors: names.add n
          names.add "Custom"
          let ci = colorIndex(viewPrefs.guideColor)
          var k = if ci >= 0: ci else: names.high
          if combo(names, k, w = dp(110)) and k < guideColors.len: viewPrefs.guideColor = guideColors[k][1]
          var c = argb(255, viewPrefs.guideColor.r.int, viewPrefs.guideColor.g.int, viewPrefs.guideColor.b.int)
          if colorWell(c, "prefguide", w = dp(40)):
            viewPrefs.guideColor = color(uint8(c shr 16 and 255), uint8(c shr 8 and 255), uint8(c and 255))
      field "Style:":
        var s = ord(viewPrefs.guideStyle)
        if combo(["Lines", "Dashed Lines", "Dots"], s, w = dp(110)): viewPrefs.guideStyle = LineStyle(s)
  group("Grid"):
    gridPrefsRows()

proc pageType() =
  group("Type Options"):
    checkbox("Use Smart Quotes", prefs.smartQuotes)
    label("Typed \" and ' become “ ” and ‘ ’ (and ’ inside a word).", color = ui.theme.gray)
  group("Placeholder Text"):
    editArea(prefs.lorem, lines = 3)
    label("Type > Paste Lorem Ipsum puts this in (empty: the Latin of Lorem Ipsum).", color = ui.theme.gray)

proc pageColor() =
  group("Working Space"):
    var names = @["None (untagged)"]
    for n in builtInProfileNames: names.add n
    row:
      label "RGB:"
      combo(names, prefs.workingSpace, w = dp(200))
    label("The profile of new documents.", color = ui.theme.gray)
  group("Color Management Policies"):
    var pp = ord(profilePolicy)
    row:
      label "Profiles of Pictures Opened:"
      if combo(["Convert to sRGB", "Keep Them", "Ignore Them"], pp, w = dp(150)): profilePolicy = ProfilePolicy(pp)
  group("Export"):
    checkbox("Embed Color Profiles in Exported Files", prefs.embedProfile)

proc keysDialog() =
  ## Edit > Keyboard Shortcuts: every command's keys, to change.
  if not keysOpen: return
  dialog(keysOpen, "Keyboard Shortcuts", 520):
    row:
      label "Set:"
      if combo(["Today's", "Retro Atelier 1994"], prefs.keySet, w = dp(240)):
        applyKeySet()
    var cmds = keymap.commandsOf
    for c in ["Free", "Skew", "Perspective", "Distort", "Warp", "Duplicate Layer", "Delete Layer", "Flatten Image",
              "Photomerge...", "Merge to HDR Pro...", "Batch...", "Fit Image...", "Color Range...",
              "Gaussian Blur...", "Unsharp Mask...", "Brush Settings", "Properties", "History"]:
      if c notin cmds: cmds.add c
    keymapEditor(keymap, cmds, dp(260))
    label("Click a command, then press its new keys in the box (Backspace: none).", color = ui.theme.gray)
    row:
      if button("Use Defaults", w = dp(110)):
        keymap.custom.setLen(0)
        applyKeySet()
      spring()
      if button("OK", isDefault = true, w = dp(80)):
        keysOpen = false
        applyKeySet()
        savePrefs()
      if button("Cancel", w = dp(80)):
        keysOpen = false
        keymap = keysWas
        applyKeySet()

proc prefsDialog() =
  if not prefsOpen: return
  var open = prefsOpen
  dialog(open, "Preferences", 640):
    var names: seq[string]
    for p in PrefPage: names.add $p
    let pageH = names.len * ItemH + 2 + 2 * (CtrlH + Gap)
    row([150, -1]):
      col:
        listbox(names, prefPage, rows = names.len, w = dp(150))
        if button("Prev", w = dp(70), enabled = prefPage > 0): dec prefPage
        if button("Next", w = dp(70), enabled = prefPage < names.high): inc prefPage
      pane(pageH):
        case PrefPage(clamp(prefPage, 0, names.high))
        of ppGeneral: pageGeneral()
        of ppInterface: pageInterface()
        of ppWorkspace: pageWorkspace()
        of ppTools: pageTools()
        of ppFiles: pageFiles()
        of ppPerformance: pageMemory()
        of ppScratch: pageScratch()
        of ppCursors: pageCursors()
        of ppTransparency: pageTransparency()
        of ppUnits: pageUnits()
        of ppGuides: pageGuides()
        of ppType: pageType()
        of ppColor: pageColor()
    row:
      if button("Reset All", w = dp(90)):
        prefs = DefaultPrefs
        viewPrefs = ViewPrefs(checkerSize: ckMedium, checkerColors: ccLight, rulerUnit: ruPixels,
                              gridEvery: 64, gridUnit: ruPixels, gridSub: 4, gridColor: color(128, 128, 128),
                              guideColor: color(0, 200, 255))
      spring()
      if button("OK", isDefault = true, w = dp(80)):
        applyPrefs()
        savePrefs()
        prefsOpen = false
      if button("Cancel", w = dp(80)):
        prefs = prefsWas.app
        viewPrefs = prefsWas.view
        restoreAppearance(loadSettings(AppData))
        prefsOpen = false
  if not open:                         # (closed by its box: as Cancel)
    prefs = prefsWas.app
    viewPrefs = prefsWas.view
    restoreAppearance(loadSettings(AppData))
    prefsOpen = false
  if prefsOpen: applyPrefs()           # (seen at once)
  if filePicker(scratchPick, scratchPicked, fmFolder, [], "Scratch Disk Folder"):
    if dirExists(scratchPicked): prefs.scratch = scratchPicked

proc startPrefs(page = -1) =
  prefsWas = (prefs, viewPrefs)
  if page >= 0: prefPage = page
  prefsOpen = true

# ---- what they change elsewhere ---------------------------------------------------------------------

proc afterZoom(dw: DocWin; x, y: float; byTool: bool) =
  ## After a zoom: the clicked point to the middle, the window to the
  ## image's new size (General: Zoom Clicked Point to Center, Zoom Resizes
  ## Windows).
  let d = dw.doc
  if byTool and prefs.zoomCenter: dw.view.centerOn(d, x, y)
  if prefs.zoomResizes and not dw.win.maximized and not prefs.docTabs:
    let a = mdiAreaRect("ws")
    if a.w <= 0: return
    let k = dw.view.scaleOf
    let iw = int(d.w.float * k / pxScale.float)
    let ih = int(d.h.float * k / pxScale.float)
    let (ww, wh) = mdiWindowSize(iw + SbW + 2, ih + SbW + 2)
    let right = if docsRight > 0: docsRight else: a.w - dp(250)
    dw.win.r.w = clamp(ww, dp(220), max(dp(220), right - dw.win.r.x - dp(4)))
    dw.win.r.h = clamp(wh, dp(160), max(dp(160), a.h - dw.win.r.y - dp(4)))
    dw.view.fitWanted = false

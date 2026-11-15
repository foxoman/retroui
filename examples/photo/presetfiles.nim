# (included by photo.nim) the usual preset files: swatches (.aco, .ase),
# curves (.acv), levels (.alv), gradients (.grd), patterns (.pat) and
# brushes (.abr) -- imported (Edit > Presets > Import Presets, the Swatches
# palette, the Curves and Levels dialogs, the Gradient Editor) and, but
# gradients and patterns, saved.

var
  presetPick = false
  presetSave = false
  presetPath = ""
  presetFor = pfAny
  presetReplace = false          ## Replace Swatches (else they are added)

proc presetPatterns(f: PresetFor; save: bool): seq[string] =
  case f
  of pfSwatches: (if save: @["*.aco", "*.ase"] else: @["*.aco", "*.ase"])
  of pfCurves: @["*.acv"]
  of pfLevels: @["*.alv"]
  of pfGradients: @["*.grd"]
  of pfPatterns: @["*.pat"]
  of pfAdjust: @["*.radj"]
  of pfAny: @["*.aco", "*.ase", "*.acb", "*.acv", "*.alv", "*.grd", "*.pat", "*.abr", "*.radj"]

proc startPresetFile(f: PresetFor; save = false; replace = false) =
  presetFor = f
  presetSave = save
  presetReplace = replace
  proc go() =
    let name = case f
               of pfSwatches: "Retro Atelier Swatches.aco"
               of pfCurves: "Curves.acv"
               of pfLevels: "Levels.alv"
               of pfAdjust: "Retro Atelier Presets.radj"
               else: ""
    presetPath = if save: picturesDir() / name else: picturesDir()
    presetPick = true
  if storageFor(go): go()

var booksLoaded = false

proc ensureBooksLoaded() =
  ## Color Libraries: the kit's own books, then the user's (.acb files
  ## imported before, kept in Retro Atelier's folder).
  if booksLoaded: return
  booksLoaded = true
  if colorBooks.len == 0: colorBooks = builtinBooks()
  let dir = dataDir(AppData) / "Color Books"
  if not dirExists(dir): return
  var files: seq[string]
  for kind, f in walkDir(dir):
    if kind == pcFile and f.toLowerAscii.endsWith(".acb"): files.add f
  files.sort()
  for f in files:
    try: colorBooks.add readAcb(readFile(f))
    except CatchableError: discard

proc usePattern(p: PatternPreset) =
  ## The pattern of the Pattern Stamp, Fill, the brushes' texture.
  pattern = p.px
  patternW = p.w
  patternH = p.h

proc importPresets(path: string) =
  ## A preset file read, as its kind says.
  let data = readFile(path)
  let kind = kindOf(path, data)
  let base = path.splitFile.name
  case kind
  of "aco", "ase":
    let got = if kind == "aco": readAco(data) else: readAse(data)
    if presetReplace: swatches.setLen(0)
    for (_, c) in got: swatches.add c
    status = $got.len & " swatches from " & path.extractFilename
  of "acb":
    # a color book (Pantone's, Toyo's, one of the user's): in Color Libraries,
    # and kept for the next start
    let b = readAcb(data)
    ensureBooksLoaded()
    colorBooks.add b
    try:
      let dir = dataDir(AppData) / "Color Books"
      createDir(dir)
      writeFile(dir / path.extractFilename, data)
    except CatchableError: discard
    status = b.title & ": " & $b.colors.len & " colors in Color Libraries (in the color picker)"
  of "radj":
    let got = loadPresetFile(path)
    for p in got:
      var q = p
      if q.category notin PresetCategories: q.category = "My Presets"
      myPresets.add q
    saveMyPresets()
    presetThumbs.key = ""
    status = $got.len & " adjustment presets from " & path.extractFilename & " (in Adjustments)"
  of "acv":
    let got = readAcv(data)
    for k in 0 ..< min(4, got.len): cv[k] = got[k]
    status = "Curves from " & path.extractFilename & (if adjOpen: "" else: " (for the next Curves)")
  of "alv":
    let got = readAlv(data)
    for k in 0 ..< min(4, got.len):
      lv[k] = Levels(inLo: got[k].inLo, inHi: got[k].inHi, gamma: got[k].gamma, outLo: got[k].outLo,
                     outHi: got[k].outHi)
    status = "Levels from " & path.extractFilename & (if adjOpen: "" else: " (for the next Levels)")
  of "grd":
    let got = readGrd(data)
    for g in got: userGradients.add g
    status = $got.len & " gradients from " & path.extractFilename & " (in the gradient lists)"
  of "pat":
    let got = readPat(data)
    for p in got: userPatterns.add p
    if got.len > 0: usePattern(got[0])
    status = $got.len & " patterns from " & path.extractFilename &
             (if got.len > 0: "; the pattern is now \"" & got[0].name & "\"" else: "")
  else:
    if path.toLowerAscii.endsWith(".abr"):
      let tips = readBrushes(path, data)
      for t in tips: presets.add BrushPreset(name: t.name, folder: base, tip: t)
      savePresets()
      status = $tips.len & " brushes from " & path.extractFilename
    else:
      raise newException(ValueError, "not a preset file Retro Atelier reads")

proc exportPresets(path: string) =
  var p = path
  case presetFor
  of pfSwatches:
    var sw: seq[Swatch]
    for i, c in swatches: sw.add ("Swatch " & $(i + 1), c)
    if p.splitFile.ext.len == 0: p.add ".aco"
    writeFile(p, if p.toLowerAscii.endsWith(".ase"): writeAse(sw) else: writeAco(sw))
    status = $sw.len & " swatches saved in " & p.extractFilename
  of pfCurves:
    if p.splitFile.ext.len == 0: p.add ".acv"
    var curves: seq[seq[CurvePoint]]
    for c in cv: curves.add(if c.len >= 2: c else: @[(0, 0), (255, 255)])
    writeFile(p, writeAcv(curves))
    status = "Curves saved in " & p.extractFilename
  of pfLevels:
    if p.splitFile.ext.len == 0: p.add ".alv"
    var recs: seq[LevelsRecord]
    for l in lv: recs.add LevelsRecord(inLo: l.inLo, inHi: l.inHi, outLo: l.outLo, outHi: l.outHi, gamma: l.gamma)
    writeFile(p, writeAlv(recs))
    status = "Levels saved in " & p.extractFilename
  of pfAdjust:
    if p.splitFile.ext.len == 0: p.add ".radj"
    savePresetFile(p, myPresets)
    status = $myPresets.len & " adjustment presets saved in " & p.extractFilename
  else: discard

proc presetFileDialog() =
  if filePicker(presetPick, presetPath, (if presetSave: fmSave else: fmOpen), presetPatterns(presetFor, presetSave),
                (if presetSave: "Save " else: "Load ") & $presetFor):
    try:
      if presetSave: exportPresets(presetPath)
      else: importPresets(presetPath)
    except CatchableError:
      status = "Could not " & (if presetSave: "save " else: "read ") & presetPath.extractFilename & ": " &
               getCurrentExceptionMsg()

proc presetItems() =
  ## Edit > Presets: import, and the patterns to choose from.
  submenu "P&resets":
    if menuItem("&Import Presets..."): startPresetFile(pfAny)
    if menuItem("Load &Swatches..."): startPresetFile(pfSwatches)
    if menuItem("Load Color &Book (.acb)..."): startPresetFile(pfAny)
    if menuItem("Save S&watches..."): startPresetFile(pfSwatches, save = true)
    if menuItem("Load &Gradients..."): startPresetFile(pfGradients)
    if menuItem("Load &Patterns..."): startPresetFile(pfPatterns)
    if userPatterns.len > 0:
      menuSeparator()
      for i, p in userPatterns:
        if i >= 20: break
        if menuItem("Pattern: " & p.name.replace("&", "&&"), checked = pattern == p.px): usePattern(p)

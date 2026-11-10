# Retro Photo -- included by photo.nim
#
# The panels editors have today that 1994 did not: Adjustments (with
# Properties), Histogram (with the Navigator and the History), Gradients
# and Patterns (with the Color and the Swatches), Styles, Shapes and Tool
# Presets, Layer Comps and Clone Source, Glyphs (with Character and
# Paragraph). Each a tab of a palette, drawn as 1994 drew palettes.

proc tileGrid(n, cw, ch: int; key: string;
              cell: proc (i: int; r: Rect; hit: Hit)) =
  ## `n` tiles of `cw` x `ch` in rows as wide as the palette.
  if n <= 0: return
  let gap = dp(3)
  let room = available()
  let cols = max(1, (room + gap) div (cw + gap))
  let rows = (n + cols - 1) div cols
  let r = place(room, rows * (ch + gap))
  for i in 0 ..< n:
    let tr = rect(r.x + (i mod cols) * (cw + gap), r.y + (i div cols) * (ch + gap), cw, ch)
    cell(i, tr, interact(idOf(key & ":" & $i), tr, focusable = false))

from std/unicode import runes, runeAt, toUTF8

# ---- Adjustments -------------------------------------------------------------------------------------------

const adjPanelButtons = [
  ("Brightness/Contrast", akBC), ("Levels", akLevels), ("Curves", akCurves), ("Exposure", akExposure),
  ("Vibrance", akVibrance), ("Hue/Saturation", akHS), ("Color Balance", akBalance), ("Black & White", akBlackWhite),
  ("Photo Filter", akPhotoFilter), ("Channel Mixer", akMixer), ("Color Lookup", akLookup), ("Invert", akLevels),
  ("Posterize", akPosterize), ("Threshold", akThreshold), ("Gradient Map", akGradMap),
  ("Selective Color", akSelective)]
  ## (the panel's buttons, in the usual order; Invert has no settings)

proc docSample(d: Doc; tw, th: int): Bitmap =
  ## The image as it looks, small (each pixel the mean of a few under it).
  d.updateComposite()
  let src = d.compPtr
  result = newBitmap(tw, th)
  for y in 0 ..< th:
    for x in 0 ..< tw:
      var r, g, b, n = 0
      for sy in 0 .. 1:
        for sx in 0 .. 1:
          let ix = clamp(((x * 2 + sx) * d.w + d.w div 2) div (tw * 2), 0, d.w - 1)
          let iy = clamp(((y * 2 + sy) * d.h + d.h div 2) div (th * 2), 0, d.h - 1)
          let p = src[iy * d.w + ix]
          let a = int(p shr 24)
          # (see-through: over white)
          r += (rOf(p) * a + 255 * (255 - a)) div 255
          g += (gOf(p) * a + 255 * (255 - a)) div 255
          b += (bOf(p) * a + 255 * (255 - a)) div 255
          inc n
      result.px[y * tw + x] = argb(255, r div n, g div n, b div n)

proc sampleScene(tw, th: int): Bitmap =
  ## (no image open: a little scene to show the presets on -- sky, sun,
  ## hills, a face's warm tones)
  result = newBitmap(tw, th)
  for y in 0 ..< th:
    for x in 0 ..< tw:
      let fy = y / th
      let fx = x / tw
      var c = argb(255, int(90 + 120 * fy), int(150 + 80 * fy), int(235 - 40 * fy))
      let hill = 0.62 + 0.12 * sin(fx * 6.0)
      if fy > hill: c = argb(255, int(60 + 50 * fx), int(140 - 40 * (fy - hill) * 3), int(50 + 20 * fx))
      let dx = fx - 0.72
      let dy = fy - 0.28
      if dx * dx + dy * dy < 0.012: c = argb(255, 250, 214, 120)
      let ex = fx - 0.26
      let ey = fy - 0.55
      if ex * ex * 1.6 + ey * ey < 0.02: c = argb(255, 222, 168, 140)
      result.px[y * tw + x] = c

proc shownPresets(): seq[int] =
  ## (the presets of the kind picked, as indexes into `allPresets`)
  let all = allPresets()
  for i, p in all:
    let cat = if presetCat == 0: "" elif presetCat <= PresetCategories.len: PresetCategories[presetCat - 1]
              else: "My Presets"
    if cat.len == 0 or p.category == cat or (cat == "My Presets" and p.category notin PresetCategories):
      result.add i

proc applyAdjPreset(p: AdjPreset) =
  ## The preset on the current image: its adjustment layers in a group over
  ## the current layer (undoable).
  let d = cur()
  if d == nil: return
  if d.mode notin colorModes:
    status = "Adjustment Presets are for color images (Image > Mode > RGB Color)"
    return
  d.layersChange("Adjustment Preset"): discard d.applyPreset(p)
  status = "\"" & p.name & "\": its layers are in a group of that name (change or hide each in Layers)"

proc adjustmentsBody() =
  ## Window > Adjustments, as the usual today: Adjustment Presets (looks
  ## made of adjustment layers, shown on the image), then the single
  ## adjustments (a click makes an adjustment layer over the current one;
  ## its settings in Properties).
  let d = cur()
  label("Adjustment Presets", bold = true)
  var cats = @["All"]
  for c in PresetCategories: cats.add c
  cats.add "My Presets"
  if combo(cats, presetCat, w = available()): discard
  let all = allPresets()
  let key = (if d != nil: $cast[uint](d) & "/" & $d.ver else: "none") & "/" & $all.len
  if presetThumbs.key != key and not ui.mouseDown:
    let base = if d != nil: docSample(d, 64, 48) else: sampleScene(64, 48)
    presetThumbs.pics.setLen(0)
    for p in all:
      let b = newBitmap(base.w, base.h)
      b.px = presetLook(base.px, base.w, base.h, p)
      presetThumbs.pics.add b
    presetThumbs.key = key
  let shown = shownPresets()
  if shown.len == 0:
    label(if presetCat > PresetCategories.len: "None yet: pick adjustment layers, then the panel's menu > " &
            "Save Adjustment Preset" else: "(none)", color = ui.theme.gray)
  let st = style(size = 0.85)
  tileGrid(shown.len, dp(64), dp(48) + FontH + dp(2), "adjpreset", proc (i: int; r: Rect; hit: Hit) =
    let k = shown[i]
    let p = all[k]
    let pr = rect(r.x, r.y, r.w, dp(48))
    if k < presetThumbs.pics.len: drawBitmap(pr, presetThumbs.pics[k])
    box(pr, if hit.showsHover: ui.theme.select else: ui.theme.frame)
    if hit.showsHover: box(inset(pr, 1), ui.theme.select)
    let nm = ellipsize(p.name, r.w, st)
    text(r.x + (r.w - textWidth(nm, st)) div 2, pr.y + pr.h + dp(1), nm, ui.theme.text, st)
    ui.lastRect = r
    tooltip(p.name & " (" & p.category & "): " & $p.steps.len & " adjustment layer" &
            (if p.steps.len == 1: "" else: "s"))
    if hit.clicked and d != nil: applyAdjPreset(p))
  space(dp(4))
  label("Single Adjustments", bold = true)
  if d == nil:
    label("(no image)", color = ui.theme.gray)
    return
  let half = (available() - Gap) div 2
  var k = 0
  while k < adjPanelButtons.len:
    row:
      for j in k ..< min(k + 2, adjPanelButtons.len):
        let (n, kind) = adjPanelButtons[j]
        let rgbOnly = kind in {akBalance, akHS, akSelective, akVibrance, akPhotoFilter, akBlackWhite, akMixer}
        let ok = d.mode in colorModes or not rgbOnly
        if button(n.replace("&", "&&"), w = half, enabled = ok):
          if n == "Invert":
            d.beginStep("New Adjustment Layer")
            discard d.newAdjustmentLayer(Adjustment(kind: "Invert"))
            d.endStep()
          else:
            startAdjustLayer(kind)
    k += 2
  row:
    let third = (available() - 2 * Gap) div 3
    for n in ["Clarity", "Dehaze", "Grain"]:
      if button(n, w = third, enabled = d.mode in colorModes): newAreaAdjustment(d, n)
  label("Alt+click a layer's eye in Layers to see it alone", color = ui.theme.gray)

proc adjustmentsMenu() =
  ## The Adjustments panel's menu: presets of your own, kept, shared,
  ## put on many files.
  let d = cur()
  var adj: seq[int]
  if d != nil:
    for i in d.pickedLayers:
      let L = d.layers[i]
      if L.adjust.kind.len > 0: adj.add i
      elif L.group:
        for j in d.blockStart(i) ..< i:
          if d.layers[j].adjust.kind.len > 0: adj.add j
  if menuItem("Save Adjustment Preset...", enabled = adj.len > 0):
    adjSaveDlg = (true, if d.current.group: d.current.name else: "My Look")
  if menuItem("Import Presets..."): startPresetFile(pfAdjust)
  if menuItem("Export My Presets...", enabled = myPresets.len > 0): startPresetFile(pfAdjust, save = true)
  if menuItem("Delete My Presets", enabled = myPresets.len > 0):
    myPresets.setLen(0)
    saveMyPresets()
    presetThumbs.key = ""
  menuSeparator()
  if menuItem("Batch: Apply a Preset to Files..."):
    presetBatch.open = true
    if presetBatch.src.len == 0: presetBatch.src = picturesDir()
    if presetBatch.dst.len == 0: presetBatch.dst = picturesDir() / "Edited"

proc adjPresetDialogs() =
  ## Save Adjustment Preset; the batch that puts a preset on many files.
  let d = cur()
  if adjSaveDlg.open:
    dialog(adjSaveDlg.open, "Save Adjustment Preset", 360):
      form 0:
        field "Name:": edit(adjSaveDlg.name)
      paragraph("The adjustment layers picked in Layers (or in the group picked) become a preset in " &
                "Adjustments > My Presets.", color = ui.theme.gray)
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80), enabled = adjSaveDlg.name.strip.len > 0) and d != nil:
          var idxs: seq[int]
          for i in d.pickedLayers:
            idxs.add i
            if d.layers[i].group:
              for j in d.blockStart(i) ..< i: idxs.add j
          let p = d.presetFromLayers(adjSaveDlg.name.strip, "My Presets", idxs)
          if p.steps.len > 0:
            myPresets.add p
            saveMyPresets()
            presetThumbs.key = ""
            presetCat = PresetCategories.len + 1
            status = "\"" & p.name & "\" is in Adjustments > My Presets"
          adjSaveDlg.open = false
        if button("Cancel", w = dp(80)): adjSaveDlg.open = false
  if presetBatch.open:
    let all = allPresets()
    dialog(presetBatch.open, "Apply a Preset to Files", 440):
      var names: seq[string]
      for p in all: names.add p.name & " (" & p.category & ")"
      form 0:
        field "Preset:": combo(names, presetBatch.preset, w = dp(260))
        field "From folder:": edit(presetBatch.src, w = dp(260))
        field "To folder:": edit(presetBatch.dst, w = dp(260))
        field "Save as:": combo(["JPEG (quality 92)", "PNG", "Same as each"], presetBatch.format, w = dp(160))
      if presetBatch.running:
        label("Done " & $presetBatch.done & " of " & $presetBatch.total, bold = true)
        progress(presetBatch.done / max(1, presetBatch.total))
      elif presetBatch.err.len > 0:
        paragraph(presetBatch.err, color = ui.theme.gray)
      row:
        spring()
        if button("Run", isDefault = true, w = dp(80), enabled = not presetBatch.running and dirExists(presetBatch.src)):
          presetBatch.files.setLen(0)
          for kind, f in walkDir(presetBatch.src):
            if kind == pcFile and f.splitFile.ext.toLowerAscii in [".jpg", ".jpeg", ".png", ".bmp", ".gif", ".webp"]:
              presetBatch.files.add f
          presetBatch.files.sort()
          presetBatch.total = presetBatch.files.len
          presetBatch.done = 0
          presetBatch.err = ""
          presetBatch.running = presetBatch.total > 0
          if not presetBatch.running: presetBatch.err = "No pictures in " & presetBatch.src
          else:
            try: createDir(presetBatch.dst)
            except CatchableError:
              presetBatch.running = false
              presetBatch.err = "Cannot make " & presetBatch.dst
        if button(if presetBatch.running: "Stop" else: "Close", w = dp(80)):
          if presetBatch.running: presetBatch.running = false
          else: presetBatch.open = false
    # (a file each frame: the window stays alive, Stop works)
    if presetBatch.running and presetBatch.done < presetBatch.files.len:
      let f = presetBatch.files[presetBatch.done]
      let ext = case presetBatch.format
                of 0: ".jpg"
                of 1: ".png"
                else: f.splitFile.ext.toLowerAscii
      let outP = presetBatch.dst / f.splitFile.name & ext
      try: applyPresetToFile(f, outP, all[clamp(presetBatch.preset, 0, all.high)])
      except CatchableError:
        presetBatch.err.add f.extractFilename & ": " & getCurrentExceptionMsg() & "\n"
      inc presetBatch.done
      if presetBatch.done >= presetBatch.files.len:
        presetBatch.running = false
        status = $presetBatch.done & " files with \"" & all[clamp(presetBatch.preset, 0, all.high)].name &
                 "\" in " & presetBatch.dst
      ui.redraw = true

# ---- Histogram ---------------------------------------------------------------------------------------------

var
  histPanel: tuple[d: Doc; ver, selVer, at: int; h: Histogram; chan, source: int]
    ## the counts shown (made again when the image changed and the mouse is up)

proc sampledHistogram(d: Doc; merged: bool): Histogram =
  ## The counts from at most a million pixels spread over the image (or the
  ## selection) -- quick on a big photo, the same shape.
  if merged: d.updateComposite()
  let r = d.clip(d.selBounds)
  if r.w <= 0 or r.h <= 0 or (not merged and d.layer.px.len != d.w * d.h): return
  let src = if merged: d.compPtr else: cast[ptr UncheckedArray[uint32]](addr d.layer.px[0])
  let step = max(1, int(sqrt(r.w.float * r.h.float / 1_000_000.0)))
  let hasSel = d.sel.len == d.w * d.h
  var y = r.y
  while y < r.y + r.h:
    var x = r.x
    while x < r.x + r.w:
      let i = y * d.w + x
      if not hasSel or d.sel[i] >= 128:
        let p = src[i]
        if (p shr 24) != 0:
          inc result.counts[0][lumaOf(p)]
          inc result.counts[1][rOf(p)]
          inc result.counts[2][gOf(p)]
          inc result.counts[3][bOf(p)]
          inc result.total
      x += step
    y += step

proc histogramBody() =
  ## Window > Histogram: the levels of the image (or of the layer), kept up
  ## as it changes; Mean, Std Dev, Median, Pixels under it.
  let d = cur()
  if d == nil:
    label("(no image)", color = ui.theme.gray)
    return
  row:
    label "Channel:"
    combo(["Colors", "Luminosity", "Red", "Green", "Blue"], histPanel.chan, w = dp(96))
  row:
    label "Source:"
    combo(["Entire Image", "Selected Layer"], histPanel.source, w = dp(120))
  let stale = histPanel.d != d or histPanel.ver != d.ver or histPanel.selVer != d.selVer
  if stale and not ui.mouseDown and ui.now - histPanel.at > 250:
    histPanel.h = d.sampledHistogram(histPanel.source == 0)
    histPanel.d = d
    histPanel.ver = d.ver
    histPanel.selVer = d.selVer
    histPanel.at = ui.now
  elif stale: wakeIn(300)
  let w = available()
  let h = dp(90)
  let r = place(w, h + 2)
  fill(r, ui.theme.window)
  box(r, ui.theme.frame)
  let hs = histPanel.h
  let cols = max(1, w - 2)
  # (each column: the most of the levels it covers; the top: the tallest)
  proc binOf(c, x: int): int =
    let v0 = x * 256 div cols
    let v1 = max(v0 + 1, (x + 1) * 256 div cols)
    for v in v0 ..< min(256, v1): result = max(result, hs.counts[c][v])
  let chans = if histPanel.chan == 0: @[1, 2, 3] else: @[histPanel.chan - 1]
  var bins = newSeq[array[4, int]](cols)
  var heights: seq[int]
  for x in 0 ..< cols:
    for c in chans:
      bins[x][c] = binOf(c, x)
      if bins[x][c] > 0: heights.add bins[x][c]
  # (the top: not the one spike -- a level most of the picture has -- but
  # nearly the tallest of the rest, as editors draw it; spikes run off)
  heights.sort()
  let top = if heights.len == 0: 1
            else: max(1, int(heights[int(0.94 * float(heights.high))].float * 1.15))
  for x in 0 ..< cols:
    for c in chans: bins[x][c] = min(bins[x][c], top)
  for x in 0 ..< cols:
    if histPanel.chan == 0:
      # the three channels in their colors (where all meet: gray)
      let hr = bins[x][1] * h div top
      let hg = bins[x][2] * h div top
      let hb = bins[x][3] * h div top
      var y = h
      while y > 0:
        let up = h - y + 1
        let cr = up <= hr
        let cg = up <= hg
        let cb = up <= hb
        if not (cr or cg or cb): break
        let c = if cr and cg and cb: color(110, 110, 110)
                else: color(if cr: 230 else: 40, if cg: 200 else: 40, if cb: 230 else: 40)
        vline(r.x + 1 + x, r.y + y, 1, c)
        dec y
    else:
      let c0 = histPanel.chan - 1
      let n = bins[x][c0] * h div top
      let c = case histPanel.chan
              of 2: color(200, 30, 30)
              of 3: color(30, 150, 30)
              of 4: color(30, 60, 200)
              else: ui.theme.text
      if n > 0: vline(r.x + 1 + x, r.y + 1 + h - n, n, c)
  let st = hs.stats(if histPanel.chan == 0: 0 else: histPanel.chan - 1)
  row:
    col:
      label("Mean: " & formatFloat(st.mean, ffDecimal, 2))
      label("Std Dev: " & formatFloat(st.sd, ffDecimal, 2))
    col:
      label("Median: " & $st.median)
      label("Pixels: " & $hs.total)
  if stale: label("(the image changed: up to date when the mouse is up)", color = ui.theme.gray)

# ---- Gradients ---------------------------------------------------------------------------------------------

var gradThumbs: tuple[key: string; bmps: seq[Bitmap]]

proc gradientsBody() =
  ## Window > Gradients: a click is the Gradient tool's gradient; a double
  ## click makes a gradient fill layer of it.
  let ps = gradientPresets()
  let cw = dp(40)
  let ch = dp(22)
  let key = $fg & "," & $bg & "," & $ps.len & "," & $cw
  if gradThumbs.key != key:
    gradThumbs.key = key
    gradThumbs.bmps.setLen(0)
    for p in ps: gradThumbs.bmps.add gradientStrip(p.stops, (cw - 2) * pxScale, (ch - 2) * pxScale)
  var picked = -1
  var made = -1
  tileGrid(ps.len, cw, ch, "gradpanel", proc (i: int; r: Rect; hit: Hit) =
    drawBitmap(inset(r, 1), gradThumbs.bmps[i])
    box(r, if gradPreset == i: ui.theme.text else: ui.theme.frame)
    if gradPreset == i: box(inset(r, -1), ui.theme.text)
    if hit.hover: ui.tip = ps[i].name
    if hit.clicked:
      picked = i
      if ui.clicks >= 2: made = i)
  if picked >= 0:
    gradPreset = picked
    status = "Gradient: " & ps[picked].name
  if made >= 0 and cur() != nil:
    gradPreset = made
    runCommand("Gradient...")
  row:
    if button("Gradient Tool", w = dp(110)):
      for g, grp in toolGroups:
        for k, it in grp.items:
          if it.tool == tGradient: pickTool(g, k)
    if button("Edit...", w = dp(70)): startGradientEditor(0, toolStops())

# ---- Patterns ----------------------------------------------------------------------------------------------

var
  basicPatterns: seq[PatternPreset]
  patThumbs: tuple[n, size: int; bmps: seq[Bitmap]]

proc makeBasicPatterns(): seq[PatternPreset] =
  ## A few patterns to start with, made here (no files): checks, stripes,
  ## dots, bricks, a grid, diagonals, a weave, paper grain.
  proc pat(name: string; w, h: int; f: proc (x, y: int): uint32): PatternPreset =
    result = PatternPreset(name: name, w: w, h: h, px: newSeq[uint32](w * h))
    for y in 0 ..< h:
      for x in 0 ..< w: result.px[y * w + x] = f(x, y)
  let ink = 0xFF404040'u32
  let paper = 0xFFF0F0F0'u32
  result.add pat("Checkerboard", 16, 16, proc (x, y: int): uint32 =
    if ((x div 8) + (y div 8)) mod 2 == 0: ink else: paper)
  result.add pat("Stripes", 8, 8, proc (x, y: int): uint32 = (if x < 4: ink else: paper))
  result.add pat("Dots", 12, 12, proc (x, y: int): uint32 =
    let dx = x - 6
    let dy = y - 6
    if dx * dx + dy * dy <= 9: ink else: paper)
  result.add pat("Bricks", 32, 16, proc (x, y: int): uint32 =
    let off = if y < 8: 0 else: 16
    if y mod 8 == 7 or (x + off) mod 32 == 31: 0xFFB0B0B0'u32 else: 0xFFB04A2A'u32)
  result.add pat("Grid", 16, 16, proc (x, y: int): uint32 = (if x == 0 or y == 0: ink else: paper))
  result.add pat("Diagonal", 12, 12, proc (x, y: int): uint32 = (if (x + y) mod 12 < 3: ink else: paper))
  result.add pat("Weave", 16, 16, proc (x, y: int): uint32 =
    let a = (x div 4 + y div 4) mod 2 == 0
    if a: (if y mod 4 == 0: ink else: 0xFF9A7A50'u32) else: (if x mod 4 == 0: ink else: 0xFFC8A878'u32))
  var seed = 12345'u32
  var grain = PatternPreset(name: "Paper Grain", w: 64, h: 64, px: newSeq[uint32](64 * 64))
  for i in 0 ..< grain.px.len:
    seed = seed * 1103515245'u32 + 12345'u32
    let v = 215 + int((seed shr 16) mod 40)
    grain.px[i] = 0xFF000000'u32 or uint32(v shl 16) or uint32(v shl 8) or uint32(v)
  result.add grain

proc allPatterns(): seq[PatternPreset] =
  if basicPatterns.len == 0: basicPatterns = makeBasicPatterns()
  basicPatterns & userPatterns

proc patternsBody() =
  ## Window > Patterns: a click is the pattern of Fill, the Pattern Stamp,
  ## the Paint Bucket and the brushes' texture; a double click makes a
  ## pattern fill layer.
  let ps = allPatterns()
  let cs = dp(30)
  if patThumbs.n != ps.len or patThumbs.size != cs:
    patThumbs = (ps.len, cs, newSeq[Bitmap]())
    for p in ps:
      let n = (cs - 2) * pxScale
      let b = newBitmap(n, n)
      for y in 0 ..< n:
        for x in 0 ..< n:
          b.px[y * n + x] = p.px[(y mod max(1, p.h)) * p.w + (x mod max(1, p.w))] or 0xFF000000'u32
      b.changed()
      patThumbs.bmps.add b
  var picked = -1
  var made = false
  tileGrid(ps.len, cs, cs, "patpanel", proc (i: int; r: Rect; hit: Hit) =
    drawBitmap(inset(r, 1), patThumbs.bmps[i])
    let on = pattern.len > 0 and pattern == ps[i].px
    box(r, if on: ui.theme.text else: ui.theme.frame)
    if on: box(inset(r, -1), ui.theme.text)
    if hit.hover: ui.tip = ps[i].name & " (" & $ps[i].w & " x " & $ps[i].h & ")"
    if hit.clicked:
      picked = i
      made = ui.clicks >= 2)
  if picked >= 0:
    usePattern(ps[picked])
    status = "Pattern: " & ps[picked].name
    if made and cur() != nil: runCommand("Pattern...")
  row:
    if button("New Fill Layer", w = dp(110), enabled = cur() != nil and pattern.len > 0): runCommand("Pattern...")
    if button("Define...", w = dp(70), enabled = cur() != nil and cur().hasSelection): runCommand("Define Pattern")

# ---- Styles -------------------------------------------------------------------------------------------------

template preset(name: string; body: untyped) =
  ## (a style of the list: its effects set in `body` with `eff`)
  block:
    var fx {.inject.} = LayerFx()
    body
    result.add (name, fx)

template eff(k: FxKind; body: untyped) =
  ## (an effect of the style, on, its settings changed in `body` as `e`)
  block:
    var e {.inject.} = defaultEffect(k)
    e.on = true
    body
    fx.fx[k] = e

proc stylePresets(): seq[tuple[name: string; fx: LayerFx]] =
  ## The styles to start with (the usual kinds: shadows, bevels, glows,
  ## metals, a sticker).
  preset "Default Style (None)": discard
  preset "Drop Shadow":
    eff fxDropShadow: discard
  preset "Soft Shadow":
    eff fxDropShadow:
      e.distance = 10; e.size = 24; e.opacity = 45
  preset "Inner Shadow":
    eff fxInnerShadow: discard
  preset "Outer Glow":
    eff fxOuterGlow:
      e.color = 0xFFFFE070'u32; e.size = 14; e.opacity = 80
  preset "Bevel":
    eff fxBevel: discard
  preset "Emboss":
    eff fxBevel: e.style = 2
  preset "Pillow":
    eff fxBevel: e.style = 3
  preset "Stroke":
    eff fxStroke:
      e.color = 0xFF000000'u32; e.size = 3
  preset "Sticker":
    eff fxStroke:
      e.color = 0xFFFFFFFF'u32; e.size = 6
    eff fxDropShadow:
      e.distance = 4; e.size = 8; e.opacity = 50
  preset "Gold":
    eff fxGradientOverlay:
      e.color = 0xFF8A5A10'u32; e.color2 = 0xFFFFE08A'u32; e.angle = 90
    eff fxBevel:
      e.size = 6; e.depth = 200
    eff fxDropShadow: e.opacity = 50
  preset "Chrome":
    eff fxGradientOverlay:
      e.color = 0xFF30405A'u32; e.color2 = 0xFFF2F6FA'u32; e.angle = 90
    eff fxBevel:
      e.size = 5; e.depth = 300
    eff fxStroke:
      e.color = 0xFF202020'u32; e.size = 1
  preset "Neon":
    eff fxColorOverlay: e.color = 0xFFE8FFFF'u32
    eff fxOuterGlow:
      e.color = 0xFF00E0FF'u32; e.size = 16; e.opacity = 90
    eff fxInnerGlow:
      e.color = 0xFF00B0FF'u32; e.size = 6
  preset "Glass":
    eff fxInnerGlow:
      e.color = 0xFFFFFFFF'u32; e.size = 10; e.opacity = 70
    eff fxBevel:
      e.size = 8; e.soften = 4
    eff fxDropShadow: e.opacity = 35
  preset "Button (1994)":
    eff fxBevel:
      e.size = 3; e.soften = 0; e.depth = 300
    eff fxStroke:
      e.color = 0xFF000000'u32; e.size = 1; e.style = 1
    eff fxColorOverlay: e.color = 0xFFC0C0C0'u32

var
  userStyles: seq[tuple[name: string; fx: LayerFx]]
  styleThumbs: tuple[n, size: int; bmps: seq[Bitmap]]

proc styleThumb(fx: LayerFx; n: int): Bitmap =
  ## A rounded square with the style, on white.
  let sd = newDoc(n, n, 0'u32)
  let L = sd.layers[0]
  let m = max(3, n div 6)
  let rad = n div 5
  for y in m ..< n - m:
    for x in m ..< n - m:
      let cx = if x < m + rad: m + rad elif x >= n - m - rad: n - m - rad - 1 else: x
      let cy = if y < m + rad: m + rad elif y >= n - m - rad: n - m - rad - 1 else: y
      if (x - cx) * (x - cx) + (y - cy) * (y - cy) <= rad * rad:
        L.px[y * n + x] = 0xFF7A8AA0'u32
  L.fx = fx
  sd.markAll()
  sd.updateComposite()
  result = newBitmap(n, n)
  let c = sd.compCopy
  for i in 0 ..< n * n: result.px[i] = blendPx(0xFFFFFFFF'u32, c[i], 255, bmNormal)
  result.changed()

proc stylesBody() =
  ## Window > Styles: a click puts the style on the current layer (Shift:
  ## adds its effects to the layer's); New Style keeps the current layer's.
  let all = stylePresets() & userStyles
  let cs = dp(32)
  if styleThumbs.n != all.len or styleThumbs.size != cs:
    styleThumbs = (all.len, cs, newSeq[Bitmap]())
    for s in all: styleThumbs.bmps.add styleThumb(s.fx, cs * pxScale)
  let d = cur()
  var picked = -1
  tileGrid(all.len, cs, cs, "stylepanel", proc (i: int; r: Rect; hit: Hit) =
    drawBitmap(r, styleThumbs.bmps[i])
    box(r, if hit.hover: ui.theme.text else: ui.theme.frame)
    if i == 0: hline(r.x + 2, r.y + r.h - 3, r.w - 4, color(220, 0, 0))
    if hit.hover: ui.tip = all[i].name
    if hit.clicked: picked = i)
  let ok = d != nil and not d.current.background and not d.current.group
  if picked >= 0 and ok:
    let L = d.current
    var fx = all[picked].fx
    if ShiftPressed in ui.mods:
      var mine = L.fx
      for k in FxKind:
        if fx.fx[k].on: mine.fx[k] = fx.fx[k]
      fx = mine
    d.stepOnce("Apply Style", proc () =
      L.fx = fx
      d.markAll())
  elif picked >= 0:
    status = "Styles go on a layer (not the Background): Layer > New > Layer from Background"
  row:
    if button("New Style", w = dp(90), enabled = ok and d.current.hasStyle):
      userStyles.add ("Style " & $(userStyles.len + 1), d.current.fx)
    if button("Clear", w = dp(60), enabled = ok and d.current.hasStyle):
      let L = d.current
      d.stepOnce("Clear Layer Style", proc () =
        L.fx = LayerFx()
        d.markAll())

# ---- Shapes -------------------------------------------------------------------------------------------------

var shapeSet = 0                    ## the Shapes panel's set (0: all of them)

proc shapesBody() =
  ## Window > Shapes: the custom shapes by set; a click picks the Custom
  ## Shape tool with that shape.
  let cs = dp(30)
  var picked = -1
  combo(@["All Shapes"] & @ShapeCategories, shapeSet, w = available())
  var shown: seq[int]
  for i, c in CustomShapes:
    if shapeSet == 0 or c.category == ShapeCategories[clamp(shapeSet - 1, 0, ShapeCategories.high)]: shown.add i
  tileGrid(shown.len, cs, cs, "shapepanel", proc (k: int; r: Rect; hit: Hit) =
    let i = shown[k]
    fill(r, ui.theme.window)
    let on = tool == tShape and shapeKind == 5 and customShape == i
    drawBitmap(inset(r, dp(3)), shapeThumb(i, (cs - dp(6)) * pxScale))
    box(r, if on: ui.theme.text else: ui.theme.frame)
    if on: box(inset(r, -1), ui.theme.text)
    if hit.hover: ui.tip = CustomShapes[i].name & " (" & CustomShapes[i].category & ")"
    if hit.clicked: picked = i)
  if picked >= 0:
    for g, grp in toolGroups:
      for k, it in grp.items:
        if it.tool == tShape and it.mode == 5: pickTool(g, k)
    customShape = picked
    status = "Custom Shape: " & CustomShapes[picked].name & " -- drag on the image"

# ---- Tool Presets ---------------------------------------------------------------------------------------------

var
  toolPresets: seq[tuple[name: string; t: Tool; o: ToolOpts; item: string]]
  toolPresetSel = 0
  toolPresetsOnly = true         ## Current Tool Only

proc toolPresetsBody() =
  ## Window > Tool Presets: a tool with its settings, kept to pick again.
  var shown: seq[int]
  var names: seq[string]
  for i, p in toolPresets:
    if toolPresetsOnly and p.t != tool: continue
    shown.add i
    names.add p.name
  if names.len == 0: names.add "(none yet: New keeps the tool as it is set)"
  let before = toolPresetSel
  listbox(names, toolPresetSel, rows = max(3, min(8, (remainingH() - 2 * CtrlH - 2 * Gap) div ItemH)))
  if (toolPresetSel != before or doubleClicked()) and toolPresetSel in 0 .. shown.high:
    let p = toolPresets[shown[toolPresetSel]]
    var picked = false
    for g, grp in toolGroups:
      for k, it in grp.items:
        if it.name == p.item and not picked:
          pickTool(g, k)
          picked = true
    if not picked: selectTool(p.t)
    opts[p.t] = p.o
    status = "Tool preset: " & p.name
  checkbox("Current Tool Only", toolPresetsOnly)
  row:
    if button("New", w = dp(60)):
      var item = $tool
      let g = groupOf(tool)
      if g >= 0: item = toolGroups[g].items[shownItem(g)].name
      let base = item.replace(" Tool", "")
      var n = 1
      for p in toolPresets:
        if p.t == tool: inc n
      toolPresets.add (base & " " & $n, tool, opts[tool], item)
    if button("Delete", w = dp(60), enabled = toolPresetSel in 0 .. shown.high):
      toolPresets.delete(shown[toolPresetSel])
      toolPresetSel = max(0, toolPresetSel - 1)

# ---- Layer Comps --------------------------------------------------------------------------------------------

var
  compSel = 0
  compDlg: tuple[open: bool; edit: int; name, comment: string; vis, pos, app: bool]
    ## New Layer Comp / Layer Comp Options (`edit`: the comp, -1 a new one)

proc applyCompNow(d: Doc; k: int) =
  if k < 0 or k >= d.comps.len: return
  d.snapStep("Apply Layer Comp")
  d.applyComp(d.comps[k])
  d.endStep()
  status = "Layer comp: " & d.comps[k].name

proc layerCompsBody() =
  ## Window > Layer Comps: looks of the document kept by name -- which
  ## layers show, where they are, how they look (opacity, blend mode,
  ## style) -- to go back and forth between; kept in the document.
  let d = cur()
  if d == nil:
    label("(no image)", color = ui.theme.gray)
    return
  var names = @["Last Document State"]
  for c in d.comps:
    var marks = ""
    if c.visibility: marks.add "V"
    if c.position: marks.add "P"
    if c.appearance: marks.add "A"
    names.add c.name & "  [" & marks & "]"
  compSel = clamp(compSel, 0, names.high)
  let before = compSel
  listbox(names, compSel, rows = max(3, min(8, (remainingH() - 2 * CtrlH - 2 * Gap) div ItemH)))
  if compSel != before and compSel >= 1: d.applyCompNow(compSel - 1)
  if compSel >= 1 and compSel <= d.comps.len and d.comps[compSel - 1].comment.len > 0:
    label(d.comps[compSel - 1].comment, color = ui.theme.gray)
  row:
    if toolButton("<", "Apply Previous", enabled = d.comps.len > 0):
      compSel = if compSel <= 1: d.comps.len else: compSel - 1
      d.applyCompNow(compSel - 1)
    if toolButton(">", "Apply Next", enabled = d.comps.len > 0):
      compSel = if compSel >= d.comps.len: 1 else: compSel + 1
      d.applyCompNow(compSel - 1)
    if button("New...", w = dp(56)):
      compDlg = (true, -1, "Layer Comp " & $(d.comps.len + 1), "", true, true, true)
    if button("Update", w = dp(60), enabled = compSel >= 1 and compSel <= d.comps.len):
      let c = d.comps[compSel - 1]
      d.comps[compSel - 1] = d.captureComp(c.name, c.visibility, c.position, c.appearance, c.comment)
      d.modified = true
      status = "Updated " & c.name
  row:
    if button("Options...", w = dp(70), enabled = compSel >= 1 and compSel <= d.comps.len):
      let c = d.comps[compSel - 1]
      compDlg = (true, compSel - 1, c.name, c.comment, c.visibility, c.position, c.appearance)
    if button("Delete", w = dp(56), enabled = compSel >= 1 and compSel <= d.comps.len):
      d.comps.delete(compSel - 1)
      compSel = 0
      d.modified = true

proc layerCompDialog() =
  if not compDlg.open: return
  let d = cur()
  if d == nil:
    compDlg.open = false
    return
  dialog(compDlg.open, if compDlg.edit < 0: "New Layer Comp" else: "Layer Comp Options", 380):
    form(0):
      field "Name:": edit compDlg.name
      field "Apply To Layers:":
        col:
          checkbox("Visibility", compDlg.vis)
          checkbox("Position", compDlg.pos)
          checkbox("Appearance (Layer Style)", compDlg.app)
      field "Comment:": edit compDlg.comment
    case buttonRow(["OK", "Cancel"])
    of 1:
      if compDlg.edit < 0:
        d.comps.add d.captureComp(compDlg.name, compDlg.vis, compDlg.pos, compDlg.app, compDlg.comment)
        compSel = d.comps.len
      elif compDlg.edit < d.comps.len:
        d.comps[compDlg.edit].name = compDlg.name
        d.comps[compDlg.edit].comment = compDlg.comment
        d.comps[compDlg.edit].visibility = compDlg.vis
        d.comps[compDlg.edit].position = compDlg.pos
        d.comps[compDlg.edit].appearance = compDlg.app
      d.modified = true
      compDlg.open = false
    of 2: compDlg.open = false
    else: discard

# ---- Clone Source -------------------------------------------------------------------------------------------

var
  cloneSlots: array[5, tuple[set: bool; x, y: float; doc: Doc]]
  cloneSlot = 0

proc cloneSourceBody() =
  ## Window > Clone Source: five sources for the Clone Stamp and the
  ## Healing Brush (Alt+click sets the one picked); a click on another
  ## takes it back up.
  if stampSrc.set and stampSrc != cloneSlots[cloneSlot]: cloneSlots[cloneSlot] = stampSrc
  row:
    for i in 0 .. 4:
      let s = cloneSlots[i]
      if toolButton($(i + 1), (if s.set: "Source " & $(i + 1) & ": " & s.doc.name else: "Source " & $(i + 1) & " (not set)"),
                    down = i == cloneSlot):
        cloneSlot = i
        if cloneSlots[i].set:
          stampSrc = cloneSlots[i]
  let s = cloneSlots[cloneSlot]
  if s.set and s.doc != nil:
    label("Source: " & s.doc.name)
    label("X: " & $int(s.x) & " px   Y: " & $int(s.y) & " px")
  else:
    label("Alt+click with the Clone Stamp to set it", color = ui.theme.gray)
  row:
    if button("Clone Stamp", w = dp(100)):
      for g, grp in toolGroups:
        for k, it in grp.items:
          if it.name == "Clone Stamp Tool": pickTool(g, k)
    if button("Clear", w = dp(60), enabled = s.set):
      cloneSlots[cloneSlot].set = false
      stampSrc.set = false

# ---- Glyphs -------------------------------------------------------------------------------------------------

const glyphSets = [
  ("Punctuation", "‘’“”‚„«»‹›–—…•·¡¿§¶†‡‰′″"),
  ("Symbols", "©®™°±×÷¢£¥€¤¦µ¹²³¼½¾ªº"),
  ("Arrows", "←↑→↓↔↕↖↗↘↙⇐⇑⇒⇓⇔"),
  ("Math", "∞≈≠≤≥√∑∏∫∂∆∇πΩ∈∩∪⊂⊃∀∃¬∧∨"),
  ("Shapes", "■□▪▫▲△▶▷▼▽◀◁◆◇○●◎★☆♠♣♥♦"),
  ("Latin", "ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖØÙÚÛÜÝÞßàáâãäåæçèéêëìíîïðñòóôõöøùúûüýþÿ"),
  ("Greek", "ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩαβγδεζηθικλμνξοπρστυφχψω"),
  ("Arabic", "ابتثجحخدذرزسشصضطظعغفقكلمنهوي٠١٢٣٤٥٦٧٨٩")]

var
  glyphSet = 0
  glyphRecent: seq[string]

proc glyphsBody() =
  ## Window > Glyphs: a click puts the character where the text is being
  ## typed (the Type tool first).
  row:
    label "Show:"
    var names: seq[string]
    for (n, _) in glyphSets: names.add n
    combo(names, glyphSet, w = dp(110))
  var cells: seq[string]
  for g in glyphRecent: cells.add g
  let recentN = cells.len
  let chars = glyphSets[clamp(glyphSet, 0, glyphSets.high)][1]
  for r in runes(chars): cells.add r.toUTF8
  let cs = dp(22)
  var picked = ""
  tileGrid(cells.len, cs, cs, "glyphs" & $glyphSet, proc (i: int; r: Rect; hit: Hit) =
    fill(r, if hit.down: ui.theme.select elif i < recentN: mixColor(ui.theme.window, ui.theme.face, 0.5)
            else: ui.theme.window)
    box(r, ui.theme.frame)
    let s = cells[i]
    text(r.x + (r.w - textWidth(s)) div 2, r.y + (r.h - FontH) div 2, s,
         if hit.down: ui.theme.selectText else: ui.theme.text)
    if hit.hover: ui.tip = "U+" & toHex(int(s.runeAt(0)), 4)
    if hit.clicked: picked = s)
  if picked.len > 0:
    if te.on:
      insertTyped(picked)
      let k = glyphRecent.find(picked)
      if k >= 0: glyphRecent.delete(k)
      glyphRecent.insert(picked, 0)
      if glyphRecent.len > 10: glyphRecent.setLen(10)
    else:
      status = "Click in the image with the Type tool (T) first, then on a glyph"
  if not te.on: label("Glyphs go where the Type tool is typing", color = ui.theme.gray)

# ---- Libraries -----------------------------------------------------------------------------------------------

type LibItem = object
  kind: string                 ## "color", "char", "style", "graphic"
  name: string
  color: uint32
  char: CharStyle
  fx: LayerFx
  file: string                 ## (a graphic: its PNG, in the library's folder)

var
  libs: seq[tuple[name: string; items: seq[LibItem]]]
  libCur = 0
  libLoaded = false
  libSel = -1
  libThumbs: Table[string, Bitmap]       ## (graphics and styles: their pictures)
  libNew: tuple[open: bool; name: string]

proc libDir(): string = dataDir(AppName) / "Libraries"

proc libFile(name: string): string =
  var safe = ""
  for c in name:
    safe.add(if c.isAlphaNumeric or c in {' ', '-', '_'}: c else: '_')
  libDir() / (safe.strip & ".json")

proc saveLibrary(k: int) =
  if k < 0 or k >= libs.len: return
  var a = newJArray()
  for it in libs[k].items:
    var j = %*{"kind": it.kind, "name": it.name}
    case it.kind
    of "color": j["color"] = %int(it.color)
    of "char": j["char"] = it.char.toJson
    of "style": j["style"] = it.fx.toJson
    of "graphic": j["file"] = %it.file
    else: discard
    a.add j
  try:
    createDir(libDir())
    writeFile(libFile(libs[k].name), $(%*{"name": libs[k].name, "items": a}))
  except CatchableError: status = "Could not keep the library: " & getCurrentExceptionMsg()

proc loadLibraries() =
  libLoaded = true
  libs.setLen(0)
  if dirExists(libDir()):
    var files: seq[string]
    for kind, f in walkDir(libDir()):
      if kind == pcFile and f.endsWith(".json"): files.add f
    files.sort()
    for f in files:
      try:
        let j = parseJson(readFile(f))
        var items: seq[LibItem]
        for ij in j{"items"}.getElems:
          var it = LibItem(kind: ij{"kind"}.getStr, name: ij{"name"}.getStr)
          case it.kind
          of "color": it.color = uint32(ij{"color"}.getBiggestInt) or 0xFF000000'u32
          of "char": it.char = charStyleFrom(ij{"char"})
          of "style": it.fx = layerFxFrom(ij{"style"})
          of "graphic": it.file = ij{"file"}.getStr
          else: continue
          items.add it
        libs.add (j{"name"}.getStr(f.splitFile.name), items)
      except CatchableError: discard
  if libs.len == 0:
    libs.add ("My Library", newSeq[LibItem]())
  libCur = clamp(libCur, 0, libs.high)

proc libAdd(it: LibItem) =
  libs[libCur].items.add it
  libSel = libs[libCur].items.high
  saveLibrary(libCur)
  status = "Added to " & libs[libCur].name & ": " & it.name

proc addGraphic(d: Doc) =
  ## The current layer (what is selected of it) kept as a graphic.
  let L = d.current
  if L.group or L.px.len != d.w * d.h: return
  var b = if d.hasSelection: d.selBounds else: d.contentBounds(L)
  b = d.clip(b)
  if b.w <= 0 or b.h <= 0:
    status = "The layer is empty"
    return
  let bm = newBitmap(b.w, b.h)
  for y in 0 ..< b.h:
    for x in 0 ..< b.w:
      let i = (b.y + y) * d.w + b.x + x
      var p = L.px[i]
      if d.hasSelection: p = withAlpha(p, aOf(p) * int(d.sel[i]) div 255)
      bm.px[y * b.w + x] = p
  let file = "graphic-" & $getTime().toUnix & "-" & $libs[libCur].items.len & ".png"
  try:
    createDir(libDir())
    writeFile(libDir() / file, encodePng(bm))
    libAdd LibItem(kind: "graphic", name: L.name, file: file)
  except CatchableError: status = "Could not keep the graphic: " & getCurrentExceptionMsg()

proc placeGraphic(d: Doc; it: LibItem) =
  ## A graphic of the library as a new layer, in the middle.
  let b = try: decodePng(readFile(libDir() / it.file)) except CatchableError: nil
  if b == nil:
    status = "The graphic's file is gone"
    return
  d.layersChange("Place Graphic"):
    let L = d.addLayer(it.name)
    let x0 = (d.w - b.w) div 2
    let y0 = (d.h - b.h) div 2
    for y in 0 ..< b.h:
      for x in 0 ..< b.w:
        let xx = x0 + x
        let yy = y0 + y
        if xx >= 0 and yy >= 0 and xx < d.w and yy < d.h: L.px[yy * d.w + xx] = b.px[y * b.w + x]
    inc L.ver
    d.markAll()

proc useLibItem(it: LibItem) =
  let d = cur()
  case it.kind
  of "color":
    fg = it.color
    status = "Foreground: " & it.name
  of "char":
    if te.on:
      let st = it.char
      restyleSel(proc (s: var CharStyle) = s = st)
    elif d != nil and d.current.isText:
      let st = it.char
      applyText("Character Style", proc (t: var TextData) =
        for sp in t.spans.mitems: sp.style = st)
    else: status = "Character styles go on type: pick a type layer, or type"
  of "style":
    if d != nil and not d.current.background and not d.current.group:
      let L = d.current
      let fx = it.fx
      d.stepOnce("Apply Style", proc () =
        L.fx = fx
        d.markAll())
    else: status = "Styles go on a layer (not the Background)"
  of "graphic":
    if d != nil: d.placeGraphic(it)
  else: discard

proc librariesBody() =
  ## Window > Libraries: colors, character styles, layer styles and
  ## graphics kept in libraries of one's own (on this device), for any
  ## document; a click uses one. "+" adds what is in use now.
  if not libLoaded: loadLibraries()
  let d = cur()
  row([-1, 0]):
    var names: seq[string]
    for l in libs: names.add l.name
    accessName(tr("Library"))
    if combo(names, libCur): libSel = -1
    if toolButton("New...", "A new library"): libNew = (true, "Library " & $(libs.len + 1))
  if libNew.open:
    row([-1, 0, 0]):
      accessName(tr("The new library's name"))
      edit libNew.name
      if toolButton("OK", "Make it") and libNew.name.strip.len > 0:
        libs.add (libNew.name.strip, newSeq[LibItem]())
        libCur = libs.high
        saveLibrary(libCur)
        libNew.open = false
      if toolButton("X", "Cancel"): libNew.open = false
  let items = libs[libCur].items
  if items.len == 0:
    paragraph("This library is empty. With \"+\": the foreground color, the type's character " &
              "style, the layer's style, or the layer itself as a graphic.", color = ui.theme.gray)
  var used = -1
  for (kind, title) in [("color", "Colors"), ("char", "Character Styles"), ("style", "Layer Styles"),
                        ("graphic", "Graphics")]:
    var idx: seq[int]
    for i, it in items:
      if it.kind == kind: idx.add i
    if idx.len == 0: continue
    label(title, bold = true)
    case kind
    of "color":
      tileGrid(idx.len, dp(22), dp(22), "lib:c", proc (k: int; r: Rect; hit: Hit) =
        let it = items[idx[k]]
        fill(r, colorOf(it.color))
        box(r, if idx[k] == libSel: ui.theme.select elif hit.hover: ui.theme.text else: ui.theme.frame)
        if hit.hover: ui.tip = it.name
        if hit.clicked:
          libSel = idx[k]
          used = idx[k])
    of "char":
      for i in idx:
        let it = items[i]
        let r = place(available(), CtrlH)
        let hit = interact(idOf("lib:t:" & $i), r, focusable = false)
        if i == libSel: fill(r, ui.theme.select)
        elif hit.hover: fill(r, hoverColor())
        let fam = if it.char.family.len > 0: it.char.family else: "Default"
        text(r.x + dp(4), r.y + (r.h - FontH) div 2, "Aa  " & fam & " " & $int(it.char.size) & " pt",
             if i == libSel: ui.theme.selectText else: ui.theme.text)
        if hit.clicked:
          libSel = i
          used = i
    else:
      let cs = dp(40)
      tileGrid(idx.len, cs, cs, "lib:" & kind, proc (k: int; r: Rect; hit: Hit) =
        let it = items[idx[k]]
        let key = kind & ":" & it.name & ":" & it.file & ":" & $idx[k]
        if key notin libThumbs:
          var tb: Bitmap = nil
          if kind == "style": tb = styleThumb(it.fx, cs * pxScale)
          else:
            try: tb = thumbnail(decodePng(readFile(libDir() / it.file)), cs * pxScale, cs * pxScale)
            except CatchableError: tb = nil
          libThumbs[key] = tb
        fill(r, ui.theme.window)
        let b = libThumbs[key]
        if b != nil: drawFit(inset(r, 2), b, enlarge = kind == "style")
        box(r, if idx[k] == libSel: ui.theme.select elif hit.hover: ui.theme.text else: ui.theme.frame)
        if hit.hover: ui.tip = it.name
        if hit.clicked:
          libSel = idx[k]
          used = idx[k])
  if used >= 0: useLibItem(items[used])
  row:
    case menuButton("+ Add", ["Foreground Color", "Character Style", "Layer Style", "Graphic (the layer)"],
                    w = dp(70))
    of 0:
      libAdd LibItem(kind: "color", name: "#" & toHex(int(fg and 0xFFFFFF'u32), 6), color: fg)
    of 1:
      if te.on or (d != nil and d.current.isText):
        let st = if te.on: te.style else: d.current.text.styleAt(0)
        libAdd LibItem(kind: "char", name: (if st.family.len > 0: st.family else: "Default") & " " &
                       $int(st.size) & " pt", char: st)
      else: status = "Pick a type layer (or type) first"
    of 2:
      if d != nil and d.current.hasStyle:
        libAdd LibItem(kind: "style", name: d.current.name & " style", fx: d.current.fx)
      else: status = "The current layer has no style"
    of 3:
      if d != nil and not d.current.group: d.addGraphic()
    else: discard
    if button("Delete", w = dp(60), enabled = libSel >= 0 and libSel < items.len):
      libs[libCur].items.delete(libSel)
      libSel = -1
      libThumbs.clear()
      saveLibrary(libCur)

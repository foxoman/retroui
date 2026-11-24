# Retro Atelier -- included by photo.nim
#
# Today's today's editors features made offline (retroui/photocc): Layer Cleanup,
# Harmonize with a shadow, Artboards to Files.

proc exportSlices(d: Doc) =
  ## File > Export > Slices to Files: each slice of the image as it looks
  ## (all its layers), a PNG, beside the document (or in Pictures).
  let base = if d.path.len > 0: d.path.parentDir else: picturesDir()
  let dir = base / (d.name & " Slices")
  try:
    createDir(dir)
    d.updateComposite()
    let all = d.toBitmap
    var n = 0
    for r0 in slicesOf(d):
      let r = d.clip(r0)
      if r.w <= 0 or r.h <= 0: continue
      inc n
      var b = Bitmap(w: r.w, h: r.h, px: newSeq[uint32](r.w * r.h))
      for y in 0 ..< r.h:
        copyMem(addr b.px[y * r.w], unsafeAddr all.px[(r.y + y) * d.w + r.x], r.w * 4)
      discard b.savePng(dir / (d.name & "_" & align($n, 2, '0') & ".png"))
    status = $n & " slices saved in " & dir
  except CatchableError:
    status = "Could not save the slices: " & getCurrentExceptionMsg()

proc slicesFromGuides(d: Doc) =
  ## Slices From Guides: one slice for each part the guides cut the image
  ## into (they replace the image's slices).
  var xs = @[0]
  var ys = @[0]
  for g in d.guides:
    let v = int(round(g.pos))
    if g.vertical:
      if v > 0 and v < d.w and v notin xs: xs.add v
    elif v > 0 and v < d.h and v notin ys: ys.add v
  xs.add d.w
  ys.add d.h
  xs.sort()
  ys.sort()
  var k = 0
  while k < slices.len:
    if slices[k].d == d: slices.delete(k) else: inc k
  for j in 0 ..< ys.high:
    for i in 0 ..< xs.high:
      slices.add (d, rect(xs[i], ys[j], xs[i + 1] - xs[i], ys[j + 1] - ys[j]))
  status = $((xs.len - 1) * (ys.len - 1)) & " slices from the guides"

proc noteDialog() =
  ## The Note tool's note: written, read, deleted.
  if not noteDlg.on: return
  let at = noteDlg.idx
  if at notin 0 .. notes.high:
    noteDlg.on = false
    return
  var keep = true
  dialog(noteDlg.on, "Note", 360):
    label "&Note:"
    editArea(noteDlg.text, lines = 6)
    row:
      if button("Delete", w = dp(80)):
        keep = false
        noteDlg.on = false
      spring()
      if button("OK", isDefault = true, w = dp(80)):
        notes[at].text = noteDlg.text
        noteDlg.on = false
      if button("Cancel", w = dp(80)): noteDlg.on = false
  if not noteDlg.on and at in 0 .. notes.high:
    if not keep or notes[at].text.len == 0 and noteDlg.text.len == 0: notes.delete(at)

proc createShapeDialog() =
  ## A click (no drag) with a shape tool: the usual Create Rectangle
  ## (Ellipse, Polygon...) -- the size typed, the shape made where clicked.
  if not shapeDlg.on: return
  let radial = shapeKind in {3, 6, 7}
  let name = shapeNames[clamp(shapeKind, 0, shapeNames.high)]
  var made = false
  dialog(shapeDlg.on, "Create " & name, 320):
    form 0:
      if radial:
        field "Radius:":
          row:
            intEdit(shapeDlg.w, w = dp(80), lo = 1, hi = 30000)
            label "pixels"
      else:
        field "Width:":
          row:
            intEdit(shapeDlg.w, w = dp(80), lo = 1, hi = 30000)
            label "pixels"
        field "Height:":
          row:
            intEdit(shapeDlg.h, w = dp(80), lo = 1, hi = 30000)
            label "pixels"
        if shapeKind == 1:
          field "Radius:":
            row:
              intEdit(shapeRadius, w = dp(80), lo = 0, hi = 5000)
              label "pixels"
    if not radial: checkbox("From Center", shapeDlg.center)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)):
        made = true
        shapeDlg.on = false
      if button("Cancel", w = dp(80)): shapeDlg.on = false
  if made and shapeDlg.dw != nil and shapeDlg.dw in docs:
    var x0 = shapeDlg.x
    var y0 = shapeDlg.y
    let w = max(1, shapeDlg.w).float
    let h = max(1, shapeDlg.h).float
    if shapeDlg.center and not radial:
      x0 -= w / 2
      y0 -= h / 2
    drag = Drag(on: true, dw: shapeDlg.dw, tool: tShape, x0: x0, y0: y0,
                x1: (if radial: x0 + w else: x0 + w), y1: (if radial: y0 else: y0 + h))
    shapeDlg.dw.finishShape(PhotoEvent())
    drag = Drag()

proc hdrDialogs() =
  ## HDR Toning (a 32-bit image down to 16 or 8 bits) and View > 32-bit
  ## Preview Options (the exposure and gamma it is shown at).
  let d = cur()
  if d == nil or d.depth != 32:
    toningDlg.on = false
    previewDlg.on = false
    return
  if previewDlg.on:
    var ev = int(round(previewDlg.exposure * 10))
    var g = int(round(previewDlg.gamma * 100))
    var changed = false
    dialog(previewDlg.on, "32-bit Preview Options", 380):
      label("How the light is shown (the light itself is not changed):", color = ui.theme.gray)
      row([80, -1, 52]):
        label "Exposure:"
        if slider(ev, -100, 100): changed = true
        label(formatFloat(ev / 10, ffDecimal, 1))
      row([80, -1, 52]):
        label "Gamma:"
        if slider(g, 10, 400): changed = true
        label(formatFloat(g / 100, ffDecimal, 2))
      row:
        if button("Reset", w = dp(80)):
          ev = 0
          g = 100
          changed = true
        spring()
        if button("OK", isDefault = true, w = dp(80)): previewDlg.on = false
    if changed:
      previewDlg.exposure = ev / 10
      previewDlg.gamma = g / 100
      d.setExposure(previewDlg.exposure, previewDlg.gamma)
      d.modified = true
  if toningDlg.on:
    var done = false
    dialog(toningDlg.on, "HDR Toning", 420):
      form 0:
        field "Bits:":
          var b = if toningDlg.bits == 8: 0 else: 1
          if combo(["8 Bits/Channel", "16 Bits/Channel"], b, w = dp(150)): toningDlg.bits = if b == 0: 8 else: 16
        field "Method:":
          var m = toningDlg.meth
          if combo(["Exposure and Gamma", "Highlight Compression", "Equalize Histogram", "Local Adaptation"],
                   m, w = dp(180)): toningDlg.meth = m
      if toningDlg.meth == 0:
        var ev = int(round(toningDlg.exposure * 10))
        row([80, -1, 52]):
          label "Exposure:"
          if slider(ev, -100, 100): toningDlg.exposure = ev / 10
          label(formatFloat(toningDlg.exposure, ffDecimal, 1))
        var g = int(round(toningDlg.gamma * 100))
        row([80, -1, 52]):
          label "Gamma:"
          if slider(g, 10, 400): toningDlg.gamma = g / 100
          label(formatFloat(toningDlg.gamma, ffDecimal, 2))
      elif toningDlg.meth == 3:
        var dt = int(toningDlg.detail)
        row([80, -1, 52]):
          label "Detail:"
          if slider(dt, 0, 100): toningDlg.detail = dt.float
          label($dt & "%")
      label((case toningDlg.meth
             of 1: "The highlights brought in: nothing is burnt out."
             of 2: "The lightness spread by its histogram: the most contrast."
             of 3: "The shadows lifted and the lights kept, each part by what is round it."
             else: "The light at an exposure and gamma: what is brighter than white is white."),
            color = ui.theme.gray)
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)):
          done = true
          toningDlg.on = false
        if button("Cancel", w = dp(80)): toningDlg.on = false
    if done:
      beginBusy("HDR Toning")
      try:
        d.beginStep("HDR Toning")
        d.touchLayers()
        d.toneMap(toningDlg.bits, ToneMethod(clamp(toningDlg.meth, 0, 3)),
                  (if toningDlg.meth == 0: toningDlg.exposure else: 0.0),
                  (if toningDlg.meth == 0: toningDlg.gamma else: 1.0), toningDlg.detail)
        d.endStep()
        d.modified = true
        status = $toningDlg.bits & " bits a channel"
      finally: endBusy()

var abDlg: tuple[open: bool; d: Doc; i: int; name: string; preset: int; x, y, w, h: int; color: int;
                 custom: uint32; centerMark, crossHairs, videoSafe: bool]
var gfDlg: tuple[open: bool; layer: Layer; g: GradientFeather; was: GradientFeather; shown: string]
var gfPending = false

proc startGradientFeather() =
  ## Layer > Gradient Feather...: the layer picked fading across itself (the layout program's
  ## effect), live while the box is open.
  let d = cur()
  if d == nil or d.current.group or d.current.background:
    status = "Gradient Feather: pick a layer (not the Background)"
    return
  let L = d.current
  var g = L.gradFeather
  if not g.on: g = GradientFeather(on: true, angle: 0, startOpacity: 100, endOpacity: 0, startAt: 0, endAt: 100)
  gfDlg = (true, L, g, L.gradFeather, "")
  d.beginStep("Gradient Feather")
  d.touchLayers()
  gfPending = true

proc gradientFeatherDialog() =
  let d = cur()
  if not gfDlg.open:
    if gfPending:
      # (closed from outside: as Cancel)
      gfPending = false
      if d != nil and d.stepOpen: d.cancelStep()
    return
  if d == nil or gfDlg.layer notin d.layers:
    gfDlg.open = false
    return
  var ok, cancel = false
  var g = gfDlg.g
  dialog(gfDlg.open, "Gradient Feather", 360):
    row([110, -1]):
      label "Type:"
      var k = ord(g.radial)
      if combo(["Linear", "Radial"], k, w = dp(120)): g.radial = k == 1
    template num(lab: string; v: var int; lo, hi: int; unit: string) =
      row([110, -1, 50]):
        label lab
        discard slider(v, lo, hi, ticks = 0)
        label $v & unit
    var ang = int(g.angle)
    if not g.radial: num("Angle:", ang, -180, 180, "°")
    g.angle = ang.float
    num("Start Opacity:", g.startOpacity, 0, 100, "%")
    num("End Opacity:", g.endOpacity, 0, 100, "%")
    num("Start At:", g.startAt, 0, 100, "%")
    num("End At:", g.endAt, 0, 100, "%")
    paragraph("The layer fades across where it is drawn; its mask, if it has one, stays.", color = ui.theme.gray)
    row:
      if button("Remove", w = dp(80)):
        g.on = false
        ok = true
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): cancel = true
  gfDlg.g = g
  let key = $g
  if key != gfDlg.shown and not cancel:
    gfDlg.shown = key
    gfDlg.layer.gradFeather = g
    inc gfDlg.layer.ver
    d.markAll()
  if ok:
    gfDlg.open = false
    gfPending = false
    gfDlg.layer.gradFeather = g
    d.markAll()
    if d.stepOpen: d.endStep()
  elif cancel:
    gfDlg.open = false
    gfPending = false
    if d.stepOpen: d.cancelStep()
    gfDlg.layer.gradFeather = gfDlg.was
    d.markAll()

proc boardOf(d: Doc): int =
  ## (the artboard a command is for: the picked one -- with another tool than the Artboard tool, the
  ## one the current layer is on, when it is on one)
  result = d.boardCur
  if d.layers.len > 0 and not d.current.background and not (tool == tMove and moveKind == 1):
    let c = d.contentBounds(d.current)
    if c.w > 0:
      let k = d.artboardAt(c.x + c.w div 2, c.y + c.h div 2)
      if k >= 0: result = k
  if result >= d.boards.len: result = d.boards.high

proc startArtboardOptions() =
  ## Artboard Options: the picked artboard's (the Artboard tool's; the one the current layer is on).
  let d = cur()
  if d == nil: return
  let i = d.boardOf
  if i < 0:
    status = "Artboard Options: there is no artboard -- make one with the Artboard tool (V)"
    return
  let b = d.boards[i]
  let c = b.color
  let k = if (c shr 24) == 0: 2 elif (c and 0xFFFFFF'u32) == 0xFFFFFF'u32: 0
          elif (c and 0xFFFFFF'u32) == 0: 1 else: 3
  abDlg = (true, d, i, b.name, d.presetOf(b.r.w, b.r.h), b.r.x, b.r.y, b.r.w, b.r.h, k,
           (if (c shr 24) == 0: 0xFFF2E8D8'u32 else: c), b.centerMark, b.crossHairs, b.videoSafe)

proc artboardOptionsDialog() =
  ## (Artboard Options, as the drawing program has them: its name, a preset and its size, its place,
  ## which way round, what it shows -- a mark at its middle, cross hairs, the video safe areas -- and
  ## the color of its paper: white, black, none or a color)
  if not abDlg.open: return
  let d = abDlg.d
  if d == nil or d != cur() or abDlg.i < 0 or abDlg.i >= d.boards.len:
    abDlg.open = false
    return
  var ok = false
  dialog(abDlg.open, "Artboard Options", 400):
    form 0:
      field "Name:": edit(abDlg.name)
      field "Preset:":
        var names: seq[string]
        for p in BoardPresets: names.add p[0]
        if combo(names, abDlg.preset, w = dp(170)) and abDlg.preset > 0:
          let (pw, ph) = d.presetSize(abDlg.preset)
          # (which way round it was: kept)
          if abDlg.w > abDlg.h and pw < ph: (abDlg.w, abDlg.h) = (ph, pw)
          else: (abDlg.w, abDlg.h) = (pw, ph)
      field "Width:":
        if spin(abDlg.w, 1, 30000, w = dp(90)): abDlg.preset = d.presetOf(abDlg.w, abDlg.h)
      field "Height:":
        if spin(abDlg.h, 1, 30000, w = dp(90)): abDlg.preset = d.presetOf(abDlg.w, abDlg.h)
      field "Orientation:":
        row:
          if button("Portrait", w = dp(80), enabled = abDlg.w > abDlg.h): (abDlg.w, abDlg.h) = (abDlg.h, abDlg.w)
          if button("Landscape", w = dp(80), enabled = abDlg.h > abDlg.w): (abDlg.w, abDlg.h) = (abDlg.h, abDlg.w)
      field "X:": discard spin(abDlg.x, -30000, 30000, w = dp(90))
      field "Y:": discard spin(abDlg.y, -30000, 30000, w = dp(90))
      field "Background:":
        discard combo(["White", "Black", "None (transparent)", "Color"], abDlg.color, w = dp(170))
      if abDlg.color == 3:
        field "Color:": discard colorWell(abDlg.custom, "artboardpaper", dp(50))
    label("Display", bold = true)
    checkbox("Show Center Mark", abDlg.centerMark)
    checkbox("Show Cross Hairs", abDlg.crossHairs)
    checkbox("Show Video Safe Areas", abDlg.videoSafe)
    paragraph(tr("Artboard ") & $(abDlg.i + 1) & tr(" of ") & $d.boards.len & tr("; its size in pixels at ") &
              $int(round(d.dpi)) & tr(" ppi."), color = ui.theme.gray)
    row:
      if button("Delete", w = dp(80)):
        abDlg.open = false
        d.beginStep("Delete Artboard")
        d.deleteArtboard(abDlg.i)
        d.endStep()
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): abDlg.open = false
  if ok:
    abDlg.open = false
    let i = abDlg.i
    d.beginStep("Artboard Options")
    d.renameArtboard(i, abDlg.name.strip)
    let c = case abDlg.color
            of 0: 0xFFFFFFFF'u32
            of 1: 0xFF000000'u32
            of 2: 0'u32
            else: abDlg.custom or 0xFF000000'u32
    if c != d.boards[i].color: d.setArtboardColor(i, c)
    # (its place first -- with its artwork, as the Artboard tool says --, then its size)
    let b = d.boards[i].r
    if abDlg.x != b.x or abDlg.y != b.y: d.moveArtboard(i, abDlg.x - b.x, abDlg.y - b.y, boardMoveArt)
    let nb = d.boards[i].r
    if abDlg.w != nb.w or abDlg.h != nb.h: d.resizeArtboard(i, rect(nb.x, nb.y, max(1, abDlg.w), max(1, abDlg.h)))
    if abDlg.centerMark != d.boards[i].centerMark or abDlg.crossHairs != d.boards[i].crossHairs or
       abDlg.videoSafe != d.boards[i].videoSafe:
      d.touchLayers()
      d.boards[i].centerMark = abDlg.centerMark
      d.boards[i].crossHairs = abDlg.crossHairs
      d.boards[i].videoSafe = abDlg.videoSafe
      inc d.boardsVer
    d.endStep()
    d.markAll()

proc ccDialogs() =
  ## Layer > Layer Cleanup; Layer > Harmonize; Create Rectangle (a click
  ## with a shape tool); Artboard Options.
  createShapeDialog()
  artboardOptionsDialog()
  gradientFeatherDialog()
  noteDialog()
  hdrDialogs()
  let d = cur()
  if ccDlg.cleanup:
    dialog(ccDlg.cleanup, "Layer Cleanup", 380):
      checkbox("Delete empty layers", ccDlg.cEmpty)
      checkbox("Delete empty groups", ccDlg.cGroups)
      checkbox("Delete hidden layers", ccDlg.cHidden)
      checkbox("Name layers after what they hold (\"Layer 3\" becomes \"Blue Shape\")", ccDlg.cRename)
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)) and d != nil:
          ccDlg.cleanup = false
          d.beginStep("Layer Cleanup")
          let rep = d.cleanupLayers(ccDlg.cEmpty, ccDlg.cHidden, ccDlg.cGroups, ccDlg.cRename)
          d.endStep()
          var parts: seq[string]
          if rep.emptyRemoved > 0: parts.add $rep.emptyRemoved & " empty"
          if rep.groupsRemoved > 0: parts.add $rep.groupsRemoved & " empty groups"
          if rep.hiddenRemoved > 0: parts.add $rep.hiddenRemoved & " hidden"
          status = (if parts.len > 0: "Deleted " & parts.join(", ") & "; " else: "") &
                   $rep.renamed & tr(" layers named after what they hold")
        if button("Cancel", w = dp(80)): ccDlg.cleanup = false
  if ccDlg.harmonize:
    dialog(ccDlg.harmonize, "Harmonize", 400):
      paragraph("The layer's colors and light made to fit the picture under it, and a shadow cast " &
                "away from the light.", color = ui.theme.gray)
      form 0:
        field "Intensity:": slider(ccDlg.hIntensity, 0, 100)
        field "Brightness:": slider(ccDlg.hBright, -50, 50)
        field "Saturation:": slider(ccDlg.hSat, -100, 100)
        field "Shadow:": slider(ccDlg.hShadow, 0, 100)
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)) and d != nil:
          ccDlg.harmonize = false
          let L = d.current
          beginBusy("Harmonize")
          try:
            d.layersChange("Harmonize"):
              discard d.harmonizeLayer(L, ccDlg.hIntensity, ccDlg.hShadow, ccDlg.hBright, ccDlg.hSat)
          finally: endBusy()
          status = "Harmonized" & (if ccDlg.hShadow > 0: ", with its shadow on a layer under it" else: "")
        if button("Cancel", w = dp(80)): ccDlg.harmonize = false

proc exportArtboards(d: Doc) =
  ## File > Export > Artboards to Files: each artboard a PNG -- what is on it over its paper -- beside
  ## the document (or in Pictures), named by its number and name ("01 - Artboard 1.png").
  let base = if d.path.len > 0: d.path.parentDir else: picturesDir()
  let dir = base / (d.name & " Artboards")
  var n = 0
  try:
    createDir(dir)
    for i in 0 ..< d.boards.len:
      let b = d.artboardPicture(i)
      if b == nil: continue
      var nm = d.artboardName(i)
      for c in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]: nm = nm.replace(c, "-")
      discard b.savePng(dir / nm & ".png")
      inc n
    status = $n & tr(" artboards saved in ") & dir
  except CatchableError:
    status = "Could not save the artboards: " & getCurrentExceptionMsg()

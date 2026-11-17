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

var abDlg: tuple[open: bool; board: Layer; name: string; color: int; locked: bool]
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

proc startArtboardOptions() =
  ## Artboard Options: the artboard picked (or the one the layer picked is in).
  let d = cur()
  if d == nil: return
  var i = -1
  if d.current.isArtboard: i = d.cur
  else:
    for a in d.artboards:
      if d.cur >= d.blockStart(a) and d.cur <= a: i = a
  if i < 0:
    status = "Artboard Options: pick an artboard (or a layer in one)"
    return
  let c = d.artboardColor(i)
  let k = if c == 0: 2 elif (c and 0xFFFFFF'u32) == 0xFFFFFF'u32: 0 elif (c and 0xFFFFFF'u32) == 0: 1 else: 3
  abDlg = (true, d.layers[i], d.layers[i].name, k, d.layers[i].locked)

proc artboardOptionsDialog() =
  ## (Artboard Options, as the photo and drawing programs have them: its name, the color of its
  ## page -- white, black, transparent or the foreground color --, locked)
  if not abDlg.open: return
  let d = cur()
  if d == nil or abDlg.board notin d.layers:
    abDlg.open = false
    return
  var ok = false
  dialog(abDlg.open, "Artboard Options", 340):
    row([100, -1]):
      label "Name:"
      edit(abDlg.name)
    row([100, -1]):
      label "Background:"
      discard combo(["White", "Black", "Transparent", "Foreground Color"], abDlg.color, w = dp(170))
    checkbox("Lock (not moved, resized or painted on)", abDlg.locked)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): abDlg.open = false
  if ok:
    abDlg.open = false
    let i = d.layers.find(abDlg.board)
    if i < 0: return
    d.beginStep("Artboard Options")
    d.touchLayers()
    if abDlg.name.strip.len > 0: d.layers[i].name = abDlg.name.strip
    let c = case abDlg.color
            of 0: 0xFFFFFFFF'u32
            of 1: 0xFF000000'u32
            of 2: 0'u32
            else: fg or 0xFF000000'u32
    d.setArtboardColor(i, c)
    d.lockArtboard(d.layers.find(abDlg.board), abDlg.locked)
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
                   $rep.renamed & " layers named after what they hold"
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
  ## File > Export > Artboards to Files: each artboard a PNG, beside the
  ## document (or in Pictures).
  let base = if d.path.len > 0: d.path.parentDir else: picturesDir()
  let dir = base / (d.name & " Artboards")
  var n = 0
  # (the artboards picked in the Layers palette, when some are: those alone)
  var which: seq[int]
  for i in d.artboards:
    if d.layers[i].picked or (i == d.cur and d.pickedLayers.len > 0 and i in d.pickedLayers): which.add i
  if which.len == 0: which = d.artboards
  try:
    createDir(dir)
    for i in which:
      let b = d.artboardPicture(i)
      if b == nil: continue
      var nm = d.layers[i].name
      for c in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]: nm = nm.replace(c, "-")
      discard b.savePng(dir / nm & ".png")
      inc n
    status = $n & " artboards saved in " & dir
  except CatchableError:
    status = "Could not save the artboards: " & getCurrentExceptionMsg()

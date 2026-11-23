# (included by photo.nim) Gradients: the presets, the Gradient Editor, the
# gradient tool's gradient; fill layers (Solid Color, Gradient, Pattern).

proc stop(at: float; c: uint32; mid = 0.0): GradientStop = GradientStop(at: at, color: c, mid: mid)

proc gradientPresets(): seq[tuple[name: string; stops: seq[GradientStop]]] =
  ## The gradients to pick from (the first three from the colors of the
  ## moment).
  let f = fg or 0xFF000000'u32
  let b = bg or 0xFF000000'u32
  result = @[
    ("Foreground to Background", @[stop(0, f), stop(1, b)]),
    ("Foreground to Transparent", @[stop(0, f), stop(1, f.withAlpha(0))]),
    ("Transparent to Foreground", @[stop(0, f.withAlpha(0)), stop(1, f)]),
    ("Black, White", @[stop(0, 0xFF000000'u32), stop(1, 0xFFFFFFFF'u32)]),
    ("Red, Green", @[stop(0, 0xFFE10019'u32), stop(1, 0xFF00601B'u32)]),
    ("Violet, Orange", @[stop(0, 0xFF290A59'u32), stop(1, 0xFFFF7C00'u32)]),
    ("Blue, Red, Yellow", @[stop(0, 0xFF0A00B2'u32), stop(0.5, 0xFFFF0000'u32), stop(1, 0xFFFFFC00'u32)]),
    ("Blue, Yellow, Blue", @[stop(0, 0xFF0A00B2'u32), stop(0.5, 0xFFFFFC00'u32), stop(1, 0xFF0A00B2'u32)]),
    ("Orange, Yellow, Orange", @[stop(0, 0xFFFF6E02'u32), stop(0.5, 0xFFFFFF00'u32), stop(1, 0xFFFF6D00'u32)]),
    ("Violet, Green, Orange", @[stop(0, 0xFF6F158F'u32), stop(0.5, 0xFF00843F'u32), stop(1, 0xFFFF6D00'u32)]),
    ("Yellow, Violet, Orange, Blue", @[stop(0, 0xFFF9EF00'u32), stop(0.33, 0xFF5B0A87'u32),
                                       stop(0.66, 0xFFFF6D00'u32), stop(1, 0xFF00489C'u32)]),
    ("Copper", @[stop(0, 0xFF97461A'u32), stop(0.3, 0xFFFBD8C5'u32), stop(0.83, 0xFF6C2E16'u32),
                 stop(1, 0xFFEFDBCD'u32)]),
    ("Chrome", @[stop(0, 0xFF29405F'u32), stop(0.47, 0xFFE6EEF6'u32), stop(0.5, 0xFF3A2A16'u32),
                 stop(0.64, 0xFF9C7D57'u32), stop(1, 0xFFFFFFFF'u32)]),
    ("Spectrum", @[stop(0, 0xFFFF0000'u32), stop(0.17, 0xFFFFFF00'u32), stop(0.33, 0xFF00FF00'u32),
                   stop(0.5, 0xFF00FFFF'u32), stop(0.67, 0xFF0000FF'u32), stop(0.83, 0xFFFF00FF'u32),
                   stop(1, 0xFFFF0000'u32)]),
    ("Transparent Rainbow", @[stop(0, 0x00FF0000'u32), stop(0.15, 0xFFFF0000'u32), stop(0.3, 0xFFFFFF00'u32),
                              stop(0.45, 0xFF00FF00'u32), stop(0.6, 0xFF00FFFF'u32), stop(0.75, 0xFF0000FF'u32),
                              stop(0.9, 0xFFFF00FF'u32), stop(1, 0x00FF00FF'u32)])]
  var stripes: seq[GradientStop]
  for k in 0 .. 9:
    let t0 = k / 10
    stripes.add stop(t0, (if k mod 2 == 0: f else: f.withAlpha(0)))
    stripes.add stop(t0 + 0.0999, (if k mod 2 == 0: f else: f.withAlpha(0)))
  result.add ("Transparent Stripes", stripes)
  # (and those loaded from the usual .grd files)
  for g in userGradients:
    if g.stops.len >= 2: result.add (g.name, g.stops)

var
  # the Gradient Map (Image > Adjust, an adjustment layer)
  gmStops: seq[GradientStop]
  gmReverse = false
  gmDither = false
  # Color Lookup
  luData = "look:Film Stock"
  luName = ""
  # the Gradient Editor
  geOpen = false
  geStops: seq[GradientStop]
  geSel = 0
  geName = ""
  geTarget = 0                     ## 0 the gradient tool, 1 the Gradient Map, 2 a gradient fill
  gePicked = -1                    ## the preset picked in it

proc toolStops(): seq[GradientStop] =
  ## The gradient tool's gradient now.
  if gradPreset >= 0:
    let ps = gradientPresets()
    return ps[clamp(gradPreset, 0, ps.high)].stops
  if gradCustom.len >= 2: gradCustom else: gradientPresets()[0].stops

proc startGradientEditor(target: int; stops: seq[GradientStop]) =
  geTarget = target
  geStops = stops
  if geStops.len < 2: geStops = gradientPresets()[0].stops
  geSel = 0
  gePicked = -1
  geName = "Custom"
  geOpen = true

var fillGradStops: seq[GradientStop]

proc gradientEditorDialog() =
  if not geOpen: return
  var ok = false
  dialog(geOpen, "Gradient Editor", 520):
    label("Presets", bold = true)
    let ps = gradientPresets()
    let cell = dp(40)
    let cols = max(1, (available() - dp(4)) div (cell + dp(4)))
    var i = 0
    while i < ps.len:
      row:
        for k in 0 ..< cols:
          if i + k >= ps.len: break
          pushId("gp" & $(i + k))
          if gradientSwatch(ps[i + k].name, ps[i + k].stops, cell, dp(26), gePicked == i + k).clicked:
            gePicked = i + k
            geStops = ps[i + k].stops
            geName = ps[i + k].name
            geSel = 0
          tooltip(ps[i + k].name)
          popId()
      i += cols
    space(dp(4))
    form 0:
      field "Name:": edit(geName)
    gradientEditBar("ge", geStops, geSel, available(), fg)
    if geSel >= 0 and geSel < geStops.len:
      var c = geStops[geSel].color
      var op = aOf(c) * 100 div 255
      var loc = int(round(geStops[geSel].at * 100))
      row:
        label "Color:"
        var cc = c
        if colorWell(cc, "gestop", alpha = true):     # (its opacity too: Transparent)
          geStops[geSel].color = cc
          gePicked = -1
        label "Opacity:"
        if spin(op, 0, 100, w = dp(64)):
          geStops[geSel].color = c.withAlpha(op * 255 div 100)
          gePicked = -1
        label "%"
        label "Location:"
        if spin(loc, 0, 100, w = dp(64)):
          geStops[geSel].at = loc / 100
          let picked = geStops[geSel]
          geStops.sort(proc (a, b: GradientStop): int = cmp(a.at, b.at))
          geSel = geStops.find(picked)
          gePicked = -1
        label "%"
      row:
        if button("Use Foreground", w = dp(120)):
          geStops[geSel].color = (fg or 0xFF000000'u32).withAlpha(aOf(c))
        if button("Use Background", w = dp(120)):
          geStops[geSel].color = (bg or 0xFF000000'u32).withAlpha(aOf(c))
        if button("Transparent", w = dp(100), enabled = aOf(c) > 0):
          geStops[geSel].color = c.withAlpha(0)
          gePicked = -1
        tooltip("This color stop see-through: the gradient fades out to it")
        if button("Delete", w = dp(80), enabled = geStops.len > 2):
          geStops.delete(geSel)
          geSel = min(geSel, geStops.high)
    paragraph("Click under the bar to add a color; drag a color stop to move it (away, under the bar, to " &
              "take it off); drag a diamond to move the middle between two colors.", color = ui.theme.gray)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): geOpen = false
  if ok:
    geOpen = false
    case geTarget
    of 0:
      if gePicked >= 0: gradPreset = gePicked
      else:
        gradPreset = -1
        gradCustom = geStops
    of 1: gmStops = geStops
    else: fillGradStops = geStops

# ---- fill layers ------------------------------------------------------------------------------------------------

var
  flOpen = false
  flKind = spColor
  flColor = 0xFF3A6EA5'u32
  flStyle = 0                    ## Linear, Radial, Angle, Reflected, Diamond
  flAngle = 90
  flScale = 100
  flReverse = false
  flLayer: Layer                 ## a fill layer being changed (nil: a new one)

proc flPaint(): ShapePaint =
  case flKind
  of spGradient:
    let st = if fillGradStops.len >= 2: fillGradStops else: toolStops()
    ShapePaint(kind: spGradient, stops: st, color: st[0].color, color2: st[^1].color, angle: flAngle,
               style: flStyle, scale: flScale, reverse: flReverse, opacity: 100)
  of spPattern:
    ShapePaint(kind: spPattern, pattern: pattern, pw: patternW, ph: patternH, scale: flScale, opacity: 100)
  else: ShapePaint(kind: spColor, color: flColor, color2: flColor, opacity: 100)

proc startFillLayer(kind: ShapePaintKind; L: Layer = nil) =
  ## Layer > New Fill Layer: a color, a gradient or the pattern -- or a fill
  ## layer's changed (`L`).
  let d = cur()
  if d == nil: return
  if kind == spPattern and pattern.len == 0 and (L == nil or L.shape.fill.pattern.len == 0):
    status = "Define a pattern first (Edit > Define Pattern)"
    return
  flKind = kind
  flLayer = L
  if L != nil:
    let p = L.shape.fill
    flKind = p.kind
    case p.kind
    of spGradient:
      fillGradStops = if p.stops.len >= 2: p.stops else: @[stop(0, p.color), stop(1, p.color2)]
      flStyle = p.style
      flAngle = p.angle
      flScale = if p.scale <= 0: 100 else: p.scale
      flReverse = p.reverse
    of spPattern:
      flScale = if p.scale <= 0: 100 else: p.scale
    else: flColor = p.color
    d.beginStep("Fill Layer")
    d.touchLayers()
  else:
    if kind == spGradient: fillGradStops = toolStops()
    if kind == spColor: flColor = fg or 0xFF000000'u32
    d.beginStep("New Fill Layer")
    d.touchLayers()
    flLayer = d.addFillLayer(flPaint())
  flOpen = true

proc fillLayerDialog() =
  if not flOpen: return
  let d = cur()
  if d == nil or flLayer == nil or flLayer notin d.layers:
    flOpen = false
    return
  var done = 0
  var open = true
  dialog(open, (case flKind
                of spGradient: "Gradient Fill"
                of spPattern: "Pattern Fill"
                else: "Solid Color"), 400):
    case flKind
    of spGradient:
      row:
        label "Gradient:"
        if gradientSwatch("fillgrad", (if fillGradStops.len >= 2: fillGradStops else: toolStops()),
                          dp(160), dp(24)).clicked:
          startGradientEditor(2, fillGradStops)
      row:
        label "Style:"
        combo(@["Linear", "Radial", "Angle", "Reflected", "Diamond"], flStyle, w = dp(110))
      discard fxSlider("Angle:", flAngle, -180, 180, "°")
      discard fxSlider("Scale:", flScale, 10, 150, "%")
      checkbox("Reverse", flReverse)
    of spPattern:
      row:
        label "Pattern:"
        if pattern.len > 0:
          let b = newBitmap(patternW, patternH)
          b.px = pattern
          b.changed()
          discard pictureBox("fillpat", b, dp(48), dp(48))
      discard fxSlider("Scale:", flScale, 10, 1000, "%")
      paragraph("The pattern is the one of Edit > Define Pattern.", color = ui.theme.gray)
    else:
      row:
        label "Color:"
        colorWell(flColor, "fillcolor", dp(80), alpha = true)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): done = 1
      if button("Cancel", w = dp(80)): done = 2
  let paint = flPaint()
  if flLayer.shape.fill != paint: d.setFillPaint(flLayer, paint)
  if not open and done == 0: done = 2
  if done == 1:
    flOpen = false
    d.endStep()
  elif done == 2:
    flOpen = false
    d.cancelStep()

var
  lutPick = false
  lutPath = ""

proc startOpenLut() =
  proc go() =
    if lutPath.len == 0 or not dirExists(lutPath.parentDir): lutPath = picturesDir()
    lutPick = true
  if askStorage(AppName, AppName & " reads the color table you pick.", go): go()

proc gradientDialogs() =
  fillLayerDialog()
  gradientEditorDialog()
  if filePicker(lutPick, lutPath, fmOpen, ["*.cube", "*.CUBE"], "Load 3D LUT"):
    try:
      let text = readFile(lutPath)
      discard parseCube(text)                # (that it is one)
      luData = "cube:" & text
      luName = lutPath.extractFilename
    except CatchableError:
      status = "Could not read " & lutPath.extractFilename & ": " & getCurrentExceptionMsg()

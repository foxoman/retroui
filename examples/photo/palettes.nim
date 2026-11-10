# (included by photo.nim) The palettes: Brushes and Options; Picker,
# Swatches and Scratch; Layers, Channels and Paths; Info; Commands.

var
  thumbs: Table[pointer, tuple[ver: int; w, h: int; b: Bitmap]]
  chanThumbs: Table[string, tuple[ver: int; b: Bitmap]]
  layerOptsOpen = false
  layerOptsName = ""
  layerOptsOpacity = 100
  layerOptsMode = 0
  newLayerOpen = false
  newLayerName = ""
  brushOptsOpen = false
  brushOpts: BrushTip
  brushOptsNew = false
  pickerTarget = 0          ## 0 foreground, 1 background
  cmdTab = 0

proc editSmartContents(d: Doc; L: Layer)
proc typeOptions()
proc startLayerStyle(page = -1)
proc layerStyleMenu(d: Doc)
proc typeMenu(d: Doc)
proc showTypePal(tab: int)

proc thumbOf(d: Doc; L: Layer; size: int): Bitmap =
  let k = cast[pointer](L)
  let t = thumbs.getOrDefault(k)
  if t.b != nil and t.ver == L.ver and t.w == d.w and t.h == d.h: return t.b
  result = thumbnailOf(L.px, d.w, d.h, size, size)
  if thumbs.len > 512: thumbs.clear()        # (layers long gone: not kept)
  thumbs[k] = (L.ver, d.w, d.h, result)

proc channelThumb(d: Doc; ch: int; size: int): Bitmap =
  ## A color channel of the image (in gray), or an alpha channel.
  let key = $cast[uint](d) & "/" & $ch
  let t = chanThumbs.getOrDefault(key)
  if t.b != nil and (t.ver == d.ver or d.live.len > 0): return t.b
  d.updateComposite()
  var px: seq[uint32]
  if ch < 4:
    # (small first: a channel of a thumbnail is the thumbnail of a channel)
    let k = max(1.0, max(d.w, d.h).float / (size * 2).float)
    let tw = max(1, int(d.w.float / k))
    let th = max(1, int(d.h.float / k))
    let comp = d.compCopy
    var small = thumbnailOf(comp, d.w, d.h, tw, th).px
    let mode = d.mode
    if ch < 0:
      if mode == cmDuotone:
        let t = duotoneTable(d.duotone)
        for p in small.mitems: p = (t[(p shr 16) and 255] and 0xFFFFFF'u32) or (p and 0xFF000000'u32)
      elif mode == cmCMYK or d.proof or (mode == cmMultichannel and d.spotBase == cmCMYK):
        for p in small.mitems: p = proofOf(p)
    else:
      for p in small.mitems: p = grayPx(d.channelGrayOf(p, ch))
    result = thumbnailOf(small, tw, th, size, size)
    if chanThumbs.len > 256: chanThumbs.clear()
    chanThumbs[key] = (d.ver, result)
    return
  else:
    let a = d.alphas[ch - 4]
    px = newSeq[uint32](a.m.len)
    for i, v in a.m: px[i] = grayPx(int(v))
  result = thumbnailOf(px, d.w, d.h, size, size)
  chanThumbs[key] = (d.ver, result)

# ---- small rows ------------------------------------------------------------------------------------

proc optCombo(lab: string; items: openArray[string]; v: var int; w = 0): bool {.discardable.} =
  row:
    label lab
    result = combo(items, v, w = (if w > 0: w else: dp(120)))

proc optSlider(lab: string; v: var int; lo, hi: int; unit = "%"): bool {.discardable.} =
  row([58, -1, 36]):
    label lab
    result = slider(v, lo, hi, ticks = 0)
    label $v & unit

proc optNumber(lab: string; v: var int; lo, hi: int; unit = ""): bool {.discardable.} =
  row:
    label lab
    result = spin(v, lo, hi, w = dp(64))
    if unit.len > 0: label unit

proc modeOpacity(t: Tool; what = "Opacity") =
  var m = opts[t].mode
  row:
    label "Mode:"
    if combo(modeNames(), m, w = dp(110)): opts[t].mode = m
  optSlider(what & ":", opts[t].opacity, 1, 100)

proc fadeRow(t: Tool) =
  row:
    var on = opts[t].fade > 0
    if checkbox("Fade:", on): opts[t].fade = (if on: 20 else: 0)
    var f = max(opts[t].fade, 1)
    if spin(f, 1, 9999, w = dp(64)) and opts[t].fade > 0: opts[t].fade = f
    label "steps"
  row:
    var k = ord(opts[t].fadeToBg)
    label "to"
    if radio("Transparent", k, 0): opts[t].fadeToBg = false
    if radio("Background", k, 1): opts[t].fadeToBg = true

proc pressureRow(t: Tool) =
  row:
    label "Stylus:"
    checkbox("Size", opts[t].sizeByPressure)
    checkbox("Opacity", opts[t].opacityByPressure)

proc startDynamics(t: Tool)

proc dynamicsRows(t: Tool) =
  ## Smoothing, symmetry and the Brush Dynamics of the painting tools.
  optSlider("Smoothing:", brushSmoothing, 0, 100)
  row:
    label "Symmetry:"
    combo(["Off", "Vertical", "Horizontal", "Dual Axis", "Radial", "Mandala"], symmetry, w = dp(100))
    if symmetry >= 4: spin(symAxes, 2, 16, w = dp(50))
  let o = opts[t].dyn
  let on = o.sizeJitter + o.angleJitter + o.roundJitter + o.scatter + o.opacityJitter + o.flowJitter +
           o.hueJitter + o.fgBgJitter + o.brightJitter + max(0, o.count - 1) > 0 or (o.flow > 0 and o.flow < 100)
  row:
    if button("Brush Settings...", w = dp(130)): startDynamics(t)
    if on: label("(on)", color = ui.theme.gray)

proc selModeRow() =
  ## On a touch screen (no Shift or Alt): how a new selection meets the one
  ## there is.
  if not ui.touch: return
  optCombo("Selection:", ["New", "Add to", "Subtract from", "Intersect with"], touchSelMode)

proc colorWell(c: var uint32; key: string; w = 0): bool {.discardable.}
proc stepOnce(d: Doc; name: string; body: proc ())

var
  shapeThumbs: seq[Bitmap]
  shapeSynced: Layer             ## the shape layer whose settings the options show

proc shapeThumb(i, size: int): Bitmap =
  ## A custom shape drawn small (for its list).
  if shapeThumbs.len != CustomShapes.len or shapeThumbs[0].w != size:
    shapeThumbs = @[]
    for k in 0 .. CustomShapes.high:
      var px = newSeq[uint32](size * size)
      discard renderShape(ShapeData(path: customPath(k, 1, 1, size.float - 1, size.float - 1),
                                    fill: solidPaint(0xFF000000'u32)), px, size, size)
      let b = newBitmap(size, size)
      b.px = px
      shapeThumbs.add b
  shapeThumbs[clamp(i, 0, shapeThumbs.high)]

var lineThumbs: Table[(LineEnd, bool, uint32), Bitmap]   ## (the ends drawn small, for their lists)

proc lineEndThumb(e: LineEnd; atStart: bool; c: uint32): Bitmap =
  ## (a line with end `e`, small: what the lists of ends show)
  let key = (e, atStart, c)
  if key in lineThumbs: return lineThumbs[key]
  let w = dp(30)
  let h = dp(14)
  result = newBitmap(w, h)
  var s = ShapeData(stroke: solidPaint(c or 0xFF000000'u32), strokeWidth: max(1.0, dp(15) / 10),
                    endW: 3.5, endL: 3.5)
  if atStart: s.startEnd = e else: s.endEnd = e
  var sp = SubPath()
  let y = h.float / 2
  let pad = dp(5).float
  for x in [pad, w.float - pad]: sp.pts.add PathPoint(p: (x, y), inH: (x, y), outH: (x, y))
  s.path.subs.add sp
  discard renderShape(s, result.px, w, h)
  lineThumbs[key] = result

proc lineEndCombo(v: var LineEnd; atStart: bool; w: int): bool =
  ## A list of the ends a line can have (each drawn), bound to `v`.
  var names: seq[string]
  for e in LineEnd: names.add $e
  var i = ord(v)
  let preview: ItemPreview = proc (k: int; r: Rect; selected: bool) =
    let tc = if selected: ui.theme.selectText else: ui.theme.text
    let b = lineEndThumb(LineEnd(k), atStart, argb(255, int(tc.r), int(tc.g), int(tc.b)))
    drawBitmap(rect(r.x + dp(3), r.y + (r.h - b.h) div 2, b.w, b.h), b)
    text(r.x + b.w + dp(8), itemTextY(r.y), tr(names[k]), tc)
  if combo(names, i, w = w, preview = preview) and i != ord(v):
    v = LineEnd(clamp(i, 0, ord(LineEnd.high)))
    result = true

proc applyLineOptions() =
  ## The Line tool's options changed with a line layer the current one: it
  ## takes them (its weight, its ends).
  let d = cur()
  if d == nil or not d.current.isLine or d.quickMask: return
  let L = d.current
  var s = L.shape
  s.strokeWidth = max(1, lineWidth).float
  s.startEnd = lineStart
  s.endEnd = lineEnd
  s.endW = lineEndW / 100
  s.endL = lineEndL / 100
  if s.stroke.kind == spNone: s.stroke = solidPaint(lineColor())
  d.stepOnce("Line Options", proc () = d.setShape(L, s))

proc applyShapeOptions()

proc lineOptions(bar: bool) =
  ## The Line tool's color, weight and ends -- in the options bar, or the
  ## palette (`bar` false).
  var changed = false
  label "Color:"
  var c = lineColor()
  if colorWell(c, (if bar: "barlinecolor" else: "linecolor"), dp(26)):
    shapeStroke = c
    shapeStrokeKind = 1
    applyShapeOptions()
  if combo(["Solid", "Dashed", "Dotted"], shapeDash, w = dp(70)): applyShapeOptions()
  if not bar:
    endRow()
    beginRow()
  label "Weight:"
  if spin(lineWidth, 1, 1000, w = dp(56)): changed = true
  label "px"
  label "Start:"
  if lineEndCombo(lineStart, true, dp(if bar: 118 else: 130)): changed = true
  if not bar:
    endRow()
    beginRow()
  label "End:"
  if lineEndCombo(lineEnd, false, dp(if bar: 118 else: 130)): changed = true
  if lineStart != leNone or lineEnd != leNone:
    if not bar:
      endRow()
      beginRow()
    label "Width:"
    if spin(lineEndW, 100, 3000, w = dp(60)): changed = true
    label "%  Length:"
    if spin(lineEndL, 100, 3000, w = dp(60)): changed = true
    label "%"
  if changed: applyLineOptions()

proc syncShapeOptions(L: Layer) =
  ## The options show a shape layer's fill and stroke (when it becomes the
  ## current one).
  let s = L.shape
  if L.isLine:
    # (a line: its weight and ends too)
    lineWidth = max(1, int(round(s.strokeWidth)))
    lineStart = s.startEnd
    lineEnd = s.endEnd
    if s.endW > 0: lineEndW = int(round(s.endW * 100))
    if s.endL > 0: lineEndL = int(round(s.endL * 100))
  shapeFillKind = ord(s.fill.kind)
  shapeFill = s.fill.color or 0xFF000000'u32
  shapeFill2 = s.fill.color2 or 0xFF000000'u32
  shapeStrokeKind = if s.stroke.kind == spNone: 0 else: 1
  shapeStroke = s.stroke.color or 0xFF000000'u32
  shapeStrokeW = max(1, int(round(s.strokeWidth)))
  shapeAlign = ord(s.align)
  shapeDash = if s.dashes.len == 0: 0 elif s.dashes[0] < 0.5: 2 else: 1

proc applyShapeOptions() =
  ## The fill and stroke options changed with a shape layer the current one:
  ## it takes them.
  let d = cur()
  if d == nil or not d.current.isShape or d.quickMask: return
  let L = d.current
  if L.isLine:
    # (a line keeps its stroke: its color from the options)
    var s = L.shape
    s.stroke = solidPaint(lineColor())
    s.dashes = shapeSettings().dashes
    s.cap = if shapeDash == 2: lcRound else: lcButt
    d.stepOnce("Shape Options", proc () = d.setShape(L, s))
    return
  var s = L.shape
  let n = shapeSettings()
  s.fill = n.fill
  if L.shape.fill.kind == spGradient and n.fill.kind == spGradient:
    s.fill.angle = L.shape.fill.angle
    s.fill.style = L.shape.fill.style
  s.stroke = n.stroke
  s.strokeWidth = n.strokeWidth
  s.align = n.align
  s.cap = n.cap
  s.dashes = n.dashes
  d.stepOnce("Shape Options", proc () = d.setShape(L, s))

proc shapeOptions() =
  let d = cur()
  if d != nil and d.current.isShape and d.current != shapeSynced:
    shapeSynced = d.current
    syncShapeOptions(d.current)
  elif d == nil or not d.current.isShape: shapeSynced = nil
  optCombo("Shape:", shapeNames, shapeKind, dp(150))
  optCombo("Mode:", ["Shape Layer", "Path", "Pixels"], shapeMode, dp(110))
  if shapeMode == 2: modeOpacity(tShape)
  if shapeMode == 0 and shapeKind != 4:
    var changed = false
    row:
      label "Fill:"
      if combo(["No Color", "Solid Color", "Gradient"], shapeFillKind, w = dp(96)): changed = true
      if shapeFillKind > 0:
        if colorWell(shapeFill, "shapefill", dp(26)): changed = true
      if shapeFillKind == 2:
        if colorWell(shapeFill2, "shapefill2", dp(26)): changed = true
    row:
      label "Stroke:"
      if combo(["No Color", "Solid Color"], shapeStrokeKind, w = dp(96)): changed = true
      if shapeStrokeKind > 0:
        if colorWell(shapeStroke, "shapestroke", dp(26)): changed = true
    if shapeStrokeKind > 0:
      row:
        label "Width:"
        if spin(shapeStrokeW, 1, 500, w = dp(56)): changed = true
        label "px"
      row:
        if combo(["Inside", "Center", "Outside"], shapeAlign, w = dp(80)): changed = true
        if combo(["Solid", "Dashed", "Dotted"], shapeDash, w = dp(80)): changed = true
    if changed: applyShapeOptions()
  case shapeKind
  of 6:
    optNumber("Points:", starPoints, 3, 100)
    optSlider("Indent:", starIndent, 1, 99)
    checkbox("Rounded", polySmooth)
  of 7:
    optNumber("Turns:", spiralTurns, 1, 30)
    optSlider("Decay:", spiralDecay, 5, 99)
  of 1: optNumber("Radius:", shapeRadius, 0, 2000, "pixels")
  of 3:
    optNumber("Sides:", polySides, 3, 100)
    row:
      checkbox("Star", polyStar)
      checkbox("Smooth", polySmooth)
    if polyStar: optSlider("Indent:", polyIndent, 1, 99)
  of 4:
    row: lineOptions(false)
  of 5:
    var names: seq[string]
    for cs in CustomShapes: names.add cs.name
    let ts = dp(16)
    let preview: ItemPreview = proc (i: int; r: Rect; selected: bool) =
      let b = shapeThumb(i, ts)
      drawBitmap(rect(r.x + dp(3), r.y + (r.h - ts) div 2, ts, ts), b)
      text(r.x + ts + dp(8), itemTextY(r.y), names[i], if selected: ui.theme.selectText else: ui.theme.text)
    row:
      label "Shape:"
      combo(names, customShape, w = dp(150), preview = preview)
  else: discard
  if shapeMode == 0:
    optCombo("Combine:", ["New Layer", "Combine Shapes", "Subtract Front", "Intersect Areas", "Exclude Overlap"],
             shapeOp, dp(140))

proc optionsBody() =
  let t = tool
  label(toolName(t) & " Options", bold = true)
  case t
  of tMarquee:
    optCombo("Shape:", ["Rectangular", "Elliptical", "Single Row", "Single Column"], marqueeShape)
    optCombo("Style:", ["Normal", "Constrained Aspect Ratio", "Fixed Size"], marqueeStyle)
    if marqueeStyle > 0:
      row:
        label "Width:"
        spin(marqueeW, 1, 30000, w = dp(64))
        label "Height:"
        spin(marqueeH, 1, 30000, w = dp(64))
    optNumber("Feather:", marqueeFeather, 0, 250, "pixels")
    checkbox("Anti-aliased", marqueeAA)
    selModeRow()
  of tLasso:
    optNumber("Feather:", lassoFeather, 0, 250, "pixels")
    checkbox("Anti-aliased", lassoAA)
    selModeRow()
  of tWand:
    optCombo("Tool:", ["Magic Wand", "Quick Selection", "Object Selection", "Selection Brush"], wandMode, dp(150))
    case wandMode
    of 3:
      var m = ord(selBrushSub)
      if optCombo("Mode:", ["Add", "Subtract"], m, dp(110)): selBrushSub = m == 1
      optSlider("Brush Size:", quickSize, 1, 1000)
      optSlider("Hardness:", selBrushHard, 0, 100)
      checkbox("Overlay (what is not selected in red)", selBrushOverlay)
      paragraph("Paint what to select; Alt (or Subtract) takes away.", color = ui.theme.gray)
    of 1:
      optSlider("Brush Size:", quickSize, 2, 400)
      checkbox("Sample All Layers", wandMerged)
      paragraph("Paint over what to select: the selection grows to its edges. Alt (or Subtract) " &
                "takes away.", color = ui.theme.gray)
    of 2:
      checkbox("Sample All Layers", wandMerged)
      paragraph("Draw a box round a thing: the thing is selected.", color = ui.theme.gray)
    else:
      optNumber("Tolerance:", wandTol, 0, 255)
      checkbox("Anti-aliased", wandAA)
      checkbox("Contiguous", wandContig)
      checkbox("Sample All Layers", wandMerged)
    selModeRow()
    if button("Select and Mask...", w = dp(140), enabled = cur() != nil): runCommand("Select and Mask...")
  of tHand, tZoom:
    row:
      if button("Zoom 1:1", w = dp(96)) and active != nil: active.view.setZoom(active.doc, 1)
      if button("Fit on Screen", w = dp(110)) and active != nil: active.view.fit(active.doc)
  of tMove:
    paragraph("Drag the selection (or the whole layer) to move it; Shift keeps it straight. " &
              "The arrow keys move it one pixel (Shift: ten).", color = ui.theme.gray)
  of tCrop:
    if cropKind == 1:
      paragraph("Drag a box around what was photographed at an angle (a page, a sign, a " &
                "building), then drag its four corners onto its edges: Enter makes it a " &
                "rectangle. Esc cancels.", color = ui.theme.gray)
      return
    checkbox("Straighten", cropStraighten)
    if cropStraighten:
      paragraph("Drag along a line that should be level (a horizon) or upright: the image is " &
                "turned and cut to what it fills.", color = ui.theme.gray)
    else:
      paragraph("Drag the part to keep; its handles change it (Shift: in proportion), dragging " &
                "inside moves it. Click inside it or press Enter to crop, Esc to cancel.",
                color = ui.theme.gray)
  of tType:
    typeOptions()
  of tBucket:
    modeOpacity(tBucket)
    optNumber("Tolerance:", bucketTol, 0, 255)
    checkbox("Anti-aliased", bucketAA)
    checkbox("Contiguous", bucketContig)
    checkbox("All Layers", bucketAll)
    row:
      label "Contents:"
      radio("Foreground", bucketPattern, 0)
      radio("Pattern", bucketPattern, 1, enabled = pattern.len > 0)
  of tGradient:
    modeOpacity(tGradient)
    row:
      label "Gradient:"
      if gradientSwatch("toolgrad", toolStops(), dp(120), dp(22), false, gradReverse).clicked:
        startGradientEditor(0, toolStops())
    let ps = gradientPresets()
    var names: seq[string]
    for p in ps: names.add p.name
    if gradPreset < 0: names.add "Custom"
    var k = if gradPreset < 0: names.high else: gradPreset
    if optCombo("Preset:", names, k, dp(150)):
      if k < ps.len: gradPreset = k
    optCombo("Type:", ["Linear", "Radial", "Angle", "Reflected", "Diamond"], gradKind)
    if gradKind == 1: optSlider("Offset:", gradOffset, 0, 99)
    row:
      checkbox("Reverse", gradReverse)
      checkbox("Dither", gradDither)
  of tShape: shapeOptions()
  of tEyedropper:
    optCombo("Sample Size:", ["Point Sample", "3 by 3 Average", "5 by 5 Average"], dropperSize)
    if dropKind == 2 and ruler.on:
      label("Angle: " & formatFloat(rulerAngle(), ffDecimal, 1) & "°")
      if button("Straighten Layer", w = dp(130)): straightenByRuler()
  of tEraser:
    if eraseKind == 2:
      optCombo("Sampling:", ["Continuous", "Once", "Background Swatch"], bgEraseSampling)
      optCombo("Limits:", ["Discontiguous", "Contiguous", "Find Edges"], bgEraseLimits)
      optSlider("Tolerance:", bgEraseTol, 1, 100)
      checkbox("Protect Foreground Color", bgEraseProtect)
      paragraph("The color under the cross in the brush's middle is rubbed out to transparency, " &
                "and those like it: paint along an edge to lift a subject off its background.",
                color = ui.theme.gray)
      return
    if eraseKind == 1:
      optNumber("Tolerance:", magicTol, 0, 255)
      checkbox("Contiguous", magicContig)
      return
    optCombo("Mode:", ["Paintbrush", "Airbrush", "Pencil", "Block"], eraserMode)
    if eraserMode != 3: optSlider("Opacity:", opts[tEraser].opacity, 1, 100)
    fadeRow(tEraser)
    checkbox("Erase to Saved", eraseToSaved)
    pressureRow(tEraser)
    if eraserMode != 3: dynamicsRows(tEraser)
    if button("Erase Image", w = dp(110), enabled = cur() != nil): runCommand("Erase Image")
  of tPencil:
    modeOpacity(tPencil)
    fadeRow(tPencil)
    checkbox("Auto Erase", opts[tPencil].autoErase)
    dynamicsRows(tPencil)
  of tAirbrush:
    modeOpacity(tAirbrush, "Pressure")
    fadeRow(tAirbrush)
    pressureRow(tAirbrush)
    dynamicsRows(tAirbrush)
  of tBrush:
    optCombo("Tool:", ["Paintbrush", "Mixer Brush", "Color Replacement", "Adjustment Brush"], brushTool, dp(150))
    if brushTool == 3:
      optCombo("Adjustment:", adjBrushPresets, adjBrushKind, dp(150))
      if optSlider("Amount:", adjBrushAmount, -100, 100): adjBrushChanged()
      var m = ord(adjBrushSub)
      if optCombo("Mode:", ["Add", "Subtract"], m, dp(110)): adjBrushSub = m == 1
      paragraph("Paint an adjustment where it is wanted: an adjustment layer whose mask is what " &
                "is painted (Alt takes it away). The amount changes it afterwards too.",
                color = ui.theme.gray)
    elif brushTool == 2:
      optCombo("Mode:", ["Hue", "Saturation", "Color", "Luminosity"], crMode)
      optCombo("Sampling:", ["Continuous", "Once", "Background Swatch"], crSampling)
      optCombo("Limits:", ["Discontiguous", "Contiguous", "Find Edges"], crLimits)
      optSlider("Tolerance:", crTol, 1, 100)
      paragraph("Paints the foreground color over the color under the cross in the brush's middle " &
                "(and those like it), keeping its light and shade: a red car made blue.",
                color = ui.theme.gray)
    elif brushTool == 1:
      optSlider("Opacity:", opts[tBrush].opacity, 1, 100)
      optSlider("Wet:", mixWet, 0, 100)
      optSlider("Load:", mixLoad, 1, 100)
      optSlider("Mix:", mixRatio, 0, 100)
      paragraph("Paints with the foreground color, mixing it with the paint already there (Wet: how " &
                "much it picks up; Load: how long its paint lasts).", color = ui.theme.gray)
    else:
      modeOpacity(tBrush)
      fadeRow(tBrush)
      checkbox("Wet Edges", opts[tBrush].wet)
    pressureRow(tBrush)
    dynamicsRows(tBrush)
  of tStamp:
    optCombo("Tool:", ["Rubber Stamp", "History Brush", "Art History Brush"], stampTool, dp(150))
    modeOpacity(tStamp)
    if stampTool == 2:
      var names: seq[string]
      for st in ArtStyle: names.add $st
      optCombo("Style:", names, artStyle, dp(150))
      row:
        label "Area:"
        spin(artArea, 1, 500, w = dp(60))
        label "px"
      row:
        label "Tolerance:"
        spin(artTolerance, 0, 100, w = dp(60))
        label "%"
      paragraph("Paints quick strokes in the colors of the state or snapshot marked in the History palette, " &
                "along its edges: a painting made from the photo.", color = ui.theme.gray)
      if button("History...", w = dp(110)): runCommand("History")
      return
    if stampTool == 1:
      paragraph("Paints back the image as it was: the state or snapshot marked with the brush in the " &
                "History palette (Window > Palettes > History).", color = ui.theme.gray)
      if button("History...", w = dp(110)): runCommand("History")
      return
    optCombo("Option:", ["Clone (aligned)", "Clone (non-aligned)", "Pattern (aligned)",
                         "Pattern (non-aligned)", "From Snapshot", "From Saved", "Impressionist"],
            stampMode, dp(140))
    row:
      # (Alt+click sets it too; a finger has no Alt)
      if button(if stampPicking: "Tap the source..." else: "Set Source", w = dp(120)):
        stampPicking = not stampPicking
    label(if stampSrc.set: "Source set: Alt+click for another" else: "Alt+click to set the source",
          color = ui.theme.gray)
  of tSmudge:
    modeOpacity(tSmudge, "Pressure")
    checkbox("Finger Painting", opts[tSmudge].finger)
  of tBlur:
    optCombo("Tool:", ["Blur", "Sharpen"], blurMode)
    modeOpacity(tBlur, "Pressure")
  of tDodge:
    optCombo("Tool:", ["Dodge", "Burn", "Sponge"], dodgeMode)
    if dodgeMode == 2: optCombo("Mode:", ["Desaturate", "Saturate"], spongeMode)
    else: optCombo("Range:", ["Shadows", "Midtones", "Highlights"], dodgeTone)
    optSlider(if dodgeMode == 2: "Pressure:" else: "Exposure:", opts[tDodge].opacity, 1, 100)
  of tHeal:
    optCombo("Tool:", ["Spot Healing Brush", "Healing Brush", "Patch", "Remove Tool", "Content-Aware Move"],
             healMode, dp(150))
    case healMode
    of 0:
      paragraph("Paint over a spot or a small thing: it is made again from what is around it.",
                color = ui.theme.gray)
    of 1:
      row:
        if button(if stampPicking: "Tap the source..." else: "Set Source", w = dp(120)):
          stampPicking = not stampPicking
      label(if stampSrc.set: "Source set: Alt+click for another" else: "Alt+click to set the source",
            color = ui.theme.gray)
    of 3:
      paragraph("Paint over what should go -- a person, a wire, a sign: it is taken away and what was " &
                "behind it made up from round it. Paint a little past its edges.", color = ui.theme.gray)
    of 4:
      var m = if camExtend: 1 else: 0
      optCombo("Mode:", ["Move", "Extend"], m)
      camExtend = m == 1
      paragraph("Select something (or draw round it with this tool), then drag it elsewhere: it is " &
                "fitted in there, and where it was is made up (Extend: copied, the original kept).",
                color = ui.theme.gray)
    else:
      paragraph("Select what to mend (or draw round it with this tool), then drag it to the place " &
                "whose texture it should take.", color = ui.theme.gray)
  of tRedEye:
    optSlider("Darken:", redEyeDarken, 1, 100)
    paragraph("Click a red pupil, or drag a box around the eye.", color = ui.theme.gray)
  of tPen:
    case penMode
    of 8:
      optSlider("Detail:", traceDetail, 1, 100)
      optCombo("Trace:", ["Detailed", "Normal", "Simplified"], traceMode, dp(120))
      paragraph("Point at an edge of the picture: it lights up; click: it becomes a path. " &
                "Shift+click another point of an edge: the path goes on along it to there. " &
                "More detail finds fainter edges.", color = ui.theme.gray)
    of 6:
      optNumber("Curve Fit (px):", freeCurveFit, 1, 10)
      paragraph("Draw the path as with a pencil: it is made smooth curves when the mouse comes " &
                "up (the higher the Curve Fit, the fewer its points). End where it began to close it.",
                color = ui.theme.gray)
    of 7:
      paragraph("Click points: the curve goes smoothly through them all. Drag a point to move it, " &
                "Alt+click it for a corner; click the first point to close the shape.",
                color = ui.theme.gray)
    else:
      paragraph("Click for corner points, drag for curves; click the first point to close the " &
                "shape. The Paths palette fills, strokes or selects it.", color = ui.theme.gray)

var
  brushFilePick = false          ## Load Brushes / Save Brushes (.abr, .gbr)
  brushFileSave = false
  brushFilePath = ""

proc brushMenuItems() =
  ## The Brushes panel's menu.
  let t = brushOwner()
  if menuItem("New Brush Preset..."):
    presetDlg = (true, 0, "Brush " & $opts[t].tip.diameter, -1)
  if menuItem("New Brush Group..."): presetDlg = (true, 1, "New Group", -1)
  if menuItem("Rename Brush...", enabled = presetIndex(opts[t].preset) >= 0):
    let i = presetIndex(opts[t].preset)
    presetDlg = (true, 2, presets[i].name, i)
  if menuItem("Delete Brush", enabled = presets.len > 1 and presetIndex(opts[t].preset) >= 0):
    presets.delete(presetIndex(opts[t].preset))
    savePresets()
  menuSeparator()
  if menuItem("Brush Settings...", "F5"):
    showPanel("brushsettings")
    palettesHidden = false
  if menuItem("Brush Tip Options..."):
    brushOpts = opts[t].tip
    brushOptsNew = false
    brushOptsOpen = true
  menuSeparator()
  if menuItem("Define Brush Preset...", enabled = cur() != nil and cur().hasSelection):
    var tip = cur().tipFromSelection()
    tip.name = "Sampled Brush"
    opts[t].tip = tip
    opts[t].preset = ""
    presetDlg = (true, 0, "Sampled Brush " & $tip.diameter, -1)
  if menuItem("Restore Default Brushes"):
    presets = defaultPresets()
    savePresets()
    initOpts()
  menuSeparator()
  if menuItem("Import Brushes..."):
    proc go() =
      if brushFilePath.len == 0: brushFilePath = picturesDir()
      brushFileSave = false
      brushFilePick = true
    if askStorage(AppName, filesWhy, go): go()
  if menuItem("Export Selected Brushes..."):
    proc go() =
      brushFilePath = picturesDir() / "Retro Photo Brushes.abr"
      brushFileSave = true
      brushFilePick = true
    if askStorage(AppName, filesWhy, go): go()


# ---- Picker, Swatches, Scratch ------------------------------------------------------------------------

proc setColor(c: uint32; background = false) =
  let c2 = c or 0xFF000000'u32
  if background: bg = c2 else: fg = c2

proc pickerBody() =
  row:
    # which one is edited: the foreground or the background
    let r = place(dp(36), dp(36))
    let br = rect(r.x + dp(12), r.y + dp(12), dp(24), dp(24))
    let fr = rect(r.x, r.y, dp(24), dp(24))
    fill(br, colorOf(bg)); box(br, if pickerTarget == 1: color(0, 0, 0) else: ui.theme.shadow, 2)
    fill(fr, colorOf(fg)); box(fr, if pickerTarget == 0: color(0, 0, 0) else: ui.theme.shadow, 2)
    # (a click on the one being edited -- or a double click -- opens the
    # Color Picker, as the usual Color panel does)
    if interact(idOf("pick-fg"), fr, focusable = false).clicked:
      if pickerTarget == 0 or ui.clicks >= 2: showFgPicker = true
      pickerTarget = 0
    elif interact(idOf("pick-bg"), br, focusable = false).clicked:
      if pickerTarget == 1 or ui.clicks >= 2: showBgPicker = true
      pickerTarget = 1
    col:
      var c = if pickerTarget == 0: fg else: bg
      let w = available() - dp(40)
      case pickerSliders
      of 1:
        var hsb = toHsb(c)
        var h = int(round(hsb.h))
        var s = int(round(hsb.s * 100))
        var b = int(round(hsb.b * 100))
        var ch = false
        row:
          label "H"
          if gradientSlider(h, 359, w, proc (t: float): uint32 = fromHsb(t * 359, max(0.3, hsb.s), max(0.6, hsb.b))): ch = true
          label $h
        row:
          label "S"
          if gradientSlider(s, 100, w, proc (t: float): uint32 = fromHsb(hsb.h, t, hsb.b)): ch = true
          label $s
        row:
          label "B"
          if gradientSlider(b, 100, w, proc (t: float): uint32 = fromHsb(hsb.h, hsb.s, t)): ch = true
          label $b
        if ch: setColor(fromHsb(h.float, s / 100, b / 100), pickerTarget == 1)
      of 2:
        var k = 100 - lumaOf(c) * 100 div 255
        row:
          label "K"
          if gradientSlider(k, 100, w, proc (t: float): uint32 = grayPx(int((1 - t) * 255))):
            setColor(grayPx(int(round((100 - k).float * 2.55))), pickerTarget == 1)
          label $k & "%"
      else:
        var r2 = rOf(c)
        var g = gOf(c)
        var b = bOf(c)
        row:
          label "R"
          if gradientSlider(r2, 255, w, proc (t: float): uint32 = argb(255, int(t * 255), gOf(c), bOf(c))):
            setColor(argb(255, r2, gOf(c), bOf(c)), pickerTarget == 1)
          label $r2
        row:
          label "G"
          if gradientSlider(g, 255, w, proc (t: float): uint32 = argb(255, rOf(c), int(t * 255), bOf(c))):
            setColor(argb(255, rOf(c), g, bOf(c)), pickerTarget == 1)
          label $g
        row:
          label "B"
          if gradientSlider(b, 255, w, proc (t: float): uint32 = argb(255, rOf(c), gOf(c), int(t * 255))):
            setColor(argb(255, rOf(c), gOf(c), b), pickerTarget == 1)
          label $b
  # the color bar: the spectrum, then black to white
  let bar = place(0, dp(18), fill = true)
  let hit = interact(idOf("colorbar"), bar, focusable = false)
  if hit.down or ui.active == idOf("colorbar"): ui.dragsActive = true
  proc barColor(x, y: int): uint32 =
    let u = (x - bar.x) / max(1, bar.w - 1)
    let v = (y - bar.y) / max(1, bar.h - 1)
    if v < 0.7: fromHsb(u * 360, 1.0, 1.0)
    else: grayPx(int(u * 255))
  for x in 0 ..< bar.w:
    vline(bar.x + x, bar.y, bar.h * 7 div 10, colorOf(barColor(bar.x + x, bar.y)))
    vline(bar.x + x, bar.y + bar.h * 7 div 10, bar.h - bar.h * 7 div 10, colorOf(barColor(bar.x + x, bar.y + bar.h - 1)))
  box(bar, ui.theme.frame)
  if ui.active == idOf("colorbar") and ui.mouseDown and mouseIn(bar):
    setColor(barColor(ui.mx, ui.my), pickerTarget == 1 or AltPressed in ui.mods)

var newSwatch = 0xFF808080'u32

proc swatchesBody() =
  let ev = swatchGrid(swatches, available())
  if ev.pick >= 0:
    if ev.ctrl: swatches.delete(ev.pick)
    elif ev.shift: swatches[ev.pick] = fg
    else: setColor(swatches[ev.pick], ev.alt)
  elif ev.empty:
    swatches.add fg
  row:
    # (a new swatch of any color: from the Color Picker)
    label "New Swatch:"
    if colorWell(newSwatch, "newswatch", dp(40)): swatches.add newSwatch or 0xFF000000'u32
    if toolButton("+FG", "Add the foreground color"): swatches.add fg
  label("Click: foreground; Alt: background; Shift: replace; Ctrl: delete", color = ui.theme.gray)

var scratchStroke: Stroke
var scratchPainting = false

proc scratchBody() =
  let room = available()
  if scratch.w != max(40, room) or scratch.h != dp(64):
    let old = scratch
    scratch = newDoc(max(40, room), dp(64), white)
    for y in 0 ..< min(old.h, scratch.h):
      for x in 0 ..< min(old.w, scratch.w): scratch.layers[0].px[y * scratch.w + x] = old.layers[0].px[y * old.w + x]
    scratch.markAll()
  let r = place(scratch.w, scratch.h)
  let id = idOf("scratch")
  let hit = interact(id, r, focusable = false)
  if hit.down or ui.active == id: ui.dragsActive = true
  let x = (ui.mx - r.x).float
  let y = (ui.my - r.y).float
  if hit.down and ui.pressed:
    if tool == tEyedropper:
      setColor(scratch.pixelAt(int(x), int(y)), AltPressed in ui.mods)
    else:
      let t = if tool in {tBrush, tPencil, tAirbrush, tEraser, tSmudge, tBlur, tDodge}: tool else: tBrush
      scratch.beginStep("Scratch")
      scratchStroke = scratch.beginStroke(paintOpts(t, scratch), tipFor(t), x, y)
      scratchStroke.startStroke()
      scratchPainting = true
  elif scratchPainting and ui.mouseDown:
    scratchStroke.strokeTo(x, y)
  if scratchPainting and not ui.mouseDown:
    scratchStroke.endStroke()
    scratch.endStep()
    scratchPainting = false
  if scratchVer != scratch.ver or scratchBmp == nil:
    scratch.updateComposite()
    scratchBmp = newBitmap(scratch.w, scratch.h)
    scratchBmp.px = scratch.compCopy
    scratchBmp.changed()
    scratchVer = scratch.ver
  drawBitmap(r, scratchBmp)
  box(inset(r, -1), ui.theme.frame)
  if hit.hover: ui.cursor = curCrosshair

proc colorMenuItems(tab: int) =
  ## The menus of Color, Swatches, Scratch, Gradients, Patterns.
  case tab
  of 0:
    if menuItem("RGB Sliders", checked = pickerSliders == 0): pickerSliders = 0
    if menuItem("HSB Sliders", checked = pickerSliders == 1): pickerSliders = 1
    if menuItem("Grayscale Slider", checked = pickerSliders == 2): pickerSliders = 2
  of 1:
    if menuItem("Reset Swatches"):
      swatches.setLen(0)
      initSwatches()
    menuSeparator()
    if menuItem("Load Swatches..."): startPresetFile(pfSwatches)
    if menuItem("Replace Swatches..."): startPresetFile(pfSwatches, replace = true)
    if menuItem("Save Swatches..."): startPresetFile(pfSwatches, save = true)
    if menuItem("Add the Foreground Color"): swatches.add fg
  of 2:
    if menuItem("Clear Scratch"):
      scratch = newDoc(scratch.w, scratch.h, white)
  of 3:
    if menuItem("Gradient Editor..."): startGradientEditor(0, toolStops())
    if menuItem("Load Gradients..."): startPresetFile(pfGradients)
  else:
    if menuItem("Load Patterns..."): startPresetFile(pfPatterns)

# ---- Layers, Channels, Paths --------------------------------------------------------------------------

template layersChange(d: Doc; name: string; body: untyped) =
  ## A change of the layers (which, their order, settings, masks): undone
  ## without copying the image.
  if te.on: commitType()
  d.beginStep(name)
  d.touchLayers()
  body
  d.endStep()

proc adjustLayerMenu(d: Doc)
proc editAdjustLayer(L: Layer)

proc groupModeNames(): seq[string] =
  result = @["Pass Through"]
  for m in LayerModes: result.add $m

proc setLayerMode(d: Doc; L: Layer; k: int) =
  ## (the mode combo's `k`: for a group, 0 is Pass Through)
  if L.group:
    let pass = k == 0
    let m = if pass: L.mode else: LayerModes[clamp(k - 1, 0, LayerModes.high)]
    if pass == L.passThrough and m == L.mode: return
    d.layersChange("Layer Mode"):
      L.passThrough = pass
      L.mode = m
      d.markAll()
  elif LayerModes[k] != L.mode:
    d.layersChange("Layer Mode"):
      L.mode = LayerModes[k]
      d.markAll()

type LayerKindF = enum lkfPixel, lkfAdjust, lkfType, lkfShape, lkfSmart
  ## (the kinds the Layers panel's filter shows)

var
  layerFilterOn = false          ## the Layers panel shows only the layers that match
  layerFilterBy = 0              ## by Kind (0) or by Name (1)
  layerFilterKinds: set[LayerKindF]
  layerFilterName = ""
  layerOpacityBox, layerFillBox = 100   ## (the boxes of Opacity and Fill)

proc kindOf(L: Layer): LayerKindF =
  if L.adjust.kind.len > 0 or L.isFill: lkfAdjust
  elif L.isText: lkfType
  elif L.isShape: lkfShape
  elif L.isSmart: lkfSmart
  else: lkfPixel

proc filterActive(): bool =
  layerFilterOn and ((layerFilterBy == 0 and layerFilterKinds != {}) or
                     (layerFilterBy == 1 and layerFilterName.strip.len > 0))

proc filterMatch(L: Layer): bool =
  if L.group: return false
  if layerFilterBy == 0: L.kindOf in layerFilterKinds
  else: layerFilterName.strip.toLowerAscii in L.name.toLowerAscii

proc shownRows(d: Doc): seq[int] =
  ## The layers that have rows (not in a closed group; with the filter on,
  ## those that match it), the top first.
  if filterActive():
    for i in countdown(d.layers.high, 0):
      if d.layers[i].filterMatch: result.add i
    return
  var closedAt = -1               # (the depth of a closed group whose layers are hidden)
  for i in countdown(d.layers.high, 0):
    let L = d.layers[i]
    if closedAt >= 0:
      if L.depth > closedAt: continue
      closedAt = -1
    result.add i
    if L.group and L.collapsed: closedAt = L.depth

var liveSlider: Doc       ## a big photo whose layer opacity is being dragged: shown live

proc showOpacity(d: Doc) =
  ## (a layer's opacity changed: on a big photo, while the mouse is down,
  ## shown from the layers at the view's size -- the whole image is made
  ## again when it is let go)
  d.markAll()
  if ui.mouseDown and d.w * d.h > 4_000_000:
    if d.live.len == 0: d.setLive(@[LivePart(kind: lkMap)])
    else: d.liveChanged()
    liveSlider = d

var layerListFollow: tuple[d: pointer; cur: int]   ## (the row of the current layer kept in view)

proc lockButton(glyph: string; tip: string; on: bool; enabled = true): bool =
  ## (a lock of the Layers panel: pressed in when on)
  toolButton(glyphIcon(glyph, ui.theme.text, dp(14)), tip, down = on, enabled = enabled)

proc layersBody(d: Doc) =
  let L = d.layers[d.cur]
  # the filter: by kind (pixels, adjustments, type, shapes, Smart Objects) or by name; the switch at the right
  row:
    let bw = CtrlH + 1
    # (narrow -- a tablet's: no room for the switch; picking a kind turns the filter on)
    let roomy = available() - 6 * bw - 7 * Gap - dp(4) >= dp(56)
    if not roomy: layerFilterOn = layerFilterKinds != {} or layerFilterName.strip.len > 0
    combo(["Kind", "Name"], layerFilterBy, w = max(dp(56), available() - (if roomy: 6 else: 5) * bw - 7 * Gap - dp(4)))
    if layerFilterBy == 0:
      for (k, g, tip) in [(lkfPixel, pxImage, "Pixel layers"), (lkfAdjust, pxAdjustLayer, "Adjustment layers"),
                          (lkfType, pxTypeTool, "Type layers"), (lkfShape, pxShapeLayer, "Shape layers"),
                          (lkfSmart, pxSmartObject, "Smart Objects")]:
        if toolButton(glyphIcon(g, ui.theme.text, dp(14)), "Filter: " & tip, down = k in layerFilterKinds):
          if k in layerFilterKinds: layerFilterKinds.excl k else: layerFilterKinds.incl k
          layerFilterOn = true
    else:
      if edit(layerFilterName, w = max(dp(40), available() - CtrlH - dp(6))): layerFilterOn = true
    if roomy and toolButton(glyphIcon(if layerFilterOn: nfToggleOn else: nfToggleOff,
                                      if layerFilterOn: color(200, 0, 0) else: color(0, 0, 0), dp(16)),
                            "Layer filtering on or off", down = layerFilterOn):
      layerFilterOn = not layerFilterOn
  # the blend mode and the Opacity
  var m = if L.group: (if L.passThrough: 0 else: 1 + max(0, LayerModes.find(L.mode)))
          else: max(0, LayerModes.find(L.mode))
  template opacityStep(body: untyped) =
    if not (d.undoSteps.len > 0 and d.undoName == "Layer Opacity" and ui.mouseDown and not ui.pressed):
      d.layersChange("Layer Opacity"): discard
    body
    d.showOpacity()
  row:
    if combo((if L.group: groupModeNames() else: layerModeNames()), m, w = max(dp(80), available() - dp(122))):
      d.setLayerMode(L, m)
    var op0 = L.opacity
    if scrubLabel("Opacity:", op0, 0, 100) and op0 != L.opacity:
      opacityStep: L.opacity = op0
    layerOpacityBox = L.opacity
    if popupSlider(layerOpacityBox, 0, 100, w = dp(54)) and layerOpacityBox != L.opacity:
      opacityStep: L.opacity = clamp(layerOpacityBox, 0, 100)
  template fillControls() =
    var f0 = L.fill
    if scrubLabel("Fill:", f0, 0, 100) and f0 != L.fill:
      opacityStep: L.fill = f0
    layerFillBox = L.fill
    if popupSlider(layerFillBox, 0, 100, w = dp(54), enabled = not L.group) and layerFillBox != L.fill:
      opacityStep: L.fill = clamp(layerFillBox, 0, 100)
  # the locks and the Fill (on a narrow panel the Fill on a row of its own)
  let fillApart = textWidth("Lock:") + 4 * (CtrlH + 1) + textWidth("Fill:") + dp(54) + 7 * Gap > available()
  row:
    label "Lock:"
    let can = not L.background
    if lockButton(nfTh, "Lock transparent pixels", L.lockAlpha, can and not L.group):
      d.layersChange("Lock Transparent Pixels"): L.lockAlpha = not L.lockAlpha
    if lockButton(pxBrush, "Lock image pixels", L.lockPixels, can):
      d.layersChange("Lock Image Pixels"): L.lockPixels = not L.lockPixels
    if lockButton(pxMoveTool, "Lock position", L.lockPosition, can):
      d.layersChange("Lock Position"): L.lockPosition = not L.lockPosition
    if lockButton(pxLock, "Lock all", L.locked, can):
      d.layersChange(if L.locked: "Unlock Layer" else: "Lock Layer"): L.locked = not L.locked
    if not fillApart: fillControls()
  if fillApart:
    row:
      spring()
      fillControls()
  # the rows, the top layer first (not those in a closed group)
  var rows: seq[LayerRow]
  let rowH = dp(30)
  let idx = d.shownRows
  for i in idx:
    let l = d.layers[i]
    rows.add LayerRow(name: l.name, thumb: (if l.isText or l.group: nil else: thumbOf(d, l, rowH - dp(6))),
                      visible: l.visible, active: i == d.cur and not d.quickMask,
                      lock: l.lockAlpha or l.lockPixels or l.lockPosition,
                      icon: (if l.adjust.kind.len > 0: pxAdjustLayer elif l.isFill: pxFillLayer
                             elif l.isShape: pxShapeLayer elif l.isSmart: pxSmartObject else: ""),
                      clipped: l.clipped and i > 0 and not l.group,
                      maskThumb: (if l.mask != nil: thumbOf(d, l.mask, rowH - dp(6)) else: nil),
                      maskActive: i == d.cur and d.editMask and l.mask != nil, maskOff: l.maskOff,
                      thumbGlyph: (if l.isText: pxTypeTool else: ""), fx: l.hasStyle, fxOff: l.fx.hidden,
                      indent: l.depth, group: l.group, collapsed: l.collapsed,
                      picked: l.picked and i != d.cur, locked: l.locked,
                      linked: l.link != 0)
  let listH = max(rowH, remainingH() - (CtrlH + 1) - Gap - 1)   # (the buttons under it)
  if layerListFollow != (cast[pointer](d), d.cur):
    # (another layer current -- picked on the canvas, a new one: its row in view)
    layerListFollow = (cast[pointer](d), d.cur)
    let at = idx.find(d.cur)
    if at >= 0:
      let sid = makeId(fnv("scroll-panel" & "layerlist"))
      var y = state(sid).scrollY
      let top = at * rowH
      if top < y: y = top
      elif top + rowH + 2 * Pad > y + listH - 2: y = top + rowH + 2 * Pad - (listH - 2)
      state(sid).scrollY = max(0, y)
  beginScroll(listH, "layerlist")
  let ev = layerRows(rows, available(), rowH, "layers", brushColumn = true)
  # (a right click on the layers: group them -- several picked -- or ungroup, and the rest)
  contextMenu:
    let several = d.pickedLayers.len > 1
    if menuItem(if several: "&Group Layers" else: "&Group Layer", "Ctrl+G", enabled = not d.current.background):
      runCommand("Group Layers")
    if menuItem("&Ungroup Layers", "Ctrl+Shift+G", enabled = d.current.group): runCommand("Ungroup Layers")
    menuSeparator()
    if menuItem("&Duplicate Layer"):
      d.layersChange("Duplicate Layer"): discard d.duplicateLayer()
    if menuItem("De&lete Layer", enabled = d.layers.len > 1):
      d.layersChange(if d.current.group: "Delete Group" else: "Delete Layer"): d.deleteLayer()
    if menuItem(if d.current.group: "Merge Grou&p" else: "Merge Do&wn", "Ctrl+E"):
      runCommand(if d.current.group: "Merge Group" else: "Merge Down")
    menuSeparator()
    if menuItem("&Blending Options...", enabled = not d.current.background): runCommand("Blending Options...")
  endScroll()
  if te.on and (ev.eyeToggled >= 0 or ev.fxClicked >= 0 or ev.clicked >= 0 or ev.moved[0] >= 0 or
                ev.activated >= 0 or ev.thumbClicked >= 0 or ev.maskClicked >= 0 or ev.toggled >= 0):
    commitType()
    if d.shownRows != idx: return     # (an empty type layer went: the rows are not these)
  if ev.toggled >= 0:
    let g = d.layers[idx[ev.toggled]]
    g.collapsed = not g.collapsed
    # (the current layer hidden in it: the group is current)
    if g.collapsed and d.cur < idx[ev.toggled] and d.cur >= d.blockStart(idx[ev.toggled]):
      d.cur = idx[ev.toggled]
      d.editMask = false
    inc d.ver
  if ev.eyeToggled >= 0:
    let i = idx[ev.eyeToggled]
    d.layersChange("Show/Hide Layer"):
      if AltPressed in ui.mods:
        for k, l in d.layers: l.visible = k == i or (l.group and k > i and d.blockStart(k) <= i)
      else:
        d.layers[i].visible = not d.layers[i].visible
      d.markAll()
  if ev.clipAt >= 0:
    # Alt+click between two layers: a clipping mask made or let go
    let i = idx[ev.clipAt]
    if i > 0 and not d.layers[i].background:
      d.layersChange(if d.layers[i].clipped: "Release Clipping Mask" else: "Create Clipping Mask"):
        d.layers[i].clipped = not d.layers[i].clipped
        d.markAll()
  if ev.fxClicked >= 0:
    # the style's mark: its dialog
    d.cur = idx[ev.fxClicked]
    d.editMask = false
    startLayerStyle(-1)
  elif ev.clicked >= 0 and ev.ctrl and (ev.thumbClicked >= 0 or ev.maskClicked >= 0):
    # Ctrl+click on a thumbnail: the layer's shape (or its mask) as the
    # selection; with Shift added, Alt taken away, both: where they cross
    let l = d.layers[idx[ev.clicked]]
    let fromMask = ev.maskClicked >= 0 and l.mask != nil
    var m = newSeq[uint8](d.w * d.h)
    if fromMask:
      for k, v in l.mask.px: m[k] = uint8(v and 255)
    elif l.px.len == m.len:
      for k, v in l.px: m[k] = uint8(v shr 24)
    let op = if ev.shift and ev.alt: soIntersect elif ev.shift: soAdd elif ev.alt: soSubtract else: soReplace
    d.beginStep("Load Selection")
    d.touchSel()
    d.setSelection(m, op)
    d.endStep()
  elif ev.clicked >= 0:
    let i = idx[ev.clicked]
    let l = d.layers[i]
    if ev.ctrl and ev.maskClicked < 0:
      # Ctrl+click: picked with the others (or not)
      if i != d.cur: l.picked = not l.picked
      inc d.ver
    elif ev.shift and ev.maskClicked < 0 and ev.thumbClicked < 0:
      # Shift+click: all from the current one to it picked
      let a = idx.find(d.cur)
      if a >= 0:
        for k in min(a, ev.clicked) .. max(a, ev.clicked): d.layers[idx[k]].picked = true
      inc d.ver
    else:
      if ev.maskClicked >= 0 and ev.shift and l.mask != nil:
        # Shift+click on the mask: off and on again
        d.layersChange(if l.maskOff: "Enable Layer Mask" else: "Disable Layer Mask"):
          l.maskOff = not l.maskOff
          d.markAll()
      if not l.picked: d.clearPicks()
      d.cur = i
      d.editMask = ev.maskClicked >= 0 and l.mask != nil
      inc d.ver
  if ev.activated >= 0 and ev.fxClicked < 0:
    let l = d.layers[idx[ev.activated]]
    if l.adjust.kind.len > 0:
      editAdjustLayer(l)      # (an adjustment layer: its dialog again)
    elif l.isFill and ev.maskClicked < 0:
      startFillLayer(l.shape.fill.kind, l)
    elif l.isText and ev.thumbClicked >= 0 and active != nil:
      # (the "T": all its text, to be edited)
      selectTool(tType)
      if not te.on:
        startTypeEdit(active, l, false, 0)
      te.anchor = 0
      te.caret = l.text.runeLen
    elif l.isSmart and ev.thumbClicked >= 0:
      editSmartContents(d, l)
    else:
      layerOptsName = l.name
      layerOptsOpacity = l.opacity
      layerOptsMode = if l.group: (if l.passThrough: 0 else: 1 + max(0, LayerModes.find(l.mode)))
                      else: max(0, LayerModes.find(l.mode))
      layerOptsOpen = true
      typeFirst()
  if ev.moved.src >= 0:
    let src = idx[ev.moved.src]
    if ev.into >= 0:
      let g = idx[ev.into]
      if g != src:
        d.layersChange("Layer Order"): discard d.moveBlock(src, g, d.layers[g].depth + 1)
    else:
      let gap = ev.moved.dst
      var lgap, depth: int
      if gap <= 0:
        lgap = d.layers.len
        depth = 0
      else:
        let x = idx[gap - 1]
        let xl = d.layers[x]
        if xl.group and not xl.collapsed:
          lgap = x
          depth = xl.depth + 1
        else:
          lgap = d.blockStart(x)
          depth = xl.depth
      depth = min(depth, ev.dropIndent)
      d.layersChange("Layer Order"): discard d.moveBlock(src, lgap, depth)
  # the buttons, as the usual: Link, Style, Mask, Adjustment, Group, New, Delete -- at the right
  row:
    let n = 7
    let spare = available() - n * (CtrlH + 1) - (n - 1) * Gap
    if spare > 0: space(spare - Gap)
    let picked = d.pickedLayers
    let linked = L.link != 0
    if toolButton(glyphIcon(nfLink, ui.theme.text, dp(15)),
                  if linked: "Unlink Layers" else: "Link Layers (pick them with Ctrl+click first)",
                  down = linked, enabled = linked or picked.len > 1):
      if linked:
        d.layersChange("Unlink Layers"): d.unlinkLayers(if picked.len > 1: picked else: @[d.cur])
      else:
        d.layersChange("Link Layers"): d.linkLayers(picked)
    if toolButton(glyphIcon(pxLayerStyle, ui.theme.text, dp(16)), "Add a Layer Style",
                  enabled = not L.background and L.adjust.kind.len == 0):
      openPopupMenu("fxmenu", ui.mx, ui.my)
    if toolButton(glyphIcon(pxLayerMask, ui.theme.text, dp(16)), "Add Layer Mask (Alt: hiding all)",
                  enabled = not L.background and L.mask == nil and L.adjust.kind.len == 0):
      d.layersChange("Add Layer Mask"):
        d.addLayerMask(if AltPressed in ui.mods: (if d.hasSelection: mfHideSelection else: mfHideAll)
                       elif d.hasSelection: mfRevealSelection else: mfRevealAll)
        d.editMask = true
    if toolButton(glyphIcon(pxAdjustLayer, ui.theme.text, dp(16)), "New Fill or Adjustment Layer"):
      openPopupMenu("adjlayermenu", ui.mx, ui.my)
    let several = d.pickedLayers.len > 1
    if toolButton(glyphIcon(pxFolder, ui.theme.text, dp(16)),
                  (if several: "Group the layers picked (Ctrl+G)" else: "New Group (Ctrl+click: Group Layers)")):
      if CtrlPressed in ui.mods or several:
        d.layersChange("Group Layers"): discard d.groupLayers(d.pickedLayers)
      else:
        d.layersChange("New Group"): discard d.addGroup()
    if toolButton(glyphIcon(pxNew, ui.theme.text, dp(16)), "New Layer (Alt: Duplicate Layer)"):
      if AltPressed in ui.mods:
        d.layersChange("Duplicate Layer"): discard d.duplicateLayer()
      else:
        d.layersChange("New Layer"): discard d.addLayer()
    if toolButton(glyphIcon(pxTrash, ui.theme.text, dp(16)), "Delete Layer", enabled = d.layers.len > 1):
      d.layersChange(if L.group: "Delete Group" else: "Delete Layer"): d.deleteLayer()
  popupMenu("adjlayermenu"): adjustLayerMenu(d)
  popupMenu("fxmenu"): layerStyleMenu(d)

proc channelsBody(d: Doc) =
  var rows: seq[LayerRow]
  let rowH = dp(30)
  let names = d.channelNames
  let all = d.colorChannelsAll and d.viewChannel < 0
  # (a Multichannel image: its inks alone, no channel of them mixed first)
  let comp = d.hasComposite
  for i, nm in names:
    let ch = if names.len == 1: -1 elif comp: i - 1 else: i
    let on = if ch < 0: all else: d.channelsOn[ch] and not all
    # (the keys: the usual Ctrl+2 for all, Ctrl+3.. a channel; 1994's Ctrl+0,
    # 1..; a Multichannel image's inks Ctrl+1..)
    let k = if not comp and names.len > 1: i + 1 elif prefs.keySet == 0: i + 2 else: i
    rows.add LayerRow(name: nm, thumb: channelThumb(d, ch, rowH - dp(6)), visible: ch < 0 or d.channelsOn[ch] or all,
                      active: on and not d.quickMask, note: "Ctrl+" & $k)
  for k, a in d.alphas:
    rows.add LayerRow(name: a.name, thumb: channelThumb(d, 4 + k, rowH - dp(6)), visible: false,
                      note: "Ctrl+" & $(names.len + k + (if prefs.keySet == 0: 2 else: 0)))
  if d.quickMask:
    rows.add LayerRow(name: "Quick Mask", visible: true, active: true)
  let listH = max(rowH, remainingH() - (CtrlH + 1) - Gap - 1)   # (the buttons under it)
  beginScroll(listH, "chanlist")
  let ev = layerRows(rows, available(), rowH, "channels", brushColumn = true)
  endScroll()
  if ev.clicked >= 0:
    if ev.clicked < names.len:
      let ch = if names.len == 1: -1 elif comp: ev.clicked - 1 else: ev.clicked
      # (an ink of a Multichannel image clicked again: all of them again)
      if ch < 0 or (not comp and d.viewChannel == ch): d.showAllChannels()
      else: d.showChannel(ch)
      inc d.ver
    elif ev.clicked - names.len < d.alphas.len:
      d.beginStep("Load Selection")
      d.touchSel()
      d.loadSelection(ev.clicked - names.len)
      d.endStep()
  row:
    if toolButton(glyphIcon(pxMarqueeEllipse, ui.theme.text, dp(16)), "Save the Selection as a Channel",
                  enabled = d.hasSelection):
      d.snapStep("Save Selection")
      discard d.saveSelection()
      d.endStep()
    # (deleting a color channel -- the one shown -- makes the image
    # Multichannel: its ink taken out; else the last saved selection goes)
    let colorCh = d.viewChannel >= 0 and d.canDeleteSpot
    if toolButton(glyphIcon(pxTrash, ui.theme.text, dp(16)),
                  (if colorCh: "Delete the Channel (Multichannel)" else: "Delete the Last Channel"),
                  enabled = colorCh or d.alphas.len > 0):
      if colorCh: runCommand("Delete Color Channel")
      else:
        d.snapStep("Delete Channel")
        d.alphas.setLen(d.alphas.len - 1)
        d.endStep()

proc pathsBody(d: Doc) =
  # the path tools of 1994: the arrow, the pen, add, delete and convert point
  row:
    for k, (g, tip) in [(pxPathArrow, "Direct Selection: drag the points and their handles (of a shape layer too)"),
                        (pxPen, "Pen (P): click for corners, drag for curves"),
                        (pxPenAdd, "Add a point: click on the path"),
                        (pxPenRemove, "Delete a point: click it"),
                        (pxConvertPoint, "Convert: click a curve's point for a corner, drag a corner for a curve"),
                        (pxPathSelect, "Path Selection: drag a whole shape of the path (Alt: a copy; Delete: away)")]:
      if toolButton(glyphIcon(g, ui.theme.text, dp(16)), tip, down = tool == tPen and penMode == k):
        selectTool(tPen)
        penMode = k
        status = tip
  var rows: seq[LayerRow]
  let rowH = dp(24)
  for i, p in d.paths:
    rows.add LayerRow(name: p.name, active: i == d.curPath, visible: i == d.curPath)
  let listH = max(rowH, remainingH() - (CtrlH + 1) - Gap - 1)   # (the buttons under it)
  beginScroll(listH, "pathlist")
  let ev = layerRows(rows, available(), rowH, "paths")
  endScroll()
  if ev.clicked >= 0 or ev.eyeToggled >= 0:
    let i = max(ev.clicked, ev.eyeToggled)
    d.curPath = if d.curPath == i and ev.eyeToggled >= 0: -1 else: i
    inc d.ver
  let has = d.curPath >= 0 and d.curPath < d.paths.len
  row:
    if toolButton(glyphIcon(pxBucket, ui.theme.text, dp(16)), "Fill the Path", enabled = has):
      d.beginStep("Fill Path")
      d.fillPath(d.paths[d.curPath], fg)
      d.endStep()
    if toolButton(glyphIcon(pxBrush, ui.theme.text, dp(16)), "Stroke the Path (with the painting tool)", enabled = has):
      let t = if tool in brushTools: tool else: tBrush
      d.beginStep("Stroke Path")
      d.strokePath(d.paths[d.curPath], paintOpts(t, d), tipFor(t))
      d.endStep()
    if toolButton(glyphIcon(pxMarqueeEllipse, ui.theme.text, dp(16)), "Make a Selection of the Path", enabled = has):
      var m = d.pathMask(d.paths[d.curPath])
      d.beginStep("Make Selection")
      d.touchSel()
      d.setSelection(m)
      d.endStep()
    if toolButton(glyphIcon(pxPen, ui.theme.text, dp(16)), "Make a Path of the Selection", enabled = d.hasSelection):
      d.snapStep("Make Path")
      d.paths.add d.pathFromSelection()
      d.curPath = d.paths.high
      d.endStep()
    if toolButton(glyphIcon(pxTrash, ui.theme.text, dp(16)), "Delete the Path", enabled = has):
      d.snapStep("Delete Path")
      d.paths.delete(d.curPath)
      d.curPath = -1
      d.endStep()

proc layerMenuItems(tab: int) =
  ## The menus of Layers, Channels, Paths.
  let d = cur()
  case tab
  of 0:
    if menuItem("New Layer...", enabled = d != nil):
      newLayerName = ""
      newLayerOpen = true
      typeFirst()
    if menuItem("New Layer from File...", enabled = d != nil): runCommand("Layer from File...")
    if menuItem("Duplicate Layer", enabled = d != nil):
      d.layersChange("Duplicate Layer"): discard d.duplicateLayer()
    if menuItem("Delete Layer", enabled = d != nil and d.layers.len > 1):
      d.layersChange("Delete Layer"): d.deleteLayer()
    if menuItem("New Group...", enabled = d != nil): runCommand("New Group...")
    if menuItem("Group Layers", enabled = d != nil): runCommand("Group Layers")
    if menuItem("Ungroup Layers", enabled = d != nil and d.current.group): runCommand("Ungroup Layers")
    if menuItem(if d != nil and d.current.group: "Group Properties..." else: "Layer Options...",
                enabled = d != nil):
      runCommand("Layer Options...")
    menuSeparator()
    let clc = d != nil and d.current.clipped
    if menuItem(if clc: "Release Clipping Mask" else: "Create Clipping Mask",
                enabled = d != nil and (clc or (d.cur > 0 and not d.current.background))):
      runCommand(if clc: "Release Clipping Mask" else: "Create Clipping Mask")
    menuSeparator()
    submenu "New Adjustment Layer":
      if d != nil: adjustLayerMenu(d)
    submenu "Layer Style":
      layerStyleMenu(d)
    submenu "Type":
      typeMenu(d)
    let cl = if d != nil: d.current else: nil
    let canMask = cl != nil and not cl.background and cl.mask == nil and cl.adjust.kind.len == 0
    submenu "Add Layer Mask":
      for how in MaskFill:
        if menuItem($how, enabled = canMask and (how in {mfRevealAll, mfHideAll} or d.hasSelection)):
          d.layersChange("Add Layer Mask"):
            d.addLayerMask(how)
            d.editMask = true
    let hasMask = cl != nil and cl.mask != nil
    if menuItem(if hasMask and cl.maskOff: "Enable Layer Mask" else: "Disable Layer Mask", enabled = hasMask):
      d.layersChange("Layer Mask"):
        cl.maskOff = not cl.maskOff
        d.markAll()
    if menuItem("Apply Layer Mask", enabled = hasMask):
      d.layersChange("Apply Layer Mask"): d.removeLayerMask(apply = true)
    if menuItem("Delete Layer Mask", enabled = hasMask):
      d.layersChange("Delete Layer Mask"): d.removeLayerMask()
    menuSeparator()
    if menuItem(if d != nil and d.current.group: "Merge Group" else: "Merge Down",
                enabled = d != nil and canMergeDown(d)):
      runCommand("Merge Down")
    if menuItem("Merge Visible", enabled = d != nil and d.layers.len > 1):
      d.layersChange("Merge Visible"):
        for l in d.layers:
          if l.visible:
            d.touch(l, d.bounds)
            break
        d.mergeVisible()
    if menuItem("Flatten Image", enabled = d != nil and d.layers.len > 1):
      d.layersChange("Flatten Image"): d.flatten(bg)
    if menuItem("Layer from Background", enabled = d != nil and d.layers[0].background):
      d.layersChange("Layer from Background"): d.layerFromBackground()
  of 1:
    if menuItem("Save Selection as Channel", enabled = d != nil and d.hasSelection):
      d.snapStep("Save Selection")
      discard d.saveSelection()
      d.endStep()
    if menuItem("Delete Channel", enabled = d != nil and d.alphas.len > 0):
      d.snapStep("Delete Channel")
      d.alphas.setLen(d.alphas.len - 1)
      d.endStep()
    if menuItem("Show All Channels", enabled = d != nil):
      d.showAllChannels()
      inc d.ver
  else:
    if menuItem("Make Work Path", enabled = d != nil and d.hasSelection):
      d.snapStep("Make Path")
      d.paths.add d.pathFromSelection()
      d.curPath = d.paths.high
      d.endStep()
    if menuItem("Turn Off Path", enabled = d != nil and d.curPath >= 0):
      d.curPath = -1
      inc d.ver

# ---- Info, Commands -----------------------------------------------------------------------------------

proc infoPalBody() =
  let d = cur()
  let small = TextStyle(size: 0.95)
  proc cell(x, y: int; glyph: string; lines: openArray[(string, string)]) =
    # the little picture of what is measured, then the figures
    if glyph == "+":
      let cx = x + dp(7)
      let cy = y + dp(7)
      hline(cx - dp(6), cy, dp(13), ui.theme.text)
      vline(cx, cy - dp(6), dp(13), ui.theme.text)
    else:
      image(x, y, glyphIcon(glyph, ui.theme.text, dp(14)))
    var yy = y
    for (k, v) in lines:
      text(x + dp(17), yy, k, ui.theme.text, small)
      text(x + dp(32), yy, v, ui.theme.text, small)
      yy += FontH
  let r = place(0, 6 * FontH + dp(6), fill = true)
  let half = r.w div 2
  let mid = r.y + 4 * FontH + dp(2)
  hline(r.x, mid, r.w, ui.theme.shadow)
  vline(r.x + half, r.y, r.h, ui.theme.shadow)
  let c = info.c
  let shown = d != nil and info.inside
  let cm = if shown: toCmyk(c) else: (c: 0, m: 0, y: 0, k: 0)   # (the inks' table: made when first needed)
  cell(r.x + dp(2), r.y, pxEyedropper, [("R:", if shown: $rOf(c) else: ""), ("G:", if shown: $gOf(c) else: ""),
                          ("B:", if shown: $bOf(c) else: "")])
  cell(r.x + half + dp(4), r.y, pxEyedropper, [("C:", if shown: $cm.c & "%" else: ""), ("M:", if shown: $cm.m & "%" else: ""),
                                 ("Y:", if shown: $cm.y & "%" else: ""), ("K:", if shown: $cm.k & "%" else: "")])
  cell(r.x + dp(2), mid + dp(3), "+", [("X:", if d != nil: $int(floor(info.x)) else: ""),
                                  ("Y:", if d != nil: $int(floor(info.y)) else: "")])
  var wv, hv = ""
  var keys = ("W:", "H:")
  if info.sized:
    if tool == tGradient or (tool == tShape and shapeKind == 4):
      keys = ("A:", "D:")
      wv = formatFloat(info.angle, ffDecimal, 1) & "°"
      hv = formatFloat(info.dist, ffDecimal, 1)
    else:
      wv = $int(round(info.w))
      hv = $int(round(info.h))
  elif d != nil and d.hasSelection:
    let b = d.selBounds
    wv = $b.w
    hv = $b.h
  cell(r.x + half + dp(4), mid + dp(3), if keys[0] == "A:": pxLineTool else: pxMarqueeRect,
       [(keys[0], wv), (keys[1], hv)])

proc cmdPalBody() =
  let d = cur()
  let cmds = ["New...", "Open...", "Save", "Undo", "Fill...", "Levels...", "Curves...",
              "Hue/Saturation...", "Gaussian Blur...", "Image Size...", "Flatten Image", "Select All"]
  let w = (available() - dp(4)) div 2
  var i = 0
  while i < cmds.len:
    row:
      for k in 0 .. 1:
        if i + k < cmds.len:
          if button(cmds[i + k], w = w): runCommand(cmds[i + k])
    i += 2
  discard d

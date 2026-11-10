# (included by photo.nim) The options bar: the current tool's options in a
# strip under the menu bar -- what the 1994 program kept in its Options
# palette, laid out the way later versions put it, with 3.1 buttons, drop-
# down lists and sliders that drop down. (Window > Options Bar hides it;
# the Options palette still has everything.)

proc barIcon(glyph, tip: string; down = false; enabled = true): bool {.discardable.} =
  toolButton(glyphIcon(glyph, ui.theme.text, dp(16)), tip, down, enabled)

proc barCheck(lab: string; v: var bool): bool {.discardable.} =
  ## A check box in the bar.
  checkbox(lab, v)

proc barBrush(t: Tool) =
  ## The brush: its tip and size; the size, hardness and presets drop down
  ## from it; the button beside it opens Brush Settings.
  brushPicker(t)
  if barIcon(pxBrush, "Brush Settings (F5)", down = panelShown("brushsettings")):
    togglePanel("brushsettings")
    palettesHidden = false

proc barMode(t: Tool) =
  label "Mode:"
  var m = opts[t].mode
  if combo(modeNames(), m, w = dp(100)): opts[t].mode = m

proc barOpacity(t: Tool; what = "Opacity:") =
  scrubLabel(what, opts[t].opacity, 1, 100)        # (dragged across: as the usual)
  popupSlider(opts[t].opacity, 1, 100)

proc barFlow(t: Tool) =
  var f = if opts[t].dyn.flow <= 0: 100 else: opts[t].dyn.flow
  if scrubLabel("Flow:", f, 1, 100): opts[t].dyn.flow = f
  if popupSlider(f, 1, 100): opts[t].dyn.flow = f

proc barSelModes() =
  ## New, Add, Subtract, Intersect (Shift and Alt do it too).
  for k, (g, tip) in [(pxSelNew, "New Selection"), (pxSelAdd, "Add to Selection (Shift)"),
                      (pxSelSubtract, "Subtract from Selection (Alt)"),
                      (pxSelIntersect, "Intersect with Selection (Shift+Alt)")]:
    if barIcon(g, tip, down = touchSelMode == k): touchSelMode = k
  toolSeparator()

proc barFeather(v: var int) =
  label "Feather:"
  spin(v, 0, 250, w = dp(56))
  label "px"

proc barSource() =
  if toolButton(if stampPicking: "Tap the source..." else: "Set Source",
                "The place to copy from (Alt+click on the image)", down = stampPicking):
    stampPicking = not stampPicking

proc commitCrop() = commitCropNow()

proc barType() =
  # (the usual Type tool and Type Mask tool)
  var tm = ord(typeMaskMode)
  accessName(tr("Type tool"))
  if combo(["Type", "Type Mask"], tm, w = dp(90)): typeMaskMode = tm == 1
  # (Toggle Text Orientation: the text being edited, or the next one)
  let L0 = typeTarget()
  if barIcon(pxTypeTool, (if typeVertical: "Horizontal type" else: "Vertical type") & " (toggle the orientation)",
             down = typeVertical):
    typeVertical = not typeVertical
    if L0 != nil and L0.text.boxW <= 0 and not L0.text.onPath:
      applyText("Text Orientation", proc (t: var TextData) = t.vertical = typeVertical)
  let s = shownStyle()
  cpFamily = s.family
  cpStyle = s.style
  if fontCombo(cpFamily, w = dp(150)):
    let f = cpFamily
    let sts = fontStyles(f)
    var st = s.style
    if st notin sts:
      st = sts[0]
      for cand in ["Regular", "Book", "Roman", "Normal", "Medium"]:
        if cand in sts:
          st = cand
          break
    let st2 = st
    applyChar("Font", proc (x: var CharStyle) = (x.family = f; x.style = st2))
  if fontStyleCombo(s.family, cpStyle, w = dp(96)):
    let st = cpStyle
    applyChar("Font Style", proc (x: var CharStyle) = x.style = st)
  cpSize = int(round(s.size))
  if spin(cpSize, 1, 2000, w = dp(60)):
    let v = float32(cpSize)
    applyChar("Font Size", proc (x: var CharStyle) = x.size = v)
  label "px"
  var c = if te.on or typeTarget() != nil: s.color else: fg
  if colorWell(c, "bartypecolor", dp(26)):
    let cc = c
    if typeTarget() == nil: fg = cc
    applyChar("Text Color", proc (x: var CharStyle) = x.color = cc)
  toolSeparator()
  let L = typeTarget()
  alignButtons(if L != nil: L.text.para.align else: typePara.align, false)
  directionButtons()
  if barIcon(pxWarpText, "Warp Text", enabled = L != nil and not L.text.onPath): startWarp()
  if barIcon(pxCharacter, "Character and Paragraph palettes", down = panelShown("character") or panelShown("paragraph") or panelShown("glyphs")): showTypePal(typeTab)
  if te.on:
    toolSeparator()
    if toolButton("Commit", "Commit the text (Enter on the keypad)"): commitType()
    if toolButton("Cancel", "Cancel the typing (Esc)"): cancelType()

proc barShape() =
  for k, g in [pxRectShape, pxRoundRectShape, pxEllipseShape, pxPolygonShape, pxLineTool, pxCustomShape,
               pxStarShape, pxSpiral, pxPolygonShape]:
    if barIcon(g, shapeNames[k], down = shapeKind == k): shapeKind = k
  toolSeparator()
  let d = cur()
  if d != nil and d.current.isShape and d.current != shapeSynced:
    shapeSynced = d.current
    syncShapeOptions(d.current)
  elif d == nil or not d.current.isShape: shapeSynced = nil
  accessName(tr("Shape tool mode"))
  combo(["Shape Layer", "Path", "Pixels"], shapeMode, w = dp(100))
  if shapeMode == 0 and shapeKind != 4:
    var changed = false
    label "Fill:"
    if combo(["None", "Color", "Gradient"], shapeFillKind, w = dp(80)): changed = true
    if shapeFillKind > 0:
      if colorWell(shapeFill, "barshapefill", dp(26)): changed = true
    if shapeFillKind == 2:
      if colorWell(shapeFill2, "barshapefill2", dp(26)): changed = true
    label "Stroke:"
    if combo(["None", "Color"], shapeStrokeKind, w = dp(70)): changed = true
    if shapeStrokeKind > 0:
      if colorWell(shapeStroke, "barshapestroke", dp(26)): changed = true
      if spin(shapeStrokeW, 1, 500, w = dp(56)): changed = true
      label "px"
    if changed: applyShapeOptions()
  elif shapeMode == 2:
    barMode(tShape)
    barOpacity(tShape)
  case shapeKind
  of 1:
    label "Radius:"
    spin(shapeRadius, 0, 2000, w = dp(60))
  of 3:
    label "Sides:"
    spin(polySides, 3, 100, w = dp(52))
    barCheck("Star", polyStar)
  of 4: lineOptions(true)
  of 6:
    label "Points:"
    spin(starPoints, 3, 100, w = dp(52))
    label "Indent:"
    spin(starIndent, 1, 99, w = dp(52))
    label "%"
  of 7:
    label "Turns:"
    spin(spiralTurns, 1, 30, w = dp(52))
    label "Decay:"
    spin(spiralDecay, 5, 99, w = dp(52))
    label "%"
  else: discard

proc barGradient() =
  if gradientSwatch("bargrad", toolStops(), dp(96), EditH, false, gradReverse).clicked:
    startGradientEditor(0, toolStops())
  for k, (g, tip) in [(pxGradLinear, "Linear Gradient"), (pxGradRadial, "Radial Gradient"),
                      (pxGradAngle, "Angle Gradient"), (pxGradReflected, "Reflected Gradient"),
                      (pxGradDiamond, "Diamond Gradient")]:
    if barIcon(g, tip, down = gradKind == k): gradKind = k
  toolSeparator()
  barMode(tGradient)
  barOpacity(tGradient)
  barCheck("Reverse", gradReverse)
  barCheck("Dither", gradDither)

proc barAlign() =
  let d = cur()
  let some = d != nil and not d.current.background
  for (how, g) in [(alTop, pxAlignEdgeTop), (alVCenter, pxAlignEdgeVCenter), (alBottom, pxAlignEdgeBottom),
                   (alLeft, pxAlignEdgeLeft), (alHCenter, pxAlignEdgeHCenter), (alRight, pxAlignEdgeRight)]:
    if barIcon(g, "Align " & $how, enabled = some):
      let idxs = d.pickedLayers
      let to = d.alignTarget(idxs)
      d.layersChange("Align " & $how): d.alignLayers(idxs, how, to)

proc optionsBar() =
  ## The strip under the menu bar.
  if not optionsBarOn or screenMode == 2: return
  let t = tool
  toolbar:
    if wm.kind != wkNone:
      discard toolButton(glyphIcon(if wm.kind == wkPuppet: pxPuppetWarp else: pxWarp, ui.theme.text, dp(16)),
                         $wm.kind)
      toolSeparator()
      warpModeBar()
    elif xf.on:
      label($xf.kind & (if xfSmart != nil: " (Smart Object)" elif xfText.on: " (type)" else: "") &
            ": drag the handles; Shift keeps the proportions, Alt from the middle")
      toolSeparator()
      # (the size, as the usual W and H)
      var x0, y0 = 1e18
      var x1, y1 = -1e18
      for (x, y) in xf.quad:
        x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
      label("W: " & $int(round((x1 - x0) * 100 / max(1, xf.r.w).float)) & "%  H: " &
            $int(round((y1 - y0) * 100 / max(1, xf.r.h).float)) & "%")
      toolSeparator()
      if toolButton("OK", "Finish (Enter)"): finishTransform(true)
      if toolButton("Cancel", "Leave it as it was (Esc)"): finishTransform(false)
    else:
      if toolButton(glyphIcon(toolGlyph(t), ui.theme.text, dp(16)), toolName(t) & " Options (the Options palette)",
                    down = panelShown("options")):
        togglePanel("options")
      toolSeparator()
      case t
      of tMarquee:
        barSelModes()
        accessName(tr("Marquee shape"))
        combo(["Rectangular", "Elliptical", "Single Row", "Single Column"], marqueeShape, w = dp(100))
        barFeather(marqueeFeather)
        barCheck("Anti-aliased", marqueeAA)
        label "Style:"
        combo(["Normal", "Fixed Ratio", "Fixed Size"], marqueeStyle, w = dp(96))
        if marqueeStyle > 0:
          label "W:"
          spin(marqueeW, 1, 30000, w = dp(60))
          label "H:"
          spin(marqueeH, 1, 30000, w = dp(60))
        toolSeparator()
        if toolButton("Select and Mask...", enabled = cur() != nil): runCommand("Select and Mask...")
      of tLasso:
        barSelModes()
        barFeather(lassoFeather)
        barCheck("Anti-aliased", lassoAA)
        if lassoMode == 2:
          toolSeparator()
          label "Width:"
          spin(magWidth, 1, 256, w = dp(52))
          label "px  Contrast:"
          spin(magContrast, 1, 100, w = dp(52))
          label "%  Frequency:"
          spin(magFrequency, 0, 100, w = dp(52))
        toolSeparator()
        if toolButton("Select and Mask...", enabled = cur() != nil): runCommand("Select and Mask...")
      of tWand:
        accessName(tr("Selection tool"))
        combo(["Magic Wand", "Quick Selection", "Object Selection", "Selection Brush"], wandMode, w = dp(120))
        if wandMode != 3: barSelModes()
        case wandMode
        of 3:
          # the Selection Brush: add or take away, its size and hardness, the red overlay
          var m = ord(selBrushSub)
          accessName(tr("The brush adds or subtracts"))
          if combo(["Add", "Subtract"], m, w = dp(84)): selBrushSub = m == 1
          label "Size:"
          popupSlider(quickSize, 1, 1000, unit = "px")
          label "Hardness:"
          popupSlider(selBrushHard, 0, 100, unit = "%")
          barCheck("Overlay", selBrushOverlay)
          label("Alt: the other way; [ ] the size", color = ui.theme.gray)
        of 1:
          label "Size:"
          popupSlider(quickSize, 2, 400, unit = "px")
          barCheck("Sample All Layers", wandMerged)
        of 2:
          barCheck("Object Finder", objectFinder)
          barCheck("Sample All Layers", wandMerged)
        else:
          label "Tolerance:"
          spin(wandTol, 0, 255, w = dp(56))
          barCheck("Anti-aliased", wandAA)
          barCheck("Contiguous", wandContig)
          barCheck("Sample All Layers", wandMerged)
        toolSeparator()
        if toolButton("Select Subject", enabled = cur() != nil): runCommand("Subject")
        if toolButton("Remove Background", enabled = cur() != nil): runCommand("Remove Background")
        if toolButton("Select and Mask...", enabled = cur() != nil): runCommand("Select and Mask...")
      of tMove:
        if moveKind == 1:
          let d = cur()
          let ab = if d != nil and d.current.isArtboard: d.cur else: -1
          if ab >= 0:
            let b = d.layers[ab].board
            label(d.layers[ab].name & ": " & $b.w & " x " & $b.h & " px")
            toolSeparator()
            for (n, w, h) in [("A4", 2480, 3508), ("Phone", 1080, 1920), ("Square", 1080, 1080),
                              ("HD", 1920, 1080)]:
              if toolButton(n, "Size: " & $w & " x " & $h):
                d.beginStep("Artboard Size")
                d.resizeArtboard(ab, rect(b.x, b.y, w, h))
                d.endStep()
            toolSeparator()
          if toolButton("Export...", "File > Export > Artboards to Files", enabled = d != nil and d.artboards.len > 0):
            runCommand("Artboards to Files")
          label("Drag a box: a new artboard; drag one (or its name) to move it", color = ui.theme.gray)
        else:
          barCheck("Auto-Select", moveAutoSelect)
          # (what a click picks: the layer, or the outermost group it is in)
          var ag = ord(moveAutoGroup)
          accessName(tr("Auto-Select picks"))
          if combo(["Layer", "Group"], ag, w = dp(70), enabled = moveAutoSelect):
            moveAutoGroup = ag == 1
            savePrefs()
          barCheck("Show Transform Controls", moveShowControls)
          toolSeparator()
          barAlign()
          toolSeparator()
          label("Alt+drag: a copy; arrows: 1 pixel (Shift: 10)", color = ui.theme.gray)
      of tHand, tZoom:
        if tool == tHand and handKind == 1:
          # Rotate View: the angle, back to straight, all the windows
          label "Rotation Angle:"
          var ang = if active != nil: int(round(active.view.angle)) else: 0
          if spin(ang, -180, 180, w = dp(64)) and active != nil:
            active.view.angle = ang.float
            if rotateAll:
              for o in docs: o.view.angle = ang.float
          label "°"
          if toolButton("Reset View", "The view straight again (Esc)", enabled = active != nil):
            active.view.angle = 0
            if rotateAll:
              for o in docs: o.view.angle = 0
          barCheck("Rotate All Windows", rotateAll)
          toolSeparator()
        if barIcon(pxZoomIn, "Zoom In", enabled = active != nil): runCommand("Zoom In")
        if barIcon(pxZoomOut, "Zoom Out", enabled = active != nil): runCommand("Zoom Out")
        if toolButton("100%", "Actual Pixels", enabled = active != nil): runCommand("Actual Pixels")
        if toolButton("Fit Screen", "Fit on Screen", enabled = active != nil): runCommand("Fit on Screen")
      of tCrop:
        if cropKind in {3, 4}:
          var n = 0
          for sl in slices:
            if sl.d == cur(): inc n
          label($n & (if n == 1: " slice" else: " slices"))
          if toolButton("Slices From Guides", "A slice for each part the guides make", enabled = cur() != nil):
            runCommand("Slices From Guides")
          if toolButton("Delete", "Take the slice picked away", enabled = sliceSel in 0 .. slices.high):
            slices.delete(sliceSel)
            sliceSel = -1
          if toolButton("Export...", "Save each slice as a PNG", enabled = n > 0): runCommand("Slices to Files")
        elif cropKind == 2:
          if barIcon(pxMarqueeRect, "Rectangular frame", down = not frameEllipse): frameEllipse = false
          if barIcon(pxMarqueeEllipse, "Elliptical frame", down = frameEllipse): frameEllipse = true
          toolSeparator()
          label("Drag a frame (Shift: square); place a picture into it with Layer > Place Into",
                color = ui.theme.gray)
        elif cropKind == 1:
          if pendingCrop.on and pendingCrop.persp:
            let (pw, ph) = perspectiveSize(pendingCrop.q)
            label("W: " & $pw & " px   H: " & $ph & " px")
          else: label "Drag a box, then its corners onto lines that should be straight"
        else:
          barCheck("Straighten", cropStraighten)
          label "Fill:"
          combo(["Background", "Content-Aware"], cropFill, w = dp(118))
          tooltip("What fills the room a crop box past the image adds")
        if pendingCrop.on:
          toolSeparator()
          if toolButton("Crop", "Crop to the box (Enter)"): commitCrop()
          if toolButton("Cancel", "Leave it (Esc)"): pendingCrop.on = false
      of tType: barType()
      of tBucket:
        accessName(tr("Fill with"))
        combo(["Foreground", "Pattern"], bucketPattern, w = dp(96))
        barMode(tBucket)
        barOpacity(tBucket)
        label "Tolerance:"
        spin(bucketTol, 0, 255, w = dp(56))
        barCheck("Anti-aliased", bucketAA)
        barCheck("Contiguous", bucketContig)
        barCheck("All Layers", bucketAll)
      of tGradient: barGradient()
      of tShape: barShape()
      of tEyedropper:
        case dropKind
        of 1:
          let d = cur()
          var n = 0
          for sp in samplers:
            if d == nil or sp.d != d: continue
            inc n
            let c = d.pixelAt(sp.x, sp.y)
            label("#" & $n & " R" & $rOf(c) & " G" & $gOf(c) & " B" & $bOf(c))
            toolSeparator()
          if n == 0: label "Click to put a sampler (four an image); Alt+click takes one away"
          elif toolButton("Clear All", "Take the samplers away"):
            var k = 0
            while k < samplers.len:
              if samplers[k].d == d: samplers.delete(k) else: inc k
        of 2:
          let d = cur()
          if ruler.on and d != nil and ruler.d == d:
            let l = sqrt((ruler.x1 - ruler.x0) ^ 2 + (ruler.y1 - ruler.y0) ^ 2)
            label("X: " & $int(ruler.x0) & "  Y: " & $int(ruler.y0) & "   W: " & $int(ruler.x1 - ruler.x0) &
                  "  H: " & $int(ruler.y1 - ruler.y0) & "   A: " & formatFloat(rulerAngle(), ffDecimal, 1) &
                  "°  L: " & formatFloat(l, ffDecimal, 1))
            toolSeparator()
            if toolButton("Straighten Layer", "Turn the image so the line is level"): straightenByRuler()
            if toolButton("Clear", "Take the line away"): ruler.on = false
          else: label "Drag along what should be level, then Straighten Layer"
        of 3:
          var n = 0
          for nt in notes:
            if nt.d == cur(): inc n
          label($n & (if n == 1: " note" else: " notes"))
          if toolButton("Clear All", "Take this image's notes away"):
            var k = 0
            while k < notes.len:
              if notes[k].d == cur(): notes.delete(k) else: inc k
          label("Click to add a note, click one to open it, Alt+click to take it away", color = ui.theme.gray)
        of 4:
          var n = 0
          for c in counts:
            if c.d == cur(): inc n
          label("Count: " & $n, bold = true)
          if toolButton("Clear", "Start counting again"):
            var k = 0
            while k < counts.len:
              if counts[k].d == cur(): counts.delete(k) else: inc k
          label("Click each thing to count it; Alt+click takes a number away", color = ui.theme.gray)
        else:
          label "Sample Size:"
          combo(["Point Sample", "3 by 3 Average", "5 by 5 Average"], dropperSize, w = dp(120))
      of tEraser:
        if eraseKind == 2:
          barBrush(tEraser)
          label "Sampling:"
          combo(["Continuous", "Once", "Background Swatch"], bgEraseSampling, w = dp(120))
          label "Limits:"
          combo(["Discontiguous", "Contiguous", "Find Edges"], bgEraseLimits, w = dp(104))
          label "Tolerance:"
          popupSlider(bgEraseTol, 1, 100)
          barCheck("Protect Foreground Color", bgEraseProtect)
        elif eraseKind == 1:
          label "Tolerance:"
          spin(magicTol, 0, 255, w = dp(56))
          barCheck("Contiguous", magicContig)
        else:
          barBrush(tEraser)
          accessName(tr("Eraser mode"))
          combo(["Paintbrush", "Airbrush", "Pencil", "Block"], eraserMode, w = dp(90))
          if eraserMode != 3: barOpacity(tEraser)
          barCheck("Erase to Saved", eraseToSaved)
      of tPencil:
        barBrush(tPencil)
        barMode(tPencil)
        barOpacity(tPencil)
        barCheck("Auto Erase", opts[tPencil].autoErase)
      of tAirbrush:
        barBrush(tAirbrush)
        barMode(tAirbrush)
        barOpacity(tAirbrush, "Pressure:")
        barFlow(tAirbrush)
      of tBrush:
        accessName(tr("Brush tool"))
        combo(["Paintbrush", "Mixer Brush", "Color Replacement", "Adjustment Brush"], brushTool, w = dp(128))
        barBrush(tBrush)
        if brushTool == 3:
          # the Adjustment Brush: which adjustment, how much, add or take away
          accessName(tr("Adjustment"))
          if combo(adjBrushPresets, adjBrushKind, w = dp(110)): discard
          label "Amount:"
          if popupSlider(adjBrushAmount, -100, 100, unit = ""): adjBrushChanged()
          var m = ord(adjBrushSub)
          accessName(tr("The brush adds or subtracts"))
          if combo(["Add", "Subtract"], m, w = dp(84)): adjBrushSub = m == 1
          barFlow(tBrush)
          label("Alt: takes it away", color = ui.theme.gray)
        elif brushTool == 2:
          label "Mode:"
          combo(["Hue", "Saturation", "Color", "Luminosity"], crMode, w = dp(90))
          label "Sampling:"
          combo(["Continuous", "Once", "Background Swatch"], crSampling, w = dp(120))
          label "Limits:"
          combo(["Discontiguous", "Contiguous", "Find Edges"], crLimits, w = dp(104))
          label "Tolerance:"
          popupSlider(crTol, 1, 100)
        elif brushTool == 1:
          barOpacity(tBrush)
          label "Wet:"
          popupSlider(mixWet, 0, 100)
          label "Load:"
          popupSlider(mixLoad, 1, 100)
          label "Mix:"
          popupSlider(mixRatio, 0, 100)
        else:
          barMode(tBrush)
          barOpacity(tBrush)
          barFlow(tBrush)
        label "Smoothing:"
        popupSlider(brushSmoothing, 0, 100)
        if barIcon(pxSymmetry, "Symmetry (the Options palette)", down = symmetry > 0):
          togglePanel("options")
      of tStamp:
        accessName(tr("Stamp tool"))
        combo(["Rubber Stamp", "History Brush", "Art History Brush"], stampTool, w = dp(120))
        barBrush(tStamp)
        barMode(tStamp)
        barOpacity(tStamp)
        if stampTool == 2:
          label "Style:"
          var names: seq[string]
          for st in ArtStyle: names.add $st
          accessName(tr("Art style"))
          combo(names, artStyle, w = dp(120))
          label "Area:"
          spin(artArea, 1, 500, w = dp(56))
          label "px"
          label "Tolerance:"
          spin(artTolerance, 0, 100, w = dp(52))
          label "%"
        elif stampTool == 0:
          accessName(tr("Clone from"))
          combo(["Clone (aligned)", "Clone", "Pattern (aligned)", "Pattern", "From Snapshot", "From Saved",
                 "Impressionist"], stampMode, w = dp(120))
          barSource()
        elif toolButton("History...", "The History palette: mark the state to paint back"):
          runCommand("History")
      of tSmudge:
        barBrush(tSmudge)
        barMode(tSmudge)
        barOpacity(tSmudge, "Strength:")
        barCheck("Finger Painting", opts[tSmudge].finger)
      of tBlur:
        accessName(tr("Blur or Sharpen"))
        combo(["Blur", "Sharpen"], blurMode, w = dp(80))
        barBrush(tBlur)
        barMode(tBlur)
        barOpacity(tBlur, "Strength:")
      of tDodge:
        accessName(tr("Dodge, Burn or Sponge"))
        combo(["Dodge", "Burn", "Sponge"], dodgeMode, w = dp(80))
        barBrush(tDodge)
        if dodgeMode == 2:
          accessName(tr("Sponge mode"))
          combo(["Desaturate", "Saturate"], spongeMode, w = dp(90))
          barOpacity(tDodge, "Flow:")
        else:
          label "Range:"
          combo(["Shadows", "Midtones", "Highlights"], dodgeTone, w = dp(90))
          barOpacity(tDodge, "Exposure:")
      of tHeal:
        accessName(tr("Healing tool"))
        combo(["Spot Healing Brush", "Healing Brush", "Patch", "Remove Tool", "Content-Aware Move"], healMode,
              w = dp(140))
        if healMode in {0, 1, 3}: barBrush(tHeal)
        case healMode
        of 0:
          label "Type:"
          combo(["Content-Aware", "Create Texture", "Proximity Match"], spotKind, w = dp(128))
        of 1: barSource()
        of 2:
          label "Patch:"
          combo(["Normal", "Content-Aware"], patchContentAware, w = dp(112))
          if patchContentAware == 0:
            var src = not patchDest
            if barIcon(pxPatch, "Source: the selection made from where it is dragged to", down = src): patchDest = false
            if barIcon(pxMoveTool, "Destination: the selection copied to where it is dragged", down = not src):
              patchDest = true
            barCheck("Transparent", patchTransparent)
          else:
            label "Structure:"
            spin(patchStructure, 1, 7, w = dp(44))
            label "Color:"
            spin(patchColor, 0, 10, w = dp(44))
        of 4:
          var m = if camExtend: 1 else: 0
          accessName(tr("Move mode"))
          if combo(["Move", "Extend"], m, w = dp(80)): camExtend = m == 1
        else: discard
      of tRedEye:
        label "Darken:"
        popupSlider(redEyeDarken, 1, 100)
      of tPen:
        for k, (g, tip) in [(pxPathArrow, "Direct Selection"), (pxPen, "Pen"), (pxPenAdd, "Add Point"),
                            (pxPenRemove, "Delete Point"), (pxConvertPoint, "Convert Point"),
                            (pxPathSelect, "Path Selection"), (pxFreeformPen, "Freeform Pen"),
                            (pxCurvaturePen, "Curvature Pen"), (pxContentTrace, "Content-Aware Tracing")]:
          if barIcon(g, tip, down = penMode == k): penMode = k
        toolSeparator()
        if penMode == 8:
          label "Detail:"
          popupSlider(traceDetail, 1, 100, unit = "%")
          label "Trace:"
          combo(["Detailed", "Normal", "Simplified"], traceMode, w = dp(100))
          label("Point at an edge, click: a path; Shift+click: on along it", color = ui.theme.gray)
          toolSeparator()
        elif penMode == 6:
          label "Curve Fit:"
          spin(freeCurveFit, 1, 10, w = dp(48))
          label "px"
          toolSeparator()
        elif penMode == 7:
          label "Alt+click a point: corner or smooth"
          toolSeparator()
        if toolButton("Paths...", "The Paths palette"): togglePanel("paths")

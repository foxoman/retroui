# (included by photo.nim) The palettes and dialogs of type and layer
# styles: Character and Paragraph, the Type tool's options, Warp Text,
# Layer Style, and the Layer menu that reaches them.

var
  typeTab = 0
  # the boxes of the Character palette (what they show, each frame)
  cpFamily, cpStyle: string
  cpSize, cpLead, cpTrack, cpVS, cpHS, cpBase, cpKern, cpAA: int
  cpIndL, cpIndR, cpIndF, cpSpB, cpSpA, cpDir: int
  well: tuple[open: bool; key: string; c: uint32; done: bool; picker: ColorPickerState]
  warpDlg: tuple[open: bool; w: TextWarp; orig: TextWarp; layer: Layer; ownStep: bool; style: int]
  lsDlg: tuple[open: bool; layer: Layer; page: int; ownStep: bool; split, blendOnly: bool]
  copiedStyle: tuple[has: bool; fx: LayerFx; fill: int]

const warpNames = ["None", "Arc", "Arc Lower", "Arc Upper", "Arch", "Bulge", "Shell Lower", "Shell Upper",
                   "Flag", "Wave", "Fish", "Rise", "Fisheye", "Inflate", "Squeeze", "Twist"]

# ---- small things ----------------------------------------------------------------------------------------

proc colorWell(c: var uint32; key: string; w = 0): bool {.discardable.} =
  ## A swatch of a color: a click opens the picker for it.
  let r = place(if w > 0: w else: dp(34), CtrlH - dp(4))
  fill(r, colorOf(c or 0xFF000000'u32))
  box(r, color(0, 0, 0))
  box(inset(r, 1), color(255, 255, 255))
  if interact(idOf("well:" & key), r, focusable = false).clicked:
    well.open = true
    well.key = key
    well.c = c or 0xFF000000'u32
    well.done = false
  if well.done and well.key == key:
    well.done = false
    if well.c != c:
      c = well.c
      result = true

proc listRow(caption: string; selected: bool; key: string; w = 0): bool =
  ## A row of a list (picked when clicked).
  let r = place(if w > 0: w else: available(), ItemH)
  if selected: fill(r, ui.theme.select)
  text(r.x + dp(3), itemTextY(r.y), caption, if selected: ui.theme.selectText else: ui.theme.text)
  interact(idOf("listrow:" & key), r, focusable = false).clicked

proc stepOnce(d: Doc; name: string; body: proc ()) =
  ## A change of the layers as one undo step -- one for a whole drag of a
  ## slider (the steps of one name while the mouse is down are joined).
  let joined = d.undoSteps.len > 0 and d.undoName == name and ui.mouseDown and not ui.pressed and
               not d.stepOpen
  let mine = not d.stepOpen and not joined
  if mine:
    d.beginStep(name)
    d.touchLayers()
  body()
  if mine: d.endStep()

# ---- the Character and Paragraph settings applied ------------------------------------------------------------

proc typeTarget(): Layer =
  ## The type layer the palettes change: the one edited, or the current
  ## layer when it is type (nil: they set the next text).
  if te.on: return te.layer
  let d = cur()
  if d != nil and d.current.isText and not d.quickMask: d.current else: nil

proc shownStyle(): CharStyle =
  if te.on: return te.style
  let L = typeTarget()
  if L != nil: L.text.styleAt(0) else: typingStyle()

proc applyChar(name: string; change: proc (s: var CharStyle)) =
  ## A Character setting changed: the selection (or what is typed next) of
  ## the text edited, or all of the current type layer -- and the next text.
  change(typeStyle)
  if te.on:
    restyleSel(change)
    return
  let L = typeTarget()
  if L == nil: return
  let d = cur()
  d.stepOnce(name, proc () =
    var t = L.text
    t.restyle(0, 0, change)
    d.setText(L, t))

proc applyText(name: string; change: proc (t: var TextData)) =
  ## A setting of the whole text (its paragraphs, its anti-aliasing, its
  ## warp) changed.
  let L = typeTarget()
  if L == nil: return
  if te.on:
    editText(change)
    return
  let d = cur()
  d.stepOnce(name, proc () =
    var t = L.text
    change(t)
    d.setText(L, t))

proc fontRows(compact: bool) =
  ## The font, its style, the size, the color (the Options palette and the
  ## Character palette share them).
  let s = shownStyle()
  cpFamily = s.family
  cpStyle = s.style
  let w = available()
  rowPx([w * 3 div 5, -1]):
    if fontCombo(cpFamily, w = w * 3 div 5 - dp(2)):
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
    if fontStyleCombo(s.family, cpStyle, w = w - w * 3 div 5 - Gap):
      let st = cpStyle
      applyChar("Font Style", proc (x: var CharStyle) = x.style = st)
  let fp = fontProblem(s.family)
  if fp.len > 0:
    # (a font that is listed but drawn in another: said, not hidden)
    paragraph("Drawn in FreeSans: " & fp, color = color(176, 0, 0))
  cpSize = int(round(s.size))
  row:
    label "Size:"
    if spin(cpSize, 1, 2000, w = dp(64)):
      let v = float32(cpSize)
      applyChar("Font Size", proc (x: var CharStyle) = x.size = v)
    label "px"
    var c = if te.on or typeTarget() != nil: s.color else: fg
    if colorWell(c, "typecolor"):
      let cc = c
      if typeTarget() == nil: fg = cc
      applyChar("Text Color", proc (x: var CharStyle) = x.color = cc)

proc directionButtons()

proc characterBody() =
  fontRows(false)
  row:
    label "Direction:"
    directionButtons()
  if toolButton("+ Google Fonts", "Get free fonts (Arabic ones too) from Google Fonts"): runCommand("Get Google Fonts...")
  let s = shownStyle()
  cpLead = int(round(s.leading))
  cpTrack = s.tracking
  cpKern = ord(s.noKerning)
  cpVS = int(round((if s.vScale <= 0: 1'f32 else: s.vScale) * 100))
  cpHS = int(round((if s.hScale <= 0: 1'f32 else: s.hScale) * 100))
  cpBase = int(round(s.baselineShift))
  let half = (available() - Gap) div 2
  rowPx([half, half]):
    row:
      label "Lead:"
      if spin(cpLead, 0, 5000, w = dp(56)):
        let v = float32(cpLead)
        applyChar("Leading", proc (x: var CharStyle) = x.leading = v)
    row:
      label "Kern:"
      if combo(["Metrics", "0"], cpKern, w = dp(70)):
        let v = cpKern == 1
        applyChar("Kerning", proc (x: var CharStyle) = x.noKerning = v)
  rowPx([half, half]):
    row:
      label "Track:"
      if spin(cpTrack, -1000, 10000, w = dp(56), step = 10):
        let v = cpTrack
        applyChar("Tracking", proc (x: var CharStyle) = x.tracking = v)
    row:
      label "Shift:"
      if spin(cpBase, -2000, 2000, w = dp(56)):
        let v = float32(cpBase)
        applyChar("Baseline Shift", proc (x: var CharStyle) = x.baselineShift = v)
  rowPx([half, half]):
    row:
      label "V:"
      if spin(cpVS, 1, 1000, w = dp(56)):
        let v = float32(cpVS) / 100
        applyChar("Vertical Scale", proc (x: var CharStyle) = x.vScale = v)
      label "%"
    row:
      label "H:"
      if spin(cpHS, 1, 1000, w = dp(56)):
        let v = float32(cpHS) / 100
        applyChar("Horizontal Scale", proc (x: var CharStyle) = x.hScale = v)
      label "%"
  # the switches: faux bold, faux italic, caps, small caps, super, sub, underline, strike
  row:
    template sw(g, tip: string; on: bool; body: untyped) {.redefine.} =
      if toolButton(glyphIcon(g, ui.theme.text, dp(16)), tip, down = on):
        let now {.inject.} = not on
        applyChar(tip, proc (x {.inject.}: var CharStyle) = body)
    sw(pxFauxBold, "Faux Bold", s.fauxBold): x.fauxBold = now
    sw(pxFauxItalic, "Faux Italic", s.fauxItalic): x.fauxItalic = now
    sw(pxAllCaps, "All Caps", s.allCaps): x.allCaps = now
    sw(pxSmallCaps, "Small Caps", s.smallCaps): x.smallCaps = now
    sw(pxSuperscript, "Superscript", s.script == scSuper): x.script = (if now: scSuper else: scNormal)
    sw(pxSubscript, "Subscript", s.script == scSub): x.script = (if now: scSub else: scNormal)
    sw(pxUnderline, "Underline", s.underline): x.underline = now
    sw(pxStrikethrough, "Strikethrough", s.strike): x.strike = now
  let L = typeTarget()
  cpAA = ord(if L != nil: L.text.antialias else: typeAA)
  row:
    label "Anti-alias:"
    if combo(["None", "Smooth"], cpAA, w = dp(90)):
      typeAA = cpAA == 1
      let v = typeAA
      applyText("Anti-Alias", proc (t: var TextData) = t.antialias = v)
  var dg = s.digits
  row:
    label "Digits:"
    if combo(["As typed (123)", "Arabic (١٢٣)", "Persian (۱۲۳)"], dg, w = dp(130)):
      let v = dg
      applyChar("Digits", proc (x: var CharStyle) = x.digits = v)
  # the room between words; the tashkeel (the marks over and under letters) set apart
  var ws = s.wordSpace
  row:
    label "Word space:"
    if spin(ws, -500, 5000, w = dp(64), step = 10):
      let v = ws
      applyChar("Word Spacing", proc (x: var CharStyle) = x.wordSpace = v)
    label "/1000 em"
  var mk = if s.noMarks: 2 elif s.markColor != 0: 1 else: 0
  var raise0 = int(s.markRaise)
  row:
    label "Tashkeel:"
    if combo(["As the letters", "In the foreground color", "Hidden"], mk, w = dp(150)):
      let v = mk
      let c = fg or 0xFF000000'u32
      applyChar("Tashkeel", proc (x: var CharStyle) =
        x.noMarks = v == 2
        x.markColor = if v == 1: c else: 0'u32)
  row:
    label "... raised:"
    if spin(raise0, -200, 200, w = dp(64)):
      let v = raise0.float32
      applyChar("Raise Tashkeel", proc (x: var CharStyle) = x.markRaise = v)
    label "px"
    if button("Word Shapes...", w = dp(110)): runCommand("Word Shapes...")

proc textIsRtl(): bool =
  ## (the type being set runs right to left: its first line, or the direction chosen)
  let L = typeTarget()
  if L != nil and L.text.spans.len > 0:
    let l = layoutText(L.text)
    if l.lines.len > 0: return l.lines[0].rtl
  typePara.rtl == 2

proc mirroredAlign(a: TextAlign): TextAlign =
  case a
  of textLeft: textRight
  of textRight: textLeft
  of justifyLeft: justifyRight
  of justifyRight: justifyLeft
  else: a

proc alignButtons(cur: TextAlign; all: bool) =
  ## The alignment buttons (all seven, or left, center, right). (In right-
  ## to-left text they keep their look -- Right puts the lines at the right
  ## -- though the paragraph keeps where its lines start and end.)
  let icons = [pxAlignLeft, pxAlignCenter, pxAlignRight, pxJustifyLeft, pxJustifyCenter, pxJustifyRight,
               pxJustifyAll]
  let rtl = textIsRtl()
  let shownCur = if rtl: mirroredAlign(cur) else: cur
  for a in TextAlign:
    if not all and a > textRight: break
    if toolButton(glyphIcon(icons[ord(a)], ui.theme.text, dp(16)), $a, down = shownCur == a):
      let v = if rtl: mirroredAlign(a) else: a
      typePara.align = v
      applyText("Paragraph Alignment", proc (t: var TextData) = t.para.align = v)

proc directionButtons() =
  ## Left-to-right / right-to-left text, as buttons (the text being typed or
  ## picked, else the next one); a click on the one pressed: by the text.
  let L = typeTarget()
  let cur = if L != nil: L.text.para.rtl else: typePara.rtl
  for (v, cap, tip) in [(1, "LTR", "Left-to-right text (again: as the text runs)"),
                        (2, "RTL", "Right-to-left text, as Arabic (again: as the text runs)")]:
    if toolButton(cap, tip, down = cur == v):
      let nv = if cur == v: 0 else: v
      typePara.rtl = nv
      applyText("Text Direction", proc (t: var TextData) = t.para.rtl = nv)

proc paragraphBody() =
  let L = typeTarget()
  let p = if L != nil: L.text.para else: typePara
  row:
    alignButtons(p.align, true)
    directionButtons()
  cpIndL = int(round(p.indentLeft))
  cpIndR = int(round(p.indentRight))
  cpIndF = int(round(p.indentFirst))
  cpSpB = int(round(p.spaceBefore))
  cpSpA = int(round(p.spaceAfter))
  cpDir = p.rtl
  template num(lab: string; v: var int; lo, hi: int; name: string; field: untyped) =
    row([96, -1]):
      label lab
      if spin(v, lo, hi, w = dp(64)):
        let x = float32(v)
        typePara.field = x
        applyText(name, proc (t: var TextData) = t.para.field = x)
  num("Indent left:", cpIndL, -2000, 2000, "Indent", indentLeft)
  num("Indent right:", cpIndR, -2000, 2000, "Indent", indentRight)
  num("First line:", cpIndF, -2000, 2000, "Indent", indentFirst)
  num("Space before:", cpSpB, 0, 2000, "Paragraph Spacing", spaceBefore)
  num("Space after:", cpSpA, 0, 2000, "Paragraph Spacing", spaceAfter)
  row:
    label "Direction:"
    if combo(["Of the text", "Left to right", "Right to left"], cpDir, w = dp(120)):
      typePara.rtl = cpDir
      let v = cpDir
      applyText("Text Direction", proc (t: var TextData) = t.para.rtl = v)
  # (the usual Insert Kashida: how long justified Arabic's joins may grow)
  const kOrder = [kaNone, kaShort, kaMedium, kaLong, kaStylistic]
  var ki = kOrder.find(if p.noKashida: kaNone else: p.kashida)
  row:
    label "Insert Kashida:"
    if combo(["None", "Short", "Medium", "Long", "Stylistic"], ki, w = dp(100)):
      let v = kOrder[clamp(ki, 0, 4)]
      typePara.kashida = v
      typePara.noKashida = false
      applyText("Insert Kashida", proc (t: var TextData) = (t.para.kashida = v; t.para.noKashida = false))
  label("(justified Arabic: a join in each word grows, where a scribe would lengthen it)",
        color = ui.theme.gray)
  if L != nil and L.text.boxW > 0:
    var fit = L.text.fit
    if checkbox("Dynamic Text: as big as fills the box", fit):
      let v = fit
      applyText("Dynamic Text", proc (t: var TextData) = t.fit = v)
    paragraph(if fit: "The box sized, the text follows (its sizes scaled: " &
                formatFloat(L.text.fitScale * 100, ffDecimal, 0) & "%)."
              else: "Text in a box: drag its corners to size it.", color = ui.theme.gray)
    # columns, and the text flowing on into another box (threaded frames)
    var cols = max(1, L.text.columns)
    var gut = int(if L.text.gutter > 0: L.text.gutter else: 12'f32)
    row:
      label "Columns:"
      if spin(cols, 1, 12, w = dp(52)):
        let v = cols
        applyText("Columns", proc (t: var TextData) = t.columns = v)
      label "Gutter:"
      if spin(gut, 0, 2000, w = dp(60)):
        let v = gut.float32
        applyText("Gutter", proc (t: var TextData) = t.gutter = max(0.01'f32, v))
      label "px"
    let d = cur()
    let lay = layoutText(d.effectiveText(L))
    if L.flowFrom != 0:
      let S = d.layerOfUid(L.flowFrom)
      label("Flows on from \"" & (if S != nil: S.name else: "?") & "\": its text is edited there.",
            color = ui.theme.gray)
    row:
      if button("Flow Into a New Box", w = dp(150)): runCommand("Flow Into a New Box")
      if L.flowFrom != 0 and button("Unlink", w = dp(70)): runCommand("Unlink Text Box")
    if lay.overflow >= 0 and not d.flowsOn(L):
      label("Overset: some of the text does not fit -- size the box, add columns or flow it on.",
            color = color(200, 0, 0))

proc typeMenuItems() =
  ## The menu of Character, Paragraph, Glyphs.
  if menuItem("Reset Character"):
    typeStyle = CharStyle(family: defaultFamily, style: "Regular", size: 48, color: fg, hScale: 1, vScale: 1)
  if menuItem("Reset Paragraph"): typePara = ParaStyle()

proc typeTargetNote() =
  let L = typeTarget()
  if L == nil:
    label("For the next text", color = ui.theme.gray)

proc showTypePal(tab: int) =
  ## Character, Paragraph or Glyphs: shown (hidden when it is the one shown).
  togglePanel(["character", "paragraph", "glyphs"][clamp(tab, 0, 2)])

# ---- the Type tool's options -------------------------------------------------------------------------------

proc startWarp()

proc typeOptions() =
  fontRows(true)
  let L = typeTarget()
  row:
    alignButtons(if L != nil: L.text.para.align else: typePara.align, false)
    if toolButton(glyphIcon(pxWarpText, ui.theme.text, dp(16)), "Warp Text", enabled = L != nil and
                  not L.text.onPath):
      startWarp()
    if toolButton(glyphIcon(pxCharacter, ui.theme.text, dp(16)), "Character and Paragraph palettes",
                  down = panelShown("character") or panelShown("paragraph") or panelShown("glyphs")):
      showTypePal(typeTab)
  if te.on:
    row:
      if button("Commit", w = dp(80)): commitType()
      if button("Cancel", w = dp(80)): cancelType()
  paragraph("Click to type; drag a box for a paragraph; click the work path to type along it. " &
            "A click on text edits it.", color = ui.theme.gray)

# ---- Warp Text --------------------------------------------------------------------------------------------

proc startWarp() =
  let d = cur()
  if d == nil: return
  let L = if te.on: te.layer else: d.current
  if not L.isText or L.text.onPath: return
  let own = not d.stepOpen
  if own:
    d.beginStep("Warp Text")
    d.touchLayers()
  warpDlg = (true, L.text.warp, L.text.warp, L, own, ord(L.text.warp.style))
  if warpDlg.w.style == wsNone and warpDlg.w.bend == 0: warpDlg.w.bend = 50

proc warpDialog() =
  if not warpDlg.open: return
  let d = cur()
  let L = warpDlg.layer
  if d == nil or L notin d.layers:
    warpDlg.open = false
    return
  var done = 0               # 1 OK, 2 Cancel
  var open = true
  dialog(open, "Warp Text", 420):
    row([-1, 92]):
      col:
        row:
          label "Style:"
          if combo(warpNames, warpDlg.style, w = dp(150)): warpDlg.w.style = WarpStyle(warpDlg.style)
        var vert = ord(warpDlg.w.vertical)
        row:
          if radio("Horizontal", vert, 0): warpDlg.w.vertical = false
          if radio("Vertical", vert, 1): warpDlg.w.vertical = true
        template sl(lab: string; v: untyped) {.redefine.} =
          row([110, -1, 40]):
            label lab
            slider(v, -100, 100, ticks = 0, enabled = warpDlg.w.style != wsNone)
            label $v & "%"
        sl("Bend:", warpDlg.w.bend)
        sl("Horizontal Distortion:", warpDlg.w.hDistort)
        sl("Vertical Distortion:", warpDlg.w.vDistort)
      col:
        if button("OK", isDefault = true, w = dp(80)): done = 1
        if button("Cancel", w = dp(80)): done = 2
  if not open and done == 0: done = 2
  # shown as it is set
  if L.text.warp != warpDlg.w and done != 2:
    var t = L.text
    t.warp = warpDlg.w
    d.setText(L, t)
  if done == 1:
    warpDlg.open = false
    if warpDlg.ownStep: d.endStep()
  elif done == 2:
    warpDlg.open = false
    if warpDlg.ownStep: d.cancelStep()
    else:
      var t = L.text
      t.warp = warpDlg.orig
      d.setText(L, t)

# ---- Layer Style ------------------------------------------------------------------------------------------

proc startLayerStyle(page = -1) =
  ## Layer > Layer Style: its dialog, on an effect (turned on) or on the
  ## Blending Options (-1).
  let d = cur()
  if d == nil: return
  if te.on: commitType()
  let L = d.current
  let blendOnly = L.adjust.kind.len > 0 or L.group
  if L.background or (blendOnly and page >= 0):
    status = if L.background: "The Background cannot have a layer style (make it a layer first)"
             elif L.group: "A group has no layer style here (its layers can)"
             else: "An adjustment layer has no layer style"
    return
  let own = not d.stepOpen
  if own:
    d.beginStep("Layer Style")
    d.touchLayers()
  if page >= 0 and not L.fx.fx[FxKind(page)].on:
    L.fx.fx[FxKind(page)] = defaultEffect(FxKind(page))
    d.markAll()
  lsDlg = (true, L, page, own, false, blendOnly)

proc modeCombo(m: var BlendMode; key: string): bool =
  var k = max(0, LayerModes.find(m))
  pushId(key)
  if combo(layerModeNames(), k, w = dp(120)) and LayerModes[k] != m:
    m = LayerModes[k]
    result = true
  popId()

proc fxSlider(lab: string; v: var int; lo, hi: int; unit = ""): bool =
  row([78, -1, 46]):
    label lab
    result = slider(v, lo, hi, ticks = 0)
    label $v & unit

proc effectPage(e: var Effect; k: FxKind): bool =
  ## The settings of effect `k`; true when one changed.
  template ch(x: untyped) =
    if x: result = true
  case k
  of fxDropShadow, fxInnerShadow:
    row:
      label "Blend Mode:"
      ch modeCombo(e.mode, "m1")
      ch colorWell(e.color, "fxc1")
    ch fxSlider("Opacity:", e.opacity, 0, 100, "%")
    ch fxSlider("Angle:", e.angle, -180, 180, "°")
    ch fxSlider("Distance:", e.distance, 0, 300, " px")
    ch fxSlider(if k == fxDropShadow: "Spread:" else: "Choke:", e.spread, 0, 100, "%")
    ch fxSlider("Size:", e.size, 0, 250, " px")
  of fxOuterGlow, fxInnerGlow:
    row:
      label "Blend Mode:"
      ch modeCombo(e.mode, "m1")
      ch colorWell(e.color, "fxc1")
    ch fxSlider("Opacity:", e.opacity, 0, 100, "%")
    if k == fxInnerGlow:
      row:
        label "Source:"
        if radio("Center", e.style, 1): result = true
        if radio("Edge", e.style, 0): result = true
    ch fxSlider(if k == fxOuterGlow: "Spread:" else: "Choke:", e.spread, 0, 100, "%")
    ch fxSlider("Size:", e.size, 0, 250, " px")
  of fxBevel:
    row:
      label "Style:"
      ch combo(BevelStyles, e.style, w = dp(130))
    ch fxSlider("Depth:", e.depth, 1, 1000, "%")
    var dn = ord(e.down)
    row:
      label "Direction:"
      if radio("Up", dn, 0): (e.down = false; result = true)
      if radio("Down", dn, 1): (e.down = true; result = true)
    ch fxSlider("Size:", e.size, 0, 250, " px")
    ch fxSlider("Soften:", e.soften, 0, 16, " px")
    ch fxSlider("Angle:", e.angle, -180, 180, "°")
    ch fxSlider("Altitude:", e.altitude, 0, 90, "°")
    row:
      label "Highlight:"
      ch modeCombo(e.mode, "m1")
      ch colorWell(e.color, "fxc1")
    ch fxSlider("Opacity:", e.opacity, 0, 100, "%")
    row:
      label "Shadow:"
      ch modeCombo(e.mode2, "m2")
      ch colorWell(e.color2, "fxc2")
    ch fxSlider("Opacity:", e.opacity2, 0, 100, "%")
  of fxSatin:
    row:
      label "Blend Mode:"
      ch modeCombo(e.mode, "m1")
      ch colorWell(e.color, "fxc1")
    ch fxSlider("Opacity:", e.opacity, 0, 100, "%")
    ch fxSlider("Angle:", e.angle, -180, 180, "°")
    ch fxSlider("Distance:", e.distance, 1, 250, " px")
    ch fxSlider("Size:", e.size, 0, 250, " px")
    ch checkbox("Invert", e.down)
  of fxColorOverlay:
    row:
      label "Blend Mode:"
      ch modeCombo(e.mode, "m1")
      ch colorWell(e.color, "fxc1")
    ch fxSlider("Opacity:", e.opacity, 0, 100, "%")
  of fxGradientOverlay:
    row:
      label "Blend Mode:"
      ch modeCombo(e.mode, "m1")
    ch fxSlider("Opacity:", e.opacity, 0, 100, "%")
    row:
      label "Gradient:"
      ch colorWell(e.color, "fxc1")
      ch colorWell(e.color2, "fxc2")
      ch checkbox("Reverse", e.down)
    row:
      label "Style:"
      ch combo(GradientStyles, e.style, w = dp(110))
    ch fxSlider("Angle:", e.angle, -180, 180, "°")
    if e.scale <= 0: e.scale = 100
    ch fxSlider("Scale:", e.scale, 10, 150, "%")
  of fxStroke:
    ch fxSlider("Size:", e.size, 1, 250, " px")
    row:
      label "Position:"
      ch combo(StrokePositions, e.style, w = dp(100))
    row:
      label "Blend Mode:"
      ch modeCombo(e.mode, "m1")
    ch fxSlider("Opacity:", e.opacity, 0, 100, "%")
    row:
      label "Color:"
      ch colorWell(e.color, "fxc1")

proc layerStyleDialog() =
  if not lsDlg.open: return
  let d = cur()
  let L = lsDlg.layer
  if d == nil or L notin d.layers:
    lsDlg.open = false
    return
  var done = 0
  var open = true
  var changed = false
  dialog(open, (if lsDlg.blendOnly: "Blending Options" else: "Layer Style"), 600):
    row([176, -1, 92]):
      col:
        label("Styles", bold = true)
        if listRow("Blending Options", lsDlg.page < 0, "blend", dp(170)): lsDlg.page = -1
        for k in DialogOrder:
          if lsDlg.blendOnly: break
          row([22, 148]):
            var on = L.fx.fx[k].on
            pushId("fxon" & $ord(k))
            if checkbox("", on):
              if on and L.fx.fx[k] == Effect(): L.fx.fx[k] = defaultEffect(k)
              L.fx.fx[k].on = on
              changed = true
              if on: lsDlg.page = ord(k)
            popId()
            if listRow(StyleNames[k], lsDlg.page == ord(k), "fx" & $ord(k), dp(146)):
              lsDlg.page = ord(k)
              if not L.fx.fx[k].on:
                L.fx.fx[k] = defaultEffect(k)
                changed = true
      col:
        # (a box of one height for every effect: the dialog does not jump)
        beginScroll(dp(376), "lspage")
        if lsDlg.page < 0:
          label("Blending Options", bold = true)
          var m = L.mode
          row:
            label "Blend Mode:"
            if modeCombo(m, "lm"):
              L.mode = m
              changed = true
          var op = L.opacity
          if fxSlider("Opacity:", op, 0, 100, "%"):
            L.opacity = op
            changed = true
          var fl = L.fill
          if fxSlider("Fill Opacity:", fl, 0, 100, "%"):
            L.fill = fl
            changed = true
          paragraph("Fill Opacity fades the layer's own pixels, not its effects.", color = ui.theme.gray)
          if not L.group:
            space(dp(4))
            label("Blend If", bold = true)
            var ch = L.blendIf.channel
            row:
              label "Channel:"
              if combo(@["Gray", "Red", "Green", "Blue"], ch, w = dp(90)):
                L.blendIf.channel = ch
                changed = true
              checkbox("Split", lsDlg.split)
            let tint = case L.blendIf.channel
                       of 1: (0xFF000000'u32, 0xFFFF0000'u32)
                       of 2: (0xFF000000'u32, 0xFF00FF00'u32)
                       of 3: (0xFF000000'u32, 0xFF0000FF'u32)
                       else: (0xFF000000'u32, 0xFFFFFFFF'u32)
            label "This Layer:"
            var t = rangeOf(L.blendIf.this)
            if blendRange("this", t, dp(300), tint, lsDlg.split):
              L.blendIf.this = if t == [0, 0, 255, 255]: [0, 0, 0, 0] else: t
              changed = true
            label "Underlying Layer:"
            var u = rangeOf(L.blendIf.under)
            if blendRange("under", u, dp(300), tint, lsDlg.split):
              L.blendIf.under = if u == [0, 0, 255, 255]: [0, 0, 0, 0] else: u
              changed = true
        else:
          let k = FxKind(lsDlg.page)
          label(StyleNames[k], bold = true)
          var e = L.fx.fx[k]
          pushId("page" & $ord(k))
          if effectPage(e, k):
            e.on = true
            L.fx.fx[k] = e
            changed = true
          popId()
        endScroll()
      col:
        if button("OK", isDefault = true, w = dp(86)): done = 1
        if button("Cancel", w = dp(86)): done = 2
        space(dp(6))
        var hide = L.fx.hidden
        if checkbox("Hide", hide):
          L.fx.hidden = hide
          changed = true
  if changed: d.markAll()
  if not open and done == 0: done = 2
  if done == 1:
    lsDlg.open = false
    if lsDlg.ownStep: d.endStep()
  elif done == 2:
    lsDlg.open = false
    if lsDlg.ownStep: d.cancelStep()

# ---- the rasterize question ------------------------------------------------------------------------------------

proc rasterAskDialog() =
  if not rasterAsk.open: return
  var go = false
  dialog(rasterAsk.open, AppName, 440):
    row([40, -1]):
      let ir = place(dp(32), dp(32))
      let shape = cur() != nil and cur().current.isShape
      let smart = cur() != nil and cur().current.isSmart and not shape
      image(ir.x, ir.y, glyphIcon(if smart: pxSmartObject elif shape: pxShapeLayer else: pxTypeTool,
                                  ui.theme.text, dp(32)))
      if smart:
        paragraph("This Smart Object must be rasterized before proceeding. It will no longer be " &
                  "scaled without loss, nor its Smart Filters changed. Rasterize the Smart Object?")
      elif shape:
        paragraph("This shape layer must be rasterized before proceeding. Its shape will no longer be " &
                  "editable. Rasterize the shape?")
      else:
        paragraph("This type layer must be rasterized before proceeding. Its text will no longer be " &
                  "editable. Rasterize the type?")
    row([-1, 80, 80]):
      space(0)
      if button("OK", isDefault = true, w = dp(80)): go = true
      if button("Cancel", w = dp(80)): rasterAsk.open = false
  if go:
    rasterAsk.open = false
    let d = cur()
    if d != nil and d.current.isSmart and not d.current.isShape and not d.current.isText:
      d.beginStep("Rasterize Smart Object")
      d.touchLayers()
      d.current.smart = nil
      d.endStep()
      if rasterAsk.then.len > 0: runCommand(rasterAsk.then)
    elif d != nil and d.current.isShape:
      d.beginStep("Rasterize Shape")
      d.touchLayers()
      d.rasterizeShape(d.current)
      d.endStep()
      if rasterAsk.then.len > 0: runCommand(rasterAsk.then)
    elif d != nil and d.current.isText:
      if te.on: commitType()
      d.beginStep("Rasterize Type")
      d.touchLayers()
      d.rasterizeText(d.current)
      d.endStep()
      if rasterAsk.then.len > 0: runCommand(rasterAsk.then)

proc typeDialogs() =
  warpDialog()
  layerStyleDialog()
  rasterAskDialog()
  if colorPickerDialog(well.open, "Select color", well.c, well.picker): well.done = true

# ---- the Layer menu's type and style items -------------------------------------------------------------------

proc layerStyleMenu(d: Doc) =
  let L = if d != nil: d.current else: nil
  let ok = L != nil and not L.background and L.adjust.kind.len == 0
  if menuItem("Blending Options...", enabled = ok): startLayerStyle(-1)
  menuSeparator()
  for k in DialogOrder:
    if menuItem(StyleNames[k] & "...", enabled = ok, checked = ok and L.fx.fx[k].on): startLayerStyle(ord(k))
  menuSeparator()
  if menuItem("Copy Layer Style", enabled = ok and L.hasStyle):
    copiedStyle = (true, L.fx, L.fill)
  if menuItem("Paste Layer Style", enabled = ok and copiedStyle.has):
    d.stepOnce("Paste Layer Style", proc () =
      L.fx = copiedStyle.fx
      L.fill = copiedStyle.fill
      d.markAll())
  if menuItem("Clear Layer Style", enabled = ok and L.hasStyle):
    d.stepOnce("Clear Layer Style", proc () =
      L.fx = LayerFx()
      L.fill = 100
      d.markAll())
  if menuItem(if ok and L.fx.hidden: "Show All Effects" else: "Hide All Effects", enabled = ok and L.hasStyle):
    d.stepOnce("Hide Effects", proc () =
      L.fx.hidden = not L.fx.hidden
      d.markAll())

proc typeMenu(d: Doc) =
  let L = if d != nil: (if te.on: te.layer else: d.current) else: nil
  let isT = L != nil and L.isText
  if menuItem("Warp Text...", enabled = isT and not L.text.onPath): startWarp()
  if menuItem("Character", checked = panelShown("character")): showTypePal(0)
  if menuItem("Paragraph", checked = panelShown("paragraph")): showTypePal(1)
  menuSeparator()
  if menuItem("Anti-Alias None", enabled = isT, checked = isT and not L.text.antialias):
    applyText("Anti-Alias", proc (t: var TextData) = t.antialias = false)
  if menuItem("Anti-Alias Smooth", enabled = isT, checked = isT and L.text.antialias):
    applyText("Anti-Alias", proc (t: var TextData) = t.antialias = true)
  menuSeparator()
  if menuItem("Orientation: Horizontal", enabled = isT and not L.text.onPath, checked = isT and not L.text.vertical):
    applyText("Text Orientation", proc (t: var TextData) = t.vertical = false)
  if menuItem("Orientation: Vertical", enabled = isT and L.text.boxW <= 0 and not L.text.onPath,
              checked = isT and L.text.vertical):
    applyText("Text Orientation", proc (t: var TextData) = t.vertical = true)
  menuSeparator()
  if menuItem("Convert to Paragraph Text", enabled = isT and L.text.boxW <= 0 and not L.text.onPath):
    applyText("Convert to Paragraph Text", proc (t: var TextData) =
      let l = layoutText(t)
      t.boxW = max(16'f32, l.x1 - l.x0 + 4)
      t.boxH = max(16'f32, l.y1 - l.y0 + 4)
      t.x = l.x0
      t.y = l.y0)
  if menuItem("Convert to Point Text", enabled = isT and L.text.boxW > 0):
    applyText("Convert to Point Text", proc (t: var TextData) =
      let l = layoutText(t)
      t.boxW = 0
      t.boxH = 0
      if l.lines.len > 0:
        t.y = l.lines[0].baseline
        t.x = l.lines[0].x0)
  let hasPath = d != nil and d.curPath >= 0 and d.curPath < d.paths.len
  if menuItem("Type on the Work Path", enabled = isT and hasPath):
    var pts: seq[(float32, float32)]
    let polys = d.paths[d.curPath].flatten(16)
    if polys.len > 0:
      for p in polys[0]: pts.add (float32(p[0]), float32(p[1]))
      applyText("Type on Path", proc (t: var TextData) =
        t.path = pts
        t.pathOffset = 0
        t.boxW = 0
        t.warp = TextWarp())
  if menuItem("Type off the Path", enabled = isT and L.text.onPath):
    applyText("Type off Path", proc (t: var TextData) =
      if t.path.len > 0:
        t.x = t.path[0][0]
        t.y = t.path[0][1]
      t.path = @[])
  menuSeparator()
  if menuItem("Rasterize Type", enabled = isT):
    if te.on: commitType()
    d.stepOnce("Rasterize Type", proc () = d.rasterizeText(L))

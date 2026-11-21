# (included by photo.nim) The palettes and dialogs of type and layer
# styles: Character and Paragraph, the Type tool's options, Warp Text,
# Layer Style, and the Layer menu that reaches them.

var
  typeTab = 0
  # the boxes of the Character palette (what they show, each frame)
  cpFamily, cpStyle: string
  cpSize, cpLead, cpTrack, cpVS, cpHS, cpBase, cpKern, cpAA: int
  cpDir: int
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

proc applyPara(name: string; change: proc (p: var ParaStyle)) =
  ## A paragraph setting changed: of the paragraphs the selection is in while typing (each keeps
  ## the rest of its own format), else of all of them -- as the layout program's Paragraph panel.
  let L = typeTarget()
  if L == nil: return
  if te.on and te.layer == L:
    let (a, b) = (min(te.caret, te.anchor), max(te.caret, te.anchor))
    editText(proc (t: var TextData) = t.changeParas(a, b, change))
    return
  applyText(name, proc (t: var TextData) = t.changeParas(0, t.runeLen, change))

proc applyAllParas(name: string; change: proc (p: var ParaStyle)) =
  ## A setting the whole text has, as one (a list, a drop cap): in every paragraph of it.
  applyText(name, proc (t: var TextData) = t.changeParas(0, t.runeLen, change))

proc curPara(): ParaStyle =
  ## The format of the paragraph being typed in (the first's, of a text picked; the next
  ## text's).
  let L = typeTarget()
  if L == nil: typePara
  elif te.on and te.layer == L: L.text.paraFmtAt(te.caret)
  else: L.text.paraFmtAt(0)

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

var scriptFontsOpen = false        ## (Character: the Arabic and Latin fonts shown)

proc scriptFontRows(s: CharStyle) =
  ## (Character: a font for the Arabic letters and one for the Latin, each with its style, size,
  ## raise, color and tracking -- the spaces and digits between go with the letters about them)
  let on = s.arabicFont != ScriptFont() or s.latinFont != ScriptFont()
  if not checkbox("Fonts for Arabic and Latin" & (if on: " (set)" else: ""), scriptFontsOpen): discard
  if not scriptFontsOpen: return
  for which in 0 .. 1:
    var f = if which == 0: s.arabicFont else: s.latinFont
    let f0 = f
    label((if which == 0: "Arabic letters:" else: "Latin (English) letters:"), bold = true)
    var fam = if f.family.len > 0: f.family else: "(the text's font)"
    let w = available()
    rowPx([w * 3 div 5, -1]):
      if fontCombo(fam, w = w * 3 div 5 - dp(2)): f.family = fam
      var sts = @["(as the text)"]
      if f.family.len > 0: sts.add fontStyles(f.family)
      var si = max(0, sts.find(if f.style.len > 0: f.style else: "(as the text)"))
      if combo(sts, si, w = available()): f.style = if si == 0: "" else: sts[si]
    var sc = int(round((if f.scale > 0: f.scale else: 1'f32) * 100))
    var sh = int(round(f.shift))
    var tr = f.tracking
    row:
      label "Size:"
      if spin(sc, 25, 400, w = dp(56), step = 5): f.scale = sc.float32 / 100
      label "%"
      label "Raise:"
      if spin(sh, -500, 500, w = dp(56)): f.shift = sh.float32
      label "px"
    row:
      label "Track:"
      if spin(tr, -500, 5000, w = dp(56), step = 10): f.tracking = tr
      var own = f.color != 0
      if checkbox("Color:", own): f.color = if own: (fg or 0xFF000000'u32) else: 0'u32
      if own:
        var c = f.color
        if colorWell(c, "scriptcolor" & $which, dp(36)): f.color = c or 0xFF000000'u32
      if button("Reset", w = dp(56)): f = ScriptFont()
    if f != f0:
      let v = f
      if which == 0: applyChar("Arabic Font", proc (x: var CharStyle) = x.arabicFont = v)
      else: applyChar("Latin Font", proc (x: var CharStyle) = x.latinFont = v)

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
  # (the language: as its words are hyphenated)
  const langs = ["", "fr", "de", "es", "it", "pt", "nl", "ar"]
  var lg = max(0, langs.find(if s.lang == "en": "" else: s.lang))
  row:
    label "Language:"
    if combo(["English: USA", "French", "German: 2006 Reform", "Spanish", "Italian", "Portuguese",
              "Dutch: 2005 Reform", "Arabic"], lg, w = dp(150)):
      let v = langs[clamp(lg, 0, langs.high)]
      applyChar("Language", proc (x: var CharStyle) = x.lang = v)
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
  var shift0 = int(s.markShift)
  row:
    label "... raised:"
    if spin(raise0, -200, 200, w = dp(64)):
      let v = raise0.float32
      applyChar("Raise Tashkeel", proc (x: var CharStyle) = x.markRaise = v)
    label "px"
    label "moved:"
    if spin(shift0, -200, 200, w = dp(64)):
      let v = shift0.float32
      applyChar("Move Tashkeel", proc (x: var CharStyle) = x.markShift = v)
    label "px"
  row:
    if button("Word Shapes...", w = dp(110)): runCommand("Word Shapes...")
  scriptFontRows(s)

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
      applyPara("Paragraph Alignment", proc (p: var ParaStyle) = p.align = v)

proc directionButtons() =
  ## Left-to-right / right-to-left text, as buttons (the text being typed or
  ## picked, else the next one); a click on the one pressed: by the text.
  let cur = curPara().rtl
  for (v, cap, tip) in [(1, "LTR", "Left-to-right text (again: as the text runs)"),
                        (2, "RTL", "Right-to-left text, as Arabic (again: as the text runs)")]:
    if toolButton(cap, tip, down = cur == v):
      let nv = if cur == v: 0 else: v
      typePara.rtl = nv
      applyPara("Text Direction", proc (p: var ParaStyle) = p.rtl = nv)

var tabsUi: tuple[kind: TabAlign; sel: int; drag: int; off: bool; ruler: Rect]
  ## (the Tabs panel: the kind a new stop gets, the stop picked, the one dragged -- `off`: dragged
  ## off the ruler, it goes when let go)

proc tabsBody() =
  ## The Tabs panel: the stops of the paragraphs typed in (or of all of the type layer's) on a
  ## ruler as wide as its column -- mirrored for right-to-left text, its zero at the right --; a
  ## click puts one of the kind picked there, a drag moves it, off the ruler takes it away; where
  ## the stop picked is in the rulers' unit, its leader, the character it aligns on; Repeat Tab,
  ## Clear All. Shift+Tab, typing: a Right Indent Tab.
  let L = typeTarget()
  let d = cur()
  if L == nil or d == nil or L.text.boxW <= 0:
    paragraph("Pick a text box (or type in one): its paragraphs' tab stops are set here.", color = ui.theme.gray)
    return
  let p = curPara()
  let rtl = p.rtl == 2 or (p.rtl == 0 and textIsRtl(L.text.plainText))
  let t = L.text
  let cols = max(1, t.columns)
  let gut = if t.gutter > 0: t.gutter else: 12'f32
  let colW = max(10'f32, (t.boxW - gut * float32(cols - 1)) / float32(cols))
  var tabs = p.tabs
  tabsUi.sel = clamp(tabsUi.sel, -1, tabs.high)
  proc setTabs(name: string; ts: seq[TabStop]) =
    let v = ts
    applyPara(name, proc (q: var ParaStyle) = q.tabs = v)
  # the kinds
  row:
    for (k, cap, tip) in [(tabLeft, "Left", "Left-justified tab: the text starts at it"),
                          (tabCenter, "Center", "Center-justified tab: the text's middle at it"),
                          (tabRight, "Right", "Right-justified tab: the text ends at it"),
                          (tabChar, "Align On", "Align on a character: a decimal point at it")]:
      if toolButton(cap, tip, down = (if tabsUi.sel >= 0: tabs[tabsUi.sel].align == k else: tabsUi.kind == k)):
        tabsUi.kind = k
        if tabsUi.sel >= 0:
          tabs[tabsUi.sel].align = k
          setTabs("Tabs", tabs)
  # the ruler: the column's width across the panel (right to left: its zero at the right)
  let r = place(available(), dp(30))
  tabsUi.ruler = r
  let id = idOf("tabsruler")
  let hit = interact(id, r, focusable = false)
  fill(r, color(255, 255, 255))
  box(r, ui.theme.frame)
  let k = float32(r.w - dp(12)) / colW               # (screen pixels a text pixel)
  let x0 = r.x + dp(6)
  # (its zero at the right for right-to-left text -- an interface right to left mirrors what is
  # drawn already: then for left-to-right text)
  let flip = rtl != ui.rtl
  proc toScreen(pos: float32): int = (if flip: x0 + r.w - dp(12) - int(pos * k) else: x0 + int(pos * k))
  proc fromScreen(sx: int): float32 =
    max(0'f32, min(colW, (if flip: float32(x0 + r.w - dp(12) - sx) else: float32(sx - x0)) / k))
  let u = viewPrefs.rulerUnit
  let unitPx = unitPixels(u, d.dpi, d.w)
  # (ticks: one a unit, longer every so many)
  var every = unitPx
  while every * k < float(dp(6)): every *= 2
  var tv = 0.0
  var n = 0
  while tv <= colW.float + 0.01:
    let sx = toScreen(float32(tv))
    vline(sx, r.y + r.h - (if n mod 4 == 0: dp(8) else: dp(4)), (if n mod 4 == 0: dp(8) else: dp(4)), ui.theme.text)
    tv += every
    inc n
  # (the indents)
  for (pos, c) in [((if rtl: p.indentRight else: p.indentLeft), color(120, 120, 120)),
                   (colW - (if rtl: p.indentLeft else: p.indentRight), color(120, 120, 120))]:
    let sx = toScreen(pos)
    vline(sx, r.y + 2, r.h - 4, c)
  # (the stops: a mark for each kind, the one picked filled)
  for i, ts in tabs:
    let sx = toScreen(ts.pos)
    let y = r.y + dp(4)
    let on = i == tabsUi.sel
    let c = if on: ui.theme.select else: ui.theme.text
    vline(sx, y, dp(12), c)
    case ts.align
    of tabLeft: hline((if flip: sx - dp(5) else: sx), y + dp(11), dp(6), c)
    of tabRight: hline((if flip: sx else: sx - dp(5)), y + dp(11), dp(6), c)
    of tabCenter: hline(sx - dp(4), y + dp(11), dp(9), c)
    of tabChar:
      hline(sx - dp(4), y + dp(11), dp(9), c)
      fill(rect(sx + dp(2), y + dp(5), dp(2), dp(2)), c)
    if on: fill(rect(sx - dp(1), y, dp(3), dp(3)), c)
  if hit.hover: ui.cursor = curHand
  if ui.active == id and ui.pressed:
    # (on a stop: picked, to drag; else a new one there)
    tabsUi.drag = -1
    for i, ts in tabs:
      if abs(toScreen(ts.pos) - ui.mx) <= dp(5): tabsUi.drag = i
    if tabsUi.drag < 0:
      let pos = fromScreen(ui.mx)
      var p2 = p
      p2.setTab(TabStop(pos: pos, align: tabsUi.kind, alignOn: (if tabsUi.kind == tabChar: "." else: "")))
      tabs = p2.tabs
      for i, ts in tabs:
        if abs(ts.pos - pos) < 0.5: tabsUi.drag = i
      setTabs("New Tab Stop", tabs)
    tabsUi.sel = tabsUi.drag
    tabsUi.off = false
  elif ui.active == id and ui.mouseDown and tabsUi.drag in 0 .. tabs.high:
    tabsUi.off = ui.my > r.y + r.h + dp(16) or ui.my < r.y - dp(16)
    let pos = fromScreen(ui.mx)
    if abs(tabs[tabsUi.drag].pos - pos) >= 0.5 and not tabsUi.off:
      var moved = tabs[tabsUi.drag]
      moved.pos = pos
      tabs.delete(tabsUi.drag)
      var p2 = p
      p2.tabs = tabs
      p2.setTab(moved)
      tabs = p2.tabs
      for i, ts in tabs:
        if abs(ts.pos - pos) < 0.5: tabsUi.drag = i
      tabsUi.sel = tabsUi.drag
      setTabs("Move Tab Stop", tabs)
    if tabsUi.off: ui.cursor = curArrow
  if ui.released and tabsUi.drag >= 0:
    if tabsUi.off and tabsUi.drag <= tabs.high:
      tabs.delete(tabsUi.drag)
      tabsUi.sel = -1
      setTabs("Delete Tab Stop", tabs)
    tabsUi.drag = -1
    tabsUi.off = false
  tooltip("Click: a tab stop there; drag one to move it, off the ruler to take it away")
  # the stop picked: where (the rulers' unit), its leader, the character it aligns on
  let i = tabsUi.sel
  row([30, 76, 56, -1]):
    label "X:"
    var v = if i >= 0: float(tabs[i].pos) / unitPx else: 0.0
    if numberEdit(v, decimals = (if u == ruPixels: 0 else: 2), w = dp(66), lo = 0, hi = 99999, enabled = i >= 0) and
       i >= 0:
      var moved = tabs[i]
      moved.pos = float32(v * unitPx)
      tabs.delete(i)
      var p2 = p
      p2.tabs = tabs
      p2.setTab(moved)
      for j, ts in p2.tabs:
        if abs(ts.pos - moved.pos) < 0.5: tabsUi.sel = j
      setTabs("Tabs", p2.tabs)
    label "Leader:"
    var ld = if i >= 0: tabs[i].leader else: ""
    if edit(ld, w = dp(38), enabled = i >= 0) and i >= 0:
      let rs = ld.toRunes
      var cut = ""
      for q in rs[0 ..< min(8, rs.len)]: cut.add q.toUTF8
      tabs[i].leader = cut
      setTabs("Tabs", tabs)
  row([86, -1]):
    label "Align On:"
    var on = if i >= 0: tabs[i].alignOn else: ""
    if edit(on, w = dp(28), enabled = i >= 0 and tabs[i].align == tabChar) and i >= 0:
      let rs = on.toRunes
      tabs[i].alignOn = (if rs.len > 0: rs[0].toUTF8 else: "")
      setTabs("Tabs", tabs)
  row:
    if button("Repeat Tab", w = dp(96), enabled = i >= 0):
      # (as far from it as it is from the one before -- the edge for the first --, again to the end)
      let step = tabs[i].pos - (if i > 0: tabs[i - 1].pos else: 0'f32)
      if step >= 1:
        var p2 = p
        var at = tabs[i].pos + step
        while at <= colW + 0.01:
          var c = tabs[i]
          c.pos = at
          p2.setTab(c)
          at += step
        setTabs("Repeat Tab", p2.tabs)
    if button("Delete", w = dp(64), enabled = i >= 0):
      tabs.delete(i)
      tabsUi.sel = -1
      setTabs("Tabs", tabs)
    if button("Clear All", w = dp(80), enabled = tabs.len > 0):
      tabsUi.sel = -1
      setTabs("Clear All Tabs", @[])
  paragraph((if rtl: tr("Right to left: measured from the column's right edge. ") else: "") &
            tr("Shift+Tab while typing: a Right Indent Tab."), color = ui.theme.gray)

proc paragraphBody() =
  let L = typeTarget()
  let p = curPara()
  row:
    alignButtons(p.align, true)
    directionButtons()
  cpDir = p.rtl
  let d = cur()
  template num(lab: string; lo, hi: float; name: string; field: untyped) =
    # (in the rulers' unit)
    row([96, 72, -1]):
      label lab
      var v = p.field
      if d.lengthField(v, dp(64), lo, hi):
        let x = v
        typePara.field = x
        applyPara(name, proc (p: var ParaStyle) = p.field = x)
      label unitShort()
  num("Indent left:", -4000, 4000, "Indent", indentLeft)
  num("Indent right:", -4000, 4000, "Indent", indentRight)
  num("First line:", -4000, 4000, "Indent", indentFirst)
  num("Space before:", 0, 4000, "Paragraph Spacing", spaceBefore)
  num("Space after:", 0, 4000, "Paragraph Spacing", spaceAfter)
  row:
    label "Direction:"
    if combo(["Of the text", "Left to right", "Right to left"], cpDir, w = dp(120)):
      typePara.rtl = cpDir
      let v = cpDir
      applyPara("Text Direction", proc (p: var ParaStyle) = p.rtl = v)
  # (the usual Insert Kashida: how long justified Arabic's joins may grow)
  const kOrder = [kaNone, kaShort, kaMedium, kaLong, kaStylistic]
  var ki = kOrder.find(if p.noKashida: kaNone else: p.kashida)
  row:
    label "Insert Kashida:"
    if combo(["None", "Short", "Medium", "Long", "Stylistic"], ki, w = dp(100)):
      let v = kOrder[clamp(ki, 0, 4)]
      typePara.kashida = v
      typePara.noKashida = false
      applyPara("Insert Kashida", proc (p: var ParaStyle) = (p.kashida = v; p.noKashida = false))
  label("(justified Arabic: a join in each word grows, where a scribe would lengthen it)",
        color = ui.theme.gray)
  # (the composer; Justification, Keep Options, Span Columns: the layout program's dialogs)
  row:
    label "Composer:"
    var ci = ord(p.composer)
    var cn: seq[string]
    for e in Composer: cn.add tr($e)
    if combo(cn, ci, w = dp(170)):
      let v = Composer(clamp(ci, 0, ord(high(Composer))))
      typePara.composer = v
      applyPara("Composer", proc (p: var ParaStyle) = p.composer = v)
  row:
    if button("Justification...", w = dp(104)): runCommand("Justification...")
    if button("Keep Options...", w = dp(104)): runCommand("Keep Options...")
    if button("Span Columns...", w = dp(104)): runCommand("Span Columns...")
  row:
    if button("Nested Styles...", w = dp(104)): runCommand("Drop Caps and Nested Styles...")
    if button("GREP Styles...", w = dp(104)): runCommand("GREP Styles...")
    if button("Hyphenation...", w = dp(104)): runCommand("Hyphenation...")
  row:
    if button("Paragraph Rules...", w = dp(104)): runCommand("Paragraph Rules...")
  row:
    var hy = p.hyphenate
    if checkbox("Hyphenate", hy):
      typePara.hyphenate = hy
      let v = hy
      applyPara("Hyphenate", proc (p: var ParaStyle) = p.hyphenate = v)
    label("(words broken at a line's end, in a box, in their language)", color = ui.theme.gray)
  # (punctuation hung out of the lines' edges: the paragraph's own, Photoshop's -- the whole
  # story's, letters' edges too, the layout program's Story panel)
  row:
    var hg = p.hanging
    if checkbox("Roman Hanging Punctuation", hg):
      typePara.hanging = hg
      let v = hg
      applyPara("Roman Hanging Punctuation", proc (p: var ParaStyle) = p.hanging = v)
  row:
    var om = L != nil and L.text.opticalMargin
    if checkbox("Optical Margin Alignment", om):
      let v = om
      applyText("Optical Margin Alignment", proc (t: var TextData) = t.opticalMargin = v)
    var ig = p.ignoreOptical
    if checkbox("Ignore Optical Margin", ig):
      typePara.ignoreOptical = ig
      let v = ig
      applyPara("Ignore Optical Margin", proc (p: var ParaStyle) = p.ignoreOptical = v)
  # a list: a mark before every paragraph of a text box
  var lk = ord(p.list)
  row:
    label "List:"
    if combo(["None", "Bullets", "Numbers"], lk, w = dp(100)):
      let v = ListKind(clamp(lk, 0, 2))
      typePara.list = v
      applyAllParas("List", proc (p: var ParaStyle) = p.list = v)
    if p.list == lkBullet:
      const marks = ["•", "–", "▪", "◆", "★", "✓", "○", "►"]
      var mi = max(0, marks.find(if p.listMark.len > 0: p.listMark else: "•"))
      if combo(marks, mi, w = dp(56)):
        let v = marks[clamp(mi, 0, marks.high)]
        typePara.listMark = v
        applyAllParas("List Mark", proc (p: var ParaStyle) = p.listMark = v)
    elif p.list == lkNumber:
      var names: seq[string]
      for s in NumberStyle: names.add $s
      var ni = ord(p.listNumbers)
      if combo(names, ni, w = dp(90)):
        let v = NumberStyle(clamp(ni, 0, ord(high(NumberStyle))))
        typePara.listNumbers = v
        applyAllParas("List Numbers", proc (p: var ParaStyle) = p.listNumbers = v)
  if p.list != lkNone:
    row:
      if p.list == lkNumber:
        label "From:"
        var from0 = max(1, p.listStart)
        if spin(from0, 1, 9999, w = dp(56)):
          let v = from0
          applyAllParas("List Start", proc (p: var ParaStyle) = p.listStart = v)
        const ends = [".", ")", "-", ":"]
        var ei = max(0, ends.find(if p.listSuffix.len > 0: p.listSuffix else: "."))
        if combo(ends, ei, w = dp(44)):
          let v = ends[clamp(ei, 0, ends.high)]
          applyAllParas("List Numbers", proc (p: var ParaStyle) = p.listSuffix = v)
      var own = p.listColor != 0
      if checkbox("Marks in the foreground color", own):
        let v = if own: (fg or 0xFF000000'u32) else: 0'u32
        applyAllParas("List Color", proc (p: var ParaStyle) = p.listColor = v)
    if L != nil and L.text.boxW <= 0:
      label("(a list is text in a box: drag a box with the Type tool)", color = ui.theme.gray)
  # a drop cap: the first letters as tall as so many lines
  var dl = p.dropLines
  var dc = max(1, p.dropChars)
  row([96, -1]):
    label "Drop cap lines:"
    if spin(dl, 0, 20, w = dp(64)):
      let v = if dl == 1: (if p.dropLines >= 2: 0 else: 2) else: dl   # (one line is no drop cap)
      typePara.dropLines = v
      applyAllParas("Drop Cap", proc (p: var ParaStyle) = p.dropLines = v)
  if p.dropLines >= 2:
    row([96, -1]):
      label "Letters:"
      if spin(dc, 1, 20, w = dp(64)):
        let v = dc
        typePara.dropChars = v
        applyAllParas("Drop Cap", proc (p: var ParaStyle) = p.dropChars = v)
  # (a book's page with a baseline grid: the lines on it)
  let grid = if active != nil: bookGrid(active) else: (0'f32, 0'f32)
  if L != nil and L.text.boxW > 0 and grid.step > 0:
    var on = L.text.gridStep > 0
    if checkbox("Align to baseline grid", on):
      let g = if on: grid else: (0'f32, 0'f32)
      let v = on
      typePara.gridAlign = v
      applyText("Align to Baseline Grid", proc (t: var TextData) =
        t.gridStep = g.step
        t.gridStart = g.start
        t.changeParas(0, t.runeLen, proc (p: var ParaStyle) = p.gridAlign = v))
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
    var gut = if L.text.gutter > 0: L.text.gutter else: 12'f32
    row:
      label "Columns:"
      if spin(cols, 1, 12, w = dp(52)):
        let v = cols
        applyText("Columns", proc (t: var TextData) = t.columns = v)
      label "Gutter:"
      if cur().lengthField(gut, dp(60), 0, 4000):
        let v = gut
        applyText("Gutter", proc (t: var TextData) = t.gutter = max(0.01'f32, v))
      label unitShort()
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

proc fontHasFeature(s: CharStyle; tag: string): bool =
  ## (the style's font has OpenType feature `tag`)
  when declared(featureTags):
    let f = fontFace(s.family, s.style).face
    f != nil and tag in f.featureTags
  else: false

proc otLabel(name, tag: string; s: CharStyle): string =
  ## (an OpenType menu item: in [brackets] when the font has not the feature, as the layout
  ## program shows it -- it can be set all the same, for the next font)
  if fontHasFeature(s, tag): name else: "[" & tr(name) & "]"

proc toggleLigatures() =
  ## Character panel menu > Ligatures: the font's standard ligatures on or off (Arabic's
  ## lam + alef and its joins stay: required).
  let on = not shownStyle().ligaturesOn
  applyChar("Ligatures", proc (x: var CharStyle) = x.features = withLigatures(x.features, on))

proc toggleOpenType(name: string) =
  ## Character panel menu > OpenType > `name`: its feature on or off.
  for (nm, tag) in OpenTypeMenu:
    if nm == name:
      let t = tag
      let on = not featureOn(shownStyle().features, t)
      applyChar(nm, proc (x: var CharStyle) =
        x.features = withFeature(x.features, t, on)
        if t == "c2sc": x.features = withFeature(x.features, "smcp", on))   # (All Small Caps: both)

proc fontSets(s: CharStyle): seq[tuple[tag, name: string]] =
  ## (the stylistic sets and character variants the style's font has, with its own names for them)
  when declared(featureTags):
    let f = fontFace(s.family, s.style).face
    if f != nil:
      for t in f.featureTags:
        if t.len == 4 and (t.startsWith("ss") or t.startsWith("cv")) and t[2 .. 3].allCharsInSet(Digits):
          result.add (t, f.featureName(t))

proc openTypeItems() =
  ## Ligatures and the OpenType menu (the Character panel's, Type's).
  let s = shownStyle()
  if menuItem("Ligatures", checked = s.ligaturesOn): toggleLigatures()
  submenu("OpenType"):
    for (nm, tag) in OpenTypeMenu:
      if menuItem(otLabel(nm, tag, s), checked = featureOn(s.features, tag)): toggleOpenType(nm)
    menuSeparator()
    submenu("Figure Style"):
      let fs = figureStyleOf(s.features)
      for k, (nm, _) in FigureStyles:
        if menuItem(nm, checked = k == fs): runCommand("Figure Style: " & nm)
    submenu("Positional Form"):
      let pf = positionalFormOf(s.features)
      for k, (nm, _) in PositionalForms:
        if menuItem(nm, checked = k == pf): runCommand("Positional Form: " & nm)
    let sets = fontSets(s)
    if sets.len > 0:
      submenu("Stylistic Sets"):
        for (tag, nm) in sets:
          if menuItem(nm, checked = featureOn(s.features, tag)): runCommand("Stylistic Set: " & tag)

proc typeMenuItems() =
  ## The menu of Character, Paragraph, Glyphs.
  openTypeItems()
  menuSeparator()
  if menuItem("Reset Character"):
    typeStyle = CharStyle(family: DastkhatFamily, style: "Regular", size: 48, color: fg, hScale: 1, vScale: 1)
  if menuItem("Reset Paragraph"): typePara = ParaStyle()
  menuSeparator()
  if menuItem("Underline Options..."): runCommand("Underline Options...")
  if menuItem("Strikethrough Options..."): runCommand("Strikethrough Options...")

var fgSeen = 0'u32               ## (the foreground color as last seen: `fgToText`)

proc fgToText() {.nimcall.} =
  ## A foreground color chosen -- a swatch, the Color panel, the picker, a library's color, the
  ## eyedropper -- while the Type tool works on a type layer (or its text is edited): the text
  ## takes it too (the selection, else the whole layer), as the layout program does; one undo step
  ## for a slider's whole drag.
  if fg == fgSeen: return
  let first = fgSeen == 0
  fgSeen = fg
  if first or (tool != tType and not te.on): return
  let L = typeTarget()
  if L == nil or (L.locked and not te.on): return
  if shownStyle().color == fg: return
  let c = fg
  applyChar("Text Color", proc (x: var CharStyle) = x.color = c)

beginFrameHooks.add fgToText

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
    alignButtons(curPara().align, false)
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

var patSwatch: tuple[key: Hash; b: Bitmap]   ## (Pattern Overlay's swatch)

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
  of fxPatternOverlay:
    row:
      label "Blend Mode:"
      ch modeCombo(e.mode, "m1")
    ch fxSlider("Opacity:", e.opacity, 0, 100, "%")
    # the pattern: one of those it comes with, or the one of Edit > Define Pattern
    var names = @PatternNames
    if pattern.len > 0 and patternW > 0: names.add "Defined Pattern"
    var shown: seq[string]
    for n in names: shown.add tr(n)
    var k = max(0, names.find(e.patternName))
    row:
      label "Pattern:"
      if e.pattern.len == e.patternW * e.patternH and e.patternW > 0:
        # (a swatch of it, made again only when it changes)
        let r = place(dp(28), dp(28))
        let key = hash(e.pattern) !& hash(e.patternW)
        if patSwatch.b == nil or patSwatch.key != key:
          let b = newBitmap(min(e.patternW, 64), min(e.patternH, 64))
          for y in 0 ..< b.h:
            for x in 0 ..< b.w: b.px[y * b.w + x] = e.pattern[y * e.patternW + x]
          patSwatch = (key, b)
        drawBitmap(r, patSwatch.b)
        box(r, ui.theme.frame)
      if combo(shown, k, w = dp(150)):
        if names[k] == "Defined Pattern":
          e.pattern = pattern
          e.patternW = patternW
          e.patternH = patternH
        else:
          let t = patternTile(names[k])
          e.pattern = t.px
          e.patternW = t.w
          e.patternH = t.h
        e.patternName = names[k]
        result = true
    ch fxSlider("Angle:", e.angle, -180, 180, "°")
    if e.scale <= 0: e.scale = 100
    ch fxSlider("Scale:", e.scale, 1, 1000, "%")
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
  menuSeparator()
  if menuItem("Create Layers", enabled = ok and L.hasStyle and not L.fx.hidden): runCommand("Create Layers")
  if menuItem("Scale Effects...", enabled = ok and L.hasStyle): runCommand("Scale Effects...")

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
  if menuItem("Convert to Shape", enabled = isT): runCommand("Convert to Shape")
  menuSeparator()
  if menuItem("Text Effects...", enabled = isT): runCommand("Text Effects...")
  if menuItem("Insert Table...", enabled = d != nil): runCommand("Insert Table...")
  if menuItem("Table Options...", enabled = isT and L.text.boxW > 0): runCommand("Table Options...")
  if menuItem(if isT and L.text.table.on: "Convert Table to Text" else: "Convert Text to Table",
              enabled = isT and L.text.boxW > 0):
    runCommand(if L.text.table.on: "Convert Table to Text" else: "Convert Text to Table")
  let isTable = isT and L.text.table.on
  submenu "Ta&ble":
    let typing = isTable and te.on and te.layer == L
    proc items(list: openArray[(string, string)]) =
      for (cap, cmd) in list:
        if cap == "-": menuSeparator()
        elif menuItem(cap, enabled = (if cmd.startsWith("Select "): typing
                                      else: isTable or cmd in ["Table Styles", "Cell Styles"])): runCommand(cmd)
    items([("Cell &Options...", "Cell Options..."), ("-", ""),
           ("Insert Row &Above", "Insert Row Above"), ("Insert Row &Below", "Insert Row Below"),
           ("Insert &Column Before", "Insert Column Before"), ("Insert Column A&fter", "Insert Column After"),
           ("Insert Ro&ws...", "Insert Rows..."), ("Insert Colum&ns...", "Insert Columns..."),
           ("&Delete Rows", "Delete Rows"), ("Delete Co&lumns", "Delete Columns"),
           ("Delete &Table", "Delete Table"), ("-", "")])
    submenu "S&elect":
      items([("&Cell", "Select Cell"), ("&Row", "Select Row"), ("C&olumn", "Select Column"),
             ("&Table", "Select Table")])
    items([("-", ""), ("&Merge Cells", "Merge Cells"), ("&Unmerge Cells", "Unmerge Cells"),
           ("Split Cell &Horizontally", "Split Cell Horizontally"),
           ("Split Cell &Vertically", "Split Cell Vertically"), ("-", ""),
           ("D&istribute Rows Evenly", "Distribute Rows Evenly"),
           ("Distribute Columns Evenl&y", "Distribute Columns Evenly"), ("So&rt...", "Sort..."), ("-", ""),
           ("Table &Styles", "Table Styles"), ("Cell Style&s", "Cell Styles")])
  menuSeparator()
  if menuItem("Rasterize Type", enabled = isT):
    if te.on: commitType()
    d.stepOnce("Rasterize Type", proc () = d.rasterizeText(L))

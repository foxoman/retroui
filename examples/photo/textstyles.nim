# Retro Atelier -- included by photo.nim
#
# Character Styles and Paragraph Styles, as the usual: a text's look kept
# by name in the document, given to text with a click, and changed in every
# text that has it when it is redefined. "+" beside a style: the text
# differs from it (Clear Override puts it back).

var
  styleRename: tuple[on: bool; paragraph: bool; old, name: string]

proc panelIcon(glyph, tip: string; down = false; enabled = true): bool {.discardable.} =
  ## (a small button with an icon, under a panel's list)
  toolButton(glyphIcon(glyph, ui.theme.text, dp(16)), tip, down, enabled)

proc styleTargetRange(): tuple[L: Layer; a, b: int] =
  ## (the text a style goes to: what is selected in the text being edited,
  ## else all of the current type layer)
  if te.on:
    let (a, b) = selRange()
    return (te.layer, a, b)
  (typeTarget(), 0, 0)

proc currentLook(): tuple[c: CharStyle; p: ParaStyle] =
  ## (the look a new style is made from: the text's where the caret is)
  result.c = shownStyle()
  result.p = curPara()
  result.c.styleName = ""
  result.p.styleName = ""

proc uniqueStyleName(list: seq[TextStyleDef]; base: string): string =
  var n = list.len + 1
  result = base & " " & $n
  while list.styleIndex(result) >= 0:
    inc n
    result = base & " " & $n

proc styleRow(caption: string; selected, overridden: bool; key: string): tuple[clicked, double: bool] =
  let r = place(available(), ItemH)
  if selected: fill(r, ui.theme.select)
  let col = if selected: ui.theme.selectText else: ui.theme.text
  text(r.x + dp(4), itemTextY(r.y), caption & (if overridden: "+" else: ""), col)
  let hit = interact(idOf("stylerow:" & key), r, focusable = false)
  (hit.clicked, hit.clicked and ui.clicks >= 2)

proc stylesPanel(paragraph: bool) =
  let d = cur()
  if d == nil:
    label("No image open", color = ui.theme.gray)
    return
  let list = if paragraph: d.paraStyles else: d.charStyles
  let (L, a, b) = styleTargetRange()
  # the style the text has (where the caret is)
  var current = ""
  if L != nil:
    if paragraph: current = curPara().styleName
    elif te.on: current = te.style.styleName
    else: current = L.text.styleAt(0).styleName
  let at = if te.on and te.layer == L: te.caret else: 0
  let over = L != nil and d.styleOverridden(L, paragraph, at)
  let (pa, pb) = if te.on and te.layer == L: (a, b) else: (0, -1)
  let none = if paragraph: "[Basic Paragraph]" else: "[No Character Style]"
  let kind = if paragraph: "Paragraph Style" else: "Character Style"
  template give(name: string) =
    if L == nil:
      if paragraph:
        typePara.styleName = name
        let k = d.paraStyles.styleIndex(name)
        if k >= 0:
          typePara = d.paraStyles[k].para
          typePara.styleName = name
      else:
        let k = d.charStyles.styleIndex(name)
        if k >= 0: keepTypeStyle(d.charStyles[k].char)
        typeStyle.styleName = name
    else:
      d.beginStep(kind)
      d.touchLayers()
      if paragraph:
        d.applyParaStyle(L, name, pa, pb)
        # (a style that keeps its lines on the baseline grid: on the page's grid, or off it)
        let g = if active != nil: bookGrid(active) else: (0'f32, 0'f32)
        let ga = L.text.paraFmtAt(max(0, pa)).gridAlign
        if L.text.boxW > 0 and (ga != (L.text.gridStep > 0)):
          var t = L.text
          if ga and g.step > 0:
            t.gridStep = g.step
            t.gridStart = g.start
          elif not ga:
            t.gridStep = 0
          d.setText(L, t)
      else: d.applyCharStyle(L, a, b, name)
      d.endStep()
      if te.on and not paragraph:
        te.style.styleName = name
        let k = d.charStyles.styleIndex(name)
        if k >= 0:
          te.style = d.charStyles[k].char
          te.style.styleName = name
  let lh = max(ItemH * 4, min(ItemH * 12, remainingH() - ItemH * 4))
  beginScroll(lh, "stylelist" & $paragraph)
  let r0 = styleRow(none, current.len == 0, false, "none" & $paragraph)
  if r0.clicked: give("")
  for st in list:
    let sel = st.name == current
    let r = styleRow(st.name, sel, sel and over, st.name & $paragraph)
    if r.double:
      # (a paragraph style: its Style Options, as the layout program's; a character style renamed)
      if paragraph: startStyleOptions(st.name)
      else: styleRename = (true, paragraph, st.name, st.name)
    elif r.clicked: give(st.name)
  endScroll()
  if styleRename.on and styleRename.paragraph == paragraph:
    row([-1, 64, 56]):
      edit(styleRename.name)
      if button("Rename"):
        d.renameStyle(paragraph, styleRename.old, styleRename.name)
        styleRename.on = false
        inc d.ver
      if button("Cancel"): styleRename.on = false
  row:
    if panelIcon(pxNew, "New " & kind & " (from the text's look)"):
      let (c, p) = currentLook()
      let name = uniqueStyleName(list, kind)
      d.beginStep("New " & kind)
      d.touchLayers()
      d.redefineStyle(paragraph, name, c, p)
      if L != nil:
        if paragraph: d.applyParaStyle(L, name, pa, pb)
        else: d.applyCharStyle(L, a, b, name)
      d.endStep()
    if panelIcon(pxRefresh, "Redefine " & kind & " by Merging Overrides",
               enabled = current.len > 0 and L != nil):
      let (c, p) = currentLook()
      d.beginStep("Redefine " & kind)
      d.touchLayers()
      d.redefineStyle(paragraph, current, c, p)
      d.endStep()
    if panelIcon(pxUndo, "Clear Override", enabled = over):
      d.beginStep("Clear Override")
      d.touchLayers()
      if paragraph: d.applyParaStyle(L, current, pa, pb)
      else: d.applyCharStyle(L, a, b, current)
      d.endStep()
    if paragraph and panelIcon(pxSettings, "Paragraph Style Options...", enabled = current.len > 0):
      startStyleOptions(current)
    if panelIcon(pxDelete, "Delete " & kind, enabled = current.len > 0):
      d.beginStep("Delete " & kind)
      d.touchLayers()
      d.deleteStyle(paragraph, current)
      d.endStep()
  if L == nil:
    label("For the next text", color = ui.theme.gray)
  elif over:
    label("+: the text differs from its style", color = ui.theme.gray)

var gsThumbs: tuple[key: string; bmps: seq[Bitmap]]
var gsPick = -1                    ## (the Graphic Style last clicked: Delete takes it away)

proc graphicStylesBody() =
  ## Graphic Styles, as the drawing program's: all of how a shape looks, kept by name -- each a
  ## swatch of it; a click gives it to the shapes picked (their outlines kept).
  let d = cur()
  if d == nil:
    label("No image open", color = ui.theme.gray)
    return
  let L = d.current
  # (the swatches: a rounded square in each style, made again when the styles change)
  let side = dp(36)
  var key = $side
  for g in d.graphicStyles: key.add g.name & $hash($g.look.toJson & $g.opacity & $g.mode)
  if key != gsThumbs.key:
    gsThumbs.key = key
    gsThumbs.bmps = @[]
    for g in d.graphicStyles:
      var s = g.look
      let m = float(side) * 0.18
      s.path = rectPath(m, m, float(side) - m, float(side) - m, float(side) * 0.15)
      var px = newSeq[uint32](side * side)
      for i in 0 ..< px.len: px[i] = (if ((i mod side) div 6 + (i div side) div 6) mod 2 == 0: 0xFFFFFFFF'u32 else: 0xFFE0E0E0'u32)
      var over = newSeq[uint32](side * side)
      discard renderShape(s, over, side, side)
      for i in 0 ..< px.len: px[i] = blendPx(px[i], over[i], g.opacity * 255 div 100, bmNormal)
      var b = newBitmap(side, side)
      b.px = px
      gsThumbs.bmps.add b
  let cols = max(1, (available() - dp(8)) div (side + dp(6)))
  var gone = -1
  if d.graphicStyles.len == 0:
    paragraph("No graphic styles yet: pick a shape and press New to keep its look.", color = ui.theme.gray)
  var i = 0
  while i < d.graphicStyles.len:
    row:
      for c in 0 ..< cols:
        if i >= d.graphicStyles.len: break
        let g = d.graphicStyles[i]
        let r = place(side, side)
        if i < gsThumbs.bmps.len: drawBitmap(r, gsThumbs.bmps[i])
        box(r, if i == gsPick: ui.theme.select else: ui.theme.edge)
        let h = interact(idOf("gs:" & g.name), r)
        if mouseIn(r) and canHover(): ui.tip = g.name
        if h.clicked: gsPick = i
        if h.clicked and L != nil:
          d.beginStep("Apply Graphic Style")
          d.touchLayers()
          var n = 0
          for k in d.pickedLayers & @[d.cur]:
            if k >= 0 and k < d.layers.len and d.layers[k].isShape:
              d.applyGraphicStyle(d.layers[k], g.name)
              inc n
          if n > 0:
            d.endStep()
            d.markAll()
            status = "Graphic Style \"" & g.name & "\""
          else:
            d.cancelStep()
            status = "Graphic Styles: pick a shape layer"
        inc i
  row:
    if panelIcon(pxNew, "New Graphic Style (from the shape's look)", enabled = L != nil and L.isShape):
      var n = d.graphicStyles.len + 1
      while d.graphicStyleIndex("Graphic Style " & $n) >= 0: inc n
      d.beginStep("New Graphic Style")
      d.touchLayers()
      d.graphicStyles.add graphicStyleOf(L, "Graphic Style " & $n)
      d.endStep()
    if panelIcon(pxDelete, "Delete Graphic Style", enabled = gsPick >= 0 and gsPick < d.graphicStyles.len):
      gone = gsPick
      gsPick = -1
  if gone >= 0:
    d.beginStep("Delete Graphic Style")
    d.touchLayers()
    d.graphicStyles.delete(gone)
    d.endStep()

proc objectStylesBody() =
  ## Object Styles, as the layout program's: how a shape or a text frame looks, kept by name; a
  ## click gives it to the layers picked, "+" where a layer differs from it.
  let d = cur()
  if d == nil:
    label("No image open", color = ui.theme.gray)
    return
  let L = d.current
  let current = if L != nil: L.objectStyle else: ""
  let over = L != nil and d.objectStyleOverridden(L)
  proc give(name: string) =
    d.beginStep("Apply Object Style")
    d.touchLayers()
    for i in d.pickedLayers: d.applyObjectStyle(d.layers[i], name)
    d.endStep()
    d.markAll()
  let lh = max(ItemH * 4, min(ItemH * 12, remainingH() - ItemH * 4))
  beginScroll(lh, "objstylelist")
  let r0 = styleRow("[None]", current.len == 0, false, "objnone")
  if r0.clicked and L != nil: give("")
  for st in d.objectStyles:
    let sel = st.name == current
    let r = styleRow(st.name, sel, sel and over, "obj:" & st.name)
    if r.double: startObjectStyleOptions(st.name)
    elif r.clicked and L != nil: give(st.name)
  endScroll()
  row:
    if panelIcon(pxNew, "New Object Style (from the layer's look)", enabled = L != nil):
      var n = d.objectStyles.len + 1
      while d.objectStyleIndex("Object Style " & $n) >= 0: inc n
      let def = objectStyleOf(L, "Object Style " & $n)
      d.beginStep("New Object Style")
      d.touchLayers()
      d.redefineObjectStyle(def)
      d.applyObjectStyle(L, def.name)
      d.endStep()
    if panelIcon(pxRefresh, "Redefine Object Style (from the layer's look)", enabled = current.len > 0 and L != nil):
      let k = d.objectStyleIndex(current)
      var def = objectStyleOf(L, current)
      let was = d.objectStyles[k]
      # (what it sets, as it was)
      def.useFill = was.useFill and def.useFill
      def.useStroke = was.useStroke and def.useStroke
      def.useEffects = was.useEffects
      def.useFrame = was.useFrame and def.useFrame
      def.useParagraph = was.useParagraph
      if not def.useFrame:
        def.columns = was.columns; def.gutter = was.gutter; def.inset = was.inset
        def.vjust = was.vjust; def.balance = was.balance; def.autoSize = was.autoSize
      if def.paraStyle.len == 0: def.paraStyle = was.paraStyle
      if not L.isShape: def.shape = was.shape
      d.beginStep("Redefine Object Style")
      d.touchLayers()
      d.redefineObjectStyle(def)
      d.endStep()
      d.markAll()
    if panelIcon(pxUndo, "Clear Overrides", enabled = over): give(current)
    if panelIcon(pxSettings, "Object Style Options...", enabled = current.len > 0):
      startObjectStyleOptions(current)
    if panelIcon(pxDelete, "Delete Object Style", enabled = current.len > 0):
      d.beginStep("Delete Object Style")
      d.touchLayers()
      d.deleteObjectStyle(current)
      d.endStep()
  if L == nil: label("Pick a layer to give it a style", color = ui.theme.gray)
  elif over: label("+: the layer differs from its style", color = ui.theme.gray)

proc charStylesBody() = stylesPanel(false)
proc paraStylesBody() = stylesPanel(true)

proc stylesMenuItems(paragraph: bool) =
  let d = cur()
  let kind = if paragraph: "Paragraph Style" else: "Character Style"
  if menuItem("New " & kind & "...", enabled = d != nil):
    let (c, p) = currentLook()
    let list = if paragraph: d.paraStyles else: d.charStyles
    d.redefineStyle(paragraph, uniqueStyleName(list, kind), c, p)
  if paragraph:
    let L = typeTarget()
    let curName = if L != nil: curPara().styleName else: ""
    if menuItem("Style Options...", enabled = d != nil and curName.len > 0): startStyleOptions(curName)
  if menuItem("Load " & (if paragraph: "Paragraph" else: "Character") & " Styles from the other images",
              enabled = d != nil and docs.len > 1):
    # (the usual Load Styles: from the documents open)
    for o in docs:
      if o.doc == d: continue
      for st in (if paragraph: o.doc.paraStyles else: o.doc.charStyles):
        let list = if paragraph: d.paraStyles else: d.charStyles
        if list.styleIndex(st.name) < 0:
          if paragraph: d.paraStyles.add st else: d.charStyles.add st

# ---- OpenType: the font's features and a variable font's axes ------------------------------------------------

const
  RequiredFeatures = ["ccmp", "locl", "rlig", "rclt", "init", "medi", "fina", "isol", "fin2", "fin3", "med2",
                      "mark", "mkmk", "curs", "mset", "abvm", "blwm", "abvs", "blws", "pres", "psts",
                      "nukt", "akhn", "rphf", "blwf", "half", "pstf", "vatu", "cjct", "ljmo", "vjmo", "tjmo",
                      "stch", "dist", "rvrn", "aalt", "ltra", "ltrm", "rtla", "rtlm", "vert", "vrt2"]

proc axisValue*(variation, tag: string; default: float): float =
  ## A variable font axis's value in a style ("wght=650 wdth=90").
  result = default
  for w in variation.splitWhitespace:
    let p = w.split('=')
    if p.len == 2 and p[0] == tag:
      try: result = parseFloat(p[1]) except ValueError: discard

proc withAxis*(variation, tag: string; v: float; default: float): string =
  var ws: seq[string]
  for w in variation.splitWhitespace:
    if not w.startsWith(tag & "="): ws.add w
  if abs(v - default) > 1e-6: ws.add tag & "=" & formatFloat(v, ffDecimal, 1)
  ws.join(" ")

proc openTypeBody() =
  let s = shownStyle()
  let fc = fontFace(s.family, s.style)
  let f = fc.face
  if f == nil:
    label("No font", color = ui.theme.gray)
    return
  label(s.family & " " & s.style, color = ui.theme.gray)
  when declared(featureTags):
    var tags: seq[string]
    for t in f.featureTags:
      if t notin RequiredFeatures: tags.add t
    if tags.len == 0:
      paragraph("This font has no features to choose (its letters are joined, placed and kerned as it sets " &
                "them).", color = ui.theme.gray)
    else:
      let lh = min(ItemH * 12, max(ItemH * 4, remainingH() div 2))
      beginScroll(lh, "otfeatures")
      for t in tags:
        var on = featureOn(s.features, t)
        if checkbox(f.featureName(t) & "  (" & t & ")", on):
          let tag = t
          let v = on
          applyChar("OpenType", proc (x: var CharStyle) = x.features = withFeature(x.features, tag, v))
      endScroll()
  else:
    paragraph("OpenType features are not in this build.", color = ui.theme.gray)
  when declared(axes):
    let ax = f.axes
    if ax.len > 0:
      label "Variable font:"
      for a in ax:
        var v = int(round(axisValue(s.variation, a.tag, a.defV)))
        row([90, -1, 48]):
          label (if a.name.len > 0: a.name else: a.tag) & ":"
          var changed = slider(v, int(a.minV), int(a.maxV))
          changed = spin(v, int(a.minV), int(a.maxV), w = dp(48)) or changed
          if changed:
            let tag = a.tag
            let val = v.float
            let dv = a.defV
            applyChar("Variable Font", proc (x: var CharStyle) = x.variation = withAxis(x.variation, tag, val, dv))

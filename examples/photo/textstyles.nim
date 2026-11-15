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
  let L = typeTarget()
  result.c = shownStyle()
  result.p = if L != nil: L.text.para else: typePara
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
    if paragraph: current = L.text.para.styleName
    elif te.on: current = te.style.styleName
    else: current = L.text.styleAt(0).styleName
  let over = L != nil and d.styleOverridden(L, paragraph)
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
        if k >= 0: typeStyle = d.charStyles[k].char
        typeStyle.styleName = name
    else:
      d.beginStep(kind)
      d.touchLayers()
      if paragraph: d.applyParaStyle(L, name)
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
      styleRename = (true, paragraph, st.name, st.name)
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
        if paragraph: d.applyParaStyle(L, name)
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
      if paragraph: d.applyParaStyle(L, current)
      else: d.applyCharStyle(L, a, b, current)
      d.endStep()
    if panelIcon(pxDelete, "Delete " & kind, enabled = current.len > 0):
      d.beginStep("Delete " & kind)
      d.touchLayers()
      d.deleteStyle(paragraph, current)
      d.endStep()
  if L == nil:
    label("For the next text", color = ui.theme.gray)
  elif over:
    label("+: the text differs from its style", color = ui.theme.gray)

proc charStylesBody() = stylesPanel(false)
proc paraStylesBody() = stylesPanel(true)

proc stylesMenuItems(paragraph: bool) =
  let d = cur()
  let kind = if paragraph: "Paragraph Style" else: "Character Style"
  if menuItem("New " & kind & "...", enabled = d != nil):
    let (c, p) = currentLook()
    let list = if paragraph: d.paraStyles else: d.charStyles
    d.redefineStyle(paragraph, uniqueStyleName(list, kind), c, p)
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
  OnByDefault = ["liga", "clig", "calt", "kern"]

proc featureState*(features, tag: string): bool =
  ## Whether `tag` is on in a style's feature list ("+ss01 -liga"), the
  ## font's own default when the list does not say.
  result = tag in OnByDefault
  for w in features.splitWhitespace:
    if w == "+" & tag or w == tag: result = true
    elif w == "-" & tag: result = false

proc withFeature*(features, tag: string; on: bool): string =
  ## The feature list with `tag` set (left out when that is its default).
  var ws: seq[string]
  for w in features.splitWhitespace:
    if w notin ["+" & tag, "-" & tag, tag]: ws.add w
  if on != (tag in OnByDefault): ws.add (if on: "+" else: "-") & tag
  ws.join(" ")

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
        var on = featureState(s.features, t)
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

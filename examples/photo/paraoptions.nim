## Retro Atelier: the Paragraph panel's Justification, Keep Options and Span Columns dialogs, as
## the layout program's -- for the paragraphs the selection is in while typing, all of a text
## picked otherwise; Preview shows them as set, Cancel puts them back (included by photo.nim).

var
  poDlg: tuple[open: bool; kind: string; layer: Layer; snap: TextData; editing: bool; a, b: int;
               f: ParaStyle; preview: bool; applied: string]
    ## (the dialog open: which, the text as it was, the paragraphs, the settings in it)
  okPara*: bool      ## (its OK pressed from outside: the tests)
  poPending: bool    ## (a dialog open, its Preview to take back if it is closed from outside)

proc poCopy(dst: var ParaStyle; src: ParaStyle; kind: string) =
  ## (the settings a dialog has, from `src`)
  case kind
  of "Justification...":
    dst.wordSpacing = src.wordSpacing
    dst.letterSpacing = src.letterSpacing
    dst.glyphScaling = src.glyphScaling
    dst.composer = src.composer
  of "Keep Options...":
    dst.keepWithNext = src.keepWithNext
    dst.keepTogether = src.keepTogether
    dst.keepStart = src.keepStart
    dst.keepEnd = src.keepEnd
    dst.startAt = src.startAt
  of "Span Columns...":
    dst.spanAll = src.spanAll
    dst.splitColumns = src.splitColumns
  of "Drop Caps and Nested Styles...":
    dst.dropLines = src.dropLines
    dst.dropChars = src.dropChars
    dst.nested = src.nested
    dst.lineStyles = src.lineStyles
    dst.repeatLast = src.repeatLast
  of "GREP Styles...":
    dst.grepStyles = src.grepStyles
  else: discard

proc charStyleChoices(d: Doc): seq[string] =
  ## (the character styles to pick for a nested or GREP style: [None] first)
  result = @[tr("[None]")]
  for st in d.charStyles: result.add st.name

proc lookOf(d: Doc; name: string): CharStyle =
  let k = d.charStyles.styleIndex(name)
  if k >= 0: d.charStyles[k].char else: defaultStyle()

proc nestedRows(d: Doc; list: var seq[NestedStyle]) =
  ## Nested Styles, as the layout program lists them: a character style, through or up to, so
  ## many, words, characters, sentences or a letter -- one after another from the paragraph's start
  let names = charStyleChoices(d)
  if list.len == 0: label("(none: New Nested Style adds one)", color = ui.theme.gray)
  var gone = -1
  for i in 0 ..< list.len:
    row([110, 80, 54, 100, 44, -1]):
      var k = max(0, names.find(list[i].name))
      if list[i].name.len == 0: k = 0
      if combo(names, k, w = dp(104)):
        list[i].name = if k <= 0: "" else: names[k]
        list[i].look = d.lookOf(list[i].name)
      var thr = if list[i].through: 0 else: 1
      if combo([tr("through"), tr("up to")], thr, w = dp(74)): list[i].through = thr == 0
      var n = max(1, list[i].count)
      if spin(n, 1, 999, w = dp(50)): list[i].count = n
      var u = ord(list[i].unit)
      var un: seq[string]
      for e in NestedUnit: un.add tr(if e == nuUpTo: "Letter" else: $e)
      if combo(un, u, w = dp(94)): list[i].unit = NestedUnit(clamp(u, 0, ord(high(NestedUnit))))
      if list[i].unit == nuUpTo:
        if list[i].upTo.len == 0: list[i].upTo = ":"
        edit(list[i].upTo, w = dp(40))
      else: label ""
      if button("-", w = dp(24)): gone = i
  if gone >= 0: list.delete(gone)
  row:
    if button("New Nested Style", w = dp(130)) and list.len < 50:
      let nm = if d.charStyles.len > 0: d.charStyles[0].name else: ""
      list.add NestedStyle(name: nm, look: d.lookOf(nm), count: 1, unit: nuWords, through: true)

proc lineRows(d: Doc; list: var seq[NestedLine]; repeatLast: var int) =
  ## Nested Line Styles, as the layout program lists them: a character style for so many lines,
  ## one after another from the paragraph's first line; then, if asked, the last styles again
  ## ([Repeat])
  let names = charStyleChoices(d)
  if list.len == 0: label("(none: New Line Style adds one)", color = ui.theme.gray)
  var gone = -1
  for i in 0 ..< list.len:
    row([110, 40, 54, 50, -1]):
      var k = max(0, names.find(list[i].name))
      if list[i].name.len == 0: k = 0
      if combo(names, k, w = dp(104)):
        list[i].name = if k <= 0: "" else: names[k]
        list[i].look = d.lookOf(list[i].name)
      label "for"
      var n = max(1, list[i].lines)
      if spin(n, 1, 999, w = dp(50)): list[i].lines = n
      label "Lines"
      if button("-", w = dp(24)): gone = i
  if gone >= 0: list.delete(gone)
  row([130, 130, 54, 44]):
    if button("New Line Style", w = dp(124)) and list.len < 50:
      let nm = if d.charStyles.len > 0: d.charStyles[0].name else: ""
      list.add NestedLine(name: nm, look: d.lookOf(nm), lines: 1)
    var rp = repeatLast > 0
    if checkbox("Repeat the Last", rp): repeatLast = (if rp: 1 else: 0)
    var rn = max(1, repeatLast)
    if spin(rn, 1, 999, w = dp(50)) and repeatLast > 0: repeatLast = rn
    label "Styles"

proc grepRows(d: Doc; list: var seq[GrepStyle]) =
  ## GREP Styles: a character style wherever a pattern matches in the paragraph
  let names = charStyleChoices(d)
  if list.len == 0: label("(none: New GREP Style adds one)", color = ui.theme.gray)
  var gone = -1
  for i in 0 ..< list.len:
    row([110, 56, -1, 30]):
      var k = max(0, names.find(list[i].name))
      if list[i].name.len == 0: k = 0
      if combo(names, k, w = dp(104)):
        list[i].name = if k <= 0: "" else: names[k]
        list[i].look = d.lookOf(list[i].name)
      label "To Text:"
      edit(list[i].pattern)
      if button("-", w = dp(24)): gone = i
  if gone >= 0: list.delete(gone)
  row:
    if button("New GREP Style", w = dp(130)) and list.len < 50:
      let nm = if d.charStyles.len > 0: d.charStyles[0].name else: ""
      list.add GrepStyle(name: nm, look: d.lookOf(nm), pattern: "\\d+")
  paragraph("A pattern as in Find/Change's GREP: \\d+ numbers, [A-Z]{2,} capitals, \\(.+?\\) what is in brackets.",
            color = ui.theme.gray)

proc poApplied(t: TextData): TextData =
  ## (the text as it was with the dialog's settings in its paragraphs)
  result = t
  let f = poDlg.f
  let kind = poDlg.kind
  let (a, b) = if poDlg.editing: (poDlg.a, poDlg.b) else: (0, t.runeLen)
  result.changeParas(a, b, proc (p: var ParaStyle) = poCopy(p, f, kind))

proc startParaOptions(name: string) =
  let d = cur()
  let L = typeTarget()
  if d == nil or L == nil:
    status = tr(name.replace("...", "")) & ": " & tr("pick a type layer, or type in one")
    return
  let editing = te.on and te.layer == L
  var f = curPara()
  # (the wanted widths shown as the layout program has them when not set)
  if f.wordSpacing == [0'i16, 0, 0]: f.wordSpacing = [80'i16, 100, 133]
  if f.glyphScaling == [0'i16, 0, 0]: f.glyphScaling = [100'i16, 100, 100]
  poDlg = (true, name, L, L.text, editing, min(te.caret, te.anchor), max(te.caret, te.anchor), f, true, "")
  poPending = true

proc paraOptionsDialog() =
  let d = cur()
  let L = poDlg.layer
  if not poDlg.open:
    if poPending:
      # (closed from outside: as Cancel)
      poPending = false
      if d != nil and L in d.layers and L.text != poDlg.snap:
        d.setText(L, poDlg.snap)
        d.markAll()
    return
  if d == nil or L notin d.layers:
    poDlg.open = false
    poPending = false
    return
  var ok = okPara
  var cancel = false
  okPara = false
  let title = poDlg.kind.replace("...", "")
  dialog(poDlg.open, title, 420):
    case poDlg.kind
    of "Justification...":
      # (Word Spacing, Letter Spacing, Glyph Scaling: least, wanted, most)
      row([120, 70, 70, 70, -1]):
        label ""
        label "Minimum"
        label "Desired"
        label "Maximum"
        label ""
      for (cap, unit, lo, hi, which) in [("Word Spacing:", "%", 0, 1000, 0), ("Letter Spacing:", "%", -100, 500, 1),
                                         ("Glyph Scaling:", "%", 50, 200, 2)]:
        row([120, 70, 70, 70, -1]):
          label cap
          var v = case which
                  of 0: poDlg.f.wordSpacing
                  of 1: poDlg.f.letterSpacing
                  else: poDlg.f.glyphScaling
          var x = [int(v[0]), int(v[1]), int(v[2])]
          for q in 0 .. 2:
            if spin(x[q], lo, hi, w = dp(62)):
              # (least no more than wanted, wanted no more than most)
              if q == 0: x[1] = max(x[1], x[0])
              if q == 1:
                x[0] = min(x[0], x[1])
                x[2] = max(x[2], x[1])
              if q == 2: x[1] = min(x[1], x[2])
              x[0] = min(x[0], x[1])
          for q in 0 .. 2: v[q] = int16(x[q])
          case which
          of 0: poDlg.f.wordSpacing = v
          of 1: poDlg.f.letterSpacing = v
          else: poDlg.f.glyphScaling = v
          label unit
      row([120, -1]):
        label "Composer:"
        var c = ord(poDlg.f.composer)
        var names: seq[string]
        for e in Composer: names.add tr($e)
        if combo(names, c, w = dp(220)): poDlg.f.composer = Composer(clamp(c, 0, ord(high(Composer))))
      paragraph("Justified lines get their room from the spaces first, then between the letters, then by " &
                "making the letters a little wider or narrower. The Paragraph Composer weighs the whole " &
                "paragraph at once; the Single-line Composer a line at a time.", color = ui.theme.gray)
    of "Keep Options...":
      row([180, 70, -1]):
        label "Keep with Next:"
        spin(poDlg.f.keepWithNext, 0, 5, w = dp(62))
        label "lines"
      var on = poDlg.f.keepTogether or poDlg.f.keepStart > 1 or poDlg.f.keepEnd > 1
      if checkbox("Keep Lines Together", on):
        if on:
          poDlg.f.keepTogether = true
        else:
          poDlg.f.keepTogether = false
          poDlg.f.keepStart = 0
          poDlg.f.keepEnd = 0
      if on:
        var mode = if poDlg.f.keepTogether: 0 else: 1
        row([24, -1]):
          label ""
          if radio("All Lines in Paragraph", mode, 0): poDlg.f.keepTogether = true
        row([24, -1]):
          label ""
          if radio("At Start/End of Paragraph", mode, 1):
            poDlg.f.keepTogether = false
            poDlg.f.keepStart = max(2, poDlg.f.keepStart)
            poDlg.f.keepEnd = max(2, poDlg.f.keepEnd)
        if mode == 1:
          var s0 = max(1, poDlg.f.keepStart)
          var e0 = max(1, poDlg.f.keepEnd)
          row([48, 132, 70, -1]):
            label ""
            label "Start:"
            if spin(s0, 1, 50, w = dp(62)): poDlg.f.keepStart = s0
            label "lines"
          row([48, 132, 70, -1]):
            label ""
            label "End:"
            if spin(e0, 1, 50, w = dp(62)): poDlg.f.keepEnd = e0
            label "lines"
      row([180, -1]):
        label "Start Paragraph:"
        var k = ord(poDlg.f.startAt)
        var names: seq[string]
        for e in ParaStart: names.add tr($e)
        if combo(names, k, w = dp(160)): poDlg.f.startAt = ParaStart(clamp(k, 0, ord(high(ParaStart))))
    of "Span Columns...":
      var layout = if poDlg.f.spanAll: 1 elif poDlg.f.splitColumns >= 2: 2 else: 0
      row([150, -1]):
        label "Paragraph Layout:"
        if combo([tr("Single Column"), tr("Span Columns"), tr("Split Column")], layout, w = dp(160)):
          poDlg.f.spanAll = layout == 1
          poDlg.f.splitColumns = if layout == 2: max(2, poDlg.f.splitColumns) else: 0
      if layout == 2:
        var n = max(2, poDlg.f.splitColumns)
        row([150, 70, -1]):
          label "Sub-columns:"
          if spin(n, 2, 20, w = dp(62)): poDlg.f.splitColumns = n
          label ""
      paragraph(case layout
                of 1: "The paragraph across all the box's columns -- a heading over them; the columns above it balanced."
                of 2: "The paragraph split into columns of its own, side by side within its column."
                else: "The paragraph in its column.", color = ui.theme.gray)
    of "Drop Caps and Nested Styles...":
      row([120, 70, 80, 70, -1]):
        label "Drop Cap Lines:"
        var dl = poDlg.f.dropLines
        if spin(dl, 0, 20, w = dp(62)): poDlg.f.dropLines = (if dl == 1: (if poDlg.f.dropLines >= 2: 0 else: 2) else: dl)
        label "Characters:"
        var dc = max(1, poDlg.f.dropChars)
        if spin(dc, 1, 20, w = dp(62)): poDlg.f.dropChars = dc
        label ""
      label("Nested Styles:")
      nestedRows(d, poDlg.f.nested)
      label("Nested Line Styles:")
      lineRows(d, poDlg.f.lineStyles, poDlg.f.repeatLast)
    of "GREP Styles...":
      grepRows(d, poDlg.f.grepStyles)
    else: discard
    row:
      checkbox("Preview", poDlg.preview)
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): cancel = true
  # (Preview: the paragraphs as set; off, or Cancel: as they were)
  let key = $(poDlg.f, poDlg.preview)
  if ok or cancel or not poDlg.open:
    var t = poDlg.snap
    if L.text != t: d.setText(L, t)
    if ok:
      let f = poDlg.f
      let kind = poDlg.kind
      if poDlg.editing and te.on and te.layer == L:
        let (a, b) = (poDlg.a, poDlg.b)
        editText(proc (t: var TextData) = t.changeParas(a, b, proc (p: var ParaStyle) = poCopy(p, f, kind)))
      else:
        d.stepOnce(title, proc () =
          var u = L.text
          u.changeParas(0, u.runeLen, proc (p: var ParaStyle) = poCopy(p, f, kind))
          d.setText(L, u))
    poDlg.open = false
    poPending = false
    d.markAll()
  elif key != poDlg.applied:
    poDlg.applied = key
    d.setText(L, if poDlg.preview: poApplied(poDlg.snap) else: poDlg.snap)
    d.markAll()

# ---- Paragraph Style Options -------------------------------------------------------------------------------

var psoDlg: tuple[open: bool; old, name: string; f: ParaStyle; page: int]
var psoTab: tuple[sel: int; pos: float; kind: int; leader: string]   ## (the dialog's Tabs: the stop picked, a new one)

proc tabRows(d: Doc; f: var ParaStyle) =
  ## (a paragraph style's tab stops: a list, each where (the rulers' unit), its kind, its
  ## leader; one put in by where, its kind and leader; the one picked taken away)
  let u = viewPrefs.rulerUnit
  let unitPx = unitPixels(u, d.dpi, d.w)
  var names: seq[string]
  for t in f.tabs:
    names.add inUnits(t.pos.float, u, d.dpi, d.w) & "   " & tr($t.align) &
              (if t.align == tabChar: " \"" & (if t.alignOn.len > 0: t.alignOn else: ".") & "\"" else: "") &
              (if t.leader.len > 0: "   " & tr("leader") & " \"" & t.leader & "\"" else: "")
  if names.len == 0: label("No tab stops: one every two ems.", color = ui.theme.gray)
  else: listbox(names, psoTab.sel, rows = min(6, max(3, names.len)))
  row([70, 80, 50, 110, 60, -1]):
    label "Position:"
    discard numberEdit(psoTab.pos, decimals = (if u == ruPixels: 0 else: 2), w = dp(74), lo = 0, hi = 99999)
    label "Kind:"
    var kinds: seq[string]
    for a in TabAlign: kinds.add tr($a)
    discard combo(kinds, psoTab.kind, w = dp(104))
    label "Leader:"
    discard edit(psoTab.leader, w = dp(48))
  row:
    if button("Add", w = dp(70)):
      var ld = ""
      var n = 0
      for c in psoTab.leader.toRunes:
        if n < 8: ld.add c.toUTF8
        inc n
      f.setTab(TabStop(pos: float32(psoTab.pos * unitPx), align: TabAlign(clamp(psoTab.kind, 0, ord(high(TabAlign)))),
                       leader: ld))
    if button("Delete", w = dp(70), enabled = psoTab.sel in 0 .. f.tabs.high):
      f.tabs.delete(psoTab.sel)
      psoTab.sel = -1
    if button("Clear All", w = dp(80), enabled = f.tabs.len > 0):
      f.tabs.setLen(0)
      psoTab.sel = -1
  ## (the style being changed: its name before, its name and paragraph settings in the dialog,
  ## the page shown)
var psoOk*: bool     ## (its OK pressed from outside: the tests)

proc startStyleOptions(name: string) =
  let d = cur()
  if d == nil: return
  let k = d.paraStyles.styleIndex(name)
  if k < 0:
    status = tr("Paragraph Style Options: pick a paragraph style")
    return
  psoDlg = (true, name, name, d.paraStyles[k].para, 0)

proc styleOptionsDialog() =
  if not psoDlg.open: return
  let d = cur()
  if d == nil or d.paraStyles.styleIndex(psoDlg.old) < 0:
    psoDlg.open = false
    return
  var ok = psoOk
  var cancel = false
  psoOk = false
  dialog(psoDlg.open, "Paragraph Style Options", 520):
    row([110, -1]):
      label "Style Name:"
      edit(psoDlg.name)
    discard tabStrip([tr("General"), tr("Keep Options"), tr("Justification"), tr("Drop Caps and Nested Styles"),
              tr("GREP Style"), tr("Tabs")], psoDlg.page, closable = false, addButton = false)
    case psoDlg.page
    of 0:
      row([110, -1]):
        label "Next Style:"
        var names = @[tr("[Same style]")]
        for st in d.paraStyles:
          if st.name != psoDlg.old: names.add st.name
        var k = max(0, names.find(psoDlg.f.nextStyle))
        if combo(names, k, w = dp(200)): psoDlg.f.nextStyle = if k <= 0: "" else: names[k]
      paragraph("Enter at the end of a paragraph in this style: the next one in the Next Style.",
                color = ui.theme.gray)
    of 1:
      row([180, 70, -1]):
        label "Keep with Next:"
        spin(psoDlg.f.keepWithNext, 0, 5, w = dp(62))
        label "lines"
      row:
        checkbox("Keep All Lines Together", psoDlg.f.keepTogether)
      row([180, 70, 60, 70, -1]):
        label "At start / end:"
        var s0 = max(1, psoDlg.f.keepStart)
        if spin(s0, 1, 50, w = dp(62)): psoDlg.f.keepStart = s0
        label ""
        var e0 = max(1, psoDlg.f.keepEnd)
        if spin(e0, 1, 50, w = dp(62)): psoDlg.f.keepEnd = e0
        label "lines"
      row([180, -1]):
        label "Start Paragraph:"
        var k = ord(psoDlg.f.startAt)
        var names: seq[string]
        for e in ParaStart: names.add tr($e)
        if combo(names, k, w = dp(160)): psoDlg.f.startAt = ParaStart(clamp(k, 0, ord(high(ParaStart))))
      row:
        checkbox("Span Columns", psoDlg.f.spanAll)
    of 2:
      for (cap, which) in [("Word Spacing:", 0), ("Letter Spacing:", 1), ("Glyph Scaling:", 2)]:
        row([120, 70, 70, 70, -1]):
          label cap
          var v = case which
                  of 0: psoDlg.f.wordSpacing
                  of 1: psoDlg.f.letterSpacing
                  else: psoDlg.f.glyphScaling
          let d0 = case which
                   of 0: [80'i16, 100, 133]
                   of 1: [0'i16, 0, 0]
                   else: [100'i16, 100, 100]
          if v == [0'i16, 0, 0]: v = d0
          var x = [int(v[0]), int(v[1]), int(v[2])]
          for q in 0 .. 2: spin(x[q], (if which == 1: -100 else: 0), 1000, w = dp(62))
          x[0] = min(x[0], x[1])
          x[2] = max(x[2], x[1])
          for q in 0 .. 2: v[q] = int16(x[q])
          case which
          of 0: psoDlg.f.wordSpacing = v
          of 1: psoDlg.f.letterSpacing = v
          else: psoDlg.f.glyphScaling = v
          label "%"
      row([120, -1]):
        label "Composer:"
        var c = ord(psoDlg.f.composer)
        var names: seq[string]
        for e in Composer: names.add tr($e)
        if combo(names, c, w = dp(220)): psoDlg.f.composer = Composer(clamp(c, 0, ord(high(Composer))))
    of 3:
      row([120, 70, 80, 70, -1]):
        label "Drop Cap Lines:"
        var dl = psoDlg.f.dropLines
        if spin(dl, 0, 20, w = dp(62)): psoDlg.f.dropLines = (if dl == 1: 0 else: dl)
        label "Characters:"
        var dc = max(1, psoDlg.f.dropChars)
        if spin(dc, 1, 20, w = dp(62)): psoDlg.f.dropChars = dc
        label ""
      nestedRows(d, psoDlg.f.nested)
      label("Nested Line Styles:")
      lineRows(d, psoDlg.f.lineStyles, psoDlg.f.repeatLast)
    of 5:
      tabRows(d, psoDlg.f)
    else:
      grepRows(d, psoDlg.f.grepStyles)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): cancel = true
  if ok:
    psoDlg.open = false
    let k = d.paraStyles.styleIndex(psoDlg.old)
    d.beginStep("Paragraph Style Options")
    d.touchLayers()
    let nm = psoDlg.name.strip
    var name = psoDlg.old
    if nm.len > 0 and nm != psoDlg.old and d.paraStyles.styleIndex(nm) < 0:
      d.renameStyle(true, psoDlg.old, nm)
      name = nm
    # (the next style named so in the other styles too)
    if name != psoDlg.old:
      for st in d.paraStyles.mitems:
        if st.para.nextStyle == psoDlg.old: st.para.nextStyle = name
    d.redefineStyle(true, name, d.paraStyles[k].char, psoDlg.f)
    d.endStep()
    inc d.ver
    d.markAll()
  elif cancel:
    psoDlg.open = false

# ---- Object Style Options ------------------------------------------------------------------------------------

var osoDlg: tuple[open: bool; old, name: string; f: ObjectStyleDef]

proc startObjectStyleOptions(name: string) =
  let d = cur()
  if d == nil: return
  let k = d.objectStyleIndex(name)
  if k < 0: return
  osoDlg = (true, name, name, d.objectStyles[k])

proc objectStyleOptionsDialog() =
  if not osoDlg.open: return
  let d = cur()
  if d == nil or d.objectStyleIndex(osoDlg.old) < 0:
    osoDlg.open = false
    return
  var ok, cancel = false
  dialog(osoDlg.open, "Object Style Options", 440):
    row([110, -1]):
      label "Style Name:"
      edit(osoDlg.name)
    label("Basic Attributes (what the style sets; the rest each layer keeps):", color = ui.theme.gray)
    checkbox("Fill", osoDlg.f.useFill)
    checkbox("Stroke", osoDlg.f.useStroke)
    checkbox("Effects, opacity and blending", osoDlg.f.useEffects)
    checkbox("Text Frame Options", osoDlg.f.useFrame)
    if osoDlg.f.useFrame:
      row([130, 90, 40, 90, -1]):
        label "Columns:"
        spin(osoDlg.f.columns, 1, 12, w = dp(80))
        label "gap"
        discard cur().lengthField(osoDlg.f.gutter, dp(80), 0, 4000)
        label unitShort()
      row([130, 60, 60, 60, 60, -1]):
        label "Inset:"
        for q in [0, 3, 2, 1]: discard cur().lengthField(osoDlg.f.inset[q], dp(54), 0, 4000)
        label unitShort()
      row([130, -1]):
        label "Vertical Justification:"
        var vj = ord(osoDlg.f.vjust)
        var vn: seq[string]
        for v in VertJust: vn.add tr($v)
        if combo(vn, vj, w = dp(120)): osoDlg.f.vjust = VertJust(clamp(vj, 0, ord(high(VertJust))))
      checkbox("Balance Columns", osoDlg.f.balance)
    checkbox("Paragraph Style", osoDlg.f.useParagraph)
    if osoDlg.f.useParagraph:
      var names = @[tr("[Basic Paragraph]")]
      for st in d.paraStyles: names.add st.name
      var k = max(0, names.find(osoDlg.f.paraStyle))
      row([130, -1]):
        label ""
        if combo(names, k, w = dp(200)): osoDlg.f.paraStyle = if k <= 0: "" else: names[k]
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): cancel = true
  if ok:
    osoDlg.open = false
    d.beginStep("Object Style Options")
    d.touchLayers()
    var name = osoDlg.old
    let nm = osoDlg.name.strip
    if nm.len > 0 and nm != name and d.objectStyleIndex(nm) < 0:
      d.renameObjectStyle(name, nm)
      name = nm
    var f = osoDlg.f
    f.name = name
    d.redefineObjectStyle(f)
    d.endStep()
    inc d.ver
    d.markAll()
  elif cancel:
    osoDlg.open = false

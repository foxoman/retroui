# Retro Atelier -- included by photo.nim
#
# Print, PDF and the screen, as the layout program has them (retroui/inks, photoseps, pdf,
# publish, textengine): Separations Preview and Overprint Preview, the Ink Manager, spot inks,
# the Attributes panel; an interactive PDF's buttons, form fields and page transitions; alt
# text (Object Export Options); Conditional Text, Track Changes and Notes; equations; Flex
# Layout; Paragraph Shading and Borders; EPUB and the web page.

var
  inkDlg = false
  spotDlg: tuple[open: bool; name: string; color: uint32; tint: int]
  transDlg: tuple[open: bool; style, dir: int; dur, adv: float; all: bool]
  altDlg: tuple[open: bool; alt: string; artifact: bool; tag: int]
  eqDlg: tuple[open: bool; src: string; size: int; bmp: Bitmap; key: string; err: string]
  flexDlg: tuple[open: bool; dir, justify, align: int; wrap, hugW, hugH: bool; gap, pad: int]
  shadeDlg: tuple[open: bool; shade, border: bool; shadeColor, borderColor: uint32; toText: bool;
                  offset, width: int]
  pubDlg: tuple[open: bool; kind: int; fixed: bool; pick: bool; path: string]
  condName = ""
  noteText = ""

const
  TransStyles = ["None", "Dissolve", "Fade", "Wipe", "Push", "Cover", "Uncover", "Split", "Blinds", "Box", "Glitter",
                 "Fly"]
  TransDirs = [("Left to Right", 0), ("Bottom to Top", 90), ("Right to Left", 180), ("Top to Bottom", 270)]
  ExportTags = ["From Its Kind", "Paragraph (P)", "Heading 1", "Heading 2", "Heading 3", "Figure", "Formula",
                "Table", "Artifact (left out)"]
  FieldKinds = ["None", "Text Field", "Check Box", "Radio Button", "Combo Box", "List Box", "Button", "Signature"]
  FieldKeys = ["", "text", "check", "radio", "combo", "list", "button", "signature"]
  ButtonActions = ["Go to Next Page", "Go to Previous Page", "Go to First Page", "Go to Last Page", "Go to Page",
                   "Go to Web Address", "Show Field", "Hide Field", "Print", "Clear Form", "Submit Form"]

# ---- Separations Preview and Overprint Preview ------------------------------------------------------

proc separationsBody(d: Doc) =
  ## Window > Output > Separations Preview: the plates, each shown or not; the ink under the
  ## pointer, each and all of it.
  if d == nil:
    label("No image open", color = ui.theme.gray)
    return
  var on = d.sepView.on
  if checkbox("Separations", on):
    d.sepView.on = on
    inc d.ver
  var black = d.sepView.black
  if checkbox("Show Single Plates in Black", black):
    d.sepView.black = black
    inc d.ver
  let ps = d.docPlates
  var amounts: seq[int]
  let inside = info.inside and info.x >= 0 and info.y >= 0
  if inside:
    amounts = d.inkAmountsAt(int(info.x), int(info.y), info.c, ps)
  for k, p in ps:
    pushId("plate" & $k)
    row([22, 18, -1, 48]):
      var shown = p.name notin d.sepView.hidden
      if checkbox("", shown):
        if shown: d.sepView.hidden.keepItIf(it != p.name)
        else: d.sepView.hidden.add p.name
        d.sepView.on = true
        inc d.ver
      let r = place(dp(14), dp(14))
      fill(r, colorOf(p.color))
      box(r, ui.theme.frame)
      label(if p.process >= 0: tr(p.name) else: p.name)
      label(if amounts.len > k: $((amounts[k] * 100 + 127) div 255) & "%" else: "")
    popId()
  row([-1, 48]):
    label("Total Ink", bold = true)
    label(if amounts.len > 0: $coverage(amounts) & "%" else: "")
  space(dp(4))
  row:
    if button("Ink Manager...", w = dp(120)): runCommand("Ink Manager...")
    if button("New Spot Ink...", w = dp(120)): runCommand("New Spot Ink...")

proc inkManagerDialog() =
  if not inkDlg: return
  let d = cur()
  if d == nil:
    inkDlg = false
    return
  var ok = false
  dialog(inkDlg, "Ink Manager", 460):
    label("The inks this document prints with:", bold = true)
    for k in 0 .. 3:
      row([24, -1]):
        let r = place(dp(14), dp(14))
        fill(r, colorOf(ProcessColors[k]))
        label(tr("Process ") & tr(ProcessNames[k]))
    var names: seq[string] = @["(its own plate)"]
    for i in 0 .. 3: names.add ProcessNames[i]
    for sp in d.spotInks: names.add sp.name
    for i, sp in d.spotInks:
      pushId("ink" & $i)
      row([24, 150, 110, -1]):
        let r = place(dp(14), dp(14))
        fill(r, colorOf(sp.color))
        label(sp.name)
        var proc0 = d.inkSettings.toProcess.find(sp.name) >= 0
        if checkbox("To Process", proc0, enabled = not d.inkSettings.allToProcess):
          if proc0: d.inkSettings.toProcess.add sp.name
          else: d.inkSettings.toProcess.keepItIf(it != sp.name)
          inc d.ver
        var cur0 = 0
        for (a, b) in d.inkSettings.aliases:
          if a == sp.name: cur0 = max(0, names.find(b))
        if combo(names, cur0, w = dp(150)):
          d.inkSettings.aliases.keepItIf(it.ink != sp.name)
          if cur0 > 0 and names[cur0] != sp.name: d.inkSettings.aliases.add (sp.name, names[cur0])
          inc d.ver
      popId()
    if d.spotInks.len == 0:
      paragraph("No spot inks yet: New Spot Ink (Separations Preview, the Swatches panel) makes one.",
                color = ui.theme.gray)
    var all = d.inkSettings.allToProcess
    if checkbox("All Spots to Process", all):
      d.inkSettings.allToProcess = all
      inc d.ver
    paragraph("An ink alias prints a spot ink on another ink's plate. Spots to process are printed in cyan, " &
              "magenta, yellow and black. What the PDF for a press and Separations Preview do.",
              color = ui.theme.gray)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
  if ok: inkDlg = false

proc newSpotDialog() =
  if not spotDlg.open: return
  let d = cur()
  if d == nil:
    spotDlg.open = false
    return
  var ok = false
  dialog(spotDlg.open, "New Spot Ink", 380):
    row([110, -1]):
      label "Name:"
      edit(spotDlg.name)
    row([110, -1]):
      label "Looks like:"
      colorWell(spotDlg.color, "spotcolor", dp(60))
    let ink = inkOf(spotDlg.color)
    label("Printed in process inks as C " & $(ink[0].int * 100 div 255) & " M " & $(ink[1].int * 100 div 255) &
          " Y " & $(ink[2].int * 100 div 255) & " K " & $(ink[3].int * 100 div 255), color = ui.theme.gray)
    row([110, 70, -1]):
      label "Tint:"
      discard spin(spotDlg.tint, 1, 100, w = dp(64))
      label "%"
    paragraph("The current shape is filled with it (a shape's fill: printed on a plate of its own).",
              color = ui.theme.gray)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80), enabled = spotDlg.name.strip.len > 0): ok = true
      if button("Cancel", w = dp(80)): spotDlg.open = false
  if ok:
    spotDlg.open = false
    let name = spotDlg.name.strip
    let k = d.spotInks.findSpot(name)
    if k < 0: d.spotInks.add spotInk(name, spotDlg.color)
    else: d.spotInks[k] = spotInk(name, spotDlg.color)
    let L = d.current
    if L.isShape:
      d.layersChange("Spot Ink"):
        var s = L.shape
        s.fill = solidPaint(spotDlg.color or 0xFF000000'u32)
        s.fill.spot = name
        s.fill.tint = if spotDlg.tint >= 100: 0 else: spotDlg.tint
        d.setShape(L, s)
    inc d.ver
    status = "Spot ink " & name & (if L.isShape: ": the shape is filled with it" else: "")

proc attributesBody(d: Doc) =
  ## Window > Output > Attributes: what the current layer is in print.
  if d == nil:
    label("No image open", color = ui.theme.gray)
    return
  let L = d.current
  var a = L.attrs
  var changed = false
  if checkbox("Overprint Fill", a.overprintFill): changed = true
  if checkbox("Overprint Stroke", a.overprintStroke): changed = true
  if checkbox("Nonprinting", a.nonprinting): changed = true
  if L.isShape:
    var names = @["Process inks"]
    for sp in d.spotInks: names.add sp.name
    var k = max(0, names.find(L.shape.fill.spot))
    row([90, -1]):
      label "Fill ink:"
      if combo(names, k, w = dp(150)):
        d.layersChange("Fill Ink"):
          var s = L.shape
          s.fill.spot = if k == 0: "" else: names[k]
          if k > 0 and k - 1 < d.spotInks.len: s.fill.color = d.spotInks[k - 1].color
          d.setShape(L, s)
  if changed:
    d.layersChange("Attributes"): L.attrs = a
    inc d.ver
  paragraph("Overprint: its inks print over what is under it (View > Overprint Preview shows it). " &
            "Nonprinting: seen here, not printed or exported.", color = ui.theme.gray)

# ---- an interactive PDF: buttons and forms, page transitions -------------------------------------------

proc buttonsBody(d: Doc) =
  ## Window > Interactive > Buttons and Forms: the current layer made a form field or a button
  ## (an interactive PDF: File > Save As > PDF, Interactive).
  if d == nil:
    label("No image open", color = ui.theme.gray)
    return
  let L = d.current
  var f = L.attrs.field
  var k = max(0, FieldKeys.find(f.kind))
  var changed = false
  row([80, -1]):
    label "Type:"
    if combo(FieldKinds, k, w = dp(150)):
      f.kind = FieldKeys[k]
      if f.name.len == 0 and k > 0: f.name = L.name.replace(" ", "_")
      changed = true
  if k > 0:
    row([80, -1]):
      label "Name:"
      if edit(f.name): changed = true
    row([80, -1]):
      label "Description:"
      if edit(f.tooltip): changed = true
    case f.kind
    of "text":
      if checkbox("Multiline", f.multiline): changed = true
      if checkbox("Password", f.password): changed = true
      row([80, -1]):
        label "Value:"
        if edit(f.value): changed = true
    of "check", "radio":
      var on = f.value == "on"
      if checkbox("Selected by Default", on):
        f.value = if on: "on" else: ""
        changed = true
      if f.kind == "radio":
        row([80, -1]):
          label "Value:"
          if edit(f.exportValue): changed = true
    of "combo", "list":
      var items = f.choices.join("\n")
      label "Choices (one a line):"
      if editArea(items, lines = 4):
        f.choices = @[]
        for s in items.splitLines:
          if s.strip.len > 0: f.choices.add s.strip
        changed = true
    of "button":
      row([80, -1]):
        label "Caption:"
        if edit(f.caption): changed = true
      var act = 0
      let low = f.action.toLowerAscii
      act = if low == "next" or low == "": 0 elif low == "prev": 1 elif low == "first": 2 elif low == "last": 3
            elif low.startsWith("page:"): 4 elif low.startsWith("show:"): 6 elif low.startsWith("hide:"): 7
            elif low == "print": 8 elif low == "reset": 9 elif low.startsWith("submit:"): 10 else: 5
      row([80, -1]):
        label "Action:"
        if combo(ButtonActions, act, w = dp(170)):
          f.action = case act
                     of 0: "next"
                     of 1: "prev"
                     of 2: "first"
                     of 3: "last"
                     of 4: "page:1"
                     of 5: "https://"
                     of 6: "show:"
                     of 7: "hide:"
                     of 8: "print"
                     of 9: "reset"
                     else: "submit:https://"
          changed = true
      if act in {4, 5, 6, 7, 10}:
        var arg = if act == 5: f.action else: f.action[f.action.find(':') + 1 .. ^1]
        row([80, -1]):
          label(case act
                of 4: "Page:"
                of 5: "Address:"
                of 10: "Address:"
                else: "Field:")
          if edit(arg):
            f.action = case act
                       of 4: "page:" & arg
                       of 5: arg
                       of 6: "show:" & arg
                       of 7: "hide:" & arg
                       else: "submit:" & arg
            changed = true
    else: discard
    if checkbox("Required", f.required): changed = true
    if checkbox("Read Only", f.readOnly): changed = true
  if changed:
    d.layersChange("Buttons and Forms"): L.attrs.field = f
  paragraph("The layer is drawn as it is; the field or button goes over it in the PDF.", color = ui.theme.gray)

proc transitionsDialog() =
  if not transDlg.open: return
  let d = cur()
  if d == nil:
    transDlg.open = false
    return
  var ok = false
  dialog(transDlg.open, "Page Transitions", 380):
    row([110, -1]):
      label "Transition:"
      combo(TransStyles, transDlg.style, w = dp(150))
    row([110, -1]):
      label "Direction:"
      var names: seq[string]
      for (n, _) in TransDirs: names.add n
      combo(names, transDlg.dir, w = dp(150))
    row([110, 80, -1]):
      label "Speed:"
      numberEdit(transDlg.dur, decimals = 1, w = dp(64), lo = 0.1, hi = 10)
      label "seconds"
    row([110, 80, -1]):
      label "Next page after:"
      numberEdit(transDlg.adv, decimals = 0, w = dp(64), lo = 0, hi = 600)
      label "seconds (0: a click)"
    if curBook() != nil: checkbox("Apply to All Pages", transDlg.all)
    paragraph("How the page comes when the PDF is shown full screen (a presentation).", color = ui.theme.gray)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): transDlg.open = false
  if ok:
    transDlg.open = false
    let st = if transDlg.style == 0: "" else: TransStyles[transDlg.style]
    let t = (style: st, duration: transDlg.dur, direction: TransDirs[clamp(transDlg.dir, 0, TransDirs.high)][1],
             advance: transDlg.adv)
    let bw = curBook()
    if transDlg.all and bw != nil:
      for i in 0 ..< bw.book.pages.len:
        let pd = bw.book.doc(i)
        pd.transition = t
        pd.modified = true
    else:
      d.transition = t
      d.modified = true
    status = "Page transition: " & (if t[0].len == 0: "none" else: t[0])

proc exportOptionsDialog() =
  ## Object Export Options: the alt text and how readers take the current layer.
  if not altDlg.open: return
  let d = cur()
  if d == nil:
    altDlg.open = false
    return
  var ok = false
  dialog(altDlg.open, "Object Export Options", 420):
    label("Alt Text (what it shows, for screen readers):", bold = true)
    editArea(altDlg.alt, lines = 3)
    row([110, -1]):
      label "Tag:"
      combo(ExportTags, altDlg.tag, w = dp(180))
    checkbox("A decoration (readers leave it out)", altDlg.artifact)
    paragraph("Used by a tagged PDF (File > Save As > PDF, Create Tagged PDF), EPUB and the web page.",
              color = ui.theme.gray)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): altDlg.open = false
  if ok:
    altDlg.open = false
    let L = d.current
    d.layersChange("Object Export Options"):
      L.attrs.alt = altDlg.alt.strip
      L.attrs.artifact = altDlg.artifact or altDlg.tag == ExportTags.high
      L.attrs.tag = case altDlg.tag
                    of 1: "P"
                    of 2: "H1"
                    of 3: "H2"
                    of 4: "H3"
                    of 5: "Figure"
                    of 6: "Formula"
                    of 7: "Table"
                    else: ""

# ---- Conditional Text, Track Changes, Notes ---------------------------------------------------------------

proc storyLayer(d: Doc): Layer =
  ## (the type layer being typed in, else the current one if it is type)
  if te.on and te.layer != nil: return te.layer
  if d != nil and d.current.isText: return d.current
  nil

proc storyRange(L: Layer): (int, int) =
  ## (the characters selected while typing; else all of them)
  if te.on and te.layer == L:
    let (a, b) = selRange()
    if b > a: return (a, b)
  (0, L.text.runeLen)

proc conditionsBody(d: Doc) =
  ## Window > Type & Tables > Conditional Text: the document's conditions, shown or hidden,
  ## put on the text selected.
  if d == nil:
    label("No image open", color = ui.theme.gray)
    return
  for i, c in d.conditions.mpairs:
    pushId("cond" & $i)
    row([24, 18, -1, 70]):
      var v = c.visible
      if checkbox("", v):
        c.visible = v
        inc d.ver
        d.markAll()
        for L in d.layers:
          if L.isText: d.drawText(L)
      let r = place(dp(14), dp(14))
      fill(r, colorOf(c.color))
      label(c.name)
      let L = d.storyLayer
      if button("Apply", w = dp(64), enabled = L != nil):
        let (a, b) = L.storyRange
        let name = c.name
        d.layersChange("Apply Condition"):
          var t = L.text
          t.applyCondition(a, b, name)
          d.setText(L, t)
    popId()
  row([-1, 70]):
    edit(condName)
    if button("New", w = dp(64), enabled = condName.strip.len > 0):
      let palette = [0xFFE74C3C'u32, 0xFF3498DB'u32, 0xFF2ECC71'u32, 0xFFF39C12'u32, 0xFF9B59B6'u32]
      d.conditions.add TextCondition(name: condName.strip, color: palette[d.conditions.len mod palette.len],
                                     visible: true)
      condName = ""
  let L = d.storyLayer
  if L != nil:
    if button("Unconditional", w = dp(120)):
      let (a, b) = L.storyRange
      d.layersChange("Remove Conditions"):
        var t = L.text
        t.restyle(a, b, proc (st: var CharStyle) = st.condition = "")
        d.setText(L, t)
  paragraph("Text under a hidden condition is left out as the document shows, prints and exports -- " &
            "under several, only when all of them are hidden.", color = ui.theme.gray)

proc reviewBody(d: Doc) =
  ## Window > Type & Tables > Track Changes and Notes: the story's changes, accepted or
  ## rejected; its notes.
  if d == nil:
    label("No image open", color = ui.theme.gray)
    return
  let L = d.storyLayer
  if L == nil:
    label("Pick a type layer (or type in one).", color = ui.theme.gray)
    return
  var track = L.text.track
  if checkbox("Track Changes in This Story", track):
    d.layersChange(if track: "Track Changes" else: "Stop Tracking Changes"):
      var t = L.text
      t.track = track
      L.text = t
  row([90, -1]):
    label "Who I am:"
    if reviewer.len == 0: reviewer = whoAmI()
    edit(reviewer)
  let changes = L.text.changesOf
  label(tr("Changes:") & " " & $changes.len, bold = true)
  for i, c in changes:
    if i >= 30: break
    pushId("chg" & $i)
    row([-1, 30, 30]):
      label((if c.added: "+ " else: "- ") & c.text.replace("\n", " ").strip & "  (" & c.who & ")",
            color = if c.added: color(0, 96, 208) else: color(208, 32, 32))
      if toolButton("✓", "Accept"):
        d.layersChange("Accept Change"):
          var t = L.text
          t.acceptChanges(c.a, c.b)
          d.setText(L, t)
      if toolButton("✗", "Reject"):
        d.layersChange("Reject Change"):
          var t = L.text
          t.rejectChanges(c.a, c.b)
          d.setText(L, t)
    popId()
  row:
    if button("Accept All", w = dp(90), enabled = changes.len > 0): runCommand("Accept All Changes")
    if button("Reject All", w = dp(90), enabled = changes.len > 0): runCommand("Reject All Changes")
  space(dp(6))
  let memos = L.text.memosOf
  label(tr("Notes:") & " " & $memos.len, bold = true)
  for i, m in memos:
    pushId("memo" & $i)
    row([-1, 30]):
      paragraph(m.who & (if m.at.len > 0: ", " & m.at else: "") & ": " & m.text)
      if toolButton("✗", "Delete Note"):
        d.layersChange("Delete Note"):
          var t = L.text
          t.removeMemo(m.a, m.b)
          d.setText(L, t)
    popId()
  editArea(noteText, lines = 2)
  if button("New Note", w = dp(100), enabled = noteText.strip.len > 0): runCommand("New Note")

# ---- equations -------------------------------------------------------------------------------------------

proc equationDialog() =
  ## Type > Insert Equation: math written as TeX writes it, set as a shape layer.
  if not eqDlg.open: return
  let d = cur()
  if d == nil:
    eqDlg.open = false
    return
  var ok = false
  dialog(eqDlg.open, "Insert Equation", 520):
    label("The equation, as TeX writes it:", bold = true)
    edit(eqDlg.src)
    row([110, 80, -1]):
      label "Size:"
      discard spin(eqDlg.size, 6, 400, w = dp(64))
      label "pixels"
    let key = eqDlg.src & "|" & $eqDlg.size
    if key != eqDlg.key:
      eqDlg.key = key
      let m = setMath(eqDlg.src, 40)
      eqDlg.err = m.error
      let w = max(4, int(ceil(m.w)))
      let h = max(4, int(ceil(m.h)))
      let s = ShapeData(fill: solidPaint(0xFF000000'u32))
      var pd = newDoc(w, h, 0xFFFFFFFF'u32)
      var sh = s
      for poly in m.mathPolys:
        var sp = SubPath(closed: true, joined: sh.path.subs.len > 0)
        for v in poly: sp.pts.add PathPoint(p: (v[0].float, v[1].float), inH: (v[0].float, v[1].float),
                                            outH: (v[0].float, v[1].float))
        sh.path.subs.add sp
      discard pd.addShapeLayer(sh)
      pd.markAll()
      pd.updateComposite()
      eqDlg.bmp = newBitmap(w, h)
      eqDlg.bmp.px = pd.compCopy
      eqDlg.bmp.changed()
    let r = place(dp(480), dp(110))
    fill(r, color(255, 255, 255))
    box(r, ui.theme.frame)
    if eqDlg.bmp != nil: drawFit(inset(r, dp(4)), eqDlg.bmp)
    if eqDlg.err.len > 0: label(eqDlg.err, color = color(170, 0, 0))
    paragraph("\\frac{a}{b}  x^2  y_1  \\sqrt{x}  \\sum_{i=1}^{n}  \\int_0^1  \\alpha \\pi  \\le \\pm \\infty  " &
              "\\left( ... \\right)  \\text{words}", color = ui.theme.gray)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80), enabled = eqDlg.src.strip.len > 0): ok = true
      if button("Cancel", w = dp(80)): eqDlg.open = false
  if ok:
    eqDlg.open = false
    let m = setMath(eqDlg.src, eqDlg.size.float)
    let ox = d.w.float / 2 - m.w / 2
    let oy = d.h.float / 2 - m.h / 2
    var sh = ShapeData(fill: solidPaint(fg or 0xFF000000'u32), kind: "Equation")
    for poly in m.mathPolys(ox, oy):
      var sp = SubPath(closed: true, joined: sh.path.subs.len > 0)
      for v in poly: sp.pts.add PathPoint(p: (v[0].float, v[1].float), inH: (v[0].float, v[1].float),
                                          outH: (v[0].float, v[1].float))
      sh.path.subs.add sp
    d.layersChange("Insert Equation"):
      let L = d.addShapeLayer(sh, "Equation")
      L.attrs.tag = "Formula"
      L.attrs.alt = eqDlg.src
      d.cur = d.layers.find(L)
    d.markAll()

# ---- Flex Layout, Paragraph Shading and Borders --------------------------------------------------------

proc flexDialog() =
  if not flexDlg.open: return
  let d = cur()
  if d == nil:
    flexDlg.open = false
    return
  var ok = false
  dialog(flexDlg.open, "Flex Layout", 420):
    row([110, -1]):
      label "Direction:"
      combo(["Row", "Column", "Row Reverse", "Column Reverse"], flexDlg.dir, w = dp(160))
    row([110, -1]):
      label "Justify:"
      combo(["Start", "Center", "End", "Space Between", "Space Around", "Space Evenly"], flexDlg.justify,
            w = dp(160))
    row([110, -1]):
      label "Align:"
      combo(["Start", "Center", "End", "Stretch"], flexDlg.align, w = dp(160))
    row([110, 80, -1]):
      label "Gap:"
      discard d.lengthField(flexDlg.gap, dp(64), 0, 4000)
      label unitShort()
    row([110, 80, -1]):
      label "Padding:"
      discard d.lengthField(flexDlg.pad, dp(64), 0, 4000)
      label unitShort()
    checkbox("Wrap onto more lines", flexDlg.wrap)
    checkbox("Hug Width (as wide as its frames)", flexDlg.hugW)
    checkbox("Hug Height (as tall as its frames)", flexDlg.hugH)
    paragraph("The layers picked (or the group) become a Flex Layout: change one -- a text frame that grows with " &
              "its text -- and the others move.", color = ui.theme.gray)
    row:
      if button("Release", w = dp(80), enabled = d.current.group and d.current.flexOf.on):
        let g = d.current
        d.layersChange("Release Flex Layout"): g.setFlex(FlexBox(), 0, 0, on = false)
        flexDlg.open = false
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): flexDlg.open = false
  if ok:
    flexDlg.open = false
    var g = d.current
    d.layersChange("Flex Layout"):
      if not g.group:
        var idxs: seq[int]
        for i, L in d.layers:
          if (L.picked or i == d.cur) and not L.background and not L.group: idxs.add i
        if idxs.len >= 1: g = d.groupLayers(idxs, "Flex Layout")
      if g != nil and g.group:
        let gi = d.layers.find(g)
        var x0, y0 = 1e9
        var x1, y1 = -1e9
        for j in d.flexChildren(gi):
          let r = d.layerBox(d.layers[j])
          if r.w <= 0: continue
          x0 = min(x0, r.x.float); y0 = min(y0, r.y.float)
          x1 = max(x1, float(r.x + r.w)); y1 = max(y1, float(r.y + r.h))
        if x1 > x0:
          let p = flexDlg.pad.float
          let box = FlexBox(dir: FlexDir(flexDlg.dir), justify: FlexJustify(flexDlg.justify),
                            align: FlexAlign(flexDlg.align), wrap: flexDlg.wrap, gap: flexDlg.gap.float,
                            padding: [p, p, p, p], w: x1 - x0 + 2 * p, h: y1 - y0 + 2 * p,
                            hugW: flexDlg.hugW, hugH: flexDlg.hugH)
          g.setFlex(box, x0 - p, y0 - p)
          discard d.arrangeFlex(gi)
          d.cur = gi
    d.markAll()

proc flexAfterStep(d: Doc) =
  ## (as a step ends: the document's Flex Layouts kept -- one of their frames changed, the
  ## others moved -- in that step, undone with it)
  for gi in 0 ..< d.layers.len:
    if d.layers[gi].group and d.layers[gi].flexOf.on: discard d.arrangeFlex(gi)

proc shadeDialog() =
  if not shadeDlg.open: return
  let d = cur()
  let L = if d != nil: d.storyLayer else: nil
  if L == nil:
    shadeDlg.open = false
    return
  var ok = false
  dialog(shadeDlg.open, "Paragraph Shading and Borders", 420):
    group("Shading"):
      row:
        checkbox("Shading", shadeDlg.shade)
        colorWell(shadeDlg.shadeColor, "parashade", dp(50))
      checkbox("As wide as the text (else the column)", shadeDlg.toText)
    group("Border"):
      row:
        checkbox("Border", shadeDlg.border)
        colorWell(shadeDlg.borderColor, "paraborder", dp(50))
      row([110, 80, -1]):
        label "Weight:"
        discard d.lengthField(shadeDlg.width, dp(64), 1, 100)
        label unitShort()
    row([110, 80, -1]):
      label "Offset:"
      discard d.lengthField(shadeDlg.offset, dp(64), 0, 400)
      label unitShort()
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): shadeDlg.open = false
  if ok:
    shadeDlg.open = false
    let o = shadeDlg.offset.float32
    let w = shadeDlg.width.float32
    d.layersChange("Paragraph Shading and Borders"):
      var t = L.text
      var p = t.para
      p.shading = if shadeDlg.shade: shadeDlg.shadeColor or 0xFF000000'u32 else: 0
      p.shadeOffsets = [o, o, o, o]
      p.shadeToText = shadeDlg.toText
      p.border = if shadeDlg.border: shadeDlg.borderColor or 0xFF000000'u32 else: 0
      p.borderWidths = [w, w, w, w]
      p.borderOffsets = [o, o, o, o]
      t.para = p
      for f in t.paraFmts.mitems:
        f.shading = p.shading; f.shadeOffsets = p.shadeOffsets; f.shadeToText = p.shadeToText
        f.border = p.border; f.borderWidths = p.borderWidths; f.borderOffsets = p.borderOffsets
      d.setText(L, t)
    d.markAll()

# ---- EPUB and the web page ----------------------------------------------------------------------------------

proc publishDialog() =
  if pubDlg.open:
    var go = false
    dialog(pubDlg.open, if pubDlg.kind == 0: "Export EPUB" else: "Publish as Web Page", 420):
      if pubDlg.kind == 0:
        var k = if pubDlg.fixed: 1 else: 0
        if radio("Reflowable (any screen: the text flows, its pictures between)", k, 0) or
           radio("Fixed Layout (each page as it is laid out)", k, 1):
          pubDlg.fixed = k == 1
      else:
        paragraph("A web page of the pages -- each as it is laid out on a computer, its text and pictures one " &
                  "under another on a phone -- in a folder with its pictures: put the folder on any web host.",
                  color = ui.theme.gray)
      paragraph("The text stays text, headings headings; the pictures say what they show (Object Export Options).",
                color = ui.theme.gray)
      row:
        spring()
        if button("Save...", isDefault = true, w = dp(90)): go = true
        if button("Cancel", w = dp(80)): pubDlg.open = false
    if go:
      pubDlg.open = false
      pubDlg.pick = true
      let d = cur()
      let base = if d != nil and d.path.len > 0: d.path.parentDir else: picturesDir()
      let nm = if curBook() != nil: curBook().book.name elif d != nil: d.name else: "Untitled"
      pubDlg.path = if pubDlg.kind == 0: base / (nm & ".epub") else: base / (nm & " Web")
  if pubDlg.pick:
    let mode = if pubDlg.kind == 0: fmSave else: fmFolder
    if filePicker(pubDlg.pick, pubDlg.path, mode, (if pubDlg.kind == 0: @["*.epub"] else: @[]),
                  if pubDlg.kind == 0: "Export EPUB" else: "Publish as Web Page"):
      var p = pubDlg.path
      try:
        beginBusy(if pubDlg.kind == 0: "Export EPUB" else: "Publish as Web Page")
        try:
          let bw = curBook()
          var pd = if bw != nil: pubDocOf(bw.book)
                   else: (if cur() != nil: pubDocOf(@[cur()]) else: PubDoc())
          if pd.lang.len == 0: pd.lang = if prefs.language == 1: "ar" else: "en"
          if pubDlg.kind == 0:
            if p.splitFile.ext.toLowerAscii != ".epub": p.add ".epub"
            writeFile(p, epubOf(pd, pubDlg.fixed))
            rememberFile(p)
            status = "Saved " & p.extractFilename & " (" & $pd.pages.len & " pages)"
          else:
            publishSite(pd, p)
            status = "Published " & $pd.pages.len & (if pd.pages.len == 1: " page in " else: " pages in ") & p &
                     " (index.html)"
        finally: endBusy()
      except CatchableError:
        status = "Could not save: " & getCurrentExceptionMsg()

# ---- the commands ---------------------------------------------------------------------------------------

proc outputCommand(name: string): bool =
  ## (the commands of this file: true when it was one)
  let d = cur()
  result = true
  case name
  of "Separations Preview":
    if d != nil:
      d.sepView.on = not d.sepView.on
      if d.sepView.on:
        d.overprintView = false
        showPanel("separations")
      inc d.ver
  of "Overprint Preview":
    if d != nil:
      d.overprintView = not d.overprintView
      if d.overprintView: d.sepView.on = false
      inc d.ver
  of "Ink Manager...":
    if d != nil: inkDlg = true
  of "New Spot Ink...":
    if d != nil:
      spotDlg = (true, "Spot " & $(d.spotInks.len + 1), fg or 0xFF000000'u32, 100)
  of "Attributes": togglePanel("attributes")
  of "Text Wrap Panel": togglePanel("textwrap")
  of "Separations Preview Panel": togglePanel("separations")
  of "Buttons and Forms": togglePanel("buttons")
  of "Conditional Text": togglePanel("conditions")
  of "Track Changes and Notes": togglePanel("review")
  of "Page Transitions...":
    if d != nil:
      let st = max(0, TransStyles.find(d.transition.style))
      var di = 0
      for k, (_, v) in TransDirs:
        if v == d.transition.direction: di = k
      transDlg = (true, st, di, (if d.transition.duration > 0: d.transition.duration else: 1.0),
                  d.transition.advance, false)
  of "Object Export Options...":
    if d != nil:
      let L = d.current
      let tag = case L.attrs.tag
                of "P": 1
                of "H1": 2
                of "H2": 3
                of "H3": 4
                of "Figure": 5
                of "Formula": 6
                of "Table": 7
                else: 0
      altDlg = (true, L.attrs.alt, L.attrs.artifact, tag)
  of "Track Changes":
    let L = d.storyLayer
    if L != nil:
      d.layersChange("Track Changes"):
        var t = L.text
        t.track = not t.track
        L.text = t
      status = if L.text.track: "Track Changes: on (what is typed and deleted is kept as changes)"
               else: "Track Changes: off"
  of "Accept All Changes", "Reject All Changes":
    let L = d.storyLayer
    if L != nil:
      if te.on: commitType()
      d.layersChange(name.replace(" All", "")):
        var t = L.text
        if name.startsWith("Accept"): t.acceptChanges() else: t.rejectChanges()
        d.setText(L, t)
  of "New Note":
    let L = d.storyLayer
    if L == nil:
      status = "Pick a type layer (or select words in one) first"
    else:
      var (a, b) = L.storyRange
      if b - a == L.text.runeLen and not te.on: (a, b) = (0, min(1, L.text.runeLen))
      var txt = noteText.strip
      if txt.len == 0: txt = "Note"
      let who = trackWho()
      d.layersChange("New Note"):
        var t = L.text
        t.addMemo(a, b, who, txt)
        L.text = t
      noteText = ""
      showPanel("review")
  of "Insert Equation...":
    if d != nil:
      eqDlg.open = true
      if eqDlg.src.len == 0: eqDlg.src = "x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}"
      if eqDlg.size == 0: eqDlg.size = max(24, min(d.w, d.h) div 12)
      eqDlg.key = ""
  of "Flex Layout...":
    if d != nil:
      let f = d.current.flexOf
      if f.on:
        flexDlg = (true, ord(f.box.dir), ord(f.box.justify), ord(f.box.align), f.box.wrap, f.box.hugW, f.box.hugH,
                   int(f.box.gap), int(f.box.padding[0]))
      else:
        flexDlg = (true, 0, 0, 1, false, true, true, 16, 16)
  of "Paragraph Shading and Borders...":
    let L = d.storyLayer
    if L == nil: status = "Pick a type layer first"
    else:
      let p = L.text.para
      shadeDlg = (true, p.shading != 0, p.border != 0, (if p.shading != 0: p.shading else: 0xFFFFF2B3'u32),
                  (if p.border != 0: p.border else: 0xFF333333'u32), p.shadeToText,
                  int(p.shadeOffsets[0]), max(1, int(p.borderWidths[0])))
  of "Export EPUB...": pubDlg = (true, 0, false, false, "")
  of "Publish as Web Page...": pubDlg = (true, 1, false, false, "")
  else: result = false

proc outputDialogs() =
  inkManagerDialog()
  newSpotDialog()
  transitionsDialog()
  exportOptionsDialog()
  equationDialog()
  flexDialog()
  shadeDialog()
  publishDialog()

# (included by photo.nim) Footnotes and endnotes (retroui/textengine's notes): Type >
# Insert Footnote puts a reference at the caret -- its number shown there, the note at the
# foot of the box -- and opens Footnotes, where each note's text is written and the numbering
# and the look are set (Footnotes or Endnotes, 1 2 3 or ١ ٢ ٣ or i ii..., the first number,
# what is round the reference, the notes' size, the line above them), live: Cancel puts it
# back.

var
  fnDlg: tuple[open: bool; layer: Layer; focus: int]
  fnPending = false              ## (its step is open: OK ends it, anything else lets it go)
  fnApplied = ""                 ## (the notes as they were last drawn)

proc notesLayer(): Layer =
  ## (the text the notes are of: the one being typed, else the current layer)
  if te.on: return te.layer
  let d = cur()
  if d != nil and d.current != nil and d.current.isText: d.current else: nil

proc startFootnotes(focus = -1) =
  let d = cur()
  let L = notesLayer()
  if d == nil or L == nil:
    status = "Footnotes: click in a text with the Type tool (or pick a type layer) first."
    return
  if te.on: commitType()
  d.beginStep("Footnotes")
  d.touchLayers()
  d.touch(L, d.bounds)
  fnDlg = (true, L, focus)
  fnPending = true
  fnApplied = $L.text.toJson

proc insertNoteCmd(endnote: bool) =
  ## Type > Insert Footnote (Insert Endnote): a reference at the caret (at the text's end when
  ## it is not being typed in), its note written in the Footnotes box.
  let d = cur()
  let L = notesLayer()
  if d == nil or L == nil or L.text.path.len > 0:
    status = "Insert Footnote: click in a text with the Type tool where its number goes."
    return
  var id = 0
  if te.on:
    let at = te.caret
    editText(proc (t: var TextData) =
      if t.notes.len == 0: t.noteOpts.kind = (if endnote: nkEndnotes else: nkFootnotes)
      id = t.insertNote(at))
    te.caret = at + 1
    te.anchor = te.caret
  else:
    d.beginStep(if endnote: "Insert Endnote" else: "Insert Footnote")
    d.touchLayers()
    d.touch(L, d.bounds)
    var t = L.text
    if t.notes.len == 0: t.noteOpts.kind = (if endnote: nkEndnotes else: nkFootnotes)
    id = t.insertNote(t.runeLen)
    d.setText(L, t)
    d.endStep()
  if id == 0:
    status = "Insert Footnote: this text has as many notes as it can"
    return
  var k = 0
  for i, n in L.text.notes:
    if n.id == id: k = i
  startFootnotes(k)

proc notesCommand(name: string): bool =
  ## (Type > Insert Footnote, Insert Endnote, Footnotes; true: done here)
  result = true
  case name
  of "Insert Footnote": insertNoteCmd(false)
  of "Insert Endnote": insertNoteCmd(true)
  of "Footnotes...": startFootnotes()
  else: result = false

proc footnotesDialog() =
  if not fnDlg.open:
    if fnPending:
      # (closed from outside the box: as Cancel)
      fnPending = false
      let d = cur()
      if d != nil and d.stepOpen:
        d.cancelStep()
        d.markAll()
    return
  let d = cur()
  let L = fnDlg.layer
  if d == nil or L == nil or L notin d.layers or not L.isText:
    fnDlg.open = false
    fnPending = false
    if d != nil and d.stepOpen: d.endStep()
    return
  var t = L.text
  var ok, cancel = false
  dialog(fnDlg.open, "Footnotes", 520):
    if t.notes.len == 0:
      label("No notes in this text yet: Type > Insert Footnote puts one at the caret.", color = ui.theme.gray)
    else:
      let lh = min(dp(260), max(dp(80), t.notes.len * (lineHeight() * 3 + dp(10))))
      beginScroll(lh, "fnlist")
      var gone = -1
      for i in 0 ..< t.notes.len:
        row([44, -1, 28]):
          label(t.noteNumber(t.notes[i].id) & ".", bold = i == fnDlg.focus)
          editArea(t.notes[i].text, lines = 2)
          if toolButton(glyphIcon(pxTrash, ui.theme.text, dp(14)), "Delete the note (and its number in the text)"):
            gone = i
      endScroll()
      if gone >= 0:
        let mark = noteMark(t.notes[gone].id)
        for sp in t.spans.mitems: sp.text = sp.text.replace(mark, "")
        t.tidyNotes()
    var o = t.noteOpts
    group("Numbering"):
      row:
        var k = ord(o.kind)
        if radio("Footnotes", k, 0): o.kind = nkFootnotes
        if radio("Endnotes", k, 1): o.kind = nkEndnotes
      row([110, -1]):
        label "Style:"
        var ns = ord(o.numbers)
        var names: seq[string]
        for s in NumberStyle: names.add $s
        if combo(names, ns, w = dp(150)): o.numbers = NumberStyle(ns)
      row([110, -1]):
        label "Start at:"
        var st = max(1, o.start)
        if spin(st, 1, 100_000, w = dp(70)): o.start = st
      row([110, 60, 60, -1]):
        label "Reference:"
        edit(o.prefix, w = dp(50))
        edit(o.suffix, w = dp(50))
        label("before and after the number", color = ui.theme.gray)
      row([110, 60, -1]):
        label "After the number:"
        var sep = if o.separator.len > 0: o.separator else: ". "
        if edit(sep, w = dp(50)): o.separator = sep
        label("in the note", color = ui.theme.gray)
    group("Layout"):
      row([150, -1, 50]):
        label "Notes' size:"
        var sc = int(round((if o.scale > 0: o.scale else: 0.8) * 100))
        if slider(sc, 40, 120, ticks = 0): o.scale = sc.float32 / 100
        label $sc & "%"
      row([150, -1, 50]):
        label "Reference's size:"
        var rs = int(round((if o.refScale > 0: o.refScale else: 0.6) * 100))
        if slider(rs, 30, 100, ticks = 0): o.refScale = rs.float32 / 100
        label $rs & "%"
      row([150, -1, 50]):
        label "Space above the notes:"
        var g = int(round(o.gap))
        if spin(g, 0, 500, w = dp(60)): o.gap = g.float32
        label "px"
      if o.kind == nkFootnotes:
        row:
          var rule = not o.noRule
          if checkbox("A line above them", rule): o.noRule = not rule
          if not o.noRule:
            var rw = max(1, int(round(o.ruleWidth)))
            if spin(rw, 1, 20, w = dp(52)): o.ruleWidth = rw.float32
            label "px,"
            var rl = int(round((if o.ruleLength > 0: o.ruleLength else: 0.33) * 100))
            if spin(rl, 5, 100, w = dp(56)): o.ruleLength = rl.float32 / 100
            label "% wide"
            var c = if o.ruleColor != 0: o.ruleColor else: (if t.spans.len > 0: t.spans[0].style.color else: 0xFF000000'u32)
            if colorWell(c, "fnrule", dp(36)): o.ruleColor = c or 0xFF000000'u32
      else:
        row([150, -1]):
          label "Heading:"
          var h = t.noteHeading
          if edit(h): o.heading = h
    t.noteOpts = o
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): cancel = true
  let now = $t.toJson
  if now != fnApplied and not cancel:
    fnApplied = now
    d.setText(L, t)
  if cancel or (not fnDlg.open and not ok):
    fnDlg.open = false
    fnPending = false
    if d.stepOpen: d.cancelStep()
    d.markAll()
  elif ok:
    fnDlg.open = false
    fnPending = false
    if d.stepOpen: d.endStep()

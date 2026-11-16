# (included by photo.nim) Edit > Find/Change (retroui/textsearch): words or patterns (GREP)
# found in a text, the page or the whole book -- the next one selected where it is, changed
# one by one or all at once, each text keeping its styles -- and Type > Story Editor: a text's
# words in a plain box to write in, its styles kept for what did not change.

var
  fcDlg: tuple[open: bool; what, change: string; patterns, matchCase, wholeWord: bool; scope: int;
               note: string]
  seDlg: tuple[open: bool; layer: Layer; words, orig: string]

proc fcFind(d: Doc; L: Layer; start: int): textsearch.Match =
  ## (the next match in `L`'s text at or after character `start`)
  result = textsearch.Match(a: -1, b: -1)
  try:
    let p = patternOf(fcDlg.what, fcDlg.patterns, fcDlg.matchCase, fcDlg.wholeWord)
    var cps: seq[int]
    for r in L.text.plainText.toRunes: cps.add int(r)
    result = p.find(cps, start)
    fcDlg.note = ""
  except PatternError as e:
    fcDlg.note = tr("The pattern: ") & e.msg

proc textLayersOf(d: Doc): seq[Layer] =
  for L in d.layers:
    if L.isText and L.fromMaster == 0 and L.text.path.len == 0: result.add L

proc fcSelect(dw: DocWin; L: Layer; m: textsearch.Match) =
  ## (a match selected where it is: its text being typed in, the letters found selected)
  let d = dw.doc
  if te.on: commitType()
  d.cur = d.layers.find(L)
  selectTool(tType)                 # (first: a tool changed ends what is typed)
  startTypeEdit(dw, L, false, m.b)
  te.anchor = m.a
  te.caret = m.b

proc fcNext() =
  ## Find Next: from the caret (or the start), in this text, then the page's next texts, then
  ## the book's next pages; round to the start once.
  let dw = active
  if dw == nil or fcDlg.what.len == 0: return
  var d = dw.doc
  let bw = curBook()
  var L = if te.on: te.layer elif d.current != nil and d.current.isText: d.current else: nil
  var start = if te.on: max(te.caret, te.anchor) else: 0
  var layers = textLayersOf(d)
  var li = if L != nil: max(0, layers.find(L)) else: 0
  if L == nil: start = 0
  let pages = if bw != nil and fcDlg.scope == 2: bw.book.pages.len else: 1
  var page = if bw != nil: bw.page else: 0
  for round in 0 .. pages * 2 + 1:
    while li < layers.len:
      if fcDlg.scope == 0 and L != nil and layers[li] != L:
        inc li
        continue
      let m = fcFind(d, layers[li], start)
      if fcDlg.note.len > 0: return
      if m.a >= 0:
        fcSelect(active, layers[li], m)
        fcDlg.note = ""
        return
      inc li
      start = 0
    if fcDlg.scope == 2 and bw != nil:
      page = (page + 1) mod bw.book.pages.len
      bw.showPage(page)
      d = bw.dw.doc
    elif round > 0: break
    layers = textLayersOf(d)
    li = 0
    start = 0
  fcDlg.note = "Not found"

proc fcChangeOne() =
  ## Change: the selection, when it is what was found, changed; then the next found.
  if te.on and te.anchor != te.caret:
    let a = min(te.anchor, te.caret)
    let b = max(te.anchor, te.caret)
    let m = fcFind(te.dw.doc, te.layer, a)
    if m.a == a and m.b == b:
      var cps: seq[int]
      for r in te.layer.text.plainText.toRunes: cps.add int(r)
      let s = expand(fcDlg.change, m, cps)
      let st = te.layer.text.styleAt(a)
      editText(proc (t: var TextData) =
        t.deleteText(a, b)
        if s.len > 0: t.insertText(a, s, st))
      te.caret = a + s.toRunes.len
      te.anchor = te.caret
  fcNext()

proc fcChangeAll() =
  ## Change All: every place in the text, the page or the book; one undo step a page.
  let dw = active
  if dw == nil or fcDlg.what.len == 0: return
  if te.on: commitType()
  let bw = curBook()
  var total = 0
  proc onDoc(d: Doc; only: Layer) =
    var stepOpen = false
    for L in textLayersOf(d):
      if only != nil and L != only: continue
      var t = L.text
      var n = 0
      try: n = t.changeIn(fcDlg.what, fcDlg.change, fcDlg.patterns, fcDlg.matchCase, fcDlg.wholeWord)
      except PatternError as e:
        fcDlg.note = tr("The pattern: ") & e.msg
        return
      if n > 0:
        if not stepOpen:
          d.beginStep("Change All")
          d.touchLayers()
          stepOpen = true
        d.touch(L, d.bounds)
        d.setText(L, t)
        total += n
    if stepOpen: d.endStep()
  let d = dw.doc
  case fcDlg.scope
  of 0: onDoc(d, if d.current != nil and d.current.isText: d.current else: nil)
  of 1: onDoc(d, nil)
  else:
    if bw == nil: onDoc(d, nil)
    else:
      let here = bw.page
      for i in 0 ..< bw.book.pages.len:
        let pd = bw.book.doc(i)
        onDoc(pd, nil)
        if i != here: bw.book.park([here])
      d.markAll()
  if fcDlg.note.len == 0:
    fcDlg.note = if total == 0: "Not found" else: $total & (if total == 1: " change" else: " changes")

proc startFindChange() =
  fcDlg.open = true
  fcDlg.note = ""
  if te.on and te.anchor != te.caret and fcDlg.what.len == 0:
    fcDlg.what = te.layer.text.textSlice(min(te.anchor, te.caret), max(te.anchor, te.caret))

proc startStoryEditor() =
  let d = cur()
  let L = if te.on: te.layer elif d != nil and d.current != nil and d.current.isText: d.current else: nil
  if d == nil or L == nil:
    status = "Story Editor: pick a type layer (or click in a text) first."
    return
  if te.on: commitType()
  seDlg = (true, L, L.text.plainText, L.text.plainText)

proc findCommand(name: string): bool =
  result = true
  case name
  of "Find/Change...", "Find and Replace...": startFindChange()
  of "Story Editor...", "Edit in Story Editor": startStoryEditor()
  else: result = false

proc findDialogs() =
  if fcDlg.open:
    var next, one, all = false
    dialog(fcDlg.open, "Find/Change", 460):
      row([110, -1]):
        label "Find what:"
        edit(fcDlg.what)
      row([110, -1]):
        label "Change to:"
        edit(fcDlg.change)
      row:
        checkbox("Patterns (GREP)", fcDlg.patterns)
        checkbox("Match case", fcDlg.matchCase)
        checkbox("Whole word", fcDlg.wholeWord)
      row([110, -1]):
        label "Search:"
        combo(["This text", "This page", "The book"], fcDlg.scope, w = dp(140))
      if fcDlg.patterns:
        paragraph(tr("\\d a digit, \\w a letter, \\s a space, . anything, [abc] one of them, + more, * any, ") &
                  tr("? or not, (..) a group: $1 in the change."), color = ui.theme.gray)
      if fcDlg.note.len > 0: label(fcDlg.note, bold = true)
      row:
        if button("Find Next", isDefault = true, w = dp(96)): next = true
        if button("Change", w = dp(80)): one = true
        if button("Change All", w = dp(96)): all = true
        spring()
        if button("Done", w = dp(70)): fcDlg.open = false
    if next: fcNext()
    if one: fcChangeOne()
    if all: fcChangeAll()
  if seDlg.open:
    let d = cur()
    if d == nil or seDlg.layer notin d.layers:
      seDlg.open = false
      return
    var ok = false
    dialog(seDlg.open, "Story Editor: " & seDlg.layer.name, 640):
      editArea(seDlg.words, lines = 18)
      label($seDlg.words.toRunes.len & tr(" characters, ") & $seDlg.words.splitWhitespace.len & tr(" words"), color = ui.theme.gray)
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)): ok = true
        if button("Cancel", w = dp(80)): seDlg.open = false
    if ok:
      seDlg.open = false
      if seDlg.words != seDlg.orig:
        let L = seDlg.layer
        var t = L.text
        t.editPlain(seDlg.words)
        t.tidyNotes()
        d.beginStep("Story Editor")
        d.touchLayers()
        d.touch(L, d.bounds)
        d.setText(L, t)
        d.endStep()

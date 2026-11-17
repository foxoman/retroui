# (included by photo.nim) Edit > Find/Change (retroui/textsearch): words or patterns (GREP)
# found in a text, the page or the whole book -- the next one selected where it is, changed
# one by one or all at once, each text keeping its styles; a glyph in a font (Glyph), changed
# to another in a font of its own; frames by their formats (Object: fill, stroke, opacity,
# Object Style), changed to others; searches kept by name (Query, with the ones it comes
# with) -- and Type > Story Editor: a text's words in a plain box to write in, its styles kept
# for what did not change.

var
  fcDlg: tuple[open: bool; what, change: string; patterns, matchCase, wholeWord: bool; scope: int;
               note: string; mode: int; font, toFont: string; oq: ObjectQuery; oc: ObjectChange;
               queries: seq[SavedQuery]; loaded: bool; qi: int; naming: bool; qname: string]
  seDlg: tuple[open: bool; layer: Layer; words, orig: string]

const fcQueriesKey = "findchange.queries"

proc fcLoadQueries() =
  ## (the queries kept: the program's settings -- then the ones it comes with)
  if fcDlg.loaded: return
  fcDlg.loaded = true
  fcDlg.queries.setLen(0)
  let st = loadSettings(AppData)
  let raw = st.getOrDefault(fcQueriesKey, "")
  if raw.len > 0:
    try: fcDlg.queries = queriesFrom(parseJson(raw)) except CatchableError: discard
  for q in builtInQueries():
    var have = false
    for m in fcDlg.queries:
      if m.name == q.name: have = true
    if not have: fcDlg.queries.add q

proc fcSaveQueries() =
  var st = loadSettings(AppData)
  var mine: seq[SavedQuery]
  let built = builtInQueries()
  for q in fcDlg.queries:
    var isBuilt = false
    for b in built:
      if b == q: isBuilt = true
    if not isBuilt: mine.add q
  st[fcQueriesKey] = $queriesToJson(mine)
  discard saveSettings(AppData, st)

proc objectToJson(q: ObjectQuery; c: ObjectChange): JsonNode =
  %*{"kind": ord(q.kind), "byFill": q.byFill, "byStroke": q.byStroke, "byWidth": q.byWidth,
     "byOpacity": q.byOpacity, "fill": int64(q.fill), "stroke": int64(q.stroke), "width": q.strokeWidth,
     "opacity": q.opacity, "style": q.objectStyle, "name": q.name,
     "setFill": c.setFill, "setStroke": c.setStroke, "setWidth": c.setWidth, "setOpacity": c.setOpacity,
     "toFill": int64(c.fill), "toStroke": int64(c.stroke), "toWidth": c.strokeWidth, "toOpacity": c.opacity,
     "toStyle": c.objectStyle}

proc objectFrom(j: JsonNode): (ObjectQuery, ObjectChange) =
  if j == nil or j.kind != JObject: return
  template u(k: string): uint32 = uint32(j{k}.getBiggestInt(0) and 0xFFFFFFFF'i64)
  result[0] = ObjectQuery(kind: ObjectKind(clamp(j{"kind"}.getInt, 0, ord(high(ObjectKind)))),
                          byFill: j{"byFill"}.getBool, byStroke: j{"byStroke"}.getBool,
                          byWidth: j{"byWidth"}.getBool, byOpacity: j{"byOpacity"}.getBool,
                          fill: u("fill"), stroke: u("stroke"), strokeWidth: j{"width"}.getFloat,
                          opacity: j{"opacity"}.getInt(100), objectStyle: j{"style"}.getStr,
                          name: j{"name"}.getStr)
  result[1] = ObjectChange(setFill: j{"setFill"}.getBool, setStroke: j{"setStroke"}.getBool,
                           setWidth: j{"setWidth"}.getBool, setOpacity: j{"setOpacity"}.getBool,
                           fill: u("toFill"), stroke: u("toStroke"), strokeWidth: j{"toWidth"}.getFloat,
                           opacity: j{"toOpacity"}.getInt(100), objectStyle: j{"toStyle"}.getStr)

proc fcQueryNow(name: string): SavedQuery =
  ## (the search as the dialog has it, kept as `name`)
  result = SavedQuery(name: name, kind: QueryKind(clamp(fcDlg.mode, 0, 3)), what: fcDlg.what,
                      change: fcDlg.change, matchCase: fcDlg.matchCase, wholeWord: fcDlg.wholeWord,
                      font: fcDlg.font, toFont: fcDlg.toFont)
  if fcDlg.mode == 3: result.extra = objectToJson(fcDlg.oq, fcDlg.oc)

proc fcUseQuery(q: SavedQuery) =
  fcDlg.mode = ord(q.kind)
  fcDlg.what = q.what
  fcDlg.change = q.change
  fcDlg.matchCase = q.matchCase
  fcDlg.wholeWord = q.wholeWord
  fcDlg.font = q.font
  fcDlg.toFont = q.toFont
  if q.kind == qkObject: (fcDlg.oq, fcDlg.oc) = objectFrom(q.extra)
  fcDlg.note = ""

proc fcFind(d: Doc; L: Layer; start: int): textsearch.Match =
  ## (the next match in `L`'s text at or after character `start`)
  result = textsearch.Match(a: -1, b: -1)
  if fcDlg.mode == 2:
    # (a glyph, in a font or any)
    let cp = glyphOf(fcDlg.what)
    if cp < 0:
      fcDlg.note = "The glyph: a character, or its code (U+2605)"
      return
    fcDlg.note = ""
    for m in L.text.findGlyph(cp, fcDlg.font):
      if m.a >= start:
        result = m
        break
    return
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
      var st = te.layer.text.styleAt(a)
      var s = ""
      if fcDlg.mode == 2:
        let to = glyphOf(fcDlg.change)
        if to >= 0: s = toUTF8(Rune(to))
        if fcDlg.toFont.len > 0: st.family = fcDlg.toFont
      else: s = expand(fcDlg.change, m, cps)
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
      try:
        n = if fcDlg.mode == 2: t.changeGlyph(glyphOf(fcDlg.what), fcDlg.font, glyphOf(fcDlg.change), fcDlg.toFont)
            else: t.changeIn(fcDlg.what, fcDlg.change, fcDlg.patterns, fcDlg.matchCase, fcDlg.wholeWord)
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

proc fcObjectNext() =
  ## Find Next (Object): the next layer up from the current one that has the formats asked for
  ## (round from the bottom once), made current.
  let dw = active
  if dw == nil: return
  if te.on: commitType()
  let d = dw.doc
  let found = d.findObjects(fcDlg.oq)
  if found.len == 0:
    fcDlg.note = "Not found"
    return
  var nxt = found[0]
  for i in found:
    if i > d.cur:
      nxt = i
      break
  d.clearPicks()
  d.cur = nxt
  d.editMask = false
  inc d.ver
  fcDlg.note = d.layers[nxt].name

proc fcObjectChange(all: bool) =
  ## Change (Object): the current layer, when it is what was asked for, then the next found;
  ## Change All: every one on the page (or each page of the book), one undo step a page.
  let dw = active
  if dw == nil: return
  if te.on: commitType()
  let d = dw.doc
  if not all:
    if d.current != nil and d.matchesObject(d.current, fcDlg.oq):
      d.beginStep("Change Object Format")
      discard d.changeObjects(fcDlg.oq, fcDlg.oc, @[d.cur])
      d.endStep()
    fcObjectNext()
    return
  var total = 0
  proc onDoc(pd: Doc) =
    if pd.findObjects(fcDlg.oq).len == 0: return
    pd.beginStep("Change All")
    total += pd.changeObjects(fcDlg.oq, fcDlg.oc)
    pd.endStep()
  let bw = curBook()
  if fcDlg.scope == 2 and bw != nil:
    let here = bw.page
    for i in 0 ..< bw.book.pages.len:
      onDoc(bw.book.doc(i))
      if i != here: bw.book.park([here])
    d.markAll()
  else: onDoc(d)
  fcDlg.note = if total == 0: "Not found" else: $total & (if total == 1: " change" else: " changes")

proc fcObjectRows(d: Doc) =
  ## (the Object search's formats: what is found, and what it is changed to)
  var styles = @["Any"]
  var toStyles = @["Keep"]
  styles.add "[None]"
  toStyles.add "[None]"
  for s in d.objectStyles:
    styles.add s.name
    toStyles.add s.name
  row([110, -1]):
    label "Find:"
    var k = ord(fcDlg.oq.kind)
    var names: seq[string]
    for e in ObjectKind: names.add tr($e)
    if combo(names, k, w = dp(150)): fcDlg.oq.kind = ObjectKind(clamp(k, 0, ord(high(ObjectKind))))
  row:
    checkbox("Fill", fcDlg.oq.byFill)
    var c = fcDlg.oq.fill
    if colorWell(c, "fcqfill", dp(40)): fcDlg.oq.fill = c or 0xFF000000'u32
    checkbox("Stroke", fcDlg.oq.byStroke)
    var s2 = fcDlg.oq.stroke
    if colorWell(s2, "fcqstroke", dp(40)): fcDlg.oq.stroke = s2 or 0xFF000000'u32
    checkbox("Weight", fcDlg.oq.byWidth)
    var w = int(round(fcDlg.oq.strokeWidth))
    if spin(w, 0, 500, w = dp(56)): fcDlg.oq.strokeWidth = w.float
  row:
    checkbox("Opacity", fcDlg.oq.byOpacity)
    var o = fcDlg.oq.opacity
    if spin(o, 0, 100, w = dp(56)): fcDlg.oq.opacity = o
    label "Object Style:"
    var si = max(0, styles.find(if fcDlg.oq.objectStyle.len > 0: fcDlg.oq.objectStyle else: "Any"))
    if combo(styles, si, w = dp(120)):
      fcDlg.oq.objectStyle = if si <= 0: "" else: styles[si]
  row([110, -1]):
    label "Name has:"
    edit(fcDlg.oq.name)
  separator()
  label("Change to:", bold = true)
  row:
    checkbox("Fill", fcDlg.oc.setFill)
    var c2 = fcDlg.oc.fill
    if colorWell(c2, "fccfill", dp(40)): fcDlg.oc.fill = c2 or 0xFF000000'u32
    checkbox("Stroke", fcDlg.oc.setStroke)
    var s3 = fcDlg.oc.stroke
    if colorWell(s3, "fccstroke", dp(40)): fcDlg.oc.stroke = s3 or 0xFF000000'u32
    checkbox("Weight", fcDlg.oc.setWidth)
    var w2 = int(round(fcDlg.oc.strokeWidth))
    if spin(w2, 0, 500, w = dp(56)): fcDlg.oc.strokeWidth = w2.float
  row:
    checkbox("Opacity", fcDlg.oc.setOpacity)
    var o2 = fcDlg.oc.opacity
    if spin(o2, 0, 100, w = dp(56)): fcDlg.oc.opacity = o2
    label "Object Style:"
    var ti = max(0, toStyles.find(if fcDlg.oc.objectStyle.len > 0: fcDlg.oc.objectStyle else: "Keep"))
    if combo(toStyles, ti, w = dp(120)):
      fcDlg.oc.objectStyle = if ti <= 0: "" else: toStyles[ti]

proc startFindChange() =
  fcDlg.open = true
  if not fcDlg.oq.byOpacity and fcDlg.oq.opacity == 0: fcDlg.oq.opacity = 100
  if not fcDlg.oc.setOpacity and fcDlg.oc.opacity == 0: fcDlg.oc.opacity = 100
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
    fcLoadQueries()
    var next, one, all = false
    let d0 = cur()
    dialog(fcDlg.open, "Find/Change", 500):
      # (a search kept by name: the Query menu, and its Save and Delete)
      row([110, -1, 60, 60]):
        label "Query:"
        var names = @["[Custom]"]
        for q in fcDlg.queries: names.add q.name
        fcDlg.qi = clamp(fcDlg.qi, 0, names.high)
        if combo(names, fcDlg.qi, w = dp(220)) and fcDlg.qi > 0: fcUseQuery(fcDlg.queries[fcDlg.qi - 1])
        if button("Save...", w = dp(56)):
          fcDlg.naming = true
          fcDlg.qname = if fcDlg.qi > 0: fcDlg.queries[fcDlg.qi - 1].name else: ""
        if button("Delete", w = dp(56), enabled = fcDlg.qi > 0):
          fcDlg.queries.delete(fcDlg.qi - 1)
          fcDlg.qi = 0
          fcSaveQueries()
      if fcDlg.naming:
        row([110, -1, 60]):
          label "Save as:"
          edit(fcDlg.qname)
          if button("OK", w = dp(56), enabled = fcDlg.qname.strip.len > 0):
            let q = fcQueryNow(fcDlg.qname.strip)
            var at = -1
            for i, m in fcDlg.queries:
              if m.name == q.name: at = i
            if at >= 0: fcDlg.queries[at] = q else: fcDlg.queries.add q
            fcDlg.qi = (if at >= 0: at else: fcDlg.queries.high) + 1
            fcDlg.naming = false
            fcSaveQueries()
      # (the searches, the layout program's tabs)
      row([110, -1]):
        label "Search for:"
        if combo([tr("Text"), "GREP", tr("Glyph"), tr("Object")], fcDlg.mode, w = dp(120)): fcDlg.note = ""
      fcDlg.patterns = fcDlg.mode == 1
      if fcDlg.mode == 3:
        if d0 != nil: fcObjectRows(d0)
      else:
        row([110, -1]):
          label(if fcDlg.mode == 2: "Find glyph:" else: "Find what:")
          edit(fcDlg.what)
        if fcDlg.mode == 2:
          row([110, -1]):
            label "In the font:"
            var fams = @["Any"]
            for f in fontFamilies(): fams.add f
            var fi = max(0, fams.find(if fcDlg.font.len > 0: fcDlg.font else: "Any"))
            if combo(fams, fi, w = dp(200)): fcDlg.font = if fi <= 0: "" else: fams[fi]
        row([110, -1]):
          label(if fcDlg.mode == 2: "Change glyph:" else: "Change to:")
          edit(fcDlg.change)
        if fcDlg.mode == 2:
          row([110, -1]):
            label "In the font:"
            var fams = @["The letter's own"]
            for f in fontFamilies(): fams.add f
            var fi = max(0, fams.find(if fcDlg.toFont.len > 0: fcDlg.toFont else: "The letter's own"))
            if combo(fams, fi, w = dp(200)): fcDlg.toFont = if fi <= 0: "" else: fams[fi]
          paragraph(tr("A glyph: the character itself, or its code -- U+2605, 0x2605."), color = ui.theme.gray)
        else:
          row:
            checkbox("Match case", fcDlg.matchCase)
            checkbox("Whole word", fcDlg.wholeWord)
      row([110, -1]):
        label "Search:"
        combo(if fcDlg.mode == 3: @["This page", "This page", "The book"] else: @["This text", "This page", "The book"],
              fcDlg.scope, w = dp(140))
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
    if fcDlg.mode == 3:
      if next: fcObjectNext()
      if one: fcObjectChange(false)
      if all: fcObjectChange(true)
    else:
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

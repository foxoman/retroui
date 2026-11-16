## Retro Atelier: spelling, as the layout program has it -- Edit > Spelling > Dynamic Spelling
## (the words not in the dictionary underlined in red in the text on the canvas) and Check
## Spelling... (each such word in turn: Skip, Change, Ignore All, Change All, Add) -- with the
## system's checker (`retroui/spell`: Hunspell, Windows', macOS'), English and Arabic each in its
## own dictionary (included by photo.nim).

when not defined(wasm):
  import retroui/spell
else:
  proc spellAvailable(lang = ""): bool = false
  proc isMisspelled(word: string; lang = ""): bool = false
  proc spellSuggest(word: string; lang = ""; max = 6): seq[string] = @[]
  proc spellIgnore(word: string) = discard
  proc spellAdd(word: string) = discard
  proc spellWords(text: string): seq[tuple[a, b: int]] = @[]
  proc spellGeneration(): int = 0

var
  spellMarks: Table[int, tuple[key: string; marks: seq[tuple[x0, x1, y: float32]]]]
    ## (each type layer's words underlined, where: kept while its text stays)
  spellDlg: tuple[open: bool; layer: Layer; a, b: int; word, change: string; sugg: seq[string];
                  pick: int; allDoc: bool; done: bool; changed: Table[string, string]]
    ## (Check Spelling: the word found -- its layer, its characters --, what to change it to)

proc misspelled*(t: TextData): seq[tuple[a, b: int; word: string]] =
  ## The words of a text the dictionary has not, as characters `a` ..< `b` (the variables'
  ## `<...>` left alone).
  let s = t.plainText
  # (bytes to characters)
  var runeAt = newSeq[int](s.len + 1)
  var n = 0
  for i in 0 ..< s.len:
    runeAt[i] = n
    if (ord(s[i]) and 0xC0) != 0x80: inc n
  runeAt[s.len] = n
  for (a, b) in spellWords(s):
    if a > 0 and s[a - 1] == '<': continue          # (a text variable's name)
    let w = s[a ..< b]
    if isMisspelled(w): result.add (runeAt[a], runeAt[b], w)

proc spellMarksOf(d: Doc; L: Layer): seq[tuple[x0, x1, y: float32]] =
  ## (where a type layer's misspelled words are, under their letters)
  let t = d.effectiveText(L)
  if t.path.len > 0 or t.vertical or t.warp.style != wsNone: return
  let key = $L.ver & ":" & $hash(t.plainText) & ":" & $t.x & "," & $t.y & "," & $t.boxW & ":" & $spellGeneration()
  let uid = uidOf(L)
  if spellMarks.hasKey(uid) and spellMarks[uid].key == key: return spellMarks[uid].marks
  var marks: seq[tuple[x0, x1, y: float32]]
  let bad = misspelled(t)
  if bad.len > 0:
    let lay = layoutText(t)
    for (a, b, _) in bad:
      # (each line the word is on: from its first letter's start to its last's end)
      for ln in lay.lines:
        if ln.last <= a or ln.first >= b: continue
        var x0 = 1e9'f32
        var x1 = -1e9'f32
        for g in lay.glyphs:
          if g.index >= a and g.index < b and g.index >= ln.first and g.index < ln.last:
            x0 = min(x0, g.x)
            x1 = max(x1, g.x + g.adv)
        if x1 > x0: marks.add (x0, x1, ln.baseline + max(1'f32, ln.descent * 0.45'f32))
  if spellMarks.len > 400: spellMarks.clear()
  spellMarks[uid] = (key, marks)
  marks

proc spellOverlay(dw: DocWin) =
  ## Dynamic Spelling: a red wave under each word the dictionary has not.
  if not dynamicSpelling or not spellAvailable(): return
  let d = dw.doc
  let v = dw.view
  if v.angle != 0: return
  let c = color(230, 30, 30)
  for L in d.layers:
    if not L.isText or not L.visible: continue
    for (x0, x1, y) in d.spellMarksOf(L):
      let (sx0, sy) = v.toScreen(d, x0, y)
      let (sx1, _) = v.toScreen(d, x1, y)
      if sx1 < v.view.x or sx0 > v.view.x + v.view.w or sy < v.view.y or sy > v.view.y + v.view.h: continue
      # (a wave two pixels high, as the layout program draws it)
      var x = sx0
      var up = true
      let step = max(2, dp(2))
      while x < sx1:
        let nx = min(sx1, x + step)
        if up: line(x, sy + step, nx, sy, c) else: line(x, sy, nx, sy + step, c)
        up = not up
        x = nx

# ---- Check Spelling ----------------------------------------------------------------------------------------

proc spellNext(fromStart = false) =
  ## (the next word the dictionary has not, from the one found; the text being typed or the
  ## layer picked, then -- All Documents -- the rest of the image's type layers)
  let d = cur()
  if d == nil: return
  var order: seq[Layer]
  for L in d.layers:
    if L.isText and L.text.spans.len > 0: order.add L
  var start = max(0, order.find(spellDlg.layer))
  var at = if fromStart: 0 else: spellDlg.b
  for k in 0 ..< max(1, order.len):
    if order.len == 0: break
    let L = order[(start + k) mod order.len]
    if k > 0:
      if not spellDlg.allDoc: break
      at = 0
    for (a, b, w) in misspelled(L.text):
      if a < at: continue
      spellDlg.layer = L
      spellDlg.a = a
      spellDlg.b = b
      spellDlg.word = w
      spellDlg.sugg = spellSuggest(w)
      spellDlg.pick = if spellDlg.sugg.len > 0: 0 else: -1
      spellDlg.change = if spellDlg.changed.hasKey(w): spellDlg.changed[w]
                        elif spellDlg.sugg.len > 0: spellDlg.sugg[0]
                        else: w
      return
  spellDlg.done = true
  spellDlg.word = ""
  spellDlg.sugg = @[]

proc startCheckSpelling() =
  let d = cur()
  if d == nil:
    status = tr("Check Spelling: open an image with text first")
    return
  if not spellAvailable():
    status = tr("Check Spelling: this system has no spell checker (Hunspell on Linux, the system's on Windows and macOS)")
    return
  let L0 = typeTarget()
  let start = if te.on: min(te.caret, te.anchor) else: 0
  if te.on: commitType()
  spellDlg = (true, L0, start, start, "", "", @[], -1, L0 == nil, false, initTable[string, string]())
  if spellDlg.layer == nil:
    for L in d.layers:
      if L.isText: spellDlg.layer = L
  spellNext(fromStart = start == 0)

proc spellReplace(L: Layer; a, b: int; s: string) =
  ## (characters `a` ..< `b` of the layer's text said as `s`, in their own look)
  let d = cur()
  d.stepOnce("Check Spelling", proc () =
    var t = L.text
    let st = t.styleAt(a)
    t.deleteText(a, b)
    t.insertText(a, s, st)
    d.setText(L, t))
  d.markAll()

proc checkSpellingDialog() =
  if not spellDlg.open: return
  let d = cur()
  if d == nil:
    spellDlg.open = false
    return
  dialog(spellDlg.open, "Check Spelling", 420):
    if spellDlg.done:
      label("Spell check complete.")
    else:
      row([130, -1]):
        label "Not in Dictionary:"
        label(spellDlg.word, color = color(200, 0, 0))
    row([130, -1]):
      label "Change To:"
      edit(spellDlg.change)
    label "Suggested Corrections:"
    beginScroll(ItemH * 5, "spellsugg")
    for i, s in spellDlg.sugg:
      let r = place(available(), ItemH)
      if i == spellDlg.pick: fill(r, ui.theme.select)
      text(r.x + dp(4), itemTextY(r.y), s, if i == spellDlg.pick: ui.theme.selectText else: ui.theme.text)
      let hit = interact(idOf("spellsugg:" & s), r, focusable = false)
      if hit.clicked:
        spellDlg.pick = i
        spellDlg.change = s
    if spellDlg.sugg.len == 0 and not spellDlg.done: label("(no suggestions)", color = ui.theme.gray)
    endScroll()
    row:
      checkbox("All type layers", spellDlg.allDoc)
    let some = not spellDlg.done and spellDlg.layer != nil and spellDlg.layer in d.layers
    row:
      if button("Skip", w = dp(70), enabled = some): spellNext()
      if button("Change", w = dp(70), enabled = some):
        let delta = spellDlg.change.runeCount - (spellDlg.b - spellDlg.a)
        spellReplace(spellDlg.layer, spellDlg.a, spellDlg.b, spellDlg.change)
        spellDlg.b += delta
        spellNext()
      if button("Ignore All", w = dp(80), enabled = some):
        spellIgnore(spellDlg.word)
        spellNext()
      if button("Change All", w = dp(84), enabled = some):
        # (the word changed wherever it is, in every type layer)
        let w = spellDlg.word
        let to = spellDlg.change
        spellDlg.changed[w] = to
        d.beginStep("Change All")
        d.touchLayers()
        for L in d.layers:
          if not L.isText: continue
          var t = L.text
          var hits = misspelled(t)
          var any = false
          for k in countdown(hits.high, 0):
            if hits[k].word == w:
              let st = t.styleAt(hits[k].a)
              t.deleteText(hits[k].a, hits[k].b)
              t.insertText(hits[k].a, to, st)
              any = true
          if any: d.setText(L, t)
        d.endStep()
        d.markAll()
        spellNext(fromStart = true)
    row:
      if button("Add", w = dp(70), enabled = some):
        spellAdd(spellDlg.word)
        spellMarks.clear()
        spellNext()
      if button(if spellDlg.done: "Start" else: "Skip to End", w = dp(100)):
        if spellDlg.done:
          spellDlg.done = false
          spellNext(fromStart = true)
        else: spellDlg.done = true
      spring()
      if button("Done", isDefault = true, w = dp(80)): spellDlg.open = false

proc spellingCommand(name: string): bool =
  result = true
  case name
  of "Check Spelling...": startCheckSpelling()
  of "Dynamic Spelling":
    dynamicSpelling = not dynamicSpelling
    if dynamicSpelling and not spellAvailable():
      status = tr("Dynamic Spelling: this system has no spell checker")
  else: result = false

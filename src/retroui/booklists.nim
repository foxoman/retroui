## A book's lists made from its pages: a table of contents and an index.
##
## - `tocEntries`: the headings -- the text boxes in the paragraph styles
##   named (each style a level), or, when none is named, the text set at
##   least so big -- with the page each is on, in the order of the pages.
## - `indexEntries`: each word or phrase asked for, with the pages it is on
##   (any case; Arabic too: its letters with or without their marks).
## - `tocText`, `indexText`: either as a text box to place -- each entry's
##   page numbers at the edge, at a right tab stop with dots before them
##   (right to left: at the left edge), each level standing in; an index in
##   the order of its letters, a heading for each first letter. A table of
##   contents set as `TocOptions` says: the number after the entry, before
##   it or none, what is between them, the leader, the entries sorted, a
##   style for each level and for the title (the layout program's Table of
##   Contents dialog).
##
## .. code-block:: nim
##   import retroui/[photobook, booklists]
##   let toc = b.tocEntries(@["Chapter", "Section"])
##   var t = tocText(toc, "Contents", style, b.marginBox(0).w.float32)
##   let ix = b.indexEntries(@["Muscat", "Sohar", "عُمان"])
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, algorithm, tables]
import std/unicode except strip
import photo, photobook, textengine

type
  TocEntry* = object
    ## A heading of the book.
    text*: string                ## what it says (its first line)
    page*: int                   ## the page it is on (0 the first)
    label*: string               ## ... that page's number as printed
    level*: int                  ## 0 the highest (the first style named)

  TocNumbers* = enum
    ## Where an entry's page number is (Table of Contents > Page Number).
    tnAfter = "After Entry", tnBefore = "Before Entry", tnNone = "No Page Number"

  TocOptions* = object
    ## How a table of contents is set (`tocText`).
    numbers*: TocNumbers
    between*: string             ## between an entry and its number ("": a tab to the box's far edge
                                 ## after the entry -- `leader` before the number --, two spaces before it)
    leader*: string              ## ... the tab's leader ("": ". "; " ": none)
    sorted*: bool                ## the entries in the order of their letters (else as the pages have them)
    levelStyles*: seq[CharStyle] ## each level's entries' style (missing, or size 0: the style given)
    titleStyle*: CharStyle       ## the title's (size 0: the style given, half as big again, bold)

  IndexEntry* = object
    ## A word of the index and where it is.
    term*: string
    pages*: seq[int]             ## the pages it is on (0 the first), each once, in order
    labels*: seq[string]         ## ... their numbers as printed

proc firstLine(s: string): string =
  result = s.strip
  let n = result.find('\n')
  if n >= 0: result = result[0 ..< n].strip

proc biggest(t: TextData): float32 =
  for sp in t.spans: result = max(result, sp.style.size)

proc tocEntries*(b: Book; styles: seq[string] = @[]; minSize = 0'f32; keep: openArray[int] = [];
                 hidden = false): seq[TocEntry] =
  ## The book's headings: its text boxes in the paragraph styles `styles` (each a level, in
  ## that order), or -- none named -- those set at `minSize` pixels and more; page by page,
  ## top to bottom on a page (`hidden`: layers not shown too).
  for i in 0 ..< b.pages.len:
    let was = b.isOpen(i)
    let d = b.doc(i)
    var here: seq[tuple[y: float32; e: TocEntry]]
    for L in d.layers:
      if not L.isText or (not L.visible and not hidden) or L.fromMaster != 0: continue
      if styles.len > 0 and L.text.paraFmts.len > 0:
        # (paragraphs in formats of their own: each in a style named, an entry where it is)
        let lay = layoutText(L.text)
        var at = 0
        for ptxt in L.text.plainText.split('\n'):
          let level = styles.find(L.text.paraFmtAt(at).styleName)
          let tx = ptxt.strip
          if level >= 0 and tx.len > 0 and not tx.contains("<#"):
            var y = L.text.y
            for ln in lay.lines:
              if ln.first == at: y = ln.baseline
            here.add (y, TocEntry(text: tx, page: i, label: b.label(i), level: level))
          at += ptxt.runeLen + 1
        continue
      let txt = firstLine(L.text.plainText)
      if txt.len == 0 or txt.contains("<#"): continue
      var level = -1
      if styles.len > 0:
        level = styles.find(L.text.para.styleName)
      elif minSize > 0 and L.text.biggest >= minSize:
        level = 0
      if level < 0: continue
      here.add (L.text.y, TocEntry(text: txt, page: i, label: b.label(i), level: level))
    here.sort(proc (a, c: tuple[y: float32; e: TocEntry]): int = cmp(a.y, c.y))
    for h in here: result.add h.e
    if not was and i notin keep: b.park(keep)

proc folded(s: string): string =
  ## (a word to compare: small letters, Arabic without its marks and tatweel, alef's forms one)
  for r in s.toLower.runes:
    let c = int(r)
    if c in 0x064B .. 0x065F or c == 0x0670 or c == 0x0640: continue
    if c in [0x0622, 0x0623, 0x0625]: result.add "ا"
    elif c == 0x0629: result.add "ه"
    elif c == 0x0649: result.add "ي"
    else: result.add $r

proc isLetter(s: string; i: int): bool =
  ## (a letter or a digit at byte `i` of `s`)
  if i < 0 or i >= s.len: return false
  let r = s.runeAt(i)
  r.isAlpha or (int(r) < 128 and char(int(r)) in {'0' .. '9'})

proc indexEntries*(b: Book; terms: seq[string]; keep: openArray[int] = []): seq[IndexEntry] =
  ## Each of `terms` with the pages it is on, as a whole word or phrase; those on no page left
  ## out. In the order of their letters.
  var found: Table[string, seq[int]]
  var wanted: seq[(string, string)]          # (as asked, folded)
  for t in terms:
    let s = t.strip
    if s.len > 0: wanted.add (s, folded(s))
  for i in 0 ..< b.pages.len:
    let was = b.isOpen(i)
    let d = b.doc(i)
    var all = ""
    for L in d.layers:
      if L.isText and L.visible and L.fromMaster == 0: all.add folded(L.text.plainText) & "\n"
    for (term, f) in wanted:
      var at = all.find(f)
      while at >= 0:
        # (a whole word: not inside another)
        let before = if at > 0: at - 1 else: -1
        var b0 = before
        while b0 > 0 and (ord(all[b0]) and 0xC0) == 0x80: dec b0
        let after = at + f.len
        if not isLetter(all, b0) and not isLetter(all, after):
          var ps = found.getOrDefault(term)
          if i notin ps:
            ps.add i
            found[term] = ps
          break
        at = all.find(f, at + 1)
    if not was and i notin keep: b.park(keep)
  for (term, _) in wanted:
    if term in found:
      var e = IndexEntry(term: term, pages: found[term])
      for p in e.pages: e.labels.add b.label(p)
      result.add e
  result.sort(proc (a, c: IndexEntry): int = cmp(folded(a.term), folded(c.term)))

proc dotted(t: var TextData; width: float32) =
  ## (a list's page numbers at its box's far edge -- the left, right to left --, dots before them:
  ## a right tab stop with a leader)
  t.para.setTab(TabStop(pos: width, align: tabRight, leader: ". "))

proc tocText*(entries: seq[TocEntry]; title: string; style: CharStyle; width: float32; rtl = false;
              o = TocOptions()): TextData =
  ## The table of contents as a text box `width` wide: its title, then a line a heading -- the
  ## heading (standing in by its level), dots, its page's number at the edge -- or as `o` says.
  var list = entries
  if o.sorted: list.sort(proc (a, c: TocEntry): int = cmp(folded(a.text), folded(c.text)))
  var spans: seq[TextSpan]
  var tallest = style.size
  for k, e in list:
    var st = style
    if e.level < o.levelStyles.len and o.levelStyles[e.level].size > 0: st = o.levelStyles[e.level]
    tallest = max(tallest, st.size)
    let entry = repeat("    ", e.level) & e.text.replace("\t", " ")
    let row = case o.numbers
              of tnAfter: entry & (if o.between.len > 0: o.between else: "\t") & e.label
              of tnBefore: repeat("    ", e.level) & e.label & (if o.between.len > 0: o.between else: "  ") &
                           e.text.replace("\t", " ")
              of tnNone: entry
    spans.add TextSpan(text: (if k > 0: "\n" else: "") & row, style: st)
  result = newText("", style, 0, 0)
  if spans.len > 0: result.spans = spans
  result.boxW = width
  result.boxH = max(40'f32, float32(list.len + 1) * tallest * 1.6)
  if rtl: result.para.rtl = 2
  if o.numbers == tnAfter and o.between.len == 0:
    result.para.setTab(TabStop(pos: width, align: tabRight, leader: (if o.leader.len > 0: o.leader else: ". ")))
  if title.len > 0:
    # (the title: a line of its own, bold, larger -- or in its own style)
    var ts = o.titleStyle
    if ts.size <= 0:
      ts = style
      ts.size = style.size * 1.5
      ts.fauxBold = true
    result.spans.insert(TextSpan(text: title & "\n", style: ts), 0)
    result.boxH += ts.size * 1.6

proc indexText*(entries: seq[IndexEntry]; title: string; style: CharStyle; width: float32; rtl = false;
                letters = true): TextData =
  ## The index as a text box `width` wide: each term, dots, its pages' numbers at the edge
  ## ("Muscat . . . 3, 7"); `letters`: a heading for each first letter.
  var spans: seq[TextSpan]
  var head = style
  head.fauxBold = true
  head.size = style.size * 1.2
  if title.len > 0:
    var ts = style
    ts.size = style.size * 1.5
    ts.fauxBold = true
    spans.add TextSpan(text: title & "\n", style: ts)
  var last = ""
  var lines = 0
  for e in entries:
    let first = if e.term.len > 0: ($e.term.runeAt(0)).toUpper else: ""
    if letters and first != last:
      spans.add TextSpan(text: (if spans.len > 0: "\n" else: "") & first & "\n", style: head)
      last = first
      inc lines
    spans.add TextSpan(text: e.term & "\t" & e.labels.join(if rtl: "، " else: ", ") & "\n", style: style)
    inc lines
  result = newText("", style, 0, 0)
  result.spans = spans
  if result.spans.len > 0 and result.spans[^1].text.endsWith("\n"):
    result.spans[^1].text.setLen(result.spans[^1].text.len - 1)
  result.boxW = width
  result.boxH = max(40'f32, float32(lines + 3) * style.size * 1.6)
  if rtl: result.para.rtl = 2
  result.dotted(width)

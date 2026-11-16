## A book's lists made from its pages: a table of contents and an index.
##
## - `tocEntries`: the headings -- the text boxes in the paragraph styles
##   named (each style a level), or, when none is named, the text set at
##   least so big -- with the page each is on, in the order of the pages.
## - `indexEntries`: each word or phrase asked for, with the pages it is on
##   (any case; Arabic too: its letters with or without their marks).
## - `tocText`, `indexText`: either as a text box to place -- a table of two
##   columns, the page numbers at the edge, each level standing in; an
##   index in the order of its letters, a heading for each first letter.
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

proc tocEntries*(b: Book; styles: seq[string] = @[]; minSize = 0'f32; keep: openArray[int] = []): seq[TocEntry] =
  ## The book's headings: its text boxes in the paragraph styles `styles` (each a level, in
  ## that order), or -- none named -- those set at `minSize` pixels and more; page by page,
  ## top to bottom on a page.
  for i in 0 ..< b.pages.len:
    let was = b.isOpen(i)
    let d = b.doc(i)
    var here: seq[tuple[y: float32; e: TocEntry]]
    for L in d.layers:
      if not L.isText or not L.visible or L.fromMaster != 0: continue
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

proc listStyle(): TableStyle =
  ## (a list's table: no lines, no fills, the numbers at the edge)
  result = tableTheme("Minimal")
  result.border = 0
  result.inner = false
  result.rowLines = false
  result.headerRows = 0
  result.fill = 0
  result.altFill = 0
  result.numbersRight = true
  result.widths = @[0.85'f32, 0.15]

proc tocText*(entries: seq[TocEntry]; title: string; style: CharStyle; width: float32; rtl = false): TextData =
  ## The table of contents as a text box `width` wide: its title, then a row a heading -- the
  ## heading (standing in by its level), its page's number at the edge.
  var rows = ""
  for e in entries:
    if rows.len > 0: rows.add "\n"
    rows.add repeat("    ", e.level) & e.text.replace("\t", " ") & "\t" & e.label
  var body = style
  result = newText(rows, body, 0, 0)
  result.boxW = width
  result.boxH = max(40'f32, float32(entries.len + 1) * style.size * 1.6)
  result.table = listStyle()
  result.table.pad = style.size * 0.18
  if rtl: result.para.rtl = 2
  if title.len > 0:
    # (the title: a row of its own, bold, larger)
    var ts = style
    ts.size = style.size * 1.5
    ts.fauxBold = true
    result.spans.insert(TextSpan(text: title & "\t\n", style: ts), 0)
    result.boxH += style.size * 2.4

proc indexText*(entries: seq[IndexEntry]; title: string; style: CharStyle; width: float32; rtl = false;
                letters = true): TextData =
  ## The index as a text box `width` wide: each term, its pages' numbers after it ("Muscat,
  ## 3, 7"); `letters`: a heading for each first letter.
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
    spans.add TextSpan(text: e.term & (if rtl: "، " else: ", ") & e.labels.join(if rtl: "، " else: ", ") & "\n",
                       style: style)
    inc lines
  result = newText("", style, 0, 0)
  result.spans = spans
  if result.spans.len > 0 and result.spans[^1].text.endsWith("\n"):
    result.spans[^1].text.setLen(result.spans[^1].text.len - 1)
  result.boxW = width
  result.boxH = max(40'f32, float32(lines + 3) * style.size * 1.6)
  if rtl: result.para.rtl = 2

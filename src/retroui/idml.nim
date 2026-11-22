## A book (or one document) as IDML -- the open, documented package the
## usual page layout program saves and opens for exchange: its pages in
## spreads (facing or not, bound either way), its master pages, its text
## boxes with their stories (fonts, sizes, colors, tracking, leading,
## alignment, indents, direction; Arabic and Latin each in its font; page
## numbers as the program's own), its shapes as rectangles, ovals and
## polygons with their fill and stroke, its pictures as linked PNG files
## beside it. `saveBookIdml`, `saveDocIdml`.
##
## What it has no word for is drawn to pixels (layer styles, blend modes:
## the layer as a picture) or kept simpler: text that flows on from box to
## box as a story each. Tables go as the program's own tables (rows,
## columns, cells' text, fills and lines), footnotes as its footnotes,
## endnotes as text after the story.

import std/[strutils, os, tables, hashes]
from std/unicode import runeAt, runeLenAt, runeLen, toUTF8
import gfx, imaging, jpeg, photo, photobook, photoshapes, textengine, zip

type
  IdmlOut = object
    stories: seq[(string, string)]          ## (id, XML)
    colors: OrderedTable[uint32, string]    ## ARGB -> its Self
    fonts: OrderedTable[string, seq[string]] ## family -> its styles
    links: seq[(string, string)]            ## (file name, PNG bytes)
    linksDir: string
    next: int
    charStyles: OrderedTable[string, CharStyle]  ## the character styles nested, GREP and line styles name
    objStyles: OrderedTable[string, string]      ## Object Styles: name -> their attributes, written
    hyper: string                           ## the hyperlinks, their destinations, the bookmarks (designmap)
    dests: Table[string, string]            ## a text destination's name -> its Self
    pageSelf: seq[string]                   ## (a book's) each page's Self, for links to a page
    pageDest: Table[int, string]            ## page number -> its HyperlinkPageDestination
    k: float                                ## points a pixel

const
  AutoSizing = [asOff: "Off", asHeight: "HeightOnly", asWidth: "WidthOnly", asBoth: "HeightAndWidth",
                asProportional: "HeightAndWidthProportionally"]
    ## (Auto-Size as the layout program writes it)
  VertJusts = [vjTop: "TopAlign", vjCenter: "CenterAlign", vjBottom: "BottomAlign", vjJustify: "JustifyAlign"]
  FirstBases = [fbAscent: "AscentOffset", fbCapHeight: "CapHeight", fbLeading: "LeadingOffset",
                fbXHeight: "XHeight", fbFixed: "FixedHeight"]
  RefPoints = ["TopLeftPoint", "TopCenterPoint", "TopRightPoint", "LeftCenterPoint", "CenterPoint",
               "RightCenterPoint", "BottomLeftPoint", "BottomCenterPoint", "BottomRightPoint"]

proc x(s: string): string =
  ## (XML's text)
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    else:
      if ord(c) < 0x20 and c notin {'\t', '\n'}: discard
      else: result.add c

proc f(v: float): string =
  ## (a number as IDML writes it)
  if abs(v) < 1e-9: return "0"
  result = formatFloat(v, ffDecimal, 4)
  result.trimZeros()
  if result.endsWith("."): result.setLen(result.len - 1)

proc uid(o: var IdmlOut; prefix = "u"): string =
  inc o.next
  prefix & toHex(o.next + 0x100, 4).toLowerAscii

proc colorRef(o: var IdmlOut; c: uint32): string =
  ## (a color's swatch: "Color/Black" for black, the paper for white, else one of its own)
  let rgb = c and 0xFFFFFF'u32
  if rgb == 0: return "Color/Black"
  if rgb == 0xFFFFFF'u32: return "Color/Paper"
  if rgb notin o.colors:
    let r = (rgb shr 16) and 255
    let g = (rgb shr 8) and 255
    let b = rgb and 255
    o.colors[rgb] = "Color/R=" & $r & " G=" & $g & " B=" & $b
  o.colors[rgb]

proc fontRef(o: var IdmlOut; family, style: string) =
  let fam = if family.len > 0: family else: "FreeSans"
  let st = if style.len > 0: style else: "Regular"
  if fam notin o.fonts: o.fonts[fam] = @[]
  if st notin o.fonts[fam]: o.fonts[fam].add st

const languageNames = [("en", "English: USA"), ("fr", "French"), ("de", "German: 2006 Reform"),
                       ("es", "Spanish"), ("it", "Italian"), ("pt", "Portuguese"),
                       ("nl", "Dutch: 2005 Reform"), ("ar", "Arabic")]
  # (a language's tag and the layout program's name for it: AppliedLanguage="$ID/French")

proc languageOut(lang: string): string =
  ## (a CharacterStyleRange's AppliedLanguage: "" for English, the program's default)
  if lang.len < 2 or lang.startsWith("en"): return ""
  for (tag, name) in languageNames:
    if lang.startsWith(tag): return " AppliedLanguage=\"$ID/" & name & "\""

proc languageIn(s: string): string =
  ## (a language's tag from an AppliedLanguage: "$ID/German: Swiss" -> "de")
  let n = (if s.startsWith("$ID/"): s[4 .. ^1] else: s).toLowerAscii
  for (tag, name) in languageNames:
    if n.startsWith(name.toLowerAscii.split(':')[0]): return (if tag == "en": "" else: tag)

proc alignOf(a: TextAlign; rtl: bool): string =
  case a
  of textLeft: (if rtl: "RightAlign" else: "LeftAlign")
  of textCenter: "CenterAlign"
  of textRight: (if rtl: "LeftAlign" else: "RightAlign")
  of justifyLeft: (if rtl: "RightJustified" else: "LeftJustified")
  of justifyCenter: "CenterJustified"
  of justifyRight: (if rtl: "LeftJustified" else: "RightJustified")
  of justifyAll: "FullyJustified"

const OtfAttrs = [("dlig", "OTFDiscretionaryLigature"), ("frac", "OTFFraction"), ("ordn", "OTFOrdinal"),
                 ("swsh", "OTFSwash"), ("titl", "OTFTitling"), ("zero", "OTFSlashedZero"),
                 ("hist", "OTFHistorical")]
  # (OpenType features and the layout program's names for them; Ligatures and Contextual
  # Alternates apart: on unless said)

proc otfOut(features: string): string =
  ## (a style's OpenType features as the attributes of a CharacterStyleRange)
  if not featureOn(features, "liga"): result.add " Ligatures=\"false\""
  if not featureOn(features, "calt"): result.add " OTFContextualAlternate=\"false\""
  for (tag, attr) in OtfAttrs:
    if featureOn(features, tag): result.add " " & attr & "=\"true\""

proc charStyleRef(o: var IdmlOut; name: string; look: CharStyle): string =
  ## (a character style nested, GREP or line styles name: written in Styles.xml with its look)
  if name.len == 0: return "CharacterStyle/$ID/[No character style]"
  if name notin o.charStyles: o.charStyles[name] = look
  "CharacterStyle/" & x(name)

proc styleProps(o: var IdmlOut; p: ParaStyle): string =
  ## (a paragraph's nested, GREP and line styles: the layout program's Properties lists)
  var items = ""
  if p.nested.len > 0:
    items.add "<AllNestedStyles type=\"list\">"
    for n in p.nested:
      let delim = case n.unit
                  of nuWords: "<Delimiter type=\"enumeration\">AnyWord</Delimiter>"
                  of nuChars: "<Delimiter type=\"enumeration\">AnyCharacter</Delimiter>"
                  of nuSentences: "<Delimiter type=\"enumeration\">Sentence</Delimiter>"
                  of nuUpTo: "<Delimiter type=\"string\">" & x(if n.upTo.len > 0: n.upTo else: ":") & "</Delimiter>"
      items.add "<ListItem type=\"record\"><AppliedCharacterStyle type=\"object\">" & o.charStyleRef(n.name, n.look) &
                 "</AppliedCharacterStyle>" & delim & "<Repetition type=\"long\">" & $max(1, n.count) &
                 "</Repetition><Inclusive type=\"boolean\">" & $(n.through or n.unit != nuUpTo) & "</Inclusive></ListItem>"
    items.add "</AllNestedStyles>"
  if p.lineStyles.len > 0:
    items.add "<AllLineStyles type=\"list\">"
    for n in p.lineStyles:
      items.add "<ListItem type=\"record\"><AppliedCharacterStyle type=\"object\">" & o.charStyleRef(n.name, n.look) &
                 "</AppliedCharacterStyle><LineCount type=\"long\">" & $max(1, n.lines) &
                 "</LineCount><RepeatLast type=\"long\">0</RepeatLast></ListItem>"
    if p.repeatLast > 0:
      items.add "<ListItem type=\"record\"><AppliedCharacterStyle type=\"object\">CharacterStyle/$ID/[Repeat]" &
                 "</AppliedCharacterStyle><LineCount type=\"long\">1</LineCount><RepeatLast type=\"long\">" &
                 $p.repeatLast & "</RepeatLast></ListItem>"
    items.add "</AllLineStyles>"
  if p.grepStyles.len > 0:
    items.add "<AllGREPStyles type=\"list\">"
    for g in p.grepStyles:
      if g.pattern.len == 0: continue
      items.add "<ListItem type=\"record\"><AppliedCharacterStyle type=\"object\">" & o.charStyleRef(g.name, g.look) &
                 "</AppliedCharacterStyle><GrepExpression type=\"string\">" & x(g.pattern) & "</GrepExpression></ListItem>"
    items.add "</AllGREPStyles>"
  if p.tabs.len > 0:
    # (its tab stops: where, in points from the edge its lines start from; how; their leaders)
    items.add "<TabList type=\"list\">"
    for t in p.tabs:
      let al = case t.align
               of tabLeft: "LeftAlign"
               of tabRight: "RightAlign"
               of tabCenter: "CenterAlign"
               of tabChar: "CharacterAlign"
      items.add "<ListItem type=\"record\"><Alignment type=\"enumeration\">" & al &
                 "</Alignment><AlignmentCharacter type=\"string\">" & x(if t.alignOn.len > 0: t.alignOn else: ".") &
                 "</AlignmentCharacter><Leader type=\"string\">" & x(t.leader) &
                 "</Leader><Position type=\"unit\">" & f(t.pos * o.k) & "</Position></ListItem>"
    items.add "</TabList>"
  if items.len > 0: result = "<Properties>" & items & "</Properties>\n"

proc pageDestOf(o: var IdmlOut; n: int): string

proc destSelf(o: var IdmlOut; name: string): string =
  ## (a text destination's Self, by its name)
  if name notin o.dests: o.dests[name] = "HyperlinkTextDestination/" & x(name)
  o.dests[name]

proc linkOpen(o: var IdmlOut; link: string): string =
  ## (a span's hyperlink: its source's opening, the link and where it goes put in the designmap;
  ## "" when it is a destination, written where it starts)
  if link.len == 0: return ""
  if link[0] == '=':
    return "<HyperlinkTextDestination Self=\"" & o.destSelf(link[1 .. ^1]) & "\" Name=\"" & x(link[1 .. ^1]) &
           "\" Hidden=\"false\" DestinationUniqueKey=\"" & $(o.dests.len + 100) & "\"/>\n"
  let src = o.uid("hs")
  let hl = o.uid("hl")
  var dest = ""
  if link[0] == '#':
    dest = o.destSelf(link[1 .. ^1])
  elif link.startsWith("page:"):
    let n = (try: parseInt(link[5 .. ^1]) except ValueError: 1)
    dest = o.pageDestOf(n)
  else:
    dest = o.uid("hud")
    o.hyper.add "<HyperlinkURLDestination Self=\"" & dest & "\" Name=\"" & x(link) & "\" DestinationURL=\"" & x(link) &
                "\" Hidden=\"false\" DestinationUniqueKey=\"" & $(2000 + o.next) & "\"/>\n"
  o.hyper.add "<Hyperlink Self=\"" & hl & "\" Name=\"" & x(link) & "\" Source=\"" & src &
              "\" Visible=\"false\" Highlight=\"None\" Width=\"Thin\" BorderStyle=\"Solid\" Hidden=\"false\" " &
              "DestinationUniqueKey=\"" & $(3000 + o.next) & "\"><Properties><BorderColor type=\"enumeration\">Black" &
              "</BorderColor><Destination type=\"object\">" & dest & "</Destination></Properties></Hyperlink>\n"
  "<HyperlinkTextSource Self=\"" & src & "\" Name=\"" & x(link) & "\" Hidden=\"false\">\n"

proc storyOf(o: var IdmlOut; t0: TextData; k: float; master: bool; self = ""): string =
  ## (a text's story: its paragraphs, each run in its look; on a master, "<#>" the page number;
  ## footnotes the layout program's own, endnotes as text after it)
  let t = scriptFontsApplied(if t0.noteOpts.kind == nkEndnotes: notesAsText(t0) else: t0)
  let id = if self.len > 0: self else: o.uid("s")
  var rtl = t.para.rtl == 2
  if t.para.rtl == 0:
    block strong:
      for sp in t.spans:
        for c in sp.text:
          if ord(c) in [0xD8, 0xD9, 0xDA, 0xDB]:
            rtl = true
            break strong
          if c in {'A' .. 'Z', 'a' .. 'z'}: break strong
  proc psrOpen(o: var IdmlOut; p: ParaStyle): string =
    ## (a ParagraphStyleRange's opening, in paragraph format `p`)
    let composer = if rtl: "$ID/HL Composer Optyca"
                   elif p.composer == cpSingle: "HL Single"
                   elif p.composer == cpParagraph: "HL Composer"
                   else: ""
    result = "<ParagraphStyleRange AppliedParagraphStyle=\"ParagraphStyle/$ID/NormalParagraphStyle\" Justification=\"" &
             alignOf(p.align, rtl) & "\" LeftIndent=\"" & f(p.indentLeft * k) & "\" RightIndent=\"" &
             f(p.indentRight * k) & "\" FirstLineIndent=\"" & f(p.indentFirst * k) & "\" SpaceBefore=\"" &
             f(p.spaceBefore * k) & "\" SpaceAfter=\"" & f(p.spaceAfter * k) & "\"" &
             (if rtl: " ParagraphDirection=\"RightToLeftDirection\"" else: "") &
             (if composer.len > 0: " Composer=\"" & composer & "\"" else: "") &
             " Hyphenation=\"" & $p.hyphenate & "\"" &
             (if p.dropLines >= 2: " DropCapLines=\"" & $p.dropLines & "\" DropCapCharacters=\"" &
                                   $max(1, p.dropChars) & "\"" else: "")
    # (Justification's spacing, Keep Options, Span Columns: the layout program's own)
    for (names, a, d) in [(["MinimumWordSpacing", "DesiredWordSpacing", "MaximumWordSpacing"], p.wordSpacing,
                           [80'i16, 100, 133]),
                          (["MinimumLetterSpacing", "DesiredLetterSpacing", "MaximumLetterSpacing"], p.letterSpacing,
                           [0'i16, 0, 0]),
                          (["MinimumGlyphScaling", "DesiredGlyphScaling", "MaximumGlyphScaling"], p.glyphScaling,
                           [100'i16, 100, 100])]:
      if a != [0'i16, 0, 0]:
        for q in 0 .. 2: result.add " " & names[q] & "=\"" & $(if a[q] == 0 and d[q] != 0: d[q] else: a[q]) & "\""
    if p.keepTogether or p.keepStart > 1 or p.keepEnd > 1:
      result.add " KeepLinesTogether=\"true\" KeepAllLinesTogether=\"" & $p.keepTogether & "\" KeepFirstLines=\"" &
                 $max(1, p.keepStart) & "\" KeepLastLines=\"" & $max(1, p.keepEnd) & "\""
    if p.keepWithNext > 0: result.add " KeepWithNext=\"" & $p.keepWithNext & "\""
    if p.ignoreOptical: result.add " IgnoreEdgeAlignment=\"true\""
    if p.startAt != psAnywhere:
      result.add " StartParagraph=\"" &
                 (case p.startAt
                  of psNextColumn: "NextColumn"
                  of psNextFrame: "NextFrame"
                  of psNextPage: "NextPage"
                  else: "Anywhere") & "\""
    if p.spanAll: result.add " SpanColumnType=\"SpanColumns\" SpanSplitColumnCount=\"All\""
    elif p.splitColumns >= 2:
      result.add " SpanColumnType=\"SplitColumns\" SpanSplitColumnCount=\"" & $p.splitColumns & "\""
    result.add ">\n" & o.styleProps(p)
  # (each paragraph's format: where they change, a range of their own)
  var paraFmt: seq[int]
  block:
    var atStart = true
    for sp in t.spans:
      for c in sp.text:
        if atStart:
          paraFmt.add sp.style.para
          atStart = false
        if c == '\n': atStart = true
    if atStart: paraFmt.add (if t.spans.len > 0: t.spans[^1].style.para else: 0)
  var paraNo = 0
  var body = psrOpen(o, t.fmtOf(if paraFmt.len > 0: paraFmt[0] else: 0))
  proc csrOpen(o: var IdmlOut; st: CharStyle): string =
    ## (a CharacterStyleRange's opening, in `st`'s look)
    let fam = if st.family.len > 0: st.family else: "FreeSans"
    let sty = if st.style.len > 0: st.style elif st.fauxBold: "Bold" else: "Regular"
    o.fontRef(fam, sty)
    "<CharacterStyleRange AppliedCharacterStyle=\"CharacterStyle/$ID/[No character style]\" FontStyle=\"" &
      x(sty) & "\" PointSize=\"" & f(max(0.1, st.size * k)) & "\" FillColor=\"" & o.colorRef(st.color) & "\"" &
      (if st.tracking != 0: " Tracking=\"" & $st.tracking & "\"" else: "") &
      (if st.baselineShift != 0: " BaselineShift=\"" & f(st.baselineShift * k) & "\"" else: "") &
      (if st.underline: " Underline=\"true\"" else: "") & (if st.strike: " StrikeThru=\"true\"" else: "") &
      (if st.hScale > 0 and st.hScale != 1: " HorizontalScale=\"" & f(st.hScale * 100) & "\"" else: "") &
      (if st.vScale > 0 and st.vScale != 1: " VerticalScale=\"" & f(st.vScale * 100) & "\"" else: "") &
      (if st.allCaps: " Capitalization=\"AllCaps\"" elif st.smallCaps: " Capitalization=\"SmallCaps\"" else: "") &
      languageOut(st.lang) &
      otfOut(st.features) & ">\n<Properties><AppliedFont type=\"string\">" & x(fam) & "</AppliedFont>" &
      (if st.leading > 0: "<Leading type=\"unit\">" & f(st.leading * k) & "</Leading>" else: "") &
      "</Properties>\n"
  if t.table.on:
    # (a table: the layout program's own -- its rows and columns, each cell's text and fill, its lines)
    let tb = t.table
    let all = t.plainText
    var rows: seq[seq[tuple[text: string; at: int]]]
    var at = 0
    for line in all.split('\n'):
      var cells: seq[tuple[text: string; at: int]]
      var a = at
      for c in line.split('\t'):
        cells.add (c, a)
        a += c.runeLen + 1
      rows.add cells
      at += line.runeLen + 1
    var ncol = 1
    for r in rows: ncol = max(ncol, r.len)
    let tid = o.uid("t")
    let w = max(1.0, t.boxW.float * k)
    var widths: seq[float]
    var sum = 0.0
    for c in 0 ..< ncol:
      let wv = if c < tb.widths.len and tb.widths[c] > 0: tb.widths[c].float else: 1.0
      widths.add wv
      sum += wv
    let base = t.styleAt(0)
    let rowH = max(1.0, base.size.float * k * 1.6)
    let lineW = (if tb.borderW > 0: tb.borderW.float else: 1.0) * k
    body.add csrOpen(o, base)
    let hr = min(tb.headerRows, rows.len)
    let fr = min(tb.footerRows, rows.len - hr)
    body.add "<Table Self=\"" & tid & "\" HeaderRowCount=\"" & $hr & "\" FooterRowCount=\"" & $fr & "\" " &
             "BodyRowCount=\"" & $(rows.len - hr - fr) & "\" ColumnCount=\"" & $ncol &
             "\" AppliedTableStyle=\"TableStyle/$ID/[Basic Table]\" TableDirection=\"" &
             (if rtl: "RightToLeftDirection" else: "LeftToRightDirection") & "\"" &
             (if tb.skipFirstHeader: " SkipFirstHeader=\"true\"" else: "") &
             (if tb.skipLastFooter: " SkipLastFooter=\"true\"" else: "") & ">\n"
    for r in 0 ..< rows.len:
      # (its height: as tall as it needs from a least one, at least so tall, exactly so tall)
      let rf = tb.rowFmtAt(r)
      body.add "<Row Self=\"" & tid & "Row" & $r & "\" Name=\"" & $r & "\" " &
               (case rf.kind
                of rhExactly: "AutoGrow=\"false\" SingleRowHeight=\"" & f(max(1.0, rf.height.float * k)) & "\""
                of rhAtLeast: "AutoGrow=\"true\" MinimumHeight=\"" & f(max(1.0, rf.height.float * k)) & "\""
                of rhAuto: "AutoGrow=\"true\" MinimumHeight=\"" & f(rowH) & "\"") &
               (if rf.maxHeight > 0 and rf.kind != rhExactly: " MaximumHeight=\"" & f(rf.maxHeight.float * k) & "\""
                else: "") &
               (if rf.keepNext: " KeepWithNextRow=\"true\"" else: "") &
               (if rf.startNext: " StartRow=\"NextFrame\"" else: "") & "/>\n"
    for c in 0 ..< ncol:
      body.add "<Column Self=\"" & tid & "Column" & $c & "\" Name=\"" & $c & "\" SingleColumnWidth=\"" &
               f(w * widths[c] / sum) & "\"/>\n"
    for r in 0 ..< rows.len:
      let header = r < tb.headerRows
      let fillC = if header: tb.headerFill
                  elif tb.rowStriped(r): tb.altFill
                  else: tb.fill
      # (the cells merged into another: not written -- that one spans them)
      var covered = newSeq[bool](ncol)
      for r0 in 0 .. r:
        for c0 in 0 ..< ncol:
          let f0 = tb.cellAt(r0, c0)
          if f0.rowSpan > 1 or f0.colSpan > 1:
            if r < r0 + max(1, f0.rowSpan):
              for cc in c0 ..< min(ncol, c0 + max(1, f0.colSpan)):
                if r != r0 or cc != c0: covered[cc] = true
      for c in 0 ..< ncol:
        if covered[c]: continue
        let cf = tb.cellAt(r, c)
        let cell = if c < rows[r].len: rows[r][c] else: ("", 0)
        var st = t.styleAt(cell.at)
        if header and tb.headerColor != 0: st.color = tb.headerColor
        elif not header and tb.bodyColor != 0: st.color = tb.bodyColor
        if header and tb.headerBold: st.fauxBold = true
        var edges = ""
        if tb.border != 0:
          let top = tb.inner or r == 0 or (tb.rowLines and r > 0) or (r == tb.headerRows and r > 0)
          let bottom = tb.inner or r == rows.high or tb.rowLines or (r == tb.headerRows - 1)
          let left = tb.inner or c == 0
          let right = tb.inner or c == ncol - 1
          for (name, on, side) in [("Top", top, 0), ("Bottom", bottom, 2), ("Left", left, 3), ("Right", right, 1)]:
            let own = cf.strokes[side]
            if own.on: continue
            edges.add " " & name & "EdgeStrokeWeight=\"" & (if on: f(lineW) else: "0") & "\""
            if on: edges.add " " & name & "EdgeStrokeColor=\"" & o.colorRef(tb.border) & "\""
        # (its own sides, inset, place up and down, turn)
        for (name, side) in [("Top", 0), ("Bottom", 2), ("Left", 3), ("Right", 1)]:
          let own = cf.strokes[side]
          if not own.on: continue
          edges.add " " & name & "EdgeStrokeWeight=\"" & f(own.width.float * k) & "\""
          if own.width > 0 and own.color != 0: edges.add " " & name & "EdgeStrokeColor=\"" & o.colorRef(own.color) & "\""
        if cf.inset != [0'f32, 0, 0, 0]:
          for (name, side) in [("Top", 0), ("Right", 1), ("Bottom", 2), ("Left", 3)]:
            edges.add " " & name & "Inset=\"" & f(cf.inset[side].float * k) & "\""
        if cf.vAlign != vjTop: edges.add " VerticalJustification=\"" & VertJusts[cf.vAlign] & "\""
        if cf.rotation != 0: edges.add " RotationAngle=\"" & $cf.rotation & "\""
        let fill = if cf.fill != 0: cf.fill else: fillC
        var content = ""
        var first = true
        for para in cell.text.split("\u2029"):
          if not first: content.add "<Br/>\n"
          first = false
          content.add "<Content>" & x(para) & "</Content>\n"
        body.add "<Cell Self=\"" & tid & "i" & $r & "_" & $c & "\" Name=\"" & $c & ":" & $r &
                 "\" RowSpan=\"" & $max(1, cf.rowSpan) & "\" ColumnSpan=\"" & $max(1, cf.colSpan) &
                 "\" AppliedCellStyle=\"CellStyle/$ID/[None]\"" &
                 (if fill != 0: " FillColor=\"" & o.colorRef(fill) & "\"" else: "") & edges & ">\n" &
                 "<ParagraphStyleRange AppliedParagraphStyle=\"ParagraphStyle/$ID/NormalParagraphStyle\"" &
                 (if tb.numbersRight and looksNumeric(newText(cell.text)): " Justification=\"RightAlign\"" else: "") & ">\n" &
                 csrOpen(o, st) & content & "</CharacterStyleRange>\n" &
                 "</ParagraphStyleRange>\n</Cell>\n"
    body.add "</Table>\n</CharacterStyleRange>\n"
  for sp in (if t.table.on: @[] else: t.spans):
    let st = sp.style
    body.add csrOpen(o, st)
    # (a hyperlink: its text a source of it; a destination: written where it starts)
    var linkSrc = ""
    if not master and st.link.len > 0:
      let lo = o.linkOpen(st.link)
      if lo.startsWith("<HyperlinkTextSource"): linkSrc = lo
      body.add lo
    # its text: paragraphs apart (<Br/>), the page number the program's own on a master
    var piece = ""
    proc flush(body: var string; piece: var string) =
      if piece.len > 0:
        body.add "<Content>" & x(piece) & "</Content>\n"
        piece = ""
    var i = 0
    let s = sp.text
    while i < s.len:
      if s[i] == '\n':
        flush(body, piece)
        body.add "<Br/>\n"
        inc i
        inc paraNo
        if paraNo < paraFmt.len and paraFmt[paraNo] != paraFmt[paraNo - 1] and
           t.fmtOf(paraFmt[paraNo]) != t.fmtOf(paraFmt[paraNo - 1]):
          # (the next paragraph in a format of its own)
          body.add (if linkSrc.len > 0: "</HyperlinkTextSource>\n" else: "") &
                   "</CharacterStyleRange>\n</ParagraphStyleRange>\n" & psrOpen(o, t.fmtOf(paraFmt[paraNo])) &
                   csrOpen(o, st)
          if linkSrc.len > 0:
            linkSrc = o.linkOpen(st.link)
            body.add linkSrc
      elif s[i] == '\b':
        # (a Right Indent Tab: the layout program's own character)
        flush(body, piece)
        body.add "<Content><?ACE 8?></Content>\n"
        inc i
      elif master and s.continuesWith("<##>", i):
        flush(body, piece)
        body.add "<Content><?ACE 18?></Content>\n"
        i += 4
      elif master and s.continuesWith("<#>", i):
        flush(body, piece)
        body.add "<Content><?ACE 18?></Content>\n"
        i += 3
      elif s[i] == '\xF3' and isNoteMark(int(s.runeAt(i))):
        # (a footnote: its number the program's own, its text in it)
        flush(body, piece)
        let nid = int(s.runeAt(i)) - 0xF0000
        var nt = ""
        for n in t.notes:
          if n.id == nid: nt = n.text
        body.add "<Footnote><ParagraphStyleRange AppliedParagraphStyle=\"ParagraphStyle/$ID/NormalParagraphStyle\">" &
                 "<CharacterStyleRange AppliedCharacterStyle=\"CharacterStyle/$ID/[No character style]\">" &
                 "<Content><?ACE 4?></Content><Content>" & x(" " & nt) & "</Content></CharacterStyleRange>" &
                 "</ParagraphStyleRange></Footnote>\n"
        i += s.runeLenAt(i)
      else:
        piece.add s[i]
        inc i
    flush(body, piece)
    if linkSrc.len > 0: body.add "</HyperlinkTextSource>\n"
    body.add "</CharacterStyleRange>\n"
  body.add "</ParagraphStyleRange>\n"
  o.stories.add (id, "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" &
    "<idPkg:Story xmlns:idPkg=\"http://ns.adobe.com/AdobeInDesign/idml/1.0/packaging\" DOMVersion=\"8.0\">\n" &
    "<Story Self=\"" & id & "\" AppliedTOCStyle=\"n\" TrackChanges=\"false\" StoryTitle=\"$ID/\" " &
    "AppliedNamedGrid=\"n\">\n<StoryPreference OpticalMarginAlignment=\"" & $t0.opticalMargin & "\" OpticalMarginSize=\"" &
    f(float(if t0.spans.len > 0: t0.spans[0].style.size else: 12'f32) * k) & "\" " &
    "FrameType=\"TextFrameType\" StoryOrientation=\"Horizontal\" StoryDirection=\"" &
    (if rtl: "RightToLeftDirection" else: "LeftToRightDirection") & "\"/>\n" & body & "</Story>\n</idPkg:Story>\n")
  id

proc geometry(pts: seq[tuple[a, l, r: (float, float)]]; closed = true): string =
  result = "<Properties><PathGeometry><GeometryPathType PathOpen=\"" & (if closed: "false" else: "true") &
           "\"><PathPointArray>\n"
  for p in pts:
    result.add "<PathPointType Anchor=\"" & f(p.a[0]) & " " & f(p.a[1]) & "\" LeftDirection=\"" & f(p.l[0]) & " " &
               f(p.l[1]) & "\" RightDirection=\"" & f(p.r[0]) & " " & f(p.r[1]) & "\"/>\n"
  result.add "</PathPointArray></GeometryPathType></PathGeometry></Properties>\n"

proc boxGeometry(x0, y0, x1, y1: float): string =
  geometry(@[((x0, y0), (x0, y0), (x0, y0)), ((x0, y1), (x0, y1), (x0, y1)), ((x1, y1), (x1, y1), (x1, y1)),
             ((x1, y0), (x1, y0), (x1, y0))])

type Thread = tuple[self, prev, next, story: string; own: bool]
  ## (a text frame's place in its thread: its Self, the frames before and after it ("n": none),
  ## its story's Self, and whether the story is written with it -- the first frame's)

proc writtenFrame(L: Layer): bool =
  ## (the layer is written as a text frame of its own)
  L.isText and L.visible and not L.group and L.fromMaster == 0 and L.fromSpan == 0 and L.mode == bmNormal and
    not L.hasStyle and not L.clipped and (L.mask == nil or L.maskOff) and L.text.boxW > 0 and
    L.text.path.len == 0

proc frameSelf(page, uid: int): string = "tf" & $page & "x" & $uid
proc storySelf(page, uid: int): string = "st" & $page & "x" & $uid

const
  WrapModes = ["None", "BoundingBoxTextWrap", "Contour", "JumpObjectTextWrap", "NextColumnTextWrap"]
    ## (IDML's TextWrapMode for each of `Layer.wrap`)
  WrapSides = ["BothSides", "LeftSide", "RightSide", "LargestArea", "SideTowardsSpine", "SideAwayFromSpine"]
    ## (... and TextWrapSide for each of `wrapSide`)

const ContourTypes = ["AlphaChannel", "DetectEdges", "PhotoshopPath"]
  ## (IDML's ContourType for each of `WrapOptions.contour`: its pixels, its edges, a path)

proc wrapPrefXml(wrap, side: int; o: array[4, float32]; invert: bool; contour = 0; path = ""): string =
  ## (Text Wrap as IDML has it: its kind, side, whether the text is inside it, its offsets in
  ## points, and round its shape where its outline comes from)
  if wrap == 0: return ""
  "<TextWrapPreference Inverse=\"" & (if invert: "true" else: "false") & "\" TextWrapSide=\"" &
    WrapSides[clamp(side, 0, 5)] & "\" TextWrapMode=\"" & WrapModes[clamp(wrap, 0, 4)] & "\">\n" &
    "<Properties><TextWrapOffset Top=\"" & f(o[0]) & "\" Left=\"" & f(o[2]) & "\" Bottom=\"" & f(o[1]) &
    "\" Right=\"" & f(o[3]) & "\"/></Properties>\n" &
    (if wrap == 2:
       "<ContourOption ContourType=\"" & ContourTypes[clamp(contour, 0, 2)] & "\"" &
         (if contour == 2 and path.len > 0: " ContourPathName=\"" & x(path) & "\"" else: "") & "/>\n"
     else: "") & "</TextWrapPreference>\n"

proc wrapXml(d: Doc; L: Layer): string =
  ## (a layer's Text Wrap; a file before the offsets: its gap on every side)
  var o = L.wrapOpts.offsets
  if o == [0'f32, 0, 0, 0] and L.wrapGap > 0:
    let g = float32(L.wrapGap) * 72 / float32(max(1.0, d.dpi))
    o = [g, g, g, g]
  wrapPrefXml(L.wrap, L.wrapSide, o, L.wrapOpts.invert, L.wrapOpts.contour, L.wrapOpts.contourPath)

proc objRef(o: var IdmlOut; d: Doc; name: string; k: float): string =
  ## (a frame's Object Style: its name on the frame, its fill and stroke in Styles.xml)
  if name.len == 0: return ""
  if name notin o.objStyles:
    var attrs = ""
    let i = d.objectStyleIndex(name)
    if i >= 0:
      let os = d.objectStyles[i]
      if os.useFill:
        attrs.add " EnableFill=\"true\" FillColor=\"" &
                  (if os.shape.fill.kind == spColor: o.colorRef(os.shape.fill.color) else: "Swatch/None") & "\""
      if os.useStroke:
        attrs.add " EnableStroke=\"true\" StrokeColor=\"" &
                  (if os.shape.stroke.kind == spColor and os.shape.strokeWidth > 0: o.colorRef(os.shape.stroke.color)
                   else: "Swatch/None") & "\" StrokeWeight=\"" & f(os.shape.strokeWidth * k) & "\""
      if os.useFrame:
        attrs.add " EnableTextFrameGeneralOptions=\"true\""
      if os.useParagraph and os.paraStyle.len > 0:
        attrs.add " EnableParagraphStyle=\"true\""
      if os.useWrap:
        attrs.add " EnableTextWrapAndOthers=\"true\"\x01" & wrapPrefXml(os.wrap, os.wrapSide, os.wrapOpts.offsets,
                                                                       os.wrapOpts.invert, os.wrapOpts.contour,
                                                                       os.wrapOpts.contourPath)
    o.objStyles[name] = attrs
  " AppliedObjectStyle=\"ObjectStyle/" & x(name) & "\""

proc itemsOf(o: var IdmlOut; d: Doc; ox, oy, k: float; master: bool; name: string;
             threads: proc (L: Layer; fresh: string): Thread = nil): string =
  ## (a page's layers as the spread's items: from `ox`, `oy` points, `k` points a pixel; text
  ## frames threaded as `threads` says)
  template P(px, py: float): (float, float) = (ox + px * k, oy + py * k)
  for n, L in d.layers:
    if not L.visible or L.group or L.adjust.kind.len > 0: continue
    if L.fromMaster != 0 or (not master and L.fromSpan != 0): continue
      # (a master's layers on a page, a parent master's on a master: written with that master)
    let plain = L.mode == bmNormal and not L.hasStyle and not L.clipped and (L.mask == nil or L.maskOff)
    let op = if L.opacity < 100: "<TransparencySetting><BlendingSetting Opacity=\"" & $L.opacity &
                                 "\"/></TransparencySetting>\n" else: ""
    if L.isText and plain:
      let t = if master: L.text else: d.effectiveText(L)    # (a master's page number as its mark)
      let lay = layoutText(t)
      var (x0, y0, x1, y1) = (t.x.float, t.y.float, float(t.x + t.boxW), float(t.y + t.boxH))
      if t.boxW <= 0 or t.boxH <= 0:
        # (point text: a frame round where its letters are)
        x0 = lay.x0.float - 2
        y0 = lay.y0.float - 2
        x1 = lay.x1.float + 6
        y1 = lay.y1.float + 4
      let th: Thread = if threads != nil and not master: threads(L, o.uid("t")) else: (o.uid("t"), "n", "n", "", true)
      let sid = if th.own: o.storyOf(t, k, master, th.story) else: th.story
      let (a, b) = (P(x0, y0), P(x1, y1))
      result.add "<TextFrame Self=\"" & th.self & "\" ParentStory=\"" & sid & "\" PreviousTextFrame=\"" & th.prev &
                 "\" NextTextFrame=\"" & th.next & "\" ContentType=\"TextType\" Name=\"" & x(L.name) &
                 "\"" & o.objRef(d, L.objectStyle, k) & " ItemTransform=\"1 0 0 1 0 0\">\n" &
                 boxGeometry(a[0], a[1], b[0], b[1]) & op &
                 wrapXml(d, L) &
                 "<TextFramePreference TextColumnCount=\"" & $max(1, t.columns) & "\" TextColumnGutter=\"" &
                 f((if t.gutter > 0: t.gutter else: 12'f32) * k) & "\" VerticalJustification=\"" &
                 VertJusts[t.vjust] & "\"" & (if t.balance: " VerticalBalanceColumns=\"true\"" else: "") &
                 (if L.ignoreWrap: " IgnoreWrap=\"true\"" else: "") &
                 (if t.firstBase != fbAscent: " FirstBaselineOffset=\"" & FirstBases[t.firstBase] & "\"" else: "") &
                 (if t.firstMin > 0: " MinimumFirstBaselineOffset=\"" & f(t.firstMin * k) & "\"" else: "") &
                 (case t.colMode
                  of cmFixedWidth: " UseFixedColumnWidth=\"true\" TextColumnFixedWidth=\"" & f(t.colWidth * k) & "\""
                  of cmFlexible: " UseFlexibleColumnWidth=\"true\" TextColumnMaxWidth=\"" & f(t.colWidth * k) & "\""
                  of cmNumber: "") &
                 (if t.autoSize != asOff: " AutoSizingType=\"" & AutoSizing[t.autoSize] & "\" AutoSizingReferencePoint=\"" &
                                         RefPoints[clamp(t.autoRef, 0, 8)] & "\"" else: "") &
                 (if t.inset == [0'f32, 0, 0, 0]: "/>\n"
                  else: "><Properties><InsetSpacing type=\"list\"><ListItem type=\"unit\">" & f(t.inset[0] * k) &
                        "</ListItem><ListItem type=\"unit\">" & f(t.inset[3] * k) & "</ListItem><ListItem type=\"unit\">" &
                        f(t.inset[2] * k) & "</ListItem><ListItem type=\"unit\">" & f(t.inset[1] * k) &
                        "</ListItem></InsetSpacing></Properties></TextFramePreference>\n") &
                 "</TextFrame>\n"
    elif L.isShape and plain and L.shape.fill.kind in {spNone, spColor, spGradient}:
      let s = L.shape
      var geo = ""
      var subs = 0
      for sp in s.path.subs:
        if sp.pts.len < 2: continue
        inc subs
        var pts: seq[tuple[a, l, r: (float, float)]]
        for q in sp.pts: pts.add (P(q.p[0], q.p[1]), P(q.inH[0], q.inH[1]), P(q.outH[0], q.outH[1]))
        geo.add (if subs == 1: "" else: "") & "<GeometryPathType PathOpen=\"" & (if sp.closed: "false" else: "true") &
                "\"><PathPointArray>\n"
        for p in pts:
          geo.add "<PathPointType Anchor=\"" & f(p.a[0]) & " " & f(p.a[1]) & "\" LeftDirection=\"" & f(p.l[0]) & " " &
                  f(p.l[1]) & "\" RightDirection=\"" & f(p.r[0]) & " " & f(p.r[1]) & "\"/>\n"
        geo.add "</PathPointArray></GeometryPathType>\n"
      if subs == 0: continue
      let fill = if s.fill.kind == spColor: o.colorRef(s.fill.color)
                 elif s.fill.kind == spGradient: o.colorRef(s.fill.color) else: "Swatch/None"
      let stroke = if s.stroke.kind == spColor and s.strokeWidth > 0: o.colorRef(s.stroke.color) else: "Swatch/None"
      let tag = if s.kind == "Ellipse": "Oval" elif s.kind == "Rectangle": "Rectangle" else: "Polygon"
      result.add "<" & tag & " Self=\"" & o.uid("p") & "\" ContentType=\"Unassigned\" Name=\"" & x(L.name) &
                 "\"" & o.objRef(d, L.objectStyle, k) & " FillColor=\"" & fill & "\" StrokeColor=\"" & stroke & "\" StrokeWeight=\"" &
                 f(s.strokeWidth * k) & "\" ItemTransform=\"1 0 0 1 0 0\">\n" &
                 "<Properties><PathGeometry>" & geo & "</PathGeometry></Properties>\n" & op & wrapXml(d, L) &
                 "</" & tag & ">\n"
    else:
      # (anything else -- pixels, a Smart Object, what has a style or a mode -- as a picture of it)
      let box = d.layerBox(L).intersect(d.bounds)
      if box.w <= 0 or box.h <= 0: continue
      var pic = newBitmap(box.w, box.h)
      var op = op
      if plain and L.px.len == d.w * d.h:
        # (its own pixels, as they are: its opacity the frame's)
        for y in 0 ..< box.h:
          copyMem(addr pic.px[y * box.w], addr L.px[(box.y + y) * d.w + box.x], box.w * 4)
        # (one color all over -- a page's paper, a flat band: a frame filled with it, no picture)
        let c0 = pic.px[0]
        var flat = (c0 shr 24) == 255
        if flat:
          for c in pic.px:
            if c != c0:
              flat = false
              break
        if flat:
          if L.background and (c0 and 0xFFFFFF'u32) == 0xFFFFFF'u32: continue    # (white paper: the page's own)
          let (a, b) = (P(box.x.float, box.y.float), P(float(box.x + box.w), float(box.y + box.h)))
          result.add "<Rectangle Self=\"" & o.uid("r") & "\" ContentType=\"Unassigned\" Name=\"" & x(L.name) &
                     "\" FillColor=\"" & o.colorRef(c0) & "\" StrokeColor=\"Swatch/None\" ItemTransform=\"1 0 0 1 0 0\">\n" &
                     boxGeometry(a[0], a[1], b[0], b[1]) & op & wrapXml(d, L) & "</Rectangle>\n"
          continue
      else:
        # (with its mode, style, mask or clipping: how it looks, alone -- its opacity in it)
        op = ""
        var shown: seq[bool]
        for M in d.layers: shown.add M.visible
        for j, M in d.layers: M.visible = j == n or (M.group and j > n)
        try:
          d.markAll()
          let full = d.toBitmap(0'u32)
          for y in 0 ..< box.h:
            copyMem(addr pic.px[y * box.w], addr full.px[(box.y + y) * d.w + box.x], box.w * 4)
        finally:
          for j, M in d.layers: M.visible = shown[j]
          d.markAll()
      let file = name & "-" & $o.links.len & ".png"
      o.links.add (file, encodePng(pic, dpi = int(d.dpi + 0.5)))
      let (a, b) = (P(box.x.float, box.y.float), P(float(box.x + box.w), float(box.y + box.h)))
      let sx = (b[0] - a[0]) / box.w.float
      let sy = (b[1] - a[1]) / box.h.float
      let uri = "file:" & (o.linksDir / file).replace('\\', '/')
      result.add "<Rectangle Self=\"" & o.uid("r") & "\" ContentType=\"GraphicType\" Name=\"" & x(L.name) &
                 "\" FillColor=\"Swatch/None\" StrokeColor=\"Swatch/None\" ItemTransform=\"1 0 0 1 0 0\">\n" &
                 boxGeometry(a[0], a[1], b[0], b[1]) & op & wrapXml(d, L) &
                 "<Image Self=\"" & o.uid("i") & "\" ItemTransform=\"" & f(sx) & " 0 0 " & f(sy) & " " & f(a[0]) & " " &
                 f(a[1]) & "\">\n<Properties><Profile type=\"string\">$ID/None</Profile><GraphicBounds Left=\"0\" " &
                 "Top=\"0\" Right=\"" & $box.w & "\" Bottom=\"" & $box.h & "\"/></Properties>\n" &
                 "<Link Self=\"" & o.uid("l") & "\" LinkResourceURI=\"" & x(uri) & "\" StoredState=\"Normal\"/>\n" &
                 "</Image>\n</Rectangle>\n"

proc resources(o: var IdmlOut; pageW, pageH: float; pages: int; facing, rtl: bool; margins: array[4, float];
               cols: int; gutter: float): seq[(string, string)] =
  const head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
  const ns = "xmlns:idPkg=\"http://ns.adobe.com/AdobeInDesign/idml/1.0/packaging\" DOMVersion=\"8.0\""
  # (the character styles nested, GREP and line styles name, and the Object Styles, first: their
  # colors and fonts go into the lists below)
  var charXml, objXml = ""
  for name, st in o.charStyles:
    let fam = if st.family.len > 0: st.family else: "FreeSans"
    let sty = if st.style.len > 0: st.style elif st.fauxBold: "Bold" else: "Regular"
    o.fontRef(fam, sty)
    charXml.add "<CharacterStyle Self=\"CharacterStyle/" & x(name) & "\" Imported=\"false\" Name=\"" & x(name) &
                "\" FontStyle=\"" & x(sty) & "\" PointSize=\"" & f(max(0.1, st.size * o.k)) & "\" FillColor=\"" &
                o.colorRef(st.color) & "\"" & (if st.underline: " Underline=\"true\"" else: "") &
                (if st.allCaps: " Capitalization=\"AllCaps\"" elif st.smallCaps: " Capitalization=\"SmallCaps\"" else: "") &
                "><Properties><AppliedFont type=\"string\">" & x(fam) & "</AppliedFont></Properties></CharacterStyle>\n"
  for name, attrs in o.objStyles:
    let parts = attrs.split('\x01')
    objXml.add "<ObjectStyle Self=\"ObjectStyle/" & x(name) & "\" Name=\"" & x(name) & "\"" & parts[0] &
               (if parts.len > 1 and parts[1].len > 0: ">\n" & parts[1] & "</ObjectStyle>\n" else: "/>\n")
  var g = head & "<idPkg:Graphic " & ns & ">\n" &
    "<Color Self=\"Color/Black\" Model=\"Process\" Space=\"CMYK\" ColorValue=\"0 0 0 100\" ColorOverride=\"Specialblack\" " &
    "AlternateSpace=\"NoAlternateColor\" AlternateColorValue=\"\" Name=\"Black\" ColorEditable=\"false\" " &
    "ColorRemovable=\"false\" Visible=\"true\" SwatchCreatorID=\"7937\"/>\n" &
    "<Color Self=\"Color/Paper\" Model=\"Process\" Space=\"CMYK\" ColorValue=\"0 0 0 0\" ColorOverride=\"Specialpaper\" " &
    "AlternateSpace=\"NoAlternateColor\" AlternateColorValue=\"\" Name=\"Paper\" ColorEditable=\"true\" " &
    "ColorRemovable=\"false\" Visible=\"true\" SwatchCreatorID=\"7937\"/>\n" &
    "<Color Self=\"Color/Registration\" Model=\"Registration\" Space=\"CMYK\" ColorValue=\"100 100 100 100\" " &
    "ColorOverride=\"Specialregistration\" AlternateSpace=\"NoAlternateColor\" AlternateColorValue=\"\" " &
    "Name=\"Registration\" ColorEditable=\"false\" ColorRemovable=\"false\" Visible=\"true\" SwatchCreatorID=\"7937\"/>\n"
  for rgb, self in o.colors:
    g.add "<Color Self=\"" & self & "\" Model=\"Process\" Space=\"RGB\" ColorValue=\"" & $((rgb shr 16) and 255) & " " &
          $((rgb shr 8) and 255) & " " & $(rgb and 255) & "\" ColorOverride=\"Normal\" AlternateSpace=\"NoAlternateColor\" " &
          "AlternateColorValue=\"\" Name=\"" & self[6 .. ^1] & "\" ColorEditable=\"true\" ColorRemovable=\"true\" " &
          "Visible=\"true\" SwatchCreatorID=\"7937\"/>\n"
  g.add "<Swatch Self=\"Swatch/None\" Name=\"None\" ColorEditable=\"false\" ColorRemovable=\"false\" Visible=\"true\" " &
        "SwatchCreatorID=\"7937\"/>\n" &
        "<StrokeStyle Self=\"StrokeStyle/$ID/Solid\" Name=\"$ID/Solid\"/>\n</idPkg:Graphic>\n"
  var fo = head & "<idPkg:Fonts " & ns & ">\n"
  for fam, styles in o.fonts:
    fo.add "<FontFamily Self=\"di" & toHex(hash(fam).int and 0xFFFFFF, 6).toLowerAscii & "\" Name=\"" & x(fam) & "\">\n"
    for st in styles:
      fo.add "<Font Self=\"di" & toHex(hash(fam & st).int and 0xFFFFFF, 6).toLowerAscii & "\" FontFamily=\"" & x(fam) &
             "\" Name=\"" & x(fam & " " & st) & "\" PostScriptName=\"" & x(fam.replace(" ", "") & "-" &
             st.replace(" ", "")) & "\" Status=\"Installed\" FontStyleName=\"" & x(st) & "\" FontType=\"OpenTypeTT\" " &
             "WritingScript=\"0\" FullName=\"" & x(fam & " " & st) & "\" FullNameNative=\"" & x(fam & " " & st) &
             "\" FontStyleNameNative=\"" & x(st) & "\" PlatformName=\"$ID/\" Version=\"1.0\"/>\n"
    fo.add "</FontFamily>\n"
  fo.add "</idPkg:Fonts>\n"
  let st = head & "<idPkg:Styles " & ns & ">\n" &
    "<RootCharacterStyleGroup Self=\"u79\">\n<CharacterStyle Self=\"CharacterStyle/$ID/[No character style]\" " &
    "Imported=\"false\" Name=\"$ID/[No character style]\"/>\n" & charXml & "</RootCharacterStyleGroup>\n" &
    "<RootParagraphStyleGroup Self=\"u78\">\n<ParagraphStyle Self=\"ParagraphStyle/$ID/[No paragraph style]\" " &
    "Name=\"$ID/[No paragraph style]\" Imported=\"false\" PointSize=\"12\"/>\n" &
    "<ParagraphStyle Self=\"ParagraphStyle/$ID/NormalParagraphStyle\" Name=\"$ID/NormalParagraphStyle\" " &
    "Imported=\"false\" NextStyle=\"ParagraphStyle/$ID/NormalParagraphStyle\">\n<Properties>" &
    "<BasedOn type=\"object\">ParagraphStyle/$ID/[No paragraph style]</BasedOn></Properties>\n</ParagraphStyle>\n" &
    "</RootParagraphStyleGroup>\n<RootCellStyleGroup Self=\"u8e\">\n<CellStyle Self=\"CellStyle/$ID/[None]\" " &
    "Name=\"$ID/[None]\"/>\n</RootCellStyleGroup>\n<RootTableStyleGroup Self=\"u90\">\n" &
    "<TableStyle Self=\"TableStyle/$ID/[No table style]\" Name=\"$ID/[No table style]\"/>\n" &
    "<TableStyle Self=\"TableStyle/$ID/[Basic Table]\" Name=\"$ID/[Basic Table]\"/>\n</RootTableStyleGroup>\n" &
    "<RootObjectStyleGroup Self=\"u98\">\n<ObjectStyle Self=\"ObjectStyle/$ID/[None]\" Name=\"$ID/[None]\"/>\n" &
    "<ObjectStyle Self=\"ObjectStyle/$ID/[Normal Graphics Frame]\" Name=\"$ID/[Normal Graphics Frame]\"/>\n" &
    "<ObjectStyle Self=\"ObjectStyle/$ID/[Normal Text Frame]\" Name=\"$ID/[Normal Text Frame]\"/>\n" & objXml &
    "</RootObjectStyleGroup>\n</idPkg:Styles>\n"
  let pr = head & "<idPkg:Preferences " & ns & ">\n" &
    "<DocumentPreference PageHeight=\"" & f(pageH) & "\" PageWidth=\"" & f(pageW) & "\" PagesPerDocument=\"" & $pages &
    "\" FacingPages=\"" & $facing & "\" DocumentBleedTopOffset=\"0\" DocumentBleedBottomOffset=\"0\" " &
    "DocumentBleedInsideOrLeftOffset=\"0\" DocumentBleedOutsideOrRightOffset=\"0\" PageBinding=\"" &
    (if rtl: "RightToLeft" else: "LeftToRight") & "\" ColumnDirection=\"Horizontal\" Intent=\"PrintIntent\"/>\n" &
    "<MarginPreference ColumnCount=\"" & $max(1, cols) & "\" ColumnGutter=\"" & f(gutter) & "\" Top=\"" & f(margins[0]) &
    "\" Bottom=\"" & f(margins[1]) & "\" Left=\"" & f(margins[2]) & "\" Right=\"" & f(margins[3]) &
    "\" ColumnDirection=\"Horizontal\" ColumnsPositions=\"0 " & f(pageW - margins[2] - margins[3]) & "\"/>\n" &
    "<ViewPreference HorizontalMeasurementUnits=\"Millimeters\" VerticalMeasurementUnits=\"Millimeters\"/>\n" &
    "</idPkg:Preferences>\n"
  @[("Resources/Graphic.xml", g), ("Resources/Fonts.xml", fo), ("Resources/Styles.xml", st),
    ("Resources/Preferences.xml", pr)]

proc package(o: var IdmlOut; spreads, masters: seq[(string, string)]; res: seq[(string, string)];
             pages: int; firstPage: string): string =
  const head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
  const ns = "xmlns:idPkg=\"http://ns.adobe.com/AdobeInDesign/idml/1.0/packaging\" DOMVersion=\"8.0\""
  var storyList = ""
  for (id, _) in o.stories: storyList.add (if storyList.len > 0: " " else: "") & id
  var dm = head & "<?aid style=\"50\" type=\"document\" readerVersion=\"6.0\" featureSet=\"257\" product=\"8.0(370)\" ?>\n" &
           "<Document " & ns & " Self=\"d\" StoryList=\"" & storyList & "\" ZeroPoint=\"0 0\" ActiveLayer=\"ub\" " &
           "CMYKProfile=\"Coated FOGRA39 (ISO 12647-2:2004)\" RGBProfile=\"sRGB IEC61966-2.1\" " &
           "SolidColorIntent=\"UseColorSettings\" AfterBlendingIntent=\"UseColorSettings\" " &
           "DefaultImageIntent=\"UseColorSettings\" RGBPolicy=\"PreserveEmbeddedProfiles\" " &
           "CMYKPolicy=\"CombinationOfPreserveAndSafeCmyk\" AccurateLABSpots=\"false\">\n"
  for (path, _) in res:
    let tag = path.splitFile.name
    dm.add "<idPkg:" & tag & " src=\"" & path & "\"/>\n"
  dm.add "<Layer Self=\"ub\" Name=\"Layer 1\" Visible=\"true\" Locked=\"false\" IgnoreWrap=\"false\" ShowGuides=\"true\" " &
         "LockGuides=\"false\" UI=\"true\" Expendable=\"true\" Printable=\"true\"><Properties><LayerColor type=\"enumeration\">" &
         "LightBlue</LayerColor></Properties></Layer>\n"
  for (path, _) in masters: dm.add "<idPkg:MasterSpread src=\"" & path & "\"/>\n"
  for (path, _) in spreads: dm.add "<idPkg:Spread src=\"" & path & "\"/>\n"
  dm.add "<Section Self=\"usec\" Length=\"" & $pages & "\" Name=\"\" ContinueNumbering=\"true\" IncludeSectionPrefix=\"false\" " &
         "PageNumberStyle=\"Arabic\" PageStart=\"" & firstPage & "\" SectionPrefix=\"\"/>\n" &
         "<idPkg:BackingStory src=\"XML/BackingStory.xml\"/>\n"
  for (id, _) in o.stories: dm.add "<idPkg:Story src=\"Stories/Story_" & id & ".xml\"/>\n"
  dm.add o.hyper                       # (hyperlinks, where they go, bookmarks)
  dm.add "</Document>\n"
  var z = newZipWriter()
  z.addFile("mimetype", "application/vnd.adobe.indesign-idml-package", compress = false)
  z.addFile("designmap.xml", dm)
  z.addFile("META-INF/container.xml", head & "<container version=\"1.0\" " &
            "xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\">\n<rootfiles>\n" &
            "<rootfile full-path=\"designmap.xml\" media-type=\"text/xml\"/>\n</rootfiles>\n</container>\n")
  for (path, data) in res: z.addFile(path, data)
  for (path, data) in masters: z.addFile(path, data)
  for (path, data) in spreads: z.addFile(path, data)
  for (id, data) in o.stories: z.addFile("Stories/Story_" & id & ".xml", data)
  z.addFile("XML/BackingStory.xml", head & "<idPkg:BackingStory " & ns & ">\n<XmlStory Self=\"ui\" " &
            "AppliedTOCStyle=\"n\" TrackChanges=\"false\" StoryTitle=\"$ID/\" AppliedNamedGrid=\"n\">\n" &
            "<ParagraphStyleRange AppliedParagraphStyle=\"ParagraphStyle/$ID/NormalParagraphStyle\">\n" &
            "<CharacterStyleRange AppliedCharacterStyle=\"CharacterStyle/$ID/[No character style]\"/>\n" &
            "</ParagraphStyleRange>\n</XmlStory>\n</idPkg:BackingStory>\n")
  z.addFile("XML/Tags.xml", head & "<idPkg:Tags " & ns & ">\n<XMLTag Self=\"XMLTag/Root\" Name=\"Root\">\n" &
            "<Properties><TagColor type=\"enumeration\">LightBlue</TagColor></Properties>\n</XMLTag>\n</idPkg:Tags>\n")
  z.finish()

proc spreadXml(self, items, pagesXml: string; pageCount: int; master: bool; name = "A"): string =
  const head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
  const ns = "xmlns:idPkg=\"http://ns.adobe.com/AdobeInDesign/idml/1.0/packaging\" DOMVersion=\"8.0\""
  if master:
    head & "<idPkg:MasterSpread " & ns & ">\n<MasterSpread Self=\"" & self & "\" ItemTransform=\"1 0 0 1 0 0\" " &
      "Name=\"" & x(name) & "-Master\" NamePrefix=\"" & x(name) & "\" BaseName=\"Master\" ShowMasterItems=\"true\" " &
      "PageCount=\"" & $pageCount & "\" OverriddenPageItemProps=\"\">\n" & pagesXml & items &
      "</MasterSpread>\n</idPkg:MasterSpread>\n"
  else:
    head & "<idPkg:Spread " & ns & ">\n<Spread Self=\"" & self & "\" PageTransitionType=\"None\" " &
      "PageTransitionDirection=\"NotApplicable\" PageTransitionDuration=\"Medium\" ShowMasterItems=\"true\" " &
      "PageCount=\"" & $pageCount & "\" BindingLocation=\"" & $(if pageCount > 1: 1 else: 0) & "\" " &
      "AllowPageShuffle=\"true\" ItemTransform=\"1 0 0 1 0 0\" FlattenerOverride=\"Default\">\n" & pagesXml & items &
      "</Spread>\n</idPkg:Spread>\n"

proc pageXml(self, name, master: string; w, h, tx, ty: float; margins: array[4, float]; cols: int;
             gutter: float): string =
  "<Page Self=\"" & self & "\" AppliedTrapPreset=\"TrapPreset/$ID/kDefaultTrapStyleName\" Name=\"" & x(name) &
    "\" AppliedMaster=\"" & master & "\" OverrideList=\"\" TabOrder=\"\" GridStartingPoint=\"TopOutside\" " &
    "UseMasterGrid=\"true\" GeometricBounds=\"0 0 " & f(h) & " " & f(w) & "\" ItemTransform=\"1 0 0 1 " & f(tx) & " " &
    f(ty) & "\" MasterPageTransform=\"1 0 0 1 0 0\">\n<MarginPreference ColumnCount=\"" & $max(1, cols) &
    "\" ColumnGutter=\"" & f(gutter) & "\" Top=\"" & f(margins[0]) & "\" Bottom=\"" & f(margins[1]) & "\" Left=\"" &
    f(margins[2]) & "\" Right=\"" & f(margins[3]) & "\" ColumnDirection=\"Horizontal\" ColumnsPositions=\"0 " &
    f(w - margins[2] - margins[3]) & "\"/>\n</Page>\n"

proc threadOf(d: Doc; L: Layer; fresh: string): Thread =
  ## (a frame of one document: threaded to the frames of the same page)
  if not L.writtenFrame: return (fresh, "n", "n", "", true)
  # (the whole thread written, or none of it threaded)
  let H = d.storyHead(L)
  if H.flowFrom != 0 or not H.writtenFrame: return (fresh, "n", "n", "", true)
  var B = H
  var n = 0
  while n < 64:
    inc n
    let C = d.followerOf(B)
    if C == nil: break
    if not C.writtenFrame: return (fresh, "n", "n", "", true)
    B = C
  if n == 1: return (fresh, "n", "n", "", true)          # (alone)
  let N = d.followerOf(L)
  result.self = frameSelf(0, uidOf(L))
  result.prev = if L.flowFrom != 0: frameSelf(0, L.flowFrom) else: "n"
  result.next = if N != nil: frameSelf(0, uidOf(N)) else: "n"
  result.story = storySelf(0, uidOf(H))
  result.own = L == H

proc threadOf(b: Book; i: int; L: Layer; fresh: string): Thread =
  ## (a frame of page `i`: threaded to the frames of its thread, on this page and the others)
  if not L.writtenFrame or (L.flowFrom == 0 and not b.doc(i).flowsOn(L)): return (fresh, "n", "n", "", true)
  let (hp, H) = b.storyStart(i, L)
  if H.flowFrom != 0 or not H.writtenFrame: return (fresh, "n", "n", "", true)
  # (every frame of the thread written, from the first)
  var at = (hp, H)
  var n = 0
  while n < MaxBookPages:
    inc n
    let d = b.doc(at[0])
    var nx = d.followerOf(at[1])
    var np = at[0]
    if nx == nil and at[1].flowOut:
      let f = b.follower(at[0], at[1])
      np = f.page
      nx = f.layer
    if nx == nil: break
    if not nx.writtenFrame: return (fresh, "n", "n", "", true)
    at = (np, nx)
  let d = b.doc(i)
  var N = d.followerOf(L)
  var np = i
  if N == nil and L.flowOut:
    let f = b.follower(i, L)
    np = f.page
    N = f.layer
  let pid = b.pages[i].id
  result.self = frameSelf(pid, uidOf(L))
  result.prev = if L.flowFrom == 0: "n"
                elif L.flowPage != 0: frameSelf(L.flowPage, L.flowFrom)
                else: frameSelf(pid, L.flowFrom)
  result.next = if N != nil: frameSelf(b.pages[np].id, uidOf(N)) else: "n"
  result.story = storySelf(b.pages[hp].id, uidOf(H))
  result.own = L == H and hp == i

proc pageDestOf(o: var IdmlOut; n: int): string =
  ## (page `n`'s HyperlinkPageDestination, made the first time)
  if n notin o.pageDest:
    let pd = o.uid("hpd")
    o.pageDest[n] = pd
    let pg = if n >= 1 and n <= o.pageSelf.len: o.pageSelf[n - 1] else: (if o.pageSelf.len > 0: o.pageSelf[0] else: "n")
    o.hyper.add "<HyperlinkPageDestination Self=\"" & pd & "\" Name=\"Page " & $n & "\" DestinationPage=\"" & pg &
                "\" ViewSetting=\"FitWindow\" Hidden=\"false\" DestinationUniqueKey=\"" & $(1000 + n) & "\"/>\n"
  o.pageDest[n]

proc bookmarksOut(o: var IdmlOut; bms: seq[tuple[b: DocBookmark; page: int]]) =
  ## (the bookmarks, entries under entries as their levels say, each to its text destination or
  ## its page)
  var depth = 0
  for (bm, page) in bms:
    let lvl = clamp(bm.level, 0, depth)
    while depth > lvl:
      o.hyper.add "</Bookmark>\n"
      dec depth
    let dest = if bm.dest.len > 0: o.destSelf(bm.dest) else: o.pageDestOf(page)
    o.hyper.add "<Bookmark Self=\"" & o.uid("bm") & "\" Name=\"" & x(bm.title) & "\" Destination=\"" & dest &
                "\" IndentLevel=\"" & $lvl & "\">\n"
    inc depth
  while depth > 0:
    o.hyper.add "</Bookmark>\n"
    dec depth

proc saveBookIdml*(b: Book; path: string; keep: openArray[int] = []) =
  ## The book as IDML at `path`, its pictures as PNG files in a folder
  ## beside it ("name-links"). The pages opened for it are parked again,
  ## but for those at `keep`. Raises `IOError` when it cannot be written.
  b.reflow(keep)
  var o = IdmlOut(linksDir: path.changeFileExt("").absolutePath & "-links")
  let s = b.setup
  let k = 72 / max(1.0, s.dpi)
  o.k = k
  for i in 0 ..< b.pages.len: o.pageSelf.add o.uid("pg")      # (known before the links to them)
  var bms: seq[tuple[b: DocBookmark; page: int]]
  let pw = s.w.float * k
  let ph = s.h.float * k
  let rtl = s.binding == bindRight
  proc marginsOf(m: PageMargins): array[4, float] =
    # (the layout program's Left and Right are the inside and the outside on facing pages)
    [m.top.float * k, m.bottom.float * k, m.inside.float * k, m.outside.float * k]
  let gut = s.gutter.float * k
  # masters
  var masters: seq[(string, string)]
  var masterSelf = initTable[int, string]()
  for m in b.masters: masterSelf[m.id] = o.uid("m")
  for m in b.masters:
    let self = masterSelf[m.id]
    # (based on another master: its pages have that one applied, as the layout program does it)
    let parent = masterSelf.getOrDefault(m.basedOn, "n")
    var items, pagesXml = ""
    let sides = if s.facing: @[psLeft, psRight] else: @[psSingle]
    for j, side in sides:
      let tx = if s.facing: (if j == 0: -pw else: 0.0) else: 0.0
      let ty = -ph / 2
      let md = b.masterDoc(m, side)
      let mm = b.masterMargins(m)
      pagesXml.add pageXml(o.uid("mp"), m.name, parent, pw, ph, tx, ty, marginsOf(mm), mm.columns,
                           mm.gutter.float * k)
      items.add o.itemsOf(md, tx, ty, k, master = true, name = path.splitFile.name & "-master-" & m.name)
    masters.add ("MasterSpreads/MasterSpread_" & self & ".xml",
                 spreadXml(self, items, pagesXml, sides.len, master = true, name = m.name))
  # the pages, spread by spread
  var spreads: seq[(string, string)]
  var firstPage = ""
  var done = newSeq[bool](b.pages.len)
  for i in 0 ..< b.pages.len:
    if done[i]: continue
    let sheet = b.spreadOf(i)
    var items, pagesXml = ""
    let self = o.uid("sp")
    for j, pi in sheet:
      done[pi] = true
      let was = b.isOpen(pi)
      let d = b.doc(pi)
      let side = b.sideOf(pi)
      let tx = if sheet.len == 2: (if j == 0: -pw else: 0.0) elif side == psLeft: -pw else: 0.0
      let ty = -ph / 2
      let pself = o.pageSelf[pi]
      if firstPage.len == 0: firstPage = pself
      let ms = if b.pages[pi].master != 0 and b.pages[pi].master in masterSelf: masterSelf[b.pages[pi].master] else: "n"
      let pm = b.marginsOf(pi)
      pagesXml.add pageXml(pself, b.label(pi), ms, pw, ph, tx, ty, marginsOf(pm), pm.columns, pm.gutter.float * k)
      let here = pi
      let threads = proc (L: Layer; fresh: string): Thread = b.threadOf(here, L, fresh)
      items.add o.itemsOf(d, tx, ty, k, master = false, name = path.splitFile.name & "-p" & $(pi + 1),
                          threads = threads)
      for bm in d.bookmarks: bms.add (bm, pi + 1)
      if not was and pi notin keep: b.park(keep)
    spreads.add ("Spreads/Spread_" & self & ".xml", spreadXml(self, items, pagesXml, sheet.len, master = false))
  o.bookmarksOut(bms)
  let res = o.resources(pw, ph, b.pages.len, s.facing, rtl, marginsOf(bookMargins(s)), s.columns, gut)
  let data = o.package(spreads, masters, res, b.pages.len, firstPage)
  if o.links.len > 0:
    createDir(o.linksDir)
    for (file, png) in o.links: writeFile(o.linksDir / file, png)
  writeFile(path, data)

proc saveDocIdml*(d: Doc; path: string) =
  ## One document as a one-page IDML, its pictures as PNG files beside it.
  var o = IdmlOut(linksDir: path.changeFileExt("").absolutePath & "-links")
  let k = 72 / max(1.0, d.dpi)
  o.k = k
  let pw = d.w.float * k
  let ph = d.h.float * k
  let first = o.uid("pg")
  o.pageSelf = @[first]
  let self = o.uid("sp")
  let threads = proc (L: Layer; fresh: string): Thread = d.threadOf(L, fresh)
  let items = o.itemsOf(d, 0, -ph / 2, k, master = false, name = path.splitFile.name, threads = threads)
  let spread = spreadXml(self, items, pageXml(first, "1", "n", pw, ph, 0, -ph / 2, [0.0, 0, 0, 0], 1, 12), 1,
                         master = false)
  var bms: seq[tuple[b: DocBookmark; page: int]]
  for bm in d.bookmarks: bms.add (bm, 1)
  o.bookmarksOut(bms)
  let res = o.resources(pw, ph, 1, false, false, [0.0, 0, 0, 0], 1, 12)
  let data = o.package(@[("Spreads/Spread_" & self & ".xml", spread)], @[], res, 1, first)
  if o.links.len > 0:
    createDir(o.linksDir)
    for (file, png) in o.links: writeFile(o.linksDir / file, png)
  writeFile(path, data)

# ---- reading IDML -------------------------------------------------------------------------------------------

import std/[xmlparser, xmltree, strtabs]

type IdmlError* = object of IOError
  ## `readIdml`: not an IDML package, or one damaged past reading

proc nums(s: string): seq[float] =
  for w in s.splitWhitespace:
    try: result.add parseFloat(w) except ValueError: result.add 0

proc applyT(m: seq[float]; p: (float, float)): (float, float) =
  if m.len < 6: return p
  (m[0] * p[0] + m[2] * p[1] + m[4], m[1] * p[0] + m[3] * p[1] + m[5])

proc mul(a, b: seq[float]): seq[float] =
  ## (`a` then `b`, as IDML's ItemTransforms nest)
  if a.len < 6: return b
  if b.len < 6: return a
  @[a[0] * b[0] + a[1] * b[2], a[0] * b[1] + a[1] * b[3], a[2] * b[0] + a[3] * b[2], a[2] * b[1] + a[3] * b[3],
    a[4] * b[0] + a[5] * b[2] + b[4], a[4] * b[1] + a[5] * b[3] + b[5]]

proc childrenNamed(n: XmlNode; tag: string): seq[XmlNode] =
  if n == nil or n.kind != xnElement: return
  for c in n:
    if c.kind == xnElement and c.tag == tag: result.add c

proc findAll(n: XmlNode; tag: string; into: var seq[XmlNode]) =
  if n == nil or n.kind != xnElement: return
  for c in n:
    if c.kind == xnElement:
      if c.tag == tag: into.add c
      findAll(c, tag, into)

proc attr(n: XmlNode; k: string): string =
  if n == nil or n.kind != xnElement or n.attrs == nil: "" else: n.attrs.getOrDefault(k)

proc pathOf(n: XmlNode; m: seq[float]): seq[seq[tuple[a, l, r: (float, float)]]] =
  ## (an item's outlines, in the spread's points)
  var gps: seq[XmlNode]
  findAll(n, "GeometryPathType", gps)
  for g in gps:
    var sub: seq[tuple[a, l, r: (float, float)]]
    var pps: seq[XmlNode]
    findAll(g, "PathPointType", pps)
    for p in pps:
      let a = nums(p.attr("Anchor"))
      let l = nums(p.attr("LeftDirection"))
      let r = nums(p.attr("RightDirection"))
      if a.len < 2: continue
      let la = if l.len >= 2: (l[0], l[1]) else: (a[0], a[1])
      let ra = if r.len >= 2: (r[0], r[1]) else: (a[0], a[1])
      sub.add (applyT(m, (a[0], a[1])), applyT(m, la), applyT(m, ra))
    if sub.len > 0: result.add sub

proc wrapIn(it: XmlNode; wrap, side: var int; opts: var WrapOptions): bool =
  ## (an item's or an Object Style's Text Wrap read: false when it has none)
  for c in it:
    if c.kind != xnElement or c.tag != "TextWrapPreference": continue
    let mode = WrapModes.find(c.attr("TextWrapMode"))
    if mode <= 0: return false
    wrap = mode
    side = max(0, WrapSides.find(c.attr("TextWrapSide")))
    opts.invert = c.attr("Inverse") == "true"
    for pp in c:
      if pp.kind == xnElement and pp.tag == "ContourOption":
        # (where its outline comes from: a path, its edges, else its pixels -- its frame's or its
        # clipping's outline is its own shape's)
        case pp.attr("ContourType")
        of "PhotoshopPath":
          opts.contour = 2
          opts.contourPath = pp.attr("ContourPathName")
        of "DetectEdges": opts.contour = 1
        else: opts.contour = 0
      if pp.kind != xnElement or pp.tag != "Properties": continue
      for o in pp:
        if o.kind != xnElement or o.tag != "TextWrapOffset": continue
        proc num(k: string): float32 =
          try: float32(parseFloat(o.attr(k))) except ValueError: 0'f32
        opts.offsets = [num("Top"), num("Bottom"), num("Left"), num("Right")]
    opts.linked = opts.offsets[0] == opts.offsets[1] and opts.offsets[1] == opts.offsets[2] and
                  opts.offsets[2] == opts.offsets[3] and opts.offsets[0] != 0
    return true

proc readIdml*(file: string; dpi = 150.0): Book =
  ## An IDML package as a book: its pages (spreads, facing or not, bound
  ## either way), each text frame a text box with its story's runs (fonts,
  ## sizes, colors, paragraphs), each rectangle, oval and polygon a shape
  ## with its fill and stroke, each linked picture found where its link
  ## says (or beside the package) a layer of its own; tables and footnotes
  ## as the type engine's own. Master pages and effects are not read.
  ## Raises `IdmlError`.
  var entries: seq[ZipEntry]
  try: entries = zipEntries(file)
  except CatchableError: raise newException(IdmlError, "not an IDML package")
  var files = initTable[string, ZipEntry]()
  for e in entries: files[e.name] = e
  proc get(name: string): XmlNode =
    if name notin files: return nil
    # (a Right Indent Tab, a processing instruction XML drops: a character kept in its place --
    # U+E008, made "\b" again as the text is read)
    try: parseXml(readEntry(file, files[name]).replace("<?ACE 8?>", "\uE008"))
    except CatchableError: nil
  let dm = get("designmap.xml")
  if dm == nil: raise newException(IdmlError, "not an IDML package (no designmap.xml)")
  # colors
  var colors = initTable[string, uint32]()
  colors["Color/Black"] = 0xFF000000'u32
  colors["Color/Paper"] = 0xFFFFFFFF'u32
  let gr = get("Resources/Graphic.xml")
  var cs: seq[XmlNode]
  findAll(gr, "Color", cs)
  for c in cs:
    let v = nums(c.attr("ColorValue"))
    let sp = c.attr("Space")
    var argb = 0xFF000000'u32
    if sp == "RGB" and v.len >= 3:
      argb = 0xFF000000'u32 or (uint32(clamp(v[0], 0, 255)) shl 16) or (uint32(clamp(v[1], 0, 255)) shl 8) or
             uint32(clamp(v[2], 0, 255))
    elif sp == "CMYK" and v.len >= 4:
      let (cc, mm, yy, kk) = (v[0] / 100, v[1] / 100, v[2] / 100, v[3] / 100)
      argb = 0xFF000000'u32 or (uint32(255 * (1 - cc) * (1 - kk)) shl 16) or (uint32(255 * (1 - mm) * (1 - kk)) shl 8) or
             uint32(255 * (1 - yy) * (1 - kk))
    elif sp == "LAB" and v.len >= 1:
      let g = uint32(clamp(v[0] / 100 * 255, 0, 255))
      argb = 0xFF000000'u32 or (g shl 16) or (g shl 8) or g
    colors[c.attr("Self")] = argb
  proc colorOf(s: string; d = 0'u32): uint32 = colors.getOrDefault(s, d)
  let k0 = dpi / 72
  # (the character styles -- what nested, GREP and line styles name -- and the Object Styles)
  let sx = get("Resources/Styles.xml")
  var charLooks = initTable[string, (string, CharStyle)]()   # (Self -> its name, its look)
  var objDefs = initTable[string, ObjectStyleDef]()          # (Self -> it)
  block:
    var css: seq[XmlNode]
    findAll(sx, "CharacterStyle", css)
    for c in css:
      let self = c.attr("Self")
      let name = c.attr("Name")
      if name.len == 0 or name.startsWith("$ID/"): continue
      var st = defaultStyle()
      try:
        if c.attr("PointSize").len > 0: st.size = float32(parseFloat(c.attr("PointSize")) * k0)
      except ValueError: discard
      if c.attr("FillColor").len > 0: st.color = colorOf(c.attr("FillColor"), 0xFF000000'u32)
      var fam = ""
      for pp in c.childrenNamed("Properties"):
        for af in pp.childrenNamed("AppliedFont"): fam = af.innerText
      if fam.len > 0 and fam in fontFamilies(): st.family = fam
      let fsn = c.attr("FontStyle")
      if fsn.len > 0:
        if st.family.len > 0 and fsn in fontStyles(st.family): st.style = fsn
        elif "Bold" in fsn: st.fauxBold = true
      st.underline = c.attr("Underline") == "true"
      case c.attr("Capitalization")
      of "AllCaps": st.allCaps = true
      of "SmallCaps": st.smallCaps = true
      else: discard
      st.styleName = name
      charLooks[self] = (name, st)
    var oss: seq[XmlNode]
    findAll(sx, "ObjectStyle", oss)
    for c in oss:
      let name = c.attr("Name")
      if name.len == 0 or name.startsWith("$ID/"): continue
      var os = ObjectStyleDef(name: name, opacity: 100, fillOpacity: 100)
      if c.attr("EnableFill") == "true" or c.attr("FillColor").len > 0:
        os.useFill = true
        let fc = c.attr("FillColor")
        if fc.len > 0 and fc != "Swatch/None": os.shape.fill = ShapePaint(kind: spColor, color: colorOf(fc, 0xFF000000'u32))
      if c.attr("EnableStroke") == "true" or c.attr("StrokeColor").len > 0:
        os.useStroke = true
        let sc = c.attr("StrokeColor")
        if sc.len > 0 and sc != "Swatch/None":
          os.shape.stroke = ShapePaint(kind: spColor, color: colorOf(sc, 0xFF000000'u32))
          os.shape.strokeWidth = (try: parseFloat(c.attr("StrokeWeight")) * k0 except ValueError: 1.0)
      os.useWrap = wrapIn(c, os.wrap, os.wrapSide, os.wrapOpts)
      objDefs[c.attr("Self")] = os
  # (hyperlinks: each source's link -- an address, "page:N", "#name" -- and the text destinations'
  # names; the bookmarks)
  var destNames = initTable[string, string]()     # (a HyperlinkTextDestination's Self -> its name)
  for name in files.keys:
    if name.startsWith("Stories/") and name.endsWith(".xml"):
      var ds: seq[XmlNode]
      findAll(get(name), "HyperlinkTextDestination", ds)
      for dn in ds: destNames[dn.attr("Self")] = dn.attr("Name")
  var urlDests = initTable[string, string]()
  var pageDests = initTable[string, string]()      # (Self -> the page's Self)
  for e in dm:
    if e.kind != xnElement: continue
    case e.tag
    of "HyperlinkURLDestination": urlDests[e.attr("Self")] = e.attr("DestinationURL")
    of "HyperlinkPageDestination": pageDests[e.attr("Self")] = e.attr("DestinationPage")
    of "HyperlinkTextDestination": destNames[e.attr("Self")] = e.attr("Name")
    else: discard
  var pageSelfs: seq[string]                       # (the pages' Selfs, in order: filled with the spreads)
  var pageMargins: seq[PageMargins]                # (... their margins and columns, as they say)
  var sourceLink = initTable[string, string]()     # (a HyperlinkTextSource's Self -> its link)
  var sourceDest = initTable[string, string]()     # (... -> its destination's Self, to settle)
  for e in dm.childrenNamed("Hyperlink"):
    var dest = ""
    for pp in e.childrenNamed("Properties"):
      for dd in pp.childrenNamed("Destination"): dest = dd.innerText
    if dest.len == 0: dest = e.attr("Destination")
    sourceDest[e.attr("Source")] = dest
  # the page's size and binding
  let pr = get("Resources/Preferences.xml")
  var dps: seq[XmlNode]
  findAll(pr, "DocumentPreference", dps)
  var pw = 595.0
  var ph = 842.0
  var facing = true
  var rtl = false
  if dps.len > 0:
    try:
      pw = parseFloat(dps[0].attr("PageWidth"))
      ph = parseFloat(dps[0].attr("PageHeight"))
    except ValueError: discard
    facing = dps[0].attr("FacingPages") != "false"
    rtl = dps[0].attr("PageBinding") == "RightToLeft"
  let k = dpi / 72                       # (pixels a point)
  var s = bookSetup(pw * 25.4 / 72, ph * 25.4 / 72, dpi = dpi, facing = facing,
                    binding = (if rtl: bindRight else: bindLeft))
  proc marginsIn(n: XmlNode): PageMargins =
    ## (a MarginPreference: points to pixels; Left and Right the inside and the outside)
    proc num(a: string): float = (try: parseFloat(n.attr(a)) except ValueError: -1.0)
    if n == nil or num("Top") < 0: return
    PageMargins(own: true, top: int(num("Top") * k + 0.5), bottom: int(max(0.0, num("Bottom")) * k + 0.5),
                inside: int(max(0.0, num("Left")) * k + 0.5), outside: int(max(0.0, num("Right")) * k + 0.5),
                columns: clamp((try: parseInt(n.attr("ColumnCount")) except ValueError: 1), 1, 12),
                gutter: int(max(0.0, num("ColumnGutter")) * k + 0.5))
  block:
    var mps: seq[XmlNode]
    findAll(pr, "MarginPreference", mps)
    if mps.len > 0:
      let m = marginsIn(mps[0])
      if m.own:
        (s.top, s.bottom, s.inside, s.outside) = (m.top, m.bottom, m.inside, m.outside)
        (s.columns, s.gutter) = (m.columns, m.gutter)
  # stories
  var stories = initTable[string, XmlNode]()
  for name in files.keys:
    if name.startsWith("Stories/") and name.endsWith(".xml"):
      let st = get(name)
      var ss: seq[XmlNode]
      findAll(st, "Story", ss)
      if st != nil and st.tag == "Story": ss.add st
      for x in ss: stories[x.attr("Self")] = x
  proc textOf(id: string; at: (float, float); w, h: float): TextData =
    result = TextData(x: float32(at[0]), y: float32(at[1]), boxW: float32(w), boxH: float32(h), antialias: true)
    if id notin stories: return
    var psrs: seq[XmlNode]
    proc paraRanges(n: XmlNode; acc: var seq[XmlNode]) =
      ## (the story's own paragraphs: not those in a table's cells or a footnote)
      for c in n:
        if c.kind != xnElement: continue
        if c.tag == "ParagraphStyleRange": acc.add c
        elif c.tag notin ["Table", "Cell", "Footnote", "Note", "Endnote"]: paraRanges(c, acc)
    paraRanges(stories[id], psrs)
    for sp in stories[id].childrenNamed("StoryPreference"):
      result.opticalMargin = sp.attr("OpticalMarginAlignment") == "true"
    proc paraOf(psr: XmlNode): ParaStyle =
      ## (a ParagraphStyleRange's format)
      # (the layout program's sides are the page's; ours, a right-to-left paragraph's, where its
      # lines start: its Right Align is our start -- as `alignOf` writes it)
      let rtl = psr.attr("ParagraphDirection") == "RightToLeftDirection"
      if rtl: result.rtl = 2
      case psr.attr("Justification")
      of "LeftAlign": result.align = (if rtl: textRight else: textLeft)
      of "CenterAlign": result.align = textCenter
      of "RightAlign": result.align = (if rtl: textLeft else: textRight)
      of "LeftJustified": result.align = (if rtl: justifyRight else: justifyLeft)
      of "RightJustified": result.align = (if rtl: justifyLeft else: justifyRight)
      of "CenterJustified": result.align = justifyCenter
      of "FullyJustified": result.align = justifyAll
      else: discard
      if psr.attr("Hyphenation") == "true": result.hyphenate = true
      proc num(a: string; lo, hi: float): float =
        try: clamp(parseFloat(psr.attr(a)), lo, hi) except ValueError: 0.0
      result.indentLeft = float32(num("LeftIndent", -1e5, 1e5) * k)
      result.indentRight = float32(num("RightIndent", -1e5, 1e5) * k)
      result.indentFirst = float32(num("FirstLineIndent", -1e5, 1e5) * k)
      result.spaceBefore = float32(num("SpaceBefore", 0, 1e5) * k)
      result.spaceAfter = float32(num("SpaceAfter", 0, 1e5) * k)
      let dl = int(num("DropCapLines", 0, 20))
      if dl >= 2:
        result.dropLines = dl
        result.dropChars = int(num("DropCapCharacters", 0, 20))
      case psr.attr("Composer")
      of "HL Single", "$ID/HL Single", "Adobe Single-line Composer": result.composer = cpSingle
      of "HL Composer", "$ID/HL Composer", "Adobe Paragraph Composer": result.composer = cpParagraph
      else: discard
      for (names, a, d) in [(["MinimumWordSpacing", "DesiredWordSpacing", "MaximumWordSpacing"],
                             addr result.wordSpacing, [80'i16, 100, 133]),
                            (["MinimumLetterSpacing", "DesiredLetterSpacing", "MaximumLetterSpacing"],
                             addr result.letterSpacing, [0'i16, 0, 0]),
                            (["MinimumGlyphScaling", "DesiredGlyphScaling", "MaximumGlyphScaling"],
                             addr result.glyphScaling, [100'i16, 100, 100])]:
        var v: array[3, int16]
        for q in 0 .. 2:
          v[q] = if psr.attr(names[q]).len > 0: int16(num(names[q], -100, 1000)) else: d[q]
        if v != d: a[] = v
      if psr.attr("KeepLinesTogether") == "true":
        result.keepTogether = psr.attr("KeepAllLinesTogether") == "true"
        result.keepStart = int(num("KeepFirstLines", 0, 50))
        result.keepEnd = int(num("KeepLastLines", 0, 50))
      result.keepWithNext = int(num("KeepWithNext", 0, 50))
      result.ignoreOptical = psr.attr("IgnoreEdgeAlignment") == "true"
      case psr.attr("StartParagraph")
      of "NextColumn": result.startAt = psNextColumn
      of "NextFrame": result.startAt = psNextFrame
      of "NextPage", "NextOddPage", "NextEvenPage": result.startAt = psNextPage
      else: discard
      case psr.attr("SpanColumnType")
      of "SpanColumns": result.spanAll = true
      of "SplitColumns": result.splitColumns = max(2, int(num("SpanSplitColumnCount", 0, 20)))
      else: discard
      # (nested, line and GREP styles: the character styles they name, their looks from Styles.xml)
      proc lookOf(ref0: string): (string, CharStyle) =
        if ref0 in charLooks: charLooks[ref0] else: ("", defaultStyle())
      proc field(li: XmlNode; tag: string): string =
        for e in li.childrenNamed(tag): return e.innerText
      for pp in psr.childrenNamed("Properties"):
        for lst in pp.childrenNamed("TabList"):
          for li in lst.childrenNamed("ListItem"):
            if result.tabs.len >= 100: break
            let at = try: clamp(parseFloat(li.field("Position")), 0, 1e5) except ValueError: 0.0
            var ts = TabStop(pos: float32(at * k))
            ts.align = case li.field("Alignment")
                       of "RightAlign": tabRight
                       of "CenterAlign": tabCenter
                       of "CharacterAlign": tabChar
                       else: tabLeft
            ts.leader = li.field("Leader")
            if ts.align == tabChar:
              let on = li.field("AlignmentCharacter")
              ts.alignOn = if on.len > 0 and on != ".": on.runeAt(0).toUTF8 else: ""
            result.setTab(ts)
        for lst in pp.childrenNamed("AllNestedStyles"):
          for li in lst.childrenNamed("ListItem"):
            if result.nested.len >= 50: break
            let (nm, look) = lookOf(li.field("AppliedCharacterStyle"))
            var ns = NestedStyle(name: nm, look: look, through: li.field("Inclusive") != "false")
            ns.count = (try: clamp(parseInt(li.field("Repetition")), 1, 10_000) except ValueError: 1)
            var dl: XmlNode = nil
            for e in li.childrenNamed("Delimiter"): dl = e
            if dl != nil:
              if dl.attr("type") == "string":
                ns.unit = nuUpTo
                ns.upTo = dl.innerText
              else:
                case dl.innerText
                of "AnyCharacter", "Letters": ns.unit = nuChars
                of "Sentence": ns.unit = nuSentences
                of "Tabs":
                  ns.unit = nuUpTo
                  ns.upTo = "\t"
                else: ns.unit = nuWords
            result.nested.add ns
        for lst in pp.childrenNamed("AllLineStyles"):
          for li in lst.childrenNamed("ListItem"):
            if result.lineStyles.len >= 50: break
            let cref = li.field("AppliedCharacterStyle")
            if cref.endsWith("[Repeat]"):
              result.repeatLast = (try: clamp(parseInt(li.field("RepeatLast")), 0, 1000) except ValueError: 1)
              continue
            let (nm, look) = lookOf(cref)
            let lines = (try: clamp(parseInt(li.field("LineCount")), 1, 1000) except ValueError: 1)
            result.lineStyles.add NestedLine(name: nm, look: look, lines: lines)
            let rl = (try: parseInt(li.field("RepeatLast")) except ValueError: 0)
            if rl > 0: result.repeatLast = clamp(rl, 0, 1000)
        for lst in pp.childrenNamed("AllGREPStyles"):
          for li in lst.childrenNamed("ListItem"):
            if result.grepStyles.len >= 50: break
            let (nm, look) = lookOf(li.field("AppliedCharacterStyle"))
            let pat = li.field("GrepExpression")
            if pat.len > 0: result.grepStyles.add GrepStyle(name: nm, look: look, pattern: pat)
    var fmtNo = 0
    for pi, psr in psrs:
      let pf = paraOf(psr)
      if pi == 0: result.para = pf
      else:
        if result.spans.len > 0 and not result.spans[^1].text.endsWith("\n"): result.spans[^1].text.add "\n"
        fmtNo = 0
        if pf != result.para:
          fmtNo = result.paraFmts.find(pf) + 1
          if fmtNo == 0 and result.paraFmts.len < 10_000:
            result.paraFmts.add pf
            fmtNo = result.paraFmts.len
      for csr in psr.childrenNamed("CharacterStyleRange"):
        var st = defaultStyle()
        st.para = fmtNo
        try:
          if csr.attr("PointSize").len > 0: st.size = float32(parseFloat(csr.attr("PointSize")) * k)
        except ValueError: discard
        st.color = colorOf(csr.attr("FillColor"), 0xFF000000'u32)
        st.lang = languageIn(csr.attr("AppliedLanguage"))
        var fam = ""
        for pp in csr.childrenNamed("Properties"):
          for af in pp.childrenNamed("AppliedFont"): fam = af.innerText
          for ld in pp.childrenNamed("Leading"):
            try: st.leading = float32(parseFloat(ld.innerText) * k) except ValueError: discard
        if fam.len > 0 and fam in fontFamilies(): st.family = fam
        let fsn = csr.attr("FontStyle")
        if fsn.len > 0:
          if st.family.len > 0 and fsn in fontStyles(st.family): st.style = fsn
          elif "Bold" in fsn: st.fauxBold = true
        try:
          if csr.attr("Tracking").len > 0: st.tracking = parseInt(csr.attr("Tracking"))
        except ValueError: discard
        st.underline = csr.attr("Underline") == "true"
        st.strike = csr.attr("StrikeThru") == "true"
        if csr.attr("Ligatures") == "false": st.features = withLigatures(st.features, false)
        if csr.attr("OTFContextualAlternate") == "false": st.features = withFeature(st.features, "calt", false)
        for (tag, attr) in OtfAttrs:
          if csr.attr(attr) == "true": st.features = withFeature(st.features, tag, true)
        var txt = ""
        var linkNow = ""                  # (a text destination: the text after it is it)
        template flushRun() =
          if txt.len > 0:
            var st2 = st
            st2.link = linkNow
            result.spans.add TextSpan(text: txt, style: st2)
            txt = ""
        for c in csr:
          if c.kind != xnElement: continue
          if c.tag == "Content": txt.add c.innerText.replace("\uE008", "\b")
          elif c.tag == "Br": txt.add "\n"
          elif c.tag == "HyperlinkTextDestination":
            flushRun()
            let nm = c.attr("Name")
            linkNow = if nm.len > 0: "=" & nm else: ""
          elif c.tag == "HyperlinkTextSource":
            # (a hyperlink's text: in a span of its own, with where it goes)
            flushRun()
            var lt = ""
            for e in c:
              if e.kind != xnElement: continue
              if e.tag == "Content": lt.add e.innerText
              elif e.tag == "Br": lt.add "\n"
            if lt.len > 0:
              var st2 = st
              st2.link = sourceLink.getOrDefault(c.attr("Self"), "")
              result.spans.add TextSpan(text: lt, style: st2)
          elif c.tag == "Table":
            # (a table: its cells back as text -- tabs between them, a paragraph a row -- and its look)
            var ncol = 1
            var nrow = 0
            try:
              ncol = max(1, parseInt(c.attr("ColumnCount")))
              nrow = parseInt(c.attr("HeaderRowCount")) + parseInt(c.attr("BodyRowCount"))
              if c.attr("FooterRowCount").len > 0: nrow += parseInt(c.attr("FooterRowCount"))
            except ValueError: discard
            var grid = newSeq[seq[string]](max(0, min(nrow, 10_000)))
            for row in grid.mitems: row = newSeq[string](min(ncol, 1000))
            var ts = TableStyle(on: true)
            try: ts.headerRows = parseInt(c.attr("HeaderRowCount")) except ValueError: discard
            try: ts.footerRows = clamp(parseInt(c.attr("FooterRowCount")), 0, 100) except ValueError: discard
            ts.skipFirstHeader = c.attr("SkipFirstHeader") == "true"
            ts.skipLastFooter = c.attr("SkipLastFooter") == "true"
            # (each row's height: exactly so tall, or at least)
            var ri = 0
            for row0 in c.childrenNamed("Row"):
              let row = row0
              proc num(a: string): float = (try: parseFloat(row.attr(a)) except ValueError: 0.0)
              var rf = TableRowFmt()
              if row.attr("AutoGrow") == "false" and num("SingleRowHeight") > 0:
                rf = TableRowFmt(kind: rhExactly, height: float32(num("SingleRowHeight") * k))
              elif num("MinimumHeight") > 0:
                rf = TableRowFmt(kind: rhAtLeast, height: float32(num("MinimumHeight") * k))
              # (its most height, kept with the next row, started in the next frame -- or column, page)
              if rf.kind != rhExactly and num("MaximumHeight") > 0:
                rf.maxHeight = float32(num("MaximumHeight") * k)
              rf.keepNext = row.attr("KeepWithNextRow") == "true"
              rf.startNext = row.attr("StartRow") notin ["", "Anywhere"]
              if ri < 10_000: ts.rowFmts.add rf
              inc ri
            var widths: seq[float32]
            for col in c.childrenNamed("Column"):
              try: widths.add float32(parseFloat(col.attr("SingleColumnWidth"))) except ValueError: widths.add 1
            ts.widths = widths
            var fills = newSeq[seq[tuple[seen: bool; c: uint32]]](grid.len)
            for row in fills.mitems: row = newSeq[tuple[seen: bool; c: uint32]](ncol)
            for cell in c.childrenNamed("Cell"):
              let nm = cell.attr("Name").split(':')
              if nm.len != 2: continue
              var cc, rr = -1
              try:
                cc = parseInt(nm[0])
                rr = parseInt(nm[1])
              except ValueError: continue
              if rr < 0 or rr >= grid.len or cc < 0 or cc >= grid[rr].len: continue
              # (its paragraphs apart: U+2029)
              var ct = ""
              proc walk(n: XmlNode; acc: var string) =
                for e in n:
                  if e.kind != xnElement: continue
                  if e.tag == "Content": acc.add e.innerText
                  elif e.tag == "Br":
                    if acc.len > 0: acc.add "\u2029"
                  else: walk(e, acc)
              walk(cell, ct)
              while ct.endsWith("\u2029"): ct.setLen(ct.len - "\u2029".len)
              grid[rr][cc] = ct.replace("\t", " ").replace("\n", " ")
              # (its own look: fill, sides, merged, inset, place up and down, turn)
              var cf = TableCell()
              cf.fill = colorOf(cell.attr("FillColor"), 0)
              fills[rr][cc] = (true, cf.fill)
              cf.fill = 0
              let bc = colorOf(cell.attr("TopEdgeStrokeColor"), 0)
              if bc != 0 and ts.border == 0: ts.border = bc
              let cellNode = cell
              proc cnum(a: string): float = (try: parseFloat(cellNode.attr(a)) except ValueError: -1.0)
              for (name, side) in [("Top", 0), ("Right", 1), ("Bottom", 2), ("Left", 3)]:
                let w = cnum(name & "EdgeStrokeWeight")
                if w >= 0:
                  cf.strokes[side] = CellStroke(on: true, width: float32(w * k),
                                                color: colorOf(cell.attr(name & "EdgeStrokeColor"), 0xFF000000'u32))
                let ins = cnum(name & "Inset")
                if ins >= 0: cf.inset[side] = float32(ins * k)
              cf.rowSpan = max(1, int(cnum("RowSpan")))
              cf.colSpan = max(1, int(cnum("ColumnSpan")))
              cf.vAlign = case cell.attr("VerticalJustification")
                          of "CenterAlign": vjCenter
                          of "BottomAlign": vjBottom
                          of "JustifyAlign": vjJustify
                          else: vjTop
              let rot = int(cnum("RotationAngle"))
              cf.rotation = if rot in [90, 180, 270]: rot else: 0
              if cf != TableCell(rowSpan: 1, colSpan: 1): ts.cellRef(rr, cc) = cf
            # (the fills: a row's, when all its cells have it -- the header's, the body's and every
            # other one's, as a theme has them --; a cell's own, else)
            var common = newSeq[uint32](grid.len)
            for r2, row in fills:
              var f = 0'u32
              var same = true
              var any = false
              for cell in row:
                if not cell.seen: continue
                if not any: (f, any) = (cell.c, true)
                elif cell.c != f: same = false
              common[r2] = if same: f else: 0'u32
            let b0 = min(ts.headerRows, grid.len)
            if ts.headerRows > 0 and grid.len > 0: ts.headerFill = common[0]
            if b0 < grid.len: ts.fill = common[b0]
            if b0 + 1 < grid.len and common[b0 + 1] != ts.fill: ts.altFill = common[b0 + 1]
            for r2, row in fills:
              let rowFill = if r2 < ts.headerRows: ts.headerFill
                            elif ts.altFill != 0 and (r2 - ts.headerRows) mod 2 == 1: ts.altFill
                            else: ts.fill
              for c2, cell in row:
                if cell.seen and cell.c != rowFill and cell.c != 0: ts.cellRef(r2, c2).fill = cell.c
            for i, row in grid:
              if i > 0: txt.add "\n"
              txt.add row.join("\t")
            result.table = ts
          elif c.tag == "Footnote":
            # (a footnote: a reference here, its text the note's)
            var nt = ""
            for e in c.findAll("Content"): nt.add e.innerText
            var nid = 1
            for n in result.notes: nid = max(nid, n.id + 1)
            if nid <= 65533:
              txt.add noteMark(nid)
              result.notes.add Footnote(id: nid, text: nt.strip)
        flushRun()
  # spreads: their pages in order, each page's items
  var pagesOut: seq[tuple[items: seq[XmlNode]; m: seq[seq[float]]; page: seq[float]]]
  for sp in dm.childrenNamed("idPkg:Spread"):
    let sx = get(sp.attr("src"))
    var spreadNodes: seq[XmlNode]
    findAll(sx, "Spread", spreadNodes)
    if sx != nil and sx.tag == "Spread": spreadNodes.add sx
    for spread in spreadNodes:
      let smat = nums(spread.attr("ItemTransform"))
      let pages = spread.childrenNamed("Page")
      var pageMats: seq[seq[float]]
      for p in pages: pageMats.add mul(nums(p.attr("ItemTransform")), smat)
      var items: seq[seq[XmlNode]]
      for _ in pages: items.add @[]
      var mats: seq[seq[seq[float]]]
      for _ in pages: mats.add @[]
      for it in spread:
        if it.kind != xnElement or it.tag notin ["TextFrame", "Rectangle", "Oval", "Polygon", "GraphicLine", "Group"]:
          continue
        let m = mul(nums(it.attr("ItemTransform")), smat)
        # (the page the item's middle is over)
        let paths = pathOf(it, m)
        var cx, cy = 0.0
        var n = 0
        for sub in paths:
          for p in sub:
            cx += p.a[0]
            cy += p.a[1]
            inc n
        if n == 0: continue
        cx /= n.float
        cy /= n.float
        var best = 0
        for pi, pm in pageMats:
          if pm.len >= 6 and cx >= pm[4] and cx <= pm[4] + pw: best = pi
        if best < items.len:
          items[best].add it
          mats[best].add m
      for pi, p in pages:
        pagesOut.add (items[pi], mats[pi], pageMats[pi])
        pageSelfs.add p.attr("Self")
        var pm = PageMargins()
        for mp in p.childrenNamed("MarginPreference"): pm = marginsIn(mp)
        pageMargins.add pm
  if pagesOut.len == 0: raise newException(IdmlError, "the package has no pages")
  for src, dest in sourceDest:
    if dest in urlDests: sourceLink[src] = urlDests[dest]
    elif dest in pageDests:
      let n = pageSelfs.find(pageDests[dest])
      sourceLink[src] = "page:" & $(max(0, n) + 1)
    elif dest in destNames: sourceLink[src] = "#" & destNames[dest]
  result = newBook(s, pages = pagesOut.len, name = file.splitFile.name)
  let b = result
  # (a page's margins of its own: where they are not the document's)
  for i, pm in pageMargins:
    if i < b.pages.len and pm.own and pm != bookMargins(s): b.setPageMargins(i, pm)
  var frameAt = initTable[string, (int, int)]()     # (a text frame's Self: its page, its layer)
  var threaded: seq[(int, int, string)]             # (a frame that goes on from another)
  for i, pg in pagesOut:
    let d = b.doc(i)
    let ox = if pg.page.len >= 6: pg.page[4] else: 0.0
    let oy = if pg.page.len >= 6: pg.page[5] else: 0.0
    proc px(p: (float, float)): (float, float) = ((p[0] - ox) * k, (p[1] - oy) * k)
    for j, it in pg.items:
      let paths = pathOf(it, pg.m[j])
      var x0, y0 = Inf
      var x1, y1 = -Inf
      var path: Path
      for sub in paths:
        var spth = SubPath(closed: true)
        for p in sub:
          let a = px(p.a)
          x0 = min(x0, a[0]); y0 = min(y0, a[1]); x1 = max(x1, a[0]); y1 = max(y1, a[1])
          spth.pts.add PathPoint(p: a, inH: px(p.l), outH: px(p.r))
        path.subs.add spth
      if x1 <= x0 or y1 <= y0: continue
      case it.tag
      of "TextFrame":
        var t = textOf(it.attr("ParentStory"), (x0, y0), x1 - x0, y1 - y0)
        for pref in it.childrenNamed("TextFramePreference"):
          # (its columns, and Auto-Size)
          let cols = (try: parseInt(pref.attr("TextColumnCount")) except ValueError: 0)
          if cols > 1:
            t.columns = min(cols, 12)
            let g = (try: parseFloat(pref.attr("TextColumnGutter")) except ValueError: 0.0)
            if g > 0: t.gutter = float32(g * k)
          for a in TextAutoSize:
            if pref.attr("AutoSizingType") == AutoSizing[a]: t.autoSize = a
          let rp = RefPoints.find(pref.attr("AutoSizingReferencePoint"))
          if rp >= 0: t.autoRef = rp
          # (Inset Spacing -- top, left, bottom, right --, Vertical Justification, Balance Columns)
          for e in VertJust:
            if pref.attr("VerticalJustification") == VertJusts[e]: t.vjust = e
          t.balance = pref.attr("VerticalBalanceColumns") == "true"
          # (Baseline Options' first baseline; columns of a fixed or a most width)
          for e in FirstBaseline:
            if pref.attr("FirstBaselineOffset") == FirstBases[e]: t.firstBase = e
          try: t.firstMin = clamp(float32(parseFloat(pref.attr("MinimumFirstBaselineOffset")) * k), 0, 10_000)
          except ValueError: discard
          if pref.attr("UseFixedColumnWidth") == "true":
            try:
              t.colWidth = clamp(float32(parseFloat(pref.attr("TextColumnFixedWidth")) * k), 1, 100_000)
              t.colMode = cmFixedWidth
            except ValueError: discard
          elif pref.attr("UseFlexibleColumnWidth") == "true":
            try:
              t.colWidth = clamp(float32(parseFloat(pref.attr("TextColumnMaxWidth")) * k), 1, 100_000)
              t.colMode = cmFlexible
            except ValueError: discard
          var ins: seq[float32]
          for pp in pref.childrenNamed("Properties"):
            for il in pp.childrenNamed("InsetSpacing"):
              for li in il.childrenNamed("ListItem"):
                try: ins.add clamp(float32(parseFloat(li.innerText) * k), 0, 10_000) except ValueError: ins.add 0
          if ins.len == 4: t.inset = [ins[0], ins[3], ins[2], ins[1]]
          else:
            # (one number for all four sides: an attribute)
            let a = pref.attr("InsetSpacing")
            if a.len > 0:
              let v = nums(a)
              if v.len == 1: t.inset = [float32(v[0] * k), float32(v[0] * k), float32(v[0] * k), float32(v[0] * k)]
              elif v.len == 4: t.inset = [float32(v[0] * k), float32(v[3] * k), float32(v[2] * k), float32(v[1] * k)]
        let prev = it.attr("PreviousTextFrame")
        let follows = prev.len > 0 and prev != "n"
        if follows and t.spans.len > 0:
          # (a frame the story goes on into: it shows what did not fit the one before)
          t.spans = @[TextSpan(text: "", style: t.spans[0].style)]
          t.notes = @[]
        if t.spans.len > 0:
          let L = d.addTextLayer(t)
          if it.attr("Name").len > 0 and it.attr("Name") != "$ID/": L.name = it.attr("Name")
          discard wrapIn(it, L.wrap, L.wrapSide, L.wrapOpts)
          for pref in it.childrenNamed("TextFramePreference"):
            if pref.attr("IgnoreWrap") == "true": L.ignoreWrap = true
          let osr = it.attr("AppliedObjectStyle")
          if osr in objDefs:
            L.objectStyle = objDefs[osr].name
            if d.objectStyleIndex(L.objectStyle) < 0: d.objectStyles.add objDefs[osr]
          frameAt[it.attr("Self")] = (i, uidOf(L))
          if follows: threaded.add (i, uidOf(L), prev)
      else:
        # a picture in it: its link, where it says or beside the package
        var imgs: seq[XmlNode]
        findAll(it, "Image", imgs)
        findAll(it, "PDF", imgs)
        var placed = false
        for im in imgs:
          var links: seq[XmlNode]
          findAll(im, "Link", links)
          for l in links:
            var f = l.attr("LinkResourceURI")
            if f.startsWith("file:"): f = f[5 .. ^1]
            while f.startsWith("//"): f = f[1 .. ^1]
            f = f.replace("%20", " ")
            let near = file.parentDir / f.extractFilename
            let found = if fileExists(f): f elif fileExists(near): near else: ""
            if found.len == 0: continue
            try:
              let data = readFile(found)
              let pic = if data.startsWith("\x89PNG"): decodePng(data)
                        elif data.startsWith("\xFF\xD8"): decodeJpeg(data)
                        elif data.startsWith("BM"): decodeBmp(data)
                        else: nil
              if pic == nil or pic.w <= 0: continue
              let L = d.addLayer(found.splitFile.name)
              let bw = int(x1 - x0)
              let bh = int(y1 - y0)
              let kk = max(bw / pic.w, bh / pic.h)
              let w = int(pic.w.float * kk)
              let h = int(pic.h.float * kk)
              let sx0 = int(x0) + (bw - w) div 2
              let sy0 = int(y0) + (bh - h) div 2
              for yy in max(0, int(y0)) ..< min(d.h, int(y1)):
                for xx in max(0, int(x0)) ..< min(d.w, int(x1)):
                  let u = (xx - sx0) * pic.w div max(1, w)
                  let v = (yy - sy0) * pic.h div max(1, h)
                  if u >= 0 and v >= 0 and u < pic.w and v < pic.h: L.px[yy * d.w + xx] = pic.px[v * pic.w + u]
              inc L.ver
              discard wrapIn(it, L.wrap, L.wrapSide, L.wrapOpts)
              placed = true
            except CatchableError: discard
        if not placed:
          let fill = it.attr("FillColor")
          let stroke = it.attr("StrokeColor")
          var sw = 0.0
          try:
            if it.attr("StrokeWeight").len > 0: sw = parseFloat(it.attr("StrokeWeight")) * k
          except ValueError: discard
          let hasFill = fill.len > 0 and fill != "Swatch/None"
          let hasStroke = stroke.len > 0 and stroke != "Swatch/None" and sw > 0
          if not hasFill and not hasStroke: continue
          var sd = ShapeData(path: path,
                             fill: (if hasFill: ShapePaint(kind: spColor, color: colorOf(fill, 0xFF000000'u32))
                                    else: ShapePaint()),
                             stroke: (if hasStroke: ShapePaint(kind: spColor, color: colorOf(stroke, 0xFF000000'u32))
                                      else: ShapePaint()),
                             strokeWidth: (if hasStroke: sw else: 0.0), align: saCenter,
                             kind: (if it.tag == "Oval": "Ellipse" elif it.tag == "Rectangle": "Rectangle" else: ""))
          if it.tag == "GraphicLine":
            for sub in sd.path.subs.mitems: sub.closed = false
          let SL = d.addShapeLayer(sd, if it.attr("Name").len > 0 and it.attr("Name") != "$ID/": it.attr("Name") else: "")
          if SL != nil: discard wrapIn(it, SL.wrap, SL.wrapSide, SL.wrapOpts)
          let osr = it.attr("AppliedObjectStyle")
          if osr in objDefs and SL != nil:
            SL.objectStyle = objDefs[osr].name
            if d.objectStyleIndex(SL.objectStyle) < 0: d.objectStyles.add objDefs[osr]
    d.markAll()
    b.park()
  # (the bookmarks: entries under entries; each to its text destination -- kept with the first
  # page -- or to its page)
  proc bookmarksIn(n: XmlNode; level: int) =
    for e in n.childrenNamed("Bookmark"):
      let dest = e.attr("Destination")
      var bm = DocBookmark(title: e.attr("Name"), level: level)
      var page = 0
      if dest in destNames: bm.dest = destNames[dest]
      elif dest in pageDests: page = max(0, pageSelfs.find(pageDests[dest]))
      if bm.title.len > 0 and page < b.pages.len:
        b.doc(page).bookmarks.add bm
        b.touch(page)
      bookmarksIn(e, level + 1)
  bookmarksIn(dm, 0)
  # the threads: each frame takes what did not fit the one before it, on its page or another
  for (i, uid, prev) in threaded:
    if prev notin frameAt: continue
    let (pp, puid) = frameAt[prev]
    let L = b.doc(i).layerOfUid(uid)
    if L == nil: continue
    L.flowFrom = puid
    if pp != i:
      L.flowPage = b.pages[pp].id
      let P = b.doc(pp).layerOfUid(puid)
      if P != nil: P.flowOut = true
    b.touch(i)
    b.touch(pp)
  if threaded.len > 0:
    # (in the pages' order: what each takes is known when it is reached)
    for i in 0 ..< b.pages.len: discard b.settle(i)
    for i in 0 ..< b.pages.len: b.doc(i).markAll()
    b.park()
  b.modified = false

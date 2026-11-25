## Diagrams as a designer sets them on a page or a slide -- a family tree, a dendrogram, a
## timeline, a numbered list, a note and a title -- typed as a few lines of text and placed in a
## document (`retroui/photo`) as shape and type layers in a group: each box, line and word still to
## change, sharp in a PDF. Two languages side by side: each field's script picks its font and its
## direction, so Arabic and English are set together. A theme gives the colors
## (`diagramThemes`); `newCarousel` makes a set of slides (artboards) with a header and a footer
## in both languages and their page numbers.
##
## The text has an item a line, `|` between its fields; in a tree, two spaces of indent go a level
## down:
##
## .. code-block:: text
##   الفينيقية | Phoenician
##     * الآرامية | Aramaic
##       * النبطية | Nabataean
##         * العربية | Arabic
##       ~ السريانية | Syriac
##
## Marks before an item: `*` highlighted (in the accent: its box filled, its line, its dot), `~`
## dashed (a branch that goes on elsewhere), `>` its children stacked one under another beside it.
##
## .. code-block:: nim
##   var s = defaultDiagram(dkTree)
##   s.data = "Aramaic | الآرامية\n  * Nabataean | النبطية"
##   let group = d.placeDiagram(s, rect(80, 300, 920, 800))
##   # group.meta keeps `s`: diagramOf(group) gives it back to change it
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net

import std/[json, math, strutils, algorithm]
import std/unicode except strip     # (strutils' strip: unicode's cuts a last letter ending in 0x85 or 0xA0)
import gfx, photo, photoshapes, textengine, dastkhat, photocc

type
  DiagramKind* = enum
    ## What a diagram is.
    dkTree = "Family Tree",        ## boxes joined by lines, a level a row
    dkDendrogram = "Dendrogram",   ## dots joined by curves, the leaves in a row
    dkTimeline = "Timeline",       ## a line down the middle, a dot a date, a language each side
    dkList = "Numbered List",      ## numbers in circles, each item's text beside its number
    dkNote = "Note",               ## a tinted box with its label in both languages
    dkTitle = "Title"              ## a big title, a second one, a short rule, lines under it

  LinkStyle* = enum
    ## How a tree's lines go from a box to its children.
    lsElbow = "Elbow",             ## down, across, down (a bus line under the parent)
    lsCurve = "Curve",             ## a smooth S
    lsStraight = "Straight"        ## straight to each child

  DiagramTheme* = object
    ## A diagram's colors (ARGB) and fonts.
    name*: string
    paper*: uint32                 ## the page behind it (a slide's paper; a dot's hole)
    ink*: uint32                   ## the text
    accent*: uint32                ## what is highlighted: boxes, lines, dots, numbers, dates, rules
    onAccent*: uint32              ## text on the accent
    fill*: uint32                  ## a box's fill
    edge*: uint32                  ## a box's outline
    muted*: uint32                 ## the second language's text, notes, sources
    line*: uint32                  ## lines, the timeline, rules between items
    arabicFont*, latinFont*: string  ## the families ("": Dastkhat, carried in the program)

  DiagramSpec* = object
    ## A diagram: what it is, what it says (the text above), how it looks.
    kind*: DiagramKind
    data*: string
    theme*: DiagramTheme
    size*: float                   ## its main text's size, pixels (0: by its width); smaller if
                                   ## it would not fit its box
    rtl*: bool                     ## Arabic first: a tree's first child at the right, a list's
                                   ## numbers at the right, a stack's boxes left of its line
    arabicDigits*: bool            ## numbers in Arabic-Indic digits (٠١٢) in Arabic text
    links*: LinkStyle
    radius*: float                 ## a box's corners, pixels (0: by the size; -1: square)
    lineWidth*: float              ## its lines, pixels (0: by the size)
    horizontal*: bool              ## a dendrogram from the side (its root at the right when `rtl`)
    labels*: bool                  ## a dendrogram's leaves named

  DiagramPart* = object
    ## A layer a diagram is made of: a type layer (`isText`) or a shape layer.
    name*: string
    isText*: bool
    text*: TextData
    shape*: ShapeData

  SlideFrame* = object
    ## A slide's header and footer, in both languages: the English at the left, the Arabic at
    ## the right.
    enTitle*, enSubtitle*: string
    arTitle*, arSubtitle*: string
    enSource*, arSource*: string   ## the footer's sources ("": none)
    pageNumbers*: bool             ## "1 / 8" in the footer's middle (`<#> / <##>`)
    arabicDigits*: bool            ## ... in Arabic-Indic digits

  CarouselSpec* = object
    ## A set of slides (`newCarousel`).
    slides*: int                   ## how many (artboards)
    w*, h*: int                    ## each one's size, pixels
    theme*: DiagramTheme
    frame*: SlideFrame
    titleSlide*: bool              ## the first one a title page: a dendrogram and `title`
    title*: string                 ## ... its text, as a Title diagram has it
    samples*: bool                 ## the next ones a diagram each to start from (a numbered list,
                                   ## a family tree, a timeline, a note)

  Item = object
    depth: int
    hi, dashed, stack: bool
    fields: seq[string]

  Para = tuple[text: string; st: CharStyle; side: int; before: float]

  Built = tuple[parts: seq[DiagramPart]; w, h: float]

  TNode = ref object
    it: Item
    kids: seq[TNode]
    w, h, lft, rgt, stackH: float
    offs: seq[float]
    x, y: float
    level: int
    text: TextData

# ---- themes ----------------------------------------------------------------------------------------------

const themeList = [
  # name, paper, ink, accent, onAccent, fill, edge, muted, line
  ("Parchment", 0xFFF2EEE5'u32, 0xFF1A1714'u32, 0xFFA0482A'u32, 0xFFFFFFFF'u32, 0xFFEAE3D5'u32,
   0xFFD6CBB5'u32, 0xFF6B6358'u32, 0xFFB8A88E'u32),
  ("Paper", 0xFFFFFFFF'u32, 0xFF15171A'u32, 0xFF1F5FAF'u32, 0xFFFFFFFF'u32, 0xFFF1F4F8'u32,
   0xFFD3DAE3'u32, 0xFF667085'u32, 0xFFA7B0BC'u32),
  ("Olive", 0xFFF4F3EC'u32, 0xFF22261C'u32, 0xFF5E7A2E'u32, 0xFFFFFFFF'u32, 0xFFE8E9DC'u32,
   0xFFCFD2BC'u32, 0xFF666B5A'u32, 0xFFA9AE92'u32),
  ("Sea", 0xFFEEF3F4'u32, 0xFF102A33'u32, 0xFF0F7C8C'u32, 0xFFFFFFFF'u32, 0xFFE0EAEC'u32,
   0xFFC3D6DA'u32, 0xFF557079'u32, 0xFF93AEB4'u32),
  ("Rose", 0xFFF8F1F0'u32, 0xFF2A1A1C'u32, 0xFFB03A55'u32, 0xFFFFFFFF'u32, 0xFFF0E2E2'u32,
   0xFFE0C9CB'u32, 0xFF7A6266'u32, 0xFFC4A8AC'u32),
  ("Night", 0xFF15171C'u32, 0xFFEDEDED'u32, 0xFFE0A458'u32, 0xFF15171C'u32, 0xFF23262D'u32,
   0xFF363A44'u32, 0xFF9AA0AA'u32, 0xFF5A606B'u32)]

proc diagramThemes*(): seq[string] =
  ## The themes' names, Parchment (cream, ink and rust) first.
  for t in themeList: result.add t[0]

proc diagramTheme*(name: string): DiagramTheme =
  ## The theme `name` (Parchment when there is none of that name).
  var k = 0
  for i, t in themeList:
    if cmpIgnoreCase(t[0], name) == 0: k = i
  let t = themeList[k]
  DiagramTheme(name: t[0], paper: t[1], ink: t[2], accent: t[3], onAccent: t[4], fill: t[5], edge: t[6],
               muted: t[7], line: t[8])

# ---- text ------------------------------------------------------------------------------------------------

var carried = false

proc carry() =
  if not carried:
    carried = true
    carryDastkhat()

proc arabicFirst(s: string): bool =
  ## (whether the first letter that has a direction is Arabic -- or Hebrew)
  for r in s.runes:
    let c = int(r)
    if c in 0x0590 .. 0x08FF or c in 0xFB1D .. 0xFDFF or c in 0xFE70 .. 0xFEFF: return true
    if (c >= ord('A') and c <= ord('Z')) or (c >= ord('a') and c <= ord('z')) or c in 0xC0 .. 0x24F:
      return false
  false

proc styleFor(s: DiagramSpec; text: string; size: float; color: uint32; weight = "Regular"): CharStyle =
  result = defaultStyle()
  let ar = arabicFirst(text)
  let fam = if ar: s.theme.arabicFont else: s.theme.latinFont
  result.family = if fam.len > 0: fam else: DastkhatFamily
  result.style = weight
  result.size = max(1.0, size).float32
  result.color = color
  if ar:
    result.lang = "ar"
    if s.arabicDigits: result.digits = 1

proc alignFor(text: string; side: int): TextAlign =
  ## (a paragraph standing at the left (0), in the middle (1) or at the right (2), whichever way
  ## it reads)
  if side == 1: return textCenter
  if (side == 2) != arabicFirst(text): textRight else: textLeft

proc textBox(paras: seq[Para]; x, y, w: float): TextData =
  ## (a text in a box `w` wide, a paragraph each, as tall as its lines)
  result = TextData(antialias: true, x: x.float32, y: y.float32, boxW: max(1.0, w).float32, boxH: 100000)
  var n = 0
  for p in paras:
    if p.text.len == 0: continue
    let ps = ParaStyle(align: alignFor(p.text, p.side), spaceBefore: (if n == 0: 0'f32 else: p.before.float32))
    var st = p.st
    if n == 0: result.para = ps
    else:
      result.paraFmts.add ps
      st.para = result.paraFmts.len
    if n > 0: result.spans[^1].text.add "\n"
    result.spans.add TextSpan(text: p.text, style: st)
    inc n
  if n == 0:
    result.spans.add TextSpan(text: "", style: defaultStyle())
    result.boxH = 1
    return
  let L = layoutText(result)
  result.boxH = max(1'f32, L.y1 - result.y + 2)

proc textWidth(text: string; st: CharStyle): float =
  if text.len == 0: return 0
  let L = layoutText(newText(text, st))
  float(L.x1 - L.x0)

proc firstBaseline(t: TextData): float =
  ## (how far under its top its first line's baseline is)
  let L = layoutText(t)
  if L.lines.len > 0: float(L.lines[0].baseline - t.y) else: 0.0

proc moved(t: TextData; x, y: float): TextData =
  result = t
  result.x = x.float32
  result.y = y.float32

# ---- shapes ----------------------------------------------------------------------------------------------

proc paint(c: uint32): ShapePaint = ShapePaint(kind: spColor, color: c)

proc noPaint(): ShapePaint = ShapePaint(kind: spNone)

proc boxShape(x, y, w, h, r: float; fill, edge: uint32; ew: float; dashed = false): ShapeData =
  let r = max(0.0, r)
  result = ShapeData(path: rectPath(x, y, x + w, y + h, r), fill: (if fill == 0: noPaint() else: paint(fill)),
                     stroke: (if edge == 0 or ew <= 0: noPaint() else: paint(edge)), strokeWidth: ew,
                     align: saInside, kind: "Rectangle", radius: r)
  if dashed: result.dashes = @[4.0, 3.0]

proc lineShape(path: Path; color: uint32; w: float; dashed = false): ShapeData =
  result = ShapeData(path: path, fill: noPaint(), stroke: paint(color), strokeWidth: w, align: saCenter,
                     cap: lcButt, join: ljMiter)
  if dashed: result.dashes = @[3.0, 2.5]

proc poly(pts: openArray[(float, float)]): SubPath =
  for p in pts: result.pts.add PathPoint(p: p, inH: p, outH: p)

proc curve(a, b: (float, float); vertical: bool): SubPath =
  ## (a smooth S from `a` to `b`, leaving and coming in down -- or across)
  if vertical:
    let my = (a[1] + b[1]) / 2
    SubPath(pts: @[PathPoint(p: a, inH: a, outH: (a[0], my)), PathPoint(p: b, inH: (b[0], my), outH: b)])
  else:
    let mx = (a[0] + b[0]) / 2
    SubPath(pts: @[PathPoint(p: a, inH: a, outH: (mx, a[1])), PathPoint(p: b, inH: (mx, b[1]), outH: b)])

proc dot(cx, cy, r: float): SubPath = ellipsePath(cx - r, cy - r, cx + r, cy + r).subs[0]

proc addText(b: var Built; t: TextData; name = "") =
  if t.plainText.len > 0: b.parts.add DiagramPart(name: name, isText: true, text: t)

proc addShape(b: var Built; s: ShapeData; name: string) =
  if s.path.subs.len > 0: b.parts.add DiagramPart(name: name, shape: s)

# ---- the text typed ---------------------------------------------------------------------------------------

proc parseItems(data: string): seq[Item] =
  for raw in data.splitLines:
    if raw.strip.len == 0: continue
    var ind = 0
    for ch in raw:
      if ch == ' ': inc ind
      elif ch == '\t': ind += 2
      else: break
    var s = raw.strip
    var it = Item(depth: ind div 2)
    while s.len > 0 and s[0] in {'*', '~', '>'}:
      case s[0]
      of '*': it.hi = true
      of '~': it.dashed = true
      else: it.stack = true
      s = s[1 .. ^1].strip(trailing = false)
    for f in s.split('|'): it.fields.add f.strip
    result.add it

proc field(it: Item; i: int): string =
  if i < it.fields.len: it.fields[i] else: ""

proc treeOf(items: seq[Item]): seq[TNode] =
  var path: seq[(int, TNode)]
  for it in items:
    let n = TNode(it: it)
    while path.len > 0 and path[^1][0] >= it.depth: path.setLen(path.len - 1)
    if path.len == 0: result.add n else: path[^1][1].kids.add n
    path.add (it.depth, n)

# ---- a family tree ---------------------------------------------------------------------------------------

type TreeM = object
  b, padX, padY, gapX, gapY, stub, stackGap, radius, ew, lw: float

proc treeMetrics(s: DiagramSpec; b: float): TreeM =
  TreeM(b: b, padX: b * 0.55, padY: b * 0.38, gapX: b * 0.7, gapY: b * 1.5, stub: b * 0.9, stackGap: b * 0.45,
        radius: (if s.radius < 0: 0.0 elif s.radius > 0: s.radius else: b * 0.3), ew: max(1.0, b * 0.06),
        lw: (if s.lineWidth > 0: s.lineWidth else: max(1.5, b * 0.075)))

proc sizeNode(s: DiagramSpec; m: TreeM; n: TNode) =
  let f1 = n.it.field(0)
  let f2 = n.it.field(1)
  let (c1, c2) = if n.it.hi: (s.theme.onAccent, s.theme.onAccent)
                 elif n.it.dashed: (s.theme.muted, s.theme.muted)
                 else: (s.theme.ink, s.theme.muted)
  let st1 = s.styleFor(f1, m.b, c1, "SemiBold")
  let st2 = s.styleFor(f2, m.b * 0.62, c2)
  let inner = clamp(max(textWidth(f1, st1), textWidth(f2, st2)) + 2, m.b * 2.2, m.b * 8)
  n.text = textBox(@[(f1, st1, 1, 0.0), (f2, st2, 1, m.b * 0.06)], 0, 0, inner)
  n.w = inner + 2 * m.padX
  n.h = (if f1.len + f2.len > 0: n.text.boxH.float else: m.b) + 2 * m.padY
  for k in n.kids: sizeNode(s, m, k)

proc rowPlace(kids: seq[TNode]; rtl: bool; gap: float): tuple[offs: seq[float]; lft, rgt: float] =
  ## (children side by side, the first at the right when right to left: their middles from the
  ## middle above them, and how far they reach left and right of it)
  var order: seq[int]
  for i in 0 ..< kids.len: order.add i
  if rtl: order.reverse
  var pos = newSeq[float](kids.len)
  var at = 0.0
  for j, i in order:
    if j > 0: at += gap
    at += kids[i].lft
    pos[i] = at
    at += kids[i].rgt
  let mid = (pos[order[0]] + pos[order[^1]]) / 2
  for i in 0 ..< kids.len: result.offs.add pos[i] - mid
  result.lft = mid
  result.rgt = at - mid

proc extents(m: TreeM; rtl: bool; n: TNode; stacked: bool) =
  for k in n.kids: extents(m, rtl, k, stacked or n.it.stack)
  n.lft = n.w / 2
  n.rgt = n.w / 2
  n.stackH = n.h
  n.offs = @[]
  if n.kids.len == 0: return
  if stacked or n.it.stack:
    let sg = if rtl: -1.0 else: 1.0
    for k in n.kids:
      let off = sg * (m.stub + k.w / 2)
      n.offs.add off
      n.lft = max(n.lft, k.lft - off)
      n.rgt = max(n.rgt, off + k.rgt)
      n.stackH += m.stackGap + k.stackH
  else:
    let r = rowPlace(n.kids, rtl, m.gapX)
    n.offs = r.offs
    n.lft = max(n.lft, r.lft)
    n.rgt = max(n.rgt, r.rgt)

proc rows(n: TNode; level: int; hs: var seq[float]) =
  n.level = level
  if hs.len <= level: hs.setLen(level + 1)
  hs[level] = max(hs[level], n.h)
  if not n.it.stack:
    for k in n.kids: rows(k, level + 1, hs)

proc placeStack(m: TreeM; n: TNode) =
  var y = n.y + n.h + m.stackGap
  let cx = n.x + n.w / 2
  for i, k in n.kids:
    k.x = cx + n.offs[i] - k.w / 2
    k.y = y
    placeStack(m, k)
    y += k.stackH + m.stackGap

proc placeRow(m: TreeM; n: TNode; cx: float; tops, hs: seq[float]) =
  n.x = cx - n.w / 2
  n.y = tops[n.level] + (hs[n.level] - n.h) / 2
  if n.it.stack: placeStack(m, n)
  else:
    for i, k in n.kids: placeRow(m, k, cx + n.offs[i], tops, hs)

proc treeLinks(s: DiagramSpec; m: TreeM; n: TNode; tops: seq[float]; inStack: bool;
               plain, dashed, hi: var Path) =
  let cx = n.x + n.w / 2
  let pb = n.y + n.h
  for i, k in n.kids:
    var sp: SubPath
    if inStack or n.it.stack:
      let ky = k.y + k.h / 2
      let edge = cx + n.offs[i] + (if n.offs[i] < 0: k.w / 2 else: -k.w / 2)
      sp = poly([(cx, pb), (cx, ky), (edge, ky)])
    else:
      let kx = cx + n.offs[i]
      let kt = k.y
      let busY = tops[n.level + 1] - m.gapY / 2
      sp = case s.links
           of lsElbow:
             if abs(kx - cx) < 0.5: poly([(cx, pb), (kx, kt)])
             else: poly([(cx, pb), (cx, busY), (kx, busY), (kx, kt)])
           of lsCurve: curve((cx, pb), (kx, kt), true)
           of lsStraight: poly([(cx, pb), (kx, kt)])
    if k.it.hi: hi.subs.add sp
    elif k.it.dashed: dashed.subs.add sp
    else: plain.subs.add sp
    treeLinks(s, m, k, tops, inStack or n.it.stack, plain, dashed, hi)

proc treeParts(s: DiagramSpec; x, y, w, h, b: float): Built =
  let roots = treeOf(parseItems(s.data))
  if roots.len == 0: return
  let m = treeMetrics(s, b)
  var hs: seq[float]
  for r in roots:
    sizeNode(s, m, r)
    extents(m, s.rtl, r, false)
    rows(r, 0, hs)
  let top = rowPlace(roots, s.rtl, m.gapX * 2)
  var gapY = m.gapY
  proc layout(gapY: float): (seq[float], float) =
    var tops = @[y]
    for i in 1 .. hs.len:
      let above = tops[^1]
      tops.add above + hs[i - 1] + gapY
    let cx = x + (w - top.lft - top.rgt) / 2 + top.lft
    var bottom = y
    for i, r in roots: placeRow(m, r, cx + top.offs[i], tops, hs)
    proc deepest(n: TNode; bottom: var float) =
      bottom = max(bottom, n.y + n.h)
      for k in n.kids: deepest(k, bottom)
    for r in roots: deepest(r, bottom)
    (tops, bottom - y)
  var (tops, tall) = layout(gapY)
  if h > tall + 1 and hs.len > 1:
    # (room to spare: the rows further apart -- twice as far at most)
    gapY += min((h - tall) / float(hs.len - 1), gapY)
    (tops, tall) = layout(gapY)
  if h > tall + 1:
    # (still room: the tree in the middle of its box, up and down)
    let dy = (h - tall) / 2
    for t in tops.mitems: t += dy
    proc shift(n: TNode) =
      n.y += dy
      for k in n.kids: shift(k)
    for r in roots: shift(r)
  var m2 = m
  m2.gapY = gapY
  var plain, dashed, hi: Path
  for r in roots: treeLinks(s, m2, r, tops, false, plain, dashed, hi)
  result.addShape(lineShape(plain, s.theme.line, m.lw), "Lines")
  result.addShape(lineShape(dashed, s.theme.line, m.lw, dashed = true), "Dashed lines")
  result.addShape(lineShape(hi, s.theme.accent, m.lw * 1.4), "Highlighted lines")
  proc boxes(n: TNode; res: var Built) =
    let sh = if n.it.hi: boxShape(n.x, n.y, n.w, n.h, m.radius, s.theme.accent, s.theme.accent, m.ew)
             elif n.it.dashed: boxShape(n.x, n.y, n.w, n.h, m.radius, 0, s.theme.line, m.ew * 1.2, dashed = true)
             else: boxShape(n.x, n.y, n.w, n.h, m.radius, s.theme.fill, s.theme.edge, m.ew)
    res.addShape(sh, "Box " & n.it.field(0))
    res.addText(n.text.moved(n.x + m.padX, n.y + m.padY))
    for k in n.kids: boxes(k, res)
  for r in roots: boxes(r, result)
  result.w = top.lft + top.rgt
  result.h = max(tall, h)

# ---- a dendrogram ----------------------------------------------------------------------------------------

proc dendroParts(s: DiagramSpec; x, y, w, h, b: float): Built =
  let roots = treeOf(parseItems(s.data))
  if roots.len == 0: return
  var leaves: seq[TNode]
  var deep = 0
  proc walk(n: TNode; level: int) =
    n.level = level
    deep = max(deep, level)
    if n.kids.len == 0: leaves.add n
    else:
      for k in n.kids: walk(k, level + 1)
  for r in roots: walk(r, 0)
  let hh = if h > 0: h else: w * 0.55
  let r0 = b * 0.2
  let lw = if s.lineWidth > 0: s.lineWidth else: max(1.5, b * 0.075)
  proc named(n: TNode): string =
    result = n.it.field(0)
    if result == "o" or result == "-": result = ""
  # (the leaves' names: under them, or beside them from the side)
  var labelsOf = newSeq[TextData](leaves.len)
  var labelW, labelH = 0.0
  let across = if s.horizontal: hh / leaves.len.float else: w / leaves.len.float
  if s.labels:
    for i, n in leaves:
      let t = named(n)
      if t.len == 0: continue
      let t2 = n.it.field(1)
      let c = if n.it.hi: s.theme.accent else: s.theme.ink
      let st = s.styleFor(t, b * 0.62, c, (if n.it.hi: "Bold" else: "Medium"))
      let st2 = s.styleFor(t2, b * 0.46, (if n.it.hi: s.theme.accent else: s.theme.muted))
      if s.horizontal:
        let tw = max(textWidth(t, st), textWidth(t2, st2)) + 2
        let side = if s.rtl: 2 else: 0
        labelsOf[i] = textBox(@[(t, st, side, 0.0), (t2, st2, side, 0.0)], 0, 0, tw)
        labelW = max(labelW, tw)
      else:
        labelsOf[i] = textBox(@[(t, st, 1, 0.0), (t2, st2, 1, 0.0)], 0, 0, max(b * 2, across * 0.96))
      labelH = max(labelH, labelsOf[i].boxH.float)
  let gap = b * 0.4
  # (where each node is: its leaves' place across, its level down -- the leaves all at the end)
  proc depthAt(level: int; leaf: bool): float =
    let lv = if leaf: deep else: level
    if s.horizontal:
      let span = w - (if labelW > 0: labelW + gap else: 0.0) - 4 * r0
      let d = 2 * r0 + lv.float * span / max(1, deep).float
      if s.rtl: x + w - d else: x + d
    else:
      let span = hh - (if labelH > 0: labelH + gap else: 0.0) - 4 * r0
      y + 2 * r0 + lv.float * span / max(1, deep).float
  for i, n in leaves:
    let a = (i.float + 0.5) * across
    if s.horizontal:
      n.y = y + a
      n.x = depthAt(n.level, true)
    else:
      n.x = if s.rtl: x + w - a else: x + a
      n.y = depthAt(n.level, true)
  proc inner(n: TNode) =
    if n.kids.len == 0: return
    for k in n.kids: inner(k)
    if s.horizontal:
      n.y = (n.kids[0].y + n.kids[^1].y) / 2
      n.x = depthAt(n.level, false)
    else:
      n.x = (n.kids[0].x + n.kids[^1].x) / 2
      n.y = depthAt(n.level, false)
  for r in roots: inner(r)
  var plain, dashed, hi, dots, hiDots: Path
  proc links(n: TNode) =
    for k in n.kids:
      let a = (n.x, n.y)
      let c = (k.x, k.y)
      let sp = case s.links
               of lsCurve: curve(a, c, not s.horizontal)
               of lsStraight: poly([a, c])
               of lsElbow:
                 if s.horizontal: poly([a, ((a[0] + c[0]) / 2, a[1]), ((a[0] + c[0]) / 2, c[1]), c])
                 else: poly([a, (a[0], (a[1] + c[1]) / 2), (c[0], (a[1] + c[1]) / 2), c])
      if k.it.hi: hi.subs.add sp
      elif k.it.dashed: dashed.subs.add sp
      else: plain.subs.add sp
      links(k)
    let r = if n.level == 0: r0 * 1.5 elif n.kids.len == 0: r0 else: r0 * 1.15
    if n.it.hi: hiDots.subs.add dot(n.x, n.y, r * 1.3) else: dots.subs.add dot(n.x, n.y, r)
  for r in roots: links(r)
  result.addShape(lineShape(plain, s.theme.line, lw), "Lines")
  result.addShape(lineShape(dashed, s.theme.line, lw, dashed = true), "Dashed lines")
  result.addShape(lineShape(hi, s.theme.accent, lw * 1.5), "Highlighted lines")
  result.addShape(ShapeData(path: dots, fill: paint(s.theme.line), stroke: noPaint(), kind: "Ellipse"), "Dots")
  result.addShape(ShapeData(path: hiDots, fill: paint(s.theme.accent), stroke: noPaint(), kind: "Ellipse"),
                  "Highlighted dots")
  for i, n in leaves:
    let t = labelsOf[i]
    if t.spans.len == 0: continue
    if s.horizontal:
      let lx = if s.rtl: n.x - r0 * 2 - gap - t.boxW.float else: n.x + r0 * 2 + gap
      result.addText(t.moved(lx, n.y - t.boxH.float / 2))
    else:
      result.addText(t.moved(n.x - t.boxW.float / 2, n.y + r0 * 2 + gap * 0.5))
  result.w = w
  result.h = hh

# ---- a timeline ------------------------------------------------------------------------------------------

proc timelineParts(s: DiagramSpec; x, y, w, h, b: float): Built =
  let items = parseItems(s.data)
  if items.len == 0: return
  let cx = x + w / 2
  let gap = b * 1.3
  let colW = max(b * 3, w / 2 - gap)
  let sd = b * 0.78
  var rowsL, rowsR: seq[TextData]
  var heights: seq[float]
  for it in items:
    let date = it.field(0)
    var dl = date
    var dr = date
    let slash = date.find(" / ")
    if slash >= 0:
      dl = date[0 ..< slash].strip
      dr = date[slash + 3 .. ^1].strip
    let ink = if it.hi: s.theme.accent else: s.theme.ink
    let L = textBox(@[(dl, s.styleFor(dl, sd, s.theme.accent, "SemiBold"), 2, 0.0),
                      (it.field(1), s.styleFor(it.field(1), b, ink, "Medium"), 2, b * 0.1),
                      (it.field(3), s.styleFor(it.field(3), b * 0.72, s.theme.muted), 2, b * 0.12)], x, 0, colW)
    let R = textBox(@[(dr, s.styleFor(dr, sd, s.theme.accent, "SemiBold"), 0, 0.0),
                      (it.field(2), s.styleFor(it.field(2), b, ink, "Medium"), 0, b * 0.1),
                      (it.field(4), s.styleFor(it.field(4), b * 0.72, s.theme.muted), 0, b * 0.12)],
                    cx + gap, 0, colW)
    rowsL.add L
    rowsR.add R
    heights.add max(L.boxH.float, R.boxH.float)
  var step = b * 1.1
  var tall = 0.0
  for hgt in heights: tall += hgt
  tall += step * float(items.len - 1)
  if h > tall + 1 and items.len > 1:
    let more = min((h - tall) / float(items.len - 1), step * 2)
    step += more
    tall += more * float(items.len - 1)
  let lw = if s.lineWidth > 0: s.lineWidth else: max(1.5, b * 0.075)
  var at = y
  var dots, hiDots: Path
  var first, last = 0.0
  for i, it in items:
    let dy = at + sd * 0.68
    if i == 0: first = dy
    last = dy
    if it.hi: hiDots.subs.add dot(cx, dy, b * 0.34) else: dots.subs.add dot(cx, dy, b * 0.26)
    rowsL[i].y = at.float32
    rowsR[i].y = at.float32
    at += heights[i] + step
  result.addShape(lineShape(Path(subs: @[poly([(cx, first), (cx, last)])]), s.theme.line, lw), "Line")
  result.addShape(ShapeData(path: dots, fill: paint(s.theme.paper), stroke: paint(s.theme.line),
                            strokeWidth: lw * 1.2, align: saInside, kind: "Ellipse"), "Dots")
  result.addShape(ShapeData(path: hiDots, fill: paint(s.theme.accent), stroke: noPaint(), kind: "Ellipse"),
                  "Highlighted dots")
  for i in 0 ..< items.len:
    result.addText(rowsL[i])
    result.addText(rowsR[i])
  result.w = w
  result.h = tall

# ---- a numbered list -------------------------------------------------------------------------------------

proc listParts(s: DiagramSpec; x, y, w, h, b: float): Built =
  let items = parseItems(s.data)
  if items.len == 0: return
  let d = b * 1.55
  let gap = b * 0.7
  let tx = if s.rtl: x else: x + d + gap
  let tw = max(b * 3, w - d - gap)
  let side = if s.rtl: 2 else: 0
  var blocks: seq[TextData]
  var heights: seq[float]
  for it in items:
    let t = textBox(@[(it.field(0), s.styleFor(it.field(0), b, (if it.hi: s.theme.accent else: s.theme.ink),
                                               "Medium"), side, 0.0),
                      (it.field(1), s.styleFor(it.field(1), b * 0.72, s.theme.muted), side, b * 0.18)], tx, 0, tw)
    blocks.add t
    # (the first line's middle on the number's middle)
    heights.add max(d, d / 2 - b * 0.68 + t.boxH.float)
  var step = b * 1.2
  var tall = 0.0
  for hgt in heights: tall += hgt
  tall += step * float(items.len - 1)
  if h > tall + 1 and items.len > 1:
    let more = min((h - tall) / float(items.len - 1), step * 1.5)
    step += more
    tall += more * float(items.len - 1)
  var badges: Path
  var rules: Path
  var nums: seq[TextData]
  var at = y
  let bx = if s.rtl: x + w - d else: x
  for i, it in items:
    badges.subs.add dot(bx + d / 2, at + d / 2, d / 2)
    let ns = $(i + 1)
    var st = s.styleFor("ع", b * 0.8, s.theme.onAccent, "Bold")
    if not s.arabicDigits:
      st.digits = 0
      st.lang = ""
    let nt = textBox(@[(ns, st, 1, 0.0)], bx, 0, d)
    nums.add nt.moved(bx, at + d / 2 - nt.boxH.float / 2 + b * 0.08)
    blocks[i].y = float32(at + d / 2 - b * 0.68)
    if i < items.high:
      let ry = at + heights[i] + step / 2
      rules.subs.add poly([(x, ry), (x + w, ry)])
    at += heights[i] + step
  result.addShape(lineShape(rules, s.theme.line, max(1.0, b * 0.04)), "Rules")
  result.addShape(ShapeData(path: badges, fill: paint(s.theme.accent), stroke: noPaint(), kind: "Ellipse"),
                  "Numbers")
  for t in nums: result.addText(t)
  for t in blocks: result.addText(t)
  result.w = w
  result.h = tall

# ---- a note ----------------------------------------------------------------------------------------------

proc noteParts(s: DiagramSpec; x, y, w, h, b: float): Built =
  let items = parseItems(s.data)
  if items.len == 0: return
  let pad = b * 0.9
  let iw = max(b * 3, w - 2 * pad)
  var en, ar = ""
  for f in items[0].fields:
    if arabicFirst(f): ar = f else: en = f
  var lab = s.styleFor(en, b * 0.6, s.theme.accent, "Bold")
  lab.allCaps = true
  lab.tracking = 120
  var left = textBox(@[(en, lab, 0, 0.0)], x + pad, y + pad, iw)
  var right = textBox(@[(ar, s.styleFor(ar, b * 0.8, s.theme.accent, "Bold"), 2, 0.0)], x + pad, y + pad, iw)
  if en.len > 0 and ar.len > 0:
    # (both labels on one baseline)
    let d = firstBaseline(right) - firstBaseline(left)
    if d > 0: left.y += d.float32 else: right.y -= d.float32
  let labH = max(if en.len > 0: float(left.y + left.boxH) - y - pad else: 0.0,
                 if ar.len > 0: float(right.y + right.boxH) - y - pad else: 0.0)
  var paras: seq[Para]
  for it in items[1 .. ^1]:
    for f in it.fields:
      let ara = arabicFirst(f)
      paras.add (f, s.styleFor(f, (if ara: b else: b * 0.82), (if ara: s.theme.ink else: s.theme.muted)),
                 (if ara: 2 else: 0), b * 0.5)
  let by = y + pad + (if labH > 0: labH + b * 0.45 else: 0.0)
  let body = textBox(paras, x + pad, by, iw)
  let tall = (if paras.len > 0: by + body.boxH.float else: by) + pad - y
  result.addShape(boxShape(x, y, w, tall, (if s.radius < 0: 0.0 elif s.radius > 0: s.radius else: b * 0.4),
                           s.theme.fill, s.theme.edge, max(1.0, b * 0.06)), "Note")
  if en.len > 0: result.addText(left)
  if ar.len > 0: result.addText(right)
  result.addText(body)
  result.w = w
  result.h = tall

# ---- a title ---------------------------------------------------------------------------------------------

proc titleParts(s: DiagramSpec; x, y, w, h, b: float): Built =
  let items = parseItems(s.data)
  if items.len == 0: return
  var above, below: seq[Para]
  var rule = false
  var n = 0
  for it in items:
    if it.field(0).startsWith("---"):
      rule = true
      continue
    for f0 in it.fields:
      var f = f0
      if f.len == 0: continue
      if rule:
        if f.startsWith(". "):
          f = f[2 .. ^1]
          below.add (f, s.styleFor(f, b * 0.6, s.theme.muted), 1, b * 0.7)
        else:
          below.add (f, s.styleFor(f, b * 0.85, s.theme.muted), 1, b * 0.25)
      else:
        if n == 0: above.add (f, s.styleFor(f, b * 2.3, s.theme.ink, "Bold"), 1, 0.0)
        else: above.add (f, s.styleFor(f, b * 1.25, s.theme.ink, "Medium"), 1, b * 0.55)
        inc n
  let A = textBox(above, x, y, w)
  var at = y + (if above.len > 0: A.boxH.float else: 0.0)
  var ruleBox: ShapeData
  if rule:
    at += b * 0.7
    let rw = b * 2.6
    let rh = max(2.0, b * 0.14)
    ruleBox = boxShape(x + (w - rw) / 2, at, rw, rh, 0, s.theme.accent, 0, 0)
    at += rh + b * 0.7
  let B = textBox(below, x, at, w)
  if below.len > 0: at += B.boxH.float
  var tall = at - y
  # (in the middle of its box, up and down)
  let dy = if h > tall: (h - tall) / 2 else: 0.0
  if rule:
    for sp in ruleBox.path.subs.mitems:
      for p in sp.pts.mitems:
        p.p[1] += dy
        p.inH[1] += dy
        p.outH[1] += dy
    result.addShape(ruleBox, "Rule")
  result.addText(A.moved(x, y + dy))
  result.addText(B.moved(x, B.y.float + dy))
  result.w = w
  result.h = max(tall, h)

# ---- placing ---------------------------------------------------------------------------------------------

proc build(s: DiagramSpec; x, y, w, h, b: float): Built =
  case s.kind
  of dkTree: treeParts(s, x, y, w, h, b)
  of dkDendrogram: dendroParts(s, x, y, w, h, b)
  of dkTimeline: timelineParts(s, x, y, w, h, b)
  of dkList: listParts(s, x, y, w, h, b)
  of dkNote: noteParts(s, x, y, w, h, b)
  of dkTitle: titleParts(s, x, y, w, h, b)

proc diagramBaseSize*(s: DiagramSpec; w: float): float =
  ## The main text's size a diagram `w` wide starts from: its `size`, else by its width (27
  ## pixels for 920).
  if s.size > 0: s.size else: clamp(w / 34, 8, 400)

proc diagramParts*(s: DiagramSpec; box: Rect): tuple[parts: seq[DiagramPart]; h: float] =
  ## The layers of the diagram `s` set in `box` (its height 0: as tall as it needs), its text
  ## smaller where it would not fit; how tall it is.
  carry()
  let (x, y, w, h) = (box.x.float, box.y.float, max(1, box.w).float, max(0, box.h).float)
  var b = diagramBaseSize(s, w)
  var r: Built
  for _ in 0 .. 5:
    r = build(s, x, y, w, h, b)
    var k = 1.0
    if r.w > w + 0.5: k = min(k, w / r.w)
    if h > 0 and r.h > h + 0.5: k = min(k, h / r.h)
    if k >= 0.999 or b <= 6: break
    b = max(6.0, b * max(0.4, k * 0.985))
  (r.parts, r.h)

proc toJson*(t: DiagramTheme): JsonNode =
  ## The theme as JSON.
  %*{"name": t.name, "paper": t.paper, "ink": t.ink, "accent": t.accent, "onAccent": t.onAccent,
     "fill": t.fill, "edge": t.edge, "muted": t.muted, "line": t.line, "arabicFont": t.arabicFont,
     "latinFont": t.latinFont}

proc themeFrom*(j: JsonNode): DiagramTheme =
  ## A theme from its JSON (Parchment's colors where it says none).
  result = diagramTheme(j{"name"}.getStr("Parchment"))
  proc col(key: string; v: var uint32) =
    if j.hasKey(key): v = uint32(j[key].getBiggestInt and 0xFFFFFFFF)
  col("paper", result.paper)
  col("ink", result.ink)
  col("accent", result.accent)
  col("onAccent", result.onAccent)
  col("fill", result.fill)
  col("edge", result.edge)
  col("muted", result.muted)
  col("line", result.line)
  result.arabicFont = j{"arabicFont"}.getStr
  result.latinFont = j{"latinFont"}.getStr

proc toJson*(s: DiagramSpec): JsonNode =
  ## The diagram as JSON (kept with its group: `Layer.meta`).
  %*{"kind": $s.kind, "data": s.data, "theme": toJson(s.theme), "size": s.size, "rtl": s.rtl,
     "arabicDigits": s.arabicDigits, "links": $s.links, "radius": s.radius, "lineWidth": s.lineWidth,
     "horizontal": s.horizontal, "labels": s.labels}

proc diagramFrom*(j: JsonNode): DiagramSpec =
  ## A diagram from its JSON.
  result.kind = parseEnum[DiagramKind](j{"kind"}.getStr, dkTree)
  result.data = j{"data"}.getStr
  result.theme = if j.hasKey("theme"): themeFrom(j["theme"]) else: diagramTheme("Parchment")
  result.size = j{"size"}.getFloat
  result.rtl = j{"rtl"}.getBool
  result.arabicDigits = j{"arabicDigits"}.getBool
  result.links = parseEnum[LinkStyle](j{"links"}.getStr, lsElbow)
  result.radius = j{"radius"}.getFloat
  result.lineWidth = j{"lineWidth"}.getFloat
  result.horizontal = j{"horizontal"}.getBool
  result.labels = j{"labels"}.getBool

proc diagramMeta*(s: DiagramSpec; box: Rect): string =
  ## What a diagram's group keeps (`Layer.meta`): the diagram and its box.
  $(%*{"diagram": toJson(s), "box": [box.x, box.y, box.w, box.h]})

proc isDiagram*(L: Layer): bool =
  ## Whether `L` is a diagram's group.
  L != nil and L.group and L.meta.startsWith("{\"diagram\"")

proc diagramOf*(L: Layer): tuple[spec: DiagramSpec; box: Rect; ok: bool] =
  ## The diagram a group was made from, and its box (`ok` false: it is not one).
  if not L.isDiagram: return
  try:
    let j = parseJson(L.meta)
    result.spec = diagramFrom(j["diagram"])
    let b = j{"box"}.getElems
    if b.len == 4: result.box = rect(b[0].getInt, b[1].getInt, max(1, b[2].getInt), max(0, b[3].getInt))
    result.ok = true
  except CatchableError, Defect: discard

proc addParts*(d: Doc; parts: seq[DiagramPart]): seq[Layer] =
  ## The parts as layers above the current one, one above another (undoable in a step:
  ## `touchLayers` first).
  for p in parts:
    if p.isText: result.add d.addTextLayer(p.text)
    else: result.add d.addShapeLayer(p.shape, p.name)

proc placeDiagram*(d: Doc; s: DiagramSpec; box: Rect; name = ""): Layer =
  ## The diagram `s` set in `box` (its height 0: as tall as it needs) as shape and type layers in a
  ## group (named `name`, else what it is) above the current layer, the group current, the diagram
  ## kept with it (`diagramOf`). nil when it has nothing to draw. Undoable in a step:
  ## `touchLayers` first.
  let (parts, _) = diagramParts(s, box)
  if parts.len == 0: return nil
  let made = d.addParts(parts)
  var idxs: seq[int]
  for L in made: idxs.add d.layers.find(L)
  result = d.groupLayers(idxs, if name.len > 0: name else: $s.kind)
  if result != nil:
    result.collapsed = true        # (closed in the Layers palette: what comes next goes over it)
    result.meta = diagramMeta(s, box)
    d.cur = d.layers.find(result)

proc defaultDiagram*(kind: DiagramKind): DiagramSpec =
  ## A diagram of `kind` to start from: Parchment, Arabic first, a few lines of text about Arabic
  ## writing to type over.
  result = DiagramSpec(kind: kind, theme: diagramTheme("Parchment"), rtl: true, arabicDigits: true)
  case kind
  of dkTree:
    result.data = "الفينيقية | Phoenician\n" &
                  "  > اليونانية | Greek\n" &
                  "    اللاتينية | Latin\n" &
                  "    ~ الكريلية | Cyrillic\n" &
                  "  * الآرامية | Aramaic\n" &
                  "    ~ العبرية المربعة | Square Hebrew\n" &
                  "    * النبطية | Nabataean\n" &
                  "      * العربية | Arabic\n" &
                  "    ~ السريانية | Syriac"
  of dkDendrogram:
    result.links = lsCurve
    result.labels = true
    result.data = "الفينيقية | Phoenician\n" &
                  "  اليونانية | Greek\n" &
                  "    اللاتينية | Latin\n" &
                  "    الكريلية | Cyrillic\n" &
                  "  * الآرامية | Aramaic\n" &
                  "    العبرية | Hebrew\n" &
                  "    * النبطية | Nabataean\n" &
                  "      * العربية | Arabic\n" &
                  "    السريانية | Syriac"
  of dkTimeline:
    result.data = "328 CE / ٣٢٨ م | Namara inscription | نقش النمارة\n" &
                  "512 CE / ٥١٢ م | Zabad inscription | نقش زبد\n" &
                  "* 568 CE / ٥٦٨ م | Harran inscription | نقش حران\n" &
                  "7th century / القرن السابع | Early Kufic | الخط الكوفي المبكر\n" &
                  "10th century / القرن العاشر | Proportioned script | الخط المنسوب"
  of dkList:
    result.data = "الخط النبطي أصل الحروف العربية | Nabataean script, the root of the Arabic letters\n" &
                  "تتصل الحروف وتتخذ أشكالها | The letters join and take their shapes\n" &
                  "* نشأة الخط الكوفي | Kufic script appears\n" &
                  "إضافة النقاط والحركات | Dots and vowel marks are added"
  of dkNote:
    result.data = "ملاحظة | Note\n" &
                  "تواريخ النقوش تقريبية، وما زال تاريخ الكتابة العربية موضع بحث.\n" &
                  "The inscriptions' dates are approximate; the history of Arabic writing is still studied."
  of dkTitle:
    result.data = "تاريخ الكتابة العربية\n" &
                  "The History of Arabic Writing\n" &
                  "---\n" &
                  "من النقوش النبطية إلى الخط الحديث\n" &
                  "From Nabataean inscriptions to modern script\n" &
                  ". Sources: add yours here"

# ---- slides ----------------------------------------------------------------------------------------------

proc slideMargin*(board: Rect): float =
  ## How far a slide's header, footer and content stand in from its edges (80 pixels on 1080).
  board.w.float * 0.074

proc slideBase(board: Rect): float = board.w.float / 40

proc slideRuleY(board: Rect): float = board.y.float + slideMargin(board) + slideBase(board) * 3.4

proc slideFootY(board: Rect): float = board.y.float + board.h.float - slideMargin(board) - slideBase(board) * 1.3

proc slideContent*(board: Rect): Rect =
  ## The room a slide (`placeSlideFrame`) has between its header and its footer, for a diagram.
  let m = slideMargin(board)
  let b = slideBase(board)
  let top = slideRuleY(board) + b * 1.3
  let bottom = slideFootY(board) - b * 1.0
  rect(int(round(board.x.float + m)), int(round(top)), max(1, int(round(board.w.float - 2 * m))),
       max(1, int(round(bottom - top))))

proc slideFrameParts*(board: Rect; t: DiagramTheme; f: SlideFrame): seq[DiagramPart] =
  ## A slide's header and footer as layers: the English title and subtitle at the left, the
  ## Arabic ones at the right (its subtitle in the accent), a rule under them; a hairline above the
  ## sources (English left, Arabic right) and the page number in the middle.
  carry()
  let s = DiagramSpec(theme: t, arabicDigits: f.arabicDigits)
  let m = slideMargin(board)
  let b = slideBase(board)
  let x0 = board.x.float + m
  let iw = board.w.float - 2 * m
  let y0 = board.y.float + m
  var r: Built
  let en = textBox(@[(f.enTitle, s.styleFor(f.enTitle, b * 0.95, t.ink, "SemiBold"), 0, 0.0),
                     (f.enSubtitle, s.styleFor(f.enSubtitle, b * 0.62, t.muted), 0, b * 0.15)], x0, y0, iw * 0.44)
  let ar = textBox(@[(f.arTitle, s.styleFor(f.arTitle, b * 1.45, t.ink, "Bold"), 2, 0.0),
                     (f.arSubtitle, s.styleFor(f.arSubtitle, b * 0.8, t.accent, "Medium"), 2, b * 0.3)],
                   x0 + iw * 0.42, y0, iw * 0.58)
  r.addText(en)
  r.addText(ar)
  let ry = slideRuleY(board)
  r.addShape(boxShape(x0, ry, iw, max(2.0, b * 0.1), 0, t.ink, 0, 0), "Rule")
  let fy = slideFootY(board)
  r.addShape(boxShape(x0, fy, iw, max(1.0, b * 0.04), 0, t.line, 0, 0), "Hairline")
  let sy = fy + b * 0.45
  r.addText(textBox(@[(f.enSource, s.styleFor(f.enSource, b * 0.5, t.muted), 0, 0.0)], x0, sy, iw * 0.4))
  r.addText(textBox(@[(f.arSource, s.styleFor(f.arSource, b * 0.55, t.muted), 2, 0.0)], x0 + iw * 0.6, sy,
                    iw * 0.4))
  if f.pageNumbers:
    var st = s.styleFor("<#> / <##>", b * 0.55, t.muted, "Medium")
    if f.arabicDigits:
      st.digits = 1
      st.lang = "ar"
    var pn = textBox(@[("<#> / <##>", st, 1, 0.0)], x0 + iw * 0.4, sy, iw * 0.2)
    if f.arabicDigits: pn.para.rtl = 2
    r.addText(pn, "Page number")
  r.parts

proc placeSlideFrame*(d: Doc; board: Rect; t: DiagramTheme; f: SlideFrame): Layer =
  ## A slide's header and footer (`slideFrameParts`) in a group "Header and Footer" above the
  ## current layer. Undoable in a step: `touchLayers` first.
  let made = d.addParts(slideFrameParts(board, t, f))
  var idxs: seq[int]
  for L in made: idxs.add d.layers.find(L)
  result = d.groupLayers(idxs, "Header and Footer")
  if result != nil: result.collapsed = true

proc defaultCarousel*(): CarouselSpec =
  ## Eight slides of 1080 x 1350 in Parchment: a title page, then a numbered list, a family tree, a
  ## timeline, and a tree of stacked branches over a note, to type over; a header and a footer in
  ## English and Arabic on each, page numbers in Arabic-Indic digits.
  CarouselSpec(slides: 8, w: 1080, h: 1350, theme: diagramTheme("Parchment"), titleSlide: true,
               samples: true, title: defaultDiagram(dkTitle).data,
               frame: SlideFrame(enTitle: "History of Arabic Writing", enSubtitle: "From inscriptions to script",
                                 arTitle: "تاريخ الكتابة العربية", arSubtitle: "من النقش إلى الخط",
                                 enSource: "Source: your reference", arSource: "المصدر: مرجعك",
                                 pageNumbers: true, arabicDigits: true))

proc newCarousel*(c: CarouselSpec; name = "Carousel"): Doc =
  ## A document of `c.slides` artboards side by side, each its size and in the theme's paper, with
  ## its header and footer (`placeSlideFrame`); the first a title page and the next ones a diagram
  ## each to start from, when asked. Its history starts empty.
  carry()
  let n = clamp(c.slides, 1, 100)
  let (w, h) = (max(64, c.w), max(64, c.h))
  result = newDoc(w, h, 0'u32, 72, name)
  let d = result
  d.layers[0].background = false
  let gap = max(20, w div 10)
  for k in 0 ..< n:
    let at = if k == 0: rect(0, 0, w, h) else: rect(d.boards[0].r.x + k * (w + gap), d.boards[0].r.y, w, h)
    discard d.addArtboard(at, "Slide " & $(k + 1), c.theme.paper)
  let samples = [dkList, dkTree, dkTimeline, dkNote]
  for k in 0 ..< n:
    let board = d.boards[k].r
    if k == 0 and c.titleSlide:
      # (the title page: the tree of dots over the title, no header)
      let m = slideMargin(board)
      let iw = board.w.float - 2 * m
      var den = defaultDiagram(dkDendrogram)
      den.theme = c.theme
      den.labels = false
      let dh = board.h.float * 0.3
      discard d.placeDiagram(den, rect(int(board.x.float + m + iw * 0.15), int(board.y.float + m * 1.4),
                                       int(iw * 0.7), int(dh)), "Tree of Dots")
      var ti = defaultDiagram(dkTitle)
      ti.theme = c.theme
      if c.title.len > 0: ti.data = c.title
      let ty = board.y.float + m * 1.4 + dh + slideBase(board) * 2
      discard d.placeDiagram(ti, rect(int(board.x.float + m), int(ty), int(iw),
                                      int(slideFootY(board) - ty - slideBase(board))), "Title")
      var f = c.frame
      f.enTitle = ""
      f.enSubtitle = ""
      f.arTitle = ""
      f.arSubtitle = ""
      # (no header on a title page: no rule under it either)
      var parts: seq[DiagramPart]
      for p in slideFrameParts(board, c.theme, f):
        if p.name != "Rule": parts.add p
      var idxs: seq[int]
      for L in d.addParts(parts): idxs.add d.layers.find(L)
      let g = d.groupLayers(idxs, "Footer")
      if g != nil: g.collapsed = true
    else:
      discard d.placeSlideFrame(board, c.theme, c.frame)
      let j = k - (if c.titleSlide: 1 else: 0)
      if c.samples and j >= 0 and j < samples.len:
        let room = slideContent(board)
        var s = defaultDiagram(samples[j])
        s.theme = c.theme
        if samples[j] == dkNote:
          # (a tree whose branches hang one under another beside its line, a note under it)
          var t = defaultDiagram(dkTree)
          t.theme = c.theme
          t.data = "> الخط العربي | Arabic script\n" &
                   "  * الكوفي | Kufic\n" &
                   "  النسخ | Naskh\n" &
                   "  الثلث | Thuluth\n" &
                   "  ~ الديواني | Diwani"
          let (_, nh) = diagramParts(s, rect(room.x, 0, room.w, 0))
          let ny = room.y + room.h - int(ceil(nh))
          discard d.placeDiagram(t, rect(room.x, room.y, room.w,
                                         max(1, ny - room.y - int(slideBase(board) * 1.5))))
          discard d.placeDiagram(s, rect(room.x, ny, room.w, 0))
        else:
          discard d.placeDiagram(s, room)
  d.boardCur = 0
  d.grown = (0, 0)
  discard d.syncBoardNumbers()
  d.cur = d.layers.high
  d.clearHistory()
  d.markAll()
  d.modified = false

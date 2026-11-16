## Photoshop PDF: a document as a PDF page -- for the screen and the web
## (small: JPEG, a lower resolution), for printing at home or by a lab
## (high resolution), or for a press (printing inks: CMYK; crop marks and
## bleed). Type and shape layers go in as vectors, sharp at any size; the
## rest as pictures at the resolution asked (up to 3500 pixels an inch).
## `savePdfPresentation` makes one PDF of several documents, a page each.
##
## .. code-block:: nim
##   var o = pdfPreset(ppPress)
##   o.marks = true
##   doc.savePdf("cover.pdf", o)

import std/[math, unicode, tables, strutils]
import gfx, pdf, photo, photoinks, textengine, parallel, photoshapes

type
  PdfPresetKind* = enum
    ## The kinds of PDF the Save As PDF dialog offers (`pdfPreset` gives
    ## their options).
    ppWeb = "Smallest File Size (screen, web)"
    ppPrint = "High Quality Print"
    ppPress = "Press Quality (CMYK)"
    ppCustom = "Custom"

  PdfOptions* = object
    ## How a document goes into a PDF.
    ppi*: int                ## the pictures' resolution, pixels an inch (0: the document's own);
                             ## 72 .. 3500 (more pixels made when it is higher than the document's)
    cmyk*: bool              ## colors in printing inks (Color Settings' separation), for a press
    jpeg*: bool              ## pictures as JPEG (small) -- else lossless (ZIP)
    quality*: int            ## ... the JPEG's quality, 1..100
    vectors*: bool           ## type and shape layers as outlines (sharp at any size)
    marks*: bool             ## crop marks round the page (where it is cut)
    regMarks*: bool          ## registration marks (the plates lined up)
    colorBars*: bool         ## color bars (each ink and their mixes; a ramp of black)
    pageInfo*: bool          ## the file's name, the date, the inks, under the page
    bleedMm*: float          ## the bleed, mm (with marks): the picture's edges drawn out past the cut
    liveText*: bool          ## type as text (its font in the file): found, copied, edited in a PDF
                             ## editor later -- else as outlines
    standard*: string        ## "PDF/X-4", "PDF/X-1a:2003": for a press ("" none)
    condition*: string       ## ... the printing condition ("FOGRA39", "GRACoL2006"...)
    profile*: string         ## ... its ICC profile, when there is one (embedded)
    maxPixels*: int          ## a picture never larger than this (0: 160 million)
    title*, author*: string  ## the PDF's title and author ("" title: the document's name)
    noLinks*: bool           ## the text's hyperlinks and cross-references not made links
    noBookmarks*: bool       ## the documents' bookmarks not made the PDF's
    dests*: Table[string, tuple[page: int; top: float]]
      ## (a book: where each text destination is -- its page in the PDF, 1 the first, and points
      ## down from its top; links to one go there. Made by whoever adds the pages)
    pageMap*: seq[int]       ## (a book: each of its pages' page in the PDF, 1 the first, 0 not in it)

proc pdfPreset*(k: PdfPresetKind): PdfOptions =
  ## Photoshop's presets, more or less.
  case k
  of ppWeb: PdfOptions(ppi: 150, jpeg: true, quality: 72, vectors: true, liveText: true)
  of ppPrint: PdfOptions(ppi: 300, jpeg: true, quality: 94, vectors: true, liveText: true)
  of ppPress: PdfOptions(ppi: 300, cmyk: true, vectors: true, liveText: true, marks: true, regMarks: true,
                         colorBars: true, pageInfo: true, bleedMm: 3, standard: "PDF/X-4", condition: "FOGRA39")
  of ppCustom: PdfOptions(ppi: 300, vectors: true, quality: 90, liveText: true)

const MarkRoom = 36.0          ## (points round the page for the printer's marks: half an inch)

proc vectorOk(d: Doc; i: int): bool =
  ## (a type or shape layer that can go in as outlines: nothing above it
  ## mixes with it, nothing changes it but its own opacity)
  let L = d.layers[i]
  if not L.visible or L.group or L.depth != 0 or L.mode != bmNormal or L.clipped or L.hasStyle or
     L.fill != 100 or L.isSmart:
    return false
  if L.mask != nil and not L.maskOff: return false
  if L.isShape:
    let s = L.shape
    if not s.isPlain:
      # (drawn in parts: as outlines when every part is plain color, at full opacity, normal)
      for (part, pop, pmode) in exportParts(s):
        if part.fill.kind notin {spNone, spColor} or part.stroke.kind notin {spNone, spColor} or
           pop != 100 or pmode != bmNormal or (part.stroke.kind == spColor and part.align != saCenter):
          return false
      return true
    if s.fill.kind notin {spNone, spColor} or s.stroke.kind notin {spNone, spColor}: return false
    if s.stroke.kind == spColor and s.strokeWidth > 0 and s.align != saCenter: return false
    if s.startEnd != leNone or s.endEnd != leNone: return false   # (a line's arrowheads: as pixels)
    for sp in s.path.subs:
      if sp.op != poAdd: return false
  elif not L.isText: return false
  for j in i + 1 ..< d.layers.len:
    let A = d.layers[j]
    if not A.visible: continue
    if A.adjust.kind.len > 0 or A.mode != bmNormal or (A.clipped and j == i + 1): return false
  true

proc paintOf(p: PdfPage; c: uint32; cmyk, stroke: bool) =
  if cmyk:
    let ink = inkOf(c)
    let (cc, mm, yy, kk) = (ink[0].float / 255, ink[1].float / 255, ink[2].float / 255, ink[3].float / 255)
    if stroke: p.strokeCmyk(cc, mm, yy, kk) else: p.fillCmyk(cc, mm, yy, kk)
  else:
    let col = color(uint8((c shr 16) and 255), uint8((c shr 8) and 255), uint8(c and 255))
    if stroke: p.strokeColor(col) else: p.fillColor(col)

proc addRasterPx(p: PdfPage; px: seq[uint32]; pw, ph: int; dpi: float; ox, oy, k: float; o: PdfOptions) =
  ## (a picture `pw` x `ph`, cropped to what is in it, at the resolution
  ## asked, put in the page)
  var x0 = pw
  var y0 = ph
  var x1 = -1
  var y1 = -1
  var one = 0'u32                    # (its color, while all of it is one)
  var flat = true
  var count = 0
  for y in 0 ..< ph:
    for x in 0 ..< pw:
      let c = px[y * pw + x]
      if (c shr 24) != 0:
        x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
        if count == 0: one = c
        elif c != one: flat = false
        inc count
  if x1 < x0: return
  let cw = x1 - x0 + 1
  let ch = y1 - y0 + 1
  if flat and (one shr 24) == 255 and count == cw * ch:
    # (a rectangle of one color -- a page's paper, a rule, a panel: drawn
    # as one, not kept as a picture of it)
    p.paintOf(one, o.cmyk, false)
    p.rect(ox + x0.float * k, oy + y0.float * k, cw.float * k, ch.float * k)
    p.fill()
    return
  var crop = newSeq[uint32](cw * ch)
  for y in 0 ..< ch:
    for x in 0 ..< cw: crop[y * cw + x] = px[(y0 + y) * pw + x0 + x]
  # (the resolution asked: more pixels or fewer)
  let want = if o.ppi > 0: o.ppi.float else: dpi
  var f = want / max(1.0, dpi)
  let limit = if o.maxPixels > 0: o.maxPixels.float else: 160e6
  if cw.float * ch.float * f * f > limit: f = sqrt(limit / (cw.float * ch.float))
  var bw = cw
  var bh = ch
  if abs(f - 1) > 0.01:
    bw = max(1, int(round(cw.float * f)))
    bh = max(1, int(round(ch.float * f)))
    crop = resample(crop, cw, ch, bw, bh, if f > 1: rsLanczos else: rsBicubic)
  let x = ox + x0.float * k
  let y = oy + y0.float * k
  let w = cw.float * k
  let h = ch.float * k
  if o.cmyk:
    var inks = newString(bw * bh * 4)
    var alpha = newString(bw * bh)
    let cp = cast[ptr UncheckedArray[uint32]](addr crop[0])
    let ip = cast[ptr UncheckedArray[char]](addr inks[0])
    let ap = cast[ptr UncheckedArray[char]](addr alpha[0])
    parallelRows(bh, row):
      for i in row * bw ..< (row + 1) * bw:
        let c = cp[i]
        let ink = inkOf(c)
        for n in 0 .. 3: ip[i * 4 + n] = char(ink[n])
        ap[i] = char(c shr 24)
    p.imageCmyk(bw, bh, inks, x, y, w, h, alpha)
  else:
    let b = newBitmap(bw, bh)
    b.px = crop
    if o.jpeg: p.imageJpeg(b, x, y, w, h, quality = (if o.quality > 0: o.quality else: 85))
    else: p.image(b, x, y, w, h)

proc addRaster(p: PdfPage; d: Doc; px: seq[uint32]; ox, oy, k: float; o: PdfOptions; bleedPx = 0) =
  ## (the picture of some layers; with `bleedPx`, its edges drawn out that
  ## far past the cut -- the bleed a press trims into)
  if bleedPx <= 0:
    p.addRasterPx(px, d.w, d.h, d.dpi, ox, oy, k, o)
    return
  let e = bleedPx
  let w2 = d.w + 2 * e
  let h2 = d.h + 2 * e
  var ext = newSeqUninit[uint32](w2 * h2)
  for y in 0 ..< h2:
    let sy = clamp(y - e, 0, d.h - 1)
    for x in 0 ..< w2: ext[y * w2 + x] = px[sy * d.w + clamp(x - e, 0, d.w - 1)]
  p.addRasterPx(ext, w2, h2, d.dpi, ox - e.float * k, oy - e.float * k, k, o)

proc addVector(p: PdfPage; d: Doc; L: Layer; ox, oy, k: float; o: PdfOptions) =
  ## (a type or shape layer as outlines)
  if L.opacity < 100:
    p.saveState()
    p.opacity(L.opacity / 100)
  template X(v: float): float = ox + v * k
  template Y(v: float): float = oy + v * k
  var tx = if L.isText: d.effectiveText(L) else: TextData()
  if L.isText and d.flowsOn(L): tx.clipOverflow = true
  if L.isText and o.liveText and tx.warp.style == wsNone and tx.path.len == 0 and not tx.vertical:
    # type as text: each run of glyphs in one font, size and color as text
    # in that font (embedded), the characters kept -- a PDF editor edits it
    let lay = layoutText(tx)
    var cps: seq[string]
    for sp in tx.spans:
      for r in sp.text.runes: cps.add r.toUTF8
    var allOk = true
    for g in lay.glyphs:
      if not canEmbed(g.face): allOk = false
    if allOk:
      template bars(list: seq[Decoration]) =
        # (a table's fills under the letters; underlines, strikes and a table's lines over them)
        for dcr in list:
          p.paintOf(dcr.color, o.cmyk, false)
          p.rect(X(dcr.x0.float), Y(float(dcr.y - dcr.thick / 2)), float(dcr.x1 - dcr.x0) * k, dcr.thick.float * k)
          p.fill()
      bars(lay.backs)
      var i = 0
      while i < lay.glyphs.len:
        let g0 = lay.glyphs[i]
        var j = i
        var run: seq[tuple[gid: int; x, y: float; text: string]]
        while j < lay.glyphs.len:
          let g = lay.glyphs[j]
          if g.face != g0.face or g.size != g0.size or g.color != g0.color or g.hScale != g0.hScale or
             g.vScale != g0.vScale or g.shear != g0.shear or g.embolden != g0.embolden: break
          run.add (g.gid, X(g.x.float), Y(g.y.float), (if g.index in 0 .. cps.high: cps[g.index] else: ""))
          inc j
        p.paintOf(g0.color, o.cmyk, false)
        if g0.embolden > 0:
          # (faux bold: the letters filled and stroked a little)
          p.paintOf(g0.color, o.cmyk, true)
          p.lineWidth(g0.embolden.float * k)
          p.textRender(2)
        p.glyphText(g0.face, g0.size.float * k, run, hScale = g0.hScale.float, vScale = g0.vScale.float,
                    shear = g0.shear.float)
        if g0.embolden > 0: p.textRender(0)
        i = j
      bars(lay.decorations)
      if L.opacity < 100: p.restoreState()
      return
  if L.isText:
    for t in textOutlines(tx, layoutText(tx), fine = true):
      if t.polys.len == 0: continue
      for poly in t.polys:
        if poly.len < 3: continue
        p.moveTo(X(poly[0][0].float), Y(poly[0][1].float))
        for q in 1 ..< poly.len: p.lineTo(X(poly[q][0].float), Y(poly[q][1].float))
        p.closePath()
      p.paintOf(t.color, o.cmyk, false)
      if t.embolden > 0:
        p.paintOf(t.color, o.cmyk, true)
        p.lineWidth(t.embolden.float * k)
        p.lineJoin(joinRound)
        p.fillStroke()
      else: p.fill()
  else:
    for (s, _, _) in (if L.shape.isPlain: @[(L.shape, 100, bmNormal)] else: exportParts(L.shape)):
      template path() =
        for sp in s.path.subs:
          if sp.pts.len == 0: continue
          p.moveTo(X(sp.pts[0].p[0]), Y(sp.pts[0].p[1]))
          let n = sp.pts.len
          let segs = if sp.closed: n else: n - 1
          for i in 0 ..< segs:
            let a = sp.pts[i]
            let b = sp.pts[(i + 1) mod n]
            if a.outH == a.p and b.inH == b.p: p.lineTo(X(b.p[0]), Y(b.p[1]))
            else: p.curveTo(X(a.outH[0]), Y(a.outH[1]), X(b.inH[0]), Y(b.inH[1]), X(b.p[0]), Y(b.p[1]))
          if sp.closed: p.closePath()
      if s.fill.kind == spColor:
        let fo = if s.fill.opacity in 1 .. 99: s.fill.opacity / 100 else: 1.0
        if fo < 1:
          p.saveState()
          p.opacity(fo * L.opacity.float / 100)
        path()
        p.paintOf(s.fill.color, o.cmyk, false)
        p.fill()
        if fo < 1: p.restoreState()
      if s.stroke.kind == spColor and s.strokeWidth > 0:
        path()
        p.paintOf(s.stroke.color, o.cmyk, true)
        p.lineWidth(s.strokeWidth * k)
        p.lineCap(case s.cap
                  of lcRound: capRound
                  of lcSquare: capSquare
                  else: capButt)
        p.lineJoin(case s.join
                   of ljRound: joinRound
                   of ljBevel: joinBevel
                   else: joinMiter)
        if s.dashes.len > 0:
          var ds: seq[float]
          for v in s.dashes: ds.add v * s.strokeWidth * k
          p.dash(ds)
        p.stroke()
        if s.dashes.len > 0: p.dash()
  if L.opacity < 100: p.restoreState()

proc linkRects*(d: Doc; L: Layer): seq[tuple[x0, y0, x1, y1: float32; link: string]] =
  ## Where a type layer's hyperlinks and destinations are (`CharStyle.link`): a box round their
  ## letters on each line they are on, in the image's pixels.
  if not L.isText: return
  let t = d.effectiveText(L)
  if t.path.len > 0 or t.warp.style != wsNone or t.vertical: return
  let runs = t.linkRuns
  if runs.len == 0: return
  let lay = layoutText(t)
  for (a, b, link) in runs:
    for ln in lay.lines:
      if ln.last <= a or ln.first >= b: continue
      var x0 = 1e9'f32
      var x1 = -1e9'f32
      for g in lay.glyphs:
        if g.index >= max(a, ln.first) and g.index < min(b, ln.last):
          x0 = min(x0, g.x)
          x1 = max(x1, g.x + g.adv)
      if x1 > x0: result.add (x0, ln.baseline - ln.ascent, x1, ln.baseline + ln.descent, link)

proc docDests*(d: Doc; page: int; k: float; into: var Table[string, tuple[page: int; top: float]]) =
  ## (the text destinations of a document that is page `page` of a PDF: where each is, points
  ## from the page's top at `k` points a pixel)
  for L in d.layers:
    if not L.isText or not L.visible: continue
    for (_, y0, _, _, link) in d.linkRects(L):
      if link.len > 1 and link[0] == '=' and link[1 .. ^1] notin into:
        into[link[1 .. ^1]] = (page, max(0.0, y0.float * k - 12))

proc addLinks(p: PdfPage; d: Doc; page: int; ox, oy, k: float; o: PdfOptions) =
  ## (the hyperlinks of the document's text: a click opens a web or mail address, goes to a
  ## destination or a page of the book)
  if o.noLinks: return
  for L in d.layers:
    if not L.isText or not L.visible: continue
    for (x0, y0, x1, y1, link) in d.linkRects(L):
      let (x, y, w, h) = (ox + x0.float * k, oy + y0.float * k, float(x1 - x0) * k, float(y1 - y0) * k)
      if link.startsWith("="): continue
      if link.startsWith("#"):
        let dn = link[1 .. ^1]
        if dn in o.dests: p.linkToPage(x, y, w, h, o.dests[dn].page, o.dests[dn].top)
        else:
          # (in this document)
          var here: Table[string, tuple[page: int; top: float]]
          d.docDests(page, k, here)
          if dn in here: p.linkToPage(x, y, w, h, here[dn].page, oy + here[dn].top)
      elif link.startsWith("page:"):
        let n = try: parseInt(link[5 .. ^1]) except ValueError: 0
        let to = if n >= 1 and n <= o.pageMap.len: o.pageMap[n - 1] elif o.pageMap.len == 0: n else: 0
        if to >= 1: p.linkToPage(x, y, w, h, to)
      else: p.link(x, y, w, h, link)

proc addBookmarks*(pdf: PdfDoc; d: Doc; page: int; k: float; o: PdfOptions) =
  ## (a document's bookmarks, `Doc.bookmarks`, as the PDF's: going to page `page` -- to their
  ## destination on it)
  if o.noBookmarks: return
  var here: Table[string, tuple[page: int; top: float]]
  for bm in d.bookmarks:
    if here.len == 0 and bm.dest.len > 0: d.docDests(page, k, here)
    let top = if bm.dest.len > 0 and bm.dest in here: here[bm.dest].top else: 0.0
    pdf.bookmarks.add PdfBookmark(title: bm.title, page: page, top: top, level: bm.level)

proc drawDocAt(p: PdfPage; d: Doc; ox, oy, k: float; o: PdfOptions; bleed: bool) =
  ## (the document's layers on the page from `ox`, `oy`; `bleed`: its pictures drawn out past
  ## its edges by the bleed)
  # the layers, bottom first: runs of pixel layers as one picture each,
  # type and shapes as outlines between them
  var visible, asVector: seq[bool]
  for n, L in d.layers:
    visible.add L.visible
    asVector.add o.vectors and d.vectorOk(n)
  var i = 0
  try:
    while i < d.layers.len:
      if asVector[i]:
        # (the layers shown as they are: type keeps out of those with Text Wrap that are)
        for n, L in d.layers: L.visible = visible[n]
        p.addVector(d, d.layers[i], ox, oy, k, o)
        inc i
        continue
      var j = i
      while j < d.layers.len and not asVector[j]: inc j
      # (just layers i ..< j shown: their picture)
      for n, L in d.layers:
        if not L.group: L.visible = visible[n] and n >= i and n < j
      d.markAll()
      d.updateComposite()
      let bleedPx = if bleed and o.marks and o.bleedMm > 0 and i == 0: int(ceil(o.bleedMm * 72 / 25.4 / k)) else: 0
      p.addRaster(d, d.compCopy, ox, oy, k, o, bleedPx)
      i = j
  finally:
    for n, L in d.layers: L.visible = visible[n]
    d.markAll()
    d.updateComposite()

proc addSpreadPage*(pdf: PdfDoc; docs: openArray[Doc]; o: PdfOptions): PdfPage {.discardable.} =
  ## `docs` side by side as one page at the end of `pdf`, the first at the
  ## left: a spread (facing pages as one sheet) -- its size theirs together
  ## (each document's pixels at its resolution), the crop marks round all of
  ## it when asked, each page's bleed only past the spread's outer edges.
  if docs.len == 0: return
  let d = docs[0]
  let dpi = if d.dpi > 0: d.dpi else: 72.0
  let k = 72 / dpi                        # (points a pixel)
  var pw = 0.0
  var ph = 0.0
  for x in docs:
    pw += x.w.float * k
    ph = max(ph, x.h.float * k)
  let room = if o.marks or o.regMarks or o.colorBars or o.pageInfo: MarkRoom else: 0.0
  result = pdf.addPage((pw + 2 * room, ph + 2 * room))
  let p = result
  let b = if o.marks: o.bleedMm * 72 / 25.4 else: 0.0
  if room > 0:
    p.trim = (room, room, pw, ph)
    p.bleed = (room - b, room - b, pw + 2 * b, ph + 2 * b)
  var x = room
  for j, dd in docs:
    let w = dd.w.float * k
    if docs.len > 1:
      # (each page shows only on its side of the spine; the bleed past the outer edges)
      p.saveState()
      let x0 = if j == 0: x - b else: x
      let x1 = if j == docs.high: x + w + b else: x + w
      p.rect(x0, room - b, x1 - x0, dd.h.float * k + 2 * b)
      p.clip()
    p.drawDocAt(dd, x, room, k, o, bleed = true)
    if docs.len > 1: p.restoreState()
    p.addLinks(dd, pdf.pages.len, x, room, k, o)
    pdf.addBookmarks(dd, pdf.pages.len, k, o)
    x += w
  if o.marks:
    # crop marks: short lines out from the corners, in registration black
    # (all four inks: on every plate)
    let b = o.bleedMm * 72 / 25.4
    let gap = max(b, 6.0)
    let len = room - gap - 2
    if o.cmyk: p.strokeCmyk(1, 1, 1, 1) else: p.strokeColor(color(0, 0, 0))
    p.lineWidth(0.3)
    for (cx, cy, sx, sy) in [(room, room, -1.0, -1.0), (room + pw, room, 1.0, -1.0),
                             (room, room + ph, -1.0, 1.0), (room + pw, room + ph, 1.0, 1.0)]:
      p.moveTo(cx + sx * gap, cy)
      p.lineTo(cx + sx * (gap + len), cy)
      p.moveTo(cx, cy + sy * gap)
      p.lineTo(cx, cy + sy * (gap + len))
      p.stroke()
  if o.regMarks and room > 0:
    # registration marks: a target in the middle of each side, out in the
    # margin -- the plates are lined up on them
    let r = 6.0
    let off = room / 2
    if o.cmyk: p.strokeCmyk(1, 1, 1, 1) else: p.strokeColor(color(0, 0, 0))
    p.lineWidth(0.25)
    for (cx, cy) in [(room + pw / 2, off), (room + pw / 2, room + ph + room - off),
                     (off, room + ph / 2), (room + pw + room - off, room + ph / 2)]:
      p.ellipse(cx - r, cy - r, 2 * r, 2 * r)
      p.stroke()
      p.ellipse(cx - r / 2, cy - r / 2, r, r)
      p.stroke()
      p.moveTo(cx - r * 1.6, cy)
      p.lineTo(cx + r * 1.6, cy)
      p.moveTo(cx, cy - r * 1.6)
      p.lineTo(cx, cy + r * 1.6)
      p.stroke()
  if o.colorBars and room > 0:
    # color bars: each ink alone and their mixes, over the top; a ramp of
    # black, 10 % to 100 %, under the bottom
    let sz = 10.0
    let y = (room - sz) / 2 - 4
    let solids = [(1.0, 0.0, 0.0, 0.0), (0.0, 1.0, 0.0, 0.0), (0.0, 0.0, 1.0, 0.0), (0.0, 0.0, 0.0, 1.0),
                  (1.0, 1.0, 0.0, 0.0), (0.0, 1.0, 1.0, 0.0), (1.0, 0.0, 1.0, 0.0), (1.0, 1.0, 1.0, 0.0)]
    var x = room + pw / 2 - solids.len.float * sz / 2
    for (c, m, yy, kk) in solids:
      if o.cmyk: p.fillCmyk(c, m, yy, kk)
      else: p.fillColor(color(uint8((1 - c) * (1 - kk) * 255), uint8((1 - m) * (1 - kk) * 255),
                              uint8((1 - yy) * (1 - kk) * 255)))
      p.rect(x, max(1.0, y), sz, sz)
      p.fill()
      x += sz
    x = room + pw / 2 - 5 * sz
    let yb = room + ph + (room - sz) / 2 + 4
    for t in 1 .. 10:
      let v = t / 10
      if o.cmyk: p.fillCmyk(0, 0, 0, v) else: p.fillColor(color(uint8((1 - v) * 255), uint8((1 - v) * 255),
                                                                 uint8((1 - v) * 255)))
      p.rect(x, yb, sz, sz)
      p.fill()
      x += sz
  if o.pageInfo and room > 0:
    # what the page is, under it at the left: the file, the inks
    let info = (if d.name.len > 0: d.name else: "Untitled") & "   " & $d.w & " x " & $d.h & " px, " &
               $int(round(d.dpi)) & " ppi   " & (if o.cmyk: "CMYK" else: "RGB") &
               (if o.standard.len > 0: "   " & o.standard & (if o.condition.len > 0: " (" & o.condition & ")" else: "")
                else: "")
    discard p.text(room, room + ph + room - 12, info, size = 6, color = color(0, 0, 0))


proc addDocPage*(pdf: PdfDoc; d: Doc; o: PdfOptions): PdfPage {.discardable.} =
  ## `d` as a page at the end of `pdf`: its size the document's (its pixels
  ## at its resolution), with crop marks round it when asked.
  pdf.addSpreadPage([d], o)

proc forPress(pdf: PdfDoc; o: PdfOptions) =
  ## (PDF/X: the standard claimed, the printing condition the colors are for)
  if o.standard.len > 0 and o.cmyk:
    pdf.pdfx = o.standard
    # (the press's profile -- Color Settings' -- or the ink model's own, made as one)
    let icc = if o.profile.len > 0: o.profile
              elif inkProfile().len > 0: inkProfile()
              else: inkModelProfile(inkSetup)
    pdf.outputIntent = (icc, (if o.condition.len > 0: o.condition
                              elif inkProfileName().len > 0: inkProfileName() else: "FOGRA39"),
                        (if o.condition.len > 0: o.condition else: "Coated FOGRA39 (ISO 12647-2:2004)"))

proc savePdf*(d: Doc; path: string; o: PdfOptions) =
  ## File > Save As > Photoshop PDF: the document as a one-page PDF.
  let pdf = newPdf(if o.title.len > 0: o.title else: d.name, author = o.author, creator = "Retro Photo")
  pdf.forPress(o)
  pdf.addDocPage(d, o)
  pdf.save(path)

proc newPressPdf*(o: PdfOptions; title = ""): PdfDoc =
  ## An empty PDF that pages are added to with `addDocPage` and that is
  ## then saved (`save`): as `o` asks (PDF/X, its printing condition).
  ## For documents made a PDF one after another, without all of them in
  ## memory (a book: `retroui/photobook`).
  result = newPdf(title, author = o.author, creator = "Retro Photo")
  result.forPress(o)

proc savePdfPresentation*(docs: openArray[Doc]; path: string; o: PdfOptions; title = "") =
  ## File > Automate > PDF Presentation: the documents as one PDF, a page
  ## each, in order (a magazine, a portfolio).
  let pdf = newPdf(title, author = o.author, creator = "Retro Photo")
  pdf.forPress(o)
  for d in docs: pdf.addDocPage(d, o)
  pdf.save(path)

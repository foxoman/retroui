## Retro Photo's documents and books made e-books and web pages (`retroui/publish`): each page's
## type as text -- its paragraphs, headings by their paragraph styles, its letters' look and
## links -- and each of its other layers as a picture of itself with its alt text
## (`LayerAttrs.alt`; a layer marked a decoration, or a plain background, left to the page).
##
## .. code-block:: nim
##   writeFile("book.epub", epubOf(pubDocOf(book)))
##   publishSite(pubDocOf(@[doc]), "site")
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/strutils
import std/unicode except strip
import gfx, imaging, jpeg, photo, photobook, textengine, publish

export publish

proc headingTag(L: Layer; styleName: string): string =
  if L.attrs.tag.len == 2 and L.attrs.tag[0] in {'H', 'h'}: return L.attrs.tag.toLowerAscii
  let st = styleName.toLowerAscii
  if st.startsWith("title"): return "h1"
  if st.startsWith("head"):
    for ch in st:
      if ch in {'1' .. '6'}: return "h" & ch
    return "h2"
  if st.len == 2 and st[0] == 'h' and st[1] in {'1' .. '6'}: return st
  if st.startsWith("list") or st.startsWith("bullet"): return "li"
  if st.startsWith("quote"): return "blockquote"
  "p"

proc textBlock(d: Doc; L: Layer): PubBlock =
  let t = d.effectiveText(L)
  let r = d.layerBox(L)
  result = PubBlock(kind: pbText, x: r.x.float, y: r.y.float, w: r.w.float, h: r.h.float)
  var para = PubPara()
  proc finish(p: var PubPara; fmt: ParaStyle) =
    p.tag = L.headingTag(fmt.styleName)
    p.align = case fmt.align
              of textCenter: "center"
              of textRight: "right"
              of justifyLeft, justifyCenter, justifyRight, justifyAll: "justify"
              else: ""
    if fmt.list != lkNone and p.tag == "p": p.tag = "li"
    if fmt.shading != 0: p.shading = fmt.shading
  for sp in t.spans:
    let parts = sp.text.split('\n')
    for k, part in parts:
      if k > 0:
        para.rtl = fmtOf(t, sp.style.para).rtl == 2
        para.finish(fmtOf(t, sp.style.para))
        result.paras.add para
        para = PubPara()
      if part.len > 0:
        var clean = ""
        for rn in part.runes:
          let c = int(rn)
          if c >= 0xE000 and c <= 0xF8FF: continue          # (marks the layout keeps: notes, anchors)
          clean.add rn.toUTF8
        if clean.len == 0: continue
        let s = sp.style
        let low = s.style.toLowerAscii
        para.runs.add PubRun(text: (if s.allCaps: clean.toUpper else: clean), family: s.family, size: s.size,
                             color: s.color, bold: "bold" in low or "black" in low or s.fauxBold,
                             italic: "italic" in low or "oblique" in low or s.fauxItalic,
                             underline: s.underline, strike: s.strike,
                             link: (if s.link.len > 0 and s.link[0] != '=': s.link else: ""))
  if para.runs.len > 0:
    let last = if t.spans.len > 0: t.spans[^1].style.para else: 0
    para.finish(fmtOf(t, last))
    result.paras.add para

proc plainFill(L: Layer): bool =
  ## (one color all over: a background)
  if L.px.len == 0: return true
  let first = L.px[0]
  for p in L.px:
    if p != first: return false
  true

proc pictureBlock(d: Doc; L: Layer): PubBlock =
  let r = d.layerBox(L)
  result = PubBlock(kind: pbPicture, x: r.x.float, y: r.y.float, w: r.w.float, h: r.h.float, alt: L.attrs.alt,
                    decorative: L.attrs.artifact or L.attrs.alt.len == 0 and L.isShape)
  if r.w <= 0 or r.h <= 0 or L.px.len != d.w * d.h: return
  let b = newBitmap(r.w, r.h)
  var opaque = true
  for y in 0 ..< r.h:
    for x in 0 ..< r.w:
      var p = L.px[(r.y + y) * d.w + r.x + x]
      if L.opacity < 100: p = (p and 0xFFFFFF'u32) or (uint32(int(p shr 24) * L.opacity div 100) shl 24)
      if (p shr 24) != 255: opaque = false
      b.px[y * r.w + x] = p
  result.picture = if opaque and not L.isShape and r.w * r.h > 40_000: encodeJpeg(b, 88) else: encodePng(b)

proc pubPageOf*(d: Doc; title = ""): PubPage =
  ## A document as a page to publish.
  result = PubPage(w: d.w.float, h: d.h.float, title: title)
  if d.layers.len > 0 and d.layers[0].background and d.layers[0].plainFill and d.layers[0].px.len > 0:
    result.background = d.layers[0].px[0]
  for L in d.layers:
    if not L.visible or L.group or L.attrs.nonprinting or L.adjust.kind.len > 0: continue
    if L.isText:
      if d.effectiveText(L).plainText.strip.len > 0: result.blocks.add d.textBlock(L)
    elif L.background and L.plainFill: continue
    else:
      let b = d.pictureBlock(L)
      if b.picture.len > 0: result.blocks.add b
  for L in d.layers:
    if not L.isText: continue
    for sp in L.text.spans:
      if sp.style.link.len > 1 and sp.style.link[0] == '=': result.anchors.add sp.style.link[1 .. ^1]

proc pubDocOf*(docs: openArray[Doc]; title = ""): PubDoc =
  ## Documents as the pages of an e-book or a web page, in order.
  result.title = if title.len > 0: title elif docs.len > 0: docs[0].name else: "Untitled"
  if docs.len > 0:
    result.author = docs[0].info.author
    result.description = docs[0].info.caption
  for d in docs: result.pages.add pubPageOf(d)
  for p in result.pages:
    for b in p.blocks:
      for q in b.paras:
        if q.rtl: result.rtl = true

proc pubDocOf*(b: Book): PubDoc =
  ## A book as an e-book or a web page: its pages in order, its cover the first page's
  ## picture.
  result.title = b.name
  b.reflow()
  for i in 0 ..< b.pages.len:
    let was = b.pageOpen(i)
    let d = b.doc(i)
    var pg: PubPage
    b.quietly(b.pages[i]): pg = pubPageOf(d)
    result.pages.add pg
    if i == 0:
      d.updateComposite()
      let c = newBitmap(d.w, d.h)
      c.px = d.compCopy
      result.cover = encodeJpeg(c, 85)
      result.author = d.info.author
    if not was: b.letGoPage(i)
  for p in result.pages:
    for blk in p.blocks:
      for q in blk.paras:
        if q.rtl: result.rtl = true

## Web pages and HTML in the window.
##
## - `htmlView`, `htmlBlock`: HTML as mail and help pages have it, laid out
##   by the kit itself (`htmllayout`): style sheets and `style` attributes
##   (`htmlcss`), the old attributes (`bgcolor`, `width`, `align`,
##   `cellpadding`, `<font>`...), blocks with margins, padding, borders and
##   backgrounds, tables with real column widths (nested as newsletters
##   nest them), floats, lists, quotes as mail apps show replies, pictures
##   made to fit, right-to-left paragraphs. What a mail hides (a
##   newsletter's "preheader") stays hidden. Scrolls with the wheel, a
##   finger, the scroll bar and the keys; links show the hand and are
##   reported when clicked; text is selected with the mouse and copied
##   with Ctrl+C (Ctrl+A: all of it). Given a `zoom`, it zooms as a
##   browser does -- Ctrl+wheel, Ctrl+plus, minus and 0, two fingers
##   pinching -- laid out again at the new size, the same lines in view.
##   No page can run code or reach the network: scripts are never run,
##   forms are left out, and pictures come from the page itself (`data:`),
##   from files next to it (`baseDir`, never outside it) or from the app
##   (`images`): what is not there is listed in `HtmlEvent.wantedImages`
##   for the app to fetch (then `htmlImagesChanged`).
## - `htmlToText`: the plain text of a mail; `htmlToMarkdown`, `htmlTitle`.
## - `webView`: a web page. With the system's engine (`engine = weSystem`,
##   $RETRO_WEB=system; the default in an Android app) it is the system's own
##   browser placed over the widget -- WebView2, WKWebView, WebKitGTK,
##   Android's WebView (`webnative`) -- whose scripts talk to the app
##   (`retro.post`, `webPost`, `webRun`). With the kit's own, local pages
##   (`file://`, paths, `html:` text) are shown with `htmlView`, and pages
##   on the web get a button that opens them in the browser.
##
## .. code-block:: nim
##   let ev = htmlView(readFile("help/index.html"), baseDir = "help")
##   if ev.link.len > 0: discard openUrl(ev.link)
##
##   # a mail: its pictures from the app (cid: parts, the web when allowed)
##   let m = htmlView(body, key = "mail", images = proc (src: string): Bitmap =
##     pictures.getOrDefault(src))
##   for src in m.wantedImages: fetchLater(src)   # ... then htmlImagesChanged()
##
##   # a mail the reader zooms (the app keeps the size in its settings)
##   discard htmlView(body, settings.mailZoom, key = "mail")
##
##   let w = webView("https://nim-lang.org", key = "docs", engine = weSystem)
##   for m in w.messages: echo "the page says ", m   # retro.post(text) in its scripts
##   if w.back: requestClose()      # Back with no page before (Android)

import std/[strutils, tables, os, hashes, times, base64, math]
import std/unicode except strip   # (its strip cuts letters: docs/nim-bugs.md)
import uirelays/target   # (androidApp: an APK, not a program in Termux)
import core, widgets, markdown, pixelicons, nerdicons, imaging, htmldom, htmllayout, htmlcss
import webp, gifanim
import uirelays/[services, input]
import webnative
export webnative.WebPermission, webnative.WebDownload

export htmldom.decodeEntities, htmldom.htmlEscape

template th: untyped = ui.theme

# ---- limits: what a hostile page can cost ---------------------------------------------------

const
  MaxOut = 6_000_000         ## bytes of Markdown made
  MaxNest = 10               ## lists and quotes in each other
  MaxCols = 50               ## table columns (in Markdown)
  MaxRows = 5000             ## table rows (in Markdown)
  MaxPicture = 2048          ## a picture is made no bigger than this
  MaxDataUri = 12_000_000    ## bytes of a `data:` picture read

const
  skipTags = ["head", "script", "style", "template", "iframe", "object", "embed",
              "svg", "math", "canvas", "video", "audio", "form", "select", "button",
              "textarea", "datalist", "dialog", "map", "frameset", "frame", "applet",
              "meta", "link", "base", "noembed", "noframes", "title", "xmp", "option",
              "optgroup", "label", "output", "progress", "meter", "picture", "source",
              "track", "param", "plaintext"]
  blockTags = ["html", "body", "div", "p", "section", "article", "header", "footer",
               "main", "nav", "aside", "figure", "figcaption", "address", "center",
               "details", "summary", "hgroup", "h1", "h2", "h3", "h4", "h5", "h6",
               "ul", "ol", "li", "dl", "dt", "dd", "blockquote", "pre", "table",
               "caption", "thead", "tbody", "tfoot", "tr", "td", "th", "hr", "menu",
               "dir", "fieldset", "legend", "noscript", "search", "listing"]

# ---- to Markdown ------------------------------------------------------------------------------

type
  Inl = object
    ## A paragraph being made.
    buf: string
    lastSpace: bool            ## the text so far ends in white space
    visible: bool              ## something shows
    pendingBreak: bool         ## a line break before what comes next
    inLink: bool
  Conv = object
    size: int                  ## Markdown made so far

proc esc(buf: var string; r: string) =
  ## Text, with what Markdown would read as markup escaped.
  for c in r:
    if c in {'!'..'/', ':'..'@', '['..'`', '{'..'~'}: buf.add '\\'
    buf.add c

proc safeUrl(u: string): string =
  ## `u` as a link may take it: "" for scripts; spaces, brackets and pipes
  ## made harmless.
  var t = ""
  for c in u:
    if c notin {'\0'..' ', '\x7F'} or c == ' ': t.add c
  t = t.strip
  var scheme = ""
  for c in t:
    if c in {' ', '\t'}: continue
    if c == ':': break
    scheme.add c.toLowerAscii
    if scheme.len > 12: break
  if scheme in ["javascript", "vbscript", "data"] and ':' in t: return ""
  for c in t:
    case c
    of '<': result.add "%3C"
    of '>': result.add "%3E"
    of '(': result.add "%28"
    of ')': result.add "%29"
    of '|': result.add "%7C"
    of '\\': result.add '/'
    else: result.add c

proc emitText(st: var Inl; t: string; c: var Conv) =
  ## Text into the paragraph, white space collapsed.
  for r in t.runes:
    let isSpace = int(r) in {9, 10, 12, 13, 32}
    if isSpace:
      if not st.lastSpace and st.visible and not st.pendingBreak:
        st.buf.add ' '
        st.lastSpace = true
      continue
    if st.pendingBreak and st.visible:
      while st.buf.endsWith(" "): st.buf.setLen(st.buf.len - 1)
      st.buf.add "<br>"
    st.pendingBreak = false
    st.buf.esc($r)
    st.lastSpace = false
    st.visible = true
  c.size += t.len

proc lineBreak(st: var Inl) =
  ## A break before the next text (none at the start, none twice).
  if st.visible: st.pendingBreak = true
  st.lastSpace = true

proc styleAttrColor(n: HNode): string =
  ## "#rrggbb" of the text color an element asks for, or "".
  var col = Color()
  if n.tag == "font": col = cssColor(n.attr("color"))
  let style = n.attr("style")
  if style.len > 0:
    for decl in style.split(';'):
      let k = decl.find(':')
      if k > 0 and decl[0 ..< k].strip.toLowerAscii == "color":
        col = cssColor(decl[k + 1 .. ^1].strip.split(' ')[0])
  if col.a == 0: return ""
  "#" & toHex(int(col.r), 2) & toHex(int(col.g), 2) & toHex(int(col.b), 2)

proc rawText(n: HNode; buf: var string) =
  ## The text of `n` as it is (preformatted): line breaks kept.
  if n.tag.len == 0:
    buf.add n.text
    return
  if n.tag in skipTags and n.tag notin ["xmp", "plaintext"]: return
  if n.tag == "br":
    buf.add '\n'
    return
  let blocky = n.tag in ["p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6"]
  if blocky and buf.len > 0 and not buf.endsWith("\n"): buf.add '\n'
  for k in n.kids: rawText(k, buf)
  if blocky and not buf.endsWith("\n"): buf.add '\n'

proc inline(c: var Conv; n: HNode; st: var Inl; depth: int)

proc wrapped(c: var Conv; n: HNode; st: var Inl; depth: int; open, close: string) =
  ## The children of `n` between `open` and `close` (left out when empty).
  let saved = (st.buf.len, st.visible, st.pendingBreak, st.lastSpace)
  st.buf.add open
  let inner = st.buf.len
  for k in n.kids: c.inline(k, st, depth + 1)
  if st.buf.len == inner:
    st.buf.setLen(saved[0])
    (st.visible, st.pendingBreak, st.lastSpace) = (saved[1], saved[2], saved[3])
  else:
    st.buf.add close

proc inline(c: var Conv; n: HNode; st: var Inl; depth: int) =
  if c.size > MaxOut: return
  if n.tag.len == 0:
    st.emitText(n.text, c)
    return
  if n.tag in skipTags: return
  if depth > MaxDepth:
    var t = ""
    rawText(n, t)
    st.emitText(t, c)
    return
  case n.tag
  of "br":
    while st.buf.endsWith(" "): st.buf.setLen(st.buf.len - 1)
    if st.visible:
      st.buf.add "<br>"
      st.pendingBreak = false
    st.lastSpace = true
  of "b", "strong": c.wrapped(n, st, depth, "<b>", "</b>")
  of "i", "em", "cite", "var", "dfn": c.wrapped(n, st, depth, "<i>", "</i>")
  of "u", "ins": c.wrapped(n, st, depth, "<u>", "</u>")
  of "s", "strike", "del": c.wrapped(n, st, depth, "<s>", "</s>")
  of "code", "kbd", "samp", "tt": c.wrapped(n, st, depth, "<code>", "</code>")
  of "mark": c.wrapped(n, st, depth, "<mark>", "</mark>")
  of "q": c.wrapped(n, st, depth, "<q>", "</q>")
  of "font", "span":
    let col = styleAttrColor(n)
    if col.len > 0: c.wrapped(n, st, depth, "<font color=\"" & col & "\">", "</font>")
    else:
      for k in n.kids: c.inline(k, st, depth + 1)
  of "a":
    let href = safeUrl(n.attr("href"))
    if href.len == 0 or st.inLink or href.startsWith("#") and href.len == 1:
      for k in n.kids: c.inline(k, st, depth + 1)
      return
    if st.pendingBreak and st.visible:
      st.buf.add "<br>"
      st.pendingBreak = false
    let start = st.buf.len
    let wasVisible = st.visible
    st.buf.add '['
    let inner = st.buf.len
    st.inLink = true
    for k in n.kids: c.inline(k, st, depth + 1)
    st.inLink = false
    if st.buf.len == inner:
      st.buf.esc(n.attr("href").strip)       # a link without words: its address
      st.visible = true
    while st.buf.endsWith(" "): st.buf.setLen(st.buf.len - 1)
    if st.buf.len == inner:
      st.buf.setLen(start)
      st.visible = wasVisible
      return
    st.buf.add "](<" & href & ">)"
    st.lastSpace = false
  of "img":
    let src = safeUrl(n.attr("src"))
    let alt = strutils.splitWhitespace(n.attr("alt")).join(" ")
    if src.len == 0:
      if alt.len > 0: st.emitText(alt, c)
      return
    if st.pendingBreak and st.visible:
      st.buf.add "<br>"
      st.pendingBreak = false
    if not st.lastSpace and st.visible: st.buf.add ' '
    st.buf.add "!["
    st.buf.esc(alt)
    st.buf.add "](<" & src & ">)"
    st.visible = true
    st.lastSpace = false
  of "input":
    # a task list's check box (forms are left out)
    if n.attr("type").toLowerAscii == "checkbox":
      var checked = false
      for (k, _) in n.attrs:
        if k == "checked": checked = true
      st.emitText(if checked: "\u2611 " else: "\u2610 ", c)
  of "li":
    st.lineBreak()
    st.emitText("\u2022 ", c)
    for k in n.kids: c.inline(k, st, depth + 1)
    st.lineBreak()
  of "td", "th":
    if st.visible and not st.pendingBreak: st.emitText(" \u00B7 ", c)
    for k in n.kids: c.inline(k, st, depth + 1)
  of "hr":
    st.lineBreak()
  of "pre", "listing":
    st.lineBreak()
    var t = ""
    rawText(n, t)
    let lines = t.strip(leading = false).split('\n')
    if st.pendingBreak and st.visible: st.buf.add "<br>"
    st.pendingBreak = false
    st.buf.add "<code>"
    for k, line in lines:
      if k > 0: st.buf.add "<br>"
      st.buf.esc(line.replace("\t", "    "))
    st.buf.add "</code>"
    st.visible = true
    st.lineBreak()
  else:
    if n.tag in blockTags:
      st.lineBreak()
      for k in n.kids: c.inline(k, st, depth + 1)
      st.lineBreak()
    else:
      for k in n.kids: c.inline(k, st, depth + 1)

proc blocks(c: var Conv; kids: seq[HNode]; depth, nest: int): seq[string]

proc addBlock(result: var seq[string]; lines: seq[string]) =
  if lines.len == 0: return
  if result.len > 0: result.add ""
  result.add lines

proc tableLines(c: var Conv; n: HNode; depth: int): seq[string] =
  var rows: seq[tuple[node: HNode; head: bool]]
  var caption = ""
  for k in n.kids:
    case k.tag
    of "tr": rows.add (k, false)
    of "thead", "tbody", "tfoot":
      for kk in k.kids:
        if kk.tag == "tr": rows.add (kk, k.tag == "thead")
    of "caption":
      var st = Inl(lastSpace: true)
      for kk in k.kids: c.inline(kk, st, depth + 1)
      caption = st.buf.strip
    else: discard
    if rows.len >= MaxRows: break
  if rows.len == 0:
    # a table without rows: its text
    var st = Inl(lastSpace: true)
    for k in n.kids: c.inline(k, st, depth + 1)
    if st.visible: result.add st.buf.strip
    return
  var cells: seq[seq[string]]
  var aligns: seq[char]
  var allTh: seq[bool]
  for (r, head) in rows:
    var row: seq[string]
    var thOnly = true
    var any = false
    for cell in r.kids:
      if cell.tag notin ["td", "th"]: continue
      any = true
      if cell.tag == "td": thOnly = false
      var st = Inl(lastSpace: true)
      for kk in cell.kids: c.inline(kk, st, depth + 1)
      let col = row.len
      if col >= MaxCols: break
      row.add st.buf.strip
      var a = cell.attr("align").toLowerAscii
      let style = cell.attr("style").toLowerAscii
      let ta = style.find("text-align")
      if ta >= 0:
        let rest = style[ta .. ^1]
        if "center" in rest.split(';')[0]: a = "center"
        elif "right" in rest.split(';')[0]: a = "right"
      while aligns.len <= col: aligns.add '\0'
      if aligns[col] == '\0' and a in ["center", "right", "left"]: aligns[col] = a[0]
      var span = 1
      try: span = clamp(parseInt(cell.attr("colspan").strip), 1, MaxCols)
      except ValueError: discard
      for _ in 1 ..< span:
        if row.len < MaxCols: row.add ""
    cells.add row
    allTh.add (head or (any and thOnly))
  var ncols = 1
  for r in cells: ncols = max(ncols, r.len)
  ncols = min(ncols, MaxCols)
  proc line(r: seq[string]): string =
    result = "|"
    for k in 0 ..< ncols:
      result.add ' '
      result.add(if k < r.len: r[k] else: "")
      result.add " |"
  if caption.len > 0:
    result.add "<b>" & caption & "</b>"
    result.add ""
  var first = 0
  if allTh[0]:
    result.add line(cells[0])
    first = 1
  else:
    result.add line(newSeq[string](ncols))        # no header row
  var d = "|"
  for k in 0 ..< ncols:
    let a = if k < aligns.len: aligns[k] else: '\0'
    d.add(case a
          of 'c': " :---: |"
          of 'r': " ---: |"
          else: " --- |")
  result.add d
  for k in first ..< cells.len: result.add line(cells[k])
  if cells.len == first:
    result.add line(newSeq[string](ncols))

proc blockOf(c: var Conv; n: HNode; depth, nest: int): seq[string] =
  result = @[]         # (a value at once: see tools/writecheck.py)
  if c.size > MaxOut or n.tag in skipTags: return
  if depth > MaxDepth:
    var st = Inl(lastSpace: true)
    c.inline(n, st, depth)
    if st.visible: result.add st.buf.strip
    return
  case n.tag
  of "h1", "h2", "h3", "h4", "h5", "h6":
    var st = Inl(lastSpace: true)
    for k in n.kids: c.inline(k, st, depth + 1)
    if st.visible:
      result.add repeat('#', ord(n.tag[1]) - ord('0')) & " " & st.buf.strip
  of "hr":
    result.add "---"
  of "pre", "listing":
    var t = ""
    rawText(n, t)
    if t.startsWith("\n"): t = t[1 .. ^1]
    if t.startsWith("\r\n"): t = t[2 .. ^1]
    while t.endsWith("\n") or t.endsWith("\r"): t.setLen(t.len - 1)
    var lang = ""
    for k in n.kids:
      if k.tag == "code":
        for cls in strutils.splitWhitespace(k.attr("class")):
          if cls.startsWith("language-"): lang = cls[9 .. ^1]
          elif cls.startsWith("lang-"): lang = cls[5 .. ^1]
    var run, longest = 0
    for ch in t:
      if ch == '`':
        inc run
        longest = max(longest, run)
      else: run = 0
    let fence = repeat('`', max(3, longest + 1))
    var l = ""
    for ch in lang:
      if ch.isAlphaNumeric or ch in {'-', '+', '#', '.'}: l.add ch
    result.add fence & l
    for line in t.replace("\r\n", "\n").split('\n'): result.add line.replace("\t", "    ")
    result.add fence
    c.size += t.len
  of "blockquote":
    if nest >= MaxNest:
      result = c.blocks(n.kids, depth + 1, nest); return
    for line in c.blocks(n.kids, depth + 1, nest + 1):
      result.add(if line.len == 0: ">" else: "> " & line)
  of "ul", "ol", "menu", "dir":
    let ordered = n.tag == "ol"
    var num = 1
    if ordered:
      try: num = clamp(parseInt(n.attr("start").strip), 0, 999_999_999)
      except ValueError: discard
    if nest >= MaxNest:
      # too deep: items as lines with bullets
      var st = Inl(lastSpace: true)
      c.inline(n, st, depth)
      if st.visible: result.add st.buf.strip
      return
    var items: seq[seq[string]]
    for k in n.kids:
      if k.tag == "li":
        items.add c.blocks(k.kids, depth + 1, nest + 1)
      elif k.tag.len == 0 and k.text.strip.len == 0:
        continue
      elif k.tag in skipTags:
        continue
      else:
        # something else in the list: with the item before, or one of its own
        let lines = if k.tag in blockTags: c.blockOf(k, depth + 1, nest + 1)
                    else:
                      var st = Inl(lastSpace: true)
                      c.inline(k, st, depth + 1)
                      (if st.visible: @[st.buf.strip] else: @[])
        if lines.len == 0: continue
        if items.len > 0: items[^1].addBlock(lines)
        else: items.add lines
    for k, item in items:
      let marker = if ordered: $(num + k) & ". " else: "- "
      let pad = spaces(marker.len)
      if item.len == 0:
        result.add marker.strip
        continue
      result.add marker & item[0]
      for line in item[1 .. ^1]:
        result.add(if line.len == 0: "" else: pad & line)
  of "dl":
    for k in n.kids:
      case k.tag
      of "dt":
        var st = Inl(lastSpace: true)
        for kk in k.kids: c.inline(kk, st, depth + 1)
        if st.visible: result.addBlock(@["<b>" & st.buf.strip & "</b>"])
      of "dd":
        var lines: seq[string]
        for line in c.blocks(k.kids, depth + 1, nest):
          lines.add(if line.len == 0: "" else: "\u00A0\u00A0\u00A0\u00A0\u00A0\u00A0" & line)
        result.addBlock(lines)
      else:
        if k.tag.len > 0: result.addBlock(c.blockOf(k, depth + 1, nest))
  of "table":
    result = c.tableLines(n, depth)
  of "li":
    let item = c.blocks(n.kids, depth + 1, nest + 1)
    if item.len > 0:
      result.add "- " & item[0]
      for line in item[1 .. ^1]: result.add(if line.len == 0: "" else: "  " & line)
  of "caption", "summary", "legend", "figcaption", "dt":
    var st = Inl(lastSpace: true)
    for k in n.kids: c.inline(k, st, depth + 1)
    if st.visible: result.add "<b>" & st.buf.strip & "</b>"
  else:
    result = c.blocks(n.kids, depth + 1, nest)

proc blocks(c: var Conv; kids: seq[HNode]; depth, nest: int): seq[string] =
  var st = Inl(lastSpace: true)
  template flush() =
    if st.visible:
      let t = st.buf.strip
      if t.len > 0: result.addBlock(@[t])
    st = Inl(lastSpace: true)
  for k in kids:
    if c.size > MaxOut: break
    if k.tag.len > 0 and k.tag in blockTags and k.tag notin ["td", "th", "tr"]:
      flush()
      result.addBlock(c.blockOf(k, depth, nest))
    else:
      c.inline(k, st, depth)
  flush()

var convCache: seq[tuple[h: Hash; n: int; md, title: string]]

proc convert(html: string): tuple[md, title: string] =
  let h = hash(html)
  for i, e in convCache:
    if e.h == h and e.n == html.len:
      if i > 0:
        let x = convCache[i]
        convCache.delete(i)
        convCache.insert(x, 0)
      return (convCache[0].md, convCache[0].title)
  let hd = parseHtml(html)
  let title = hd.title
  var c = Conv()
  let lines = c.blocks(hd.root.kids, 0, 0)
  result = (lines.join("\n"), title)
  convCache.insert((h, html.len, result.md, result.title), 0)
  if convCache.len > 4: convCache.setLen(4)

proc htmlToMarkdown*(html: string): string =
  ## `html` as Markdown the kit draws (inline styles kept as the few HTML
  ## tags `markdown` understands). Scripts, styles, frames and forms are
  ## left out.
  convert(html).md

proc htmlTitle*(html: string): string =
  ## The page's `<title>` ("" when it has none).
  convert(html).title


# ---- pictures ---------------------------------------------------------------------------------

type
  HtmlImageSource* = proc (src: string): Bitmap {.closure.}
    ## A picture for an <img src>, or an empty Bitmap (w = 0) when there is none (yet)

var
  imgVersion = 0
  picCache: Table[string, Bitmap]      ## (folder, src): the picture, or nil
  dataPics: Table[Hash, Bitmap]        ## `data:` pictures, decoded

proc htmlImagesChanged*() =
  ## A picture arrived (the app has one now for a src it was asked for):
  ## the views lay their pages out again, with it.
  inc imgVersion
  picCache.clear()
  ui.redraw = true

proc decodePicture(data: string): Bitmap =
  ## PNG, JPEG, GIF (its first frame), BMP or WebP bytes; nil when they are
  ## none of these, or damaged.
  result = nil         # (a value at once: see tools/writecheck.py)
  if data.len < 8: return
  try:
    if data.startsWith("\x89PNG"): result = decodePng(data)
    elif data[0] == '\xFF' and data[1] == '\xD8': result = decodeJpeg(data)
    elif data.startsWith("GIF8"):
      let f = gifFrames(data)
      if f.len > 0: result = f[0].bmp
    elif data.startsWith("BM"): result = decodeBmp(data)
    elif data.startsWith("RIFF") and data.len > 12 and data[8 .. 11] == "WEBP":
      result = decodeWebp(data)
  except CatchableError, Defect:
    result = nil
  if result != nil and (result.w <= 0 or result.h <= 0): result = nil
  if result != nil: result = thumbnail(result, MaxPicture, MaxPicture)

proc dataPicture(src: string): Bitmap =
  ## A `data:image/...;base64,...` picture, decoded once.
  let key = hash(src)
  if key in dataPics: return dataPics[key]
  if dataPics.len > 200: dataPics.clear()
  result = nil
  let comma = src.find(',')
  if comma > 5 and src.len <= MaxDataUri:
    let meta = src[5 ..< comma].toLowerAscii
    var body = src[comma + 1 .. ^1]
    var bytes = ""
    if ";base64" in meta:
      var clean = newStringOfCap(body.len)
      for ch in body:
        if ch in {'A'..'Z', 'a'..'z', '0'..'9', '+', '/', '-', '_'}: clean.add ch
      while clean.len mod 4 != 0: clean.add '='
      try: bytes = base64.decode(clean)
      except ValueError: bytes = ""
    else:
      var i = 0
      while i < body.len:
        if body[i] == '%' and i + 2 < body.len and body[i + 1] in HexDigits and body[i + 2] in HexDigits:
          bytes.add char(parseHexInt(body[i + 1 .. i + 2]))
          i += 3
        else:
          bytes.add body[i]
          inc i
    result = decodePicture(bytes)
  dataPics[key] = result

proc filePicture(src, baseDir: string): Bitmap =
  ## A picture in a file next to the page (never outside `baseDir`).
  if baseDir.len == 0: return nil
  var p = src
  for c in ['?', '#']:
    let k = p.find(c)
    if k >= 0: p = p[0 ..< k]
  var dec = ""
  var i = 0
  while i < p.len:
    if p[i] == '%' and i + 2 < p.len and p[i + 1] in HexDigits and p[i + 2] in HexDigits:
      dec.add char(parseHexInt(p[i + 1 .. i + 2]))
      i += 3
    else:
      dec.add p[i]
      inc i
  if dec.len == 0 or ':' in dec or dec[0] in {'/', '\\', '~'} or '\0' in dec: return nil
  let base = normalizedPath(absolutePath(baseDir))
  let full = normalizedPath(absolutePath(baseDir / dec))
  if not full.startsWith(base & DirSep): return nil
  loadPicture(full, MaxPicture, MaxPicture)

proc picSource(baseDir: string; images: HtmlImageSource): PicSource =
  ## Where a page's pictures come from: itself (`data:`), the app, the
  ## files next to it.
  result = proc (src: string): Bitmap =
    if src.len == 0: result = nil; return
    if src.len > 5 and src[0 .. 4].toLowerAscii == "data:": result = dataPicture(src); return
    let key = baseDir & "\0" & src
    picCache.withValue(key, v):
      result = v[]; return
    var b: Bitmap = nil
    if images != nil:
      try:
        b = images(src)
      except CatchableError:
        b = nil
      if b != nil and (b.w <= 0 or b.h <= 0 or b.px.len < b.w * b.h): b = nil
    if b == nil: b = filePicture(src, baseDir)
    if picCache.len > 2000: picCache.clear()
    picCache[key] = b
    b

# ---- pages read and laid out, kept ----------------------------------------------------------------

type
  PageKey = tuple[h: Hash; n, w: int; dir: string; img: int; em: float; k: float;
                  font: int; scale: int; zoom: float]

var
  docCache: seq[tuple[h: Hash; n: int; doc: Doc]]
  pageCache: seq[tuple[key: PageKey; page: ref Page]]

proc docOf(html: string; h: Hash): Doc =
  for i, e in docCache:
    if e.h == h and e.n == html.len:
      if i > 0:
        let x = docCache[i]
        docCache.delete(i)
        docCache.insert(x, 0)
      return docCache[0].doc
  result = buildDoc(html)
  docCache.insert((h, html.len, result), 0)
  if docCache.len > 4: docCache.setLen(4)

proc layoutZoom(z: float): float =
  ## The zoom a page is laid out at: `z` in steps of 5% (a pinch lays it
  ## out again a step at a time, not every frame); 0 and NaN: 1.
  if not (z > 0): return 1.0
  round(clamp(z, MinPageZoom, MaxPageZoom) * 20) / 20

proc pageOfHash(html: string; h: Hash; width: int; baseDir: string; images: HtmlImageSource;
                zoom: float): ref Page =
  ## `html` (its hash `h`) laid out `width` wide at `zoom` (read, styled and
  ## laid out once; kept).
  let key: PageKey = (h, html.len, width, baseDir, imgVersion, textSize(), ui.k,
                      ord(uiFont()), pxScale, zoom)
  for i, e in pageCache:
    if e.key == key:
      if i > 0:
        let x = pageCache[i]
        pageCache.delete(i)
        pageCache.insert(x, 0)
      return pageCache[0].page
  let d = docOf(html, h)
  result = new Page
  var pk = hash(baseDir)
  if images != nil: pk = pk !& hash(cast[int](rawProc(images))) !& hash(cast[int](rawEnv(images)))
  result[] = layoutDoc(d, width, picSource(baseDir, images), imgVersion, !$pk, zoom)
  pageCache.insert((key, result), 0)
  if pageCache.len > 8: pageCache.setLen(8)

proc pageOf(html: string; width: int; baseDir: string; images: HtmlImageSource;
            zoom = 1.0): ref Page =
  ## `html` laid out `width` wide (read, styled and laid out once; kept).
  pageOfHash(html, hash(html), width, baseDir, images, zoom)

# ---- colors -----------------------------------------------------------------------------------------

var
  adapted: Table[uint32, Color]
  adaptedFor: Color

proc dark(): bool {.inline.} =
  (int(th.field.r) * 3 + int(th.field.g) * 6 + int(th.field.b)) div 10 < 110

proc toColor(c: uint32): Color {.inline.} =
  color(uint8((c shr 16) and 255), uint8((c shr 8) and 255), uint8(c and 255))

type Use = enum forText, forBg, forLine

proc darkened(c: uint32; use: Use): Color =
  ## A page's color for a dark theme: light backgrounds made dark and dark
  ## text made light (their hue kept), as mail apps do; lines between.
  let r = float((c shr 16) and 255) / 255
  let g = float((c shr 8) and 255) / 255
  let b = float(c and 255) / 255
  let mx = max(r, max(g, b))
  let mn = min(r, min(g, b))
  let l = (mx + mn) / 2
  if (use == forBg and l <= 0.45) or (use == forText and l >= 0.55): return toColor(c)
  var hh, ss = 0.0
  let d = mx - mn
  if d > 0.0001:
    ss = if l > 0.5: d / (2 - mx - mn) else: d / (mx + mn)
    hh = if mx == r: (g - b) / d + (if g < b: 6 else: 0)
         elif mx == g: (b - r) / d + 2
         else: (r - g) / d + 4
    hh /= 6
  var nl = 1 - l
  case use
  of forBg: nl = 0.08 + nl * 0.5
  of forText: nl = max(nl, 0.62)
  of forLine: nl = clamp(nl, 0.3, 0.7)
  let q = if nl < 0.5: nl * (1 + ss) else: nl + ss - nl * ss
  let p = 2 * nl - q
  proc hue(t0: float): float =
    var t = t0
    if t < 0: t += 1
    if t > 1: t -= 1
    if t < 1/6: p + (q - p) * 6 * t
    elif t < 1/2: q
    elif t < 2/3: p + (q - p) * (2/3 - t) * 6
    else: p
  color(uint8(clamp(hue(hh + 1/3) * 255, 0, 255)), uint8(clamp(hue(hh) * 255, 0, 255)),
        uint8(clamp(hue(hh - 1/3) * 255, 0, 255)))

const quoteColors = [(60, 110, 200), (40, 140, 80), (160, 80, 160), (200, 120, 30)]

proc colorOf(c: uint32; fallback: Color; use = forText): Color =
  ## A color of the page as drawn: the theme's for the roles, the page's
  ## own (made to suit a dark theme).
  if c == 0: return fallback
  if isRole(c):
    if c >= RoleQuote and c <= RoleQuote + 3:
      let q = quoteColors[int(c - RoleQuote)]
      return if dark(): mixColor(color(uint8(q[0]), uint8(q[1]), uint8(q[2])), th.fieldText, 0.3)
             else: color(uint8(q[0]), uint8(q[1]), uint8(q[2]))
    case c
    of RoleLink: return th.link
    of RoleMark: return (if dark(): color(110, 95, 10) else: color(255, 240, 120))
    of RoleRule: return mixColor(th.fieldText, th.field, 0.6)
    of RoleFaint: return mixColor(th.fieldText, th.field, 0.92)
    of RoleHeading: return (if dark(): th.fieldText else: th.select)
    of RoleCode: return (if dark(): color(230, 200, 140) else: color(140, 30, 30))
    of RoleCodeBg: return (if dark(): color(45, 45, 45) else: color(244, 244, 238))
    else: return fallback
  if not dark(): return toColor(c)
  if adaptedFor != th.field:
    adapted.clear()
    adaptedFor = th.field
  let key = (c and 0x00FFFFFF'u32) or (uint32(ord(use)) shl 24)
  adapted.withValue(key, v):
    return v[]
  result = darkened(c, use)
  if adapted.len > 4000: adapted.clear()
  adapted[key] = result

# ---- drawing --------------------------------------------------------------------------------------

type
  SelPos = tuple[item, off: int]
  ViewState = object
    page: int                  ## the page (its serial) the selection is of
    seen: int                  ## the frame it was last drawn in
    a, b: SelPos               ## the selection's ends (item -1: none)
    anchor: SelPos             ## where the mouse went down
    dragging, moved: bool
    word: bool                 ## a double click chose a word
    pressX, pressY: int
    zoom: float                ## the zoom the page is laid out at (0: none yet)
    w: int                     ## ... its width
    src: Hash                  ## ... and which page

var views: Table[Id, ViewState]

proc noSel(): SelPos = (-1, 0)

proc lessEq(a, b: SelPos): bool = a.item < b.item or (a.item == b.item and a.off <= b.off)

proc ordered(v: ViewState): (SelPos, SelPos) =
  if lessEq(v.a, v.b): (v.a, v.b) else: (v.b, v.a)

proc runeEnd(s: string; start, n: int): int =
  result = start
  var k = 0
  while result < s.len and k < n:
    result += max(1, runeLenAt(s, result))
    inc k

proc offsetAt(d: DItem; px: int): int =
  ## The byte of text item `d` nearest `px` pixels from its left.
  let s = d.text
  var rel = px - int(d.x)
  if d.ts.rtl: rel = int(d.w) - rel
  if rel <= 0: return 0
  if rel >= int(d.w): return s.len
  var lo = 0
  var hi = s.runeLen
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    let w = textWidth(s[0 ..< runeEnd(s, 0, mid)], d.ts)
    if w <= rel: lo = mid else: hi = mid - 1
  # (the nearer edge of the letter)
  let a = runeEnd(s, 0, lo)
  if a < s.len:
    let wa = textWidth(s[0 ..< a], d.ts)
    let b = runeEnd(s, a, 1)
    let wb = textWidth(s[0 ..< b], d.ts)
    if rel - wa > wb - rel: return b
  a

proc hitText(p: ref Page; px, py: int): SelPos =
  ## The text position nearest a point of the page.
  var best = -1
  var bestScore = high(int)
  for i, d in p.items:
    if d.kind != dkText: continue
    let dy = if py < d.y: int(d.y) - py
             elif py >= d.y + d.h: py - int(d.y + d.h) + 1
             else: 0
    let dx = if px < d.x: int(d.x) - px
             elif px >= d.x + d.w: px - int(d.x + d.w) + 1
             else: 0
    let score = dy * 100_000 + dx
    if score < bestScore or (score == bestScore and dy == 0):
      if score < bestScore:
        bestScore = score
        best = i
  if best < 0: return noSel()
  (best, offsetAt(p.items[best], px))

proc sepText(s: int8): string =
  case s
  of 1: " "
  of 2: "\t"
  of 3: "\n"
  of 4: "\n\n"
  else: ""

proc pieceText(d: DItem): string =
  if d.kind == dkMarker:
    if d.text.len > 0: d.text else: "-"
  else: d.text

proc textBetween(p: ref Page; a, b: SelPos): string =
  ## The text from `a` to `b`, as it reads (line breaks, tabs between cells).
  if a.item < 0 or b.item < 0: return ""
  var first = true
  for i in a.item .. min(b.item, p.items.high):
    let d = p.items[i]
    if d.kind notin {dkText, dkMarker}: continue
    let t = pieceText(d)
    let s0 = if i == a.item and d.kind == dkText: clamp(a.off, 0, t.len) else: 0
    let s1 = if i == b.item and d.kind == dkText: clamp(b.off, 0, t.len) else: t.len
    if not first: result.add sepText(d.sep)
    first = false
    if s1 > s0: result.add t[s0 ..< s1]

proc allText(p: ref Page): string =
  var last = -1
  for i in countdown(p.items.high, 0):
    if p.items[i].kind == dkText:
      last = i
      break
  if last < 0: return ""
  textBetween(p, (0, 0), (last, p.items[last].text.len))

proc textMark(p: ref Page; pos: SelPos): int =
  ## Where `pos` is in the page's text, counted in letters that are not
  ## spaces: the same place at any width and zoom.
  if pos.item < 0: return -1
  for i in 0 ..< min(pos.item, p.items.len):
    if p.items[i].kind == dkText:
      for c in p.items[i].text:
        if c != ' ': inc result
  if pos.item < p.items.len and p.items[pos.item].kind == dkText:
    let t = p.items[pos.item].text
    for k in 0 ..< clamp(pos.off, 0, t.len):
      if t[k] != ' ': inc result

proc posOfMark(p: ref Page; mark: int; after = true): SelPos =
  ## The text position `textMark` counted to; between two pieces of text,
  ## the start of the second (`after`) or the end of the first.
  if mark < 0: return noSel()
  var left = mark
  var last = -1
  for i, d in p.items:
    if d.kind != dkText: continue
    last = i
    var n = 0
    for c in d.text:
      if c != ' ': inc n
    if left < n or left == n and n > 0 and not after:
      var k = 0
      var seen = 0
      while k < d.text.len and seen < left:
        if d.text[k] != ' ': inc seen
        inc k
      return (i, k)
    left -= n
  if last < 0: noSel() else: (last, p.items[last].text.len)

const zoomSteps = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

proc htmlZoomStep*(z: float; up: bool): float =
  ## The zoom after `z` one step up or down, as the view's keys and wheel
  ## step (50% .. 300%, as browsers do) -- for an app's View > Zoom In.
  ## Up from 1, steps at which the UI's text would be no taller (its line
  ## height rounds to the same pixels) are passed over.
  if up:
    let now = lineHeight(style(size = z))
    for s in zoomSteps:
      if s > z + 0.01 and (z < 0.99 or lineHeight(style(size = s)) > now or s == zoomSteps[^1]):
        return s
    zoomSteps[^1]
  else:
    for i in countdown(zoomSteps.high, 0):
      if zoomSteps[i] < z - 0.01: return zoomSteps[i]
    zoomSteps[0]

proc drawBox(d: DItem; r: Rect) =
  ## A block's background and borders.
  let bgc = if d.color != 0: colorOf(d.color, th.field, forBg) else: Color()
  let uniform = d.bw[0] == d.bw[1] and d.bw[1] == d.bw[2] and d.bw[2] == d.bw[3] and
                d.bc[0] == d.bc[1] and d.bc[1] == d.bc[2] and d.bc[2] == d.bc[3]
  if d.radius > 0 and d.color != 0:
    let rad = float(min(int(d.radius), min(r.w, r.h) div 2))
    if uniform and d.bw[0] > 0:
      roundRect(r, rad, colorOf(d.bc[0], th.fieldText, forLine))
      let t = int(d.bw[0])
      roundRect(rect(r.x + t, r.y + t, r.w - 2 * t, r.h - 2 * t), max(0.0, rad - float(t)), bgc)
    else:
      roundRect(r, rad, bgc)
    if uniform: return
  elif d.color != 0:
    fill(r, bgc)
  for side in 0 .. 3:
    let t = int(d.bw[side])
    if t <= 0: continue
    var c = colorOf(d.bc[side], th.fieldText, forLine)
    # (inset, outset: the 3D look of old tables)
    if d.bs[side] in {3'u8, 4'u8}:
      let lit = (d.bs[side] == 4) == (side in {0, 3})
      c = if lit: mixColor(c, th.field, 0.55) else: mixColor(c, th.fieldText, 0.2)
    let er = case side
      of 0: rect(r.x, r.y, r.w, t)
      of 1: rect(r.x + r.w - t, r.y, t, r.h)
      of 2: rect(r.x, r.y + r.h - t, r.w, t)
      else: rect(r.x, r.y, t, r.h)
    if d.bs[side] == 2 and (er.w > 3 * t or er.h > 3 * t):
      # dashed, dotted
      let step = max(2, 3 * t)
      if er.w >= er.h:
        var x = er.x
        while x < er.x + er.w:
          fill(rect(x, er.y, min(2 * t, er.x + er.w - x), er.h), c)
          x += step
      else:
        var y = er.y
        while y < er.y + er.h:
          fill(rect(er.x, y, er.w, min(2 * t, er.y + er.h - y)), c)
          y += step
    else:
      fill(er, c)

proc drawMissing(d: DItem; r: Rect) =
  ## A picture that is not there: a light box, its alt text in it.
  fill(r, colorOf(RoleFaint, th.field))
  box(r, mixColor(th.fieldText, th.field, 0.75))
  if d.text.len > 0 and r.w > 12 and r.h > 8:
    pushClip(intersect(clipRect(), inset(r, 2)))
    let lh = lineHeight(d.ts)
    text(r.x + 4, r.y + max(2, (min(r.h, lh + 6) - lh) div 2), d.text, mixColor(th.fieldText, th.field, 0.4), d.ts)
    popClip()

proc drawMarker(d: DItem; r: Rect; fg: Color) =
  if d.text.len > 0:
    text(r.x, r.y, d.text, fg, d.ts)
    return
  let s = float(r.w)
  case d.mk
  of lsCircle: ring(float(r.x) + s / 2, float(r.y) + s / 2, s / 2, max(1.0, s / 5), fg)
  of lsSquare: fill(r, fg)
  else: disc(float(r.x) + s / 2, float(r.y) + s / 2, s / 2, fg)

proc drawPage(p: ref Page; ox, oy: int; clip: Rect; v: ptr ViewState; canClick: bool;
              hoverLink: var int; overText: var bool) =
  ## The page with its top left at `ox`, `oy`; only what is in `clip`.
  let mp = point(ui.mx, ui.my)
  let fg = th.fieldText
  var sa, sb: SelPos = noSel()
  if v != nil and v.a.item >= 0 and v.b.item >= 0 and v.a != v.b:
    (sa, sb) = v[].ordered
  let top = clip.y - oy
  let bottom = clip.y + clip.h - oy
  for i in 0 ..< p.items.len:
    let d = addr p.items[i]
    if d.y > bottom or d.y + d.h < top: continue
    let r = rect(int(d.x) + ox, int(d.y) + oy, int(d.w), int(d.h))
    if canClick and d.link >= 0 and r.contains(mp): hoverLink = int(d.link)
    case d.kind
    of dkBox: drawBox(d[], r)
    of dkText:
      if canClick and r.contains(mp): overText = true
      let c = colorOf(d.color, fg)
      if sa.item >= 0 and i >= sa.item and i <= sb.item:
        let a = if i == sa.item: sa.off else: 0
        let b = if i == sb.item: sb.off else: d.text.len
        if b > a:
          let wa = textWidth(d.text[0 ..< a], d.ts)
          let wb = if b >= d.text.len: int(d.w) else: textWidth(d.text[0 ..< b], d.ts)
          let sr = if d.ts.rtl: rect(r.x + r.w - wb, r.y, wb - wa, r.h)
                   else: rect(r.x + wa, r.y, wb - wa, r.h)
          fill(sr, th.select)
          text(r.x, r.y, d.text, c, d.ts)
          pushClip(intersect(clipRect(), sr))
          text(r.x, r.y, d.text, th.selectText, d.ts)
          popClip()
          continue
      text(r.x, r.y, d.text, c, d.ts)
    of dkImage:
      if d.pic != nil: drawBitmap(r, d.pic)
    of dkMissing: drawMissing(d[], r)
    of dkMarker: drawMarker(d[], r, colorOf(d.color, fg))
    of dkAnchor, dkLinkArea: discard

# ---- the widgets ------------------------------------------------------------------------------------

type HtmlEvent* = object
  ## What happened in an `htmlView` this frame.
  link*: string        ## a link clicked (its address as the page has it), or ""
  hover*: string       ## the link under the pointer, or ""
  wantedImages*: seq[string]
    ## pictures the page has that it got no picture for (not `data:`): for
    ## the app to fetch, then call `htmlImagesChanged`

proc htmlView*(html: string; baseDir = ""; height = -1; key = ""; images: HtmlImageSource = nil;
               padding = -1; zoom: ptr float = nil): HtmlEvent {.discardable.} =
  ## HTML in a framed view that scrolls (wheel, finger, scroll bar, arrows,
  ## Page keys, Space, Home, End). Returns the link clicked (links to
  ## "#a-name" scroll there themselves) and the one under the pointer.
  ## Text is selected with the mouse (a double click: a word), Ctrl+C
  ## copies it (or all of it), Ctrl+A selects all. Pictures: `data:` ones
  ## from the page, others from `images` or files in `baseDir`; those it
  ## has none for are in `wantedImages`. `padding` (pixels, -1: a
  ## comfortable default) is room around the page. `key` tells several
  ## views apart (each keeps where it is scrolled to).
  ##
  ## `zoom`: the page's size, text and all (1.0 normal, 0.5 .. 3.0; 0: 1).
  ## When given, Ctrl+wheel and two fingers pinching over the view, and
  ## Ctrl+plus, minus and 0 (the view focused or under the pointer) change
  ## it; the app keeps it (in its settings), and may change it itself
  ## (View > Zoom). The page is laid out again at the new size, with the
  ## lines under the pointer (or at the top) kept where they were. A page
  ## wider than the view (zoomed in far) scrolls sideways too: Shift+wheel,
  ## a finger, the bar at the bottom, Left and Right.
  let r = place(0, if height < 0: remainingH() else: height, fill = true)
  let id = idOf("htmlview" & key)
  var st = state(id)
  var hit = interact(id, r)
  let pad = if padding < 0: dp(12) else: dp(padding)
  var inner = rect(r.x + 1, r.y + 1, r.w - SbW - 1, r.h - 2)
  let pw = max(40, inner.w - 2 * pad)
  # the zoom: Ctrl+wheel, a pinch, Ctrl+plus/minus/0
  var anchor = point(inner.x, inner.y)          # (what stays where it is when it changes)
  if zoom != nil:
    var z = if zoom[] > 0: clamp(zoom[], MinPageZoom, MaxPageZoom) else: 1.0
    if canInput():
      if ui.wheel != 0 and not ui.wheelUsed and CtrlPressed in ui.mods and mouseIn(r):
        ui.wheelUsed = true
        for _ in 1 .. min(abs(ui.wheel), 4): z = htmlZoomStep(z, ui.wheel > 0)
        anchor = point(ui.mx, ui.my)
      if ui.pinch != 1 and ui.pinch > 0 and r.contains(point(ui.pinchX, ui.pinchY)):
        z = clamp(z * ui.pinch, MinPageZoom, MaxPageZoom)
        anchor = point(ui.pinchX, ui.pinchY)
        ui.pinch = 1                            # (taken: one view zooms)
      if CtrlPressed in ui.mods and not ui.keyUsed and (hit.focused or mouseIn(r)):
        case ui.key
        of KeyPlus, KeyEqual: z = htmlZoomStep(z, true); ui.keyUsed = true
        of KeyMinus: z = htmlZoomStep(z, false); ui.keyUsed = true
        of Key0: z = 1.0; ui.keyUsed = true
        else: discard
    if z != zoom[]:
      zoom[] = z
      ui.redraw = true                          # (what shows the zoom shows the new one)
  let zl = if zoom != nil: layoutZoom(zoom[]) else: 1.0
  let h = hash(html)
  let src = h !& html.len
  let page = pageOfHash(html, h, pw, baseDir, images, zl)
  var v = views.getOrDefault(id)
  if v.page != page.serial:
    if v.zoom > 0 and v.zoom != zl and v.w == pw and v.src == src:
      # the same page at another zoom: the same text where it was, the
      # selection kept
      let old = pageOfHash(html, h, pw, baseDir, images, v.zoom)
      let ay = clamp(anchor.y, inner.y, inner.y + inner.h)
      let oldY = ay - (inner.y + pad) + st.scrollY
      let at = hitText(old, anchor.x - inner.x - pad + st.scrollX, oldY)
      let np = if at.item >= 0: posOfMark(page, textMark(old, at)) else: noSel()
      if np.item >= 0:
        let into = float(oldY - old.items[at.item].y) * zl / v.zoom
        st.scrollY = max(0, page.items[np.item].y + int(round(into)) - (ay - inner.y - pad))
      else:                                     # (no text: as far down, in proportion)
        st.scrollY = int(float(st.scrollY) * float(page.height) / float(max(1, old.height)))
      st.scrollX = int(float(st.scrollX) * zl / v.zoom)
      scrollStop(id)
      scrollStop(id + 3)
      if v.a.item >= 0 and v.b.item >= 0:
        # (a selection's start: where the text after it starts; its end:
        # where the text before it ends)
        let ma = textMark(old, v.a)
        let mb = textMark(old, v.b)
        let mn = textMark(old, v.anchor)
        v.a = posOfMark(page, ma, after = ma <= mb)
        v.b = posOfMark(page, mb, after = mb < ma or ma == mb)
        v.anchor = posOfMark(page, mn, after = mn <= min(ma, mb) or ma == mb)
      v.page = page.serial
      v.dragging = false
    else:
      v = ViewState(page: page.serial, a: noSel(), b: noSel(), anchor: noSel())
  v.zoom = zl
  v.w = pw
  v.src = src
  v.seen = ui.frameNo
  if views.len > 64:
    # (views not drawn for a while forget their selection)
    var old: seq[Id]
    for k, e in views:
      if ui.frameNo - e.seen > 600: old.add k
    for k in old: views.del k
  # (a page wider than the view -- zoomed in, mostly -- scrolls sideways too)
  let maxX = max(0, page.right - pw)
  if maxX > 0: inner.h -= SbW
  let maxY = max(0, page.height + 2 * pad - inner.h)
  var y = clamp(st.scrollY, 0, maxY)
  var x = clamp(st.scrollX, 0, maxX)
  scrollWheel(id, y, maxY, r, 3 * FontH)
  if maxX > 0:
    scrollWheel(id + 3, x, maxX, r, 3 * FontH, sideways = true)
    scrollPan2(id, y, maxY, id + 3, x, maxX, r)
  else:
    scrollPan(id, y, maxY, r)
  if hit.focused and canInput():
    let ctrl = CtrlPressed in ui.mods
    case ui.key
    of KeyLeft, KeyRight:
      if maxX > 0 and not ctrl:
        scrollBy(id + 3, x, (if ui.key == KeyLeft: -3 else: 3) * FontH, maxX)
        ui.keyUsed = true
    of KeyUp: scrollBy(id, y, -FontH, maxY); ui.keyUsed = true
    of KeyDown: scrollBy(id, y, FontH, maxY); ui.keyUsed = true
    of KeyPageUp: scrollBy(id, y, -(inner.h - FontH), maxY); ui.keyUsed = true
    of KeyPageDown, KeySpace:
      scrollBy(id, y, (if ShiftPressed in ui.mods and ui.key == KeySpace: -1 else: 1) *
                      (inner.h - FontH), maxY)
      ui.keyUsed = true
    of KeyHome: scrollTo(id, y, 0, maxY); ui.keyUsed = true
    of KeyEnd: scrollTo(id, y, maxY, maxY); ui.keyUsed = true
    of KeyC:
      if ctrl:
        let t = if v.a.item >= 0 and v.b.item >= 0 and v.a != v.b:
                  let (a, b) = v.ordered
                  textBetween(page, a, b)
                else: allText(page)
        putClipboardText(t)
        ui.keyUsed = true
    of KeyA:
      if ctrl:
        var first, last = -1
        for i, d in page.items:
          if d.kind in {dkText, dkMarker}:
            if first < 0: first = i
            last = i
        if first >= 0:
          v.a = (first, 0)
          v.b = (last, page.items[last].text.len)
        ui.keyUsed = true
    else: discard
  # the mouse: a click (a link), a drag (a selection) -- on the page as it
  # reads (a right-to-left interface does not mirror it)
  let ox = inner.x + pad - x
  let oyOf = proc (y: int): int = inner.y + pad - y
  beginKeepSides(inner)
  let overContent = canInput() and mouseIn(inner)
  if overContent and ui.pressed and not finger() and ui.active == id:
    v.dragging = true
    v.moved = false
    v.word = false
    v.pressX = ui.mx
    v.pressY = ui.my
    v.anchor = hitText(page, ui.mx - ox, ui.my - oyOf(y))
    if ShiftPressed in ui.mods and v.a.item >= 0:
      v.b = v.anchor
      v.anchor = v.a
      v.moved = true
    elif ui.clicks >= 2 and v.anchor.item >= 0:
      # a word
      let t = page.items[v.anchor.item].text
      var a = clamp(v.anchor.off, 0, t.len)
      var b = a
      while a > 0 and t[a - 1] != ' ': dec a
      while b < t.len and t[b] != ' ': inc b
      v.a = (v.anchor.item, a)
      v.b = (v.anchor.item, b)
      v.anchor = v.a
      v.moved = true
      v.word = true
      markDouble(id)
    else:
      v.a = noSel()
      v.b = noSel()
  if v.dragging and (ui.mouseDown or ui.released) and not finger():
    let far = abs(ui.mx - v.pressX) > 3 or abs(ui.my - v.pressY) > 3
    if far: v.moved = true
    if v.moved and v.anchor.item >= 0 and (far or not v.word):
      # past the top or bottom: it scrolls
      if ui.my < inner.y: scrollTo(id, y, y - max(4, (inner.y - ui.my) div 2), maxY)
      elif ui.my > inner.y + inner.h:
        scrollTo(id, y, y + max(4, (ui.my - inner.y - inner.h) div 2), maxY)
      if ui.my < inner.y or ui.my > inner.y + inner.h: wakeIn(30)
      let mx = clamp(ui.mx, inner.x, inner.x + inner.w)
      let my = clamp(ui.my, inner.y, inner.y + inner.h)
      v.a = v.anchor
      v.b = hitText(page, mx - ox, my - oyOf(y))
  endKeepSides()
  scrollTick(id, y, maxY)
  y = clamp(y, 0, maxY)
  if maxX > 0:
    scrollTick(id + 3, x, maxX)
    x = clamp(x, 0, maxX)
  scrollBarFor(id + 9, id, rect(r.x + r.w - SbW, r.y, SbW, r.h - (if maxX > 0: SbW else: 0)), true,
               y, maxY, max(FontH, inner.h - FontH), FontH)
  if maxX > 0:
    scrollBarFor(id + 10, id + 3, rect(r.x, r.y + r.h - SbW, r.w - SbW, SbW), false, x,
                 maxX, max(FontH, inner.w - FontH), FontH)
    fill(rect(r.x + r.w - SbW, r.y + r.h - SbW, SbW, SbW), th.face)
  fill(inner, colorOf(page.bg, th.field, forBg))
  fieldFrame(r)
  pushClip(inner)
  var hoverLink = -1
  var overText = false
  beginKeepSides(inner)
  drawPage(page, ox, oyOf(y), inner, addr v, overContent, hoverLink, overText)
  endKeepSides()
  popClip()
  if hit.focused: dots(inset(r, 1), th.text)
  if hoverLink >= 0 and hoverLink < page.links.len:
    result.hover = page.links[hoverLink]
    ui.cursor = curHand
  elif overText and canHover(): ui.cursor = curIbeam
  if hit.clicked and not v.moved and hoverLink >= 0 and hoverLink < page.links.len:
    result.link = page.links[hoverLink]
  if ui.released or not ui.mouseDown: v.dragging = false
  if result.link.startsWith("#"):
    let a = page.anchors.getOrDefault(result.link[1 .. ^1], -1)
    if a >= 0: scrollTo(id, y, a, maxY)          # (it glides there)
    result.link = ""
  result.wantedImages = page.wanted
  if y != st.scrollY or x != st.scrollX:
    st.scrollY = y
    st.scrollX = x
    ui.redraw = true
  state(id) = st
  views[id] = v
  if accessOn:
    accessNode(arTextArea, value = docOf(html, hash(html)).plainText(), id = id, r = r,
               states = {asReadOnly, asMultiLine})
  ui.lastId = id
  ui.lastRect = r

proc htmlView*(html: string; zoom: var float; baseDir = ""; height = -1; key = "";
               images: HtmlImageSource = nil; padding = -1): HtmlEvent {.discardable.} =
  ## `htmlView` that zooms, its zoom in `zoom` (the app's to keep):
  ## `htmlView(body, settings.mailZoom, key = "mail")`.
  htmlView(html, baseDir, height, key, images, padding, addr zoom)

proc htmlBlock*(html: string; baseDir = ""; w = 0; images: HtmlImageSource = nil;
                zoom = 1.0): HtmlEvent {.discardable.} =
  ## HTML flowing in the layout at its natural height (in a page that
  ## scrolls, a card, a dialog). Pictures as in `htmlView`; `zoom` as
  ## there (1.0 normal, 0.5 .. 3.0), set by the app.
  let width = if w > 0: w else: available()
  let page = pageOf(html, max(20, width), baseDir, images, layoutZoom(zoom))
  let r = place(width, page.height)
  let id = idOf("htmlblock" & $page.height & $width & $html.len)
  let hit = interact(id, r, focusable = false)
  let clip = intersect(r, clipRect())
  if page.bg != 0: fill(r, colorOf(page.bg, th.field, forBg))
  var hoverLink = -1
  var overText = false
  pushClip(clip)
  drawPage(page, r.x, r.y, clip, nil, canInput() and mouseIn(clip), hoverLink, overText)
  popClip()
  if hoverLink >= 0 and hoverLink < page.links.len:
    result.hover = page.links[hoverLink]
    ui.cursor = curHand
    if hit.clicked: result.link = page.links[hoverLink]
  result.wantedImages = page.wanted
  if accessOn:
    accessNode(arTextArea, value = docOf(html, hash(html)).plainText(), id = id, r = r,
               states = {asReadOnly, asMultiLine})
  ui.lastId = id
  ui.lastRect = r

proc htmlToText*(html: string): string =
  ## The plain text of a mail: paragraphs, "- " bullets, links as "text
  ## <url>", quotes with "> ", hidden text left out.
  docOf(html, hash(html)).plainText()

type HtmlPageInfo* = object
  ## A page as `htmlView` lays it out at a width (for tests, printing,
  ## tools): its size and what is where, in page coordinates.
  height*: int                                   ## its content's height
  right*: int                                    ## where its widest content ends
  text*: string                                  ## its text as Ctrl+A, Ctrl+C copies it
  words*: seq[tuple[text: string; r: Rect]]      ## the pieces of text drawn
  links*: seq[tuple[url: string; r: Rect]]       ## where each link can be clicked
  images*: seq[tuple[src: string; r: Rect; shown: bool]]  ## pictures (shown: it has the picture)
  wantedImages*: seq[string]                     ## as `HtmlEvent.wantedImages`

proc htmlPageInfo*(html: string; width: int; baseDir = ""; images: HtmlImageSource = nil;
                   zoom = 1.0): HtmlPageInfo =
  ## `html` laid out `width` pixels wide (its content, without the view's
  ## padding) at `zoom`, as `htmlView` and `htmlBlock` show it.
  let p = pageOf(html, max(20, width), baseDir, images, layoutZoom(zoom))
  result.height = p.height
  result.right = p.right
  result.text = allText(p)
  result.wantedImages = p.wanted
  for d in p.items:
    let r = rect(int(d.x), int(d.y), int(d.w), int(d.h))
    case d.kind
    of dkText: result.words.add (d.text, r)
    of dkImage: result.images.add (d.src, r, true)
    of dkMissing: result.images.add (d.src, r, false)
    else: discard
    if d.link >= 0 and d.kind in {dkText, dkImage, dkMissing, dkLinkArea} and d.link < p.links.len:
      result.links.add (p.links[d.link], r)

# ---- web pages ----------------------------------------------------------------------------------

type
  WebEngine* = enum
    ## Which engine shows a `webView`'s pages.
    weAuto     ## the system's in an Android app, the kit's own elsewhere
    weSystem   ## the system's where it has one (WebKitGTK, WebView2, WKWebView,
               ## Android's WebView), else the kit's own
    weKit      ## the kit's own everywhere: local pages drawn by it, pages on
               ## the web opened in the browser
  WebResult* = object
    ## The answer of a script run with `webRun`.
    id*: int             ## what `webRun` returned
    value*: string       ## its value as JSON ("" for undefined)
    error*: string       ## the error it raised ("" when none)
  WebEvent* = object
    ## What a `webView` shows and what happened in it this frame.
    url*: string         ## the page shown now (after links followed in it)
    title*: string       ## its title ("" while there is none)
    progress*: int       ## how much of it is loaded, 0..100
    loading*: bool       ## the page is still loading
    canGoBack*: bool     ## there is a page before (`webGoBack`)
    canGoForward*: bool  ## there is one after (`webGoForward`; the system's engine)
    link*: string        ## a link clicked in a page the kit shows itself
    opened*: bool        ## the page was handed to the browser
    back*: bool          ## (Android) Back pressed in the page with no page before
    native*: bool        ## the system's engine shows it
    messages*: seq[string]   ## what the page posted (`retro.post(text)` in its scripts)
    results*: seq[WebResult] ## the answers of `webRun`
    blocked*: seq[string]    ## addresses it was kept from (`webAllow`); the app may
                             ## `openUrl` them
    asked*: seq[WebPermission]   ## what the page asked to use and was not allowed
                                 ## (`webPermit`)
    downloads*: seq[WebDownload] ## files it downloads into the Downloads folder (each
                                 ## as it goes; a finished or failed one once)
  WebMode = enum wmKit, wmRelay, wmNative
  WebState = ref object
    asked: string        ## the address the app gave last
    cur: string          ## shown now
    history: seq[string]
    drawn: int           ## the frame it was last drawn in
    mode: WebMode        ## who shows it
    shown: bool          ## the system's view is on screen
    sent: string         ## ... with this address
    rect: Rect           ## ... at this place, in screen pixels
    zoomSent: float      ## ... at this zoom
    polledAt: int
    title: string
    progress: int
    canBack, canForward, backOut: bool
    zoom: float          ## `webZoom` (1: as it is)
    hosts: seq[string]   ## `webAllow`
    hostsSent: bool
    pending: seq[string] ## scripts asked before the page was shown
    messages: seq[string]
    results: seq[WebResult]
    blocked: seq[string]
    refused: seq[WebPermission]
    downloads: seq[WebDownload]
    permit: set[WebPermission]
    permitSent: bool     ## (sent to the page's engine)
    permitSet: bool      ## (`webPermit` was called)
    snapshot: Bitmap     ## the page as it was last seen (drawn while it is hidden)
    snapAt: int          ## when one was asked (ms)
    file: tuple[path, text: string; stamp: Time]

proc engineFromEnv(): WebEngine =
  case getEnv("RETRO_WEB").toLowerAscii
  of "system", "native": weSystem
  of "kit": weKit
  else: weAuto

var
  useSystemWebView* = androidApp
    ## Pages are the system's WebView through `systemCall` ("web.show"...), as
    ## on Android (tests turn it on with a fake `systemRelays.call`).
  webEngine* = engineFromEnv()
    ## The engine of every `webView` not given one ($RETRO_WEB: "system",
    ## "kit", "auto").
  webs: Table[string, WebState]
  hooked = false
  webRunIds = 0

proc relayTake(key: string): WebNativeState =
  ## (the Android protocol: "web.info" -- url, title, progress, can go back,
  ## Back with no page before, can go forward, then the notes)
  let info = systemCall("web.info", key)
  if info == "\0": return
  let p = info.split('\t', 6)
  if p.len >= 5:
    result.url = p[0]
    result.title = p[1]
    result.progress = (try: clamp(parseInt(p[2]), 0, 100) except ValueError: 100)
    result.canBack = p[3] == "1"
    result.backOut = p[4] == "1"
  if p.len >= 6: result.canForward = p[5] == "1"
  if p.len >= 7:
    for n in p[6].split('\2'):
      if n.len == 0: continue
      case n[0]
      of 'b': result.blocked.add n[1 .. ^1]
      of 'p':
        for p in WebPermission:
          if ($p)[2 .. ^1].toLowerAscii == n[1 .. ^1]: result.asked.add p
      of 'd':
        # (a download: url, file, progress, done/failed)
        let d = n[1 .. ^1].split('\3')
        if d.len >= 4:
          result.downloads.add WebDownload(url: d[0], file: d[1],
            progress: (try: parseInt(d[2]) except ValueError: 0), done: d[3] == "1",
            failed: d[3] == "-1")
      else: result.notes.add n[1 .. ^1]

proc localPath(u: string): string

proc engShow(w: WebState; key: string; r: Rect; asked: string) =
  let zoom = if w.zoom > 0: w.zoom else: 1.0
  # (a path, "file://" address, "./" or "~" path as the whole path the
  #  engines take)
  let path = if asked.toLowerAscii.startsWith("html:"): "" else: localPath(asked)
  let url = if path.len > 0: path.absolutePath.normalizedPath else: asked
  case w.mode
  of wmRelay:
    discard systemCall("web.show", key & "\t" & $r.x & "\t" & $r.y & "\t" & $r.w &
                       "\t" & $r.h & "\t" & url)
    if zoom != w.zoomSent and (w.zoomSent != 0 or zoom != 1.0):
      discard systemCall("web.zoom", key & "\t" & $int(zoom * 100))
  of wmNative:
    # (the page's pixels as the kit's: its size times the zoom asked)
    webNativeShow(key, r, url, zoom * ui.k * float(pxScale))
  of wmKit: discard
  w.zoomSent = zoom

proc engHide(w: WebState; key: string) =
  case w.mode
  of wmRelay: discard systemCall("web.hide", key)
  of wmNative: webNativeHide(key)
  of wmKit: discard

proc engNav(w: WebState; key: string; what: WebNav): bool =
  case w.mode
  of wmRelay:
    let r = systemCall("web." & ($what)[2 .. ^1].toLowerAscii, key)
    r == "1" or (what notin {wnBack, wnForward} and r != "\0")
  of wmNative:
    webNativeNav(key, what)
    true
  of wmKit: false

proc engRun(w: WebState; key, js: string) =
  case w.mode
  of wmRelay: discard systemCall("web.run", key & "\t" & js)
  of wmNative: webNativeRun(key, js)
  of wmKit: discard

proc engAllow(w: WebState; key: string) =
  case w.mode
  of wmRelay: discard systemCall("web.allow", key & "\t" & w.hosts.join("\t"))
  of wmNative: webNativeAllow(key, w.hosts)
  of wmKit: discard
  w.hostsSent = true

proc engSnap(w: WebState; key: string) =
  ## A picture of the page now (some engines give it later).
  case w.mode
  of wmRelay:
    let tmp = getTempDir() / "retro-web-" & $getCurrentProcessId() & ".png"
    if systemCall("web.snap", key & "\t" & tmp) == "1":
      let pic = try: decodePng(readFile(tmp)) except CatchableError: nil
      if pic != nil: w.snapshot = pic
      try: removeFile(tmp) except OSError: discard
  of wmNative: webNativeSnap(key)
  of wmKit: discard
  w.snapAt = ui.now

proc engPermit(w: WebState; key: string) =
  case w.mode
  of wmRelay:
    var l: seq[string]
    for p in w.permit: l.add ($p)[2 .. ^1].toLowerAscii
    discard systemCall("web.permit", key & "\t" & l.join(","))
  of wmNative: webNativePermit(key, w.permit)
  of wmKit: discard
  w.permitSent = true

proc engTake(w: WebState; key: string): WebNativeState =
  case w.mode
  of wmRelay: relayTake(key)
  of wmNative: webNativeTake(key)
  of wmKit: WebNativeState(progress: 100)

proc webFrameHook() {.nimcall.} =
  ## Views not drawn in the frame before go away (the system's view is
  ## not part of the kit's drawing: it would stay over the window).
  for k, w in webs:
    if w.shown and w.drawn < ui.frameNo - 1:
      w.engHide(k)
      w.shown = false

proc webStopAll() {.nimcall.} =
  ## The app ends: every system view let go, the engine stopped.
  for k, w in webs:
    if w.mode == wmRelay: discard systemCall("web.close", k)
  webs.clear()
  webNativeShutdown()

proc webOf(key: string): WebState =
  result = webs.getOrDefault(key, nil)
  if result == nil:
    result = WebState(progress: 100, zoom: 1.0)
    webs[key] = result
  if not hooked:
    hooked = true
    beginFrameHooks.add webFrameHook
    stopAppHooks.add webStopAll

proc isWeb(u: string): bool =
  let l = u.toLowerAscii
  l.startsWith("http://") or l.startsWith("https://")

proc localPath(u: string): string =
  ## The file a "file://" address or a path names ("" when it is neither).
  if u.toLowerAscii.startsWith("file://"):
    var p = u[7 .. ^1]
    if p.len >= 3 and p[0] == '/' and p[2] == ':': p = p[1 .. ^1]   # file:///C:/...
    var r = ""
    var i = 0
    while i < p.len:
      if p[i] == '%' and i + 2 < p.len and p[i + 1] in HexDigits and p[i + 2] in HexDigits:
        r.add char(parseHexInt(p[i + 1 .. i + 2]))
        i += 3
      else:
        r.add p[i]
        inc i
    return r
  if u.len > 0 and (u[0] == '/' or u.startsWith("./") or u.startsWith("~") or
     (u.len >= 3 and u[1] == ':' and u[2] in {'/', '\\'})):
    return u.expandTilde
  ""

proc pageText(w: WebState; path: string): string =
  ## A local page's text, read again when the file changed (4 MB at most).
  let stamp = try: getLastModificationTime(path) except OSError: Time()
  if w.file.path == path and w.file.stamp == stamp: return w.file.text
  var t = ""
  try:
    var f = open(path)
    defer: f.close()
    t = newString(min(MaxHtml, int(max(0'i64, getFileSize(f)))))
    if t.len > 0: t.setLen(f.readBuffer(addr t[0], t.len))
  except IOError, OSError:
    t = ""
  w.file = (path, t, stamp)
  t

proc webGoBack*(key = ""): bool {.discardable.} =
  ## The page before in the `webView` with `key`; false when there is none.
  let w = webs.getOrDefault(key, nil)
  if w == nil: return false
  if w.mode != wmKit:
    if not w.shown or not w.canBack and w.mode == wmNative: return false
    return w.engNav(key, wnBack)
  if w.history.len == 0: return false
  w.cur = w.history.pop()
  ui.redraw = true
  true

proc webGoForward*(key = ""): bool {.discardable.} =
  ## The page after (one Back left) in the `webView` with `key`, when the
  ## system's engine shows it; false when there is none.
  let w = webs.getOrDefault(key, nil)
  if w == nil or w.mode == wmKit or not w.shown or not w.canForward: return false
  w.engNav(key, wnForward)

proc webReload*(key = "") =
  ## Loads the page of the `webView` with `key` again.
  let w = webs.getOrDefault(key, nil)
  if w == nil: return
  if w.mode != wmKit: discard w.engNav(key, wnReload)
  else:
    w.file.path = ""
    ui.redraw = true

proc webStop*(key = "") =
  ## Stops loading the page of the `webView` with `key` (the system's engine).
  let w = webs.getOrDefault(key, nil)
  if w != nil and w.mode != wmKit: discard w.engNav(key, wnStop)

proc webClose*(key = "") =
  ## Lets the `webView` with `key` go (the system's view is freed; drawing
  ## it again starts afresh).
  let w = webs.getOrDefault(key, nil)
  if w == nil: return
  case w.mode
  of wmRelay: discard systemCall("web.close", key)
  of wmNative: webNativeClose(key)
  of wmKit: discard
  webs.del key

proc jsString(s: string): string =
  ## `s` as a JavaScript string literal.
  result = "\""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    of '<': result.add "\\x3c"            # (no </script> in it)
    of '\0' .. '\x08', '\x0b', '\x0c', '\x0e' .. '\x1f':
      result.add "\\x" & toHex(ord(c), 2).toLowerAscii
    else: result.add c
  result.add "\""

proc queue(w: WebState; js: string) =
  ## A script for when the page is shown (the last 64: a page never shown
  ## does not keep them all).
  if w.pending.len >= 64: w.pending.delete(0)
  w.pending.add js

proc webRun*(key: string; js: string): int {.discardable.} =
  ## Runs `js` in the page of the `webView` with `key` when the system's
  ## engine shows it, and returns a number: its answer comes in a later
  ## frame's `WebEvent.results` with that `id` -- its value as JSON, or the
  ## error it raised. With the kit's own engine nothing runs (no answer).
  ##
  ## .. code-block:: nim
  ##   let ask = webRun("docs", "document.querySelectorAll('h2').length")
  ##   for r in ev.results:
  ##     if r.id == ask: echo "headings: ", r.value
  inc webRunIds
  result = webRunIds
  let w = webOf(key)
  # (its answer posted back as a note: "\1id\1" and JSON)
  let wrapped = "(function(){var r;try{var v=(0,eval)(" & jsString(js) & ");" &
    "r=JSON.stringify({ok:v===undefined?null:v});}catch(e){r=JSON.stringify({error:String(e)});}" &
    "if(window.retro&&window.retro.post)window.retro.post('\\u0001" & $result & "\\u0001'+r);})();"
  if w.shown: w.engRun(key, wrapped) else: w.queue wrapped

proc webPost*(key: string; message: string) =
  ## Sends `message` to the page of the `webView` with `key` (the system's
  ## engine): its scripts get it as a `retro` event on `window`
  ## (`window.addEventListener("retro", e => use(e.detail))`).
  let w = webOf(key)
  let js = "window.dispatchEvent(new CustomEvent('retro',{detail:" & jsString(message) & "}));"
  if w.shown: w.engRun(key, js) else: w.queue js

proc webAllow*(key: string; hosts: openArray[string]) =
  ## The hosts the page of the `webView` with `key` may open, and those under
  ## them ("nim-lang.org" lets "forum.nim-lang.org" in); none: any. Others are
  ## kept from it and come in `WebEvent.blocked` (the app may `openUrl` them).
  ## Local pages always may. The system's engine; the kit's own opens only
  ## local pages anyway. Called every frame, it is sent again only when the
  ## hosts change.
  let w = webOf(key)
  # (the same hosts every frame are sent once)
  var same = w.hosts.len == hosts.len
  if same:
    for i in 0 ..< hosts.len:
      if w.hosts[i] != hosts[i]:
        same = false
        break
  if not same:
    w.hosts = @hosts
    w.hostsSent = false

proc webPermit*(key: string; allowed: set[WebPermission]) =
  ## What the page of the `webView` with `key` may use when it asks: the
  ## camera, the microphone, the location, notifications (none by
  ## default). What it asks for and is not allowed comes in
  ## `WebEvent.asked`; the app may allow it then and reload the page. The
  ## system's engine (the app needs the system's permission too: an
  ## Android app `--permission:CAMERA`...).
  let w = webOf(key)
  if w.permit != allowed or not w.permitSet:
    w.permit = allowed
    w.permitSent = false
    w.permitSet = true

proc webPrint*(key: string) =
  ## Prints the page of the `webView` with `key`: the system's print
  ## dialog (the system's engine; the kit's own prints nothing here --
  ## `retroui/report` prints documents).
  let w = webs.getOrDefault(key, nil)
  if w != nil and w.mode != wmKit and w.shown: discard w.engNav(key, wnPrint)

proc webAppFolder*(folder: string) =
  ## The folder of the app's own web pages (its scripts, styles, pictures),
  ## served to pages at `webAppUrl`: an address of their own, so they may
  ## fetch each other as a site's files do (a `file://` page may not).
  webNativeAppFolder(folder.absolutePath)
  when androidApp: discard systemCall("web.appFolder", folder.absolutePath)

proc webAppUrl*(path = "index.html"): string =
  ## The address of the file `path` of the app's folder (`webAppFolder`):
  ## "app://local/PATH" (on Windows "https://app.local/PATH").
  ##
  ## .. code-block:: nim
  ##   webAppFolder(getAppDir() / "web")
  ##   webView(webAppUrl("index.html"), key = "ui", engine = weSystem)
  webNativeAppUrl(path)

proc webZoom*(key: string; zoom: float) =
  ## The size of the page of the `webView` with `key`, text and pictures:
  ## 1.0 as it is (0.5 .. 3.0); the system's engine.
  let w = webOf(key)
  w.zoom = clamp(if zoom <= 0: 1.0 else: zoom, 0.5, 3.0)

proc follow(w: WebState; link: string; ev: var WebEvent) =
  ## A link clicked in a page the kit shows: another local page is shown
  ## here (Back returns), anything else goes to the system (the browser,
  ## mail...).
  var target = link
  let hashAt = target.find('#')
  if hashAt >= 0: target = target[0 ..< hashAt]
  let qAt = target.find('?')
  if qAt >= 0: target = target[0 ..< qAt]
  if target.len == 0: return
  let lower = target.toLowerAscii
  if ':' in lower and not lower.startsWith("file:") and
     not (target.len >= 3 and target[1] == ':' and target[2] in {'/', '\\'}):
    if openUrl(link): ev.opened = true
    return
  var path = localPath(target)
  if path.len == 0:
    let here = localPath(w.cur)
    let dir = if here.len > 0: here.parentDir else: getCurrentDir()
    path = dir / target
  path = path.normalizedPath
  if fileExists(path):
    w.history.add w.cur
    if w.history.len > 50: w.history.delete(0)
    w.cur = path
    ui.redraw = true

proc webPlaceholder(r: Rect; w: WebState) =
  ## What shows where the system's view goes, under it (and while it is
  ## hidden by a menu or a dialog): the page as it was last seen, else its
  ## title.
  if w.snapshot != nil and w.snapshot.w > 0:
    drawBitmap(r, w.snapshot)
    return
  fill(r, th.field)
  box(r, th.edge)
  let t = if w.progress < 100: "Loading... " & $w.progress & "%"
          elif w.title.len > 0: w.title
          else: w.cur
  let line = ellipsize(t, r.w - dp(16))
  text(r.x + (r.w - textWidth(line)) div 2, r.y + (r.h - FontH) div 2, line, th.gray)

proc webFallback(r: Rect; url: string; ev: var WebEvent) =
  ## A page on the web where the kit has no browser engine: the address and
  ## a button that opens it in the browser.
  fill(r, th.field)
  box(r, th.edge)
  let gh = dp(32)
  let lines = wrapLines(url, r.w - dp(24))
  let need = gh + dp(8) + FontH * (2 + min(3, lines.len) + 2) + dp(12) + CtrlH
  var y = r.y + max(dp(6), (r.h - need) div 2)
  if r.h > need:
    image(r.x + (r.w - gh) div 2, y, glyphIcon(retroOr(pxWeb, nfGlobe), th.text, gh))
    y += gh + dp(8)
  let head = "This page is on the web"
  drawLabel(r.x + (r.w - textWidth(head, true)) div 2, y, head, th.text, bold = true)
  y += FontH + dp(4)
  for k, line in lines:
    if k >= 3: break
    text(r.x + (r.w - textWidth(line)) div 2, y, line, th.link)
    y += FontH
  y += dp(4)
  for line in wrapLines("It opens in your browser. (Inside the app on Android.)",
                        r.w - dp(24)):
    text(r.x + (r.w - textWidth(line)) div 2, y, line, th.gray)
    y += FontH
  y += dp(8)
  let label = "&Open in your browser"
  let bw = max(dp(150), labelWidth(label) + dp(24))
  if y + CtrlH <= r.y + r.h:
    pushFrame(rect(r.x + (r.w - bw) div 2, y, bw, CtrlH))
    if button(label, w = bw):
      if openUrl(url): ev.opened = true
    discard popFrame()

proc webView*(url: string; height = -1; key = ""; engine = webEngine): WebEvent {.discardable.} =
  ## A web page in the window, `height` pixels high (-1: the room left).
  ## `url` is "https://...", a "file://" address or a path, or "html:" and
  ## the HTML itself; giving another address shows that page. `engine`
  ## chooses who shows it (`webEngine`, $RETRO_WEB: the kit's own on
  ## desktops, the system's in an Android app).
  ##
  ## The system's engine (`weSystem`; the default in an Android app) is the
  ## browser the system has -- Android's WebView, WebView2 on Windows,
  ## WKWebView on macOS and iOS, WebKitGTK on Linux and BSD when it is
  ## installed -- placed over the widget: scripts, forms, video; links are
  ## followed in it, Back and Forward (`webGoBack`, `webGoForward`) go through
  ## its history. Its scripts talk to the app: `retro.post(text)` comes in
  ## `messages`; `webPost` sends one to them (a `retro` event on `window`),
  ## `webRun` runs a script and its answer comes in `results`. `webAllow`
  ## keeps it to some hosts, `webZoom` sizes it. It is hidden while a menu or a
  ## dialog of the app is over it, and when the widget is not drawn; while it
  ## has the keyboard, keys go to it (a click on the app takes them back).
  ## Android apps need the INTERNET permission (`retroapk
  ## --permission:INTERNET`). Where there is no engine it is the kit's own.
  ## While you make the app, $RETRO_WEB_TOOLS=1 offers the engine's
  ## developer tools (Inspect Element; Safari's Web Inspector for WKWebView).
  ##
  ## The kit's own engine shows local pages itself (`htmlView`: no scripts,
  ## no network; links to other local pages are followed, others open in
  ## the browser), and pages on the web get a button that opens them in the
  ## browser.
  let r = place(0, if height < 0: remainingH() else: height, fill = true)
  let w = webOf(key)
  # who shows it
  let mode = if useSystemWebView and engine != weKit: wmRelay
             elif engine == weSystem and webNativeAvailable(): wmNative
             else: wmKit
  if mode != w.mode:
    if w.shown: w.engHide(key)
    w.shown = false
    w.mode = mode
    w.sent = ""
    w.hostsSent = false
    # (the page asked, afresh: not the address the other engine went on to)
    w.cur = w.asked
    w.history.setLen(0)
    w.title = ""
    w.progress = if mode != wmKit: 0 else: 100
    w.snapshot = nil
    w.permitSent = false
  if url != w.asked:
    w.asked = url
    w.cur = url
    w.history.setLen(0)
    w.title = ""
    w.snapshot = nil
    w.progress = if w.mode != wmKit: 0 else: 100
  w.drawn = ui.frameNo
  if w.mode != wmKit:
    webPlaceholder(r, w)
    # only the part of it on screen; hidden under the app's menus and dialogs
    let vis = intersect(r, clipRect())
    let covered = vis.w <= 0 or vis.h <= 0 or ui.inertDepth > 0 or
                  (ui.dialogTop != 0 and ui.curDialog != ui.dialogTop) or
                  (ui.popup != 0 and intersect(ui.popupRect, vis).w > 0)
    if covered:
      if w.shown:
        # (the page as it is now, drawn in its place while it is hidden)
        w.engSnap(key)
        let st = w.engTake(key)
        if st.snapshot != nil: w.snapshot = st.snapshot
        for n in st.notes: w.messages.add n
        w.engHide(key)
        w.shown = false
    else:
      let dr = rect(vis.x * pxScale, vis.y * pxScale, vis.w * pxScale, vis.h * pxScale)
      let zoom = if w.zoom > 0: w.zoom else: 1.0
      # (the address the app asked: a page the engine went on to is not loaded
      #  again when the view only moves)
      if not w.shown or dr != w.rect or w.sent != w.asked or zoom != w.zoomSent:
        w.engShow(key, dr, w.asked)
        w.shown = true
        w.rect = dr
        w.sent = w.asked
      if not w.hostsSent and (w.hosts.len > 0 or w.mode == wmNative): w.engAllow(key)
      if w.pending.len > 0:
        for js in w.pending: w.engRun(key, js)
        w.pending.setLen(0)
      if w.permitSet and not w.permitSent: w.engPermit(key)
      # (a picture of the page now and then, for when it is hidden: engines
      #  that give it later)
      if w.mode == wmNative and w.progress >= 100 and ui.now - w.snapAt > 2000: w.engSnap(key)
      # what the page does by itself (links followed, its title, loading,
      # what its scripts post)
      if ui.now - w.polledAt >= 100 or ui.now < w.polledAt:
        w.polledAt = ui.now
        let st = w.engTake(key)
        if st.url.len > 0: w.cur = st.url
        w.title = st.title
        w.progress = st.progress
        w.canBack = st.canBack
        w.canForward = st.canForward
        if st.backOut: w.backOut = true
        for n in st.notes:
          if n.len > 2 and n[0] == '\1':
            # (a script's answer: "\1id\1" and {"ok": value} or {"error": text})
            let k = n.find('\1', 1)
            if k > 1:
              var res = WebResult(id: (try: parseInt(n[1 ..< k]) except ValueError: 0))
              let body = n[k + 1 .. ^1]
              if body.startsWith("{\"error\":"):
                let a = body.find(':')
                res.error = body[a + 1 .. ^2].strip(chars = {'"'})
              elif body.startsWith("{\"ok\":"):
                res.value = body[6 .. ^2]
              w.results.add res
              continue
          w.messages.add n
        for b in st.blocked:
          let l = b.toLowerAscii
          if l.startsWith("http:") or l.startsWith("https:"): w.blocked.add b
          elif openUrl(b): discard          # (mail, phone, maps: their apps)
        for p in st.asked:
          if p notin w.refused: w.refused.add p
        for d in st.downloads: w.downloads.add d
        if st.snapshot != nil: w.snapshot = st.snapshot
      wakeIn(if w.progress < 100 or w.mode == wmNative: 100 else: 500)
    result.url = w.cur
    result.title = w.title
    result.progress = w.progress
    result.loading = w.progress < 100
    result.canGoBack = w.canBack
    result.canGoForward = w.canForward
    result.back = w.backOut
    result.native = true
    swap(result.messages, w.messages)
    swap(result.results, w.results)
    swap(result.blocked, w.blocked)
    swap(result.asked, w.refused)
    swap(result.downloads, w.downloads)
    w.backOut = false
    ui.lastRect = r
    return
  # the kit shows it itself (it runs no scripts)
  w.pending.setLen(0)
  result.progress = 100
  let cur = w.cur
  if cur.startsWith("html:"):
    pushFrame(rect(r.x, r.y, r.w, r.h))
    let ev = htmlView(cur[5 .. ^1], height = r.h, key = "web:" & key)
    discard popFrame()
    result.title = htmlTitle(cur[5 .. ^1])
    if ev.link.len > 0:
      result.link = ev.link
      w.follow(ev.link, result)
  elif isWeb(cur):
    webFallback(r, cur, result)
    result.title = cur
  else:
    let path = localPath(cur)
    if path.len == 0 or not fileExists(path):
      pushFrame(rect(r.x, r.y, r.w, r.h))
      discard htmlView("<h3>This page is not there</h3><p>" & htmlEscape(cur) & "</p>",
                       height = r.h, key = "web:" & key)
      discard popFrame()
    else:
      let text = w.pageText(path)
      let ext = path.splitFile.ext.toLowerAscii
      pushFrame(rect(r.x, r.y, r.w, r.h))
      var ev: HtmlEvent
      if ext in [".md", ".markdown"]:
        let m = markdownView(text, height = r.h, baseDir = path.parentDir,
                             key = "web:" & key & ":" & path)
        ev.link = m.link
        result.title = path.extractFilename
      elif ext in [".html", ".htm", ".xhtml", ".xht", ""]:
        ev = htmlView(text, baseDir = path.parentDir, height = r.h,
                      key = "web:" & key & ":" & path)
        result.title = htmlTitle(text)
        if result.title.len == 0: result.title = path.extractFilename
      else:
        ev = htmlView("<pre>" & htmlEscape(text) & "</pre>", height = r.h,
                      key = "web:" & key & ":" & path)
        result.title = path.extractFilename
      discard popFrame()
      if ev.link.len > 0:
        result.link = ev.link
        w.follow(ev.link, result)
  result.url = w.cur
  result.canGoBack = w.history.len > 0
  ui.lastRect = r

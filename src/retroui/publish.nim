## Pages made into an e-book or a web page: an EPUB 3 -- reflowable (its text and pictures in
## reading order, for any reader and any size of screen) or fixed layout (each page as it is
## laid out) -- and a web page, one file or a folder with its pictures, that follows the
## screen it is on. Its text stays text, its headings headings, its pictures say what they show
## (alt text), its links go where they go: readers and search engines read it.
##
## The pages are given as blocks (`PubPage`): text (paragraphs of runs in their styles) and
## pictures (PNG or JPEG bytes), each where it is on the page; Retro Atelier makes them of a
## book's pages or a design.
##
## .. code-block:: nim
##   var page = PubPage(w: 800, h: 1000, title: "Chapter 1")
##   page.blocks.add PubBlock(kind: pbText, x: 60, y: 60, w: 680, h: 80,
##                            paras: @[PubPara(tag: "h1", runs: @[PubRun(text: "Hello", size: 40)])])
##   let book = PubDoc(title: "My Book", author: "Me", lang: "en", pages: @[page])
##   writeFile("my.epub", epubOf(book))
##   writeFile("index.html", webPage(book))
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils, sequtils, algorithm, base64, times, hashes, math]
import zip

type
  PubBlockKind* = enum
    ## What a block of a page is.
    pbText, pbPicture

  PubRun* = object
    ## Text in one style.
    text*: string
    family*: string            ## its font ("" the page's)
    size*: float               ## pixels (0: the paragraph's tag's)
    color*: uint32             ## ARGB (0: black)
    bold*, italic*, underline*, strike*: bool
    link*: string              ## a link: a web or mail address, or "#name" a place in the book

  PubPara* = object
    ## A paragraph.
    runs*: seq[PubRun]
    tag*: string               ## "p", "h1" .. "h6", "li", "blockquote" ("" a "p")
    align*: string             ## "left", "center", "right", "justify" ("" as it reads)
    rtl*: bool                 ## right to left (Arabic)
    shading*: uint32           ## a fill behind it (ARGB; 0 none)

  PubBlock* = object
    ## A part of a page.
    kind*: PubBlockKind
    x*, y*, w*, h*: float      ## where it is (pixels from the page's top left)
    paras*: seq[PubPara]       ## text: its paragraphs
    picture*: string           ## a picture: its PNG or JPEG bytes
    alt*: string               ## ... what it shows, for readers ("" with `decorative`: none)
    decorative*: bool          ## ... a decoration: readers leave it out
    link*: string              ## a click on it goes there
    background*: uint32        ## a fill behind it (ARGB; 0 none)

  PubPage* = object
    ## A page: its blocks, in the order they are drawn.
    w*, h*: float
    title*: string             ## its title (the table of contents; "" its first heading)
    background*: uint32        ## the page's color (0: white)
    blocks*: seq[PubBlock]
    anchors*: seq[string]      ## places on it links go to ("#name")

  PubDoc* = object
    ## A book or a design to publish.
    title*, author*, publisher*, description*: string
    lang*: string              ## its language, a BCP 47 tag ("en", "ar")
    id*: string                ## its identifier ("" one made of its title)
    date*: string              ## when it was published, "2026-11-17" ("" none)
    pages*: seq[PubPage]
    cover*: string             ## its cover picture, PNG or JPEG ("" none)
    rtl*: bool                 ## its pages turn right to left
    stamp*: string             ## when it was made, "2026-11-17T09:00:00Z" ("" now)

proc esc(s: string): string =
  ## (text for XML and HTML)
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    of '\'': result.add "&#39;"
    else:
      if ord(c) < 32 and c notin {'\n', '\t'}: discard
      else: result.add c

proc cssColor(c: uint32): string =
  let a = int(c shr 24)
  if a >= 255: "#" & toHex(int(c and 0xFFFFFF), 6).toLowerAscii
  else: "rgba(" & $((c shr 16) and 255) & "," & $((c shr 8) and 255) & "," & $(c and 255) & "," &
        formatFloat(a / 255, ffDecimal, 3) & ")"

proc mimeOf(pic: string): string =
  if pic.len > 3 and pic[0] == '\xFF' and pic[1] == '\xD8': "image/jpeg"
  elif pic.len > 4 and pic.startsWith("\x89PNG"): "image/png"
  elif pic.len > 4 and pic.startsWith("GIF8"): "image/gif"
  elif pic.len > 12 and pic[8 .. 11] == "WEBP": "image/webp"
  elif pic.len > 4 and pic.startsWith("<svg"): "image/svg+xml"
  else: "image/png"

proc extOf(mime: string): string =
  case mime
  of "image/jpeg": ".jpg"
  of "image/gif": ".gif"
  of "image/webp": ".webp"
  of "image/svg+xml": ".svg"
  else: ".png"

proc runHtml(r: PubRun; baseSize: float): string =
  var style = ""
  if r.family.len > 0: style.add "font-family:'" & r.family.replace("'", "") & "',serif;"
  if r.size > 0 and abs(r.size - baseSize) > 0.5: style.add "font-size:" & formatFloat(r.size / baseSize, ffDecimal, 3) & "em;"
  if r.color != 0 and (r.color and 0xFFFFFF) != 0: style.add "color:" & cssColor(r.color) & ";"
  var t = esc(r.text).replace("\n", "<br/>")
  if r.bold: t = "<strong>" & t & "</strong>"
  if r.italic: t = "<em>" & t & "</em>"
  if r.underline: t = "<u>" & t & "</u>"
  if r.strike: t = "<s>" & t & "</s>"
  if style.len > 0: t = "<span style=\"" & style & "\">" & t & "</span>"
  if r.link.len > 0: t = "<a href=\"" & esc(r.link) & "\">" & t & "</a>"
  t

proc paraHtml(p: PubPara; baseSize: float): string =
  let tag = if p.tag in ["p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote"]: p.tag else: "p"
  var attrs = ""
  var style = ""
  if p.align in ["left", "center", "right", "justify"]: style.add "text-align:" & p.align & ";"
  if p.shading != 0: style.add "background:" & cssColor(p.shading) & ";padding:0.2em 0.4em;"
  if p.rtl: attrs.add " dir=\"rtl\""
  if style.len > 0: attrs.add " style=\"" & style & "\""
  var body = ""
  for r in p.runs: body.add runHtml(r, baseSize)
  if body.len == 0: body = "&#160;"
  "<" & tag & attrs & ">" & body & "</" & tag & ">"

proc readingOrder(pg: PubPage): seq[int] =
  ## (the blocks as they are read: down the page, and across where they stand side by side)
  result = toSeq(0 ..< pg.blocks.len)
  let rtl = block:
    var r = false
    for b in pg.blocks:
      for p in b.paras:
        if p.rtl: r = true
    r
  result.sort(proc (a, b: int): int =
    let A = pg.blocks[a]
    let B = pg.blocks[b]
    # (on the same band down the page: by where they are across)
    if A.y + A.h * 0.5 < B.y: -1
    elif B.y + B.h * 0.5 < A.y: 1
    elif rtl: cmp(B.x + B.w, A.x + A.w)
    else: cmp(A.x, B.x))

proc baseSizeOf(d: PubDoc): float =
  ## (the size most of its text is: the size 1 em is)
  var best = 0
  var counts: seq[(int, int)]
  for pg in d.pages:
    for b in pg.blocks:
      for p in b.paras:
        for r in p.runs:
          if r.size <= 0: continue
          let k = int(round(r.size))
          var found = false
          for c in counts.mitems:
            if c[0] == k:
              c[1] += r.text.len
              found = true
          if not found: counts.add (k, r.text.len)
  var n = 0
  for (k, c) in counts:
    if c > n:
      n = c
      best = k
  if best > 0: best.float else: 16.0

proc titleOf(pg: PubPage; n: int): string =
  if pg.title.len > 0: return pg.title
  for b in pg.blocks:
    for p in b.paras:
      if p.tag.len == 2 and p.tag[0] == 'h':
        var t = ""
        for r in p.runs: t.add r.text
        if t.strip.len > 0: return t.strip
  "Page " & $n

proc blockHtml(b: PubBlock; pic: string; baseSize: float): string =
  case b.kind
  of pbText:
    var list = false
    for p in b.paras:
      if p.tag == "li" and not list:
        result.add "<ul>"
        list = true
      elif p.tag != "li" and list:
        result.add "</ul>"
        list = false
      result.add paraHtml(p, baseSize)
    if list: result.add "</ul>"
  of pbPicture:
    let alt = if b.decorative: "" else: b.alt
    var img = "<img src=\"" & pic & "\" alt=\"" & esc(alt) & "\"" &
              (if b.decorative: " role=\"presentation\"" else: "") & "/>"
    if b.link.len > 0: img = "<a href=\"" & esc(b.link) & "\">" & img & "</a>"
    result = if b.decorative: img else: "<figure>" & img & "</figure>"

proc fixedBlockHtml(b: PubBlock; pic: string; baseSize: float): string =
  var style = "position:absolute;left:" & formatFloat(b.x, ffDecimal, 1) & "px;top:" &
              formatFloat(b.y, ffDecimal, 1) & "px;width:" & formatFloat(b.w, ffDecimal, 1) & "px;height:" &
              formatFloat(b.h, ffDecimal, 1) & "px;"
  if b.background != 0: style.add "background:" & cssColor(b.background) & ";"
  if b.kind == pbPicture:
    let alt = if b.decorative: "" else: b.alt
    let img = "<img style=\"" & style & "\" src=\"" & pic & "\" alt=\"" & esc(alt) & "\"/>"
    result = if b.link.len > 0: "<a href=\"" & esc(b.link) & "\">" & img & "</a>" else: img
  else:
    result = "<div style=\"" & style & "\">" & blockHtml(b, pic, baseSize) & "</div>"

const BookCss = """
body { margin: 0 4%; font-family: serif; line-height: 1.4; }
h1, h2, h3, h4, h5, h6 { line-height: 1.2; page-break-after: avoid; }
figure { margin: 1em 0; text-align: center; }
figure img, img { max-width: 100%; height: auto; }
p { margin: 0 0 0.6em 0; }
a { color: inherit; }
"""

proc epubOf*(d: PubDoc; fixed = false): string =
  ## The pages as an EPUB 3 file's bytes: reflowable -- the text and pictures of each page in
  ## reading order, a chapter a page -- or `fixed`, each page as it is laid out.
  var z = newZipWriter()
  var t = getTime()
  if d.stamp.len > 0:
    try: t = parse(d.stamp, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc()).toTime
    except CatchableError: discard
  let stamp = t.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  # (first, stored as it is: what kind of file it is)
  z.addFile("mimetype", "application/epub+zip", t, compress = false)
  z.addFile("META-INF/container.xml", """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>
""", t)
  let lang = if d.lang.len > 0: d.lang else: "en"
  let id = if d.id.len > 0: d.id else: "urn:retro:" & toHex(hash(d.title & d.author), 16).toLowerAscii
  let base = d.baseSizeOf
  var manifest = ""
  var spine = ""
  var nav = ""
  var pics: seq[tuple[name, data: string]]
  proc picName(data: string): string =
    for p in pics:
      if p.data == data: return p.name
    let name = "images/pic" & $(pics.len + 1) & extOf(mimeOf(data))
    pics.add (name, data)
    name
  for n, pg in d.pages:
    let file = "page" & $(n + 1) & ".xhtml"
    var body = ""
    for a in pg.anchors: body.add "<a id=\"" & esc(a) & "\"></a>"
    let pw = max(1.0, pg.w)
    let ph = max(1.0, pg.h)
    if fixed:
      for b in pg.blocks:
        let pic = if b.kind == pbPicture and b.picture.len > 0: picName(b.picture) else: ""
        if b.kind == pbPicture and pic.len == 0: continue
        body.add fixedBlockHtml(b, pic, base) & "\n"
    else:
      for k in pg.readingOrder:
        let b = pg.blocks[k]
        let pic = if b.kind == pbPicture and b.picture.len > 0: picName(b.picture) else: ""
        if b.kind == pbPicture and pic.len == 0: continue
        body.add blockHtml(b, pic, base) & "\n"
    let head = if fixed: "<meta name=\"viewport\" content=\"width=" & $int(pw) & ", height=" & $int(ph) & "\"/>"
               else: ""
    let bodyStyle = if fixed: " style=\"position:relative;margin:0;width:" & $int(pw) & "px;height:" & $int(ph) &
                              "px;overflow:hidden;font-size:" & formatFloat(base, ffDecimal, 1) & "px;" &
                              (if pg.background != 0: "background:" & cssColor(pg.background) & ";" else: "") & "\""
                    else: ""
    let title = pg.titleOf(n + 1)
    z.addFile("OEBPS/" & file, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE html>\n" &
              "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\" lang=\"" &
              esc(lang) & "\" xml:lang=\"" & esc(lang) & "\"" & (if d.rtl: " dir=\"rtl\"" else: "") & ">\n<head>" &
              "<meta charset=\"UTF-8\"/><title>" & esc(title) & "</title>" & head &
              "<link rel=\"stylesheet\" type=\"text/css\" href=\"book.css\"/></head>\n<body" & bodyStyle & ">\n" &
              body & "</body>\n</html>\n", t)
    let props = if fixed: " properties=\"rendition:layout-pre-paginated\"" else: ""
    manifest.add "    <item id=\"p" & $(n + 1) & "\" href=\"" & file & "\" media-type=\"application/xhtml+xml\"/>\n"
    spine.add "    <itemref idref=\"p" & $(n + 1) & "\"" & props & "/>\n"
    nav.add "      <li><a href=\"" & file & "\">" & esc(title) & "</a></li>\n"
  z.addFile("OEBPS/book.css", BookCss, t)
  z.addFile("OEBPS/nav.xhtml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE html>\n" &
            "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\" lang=\"" &
            esc(lang) & "\"><head><meta charset=\"UTF-8\"/><title>" & esc(d.title) & "</title></head><body>\n" &
            "  <nav epub:type=\"toc\" id=\"toc\"><h1>" & esc(d.title) & "</h1>\n    <ol>\n" & nav &
            "    </ol>\n  </nav>\n</body></html>\n", t)
  var coverItem = ""
  if d.cover.len > 0:
    let m = mimeOf(d.cover)
    let name = "images/cover" & extOf(m)
    z.addFile("OEBPS/" & name, d.cover, t)
    coverItem = "    <item id=\"cover\" href=\"" & name & "\" media-type=\"" & m & "\" properties=\"cover-image\"/>\n"
  for k, p in pics:
    z.addFile("OEBPS/" & p.name, p.data, t)
    manifest.add "    <item id=\"img" & $(k + 1) & "\" href=\"" & p.name & "\" media-type=\"" & mimeOf(p.data) & "\"/>\n"
  var meta = "    <dc:identifier id=\"bookid\">" & esc(id) & "</dc:identifier>\n" &
             "    <dc:title>" & esc(if d.title.len > 0: d.title else: "Untitled") & "</dc:title>\n" &
             "    <dc:language>" & esc(lang) & "</dc:language>\n" &
             "    <meta property=\"dcterms:modified\">" & stamp & "</meta>\n"
  if d.author.len > 0: meta.add "    <dc:creator>" & esc(d.author) & "</dc:creator>\n"
  if d.publisher.len > 0: meta.add "    <dc:publisher>" & esc(d.publisher) & "</dc:publisher>\n"
  if d.description.len > 0: meta.add "    <dc:description>" & esc(d.description) & "</dc:description>\n"
  if d.date.len > 0: meta.add "    <dc:date>" & esc(d.date) & "</dc:date>\n"
  # (accessibility: what the book is for readers)
  meta.add "    <meta property=\"schema:accessMode\">textual</meta>\n" &
           "    <meta property=\"schema:accessMode\">visual</meta>\n" &
           "    <meta property=\"schema:accessibilityFeature\">alternativeText</meta>\n" &
           "    <meta property=\"schema:accessibilityFeature\">tableOfContents</meta>\n" &
           "    <meta property=\"schema:accessibilityHazard\">none</meta>\n" &
           "    <meta property=\"schema:accessibilitySummary\">The pictures say what they show; the headings are " &
           "headings.</meta>\n"
  if fixed:
    meta.add "    <meta property=\"rendition:layout\">pre-paginated</meta>\n" &
             "    <meta property=\"rendition:spread\">auto</meta>\n"
  z.addFile("OEBPS/content.opf", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" &
            "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"bookid\" xml:lang=\"" &
            esc(lang) & "\">\n  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n" & meta & "  </metadata>\n" &
            "  <manifest>\n    <item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n" &
            "    <item id=\"css\" href=\"book.css\" media-type=\"text/css\"/>\n" & coverItem & manifest &
            "  </manifest>\n  <spine" & (if d.rtl: " page-progression-direction=\"rtl\"" else: "") & ">\n" & spine &
            "  </spine>\n</package>\n", t)
  z.finish()

const WebCss = """
:root { --page: #ffffff; --ink: #1a1a1a; }
* { box-sizing: border-box; }
body { margin: 0; background: #e9e7e2; color: var(--ink); font-family: system-ui, sans-serif; }
main { max-width: 980px; margin: 0 auto; padding: 16px; }
section.page { background: var(--page); margin: 0 0 24px; box-shadow: 0 1px 4px rgba(0,0,0,.18); }
section.page .flow { padding: 6% 7%; }
.fixed { position: relative; width: 100%; overflow: hidden; }
.fixed > * { position: absolute; }
.fixed img { width: 100%; height: 100%; object-fit: fill; }
figure { margin: 1em 0; } figure img { max-width: 100%; height: auto; display: block; }
img { max-width: 100%; }
nav.pages { display: flex; gap: 8px; flex-wrap: wrap; margin: 0 0 16px; }
nav.pages a { padding: 6px 10px; background: #fff; border-radius: 6px; text-decoration: none; color: #333; }
@media (max-width: 700px) { .fixed { display: none; } .phone { display: block !important; } }
.phone { display: none; padding: 6% 7%; }
"""

proc webPage*(d: PubDoc; pictures: ptr seq[tuple[name, data: string]] = nil): string =
  ## The pages as one web page: each page as it is laid out on a screen as wide as it, its text
  ## and pictures in reading order on a phone. The pictures inside it (data addresses), or --
  ## `pictures` given -- put there with the names it uses for them ("images/pic1.png"...).
  let lang = if d.lang.len > 0: d.lang else: "en"
  let base = d.baseSizeOf
  var body = ""
  var toc = ""
  proc picRef(data: string): string =
    if pictures == nil:
      return "data:" & mimeOf(data) & ";base64," & encode(data)
    for p in pictures[]:
      if p.data == data: return p.name
    let name = "images/pic" & $(pictures[].len + 1) & extOf(mimeOf(data))
    pictures[].add (name, data)
    name
  proc pct(v, of0: float): string = formatFloat(v / of0 * 100, ffDecimal, 3) & "%"
  for n, pg in d.pages:
    let pw = max(1.0, pg.w)
    let ph = max(1.0, pg.h)
    let title = pg.titleOf(n + 1)
    toc.add "<a href=\"#page" & $(n + 1) & "\">" & esc(title) & "</a>"
    var fixedHtml = ""
    var flow = ""
    for b in pg.blocks:
      if b.kind == pbPicture and b.picture.len == 0: continue
      let pic = if b.kind == pbPicture: picRef(b.picture) else: ""
      var style = "left:" & pct(b.x, pw) & ";top:" & pct(b.y, ph) & ";width:" & pct(b.w, pw) & ";height:" &
                  pct(b.h, ph) & ";"
      if b.background != 0: style.add "background:" & cssColor(b.background) & ";"
      if b.kind == pbPicture:
        let alt = if b.decorative: "" else: b.alt
        var img = "<img style=\"" & style & "\" src=\"" & pic & "\" alt=\"" & esc(alt) & "\"" &
                  (if b.decorative: " role=\"presentation\"" else: "") & ">"
        if b.link.len > 0: img = "<a href=\"" & esc(b.link) & "\">" & img & "</a>"
        fixedHtml.add img & "\n"
      else:
        fixedHtml.add "<div style=\"" & style & "font-size:" & formatFloat(base / pw * 100, ffDecimal, 3) &
                      "cqw\">" & blockHtml(b, pic, base) & "</div>\n"
    for k in pg.readingOrder:
      let b = pg.blocks[k]
      if b.kind == pbPicture and b.picture.len == 0: continue
      if b.kind == pbPicture and b.decorative: continue
      flow.add blockHtml(b, (if b.kind == pbPicture: picRef(b.picture) else: ""), base) & "\n"
    var anchors = ""
    for a in pg.anchors: anchors.add "<a id=\"" & esc(a) & "\"></a>"
    let bg = if pg.background != 0: " style=\"--page:" & cssColor(pg.background) & "\"" else: ""
    body.add "<section class=\"page\" id=\"page" & $(n + 1) & "\"" & bg & ">" & anchors &
             "<div class=\"fixed\" style=\"aspect-ratio:" & formatFloat(pw, ffDecimal, 2) & " / " &
             formatFloat(ph, ffDecimal, 2) & ";container-type:inline-size\">\n" & fixedHtml &
             "</div><div class=\"phone\">\n" & flow & "</div></section>\n"
  result = "<!DOCTYPE html>\n<html lang=\"" & esc(lang) & "\"" & (if d.rtl: " dir=\"rtl\"" else: "") & ">\n<head>\n" &
           "<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n" &
           "<title>" & esc(if d.title.len > 0: d.title else: "Untitled") & "</title>\n" &
           (if d.description.len > 0: "<meta name=\"description\" content=\"" & esc(d.description) & "\">\n" else: "") &
           (if d.author.len > 0: "<meta name=\"author\" content=\"" & esc(d.author) & "\">\n" else: "") &
           "<meta name=\"generator\" content=\"Retro Nim UI\">\n<style>" & WebCss & "</style>\n</head>\n<body>\n<main>\n" &
           (if d.pages.len > 1: "<nav class=\"pages\" aria-label=\"Pages\">" & toc & "</nav>\n" else: "") &
           body & "</main>\n</body>\n</html>\n"

proc publishSite*(d: PubDoc; dir: string) =
  ## The web page written into folder `dir`: index.html and its pictures beside it (images/),
  ## ready to put on any web host.
  var pics: seq[tuple[name, data: string]]
  let html = webPage(d, addr pics)
  createDir(dir / "images")
  for p in pics: writeFile(dir / p.name, p.data)
  writeFile(dir / "index.html", html)

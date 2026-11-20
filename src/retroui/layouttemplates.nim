## Presets and templates for new drawings and new books, as the New
## Document dialog shows them for photos: blank sizes by what they are for,
## and ready-made starting points with their pictures -- every part of them
## a layer to change (type, shapes, frames to place pictures into).
##
## - **Drawings** (vectors, saved as SVG): `drawingPresets`, and
##   `drawingTemplates` -- each an SVG, opened as layers (`placeSvg`).
## - **Books** (pages: `retroui/photobook`): `bookPresets` -- a page size,
##   facing or not, bound which way, margins, columns -- and `bookTemplates`,
##   each a proc that makes the book.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[math, strutils]
import photo, photobook, photoshapes, phototemplates, textengine

type
  DrawingCategory* = enum
    dcIcons = "Icons", dcLogos = "Logos & Brand", dcWeb = "Web & Screens", dcSocial = "Social",
    dcPrint = "Print", dcArt = "Illustration"
  DrawingTemplate* = object
    name*: string
    category*: DrawingCategory
    w*, h*: int               ## its size in pixels
    svg*: string              ## what it is (opened as layers)
  BookCategory* = enum
    bcBooks = "Books", bcMagazines = "Magazines", bcBrochures = "Brochures & Flyers",
    bcSocial = "Social & Infographics"
  BookPreset* = object
    name*: string
    category*: BookCategory
    setup*: BookSetup
    pages*: int
    wMm*, hMm*: float         ## its page in millimeters (as it is shown)
  BookTemplate* = object
    name*: string
    category*: BookCategory
    wMm*, hMm*: float
    facing*: bool
    build*: proc (): Book     ## makes it (a new book, nothing saved)

# ---- drawings ----------------------------------------------------------------------------------------

proc dp(c: DrawingCategory; name: string; w, h: int; dpi = 72; units = "px"): DocPreset =
  DocPreset(name: name, w: w, h: h, dpi: dpi, units: units)

proc mm(v: float; dpi: int): int = int(round(v / 25.4 * dpi.float))

proc drawingPresets*(c: DrawingCategory): seq[DocPreset] =
  ## The blank drawings of a tab.
  case c
  of dcIcons:
    @[dp(c, "Icon 24", 24, 24), dp(c, "Icon 48", 48, 48), dp(c, "Icon 128", 128, 128),
      dp(c, "App Icon", 1024, 1024), dp(c, "Favicon", 32, 32), dp(c, "Toolbar Icons", 256, 64)]
  of dcLogos:
    @[dp(c, "Logo", 1000, 1000), dp(c, "Wide Logo", 1600, 600), dp(c, "Letterhead Mark", 600, 200),
      dp(c, "Brand Board", 1920, 1080)]
  of dcWeb:
    @[dp(c, "Web 1920", 1920, 1080), dp(c, "Web 1440", 1440, 900), dp(c, "Banner", 1200, 300),
      dp(c, "Phone", 390, 844), dp(c, "Tablet", 820, 1180), dp(c, "Illustration Spot", 800, 600)]
  of dcSocial:
    @[dp(c, "Square Post", 1080, 1080), dp(c, "Portrait Post", 1080, 1350), dp(c, "Story", 1080, 1920),
      dp(c, "Cover", 1500, 500), dp(c, "Thumbnail", 1280, 720)]
  of dcPrint:
    @[dp(c, "A4", mm(210, 300), mm(297, 300), 300, "mm"), dp(c, "A3 Poster", mm(297, 150), mm(420, 150), 150, "mm"),
      dp(c, "Letter", 2550, 3300, 300, "in"), dp(c, "Business Card", mm(85, 300), mm(55, 300), 300, "mm"),
      dp(c, "Postcard", mm(148, 300), mm(105, 300), 300, "mm"), dp(c, "Sticker", mm(70, 300), mm(70, 300), 300, "mm")]
  of dcArt:
    @[dp(c, "Square", 2000, 2000), dp(c, "Landscape", 2400, 1600), dp(c, "Portrait", 1600, 2400),
      dp(c, "Wallpaper", 2560, 1440), dp(c, "Comic Page", 1800, 2700)]

const
  badgeSvg = """<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="1000" viewBox="0 0 1000 1000">
<rect width="1000" height="1000" fill="#f3ead8"/>
<circle cx="500" cy="500" r="380" fill="#1f3a5f"/>
<circle cx="500" cy="500" r="330" fill="none" stroke="#e9b44c" stroke-width="14"/>
<path d="M300 560 L500 300 L700 560 Z" fill="#e9b44c"/>
<path d="M380 560 L500 410 L620 560 Z" fill="#f3ead8"/>
<rect x="250" y="600" width="500" height="90" rx="20" fill="#9b2915"/>
<text x="500" y="662" font-family="FreeSans" font-weight="bold" font-size="56" fill="#f3ead8" text-anchor="middle">YOUR BRAND</text>
<text x="500" y="770" font-family="FreeSerif" font-style="italic" font-size="40" fill="#f3ead8" text-anchor="middle">since 2026</text>
</svg>"""
  landscapeSvg = """<svg xmlns="http://www.w3.org/2000/svg" width="2400" height="1600" viewBox="0 0 2400 1600">
<rect width="2400" height="1600" fill="#f6d8ae"/>
<circle cx="1700" cy="560" r="260" fill="#e4572e"/>
<path d="M0 1000 C400 760 700 820 1000 960 C1300 1100 1600 760 2400 900 L2400 1600 L0 1600 Z" fill="#c97c5d"/>
<path d="M0 1180 C500 980 900 1120 1300 1180 C1700 1240 2000 1080 2400 1140 L2400 1600 L0 1600 Z" fill="#2e4057"/>
<path d="M0 1380 C600 1260 1200 1420 2400 1320 L2400 1600 L0 1600 Z" fill="#17a398"/>
<path d="M300 300 C340 280 380 280 420 300 C460 280 500 280 540 300" fill="none" stroke="#2e4057" stroke-width="10" stroke-linecap="round"/>
<path d="M620 220 C650 205 680 205 710 220 C740 205 770 205 800 220" fill="none" stroke="#2e4057" stroke-width="8" stroke-linecap="round"/>
</svg>"""
  appIconSvg = """<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<rect x="64" y="64" width="896" height="896" rx="200" fill="#3a86ff"/>
<rect x="64" y="64" width="896" height="448" rx="200" fill="#5c9dff"/>
<circle cx="512" cy="512" r="250" fill="#ffffff"/>
<path d="M430 400 L640 512 L430 624 Z" fill="#3a86ff"/>
</svg>"""
  posterSvg = """<svg xmlns="http://www.w3.org/2000/svg" width="1754" height="2480" viewBox="0 0 1754 2480">
<rect width="1754" height="2480" fill="#14213d"/>
<circle cx="1300" cy="700" r="520" fill="#fca311"/>
<rect x="120" y="1500" width="1514" height="12" fill="#e5e5e5"/>
<text x="120" y="1380" font-family="FreeSans" font-weight="bold" font-size="240" fill="#ffffff">EVENT</text>
<text x="120" y="1640" font-family="FreeSans" font-size="72" fill="#e5e5e5">SATURDAY 12 DECEMBER · 7 PM</text>
<text x="120" y="1760" font-family="FreeSerif" font-style="italic" font-size="64" fill="#fca311">A place, a city</text>
<text x="120" y="2340" font-family="FreeSans" font-size="44" fill="#e5e5e5">www.example.com</text>
</svg>"""
  cardSvg = """<svg xmlns="http://www.w3.org/2000/svg" width="1004" height="650" viewBox="0 0 1004 650">
<rect width="1004" height="650" fill="#ffffff"/>
<rect width="300" height="650" fill="#264653"/>
<circle cx="150" cy="325" r="90" fill="#e9c46a"/>
<text x="360" y="250" font-family="FreeSans" font-weight="bold" font-size="56" fill="#264653">Your Name</text>
<text x="360" y="310" font-family="FreeSans" font-size="32" fill="#2a9d8f">Title or role</text>
<rect x="360" y="350" width="120" height="6" fill="#e76f51"/>
<text x="360" y="440" font-family="FreeSans" font-size="28" fill="#333333">+968 0000 0000</text>
<text x="360" y="490" font-family="FreeSans" font-size="28" fill="#333333">name@example.com</text>
</svg>"""
  quoteSvg = """<svg xmlns="http://www.w3.org/2000/svg" width="1080" height="1080" viewBox="0 0 1080 1080">
<rect width="1080" height="1080" fill="#fefae0"/>
<rect x="80" y="80" width="920" height="920" rx="48" fill="#283618"/>
<text x="160" y="330" font-family="FreeSerif" font-weight="bold" font-size="200" fill="#dda15e">“</text>
<text x="160" y="480" font-family="FreeSerif" font-size="64" fill="#fefae0">A short quote</text>
<text x="160" y="560" font-family="FreeSerif" font-size="64" fill="#fefae0">that says it well.</text>
<rect x="160" y="680" width="160" height="8" fill="#dda15e"/>
<text x="160" y="780" font-family="FreeSans" font-size="40" fill="#fefae0">Someone</text>
</svg>"""

proc drawingTemplates*(): seq[DrawingTemplate] =
  ## The ready-made drawings.
  @[DrawingTemplate(name: "Badge Logo", category: dcLogos, w: 1000, h: 1000, svg: badgeSvg),
    DrawingTemplate(name: "Flat Landscape", category: dcArt, w: 2400, h: 1600, svg: landscapeSvg),
    DrawingTemplate(name: "App Icon", category: dcIcons, w: 1024, h: 1024, svg: appIconSvg),
    DrawingTemplate(name: "Event Poster", category: dcPrint, w: 1754, h: 2480, svg: posterSvg),
    DrawingTemplate(name: "Business Card", category: dcPrint, w: 1004, h: 650, svg: cardSvg),
    DrawingTemplate(name: "Quote Post", category: dcSocial, w: 1080, h: 1080, svg: quoteSvg)]

proc templatesOf*(c: DrawingCategory): seq[DrawingTemplate] =
  for t in drawingTemplates():
    if t.category == c: result.add t

# ---- books -------------------------------------------------------------------------------------------

proc bp(c: BookCategory; name: string; wMm, hMm: float; facing: bool; pages: int; binding = bindLeft;
        margin = 15.0; columns = 1; dpi = 150.0; numbers = nsDigits): BookPreset =
  var s = bookSetup(wMm, hMm, dpi = dpi, facing = facing, binding = binding, marginMm = margin)
  s.columns = columns
  s.numbers = numbers
  BookPreset(name: name, category: c, setup: s, pages: pages, wMm: wMm, hMm: hMm)

proc bookPresets*(c: BookCategory): seq[BookPreset] =
  ## The blank books of a tab.
  case c
  of bcBooks:
    @[bp(c, "Novel A5", 148, 210, true, 16), bp(c, "Arabic Book A5", 148, 210, true, 16, bindRight,
                                                 numbers = nsArabicIndic),
      bp(c, "Trade 6 x 9 in", 152.4, 228.6, true, 16), bp(c, "Pocket Book", 110, 178, true, 16, margin = 12),
      bp(c, "Children's Square", 216, 216, true, 12, margin = 18), bp(c, "Report A4", 210, 297, false, 8, margin = 20)]
  of bcMagazines:
    @[bp(c, "Magazine A4", 210, 297, true, 8, margin = 14, columns = 3),
      bp(c, "Magazine Letter", 215.9, 279.4, true, 8, margin = 14, columns = 3),
      bp(c, "Zine A5", 148, 210, true, 8, margin = 10, columns = 2),
      bp(c, "Newsletter A4", 210, 297, false, 4, margin = 15, columns = 2)]
  of bcBrochures:
    @[bp(c, "Flyer A4", 210, 297, false, 1, margin = 12), bp(c, "Flyer A5", 148, 210, false, 2, margin = 10),
      bp(c, "Tri-fold A4", 297, 210, false, 2, margin = 8, columns = 3), bp(c, "Menu", 210, 297, true, 4, margin = 15),
      bp(c, "Catalog", 210, 210, true, 12, margin = 12, columns = 2)]
  of bcSocial:
    @[bp(c, "Carousel 1080 x 1350", 285.75, 357.19, false, 5, margin = 16, dpi = 96),
      bp(c, "Carousel Square", 285.75, 285.75, false, 5, margin = 16, dpi = 96),
      bp(c, "Story Cards", 285.75, 508.0, false, 5, margin = 18, dpi = 96),
      bp(c, "Slides 16:9", 338.67, 190.5, false, 8, margin = 12, dpi = 96)]

# (template helpers: shapes and text in a box)

proc st(size: float; color: uint32; family = "FreeSans"; bold = false; italic = false): CharStyle =
  CharStyle(family: family, style: (if bold and italic: "Bold Italic" elif bold: "Bold" elif italic: "Italic"
                                    else: "Regular"),
            size: size, color: color, hScale: 1, vScale: 1)

proc box(d: Doc; x0, y0, x1, y1: int; c: uint32; radius = 0.0; name = "Box"): Layer =
  d.addShapeLayer(ShapeData(path: rectPath(x0.float, y0.float, x1.float, y1.float, radius), fill: solidPaint(c)), name)

proc words(d: Doc; s: string; style: CharStyle; x, y, w, h: int; align = textLeft; rtl = 0; leading = 0.0): Layer =
  var t = newText(s, style, x.float32, y.float32)
  t.boxW = w.float32
  t.boxH = h.float32
  t.autoSize = asHeight          # (titles and headings: the box follows a size changed, as the layout program's)
  t.para.align = align
  t.para.rtl = rtl
  if leading > 0:
    for sp in t.spans.mitems: sp.style.leading = leading
  d.addTextLayer(t)

const
  bodyEn = "Write your text here. This box takes as much as it holds; what does not fit goes on to the " &
           "next page by itself (Layout > Autoflow Through New Pages). Click in it with the Type tool to " &
           "change it, and use the Paragraph and Character panels for how it is set.\n" &
           "Paragraphs keep the space you give them. Pictures keep the text out of their way once they " &
           "have Text Wrap (Layout > Text Wrap). Every page number is put there by the master page.\n"
  bodyAr = "اكتب نصك هنا. يأخذ هذا المربع ما يتسع له، وما لا يتسع ينتقل إلى الصفحة التالية من تلقاء نفسه " &
           "(تخطيط > تدفق تلقائي عبر صفحات جديدة). انقر فيه بأداة الكتابة لتغييره.\n" &
           "تحفظ الفقرات المسافة التي تعطيها لها، وتبعد الصور النص عن طريقها إذا كان لها التفاف النص.\n"

proc folios(b: Book; color: uint32; head: string; rtl = 0) =
  ## (a master with a running head, a rule and the page number at the outer edge)
  let m = b.addMaster("A")
  for side in (if b.setup.facing: @[psLeft, psRight] else: @[psRight]):
    let md = b.masterDoc(m, side)
    let mb = b.marginBox(side)
    let outer = if side == psLeft: textLeft else: textRight
    discard md.box(mb.x, mb.y - 24, mb.x + mb.w, mb.y - 22, color, 0, "Rule")
    discard md.words(head, st(11, color, bold = true), mb.x, mb.y - 46, mb.w, 20, outer, rtl)
    discard md.words("<#>", st(13, color, bold = true), mb.x, mb.y + mb.h + 12, mb.w, 22, outer)
    md.markAll()
  for i in 0 ..< b.pages.len: b.setMaster(i, m.id)

proc novel(rtl: bool): Book =
  var s = bookSetup(148, 210, dpi = 150, facing = true, binding = (if rtl: bindRight else: bindLeft), marginMm = 16)
  s.paper = 0xFFFBF7EF'u32
  if rtl: s.numbers = nsArabicIndic
  result = newBook(s, pages = 3, name = (if rtl: "كتاب" else: "Novel"))
  let b = result
  let ink = 0xFF222222'u32
  let accent = 0xFF7A2E1F'u32
  let dir = if rtl: 2 else: 0
  # the title page (no master)
  block:
    let d = b.doc(0)
    let mb = b.marginBox(0)
    discard d.words((if rtl: "عنوان الكتاب" else: "The Title"), st(54, ink, "FreeSerif", bold = true),
                    mb.x, mb.y + mb.h div 3, mb.w, 90, textCenter, dir)
    discard d.box(s.w div 2 - 50, mb.y + mb.h div 3 + 110, s.w div 2 + 50, mb.y + mb.h div 3 + 114, accent)
    discard d.words((if rtl: "اسم المؤلف" else: "Author Name"), st(22, accent, "FreeSerif", italic = true),
                    mb.x, mb.y + mb.h div 3 + 140, mb.w, 40, textCenter, dir)
    d.markAll()
  b.folios(accent, (if rtl: "عنوان الكتاب" else: "THE TITLE"), dir)
  b.setMaster(0, 0)
  # chapter one: a heading, a story that goes on through the pages
  block:
    let d = b.doc(1)
    let mb = b.marginBox(1)
    discard d.words((if rtl: "الفصل الأول" else: "Chapter One"), st(30, accent, "FreeSerif", bold = true),
                    mb.x, mb.y + 60, mb.w, 50, textLeft, dir)
    var t = newText((if rtl: bodyAr else: bodyEn).repeat(6), st(12.5, ink, "FreeSerif"), 0, 0)
    t.para.align = justifyLeft
    t.para.rtl = dir
    t.para.spaceAfter = 6
    for sp in t.spans.mitems: sp.style.leading = 19
    var tb = b.boxed(t, 1)
    tb.y = float32(mb.y + 140)
    tb.boxH = float32(mb.h - 140)
    let L = d.addTextLayer(tb)
    d.markAll()
    discard b.autoflow(1, L, most = 6)
  b.park()
  b.modified = false

proc magazine(): Book =
  var s = bookSetup(210, 297, dpi = 110, facing = true, marginMm = 14)
  s.columns = 2
  s.paper = 0xFFF4EFE6'u32
  result = newBook(s, pages = 4, name = "Magazine")
  let b = result
  let W = s.w
  let H = s.h
  let navy = 0xFF14213D'u32
  let teal = 0xFF12807A'u32
  let amber = 0xFFFCA311'u32
  let ink = 0xFF1B1B1B'u32
  # the cover: a masthead, a picture frame, cover lines
  block:
    let d = b.doc(0)
    discard d.words("MASTHEAD", st(124, navy, bold = true), 44, 40, W - 88, 170)
    discard d.box(52, 214, W - 52, 220, navy)
    discard d.words("No. 1   MONTH 2026", st(14, ink), 52, 232, 400, 22)
    # (a photo placeholder: the program says on it how a picture goes in -- not in the file)
    d.box(52, 280, W - 52, 900, 0xFFD9D4CB'u32, 0, "Picture frame").attrs.placeholder = 1
    discard d.box(52, 940, 62, 1080, amber)
    discard d.words("THE COVER\nSTORY", st(54, navy, bold = true), 80, 932, W - 130, 140, leading = 58)
    discard d.words("A line that tells the reader why it matters", st(22, ink, "FreeSerif", italic = true),
                    80, 1080, 600, 60)
    d.markAll()
  b.folios(navy, "MASTHEAD")
  b.setMaster(0, 0)
  # the feature: a band across the spread, a headline, text through the pages
  block:
    let d = b.doc(1)
    let mb = b.marginBox(1)
    discard d.box(mb.x, mb.y, mb.x + 2 * W - 2 * mb.x, mb.y + 230, teal, 0, "Band across the spread")
    discard d.words("A Headline in Two Lines", st(46, navy, "FreeSerif", bold = true), mb.x, mb.y + 250, mb.w, 120,
                    leading = 50)
    var t = newText(bodyEn.repeat(15), st(15, ink, "FreeSerif"), 0, 0)
    t.para.align = justifyLeft
    t.para.spaceAfter = 6
    for sp in t.spans.mitems: sp.style.leading = 22
    var tb = b.boxed(t, 1)
    tb.y = float32(mb.y + 390)
    tb.boxH = float32(mb.h - 390)
    let L = d.addTextLayer(tb)
    d.markAll()
    discard b.flowOnto(1, L, 2)
    let d2 = b.doc(2)
    let m2 = b.marginBox(2)
    for M in d2.layers:
      if M.isText and M.flowPage != 0:
        var u = M.text
        u.y = float32(m2.y + 250)
        u.boxH = float32(m2.h - 250)
        d2.setText(M, u)
    d2.markAll()
    discard b.syncSpread(1)
  # the back cover
  block:
    let d = b.doc(3)
    discard d.box(0, 0, W, H, navy, 0, "Back")
    discard d.words("Next issue", st(44, 0xFFFFFFFF'u32, bold = true), 80, H div 2 - 60, W - 160, 60, textCenter)
    discard d.words("What comes next, in a line", st(22, amber, "FreeSerif", italic = true), 80, H div 2 + 10,
                    W - 160, 40, textCenter)
    d.markAll()
  b.park()
  b.modified = false

proc cards(rtl: bool): Book =
  var s = bookSetup(285.75, 357.19, dpi = 96, facing = false, marginMm = 16)
  s.paper = 0xFFF1E6D2'u32
  if rtl: s.numbers = nsArabicIndic
  result = newBook(s, pages = 2, name = (if rtl: "بطاقات" else: "Infographic"))
  let b = result
  let W = s.w
  let indigo = 0xFF22304A'u32
  let saffron = 0xFFE0A030'u32
  let sea = 0xFF2E8B74'u32
  let clay = 0xFFC8553D'u32
  let dir = if rtl: 2 else: 1
  let m = b.addMaster("A")
  block:
    let md = b.masterDoc(m, psRight)
    discard md.box(60, 44, 132, 104, indigo, 14, "Number")
    var t = newText("<#>", st(34, 0xFFFFFFFF'u32, bold = true), 60, 54)
    t.boxW = 72
    t.boxH = 44
    t.para.align = textCenter
    t.para.rtl = 1
    discard md.addTextLayer(t)
    md.markAll()
  for i in 0 .. 1: b.setMaster(i, m.id)
  block:
    let d = b.doc(0)
    d.box(60, 150, W - 60, 640, 0xFFDCE6E2'u32, 36, "Picture panel").attrs.placeholder = 1
    discard d.box(60, 664, W - 60, 852, indigo, 36, "Title band")
    discard d.words((if rtl: "العنوان الرئيسي" else: "Main Title"), st(84, 0xFFFFFFFF'u32, bold = true),
                    100, 680, W - 200, 100, textCenter, dir)
    discard d.words((if rtl: "سطر يشرح الموضوع" else: "A line about the subject"), st(34, saffron, bold = true),
                    100, 786, W - 200, 50, textCenter, dir)
    var t = newText((if rtl: "نقطة أولى\nنقطة ثانية\nنقطة ثالثة" else: "A first point\nA second point\nA third point"),
                    st(34, indigo, "FreeSerif"), 90.0, 900.0)
    t.boxW = float32(W - 180)
    t.boxH = 260
    t.para.rtl = dir
    t.para.list = lkBullet
    t.para.listMark = "◆"
    t.para.listColor = clay
    for sp in t.spans.mitems: sp.style.leading = 56
    discard d.addTextLayer(t)
    d.markAll()
  block:
    let d = b.doc(1)
    let figures = [("94%", if rtl: "نسبة الإنجاز" else: "done"), ("57", if rtl: "مشروعًا" else: "projects"),
                   ("3", if rtl: "كم" else: "km")]
    for i, (figure, unit) in figures:
      let x = W - 60 - (i + 1) * 306 - i * 21
      discard d.box(x, 300, x + 306, 560, (if i == 1: sea else: indigo), 22, "Tile")
      var f = newText(figure, st(84, saffron, bold = true), float32(x + 14), 360)
      f.boxW = 278
      f.boxH = 100
      f.para.align = textCenter
      f.para.rtl = 1
      discard d.addTextLayer(f)
      discard d.words(unit, st(26, 0xFFF1E6D2'u32), x + 14, 470, 278, 40, textCenter, dir)
    discard d.box(W - 60 - 420, 150, W - 60, 214, clay, 32, "Heading")
    discard d.words((if rtl: "بالأرقام" else: "In numbers"), st(34, 0xFFFFFFFF'u32, bold = true),
                    W - 60 - 420, 160, 420, 48, textCenter, dir)
    d.markAll()
  b.park()
  b.modified = false

proc bookTemplates*(): seq[BookTemplate] =
  ## The ready-made books.
  @[BookTemplate(name: "Novel", category: bcBooks, wMm: 148, hMm: 210, facing: true,
                 build: proc (): Book = novel(false)),
    BookTemplate(name: "Arabic Book", category: bcBooks, wMm: 148, hMm: 210, facing: true,
                 build: proc (): Book = novel(true)),
    BookTemplate(name: "Magazine", category: bcMagazines, wMm: 210, hMm: 297, facing: true,
                 build: magazine),
    BookTemplate(name: "Infographic Cards", category: bcSocial, wMm: 285.75, hMm: 357.19, facing: false,
                 build: proc (): Book = cards(false)),
    BookTemplate(name: "Arabic Infographic", category: bcSocial, wMm: 285.75, hMm: 357.19, facing: false,
                 build: proc (): Book = cards(true))]

proc templatesOf*(c: BookCategory): seq[BookTemplate] =
  for t in bookTemplates():
    if t.category == c: result.add t

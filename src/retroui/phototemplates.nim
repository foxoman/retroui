## New documents as today's Photoshop offers them: blank document presets
## by what they are for (Photo, Print, Social, Web, Mobile, Art and
## Illustration, Film and Video) and ready-made templates -- a flyer, a
## certificate, a notice, a business card, social posts, a collage... --
## made of layers that stay editable: type, shapes, and frames to place
## photos into (Layer > Place Into).
##
## ```nim
## for p in docPresets(pcSocial): echo p.name, " ", p.w, " x ", p.h
## let t = docTemplates()[0]
## let d = buildTemplate(t)              # full size, its layers editable
## let thumb = templateThumb(t, 160)     # a small picture of it
## ```
##
## Everything in a template is placed by fractions of the page, so the same
## template is built at any size (a thumbnail is built small, not shrunk).

import std/[math, strutils]
import gfx, photo, photoshapes, textengine, qrcode

type
  PresetCategory* = enum
    ## The New Document dialog's tabs (with Recent and Saved).
    pcPhoto = "Photo", pcPrint = "Print", pcSocial = "Social", pcWeb = "Web", pcMobile = "Mobile",
    pcArt = "Art & Illustration", pcFilm = "Film & Video"

  DocPreset* = object
    ## A blank document: its size in pixels at `dpi`, and how it is shown
    ## (`units`: "px", "in", "mm" -- the unit its size is known by).
    name*: string               ## shown in the dialog ("A4", "Instagram Post")
    w*, h*: int                 ## its size in pixels
    dpi*: int                   ## pixels per inch
    units*: string              ## the unit its size is shown in
    category*: PresetCategory   ## the dialog's tab it is on

  DocTemplate* = object
    ## A ready-made document: what it is, its size, and how it is made.
    name*: string               ## shown in the dialog
    category*: PresetCategory   ## the dialog's tab it is on
    w*, h*: int                 ## its size in pixels (at `scale` 1)
    dpi*: int                   ## pixels per inch
    build*: proc (d: Doc; say: proc (s: string): string)
      ## adds its layers to the new document `d` (`say` translates its
      ## words); `buildTemplate` calls it

proc preset(c: PresetCategory; name: string; w, h, dpi: int; units = "px"): DocPreset =
  DocPreset(name: name, w: w, h: h, dpi: dpi, units: units, category: c)

proc mmPx(mm: float; dpi: int): int = int(round(mm / 25.4 * dpi.float))

proc docPresets*(c: PresetCategory): seq[DocPreset] =
  ## The blank documents of a tab, as Photoshop lists them (and today's
  ## social sizes).
  case c
  of pcPhoto:
    @[preset(c, "Default Size", 2100, 1500, 300, "in"),
      preset(c, "Landscape, 4 x 6", 1800, 1200, 300, "in"), preset(c, "Portrait, 4 x 6", 1200, 1800, 300, "in"),
      preset(c, "Landscape, 5 x 7", 2100, 1500, 300, "in"), preset(c, "Portrait, 5 x 7", 1500, 2100, 300, "in"),
      preset(c, "Landscape, 8 x 10", 3000, 2400, 300, "in"), preset(c, "Portrait, 8 x 10", 2400, 3000, 300, "in"),
      preset(c, "Square, 8 x 8", 2400, 2400, 300, "in"),
      preset(c, "Passport Photo, 35 x 45 mm", mmPx(35, 300), mmPx(45, 300), 300, "mm"),
      preset(c, "ID Photo, 2 x 2", 600, 600, 300, "in")]
  of pcPrint:
    @[preset(c, "A4", mmPx(210, 300), mmPx(297, 300), 300, "mm"),
      preset(c, "A4 Landscape", mmPx(297, 300), mmPx(210, 300), 300, "mm"),
      preset(c, "A5", mmPx(148, 300), mmPx(210, 300), 300, "mm"),
      preset(c, "A3", mmPx(297, 300), mmPx(420, 300), 300, "mm"),
      preset(c, "A6 Postcard", mmPx(148, 300), mmPx(105, 300), 300, "mm"),
      preset(c, "Letter", 2550, 3300, 300, "in"), preset(c, "Legal", 2550, 4200, 300, "in"),
      preset(c, "Tabloid", 3300, 5100, 300, "in"),
      preset(c, "Business Card, 85 x 55 mm", mmPx(85, 300), mmPx(55, 300), 300, "mm"),
      preset(c, "Business Card, 3.5 x 2", 1050, 600, 300, "in"),
      preset(c, "Roll-up Banner, 85 x 200 cm", mmPx(850, 100), mmPx(2000, 100), 100, "mm")]
  of pcSocial:
    @[preset(c, "Instagram Post", 1080, 1080, 72), preset(c, "Instagram Portrait", 1080, 1350, 72),
      preset(c, "Story / Reel", 1080, 1920, 72), preset(c, "Facebook Post", 1200, 630, 72),
      preset(c, "Facebook Cover", 1640, 624, 72), preset(c, "X Post", 1600, 900, 72),
      preset(c, "LinkedIn Post", 1200, 627, 72), preset(c, "LinkedIn Banner", 1584, 396, 72),
      preset(c, "YouTube Thumbnail", 1280, 720, 72), preset(c, "YouTube Banner", 2560, 1440, 72),
      preset(c, "WhatsApp Status", 1080, 1920, 72), preset(c, "Profile Picture", 800, 800, 72)]
  of pcWeb:
    @[preset(c, "Web Most Common", 1366, 768, 72), preset(c, "Web Large", 1920, 1080, 72),
      preset(c, "Web Medium", 1280, 800, 72), preset(c, "Web Minimum", 1024, 768, 72),
      preset(c, "MacBook Pro 14", 3024, 1964, 72), preset(c, "Web Banner, Leaderboard", 728, 90, 72),
      preset(c, "Web Banner, Medium Rectangle", 300, 250, 72), preset(c, "Email Header", 600, 200, 72),
      preset(c, "Favicon", 64, 64, 72)]
  of pcMobile:
    @[preset(c, "iPhone 16 Pro", 1206, 2622, 72), preset(c, "iPhone 16", 1179, 2556, 72),
      preset(c, "iPhone SE", 750, 1334, 72), preset(c, "Android Phone", 1080, 2400, 72),
      preset(c, "Android Tablet", 1600, 2560, 72), preset(c, "iPad Pro 11", 1668, 2420, 72),
      preset(c, "iPad 10.9", 1640, 2360, 72), preset(c, "App Icon", 1024, 1024, 72),
      preset(c, "Android Icon", 512, 512, 72), preset(c, "Apple Watch", 416, 496, 72)]
  of pcArt:
    @[preset(c, "Square Canvas", 2000, 2000, 300), preset(c, "Poster, 18 x 24", 2700, 3600, 150, "in"),
      preset(c, "Comic Page", 1988, 3075, 300, "in"), preset(c, "Sketch, A4", mmPx(210, 150), mmPx(297, 150), 150, "mm"),
      preset(c, "Pixel Art, 64 x 64", 64, 64, 72), preset(c, "Pixel Art, 128 x 128", 128, 128, 72),
      preset(c, "Wallpaper, Phone", 1440, 3200, 72), preset(c, "Wallpaper, Desktop", 3840, 2160, 72)]
  of pcFilm:
    @[preset(c, "HDTV 1080p", 1920, 1080, 72), preset(c, "UHD 4K", 3840, 2160, 72),
      preset(c, "HDV / HDTV 720p", 1280, 720, 72), preset(c, "Vertical Video", 1080, 1920, 72),
      preset(c, "Square Video", 1080, 1080, 72), preset(c, "DCI 2K", 2048, 1080, 72),
      preset(c, "DCI 4K", 4096, 2160, 72), preset(c, "Cinema Scope", 2048, 858, 72)]

proc sizeLabel*(p: DocPreset): string =
  ## "1080 x 1080 px", "210 x 297 mm @ 300 ppi", "4 x 6 in @ 300 ppi".
  proc num(v: float): string =
    let r = round(v * 10) / 10
    if abs(r - round(r)) < 0.15: $int(round(r)) else: formatFloat(r, ffDecimal, 1)
  case p.units
  of "mm": num(p.w / p.dpi * 25.4) & " x " & num(p.h / p.dpi * 25.4) & " mm @ " & $p.dpi & " ppi"
  of "in": num(p.w / p.dpi) & " x " & num(p.h / p.dpi) & " in @ " & $p.dpi & " ppi"
  else: $p.w & " x " & $p.h & " px"

# ---- what the templates are made of ----------------------------------------------------------------------

type Page = object
  d: Doc
  say: proc (s: string): string

proc X(p: Page; f: float): float = f * p.d.w.float
proc Y(p: Page; f: float): float = f * p.d.h.float
proc S(p: Page; f: float): float = f * min(p.d.w, p.d.h).float

proc rgb(c: int): uint32 = 0xFF000000'u32 or uint32(c and 0xFFFFFF)

proc box(p: Page; name: string; x0, y0, x1, y1: float; paint: ShapePaint; radius = 0.0;
         stroke = 0.0; strokeColor = 0'u32; ellipse = false): Layer {.discardable.} =
  ## A rectangle (or an ellipse) by fractions of the page; `radius` and
  ## `stroke` by fractions of its smaller side.
  let (a, b, c, e) = (p.X(x0), p.Y(y0), p.X(x1), p.Y(y1))
  var sd = ShapeData(fill: paint, kind: if ellipse: "Ellipse" else: "Rectangle")
  sd.path = if ellipse: ellipsePath(a, b, c, e) else: rectPath(a, b, c, e, p.S(radius))
  sd.radius = p.S(radius)
  if stroke > 0:
    sd.stroke = solidPaint(strokeColor)
    sd.strokeWidth = max(1.0, p.S(stroke))
    sd.align = saInside
  p.d.addShapeLayer(sd, p.say(name))

proc circle(p: Page; name: string; cx, cy, r: float; paint: ShapePaint; stroke = 0.0;
            strokeColor = 0'u32): Layer {.discardable.} =
  ## A circle: its middle by fractions of the page, its radius of the
  ## smaller side.
  let rr = p.S(r)
  let (x, y) = (p.X(cx), p.Y(cy))
  var sd = ShapeData(fill: paint, kind: "Ellipse")
  sd.path = ellipsePath(x - rr, y - rr, x + rr, y + rr)
  if stroke > 0:
    sd.stroke = solidPaint(strokeColor)
    sd.strokeWidth = max(1.0, p.S(stroke))
    sd.align = saInside
  p.d.addShapeLayer(sd, p.say(name))

proc frame(p: Page; x0, y0, x1, y1: float; ellipse = false; round = 0.0) =
  ## A frame to place a photo into (Layer > Place Into), as the Frame tool
  ## makes one.
  var n = 1
  for L in p.d.layers:
    if L.name.startsWith("Frame "): inc n
  let (a, b, c, e) = (p.X(x0), p.Y(y0), p.X(x1), p.Y(y1))
  var sd = ShapeData(fill: solidPaint(0xFFC8C8C8'u32), stroke: solidPaint(0xFF808080'u32), strokeWidth: 1,
                     kind: if ellipse: "Ellipse" else: "Rectangle")
  sd.path = if ellipse: ellipsePath(a, b, c, e) else: rectPath(a, b, c, e, p.S(round))
  let L = p.d.addShapeLayer(sd, "Frame " & $n)
  L.attrs.placeholder = 1          # (a photo placeholder: a double-click puts a photo in)
  L.attrs.alt = p.say("Photo")

proc circleFrame(p: Page; cx, cy, r: float) =
  ## A round frame: its middle by fractions of the page, its radius of the
  ## smaller side.
  let rr = p.S(r)
  let (x, y) = (p.X(cx), p.Y(cy))
  p.frame((x - rr) / p.d.w.float, (y - rr) / p.d.h.float, (x + rr) / p.d.w.float, (y + rr) / p.d.h.float,
          ellipse = true)

proc star(p: Page; name: string; cx, cy, r: float; color: uint32) =
  ## A five-pointed star: its middle by fractions of the page, its radius
  ## of the smaller side.
  let rr = p.S(r)
  let (x, y) = (p.X(cx), p.Y(cy))
  var sd = ShapeData(fill: solidPaint(color), kind: "Star")
  sd.path = polygonPath(x - rr, y - rr, x + rr, y + rr, 5, star = true, indent = 55)
  discard p.d.addShapeLayer(sd, p.say(name))

proc crescent(p: Page; name: string; cx, cy, r: float; color: uint32) =
  ## A crescent moon: a circle with another taken out of it.
  let rr = p.S(r)
  let (x, y) = (p.X(cx), p.Y(cy))
  var sd = ShapeData(fill: solidPaint(color), kind: "")
  sd.path = ellipsePath(x - rr, y - rr, x + rr, y + rr)
  let k = rr * 0.86
  let (ox, oy) = (x + rr * 0.42, y - rr * 0.2)
  sd.path.combine(ellipsePath(ox - k, oy - k, ox + k, oy + k), poSubtract)
  discard p.d.addShapeLayer(sd, p.say(name))

proc words(p: Page; s: string; x, y: float; size: float; color: uint32; bold = false;
           align = textCenter; family = ""; tracking = 0; boxW = 0.0; boxH = 0.0): Layer {.discardable.} =
  ## Type: point text with its baseline at `x`, `y` (fractions of the page;
  ## the middle of the line when centered), `size` of the smaller side; or
  ## text in a box `boxW` x `boxH` wide (fractions) from `x`, `y`.
  var st = defaultStyle()
  st.size = max(1.0, p.S(size)).float32
  st.color = color
  st.tracking = tracking
  if family.len > 0:
    st.family = family
    st.style = "Regular"
  elif bold:
    st.style = "Bold"
  var t = newText(p.say(s), st, p.X(x).float32, p.Y(y).float32)
  t.para.align = align
  if boxW > 0:
    t.boxW = p.X(boxW).float32
    t.boxH = p.Y(boxH).float32
  p.d.addTextLayer(t)

# ---- the templates -----------------------------------------------------------------------------------------

proc eventFlyer(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.frame(0, 0, 1, 0.45)
  p.box("Accent", 0, 0.45, 1, 0.465, solidPaint(rgb(0xF2A541)))
  p.words("SUMMER POOL PARTY", 0.5, 0.565, 0.072, rgb(0x1F2933), bold = true)
  p.words("Music  ·  Food  ·  Fun for the whole family", 0.5, 0.615, 0.036, rgb(0x52606D))
  p.box("Date Box", 0.14, 0.655, 0.86, 0.735, solidPaint(rgb(0x0F5C63)), radius = 0.03)
  p.words("SATURDAY 14 JUNE  ·  4 PM", 0.5, 0.707, 0.04, rgb(0xFFFFFF), bold = true)
  p.words("Join us by the pool for an afternoon of music, games and fresh food. Free entry for members " &
          "and their families.", 0.1, 0.765, 0.03, rgb(0x3E4C59), boxW = 0.8, boxH = 0.12)
  p.box("Footer", 0, 0.925, 1, 1, solidPaint(rgb(0x1F2933)))
  p.words("Your Venue  ·  Reception +000 0000 0000", 0.5, 0.97, 0.026, rgb(0xFFFFFF))

proc employeeOfMonth(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.box("Background", 0, 0, 1, 1, gradientPaint(rgb(0x0B1F3A), rgb(0x1D4E89), angle = 90))
  p.words("EMPLOYEE OF THE MONTH", 0.5, 0.115, 0.064, rgb(0xE8C468), bold = true)
  p.words("OCTOBER 2026", 0.5, 0.165, 0.04, rgb(0xFFFFFF), tracking = 200)
  let r = 0.27
  let cy = 0.205 + r * min(d.w, d.h).float / d.h.float + 0.015
  p.circle("Gold Ring", 0.5, cy, r + 0.018, ShapePaint(kind: spNone), stroke = 0.012, strokeColor = rgb(0xE8C468))
  p.circleFrame(0.5, cy, r)
  p.words("Employee Name", 0.5, 0.69, 0.07, rgb(0xFFFFFF), bold = true)
  p.words("Department  ·  Position", 0.5, 0.735, 0.036, rgb(0xC9D6E8))
  p.words("Thank you for your outstanding dedication and the care you bring to our guests and colleagues " &
          "every day.", 0.12, 0.775, 0.033, rgb(0xFFFFFF), boxW = 0.76, boxH = 0.11)
  p.box("Line", 0.4, 0.905, 0.6, 0.907, solidPaint(rgb(0xE8C468)))
  p.words("Company Name", 0.5, 0.945, 0.032, rgb(0xE8C468), bold = true)

proc certificate(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.box("Paper", 0, 0, 1, 1, solidPaint(rgb(0xFFFDF6)))
  p.box("Border", 0.025, 0.035, 0.975, 0.965, ShapePaint(kind: spNone), stroke = 0.012,
        strokeColor = rgb(0xB8912F))
  p.box("Inner Border", 0.045, 0.063, 0.955, 0.937, ShapePaint(kind: spNone), stroke = 0.003,
        strokeColor = rgb(0xB8912F))
  p.words("CERTIFICATE", 0.5, 0.25, 0.1, rgb(0x14213D), bold = true, tracking = 120)
  p.words("OF ACHIEVEMENT", 0.5, 0.32, 0.042, rgb(0xB8912F), tracking = 400)
  p.words("This certificate is proudly presented to", 0.5, 0.42, 0.036, rgb(0x5C5C5C))
  p.words("Recipient Name", 0.5, 0.545, 0.1, rgb(0x14213D), family = "FreeSerif")
  p.box("Name Line", 0.28, 0.575, 0.72, 0.578, solidPaint(rgb(0xB8912F)))
  p.words("for completing the Guest Service Excellence training programme", 0.5, 0.65, 0.032, rgb(0x5C5C5C))
  for (x0, x1, lab) in [(0.12, 0.36, "Date"), (0.64, 0.88, "Signature")]:
    p.box(lab & " Line", x0, 0.8, x1, 0.803, solidPaint(rgb(0x14213D)))
    p.words(lab, (x0 + x1) / 2, 0.85, 0.028, rgb(0x5C5C5C))
  p.circle("Seal", 0.5, 0.81, 0.085, solidPaint(rgb(0xD4AF37)), stroke = 0.008, strokeColor = rgb(0xB8912F))
  p.star("Star", 0.5, 0.81, 0.045, rgb(0xFFFDF6))

proc businessCard(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.box("Bar", 0, 0, 0.055, 1, solidPaint(rgb(0x0F5C63)))
  p.circleFrame(0.83, 0.3, 0.17)
  p.words("Your Name", 0.12, 0.3, 0.1, rgb(0x1F2933), bold = true, align = textLeft)
  p.words("Job Title", 0.12, 0.42, 0.06, rgb(0x0F5C63), align = textLeft)
  p.box("Rule", 0.12, 0.5, 0.45, 0.505, solidPaint(rgb(0xF2A541)))
  p.words("+000 0000 0000", 0.12, 0.64, 0.055, rgb(0x3E4C59), align = textLeft)
  p.words("name@company.com", 0.12, 0.74, 0.055, rgb(0x3E4C59), align = textLeft)
  p.words("www.company.com", 0.12, 0.84, 0.055, rgb(0x3E4C59), align = textLeft)

proc staffNotice(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.box("Header", 0, 0, 1, 0.11, solidPaint(rgb(0x14213D)))
  p.box("Accent", 0, 0.11, 1, 0.116, solidPaint(rgb(0xF2A541)))
  p.words("NOTICE", 0.5, 0.075, 0.09, rgb(0xFFFFFF), bold = true, tracking = 300)
  p.words("Subject of the Notice", 0.08, 0.18, 0.05, rgb(0x14213D), bold = true, align = textLeft)
  p.words("Date: 1 November 2026", 0.08, 0.215, 0.028, rgb(0x7B8794), align = textLeft)
  p.words("Dear Colleagues,\n\nWe would like to inform all team members that the following arrangements " &
          "will take effect from the date above. Please read this notice carefully and share it with your " &
          "team.\n\n•  First point of the notice.\n•  Second point of the notice.\n•  Third point of the " &
          "notice.\n\nFor any questions, please contact the Human Resources office.\n\nThank you for your " &
          "cooperation.", 0.08, 0.25, 0.03, rgb(0x1F2933), align = textLeft, boxW = 0.84, boxH = 0.56)
  p.words("Human Resources Department", 0.08, 0.86, 0.032, rgb(0x14213D), bold = true, align = textLeft)
  p.box("Footer Line", 0.08, 0.93, 0.92, 0.932, solidPaint(rgb(0xCBD2D9)))
  p.words("Company Name  ·  Internal", 0.5, 0.96, 0.024, rgb(0x7B8794))

proc instagramAnnouncement(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.frame(0, 0, 1, 1)
  var shade = solidPaint(0xFF000000'u32)
  shade.opacity = 45
  p.box("Shade", 0, 0, 1, 1, shade)
  p.words("BIG NEWS", 0.5, 0.47, 0.15, rgb(0xFFFFFF), bold = true, tracking = 60)
  p.words("Something new is coming", 0.5, 0.56, 0.055, rgb(0xFFFFFF))
  p.box("Button", 0.32, 0.64, 0.68, 0.72, solidPaint(rgb(0xF2A541)), radius = 0.04)
  p.words("Learn more", 0.5, 0.696, 0.045, rgb(0x1F2933), bold = true)

proc storyEvent(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.box("Background", 0, 0, 1, 1, gradientPaint(rgb(0xF2994A), rgb(0x6A3093), angle = 90))
  p.words("THIS WEEKEND", 0.5, 0.12, 0.06, rgb(0xFFFFFF), tracking = 300)
  p.frame(0.1, 0.16, 0.9, 0.58, round = 0.05)
  p.words("BRUNCH", 0.5, 0.68, 0.16, rgb(0xFFFFFF), bold = true)
  p.words("Friday & Saturday  ·  11 AM – 3 PM", 0.5, 0.73, 0.045, rgb(0xFFFFFF))
  p.box("Button", 0.2, 0.8, 0.8, 0.85, solidPaint(rgb(0xFFFFFF)), radius = 0.06)
  p.words("Book your table", 0.5, 0.835, 0.05, rgb(0x6A3093), bold = true)

proc facebookCover(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.box("Background", 0, 0, 1, 1, solidPaint(rgb(0x0F5C63)))
  p.frame(0.55, 0, 1, 1)
  p.box("Edge", 0.54, 0, 0.55, 1, solidPaint(rgb(0xF2A541)))
  p.words("Your Business", 0.06, 0.45, 0.16, rgb(0xFFFFFF), bold = true, align = textLeft)
  p.words("A short line about what you do", 0.06, 0.6, 0.075, rgb(0xD9F2F0), align = textLeft)

proc youtubeThumbnail(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.box("Background", 0, 0, 1, 1, solidPaint(rgb(0x111111)))
  p.frame(0, 0, 0.58, 1)
  p.box("Panel", 0.56, 0, 1, 1, solidPaint(rgb(0xE63946)))
  p.words("HOW TO", 0.78, 0.33, 0.13, rgb(0xFFFFFF), bold = true)
  p.words("DO IT", 0.78, 0.53, 0.2, rgb(0xFFD60A), bold = true)
  p.words("in 5 minutes", 0.78, 0.7, 0.08, rgb(0xFFFFFF))

proc titleCard(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.box("Background", 0, 0, 1, 1, gradientPaint(rgb(0x000000), rgb(0x22313F), angle = 90))
  p.words("The Title", 0.5, 0.5, 0.14, rgb(0xFFFFFF), bold = true)
  p.box("Line", 0.42, 0.56, 0.58, 0.563, solidPaint(rgb(0xF2A541)))
  p.words("A SUBTITLE GOES HERE", 0.5, 0.64, 0.04, rgb(0xB0BEC5), tracking = 400)

proc collage(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  let g = 0.02
  let c = (1 - 3 * g) / 2
  for j in 0 .. 1:
    for i in 0 .. 1:
      let x = g + i.float * (c + g)
      let y = g + j.float * (c + g)
      p.frame(x, y, x + c, y + c)

proc beforeAfter(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.frame(0, 0, 0.497, 1)
  p.frame(0.503, 0, 1, 1)
  for (x, lab) in [(0.03, "BEFORE"), (0.533, "AFTER")]:
    p.box(lab & " Tag", x, 0.05, x + 0.15, 0.15, solidPaint(0xCC000000'u32), radius = 0.02)
    p.words(lab, x + 0.075, 0.115, 0.045, rgb(0xFFFFFF), bold = true)

proc eidGreeting(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.box("Background", 0, 0, 1, 1, gradientPaint(rgb(0x0B3D2E), rgb(0x14746F), angle = 90))
  # a crescent: a gold moon, a circle of the sky over it
  p.crescent("Moon", 0.5, 0.2, 0.11, rgb(0xE8C468))
  for (x, y, s) in [(0.2, 0.1, 0.022), (0.8, 0.15, 0.028), (0.3, 0.29, 0.016), (0.72, 0.31, 0.02)]:
    p.star("Star", x, y, s, rgb(0xE8C468))
  p.words("عيد مبارك", 0.5, 0.52, 0.17, rgb(0xE8C468), family = "FreeSerif")
  p.words("Eid Mubarak", 0.5, 0.62, 0.075, rgb(0xFFFFFF), bold = true)
  p.words("Wishing you and your family joy, peace and happiness", 0.15, 0.67, 0.038, rgb(0xD8F3DC),
          boxW = 0.7, boxH = 0.1)
  p.words("From all of us", 0.5, 0.9, 0.035, rgb(0xE8C468))

proc qrShape(p: Page; text: string; x0, y0, side: float) =
  ## A QR code (a shape layer, sharp at any size) in a white square: `side`
  ## of the smaller side, its top left at fractions of the page.
  let q = qrEncode(text, qrM)
  let px = p.S(side)
  let cell = px / (q.size + 4).float
  let (ox, oy) = (p.X(x0), p.Y(y0))
  discard p.d.addShapeLayer(ShapeData(path: rectPath(ox, oy, ox + px, oy + px), fill: solidPaint(0xFFFFFFFF'u32),
                                      kind: "Rectangle"), p.say("QR Code Background"))
  var path: Path
  for k, poly in qrPath(q, cell, ox + 2 * cell, oy + 2 * cell):
    var sp = SubPath(closed: true, joined: k > 0)
    for pt in poly: sp.pts.add PathPoint(p: pt, inH: pt, outH: pt)
    path.subs.add sp
  discard p.d.addShapeLayer(ShapeData(path: path, fill: solidPaint(0xFF000000'u32)), p.say("QR Code"))

proc nationalDay(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.box("Background", 0, 0, 1, 1, solidPaint(rgb(0xFFFFFF)))
  # (the flag's colors: a red band down the side, white and green across)
  p.box("Red Band", 0, 0, 0.3, 1, solidPaint(rgb(0xDB161B)))
  p.box("Red Bar", 0.3, 0.44, 1, 0.56, solidPaint(rgb(0xDB161B)))
  p.box("Green Band", 0.3, 0.56, 1, 1, solidPaint(rgb(0x008000)))
  p.words("كل عام وعُمان بخير", 0.65, 0.2, 0.09, rgb(0xDB161B), family = "FreeSerif")
  p.words("Happy National Day", 0.65, 0.3, 0.06, rgb(0x1F2933), bold = true)
  p.words("18 November", 0.65, 0.515, 0.055, rgb(0xFFFFFF), bold = true)
  p.words("From all of us", 0.65, 0.8, 0.04, rgb(0xFFFFFF))
  p.words("Company Name", 0.65, 0.88, 0.035, rgb(0xFFFFFF), bold = true)

proc ramadan(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.box("Background", 0, 0, 1, 1, gradientPaint(rgb(0x2B1055), rgb(0x0B132B), angle = 90))
  p.crescent("Moon", 0.5, 0.24, 0.13, rgb(0xF4D58D))
  for (x, y, s) in [(0.18, 0.12, 0.02), (0.82, 0.1, 0.026), (0.26, 0.34, 0.014), (0.75, 0.33, 0.018),
                    (0.12, 0.5, 0.012), (0.9, 0.46, 0.015)]:
    p.star("Star", x, y, s, rgb(0xF4D58D))
  p.words("رمضان كريم", 0.5, 0.58, 0.17, rgb(0xF4D58D), family = "FreeSerif")
  p.words("Ramadan Kareem", 0.5, 0.67, 0.07, rgb(0xFFFFFF), bold = true)
  p.words("May this blessed month bring you peace, health and happiness", 0.15, 0.72, 0.036, rgb(0xD9D2E9),
          boxW = 0.7, boxH = 0.1)
  p.box("Line", 0.4, 0.86, 0.6, 0.863, solidPaint(rgb(0xF4D58D)))
  p.words("Company Name", 0.5, 0.91, 0.035, rgb(0xF4D58D), bold = true)

proc wifiCard(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.box("Background", 0, 0, 1, 1, solidPaint(rgb(0x0F5C63)))
  p.words("Free Wi-Fi", 0.07, 0.24, 0.1, rgb(0xFFFFFF), bold = true, align = textLeft)
  p.words("Network:", 0.07, 0.48, 0.055, rgb(0xB8E1DD), align = textLeft)
  p.words("Hotel-Guest", 0.07, 0.58, 0.075, rgb(0xFFFFFF), bold = true, align = textLeft)
  p.words("Password:", 0.07, 0.72, 0.055, rgb(0xB8E1DD), align = textLeft)
  p.words("welcome2026", 0.07, 0.82, 0.075, rgb(0xFFFFFF), bold = true, align = textLeft)
  p.qrShape("WIFI:T:WPA;S:Hotel-Guest;P:welcome2026;;", 0.575, 0.12, 0.56)
  p.words("Scan to connect", 0.77, 0.86, 0.045, rgb(0xFFFFFF))

proc hiring(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.box("Background", 0, 0, 1, 1, solidPaint(rgb(0xFFF8EC)))
  p.box("Corner", 0.62, 0, 1, 0.36, solidPaint(rgb(0xF2A541)))
  p.circleFrame(0.78, 0.2, 0.15)
  p.words("WE'RE", 0.07, 0.17, 0.1, rgb(0x14213D), bold = true, align = textLeft)
  p.words("HIRING", 0.07, 0.28, 0.13, rgb(0xE63946), bold = true, align = textLeft)
  p.words("Front Office Agent", 0.07, 0.43, 0.06, rgb(0x14213D), bold = true, align = textLeft)
  p.words("•  Guest service experience\n•  English and Arabic\n•  Team player, positive attitude\n" &
          "•  Shifts and weekends", 0.07, 0.49, 0.042, rgb(0x3E4C59), align = textLeft, boxW = 0.8, boxH = 0.28)
  p.box("Apply Box", 0.07, 0.8, 0.93, 0.92, solidPaint(rgb(0x14213D)), radius = 0.03)
  p.words("Apply: careers@company.com", 0.5, 0.875, 0.045, rgb(0xFFFFFF), bold = true)

proc thankYou(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.box("Paper", 0, 0, 1, 1, solidPaint(rgb(0xFDF8F2)))
  p.box("Border", 0.04, 0.06, 0.96, 0.94, ShapePaint(kind: spNone), stroke = 0.006, strokeColor = rgb(0xC9A227))
  p.words("Thank You", 0.5, 0.42, 0.22, rgb(0x6B4226), family = "FreeSerif")
  p.words("for being part of our story", 0.5, 0.55, 0.06, rgb(0x7B6A58))
  p.box("Line", 0.42, 0.66, 0.58, 0.664, solidPaint(rgb(0xC9A227)))
  p.words("With warm regards,", 0.5, 0.76, 0.05, rgb(0x7B6A58))
  p.words("Your Name", 0.5, 0.85, 0.065, rgb(0x6B4226), family = "FreeSerif")

proc quotePost(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.box("Background", 0, 0, 1, 1, gradientPaint(rgb(0x1D3557), rgb(0x457B9D), angle = 135))
  p.words("“", 0.12, 0.33, 0.35, rgb(0xF1FAEE), family = "FreeSerif", align = textLeft)
  p.words("Quality is never an accident; it is always the result of intelligent effort.", 0.12, 0.36,
          0.065, rgb(0xFFFFFF), bold = true, align = textLeft, boxW = 0.76, boxH = 0.36)
  p.box("Line", 0.12, 0.76, 0.3, 0.765, solidPaint(rgb(0xF2A541)))
  p.words("John Ruskin", 0.12, 0.82, 0.045, rgb(0xF1FAEE), align = textLeft)

proc menuBoard(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.box("Paper", 0, 0, 1, 1, solidPaint(rgb(0x1C1C1C)))
  p.box("Border", 0.04, 0.03, 0.96, 0.97, ShapePaint(kind: spNone), stroke = 0.004, strokeColor = rgb(0xC9A227))
  p.words("MENU", 0.5, 0.11, 0.12, rgb(0xC9A227), bold = true, tracking = 300)
  p.words("Restaurant Name", 0.5, 0.155, 0.035, rgb(0xE8E8E8))
  var y = 0.22
  for (sect, items) in [("Starters", "Lentil Soup  ·  2.500\nFattoush Salad  ·  3.000\nHummus with Bread  ·  2.000"),
                        ("Main Courses", "Grilled Hammour  ·  7.500\nChicken Machboos  ·  6.000\n" &
                                         "Lamb Shuwa  ·  8.500"),
                        ("Desserts", "Omani Halwa  ·  2.000\nKunafa  ·  3.000\nDate Pudding  ·  2.500")]:
    p.words(sect, 0.5, y + 0.03, 0.055, rgb(0xC9A227), bold = true)
    p.box(sect & " Line", 0.3, y + 0.045, 0.7, y + 0.047, solidPaint(rgb(0x6E6E6E)))
    p.words(items, 0.15, y + 0.07, 0.038, rgb(0xF5F5F5), boxW = 0.7, boxH = 0.15)
    y += 0.25

proc welcomeCard(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.box("Paper", 0, 0, 1, 1, solidPaint(rgb(0xFFFFFF)))
  p.box("Side", 0, 0, 0.38, 1, gradientPaint(rgb(0x0F5C63), rgb(0x2A9D8F), angle = 90))
  p.words("أهلاً وسهلاً", 0.19, 0.45, 0.11, rgb(0xFFFFFF), family = "FreeSerif")
  p.words("Welcome", 0.19, 0.58, 0.075, rgb(0xFFFFFF), bold = true)
  p.words("Dear Guest Name,", 0.44, 0.22, 0.065, rgb(0x14213D), bold = true, align = textLeft)
  p.words("It is our pleasure to welcome you. We hope your stay is comfortable and memorable. Please " &
          "let us know if there is anything we can do for you.", 0.44, 0.3, 0.045, rgb(0x3E4C59),
          align = textLeft, boxW = 0.5, boxH = 0.4)
  p.words("Manager Name", 0.44, 0.8, 0.055, rgb(0x14213D), family = "FreeSerif", align = textLeft)
  p.words("General Manager", 0.44, 0.87, 0.04, rgb(0x7B8794), align = textLeft)

# (remixable: their photos in placeholders, their colors and fonts to a Style in one click)

proc productLaunch(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.box("Background", 0, 0, 1, 1, solidPaint(rgb(0xF4EFE6)))
  p.frame(0.07, 0.06, 0.93, 0.62, round = 0.03)
  p.words("NEW", 0.12, 0.13, 0.05, rgb(0xFFFFFF), bold = true, align = textLeft)
  p.words("Product Name", 0.5, 0.71, 0.09, rgb(0x2B2B2B), bold = true)
  p.words("A line about what makes it special", 0.5, 0.765, 0.038, rgb(0x6B6B6B))
  p.box("Price Tag", 0.34, 0.8, 0.66, 0.875, solidPaint(rgb(0xC1440E)), radius = 0.05)
  p.words("OMR 12.500", 0.5, 0.851, 0.045, rgb(0xFFFFFF), bold = true)
  p.words("Order now  ·  www.yourshop.com", 0.5, 0.94, 0.03, rgb(0x2B2B2B))

proc realEstate(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.box("Background", 0, 0, 1, 1, solidPaint(rgb(0xFFFFFF)))
  p.frame(0, 0, 1, 0.58)
  p.frame(0.04, 0.61, 0.33, 0.8)
  p.frame(0.355, 0.61, 0.645, 0.8)
  p.frame(0.67, 0.61, 0.96, 0.8)
  p.box("Banner", 0, 0.5, 0.52, 0.58, solidPaint(rgb(0x0B2545)))
  p.words("FOR SALE", 0.04, 0.555, 0.05, rgb(0xFFFFFF), bold = true, align = textLeft, tracking = 200)
  p.words("Villa in Al Mouj", 0.04, 0.875, 0.06, rgb(0x0B2545), bold = true, align = textLeft)
  p.words("4 Bedrooms  ·  5 Bathrooms  ·  450 m²", 0.04, 0.925, 0.032, rgb(0x5C677D), align = textLeft)
  p.words("OMR 185,000", 0.96, 0.9, 0.05, rgb(0x13315C), bold = true, align = textRight)

proc travelPostcard(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.frame(0, 0, 1, 1)
  var shade = solidPaint(0xFF000000'u32)
  shade.opacity = 30
  p.box("Shade", 0, 0.62, 1, 1, shade)
  p.words("Greetings from", 0.06, 0.76, 0.07, rgb(0xFFFFFF), align = textLeft, family = "FreeSerif")
  p.words("MUSCAT", 0.06, 0.92, 0.2, rgb(0xFFFFFF), bold = true, align = textLeft, tracking = 100)
  p.box("Stamp", 0.82, 0.06, 0.95, 0.27, solidPaint(rgb(0xFFFFFF)), stroke = 0.008, strokeColor = rgb(0xC1440E))
  p.star("Stamp Star", 0.885, 0.165, 0.05, rgb(0xC1440E))

proc magazineCover(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.frame(0, 0, 1, 1)
  p.words("ATELIER", 0.5, 0.12, 0.2, rgb(0xFFFFFF), bold = true, tracking = 80)
  p.words("ISSUE 12  ·  NOVEMBER 2026", 0.5, 0.155, 0.025, rgb(0xFFFFFF), tracking = 300)
  p.words("The Light of the Coast", 0.06, 0.74, 0.07, rgb(0xFFFFFF), bold = true, align = textLeft,
          boxW = 0.55, boxH = 0.14)
  p.words("Ten places to see this winter, and how to photograph them", 0.06, 0.86, 0.032, rgb(0xFFFFFF),
          align = textLeft, boxW = 0.5, boxH = 0.08)
  p.box("Badge", 0.74, 0.62, 0.94, 0.72, solidPaint(rgb(0xE9B44C)), radius = 0.05)
  p.words("SPECIAL", 0.84, 0.68, 0.035, rgb(0x0D0D1A), bold = true)

proc recipeCard(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.box("Paper", 0, 0, 1, 1, solidPaint(rgb(0xFFF9EB)))
  p.frame(0.06, 0.04, 0.94, 0.42, round = 0.04)
  p.words("Saffron Rice Pudding", 0.5, 0.5, 0.075, rgb(0x3A2E1F), bold = true, family = "FreeSerif")
  p.words("Serves 4  ·  40 minutes", 0.5, 0.54, 0.032, rgb(0xC1440E))
  p.words("INGREDIENTS", 0.06, 0.6, 0.032, rgb(0x3A2E1F), bold = true, align = textLeft, tracking = 200)
  p.words("1 cup rice\n4 cups milk\n½ cup sugar\nA pinch of saffron\nCardamom, rose water", 0.06, 0.63,
          0.03, rgb(0x3A2E1F), align = textLeft, boxW = 0.36, boxH = 0.3)
  p.words("METHOD", 0.47, 0.6, 0.032, rgb(0x3A2E1F), bold = true, align = textLeft, tracking = 200)
  p.words("Simmer the rice in the milk until soft. Stir in the sugar, the saffron and the cardamom; cook " &
          "a little more. Finish with rose water and serve warm or cold.", 0.47, 0.63, 0.03, rgb(0x3A2E1F),
          align = textLeft, boxW = 0.47, boxH = 0.3)

proc teamMember(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.box("Background", 0, 0, 1, 1, gradientPaint(rgb(0x1B3A2F), rgb(0x3E6B48), angle = 90))
  p.words("MEET THE TEAM", 0.5, 0.1, 0.05, rgb(0xC9A227), bold = true, tracking = 300)
  p.circle("Ring", 0.5, 0.4, 0.3, ShapePaint(kind: spNone), stroke = 0.012, strokeColor = rgb(0xC9A227))
  p.circleFrame(0.5, 0.4, 0.28)
  p.words("Team Member", 0.5, 0.78, 0.075, rgb(0xFFFFFF), bold = true)
  p.words("Position  ·  Department", 0.5, 0.83, 0.04, rgb(0xF4EFE1))
  p.words("A sentence about what they bring to the team.", 0.5, 0.9, 0.032, rgb(0xF4EFE1))

proc salePost(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.box("Background", 0, 0, 1, 1, solidPaint(rgb(0xEF476F)))
  p.frame(0.5, 0, 1, 1)
  p.words("SALE", 0.25, 0.4, 0.17, rgb(0xFFFFFF), bold = true)
  p.words("50%", 0.25, 0.58, 0.16, rgb(0xFFF6EC), bold = true)
  p.words("OFF EVERYTHING", 0.25, 0.65, 0.04, rgb(0xFFFFFF), tracking = 200)
  p.box("Button", 0.07, 0.72, 0.43, 0.8, solidPaint(rgb(0x073B4C)), radius = 0.04)
  p.words("Shop now", 0.25, 0.775, 0.045, rgb(0xFFFFFF), bold = true)

proc photoStory(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.box("Background", 0, 0, 1, 1, solidPaint(rgb(0xFAFAF7)))
  p.words("A DAY IN NIZWA", 0.5, 0.06, 0.07, rgb(0x111111), bold = true, tracking = 150)
  for k, cap in ["Morning at the souq", "The fort at noon", "Sunset over the date palms"]:
    let y = 0.09 + k.float * 0.3
    p.frame(0.06, y, 0.94, y + 0.24, round = 0.03)
    p.words(cap, 0.06, y + 0.27, 0.035, rgb(0x444444), align = textLeft)

proc weddingInvite(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.box("Paper", 0, 0, 1, 1, solidPaint(rgb(0xF8F5FF)))
  p.box("Border", 0.04, 0.03, 0.96, 0.97, ShapePaint(kind: spNone), stroke = 0.006, strokeColor = rgb(0x6C5B9E))
  p.circleFrame(0.5, 0.27, 0.22)
  p.words("Together with their families", 0.5, 0.53, 0.035, rgb(0x6C5B9E), family = "FreeSerif")
  p.words("Name & Name", 0.5, 0.63, 0.1, rgb(0x2D2342), family = "FreeSerif")
  p.words("invite you to celebrate their wedding", 0.5, 0.69, 0.035, rgb(0x6C5B9E), family = "FreeSerif")
  p.box("Line", 0.35, 0.73, 0.65, 0.732, solidPaint(rgb(0xC7B8EA)))
  p.words("THURSDAY 18 DECEMBER 2026  ·  7 PM", 0.5, 0.79, 0.032, rgb(0x2D2342), tracking = 150)
  p.words("The Venue, Muscat", 0.5, 0.84, 0.032, rgb(0x2D2342))

proc portfolioPage(d: Doc; say: proc (s: string): string) =
  let p = Page(d: d, say: say)
  p.box("Background", 0, 0, 1, 1, solidPaint(rgb(0x1E252B)))
  p.words("Your Name", 0.05, 0.12, 0.08, rgb(0xFFFFFF), bold = true, align = textLeft)
  p.words("Photographer  ·  Designer", 0.05, 0.18, 0.035, rgb(0xB5E61D), align = textLeft)
  for j in 0 .. 1:
    for i in 0 .. 2:
      let x = 0.05 + i.float * 0.31
      let y = 0.25 + j.float * 0.36
      p.frame(x, y, x + 0.28, y + 0.33)
  p.words("www.yoursite.com", 0.95, 0.12, 0.03, rgb(0xF4F6F7), align = textRight)

proc tmpl(name: string; c: PresetCategory; w, h, dpi: int;
          build: proc (d: Doc; say: proc (s: string): string)): DocTemplate =
  DocTemplate(name: name, category: c, w: w, h: h, dpi: dpi, build: build)

proc docTemplates*(): seq[DocTemplate] =
  ## Every built-in template.
  @[tmpl("Event Flyer", pcPrint, mmPx(148, 300), mmPx(210, 300), 300, eventFlyer),
    tmpl("Employee of the Month", pcPrint, mmPx(210, 300), mmPx(297, 300), 300, employeeOfMonth),
    tmpl("Certificate", pcPrint, mmPx(297, 300), mmPx(210, 300), 300, certificate),
    tmpl("Staff Notice", pcPrint, mmPx(210, 300), mmPx(297, 300), 300, staffNotice),
    tmpl("Business Card", pcPrint, mmPx(85, 300), mmPx(55, 300), 300, businessCard),
    tmpl("Announcement Post", pcSocial, 1080, 1080, 72, instagramAnnouncement),
    tmpl("Event Story", pcSocial, 1080, 1920, 72, storyEvent),
    tmpl("Eid Greeting", pcSocial, 1080, 1350, 72, eidGreeting),
    tmpl("Facebook Cover", pcSocial, 1640, 624, 72, facebookCover),
    tmpl("YouTube Thumbnail", pcSocial, 1280, 720, 72, youtubeThumbnail),
    tmpl("Photo Collage", pcPhoto, 2400, 2400, 300, collage),
    tmpl("Before and After", pcPhoto, 2400, 1200, 300, beforeAfter),
    tmpl("Eid Greeting", pcArt, 1080, 1350, 72, eidGreeting),
    tmpl("Title Card", pcFilm, 1920, 1080, 72, titleCard),
    tmpl("National Day Greeting", pcSocial, 1080, 1350, 72, nationalDay),
    tmpl("Ramadan Kareem", pcSocial, 1080, 1350, 72, ramadan),
    tmpl("We're Hiring", pcSocial, 1080, 1080, 72, hiring),
    tmpl("Quote Post", pcSocial, 1080, 1080, 72, quotePost),
    tmpl("Wi-Fi Card", pcPrint, mmPx(148, 300), mmPx(105, 300), 300, wifiCard),
    tmpl("Thank You Card", pcPrint, mmPx(148, 300), mmPx(105, 300), 300, thankYou),
    tmpl("Restaurant Menu", pcPrint, mmPx(210, 300), mmPx(297, 300), 300, menuBoard),
    tmpl("Welcome Card", pcPrint, mmPx(210, 300), mmPx(148, 300), 300, welcomeCard),
    tmpl("Web Banner", pcWeb, 1640, 624, 72, facebookCover),
    tmpl("Product Launch", pcSocial, 1080, 1350, 72, productLaunch),
    tmpl("Real Estate Listing", pcSocial, 1080, 1080, 72, realEstate),
    tmpl("Sale Post", pcSocial, 1080, 1080, 72, salePost),
    tmpl("Team Member", pcSocial, 1080, 1350, 72, teamMember),
    tmpl("Photo Story", pcSocial, 1080, 1920, 72, photoStory),
    tmpl("Travel Postcard", pcPrint, mmPx(148, 300), mmPx(105, 300), 300, travelPostcard),
    tmpl("Magazine Cover", pcPrint, mmPx(210, 300), mmPx(297, 300), 300, magazineCover),
    tmpl("Recipe Card", pcPrint, mmPx(148, 300), mmPx(210, 300), 300, recipeCard),
    tmpl("Wedding Invitation", pcPrint, 1500, 2100, 300, weddingInvite),
    tmpl("Portfolio Page", pcWeb, 1920, 1080, 72, portfolioPage)]

proc templatesOf*(c: PresetCategory): seq[DocTemplate] =
  ## The templates of a tab.
  for t in docTemplates():
    if t.category == c: result.add t

proc buildTemplate*(t: DocTemplate; scale = 1.0; say: proc (s: string): string = nil; name = ""): Doc =
  ## The template made: a document with its layers (type, shapes, frames),
  ## at its size times `scale`; `say` translates its words (nil: as they
  ## are). Its history starts empty.
  proc same(s: string): string = s
  let say = if say != nil: say else: same
  let w = max(1, int(round(t.w.float * scale)))
  let h = max(1, int(round(t.h.float * scale)))
  result = newDoc(w, h, 0xFFFFFFFF'u32, t.dpi.float * scale, if name.len > 0: name else: t.name)
  t.build(result, say)
  result.cur = result.layers.high
  result.markAll()
  result.modified = false

proc templateThumb*(t: DocTemplate; side: int; say: proc (s: string): string = nil): Bitmap =
  ## A picture of the template, its longer side `side` pixels (made at that
  ## size, so it is quick).
  let k = side.float / max(t.w, t.h).float
  let d = buildTemplate(t, k, say)
  d.updateComposite()
  let px = d.compCopy
  result = newBitmap(d.w, d.h)
  for i in 0 ..< min(px.len, result.px.len):
    result.px[i] = blendPx(0xFFFFFFFF'u32, px[i], 255, bmNormal)
  result.changed()

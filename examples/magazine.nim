## Retro Photo's sample magazine: three A4 pages made with Retro Photo's
## own engine, tool by tool, as the app's tools make them -- the Gradient
## tool, Render > Clouds and Lens Flare, Add Noise, shape layers from the
## Rectangle, Ellipse, Star, Spiral, Line and Pen tools (with Path
## Operations), type layers (point and paragraph type, Arabic set right to
## left), layer styles, layer masks, clipping masks, blend modes, a placed
## Smart Object, adjustment layers and a Neural Filter -- then saved as
## Retro Photo documents (.rpd: every layer still editable in the app) and
## exported with File > Automate > PDF Presentation, type and shapes as
## outlines, the rest as pictures.
##
##   nim c -r -d:release examples/magazine.nim [output folder]
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, math]
import retroui/[gfx, photo, photopaint, photofx, photoshapes, photovector,
              photowarp, photoneural, photopdf, photofiles, textengine]

const
  W = 1240                 # A4 at 150 pixels an inch
  H = 1754
  # the issue's colors
  night = 0xFF140B34'u32
  plum = 0xFF2B1055'u32
  magenta = 0xFFD7268B'u32
  pink = 0xFFFF3EA5'u32
  orange = 0xFFFF7A3D'u32
  sun = 0xFFFFD23F'u32
  cyan = 0xFF2EE6E6'u32
  paper = 0xFFFBF6EE'u32
  ink = 0xFF1A1423'u32
  gray = 0xFF7D6E86'u32
  white = 0xFFFFFFFF'u32

let here = currentSourcePath().parentDir
let outDir = if paramCount() >= 1: paramStr(1) else: getCurrentDir() / "magazine"
createDir(outDir)

# ---- what the tools do ---------------------------------------------------------------------

proc stops(cs: openArray[(float, uint32)]): seq[GradientStop] =
  for (at, c) in cs: result.add GradientStop(at: at, color: c)

proc chars(family, style: string; size: float; color: uint32; tracking = 0; leading = 0.0): CharStyle =
  ## (the Character palette)
  CharStyle(family: family, style: style, size: size.float32, color: color, tracking: tracking,
            leading: leading.float32, hScale: 1, vScale: 1)

proc typeTool(d: Doc; s: string; c: CharStyle; x, y: float; align = textLeft; name = "";
              rtl = 0): Layer =
  ## The Type tool, a click: point type, its first line's baseline at `y`
  ## (`x`: where it starts, ends or its middle, by `align`).
  var t = newText(s, c, x.float32, y.float32)
  t.para.align = align
  t.para.rtl = rtl
  result = d.addTextLayer(t)
  if name.len > 0: result.name = name

proc typeBox(d: Doc; spans: openArray[(string, CharStyle)]; x, y, w, h: float; align = justifyLeft;
             name = ""; rtl = 0; spaceAfter = 0.0): Layer =
  ## The Type tool, a box dragged: paragraph type wrapped in it.
  var t = TextData(x: x.float32, y: y.float32, boxW: w.float32, boxH: h.float32, antialias: true)
  for (s, c) in spans: t.spans.add TextSpan(text: s, style: c)
  t.para.align = align
  t.para.rtl = rtl
  t.para.spaceAfter = spaceAfter.float32
  result = d.addTextLayer(t)
  if name.len > 0: result.name = name

proc centered(d: Doc; L: Layer; cx: float) =
  ## (the Move tool with Align Horizontal Centers)
  let b = L.textBounds
  if b.w <= 0: return
  var t = L.text
  t.x += float32(cx - (b.x.float + b.w / 2))
  d.setText(L, t)

proc shapeTool(d: Doc; p: Path; fill: ShapePaint; name: string; stroke = ShapePaint(kind: spNone);
               width = 0.0; kind = ""): Layer =
  ## The Rectangle / Ellipse / Polygon / Line / Pen tools in Shape mode.
  d.addShapeLayer(ShapeData(path: p, fill: fill, stroke: stroke, strokeWidth: width, align: saCenter,
                            kind: kind), name)

proc gradientPaint(cs: openArray[(float, uint32)]; angle = 90; style = 0): ShapePaint =
  ShapePaint(kind: spGradient, stops: stops(cs), angle: angle, style: style)

proc penPath(pts: openArray[(float, float)]; closed = true): Path =
  ## The Pen tool, clicks: corner points.
  var sp = SubPath(closed: closed)
  for p in pts: sp.pts.add PathPoint(p: p, inH: p, outH: p)
  Path(subs: @[sp])

proc gradientTool(d: Doc; x0, y0, x1, y1: float; cs: openArray[(float, uint32)]; kind = gkLinear) =
  ## The Gradient tool, dragged on the current layer (or its mask).
  d.gradientFill(x0, y0, x1, y1, PaintOpts(opacity: 100, mode: bmNormal, color: white, bg: 0xFF000000'u32),
                 stops(cs), kind)

proc filter(d: Doc; f: FilterFn; margin = 0) =
  ## Filter > ... on the current layer.
  d.applyFilter(margin, f)
  d.markAll()

proc style(L: Layer; k: FxKind; e: Effect) =
  ## Layer > Layer Style > ...
  var e = e
  e.on = true
  L.fx.fx[k] = e

proc dropShadow(L: Layer; color = 0xFF000000'u32; opacity = 50; distance = 8; size = 12; angle = 120;
                spread = 0) =
  L.style(fxDropShadow, Effect(mode: bmMultiply, opacity: opacity, color: color, angle: angle,
                               distance: distance, size: size, spread: spread))

proc outerGlow(L: Layer; color: uint32; opacity = 75; size = 30; spread = 0) =
  L.style(fxOuterGlow, Effect(mode: bmScreen, opacity: opacity, color: color, size: size, spread: spread))

proc gradientOverlay(L: Layer; c0, c1: uint32; angle = 90; opacity = 100) =
  L.style(fxGradientOverlay, Effect(mode: bmNormal, opacity: opacity, color: c0, color2: c1, angle: angle,
                                    scale: 100))

proc strokeFx(L: Layer; color: uint32; size = 3; inside = false; opacity = 100) =
  L.style(fxStroke, Effect(mode: bmNormal, opacity: opacity, color: color, size: size,
                           style: (if inside: 1 else: 0)))

proc newLayerFilled(d: Doc; name: string; c: uint32): Layer =
  ## Layer > New > Layer, then Edit > Fill.
  result = d.addLayer(name)
  for p in result.px.mitems: p = c
  inc result.ver

proc placeEmbedded(d: Doc; src: Doc; r: Rect; name: string; file = ""): Layer =
  ## File > Place Embedded: a Smart Object, scaled to cover `r`.
  let px = src.flattened()
  let k = max(r.w / src.w, r.h / src.h)
  let w = src.w.float * k
  let h = src.h.float * k
  let x = r.x.float + (r.w.float - w) / 2
  let y = r.y.float + (r.h.float - h) / 2
  result = d.newLayer(name)
  result.smart = SmartData(src: px, w: src.w, h: src.h, name: (if file.len > 0: file else: name & ".rpd"),
                           quad: [(x, y), (x + w, y), (x + w, y + h), (x, y + h)])
  d.insertLayer(result)
  result.px = renderSmart(result.smart, d.w, d.h)
  inc result.ver

proc placeEmbedded(d: Doc; path: string; r: Rect; name = ""): Layer =
  ## File > Place Embedded, a picture file.
  d.placeEmbedded(openPicture(path), r, if name.len > 0: name else: path.splitFile.name, path.extractFilename)

proc brushTool(d: Doc; pts: openArray[(float, float)]; color: uint32; size: int; soft = true;
               dyn = BrushDynamics(); opacity = 100) =
  ## The Brush tool, dragged through `pts` on the current layer.
  if pts.len == 0: return
  d.beginStep("Brush Tool")
  let o = PaintOpts(tool: tkBrush, color: color, bg: white, opacity: opacity, mode: bmNormal, dyn: dyn)
  var s = d.beginStroke(o, if soft: softTip(size) else: hardTip(size), pts[0][0], pts[0][1])
  for i in 1 ..< pts.len: s.strokeTo(pts[i][0], pts[i][1])
  s.endStroke()
  d.endStep()

proc clipToBelow(d: Doc; L: Layer) =
  ## Layer > Create Clipping Mask.
  L.clipped = true
  d.markAll()

proc rule(d: Doc; x0, y0, x1: float; color: uint32; weight = 2.0; name = "Rule"): Layer =
  ## The Line tool.
  d.shapeTool(linePath(x0, y0, x1, y0, weight), solidPaint(color), name, kind = "Line")

# ---- page 1: the cover --------------------------------------------------------------------------

proc cover(): Doc =
  let d = newDoc(W, H, night, dpi = 150, name = "Retro 04 - Cover")
  d.info.title = "RETRO No. 04 - Cover"
  let horizon = 1000.0
  # the sky: the Gradient tool on the Background
  d.cur = 0
  d.gradientTool(0, 0, 0, horizon, [(0.0, night), (0.34, 0xFF3A1268'u32), (0.66, 0xFFB0206E'u32),
                                    (0.86, 0xFFFF6A3D'u32), (1.0, 0xFFFFC56B'u32)])
  # stars: an Ellipse tool shape of many small circles
  var stars: Path
  var seed = 7'u32
  proc rnd(): float =
    seed = seed * 1664525'u32 + 1013904223'u32
    float(seed shr 8) / float(1 shl 24)
  for i in 0 ..< 90:
    let x = rnd() * W.float
    let y = rnd() * 560.0
    let r = 0.8 + rnd() * 2.2
    stars.subs.add ellipsePath(x - r, y - r, x + r, y + r).subs[0]
  let st = d.shapeTool(stars, solidPaint(white), "Stars", kind = "Ellipse")
  st.opacity = 80
  st.outerGlow(white, 60, 6)
  # clouds: Filter > Render > Clouds on a layer of their own, Screen, faded out
  # toward the horizon by a gradient on its mask
  let cl = d.newLayerFilled("Clouds", 0xFF000000'u32)
  d.filter(clouds(0xFFFFFFFF'u32, 0xFF000000'u32, seed = 4))
  cl.mode = bmScreen
  cl.opacity = 28
  d.addLayerMask(mfRevealAll)
  d.editMask = true
  d.gradientTool(0, 120, 0, horizon - 140, [(0.0, white), (1.0, 0xFF000000'u32)])
  d.editMask = false
  # the sun: an Ellipse with its slats cut out (Path Operations: Subtract)
  var sunPath = ellipsePath(620 - 290, 520, 620 + 290, 1100)
  var y = 800.0
  var gap = 6.0
  while y < 1100:
    var bar = rectPath(300, y, 940, y + gap).subs[0]
    bar.op = poSubtract
    sunPath.subs.add bar
    y += gap + 22 - gap * 0.6
    gap += 4.5
  let sn = d.shapeTool(sunPath, gradientPaint([(0.0, 0xFFFFE45C'u32), (0.55, 0xFFFF9A3D'u32),
                                               (1.0, 0xFFFF3E7F'u32)], angle = -90), "Sun", kind = "Ellipse")
  sn.outerGlow(0xFFFF8A3D'u32, 70, 90, 5)
  # a flare where the light is strongest: Filter > Render > Lens Flare, Screen
  let fl = d.newLayerFilled("Lens Flare", 0xFF000000'u32)
  d.filter(lensFlare(620, 560, 95))
  fl.mode = bmScreen
  fl.opacity = 55
  # the mountains: the Pen tool, then a gradient overlay
  let far = d.shapeTool(penPath([(0.0, horizon), (0.0, 905), (90, 870), (170, 912), (260, 842), (330, 880),
                                 (420, 806), (520, 890), (600, 858), (700, 915), (790, 838), (880, 884),
                                 (980, 820), (1080, 896), (1160, 856), (1240, 884), (1240, horizon)]),
                        solidPaint(0xFF4A2370'u32), "Far Mountains")
  far.gradientOverlay(0xFF7A3BA8'u32, 0xFF2B1055'u32, angle = -90)
  let near = d.shapeTool(penPath([(0.0, horizon), (0.0, 950), (120, 930), (210, 962), (330, 912),
                                  (460, 968), (560, 948), (680, 975), (800, 930), (930, 966), (1050, 925),
                                  (1160, 958), (1240, 940), (1240, horizon)]),
                         solidPaint(0xFF1E0B3A'u32), "Near Mountains")
  near.strokeFx(0xFFFF3EA5'u32, 2, opacity = 70)
  # the floor and its grid: a Rectangle with a gradient, then Line tool lines
  discard d.shapeTool(rectPath(0, horizon, W.float, H.float),
                      gradientPaint([(0.0, 0xFF2B0F4F'u32), (1.0, 0xFF07031A'u32)], angle = -90), "Floor",
                      kind = "Rectangle")
  var grid: Path
  var k = 0.0
  while true:
    let gy = horizon + 6 + k * k * 9
    if gy > H.float: break
    grid.subs.add linePath(0, gy, W.float, gy, 1.5 + k * 0.25).subs
    k += 1
  for i in -16 .. 16:
    let bx = 620 + i.float * 150
    grid.subs.add linePath(620 + i.float * 6, horizon + 2, bx, H.float + 40, 1.6 + abs(i).float * 0.06).subs
  let gr = d.shapeTool(grid, solidPaint(pink), "Grid", kind = "Line")
  gr.opacity = 80
  gr.outerGlow(pink, 80, 14)
  # (the floor fades into the haze at the horizon: a gradient on the grid's mask)
  d.addLayerMask(mfRevealAll)
  d.editMask = true
  d.gradientTool(0, horizon, 0, horizon + 260, [(0.0, 0xFF000000'u32), (1.0, white)])
  d.editMask = false
  # the masthead: point type, a gradient overlay, a hard shadow
  let tag = d.typeTool("THE MAGAZINE OF PIXELS, TYPE & TOOLS", chars("Poppins", "Medium", 22, sun, 380),
                       620, 74, textCenter, "Tagline")
  d.centered(tag, 620)
  let mast = d.typeTool("RETRO", chars("Poppins", "Bold", 300, white, 30), 620, 330, textCenter, "Masthead")
  d.centered(mast, 620)
  mast.gradientOverlay(0xFF7DF9FF'u32, 0xFFFF6BC1'u32, angle = -90)
  mast.strokeFx(white, 3, inside = true, opacity = 70)
  mast.dropShadow(0xFF07031A'u32, 85, 12, 0, 135)
  discard d.rule(70, 386, 1170, 0x99FFFFFF'u32, 2, "Masthead Rule")
  discard d.typeTool("No. 04  ·  AUTUMN 2026", chars("Poppins", "Medium", 22, white, 200), 70, 420, name = "Issue")
  discard d.typeTool("€ 6.50", chars("Poppins", "Medium", 22, white, 200), 1170, 420, textRight, "Price")
  # the badge: the Star tool, type over it
  let badge = d.shapeTool(starPath(905, 470, 1145, 710, 18, 14), solidPaint(sun), "Badge", kind = "Star")
  badge.dropShadow(0xFF07031A'u32, 60, 8, 10)
  let b1 = d.typeTool("NEW", chars("Poppins", "Bold", 46, plum, 60), 1025, 585, textCenter, "Badge: NEW")
  d.centered(b1, 1025)
  let b2 = d.typeTool("ISSUE 04", chars("Poppins", "Medium", 22, plum, 160), 1025, 622, textCenter,
                      "Badge: Issue")
  d.centered(b2, 1025)
  # the cover lines, over the floor (a dark gradient under them to read them by)
  discard d.shapeTool(rectPath(0, 1080, W.float, 1640),
                      gradientPaint([(0.0, 0x0007031A'u32), (0.45, 0x9907031A'u32), (1.0, 0xCC07031A'u32)],
                                    angle = -90), "Cover Lines Shade", kind = "Rectangle")
  let h1 = d.typeBox([("THE PIXEL\nREVIVAL", chars("Poppins", "Bold", 92, white, 10, 92))],
                     70, 1140, 640, 220, textLeft, "Cover Line: Headline")
  h1.dropShadow(0xFF07031A'u32, 80, 6, 0)
  h1.gradientOverlay(white, 0xFFFFC2E6'u32, angle = -90)
  discard d.typeBox([("Why the interfaces of 1994 are back on every screen — and what their " &
                      "bevels still teach us.", chars("Lora", "Italic", 30, 0xFFFFE6F2'u32, 0, 40))],
                    72, 1352, 560, 140, textLeft, "Cover Line: Deck")
  discard d.typeBox([("40 TOOLS,\nONE TINY APP", chars("Poppins", "Bold", 50, sun, 20, 54))],
                    760, 1150, 410, 130, textRight, "Cover Line 2")
  discard d.typeBox([("Inside Retro Photo 4.0: layers, styles, type and print-ready PDF",
                      chars("Lora", "Italic", 26, white, 0, 34))],
                    760, 1270, 410, 100, textRight, "Cover Line 2: Deck")
  discard d.rule(900, 1395, 1170, cyan, 3, "Cover Rule")
  discard d.typeBox([("Arabic type on the canvas", chars("Poppins", "Medium", 30, white, 0, 36))],
                    760, 1415, 410, 50, textRight, "Cover Line 3")
  discard d.typeTool("الحرف العربي على اللوحة", chars("FreeSerif", "Bold", 40, cyan), 1170, 1508,
                     textLeft, "Cover Line 3: Arabic", rtl = 2)
  # the strip at the foot: a Rectangle, the barcode of Rectangles, small type
  let strip = d.shapeTool(rectPath(0, 1640, W.float, H.float), solidPaint(0xE607031A'u32), "Foot",
                          kind = "Rectangle")
  discard strip
  var bars: Path
  var bx = 1000.0
  var s2 = 3'u32
  while bx < 1170:
    s2 = s2 * 1103515245'u32 + 12345'u32
    let bw = 1.5 + float((s2 shr 16) mod 4) * 1.6
    bars.subs.add rectPath(bx, 1662, bx + bw, 1722).subs
    bx += bw + 1.5 + float((s2 shr 20) mod 3) * 1.6
  discard d.shapeTool(rectPath(990, 1654, 1180, 1742), solidPaint(white), "Barcode Label", kind = "Rectangle")
  discard d.shapeTool(bars, solidPaint(ink), "Barcode", kind = "Rectangle")
  discard d.typeTool("RETRO  ·  THE MAGAZINE OF THE RETRO NIM UI TOOLKIT  ·  MADE IN RETRO PHOTO",
                     chars("Poppins", "Medium", 16, 0xFFBFB3D9'u32, 160), 70, 1704, name = "Foot Line")
  # film grain: Add Noise on a gray layer, Overlay
  let grain = d.newLayerFilled("Grain", 0xFF808080'u32)
  d.filter(addNoise(14, true, mono = true, seed = 9))
  grain.mode = bmOverlay
  grain.opacity = 22
  d.markAll()
  d

# ---- the picture of the feature: painted -------------------------------------------------------

proc scene(): Doc =
  ## A valley at sunset with a figure in red, painted: the Gradient tool,
  ## Clouds, the Pen tool's hills, the Brush tool's grass, shapes.
  let w = 1100
  let h = 670
  let d = newDoc(w, h, white, dpi = 150, name = "Scene")
  d.cur = 0
  d.gradientTool(0, 0, 0, 470, [(0.0, 0xFF241A5A'u32), (0.45, 0xFF7B2C8C'u32), (0.75, 0xFFE8608A'u32),
                                (1.0, 0xFFFFC27A'u32)])
  let cl = d.newLayerFilled("Clouds", 0xFF000000'u32)
  d.filter(clouds(0xFFFFE2F0'u32, 0xFF000000'u32, seed = 11))
  cl.mode = bmScreen
  cl.opacity = 40
  d.addLayerMask(mfRevealAll)
  d.editMask = true
  d.gradientTool(0, 60, 0, 430, [(0.0, white), (1.0, 0xFF000000'u32)])
  d.editMask = false
  let sn = d.shapeTool(ellipsePath(640, 300, 820, 480), solidPaint(0xFFFFE6A0'u32), "Sun", kind = "Ellipse")
  sn.outerGlow(0xFFFFB070'u32, 85, 70, 10)
  var far = penPath([(0.0, 470.0), (0, 380), (140, 330), (260, 372), (380, 300), (520, 368), (660, 320),
                     (780, 386), (900, 330), (1020, 370), (1100, 344), (1100, 470)])
  smoothThrough(far.subs[0], @[true, true, false, false, false, false, false, false, false, false, false, true])
  let fh = d.shapeTool(far, gradientPaint([(0.0, 0xFF6A4C9C'u32), (1.0, 0xFF3B2A6B'u32)], angle = -90),
                       "Far Hills")
  discard fh
  var near = penPath([(0.0, 670.0), (0, 470), (180, 430), (360, 476), (560, 440), (760, 486), (940, 446),
                      (1100, 470), (1100, 670)])
  smoothThrough(near.subs[0], @[true, true, false, false, false, false, false, false, true])
  discard d.shapeTool(near, gradientPaint([(0.0, 0xFF2F6E62'u32), (1.0, 0xFF153D3A'u32)], angle = -90),
                      "Valley")
  # grass: the Brush tool with scattering and size jitter
  discard d.addLayer("Grass")
  for row in 0 .. 5:
    var pts: seq[(float, float)]
    for x in countup(-20, w + 20, 40): pts.add (x.float, 520.0 + row.float * 28 + sin(x.float / 90) * 8)
    d.brushTool(pts, (if row mod 2 == 0: 0xFF1F5A4E'u32 else: 0xFF3E8A6A'u32), 10 + row * 2,
                dyn = BrushDynamics(scatter: 140, sizeJitter: 70, count: 2, opacityJitter: 40), opacity = 70)
  # the figure: shapes (the Pen tool's coat, the Ellipse tool's head)
  let fx = 230.0          # (the figure's place: under the sun)
  discard d.shapeTool(penPath([(468.0 + fx, 590.0), (486 + fx, 470), (514 + fx, 450), (546 + fx, 450),
                               (574 + fx, 470), (592 + fx, 590)]),
                      gradientPaint([(0.0, 0xFFE0303A'u32), (1.0, 0xFF9C1426'u32)], angle = -90), "Coat")
  discard d.shapeTool(rectPath(496 + fx, 588, 520 + fx, 640), solidPaint(0xFF1A1423'u32), "Leg L",
                      kind = "Rectangle")
  discard d.shapeTool(rectPath(540 + fx, 588, 564 + fx, 640), solidPaint(0xFF1A1423'u32), "Leg R",
                      kind = "Rectangle")
  discard d.shapeTool(ellipsePath(508 + fx, 400, 552 + fx, 452), solidPaint(0xFFE9B48E'u32), "Head",
                      kind = "Ellipse")
  discard d.shapeTool(ellipsePath(504 + fx, 394, 556 + fx, 428), solidPaint(0xFF3A2216'u32), "Hair",
                      kind = "Ellipse")
  # birds: the Pen tool, open paths stroked
  var birds: Path
  for (bx, by, s) in [(300.0, 200.0, 18.0), (340.0, 180.0, 13.0), (372.0, 214.0, 10.0)]:
    var sp = SubPath(closed: false)
    for p in [(bx - s, by - s * 0.5), (bx, by), (bx + s, by - s * 0.5)]:
      sp.pts.add PathPoint(p: p, inH: p, outH: p)
    birds.subs.add sp
  discard d.shapeTool(birds, ShapePaint(kind: spNone), "Birds", solidPaint(0xFF2A1A40'u32), 3)
  d.clearHistory()
  d

# ---- page 2: the feature ------------------------------------------------------------------------

const bodyText = [
  "THIRTY YEARS AGO a button looked like a button. It had a light edge on top, a dark edge " &
    "below, and when you pressed it, it sank. Nobody had to explain it. Today that small " &
    "piece of honesty is back — in indie games, in music software, in the photo editor that " &
    "made this page.",
  "The revival is not only nostalgia. Designers who grew up with flat, borderless screens " &
    "describe the old interfaces as calm: every control sits in its place, every window has an " &
    "edge, and the whole program fits in your head. Constraints that were once technical — " &
    "sixteen colors, one font, a screen of 640 by 480 — have become a style.",
  "Retro Photo takes that style seriously. Its toolbox, dialogs and palettes are drawn the way " &
    "a 1994 desktop drew them, pixel for pixel, while the engine underneath does what a " &
    "designer expects today: layers and groups, styles, masks, Smart Objects, adjustment " &
    "layers, type that wraps and sets Arabic from right to left, and PDF for the press.",
  "Every element of this issue was built that way. The cover's sunset is the Gradient tool, " &
    "its clouds Render > Clouds on a Screen layer faded by its mask; the sun is an Ellipse " &
    "with its slats cut by Path Operations, the grid a Line shape with an Outer Glow.",
  "What surprises people most is how small it all is: one app that starts in a moment and " &
    "runs the same on a laptop and an Android tablet. The files stay yours — open the layered " &
    "document, change a word, export again.",
  "Will bevels replace glass and blur? Probably not. But a tool you understand at a glance " &
    "is a tool you can get lost in for hours — in the good way."]

proc feature(): Doc =
  let d = newDoc(W, H, paper, dpi = 150, name = "Retro 04 - Feature")
  # the picture: a rounded Rectangle, a Smart Object placed and clipped to it,
  # an adjustment and a gradient clipped too
  let frame = d.shapeTool(rectPath(70, 70, 1170, 700, 22), solidPaint(ink), "Picture Frame",
                          kind = "Rounded Rectangle")
  frame.dropShadow(0xFF3A2440'u32, 35, 10, 24)
  let pic = d.placeEmbedded(scene(), rect(70, 70, 1100, 630), "Scene")
  d.clipToBelow(pic)
  # Filter > Neural Filters > Harmonization: the scene's colors toward the issue's
  d.filter(harmonize(d, pic, 45, 0, 10))
  let warm = d.newAdjustmentLayer(Adjustment(kind: "Photo Filter", args: @[255.0, 120, 40, 18, 1]),
                                  "Photo Filter")
  d.clipToBelow(warm)
  let shade = d.shapeTool(rectPath(70, 430, 1170, 700),
                          gradientPaint([(0.0, 0x00000000'u32), (1.0, 0xC0140B34'u32)], angle = -90),
                          "Caption Shade", kind = "Rectangle")
  d.clipToBelow(shade)
  discard d.typeBox([("Painted pixels: a valley, a cloud bank and a figure in red, made in Retro " &
                      "Photo with the Brush, Gradient and Pen tools.", chars("Lora", "Italic", 21, white, 0, 30))],
                    100, 600, 470, 90, textLeft, "Caption")
  # the head of the story; each part under the one before (as far down as its type goes)
  discard d.typeTool("FEATURE  ·  DESIGN", chars("Poppins", "Bold", 20, magenta, 300), 70, 768, name = "Kicker")
  discard d.typeTool("The Pixel Revival", chars("Poppins", "Bold", 104, ink, -10), 64, 876, name = "Headline")
  let deck = d.typeBox([("Thirty years after the bevelled button, the interfaces of 1994 are winning hearts " &
                         "again. We asked designers, developers and one very small photo editor why.",
                         chars("Lora", "Italic", 31, 0xFF4E3F59'u32, 0, 42))],
                       70, 902, 1100, 140, textLeft, "Deck")
  var y = deck.textBounds.y.float + deck.textBounds.h.float + 34
  discard d.typeTool("BY THE RETRO DESK   ·   6 MIN READ", chars("Poppins", "Medium", 16, gray, 220), 70, y,
                     name = "Byline")
  discard d.rule(70, y + 18, 1170, ink, 2)
  let top = y + 44
  # the body: paragraph type in two columns, the first words set off
  let body = chars("Lora", "Regular", 19, 0xFF2A2230'u32, 0, 29)
  let lead = chars("Poppins", "Bold", 17, magenta, 80, 29)
  let col1 = @[("THIRTY YEARS AGO", lead), (bodyText[0][16 .. ^1] & "\n" & bodyText[1] & "\n" & bodyText[2], body)]
  discard d.typeBox(col1, 70, top, 520, 1650 - top, justifyLeft, "Body: Column 1", spaceAfter = 10)
  let c2 = d.typeBox(@[(bodyText[3], body)], 650, top, 520, 300, justifyLeft, "Body: Column 2")
  # the pull quote: a Rectangle, a bar, type
  y = c2.textBounds.y.float + c2.textBounds.h.float + 26
  let q = d.typeBox([("“Constraints that were once technical have become a style.”",
                      chars("Poppins", "Medium Italic", 27, ink, 0, 36))], 682, y + 20, 470, 110, textLeft,
                    "Pull Quote")
  let qb = q.textBounds.y.float + q.textBounds.h.float + 22
  discard d.shapeTool(rectPath(650, y, 1170, qb), solidPaint(0xFFF6E2EC'u32), "Quote Box", kind = "Rectangle")
  d.moveLayer(d.cur, d.cur - 1)            # (Arrange > Send Backward: under the quote)
  discard d.shapeTool(rectPath(650, y, 658, qb), solidPaint(magenta), "Quote Bar", kind = "Rectangle")
  discard d.typeBox(@[(bodyText[4] & "\n" & bodyText[5], body)], 650, qb + 22, 520, 1650 - qb - 22, justifyLeft,
                    "Body: Column 2 (cont.)", spaceAfter = 10)
  # the folio
  discard d.rule(70, 1676, 1170, 0xFFD9CCD6'u32, 1.5, "Folio Rule")
  discard d.typeTool("02", chars("Poppins", "Bold", 18, magenta), 70, 1708, name = "Folio: Page")
  discard d.typeTool("RETRO  ·  AUTUMN 2026", chars("Poppins", "Medium", 14, gray, 220), 1170, 1706, textRight,
                     "Folio")
  d.markAll()
  d

# ---- page 3: Arabic, numbers, and an advertisement --------------------------------------------

proc arabicAndNumbers(): Doc =
  let d = newDoc(W, H, night, dpi = 150, name = "Retro 04 - Arabic & Numbers")
  d.cur = 0
  d.gradientTool(0, 0, W.float, 900, [(0.0, night), (1.0, plum)])
  # the Spiral tool, a decoration; the Polygon tool in Star mode, sparkles
  let sp = d.shapeTool(Path(), ShapePaint(kind: spNone), "Spiral", solidPaint(cyan), 3, "Spiral")
  d.setShape(sp, ShapeData(path: spiralPath(-160, -160, 420, 420, 4.5, 82), fill: ShapePaint(kind: spNone),
                           stroke: solidPaint(cyan), strokeWidth: 3, align: saCenter, kind: "Spiral"))
  sp.opacity = 35
  sp.outerGlow(cyan, 60, 10)
  var sparkles: Path
  for (x, y, r) in [(1120.0, 64.0, 13.0), (96.0, 560.0, 12.0), (430.0, 548.0, 9.0), (880.0, 562.0, 10.0)]:
    sparkles.subs.add starPath(x - r, y - r, x + r, y + r, 4, 70).subs
  let spk = d.shapeTool(sparkles, solidPaint(sun), "Sparkles", kind = "Star")
  spk.outerGlow(sun, 80, 12)
  # Arabic, set right to left: a headline on the canvas, a paragraph justified
  # with kashida, the digits as Arabic-Indic
  let ah = d.typeTool("الحرف العربي على اللوحة", chars("FreeSerif", "Bold", 78, white), 1170, 170, textLeft,
                      "Arabic Headline", rtl = 2)
  ah.gradientOverlay(0xFF7DF9FF'u32, 0xFFFF6BC1'u32, angle = 0)
  ah.dropShadow(0xFF07031A'u32, 70, 6, 0)
  discard d.typeTool("التصميم من اليمين إلى اليسار في ريترو فوتو", chars("FreeSerif", "Regular", 34, sun), 1170,
                     246, textLeft, "Arabic Subhead", rtl = 2)
  var ac = chars("FreeSerif", "Regular", 27, 0xFFEDE7F6'u32, 0, 50)
  ac.digits = 1
  discard d.typeBox([("يكتب ريترو فوتو العربية كما ينبغي أن تُكتب: الحروف متصلة، والسطور تبدأ من اليمين، " &
                      "والفقرات تُضبط بالكشيدة لا بالفراغات وحدها. اكتب العنوان على اللوحة مباشرة، " &
                      "وغيّر الخط والحجم واللون، واختر الأرقام العربية الهندية أو الفارسية، ثم صدّر الصفحة " &
                      "إلى ملف PDF للطباعة بدقة تصل إلى 3500 نقطة في البوصة، بألوان CMYK وعلامات القص.", ac)],
                    70, 290, 1100, 300, justifyLeft, "Arabic Body", rtl = 2)
  # the numbers: a panel, bars drawn with the Rectangle tool, labels
  let panel = d.shapeTool(rectPath(70, 600, 1170, 1196, 26), solidPaint(paper), "Numbers Panel",
                          kind = "Rounded Rectangle")
  panel.dropShadow(0xFF07031A'u32, 55, 14, 30)
  discard d.typeTool("RETRO PHOTO 4.0 IN NUMBERS", chars("Poppins", "Bold", 34, ink, 60), 110, 670,
                     name = "Numbers: Title")
  discard d.typeTool("Counted in the app itself", chars("Lora", "Italic", 22, gray), 110, 706,
                     name = "Numbers: Subtitle")
  let facts = [("Tools in the toolbox", 62), ("Filters", 47), ("Blend modes", 29),
               ("Adjustment layers", 16), ("Text warps", 15), ("Layer effects", 9)]
  let barX = 470.0
  let barW = 600.0
  for i, (label, n) in facts:
    let yy = 742.0 + i.float * 64
    discard d.typeTool(label, chars("Poppins", "Medium", 24, ink), 110, yy + 32, name = "Label: " & label)
    discard d.shapeTool(rectPath(barX, yy + 8, barX + barW, yy + 40, 16), solidPaint(0xFFEDE3EC'u32),
                        "Track: " & label, kind = "Rounded Rectangle")
    let w = barW * n.float / 62
    let bar = d.shapeTool(rectPath(barX, yy + 8, barX + w, yy + 40, 16),
                          gradientPaint([(0.0, magenta), (1.0, orange)], angle = 0), "Bar: " & label,
                          kind = "Rounded Rectangle")
    discard bar
    let num = d.typeTool($n, chars("Poppins", "Bold", 26, (if w > 120: white else: ink)),
                         (if w > 120: barX + w - 18 else: barX + w + 14), yy + 34,
                         (if w > 120: textRight else: textLeft), "Value: " & label)
    discard num
  # the verdict: five stars of the Star tool
  discard d.typeTool("OUR VERDICT", chars("Poppins", "Bold", 22, magenta, 260), 110, 1158, name = "Verdict")
  var five: Path
  for i in 0 .. 4:
    let x = 330.0 + i.float * 46
    five.subs.add starPath(x, 1128, x + 38, 1166, 5, 50).subs
  discard d.shapeTool(five, solidPaint(sun), "Stars: Verdict", stroke = solidPaint(0xFFE0A800'u32), width = 2,
                      kind = "Star")
  # the advertisement: a gradient Fill layer in a rounded frame, the apps' icons placed
  let adBox = d.shapeTool(rectPath(70, 1250, 1170, 1630, 30),
                          gradientPaint([(0.0, magenta), (0.55, 0xFFFF5A5F'u32), (1.0, orange)], angle = 20),
                          "Advert", kind = "Rounded Rectangle")
  adBox.dropShadow(0xFF07031A'u32, 50, 12, 26)
  let rings = d.shapeTool(Path(), ShapePaint(kind: spNone), "Advert Rings")
  var rp: Path
  for i in 0 .. 5:
    let r = 120.0 + i.float * 70
    rp.subs.add ellipsePath(1120 - r, 1310 - r, 1120 + r, 1310 + r).subs
  d.setShape(rings, ShapeData(path: rp, fill: ShapePaint(kind: spNone), stroke: solidPaint(0x40FFFFFF'u32),
                              strokeWidth: 10, align: saCenter, kind: "Ellipse"))
  d.clipToBelow(rings)
  let i1 = d.placeEmbedded(here / "assets" / "filemanager-icon.png", rect(110, 1300, 150, 150), "Retro Files Icon")
  i1.dropShadow(0xFF3A0B2A'u32, 55, 8, 12)
  let i2 = d.placeEmbedded(here / "assets" / "photo-icon-512.png", rect(126, 1470, 118, 118), "Retro Photo Icon")
  discard i2
  discard d.typeTool("RETRO FILES 2.1", chars("Poppins", "Bold", 58, white, 20), 300, 1360, name = "Advert: Title")
  discard d.typeBox([("Columns like a Mac, previews of photos, PDFs, videos and sound, batch renaming " &
                      "and a terminal one key away. On your desktop and on Android.",
                      chars("Poppins", "Regular", 24, 0xFFFFF1F6'u32, 0, 34))],
                    300, 1386, 820, 110, textLeft, "Advert: Copy")
  let cta = d.shapeTool(rectPath(300, 1534, 640, 1580, 23), solidPaint(white), "Advert: Button",
                        kind = "Rounded Rectangle")
  discard cta
  let ct = d.typeTool("FREE · OPEN SOURCE", chars("Poppins", "Bold", 20, magenta, 160), 470, 1565, textCenter,
                      "Advert: Button Text")
  d.centered(ct, 470)
  # the folio
  discard d.typeTool("03", chars("Poppins", "Bold", 18, pink), 70, 1708, name = "Folio: Page")
  discard d.typeTool("RETRO  ·  AUTUMN 2026", chars("Poppins", "Medium", 14, 0xFFBFB3D9'u32, 220), 1170, 1706,
                     textRight, "Folio")
  d.markAll()
  d

# ---- out ---------------------------------------------------------------------------------------

let pages = [cover(), feature(), arabicAndNumbers()]
for i, d in pages:
  d.saveRpd(outDir / ("Retro-04-page" & $(i + 1) & ".rpd"))
  d.saveFlat(outDir / ("Retro-04-page" & $(i + 1) & ".png"), "png")
var o = pdfPreset(ppPrint)
o.title = "RETRO No. 04 - Autumn 2026"
o.author = "Made in Retro Photo"
savePdfPresentation(pages, outDir / "Retro-Magazine-No04.pdf", o, "RETRO No. 04")
echo "wrote ", outDir

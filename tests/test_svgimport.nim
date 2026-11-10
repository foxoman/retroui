## Tests of `retroui/svgimport`: SVG read (colors, transforms, path data,
## style sheets, uses, gradients, clips, masks, markers), made shapes
## (`svgShapes`, `placeSvg`: one shape for a one-color icon, undoable) and
## drawn (`rasterizeSvg`) as resvg draws it; bad input never crashes
## (fuzzed); 60 thumbnails timed.
##
## Fixtures (tests/data/svg): icons of Iconify's sets -- mdi (Apache-2.0),
## tabler (MIT), lucide (ISC), ph (MIT), fluent-emoji-flat (MIT), noto
## (Apache-2.0), logos (CC0), flag-icons (MIT), circle-flags (MIT) -- two
## Wikimedia Commons flags (public domain, as hjnilsson/country-flags has
## them), kitchen.svg (written for these tests); each with a .png of it as
## resvg 0.48 draws it 64 pixels wide.

import std/[os, strutils, math, monotimes, times, random, tables]
import retroui/[gfx, photo, photoshapes, imaging, svgimport]

let dir = currentSourcePath().parentDir / "data" / "svg"

proc svg(body: string; attrs = "width=\"100\" height=\"100\""): string =
  "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" " & attrs & ">" &
    body & "</svg>"

proc near(a, b: (float, float); tol = 1e-6): bool = abs(a[0] - b[0]) <= tol and abs(a[1] - b[1]) <= tol

proc diff(a, b: seq[uint32]): float =
  ## Mean difference of premultiplied channels, 0..255.
  var s = 0.0
  for i in 0 ..< a.len:
    let p = a[i]
    let q = b[i]
    let pa = float(p shr 24) / 255
    let qa = float(q shr 24) / 255
    s += abs(float(p shr 24) - float(q shr 24))
    for sh in [16, 8, 0]:
      s += abs(float((p shr sh) and 255) * pa - float((q shr sh) and 255) * qa)
  s / float(a.len * 4)

proc drawShapes(doc: SvgDoc; w, h: int; color = 0xFF000000'u32): seq[uint32] =
  ## (the shapes drawn with `renderShape`, one over another; 8 pixels in
  ## from the canvas's sides, then cut out)
  const mg = 8
  let cw = w + 2 * mg
  let ch = h + 2 * mg
  var big = newSeq[uint32](cw * ch)
  for (name, s) in doc.svgShapes((mg.float, mg.float, float(mg + w), float(mg + h)), color):
    var lp = newSeq[uint32](cw * ch)
    discard renderShape(s, lp, cw, ch)
    for i in 0 ..< big.len:
      let sp = lp[i]
      let sa = float(sp shr 24) / 255
      if sa <= 0: continue
      let dp = big[i]
      let da = float(dp shr 24) / 255
      let oa = sa + da * (1 - sa)
      template c(sh: int): uint32 =
        uint32(clamp(int(round((float((sp shr sh) and 255) * sa + float((dp shr sh) and 255) * da * (1 - sa)) / oa)),
                     0, 255))
      big[i] = (uint32(round(oa * 255)) shl 24) or (c(16) shl 16) or (c(8) shl 8) or c(0)
  result = newSeq[uint32](w * h)
  for y in 0 ..< h:
    for x in 0 ..< w: result[y * w + x] = big[(y + mg) * cw + x + mg]

# ---- colors ----------------------------------------------------------------------------------------------

for (v, want) in [("#f00", 0xFFFF0000'u32), ("#ff000080", 0x80FF0000'u32), ("#abcd", 0xDDAABBCC'u32),
                  ("rgb(0, 128, 255)", 0xFF0080FF'u32), ("rgba(255,0,0,.5)", 0x80FF0000'u32),
                  ("rgb(100%, 0%, 50%)", 0xFFFF0080'u32), ("rgb(0 0 255 / 50%)", 0x800000FF'u32),
                  ("hsl(120, 100%, 25%)", 0xFF008000'u32), ("hsla(0, 100%, 50%, 0.5)", 0x80FF0000'u32),
                  ("rebeccapurple", 0xFF663399'u32), ("RED", 0xFFFF0000'u32), (" white ", 0xFFFFFFFF'u32)]:
  let d = parseSvg(svg("<rect width='10' height='10' fill='" & v & "'/>"))
  doAssert d.items.len == 1 and d.items[0].fill.kind == spkColor and d.items[0].fill.color == want,
           v & ": " & (if d.items.len > 0: toHex(d.items[0].fill.color) else: "none")
block:
  # currentColor: the color asked for, unless `color` says
  var d = parseSvg(svg("<path d='M0 0h10v10z' fill='currentColor'/>"))
  doAssert d.items[0].fill.kind == spkCurrent
  d = parseSvg(svg("<g color='#0000ff'><path d='M0 0h10v10z' fill='currentColor'/></g>"))
  doAssert d.items[0].fill.kind == spkColor and d.items[0].fill.color == 0xFF0000FF'u32
  # nothing to paint, invisible, display none: not drawn
  d = parseSvg(svg("<path d='M0 0h10v10z' fill='none'/><rect width='5' height='5' visibility='hidden'/>" &
                   "<g display='none'><rect width='5' height='5'/></g><rect width='5' height='5' opacity='0'/>"))
  doAssert d.items.len == 0
echo "colors ok"

# ---- transforms ------------------------------------------------------------------------------------------

block:
  var d = parseSvg(svg("<rect x='10' y='10' width='20' height='10' transform='rotate(90 50 50)'/>"))
  doAssert near(d.items[0].path.subs[0].pts[0].p, (90.0, 10.0))
  d = parseSvg(svg("<g transform='translate(10,0)'><rect x='1' y='2' width='3' height='4' transform='scale(2)'/></g>"))
  doAssert near(d.items[0].path.subs[0].pts[0].p, (12.0, 4.0))
  d = parseSvg(svg("<rect x='0' y='10' width='1' height='1' transform='skewX(45)'/>"))
  doAssert near(d.items[0].path.subs[0].pts[0].p, (10.0, 10.0), 1e-9)
  d = parseSvg(svg("<rect x='1' y='1' width='1' height='1' transform='matrix(1 0 0 1 5 6) scale(2 3)'/>"))
  doAssert near(d.items[0].path.subs[0].pts[0].p, (7.0, 9.0))
  # (a broken transform is none)
  d = parseSvg(svg("<rect x='1' y='1' width='1' height='1' transform='scale(2'/>"))
  doAssert near(d.items[0].path.subs[0].pts[0].p, (1.0, 1.0))
  # units
  d = parseSvg(svg("<rect x='1in' y='10mm' width='12pt' height='50%'/>"))
  let p0 = d.items[0].path.subs[0].pts[0].p
  doAssert near(p0, (96.0, 37.795275590551), 1e-6)
  doAssert abs(d.items[0].path.subs[0].pts[2].p[1] - (37.795275590551 + 50)) < 1e-6
echo "transforms ok"

# ---- path data -------------------------------------------------------------------------------------------

block:
  var p = parsePathData("M10 10 20 20 30 10")
  doAssert p.subs.len == 1 and p.subs[0].pts.len == 3 and not p.subs[0].closed
  p = parsePathData("M10 10h10v10z m5 5h1v1z")
  doAssert p.subs.len == 2 and p.subs[1].closed and near(p.subs[1].pts[0].p, (15.0, 15.0))
  p = parsePathData("M10 10h10v10z l5 5")           # (after z, from where the subpath began)
  doAssert p.subs.len == 2 and near(p.subs[1].pts[0].p, (10.0, 10.0)) and near(p.subs[1].pts[1].p, (15.0, 15.0))
  p = parsePathData("M0 50 A50 50 0 0 1 100 50")
  doAssert near(p.subs[0].pts[^1].p, (100.0, 50.0), 1e-9) and near(p.subs[0].pts[1].p, (50.0, 0.0), 1e-9)
  p = parsePathData("M0 0a10 10 0 1110 10")         # (flags without separators)
  doAssert near(p.subs[0].pts[^1].p, (10.0, 10.0), 1e-9) and p.subs[0].pts.len >= 3
  p = parsePathData("M0 0C0 10 10 10 10 0S20 -10 20 0")
  doAssert near(p.subs[0].pts[1].outH, (10.0, -10.0))
  p = parsePathData("M0 0Q10 10 20 0T40 0")
  doAssert near(p.subs[0].pts[1].outH, (20 + 10 * 2 / 3, -10 * 2 / 3), 1e-9)
  p = parsePathData("M0 0L10 10 L20 x L30 30")      # (stops at the error)
  doAssert p.subs.len == 1 and p.subs[0].pts.len == 2
  p = parsePathData("M.5.5-1-1e1.5.5")
  doAssert near(p.subs[0].pts[0].p, (0.5, 0.5)) and near(p.subs[0].pts[1].p, (-1.0, -10.0)) and
           near(p.subs[0].pts[2].p, (0.5, 0.5))
  doAssert parsePathData("L10 10").subs.len == 0 and parsePathData("").subs.len == 0
echo "path data ok"

# ---- style sheets, uses -----------------------------------------------------------------------------------

block:
  let css = "<style>rect { fill: green } .a { fill: red } #b { fill: blue } g > .c { fill: #123456 }" &
            " .d { fill: #00ff00 !important }</style>"
  var d = parseSvg(svg(css & "<rect class='a' id='b' width='1' height='1'/><rect class='a' width='1' height='1'/>" &
                       "<rect width='1' height='1' fill='black'/><g><rect class='c' width='1' height='1'/></g>" &
                       "<rect class='a' width='1' height='1' style='fill: #ffffff'/>" &
                       "<rect class='d' width='1' height='1' style='fill: #ffffff'/>"))
  doAssert d.items.len == 6
  doAssert d.items[0].fill.color == 0xFF0000FF'u32       # (an id over a class)
  doAssert d.items[1].fill.color == 0xFFFF0000'u32
  doAssert d.items[2].fill.color == 0xFF008000'u32       # (a sheet over an attribute)
  doAssert d.items[3].fill.color == 0xFF123456'u32
  doAssert d.items[4].fill.color == 0xFFFFFFFF'u32       # (style="" over a sheet)
  doAssert d.items[5].fill.color == 0xFF00FF00'u32       # (!important over style="")
  # inheritance, uses, symbols
  d = parseSvg(svg("<defs><path id='p' d='M0 0h10v10z'/><symbol id='s' viewBox='0 0 10 10'>" &
                   "<rect width='10' height='10'/></symbol></defs><g fill='#ff0000' stroke='#00ff00' stroke-width='3'>" &
                   "<use href='#p' x='10'/><use xlink:href='#s' x='50' y='50' width='20' height='20'/></g>" &
                   "<use href='#u'/><use id='u' href='#u'/>"))
  doAssert d.items.len == 2
  doAssert d.items[0].fill.color == 0xFFFF0000'u32 and d.items[0].stroke.color == 0xFF00FF00'u32 and
           d.items[0].strokeWidth == 3
  doAssert near(d.items[0].path.subs[0].pts[0].p, (10.0, 0.0))
  doAssert near(d.items[1].path.subs[0].pts[2].p, (70.0, 70.0))
  doAssert abs(d.items[1].strokeWidth - 6) < 1e-9        # (the symbol's scale)
  # the size and the view box
  d = parseSvg(svg("", "width=\"2in\" viewBox=\"0 0 20 10\""))
  doAssert d.width == 192 and d.height == 96 and d.hasViewBox
  let m = d.svgMap(0, 0, 100, 100)                       # (fitted, centered)
  doAssert near(m.apply((0.0, 0.0)), (0.0, 25.0)) and near(m.apply((20.0, 10.0)), (100.0, 75.0))
  d = parseSvg(svg("<rect width='10' height='10'/>", "width=\"0\" height=\"10\""))
  doAssert d.items.len == 0
  # title; what is skipped is counted
  d = parseSvg(svg("<title> Star </title><text x='1' y='1'>Hi</text><image href='a.png'/>" &
                   "<rect width='1' height='1' filter='url(#f)'/>"))
  doAssert d.title == "Star" and d.skipped["text"] == 1 and d.skipped["image"] == 1 and d.skipped["filter"] == 1
echo "styles and uses ok"

# ---- gradients, clips, masks, markers ---------------------------------------------------------------------

block:
  var d = parseSvg(svg("<linearGradient id='g'><stop offset='0' stop-color='red'/><stop offset='1' stop-color='blue'" &
                       " stop-opacity='.5'/></linearGradient><linearGradient id='h' href='#g' x2='0' y2='1'/>" &
                       "<rect x='10' y='20' width='100' height='50' fill='url(#g)'/>" &
                       "<rect width='10' height='10' fill='url(#h)'/><rect width='10' height='10' fill='url(#nope) #00f'/>"))
  let g = d.items[0].fill
  doAssert g.kind == spkLinear and g.stops.len == 2 and g.stops[1].color == 0x800000FF'u32
  doAssert near(g.m.apply((1.0, 1.0)), (110.0, 70.0)) and near(g.m.apply((0.0, 0.0)), (10.0, 20.0))
  let h = d.items[1].fill
  doAssert h.kind == spkLinear and h.stops.len == 2 and near(h.p1, (0.0, 1.0))
  doAssert d.items[2].fill.kind == spkColor and d.items[2].fill.color == 0xFF0000FF'u32   # (the fallback)
  # a clip path that holds everything is dropped from shapes; one that cuts is a part intersected
  d = parseSvg(svg("<clipPath id='a'><rect width='100' height='100'/></clipPath>" &
                   "<clipPath id='b'><circle cx='50' cy='50' r='20'/></clipPath>" &
                   "<g clip-path='url(#a)'><rect x='10' y='10' width='80' height='80' fill='red'/></g>" &
                   "<rect x='10' y='10' width='80' height='80' fill='blue' clip-path='url(#b)'/>"))
  doAssert d.items.len == 2 and d.items[0].clips.len == 1 and d.items[1].clips.len == 1
  let sh = d.svgShapes((0.0, 0.0, 100.0, 100.0))
  doAssert sh.len == 2 and sh[0].shape.path.subs.len == 1
  doAssert sh[1].shape.path.subs.len == 2 and sh[1].shape.path.subs[1].op == poIntersect
  let b = rasterizeSvg(d, 100, 100)
  doAssert b.px[50 * 100 + 50] == 0xFF0000FF'u32 and b.px[15 * 100 + 15] == 0xFFFF0000'u32
  # a mask of white shapes is a clip path; one of grays is a mask (drawn when rasterized)
  d = parseSvg(svg("<mask id='m'><circle cx='50' cy='50' r='40' fill='#fff'/></mask>" &
                   "<mask id='n'><rect width='100' height='100' fill='#808080'/></mask>" &
                   "<rect width='100' height='100' fill='red' mask='url(#m)'/>" &
                   "<rect width='100' height='100' fill='blue' mask='url(#n)'/>"))
  doAssert d.masks.len == 1 and d.items[0].clips.len == 1 and d.items[1].layers.len == 1
  let mb = rasterizeSvg(d, 100, 100)
  let c0 = mb.px[50 * 100 + 50]
  doAssert (c0 shr 24) == 255 and abs(int(c0 and 255) - 128) < 4      # (blue half over red)
  doAssert abs(int(mb.px[2 * 100 + 2] shr 24) - 128) < 4               # (outside the circle: half blue)
  # markers: the US flag's 50 stars are markers
  d = parseSvg(readFile(dir / "flag-us-1x1.svg"))
  doAssert d.items.len >= 53, $d.items.len
echo "paints, clips, masks, markers ok"

# ---- shapes ----------------------------------------------------------------------------------------------

block:
  # even-odd: the hole turned the other way, one part
  let d = parseSvg(svg("<path fill-rule='evenodd' d='M0 0h100v100H0z M25 25h50v50H25z'/>"))
  let sh = d.svgShapes((0.0, 0.0, 100.0, 100.0))
  doAssert sh.len == 1 and sh[0].shape.path.subs.len == 2 and sh[0].shape.path.subs[1].joined
  var px = newSeq[uint32](100 * 100)
  discard renderShape(sh[0].shape, px, 100, 100)
  doAssert px[50 * 100 + 50] == 0 and px[10 * 100 + 10] == 0xFF000000'u32
block:
  # a one-color icon: one shape, in the color asked for
  var sh = parseSvg(readFile(dir / "mdi-home.svg")).svgShapes((0.0, 0.0, 48.0, 48.0), 0xFF3366CC'u32)
  doAssert sh.len == 1 and sh[0].shape.fill.kind == spColor and sh[0].shape.fill.color == 0xFF3366CC'u32
  # stroke icons: one shape, a stroke without a fill
  for f in ["tabler-settings.svg", "lucide-camera.svg"]:
    sh = parseSvg(readFile(dir / f)).svgShapes((0.0, 0.0, 48.0, 48.0))
    doAssert sh.len == 1, f & ": " & $sh.len
    doAssert sh[0].shape.fill.kind == spNone and sh[0].shape.stroke.kind == spColor
    doAssert abs(sh[0].shape.strokeWidth - 4) < 1e-9 and sh[0].shape.cap == lcRound and sh[0].shape.join == ljRound
  # duotone: two shapes (the light one at 20 %)
  sh = parseSvg(readFile(dir / "ph-heart-duotone.svg")).svgShapes((0.0, 0.0, 48.0, 48.0))
  doAssert sh.len == 2 and sh[0].shape.fill.opacity == 20 and sh[1].shape.fill.opacity == 100
  # gradients become a shape's gradient through the same colors
  sh = parseSvg(readFile(dir / "kitchen.svg")).svgShapes((0.0, 0.0, 120.0, 120.0))
  doAssert sh[0].shape.fill.kind == spGradient and sh[0].shape.fill.stops.len >= 2
  doAssert sh[0].shape.stroke.kind == spColor and sh[0].shape.strokeWidth == 2
echo "shapes ok"

# ---- placing ---------------------------------------------------------------------------------------------

block:
  let d = newDoc(200, 200)
  let before = d.layers.len
  let ls = d.placeSvg(readFile(dir / "kitchen.svg"), rect(20, 20, 160, 160))
  doAssert ls.len > 3 and ls[0].group and ls[0].name == "Kitchen sink"
  for k in 1 ..< ls.len: doAssert ls[k].isShape and ls[k].depth == 1
  doAssert d.layers.len == before + ls.len and not d.stepOpen
  d.updateComposite()
  doAssert d.comp[100 * 200 + 20] != 0xFFFFFFFF'u32 or d.comp[40 * 200 + 40] != 0xFFFFFFFF'u32
  d.undo()
  doAssert d.layers.len == before
  d.redo()
  doAssert d.layers.len == before + ls.len
  # one shape: no group, named after the SVG
  let one = d.placeSvg(readFile(dir / "mdi-home.svg"), rect(0, 0, 50, 50), asGroup = true)
  doAssert one.len == 1 and one[0].isShape and one[0].name == "SVG"
  # within a step already begun
  d.beginStep("Place two")
  discard d.placeSvg(readFile(dir / "lucide-camera.svg"), rect(0, 0, 50, 50))
  discard d.placeSvg(readFile(dir / "tabler-settings.svg"), rect(50, 0, 50, 50))
  d.endStep()
  let n = d.layers.len
  d.undo()
  doAssert d.layers.len == n - 2
  doAssert d.placeSvg("not an svg", rect(0, 0, 10, 10)).len == 0
echo "placing ok"

# ---- drawn as resvg draws it ----------------------------------------------------------------------------------

block:
  var total = 0.0
  var n = 0
  for f in walkFiles(dir / "*.svg"):
    let png = f.changeFileExt("png")
    if not fileExists(png): continue
    let r = decodePng(readFile(png))
    let data = readFile(f)
    let b = rasterizeSvg(data, r.w, r.h)
    let m = diff(b.px, r.px)
    total += m
    inc n
    echo "  ", f.extractFilename, " ", r.w, "x", r.h, ": ", formatFloat(m, ffDecimal, 2), " (as shapes ",
         formatFloat(diff(drawShapes(parseSvg(data), r.w, r.h), r.px), ffDecimal, 2), ")"
    doAssert m < 3.0, f        # (the US flag's 50 stars, 4 pixels wide, cross themselves: 2.6)
  echo "drawn: ", n, " files, mean difference ", formatFloat(total / n.float, ffDecimal, 2), " of 255"
  doAssert n >= 10 and total / n.float < 1.2
  # a transparent background; the color asked for
  let b = rasterizeSvg(readFile(dir / "mdi-home.svg"), 24, 24, 0xFF00FF00'u32)
  doAssert b.px[0] == 0 and b.px[15 * 24 + 6] == 0xFF00FF00'u32 and b.px[17 * 24 + 12] == 0   # (the door)
echo "drawing ok"

# ---- bad input ---------------------------------------------------------------------------------------------

proc tryAll(data: string) =
  let d = parseSvg(data)
  discard d.svgShapes((0.0, 0.0, 24.0, 24.0))
  discard rasterizeSvg(d, 24, 24)

block:
  # crafted ones
  var deep = svg(repeat("<g>", 5000) & "<rect width='1' height='1'/>" & repeat("</g>", 5000))
  tryAll(deep)
  var fan = "<defs><rect id='u0' width='1' height='1'/>"
  for k in 1 .. 12:
    fan.add "<g id='u" & $k & "'>" & repeat("<use href='#u" & $(k - 1) & "'/>", 10) & "</g>"
  fan.add "</defs><use href='#u12'/>"
  let t0 = getMonoTime()
  tryAll(svg(fan))                                       # (10^12 uses: cut short)
  # (a bound for a blow-up, not a speed: under ASan and UBSan -- the nightly
  # job sets ASAN_OPTIONS -- each step is many times slower)
  let bound = if getEnv("ASAN_OPTIONS").len > 0 or getEnv("UBSAN_OPTIONS").len > 0: 150_000 else: 20_000
  doAssert (getMonoTime() - t0).inMilliseconds < bound
  var lol = "<?xml version='1.0'?><!DOCTYPE svg [<!ENTITY a \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\">"
  lol.add "<!ENTITY b \"&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;\"><!ENTITY c \"<g>&b;&b;&b;&b;&b;&b;&b;&b;</g>\">]>"
  lol.add svg(repeat("&c;", 2000))
  tryAll(lol)
  for s in [svg("<path d='M1e308 1e308L-1e308 1e308z' stroke='red' stroke-width='1e300'/>"),
            svg("<rect width='10' height='10' transform='scale(1e200) scale(1e200)'/>"),
            svg("<path d='M0 0h1000000' stroke='red' stroke-dasharray='0.000001'/>"),
            svg("<path d='M0 0h10' stroke='red' stroke-dasharray='0 0.0000001' stroke-linecap='round'/>"),
            svg("<circle r='5' fill='url(#g)'/><radialGradient id='g' r='0' fr='-1'/>"),
            svg("<g clip-path='url(#a)'><rect width='5' height='5'/></g><clipPath id='a' clip-path='url(#a)'>" &
                "<use href='#a'/></clipPath>"),
            svg("<mask id='m' mask='url(#m)'><rect width='9' height='9' fill='url(#m)'/></mask>" &
                "<rect width='9' height='9' mask='url(#m)'/>"),
            svg("<marker id='k'><path d='M0 0L1 1' marker-end='url(#k)' stroke='red'/></marker>" &
                "<path d='M0 0L10 10' marker-end='url(#k)'/>"),
            svg("<rect width='1' height='1'/>", "viewBox=\"0 0 0 0\""), svg("", "width=\"-5\""),
            "", "<", "<svg", "<svg/>", "<svg><", "\x00\xff\xfe", "<svg><path d='M0 0 A 1e-320 1e-320 0 0 0 1 1'/></svg>",
            svg("<style>@media screen { rect { fill: red } } :not(x) {} rect:first-child{fill:blue}</style>" &
                "<rect width='4' height='4'/>")]:
    tryAll(s)
  # mutated fixtures
  var rng = initRand(20261031)
  var files: seq[string]
  for f in walkFiles(dir / "*.svg"): files.add readFile(f)
  const junk = ["<", ">", "\"", "'", "/", "=", " ", "-", ".", "e", "9", "#", "url(#", ")", "z", "A", "&", ";",
                "<g>", "</g>", "<use href='#a'/>", "transform='scale(0)'", "1e999", "nan", "-0"]
  let t1 = getMonoTime()
  var tried = 0
  for it in 0 ..< 1500:
    var s = files[rng.rand(files.high)]
    for k in 0 .. rng.rand(1 .. 6):
      if s.len == 0: break
      let at = rng.rand(s.high)
      case rng.rand(3)
      of 0: s = s[0 ..< at] & s[min(s.len, at + rng.rand(1 .. 40)) .. ^1]
      of 1: s.insert(junk[rng.rand(junk.high)], at)
      of 2: s[at] = char(rng.rand(255))
      else: s = s[0 ..< at]
    tryAll(s)
    inc tried
  echo "bad input: ", tried, " mutated files in ", (getMonoTime() - t1).inMilliseconds, " ms, none crashed"
echo "bad input ok"

# ---- speed: a grid of 60 thumbnails --------------------------------------------------------------------------

block:
  var datas: seq[string]
  for f in walkFiles(dir / "*.svg"): datas.add readFile(f)
  var best = 1e9
  for rep in 0 .. 2:
    let t = getMonoTime()
    for k in 0 ..< 60:
      let b = rasterizeSvg(datas[k mod datas.len], 64, 64)
      doAssert b.w == 64
    best = min(best, (getMonoTime() - t).inMicroseconds.float / 1000)
  echo "60 thumbnails at 64 x 64 (parsed and drawn): ", formatFloat(best, ffDecimal, 1), " ms"
  doAssert best < 1500
echo "svgimport ok"

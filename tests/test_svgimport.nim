## Tests of `retroui/svgimport`: SVG read (colors, transforms, path data,
## style sheets, uses, gradients, clips, masks, markers), made shapes
## (`svgShapes`, `placeSvg`: one shape for a one-color icon, undoable) and
## drawn (`rasterizeSvg`) as resvg draws it; texts (runs, lines, along a
## path, the font found, letters given places, outlines, gradients,
## directions) and pictures (in the file, beside it, an SVG), read, drawn
## -- on worker threads too -- and made type layers and layers of pixels;
## patterns, filters (and the drop shadows among them), blending modes,
## masks, groups kept as groups, and what is hidden kept hidden; bad input
## never crashes (fuzzed); 60 thumbnails timed.
##
## Fixtures (tests/data/svg): icons of Iconify's sets -- mdi (Apache-2.0),
## tabler (MIT), lucide (ISC), ph (MIT), fluent-emoji-flat (MIT), noto
## (Apache-2.0), logos (CC0), flag-icons (MIT), circle-flags (MIT) -- two
## Wikimedia Commons flags (public domain, as hjnilsson/country-flags has
## them), kitchen.svg (written for these tests); each with a .png of it as
## resvg 0.48 draws it 64 pixels wide. fx-*.svg (written for these tests:
## patterns, every filter step, blending modes, masks, text with its
## outline, its gradient, its letters' own places): each as resvg draws it
## 96 pixels wide (resvg_py 0.5.0, FreeSans given for the text).

import std/[os, strutils, math, monotimes, times, random, tables, base64]
import retroui/[gfx, photo, photoshapes, imaging, svgimport, textengine]

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
  doAssert d.title == "Star" and d.texts.len == 1 and d.texts[0].runs[0].text == "Hi" and
           d.skipped["image"] == 1 and d.skipped["filter"] == 1      # (a picture that is not there)
echo "styles and uses ok"

# ---- texts and pictures --------------------------------------------------------------------------------------

block textsAndPictures:
  proc shown(t: SvgText): string =
    for r in t.runs: result.add r.text
  # a text: its runs in their looks, where it starts
  var d = parseSvg(svg("<style>.h { font: italic bold 20px Georgia, serif; fill: #203080 }</style>" &
                       "<text class='h' x='10' y='30' data-name='Head line'>  Hello\n <tspan fill='red' " &
                       "font-style='normal' font-weight='400'>big</tspan>   world </text>"))
  doAssert d.texts.len == 1 and d.items.len == 1 and d.items[0].extra == 1 and d.items[0].kind == "text"
  var t = d.texts[0]
  doAssert t.shown == "Hello big world" and t.runs.len == 3      # (spaces made one, the ends' cut)
  doAssert t.x == 10 and t.y == 30 and t.anchor == 0 and t.leading == 0 and t.id == "Head line"
  doAssert t.runs[0].size == 20 and t.runs[0].weight == 700 and t.runs[0].italic and "Georgia" in t.runs[0].family
  doAssert t.runs[0].fill.color == 0xFF203080'u32
  doAssert t.runs[1].text == "big" and t.runs[1].fill.color == 0xFFFF0000'u32 and t.runs[1].weight == 400 and
           not t.runs[1].italic
  # lines from the same x: one text; a tspan put somewhere else: one of its own
  d = parseSvg(svg("<text x='50' y='20' font-size='10' text-anchor='middle' letter-spacing='1' " &
                   "text-decoration='underline'><tspan x='50' dy='0'>one</tspan><tspan x='50' dy='12'>two</tspan>" &
                   "<tspan x='50' dy='12'>three</tspan><tspan x='5' y='90'>far</tspan></text>"))
  doAssert d.texts.len == 2 and d.texts[0].shown == "one\ntwo\nthree" and d.texts[0].leading == 12
  doAssert d.texts[0].anchor == 1 and d.texts[0].runs[0].underline and d.texts[0].runs[0].spacing == 1
  doAssert d.texts[1].shown == "far" and d.texts[1].x == 5 and d.texts[1].y == 90
  # what goes on in a line: after what was before it
  d = parseSvg(svg("<text x='10' y='20' font-size='10'>x<tspan dy='-4' font-size='6'>2</tspan></text>"))
  doAssert d.texts.len == 2 and d.texts[1].shown == "2" and d.texts[1].y == 16
  doAssert d.texts[1].x > 12 and d.texts[1].x < 20             # (measured: an x wide)
  # spaces kept when asked; entities; a baseline in the middle
  d = parseSvg(svg("<text x='0' y='20' xml:space='preserve'> a  b &amp; &#169;</text>" &
                   "<text x='0' y='50' font-size='20' dominant-baseline='middle'>m</text>"))
  doAssert d.texts[0].shown == " a  b & \xC2\xA9" and abs(d.texts[1].y - 57) < 1e-9
  # hidden, not displayed, with no fill: not there, or in no color
  d = parseSvg(svg("<text x='0' y='20' display='none'>a</text><text x='0' y='20' visibility='hidden'>b</text>" &
                   "<text x='0' y='20' opacity='0'>c</text><text x='0' y='20'></text>"))
  doAssert d.items.len == 0
  # along a path
  d = parseSvg(svg("<defs><path id='p' d='M10 50 L90 50'/></defs><text font-size='10'><textPath href='#p' " &
                   "startOffset='50%' text-anchor='middle'>on it</textPath></text>"))
  doAssert d.texts.len == 1 and d.texts[0].path.subs.len == 1 and d.texts[0].offsetPercent and
           d.texts[0].pathOffset == 50 and d.texts[0].anchor == 1
  var td = svgTextData(d.texts[0], d.svgMap(0, 0, 200, 200) * d.texts[0].ctm)
  doAssert td.path.len == 2 and td.path[0] == (20'f32, 100'f32) and td.spans[0].style.size == 20
  doAssert td.pathOffset > 40 and td.pathOffset < 80          # (its middle at the path's)
  # the font: the family there is, else by its kind
  doAssert svgFont("Nothing Such, Times New Roman, serif").family == "FreeSerif"
  doAssert svgFont("Courier New", 700, true) == ("FreeMono", "Bold Oblique") or
           svgFont("Courier New", 700, true) == ("FreeMono", "Bold Italic")
  doAssert svgFont("").family == "FreeSans" and svgFont("FREESERIF").family == "FreeSerif"
  # a text in a mask masks: what is under shows through its letters
  d = parseSvg(svg("<mask id='m'><text x='5' y='80' font-size='90' font-weight='bold' fill='white'>I</text></mask>" &
                   "<rect width='100' height='100' fill='#0000ff' mask='url(#m)'/>"))
  doAssert d.texts.len == 1 and d.masks.len == 1 and d.skipped.getOrDefault("text") == 0
  block:
    let b = rasterizeSvg(d, 100, 100)
    var blue = 0
    for p in b.px:
      if p == 0xFF0000FF'u32: inc blue
    doAssert blue > 300 and blue < 4000 and b.px[0] == 0          # (an I of blue, nothing round it)

  # pictures: in the file, beside it; nowhere else
  let pic = newBitmap(4, 2)
  for i in 0 ..< 8: pic.px[i] = (if i mod 4 < 2: 0xFFFF0000'u32 else: 0xFF0000FF'u32)
  let png = encodePng(pic)
  let tmp = getTempDir() / "retro-svgtest"
  createDir(tmp / "in")
  writeFile(tmp / "in" / "pic one.png", png)
  writeFile(tmp / "out.png", png)
  let uri = "data:image/png;base64," & base64.encode(png)
  d = parseSvg(svg("<image id='a' x='10' y='20' width='40' height='40' href='" & uri & "'/>" &
                   "<image x='0' y='0' width='40' height='40' preserveAspectRatio='xMidYMid slice' " &
                   "xlink:href='pic%20one.png'/><image width='8' height='8' preserveAspectRatio='none' " &
                   "href='../out.png'/><image width='8' height='8' href='" & (tmp / "out.png") & "'/>"),
               tmp / "in")
  doAssert d.images.len == 2 and d.skipped["image"] == 2      # (a file above the folder, or named whole: not read)
  doAssert d.images[0].bitmap.w == 4 and d.images[0].id == "a"
  doAssert near(d.images[0].m.apply((0.0, 0.0)), (10.0, 30.0)) and near(d.images[0].m.apply((4.0, 2.0)), (50.0, 50.0))
  doAssert d.images[1].crop == (1.0, 0.0, 3.0, 2.0)            # (sliced: its middle fills the square)
  doAssert parseSvg(svg("<image width='8' height='8' href='pic%20one.png'/>")).images.len == 0   # (no folder given)
  removeDir(tmp)

  # drawn: the letters, the picture
  d = parseSvg(svg("<rect width='100' height='100' fill='white'/><text x='10' y='80' font-size='80' " &
                   "font-weight='bold' fill='#00a000'>I</text><image x='60' y='10' width='30' height='30' " &
                   "preserveAspectRatio='none' opacity='0.5' href='" & uri & "'/>"))
  let b = rasterizeSvg(d, 100, 100)
  var green = 0
  for p in b.px:
    if p == 0xFF00A000'u32: inc green
  doAssert green > 300 and green < 3000                         # (an I)
  let left = b.px[25 * 100 + 65]
  let right = b.px[25 * 100 + 85]
  doAssert (left shr 16 and 255) == 255 and (left and 255) in 126'u32 .. 129'u32     # (red, half over white)
  doAssert (right and 255) == 255 and (right shr 16 and 255) in 126'u32 .. 129'u32   # (blue, half)

  # for a document: in their order, shapes not made one across a text
  d = parseSvg(svg("<rect width='10' height='10' fill='red'/><text x='0' y='50' font-size='10'>mid</text>" &
                   "<rect x='20' width='10' height='10' fill='red'/><rect x='40' width='10' height='10' fill='red'/>" &
                   "<g opacity='0.5'><image x='60' y='10' width='30' height='30' href='" & uri & "'/></g>"))
  let ps = d.svgPieces((0.0, 0.0, 200.0, 200.0))
  doAssert ps.len == 4 and ps[0].shape.path.subs.len == 1 and ps[1].text.spans.len == 1 and
           ps[2].shape.path.subs.len == 2 and ps[3].image != nil and ps[3].opacity == 50
  doAssert ps[1].text.spans[0].style.size == 20 and ps[1].text.y == 100 and ps[1].text.path.len == 0
  doAssert d.svgShapes((0.0, 0.0, 200.0, 200.0)).len == 1     # (the shapes alone: one, as before)
  # in a document: type layers that can be typed in; a turned text along a line
  let doc = newDoc(200, 200, 0'u32)
  let made = doc.placeSvg(svg("<rect width='10' height='10' fill='red'/><text id='up' x='10' y='50' " &
                              "font-size='10'>straight</text><text transform='translate(50 80) rotate(90)' " &
                              "font-size='10' opacity='0.4'>turned</text><image id='im' x='60' y='10' width='30' " &
                              "height='30' href='" & uri & "'/>"), rect(0, 0, 200, 200))
  doAssert made.len == 5 and made[0].group and made[1].isShape and made[2].isText and made[3].isText and
           not made[4].isText and not made[4].isShape
  doAssert made[2].name == "up" and made[2].text.plainText == "straight" and made[2].text.x == 20
  doAssert made[3].text.path.len == 2 and made[3].opacity == 40
  doAssert abs(made[3].text.path[1][0] - made[3].text.path[0][0]) < 0.01 and
           made[3].text.path[1][1] > made[3].text.path[0][1]    # (it runs down)
  doAssert made[4].name == "im" and made[4].px[60 * 200 + 130] != 0 and made[4].px[10 * 200 + 10] == 0
  doc.undo()
  doAssert doc.layers.len == 1

  # on another thread (a thumbnail made in the background): its text too, in the
  # program's own fonts -- each thread with faces of its own
  when compileOption("threads"):
    var other: Thread[void]
    var seen {.global.}: int
    proc work() {.thread.} =
      {.cast(gcsafe).}:
        var mine = 0
        for round in 0 ..< 8:
          let dd = parseSvg("<svg xmlns='http://www.w3.org/2000/svg' width='50' height='50'><text x='5' y='40' " &
                            "font-size='40' font-weight='bold' fill='#00a000'>I</text><text x='30' y='20' " &
                            "font-size='9' font-family='monospace'>" & $round & "</text>" &
                            "<rect width='5' height='5' fill='#00a000'/></svg>")
          let bb = rasterizeSvg(dd, 50, 50)
          mine = 0
          for p in bb.px:
            if p == 0xFF00A000'u32: inc mine
        discard atomicInc(seen, mine)
    var others: array[3, Thread[void]]
    for t in others.mitems: createThread(t, work)
    # (and here at the same time)
    for k in 0 ..< 20:
      discard rasterizeSvg(parseSvg(svg("<text x='5' y='40' font-size='40' font-family='serif'>Aa " & $k &
                                        "</text>")), 60, 60)
    for t in others.mitems: joinThread(t)
    doAssert seen > 3 * 150 and seen mod 3 == 0, $seen           # (three I's, alike, and the squares)

  # damaged: never a crash
  var rng = initRand(11)
  let whole = svg("<style>text { font: 12px serif }</style><text x='10' y='20' text-anchor='end'>a<tspan dy='1em' " &
                  "x='10 20 30'>b &lt; c</tspan><textPath href='#p'>d</textPath></text><path id='p' d='M0 0L9 9'/>" &
                  "<image width='10' height='10' href='" & uri & "'/>")
  for k in 0 ..< 400:
    var s2 = whole
    for j in 0 .. rng.rand(1 .. 4):
      let at = rng.rand(s2.high)
      case rng.rand(2)
      of 0: s2 = s2[0 ..< at] & s2[min(s2.len, at + rng.rand(1 .. 30)) .. ^1]
      of 1: s2[at] = char(rng.rand(255))
      else: s2.insert(["<text>", "</tspan>", "<tspan x='1e99' dy='-1e308'>", "font-size='0'", "&#x110000;"][rng.rand(4)], at)
    let dd = parseSvg(s2)
    discard rasterizeSvg(dd, 24, 24)
    discard dd.svgPieces((0.0, 0.0, 64.0, 64.0))
echo "texts and pictures ok"

# ---- patterns, filters, groups, masks, blending, what is hidden ----------------------------------------

block looks:
  proc count(b: Bitmap; c: uint32): int =
    for p in b.px:
      if p == c: inc result
  # a pattern: its tile drawn, repeated; a pattern fill in a document
  var d = parseSvg(svg("<pattern id='p' width='10' height='10' patternUnits='userSpaceOnUse'>" &
                       "<rect width='10' height='10' fill='#ffffff'/><rect width='5' height='10' fill='#ff0000'/>" &
                       "</pattern><rect x='10' y='10' width='80' height='80' fill='url(#p)'/>"))
  doAssert d.patterns.len == 1 and d.items.len == 1 and d.items[0].fill.kind == spkPattern and
           d.skipped.getOrDefault("pattern") == 0
  doAssert d.patterns[0].w == 10 and d.patterns[0].items.len == 2
  var b = rasterizeSvg(d, 100, 100)
  doAssert b.count(0xFFFF0000'u32) == 3200 and b.count(0xFFFFFFFF'u32) == 3200 and b.px[0] == 0   # (stripes)
  doAssert b.px[50 * 100 + 12] == 0xFFFF0000'u32 and b.px[50 * 100 + 17] == 0xFFFFFFFF'u32
  var ps = d.svgPieces((0.0, 0.0, 200.0, 200.0))
  doAssert ps.len == 1 and ps[0].shape.fill.kind == spPattern and ps[0].shape.fill.pw == 20 and
           ps[0].shape.fill.pattern.len == 400 and ps[0].shape.fill.pattern[0] == 0xFFFF0000'u32
  # ... in parts of the shape's box, after another pattern, moved
  d = parseSvg(svg("<pattern id='a' width='0.5' height='1'><rect width='20' height='80' fill='#00ff00'/></pattern>" &
                   "<pattern id='b' href='#a' patternTransform='translate(20 0)'/>" &
                   "<rect x='10' y='10' width='80' height='80' fill='url(#b)'/>"))
  b = rasterizeSvg(d, 100, 100)
  doAssert b.px[50 * 100 + 15] == 0 and b.px[50 * 100 + 35] == 0xFF00FF00'u32 and b.px[50 * 100 + 55] == 0 and
           b.px[50 * 100 + 75] == 0xFF00FF00'u32
  # ... turned a quarter: as a shape's fill, one tile the size of the shape's box, the stripes lying
  # across on it as they do in the picture (a pattern fill itself is never turned)
  d = parseSvg(svg("<pattern id='p' width='10' height='10' patternUnits='userSpaceOnUse' " &
                   "patternTransform='rotate(90)'><rect width='10' height='10' fill='#ffffff'/>" &
                   "<rect width='5' height='10' fill='#ff0000'/></pattern>" &
                   "<rect x='10' y='10' width='80' height='60' fill='url(#p)'/>"))
  b = rasterizeSvg(d, 100, 100)
  doAssert b.px[12 * 100 + 50] == 0xFFFF0000'u32 and b.px[17 * 100 + 50] == 0xFFFFFFFF'u32 and
           b.px[12 * 100 + 20] == 0xFFFF0000'u32                     # (the stripes run across now)
  ps = d.svgPieces((0.0, 0.0, 100.0, 100.0))
  doAssert ps.len == 1 and ps[0].shape.fill.kind == spPattern and ps[0].shape.fill.pw == 81 and
           ps[0].shape.fill.ph == 61
  block:
    let doc = newDoc(100, 100, 0'u32)
    discard doc.placeSvg(svg("<pattern id='p' width='10' height='10' patternUnits='userSpaceOnUse' " &
                             "patternTransform='rotate(90)'><rect width='10' height='10' fill='#ffffff'/>" &
                             "<rect width='5' height='10' fill='#ff0000'/></pattern>" &
                             "<rect x='10' y='10' width='80' height='60' fill='url(#p)'/>"), rect(0, 0, 100, 100))
    let flat = doc.toBitmap()
    var apart = 0
    for i in 0 ..< flat.px.len:
      if flat.px[i] != b.px[i]: inc apart
    doAssert apart < 300, $apart                                  # (the same picture, but for its edge)
  # a pattern that is not there: its fallback color, and counted
  d = parseSvg(svg("<rect width='10' height='10' fill='url(#none) #123456'/><pattern id='e' width='4' height='4'/>" &
                   "<rect width='10' height='10' fill='url(#e) blue'/>"))
  doAssert d.items[0].fill.color == 0xFF123456'u32 and d.items[1].fill.color == 0xFF0000FF'u32 and
           d.skipped["pattern"] == 1

  # filters: a blur spreads, a shadow lies where it is put, in its color
  d = parseSvg(svg("<filter id='f' x='-50%' y='-50%' width='200%' height='200%'><feGaussianBlur stdDeviation='4'/>" &
                   "</filter><rect x='40' y='40' width='20' height='20' fill='#ff0000' filter='url(#f)'/>"))
  doAssert d.filters.len == 1 and d.groups.len == 1 and d.groups[0].filter == 1 and
           d.skipped.getOrDefault("filter") == 0
  b = rasterizeSvg(d, 100, 100)
  doAssert (b.px[50 * 100 + 50] shr 24) > 150 and (b.px[50 * 100 + 50] shr 24) < 255   # (its middle paler)
  doAssert (b.px[50 * 100 + 34] shr 24) in 10'u32 .. 120'u32 and b.px[50 * 100 + 10] == 0   # (past its edge; not far)
  d = parseSvg(svg("<filter id='f' x='-50%' y='-50%' width='200%' height='200%'><feDropShadow dx='10' dy='20' " &
                   "stdDeviation='0' flood-color='#0000ff' flood-opacity='0.5'/></filter>" &
                   "<rect x='20' y='20' width='30' height='30' fill='#ff0000' filter='url(#f)'/>"))
  b = rasterizeSvg(d, 100, 100)
  doAssert b.px[30 * 100 + 30] == 0xFFFF0000'u32                 # (itself, over its shadow)
  let sh = b.px[60 * 100 + 55]
  doAssert (sh shr 24) in 126'u32 .. 129'u32 and (sh and 255) == 255 and ((sh shr 16) and 255) == 0, toHex(sh)
  doAssert b.px[15 * 100 + 15] == 0 and b.px[80 * 100 + 80] == 0
  let s1 = svgShadow(d.filters[0])
  doAssert s1.on and s1.dx == 10 and s1.dy == 20 and s1.blur == 0 and s1.color == 0x800000FF'u32
  # ... the steps drawing programs write for one: seen as one, and drawn the same
  d = parseSvg(svg("<filter id='f' x='-50%' y='-50%' width='200%' height='200%'><feGaussianBlur in='SourceAlpha' " &
                   "stdDeviation='0'/><feOffset dx='10' dy='20' result='o'/><feFlood flood-color='#0000ff' " &
                   "flood-opacity='0.5'/><feComposite in2='o' operator='in'/><feMerge><feMergeNode/>" &
                   "<feMergeNode in='SourceGraphic'/></feMerge></filter>" &
                   "<rect x='20' y='20' width='30' height='30' fill='#ff0000' filter='url(#f)'/>"))
  let s2 = svgShadow(d.filters[0])
  doAssert s2.on and s2.dx == 10 and s2.dy == 20 and s2.color == 0x800000FF'u32
  let b2 = rasterizeSvg(d, 100, 100)
  doAssert b2.px == b.px
  # ... CSS's own: drop-shadow(), blur()
  d = parseSvg(svg("<rect x='20' y='20' width='30' height='30' fill='#ff0000' " &
                   "style='filter: drop-shadow(10px 20px 0px rgb(0, 0, 255))'/>"))
  doAssert d.filters.len == 1 and svgShadow(d.filters[0]).dx == 10 and
           svgShadow(d.filters[0]).color == 0xFF0000FF'u32
  # ... colors: gray; turned round; a table; grown and shrunk; added up
  proc one(filter: string; fill = "#ff0000"; space = "sRGB"): uint32 =
    let dd = parseSvg(svg("<filter id='f' x='-50%' y='-50%' width='200%' height='200%' " &
                          "color-interpolation-filters='" & space & "'>" & filter & "</filter>" &
                          "<rect x='40' y='40' width='20' height='20' fill='" & fill & "' filter='url(#f)'/>"))
    doAssert dd.skipped.getOrDefault("filter") == 0, filter
    rasterizeSvg(dd, 100, 100).px[50 * 100 + 50]
  doAssert one("<feColorMatrix type='saturate' values='0'/>") == 0xFF363636'u32
  doAssert one("<feColorMatrix type='matrix' values='0 0 0 0 0  0 0 0 0 1  0 0 0 0 0  0 0 0 1 0'/>") == 0xFF00FF00'u32
  doAssert ((one("<feColorMatrix type='hueRotate' values='120'/>") shr 8) and 255) > 100   # (red toward green)
  doAssert one("<feComponentTransfer><feFuncR type='linear' slope='0.5'/><feFuncA type='table' " &
               "tableValues='0 0.5'/></feComponentTransfer>") == 0x80800000'u32
  doAssert one("<feFlood flood-color='#00ff00'/><feComposite in2='SourceGraphic' operator='arithmetic' " &
               "k2='0.5' k3='0.5'/>") == 0xFF808000'u32
  doAssert one("<feFlood flood-color='#0000ff'/><feBlend in='SourceGraphic' mode='screen'/>") == 0xFFFF00FF'u32
  # ... in linear light, as a filter is unless it says sRGB: red's gray is lighter, half of red is not 128
  doAssert one("<feColorMatrix type='saturate' values='0'/>", space = "linearRGB") == 0xFF7F7F7F'u32
  doAssert one("<feColorMatrix type='saturate' values='0'/>", space = "auto") == 0xFF7F7F7F'u32
  doAssert one("<feFlood flood-color='#00ff00'/><feComposite in2='SourceGraphic' operator='arithmetic' " &
               "k2='0.5' k3='0.5'/>", space = "linearRGB") == 0xFFBCBC00'u32
  doAssert one("<feFlood flood-color='#0000ff' color-interpolation-filters='sRGB'/><feComposite in2='SourceGraphic' " &
               "operator='arithmetic' k2='0.5' k3='0.5' color-interpolation-filters='sRGB'/>",
               space = "linearRGB") == 0xFF800080'u32          # (a step's own word)
  # ... the blending modes that take the three colors together
  # (red over gray. color: red's hue as light as the gray -- 1, 0.29, 0.29; luminosity: a gray as light as red, 0.3)
  let asColor = one("<feFlood flood-color='#808080'/><feBlend in='SourceGraphic' mode='color'/>")
  doAssert asColor == 0xFFFF4A4A'u32 or asColor == 0xFFFF4949'u32, toHex(asColor)
  let asLight = one("<feFlood flood-color='#808080'/><feBlend in='SourceGraphic' mode='luminosity'/>")
  doAssert asLight == 0xFF4D4D4D'u32 or asLight == 0xFF4C4C4C'u32, toHex(asLight)
  # ... a step's own rectangle: nothing of it outside
  d = parseSvg(svg("<filter id='f' filterUnits='userSpaceOnUse' x='0' y='0' width='100' height='100'>" &
                   "<feFlood flood-color='#00ff00' x='10' y='20' width='30' height='40'/></filter>" &
                   "<rect x='40' y='40' width='20' height='20' fill='#ff0000' filter='url(#f)'/>"))
  b = rasterizeSvg(d, 100, 100)
  doAssert b.count(0xFF00FF00'u32) == 1200 and b.px[20 * 100 + 10] == 0xFF00FF00'u32 and b.px[50 * 100 + 50] == 0
  # ... tiles: that rectangle side by side
  d = parseSvg(svg("<filter id='f' filterUnits='userSpaceOnUse' x='0' y='0' width='100' height='100'>" &
                   "<feFlood flood-color='#00ff00' x='0' y='0' width='10' height='10' result='a'/>" &
                   "<feOffset in='SourceGraphic' dx='0' dy='0' x='0' y='0' width='20' height='20' result='b'/>" &
                   "<feMerge x='0' y='0' width='20' height='20'><feMergeNode in='a'/></feMerge><feTile/></filter>" &
                   "<rect x='40' y='40' width='20' height='20' fill='#ff0000' filter='url(#f)'/>"))
  b = rasterizeSvg(d, 100, 100)
  doAssert b.count(0xFF00FF00'u32) == 2500 and b.px[45 * 100 + 45] == 0xFF00FF00'u32 and b.px[55 * 100 + 45] == 0
  # ... noise: the same each time, another with another seed, not one color; stitched, the same at
  # both ends of its tile (next to each other across the seam: no jump)
  block:
    proc noise(extra: string): seq[uint32] =
      let dd = parseSvg(svg("<filter id='f' x='0' y='0' width='1' height='1'><feTurbulence " & extra &
                            "/></filter><rect width='100' height='100' filter='url(#f)'/>"))
      doAssert dd.skipped.getOrDefault("filter") == 0 and dd.filters[0].prims[0].kind == "feTurbulence"
      rasterizeSvg(dd, 100, 100).px
    let n1 = noise("type='fractalNoise' baseFrequency='0.05' numOctaves='2' seed='3'")
    doAssert n1 == noise("type='fractalNoise' baseFrequency='0.05' numOctaves='2' seed='3'")
    doAssert n1 != noise("type='fractalNoise' baseFrequency='0.05' numOctaves='2' seed='4'")
    var kinds = 0
    for i in 1 ..< n1.len:
      if n1[i] != n1[i - 1]: inc kinds
    doAssert kinds > 5000
    proc seam(px: seq[uint32]): int =
      for y in 0 ..< 50:
        for sh in [0, 8, 16, 24]:
          result = max(result, abs(int((px[y * 100] shr sh) and 255) - int((px[y * 100 + 49] shr sh) and 255)))
    let args = "type='fractalNoise' baseFrequency='0.07' numOctaves='2' seed='5' x='0' y='0' width='50' height='50' " &
               "color-interpolation-filters='sRGB'"
    doAssert seam(noise(args & " stitchTiles='stitch'")) < 30 and seam(noise(args)) > 50
  # ... displacement: a map of one color moves all of it (red 1: ten to the left; green 0.25: five down)
  d = parseSvg(svg("<filter id='f' filterUnits='userSpaceOnUse' x='0' y='0' width='100' height='100' " &
                   "color-interpolation-filters='sRGB'>" &
                   "<feFlood flood-color='#ff4080' result='n'/><feDisplacementMap in='SourceGraphic' in2='n' " &
                   "scale='20' xChannelSelector='R' yChannelSelector='G'/></filter>" &
                   "<rect x='40' y='40' width='20' height='20' fill='#ff0000' filter='url(#f)'/>"))
  b = rasterizeSvg(d, 100, 100)
  doAssert b.count(0xFFFF0000'u32) == 400 and b.px[45 * 100 + 30] == 0xFFFF0000'u32 and
           b.px[64 * 100 + 49] == 0xFFFF0000'u32 and b.px[44 * 100 + 30] == 0 and b.px[45 * 100 + 50] == 0
  # ... light: a flat surface under a far light straight above is the light's color; from the side, darker
  doAssert one("<feDiffuseLighting lighting-color='#ffcc00'><feDistantLight elevation='90'/></feDiffuseLighting>") ==
           0xFFFFCC00'u32
  doAssert one("<feDiffuseLighting lighting-color='#ffffff'><feDistantLight elevation='30'/></feDiffuseLighting>") ==
           0xFF808080'u32
  doAssert one("<feSpecularLighting specularExponent='4'><fePointLight x='50' y='50' z='50'/></feSpecularLighting>") ==
           0xFFFFFFFF'u32
  # ... a picture of something else in the drawing; a kernel (a pixel and its neighbor: red, twice)
  d = parseSvg(svg("<defs><circle id='dot' cx='10' cy='10' r='10' fill='#0000ff'/></defs>" &
                   "<filter id='f' filterUnits='userSpaceOnUse' x='0' y='0' width='100' height='100'>" &
                   "<feImage href='#dot' x='60' y='60'/></filter>" &
                   "<rect x='40' y='40' width='20' height='20' fill='#ff0000' filter='url(#f)'/>"))
  doAssert d.filters[0].prims[0].items.len == 1
  b = rasterizeSvg(d, 100, 100)
  doAssert b.px[70 * 100 + 70] == 0xFF0000FF'u32 and b.px[50 * 100 + 50] == 0 and b.px[10 * 100 + 10] == 0
  doAssert one("<feConvolveMatrix order='3 1' kernelMatrix='1 1 0' divisor='4' preserveAlpha='true'/>") ==
           0xFF800000'u32
  doAssert parseSvg(svg("<filter id='f'><feConvolveMatrix order='3' kernelMatrix='1 2 3'/></filter>" &
                        "<rect width='9' height='9' filter='url(#f)'/>")).skipped["filter"] == 1   # (not a 3 by 3)
  d = parseSvg(svg("<filter id='f' x='-50%' y='-50%' width='200%' height='200%'><feMorphology operator='dilate' " &
                   "radius='5'/></filter><rect x='40' y='40' width='20' height='20' fill='#ff0000' filter='url(#f)'/>"))
  b = rasterizeSvg(d, 100, 100)
  doAssert b.px[50 * 100 + 37] == 0xFFFF0000'u32 and b.px[50 * 100 + 33] == 0     # (five more each way)
  # ... a step that is not made: drawn without the filter, and counted
  d = parseSvg(svg("<filter id='f'><feGaussianBlur stdDeviation='2'/><feSomethingNew/></filter>" &
                   "<rect x='40' y='40' width='20' height='20' fill='#ff0000' filter='url(#f)'/>"))
  doAssert d.filters.len == 0 and d.skipped["filter"] == 1 and
           rasterizeSvg(d, 100, 100).px[50 * 100 + 50] == 0xFFFF0000'u32

  # blending: multiplied with what is under it; a group's opacity its own
  d = parseSvg(svg("<rect width='100' height='100' fill='#808080'/>" &
                   "<rect x='20' y='20' width='60' height='60' fill='#ff8000' style='mix-blend-mode:multiply'/>"))
  doAssert d.groups.len == 1 and d.groups[0].blend == "multiply"
  doAssert rasterizeSvg(d, 100, 100).px[50 * 100 + 50] == 0xFF804000'u32
  # groups: one with a name, one with an opacity over several things -- kept; a thing's own folded in
  d = parseSvg(svg("<g data-name='Layer 1'><rect width='10' height='10' fill='red'/>" &
                   "<g opacity='0.5'><rect x='20' width='10' height='10' fill='red'/>" &
                   "<rect x='25' width='10' height='10' fill='red'/></g></g>" &
                   "<g opacity='0.5'><rect x='60' width='10' height='10' fill='red'/></g>" &
                   "<g inkscape:label='Empty'/>"))
  doAssert d.groups.len == 2 and d.groups[1].name == "Layer 1" and d.groups[1].count == 3 and
           d.groups[0].name == "" and d.groups[0].count == 2 and d.groups[0].opacity == 0.5
  doAssert d.items[3].opacity == 0.5 and d.items[3].layers.len == 0
  ps = d.svgPieces((0.0, 0.0, 200.0, 200.0))
  doAssert ps.len == 3 and ps[0].groups == @[1] and ps[1].groups == @[1, 0] and ps[1].shape.path.subs.len == 2 and
           ps[2].groups.len == 0 and ps[2].opacity == 50 and ps[1].opacity == 0   # (the group's half is the group's)
  doAssert d.svgShapes((0.0, 0.0, 200.0, 200.0)).len == 4        # (the shapes alone: no groups, each its opacity)
  block:
    let doc = newDoc(200, 200, 0'u32)
    let made = doc.placeSvg(svg("<g data-name='Layer 1' style='mix-blend-mode:screen'><rect width='10' height='10' " &
                                "fill='red'/><g opacity='0.5'><rect x='20' width='10' height='10' fill='red'/>" &
                                "<rect x='25' width='10' height='10' fill='blue'/></g></g>"), rect(0, 0, 200, 200),
                            asGroup = false)
    var seen: seq[string]
    for L in doc.layers:
      seen.add L.name & (if L.group: "/group" else: "") & "/" & $L.depth & "/" & $L.opacity
    doAssert seen[1 .. ^1] == @["Shape 1/1/100", "Shape 2/2/100", "Shape 3/2/100", "Group/group/1/50",
                                "Layer 1/group/0/100"], $seen       # (after the document's own first layer)
    doAssert doc.layers[^1].mode == bmScreen and made.len == 5
    # (half of the two together: where they overlap, the one over shows alone)
    let flat = doc.toBitmap()
    doAssert (flat.px[10 * 200 + 55] shr 24) in 126'u32 .. 129'u32 and (flat.px[10 * 200 + 55] and 255) > 200

  # masks: a gradient's lets less and less through; in a document the layer's mask
  d = parseSvg(svg("<linearGradient id='g'><stop offset='0' stop-color='white'/><stop offset='1' " &
                   "stop-color='black'/></linearGradient><mask id='m'><rect width='100' height='100' fill='url(#g)'/>" &
                   "</mask><rect width='100' height='100' fill='#ff0000' mask='url(#m)'/>"))
  doAssert d.masks.len == 1 and d.skipped.getOrDefault("mask") == 0
  b = rasterizeSvg(d, 100, 100)
  doAssert (b.px[50 * 100 + 5] shr 24) > 220 and (b.px[50 * 100 + 50] shr 24) in 90'u32 .. 160'u32 and
           (b.px[50 * 100 + 95] shr 24) < 30
  ps = d.svgPieces((0.0, 0.0, 100.0, 100.0))
  doAssert ps.len == 1 and ps[0].masks == @[0]
  let mv = svgMask(d, ps[0].masks, ps[0].clips, ps[0].map, 100, 100)
  doAssert mv.len == 10000 and mv[50 * 100 + 5] > 220'u8 and mv[50 * 100 + 95] < 30'u8
  block:
    let doc = newDoc(100, 100, 0'u32)
    let made = doc.placeSvg(svg("<linearGradient id='g'><stop offset='0' stop-color='white'/><stop offset='1' " &
                                "stop-color='black'/></linearGradient><mask id='m'><rect width='100' height='100' " &
                                "fill='url(#g)'/></mask><rect width='100' height='100' fill='#ff0000' " &
                                "mask='url(#m)'/><clipPath id='c'><circle cx='50' cy='50' r='20'/></clipPath>" &
                                "<text x='30' y='60' font-size='30' clip-path='url(#c)'>Hey</text>"),
                            rect(0, 0, 100, 100), asGroup = false)
    doAssert made.len == 2 and made[0].isShape and made[0].mask != nil and made[1].isText and made[1].mask != nil
    doAssert (made[0].mask.px[50 * 100 + 5] and 255) > 220 and (made[0].mask.px[50 * 100 + 95] and 255) < 30
    doAssert (made[1].mask.px[50 * 100 + 50] and 255) == 255 and (made[1].mask.px[50 * 100 + 5] and 255) == 0
    let flat = doc.toBitmap()
    doAssert (flat.px[50 * 100 + 5] shr 24) > 220 and (flat.px[50 * 100 + 95] shr 24) < 30

  # a shadow in a document: the layer's Drop Shadow; any other filter: pixels, as it is drawn
  block:
    let doc = newDoc(100, 100, 0'u32)
    let made = doc.placeSvg(svg("<filter id='s'><feDropShadow dx='3' dy='4' stdDeviation='2' flood-color='#000080' " &
                                "flood-opacity='0.5'/></filter><filter id='b' x='-50%' y='-50%' width='200%' " &
                                "height='200%'><feGaussianBlur stdDeviation='3'/></filter>" &
                                "<rect id='lit' x='10' y='10' width='20' height='20' fill='#ff0000' " &
                                "filter='url(#s)'/><g id='soft' filter='url(#b)'><rect x='60' y='60' width='20' " &
                                "height='20' fill='#00ff00'/><rect x='70' y='70' width='20' height='20' " &
                                "fill='#0000ff'/></g>"), rect(0, 0, 100, 100), asGroup = false)
    doAssert made.len == 2 and made[0].isShape and made[0].name == "lit" and not made[1].isShape
    let e = made[0].fx.fx[fxDropShadow]
    doAssert e.on and e.distance == 5 and e.size == 4 and e.opacity == 50 and e.color == 0xFF000080'u32 and
             e.angle in 125 .. 128, $e.angle
    doAssert (made[1].px[57 * 100 + 70] shr 24) in 5'u32 .. 200'u32 and (made[1].px[75 * 100 + 75] shr 24) > 200

  # what is hidden: left out -- or kept, hidden, when it is asked for
  let off = svg("<rect id='a' width='10' height='10' fill='red'/><rect id='b' x='20' width='10' height='10' " &
                "fill='blue' visibility='hidden'/><g display='none' data-name='Off'><rect x='40' width='10' " &
                "height='10' fill='lime'/><text x='40' y='30' font-size='10'>t</text></g>" &
                "<rect id='c' x='60' width='10' height='10' fill='lime' display='none'/>")
  d = parseSvg(off)
  doAssert d.items.len == 1 and d.groups.len == 0
  d = parseSvg(off, hidden = true)
  doAssert d.items.len == 5 and not d.items[0].hidden and d.items[1].hidden and not d.items[2].hidden and
           d.items[4].hidden and d.groups.len == 1 and d.groups[0].hidden and d.groups[0].name == "Off"
  b = rasterizeSvg(d, 100, 100)
  doAssert b.count(0xFFFF0000'u32) == 100 and b.count(0xFF0000FF'u32) == 0 and b.count(0xFF00FF00'u32) == 0
  doAssert d.svgShapes((0.0, 0.0, 100.0, 100.0)).len == 1
  block:
    let doc = newDoc(100, 100, 0'u32)
    let made = doc.placeSvg(off, rect(0, 0, 100, 100), asGroup = false, hidden = true)
    var seen: seq[string]
    for L in doc.layers: seen.add L.name & (if L.visible: "" else: " off") & "/" & $L.depth
    doAssert seen[1 .. ^1] == @["a/0", "b off/0", "Shape 1/1", "t/1", "Off off/0", "c off/0"], $seen
    doAssert made.len == 6
    let flat = doc.toBitmap()
    doAssert flat.count(0xFFFF0000'u32) == 100 and flat.count(0xFF0000FF'u32) == 0 and flat.count(0xFF00FF00'u32) == 0

  # text: letters given places, a length to fill -- spaced to take as much
  d = parseSvg(svg("<text y='20' font-size='10' x='10 30 50 70'>ABCD</text>" &
                   "<text x='10' y='40' font-size='10' textLength='80'>ABCD</text>" &
                   "<text x='10' y='60' font-size='10'>ABCD</text>"))
  doAssert d.texts[0].fitChars == 4 and d.texts[0].fitWidth == 60 and d.texts[1].fitChars == -1 and
           d.texts[1].fitWidth == 80 and d.texts[2].fitChars == 0
  block:
    proc wide(t: SvgText): float =
      let td = svgTextData(t, SvgMatrix(a: 1, d: 1))
      let l = layoutText(td)
      l.caretX[^1] - l.caretX[0]
    let nat = wide(d.texts[2])
    doAssert nat > 20 and nat < 40
    # (the last letter 60 on from the first; the caret after it one more space on)
    let w0 = wide(d.texts[0])
    doAssert abs(w0 - (60 + nat / 4 + (60 - nat * 0.75) / 3)) < 6, $w0
    doAssert abs(wide(d.texts[1]) - (80 + (80 - nat) / 3)) < 6, $wide(d.texts[1])
    doAssert svgTextData(d.texts[0], SvgMatrix(a: 1, d: 1)).spans[0].style.tracking > 1000
  # ... each at its place when drawn: the same letter four times, twenty apart
  doAssert d.texts[0].places == @[(1, 30.0), (2, 50.0), (3, 70.0)]
  block:
    let dd = parseSvg(svg("<text y='25' font-size='20' x='10 30 50 70' font-weight='bold'>AAAA</text>"))
    doAssert dd.texts.len == 1 and dd.texts[0].places.len == 3
    let px = rasterizeSvg(dd, 100, 100).px
    proc column(px: seq[uint32]; x: int): int =
      for y in 0 ..< 30:
        if (px[y * 100 + x] shr 24) > 60: inc result
    var inked = 0
    for x in 10 ..< 30:
      doAssert abs(column(px, x) - column(px, x + 20)) <= 1 and abs(column(px, x) - column(px, x + 60)) <= 1, $x
      inked += column(px, x)
    doAssert inked > 60, $inked
  # ... letters moved on, moved down and turned: a text each, where it is put
  d = parseSvg(svg("<text x='10' y='20' font-size='10' dx='0 5 5' dy='0 3 -3'>abc</text>" &
                   "<text x='10 30' y='50 60' font-size='10' rotate='0 90'>de</text>" &
                   "<text x='10' y='80' font-size='10'>a<tspan dx='4 2'>bc</tspan>d</text>"))
  doAssert d.texts.len == 7, $d.texts.len
  doAssert d.texts[0].runs[0].text == "a" and d.texts[1].runs[0].text == "b" and d.texts[1].y == 23 and
           d.texts[1].x > 19 and d.texts[1].x < 23 and d.texts[2].runs[0].text == "c" and d.texts[2].y == 20
  doAssert d.texts[3].runs[0].text == "d" and d.texts[4].runs[0].text == "e" and d.texts[4].x == 30 and
           d.texts[4].y == 60 and abs(d.texts[4].ctm.b - 1) < 1e-9 and abs(d.texts[4].ctm.a) < 1e-9   # (a quarter turn)
  doAssert near(d.texts[4].ctm.apply((30.0, 60.0)), (30.0, 60.0))             # (about where it starts)
  # (a tspan moved on is a text of its own, four past the "a"; in it, the "c" two on from where
  # the "b" ends -- a place in the same text)
  doAssert d.texts[5].runs[0].text == "a" and d.texts[6].runs[0].text == "bcd" and d.texts[6].places.len == 1 and
           d.texts[6].places[0][0] == 1 and d.texts[6].x > d.texts[5].x + 8 and
           d.texts[6].places[0][1] > d.texts[6].x + 6
  # ... more room between words; letters that are their outline alone
  d = parseSvg(svg("<text x='10' y='20' font-size='10' word-spacing='7'>a b</text>" &
                   "<text x='10' y='80' font-size='60' fill='none' stroke='#0000ff' stroke-width='2'>O</text>"))
  doAssert d.texts[0].runs.len == 3 and d.texts[0].runs[1].text == " " and d.texts[0].runs[1].spacing == 7 and
           d.texts[0].runs[0].spacing == 0
  doAssert d.texts[1].hollow and d.texts[1].strokeWidth == 2 and d.texts[1].stroke.kind == spkNone and
           d.texts[1].runs[0].fill.color == 0xFF0000FF'u32 and d.texts.len == 2
  b = rasterizeSvg(d, 100, 100)
  block:
    # (the same letter filled, to tell by: the middle of its line is clear in the hollow one, and
    # the hollow one's outline reaches past it)
    let f = rasterizeSvg(svg("<text x='10' y='20' font-size='10' word-spacing='7'>a b</text>" &
                             "<text x='10' y='80' font-size='60' fill='#0000ff'>O</text>"), 100, 100)
    var clear, past = 0
    for i in 0 ..< b.px.len:
      if f.px[i] == 0xFF0000FF'u32 and b.px[i] == 0: inc clear
      if (b.px[i] shr 24) > 128 and (f.px[i] shr 24) < 128: inc past
    doAssert clear > 100 and past > 50, $clear & " " & $past
    let doc = newDoc(100, 100, 0'u32)
    let made = doc.placeSvg(svg("<text x='10' y='80' font-size='60' fill='none' stroke='#0000ff' " &
                                "stroke-width='2'>O</text>"), rect(0, 0, 100, 100))
    doAssert made.len == 1 and made[0].isText and made[0].fill == 0 and made[0].fx.fx[fxStroke].on and
             made[0].fx.fx[fxStroke].size == 2 and made[0].fx.fx[fxStroke].color == 0xFF0000FF'u32
    let flat = doc.toBitmap()
    var kept = 0
    for i in 0 ..< flat.px.len:
      if f.px[i] == 0xFF0000FF'u32 and (flat.px[i] shr 24) < 40: inc kept
    doAssert kept > 100, $kept                                     # (the Stroke shows, the letter does not)
  # ... its outline, its gradient, its direction, its case
  d = parseSvg(svg("<linearGradient id='g'><stop offset='0' stop-color='#ff0000'/><stop offset='1' " &
                   "stop-color='#0000ff'/></linearGradient><text x='10' y='40' font-size='30' fill='url(#g)' " &
                   "stroke='#000000' stroke-width='2'>Go</text><text x='90' y='70' font-size='10' direction='rtl'>" &
                   "abc</text><text x='10' y='90' font-size='10' style='text-transform:uppercase'>up" &
                   "<tspan style='font-variant:small-caps;text-transform:lowercase'>LOW</tspan></text>" &
                   "<text x='50' y='10' font-size='10' writing-mode='vertical-rl'>down</text>"))
  doAssert d.texts[0].stroke.kind == spkColor and d.texts[0].strokeWidth == 2 and
           d.texts[0].runs[0].fill.kind == spkLinear
  doAssert d.texts[1].rtl and svgTextData(d.texts[1], SvgMatrix(a: 1, d: 1)).para.rtl == 2
  doAssert d.texts[2].runs[0].allCaps and d.texts[2].runs[0].text == "up" and d.texts[2].runs[1].smallCaps and
           d.texts[2].runs[1].text == "low"
  doAssert d.texts[3].vertical and svgTextData(d.texts[3], SvgMatrix(a: 1, d: 1)).vertical
  # (running down, its letters lie on their side, the middle of their height on its x)
  doAssert abs(svgTextData(d.texts[3], SvgMatrix(a: 1, d: 1)).x - 46.5) < 0.01
  b = rasterizeSvg(d, 200, 200)
  doAssert b.count(0xFF000000'u32) > 150                         # (the outline, and the texts)
  var reds, blues = 0
  for y in 30 ..< 90:
    for x in 20 ..< 110:
      let p = b.px[y * 200 + x]
      let red = (p shr 24) == 255 and ((p shr 16) and 255) > 160 and (p and 255) < 90
      let blue = (p shr 24) == 255 and (p and 255) > 160 and ((p shr 16) and 255) < 90
      if (red and x < 60) or (blue and x >= 60): inc reds          # (as the gradient goes)
      elif red or blue: inc blues
  doAssert reds > 40 and blues < reds div 6, $reds & " " & $blues     # (red at its left, blue at its right)
  ps = d.svgPieces((0.0, 0.0, 200.0, 200.0))
  doAssert ps[0].outline == 4 and ps[0].outlineColor == 0xFF000000'u32 and ps[0].gradient.kind == spkLinear
  block:
    let doc = newDoc(200, 200, 0'u32)
    let made = doc.placeSvg(svg("<linearGradient id='g'><stop offset='0' stop-color='#ff0000'/><stop offset='1' " &
                                "stop-color='#0000ff'/></linearGradient><text x='10' y='40' font-size='30' " &
                                "fill='url(#g)' stroke='#000000' stroke-width='2'>Go</text>"), rect(0, 0, 200, 200))
    doAssert made.len == 1 and made[0].fx.fx[fxStroke].on and made[0].fx.fx[fxStroke].size == 4 and
             made[0].fx.fx[fxStroke].style == 2
    let go = made[0].fx.fx[fxGradientOverlay]
    doAssert go.on and go.color == 0xFFFF0000'u32 and go.color2 == 0xFF0000FF'u32 and go.angle == 0

  # what Retro Photo writes for itself: effects, a blending mode by its name, an adjustment layer --
  # read by `placeSvg`; damaged, left out
  block:
    let doc = newDoc(100, 100, 0'u32)
    let made = doc.placeSvg(svg(
      "<rect width='40' height='40' fill='#ff0000' data-name='Plate' data-retro-mode='Linear Burn' " &
      "data-retro-fx='{\"Bevel and Emboss\":{\"mode\":\"Screen\",\"opacity\":75,\"size\":7},\"fill\":50}'/>" &
      "<g data-name='Warmer' data-retro-adjust='{\"kind\":\"Hue/Saturation\",\"args\":[30,-20,10,0]}' opacity='0.5'/>" &
      "<g data-name='Pair' data-retro-mode='Linear Dodge (Add)'><rect x='50' width='10' height='10' fill='#00ff00'/>" &
      "<rect x='70' width='10' height='10' fill='#0000ff'/></g>" &
      "<rect y='50' width='10' height='10' fill='#000000' data-retro-fx='" & repeat("[", 5000) & "'/>" &
      "<rect y='70' width='10' height='10' fill='#000000' data-retro-fx='{\"Stroke\":7' data-retro-mode='No such'/>" &
      "<g data-retro-adjust='[1,2'/><g data-retro-adjust='{\"args\":[1]}'/>"), rect(0, 0, 100, 100), asGroup = false)
    var seen: seq[string]
    for L in made: seen.add L.name & "/" & $L.mode & "/" & $L.opacity & "/" & L.adjust.kind
    doAssert seen == @["Plate/Linear Burn/100/", "Warmer/Normal/50/Hue/Saturation", "Shape 1/Normal/100/",
                       "Shape 2/Normal/100/", "Shape 3/Normal/100/", "Shape 4/Normal/100/",
                       "Pair/Linear Dodge (Add)/100/"], $seen
    doAssert made[0].fx.fx[fxBevel].on and made[0].fx.fx[fxBevel].size == 7 and made[0].fx.fx[fxBevel].mode == bmScreen and
             made[0].fill == 50 and made[1].adjust.args == @[30.0, -20, 10, 0] and not made[4].hasFx
    # (drawn as a picture, they are nothing: the red square alone where it is)
    doAssert rasterizeSvg(svg("<rect width='40' height='40' fill='#ff0000' data-retro-fx='{}'/>" &
                              "<g data-retro-adjust='{\"kind\":\"Invert\"}'/>"), 100, 100).count(0xFFFF0000'u32) == 1600

  # a picture that is an SVG, written out in the link or in base64
  d = parseSvg(svg("<image x='10' y='10' width='40' height='40' href=\"data:image/svg+xml,%3Csvg xmlns='http://www." &
                   "w3.org/2000/svg' viewBox='0 0 10 10'%3E%3Crect width='10' height='10' fill='%23008000'/%3E%3C/svg" &
                   "%3E\"/><image x='50' y='50' width='40' height='40' href='data:image/svg+xml;base64," &
                   base64.encode("<svg xmlns='http://www.w3.org/2000/svg' width='4' height='4'><rect width='4' " &
                                 "height='4' fill='#800000'/></svg>") & "'/>"))
  doAssert d.images.len == 2 and d.images[0].bitmap.w == 20 and d.images[1].bitmap.w == 8
  b = rasterizeSvg(d, 100, 100)
  doAssert b.px[30 * 100 + 30] == 0xFF008000'u32 and b.px[70 * 100 + 70] == 0xFF800000'u32

  # damaged: never a crash
  var rng = initRand(23)
  let whole = svg("<pattern id='p' width='8' height='8' patternUnits='userSpaceOnUse'><circle cx='4' cy='4' r='3'/>" &
                  "</pattern><filter id='f'><feGaussianBlur stdDeviation='2'/><feOffset dx='2' dy='2' result='o'/>" &
                  "<feFlood flood-color='red'/><feComposite in2='o' operator='in'/><feMerge><feMergeNode/>" &
                  "<feMergeNode in='SourceGraphic'/></feMerge><feColorMatrix type='saturate' values='0.5'/>" &
                  "<feMorphology radius='1'/><feComponentTransfer><feFuncA type='table' tableValues='0 1'/>" &
                  "</feComponentTransfer></filter><mask id='m'><rect width='50' height='50' fill='url(#p)'/></mask>" &
                  "<g data-name='G' opacity='0.5' filter='url(#f)' mask='url(#m)' style='mix-blend-mode:multiply'>" &
                  "<rect width='40' height='40' fill='url(#p)'/><text x='5' y='30' textLength='30' stroke='blue'>ab" &
                  "</text></g><rect width='9' height='9' display='none'/>")
  for k in 0 ..< 400:
    var s2 = whole
    for j in 0 .. rng.rand(1 .. 4):
      let at = rng.rand(s2.high)
      case rng.rand(2)
      of 0: s2 = s2[0 ..< at] & s2[min(s2.len, at + rng.rand(1 .. 30)) .. ^1]
      of 1: s2[at] = char(rng.rand(255))
      else: s2.insert(["<g filter='url(#f)'>", "stdDeviation='1e9'", "width='1e-9'", "radius='9999'",
                       "values='1e308 nan'", "<pattern id='p' href='#p'>", "tableValues=''"][rng.rand(6)], at)
    let dd = parseSvg(s2, hidden = k mod 2 == 0)
    discard rasterizeSvg(dd, 24, 24)
    let pp = dd.svgPieces((0.0, 0.0, 48.0, 48.0))
    for piece in pp:
      discard svgMask(dd, piece.masks, piece.clips, piece.map, 48, 48)
      if piece.raster.len > 0: discard svgRaster(dd, piece.raster, piece.map, 48, 48)
echo "looks ok"

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
  for f in walkFiles(dir / "*.svg"):
    if not f.extractFilename.startsWith("fx-"): datas.add readFile(f)      # (the icons)
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

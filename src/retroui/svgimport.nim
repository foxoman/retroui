## SVG import: icons and vector clipart (Iconify, Openverse, Wikimedia
## Commons...) read as outlines -- each drawable element's path in the
## SVG's user space with its fill and stroke (`parseSvg`) -- placed in a
## document as shape layers (`svgShapes`, `placeSvg`), or drawn as pixels
## (`rasterizeSvg`: thumbnails, art too complex to keep as shapes).
##
## Read: svg (nested too), g, a, switch, use (of shapes, groups, symbols,
## svgs; uses of uses), defs, symbol; path (every command, arcs too), rect
## (rounded), circle, ellipse, line, polyline, polygon; markers;
## transforms (matrix, translate, scale, rotate about a point, skewX,
## skewY, transform-origin; CSS `transform`); presentation attributes,
## `style="..."`, `<style>` sheets (tag, class, id, attribute and
## :first-child selectors, descendant and child combinators, !important);
## inheritance; colors (named, #rgb, #rgba, #rrggbb, #rrggbbaa, rgb(),
## rgba(), hsl(), hsla(), currentColor); linear and radial gradients
## (units, gradientTransform, spreadMethod, focal point, stops, href);
## fill-rule; strokes (width, caps, joins, miter limit, dashes and their
## offset); opacity, fill-opacity, stroke-opacity; paint-order; clip paths
## (nested, on their parts); masks (`rasterizeSvg` draws them; a mask that
## only cuts out -- white shapes -- is a clip path for the shapes too);
## XML namespaces, DOCTYPE entities, the root's background-color. What
## lies outside the viewport is cut there. Skipped, and counted in
## `SvgDoc.skipped`: text, images, filters (drawn unfiltered), patterns
## (their fallback color), foreignObject; and as shapes, masks that are not
## white shapes.
##
## ```nim
## let layers = d.placeSvg(readFile("star.svg"), rect(10, 10, 200, 200), color = 0xFF3366CC'u32)
## let thumb = rasterizeSvg(readFile("star.svg"), 64, 64)
## ```

import std/[math, strutils, tables, algorithm]
from std/unicode import Rune, toUTF8
from std/sequtils import keepItIf
import gfx, photo, photoshapes

type
  SvgMatrix* = object
    ## An affine transform: x' = a x + c y + e, y' = b x + d y + f.
    a*, b*, c*, d*, e*, f*: float   ## the matrix's six numbers (identity: 1, 0, 0, 1, 0, 0)

  SvgPaintKind* = enum
    ## What a fill or stroke paints with: nothing, a color, the color asked
    ## for (`currentColor`), a linear or a radial gradient.
    spkNone, spkColor, spkCurrent, spkLinear, spkRadial

  SvgSpread* = enum
    ## What a gradient does past its ends (spreadMethod): its end colors go
    ## on, it is mirrored, or it repeats.
    ssPad, ssReflect, ssRepeat

  SvgStop* = object
    ## A color stop of a gradient.
    offset*: float            ## 0..1, in order
    color*: uint32            ## 0xAARRGGBB (stop-opacity in the alpha)
    current*: bool            ## currentColor: the color asked for (alpha times `color`'s)

  SvgPaint* = object
    ## A fill or a stroke as the SVG has it.
    kind*: SvgPaintKind       ## what it paints with
    color*: uint32            ## spkColor: 0xAARRGGBB
    stops*: seq[SvgStop]      ## a gradient's
    p0*, p1*: (float, float)  ## linear: from, to; radial: the center, the focal point
    r*, fr*: float            ## radial: the radius, the focal radius
    m*: SvgMatrix             ## the gradient's space to user space
    spread*: SvgSpread        ## what the gradient does past its ends

  SvgItem* = object
    ## Something drawn: an element's outline (in user space: transformed)
    ## and how it is painted.
    id*: string               ## the element's id ("" none)
    kind*: string             ## the element: "path", "rect", "circle"...
    path*: Path               ## its outline (user units)
    fill*, stroke*: SvgPaint  ## how it is filled and stroked
    fillOpacity*, strokeOpacity*: float  ## fill-opacity, stroke-opacity (0..1)
    opacity*: float           ## the element's own (and its groups' when they hold only it)
    evenOdd*: bool            ## fill-rule: evenodd
    strokeWidth*: float       ## user units
    cap*: LineCap             ## stroke-linecap
    join*: LineJoin           ## stroke-linejoin
    miterLimit*: float        ## stroke-miterlimit
    dashes*: seq[float]       ## user units (an even count); empty: solid
    dashOffset*: float        ## stroke-dashoffset (user units)
    strokeFirst*: bool        ## paint-order: the stroke under the fill
    clips*: seq[int]          ## clip paths (`SvgDoc.clips`) that cut it, all of them
    layers*: seq[int]         ## the groups it is drawn in (`SvgDoc.groups`), outermost first
    ctm*: SvgMatrix           ## its element's transform to user space (a stroke is drawn in that space)
    ghost: bool               # (not drawn: there for the boxes of the groups around it)

  SvgClipPart* = object
    ## An outline of a clip path.
    path*: Path               ## its outline (user units)
    evenOdd*: bool            ## clip-rule: evenodd
    clips*: seq[int]          ## clip paths cutting this part

  SvgClip* = object
    ## A clip path: what is in any of its parts shows.
    parts*: seq[SvgClipPart]  ## its outlines
    clips*: seq[int]          ## clip paths that cut the clip path itself
    bounds*: (float, float, float, float)   ## x0, y0, x1, y1
    rect*: bool               ## it is the rectangle `bounds`

  SvgGroup* = object
    ## A group drawn by itself and then put down: its opacity, its mask.
    opacity*: float           ## 0..1
    mask*: int                ## `SvgDoc.masks` (-1: none)

  SvgMask* = object
    ## A mask: what it draws sets how much of what it masks shows.
    items*: seq[SvgItem]      ## what it draws, in order
    alpha*: bool              ## mask-type: alpha (else luminance)
    region*: int              ## the clip path of its rectangle (-1: none)

  SvgDoc* = object
    ## An SVG read: its size, its view box and what it draws, in order.
    width*, height*: float    ## its size (the width and height attributes, or the view box's)
    viewBox*: (float, float, float, float)   ## x, y, width, height
    hasViewBox*: bool         ## it gave a view box
    alignX*, alignY*: float   ## preserveAspectRatio: 0, 0.5, 1 (-1: none -- stretched)
    slice*: bool              ## ... "slice": the view box covers the size (else it fits in it)
    title*: string            ## its <title> ("" none)
    items*: seq[SvgItem]      ## what it draws, back to front
    clips*: seq[SvgClip]      ## the clip paths the items name
    groups*: seq[SvgGroup]    ## the groups drawn by themselves the items name
    masks*: seq[SvgMask]      ## the masks the groups name
    skipped*: CountTable[string]   ## what was not drawn ("text", "image", "filter"...): how many

const
  IdentityM = SvgMatrix(a: 1, d: 1)
  Wsp = {' ', '\t', '\n', '\r', '\f'}
  MaxDepth = 48               # elements in elements (and uses, clips, masks in them)
  MaxWork = 300_000           # elements looked at (uses of uses can multiply them)
  MaxItems = 150_000
  MaxXmlDepth = 400
  Kap = 0.5522847498307936

# ---- matrices ---------------------------------------------------------------------------------------------

proc `*`*(m, n: SvgMatrix): SvgMatrix =
  ## `n`, then `m`.
  SvgMatrix(a: m.a * n.a + m.c * n.b, b: m.b * n.a + m.d * n.b,
            c: m.a * n.c + m.c * n.d, d: m.b * n.c + m.d * n.d,
            e: m.a * n.e + m.c * n.f + m.e, f: m.b * n.e + m.d * n.f + m.f)

proc apply*(m: SvgMatrix; p: (float, float)): (float, float) {.inline.} =
  ## Where `p` goes.
  (m.a * p[0] + m.c * p[1] + m.e, m.b * p[0] + m.d * p[1] + m.f)

proc det(m: SvgMatrix): float {.inline.} = m.a * m.d - m.b * m.c

proc invert*(m: SvgMatrix): SvgMatrix =
  ## The transform back (all zeros when there is none).
  let dt = det(m)
  if abs(dt) < 1e-300 or dt != dt: return SvgMatrix()
  SvgMatrix(a: m.d / dt, b: -m.b / dt, c: -m.c / dt, d: m.a / dt,
            e: (m.c * m.f - m.d * m.e) / dt, f: (m.b * m.e - m.a * m.f) / dt)

proc translateM(x, y: float): SvgMatrix = SvgMatrix(a: 1, d: 1, e: x, f: y)
proc scaleM(x, y: float): SvgMatrix = SvgMatrix(a: x, d: y)

proc scaleOf(m: SvgMatrix): float = sqrt(abs(det(m)))

proc finite(x: float): bool {.inline.} = x - x == 0

proc toInt(x: float): int {.inline.} =
  ## (a float as an int, never past what an int holds)
  if x != x: 0 elif x > 1e9: 1_000_000_000 elif x < -1e9: -1_000_000_000 else: int(x)

# ---- outlines ---------------------------------------------------------------------------------------------

proc corner(p: Pt): PathPoint {.inline.} = PathPoint(p: p, inH: p, outH: p)

proc near(a, b: Pt): bool {.inline.} =
  let tol = 1e-7 * max(1.0, max(abs(a[0]), abs(a[1])))
  abs(a[0] - b[0]) <= tol and abs(a[1] - b[1]) <= tol

type PB = object
  ## (an outline being made: moves, lines, curves, closes)
  subs: seq[SubPath]
  cur: SubPath
  open: bool
  start, pen: Pt

proc flushSub(b: var PB) =
  if b.open and (b.cur.pts.len >= 2 or (b.cur.pts.len == 1 and b.cur.closed)):
    b.subs.add b.cur
  b.cur = SubPath()
  b.open = false

proc moveTo(b: var PB; p: Pt) =
  b.flushSub()
  b.cur.pts.add corner(p)
  b.open = true
  b.start = p
  b.pen = p

proc lineTo(b: var PB; p: Pt) =
  if not b.open: b.moveTo(b.pen)
  b.cur.pts.add corner(p)
  b.pen = p

proc cubicTo(b: var PB; c1, c2, p: Pt) =
  if not b.open: b.moveTo(b.pen)
  b.cur.pts[^1].outH = c1
  b.cur.pts.add PathPoint(p: p, inH: c2, outH: p)
  b.pen = p

proc closeSub(b: var PB) =
  if not b.open: return
  let n = b.cur.pts.len
  if n >= 2 and near(b.cur.pts[^1].p, b.cur.pts[0].p):
    b.cur.pts[0].inH = b.cur.pts[^1].inH
    b.cur.pts.setLen(n - 1)
  b.cur.closed = true
  b.pen = b.start
  b.flushSub()

proc finish(b: var PB): Path =
  b.flushSub()
  Path(subs: move(b.subs))

proc arcTo(b: var PB; rx0, ry0, rotDeg: float; large, sweep: bool; p1: Pt) =
  ## An elliptical arc (SVG's endpoint form) as cubic curves.
  let p0 = b.pen
  if near(p0, p1): return
  var rx = abs(rx0)
  var ry = abs(ry0)
  if rx < 1e-12 or ry < 1e-12 or not finite(rx) or not finite(ry):
    b.lineTo(p1)
    return
  let phi = degToRad(floorMod(rotDeg, 360.0))
  let cp = cos(phi)
  let sp = sin(phi)
  let dx2 = (p0[0] - p1[0]) / 2
  let dy2 = (p0[1] - p1[1]) / 2
  let x1p = cp * dx2 + sp * dy2
  let y1p = -sp * dx2 + cp * dy2
  let lam = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry)
  if lam > 1:
    rx *= sqrt(lam)
    ry *= sqrt(lam)
  let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
  let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
  var coef = if den <= 0: 0.0 else: sqrt(max(0.0, num / den))
  if large == sweep: coef = -coef
  let cxp = coef * rx * y1p / ry
  let cyp = -coef * ry * x1p / rx
  let cx = cp * cxp - sp * cyp + (p0[0] + p1[0]) / 2
  let cy = sp * cxp + cp * cyp + (p0[1] + p1[1]) / 2
  proc ang(ux, uy, vx, vy: float): float = arctan2(ux * vy - uy * vx, ux * vx + uy * vy)
  let ux = (x1p - cxp) / rx
  let uy = (y1p - cyp) / ry
  let vx = (-x1p - cxp) / rx
  let vy = (-y1p - cyp) / ry
  let th1 = ang(1, 0, ux, uy)
  var dth = ang(ux, uy, vx, vy)
  if not sweep and dth > 0: dth -= 2 * PI
  elif sweep and dth < 0: dth += 2 * PI
  if not finite(dth) or not finite(th1) or not finite(cx) or not finite(cy):
    b.lineTo(p1)
    return
  let segs = clamp(int(ceil(abs(dth) / (PI / 2) - 1e-9)), 1, 4)
  let delta = dth / segs.float
  let t = 4 / 3 * tan(delta / 4)
  proc onE(x, y: float): Pt = (cx + rx * cp * x - ry * sp * y, cy + rx * sp * x + ry * cp * y)
  for k in 0 ..< segs:
    let a1 = th1 + k.float * delta
    let a2 = a1 + delta
    let (c1, s1) = (cos(a1), sin(a1))
    let (c2, s2) = (cos(a2), sin(a2))
    let q1 = onE(c1 - t * s1, s1 + t * c1)
    let q2 = onE(c2 + t * s2, s2 - t * c2)
    let e = if k == segs - 1: p1 else: onE(c2, s2)
    b.cubicTo(q1, q2, e)

proc ellipseTo(b: var PB; cx, cy, rx, ry: float) =
  ## (an ellipse as SVG draws one: from its right, turning toward +y)
  let kx = rx * Kap
  let ky = ry * Kap
  b.moveTo((cx + rx, cy))
  b.cubicTo((cx + rx, cy + ky), (cx + kx, cy + ry), (cx, cy + ry))
  b.cubicTo((cx - kx, cy + ry), (cx - rx, cy + ky), (cx - rx, cy))
  b.cubicTo((cx - rx, cy - ky), (cx - kx, cy - ry), (cx, cy - ry))
  b.cubicTo((cx + kx, cy - ry), (cx + rx, cy - ky), (cx + rx, cy))
  b.closeSub()

proc transformed(p: Path; m: SvgMatrix): Path =
  result.name = p.name
  result.subs = p.subs
  for s in result.subs.mitems:
    for q in s.pts.mitems:
      q.p = m.apply(q.p)
      q.inH = m.apply(q.inH)
      q.outH = m.apply(q.outH)

type Box = (float, float, float, float)

const NoBox: Box = (Inf, Inf, -Inf, -Inf)

proc add(b: var Box; p: Pt) {.inline.} =
  if not (finite(p[0]) and finite(p[1])): return
  b[0] = min(b[0], p[0]); b[1] = min(b[1], p[1])
  b[2] = max(b[2], p[0]); b[3] = max(b[3], p[1])

proc union(a, b: Box): Box = (min(a[0], b[0]), min(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3]))

proc empty(b: Box): bool {.inline.} = not (b[2] >= b[0] and b[3] >= b[1])

proc cubicBounds(b: var Box; p0, p1, p2, p3: Pt) =
  b.add p0
  b.add p3
  for ax in 0 .. 1:
    template co(p: Pt): float = (if ax == 0: p[0] else: p[1])
    let (a0, a1, a2, a3) = (co(p0), co(p1), co(p2), co(p3))
    if min(a1, a2) >= min(a0, a3) and max(a1, a2) <= max(a0, a3): continue
    let qa = -a0 + 3 * a1 - 3 * a2 + a3
    let qb = 2 * (a0 - 2 * a1 + a2)
    let qc = a1 - a0
    var ts: seq[float]
    if abs(qa) < 1e-12:
      if abs(qb) > 1e-12: ts.add -qc / qb
    else:
      let disc = qb * qb - 4 * qa * qc
      if disc >= 0:
        let sq = sqrt(disc)
        ts.add (-qb + sq) / (2 * qa)
        ts.add (-qb - sq) / (2 * qa)
    for t in ts:
      if t > 0 and t < 1:
        let u = 1 - t
        b.add (u*u*u*p0[0] + 3*u*u*t*p1[0] + 3*u*t*t*p2[0] + t*t*t*p3[0],
               u*u*u*p0[1] + 3*u*u*t*p1[1] + 3*u*t*t*p2[1] + t*t*t*p3[1])

iterator segments(s: SubPath): (PathPoint, PathPoint) =
  let n = s.pts.len
  let segs = if s.closed: n else: n - 1
  for k in 0 ..< segs: yield (s.pts[k], s.pts[(k + 1) mod n])

proc tightBounds(p: Path; m = IdentityM): Box =
  ## The box around the outline itself (not its handles).
  result = NoBox
  for s in p.subs:
    if s.pts.len == 1: result.add m.apply(s.pts[0].p)
    for (a, b) in s.segments:
      result.cubicBounds(m.apply(a.p), m.apply(a.outH), m.apply(b.inH), m.apply(b.p))

proc polyOf(s: SubPath): seq[Pt] =
  ## (a rough polygon of a subpath: its points and the middles of its curves)
  for (a, b) in s.segments:
    result.add a.p
    if a.outH != a.p or b.inH != b.p:
      result.add (0.125 * a.p[0] + 0.375 * a.outH[0] + 0.375 * b.inH[0] + 0.125 * b.p[0],
                  0.125 * a.p[1] + 0.375 * a.outH[1] + 0.375 * b.inH[1] + 0.125 * b.p[1])
  if s.pts.len > 0 and not s.closed: result.add s.pts[^1].p

proc areaOf(pts: seq[Pt]): float =
  for i in 0 ..< pts.len:
    let a = pts[i]
    let b = pts[(i + 1) mod pts.len]
    result += a[0] * b[1] - b[0] * a[1]

# ---- reading numbers --------------------------------------------------------------------------------------

proc skipWsp(s: string; i: var int) {.inline.} =
  while i < s.len and s[i] in Wsp: inc i

proc skipSep(s: string; i: var int) {.inline.} =
  skipWsp(s, i)
  if i < s.len and s[i] == ',':
    inc i
    skipWsp(s, i)

proc readNum(s: string; i: var int; v: var float): bool =
  ## An SVG number at `i` (no separators skipped), `i` past it.
  var j = i
  var neg = false
  if j < s.len and s[j] in {'+', '-'}:
    neg = s[j] == '-'
    inc j
  var mant = 0.0
  var e10 = 0
  var nd = 0
  var sig = 0
  while j < s.len and s[j] in Digits:
    let dg = ord(s[j]) - 48
    if sig < 18:
      mant = mant * 10 + dg.float
      if mant > 0: inc sig
    else: inc e10
    inc nd
    inc j
  if j < s.len and s[j] == '.':
    inc j
    while j < s.len and s[j] in Digits:
      let dg = ord(s[j]) - 48
      if sig < 18:
        mant = mant * 10 + dg.float
        dec e10
        if mant > 0: inc sig
      inc nd
      inc j
  if nd == 0: return false
  if j < s.len and s[j] in {'e', 'E'}:
    var k = j + 1
    var eneg = false
    if k < s.len and s[k] in {'+', '-'}:
      eneg = s[k] == '-'
      inc k
    if k < s.len and s[k] in Digits:
      var ex = 0
      while k < s.len and s[k] in Digits:
        if ex < 100_000: ex = ex * 10 + (ord(s[k]) - 48)
        inc k
      e10 += (if eneg: -ex else: ex)
      j = k
  var r = mant
  if e10 != 0 and mant != 0:
    r = if e10 < -600: 0.0 elif e10 > 600: Inf else: mant * pow(10.0, e10.float)
  if not finite(r) or r > 1e30: return false
  v = if neg: -r else: r
  i = j
  true

proc readFlag(s: string; i: var int; f: var bool): bool =
  skipSep(s, i)
  if i < s.len and s[i] in {'0', '1'}:
    f = s[i] == '1'
    inc i
    return true
  false

proc numbers(s: string): seq[float] =
  ## The numbers in a list ("1 2,3 -4"); as far as they read.
  var i = 0
  var v: float
  while true:
    skipSep(s, i)
    if i >= s.len or not readNum(s, i, v): break
    result.add v

proc parseNumber(s: string; v: var float): bool =
  var i = 0
  skipWsp(s, i)
  if not readNum(s, i, v): return false
  skipWsp(s, i)
  i == s.len

proc parseOpacity(s: string; v: var float): bool =
  var i = 0
  skipWsp(s, i)
  var x: float
  if not readNum(s, i, x): return false
  if i < s.len and s[i] == '%':
    x /= 100
    inc i
  skipWsp(s, i)
  if i != s.len: return false
  v = clamp(x, 0.0, 1.0)
  true

# ---- XML -----------------------------------------------------------------------------------------------

type XNode = ref object
  tag: string
  attrs: seq[(string, string)]
  kids: seq[XNode]
  text: string

proc attr(n: XNode; name: string): string =
  for (k, v) in n.attrs:
    if k == name: return v
  ""

proc has(n: XNode; name: string): bool =
  for (k, v) in n.attrs:
    if k == name: return true
  false

proc hrefOf(n: XNode): string =
  for (k, v) in n.attrs:
    if k == "href": return v.strip
  for (k, v) in n.attrs:
    if k.endsWith(":href"): return v.strip
  ""

proc decode(s: string; ents: Table[string, string]): string =
  if '&' notin s: return s
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    let ch = s[i]
    if ch == '&':
      let e = s.find(';', i + 1)
      if e > i + 1 and e - i <= 64:
        let name = s[i + 1 ..< e]
        var rep = ""
        var ok = true
        if name[0] == '#':
          var code = -1
          try:
            code = if name.len > 1 and name[1] in {'x', 'X'}: parseHexInt(name[2 .. ^1]) else: parseInt(name[1 .. ^1])
          except ValueError: code = -1
          if code > 0 and code <= 0x10FFFF: rep = toUTF8(Rune(code)) else: ok = false
        else:
          case name
          of "lt": rep = "<"
          of "gt": rep = ">"
          of "amp": rep = "&"
          of "quot": rep = "\""
          of "apos": rep = "'"
          else:
            if name in ents and result.len < 16_000_000: rep = ents[name] else: ok = false
        if ok:
          result.add rep
          i = e + 1
          continue
    result.add ch
    inc i

const SvgNs = "http://www.w3.org/2000/svg"

proc parseXml(input: string): XNode =
  ## A forgiving reader: what is malformed is passed over. Elements of
  ## other namespaces than SVG's get a tag that is none of SVG's; entities
  ## declared in the DOCTYPE are expanded (those holding markup too).
  result = XNode(tag: "")
  var s = input
  var stack = @[result]
  var raws = @[""]                          # (the tags as written, for the ends)
  var nss: seq[seq[(string, string)]] = @[@[]]   # (prefix -> namespace, for each open element)
  var ents = initTable[string, string]()
  var expansions = 0
  var i = 0
  proc nsOf(nss: seq[seq[(string, string)]]; own: seq[(string, string)]; prefix: string; found: var bool): string =
    for (p, u) in own:
      if p == prefix:
        found = true
        return u
    for k in countdown(nss.high, 0):
      for (p, u) in nss[k]:
        if p == prefix:
          found = true
          return u
    found = false
    ""
  while i < s.len:
    let n = s.len
    if s[i] != '<':
      var j = s.find('<', i)
      if j < 0: j = n
      # (an entity holding markup: put in its place and read)
      var at = -1
      var amp = s.find('&', i)
      while amp >= 0 and amp < j and expansions < 1000:
        let e = s.find(';', amp + 1)
        if e < 0 or e > j: break
        let name = s[amp + 1 ..< e]
        if name in ents and '<' in ents[name] and s.len < 32_000_000:
          at = amp
          let top = stack[^1]
          if stack.len > 1 and top.tag in ["style", "title"]: top.text.add decode(s[i ..< amp], ents)
          s = s[0 ..< amp] & ents[name] & s[e + 1 .. ^1]
          inc expansions
          break
        amp = s.find('&', e + 1)
      if at >= 0:
        i = at
        continue
      let top = stack[^1]
      if stack.len > 1 and top.tag in ["style", "title"]: top.text.add decode(s[i ..< j], ents)
      i = j
      continue
    if s.continuesWith("<!--", i):
      let e = s.find("-->", i + 4)
      i = if e < 0: n else: e + 3
    elif s.continuesWith("<![CDATA[", i):
      let e = s.find("]]>", i + 9)
      let stop = if e < 0: n else: e
      if stack.len > 1 and stack[^1].tag in ["style", "title"]: stack[^1].text.add s[i + 9 ..< stop]
      i = if e < 0: n else: e + 3
    elif s.continuesWith("<!", i):
      # <!DOCTYPE svg ... [ <!ENTITY name "value"> ... ]>
      var j = i + 2
      var depth = 0
      while j < n:
        let ch = s[j]
        if ch == '[': inc depth
        elif ch == ']': dec depth
        elif ch == '>' and depth <= 0: break
        elif depth > 0 and s.continuesWith("<!ENTITY", j):
          var k = j + 8
          skipWsp(s, k)
          var pe = false
          if k < n and s[k] == '%':
            pe = true
            inc k
            skipWsp(s, k)
          let k0 = k
          while k < n and s[k] notin Wsp + {'>', '"', '\''}: inc k
          let name = s[k0 ..< k]
          skipWsp(s, k)
          if k < n and s[k] in {'"', '\''}:
            let q = s[k]
            let e = s.find(q, k + 1)
            let stop = if e < 0: n else: e
            if not pe and name.len > 0 and stop - k - 1 <= 65536 and ents.len < 4096:
              ents[name] = s[k + 1 ..< stop]
            k = stop + 1
          let e = s.find('>', k)
          j = if e < 0: n else: e + 1
          continue
        elif depth > 0 and s.continuesWith("<!--", j):
          let e = s.find("-->", j + 4)
          j = if e < 0: n else: e + 3
          continue
        inc j
      i = j + 1
    elif s.continuesWith("<?", i):
      let e = s.find("?>", i + 2)
      i = if e < 0: n else: e + 2
    elif s.continuesWith("</", i):
      var j = i + 2
      while j < n and s[j] notin Wsp + {'>'}: inc j
      let name = s[i + 2 ..< j]
      let e = s.find('>', j)
      i = if e < 0: n else: e + 1
      for k in countdown(stack.high, 1):
        if raws[k] == name:
          stack.setLen(k)
          raws.setLen(k)
          nss.setLen(k)
          break
    else:
      var j = i + 1
      while j < n and s[j] notin Wsp + {'/', '>'}: inc j
      if j == i + 1:
        i = j
        continue
      let raw = s[i + 1 ..< j]
      let node = XNode()
      var own: seq[(string, string)]
      var selfClose = false
      while j < n:
        skipWsp(s, j)
        if j >= n: break
        if s[j] == '>':
          inc j
          break
        if s[j] == '/':
          selfClose = true
          inc j
          continue
        selfClose = false
        let a0 = j
        while j < n and s[j] notin Wsp + {'=', '>', '/'}: inc j
        let an = s[a0 ..< j]
        skipWsp(s, j)
        var av = ""
        if j < n and s[j] == '=':
          inc j
          skipWsp(s, j)
          if j < n and s[j] in {'"', '\''}:
            let q = s[j]
            let e = s.find(q, j + 1)
            let stop = if e < 0: n else: e
            av = decode(s[j + 1 ..< stop], ents)
            j = stop + 1
          else:
            let v0 = j
            while j < n and s[j] notin Wsp + {'>'}: inc j
            av = s[v0 ..< j]
        if an.len > 0:
          node.attrs.add (an, av)
          if an == "xmlns": own.add ("", av.strip)
          elif an.startsWith("xmlns:"): own.add (an[6 .. ^1], av.strip)
        elif j == a0: inc j
      # its namespace: SVG's (or none said: taken as SVG's), or another
      let colon = raw.find(':')
      let prefix = if colon > 0: raw[0 ..< colon] else: ""
      let local = if colon > 0: raw[colon + 1 .. ^1] else: raw
      var found = false
      let ns = nsOf(nss, own, prefix, found)
      node.tag = if ns == SvgNs or (not found and prefix in ["", "svg"]) or (found and ns.len == 0 and prefix == ""):
                   local
                 else: "{" & ns & "}" & local
      stack[^1].kids.add node
      if not selfClose and stack.len < MaxXmlDepth:
        stack.add node
        raws.add raw
        nss.add own
      i = j

# ---- CSS -------------------------------------------------------------------------------------------------

type
  CssCompound = object
    tag, id: string
    classes: seq[string]
    attrs: seq[(string, string, bool)]   # name, value, value given
    firstChild: bool

  CssRule = object
    parts: seq[CssCompound]               # left to right; the last: the element
    combs: seq[char]                      # between them: ' ' (in) or '>' (child of)
    spec: int
    order: int
    decls: seq[(string, string, bool)]    # name, value, !important

proc stripComments(text: string): string =
  result = newStringOfCap(text.len)
  var i = 0
  while i < text.len:
    if text.continuesWith("/*", i):
      let e = text.find("*/", i + 2)
      i = if e < 0: text.len else: e + 2
    else:
      result.add text[i]
      inc i

proc parseDecls(s: string): seq[(string, string, bool)] =
  for d in stripComments(s).split(';'):
    let c = d.find(':')
    if c <= 0: continue
    let name = d[0 ..< c].strip.toLowerAscii
    var value = d[c + 1 .. ^1].strip
    var imp = false
    let bang = value.find('!')
    if bang >= 0:
      imp = value[bang + 1 .. ^1].strip.toLowerAscii == "important"
      value = value[0 ..< bang].strip
    if name.len > 0: result.add (name, value, imp)

proc parseSelector(s: string; r: var CssRule): bool =
  ## One selector (no commas) into `r`: false when it has what is not read.
  var i = 0
  var comp = CssCompound()
  var haveComp = false
  var pending = '\0'
  proc ident(s: string; i: var int): string =
    let i0 = i
    while i < s.len and (s[i].isAlphaNumeric or s[i] in {'-', '_'} or ord(s[i]) >= 128): inc i
    s[i0 ..< i]
  while i < s.len:
    let ch = s[i]
    if ch in Wsp:
      skipWsp(s, i)
      if haveComp and pending == '\0': pending = ' '
      continue
    if ch in {'>', '+', '~'}:
      if ch != '>': return false
      pending = '>'
      inc i
      continue
    if haveComp and pending != '\0':
      r.parts.add comp
      r.combs.add pending
      comp = CssCompound()
      haveComp = false
    pending = '\0'
    if ch == '*':
      inc i
      haveComp = true
    elif ch == '#':
      inc i
      comp.id = ident(s, i)
      if comp.id.len == 0: return false
      r.spec += 10000
      haveComp = true
    elif ch == '.':
      inc i
      let c = ident(s, i)
      if c.len == 0: return false
      comp.classes.add c
      r.spec += 100
      haveComp = true
    elif ch == '[':
      let e = s.find(']', i)
      if e < 0: return false
      let body = s[i + 1 ..< e]
      let eq = body.find('=')
      if eq < 0: comp.attrs.add (body.strip, "", false)
      else:
        if eq > 0 and body[eq - 1] in {'~', '|', '^', '$', '*'}: return false
        comp.attrs.add (body[0 ..< eq].strip, body[eq + 1 .. ^1].strip(chars = Wsp + {'"', '\''}), true)
      r.spec += 100
      i = e + 1
      haveComp = true
    elif ch == ':':
      inc i
      if i < s.len and s[i] == ':': return false
      let p = ident(s, i)
      if p != "first-child": return false
      comp.firstChild = true
      r.spec += 100
      haveComp = true
    elif ch.isAlphaAscii or ch == '_':
      comp.tag = ident(s, i)
      if comp.tag.startsWith("svg|"): comp.tag = comp.tag[4 .. ^1]
      r.spec += 1
      haveComp = true
    else: return false
  if not haveComp: return false
  r.parts.add comp
  true

proc parseCss(text: string; rules: var seq[CssRule]) =
  let s = stripComments(text)
  var i = 0
  while i < s.len:
    skipWsp(s, i)
    if i >= s.len: break
    if s[i] == '@':
      # an at-rule: to its ';' or past its block
      var j = i
      while j < s.len and s[j] notin {';', '{'}: inc j
      if j < s.len and s[j] == '{':
        var depth = 0
        while j < s.len:
          if s[j] == '{': inc depth
          elif s[j] == '}':
            dec depth
            if depth == 0: break
          inc j
      i = j + 1
      continue
    let ob = s.find('{', i)
    if ob < 0: break
    let cb = s.find('}', ob)
    let stop = if cb < 0: s.len else: cb
    let decls = parseDecls(s[ob + 1 ..< stop])
    for sel in s[i ..< ob].split(','):
      var r = CssRule(order: rules.len, decls: decls)
      if sel.strip.len > 0 and parseSelector(sel.strip, r): rules.add r
    i = stop + 1

proc matchOne(c: CssCompound; chain: openArray[XNode]; k: int): bool =
  let n = chain[k]
  if c.tag.len > 0 and n.tag != c.tag: return false
  if c.id.len > 0 and n.attr("id") != c.id: return false
  if c.classes.len > 0:
    let cls = n.attr("class").splitWhitespace
    for x in c.classes:
      if x notin cls: return false
  for (name, value, given) in c.attrs:
    if not n.has(name): return false
    if given and n.attr(name) != value: return false
  if c.firstChild:
    if k == 0 or chain[k - 1].kids.len == 0 or chain[k - 1].kids[0] != n: return false
  true

proc matches(r: CssRule; chain: openArray[XNode]): bool =
  var k = chain.high
  if k < 0 or not matchOne(r.parts[^1], chain, k): return false
  var pi = r.parts.high - 1
  while pi >= 0:
    if r.combs[pi] == '>':
      dec k
      if k < 0 or not matchOne(r.parts[pi], chain, k): return false
    else:
      dec k
      while k >= 0 and not matchOne(r.parts[pi], chain, k): dec k
      if k < 0: return false
    dec pi
  true

# ---- colors ----------------------------------------------------------------------------------------------

const NamedColors = {
  "aliceblue": 0xf0f8ff, "antiquewhite": 0xfaebd7, "aqua": 0x00ffff, "aquamarine": 0x7fffd4,
  "azure": 0xf0ffff, "beige": 0xf5f5dc, "bisque": 0xffe4c4, "black": 0x000000, "blanchedalmond": 0xffebcd,
  "blue": 0x0000ff, "blueviolet": 0x8a2be2, "brown": 0xa52a2a, "burlywood": 0xdeb887,
  "cadetblue": 0x5f9ea0, "chartreuse": 0x7fff00, "chocolate": 0xd2691e, "coral": 0xff7f50,
  "cornflowerblue": 0x6495ed, "cornsilk": 0xfff8dc, "crimson": 0xdc143c, "cyan": 0x00ffff,
  "darkblue": 0x00008b, "darkcyan": 0x008b8b, "darkgoldenrod": 0xb8860b, "darkgray": 0xa9a9a9,
  "darkgreen": 0x006400, "darkgrey": 0xa9a9a9, "darkkhaki": 0xbdb76b, "darkmagenta": 0x8b008b,
  "darkolivegreen": 0x556b2f, "darkorange": 0xff8c00, "darkorchid": 0x9932cc, "darkred": 0x8b0000,
  "darksalmon": 0xe9967a, "darkseagreen": 0x8fbc8f, "darkslateblue": 0x483d8b,
  "darkslategray": 0x2f4f4f, "darkslategrey": 0x2f4f4f, "darkturquoise": 0x00ced1,
  "darkviolet": 0x9400d3, "deeppink": 0xff1493, "deepskyblue": 0x00bfff, "dimgray": 0x696969,
  "dimgrey": 0x696969, "dodgerblue": 0x1e90ff, "firebrick": 0xb22222, "floralwhite": 0xfffaf0,
  "forestgreen": 0x228b22, "fuchsia": 0xff00ff, "gainsboro": 0xdcdcdc, "ghostwhite": 0xf8f8ff,
  "gold": 0xffd700, "goldenrod": 0xdaa520, "gray": 0x808080, "grey": 0x808080, "green": 0x008000,
  "greenyellow": 0xadff2f, "honeydew": 0xf0fff0, "hotpink": 0xff69b4, "indianred": 0xcd5c5c,
  "indigo": 0x4b0082, "ivory": 0xfffff0, "khaki": 0xf0e68c, "lavender": 0xe6e6fa,
  "lavenderblush": 0xfff0f5, "lawngreen": 0x7cfc00, "lemonchiffon": 0xfffacd, "lightblue": 0xadd8e6,
  "lightcoral": 0xf08080, "lightcyan": 0xe0ffff, "lightgoldenrodyellow": 0xfafad2,
  "lightgray": 0xd3d3d3, "lightgreen": 0x90ee90, "lightgrey": 0xd3d3d3, "lightpink": 0xffb6c1,
  "lightsalmon": 0xffa07a, "lightseagreen": 0x20b2aa, "lightskyblue": 0x87cefa,
  "lightslategray": 0x778899, "lightslategrey": 0x778899, "lightsteelblue": 0xb0c4de,
  "lightyellow": 0xffffe0, "lime": 0x00ff00, "limegreen": 0x32cd32, "linen": 0xfaf0e6,
  "magenta": 0xff00ff, "maroon": 0x800000, "mediumaquamarine": 0x66cdaa, "mediumblue": 0x0000cd,
  "mediumorchid": 0xba55d3, "mediumpurple": 0x9370db, "mediumseagreen": 0x3cb371,
  "mediumslateblue": 0x7b68ee, "mediumspringgreen": 0x00fa9a, "mediumturquoise": 0x48d1cc,
  "mediumvioletred": 0xc71585, "midnightblue": 0x191970, "mintcream": 0xf5fffa, "mistyrose": 0xffe4e1,
  "moccasin": 0xffe4b5, "navajowhite": 0xffdead, "navy": 0x000080, "oldlace": 0xfdf5e6,
  "olive": 0x808000, "olivedrab": 0x6b8e23, "orange": 0xffa500, "orangered": 0xff4500,
  "orchid": 0xda70d6, "palegoldenrod": 0xeee8aa, "palegreen": 0x98fb98, "paleturquoise": 0xafeeee,
  "palevioletred": 0xdb7093, "papayawhip": 0xffefd5, "peachpuff": 0xffdab9, "peru": 0xcd853f,
  "pink": 0xffc0cb, "plum": 0xdda0dd, "powderblue": 0xb0e0e6, "purple": 0x800080,
  "rebeccapurple": 0x663399, "red": 0xff0000, "rosybrown": 0xbc8f8f, "royalblue": 0x4169e1,
  "saddlebrown": 0x8b4513, "salmon": 0xfa8072, "sandybrown": 0xf4a460, "seagreen": 0x2e8b57,
  "seashell": 0xfff5ee, "sienna": 0xa0522d, "silver": 0xc0c0c0, "skyblue": 0x87ceeb,
  "slateblue": 0x6a5acd, "slategray": 0x708090, "slategrey": 0x708090, "snow": 0xfffafa,
  "springgreen": 0x00ff7f, "steelblue": 0x4682b4, "tan": 0xd2b48c, "teal": 0x008080,
  "thistle": 0xd8bfd8, "tomato": 0xff6347, "turquoise": 0x40e0d0, "violet": 0xee82ee,
  "wheat": 0xf5deb3, "white": 0xffffff, "whitesmoke": 0xf5f5f5, "yellow": 0xffff00,
  "yellowgreen": 0x9acd32}.toTable

proc mkColor(a, r, g, b: float): uint32 =
  template c8(v: float): uint32 = uint32(clamp(int(round(v)), 0, 255))
  (c8(a) shl 24) or (c8(r) shl 16) or (c8(g) shl 8) or c8(b)

proc hexVal(c: char): int =
  case c
  of '0' .. '9': ord(c) - 48
  of 'a' .. 'f': ord(c) - 87
  of 'A' .. 'F': ord(c) - 55
  else: -1

proc parseColor(v: string; c: var uint32): bool =
  ## A CSS color: named, #rgb, #rgba, #rrggbb, #rrggbbaa, rgb(), rgba(), hsl(), hsla().
  let t = v.strip.toLowerAscii
  if t.len == 0: return false
  if t[0] == '#':
    var j = 1
    while j < t.len and hexVal(t[j]) >= 0: inc j
    if j != t.len: return false
    let h = t[1 ..< j]
    var ds: seq[int]
    for ch in h: ds.add hexVal(ch)
    case h.len
    of 3, 4:
      let a = if h.len == 4: ds[3] * 17 else: 255
      c = mkColor(a.float, float(ds[0] * 17), float(ds[1] * 17), float(ds[2] * 17))
    of 6, 8:
      let a = if h.len == 8: ds[6] * 16 + ds[7] else: 255
      c = mkColor(a.float, float(ds[0] * 16 + ds[1]), float(ds[2] * 16 + ds[3]), float(ds[4] * 16 + ds[5]))
    else: return false
    return true
  if t.startsWith("rgb") or t.startsWith("hsl"):
    let o = t.find('(')
    let e = t.find(')')
    if o < 0 or e < o or e != t.high: return false
    var parts: seq[string]
    for p in t[o + 1 ..< e].multiReplace((",", " "), ("/", " ")).splitWhitespace: parts.add p
    if parts.len notin {3, 4}: return false
    var vals: seq[float]
    var pct: seq[bool]
    for k, p in parts:
      var i = 0
      var x: float
      if not readNum(p, i, x):
        if p == "none":
          x = 0
          i = p.len
        else: return false
      let unit = p[i .. ^1]
      pct.add unit == "%"
      if t.startsWith("hsl") and k == 0:
        case unit
        of "", "deg": discard
        of "rad": x = radToDeg(x)
        of "grad": x = x * 0.9
        of "turn": x = x * 360
        else: return false
      elif unit notin ["", "%"]: return false
      vals.add x
    var a = 255.0
    if vals.len == 4: a = (if pct[3]: vals[3] / 100 else: vals[3]) * 255
    if t.startsWith("rgb"):
      var ch: array[3, float]
      for k in 0 .. 2: ch[k] = if pct[k]: vals[k] * 255 / 100 else: vals[k]
      c = mkColor(clamp(a, 0, 255), clamp(ch[0], 0, 255), clamp(ch[1], 0, 255), clamp(ch[2], 0, 255))
    else:
      let h = floorMod(vals[0], 360.0) / 360
      let s = clamp(vals[1] / 100, 0.0, 1.0)
      let l = clamp(vals[2] / 100, 0.0, 1.0)
      let q = if l < 0.5: l * (1 + s) else: l + s - l * s
      let p = 2 * l - q
      proc hue(t0: float): float =
        var t = t0
        if t < 0: t += 1
        if t > 1: t -= 1
        if t < 1 / 6: p + (q - p) * 6 * t
        elif t < 1 / 2: q
        elif t < 2 / 3: p + (q - p) * (2 / 3 - t) * 6
        else: p
      c = mkColor(clamp(a, 0, 255), hue(h + 1 / 3) * 255, hue(h) * 255, hue(h - 1 / 3) * 255)
    return true
  if t == "transparent":
    c = 0
    return true
  if t in NamedColors:
    c = 0xFF000000'u32 or uint32(NamedColors[t])
    return true
  false

# ---- styles ----------------------------------------------------------------------------------------------

type
  PaintSpec = object
    kind: SvgPaintKind        # spkNone, spkColor, spkCurrent (or a url)
    color: uint32
    url: string               # (a url: the id; kind then the fallback's)
    isUrl, hasFb: bool

  Style = object
    fill, stroke: PaintSpec
    fillOpacity, strokeOpacity: float
    fillEvenOdd, clipEvenOdd: bool
    strokeWidth: float
    cap: LineCap
    join: LineJoin
    miter: float
    dashes: seq[float]
    dashOffset: float
    color: uint32
    colorSet: bool
    visible: bool
    fontSize: float
    strokeFirst: bool
    markerStart, markerMid, markerEnd: string
    # (not inherited)
    opacity: float
    display: bool
    clipPath, mask, filter: string
    stopColor: uint32
    stopCurrent: bool
    stopOpacity: float
    maskAlpha: bool
    overflowVisible: bool
    origin: string
    transform: string             # (a `transform` set by CSS)
    hasTransform: bool
    bg: uint32                    # (background-color: the root's)
    hasBg: bool

const PropNames = ["fill", "fill-opacity", "fill-rule", "stroke", "stroke-width", "stroke-opacity",
                   "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray",
                   "stroke-dashoffset", "color", "visibility", "display", "opacity", "clip-path", "clip-rule",
                   "mask", "filter", "stop-color", "stop-opacity", "font-size", "paint-order", "mask-type",
                   "overflow", "transform-origin", "marker-start", "marker-mid", "marker-end"]

proc defaultStyle(): Style =
  Style(fill: PaintSpec(kind: spkColor, color: 0xFF000000'u32), stroke: PaintSpec(kind: spkNone),
        fillOpacity: 1, strokeOpacity: 1, strokeWidth: 1, cap: lcButt, join: ljMiter, miter: 4,
        color: 0xFF000000'u32, visible: true, fontSize: 16, opacity: 1, display: true,
        stopColor: 0xFF000000'u32, stopOpacity: 1)

proc inherit(p: Style): Style =
  result = p
  result.opacity = 1
  result.display = true
  result.clipPath = ""
  result.mask = ""
  result.filter = ""
  result.stopColor = 0xFF000000'u32
  result.stopCurrent = false
  result.stopOpacity = 1
  result.maskAlpha = false
  result.overflowVisible = false
  result.origin = ""
  result.transform = ""
  result.hasTransform = false
  result.hasBg = false

proc parsePaint(v: string; p: var PaintSpec): bool =
  let t = v.strip
  let low = t.toLowerAscii
  if low == "none": p = PaintSpec(kind: spkNone)
  elif low == "currentcolor": p = PaintSpec(kind: spkCurrent)
  elif low in ["context-fill", "context-stroke"]: p = PaintSpec(kind: spkNone)
  elif low.startsWith("url("):
    let e = t.find(')')
    if e < 0: return false
    var id = t[4 ..< e].strip(chars = Wsp + {'\'', '"'})
    let hashAt = id.find('#')
    id = if hashAt == 0: id[1 .. ^1] else: ""      # (another file's: not there)
    var r = PaintSpec(isUrl: true, url: id, kind: spkNone)
    let rest = t[e + 1 .. ^1].strip
    if rest.len > 0:
      var fb: PaintSpec
      if not parsePaint(rest, fb) or fb.isUrl: return false
      r.kind = fb.kind
      r.color = fb.color
      r.hasFb = true
    p = r
  else:
    var c: uint32
    if not parseColor(t, c): return false
    p = PaintSpec(kind: spkColor, color: c)
  true

proc urlId(v: string): string =
  ## The id of `url(#id)` ("" for none; "\0" for one that cannot be found).
  let t = v.strip
  if t.len == 0 or t.toLowerAscii == "none": return ""
  if not t.toLowerAscii.startsWith("url("): return "\0"
  let e = t.find(')')
  if e < 0: return "\0"
  let id = t[4 ..< e].strip(chars = Wsp + {'\'', '"'})
  if id.startsWith("#") and id.len > 1: id[1 .. ^1] else: "\0"

type
  Ctx = object
    doc: SvgDoc
    ids: Table[string, XNode]
    rules: seq[CssRule]
    vw, vh: float                 # the viewport (for %)
    depth: int
    work: int
    busy: seq[XNode]              # what is being made (uses, clips, masks): no loops
    anc: seq[XNode]               # the elements around (for selectors)
    parents: Table[uint, XNode]   # (each element's parent)

proc skip(c: var Ctx; what: string) = c.doc.skipped.inc(what)

proc parseLen(c: Ctx; s: string; axis: int; v: var float; fontSize = 16.0): bool =
  ## A length (axis 0 x, 1 y, 2 other: for %).
  var i = 0
  skipWsp(s, i)
  var x: float
  if not readNum(s, i, x): return false
  let unit = s[i .. ^1].strip.toLowerAscii
  case unit
  of "", "px": v = x
  of "pt": v = x * 4 / 3
  of "pc": v = x * 16
  of "mm": v = x * 96 / 25.4
  of "cm": v = x * 96 / 2.54
  of "in": v = x * 96
  of "em", "rem": v = x * fontSize
  of "ex": v = x * fontSize / 2
  of "%":
    let base = case axis
               of 0: c.vw
               of 1: c.vh
               else: sqrt((c.vw * c.vw + c.vh * c.vh) / 2)
    v = x / 100 * base
  else: return false
  finite(v)

proc lenAttr(c: Ctx; n: XNode; name: string; axis: int; def = 0.0): float =
  result = def
  let s = n.attr(name)
  if s.len > 0:
    var v: float
    if c.parseLen(s, axis, v): result = v

proc applyProp(c: Ctx; st: var Style; parent: Style; name, value: string) =
  let v = value.strip
  let low = v.toLowerAscii
  if low == "inherit":
    case name
    of "fill": st.fill = parent.fill
    of "stroke": st.stroke = parent.stroke
    of "fill-opacity": st.fillOpacity = parent.fillOpacity
    of "stroke-opacity": st.strokeOpacity = parent.strokeOpacity
    of "fill-rule": st.fillEvenOdd = parent.fillEvenOdd
    of "clip-rule": st.clipEvenOdd = parent.clipEvenOdd
    of "stroke-width": st.strokeWidth = parent.strokeWidth
    of "stroke-linecap": st.cap = parent.cap
    of "stroke-linejoin": st.join = parent.join
    of "stroke-miterlimit": st.miter = parent.miter
    of "stroke-dasharray": st.dashes = parent.dashes
    of "stroke-dashoffset": st.dashOffset = parent.dashOffset
    of "color":
      st.color = parent.color
      st.colorSet = parent.colorSet
    of "visibility": st.visible = parent.visible
    of "opacity": st.opacity = parent.opacity
    of "stop-color":
      st.stopColor = parent.stopColor
      st.stopCurrent = parent.stopCurrent
    of "stop-opacity": st.stopOpacity = parent.stopOpacity
    of "clip-path": st.clipPath = parent.clipPath
    of "mask": st.mask = parent.mask
    of "display": st.display = parent.display
    else: discard
    return
  case name
  of "fill":
    var p: PaintSpec
    if parsePaint(v, p): st.fill = p
  of "stroke":
    var p: PaintSpec
    if parsePaint(v, p): st.stroke = p
  of "fill-opacity": discard parseOpacity(v, st.fillOpacity)
  of "stroke-opacity": discard parseOpacity(v, st.strokeOpacity)
  of "opacity": discard parseOpacity(v, st.opacity)
  of "stop-opacity": discard parseOpacity(v, st.stopOpacity)
  of "fill-rule":
    if low == "evenodd": st.fillEvenOdd = true
    elif low == "nonzero": st.fillEvenOdd = false
  of "clip-rule":
    if low == "evenodd": st.clipEvenOdd = true
    elif low == "nonzero": st.clipEvenOdd = false
  of "stroke-width":
    var w: float
    if c.parseLen(v, 2, w, st.fontSize) and w >= 0: st.strokeWidth = w
  of "stroke-linecap":
    case low
    of "butt": st.cap = lcButt
    of "round": st.cap = lcRound
    of "square": st.cap = lcSquare
    else: discard
  of "stroke-linejoin":
    case low
    of "miter", "miter-clip", "arcs": st.join = ljMiter
    of "round": st.join = ljRound
    of "bevel": st.join = ljBevel
    else: discard
  of "stroke-miterlimit":
    var m: float
    if parseNumber(v, m) and m >= 1: st.miter = m
  of "stroke-dasharray":
    if low == "none":
      st.dashes = @[]
      return
    var ds: seq[float] = @[]
    for p in v.multiReplace((",", " ")).splitWhitespace:
      var d: float
      if not c.parseLen(p, 2, d, st.fontSize) or d < 0: return
      ds.add d
    var total = 0.0
    for d in ds: total += d
    if total <= 0:
      st.dashes = @[]
      return
    if ds.len mod 2 == 1: ds = ds & ds          # (a copy: `add` of itself reads freed memory)
    st.dashes = ds
  of "stroke-dashoffset":
    var d: float
    if c.parseLen(v, 2, d, st.fontSize): st.dashOffset = d
  of "color":
    var col: uint32
    if parseColor(v, col):
      st.color = col
      st.colorSet = true
  of "stop-color":
    if low == "currentcolor":
      st.stopCurrent = true
    else:
      var col: uint32
      if parseColor(v, col):
        st.stopColor = col
        st.stopCurrent = false
  of "visibility": st.visible = low notin ["hidden", "collapse"]
  of "display": st.display = low != "none"
  of "clip-path": st.clipPath = urlId(v)
  of "mask": st.mask = urlId(v)
  of "filter": st.filter = (if low == "none" or low.len == 0: "" else: "f")
  of "font-size":
    var f: float
    if low.endsWith("%"):
      var i = 0
      if readNum(low, i, f): st.fontSize = parent.fontSize * f / 100
    elif c.parseLen(v, 2, f, parent.fontSize) and f > 0: st.fontSize = f
  of "paint-order":
    let w = low.splitWhitespace
    if w.len > 0 and w[0] in ["stroke", "markers"]:
      st.strokeFirst = w[0] == "stroke" or (w.len > 1 and w[1] == "stroke")
    elif w.len > 0: st.strokeFirst = false
  of "mask-type": st.maskAlpha = low == "alpha"
  of "overflow": st.overflowVisible = low in ["visible", "auto"]
  of "transform-origin": st.origin = v
  of "transform":
    st.transform = v
    st.hasTransform = true
  of "marker-start": st.markerStart = urlId(v)
  of "marker-mid": st.markerMid = urlId(v)
  of "marker-end": st.markerEnd = urlId(v)
  of "marker":
    st.markerStart = urlId(v)
    st.markerMid = st.markerStart
    st.markerEnd = st.markerStart
  of "background-color":
    var col: uint32
    if parseColor(v, col):
      st.bg = col
      st.hasBg = true
  else: discard

proc styleOf(c: Ctx; n: XNode; parent: Style): Style =
  ## The element's style: what it inherits, then its attributes, the style
  ## sheet's rules for it (by how specific they are), its `style`.
  result = inherit(parent)
  for (k, v) in n.attrs:
    if k in PropNames: c.applyProp(result, parent, k, v)
  var important: seq[(string, string)]
  if c.rules.len > 0:
    var chain = c.anc
    chain.add n
    var hits: seq[(int, int)]
    for ri, r in c.rules:
      if matches(r, chain): hits.add (r.spec, r.order)
    hits.sort()
    for (sp, o) in hits:
      for (k, v, imp) in c.rules[o].decls:
        if imp: important.add (k, v)
        else: c.applyProp(result, parent, k, v)
  let sa = n.attr("style")
  if sa.len > 0:
    for (k, v, imp) in parseDecls(sa): c.applyProp(result, parent, k, v)
  for (k, v) in important: c.applyProp(result, parent, k, v)

proc chainStyle(c: Ctx; n: XNode): Style =
  ## An element's style where it is in the document (what its ancestors
  ## hand down): for what is used from elsewhere (clip paths, masks,
  ## markers, gradients).
  var up: seq[XNode]
  var p = c.parents.getOrDefault(cast[uint](n))
  while p != nil and up.len < 64:
    up.add p
    p = c.parents.getOrDefault(cast[uint](p))
  result = defaultStyle()
  for k in countdown(up.high, 0):
    if up[k].tag.len > 0: result = c.styleOf(up[k], result)
  result = c.styleOf(n, result)

# ---- transforms ------------------------------------------------------------------------------------------

proc parseTransform(s: string; m: var SvgMatrix): bool =
  var r = IdentityM
  var i = 0
  while true:
    skipSep(s, i)
    if i >= s.len: break
    let i0 = i
    while i < s.len and s[i].isAlphaAscii: inc i
    let name = s[i0 ..< i]
    skipWsp(s, i)
    if name.len == 0 or i >= s.len or s[i] != '(': return false
    inc i
    var args: seq[float]
    while true:
      skipSep(s, i)
      if i < s.len and s[i] == ')':
        inc i
        break
      var v: float
      if not readNum(s, i, v): return false
      # (CSS units)
      if s.continuesWith("deg", i): i += 3
      elif s.continuesWith("grad", i):
        i += 4
        v *= 0.9
      elif s.continuesWith("rad", i):
        i += 3
        v = radToDeg(v)
      elif s.continuesWith("turn", i):
        i += 4
        v *= 360
      elif s.continuesWith("px", i): i += 2
      args.add v
    var t = IdentityM
    case name
    of "matrix":
      if args.len != 6: return false
      t = SvgMatrix(a: args[0], b: args[1], c: args[2], d: args[3], e: args[4], f: args[5])
    of "translate":
      if args.len notin {1, 2}: return false
      t = translateM(args[0], if args.len == 2: args[1] else: 0.0)
    of "scale":
      if args.len notin {1, 2}: return false
      t = scaleM(args[0], if args.len == 2: args[1] else: args[0])
    of "rotate":
      if args.len notin {1, 3}: return false
      let a = degToRad(args[0])
      t = SvgMatrix(a: cos(a), b: sin(a), c: -sin(a), d: cos(a))
      if args.len == 3: t = translateM(args[1], args[2]) * t * translateM(-args[1], -args[2])
    of "skewX":
      if args.len != 1: return false
      t = SvgMatrix(a: 1, d: 1, c: tan(degToRad(args[0])))
    of "skewY":
      if args.len != 1: return false
      t = SvgMatrix(a: 1, d: 1, b: tan(degToRad(args[0])))
    else: return false
    r = r * t
  m = r
  true

proc originOf(c: Ctx; s: string): Pt =
  ## transform-origin (lengths, %, keywords) in user units.
  var xs, ys: string
  let w = s.splitWhitespace
  if w.len == 0: return (0.0, 0.0)
  xs = w[0]
  ys = if w.len > 1: w[1] else: "center"
  if xs in ["top", "bottom"] or ys in ["left", "right"]: swap(xs, ys)
  proc one(c: Ctx; v: string; axis: int): float =
    case v
    of "left", "top": 0.0
    of "center": (if axis == 0: c.vw else: c.vh) / 2
    of "right", "bottom": (if axis == 0: c.vw else: c.vh)
    else:
      var r: float
      if c.parseLen(v, axis, r): r else: 0.0
  (c.one(xs, 0), c.one(ys, 1))

proc localTransform(c: Ctx; n: XNode; st: Style): SvgMatrix =
  result = IdentityM
  let t = if st.hasTransform: st.transform else: n.attr("transform")
  if t.len > 0:
    var m: SvgMatrix
    if parseTransform(t, m): result = m
  if st.origin.len > 0 and t.len > 0:
    let o = c.originOf(st.origin)
    result = translateM(o[0], o[1]) * result * translateM(-o[0], -o[1])

proc viewBoxOf(s: string; vb: var (float, float, float, float)): bool =
  let v = numbers(s)
  if v.len != 4 or v[2] <= 0 or v[3] <= 0: return false
  vb = (v[0], v[1], v[2], v[3])
  true

proc aspectOf(s: string): (float, float, bool) =
  ## preserveAspectRatio: (align x, align y (-1: none), slice).
  result = (0.5, 0.5, false)
  var w = s.splitWhitespace
  if w.len > 0 and w[0] == "defer": w.delete(0)
  if w.len == 0: return
  let a = w[0]
  if a == "none": result = (-1.0, -1.0, false)
  elif a.len == 8 and a[0] == 'x' and a[4] == 'Y':
    proc al(p: string): float =
      case p
      of "Min": 0.0
      of "Max": 1.0
      else: 0.5
    result = (al(a[1 .. 3]), al(a[5 .. 7]), false)
  if w.len > 1 and w[1] == "slice": result[2] = true

proc viewBoxTransform(vb: (float, float, float, float); ax, ay: float; slice: bool; w, h: float): SvgMatrix =
  ## The view box fitted into `w` x `h`.
  let sx = w / vb[2]
  let sy = h / vb[3]
  if ax < 0: return scaleM(sx, sy) * translateM(-vb[0], -vb[1])
  let s = if slice: max(sx, sy) else: min(sx, sy)
  translateM((w - vb[2] * s) * ax - vb[0] * s, (h - vb[3] * s) * ay - vb[1] * s) * scaleM(s, s)

# ---- outlines of the elements ----------------------------------------------------------------------------

proc parsePathData*(d: string): Path =
  ## SVG path data (every command, upper or lower case, arcs as cubic
  ## curves) as an outline; it stops at an error, keeping what came before.
  var b: PB
  var i = 0
  var cmd = '\0'
  var prev = '\0'
  var ctl: Pt
  var first = true
  var guard = 0
  while true:
    inc guard
    if guard > 50_000_000: break
    skipSep(d, i)
    if i >= d.len: break
    let ch = d[i]
    if ch.isAlphaAscii:
      if ch notin "MmZzLlHhVvCcSsQqTtAa": break
      if first and ch notin {'M', 'm'}: break
      first = false
      cmd = ch
      inc i
      if cmd in {'Z', 'z'}:
        b.closeSub()
        prev = 'Z'
        continue
    elif cmd == '\0' or cmd in {'Z', 'z'}: break
    let rel = cmd in {'a' .. 'z'}
    let o = if rel: b.pen else: (0.0, 0.0)
    var x, y, x1, y1, x2, y2: float
    template num(v: untyped): bool = (skipSep(d, i); readNum(d, i, v))
    case cmd
    of 'M', 'm':
      if not (num(x) and num(y)): break
      b.moveTo((o[0] + x, o[1] + y))
      cmd = if rel: 'l' else: 'L'
      prev = 'M'
    of 'L', 'l':
      if not (num(x) and num(y)): break
      b.lineTo((o[0] + x, o[1] + y))
      prev = 'L'
    of 'H', 'h':
      if not num(x): break
      b.lineTo(((if rel: b.pen[0] else: 0.0) + x, b.pen[1]))
      prev = 'L'
    of 'V', 'v':
      if not num(y): break
      b.lineTo((b.pen[0], (if rel: b.pen[1] else: 0.0) + y))
      prev = 'L'
    of 'C', 'c':
      if not (num(x1) and num(y1) and num(x2) and num(y2) and num(x) and num(y)): break
      let c2 = (o[0] + x2, o[1] + y2)
      b.cubicTo((o[0] + x1, o[1] + y1), c2, (o[0] + x, o[1] + y))
      ctl = c2
      prev = 'C'
    of 'S', 's':
      if not (num(x2) and num(y2) and num(x) and num(y)): break
      let c1 = if prev == 'C': (2 * b.pen[0] - ctl[0], 2 * b.pen[1] - ctl[1]) else: b.pen
      let c2 = (o[0] + x2, o[1] + y2)
      b.cubicTo(c1, c2, (o[0] + x, o[1] + y))
      ctl = c2
      prev = 'C'
    of 'Q', 'q', 'T', 't':
      var q: Pt
      if cmd in {'Q', 'q'}:
        if not (num(x1) and num(y1)): break
        q = (o[0] + x1, o[1] + y1)
      else:
        q = if prev == 'Q': (2 * b.pen[0] - ctl[0], 2 * b.pen[1] - ctl[1]) else: b.pen
      if not (num(x) and num(y)): break
      let p0 = b.pen
      let p = (o[0] + x, o[1] + y)
      b.cubicTo((p0[0] + (q[0] - p0[0]) * 2 / 3, p0[1] + (q[1] - p0[1]) * 2 / 3),
                (p[0] + (q[0] - p[0]) * 2 / 3, p[1] + (q[1] - p[1]) * 2 / 3), p)
      ctl = q
      prev = 'Q'
    of 'A', 'a':
      var rot: float
      var large, sweep: bool
      if not (num(x1) and num(y1) and num(rot) and readFlag(d, i, large) and readFlag(d, i, sweep) and
              num(x) and num(y)): break
      b.arcTo(x1, y1, rot, large, sweep, (o[0] + x, o[1] + y))
      prev = 'A'
    else: break
  b.finish()

proc shapePath(c: Ctx; n: XNode; fontSize: float): Path =
  ## The outline of a basic shape in its own user space (empty: none).
  var b: PB
  case n.tag
  of "path": return parsePathData(n.attr("d"))
  of "rect":
    let x = c.lenAttr(n, "x", 0)
    let y = c.lenAttr(n, "y", 1)
    let w = c.lenAttr(n, "width", 0)
    let h = c.lenAttr(n, "height", 1)
    if not (w > 0 and h > 0): return
    var rx, ry: float
    let hasRx = n.has("rx") and c.parseLen(n.attr("rx"), 0, rx, fontSize) and rx >= 0
    let hasRy = n.has("ry") and c.parseLen(n.attr("ry"), 1, ry, fontSize) and ry >= 0
    if not hasRx and not hasRy:
      rx = 0
      ry = 0
    elif not hasRy: ry = rx
    elif not hasRx: rx = ry
    rx = min(rx, w / 2)
    ry = min(ry, h / 2)
    if rx <= 0 or ry <= 0:
      b.moveTo((x, y))
      b.lineTo((x + w, y))
      b.lineTo((x + w, y + h))
      b.lineTo((x, y + h))
      b.closeSub()
    else:
      let kx = rx * Kap
      let ky = ry * Kap
      b.moveTo((x + rx, y))
      b.lineTo((x + w - rx, y))
      b.cubicTo((x + w - rx + kx, y), (x + w, y + ry - ky), (x + w, y + ry))
      b.lineTo((x + w, y + h - ry))
      b.cubicTo((x + w, y + h - ry + ky), (x + w - rx + kx, y + h), (x + w - rx, y + h))
      b.lineTo((x + rx, y + h))
      b.cubicTo((x + rx - kx, y + h), (x, y + h - ry + ky), (x, y + h - ry))
      b.lineTo((x, y + ry))
      b.cubicTo((x, y + ry - ky), (x + rx - kx, y), (x + rx, y))
      b.closeSub()
  of "circle":
    let r = c.lenAttr(n, "r", 2)
    if not (r > 0): return
    b.ellipseTo(c.lenAttr(n, "cx", 0), c.lenAttr(n, "cy", 1), r, r)
  of "ellipse":
    var rx, ry: float
    let hasRx = n.has("rx") and c.parseLen(n.attr("rx"), 0, rx, fontSize) and rx >= 0
    let hasRy = n.has("ry") and c.parseLen(n.attr("ry"), 1, ry, fontSize) and ry >= 0
    if not hasRx and not hasRy: return
    if not hasRx: rx = ry
    if not hasRy: ry = rx
    if not (rx > 0 and ry > 0): return
    b.ellipseTo(c.lenAttr(n, "cx", 0), c.lenAttr(n, "cy", 1), rx, ry)
  of "line":
    b.moveTo((c.lenAttr(n, "x1", 0), c.lenAttr(n, "y1", 1)))
    b.lineTo((c.lenAttr(n, "x2", 0), c.lenAttr(n, "y2", 1)))
  of "polyline", "polygon":
    let v = numbers(n.attr("points"))
    if v.len < 4: return
    b.moveTo((v[0], v[1]))
    var k = 2
    while k + 1 < v.len:
      b.lineTo((v[k], v[k + 1]))
      k += 2
    if n.tag == "polygon": b.closeSub()
  else: discard
  b.finish()

# ---- paints ----------------------------------------------------------------------------------------------

proc gradAttr(chain: seq[XNode]; name: string): string =
  for g in chain:
    if g.has(name): return g.attr(name)
  ""

proc gradientOf(c: var Ctx; node: XNode; st: Style; bb: Box; m: SvgMatrix): SvgPaint =
  ## A gradient for an element (its box `bb` in its own space, which `m`
  ## takes to user space).
  var chain = @[node]
  var g = node
  while chain.len < 16:
    let h = g.hrefOf
    if not h.startsWith("#"): break
    let t = c.ids.getOrDefault(h[1 .. ^1])
    if t == nil or t in chain or t.tag notin ["linearGradient", "radialGradient"]: break
    chain.add t
    g = t
  # the stops: the first in the chain with any
  var stops: seq[SvgStop]
  for gn in chain:
    var any = false
    for k in gn.kids:
      if k.tag != "stop": continue
      any = true
      var off = 0.0
      let os = k.attr("offset").strip
      var i = 0
      if readNum(os, i, off):
        if i < os.len and os[i] == '%':
          off /= 100
          inc i
        if os[i .. ^1].strip.len > 0: off = 0
      else: off = 0
      off = clamp(off, 0.0, 1.0)
      if stops.len > 0: off = max(off, stops[^1].offset)
      let ks = c.styleOf(k, c.chainStyle(gn))
      var col = ks.stopColor
      let a = float(col shr 24) / 255 * ks.stopOpacity
      col = (col and 0xFFFFFF'u32) or (uint32(clamp(int(round(a * 255)), 0, 255)) shl 24)
      var cur = false
      if ks.stopCurrent:
        if ks.colorSet: col = (ks.color and 0xFFFFFF'u32) or (uint32(clamp(int(round(
                                float(ks.color shr 24) * ks.stopOpacity)), 0, 255)) shl 24)
        elif st.colorSet: col = (st.color and 0xFFFFFF'u32) or (uint32(clamp(int(round(
                                float(st.color shr 24) * ks.stopOpacity)), 0, 255)) shl 24)
        else:
          cur = true
          col = uint32(clamp(int(round(ks.stopOpacity * 255)), 0, 255)) shl 24
      stops.add SvgStop(offset: off, color: col, current: cur)
    if any: break
  if stops.len == 0: return SvgPaint(kind: spkNone)
  if stops.len == 1:
    if stops[0].current: return SvgPaint(kind: spkCurrent, color: stops[0].color)
    return SvgPaint(kind: spkColor, color: stops[0].color)
  let obb = chain.gradAttr("gradientUnits").strip != "userSpaceOnUse"
  var gt = IdentityM
  let gts = chain.gradAttr("gradientTransform")
  if gts.len > 0:
    var t: SvgMatrix
    if parseTransform(gts, t): gt = t
  let spread = case chain.gradAttr("spreadMethod").strip
               of "reflect": ssReflect
               of "repeat": ssRepeat
               else: ssPad
  var base = m
  if obb:
    if empty(bb) or bb[2] - bb[0] <= 1e-12 or bb[3] - bb[1] <= 1e-12: return SvgPaint(kind: spkNone)
    base = m * SvgMatrix(a: bb[2] - bb[0], d: bb[3] - bb[1], e: bb[0], f: bb[1])
  var same: seq[XNode]
  for g in chain:
    if g.tag == node.tag: same.add g
  proc coord(c: Ctx; name: string; axis: int; def: string): float =
    var s = same.gradAttr(name)
    if s.len == 0: s = def
    let t = s.strip
    if obb:
      var i = 0
      var v: float
      if not readNum(t, i, v):
        i = 0
        discard readNum(def, i, v)
        return (if def.endsWith("%"): v / 100 else: v)
      if i < t.len and t[i] == '%': v /= 100
      return v
    var v: float
    if c.parseLen(t, axis, v): return v
    var d: float
    discard c.parseLen(def, axis, d)
    d
  let last = stops[^1]
  var r = SvgPaint(stops: stops, m: base * gt, spread: spread)
  if node.tag == "linearGradient":
    r.kind = spkLinear
    r.p0 = (c.coord("x1", 0, "0%"), c.coord("y1", 1, "0%"))
    r.p1 = (c.coord("x2", 0, "100%"), c.coord("y2", 1, "0%"))
    if near(r.p0, r.p1): return SvgPaint(kind: (if last.current: spkCurrent else: spkColor), color: last.color)
  else:
    r.kind = spkRadial
    let cx = c.coord("cx", 0, "50%")
    let cy = c.coord("cy", 1, "50%")
    r.r = c.coord("r", 2, "50%")
    var fx = cx
    var fy = cy
    if same.gradAttr("fx").len > 0: fx = c.coord("fx", 0, "50%")
    if same.gradAttr("fy").len > 0: fy = c.coord("fy", 1, "50%")
    r.fr = max(0.0, c.coord("fr", 2, "0%"))
    if r.r <= 1e-12: return SvgPaint(kind: (if last.current: spkCurrent else: spkColor), color: last.color)
    r.p0 = (cx, cy)
    r.p1 = (fx, fy)
  if not (finite(r.m.a) and finite(r.m.b) and finite(r.m.c) and finite(r.m.d) and finite(r.m.e) and
          finite(r.m.f)) or abs(det(r.m)) < 1e-300:
    return SvgPaint(kind: (if last.current: spkCurrent else: spkColor), color: last.color)
  r

proc paintOf(c: var Ctx; p: PaintSpec; st: Style; bb: Box; m: SvgMatrix): SvgPaint =
  if p.isUrl:
    let node = if p.url.len > 0: c.ids.getOrDefault(p.url) else: nil
    if node != nil and node.tag in ["linearGradient", "radialGradient"]:
      let g = c.gradientOf(node, st, bb, m)
      if g.kind != spkNone or not p.hasFb: return g
    if node != nil and node.tag == "pattern": c.skip("pattern")
    if not p.hasFb: return SvgPaint(kind: spkNone)
  case p.kind
  of spkColor: SvgPaint(kind: spkColor, color: p.color)
  of spkCurrent:
    if st.colorSet: SvgPaint(kind: spkColor, color: st.color) else: SvgPaint(kind: spkCurrent, color: 0xFF000000'u32)
  else: SvgPaint(kind: spkNone)

# ---- walking the document --------------------------------------------------------------------------------

const Drawn = ["svg", "g", "a", "switch", "use", "path", "rect", "circle", "ellipse", "line", "polyline",
               "polygon"]
const ShapeTags = ["path", "rect", "circle", "ellipse", "line", "polyline", "polygon"]

proc walk(c: var Ctx; n: XNode; ps: Style; m: SvgMatrix)
proc effects(c: var Ctx; start: int; st: Style; m: SvgMatrix)

proc itemsBounds(c: Ctx; start: int; inv: SvgMatrix; items: seq[SvgItem]): Box =
  result = NoBox
  for k in start ..< items.len: result = union(result, tightBounds(items[k].path, inv))

proc rectPathM(x, y, w, h: float; m: SvgMatrix): Path =
  var b: PB
  b.moveTo(m.apply((x, y)))
  b.lineTo(m.apply((x + w, y)))
  b.lineTo(m.apply((x + w, y + h)))
  b.lineTo(m.apply((x, y + h)))
  b.closeSub()
  b.finish()

proc addClip(c: var Ctx; clip: var SvgClip): int =
  clip.bounds = NoBox
  for part in clip.parts: clip.bounds = union(clip.bounds, tightBounds(part.path))
  clip.rect = false
  if clip.parts.len == 1 and clip.parts[0].path.subs.len == 1 and clip.parts[0].clips.len == 0:
    let s = clip.parts[0].path.subs[0]
    if s.pts.len == 4 and s.closed:
      var axis = true
      for k in 0 .. 3:
        let a = s.pts[k]
        let b = s.pts[(k + 1) mod 4]
        if a.outH != a.p or b.inH != b.p or (abs(a.p[0] - b.p[0]) > 1e-9 and abs(a.p[1] - b.p[1]) > 1e-9):
          axis = false
      clip.rect = axis
  c.doc.clips.add clip
  c.doc.clips.high

proc rectClip(c: var Ctx; x, y, w, h: float; m: SvgMatrix): int =
  var clip = SvgClip(parts: @[SvgClipPart(path: rectPathM(x, y, w, h, m))])
  c.addClip(clip)

proc clipOf(c: var Ctx; id: string; m: SvgMatrix; start: int; box = NoBox): int =
  ## A clip path for the items from `start` (or what has the box `box`),
  ## made in the space `m`: its index; -1 none (not one), -2 one that
  ## hides all.
  let node = c.ids.getOrDefault(id)
  if node == nil or node.tag != "clipPath": return -1
  if node in c.busy or c.depth > MaxDepth: return -1
  c.busy.add node
  defer: discard c.busy.pop()
  let cs = c.chainStyle(node)
  var cm = m * c.localTransform(node, cs)
  if node.attr("clipPathUnits").strip == "objectBoundingBox":
    let bb = if empty(box): c.itemsBounds(start, invert(m), c.doc.items) else: box
    if empty(bb) or bb[2] - bb[0] <= 0 or bb[3] - bb[1] <= 0: return -2
    cm = cm * SvgMatrix(a: bb[2] - bb[0], d: bb[3] - bb[1], e: bb[0], f: bb[1])
  var clip = SvgClip()
  for k in node.kids:
    var el = k
    var km = cm
    var ks = c.styleOf(k, cs)
    if not ks.display: continue
    km = km * c.localTransform(k, ks)
    if k.tag == "use":
      # (to a shape: through uses of uses too)
      var u = k
      var ok = true
      for hop in 0 .. 8:
        let h = u.hrefOf
        let t = if h.startsWith("#"): c.ids.getOrDefault(h[1 .. ^1]) else: nil
        if t == nil or t == u or (t.tag notin ShapeTags and t.tag != "use"):
          ok = false
          break
        km = km * translateM(c.lenAttr(u, "x", 0), c.lenAttr(u, "y", 1))
        ks = c.styleOf(t, ks)
        if not ks.display:
          ok = false
          break
        km = km * c.localTransform(t, ks)
        u = t
        if t.tag != "use": break
      if not ok or u.tag notin ShapeTags: continue
      el = u
    elif k.tag in ["text"]:
      c.skip("text")
      continue
    elif k.tag notin ShapeTags: continue
    if not ks.visible: continue
    let p = c.shapePath(el, ks.fontSize)
    if p.subs.len == 0: continue
    var part = SvgClipPart(path: p.transformed(km), evenOdd: ks.clipEvenOdd)
    if ks.clipPath.len > 0:
      if ks.clipPath == "\0": continue
      let inner = c.clipOf(ks.clipPath, km, -1, tightBounds(p))
      if inner == -2: continue                     # (cut away entirely)
      if inner >= 0: part.clips.add inner
    clip.parts.add part
  if cs.clipPath.len > 0 and cs.clipPath != "\0":
    let inner = c.clipOf(cs.clipPath, m, start, box)
    if inner == -2: return -2
    if inner >= 0: clip.clips.add inner
  if clip.parts.len == 0: return -2
  c.addClip(clip)

proc simpleMask(items: seq[SvgItem]; alpha: bool): bool =
  ## (a mask of white shapes only: a clip path)
  if items.len == 0: return false
  for it in items:
    if it.layers.len > 0 or it.clips.len > 0: return false
    if it.stroke.kind != spkNone and it.strokeWidth > 0: return false
    if it.fill.kind != spkColor: return false
    let col = it.fill.color
    if (col shr 24) != 255 or it.fillOpacity < 0.999 or it.opacity < 0.999: return false
    if not alpha and (col and 0xFFFFFF'u32) != 0xFFFFFF'u32: return false
  true

proc maskOf(c: var Ctx; id: string; m: SvgMatrix; start: int; asClip: var int): int =
  ## A mask for the items from `start`: its index (-1 none, -2 hides all);
  ## or, when it only cuts out, a clip path (`asClip`).
  asClip = -1
  let node = c.ids.getOrDefault(id)
  if node == nil or node.tag != "mask": return -1
  if node in c.busy or c.depth > MaxDepth: return -1
  c.busy.add node
  defer: discard c.busy.pop()
  let ms = c.chainStyle(node)
  let inv = invert(m)
  let bb = c.itemsBounds(start, inv, c.doc.items)
  let bw = bb[2] - bb[0]
  let bh = bb[3] - bb[1]
  # its rectangle
  var rx, ry, rw, rh: float
  if node.attr("maskUnits").strip == "userSpaceOnUse":
    rx = c.lenAttr(node, "x", 0, -0.1 * c.vw)
    ry = c.lenAttr(node, "y", 1, -0.1 * c.vh)
    rw = c.lenAttr(node, "width", 0, 1.2 * c.vw)
    rh = c.lenAttr(node, "height", 1, 1.2 * c.vh)
  else:
    if empty(bb) or bw <= 0 or bh <= 0: return -2
    proc frac(s: string; def: float): float =
      let t = s.strip
      var i = 0
      var v: float
      if not readNum(t, i, v): return def
      if i < t.len and t[i] == '%': v /= 100
      v
    rx = bb[0] + frac(node.attr("x"), -0.1) * bw
    ry = bb[1] + frac(node.attr("y"), -0.1) * bh
    rw = frac(node.attr("width"), 1.2) * bw
    rh = frac(node.attr("height"), 1.2) * bh
  if not (rw > 0 and rh > 0): return -2
  var cm = m
  if node.attr("maskContentUnits").strip == "objectBoundingBox":
    if empty(bb) or bw <= 0 or bh <= 0: return -2
    cm = m * SvgMatrix(a: bw, d: bh, e: bb[0], f: bb[1])
  # its content
  let saved = move(c.doc.items)
  c.doc.items = @[]
  let savedAnc = c.anc
  c.anc = @[node]
  for k in node.kids: c.walk(k, ms, cm)
  if ms.mask.len > 0 and ms.mask != "\0":
    # (a mask on the mask)
    var only = defaultStyle()
    only.mask = ms.mask
    c.effects(0, only, m)
  c.anc = savedAnc
  var items = move(c.doc.items)
  c.doc.items = saved
  items.keepItIf(not it.ghost)
  if items.len == 0: return -2
  let regionBox = tightBounds(rectPathM(rx, ry, rw, rh, IdentityM))
  let contentBox = c.itemsBounds(0, inv, items)
  let regionNeeded = not (regionBox[0] <= contentBox[0] and regionBox[1] <= contentBox[1] and
                          regionBox[2] >= contentBox[2] and regionBox[3] >= contentBox[3])
  let region = if regionNeeded: c.rectClip(rx, ry, rw, rh, m) else: -1
  if simpleMask(items, ms.maskAlpha):
    var clip = SvgClip()
    for it in items: clip.parts.add SvgClipPart(path: it.path, evenOdd: it.evenOdd)
    if region >= 0: clip.clips.add region
    asClip = c.addClip(clip)
    return -1
  c.skip("mask")
  c.doc.masks.add SvgMask(items: items, alpha: ms.maskAlpha, region: region)
  c.doc.masks.high

proc hide(c: var Ctx; start: int) =
  for k in start ..< c.doc.items.len: c.doc.items[k].ghost = true

proc effects(c: var Ctx; start: int; st: Style; m: SvgMatrix) =
  ## An element's clip path, mask, opacity on what it drew (from `start`).
  var cnt = 0
  for k in start ..< c.doc.items.len:
    if not c.doc.items[k].ghost: inc cnt
  if cnt <= 0: return
  if st.filter.len > 0: c.skip("filter")
  if st.opacity <= 0:
    c.hide(start)
    return
  if st.clipPath.len > 0 and st.clipPath != "\0":
    let ci = c.clipOf(st.clipPath, m, start)
    if ci == -2:
      c.hide(start)
      return
    if ci >= 0:
      for k in start ..< c.doc.items.len: c.doc.items[k].clips.add ci
  var mi = -1
  if st.mask.len > 0 and st.mask != "\0":
    var asClip = -1
    mi = c.maskOf(st.mask, m, start, asClip)
    if mi == -2:
      c.hide(start)
      return
    if asClip >= 0:
      for k in start ..< c.doc.items.len: c.doc.items[k].clips.add asClip
  if mi >= 0 or (st.opacity < 1 and cnt > 1):
    c.doc.groups.add SvgGroup(opacity: (if cnt > 1: st.opacity else: 1.0), mask: mi)
    let g = c.doc.groups.high
    for k in start ..< c.doc.items.len: c.doc.items[k].layers.insert(g, 0)
  if st.opacity < 1 and cnt == 1:
    for k in start ..< c.doc.items.len:
      if not c.doc.items[k].ghost: c.doc.items[k].opacity *= st.opacity

proc hasArea(p: Path): bool =
  ## (an outline that encloses something: one that is not only lines back and forth)
  for sp in p.subs:
    if sp.pts.len < 2: continue
    let q = polyOf(sp)
    if q.len >= 3 and abs(areaOf(q)) > 1e-12: return true
  false

proc addItem(c: var Ctx; n: XNode; local: Path; st: Style; m: SvgMatrix) =
  if c.doc.items.len >= MaxItems: return
  if not st.visible:
    c.doc.items.add SvgItem(id: n.attr("id"), kind: n.tag, path: local.transformed(m), ctm: m, ghost: true)
    return
  let bb = tightBounds(local)
  var it = SvgItem(id: n.attr("id"), kind: n.tag, fillOpacity: st.fillOpacity, strokeOpacity: st.strokeOpacity,
                   opacity: 1, evenOdd: st.fillEvenOdd, cap: st.cap, join: st.join, miterLimit: st.miter,
                   strokeFirst: st.strokeFirst, ctm: m)
  if n.tag != "line" and hasArea(local): it.fill = c.paintOf(st.fill, st, bb, m)
  let k = scaleOf(m)
  if st.strokeWidth > 0 and st.stroke.kind != spkNone or st.stroke.isUrl:
    it.stroke = c.paintOf(st.stroke, st, bb, m)
  it.strokeWidth = st.strokeWidth * k
  for d in st.dashes: it.dashes.add d * k
  it.dashOffset = st.dashOffset * k
  let fillOn = it.fill.kind != spkNone and it.fillOpacity > 0
  let strokeOn = it.stroke.kind != spkNone and it.strokeWidth > 0 and it.strokeOpacity > 0
  if not fillOn: it.fill = SvgPaint(kind: spkNone)
  if not strokeOn: it.stroke = SvgPaint(kind: spkNone)
  it.path = local.transformed(m)
  if not fillOn and not strokeOn: it.ghost = true
  c.doc.items.add it

proc passes(n: XNode): bool =
  ## (a `switch`'s child: its conditions hold)
  if n.has("requiredExtensions"): return false
  if n.has("systemLanguage"):
    var ok = false
    for l in n.attr("systemLanguage").split(','):
      let t = l.strip.toLowerAscii
      if t == "en" or t.startsWith("en-"): ok = true
    if not ok: return false
  true

proc viewport(c: var Ctx; n: XNode; st: Style; m: SvgMatrix; x, y, w, h: float; kids: seq[XNode];
              vbNode: XNode) =
  ## A nested viewport (svg, symbol): its view box in `w` x `h` at `x`, `y`.
  if not (w > 0 and h > 0): return
  var vb: (float, float, float, float)
  var inner = m * translateM(x, y)
  let (sw, sh) = (c.vw, c.vh)
  if viewBoxOf(vbNode.attr("viewBox"), vb):
    let (ax, ay, sl) = aspectOf(vbNode.attr("preserveAspectRatio"))
    inner = inner * viewBoxTransform(vb, ax, ay, sl, w, h)
    c.vw = vb[2]
    c.vh = vb[3]
  else:
    c.vw = w
    c.vh = h
  let start = c.doc.items.len
  for k in kids: c.walk(k, st, inner)
  c.vw = sw
  c.vh = sh
  if not st.overflowVisible and c.doc.items.len > start:
    # (a clip that holds all of it: not needed)
    let cb = tightBounds(rectPathM(x, y, w, h, m))
    let ib = c.itemsBounds(start, IdentityM, c.doc.items)
    if not (cb[0] <= ib[0] and cb[1] <= ib[1] and cb[2] >= ib[2] and cb[3] >= ib[3]):
      let ci = c.rectClip(x, y, w, h, m)
      for k in start ..< c.doc.items.len: c.doc.items[k].clips.add ci

proc parseAngle(s: string): float =
  var i = 0
  let t = s.strip
  if not readNum(t, i, result): return 0
  let u = t[i .. ^1].strip
  case u
  of "rad": result = radToDeg(result)
  of "grad": result *= 0.9
  of "turn": result *= 360
  else: discard

proc markerAt(c: var Ctx; node: XNode; st: Style; m: SvgMatrix; v: Pt; angle: float) =
  ## One marker drawn at `v` turned by `angle` degrees.
  let ms = c.chainStyle(node)
  let mw = c.lenAttr(node, "markerWidth", 0, 3)
  let mh = c.lenAttr(node, "markerHeight", 1, 3)
  if not (mw > 0 and mh > 0): return
  let a = degToRad(angle)
  var t = m * translateM(v[0], v[1]) * SvgMatrix(a: cos(a), b: sin(a), c: -sin(a), d: cos(a))
  if node.attr("markerUnits").strip != "userSpaceOnUse": t = t * scaleM(st.strokeWidth, st.strokeWidth)
  var vbm = IdentityM
  var vb: (float, float, float, float)
  let hasVb = viewBoxOf(node.attr("viewBox"), vb)
  if hasVb:
    let (ax, ay, sl) = aspectOf(node.attr("preserveAspectRatio"))
    vbm = viewBoxTransform(vb, ax, ay, sl, mw, mh)
  let rp = vbm.apply((c.lenAttr(node, "refX", 0), c.lenAttr(node, "refY", 1)))
  t = t * translateM(-rp[0], -rp[1])
  let clipM = t
  t = t * vbm
  if not (finite(t.a) and finite(t.b) and finite(t.c) and finite(t.d) and finite(t.e) and finite(t.f)): return
  c.busy.add node
  let savedAnc = c.anc
  c.anc = @[node]
  let (sw, sh) = (c.vw, c.vh)
  c.vw = if hasVb: vb[2] else: mw
  c.vh = if hasVb: vb[3] else: mh
  let start = c.doc.items.len
  for k in node.kids: c.walk(k, ms, t)
  c.vw = sw
  c.vh = sh
  c.anc = savedAnc
  discard c.busy.pop()
  if not ms.overflowVisible and c.doc.items.len > start:
    let cb = tightBounds(rectPathM(0, 0, mw, mh, clipM))
    let ib = c.itemsBounds(start, IdentityM, c.doc.items)
    if not (cb[0] <= ib[0] and cb[1] <= ib[1] and cb[2] >= ib[2] and cb[3] >= ib[3]):
      let ci = c.rectClip(0, 0, mw, mh, clipM)
      for k in start ..< c.doc.items.len: c.doc.items[k].clips.add ci

proc markers(c: var Ctx; n: XNode; local: Path; st: Style; m: SvgMatrix) =
  ## The markers on a path's vertices (marker-start, -mid, -end).
  if st.markerStart.len == 0 and st.markerMid.len == 0 and st.markerEnd.len == 0: return
  if n.tag notin ["path", "line", "polyline", "polygon"]: return
  proc nz(v: Pt): bool = abs(v[0]) > 1e-12 or abs(v[1]) > 1e-12
  proc sub(a, b: Pt): Pt = (a[0] - b[0], a[1] - b[1])
  proc startTan(a, b: PathPoint): Pt =
    for d in [sub(a.outH, a.p), sub(b.inH, a.p), sub(b.p, a.p)]:
      if nz(d): return d
    (0.0, 0.0)
  proc endTan(a, b: PathPoint): Pt =
    for d in [sub(b.p, b.inH), sub(b.p, a.outH), sub(b.p, a.p)]:
      if nz(d): return d
    (0.0, 0.0)
  type V = object
    p: Pt
    din, dout: Pt
    hasIn, hasOut: bool
  var vs: seq[V]
  for s in local.subs:
    let np = s.pts.len
    if np == 0: continue
    let segs = if s.closed: np else: np - 1
    for k in 0 ..< np:
      var v = V(p: s.pts[k].p)
      if k > 0:
        v.din = endTan(s.pts[k - 1], s.pts[k])
        v.hasIn = true
      elif s.closed:
        v.din = endTan(s.pts[np - 1], s.pts[0])
        v.hasIn = true
      if k < segs:
        v.dout = startTan(s.pts[k], s.pts[(k + 1) mod np])
        v.hasOut = true
      vs.add v
    if s.closed:
      vs.add V(p: s.pts[0].p, din: endTan(s.pts[np - 1], s.pts[0]), hasIn: true,
               dout: startTan(s.pts[0], s.pts[1 mod np]), hasOut: true)
    if vs.len > 100_000: break
  for i, v in vs:
    let id = if i == 0: st.markerStart elif i == vs.high: st.markerEnd else: st.markerMid
    if id.len == 0 or id == "\0": continue
    let node = c.ids.getOrDefault(id)
    if node == nil or node.tag != "marker" or node in c.busy or c.depth >= MaxDepth: continue
    if c.doc.items.len >= MaxItems or c.work >= MaxWork: return
    let orient = node.attr("orient").strip
    var ang = 0.0
    if orient in ["auto", "auto-start-reverse"]:
      let a1 = radToDeg(arctan2(v.din[1], v.din[0]))
      let a2 = radToDeg(arctan2(v.dout[1], v.dout[0]))
      ang = if v.hasIn and v.hasOut:
              (let h = (a1 + a2) / 2; if abs(a1 - a2) > 180: h - 180 else: h)
            elif v.hasIn: a1
            else: a2
      if orient == "auto-start-reverse" and i == 0: ang += 180
    elif orient.len > 0: ang = parseAngle(orient)
    c.markerAt(node, st, m, v.p, ang)

proc walk(c: var Ctx; n: XNode; ps: Style; m: SvgMatrix) =
  if c.depth >= MaxDepth or c.work >= MaxWork or c.doc.items.len >= MaxItems: return
  inc c.work
  let tag = n.tag
  if tag in ["text", "image", "foreignObject"]:
    c.skip(tag)
    return
  if tag notin Drawn: return
  let st = c.styleOf(n, ps)
  if not st.display: return
  if st.clipPath == "\0" or st.mask == "\0": return     # (a link to nothing: not drawn)
  let mm = m * c.localTransform(n, st)
  if not (finite(mm.a) and finite(mm.b) and finite(mm.c) and finite(mm.d) and finite(mm.e) and finite(mm.f)):
    return
  inc c.depth
  c.anc.add n
  let start = c.doc.items.len
  case tag
  of "g", "a":
    for k in n.kids: c.walk(k, st, mm)
  of "switch":
    for k in n.kids:
      if k.tag in Drawn and k.passes:
        c.walk(k, st, mm)
        break
  of "svg":
    c.viewport(n, st, mm, c.lenAttr(n, "x", 0), c.lenAttr(n, "y", 1), c.lenAttr(n, "width", 0, c.vw),
               c.lenAttr(n, "height", 1, c.vh), n.kids, n)
  of "use":
    let h = n.hrefOf
    let t = if h.startsWith("#"): c.ids.getOrDefault(h[1 .. ^1]) else: nil
    if t != nil and t notin c.busy and t notin c.anc:
      c.busy.add t
      let um = mm * translateM(c.lenAttr(n, "x", 0), c.lenAttr(n, "y", 1))
      if t.tag == "symbol":
        let ts = c.styleOf(t, st)
        if ts.display:
          let w = if n.has("width"): c.lenAttr(n, "width", 0) else: c.lenAttr(t, "width", 0, c.vw)
          let hh = if n.has("height"): c.lenAttr(n, "height", 1) else: c.lenAttr(t, "height", 1, c.vh)
          let sm = um
          c.anc.add t
          let s0 = c.doc.items.len
          c.viewport(t, ts, sm, c.lenAttr(t, "x", 0), c.lenAttr(t, "y", 1), w, hh, t.kids, t)
          c.effects(s0, ts, sm)
          discard c.anc.pop()
      elif t.tag == "svg":
        let ts = c.styleOf(t, st)
        if ts.display:
          let w = if n.has("width"): c.lenAttr(n, "width", 0) else: c.lenAttr(t, "width", 0, c.vw)
          let hh = if n.has("height"): c.lenAttr(n, "height", 1) else: c.lenAttr(t, "height", 1, c.vh)
          let sm = um * c.localTransform(t, ts)
          c.anc.add t
          let s0 = c.doc.items.len
          c.viewport(t, ts, sm, c.lenAttr(t, "x", 0), c.lenAttr(t, "y", 1), w, hh, t.kids, t)
          c.effects(s0, ts, sm)
          discard c.anc.pop()
      else:
        c.walk(t, st, um)
      discard c.busy.pop()
  else:
    let p = c.shapePath(n, st.fontSize)
    if p.subs.len > 0:
      c.addItem(n, p, st, mm)
      c.markers(n, p, st, mm)
  c.effects(start, st, mm)
  discard c.anc.pop()
  dec c.depth

proc strokeOutline(it: SvgItem; m: SvgMatrix; k: float): Path

proc drawnBounds(it: SvgItem; within: Box): Box =
  ## The box of what an item draws (its stroke too) -- measured exactly
  ## when a rough guess goes past `within`.
  result = if it.fill.kind != spkNone: tightBounds(it.path) else: NoBox
  if it.stroke.kind != spkNone and it.strokeWidth > 0:
    let b = tightBounds(it.path)
    let r = it.strokeWidth / 2 * (if it.join == ljMiter: max(1.5, it.miterLimit) else: 1.5)
    let rough = (b[0] - r, b[1] - r, b[2] + r, b[3] + r)
    if rough[0] >= within[0] and rough[1] >= within[1] and rough[2] <= within[2] and rough[3] <= within[3]:
      result = union(result, rough); return
    let k = 1 / max(1e-12, it.strokeWidth)            # (pieces a tenth of its width or finer)
    let o = strokeOutline(it, scaleM(k, k), k)
    let ob = tightBounds(o)
    if not empty(ob): result = union(result, (ob[0] / k, ob[1] / k, ob[2] / k, ob[3] / k))
    else: result = union(result, b)

proc parseSvg*(data: string): SvgDoc =
  ## An SVG file read: its size, its view box, what it draws (`items`, in
  ## user space). Never raises: what cannot be read is passed over.
  result = SvgDoc(width: 0, height: 0, alignX: 0.5, alignY: 0.5)
  var root: XNode
  try:
    let top = parseXml(data)
    for k in top.kids:
      if k.tag == "svg":
        root = k
        break
  except CatchableError: return
  if root == nil: return
  var c = Ctx()
  # the ids, the style sheets
  var todo = @[root]
  var css = ""
  while todo.len > 0:
    let n = todo.pop()
    let id = n.attr("id")
    if id.len > 0 and id notin c.ids: c.ids[id] = n
    if n.tag == "style":
      let t = n.attr("type").strip
      if t.len == 0 or t.toLowerAscii == "text/css": css.add n.text & "\n"
    for k in countdown(n.kids.high, 0):
      c.parents[cast[uint](n.kids[k])] = n
      todo.add n.kids[k]
  if css.len > 0:
    try: parseCss(css, c.rules)
    except CatchableError: c.rules.setLen(0)
  for k in root.kids:
    if k.tag == "title":
      c.doc.title = k.text.strip
      break
  # the size
  var vb: (float, float, float, float)
  c.doc.hasViewBox = viewBoxOf(root.attr("viewBox"), vb)
  if c.doc.hasViewBox:
    c.doc.viewBox = vb
    c.vw = vb[2]
    c.vh = vb[3]
  else:
    c.vw = 100
    c.vh = 100
  let (ax, ay, sl) = aspectOf(root.attr("preserveAspectRatio"))
  c.doc.alignX = ax
  c.doc.alignY = ay
  c.doc.slice = sl
  var w, h: float
  let hasW = root.attr("width").len > 0 and c.parseLen(root.attr("width"), 0, w)
  let hasH = root.attr("height").len > 0 and c.parseLen(root.attr("height"), 1, h)
  if (hasW and w <= 0) or (hasH and h <= 0): return     # (no size: nothing shown)
  if not hasW and not hasH:
    w = c.vw
    h = c.vh
  elif not hasW: w = (if c.doc.hasViewBox: h * vb[2] / vb[3] else: c.vw)
  elif not hasH: h = (if c.doc.hasViewBox: w * vb[3] / vb[2] else: c.vh)
  c.doc.width = w
  c.doc.height = h
  if not c.doc.hasViewBox:
    c.vw = w
    c.vh = h
  # what it draws
  try:
    let st = c.styleOf(root, defaultStyle())
    if st.display:
      # (the root's transform is in its viewport -- after the view box --
      # about its middle unless transform-origin says)
      var m = IdentityM
      let ts = if st.hasTransform: st.transform else: root.attr("transform")
      var t: SvgMatrix
      if ts.len > 0 and parseTransform(ts, t):
        let (svw, svh) = (c.vw, c.vh)
        c.vw = w
        c.vh = h
        let o = c.originOf(if st.origin.len > 0: st.origin else: "50% 50%")
        c.vw = svw
        c.vh = svh
        m = translateM(o[0], o[1]) * t * translateM(-o[0], -o[1])
      let vbm = if c.doc.hasViewBox: viewBoxTransform(vb, ax, ay, sl, w, h) else: IdentityM
      m = invert(vbm) * m * vbm
      if st.hasBg and (st.bg shr 24) > 0:
        c.doc.items.add SvgItem(kind: "background", path: rectPathM(0, 0, w, h, invert(vbm)),
                                fill: SvgPaint(kind: spkColor, color: st.bg), fillOpacity: 1, opacity: 1,
                                ctm: IdentityM)
      c.anc.add root
      for k in root.kids: c.walk(k, st, m)
      c.anc.setLen(0)
      c.effects(0, st, m)
      # (what lies outside the viewport is not seen: cut there, or left out)
      if not st.overflowVisible:
        let back = invert(vbm)
        let vp = tightBounds(rectPathM(0, 0, w, h, back))
        var ci = -1
        for it in c.doc.items.mitems:
          if it.ghost: continue
          let ib = drawnBounds(it, vp)
          if empty(ib) or ib[2] <= vp[0] or ib[0] >= vp[2] or ib[3] <= vp[1] or ib[1] >= vp[3]:
            it.ghost = true
          elif ib[0] < vp[0] - 1e-6 or ib[1] < vp[1] - 1e-6 or ib[2] > vp[2] + 1e-6 or ib[3] > vp[3] + 1e-6:
            if ci < 0: ci = c.rectClip(0, 0, w, h, back)
            it.clips.add ci
  except CatchableError: discard
  c.doc.items.keepItIf(not it.ghost)
  result = move(c.doc)

proc svgSize*(doc: SvgDoc): (float, float) =
  ## Its size in pixels (its width and height; its view box's when it has
  ## none).
  (doc.width, doc.height)

proc svgMap*(doc: SvgDoc; x0, y0, x1, y1: float): SvgMatrix =
  ## From its user space into the box (`x0`, `y0`) - (`x1`, `y1`): its size
  ## fitted there, its aspect kept (centered), its view box fitted in its
  ## size (preserveAspectRatio: xMidYMid meet unless it says).
  let (sw, sh) = svgSize(doc)
  if not (sw > 0 and sh > 0): return SvgMatrix()
  let bw = x1 - x0
  let bh = y1 - y0
  let s = min(bw / sw, bh / sh)
  result = translateM(x0 + (bw - sw * s) / 2, y0 + (bh - sh * s) / 2) * scaleM(s, s)
  if doc.hasViewBox:
    result = result * viewBoxTransform(doc.viewBox, doc.alignX, doc.alignY, doc.slice, sw, sh)

# ---- as shapes ---------------------------------------------------------------------------------------------

proc inside(p: Pt; poly: seq[Pt]): bool =
  var j = poly.high
  for i in 0 ..< poly.len:
    let a = poly[i]
    let b = poly[j]
    if (a[1] > p[1]) != (b[1] > p[1]) and p[0] < (b[0] - a[0]) * (p[1] - a[1]) / (b[1] - a[1]) + a[0]:
      result = not result
    j = i

proc reversed(s: SubPath): SubPath =
  ## (a closed subpath the other way round, from the same point)
  result = s
  result.pts.setLen(0)
  let n = s.pts.len
  if n == 0: return
  result.pts.add PathPoint(p: s.pts[0].p, inH: s.pts[0].outH, outH: s.pts[0].inH)
  for k in countdown(n - 1, 1):
    let q = s.pts[k]
    result.pts.add PathPoint(p: q.p, inH: q.outH, outH: q.inH)

proc orientEvenOdd(p: var Path; stroked: bool) =
  ## Its subpaths turned so that filling them by winding fills them
  ## even-odd (as long as none crosses itself or another).
  let n = p.subs.len
  if n < 2: return
  var polys: seq[seq[Pt]]
  var boxes: seq[Box]
  for s in p.subs:
    let q = polyOf(s)
    var b = NoBox
    for v in q: b.add v
    polys.add q
    boxes.add b
  for i in 0 ..< n:
    if polys[i].len < 3: continue
    let t = polys[i][0]
    var depth = 0
    for j in 0 ..< n:
      if j == i or polys[j].len < 3: continue
      let b = boxes[j]
      if t[0] < b[0] or t[0] > b[2] or t[1] < b[1] or t[1] > b[3]: continue
      if inside(t, polys[j]): inc depth
    let positive = areaOf(polys[i]) > 0
    if positive != (depth mod 2 == 0):
      if p.subs[i].closed or not stroked: p.subs[i] = reversed(p.subs[i])

proc stopColorOf(st: SvgStop; cur: uint32): uint32 =
  if not st.current: return st.color
  let a = (cur shr 24) * (st.color shr 24) div 255
  (cur and 0xFFFFFF'u32) or (a shl 24)

proc spreadT(t: float; sp: SvgSpread): float {.inline.} =
  case sp
  of ssPad: clamp(t, 0.0, 1.0)
  of ssRepeat: t - floor(t)
  of ssReflect:
    let u = floorMod(t, 2.0)
    if u > 1: 2 - u else: u

proc colorAt(stops: seq[SvgStop]; t: float; cur: uint32): uint32 =
  ## The color at `t` (0..1) of the stops, straight alpha.
  if t <= stops[0].offset: return stopColorOf(stops[0], cur)
  for k in 1 .. stops.high:
    if t <= stops[k].offset:
      let a = stops[k - 1]
      let b = stops[k]
      let span = b.offset - a.offset
      if span <= 1e-12: return stopColorOf(b, cur)
      return mix(stopColorOf(a, cur), stopColorOf(b, cur), (t - a.offset) / span)
  stopColorOf(stops[^1], cur)

proc alphaPct(a: float): int = clamp(int(round(a * 100)), 1, 100)

proc shapePaintOf(p: SvgPaint; M: SvgMatrix; bb: Box; alpha: float; cur: uint32): ShapePaint =
  ## A paint as a shape's: a color with its opacity, or a gradient laid
  ## across the shape's box (`bb`) as close to the SVG's as one can be.
  case p.kind
  of spkNone: ShapePaint(kind: spNone)
  of spkColor, spkCurrent:
    let col = if p.kind == spkCurrent: (cur and 0xFFFFFF'u32) or
                                       (((cur shr 24) * (p.color shr 24) div 255) shl 24)
              else: p.color
    let a = float(col shr 24) / 255 * alpha
    if a < 0.004: return ShapePaint(kind: spNone)
    var r = solidPaint(col or 0xFF000000'u32)
    r.opacity = alphaPct(a)
    r
  of spkLinear, spkRadial:
    let G = M * p.m
    let inv = invert(G)
    let cx = (bb[0] + bb[2]) / 2
    let cy = (bb[1] + bb[3]) / 2
    var style, angle: int
    var gx, gy, tc, rdoc: float
    if p.kind == spkLinear:
      let vx = p.p1[0] - p.p0[0]
      let vy = p.p1[1] - p.p0[1]
      let vv = vx * vx + vy * vy
      gx = (inv.a * vx + inv.b * vy) / vv
      gy = (inv.c * vx + inv.d * vy) / vv
      let g = inv.apply((cx, cy))
      tc = ((g[0] - p.p0[0]) * vx + (g[1] - p.p0[1]) * vy) / vv
      angle = int(round(radToDeg(arctan2(-gy, gx))))
    else:
      style = 1
      rdoc = p.r * scaleOf(G)
    proc measure(scale: int): (float, float, float) =
      let s = scale / 100
      let t0 = gradientT(style, angle.float, s, cx, cy, bb)
      if style == 1:
        let t1 = gradientT(style, angle.float, s, cx + 10, cy, bb)
        return (t0, (t1 - t0) / 10, 0.0)
      (t0, gradientT(style, angle.float, s, cx + 1, cy, bb) - t0, gradientT(style, angle.float, s, cx, cy + 1, bb) - t0)
    var scale = 100
    var (t0, hx, hy) = measure(scale)
    var alpha1, beta: float
    if style == 0:
      var dev = 0.0
      for (x, y) in [(bb[0], bb[1]), (bb[2], bb[1]), (bb[0], bb[3]), (bb[2], bb[3])]:
        dev = max(dev, abs(hx * (x - cx) + hy * (y - cy)))
      if dev > 0.49:
        scale = clamp(int(ceil(100 * dev / 0.49)), 100, 100_000)
        (t0, hx, hy) = measure(scale)
      let hh = hx * hx + hy * hy
      alpha1 = if hh > 1e-18: (gx * hx + gy * hy) / hh else: 0.0
      beta = tc - alpha1 * t0
    else:
      var far = 0.0
      for (x, y) in [(bb[0], bb[1]), (bb[2], bb[1]), (bb[0], bb[3]), (bb[2], bb[3])]:
        far = max(far, sqrt((x - cx) ^ 2 + (y - cy) ^ 2))
      if hx * far > 0.99:
        scale = clamp(int(ceil(100 * hx * far / 0.99)), 100, 100_000)
        (t0, hx, hy) = measure(scale)
      alpha1 = if hx > 1e-18 and rdoc > 1e-12: 1 / (hx * rdoc) else: 0.0
      beta = 0
    # the stops along the shape's gradient (0..1): where the SVG's fall, and its ends
    var ts = @[0.0, 1.0]
    if abs(alpha1) > 1e-12:
      if p.spread == ssPad:
        for st in p.stops:
          let u = (st.offset - beta) / alpha1
          if u > 0 and u < 1: ts.add u
      else:
        let lo = min(beta, alpha1 + beta)
        let hi = max(beta, alpha1 + beta)
        let k0 = toInt(floor(lo)) - 1
        let k1 = toInt(ceil(hi)) + 1
        if k1 - k0 <= 64:
          for k in k0 .. k1:
            for st in p.stops:
              let o = st.offset
              let at = if p.spread == ssReflect and floorMod(k, 2) == 1: k.float + 1 - o else: k.float + o
              let u = (at - beta) / alpha1
              if u > 0 and u < 1: ts.add u
        else:
          for j in 1 .. 127: ts.add j / 128
    ts.sort()
    var stops: seq[GradientStop]
    var last = -1.0
    let dir = if alpha1 >= 0: 1.0 else: -1.0
    for u in ts:
      if u - last < 1e-9 or stops.len >= 254: continue
      last = u
      # (the colors just before and just after: both where they step)
      let t = alpha1 * u + beta
      let cl = colorAt(p.stops, spreadT(t - dir * 1e-9, p.spread), cur)
      let cr = colorAt(p.stops, spreadT(t + dir * 1e-9, p.spread), cur)
      if u <= 0: stops.add GradientStop(at: 0, color: cr, mid: 0.5)
      elif u >= 1: stops.add GradientStop(at: 1, color: cl, mid: 0.5)
      else:
        stops.add GradientStop(at: u, color: cl, mid: 0.5)
        if cr != cl: stops.add GradientStop(at: u, color: cr, mid: 0.5)
    ShapePaint(kind: spGradient, stops: stops, color: stops[0].color, color2: stops[^1].color, style: style,
               angle: angle, scale: scale, opacity: alphaPct(alpha))

proc dashesFrom(d: seq[float]; offset, width: float): seq[float] =
  ## (SVG dashes and their offset as a shape's: in stroke widths, from 0)
  if d.len == 0 or width <= 0: return
  var total = 0.0
  for v in d: total += v
  if total <= 0: return
  var o = floorMod(offset, total)
  var ds = d
  if o > 1e-9:
    # start the pattern `o` into it: the piece cut off goes at the end
    var k = 0
    while k < ds.len and o >= ds[k]:
      o -= ds[k]
      inc k
    var r: seq[float]
    if k mod 2 == 1:
      # (in a gap: start with an empty dash)
      r.add 0.0
    r.add ds[k] - o
    for j in k + 1 ..< ds.len: r.add ds[j]
    for j in 0 ..< k: r.add ds[j]
    r.add o
    if r.len mod 2 == 1: r.add 0.0
    ds = r
  for v in ds: result.add v / width

# ---- as pixels -------------------------------------------------------------------------------------------

type
  Cov = object
    ## (how much of each pixel of a box outlines cover: signed areas added
    ## up along the rows, the method of font-rs)
    x0, y0, w, h, stride: int
    a: seq[float32]
    collect: ptr seq[seq[Pt]]     # (not nil: the pieces gathered, not drawn)

  ClipCov = object
    x0, y0, w, h: int
    a: seq[float32]

  Poly = object
    pts: seq[Pt]
    corner: seq[bool]
    closed: bool

  PaintEv = object
    kind: SvgPaintKind
    color: uint32
    lut: seq[uint32]
    inv: SvgMatrix
    p0, p1: Pt
    r, fr: float
    spread: SvgSpread

  Rnd = object
    w, h: int
    m: SvgMatrix
    k: float
    color: uint32
    fc, sc: Cov
    polys, spolys: seq[Poly]
    clipCov: seq[ClipCov]         # (each clip path's, made when first wanted)
    clipDone: seq[bool]
    tol: float

proc reset(c: var Cov; x0, y0, w, h: int) =
  c.x0 = x0
  c.y0 = y0
  c.w = max(0, w)
  c.h = max(0, h)
  c.stride = c.w + 2
  let n = c.stride * c.h
  if c.a.len < n: c.a.setLen(n)
  if n > 0: zeroMem(addr c.a[0], n * sizeof(float32))

proc cell(c: var Cov; x0, y0, x1, y1: float32) =
  ## (a line within the box, `x` 0..w: its signed area added)
  if abs(y0 - y1) <= 1e-7'f32: return
  var (dir, ax, ay, bx, by) = if y0 < y1: (1'f32, x0, y0, x1, y1) else: (-1'f32, x1, y1, x0, y0)
  let dxdy = (bx - ax) / (by - ay)
  let wf = c.w.float32
  let ys = max(0, int(ay))
  let ye = min(c.h, int(ceil(by)))
  for y in ys ..< ye:
    let ls = y * c.stride
    let yt = max(float32(y), ay)
    let yb = min(float32(y + 1), by)
    let dy = yb - yt
    # (x where the line enters and leaves the row: from y, not added up -- no drift past the sides)
    let x = clamp(ax + (yt - ay) * dxdy, 0'f32, wf)
    let xn = if yb >= by: clamp(bx, 0'f32, wf) else: clamp(ax + (yb - ay) * dxdy, 0'f32, wf)
    let d = dy * dir
    let (xa, xb) = if x < xn: (x, xn) else: (xn, x)
    let xaf = floor(xa)
    let xai = int(xaf)
    let xbc = ceil(xb)
    let xbi = int(xbc)
    if xai < 0 or xbi > c.w + 1: continue
    if xbi <= xai + 1:
      let xm = 0.5'f32 * (x + xn) - xaf
      c.a[ls + xai] += d - d * xm
      c.a[ls + xai + 1] += d * xm
    else:
      let s = 1'f32 / (xb - xa)
      let x0f = xa - xaf
      let a0 = 0.5'f32 * s * (1 - x0f) * (1 - x0f)
      let x1f = xb - xbc + 1
      let am = 0.5'f32 * s * x1f * x1f
      c.a[ls + xai] += d * a0
      if xbi == xai + 2:
        c.a[ls + xai + 1] += d * (1 - a0 - am)
      else:
        let a1 = s * (1.5'f32 - x0f)
        c.a[ls + xai + 1] += d * (a1 - a0)
        for xi in xai + 2 ..< xbi - 1: c.a[ls + xi] += d * s
        let a2 = a1 + float32(xbi - xai - 3) * s
        c.a[ls + xbi - 1] += d * (1 - a2 - am)
      c.a[ls + xbi] += d * am

proc edge(c: var Cov; p0, p1: Pt) =
  ## A line of an outline (in canvas pixels), cut to the box: what lies
  ## left of it is drawn on its left side.
  let ax = p0[0] - c.x0.float
  let ay = p0[1] - c.y0.float
  let bx = p1[0] - c.x0.float
  let by = p1[1] - c.y0.float
  if not (finite(ax) and finite(ay) and finite(bx) and finite(by)): return
  let dy = by - ay
  if abs(dy) < 1e-12: return
  let h = c.h.float
  let w = c.w.float
  if max(ay, by) <= 0 or min(ay, by) >= h: return
  let ta = (0 - ay) / dy
  let tb = (h - ay) / dy
  let tlo = max(0.0, min(ta, tb))
  let thi = min(1.0, max(ta, tb))
  if tlo >= thi: return
  let dx = bx - ax
  var ts = [tlo, thi, -1.0, -1.0]
  var nt = 2
  if abs(dx) > 1e-12:
    for side in [0.0, w]:
      let t = (side - ax) / dx
      if t > tlo and t < thi:
        ts[nt] = t
        inc nt
  if nt == 4 and ts[2] > ts[3]: swap(ts[2], ts[3])
  if nt >= 3:
    # (the cuts in order between tlo and thi)
    var arr = @[ts[0]]
    for k in 2 ..< nt: arr.add ts[k]
    arr.add ts[1]
    for k in 0 ..< arr.len - 1:
      let t0 = arr[k]
      let t1 = arr[k + 1]
      if t1 - t0 <= 1e-12: continue
      c.cell(clamp(ax + dx * t0, 0.0, w).float32, clamp(ay + dy * t0, 0.0, h).float32,
             clamp(ax + dx * t1, 0.0, w).float32, clamp(ay + dy * t1, 0.0, h).float32)
  else:
    c.cell(clamp(ax + dx * tlo, 0.0, w).float32, clamp(ay + dy * tlo, 0.0, h).float32,
           clamp(ax + dx * thi, 0.0, w).float32, clamp(ay + dy * thi, 0.0, h).float32)

proc polygon(c: var Cov; pts: openArray[Pt]) =
  if pts.len < 2: return
  for i in 0 ..< pts.len: c.edge(pts[i], pts[(i + 1) mod pts.len])

proc finish(c: var Cov; evenOdd: bool) =
  ## The areas added up into how much of each pixel is covered, 0..1.
  for y in 0 ..< c.h:
    var acc = 0'f32
    let ls = y * c.stride
    for x in 0 ..< c.w:
      acc += c.a[ls + x]
      var v = abs(acc)
      if evenOdd:
        v = v - 2 * floor(v / 2)
        if v > 1: v = 2 - v
      else: v = min(1'f32, v)
      c.a[ls + x] = v

proc flatten(s: SubPath; m: SvgMatrix; tol: float; out0: var Poly) =
  ## A subpath as a polygon in pixels (its curves in pieces at most `tol`
  ## off), each point marked when it is one of the path's own.
  out0.pts.setLen(0)
  out0.corner.setLen(0)
  out0.closed = s.closed
  let n = s.pts.len
  if n == 0: return
  out0.pts.add m.apply(s.pts[0].p)
  out0.corner.add true
  for (a, b) in s.segments:
    let p3 = m.apply(b.p)
    if a.outH == a.p and b.inH == b.p:
      if p3 != out0.pts[^1]:
        out0.pts.add p3
        out0.corner.add true
      continue
    let p0 = m.apply(a.p)
    let p1 = m.apply(a.outH)
    let p2 = m.apply(b.inH)
    let ddx = max(abs(p0[0] - 2 * p1[0] + p2[0]), abs(p1[0] - 2 * p2[0] + p3[0]))
    let ddy = max(abs(p0[1] - 2 * p1[1] + p2[1]), abs(p1[1] - 2 * p2[1] + p3[1]))
    let dd = sqrt(ddx * ddx + ddy * ddy)
    let steps = if finite(dd): clamp(int(ceil(sqrt(0.75 * dd / tol))), 1, 500) else: 1
    for t in 1 .. steps:
      let u = t / steps
      let mu = 1 - u
      let p = if t == steps: p3
              else: (mu*mu*mu*p0[0] + 3*mu*mu*u*p1[0] + 3*mu*u*u*p2[0] + u*u*u*p3[0],
                     mu*mu*mu*p0[1] + 3*mu*mu*u*p1[1] + 3*mu*u*u*p2[1] + u*u*u*p3[1])
      if p != out0.pts[^1]:
        out0.pts.add p
        out0.corner.add t == steps
  if out0.closed and out0.pts.len > 1 and out0.pts[^1] == out0.pts[0]:
    out0.pts.setLen(out0.pts.len - 1)
    out0.corner.setLen(out0.corner.len - 1)

proc convex(c: var Cov; pts: var seq[Pt]; tm: SvgMatrix) =
  ## (a convex polygon (taken by `tm` to pixels) turned the one way:
  ## overlapping ones make a union)
  if pts.len < 3: return
  if tm != IdentityM:
    for p in pts.mitems: p = tm.apply(p)
  var ar = 0.0
  for i in 0 ..< pts.len:
    let a = pts[i]
    let b = pts[(i + 1) mod pts.len]
    ar += a[0] * b[1] - b[0] * a[1]
  if abs(ar) < 1e-12: return
  if ar < 0: pts.reverse()
  if c.collect != nil:
    c.collect[].add pts
    return
  c.polygon(pts)

proc circlePts(p: Pt; r, tol: float): seq[Pt] =
  let n = if r > tol: clamp(int(ceil(PI / arccos(clamp(1 - tol / r, -1.0, 1.0)))), 8, 256) else: 8
  for i in 0 ..< n:
    let a = i.float * 2 * PI / n.float
    result.add (p[0] + cos(a) * r, p[1] + sin(a) * r)

proc strokePoly(c: var Cov; pts: seq[Pt]; corner: seq[bool]; closed: bool; hw: float; cap: LineCap;
                join: LineJoin; miter, tol: float; tm: SvgMatrix) =
  ## The outline of a line `hw` to each side of `pts`, with its joins and
  ## caps, as convex pieces.
  let n = pts.len
  if n == 0: return
  if n == 1:
    let p = pts[0]
    case cap
    of lcRound:
      var q = circlePts(p, hw, tol)
      c.convex(q, tm)
    of lcSquare:
      var q = @[(p[0] - hw, p[1] - hw), (p[0] + hw, p[1] - hw), (p[0] + hw, p[1] + hw), (p[0] - hw, p[1] + hw)]
      c.convex(q, tm)
    else: discard
    return
  let isClosed = closed and n > 2
  let segs = if isClosed: n else: n - 1
  proc dirOf(k: int): Pt =
    let a = pts[k]
    let b = pts[(k + 1) mod n]
    let dx = b[0] - a[0]
    let dy = b[1] - a[1]
    let l = max(1e-12, sqrt(dx * dx + dy * dy))
    (dx / l, dy / l)
  for k in 0 ..< segs:
    let a = pts[k]
    let b = pts[(k + 1) mod n]
    let u = dirOf(k)
    let nn = (-u[1] * hw, u[0] * hw)
    var a0 = a
    var b0 = b
    if not isClosed and cap == lcSquare:
      if k == 0: a0 = (a[0] - u[0] * hw, a[1] - u[1] * hw)
      if k == segs - 1: b0 = (b[0] + u[0] * hw, b[1] + u[1] * hw)
    var q = @[(a0[0] + nn[0], a0[1] + nn[1]), (b0[0] + nn[0], b0[1] + nn[1]),
              (b0[0] - nn[0], b0[1] - nn[1]), (a0[0] - nn[0], a0[1] - nn[1])]
    c.convex(q, tm)
  let first = if isClosed: 0 else: 1
  let last = if isClosed: n - 1 else: n - 2
  for k in first .. last:
    let p = pts[k]
    let d1 = dirOf((k - 1 + n) mod n)
    let d2 = dirOf(k)
    let cr = d1[0] * d2[1] - d1[1] * d2[0]
    let dt = d1[0] * d2[0] + d1[1] * d2[1]
    if abs(cr) < 1e-9 and dt > 0: continue
    let jn = if corner[k]: join elif dt > 0.9: ljMiter else: ljRound
    case jn
    of ljRound:
      var q = circlePts(p, hw, tol)
      c.convex(q, tm)
    of ljBevel, ljMiter:
      let s = if cr > 0: -1.0 else: 1.0
      let n1 = (-d1[1] * hw * s, d1[0] * hw * s)
      let n2 = (-d2[1] * hw * s, d2[0] * hw * s)
      let e1 = (p[0] + n1[0], p[1] + n1[1])
      let e2 = (p[0] + n2[0], p[1] + n2[1])
      let half = sqrt(max(0.0, (1 + dt) / 2))
      if jn == ljMiter and half > 1e-9 and 1 / half <= (if corner[k]: miter else: 1e9):
        let mx = (n1[0] + n2[0]) / 2
        let my = (n1[1] + n2[1]) / 2
        let ml = sqrt(mx * mx + my * my)
        if ml > 1e-12:
          let k2 = hw / half / ml
          var q = @[p, e1, (p[0] + mx * k2, p[1] + my * k2), e2]
          c.convex(q, tm)
          continue
      var q = @[p, e1, e2]
      c.convex(q, tm)
  if not isClosed and cap == lcRound:
    var q0 = circlePts(pts[0], hw, tol)
    c.convex(q0, tm)
    var q1 = circlePts(pts[^1], hw, tol)
    c.convex(q1, tm)

proc dashPieces(p: Poly; dashes: seq[float]; offset: float): seq[Poly] =
  ## The pieces of a polygon the dashes draw.
  var total = 0.0
  for v in dashes: total += v
  if dashes.len == 0 or total <= 1e-9: return @[p]
  var pts = p.pts
  var cor = p.corner
  if p.closed and pts.len > 1:
    pts.add pts[0]
    cor.add true
  var length = 0.0
  for k in 0 ..< pts.len - 1: length += sqrt((pts[k + 1][0] - pts[k][0]) ^ 2 + (pts[k + 1][1] - pts[k][1]) ^ 2)
  if length / total > 20_000: return @[p]       # (too fine to see: drawn whole)
  var idx = 0
  var left = dashes[0]
  var o = floorMod(offset, total)
  while o > 0:
    if o >= left:
      o -= left
      idx = (idx + 1) mod dashes.len
      left = dashes[idx]
    else:
      left -= o
      o = 0
  var on = idx mod 2 == 0
  var cur = Poly()
  proc dot(res: var seq[Poly]; p, q: Pt) =
    ## (a dash of no length: a dot -- round and square caps show it -- turned along the line)
    let dx = q[0] - p[0]
    let dy = q[1] - p[1]
    let l = max(1e-12, sqrt(dx * dx + dy * dy))
    res.add Poly(pts: @[p, (p[0] + dx / l * 1e-4, p[1] + dy / l * 1e-4)], corner: @[true, true])
  if on and pts.len > 0:
    if left <= 1e-9 and pts.len > 1:
      dot(result, pts[0], pts[1])
      on = false
      idx = (idx + 1) mod dashes.len
      left = dashes[idx]
    else:
      cur.pts.add pts[0]
      cur.corner.add true
  var guard = 0
  for k in 0 ..< pts.len - 1:
    var a = pts[k]
    let b = pts[k + 1]
    var segLen = sqrt((b[0] - a[0]) ^ 2 + (b[1] - a[1]) ^ 2)
    while segLen > 1e-12:
      inc guard
      if guard > 400_000: return
      if left >= segLen:
        left -= segLen
        if on:
          cur.pts.add b
          cur.corner.add cor[k + 1]
        segLen = 0
      else:
        let t = left / segLen
        let mm = (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
        if on:
          cur.pts.add mm
          cur.corner.add true
          result.add cur
          cur = Poly()
        else:
          cur = Poly(pts: @[mm], corner: @[true])
        a = mm
        segLen -= left
        on = not on
        idx = (idx + 1) mod dashes.len
        left = dashes[idx]
        if on and left <= 1e-9:
          dot(result, mm, b)
          cur = Poly()
          on = false
          idx = (idx + 1) mod dashes.len
          left = dashes[idx]
  if on and cur.pts.len > 1: result.add cur

proc localStroke(ctm: SvgMatrix): bool =
  ## (a transform that is not a turn and a scale: its strokes are drawn in its space)
  let q2 = ctm.a * ctm.a + ctm.b * ctm.b + ctm.c * ctm.c + ctm.d * ctm.d
  q2 > 0 and abs(det(ctm)) > 1e-12 and (abs(ctm.a * ctm.c + ctm.b * ctm.d) > 1e-4 * q2 or
                                        abs(ctm.a * ctm.a + ctm.b * ctm.b - ctm.c * ctm.c - ctm.d * ctm.d) > 1e-4 * q2)

proc strokeInto(cov: var Cov; it: SvgItem; m: SvgMatrix; k, tol: float; polys: var seq[Poly]) =
  ## An item's stroke (in pixels by `m`, `k` pixels a unit) as convex
  ## pieces drawn into `cov` (or gathered by it).
  let n = it.path.subs.len
  if polys.len < n: polys.setLen(n)
  var hw = it.strokeWidth * k / 2
  var tm = IdentityM
  var tl = tol
  var unit = k                      # (pixels a user unit, along the stroke)
  if localStroke(it.ctm):
    let ks = scaleOf(it.ctm)
    tm = m * it.ctm
    hw = it.strokeWidth / ks / 2
    tl = tol / max(1e-12, scaleOf(tm))
    unit = 1 / ks
    let back = invert(it.ctm)
    for j in 0 ..< n: flatten(it.path.subs[j], back, tl, polys[j])
  else:
    for j in 0 ..< n: flatten(it.path.subs[j], m, tol, polys[j])
  var ds: seq[float]
  for d in it.dashes: ds.add d * unit
  for j in 0 ..< n:
    let q = polys[j]
    if q.pts.len == 0: continue
    if ds.len > 0:
      for piece in dashPieces(q, ds, it.dashOffset * unit):
        cov.strokePoly(piece.pts, piece.corner, false, hw, it.cap, it.join, it.miterLimit, tl, tm)
    else:
      cov.strokePoly(q.pts, q.corner, q.closed, hw, it.cap, it.join, it.miterLimit, tl, tm)

proc strokeOutline(it: SvgItem; m: SvgMatrix; k: float): Path =
  ## (an item's stroke as an outline to fill: convex pieces, one part)
  var cov = Cov()
  var gathered: seq[seq[Pt]]
  cov.collect = addr gathered
  var polys: seq[Poly]
  cov.strokeInto(it, m, k, 0.1, polys)
  for i, g in gathered:
    var sp = SubPath(closed: true, joined: i > 0, op: poAdd)
    for p in g: sp.pts.add corner(p)
    result.subs.add sp

proc prepPaint(p: SvgPaint; m: SvgMatrix; cur: uint32): PaintEv =
  result.kind = p.kind
  case p.kind
  of spkColor: result.color = p.color
  of spkCurrent:
    result.kind = spkColor
    result.color = (cur and 0xFFFFFF'u32) or (((cur shr 24) * (p.color shr 24) div 255) shl 24)
  of spkLinear, spkRadial:
    result.inv = invert(m * p.m)
    result.p0 = p.p0
    result.p1 = p.p1
    result.r = p.r
    result.fr = p.fr
    result.spread = p.spread
    result.lut = newSeq[uint32](256)
    for k in 0 .. 255: result.lut[k] = colorAt(p.stops, k / 255, cur)
  of spkNone: discard

proc at(pe: PaintEv; x, y: float): uint32 {.inline.} =
  case pe.kind
  of spkColor: pe.color
  of spkLinear:
    let g = pe.inv.apply((x, y))
    let vx = pe.p1[0] - pe.p0[0]
    let vy = pe.p1[1] - pe.p0[1]
    let t = ((g[0] - pe.p0[0]) * vx + (g[1] - pe.p0[1]) * vy) / (vx * vx + vy * vy)
    pe.lut[clamp(toInt(spreadT(t, pe.spread) * 255 + 0.5), 0, 255)]
  of spkRadial:
    # (two circles: the focal one at t = 0, the outer at t = 1)
    let g = pe.inv.apply((x, y))
    let cdx = pe.p0[0] - pe.p1[0]
    let cdy = pe.p0[1] - pe.p1[1]
    let dr = pe.r - pe.fr
    let pdx = g[0] - pe.p1[0]
    let pdy = g[1] - pe.p1[1]
    let a = cdx * cdx + cdy * cdy - dr * dr
    let b = pdx * cdx + pdy * cdy + pe.fr * dr
    let cc = pdx * pdx + pdy * pdy - pe.fr * pe.fr
    var t: float
    if abs(a) < 1e-12:
      if abs(b) < 1e-12: return 0
      t = cc / (2 * b)
    else:
      let disc = b * b - a * cc
      if disc < 0: return 0
      let sq = sqrt(disc)
      let t1 = (b + sq) / a
      let t2 = (b - sq) / a
      t = max(t1, t2)
      if pe.fr + t * dr < 0:
        t = min(t1, t2)
        if pe.fr + t * dr < 0: return 0
    if not finite(t): return 0
    pe.lut[clamp(toInt(spreadT(t, pe.spread) * 255 + 0.5), 0, 255)]
  of spkNone, spkCurrent: 0

proc covAt(cc: ptr ClipCov; x, y: int): float32 {.inline.} =
  if x >= cc.x0 and x < cc.x0 + cc.w and y >= cc.y0 and y < cc.y0 + cc.h: cc.a[(y - cc.y0) * cc.w + x - cc.x0]
  else: 0

proc clipCovOf(r: var Rnd; doc: SvgDoc; ci: int; depth = 0): ptr ClipCov =
  ## (how much of each pixel a clip path lets through: made once)
  if r.clipDone[ci]: return addr r.clipCov[ci]
  r.clipDone[ci] = true
  var cc = ClipCov()
  let cl = doc.clips[ci]
  var b = NoBox
  var polys: seq[seq[Poly]]
  for part in cl.parts:
    var ps: seq[Poly]
    for sp in part.path.subs:
      var q: Poly
      flatten(sp, r.m, r.tol, q)
      for v in q.pts: b.add v
      ps.add q
    polys.add ps
  if not empty(b):
    let x0 = clamp(toInt(floor(b[0])), 0, r.w)
    let y0 = clamp(toInt(floor(b[1])), 0, r.h)
    let x1 = clamp(toInt(ceil(b[2])) + 1, 0, r.w)
    let y1 = clamp(toInt(ceil(b[3])) + 1, 0, r.h)
    cc = ClipCov(x0: x0, y0: y0, w: max(0, x1 - x0), h: max(0, y1 - y0))
    cc.a = newSeq[float32](cc.w * cc.h)
    var cov: Cov
    for pi, ps in polys:
      cov.reset(cc.x0, cc.y0, cc.w, cc.h)
      for q in ps: cov.polygon(q.pts)
      cov.finish(cl.parts[pi].evenOdd)
      var inner: seq[ptr ClipCov]
      if depth < 8:
        for ic in cl.parts[pi].clips:
          if ic >= 0 and ic < doc.clips.len and ic != ci: inner.add r.clipCovOf(doc, ic, depth + 1)
      for y in 0 ..< cc.h:
        for x in 0 ..< cc.w:
          var v = cov.a[y * cov.stride + x]
          for ic in inner: v *= covAt(ic, cc.x0 + x, cc.y0 + y)
          let o = cc.a[y * cc.w + x]
          cc.a[y * cc.w + x] = v + o * (1 - v)
    if depth < 8:
      for inner in cl.clips:
        if inner < 0 or inner >= doc.clips.len or inner == ci: continue
        let ic = r.clipCovOf(doc, inner, depth + 1)
        for y in 0 ..< cc.h:
          for x in 0 ..< cc.w:
            let gx = cc.x0 + x
            let gy = cc.y0 + y
            var v = 0'f32
            if gx >= ic.x0 and gx < ic.x0 + ic.w and gy >= ic.y0 and gy < ic.y0 + ic.h:
              v = ic.a[(gy - ic.y0) * ic.w + gx - ic.x0]
            cc.a[y * cc.w + x] *= v
  r.clipCov[ci] = cc
  addr r.clipCov[ci]

type IBox = tuple[x0, y0, x1, y1: int]

proc grow(a: var IBox; b: IBox) =
  if b.x1 <= b.x0 or b.y1 <= b.y0: return
  if a.x1 <= a.x0 or a.y1 <= a.y0:
    a = b
    return
  a = (min(a.x0, b.x0), min(a.y0, b.y0), max(a.x1, b.x1), max(a.y1, b.y1))

proc drawItem(r: var Rnd; doc: SvgDoc; it: SvgItem; dst: var seq[uint32]; drawn: var IBox) =
  let sw = it.strokeWidth * r.k
  let fillOn = it.fill.kind != spkNone and it.fillOpacity * it.opacity > 0
  let strokeOn = it.stroke.kind != spkNone and sw > 0 and it.strokeOpacity * it.opacity > 0
  if not fillOn and not strokeOn: return
  if r.polys.len < it.path.subs.len: r.polys.setLen(it.path.subs.len)
  var fb = NoBox
  for k, sp in it.path.subs:
    flatten(sp, r.m, r.tol, r.polys[k])
    for v in r.polys[k].pts: fb.add v
  if empty(fb): return
  var bb = NoBox
  if fillOn: bb = fb
  # (a stroke under a transform that is not a turn and a scale is drawn in its element's space)
  let ctm = it.ctm
  let local = strokeOn and localStroke(ctm)
  if strokeOn:
    var stretch = r.k
    if local:
      let S = r.m * ctm
      let e = (S.a * S.a + S.b * S.b + S.c * S.c + S.d * S.d) / 2
      let f = sqrt(((S.a * S.a + S.b * S.b - S.c * S.c - S.d * S.d) / 2) ^ 2 + (S.a * S.c + S.b * S.d) ^ 2)
      stretch = sqrt(e + f) / max(1e-12, scaleOf(ctm))
    let reach = it.strokeWidth * stretch / 2 * (if it.join == ljMiter: max(1.5, it.miterLimit) else: 1.5) + 1
    bb = union(bb, (fb[0] - reach, fb[1] - reach, fb[2] + reach, fb[3] + reach))
  var x0 = clamp(toInt(floor(bb[0])), 0, r.w)
  var y0 = clamp(toInt(floor(bb[1])), 0, r.h)
  var x1 = clamp(toInt(ceil(bb[2])) + 1, 0, r.w)
  var y1 = clamp(toInt(ceil(bb[3])) + 1, 0, r.h)
  var clips: seq[ptr ClipCov]
  for ci in it.clips:
    if ci < 0 or ci >= doc.clips.len: continue
    let cc = r.clipCovOf(doc, ci)
    clips.add cc
    x0 = max(x0, cc.x0)
    y0 = max(y0, cc.y0)
    x1 = min(x1, cc.x0 + cc.w)
    y1 = min(y1, cc.y0 + cc.h)
  if x1 <= x0 or y1 <= y0: return
  let w = x1 - x0
  let h = y1 - y0
  let n = it.path.subs.len
  if fillOn:
    r.fc.reset(x0, y0, w, h)
    for k in 0 ..< n:
      if r.polys[k].pts.len >= 3: r.fc.polygon(r.polys[k].pts)
    r.fc.finish(it.evenOdd)
  if strokeOn:
    r.sc.reset(x0, y0, w, h)
    r.sc.strokeInto(it, r.m, r.k, r.tol, r.spolys)
    r.sc.finish(false)
  let fp = if fillOn: prepPaint(it.fill, r.m, r.color) else: PaintEv()
  let spn = if strokeOn: prepPaint(it.stroke, r.m, r.color) else: PaintEv()
  let fo = it.fillOpacity
  let so = it.strokeOpacity
  let op = it.opacity
  for yy in 0 ..< h:
    let y = y0 + yy
    for xx in 0 ..< w:
      let x = x0 + xx
      var fa = 0.0
      var sa = 0.0
      if fillOn: fa = r.fc.a[yy * r.fc.stride + xx]
      if strokeOn: sa = r.sc.a[yy * r.sc.stride + xx]
      if fa <= 0.0005 and sa <= 0.0005: continue
      var kk = op
      for cc in clips:
        kk *= cc.a[(y - cc.y0) * cc.w + x - cc.x0]
      if kk <= 0.0005: continue
      var fr, fg, fbb, sr, sg, sbb: float
      if fa > 0.0005:
        let col = fp.at(x.float + 0.5, y.float + 0.5)
        fa *= float(col shr 24) / 255 * fo
        fr = float((col shr 16) and 255)
        fg = float((col shr 8) and 255)
        fbb = float(col and 255)
      else: fa = 0
      if sa > 0.0005:
        let col = spn.at(x.float + 0.5, y.float + 0.5)
        sa *= float(col shr 24) / 255 * so
        sr = float((col shr 16) and 255)
        sg = float((col shr 8) and 255)
        sbb = float(col and 255)
      else: sa = 0
      # (fill and stroke together, then its opacity and clip)
      var oa, orr, og, ob: float
      if it.strokeFirst:
        oa = fa + sa * (1 - fa)
        orr = fr * fa + sr * sa * (1 - fa)
        og = fg * fa + sg * sa * (1 - fa)
        ob = fbb * fa + sbb * sa * (1 - fa)
      else:
        oa = sa + fa * (1 - sa)
        orr = sr * sa + fr * fa * (1 - sa)
        og = sg * sa + fg * fa * (1 - sa)
        ob = sbb * sa + fbb * fa * (1 - sa)
      oa *= kk
      if oa <= 0.0005: continue
      orr *= kk
      og *= kk
      ob *= kk
      let i = y * r.w + x
      let d = dst[i]
      let inv = 1 - oa
      let na = oa * 255 + float(d shr 24) * inv
      let nr = orr + float((d shr 16) and 255) * inv
      let ng = og + float((d shr 8) and 255) * inv
      let nb = ob + float(d and 255) * inv
      dst[i] = (uint32(clamp(toInt(na + 0.5), 0, 255)) shl 24) or (uint32(clamp(toInt(nr + 0.5), 0, 255)) shl 16) or
               (uint32(clamp(toInt(ng + 0.5), 0, 255)) shl 8) or uint32(clamp(toInt(nb + 0.5), 0, 255))
  drawn.grow((x0, y0, x1, y1))

proc drawList(r: var Rnd; doc: SvgDoc; items: seq[SvgItem]; base: var seq[uint32]; depth = 0)

proc putLayer(r: var Rnd; doc: SvgDoc; g: int; layer: var seq[uint32]; lb: IBox; dst: var seq[uint32];
              depth: int) =
  ## A group drawn by itself put down: its mask, its opacity.
  if lb.x1 <= lb.x0 or lb.y1 <= lb.y0: return
  let grp = if g >= 0 and g < doc.groups.len: doc.groups[g] else: SvgGroup(opacity: 1, mask: -1)
  if grp.mask >= 0 and grp.mask < doc.masks.len and depth < 8:
    let mk = doc.masks[grp.mask]
    var mpx = newSeq[uint32](r.w * r.h)
    r.drawList(doc, mk.items, mpx, depth + 1)
    var region: ptr ClipCov = nil
    if mk.region >= 0 and mk.region < doc.clips.len: region = r.clipCovOf(doc, mk.region)
    for y in lb.y0 ..< lb.y1:
      for x in lb.x0 ..< lb.x1:
        let i = y * r.w + x
        let mp = mpx[i]
        var v = if mk.alpha: float(mp shr 24) / 255
                else: (0.2125 * float((mp shr 16) and 255) + 0.7154 * float((mp shr 8) and 255) +
                       0.0721 * float(mp and 255)) / 255     # (premultiplied: times its alpha)
        if region != nil:
          if x >= region.x0 and x < region.x0 + region.w and y >= region.y0 and y < region.y0 + region.h:
            v *= region.a[(y - region.y0) * region.w + x - region.x0]
          else: v = 0
        let p = layer[i]
        layer[i] = (uint32(clamp(toInt(float(p shr 24) * v + 0.5), 0, 255)) shl 24) or
                   (uint32(clamp(toInt(float((p shr 16) and 255) * v + 0.5), 0, 255)) shl 16) or
                   (uint32(clamp(toInt(float((p shr 8) and 255) * v + 0.5), 0, 255)) shl 8) or
                   uint32(clamp(toInt(float(p and 255) * v + 0.5), 0, 255))
  let o = grp.opacity
  for y in lb.y0 ..< lb.y1:
    for x in lb.x0 ..< lb.x1:
      let i = y * r.w + x
      let s = layer[i]
      let sa = float(s shr 24) / 255 * o
      if sa <= 0: continue
      let d = dst[i]
      let inv = 1 - sa
      dst[i] = (uint32(clamp(toInt(sa * 255 + float(d shr 24) * inv + 0.5), 0, 255)) shl 24) or
               (uint32(clamp(toInt(float((s shr 16) and 255) * o + float((d shr 16) and 255) * inv + 0.5), 0, 255)) shl 16) or
               (uint32(clamp(toInt(float((s shr 8) and 255) * o + float((d shr 8) and 255) * inv + 0.5), 0, 255)) shl 8) or
               uint32(clamp(toInt(float(s and 255) * o + float(d and 255) * inv + 0.5), 0, 255))

proc drawList(r: var Rnd; doc: SvgDoc; items: seq[SvgItem]; base: var seq[uint32]; depth = 0) =
  ## Items drawn in order into `base` (premultiplied), each in its groups.
  type Open = object
    g: int
    px: seq[uint32]
    box: IBox
  var stack: seq[Open]
  var baseBox: IBox
  proc pop(r: var Rnd; stack: var seq[Open]; base: var seq[uint32]; baseBox: var IBox) =
    var top = stack.pop()
    if stack.len > 0:
      r.putLayer(doc, top.g, top.px, top.box, stack[^1].px, depth)
      stack[^1].box.grow(top.box)
    else:
      r.putLayer(doc, top.g, top.px, top.box, base, depth)
      baseBox.grow(top.box)
  for it in items:
    var k = 0
    while k < stack.len and k < it.layers.len and stack[k].g == it.layers[k]: inc k
    while stack.len > k: r.pop(stack, base, baseBox)
    while stack.len < it.layers.len:
      stack.add Open(g: it.layers[stack.len], px: newSeq[uint32](r.w * r.h))
    if stack.len > 0: r.drawItem(doc, it, stack[^1].px, stack[^1].box)
    else: r.drawItem(doc, it, base, baseBox)
  while stack.len > 0: r.pop(stack, base, baseBox)

# ---- placing ----------------------------------------------------------------------------------------------

proc tame(p: var Path): bool =
  ## (an outline a shape can be: false when it has points that are not
  ## numbers; points past ten million pixels brought back to there)
  const far = 1e7
  for sp in p.subs.mitems:
    for q in sp.pts.mitems:
      for v in [q.p[0], q.p[1], q.inH[0], q.inH[1], q.outH[0], q.outH[1]]:
        if not finite(v): return false
      q.p = (clamp(q.p[0], -far, far), clamp(q.p[1], -far, far))
      q.inH = (clamp(q.inH[0], -far, far), clamp(q.inH[1], -far, far))
      q.outH = (clamp(q.outH[0], -far, far), clamp(q.outH[1], -far, far))
  true

proc svgShapes*(doc: SvgDoc; box: (float, float, float, float); color = 0xFF000000'u32):
               seq[tuple[name: string; shape: ShapeData]] =
  ## What the SVG draws as shapes in document pixels, fitted into `box`
  ## (x0, y0, x1, y1; its aspect kept), in order: currentColor taken as
  ## `color`; elements one after another painted alike (one opaque color
  ## and no stroke, or one opaque stroke and no fill) made one shape where
  ## that does not change the look; a stroke without a fill a shape with no
  ## fill; a stroke that is clipped, or under a skew or a stretch, an
  ## outline filled. Approximated: gradients (a shape's go across its box:
  ## a radial one from its middle, round, no focal point), the opacity of
  ## groups (on each element), even-odd fills of outlines that cross
  ## themselves (filled by winding), masks that are not white shapes and
  ## clip paths on a clip path's parts (left out).
  let M = svgMap(doc, box[0], box[1], box[2], box[3])
  let k = scaleOf(M)
  if not (k > 0) or not finite(k): return
  type Part = object
    path: Path
    name: string
    fillP, strokeP: SvgPaint
    fa, sa, sw: float
    cap: LineCap
    join: LineJoin
    dashes: seq[float]
    clipComps: seq[SubPath]
    clipKey: string
  var parts: seq[Part]
  for it in doc.items:
    var a = it.opacity
    for g in it.layers:
      if g >= 0 and g < doc.groups.len: a *= doc.groups[g].opacity
    let fa = it.fillOpacity * a
    let sa = it.strokeOpacity * a
    let sw = it.strokeWidth * k
    let fillOn = it.fill.kind != spkNone and fa > 0.002
    let strokeOn = it.stroke.kind != spkNone and sw > 0 and sa > 0.002
    if not fillOn and not strokeOn: continue
    var path = it.path.transformed(M)
    if not path.tame: continue
    if it.evenOdd and fillOn: path.orientEvenOdd(strokeOn)
    var ib = tightBounds(path)
    if strokeOn:
      var within = NoBox
      for ci in it.clips:
        if ci >= 0 and ci < doc.clips.len: within = union(within, doc.clips[ci].bounds)
      let ub = drawnBounds(it, within)               # (in user space)
      if not empty(ub): ib = tightBounds(rectPathM(ub[0], ub[1], ub[2] - ub[0], ub[3] - ub[1], M))
    # its clip paths: none when they hold it all, else parts it is cut by
    var clipComps: seq[SubPath]
    var clipKey = ""
    var hidden = false
    proc addClipComps(ci: int; clipComps: var seq[SubPath]; clipKey: var string; hidden: var bool;
                      depth: int) =
      if ci < 0 or ci >= doc.clips.len or depth > 8: return
      let cl = doc.clips[ci]
      var whole = NoBox
      for part in cl.parts: whole = union(whole, tightBounds(part.path.transformed(M)))
      if cl.rect and whole[0] <= ib[0] + 0.01 and whole[1] <= ib[1] + 0.01 and whole[2] >= ib[2] - 0.01 and
         whole[3] >= ib[3] - 0.01:
        discard
      else:
        if empty(whole) or whole[2] <= ib[0] or whole[0] >= ib[2] or whole[3] <= ib[1] or whole[1] >= ib[3]:
          hidden = true
          return
        clipKey.add $ci & ","
        var first = true
        for part in cl.parts:
          var q = part.path.transformed(M)
          if not q.tame: continue
          if part.evenOdd: q.orientEvenOdd(false)
          # (each part turned so that its largest outline winds forward: the parts make a union)
          var big = 0.0
          for sp in q.subs:
            let ar = areaOf(polyOf(sp))
            if abs(ar) > abs(big): big = ar
          if big < 0:
            for sp in q.subs.mitems: sp = reversed(sp)
          for sp in q.subs:
            var t = sp
            t.op = poIntersect
            t.joined = not first
            first = false
            clipComps.add t
      for inner in cl.clips: addClipComps(inner, clipComps, clipKey, hidden, depth + 1)
    for ci in it.clips: addClipComps(ci, clipComps, clipKey, hidden, 0)
    if hidden: continue
    if strokeOn and (clipComps.len > 0 or localStroke(it.ctm)):
      # (a stroke that is cut, or skewed: its outline, filled)
      var op = strokeOutline(it, M, k)
      if not op.tame: continue
      let outline = Part(path: op, name: it.id, fillP: it.stroke, fa: sa,
                         clipComps: clipComps, clipKey: clipKey)
      if it.strokeFirst: parts.add outline
      if fillOn:
        parts.add Part(path: path, name: it.id, fillP: it.fill, fa: fa, clipComps: clipComps, clipKey: clipKey)
      if not it.strokeFirst: parts.add outline
    else:
      parts.add Part(path: path, name: it.id, fillP: (if fillOn: it.fill else: SvgPaint(kind: spkNone)),
                     strokeP: (if strokeOn: it.stroke else: SvgPaint(kind: spkNone)), fa: fa, sa: sa,
                     sw: (if strokeOn: min(sw, 1e6) else: 0.0), cap: it.cap, join: it.join,
                     dashes: (if strokeOn: dashesFrom(it.dashes, it.dashOffset, it.strokeWidth) else: @[]),
                     clipComps: clipComps, clipKey: clipKey)
  # parts painted alike, one after another: one shape
  var cur: ShapeData
  var curName, curKey: string
  var curClips: seq[SubPath]
  var curFill, curStroke: SvgPaint
  var curFa, curSa: float
  var any = false
  template flush() =
    if any:
      for sp in curClips: cur.path.subs.add sp
      let bb = pathBounds(cur.path)
      cur.fill = shapePaintOf(curFill, M, bb, curFa, color)
      cur.stroke = shapePaintOf(curStroke, M, bb, curSa, color)
      if cur.stroke.kind == spNone:
        cur.strokeWidth = 0
        cur.dashes = @[]
      if cur.fill.kind != spNone or cur.stroke.kind != spNone: result.add (curName, cur)
      any = false
  for p in parts:
    let fillOn = p.fillP.kind != spkNone
    let strokeOn = p.strokeP.kind != spkNone
    let fillCol = if p.fillP.kind == spkCurrent: color else: p.fillP.color
    let strokeCol = if p.strokeP.kind == spkCurrent: color else: p.strokeP.color
    let fillOnly = fillOn and not strokeOn and p.fillP.kind in {spkColor, spkCurrent} and p.fa >= 0.999 and
                   (fillCol shr 24) == 255
    let strokeOnly = strokeOn and not fillOn and p.strokeP.kind in {spkColor, spkCurrent} and p.sa >= 0.999 and
                     (strokeCol shr 24) == 255 and p.clipComps.len == 0
    let key = if fillOnly: "f" & $fillCol & "|" & p.clipKey
              elif strokeOnly: "s" & $strokeCol & "|" & $p.sw & "|" & $p.cap & "|" & $p.join & "|" & $p.dashes
              else: ""
    let merge = any and key.len > 0 and key == curKey
    if not merge:
      flush()
      any = true
      curKey = key
      curName = p.name
      curClips = p.clipComps
      curFill = p.fillP
      curStroke = p.strokeP
      curFa = p.fa
      curSa = p.sa
      cur = ShapeData(kind: "", align: saCenter, cap: p.cap, join: p.join, strokeWidth: p.sw, dashes: p.dashes)
    elif curName.len == 0: curName = p.name
    # its subpaths: one part (the first not joined) -- a stroke's all one part
    for j, sp in p.path.subs:
      var t = sp
      t.op = poAdd
      t.joined = if strokeOnly and merge: true else: j > 0
      cur.path.subs.add t
  flush()

proc placeSvg*(d: Doc; data: string; box: Rect; color = 0xFF000000'u32; asGroup = true): seq[Layer] =
  ## The SVG as shape layers (`svgShapes`) fitted into `box`, above the
  ## current layer -- in a group named after its title ("SVG" when it has
  ## none) when there is more than one. Undoable in a step (one is begun
  ## when none is open). The layers made: the group first.
  let doc = parseSvg(data)
  let shapes = doc.svgShapes((box.x.float, box.y.float, float(box.x + box.w), float(box.y + box.h)), color)
  if shapes.len == 0: return
  let own = not d.stepOpen
  if own: d.beginStep("Place SVG")
  d.touchLayers()
  let title = if doc.title.len > 0: doc.title else: "SVG"
  var g: Layer = nil
  if asGroup and shapes.len > 1:
    g = d.addGroup(title)
    result.add g
  for (name, s) in shapes:
    let nm = if name.len > 0: name elif shapes.len == 1: title else: ""
    result.add d.addShapeLayer(s, nm)
  if g != nil:
    let i = d.layers.find(g)
    if i >= 0: d.cur = i
  if own: d.endStep()

proc rasterizeSvg*(doc: SvgDoc; w, h: int; color = 0xFF000000'u32): Bitmap =
  ## The SVG drawn into a `w` x `h` bitmap (transparent where it draws
  ## nothing), fitted (its aspect kept, centered); currentColor `color`.
  result = newBitmap(max(0, w), max(0, h))
  if w <= 0 or h <= 0: return
  var r = Rnd(w: w, h: h, m: svgMap(doc, 0, 0, w.float, h.float), color: color, tol: 0.1)
  r.clipCov = newSeq[ClipCov](doc.clips.len)
  r.clipDone = newSeq[bool](doc.clips.len)
  r.k = scaleOf(r.m)
  if not (r.k > 0) or not finite(r.k): return
  var px = newSeq[uint32](w * h)
  r.drawList(doc, doc.items, px)
  for i in 0 ..< w * h:
    let p = px[i]
    let a = p shr 24
    if a == 0: continue
    if a == 255:
      result.px[i] = p
      continue
    let f = 255 / a.float
    result.px[i] = (a shl 24) or (uint32(min(255, toInt(float((p shr 16) and 255) * f + 0.5))) shl 16) or
                   (uint32(min(255, toInt(float((p shr 8) and 255) * f + 0.5))) shl 8) or
                   uint32(min(255, toInt(float(p and 255) * f + 0.5)))
  result.opaque = false

proc rasterizeSvg*(data: string; w, h: int; color = 0xFF000000'u32): Bitmap =
  ## The SVG file `data` drawn into a `w` x `h` bitmap (see above): for
  ## thumbnails, and art too complex to keep as shapes.
  rasterizeSvg(parseSvg(data), w, h, color)

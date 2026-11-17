## Equations in type: math written as TeX writes it -- the part most equations use -- set in
## the kit's serif as a typesetter sets it: variables in italic, numbers and names upright,
## fractions over their bar, roots under their sign, superscripts and subscripts smaller,
## sums, products and integrals big with their limits, fences as tall as what they hold,
## Greek letters, operators and relations spaced as they should be. What comes out is outlines
## (`mathPolys`), for a shape layer or a PDF.
##
##   x^2 + y_1        \frac{a+b}{2}      \sqrt{b^2-4ac}     \sqrt[3]{x}
##   \sum_{i=1}^{n} i \int_0^\infty e^{-x}\,dx               \left( \frac{1}{2} \right)
##   \alpha \beta \pi \Omega   \le \ge \ne \approx \pm \times \cdot \to \infty \partial
##   \sin x  \log_2 n  \lim_{n \to \infty}   \text{if } x > 0
##
## .. code-block:: nim
##   let m = setMath("E = mc^2", size = 48)
##   for poly in m.mathPolys: echo poly.len           # its letters' outlines, in pixels
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[tables, unicode]
import ttf, textengine

type
  MathGlyph* = object
    ## A character of a set equation.
    cp*: int                   ## the character
    x*, y*: float              ## its pen position, the baseline's (pixels, y down from the top)
    size*: float               ## its size (pixels)
    italic*: bool              ## in the italic
    sy*: float                 ## (stretched up and down so many times: a tall fence; 1 not)

  MathSet* = object
    ## An equation set (`setMath`): its characters and its bars (fractions, roots).
    glyphs*: seq[MathGlyph]
    polys*: seq[seq[(float32, float32)]]   ## bars and radical signs, closed polygons
    w*, h*: float              ## how big it is
    baseline*: float           ## where its baseline is, from its top
    error*: string             ## what could not be read ("" all of it)

  Box = object
    w, asc, desc: float        ## (in pixels at the size it was set)
    glyphs: seq[MathGlyph]
    polys: seq[seq[(float32, float32)]]

  AtomKind = enum akOrd, akOp, akBin, akRel, akOpen, akClose, akPunct

  Parser = object
    s: seq[Rune]
    i: int
    err: string

const
  Greek = {"alpha": 0x3B1, "beta": 0x3B2, "gamma": 0x3B3, "delta": 0x3B4, "epsilon": 0x3B5,
           "varepsilon": 0x3B5, "zeta": 0x3B6, "eta": 0x3B7, "theta": 0x3B8, "vartheta": 0x3D1,
           "iota": 0x3B9, "kappa": 0x3BA, "lambda": 0x3BB, "mu": 0x3BC, "nu": 0x3BD, "xi": 0x3BE,
           "pi": 0x3C0, "varpi": 0x3D6, "rho": 0x3C1, "sigma": 0x3C3, "varsigma": 0x3C2, "tau": 0x3C4,
           "upsilon": 0x3C5, "phi": 0x3D5, "varphi": 0x3C6, "chi": 0x3C7, "psi": 0x3C8, "omega": 0x3C9,
           "Gamma": 0x393, "Delta": 0x394, "Theta": 0x398, "Lambda": 0x39B, "Xi": 0x39E, "Pi": 0x3A0,
           "Sigma": 0x3A3, "Upsilon": 0x3A5, "Phi": 0x3A6, "Psi": 0x3A8, "Omega": 0x3A9}.toTable
  Symbols = {"pm": (0xB1, akBin), "mp": (0x2213, akBin), "times": (0xD7, akBin), "div": (0xF7, akBin),
             "cdot": (0x22C5, akBin), "ast": (0x2217, akBin), "circ": (0x2218, akBin),
             "cup": (0x222A, akBin), "cap": (0x2229, akBin), "wedge": (0x2227, akBin), "vee": (0x2228, akBin),
             "le": (0x2264, akRel), "leq": (0x2264, akRel), "ge": (0x2265, akRel), "geq": (0x2265, akRel),
             "ne": (0x2260, akRel), "neq": (0x2260, akRel), "approx": (0x2248, akRel), "equiv": (0x2261, akRel),
             "sim": (0x223C, akRel), "propto": (0x221D, akRel), "in": (0x2208, akRel), "notin": (0x2209, akRel),
             "subset": (0x2282, akRel), "supset": (0x2283, akRel), "subseteq": (0x2286, akRel),
             "to": (0x2192, akRel), "rightarrow": (0x2192, akRel), "leftarrow": (0x2190, akRel),
             "Rightarrow": (0x21D2, akRel), "Leftrightarrow": (0x21D4, akRel), "mapsto": (0x21A6, akRel),
             "infty": (0x221E, akOrd), "partial": (0x2202, akOrd), "nabla": (0x2207, akOrd),
             "forall": (0x2200, akOrd), "exists": (0x2203, akOrd), "emptyset": (0x2205, akOrd),
             "degree": (0xB0, akOrd), "prime": (0x2032, akOrd), "ldots": (0x2026, akOrd),
             "cdots": (0x22EF, akOrd), "hbar": (0x210F, akOrd), "ell": (0x2113, akOrd),
             "angle": (0x2220, akOrd), "triangle": (0x25B3, akOrd), "neg": (0xAC, akOrd),
             "langle": (0x27E8, akOpen), "rangle": (0x27E9, akClose),
             "lbrace": (0x7B, akOpen), "rbrace": (0x7D, akClose)}.toTable
  BigOps = {"sum": 0x2211, "prod": 0x220F, "coprod": 0x2210, "int": 0x222B, "iint": 0x222C, "oint": 0x222E,
            "bigcup": 0x22C3, "bigcap": 0x22C2}.toTable
  Functions = ["sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh",
               "tanh", "log", "ln", "lg", "exp", "lim", "max", "min", "sup", "inf", "det", "gcd", "deg",
               "dim", "ker", "arg", "Pr"]
  Limits = ["lim", "max", "min", "sup", "inf"]

var faces: array[bool, Face]

proc faceOf(italic: bool): Face =
  if faces[italic] == nil: faces[italic] = fontFace("FreeSerif", if italic: "Italic" else: "Regular").face
  faces[italic]

proc glyphBox(cp: int; size: float; italic: bool; sy = 1.0): Box =
  ## (a character alone)
  let f = faceOf(italic)
  let g = f.glyphOf(cp)
  let em = float(max(1, f.unitsPerEm))
  let b = f.bounds(g)
  result.w = float(f.advance(g)) / em * size
  result.asc = max(0.0, float(b.y1) / em * size * sy)
  result.desc = max(0.0, -float(b.y0) / em * size * sy)
  if b.y1 <= b.y0:
    result.asc = 0.7 * size
    result.desc = 0
  if italic and cp in [ord('f'), ord('j')]: result.w += 0.08 * size      # (its tail)
  result.glyphs.add MathGlyph(cp: cp, x: 0, y: 0, size: size, italic: italic, sy: sy)

proc place(dst: var Box; b: Box; dx, dy: float) =
  ## (`b` put into `dst`, its pen at `dx`, its baseline `dy` down)
  for g in b.glyphs:
    var q = g
    q.x += dx
    q.y += dy
    dst.glyphs.add q
  for p in b.polys:
    var q = p
    for v in q.mitems: v = (v[0] + float32(dx), v[1] + float32(dy))
    dst.polys.add q

proc rule(x, y, w, h: float): seq[(float32, float32)] =
  @[(float32(x), float32(y)), (float32(x + w), float32(y)), (float32(x + w), float32(y + h)),
    (float32(x), float32(y + h))]

proc hlist(items: seq[(Box, AtomKind)]; size: float): Box =
  ## (atoms side by side, with the room a typesetter puts round operators and relations)
  var x = 0.0
  var prev = akOpen
  for k, (b, kind) in items:
    var kind = kind
    if kind == akBin and (k == 0 or prev in {akBin, akRel, akOpen, akOp, akPunct}): kind = akOrd   # (a sign: -x)
    if k > 0:
      let gap = if kind == akRel or prev == akRel: 0.28
                elif kind == akBin or prev == akBin: 0.22
                elif kind == akOp or (prev == akOp and kind notin {akClose, akPunct}): 0.17
                elif prev == akPunct: 0.17
                else: 0.0
      x += gap * size
    result.place(b, x, 0)
    result.asc = max(result.asc, b.asc)
    result.desc = max(result.desc, b.desc)
    x += b.w
    prev = kind
  result.w = x

proc peek(p: Parser): int = (if p.i < p.s.len: int(p.s[p.i]) else: -1)

proc skipSpace(p: var Parser) =
  while p.i < p.s.len and int(p.s[p.i]) in [ord(' '), ord('\t'), ord('\n'), ord('\r')]: inc p.i

proc command(p: var Parser): string =
  ## (after a backslash: its name, or one character)
  if p.i >= p.s.len: return ""
  if p.s[p.i].isAlpha:
    while p.i < p.s.len and int(p.s[p.i]) < 128 and p.s[p.i].isAlpha:
      result.add char(int(p.s[p.i]))
      inc p.i
  else:
    result = $p.s[p.i]
    inc p.i

proc parseList(p: var Parser; size: float; stop: set[char]; atEnd: var string): Box
proc parseAtom(p: var Parser; size: float; kind: var AtomKind): Box

proc groupArg(p: var Parser; size: float): Box =
  ## (a `{...}` or one atom)
  p.skipSpace()
  if p.peek == ord('{'):
    inc p.i
    var e = ""
    result = p.parseList(size, {'}'}, e)
    if p.peek == ord('}'): inc p.i
    else: p.err = "a { without its }"
  else:
    var k = akOrd
    result = p.parseAtom(size, k)

proc rawGroup(p: var Parser): string =
  ## (a `{...}` as it is written: \text's words)
  p.skipSpace()
  if p.peek != ord('{'): return
  inc p.i
  var depth = 1
  while p.i < p.s.len:
    let c = int(p.s[p.i])
    if c == ord('{'): inc depth
    elif c == ord('}'):
      dec depth
      if depth == 0:
        inc p.i
        return
    result.add $p.s[p.i]
    inc p.i
  p.err = "a { without its }"

proc textBox(s: string; size: float; italic = false): Box =
  var items: seq[(Box, AtomKind)]
  for r in s.runes: items.add (glyphBox(int(r), size, italic), akOrd)
  hlist(items, size)

proc fraction(num, den: Box; size: float): Box =
  ## (`num` over `den`, centered, the bar on the math axis)
  let axis = 0.26 * size
  let t = max(1.0, 0.05 * size)
  let gap = 0.16 * size
  result.w = max(num.w, den.w) + 0.2 * size
  result.place(num, (result.w - num.w) / 2, -(axis + t / 2 + gap + num.desc))
  result.place(den, (result.w - den.w) / 2, -(axis - t / 2 - gap - den.asc))
  result.polys.add rule(0.05 * size, -axis - t / 2, result.w - 0.1 * size, t)
  result.asc = axis + t / 2 + gap + num.desc + num.asc
  result.desc = max(0.0, -(axis - t / 2 - gap - den.asc - den.desc))

proc root(body: Box; index: Box; hasIndex: bool; size: float): Box =
  ## (`body` under a radical sign drawn as tall as it, an overline over it)
  let t = max(1.0, 0.05 * size)
  let top = body.asc + 0.14 * size
  let bot = body.desc + 0.04 * size
  let sw = 0.55 * size
  var x0 = 0.0
  if hasIndex:
    result.place(index, 0, -(top * 0.45))
    x0 = max(0.0, index.w - 0.25 * size)
  # (the sign: a short stroke up, a long one down to the foot, up to the top)
  let a = (float32(x0), float32(-(top - bot) * 0.35))
  let b = (float32(x0 + sw * 0.22), float32(-(top - bot) * 0.45))
  let c = (float32(x0 + sw * 0.5), float32(bot))
  let d = (float32(x0 + sw), float32(-top))
  let tw = float32(t)
  result.polys.add @[a, b, (c[0], c[1] - tw * 2.2), (d[0], d[1]), (d[0] + tw, d[1] + tw), (c[0], c[1]),
                     (b[0] - tw * 0.6, b[1] + tw * 1.4), (a[0], a[1] + tw)]
  result.polys.add rule(x0 + sw, -top, body.w + 0.1 * size, t)
  result.place(body, x0 + sw + 0.05 * size, 0)
  result.w = x0 + sw + body.w + 0.15 * size
  result.asc = top + t
  result.desc = bot
  if hasIndex: result.asc = max(result.asc, top * 0.45 + index.asc)

proc scripts(base: Box; sup, sub: Box; hasSup, hasSub: bool; size: float; limits: bool): Box =
  ## (superscripts up, subscripts down -- above and below a big operator's middle)
  if limits:
    let w = max(base.w, max(if hasSup: sup.w else: 0.0, if hasSub: sub.w else: 0.0))
    result.place(base, (w - base.w) / 2, 0)
    result.w = w
    result.asc = base.asc
    result.desc = base.desc
    if hasSup:
      let y = -(base.asc + 0.12 * size + sup.desc)
      result.place(sup, (w - sup.w) / 2, y)
      result.asc = base.asc + 0.12 * size + sup.desc + sup.asc
    if hasSub:
      let y = base.desc + 0.12 * size + sub.asc
      result.place(sub, (w - sub.w) / 2, y)
      result.desc = base.desc + 0.12 * size + sub.asc + sub.desc
    return
  result.place(base, 0, 0)
  result.asc = base.asc
  result.desc = base.desc
  var w = base.w
  let x = base.w + 0.04 * size
  if hasSup:
    let y = -max(0.42 * size, base.asc - 0.25 * size)
    result.place(sup, x, y)
    result.asc = max(result.asc, -y + sup.asc)
    w = max(w, x + sup.w)
  if hasSub:
    let y = max(0.22 * size, base.desc + 0.1 * size) + (if hasSup: 0.08 * size else: 0.0)
    result.place(sub, x, y)
    result.desc = max(result.desc, y + sub.desc)
    w = max(w, x + sub.w)
  result.w = w + 0.03 * size

proc fence(cp: int; inner: Box; size: float): Box =
  ## (a parenthesis, bracket or bar as tall as what it holds)
  if cp <= 0: return
  let one = glyphBox(cp, size, false)
  let h = inner.asc + inner.desc
  let h1 = max(1.0, one.asc + one.desc)
  let sy = max(1.0, (h + 0.1 * size) / h1)
  result = glyphBox(cp, size, false, sy)
  # (stretched round the middle of what it holds)
  let mid = (inner.asc - inner.desc) / 2
  let oneMid = (one.asc - one.desc) / 2 * sy
  let dy = oneMid - mid
  for g in result.glyphs.mitems: g.y += dy
  result.asc = one.asc * sy - dy
  result.desc = one.desc * sy + dy

proc parseAtom(p: var Parser; size: float; kind: var AtomKind): Box =
  p.skipSpace()
  kind = akOrd
  let c = p.peek
  if c < 0: return
  if c == ord('{'):
    return p.groupArg(size)
  if c == ord('\\'):
    inc p.i
    let name = p.command()
    case name
    of "frac", "dfrac", "tfrac":
      let n = p.groupArg(size * 0.9)
      let d = p.groupArg(size * 0.9)
      return fraction(n, d, size)
    of "sqrt":
      p.skipSpace()
      var idx: Box
      var has = false
      if p.peek == ord('['):
        inc p.i
        var e = ""
        idx = p.parseList(size * 0.55, {']'}, e)
        if p.peek == ord(']'): inc p.i
        has = true
      let body = p.groupArg(size)
      return root(body, idx, has, size)
    of "text", "mathrm", "operatorname":
      let t = p.rawGroup()
      return textBox(t, size)
    of "mathbf", "boldsymbol":
      return p.groupArg(size)
    of "left", "right", "big", "Big", "bigl", "bigr":
      # (\left ( ... \right ): the fences as tall as what is between them)
      p.skipSpace()
      var cp = p.peek
      if cp == ord('\\'):
        inc p.i
        let nm = p.command()
        cp = if nm in Symbols: Symbols[nm][0] elif nm == "|": 0x2016 elif nm == "{": ord('{')
             elif nm == "}": ord('}') else: 0
      elif cp >= 0: inc p.i
      if cp == ord('.'): cp = 0
      if name == "left":
        var e = ""
        let inner = p.parseList(size, {}, e)
        # (the \right that ends it)
        p.skipSpace()
        var cp2 = 0
        if e == "right":
          p.skipSpace()
          cp2 = p.peek
          if cp2 == ord('\\'):
            inc p.i
            let nm = p.command()
            cp2 = if nm in Symbols: Symbols[nm][0] elif nm == "|": 0x2016 elif nm == "}": ord('}') else: 0
          elif cp2 >= 0: inc p.i
          if cp2 == ord('.'): cp2 = 0
        else: p.err = "a \\left without its \\right"
        var items: seq[(Box, AtomKind)]
        if cp > 0: items.add (fence(cp, inner, size), akOpen)
        items.add (inner, akOrd)
        if cp2 > 0: items.add (fence(cp2, inner, size), akClose)
        return hlist(items, size)
      kind = if name == "right" or name == "bigr": akClose else: akOpen
      return if cp > 0: glyphBox(cp, size * 1.2, false) else: Box()
    of ",": return Box(w: 0.17 * size)
    of ":", ">": return Box(w: 0.22 * size)
    of ";": return Box(w: 0.28 * size)
    of "quad": return Box(w: size)
    of "qquad": return Box(w: 2 * size)
    of "!": return Box(w: -0.17 * size)
    of " ": return Box(w: 0.25 * size)
    of "\\": return Box()
    of "{", "}", "%", "$", "&", "#", "_":
      return glyphBox(ord(name[0]), size, false)
    of "|":
      return glyphBox(0x2016, size, false)
    else: discard
    if name in Greek:
      let cp = Greek[name]
      return glyphBox(cp, size, cp >= 0x3B1)        # (small Greek letters in italic, capitals upright)
    if name in Symbols:
      kind = Symbols[name][1]
      return glyphBox(Symbols[name][0], size, false)
    if name in BigOps:
      kind = akOp
      var b = glyphBox(BigOps[name], size * 1.5, false)
      # (on the math axis)
      let axis = 0.26 * size
      let mid = (b.asc - b.desc) / 2
      for g in b.glyphs.mitems: g.y += mid - axis
      let dy = mid - axis
      b.asc -= dy
      b.desc += dy
      return b
    if name in Functions:
      kind = akOp
      return textBox(name, size)
    p.err = "\\" & name & " is not known"
    return textBox("\\" & name, size)
  inc p.i
  let r = Rune(c)
  if c in [ord('+'), ord('*')]:
    kind = akBin
    return glyphBox(if c == ord('*'): 0x2217 else: c, size, false)
  if c == ord('-'):
    kind = akBin
    return glyphBox(0x2212, size, false)
  if c in [ord('='), ord('<'), ord('>')]:
    kind = akRel
    return glyphBox(c, size, false)
  if c in [ord('('), ord('[')]:
    kind = akOpen
    return glyphBox(c, size, false)
  if c in [ord(')'), ord(']')]:
    kind = akClose
    return glyphBox(c, size, false)
  if c in [ord(','), ord(';')]:
    kind = akPunct
    return glyphBox(c, size, false)
  if c == ord('\''): return glyphBox(0x2032, size * 0.8, false)
  if c == ord('|'): return glyphBox(c, size, false)
  if r.isAlpha and c < 0x370: return glyphBox(c, size, true)        # (a variable: italic)
  glyphBox(c, size, false)

proc parseList(p: var Parser; size: float; stop: set[char]; atEnd: var string): Box =
  ## (atoms until one of `stop`, the end, or \right)
  var items: seq[(Box, AtomKind)]
  while true:
    p.skipSpace()
    let c = p.peek
    if c < 0: break
    if c < 128 and char(c) in stop: break
    if c == ord('}') and '}' notin stop:
      p.err = "a } with no { before it"
      inc p.i
      continue
    if c == ord('\\') and p.i + 5 < p.s.len and $p.s[p.i + 1 .. p.i + 5] == "right":
      p.i += 6
      atEnd = "right"
      break
    var kind = akOrd
    var base = p.parseAtom(size, kind)
    # its scripts, and limits above and below a big operator
    var sup, sub: Box
    var hasSup, hasSub = false
    var limits = false
    if kind == akOp:
      p.skipSpace()
      if p.peek == ord('\\') and p.i + 7 <= p.s.len and $p.s[p.i + 1 .. p.i + 6] == "limits":
        p.i += 7
        limits = true
      for b in base.glyphs:
        if b.cp in [0x2211, 0x220F, 0x2210, 0x22C3, 0x22C2]: limits = true
      if base.glyphs.len > 1 and base.glyphs[0].cp < 128:
        # (lim, max, min: their limits under them)
        var nm = ""
        for g in base.glyphs: nm.add char(g.cp)
        if nm in Limits: limits = true
    while true:
      p.skipSpace()
      let q = p.peek
      if q == ord('^') and not hasSup:
        inc p.i
        sup = p.groupArg(size * (if limits: 0.7 else: 0.7))
        hasSup = true
      elif q == ord('_') and not hasSub:
        inc p.i
        sub = p.groupArg(size * 0.7)
        hasSub = true
      else: break
    if hasSup or hasSub: base = scripts(base, sup, sub, hasSup, hasSub, size, limits)
    items.add (base, kind)
  hlist(items, size)

proc setMath*(src: string; size = 32.0): MathSet =
  ## The equation `src` (TeX's math) set at `size` pixels: what to draw (`mathPolys`), how big
  ## it is, and `error` for what could not be read (what could is set anyway).
  var p = Parser(s: src.toRunes)
  var e = ""
  let b = p.parseList(max(1.0, size), {}, e)
  if e == "right": p.err = "a \\right without its \\left"
  let pad = 0.1 * size
  result.w = b.w + 2 * pad
  result.baseline = b.asc + pad
  result.h = b.asc + b.desc + 2 * pad
  for g in b.glyphs:
    var q = g
    q.x += pad
    q.y += result.baseline
    result.glyphs.add q
  for poly in b.polys:
    var q = poly
    for v in q.mitems: v = (v[0] + float32(pad), v[1] + float32(result.baseline))
    result.polys.add q
  result.error = p.err

proc mathPolys*(m: MathSet; dx = 0.0; dy = 0.0): seq[seq[(float32, float32)]] =
  ## The equation's outlines -- its characters' and its bars' -- as closed polygons in pixels
  ## (y down), moved by `dx`, `dy`: to fill, nonzero.
  for g in m.glyphs:
    let f = faceOf(g.italic)
    let gid = f.glyphOf(g.cp)
    if gid == 0: continue
    let k = g.size / float(max(1, f.unitsPerEm))
    for c in f.contours(gid, steps = 8):
      var poly: seq[(float32, float32)]
      for v in c: poly.add (float32(g.x + dx + float(v[0]) * k), float32(g.y + dy - float(v[1]) * k * g.sy))
      if poly.len >= 3: result.add poly
  for poly in m.polys:
    var q = poly
    for v in q.mitems: v = (v[0] + float32(dx), v[1] + float32(dy))
    result.add q

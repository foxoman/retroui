## The pages drawn (`pdfreadpaint`, included by `pdfread`, not imported on
## its own): their content streams run on a 2D canvas -- paths, colors,
## pictures, text, gradients, clipping -- or read for their text
## (`pageText`), or for their outlines (`pageVectors`).
##
## ```nim
## let f = openPdf(readFile("logo.ai"))
## let pic = f.renderPage(0, dpi = 150)          # a Bitmap
## for v in f.pageVectors(0, dpi = 72):
##   echo v.subs.len, " subpaths, fill ", v.fill.toHex
## ```

import photoinks

type
  Mat = array[6, float]

  CsKind = enum csGray, csRGB, csCMYK, csIndexed, csSep, csLab, csPattern
  ColorSpace = ref object
    kind: CsKind
    n: int                       ## components
    base: ColorSpace             ## (indexed) the base; (separation) the alternate
    lookup: string               ## (indexed) the table
    hival: int
    fn: PObj                     ## (separation, DeviceN) the tint transform
    none: bool                   ## (separation /None: paints nothing)

  GState = object
    ctm: Mat
    fillCs, strokeCs: ColorSpace
    fill, stroke: uint32
    fillPat, strokePat: PObj
    lineWidth: float
    cap, join: int
    miter: float
    dash: seq[float]
    dashPhase: float
    fillAlpha, strokeAlpha: float
    font: FontInfo
    fontSize, charSpace, wordSpace, hScale, leading, rise: float
    render: int

  RunMode = enum rmDraw, rmText, rmVectors

  PdfVector* = object
    ## An outline of a page, collected (`pageVectors`): its subpaths in
    ## pixels of the page at the resolution asked (y down), what fills and
    ## strokes it.
    subs*: seq[seq[tuple[op: char; x1, y1, x2, y2, x3, y3: float]]]
      ## each subpath's steps: 'm' move to (x1, y1), 'l' line to it, 'c' a
      ## curve through (x1, y1), (x2, y2) to (x3, y3), 'h' close
    fill*, stroke*: uint32       ## (alpha 0: none)
    evenOdd*: bool               ## filled even-odd (else nonzero)
    width*: float                ## the stroke's width in pixels

  Painter = object
    f: PdfFile
    c: Canvas2D
    dev: Mat
    gs: GState
    stack: seq[GState]
    path: GPath                  ## the current path, in device pixels
    clipPending: int             ## 0 none, 1 nonzero, 2 even-odd
    tm, tlm: Mat
    mode: RunMode
    text: seq[tuple[x, y, w, size: float; s: string; actual: bool]]
      ## (each glyph's text where it stands, and how far it goes)
    marked: seq[string]          ## (marked content open: each one's /ActualText, "" none)
    actualAt: int                ## (the outermost open one with an /ActualText, +1; 0 none)
    actualShown: bool            ## (... its text given)
    vectors: seq[PdfVector]
    depth: int
    ops: int
    inGlyph: bool                ## (painting a glyph's outline)
    skipPaths: bool              ## (draw text and pictures only: the outlines go to shape layers)
    withGlyphs: bool             ## (collect: the text's outlines too)

const ident: Mat = [1.0, 0, 0, 1, 0, 0]

proc mul(a, b: Mat): Mat =
  ## `a` then `b`.
  [a[0] * b[0] + a[1] * b[2], a[0] * b[1] + a[1] * b[3],
   a[2] * b[0] + a[3] * b[2], a[2] * b[1] + a[3] * b[3],
   a[4] * b[0] + a[5] * b[2] + b[4], a[4] * b[1] + a[5] * b[3] + b[5]]

proc apply(m: Mat; x, y: float): (float, float) {.inline.} =
  (m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5])

proc matOf(f: PdfFile; o: PObj): Mat =
  let a = f.resolve(o).arr
  if a.len < 6: return ident
  for k in 0 .. 5: result[k] = f.resolve(a[k]).num

proc scaleOf(m: Mat): float = sqrt(abs(m[0] * m[3] - m[1] * m[2]))

# ---- functions (tint transforms, gradients) ----------------------------------------------------------

proc evalFn(f: PdfFile; fo: PObj; input: seq[float]; depth = 0): seq[float] =
  result = @[]         # (a value at once: see tools/writecheck.py)
  let fn = f.resolve(fo)
  if depth > 8: result = input; return
  if fn.kind == pkArr:
    # (several functions of one input each giving one output)
    for x in fn.a: result.add f.evalFn(x, input, depth + 1)
    return
  if not fn.isDict: result = input; return
  let dom = f.g(fn, "Domain").arr
  var x = input
  for i in 0 ..< x.len:
    if 2 * i + 1 < dom.len: x[i] = clamp(x[i], f.resolve(dom[2 * i]).num, f.resolve(dom[2 * i + 1]).num)
  let rng = f.g(fn, "Range").arr
  case f.g(fn, "FunctionType").int0
  of 2:
    let c0 = f.g(fn, "C0").arr
    let c1 = f.g(fn, "C1").arr
    let n = f.g(fn, "N").num(1)
    let t = if x.len > 0: x[0] else: 0.0
    let k = max(c0.len, c1.len)
    for i in 0 ..< max(1, k):
      let a = if i < c0.len: f.resolve(c0[i]).num else: (if c0.len == 0 and i == 0: 0.0 else: 0.0)
      let b = if i < c1.len: f.resolve(c1[i]).num else: (if c1.len == 0 and i == 0: 1.0 else: 0.0)
      result.add a + pow(max(0.0, t), n) * (b - a)
  of 3:
    let fns = f.g(fn, "Functions").arr
    let bounds = f.g(fn, "Bounds").arr
    let enc = f.g(fn, "Encode").arr
    let t = if x.len > 0: x[0] else: 0.0
    let d0 = if dom.len >= 2: f.resolve(dom[0]).num else: 0.0
    let d1 = if dom.len >= 2: f.resolve(dom[1]).num else: 1.0
    var k = 0
    while k < bounds.len and t >= f.resolve(bounds[k]).num: inc k
    if fns.len == 0: result = input; return
    k = min(k, fns.high)
    let lo = if k == 0: d0 else: f.resolve(bounds[k - 1]).num
    let hi = if k < bounds.len: f.resolve(bounds[k]).num else: d1
    let e0 = if 2 * k < enc.len: f.resolve(enc[2 * k]).num else: 0.0
    let e1 = if 2 * k + 1 < enc.len: f.resolve(enc[2 * k + 1]).num else: 1.0
    let u = if hi > lo: e0 + (t - lo) / (hi - lo) * (e1 - e0) else: e0
    result = f.evalFn(fns[k], @[u], depth + 1)
  of 0:
    let size = f.g(fn, "Size").arr
    let bps = f.g(fn, "BitsPerSample").int0(8)
    let data = f.decodeStream(fn)
    let nOut = max(1, rng.len div 2)
    let enc = f.g(fn, "Encode").arr
    let dec = f.g(fn, "Decode").arr
    # (one input, nearest sample -- linear between two)
    let sz = if size.len > 0: max(1, f.resolve(size[0]).int0) else: 1
    let d0 = if dom.len >= 2: f.resolve(dom[0]).num else: 0.0
    let d1 = if dom.len >= 2: f.resolve(dom[1]).num else: 1.0
    let e0 = if enc.len >= 2: f.resolve(enc[0]).num else: 0.0
    let e1 = if enc.len >= 2: f.resolve(enc[1]).num else: (sz - 1).float
    let t = if x.len > 0: x[0] else: 0.0
    let pos = clamp(e0 + (t - d0) / max(1e-9, d1 - d0) * (e1 - e0), 0.0, (sz - 1).float)
    let i0 = int(floor(pos))
    let i1 = min(sz - 1, i0 + 1)
    let fr = pos - i0.float
    proc sample(i, o: int): float =
      let bitPos = (i * nOut + o) * bps
      var v = 0
      if bps == 8: v = u8(data, bitPos div 8)
      elif bps == 16: v = u16(data, bitPos div 8)
      elif bps < 8:
        v = (u8(data, bitPos div 8) shr (8 - bps - (bitPos mod 8))) and ((1 shl bps) - 1)
      else: v = u8(data, bitPos div 8)
      v.float / float((1 shl bps) - 1)
    for o in 0 ..< nOut:
      let s = sample(i0, o) * (1 - fr) + sample(i1, o) * fr
      let r0 = if 2 * o < dec.len: f.resolve(dec[2 * o]).num elif 2 * o < rng.len: f.resolve(rng[2 * o]).num else: 0.0
      let r1 = if 2 * o + 1 < dec.len: f.resolve(dec[2 * o + 1]).num elif 2 * o + 1 < rng.len: f.resolve(rng[2 * o + 1]).num else: 1.0
      result.add r0 + s * (r1 - r0)
  of 4:
    # the PostScript calculator: a small stack machine
    let code = f.decodeStream(fn)
    var lx = Lexer(s: unsafeAddr code, p: 0)
    var toks: seq[PObj]
    while not lx.atEnd:
      lx.skipWs()
      if lx.atEnd: break
      let c = code[lx.p]
      if c == '{':
        toks.add PObj(kind: pkName, s: "\x01{")
        inc lx.p
      elif c == '}':
        toks.add PObj(kind: pkName, s: "\x01}")
        inc lx.p
      else:
        let st = lx.p
        toks.add lx.parseObj()
        if lx.p == st: inc lx.p
    var st: seq[float] = x
    proc runFrom(i0: int; stopAt: var int) =
      ## (runs the block starting after "{" at `i0`; `stopAt` is set to its "}")
      var i = i0
      while i < toks.len:
        let t = toks[i]
        if t.kind == pkNum:
          st.add t.n
          inc i
          continue
        let op = if t.kind == pkName and t.s.len > 1: t.s[1 .. ^1] else: ""
        template pop1(): float = (if st.len > 0: st.pop() else: 0.0)
        case op
        of "}":
          stopAt = i
          return
        of "{":
          # a procedure (for if / ifelse): find its end, then the next
          var e1 = 0
          var depthB = 1
          var j = i + 1
          while j < toks.len and depthB > 0:
            let s2 = toks[j].s
            if s2 == "\x01{": inc depthB
            elif s2 == "\x01}": dec depthB
            inc j
          e1 = j - 1
          if j < toks.len and toks[j].s == "\x01{":
            var depthC = 1
            var k = j + 1
            while k < toks.len and depthC > 0:
              let s3 = toks[k].s
              if s3 == "\x01{": inc depthC
              elif s3 == "\x01}": dec depthC
              inc k
            # ifelse
            let cond = pop1() != 0
            var dummy = 0
            if cond: runFrom(i + 1, dummy) else: runFrom(j + 1, dummy)
            i = k + 1                               # (past "ifelse")
          else:
            let cond = pop1() != 0
            var dummy = 0
            if cond: runFrom(i + 1, dummy)
            i = e1 + 2                              # (past "if")
          continue
        of "add": (let b = pop1(); let a = pop1(); st.add a + b)
        of "sub": (let b = pop1(); let a = pop1(); st.add a - b)
        of "mul": (let b = pop1(); let a = pop1(); st.add a * b)
        of "div": (let b = pop1(); let a = pop1(); st.add(if b != 0: a / b else: 0.0))
        of "idiv": (let b = pop1(); let a = pop1(); st.add(if b != 0: float(int(a) div int(b)) else: 0.0))
        of "mod": (let b = pop1(); let a = pop1(); st.add(if b != 0: float(int(a) mod int(b)) else: 0.0))
        of "neg": st.add -pop1()
        of "abs": st.add abs(pop1())
        of "sqrt": st.add sqrt(max(0.0, pop1()))
        of "exp": (let b = pop1(); let a = pop1(); st.add pow(a, b))
        of "ln": st.add ln(max(1e-12, pop1()))
        of "log": st.add log10(max(1e-12, pop1()))
        of "sin": st.add sin(degToRad(pop1()))
        of "cos": st.add cos(degToRad(pop1()))
        of "atan": (let b = pop1(); let a = pop1(); st.add radToDeg(arctan2(a, b)))
        of "floor": st.add floor(pop1())
        of "ceiling": st.add ceil(pop1())
        of "round": st.add round(pop1())
        of "truncate": st.add trunc(pop1())
        of "cvi": st.add trunc(pop1())
        of "cvr": discard
        of "dup": (let a = pop1(); st.add a; st.add a)
        of "pop": discard pop1()
        of "exch": (let b = pop1(); let a = pop1(); st.add b; st.add a)
        of "copy":
          let n = int(pop1())
          if n > 0 and n <= st.len:
            let base = st.len - n
            for k in 0 ..< n: st.add st[base + k]
        of "index":
          let n = int(pop1())
          if n >= 0 and n < st.len: st.add st[st.high - n]
        of "roll":
          let j = int(pop1())
          let n = int(pop1())
          if n > 0 and n <= st.len:
            var part = st[st.len - n .. ^1]
            let s = ((j mod n) + n) mod n
            for k in 0 ..< n: st[st.len - n + (k + s) mod n] = part[k]
        of "eq": (let b = pop1(); let a = pop1(); st.add(if a == b: 1.0 else: 0.0))
        of "ne": (let b = pop1(); let a = pop1(); st.add(if a != b: 1.0 else: 0.0))
        of "gt": (let b = pop1(); let a = pop1(); st.add(if a > b: 1.0 else: 0.0))
        of "ge": (let b = pop1(); let a = pop1(); st.add(if a >= b: 1.0 else: 0.0))
        of "lt": (let b = pop1(); let a = pop1(); st.add(if a < b: 1.0 else: 0.0))
        of "le": (let b = pop1(); let a = pop1(); st.add(if a <= b: 1.0 else: 0.0))
        of "and": (let b = pop1(); let a = pop1(); st.add float(int(a) and int(b)))
        of "or": (let b = pop1(); let a = pop1(); st.add float(int(a) or int(b)))
        of "xor": (let b = pop1(); let a = pop1(); st.add float(int(a) xor int(b)))
        of "not": (let a = pop1(); st.add(if a == 0: 1.0 elif a == 1: 0.0 else: float(not int(a))))
        of "true": st.add 1.0
        of "false": st.add 0.0
        else: discard
        inc i
    var stop = 0
    var start = 0
    while start < toks.len and toks[start].s != "\x01{": inc start
    runFrom(start + 1, stop)
    let nOut = max(1, rng.len div 2)
    result = st[max(0, st.len - nOut) .. ^1]
  else: result = input
  for i in 0 ..< result.len:
    if 2 * i + 1 < rng.len:
      result[i] = clamp(result[i], f.resolve(rng[2 * i]).num, f.resolve(rng[2 * i + 1]).num)

# ---- colors -------------------------------------------------------------------------------------------------

# (fresh ones each time: no object is shared by the threads drawing pages)
template gray: ColorSpace = ColorSpace(kind: csGray, n: 1)
template rgbCs: ColorSpace = ColorSpace(kind: csRGB, n: 3)
template cmykCs: ColorSpace = ColorSpace(kind: csCMYK, n: 4)

proc b8(v: float): int {.inline.} = clamp(int(round(v * 255)), 0, 255)

proc toRgb(f: PdfFile; cs: ColorSpace; v: openArray[float]): uint32 =
  ## A color in a color space as ARGB (alpha 255).
  template at(i: int): float = (if i < v.len: v[i] else: 0.0)
  case cs.kind
  of csGray:
    let g = b8(at(0))
    0xFF000000'u32 or (uint32(g) shl 16) or (uint32(g) shl 8) or uint32(g)
  of csRGB: 0xFF000000'u32 or (uint32(b8(at(0))) shl 16) or (uint32(b8(at(1))) shl 8) or uint32(b8(at(2)))
  of csCMYK: printed(b8(at(0)), b8(at(1)), b8(at(2)), b8(at(3))) or 0xFF000000'u32
  of csLab:
    let L = at(0)
    let a = at(1)
    let b = at(2)
    let fy = (L + 16) / 116
    let fx = fy + a / 500
    let fz = fy - b / 200
    proc fi(t: float): float = (if t * t * t > 0.008856: t * t * t else: (t - 16 / 116) / 7.787)
    let x = fi(fx) * 0.9505
    let y = fi(fy)
    let z = fi(fz) * 1.089
    proc g(c: float): int =
      let cc = clamp(c, 0.0, 1.0)
      b8(if cc <= 0.0031308: 12.92 * cc else: 1.055 * pow(cc, 1 / 2.4) - 0.055)
    0xFF000000'u32 or (uint32(g(3.2406 * x - 1.5372 * y - 0.4986 * z)) shl 16) or
      (uint32(g(-0.9689 * x + 1.8758 * y + 0.0415 * z)) shl 8) or uint32(g(0.0557 * x - 0.2040 * y + 1.0570 * z))
  of csIndexed:
    let i = clamp(int(at(0)), 0, max(0, cs.hival))
    let nb = max(1, cs.base.n)
    var c: seq[float]
    for k in 0 ..< nb: c.add u8(cs.lookup, i * nb + k).float / 255
    f.toRgb(cs.base, c)
  of csSep:
    if cs.none: return 0
    let o = f.evalFn(cs.fn, @v)
    f.toRgb(cs.base, o)
  of csPattern: 0xFF808080'u32

proc parseCs(f: PdfFile; o: PObj; res: PObj; depth = 0): ColorSpace =
  var o = f.resolve(o)
  if depth > 6: return gray
  if o.kind == pkName:
    case o.s
    of "DeviceGray", "G", "CalGray": return gray
    of "DeviceRGB", "RGB", "CalRGB": return rgbCs
    of "DeviceCMYK", "CMYK": return cmykCs
    of "Pattern": return ColorSpace(kind: csPattern, n: 1)
    else:
      let named = f.g(f.g(res, "ColorSpace"), o.s)
      if named.kind != pkNull: return f.parseCs(named, res, depth + 1)
      return gray
  if o.kind == pkArr and o.a.len > 0:
    let kind = f.resolve(o.a[0]).name
    case kind
    of "ICCBased":
      let st = if o.a.len > 1: f.resolve(o.a[1]) else: nullObj
      let n = f.g(st, "N").int0(3)
      return (if n == 1: gray elif n == 4: cmykCs else: rgbCs)
    of "Indexed", "I":
      let base = if o.a.len > 1: f.parseCs(o.a[1], res, depth + 1) else: rgbCs
      let hival = if o.a.len > 2: f.resolve(o.a[2]).int0 else: 255
      let lk = if o.a.len > 3: f.resolve(o.a[3]) else: nullObj
      let table = if lk.kind == pkStream: f.decodeStream(lk) else: lk.str
      return ColorSpace(kind: csIndexed, n: 1, base: base, lookup: table, hival: hival)
    of "Separation", "DeviceN":
      let names = if o.a.len > 1: f.resolve(o.a[1]) else: nullObj
      let n = if kind == "DeviceN": max(1, names.arr.len) else: 1
      let alt = if o.a.len > 2: f.parseCs(o.a[2], res, depth + 1) else: gray
      let fn = if o.a.len > 3: o.a[3] else: nullObj
      return ColorSpace(kind: csSep, n: n, base: alt, fn: fn, none: names.name == "None")
    of "Lab": return ColorSpace(kind: csLab, n: 3)
    of "CalRGB": return rgbCs
    of "CalGray": return gray
    of "Pattern": return ColorSpace(kind: csPattern, n: 1)
    of "DeviceGray": return gray
    of "DeviceRGB": return rgbCs
    of "DeviceCMYK": return cmykCs
    else: return gray
  gray

# ---- pictures -------------------------------------------------------------------------------------------------

proc decodeImage(p: var Painter; o: PObj; res: PObj; inlineData = ""; isInline = false): Bitmap =
  ## A picture XObject (or an inline picture) as ARGB; its soft mask as
  ## its alpha. An image mask: the fill color where it paints.
  let f = p.f
  let w = f.g(o, "Width").int0(f.g(o, "W").int0)
  let h = f.g(o, "Height").int0(f.g(o, "H").int0)
  if w <= 0 or h <= 0 or w.float * h.float > 64e6: return nil
  let isMask = f.g(o, "ImageMask").kind == pkBool and f.g(o, "ImageMask").b or
               (f.g(o, "IM").kind == pkBool and f.g(o, "IM").b)
  var bpc = f.g(o, "BitsPerComponent").int0(f.g(o, "BPC").int0(8))
  if isMask: bpc = 1
  var csObj = f.g(o, "ColorSpace")
  if csObj.kind == pkNull: csObj = f.g(o, "CS")
  let cs = if isMask: gray else: f.parseCs(csObj, res)
  var dec: seq[float]
  for x in f.g(o, "Decode").arr: dec.add f.resolve(x).num
  if dec.len == 0:
    for x in f.g(o, "D").arr: dec.add f.resolve(x).num
  let codec = f.pictureFilter(o)
  var data = if isInline: inlineData else: f.decodeStream(o)
  # (what is not read is known before `result` is set: `return nil` after
  # it leaks the picture in Nim 2.2)
  let jpeg = codec in ["DCTDecode", "DCT"]
  if codec.len > 0 and not jpeg: return nil       # (JPEG 2000, JBIG2, fax: not read)
  let j = if jpeg: (try: decodeJpeg(data) except CatchableError: nil) else: nil
  if jpeg and j == nil: return nil
  result = newBitmap(w, h)
  if jpeg:
    if j.w == w and j.h == h: result.px = j.px
    else:
      for y in 0 ..< h:
        for x in 0 ..< w:
          result.px[y * w + x] = j.px[min(j.h - 1, y * j.h div h) * j.w + min(j.w - 1, x * j.w div w)]
    if dec.len >= 2 and dec[0] > dec[1]:
      for px in result.px.mitems: px = (px and 0xFF000000'u32) or ((not px) and 0xFFFFFF'u32)
  else:
    let n = if isMask: 1 else: cs.n
    let rowBits = w * n * bpc
    let rowBytes = (rowBits + 7) div 8
    if data.len < rowBytes * h: data.setLen(rowBytes * h)
    let maxV = float((1 shl min(bpc, 16)) - 1)
    var comps = newSeq[float](n)
    let fillC = p.gs.fill
    for y in 0 ..< h:
      let rowAt = y * rowBytes
      for x in 0 ..< w:
        for k in 0 ..< n:
          let bit = (x * n + k) * bpc
          var v: int
          case bpc
          of 8: v = ord(data[rowAt + bit div 8])
          of 16: v = (ord(data[rowAt + bit div 8]) shl 8) or ord(data[rowAt + bit div 8 + 1])
          of 1, 2, 4:
            v = (ord(data[rowAt + bit div 8]) shr (8 - bpc - (bit mod 8))) and ((1 shl bpc) - 1)
          else: v = 0
          var t = v.float / maxV
          if 2 * k + 1 < dec.len: t = dec[2 * k] + t * (dec[2 * k + 1] - dec[2 * k])
          elif cs.kind == csIndexed: t = v.float
          comps[k] = t
        if isMask:
          # (0 paints, unless Decode is [1 0])
          let paints = if dec.len >= 2 and dec[0] > dec[1]: comps[0] > 0.5 else: comps[0] < 0.5
          result.px[y * w + x] = if paints: fillC else: 0'u32
        else:
          result.px[y * w + x] = f.toRgb(cs, comps)
  # its transparency: a soft mask, or a stencil mask
  let sm = f.g(o, "SMask")
  if sm.kind == pkStream and not isMask:
    let sw = f.g(sm, "Width").int0
    let sh = f.g(sm, "Height").int0
    if sw > 0 and sh > 0 and sw.float * sh.float <= 64e6:
      var md = f.decodeStream(sm)
      var mb: Bitmap
      if f.pictureFilter(sm) in ["DCTDecode", "DCT"]:
        mb = try: decodeJpeg(md) except CatchableError: nil
      let sbpc = f.g(sm, "BitsPerComponent").int0(8)
      let rowBytes = (sw * sbpc + 7) div 8
      if mb == nil and md.len < rowBytes * sh: md.setLen(rowBytes * sh)
      for y in 0 ..< h:
        for x in 0 ..< w:
          let mx = x * sw div w
          let my = y * sh div h
          var a: int
          if mb != nil: a = int(mb.px[my * sw + mx] and 255)
          elif sbpc == 8: a = ord(md[my * rowBytes + mx])
          elif sbpc == 1: a = if ((ord(md[my * rowBytes + mx div 8]) shr (7 - mx mod 8)) and 1) != 0: 255 else: 0
          else: a = ord(md[my * rowBytes + (mx * sbpc) div 8])
          let i = y * w + x
          result.px[i] = (result.px[i] and 0xFFFFFF'u32) or (uint32(a) shl 24)
  elif f.g(o, "Mask").kind == pkStream:
    let mk = f.g(o, "Mask")
    let mw = f.g(mk, "Width").int0
    let mh = f.g(mk, "Height").int0
    if mw > 0 and mh > 0:
      var md = f.decodeStream(mk)
      let rowBytes = (mw + 7) div 8
      if md.len < rowBytes * mh: md.setLen(rowBytes * mh)
      var inv = false
      let mdec = f.g(mk, "Decode").arr
      if mdec.len >= 2 and f.resolve(mdec[0]).num > 0.5: inv = true
      for y in 0 ..< h:
        for x in 0 ..< w:
          let mx = x * mw div w
          let my = y * mh div h
          let bit = (ord(md[my * rowBytes + mx div 8]) shr (7 - mx mod 8)) and 1
          let masked = if inv: bit == 0 else: bit == 1
          if masked: result.px[y * w + x] = 0
  result.changed()

# ---- the painter ------------------------------------------------------------------------------------------------

proc colorOf(c: uint32; alpha: float): Color =
  color(uint8((c shr 16) and 255), uint8((c shr 8) and 255), uint8(c and 255),
        uint8(clamp(int(float(c shr 24) * alpha), 0, 255)))

proc toArgb(c: Color): uint32 =
  (uint32(c.a) shl 24) or (uint32(c.r) shl 16) or (uint32(c.g) shl 8) or uint32(c.b)

proc devMat(p: Painter): Mat = mul(p.gs.ctm, p.dev)

proc addPt(p: var Painter; op: char; xs: openArray[float]) =
  let m = p.devMat
  var v: array[6, float]
  var k = 0
  while k + 1 < xs.len:
    let (x, y) = m.apply(xs[k], xs[k + 1])
    v[k] = x
    v[k + 1] = y
    k += 2
  p.path.add (op, v[0], v[1], v[2], v[3], v[4], v[5])

proc feedPath(p: var Painter) =
  ## (the current path into the canvas, in device pixels)
  p.c.resetTransform()
  p.c.beginPath()
  for o in p.path:
    case o.op
    of 'm': p.c.moveTo(o.x1, o.y1)
    of 'l': p.c.lineTo(o.x1, o.y1)
    of 'c': p.c.bezierCurveTo(o.x1, o.y1, o.x2, o.y2, o.x3, o.y3)
    of 'h': p.c.closePath()
    else: discard

proc shadingGradient(p: var Painter; sh: PObj): CanvasGradient =
  ## An axial or radial shading as a canvas gradient (its colors sampled);
  ## nil for the others.
  let f = p.f
  let t = f.g(sh, "ShadingType").int0
  if t notin [2, 3]: return nil
  let coords = f.g(sh, "Coords").arr
  let cs = f.parseCs(f.g(sh, "ColorSpace"), nullObj)
  let dom = f.g(sh, "Domain").arr
  let d0 = if dom.len >= 2: f.resolve(dom[0]).num else: 0.0
  let d1 = if dom.len >= 2: f.resolve(dom[1]).num else: 1.0
  var c: seq[float]
  for x in coords: c.add f.resolve(x).num
  result = if t == 2 and c.len >= 4: p.c.createLinearGradient(c[0], c[1], c[2], c[3])
           elif t == 3 and c.len >= 6: p.c.createRadialGradient(c[0], c[1], c[2], c[3], c[4], c[5])
           else: nil
  if result == nil: return
  let fn = f.g(sh, "Function")
  const steps = 24
  for i in 0 .. steps:
    let u = i / steps
    let col = f.toRgb(cs, f.evalFn(fn, @[d0 + u * (d1 - d0)]))
    result.addColorStop(u, colorOf(col, 1))

proc paint(p: var Painter; doFill, doStroke: bool; evenOdd: bool) =
  let rule = if evenOdd: frEvenOdd else: frNonZero
  if p.mode == rmVectors and p.inGlyph and not p.withGlyphs:
    p.path.setLen(0)
    return
  if p.mode == rmDraw and p.skipPaths and not p.inGlyph:
    # (a path: not drawn -- but a clip still clips)
    if p.clipPending > 0:
      p.feedPath()
      p.c.clip(if p.clipPending == 2: frEvenOdd else: frNonZero)
    p.clipPending = 0
    p.path.setLen(0)
    return
  if p.mode == rmVectors:
    if (doFill or doStroke) and p.path.len > 0:
      var v = PdfVector(evenOdd: evenOdd, width: p.gs.lineWidth * p.devMat.scaleOf)
      if doFill and p.gs.fillPat == nil:
        v.fill = colorOf(p.gs.fill, p.gs.fillAlpha).toArgb
      if doStroke: v.stroke = colorOf(p.gs.stroke, p.gs.strokeAlpha).toArgb
      var cur: seq[tuple[op: char; x1, y1, x2, y2, x3, y3: float]]
      for o in p.path:
        if o.op == 'm' and cur.len > 0:
          v.subs.add cur
          cur.setLen(0)
        cur.add o
      if cur.len > 0: v.subs.add cur
      if v.fill != 0 or v.stroke != 0: p.vectors.add v
  elif p.mode == rmDraw and p.path.len > 0:
    p.feedPath()
    if doFill:
      if p.gs.fillPat != nil:
        let f = p.f
        let pat = p.gs.fillPat
        let pm = f.matOf(f.g(pat, "Matrix"))
        if f.g(pat, "PatternType").int0 == 2:
          let g = p.shadingGradient(f.g(pat, "Shading"))
          if g != nil:
            p.c.save()
            let m = mul(pm, p.dev)
            p.c.setTransform(m[0], m[1], m[2], m[3], m[4], m[5])
            p.c.fillStyle = g
            p.c.globalAlpha = p.gs.fillAlpha
            p.c.fill(rule)
            p.c.restore()
        else:
          # (a tiling pattern: a light gray in its place)
          p.c.fillStyle = color(200, 200, 200, uint8(255 * p.gs.fillAlpha))
          p.c.fill(rule)
      else:
        p.c.fillStyle = colorOf(p.gs.fill, p.gs.fillAlpha)
        p.c.fill(rule)
    if doStroke:
      let s = p.devMat.scaleOf
      p.c.strokeStyle = colorOf(p.gs.stroke, p.gs.strokeAlpha)
      p.c.lineWidth = max(0.6, p.gs.lineWidth * s)
      p.c.lineCap = [lcButt, lcRound, lcSquare][clamp(p.gs.cap, 0, 2)].CanvasLineCap
      p.c.lineJoin = [ljMiter, ljRound, ljBevel][clamp(p.gs.join, 0, 2)].CanvasLineJoin
      p.c.miterLimit = p.gs.miter
      if p.gs.dash.len > 0:
        var d: seq[float]
        for x in p.gs.dash: d.add x * s
        p.c.setLineDash(d)
        p.c.lineDashOffset = p.gs.dashPhase * s
      p.c.stroke()
      if p.gs.dash.len > 0: p.c.setLineDash(newSeq[float]())
  if p.clipPending > 0 and p.mode == rmDraw:
    p.feedPath()
    p.c.clip(if p.clipPending == 2: frEvenOdd else: frNonZero)
  p.clipPending = 0
  p.path.setLen(0)

proc textString(s: string): string =
  ## (a PDF text string as UTF-8: UTF-16 with its byte order mark, else
  ## the bytes as Latin-1)
  if s.len >= 2 and s[0] == '\xFE' and s[1] == '\xFF':
    var i = 2
    while i + 1 < s.len:
      var u = (ord(s[i]) shl 8) or ord(s[i + 1])
      i += 2
      if u in 0xD800 .. 0xDBFF and i + 1 < s.len:
        let lo = (ord(s[i]) shl 8) or ord(s[i + 1])
        if lo in 0xDC00 .. 0xDFFF:
          u = 0x10000 + ((u - 0xD800) shl 10) + (lo - 0xDC00)
          i += 2
      result.add Rune(u).toUTF8
  elif s.len >= 3 and s[0] == '\xEF' and s[1] == '\xBB' and s[2] == '\xBF':
    result = s[3 .. ^1]
  else:
    for c in s: result.add Rune(ord(c)).toUTF8

proc runContent(p: var Painter; data: string; res: PObj)

proc showText(p: var Painter; s: string) =
  let fi = p.gs.font
  if fi == nil: return
  let fs = p.gs.fontSize
  let th = p.gs.hScale / 100
  for code in fi.codesOf(s):
    let w0 = fi.widthOf(code)
    # the glyph's matrix: glyph space -> device
    let trm = mul([fs * th, 0, 0, fs, 0, p.gs.rise], mul(p.tm, p.gs.ctm))
    case p.mode
    of rmText:
      let gm = mul(trm, p.dev)
      let (x, y) = gm.apply(0, 0)
      let x2 = gm.apply(w0, 0)[0]
      let (xa, xb) = (min(x, x2), max(x, x2))
      if p.actualAt > 0:
        # (inside an /ActualText: that text, once, over its glyphs)
        if not p.actualShown:
          p.actualShown = true
          p.text.add (xa, y, xb - xa, fs * p.devMat.scaleOf, p.marked[p.actualAt - 1], true)
        elif p.text.len > 0 and p.text[^1].actual:
          template t: untyped = p.text[^1]
          let e = max(t.x + t.w, xb)
          t.x = min(t.x, xa)
          t.w = e - t.x
      else:
        let t = fi.textOf(code)
        if t.len > 0: p.text.add (xa, y, xb - xa, fs * p.devMat.scaleOf, t, false)
    of rmDraw, rmVectors:
      if p.gs.render != 3 and p.gs.render != 7:
        if fi.kind == fkType3:
          let procObj = p.f.resolve(fi.t3procs.get(fi.names.getOrDefault(code, "")))
          if procObj.kind == pkStream and p.depth < 6:
            let saved = p.gs
            let savedPath = p.path
            p.gs.ctm = mul(fi.matrix, trm)
            p.path.setLen(0)
            inc p.depth
            if p.mode == rmDraw: p.c.save()
            p.runContent(p.f.decodeStream(procObj), if fi.t3res.isDict: fi.t3res else: nullObj)
            if p.mode == rmDraw: p.c.restore()
            dec p.depth
            p.gs = saved
            p.path = savedPath
        else:
          let gp = fi.glyphPath(code)
          if gp.len > 0:
            # (a face standing in for one not embedded: its glyphs as wide as
            # the font's own, so the words fill the line as they should)
            var sx = 1.0
            if fi.kind == fkBuiltin and fi.widths.hasKey(code):
              let a = fi.builtinAdvance(code)
              if a > 0.05 and w0 > 0.05: sx = clamp(w0 / a, 0.75, 1.25)
            let m = mul(mul([sx, 0, 0, 1, 0, 0], fi.matrix), mul(trm, p.dev))
            let saved = p.path
            p.path.setLen(0)
            for o in gp:
              let (x1, y1) = m.apply(o.x1, o.y1)
              let (x2, y2) = m.apply(o.x2, o.y2)
              let (x3, y3) = m.apply(o.x3, o.y3)
              p.path.add (o.op, x1, y1, x2, y2, x3, y3)
            let mode = p.gs.render
            let pend = p.clipPending
            p.clipPending = 0
            p.inGlyph = true
            p.paint(mode in {0, 2, 4, 6}, mode in {1, 2, 5, 6}, false)
            p.inGlyph = false
            p.clipPending = pend
            p.path = saved
    # advance
    var tx = w0 * fs + p.gs.charSpace
    if not fi.composite and code == 32: tx += p.gs.wordSpace
    p.tm = mul([1.0, 0, 0, 1, tx * th, 0], p.tm)

proc drawImage(p: var Painter; b: Bitmap) =
  if b == nil or p.mode != rmDraw: return
  let m = mul([1.0, 0, 0, -1, 0, 1], p.devMat)
  p.c.save()
  p.c.setTransform(m[0], m[1], m[2], m[3], m[4], m[5])
  p.c.globalAlpha = p.gs.fillAlpha
  # (a few pixels shown big -- a chart's cells, pixel art: kept square, as readers do)
  let shown = sqrt(abs(m[0] * m[3] - m[1] * m[2]))
  p.c.imageSmoothingEnabled = shown < 3 * sqrt(float(b.w * b.h))
  p.c.drawImage(b, 0, 0, 1, 1)
  p.c.restore()

proc setFillCs(p: var Painter; cs: ColorSpace) =
  p.gs.fillCs = cs
  p.gs.fillPat = nil
  p.gs.fill = case cs.kind
              of csCMYK: p.f.toRgb(cs, [0.0, 0, 0, 1])
              of csIndexed, csSep: p.f.toRgb(cs, [0.0])
              of csSep.succ .. csPattern: 0xFF000000'u32
              else: 0xFF000000'u32

proc runContent(p: var Painter; data: string; res: PObj) =
  let f = p.f
  var lx = Lexer(s: unsafeAddr data, p: 0)
  var args: seq[PObj]
  while true:
    lx.skipWs()
    if lx.atEnd: break
    let st = lx.p
    let o = lx.parseObj()
    if lx.p == st:
      inc lx.p
      continue
    if o.kind != pkName or not o.s.startsWith("\x01"):
      args.add o
      continue
    inc p.ops
    if p.ops > 3_000_000: return
    let op = o.s[1 .. ^1]
    template n(i: int): float = (if i < args.len: args[i].num else: 0.0)
    template nums(): seq[float] =
      (block:
        var r: seq[float]
        for a in args:
          if a.kind == pkNum: r.add a.n
        r)
    case op
    of "q":
      p.stack.add p.gs
      if p.mode == rmDraw: p.c.save()
    of "Q":
      if p.stack.len > 0:
        p.gs = p.stack.pop()
        if p.mode == rmDraw: p.c.restore()
    of "cm":
      if args.len >= 6: p.gs.ctm = mul([n(0), n(1), n(2), n(3), n(4), n(5)], p.gs.ctm)
    of "w": p.gs.lineWidth = n(0)
    of "J": p.gs.cap = int(n(0))
    of "j": p.gs.join = int(n(0))
    of "M": p.gs.miter = max(1.0, n(0))
    of "d":
      p.gs.dash.setLen(0)
      if args.len >= 1:
        for x in args[0].arr: p.gs.dash.add f.resolve(x).num
      p.gs.dashPhase = n(1)
    of "gs":
      let eg = f.g(f.g(res, "ExtGState"), (if args.len > 0: args[0].name else: ""))
      if eg.isDict:
        let ca = f.g(eg, "ca")
        if ca.kind == pkNum: p.gs.fillAlpha = clamp(ca.n, 0.0, 1.0)
        let ca2 = f.g(eg, "CA")
        if ca2.kind == pkNum: p.gs.strokeAlpha = clamp(ca2.n, 0.0, 1.0)
        let lw = f.g(eg, "LW")
        if lw.kind == pkNum: p.gs.lineWidth = lw.n
        let fnt = f.g(eg, "Font").arr
        if fnt.len >= 2:
          p.gs.font = f.loadFont(f.resolve(fnt[0]))
          p.gs.fontSize = f.resolve(fnt[1]).num
    of "m": p.addPt('m', [n(0), n(1)])
    of "l": p.addPt('l', [n(0), n(1)])
    of "c": p.addPt('c', [n(0), n(1), n(2), n(3), n(4), n(5)])
    of "v":
      # (the first control point at the current point)
      if p.path.len > 0:
        let last = p.path[^1]
        let (cx, cy) = if last.op == 'c': (last.x3, last.y3) else: (last.x1, last.y1)
        let m = p.devMat
        let (x2, y2) = m.apply(n(0), n(1))
        let (x3, y3) = m.apply(n(2), n(3))
        p.path.add ('c', cx, cy, x2, y2, x3, y3)
    of "y": p.addPt('c', [n(0), n(1), n(2), n(3), n(2), n(3)])
    of "h": p.path.add ('h', 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    of "re":
      let (x, y, w, h) = (n(0), n(1), n(2), n(3))
      p.addPt('m', [x, y])
      p.addPt('l', [x + w, y])
      p.addPt('l', [x + w, y + h])
      p.addPt('l', [x, y + h])
      p.path.add ('h', 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    of "f", "F": p.paint(true, false, false)
    of "f*": p.paint(true, false, true)
    of "S": p.paint(false, true, false)
    of "s":
      p.path.add ('h', 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
      p.paint(false, true, false)
    of "B": p.paint(true, true, false)
    of "B*": p.paint(true, true, true)
    of "b":
      p.path.add ('h', 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
      p.paint(true, true, false)
    of "b*":
      p.path.add ('h', 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
      p.paint(true, true, true)
    of "n": p.paint(false, false, false)
    of "W": p.clipPending = 1
    of "W*": p.clipPending = 2
    of "g":
      p.gs.fillCs = gray
      p.gs.fillPat = nil
      p.gs.fill = f.toRgb(gray, [n(0)])
    of "G":
      p.gs.strokeCs = gray
      p.gs.stroke = f.toRgb(gray, [n(0)])
    of "rg":
      p.gs.fillCs = rgbCs
      p.gs.fillPat = nil
      p.gs.fill = f.toRgb(rgbCs, [n(0), n(1), n(2)])
    of "RG":
      p.gs.strokeCs = rgbCs
      p.gs.stroke = f.toRgb(rgbCs, [n(0), n(1), n(2)])
    of "k":
      p.gs.fillCs = cmykCs
      p.gs.fillPat = nil
      p.gs.fill = f.toRgb(cmykCs, [n(0), n(1), n(2), n(3)])
    of "K":
      p.gs.strokeCs = cmykCs
      p.gs.stroke = f.toRgb(cmykCs, [n(0), n(1), n(2), n(3)])
    of "cs":
      if args.len > 0: p.setFillCs(f.parseCs(args[0], res))
    of "CS":
      if args.len > 0:
        p.gs.strokeCs = f.parseCs(args[0], res)
        p.gs.stroke = 0xFF000000'u32
    of "sc", "scn":
      let cs = if p.gs.fillCs == nil: gray else: p.gs.fillCs
      if cs.kind == csPattern:
        let nm = if args.len > 0: args[^1].name else: ""
        p.gs.fillPat = f.g(f.g(res, "Pattern"), nm)
        if not p.gs.fillPat.isDict: p.gs.fillPat = nil
      else:
        p.gs.fillPat = nil
        p.gs.fill = f.toRgb(cs, nums())
    of "SC", "SCN":
      let cs = if p.gs.strokeCs == nil: gray else: p.gs.strokeCs
      if cs.kind != csPattern: p.gs.stroke = f.toRgb(cs, nums())
    of "sh":
      if p.mode == rmDraw and args.len > 0:
        let sh = f.g(f.g(res, "Shading"), args[0].name)
        let g = p.shadingGradient(sh)
        p.c.save()
        if g != nil:
          let m = p.devMat
          p.c.setTransform(m[0], m[1], m[2], m[3], m[4], m[5])
          p.c.fillStyle = g
        else:
          p.c.fillStyle = color(200, 200, 200)
        p.c.globalAlpha = p.gs.fillAlpha
        # (everything there is, inside the clip)
        p.c.resetTransform()
        let gg = g
        if gg != nil:
          let m = p.devMat
          p.c.setTransform(m[0], m[1], m[2], m[3], m[4], m[5])
          # (a big rectangle in the shading's space: its inverse over the page)
          let det = m[0] * m[3] - m[1] * m[2]
          if abs(det) > 1e-12:
            let inv: Mat = [m[3] / det, -m[1] / det, -m[2] / det, m[0] / det,
                            (m[2] * m[5] - m[3] * m[4]) / det, (m[1] * m[4] - m[0] * m[5]) / det]
            var xs, ys: seq[float]
            for (x, y) in [(0.0, 0.0), (p.c.width, 0.0), (0.0, p.c.height), (p.c.width, p.c.height)]:
              let (u, v) = inv.apply(x, y)
              xs.add u
              ys.add v
            p.c.beginPath()
            p.c.moveTo(xs[0], ys[0]); p.c.lineTo(xs[1], ys[1]); p.c.lineTo(xs[3], ys[3]); p.c.lineTo(xs[2], ys[2])
            p.c.closePath()
            p.c.fill()
        p.c.restore()
    of "BDC", "BMC":
      # marked content; one with an /ActualText stands for that text (a
      # right-to-left line in its reading order), read in place of its glyphs
      var at = ""
      if op == "BDC" and args.len >= 2:
        var props = args[^1]
        if props.kind == pkName: props = f.g(f.g(res, "Properties"), props.name)
        at = textString(f.g(props, "ActualText").str)
      p.marked.add at
      if at.len > 0 and p.actualAt == 0:
        p.actualAt = p.marked.len
        p.actualShown = false
    of "EMC":
      if p.marked.len > 0: p.marked.setLen(p.marked.len - 1)
      if p.actualAt > p.marked.len: p.actualAt = 0
    of "BT":
      p.tm = ident
      p.tlm = ident
    of "ET": discard
    of "Tf":
      if args.len >= 2:
        let fd = f.g(f.g(res, "Font"), args[0].name)
        p.gs.font = if fd.isDict: f.loadFont(fd) else: nil
        p.gs.fontSize = args[1].num
    of "Tc": p.gs.charSpace = n(0)
    of "Tw": p.gs.wordSpace = n(0)
    of "Tz": p.gs.hScale = n(0)
    of "TL": p.gs.leading = n(0)
    of "Ts": p.gs.rise = n(0)
    of "Tr": p.gs.render = int(n(0))
    of "Td":
      p.tlm = mul([1.0, 0, 0, 1, n(0), n(1)], p.tlm)
      p.tm = p.tlm
    of "TD":
      p.gs.leading = -n(1)
      p.tlm = mul([1.0, 0, 0, 1, n(0), n(1)], p.tlm)
      p.tm = p.tlm
    of "Tm":
      if args.len >= 6:
        p.tlm = [n(0), n(1), n(2), n(3), n(4), n(5)]
        p.tm = p.tlm
    of "T*":
      p.tlm = mul([1.0, 0, 0, 1, 0, -p.gs.leading], p.tlm)
      p.tm = p.tlm
    of "Tj":
      if args.len > 0: p.showText(args[0].str)
    of "'":
      p.tlm = mul([1.0, 0, 0, 1, 0, -p.gs.leading], p.tlm)
      p.tm = p.tlm
      if args.len > 0: p.showText(args[^1].str)
    of "\"":
      if args.len >= 3:
        p.gs.wordSpace = n(0)
        p.gs.charSpace = n(1)
      p.tlm = mul([1.0, 0, 0, 1, 0, -p.gs.leading], p.tlm)
      p.tm = p.tlm
      if args.len > 0: p.showText(args[^1].str)
    of "TJ":
      if args.len > 0:
        for a in args[0].arr:
          if a.kind == pkNum:
            let th = p.gs.hScale / 100
            p.tm = mul([1.0, 0, 0, 1, -a.n / 1000 * p.gs.fontSize * th, 0], p.tm)
          else: p.showText(a.str)
    of "Do":
      if args.len > 0:
        let xo = f.g(f.g(res, "XObject"), args[0].name)
        if xo.kind == pkStream:
          let st = f.g(xo, "Subtype").name
          if st == "Image":
            if p.mode == rmDraw: p.drawImage(p.decodeImage(xo, res))
          elif st == "Form" and p.depth < 12:
            let saved = p.gs
            let savedStack = p.stack.len
            p.gs.ctm = mul(f.matOf(f.g(xo, "Matrix")), p.gs.ctm)
            if p.mode == rmDraw: p.c.save()
            let bb = f.g(xo, "BBox").arr
            if bb.len == 4 and p.mode == rmDraw:
              let x0 = f.resolve(bb[0]).num
              let y0 = f.resolve(bb[1]).num
              let x1 = f.resolve(bb[2]).num
              let y1 = f.resolve(bb[3]).num
              p.path.setLen(0)
              p.addPt('m', [x0, y0]); p.addPt('l', [x1, y0]); p.addPt('l', [x1, y1]); p.addPt('l', [x0, y1])
              p.path.add ('h', 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
              p.feedPath()
              p.c.clip()
              p.path.setLen(0)
            inc p.depth
            let fres = f.g(xo, "Resources")
            p.runContent(f.decodeStream(xo), if fres.isDict: fres else: res)
            dec p.depth
            if p.mode == rmDraw: p.c.restore()
            p.gs = saved
            p.stack.setLen(min(p.stack.len, savedStack))
    of "BI":
      # an inline picture: its dictionary, then ID and its bytes up to EI
      var d = PObj(kind: pkDict)
      var key = ""
      while not lx.atEnd:
        let q = lx.parseObj()
        if q.kind == pkName and q.s == "\x01ID": break
        if key.len == 0 and q.kind == pkName: key = q.s
        elif key.len > 0:
          d.d[key] = q
          key = ""
      if lx.p < data.len and data[lx.p] in White: inc lx.p
      var e = lx.p
      while true:
        e = data.find("EI", e)
        if e < 0:
          e = data.len
          break
        if (e == 0 or data[e - 1] in White) and (e + 2 >= data.len or data[e + 2] in White): break
        e += 2
      let raw = data[lx.p ..< max(lx.p, e - 1)]
      lx.p = min(data.len, e + 2)
      # (abbreviated filter names and the data decoded)
      var stObj = PObj(kind: pkStream, d: d.d, raw: raw)
      if d.d.hasKey("F"): stObj.d["Filter"] = d.d["F"]
      if d.d.hasKey("DP"): stObj.d["DecodeParms"] = d.d["DP"]
      let decoded = f.decodeStream(stObj)
      if p.mode == rmDraw: p.drawImage(p.decodeImage(stObj, res, decoded, true))
    else: discard
    args.setLen(0)

proc newPainter(f: PdfFile; i: int; dpi: float; mode: RunMode; c: Canvas2D): Painter =
  let pg = f.pages[i]
  let (x0, y0, x1, y1) = f.box(pg)
  let s = dpi / 72
  let dev: Mat = case f.rotation(pg)
                 of 90: [0.0, s, s, 0, -y0 * s, -x0 * s]
                 of 180: [-s, 0, 0, s, x1 * s, -y0 * s]
                 of 270: [0.0, -s, -s, 0, y1 * s, x1 * s]
                 else: [s, 0, 0, -s, -x0 * s, y1 * s]
  result = Painter(f: f, c: c, dev: dev, mode: mode)
  result.gs = GState(ctm: ident, fillCs: gray, strokeCs: gray, fill: 0xFF000000'u32, stroke: 0xFF000000'u32,
                     lineWidth: 1, miter: 10, fillAlpha: 1, strokeAlpha: 1, hScale: 100)

proc contentsOf(f: PdfFile; pg: PObj): string =
  let c = f.g(pg, "Contents")
  if c.kind == pkStream: return f.decodeStream(c)
  for x in c.arr:
    let s = f.resolve(x)
    if s.kind == pkStream:
      result.add f.decodeStream(s)
      result.add '\n'

proc renderPage*(f: PdfFile; i: int; dpi = 96.0; background = 0xFFFFFFFF'u32;
                 maxPixels = 40_000_000; paths = true): Bitmap =
  ## Page `i` drawn at `dpi` pixels an inch (smaller when that would take
  ## more than `maxPixels`), on `background` (0: transparent). Without
  ## `paths`: its text and pictures only (its outlines are made shape
  ## layers, `pageVectors`).
  if i < 0 or i >= f.pages.len: return nil
  let (pw, ph) = f.pageSize(i)
  var d = dpi
  if pw * ph * (d / 72) * (d / 72) > maxPixels.float: d = 72 * sqrt(maxPixels.float / max(1.0, pw * ph))
  let w = max(1, int(ceil(pw * d / 72)))
  let h = max(1, int(ceil(ph * d / 72)))
  let c = newCanvas2D(w, h)
  if (background shr 24) != 0:
    c.fillStyle = colorOf(background, 1)
    c.fillRect(0, 0, w.float, h.float)
  var p = f.newPainter(i, d, rmDraw, c)
  p.skipPaths = not paths
  let res = f.g(f.pages[i], "Resources")
  try: p.runContent(f.contentsOf(f.pages[i]), res)
  except CatchableError: discard              # (what was drawn before the damage stays)
  c.toBitmap()

var arabicForms {.threadvar.}: Table[int, string]

proc letters(s: string): string =
  ## (Arabic presentation forms -- the joined shapes a PDF may map its
  ## glyphs to -- as the letters themselves)
  if arabicForms.len == 0:
    for item in arabicFormsData.split('|'):
      let k = item.find('=')
      if k <= 0: continue
      try:
        var t = ""
        for h in item[k + 1 .. ^1].split(','): t.add Rune(parseHexInt(h)).toUTF8
        arabicForms[parseHexInt(item[0 ..< k])] = t
      except ValueError: discard
  for r in s.runes:
    let t = arabicForms.getOrDefault(int(r), "")
    if t.len > 0: result.add t else: result.add r

proc readingOrder(units: seq[string]): string =
  ## (a line's glyphs as they stand, left to right -- each one's text -- in
  ## reading order: the right-to-left runs turned round by the bidi
  ## algorithm, done again over the line as it stands, brackets mirrored
  ## back; a glyph of several letters, a ligature, kept as it is)
  var s = ""
  var unitOf: seq[int]
  var rtlLetters, ltrLetters = 0
  for k, u in units:
    for ch in u.runes:
      unitOf.add k
      case strongDir($ch)
      of 0: inc ltrLetters
      of 1: inc rtlLetters
      else: discard
    s.add u
  if rtlLetters == 0: return s
  let bi = bidiInfo(s, ord(rtlLetters > ltrLetters))
  if bi.levels.len == 0: return s
  var rs: seq[Rune]
  for r in s.runes: rs.add r
  let order = visualOrderOf(bi.levels)
  var i = 0
  while i < order.len:
    var j = i
    while j < order.len and unitOf[order[j]] == unitOf[order[i]]: inc j
    var idx = order[i ..< j]
    idx.sort()
    for k in idx:
      result.add Rune(if (bi.levels[k] and 1) == 1: mirrored(int(rs[k])) else: int(rs[k]))
    i = j

proc lineText(gs: seq[tuple[x, y, w, size: float; s: string; actual: bool]]): string =
  ## (one line's glyphs, in the order the file has them, as text in reading
  ## order: a space where two that stand side by side leave a gap)
  var at = newSeq[int](gs.len)          # stream -> place left to right
  var byX = newSeq[int](gs.len)
  for k in 0 ..< gs.len: byX[k] = k
  byX.sort(proc (a, b: int): int = cmp(gs[a].x, gs[b].x))
  for k, g in byX: at[g] = k
  proc spaced(a, b: int): bool =
    # (glyphs a and b side by side with room between them, neither a space)
    if abs(at[a] - at[b]) != 1 or gs[a].s == " " or gs[b].s == " ": return false
    let (l, r) = if at[a] < at[b]: (a, b) else: (b, a)
    gs[r].x - (gs[l].x + gs[l].w) > 0.25 * gs[r].size
  proc piece(k: int): string = (if gs[k].actual: gs[k].s else: letters(gs[k].s))
  # right-to-left letters going leftwards in the file: it has them in
  # reading order already (as `retroui/pdf` and most writers do)
  var left, right = 0
  for k in 1 ..< gs.len:
    if strongDir(gs[k].s) == 1 and strongDir(gs[k - 1].s) == 1:
      if gs[k].x < gs[k - 1].x: inc left else: inc right
  if left > right:
    for k in 0 ..< gs.len:
      if k > 0 and spaced(k - 1, k) and not result.endsWith(" "): result.add ' '
      result.add piece(k)
    result = result.strip; return
  var given = true
  for g in gs:
    if not g.actual and g.s.strip.len > 0: given = false
  var units: seq[string]
  for k, g in byX:
    if k > 0 and spaced(byX[k - 1], g): units.add " "
    units.add piece(g)
  if given:
    # (all given as /ActualText: each piece reads as it is; a line mostly
    # right to left goes from its right end)
    var rtl, ltr = 0
    for u in units:
      case strongDir(u)
      of 1: inc rtl
      of 0: inc ltr
      else: discard
    if rtl > ltr: units.reverse()
    var t = ""
    for u in units:
      if u.strip.len == 0: continue
      if t.len > 0: t.add ' '
      t.add u.strip
    result = t; return
  # else as they stand, left to right, the right-to-left runs turned round
  readingOrder(units).strip

proc pageText*(f: PdfFile; i: int): string =
  ## The text of page `i`, in reading order: lines top to bottom, the
  ## words of each as they read -- right to left in Arabic and Hebrew,
  ## whether the file has its glyphs in reading order or as they stand.
  ## Arabic shapes come out as their letters; text a file gives as it reads
  ## (`/ActualText`) is taken as it is.
  if i < 0 or i >= f.pages.len: return ""
  var p = f.newPainter(i, 72, rmText, nil)
  try: p.runContent(f.contentsOf(f.pages[i]), f.g(f.pages[i], "Resources"))
  except CatchableError: discard
  # (glyphs to lines: by their baselines)
  type G = tuple[x, y, w, size: float; s: string; actual: bool]
  var lines: seq[tuple[y: float; gs: seq[G]]]
  for b in p.text:
    var placed = false
    for ln in lines.mitems:
      if abs(ln.y - b.y) < max(1.0, b.size * 0.4):
        ln.gs.add b
        placed = true
        break
    if not placed: lines.add (b.y, @[b])
  lines.sort(proc (a, b: tuple[y: float; gs: seq[G]]): int = cmp(a.y, b.y))
  for ln in lines:
    result.add lineText(ln.gs) & "\n"

proc pageVectors*(f: PdfFile; i: int; dpi = 72.0; glyphs = false): seq[PdfVector] =
  ## The outlines of page `i` -- each filled or stroked path, in pixels at
  ## `dpi` (y down), with its color: what an Illustrator drawing is made of
  ## (pictures left out; the text's outlines too unless `glyphs`).
  if i < 0 or i >= f.pages.len: return
  var p = f.newPainter(i, dpi, rmVectors, nil)
  p.withGlyphs = glyphs
  try: p.runContent(f.contentsOf(f.pages[i]), f.g(f.pages[i], "Resources"))
  except CatchableError: discard
  p.vectors

## Reading PDF files (and Illustrator's .ai, which are PDFs inside) in
## plain Nim: their pages drawn into pictures at any resolution -- paths,
## colors (gray, RGB, CMYK, ICC, separations), gradients, pictures (JPEG,
## Flate, masks), text in the fonts the file carries (TrueType, CFF,
## Type 1, Type 3; others in the kit's own) -- their text read out, and
## their outlines and pictures collected as vectors (to make shape layers
## of an Illustrator drawing).
##
## .. code-block:: nim
##   let f = openPdf(readFile("menu.pdf"))
##   echo f.pageCount, " pages"
##   let pic = f.renderPage(0, dpi = 150)
##
## What it leaves out: transparency groups and soft masks drawn as plain
## (no knock-outs), blend modes as Normal, shadings other than axial and
## radial as their middle color, encrypted files (refused), JBIG2 and
## JPEG 2000 pictures (left out).

import std/[tables, strutils, math, algorithm]
import std/unicode except strip   # (its strip cuts letters: docs/nim-bugs.md)
import gfx, codec, jpeg, ttf, typeset, canvas2d

type
  PdfError* = object of CatchableError
    ## A file that is not a PDF, is damaged beyond reading, has no pages, or
    ## is encrypted.

  PKind = enum pkNull, pkBool, pkNum, pkStr, pkName, pkArr, pkDict, pkRef, pkStream
  PObj = ref object
    case kind: PKind
    of pkNull: discard
    of pkBool: b: bool
    of pkNum: n: float
    of pkStr, pkName: s: string
    of pkArr: a: seq[PObj]
    of pkDict, pkStream:
      d: OrderedTable[string, PObj]
      raw: string            ## (a stream's bytes, still encoded)
      data: string           ## ... decoded (once asked for)
      decoded: bool
    of pkRef: rnum, rgen: int

  PdfFile* = ref object
    ## A PDF file opened: its objects (read when needed) and its pages.
    src: string
    offsets: Table[int, int]               ## object -> where it starts in the file
    inStream: Table[int, (int, int)]       ## object -> (object stream, index)
    cache: Table[int, PObj]
    trailer: PObj
    pages: seq[PObj]
    fonts: Table[int, FontInfo]            ## (by the font dictionary's address)
    loading: int                           ## (nesting: a broken file referring to itself)

  FontKind = enum fkTrueType, fkCff, fkType1, fkType3, fkBuiltin
  FontInfo = ref object
    kind: FontKind
    composite: bool                        ## Type0: codes of 2 bytes (Identity) or a CMap
    ttf: Face
    cff: CffFont
    t1: Type1Font
    t3procs: PObj                          ## Type 3: CharProcs
    t3res: PObj
    matrix: array[6, float]                ## (glyph units -> text space)
    widths: Table[int, float]              ## code (or CID) -> width, 1/1000 em
    dw: float                              ## the default width
    names: Table[int, string]              ## code -> glyph name (/Encoding /Differences)
    uni: Table[int, string]                ## code -> its text (ToUnicode)
    cidToGid: seq[uint16]                  ## (TrueType CID fonts with a map)
    symbolic: bool
    builtin: FaceId
    codeBytes: seq[tuple[lo, hi: int; bytes: int]]   ## (a CMap's code space)

  CffFont = ref object
    data: string
    charStrings: seq[(int, int)]           ## glyph -> (start, end)
    gsubrs, lsubrs: seq[(int, int)]
    fdSubrs: seq[seq[(int, int)]]          ## (CID-keyed) per font dict
    fdSelect: seq[uint8]
    charset: seq[int]                      ## glyph -> SID or CID
    names: Table[string, int]              ## glyph name -> glyph
    cidGlyph: Table[int, int]              ## (CID-keyed) CID -> glyph
    encoding: array[256, int]              ## code -> glyph (its own encoding)
    cid: bool
    strings: seq[string]
    matrix: array[6, float]
    nominalW, defaultW: float

  Type1Font = ref object
    charStrings: Table[string, string]     ## name -> charstring (decrypted)
    subrs: seq[string]
    encoding: Table[int, string]
    matrix: array[6, float]

proc fail(msg: string) {.noreturn.} = raise newException(PdfError, msg)

proc newNum(v: float): PObj = PObj(kind: pkNum, n: v)
template nullObj: PObj = PObj(kind: pkNull)   # (a fresh one: pages are read on several threads)

# ---- reading the syntax ------------------------------------------------------------------------------

const
  White = {'\0', '\t', '\n', '\f', '\r', ' '}
  Delim = {'(', ')', '<', '>', '[', ']', '{', '}', '/', '%'}

type Lexer = object
  s: ptr string
  p: int

proc skipWs(lx: var Lexer) =
  let s = lx.s
  while lx.p < s[].len:
    let c = s[][lx.p]
    if c in White: inc lx.p
    elif c == '%':
      while lx.p < s[].len and s[][lx.p] notin {'\r', '\n'}: inc lx.p
    else: break

proc atEnd(lx: Lexer): bool = lx.p >= lx.s[].len

proc readNumberOrWord(lx: var Lexer): string =
  let s = lx.s
  let st = lx.p
  while lx.p < s[].len and s[][lx.p] notin White and s[][lx.p] notin Delim: inc lx.p
  s[][st ..< lx.p]

proc hexv(c: char): int =
  case c
  of '0' .. '9': ord(c) - ord('0')
  of 'a' .. 'f': ord(c) - ord('a') + 10
  of 'A' .. 'F': ord(c) - ord('A') + 10
  else: -1

proc readLiteral(lx: var Lexer): string =
  ## (after the "(")
  let s = lx.s
  var depth = 1
  while lx.p < s[].len:
    let c = s[][lx.p]
    inc lx.p
    case c
    of '(':
      inc depth
      result.add c
    of ')':
      dec depth
      if depth == 0: return
      result.add c
    of '\\':
      if lx.p >= s[].len: return
      let e = s[][lx.p]
      inc lx.p
      case e
      of 'n': result.add '\n'
      of 'r': result.add '\r'
      of 't': result.add '\t'
      of 'b': result.add '\b'
      of 'f': result.add '\f'
      of '\r':
        if lx.p < s[].len and s[][lx.p] == '\n': inc lx.p
      of '\n': discard
      of '0' .. '7':
        var v = ord(e) - ord('0')
        for _ in 0 .. 1:
          if lx.p < s[].len and s[][lx.p] in {'0' .. '7'}:
            v = v * 8 + ord(s[][lx.p]) - ord('0')
            inc lx.p
        result.add char(v and 255)
      else: result.add e
    else: result.add c

proc readHex(lx: var Lexer): string =
  ## (after the "<")
  let s = lx.s
  var hi = -1
  while lx.p < s[].len:
    let c = s[][lx.p]
    inc lx.p
    if c == '>': break
    let v = hexv(c)
    if v < 0: continue
    if hi < 0: hi = v
    else:
      result.add char(hi * 16 + v)
      hi = -1
  if hi >= 0: result.add char(hi * 16)

proc readName(lx: var Lexer): string =
  ## (after the "/")
  let w = lx.readNumberOrWord()
  var i = 0
  while i < w.len:
    if w[i] == '#' and i + 2 < w.len and hexv(w[i + 1]) >= 0 and hexv(w[i + 2]) >= 0:
      result.add char(hexv(w[i + 1]) * 16 + hexv(w[i + 2]))
      i += 3
    else:
      result.add w[i]
      inc i

proc parseObj(lx: var Lexer; depth = 0): PObj

proc parseAfterNumber(lx: var Lexer; first: string): PObj =
  ## "12" could start "12 0 R".
  let v = try: parseFloat(first) except ValueError: 0.0
  if '.' notin first and first.len > 0 and first[0] in {'0' .. '9'}:
    let save = lx.p
    lx.skipWs()
    if not lx.atEnd and lx.s[][lx.p] in {'0' .. '9'}:
      let g = lx.readNumberOrWord()
      lx.skipWs()
      if not lx.atEnd and lx.s[][lx.p] == 'R' and
         (lx.p + 1 >= lx.s[].len or lx.s[][lx.p + 1] in White + Delim):
        inc lx.p
        return PObj(kind: pkRef, rnum: int(v), rgen: (try: parseInt(g) except ValueError: 0))
    lx.p = save
  newNum(v)

proc parseObj(lx: var Lexer; depth = 0): PObj =
  if depth > 64: fail("nested too deep")
  lx.skipWs()
  if lx.atEnd: return nullObj
  let s = lx.s
  let c = s[][lx.p]
  case c
  of '/':
    inc lx.p
    PObj(kind: pkName, s: lx.readName())
  of '(':
    inc lx.p
    PObj(kind: pkStr, s: lx.readLiteral())
  of '<':
    if lx.p + 1 < s[].len and s[][lx.p + 1] == '<':
      lx.p += 2
      var d = PObj(kind: pkDict)
      while true:
        lx.skipWs()
        if lx.atEnd: break
        if s[][lx.p] == '>':
          lx.p += 2
          break
        if s[][lx.p] != '/':
          discard lx.parseObj(depth + 1)          # (junk: skipped)
          continue
        inc lx.p
        let k = lx.readName()
        d.d[k] = lx.parseObj(depth + 1)
      d
    else:
      inc lx.p
      PObj(kind: pkStr, s: lx.readHex())
  of '[':
    inc lx.p
    var a = PObj(kind: pkArr)
    while true:
      lx.skipWs()
      if lx.atEnd: break
      if s[][lx.p] == ']':
        inc lx.p
        break
      let st = lx.p
      a.a.add lx.parseObj(depth + 1)
      if lx.p == st: inc lx.p                    # (no progress: skip a byte)
    a
  of ']', '>', ')', '}', '{':
    inc lx.p
    nullObj
  else:
    let w = lx.readNumberOrWord()
    if w.len == 0:
      inc lx.p
      return nullObj
    case w
    of "true": PObj(kind: pkBool, b: true)
    of "false": PObj(kind: pkBool, b: false)
    of "null": nullObj
    else:
      if w[0] in {'0' .. '9', '-', '+', '.'}: lx.parseAfterNumber(w)
      else: PObj(kind: pkName, s: "\x01" & w)      # (an operator: marked)

# ---- objects ---------------------------------------------------------------------------------------------

proc resolve(f: PdfFile; o: PObj): PObj

proc get(o: PObj; key: string): PObj =
  if o != nil and o.kind in {pkDict, pkStream}: o.d.getOrDefault(key, nullObj) else: nullObj

proc num(o: PObj; d = 0.0): float =
  if o != nil and o.kind == pkNum: o.n else: d

proc int0(o: PObj; d = 0): int =
  if o != nil and o.kind == pkNum and o.n.classify in {fcNormal, fcZero, fcNegZero}:
    int(clamp(o.n, -2e9, 2e9))
  else: d

proc name(o: PObj): string =
  if o != nil and o.kind == pkName: o.s else: ""

proc str(o: PObj): string =
  if o != nil and o.kind in {pkStr, pkName}: o.s else: ""

proc arr(o: PObj): seq[PObj] =
  if o != nil and o.kind == pkArr: o.a else: @[]

proc isDict(o: PObj): bool = o != nil and o.kind in {pkDict, pkStream}

proc g(f: PdfFile; o: PObj; key: string): PObj = f.resolve(o.get(key))

proc readObjectAt(f: PdfFile; at: int): PObj =
  ## The object "N G obj ... endobj" at `at` (a stream's bytes kept).
  var lx = Lexer(s: addr f.src, p: at)
  discard lx.readNumberOrWord(); lx.skipWs()
  discard lx.readNumberOrWord(); lx.skipWs()
  let kw = lx.readNumberOrWord()
  if kw != "obj": return nullObj
  result = lx.parseObj()
  lx.skipWs()
  if result.isDict and lx.p + 6 <= f.src.len and f.src[lx.p ..< lx.p + 6] == "stream":
    lx.p += 6
    if lx.p < f.src.len and f.src[lx.p] == '\r': inc lx.p
    if lx.p < f.src.len and f.src[lx.p] == '\n': inc lx.p
    var len = -1
    let lo = result.d.getOrDefault("Length", nullObj)
    if lo.kind == pkNum: len = lo.int0
    elif lo.kind == pkRef and f.loading < 8:
      inc f.loading
      len = f.resolve(lo).int0(-1)
      dec f.loading
    var e = -1
    if len >= 0 and lx.p + len <= f.src.len:
      let after = f.src[lx.p + len ..< min(f.src.len, lx.p + len + 12)].strip(trailing = false)
      if after.startsWith("endstream"): e = lx.p + len
    if e < 0:
      # (a wrong length: up to the "endstream")
      e = f.src.find("endstream", lx.p)
      if e < 0: e = f.src.len
      var k = e
      if k > lx.p and f.src[k - 1] == '\n': dec k
      if k > lx.p and f.src[k - 1] == '\r': dec k
      e = k
    let st = PObj(kind: pkStream, d: result.d, raw: f.src[lx.p ..< e])
    result = st

proc decodeStream(f: PdfFile; o: PObj): string

proc loadObjStm(f: PdfFile; num: int): PObj =
  ## (an object kept in an object stream)
  let (sn, idx) = f.inStream[num]
  let st = f.resolve(PObj(kind: pkRef, rnum: sn))
  if st.kind != pkStream: return nullObj
  let data = f.decodeStream(st)
  let n = st.get("N").int0
  let first = st.get("First").int0
  var lx = Lexer(s: addr data, p: 0)
  var pairs: seq[(int, int)]
  for _ in 0 ..< n:
    let a = lx.parseObj()
    let b = lx.parseObj()
    pairs.add (a.int0, b.int0)
  for k, (onum, off) in pairs:
    if (f.cache.hasKey(onum) and onum != num) or (onum != num and f.inStream.getOrDefault(onum, (-1, -1))[0] != sn):
      continue
    var lx2 = Lexer(s: addr data, p: first + off)
    let o = lx2.parseObj()
    f.cache[onum] = o
  f.cache.getOrDefault(num, nullObj)

proc resolve(f: PdfFile; o: PObj): PObj =
  if o == nil: return nullObj
  if o.kind != pkRef: return o
  if f.cache.hasKey(o.rnum): return f.cache[o.rnum]
  if f.loading > 32: return nullObj
  inc f.loading
  try:
    f.cache[o.rnum] = nullObj                     # (a loop: null)
    var r = nullObj
    if f.offsets.hasKey(o.rnum): r = f.readObjectAt(f.offsets[o.rnum])
    elif f.inStream.hasKey(o.rnum): r = f.loadObjStm(o.rnum)
    f.cache[o.rnum] = r
    result = r
  finally: dec f.loading

# ---- filters -----------------------------------------------------------------------------------------------

proc unpredict(data: string; pred, colors, bpc, cols: int): string =
  ## PNG predictors (10..15) and TIFF predictor 2.
  if pred < 2: return data
  let bpp = max(1, (colors * bpc + 7) div 8)
  let row = (colors * bpc * cols + 7) div 8
  if pred == 2:
    if bpc != 8: return data
    result = data
    var i = 0
    while i + row <= result.len:
      for x in bpp ..< row: result[i + x] = char((ord(result[i + x]) + ord(result[i + x - bpp])) and 255)
      i += row
    return
  var prev = newString(row)
  var i = 0
  while i < data.len:
    let ft = ord(data[i])
    inc i
    var cur = newString(row)
    for x in 0 ..< row:
      let raw = if i + x < data.len: ord(data[i + x]) else: 0
      let a = if x >= bpp: ord(cur[x - bpp]) else: 0
      let b = ord(prev[x])
      let c = if x >= bpp: ord(prev[x - bpp]) else: 0
      let v = case ft
              of 1: raw + a
              of 2: raw + b
              of 3: raw + (a + b) div 2
              of 4:
                let p = a + b - c
                let pa = abs(p - a)
                let pb = abs(p - b)
                let pc = abs(p - c)
                raw + (if pa <= pb and pa <= pc: a elif pb <= pc: b else: c)
              else: raw
      cur[x] = char(v and 255)
    result.add cur
    prev = cur
    i += row

proc ascii85(s: string): string =
  var acc = 0'u32
  var n = 0
  for c in s:
    if c == '~': break
    if c in White: continue
    if c == 'z' and n == 0:
      result.add "\0\0\0\0"
      continue
    if c < '!' or c > 'u': continue
    acc = acc * 85 + uint32(ord(c) - 33)
    inc n
    if n == 5:
      for k in countdown(3, 0): result.add char((acc shr (8 * k)) and 255)
      acc = 0
      n = 0
  if n > 0:
    for _ in n ..< 5: acc = acc * 85 + 84
    for k in 0 ..< n - 1: result.add char((acc shr (8 * (3 - k))) and 255)

proc lzw(s: string; early = 1): string =
  var dict: seq[string]
  proc reset(d: var seq[string]) =
    d.setLen(0)
    for i in 0 .. 255: d.add $char(i)
    d.add ""; d.add ""
  dict.reset()
  var bits = 9
  var buf = 0
  var nb = 0
  var prev = ""
  for c in s:
    buf = (buf shl 8) or ord(c)
    nb += 8
    while nb >= bits:
      let code = (buf shr (nb - bits)) and ((1 shl bits) - 1)
      nb -= bits
      if code == 256:
        dict.reset()
        bits = 9
        prev = ""
        continue
      if code == 257: return
      var entry: string
      if code < dict.len: entry = dict[code]
      elif prev.len > 0: entry = prev & prev[0]
      else: return
      result.add entry
      if prev.len > 0: dict.add prev & entry[0]
      prev = entry
      if dict.len + early >= (1 shl bits) and bits < 12: inc bits

proc runLength(s: string): string =
  var i = 0
  while i < s.len:
    let n = ord(s[i])
    inc i
    if n == 128: break
    if n < 128:
      result.add s[i ..< min(s.len, i + n + 1)]
      i += n + 1
    elif i < s.len:
      for _ in 0 ..< 257 - n: result.add s[i]
      inc i

proc filtersOf(f: PdfFile; o: PObj): seq[(string, PObj)] =
  let fl = f.resolve(o.get("Filter"))
  let pr = f.resolve(o.get("DecodeParms"))
  if fl.kind == pkName: result.add (fl.s, pr)
  elif fl.kind == pkArr:
    for i, x in fl.a:
      let p = if pr.kind == pkArr and i < pr.a.len: f.resolve(pr.a[i]) else: nullObj
      result.add (f.resolve(x).name, p)

proc decodeStream(f: PdfFile; o: PObj): string =
  ## A stream's bytes decoded (all but picture codecs: DCT, JPX, JBIG2,
  ## which are left for the picture code).
  if o.kind != pkStream: return ""
  if o.decoded: return o.data
  var d = o.raw
  for (name, parms) in f.filtersOf(o):
    case name
    of "FlateDecode", "Fl":
      try:
        let b = zlibDecompress(toBytes(d), 256 shl 20)
        d = newString(b.len)
        if b.len > 0: copyMem(addr d[0], unsafeAddr b[0], b.len)
      except CatchableError:
        # (a damaged stream: what inflates of it, raw deflate past the header)
        try:
          let b = inflate(toBytes(d), 2, nil, 256 shl 20)
          d = newString(b.len)
          if b.len > 0: copyMem(addr d[0], unsafeAddr b[0], b.len)
        except CatchableError: d = ""
      if parms.isDict:
        d = unpredict(d, parms.get("Predictor").int0(1), parms.get("Colors").int0(1),
                      parms.get("BitsPerComponent").int0(8), parms.get("Columns").int0(1))
    of "LZWDecode", "LZW":
      d = lzw(d, if parms.isDict: parms.get("EarlyChange").int0(1) else: 1)
      if parms.isDict:
        d = unpredict(d, parms.get("Predictor").int0(1), parms.get("Colors").int0(1),
                      parms.get("BitsPerComponent").int0(8), parms.get("Columns").int0(1))
    of "ASCIIHexDecode", "AHx":
      var lx = Lexer(s: addr d, p: 0)
      d = lx.readHex()
    of "ASCII85Decode", "A85": d = ascii85(d)
    of "RunLengthDecode", "RL": d = runLength(d)
    else: break                                   # (DCT and the others: for pictures)
  o.data = d
  o.decoded = true
  o.raw = ""
  d

proc pictureFilter(f: PdfFile; o: PObj): string =
  ## (the codec a picture is left in after `decodeStream`: "DCTDecode"...)
  for (name, _) in f.filtersOf(o):
    if name in ["DCTDecode", "DCT", "JPXDecode", "JBIG2Decode", "CCITTFaxDecode", "CCF"]: return name

# ---- the file: where its objects are, its pages ---------------------------------------------------------

proc scanObjects(f: PdfFile) =
  ## Every "N G obj" in the file (what a damaged cross-reference table
  ## would have said); the last one of a number wins, as updates go.
  var i = 0
  let s = f.src
  while true:
    i = s.find(" obj", i)
    if i < 0: break
    # back over "N G"
    var j = i - 1
    while j >= 0 and s[j] in {'0' .. '9'}: dec j
    let genEnd = j + 1
    if genEnd < i and j >= 0 and s[j] in White:
      var k = j
      while k >= 0 and s[k] in White: dec k
      let numEnd = k + 1
      while k >= 0 and s[k] in {'0' .. '9'}: dec k
      if k + 1 < numEnd and (k < 0 or s[k] in White + Delim):
        let num = try: parseInt(s[k + 1 ..< numEnd]) except ValueError: -1
        if num >= 0: f.offsets[num] = k + 1
    i += 4

proc readXrefStream(f: PdfFile; o: PObj) =
  let w = o.get("W").arr
  if w.len < 3: return
  let ws = [w[0].int0, w[1].int0, w[2].int0]
  let data = f.decodeStream(o)
  var index = o.get("Index").arr
  var ranges: seq[(int, int)]
  if index.len >= 2:
    var k = 0
    while k + 1 < index.len:
      ranges.add (index[k].int0, index[k + 1].int0)
      k += 2
  else: ranges.add (0, o.get("Size").int0)
  let rec = ws[0] + ws[1] + ws[2]
  if rec <= 0: return
  var p = 0
  proc field(at, n: int; d: int): int =
    if n == 0: return d
    for k in 0 ..< n: result = (result shl 8) or ord(data[at + k])
  for (first, count) in ranges:
    for k in 0 ..< count:
      if p + rec > data.len: return
      let t = field(p, ws[0], 1)
      let a = field(p + ws[0], ws[1], 0)
      let b = field(p + ws[0] + ws[1], ws[2], 0)
      let num = first + k
      if not f.offsets.hasKey(num) and not f.inStream.hasKey(num):
        if t == 1: f.offsets[num] = a
        elif t == 2: f.inStream[num] = (a, b)
      p += rec

proc readXref(f: PdfFile): bool =
  ## The cross-reference tables and streams, newest first; false when
  ## they cannot be read (then the objects are found by scanning).
  let sx = f.src.rfind("startxref")
  if sx < 0: return false
  var lx = Lexer(s: addr f.src, p: sx + 9)
  var at = lx.parseObj().int0(-1)
  var seen = 0
  while at >= 0 and at < f.src.len and seen < 64:
    inc seen
    lx = Lexer(s: addr f.src, p: at)
    lx.skipWs()
    var trailer: PObj
    if f.src.continuesWith("xref", lx.p):
      lx.p += 4
      while true:
        lx.skipWs()
        if lx.atEnd or f.src.continuesWith("trailer", lx.p): break
        let first = lx.parseObj().int0(-1)
        let count = lx.parseObj().int0(-1)
        if first < 0 or count < 0: return false
        lx.skipWs()
        for k in 0 ..< count:
          if lx.p + 18 > f.src.len: return false
          let off = try: parseInt(f.src[lx.p ..< lx.p + 10]) except ValueError: 0
          let kind = f.src[lx.p + 17]
          if kind == 'n' and not f.offsets.hasKey(first + k) and not f.inStream.hasKey(first + k):
            f.offsets[first + k] = off
          lx.p += 20
          if lx.p <= f.src.len and lx.p > 0 and f.src[lx.p - 1] notin {'\n', '\r'}:
            # (rows of 19 bytes in some files)
            while lx.p < f.src.len and f.src[lx.p] in White: inc lx.p
      lx.p += 7
      trailer = lx.parseObj()
      if trailer.isDict:
        let xs = trailer.get("XRefStm")
        if xs.kind == pkNum:
          let so = f.readObjectAt(xs.int0)
          if so.kind == pkStream: f.readXrefStream(so)
    else:
      let o = f.readObjectAt(at)
      if o.kind != pkStream or o.get("Type").name != "XRef": return false
      f.readXrefStream(o)
      trailer = o
    if f.trailer == nil: f.trailer = trailer
    at = trailer.get("Prev").int0(-1)
  f.trailer != nil

proc collectPages(f: PdfFile; node: PObj; inherit: OrderedTable[string, PObj]; depth: int) =
  if depth > 64 or not node.isDict or f.pages.len > 100_000: return
  var inh = inherit
  for k in ["Resources", "MediaBox", "CropBox", "Rotate"]:
    if node.d.hasKey(k): inh[k] = node.d[k]
  let t = node.get("Type").name
  if t == "Page" or (t != "Pages" and not node.d.hasKey("Kids")):
    let pg = PObj(kind: pkDict, d: node.d)
    for k, v in inh:
      if not pg.d.hasKey(k): pg.d[k] = v
    f.pages.add pg
    return
  for kid in f.g(node, "Kids").arr: f.collectPages(f.resolve(kid), inh, depth + 1)

proc openPdf*(data: string): PdfFile =
  ## A PDF (or a PDF-compatible .ai) from its bytes. Raises `PdfError` when
  ## it is not one, or is encrypted.
  if data.len < 16: fail("not a PDF file")
  let head = data.find("%PDF-")
  if head < 0 or head > 1024: fail("not a PDF file")
  result = PdfFile(src: data)
  let ok = result.readXref()
  if not ok or result.offsets.len == 0 and result.inStream.len == 0:
    result.offsets.clear()
    result.inStream.clear()
    result.scanObjects()
    # (the trailer: the last one there, else the catalog found by its type)
    let t = data.rfind("trailer")
    if t >= 0:
      var lx = Lexer(s: addr result.src, p: t + 7)
      result.trailer = lx.parseObj()
    if result.trailer == nil or not result.trailer.isDict or result.trailer.get("Root").kind != pkRef:
      result.trailer = PObj(kind: pkDict)
      for num, _ in result.offsets:
        let o = result.resolve(PObj(kind: pkRef, rnum: num))
        if o.isDict and o.get("Type").name == "Catalog":
          result.trailer.d["Root"] = PObj(kind: pkRef, rnum: num)
          break
      # (object streams: their objects too)
      for num, _ in result.offsets:
        let o = result.resolve(PObj(kind: pkRef, rnum: num))
        if o.kind == pkStream and o.get("Type").name == "ObjStm":
          let dd = result.decodeStream(o)
          var lx = Lexer(s: addr dd, p: 0)
          for k in 0 ..< o.get("N").int0:
            let a = lx.parseObj().int0(-1)
            discard lx.parseObj()
            if a >= 0 and not result.offsets.hasKey(a): result.inStream[a] = (num, k)
  if result.trailer.get("Encrypt").kind != pkNull: fail("the PDF is encrypted")
  let root = result.g(result.trailer, "Root")
  if not root.isDict: fail("the PDF has no pages")
  result.collectPages(result.g(root, "Pages"), initOrderedTable[string, PObj](), 0)
  if result.pages.len == 0: fail("the PDF has no pages")

proc pageCount*(f: PdfFile): int = f.pages.len
  ## How many pages the file has.

proc box(f: PdfFile; pg: PObj): (float, float, float, float) =
  var b = f.g(pg, "CropBox").arr
  if b.len < 4: b = f.g(pg, "MediaBox").arr
  if b.len < 4: return (0.0, 0.0, 612.0, 792.0)
  let v = [f.resolve(b[0]).num, f.resolve(b[1]).num, f.resolve(b[2]).num, f.resolve(b[3]).num]
  (min(v[0], v[2]), min(v[1], v[3]), max(v[0], v[2]), max(v[1], v[3]))

proc rotation(f: PdfFile; pg: PObj): int = ((f.g(pg, "Rotate").int0 mod 360) + 360) mod 360

proc pageSize*(f: PdfFile; i: int): tuple[w, h: float] =
  ## Page `i`'s size in points (1/72 inch), as it is shown (turned).
  if i < 0 or i >= f.pages.len: return (0.0, 0.0)
  let (x0, y0, x1, y1) = f.box(f.pages[i])
  if f.rotation(f.pages[i]) in [90, 270]: (y1 - y0, x1 - x0) else: (x1 - x0, y1 - y0)

proc info*(f: PdfFile): tuple[title, author, creator: string] =
  ## The file's title, author and the program that made it.
  let inf = f.g(f.trailer, "Info")
  proc text(o: PObj): string =
    let s = f.resolve(o).str
    if s.len >= 2 and s[0] == '\xFE' and s[1] == '\xFF':
      var i = 2
      while i + 1 < s.len:
        let u = (ord(s[i]) shl 8) or ord(s[i + 1])
        result.add Rune(u).toUTF8
        i += 2
    else: result = s
  (text(inf.get("Title")), text(inf.get("Author")), text(inf.get("Creator")))

include pdfreadfonts
include pdfreadpaint

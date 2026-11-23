## The fonts of a PDF (`pdfreadfonts`, included by `pdfread`, not imported
## on its own): their encodings, widths and text (ToUnicode), and their
## glyphs' outlines -- TrueType (by the kit's reader), CFF (Type 2
## charstrings), Type 1 (decrypted, Type 1 charstrings), Type 3 (content
## streams); the kit's own fonts (FreeSans, FreeSerif, FreeMono) for the
## rest, at the widths the PDF gives. It has no procs of its own to call:
## `renderPage` and `pageText` draw and read text with it.
##
## ```nim
## let f = openPdf(readFile("letter.pdf"))
## echo f.pageText(0)        # the text, through its fonts' ToUnicode maps
## ```

import pdfencodings

type
  GOp = tuple[op: char; x1, y1, x2, y2, x3, y3: float]
    ## a glyph's outline: 'm' move, 'l' line, 'c' curve, 'h' close
  GPath = seq[GOp]

var agl {.threadvar.}: Table[string, int]   # (pages are drawn on several threads)
var tlFaces {.threadvar.}: array[FaceId, Face]
var afm {.threadvar.}: Table[string, Table[string, int]]

proc builtinFace(id: FaceId): Face =
  ## The toolkit's face `id`, this thread's own.
  if tlFaces[id] == nil: tlFaces[id] = typeset.threadFace(id)
  tlFaces[id]

proc afmWidths(base: string): Table[string, int] =
  ## The widths of the standard font `base` stands for (Times, Helvetica /
  ## Arial, Symbol, ZapfDingbats; 1/1000 em by glyph name); empty: none.
  let b = base.toLowerAscii
  let bold = "bold" in b or "black" in b or "heavy" in b or "semibold" in b
  let italic = "italic" in b or "oblique" in b
  let name =
    if "symbol" in b: "Symbol"
    elif "zapf" in b or "dingbat" in b: "ZapfDingbats"
    elif "times" in b or "georgia" in b or "garamond" in b or "serif" in b and "sans" notin b:
      (if bold and italic: "Times-BoldItalic" elif bold: "Times-Bold"
       elif italic: "Times-Italic" else: "Times-Roman")
    elif "helvetica" in b or "arial" in b or "sans" in b or "verdana" in b or "tahoma" in b or
         "calibri" in b or b.len > 0:
      (if bold: "Helvetica-Bold" else: "Helvetica")
    else: ""
  if name.len == 0: return
  if afm.len == 0:
    for part in afmWidthsData.split('|'):
      let c = part.find(':')
      if c <= 0: continue
      var t: Table[string, int]
      for item in part[c + 1 .. ^1].split(','):
        let e = item.find('=')
        if e > 0:
          try: t[item[0 ..< e]] = parseInt(item[e + 1 .. ^1]) except ValueError: discard
      afm[part[0 ..< c]] = t
  afm.getOrDefault(name)

proc unicodeOfName(n: string): int =
  ## The character a glyph's name stands for (the Adobe Glyph List,
  ## "uniXXXX", "uXXXX"; -1 not known).
  if agl.len == 0:
    for item in glyphListData.split('|'):
      let k = item.find('=')
      if k > 0:
        try: agl[item[0 ..< k]] = parseHexInt(item[k + 1 .. ^1]) except ValueError: discard
  var base = n
  let dot = base.find('.')
  if dot > 0: base = base[0 ..< dot]
  if agl.hasKey(base): return agl[base]
  if base.len == 7 and base.startsWith("uni"):
    try: return parseHexInt(base[3 .. 6]) except ValueError: discard
  if base.len in 5 .. 7 and base[0] == 'u':
    try: return parseHexInt(base[1 .. ^1]) except ValueError: discard
  -1

# ---- CMaps (ToUnicode, and the codes of composite fonts) ------------------------------------------------

proc utf16Text(s: string): string =
  result = ""         # (a value at once: see tools/writecheck.py)
  var i = 0
  while i + 1 < s.len:
    var u = (ord(s[i]) shl 8) or ord(s[i + 1])
    i += 2
    if u >= 0xD800 and u < 0xDC00 and i + 1 < s.len:
      let lo = (ord(s[i]) shl 8) or ord(s[i + 1])
      u = 0x10000 + ((u - 0xD800) shl 10) + (lo - 0xDC00)
      i += 2
    result.add Rune(u).toUTF8
  if s.len == 1: result = $s[0]

proc bytesNum(s: string): int =
  for c in s: result = (result shl 8) or ord(c)

proc parseCMap(data: string; uni: var Table[int, string]; space: var seq[tuple[lo, hi: int; bytes: int]];
               cids: var Table[int, int]; cidRanges: var seq[(int, int, int)]) =
  ## bfchar, bfrange (text), cidchar, cidrange (CIDs), codespacerange.
  var lx = Lexer(s: unsafeAddr data, p: 0)
  var stack: seq[PObj]
  var mode = ""
  while not lx.atEnd:
    let st = lx.p
    let o = lx.parseObj()
    if lx.p == st: inc lx.p
    if o.kind == pkName and o.s.startsWith("\x01"):
      let op = o.s[1 .. ^1]
      case op
      of "begincodespacerange", "beginbfchar", "beginbfrange", "begincidchar", "begincidrange":
        mode = op
        stack.setLen(0)
      of "endcodespacerange":
        var k = 0
        while k + 1 < stack.len:
          space.add (bytesNum(stack[k].str), bytesNum(stack[k + 1].str), max(1, stack[k].str.len))
          k += 2
        stack.setLen(0)
      of "endbfchar":
        var k = 0
        while k + 1 < stack.len:
          let dst = stack[k + 1]
          uni[bytesNum(stack[k].str)] = if dst.kind == pkName: (let u = unicodeOfName(dst.s); if u >= 0: Rune(u).toUTF8 else: "")
                                        else: utf16Text(dst.str)
          k += 2
        stack.setLen(0)
      of "endbfrange":
        var k = 0
        while k + 2 < stack.len:
          let lo = bytesNum(stack[k].str)
          let hi = bytesNum(stack[k + 1].str)
          let dst = stack[k + 2]
          if hi - lo <= 65535 and hi >= lo:
            if dst.kind == pkArr:
              for j, dd in dst.a:
                if lo + j > hi: break
                uni[lo + j] = utf16Text(dd.str)
            else:
              let base = dst.str
              for c in lo .. hi:
                var s = base
                if s.len > 0:
                  var v = ord(s[^1]) + (c - lo)
                  var at = s.high
                  s[at] = char(v and 255)
                  while v > 255 and at > 0:
                    dec at
                    v = ord(s[at]) + (v shr 8)
                    s[at] = char(v and 255)
                uni[c] = utf16Text(s)
          k += 3
        stack.setLen(0)
      of "endcidchar":
        var k = 0
        while k + 1 < stack.len:
          cids[bytesNum(stack[k].str)] = stack[k + 1].int0
          k += 2
        stack.setLen(0)
      of "endcidrange":
        var k = 0
        while k + 2 < stack.len:
          cidRanges.add (bytesNum(stack[k].str), bytesNum(stack[k + 1].str), stack[k + 2].int0)
          k += 3
        stack.setLen(0)
      else: stack.setLen(0)
    else: stack.add o

# ---- CFF -----------------------------------------------------------------------------------------------------

proc u8(s: string; i: int): int {.inline.} = (if i >= 0 and i < s.len: ord(s[i]) else: 0)
proc u16(s: string; i: int): int {.inline.} = (u8(s, i) shl 8) or u8(s, i + 1)

# ---- Type 1 ------------------------------------------------------------------------------------------------

proc decrypt(s: string; r0: uint16; skip: int): string =
  var r = r0
  result = newStringOfCap(s.len)
  for i, c in s:
    let ci = uint16(ord(c))
    let p = ci xor (r shr 8)
    # (in 32 bits without a sign, then its low 16: as `retroui/fontconv` does it -- C makes two
    # 16-bit numbers signed ints to multiply them, and that product can overflow one)
    r = uint16(((uint32(ci) + uint32(r)) * 52845'u32 + 22719'u32) and 0xFFFF'u32)
    if i >= skip: result.add char(p and 255)

proc parseType1(data: string; len1: int): Type1Font =
  ## A Type 1 font program (as a PDF's FontFile stream: cleartext, then
  ## the eexec part).
  var d = data
  if d.len > 6 and d[0] == '\x80':
    # (PFB: segments)
    var o = ""
    var p = 0
    while p + 6 <= d.len and d[p] == '\x80' and d[p + 1] in {'\x01', '\x02'}:
      let n = ord(d[p + 2]) or (ord(d[p + 3]) shl 8) or (ord(d[p + 4]) shl 16) or (ord(d[p + 5]) shl 24)
      o.add d[p + 6 ..< min(d.len, p + 6 + n)]
      p += 6 + n
    d = o
  let t = Type1Font(matrix: [0.001, 0, 0, 0.001, 0, 0])
  var clearEnd = d.find("eexec")
  if clearEnd < 0: clearEnd = min(d.len, if len1 > 0: len1 else: d.len)
  let clear = d[0 ..< clearEnd]
  # the encoding (dup code /name put) and the matrix
  if "StandardEncoding" in clear:
    for code in 0 .. 255:
      if standardEncoding[code].len > 0: t.encoding[code] = standardEncoding[code]
  var p = 0
  while true:
    p = clear.find("dup ", p)
    if p < 0: break
    var lx = Lexer(s: unsafeAddr clear, p: p + 4)
    let code = lx.parseObj()
    let nm = lx.parseObj()
    if code.kind == pkNum and nm.kind == pkName and not nm.s.startsWith("\x01"):
      t.encoding[code.int0] = nm.s
    p += 4
  let fm = clear.find("/FontMatrix")
  if fm >= 0:
    var lx = Lexer(s: unsafeAddr clear, p: fm + 11)
    let a = lx.parseObj().arr
    if a.len == 6:
      for k in 0 .. 5: t.matrix[k] = a[k].num
  # the private part, decrypted (binary or hex)
  var e = clearEnd + 5
  while e < d.len and d[e] in White: inc e
  var enc = d[e .. ^1]
  var isHex = enc.len >= 4
  for k in 0 ..< min(4, enc.len):
    if hexv(enc[k]) < 0: isHex = false
  if isHex:
    var lx = Lexer(s: addr enc, p: 0)
    var h = ""
    for c in enc:
      if hexv(c) >= 0: h.add c
    enc = ""
    var k = 0
    while k + 1 < h.len:
      enc.add char(hexv(h[k]) * 16 + hexv(h[k + 1]))
      k += 2
    discard lx
  let priv = decrypt(enc, 55665, 4)
  var lenIV = 4
  let li = priv.find("/lenIV")
  if li >= 0:
    var lx = Lexer(s: unsafeAddr priv, p: li + 6)
    lenIV = lx.parseObj().int0(4)
  proc binAfter(at: int; n: int): (string, int) =
    ## (the n bytes after "RD " or "-| " at `at`)
    var q = at
    while q < priv.len and priv[q] == ' ': inc q
    while q < priv.len and priv[q] notin White: inc q          # (RD or -|)
    inc q                                                        # (one space)
    if q + n > priv.len: return ("", priv.len)
    (priv[q ..< q + n], q + n)
  # Subrs: dup i n RD <bin> NP
  let sb = priv.find("/Subrs")
  if sb >= 0:
    var q = sb
    while true:
      let du = priv.find("dup ", q)
      let cs = priv.find("/CharStrings", q)
      if du < 0 or (cs >= 0 and du > cs): break
      var lx = Lexer(s: unsafeAddr priv, p: du + 4)
      let idx = lx.parseObj().int0(-1)
      let n = lx.parseObj().int0(-1)
      if idx < 0 or n < 0 or idx > 10000: break
      let (bin, nq) = binAfter(lx.p, n)
      while t.subrs.len <= idx: t.subrs.add ""
      t.subrs[idx] = if lenIV >= 0: decrypt(bin, 4330, lenIV) else: bin
      q = nq
  let csAt = priv.find("/CharStrings")
  if csAt >= 0:
    var q = priv.find("begin", csAt)
    if q < 0: q = csAt + 12
    while q < priv.len:
      let sl = priv.find('/', q)
      if sl < 0: break
      if priv.continuesWith("/Private", sl) or priv.continuesWith("/FontName", sl): break
      var lx = Lexer(s: unsafeAddr priv, p: sl + 1)
      let nm = lx.readName()
      let n = lx.parseObj().int0(-1)
      if n < 0 or n > 65535:
        q = sl + 1
        continue
      let (bin, nq) = binAfter(lx.p, n)
      t.charStrings[nm] = if lenIV >= 0: decrypt(bin, 4330, lenIV) else: bin
      q = nq
  t

proc type1Glyph(t: Type1Font; name: string): GPath =
  ## A glyph's outline (Type 1 charstrings; flex and hint replacement
  ## followed as fonts use them).
  if t == nil or not t.charStrings.hasKey(name): return
  var stack: seq[float]
  var ps: seq[float]                        # (what othersubrs leave for pop)
  var x, y = 0.0
  var sbx = 0.0
  var flexing = false
  var flexPts: seq[(float, float)]
  var open = false
  var path: GPath
  var depth = 0
  proc moveTo(nx, ny: float) =
    if flexing:
      flexPts.add (nx, ny)
      x = nx; y = ny
      return
    if open: path.add ('h', 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    x = nx; y = ny
    path.add ('m', x, y, 0.0, 0.0, 0.0, 0.0)
    open = true
  proc lineTo(nx, ny: float) =
    if not open: moveTo(x, y)
    x = nx; y = ny
    path.add ('l', x, y, 0.0, 0.0, 0.0, 0.0)
  proc curveTo(ax, ay, bx, by, cx, cy: float) =
    if not open: moveTo(x, y)
    path.add ('c', ax, ay, bx, by, cx, cy)
    x = cx; y = cy
  proc run(cs: string) =
    inc depth
    if depth > 12: return
    var i = 0
    while i < cs.len:
      let v = ord(cs[i])
      inc i
      if v >= 32:
        if v <= 246: stack.add float(v - 139)
        elif v <= 250:
          stack.add float((v - 247) * 256 + ord(cs[min(i, cs.high)]) + 108)
          inc i
        elif v <= 254:
          stack.add float(-(v - 251) * 256 - ord(cs[min(i, cs.high)]) - 108)
          inc i
        else:
          var q = 0'u32
          for k in 0 .. 3: q = (q shl 8) or uint32(if i + k < cs.len: ord(cs[i + k]) else: 0)
          stack.add float(cast[int32](q))
          i += 4
        continue
      case v
      of 13:                                   # hsbw
        if stack.len >= 2:
          sbx = stack[0]
          x = sbx
          y = 0
        stack.setLen(0)
      of 21:
        if stack.len >= 2: moveTo(x + stack[0], y + stack[1])
        stack.setLen(0)
      of 22:
        if stack.len >= 1: moveTo(x + stack[0], y)
        stack.setLen(0)
      of 4:
        if stack.len >= 1: moveTo(x, y + stack[0])
        stack.setLen(0)
      of 5:
        if stack.len >= 2: lineTo(x + stack[0], y + stack[1])
        stack.setLen(0)
      of 6:
        if stack.len >= 1: lineTo(x + stack[0], y)
        stack.setLen(0)
      of 7:
        if stack.len >= 1: lineTo(x, y + stack[0])
        stack.setLen(0)
      of 8:
        if stack.len >= 6:
          let ax = x + stack[0]; let ay = y + stack[1]
          let bx = ax + stack[2]; let by = ay + stack[3]
          curveTo(ax, ay, bx, by, bx + stack[4], by + stack[5])
        stack.setLen(0)
      of 30:                                   # vhcurveto
        if stack.len >= 4:
          let ax = x; let ay = y + stack[0]
          let bx = ax + stack[1]; let by = ay + stack[2]
          curveTo(ax, ay, bx, by, bx + stack[3], by)
        stack.setLen(0)
      of 31:                                   # hvcurveto
        if stack.len >= 4:
          let ax = x + stack[0]; let ay = y
          let bx = ax + stack[1]; let by = ay + stack[2]
          curveTo(ax, ay, bx, by, bx, by + stack[3])
        stack.setLen(0)
      of 9:                                    # closepath
        if open: path.add ('h', 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
        open = false
        stack.setLen(0)
      of 10:                                   # callsubr
        if stack.len > 0:
          let n = int(stack.pop())
          if n >= 0 and n < t.subrs.len: run(t.subrs[n])
      of 11: break                             # return
      of 14:                                   # endchar
        if open: path.add ('h', 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
        open = false
        stack.setLen(0)
        depth = 100
        return
      of 1, 3: stack.setLen(0)                 # hstem vstem
      of 12:
        let e = if i < cs.len: ord(cs[i]) else: 0
        inc i
        case e
        of 7:                                  # sbw
          if stack.len >= 4:
            sbx = stack[0]
            x = stack[0]
            y = stack[1]
          stack.setLen(0)
        of 12:                                 # div
          if stack.len >= 2:
            let b = stack.pop()
            let a = stack.pop()
            stack.add(if b != 0: a / b else: 0.0)
        of 16:                                 # callothersubr
          if stack.len >= 2:
            let n = int(stack.pop())
            let argc = int(stack.pop())
            var args: seq[float]
            for _ in 0 ..< min(argc, stack.len): args.insert(stack.pop(), 0)
            case n
            of 1:
              flexing = true
              flexPts.setLen(0)
            of 2: discard
            of 0:
              flexing = false
              # (7 points: the reference, then two curves)
              if flexPts.len >= 7:
                let p = flexPts
                curveTo(p[1][0], p[1][1], p[2][0], p[2][1], p[3][0], p[3][1])
                curveTo(p[4][0], p[4][1], p[5][0], p[5][1], p[6][0], p[6][1])
              ps = @[y, x]
            of 3: ps = @[3.0]
            else: ps = args.reversed
        of 17:                                 # pop
          if ps.len > 0: stack.add ps.pop()
        of 33:                                 # setcurrentpoint
          if stack.len >= 2:
            x = stack[0]
            y = stack[1]
          stack.setLen(0)
        of 6:                                  # seac: an accented glyph from two
          if stack.len >= 5:
            let adx = stack[1]
            let ady = stack[2]
            let bc = int(stack[3])
            let ac = int(stack[4])
            stack.setLen(0)
            let bn = if bc in 0 .. 255: standardEncoding[bc] else: ""
            let an = if ac in 0 .. 255: standardEncoding[ac] else: ""
            for (nm, dx, dy) in [(bn, 0.0, 0.0), (an, adx - 0.0, ady)]:
              if nm.len > 0 and t.charStrings.hasKey(nm):
                let sub = type1Glyph(t, nm)
                for o in sub:
                  path.add (o.op, o.x1 + dx, o.y1 + dy, o.x2 + dx, o.y2 + dy, o.x3 + dx, o.y3 + dy)
            depth = 100
            return
        else: stack.setLen(0)
      else: stack.setLen(0)
    dec depth
  run(t.charStrings[name])
  if open: path.add ('h', 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
  path

# ---- the fonts of a page --------------------------------------------------------------------------------------

proc loadFont(f: PdfFile; fd: PObj): FontInfo =
  let key = cast[int](fd)
  if f.fonts.hasKey(key): return f.fonts[key]
  let fi = FontInfo(kind: fkBuiltin, matrix: [0.001, 0, 0, 0.001, 0, 0], dw: 1000)
  f.fonts[key] = fi
  let sub = f.g(fd, "Subtype").name
  var desc = fd
  var base = f.g(fd, "BaseFont").name
  if sub == "Type0":
    fi.composite = true
    let kids = f.g(fd, "DescendantFonts").arr
    if kids.len > 0: desc = f.resolve(kids[0])
    fi.dw = f.g(desc, "DW").num(1000)
    # widths: [c [w...]] or [c1 c2 w]
    let w = f.g(desc, "W").arr
    var k = 0
    while k < w.len:
      let a = f.resolve(w[k]).int0
      if k + 1 < w.len and f.resolve(w[k + 1]).kind == pkArr:
        for j, v in f.resolve(w[k + 1]).a: fi.widths[a + j] = f.resolve(v).num
        k += 2
      elif k + 2 < w.len:
        let b = f.resolve(w[k + 1]).int0
        let v = f.resolve(w[k + 2]).num
        if b - a < 65536:
          for c in a .. b: fi.widths[c] = v
        k += 3
      else: break
    let m = f.g(desc, "CIDToGIDMap")
    if m.kind == pkStream:
      let data = f.decodeStream(m)
      fi.cidToGid = newSeq[uint16](data.len div 2)
      for i in 0 ..< data.len div 2: fi.cidToGid[i] = uint16(u16(data, 2 * i))
    let enc = f.g(fd, "Encoding")
    if enc.kind == pkStream:
      var cids: Table[int, int]
      var ranges: seq[(int, int, int)]
      var dummy: Table[int, string]
      parseCMap(f.decodeStream(enc), dummy, fi.codeBytes, cids, ranges)
  else:
    let first = f.g(fd, "FirstChar").int0
    for i, v in f.g(fd, "Widths").arr: fi.widths[first + i] = f.resolve(v).num
    fi.dw = 0
  let fdesc = f.g(desc, "FontDescriptor")
  fi.symbolic = (f.g(fdesc, "Flags").int0 and 4) != 0
  # the encoding of a simple font: code -> glyph name
  if not fi.composite:
    let enc = f.g(fd, "Encoding")
    let baseName = if enc.kind == pkName: enc.s else: f.g(enc, "BaseEncoding").name
    let table = case baseName
                of "WinAnsiEncoding": winAnsiEncoding
                of "MacRomanEncoding": macRomanEncoding
                else: standardEncoding
    if baseName.len > 0 or not fi.symbolic:
      for code in 0 .. 255:
        if table[code].len > 0: fi.names[code] = table[code]
    var code = 0
    for d in f.g(enc, "Differences").arr:
      let o = f.resolve(d)
      if o.kind == pkNum: code = o.int0
      elif o.kind == pkName:
        fi.names[code] = o.s
        inc code
  # what the codes say (ToUnicode)
  let tu = f.g(fd, "ToUnicode")
  if tu.kind == pkStream:
    var cids: Table[int, int]
    var ranges: seq[(int, int, int)]
    var space: seq[tuple[lo, hi: int; bytes: int]]
    parseCMap(f.decodeStream(tu), fi.uni, space, cids, ranges)
  # the font program
  if sub == "Type3":
    fi.kind = fkType3
    let fm = f.g(fd, "FontMatrix").arr
    if fm.len == 6:
      for k in 0 .. 5: fi.matrix[k] = f.resolve(fm[k]).num
    fi.t3procs = f.g(fd, "CharProcs")
    fi.t3res = f.g(fd, "Resources")
    return fi
  let ff2 = f.g(fdesc, "FontFile2")
  let ff3 = f.g(fdesc, "FontFile3")
  let ff1 = f.g(fdesc, "FontFile")
  try:
    if ff2.kind == pkStream:
      fi.ttf = parseFace(f.decodeStream(ff2), loose = true)
      fi.kind = fkTrueType
      fi.matrix = [1 / max(1, fi.ttf.unitsPerEm).float, 0, 0, 1 / max(1, fi.ttf.unitsPerEm).float, 0, 0]
    elif ff3.kind == pkStream:
      let st = f.g(ff3, "Subtype").name
      if st == "OpenType":
        let data = f.decodeStream(ff3)
        if data.startsWith("OTTO"):
          # (CFF inside an OpenType font: its CFF table)
          let n = u16(data, 4)
          for i in 0 ..< n:
            let r = 12 + 16 * i
            if data[r ..< r + 4] == "CFF ":
              let off = (u16(data, r + 8) shl 16) or u16(data, r + 10)
              let ln = (u16(data, r + 12) shl 16) or u16(data, r + 14)
              fi.cff = parseCff(data[off ..< min(data.len, off + ln)])
        else:
          fi.ttf = parseFace(data, loose = true)
          fi.kind = fkTrueType
          fi.matrix = [1 / max(1, fi.ttf.unitsPerEm).float, 0, 0, 1 / max(1, fi.ttf.unitsPerEm).float, 0, 0]
      else: fi.cff = parseCff(f.decodeStream(ff3))
      if fi.cff != nil:
        fi.kind = fkCff
        fi.matrix = fi.cff.matrix
    elif ff1.kind == pkStream:
      fi.t1 = parseType1(f.decodeStream(ff1), f.g(ff1, "Length1").int0)
      if fi.t1.charStrings.len > 0:
        fi.kind = fkType1
        fi.matrix = fi.t1.matrix
        if f.g(fd, "Encoding").kind == pkNull:
          for code, nm in fi.t1.encoding: fi.names[code] = nm
  except CatchableError:
    fi.kind = fkBuiltin
  if fi.kind == fkBuiltin:
    let bn = base.toLowerAscii
    let bold = "bold" in bn or "black" in bn or "heavy" in bn
    let mono = "courier" in bn or "mono" in bn or "consol" in bn
    let italic = "italic" in bn or "oblique" in bn
    let serif = not mono and ("times" in bn or "serif" in bn and "sans" notin bn or "roman" in bn or
                              "georgia" in bn or "garamond" in bn or "cambria" in bn or "book" in bn)
    # (the standard fonts by their FreeFont likes: Courier FreeMono, Times
    # FreeSerif, Helvetica and the rest FreeSans -- the same widths)
    fi.builtin = styled(if mono: fMono elif serif: fSerif else: fSans, bold, italic)
    fi.matrix = [1 / max(1, builtinFace(fi.builtin).unitsPerEm).float, 0, 0,
                 1 / max(1, builtinFace(fi.builtin).unitsPerEm).float, 0, 0]
    # a font named, not embedded (the standard 14): its widths, as Adobe's
    # metrics give them -- the text keeps its place in whatever face draws it
    if not fi.composite and fi.widths.len == 0:
      if mono:
        for code in 0 .. 255: fi.widths[code] = 600
      else:
        let ws = afmWidths(base)
        if ws.len > 0:
          for code in 0 .. 255:
            let nm = if fi.names.hasKey(code): fi.names[code]
                     elif base.toLowerAscii.contains("symbol") or base.toLowerAscii.contains("dingbat"): ""
                     else: standardEncoding[code]
            if nm.len > 0 and ws.hasKey(nm): fi.widths[code] = ws[nm].float
  fi

proc codesOf(fi: FontInfo; s: string): seq[int] =
  ## The codes a string shows: bytes, or two bytes each (a composite font),
  ## or as the font's CMap says.
  if not fi.composite:
    for c in s: result.add ord(c)
    return
  if fi.codeBytes.len == 0:
    var i = 0
    while i + 1 < s.len:
      result.add (ord(s[i]) shl 8) or ord(s[i + 1])
      i += 2
    return
  var i = 0
  while i < s.len:
    var done = false
    for n in 1 .. 4:
      if i + n > s.len: break
      let v = bytesNum(s[i ..< i + n])
      for sp in fi.codeBytes:
        if sp.bytes == n and v >= sp.lo and v <= sp.hi:
          result.add v
          i += n
          done = true
          break
      if done: break
    if not done:
      result.add ord(s[i])
      inc i

proc textOf(fi: FontInfo; code: int): string =
  ## What a code is as text.
  if fi.uni.hasKey(code): return fi.uni[code]
  if fi.names.hasKey(code):
    let u = unicodeOfName(fi.names[code])
    if u > 0: return Rune(u).toUTF8
  if not fi.composite and code >= 32 and code < 127: return $char(code)

proc builtinAdvance(fi: FontInfo; code: int): float =
  ## The advance of the face standing in for a font not embedded (an em = 1).
  let face = builtinFace(fi.builtin)
  let t = fi.textOf(code)
  let u = if t.len > 0: t.runeAt(0).int else: code
  face.advance(face.glyphOf(u)) / max(1, face.unitsPerEm)

proc widthOf(fi: FontInfo; code: int): float =
  ## The code's advance in text space (an em = 1).
  if fi.kind == fkType3:
    let w = fi.widths.getOrDefault(code, 0)
    return w * fi.matrix[0]
  if fi.widths.hasKey(code): return fi.widths[code] / 1000
  if fi.composite: return fi.dw / 1000
  # (no widths given: the glyph's own)
  case fi.kind
  of fkTrueType:
    let g = if fi.names.hasKey(code) and unicodeOfName(fi.names[code]) > 0:
              fi.ttf.glyphOf(unicodeOfName(fi.names[code]))
            else: fi.ttf.codeGlyph(code)
    fi.ttf.advance(g) / max(1, fi.ttf.unitsPerEm)
  of fkBuiltin: fi.builtinAdvance(code)
  else: 0.5

proc glyphPath(fi: FontInfo; code: int): GPath =
  ## The outline of a code, in glyph space (then `fi.matrix`).
  case fi.kind
  of fkTrueType:
    var g = 0
    if fi.composite:
      g = if fi.cidToGid.len > 0: (if code < fi.cidToGid.len: int(fi.cidToGid[code]) else: 0) else: code
    else:
      if not fi.symbolic and fi.names.hasKey(code):
        let u = unicodeOfName(fi.names[code])
        if u > 0: g = fi.ttf.glyphOf(u)
      if g == 0: g = fi.ttf.codeGlyph(code)
      if g == 0 and fi.uni.hasKey(code) and fi.uni[code].len > 0:
        g = fi.ttf.glyphOf(fi.uni[code].runeAt(0).int)
    if g <= 0 or g >= fi.ttf.numGlyphs: return
    for c in fi.ttf.contours(g, 8):
      if c.len == 0: continue
      result.add ('m', c[0][0].float, c[0][1].float, 0.0, 0.0, 0.0, 0.0)
      for k in 1 ..< c.len: result.add ('l', c[k][0].float, c[k][1].float, 0.0, 0.0, 0.0, 0.0)
      result.add ('h', 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
  of fkCff:
    let c = fi.cff
    var g = -1
    if fi.composite or c.cid:
      if c.cid:
        # (CID -> glyph by the charset)
        if c.cidGlyph.len == 0:
          for k, v in c.charset: c.cidGlyph[v] = k
        g = c.cidGlyph.getOrDefault(code, -1)
      else: g = code
    else:
      if fi.names.hasKey(code) and c.names.hasKey(fi.names[code]): g = c.names[fi.names[code]]
      elif code in 0 .. 255: g = c.encoding[code]
    if g > 0: result = c.cffGlyph(g)
  of fkType1:
    let nm = fi.names.getOrDefault(code, "")
    if nm.len > 0: result = fi.t1.type1Glyph(nm)
  of fkBuiltin:
    let t = fi.textOf(code)
    if t.len == 0: return
    let face = builtinFace(fi.builtin)
    let g = face.glyphOf(t.runeAt(0).int)
    if g <= 0: return
    for cn in face.contours(g, 8):
      if cn.len == 0: continue
      result.add ('m', cn[0][0].float, cn[0][1].float, 0.0, 0.0, 0.0, 0.0)
      for k in 1 ..< cn.len: result.add ('l', cn[k][0].float, cn[k][1].float, 0.0, 0.0, 0.0, 0.0)
      result.add ('h', 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
  of fkType3: discard

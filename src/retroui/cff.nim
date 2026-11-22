## CFF -- the outlines of OpenType fonts that are PostScript's (".otf" files that begin "OTTO",
## and the faces of an ".otc" or ".ttc" collection that are): their table read (`parseCff`),
## a glyph's outline from its Type 2 charstring (`cffGlyph`: lines and cubic curves), and the
## whole font made one with TrueType outlines (`otfToTtf`) -- each cubic curve cut into
## quadratic ones close to it, in glyf and loca, every other table as it was -- which is how
## the kit's text engine, its PDF writer and everything else that reads fonts takes them.
##
## ```nim
## let ttf = otfToTtf(readFile("Amiri-Regular.otf"))   # "" when it is not one
## let face = parseFace(ttf)                             # (ttf's parseFace does it by itself)
## ```
##
## CFF2 (variable PostScript outlines: Adobe's variable fonts) is read at its default instance:
## its blends' default values taken, the deltas left.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[tables, strutils, math, algorithm]
import pdfencodings

type
  CffOp* = tuple[op: char; x1, y1, x2, y2, x3, y3: float]
    ## A step of a glyph's outline: 'm' move to (x1, y1), 'l' line to it, 'c' a cubic curve
    ## (x1, y1) (x2, y2) to (x3, y3), 'h' the contour closed.
  CffPath* = seq[CffOp]

  CffFont* = ref object
    ## A CFF table, read (`parseCff`).
    data*: string
    charStrings*: seq[(int, int)]          ## glyph -> its charstring (start, end) in `data`
    gsubrs*, lsubrs*: seq[(int, int)]
    fdSubrs*: seq[seq[(int, int)]]         ## (CID-keyed) the subroutines of each font dict
    fdSelect*: seq[uint8]                  ## (CID-keyed) glyph -> font dict
    charset*: seq[int]                     ## glyph -> SID (or CID)
    names*: Table[string, int]             ## glyph name -> glyph
    cidGlyph*: Table[int, int]             ## (CID-keyed) CID -> glyph, filled by who needs it
    encoding*: array[256, int]             ## code -> glyph (its own encoding)
    cid*: bool                             ## CID-keyed (a CJK font's kind)
    strings*: seq[string]
    matrix*: array[6, float]               ## the FontMatrix: units to an em of 1
    nominalW*, defaultW*: float
    cff2*: bool                            ## a CFF2 table (variable): its default instance is read
    regions*: seq[int]                     ## (CFF2) each item variation data's region count
    fdVsIndex*: seq[int]                   ## (CFF2) each font dict's vsindex

proc u8(s: string; i: int): int {.inline.} = (if i >= 0 and i < s.len: ord(s[i]) else: 0)
proc u16(s: string; i: int): int {.inline.} = (u8(s, i) shl 8) or u8(s, i + 1)
proc u32(s: string; i: int): int {.inline.} = (u16(s, i) shl 16) or u16(s, i + 2)

proc readIndex(s: string; at: int): (seq[(int, int)], int) =
  ## A CFF INDEX at `at`: its items (start, end), and where it ends.
  let count = u16(s, at)
  if count == 0: return (@[], at + 2)
  let offSize = u8(s, at + 2)
  if offSize notin 1 .. 4: return (@[], at + 3)
  let base = at + 3 + (count + 1) * offSize - 1
  var offs = newSeq[int](count + 1)
  for i in 0 .. count:
    var v = 0
    for k in 0 ..< offSize: v = (v shl 8) or u8(s, at + 3 + i * offSize + k)
    offs[i] = v
  var items: seq[(int, int)]
  for i in 0 ..< count: items.add (base + offs[i], base + offs[i + 1])
  (items, base + offs[count])

proc readIndex2(s: string; at: int): (seq[(int, int)], int) =
  ## A CFF2 INDEX (its count four bytes) at `at`: its items (start, end), and where it ends.
  let count = u32(s, at)
  if count <= 0 or count > 1_000_000: return (@[], at + 4)
  let offSize = u8(s, at + 4)
  if offSize notin 1 .. 4: return (@[], at + 5)
  let base = at + 5 + (count + 1) * offSize - 1
  var offs = newSeq[int](count + 1)
  for i in 0 .. count:
    var v = 0
    for k in 0 ..< offSize: v = (v shl 8) or u8(s, at + 5 + i * offSize + k)
    offs[i] = v
  var items: seq[(int, int)]
  for i in 0 ..< count: items.add (base + offs[i], base + offs[i + 1])
  (items, base + offs[count])

proc readDict(s: string; a, b: int): Table[int, seq[float]] =
  ## A CFF DICT: operator (12 x as 1200 + x) -> its operands. (CFF2's blend in a DICT: the
  ## default values kept.)
  var ops: seq[float]
  var i = a
  while i < b and i < s.len:
    let c = u8(s, i)
    if c == 23:
      # (blend: n defaults, their deltas, n -- the defaults kept)
      inc i
      if ops.len > 0:
        let n = int(ops.pop())
        if n >= 0 and n <= ops.len: ops.setLen(n)
    elif c <= 24:
      var op = c
      inc i
      if c == 12:
        op = 1200 + u8(s, i)
        inc i
      result[op] = ops
      ops.setLen(0)
    elif c == 28:
      var v = u16(s, i + 1)
      if v >= 0x8000: v -= 0x10000
      ops.add v.float
      i += 3
    elif c == 29:
      let v = cast[int32]((uint32(u16(s, i + 1)) shl 16) or uint32(u16(s, i + 3)))
      ops.add v.float
      i += 5
    elif c == 30:
      # a real: nibbles
      var txt = ""
      inc i
      block reading:
        while i < b:
          let byt = u8(s, i)
          inc i
          for nib in [byt shr 4, byt and 15]:
            case nib
            of 0 .. 9: txt.add char(ord('0') + nib)
            of 10: txt.add '.'
            of 11: txt.add 'E'
            of 12: txt.add "E-"
            of 14: txt.add '-'
            of 15: break reading
            else: discard
      ops.add(try: parseFloat(txt) except ValueError: 0.0)
    elif c >= 32 and c <= 246:
      ops.add float(c - 139)
      inc i
    elif c >= 247 and c <= 250:
      ops.add float((c - 247) * 256 + u8(s, i + 1) + 108)
      i += 2
    elif c >= 251 and c <= 254:
      ops.add float(-(c - 251) * 256 - u8(s, i + 1) - 108)
      i += 2
    else: inc i

proc parseCff2(data: string): CffFont =
  ## (a CFF2 table: its top dict, global subroutines, font dicts, charstrings, regions)
  let f = CffFont(data: data, matrix: [0.001, 0, 0, 0.001, 0, 0], cff2: true, cid: true)
  for c in f.encoding.mitems: c = 0
  let hdr = u8(data, 2)
  let topLen = u16(data, 3)
  let top = readDict(data, hdr, hdr + topLen)
  f.gsubrs = readIndex2(data, hdr + topLen)[0]
  if top.hasKey(1207) and top[1207].len >= 6:
    for k in 0 .. 5: f.matrix[k] = top[1207][k]
  if not top.hasKey(17) or top[17].len == 0: return nil
  f.charStrings = readIndex2(data, int(top[17][0]))[0]
  let n = f.charStrings.len
  if top.hasKey(1236) and top[1236].len > 0:
    for (a, b) in readIndex2(data, int(top[1236][0]))[0]:
      let fd = readDict(data, a, b)
      var subrs: seq[(int, int)]
      var vsi = 0
      if fd.hasKey(18) and fd[18].len >= 2:
        let size = int(fd[18][0])
        let off = int(fd[18][1])
        let pr = readDict(data, off, off + size)
        if pr.hasKey(19) and pr[19].len > 0: subrs = readIndex2(data, off + int(pr[19][0]))[0]
        if pr.hasKey(22) and pr[22].len > 0: vsi = int(pr[22][0])
      f.fdSubrs.add subrs
      f.fdVsIndex.add vsi
  if f.fdSubrs.len == 0: return nil
  f.fdSelect = newSeq[uint8](n)
  if top.hasKey(1237) and top[1237].len > 0:
    let at = int(top[1237][0])
    case u8(data, at)
    of 0:
      for g in 0 ..< n: f.fdSelect[g] = uint8(u8(data, at + 1 + g))
    of 3:
      let nr = u16(data, at + 1)
      for r in 0 ..< nr:
        let first = u16(data, at + 3 + r * 3)
        let fdi = u8(data, at + 5 + r * 3)
        let next = u16(data, at + 6 + r * 3)
        for g in first ..< min(next, n): f.fdSelect[g] = uint8(fdi)
    of 4:
      let nr = u32(data, at + 1)
      for r in 0 ..< min(nr, 65536):
        let first = u32(data, at + 5 + r * 6)
        let fdi = u16(data, at + 9 + r * 6)
        let next = u32(data, at + 11 + r * 6)
        for g in first ..< min(next, n): f.fdSelect[g] = uint8(min(fdi, 255))
    else: discard
  # (the variation store: how many regions each blend's deltas are for)
  if top.hasKey(24) and top[24].len > 0:
    let vs = int(top[24][0]) + 2
    let count = u16(data, vs + 6)
    for k in 0 ..< count:
      let d = vs + u32(data, vs + 8 + 4 * k)
      f.regions.add u16(data, d + 4)
  f.charset = newSeq[int](n)
  for g in 0 ..< n: f.charset[g] = g
  f

proc parseCff*(data: string): CffFont =
  ## A CFF table read (its first font), or a CFF2 one (`cff2`): nil when it is not one.
  if data.len < 8: return nil
  if u8(data, 0) == 2: return parseCff2(data)
  let f = CffFont(data: data, matrix: [0.001, 0, 0, 0.001, 0, 0])
  for c in f.encoding.mitems: c = 0
  let hdr = u8(data, 2)
  let (names, a1) = readIndex(data, hdr)
  let (tops, a2) = readIndex(data, a1)
  let (strs, a3) = readIndex(data, a2)
  let (gsubrs, _) = readIndex(data, a3)
  f.gsubrs = gsubrs
  for (a, b) in strs: f.strings.add data[a ..< min(b, data.len)]
  if tops.len == 0: return nil
  discard names
  let top = readDict(data, tops[0][0], tops[0][1])
  if top.hasKey(1207) and top[1207].len >= 6:
    for k in 0 .. 5: f.matrix[k] = top[1207][k]
  if not top.hasKey(17) or top[17].len == 0: return nil
  let (cs, _) = readIndex(data, int(top[17][0]))
  f.charStrings = cs
  f.cid = top.hasKey(1230)
  proc privateOf(d: Table[int, seq[float]]): (seq[(int, int)], float, float) =
    if not d.hasKey(18) or d[18].len < 2: return (@[], 0.0, 0.0)
    let size = int(d[18][0])
    let off = int(d[18][1])
    let p = readDict(data, off, off + size)
    var subrs: seq[(int, int)]
    if p.hasKey(19) and p[19].len > 0: subrs = readIndex(data, off + int(p[19][0]))[0]
    (subrs, (if p.hasKey(20) and p[20].len > 0: p[20][0] else: 0.0),
     (if p.hasKey(21) and p[21].len > 0: p[21][0] else: 0.0))
  if f.cid:
    if top.hasKey(1236) and top[1236].len > 0:
      let (fds, _) = readIndex(data, int(top[1236][0]))
      for (a, b) in fds:
        let fd = readDict(data, a, b)
        f.fdSubrs.add privateOf(fd)[0]
    if top.hasKey(1237) and top[1237].len > 0:
      let at = int(top[1237][0])
      let n = cs.len
      f.fdSelect = newSeq[uint8](n)
      case u8(data, at)
      of 0:
        for g in 0 ..< n: f.fdSelect[g] = uint8(u8(data, at + 1 + g))
      of 3:
        let nr = u16(data, at + 1)
        for r in 0 ..< nr:
          let first = u16(data, at + 3 + r * 3)
          let fdi = u8(data, at + 5 + r * 3)
          let next = u16(data, at + 6 + r * 3)
          for g in first ..< min(next, n): f.fdSelect[g] = uint8(fdi)
      else: discard
  else:
    let (subrs, dw, nw) = privateOf(top)
    f.lsubrs = subrs
    f.defaultW = dw
    f.nominalW = nw
  # charset: glyph -> SID (or CID)
  let n = cs.len
  f.charset = newSeq[int](n)
  let csOff = if top.hasKey(15) and top[15].len > 0: int(top[15][0]) else: 0
  if csOff > 2:
    var g = 1
    case u8(data, csOff)
    of 0:
      while g < n:
        f.charset[g] = u16(data, csOff + 1 + (g - 1) * 2)
        inc g
    of 1, 2:
      var p = csOff + 1
      let big = u8(data, csOff) == 2
      while g < n and p < data.len:
        let first = u16(data, p)
        let left = if big: u16(data, p + 2) else: u8(data, p + 2)
        p += (if big: 4 else: 3)
        for k in 0 .. left:
          if g >= n: break
          f.charset[g] = first + k
          inc g
    else: discard
  else:
    for g in 0 ..< n: f.charset[g] = g          # (ISOAdobe: in order)
  if not f.cid:
    for g in 0 ..< n:
      let sid = f.charset[g]
      let nm = if sid < cffStandardStrings.len: cffStandardStrings[sid]
               elif sid - cffStandardStrings.len < f.strings.len: f.strings[sid - cffStandardStrings.len]
               else: ""
      if nm.len > 0 and not f.names.hasKey(nm): f.names[nm] = g
    # its own encoding: code -> glyph
    let encOff = if top.hasKey(16) and top[16].len > 0: int(top[16][0]) else: 0
    if encOff > 1:
      let fmt = u8(data, encOff) and 0x7F
      if fmt == 0:
        let nc = u8(data, encOff + 1)
        for k in 0 ..< nc:
          let code = u8(data, encOff + 2 + k)
          if k + 1 < n: f.encoding[code] = k + 1
      elif fmt == 1:
        let nr = u8(data, encOff + 1)
        var g = 1
        for r in 0 ..< nr:
          let first = u8(data, encOff + 2 + r * 2)
          let left = u8(data, encOff + 3 + r * 2)
          for k in 0 .. left:
            if first + k < 256 and g < n: f.encoding[first + k] = g
            inc g
    else:
      for code in 0 .. 255:
        let nm = standardEncoding[code]
        if nm.len > 0 and f.names.hasKey(nm): f.encoding[code] = f.names[nm]
  f

proc cffGlyph*(f: CffFont; gid: int; depthIn = 0): CffPath =
  ## Glyph `gid`'s outline (its Type 2 charstring run), in font units; an accented glyph made
  ## of two (endchar's seac) both.
  if f == nil or gid < 0 or gid >= f.charStrings.len or depthIn > 2: return
  var stack: seq[float]
  var x, y = 0.0
  var nStems = 0
  var widthDone = f.cff2                       # (CFF2: no widths in the charstrings)
  var open = false
  var depth = 0
  # (the font's data and subroutines reached where they are -- a `let` would copy them, the
  # whole CFF table, at every call)
  let fd = if f.cid and f.fdSelect.len > gid and int(f.fdSelect[gid]) < f.fdSubrs.len: int(f.fdSelect[gid]) else: -1
  var vsindex = if f.cff2 and fd >= 0 and fd < f.fdVsIndex.len: f.fdVsIndex[fd] else: 0
  template nSubrs: int = (if fd >= 0: f.fdSubrs[fd].len else: f.lsubrs.len)
  template subr(k: int): (int, int) = (if fd >= 0: f.fdSubrs[fd][k] else: f.lsubrs[k])
  var path: CffPath
  proc bias(n: int): int = (if n < 1240: 107 elif n < 33900: 1131 else: 32768)
  proc moveTo(nx, ny: float) =
    if open: path.add ('h', 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    x = nx; y = ny
    path.add ('m', x, y, 0.0, 0.0, 0.0, 0.0)
    open = true
  proc lineTo(nx, ny: float) =
    x = nx; y = ny
    path.add ('l', x, y, 0.0, 0.0, 0.0, 0.0)
  proc curveTo(ax, ay, bx, by, cx, cy: float) =
    path.add ('c', ax, ay, bx, by, cx, cy)
    x = cx; y = cy
  proc seac(adx, ady: float; bchar, achar: int) =
    # (an accented letter: the base and the accent of the standard encoding, the accent moved)
    proc glyphOfCode(c: int): int =
      if c notin 0 .. 255: return -1
      let nm = standardEncoding[c]
      if nm.len == 0: return -1
      f.names.getOrDefault(nm, -1)
    let b = glyphOfCode(bchar)
    let a = glyphOfCode(achar)
    if b > 0: path.add f.cffGlyph(b, depthIn + 1)
    if a > 0:
      for op in f.cffGlyph(a, depthIn + 1):
        var o = op
        if o.op != 'h':
          o.x1 += adx; o.y1 += ady
          if o.op == 'c':
            o.x2 += adx; o.y2 += ady; o.x3 += adx; o.y3 += ady
        path.add o
  proc run(a, b: int) =
    inc depth
    if depth > 12: return
    var i = a
    template s: untyped = f.data
    while i < b:
      let v = u8(s, i)
      if v >= 32 or v == 28:
        if v == 28:
          var q = u16(s, i + 1)
          if q >= 0x8000: q -= 0x10000
          stack.add q.float
          i += 3
        elif v <= 246:
          stack.add float(v - 139)
          inc i
        elif v <= 250:
          stack.add float((v - 247) * 256 + u8(s, i + 1) + 108)
          i += 2
        elif v <= 254:
          stack.add float(-(v - 251) * 256 - u8(s, i + 1) - 108)
          i += 2
        else:
          let q = cast[int32]((uint32(u16(s, i + 1)) shl 16) or uint32(u16(s, i + 3)))
          stack.add q.float / 65536
          i += 5
        continue
      inc i
      template takeWidth(evenWanted: bool) =
        if not widthDone:
          widthDone = true
          if (stack.len mod 2 == 1) == evenWanted and stack.len > 0: stack.delete(0)
      case v
      of 1, 3, 18, 23:                         # hstem vstem hstemhm vstemhm
        takeWidth(true)
        nStems += stack.len div 2
        stack.setLen(0)
      of 19, 20:                               # hintmask cntrmask
        takeWidth(true)
        nStems += stack.len div 2
        stack.setLen(0)
        i += (nStems + 7) div 8
      of 21:                                   # rmoveto
        takeWidth(true)
        if stack.len >= 2: moveTo(x + stack[^2], y + stack[^1])
        stack.setLen(0)
      of 22:                                   # hmoveto
        takeWidth(false)
        if stack.len >= 1: moveTo(x + stack[^1], y)
        stack.setLen(0)
      of 4:                                    # vmoveto
        takeWidth(false)
        if stack.len >= 1: moveTo(x, y + stack[^1])
        stack.setLen(0)
      of 5:                                    # rlineto
        var k = 0
        while k + 1 < stack.len:
          lineTo(x + stack[k], y + stack[k + 1])
          k += 2
        stack.setLen(0)
      of 6, 7:                                 # hlineto vlineto
        var horiz = v == 6
        for d in stack:
          if horiz: lineTo(x + d, y) else: lineTo(x, y + d)
          horiz = not horiz
        stack.setLen(0)
      of 8:                                    # rrcurveto
        var k = 0
        while k + 5 < stack.len:
          let ax = x + stack[k]
          let ay = y + stack[k + 1]
          let bx = ax + stack[k + 2]
          let by = ay + stack[k + 3]
          curveTo(ax, ay, bx, by, bx + stack[k + 4], by + stack[k + 5])
          k += 6
        stack.setLen(0)
      of 24:                                   # rcurveline
        var k = 0
        while k + 5 < stack.len - 2:
          let ax = x + stack[k]
          let ay = y + stack[k + 1]
          let bx = ax + stack[k + 2]
          let by = ay + stack[k + 3]
          curveTo(ax, ay, bx, by, bx + stack[k + 4], by + stack[k + 5])
          k += 6
        if k + 1 < stack.len: lineTo(x + stack[k], y + stack[k + 1])
        stack.setLen(0)
      of 25:                                   # rlinecurve
        var k = 0
        while k + 1 < stack.len - 6:
          lineTo(x + stack[k], y + stack[k + 1])
          k += 2
        if k + 5 < stack.len:
          let ax = x + stack[k]
          let ay = y + stack[k + 1]
          let bx = ax + stack[k + 2]
          let by = ay + stack[k + 3]
          curveTo(ax, ay, bx, by, bx + stack[k + 4], by + stack[k + 5])
        stack.setLen(0)
      of 26:                                   # vvcurveto
        var k = 0
        var dx1 = 0.0
        if stack.len mod 4 == 1:
          dx1 = stack[0]
          k = 1
        while k + 3 < stack.len:
          let ax = x + dx1
          let ay = y + stack[k]
          let bx = ax + stack[k + 1]
          let by = ay + stack[k + 2]
          curveTo(ax, ay, bx, by, bx, by + stack[k + 3])
          dx1 = 0
          k += 4
        stack.setLen(0)
      of 27:                                   # hhcurveto
        var k = 0
        var dy1 = 0.0
        if stack.len mod 4 == 1:
          dy1 = stack[0]
          k = 1
        while k + 3 < stack.len:
          let ax = x + stack[k]
          let ay = y + dy1
          let bx = ax + stack[k + 1]
          let by = ay + stack[k + 2]
          curveTo(ax, ay, bx, by, bx + stack[k + 3], by)
          dy1 = 0
          k += 4
        stack.setLen(0)
      of 30, 31:                               # vhcurveto hvcurveto
        var horiz = v == 31
        var k = 0
        while k + 3 < stack.len:
          let last = k + 4 >= stack.len - 1
          let extra = if last and stack.len - k == 5: stack[k + 4] else: 0.0
          if horiz:
            let ax = x + stack[k]
            let ay = y
            let bx = ax + stack[k + 1]
            let by = ay + stack[k + 2]
            curveTo(ax, ay, bx, by, bx + extra, by + stack[k + 3])
          else:
            let ax = x
            let ay = y + stack[k]
            let bx = ax + stack[k + 1]
            let by = ay + stack[k + 2]
            curveTo(ax, ay, bx, by, bx + stack[k + 3], by + extra)
          horiz = not horiz
          k += 4
        stack.setLen(0)
      of 10:                                   # callsubr
        if stack.len > 0:
          let n = int(stack.pop()) + bias(nSubrs)
          if n >= 0 and n < nSubrs:
            let (sa, sb) = subr(n)
            run(sa, sb)
      of 29:                                   # callgsubr
        if stack.len > 0:
          let n = int(stack.pop()) + bias(f.gsubrs.len)
          if n >= 0 and n < f.gsubrs.len: run(f.gsubrs[n][0], f.gsubrs[n][1])
      of 11: break                             # return
      of 15:                                   # vsindex (CFF2)
        if f.cff2 and stack.len > 0: vsindex = int(stack.pop())
        stack.setLen(0)
      of 16:                                   # blend (CFF2): the defaults kept
        if f.cff2 and stack.len > 0:
          let n = int(stack.pop())
          let k = if vsindex in 0 ..< f.regions.len: f.regions[vsindex] else: 0
          let first = stack.len - n * (k + 1)
          if n >= 0 and first >= 0: stack.setLen(first + n)
          else: stack.setLen(0)
        else: stack.setLen(0)
      of 14:                                   # endchar
        if not widthDone:
          widthDone = true
          if stack.len == 1 or stack.len == 5: stack.delete(0)
        if open: path.add ('h', 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
        open = false
        if stack.len >= 4:
          seac(stack[^4], stack[^3], int(stack[^2]), int(stack[^1]))
        stack.setLen(0)
        depth = 100
        return
      of 12:
        let e = u8(s, i)
        inc i
        case e
        of 35:                                 # flex
          if stack.len >= 12:
            let ax = x + stack[0]; let ay = y + stack[1]
            let bx = ax + stack[2]; let by = ay + stack[3]
            let cx = bx + stack[4]; let cy = by + stack[5]
            curveTo(ax, ay, bx, by, cx, cy)
            let dx = x + stack[6]; let dy = y + stack[7]
            let ex = dx + stack[8]; let ey = dy + stack[9]
            curveTo(dx, dy, ex, ey, ex + stack[10], ey + stack[11])
        of 34:                                 # hflex
          if stack.len >= 7:
            let y0 = y
            let ax = x + stack[0]; let ay = y
            let bx = ax + stack[1]; let by = ay + stack[2]
            let cx = bx + stack[3]; let cy = by
            curveTo(ax, ay, bx, by, cx, cy)
            let dx = x + stack[4]; let dy = by
            let ex = dx + stack[5]; let ey = y0
            curveTo(dx, dy, ex, ey, ex + stack[6], y0)
        of 36:                                 # hflex1
          if stack.len >= 9:
            let y0 = y
            let ax = x + stack[0]; let ay = y + stack[1]
            let bx = ax + stack[2]; let by = ay + stack[3]
            let cx = bx + stack[4]; let cy = by
            curveTo(ax, ay, bx, by, cx, cy)
            let dx = x + stack[5]; let dy = cy
            let ex = dx + stack[6]; let ey = dy + stack[7]
            curveTo(dx, dy, ex, ey, ex + stack[8], y0)
        of 37:                                 # flex1
          if stack.len >= 11:
            let x0 = x
            let y0 = y
            let ax = x + stack[0]; let ay = y + stack[1]
            let bx = ax + stack[2]; let by = ay + stack[3]
            let cx = bx + stack[4]; let cy = by + stack[5]
            curveTo(ax, ay, bx, by, cx, cy)
            let dx = x + stack[6]; let dy = y + stack[7]
            let ex = dx + stack[8]; let ey = dy + stack[9]
            var fx, fy: float
            if abs(ex - x0) > abs(ey - y0):
              fx = ex + stack[10]; fy = y0
            else:
              fx = x0; fy = ey + stack[10]
            curveTo(dx, dy, ex, ey, fx, fy)
        else: discard
        stack.setLen(0)
      else:
        stack.setLen(0)
    dec depth
  run(f.charStrings[gid][0], f.charStrings[gid][1])
  if open: path.add ('h', 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
  path

# ---- the font made one with TrueType outlines ------------------------------------------------------

type QPoint = tuple[x, y: int; on: bool]

proc quadsOf(p0x, p0y, c1x, c1y, c2x, c2y, p3x, p3y, tol: float; pts: var seq[QPoint]) =
  ## (a cubic curve as quadratic ones, each within `tol` of it: their controls and ends added;
  ## a quadratic's control (3 (c1 + c2) - (p0 + p3)) / 4 is off the cubic by at most
  ## sqrt(3) / 36 |p3 - 3 c2 + 3 c1 - p0|, and n pieces by that over n cubed)
  let ex = p3x - 3 * c2x + 3 * c1x - p0x
  let ey = p3y - 3 * c2y + 3 * c1y - p0y
  let err = sqrt(ex * ex + ey * ey) * sqrt(3.0) / 36
  let n = clamp(int(ceil(cbrt(err / max(tol, 1e-6)))), 1, 16)
  proc at(t: float): (float, float) =
    let u = 1 - t
    (u*u*u*p0x + 3*u*u*t*c1x + 3*u*t*t*c2x + t*t*t*p3x, u*u*u*p0y + 3*u*u*t*c1y + 3*u*t*t*c2y + t*t*t*p3y)
  proc slope(t: float): (float, float) =
    let u = 1 - t
    (3*u*u*(c1x - p0x) + 6*u*t*(c2x - c1x) + 3*t*t*(p3x - c2x),
     3*u*u*(c1y - p0y) + 6*u*t*(c2y - c1y) + 3*t*t*(p3y - c2y))
  for i in 0 ..< n:
    let ta = i / n
    let tb = (i + 1) / n
    let h = (tb - ta) / 3
    let (ax, ay) = at(ta)
    let (bx, by) = at(tb)
    let (sax, say) = slope(ta)
    let (sbx, sby) = slope(tb)
    let (q1x, q1y) = (ax + h * sax, ay + h * say)
    let (q2x, q2y) = (bx - h * sbx, by - h * sby)
    let cx = (3 * (q1x + q2x) - (ax + bx)) / 4
    let cy = (3 * (q1y + q2y) - (ay + by)) / 4
    pts.add (int(round(cx)), int(round(cy)), false)
    pts.add (int(round(bx)), int(round(by)), true)

proc glyfOf*(path: CffPath; m: array[6, float]; upem: int; tol: float;
            bbox: var tuple[x0, y0, x1, y1: int]; points, contours: var int): string =
  ## (one glyph's outline as a TrueType glyf entry: its contours turned round -- PostScript's
  ## outer contours go counterclockwise, TrueType's clockwise --, no instructions)
  proc tx(x, y: float): (float, float) =
    ((m[0] * x + m[2] * y + m[4]) * upem.float, (m[1] * x + m[3] * y + m[5]) * upem.float)
  var cons: seq[seq[QPoint]]
  var cur: seq[QPoint]
  var cx, cy = 0.0
  proc close() =
    # (the last point the first again: once is enough -- TrueType closes a contour itself)
    while cur.len > 1 and cur[^1].on and cur[^1].x == cur[0].x and cur[^1].y == cur[0].y: cur.setLen(cur.len - 1)
    if cur.len >= 2: cons.add cur
    cur.setLen(0)
  for op in path:
    case op.op
    of 'm':
      close()
      (cx, cy) = tx(op.x1, op.y1)
      cur.add (int(round(cx)), int(round(cy)), true)
    of 'l':
      let (nx, ny) = tx(op.x1, op.y1)
      let p = (int(round(nx)), int(round(ny)), true)
      if cur.len == 0 or cur[^1] != p: cur.add p
      (cx, cy) = (nx, ny)
    of 'c':
      let (ax, ay) = tx(op.x1, op.y1)
      let (bx, by) = tx(op.x2, op.y2)
      let (ex, ey) = tx(op.x3, op.y3)
      if cur.len == 0: cur.add (int(round(cx)), int(round(cy)), true)
      quadsOf(cx, cy, ax, ay, bx, by, ex, ey, tol, cur)
      (cx, cy) = (ex, ey)
    else: close()
  close()
  if cons.len == 0: return ""
  var flags, xs, ys: string
  var ends: seq[int]
  var lastX, lastY = 0
  var n = 0
  var x0, y0 = high(int)
  var x1, y1 = low(int)
  for c in cons.mitems:
    c.reverse()
    for p in c:
      x0 = min(x0, p.x); y0 = min(y0, p.y); x1 = max(x1, p.x); y1 = max(y1, p.y)
      var fl = if p.on: 1 else: 0
      let dx = p.x - lastX
      let dy = p.y - lastY
      if dx == 0: fl = fl or 0x10
      elif abs(dx) <= 255:
        fl = fl or 0x02 or (if dx > 0: 0x10 else: 0)
        xs.add char(abs(dx))
      else:
        xs.add char((dx shr 8) and 255); xs.add char(dx and 255)
      if dy == 0: fl = fl or 0x20
      elif abs(dy) <= 255:
        fl = fl or 0x04 or (if dy > 0: 0x20 else: 0)
        ys.add char(abs(dy))
      else:
        ys.add char((dy shr 8) and 255); ys.add char(dy and 255)
      flags.add char(fl)
      lastX = p.x
      lastY = p.y
      inc n
    ends.add n - 1
  proc w16(s: var string; v: int) =
    s.add char((v shr 8) and 255)
    s.add char(v and 255)
  result.w16(cons.len)
  result.w16(x0); result.w16(y0); result.w16(x1); result.w16(y1)
  for e in ends: result.w16(e)
  result.w16(0)                    # (no instructions)
  result.add flags
  result.add xs
  result.add ys
  while result.len mod 4 != 0: result.add '\0'
  bbox = (min(bbox.x0, x0), min(bbox.y0, y0), max(bbox.x1, x1), max(bbox.y1, y1))
  points = max(points, n)
  contours = max(contours, cons.len)

proc otfToTtf*(data: string; tolerance = -1.0): string =
  ## An OpenType font with CFF outlines (its bytes, beginning "OTTO") made one with TrueType
  ## outlines: each glyph's cubic curves cut into quadratic ones within `tolerance` font units
  ## of them (-1: a thousandth of an em), in new glyf and loca tables; maxp made version 1.0,
  ## head's loca long and its box the glyphs', hmtx's left side bearings the glyphs'; the CFF
  ## table left out, every other one (cmap, GSUB, GPOS, name...) as it was. "" when `data` is
  ## not such a font, or its CFF cannot be read.
  if data.len < 12 or data[0 .. 3] != "OTTO": return ""
  let n = u16(data, 4)
  if 12 + 16 * n > data.len: return ""
  var tabs: Table[string, (int, int)]
  for i in 0 ..< n:
    let r = 12 + 16 * i
    let off = u32(data, r + 8)
    let ln = u32(data, r + 12)
    if off < 0 or ln < 0 or off + ln > data.len: return ""
    tabs[data[r ..< r + 4]] = (off, ln)
  for t in ["head", "hhea", "maxp", "hmtx"]:
    if t notin tabs: return ""
  if "CFF " notin tabs and "CFF2" notin tabs: return ""
  let (co, cl) = if "CFF " in tabs: tabs["CFF "] else: tabs["CFF2"]
  let cff = parseCff(data[co ..< co + cl])
  if cff == nil: return ""
  let (ho, hl) = tabs["head"]
  if hl < 54: return ""
  let upem = max(16, u16(data, ho + 18))
  let numGlyphs = min(u16(data, tabs["maxp"][0] + 4), cff.charStrings.len)
  let tol = if tolerance > 0: tolerance else: upem / 1000
  var glyf = ""
  var loca = newString(4 * (numGlyphs + 1))
  var bbox: tuple[x0, y0, x1, y1: int] = (high(int), high(int), low(int), low(int))
  var maxPts, maxCons = 0
  var lsb = newSeq[int](numGlyphs)
  proc put32(s: var string; at, v: int) =
    for k in 0 .. 3: s[at + k] = char((v shr (24 - 8 * k)) and 255)
  proc put16(s: var string; at, v: int) =
    s[at] = char((v shr 8) and 255)
    s[at + 1] = char(v and 255)
  for g in 0 ..< numGlyphs:
    loca.put32(4 * g, glyf.len)
    var b: tuple[x0, y0, x1, y1: int] = (high(int), high(int), low(int), low(int))
    let entry = glyfOf(cff.cffGlyph(g), cff.matrix, upem, tol, b, maxPts, maxCons)
    if entry.len > 0:
      lsb[g] = b[0]
      bbox = (min(bbox[0], b[0]), min(bbox[1], b[1]), max(bbox[2], b[2]), max(bbox[3], b[3]))
    glyf.add entry
  loca.put32(4 * numGlyphs, glyf.len)
  if bbox[0] > bbox[2]: bbox = (0, 0, 0, 0)
  # head: long loca, the glyphs' box, its checksum adjustment worked out at the end
  var head = data[ho ..< ho + hl]
  head.put32(8, 0)
  head.put16(36, bbox[0]); head.put16(38, bbox[1]); head.put16(40, bbox[2]); head.put16(42, bbox[3])
  head.put16(50, 1)
  # maxp 1.0
  var maxp = newString(32)
  maxp.put32(0, 0x00010000)
  maxp.put16(4, numGlyphs)
  maxp.put16(6, min(maxPts, 65535))
  maxp.put16(8, min(maxCons, 65535))
  maxp.put16(14, 2)                     # maxZones
  # hmtx: the left side bearings the glyphs' (their advances as they were)
  let (mo, ml) = tabs["hmtx"]
  var hmtx = data[mo ..< mo + ml]
  let numH = u16(data, tabs["hhea"][0] + 34)
  for g in 0 ..< numGlyphs:
    let at = if g < numH: 4 * g + 2 else: 4 * numH + 2 * (g - numH)
    if at + 2 <= hmtx.len: hmtx.put16(at, lsb[g])
  var outTabs: seq[(string, string)]
  for tag, (off, ln) in tabs:
    if tag in ["CFF ", "CFF2", "VORG", "head", "maxp", "hmtx", "glyf", "loca", "DSIG"]: continue
    outTabs.add (tag, data[off ..< off + ln])
  outTabs.add ("head", head)
  outTabs.add ("maxp", maxp)
  outTabs.add ("hmtx", hmtx)
  outTabs.add ("glyf", glyf)
  outTabs.add ("loca", loca)
  outTabs.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))
  # the file: its directory, then the tables, each on four bytes
  let nt = outTabs.len
  var es = 0
  while (1 shl (es + 1)) <= nt: inc es
  let sr = (1 shl es) * 16
  result = newString(12 + 16 * nt)
  result.put32(0, 0x00010000)
  result.put16(4, nt)
  result.put16(6, sr)
  result.put16(8, es)
  result.put16(10, nt * 16 - sr)
  proc sum(s: string): uint32 =
    var i = 0
    while i < s.len:
      var w = 0'u32
      for k in 0 .. 3: w = (w shl 8) or (if i + k < s.len: uint32(ord(s[i + k])) else: 0'u32)
      result += w
      i += 4
  var headAt = -1
  for i, (tag, body) in outTabs:
    let r = 12 + 16 * i
    for k in 0 .. 3: result[r + k] = tag[k]
    result.put32(r + 4, int(cast[int32](sum(body))))      # (its bits: a checksum over 2^31 on 32-bit too)
    result.put32(r + 8, result.len)
    result.put32(r + 12, body.len)
    if tag == "head": headAt = result.len
    result.add body
    while result.len mod 4 != 0: result.add '\0'
  if headAt >= 0: result.put32(headAt + 8, int(cast[int32](0xB1B0AFBA'u32 - sum(result))))

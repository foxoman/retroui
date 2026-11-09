## Raw photos: DNG files (what phones and Adobe's converter make, and
## many cameras): the sensor's numbers read (uncompressed, or lossless
## JPEG), made linear (black and white levels), the color mosaic filled in
## (Malvar-He-Cutler), the camera's colors made sRGB's with its white
## balance -- as light in floating point, so exposure and white balance are
## changed before anything is cut to 8 bits (`developRaw`).
##
## ```nim
## let raw = readDng(readFile("IMG_0042.dng"))
## let img = developRaw(raw, Develop(exposure: 50))   # +0.5 stop
## ```

import std/[math, algorithm, strutils]
import photo, photofx, photodevelop, parallel

type
  RawImage* = object
    ## A raw photo as light: linear sRGB (1.0: white), 3 floats a pixel.
    w*, h*: int                 ## its size in pixels
    px*: seq[float32]           ## r, g, b of each pixel
    make*, model*: string       ## the camera's maker and model
    baseline*: float            ## the camera's exposure bias (stops), already in

  RawError* = object of CatchableError
    ## A raw file that cannot be read: damaged, or of a kind not read here.

proc fail(msg: string) {.noreturn.} = raise newException(RawError, msg)

template fptr(s: seq[float32]): ptr UncheckedArray[float32] =
  cast[ptr UncheckedArray[float32]](if s.len > 0: unsafeAddr s[0] else: nil)

# ---- TIFF directories ---------------------------------------------------------------------------------

type
  Entry = object
    tag, kind, count, at: int     ## `at`: where its values are
  Ifd = seq[Entry]
  Tiff = object
    s: string
    le: bool

proc u16(t: Tiff; at: int): int =
  if at < 0 or at + 2 > t.s.len: fail("the file ends early")
  if t.le: ord(t.s[at]) or (ord(t.s[at + 1]) shl 8) else: (ord(t.s[at]) shl 8) or ord(t.s[at + 1])

proc u32(t: Tiff; at: int): int =
  if at < 0 or at + 4 > t.s.len: fail("the file ends early")
  if t.le: ord(t.s[at]) or (ord(t.s[at + 1]) shl 8) or (ord(t.s[at + 2]) shl 16) or (ord(t.s[at + 3]) shl 24)
  else: (ord(t.s[at]) shl 24) or (ord(t.s[at + 1]) shl 16) or (ord(t.s[at + 2]) shl 8) or ord(t.s[at + 3])

proc kindSize(k: int): int =
  case k
  of 1, 2, 6, 7: 1
  of 3, 8: 2
  of 4, 9, 11: 4
  of 5, 10, 12: 8
  else: 1

proc readIfd(t: Tiff; at: int): Ifd =
  let n = t.u16(at)
  if n > 2000: fail("a damaged directory")
  for i in 0 ..< n:
    let e = at + 2 + 12 * i
    var en = Entry(tag: t.u16(e), kind: t.u16(e + 2), count: t.u32(e + 4))
    let size = kindSize(en.kind) * en.count
    en.at = if size <= 4: e + 8 else: t.u32(e + 8)
    result.add en

proc find(d: Ifd; tag: int): int =
  for i, e in d:
    if e.tag == tag: return i
  -1

proc value(t: Tiff; e: Entry; i = 0): float =
  ## Value `i` of an entry, as a number.
  let at = e.at + i * kindSize(e.kind)
  case e.kind
  of 1, 7: ord(t.s[at]).float
  of 6: float(cast[int8](t.s[at]))
  of 3: t.u16(at).float
  of 8: float(cast[int16](uint16(t.u16(at))))
  of 4: t.u32(at).float
  of 9: float(cast[int32](uint32(t.u32(at))))
  of 5:
    let d = t.u32(at + 4)
    if d == 0: 0.0 else: t.u32(at).float / d.float
  of 10:
    let n = cast[int32](uint32(t.u32(at)))
    let d = cast[int32](uint32(t.u32(at + 4)))
    if d == 0: 0.0 else: n.float / d.float
  of 11: float(cast[float32](uint32(t.u32(at))))
  else: 0.0

proc get(t: Tiff; d: Ifd; tag: int; default = 0.0; i = 0): float =
  let k = d.find(tag)
  if k < 0 or i >= d[k].count: default else: t.value(d[k], i)

proc values(t: Tiff; d: Ifd; tag: int): seq[float] =
  let k = d.find(tag)
  if k < 0: return
  for i in 0 ..< min(d[k].count, 1 shl 20): result.add t.value(d[k], i)

proc text(t: Tiff; d: Ifd; tag: int): string =
  let k = d.find(tag)
  if k < 0: return
  let e = d[k]
  if e.at + e.count <= t.s.len: t.s[e.at ..< e.at + e.count].strip(chars = {'\0', ' '}) else: ""

# ---- lossless JPEG ---------------------------------------------------------------------------------------------

type
  Huff = object
    look: array[512, int16]      ## 9 bits: symbol << 4 | length; -1 longer
    maxcode: array[18, int]
    valptr: array[17, int]
    mincode: array[17, int]
    vals: seq[uint8]

proc buildHuff(bits: array[17, int]; vals: seq[uint8]): Huff =
  result.vals = vals
  for v in result.look.mitems: v = -1
  var code = 0
  var k = 0
  for l in 1 .. 16:
    result.valptr[l] = k
    result.mincode[l] = code
    for _ in 0 ..< bits[l]:
      if l <= 9 and k < vals.len:
        let shift = 9 - l
        for f in 0 ..< (1 shl shift):
          result.look[(code shl shift) or f] = int16((int(vals[k]) shl 4) or l)
      inc code
      inc k
    result.maxcode[l] = if bits[l] > 0: code - 1 else: -1
    code = code shl 1
  result.maxcode[17] = high(int)

type BitReader = object
  s: ptr UncheckedArray[char]
  len, pos: int
  acc: uint64
  n: int

proc fill(b: var BitReader) {.inline.} =
  while b.n <= 56:
    var c = 0
    if b.pos < b.len:
      c = ord(b.s[b.pos])
      if c == 0xFF:
        let nx = if b.pos + 1 < b.len: ord(b.s[b.pos + 1]) else: 0
        if nx == 0: b.pos += 2
        else:
          c = 0                    # (a marker: no more data, zeros)
      else: inc b.pos
    b.acc = b.acc or (uint64(c) shl (56 - b.n))
    b.n += 8

proc bits(b: var BitReader; k: int): int {.inline.} =
  if k == 0: return 0
  if b.n < k: b.fill()
  result = int(b.acc shr (64 - k))
  b.acc = b.acc shl k
  b.n -= k

proc peek9(b: var BitReader): int {.inline.} =
  if b.n < 9: b.fill()
  int(b.acc shr 55)

proc decode(b: var BitReader; h: Huff): int {.inline.} =
  let p = b.peek9()
  let e = h.look[p]
  if e >= 0:
    discard b.bits(int(e) and 15)
    return int(e) shr 4
  var code = b.bits(9)
  var l = 9
  while l < 16 and code > h.maxcode[l]:
    code = (code shl 1) or b.bits(1)
    inc l
  if code > h.maxcode[l]: return 0
  let k = h.valptr[l] + code - h.mincode[l]
  if k < 0 or k >= h.vals.len: 0 else: int(h.vals[k])

proc decodeLj92*(s: string; at, len: int): tuple[w, h, comps: int; px: seq[uint16]] =
  ## A lossless JPEG (SOF3) stream: its samples, row by row, components
  ## interleaved.
  var p = at
  let stop = min(s.len, at + len)
  if p + 2 > stop or s[p] != '\xFF' or s[p + 1] != '\xD8': fail("not a lossless JPEG")
  p += 2
  var tables: array[4, Huff]
  var prec, w, h, nc = 0
  var ids: seq[int]
  var restart = 0
  proc be16(at: int): int =
    if at + 2 > stop: fail("the file ends early")
    (ord(s[at]) shl 8) or ord(s[at + 1])
  while p + 4 <= stop:
    if s[p] != '\xFF':
      inc p
      continue
    let m = ord(s[p + 1])
    if m == 0xFF:
      inc p
      continue
    let seglen = be16(p + 2)
    let body = p + 4
    case m
    of 0xC4:
      var q = body
      while q < p + 2 + seglen:
        let tc = ord(s[q]) and 15
        var bitsA: array[17, int]
        var total = 0
        for l in 1 .. 16:
          bitsA[l] = ord(s[q + l])
          total += bitsA[l]
        var vals = newSeq[uint8](total)
        for i in 0 ..< total: vals[i] = uint8(ord(s[q + 17 + i]))
        tables[tc and 3] = buildHuff(bitsA, vals)
        q += 17 + total
    of 0xC3:
      prec = ord(s[body])
      h = be16(body + 1)
      w = be16(body + 3)
      nc = ord(s[body + 5])
      for c in 0 ..< nc: ids.add ord(s[body + 6 + 3 * c])
    of 0xDD: restart = be16(body)
    of 0xDA:
      let ns = ord(s[body])
      var tsel = newSeq[int](nc)
      for c in 0 ..< ns:
        let id = ord(s[body + 1 + 2 * c])
        let k = ids.find(id)
        if k >= 0: tsel[k] = (ord(s[body + 2 + 2 * c]) shr 4) and 3
      let pred = ord(s[body + 1 + 2 * ns])
      let pt = ord(s[body + 3 + 2 * ns]) and 15
      if w <= 0 or h <= 0 or nc <= 0 or w * h * nc > 400_000_000: fail("a damaged lossless JPEG")
      var px = newSeq[uint16](w * h * nc)
      var br = BitReader(s: cast[ptr UncheckedArray[char]](unsafeAddr s[0]), len: stop, pos: p + 2 + seglen)
      let initial = 1 shl max(0, prec - pt - 1)
      let rowW = w * nc
      var mcus = 0
      for y in 0 ..< h:
        for x in 0 ..< w:
          if restart > 0 and mcus > 0 and mcus mod restart == 0:
            # (a restart: past its marker, the prediction starts again)
            br.n = 0
            br.acc = 0
            while br.pos + 1 < stop and not (s[br.pos] == '\xFF' and ord(s[br.pos + 1]) in 0xD0 .. 0xD7): inc br.pos
            br.pos += 2
          let fresh = restart > 0 and mcus mod max(1, restart) == 0 and mcus > 0
          inc mcus
          for c in 0 ..< nc:
            let t = br.decode(tables[tsel[c]])
            var diff = 0
            if t == 16: diff = 32768
            elif t > 0:
              diff = br.bits(t)
              if diff < (1 shl (t - 1)): diff -= (1 shl t) - 1
            let i = y * rowW + x * nc + c
            var pv: int
            if (y == 0 and x == 0) or fresh: pv = initial
            elif y == 0: pv = int(px[i - nc])
            elif x == 0: pv = int(px[i - rowW])
            else:
              let ra = int(px[i - nc])
              let rb = int(px[i - rowW])
              let rc = int(px[i - rowW - nc])
              pv = case pred
                   of 1: ra
                   of 2: rb
                   of 3: rc
                   of 4: ra + rb - rc
                   of 5: ra + ((rb - rc) shr 1)
                   of 6: rb + ((ra - rc) shr 1)
                   of 7: (ra + rb) shr 1
                   else: ra
            px[i] = uint16((pv + diff) and 0xFFFF)
      return (w, h, nc, px)
    of 0xD9: break
    else: discard
    p += 2 + seglen
  fail("a lossless JPEG with no picture")

proc encodeLj92*(px: seq[uint16]; w, h: int; prec = 16): string =
  ## A lossless JPEG of one component (predictor 1): for tests, and DNGs we
  ## write.
  # the differences' sizes, and a Huffman table for them (lengths by count)
  var diffs = newSeq[int](w * h)
  var counts: array[17, int]
  for y in 0 ..< h:
    for x in 0 ..< w:
      let i = y * w + x
      let pv = if x == 0 and y == 0: 1 shl (prec - 1)
               elif y == 0 or x > 0: int(px[i - 1])
               else: int(px[i - w])
      var d = (int(px[i]) - pv) and 0xFFFF
      if d >= 32768: d -= 65536
      diffs[i] = d
      var t = 0
      var a = abs(d)
      while a > 0:
        inc t
        a = a shr 1
      if d == -32768: t = 16
      inc counts[t]
  # (a simple length for each size used: in order of how common, from 2)
  var syms: seq[int]
  for t in 0 .. 16:
    if counts[t] > 0: syms.add t
  syms.sort(proc (a, b: int): int = cmp(counts[b], counts[a]))
  var lens: array[17, int]
  for k, t in syms: lens[t] = min(16, k + 1 + (if syms.len == 1: 0 else: 0))
  if syms.len == 1: lens[syms[0]] = 1
  var bitsA: array[17, int]
  var order: seq[int]
  for l in 1 .. 16:
    for t in syms:
      if lens[t] == l:
        inc bitsA[l]
        order.add t
  var codes: array[17, (int, int)]
  var code = 0
  var k = 0
  for l in 1 .. 16:
    for _ in 0 ..< bitsA[l]:
      codes[order[k]] = (code, l)
      inc code
      inc k
    code = code shl 1
  var o = "\xFF\xD8"
  proc w16(v: int) = (o.add char((v shr 8) and 255); o.add char(v and 255))
  o.add "\xFF\xC4"
  w16(2 + 1 + 16 + order.len)
  o.add '\0'
  for l in 1 .. 16: o.add char(bitsA[l])
  for t in order: o.add char(t)
  o.add "\xFF\xC3"
  w16(11)
  o.add char(prec)
  w16(h); w16(w)
  o.add '\1'
  o.add "\1\x11\0"
  o.add "\xFF\xDA"
  w16(8)
  o.add '\1'
  o.add "\1\0"
  o.add '\1'                    # predictor 1
  o.add '\0'
  o.add '\0'
  var acc = 0'u64
  var n = 0
  proc put(v, l: int) =
    acc = (acc shl l) or uint64(v and ((1 shl l) - 1))
    n += l
    while n >= 8:
      let c = int((acc shr (n - 8)) and 255)
      o.add char(c)
      if c == 0xFF: o.add '\0'
      n -= 8
  for d in diffs:
    var t = 0
    var a = abs(d)
    while a > 0:
      inc t
      a = a shr 1
    if d == -32768: t = 16
    put(codes[t][0], codes[t][1])
    if t > 0 and t < 16:
      put(if d < 0: d + (1 shl t) - 1 else: d, t)
  if n > 0: put(0x7F, 8 - n)
  o.add "\xFF\xD9"
  o

# ---- the sensor's numbers -----------------------------------------------------------------------------------

proc unpackBits(s: string; at, count, bps: int; le16: bool): seq[uint16] =
  ## Samples of `bps` bits packed most significant bit first (16: two bytes
  ## in the file's order).
  result = newSeq[uint16](count)
  if bps == 16:
    if at + 2 * count > s.len: fail("the file ends early")
    for i in 0 ..< count:
      let a = ord(s[at + 2 * i])
      let b = ord(s[at + 2 * i + 1])
      result[i] = uint16(if le16: a or (b shl 8) else: (a shl 8) or b)
  elif bps == 8:
    if at + count > s.len: fail("the file ends early")
    for i in 0 ..< count: result[i] = uint16(ord(s[at + i]))
  else:
    var acc = 0'u64
    var n = 0
    var p = at
    for i in 0 ..< count:
      while n < bps:
        if p >= s.len: fail("the file ends early")
        acc = (acc shl 8) or uint64(ord(s[p]))
        inc p
        n += 8
      result[i] = uint16((acc shr (n - bps)) and ((1'u64 shl bps) - 1))
      n -= bps

proc rawSamples(t: Tiff; d: Ifd; w, h, spp: int): seq[uint16] =
  ## The raw IFD's samples, `w` x `h` x `spp`.
  result = newSeq[uint16](w * h * spp)
  let comp = int(t.get(d, 259, 1))
  let bps = int(t.get(d, 258, 16))
  let tw = int(t.get(d, 322, 0))
  let th = int(t.get(d, 323, 0))
  if tw > 0 and th > 0:
    let offs = t.values(d, 324)
    let cnts = t.values(d, 325)
    let across = (w + tw - 1) div tw
    for k in 0 ..< offs.len:
      let tx = (k mod across) * tw
      let ty = (k div across) * th
      var tile: seq[uint16]
      var tileW = tw
      if comp == 7:
        let j = decodeLj92(t.s, int(offs[k]), int(cnts[k]))
        tile = j.px
        tileW = j.w * j.comps div spp
      elif comp == 1:
        tile = unpackBits(t.s, int(offs[k]), tw * th * spp, bps, t.le)
      else: fail("a raw compression we do not read (" & $comp & ")")
      let rows = tile.len div max(1, tileW * spp)
      for y in 0 ..< min(th, rows):
        if ty + y >= h: break
        for x in 0 ..< tileW:
          if tx + x >= w: break
          for c in 0 ..< spp:
            result[((ty + y) * w + tx + x) * spp + c] = tile[(y * tileW + x) * spp + c]
  else:
    let offs = t.values(d, 273)
    let cnts = t.values(d, 279)
    let rps = int(t.get(d, 278, h.float))
    var y0 = 0
    for k in 0 ..< offs.len:
      let rows = min(rps, h - y0)
      if rows <= 0: break
      var strip: seq[uint16]
      if comp == 7:
        let j = decodeLj92(t.s, int(offs[k]), int(cnts[k]))
        strip = j.px
      elif comp == 1:
        strip = unpackBits(t.s, int(offs[k]), rows * w * spp, bps, t.le)
      else: fail("a raw compression we do not read (" & $comp & ")")
      let n = min(strip.len, rows * w * spp)
      for i in 0 ..< n: result[y0 * w * spp + i] = strip[i]
      y0 += rows

# ---- the color mosaic filled in -------------------------------------------------------------------------------

proc demosaic*(m: seq[float32]; w, h: int; cfa: array[4, int]): seq[float32] =
  ## The two colors each pixel lacks, from its neighbors (Malvar, He and
  ## Cutler's gradient-corrected linear interpolation): `m` is the 2 x 2
  ## mosaic made linear, `cfa` its colors (0 red, 1 green, 2 blue) from the
  ## top left; 3 floats a pixel back.
  result = newSeq[float32](w * h * 3)
  let mp = fptr(m)
  let rp = fptr(result)
  template X(x, y: int): float32 = mp[clamp(y, 0, h - 1) * w + clamp(x, 0, w - 1)]
  parallelRows(h, y):
    for x in 0 ..< w:
      let c = cfa[(y and 1) * 2 + (x and 1)]
      let v = X(x, y)
      var r, g, b: float32
      if c == 1:
        g = v
        # (which color is beside it across: the other is above and below)
        let across = cfa[(y and 1) * 2 + ((x + 1) and 1)]
        let horiz = (5 * v + 4 * (X(x - 1, y) + X(x + 1, y)) - X(x - 2, y) - X(x + 2, y) -
                     (X(x - 1, y - 1) + X(x + 1, y - 1) + X(x - 1, y + 1) + X(x + 1, y + 1)) +
                     0.5'f32 * (X(x, y - 2) + X(x, y + 2))) / 8
        let vert = (5 * v + 4 * (X(x, y - 1) + X(x, y + 1)) - X(x, y - 2) - X(x, y + 2) -
                    (X(x - 1, y - 1) + X(x + 1, y - 1) + X(x - 1, y + 1) + X(x + 1, y + 1)) +
                    0.5'f32 * (X(x - 2, y) + X(x + 2, y))) / 8
        if across == 0:
          r = horiz
          b = vert
        else:
          b = horiz
          r = vert
      else:
        g = (4 * v + 2 * (X(x - 1, y) + X(x + 1, y) + X(x, y - 1) + X(x, y + 1)) -
             (X(x - 2, y) + X(x + 2, y) + X(x, y - 2) + X(x, y + 2))) / 8
        let other = (6 * v + 2 * (X(x - 1, y - 1) + X(x + 1, y - 1) + X(x - 1, y + 1) + X(x + 1, y + 1)) -
                     1.5'f32 * (X(x - 2, y) + X(x + 2, y) + X(x, y - 2) + X(x, y + 2))) / 8
        if c == 0:
          r = v
          b = other
        else:
          b = v
          r = other
      let i = (y * w + x) * 3
      rp[i] = max(0'f32, r)
      rp[i + 1] = max(0'f32, g)
      rp[i + 2] = max(0'f32, b)

# ---- DNG -------------------------------------------------------------------------------------------------

proc inv3*(m: array[9, float]): array[9, float] =
  ## The inverse of a 3 x 3 matrix (row by row); the identity when it has none.
  let (a, b, c, d, e, f, g, h, i) = (m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8])
  let A = e * i - f * h
  let B = -(d * i - f * g)
  let C = d * h - e * g
  let det = a * A + b * B + c * C
  if abs(det) < 1e-12: return [1.0, 0, 0, 0, 1, 0, 0, 0, 1]
  let k = 1 / det
  [A * k, -(b * i - c * h) * k, (b * f - c * e) * k, B * k, (a * i - c * g) * k, -(a * f - c * d) * k,
   C * k, -(a * h - b * g) * k, (a * e - b * d) * k]

proc readDng*(data: string): RawImage =
  ## A DNG's raw picture as light (see `RawImage`). Raises `RawError`
  ## when it is not one we read.
  if data.len < 16 or data[0 .. 1] notin ["II", "MM"]: fail("not a DNG file")
  let t = Tiff(s: data, le: data[0] == 'I')
  if t.u16(2) != 42: fail("not a DNG file")
  let ifd0 = t.readIfd(t.u32(4))
  if ifd0.find(50706) < 0: fail("not a DNG file (a TIFF)")
  result.make = t.text(ifd0, 271)
  result.model = t.text(ifd0, 272)
  # the raw picture: the main image that is a mosaic or linear raw
  var dirs = @[ifd0]
  for off in t.values(ifd0, 330):
    try: dirs.add t.readIfd(int(off))
    except RawError: discard
  var raw: Ifd
  var found = false
  for d in dirs:
    let pi = int(t.get(d, 262, 0))
    if int(t.get(d, 254, 0)) == 0 and pi in [32803, 34892]:
      raw = d
      found = true
      break
  if not found: fail("a DNG without its raw picture")
  let w = int(t.get(raw, 256, 0))
  let h = int(t.get(raw, 257, 0))
  let spp = int(t.get(raw, 277, 1))
  let mosaic = int(t.get(raw, 262, 0)) == 32803
  if w <= 0 or h <= 0 or w * h > 200_000_000 or spp notin [1, 3]: fail("a raw picture of a size we do not read")
  if mosaic and spp != 1: fail("a mosaic of several samples")
  var cfa = [0, 1, 1, 2]
  if mosaic:
    let dim = t.values(raw, 33421)
    let pat = t.values(raw, 33422)
    if dim.len == 2 and (dim[0] != 2 or dim[1] != 2): fail("a color mosaic other than 2 x 2 (X-Trans)")
    if pat.len >= 4:
      for k in 0 .. 3: cfa[k] = int(pat[k])
    for c in cfa:
      if c notin 0 .. 2: fail("a color mosaic of other colors")
  let samples = rawSamples(t, raw, w, h, spp)
  # linear: the table, the black and white levels
  let lin = t.values(raw, 50712)
  var black = t.values(raw, 50714)
  if black.len == 0: black = @[0.0]
  let bdim = t.values(raw, 50713)
  let bw = if bdim.len == 2: max(1, int(bdim[1])) else: 1
  let bh = if bdim.len == 2: max(1, int(bdim[0])) else: 1
  let white = t.get(raw, 50717, float((1 shl int(t.get(raw, 258, 16))) - 1))
  let area = t.values(raw, 50829)
  let (ay, ax, ay1, ax1) = if area.len == 4: (int(area[0]), int(area[1]), int(area[2]), int(area[3]))
                           else: (0, 0, h, w)
  let crop0 = t.values(raw, 50719)
  let cropS = t.values(raw, 50720)
  var cx = ax
  var cy = ay
  var cw = ax1 - ax
  var ch = ay1 - ay
  if crop0.len == 2 and cropS.len == 2:
    cx = ax + int(crop0[0])
    cy = ay + int(crop0[1])
    cw = int(cropS[0])
    ch = int(cropS[1])
  # (a mosaic: the crop on an even pixel, so the pattern stays)
  if mosaic:
    let sx = cx and 1
    let sy = cy and 1
    if sx == 1 or sy == 1:
      let c0 = cfa
      for yy in 0 .. 1:
        for xx in 0 .. 1: cfa[yy * 2 + xx] = c0[((yy + sy) and 1) * 2 + ((xx + sx) and 1)]
  cw = clamp(cw, 1, w - cx)
  ch = clamp(ch, 1, h - cy)
  var linv = newSeq[float32](cw * ch * spp)
  for y in 0 ..< ch:
    for x in 0 ..< cw:
      for c in 0 ..< spp:
        var v = int(samples[((cy + y) * w + cx + x) * spp + c]).float
        if lin.len > 0: v = lin[clamp(int(v), 0, lin.high)]
        let rep = ((cy + y) mod bh) * bw + ((cx + x) mod bw)
        let bl = if black.len >= bw * bh * spp: black[rep * spp + c]
                 elif black.len >= bw * bh: black[rep]
                 elif black.len >= spp: black[c]
                 else: black[0]
        linv[(y * cw + x) * spp + c] = float32(max(0.0, (v - bl) / max(1.0, white - bl)))
  # the mosaic filled in
  var rgb = if mosaic: demosaic(linv, cw, ch, cfa) else: linv
  # white balance and the camera's colors made sRGB's (dcraw's way)
  var neutral = t.values(ifd0, 50728)
  if neutral.len < 3 or neutral[0] <= 0 or neutral[1] <= 0 or neutral[2] <= 0: neutral = @[1.0, 1.0, 1.0]
  var mul = [1 / neutral[0], 1 / neutral[1], 1 / neutral[2]]
  let mg = mul[1]
  for m in mul.mitems: m /= mg
  let cm1 = t.values(ifd0, 50721)
  let cm2 = t.values(ifd0, 50722)
  let il1 = int(t.get(ifd0, 50778, 0))
  let il2 = int(t.get(ifd0, 50779, 0))
  let cm = if cm2.len == 9 and (il2 == 21 or il1 != 21): cm2 elif cm1.len == 9: cm1 else: @[]
  var rgbCam = [1.0, 0, 0, 0, 1, 0, 0, 0, 1]
  if cm.len == 9:
    const xyzRgb = [0.412453, 0.357580, 0.180423, 0.212671, 0.715160, 0.072169, 0.019334, 0.119193, 0.950227]
    var camRgb: array[9, float]
    for r in 0 .. 2:
      for c in 0 .. 2:
        camRgb[r * 3 + c] = cm[r * 3] * xyzRgb[c] + cm[r * 3 + 1] * xyzRgb[3 + c] + cm[r * 3 + 2] * xyzRgb[6 + c]
    for r in 0 .. 2:
      let s = camRgb[r * 3] + camRgb[r * 3 + 1] + camRgb[r * 3 + 2]
      if abs(s) > 1e-9:
        for c in 0 .. 2: camRgb[r * 3 + c] /= s
    rgbCam = inv3(camRgb)
  result.baseline = t.get(ifd0, 50730, 0)
  let gain = float32(pow(2.0, result.baseline))
  let rp = fptr(rgb)
  let m = rgbCam
  let mu = mul
  parallelChunks(cw * ch, lo, hi):
    for i in lo ..< hi:
      # (white balanced, cut where the sensor was full: no colored highlights)
      let r = min(1.0, rp[3 * i].float * mu[0])
      let g = min(1.0, rp[3 * i + 1].float * mu[1])
      let b = min(1.0, rp[3 * i + 2].float * mu[2])
      rp[3 * i] = max(0'f32, float32(m[0] * r + m[1] * g + m[2] * b) * gain)
      rp[3 * i + 1] = max(0'f32, float32(m[3] * r + m[4] * g + m[5] * b) * gain)
      rp[3 * i + 2] = max(0'f32, float32(m[6] * r + m[7] * g + m[8] * b) * gain)
  # turned as the camera was held
  let orient = int(t.get(ifd0, 274, 1))
  var ow = cw
  var oh = ch
  if orient in [3, 6, 8]:
    if orient != 3: swap(ow, oh)
    var o = newSeq[float32](ow * oh * 3)
    for y in 0 ..< ch:
      for x in 0 ..< cw:
        let (nx, ny) = case orient
                       of 3: (cw - 1 - x, ch - 1 - y)
                       of 6: (ch - 1 - y, x)
                       else: (y, cw - 1 - x)
        for c in 0 .. 2: o[(ny * ow + nx) * 3 + c] = rgb[(y * cw + x) * 3 + c]
    rgb = o
  result.w = ow
  result.h = oh
  result.px = rgb

proc isDng*(data: string): bool =
  ## The bytes are a DNG (a TIFF with a DNG version).
  try:
    if data.len < 16 or data[0 .. 1] notin ["II", "MM"]: return false
    let t = Tiff(s: data, le: data[0] == 'I')
    t.readIfd(t.u32(4)).find(50706) >= 0
  except CatchableError: false

var cameraRawReader*: proc (data: string): RawImage {.nimcall.}
  ## What reads the raws of cameras' own kinds (NEF, ARW, CR2, ...):
  ## set by retroui/rawformats when it is part of the program.

proc readRaw*(data: string): RawImage =
  ## Any raw photo we read, as light (see `RawImage`): a DNG (`readDng`),
  ## or -- with retroui/rawformats imported anywhere in the program -- a
  ## camera's own raw. Raises `RawError` when it is neither.
  if isDng(data): return readDng(data)
  if cameraRawReader != nil: return cameraRawReader(data)
  fail("not a raw photo we read (a camera's own raws: import retroui/rawformats)")

proc smaller*(r: RawImage; maxSide: int): RawImage =
  ## The raw picture made smaller (averaged): for previews.
  let k = min(1.0, maxSide / max(1, max(r.w, r.h)))
  let w = max(1, int(r.w.float * k))
  let h = max(1, int(r.h.float * k))
  result = RawImage(w: w, h: h, px: newSeq[float32](w * h * 3), make: r.make, model: r.model, baseline: r.baseline)
  let sp = fptr(r.px)
  let dp = fptr(result.px)
  let rw = r.w
  let rh = r.h
  parallelRows(h, y):
    let y0 = y * rh div h
    let y1 = max(y0 + 1, (y + 1) * rh div h)
    for x in 0 ..< w:
      let x0 = x * rw div w
      let x1 = max(x0 + 1, (x + 1) * rw div w)
      var acc: array[3, float32]
      for yy in y0 ..< y1:
        for xx in x0 ..< x1:
          for c in 0 .. 2: acc[c] += sp[(yy * rw + xx) * 3 + c]
      let n = float32((y1 - y0) * (x1 - x0))
      for c in 0 .. 2: dp[(y * w + x) * 3 + c] = acc[c] / n

proc crop*(r: RawImage; x, y, w, h: int): RawImage =
  ## The part `x`, `y`, `w` x `h` of the image (edge pixels repeated
  ## outside it).
  result = RawImage(w: w, h: h, px: newSeq[float32](w * h * 3), make: r.make, model: r.model)
  for yy in 0 ..< h:
    for xx in 0 ..< w:
      let sx = clamp(x + xx, 0, r.w - 1)
      let sy = clamp(y + yy, 0, r.h - 1)
      for c in 0 .. 2: result.px[(yy * w + xx) * 3 + c] = r.px[(sy * r.w + sx) * 3 + c]

# ---- developed: light to pixels ---------------------------------------------------------------------------------

proc floatPart*(s: Develop): Develop =
  ## The settings done on the light itself: white balance and exposure.
  Develop(temperature: s.temperature, tint: s.tint, exposure: s.exposure)

proc pixelPart*(s: Develop): Develop =
  ## The rest (done on the pixels after).
  result = s
  result.temperature = 0
  result.tint = 0
  result.exposure = 0

proc developRaw*(r: RawImage; s: Develop): Img =
  ## The raw picture made pixels: its white balance and exposure changed in
  ## the light (nothing lost to 8 bits yet), the highlights rolled off
  ## gently, a camera's tone curve, sRGB. (The other settings of `s`:
  ## `developImg` after, with `pixelPart`.)
  result = newImg(r.w, r.h)
  let t = s.temperature.float / 100
  let u = s.tint.float / 100
  let e = pow(2.0, s.exposure.float / 100)
  let kr = float32(e * (1 + 0.35 * t) * (1 + 0.1 * u))
  let kg = float32(e * (1 - 0.22 * u))
  let kb = float32(e * (1 - 0.35 * t) * (1 + 0.1 * u))
  # the curve, as a table of 4096 steps of light (the highlights are rolled
  # off before it, beyond 1: white)
  var curve = newSeq[uint8](16385)
  for i in 0 .. 16384:
    let x = min(1.0, i.float / 4096)
    var y = if x <= 0.0031308: 12.92 * x else: 1.055 * pow(x, 1 / 2.4) - 0.055
    # a camera's mild S
    let sm = y * y * (3 - 2 * y)
    y = y + (sm - y) * 0.22
    curve[i] = uint8(clamp(int(y * 255 + 0.5), 0, 255))
  let sp = fptr(r.px)
  let dp = cast[ptr UncheckedArray[uint32]](addr result.px[0])
  let cp = cast[ptr UncheckedArray[uint8]](addr curve[0])
  parallelChunks(r.w * r.h, lo, hi):
    for i in lo ..< hi:
      var rr = sp[3 * i] * kr
      var gg = sp[3 * i + 1] * kg
      var bb = sp[3 * i + 2] * kb
      # (the brightest of the three rolled off, the others with it: the hue kept)
      let m = max(rr, max(gg, bb))
      if m > 0.8'f32:
        let x = m.float
        let k = float32((0.8 + 0.2 * (1 - exp(-(x - 0.8) / 0.2))) / x)
        rr *= k; gg *= k; bb *= k
      let ri = clamp(int(rr * 4096), 0, 16384)
      let gi = clamp(int(gg * 4096), 0, 16384)
      let bi = clamp(int(bb * 4096), 0, 16384)
      dp[i] = 0xFF000000'u32 or (uint32(cp[ri]) shl 16) or (uint32(cp[gi]) shl 8) or uint32(cp[bi])

proc docOfRaw*(r: RawImage; name = "Untitled"; s = Develop()): Doc =
  ## A document of the raw picture developed with `s`.
  let im = developRaw(r, s.floatPart)
  result = newDoc(r.w, r.h, 0, 300, name)
  result.layers[0].px = im.px
  inc result.layers[0].ver
  let rest = s.pixelPart
  if not rest.isNeutral:
    let L = result.layers[0]
    let base = developBase(smallCopy(Img(w: r.w, h: r.h, px: L.px), 400), rest, r.w, r.h)
    L.px = developImg(Img(w: r.w, h: r.h, px: L.px), rest, base).px
  result.markAll()
  result.modified = false

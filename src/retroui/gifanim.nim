## Animated GIFs written and read back: `encodeGifFrames` makes one from
## whole frames -- each frame given its own palette when that is better
## than the file's, transparency kept, and of each frame only the part that
## changed written (what stays the same left showing through); `gifFrames`
## reads one as whole frames with the delays the file gives.
##
## ```nim
## var frames: seq[tuple[px: seq[uint32]; delayMs: int]]
## for k in 0 ..< 30: frames.add (drawFrame(k).px, 40)     # 0xAARRGGBB, w * h each
## writeFile("spin.gif", encodeGifFrames(320, 240, frames, loop = 0))
## for f in gifFrames(readFile("spin.gif")): echo f.bmp.w, " x ", f.bmp.h, ", ", f.delayMs, " ms"
## ```
##
## A pixel less than half opaque is transparent (GIF has no partial
## alpha). Frames are put on the canvas the way browsers and Pillow do it:
## a frame that leaves pixels transparent which were not is followed by
## clearing (disposal 2); otherwise frames stay (disposal 1).

import std/math
import gfx, imageformats, mediagif, parallel

type Rect4 = object
  x0, y0, x1, y1: int          # x1, y1 past the end; empty when x1 <= x0

proc empty(r: Rect4): bool {.inline.} = r.x1 <= r.x0 or r.y1 <= r.y0

proc grow(r: var Rect4; o: Rect4) =
  if o.empty: return
  if r.empty:
    r = o
    return
  r.x0 = min(r.x0, o.x0); r.y0 = min(r.y0, o.y0)
  r.x1 = max(r.x1, o.x1); r.y1 = max(r.y1, o.y1)

proc grow(r: var Rect4; x, y: int) {.inline.} =
  if r.empty: r = Rect4(x0: x, y0: y, x1: x + 1, y1: y + 1)
  else:
    if x < r.x0: r.x0 = x
    if x >= r.x1: r.x1 = x + 1
    if y < r.y0: r.y0 = y
    if y >= r.y1: r.y1 = y + 1

proc shown(p: uint32): uint32 {.inline.} =
  ## The pixel as a GIF shows it: opaque, or transparent (0).
  if p >= 0x80000000'u32: p or 0xFF000000'u32 else: 0

proc dist(a, b: uint32): int {.inline.} =
  ## How far apart two colors look (as `quantize` weighs them).
  let dr = int((a shr 16) and 255) - int((b shr 16) and 255)
  let dg = int((a shr 8) and 255) - int((b shr 8) and 255)
  let db = int(a and 255) - int(b and 255)
  3 * dr * dr + 4 * dg * dg + 2 * db * db

# ---- the nearest color of a palette, remembered --------------------------------------------------------------

type Nearest = object
  pal: seq[uint32]
  first: int                    # (entries before it: the transparent one)
  key: seq[uint32]              # color + 1 (0: nothing kept here)
  val: seq[uint8]

proc initNearest(pal: seq[uint32]; first: int): Nearest =
  Nearest(pal: pal, first: first, key: newSeq[uint32](1 shl 16), val: newSeq[uint8](1 shl 16))

proc find(n: var Nearest; c: uint32): int =
  let rgb = c and 0xFFFFFF'u32
  let h = int(((rgb * 2654435761'u32) shr 16) and 0xFFFF)
  if n.key[h] == rgb + 1: return int(n.val[h])
  var best = high(int)
  result = n.first
  for k in n.first ..< n.pal.len:
    let d = dist(n.pal[k], rgb)
    if d < best:
      best = d
      result = k
      if d == 0: break
  n.key[h] = rgb + 1
  n.val[h] = uint8(result)

# ---- a set of up to 256 colors ----------------------------------------------------------------------------

type ColorSet = object
  slot: array[1024, uint32]     # color + 1 (the colors are opaque: never 0xFFFFFFFF + 1)
  at: array[1024, int16]        # its place in the list
  list: seq[uint32]
  over: bool                    # more than 256

proc incl(s: var ColorSet; c: uint32) {.inline.} =
  if s.over: return
  var h = int(((c * 2654435761'u32) shr 22) and 1023)
  while true:
    if s.slot[h] == c + 1: return
    if s.slot[h] == 0: break
    h = (h + 1) and 1023
  if s.list.len >= 256:
    s.over = true
    return
  s.slot[h] = c + 1
  s.at[h] = int16(s.list.len)
  s.list.add c

proc has(s: ColorSet; c: uint32): int {.inline.} =
  ## Where `c` is in the list, or -1.
  var h = int(((c * 2654435761'u32) shr 22) and 1023)
  while s.slot[h] != 0:
    if s.slot[h] == c + 1: return int(s.at[h])
    h = (h + 1) and 1023
  -1

# ---- a palette for a frame (median cut on a sample) ----------------------------------------------------

proc medianCut(sample: var seq[uint32]; colors: int): seq[uint32] =
  ## Up to `colors` colors standing for `sample` (opaque): the box of the
  ## most varied colors split at its median, again and again. (As
  ## `quantize` makes them, without its table of every color's nearest:
  ## a frame's palette made in a moment.)
  type Box = tuple[a, b, ch: int; score: float]
  proc measure(s: seq[uint32]; a, b: int): Box =
    var lo = [255, 255, 255]
    var hi = [0, 0, 0]
    for k in a ..< b:
      let c = s[k]
      for ch in 0 .. 2:
        let v = int((c shr (16 - 8 * ch)) and 255)
        if v < lo[ch]: lo[ch] = v
        if v > hi[ch]: hi[ch] = v
    var ch = 0
    for c in 1 .. 2:
      if hi[c] - lo[c] > hi[ch] - lo[ch]: ch = c
    (a, b, ch, float(hi[ch] - lo[ch]) * sqrt(float(b - a)))
  proc chan(c: uint32; ch: int): int {.inline.} = int((c shr (16 - 8 * ch)) and 255)
  proc select(s: var seq[uint32]; a, b, k, ch: int) =
    ## (`s[a ..< b]` partly sorted by channel `ch`: the `k`th in place, smaller before it)
    var lo = a
    var hi = b - 1
    while lo < hi:
      let pivot = chan(s[(lo + hi) div 2], ch)
      var i = lo
      var j = hi
      while i <= j:
        while chan(s[i], ch) < pivot: inc i
        while chan(s[j], ch) > pivot: dec j
        if i <= j:
          swap(s[i], s[j])
          inc i
          dec j
      if k <= j: hi = j
      elif k >= i: lo = i
      else: break
  var boxes: seq[Box] = @[measure(sample, 0, sample.len)]
  while boxes.len < colors:
    var bi = -1
    var best = 0.0
    for k, bx in boxes:
      if bx.b - bx.a >= 2 and bx.score > best:
        best = bx.score
        bi = k
    if bi < 0: break
    let bx = boxes[bi]
    let mid = (bx.a + bx.b) div 2
    select(sample, bx.a, bx.b, mid, bx.ch)
    boxes[bi] = measure(sample, bx.a, mid)
    boxes.add measure(sample, mid, bx.b)
  for bx in boxes:
    if bx.b <= bx.a: continue
    var sr, sg, sb = 0
    for k in bx.a ..< bx.b:
      let c = sample[k]
      sr += int((c shr 16) and 255); sg += int((c shr 8) and 255); sb += int(c and 255)
    let m = bx.b - bx.a
    result.add 0xFF000000'u32 or (uint32(sr div m) shl 16) or (uint32(sg div m) shl 8) or uint32(sb div m)

# ---- LZW ------------------------------------------------------------------------------------------------

proc lzwData(o: var string; idx: openArray[uint8]; minCode: int) =
  ## The image data: the LZW code size, then the codes (least significant
  ## bits first) in blocks of up to 255 bytes, then an empty block.
  o.add char(minCode)
  let clear = 1 shl minCode
  let eoi = clear + 1
  var width = minCode + 1
  var next = eoi + 1
  var acc = 0'u64
  var nbits = 0
  var data = newStringOfCap(idx.len div 2 + 16)
  const HBits = 13
  var hkey = newSeq[int32](1 shl HBits)      # (prefix, byte) + 1: 0 is empty
  var hval = newSeq[int16](1 shl HBits)
  template emit(code: int) =
    acc = acc or (uint64(code) shl nbits)
    nbits += width
    while nbits >= 8:
      data.add char(acc and 255)
      acc = acc shr 8
      nbits -= 8
  emit(clear)
  if idx.len > 0:
    var cur = int(idx[0])
    for i in 1 ..< idx.len:
      let b = int(idx[i])
      let key = int32((cur shl 8) or b) + 1
      var s = int((uint32(key) * 2654435761'u32) shr (32 - HBits))
      while hkey[s] != 0 and hkey[s] != key: s = (s + 1) and ((1 shl HBits) - 1)
      if hkey[s] != 0:
        cur = int(hval[s])
        continue
      emit(cur)
      if next < 4096:
        hkey[s] = key
        hval[s] = int16(next)
        inc next
        if next > (1 shl width) and width < 12: inc width
      else:
        emit(clear)
        for x in hkey.mitems: x = 0
        next = eoi + 1
        width = minCode + 1
      cur = b
    emit(cur)
    if next >= (1 shl width) and width < 12: inc width
  emit(eoi)
  if nbits > 0: data.add char(acc and 255)
  var at = 0
  while at < data.len:
    let k = min(255, data.len - at)
    o.add char(k)
    o.add data[at ..< at + k]
    at += k
  o.add '\0'

proc colorTable(o: var string; pal: seq[uint32]; bits: int) =
  for k in 0 ..< (1 shl bits):
    let c = if k < pal.len: pal[k] else: 0'u32
    o.add char((c shr 16) and 255); o.add char((c shr 8) and 255); o.add char(c and 255)

proc bitsFor(n: int): int =
  result = 1
  while (1 shl result) < n: inc result

# ---- writing --------------------------------------------------------------------------------------------

type Plan = object
  rect: Rect4
  disposal: int                 # 1 stays, 2 cleared after
  needClear: bool               # some pixel transparent in it (or left as it was)
  colors: ColorSet              # the colors drawn (up to 256)
  sample: seq[uint32]           # some of them (for the file's palette)

proc encodeGifFrames*(w, h: int; frames: openArray[tuple[px: seq[uint32]; delayMs: int]];
                      loop = 0; dither = true): string =
  ## An animated GIF of `frames` (each `w * h` pixels, 0xAARRGGBB) shown for
  ## `delayMs` each (kept to hundredths of a second). `loop`: how many times
  ## it repeats (0 for ever; less than 0: played once, no loop block). Each
  ## frame is written as the rectangle that changed, with the file's
  ## palette or, when that is better, one of its own; colors beyond 256 are
  ## brought down (`dither`: with error diffusion). Raises `ValueError` for
  ## no frames, a bad size or a frame of the wrong length.
  if frames.len == 0: raise newException(ValueError, "GIF: no frames")
  if w < 1 or h < 1 or w > 65535 or h > 65535: raise newException(ValueError, "GIF: bad size")
  for f in frames:
    if f.px.len != w * h: raise newException(ValueError, "GIF: a frame of the wrong size")
  let n = frames.len
  let fp = cast[ptr UncheckedArray[tuple[px: seq[uint32]; delayMs: int]]](unsafeAddr frames[0])
  var plans = newSeq[Plan](n)
  let pp = cast[ptr UncheckedArray[Plan]](addr plans[0])
  var clearOf = newSeq[Rect4](n)     # pixels opaque before, transparent in this frame
  var anyClear = newSeq[bool](n)     # some transparent pixel in it
  # what changed from each frame to the next (all frames at once)
  parallelFor(n, proc (lo, hi: int) =
    for k in lo ..< hi:
      let a = cast[ptr UncheckedArray[uint32]](unsafeAddr fp[k].px[0])
      var changed, cleared: Rect4
      var clear = false
      if k == 0:
        changed = Rect4(x0: 0, y0: 0, x1: w, y1: h)
        for i in 0 ..< w * h:
          if a[i] < 0x80000000'u32:
            clear = true
            break
      else:
        let b = cast[ptr UncheckedArray[uint32]](unsafeAddr fp[k - 1].px[0])
        for y in 0 ..< h:
          for x in 0 ..< w:
            let i = y * w + x
            let s = shown(a[i])
            if s == 0: clear = true
            if s != shown(b[i]):
              changed.grow(x, y)
              if s == 0: cleared.grow(x, y)
      pp[k].rect = changed
      clearOf[k] = cleared
      anyClear[k] = clear
  )
  # a frame followed by pixels becoming transparent is cleared after (disposal 2)
  for k in 0 ..< n:
    plans[k].disposal = 1
    if k + 1 < n and not clearOf[k + 1].empty:
      plans[k].disposal = 2
      plans[k].rect.grow(clearOf[k + 1])
  # what a cleared frame took away is drawn again by the next
  for k in 1 ..< n:
    if plans[k - 1].disposal == 2:
      let r = plans[k - 1].rect
      let a = frames[k].px
      for y in r.y0 ..< r.y1:
        for x in r.x0 ..< r.x1:
          if a[y * w + x] >= 0x80000000'u32: plans[k].rect.grow(x, y)
  for p in plans.mitems:
    if p.rect.empty: p.rect = Rect4(x0: 0, y0: 0, x1: 1, y1: 1)    # (nothing changed: one pixel left as it was)
  var transparentAnywhere = false
  for c in anyClear:
    if c: transparentAnywhere = true
  # each frame's pixels: drawn (their colors), or left (transparent)
  template eachPixel(k: int; body: untyped) =
    ## `drawn`, `color`, `i` (the place in the rectangle) for each pixel of frame k's rectangle.
    let r = pp[k].rect
    let a = cast[ptr UncheckedArray[uint32]](unsafeAddr fp[k].px[0])
    let b = if k > 0: cast[ptr UncheckedArray[uint32]](unsafeAddr fp[k - 1].px[0]) else: nil
    let pr = if k > 0: pp[k - 1].rect else: Rect4()
    let wasCleared = k > 0 and pp[k - 1].disposal == 2
    var i {.inject.} = 0
    for y in r.y0 ..< r.y1:
      for x in r.x0 ..< r.x1:
        let s = shown(a[y * w + x])
        let gone = k == 0 or (wasCleared and x >= pr.x0 and x < pr.x1 and y >= pr.y0 and y < pr.y1)
        let drawn {.inject.} = s != 0 and (gone or s != shown(b[y * w + x]))
        let color {.inject.} = s
        body
        inc i
  parallelFor(n, proc (lo, hi: int) =
    for k in lo ..< hi:
      let r = pp[k].rect
      let area = max(0, r.x1 - r.x0) * max(0, r.y1 - r.y0)
      let step = max(1, area div 4096)
      var clear = pp[k].disposal == 2 or (k == 0 and transparentAnywhere)
      eachPixel(k):
        if drawn:
          pp[k].colors.incl color
          if i mod step == 0: pp[k].sample.add color
        else: clear = true
      pp[k].needClear = clear
  )
  # the file's palette: every color when there are few, else made from all frames
  var all: ColorSet
  for p in plans:
    if p.colors.over: all.over = true
    for c in p.colors.list: all.incl c
  let globalClear = transparentAnywhere or n > 1
  let slots = 256 - ord(globalClear)
  var globalPal: seq[uint32]
  if globalClear: globalPal.add 0'u32
  if not all.over and all.list.len <= slots:
    globalPal.add all.list
  else:
    var sample: seq[uint32]
    for p in plans: sample.add p.sample
    globalPal.add quantize(sample, slots).palette
  let globalBits = bitsFor(max(2, globalPal.len))
  var globalSet: ColorSet
  for c in globalPal: globalSet.incl c
  # each frame: its palette, its pixels as indexes, LZW (all frames at once)
  var parts = newSeq[string](n)
  let partp = cast[ptr UncheckedArray[string]](addr parts[0])
  parallelFor(n, proc (lo, hi: int) =
    for k in lo ..< hi:
      let r = pp[k].rect
      let rw = r.x1 - r.x0
      let rh = r.y1 - r.y0
      let clear = pp[k].needClear
      let first = ord(clear)
      var idx = newSeq[uint8](rw * rh)
      var pal: seq[uint32] = @[]
      var local = false
      let colors = pp[k].colors
      if not colors.over and colors.list.len <= 256 - first:
        # few colors: exactly (the file's palette when it has them all)
        var inGlobal = globalClear or not clear
        if inGlobal:
          for c in colors.list:
            if globalSet.has(c) < 0:
              inGlobal = false
              break
        if inGlobal:
          pal = globalPal
          eachPixel(k):
            idx[i] = if drawn: uint8(globalSet.has(color)) else: 0'u8
        else:
          local = true
          if clear: pal.add 0'u32
          pal.add colors.list
          eachPixel(k):
            idx[i] = if drawn: uint8(colors.has(color) + first) else: 0'u8
      else:
        # many colors: the file's palette, or one of its own when that is clearly better
        var gN = initNearest(globalPal, ord(globalClear))
        var errG = 0
        for c in pp[k].sample: errG += dist(globalPal[gN.find(c)], c)
        pal = globalPal
        var nf = gN
        if errG > 12 * pp[k].sample.len:                 # (more than a level or so off, on average)
          var own = newSeq[uint32]()
          if clear: own.add 0'u32
          var sample: seq[uint32]
          let every = max(1, rw * rh div 16384)           # (a sample: median cut needs no more)
          eachPixel(k):
            if drawn and i mod every == 0: sample.add color
          own.add medianCut(sample, 256 - first)
          var lN = initNearest(own, first)
          var errL = 0
          for c in pp[k].sample: errL += dist(own[lN.find(c)], c)
          if errL * 11 < errG * 10:
            pal = own
            nf = lN
            local = true
        let reserved = if local: clear else: globalClear      # (entry 0 kept for transparency)
        if dither:
          var sub = newSeq[uint32](rw * rh)
          eachPixel(k):
            sub[i] = if drawn: color else: 0'u32
          var q = Quantized(palette: pal, index: newSeq[uint8](rw * rh), transparent: (if reserved: 0 else: -1))
          q.ditherTo(sub, rw, rh)
          idx = move q.index
        else:
          eachPixel(k):
            idx[i] = if drawn: uint8(nf.find(color)) else: 0'u8
      # the frame: graphic control (disposal, delay, transparency), image, its own palette
      var o = newStringOfCap(rw * rh div 2 + 1024)
      let delay = clamp((fp[k].delayMs + 5) div 10, 0, 65535)
      o.add "\x21\xF9\x04"
      o.add char((pp[k].disposal shl 2) or ord(clear))
      o.add char(delay and 255); o.add char(delay shr 8)
      o.add '\0'; o.add '\0'
      o.add '\x2C'
      for v in [r.x0, r.y0, rw, rh]:
        o.add char(v and 255); o.add char(v shr 8)
      let bits = if local: bitsFor(max(2, pal.len)) else: globalBits
      if local:
        o.add char(0x80 or (bits - 1))
        o.colorTable(pal, bits)
      else: o.add '\0'
      o.lzwData(idx, max(2, bits))
      partp[k] = move o
  )
  # the file
  result = "GIF89a"
  result.add char(w and 255); result.add char(w shr 8)
  result.add char(h and 255); result.add char(h shr 8)
  result.add char(0xF0 or (globalBits - 1))
  result.add '\0'; result.add '\0'
  result.colorTable(globalPal, globalBits)
  if loop >= 0:
    let l = min(loop, 65535)
    result.add "\x21\xFF\x0BNETSCAPE2.0\x03\x01"
    result.add char(l and 255); result.add char(l shr 8)
    result.add '\0'
  for p in parts: result.add p
  result.add ';'

# ---- reading --------------------------------------------------------------------------------------------

proc gifInfo(data: string): tuple[delays: seq[int]; loop: int] =
  ## The delays the file gives its frames (milliseconds) and its loop count
  ## (-1: none), walking its blocks as `loadGif` does.
  result.loop = -1
  if not isGif(data) or data.len < 13: return
  var p = 13
  let packed = ord(data[10])
  if (packed and 0x80) != 0: p += 3 * (2 shl (packed and 7))
  var delay = 0
  template u16(i: int): int = ord(data[i]) or (ord(data[i + 1]) shl 8)
  template skip(p: untyped) =
    while p < data.len and data[p] != '\0': p += ord(data[p]) + 1
    inc p
  while p < data.len:
    let b = data[p]
    inc p
    case b
    of '\x21':
      if p >= data.len: break
      let label = ord(data[p])
      inc p
      if label == 0xF9 and p + 4 < data.len and ord(data[p]) >= 4:
        delay = u16(p + 2) * 10
      elif label == 0xFF and p + 16 < data.len and data[p] == '\x0B' and data[p + 1 .. p + 11] == "NETSCAPE2.0" and
           data[p + 12] == '\x03' and data[p + 13] == '\x01':
        result.loop = u16(p + 14)
      skip(p)
    of '\x2C':
      if p + 9 > data.len: break
      let fw = u16(p + 4)
      let fh = u16(p + 6)
      let ip = ord(data[p + 8])
      p += 9
      if (ip and 0x80) != 0: p += 3 * (2 shl (ip and 7))
      inc p                                  # (the LZW code size)
      skip(p)
      if fw > 0 and fh > 0 and fw <= MaxGifSide and fh <= MaxGifSide: result.delays.add delay
      delay = 0
    else: break

proc gifLoop*(data: string): int =
  ## How many times the GIF says it repeats (0: for ever; -1: it does not
  ## say, played once).
  gifInfo(data).loop

proc gifFrames*(data: string): seq[tuple[bmp: Bitmap; delayMs: int]] =
  ## Every frame of a GIF as a whole picture (as browsers and Pillow show
  ## it: transparent where nothing is), with the delay the file gives it in
  ## milliseconds (0 kept 0: browsers show such frames for 100 ms). Decoded
  ## by `retroui/mediagif` (its limits: 4096 pixels a side, 32 million pixels
  ## of frames). Raises `ValueError` when it is not a GIF.
  let frames = loadGif(data)
  let info = gifInfo(data)
  for k, f in frames:
    result.add (f.image, if k < info.delays.len: info.delays[k] else: f.delayMs)

## LZMA, unpacked: the fonts and pictures a program carries are packed with
## it (13 % smaller than zlib for the fonts), behind a small header of the
## kit's own --
##
##   "RLZ1"  props (one byte: (pb * 5 + lp) * 9 + lc)  dictionary size (4)
##   size unpacked (4, little end first)  the raw LZMA stream
##
## -- written by `tools/packlzma.py`. Made from the LZMA specification
## (Igor Pavlov's, public domain): a range decoder, literals that follow
## the byte of the last match, lengths, distances. Damaged or cut data
## gives "" (and never reads or writes past an end).
##
## .. code-block:: nim
##   const packed = staticRead("fonts/FreeSans.ttf.z")
##   if isLzma(packed): let ttf = unlzma(packed)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

# (the decoder checks every place it reads and writes itself -- a match
# never before the start, never past the end; a probability's index always
# in its table by how it is made -- so Nim's own checks are off here: they
# made it four times as slow)
{.push checks: off, boundChecks: off, overflowChecks: off, rangeChecks: off.}

const
  Magic = "RLZ1"
  NumStates = 12
  PosBitsMax = 4
  LenToPosStates = 4
  AlignBits = 4
  EndPosModel = 14
  FullDistances = 1 shl 7
  MatchMinLen = 2
  ProbInit = 1024'u16

type
  Decoder = object
    src: ptr UncheckedArray[byte]
    n, at: int
    rng, code: uint32
    bad: bool

template nextByte(d: var Decoder): uint32 =
  (if d.at < d.n: (inc d.at; uint32(d.src[d.at - 1])) else: (d.bad = true; 0'u32))

proc bit(d: var Decoder; p: var uint16): uint32 {.inline.} =
  let bound = (d.rng shr 11) * uint32(p)
  if d.code < bound:
    p += (2048'u16 - p) shr 5
    d.rng = bound
    result = 0
  else:
    p -= p shr 5
    d.code -= bound
    d.rng -= bound
    result = 1
  if d.rng < (1'u32 shl 24):
    d.rng = d.rng shl 8
    d.code = (d.code shl 8) or d.nextByte

proc direct(d: var Decoder; bits: int): uint32 =
  for _ in 0 ..< bits:
    d.rng = d.rng shr 1
    d.code -= d.rng
    let t = 0'u32 - (d.code shr 31)
    d.code += d.rng and t
    result = (result shl 1) + (t + 1)
    if d.rng < (1'u32 shl 24):
      d.rng = d.rng shl 8
      d.code = (d.code shl 8) or d.nextByte

proc tree(d: var Decoder; probs: var openArray[uint16]; base, bits: int): uint32 =
  var m = 1'u32
  for _ in 0 ..< bits: m = (m shl 1) + d.bit(probs[base + int(m)])
  m - (1'u32 shl bits)

proc reverse(d: var Decoder; probs: var openArray[uint16]; base, bits: int): uint32 =
  var m = 1'u32
  for i in 0 ..< bits:
    let b = d.bit(probs[base + int(m)])
    m = (m shl 1) + b
    result = result or (b shl i)

type LenDecoder = object
  choice, choice2: uint16
  low, mid: array[1 shl PosBitsMax, array[1 shl 3, uint16]]
  high: array[1 shl 8, uint16]

proc initLen(l: var LenDecoder) =
  l.choice = ProbInit
  l.choice2 = ProbInit
  for a in l.low.mitems:
    for p in a.mitems: p = ProbInit
  for a in l.mid.mitems:
    for p in a.mitems: p = ProbInit
  for p in l.high.mitems: p = ProbInit

proc decodeLen(d: var Decoder; l: var LenDecoder; posState: int): uint32 =
  if d.bit(l.choice) == 0: return d.tree(l.low[posState], 0, 3)
  if d.bit(l.choice2) == 0: return 8 + d.tree(l.mid[posState], 0, 3)
  16 + d.tree(l.high, 0, 8)

proc isLzma*(packed: string): bool =
  ## `packed` is LZMA behind the kit's header (else zlib, or other bytes).
  packed.len >= 13 and packed[0 ..< 4] == Magic

proc unlzma*(packed: string): string =
  ## The bytes `packed` (`isLzma`) holds; "" when it is damaged or cut.
  if not packed.isLzma: return ""
  let props = int(packed[4].byte)
  if props >= 9 * 5 * 5: return ""
  let lc = props mod 9
  let lp = (props div 9) mod 5
  let pb = props div 45
  var dict = 0'u32
  var size = 0
  for i in 0 .. 3:
    dict = dict or (uint32(packed[5 + i].byte) shl (8 * i))
    size = size or (int(packed[9 + i].byte) shl (8 * i))
  if size < 0 or size > 256 * 1024 * 1024: return ""
  if size == 0 or packed.len < 13 + 5: return ""
  var d = Decoder(src: cast[ptr UncheckedArray[byte]](unsafeAddr packed[13]), n: packed.len - 13)
  if d.nextByte != 0: return ""
  d.rng = 0xFFFFFFFF'u32
  for _ in 0 .. 3: d.code = (d.code shl 8) or d.nextByte
  if d.code == d.rng: return ""
  var lit = newSeq[uint16](0x300 shl (lc + lp))
  for p in lit.mitems: p = ProbInit
  var
    isMatch, isRep0Long: array[NumStates shl PosBitsMax, uint16]
    isRep, isRepG0, isRepG1, isRepG2: array[NumStates, uint16]
    posSlot: array[LenToPosStates, array[1 shl 6, uint16]]
    posProbs: array[1 + FullDistances - EndPosModel, uint16]
    align: array[1 shl AlignBits, uint16]
    lenDec, repLenDec: LenDecoder
  for a in [addr isMatch, addr isRep0Long]:
    for p in a[].mitems: p = ProbInit
  for a in [addr isRep, addr isRepG0, addr isRepG1, addr isRepG2]:
    for p in a[].mitems: p = ProbInit
  for a in posSlot.mitems:
    for p in a.mitems: p = ProbInit
  for p in posProbs.mitems: p = ProbInit
  for p in align.mitems: p = ProbInit
  initLen(lenDec)
  initLen(repLenDec)
  # (into a string of its own, not `result`: given, then "" on an early
  # return, Nim 2.2 would not free it -- docs/nim-bugs.md)
  var o = newString(size)
  let pbMask = (1 shl pb) - 1
  let lpMask = (1 shl lp) - 1
  var
    pos = 0
    state = 0
    rep0, rep1, rep2, rep3 = 0'u32
  while pos < size:
    if d.bad: return ""
    let posState = pos and pbMask
    if d.bit(isMatch[(state shl PosBitsMax) + posState]) == 0:
      # a byte as it is: from its probabilities, the byte before it -- and
      # after a match, the byte of the match it most likely follows
      let prev = if pos > 0: uint32(o[pos - 1].byte) else: 0'u32
      let ls = ((pos and lpMask) shl lc) + int(prev shr (8 - lc))
      let base = 0x300 * ls
      var sym = 1'u32
      if state >= 7:
        if int(rep0) + 1 > pos: return ""
        var mb = uint32(o[pos - int(rep0) - 1].byte)
        while sym < 0x100:
          let mbit = (mb shr 7) and 1
          mb = mb shl 1
          let b = d.bit(lit[base + int(((1 + mbit) shl 8) + sym)])
          sym = (sym shl 1) or b
          if mbit != b: break
      while sym < 0x100: sym = (sym shl 1) or d.bit(lit[base + int(sym)])
      o[pos] = char(sym - 0x100)
      inc pos
      state = if state < 4: 0 elif state < 10: state - 3 else: state - 6
      continue
    var len: uint32
    if d.bit(isRep[state]) != 0:
      # a match at one of the last four distances
      if pos == 0: return ""
      if d.bit(isRepG0[state]) == 0:
        if d.bit(isRep0Long[(state shl PosBitsMax) + posState]) == 0:
          # (one byte, at the last distance)
          state = if state < 7: 9 else: 11
          if int(rep0) + 1 > pos: return ""
          o[pos] = o[pos - int(rep0) - 1]
          inc pos
          continue
      else:
        var dist: uint32
        if d.bit(isRepG1[state]) == 0: dist = rep1
        else:
          if d.bit(isRepG2[state]) == 0: dist = rep2
          else:
            dist = rep3
            rep3 = rep2
          rep2 = rep1
        rep1 = rep0
        rep0 = dist
      len = d.decodeLen(repLenDec, posState)
      state = if state < 7: 8 else: 11
    else:
      # a match at a new distance
      rep3 = rep2
      rep2 = rep1
      rep1 = rep0
      len = d.decodeLen(lenDec, posState)
      state = if state < 7: 7 else: 10
      let ls = int(min(len, LenToPosStates - 1))
      let slot = d.tree(posSlot[ls], 0, 6)
      if slot < 4: rep0 = slot
      else:
        let nd = int((slot shr 1) - 1)
        var dist = (2'u32 or (slot and 1)) shl nd
        if slot < EndPosModel:
          dist += d.reverse(posProbs, int(dist) - int(slot), nd)
        else:
          dist += d.direct(nd - AlignBits) shl AlignBits
          dist += d.reverse(align, 0, AlignBits)
        rep0 = dist
      if rep0 == 0xFFFFFFFF'u32: break          # (the end marker)
      if rep0 >= dict or int(rep0) >= pos: return ""
    # the match: copied byte by byte (it may overlap where it is written)
    let n = int(len) + MatchMinLen
    if pos + n > size: return ""
    let from0 = pos - int(rep0) - 1
    for i in 0 ..< n: o[pos + i] = o[from0 + i]
    pos += n
  if pos != size or d.bad: return ""
  result = move o

{.pop.}

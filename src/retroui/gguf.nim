## GGUF files read: the format language models come in (llama.cpp's and bitnet.cpp's) -- what
## the model says of itself (its architecture, sizes, tokenizer) and its tensors, mapped from the
## file, not read into memory: a 1 GB model costs what the system pages in.
##
## .. code-block:: nim
##   let g = openGguf("model.gguf")
##   echo g.strOf("general.architecture"), " ", g.intOf("bitnet.block_count")
##   let t = g.tensor("token_embd.weight")     # its kind, its sizes, where its bytes are
##   g.close()
##
## Tensor kinds read by `retroui/llm`: F32, F16, BF16, Q8_0 and the ternary TQ1_0, TQ2_0 and
## I2_S (bitnet.cpp's, as it packs it on x86: the BitNet b1.58 models it publishes).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[memfiles, tables, strutils]

type
  GgmlType* = enum
    ## A tensor's kind (GGML's numbers).
    gtF32 = 0, gtF16 = 1, gtQ4_0 = 2, gtQ4_1 = 3, gtQ5_0 = 6, gtQ5_1 = 7, gtQ8_0 = 8, gtQ8_1 = 9,
    gtQ2_K = 10, gtQ3_K = 11, gtQ4_K = 12, gtQ5_K = 13, gtQ6_K = 14, gtQ8_K = 15,
    gtBF16 = 30, gtTQ1_0 = 34, gtTQ2_0 = 35,
    gtI2_S = 36                  ## (bitnet.cpp's: 2 bits a weight, one scale after them all)
    gtUnknown = 255

  GgufKind* = enum
    gkU8 = 0, gkI8 = 1, gkU16 = 2, gkI16 = 3, gkU32 = 4, gkI32 = 5, gkF32 = 6, gkBool = 7,
    gkString = 8, gkArray = 9, gkU64 = 10, gkI64 = 11, gkF64 = 12

  GgufValue* = object
    ## One of the model's own facts.
    case kind*: GgufKind
    of gkString: s*: string
    of gkArray: items*: seq[GgufValue]
    of gkF32, gkF64: f*: float64
    of gkBool: b*: bool
    else: i*: int64

  GgufTensor* = object
    ## A tensor: its sizes (`dims[0]` the fastest: a matrix's row length), its kind, its bytes.
    name*: string
    dims*: seq[int]
    kind*: GgmlType
    data*: ptr UncheckedArray[byte]
    size*: int                   ## its bytes

  Gguf* = ref object
    ## An open GGUF file.
    path*: string
    version*: int
    meta*: Table[string, GgufValue]
    tensors*: seq[GgufTensor]
    byName: Table[string, int]
    mf: MemFile
    opened: bool

  GgufError* = object of CatchableError

proc blockOf*(k: GgmlType): tuple[n, bytes: int] =
  ## How many values a block of `k` holds, and its bytes (0, 0: a kind not read here).
  case k
  of gtF32: (1, 4)
  of gtF16, gtBF16: (1, 2)
  of gtQ8_0: (32, 34)
  of gtQ4_0: (32, 18)
  of gtTQ2_0: (256, 66)
  of gtTQ1_0: (256, 54)
  of gtI2_S: (128, 32)
  else: (0, 0)

proc bytesOf*(k: GgmlType; n: int): int =
  ## The bytes of `n` values of kind `k` (-1: not read here, or `n` not whole blocks).
  let (bn, bb) = blockOf(k)
  if bn == 0 or n mod bn != 0: -1 else: n div bn * bb

proc fail(msg: string) {.noreturn.} = raise newException(GgufError, msg)

proc openGguf*(path: string): Gguf =
  ## Opens a GGUF file (version 2 or 3). Raises `GgufError` when it is not one or is cut short.
  result = Gguf(path: path)
  try: result.mf = memfiles.open(path, mode = fmRead)
  except OSError, IOError: fail("cannot open " & path)
  result.opened = true
  let base = cast[ptr UncheckedArray[byte]](result.mf.mem)
  let total = result.mf.size
  var at = 0
  proc need(n: int) =
    if n < 0 or at + n > total: fail(path & ": cut short")
  proc u8(): int =
    need(1)
    result = int(base[at])
    inc at
  proc rd(n: int): uint64 =
    need(n)
    for i in 0 ..< n: result = result or (uint64(base[at + i]) shl (8 * i))
    at += n
  proc str(): string =
    let n = int(rd(8))
    if n < 0 or n > total: fail(path & ": a name too long")
    need(n)
    result = newString(n)
    if n > 0: copyMem(addr result[0], addr base[at], n)
    at += n
  proc value(k: GgufKind; depth = 0): GgufValue =
    case k
    of gkU8: GgufValue(kind: k, i: int64(u8()))
    of gkI8: GgufValue(kind: k, i: int64(cast[int8](u8())))
    of gkU16: GgufValue(kind: k, i: int64(rd(2)))
    of gkI16: GgufValue(kind: k, i: int64(cast[int16](uint16(rd(2)))))
    of gkU32: GgufValue(kind: k, i: int64(rd(4)))
    of gkI32: GgufValue(kind: k, i: int64(cast[int32](uint32(rd(4)))))
    of gkU64: GgufValue(kind: k, i: cast[int64](rd(8)))
    of gkI64: GgufValue(kind: k, i: cast[int64](rd(8)))
    of gkF32: GgufValue(kind: k, f: float64(cast[float32](uint32(rd(4)))))
    of gkF64: GgufValue(kind: k, f: cast[float64](rd(8)))
    of gkBool: GgufValue(kind: k, b: u8() != 0)
    of gkString: GgufValue(kind: k, s: str())
    of gkArray:
      if depth > 2: fail(path & ": arrays too deep")
      let ik = int(rd(4))
      if ik notin 0 .. 12: fail(path & ": a value of an unknown kind")
      let n = int(rd(8))
      if n < 0 or n > total: fail(path & ": an array too long")
      var r = GgufValue(kind: gkArray)
      r.items = newSeqOfCap[GgufValue](n)
      for i in 0 ..< n: r.items.add value(GgufKind(ik), depth + 1)
      r
  need(4)
  if base[0] != byte('G') or base[1] != byte('G') or base[2] != byte('U') or base[3] != byte('F'):
    fail(path & " is not a GGUF file")
  at = 4
  result.version = int(rd(4))
  if result.version notin 2 .. 3: fail(path & ": GGUF version " & $result.version & " is not read here")
  let nTensors = int(rd(8))
  let nKv = int(rd(8))
  if nTensors < 0 or nTensors > 1_000_000 or nKv < 0 or nKv > 1_000_000: fail(path & ": damaged")
  for i in 0 ..< nKv:
    let key = str()
    let k = int(rd(4))
    if k notin 0 .. 12: fail(path & ": " & key & " has a value of an unknown kind")
    # (the value read first: a key copied for `[]=` and then a value that raises -- a file cut
    # short -- is a copy Nim never lets go of)
    let v = value(GgufKind(k))
    result.meta[key] = v
  var offs: seq[int]
  for i in 0 ..< nTensors:
    var t = GgufTensor(name: str())
    let nd = int(rd(4))
    if nd notin 1 .. 4: fail(path & ": " & t.name & " has " & $nd & " dimensions")
    for d in 0 ..< nd: t.dims.add int(rd(8))
    let k = int(rd(4))
    t.kind = gtUnknown
    for gt in [gtF32, gtF16, gtQ4_0, gtQ4_1, gtQ5_0, gtQ5_1, gtQ8_0, gtQ8_1, gtQ2_K, gtQ3_K, gtQ4_K,
               gtQ5_K, gtQ6_K, gtQ8_K, gtBF16, gtTQ1_0, gtTQ2_0, gtI2_S]:
      if ord(gt) == k: t.kind = gt
    offs.add int(rd(8))
    result.tensors.add t
  var align = 32
  if "general.alignment" in result.meta and result.meta["general.alignment"].kind in {gkU32, gkI32, gkU64}:
    align = max(1, int(result.meta["general.alignment"].i))
  let dataStart = (at + align - 1) div align * align
  for i, t in result.tensors.mpairs:
    var n = 1
    for d in t.dims: n *= d
    t.size = bytesOf(t.kind, n)
    # (I2_S: its scale, a float, after the weights)
    if t.kind == gtI2_S and t.size > 0: t.size += 4
    let start = dataStart + offs[i]
    if t.size > 0:
      if start < 0 or start + t.size > total: fail(path & ": " & t.name & " goes past the file's end")
      t.data = cast[ptr UncheckedArray[byte]](addr base[start])
    result.byName[t.name] = i

proc close*(g: Gguf) =
  ## Lets go of the file (its tensors' bytes with it).
  if g != nil and g.opened:
    g.mf.close()
    g.opened = false
    for t in g.tensors.mitems: t.data = nil

proc has*(g: Gguf; key: string): bool = key in g.meta
  ## The model says `key`.

proc strOf*(g: Gguf; key: string; dflt = ""): string =
  ## A text the model says (`dflt`: it says none).
  if key in g.meta and g.meta[key].kind == gkString: g.meta[key].s else: dflt

proc intOf*(g: Gguf; key: string; dflt = 0): int =
  ## A whole number the model says.
  if key notin g.meta: return dflt
  let v = g.meta[key]
  case v.kind
  of gkF32, gkF64: int(v.f)
  of gkString, gkArray: dflt
  of gkBool: ord(v.b)
  else: int(v.i)

proc floatOf*(g: Gguf; key: string; dflt = 0.0): float =
  ## A number the model says.
  if key notin g.meta: return dflt
  let v = g.meta[key]
  case v.kind
  of gkF32, gkF64: v.f
  of gkString, gkArray: dflt
  of gkBool: float(ord(v.b))
  else: float(v.i)

proc strings*(g: Gguf; key: string): seq[string] =
  ## A list of texts the model says (its tokens, its merges).
  if key notin g.meta or g.meta[key].kind != gkArray: return
  for v in g.meta[key].items:
    if v.kind == gkString: result.add v.s

proc numbers*(g: Gguf; key: string): seq[float] =
  ## A list of numbers the model says (its tokens' scores, kinds).
  if key notin g.meta or g.meta[key].kind != gkArray: return
  for v in g.meta[key].items:
    case v.kind
    of gkF32, gkF64: result.add v.f
    of gkString, gkArray: result.add 0.0
    of gkBool: result.add float(ord(v.b))
    else: result.add float(v.i)

proc tensor*(g: Gguf; name: string): GgufTensor =
  ## The tensor `name` (raises `GgufError` when the model has none).
  if name notin g.byName: fail(g.path & " has no tensor " & name)
  result = g.tensors[g.byName[name]]
  if result.data == nil: fail(g.path & ": " & name & " is of a kind not read here (" & $result.kind & ")")

proc hasTensor*(g: Gguf; name: string): bool = name in g.byName
  ## The model has a tensor `name`.

proc describe*(g: Gguf): string =
  ## A line of what the model is ("bitnet-b1.58, 30 layers, 2560 wide, 128256 tokens, 1.19 GB").
  let arch = g.strOf("general.architecture", "?")
  var bytes = 0
  for t in g.tensors: bytes += max(0, t.size)
  arch & ", " & $g.intOf(arch & ".block_count") & " layers, " & $g.intOf(arch & ".embedding_length") &
    " wide, " & $g.strings("tokenizer.ggml.tokens").len & " tokens, " &
    (if bytes >= 1_000_000_000: formatFloat(system.float(bytes) / 1e9, ffDecimal, 2) & " GB"
     else: formatFloat(system.float(bytes) / 1e6, ffDecimal, 1) & " MB")

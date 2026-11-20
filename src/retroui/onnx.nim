## ONNX files read: the format image models come in (Segment Anything's, LaMa's, Depth
## Anything's, PaddleOCR's...) -- the graph of operations, its inputs and outputs, and the
## weights (`initializer`), from the protobuf the file is, read by hand (no protobuf library).
## The weights of a big model kept in a file beside it (`external_data`) are read from there.
##
## .. code-block:: nim
##   let m = readOnnx("depth_anything_small.onnx")
##   echo m.graph.inputs[0].name, " ", m.graph.nodes.len, " operations"
##
## `retroui/nnet` runs them.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, tables, strutils]

type
  OnnxType* = enum
    otUndefined = 0, otFloat = 1, otUint8 = 2, otInt8 = 3, otUint16 = 4, otInt16 = 5, otInt32 = 6,
    otInt64 = 7, otString = 8, otBool = 9, otFloat16 = 10, otDouble = 11, otUint32 = 12,
    otUint64 = 13, otComplex64 = 14, otComplex128 = 15, otBfloat16 = 16

  OnnxTensor* = object
    ## A tensor of the file: its name, its sizes, its kind, its numbers (as floats, as whole
    ## numbers: whichever its kind is).
    name*: string
    dims*: seq[int]
    kind*: OnnxType
    floats*: seq[float32]
    ints*: seq[int64]

  OnnxAttrKind* = enum
    oaUndefined = 0, oaFloat = 1, oaInt = 2, oaString = 3, oaTensor = 4, oaGraph = 5,
    oaFloats = 6, oaInts = 7, oaStrings = 8

  OnnxAttr* = object
    name*: string
    kind*: OnnxAttrKind
    f*: float32
    i*: int64
    s*: string
    t*: OnnxTensor
    floats*: seq[float32]
    ints*: seq[int64]
    strings*: seq[string]
    g*: ref OnnxGraph

  OnnxNode* = object
    ## One operation: its kind ("Conv", "Relu"...), what it takes and makes (by name: "" an
    ## input left out), its settings.
    op*, name*, domain*: string
    inputs*, outputs*: seq[string]
    attrs*: seq[OnnxAttr]

  OnnxValue* = object
    ## An input or an output of the graph: its name, its kind, its sizes (-1: any).
    name*: string
    kind*: OnnxType
    dims*: seq[int]

  OnnxGraph* = object
    name*: string
    nodes*: seq[OnnxNode]
    weights*: Table[string, OnnxTensor]
    inputs*, outputs*: seq[OnnxValue]

  OnnxModel* = object
    irVersion*: int
    opset*: int                  ## (the default domain's)
    producer*: string
    graph*: OnnxGraph
    meta*: seq[(string, string)] ## its maker's notes (`metadata_props`: a reader's characters...)

  OnnxError* = object of CatchableError

proc fail(msg: string) {.noreturn.} = raise newException(OnnxError, msg)

# ---- protobuf's wire format ----------------------------------------------------------------------------

type Pb = object
  data: ptr UncheckedArray[byte]
  at, stop: int

proc pb(s: string; a = 0; b = -1): Pb =
  Pb(data: cast[ptr UncheckedArray[byte]](if s.len > 0: unsafeAddr s[0] else: nil), at: a,
     stop: if b < 0: s.len else: b)

proc more(p: Pb): bool = p.at < p.stop

proc varint(p: var Pb): uint64 =
  var shift = 0
  while true:
    if p.at >= p.stop: fail("damaged: a number cut short")
    let b = p.data[p.at]
    inc p.at
    result = result or (uint64(b and 0x7F) shl shift)
    if (b and 0x80) == 0: break
    shift += 7
    if shift > 63: fail("damaged: a number too long")

proc key(p: var Pb): tuple[field, wire: int] =
  let k = p.varint()
  (int(k shr 3), int(k and 7))

proc sub(p: var Pb): Pb =
  ## (a length-delimited field: its bytes)
  let n = int(p.varint())
  if n < 0 or p.at + n > p.stop: fail("damaged: a field past its end")
  result = Pb(data: p.data, at: p.at, stop: p.at + n)
  p.at += n

proc str(p: var Pb): string =
  let s = p.sub()
  result = newString(s.stop - s.at)
  if result.len > 0: copyMem(addr result[0], addr p.data[s.at], result.len)

proc fixed32(p: var Pb): uint32 =
  if p.at + 4 > p.stop: fail("damaged")
  for i in 0 .. 3: result = result or (uint32(p.data[p.at + i]) shl (8 * i))
  p.at += 4

proc fixed64(p: var Pb): uint64 =
  if p.at + 8 > p.stop: fail("damaged")
  for i in 0 .. 7: result = result or (uint64(p.data[p.at + i]) shl (8 * i))
  p.at += 8

proc skip(p: var Pb; wire: int) =
  case wire
  of 0: discard p.varint()
  of 1: p.at += 8
  of 2: discard p.sub()
  of 5: p.at += 4
  else: fail("damaged: a field of an unknown kind")
  if p.at > p.stop: fail("damaged")

proc ints(p: var Pb; wire: int; into: var seq[int64]) =
  ## (a repeated whole number: packed or one at a time)
  if wire == 2:
    var s = p.sub()
    while s.more: into.add cast[int64](s.varint())
  else: into.add cast[int64](p.varint())

proc floats(p: var Pb; wire: int; into: var seq[float32]) =
  if wire == 2:
    var s = p.sub()
    while s.more: into.add cast[float32](s.fixed32())
  else: into.add cast[float32](p.fixed32())

# ---- the file's parts ---------------------------------------------------------------------------------------

proc halfToFloat(h: uint16): float32 =
  let v = cast[float32](uint32(h and 0x7FFF'u16) shl 13) * 5.192296858534828e33'f32
  cast[float32](cast[uint32](v) or (uint32(h and 0x8000'u16) shl 16))

proc fromRaw(t: var OnnxTensor; raw: string) =
  ## (the tensor's numbers from its bytes, little-endian)
  let n = raw.len
  let p = cast[ptr UncheckedArray[byte]](if n > 0: unsafeAddr raw[0] else: nil)
  template u(i, k: int): uint64 =
    var v = 0'u64
    for j in 0 ..< k: v = v or (uint64(p[i * k + j]) shl (8 * j))
    v
  case t.kind
  of otFloat:
    t.floats.setLen(n div 4)
    if n >= 4: copyMem(addr t.floats[0], p, n div 4 * 4)
  of otFloat16:
    t.floats.setLen(n div 2)
    for i in 0 ..< n div 2: t.floats[i] = halfToFloat(uint16(u(i, 2)))
  of otBfloat16:
    t.floats.setLen(n div 2)
    for i in 0 ..< n div 2: t.floats[i] = cast[float32](uint32(u(i, 2)) shl 16)
  of otDouble:
    t.floats.setLen(n div 8)
    for i in 0 ..< n div 8: t.floats[i] = float32(cast[float64](u(i, 8)))
  of otInt64, otUint64:
    t.ints.setLen(n div 8)
    for i in 0 ..< n div 8: t.ints[i] = cast[int64](u(i, 8))
  of otInt32:
    t.ints.setLen(n div 4)
    for i in 0 ..< n div 4: t.ints[i] = int64(cast[int32](uint32(u(i, 4))))
  of otUint32:
    t.ints.setLen(n div 4)
    for i in 0 ..< n div 4: t.ints[i] = int64(uint32(u(i, 4)))
  of otInt16:
    t.ints.setLen(n div 2)
    for i in 0 ..< n div 2: t.ints[i] = int64(cast[int16](uint16(u(i, 2))))
  of otUint16:
    t.ints.setLen(n div 2)
    for i in 0 ..< n div 2: t.ints[i] = int64(uint16(u(i, 2)))
  of otInt8:
    t.ints.setLen(n)
    for i in 0 ..< n: t.ints[i] = int64(cast[int8](p[i]))
  of otUint8, otBool:
    t.ints.setLen(n)
    for i in 0 ..< n: t.ints[i] = int64(p[i])
  else: fail(t.name & ": a tensor of a kind not read here (" & $t.kind & ")")

proc tensorOf(p: var Pb; dir: string): OnnxTensor =
  var raw = ""
  var external: Table[string, string]
  var where = 0
  var ds: seq[int64]
  var i32: seq[int64]
  var dbl: seq[float64]
  while p.more:
    let (f, w) = p.key()
    case f
    of 1: p.ints(w, ds)
    of 2:
      let k = int(p.varint())
      result.kind = if k in 0 .. 16: OnnxType(k) else: otUndefined
    of 4: p.floats(w, result.floats)
    of 5: p.ints(w, i32)
    of 7: p.ints(w, result.ints)
    of 8: result.name = p.str()
    of 9: raw = p.str()
    of 10:
      if w == 2:
        var s = p.sub()
        while s.more: dbl.add cast[float64](s.fixed64())
      else: dbl.add cast[float64](p.fixed64())
    of 13:
      var s = p.sub()
      var k, v = ""
      while s.more:
        let (ff, ww) = s.key()
        if ff == 1: k = s.str()
        elif ff == 2: v = s.str()
        else: s.skip(ww)
      external[k] = v
    of 14: where = int(p.varint())
    else: p.skip(w)
  for d in ds: result.dims.add int(d)
  if where == 1 or external.len > 0:
    # (its numbers in a file beside the model's)
    let path = dir / external.getOrDefault("location")
    let off = try: parseInt(external.getOrDefault("offset", "0")) except ValueError: 0
    var n = -1
    try: n = parseInt(external.getOrDefault("length", "-1")) except ValueError: discard
    var f: File
    if not open(f, path): fail(result.name & ": its weights' file is not there: " & path)
    try:
      if n < 0: n = int(getFileSize(f)) - off
      f.setFilePos(off)
      raw = newString(n)
      if n > 0 and f.readBuffer(addr raw[0], n) != n: fail(result.name & ": its weights' file is cut short")
    finally: f.close()
  if raw.len > 0: result.fromRaw(raw)
  elif i32.len > 0:
    if result.kind == otFloat16:
      for v in i32: result.floats.add halfToFloat(uint16(v))
    else: result.ints = i32
  elif dbl.len > 0:
    for v in dbl: result.floats.add float32(v)

proc valueOf(p: var Pb): OnnxValue =
  while p.more:
    let (f, w) = p.key()
    case f
    of 1: result.name = p.str()
    of 2:
      var tp = p.sub()                         # TypeProto
      while tp.more:
        let (tf, tw) = tp.key()
        if tf == 1:
          var tt = tp.sub()                    # Tensor type
          while tt.more:
            let (ef, ew) = tt.key()
            if ef == 1:
              let k = int(tt.varint())
              result.kind = if k in 0 .. 16: OnnxType(k) else: otUndefined
            elif ef == 2:
              var sh = tt.sub()                # TensorShapeProto
              while sh.more:
                let (sf, sw) = sh.key()
                if sf == 1:
                  var d = sh.sub()
                  var v = -1
                  while d.more:
                    let (df, dw) = d.key()
                    if df == 1: v = int(cast[int64](d.varint()))
                    else: d.skip(dw)
                  result.dims.add v
                else: sh.skip(sw)
            else: tt.skip(ew)
        else: tp.skip(tw)
    else: p.skip(w)

proc graphOf(p: var Pb; dir: string): OnnxGraph

proc attrOf(p: var Pb; dir: string): OnnxAttr =
  while p.more:
    let (f, w) = p.key()
    case f
    of 1: result.name = p.str()
    of 2: result.f = cast[float32](p.fixed32())
    of 3: result.i = cast[int64](p.varint())
    of 4: result.s = p.str()
    of 5:
      var s = p.sub()
      result.t = tensorOf(s, dir)
    of 6:
      var s = p.sub()
      result.g = new OnnxGraph
      result.g[] = graphOf(s, dir)
    of 7: p.floats(w, result.floats)
    of 8: p.ints(w, result.ints)
    of 9: result.strings.add p.str()
    of 20:
      let k = int(p.varint())
      result.kind = if k in 0 .. 8: OnnxAttrKind(k) else: oaUndefined
    else: p.skip(w)

proc nodeOf(p: var Pb; dir: string): OnnxNode =
  while p.more:
    let (f, w) = p.key()
    case f
    of 1: result.inputs.add p.str()
    of 2: result.outputs.add p.str()
    of 3: result.name = p.str()
    of 4: result.op = p.str()
    of 5:
      var s = p.sub()
      result.attrs.add attrOf(s, dir)
    of 7: result.domain = p.str()
    else: p.skip(w)

proc graphOf(p: var Pb; dir: string): OnnxGraph =
  while p.more:
    let (f, w) = p.key()
    case f
    of 1:
      var s = p.sub()
      result.nodes.add nodeOf(s, dir)
    of 2: result.name = p.str()
    of 5:
      var s = p.sub()
      let t = tensorOf(s, dir)
      result.weights[t.name] = t
    of 11:
      var s = p.sub()
      result.inputs.add valueOf(s)
    of 12:
      var s = p.sub()
      result.outputs.add valueOf(s)
    else: p.skip(w)
  # (an input that is a weight too is a weight: older files list them as inputs)
  var real: seq[OnnxValue]
  for v in result.inputs:
    if v.name notin result.weights: real.add v
  result.inputs = real

proc readOnnx*(path: string): OnnxModel =
  ## The model in the ONNX file at `path` (its weights read into memory). Raises `OnnxError`
  ## when it is not one, or is damaged.
  let data = try: readFile(path) except IOError: fail("cannot open " & path)
  var p = pb(data)
  var sawGraph = false
  while p.more:
    let (f, w) = p.key()
    case f
    of 1: result.irVersion = int(p.varint())
    of 2: result.producer = p.str()
    of 7:
      var s = p.sub()
      result.graph = graphOf(s, path.parentDir)
      sawGraph = true
    of 8:
      var s = p.sub()
      var domain = ""
      var version = 0
      while s.more:
        let (ff, ww) = s.key()
        if ff == 1: domain = s.str()
        elif ff == 2: version = int(s.varint())
        else: s.skip(ww)
      if domain in ["", "ai.onnx"]: result.opset = version
    of 14:
      var s = p.sub()
      var k, v: string
      while s.more:
        let (ff, ww) = s.key()
        if ff == 1: k = s.str()
        elif ff == 2: v = s.str()
        else: s.skip(ww)
      result.meta.add (k, v)
    else: p.skip(w)
  if not sawGraph: fail(path & " is not an ONNX model")

proc metaOf*(m: OnnxModel; key: string): string =
  ## The model's note `key` ("": none).
  for (k, v) in m.meta:
    if k == key: return v

proc attr*(n: OnnxNode; name: string): OnnxAttr =
  ## The node's setting `name` (none: kind oaUndefined).
  for a in n.attrs:
    if a.name == name: return a

proc intAttr*(n: OnnxNode; name: string; dflt: int64): int64 =
  let a = n.attr(name)
  if a.name.len == 0: dflt else: a.i

proc floatAttr*(n: OnnxNode; name: string; dflt: float32): float32 =
  let a = n.attr(name)
  if a.name.len == 0: dflt else: a.f

proc intsAttr*(n: OnnxNode; name: string): seq[int64] = n.attr(name).ints

proc strAttr*(n: OnnxNode; name: string; dflt = ""): string =
  let a = n.attr(name)
  if a.name.len == 0: dflt else: a.s

## A language model run by the app itself, in Nim: no service, nothing sent anywhere. It reads
## a GGUF file (`retroui/gguf`) of the Llama family, Qwen 2's or BitNet's -- the ternary models
## whose weights are -1, 0 or 1 (BitNet b1.58, in TQ1_0, TQ2_0 or I2_S: a 2B model in 1.2 GB)
## -- and writes text a token at a time.
##
## .. code-block:: nim
##   let m = loadLlm("bitnet-b1.58-2B-4T.gguf")
##   var s = newLlmState(m)
##   echo m.chat(s, "You answer briefly.", "What is the capital of Oman?", maxTokens = 64)
##
## The architectures: "llama" (and "mistral"), "qwen2", "bitnet", "bitnet-25" and
## "bitnet-b1.58". The weights' kinds: F32, F16, BF16, Q8_0, Q4_0 and the ternary three, whose
## rows take the input as whole numbers (-127 .. 127 and a scale, as BitNet b1.58 was taught --
## Q8_0's and Q4_0's a scale each 32, as llama.cpp's), sixteen weights at a time (`simdllm.h`). The weights stay in the file, mapped: memory is what
## the system pages in, and the conversation's keys and values (`newLlmState`).
##
## It runs on the calling thread -- a job's (`retroui/jobs`): a model answers in seconds, not a
## frame -- with its own lasting threads for the rows of each matrix (`setLlmThreads`); one
## model works at a time.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[math, strutils, random]
import gguf, llmtokens
export gguf, llmtokens

when compileOption("threads"):
  import std/[locks, atomics, typedthreads]
  import parallel                     # (threadCount: a thread a core)

type
  Mat = object
    ## (a weight matrix: `rows` outputs of `cols` inputs each, as the file has it)
    kind: GgmlType
    rows, cols: int
    data: ptr UncheckedArray[byte]
    rowBytes: int
    scale: float32               ## (a tensor-wide scale: BitNet's .scale tensors, I2_S's own)

  LlmLayer = object
    attnNorm, attnSubNorm, ffnNorm, ffnSubNorm: seq[float32]
    qNorm, kNorm: seq[float32]   ## (Qwen 3's: each head's queries and keys normed)
    bq, bk, bv, bo: seq[float32]
    wq, wk, wv, wo, gate, up, down: Mat

  LlmAct* = enum
    ## The feed-forward's activation.
    actSilu, actReluSquared

  LlmPooling* = enum
    ## How a text's vectors make one (`embed`): their average, the first's, the last's.
    poolMean = 1, poolFirst = 2, poolLast = 3

  ChatForm* = enum
    ## How a conversation is written for the model.
    cfLlama3,                    ## <|start_header_id|>user<|end_header_id|> ... <|eot_id|>
    cfChatMl,                    ## <|im_start|>user ... <|im_end|>
    cfRoles                      ## User: ... <|eot_id|> (BitNet b1.58's)

  Llm* = ref object
    ## A model, loaded.
    g*: Gguf
    path*: string
    arch*, name*: string
    nEmbd*, nLayer*, nHead*, nHeadKv*, nFf*, nVocab*, headDim*, ctxMax*: int
    pooling*: LlmPooling         ## (how `embed` makes one vector of a text's)
    ropeBase*, rmsEps*: float32
    neox*: bool                  ## (rope on halves: BitNet's, Qwen's; else on pairs: Llama's)
    act*: LlmAct
    form*: ChatForm
    think*: bool                 ## (Qwen 3: it thinks before it answers -- slower; false: it answers)
    tok*: Tokenizer
    tokEmbd, output: Mat
    outNorm, ropeFreqs: seq[float32]
    layers: seq[LlmLayer]

  LlmState* = ref object
    ## A conversation with a model: what it has read so far (its keys and values, layer by
    ## layer), and the next token's scores.
    m: Llm
    pos*: int                    ## (tokens read)
    tokens*: seq[int]            ## (those tokens)
    kc, vc: seq[seq[float32]]
    x, xb2, q, k, v, att, hb, hb2: seq[float32]
    xb: seq[float32]
    logits*: seq[float32]
    rng: Rand

  LlmError* = object of CatchableError

proc fail(msg: string) {.noreturn.} = raise newException(LlmError, msg)

# ---- numbers out of the file ----------------------------------------------------------------------------

proc h2f(h: uint16): float32 {.inline.} =
  ## (a half as a float: its bits moved into place, scaled by 2^112 -- subnormals too)
  let v = cast[float32](uint32(h and 0x7FFF'u16) shl 13) * 5.192296858534828e33'f32
  cast[float32](cast[uint32](v) or (uint32(h and 0x8000'u16) shl 16))

proc u16(p: ptr UncheckedArray[byte]; at: int): uint16 {.inline.} =
  uint16(p[at]) or (uint16(p[at + 1]) shl 8)

type Digits = array[256, array[5, int8]]

proc digitsOf(k: GgmlType): Digits =
  ## (the weights, -1 .. 1, each byte of a ternary kind holds)
  for b in 0 .. 255:
    for n in 0 .. 4:
      result[b][n] =
        case k
        of gtI2_S: (if n < 4: int8((b shr (6 - 2 * n)) and 3) - 1 else: 0)
        of gtTQ2_0: (if n < 4: int8((b shr (2 * n)) and 3) - 1 else: 0)
        else: int8((int(uint8((b * [1, 3, 9, 27, 81][n]) and 0xFF)) * 3) shr 8) - 1

let
  digitsI2 = digitsOf(gtI2_S)
  digitsTq2 = digitsOf(gtTQ2_0)
  digitsTq1 = digitsOf(gtTQ1_0)

proc ternary(k: GgmlType): bool = k in {gtI2_S, gtTQ1_0, gtTQ2_0}

proc blockShape(k: GgmlType): tuple[values, bytes, slots, scaleAt: int] =
  ## (a ternary block: its weights, its bytes, the bytes holding weights, where its scale is)
  case k
  of gtI2_S: (128, 32, 32, -1)
  of gtTQ2_0: (256, 66, 64, 64)
  else: (256, 54, 52, 52)

proc places(k: GgmlType; slot: int; at: var array[5, int]): int =
  ## (where in its block each weight of byte `slot` goes; how many it holds)
  case k
  of gtI2_S:
    for n in 0 .. 3: at[n] = n * 32 + slot
    4
  of gtTQ2_0:
    for n in 0 .. 3: at[n] = (slot div 32) * 128 + n * 32 + slot mod 32
    4
  else:
    if slot < 32:
      for n in 0 .. 4: at[n] = n * 32 + slot
      5
    elif slot < 48:
      for n in 0 .. 4: at[n] = 160 + n * 16 + (slot - 32)
      5
    else:
      for n in 0 .. 3: at[n] = 240 + n * 4 + (slot - 48)
      4

proc digitAt(k: GgmlType; b, n: int): int8 {.inline.} =
  case k
  of gtI2_S: digitsI2[b][n]
  of gtTQ2_0: digitsTq2[b][n]
  else: digitsTq1[b][n]

# ---- a row times a vector -------------------------------------------------------------------------------

type
  Vec = ptr UncheckedArray[float32]
  Bytes = ptr UncheckedArray[int8]
  Sums = ptr UncheckedArray[int32]

const llmKernels = currentSourcePath().substr(0, currentSourcePath().rfind({'/', '\\'})) & "simdllm.h"
  ## (the hot loops in C, `simdllm.h`; -d:retroNoSimd the plain ones here)

proc quant8(x: ptr float32; q: ptr int8; n: int): float32 {.importc: "ruk_quant8", header: llmKernels, cdecl.}
proc i2sDot(p: ptr byte; xq: ptr int8; cols: int): int32 {.importc: "ruk_i2s_dot", header: llmKernels, cdecl.}
proc tq2Dot(p: ptr byte; xq: ptr int8; bsum: ptr int32; cols: int): float32
  {.importc: "ruk_tq2_dot", header: llmKernels, cdecl.}
proc tq1Dot(p: ptr byte; xq: ptr int8; bsum: ptr int32; cols: int): float32
  {.importc: "ruk_tq1_dot", header: llmKernels, cdecl.}
proc f16Dot(w: ptr uint16; x: ptr float32; n: int): float32 {.importc: "ruk_f16_dot", header: llmKernels, cdecl.}
proc f32Dot(w: ptr float32; x: ptr float32; n: int): float32 {.importc: "ruk_f32_dot", header: llmKernels, cdecl.}
proc q8Dot(p: ptr byte; x: ptr float32; cols: int): float32 {.importc: "ruk_q8_dot", header: llmKernels, cdecl.}
proc q4Dot(p: ptr byte; x: ptr float32; cols: int): float32 {.importc: "ruk_q4_dot", header: llmKernels, cdecl.}
proc q8iDot(p: ptr byte; xq: ptr int8; xd: ptr float32; cols: int): float32
  {.importc: "ruk_q8i_dot", header: llmKernels, cdecl.}
proc q4iDot(p: ptr byte; xq: ptr int8; xd: ptr float32; cols: int): float32
  {.importc: "ruk_q4i_dot", header: llmKernels, cdecl.}

proc denseDot(m: Mat; r: int; x: Vec): float32 =
  ## (a row of floats or of Q8_0, Q4_0 times the input)
  let p = cast[ptr UncheckedArray[byte]](addr m.data[r * m.rowBytes])
  when not defined(retroNoSimd):
    case m.kind
    of gtF32: return f32Dot(cast[ptr float32](p), addr x[0], m.cols)
    of gtF16: return f16Dot(cast[ptr uint16](p), addr x[0], m.cols)
    of gtQ8_0: return q8Dot(addr p[0], addr x[0], m.cols)
    of gtQ4_0: return q4Dot(addr p[0], addr x[0], m.cols)
    else: discard
  var a0, a1 = 0'f32
  case m.kind
  of gtF32:
    let f = cast[ptr UncheckedArray[float32]](p)
    for c in 0 ..< m.cols: a0 += f[c] * x[c]
  of gtF16:
    for c in 0 ..< m.cols: a0 += h2f(u16(p, 2 * c)) * x[c]
  of gtBF16:
    let h = cast[ptr UncheckedArray[uint16]](p)
    for c in 0 ..< m.cols: a0 += cast[float32](uint32(h[c]) shl 16) * x[c]
  of gtQ8_0:
    for b in 0 ..< m.cols div 32:
      var s = 0'f32
      for i in 0 ..< 32: s += float32(cast[int8](p[b * 34 + 2 + i])) * x[b * 32 + i]
      a0 += h2f(u16(p, b * 34)) * s
  of gtQ4_0:
    for b in 0 ..< m.cols div 32:
      var s = 0'f32
      for j in 0 ..< 16:
        let q = int(p[b * 18 + 2 + j])
        s += float32((q and 15) - 8) * x[b * 32 + j] + float32((q shr 4) - 8) * x[b * 32 + 16 + j]
      a1 += h2f(u16(p, b * 18)) * s
  else: discard
  a0 + a1

proc blockDot(m: Mat; r: int; xq: Bytes; xd: Vec): float32 =
  ## (a Q8_0 or Q4_0 row times the input as whole numbers, a scale each 32)
  let p = cast[ptr UncheckedArray[byte]](addr m.data[r * m.rowBytes])
  when not defined(retroNoSimd):
    result = if m.kind == gtQ8_0: q8iDot(addr p[0], addr xq[0], addr xd[0], m.cols)
             else: q4iDot(addr p[0], addr xq[0], addr xd[0], m.cols)
  else:
    for b in 0 ..< m.cols div 32:
      var t = 0'i32
      if m.kind == gtQ8_0:
        for i in 0 ..< 32: t += int32(cast[int8](p[b * 34 + 2 + i])) * int32(xq[b * 32 + i])
        result += h2f(u16(p, b * 34)) * xd[b] * float32(t)
      else:
        for j in 0 ..< 16:
          let q = int32(p[b * 18 + 2 + j])
          t += ((q and 15) - 8) * int32(xq[b * 32 + j]) + ((q shr 4) - 8) * int32(xq[b * 32 + 16 + j])
        result += h2f(u16(p, b * 18)) * xd[b] * float32(t)

proc ternaryDot(m: Mat; r: int; xq: Bytes; sums: Sums; all: int32): float32 =
  ## (a ternary row times the input as whole numbers; its sum block by block, and in all)
  let p = cast[ptr UncheckedArray[byte]](addr m.data[r * m.rowBytes])
  when not defined(retroNoSimd):
    case m.kind
    of gtI2_S: return float32(i2sDot(addr p[0], addr xq[0], m.cols) - all)
    of gtTQ2_0: return tq2Dot(addr p[0], addr xq[0], addr sums[0], m.cols)
    of gtTQ1_0: return tq1Dot(addr p[0], addr xq[0], addr sums[0], m.cols)
    else: discard
  let (values, bytes, slots, scaleAt) = blockShape(m.kind)
  var at: array[5, int]
  for b in 0 ..< m.cols div values:
    var t = 0'i32
    for s in 0 ..< slots:
      let n = places(m.kind, s, at)
      let v = int(p[b * bytes + s])
      for k in 0 ..< n: t += int32(digitAt(m.kind, v, k)) * int32(xq[b * values + at[k]])
    result += (if scaleAt >= 0: h2f(u16(p, b * bytes + scaleAt)) else: 1'f32) * float32(t)

# ---- the model's own threads ----------------------------------------------------------------------------

type
  Work = object
    ## (the rows of up to three matrices, shared out)
    mats: array[3, Mat]
    outs: array[3, Vec]
    x: Vec
    xq: Bytes                    ## (the input as whole numbers, for ternary rows, Q8_0's, Q4_0's)
    xd: Vec                      ## (... Q8_0's and Q4_0's: the scale of each 32)
    sums: Sums                   ## (... its sums, 256 at a time)
    all: int32                   ## (... its sum)
    xScale: float32              ## (... back to what it was)
    rowsEnd: array[3, int]       ## (the matrices' rows, end to end)

proc runRows(w: ptr Work; lo, hi: int) =
  var mi = 0
  var start = 0
  for r in lo ..< hi:
    while r >= w.rowsEnd[mi]:
      start = w.rowsEnd[mi]
      inc mi
    let m = w.mats[mi]
    w.outs[mi][r - start] =
      if w.xd != nil: m.blockDot(r - start, w.xq, w.xd) * m.scale
      elif w.xq != nil: m.ternaryDot(r - start, w.xq, w.sums, w.all) * w.xScale * m.scale
      else: m.denseDot(r - start, w.x) * m.scale

var llmThreadsWanted = 0

proc setLlmThreads*(n: int) =
  ## The threads a model works with (0: as many as `threadCount` -- a core each, or
  ## $RETRO_THREADS). Before the first model runs.
  llmThreadsWanted = max(0, n)

type Fn = proc (w: ptr Work; lo, hi: int) {.nimcall, gcsafe.}

when compileOption("threads"):
  var
    pLock, pUse: Lock
    pWake, pDone: Cond
    pGen, pActive: int
    pFn: Fn
    pArg: ptr Work
    pN, pChunk: int
    pNext, pLeft: Atomic[int]
    pThreads: seq[Thread[void]]
    pStarted: bool

  proc pieces(fn: Fn; w: ptr Work; n, chunk: int) =
    while true:
      let c = pNext.fetchAdd(1)
      let lo = c * chunk
      if lo >= n: break
      fn(w, lo, min(n, lo + chunk))
      if pLeft.fetchSub(1) == 1:
        withLock pLock: broadcast(pDone)

  proc poolWork() {.thread.} =
    var seen = 0
    while true:
      acquire(pLock)
      while pGen == seen: wait(pWake, pLock)
      seen = pGen
      inc pActive
      let (fn, w, n, chunk) = (pFn, pArg, pN, pChunk)
      release(pLock)
      {.cast(gcsafe).}: pieces(fn, w, n, chunk)
      acquire(pLock)
      dec pActive
      broadcast(pDone)
      release(pLock)

  proc poolStart() =
    if pStarted: return
    pStarted = true
    initLock(pLock)
    initLock(pUse)
    initCond(pWake)
    initCond(pDone)
    let n = (if llmThreadsWanted > 0: llmThreadsWanted else: threadCount()) - 1
    pThreads.setLen(max(0, n))
    for i in 0 ..< pThreads.len: createThread(pThreads[i], poolWork)

proc share(fn: Fn; w: ptr Work; n, grain: int) =
  ## (`fn` on pieces of `0 ..< n`, on the model's threads and this one)
  when compileOption("threads"):
    if pThreads.len == 0 or n < 2 * grain:
      fn(w, 0, n)
      return
    let parts = 4 * (pThreads.len + 1)
    let chunk = max(grain, (n + parts - 1) div parts)
    acquire(pLock)
    while pActive > 0: wait(pDone, pLock)          # (the last work's late threads)
    pFn = fn
    pArg = w
    pN = n
    pChunk = chunk
    pNext.store(0)
    pLeft.store((n + chunk - 1) div chunk)
    inc pGen
    broadcast(pWake)
    release(pLock)
    pieces(fn, w, n, chunk)
    acquire(pLock)
    while pLeft.load > 0: wait(pDone, pLock)
    release(pLock)
  else:
    fn(w, 0, n)

var
  xqBuf: seq[int8]               ## (the input as whole numbers: one model works at a time)
  sumBuf: seq[int32]
  xdBuf: seq[float32]

proc mulAll(ms: openArray[Mat]; x: var seq[float32]; outs: openArray[ptr seq[float32]]) =
  ## (each of `ms` times `x`, into `outs`: their rows shared out at once)
  var w = Work(x: cast[Vec](addr x[0]))
  var rows = 0
  for i, m in ms:
    w.mats[i] = m
    w.outs[i] = cast[Vec](addr outs[i][][0])
    rows += m.rows
    w.rowsEnd[i] = rows
  for i in ms.len .. 2: w.rowsEnd[i] = high(int)
  if ternary(ms[0].kind):
    # (as BitNet b1.58 was taught: the input as whole numbers, -127 .. 127, one scale)
    xqBuf.setLen(x.len)
    sumBuf.setLen((x.len + 255) div 256)
    w.xScale = quant8(addr x[0], addr xqBuf[0], x.len)
    for b in 0 ..< sumBuf.len:
      var t = 0'i32
      for i in b * 256 ..< min(x.len, b * 256 + 256): t += int32(xqBuf[i])
      sumBuf[b] = t
      w.all += t
    w.xq = cast[Bytes](addr xqBuf[0])
    w.sums = cast[Sums](addr sumBuf[0])
  elif ms[0].kind in {gtQ8_0, gtQ4_0} and x.len mod 32 == 0:
    # (as llama.cpp does: the input whole numbers too, a scale each 32)
    xqBuf.setLen(x.len)
    xdBuf.setLen(x.len div 32)
    for b in 0 ..< xdBuf.len: xdBuf[b] = quant8(addr x[b * 32], addr xqBuf[b * 32], 32)
    w.xq = cast[Bytes](addr xqBuf[0])
    w.xd = cast[Vec](addr xdBuf[0])
  share(runRows, addr w, rows, 16)

proc mul(m: Mat; x: var seq[float32]; into: var seq[float32]) =
  mulAll([m], x, [addr into])

proc rowOf(m: Mat; r: int; into: var seq[float32]) =
  ## Row `r` of `m` as numbers (a token's embedding).
  into.setLen(m.cols)
  let p = cast[ptr UncheckedArray[byte]](addr m.data[r * m.rowBytes])
  case m.kind
  of gtF32:
    let f = cast[ptr UncheckedArray[float32]](p)
    for c in 0 ..< m.cols: into[c] = f[c]
  of gtF16:
    for c in 0 ..< m.cols: into[c] = h2f(u16(p, 2 * c))
  of gtBF16:
    for c in 0 ..< m.cols: into[c] = cast[float32](uint32(u16(p, 2 * c)) shl 16)
  of gtQ8_0:
    for b in 0 ..< m.cols div 32:
      let d = h2f(u16(p, b * 34))
      for i in 0 ..< 32: into[b * 32 + i] = d * float32(cast[int8](p[b * 34 + 2 + i]))
  of gtQ4_0:
    for b in 0 ..< m.cols div 32:
      let d = h2f(u16(p, b * 18))
      for j in 0 ..< 16:
        let q = int(p[b * 18 + 2 + j])
        into[b * 32 + j] = d * float32((q and 15) - 8)
        into[b * 32 + 16 + j] = d * float32((q shr 4) - 8)
  of gtI2_S, gtTQ1_0, gtTQ2_0:
    let (values, bytes, slots, scaleAt) = blockShape(m.kind)
    var at: array[5, int]
    for b in 0 ..< m.cols div values:
      let d = (if scaleAt >= 0: h2f(u16(p, b * bytes + scaleAt)) else: 1'f32) * m.scale
      for s in 0 ..< slots:
        let n = places(m.kind, s, at)
        let byt = int(p[b * bytes + s])
        for k in 0 ..< n: into[b * values + at[k]] = d * float32(digitAt(m.kind, byt, k))
  else: discard

# ---- loading ------------------------------------------------------------------------------------------------

proc kindName(k: GgmlType): string = ($k)[2 .. ^1]

proc matOf(g: Gguf; name: string; scaleName = ""): Mat =
  let t = g.tensor(name)
  if t.dims.len != 2: fail(name & " is not a matrix")
  result = Mat(kind: t.kind, cols: t.dims[0], rows: t.dims[1], data: t.data, scale: 1)
  case t.kind
  of gtF32, gtF16, gtBF16, gtQ8_0, gtQ4_0, gtTQ1_0, gtTQ2_0: result.rowBytes = bytesOf(t.kind, result.cols)
  of gtI2_S:
    result.rowBytes = if result.cols mod 128 == 0: result.cols div 4 else: -1
    if result.rowBytes > 0: result.scale = cast[ptr float32](addr t.data[result.rows * result.rowBytes])[]
  else: fail(name & " is of a kind not run here (" & kindName(t.kind) & ")")
  if result.rowBytes <= 0: fail(name & ": its rows are not whole blocks")
  if scaleName.len > 0 and g.hasTensor(scaleName):
    let s = g.tensor(scaleName)
    if s.kind == gtF32: result.scale *= cast[ptr float32](s.data)[]

proc vecOf(g: Gguf; name: string; need = true): seq[float32] =
  if not need and not g.hasTensor(name): return
  let t = g.tensor(name)
  var n = 1
  for d in t.dims: n *= d
  result = newSeq[float32](n)
  case t.kind
  of gtF32:
    let f = cast[ptr UncheckedArray[float32]](t.data)
    for i in 0 ..< n: result[i] = f[i]
  of gtF16:
    for i in 0 ..< n: result[i] = h2f(u16(t.data, 2 * i))
  else: fail(name & " is of a kind not read here (" & kindName(t.kind) & ")")

var llmContextMost* = 4096
  ## The most tokens a conversation keeps (a model that reads more is held to it): its keys and
  ## values take memory -- BitNet b1.58 2B's about 150 KB a token, Qwen3 1.7B's 230 KB -- and the
  ## oldest turns are let go past it (`chat`). Set before `loadLlm`.

const llmArchs* = ["llama", "mistral", "qwen2", "qwen3", "bitnet", "bitnet-25", "bitnet-b1.58"]
  ## The architectures run here.

proc formOf(g: Gguf; tok: Tokenizer; arch: string): ChatForm =
  let tpl = g.strOf("tokenizer.chat_template")
  if "<|start_header_id|>" in tpl: cfLlama3
  elif "<|im_start|>" in tpl: cfChatMl
  elif "capitalize" in tpl or "Assistant: " in tpl or arch in ["bitnet-b1.58", "bitnet-25"]: cfRoles
  elif tok.id("<|start_header_id|>") >= 0: cfLlama3
  elif tok.id("<|im_start|>") >= 0: cfChatMl
  else: cfRoles

proc loadLlm*(path: string): Llm =
  ## The model in the GGUF file at `path`. Raises `LlmError` (or `GgufError`) when it is not one
  ## run here: its architecture, or a kind of weights.
  let g = openGguf(path)
  try:
    let a = g.strOf("general.architecture")
    if a notin llmArchs:
      fail("models of the kind \"" & a & "\" are not run here (" & llmArchs.join(", ") & ")")
    result = Llm(g: g, path: path, arch: a, name: g.strOf("general.name"))
    result.nEmbd = g.intOf(a & ".embedding_length")
    result.nLayer = g.intOf(a & ".block_count")
    result.nHead = g.intOf(a & ".attention.head_count")
    result.nHeadKv = g.intOf(a & ".attention.head_count_kv", result.nHead)
    result.nFf = g.intOf(a & ".feed_forward_length")
    result.ctxMax = clamp(g.intOf(a & ".context_length", 2048), 16, llmContextMost)
    result.ropeBase = float32(g.floatOf(a & ".rope.freq_base", 10000))
    result.rmsEps = float32(g.floatOf(a & ".attention.layer_norm_rms_epsilon", 1e-5))
    if result.nEmbd <= 0 or result.nLayer <= 0 or result.nHead <= 0 or result.nHeadKv <= 0 or
       result.nFf <= 0 or result.nHead mod result.nHeadKv != 0:
      fail("the model's sizes do not hold together")
    result.headDim = g.intOf(a & ".attention.key_length", result.nEmbd div result.nHead)
    if result.headDim <= 0 or result.headDim mod 2 != 0 or
       g.intOf(a & ".attention.value_length", result.headDim) != result.headDim:
      fail("the model's sizes do not hold together")
    let pool = g.intOf(a & ".pooling_type", 3)
    result.pooling = if pool in 1 .. 3: LlmPooling(pool) else: poolLast
    result.neox = a.startsWith("bitnet") or a in ["qwen2", "qwen3"]
    result.act = if a in ["bitnet-b1.58", "bitnet-25"]: actReluSquared else: actSilu
    result.tok = tokenizerOf(g)
    result.form = formOf(g, result.tok, a)
    result.tokEmbd = g.matOf("token_embd.weight")
    result.nVocab = result.tokEmbd.rows
    result.output = if g.hasTensor("output.weight"): g.matOf("output.weight") else: result.tokEmbd
    if result.output.cols != result.nEmbd or result.tokEmbd.cols != result.nEmbd:
      fail("the model's sizes do not hold together")
    result.outNorm = g.vecOf("output_norm.weight")
    result.ropeFreqs = g.vecOf("rope_freqs.weight", need = false)
    let kv = result.nHeadKv * result.headDim
    let qd = result.nHead * result.headDim
    for i in 0 ..< result.nLayer:
      let p = "blk." & $i & "."
      var L = LlmLayer(attnNorm: g.vecOf(p & "attn_norm.weight"), ffnNorm: g.vecOf(p & "ffn_norm.weight"),
                       attnSubNorm: g.vecOf(p & "attn_sub_norm.weight", need = false),
                       ffnSubNorm: g.vecOf(p & "ffn_sub_norm.weight", need = false),
                       bq: g.vecOf(p & "attn_q.bias", need = false), bk: g.vecOf(p & "attn_k.bias", need = false),
                       bv: g.vecOf(p & "attn_v.bias", need = false),
                       bo: g.vecOf(p & "attn_output.bias", need = false),
                       qNorm: g.vecOf(p & "attn_q_norm.weight", need = false),
                       kNorm: g.vecOf(p & "attn_k_norm.weight", need = false))
      L.wq = g.matOf(p & "attn_q.weight", p & "attn_q.scale")
      L.wk = g.matOf(p & "attn_k.weight", p & "attn_k.scale")
      L.wv = g.matOf(p & "attn_v.weight", p & "attn_v.scale")
      L.wo = g.matOf(p & "attn_output.weight", p & "attn_output.scale")
      L.gate = g.matOf(p & "ffn_gate.weight", p & "ffn_gate.scale")
      L.up = g.matOf(p & "ffn_up.weight", p & "ffn_up.scale")
      L.down = g.matOf(p & "ffn_down.weight", p & "ffn_down.scale")
      if L.wq.rows != qd or L.wk.rows != kv or L.wv.rows != kv or L.wo.cols != qd or
         L.wo.rows != result.nEmbd or L.wk.cols != result.nEmbd or L.wv.cols != result.nEmbd or
         L.gate.rows != result.nFf or L.up.rows != result.nFf or L.down.cols != result.nFf or
         L.wq.cols != result.nEmbd or L.down.rows != result.nEmbd or L.attnNorm.len != result.nEmbd or
         L.gate.cols != result.nEmbd or L.up.cols != result.nEmbd or L.ffnNorm.len != result.nEmbd or
         (L.attnSubNorm.len > 0 and L.attnSubNorm.len != qd) or
         (L.ffnSubNorm.len > 0 and L.ffnSubNorm.len != result.nFf) or
         (L.qNorm.len > 0 and L.qNorm.len != result.headDim) or
         (L.kNorm.len > 0 and L.kNorm.len != result.headDim) or
         (L.bq.len > 0 and L.bq.len != qd) or (L.bk.len > 0 and L.bk.len != kv) or
         (L.bv.len > 0 and L.bv.len != kv) or (L.bo.len > 0 and L.bo.len != result.nEmbd):
        fail("layer " & $i & "'s sizes do not hold together")
      result.layers.add L
  except CatchableError:
    g.close()
    raise

proc close*(m: Llm) =
  ## Lets go of the model's file.
  if m != nil and m.g != nil: m.g.close()

proc describe*(m: Llm): string =
  ## A line of what the model is.
  m.g.describe()

proc newLlmState*(m: Llm; seed = 1): LlmState =
  ## A new conversation with `m` (nothing read yet).
  result = LlmState(m: m, rng: initRand(seed))
  result.kc.setLen(m.nLayer)
  result.vc.setLen(m.nLayer)
  let kv = m.nHeadKv * m.headDim
  result.x = newSeq[float32](m.nEmbd)
  result.xb = newSeq[float32](m.nEmbd)
  result.xb2 = newSeq[float32](m.nEmbd)
  result.att = newSeq[float32](m.nHead * m.headDim)
  result.q = newSeq[float32](m.nHead * m.headDim)
  result.k = newSeq[float32](kv)
  result.v = newSeq[float32](kv)
  result.hb = newSeq[float32](m.nFf)
  result.hb2 = newSeq[float32](m.nFf)
  result.logits = newSeq[float32](m.nVocab)

proc reset*(s: LlmState) =
  ## Forgets what was read (a new conversation).
  s.pos = 0
  s.tokens.setLen(0)
  for i in 0 ..< s.kc.len:
    s.kc[i].setLen(0)
    s.vc[i].setLen(0)

proc rewind*(s: LlmState; n: int) =
  ## Forgets all but the first `n` tokens read (the same conversation, from there).
  let n = clamp(n, 0, s.pos)
  let kv = s.m.nHeadKv * s.m.headDim
  for i in 0 ..< s.kc.len:
    s.kc[i].setLen(n * kv)
    s.vc[i].setLen(n * kv)
  s.pos = n
  s.tokens.setLen(n)

# ---- one token through the model ----------------------------------------------------------------------

proc rmsNorm(x: var seq[float32]; w: seq[float32]; eps: float32; into: var seq[float32]) =
  var ss = 0'f32
  for v in x: ss += v * v
  let k = 1'f32 / sqrt(ss / float32(x.len) + eps)
  for i in 0 ..< x.len: into[i] = x[i] * k * w[i]

proc normHeads(v: var seq[float32]; heads, hd: int; w: seq[float32]; eps: float32) =
  ## (each head's part normed on its own: Qwen 3's)
  if w.len == 0: return
  for h in 0 ..< heads:
    var ss = 0'f32
    for i in 0 ..< hd: ss += v[h * hd + i] * v[h * hd + i]
    let k = 1'f32 / sqrt(ss / float32(hd) + eps)
    for i in 0 ..< hd: v[h * hd + i] = v[h * hd + i] * k * w[i]

proc addTo(v: var seq[float32]; b: seq[float32]) =
  if b.len == v.len:
    for i in 0 ..< v.len: v[i] += b[i]

proc rope(m: Llm; v: var seq[float32]; heads, pos: int) =
  let hd = m.headDim
  for i in 0 ..< hd div 2:
    var theta = float32(pos) * pow(m.ropeBase, -2'f32 * float32(i) / float32(hd))
    if i < m.ropeFreqs.len and m.ropeFreqs[i] != 0: theta /= m.ropeFreqs[i]
    let (c, s) = (cos(theta), sin(theta))
    for h in 0 ..< heads:
      let o = h * hd
      let (i0, i1) = if m.neox: (o + i, o + i + hd div 2) else: (o + 2 * i, o + 2 * i + 1)
      let (x0, x1) = (v[i0], v[i1])
      v[i0] = x0 * c - x1 * s
      v[i1] = x0 * s + x1 * c

proc step*(s: LlmState; token: int; scores = true) =
  ## Reads one token: the next token's scores in `s.logits` (`scores` false: not worked out --
  ## a text read for `embed`, or a prompt but its last token), and its vector, the model's last
  ## layer normed, in `s.hidden`. Raises `LlmError` when the conversation is as long as the
  ## model reads, or `token` is not one of its own.
  let m = s.m
  if s.pos >= m.ctxMax: fail("the conversation is as long as the model reads (" & $m.ctxMax & " tokens)")
  if token < 0 or token >= m.nVocab: fail("token " & $token & " is not one of the model's")
  when compileOption("threads"):
    poolStart()
    acquire(pUse)
  try:
    m.tokEmbd.rowOf(token, s.x)
    let hd = m.headDim
    let kvDim = m.nHeadKv * hd
    let group = m.nHead div m.nHeadKv
    let n = s.pos + 1
    let scale = 1'f32 / sqrt(float32(hd))
    var w = newSeq[float32](n)
    for li in 0 ..< m.nLayer:
      let L = addr m.layers[li]
      rmsNorm(s.x, L.attnNorm, m.rmsEps, s.xb)
      if L.wq.kind == L.wk.kind and L.wk.kind == L.wv.kind:
        mulAll([L.wq, L.wk, L.wv], s.xb, [addr s.q, addr s.k, addr s.v])
      else:
        mul(L.wq, s.xb, s.q)
        mul(L.wk, s.xb, s.k)
        mul(L.wv, s.xb, s.v)
      s.q.addTo L.bq
      s.k.addTo L.bk
      s.v.addTo L.bv
      s.q.normHeads(m.nHead, hd, L.qNorm, m.rmsEps)
      s.k.normHeads(m.nHeadKv, hd, L.kNorm, m.rmsEps)
      m.rope(s.q, m.nHead, s.pos)
      m.rope(s.k, m.nHeadKv, s.pos)
      s.kc[li].add s.k
      s.vc[li].add s.v
      let kc = cast[Vec](addr s.kc[li][0])
      let vc = cast[Vec](addr s.vc[li][0])
      for h in 0 ..< m.nHead:
        let ko = (h div group) * hd
        let qo = h * hd
        var top = -Inf.float32
        for t in 0 ..< n:
          var d = 0'f32
          let kt = t * kvDim + ko
          for i in 0 ..< hd: d += s.q[qo + i] * kc[kt + i]
          w[t] = d * scale
          top = max(top, w[t])
        var sum = 0'f32
        for t in 0 ..< n:
          w[t] = exp(w[t] - top)
          sum += w[t]
        for i in 0 ..< hd: s.att[qo + i] = 0
        for t in 0 ..< n:
          let a = w[t] / sum
          let vt = t * kvDim + ko
          for i in 0 ..< hd: s.att[qo + i] += a * vc[vt + i]
      if L.attnSubNorm.len > 0: rmsNorm(s.att, L.attnSubNorm, m.rmsEps, s.att)
      mul(L.wo, s.att, s.xb2)
      s.xb2.addTo L.bo
      for i in 0 ..< m.nEmbd: s.x[i] += s.xb2[i]
      rmsNorm(s.x, L.ffnNorm, m.rmsEps, s.xb)
      if L.gate.kind == L.up.kind: mulAll([L.gate, L.up], s.xb, [addr s.hb, addr s.hb2])
      else:
        mul(L.gate, s.xb, s.hb)
        mul(L.up, s.xb, s.hb2)
      for i in 0 ..< m.nFf:
        let g = s.hb[i]
        let a = case m.act
                of actSilu: g / (1'f32 + exp(-g))
                of actReluSquared: (let r = max(g, 0'f32); r * r)
        s.hb[i] = a * s.hb2[i]
      if L.ffnSubNorm.len > 0: rmsNorm(s.hb, L.ffnSubNorm, m.rmsEps, s.hb)
      mul(L.down, s.hb, s.xb2)
      for i in 0 ..< m.nEmbd: s.x[i] += s.xb2[i]
    rmsNorm(s.x, m.outNorm, m.rmsEps, s.xb)
    if scores: mul(m.output, s.xb, s.logits)
  finally:
    when compileOption("threads"): release(pUse)
  inc s.pos
  s.tokens.add token

proc hidden*(s: LlmState): lent seq[float32] =
  ## The last token's vector: the model's last layer, normed (what its scores are made of).
  s.xb

proc embed*(m: Llm; s: LlmState; text: string): seq[float32] =
  ## `text` as one vector of the model's, its length 1: texts alike in meaning have vectors near
  ## each other (`similarity`). The vectors of its tokens made one as the model says
  ## (`pooling`: Qwen 3 Embedding's, the last). A model made for this is asked a query as it
  ## was taught ("Instruct: Find the mail that answers the question\nQuery: ..."); `s` is
  ## left empty.
  s.reset()
  var ids = m.tok.encode(text, special = false, bos = true)
  if m.tok.addEos: ids.add m.tok.eos
  if ids.len == 0: ids.add max(0, m.tok.eos)
  if ids.len > m.ctxMax: ids.setLen(m.ctxMax)
  result = newSeq[float32](m.nEmbd)
  for i, t in ids:
    s.step(t, scores = false)
    case m.pooling
    of poolMean:
      for j in 0 ..< m.nEmbd: result[j] += s.xb[j]
    of poolFirst:
      if i == 0: result = s.xb
    of poolLast:
      if i == ids.high: result = s.xb
  var n = 0'f32
  for v in result: n += v * v
  if n > 0:
    let k = 1'f32 / sqrt(n)
    for v in result.mitems: v *= k
  s.reset()

proc similarity*(a, b: openArray[float32]): float32 =
  ## How near two of `embed`'s vectors are: 1 the same way, 0 unrelated, -1 opposite.
  for i in 0 ..< min(a.len, b.len): result += a[i] * b[i]

# ---- choosing the next token ----------------------------------------------------------------------------

type Sampling* = object
  ## How the next token is chosen: `temperature` 0 the likeliest always; else drawn among the
  ## `topK` likeliest that make `topP` of the chance, the last `repeatLast` tokens made less
  ## likely by `repeatPenalty`.
  temperature*: float32
  topK*: int
  topP*: float32
  repeatPenalty*: float32
  repeatLast*: int

proc sampling*(temperature = 0.7; topK = 40; topP = 0.9; repeatPenalty = 1.1; repeatLast = 64): Sampling =
  ## The usual way: some chance, little repeating.
  Sampling(temperature: temperature, topK: max(1, topK), topP: topP, repeatPenalty: repeatPenalty,
           repeatLast: repeatLast)

proc pick*(s: LlmState; how = sampling()): int =
  ## The next token, from `s.logits`.
  var lg = s.logits
  if how.repeatPenalty > 0 and how.repeatPenalty != 1:
    for i in max(0, s.tokens.len - how.repeatLast) ..< s.tokens.len:
      let t = s.tokens[i]
      lg[t] = if lg[t] > 0: lg[t] / how.repeatPenalty else: lg[t] * how.repeatPenalty
  if how.temperature <= 0:
    var best = 0
    for i in 1 ..< lg.len:
      if lg[i] > lg[best]: best = i
    return best
  # (the topK likeliest, likeliest first)
  let k = min(max(1, how.topK), lg.len)
  var ids = newSeqOfCap[int](k + 1)
  for i, v in lg:
    if ids.len == k and v <= lg[ids[^1]]: continue
    var at = ids.len
    while at > 0 and lg[ids[at - 1]] < v: dec at
    ids.insert(i, at)
    if ids.len > k: ids.setLen(k)
  var ps = newSeq[float32](ids.len)
  var sum = 0'f32
  for j, i in ids:
    ps[j] = exp((lg[i] - lg[ids[0]]) / how.temperature)
    sum += ps[j]
  var cut = ids.len
  var acc = 0'f32
  for j in 0 ..< ids.len:
    acc += ps[j] / sum
    if acc >= how.topP:
      cut = j + 1
      break
  var total = 0'f32
  for j in 0 ..< cut: total += ps[j]
  var r = float32(s.rng.rand(1.0)) * total
  for j in 0 ..< cut:
    r -= ps[j]
    if r <= 0: return ids[j]
  ids[0]

proc stops(m: Llm; t: int): bool =
  t == m.tok.eos or t == m.tok.eot or t in m.tok.special

proc wholeLen(s: string): int =
  ## (how much of `s` is whole UTF-8 letters: a token may end inside one)
  var i = s.len - 1
  var back = 0
  while i >= 0 and back < 4 and (ord(s[i]) and 0xC0) == 0x80:
    dec i
    inc back
  if i < 0: return s.len
  let c = ord(s[i])
  let need = if c < 0x80: 1 elif c shr 5 == 6: 2 elif c shr 4 == 14: 3 elif c shr 3 == 30: 4 else: 1
  if back + 1 >= need: s.len else: i

proc sane*(s: string): string =
  ## `s` with what is not UTF-8 in it (a model's stray bytes) as U+FFFD.
  var i = 0
  while i < s.len:
    let c = ord(s[i])
    let n = if c < 0x80: 1 elif c shr 5 == 6: 2 elif c shr 4 == 14: 3 elif c shr 3 == 30: 4 else: 0
    var ok = n > 0 and i + n <= s.len
    if ok:
      for k in 1 ..< n:
        if (ord(s[i + k]) and 0xC0) != 0x80: ok = false
    if ok:
      result.add s[i ..< i + n]
      i += n
    else:
      result.add "\uFFFD"
      inc i

proc generate*(s: LlmState; prompt: openArray[int]; maxTokens = 256; how = sampling();
               onText: proc (text: string): bool {.closure.} = nil): seq[int] =
  ## Reads `prompt` and writes up to `maxTokens` tokens after it, until the model's end or the
  ## conversation's; its text to `onText` as it comes, in whole letters (`sane`; false back:
  ## stop).
  ## The tokens written.
  let m = s.m
  for i, t in prompt:
    if s.pos >= m.ctxMax: return
    s.step(t, scores = i == prompt.high)
  var held = ""
  for i in 0 ..< maxTokens:
    let t = s.pick(how)
    if m.stops(t): break
    result.add t
    if onText != nil:
      held.add m.tok.piece(t)
      let n = wholeLen(held)
      if n > 0:
        let ok = onText(sane(held[0 ..< n]))
        held = held[n .. ^1]
        if not ok: break
    if s.pos >= m.ctxMax: break
    s.step(t)
  if onText != nil and held.len > 0: discard onText(sane(held))

# ---- conversations --------------------------------------------------------------------------------------

type ChatTurn* = tuple[role, text: string]
  ## ("system", "user" or "assistant"; its words)

proc chatPrompt*(m: Llm; turns: openArray[ChatTurn]; answer = true): string =
  ## The conversation as the model was taught to read it, the assistant's turn begun
  ## (`answer`).
  let eot = if m.tok.eot >= 0: m.tok.tokens[m.tok.eot] else: "\n"
  for x in turns:
    case m.form
    of cfLlama3: result.add "<|start_header_id|>" & x.role & "<|end_header_id|>\n\n" & x.text.strip & "<|eot_id|>"
    of cfChatMl: result.add "<|im_start|>" & x.role & "\n" & x.text.strip & "<|im_end|>\n"
    of cfRoles: result.add capitalizeAscii(x.role) & ": " & x.text.strip & eot
  if answer:
    case m.form
    of cfLlama3: result.add "<|start_header_id|>assistant<|end_header_id|>\n\n"
    of cfChatMl:
      result.add "<|im_start|>assistant\n"
      # (Qwen 3 with its thinking off, as its own template does it: the thought left empty)
      if m.arch == "qwen3" and not m.think: result.add "<think>\n\n</think>\n\n"
    of cfRoles: result.add "Assistant: "

proc thoughtLess*(text: string): string =
  ## `text` without a model's thinking (<think> ... </think>).
  result = text
  while true:
    let a = result.find("<think>")
    if a < 0: break
    let b = result.find("</think>", a)
    result = if b < 0: result[0 ..< a] else: result[0 ..< a] & result[b + 8 .. ^1]
  result = result.strip

proc chat*(m: Llm; s: LlmState; turns: openArray[ChatTurn]; maxTokens = 256; how = sampling();
           onText: proc (text: string): bool {.closure.} = nil): string =
  ## The model's answer to the conversation `turns`, in `s`: what `s` has read already of the
  ## same conversation is kept (the next answer comes sooner), the rest read. The answer is
  ## `sane`.
  var t = @turns
  var ids = m.tok.encode(m.chatPrompt(t), special = true, bos = true)
  # (longer than the model reads: the oldest turns left out, what the system says kept)
  let keepFirst = if t.len > 0 and t[0].role == "system": 1 else: 0
  while ids.len + maxTokens > m.ctxMax and t.len > keepFirst + 1:
    t.delete(keepFirst)
    ids = m.tok.encode(m.chatPrompt(t), special = true, bos = true)
  if ids.len >= m.ctxMax: ids = ids[ids.len - m.ctxMax div 2 .. ^1]
  var same = 0
  while same < min(ids.len, s.tokens.len) and ids[same] == s.tokens[same]: inc same
  if same == ids.len and same > 0: dec same            # (the last token read again: its scores)
  s.rewind(same)
  sane(m.tok.decode(s.generate(ids[same .. ^1], maxTokens, how, onText))).strip

proc chat*(m: Llm; s: LlmState; system, user: string; maxTokens = 256; how = sampling();
           onText: proc (text: string): bool {.closure.} = nil): string =
  ## One answer to `user`, `system` first.
  var turns: seq[ChatTurn]
  if system.len > 0: turns.add ("system", system)
  turns.add ("user", user)
  m.chat(s, turns, maxTokens, how, onText)

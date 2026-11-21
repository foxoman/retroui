## Image models run by the app itself: an ONNX file's graph of operations (`retroui/onnx`)
## worked out in Nim -- convolutions, attention, normalizations, resizing -- with the kit's own
## threads and vectors. What the photo tools' models need (Segment Anything's, Depth Anything's,
## LaMa's, an upscaler's, PaddleOCR's), downloaded from the model store (`retroui/modelstore`).
##
## .. code-block:: nim
##   let net = loadNet(modelPath(storeModel("depth-anything-small")))
##   let outs = net.run({"pixel_values": imageTensor(picture, 518, 518, mean, std)})
##   let depth = outs["predicted_depth"]
##
## Tensors are floats (and whole numbers for shapes and indices), dense, the last size the
## fastest (NCHW for pictures). The operations of ONNX's default domain that such models use --
## not all of ONNX: a model with another stops with its name (`NetError`).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[math, tables, strutils, algorithm, monotimes, times, os]
import onnx, gpucompute
export onnx

when compileOption("threads"):
  import std/[locks, atomics, cpuinfo]

type
  Tensor* = object
    ## Numbers and their sizes: floats in `f`, or whole numbers in `i` (`isInt`).
    dims*: seq[int]
    f*: seq[float32]
    i*: seq[int64]
    isInt*: bool

  Net* = ref object
    ## A model, loaded: its graph and weights.
    model*: OnnxModel
    path*: string
    weights: Table[string, Tensor]   # (the file's, as tensors: once)
    prepared: bool                   # (`prepare`: the graph made quicker, once)

  NetError* = object of CatchableError

proc fail(msg: string) {.noreturn.} = raise newException(NetError, msg)

# ---- the runner's own threads ---------------------------------------------------------------------------
# (as `retroui/llm`'s: a model runs in a job, and the kit's pool of cores belongs to the drawing
# thread; one model works at a time -- `run` holds `nUse` -- its pieces shared among these)

type NetBody = proc (lo, hi: int) {.closure.}

var netThreadsWanted = 0

proc setNetThreads*(n: int) =
  ## The threads a model runs on (0: one a core, or $RETRO_THREADS). Before the first runs.
  netThreadsWanted = max(0, n)

when compileOption("threads"):
  var
    nLock, nUse: Lock
    nWake, nDone: Cond
    nGen, nActive: int
    nBody: ptr NetBody
    nN, nChunk: int
    nNext, nLeft: Atomic[int]
    nFailed: Atomic[bool]
    nThreads: seq[Thread[void]]
    nStarted: Atomic[bool]
    nStartLock: Lock
  initLock(nStartLock)

  proc nPieces(body: ptr NetBody; n, chunk: int) =
    while true:
      let c = nNext.fetchAdd(1)
      let lo = c * chunk
      if lo >= n: break
      try: body[](lo, min(n, lo + chunk))
      except CatchableError: nFailed.store(true)
      if nLeft.fetchSub(1) == 1:
        withLock nLock: broadcast(nDone)

  proc nWork() {.thread.} =
    var seen = 0
    while true:
      acquire(nLock)
      while nGen == seen: wait(nWake, nLock)
      seen = nGen
      inc nActive
      let (b, n, chunk) = (nBody, nN, nChunk)
      release(nLock)
      {.cast(gcsafe).}: nPieces(b, n, chunk)
      acquire(nLock)
      dec nActive
      broadcast(nDone)
      release(nLock)

  proc nStart() =
    if nStarted.load: return
    withLock nStartLock:
      if nStarted.load: return
      initLock(nLock)
      initLock(nUse)
      initCond(nWake)
      initCond(nDone)
      var k = netThreadsWanted
      if k <= 0: k = try: parseInt(getEnv("RETRO_THREADS", "0")) except ValueError: 0
      if k <= 0: k = countProcessors()
      nThreads.setLen(clamp(k, 1, 32) - 1)
      for i in 0 ..< nThreads.len: createThread(nThreads[i], nWork)
      nStarted.store(true)

proc netFor(n: int; body: NetBody; grain = 1) =
  ## (`body` on pieces of `0 ..< n` -- each at least `grain` -- on the runner's threads and this one)
  if n <= 0: return
  when compileOption("threads"):
    nStart()
    if nThreads.len == 0 or n < 2 * max(1, grain):
      body(0, n)
      return
    let parts = 4 * (nThreads.len + 1)
    let chunk = max(max(1, grain), (n + parts - 1) div parts)
    var b = body
    acquire(nLock)
    while nActive > 0: wait(nDone, nLock)          # (the last work's late threads)
    nBody = addr b
    nN = n
    nChunk = chunk
    nNext.store(0)
    nLeft.store((n + chunk - 1) div chunk)
    nFailed.store(false)
    inc nGen
    broadcast(nWake)
    release(nLock)
    nPieces(addr b, n, chunk)
    acquire(nLock)
    while nLeft.load > 0: wait(nDone, nLock)
    release(nLock)
    if nFailed.load: fail("a piece of the work failed")
  else:
    body(0, n)

proc count*(dims: openArray[int]): int =
  result = 1
  for d in dims: result *= d

proc len*(t: Tensor): int = (if t.isInt: t.i.len else: t.f.len)

proc floats*(dims: openArray[int]; fill = 0'f32): Tensor =
  ## A tensor of floats of these sizes.
  result = Tensor(dims: @dims)
  result.f = newSeq[float32](count(dims))
  if fill != 0:
    for v in result.f.mitems: v = fill

proc wholes*(dims: openArray[int]; values: openArray[int64] = []): Tensor =
  ## A tensor of whole numbers.
  result = Tensor(dims: @dims, isInt: true)
  if values.len > 0: result.i = @values
  else: result.i = newSeq[int64](count(dims))

proc asFloat(t: Tensor): Tensor =
  if not t.isInt: return t
  result = Tensor(dims: t.dims)
  result.f = newSeq[float32](t.i.len)
  for k, v in t.i: result.f[k] = float32(v)

proc asInt(t: Tensor): Tensor =
  if t.isInt: return t
  result = Tensor(dims: t.dims, isInt: true)
  result.i = newSeq[int64](t.f.len)
  for k, v in t.f: result.i[k] = int64(v)

proc toTensor(o: OnnxTensor): Tensor =
  if o.kind in {otFloat, otFloat16, otDouble, otBfloat16}: Tensor(dims: o.dims, f: o.floats)
  else: Tensor(dims: o.dims, i: o.ints, isInt: true)

proc strides(dims: openArray[int]): seq[int] =
  result = newSeq[int](dims.len)
  var s = 1
  for k in countdown(dims.high, 0):
    result[k] = s
    s *= dims[k]

# ---- broadcasting -----------------------------------------------------------------------------------------

proc broadcastDims(a, b: openArray[int]): seq[int] =
  let n = max(a.len, b.len)
  result = newSeq[int](n)
  for k in 0 ..< n:
    let x = if k - (n - a.len) >= 0: a[k - (n - a.len)] else: 1
    let y = if k - (n - b.len) >= 0: b[k - (n - b.len)] else: 1
    if x != y and x != 1 and y != 1: fail("sizes that do not broadcast: " & $a & " and " & $b)
    result[k] = max(x, y)

proc indexMap(src, dst: openArray[int]): seq[int] =
  ## (for each place of `dst`, where it reads `src`, broadcast)
  let n = count(dst)
  result = newSeq[int](n)
  let off = dst.len - src.len
  let ss = strides(src)
  let ds = strides(dst)
  for k in 0 ..< n:
    var rem = k
    var at = 0
    for d in 0 ..< dst.len:
      let c = rem div ds[d]
      rem = rem mod ds[d]
      let sd = d - off
      if sd >= 0 and src[sd] != 1: at += c * ss[sd]
    result[k] = at

proc floatsOf(t: Tensor; keep: var Tensor): ptr Tensor =
  # (a tensor of floats without a copy: whole numbers turned into floats in `keep`)
  if t.isInt:
    keep = t.asFloat
    addr keep
  else: unsafeAddr t

proc periodOf(small, dims: openArray[int]): (int, int) =
  ## (when `small`, broadcast to `dims`, varies only over one run of sizes: how many places each
  ## of its values stays the same (`inner`), and how many it has -- else (0, 0))
  let off = dims.len - small.len
  var lo = -1
  var hi = -1
  for d in 0 ..< small.len:
    if small[d] != 1:
      if small[d] != dims[d + off]: return (0, 0)
      if lo < 0: lo = d
      elif hi != d - 1: return (0, 0)
      hi = d
  if lo < 0: return (count(dims), 1)
  var inner = 1
  for d in hi + 1 + off ..< dims.len: inner *= dims[d]
  (inner, count(small))

template eachPlace(n: int; body: untyped) =
  # (big tensors shared among the cores)
  if n >= 1 shl 16:
    netFor((n + 4095) div 4096, proc (pieceLo, pieceHi: int) =
      for k {.inject.} in pieceLo * 4096 ..< min(n, pieceHi * 4096): body,
      grain = 4)
  else:
    for k {.inject.} in 0 ..< n: body

template eachPeriod(n, inner, period: int; body: untyped) =
  # (k, every place; j, the small tensor's place for it: the same for `inner` places in a row,
  # over again after `period` of them -- no division for each)
  let blocks = n div (inner * period)
  if inner == 1:
    template run1(b0, b1: int) =
      for blk in b0 ..< b1:
        for j {.inject.} in 0 ..< period:
          let k {.inject.} = blk * period + j
          body
    if n >= 1 shl 16:
      netFor(blocks, proc (pieceLo, pieceHi: int) = run1(pieceLo, pieceHi),
                  grain = max(1, 4096 div period))
    else: run1(0, blocks)
  else:
    template run2(i0, i1: int) =
      for item in i0 ..< i1:
        let j {.inject.} = item mod period
        let base = item * inner
        for q in 0 ..< inner:
          let k {.inject.} = base + q
          body
    if n >= 1 shl 16:
      netFor(blocks * period, proc (pieceLo, pieceHi: int) = run2(pieceLo, pieceHi),
                  grain = max(1, 4096 div inner))
    else: run2(0, blocks * period)

template binaryOp(a, b: Tensor; body: untyped): Tensor =
  block:
    let dims = broadcastDims(a.dims, b.dims)
    var r: Tensor
    if a.isInt and b.isInt:
      r = Tensor(dims: dims, isInt: true)
      r.i = newSeq[int64](count(dims))
      if a.dims == b.dims:
        for k in 0 ..< r.i.len:
          let x {.inject.} = float64(a.i[k])
          let y {.inject.} = float64(b.i[k])
          r.i[k] = int64(body)
      else:
        let ma = indexMap(a.dims, dims)
        let mb = indexMap(b.dims, dims)
        for k in 0 ..< r.i.len:
          let x {.inject.} = float64(a.i[ma[k]])
          let y {.inject.} = float64(b.i[mb[k]])
          r.i[k] = int64(body)
    else:
      var ka, kb: Tensor
      let fa = floatsOf(a, ka)
      let fb = floatsOf(b, kb)
      r = Tensor(dims: dims)
      r.f = newSeq[float32](count(dims))
      let n = r.f.len
      let rp = cast[ptr UncheckedArray[float32]](addr r.f[0])
      let ap = cast[ptr UncheckedArray[float32]](unsafeAddr fa.f[0])
      let bp = cast[ptr UncheckedArray[float32]](unsafeAddr fb.f[0])
      let (ia, na) = periodOf(fa.dims, dims)
      let (ib, nb) = periodOf(fb.dims, dims)
      if fa.f.len == n and fb.f.len == n:
        eachPlace(n):
          let x {.inject.} = ap[k]
          let y {.inject.} = bp[k]
          rp[k] = float32(body)
      elif fa.f.len == n and ib > 0:
        # (a bias, a scale: b the same for `ib` places in a row, again after `nb` of them)
        eachPeriod(n, ib, nb):
          let x {.inject.} = ap[k]
          let y {.inject.} = bp[j]
          rp[k] = float32(body)
      elif fb.f.len == n and ia > 0:
        eachPeriod(n, ia, na):
          let x {.inject.} = ap[j]
          let y {.inject.} = bp[k]
          rp[k] = float32(body)
      else:
        let ma = indexMap(fa.dims, dims)
        let mb = indexMap(fb.dims, dims)
        for k in 0 ..< n:
          let x {.inject.} = ap[ma[k]]
          let y {.inject.} = bp[mb[k]]
          rp[k] = float32(body)
    r

template unaryOp(a: var Tensor; body: untyped): Tensor =
  ## (in place: a node's inputs are its own)
  block:
    var r = if a.isInt: a.asFloat else: move(a)
    if r.f.len > 0:
      let rp = cast[ptr UncheckedArray[float32]](addr r.f[0])
      eachPlace(r.f.len):
        let x {.inject.} = rp[k]
        rp[k] = float32(body)
    r

# ---- matrix products: the work of convolutions, linear layers, attention -----------------------------

const netKernels = currentSourcePath().substr(0, currentSourcePath().rfind({'/', '\\'})) & "simdnet.h"

proc netGemm(a, b, c: ptr float32; m, k, lda, ldb, ldc, j0, j1: int; over: cint)
  {.importc: "ruk_net_gemm", header: netKernels, cdecl.}

proc netSoftmax(x: ptr float32; n: int) {.importc: "ruk_net_softmax", header: netKernels, cdecl.}
proc netErf(x: ptr float32; n: int) {.importc: "ruk_net_erf", header: netKernels, cdecl.}

# (the GPU: big products worked out there -- `retroui/gpucompute`, a context of the runner's thread)
const DefaultGpuWork = 32_000_000

var
  netGpuMode = 0               # (0: a real GPU, 1: any, a software one too; -1: none)
  netGpuWork = DefaultGpuWork  # (multiply-adds a product needs to go to the GPU)

proc setNetGpu*(mode: int) =
  ## Where the runner's big matrix products are worked out: 0 on a real GPU (not the processor
  ## drawing) when one is here and a product timed both ways once found it the quicker, 1 on any
  ## GPU, -1 always on the CPU. The numbers are the same within rounding. $RETRO_NET_GPU sets it
  ## at the start.
  netGpuMode = clamp(mode, -1, 1)

proc setNetGpuWork*(macs: int) =
  ## How big a product goes to the GPU, in multiply-adds (-1: the default, 32 million).
  netGpuWork = if macs < 0: DefaultGpuWork else: macs

block:
  let e = getEnv("RETRO_NET_GPU")
  if e.len > 0:
    try: setNetGpu(parseInt(e))
    except ValueError: discard

var gpuChoice = 0               # (0: not tried yet; 1: the GPU is quicker here; -1: the CPU)

proc gemm(a: ptr UncheckedArray[float32]; b: ptr UncheckedArray[float32]; c: ptr UncheckedArray[float32];
          m, n, k: int; transB = false; accumulate = false; cpuOnly = false)

proc gpuQuicker(): bool =
  ## (a real GPU is used only where it is the quicker: a product of 256 x 1024 by 1024 x 256 timed
  ## both ways once, the GPU taken when it takes at most four fifths of the CPU's time)
  block:
    if gpuChoice == 0:
      const m = 256
      const k = 1024
      const n = 256
      var a = newSeq[float32](m * k)
      var b = newSeq[float32](k * n)
      for i in 0 ..< a.len: a[i] = float32((i * 7919) mod 1000) / 1000 - 0.5
      for i in 0 ..< b.len: b[i] = float32((i * 104729) mod 1000) / 1000 - 0.5
      var c = newSeq[float32](m * n)
      template ms(t: MonoTime): float = (getMonoTime() - t).inMicroseconds.float / 1000
      discard gpuMatmul(a, b, 16, k, 16)                     # (the GPU's shaders ready first)
      let t0 = getMonoTime()
      let g = gpuMatmul(a, b, m, k, n)
      let gpuMs = ms(t0)
      let t1 = getMonoTime()
      gemm(cast[ptr UncheckedArray[float32]](addr a[0]), cast[ptr UncheckedArray[float32]](addr b[0]),
           cast[ptr UncheckedArray[float32]](addr c[0]), m, n, k, cpuOnly = true)
      let cpuMs = ms(t1)
      gpuChoice = if g.len == m * n and gpuMs <= cpuMs * 0.8: 1 else: -1
    gpuChoice > 0

proc netGpuUsed*(): bool =
  ## The runner's big products go to the GPU on this thread (`setNetGpu`; on 0, a real GPU found
  ## quicker than the CPU, timed once). In a web page, WebGPU, for the runner's threads.
  netGpuMode >= 0 and computeReady() and (netGpuMode == 1 or (not computeSoftware() and gpuQuicker()))

proc gpuWorth(m, n, k: int): bool =
  ## (a product of these sizes goes to the GPU: big enough, and a GPU worth it for this thread)
  m * n * k >= netGpuWork and k <= computeMaxSide() and n <= computeMaxSide() and netGpuUsed()

proc gpuGemm(a, b, c: ptr UncheckedArray[float32]; m, n, k: int; accumulate: bool): bool =
  ## (c (+)= a * b on the GPU; false: not done there)
  let g = gpuMatmul(toOpenArray(a, 0, m * k - 1), toOpenArray(b, 0, k * n - 1), m, k, n)
  if g.len != m * n: return false
  if accumulate:
    for i in 0 ..< m * n: c[i] += g[i]
  else: copyMem(c, unsafeAddr g[0], m * n * sizeof(float32))
  true

proc plainGemm(a, b, c: ptr UncheckedArray[float32]; m, k, n, j0, j1: int) =
  # (-d:retroNoSimd: the same sums, lane by lane)
  for i in 0 ..< m:
    for t in 0 ..< k:
      let av = a[i * k + t]
      for j in j0 ..< j1: c[i * n + j] += av * b[t * n + j]

proc gemm(a: ptr UncheckedArray[float32]; b: ptr UncheckedArray[float32]; c: ptr UncheckedArray[float32];
          m, n, k: int; transB = false; accumulate = false; cpuOnly = false) =
  ## (c[m x n] (+)= a[m x k] * b[k x n] -- b given as n x k when `transB`: on the GPU when it is big
  ## and worth it, else pieces of rows and columns shared among the cores, `simdnet.h`'s blocks)
  if m == 0 or n == 0: return
  if k == 0:
    if not accumulate: zeroMem(c, m * n * sizeof(float32))
    return
  when defined(retroNoSimd):
    if not accumulate: zeroMem(c, m * n * sizeof(float32))
  var bt: seq[float32]
  var bp = b
  if transB:
    bt = newSeq[float32](k * n)
    for j in 0 ..< n:
      for t in 0 ..< k: bt[t * n + j] = b[j * k + t]
    bp = cast[ptr UncheckedArray[float32]](addr bt[0])
  if not cpuOnly and gpuWorth(m, n, k) and gpuGemm(a, bp, c, m, n, k, accumulate): return
  let (ap, bq, cp) = (a, bp, c)
  # (pieces of 64 rows by up to 128 columns: enough of them for every core, whatever the shape)
  const rowsEach = 64
  let rowBlocks = (m + rowsEach - 1) div rowsEach
  let panels = (n + 15) div 16
  let panelsEach = clamp(panels div max(1, 8 div rowBlocks), 1, 8)
  let groups = (panels + panelsEach - 1) div panelsEach
  let work = 2 * min(m, rowsEach) * panelsEach * 16 * k
  netFor(rowBlocks * groups, proc (lo, hi: int) =
    for it in lo ..< hi:
      let r0 = (it div groups) * rowsEach
      let r1 = min(m, r0 + rowsEach)
      let j0 = (it mod groups) * panelsEach * 16
      let j1 = min(n, j0 + panelsEach * 16)
      when defined(retroNoSimd):
        plainGemm(cast[ptr UncheckedArray[float32]](addr ap[r0 * k]), bq,
                  cast[ptr UncheckedArray[float32]](addr cp[r0 * n]), r1 - r0, k, n, j0, j1)
      else: netGemm(addr ap[r0 * k], addr bq[0], addr cp[r0 * n], r1 - r0, k, k, n, n, j0, j1,
                    cint(not accumulate)),
    grain = max(1, 1_000_000 div max(1, work)))

proc matmul*(a, b: Tensor): Tensor =
  ## ONNX's MatMul: the last two sizes multiplied, those before broadcast.
  var ka, kb: Tensor
  let fa = floatsOf(a, ka)
  let fb = floatsOf(b, kb)
  var ad = fa.dims
  var bd = fb.dims
  let aVec = ad.len == 1
  let bVec = bd.len == 1
  if aVec: ad = @[1] & ad
  if bVec: bd = bd & @[1]
  let m = ad[^2]
  let k = ad[^1]
  let n = bd[^1]
  if bd[^2] != k: fail("MatMul: " & $fa.dims & " by " & $fb.dims)
  let batchDims = broadcastDims(ad[0 ..< ad.len - 2], bd[0 ..< bd.len - 2])
  let batches = count(batchDims)
  var outDims = batchDims & @[m, n]
  result = Tensor(dims: outDims)
  result.f = newSeqUninit[float32](batches * m * n)    # (each written by `gemm`)
  let ma = indexMap(ad[0 ..< ad.len - 2], batchDims)
  let mb = indexMap(bd[0 ..< bd.len - 2], batchDims)
  for bi in 0 ..< batches:
    let ap = cast[ptr UncheckedArray[float32]](unsafeAddr fa.f[(if ma.len > 0: ma[bi] else: 0) * m * k])
    let bp = cast[ptr UncheckedArray[float32]](unsafeAddr fb.f[(if mb.len > 0: mb[bi] else: 0) * k * n])
    gemm(ap, bp, cast[ptr UncheckedArray[float32]](addr result.f[bi * m * n]), m, n, k)
  if aVec: result.dims.delete(result.dims.len - 2)
  if bVec: result.dims.delete(result.dims.len - 1)

proc conv*(x, w: Tensor; bias: Tensor; strides, pads, dilations: seq[int]; group: int; relu = false): Tensor =
  ## ONNX's Conv for pictures (N, C, H, W): the places shared among the cores in strips, each
  ## strip's inputs gathered in columns (im2col) a strip at a time -- so they stay in the cache --
  ## then a matrix product with the weights. A 1 x 1 convolution reads the input as it is; one
  ## channel a group (depthwise) is worked out directly. `relu`: the Relu after it too (`run`
  ## joins them), in the same pass as the bias.
  var kx, kw2: Tensor
  let fx = floatsOf(x, kx)
  if fx.dims.len != 4 or w.dims.len != 4: fail("Conv: only two-dimensional (" & $fx.dims & ")")
  let (n, c, h, wd) = (fx.dims[0], fx.dims[1], fx.dims[2], fx.dims[3])
  let (oc, icg, kh, kw) = (w.dims[0], w.dims[1], w.dims[2], w.dims[3])
  let g = max(1, group)
  if icg * g != c: fail("Conv: " & $c & " channels in, " & $icg & " a group of " & $g)
  let (sh, sw) = (strides[0], strides[1])
  let (dh, dw) = (dilations[0], dilations[1])
  let (pt, pl, pb, pr) = (pads[0], pads[1], pads[2], pads[3])
  let oh = (h + pt + pb - dh * (kh - 1) - 1) div sh + 1
  let ow = (wd + pl + pr - dw * (kw - 1) - 1) div sw + 1
  result = floats([n, oc, oh, ow])
  let ocg = oc div g
  let kk = icg * kh * kw
  let places = oh * ow
  let fw = floatsOf(w, kw2)
  let wq = cast[ptr UncheckedArray[float32]](unsafeAddr fw.f[0])
  let res = cast[ptr UncheckedArray[float32]](addr result.f[0])
  for b in 0 ..< n:
    let xb = cast[ptr UncheckedArray[float32]](unsafeAddr fx.f[b * c * h * wd])
    let ob = cast[ptr UncheckedArray[float32]](addr res[b * oc * places])
    if icg == 1 and ocg == 1:
      # (depthwise: each channel its own small kernel)
      netFor(c, proc (lo, hi: int) =
        for ch in lo ..< hi:
          let xp = cast[ptr UncheckedArray[float32]](addr xb[ch * h * wd])
          let op = cast[ptr UncheckedArray[float32]](addr ob[ch * places])
          for oy in 0 ..< oh:
            # (an output row at a time, kept in the cache while each tap adds to it; each tap's
            # places that read inside the input worked out first -- the loop then plain)
            let orow = oy * ow
            for ky in 0 ..< kh:
              let iy = oy * sh - pt + ky * dh
              if iy < 0 or iy >= h: continue
              let xr = iy * wd
              for kx in 0 ..< kw:
                let wv = wq[(ch * kh + ky) * kw + kx]
                let base = kx * dw - pl
                let ox0 = if base >= 0: 0 else: (-base + sw - 1) div sw
                let ox1 = if wd - 1 - base < 0: 0 else: min(ow, (wd - 1 - base) div sw + 1)
                if sw == 1:
                  for ox in ox0 ..< ox1: op[orow + ox] += wv * xp[xr + ox + base]
                else:
                  for ox in ox0 ..< ox1: op[orow + ox] += wv * xp[xr + ox * sw + base],
        grain = max(1, 65536 div max(1, places * kh * kw)))
      continue
    for gi in 0 ..< g:
      let xp = cast[ptr UncheckedArray[float32]](addr xb[gi * icg * h * wd])
      let wp = cast[ptr UncheckedArray[float32]](addr wq[gi * ocg * kk])
      let op = cast[ptr UncheckedArray[float32]](addr ob[gi * ocg * places])
      if kh == 1 and kw == 1 and sh == 1 and sw == 1 and pt == 0 and pl == 0 and pb == 0 and pr == 0:
        gemm(wp, xp, op, ocg, places, icg, accumulate = true)     # (the input is its own columns)
        continue
      if gpuWorth(ocg, places, kk):
        # (the GPU: every place's inputs gathered in columns, then one product there)
        var cols = newSeq[float32](kk * places)
        let cp = cast[ptr UncheckedArray[float32]](addr cols[0])
        netFor(kk, proc (lo, hi: int) =
          for r in lo ..< hi:
            let ci = r div (kh * kw)
            let ky = (r div kw) mod kh
            let kx = r mod kw
            for oy in 0 ..< oh:
              let iy = oy * sh - pt + ky * dh
              let row = r * places + oy * ow
              if iy < 0 or iy >= h: continue
              let src = (ci * h + iy) * wd
              for ox in 0 ..< ow:
                let ix = ox * sw - pl + kx * dw
                if ix >= 0 and ix < wd: cp[row + ox] = xp[src + ix])
        if gpuGemm(wp, cp, op, ocg, places, kk, accumulate = true): continue
        gemm(wp, cp, op, ocg, places, kk, accumulate = true)
        continue
      # (strips of places: as many as keep a strip's columns some 256 KB)
      let strip = clamp((65536 div max(1, kk)) div 16 * 16, 16, 1024)
      let strips = (places + strip - 1) div strip
      netFor(strips, proc (lo, hi: int) =
        var cols = newSeq[float32](kk * strip)
        let cp = cast[ptr UncheckedArray[float32]](addr cols[0])
        for si in lo ..< hi:
          let p0 = si * strip
          let p1 = min(places, p0 + strip)
          let tw = p1 - p0
          for r in 0 ..< kk:
            let ci = r div (kh * kw)
            let ky = (r div kw) mod kh
            let kx = r mod kw
            let row = r * tw
            var oy = p0 div ow
            var ox = p0 mod ow
            var q = 0
            while q < tw:
              # (a row of output places at a time: with a stride of 1, its inputs copied whole)
              let run = min(ow - ox, tw - q)
              let iy = oy * sh - pt + ky * dh
              if iy < 0 or iy >= h:
                zeroMem(addr cp[row + q], run * sizeof(float32))
              else:
                let src = (ci * h + iy) * wd
                let base = kx * dw - pl
                if sw == 1:
                  let a = min(max(ox, -base), ox + run)
                  let e = max(min(ox + run, wd - base), a)
                  if a > ox: zeroMem(addr cp[row + q], (a - ox) * sizeof(float32))
                  if e > a: copyMem(addr cp[row + q + a - ox], addr xp[src + a + base], (e - a) * sizeof(float32))
                  if ox + run > e: zeroMem(addr cp[row + q + e - ox], (ox + run - e) * sizeof(float32))
                else:
                  for t in 0 ..< run:
                    let ix = (ox + t) * sw + base
                    cp[row + q + t] = if ix >= 0 and ix < wd: xp[src + ix] else: 0
              q += run
              ox = 0
              inc oy
          when defined(retroNoSimd):
            for i in 0 ..< ocg:
              for t in 0 ..< kk:
                let av = wp[i * kk + t]
                for q in 0 ..< tw: op[i * places + p0 + q] += av * cp[t * tw + q]
          else:
            netGemm(addr wp[0], addr cp[0], addr op[p0], ocg, kk, kk, tw, places, 0, tw, 0),
        grain = 1)
  if bias.f.len == oc or relu:
    let bp = if bias.f.len == oc: cast[ptr UncheckedArray[float32]](unsafeAddr bias.f[0]) else: nil
    netFor(n * oc, proc (lo, hi: int) =
      for q in lo ..< hi:
        let bv = if bp != nil: bp[q mod oc] else: 0'f32
        if relu:
          for p in 0 ..< places: res[q * places + p] = max(res[q * places + p] + bv, 0'f32)
        else:
          for p in 0 ..< places: res[q * places + p] += bv,
      grain = max(1, 65536 div max(1, places)))

proc convTranspose*(x, w: Tensor; bias: Tensor; strides, pads, dilations, outPad: seq[int]; group: int;
                    outShape: seq[int] = @[]): Tensor =
  ## ONNX's ConvTranspose for pictures: each input place spreads its kernel into the output (the
  ## weights' columns times the input, then added in place: col2im).
  var kx: Tensor
  let fx = floatsOf(x, kx)
  let (n, c, h, wd) = (fx.dims[0], fx.dims[1], fx.dims[2], fx.dims[3])
  let (icw, ocg, kh, kw) = (w.dims[0], w.dims[1], w.dims[2], w.dims[3])
  let g = max(1, group)
  if icw != c: fail("ConvTranspose: " & $c & " channels in, the weights take " & $icw)
  let icg = c div g
  let oc = ocg * g
  let (sh, sw) = (strides[0], strides[1])
  let (dh, dw) = (dilations[0], dilations[1])
  var (pt, pl, pb, pr) = (pads[0], pads[1], pads[2], pads[3])
  var oh = sh * (h - 1) + outPad[0] + ((kh - 1) * dh + 1) - pt - pb
  var ow = sw * (wd - 1) + outPad[1] + ((kw - 1) * dw + 1) - pl - pr
  if outShape.len == 2:
    # (the output's size given: the padding follows from it, the extra at the end)
    let th = sh * (h - 1) + outPad[0] + ((kh - 1) * dh + 1) - outShape[0]
    let tw = sw * (wd - 1) + outPad[1] + ((kw - 1) * dw + 1) - outShape[1]
    pt = th div 2
    pl = tw div 2
    oh = outShape[0]
    ow = outShape[1]
  result = floats([n, oc, oh, ow])
  let places = h * wd
  let kk = ocg * kh * kw
  var cols = newSeq[float32](kk * places)
  var wt = newSeq[float32](kk * icg)        # (the group's weights turned: kk x icg)
  for b in 0 ..< n:
    for gi in 0 ..< g:
      for ci in 0 ..< icg:
        for r in 0 ..< kk: wt[r * icg + ci] = w.f[(gi * icg + ci) * kk + r]
      let xp = cast[ptr UncheckedArray[float32]](unsafeAddr fx.f[(b * c + gi * icg) * places])
      gemm(cast[ptr UncheckedArray[float32]](addr wt[0]), xp, cast[ptr UncheckedArray[float32]](addr cols[0]),
           kk, places, icg)
      for r in 0 ..< kk:
        let o = r div (kh * kw)
        let ky = (r div kw) mod kh
        let kx = r mod kw
        let obase = (b * oc + gi * ocg + o) * oh * ow
        for iy in 0 ..< h:
          let oy = iy * sh - pt + ky * dh
          if oy < 0 or oy >= oh: continue
          for ix in 0 ..< wd:
            let ox = ix * sw - pl + kx * dw
            if ox >= 0 and ox < ow: result.f[obase + oy * ow + ox] += cols[r * places + iy * wd + ix]
  if bias.f.len == oc:
    for b in 0 ..< n:
      for o in 0 ..< oc:
        for p in 0 ..< oh * ow: result.f[(b * oc + o) * oh * ow + p] += bias.f[o]

# ---- shapes -------------------------------------------------------------------------------------------------

proc axisOf(a, rank: int): int =
  result = if a < 0: a + rank else: a
  if result < 0 or result >= max(1, rank): fail("an axis out of range: " & $a & " of " & $rank)

proc reshaped(t: Tensor; shape: openArray[int64]; allowZero = false): Tensor =
  result = t
  var dims = newSeq[int](shape.len)
  var unknown = -1
  var known = 1
  for k, s in shape:
    if s == -1:
      unknown = k
      dims[k] = 1
    elif s == 0 and not allowZero:
      dims[k] = if k < t.dims.len: t.dims[k] else: 0
      known *= dims[k]
    else:
      dims[k] = int(s)
      known *= dims[k]
  if unknown >= 0: dims[unknown] = if known == 0: 0 else: t.len div known
  if count(dims) != t.len: fail("Reshape: " & $t.dims & " into " & $shape)
  result.dims = dims

proc transposed(t: Tensor; perm: openArray[int]): Tensor =
  let r = t.dims.len
  var p = @perm
  if p.len == 0:
    for k in countdown(r - 1, 0): p.add k
  var dims = newSeq[int](r)
  for k in 0 ..< r: dims[k] = t.dims[p[k]]
  let ss = strides(t.dims)
  let n = t.len
  result = Tensor(dims: dims, isInt: t.isInt)
  if t.isInt: result.i = newSeq[int64](n) else: result.f = newSeq[float32](n)
  let ds = strides(dims)
  var src = newSeq[int](r)
  for k in 0 ..< r: src[k] = ss[p[k]]
  if not t.isInt and r >= 1 and n > 0:
    # (floats: the output a row of its last size at a time, the rows shared among the cores --
    # a row the source has side by side copied whole)
    let last = dims[r - 1]
    let sl = src[r - 1]
    let rows = n div max(1, last)
    let sp = cast[ptr UncheckedArray[float32]](unsafeAddr t.f[0])
    let dp = cast[ptr UncheckedArray[float32]](addr result.f[0])
    netFor(rows, proc (lo, hi: int) =
      for row in lo ..< hi:
        var rem = row
        var at = 0
        for d in countdown(r - 2, 0):
          at += (rem mod dims[d]) * src[d]
          rem = rem div dims[d]
        let o = row * last
        if sl == 1: copyMem(addr dp[o], addr sp[at], last * sizeof(float32))
        else:
          for q in 0 ..< last: dp[o + q] = sp[at + q * sl],
      grain = max(1, 8192 div max(1, last)))
    return
  # (walked in the output's order: the source's place by its strides)
  var idx = newSeq[int](r)
  var at = 0
  for o in 0 ..< n:
    if t.isInt: result.i[o] = t.i[at] else: result.f[o] = t.f[at]
    var d = r - 1
    while d >= 0:
      inc idx[d]
      at += src[d]
      if idx[d] < dims[d]: break
      at -= src[d] * dims[d]
      idx[d] = 0
      dec d
  discard ds

proc sliceAxis(t: Tensor; axis, start, stop, step: int): Tensor =
  ## (t[..., start:stop:step, ...] along `axis`)
  var dims = t.dims
  var picks: seq[int]
  var k = start
  if step > 0:
    while k < stop:
      picks.add k
      k += step
  else:
    while k > stop:
      picks.add k
      k += step
  dims[axis] = picks.len
  let outer = count(t.dims[0 ..< axis])
  let inner = count(t.dims[axis + 1 .. ^1])
  result = Tensor(dims: dims, isInt: t.isInt)
  let n = count(dims)
  if t.isInt: result.i = newSeq[int64](n) else: result.f = newSeq[float32](n)
  var o = 0
  for a in 0 ..< outer:
    for p in picks:
      let base = (a * t.dims[axis] + p) * inner
      if inner > 0:
        if t.isInt: copyMem(addr result.i[o], unsafeAddr t.i[base], inner * sizeof(int64))
        else: copyMem(addr result.f[o], unsafeAddr t.f[base], inner * sizeof(float32))
      o += inner

proc concat(ts: openArray[Tensor]; axis: int): Tensor =
  ## (the parts one after another along `axis`: copied once, whole numbers when the first is)
  let isInt = ts.len > 0 and ts[0].isInt
  var parts: seq[int]
  for k, t in ts:
    if t.len > 0 or t.dims.len > 0: parts.add k
  if parts.len == 0: fail("Concat: nothing to join")
  var dims = ts[parts[0]].dims
  dims[axis] = 0
  for k in parts: dims[axis] += ts[k].dims[axis]
  let outer = count(dims[0 ..< axis])
  result = Tensor(dims: dims, isInt: isInt)
  let n = count(dims)
  if isInt: result.i = newSeq[int64](n) else: result.f = newSeq[float32](n)
  var o = 0
  for a in 0 ..< outer:
    for k in parts:
      let t = unsafeAddr ts[k]
      let chunk = count(t.dims[axis .. ^1])
      let base = a * chunk
      if chunk == 0: continue
      if isInt:
        if t.isInt: copyMem(addr result.i[o], unsafeAddr t.i[base], chunk * sizeof(int64))
        else:
          for q in 0 ..< chunk: result.i[o + q] = int64(t.f[base + q])
      else:
        if not t.isInt: copyMem(addr result.f[o], unsafeAddr t.f[base], chunk * sizeof(float32))
        else:
          for q in 0 ..< chunk: result.f[o + q] = float32(t.i[base + q])
      o += chunk

proc gathered(t: Tensor; idx: Tensor; axis: int): Tensor =
  let ii = idx.asInt
  var dims = t.dims[0 ..< axis] & ii.dims & t.dims[axis + 1 .. ^1]
  let outer = count(t.dims[0 ..< axis])
  let inner = count(t.dims[axis + 1 .. ^1])
  result = Tensor(dims: dims, isInt: t.isInt)
  let n = count(dims)
  if t.isInt: result.i = newSeq[int64](n) else: result.f = newSeq[float32](n)
  var o = 0
  for a in 0 ..< outer:
    for v in ii.i:
      let p = int(if v < 0: v + t.dims[axis] else: v)
      if p < 0 or p >= t.dims[axis]: fail("Gather: index " & $v & " of " & $t.dims[axis])
      let base = (a * t.dims[axis] + p) * inner
      if t.isInt:
        for q in 0 ..< inner: result.i[o + q] = t.i[base + q]
      else:
        for q in 0 ..< inner: result.f[o + q] = t.f[base + q]
      o += inner

# ---- normalizations, softmax, pools, resizing ------------------------------------------------------------

proc softmaxLast(t: var Tensor; axis: int) =
  ## (softmax along `axis`, in place: rows of the last size -- attention's -- shared among the
  ## cores, `simdnet.h`'s e^x; other axes number by number)
  let inner = count(t.dims[axis + 1 .. ^1])
  let n = t.dims[axis]
  let outer = count(t.dims[0 ..< axis])
  if n == 0 or outer == 0 or inner == 0: return
  let tp = cast[ptr UncheckedArray[float32]](addr t.f[0])
  if inner == 1:
    netFor(outer, proc (lo, hi: int) =
      for a in lo ..< hi:
        when defined(retroNoSimd):
          var top = -Inf.float32
          for k in 0 ..< n: top = max(top, tp[a * n + k])
          var sum = 0'f32
          for k in 0 ..< n:
            tp[a * n + k] = exp(tp[a * n + k] - top)
            sum += tp[a * n + k]
          for k in 0 ..< n: tp[a * n + k] /= sum
        else: netSoftmax(addr tp[a * n], n),
      grain = max(1, 16384 div n))
    return
  for a in 0 ..< outer:
    for q in 0 ..< inner:
      var top = -Inf.float32
      for k in 0 ..< n: top = max(top, tp[(a * n + k) * inner + q])
      var sum = 0'f32
      for k in 0 ..< n:
        let at = (a * n + k) * inner + q
        tp[at] = exp(tp[at] - top)
        sum += tp[at]
      for k in 0 ..< n: tp[(a * n + k) * inner + q] /= sum

proc layerNorm(x: sink Tensor; scale, bias: Tensor; axis: int; eps: float32): Tensor =
  ## (each group of the sizes from `axis` on: its mean 0 and its variance 1, then scaled and
  ## moved; in place)
  result = if x.isInt: x.asFloat else: x
  let inner = count(result.dims[axis .. ^1])
  let outer = result.len div max(1, inner)
  if outer == 0 or inner == 0: return
  let rp = cast[ptr UncheckedArray[float32]](addr result.f[0])
  let (sn, bn) = (scale.f.len, bias.f.len)
  let sp = if sn > 0: cast[ptr UncheckedArray[float32]](unsafeAddr scale.f[0]) else: nil
  let bp = if bn > 0: cast[ptr UncheckedArray[float32]](unsafeAddr bias.f[0]) else: nil
  netFor(outer, proc (lo, hi: int) =
    for a in lo ..< hi:
      var mean = 0'f64
      for q in 0 ..< inner: mean += rp[a * inner + q]
      mean /= float64(inner)
      var v = 0'f64
      for q in 0 ..< inner:
        let d = rp[a * inner + q] - mean
        v += d * d
      let k = 1 / sqrt(v / float64(inner) + eps)
      for q in 0 ..< inner:
        var y = float32((rp[a * inner + q] - mean) * k)
        if sp != nil: y *= sp[q mod sn]
        if bp != nil: y += bp[q mod bn]
        rp[a * inner + q] = y,
    grain = max(1, 8192 div inner))

proc channelNorm(x: sink Tensor; scale, bias: Tensor; groups: int; eps: float32): Tensor =
  ## (InstanceNormalization: a group a channel; GroupNormalization: `groups` of them; in place)
  result = if x.isInt: x.asFloat else: x
  let (n, c) = (result.dims[0], result.dims[1])
  let hw = count(result.dims[2 .. ^1])
  let cg = c div max(1, groups)
  for b in 0 ..< n:
    for g in 0 ..< groups:
      let base = (b * c + g * cg) * hw
      let m = cg * hw
      var mean = 0'f64
      for q in 0 ..< m: mean += result.f[base + q]
      mean /= float64(m)
      var v = 0'f64
      for q in 0 ..< m:
        let d = result.f[base + q] - mean
        v += d * d
      let k = 1 / sqrt(v / float64(m) + eps)
      for ci in 0 ..< cg:
        let ch = g * cg + ci
        let s = if scale.f.len == c: scale.f[ch] elif scale.f.len == groups: scale.f[g] else: 1'f32
        let o = if bias.f.len == c: bias.f[ch] elif bias.f.len == groups: bias.f[g] else: 0'f32
        for q in 0 ..< hw:
          let at = base + ci * hw + q
          result.f[at] = float32((result.f[at] - mean) * k) * s + o

proc pool(x: Tensor; kernel, strides, pads: seq[int]; isMax: bool; countPad: bool; ceilMode = false): Tensor =
  var kx: Tensor
  let fx = floatsOf(x, kx)
  let (n, c, h, w) = (fx.dims[0], fx.dims[1], fx.dims[2], fx.dims[3])
  let (kh, kw) = (kernel[0], kernel[1])
  proc outSize(insz, k, s, before, after: int): int =
    # (ceil_mode: a last window that starts inside the input and runs past it, as onnxruntime's)
    let span = insz + before + after - k
    if not ceilMode: return span div s + 1
    result = (span + s - 1) div s + 1
    if (result - 1) * s >= insz + before: dec result
  let oh = outSize(h, kh, strides[0], pads[0], pads[2])
  let ow = outSize(w, kw, strides[1], pads[1], pads[3])
  result = floats([n, c, oh, ow])
  let ip = cast[ptr UncheckedArray[float32]](unsafeAddr fx.f[0])
  let op = cast[ptr UncheckedArray[float32]](addr result.f[0])
  let (sy, sx) = (strides[0], strides[1])
  let (pt, pl, pb, pr) = (pads[0], pads[1], pads[2], pads[3])
  netFor(n * c, proc (lo, hi: int) =
    for b in lo ..< hi:
      for oy in 0 ..< oh:
        for ox in 0 ..< ow:
          var acc = if isMax: -Inf.float32 else: 0'f32
          var cnt = 0
          for ky in 0 ..< kh:
            let iy = oy * sy - pt + ky
            for kx in 0 ..< kw:
              let ix = ox * sx - pl + kx
              if iy < 0 or iy >= h or ix < 0 or ix >= w:
                # (the padding counts, what is past it does not)
                if countPad and iy < h + pb and ix < w + pr: inc cnt
                continue
              let v = ip[(b * h + iy) * w + ix]
              if isMax: acc = max(acc, v) else: acc += v
              inc cnt
          op[(b * oh + oy) * ow + ox] = if isMax: acc else: acc / float32(max(1, cnt)),
    grain = max(1, 65536 div max(1, oh * ow * kh * kw)))

proc cubicWeights(t: float; a: float): array[4, float] =
  # (Keys' cubic, ONNX's `cubic_coeff_a`: the weights of the four values round a place t past the first)
  proc k(d: float): float =
    let x = abs(d)
    if x <= 1: ((a + 2) * x - (a + 3)) * x * x + 1
    elif x < 2: ((a * x - 5 * a) * x + 8 * a) * x - 4 * a
    else: 0.0
  [k(1 + t), k(t), k(1 - t), k(2 - t)]

proc resize(x: Tensor; outDims: seq[int]; mode, coord, nearestMode: string; scaleH, scaleW: float;
            cubicA = -0.75; excludeOutside = false): Tensor =
  ## ONNX's Resize on the last two sizes (pictures): "nearest", "linear" or "cubic", the coordinate
  ## transformations models use (half_pixel, pytorch_half_pixel, align_corners, asymmetric). Each
  ## row's and column's sources and weights worked out once; the rows shared among the cores.
  var kx: Tensor
  let fx = floatsOf(x, kx)
  let r = fx.dims.len
  let (h, w) = (fx.dims[r - 2], fx.dims[r - 1])
  let (oh, ow) = (outDims[r - 2], outDims[r - 1])
  result = floats(outDims)
  let planes = count(fx.dims[0 ..< r - 2])
  if planes == 0 or oh == 0 or ow == 0: return
  proc src(o, insz, outsz: int; given: float): float =
    # (ONNX's: the scale given, not the sizes' ratio -- 5 rows by 1.5 make 7, read as 1.5)
    let scale = 1.0 / given
    case coord
    of "align_corners": (if outsz > 1: float(o) * float(insz - 1) / float(outsz - 1) else: 0.0)
    of "asymmetric": float(o) * scale
    of "pytorch_half_pixel": (if outsz > 1: (float(o) + 0.5) * scale - 0.5 else: 0.0)
    else: (float(o) + 0.5) * scale - 0.5
  proc near(s: float; size: int): int =
    let k = case nearestMode
            of "floor": int(floor(s))
            of "ceil": int(ceil(s))
            of "round_prefer_ceil": int(floor(s + 0.5))
            else: (if s - floor(s) == 0.5: int(floor(s)) else: int(round(s)))
    clamp(k, 0, size - 1)
  # (for each output row / column: four sources and their weights -- one for "nearest", two
  # for "linear", four for "cubic")
  proc taps(outsz, insz: int; given: float): (seq[int32], seq[float32]) =
    var idx = newSeq[int32](outsz * 4)
    var wts = newSeq[float32](outsz * 4)
    for o in 0 ..< outsz:
      let sp = src(o, insz, outsz, given)
      if mode == "nearest":
        idx[o * 4] = int32(near(sp, insz))
        wts[o * 4] = 1
      elif mode == "cubic":
        let i0 = int(floor(sp))
        var cw = cubicWeights(sp - float(i0), cubicA)
        if excludeOutside:
          var tot = 0.0
          for k in 0 .. 3:
            if i0 - 1 + k notin 0 ..< insz: cw[k] = 0
            tot += cw[k]
          if tot != 0:
            for k in 0 .. 3: cw[k] /= tot
        for k in 0 .. 3:
          idx[o * 4 + k] = int32(clamp(i0 - 1 + k, 0, insz - 1))
          wts[o * 4 + k] = float32(cw[k])
      else:
        let c = clamp(sp, 0.0, float(insz - 1))
        let i0 = min(int(floor(c)), insz - 1)
        let f = float32(c - float(i0))
        idx[o * 4] = int32(i0)
        idx[o * 4 + 1] = int32(min(i0 + 1, insz - 1))
        wts[o * 4] = 1 - f
        wts[o * 4 + 1] = f
    (idx, wts)
  let (yi, yw) = taps(oh, h, scaleH)
  let (xi, xw) = taps(ow, w, scaleW)
  let nt = if mode == "nearest": 1 elif mode == "cubic": 4 else: 2
  let ip = cast[ptr UncheckedArray[float32]](unsafeAddr fx.f[0])
  let op = cast[ptr UncheckedArray[float32]](addr result.f[0])
  netFor(planes * oh, proc (lo, hi: int) =
    var row = newSeq[float32](w)
    for q in lo ..< hi:
      let p = q div oh
      let oy = q mod oh
      # (the row mixed from its source rows, then each place from its columns)
      for i in 0 ..< w: row[i] = 0
      for t in 0 ..< nt:
        let wy = yw[oy * 4 + t]
        if wy == 0: continue
        let sr = (p * h + int(yi[oy * 4 + t])) * w
        for i in 0 ..< w: row[i] += wy * ip[sr + i]
      let dr = (p * oh + oy) * ow
      for ox in 0 ..< ow:
        var v = 0'f32
        for t in 0 ..< nt: v += xw[ox * 4 + t] * row[int(xi[ox * 4 + t])]
        op[dr + ox] = v,
    grain = max(1, 16384 div max(1, ow * nt + w)))

# ---- the graph worked out -----------------------------------------------------------------------------------

proc loadNet*(path: string): Net =
  ## The model in the ONNX file at `path`. Raises `OnnxError` when it is not one.
  result = Net(model: readOnnx(path), path: path)
  # (the weights moved into tensors, not copied: the file's numbers kept once)
  for k, t in result.model.graph.weights.mpairs:
    result.weights[k] =
      if t.kind in {otFloat, otFloat16, otDouble, otBfloat16}: Tensor(dims: t.dims, f: move(t.floats))
      else: Tensor(dims: t.dims, i: move(t.ints), isInt: true)

proc inputNames*(n: Net): seq[string] =
  for v in n.model.graph.inputs: result.add v.name

proc outputNames*(n: Net): seq[string] =
  for v in n.model.graph.outputs: result.add v.name

proc ints(t: Tensor): seq[int] =
  let ii = t.asInt
  for v in ii.i: result.add int(v)

proc erf32(x: float32): float32 = float32(erf(float64(x)))

proc runNode(node: OnnxNode; ins: var seq[Tensor]; opset: int; fuse = false): seq[Tensor] =
  ## (`ins` are the node's own, to change or move from: `run` hands over values at their last use,
  ## and copies of the rest)
  template inp(k: int): Tensor = ins[k]           # (`run` gives at least 8, empty past the node's)
  template has(k: int): bool = k < ins.len and (ins[k].len > 0 or ins[k].dims.len > 0)
  let op = node.op
  case op
  # (one input, number by number)
  of "Relu": result = @[unaryOp(inp(0), max(x, 0'f32))]
  of "Sigmoid": result = @[unaryOp(inp(0), 1'f32 / (1'f32 + exp(-x)))]
  of "Tanh": result = @[unaryOp(inp(0), tanh(x))]
  of "Exp": result = @[unaryOp(inp(0), exp(x))]
  of "Log": result = @[unaryOp(inp(0), ln(x))]
  of "Sqrt": result = @[unaryOp(inp(0), sqrt(x))]
  of "Abs":
    result = @[if inp(0).isInt: binaryOp(inp(0), wholes([1], [0'i64]), abs(x)) else: unaryOp(inp(0), abs(x))]
  of "Neg":
    result = @[if inp(0).isInt: binaryOp(inp(0), wholes([1], [0'i64]), -x) else: unaryOp(inp(0), -x)]
  of "Reciprocal": result = @[unaryOp(inp(0), 1'f32 / x)]
  of "Floor": result = @[unaryOp(inp(0), floor(x))]
  of "Ceil": result = @[unaryOp(inp(0), ceil(x))]
  of "Round": result = @[unaryOp(inp(0), round(x))]
  of "Erf":
    when defined(retroNoSimd): result = @[unaryOp(inp(0), erf32(x))]
    else:
      var r = if inp(0).isInt: inp(0).asFloat else: move(ins[0])
      let total = r.f.len
      let rp = cast[ptr UncheckedArray[float32]](if total > 0: addr r.f[0] else: nil)
      netFor((total + 4095) div 4096, proc (lo, hi: int) =
        netErf(addr rp[lo * 4096], min(total, hi * 4096) - lo * 4096),
        grain = 4)
      result = @[r]
  of "Sin": result = @[unaryOp(inp(0), sin(x))]
  of "Cos": result = @[unaryOp(inp(0), cos(x))]
  of "Softplus": result = @[unaryOp(inp(0), ln(1'f32 + exp(x)))]
  of "Gelu":
    if node.strAttr("approximate", "none") == "tanh":
      result = @[unaryOp(inp(0), 0.5'f32 * x * (1 + tanh(0.7978845608'f32 * (x + 0.044715'f32 * x * x * x))))]
    else: result = @[unaryOp(inp(0), 0.5'f32 * x * (1 + erf32(x * 0.70710678'f32)))]
  of "LeakyRelu":
    let a = node.floatAttr("alpha", 0.01)
    result = @[unaryOp(inp(0), (if x >= 0: x else: a * x))]
  of "Elu":
    let a = node.floatAttr("alpha", 1)
    result = @[unaryOp(inp(0), (if x >= 0: x else: a * (exp(x) - 1)))]
  of "HardSigmoid":
    let (a, b) = (node.floatAttr("alpha", 0.2), node.floatAttr("beta", 0.5))
    result = @[unaryOp(inp(0), clamp(a * x + b, 0'f32, 1'f32))]
  of "HardSwish": result = @[unaryOp(inp(0), x * clamp(x / 6'f32 + 0.5'f32, 0'f32, 1'f32))]
  of "Mish": result = @[unaryOp(inp(0), x * tanh(ln(1'f32 + exp(x))))]
  of "Clip":
    var lo = -Inf.float32
    var hi = Inf.float32
    if opset < 11:
      lo = node.floatAttr("min", lo)
      hi = node.floatAttr("max", hi)
    else:
      if has(1): lo = inp(1).asFloat.f[0]
      if has(2): hi = inp(2).asFloat.f[0]
    result = @[unaryOp(inp(0), clamp(x, lo, hi))]
  of "Identity", "Dropout": result = @[inp(0)]
  # (two inputs, broadcast)
  of "Add": result = @[binaryOp(inp(0), inp(1), x + y)]
  of "Sub": result = @[binaryOp(inp(0), inp(1), x - y)]
  of "Mul": result = @[binaryOp(inp(0), inp(1), x * y)]
  of "Div":
    if inp(0).isInt and inp(1).isInt: result = @[binaryOp(inp(0), inp(1), floor(x / y))]
    else: result = @[binaryOp(inp(0), inp(1), x / y)]
  of "Pow": result = @[binaryOp(inp(0), inp(1), pow(x, y))]
  of "Max": result = @[binaryOp(inp(0), inp(1), max(x, y))]
  of "Min": result = @[binaryOp(inp(0), inp(1), min(x, y))]
  of "Mod": result = @[binaryOp(inp(0), inp(1), x - y * floor(x / y))]
  of "Equal": result = @[binaryOp(inp(0).asFloat, inp(1).asFloat, (if x == y: 1.0 else: 0.0)).asInt]
  of "Less": result = @[binaryOp(inp(0).asFloat, inp(1).asFloat, (if x < y: 1.0 else: 0.0)).asInt]
  of "Greater": result = @[binaryOp(inp(0).asFloat, inp(1).asFloat, (if x > y: 1.0 else: 0.0)).asInt]
  of "LessOrEqual": result = @[binaryOp(inp(0).asFloat, inp(1).asFloat, (if x <= y: 1.0 else: 0.0)).asInt]
  of "GreaterOrEqual": result = @[binaryOp(inp(0).asFloat, inp(1).asFloat, (if x >= y: 1.0 else: 0.0)).asInt]
  of "And": result = @[binaryOp(inp(0).asInt, inp(1).asInt, (if x != 0 and y != 0: 1.0 else: 0.0))]
  of "Or": result = @[binaryOp(inp(0).asInt, inp(1).asInt, (if x != 0 or y != 0: 1.0 else: 0.0))]
  of "Not": result = @[binaryOp(inp(0).asInt, wholes([1], [0'i64]), (if x == 0: 1.0 else: 0.0))]
  of "Where":
    let c = inp(0).asInt
    let a = inp(1)
    let b = inp(2)
    let dims = broadcastDims(broadcastDims(c.dims, a.dims), b.dims)
    let mc = indexMap(c.dims, dims)
    let isInt = a.isInt and b.isInt
    let fa = if isInt: a else: a.asFloat
    let fb = if isInt: b else: b.asFloat
    let ma = indexMap(fa.dims, dims)
    let mb = indexMap(fb.dims, dims)
    var r = Tensor(dims: dims, isInt: isInt)
    let n = count(dims)
    if isInt:
      r.i = newSeq[int64](n)
      for k in 0 ..< n: r.i[k] = if c.i[mc[k]] != 0: fa.i[ma[k]] else: fb.i[mb[k]]
    else:
      r.f = newSeq[float32](n)
      for k in 0 ..< n: r.f[k] = if c.i[mc[k]] != 0: fa.f[ma[k]] else: fb.f[mb[k]]
    result = @[r]
  of "Sum", "Mean":
    var r = inp(0)
    for k in 1 ..< node.inputs.len: r = binaryOp(r, ins[k], x + y)
    if op == "Mean": r = binaryOp(r, floats([1], float32(node.inputs.len)), x / y)
    result = @[r]
  # (products)
  of "MatMul": result = @[matmul(inp(0), inp(1))]
  of "Gemm":
    var r =
      if node.intAttr("transA", 0) == 0 and node.intAttr("transB", 0) == 0: matmul(inp(0), inp(1))
      else:
        var a = move(ins[0])
        var b = move(ins[1])
        if node.intAttr("transA", 0) != 0: a = a.transposed([])
        if node.intAttr("transB", 0) != 0: b = b.transposed([])
        matmul(a, b)
    let alpha = node.floatAttr("alpha", 1)
    if alpha != 1: r = binaryOp(r, floats([1], alpha), x * y)
    if has(2):
      let beta = node.floatAttr("beta", 1)
      r = binaryOp(r, binaryOp(inp(2), floats([1], beta), x * y), x + y)
    result = @[r]
  of "Conv":
    if ins[1].isInt: ins[1] = ins[1].asFloat
    template w: Tensor = ins[1]
    var kshape = node.intsAttr("kernel_shape")
    if kshape.len == 0: kshape = @[int64(w.dims[2]), int64(w.dims[3])]
    var st = node.intsAttr("strides")
    var dl = node.intsAttr("dilations")
    var pd = node.intsAttr("pads")
    if st.len == 0: st = @[1'i64, 1]
    if dl.len == 0: dl = @[1'i64, 1]
    let x = inp(0)
    if pd.len == 0:
      pd = @[0'i64, 0, 0, 0]
      let ap = node.strAttr("auto_pad", "NOTSET")
      if ap in ["SAME_UPPER", "SAME_LOWER"]:
        for d in 0 .. 1:
          let insz = x.dims[2 + d]
          let o = (insz + int(st[d]) - 1) div int(st[d])
          let total = max(0, (o - 1) * int(st[d]) + int(dl[d]) * (int(kshape[d]) - 1) + 1 - insz)
          let small = total div 2
          if ap == "SAME_UPPER": (pd[d] = small; pd[d + 2] = total - small)
          else: (pd[d] = total - small; pd[d + 2] = small)
    var s, p, dd: seq[int]
    for v in st: s.add int(v)
    for v in pd: p.add int(v)
    for v in dl: dd.add int(v)
    result = @[conv(x, w, (if has(2): inp(2).asFloat else: Tensor()), s, p, dd, int(node.intAttr("group", 1)),
                    relu = fuse)]
  of "ConvTranspose":
    if ins[1].isInt: ins[1] = ins[1].asFloat
    template w: Tensor = ins[1]
    var st, dl, pd, op2, given: seq[int]
    for v in node.intsAttr("strides"): st.add int(v)
    for v in node.intsAttr("dilations"): dl.add int(v)
    for v in node.intsAttr("pads"): pd.add int(v)
    for v in node.intsAttr("output_padding"): op2.add int(v)
    for v in node.intsAttr("output_shape"): given.add int(v)
    if st.len == 0: st = @[1, 1]
    if dl.len == 0: dl = @[1, 1]
    if pd.len == 0: pd = @[0, 0, 0, 0]
    if op2.len == 0: op2 = @[0, 0]
    let os2 = if given.len > 2: given[^2 .. ^1] else: given
    result = @[convTranspose(inp(0), w, (if has(2): inp(2).asFloat else: Tensor()), st, pd, dl, op2,
                             int(node.intAttr("group", 1)), os2)]
  # (normalizations)
  of "BatchNormalization":
    # (in place, the channels shared among the cores -- one after a Conv is folded into it)
    var r = if inp(0).isInt: inp(0).asFloat else: move(ins[0])
    let (sc, bi, mean, vr) = (inp(1).asFloat, inp(2).asFloat, inp(3).asFloat, inp(4).asFloat)
    let eps = node.floatAttr("epsilon", 1e-5)
    let c = r.dims[1]
    let hw = count(r.dims[2 .. ^1])
    let rp = cast[ptr UncheckedArray[float32]](if r.f.len > 0: addr r.f[0] else: nil)
    netFor(r.dims[0] * c, proc (lo, hi: int) =
      for bc in lo ..< hi:
        let ch = bc mod c
        let k = sc.f[ch] / sqrt(vr.f[ch] + eps)
        let o = bi.f[ch] - mean.f[ch] * k
        for q in 0 ..< hw: rp[bc * hw + q] = rp[bc * hw + q] * k + o,
      grain = max(1, 16384 div max(1, hw)))
    result = @[r]
  of "LayerNormalization":
    let axis = axisOf(int(node.intAttr("axis", -1)), inp(0).dims.len)
    result = @[layerNorm(move(ins[0]), inp(1).asFloat, (if has(2): inp(2).asFloat else: Tensor()), axis,
                         node.floatAttr("epsilon", 1e-5))]
  of "InstanceNormalization":
    let channels = inp(0).dims[1]
    result = @[channelNorm(move(ins[0]), inp(1).asFloat, inp(2).asFloat, channels, node.floatAttr("epsilon", 1e-5))]
  of "GroupNormalization":
    result = @[channelNorm(move(ins[0]), inp(1).asFloat, inp(2).asFloat, int(node.intAttr("num_groups", 1)),
                           node.floatAttr("epsilon", 1e-5))]
  of "Softmax", "LogSoftmax":
    var r = if inp(0).isInt: inp(0).asFloat else: move(ins[0])
    let axis = axisOf(int(node.intAttr("axis", (if opset >= 13: -1 else: 1))), r.dims.len)
    if opset < 13 and axis != r.dims.high:
      # (before opset 13: the sizes from the axis on taken as one)
      let d = r.dims
      r.dims = d[0 ..< axis] & @[count(d[axis .. ^1])]
      softmaxLast(r, axis)
      r.dims = d
    else: softmaxLast(r, axis)
    if op == "LogSoftmax":
      for v in r.f.mitems: v = ln(v)
    result = @[r]
  # (pools)
  of "MaxPool", "AveragePool":
    var k, s, p: seq[int]
    for v in node.intsAttr("kernel_shape"): k.add int(v)
    for v in node.intsAttr("strides"): s.add int(v)
    for v in node.intsAttr("pads"): p.add int(v)
    if s.len == 0: s = @[1, 1]
    if p.len == 0 and node.strAttr("auto_pad", "NOTSET") in ["SAME_UPPER", "SAME_LOWER"]:
      let x = inp(0)
      p = @[0, 0, 0, 0]
      for d in 0 .. 1:
        let o = (x.dims[2 + d] + s[d] - 1) div s[d]
        let total = max(0, (o - 1) * s[d] + k[d] - x.dims[2 + d])
        let small = total div 2
        if node.strAttr("auto_pad") == "SAME_UPPER": (p[d] = small; p[d + 2] = total - small)
        else: (p[d] = total - small; p[d + 2] = small)
    if p.len == 0: p = @[0, 0, 0, 0]
    result = @[pool(inp(0), k, s, p, op == "MaxPool", node.intAttr("count_include_pad", 0) != 0,
                    node.intAttr("ceil_mode", 0) != 0)]
  of "GlobalAveragePool", "GlobalMaxPool":
    let x = inp(0).asFloat
    let (n, c) = (x.dims[0], x.dims[1])
    let hw = count(x.dims[2 .. ^1])
    var r = floats([n, c, 1, 1])
    for b in 0 ..< n * c:
      var acc = if op == "GlobalMaxPool": -Inf.float32 else: 0'f32
      for q in 0 ..< hw:
        let v = x.f[b * hw + q]
        if op == "GlobalMaxPool": acc = max(acc, v) else: acc += v
      r.f[b] = if op == "GlobalMaxPool": acc else: acc / float32(hw)
    r.dims = @[n, c] & newSeq[int](x.dims.len - 2)
    for k in 2 ..< r.dims.len: r.dims[k] = 1
    result = @[r]
  of "ReduceMean", "ReduceSum", "ReduceMax", "ReduceMin", "ReduceProd":
    let x = inp(0)
    let fx = x.asFloat
    var axes: seq[int]
    var given: seq[int]
    if opset >= 18 or (op == "ReduceSum" and opset >= 13):
      if has(1): given = ints(inp(1))
    else:
      for v in node.intsAttr("axes"): given.add int(v)
    for a in given: axes.add axisOf(a, fx.dims.len)
    if axes.len == 0:
      for k in 0 ..< fx.dims.len: axes.add k
    let keep = node.intAttr("keepdims", 1) != 0
    var dims = fx.dims
    for a in axes: dims[a] = 1
    var r = floats(dims)
    let init = case op
               of "ReduceMax": -Inf.float32
               of "ReduceMin": Inf.float32
               of "ReduceProd": 1'f32
               else: 0'f32
    for v in r.f.mitems: v = init
    let m = indexMap(dims, fx.dims)
    for k in 0 ..< fx.f.len:
      let at = m[k]
      case op
      of "ReduceMax": r.f[at] = max(r.f[at], fx.f[k])
      of "ReduceMin": r.f[at] = min(r.f[at], fx.f[k])
      of "ReduceProd": r.f[at] *= fx.f[k]
      else: r.f[at] += fx.f[k]
    if op == "ReduceMean":
      let n = fx.f.len div max(1, r.f.len)
      for v in r.f.mitems: v /= float32(n)
    if not keep:
      var d2: seq[int]
      for k, d in dims:
        if k notin axes: d2.add d
      r.dims = d2
    result = @[if x.isInt: r.asInt else: r]
  of "ArgMax", "ArgMin":
    let x = inp(0).asFloat
    let axis = axisOf(int(node.intAttr("axis", 0)), x.dims.len)
    let keep = node.intAttr("keepdims", 1) != 0
    let inner = count(x.dims[axis + 1 .. ^1])
    let outer = count(x.dims[0 ..< axis])
    var dims = x.dims
    dims[axis] = 1
    var r = wholes(dims)
    for a in 0 ..< outer:
      for q in 0 ..< inner:
        var best = 0
        for k in 1 ..< x.dims[axis]:
          let v = x.f[(a * x.dims[axis] + k) * inner + q]
          let bv = x.f[(a * x.dims[axis] + best) * inner + q]
          if (op == "ArgMax" and v > bv) or (op == "ArgMin" and v < bv): best = k
        r.i[a * inner + q] = best
    if not keep: r.dims.delete(axis)
    result = @[r]
  # (shapes)
  of "Shape":
    var all: seq[int64]
    for v in inp(0).dims: all.add int64(v)
    let start = int(node.intAttr("start", 0))
    let stop = int(node.intAttr("end", int64(all.len)))
    let a = clamp(if start < 0: start + all.len else: start, 0, all.len)
    let b = clamp(if stop < 0: stop + all.len else: stop, 0, all.len)
    let d = all[a ..< b]
    result = @[wholes([d.len], d)]
  of "Size": result = @[wholes([], [int64(inp(0).len)])]
  of "Reshape": result = @[inp(0).reshaped(inp(1).asInt.i, node.intAttr("allowzero", 0) != 0)]
  of "Flatten":
    let x = inp(0)
    let axis = axisOf(int(node.intAttr("axis", 1)), x.dims.len + 1)
    result = @[x.reshaped([int64(count(x.dims[0 ..< axis])), int64(count(x.dims[axis .. ^1]))])]
  of "Squeeze", "Unsqueeze":
    let x = inp(0)
    var axes: seq[int]
    if opset >= 13: axes = if has(1): ints(inp(1)) else: @[]
    else:
      for v in node.intsAttr("axes"): axes.add int(v)
    var dims = x.dims
    if op == "Squeeze":
      var d2: seq[int]
      let norm = block:
        var a: seq[int]
        for v in axes: a.add axisOf(v, dims.len)
        a
      for k, d in dims:
        if (norm.len == 0 and d == 1) or k in norm: continue
        d2.add d
      dims = d2
    else:
      let rank = dims.len + axes.len
      var norm: seq[int]
      for v in axes: norm.add(if v < 0: v + rank else: v)
      norm.sort()
      for a in norm: dims.insert(1, a)
    var r = x
    r.dims = dims
    result = @[r]
  of "Transpose":
    var p: seq[int]
    for v in node.intsAttr("perm"): p.add int(v)
    result = @[inp(0).transposed(p)]
  of "Concat":
    let axis = axisOf(int(node.intAttr("axis", 0)), ins[0].dims.len)
    result = @[concat(ins.toOpenArray(0, node.inputs.len - 1), axis)]
  of "Split":
    let x = inp(0)
    let axis = axisOf(int(node.intAttr("axis", 0)), x.dims.len)
    var sizes: seq[int]
    if has(1): sizes = ints(inp(1))
    else:
      for v in node.intsAttr("split"): sizes.add int(v)
    if sizes.len == 0:
      let parts = node.outputs.len
      for k in 0 ..< parts: sizes.add x.dims[axis] div parts
    var at = 0
    for s in sizes:
      result.add x.sliceAxis(axis, at, at + s, 1)
      at += s
  of "Slice":
    var x = inp(0)
    var starts, ends, axes, steps: seq[int]
    if opset >= 10:
      starts = ints(inp(1))
      ends = ints(inp(2))
      if has(3): axes = ints(inp(3))
      if has(4): steps = ints(inp(4))
    else:
      for v in node.intsAttr("starts"): starts.add int(v)
      for v in node.intsAttr("ends"): ends.add int(v)
      for v in node.intsAttr("axes"): axes.add int(v)
    if axes.len == 0:
      for k in 0 ..< starts.len: axes.add k
    for k, a0 in axes:
      let a = axisOf(a0, x.dims.len)
      let d = x.dims[a]
      let step = if k < steps.len: steps[k] else: 1
      var s = starts[k]
      var e = ends[k]
      if s < 0: s += d
      if e < 0: e += d
      if step > 0:
        s = clamp(s, 0, d)
        e = clamp(e, 0, d)
      else:
        s = clamp(s, -1, d - 1)
        e = clamp(e, -1, d - 1)
      x = x.sliceAxis(a, s, e, step)
    result = @[x]
  of "Gather":
    let x = inp(0)
    result = @[x.gathered(inp(1), axisOf(int(node.intAttr("axis", 0)), x.dims.len))]
  of "Constant":
    let a = node.attrs[0]
    case a.name
    of "value": result = @[a.t.toTensor]
    of "value_float": result = @[floats([], a.f)]
    of "value_floats": result = @[Tensor(dims: @[a.floats.len], f: a.floats)]
    of "value_int": result = @[wholes([], [a.i])]
    of "value_ints": result = @[wholes([a.ints.len], a.ints)]
    else: fail("Constant: " & a.name & " is not read here")
    if result[0].dims.len == 0 and result[0].len != 1:
      result[0].dims = @[result[0].len]
  of "ConstantOfShape":
    let dims = ints(inp(0))
    let a = node.attr("value")
    if a.name.len > 0 and a.t.kind notin {otFloat, otFloat16, otDouble, otUndefined}:
      result = @[wholes(dims)]
      let v = if a.t.ints.len > 0: a.t.ints[0] else: 0
      for x in result[0].i.mitems: x = v
    else:
      result = @[floats(dims, if a.name.len > 0 and a.t.floats.len > 0: a.t.floats[0] else: 0)]
  of "Expand":
    let x = inp(0)
    let dims = broadcastDims(x.dims, ints(inp(1)))
    let m = indexMap(x.dims, dims)
    var r = Tensor(dims: dims, isInt: x.isInt)
    if x.isInt:
      r.i = newSeq[int64](m.len)
      for k, at in m: r.i[k] = x.i[at]
    else:
      r.f = newSeq[float32](m.len)
      for k, at in m: r.f[k] = x.f[at]
    result = @[r]
  of "Tile":
    var x = inp(0)
    let reps = ints(inp(1))
    for a, rep in reps:
      if rep > 1:
        var parts = newSeq[Tensor](rep)
        for k in 0 ..< rep: parts[k] = x
        x = concat(parts, a)
    result = @[x]
  of "Cast":
    let to = OnnxType(int(node.intAttr("to", 1)))
    result = @[if to in {otFloat, otFloat16, otDouble, otBfloat16}: inp(0).asFloat else: inp(0).asInt]
    if to == otBool:
      for v in result[0].i.mitems: v = (if v != 0: 1 else: 0)
  of "Range":
    let (s, l, d) = (inp(0), inp(1), inp(2))
    if s.isInt and l.isInt and d.isInt:
      var vals: seq[int64]
      var v = s.i[0]
      while (d.i[0] > 0 and v < l.i[0]) or (d.i[0] < 0 and v > l.i[0]):
        vals.add v
        v += d.i[0]
      result = @[wholes([vals.len], vals)]
    else:
      let (fs, fl, fd) = (s.asFloat.f[0], l.asFloat.f[0], d.asFloat.f[0])
      let n = max(0, int(ceil((fl - fs) / fd)))
      var r = floats([n])
      for k in 0 ..< n: r.f[k] = fs + float32(k) * fd
      result = @[r]
  of "Resize", "Upsample":
    let x = inp(0)
    var outDims = x.dims
    var scales: seq[float32]
    var sizes: seq[int]
    if op == "Upsample": scales = inp(1).asFloat.f
    else:
      let si = if opset >= 11: 2 else: 1
      if has(si): scales = inp(si).asFloat.f
      if opset >= 11 and has(3): sizes = ints(inp(3))
    var sc = newSeq[float](outDims.len)
    if sizes.len > 0:
      outDims = sizes
      for k in 0 ..< outDims.len: sc[k] = float(outDims[k]) / float(max(1, x.dims[k]))
    elif scales.len > 0:
      for k in 0 ..< outDims.len:
        outDims[k] = int(floor(float32(x.dims[k]) * scales[k]))
        sc[k] = float(scales[k])
    let mode = node.strAttr("mode", "nearest")
    let r = outDims.len
    for k in 0 ..< r - 2:
      if outDims[k] != x.dims[k]: fail("Resize: only the last two sizes (" & $x.dims & " to " & $outDims & ")")
    result = @[resize(x, outDims, mode,
                      node.strAttr("coordinate_transformation_mode", (if op == "Upsample": "asymmetric" else: "half_pixel")),
                      node.strAttr("nearest_mode", (if op == "Upsample": "floor" else: "round_prefer_floor")),
                      sc[r - 2], sc[r - 1], node.floatAttr("cubic_coeff_a", -0.75),
                      node.intAttr("exclude_outside", 0) != 0)]
  of "Pad":
    let x = inp(0).asFloat
    var pads: seq[int]
    if opset >= 11: pads = ints(inp(1))
    else:
      for v in node.intsAttr("pads"): pads.add int(v)
    let value = if opset >= 11 and has(2): inp(2).asFloat.f[0] else: node.floatAttr("value", 0)
    let mode = node.strAttr("mode", "constant")
    let r = x.dims.len
    var dims = x.dims
    for k in 0 ..< r: dims[k] += pads[k] + pads[k + r]
    var res = floats(dims, value)
    let ds = strides(dims)
    let ss = strides(x.dims)
    for o in 0 ..< res.f.len:
      var rem = o
      var at = 0
      var inside = true
      for k in 0 ..< r:
        var c = rem div ds[k] - pads[k]
        rem = rem mod ds[k]
        if c < 0 or c >= x.dims[k]:
          case mode
          of "reflect": c = (if c < 0: -c else: 2 * (x.dims[k] - 1) - c)
          of "edge": c = clamp(c, 0, x.dims[k] - 1)
          else: inside = false
        at += c * ss[k]
      if inside: res.f[o] = x.f[at]
    result = @[res]
  of "DepthToSpace", "SpaceToDepth":
    let x = inp(0).asFloat
    let bs = int(node.intAttr("blocksize", 2))
    let (n, c, h, w) = (x.dims[0], x.dims[1], x.dims[2], x.dims[3])
    if op == "DepthToSpace":
      let crd = node.strAttr("mode", "DCR") == "CRD"
      let oc = c div (bs * bs)
      var r = floats([n, oc, h * bs, w * bs])
      for b in 0 ..< n:
        for ch in 0 ..< c:
          let (o, by, bx) = if crd: (ch div (bs * bs), (ch div bs) mod bs, ch mod bs)
                            else: (ch mod oc, ch div (oc * bs), (ch div oc) mod bs)
          for y in 0 ..< h:
            for xx in 0 ..< w:
              r.f[((b * oc + o) * h * bs + y * bs + by) * w * bs + xx * bs + bx] = x.f[((b * c + ch) * h + y) * w + xx]
      result = @[r]
    else:
      let oc = c * bs * bs
      var r = floats([n, oc, h div bs, w div bs])
      for b in 0 ..< n:
        for ch in 0 ..< c:
          for y in 0 ..< h:
            for xx in 0 ..< w:
              let o = ((y mod bs) * bs + xx mod bs) * c + ch
              r.f[((b * oc + o) * (h div bs) + y div bs) * (w div bs) + xx div bs] = x.f[((b * c + ch) * h + y) * w + xx]
      result = @[r]
  of "DFT":
    # (ONNX's DFT, opset 17 on: the last size of the input is 1 -- real -- or 2 -- complex; along
    # `axis`; `onesided` keeps the first half; `inverse` goes back, divided by the length)
    let x = inp(0).asFloat
    var axis = int(node.intAttr("axis", 1))
    if opset >= 20 and has(2): axis = ints(inp(2))[0]
    let r = x.dims.len
    axis = if axis < 0: axis + r else: axis
    let inverse = node.intAttr("inverse", 0) != 0
    let onesided = node.intAttr("onesided", 0) != 0
    let complexIn = x.dims[^1] == 2
    var n = x.dims[axis]
    if has(1): n = ints(inp(1))[0]
    let inner = count(x.dims[axis + 1 ..< r - 1])
    let outer = count(x.dims[0 ..< axis])
    let outN = if onesided: n div 2 + 1 else: n
    var dims = x.dims
    dims[axis] = outN
    dims[^1] = 2
    var res = floats(dims)
    let sign = if inverse: 1.0 else: -1.0
    let inN = x.dims[axis]
    for a in 0 ..< outer:
      for q in 0 ..< inner:
        for k in 0 ..< outN:
          var re, im = 0.0
          for t in 0 ..< min(n, inN):
            let at = ((a * inN + t) * inner + q) * x.dims[^1]
            let xr = float(x.f[at])
            let xi = if complexIn: float(x.f[at + 1]) else: 0.0
            let ang = sign * 2 * PI * float(k * t mod n) / float(n)
            re += xr * cos(ang) - xi * sin(ang)
            im += xr * sin(ang) + xi * cos(ang)
          if inverse:
            re /= float(n)
            im /= float(n)
          let o = ((a * outN + k) * inner + q) * 2
          res.f[o] = float32(re)
          res.f[o + 1] = float32(im)
    result = @[res]
  else: fail("an operation not run here: " & op & (if node.domain.len > 0: " (" & node.domain & ")" else: ""))

proc prepare(net: Net) =
  ## (the graph made quicker once, before it first runs: its Constant nodes made weights; a
  ## BatchNormalization right after a Conv folded into the Conv's weights and bias -- what
  ## each makes the same, to a float's rounding)
  if net.prepared: return
  net.prepared = true
  var g = addr net.model.graph
  var kept: seq[OnnxNode]
  for node in g.nodes:
    if node.op == "Constant" and node.outputs.len == 1 and node.attrs.len > 0:
      var none = newSeq[Tensor](8)
      net.weights[node.outputs[0]] = runNode(node, none, net.model.opset)[0]
    else: kept.add node
  g.nodes = kept
  var uses: CountTable[string]
  for n in g.nodes:
    for i in n.inputs: uses.inc i
  var outs: seq[string]
  for o in g.outputs: outs.add o.name
  var producer: Table[string, int]
  for k, n in g.nodes:
    for o in n.outputs: producer[o] = k
  var drop = newSeq[bool](g.nodes.len)
  for k, n in g.nodes:
    if n.op != "BatchNormalization" or n.inputs.len < 5 or n.outputs.len != 1: continue
    let src = n.inputs[0]
    let pk = producer.getOrDefault(src, -1)
    if pk < 0 or g.nodes[pk].op != "Conv" or uses[src] != 1 or src in outs: continue
    let c = g.nodes[pk]
    if c.inputs.len < 2 or c.inputs[1] notin net.weights: continue
    let hasBias = c.inputs.len >= 3 and c.inputs[2].len > 0
    if hasBias and c.inputs[2] notin net.weights: continue
    var ok = true
    for i in 1 .. 4:
      if n.inputs[i] notin net.weights or net.weights[n.inputs[i]].isInt: ok = false
    let w = net.weights[c.inputs[1]]
    if not ok or w.isInt or w.dims.len != 4: continue
    let oc = w.dims[0]
    let (sc, bi, mean, vr) = (net.weights[n.inputs[1]], net.weights[n.inputs[2]], net.weights[n.inputs[3]],
                              net.weights[n.inputs[4]])
    if sc.f.len != oc or bi.f.len != oc or mean.f.len != oc or vr.f.len != oc: continue
    let eps = n.floatAttr("epsilon", 1e-5)
    var w2 = w
    var b2 = floats([oc])
    let per = w.f.len div oc
    for o in 0 ..< oc:
      let k = sc.f[o] / sqrt(vr.f[o] + eps)
      for i in 0 ..< per: w2.f[o * per + i] = w.f[o * per + i] * k
      let b0 = if hasBias: net.weights[c.inputs[2]].f[o] else: 0'f32
      b2.f[o] = (b0 - mean.f[o]) * k + bi.f[o]
    let wn = n.outputs[0] & "#folded.w"
    let bn = n.outputs[0] & "#folded.b"
    net.weights[wn] = w2
    net.weights[bn] = b2
    g.nodes[pk].inputs = @[c.inputs[0], wn, bn]
    g.nodes[pk].outputs = n.outputs
    drop[k] = true
  kept.setLen(0)
  for k, n in g.nodes:
    if not drop[k]: kept.add n
  g.nodes = kept
  # (weights nothing takes any more: let go)
  var used: CountTable[string]
  for n in g.nodes:
    for i in n.inputs: used.inc i
  var gone: seq[string]
  for k in net.weights.keys:
    if used[k] == 0 and k notin outs: gone.add k
  for k in gone: net.weights.del k

var
  netProfile* = false
    ## `run` adds up the time each kind of operation takes into `netTimes` (to find what to make
    ## quicker).
  netTimes*: CountTable[string]
    ## The microseconds each kind of operation took, while `netProfile`.

proc run*(net: Net; inputs: openArray[(string, Tensor)]; stop: proc (): bool {.closure.} = nil):
    Table[string, Tensor] =
  ## The model worked out for `inputs` (by the graph's input names): its outputs by name. Raises
  ## `NetError` for an operation not run here; `stop` (asked between operations) ends it early,
  ## with no outputs.
  when compileOption("threads"):
    nStart()
    acquire(nUse)                   # (one model at a time on the runner's threads)
  defer:
    when compileOption("threads"): release(nUse)
  net.prepare()
  var env: Table[string, Tensor]
  for (k, t) in inputs: env[k] = t
  # (what each value is still needed for: let go after its last use -- moved, not copied, into it)
  var uses: Table[string, int]
  for node in net.model.graph.nodes:
    for i in node.inputs: uses.mgetOrPut(i, 0).inc
  var keep: seq[string]
  for o in net.model.graph.outputs: keep.add o.name
  # (a Conv whose one use is a Relu: the two in one pass, the Relu's output the Conv's)
  let nodes = net.model.graph.nodes
  var userOf: Table[string, int]
  for k, node in nodes:
    for i in node.inputs:
      if uses.getOrDefault(i) == 1: userOf[i] = k
  var fused = newSeq[bool](nodes.len)       # (a Conv run with its Relu)
  var skipped = newSeq[bool](nodes.len)     # (the Relu, then)
  for k, node in nodes:
    if node.op == "Conv" and node.outputs.len == 1 and node.outputs[0] notin keep:
      let u = userOf.getOrDefault(node.outputs[0], -1)
      if u > k and nodes[u].op == "Relu" and nodes[u].outputs.len == 1:
        fused[k] = true
        skipped[u] = true
  for ni, node in nodes:
    if skipped[ni]: continue
    if stop != nil and stop(): return
    var ins = newSeq[Tensor](max(8, node.inputs.len))
    for k, i in node.inputs:
      if i.len == 0: continue
      if i in env:
        dec uses[i]
        if uses[i] == 0 and i notin keep:
          discard env.pop(i, ins[k])
        else: ins[k] = env[i]
      elif i in net.weights: ins[k] = net.weights[i]
      else:
        # (the same value twice in one node, moved at its last: the copy before it)
        var found = false
        for j in 0 ..< k:
          if node.inputs[j] == i:
            ins[k] = ins[j]
            found = true
        if not found: fail(node.op & " " & node.name & ": " & i & " is not there")
    let t0 = if netProfile: getMonoTime() else: MonoTime()
    let outs = runNode(node, ins, net.model.opset, fused[ni])
    if netProfile: netTimes.inc(node.op, int((getMonoTime() - t0).inMicroseconds))
    if fused[ni]:
      env[nodes[userOf[node.outputs[0]]].outputs[0]] = outs[0]
      continue
    for k, o in node.outputs:
      if o.len > 0 and k < outs.len: env[o] = outs[k]
  for o in net.model.graph.outputs:
    if o.name in env: result[o.name] = env[o.name]
    elif o.name in net.weights: result[o.name] = net.weights[o.name]   # (a constant)

## Numbers on the GPU (`retroui/gpucompute`): products of matrices worked out in an off-screen
## context of the thread's own -- four floats a texel with float textures, else floats carried in
## 8-bit textures (both ways tried) -- the CPU's within rounding: small and odd sizes, a shared
## length over many passes, more rows than one band, negatives, zeros, tiny and huge numbers; a
## context on another thread too, none on a thread drawing with EGL already. Then the image
## models' runner (`retroui/nnet`) with the GPU: a convolution, a linear layer and attention's
## products as the CPU makes them. Skipped where there is no OpenGL.

import std/[math, random, monotimes, times, strutils]
import retroui/[gpucompute, nnet]
import retroui/uirelays/eglload

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

proc cpuMatmul(a, b: seq[float32]; m, k, n: int): seq[float32] =
  result = newSeq[float32](m * n)
  for i in 0 ..< m:
    for t in 0 ..< k:
      let av = float64(a[i * k + t])
      for j in 0 ..< n: result[i * n + j] = float32(float64(result[i * n + j]) + av * float64(b[t * n + j]))

proc worst(x, y: seq[float32]; scale: seq[float32] = @[]): float =
  ## (the largest difference, as a part of how big the numbers are)
  var big = 1e-30
  for v in y: big = max(big, abs(v.float))
  for i in 0 ..< x.len: result = max(result, abs(x[i].float - y[i].float) / big)

if not computeReady():
  echo "  (no OpenGL here: numbers on the GPU not tried)"
  echo "test_gpucompute: all passed"
  quit 0

echo "  (on ", computeRenderer(), (if computeSoftware(): ", the processor drawing" else: ""),
     (if computeFloats(): ", float textures" else: ", 8-bit textures"), ")"
var rng = initRand(7)
proc randoms(n: int; lo = -1.0; hi = 1.0): seq[float32] =
  for _ in 0 ..< n: result.add float32(rng.rand(lo .. hi))

block exact:
  # (whole numbers: the products exact both ways)
  let a = @[1'f32, 2, 3, 4, 5, 6]
  let b = @[7'f32, 8, 9, 10, 11, 12]
  let c = gpuMatmul(a, b, 2, 3, 2)
  check c == @[58'f32, 64, 139, 154], "2x3 by 3x2: " & $c

block sizes:
  for (m, k, n) in [(1, 1, 1), (3, 5, 7), (17, 300, 9), (64, 700, 33), (5, 1, 40)]:
    let a = randoms(m * k)
    let b = randoms(k * n)
    let g = gpuMatmul(a, b, m, k, n)
    let c = cpuMatmul(a, b, m, k, n)
    check g.len == m * n and worst(g, c) < 1e-5, $m & "x" & $k & " by " & $k & "x" & $n & ": the CPU's within " &
          "rounding (" & formatFloat(worst(g, c), ffScientific, 1) & ")"

block eightBit:
  # (the 8-bit way, as an OpenGL ES 2 GPU has it: on a thread of its own, float textures not used)
  var ok = true
  var info = ""
  proc work(p: ptr (bool, string)) {.thread.} =
    {.cast(gcsafe).}:
      computeNoFloats = true
      var r = initRand(3)
      var good = computeReady() and not computeFloats()
      for (m, k, n) in [(3, 5, 7), (40, 600, 21)]:
        var a, b: seq[float32]
        for _ in 0 ..< m * k: a.add float32(r.rand(-1.0 .. 1.0))
        for _ in 0 ..< k * n: b.add float32(r.rand(-1.0 .. 1.0))
        let g = gpuMatmul(a, b, m, k, n)
        let c = cpuMatmul(a, b, m, k, n)
        if g.len != c.len or worst(g, c) >= 1e-5: good = false
        p[][1].add formatFloat(worst(g, c), ffScientific, 1) & " "
      p[][0] = good
  var res: (bool, string)
  var th: Thread[ptr (bool, string)]
  createThread(th, work, addr res)
  joinThread(th)
  check res[0], "the 8-bit way: the CPU's within rounding (" & res[1].strip & ")"

block numbers:
  var a = @[0'f32, -0.0, 1e-30, -3.5e20, 1e-20, 7.25, -1, 0.1]
  var b = @[2'f32, 3, 1e10, -2e-18, 4, 0.5, -8, 1e-3]
  let g = gpuMatmul(a, b, 8, 1, 8)
  let c = cpuMatmul(a, b, 8, 1, 8)
  var ok = true
  for i in 0 ..< c.len:
    if abs(g[i] - c[i]) > abs(c[i]) * 1e-6 + 1e-37: ok = false
  check ok, "zeros, negatives, tiny and huge numbers carried as they are"

block band:
  let mt = computeMaxSide()
  check mt >= 64, "the GPU takes sides of " & $mt
  let m = min(mt + 37, 20000)
  let a = randoms(m * 3)
  let b = randoms(3 * 4)
  let g = gpuMatmul(a, b, m, 3, 4)
  let c = cpuMatmul(a, b, m, 3, 4)
  check g.len == m * 4 and worst(g, c) < 1e-5, "more rows than the GPU takes at once (" & $m & ")"
  let kMax = if computeFloats(): 4 * mt else: mt     # (four floats a texel with float textures)
  check gpuMatmul(randoms(2 * (kMax + 1)), randoms((kMax + 1) * 2), 2, kMax + 1, 2).len == 0,
        "a shared length longer than it takes: empty (the CPU's work)"

block otherThread:
  var res: seq[float32]
  proc work(p: ptr seq[float32]) {.thread.} =
    {.cast(gcsafe).}:
      p[] = gpuMatmul(@[1'f32, 2, 3, 4], @[1'f32, 0, 0, 1], 2, 2, 2)
  var th: Thread[ptr seq[float32]]
  createThread(th, work, addr res)
  joinThread(th)
  check res == @[1'f32, 2, 3, 4], "another thread: its own context"

block drawingThread:
  # (a thread with a context of its own current -- the one drawing a window -- gets none: making one
  # current there would take the window's away)
  var res = false
  proc work(p: ptr bool) {.thread.} =
    {.cast(gcsafe).}:
      var e: Egl
      p[] = if e.openOffscreen(4, 4): not computeReady() else: true
  var th: Thread[ptr bool]
  createThread(th, work, addr res)
  joinThread(th)
  check res, "a thread drawing with EGL already: no context made there"

# ---- the image models' runner -------------------------------------------------------------------------------

proc compare(what: string; body: proc (): Tensor) =
  setNetGpu(-1)
  let t0 = getMonoTime()
  let c = body()
  let cpuMs = (getMonoTime() - t0).inMicroseconds.float / 1000
  setNetGpu(1)
  let t1 = getMonoTime()
  let g = body()
  let gpuMs = (getMonoTime() - t1).inMicroseconds.float / 1000
  setNetGpu(0)
  check c.dims == g.dims and worst(g.f, c.f) < 2e-5,
        what & ": the CPU's within rounding (" & formatFloat(worst(g.f, c.f), ffScientific, 1) &
        "; " & formatFloat(cpuMs, ffDecimal, 1) & " ms on the CPU, " & formatFloat(gpuMs, ffDecimal, 1) &
        " ms on the GPU)"

block runner:
  setNetGpuWork(0)                     # (every product on the GPU, however small)
  var x = floats([1, 16, 40, 40])
  for v in x.f.mitems: v = float32(rng.rand(-1.0 .. 1.0))
  var w = floats([32, 16, 3, 3])
  for v in w.f.mitems: v = float32(rng.rand(-0.2 .. 0.2))
  var bias = floats([32])
  for v in bias.f.mitems: v = float32(rng.rand(-0.1 .. 0.1))
  compare("a 3 x 3 convolution, 16 to 32 channels", proc (): Tensor =
    conv(x, w, bias, @[1, 1], @[1, 1, 1, 1], @[1, 1], 1, relu = true))
  var w1 = floats([64, 16, 1, 1])
  for v in w1.f.mitems: v = float32(rng.rand(-0.2 .. 0.2))
  compare("a 1 x 1 convolution", proc (): Tensor =
    conv(x, w1, Tensor(), @[1, 1], @[0, 0, 0, 0], @[1, 1], 1))
  var q = floats([4, 77, 64])
  for v in q.f.mitems: v = float32(rng.rand(-1.0 .. 1.0))
  var kt = floats([4, 64, 77])
  for v in kt.f.mitems: v = float32(rng.rand(-1.0 .. 1.0))
  compare("attention's products, four heads", proc (): Tensor = matmul(q, kt))
  setNetGpuWork(-1)

if failures > 0:
  echo "test_gpucompute: ", failures, " failed"
  quit(1)
echo "test_gpucompute: all passed"

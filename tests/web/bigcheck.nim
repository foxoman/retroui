## What a big app needs in a page (`retroweb --threads`): the page's checks for
## tests/web/big.js. A big file written where the page keeps files (/data) comes back on the next
## visit left in the browser's storage, read a piece at a time through the C library -- seeks,
## reads across pieces, the end --; then numbers worked out with WebGPU for a thread (the image
## models' products), the CPU's within rounding, or the page says it has none. An app, as a real
## one is: the page's own thread free between frames (WebGPU answers there).

import std/[os, strutils, math, monotimes, times, atomics]
import retroui
import retroui/gpucompute

proc check(ok: bool; what: string) =
  echo (if ok: "PASS " else: "FAIL "), what

const Big = "/data/big.bin"
const Size = 20 shl 20 + 12345      # (five 4 MB pieces and a bit)

proc byteAt(i: int): byte = byte((i * 31 + (i shr 12)) and 255)

proc bigFile() =
  if not fileExists(Big):
    var s = newString(Size)
    for i in 0 ..< Size: s[i] = char(byteAt(i))
    writeFile(Big, s)
    echo "BIG WRITTEN ", getFileSize(Big)
    return
  check getFileSize(Big) == Size, "the big file's size kept: " & $getFileSize(Big)
  var f = open(Big)
  var ok = true
  for at in [0, 4 shl 20 - 3, 9_000_001, Size - 10]:
    f.setFilePos(at)
    var buf = newString(10)
    let n = f.readBuffer(addr buf[0], 10)
    for k in 0 ..< n:
      if buf[k] != char(byteAt(at + k)): ok = false
    if at == Size - 10 and n != 10: ok = false
  # (all of it, read in one go: every piece)
  f.setFilePos(0)
  let all = f.readAll()
  f.close()
  var sum = 0
  for i in 0 ..< all.len: sum = (sum + int(all[i]) * (i mod 7 + 1)) mod 1_000_003
  var want = 0
  for i in 0 ..< Size: want = (want + int(byteAt(i)) * (i mod 7 + 1)) mod 1_000_003
  check ok, "read where it was asked: across pieces, at the end"
  check all.len == Size and sum == want, "read whole: " & $all.len & " bytes, the same"
  echo "BIG READ"

when compileOption("threads"):
  import std/typedthreads

  proc cpuMatmul(a, b: seq[float32]; m, k, n: int): seq[float32] =
    result = newSeq[float32](m * n)
    for i in 0 ..< m:
      for t in 0 ..< k:
        for j in 0 ..< n: result[i * n + j] += a[i * k + t] * b[t * n + j]

  var gpuSays: string
  var gpuDone: Atomic[bool]

  proc gpuWork(x: int) {.thread.} =
    {.cast(gcsafe).}:
      # (the device is made while the page loads: a moment, at most)
      var tries = 0
      while not computeReady() and tries < 100:
        sleep(50)
        inc tries
      if not computeReady():
        gpuSays = "NONE"
        gpuDone.store(true)
        return
      var a, b: seq[float32]
      let (m, k, n) = (37, 300, 45)
      for i in 0 ..< m * k: a.add float32(sin(i.float * 0.37))
      for i in 0 ..< k * n: b.add float32(cos(i.float * 0.11))
      let t0 = getMonoTime()
      let g = gpuMatmul(a, b, m, k, n)
      let ms = (getMonoTime() - t0).inMicroseconds.float / 1000
      let c = cpuMatmul(a, b, m, k, n)
      var worst = 0.0
      var big = 1e-9
      for v in c: big = max(big, abs(v.float))
      if g.len == c.len:
        for i in 0 ..< c.len: worst = max(worst, abs(g[i] - c[i]).float / big)
      gpuSays = (if g.len == c.len and worst < 1e-5: "OK " else: "BAD ") & computeRenderer() &
                " (" & formatFloat(worst, ffScientific, 1) & ", " & formatFloat(ms, ffDecimal, 1) & " ms)"
      gpuDone.store(true)

var step = 0
var said = ""
when compileOption("threads"):
  var th: Thread[int]

app "bigcheck", 400, 200:
  label(if said.len > 0: said else: "checking...")
  case step
  of 0:
    bigFile()
    when compileOption("threads"):
      check computeReady() == false, "the page's own thread is never given the GPU"
      createThread(th, gpuWork, 0)
    step = 1
    wakeIn(30)
  of 1:
    when compileOption("threads"):
      if gpuDone.load:
        joinThread(th)
        if gpuSays == "NONE": echo "WEBGPU NONE"
        else:
          check gpuSays.startsWith("OK"), "WebGPU for a thread: the CPU's within rounding -- " & gpuSays
          echo "WEBGPU ", gpuSays
        said = "done"
        echo "BIG DONE"
        step = 2
      else: wakeIn(30)
    else:
      echo "BIG DONE"
      step = 2
  else: discard

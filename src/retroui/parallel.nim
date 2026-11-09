## Work split across the processor's cores: `parallelFor(n, body)` calls
## `body(lo, hi)` on pieces of `0 ..< n` at once on a pool of worker
## threads (and on the calling thread), and returns when every piece is
## done. Image filters, compositing and resampling use it row by row
## (`parallelRows`).
##
## .. code-block:: nim
##   parallelRows(img.h, y):
##     for x in 0 ..< img.w: dst[y * img.w + x] = f(src[y * img.w + x])
##
## The body must only read what is shared and write its own part (its
## rows); it should not raise. A `parallelFor` inside a body runs on the
## spot (no nesting). With one core, or little work, everything runs on
## the calling thread.

import std/[locks, cpuinfo, atomics, os, strutils]
import busy, codec
when compileOption("threads"):
  import std/typedthreads

type Body = proc (lo, hi: int) {.closure.}

when compileOption("threads"):
  var workers: seq[Thread[void]]

var
  lock: Lock
  wake, doneCond: Cond
  gen: int                      # a new job each time (guarded by `lock`)
  active: int                   # workers inside a job (guarded by `lock`)
  jobFn: ptr Body
  jobN, jobChunk: int
  jobKeepAlive: bool            # the drawing thread reads events between its pieces
  nextChunk: Atomic[int]
  pending: Atomic[int]
  failed: Atomic[bool]
  started: bool
  maxThreads = 0                # 0: one per core
  inJob {.threadvar.}: bool     # this thread is running a piece (no nesting)
  waiting {.threadvar.}: bool   # ... or waiting for its job (a tick draws: no new job)

proc runChunks() =
  ## Takes pieces of the current job until there are none left.
  inJob = true
  while true:
    let c = nextChunk.fetchAdd(1)
    let lo = c * jobChunk
    if lo >= jobN: break
    let hi = min(jobN, lo + jobChunk)
    try:
      {.cast(gcsafe).}:
        jobFn[](lo, hi)
    except CatchableError:
      failed.store(true)
    if pending.fetchSub(1) == 1:
      withLock lock: broadcast(doneCond)
    if jobKeepAlive and onUiThread() and not waiting:
      waiting = true
      busyTick()                     # (the window kept alive between pieces)
      waiting = false
  inJob = false

proc work() {.thread.} =
  var seen = 0
  while true:
    acquire(lock)
    while gen == seen: wait(wake, lock)
    seen = gen
    inc active
    release(lock)
    {.cast(gcsafe).}:
      runChunks()
    acquire(lock)
    dec active
    broadcast(doneCond)
    release(lock)

proc threadCount*(): int =
  ## How many threads share the work (the worker threads and the caller):
  ## one per core, or `setThreadCount`, or $RETRO_THREADS (one in a
  ## browser).
  when not compileOption("threads"):
    1
  else:
    var n = maxThreads
    if n <= 0:
      n = try: parseInt(getEnv("RETRO_THREADS", "0")) except ValueError: 0
    if n <= 0: n = countProcessors()
    clamp(n, 1, 16)

proc setThreadCount*(n: int) =
  ## At most `n` threads (0: one per core). Takes effect before the first
  ## `parallelFor` (the pool is made once).
  maxThreads = max(0, n)

proc start() =
  if started: return
  started = true
  initLock(lock)
  initCond(wake)
  initCond(doneCond)
  when compileOption("threads"):
    let n = threadCount() - 1
    workers.setLen(n)
    for i in 0 ..< n: createThread(workers[i], work)

proc runAlone*() =
  ## This thread (one of its own: saving in the background) does its
  ## parallel work by itself -- the cores' pool belongs to the drawing
  ## thread.
  inJob = true

proc parallelFor*(n: int; body: proc (lo, hi: int) {.closure.}; grain = 1; keepAlive = true) =
  ## Calls `body(lo, hi)` for pieces of `0 ..< n` (each at least `grain`
  ## long) on all the cores, and waits for them. Raises `ValueError` when a
  ## piece raised. `keepAlive` false: no events read and no busy box while
  ## it waits (work that is part of drawing a frame).
  if n <= 0: return
  template alone() =
    try: body(0, n)
    except CatchableError as e: raise newException(ValueError, "a parallel piece failed: " & e.msg)
  if inJob or waiting or threadCount() <= 1 or n < 2 * max(1, grain):
    alone()
    if keepAlive and onUiThread() and not inJob and not waiting:
      busyTick()
      busyCheck()
    return
  start()
  when compileOption("threads"):
    if workers.len == 0:
      alone()
      return
    var fn: Body = body
    # (more, smaller pieces for big jobs: the cores stay even, and the
    # window is kept alive between them)
    let pieces = threadCount() * (if n >= 4096 * max(1, grain): 16 else: 4)
    let chunk = max(max(1, grain), (n + pieces - 1) div pieces)
    acquire(lock)
    while active > 0: wait(doneCond, lock)       # (the last job's late workers)
    jobFn = addr fn
    jobKeepAlive = keepAlive
    jobN = n
    jobChunk = chunk
    nextChunk.store(0)
    pending.store((n + chunk - 1) div chunk)
    failed.store(false)
    inc gen
    broadcast(wake)
    release(lock)
    runChunks()
    if onUiThread() and keepAlive:
      # the drawing thread waits in short naps, keeping the window alive
      waiting = true
      var spins = 0
      while pending.load > 0:
        if spins < 20000:
          inc spins                     # (a short wait: spun)
        else:
          busyTick()
          sleep(1)
      waiting = false
    acquire(lock)
    while pending.load > 0 or active > 0: wait(doneCond, lock)
    release(lock)
    if failed.load: raise newException(ValueError, "a parallel piece failed")
    if keepAlive: busyCheck()
  else:
    alone()

template parallelRows*(n: int; y: untyped; body: untyped) =
  ## `body` for each `y` in `0 ..< n`, the rows shared out among the cores.
  parallelFor(n, proc (lo, hi: int) {.closure.} =
    for y in lo ..< hi:
      body)

template drawingRows*(n: int; y: untyped; body: untyped) =
  ## `parallelRows` for work that is part of drawing a frame: no events
  ## read while it waits.
  parallelFor(n, proc (lo, hi: int) {.closure.} =
    for y in lo ..< hi:
      body, keepAlive = false)

template parallelChunks*(n: int; lo, hi: untyped; body: untyped) =
  ## `body` with `lo ..< hi` a piece of `0 ..< n` (for work that keeps a
  ## running state along its piece: running sums, histograms).
  parallelFor(n, proc (lo, hi: int) {.closure.} =
    body)

codec.compressPieces = proc (n: int; body: proc (lo, hi: int) {.closure.}) {.nimcall.} =
  parallelFor(n, body)

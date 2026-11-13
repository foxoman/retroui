## Any slow work off the UI thread: `job` runs a proc on a worker thread and
## its result comes back in a later frame, while the window keeps drawing.
## Ask, keep drawing, and take the value when it is there:
##
## .. code-block:: nim
##   import retroui, retroui/jobs
##
##   var prices: Job[HttpResponse]
##   app "Prices", 400, 200:
##     if button("&Load"): prices = fetch("https://example.com/prices.json")
##     if prices.running: label "Loading..."
##     elif prices.done: label prices.value.body
##     elif prices.failed: label "No prices: " & prices.error
##
##   # any proc: what it returns is the job's value
##   let sums = job(proc (j: JobCtl): int =
##     for i in 1 .. 100:
##       if j.cancelled: return 0       # (`cancel` was asked)
##       j.progress(i / 100)            # (`progress` on the UI's side)
##       result += slowSum(i))
##
## The work gets its own copies of what it captures: it must not touch the
## app's variables, which the UI thread changes meanwhile (what it needs,
## pass it in; what it makes, return it). A raised exception fails the job
## (`failed`, `error`). While jobs run, the frames keep coming (one every
## 15 ms), so their results show without input; `onDone` runs on the UI
## thread at the start of the frame after the job ended, and may touch any
## state of the app.
##
## Without threads (a web page built without them) a job runs on the UI
## thread at the start of the next frame: the frame that asked is drawn
## first. `fetch` is `httpRequest` as a job (`retroui/http` comes with this
## module).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[locks, atomics]
import core, http
export http
when compileOption("threads"):
  import std/typedthreads

type
  JobState* = enum
    ## Where a job is.
    jsWaiting     ## asked, not started yet
    jsRunning     ## a worker is doing it
    jsDone        ## it ended with its value
    jsFailed      ## it raised: `error` says what
    jsCancelled   ## `cancel` was asked and it stopped (or never started)

  JobHead = object
    state: Atomic[int]          # a JobState
    progress: Atomic[int]       # 0 .. 1_000_000
    cancel: Atomic[bool]
    error: string               # (written by the worker before the state says it ended)

  JobCtl* = object
    ## What the work gets: to tell its progress, and to see whether it was
    ## cancelled.
    head: ptr JobHead

  JobObj[T] = object
    head: JobHead
    value: T
    onDone: proc () {.closure.}
    seen: bool                  # (the UI thread saw it end: `onDone` ran)

  Job*[T] = ref JobObj[T]
    ## A piece of work running elsewhere (`job`); nil until one is asked.

  Runner = proc () {.closure, gcsafe.}

var
  lock: Lock
  cond: Cond
  queue: seq[Runner]            # guarded by lock
  ran: seq[Runner]              # guarded by lock: let go on the UI thread
                                # (their closures were made there: ORC frees
                                # them where it counted them)
  started = false
  # UI thread only: the jobs not seen to end yet
  pending: seq[proc (): bool {.closure.}]
  hooked = false

when compileOption("threads"):
  var workers: seq[Thread[void]]

  proc work() {.thread.} =
    while true:
      var r: Runner
      {.cast(gcsafe).}:
        acquire(lock)
        while queue.len == 0: wait(cond, lock)
        r = move queue[0]
        queue.delete(0)
        release(lock)
      r()
      {.cast(gcsafe).}:
        acquire(lock)
        ran.add move(r)
        release(lock)

proc progress*(c: JobCtl; f: float) =
  ## The work tells how far it is, 0.0 to 1.0 (`progress` on the UI's side).
  c.head.progress.store(int(clamp(f, 0.0, 1.0) * 1_000_000))

proc cancelled*(c: JobCtl): bool =
  ## `cancel` was asked: the work should stop soon (what it returns then is
  ## not taken).
  c.head.cancel.load

proc state*[T](j: Job[T]): JobState =
  ## Where the job is (`jsWaiting` for nil: none asked).
  if j == nil: jsWaiting else: JobState(j.head.state.load)

proc running*[T](j: Job[T]): bool =
  ## Asked and not ended yet.
  j != nil and j.state in {jsWaiting, jsRunning}

proc done*[T](j: Job[T]): bool =
  ## It ended with its value (`value`).
  j != nil and j.state == jsDone

proc failed*[T](j: Job[T]): bool =
  ## It raised (`error` says what).
  j != nil and j.state == jsFailed

proc ended*[T](j: Job[T]): bool =
  ## It is over: done, failed or cancelled.
  j != nil and j.state in {jsDone, jsFailed, jsCancelled}

proc error*[T](j: Job[T]): string =
  ## Why it failed ("" when it did not).
  if j != nil and j.state == jsFailed: j.head.error else: ""

proc value*[T](j: Job[T]): lent T =
  ## What the work returned (the type's empty value until it is done).
  j.value

proc progress*[T](j: Job[T]): float =
  ## How far it is, 0.0 to 1.0, as the work told it (1.0 once it is done).
  if j == nil: 0.0
  elif j.state == jsDone: 1.0
  else: j.head.progress.load / 1_000_000

proc cancel*[T](j: Job[T]) =
  ## Asks the work to stop (it sees `cancelled`); one not started yet never
  ## starts.
  if j != nil: j.head.cancel.store(true)

proc checkJobs() {.nimcall.} =
  ## (each frame: the jobs that ended let go, their `onDone` run; more
  ## frames while some run)
  when not compileOption("threads"):
    # (no threads: the work asked runs now, on the UI thread)
    var todo: seq[Runner]
    swap(todo, queue)
    for r in todo: r()
  else:
    if started:
      var gone: seq[Runner]
      withLock lock: swap(gone, ran)     # (they go here, at the end of this proc)
  var i = 0
  while i < pending.len:
    if pending[i]():
      pending.delete(i)
    else: inc i
  if pending.len > 0: wakeIn(15)

proc submit(r: sink Runner) =
  if not started:
    started = true
    initLock(lock)
    initCond(cond)
    when compileOption("threads"):
      workers.setLen(4)
      for i in 0 ..< workers.len: createThread(workers[i], work)
  if not hooked:
    hooked = true
    beginFrameHooks.add checkJobs
  withLock lock:
    queue.add r
  signal(cond)
  wakeIn(15)

proc job*[T](work: proc (c: JobCtl): T {.closure, gcsafe.};
             onDone: proc () {.closure.} = nil): Job[T] =
  ## Runs `work` on a worker thread (four of them, for the app's jobs);
  ## its result is the job's `value` once it is `done`. `onDone`, when
  ## given, runs on the UI thread in the frame after it ended (done, failed
  ## or cancelled).
  result = Job[T](onDone: onDone)
  # (the worker reaches it by its address alone: `pending` keeps it until
  # the UI thread sees it end)
  let p = cast[ptr JobObj[T]](result)
  let head = addr p.head
  submit(proc () {.closure, gcsafe.} =
    if head.cancel.load:
      head.state.store(ord(jsCancelled))
      return
    head.state.store(ord(jsRunning))
    var ended = jsDone
    var why = ""
    try:
      {.cast(gcsafe).}:
        var v = work(JobCtl(head: head))
        if head.cancel.load: ended = jsCancelled
        else: p.value = move(v)
    except CatchableError, Defect:
      why = getCurrentExceptionMsg()
      ended = jsFailed
    # (told only once the exception is let go here: the UI thread may end
    # the program as soon as it sees the job end)
    head.error = why
    head.state.store(ord(ended)))
  let j = result
  pending.add (proc (): bool =
    result = j.state in {jsDone, jsFailed, jsCancelled}
    if result and not j.seen:
      j.seen = true
      if j.onDone != nil: j.onDone())
  ui.redraw = true

proc job*[T](work: proc (): T {.closure, gcsafe.};
             onDone: proc () {.closure.} = nil): Job[T] =
  ## `job` for work that tells no progress and is not cancelled.
  job(proc (c: JobCtl): T {.closure, gcsafe.} = work(), onDone)

proc jobsRunning*(): int =
  ## How many jobs are asked and not seen to end (all of the app's).
  pending.len

proc fetch*(url: string; meth = "GET"; headers: openArray[(string, string)] = [];
            body = ""; timeoutSec = 60; onDone: proc () {.closure.} = nil): Job[HttpResponse] =
  ## `httpRequest` as a job: the request goes on a worker thread, the answer
  ## is the job's `value` (its `status` 0 and `error` when none came).
  let hs = @headers
  job(proc (): HttpResponse {.gcsafe.} = httpRequest(meth, url, hs, body, timeoutSec), onDone)

## Tests of retroui/jobs: work on a worker thread, its value, progress,
## cancel and failure handed back to the UI thread between frames.

import std/os
import harness, retroui, retroui/jobs

fakeDriver()
startApp("t", W, H)
view = proc () = discard

proc waitAll(ended: proc (): bool) =
  ## (frames until the jobs ended, 5 s at most)
  for _ in 0 ..< 500:
    if ended(): break
    run()
    sleep(10)
  run()

block values:
  var doneSeen = false
  let a = job(proc (c: JobCtl): int =
    for i in 1 .. 5:
      c.progress(i / 5)
      sleep(10)
    42)
  let b = job(proc (): seq[string] = @["x", "y"], onDone = proc () = doneSeen = true)
  let e = job(proc (): string = raise newException(IOError, "boom"))
  waitAll(proc (): bool = a.ended and b.ended and e.ended)
  doAssert a.done and a.value == 42 and a.progress == 1.0, $a.state
  doAssert b.done and b.value == @["x", "y"] and doneSeen
  doAssert e.failed and e.error == "boom" and e.state == jsFailed
  doAssert jobsRunning() == 0

block cancel:
  let slow = job(proc (c: JobCtl): int =
    for i in 0 ..< 500:
      if c.cancelled: return -1
      sleep(5)
    7)
  for _ in 0 ..< 20:
    run()
    sleep(5)
  doAssert slow.running or slow.state == jsWaiting
  slow.cancel()
  waitAll(proc (): bool = slow.ended)
  doAssert slow.state == jsCancelled, $slow.state

proc square(k: int): Job[int] =
  ## (a job of its own `k`: a closure made in a loop would share the loop's)
  job(proc (): int = k * k)

block many:
  # (more jobs than workers: each runs, in turn)
  var js: seq[Job[int]]
  for i in 0 ..< 12: js.add square(i)
  waitAll(proc (): bool =
    for j in js:
      if not j.ended: return false
    true)
  for i, j in js: doAssert j.value == i * i

echo "jobs OK"

## Threads in a browser (`retroweb --threads`): the page's checks for
## tests/web/threads.js. Threads in Web Workers on one memory: locks,
## conditions, channels, atomics, each thread its own thread-local
## variables, files and the console from a thread (the page does them),
## memory grown by a thread, a thread that sleeps, `parallelFor` on every
## core. Built without threads (the page's fallback) it says so.

import std/[os, strutils, times]
import retroui/parallel

when compileOption("threads"):
  import std/[locks, atomics, typedthreads]

  var
    lock: Lock
    wake: Cond
    total: int                   # guarded by lock
    counter: Atomic[int]
    chan: Channel[string]
    mine {.threadvar.}: int
    big: array[4, seq[byte]]

  proc adder(n: int) {.thread.} =
    mine = n + 100
    for i in 1 .. 20000:
      acquire(lock)
      inc total
      release(lock)
      counter.atomicInc()
    {.cast(gcsafe).}:
      # (a file from a thread: the page writes it)
      writeFile("/tmp/thread-" & $n & ".txt", "written by thread " & $n)
      # (memory grown by a thread: 24 MB each)
      big[n] = newSeq[byte](24 shl 20)
      big[n][^1] = byte(n + 1)
    echo "a thread says hello: ", n
    doAssert mine == n + 100
    chan.send("done " & $n)

  proc sleeper(ms: int) {.thread.} =
    let t0 = epochTime()
    sleep(ms)
    chan.send("slept " & $int((epochTime() - t0) * 1000))

  proc waiter(x: int) {.thread.} =
    acquire(lock)
    while total < 1_000_000: wait(wake, lock)
    release(lock)
    chan.send("woken " & $x)

template allIt2(s: seq[string]; prefix: string): bool =
  var r = true
  for it in s:
    if not it.startsWith(prefix): r = false
  r

proc check(ok: bool; what: string) =
  echo (if ok: "PASS " else: "FAIL "), what

proc main() =
  when compileOption("threads"):
    initLock(lock)
    initCond(wake)
    chan.open()
    mine = 7
    var ts: array[4, Thread[int]]
    for i in 0 .. 3: createThread(ts[i], adder, i)
    var got: seq[string]
    for i in 0 .. 3: got.add chan.recv()        # (the page's thread waits: it spins)
    joinThreads(ts)
    check total == 80000, "a lock: 4 threads x 20000 (" & $total & ")"
    check counter.load == 80000, "atomics: " & $counter.load
    check got.len == 4 and got.allIt2("done"), "a channel: " & got.join(", ")
    check mine == 7, "thread-local variables: each thread its own"
    var files = 0
    for i in 0 .. 3:
      if readFile("/tmp/thread-" & $i & ".txt") == "written by thread " & $i: inc files
    check files == 4, "files written by threads: " & $files
    var grown = 0
    for i in 0 .. 3:
      if big[i].len == 24 shl 20 and big[i][^1] == byte(i + 1): inc grown
    check grown == 4, "memory grown by threads: " & $grown & " x 24 MB"
    var s: Thread[int]
    createThread(s, sleeper, 120)
    joinThread(s)
    let slept = parseInt(chan.recv().split(' ')[1])
    check slept >= 100, "a thread sleeps: " & $slept & " ms"
    var w: Thread[int]
    createThread(w, waiter, 1)
    sleep(30)                                    # (no sleep on the page's thread: back at once)
    acquire(lock)
    total = 1_000_000
    broadcast(wake)
    release(lock)
    joinThread(w)
    check chan.recv() == "woken 1", "a condition: a waiting thread woken"
    var sums: array[64, int]
    parallelFor(64, proc (lo, hi: int) =
      for i in lo ..< hi:
        var x = 0
        for k in 0 ..< 200_000: x += (k * i) mod 7
        sums[i] = x)
    var ok = true
    for i in 0 ..< 64:
      var x = 0
      for k in 0 ..< 200_000: x += (k * i) mod 7
      if sums[i] != x: ok = false
    check ok, "parallelFor on " & $threadCount() & " threads"
    echo "THREADS DONE ", threadCount()
  else:
    echo "THREADS NONE"

main()

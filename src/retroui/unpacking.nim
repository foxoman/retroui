## Unpacking what a program carries packed (zlib or LZMA: the fonts, the
## pixel icons) on a thread of its own, while the program starts: the window
## opens and the first frame is laid out meanwhile, and what it needs is
## there or nearly there when it asks for it.
##
## .. code-block:: nim
##   const packed = staticRead("Hand.ttf.z")
##   let ticket = unpackSoon(packed)      # (at once: the unpacking starts)
##   ...
##   let bytes = unpacked(ticket)         # (waits if it is not done yet)
##
## One thread does them in the order asked, and ends when there is nothing
## left; it is started again for the next. Without threads (a web page) a
## ticket is unpacked when it is asked for.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/locks
import codec, lzma

const Threads = compileOption("threads") and not defined(js) and not defined(emscripten)
when Threads:
  import std/typedthreads

type
  Job = object
    packed, output: string
    state: int                 # 0 waiting, 1 being unpacked, 2 done, 3 handed out

type Shared = object
  jobs: seq[Job]
# (never freed: a worker may still be at work as the program ends, after Nim
# has destroyed the program's globals -- these are not among them)
let sh = cast[ptr Shared](allocShared0(sizeof(Shared)))
template jobs: untyped = sh.jobs

var
  lk: Lock
  cv: Cond
  running, started: bool
initLock(lk)
initCond(cv)

when Threads:
  var worker: Thread[void]

proc unpackBytes*(p: string): string =
  ## The bytes of `p`, packed with zlib or with LZMA behind the kit's
  ## header (`retroui/lzma`: the fonts not needed at the start); "" when it
  ## is damaged.
  if isLzma(p): return unlzma(p)
  try:
    let b = zlibDecompress(p.toOpenArrayByte(0, p.high))
    result = newString(b.len)
    if b.len > 0: copyMem(addr result[0], unsafeAddr b[0], b.len)
  except CatchableError: result = ""

proc unzip(p: string): string = unpackBytes(p)

when Threads:
  proc work() {.thread.} =
    {.cast(gcsafe).}:
      while true:
        var i = -1
        var p: string
        withLock lk:
          for k in 0 ..< jobs.len:
            if jobs[k].state == 0:
              i = k
              break
          if i < 0:
            running = false
            return
          jobs[i].state = 1
          p = move jobs[i].packed
        let o = unzip(p)
        withLock lk:
          jobs[i].output = o
          jobs[i].state = 2
          broadcast(cv)

proc unpackSoon*(packed: string): int =
  ## Starts unpacking `packed` (zlib, or LZMA behind the kit's header:
  ## `retroui/lzma`) now, on a thread; the ticket
  ## to ask `unpacked` for its bytes with.
  var start = false
  withLock lk:
    jobs.add Job(packed: packed)
    result = jobs.high
    when Threads:
      if not running:
        running = true
        start = true
  when Threads:
    if start:
      if started: joinThread(worker)      # (the one before: ended, or ending now)
      createThread(worker, work)
      started = true

proc unpacked*(ticket: int): string =
  ## The bytes of `unpackSoon`'s `ticket` (waited for when they are being
  ## unpacked; unpacked here when they were not started yet), once: they
  ## are the caller's then. "" for a damaged stream, or asked again.
  var p, done: string
  var mine = false
  withLock lk:
    if ticket >= 0 and ticket < jobs.len:
      while jobs[ticket].state == 1: wait(cv, lk)
      case jobs[ticket].state
      of 2:
        done = move jobs[ticket].output
        jobs[ticket].state = 3
      of 0:
        p = move jobs[ticket].packed
        jobs[ticket].state = 3
        mine = true
      else: discard
  result = if mine: unzip(p) else: move done

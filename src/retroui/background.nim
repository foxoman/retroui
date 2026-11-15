## Work off the UI thread. Worker threads list folders and decode
## pictures, so a big folder or a 50-megapixel photo never holds up a tap:
## ask, keep drawing, and take the results when they are there.
##
## .. code-block:: nim
##   # with a callback: run on the UI thread when the picture is decoded
##   discard pictureAsync("IMG_0001.jpg", 1600, 1600,
##     onDone = proc (r: var TaskResult) = photo = r.toBitmap)
##
##   # or by ticket, every frame:
##   let t = folderAsync("/sdcard/DCIM")
##   for r in finished():
##     if r.ticket == t: items = r.items
##
## While work is pending, the toolkit keeps the frames coming (a frame
## every 15 ms), so results show up without input. Callbacks run at the
## start of a frame (`beginFrame`), on the UI thread: they may touch any
## state of the app.
##
## Requests can be put in a `group` (any number) and cancelled together:
## `cancelTasks(tkPicture, group)` drops the thumbnails of a folder that
## is no longer shown. A cancelled request's callback still runs, with
## `cancelled` set, so whoever asked knows it will not come.
##
## **The window never asks a disk anything itself.** A disk can take as
## long as it likes to answer -- a network drive that is not there, a
## cloud folder, a card being read -- and the window would not answer
## until it did. What the drawing needs to know of the file system is
## asked with `later`: it answers at once with what was last known, and
## asks on a thread when that is too old.
##
## .. code-block:: nim
##   let space = later(akDiskSpace, dir, freshMs = 3000)    # free, total
##   if space.known: label sizeText(parseBiggestInt(space.value[0])) & " free"
##
## Folders are listed and questions answered on threads of their own (two;
## one more each third of a second that all of them are held up by a disk
## that does not answer -- eight at most), not on the ones that
## decode pictures: a folder is shown while its thumbnails are still
## being made, and a question nobody answers holds up no picture.

import std/[locks, tables, os, times, strutils]
import gfx, files, imaging, core, thumbcache, docfs
from uirelays/input import getTicks
from uirelays/services import places
when compileOption("threads"):
  import std/[typedthreads, cpuinfo]
  import parallel

type
  TaskKind* = enum
    ## What a background request does.
    tkPicture       ## decode a picture, fitted into maxW x maxH
    tkFolder        ## list a folder (with sizes and dates)
    tkPage          ## draw a page of a document (`pageAsync`)
    tkAsk           ## answer a question about the file system (`later`, `askNow`)

  AskKind* = enum
    ## What `later` and `askNow` ask of the file system, and what the
    ## answer's strings are.
    akHasFolders    ## has the folder folders in it: "1", or none
    akFolders       ## the folders in it, sorted by name: a path each
    akDiskSpace     ## the disk that holds it: free bytes, total bytes (none: not known)
    akModTime       ## when it last changed: seconds, nanoseconds (none: it cannot be read)
    akExists        ## what it is: "d" a folder, "f" a file, none when it is not there
    akHead          ## the start of the file: one string, 4096 bytes at most (the path may be
                    ## followed by a NUL and the file's date: asked again when it changed)
    akPictureSize   ## a picture's size from its header: width, height (none: not known; the
                    ## path as for `akHead`)
    akLinkTarget    ## where a symbolic link leads, as the link says it (none: it is no link)
    akPlaces        ## the standard folders and drives (`places()`): a name, a tab, a path each
                    ## (the path asked about is not used)

  TaskResult* = object
    ## A finished request (`finished`, or the `TaskDone` callback): what
    ## was asked and what came of it.
    kind*: TaskKind         ## what was asked
    ticket*: int            ## what the request returned
    group*: int             ## the group it was asked in
    path*: string           ## the file or folder it was asked for
    w*, h*: int             ## tkPicture: its size (0: it could not be read)
    px*: seq[uint32]        ## ... its pixels, 0xAARRGGBB
    items*: seq[FileItem]   ## tkFolder: what is in it
    quick*: bool            ## ... names and kinds only (see `listFolder`)
    error*: string          ## why it failed ("" when it did not)
    cancelled*: bool        ## dropped by `cancelTasks` before it ran
    page*: int              ## tkPage: the page drawn
    modified*: Time         ## tkFolder: when the folder last changed, as it was listed
    answer*: seq[string]    ## tkAsk: the answer (see `AskKind`)

  TaskDone* = proc (r: var TaskResult) {.closure.}
    ## Called on the UI thread with a finished (or cancelled) request.

  Task = object
    kind: TaskKind
    ticket, group: int
    path: string
    maxW, maxH: int
    hidden: bool
    quick: bool
    priority: int
    page: int
    ask: AskKind

type
  Shared = object
    todo: seq[Task]                # guarded by lock: pictures and pages
    asks: seq[Task]                # guarded by lock: folders and questions
    done: seq[TaskResult]          # guarded by lock
    running: int                   # guarded by lock: tasks being worked on
    idle: int                      # guarded by lock: the threads waiting for a folder or a question
    tookAt: int                    # guarded by lock: when one of them last took one (ticks)

# (never freed: a worker may finish a task as the program ends, after Nim
# has destroyed the program's globals -- the queues are not among them)
let sh = cast[ptr Shared](allocShared0(sizeof(Shared)))
template todo: untyped = sh.todo
template asks: untyped = sh.asks
template done: untyped = sh.done
template running: untyped = sh.running

var
  lock: Lock
  cond: Cond
  askCond: Cond
  nextTicket = 1
  started = false
  # UI thread only:
  callbacks: Table[int, TaskDone]  # ticket -> who wants the result
  unclaimed: seq[TaskResult]       # results without a callback, for `finished`
  pendingCount = 0                 # asked and not yet handed over

proc takeNext(): Task =
  ## (lock held) the most urgent task, and of those the newest (what the
  ## user looks at now)
  var best = todo.high
  for i in countdown(todo.high, 0):
    if todo[i].priority > todo[best].priority: best = i
  result = move todo[best]
  todo.delete(best)
  inc running

proc takeAsk(): Task =
  ## (lock held) the most urgent folder or question, and of those the oldest
  var best = 0
  for i in 1 .. asks.high:
    if asks[i].priority > asks[best].priority: best = i
  result = move asks[best]
  asks.delete(best)
  inc running
  sh.tookAt = getTicks()

proc fileOf(path: string): string =
  ## (a file asked about as it is now: its path, then a NUL and its date --
  ## the same file changed is another question)
  let z = path.find('\0')
  if z >= 0: path[0 ..< z] else: path

proc answerOf(what: AskKind; path: string; hidden: bool): seq[string] =
  ## (on a thread: what the file system says)
  case what
  of akHasFolders:
    if hasSubFolders(path, hidden): result.add "1"
  of akFolders: result = subFolders(path, hidden)
  of akDiskSpace:
    let sp = diskSpace(path)
    if sp.total > 0: result = @[$sp.free, $sp.total]
  of akModTime:
    let t = vModTime(path)
    if t != Time(): result = @[$t.toUnix, $t.nanosecond]
  of akExists:
    if vIsDir(path) or dirExists(path): result.add "d"
    elif fileExists(path): result.add "f"
  of akHead:
    var fh = vOpen(fileOf(path), fmRead)         # (another app's documents too)
    var buf = newString(4096)
    buf.setLen(fh.readBuffer(addr buf[0], 4096))
    fh.close()
    result.add buf
  of akPictureSize:
    let s = pictureSize(fileOf(path))
    if s.w > 0 and s.h > 0: result = @[$s.w, $s.h]
  of akLinkTarget:
    let t = linkTarget(path)
    if t.len > 0: result.add t
  of akPlaces:
    for p in places(): result.add p.name & "\t" & p.path

proc runTask(t: Task) =
  ## Does `t` and puts its result with the others finished.
  var r = TaskResult(kind: t.kind, ticket: t.ticket, group: t.group, path: t.path,
                     quick: t.quick, page: t.page)
  block:
    {.cast(gcsafe).}:
      try:
        case t.kind
        of tkPicture:
          # (a thumbnail of a file slow to decode: from the disk cache when
          # it is there, kept there when it is made -- `retroui/thumbcache`)
          let side = max(t.maxW, t.maxH)
          let keep = side <= thumbMaxSide and thumbCacheOn() and worthKeeping(t.path)
          var b = if keep: cachedThumb(t.path, side) else: nil
          if b == nil:
            b = loadPicture(t.path, t.maxW, t.maxH)
            if keep and b != nil: keepThumb(t.path, side, b)
          if b == nil: r.error = "this picture cannot be read"
          else:
            r.w = b.w
            r.h = b.h
            r.px = move b.px
        of tkFolder:
          # (its date first: what changes while it is listed is seen as a change after)
          r.modified = vModTime(t.path)
          r.items = listFolder(t.path, t.hidden, t.quick)
        of tkAsk:
          r.answer = answerOf(t.ask, t.path, t.hidden)
        of tkPage:
          let rd = pageReaderFor(t.path)
          let b = if rd == nil: nil else: rd(t.path, t.page, t.maxW, t.maxH)
          if b == nil: r.error = "this page cannot be drawn"
          else:
            r.w = b.w
            r.h = b.h
            r.px = move b.px
      except CatchableError as e:
        r.error = e.msg
      except Defect as e:          # a bug, but not one that takes the app down
        r.error = e.msg
      acquire(lock)
      done.add move r
      dec running
      release(lock)

const MostAskers = 8
  ## (threads for folders and questions: two, and one more each third of a
  ## second that all of them are held up -- by a disk that does not answer
  ## -- up to this many)

when compileOption("threads"):
  var workers: seq[Thread[void]]
  var askers: array[MostAskers, Thread[void]]     # (in place: a thread's object does not move)
  var askerCount = 0                              # UI thread only

  proc work() {.thread.} =
    # (a worker decodes by itself: the cores' pool belongs to the drawing
    # thread -- several workers sharing it at once would break it)
    runAlone()
    while true:
      var t: Task
      {.cast(gcsafe).}:
        acquire(lock)
        while todo.len == 0: wait(cond, lock)
        t = takeNext()
        release(lock)
        runTask(t)

  proc askWork() {.thread.} =
    runAlone()
    while true:
      var t: Task
      {.cast(gcsafe).}:
        acquire(lock)
        while asks.len == 0:
          inc sh.idle
          wait(askCond, lock)
          dec sh.idle
        t = takeAsk()
        release(lock)
        runTask(t)

proc start() =
  if started: return
  started = true
  initLock(lock)
  initCond(cond)
  initCond(askCond)
  when compileOption("threads"):
    let n = clamp(countProcessors() - 1, 1, 3)
    workers.setLen(n)
    for i in 0 ..< n: createThread(workers[i], work)
    for i in 0 ..< 2:
      createThread(askers[i], askWork)
      inc askerCount

proc workHere() =
  ## Without threads (a browser): the tasks done between frames, the most
  ## urgent first, for a few milliseconds a frame.
  when not compileOption("threads"):
    let t0 = getTicks()
    while asks.len > 0 and getTicks() - t0 < 12:
      runTask(takeAsk())
    while todo.len > 0 and getTicks() - t0 < 12:
      runTask(takeNext())

proc submit(t: sink Task; onDone: TaskDone): int =
  start()
  result = nextTicket
  inc nextTicket
  var t = t
  t.ticket = result
  if onDone != nil: callbacks[result] = onDone
  inc pendingCount
  if t.kind in {tkFolder, tkAsk}:
    withLock lock:
      asks.add t
    signal(askCond)
  else:
    withLock lock:
      todo.add t
    signal(cond)
  wakeIn(15)

proc pictureAsync*(path: string; maxW, maxH: int; priority = 0; group = 0;
                   onDone: TaskDone = nil): int =
  ## Decodes the picture `path` (no larger than `maxW` x `maxH`) on a worker
  ## thread; returns the ticket its `TaskResult` will carry. Higher
  ## `priority` goes first; of the same priority the newest goes first.
  ## With `onDone` the result goes there, else to `finished`.
  submit(Task(kind: tkPicture, path: path, maxW: maxW, maxH: maxH,
              priority: priority, group: group), onDone)

proc pageAsync*(path: string; page, maxW, maxH: int; priority = 0; group = 0;
                onDone: TaskDone = nil): int =
  ## Draws page `page` of the document `path` (a PDF: see `addPageReader`)
  ## no larger than `maxW` x `maxH` on a worker thread, as `pictureAsync`.
  submit(Task(kind: tkPage, path: path, page: page, maxW: maxW, maxH: maxH,
              priority: priority, group: group), onDone)

proc folderAsync*(path: string; showHidden = false; priority = 10; group = 0;
                  onDone: TaskDone = nil; quick = false): int =
  ## Lists the folder `path` on a worker thread (see `listFolder`).
  submit(Task(kind: tkFolder, path: path, hidden: showHidden, priority: priority,
              group: group, quick: quick), onDone)

proc takeDone() =
  ## Moves what the workers finished to the UI thread's side, running the
  ## callbacks.
  if not started: return
  workHere()
  var got: seq[TaskResult]
  var more = false
  var heldUp = false
  withLock lock:
    got = move done
    done = @[]
    more = todo.len > 0 or asks.len > 0 or running > 0
    # (folders or questions waiting, no thread free, and none taken for a third of a
    # second: the threads there are wait on a disk that does not answer)
    heldUp = asks.len > 0 and sh.idle == 0 and getTicks() - sh.tookAt > 300
  when compileOption("threads"):
    if heldUp and askerCount < MostAskers:
      createThread(askers[askerCount], askWork)
      inc askerCount
      withLock lock: sh.tookAt = getTicks()         # (the next one a third of a second on)
  if more: wakeIn(15)
  if got.len == 0: return
  ui.redraw = true
  for r in got.mitems:
    dec pendingCount
    let cb = callbacks.getOrDefault(r.ticket, nil)
    if cb != nil:
      callbacks.del r.ticket
      cb(r)
    else:
      unclaimed.add move r

proc cancelTasks*(kind: TaskKind; group = -1) =
  ## Drops the requests of `kind` (of `group`; -1: of any group) that have
  ## not started yet. Their callbacks run with `cancelled` set; requests
  ## without one are just forgotten.
  if not started: return
  var gone: seq[Task]
  withLock lock:
    var i = 0
    while i < todo.len:
      if todo[i].kind == kind and (group < 0 or todo[i].group == group):
        gone.add move todo[i]
        todo.delete(i)
      else: inc i
    i = 0
    while i < asks.len:
      if asks[i].kind == kind and (group < 0 or asks[i].group == group):
        gone.add move asks[i]
        asks.delete(i)
      else: inc i
  for t in gone:
    dec pendingCount
    let cb = callbacks.getOrDefault(t.ticket, nil)
    if cb != nil:
      callbacks.del t.ticket
      var r = TaskResult(kind: t.kind, ticket: t.ticket, group: t.group, path: t.path,
                         cancelled: true, error: "cancelled", page: t.page)
      cb(r)

proc busy*(): bool =
  ## Requests are waiting, being worked on, or not taken yet.
  if not started: return false
  pendingCount > 0 or unclaimed.len > 0

proc finished*(): seq[TaskResult] =
  ## The results without a callback that came in since the last call.
  takeDone()
  result = move unclaimed
  unclaimed = @[]

# ---- questions about the file system ----------------------------------------------------------

type Later = object
  known, pending: bool
  value: seq[string]
  at: int                          # (when it was answered: `ui.now`)
  gen: int                         # (forgotten since it was asked: the answer is not kept)

var
  laters: Table[string, Later]     # UI thread only
  laterGen = 0
  waitedFrame = -1                 # (the frame some of its time was spent waiting) ...
  waitedMs = 0                     # ... and how much of it

proc laterKey(what: AskKind; path: string; flag: bool): string =
  $ord(what) & (if flag: "+" else: "-") & path

proc waitFor(key: string; ms: int) =
  ## (the window waits a moment for an answer on its way: a disk that is
  ## there answers in less; no more than 80 ms of a frame is spent so)
  if ms <= 0: return
  if waitedFrame != ui.frameNo:
    waitedFrame = ui.frameNo
    waitedMs = 0
  let most = min(ms, 80 - waitedMs)
  if most <= 0: return
  let t0 = getTicks()
  while getTicks() - t0 < most:
    takeDone()
    if not laters.getOrDefault(key).pending: break
    sleep(1)
  waitedMs += getTicks() - t0

proc later*(what: AskKind; path: string; flag = false; freshMs = -1;
            waitMs = 0): tuple[known: bool; value: seq[string]] =
  ## What the file system says of `path` (`what`: see `AskKind`; `flag`:
  ## hidden folders count too), without the window ever waiting for a
  ## disk: the answer last had (`known` false until there is one), asked
  ## on a thread the first time, and again when it is older than `freshMs`
  ## (-1: once is enough). A frame is drawn when an answer comes. `waitMs`:
  ## the first time, wait this long for it (a disk that is there answers
  ## in a millisecond or two, and what is drawn is whole at once); what
  ## does not answer in time is drawn when it does.
  let key = laterKey(what, path, flag)
  var e = laters.getOrDefault(key)
  let stale = e.known and freshMs >= 0 and (ui.now - e.at > freshMs or ui.now < e.at)
  if (not e.known or stale) and not e.pending:
    if not e.known and laters.len >= 1024:
      # (answers kept for what was looked at long ago: let go, so that they do not add up
      # for as long as the app runs)
      var old: seq[string]
      for k, v in laters:
        if not v.pending and (ui.now - v.at > 30_000 or ui.now < v.at or laters.len >= 4096): old.add k
      for k in old: laters.del k
    e.pending = true
    e.gen = laterGen
    laters[key] = e
    let asked = laterGen
    discard submit(Task(kind: tkAsk, ask: what, path: path, hidden: flag, priority: 20),
      proc (r: var TaskResult) =
        if not laters.hasKey(key): return        # (forgotten meanwhile)
        var x = laters[key]
        if x.gen != asked: return
        x.pending = false
        x.known = true
        x.value = move r.answer
        x.at = ui.now
        laters[key] = x
        ui.redraw = true)
    if not e.known: waitFor(key, waitMs)
    e = laters.getOrDefault(key)
  (e.known, e.value)

proc askNow*(what: AskKind; path: string; flag = false; waitMs = 1000): tuple[known: bool; value: seq[string]] =
  ## The file system asked now, for something the user asked for (a folder
  ## to go to): the answer when it comes within `waitMs`, else `known`
  ## false -- the window goes on without it. Nothing is kept.
  var got = false
  var value: seq[string]
  # (the answer lands in a box of its own: it may come after this has given up)
  type Box = ref object
    got: bool
    value: seq[string]
  let box = Box()
  discard submit(Task(kind: tkAsk, ask: what, path: path, hidden: flag, priority: 30),
    proc (r: var TaskResult) =
      box.got = not r.cancelled
      box.value = move r.answer)
  let t0 = getTicks()
  while getTicks() - t0 < waitMs:
    takeDone()
    if box.got: break
    sleep(1)
  got = box.got
  if got: value = move box.value
  (got, value)

proc tellLater*(what: AskKind; path: string; value: seq[string]; flag = false) =
  ## An answer that is known already (a folder just listed: its date), put
  ## where `later` finds it.
  laters[laterKey(what, path, flag)] = Later(known: true, value: value, at: ui.now, gen: laterGen)

proc forgetLater*(what: AskKind; under = "") =
  ## The answers to `what` let go (for the paths that start with `under`):
  ## asked again when they are next wanted.
  inc laterGen
  let head = $ord(what)
  var gone: seq[string]
  for k in laters.keys:
    if k.startsWith(head) and k.len > head.len and k[head.len] in {'+', '-'} and
       k[head.len + 1 .. ^1].startsWith(under):
      gone.add k
  for k in gone: laters.del k

proc toBitmap*(r: sink TaskResult): Bitmap =
  ## A finished picture as a `Bitmap` (nil when it failed).
  if r.w <= 0 or r.h <= 0 or r.px.len < r.w * r.h: return nil
  result = newBitmap(0, 0)
  result.w = r.w
  result.h = r.h
  result.px = move r.px
  result.changed()

beginFrameHooks.add takeDone

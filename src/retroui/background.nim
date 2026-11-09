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

import std/[locks, tables]
import gfx, files, imaging, core, thumbcache
when compileOption("threads"):
  import std/[typedthreads, cpuinfo]
  import parallel
else:
  from uirelays/input import getTicks

type
  TaskKind* = enum
    ## What a background request does.
    tkPicture       ## decode a picture, fitted into maxW x maxH
    tkFolder        ## list a folder (with sizes and dates)
    tkPage          ## draw a page of a document (`pageAsync`)

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

var
  lock: Lock
  cond: Cond
  todo: seq[Task]                  # guarded by lock
  done: seq[TaskResult]            # guarded by lock
  running: int                     # guarded by lock: tasks being worked on
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
          r.items = listFolder(t.path, t.hidden, t.quick)
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

when compileOption("threads"):
  var workers: seq[Thread[void]]

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

proc start() =
  if started: return
  started = true
  initLock(lock)
  initCond(cond)
  when compileOption("threads"):
    let n = clamp(countProcessors() - 1, 1, 3)
    workers.setLen(n)
    for i in 0 ..< n: createThread(workers[i], work)

proc workHere() =
  ## Without threads (a browser): the tasks done between frames, the most
  ## urgent first, for a few milliseconds a frame.
  when not compileOption("threads"):
    let t0 = getTicks()
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
  withLock lock:
    got = move done
    done = @[]
    more = todo.len > 0 or running > 0
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

proc toBitmap*(r: sink TaskResult): Bitmap =
  ## A finished picture as a `Bitmap` (nil when it failed).
  if r.w <= 0 or r.h <= 0 or r.px.len < r.w * r.h: return nil
  result = newBitmap(0, 0)
  result.w = r.w
  result.h = r.h
  result.px = move r.px
  result.changed()

beginFrameHooks.add takeDone

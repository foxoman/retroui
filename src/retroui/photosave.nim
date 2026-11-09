## Saving in the background: what the document holds is copied (quickly,
## on the drawing thread), then compressed and written on a thread of its
## own while the program goes on -- as Photoshop's "Save in Background".
##
## ```nim
## startSave(prepareSave(doc, "/sdcard/Pictures/big.psd", defaultExport(efPsd)))
## # ... each frame:
## let r = saveFinished()          # (done, error, path) once it is over
## ```

import std/[os, atomics]
import photo, photofiles, psd, busy
when compileOption("threads"):
  import std/typedthreads
  import parallel                         # (runAlone: the save's thread does not fan out)

type
  SaveKind = enum skRpd, skPsd, skFlat
  SaveJob* = object
    ## A save, ready to run on any thread (it holds no references to the
    ## document).
    path*: string            ## the file it writes
    kind: SaveKind
    parts: seq[RpdPart]
    psd: PsdDoc
    flat: FlatExport
    o: ExportOptions
    error*: string           ## why it failed ("" when it did not, or has not run)

proc prepareSave*(d: Doc; path: string; o: ExportOptions): SaveJob =
  ## What saving `d` to `path` takes, copied (`o.format`: efRpd, efPsd or a
  ## flat format).
  result.path = path
  result.o = o
  case o.format
  of efRpd:
    result.kind = skRpd
    result.parts = d.rpdParts
  of efPsd:
    result.kind = skPsd
    result.psd = psdOf(d)
  else:
    result.kind = skFlat
    result.flat = d.flatExport(o)

proc runSave*(job: var SaveJob) =
  ## Compresses and writes the file (to a file beside it, then moved into
  ## place); `job.error` says what went wrong.
  try:
    case job.kind
    of skRpd: writeRpd(move job.parts, job.path)
    of skPsd:
      let tmp = job.path & ".part"
      writeFile(tmp, writePsd(job.psd))
      moveFile(tmp, job.path)
    of skFlat:
      let data = encodeFlat(move(job.flat), job.o)
      let tmp = job.path & ".part"
      writeFile(tmp, data)
      moveFile(tmp, job.path)
  except CatchableError as e:
    job.error = if e.msg.len > 0: e.msg else: "could not be written"
  job.parts = @[]
  job.psd = PsdDoc()

var
  current: ptr SaveJob
  finished: Atomic[bool]

when compileOption("threads"):
  var worker: Thread[ptr SaveJob]

  proc work(j: ptr SaveJob) {.thread.} =
    runAlone()
    {.cast(gcsafe).}:
      runSave(j[])
    finished.store(true)

proc saving*(): bool = current != nil
  ## A save is going on in the background.

proc savingPath*(): string = (if current != nil: current.path else: "")
  ## The file being saved in the background ("" when none is).

proc startSave*(job: sink SaveJob) =
  ## Saves in the background (one at a time: a save still going on is
  ## waited for first).
  if current != nil:
    when compileOption("threads"): joinThread(worker)
    `=destroy`(current[])
    deallocShared(current)
    current = nil
  current = cast[ptr SaveJob](allocShared0(sizeof(SaveJob)))
  current[] = move(job)
  finished.store(false)
  when compileOption("threads"):
    createThread(worker, work, current)
  else:
    # (a web page without threads: saved now)
    runSave(current[])
    finished.store(true)

proc saveFinished*(): tuple[done: bool; error, path: string] =
  ## Whether the background save is over (once: then it is forgotten).
  if current == nil or not finished.load: return
  when compileOption("threads"): joinThread(worker)
  result = (true, current.error, current.path)
  `=destroy`(current[])
  deallocShared(current)
  current = nil

proc waitForSave*(): tuple[done: bool; error, path: string] =
  ## Waits for the background save (quitting: nothing is left half written).
  if current == nil: return
  while not finished.load:
    busyTick()
    sleep(5)
  saveFinished()

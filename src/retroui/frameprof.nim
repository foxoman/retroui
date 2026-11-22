## A frame profiler: where each frame's time goes, as spans of named work on each thread, with
## counters beside them (the GPU's draw calls, its vertices, the pictures sent to it) -- written
## as a Chrome trace (the Trace Event Format: open it in chrome://tracing, ui.perfetto.dev or
## Speedscope) and kept for the last frames to look at in the app.
##
## Off, it costs a test of one bool. On -- `RETRO_TRACE=file.json`, or `startTrace` -- every
## frame is a span ("frame"), and the kit's own parts in it (laying out, drawing, the GPU's
## flushes, putting the frame on the screen) are spans of their own:
##
## .. code-block:: nim
##   import retroui/frameprof
##   startTrace("trace.json")          # (or RETRO_TRACE=trace.json)
##   profiled("load the list"):
##     loadIt()
##   profCount("rows", rows.len)
##   ...
##   stopTrace()                       # (also when the app ends)
##
## `lastFrames` gives the last frames' spans and counters to show (the inspector shows them).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[monotimes, times, os, strutils, locks, exitprocs, algorithm]

type
  ProfSpan* = object
    ## Work done in a frame: what, when it started (microseconds from the frame's start), how long.
    name*: string
    at*, dur*: float
    depth*: int                ## how deep in other spans of its thread (0: the frame's own)
    thread*: int

  FrameProfile* = object
    ## A frame as the profiler saw it.
    number*: int
    ms*: float                 ## how long it took
    spans*: seq[ProfSpan]
    counters*: seq[tuple[name: string; value: float]]

const KeptFrames* = 120        ## the frames `lastFrames` keeps

var
  profOn* = false              ## the profiler is taking spans (`startTrace`)
  profLock: Lock
  traceFile: File
  traceOpen = false
  traceFirst = true
  t0 = getMonoTime()
  frameNo = 0
  frameStart: MonoTime
  current: FrameProfile
  kept: seq[FrameProfile]
  keptAt = 0
  stackDepth {.threadvar.}: int
  threadNo {.threadvar.}: int
  nextThread = 1

initLock(profLock)

proc us(t: MonoTime): float = float((t - t0).inNanoseconds) / 1000

proc thisThread(): int =
  if threadNo == 0:
    withLock profLock:
      threadNo = nextThread
      inc nextThread
  threadNo

proc emit(line: string) =
  ## (an event into the trace file -- the lock held)
  if not traceOpen: return
  try:
    if not traceFirst: traceFile.write ",\n"
    traceFirst = false
    traceFile.write line
  except IOError:
    traceOpen = false                # (the disk full: no more of it)

proc jsonStr(s: string): string =
  result = "\""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\0' .. '\9', '\11' .. '\31': result.add "\\u" & toHex(ord(c), 4)
    else: result.add c
  result.add "\""

proc startTrace*(path = "") =
  ## The profiler on: spans taken from now, kept for `lastFrames`, and -- `path` given -- written
  ## to that file as a Chrome trace (a JSON array of events; finished by `stopTrace`, or when the
  ## program ends).
  withLock profLock:
    if path.len > 0 and not traceOpen:
      if open(traceFile, path, fmWrite):
        traceOpen = true
        traceFirst = true
        try: traceFile.write "["
        except IOError: traceOpen = false
        emit("{\"name\":\"process_name\",\"ph\":\"M\",\"pid\":1,\"args\":{\"name\":" &
             jsonStr(getAppFilename().extractFilename) & "}}")
    profOn = true
    frameStart = getMonoTime()

proc stopTrace*() =
  ## The profiler off; the trace file finished and closed.
  withLock profLock:
    profOn = false
    if traceOpen:
      try: traceFile.write "\n]\n"
      except IOError: discard
      traceFile.close()
      traceOpen = false

proc profBegin*(name: string): MonoTime {.inline.} =
  ## The start of a span (pass what it gives to `profEnd`); nothing when the profiler is off.
  if profOn:
    inc stackDepth
    getMonoTime()
  else: MonoTime()

proc profEnd*(name: string; start: MonoTime) =
  ## The end of the span `profBegin` started.
  if start == MonoTime(): return
  dec stackDepth
  if not profOn: return
  let now = getMonoTime()
  let tid = thisThread()
  let a = us(start)
  let d = float((now - start).inNanoseconds) / 1000
  withLock profLock:
    current.spans.add ProfSpan(name: name, at: float((start - frameStart).inNanoseconds) / 1000, dur: d,
                               depth: max(0, stackDepth), thread: tid)
    emit("{\"name\":" & jsonStr(name) & ",\"ph\":\"X\",\"pid\":1,\"tid\":" & $tid & ",\"ts\":" &
         formatFloat(a, ffDecimal, 1) & ",\"dur\":" & formatFloat(d, ffDecimal, 1) & "}")

template profiled*(name: string; body: untyped) =
  ## `body` as a span named `name` (nothing more when the profiler is off).
  let profStart = profBegin(name)
  try: body
  finally: profEnd(name, profStart)

proc profCount*(name: string; value: float) =
  ## A counter's value in this frame (draw calls, rows laid out, bytes sent): shown under the
  ## spans in the trace, kept with the frame.
  if not profOn: return
  withLock profLock:
    var found = false
    for c in current.counters.mitems:
      if c.name == name:
        c.value += value
        found = true
    if not found: current.counters.add (name, value)

proc profCount*(name: string; value: int) = profCount(name, float(value))

proc profFrameBegin*() =
  ## (the kit: a frame starts)
  if not profOn: return
  withLock profLock:
    frameStart = getMonoTime()
    current = FrameProfile(number: frameNo)

proc profFrameEnd*() =
  ## (the kit: a frame ends -- its span and counters written, the frame kept)
  if not profOn: return
  let now = getMonoTime()
  let tid = thisThread()
  withLock profLock:
    current.ms = float((now - frameStart).inNanoseconds) / 1e6
    emit("{\"name\":\"frame\",\"ph\":\"X\",\"pid\":1,\"tid\":" & $tid & ",\"ts\":" &
         formatFloat(us(frameStart), ffDecimal, 1) & ",\"dur\":" & formatFloat(current.ms * 1000, ffDecimal, 1) &
         ",\"args\":{\"frame\":" & $frameNo & "}}")
    if current.counters.len > 0:
      var args = ""
      for c in current.counters:
        args.add (if args.len > 0: "," else: "") & jsonStr(c.name) & ":" & formatFloat(c.value, ffDecimal, 1)
      emit("{\"name\":\"counters\",\"ph\":\"C\",\"pid\":1,\"ts\":" & formatFloat(us(frameStart), ffDecimal, 1) &
           ",\"args\":{" & args & "}}")
    if kept.len < KeptFrames: kept.add current
    else:
      kept[keptAt] = current
      keptAt = (keptAt + 1) mod KeptFrames
    inc frameNo

proc lastFrames*(): seq[FrameProfile] =
  ## The last frames the profiler saw (at most `KeptFrames`), the oldest first.
  withLock profLock:
    if kept.len < KeptFrames: return kept
    for k in 0 ..< KeptFrames: result.add kept[(keptAt + k) mod KeptFrames]

type
  SpanSummary* = tuple[name: string; frames: int; avgMs, maxMs: float]
    ## A span's time over frames: in how many of them, its average and its longest (ms)
  CountSummary* = tuple[name: string; avg, most: float]
    ## A counter over frames: its average and its most

proc summary*(frames: openArray[FrameProfile]): tuple[spans: seq[SpanSummary]; counters: seq[CountSummary]] =
  ## The spans' and counters' averages over `frames` (as `lastFrames` gives them): the spans by
  ## their total time, the longest first; the counters by name. The frames' own time is the span
  ## "frame".
  if frames.len == 0: return
  var names: seq[string]
  var tot, most: seq[float]
  var seen: seq[int]
  proc at(n: string): int =
    result = names.find(n)
    if result < 0:
      names.add n
      tot.add 0
      most.add 0
      seen.add 0
      result = names.high
  for f in frames:
    var inThis: seq[int]
    var add = @[("frame", f.ms)]
    for sp in f.spans: add.add (sp.name, sp.dur / 1000)
    for (n, ms) in add:
      let k = at(n)
      tot[k] += ms
      if k notin inThis:
        inThis.add k
        inc seen[k]
    # (a span's longest: its time in one frame, all its pieces)
    for k in inThis:
      var inFrame = 0.0
      for (n, ms) in add:
        if n == names[k]: inFrame += ms
      most[k] = max(most[k], inFrame)
  for k in 0 ..< names.len:
    result.spans.add (names[k], seen[k], tot[k] / float(frames.len), most[k])
  result.spans.sort(proc (a, b: SpanSummary): int = cmp(b.avgMs, a.avgMs))
  var cn: seq[string]
  var csum, cmost: seq[float]
  for f in frames:
    for c in f.counters:
      var k = cn.find(c.name)
      if k < 0:
        cn.add c.name
        csum.add 0
        cmost.add 0
        k = cn.high
      csum[k] += c.value
      cmost[k] = max(cmost[k], c.value)
  for k in 0 ..< cn.len: result.counters.add (cn[k], csum[k] / float(frames.len), cmost[k])
  result.counters.sort(proc (a, b: CountSummary): int = cmp(a.name, b.name))

let envTrace = getEnv("RETRO_TRACE")
if envTrace.len > 0: startTrace(envTrace)
addExitProc(proc () {.noconv.} = stopTrace())

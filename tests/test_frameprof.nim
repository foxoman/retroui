## Tests of the frame profiler (retroui/frameprof): off, nothing kept; on, each frame's spans --
## the kit's own (the app's code, finishing it, putting it on the screen, the CPU's drawing, a
## Markdown text laid out, a picture's composite) and an app's -- and counters, kept for the last frames and summed up, written as a Chrome trace
## that is JSON a trace viewer reads.

import std/[os, json, strutils, monotimes]
import retroui, retroui/headless, retroui/frameprof, retroui/photo

useHeadless(320, 200)
startApp("Profiled", 320, 200)
var n = 0
proc frame() =
  inc n
  label "Frame " & $n                 # (each frame different: drawn and shown)
  profiled("the app's rows"):
    for i in 0 ..< 20: label "Row " & $i
  profCount("rows", 20)
proc frames(k: int) =
  for i in 0 ..< k:
    ui.redraw = true
    discard beginFrame()
    frame()
    endFrame()

# off: no spans, no frames kept, a span's start is nothing
doAssert not profOn
frames(3)
doAssert lastFrames().len == 0
doAssert profBegin("x") == MonoTime()

# on, with a file
let path = getTempDir() / "retro-frameprof-test.json"
removeFile(path)
startTrace(path)
doAssert profOn
frames(5)
let fs = lastFrames()
doAssert fs.len >= 4, $fs.len
var names: seq[string]
for f in fs:
  for sp in f.spans:
    if sp.name notin names: names.add sp.name
for want in ["app", "finish", "present", "the app's rows", "CPU: draw"]:
  doAssert want in names, want & " not among " & $names
let last = fs[^1]
doAssert last.ms > 0
for sp in last.spans:
  doAssert sp.dur >= 0 and sp.at >= 0, sp.name
  if sp.name == "the app's rows": doAssert sp.depth == 1, "inside the app's code"
  if sp.name == "app": doAssert sp.depth == 0
var rows = 0.0
for c in last.counters:
  if c.name == "rows": rows = c.value
doAssert rows == 20, "a counter's value in its frame: " & $rows
# the summary: every span over the frames, the frame itself the longest
let s = summary(fs)
doAssert s.spans.len >= 5 and s.spans[0].name == "frame", $s.spans
for sp in s.spans: doAssert sp.maxMs >= sp.avgMs - 1e-9 and sp.frames <= fs.len, sp.name
var found = false
for c in s.counters:
  if c.name == "rows":
    found = true
    doAssert c.avg == 20 and c.most == 20
doAssert found
stopTrace()
doAssert not profOn

# the file: a JSON array of trace events -- complete spans ("X") with their thread, start and
# length, each frame one, the counters ("C")
let j = parseJson(readFile(path))
doAssert j.kind == JArray and j.len > 10
var frameEvents, counterEvents, appEvents = 0
for e in j:
  let ph = e["ph"].getStr
  if ph == "X":
    doAssert e.hasKey("ts") and e.hasKey("dur") and e.hasKey("tid")
    if e["name"].getStr == "frame": inc frameEvents
    if e["name"].getStr == "app": inc appEvents
  elif ph == "C":
    inc counterEvents
    doAssert e["args"].hasKey("rows")
doAssert frameEvents >= 4 and appEvents >= 4 and counterEvents >= 4, $(frameEvents, appEvents, counterEvents)
# off again: frames go on, nothing more kept or written
let kept = lastFrames().len
frames(2)
doAssert lastFrames().len == kept
doAssert readFile(path).strip.endsWith("]")
# the kit's heavy parts, spans of their own: a Markdown text laid out (once, then kept), a
# picture's composite
startTrace()
let pic = newDoc(64, 64, 0xFFFFFFFF'u32)
ui.redraw = true
discard beginFrame()
discard markdown("# A title\n\nSome *words* to lay out.")
pic.updateComposite()
endFrame()
var kit: seq[string]
for sp in lastFrames()[^1].spans: kit.add sp.name
doAssert "markdown: lay out" in kit and "picture: composite" in kit, $kit
stopTrace()
# kept: at most the last 120
startTrace()
frames(KeptFrames + 10)
doAssert lastFrames().len == KeptFrames
doAssert lastFrames()[^1].number > lastFrames()[0].number
stopTrace()
removeFile(path)
echo "frameprof ok"

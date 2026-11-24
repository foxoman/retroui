## Tests that Retro Atelier lets go of a closed image: every command of the program (each name its
## sources run, 900 and more) run on an image with pixels, a shape, type and a selection, the
## image closed -- and no document left alive (`docsAlive`). A command that keeps its image in a
## variable of its own (a dialog's, a request's in flight, a cache's) without `forgetDoc` letting
## go of it keeps the image's layers and its history in memory for as long as the program runs:
## an hour of random input found 800 MB held so, and this test found four more (Fade, Generate
## Vector, Record Timelapse, Text in Picture).

import std/[strutils, os, algorithm]
import retroui/uirelays/input
import harness

const photoUnderTest = true
include ../examples/photo

let home = getTempDir() / "retro-photoleaks"
removeDir(home)
createDir(home)
putEnv("HOME", home)
setCurrentDir(home)
fakeDriver()
setup()
startApp("photo", W, H)
view = photoFrame

proc closeAll() =
  for _ in 0 .. 3:
    key(KeyEsc)
    run(1)
  while docs.len > 0: closeDoc(docs[0])
  run(3)
  GC_fullCollect()

proc makeDoc() =
  let d = newDoc(320, 240, 0xFFFFFFFF'u32, name = "leak")
  addDoc(d)
  for y in 0 ..< d.h:
    for x in 0 ..< d.w: d.layer.px[y * d.w + x] = argb(255, x mod 256, y mod 256, 128)
  inc d.layer.ver
  d.layersChange("shape"):
    discard d.addShapeLayer(ShapeData(path: rectPath(20, 20, 120, 90), fill: solidPaint(0xFFCC3333'u32)), "box")
  var st = defaultStyle()
  st.size = 18
  d.layersChange("type"): discard d.addTextLayer(newText("Some words", st, 60, 140))
  var m = newSeq[uint8](d.w * d.h)
  for y in 30 ..< 120:
    for x in 30 ..< 200: m[y * d.w + x] = 255
  d.setSelection(m)
  d.markAll()
  run(3)

# the commands: every name a `case` of the program's sources runs
var names: seq[string]
for f in walkFiles(currentSourcePath().parentDir.parentDir / "examples" / "photo" / "*.nim"):
  for line in lines(f):
    let l = line.strip
    if l.startsWith("of \""):
      let parts = l[3 .. ^1].split(':')[0].split('"')
      for i in countup(1, parts.high, 2):
        let n = parts[i]
        if n.len > 1 and n notin names: names.add n
names.sort()
doAssert names.len > 600, "the commands found: " & $names.len
const skip = ["Exit", "Quit", "Close", "Close All", "Close Others", "Revert", "Restart", "Print...",
              "Print One Copy", "Reset Preferences on Quit"]

closeAll()
let base = docsAlive()          # (the Scratch panel's own image, when it has one)
var kept: seq[string]
for n in names:
  if n in skip: continue
  makeDoc()
  runCommand(n)
  run(4)
  closeAll()
  if docsAlive() > base + kept.len: kept.add n
doAssert kept.len == 0, "closed images kept alive by: " & kept.join(", ")

# every tool of the tool box: a drag on the image, a double click, Enter -- the image closed
var tools = 0
for g in 0 ..< toolGroups.len:
  for k in 0 ..< toolGroups[g].items.len:
    makeDoc()
    pickTool(g, k)
    run(2)
    let (cx, cy) = (W div 2, H div 2)
    down(cx, cy)
    run(1)
    for s in 1 .. 4:
      queue.add Event(kind: MouseMoveEvent, x: cx + s * 12, y: cy + s * 9)
      run(1)
    up(cx + 48, cy + 36)
    run(2)
    down(cx + 20, cy - 20, clicks = 2)
    up(cx + 20, cy - 20)
    run(2)
    key(KeyEnter)
    run(2)
    closeAll()
    inc tools
    if docsAlive() > base + kept.len: kept.add "the " & $toolGroups[g].items[k].tool & " tool (" & $k & ")"
doAssert kept.len == 0, "closed images kept alive by: " & kept.join(", ")
echo "photoleaks: ", names.len, " commands, ", tools, " tools, no closed image kept"

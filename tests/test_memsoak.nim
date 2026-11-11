## A long session in a folder of photos, as a file manager has it: the
## icons at every size, each picture opened at the screen's size one after
## the other (a viewer's next and previous), again and again -- the memory
## the program holds must level off, not keep growing.

import std/[os, strutils, times, monotimes, random]
import retroui
import retroui/jpeg
import harness

fakeDriver()
startApp("memsoak", W, H)

proc rss(): int64 =
  ## The program's resident memory now (Linux), bytes.
  try:
    let f = readFile("/proc/self/statm").split(' ')
    parseBiggestInt(f[1]) * 4096
  except CatchableError: 0

proc waitFor(cond: proc (): bool; what: string; seconds = 60.0) =
  let until = epochTime() + seconds
  while not cond():
    doAssert epochTime() < until, "timed out: " & what
    run()
    os.sleep(1)

let root = getTempDir() / "retro-memsoak"
removeDir(root)
createDir(root)
var r = initRand(5)
var names: seq[string]
for i in 0 ..< 36:
  let w = 300 + r.rand(2200)
  let h = 200 + r.rand(1500)
  let b = newBitmap(w, h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      b.px[y * w + x] = 0xFF000000'u32 or uint32((x * 255 div w) shl 16) or uint32((y * 255 div h) shl 8) or
                        uint32((x xor y) and 255)
  let name = "photo " & $i & (if i mod 3 == 0: ".png" else: ".jpg")
  writeFile(root / name, if i mod 3 == 0: encodePng(b, level = 1) else: encodeJpeg(b, 85))
  names.add name

let m = newFolderModel(root)
var size = 48
view = proc () = discard fileList(m, fvIcons, iconSize = size)
waitFor(proc (): bool = m.dir == root and not m.loading and m.items.len == names.len, "listing")

var viewer: Bitmap
proc cycle() =
  # the icons at each size, until their pictures are there
  for s in [48, 72, 128, 200]:
    size = s
    run(2)
    waitFor(proc (): bool = not busy(), "thumbnails at " & $s)
    run(2)
  # each picture at the screen's size, one after the other
  for n in names:
    var done = false
    discard pictureAsync(root / n, 1600, 1600, priority = 5, onDone = proc (t: var TaskResult) =
      viewer = toBitmap(move t)
      done = true)
    waitFor(proc (): bool = done, "a picture")
    run()

var seen: seq[int64]
let t0 = getMonoTime()
for c in 0 ..< 12:
  cycle()
  seen.add rss()
  echo "cycle ", c + 1, ": ", seen[^1] div (1024 * 1024), " MB"
let grew = seen[^1] - seen[4]
echo "after the fifth cycle the memory grew ", grew div (1024 * 1024), " MB (",
     (getMonoTime() - t0).inSeconds, " s)"
when defined(linux) and defined(useMalloc):
  doAssert grew < 24 * 1024 * 1024, "the memory keeps growing: " & $(grew div (1024 * 1024)) & " MB"
  # (what it holds follows what it keeps: the pictures, not every page it
  # ever took -- 146 MB here with Nim's own allocator, 38 MB with malloc and
  # the trimming of retroui/memwatch)
  # (not under the sanitizers, which keep what is freed a while: 420 MB)
  when not defined(retroSanitized):
    doAssert seen[^1] < 120 * 1024 * 1024, "too much memory held: " & $(seen[^1] div (1024 * 1024)) & " MB"
removeDir(root)
echo "memory soak passed"

## Retro Files run headless (a phone-sized window): its dialogs and views,
## the Arabic interface, Folder Sizes, Copy To, the folders in windows -- then thousands of random
## taps, drags and keys in a folder of its own (half of them in Arabic). Nothing may fail: no
## exception, nothing in the fault log.

import std/[os, random, strutils]
let home = getTempDir() / "retro-filesapp-home"
removeDir(home)
createDir(home / "Pictures")
createDir(home / "Documents" / "Old")
putEnv("HOME", home)
putEnv("XDG_DATA_HOME", home / ".local" / "share")
putEnv("XDG_CACHE_HOME", home / ".cache")

import retroui
import retroui/uirelays/input
import harness
import ../examples/filemanager

for i in 0 ..< 30:
  let b = newBitmap(64 + i * 8, 48 + i * 4, 0xFF000000'u32 or uint32(i * 0x070503))
  writeFile(home / "Pictures" / ("shot " & $i & ".png"), encodePng(b))
for i in 0 ..< 40: writeFile(home / "Documents" / ("note " & $i & ".txt"), "line\n".repeat(i + 1))
writeFile(home / "Documents" / "readme.md", "# Title\n\nSome *Markdown*.\n")
writeFile(home / "Documents" / "Old" / "data.csv", "a,b\n1,2\n")

# (random input must not reach outside the test's own folder: jobs that
# would are refused, and after each step the app is put back in it)
proc inside(p: string): bool = p.len > 0 and (p == home or p.startsWith(home & "/"))
var jobsRun, jobsRefused, resets = 0
jobGuard = proc (kind: JobKind; sources: seq[string]; dest: string): bool =
  result = true
  for s in sources:
    if not inside(s): result = false
  if dest.len > 0 and not inside(dest): result = false
  if result: inc jobsRun else: inc jobsRefused

fakeDriver()
filesStart()
view = proc () = filesFrame()
run(5)
discard takeFaults()

proc noFault(what: string) =
  let f = takeFaults()
  doAssert f.len == 0, what & ":\n" & f
  doAssert ui.lastFault.len == 0, what & ": " & ui.lastFault

# the dialogs, one by one
go(home / "Pictures")
run(20)
for step in 0 .. 7:
  setView(step)
  run(5)
noFault("views")
settingsOpen = true
run(5)
key(KeyEsc)
run(3)
aboutOpen = true
run(5)
aboutOpen = false
keysOpen = true
run(3)
keysOpen = false
reportProblem("a test")
run(3)
key(KeyEsc)
run(2)
go(home)
run(10)
openSizes()
for _ in 0 ..< 40:
  run()
  os.sleep(1)
doAssert sizesOpen
sizesOpen = false
run(2)
noFault("dialogs")

# the folders in windows of their own (View > Folders in Windows): a new
# one in front, the commands act on the one in front, Ctrl+F4 closes it
# (the last one stays)
toggleWindows()
run(3)
doAssert inWindows
go(home / "Pictures")
run(20)
key(KeyT, {CtrlPressed})
run(5)
go(home / "Documents")
run(20)
doAssert currentFolder().dir == home / "Documents", currentFolder().dir
key(KeyF4, {CtrlPressed})
run(5)
doAssert currentFolder().dir == home / "Pictures", currentFolder().dir
key(KeyF4, {CtrlPressed})
run(5)
doAssert currentFolder().dir == home / "Pictures"
key(KeyF5, {ShiftPressed})
run(3)
key(KeyF4, {ShiftPressed})
run(3)
toggleWindows()
run(3)
doAssert not inWindows
noFault("windows")

# Arabic, mirrored
language = 1
applyLanguage()
go(home / "Documents")
run(20)
doAssert ui.rtl
settingsOpen = true
run(5)
settingsOpen = false
aboutOpen = true
run(5)
aboutOpen = false
language = 0
applyLanguage()
run(3)
noFault("Arabic")

# random input: taps, double taps, long presses, drags, wheel, keys
var r = initRand(20261101)
const keys = [KeyUp, KeyDown, KeyLeft, KeyRight, KeyEnter, KeyEsc, KeyBackspace, KeyHome,
              KeyEnd, KeyPageUp, KeyPageDown, KeyTab, KeyF2, KeyF3, KeyF5, KeySpace, KeyA,
              KeyC, KeyV, KeyX, KeyZ, KeyD, KeyF, KeyL]
for i in 0 ..< 6000:
  if i == 3000:                      # (the second half in Arabic, mirrored)
    language = 1
    applyLanguage()
  # (a part of each half with the folders in windows)
  if i in [1000, 2200, 4000, 5200]: toggleWindows()
  let x = r.rand(W - 1)
  let y = r.rand(H - 1)
  case r.rand(9)
  of 0, 1, 2:
    down(x, y)
    run()
    up(x, y)
  of 3:
    down(x, y, clicks = 2)
    run()
    up(x, y)
  of 4:
    down(x, y)
    for k in 1 .. 4:
      move(clamp(x + k * r.rand(-40 .. 40), 0, W - 1), clamp(y + k * r.rand(-40 .. 40), 0, H - 1))
      run()
    up(x, y)
  of 5:
    queue.add Event(kind: MouseMoveEvent, x: x, y: y)
    queue.add Event(kind: MouseWheelEvent, y: r.rand(-3 .. 3))
  of 6:
    var mods: set[Modifier]
    if r.rand(3) == 0: mods.incl CtrlPressed
    if r.rand(5) == 0: mods.incl ShiftPressed
    key(keys[r.rand(keys.high)], mods)
  of 7: typeText($char(ord('a') + r.rand(25)))
  else: run(2)
  run()
  # (what would leave the test: Exit, a folder outside its home)
  ui.running = true
  # (a folder being read: its listing in before the next step, so no step
  # acts on a folder outside)
  var w = 0
  while currentFolder().loading and w < 2000:
    run()
    os.sleep(1)
    inc w
  let (dir, _) = currentFolder()
  if dir.len > 0 and not inside(dir):
    inc resets
    go(home)
    var n = 0
    while (currentFolder().dir != home or currentFolder().loading) and n < 2000:
      run()
      os.sleep(1)
      inc n
  if i mod 200 == 0:
    noFault("random input, step " & $i)
run(10)
noFault("random input")
echo "random input: ", jobsRun, " file jobs, ", jobsRefused, " refused (outside), ", resets,
     " times back home"
# two copies asked for at once: the second waits for the first, then runs
block jobQueue:
  # (what random input left -- a job, one asking "replace?" -- let go, and
  # files of the test's own: random input may have moved the others)
  cancelJobs()
  var n = 0
  while jobRunning() and n < 3000:
    key(KeyEsc)
    run()
    os.sleep(1)
    inc n
  doAssert not jobRunning(), "random input's job ended"
  let src = home / "qsrc"
  let qa = home / "qa"
  let qb = home / "qb"
  for d in [src, qa, qb]: createDir(d)
  writeFile(src / "one.txt", "one")
  writeFile(src / "two.txt", "two")
  startJob(jkCopy, @[src / "one.txt"], qa, "Copying")
  startJob(jkCopy, @[src / "two.txt"], qb, "Copying")
  doAssert jobRunning() and jobsWaiting() == 1, "the second copy waits"
  n = 0
  while (jobRunning() or jobsWaiting() > 0) and n < 5000:
    run()
    os.sleep(1)
    inc n
  doAssert readFile(qa / "one.txt") == "one" and readFile(qb / "two.txt") == "two",
    "both copied, one after the other"
  noFault("jobs one after another")
filesStop()
removeDir(home)
echo "Retro Files app tests passed"

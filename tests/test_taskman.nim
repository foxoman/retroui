## Retro Task Manager (examples/taskman) as a program, run headless: the
## processes listed with this one among them, searched and sorted, the
## selection kept on the same process as the list changes; the Performance
## page's graphs moving with the samples; the Startup, Network and History
## pages; paused; a phone's layout. TASKMAN_SHOTS=folder writes the
## pages' pictures there.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils]
import retroui/uirelays/input
import harness
import retroui/charts {.all.}

const taskmanUnderTest = true
include ../examples/taskman

let home = getTempDir() / "retro-taskman-apptest"
removeDir(home)
createDir(home)
putEnv("HOME", home)
putEnv("XDG_CONFIG_HOME", home / ".config")
putEnv("XDG_DATA_HOME", home / ".local/share")

let shots = getEnv("TASKMAN_SHOTS")

proc shot(name: string) =
  if shots.len == 0: return
  createDir(shots)
  var b = newBitmap(W, H)
  for i in 0 ..< W * H: b.px[i] = pixels[i] or 0xFF000000'u32
  b.changed()
  discard savePng(b, shots / name & ".png")

proc waitSamples(n: int) =
  ## (frames until `n` more samples came from the reading thread)
  let want = sampleNo + n
  for i in 0 .. 400:
    run(1)
    if sampleNo >= want: break
    os.sleep(25)
  run(2)

fakeDriver()
speed = 0                                   # (twice a second: the test is quicker)
taskmanStart()
harness.view = taskmanFrame
waitSamples(2)

block processes:
  doAssert current != nil, "a sample"
  doAssert shown.len > 0 and shown.len == current.processes.len
  var mine = -1
  for i, p in shown:
    if p.pid == getCurrentProcessId(): mine = i
  doAssert mine >= 0, "this program among them"
  # sorted by CPU, the busiest first
  for i in 1 ..< shown.len: doAssert shown[i - 1].cpu >= shown[i].cpu
  # selected: it stays selected as new samples come and the order changes
  sel = mine
  selKey = (shown[mine].pid, shown[mine].started)
  waitSamples(1)
  doAssert sel >= 0 and shown[sel].pid == getCurrentProcessId(), "the same process kept selected"
  shot("processes")
  # the menu's keys: Ctrl+C copies it, Alt+Enter its properties, Delete asks
  key(KeyC, {CtrlPressed})
  run(2)
  when not defined(macosx):
    doAssert "test_taskman" in getClipboardText(), getClipboardText()
  key(KeyEnter, {AltPressed})
  run(2)
  doAssert propsOpen and propsOf.pid == getCurrentProcessId()
  propsOpen = false
  run(1)
  key(KeyDelete)
  run(2)
  doAssert askEnd, "Delete asks first"
  askEnd = false
  run(1)
  # searched
  query = "test_taskman"
  refreshShown(current)
  doAssert shown.len >= 1 and shown.allIt("test_taskman" in it.name or "test_taskman" in it.command or
                                         "test_taskman" in it.user.toLowerAscii)
  query = ""
  refreshShown(current)
  # sorted by name
  sortCol = 0
  sortDesc = false
  sortShown()
  for i in 1 ..< shown.len:
    doAssert cmp(shown[i - 1].name.toLowerAscii, shown[i].name.toLowerAscii) <= 0
  sortCol = 2
  sortDesc = true
  sortShown()
  echo "processes: ", shown.len

block performance:
  page = pgPerformance
  run(2)
  let before = sampleNo
  waitSamples(2)
  doAssert sampleNo > before
  doAssert recent.len >= 2, "the last minutes kept"
  # the graph's picture, kept: black, its grid and a green line
  doAssert "cpu" in liveGraphs, "the processor's graph"
  var green, black = 0
  for p in pixels:
    if (p and 0xFFFFFF'u32) == 0x00FF00'u32: inc green
    elif (p and 0xFFFFFF'u32) == 0: inc black
  doAssert green > 20 and black > 5000, "drawn: " & $green & " green, " & $black & " black"
  shot("performance")
  perfSel = 1
  run(2)
  doAssert "mem" in liveGraphs, "the memory's graph"
  shot("memory")
  perfSel = 0

block otherPages:
  page = pgStartup
  run(2)
  shot("startup")
  page = pgNetwork
  run(2)
  doAssert conns.len > 0 or connsWhy.len > 0
  shot("network")
  page = pgHistory
  appendHistory(histFile, current)
  histRead = -1e9
  run(2)
  doAssert fileExists(histFile), "the history written"
  page = pgProcesses
  run(2)

block paused:
  speed = 3
  let at = current.at
  os.sleep(1200)
  run(3)
  doAssert current.at == at, "paused: what is shown stays"
  speed = 0
  waitSamples(1)
  doAssert current.at != at, "and goes on"

block phone:
  # a narrow window (a phone): the bottom bar, three columns
  setUiScale(150)
  run(3)
  doAssert isCompact()
  page = pgProcesses
  waitSamples(1)
  doAssert shown.len > 0
  shot("phone")
  for p in Page:
    page = p
    run(2)
  page = pgProcesses
  setUiScale(100)
  run(2)
  doAssert not isCompact()

taskmanStop()
echo "task manager tests passed"

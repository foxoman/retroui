## Tests of retroui/flows on a clock of the test's own: a flow goes on at the end of a frame,
## a question's answer (Esc: the last button), a wait until something is so, a pause, work on
## a worker and its value, a file picker cancelled, a flow of a window that closed dropped, a
## flow that fails ended (the fault noted) while the others go on.

import std/[strutils, os]
import retroui, retroui/[headless, flows]
import retroui/uirelays/input

useHeadless(500, 400)
startApp("Flows", 500, 400)
var clock = 1000
inputRelays.getTicks = proc (): int = clock
proc frame(ms = 16) =
  clock += ms
  discard beginFrame()
  label "flows"
  endFrame()

var log: seq[string]
var ready = false

block answeredAndWaited:
  let f = flow("save"):
    log.add "asked"
    let a = ask("Save changes?", ["&Yes", "&No", "Cancel"])
    log.add "answer " & $a
    if a == 3: return
    log.add "not here"
  doAssert log.len == 0, "not run before the frame ends"
  frame()
  doAssert log == @["asked"] and flowRunning("save")
  frame()
  headlessInput(Event(kind: KeyDownEvent, key: KeyEsc))
  frame()
  frame()
  doAssert log == @["asked", "answer 3"], $log
  doAssert f.done and not flowRunning("save")

block untilPauseWorker:
  log.setLen(0)
  discard flow("steps"):
    waitUntil(ready)
    log.add "ready"
    let t0 = ui.now
    pause(300)
    log.add "paused " & $(ui.now - t0 >= 300)
    let v = onWorker(int, 6 * 7)
    log.add "worker " & $v
    nextFrame()
    log.add "end"
  for i in 0 ..< 3: frame()
  doAssert log.len == 0, "waiting until ready"
  ready = true
  frame()
  doAssert log == @["ready"]
  frame(100)
  doAssert log.len == 1, "still pausing"
  frame(250)
  # (the worker's job in real time: a busy machine may take a while)
  for i in 0 ..< 2500:
    frame()
    if "end" in log: break
    os.sleep(2)
  doAssert log == @["ready", "paused true", "worker 42", "end"], $log

block cancelledWithItsWindow:
  log.setLen(0)
  discard ownedFlow("doc 1", "close"):
    waitUntil(false)
    log.add "never"
  discard ownedFlow("doc 2", "other"):
    nextFrame()
    log.add "other"
  frame()
  cancelFlows("doc 1")
  for i in 0 ..< 3: frame()
  doAssert log == @["other"] and not flowRunning(owner = "doc 1")

block failureEnded:
  log.setLen(0)
  discard flow("bad"):
    nextFrame()
    raise newException(ValueError, "on purpose")
  discard flow("good"):
    nextFrame()
    nextFrame()
    log.add "good"
  for i in 0 ..< 4: frame()
  doAssert "on purpose" in ui.lastFault and not flowRunning("bad")
  doAssert log == @["good"]

block pickCancelled:
  var got = "x"
  discard flow("pick"):
    got = pickFile(fmOpen, ["*.txt"])
  for i in 0 ..< 3: frame()
  headlessInput(Event(kind: KeyDownEvent, key: KeyEsc))
  for i in 0 ..< 3: frame()
  doAssert got == "" and not flowRunning("pick"), "cancelled: " & got

stopApp()
echo "test_flows: ok"

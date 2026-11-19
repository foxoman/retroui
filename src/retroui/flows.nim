## Steps of the UI that wait -- a question asked, a file picked, a job on a worker, a moment --
## written one after another, as a plain proc reads, not as state kept across frames:
##
## .. code-block:: nim
##   discard flow("close " & doc.name):
##     case ask("Save changes to \"" & doc.name & "\"?", ["&Yes", "&No", "Cancel"])
##     of 1:
##       let path = pickFile(fmSave, ["*.txt"])
##       if path.len == 0: return               # (no file: the document stays open)
##       let saved = onWorker(bool, writeTo(doc, path))
##       if not saved: return
##     of 2: discard
##     else: return
##     closeDoc(doc)
##
## A flow is a closure iterator: each wait (`ask`, `pickFile`, `waitUntil`, `onWorker`,
## `pause`, `nextFrame`) gives the frame back, and the flow goes on at the end of a later
## frame, once what it waits for has come -- never in the middle of drawing. Its box (a
## question, the file picker) is drawn by the kit meanwhile; the window keeps working.
## `return` ends it. A flow may belong to an owner (a document's window: `ownedFlow`):
## `cancelFlows(owner)` drops those still waiting when it closes. A flow that fails is ended and the fault logged,
## as `guarded` does.
##
## It is the shape of Nimony's `.passive` procs, built on Nim 2's closure iterators; when
## the kit moves to Nimony, the same code becomes `.passive` procs.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import core, widgets, business, filewidgets, jobs

type
  FlowWaitKind* = enum
    ## What a flow waits for.
    fwStart, fwFrame, fwAsk, fwPick, fwUntil, fwPause

  FlowStep* = object
    ## (what a flow yields: what it waits for)
    case kind*: FlowWaitKind
    of fwAsk:
      title*, text*: string
      buttons*: seq[string]
      icon*: MsgIcon
    of fwPick:
      mode*: business.FileMode
      patterns*: seq[string]
      pickTitle*, start*: string
    of fwUntil:
      ready*: proc (): bool {.closure.}
    of fwPause:
      ms*: int
    else: discard

  Flow* = ref object
    ## A flow running: what it is called, whose it is, what it waits for.
    name*: string
    owner*: string
    it: iterator (): FlowStep {.closure.}
    step: FlowStep
    open: bool                 # (its box shown)
    answer: int
    path: string
    at: int
    done*: bool                ## ended (its last step done, returned, cancelled or failed)

var
  flows: seq[Flow]
  flowNow*: Flow
    ## The flow going on now (in its body: the answer to what it waited for).

proc flowRunning*(name = ""; owner = ""): bool =
  ## A flow of that name (or of `owner`; both empty: any) is under way.
  for f in flows:
    if not f.done and (name.len == 0 or f.name == name) and (owner.len == 0 or f.owner == owner):
      return true

proc startFlow*(name: string; it: iterator (): FlowStep {.closure.}; owner = ""): Flow {.discardable.} =
  ## Starts a flow (`flow` makes one from a body); it runs at the end of this frame.
  result = Flow(name: name, owner: owner, it: it, step: FlowStep(kind: fwStart), at: ui.now)
  flows.add result
  wakeIn(1)

template flow*(name: string; body: untyped): Flow =
  ## A flow of `body`: its waits (`ask`, `pickFile`, `waitUntil`, `onWorker`, `pause`,
  ## `nextFrame`) give the frame back; `return` ends it.
  startFlow(name, iterator (): FlowStep {.closure.} =
    body)

template ownedFlow*(owner, name: string; body: untyped): Flow =
  ## A flow of `body` that belongs to `owner` (a document's window): `cancelFlows(owner)`
  ## ends it. (A name of its own, not an overload of `flow`: the compiler would try the body
  ## as the owner first.)
  startFlow(name, iterator (): FlowStep {.closure.} =
    body, owner)

proc cancelFlows*(owner: string) =
  ## Ends the flows of `owner` (its window closed): they do not go on.
  for f in flows:
    if f.owner == owner: f.done = true

# ---- what a flow waits for (in its body only) ----------------------------------------------------------

proc askStep*(text: string; buttons: openArray[string]; title: string; icon: MsgIcon): FlowStep =
  ## (`ask`'s step)
  FlowStep(kind: fwAsk, text: text, buttons: @buttons, title: title, icon: icon)

proc pickStep*(mode: business.FileMode; patterns: openArray[string]; title, start: string): FlowStep =
  ## (`pickFile`'s step)
  FlowStep(kind: fwPick, mode: mode, patterns: @patterns, pickTitle: title, start: start)

proc untilStep*(ready: proc (): bool {.closure.}): FlowStep = FlowStep(kind: fwUntil, ready: ready)
  ## (`waitUntil`'s step)

proc pauseStep*(ms: int): FlowStep = FlowStep(kind: fwPause, ms: ms)
  ## (`pause`'s step)

proc frameStep*(): FlowStep = FlowStep(kind: fwFrame)
  ## (`nextFrame`'s step)

template ask*(text: string; buttons: openArray[string] = ["OK"]; title = ""; icon = miQuestion): int =
  ## A question (`msgBox`): the number of the button clicked, 1 the first; Esc and the
  ## close button: the last.
  yield askStep(text, buttons, title, icon)
  flowNow.answer

template pickFile*(mode: business.FileMode; patterns: openArray[string] = []; title = ""; start = ""): string =
  ## A file picked (`filePicker`): its path, "" when the user cancelled.
  yield pickStep(mode, patterns, title, start)
  flowNow.path

template waitUntil*(cond: untyped) =
  ## Waits until `cond` is true (asked again at the end of each frame; frames come every 50 ms
  ## meanwhile).
  yield untilStep(proc (): bool = cond)

template nextFrame*() =
  ## Waits for the next frame (what the flow changed is drawn first).
  yield frameStep()

template pause*(ms: int) =
  ## Waits `ms` milliseconds (the window goes on meanwhile).
  yield pauseStep(ms)

template onWorker*(T: typedesc; work: untyped): untyped =
  ## `work` on a worker (`retroui/jobs`), its value when it is done -- what must not hold up the
  ## window: a file read, the keyring asked, the network. A failure is raised in the flow.
  block:
    let j = job(proc (c: JobCtl): T {.gcsafe.} = work)
    yield untilStep(proc (): bool = j.ended)
    if j.failed: raise newException(CatchableError, j.error)
    j.value

# ---- running them --------------------------------------------------------------------------------------

proc ended(f: Flow) = f.done = true

proc runFlows() =
  ## (at the end of each frame: the boxes of those waiting drawn, those whose wait is over
  ## taken on to their next wait)
  var i = 0
  while i < flows.len:
    let f = flows[i]
    if f.done:
      flows.delete(i)
      continue
    flowNow = f
    var ready = false
    case f.step.kind
    of fwStart, fwFrame: ready = true
    of fwAsk:
      let a = msgBox(f.open, f.step.title, f.step.text, f.step.buttons, f.step.icon)
      if a > 0:
        f.answer = a
        ready = true
    of fwPick:
      if filePicker(f.open, f.path, f.step.mode, f.step.patterns, f.step.pickTitle):
        ready = true
      elif not f.open:
        f.path = ""                          # (cancelled)
        ready = true
    of fwUntil:
      ready = f.step.ready()
      if not ready: wakeIn(50)
    of fwPause:
      ready = ui.now - f.at >= f.step.ms
      if not ready: wakeIn(max(1, f.step.ms - (ui.now - f.at)))
    if ready:
      try:
        let s = f.it()
        if finished(f.it) or f.done:
          f.ended()
        else:
          f.step = s
          f.at = ui.now
          f.open = s.kind in {fwAsk, fwPick}
          if s.kind == fwPick: f.path = s.start
          wakeIn(if s.kind == fwPause: max(1, s.ms) else: 1)
      except CatchableError as e:
        noteFault("flow " & f.name, e.msg & "\n" & e.getStackTrace())
        ui.lastFault = "flow " & f.name & ": " & e.msg
        f.ended()
    if f.done:
      flows.delete(i)
      continue
    inc i
  flowNow = nil

endFrameHooks.add runFlows

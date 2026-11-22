## Work that takes a while, on the thread that draws: the hook through
## which long loops keep the window alive. After a moment a box comes up
## with an animation (and a Cancel), the screen is kept drawn and the
## system's events read (a phone does not think the app hangs); Esc or
## Cancel asks the work to stop.
##
## Long loops call `busyTick()` now and then (`parallelFor` does it while
## it waits for the cores); `retroui/core` sets what it does. Work that can
## be stopped is marked with `beginBusy(label, cancel = true)` ...
## `endBusy()`: a tick then raises `BusyCancelled` once Cancel was pressed,
## at a point where nothing is half written (an undo step is there to take
## back what was done).
##
## ```nim
## beginBusy("Counting words", cancel = true)
## try:
##   for i, line in lines:
##     busyFraction = i / lines.len        # the box shows how far it is
##     busyTickCheck()                     # draws, reads events, may raise
##     count(line)
## except BusyCancelled:
##   discard                               # the user stopped it
## finally:
##   endBusy(cancel = true)
## ```

import std/monotimes

type BusyCancelled* = object of CatchableError
  ## The user pressed Cancel (or Esc) while the work went on.

var
  busyHook*: proc () {.nimcall.}
    ## What a tick does (set by `retroui/core`: the box, the events).
  busyCancelAsked*: bool
    ## Cancel was pressed (reset by `beginBusy`).
  busyDepth*: int                 ## how many `beginBusy` are open (0: no work under way)
  busyCancelDepth*: int           ## how many of the open `beginBusy` can be cancelled
  busyLabel*: string              ## what is being done ("Gaussian Blur")
  busyStarted*: int64             ## when the work began (ms, see `busyNow`)
  busyFraction*: float = -1       ## how much is done (0..1; -1 not known)
  lastBusy*: tuple[label: string; ms: float]
    ## the last work done (`beginBusy` to `endBusy`) and how long it took
  busyLabels: seq[string]
  uiThread {.threadvar.}: bool

proc markUiThread*() =
  ## This thread draws (ticks on others do nothing).
  uiThread = true

proc onUiThread*(): bool {.inline.} = uiThread
  ## This thread draws (see `markUiThread`).

proc busyNow*(): int64 =
  ## A clock for timing work, in milliseconds.
  getMonoTime().ticks div 1_000_000

var busyBegan: int64             # (ns: the outermost work's start)

proc busyCheck*() =
  ## Raises `BusyCancelled` when Cancel was pressed in work that can be
  ## cancelled (at a point where that is safe).
  if uiThread and busyCancelAsked and busyCancelDepth > 0:
    busyCancelAsked = false
    when defined(busyDebug): writeStackTrace()
    raise newException(BusyCancelled, "cancelled")

proc busyTick*() {.gcsafe.} =
  ## Keeps the window alive during long work (cheap when called often). Safe on any thread:
  ## only the one that draws runs the hook.
  if uiThread and busyHook != nil:
    {.cast(gcsafe).}: busyHook()

proc busyTickCheck*() =
  ## `busyTick` and `busyCheck`: for loops that can stop where they are.
  busyTick()
  busyCheck()

proc beginBusy*(label: string; cancel = false) =
  ## Work named `label` begins (shown in the box); `cancel`: it can be
  ## stopped. Nested calls keep the outer label.
  busyLabels.add busyLabel
  if busyDepth == 0:
    busyLabel = label
    busyCancelAsked = false
    busyFraction = -1
    if uiThread:
      busyBegan = getMonoTime().ticks
      busyStarted = busyBegan div 1_000_000
  elif busyLabel.len == 0 and label.len > 0:
    busyLabel = label
    busyFraction = -1
  inc busyDepth
  if cancel: inc busyCancelDepth

proc endBusy*(cancel = false) =
  ## The work begun with `beginBusy` is over (its label goes).
  if busyDepth > 0: dec busyDepth
  if cancel and busyCancelDepth > 0: dec busyCancelDepth
  if busyLabels.len > 0:
    let before = busyLabels.pop()
    if before != busyLabel: busyFraction = -1
    busyLabel = before
  if busyDepth == 0:
    if uiThread and busyLabel.len > 0:
      lastBusy = (busyLabel, float(getMonoTime().ticks - busyBegan) / 1e6)
    busyLabel = ""
    busyCancelAsked = false
    busyFraction = -1

template busy*(label: string; body: untyped) =
  ## `body` as work named `label` (not cancelled).
  beginBusy(label)
  try: body
  finally: endBusy()

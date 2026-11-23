## Signals: values that know what was worked out from them. An immediate mode app draws every
## frame from its variables, and that is all most need; a value worked out from others that is
## slow to work out -- a filtered and sorted list of thousands, a chart's points, a page laid out
## -- is worked out again only when what it was made from changed: `computed` remembers what it
## read and its answer. `effect` runs again when what it read changes (a save, a search sent).
##
## .. code-block:: nim
##   import retroui, retroui/signals
##   let query = signal("")
##   let rows = signal(loadRows())
##   let shown = computed(proc (): seq[Row] =
##     rows.value.filterIt(query.value in it.name).sortedByIt(it.name))
##   app("Rows", 600, 400):
##     var q = query.value
##     if edit(q): query.value = q          # (shown is worked out again on the next read)
##     for r in shown.value: label r.name   # (else its answer from before)
##
## A signal set to the value it has changes nothing. Setting one asks for a frame (the window
## drawn again), so a signal set from a job, a timer or a socket's answer shows. `computed` and
## `effect` find what they read by themselves, each time they run: a read in an `if` counts when
## that branch ran. Effects run in `runEffects`, which each frame calls (an app without a window:
## call it). On one thread, the UI's.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net

import core

type
  Source* = ref object of RootObj
    ## (what a computed value or an effect can read: a signal or a computed value)
    version: int                     ## how many times it changed
    refresher: proc () {.closure.}   ## (a computed value: brought up to date)

  Signal*[T] = ref object of Source
    ## A value that tells what read it when it changes.
    v: T

  Computed*[T] = ref object of Source
    ## A value worked out from signals (and other computed values), again only when they changed.
    fn: proc (): T
    cache: T
    deps: seq[tuple[s: Source; seen: int]]
    ready: bool
    runs: int

  Effect* = ref object
    ## Work done again when what it read changes (`effect`).
    fn: proc ()
    deps: seq[tuple[s: Source; seen: int]]
    stopped: bool
    runs: int

var
  reading: ptr seq[tuple[s: Source; seen: int]]   # (what the computed value or effect running reads)
  effects: seq[Effect]
  hooked = false

proc current(s: Source): int =
  ## (its version now: a computed value brought up to date first)
  if s.refresher != nil: s.refresher()
  s.version

proc note(s: Source) =
  if reading != nil:
    for d in reading[]:
      if d.s == s: return
    reading[].add (s, s.version)

proc stale(deps: seq[tuple[s: Source; seen: int]]): bool =
  for d in deps:
    if d.s.current != d.seen: return true

proc signal*[T](value: T): Signal[T] =
  ## A signal holding `value`.
  Signal[T](v: value)

proc value*[T](s: Signal[T]): T =
  ## Its value (noted by the computed value or effect that reads it).
  s.note()
  s.v

proc peek*[T](s: Signal[T]): T = s.v
  ## Its value, not noted: read without being a reason to work again.

proc `value=`*[T](s: Signal[T]; value: T) =
  ## Set: what read it works again (when the value is not the one it has).
  when compiles(s.v == value):
    if s.v == value: return
  s.v = value
  inc s.version
  invalidate()

proc update*[T](s: Signal[T]; change: proc (v: var T)) =
  ## Changed in place (a sequence added to): always counts as a change.
  change(s.v)
  inc s.version
  invalidate()

proc version*(s: Source): int = s.version
  ## How many times it changed.

proc refresh[T](c: Computed[T]) =
  if c.ready and not stale(c.deps): return
  var deps: seq[tuple[s: Source; seen: int]]
  let outer = reading
  reading = addr deps
  try:
    let v = c.fn()
    inc c.runs
    var same = false
    when compiles(v == c.cache):
      same = c.ready and v == c.cache
    c.cache = v
    if not same: inc c.version
    c.ready = true
  finally:
    reading = outer
  c.deps = deps

proc computed*[T](fn: proc (): T): Computed[T] =
  ## A value worked out by `fn` when it is read, and kept until what `fn` read changes.
  let c = Computed[T](fn: fn)
  c.refresher = proc () = c.refresh()
  c

proc value*[T](c: Computed[T]): T =
  ## Its value: worked out again if what it read changed, else as before.
  c.refresh()
  c.note()
  c.cache

proc runs*[T](c: Computed[T]): int = c.runs
  ## How many times it was worked out.

proc runEffect(e: Effect) =
  var deps: seq[tuple[s: Source; seen: int]]
  let outer = reading
  reading = addr deps
  try:
    e.fn()
    inc e.runs
  finally:
    reading = outer
  e.deps = deps

proc runEffects*() =
  ## The effects whose signals changed, run again (each frame does it).
  var i = 0
  while i < effects.len:
    let e = effects[i]
    if e.stopped:
      effects.delete(i)
      continue
    if stale(e.deps): e.runEffect()
    inc i

proc effectsTick() {.nimcall.} = runEffects()

proc effect*(fn: proc ()): Effect =
  ## `fn` run now, and again whenever a signal or computed value it read changes.
  result = Effect(fn: fn)
  result.runEffect()
  effects.add result
  if not hooked:
    hooked = true
    beginFrameHooks.add effectsTick

proc stop*(e: Effect) =
  ## Not run again.
  e.stopped = true

proc runs*(e: Effect): int = e.runs
  ## How many times it ran.

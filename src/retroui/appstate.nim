## An app's state kept across its ends: what the user was doing -- the page open, the list's
## place, a half-written message -- written as NIF (`retroui/nif`) when the app goes to the
## background and when it ends, and read back when it starts, so a phone that ended it meanwhile
## to free memory brings the user back where they were, as the guides ask.
##
## ```nim
## type Ui = object
##   page: int
##   scroll: int
##   draft: string
## var st = restoreState("main", Ui())     # (at start: as it was left, or this)
## ...
## keepState("main", st)                    # (in the frame: written only when it has to be)
## ```
##
## The value is read only when it is written -- as the app is paused or ends -- so a big state
## costs nothing a frame; with the persistent collections (`retroui/persist`) keeping one is
## free. A state that can't be read back (the app's types changed) gives the default.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[tables, os, exitprocs]
import uirelays/services
import core, nif

var
  kept: OrderedTable[string, proc (): string {.closure.}]   # (each state: makes its NIF)
  written: Table[string, string]                              # (... the NIF written last)
  stateFolder* = ""
    ## Where the states are written ("": the app's own data folder, its `state` folder).
  hooked: bool

proc stateDir(): string =
  if stateFolder.len > 0: stateFolder else: dataDir("") / "state"

proc statePath*(name: string): string = stateDir() / (name & ".nif")
  ## The file the state `name` is kept in.

proc writeStates*() =
  ## Writes every kept state that changed since it was written last (the kit does it as the app
  ## is paused and as it ends; call it after a change that must not be lost).
  for name, make in kept:
    let t = try: make() except CatchableError: ""
    if t.len == 0 or written.getOrDefault(name) == t: continue
    try:
      createDir(stateDir())
      let p = statePath(name)
      writeFile(p & ".new", t)
      moveFile(p & ".new", p)
      written[name] = t
    except CatchableError: discard

proc hookStates() =
  if hooked: return
  hooked = true
  pauseHooks.add writeStates
  addExitProc(proc () = writeStates())

proc keepStateWith*(name: string; make: proc (): string {.closure.}) =
  ## Keeps the state `name` made by `make` (its NIF): written as the app is paused or ends.
  hookStates()
  kept[name] = make

template keepState*(name: string; v: untyped) =
  ## Keeps `v` as the state `name`: written as NIF as the app is paused or ends, when it changed
  ## (`restoreState` reads it back). Call it every frame or once: `v` is read only then.
  if name notin kept: keepStateWith(name, proc (): string = toNif(v))

proc restoreState*[T](name: string; default: T): T =
  ## The state `name` as it was kept (`keepState`) when the app was paused or ended last;
  ## `default` the first time, or when it can't be read.
  result = loadNif(statePath(name), T, default)
  try:
    if fileExists(statePath(name)): written[name] = readFile(statePath(name))
  except CatchableError: discard

proc forgetState*(name: string) =
  ## The state `name` no longer kept, its file removed (signed out, a fresh start).
  kept.del name
  written.del name
  try: removeFile(statePath(name))
  except CatchableError: discard

## Values kept across the runs of `retrokit run --watch`: the app is built and started again on
## every save of its code, and what `keep` names comes back as the run before left it -- the page
## a wizard was on, what was typed, the list, the counter -- so a change to the code is seen with
## the app where you were, not from the start.
##
## .. code-block:: nim
##   import retroui, retroui/keep
##   var page = 0
##   var names: seq[string]
##   keep page, names     # put back from the run before, and noted for the next one
##
## Off but in `--watch` (`retrokit` sets $RETRO_KEEP_STATE to a file of its own): a program run
## any other way keeps nothing and costs nothing. A value is anything `std/jsonutils` can write
## and read: numbers, strings, enums, objects, sequences, tables -- not refs to procs or windows.
## A value whose type changed between two runs (a field added) starts again from what the code
## gives it. The values are written a quarter of a second after they change, and when the app
## ends; `keepAt` names a value itself, where two modules' variables have the same name.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net

import std/[json, jsonutils, os, times, macros]
import core

var
  keepers: seq[tuple[name: string; save: proc (): JsonNode {.closure.}]]
  keptRead = false
  kept: JsonNode
  lastText = ""
  lastAt = 0.0
  hooked = false

proc keepsState*(): bool = getEnv("RETRO_KEEP_STATE").len > 0
  ## The values named by `keep` are kept for the next run ($RETRO_KEEP_STATE is set:
  ## `retrokit run --watch`).

proc keptNode(name: string): JsonNode =
  if not keptRead:
    keptRead = true
    try: kept = parseFile(getEnv("RETRO_KEEP_STATE"))
    except CatchableError: kept = nil
  if kept != nil and kept.kind == JObject: kept{name} else: nil

proc saveKept*() =
  ## Writes the values `keep` names now ($RETRO_KEEP_STATE; nothing when it is not set or
  ## nothing changed). Run by itself after each frame (every quarter of a second at most) and
  ## when the app ends.
  let path = getEnv("RETRO_KEEP_STATE")
  if path.len == 0 or keepers.len == 0: return
  var o = newJObject()
  for k in keepers:
    try: o[k.name] = k.save()
    except CatchableError: discard
  let text = $o
  if text == lastText: return
  try:
    writeFile(path & ".new", text)
    moveFile(path & ".new", path)          # (a run starting reads it whole, never half written)
    lastText = text
  except CatchableError: discard

proc keepTick() {.nimcall.} =
  let t = epochTime()
  if t - lastAt >= 0.25:
    lastAt = t
    saveKept()

proc keepAt*[T](name: string; v: ptr T) =
  ## The value at `v` put back as the run before left it, when it did (`keep` with a name of
  ## your own), and noted for the next run.
  if not keepsState(): return
  let n = keptNode(name)
  if n != nil:
    try: v[] = jsonTo(n, T)
    except CatchableError: discard        # (its type changed: as the code gives it)
  for k in keepers.mitems:
    if k.name == name:
      k.save = proc (): JsonNode = toJson(v[])
      return
  keepers.add (name, proc (): JsonNode = toJson(v[]))
  if not hooked:
    hooked = true
    endFrameHooks.add keepTick
    stopAppHooks.add proc () {.nimcall.} = saveKept()

macro keep*(vars: varargs[typed]): untyped =
  ## Each variable put back as the run before left it (`retrokit run --watch`), and noted for
  ## the next run -- named by its name (`keepAt` for another).
  result = newStmtList()
  for v in vars:
    let name = newLit(v.repr)
    result.add quote do:
      keepAt(`name`, addr `v`)

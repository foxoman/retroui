## Undo and redo for an app's own changes, as FOX's undo list and Qt's undo
## stack keep them: each change the app makes is recorded with what undoes
## it and what does it again; the Edit menu says what Undo will undo
## ("Undo Typing"), keystrokes in a row are one step, and the stack knows
## whether there are changes not saved (for "Save changes?").
##
## .. code-block:: nim
##   var doc = Doc(title: "Untitled")
##   var history: UndoStack
##
##   app "Notes", 400, 200:
##     menubar:
##       menu "&Edit": undoMenuItems(history)
##     let before = doc
##     if edit(doc.title):                  # the app changed it: recorded
##       history.record("Typing", doc, before, merge = "title")
##     undoKeys(history)                    # Ctrl+Z, Ctrl+Y, Ctrl+Shift+Z
##     if history.changed: label "Not saved"
##     if button("&Save"): save(doc); history.markClean()
##
## `record` keeps copies of the value before and after (simple, for values
## that are not big); `did` takes the two procs that undo and redo a change
## (for a big document: only what changed). A value `record`ed must outlive
## the stack: a global, or a field of one.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import core, widgets, desktop

type
  UndoStep = object
    label: string
    undo, redo: proc () {.closure.}
    merge: string
    at: int

  UndoStack* = object
    ## The changes made, the ones undone after them, and where the document
    ## was saved.
    steps: seq[UndoStep]
    pos: int                  # (the steps before it are done)
    cleanAt: int              # (`pos` when saved; -1: that state is gone)
    limit*: int               ## the most steps kept (0: 200)
    mergeMs*: int             ## steps of one `merge` key this close are one (0: 1500 ms)
    revision*: int            ## goes up with every change, Undo and Redo: an app that
                              ## saves as it goes compares it with the one it saved

proc did*(u: var UndoStack; label: string; undo, redo: proc () {.closure.};
          merge = "") =
  ## Records a change the app has just made: `label` names it ("Typing",
  ## "Delete Row"), `undo` takes it back, `redo` makes it again. With a
  ## `merge` key, a change right after another of the same key (within
  ## `mergeMs`) joins it: one Undo takes back the whole run. What was undone
  ## and not redone is dropped.
  inc u.revision
  if u.pos < u.steps.len:
    u.steps.setLen(u.pos)
    if u.cleanAt > u.pos: u.cleanAt = -1      # (the saved state is gone)
  let now = ui.now
  let within = if u.mergeMs > 0: u.mergeMs else: 1500
  if merge.len > 0 and u.pos > 0 and u.cleanAt != u.pos and
     u.steps[u.pos - 1].merge == merge and now - u.steps[u.pos - 1].at <= within:
    # (the first step's undo stays: it goes back to before the whole run)
    u.steps[u.pos - 1].redo = redo
    u.steps[u.pos - 1].at = now
    return
  u.steps.add UndoStep(label: label, undo: undo, redo: redo, merge: merge, at: now)
  inc u.pos
  let most = if u.limit > 0: u.limit else: 200
  if u.steps.len > most:
    let cut = u.steps.len - most
    u.steps = u.steps[cut .. ^1]
    u.pos -= cut
    u.cleanAt = if u.cleanAt >= cut: u.cleanAt - cut else: -1

proc record*[T](u: var UndoStack; label: string; v: var T; before: T; merge = "") =
  ## Records that `v` changed from `before` to what it is now (copies of
  ## both are kept): Undo puts `before` back, Redo the value now.
  let p = addr v
  let after = v
  u.did(label, proc () = p[] = before, proc () = p[] = after, merge)

proc canUndo*(u: UndoStack): bool = u.pos > 0
  ## There is a change to undo.
proc canRedo*(u: UndoStack): bool = u.pos < u.steps.len
  ## There is an undone change to make again.

proc undoLabel*(u: UndoStack): string =
  ## What Undo will take back ("Typing"; "" when nothing).
  if u.pos > 0: u.steps[u.pos - 1].label else: ""

proc redoLabel*(u: UndoStack): string =
  ## What Redo will make again ("" when nothing).
  if u.pos < u.steps.len: u.steps[u.pos].label else: ""

proc undo*(u: var UndoStack): bool {.discardable.} =
  ## Takes the last change back; false when there was none.
  if u.pos == 0: return false
  dec u.pos
  u.steps[u.pos].undo()
  inc u.revision
  ui.redraw = true
  true

proc redo*(u: var UndoStack): bool {.discardable.} =
  ## Makes the last undone change again; false when there was none.
  if u.pos >= u.steps.len: return false
  u.steps[u.pos].redo()
  inc u.pos
  inc u.revision
  ui.redraw = true
  true

proc markClean*(u: var UndoStack) =
  ## The document is saved as it is now: `changed` is false until the next
  ## change (or an Undo or Redo away from here).
  u.cleanAt = u.pos

proc changed*(u: UndoStack): bool =
  ## There are changes since the document was saved (or opened: a new
  ## stack starts clean).
  u.pos != u.cleanAt

proc clear*(u: var UndoStack) =
  ## Forgets every change (a document opened anew); clean.
  u.steps.setLen(0)
  u.pos = 0
  u.cleanAt = 0

proc undoMenuItems*(u: var UndoStack; keys = true) =
  ## The Edit menu's Undo and Redo, named by what they do ("&Undo Typing",
  ## "&Redo Typing"), grayed when there is nothing; with `keys`, their
  ## shortcuts shown (`undoKeys` presses them).
  let ul = u.undoLabel
  let rl = u.redoLabel
  if menuItem(tr("&Undo") & (if ul.len > 0: " " & tr(ul) else: ""),
              if keys: "Ctrl+Z" else: "", enabled = ul.len > 0): u.undo()
  if menuItem(tr("&Redo") & (if rl.len > 0: " " & tr(rl) else: ""),
              if keys: "Ctrl+Y" else: "", enabled = rl.len > 0): u.redo()

proc undoKeys*(u: var UndoStack) =
  ## Ctrl+Z undoes, Ctrl+Y and Ctrl+Shift+Z redo (Cmd on a Mac) -- when the
  ## keyboard is not in a text box, which undoes its own typing first.
  if hotkeyPressed("Ctrl+Z"): u.undo()
  if hotkeyPressed("Ctrl+Y") or hotkeyPressed("Ctrl+Shift+Z"): u.redo()

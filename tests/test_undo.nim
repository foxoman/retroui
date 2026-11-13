## Tests of retroui/undo: changes recorded, merged while typing, undone and
## redone by name, the saved state, and Ctrl+Z / Ctrl+Y.

import harness, retroui
import retroui/uirelays/input

fakeDriver()
startApp("t", W, H)

type Doc = object
  title: string
  rows: seq[int]

var doc = Doc(title: "a")
var u: UndoStack
view = proc () = undoKeys(u)
run()

block record:
  var before = doc
  doc.title = "ab"
  u.record("Typing", doc, before, merge = "title")
  before = doc
  doc.title = "abc"
  u.record("Typing", doc, before, merge = "title")     # (joins the step before)
  before = doc
  doc.rows.add 1
  u.record("Add Row", doc, before)
  doAssert u.canUndo and not u.canRedo and u.undoLabel == "Add Row"
  doAssert u.changed
  u.undo()
  doAssert doc.rows.len == 0 and doc.title == "abc" and u.redoLabel == "Add Row"
  u.undo()
  doAssert doc.title == "a", doc.title                   # (the run of typing at once)
  doAssert not u.canUndo and not u.changed
  u.redo()
  doAssert doc.title == "abc"
  let r = u.revision
  u.redo()
  doAssert doc.rows == @[1] and u.revision == r + 1

block clean:
  u.markClean()
  doAssert not u.changed
  u.undo()
  doAssert u.changed
  u.redo()
  doAssert not u.changed
  # a new change after an undo drops what was undone
  u.undo()
  let before = doc
  doc.title = "z"
  u.record("Rename", doc, before)
  doAssert not u.canRedo and u.changed        # (the saved state is gone)

block keys:
  u.clear()
  var n = 0
  u.did("Count", (proc () = dec n), (proc () = inc n))
  inc n
  key(KeyZ, {CtrlPressed}); run()
  doAssert n == 0
  key(KeyY, {CtrlPressed}); run()
  doAssert n == 1
  key(KeyZ, {CtrlPressed}); run()
  key(KeyZ, {CtrlPressed, ShiftPressed}); run()
  doAssert n == 1

block limit:
  var v = 0
  var s = UndoStack(limit: 5)
  for i in 1 .. 10:
    let before = v
    v = i
    s.record("Set", v, before)
  var undone = 0
  while s.undo(): inc undone
  doAssert undone == 5 and v == 5, $(undone, v)

echo "undo OK"

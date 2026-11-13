## Tests of `codeEdit`: typing with the indent kept, Tab and Shift+Tab,
## Ctrl+/ comments, its own undo, read only, the colors of Nim's words.

import std/strutils
import harness, retroui
import retroui/uirelays/input

fakeDriver()
startApp("t", W, H)

var code = "proc f() =\n  discard\n"
var box: Rect
var ro = false
var changed = 0
view = proc () =
  if codeEdit(code, lines = 8, readOnly = ro): inc changed
  box = ui.lastRect
run(2)

block typing:
  click(box, dx = 60, dy = 6)              # (into the first line)
  key(KeyEnd)
  key(KeyEnter)
  typeText("x")
  run()
  doAssert code.startsWith("proc f() =\n  x\n"), code   # (after "=": indented)
  doAssert changed > 0

block undo:
  key(KeyZ, {CtrlPressed}); run()
  doAssert code == "proc f() =\n  discard\n", code
  key(KeyY, {CtrlPressed}); run()
  doAssert code.startsWith("proc f() =\n  x\n"), code

block comment:
  key(KeyHome, {CtrlPressed})
  key(KeySlash, {CtrlPressed}); run()
  doAssert code.startsWith("# proc f() ="), code
  key(KeySlash, {CtrlPressed}); run()
  doAssert code.startsWith("proc f() ="), code

block indent:
  key(KeyHome, {CtrlPressed})
  key(KeyTab); run()
  doAssert code.startsWith("  proc f()"), code
  key(KeyTab, {ShiftPressed}); run()
  doAssert code.startsWith("proc f()"), code

block readOnly:
  ro = true
  let before = code
  typeText("zz")
  key(KeyEnter)
  run()
  doAssert code == before

block colors:
  # (the keyword "proc" is drawn in its own color: not the text's black)
  var colored = false
  for y in box.y + 2 ..< box.y + 20:
    for x in box.x + 30 ..< box.x + 80:
      let c = px(x, y)
      if c != 0xFFFFFF'u32 and c != 0 and (c and 0xFF) > (c shr 16 and 0xFF) + 40: colored = true
  doAssert colored

echo "codeedit OK"

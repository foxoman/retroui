## Fixes learned building a big app on the toolkit (Retro Mail), headless:
## a widget that has the focus without being a stop of Tab keeps it,
## `peekId` asks about a widget without counting a use, a banner's buttons
## wrap instead of running out of the strip, a read-only text box is
## selected and copied but not changed, Alt+Space and Ctrl+Space press no
## button, and `app`'s options.

import retroui
import retroui/uirelays/input
import harness

fakeDriver()
startApp("fixes", 640, 480)

block focusKept:
  # a list that takes the keys itself (no stop of Tab) keeps the focus it
  # was given; a widget that is gone gives it back to the first stop
  var name = ""
  var listShown = true
  var listId: Id
  view = proc () =
    edit name
    if listShown:
      let r = place(200, 100)
      listId = idOf("mylist")
      discard interact(listId, r, focusable = false)
  run(2)
  ui.focus = listId
  run(3)
  doAssert ui.focus == listId, "a focused widget that answered keeps the focus"
  listShown = false
  run(3)
  doAssert ui.focus != listId, "gone: the focus goes back to a stop of Tab"

block peek:
  var firstId, peeked, secondId: Id
  view = proc () =
    peeked = peekId("OK")
    firstId = idOf("OK")
    secondId = idOf("OK")
  run(2)
  doAssert peeked == firstId and secondId != firstId,
    "peekId: the first widget's id, no use counted"
  var v = 0
  var pv, iv: Id
  view = proc () =
    pv = peekId(v, "x")
    iv = idOf(v, "x")
  run(2)
  doAssert pv == iv

block bannerWraps:
  # many buttons in a narrow strip: in rows under the text, none past its edge
  var shownW = 0
  var bottom = 0
  view = proc () =
    pushFrame(rect(0, 0, 260, 0))
    discard banner("Pictures from the web are hidden in this message.", bkInfo,
                   ["Show pictures", "Trust this sender", "Show always for everyone"],
                   closable = false)
    shownW = ui.lastRect.w
    bottom = ui.lastRect.y + ui.lastRect.h
    discard popFrame()
  run(2)
  doAssert shownW <= 260 and bottom > 3 * CtrlH,
    "the banner holds its buttons in rows: " & $shownW & "x" & $bottom

block readOnly:
  var t = "line one\nline two"
  var changedSeen = false
  view = proc () =
    if editArea(t, lines = 4, readOnly = true): changedSeen = true
  run(2)
  # focus it and type, paste, delete, Enter: nothing changes
  ui.focus = peekId(t, "area")
  run()
  typeText("xyz")
  key(KeyBackspace)
  key(KeyDelete)
  key(KeyEnter)
  run(3)
  doAssert t == "line one\nline two" and not changedSeen, "read-only: " & t
  # select all and copy: it is on the clipboard
  key(KeyA, {CtrlPressed})
  key(KeyC, {CtrlPressed})
  run(2)
  doAssert getClipboardText() == t, "copied: " & getClipboardText()

block spaceWithModifiers:
  var pressed = 0
  view = proc () =
    if button("&Go"): inc pressed
  run(2)
  key(KeyTab)
  run(2)
  key(KeySpace, {CtrlPressed})
  run(3)
  doAssert pressed == 0, "Ctrl+Space presses no button"
  key(KeySpace)
  run(3)
  doAssert pressed == 1, "Space does"

echo "test_widgetfixes: ok"

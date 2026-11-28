## The phone behaviors the interface guidelines (docs/hig.md) ask for: a list's edit mode (the
## red minus, its Delete, a row dragged by its grip to another place), a scope bar, a modal sheet
## with Cancel and Done (the whole screen on a phone, a sheet in the middle on a tablet), badges
## on the tab bar, an action sheet coming out of the button that opened it, a tap on the title
## (or the status bar) taking the page back to its top; a to-do's check rows edited as other rows.

import std/strutils
import retroui
import retroui/uirelays/[coords, screen, input]
import retroui/inspect
import harness

var wide = false
fakeDriver()
windowRelays.getWindowLayout = proc (): ScreenLayout =
  if wide: ScreenLayout(width: W, height: H, scaleX: 1, scaleY: 1, uiScale: 100, touch: true)
  else: ScreenLayout(width: 360, height: H, scaleX: 1, scaleY: 1, uiScale: 100, touch: true)
startApp("HIG phone", 360, H)
uiLook = lookGloss
accessKeep = true

var passed = 0
template check(cond: bool; what: string) =
  doAssert cond, what
  inc passed
  echo "  ok   ", what

proc node(name: string; roles: set[AccessRole] = {}): int =
  result = -1
  for i, nd in accessLast:
    if (roles.len == 0 or nd.role in roles) and nd.name.replace("&", "") == name: return i

proc nodeAt(name: string; roles: set[AccessRole] = {}): Rect =
  let n = node(name, roles)
  doAssert n >= 0, "no " & name & " on the screen"
  nodeRect(accessLast[n])

proc tap(r: Rect) = click(r, dx = r.w div 2)

block editMode:
  var items = @["Milk", "Bread", "Eggs", "Tea"]
  var editing = false
  view = proc () =
    if navBar("Groceries", action = if editing: "Done" else: "Edit") == npAction:
      editing = not editing
    editTableGroup("Today", editing):
      var gone = -1
      for i, it in items:
        if tableRow(it, accessory = taChevron).deleted: gone = i
      if gone >= 0: items.delete(gone)
    let m = tableMoved()
    if m.moved:
      let it = items[m.a]
      items.delete(m.a)
      items.insert(it, m.b)
  run(2)
  check node("Remove Milk", {arButton}) < 0, "out of edit mode: no minus"
  tap(nodeAt("Edit", {arButton}))
  run(2)
  check editing and node("Remove Milk", {arButton}) >= 0, "Edit: a red minus before each row"
  tap(nodeAt("Remove Bread", {arButton}))
  run(2)
  check node("Delete Bread", {arButton}) >= 0, "the minus tapped: its Delete at the row's end"
  tap(nodeAt("Delete Bread", {arButton}))
  run(2)
  check items == @["Milk", "Eggs", "Tea"], "Delete tapped: the row is gone (" & $items & ")"
  # (the grip of the first row, dragged down past the third)
  let first = nodeAt("Milk")
  let gx = first.x + first.w - 20
  down(gx, first.y + first.h div 2)
  run(1)
  for k in 1 .. 6:
    move(gx, first.y + first.h div 2 + k * first.h * 2 div 5)
    run(1)
  up(gx, first.y + first.h div 2 + first.h * 12 div 5)
  run(2)
  check items == @["Eggs", "Tea", "Milk"], "a row dragged by its grip to another place (" & $items & ")"
  tap(nodeAt("Done", {arButton}))
  run(2)
  check not editing and node("Remove Milk", {arButton}) < 0, "Done: out of edit mode"

block checkRowsEdited:
  # (a to-do's rows in edit mode: the minus in place of the check, its Delete)
  var todos = @["Call Sami", "Pay rent"]
  var done = @[false, true]
  var editing = true
  view = proc () =
    editTableGroup("To Do", editing):
      var gone = -1
      for i, it in todos:
        if checkRow(it, done[i]).deleted: gone = i
      if gone >= 0:
        todos.delete(gone)
        done.delete(gone)
  run(2)
  check node("Remove Pay rent", {arButton}) >= 0 and node("Call Sami", {arCheckBox}) < 0,
        "a check row in edit mode: a red minus, no check"
  tap(nodeAt("Remove Pay rent", {arButton}))
  run(2)
  tap(nodeAt("Delete Pay rent", {arButton}))
  run(2)
  check todos == @["Call Sami"], "its Delete: the row is gone (" & $todos & ")"
  editing = false
  run(2)
  check node("Call Sami", {arCheckBox}) >= 0, "out of edit mode: its check again"

block scopes:
  var q = ""
  var scope = 0
  view = proc () =
    searchBar(q)
    scopeBar(["All", "Mail", "Contacts"], scope)
  run(2)
  tap(nodeAt("Mail"))
  check scope == 1, "the scope bar picks where to search"

block modalSheets:
  var open = true
  var name = ""
  var answers: seq[SheetAnswer]
  view = proc () =
    label "Calendar"
    let a = modalSheet(open, "New Event"):
      edit(name, hint = "Title")
    if a != shNone: answers.add a
  run(20)
  let bar = nodeAt("Cancel", {arButton})
  check bar.x < 60, "on a phone: Cancel at the start of its bar"
  let d = nodeAt("Done", {arButton})
  check d.x + d.w > 300, "Done at its end: the sheet the whole width"
  tap(bar)
  run(2)
  check not open and answers == @[shCancel], "Cancel: closed, nothing kept"
  open = true
  run(20)
  tap(nodeAt("Done", {arButton}))
  run(2)
  check not open and answers[^1] == shDone, "Done: closed, what is in it taken"
  wide = true
  open = true
  run(20)
  let c2 = nodeAt("Cancel", {arButton})
  check c2.x > 40, "on a tablet: a sheet in the middle of the window (" & $c2.x & ")"
  down(5, H - 5)
  run(1)
  up(5, H - 5)
  run(2)
  check open, "a tap beside it doesn't close it"
  key(KeyEsc)
  run(2)
  check not open and answers[^1] == shCancel, "Esc is Cancel"
  wide = false
  run(2)

block badges:
  var tab = 0
  view = proc () =
    bottomNav([(nfHome, "Home"), (nfEnvelope, "Mail"), (nfCog, "Settings")], tab, ["", "3", ""])
    label "content"
  run(2)
  check node("Mail, 3", {arTab}) >= 0, "a badge on a place: read with it"

block anchoredSheet:
  wide = true
  var open = false
  var picked = -2
  var share: Rect
  view = proc () =
    if button("Share"): open = true
    share = ui.lastRect
    let a = actionSheet(open, "", ["Copy Link", "Mail", "Delete"], destructive = 2, anchor = share)
    if a != -1: picked = a
  run(2)
  tap(nodeAt("Share", {arButton}))
  run(3)
  let m = nodeAt("Mail", {arButton})
  check m.y > share.y + share.h and m.y < share.y + share.h + 200,
        "it comes out of the button that opened it"
  check node("Cancel", {arButton}) < 0, "... with no Cancel: a tap beside it is Cancel"
  tap(m)
  check picked == 1 and not open, "an action picked"
  wide = false
  run(2)

block toTop:
  var y = 0
  view = proc () =
    discard navBar("Inbox")
    beginPanel(-1, "inbox", plain = true)
    for i in 0 ..< 60: label "Message " & $i
    endPanel()
  run(2)
  let msg = nodeAt("Message 5")
  # (scrolled down: a few notches of the wheel)
  move(180, msg.y + 100)
  for k in 1 .. 4:
    harness.queue.add Event(kind: MouseWheelEvent, y: -1)
    run(2)
  run(30)
  let scrolled = nodeAt("Message 5").y
  check scrolled < msg.y - 100, "scrolled down (" & $scrolled & ")"
  tap(nodeAt("Inbox", {arHeading}))
  run(40)
  check nodeAt("Message 5").y == msg.y, "a tap on the title: back at the top"

echo passed, " passed"

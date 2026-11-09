## The business controls of retroui/records: masked fields, the record
## navigator, two lists, date ranges, the property grid, the tree grid and
## wizards -- by mouse, keyboard and finger, headless.

import std/unicode
import retroui
import retroui/records
import retroui/uirelays/input
import harness

fakeDriver()
startApp("records", W, H)

proc tap(x, y: int) =
  down(x, y)
  run()
  up(x, y)
  run()

proc typeRunes(s: string) =
  ## Text as a keyboard sends it: one event per character (any UTF-8).
  for r in s.runes:
    let u = r.toUTF8
    queue.add Event(kind: KeyDownEvent, key: KeyNone)
    var e = Event(kind: TextInputEvent)
    for i, c in u: e.text[i] = c
    queue.add e

# ---- masks ---------------------------------------------------------------------------------------

block maskHelpers:
  doAssert maskFormat("96891234567", "+### #### ####") == "+968 9123 4567"
  doAssert maskFormat("968", "+### #### ####") == "+968 ____ ____"
  doAssert maskSlotCount("(###) ###-####") == 10
  doAssert maskFull("1234567890", "(###) ###-####")
  doAssert not maskFull("12345", "(###) ###-####")
  doAssert not maskFull("12345abcde", "(###) ###-####")
  doAssert maskRaw("(968) 912-3456", "(###) ###-####") == "9689123456"
  doAssert maskRaw("ab-1234", "UU-####") == "AB1234", "U makes letters upper case"
  doAssert maskFormat("x", "\\#X") == "#x", "a backslash takes the next one as it is"
  doAssert maskFormat("", "") == ""

block maskedTyping:
  var phone = ""
  var r: Rect
  view = proc () =
    maskedEdit(phone, "+### ####-####")
    r = ui.lastRect
  run(2)
  tap(r.x + 5, r.y + r.h div 2)
  typeText("968a9")            # the letter does not fit a digit slot
  run()
  doAssert phone == "9689", phone
  typeRunes("١٢٣")             # Arabic-Indic digits are digits
  run()
  doAssert phone == "9689123", phone
  key(KeyBackspace)
  run()
  doAssert phone == "968912"
  key(KeyHome)
  run()
  key(KeyDelete)
  run()
  doAssert phone == "68912", "Delete at the start: " & phone
  putClipboardText("+968 9999-0000")
  key(KeyEnd)
  run()
  key(KeyV, {CtrlPressed})
  run()
  doAssert phone.len == 11 and maskFull(phone, "+### ####-####"), phone
  key(KeyC, {CtrlPressed})
  run()
  doAssert getClipboardText() == maskFormat(phone, "+### ####-####")
  # typed over in the middle
  key(KeyHome)
  run()
  typeText("1")
  run()
  doAssert phone[0] == '1' and phone.len == 11, phone

# ---- the record navigator --------------------------------------------------------------------

block navigator:
  var pos = 0
  var dirty = false
  var last = raNone
  view = proc () =
    let a = recordNav(pos, 20, dirty)
    if a != raNone: last = a
  run(2)
  key(KeyEnd, {CtrlPressed})
  run()
  doAssert pos == 19 and last == raLast
  key(KeyPageUp, {CtrlPressed})
  run()
  doAssert pos == 18 and last == raPrev
  key(KeyHome, {CtrlPressed})
  run()
  doAssert pos == 0 and last == raFirst
  # the record number typed (the box is the first to take the focus)
  ui.focus = 0
  run(2)
  key(KeyA, {CtrlPressed})
  run()
  typeText("7")
  run()
  doAssert pos == 6 and last == raGoto, $pos
  # New, then Save and Cancel while it is dirty
  last = raNone
  key(KeyN, {AltPressed})
  run(2)
  doAssert last == raNew
  dirty = true
  run(2)
  key(KeyS, {AltPressed})
  run(2)
  doAssert last == raSave
  # the first record: back buttons do nothing
  pos = 0
  last = raNone
  key(KeyPageUp, {CtrlPressed})
  run()
  doAssert last == raNone and pos == 0

# ---- two lists -----------------------------------------------------------------------------------

block twoLists:
  var avail = @["Cash", "Bank", "Sales", "Rent"]
  var chosen: seq[string]
  var changes = 0
  view = proc () =
    if dualList(avail, chosen, rows = 5): inc changes
  run(2)
  ui.focus = 0
  run(2)                      # the left list takes the focus
  key(KeyEnter)               # moves its item across
  run(2)
  doAssert chosen == @["Cash"] and avail.len == 3 and changes == 1, $chosen
  key(KeyTab)                 # >
  run()
  key(KeySpace)
  queue.add Event(kind: KeyUpEvent, key: KeySpace)
  run(2)
  doAssert chosen.len == 2, $chosen
  key(KeyTab)                 # >>
  run()
  key(KeySpace)
  queue.add Event(kind: KeyUpEvent, key: KeySpace)
  run(2)
  doAssert avail.len == 0 and chosen.len == 4
  key(KeyTab)                 # <
  run()
  key(KeySpace)
  queue.add Event(kind: KeyUpEvent, key: KeySpace)
  run(2)
  doAssert avail.len == 1 and chosen.len == 3
  key(KeyTab)                 # <<
  run()
  key(KeySpace)
  queue.add Event(kind: KeyUpEvent, key: KeySpace)
  run(2)
  doAssert chosen.len == 0 and avail == @["Bank", "Cash", "Rent", "Sales"], $avail

# ---- date ranges ---------------------------------------------------------------------------------

block ranges:
  let d = date(2026, 10, 27)                  # a Tuesday
  firstWeekday = 0
  doAssert presetRange(rpThisMonth, d) == (date(2026, 10, 1), date(2026, 10, 31))
  doAssert presetRange(rpLastMonth, d) == (date(2026, 9, 1), date(2026, 9, 30))
  doAssert presetRange(rpThisQuarter, d) == (date(2026, 10, 1), date(2026, 12, 31))
  doAssert presetRange(rpLastQuarter, d) == (date(2026, 7, 1), date(2026, 9, 30))
  doAssert presetRange(rpThisWeek, d) == (date(2026, 10, 25), date(2026, 10, 31))
  doAssert presetRange(rpLastYear, d) == (date(2025, 1, 1), date(2025, 12, 31))
  doAssert presetRange(rpLast7, d) == (date(2026, 10, 21), d)
  doAssert presetRange(rpLastMonth, date(2026, 1, 15)) == (date(2025, 12, 1), date(2025, 12, 31))
  var a = date(2026, 5, 10)
  var b = date(2026, 5, 1)                    # before a: put right
  view = proc () = dateRange(a, b)
  run(3)
  doAssert dayNumber(b) >= dayNumber(a)
  # a preset chosen from the list
  ui.focus = 0
  run(2)                      # the list of periods takes the focus
  key(KeyDown)
  run(2)
  doAssert a == today() and b == today(), "the first preset after Custom: Today"

# ---- the property grid -------------------------------------------------------------------------

block properties:
  var props = @[
    textProp("Name", "Main store", "General", "What the store is called"),
    boolProp("Active", true, "General"),
    choiceProp("Region", ["North", "South", "East"], 1, "General"),
    numberProp("Budget", 1500.5, 2, "Money"),
    intProp("Staff", 12, "Money"),
    colorProp("Label color", color(0, 128, 0), "Look"),
    infoProp("Created", "2026-10-27", "Look")]
  var sel = 0
  var changed = -1
  var r: Rect
  view = proc () =
    let c = propertyGrid(props, sel, height = 300)
    if c >= 0: changed = c
    r = ui.lastRect
  run(3)
  let rh = max(ItemH + 4, EditH)
  let lineY = proc (k: int): int = r.y + 1 + k * rh + rh div 2
  let valueX = r.x + 1 + dp(14) + (r.w - 2) * 2 div 5 + dp(20)
  # lines: General, Name, Active, Region, Money, Budget, Staff, Look, Label color, Created
  tap(valueX, lineY(2))                       # Active's check box
  doAssert not props[1].on and changed == 1, "a click flips a yes / no"
  key(KeySpace)
  run()
  doAssert props[1].on
  # typing edits the chosen text
  tap(r.x + 30, lineY(1))
  doAssert sel == 0
  key(KeyEnter)
  run()
  key(KeyA, {CtrlPressed})
  run()
  typeText("Store 7")
  run()
  key(KeyEnter)
  run()
  doAssert props[0].text == "Store 7", props[0].text
  # Down moves over the category lines
  key(KeyDown)
  run()
  key(KeyDown)
  run()
  key(KeyDown)
  run()
  doAssert sel == 3, $sel
  # a number typed
  key(KeyEnter)
  run()
  key(KeyA, {CtrlPressed})
  run()
  typeText("2,250.75")
  run()
  key(KeyEnter)
  run()
  doAssert props[3].num == 2250.75, $props[3].num
  # the choice dropped down, the last one picked
  sel = 2
  run(2)
  ui.focus = 0
  tap(r.x + 30, lineY(3))
  key(KeyF4)
  run(2)
  key(KeyDown)
  run()
  key(KeyDown)
  run()
  key(KeyDown)
  run()
  key(KeyEnter)
  run(2)
  doAssert props[2].n == 2, $props[2].n
  # a category folds away
  tap(r.x + 5, lineY(0))
  run()
  tap(r.x + 30, lineY(2))                     # General, Money, then Budget
  doAssert sel == 3, "General folded: Budget is the second line now " & $sel
  # read-only lines are not edited
  sel = 6
  run()
  key(KeyEnter)
  run()
  typeText("x")
  run()
  doAssert props[6].text == "2026-10-27"

# ---- the tree grid -------------------------------------------------------------------------------

block treeColumns:
  var cols = @[column("Account", 200), numberColumn("Balance", 100)]
  var rows = @[
    TreeRow(level: 0, cells: @["Assets", "15,000"], open: true),
    TreeRow(level: 1, cells: @["Cash", "5,000"]),
    TreeRow(level: 1, cells: @["Bank", "10,000"], open: false),
    TreeRow(level: 2, cells: @["Current account", "7,000"]),
    TreeRow(level: 2, cells: @["Savings", "3,000"]),
    TreeRow(level: 0, cells: @["Liabilities", "4,000"], open: false),
    TreeRow(level: 1, cells: @["Loans", "4,000"])]
  var sel = 0
  var ev: TreeGridEvent
  var r: Rect
  view = proc () =
    let e = treeGrid(cols, rows, sel, height = 8)
    if e.toggled or e.activated or e.selChanged: ev = e
    r = ui.lastRect
  run(2)
  let rowH = ItemH + 2
  let hdrH = ItemH + 4
  tap(r.x + 60, r.y + 1 + hdrH + rowH div 2)  # select Assets (and take the focus)
  key(KeyDown)
  run()
  key(KeyDown)
  run()
  doAssert sel == 2, "the closed Bank: its rows are not shown " & $sel
  key(KeyRight)
  run()
  doAssert rows[2].open and ev.toggled
  key(KeyDown)
  run()
  doAssert sel == 3
  key(KeyLeft)
  run()
  doAssert sel == 2, "Left goes to the parent"
  key(KeyLeft)
  run()
  doAssert not rows[2].open
  key(KeyDown)
  run()
  doAssert sel == 5, "Liabilities next (Bank closed) " & $sel
  # the [+] box opens with a click
  let y = r.y + 1 + hdrH + 3 * rowH + rowH div 2
  tap(r.x + 1 + dp(8), y)
  doAssert rows[5].open, "a click on the box opens"
  key(KeyEnd)
  run()
  doAssert sel == 6
  key(KeyEnter)
  run()
  doAssert ev.activated and ev.row == 6
  # an empty tree is fine
  rows.setLen(0)
  run(2)

# ---- wizards ---------------------------------------------------------------------------------------

block wizards:
  var open = true
  var step = 0
  var name = ""
  var act = waNone
  view = proc () =
    let a = wizard(open, "New company", step, ["Name", "Address", "Done"], 480):
      case step
      of 0:
        label "&Company name:"
        edit name
        stepDone(name.len > 0)
      of 1: label "Where is it?"
      else: label "Ready."
    if a != waNone: act = a
  run(3)
  key(KeyEnter)                       # Next is disabled while the name is empty
  run(2)
  doAssert step == 0
  ui.focus = 0
  run(2)                              # the name box takes the focus
  typeText("Acme")
  run()
  ui.focus = 0
  run()
  key(KeyN, {AltPressed})
  run(2)
  doAssert step == 1 and act == waNext, $step
  key(KeyB, {AltPressed})
  run(2)
  doAssert step == 0 and act == waBack
  key(KeyN, {AltPressed})
  run(2)
  key(KeyN, {AltPressed})
  run(2)
  doAssert step == 2
  key(KeyF, {AltPressed})
  run(2)
  doAssert act == waFinish and not open
  # Esc cancels
  open = true
  step = 1
  act = waNone
  run(2)
  key(KeyEsc)
  run(2)
  doAssert act == waCancel and not open

echo "records tests passed"

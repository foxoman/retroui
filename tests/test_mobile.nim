## Tests of the controls from phones (retroui/mobile): the navigation bar, wheel pickers (a
## day, a time), a number with - and +, page dots, rows with actions behind them, the action
## sheet, the bottom sheet, the popover -- by the mouse, the keys and a screen reader's
## value; in every look.

import retroui
import retroui/uirelays/[coords, input]
import harness

fakeDriver()
startApp("mobile", W, H)

proc wheelNotch(r: Rect; notches: int) =
  queue.add Event(kind: MouseMoveEvent, x: r.x + r.w div 2, y: r.y + r.h div 2)
  queue.add Event(kind: MouseWheelEvent, y: notches)
  run(2)

proc rightClick(r: Rect) =
  queue.add Event(kind: MouseDownEvent, x: r.x + 20, y: r.y + r.h div 2, button: RightButton)
  queue.add Event(kind: MouseUpEvent, x: r.x + 20, y: r.y + r.h div 2, button: RightButton)
  run(2)

# ---- the navigation bar: Back, the action, Alt+Left ------------------------------------------

var navR: Rect
var picked: NavPick
var backs, actions = 0
view = proc () =
  picked = navBar("Settings", back = "Home", action = "Edit")
  navR = ui.lastRect
  if picked == npBack: inc backs
  if picked == npAction: inc actions
run(2)
doAssert navR.w > W div 2 and navR.h >= 24
click(navR, dx = 20)
doAssert backs == 1 and actions == 0, "Back: at its start"
click(navR, dx = navR.w - 20)
doAssert actions == 1, "the action: at its end"
key(KeyLeft, {AltPressed})
run(2)
doAssert backs == 2, "Alt+Left: Back"
# no Back: its start does nothing
view = proc () =
  picked = navBar("Home")
  navR = ui.lastRect
  if picked != npNone: inc backs
run(2)
click(navR, dx = 20)
key(KeyLeft, {AltPressed})
run(2)
doAssert backs == 2

# ---- a wheel picker: the keys, a click, the wheel, a letter, a fling -----------------------------

let sizes = ["Small", "Medium", "Large", "Family", "Party", "Giant"]
var size = 1
var wr: Rect
var changes = 0
view = proc () =
  if wheelPicker(sizes, size, label = "Size"): inc changes
  wr = ui.lastRect
run(2)
doAssert wr.h >= 5 * (ItemH + 6), "five rows"
click(wr, dx = wr.w div 2)                       # (the band: the one chosen, as it was)
doAssert size == 1 and changes == 0
key(KeyDown)
run(20)
doAssert size == 2 and changes == 1, "Down: the next"
key(KeyEnd)
run(20)
doAssert size == 5
key(KeyHome)
run(20)
doAssert size == 0
key(KeyUp)
run(20)
doAssert size == 0, "no row before the first"
typeText("f")
run(20)
doAssert size == 3, "a letter: the next item that starts with it"
# a click on the row under the band: it comes to the band
click(wr, dx = wr.w div 2, dy = wr.h div 2 + wheelRowH())
run(30)
doAssert size == 4, "a click a row below: that row " & $size
wheelNotch(wr, 1)
run(30)
doAssert size == 3, "the wheel up: the one before"
# dragged up two rows and let go slowly: two rows on
let cx = wr.x + wr.w div 2
let cy = wr.y + wr.h div 2
size = 1
run(3)
down(cx, cy)
run(1)
for k in 1 .. 8:
  move(cx, cy - k * wheelRowH() div 4)
  run(1)
ticks += 400                                     # (held still before letting go: no fling)
move(cx, cy - 2 * wheelRowH())
run(1)
up(cx, cy - 2 * wheelRowH())
run(40)
doAssert size == 3, "dragged two rows up: two on " & $size
# flung: it spins on and stops on a row
down(cx, cy + 2 * wheelRowH())
run(1)
for k in 1 .. 4:
  move(cx, cy + 2 * wheelRowH() - k * wheelRowH())
  run(1)
up(cx, cy - 2 * wheelRowH())
run(120)
doAssert size in 0 .. sizes.high, "a fling stops on a row"
doAssert size == sizes.high, "flung up hard: to the end " & $size
# the app sets it
size = 2
run(3)
doAssert size == 2
# a long wheel made as it shows
var year = 26
var yr: Rect
view = proc () =
  wheelPicker(200, proc (i: int): string = $(2000 + i), year, w = 80, key = "year")
  yr = ui.lastRect
run(2)
click(yr, dx = 20)
key(KeyPageDown)
run(30)
doAssert year == 30, "Page Down: a wheel's rows less one"

# ---- the day and the time ---------------------------------------------------------------------

var day = date(2026, 1, 31)
var yearR: Rect
view = proc () =
  dateWheels(day)
  yearR = ui.lastRect                          # (the year's: the last of day, month, year)
run(2)
dateStyle = dsDMY
click(rect(yearR.x - Gap - 24, yearR.y, 4, yearR.h), dx = 0)   # (the month's band: chosen as it is)
doAssert day == date(2026, 1, 31)
key(KeyDown)                                   # (the month: February)
run(30)
doAssert day == date(2026, 2, 28), "31 January to February: its last day " & $day
var h = 14
var m = 30
var ampmR: Rect
view = proc () =
  timeWheels(h, m, minuteStep = 15, hours12 = true)
  ampmR = ui.lastRect
run(2)
click(rect(ampmR.x - 2 * Gap - 2 * (textWidth("00") + dp(30)) + 10, ampmR.y, 4, ampmR.h), dx = 0)
doAssert h == 14 and m == 30
key(KeyDown)                                   # (the hour: 3 PM)
run(30)
doAssert h == 15 and m == 30, $h
key(KeyTab)
run(2)
key(KeyDown)
run(30)
doAssert m == 45, "15 minutes a row"
key(KeyTab)
run(2)
key(KeyUp)
run(30)
doAssert h == 3, "AM: twelve hours back " & $h

# ---- a number with - and + ---------------------------------------------------------------------

var cups = 3
var qr: Rect
view = proc () =
  quantity(cups, 1, 6, label = "Cups")
  qr = ui.lastRect
run(2)
click(qr, dx = qr.w - 8)
doAssert cups == 4, "+"
click(qr, dx = 8)
doAssert cups == 3, "-"
# held: on, a step every 80 ms after 400
down(qr.x + qr.w - 8, qr.y + qr.h div 2)
run(1)
for k in 1 .. 40: run(1)
up(qr.x + qr.w - 8, qr.y + qr.h div 2)
run(2)
doAssert cups == 6, "held: up to its top " & $cups
click(qr, dx = qr.w - 8)
doAssert cups == 6, "no more than its top"
key(KeyDown)
run(2)
doAssert cups == 5, "focused by the click: the keys"
key(KeyHome)
run(2)
doAssert cups == 1
typeText("+")
run(2)
doAssert cups == 2
wheelNotch(qr, 1)
doAssert cups == 3

# ---- page dots ---------------------------------------------------------------------------------

var page = 0
var dr: Rect
view = proc () =
  pageDots(page, 5)
  dr = ui.lastRect
run(2)
let gap = dp(14)
let x0 = dr.x + (dr.w - gap * 5) div 2
click(dr, dx = x0 - dr.x + gap * 3 + gap div 2)
doAssert page == 3, "a dot: its page " & $page
click(dr, dx = 4)
doAssert page == 2, "before the dots: the page before"
click(dr, dx = dr.w - 4)
doAssert page == 3, "after them: the page after"
key(KeyRight)
run(2)
doAssert page == 4
key(KeyRight)
run(2)
doAssert page == 4
key(KeyHome)
run(2)
doAssert page == 0

# ---- rows with actions behind them -------------------------------------------------------------

var rows: array[3, Rect]
var hits: array[3, SwipeHit]
var clicks, acts: seq[(int, int)]
view = proc () =
  for i in 0 .. 2:
    hits[i] = swipeRow("Invoice " & $(1042 + i), ["Archive", "Delete"], detail = "Al Noor",
                       key = $i)
    rows[i] = ui.lastRect
    if hits[i].clicked: clicks.add (i, 0)
    if hits[i].action >= 0: acts.add (i, hits[i].action)
run(2)
click(rows[0], dx = 40)
doAssert clicks == @[(0, 0)] and acts.len == 0, "a click: the row"
proc swipe(r: Rect; dx: int) =
  let y = r.y + r.h div 2
  down(r.x + r.w - 20, y)
  run(1)
  for k in 1 .. 8:
    move(r.x + r.w - 20 + dx * k div 8, y)
    run(1)
  up(r.x + r.w - 20 + dx, y)
  run(30)
swipe(rows[1], -200)
doAssert clicks.len == 1, "a swipe is no click"
# its actions at its end: Delete last
click(rows[1], dx = rows[1].w - 20)
doAssert acts == @[(1, 1)], "Delete: " & $acts
run(30)
swipe(rows[1], -200)
click(rows[1], dx = 40)                         # (a tap on the row: they go, no click)
run(30)
doAssert clicks.len == 1 and acts.len == 1
click(rows[1], dx = rows[1].w - 20)             # (hidden again: the row's own click)
doAssert clicks == @[(0, 0), (1, 0)], $clicks
# one at a time
swipe(rows[0], -200)
swipe(rows[2], -200)
click(rows[0], dx = rows[0].w - 20)
doAssert clicks.len == 3 and clicks[2] == (0, 0), "the first's went when the third's came"
run(30)
# the keys: Left shows them, Left and Right go along, Enter picks
click(rows[2], dx = 40)
run(30)
let before = clicks.len
key(KeyLeft)
run(30)
key(KeyEnter)
run(2)
doAssert acts[^1] == (2, 0), "Left, Enter: the first action " & $acts
key(KeyLeft)
run(30)
key(KeyRight)
run(2)
key(KeyEnter)
run(2)
doAssert acts[^1] == (2, 1), "Left, Right, Enter: the second"
key(KeyLeft)
run(10)
key(KeyEsc)
run(30)
key(KeyEnter)
run(2)
doAssert clicks.len == before + 1, "Esc hides them: Enter is the row's again"
# a right click: the actions as a menu
rightClick(rows[0])
key(KeyDown)
run(2)
key(KeyDown)
run(2)
key(KeyEnter)
run(3)
doAssert acts[^1] == (0, 1), "the menu: Delete " & $acts

# ---- the action sheet --------------------------------------------------------------------------

var sheetOpen = false
var choice = -2
var opener: Rect
view = proc () =
  if button("Share"): sheetOpen = true
  opener = ui.lastRect
  let p = actionSheet(sheetOpen, "Order 1042", ["Send by mail", "Print", "Delete order"], destructive = 2)
  if p >= 0: choice = p
run(2)
click(opener)
run(30)
doAssert sheetOpen
# its buttons in the middle of the window (a desktop's): find Print by the pixels? by the keys
key(KeyDown)
run(2)
key(KeyEnter)
run(3)
doAssert choice == 1 and not sheetOpen, "Down, Enter: Print " & $choice
choice = -2
sheetOpen = true
run(30)
key(KeyEsc)
run(3)
doAssert not sheetOpen and choice == -2, "Esc: cancelled"
sheetOpen = true
run(30)
click(rect(2, H - 10, 4, 4), dx = 0)
run(3)
doAssert not sheetOpen and choice == -2, "a click beside it: cancelled"
# on a phone: from the bottom, its Cancel at the bottom
ui.touch = true
sheetOpen = true
run(40)
click(rect(W div 2, H - 30, 4, 4), dx = 0)
run(3)
doAssert not sheetOpen and choice == -2, "Cancel, at the bottom"
ui.touch = false
run(2)

# ---- the bottom sheet and the popover ------------------------------------------------------------

var bottomOpen = false
var paid = false
var inside: Rect
view = proc () =
  if button("Filters"): bottomOpen = true
  opener = ui.lastRect
  bottomSheet(bottomOpen, "Filters"):
    checkbox "&Paid only", paid
    inside = ui.lastRect
run(2)
click(opener)
run(40)
doAssert bottomOpen and inside.y > H div 2, "from the bottom: " & $inside
click(inside, dx = 4)
run(2)
doAssert paid, "its controls work"
# dragged down by its top: it goes
let top = inside.y - 30
down(W div 2, top)
run(1)
for k in 1 .. 6:
  move(W div 2, top + k * 30)
  run(1)
up(W div 2, top + 180)
run(3)
doAssert not bottomOpen, "dragged down: closed"
bottomOpen = true
run(40)
key(KeyEsc)
run(3)
doAssert not bottomOpen

var popOpen = false
var anchor, popInside: Rect
view = proc () =
  if button("Info"): popOpen = true
  anchor = ui.lastRect
  popover(popOpen, anchor, 220):
    label "Saved two minutes ago"
    popInside = ui.lastRect
run(2)
click(anchor)
run(3)
doAssert popOpen and popInside.y > anchor.y + anchor.h, "under what it is for"
doAssert popInside.x < anchor.x + anchor.w + 220
click(rect(W - 20, H - 20, 4, 4), dx = 0)
run(3)
doAssert not popOpen, "a click outside: closed"

# ---- an alert: Enter the last button, Esc its cancel, a tap beside it nothing -------------------------

var alertOpen = false
var answer = -2
view = proc () =
  let a = alertBox(alertOpen, "Delete this order?", "It can't be brought back.", ["Cancel", "Delete"],
                   cancel = 0)
  if a >= 0: answer = a
alertOpen = true
run(30)
key(KeyEnter)
run(3)
doAssert answer == 1 and not alertOpen, "Enter: the last button " & $answer
answer = -2
alertOpen = true
run(30)
click(rect(2, 2, 4, 4), dx = 0)
run(3)
doAssert alertOpen and answer == -2, "a tap beside it: it waits"
key(KeyEsc)
run(3)
doAssert not alertOpen and answer == 0, "Esc: its cancel"
# no cancel: Esc does nothing
var okOnly = true
view = proc () =
  if alertBox(okOnly, "Saved") == 0: answer = 9
run(30)
key(KeyEsc)
run(3)
doAssert okOnly, "no cancel: Esc waits"
key(KeyEnter)
run(3)
doAssert not okOnly and answer == 9

# ---- rows in groups: a row, its info button, a switch, a button -----------------------------------

var rowHit, infoHit, resetHit = 0
var wifi = false
var rowR, switchR, buttonR: Rect
view = proc () =
  tableGroup("Network", "A note under it"):
    let h = tableRow("Cloudflare", "12 ms", taInfo, key = "cf")
    rowR = ui.lastRect
    if h.clicked: inc rowHit
    if h.info: inc infoHit
    if tableSwitch("Wi-Fi", wifi): discard
    switchR = ui.lastRect
  tableGroup(""):
    if tableButton("Reset", destructive = true): inc resetHit
    buttonR = ui.lastRect
run(4)
doAssert rowR.w > W div 2 and switchR.y >= rowR.y + rowR.h and buttonR.y > switchR.y + switchR.h
click(rowR, dx = 30)
doAssert rowHit == 1 and infoHit == 0, "the row"
click(rowR, dx = rowR.w - dp(22))
doAssert infoHit == 1 and rowHit == 1, "its info button, apart from the row"
click(switchR, dx = 30)
doAssert wifi, "a click on the switch's row flips it"
click(switchR, dx = 30)
doAssert not wifi
click(buttonR, dx = buttonR.w div 2)
doAssert resetHit == 1
# the keys: the button clicked last has the keys; Enter presses it
key(KeyEnter)
run(2)
doAssert resetHit == 2, "Enter on the focused row"

# ---- a search bar: Cancel empties it --------------------------------------------------------------

var q = ""
var barR: Rect
view = proc () =
  searchBar(q, "Search servers")
  barR = ui.lastRect
run(2)
click(barR, dx = 60)
typeText("quad")
run(3)
doAssert q == "quad"
click(barR, dx = barR.w - dp(20))
run(2)
doAssert q == "", "Cancel: emptied " & q

# ---- an action bar: an action, Back ---------------------------------------------------------------

var acted = -9
var abBack = 0
view = proc () =
  let a = actionBar([(nfPlus, "New"), (nfTrash, "Delete")], back = "Back", signature = 0)
  if a == -2: inc abBack
  elif a >= 0: acted = a
  label "Content"
run(3)
click(rect(W - 40, H - 20, 4, 4), dx = 0)
doAssert acted == 1, "the last action at the bar's end: " & $acted
click(rect(16, H - 20, 4, 4), dx = 0)
doAssert abBack == 1, "Back at its start"

# ---- in every look, light and dark; and on a phone's screen --------------------------------------

var all = 0
var sel2 = 2
var d2 = date(2026, 11, 25)
var c2 = 2
var p2 = 1
var openAll = true
view = proc () =
  discard navBar("Order", back = "Orders", action = "Edit")
  row:
    wheelPicker(sizes, sel2)
    dateWheels(d2)
  quantity(c2, 0, 9)
  pageDots(p2, 4)
  discard swipeRow("Invoice", ["Delete"], detail = "Al Noor")
  tableGroup("Rows", "A note"):
    discard tableRow("A row", "detail", taChevron, glyph = nfStar)
    discard tableRow("Chosen", "", taCheck)
    var on = true
    discard tableSwitch("A switch", on)
    discard tableButton("Reset", destructive = true)
  searchBar(q)
  wheelGroup:
    wheelPicker(sizes, sel2, w = 100, key = "g1")
    wheelPicker(sizes, sel2, w = 100, key = "g2")
  bottomSheet(openAll, "Filters"):
    label "Paid only"
  inc all
for look in [lookClassic, lookGlass, lookMatte, lookGloss]:
  uiLook = look
  let (l, d) = if look == lookClassic: (Classic, Dark) else: lookSchemes(look)
  for t in [l, d]:
    ui.theme = t
    invalidate()
    run(3)
uiLook = lookClassic
ui.theme = Classic
openAll = false
run(2)
doAssert all > 20
echo "mobile ok"

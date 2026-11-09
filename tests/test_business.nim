## Headless tests of the business widgets (grid, tree, dates, numbers...).

import std/[os, sequtils, strutils]
import retroui/uirelays/[coords, input]
import retroui
import harness

# ---- pure helpers ----------------------------------------------------------------

block dates:
  doAssert dayNumber(date(1970, 1, 1)) == 0
  for n in -800_000 .. 800_000:
    if n mod 997 == 0: doAssert dayNumber(fromDayNumber(n)) == n
  doAssert weekday(date(2026, 10, 27)) == 2, "a Tuesday"
  doAssert weekday(date(2000, 1, 1)) == 6, "a Saturday"
  doAssert date(2026, 1, 31).addMonths(1) == date(2026, 2, 28)
  doAssert date(2024, 1, 31).addMonths(1) == date(2024, 2, 29)
  doAssert date(2026, 12, 31).addDays(1) == date(2027, 1, 1)
  doAssert not date(2026, 2, 29).valid
  dateStyle = dsDMY
  doAssert $date(2026, 3, 7) == "07/03/2026"
  var d: Date
  doAssert parseDate("7/3/2026", d) and d == date(2026, 3, 7)
  doAssert parseDate("2026-03-07", d) and d == date(2026, 3, 7)
  doAssert not parseDate("31/02/2026", d)
  dateStyle = dsMDY
  doAssert parseDate("3/7/26", d) and d == date(2026, 3, 7)
  dateStyle = dsISO
  doAssert $date(2026, 3, 7) == "2026-03-07"
  dateStyle = dsDMY

block numbers:
  doAssert formatNumber(1234.5) == "1,234.50"
  doAssert formatNumber(-1234567.891, 1) == "-1,234,567.9"
  doAssert formatNumber(999.999, 2) == "1,000.00"
  doAssert formatNumber(-0.001) == "0.00"
  doAssert formatNumber(12, 0, thousands = false) == "12"
  var v: float
  doAssert parseNumber("1,234.50", v) and v == 1234.5
  doAssert not parseNumber("12a", v)
  # out-of-range decimals, NaN and infinities do not raise
  doAssert formatNumber(1.6, -2) == "2" and formatNumber(1.25, 99).startsWith("1.25")
  doAssert formatNumber(NaN) == "NaN" and formatNumber(Inf) == "Inf" and
           formatNumber(NegInf) == "-Inf"
  v = 7
  doAssert not parseNumber("inf", v) and not parseNumber("nan", v) and v == 7
  doAssert compact(1260) == "1.3K" and compact(25_400) == "25K" and compact(2_500_000) == "2.5M"
  doAssert compact(12) == "12"

block sorting:
  var t = @[@["b", "10"], @["a", "9"], @["C", "1,000"]]
  sortRows(t, 1)
  doAssert t[0][0] == "a" and t[2][0] == "C", "numeric column"
  sortRows(t, 0, descending = true)
  doAssert t[0][0] == "C" and t[2][0] == "a", "text column ignores case"

# ---- widgets ------------------------------------------------------------------

var
  page = 0
  r1, r2, r3: Rect
  cols = @[column("Name", 120), column("Qty", 60, alRight, editable = true),
           column("Price", 80, alRight)]
  data = @[@["Apple", "3", "1.20"], @["Pear", "10", "0.80"],
           @["Fig", "7", "2.50"], @["Kiwi", "1", "0.30"]]
  gsel = 0
  events: seq[GridEvent]
  tsel = ""
  openA = true
  openB = false
  day = date(2026, 10, 27)
  picked = false
  checks: seq[bool]
  amount = 1234.5
  qty = 5
  city = ""
  pos = 200
  dlgOpen = false
  answer = ""
  dlgResult = 0
  fdOpen = false
  fdPath = ""
  fdDone = false
  layerAfter = -1
  marked: seq[bool]
  msel = 0
  mev: GridEvent
  iconEv: GridEvent
  crumb = -1
  zoomV = 0.0
  pic = newBitmap(40, 30, 0xFF00FF00'u32)
  progOpen = false
  progCancelled = false

proc testView() =
  case page
  of 0:
    let e = grid(cols, data, gsel, height = 4, w = 300)
    r1 = ui.lastRect
    if e.sorted or e.edited or e.activated: events.add e
    if e.sorted: sortRows(data, e.sortColumn, e.sortDescending)
  of 1:
    tree(tsel, 8):
      branch "Sales", openA:
        leaf "Invoices"
        leaf "Orders"
      branch "Stock", openB:
        leaf "Items"
      leaf "Reports"
    r1 = ui.lastRect
  of 2:
    calendar(day)
    r1 = ui.lastRect
    if datePicker(day): picked = true
    r2 = ui.lastRect
  of 3:
    checkList(["Email", "Phone", "Post"], checks, rows = 3, w = 200)
    r1 = ui.lastRect
    numberEdit(amount)
    r2 = ui.lastRect
    intEdit(qty)
    r3 = ui.lastRect
  of 4:
    comboEdit(city, ["Berlin", "Bern", "Muscat", "Sohar"], w = 150)
    r1 = ui.lastRect
  of 5:
    split(pos, 200):
      label "left"
      r1 = ui.lastRect
    do:
      label "right"
      r2 = ui.lastRect
  of 6:
    barChart([3.0, 5, 2], ["a", "b", "c"], "Bars", w = 200, h = 120)
    r1 = ui.lastRect
    lineChart([@[1.0, 3, 2], @[2.0, 1, 4]], names = ["x", "y"], w = 200, h = 120)
    pieChart([1.0, 1, 2], ["p", "q", "r"], w = 200, h = 120)
  of 7:
    let res = inputBox(dlgOpen, "Name", "Your name:", answer)
    if res != 0: dlgResult = res
  of 8:
    if fileDialog(fdOpen, fdPath): fdDone = true
  of 10:
    let e = grid(cols, data.len, proc (r, c: int): string = data[r][c], msel,
                 marked, height = 6, w = 300,
                 icon = proc (r: int): Icon = (if r == 0: icFolder else: icFile),
                 typeToEdit = false)
    if e.selChanged or e.activated or e.rightClicked: mev = e
    r1 = ui.lastRect
  of 11:
    let e = iconView(12, proc (i: int): string = "Item " & $i,
                     proc (i: int; r: Rect) = image(r.x, r.y, icFolder, mag = 2),
                     msel, marked, height = 200)
    if e.selChanged or e.activated: iconEv = e
    r1 = ui.lastRect
  of 12:
    let c = breadcrumb(["/", "home", "foxoman", "Documents"], w = 400)
    if c >= 0: crumb = c
    r1 = ui.lastRect
    imageView(pic, zoomV, height = 100, w = 200)
    r2 = ui.lastRect
    if progressBox(progOpen, "Copying", "Copying 3 files", 0.5): progCancelled = true
  of 13:
    # a tree node with its own icon (arguments that are expressions), and a
    # pane taller and wider than it is
    split(pos, 200):
      tree(tsel, -1):
        branch("Sales", openA, glyphIcon(pxFolder, color(0, 0, 0)), "sales-id", true):
          leaf("Invoices", pic = glyphIcon(pxSheet, color(0, 0, 0)))
      r1 = ui.lastRect
    do:
      for i in 0 ..< 30: label "Line " & $i
      row([900]): label "a row wider than the pane"
      r2 = ui.lastRect
  of 9:
    dialog dlgOpen, "Layers", 300:
      comboEdit(city, ["Berlin", "Bern"])
      datePicker(day)
      combo(["a", "b"], gsel)
      layerAfter = layer()
  else: discard

harness.view = testView
fakeDriver()
startApp("test", W, H)
run(3)

template rowH: int = ItemH + 2   # a grid's rows
template hdrH: int = ItemH + 4   # and its header row

block gridSelect:
  click(r1, 20, 1 + hdrH + 2 * rowH + 5)
  doAssert gsel == 2, "click selects the third row"
  key(KeyDown)
  run()
  doAssert gsel == 3
  key(KeyHome)
  run()
  doAssert gsel == 0

block gridSort:
  events.setLen(0)
  click(r1, 140, 6)      # the "Qty" header
  doAssert events.len == 1 and events[0].sorted and events[0].sortColumn == 1
  doAssert not events[0].sortDescending
  doAssert data.mapIt(it[1]) == @["1", "3", "7", "10"], "sorted by quantity"
  click(r1, 140, 6)
  doAssert events[^1].sortDescending, "a second click sorts the other way"
  doAssert data[0][1] == "10"

block gridEdit:
  events.setLen(0)
  gsel = 0
  click(r1, 140, 1 + hdrH + 5)       # row 0, "Qty" cell
  key(KeyF2)
  run()
  typeText("42")
  run()
  key(KeyEnter)
  run()
  doAssert events.len == 1, $events
  let ev = events[0]
  doAssert ev.edited and ev.row == 0 and ev.col == 1 and ev.text == "42",
    "F2, type, Enter commits: " & $ev
  key(KeyEnter)
  run()
  doAssert events.len == 2 and events[1].activated, "Enter activates the row"

block gridResize:
  let before = cols[0].width
  let x = r1.x + 1 + cols[0].width - 1
  down(x, r1.y + 6)
  run()
  move(x + 30, r1.y + 6)
  run()
  up(x + 30, r1.y + 6)
  run()
  doAssert cols[0].width == before + 30, "dragging the header edge: " &
    $cols[0].width

block treeNodes:
  page = 1
  run(2)
  let rh = ItemH + 1
  click(r1, 40, 1 + rh + 5)          # "Invoices"
  doAssert tsel == "Sales/Invoices", tsel
  key(KeyDown)
  run()
  doAssert tsel == "Sales/Orders"
  key(KeyDown)
  run()
  doAssert tsel == "Stock"
  key(KeyRight)
  run()
  doAssert openB, "Right expands"
  key(KeyDown)
  run()
  doAssert tsel == "Stock/Items"
  key(KeyLeft)
  run()
  doAssert tsel == "Stock", "Left goes to the parent"
  key(KeyLeft)
  run()
  doAssert not openB, "Left collapses"
  click(r1, 4 + 4, 1 + 5)            # the box of "Sales"
  doAssert not openA, "the box collapses"
  # nothing selected: the focus shows on the tree, Down picks the first node
  tsel = "Gone"
  run(2)
  key(KeyDown)
  run()
  doAssert tsel == "Sales", tsel

block calendarAndPicker:
  page = 2
  run(2)
  click(r1, 20, r1.h - 5)          # a day in the last row
  doAssert day != date(2026, 10, 27), "clicking a day picks it"
  day = date(2026, 10, 27)
  run()
  key(KeyRight)
  run()
  doAssert day == date(2026, 10, 28), "arrow keys move the day"
  click(r2, 5)
  key(KeyA, {CtrlPressed})
  run()
  typeText("01/01/2027")
  run()
  doAssert day == date(2027, 1, 1) and picked, "typing a date: " & $day
  click(r2, r2.w - 6)               # the drop-down button
  doAssert ui.popup != 0, "the calendar dropped down"
  key(KeyDown)
  key(KeyEnter)
  run()
  doAssert day == date(2027, 1, 8) and ui.popup == 0, $day

block checksAndNumbers:
  page = 3
  run(2)
  click(r1, 10, 1 + 16 + 5)
  doAssert checks == @[false, true, false]
  key(KeySpace)
  run()
  doAssert checks == @[false, false, false], "Space toggles"
  run()
  click(r2, 5)
  key(KeyA, {CtrlPressed})
  run()
  typeText("2,500.75")
  run()
  doAssert amount == 2500.75
  click(r3, 5)
  key(KeyA, {CtrlPressed})
  run()
  typeText("12x3")
  run()
  doAssert qty == 123, "letters are not typed into a number field"
  # a click gives the focus with the whole number selected: typing replaces it
  amount = 0
  run(2)
  click(r2, 5)
  run()
  typeText("12.5")
  run()
  doAssert amount == 12.5, $amount
  # the app clears it while it has the focus (a form after Add): it shows 0
  amount = 0
  run(2)
  typeText("7")
  run()
  doAssert amount == 7, "typed after the clear: " & $amount

block autocomplete:
  page = 4
  run(2)
  click(r1, 5)
  typeText("be")
  run()
  key(KeyDown)
  key(KeyDown)
  key(KeyEnter)
  run()
  doAssert city == "Bern", city
  key(KeyA, {CtrlPressed})
  run()
  typeText("s")
  run()
  # suggestions for "s": Muscat, Sohar; a click on the second one
  click(rect(r1.x, r1.y + r1.h + ItemH, r1.w, ItemH), 10)
  doAssert city == "Sohar", city

block splitter:
  page = 5
  run(2)
  let bx = r1.x + pos + 2
  down(bx, r1.y + 5)
  run()
  move(bx + 50, r1.y + 5)
  run()
  up(bx + 50, r1.y + 5)
  run()
  doAssert pos == 250, $pos
  doAssert r2.x == r1.x + 255, "the right pane follows the bar"

block charts:
  page = 6
  run(2)
  var blue = 0
  for y in r1.y ..< r1.y + r1.h:
    for x in r1.x ..< r1.x + r1.w:
      if px(x, y) == 0x0000FF: inc blue
  doAssert blue > 200, "bars are drawn"

block inputDialog:
  page = 7
  dlgOpen = true
  run(2)
  typeText("Fox")
  run()
  key(KeyEnter)
  run()
  doAssert dlgResult == 1 and answer == "Fox" and not dlgOpen

block fileDialogPick:
  # (a web page has the browser's file chooser instead: tests/web)
  if defined(wasm): break fileDialogPick
  page = 8
  let dir = getTempDir() / "retro-test"
  createDir(dir)
  writeFile(dir / "report.txt", "x")
  writeFile(dir / "data.csv", "x")
  fdPath = dir & "/"
  fdOpen = true
  run(2)
  typeText("report.txt")
  run()
  key(KeyEnter)
  run()
  doAssert fdDone and fdPath == dir / "report.txt" and not fdOpen, fdPath
  removeDir(dir)

block popupsKeepTheirLayer:
  page = 9
  dlgOpen = true
  city = ""
  run(2)
  typeText("Ber")          # the suggestions drop down
  run()
  doAssert layerAfter == LayerDialog,
    "widgets after an open drop-down still draw in the dialog"
  dlgOpen = false
  run()

block touchGrid:
  page = 0
  ui.touch = true
  run(2)
  gsel = 0
  let y = r1.y + 1 + hdrH + 2 * rowH + 5
  down(r1.x + 20, y)
  run()
  doAssert gsel == 0, "a finger selects on release, not on touch"
  up(r1.x + 20, y)
  run()
  doAssert gsel == 2, "the tap selected the row"
  # a drag scrolls instead of selecting
  for i in 0 ..< 4: data.add @["Extra" & $i, $i, "1.00"]
  for i in 0 ..< 8: data.add @["More" & $i, $i, "2.00"]
  run()
  down(r1.x + 20, y + 40)
  run()
  move(r1.x + 20, y + 20)
  run()
  move(r1.x + 20, y)
  run()
  up(r1.x + 20, y)
  run()
  doAssert gsel == 2, "dragging did not select"
  ui.touch = false
  run()

block multiSelectGrid:
  page = 10
  data = @[@["Folder", "1", "1.00"], @["a.txt", "2", "2.00"], @["b.txt", "3", "3.00"],
           @["c.txt", "4", "4.00"]]
  marked = @[]
  run(2)
  let y0 = r1.y + 1 + hdrH
  click(r1, 30, y0 - r1.y + 5)                       # row 0
  doAssert marked == @[true, false, false, false]
  down(r1.x + 30, r1.y + y0 - r1.y + 2 * rowH + 5)   # Shift+click row 2
  queue.insert(Event(kind: KeyDownEvent, key: KeyNone, mods: {ShiftPressed}), queue.len - 1)
  run()
  up(r1.x + 30, r1.y + y0 - r1.y + 2 * rowH + 5)
  run()
  doAssert marked == @[true, true, true, false], $marked
  key(KeyA, {CtrlPressed})
  run()
  doAssert marked == @[true, true, true, true], "Ctrl+A selects all"
  key(KeyDown)
  run()
  doAssert msel == 3 and marked == @[false, false, false, true]
  typeText("b")
  run()
  doAssert msel == 2, "typing jumps to the row: " & $msel
  gridEdit(1, 0, selectTo = 1)
  run()
  typeText("Z")
  run()
  key(KeyEnter)
  run()
  doAssert mev.selChanged
  doAssert pixels.len > 0

block iconViewSelect:
  page = 11
  marked = @[]
  msel = 0
  run(2)
  click(r1, 20, 20)
  doAssert marked[0] and iconEv.selChanged
  key(KeyRight)
  run()
  doAssert msel == 1 and marked[1] and not marked[0]
  key(KeyDown)
  run()
  doAssert msel > 1, "Down moves a row of icons"
  key(KeyEnter)
  run()
  doAssert iconEv.activated

block crumbsImageProgress:
  page = 12
  progOpen = true
  run(2)
  progOpen = false
  run(2)
  click(r1, 2 + textWidth("/") + 8 + textWidth(" > ") + 6)  # "home"
  doAssert crumb >= 0, $crumb
  progOpen = true
  run(2)
  key(KeyEsc)
  run()
  doAssert progCancelled and not progOpen

block richGrid:
  # cells that are more than text: check boxes, status colors, progress,
  # a drop-down, buttons; cell colors; the record indicator; totals
  var orders = @[
    @["Pool area glass door", "70.000", "green", "1", "0.5", "Engineering", "Open"],
    @["Stewarding general", "51.800", "orange", "0", "0.25", "F&B Stewarding", "Open"],
    @["Bread for canteen", "54.155", "#0000FF", "0", "1", "Cafeteria", "Open"]]
  var ocols = @[column("Order", 150), numberColumn("Amount", 70), colorColumn("DA"),
                checkColumn("S", 30), progressColumn("Done", 70),
                choiceColumn("Store", ["Engineering", "F&B Stewarding", "Cafeteria"], 110),
                buttonColumn("", 50)]
  var osel = 0
  var ev: GridEvent
  var r: Rect
  harness.view = proc () =
    let e = grid(ocols, orders.len, proc (row, col: int): string = orders[row][col],
                 osel, height = 5, rowHeaders = true,
                 style = proc (row, col: int): CellStyle =
                   (if col == 1 and orders[row][1] > "60": cellStyle(fg = color(200, 0, 0), bold = true)
                    else: CellStyle()),
                 footer = proc (col: int): string =
                   (if col == 0: "Total" elif col == 1: "175.955" else: ""))
    if e.edited or e.clicked or e.toggled: ev = e
    if e.edited: orders[e.row][e.col] = e.text
    r = ui.lastRect
  run(3)
  let rh = 16                                 # the record indicator column
  let x0 = r.x + 1 + rh
  proc colX(c: int): int =
    result = x0
    for k in 0 ..< c: result += ocols[k].width
  let rowY = proc (row: int): int = r.y + 1 + ItemH + 4 + row * (ItemH + 2) + (ItemH + 2) div 2
  # the status color fills its cell
  doAssert px(colX(2) + 10, rowY(1)) == 0xFF8040, "an orange status cell"
  doAssert px(colX(2) + 10, rowY(2)) == 0x0000FF, "a #RRGGBB status cell"
  # a click on a check box flips it (and reports it)
  click(rect(colX(3), r.y, 30, 1), dx = 15, dy = rowY(1) - r.y)
  doAssert ev.toggled and ev.row == 1 and ev.col == 3 and ev.text == "1", $ev
  doAssert orders[1][3] == "1"
  # Space on the current check box cell flips it back
  ev = GridEvent()
  key(KeySpace)
  run()
  doAssert ev.toggled and orders[1][3] == "0", $orders[1][3]
  # a button cell is clicked
  ev = GridEvent()
  click(rect(colX(6), r.y, 50, 1), dx = 25, dy = rowY(2) - r.y)
  doAssert ev.clicked and ev.row == 2 and ev.col == 6, $ev
  # the drop-down cell: F4 opens its choices, Down + Enter picks one
  osel = 0
  click(rect(colX(5), r.y, 110, 1), dx = 20, dy = rowY(0) - r.y)
  ev = GridEvent()
  key(KeyF4)
  run(2)
  key(KeyDown)
  run()
  key(KeyDown)
  run()
  key(KeyEnter)
  run(2)
  doAssert ev.edited and ev.col == 5 and orders[0][5] == "F&B Stewarding", $orders[0][5]
  # the record indicator shows the current row; the totals row is there
  doAssert px(r.x + 1 + rh div 2, rowY(osel)) == 0x000000, "the arrow at the current row " & $osel & " " & toHex(px(r.x + 1 + rh div 2, rowY(osel))) & " " & toHex(px(r.x + 1 + rh div 2 + 1, rowY(osel)))
  doAssert px(r.x + 1 + rh div 2, rowY(osel + 1)) == 0xC0C0C0
  let fy = r.y + r.h - 2 - (ItemH + 2) div 2
  var dark = 0
  for x in x0 .. x0 + 60:
    if (px(x, fy) and 0xFF) <= 0x60: inc dark       # (gray text: nearly black)
  doAssert dark > 5, "the totals row has text"
  # cell styles: the big amount in red (in a row not selected)
  osel = 2
  run(2)
  var red = false
  for x in colX(1) .. colX(1) + 70:
    for y in rowY(0) - 4 .. rowY(0) + 4:
      if px(x, y) == 0xC80000: red = true
  doAssert red, "a cell in its own color"

block gridFooterAddsARow:
  # `height` rows of data show, and the totals row comes on top of them
  var fcols = @[column("Name", 120)]
  var fsel = 0
  var r: Rect
  let names = ["Alpha", "Bravo", "Charlie"]
  harness.view = proc () =
    discard grid(fcols, 3, proc (row, col: int): string = names[row], fsel,
                 height = 3, footer = proc (col: int): string = "Total")
    r = ui.lastRect
  run(3)
  let rowH = ItemH + 2
  doAssert r.h == ItemH + 4 + 3 * rowH + rowH + 1 + 2, $r
  # the third row is drawn above the totals row (no scroll bar needed)
  let y2 = r.y + 1 + ItemH + 4 + 2 * rowH + rowH div 2
  var dark = 0
  for x in r.x + 4 .. r.x + 60:
    for y in y2 - 3 .. y2 + 3:
      if px(x, y) != 0xFFFFFF: inc dark
  doAssert dark > 10, "the third row shows"
  doAssert px(r.x + r.w - 4, r.y + ItemH + 4 + rowH) != 0xC0C0C0, "no scroll bar"

block paneScrolls:
  harness.view = testView
  page = 13
  ui.pageX = 0
  ui.pageY = 0
  run(3)
  doAssert ui.pageMaxX == 0 and not ui.pageOn,
    "what a pane holds does not make the window scroll"
  let y0 = r2.y
  let paneX = r1.x + pos + 40
  move(paneX, 100)
  queue.add Event(kind: MouseWheelEvent, x: 0, y: -3)          # (x: the sideways part)
  run(20)
  doAssert r2.y < y0, "the wheel scrolls a pane taller than it is: " & $r2.y & " " & $y0
  # the tree node with an icon of its own and an id
  click(r1, 30, 5)
  doAssert tsel == "sales-id", tsel

block gridCells:
  # text wider than its cell ends in "...": no letters of the cut part
  doAssert ellipsize("Badar Mohammed Al Kindi", textWidth("Badar Mo")) .endsWith("\u2026")

echo "business tests passed"

## 7GUIs: the seven tasks of the GUI programming benchmark
## (eugenkiss.github.io/7guis), each made with Retro Nim UI as the tasks ask,
## a tab for each:
##
## 1. Counter -- a label and a button.
## 2. Temperature Converter -- Celsius and Fahrenheit, each kept in step with
##    the other as it is typed; what is not a number changes nothing.
## 3. Flight Booker -- a one-way or a return flight, two dates typed
##    (DD.MM.YYYY), red while they are not dates; Book only when it can be.
## 4. Timer -- a gauge of the time gone, a slider for how long, Reset.
## 5. CRUD -- names in a list, filtered by the surname's start; create,
##    update, delete.
## 6. Circle Drawer -- a click makes a circle, a right click on one adjusts
##    its diameter; undo and redo.
## 7. Cells -- a spreadsheet of A..Z by 0..99 with formulas (=B1*2,
##    =SUM(A0:A9)); a change reaches every cell that depends on it.
##
##   nim c -r examples/sevenguis.nim
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, math, tables, sets, times]
import retroui

template th: untyped = ui.theme

var page = 0

# ---- 1. Counter ---------------------------------------------------------------------------------

var count = 0

proc counterTask() =
  row([120, 90]):
    var shown = $count
    accessName "Counted"               # (its name for screen readers and drivers)
    edit shown, readOnly = true
    if button("&Count"): inc count

# ---- 2. Temperature Converter ---------------------------------------------------------------------

var celsius = "0"
var fahrenheit = "32"

proc number(s: string; v: var float): bool =
  ## (a number as typed: "12", "-3.5")
  try:
    v = parseFloat(s.strip)
    result = not v.isNaN and v.classify != fcInf and v.classify != fcNegInf
  except ValueError: discard

proc shortNum(v: float): string =
  ## (at most two decimals, no trailing zeros)
  result = formatFloat(v, ffDecimal, 2)
  result.trimZeros()
  if result == "-0": result = "0"

proc temperatureTask() =
  row([110, 90, 110, 90]):
    var c = 0.0
    var f = 0.0
    accessName "Celsius"               # (the labels come after the boxes)
    if edit(celsius) and number(celsius, c):
      fahrenheit = shortNum(c * 9 / 5 + 32)
    label "Celsius ="
    accessName "Fahrenheit"
    if edit(fahrenheit) and number(fahrenheit, f):
      celsius = shortNum((f - 32) * 5 / 9)
    label "Fahrenheit"

# ---- 3. Flight Booker ---------------------------------------------------------------------------

var
  flightKind = 0                       # 0 one-way, 1 return
  departs = now().format("dd'.'MM'.'yyyy")
  returns = departs
  booked = false
  bookedText = ""

proc parseDay(s: string; d: var DateTime): bool =
  ## (DD.MM.YYYY, a day there is: not 31.02.2026)
  let p = s.strip.split('.')
  if p.len != 3 or p[0].len notin 1..2 or p[1].len notin 1..2 or p[2].len != 4: return
  for part in p:
    if not part.allCharsInSet(Digits): return
  let (day, month, year) = (parseInt(p[0]), parseInt(p[1]), parseInt(p[2]))
  if month notin 1..12 or year < 1 or day < 1 or day > getDaysInMonth(Month(month), year): return
  d = dateTime(year, Month(month), MonthdayRange(day), zone = utc())
  true

proc flightTask() =
  var d1, d2: DateTime
  let ok1 = parseDay(departs, d1)
  let ok2 = parseDay(returns, d2)
  let canBook = ok1 and (flightKind == 0 or (ok2 and d2 >= d1))
  accessName "Flight"
  combo(["one-way flight", "return flight"], flightKind, w = 220)
  accessName "Flight out"
  edit departs, w = 220, invalid = not ok1
  accessName "Flight back"
  edit returns, w = 220, enabled = flightKind == 1, invalid = flightKind == 1 and not ok2
  if button("&Book", enabled = canBook):
    bookedText = if flightKind == 0: "You have booked a one-way flight on " & departs & "."
                 else: "You have booked a return flight from " & departs & " to " &
                       returns & "."
    booked = true
  if flightKind == 1 and ok1 and ok2 and d2 < d1:
    label "The return flight is before the flight out.", color = InvalidRed
  discard msgBox(booked, "Flight Booker", bookedText)

# ---- 4. Timer -----------------------------------------------------------------------------------

var
  durationTenths = 150                 # the slider: 0.1 .. 30 seconds
  elapsedMs = 0
  lastTick = -1                        # (the frame's time the elapsed time was counted to)

proc timerTask() =
  # the time goes on whether the tab is shown or not, as a timer does
  row([110, -1]):
    label "Elapsed time:"
    progress(elapsedMs / (durationTenths * 100), showText = false)
  label formatFloat(elapsedMs / 1000, ffDecimal, 1) & " s"
  row([110, -1]):
    label "Duration:"
    slider(durationTenths, 1, 300, ticks = 0)
  label formatFloat(durationTenths / 10, ffDecimal, 1) & " s"
  if button("&Reset"):
    elapsedMs = 0

proc timerTick() =
  ## (every frame, whatever tab is open: the elapsed time follows the
  ## clock until the duration, and wakes the window while it runs)
  if lastTick < 0: lastTick = ui.now
  let limit = durationTenths * 100
  if elapsedMs < limit:
    elapsedMs = min(limit, elapsedMs + (ui.now - lastTick))
    wakeIn(50)
  lastTick = ui.now

# ---- 5. CRUD ------------------------------------------------------------------------------------

type Person = object
  name, surname: string

var
  people = @[Person(name: "Hans", surname: "Emil"), Person(name: "Max", surname: "Mustermann"),
             Person(name: "Roman", surname: "Tisch")]
  prefix = ""
  firstName = ""
  lastName = ""
  pick = -1                            # in the list as filtered
  lastPick = -2

proc crudTask() =
  var shown: seq[int]
  for i, p in people:
    if p.surname.toLowerAscii.startsWith(prefix.toLowerAscii): shown.add i
  if pick >= shown.len: pick = shown.len - 1
  row([110, 160]):
    label "Filter prefix:"
    edit prefix
  var items: seq[string]
  for i in shown: items.add people[i].surname & ", " & people[i].name
  row([280, -1]):
    accessName "People"
    listbox(items, pick, rows = 8)
    col:
      row([80, -1]):
        label "Name:"
        edit firstName
      row([80, -1]):
        label "Surname:"
        edit lastName
  if pick != lastPick and pick >= 0:
    firstName = people[shown[pick]].name
    lastName = people[shown[pick]].surname
  lastPick = pick
  row:
    if button("&Create", enabled = firstName.strip.len > 0 or lastName.strip.len > 0):
      people.add Person(name: firstName.strip, surname: lastName.strip)
      pick = -1
    if button("&Update", enabled = pick >= 0):
      people[shown[pick]] = Person(name: firstName.strip, surname: lastName.strip)
      lastPick = -2
    if button("&Delete", enabled = pick >= 0):
      people.delete shown[pick]
      pick = -1
      firstName = ""
      lastName = ""

# ---- 6. Circle Drawer -----------------------------------------------------------------------------

type
  Circle = object
    x, y, d: int                       # the center in the canvas, the diameter
  Step = object
    ## (one undo step: a circle made, or a diameter changed)
    made: bool
    index, before, after: int

var
  circles: seq[Circle]
  undoSteps, redoSteps: seq[Step]
  chosen = -1                          # the circle nearest the mouse, under it
  adjusting = false
  adjusted = -1                        # (the circle the dialog changes)
  adjustFrom = 0
  menuFor = -1                         # (the circle the right click was on)

proc undo() =
  let s = undoSteps.pop()
  if s.made: circles.setLen(s.index)
  else: circles[s.index].d = s.before
  redoSteps.add s

proc redo() =
  let s = redoSteps.pop()
  if s.made: circles.add Circle(x: s.before, y: s.after, d: 30)
  else: circles[s.index].d = s.after
  undoSteps.add s

proc circleTask() =
  row:
    if button("&Undo", enabled = undoSteps.len > 0 and not adjusting): undo()
    if button("&Redo", enabled = redoSteps.len > 0 and not adjusting): redo()
  let r = canvas(0, max(160, remainingH()))
  fill(r, th.field)
  box(r, th.edge)
  # the circle under the mouse, the nearest to its center (not while its
  # menu or the dialog is open: the one adjusted stays lit)
  if not adjusting and ui.popup == 0:
    chosen = -1
    if mouseIn(r):
      var best = Inf
      for i, c in circles:
        let dist = hypot(float(ui.mx - r.x - c.x), float(ui.my - r.y - c.y))
        if dist <= c.d / 2 and dist < best:
          best = dist
          chosen = i
  pushClip(inset(r, 1))
  for i, c in circles:
    let cx = float(r.x + c.x)
    let cy = float(r.y + c.y)
    if i == chosen: disc(cx, cy, c.d / 2, th.gray)
    ring(cx, cy, c.d / 2, 1.0, th.text)
  popClip()
  if not adjusting and canInput() and mouseIn(r) and ui.pressed and chosen < 0:
    circles.add Circle(x: ui.mx - r.x, y: ui.my - r.y, d: 30)
    undoSteps.add Step(made: true, index: circles.high, before: ui.mx - r.x, after: ui.my - r.y)
    redoSteps.setLen(0)
  if ui.rpressed and mouseIn(r) and not adjusting: menuFor = chosen
  if menuFor >= 0:
    contextMenu:
      if menuItem("&Adjust diameter..."):
        adjusting = true
        adjusted = menuFor
        adjustFrom = circles[menuFor].d
  if adjusting and adjusted >= 0:
    dialog(adjusting, "Adjust Diameter", 320):
      let c = circles[adjusted]
      label "Adjust the diameter of the circle at (" & $c.x & ", " & $c.y & ")."
      slider(circles[adjusted].d, 4, 200, ticks = 0)
      if button("&Close", isDefault = true): adjusting = false
    if not adjusting:
      # (closed: the change is one step to undo)
      if circles[adjusted].d != adjustFrom:
        undoSteps.add Step(made: false, index: adjusted, before: adjustFrom,
                           after: circles[adjusted].d)
        redoSteps.setLen(0)
      adjusted = -1

# ---- 7. Cells -----------------------------------------------------------------------------------

const
  Cols = 26                            # A .. Z
  Rows = 100                           # 0 .. 99

type
  Val = object
    ## (a cell's value: a number, a text, or an error)
    case num: bool
    of true: n: float
    of false: s: string
  FormulaError = object of CatchableError

var
  raw = newSeq[string](Cols * Rows)    # what each cell holds, as typed
  values: Table[int, Val]              # (the values worked out, until a cell changes)
  working: HashSet[int]                # (the cells being worked out: a cycle meets one)
  cellPick = 1                         # the current row
  cellCol = 1                          # the current column (0: the row numbers)
  bar = ""                             # the formula bar
  barCell = -1
  sheetCols: seq[Column]

proc cellName(c: int): string = $chr(ord('A') + c mod Cols) & $(c div Cols)

proc valueOf(c: int): Val

proc parseRef(s: string; i: var int; c: var int): bool =
  ## (A0 .. Z99 at `i`)
  if i < s.len and s[i].toUpperAscii in {'A'..'Z'} and i + 1 < s.len and s[i + 1] in Digits:
    let col = ord(s[i].toUpperAscii) - ord('A')
    var j = i + 1
    while j < s.len and s[j] in Digits: inc j
    let row = parseInt(s[i + 1 ..< j])
    if row >= Rows: raise newException(FormulaError, "#REF")
    c = row * Cols + col
    i = j
    true
  else: false

proc evalFormula(s: string): float =
  ## =1+A1*2, =SUM(A0:A9), =AVG(B1, B2, 3), =(A1-B1)/2: numbers, cells,
  ## + - * / and parentheses, SUM PROD AVG MIN MAX COUNT of cells and
  ## ranges. An empty cell is 0; a cell of text is an error.
  var i = 1                            # (after "=")
  proc skip() =
    while i < s.len and s[i] == ' ': inc i
  proc fail(): ref FormulaError = newException(FormulaError, "#ERR")
  proc numOf(c: int): float =
    let v = valueOf(c)
    if v.num: v.n
    elif v.s.len == 0: 0.0
    else: raise newException(FormulaError, (if v.s.startsWith("#"): v.s else: "#VALUE"))
  proc expr(): float
  proc args(): seq[float] =
    # (a list of numbers, cells and ranges, in parentheses)
    skip()
    if i >= s.len or s[i] != '(': raise fail()
    inc i
    while true:
      skip()
      var a = i
      var c1, c2: int
      if parseRef(s, a, c1) and a < s.len and s[a] == ':':
        inc a
        if not parseRef(s, a, c2): raise fail()
        i = a
        for row in min(c1, c2) div Cols .. max(c1, c2) div Cols:
          for col in min(c1 mod Cols, c2 mod Cols) .. max(c1 mod Cols, c2 mod Cols):
            let v = valueOf(row * Cols + col)
            if v.num: result.add v.n
            elif v.s.startsWith("#"): raise newException(FormulaError, v.s)
      else:
        result.add expr()
      skip()
      if i < s.len and s[i] == ',': inc i
      elif i < s.len and s[i] == ')':
        inc i
        break
      else: raise fail()
  proc atom(): float =
    skip()
    if i >= s.len: raise fail()
    if s[i] == '(':
      inc i
      result = expr()
      skip()
      if i >= s.len or s[i] != ')': raise fail()
      inc i
    elif s[i] == '-':
      inc i
      result = -atom()
    elif s[i] in Digits or s[i] == '.':
      var j = i
      while j < s.len and s[j] in Digits + {'.'}: inc j
      try: result = parseFloat(s[i ..< j])
      except ValueError: raise fail()
      i = j
    else:
      var c: int
      var j = i
      if parseRef(s, j, c) and (j >= s.len or s[j] != '('):
        i = j
        return numOf(c)
      j = i
      while j < s.len and s[j].isAlphaAscii: inc j
      let fn = s[i ..< j].toUpperAscii
      if fn notin ["SUM", "PROD", "AVG", "AVERAGE", "MIN", "MAX", "COUNT"]:
        raise newException(FormulaError, if fn.len > 0: "#NAME" else: "#ERR")
      i = j
      let xs = args()
      case fn
      of "SUM": result = sum(xs)
      of "PROD":
        result = 1.0
        for x in xs: result *= x
      of "AVG", "AVERAGE": result = if xs.len > 0: sum(xs) / float(xs.len) else: 0.0
      of "MIN": result = if xs.len > 0: min(xs) else: 0.0
      of "MAX": result = if xs.len > 0: max(xs) else: 0.0
      else: result = float(xs.len)             # COUNT
  proc term(): float =
    result = atom()
    while true:
      skip()
      if i < s.len and s[i] == '*':
        inc i
        result *= atom()
      elif i < s.len and s[i] == '/':
        inc i
        let d = atom()
        if d == 0: raise newException(FormulaError, "#DIV/0")
        result /= d
      else: break
  proc expr(): float =
    result = term()
    while true:
      skip()
      if i < s.len and s[i] == '+':
        inc i
        result += term()
      elif i < s.len and s[i] == '-':
        inc i
        result -= term()
      else: break
  result = expr()
  skip()
  if i < s.len: raise fail()

proc valueOf(c: int): Val =
  ## A cell's value, worked out once until a cell changes; a cell that
  ## comes back to itself is a cycle.
  if c in values: return values[c]
  let s = raw[c]
  if s.startsWith("="):
    if c in working: return Val(num: false, s: "#CYCLE")
    working.incl c
    try: result = Val(num: true, n: evalFormula(s))
    except FormulaError as e: result = Val(num: false, s: e.msg)
    working.excl c
  else:
    var n: float
    if s.strip.len > 0 and number(s, n): result = Val(num: true, n: n)
    else: result = Val(num: false, s: s)
  values[c] = result

proc cellText(c: int): string =
  let v = valueOf(c)
  if v.num:
    if abs(v.n) < 1e15 and v.n == trunc(v.n): $int64(v.n)
    else:
      var t = formatFloat(v.n, ffDecimal, 6)
      t.trimZeros()
      t
  else: v.s

proc setCell(c: int; s: string) =
  ## (a change: every value is worked out again from it, as each is shown --
  ## the cells that depend on it with the others)
  raw[c] = s
  values.clear()

proc cellsTask() =
  if sheetCols.len == 0:
    sheetCols.add column("", 34, alRight)
    for k in 0 ..< Cols: sheetCols.add column($chr(ord('A') + k), 72, alRight, editable = true)
  let cur = cellPick * Cols + max(0, cellCol - 1)
  if cur != barCell:
    bar = raw[cur]
    barCell = cur
  row([60, -1]):
    label cellName(cur) & ":", bold = true
    if edit(bar): setCell(cur, bar)
  let ev = grid(sheetCols, Rows,
    proc (r, c: int): string = (if c == 0: $r else: cellText(r * Cols + c - 1)),
    cellPick, height = -1, typeToEdit = true,
    style = proc (r, c: int): CellStyle =
      if c == 0: CellStyle(fg: th.gray)
      else:
        let v = valueOf(r * Cols + c - 1)
        if not v.num and v.s.startsWith("#"): CellStyle(fg: InvalidRed) else: CellStyle(),
    editText = proc (r, c: int): string = (if c == 0: "" else: raw[r * Cols + c - 1]))
  cellCol = max(1, ev.curCol)
  if ev.edited and ev.col > 0:
    setCell(ev.row * Cols + ev.col - 1, ev.text)
    barCell = -1

proc seedCells() =
  ## (a small sheet to start from)
  let start = [("A0", "Fruit"), ("B0", "Price"), ("C0", "Count"), ("D0", "Total"),
               ("A1", "Apples"), ("B1", "1.20"), ("C1", "4"), ("D1", "=B1*C1"),
               ("A2", "Pears"), ("B2", "0.95"), ("C2", "6"), ("D2", "=B2*C2"),
               ("A3", "Dates"), ("B3", "3.50"), ("C3", "2"), ("D3", "=B3*C3"),
               ("A5", "Sum"), ("D5", "=SUM(D1:D3)"),
               ("A6", "Average"), ("D6", "=AVG(D1:D3)")]
  for (name, s) in start:
    let c = parseInt(name[1 .. ^1]) * Cols + ord(name[0]) - ord('A')
    raw[c] = s

seedCells()

# ---- the window ---------------------------------------------------------------------------------

proc sevenGuisFrame*() =
  timerTick()
  tabs(page, ["Counter", "Temperature", "Flight Booker", "Timer", "CRUD",
              "Circle Drawer", "Cells"]):
    case page
    of 0: counterTask()
    of 1: temperatureTask()
    of 2: flightTask()
    of 3: timerTask()
    of 4: crudTask()
    of 5: circleTask()
    else: cellsTask()

when isMainModule and not declared(sevenGuisUnderTest):
  app "7GUIs", 760, 520:
    sevenGuisFrame()

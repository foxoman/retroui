## Widgets for business apps:
##
## - dates: `Date`, `date`, `today`, `addDays`, `addMonths`, `weekday`,
##   `parseDate`; `calendar` and `datePicker`
## - `grid`: a data grid (sort, resize, edit in place, check boxes, cell
##   kinds, totals row, drag and drop of rows); `sortRows`
## - `tree`, `iconView`, `breadcrumb`, `imageView`, `checkList`,
##   `progressBox`
## - `split` / `vsplit` / `sidePane`: two panes with a bar between them
## - `numberEdit`, `intEdit`, `comboEdit` (auto-complete), `form` / `field`,
##   `link`, `buttonRow`
## - dialogs: `inputBox`, `fileDialog` (Open, Save As)
##
## Charts are in `retroui/charts`.
##
## ```nim
## var cols = @[column("Customer", 180), column("Balance", 90, alRight)]
## var rows = @[@["Al Noor Trading", "1,250.000"], @["Sohar Foods", "320.500"]]
## var sel = 0
## var due = today()
## app "Ledger", 600, 400:
##   form 0:
##     field "&Due:": datePicker(due)
##   discard grid(cols, rows, sel, height = 8)
## ```

import std/[strutils, os, algorithm, math, times, hashes]
import std/unicode except strip   # (its strip cuts letters: docs/nim-bugs.md)
import uirelays/target   # (androidApp: an APK, not a program in Termux)
import core, widgets, pixelicons
import uirelays/services

template th: untyped = ui.theme

# ---- dates --------------------------------------------------------------------

type
  Date* = object
    ## A calendar day.
    year*, month*, day*: int     ## month 1..12, day 1..31
  DateStyle* = enum
    ## How dates are written (`dateStyle`).
    dsDMY  ## 27/10/2026
    dsMDY  ## 10/27/2026
    dsISO  ## 2026-10-27

const monthNames* = ["January", "February", "March", "April", "May", "June",
                     "July", "August", "September", "October", "November",
                     "December"]
  ## The months' names in English, January first (`monthNames[d.month - 1]`).

var
  dateStyle* = dsDMY     ## how dates are written and read
  firstWeekday* = 0      ## first column of a calendar: 0 Sunday .. 6 Saturday

proc date*(year, month, day: int): Date = Date(year: year, month: month, day: day)
  ## The day `day` of `month` (1..12) in `year`.

proc isLeap(y: int): bool = (y mod 4 == 0 and y mod 100 != 0) or y mod 400 == 0

proc daysInMonth*(year, month: int): int =
  ## How many days `month` (1..12) of `year` has: 28 to 31.
  case month
  of 2: (if isLeap(year): 29 else: 28)
  of 4, 6, 9, 11: 30
  else: 31

proc valid*(d: Date): bool =
  ## A real day (no 31 April) of the years 1 to 9999.
  d.year in 1..9999 and d.month in 1..12 and d.day in 1..daysInMonth(d.year, d.month)

proc today*(): Date =
  ## The day it is here.
  let n = now()
  Date(year: n.year, month: ord(n.month), day: n.monthday)

proc dayNumber*(d: Date): int =
  ## Days since 1970-01-01.
  let y = d.year - (if d.month <= 2: 1 else: 0)
  let era = (if y >= 0: y else: y - 399) div 400
  let yoe = y - era * 400
  let mp = (d.month + 9) mod 12
  let doy = (153 * mp + 2) div 5 + d.day - 1
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  era * 146097 + doe - 719468

proc fromDayNumber*(n: int): Date =
  ## The day `n` days after 1970-01-01 (the opposite of `dayNumber`).
  let z = n + 719468
  let era = (if z >= 0: z else: z - 146096) div 146097
  let doe = z - era * 146097
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let m = if mp < 10: mp + 3 else: mp - 9
  Date(year: yoe + era * 400 + (if m <= 2: 1 else: 0), month: m,
       day: doy - (153 * mp + 2) div 5 + 1)

proc addDays*(d: Date; n: int): Date = fromDayNumber(dayNumber(d) + n)
  ## `n` days later (earlier when `n` < 0).

proc addMonths*(d: Date; n: int): Date =
  ## `n` months later, on the same day or the month's last (31 January + 1
  ## month = 28 or 29 February).
  let m = d.year * 12 + d.month - 1 + n
  result.year = m div 12
  result.month = m mod 12 + 1
  result.day = min(d.day, daysInMonth(result.year, result.month))

proc weekday*(d: Date): int =
  ## 0 = Sunday .. 6 = Saturday.
  floorMod(dayNumber(d) + 4, 7)

proc `<`*(a, b: Date): bool = dayNumber(a) < dayNumber(b)
  ## `a` is before `b`.
proc `<=`*(a, b: Date): bool = dayNumber(a) <= dayNumber(b)
  ## `a` is before `b` or the same day.

proc `$`*(d: Date): string =
  ## The date as `dateStyle` writes it ("" when it is not valid).
  if not d.valid: return ""
  let dd = intToStr(d.day, 2)
  let mm = intToStr(d.month, 2)
  let yy = intToStr(d.year, 4)
  case dateStyle
  of dsDMY: dd & "/" & mm & "/" & yy
  of dsMDY: mm & "/" & dd & "/" & yy
  of dsISO: yy & "-" & mm & "-" & dd

proc parseDate*(s: string; d: var Date): bool =
  ## Read a date written as `dateStyle` says (or yyyy-mm-dd); false if it
  ## is not a real day.
  var parts: seq[int]
  for p in s.strip.split({'/', '-', '.', ' '}):
    if p.len == 0: continue
    try: parts.add parseInt(p)
    except ValueError: return false
  if parts.len != 3: return false
  var r: Date
  if parts[0] > 31 or dateStyle == dsISO: r = date(parts[0], parts[1], parts[2])
  elif dateStyle == dsMDY: r = date(parts[2], parts[0], parts[1])
  else: r = date(parts[2], parts[1], parts[0])
  if r.year < 100: r.year += 2000
  if not r.valid: return false
  d = r
  true

# ---- calendar ---------------------------------------------------------------

proc calendarSize(): tuple[w, h, cw, ch: int] =
  let cw = if fingers(): dp(36) else: dp(26)
  let ch = ItemH + 3
  (7 * cw + 2, ItemH + 8 + ch + 6 * ch + 4, cw, ch)

proc calendarAt(id: Id; r: Rect; d: var Date; keys, focused, enabled: bool;
                picked: var bool): bool =
  ## A month view at `r`; `keys`: arrow keys move the day.
  let (_, _, cw, ch) = calendarSize()
  var st = state(id)
  let dn = if d.valid: dayNumber(d) else: dayNumber(today())
  if st.caret != dn or st.scrollX == 0:
    st.caret = dn
    let base = if d.valid: d else: today()
    st.scrollX = base.year * 12 + base.month - 1
  var vy = st.scrollX div 12
  var vm = st.scrollX mod 12 + 1
  let head = rect(r.x + 1, r.y + 1, r.w - 2, ItemH + 8)
  let prev = rect(head.x + 3, head.y + 3, head.h - 6, head.h - 6)
  let next = rect(head.x + head.w - head.h + 3, head.y + 3, head.h - 6, head.h - 6)
  var nd = if d.valid: d else: today()
  var changed = false
  if enabled:
    # the month arrows (a click or a tap), the wheel over the month
    if interact(id + 1, prev, focusable = false).clicked: dec st.scrollX
    if interact(id + 2, next, focusable = false).clicked: inc st.scrollX
    if canInput() and mouseIn(r) and ui.wheel != 0 and not ui.wheelUsed:
      ui.wheelUsed = true
      st.scrollX -= ui.wheel
    if keys and canInput() and not ui.keyUsed:
      var k = 0
      case ui.key
      of KeyLeft: k = -1
      of KeyRight: k = 1
      of KeyUp: k = -7
      of KeyDown: k = 7
      of KeyPageUp:
        nd = nd.addMonths(-1)
        changed = true
      of KeyPageDown:
        nd = nd.addMonths(1)
        changed = true
      of KeyHome:
        nd.day = 1
        changed = true
      of KeyEnd:
        nd.day = daysInMonth(nd.year, nd.month)
        changed = true
      of KeyEnter, KeySpace:
        picked = true
        ui.keyUsed = true
      else: discard
      if k != 0:
        nd = nd.addDays(k)
        changed = true
      if changed: ui.keyUsed = true
  vy = st.scrollX div 12
  vm = st.scrollX mod 12 + 1
  let first = date(vy, vm, 1)
  let offset = floorMod(weekday(first) - firstWeekday, 7)
  let grid = rect(r.x + 1, head.y + head.h + ch, 7 * cw, 6 * ch)
  # a day: picked on the press with a mouse, on the tap with a finger
  let gh = interact(id + 3, grid, focusable = false, enabled = enabled)
  if enabled and ((not finger() and gh.down and ui.pressed) or (finger() and gh.clicked)):
    let i = clamp((ui.my - grid.y) div ch, 0, 5) * 7 + clamp((ui.mx - grid.x) div cw, 0, 6)
    nd = first.addDays(i - offset)
    changed = true
    picked = true
  if accessPress != 0 and enabled:
    # (a screen reader picked a day of the month shown)
    for dd in 1 .. daysInMonth(vy, vm):
      if accessPress == accessSubId(id, dayNumber(date(vy, vm, dd))):
        nd = date(vy, vm, dd)
        changed = true
        picked = true
        accessPress = 0
        break
  if changed and nd != d:
    d = nd
    result = true
  if changed:
    st.caret = dayNumber(d)
    st.scrollX = d.year * 12 + d.month - 1
  state(id) = st
  # draw
  fill(r, th.field)
  box(r, th.edge)
  fill(head, th.select)
  let title = monthNames[vm - 1] & " " & $vy
  text(head.x + (head.w - textWidth(title, true)) div 2,
       head.y + (head.h - FontH) div 2, title, th.selectText, true)
  for (b, dir) in [(prev, dLeft), (next, dRight)]:
    buttonFace(b, false, rounded = false, bevel = 1)
    arrow(b.x + b.w div 2, b.y + b.h div 2, dir, th.frame)
  let wy = head.y + head.h
  for c in 0 ..< 7:
    let name = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"][(c + firstWeekday) mod 7]
    text(grid.x + c * cw + (cw - textWidth(name, true)) div 2,
         wy + (ch - FontH) div 2, name, th.fieldText, true)
  hline(grid.x + 2, wy + ch - 1, grid.w - 4, th.line)
  let tn = dayNumber(today())
  let sn = if d.valid: dayNumber(d) else: -1
  for i in 0 ..< 42:
    let day = first.addDays(i - offset)
    let cr = rect(grid.x + (i mod 7) * cw, grid.y + (i div 7) * ch, cw, ch)
    let s = $day.day
    let inMonth = day.month == vm
    var c = if inMonth: th.fieldText else: th.gray
    let dnum = dayNumber(day)
    if dnum == sn:
      fill(inset(cr, 1), th.select)
      c = th.selectText
      if focused: dots(inset(cr, 1), th.selectText)
    elif dnum == tn:
      box(inset(cr, 1), th.edge)
    text(cr.x + (cr.w - textWidth(s)) div 2, cr.y + (cr.h - FontH) div 2, s, c)
  if accessOn:
    # (the month as a table of its days, the picked one selected)
    accessBegin(arTable, title, r, id, (if enabled: {} else: {asDisabled}), takesLabel = true)
    accessNode(arButton, "Previous month", id = id + 1, r = prev)
    accessNode(arButton, "Next month", id = id + 2, r = next)
    for i in 0 ..< 42:
      let day = first.addDays(i - offset)
      if day.month != vm: continue
      let dnum = dayNumber(day)
      let k = accessNode(arCell, $day.day & " " & monthNames[vm - 1] & " " & $vy,
                         id = accessSubId(id, dnum),
                         r = rect(grid.x + (i mod 7) * cw, grid.y + (i div 7) * ch, cw, ch),
                         states = (if dnum == sn: {asSelected} else: {}),
                         help = (if dnum == tn: "today" else: ""))
      if dnum == sn and focused: accessFocus(k)
    accessEnd()

proc calendar*(d: var Date; enabled = true): bool {.discardable.} =
  ## A month calendar bound to `d`: click or tap a day; the arrows move a
  ## day or a week, Page Up / Page Down a month, Home / End the first /
  ## last day; the wheel and the < > buttons show other months.
  let (w, h, _, _) = calendarSize()
  let r = place(w, h)
  let id = idOf(d, "calendar")
  let focused = enabled and ui.focus == id and canInput()
  let pressIn = enabled and hover(r) and ui.pressed and not ui.pressUsed
  var picked = false
  result = calendarAt(id + 1, r, d, focused, focused, enabled, picked)
  discard interact(id, r, enabled = enabled)
  if pressIn: ui.focus = id
  if picked and ui.key in {KeyEnter, KeySpace}: markDouble(id)
  ui.lastId = id
  ui.lastRect = r

proc datePicker*(d: var Date; w = 0; enabled = true): bool {.discardable.} =
  ## A date field (typed in `dateStyle`) with a drop-down calendar (its
  ## button, Enter, Alt+Down or F4; F4, Alt+Up or Esc close it). With the
  ## focus, Up / Down move a day and Page Up / Page Down a month.
  let r = place(if w > 0: w else: textWidth("00/00/0000") + SbW + 18, EditH)
  let id = idOf(d, "datepicker")
  let editId = id + 31
  let popId = id + 7
  var st = state(id)
  if ui.focus != editId: st.buf = $d
  let field = rect(r.x, r.y, r.w - SbW + 1, r.h)
  let btn = rect(r.x + r.w - SbW, r.y, SbW, r.h)
  var buf = st.buf
  if editAt(editId, buf, field, false, false, enabled, {'0'..'9', '/', '-', '.'}):
    var nd: Date
    if parseDate(buf, nd) and nd != d:
      d = nd
      result = true
  st.buf = buf
  state(id) = st
  if enabled and ui.focus == editId: ui.takesEnter = true   # (Enter opens its calendar: #9)
  if enabled and canInput():
    if hover(btn) and takePress():
      ui.popup = if ui.popup == popId: 0 else: popId
      ui.menuOpen = false
      ui.focus = editId
      ui.redraw = true
    if ui.focus == editId and not ui.keyUsed and ui.popup != popId and
       ((ui.key == KeyDown and AltPressed in ui.mods) or ui.key == KeyF4 or ui.key == KeyEnter):
      ui.keyUsed = true
      ui.popup = popId
      ui.redraw = true
    elif ui.focus == editId and not ui.keyUsed and ui.popup != popId and
         ui.key in {KeyUp, KeyDown, KeyPageUp, KeyPageDown}:
      let base = if d.valid: d else: today()
      let nd = case ui.key
               of KeyUp: base.addDays(1)
               of KeyDown: base.addDays(-1)
               of KeyPageUp: base.addMonths(1)
               else: base.addMonths(-1)
      ui.keyUsed = true
      if nd != d:
        d = nd
        st.buf = $d
        state(id) = st
        var es = state(editId)                 # (the box shows the new date, selected)
        es.anchor = 0
        es.caret = st.buf.len
        state(editId) = es
        result = true
  buttonFace(btn, ui.popup == popId, rounded = false, bevel = 1)
  let o = if ui.popup == popId: 1 else: 0
  let c = if enabled: th.frame else: th.gray
  # a tiny calendar page
  let g = rect(btn.x + (btn.w - 9) div 2 + o, btn.y + (btn.h - 9) div 2 + o, 9, 9)
  box(g, c)
  hline(g.x, g.y + 1, g.w, c)
  hline(g.x, g.y + 2, g.w, c)
  for k in 0 .. 2: fill(g.x + 2 + k * 2, g.y + 5, 1, 1, c)
  ui.lastId = editId
  ui.lastRect = r
  if accessOn:
    # (its box says it has a calendar, and whether it is open)
    for k in countdown(accessTree.high, max(0, accessTree.len - 64)):
      if accessTree[k].id == uint32(editId):
        accessTree[k].states.incl asExpandable
        if ui.popup == popId: accessTree[k].states.incl asExpanded
        break
  if ui.popup == popId:
    let (cw, chh, _, _) = calendarSize()
    var pr = rect(r.x, r.y + r.h - 1, cw, chh)
    if pr.y + pr.h > ui.h: pr.y = r.y - chh + 1
    if pr.x + pr.w > ui.w: pr.x = max(0, ui.w - pr.w)
    pushLayer(LayerPopup)
    ui.popupRectNow = pr
    if canInput() and (dropKey() or (ui.key == KeyUp and AltPressed in ui.mods and keyHit(KeyUp))):
      ui.popup = 0                           # (F4, Alt+Down, Alt+Up close it, as Esc does)
      ui.focus = editId
    var picked = false
    if ui.popup == popId and calendarAt(popId, pr, d, true, true, true, picked): result = true
    if picked:
      ui.popup = 0
      ui.redraw = true
      # (the box shows the date picked, selected: the focus stayed in it)
      st.buf = $d
      state(id) = st
      var es = state(editId)
      es.anchor = 0
      es.caret = st.buf.len
      state(editId) = es
    if canInput() and keyHit(KeyEsc):
      ui.popup = 0
      ui.focus = editId                      # (back in the box, as F4 leaves it)
    popLayer()

# ---- grid ---------------------------------------------------------------------

type
  Align* = enum
    ## Where text goes in a cell.
    alLeft, alCenter, alRight
  CellKind* = enum
    ## What the cells of a `grid` column are.
    ckText          ## text (`editable`: edited in place)
    ckNumber        ## a number, right aligned (edited with digits only)
    ckCheck         ## a check box: "1", "true", "yes" or "x" is checked;
                    ## `editable`: a click or Space flips it (`toggled`)
    ckColor         ## a block of color: "#RRGGBB" or a name ("green", "red",
                    ## "orange", "navy"...) -- a status light
    ckProgress      ## a bar: "0.62" or "62%"
    ckChoice        ## text picked from `choices` in a drop-down (`editable`)
    ckButton        ## a push button showing the text (`clicked`)
    ckLink          ## blue underlined text (`clicked`)
    ckIcon          ## an icon: the text is a pixel icon or icon-font glyph
    ckCustom        ## drawn by the column's `paint(row, r, selected)`
  Column* = object
    ## A column of a `grid`; drag its header's edge to resize it.
    title*: string         ## the header
    width*: int            ## design pixels (scaled on the screen)
    align*: Align          ## where the text goes in the cells
    editable*: bool        ## cells are edited in place (F2, a double click, typing)
    kind*: CellKind        ## what the cells are
    choices*: seq[string]  ## ckChoice: what can be picked
    paint*: proc (row: int; r: Rect; selected: bool) {.closure.}
      ## ckCustom: draws the cell in `r` (`fill`, `text`, `image`...)
  CellStyle* = object
    ## The look of one cell (`grid`'s `style`): colors with alpha 0 are the
    ## grid's own.
    fg*, bg*: Color        ## text and background colors
    bold*: bool            ## bold text
  GridEvent* = object
    ## What happened in a `grid` this frame.
    selChanged*: bool      ## `sel` moved
    activated*: bool       ## double click or Enter on a row
    sorted*: bool          ## a header was clicked: sort by `sortColumn`
    sortColumn*: int       ## the column to sort by (`sorted`)
    sortDescending*: bool  ## largest / last first (`sorted`)
    edited*: bool          ## a cell edit was committed: `row`, `col`, `text`
    rightClicked*: bool    ## right click or long press on `row`
    row*, col*: int        ## the cell the event is about
    text*: string          ## the cell's new text (`edited`)
    curCol*: int           ## the current cell's column, every frame (its row: `sel`)
    hot*: int              ## the row under the mouse, -1 if none (not fingers)
    dragStarted*: bool     ## a drag began on `row`: call `startDrag` to carry it
    dropOver*: int         ## a drag is over this row (one `dropOk` takes), else -1
    dropped*: bool         ## something was dropped on `row` (-1: on the empty part)
    toggled*: bool         ## a check box cell was flipped (`edited` too: `text` "1" / "0")
    clicked*: bool         ## a button or link cell was clicked: `row`, `col`

proc column*(title: string; width = 100; align = alLeft;
             editable = false; kind = ckText; choices: openArray[string] = []): Column =
  ## A column of text (or of `kind`); the others below are short cuts.
  Column(title: title, width: width, align: align, editable: editable, kind: kind,
         choices: @choices)

proc numberColumn*(title: string; width = 90; editable = false): Column =
  ## Numbers, right aligned.
  column(title, width, alRight, editable, ckNumber)
proc checkColumn*(title: string; width = 40; editable = true): Column =
  ## Check boxes; a click flips them.
  column(title, width, alCenter, editable, ckCheck)
proc colorColumn*(title: string; width = 34): Column =
  ## Blocks of color (status lights).
  column(title, width, alCenter, false, ckColor)
proc progressColumn*(title: string; width = 100): Column =
  ## Progress bars ("0.62" or "62%").
  column(title, width, alLeft, false, ckProgress)
proc choiceColumn*(title: string; choices: openArray[string]; width = 120;
                   editable = true): Column =
  ## Text picked from `choices` in a drop-down list.
  column(title, width, alLeft, editable, ckChoice, choices)
proc buttonColumn*(title: string; width = 80): Column =
  ## Push buttons showing the text; a click is `clicked`.
  column(title, width, alCenter, false, ckButton)
proc linkColumn*(title: string; width = 100): Column =
  ## Links (blue underlined text); a click is `clicked`.
  column(title, width, alLeft, false, ckLink)
proc iconColumn*(title: string; width = 28): Column =
  ## Icons: the text is a pixel icon ("Sheet", "pxSheet" or `pxSheet`
  ## itself) or an icon-font glyph.
  column(title, width, alCenter, false, ckIcon)

proc iconOfName(s: string): string =
  ## A pixel icon's name ("Sheet", "pxSheet") as its character; anything
  ## else as it is.
  if isPixelIcon(s): return s
  let n = if s.startsWith("px"): s[2 .. ^1] else: s
  let k = pixelIconNames.find(n)
  if k >= 0: pixelIconChar(k) else: s
proc customColumn*(title: string; width: int;
                   paint: proc (row: int; r: Rect; selected: bool)): Column =
  ## Cells drawn by `paint` (a sparkline, a rating, a gauge...).
  result = column(title, width, alLeft, false, ckCustom)
  result.paint = paint

proc cellStyle*(fg = Color(); bg = Color(); bold = false): CellStyle =
  ## A cell's look for `grid`'s `style` (a color left out is the grid's).
  CellStyle(fg: fg, bg: bg, bold: bold)

proc isChecked*(s: string): bool =
  ## How a check box cell reads its text.
  let t = s.strip.toLowerAscii
  t in ["1", "true", "yes", "x", "on", "checked", "y"]

proc namedColor*(s: string): Color =
  ## "#RRGGBB", "#RGB" or a 3.1 palette name ("green", "red", "navy",
  ## "orange"...); alpha 0 when it is none.
  let t = s.strip.toLowerAscii
  if t.len == 0: return
  if t[0] == '#':
    try:
      if t.len == 7:
        return color(uint8(parseHexInt(t[1..2])), uint8(parseHexInt(t[3..4])),
                     uint8(parseHexInt(t[5..6])))
      if t.len == 4:
        return color(uint8(parseHexInt(t[1..1]) * 17), uint8(parseHexInt(t[2..2]) * 17),
                     uint8(parseHexInt(t[3..3]) * 17))
    except ValueError: discard
    return
  case t
  of "black": color(0, 0, 0)
  of "white": color(255, 255, 255)
  of "gray", "grey": color(128, 128, 128)
  of "silver", "lightgray": color(192, 192, 192)
  of "red": color(255, 0, 0)
  of "maroon", "darkred": color(128, 0, 0)
  of "green", "lime": color(0, 220, 0)
  of "darkgreen": color(0, 128, 0)
  of "blue": color(0, 0, 255)
  of "navy": color(0, 0, 128)
  of "yellow": color(255, 255, 0)
  of "olive": color(128, 128, 0)
  of "orange": color(255, 128, 64)
  of "aqua", "cyan": color(0, 255, 255)
  of "teal": color(0, 128, 128)
  of "fuchsia", "magenta", "pink": color(255, 0, 255)
  of "purple": color(128, 0, 128)
  else: Color()

var
  resizing: tuple[id: Id; col, grab: int]
  comboPanned: bool          ## a finger scrolled a comboEdit's list: no pick on release

proc alignedText(r: Rect; s: string; a: Align; c: Color; bold = false) =
  # text wider than its cell ends in "...", as in the lists of Windows
  # (the text itself drawn when it fits: no copy of it every frame)
  template at(tw: int): int =
    (case a
     of alLeft: r.x + 4
     of alCenter: r.x + (r.w - tw) div 2
     of alRight: r.x + r.w - 5 - tw)
  let tw = textWidth(s, bold)
  if tw > r.w - 9 and r.w > 16:
    let cut = ellipsize(s, r.w - 9, TextStyle(bold: bold))
    text(at(textWidth(cut, bold)), r.y + (r.h - FontH) div 2, cut, c, bold)
  else:
    text(at(tw), r.y + (r.h - FontH) div 2, s, c, bold)

var pendingEdit: tuple[on: bool; row, col, selectTo: int]

var press: tuple[id: Id; row, x, y, top: int; band: bool]
var bandBase: seq[bool]     ## the selection when a Ctrl + selection rectangle began
  ## Where the mouse went down in a list: a drag from an item starts a drag
  ## and drop, from the empty part a selection rectangle.

proc gridEdit*(row, col: int; selectTo = -1) =
  ## Open the editor on cell `row`, `col` of the next grid drawn (a
  ## "Rename" command, say). `selectTo`: select only the text before it
  ## (a file name without its extension); -1 selects all.
  pendingEdit = (true, row, col, selectTo)

proc clearMarks(marked: var seq[bool]) =
  for m in marked.mitems: m = false

proc markRange(marked: var seq[bool]; a, b: int; keep: bool) =
  ## Marks the items `a` to `b` (either order), unmarking the others
  ## unless `keep`.
  if not keep: clearMarks(marked)
  for i in min(a, b) .. max(a, b):
    if i >= 0 and i < marked.len: marked[i] = true

proc anyMarked(marked: seq[bool]): bool =
  for m in marked:
    if m: return true

proc typeAhead(ex: var WState; count: int; sel: int;
               name: proc (i: int): string): int =
  ## The item whose name starts with what was typed in the last second.
  result = -1
  if ui.typed.len == 0 or count == 0: return
  if ui.now - ex.aux > 1000: ex.buf.setLen(0)
  ex.aux = ui.now
  let again = ex.buf.len > 0 and ex.buf == ui.typed   # same letter: next one
  if not again: ex.buf.add ui.typed
  let q = unicode.toLower(if again: ui.typed else: ex.buf)
  ui.typed.setLen(0)
  let cur = clamp(sel, -1, count - 1)       # (the app's `sel` may be anything)
  let start = if again or ex.buf.len == 1: cur + 1 else: max(0, cur)
  for k in 0 ..< count:
    let i = (start + k) mod count
    if unicode.toLower(name(i)).startsWith(q): result = i; return

proc listSelect(marked: ptr seq[bool]; sel: var int; ex: var WState; row: int;
                ctrl, shift, toggle: bool): bool =
  ## Selection rules shared by the grid and the icon view: a plain click
  ## selects one item, Ctrl toggles, Shift selects a range; `toggle`
  ## (check box, touch selection mode) flips just this item.
  if marked == nil:
    if sel != row:
      sel = row
      return true
    return false
  if toggle or ctrl:
    marked[][row] = not marked[][row]
    ex.caret = row
  elif shift:
    markRange(marked[], ex.caret, row, false)
  else:
    markRange(marked[], row, row, false)
    ex.caret = row
  sel = row
  true

proc gridCellId(id: Id; row, col: int): Id {.inline.} =
  ## (the id of a cell of the grid `id`, for screen readers)
  accessSubId(id, 0x40000000 + ((row * 256 + col) and 0x3FFFFFFF))

proc gridImpl(colsIn: var seq[Column]; rows: int; cell: proc (row, col: int): string;
              sel: var int; marked: ptr seq[bool]; height, w, sortColumn: int;
              sortDescending, enabled: bool; icon: proc (row: int): Icon;
              typeToEdit, tapActivates, checkboxes: bool;
              dragRows = false; dropOk: proc (row: int): bool = nil;
              styleOf: proc (row, col: int): CellStyle = nil; rowHeaders = false;
              footer: proc (col: int): string = nil;
              editText: proc (row, col: int): string = nil): GridEvent =
  # column widths are design pixels: scaled to the screen here, and a
  # column resized by dragging is stored back unscaled
  var cols = colsIn
  for c in cols.mitems: c.width = dp(c.width)
  defer:
    for i in 0 ..< min(cols.len, colsIn.len):
      if cols[i].width != dp(colsIn[i].width):
        colsIn[i].width = max(16, int(float(cols[i].width) / max(0.1, ui.k) + 0.5))
  result.sortColumn = -1
  result.row = -1
  result.hot = -1
  result.dropOver = -1
  let rowH = ItemH + 2
  let hdrH = ItemH + 4
  # a totals row comes on top of the `height` rows asked for
  let footH = if footer != nil: rowH + 1 else: 0
  let h = if height < 0: remainingH() else: hdrH + height * rowH + footH + 2
  let r = place(if w > 0: w else: 0, h, fill = w <= 0)
  let id = idOf(sel, "grid")
  var st = state(id)
  var ex = state(id + 23)          # caret: range anchor; anchor: last sel + 1
  if marked != nil and marked[].len != rows: marked[].setLen(rows)
  # the record indicator column (the current row's arrow), then the check
  # boxes of `checkboxes`, then the columns; a totals row at the bottom
  let rhW = if rowHeaders: dp(16) else: 0
  let boxW = rhW + (if checkboxes: (if fingers(): dp(28) else: dp(18)) else: 0)
  let iconW = if icon != nil: max(20, ItemH + 2) else: 0
  var totalW = boxW
  for c in cols: totalW += c.width
  var vBar, hBar = false
  for _ in 0 .. 1:
    let aw = r.w - 2 - (if vBar: SbW - 1 else: 0)
    let ah = r.h - 2 - (if hBar: SbW - 1 else: 0)
    hBar = totalW > aw
    vBar = rows * rowH > max(1, ah - hdrH - footH)
  let area = rect(r.x + 1, r.y + 1, r.w - 2 - (if vBar: SbW - 1 else: 0),
                  r.h - 2 - (if hBar: SbW - 1 else: 0))
  let viewH = max(1, area.h - hdrH - footH)
  let vis = max(1, viewH div rowH)
  # the rows scroll by the pixel (`oy`), smoothly (see `scrollTo`)
  let maxOy = max(0, rows * rowH - viewH)
  let maxX = max(0, totalW - area.w)
  let sxId = id + 26                         # (the sideways scroller)
  var oy = clamp(st.scrollY, 0, maxOy)
  var sx = clamp(st.scrollX, 0, maxX)
  if vBar:
    scrollBarFor(id + 9, id, rect(r.x + r.w - SbW, r.y, SbW,
                 r.h - (if hBar: SbW - 1 else: 0)), true, oy,
                 maxOy, max(rowH, viewH - rowH), rowH, enabled)
  if hBar:
    scrollBarFor(id + 15, sxId, rect(r.x, r.y + r.h - SbW,
                 r.w - (if vBar: SbW - 1 else: 0), SbW), false, sx,
                 maxX, max(10, area.w - 20), dp(20), enabled)
  var top = oy div rowH                      # the first row (partly) in view
  let body = rect(area.x, area.y + hdrH, area.w, area.h - hdrH - footH)
  if sortColumn >= 0:
    st.aux = sortColumn + 1
    st.aux2 = ord(sortDescending)
  let hit = interact(id, body, enabled = enabled)
  var curCol = clamp(st.caret, 0, max(0, cols.high))
  # (what an edit starts with: the cell's text, or `editText`'s -- a
  # spreadsheet's formula where the cell shows its value)
  proc editOf(row, col: int): string =
    if editText != nil: editText(row, col) else: cell(row, col)
  let editId = id + 21
  let choiceKey = "grid-choice:" & $id
  template textEditable(c: int): bool =
    cols[c].editable and cols[c].kind in {ckText, ckNumber}
  template rowY(ri: int): int = body.y + (ri) * rowH - oy
  template rowAt(py: int): int = (py - body.y + oy) div rowH
  template cellRectOf(ri, ci: int): Rect =
    block:
      var cxx = x0
      for k in 0 ..< ci: cxx += cols[k].width
      rect(cxx, rowY(ri), cols[ci].width, rowH)
  template toggle(ri, ci: int) =
    result.edited = true
    result.toggled = true
    result.row = ri
    result.col = ci
    result.text = if isChecked(cell(ri, ci)): "0" else: "1"
  template openChoices(ri, ci: int) =
    let cr = cellRectOf(ri, ci)
    var es = state(id + 25)
    es.caret = ri
    es.anchor = ci
    state(id + 25) = es
    openPopupMenu(choiceKey, cr.x, cr.y + cr.h)
  var editing = st.anchor == 1
  var nsel = sel
  var follow = ex.anchor != sel + 1          # moved by the app: show it
  let appMoved = follow                      # (at once; moved here: it glides)
  let x0 = area.x - sx + boxW                # where the first column starts
  template commit() =
    result.edited = true
    result.row = sel
    result.col = curCol
    result.text = st.buf
    st.anchor = 0
    editing = false
  template startEdit(initial: string; selectAll: bool; upTo = -1) =
    if cols.len > 0 and sel >= 0 and sel < rows:
      st.anchor = 1
      st.buf = initial
      editing = true
      ui.focus = editId
      var es = state(editId)
      es.caret = if upTo >= 0: min(upTo, initial.len) else: initial.len
      es.anchor = if selectAll or upTo >= 0: 0 else: initial.len
      es.aux = 1
      state(editId) = es
  if pendingEdit.on and pendingEdit.row in 0 ..< rows and
     pendingEdit.col in 0 ..< cols.len:
    pendingEdit.on = false
    sel = pendingEdit.row
    nsel = sel
    curCol = pendingEdit.col
    follow = true
    if cols[curCol].kind in {ckText, ckNumber}:
      startEdit(editOf(sel, curCol), true, pendingEdit.selectTo)
  # headers: click sorts, edge drag resizes
  var hdrHit = -1
  if enabled and canInput():
    var x = x0
    for i in 0 ..< cols.len:
      let hr = rect(x, area.y, cols[i].width, hdrH)
      let edge = rect(x + cols[i].width - 3, area.y, 6, hdrH)
      if mouseIn(edge) and resizing.id == 0: ui.cursor = curSizeWE
      if hover(edge) and takePress():
        resizing = (id, i, ui.mx - (x + cols[i].width))
        ui.active = id + 30
        ui.dragsActive = true
      elif hover(hr) and takePress():
        ui.active = id + 40 + i.uint32
      if ui.active == id + 40 + i.uint32 and ui.released and mouseIn(hr):
        hdrHit = i
      x += cols[i].width
  if resizing.id == id:
    if ui.mouseDown:
      ui.cursor = curSizeWE
      var left = x0
      for i in 0 ..< resizing.col: left += cols[i].width
      cols[resizing.col].width = max(16, ui.mx - resizing.grab - left)
    else:
      resizing.id = 0
  if hdrHit >= 0:
    if st.aux == hdrHit + 1: st.aux2 = 1 - st.aux2
    else:
      st.aux = hdrHit + 1
      st.aux2 = 0
    result.sorted = true
    result.sortColumn = hdrHit
    result.sortDescending = st.aux2 == 1
  # body
  template colAt(px: int): int =
    var at = max(0, cols.high)
    var x = x0
    for i in 0 ..< cols.len:
      if px < x + cols[i].width:
        at = i
        break
      x += cols[i].width
    at
  let shift = ShiftPressed in ui.mods
  let ctrl = CtrlPressed in ui.mods     # (a Mac's Cmd: its driver reports it as Ctrl)
  if enabled and canInput():
    scrollWheel(sxId, sx, maxX, r, 3 * rowH, sideways = true)
    scrollWheel(id, oy, maxOy, r, 3 * rowH)
    scrollPan2(id, oy, maxOy, sxId, sx, maxX, r)
    top = oy div rowH
    if tapped(id, hit):
      let ri = rowAt(ui.my)
      let ci = colAt(ui.mx)
      let onBox = checkboxes and ui.mx < area.x - sx + boxW
      if not finger():
        press = (id, (if ri < rows: ri else: -1), ui.mx, ui.my, oy, false)
        if ri >= rows and marked != nil and not ctrl and not shift and anyMarked(marked[]):
          clearMarks(marked[])                       # a click below the rows
          result.selChanged = true
      # cells that act: a check box flips, a button or a link is clicked,
      # a drop-down cell of the current row opens its list
      let onCell = ri < rows and not onBox and ui.mx >= x0 and cols.len > 0
      let actsCell = onCell and cols[ci].kind in {ckCheck, ckButton, ckLink}
      if onCell and cols[ci].kind == ckCheck and cols[ci].editable and
         not (ui.clicks >= 2 and not finger()):
        toggle(ri, ci)
      elif onCell and cols[ci].kind in {ckButton, ckLink}:
        result.clicked = true
        result.row = ri
        result.col = ci
      elif onCell and cols[ci].kind == ckChoice and cols[ci].editable and
           ri == sel and ci == curCol and cols[ci].choices.len > 0:
        openChoices(ri, ci)
      if editing and ri == sel and ci == curCol:
        ui.focus = editId          # a click into the open editor
        ui.active = editId
      elif ri < rows:
        if editing: commit()
        let selecting = marked != nil and
                        (onBox or (finger() and (checkboxes or anyMarked(marked[]))))
        if marked != nil and marked[][ri] and not ctrl and not shift and
           not selecting and not finger():
          # a click on a selected row keeps the selection (it may be dragged)
          nsel = ri
          ex.caret = ri
        elif listSelect(marked, nsel, ex, ri, ctrl and not finger(),
                        shift and not finger(), selecting):
          result.selChanged = true
        curCol = ci
        if not selecting and not actsCell:
          if ui.clicks >= 2 or (finger() and tapActivates):
            if ui.clicks >= 2 and typeToEdit and cols.len > 0 and
               textEditable(curCol):
              sel = nsel
              startEdit(editOf(nsel, curCol), true)
            elif ui.clicks >= 2 and cols.len > 0 and cols[curCol].kind == ckChoice and
                 cols[curCol].editable and cols[curCol].choices.len > 0:
              sel = nsel
              openChoices(nsel, curCol)
            else:
              result.activated = true
              result.row = ri
              markDouble(id)
              # a tap that opens leaves nothing selected (else the next tap
              # would only add to a selection, as in touch selection mode)
              if finger() and tapActivates and marked != nil: clearMarks(marked[])
    # a click on a selected row that did not become a drag: just that row
    if press.id == id and press.row >= rows: press.id = 0   # the rows changed meanwhile
    if press.id == id and ui.released and not press.band and press.row >= 0 and
       press.row < rows and marked != nil and not ctrl and not shift and
       marked[][press.row]:
      var others = false
      for k, m in marked[]:
        if m and k != press.row: others = true
      if others:
        markRange(marked[], press.row, press.row, false)
        result.selChanged = true
    # the mouse dragged from where it went down: a drag and drop from a
    # row, a selection rectangle from the empty part
    if press.id == id and ui.mouseDown and ui.active == id and not editing:
      if abs(ui.mx - press.x) + abs(ui.my - press.y) > dp(6) or press.band:
        if press.row >= 0:
          if dragRows:
            result.dragStarted = true
            result.row = press.row
          press.id = 0
        elif marked != nil:
          if not press.band: bandBase = marked[]
          press.band = true
          let a = press.y - body.y + press.top
          let b = ui.my - body.y + oy
          let r0 = clamp(min(a, b) div rowH, 0, max(0, rows - 1))
          let r1 = clamp(max(a, b) div rowH, 0, max(0, rows - 1))
          if ctrl and bandBase.len == marked[].len: marked[] = bandBase
          else: clearMarks(marked[])
          if rows > 0 and min(a, b) < rows * rowH:
            markRange(marked[], r0, r1, true)
          result.selChanged = true
          # near an edge: it scrolls on, a little each frame
          if ui.my < body.y + rowH div 2 and oy > 0:
            scrollStop(id)
            oy = max(0, oy - max(2, rowH div 3))
            wakeIn(16)
          elif ui.my > body.y + body.h - rowH div 2 and oy < maxOy:
            scrollStop(id)
            oy = min(maxOy, oy + max(2, rowH div 3))
            wakeIn(16)
    if press.id == id and not ui.mouseDown: press.id = 0
    # a drag and drop over the grid: on a row that takes it, or the rest
    if dragging() and mouseIn(body):
      if ui.my < body.y + rowH div 2 and oy > 0:
        scrollStop(id)
        oy = max(0, oy - max(2, rowH div 4))
        wakeIn(16)
      elif ui.my > body.y + body.h - rowH div 2 and oy < maxOy:
        scrollStop(id)
        oy = min(maxOy, oy + max(2, rowH div 4))
        wakeIn(16)
      let ri = rowAt(ui.my)
      if dropOk != nil:
        if ri < rows and dropOk(ri):
          case dropTarget(rect(area.x, rowY(ri), area.w, rowH))
          of dsOver: result.dropOver = ri
          of dsDropped:
            result.dropped = true
            result.row = ri
          else: discard
        elif dropOk(-1):
          case dropTarget(body)
          of dsOver: result.dropOver = -2
          of dsDropped:
            result.dropped = true
            result.row = -1
          else: discard
    elif not ui.mouseDown and canHover() and mouseIn(body) and not editing:
      let ri = rowAt(ui.my)
      if ri < rows: result.hot = ri
    # the menu key: the menu is for the current row (scrolled into view)
    if ui.menuKey and hit.focused and rows > 0:
      let cur = clamp(nsel, 0, rows - 1)
      scrollStop(id)
      oy = clamp(clamp(oy, (cur + 1) * rowH - viewH, cur * rowH), 0, maxOy)
      ui.my = rowY(cur) + rowH div 2
      ui.mx = body.x + min(body.w div 2, dp(60))
    # right click or long press: the row under it (the context menu after
    # the grid shows for it)
    if ui.rpressed and mouseIn(body):
      let ri = rowAt(ui.my)
      if ri < rows:
        if marked != nil and not marked[][ri]: markRange(marked[], ri, ri, false)
        if nsel != ri or marked != nil: result.selChanged = true
        nsel = ri
        ex.caret = ri
        result.rightClicked = true
        result.row = ri
        ui.focus = id
        # a finger held on a row: moving it now drags the row (`lifted`)
        if finger() and dragRows: press = (id, ri, ui.mx, ui.my, oy, false)
    if lifted() and press.id == id and press.row >= 0 and dragRows and not editing:
      result.dragStarted = true
      result.row = press.row
      press.id = 0
  if hit.focused and not ui.touch and typeToEdit and cols.len > 0 and
     textEditable(curCol):
    ui.takesText = true
  if editing: ui.takesEnter = true   # (Enter ends the edit, not a dialog: #9)
  if hit.focused and not editing and canInput() and rows > 0:
    var moved = -1
    # (a drop-down cell opens as every drop-down does: F4, Alt+Down, Enter)
    let onChoice = sel >= 0 and sel < rows and cols.len > 0 and cols[curCol].kind == ckChoice and
                   cols[curCol].editable and cols[curCol].choices.len > 0
    if onChoice: ui.takesEnter = true
    case ui.key
    of KeyUp: moved = max(0, sel - 1)
    of KeyDown:
      if AltPressed in ui.mods and onChoice:
        openChoices(sel, curCol)
        ui.keyUsed = true
      else: moved = min(rows - 1, sel + 1)
    of KeyPageUp: moved = max(0, sel - vis + 1)
    of KeyPageDown: moved = min(rows - 1, sel + vis - 1)
    of KeyHome: moved = 0
    of KeyEnd: moved = rows - 1
    of KeyLeft: curCol = max(0, curCol - 1); follow = true; ui.keyUsed = true
    of KeyRight: curCol = min(cols.high, curCol + 1); follow = true; ui.keyUsed = true
    of KeyEnter:
      if AltPressed in ui.mods: discard      # Alt+Enter: properties
      elif onChoice and ui.mods * {CtrlPressed, ShiftPressed} == {}:
        openChoices(sel, curCol)
        ui.keyUsed = true
      else:
        result.activated = true
        result.row = sel
        markDouble(id)
        ui.keyUsed = true
    of KeyF2, KeyF4:
      if sel >= 0 and sel < rows and cols.len > 0 and textEditable(curCol):
        startEdit(editOf(sel, curCol), true)
      elif onChoice:
        openChoices(sel, curCol)
      ui.keyUsed = true
    of KeySpace:
      # Space flips the current check box cell; else it selects the current
      # row, Ctrl+Space flips it
      if sel in 0 ..< rows and cols.len > 0 and cols[curCol].kind == ckCheck and
         cols[curCol].editable:
        toggle(sel, curCol)
        ui.keyUsed = true
      elif sel in 0 ..< rows and cols.len > 0 and cols[curCol].kind in {ckButton, ckLink}:
        result.clicked = true
        result.row = sel
        result.col = curCol
        ui.keyUsed = true
      elif marked != nil and sel in 0 ..< rows and (ctrl or not marked[][sel]):
        marked[][sel] = if ctrl: not marked[][sel] else: true
        result.selChanged = true
        ui.keyUsed = true
    of KeyA:
      if marked != nil and ctrl:
        markRange(marked[], 0, rows - 1, false)
        result.selChanged = true
        ui.keyUsed = true
    else: discard
    if moved >= 0:
      ui.keyUsed = true
      follow = true
      if marked != nil and not ctrl:
        if shift: markRange(marked[], ex.caret, moved, false)
        else:
          markRange(marked[], moved, moved, false)
          ex.caret = moved
        result.selChanged = true
      nsel = moved
    if ui.typed.len > 0 and not editing:
      if typeToEdit and cols.len > 0 and textEditable(curCol):
        startEdit(ui.typed, false)
        ui.typed.setLen(0)
      elif cols.len > 0:
        let i = typeAhead(ex, rows, sel, proc (i: int): string = cell(i, 0))
        if i >= 0:
          nsel = i
          follow = true
          if marked != nil:
            markRange(marked[], i, i, false)
            ex.caret = i
            result.selChanged = true
  if accessPress != 0 and enabled:
    # (a screen reader picked a row, or a cell of it)
    for ri in top ..< min(rows, top + vis + 2):
      var at = -1
      if accessPress == accessSubId(id, ri): at = curCol
      else:
        for ci in 0 ..< cols.len:
          if accessPress == gridCellId(id, ri, ci): at = ci
      if at >= 0:
        accessPress = 0
        nsel = ri
        curCol = at
        ui.focus = id
        if marked != nil:
          markRange(marked[], ri, ri, false)
          ex.caret = ri
          result.selChanged = true
        break
  if nsel != sel and nsel >= 0 and nsel < rows:
    sel = nsel
    result.selChanged = true
    follow = true
  if follow and sel >= 0:
    if appMoved and not scrolling(id):
      oy = clamp(clamp(oy, (sel + 1) * rowH - viewH, sel * rowH), 0, maxOy)
    else:
      scrollShow(id, oy, sel * rowH, (sel + 1) * rowH, viewH, maxOy)
    var cx = boxW
    for i in 0 ..< curCol: cx += cols[i].width
    if curCol < cols.len:
      scrollShow(sxId, sx, cx, min(cx + cols[curCol].width, cx + area.w), area.w, maxX)
  scrollTick(id, oy, maxOy)
  scrollTick(sxId, sx, maxX)
  top = oy div rowH
  ex.anchor = sel + 1
  st.caret = curCol
  result.curCol = curCol
  st.scrollY = oy
  st.scrollX = sx
  # draw
  let fr = rect(r.x, r.y, area.w + 2, area.h + 2)   # without the scroll bars
  fill(fr, th.field)
  fieldFrame(fr, enabled)
  if vBar and hBar:
    fill(r.x + r.w - SbW, r.y + r.h - SbW, SbW, SbW, th.face)
  pushClip(area)
  if boxW > 0:
    fill(area.x - sx, area.y, boxW, hdrH, th.face)
    hline(area.x - sx, area.y + hdrH - 1, boxW, th.edge)
    vline(area.x - sx + boxW - 1, area.y, hdrH, th.edge)
    if rhW > 0: vline(area.x - sx + rhW - 1, area.y, hdrH, th.edge)
  var x = x0
  for i in 0 ..< cols.len:
    let hr = rect(x, area.y, cols[i].width, hdrH)
    let down = ui.active == id + 40 + i.uint32 and ui.mouseDown and mouseIn(hr)
    fill(hr, th.face)
    if down:
      hline(hr.x, hr.y, hr.w, th.shadow)
      vline(hr.x, hr.y, hr.h, th.shadow)
    else:
      hline(hr.x, hr.y, hr.w - 1, th.light)
      vline(hr.x, hr.y, hr.h - 1, th.light)
    hline(hr.x, hr.y + hr.h - 1, hr.w, th.shadow)
    vline(hr.x + hr.w - 1, hr.y, hr.h, th.shadow)
    let arrowW = if st.aux == i + 1: 10 else: 0
    pushClip(intersect(rect(hr.x + 1, hr.y, hr.w - 2 - arrowW, hr.h), area))
    alignedText(rect(hr.x + (if down: 1 else: 0), hr.y + (if down: 1 else: 0),
                     hr.w - arrowW, hr.h), tr(cols[i].title), cols[i].align, th.text)
    popClip()
    if st.aux == i + 1:
      arrow(hr.x + hr.w - 8, hr.y + hr.h div 2,
            if st.aux2 == 1: dDown else: dUp, th.text, 3)
    x += cols[i].width
  if x < area.x + area.w:
    fill(x, area.y, area.x + area.w - x, hdrH, th.face)
    hline(x, area.y + hdrH - 1, area.x + area.w - x, th.shadow)
  pushClip(body)
  let rowW = min(area.w, x - area.x)
  for ri in top ..< min(rows, top + vis + 2):
    let y = rowY(ri)
    let selected = if marked != nil: marked[][ri] else: ri == sel
    if selected:
      fill(rect(area.x, y, rowW, rowH), if enabled: th.select else: th.gray)
    elif enabled and not editing and hovered(rect(area.x, y, area.w, rowH)):
      fill(rect(area.x, y, rowW, rowH), hoverColor())
    let fg = if selected: th.selectText elif enabled: th.fieldText else: th.gray
    if rhW > 0:
      # the record indicator: the current row's arrow, a pencil while it is edited
      let hr = rect(area.x - sx, y, rhW, rowH)
      fill(hr, th.face)
      vline(hr.x + hr.w - 1, y, rowH, th.edge)
      hline(hr.x, y + rowH - 1, hr.w, th.edge)
      if ri == sel:
        if editing:
          text(hr.x + (hr.w - textWidth("*", true)) div 2, itemTextY(y), "*", th.text, true)
        else: arrow(hr.x + hr.w div 2, y + rowH div 2, dRight, th.text, 4)
    if boxW > rhW:
      let bs = dp(13)
      checkBox(rect(area.x - sx + rhW + (boxW - rhW - bs) div 2, y + (rowH - bs) div 2,
                    bs, bs), marked != nil and marked[][ri], false, enabled)
    var cx = x0
    for ci in 0 ..< cols.len:
      var cr = rect(cx, y, cols[ci].width, rowH)
      if cr.x + cr.w > area.x and cr.x < area.x + area.w:
        let cs = if styleOf != nil: styleOf(ri, ci) else: CellStyle()
        if cs.bg.a != 0 and not selected: fill(rect(cr.x, cr.y, cr.w - 1, cr.h - 1), cs.bg)
        let cfg = if selected or cs.fg.a == 0: fg else: cs.fg
        pushClip(intersect(rect(cr.x, cr.y, cr.w - 1, cr.h), body))
        if ci == 0 and icon != nil:
          let ic = icon(ri)
          if ic.w > 0: image(cr.x + 2, y + (rowH - ic.h) div 2, ic)
          cr.x += iconW
          cr.w -= iconW
        let v = cell(ri, ci)
        case cols[ci].kind
        of ckText, ckNumber, ckChoice:
          alignedText(cr, v, cols[ci].align, cfg, cs.bold)
          if cols[ci].kind == ckChoice and cols[ci].editable and ri == sel and
             ci == curCol and hit.focused:
            # the drop-down button of the current cell
            let bw = min(SbW, cr.w div 2)
            let br = rect(cr.x + cr.w - bw - 1, cr.y, bw, cr.h - 1)
            buttonFace(br, false, rounded = false, bevel = 1)
            arrow(br.x + br.w div 2, br.y + br.h div 2, dDown, th.text, 3)
        of ckCheck:
          let bs = dp(13)
          let bx = case cols[ci].align
                   of alLeft: cr.x + 4
                   of alRight: cr.x + cr.w - bs - 5
                   of alCenter: cr.x + (cr.w - bs) div 2
          checkBox(rect(bx, y + (rowH - bs) div 2, bs, bs), isChecked(v), false,
                   enabled and cols[ci].editable)
        of ckColor:
          let c = namedColor(v)
          if c.a != 0:
            let b = rect(cr.x + 1, cr.y + 1, cr.w - 3, cr.h - 3)
            fill(b, c)
        of ckProgress:
          var f = 0.0
          let t = v.strip
          try:
            f = if t.endsWith("%"): parseFloat(t[0 ..< ^1]) / 100 else: parseFloat(t)
          except ValueError: f = 0.0
          f = clamp(f, 0.0, 1.0)
          let b = rect(cr.x + 3, cr.y + 3, cr.w - 7, cr.h - 7)
          fill(b, th.field)
          box(b, th.edge)
          let done = rect(b.x + 1, b.y + 1, int(float(b.w - 2) * f), b.h - 2)
          fill(done, if cs.fg.a != 0: cs.fg else: th.select)
          let pt = $int(f * 100 + 0.5) & "%"
          let small = style(size = 0.85)
          let tx = b.x + (b.w - textWidth(pt, small)) div 2
          let ty = b.y + (b.h - lineHeight(small)) div 2
          # the figure in two colors, as on a 3.1 gauge: light over the bar
          pushClip(rect(done.x + done.w, b.y, b.x + b.w - done.x - done.w, b.h))
          text(tx, ty, pt, th.text, small)
          popClip()
          pushClip(done)
          text(tx, ty, pt, th.selectText, small)
          popClip()
        of ckButton:
          let b = rect(cr.x + 2, cr.y + 1, cr.w - 5, cr.h - 3)
          let down = ui.active == id and ui.mouseDown and mouseIn(b) and press.id == id and
                     press.row == ri
          buttonFace(b, down, rounded = false, bevel = 1, hot = enabled and hovered(b))
          let small = style(size = 0.9)
          text(b.x + (b.w - textWidth(v, small)) div 2 + ord(down),
               b.y + (b.h - lineHeight(small)) div 2 + ord(down), v, th.text, small)
        of ckLink:
          let lc = if selected: th.selectText else: color(0, 0, 238)
          alignedText(cr, v, cols[ci].align, lc, cs.bold)
          let tw = textWidth(v, cs.bold)
          let lx = case cols[ci].align
                   of alLeft: cr.x + 4
                   of alCenter: cr.x + (cr.w - tw) div 2
                   of alRight: cr.x + cr.w - 5 - tw
          hline(lx, cr.y + (cr.h - FontH) div 2 + FontAscent + 2, tw, lc)
        of ckCustom:
          if cols[ci].paint != nil: cols[ci].paint(ri, cr, selected)
        of ckIcon:
          if v.len > 0:
            let k = min(cr.h - 2, max(16, FontH + 2))
            image(cr.x + (cr.w - k) div 2, cr.y + (cr.h - k) div 2,
                  glyphIcon(iconOfName(v), cfg, k))
        popClip()
      vline(cx + cols[ci].width - 1, y, rowH, th.face)
      cx += cols[ci].width
    hline(area.x, y + rowH - 1, rowW, th.face)
    if ri == sel and hit.focused and curCol < cols.len:
      var fx = x0
      for i in 0 ..< curCol: fx += cols[i].width
      dots(rect(fx, y, cols[curCol].width - 1, rowH - 1),
           if selected: th.selectText else: th.fieldText)
    if result.dropOver == ri: dropHighlight(rect(area.x, y, area.w, rowH))
  # the selection rectangle
  if press.id == id and press.band:
    let by = press.y + press.top - oy
    box(rect(min(press.x, ui.mx), min(by, ui.my), abs(ui.mx - press.x) + 1,
             abs(ui.my - by) + 1), th.select)
  popClip()
  if result.dropOver == -2: dropHighlight(body)
  # the totals row
  if footH > 0:
    let fy = area.y + area.h - footH
    fill(rect(area.x, fy, area.w, footH), th.face)
    hline(area.x, fy, area.w, th.edge)
    var fx = x0
    for ci in 0 ..< cols.len:
      let fr = rect(fx, fy + 1, cols[ci].width, rowH)
      if fr.x + fr.w > area.x and fr.x < area.x + area.w:
        pushClip(intersect(rect(fr.x, fr.y, fr.w - 1, fr.h), area))
        alignedText(fr, footer(ci), cols[ci].align, th.text, true)
        popClip()
      vline(fx + cols[ci].width - 1, fy + 1, rowH, th.shadow)
      fx += cols[ci].width
  popClip()
  if accessOn:
    # (a table: its headers, the rows in view and their cells; the current
    # cell has the focus)
    accessBegin(arTable, "", fr, id, (if enabled: {} else: {asDisabled}), takesLabel = true)
    var hx = x0
    for i in 0 ..< cols.len:
      accessNode(arColumnHeader, tr(cols[i].title), id = accessSubId(id, 0x3F000000 + i),
                 r = rect(hx, area.y, cols[i].width, hdrH))
      hx += cols[i].width
    for ri in top ..< min(rows, top + vis + 2):
      let y = rowY(ri)
      let selected = if marked != nil: marked[][ri] else: ri == sel
      let k = accessBegin(arRow, "", rect(area.x, y, rowW, rowH), accessSubId(id, ri),
                          (if selected: {asSelected} else: {}))
      accessItem(k, ri + 1, rows)
      var cx = x0
      for ci in 0 ..< cols.len:
        let v = cell(ri, ci)
        var name = v
        var st2: set[AccessState] = {}
        case cols[ci].kind
        of ckCheck:
          name = tr(cols[ci].title)
          if isChecked(v): st2.incl asChecked
        of ckColor, ckIcon, ckButton, ckLink, ckCustom: discard
        of ckProgress:
          var f = 0.0
          let t = v.strip
          try: f = if t.endsWith("%"): parseFloat(t[0 ..< ^1]) / 100 else: parseFloat(t)
          except ValueError: f = 0.0
          name = $int(clamp(f, 0.0, 1.0) * 100 + 0.5) & "%"
        else: discard
        let c = accessNode(case cols[ci].kind
                           of ckCheck: arCheckBox
                           of ckButton: arButton
                           of ckLink: arLink
                           else: arCell,
                           name, id = gridCellId(id, ri, ci),
                           r = rect(cx, y, cols[ci].width, rowH), states = st2,
                           help = tr(cols[ci].title))
        if ri == sel and ci == curCol and hit.focused and not editing: accessFocus(c)
        cx += cols[ci].width
      accessEnd()
    accessEnd()
  # the drop-down list of a choice cell
  popupMenu(choiceKey):
    let es = state(id + 25)
    if es.caret in 0 ..< rows and es.anchor in 0 ..< cols.len:
      let cur = cell(es.caret, es.anchor)
      for c in cols[es.anchor].choices:
        if menuItem(c.replace("&", "&&"), checked = c == cur):
          result.edited = true
          result.row = es.caret
          result.col = es.anchor
          result.text = c
  # in-place editing
  if editing:
    let gone = ui.focus != editId and ui.focus != id
    var fx = x0
    for i in 0 ..< curCol: fx += cols[i].width
    let shiftIcon = if curCol == 0: iconW else: 0
    let er = rect(fx - 1 + shiftIcon, rowY(sel) - 2,
                  cols[curCol].width + 1 - shiftIcon, rowH + 3)
    var buf = st.buf
    pushClip(rect(area.x - 1, body.y - 2, area.w + 2, body.h + 4))
    discard editAt(editId, buf, er, false, false, true,
                   right = cols[curCol].align == alRight)
    popClip()
    st.buf = buf
    if gone or (canInput() and ui.focus == editId and keyHit(KeyEnter)):  # (Enter claimed above)
      commit()
      if not gone: ui.focus = id
    elif canInput() and ui.focus == editId and keyHit(KeyEsc):
      st.anchor = 0
      ui.focus = id
  else:
    st.anchor = 0
  state(id) = st
  state(id + 23) = ex
  ui.lastId = id
  ui.lastRect = r

proc grid*(cols: var seq[Column]; rows: int; cell: proc (row, col: int): string;
           sel: var int; height = 10; w = 0; sortColumn = -1;
           sortDescending = false; enabled = true;
           icon: proc (row: int): Icon = nil; typeToEdit = true;
           tapActivates = false; style: proc (row, col: int): CellStyle = nil;
           rowHeaders = false; footer: proc (col: int): string = nil;
           editText: proc (row, col: int): string = nil): GridEvent
          {.discardable.} =
  ## A table of `rows` rows; `cell(row, col)` gives the text of the cells
  ## on screen (so a million rows cost what the visible ones cost). Click a
  ## header to sort, drag its edge to resize; arrows, Enter, F2 to edit an
  ## `editable` cell (or just type). `height` is in rows (-1 fills).
  ## `sortColumn`, `sortDescending`: the order the rows are in, for the
  ## arrow in the header (else the grid remembers the last header click).
  ## `icon(row)`: a 16x16 icon before the first column's text.
  ## `typeToEdit` false: typing jumps to the row that starts with it.
  ## `tapActivates`: on a touch screen one tap opens a row (as in a file
  ## manager), not two.
  ##
  ## Columns can hold more than text (`Column.kind`: `checkColumn`,
  ## `colorColumn`, `progressColumn`, `choiceColumn`, `buttonColumn`,
  ## `linkColumn`, `iconColumn`, `numberColumn`): a check box cell flips on
  ## a click or Space (`toggled`, `edited` with "1" / "0"), a drop-down cell
  ## opens its `choices` (F4, Alt+Down, Enter, a click on the current cell;
  ## `edited`), a button or link reports `clicked`. `style(row, col)` gives cells their
  ## own colors and weight; `rowHeaders` adds the record indicator column
  ## (an arrow at the current row); `footer(col)` a totals row.
  ## `editText(row, col)`: what an edit of a cell starts with, when it is
  ## not the text shown (a formula, its value in the cell). The result's
  ## `curCol` is the current cell's column.
  gridImpl(cols, rows, cell, sel, nil, height, w, sortColumn, sortDescending,
           enabled, icon, typeToEdit, tapActivates, false,
           styleOf = style, rowHeaders = rowHeaders, footer = footer, editText = editText)

proc grid*(cols: var seq[Column]; rows: int; cell: proc (row, col: int): string;
           sel: var int; marked: var seq[bool]; height = 10; w = 0;
           sortColumn = -1; sortDescending = false; enabled = true;
           icon: proc (row: int): Icon = nil; typeToEdit = true;
           tapActivates = false; checkboxes = false; dragRows = false;
           dropOk: proc (row: int): bool = nil;
           style: proc (row, col: int): CellStyle = nil; rowHeaders = false;
           footer: proc (col: int): string = nil;
           editText: proc (row, col: int): string = nil): GridEvent {.discardable.} =
  ## A grid where many rows can be selected: `marked[row]`; `sel` is the
  ## row with the focus. Ctrl+click toggles a row, Shift+click selects a
  ## range, Ctrl+A all, dragging from below the rows draws a selection
  ## rectangle; `checkboxes` adds a check box to every row. On a touch
  ## screen, once a row is marked (long press, or its check box), taps mark
  ## more rows. `dragRows`: dragging a row reports `dragStarted` (call
  ## `startDrag`); `dropOk(row)` says which rows take a drop (-1: the empty
  ## part), reported as `dropOver` and `dropped`.
  gridImpl(cols, rows, cell, sel, addr marked, height, w, sortColumn,
           sortDescending, enabled, icon, typeToEdit, tapActivates, checkboxes,
           dragRows, dropOk, style, rowHeaders, footer, editText)

proc grid*(cols: var seq[Column]; data: seq[seq[string]]; sel: var int;
           height = 10; w = 0; sortColumn = -1; sortDescending = false;
           enabled = true; style: proc (row, col: int): CellStyle = nil;
           rowHeaders = false; footer: proc (col: int): string = nil): GridEvent
          {.discardable.} =
  ## A table showing `data` (rows of cells).
  let p = unsafeAddr data
  grid(cols, data.len,
       proc (r, c: int): string = (if c < p[][r].len: p[][r][c] else: ""),
       sel, height, w, sortColumn, sortDescending, enabled, style = style,
       rowHeaders = rowHeaders, footer = footer)

proc sortRows*(data: var seq[seq[string]]; col: int; descending = false) =
  ## Sort table rows by column `col`: as numbers when every cell is one
  ## (thousands separators allowed), else alphabetically ignoring case.
  var numeric = true
  for r in data:
    if col < r.len and r[col].len > 0:
      try: discard parseFloat(r[col].replace(",", ""))
      except ValueError:
        numeric = false
        break
  proc key(r: seq[string]): string = (if col < r.len: r[col] else: "")
  data.sort(proc (a, b: seq[string]): int =
    if numeric:
      let x = try: parseFloat(key(a).replace(",", "")) except ValueError: 0.0
      let y = try: parseFloat(key(b).replace(",", "")) except ValueError: 0.0
      cmp(x, y)
    else:
      cmp(unicode.toLower(key(a)), unicode.toLower(key(b))),
    if descending: SortOrder.Descending else: SortOrder.Ascending)

# ---- tree -----------------------------------------------------------------------

type TreeCtx = object
  id: Id
  area: Rect
  top, vis, n, rowH: int
  off, viewH: int              ## scrolled by this many pixels; the view's height
  pad: int                     ## room inside its frame, round the rows
  sel: ptr string
  path, order: seq[string]
  focused, enabled, tap: bool
  newSel, clicked: string
  lastNode: Rect               ## the row of the node drawn last (empty: not shown)

var tc: TreeCtx

proc beginTree*(sel: var string; rows = 10; w = 0; enabled = true; padding = 0) =
  ## Starts a tree view (see `tree`): `rows` rows high (-1: the room left);
  ## `padding` the room inside its frame round the rows (pixels).
  let rowH = ItemH + 1
  let pad = max(0, padding)
  let h = if rows < 0: remainingH() else: rows * rowH + 2 + 2 * pad
  let r = place(if w > 0: w else: 0, h, fill = w <= 0)
  let id = idOf(sel, "tree")
  var st = state(id)
  let viewH = max(1, r.h - 2 - 2 * pad)
  let vis = max(1, viewH div rowH)
  let maxOff = max(0, st.aux * rowH - viewH)     # (scrolled by the pixel)
  var off = clamp(st.scrollY, 0, maxOff)
  let bar = maxOff > 0
  if bar:
    scrollBarFor(id + 9, id, rect(r.x + r.w - SbW, r.y, SbW, r.h), true,
                 off, maxOff, max(rowH, viewH - rowH), rowH, enabled)
  let area = if bar: rect(r.x, r.y, r.w - SbW + 1, r.h) else: r
  let hit = interact(id, area, enabled = enabled)
  if hit.focused and enabled and not ui.touch: ui.takesText = true   # type-ahead
  if enabled and canInput():
    scrollWheel(id, off, maxOff, r, 3 * rowH)
    scrollPan(id, off, maxOff, r)
    # a drag and drop near the top or bottom edge scrolls
    if dragging() and mouseIn(r):
      if ui.my < r.y + rowH and off > 0:
        scrollStop(id)
        off = max(0, off - max(2, rowH div 4))
        wakeIn(16)
      elif ui.my > r.y + r.h - rowH and off < maxOff:
        scrollStop(id)
        off = min(maxOff, off + max(2, rowH div 4))
        wakeIn(16)
  scrollTick(id, off, maxOff)
  st.scrollY = off
  state(id) = st
  fill(area, th.field)
  fieldFrame(area, enabled)
  pushClip(inset(area, 1))
  tc = TreeCtx(id: id, area: area, top: off div rowH, vis: vis, rowH: rowH,
               off: off, viewH: viewH, pad: pad,
               sel: addr sel, focused: hit.focused, enabled: enabled,
               newSel: sel, tap: enabled and tapped(id, hit))
  if accessOn:
    accessBegin(arTree, "", area, id, (if enabled: {} else: {asDisabled}), takesLabel = true)

proc beginNode*(label: string; expanded: var bool; leaf = false;
                icon = true; pic = Icon(); id = ""; hasKids = true): bool =
  ## A node; `pic` replaces the built-in folder/page icon, `id` (a file's
  ## full path, say) replaces the "Parent/Child" path as the node's
  ## identity in `sel`, `hasKids` false hides the +/- box.
  let i = tc.n
  inc tc.n
  let depth = tc.path.len
  let p = if id.len > 0: id
          elif depth == 0: label
          else: tc.path[^1] & "/" & label
  tc.path.add p
  tc.order.add p
  let selected = tc.sel[] == p
  if selected and tc.focused and tc.enabled and canInput() and not ui.keyUsed:
    case ui.key
    of KeyRight, KeyPlus:
      if not leaf and not expanded: expanded = true
      ui.keyUsed = true
    of KeyLeft, KeyMinus:
      if not leaf and expanded: expanded = false
      elif depth > 0 and ui.key == KeyLeft: tc.newSel = tc.path[^2]
      ui.keyUsed = true
    of KeyEnter:
      if not leaf: expanded = not expanded
      markDouble(tc.id)
      ui.keyUsed = true
    else: discard
  tc.lastNode = rect(0, 0, 0, 0)
  if i >= tc.top and i <= tc.top + tc.vis + 1:
    let a = tc.area
    let y = a.y + 1 + tc.pad + i * tc.rowH - tc.off
    tc.lastNode = rect(a.x, y, a.w, tc.rowH)
    notePlaced(intersect(tc.lastNode, a))
    if accessOn:
      # (an item of the tree, its depth its level; a press selects it, and
      # opens or closes it when it is selected already)
      let nid = accessSubId(tc.id, int(hash(p) and 0x3FFFFFFF))
      if accessPress != 0 and accessPress == nid and tc.enabled:
        accessPress = 0
        if selected and not leaf and hasKids: expanded = not expanded
        tc.newSel = p
        tc.clicked = p
        ui.focus = tc.id
      let k = accessNode(arTreeItem, label, id = nid, r = tc.lastNode,
                         states = (if selected: {asSelected} else: {}) +
                                  (if not leaf and hasKids: {asExpandable} else: {}) +
                                  (if expanded and not leaf: {asExpanded} else: {}))
      accessItem(k, i + 1, 0, depth + 1)
      if selected and tc.focused: accessFocus(k)
    let rh = tc.rowH
    let ind = dp(16)
    let px = tc.pad
    let axis = proc (d: int): int = a.x + px + dp(8) + d * ind
    for dd in 0 ..< depth:
      dots(rect(axis(dd), y, 1, rh), th.gray)
    let x0 = a.x + px + dp(4) + depth * ind
    if depth > 0:
      dots(rect(axis(depth - 1), y + rh div 2, x0 + 4 - axis(depth - 1), 1),
           th.gray)
    # (the +/- box and the icons grow with the UI's size, in whole pixels:
    # at 300% they were drawn 9 pixels big beside text three times as tall)
    let k = max(1, dp(16) div 16)
    let b = rect(x0, y + (rh - 9 * k) div 2, 9 * k, 9 * k)
    if not leaf and hasKids:
      fill(b, th.field)
      box(b, th.gray)
      fill(rect(b.x + 2 * k, b.y + 4 * k, 5 * k, k), th.fieldText)
      if not expanded: fill(rect(b.x + 4 * k, b.y + 2 * k, k, 5 * k), th.fieldText)
    var lx = x0 + dp(14)
    if pic.w > 0:
      image(lx, y + (rh - pic.h) div 2, pic)
      lx += pic.w + 3
    elif icon:
      let iy = y + (rh - 10 * k) div 2
      if leaf:
        fill(lx + k, iy, 8 * k, 10 * k, color(255, 255, 255))
        box(rect(lx + k, iy, 8 * k, 10 * k), color(0, 0, 0))
        fill(rect(lx + 3 * k, iy + 3 * k, 4 * k, k), color(0, 0, 128))
        fill(rect(lx + 3 * k, iy + 5 * k, 4 * k, k), color(0, 0, 128))
      else:
        fill(lx, iy + 2 * k, 12 * k, 8 * k, color(255, 255, 0))
        fill(lx, iy, 5 * k, 2 * k, color(255, 255, 0))
        box(rect(lx, iy + 2 * k, 12 * k, 8 * k), color(128, 128, 0))
        fill(rect(lx, iy, 5 * k, k), color(128, 128, 0))
      lx += dp(16)
    let tw = textWidth(label)
    let lr = rect(lx - 2, y, tw + 4, rh)
    if not selected and tc.enabled and hovered(rect(a.x, y, a.w, rh)):
      fill(lr, hoverColor())
    if selected:
      fill(lr, if tc.enabled: th.select else: th.gray)
      if tc.focused: dots(lr, th.selectText)
    text(lx, y + (rh - FontH) div 2, label,
         if selected: th.selectText elif tc.enabled: th.fieldText else: th.gray)
    # a right click (or a long press) selects the node its menu is for
    if ui.rpressed and canInput() and tc.enabled and mouseIn(rect(a.x, y, a.w, rh)):
      tc.newSel = p
      ui.focus = tc.id
    if tc.tap:
      if not leaf and hasKids and mouseIn(rect(b.x - dp(4), y, dp(17), rh)):
        expanded = not expanded
        tc.newSel = p
        tc.tap = false
      elif mouseIn(rect(a.x, y, a.w, rh)):
        tc.tap = false
        tc.newSel = p
        tc.clicked = p
        if ui.clicks >= 2:
          if not leaf: expanded = not expanded
          markDouble(tc.id)
  result = expanded and not leaf

proc nodeRect*(): Rect = tc.lastNode
  ## The row of the node `beginNode` drew last (empty when it is scrolled
  ## out of sight): for a drop target, say.

proc endNode*() =
  ## Ends a `beginNode` (and its children).
  if tc.path.len > 0: tc.path.setLen(tc.path.len - 1)

proc endTree*() =
  ## Ends a `beginTree`: the keys that move the selection, scrolling to it.
  let none = tc.order.find(tc.newSel) < 0
  if tc.focused and none:
    # nothing selected: the focus shows on the tree itself
    dots(inset(tc.area, 2), th.fieldText)
  popClip()
  var st = state(tc.id)
  st.aux = tc.n
  if tc.focused and tc.enabled and canInput() and tc.order.len > 0:
    var at = max(0, tc.order.find(tc.newSel))
    var moved = true
    case ui.key
    of KeyUp: at = max(0, at - 1)
    of KeyDown: at = if none: 0 else: min(tc.order.high, at + 1)
    of KeyHome: at = 0
    of KeyEnd: at = tc.order.high
    of KeyPageUp: at = max(0, at - tc.vis + 1)
    of KeyPageDown: at = min(tc.order.high, at + tc.vis - 1)
    else: moved = false
    if moved and not ui.keyUsed:
      ui.keyUsed = true
      tc.newSel = tc.order[at]
    elif ui.typed.len > 0:
      # type-ahead: the next node whose name starts with the letter
      let c = ui.typed[0].toLowerAscii
      for k in 1 .. tc.order.len:
        let i = (at + k) mod tc.order.len
        let name = tc.order[i].extractFilename
        if name.len > 0 and name[0].toLowerAscii == c:
          tc.newSel = tc.order[i]
          break
      ui.typed.setLen(0)
  # follow the selection: moved by the user here, or set by the app
  if tc.newSel != tc.sel[] or st.buf != tc.sel[]:
    let byUser = tc.newSel != tc.sel[]
    tc.sel[] = tc.newSel
    st.buf = tc.newSel
    ui.redraw = true
    let at = tc.order.find(tc.newSel)
    if at >= 0:
      let hi = max(0, tc.n * tc.rowH - tc.viewH)
      if byUser:                     # moved here: it glides into view
        scrollShow(tc.id, st.scrollY, at * tc.rowH, (at + 1) * tc.rowH, tc.viewH, hi)
      else:                          # set by the app: shown at once
        scrollStop(tc.id)
        st.scrollY = clamp(clamp(st.scrollY, (at + 1) * tc.rowH - tc.viewH, at * tc.rowH), 0, hi)
  state(tc.id) = st
  if accessOn: accessEnd()
  ui.lastId = tc.id
  ui.lastRect = tc.area

template tree*(sel: var string; rows: int; body: untyped) =
  ## A tree view; `sel` is the path ("Parent/Child") of the selected node.
  ## Inside, `branch` and `leaf` make the nodes.
  beginTree(sel, rows)
  body
  endTree()

template branch*(label: string; expanded: var bool; body: untyped) =
  ## A node with children, shown in `body` while `expanded`.
  if beginNode(label, expanded):
    body
  endNode()

template branch*(label: string; expanded: var bool; pic: Icon; id: string;
                 hasKids: bool; body: untyped) =
  ## A node with its own icon and identity (`id`, e.g. a folder's path);
  ## `body` runs only while it is open, so children can be loaded lazily.
  # (positional: a named `pic = pic` would put the argument on both sides)
  if beginNode(label, expanded, false, true, pic, id, hasKids):
    body
  endNode()

proc leaf*(label: string; icon = true; pic = Icon(); id = ""): bool {.discardable.} =
  ## A node without children; true when it was clicked.
  var closed = false
  discard beginNode(label, closed, leaf = true, icon = icon, pic = pic, id = id)
  result = tc.clicked.len > 0 and tc.clicked == tc.path[^1]
  endNode()

proc treeClicked*(): string =
  ## Inside or right after a `tree`: the node clicked this frame ("" if none).
  tc.clicked

# ---- icon view --------------------------------------------------------------------

proc iconView*(count: int; label: proc (i: int): string;
               picture: proc (i: int; r: Rect); sel: var int;
               marked: var seq[bool]; tile = 0; height = -1;
               tapActivates = false; checkboxes = false;
               enabled = true; picSize = 0; detail: proc (i: int): string = nil;
               dragItems = false; dropOk: proc (i: int): bool = nil;
               oneLine = false; columnWise = false): GridEvent {.discardable.} =
  ## Items as large pictures with their names under them, in rows (the
  ## "Large icons" view of a file manager); with `detail` as tiles: the
  ## picture at the left, the name and a line or two of `detail(i)` beside
  ## it. `picture(i, r)` draws item `i` into `r` (an icon, a thumbnail with
  ## `drawBitmap`). With `oneLine`, small tiles of one line each: the
  ## picture and the name beside it ("Small icons"); `columnWise` too, the
  ## items down columns that go on to the right, scrolled sideways
  ## (Explorer's "List"). Selection, keys, touch, selection rectangles (drag
  ## on the empty part), `dragItems` and `dropOk` work as in the
  ## multi-select `grid`; arrows move in two dimensions.
  result.sortColumn = -1
  result.row = -1
  result.hot = -1
  result.dropOver = -1
  if marked.len != count: marked.setLen(count)
  let tiles = detail != nil or oneLine
  let picS = if picSize > 0: dp(picSize) elif fingers(): dp(48) else: dp(32)
  let tw = dp(if tile > 0: tile elif tiles: 250 else: (if fingers(): 96 else: 76))
  let th2 = if oneLine: max(picS, FontH) + dp(if fingers(): 14 else: 6)
            elif tiles: max(picS + dp(10), 3 * FontH + dp(10))
            else: picS + 10 + 2 * FontH + 6
  let h = if height < 0: remainingH() else: height
  let r = place(0, h, fill = true)
  let id = idOf(sel, "iconview")
  var st = state(id)
  var ex = state(id + 23)
  let area0 = inset(r, 1)
  # (`cw`: the items down columns, scrolled sideways -- `top` is then how
  # far it is scrolled to the right, `perRow` how many a column holds)
  let cw = columnWise and oneLine
  let perRow0 = if cw: max(1, area0.h div th2) else: max(1, area0.w div tw)
  let lines = (count + perRow0 - 1) div perRow0
  let bar = if cw: lines * tw > area0.w else: lines * th2 > area0.h
  let area = if not bar: area0
             elif cw: rect(area0.x, area0.y, area0.w, area0.h - SbW + 1)
             else: rect(area0.x, area0.y, area0.w - SbW + 1, area0.h)
  let perRow = if cw: max(1, area.h div th2) else: max(1, area.w div tw)
  let rowsN = (count + perRow - 1) div perRow
  let maxTop = if cw: max(0, rowsN * tw - area.w) else: max(0, rowsN * th2 - area.h)
  var top = clamp(st.scrollY, 0, maxTop)      # (pixels)
  if bar:
    if cw:
      scrollBarFor(id + 9, id, rect(r.x, r.y + r.h - SbW, r.w, SbW), false,
                   top, maxTop, max(1, area.w - tw), max(1, tw div 4), enabled)
    else:
      scrollBarFor(id + 9, id, rect(r.x + r.w - SbW, r.y, SbW, r.h), true,
                   top, maxTop, max(1, area.h - th2), max(1, th2 div 2), enabled)
  let hit = interact(id, area, enabled = enabled)
  var nsel = sel
  var follow = ex.anchor != sel + 1          # moved by the app: show it
  let appMoved = follow                      # (at once; moved here: it glides)
  let shift = ShiftPressed in ui.mods
  let ctrl = CtrlPressed in ui.mods     # (a Mac's Cmd: its driver reports it as Ctrl)
  let gap = if tiles: 0 else: (area.w - perRow * tw) div max(1, perRow)
  let tww = if cw: tw elif tiles: area.w div perRow else: tw
  proc tileRect(i: int): Rect =
    if cw: rect(area.x + (i div perRow) * tww - top, area.y + (i mod perRow) * th2, tww, th2)
    else: rect(area.x + (i mod perRow) * (tww + gap) + gap div 2,
               area.y + (i div perRow) * th2 - top, tww, th2)
  proc indexAt(px, py: int): int =
    if cw:
      let c = (px - area.x + top) div max(1, tww)
      let rr = (py - area.y) div th2
      let i = c * perRow + rr
      return (if px >= area.x and rr >= 0 and rr < perRow and i >= 0 and i < count and
                 tileRect(i).contains(point(px, py)): i else: -1)
    let c = (px - area.x) div max(1, tww + gap)
    let rr = (py - area.y + top) div th2
    let i = rr * perRow + c
    if c >= 0 and c < perRow and i >= 0 and i < count and py >= area.y and
       tileRect(i).contains(point(px, py)): i else: -1
  if enabled and canInput():
    if CtrlPressed notin ui.mods:
      scrollWheel(id, top, maxTop, r, if cw: max(ItemH, tw div 3) else: max(ItemH, th2 * 2 div 3))
    scrollPan(id, top, maxTop, r, sideways = cw)
    if tapped(id, hit):
      let i = indexAt(ui.mx, ui.my)
      if not finger(): press = (id, i, ui.mx, ui.my, top, false)
      if i >= 0:
        let tr = tileRect(i)
        let onBox = checkboxes and ui.mx < tr.x + 20 and ui.my < tr.y + 20
        let selecting = onBox or (finger() and (checkboxes or anyMarked(marked)))
        if not marked[i] or ctrl or shift or selecting or finger():
          if listSelect(addr marked, nsel, ex, i, ctrl and not finger(),
                        shift and not finger(), selecting):
            result.selChanged = true
        elif nsel != i:
          # a click on a selected item keeps the selection (it may be dragged)
          nsel = i
          ex.caret = i
        if not selecting and (ui.clicks >= 2 or (finger() and tapActivates)):
          result.activated = true
          result.row = i
          markDouble(id)
      elif not ctrl and not shift and anyMarked(marked):
        clearMarks(marked)                           # a click on nothing
        result.selChanged = true
    # a click on an already selected item that did not become a drag: just it
    if press.id == id and press.row >= count: press.id = 0  # the items changed meanwhile
    if press.id == id and ui.released and not press.band and press.row >= 0 and
       not ctrl and not shift and marked[press.row]:
      var others = false
      for k, m in marked:
        if m and k != press.row: others = true
      if others:
        markRange(marked, press.row, press.row, false)
        result.selChanged = true
    # dragged from where the mouse went down: a drag and drop from an item,
    # a selection rectangle from the empty part
    if press.id == id and ui.mouseDown and ui.active == id:
      if abs(ui.mx - press.x) + abs(ui.my - press.y) > dp(6) or press.band:
        if press.row >= 0:
          if dragItems:
            result.dragStarted = true
            result.row = press.row
          press.id = 0
        else:
          if not press.band: bandBase = marked
          press.band = true
          let bx = if cw: press.x + (press.top - top) else: press.x
          let by = if cw: press.y else: press.y + (press.top - top)
          let band = rect(min(bx, ui.mx), min(by, ui.my), abs(ui.mx - bx) + 1,
                          abs(ui.my - by) + 1)
          if ctrl and bandBase.len == marked.len: marked = bandBase
          else: clearMarks(marked)
          let r0 = if cw: max(0, (band.x - area.x + top) div tww)
                   else: max(0, (band.y - area.y + top) div th2)
          let r1 = if cw: min(rowsN - 1, (band.x + band.w - area.x + top) div tww)
                   else: min(rowsN - 1, (band.y + band.h - area.y + top) div th2)
          for rr in r0 .. r1:
            for c in 0 ..< perRow:
              let i = rr * perRow + c
              if i < count and intersect(tileRect(i), band).w > 0 and
                 intersect(tileRect(i), band).h > 0:
                marked[i] = true
          result.selChanged = true
          # near an edge: it scrolls on, a little each frame
          let (at, lo, hi, unit) = if cw: (ui.mx, area.x, area.x + area.w, tww)
                                   else: (ui.my, area.y, area.y + area.h, th2)
          if at < lo + unit div 4 and top > 0:
            scrollStop(id)
            top = max(0, top - max(2, unit div 12))
            wakeIn(16)
          elif at > hi - unit div 4 and top < maxTop:
            scrollStop(id)
            top = min(maxTop, top + max(2, unit div 12))
            wakeIn(16)
    if press.id == id and not ui.mouseDown: press.id = 0
    if dragging() and mouseIn(area):
      let (at, lo, hi, unit) = if cw: (ui.mx, area.x, area.x + area.w, tww)
                               else: (ui.my, area.y, area.y + area.h, th2)
      if at < lo + unit div 4 and top > 0:
        scrollStop(id)
        top = max(0, top - max(2, unit div 16))
        wakeIn(16)
      elif at > hi - unit div 4 and top < maxTop:
        scrollStop(id)
        top = min(maxTop, top + max(2, unit div 16))
        wakeIn(16)
      let i = indexAt(ui.mx, ui.my)
      if dropOk != nil:
        if i >= 0 and dropOk(i):
          case dropTarget(tileRect(i))
          of dsOver: result.dropOver = i
          of dsDropped:
            result.dropped = true
            result.row = i
          else: discard
        elif dropOk(-1):
          case dropTarget(area)
          of dsOver: result.dropOver = -2
          of dsDropped:
            result.dropped = true
            result.row = -1
          else: discard
    elif not ui.mouseDown and canHover() and mouseIn(area):
      result.hot = indexAt(ui.mx, ui.my)
    if ui.menuKey and hit.focused and count > 0:
      let tr = tileRect(clamp(nsel, 0, count - 1))
      ui.mx = tr.x + tr.w div 2
      ui.my = clamp(tr.y + tr.h div 2, area.y + 1, area.y + area.h - 2)
    if ui.rpressed and mouseIn(area):
      let i = indexAt(ui.mx, ui.my)
      if i >= 0:
        if not marked[i]: markRange(marked, i, i, false)
        nsel = i
        ex.caret = i
        result.selChanged = true
        result.rightClicked = true
        result.row = i
        ui.focus = id
        if finger() and dragItems: press = (id, i, ui.mx, ui.my, top, false)
    if lifted() and press.id == id and press.row >= 0 and dragItems:
      result.dragStarted = true
      result.row = press.row
      press.id = 0
  if hit.focused and canInput() and count > 0:
    var moved = -1
    let cur = clamp(sel, 0, count - 1)
    let page = if cw: max(1, area.w div tww) * perRow else: max(1, area.h div th2) * perRow
    # (down columns: Up and Down the next one, Left and Right the next column)
    let (back, fwd, prevLine, nextLine) =
      if cw: (KeyUp, KeyDown, KeyLeft, KeyRight) else: (KeyLeft, KeyRight, KeyUp, KeyDown)
    let k = ui.key
    if k == back: moved = max(0, cur - 1)
    elif k == fwd: moved = min(count - 1, cur + 1)
    elif k == prevLine: moved = if cur >= perRow: cur - perRow else: cur
    elif k == nextLine:
      moved = if cur + perRow < count: cur + perRow
              elif cw and cur div perRow < (count - 1) div perRow: count - 1
              else: cur
    case k
    of KeyLeft, KeyRight, KeyUp, KeyDown: discard
    of KeyPageUp: moved = max(0, cur - page)
    of KeyPageDown: moved = min(count - 1, cur + page)
    of KeyHome: moved = 0
    of KeyEnd: moved = count - 1
    of KeyEnter:
      if AltPressed notin ui.mods:
        result.activated = true
        result.row = cur
        markDouble(id)
        ui.keyUsed = true
    of KeySpace:
      # Space selects the current item, Ctrl+Space flips it
      if ctrl or not marked[cur]:
        marked[cur] = if ctrl: not marked[cur] else: true
        result.selChanged = true
        ui.keyUsed = true
    of KeyA:
      if ctrl:
        markRange(marked, 0, count - 1, false)
        result.selChanged = true
        ui.keyUsed = true
    else: discard
    if moved >= 0:
      ui.keyUsed = true
      follow = true
      if not ctrl:
        if shift: markRange(marked, ex.caret, moved, false)
        else:
          markRange(marked, moved, moved, false)
          ex.caret = moved
        result.selChanged = true
      nsel = moved
    if ui.typed.len > 0:
      let i = typeAhead(ex, count, cur, label)
      if i >= 0:
        nsel = i
        follow = true
        markRange(marked, i, i, false)
        ex.caret = i
        result.selChanged = true
  if accessPress != 0 and enabled:
    # (a screen reader picked an item)
    for i in 0 ..< count:
      if accessPress == accessSubId(id, i):
        accessPress = 0
        markRange(marked, i, i, false)
        ex.caret = i
        nsel = i
        follow = true
        result.selChanged = true
        ui.focus = id
        break
  if nsel != sel and nsel in 0 ..< count:
    sel = nsel
    result.selChanged = true
    follow = true
  if follow and sel in 0 ..< count:
    let unit = if cw: tww else: th2
    let view = if cw: area.w else: area.h
    let y = (sel div perRow) * unit
    if appMoved and not scrolling(id):
      top = clamp(clamp(top, y + unit - view, y), 0, maxTop)
    else:
      scrollShow(id, top, y, y + unit, view, maxTop)
  scrollTick(id, top, maxTop)
  ex.anchor = sel + 1
  st.scrollY = top
  state(id) = st
  state(id + 23) = ex
  # draw
  fill(rect(r.x, r.y, area.w + 2, r.h), th.field)
  box(rect(r.x, r.y, area.w + 2, r.h), if enabled: th.edge else: th.gray)
  pushClip(area)
  let first = if cw: max(0, (top div tww) * perRow) else: max(0, (top div th2) * perRow)
  let last = if cw: min(count, ((top + area.w) div tww + 1) * perRow)
             else: min(count, ((top + area.h) div th2 + 1) * perRow)
  let small = style(size = 0.85)
  for i in first ..< last:
    let tr = tileRect(i)
    let fg = if marked[i]: th.selectText elif enabled: th.fieldText else: th.gray
    if tiles:
      # the text highlighted when selected (as Program Manager did), the
      # picture left as it is
      if enabled and not marked[i] and (result.hot == i or hovered(tr)):
        fill(inset(tr, 2), hoverColor())
      let pr = rect(tr.x + dp(if oneLine: 3 else: 6), tr.y + (th2 - picS) div 2, picS, picS)
      picture(i, pr)
      let tx = pr.x + picS + dp(if oneLine: 5 else: 8)
      let tw2 = tr.x + tr.w - tx - dp(4)
      var y = if oneLine: tr.y + (th2 - FontH) div 2 else: tr.y + (th2 - 3 * FontH) div 2
      let name = ellipsize(label(i), tw2)
      var lines: seq[string]
      if detail != nil and not oneLine:
        for line in detail(i).split('\n'):
          if line.len > 0: lines.add ellipsize(line, tw2, small)
      var bw = textWidth(name)
      var bh = FontH
      for l in lines:
        if y + bh + FontH > tr.y + tr.h: break
        bw = max(bw, textWidth(l, small))
        bh += lineHeight(small) + 1
      let br = rect(tx - 2, y - 1, bw + 4, bh + 2)
      if marked[i]: fill(br, if enabled: th.select else: th.gray)
      text(tx, y, name, fg)
      y += FontH
      for line in lines:
        if y + FontH > tr.y + tr.h: break
        text(tx, y, line, if marked[i]: th.selectText else: th.gray, small)
        y += lineHeight(small) + 1
      if i == sel and hit.focused: dots(br, if marked[i]: th.selectText else: th.text)
    else:
      let pr = rect(tr.x + (tw - picS) div 2, tr.y + 6, picS, picS)
      if enabled and not marked[i] and (result.hot == i or hovered(tr)):
        fill(inset(tr, 2), hoverColor())
      picture(i, pr)
      let lines = wrapLines(label(i), tw - 6)
      var shown = lines
      if shown.len > 2:
        shown.setLen(2)
        shown[1] = ellipsize(shown[1] & " " & lines[2], tw - 6)
      var lw = 0
      for l in shown: lw = max(lw, textWidth(l))
      let lr = rect(tr.x + (tw - lw) div 2 - 2, pr.y + picS + 4, lw + 4,
                    shown.len * FontH + 2)
      if marked[i]:
        fill(lr, if enabled: th.select else: th.gray)
      for k, l in shown:
        text(tr.x + (tw - textWidth(l)) div 2, lr.y + 1 + k * FontH, l, fg)
      if i == sel and hit.focused: dots(lr, fg)
    if checkboxes:
      let bs = dp(13)
      checkBox(rect(tr.x + 3, tr.y + 3, bs, bs), marked[i], false, true)
    if result.dropOver == i: dropHighlight(inset(tr, 1))
  if press.id == id and press.band:
    let bx = if cw: press.x + (press.top - top) else: press.x
    let by = if cw: press.y else: press.y + (press.top - top)
    box(rect(min(bx, ui.mx), min(by, ui.my), abs(ui.mx - bx) + 1,
             abs(ui.my - by) + 1), th.select)
  if result.dropOver == -2: dropHighlight(area)
  popClip()
  if accessOn:
    # (a list of the items in view)
    accessBegin(arList, "", area, id, (if enabled: {} else: {asDisabled}), takesLabel = true)
    for i in first ..< last:
      let k = accessNode(arListItem, label(i), id = accessSubId(id, i), r = tileRect(i),
                         states = (if marked[i]: {asSelected} else: {}),
                         help = (if detail != nil: detail(i).replace('\n', ' ') else: ""))
      accessItem(k, i + 1, count)
      if i == sel and hit.focused: accessFocus(k)
    accessEnd()
  ui.lastId = id
  ui.lastRect = r

# ---- breadcrumb (a path you can click) ---------------------------------------------

proc breadcrumb*(parts: openArray[string]; w = 0;
                 enabled = true): int {.discardable.} =
  ## The parts of a path as buttons in a row ("C: > Users > me"); returns
  ## the index of the part clicked, -1 if none. Parts that do not fit are
  ## folded into a "<<" button at the start.
  result = -1
  let r = place(if w > 0: w else: 0, EditH, fill = w <= 0)
  let id = idOf("breadcrumb" & $parts.len)
  fill(r, th.field)
  fieldFrame(r, enabled)
  const sep = " > "
  let sepW = textWidth(sep)
  let pad = if fingers(): 8 else: 4
  var widths: seq[int]
  for i, p in parts: widths.add textWidth(p, bold = i == parts.high) + 2 * pad
  var first = 0
  var total = 0
  for i in countdown(parts.high, 0):
    total += widths[i] + (if i < parts.high: sepW else: 0)
    if total > r.w - 8 - textWidth("<<") - 2 * pad - sepW:
      first = i + 1
      break
  first = min(first, max(0, parts.high))
  var x = r.x + 2
  pushClip(inset(r, 1))
  if accessOn: accessBegin(arToolBar, "", r, takesLabel = true)
  if first > 0:
    let br = rect(x, r.y + 2, textWidth("<<") + 2 * pad, r.h - 4)
    let hit = interact(id + 99, br, focusable = false, enabled = enabled)
    if hit.showsHover or hit.down:
      fill(br, th.face)
      if hit.down: sunken(br) else: raised(br, 1)
    text(br.x + pad, r.y + (r.h - FontH) div 2, "<<", th.fieldText, true)
    if accessOn: accessNode(arButton, "Back", id = id + 99, r = br)
    if hit.clicked: result = first - 1
    x += br.w
    text(x, r.y + (r.h - FontH) div 2, sep, th.gray)
    x += sepW
  for i in first .. parts.high:
    let br = rect(x, r.y + 2, widths[i], r.h - 4)
    let hit = interact(id + uint32(i), br, focusable = false, enabled = enabled)
    let lastOne = i == parts.high
    if hit.showsHover or hit.down:
      fill(br, th.face)
      if hit.down: sunken(br) else: raised(br, 1)
    text(br.x + pad, r.y + (r.h - FontH) div 2, parts[i],
         if enabled: th.fieldText else: th.gray, lastOne)
    if accessOn:
      accessNode(arButton, parts[i], id = id + uint32(i), r = br,
                 states = (if enabled: {} else: {asDisabled}))
    if hit.clicked: result = i
    x += br.w
    if not lastOne:
      text(x, r.y + (r.h - FontH) div 2, sep, th.gray)
      x += sepW
  popClip()
  if accessOn: accessEnd()
  ui.lastId = id
  ui.lastRect = r

# ---- picture view ----------------------------------------------------------------------

proc imageView*(b: Bitmap; zoom: var float; height = -1; w = 0) =
  ## A picture to look at: fitted into the view while `zoom` is 0, else
  ## `zoom` screen pixels per picture pixel (1.0: actual size). The wheel
  ## zooms about the point under the mouse (+ / - / 0 with the focus, about
  ## the middle), a double click or double tap
  ## goes between fitted and actual size, dragging (a finger, the arrow
  ## keys) moves it.
  let r = place(if w > 0: w else: 0, if height < 0: remainingH() else: height,
                fill = w <= 0)
  let id = idOf(zoom, "imageview")
  var st = state(id)
  let hit = interact(id, r, focusable = true)
  fill(r, th.shadow)
  sunken(r)
  if b == nil or b.w <= 0:
    ui.lastRect = r
    return
  let inner = inset(r, 1)
  let s = float(pxScale)
  var dw, dh: int
  if zoom <= 0:
    let k = min(inner.w / b.w, inner.h / b.h)
    let k2 = min(k, 1.0 / s * float(max(1, int(k * s))))  # whole steps when small
    let kk = if k * s >= 1: k2 else: k
    dw = max(1, int(b.w.float * kk))
    dh = max(1, int(b.h.float * kk))
  else:
    dw = max(1, int(b.w.float * zoom / s))
    dh = max(1, int(b.h.float * zoom / s))
  var ox = st.scrollX
  var oy = st.scrollY
  if canInput():
    if mouseIn(r) and ui.wheel != 0 and not ui.wheelUsed:
      ui.wheelUsed = true
      let cur = if zoom <= 0: dw.float * s / b.w.float else: zoom
      # (the point of the picture under the mouse stays under it)
      let fx = (ui.mx - (inner.x + max(0, (inner.w - dw) div 2) - ox)).float / dw.float
      let fy = (ui.my - (inner.y + max(0, (inner.h - dh) div 2) - oy)).float / dh.float
      zoom = clamp(cur * (if ui.wheel > 0: 1.25 else: 0.8), 0.05, 16.0)
      dw = max(1, int(b.w.float * zoom / s))
      dh = max(1, int(b.h.float * zoom / s))
      ox = int(fx * dw.float) - (ui.mx - inner.x - max(0, (inner.w - dw) div 2))
      oy = int(fy * dh.float) - (ui.my - inner.y - max(0, (inner.h - dh) div 2))
    if hit.focused and not ui.keyUsed:
      case ui.key
      of KeyPlus, KeyEqual:
        zoom = clamp((if zoom <= 0: dw.float * s / b.w.float else: zoom) * 1.25, 0.05, 16.0)
        ui.keyUsed = true
      of KeyMinus:
        zoom = clamp((if zoom <= 0: dw.float * s / b.w.float else: zoom) * 0.8, 0.05, 16.0)
        ui.keyUsed = true
      of Key0: zoom = 0; ui.keyUsed = true
      of KeyLeft: ox -= dp(40); ui.keyUsed = true
      of KeyRight: ox += dp(40); ui.keyUsed = true
      of KeyUp: oy -= dp(40); ui.keyUsed = true
      of KeyDown: oy += dp(40); ui.keyUsed = true
      else: discard
    # a double click or a double tap: fitted <-> actual size
    if hit.clicked and ui.clicks >= 2:
      zoom = if zoom <= 0: 1.0 else: 0
      ui.redraw = true
    if ui.active == id and ui.mouseDown and not ui.pressed:
      ox += st.aux - ui.mx
      oy += st.aux2 - ui.my
    if ui.panX != 0 or ui.panY != 0:
      if mouseIn(r) and not ui.panUsed:
        ui.panUsed = true
        ox += ui.panX
        oy += ui.panY
    st.aux = ui.mx
    st.aux2 = ui.my
    if hit.down or ui.active == id: ui.dragsActive = not finger()
  ox = clamp(ox, 0, max(0, dw - inner.w))
  oy = clamp(oy, 0, max(0, dh - inner.h))
  st.scrollX = ox
  st.scrollY = oy
  state(id) = st
  let x = inner.x + max(0, (inner.w - dw) div 2) - ox
  let y = inner.y + max(0, (inner.h - dh) div 2) - oy
  pushClip(inner)
  drawBitmap(rect(x, y, dw, dh), b)
  popClip()
  if accessOn:
    accessNode(arImage, "", id = id, r = r,
               help = $b.w & " x " & $b.h & (if zoom > 0: ", " & $int(zoom * 100 + 0.5) & "%" else: ""))
  ui.lastId = id
  ui.lastRect = r

# ---- progress ---------------------------------------------------------------------------

proc progressBox*(open: var bool; title, message: string; value: float;
                  detail = ""; canCancel = true): bool =
  ## A modal box with a progress bar while `open`; true (once) when the
  ## user cancels (Cancel or Esc).
  let was = open
  if beginDialog(open, title, 340):
    paragraph message
    progress(clamp(value, 0.0, 1.0))
    if detail.len > 0:
      var d = detail
      while d.len > 4 and textWidth(d) > available():
        d = "..." & d[min(d.len, 8) .. ^1]
      label d, color = th.gray
    if canCancel:
      row:
        spring()
        if button("Cancel", isDefault = true):
          open = false
          result = true
    wakeIn(30)
    endDialog()
  if was and not open and not result: result = true

# ---- splitter ---------------------------------------------------------------

var splitStack: seq[tuple[r: Rect; pos: int; vert: bool; id: Id]]

proc splitRects(r: Rect; pos: int; vert: bool): tuple[a, bar, b: Rect] =
  let k = if fingers(): dp(10) else: dp(5)
  if vert:
    (rect(r.x, r.y, r.w, pos), rect(r.x, r.y + pos, r.w, k),
     rect(r.x, r.y + pos + k, r.w, r.h - pos - k))
  else:
    (rect(r.x, r.y, pos, r.h), rect(r.x + pos, r.y, k, r.h),
     rect(r.x + pos + k, r.y, r.w - pos - k, r.h))

proc beginPane(id: Id; a: Rect) =
  ## A pane of a split: content taller than it scrolls (its own scroll bar,
  ## the wheel, a finger), as an MDI window's does.
  let st = state(id)
  let over = st.aux != 0                 # (it was taller last frame)
  pushClip(a)
  beginClipped()
  ui.focusRect = rect(0, 0, 0, 0)
  pushFrame(rect(a.x, a.y - (if over: st.scrollY else: 0),
                 a.w - (if over: SbW else: 0), a.h))
  beginArea(id)                          # (F6 goes from pane to pane)

proc endPane(id: Id; a: Rect) =
  endArea()
  let ch = popFrame()
  endClipped()
  popClip()
  var st = state(id)
  # (a pixel or two over, from rounding, is not worth a scroll bar)
  let maxY = if ch - a.h > dp(2): ch - a.h else: 0
  var y = clamp(st.scrollY, 0, maxY)
  if maxY > 0:
    scrollWheel(id, y, maxY, a, 3 * ItemH)
    scrollPan(id, y, maxY, a)
    scrollTick(id, y, maxY)
    let f = wantSeen()                 # Tab to a widget out of view
    if f.w > 0:
      if f.y < a.y: y = clamp(y - (a.y + Pad - f.y), 0, maxY)
      elif f.y + f.h > a.y + a.h: y = clamp(y + (f.y + f.h + Pad - (a.y + a.h)), 0, maxY)
    scrollBarFor(id + 9, id, rect(a.x + a.w - SbW, a.y, SbW, a.h), true, y, maxY,
                 max(ItemH, a.h - ItemH), ItemH)
  let over = ord(maxY > 0)
  if y != st.scrollY or over != st.aux:
    st.scrollY = y
    st.aux = over
    ui.redraw = true
  state(id) = st

proc beginSplit*(pos: var int; height: int; vertical = false) =
  ## Starts two panes (see `split` / `vsplit`): the first one's widgets
  ## follow, then `splitNext`, the second's, and `endSplit`. A pane whose
  ## content is taller than it scrolls.
  let r = place(0, if height < 0: remainingH() else: height, fill = true)
  let total = if vertical: r.h else: r.w
  pos = clamp(pos, 30, max(30, total - 35))
  let id = idOf(pos, "split")
  let bar = splitRects(r, pos, vertical).bar
  if canInput():
    let cur = if vertical: curSizeNS else: curSizeWE
    if mouseIn(bar): ui.cursor = cur
    if hover(bar) and takePress():
      ui.active = id
      ui.dragsActive = true
    if ui.active == id and ui.mouseDown:
      ui.cursor = cur
      pos = clamp((if vertical: ui.my - r.y else: ui.mx - r.x) - 2, 30,
                  max(30, total - 35))
  splitStack.add (r, pos, vertical, id)
  beginPane(id + 101, splitRects(r, pos, vertical).a)

proc splitNext*() =
  ## Ends the first pane of a `beginSplit` and starts the second.
  let t = splitStack[^1]
  let (a, bar, b) = splitRects(t.r, t.pos, t.vert)
  endPane(t.id + 101, a)
  fill(bar, th.face)
  raised(bar, 1)
  beginPane(t.id + 102, b)

proc endSplit*() =
  ## Ends a `beginSplit`.
  let t = splitStack.pop()
  endPane(t.id + 102, splitRects(t.r, t.pos, t.vert).b)

template split*(pos: var int; height: int; left, right: untyped) =
  ## Two panes side by side; drag the bar between them (`pos` is its x).
  ##
  ## .. code-block:: nim
  ##   split(listW, 300):
  ##     listbox items, sel, rows = -1
  ##   do:
  ##     editArea text, lines = -1
  beginSplit(pos, height)
  left
  splitNext()
  right
  endSplit()

template vsplit*(pos: var int; height: int; upper, lower: untyped) =
  ## Two panes above each other; drag the bar between them.
  beginSplit(pos, height, true)
  upper
  splitNext()
  lower
  endSplit()

proc splitBar*(): int =
  ## The thickness of the bar of `split` and `vsplit`.
  if fingers(): dp(10) else: dp(5)

proc paneBeside*(paneW: int; minMain = 320): bool =
  ## A pane `paneW` logical pixels wide fits beside content that needs
  ## `minMain` (not on phones held upright).
  not isCompact() and available() >= dp(paneW + minMain) + splitBar()

template sidePane*(show: bool; paneW, paneH: var int; main, pane: untyped) =
  ## `main` with a `pane` beside it (`paneW` wide, in design pixels) when
  ## there is room, else under it (`paneH` tall): the details pane of an
  ## explorer, the inspector of an editor. Dragging the bar between them
  ## changes `paneW` or `paneH` (keep them in the app's settings).
  ##
  ## .. code-block:: nim
  ##   sidePane(showDetails, detailsW, detailsH):
  ##     listbox items, sel, rows = -1
  ##   do:
  ##     factList(details(items[sel]))
  if not show:
    main
  elif paneBeside(paneW):
    let total = available()
    let wanted = max(dp(200), total - dp(paneW) - splitBar())
    var at = wanted
    split(at, -1):
      main
    do:
      pane
    if at != wanted:
      paneW = max(120, int(float(total - at - splitBar()) / max(0.1, ui.k)))
  else:
    let total = remainingH()
    let wanted = max(dp(120), total - dp(paneH) - splitBar())
    var at = wanted
    vsplit(at, total):
      main
    do:
      pane
    if at != wanted:
      paneH = clamp(int(float(total - at - splitBar()) / max(0.1, ui.k)), 60, 2000)

# ---- check list ----------------------------------------------------------------

proc checkList*(items: openArray[string]; checked: var seq[bool]; rows = 6;
                w = 0; enabled = true): bool {.discardable.} =
  ## A list with a check box on each item: a click, a tap or Space flips
  ## the item; Up, Down, Page Up, Page Down, Home, End move.
  if checked.len != items.len: checked.setLen(items.len)
  let rowH = max(ItemH, 16)
  let h = if rows < 0: remainingH() else: rows * rowH + 2
  let r = place(if w > 0: w else: 0, h, fill = w <= 0)
  let id = idOf(checked, "checklist")
  var st = state(id)
  let n = items.len
  let viewH = max(1, r.h - 2)
  let vis = max(1, viewH div rowH)
  let maxOff = max(0, n * rowH - viewH)          # (scrolled by the pixel)
  var off = clamp(st.scrollY, 0, maxOff)
  let bar = maxOff > 0
  if bar:
    scrollBarFor(id + 9, id, rect(r.x + r.w - SbW, r.y, SbW, r.h), true,
                 off, maxOff, max(rowH, viewH - rowH), rowH, enabled)
  let area = if bar: rect(r.x, r.y, r.w - SbW + 1, r.h) else: r
  let hit = interact(id, area, enabled = enabled)
  var cur = clamp(st.caret, 0, max(0, n - 1))
  if accessPress != 0 and enabled:
    # (a screen reader pressed an item: it flips)
    for i in 0 ..< n:
      if accessPress == accessSubId(id, i):
        accessPress = 0
        cur = i
        checked[i] = not checked[i]
        result = true
        ui.focus = id
        break
  if enabled and canInput():
    scrollWheel(id, off, maxOff, r, 3 * rowH)
    scrollPan(id, off, maxOff, r)
    if tapped(id, hit):
      let i = (ui.my - r.y - 1 + off) div rowH
      if i >= 0 and i < n:
        cur = i
        checked[i] = not checked[i]
        result = true
    if hit.focused and n > 0:
      case ui.key
      of KeyUp: cur = max(0, cur - 1); ui.keyUsed = true
      of KeyDown: cur = min(n - 1, cur + 1); ui.keyUsed = true
      of KeyHome: cur = 0; ui.keyUsed = true
      of KeyEnd: cur = n - 1; ui.keyUsed = true
      of KeyPageUp: cur = max(0, cur - vis + 1); ui.keyUsed = true
      of KeyPageDown: cur = min(n - 1, cur + vis - 1); ui.keyUsed = true
      of KeySpace:
        checked[cur] = not checked[cur]
        result = true
        ui.keyUsed = true
      else: discard
      if ui.keyUsed: scrollShow(id, off, cur * rowH, (cur + 1) * rowH, viewH, maxOff)
  scrollTick(id, off, maxOff)
  st.caret = cur
  st.scrollY = off
  state(id) = st
  fill(area, th.field)
  fieldFrame(area, enabled)
  pushClip(inset(area, 1))
  let top = off div rowH
  for i in top ..< min(n, top + vis + 2):
    let y = r.y + 1 + i * rowH - off
    let bs = dp(13)
    let b = rect(area.x + 4, y + (rowH - bs) div 2, bs, bs)
    checkBox(b, checked[i], false, enabled)
    text(b.x + bs + dp(6), y + (rowH - FontH) div 2, items[i],
         if enabled: th.fieldText else: th.gray)
    if hit.focused and i == cur:
      dots(rect(b.x + bs + dp(4), y + 1, textWidth(items[i]) + 4, rowH - 2), th.fieldText)
  popClip()
  if accessOn:
    # (a list of check boxes)
    accessBegin(arList, "", area, id, (if enabled: {} else: {asDisabled}), takesLabel = true)
    for i in top ..< min(n, top + vis + 2):
      let k = accessNode(arCheckBox, items[i], id = accessSubId(id, i),
                         r = rect(area.x + 1, r.y + 1 + i * rowH - off, area.w - 2, rowH),
                         states = (if checked[i]: {asChecked} else: {}) +
                                  (if enabled: {} else: {asDisabled}))
      accessItem(k, i + 1, n)
      if hit.focused and i == cur: accessFocus(k)
    accessEnd()

# ---- number fields -----------------------------------------------------------------

proc formatNumber*(v: float; decimals = 2; thousands = true): string =
  ## 1234.5 -> "1,234.50". `decimals` is taken as 0 to 12; NaN and the
  ## infinities come out as "NaN", "Inf" and "-Inf".
  case classify(v)
  of fcNan: return "NaN"
  of fcInf: return "Inf"
  of fcNegInf: return "-Inf"
  else: discard
  var s = formatFloat(abs(v), ffDecimal, clamp(decimals, 0, 12))
  if s.endsWith('.'): s.setLen(s.len - 1)   # formatFloat(12, ffDecimal, 0) is "12."
  let dot = s.find('.')
  let ip = if dot >= 0: s[0 ..< dot] else: s
  var grouped = ""
  for i, c in ip:
    if thousands and i > 0 and (ip.len - i) mod 3 == 0: grouped.add ','
    grouped.add c
  result = grouped & (if dot >= 0: s[dot .. ^1] else: "")
  if v < 0 and result.strip(chars = {'0', '.', ','}).len > 0:
    result = "-" & result

proc parseNumber*(s: string; v: var float): bool =
  ## Reads "1,234.50" (thousands separators ignored) into `v`; false (and
  ## `v` left alone) when it is not a number -- NaN and infinities are not.
  let t = s.replace(",", "").strip
  if t.len == 0: return false
  try:
    let x = parseFloat(t)
    if classify(x) in {fcNan, fcInf, fcNegInf}: return false
    v = x
    true
  except ValueError:
    false

proc numberAt(id: Id; v: var float; decimals, w: int; lo, hi: float;
              thousands, enabled: bool): bool =
  let r = place(w, EditH)
  let editId = id + 31
  var st = state(id)
  let decimals = clamp(decimals, 0, 12)
  if ui.focus != editId: st.buf = formatNumber(v, decimals, thousands)
  else:
    # (`v` set by the app while the field has the focus -- a form cleared
    # after Add: the field shows it; what is being typed, a number not
    # taken yet, stays)
    var x: float
    if parseNumber(st.buf, x) and x >= lo and x <= hi and x != v:
      st.buf = formatNumber(v, decimals, false)
      st.aux = 2                              # (selected: typing replaces it)
  var buf = st.buf
  if editAt(editId, buf, r, false, false, enabled,
            {'0'..'9', '-', '.', ','}, right = true):
    var x: float
    if parseNumber(buf, x) and x >= lo and x <= hi and x != v:
      v = x
      result = true
  # (the focus come, by a click or by Tab: the whole number selected, so
  # what is typed replaces it -- not "12.5" typed before "0.00")
  let focused = ui.focus == editId
  if not focused: st.aux = 0
  elif st.aux == 0: st.aux = 2                # (just come: select when the button is up)
  if st.aux == 2 and not ui.mouseDown:
    var es = state(editId)
    es.anchor = 0
    es.caret = buf.len
    state(editId) = es
    st.aux = 1
  st.buf = buf
  state(id) = st

proc numberEdit*(v: var float; decimals = 2; w = 110; lo = NegInf;
                 hi = Inf; thousands = true;
                 enabled = true): bool {.discardable.} =
  ## A right-aligned number field; shows `decimals` places (0 to 12) and
  ## thousands separators when it does not have the focus. Only numbers
  ## from `lo` to `hi` are taken (true when `v` changed). Clicking or
  ## tabbing into it selects the number, so typing replaces it.
  numberAt(idOf(v, "number"), v, decimals, w, lo, hi, thousands, enabled)

proc intEdit*(v: var int; w = 80; lo = low(int); hi = high(int);
              thousands = false; enabled = true): bool {.discardable.} =
  ## A right-aligned whole-number field. Only whole numbers from `lo` to
  ## `hi` are taken (true when `v` changed); clicking or tabbing into it
  ## selects the number, so typing replaces it.
  var f = v.float
  # (a float as large as high(int) is past it: it would not convert)
  if numberAt(idOf(v, "int"), f, 0, w, lo.float, hi.float, thousands,
              enabled) and f == round(f) and f >= low(int).float and
     f < high(int).float:
    v = clamp(int(f), lo, hi)
    result = true

# ---- auto-complete combo ------------------------------------------------------------

proc comboEdit*(text: var string; items: openArray[string]; w = 0;
                enabled = true): bool {.discardable.} =
  ## A text field that suggests matching `items` as you type (or lists
  ## them all from its button, Alt+Down, F4, or Enter when no list is
  ## open; F4, Alt+Up or Esc close it). Up/Down, Enter, Esc work in the
  ## list; none is picked until Down (or the mouse) points at one, so Enter
  ## on its own keeps what was typed.
  let r = place(if w > 0: w else: 160, EditH)
  let id = idOf(text, "comboedit")
  let editId = id + 31
  var st = state(id)
  let field = rect(r.x, r.y, r.w - SbW + 1, r.h)
  let btn = rect(r.x + r.w - SbW, r.y, SbW, r.h)
  let live = canInput()          # before the list goes to the popup layer
  let home = layer()
  if enabled and ui.focus == editId: ui.takesEnter = true   # (Enter opens its list, or picks: #9)
  if enabled and hover(btn) and takePress():
    st.aux = 1 - st.aux
    st.aux2 = 1
    st.caret = -1
    ui.focus = editId
  elif enabled and live and ui.focus == editId and not ui.keyUsed and st.aux == 0 and
       ((ui.key == KeyDown and AltPressed in ui.mods) or ui.key == KeyF4 or ui.key == KeyEnter):
    # (the whole list from the keyboard)
    st.aux = 1
    st.aux2 = 1
    st.caret = -1
    ui.keyUsed = true
    ui.redraw = true
  if editAt(editId, text, field, false, false, enabled):
    result = true
    st.aux = 1
    st.aux2 = 0
    st.caret = -1
  if ui.focus != editId: st.aux = 0
  var list: seq[int]
  if st.aux == 1:
    let q = unicode.toLower(text)
    for i, it in items:
      if st.aux2 == 1 or q.len == 0 or unicode.toLower(it).contains(q):
        list.add i
    if list.len == 0 or (list.len == 1 and items[list[0]] == text and
                         st.aux2 == 0):
      st.aux = 0
  buttonFace(btn, st.aux == 1, rounded = false, bevel = 1)
  let o = if st.aux == 1: 1 else: 0
  let c = if enabled: th.frame else: th.gray
  arrow(btn.x + btn.w div 2 + o, btn.y + btn.h div 2 - 2 + o, dDown, c)
  hline(btn.x + btn.w div 2 - 3 + o, btn.y + btn.h div 2 + 3 + o, 7, c)
  if st.aux == 1:
    let vis = min(list.len, 8)
    let viewH = vis * ItemH
    let maxOff = max(0, list.len * ItemH - viewH)   # (scrolled by the pixel)
    var hi = if st.caret < 0: -1 else: clamp(st.caret, 0, list.high)
    var off = clamp(st.scrollY, 0, maxOff)
    var pick = -1
    var keyMoved = false
    if ui.focus == editId and live and not ui.keyUsed and
       (dropKey() or (ui.key == KeyUp and AltPressed in ui.mods)):
      st.aux = 0                       # (F4, Alt+Down, Alt+Up close it, as Esc does)
      ui.keyUsed = true
      ui.redraw = true
    if ui.focus == editId and live and not ui.keyUsed:
      case ui.key
      of KeyDown: hi = min(list.high, hi + 1); ui.keyUsed = true; keyMoved = true
      of KeyUp: hi = max(-1, hi - 1); ui.keyUsed = true; keyMoved = true
      of KeyEnter:
        if hi >= 0:
          pick = list[hi]
          ui.keyUsed = true
        else: st.aux = 0               # Enter is for the text as typed
      of KeyEsc:
        st.aux = 0
        ui.keyUsed = true
      else: discard
    var pr = rect(r.x, r.y + r.h - 1, r.w, vis * ItemH + 2)
    if pr.y + pr.h > ui.h: pr.y = r.y - pr.h + 1
    pushLayer(LayerPopup)
    ui.overlayNow = pr
    ui.overlayLayerNow = home
    ui.overlayOwner = true
    if live:
      if ui.pressed: comboPanned = false
      scrollWheel(id, off, maxOff, pr, 3 * ItemH)
      if scrollPan(id, off, maxOff, pr): comboPanned = true   # (no pick on release)
    if live and mouseIn(pr):
      let i = (ui.my - pr.y - 1 + off) div ItemH
      if i >= 0 and i < list.len:
        if ui.mouseMoved: hi = i
        if (if finger(): ui.released and not comboPanned and not scrollCaught()
            else: ui.pressed):
          pick = list[i]
          ui.pressUsed = true
    elif ui.pressed and not mouseIn(r): st.aux = 0
    if keyMoved and hi >= 0:
      scrollShow(id, off, hi * ItemH, (hi + 1) * ItemH, viewH, maxOff)
    elif hi >= 0 and not scrolling(id) and not mouseIn(pr):
      off = clamp(clamp(off, (hi + 1) * ItemH - viewH, hi * ItemH), 0, maxOff)
    scrollTick(id, off, maxOff)
    if st.aux == 1:
      fill(pr, th.field)
      box(pr, th.edge)
      pushClip(inset(pr, 1))
      let top = off div ItemH
      for k in top ..< min(list.len, top + vis + 1):
        let ir = rect(pr.x + 1, pr.y + 1 + k * ItemH - off, pr.w - 2, ItemH)
        if k == hi: fill(ir, th.select)
        text(ir.x + 2, itemTextY(ir.y), items[list[k]],
             if k == hi: th.selectText else: th.fieldText)
      popClip()
      if accessOn:
        # (the open list and the items it shows; a screen reader's press
        # on one picks it)
        accessBegin(arList, id = id, r = pr)
        for k in top ..< min(list.len, top + vis + 1):
          let iid = accessSubId(id, k)
          if accessPress != 0 and accessPress == iid:
            accessPress = 0
            pick = list[k]
          let n = accessNode(arListItem, items[list[k]], id = iid,
                             r = rect(pr.x + 1, pr.y + 1 + k * ItemH - off, pr.w - 2, ItemH),
                             states = (if k == hi: {asSelected} else: {}))
          accessItem(n, k + 1, list.len)
        accessEnd()
    ui.overlayOwner = false
    popLayer()
    st.caret = hi
    st.scrollY = off
    if pick >= 0:
      text = items[pick]
      st.aux = 0
      result = true
      var es = state(editId)
      es.caret = text.len
      es.anchor = text.len
      state(editId) = es
  if accessOn:
    # (its box says it has a list, and whether it is open)
    for k in countdown(accessTree.high, max(0, accessTree.len - 64)):
      if accessTree[k].id == uint32(editId):
        accessTree[k].states.incl asExpandable
        if st.aux == 1: accessTree[k].states.incl asExpanded
        break
  state(id) = st
  ui.lastId = editId
  ui.lastRect = r

# ---- forms and links ------------------------------------------------------------

var
  formLabelW* = 100    ## the label column of `field`s (logical pixels)
  formAuto, formMax: int
  ## Width of the label column of `field` rows.

template field*(caption: string; body: untyped) =
  ## A form row: `caption` in a label column, then the control(s). In a
  ## narrow space (a phone) the caption goes above the control instead.
  formMax = max(formMax, labelWidth(caption))
  let lw = if formLabelW > 0: formLabelW else: formAuto
  if available() < lw + dp(200):
    label(caption)
    beginRow([-1])
  else:
    beginRowPx([lw, -1])
    label(caption)
  body
  endRow()

template form*(labelWidth: int; body: untyped) =
  ## `field` rows with a label column `labelWidth` design pixels wide, or,
  ## with 0, as wide as the widest caption.
  let savedW = formLabelW
  let savedAuto = formAuto
  let savedMax = formMax
  let formId = idOf("form")
  formLabelW = dp(labelWidth)
  formAuto = max(dp(40), state(formId).aux)
  formMax = 0
  body
  if formMax != state(formId).aux:
    state(formId).aux = formMax
    ui.redraw = true
  formLabelW = savedW
  formAuto = savedAuto
  formMax = savedMax

proc link*(caption: string; enabled = true): bool {.discardable.} =
  ## Underlined clickable text; true when clicked (or Enter/Space).
  let tw = textWidth(caption)
  let r = place(tw + 2, FontH + 2)
  let id = idOf(caption)
  var hit = interact(id, r, enabled = enabled)
  if enabled:
    if hit.hover and canHover(): ui.cursor = curHand
    spaceKey(id, hit)
    if hit.focused: ui.takesEnter = true   # (as a button: before a default button too)
    if hit.focused and keyHit(KeyEnter): hit.clicked = true
  let c = if enabled: th.link else: th.gray
  text(r.x + 1, r.y + 1, caption, c)
  hline(r.x + 1, r.y + FontAscent + 2, tw, c)
  if hit.focused: focusDots(r)
  if accessOn:
    accessNode(arLink, caption, id = id, r = r, states = (if enabled: {} else: {asDisabled}))
  hit.clicked

# ---- dialogs ---------------------------------------------------------------------

proc buttonRow*(labels: openArray[string]): int =
  ## Buttons right-aligned in a row (the first is the default); returns
  ## which was clicked (1-based), 0 if none.
  beginRow()
  spring()
  for i, b in labels:
    if button(b, isDefault = i == 0): result = i + 1
  endRow()

proc inputBox*(open: var bool; title, prompt: string; text: var string;
               password = false; width = 320): int =
  ## Asks for one line of text while `open`; returns 1 for OK, 2 for
  ## Cancel or Esc (once, closing it).
  let was = open
  if beginDialog(open, title, width):
    paragraph prompt
    edit(text, password = password)
    space 2
    result = buttonRow(["OK", "Cancel"])
    if result != 0: open = false
    endDialog()
  if was and not open and result == 0: result = 2

type FileMode* = enum
  ## What a file dialog is for.
  fmOpen        ## pick a file that is there
  fmSave        ## name a file to write
  fmFolder      ## pick a folder (`filePicker`)

when defined(wasm):
  var webPicking = ""       # (the dialog waiting for the browser's file chooser)

  proc webFileDialog*(open: var bool; path: var string; mode: FileMode;
                      patterns: openArray[string]; key: string): bool =
    ## A web page's Open and Save As (`fileDialog`, `filePicker` call it):
    ## opening asks the browser's own file chooser (the file comes in
    ## `/tmp/opened`); saving answers at once with a path in `/downloads`,
    ## and what the app writes there is handed to the user when it is done
    ## (the browser's Save As, or a download).
    if not open:
      if webPicking == key: webPicking = ""
      return false
    case mode
    of fmSave:
      let name = if path.len > 0 and not path.endsWith("/") and not dirExists(path):
                   path.extractFilename
                 else: "Untitled"
      path = "/downloads/" & name
      open = false
      true
    of fmOpen:
      if webPicking != key:
        webPicking = key
        var accept = ""
        for p in patterns:
          let ext = p.replace("*", "")
          if ext.startsWith(".") and '"' notin ext and '\\' notin ext:
            accept.add (if accept.len > 0: "," else: "") & ext
        discard systemCall("pick", "{\"accept\":\"" & accept & "\"}")
        return false
      let r = systemCall("pick.result", "")
      if r.len == 0 or r == "\0": return false
      webPicking = ""
      open = false
      if r == "\x01": return false
      path = r.split('\n')[0]
      true
    of fmFolder:
      false

var fdlg: tuple[opened: bool; dir, name, msg: string; files, dirs,
                drives: seq[string]; fileSel, dirSel, filterIdx, driveIdx: int;
                custom: string]

proc patternsOf(filter: string): seq[string] =
  ## "Text Files (*.txt;*.md)" -> @["*.txt", "*.md"].
  let a = filter.find('(')
  let b = filter.rfind(')')
  let inner = if a >= 0 and b > a: filter[a + 1 ..< b] else: filter
  for p in inner.split({';', ',', ' '}):
    if p.len > 0: result.add p.toLowerAscii

proc globMatch(name, pat: string): bool =
  if pat == "*.*" or pat == "*": return true
  var i = 0
  var j = 0
  var star = -1
  var mark = 0
  let n = name.toLowerAscii
  while i < n.len:
    if j < pat.len and (pat[j] == '?' or pat[j] == n[i]):
      inc i
      inc j
    elif j < pat.len and pat[j] == '*':
      star = j
      mark = i
      inc j
    elif star >= 0:
      j = star + 1
      inc mark
      i = mark
    else:
      return false
  while j < pat.len and pat[j] == '*': inc j
  j == pat.len

proc rescan(filters: openArray[string]) =
  fdlg.files.setLen(0)
  fdlg.dirs.setLen(0)
  let pats = if fdlg.custom.len > 0: @[fdlg.custom]
             elif filters.len > 0: patternsOf(filters[clamp(fdlg.filterIdx, 0, filters.high)])
             else: @["*.*"]
  if fdlg.dir.parentDir != fdlg.dir and fdlg.dir.parentDir.len > 0:
    fdlg.dirs.add ".."
  try:
    for kind, p in walkDir(fdlg.dir, relative = true):
      if p.len == 0 or p[0] == '.': continue
      case kind
      of pcDir, pcLinkToDir: fdlg.dirs.add p
      of pcFile, pcLinkToFile:
        for pat in pats:
          if globMatch(p, pat):
            fdlg.files.add p
            break
  except OSError:
    fdlg.msg = "Cannot read this folder."
  fdlg.files.sort(proc (a, b: string): int = cmp(a.toLowerAscii, b.toLowerAscii))
  if fdlg.dirs.len > 1:
    fdlg.dirs.sort(proc (a, b: string): int =
      if a == "..": -1 elif b == "..": 1 else: cmp(a.toLowerAscii, b.toLowerAscii))
  fdlg.fileSel = -1
  fdlg.dirSel = -1

const phone = androidApp or defined(ios)

proc startDir(): string =
  ## Where the dialog opens: phones, the app's own folder (the only one it
  ## may write to); desktops, the folder the program was started in when
  ## that is the user's own (a terminal's), else the home folder -- the
  ## Finder, the Start menu and a desktop's menu start programs in /,
  ## System32 or the program's folder.
  when phone: dataDir("")
  else:
    let home = getHomeDir().normalizedPath
    let cur = getCurrentDir().normalizedPath
    when defined(windows):
      if cur.toLowerAscii.startsWith(home.toLowerAscii): cur else: home
    else:
      if cur == home or cur.startsWith(home & "/"): cur else: home

proc downloadsDir*(): string =
  ## The user's Downloads folder (where the system keeps it: XDG's on Linux
  ## and the BSDs, in the user's language; Windows' Known Folder, moved to
  ## another drive or not; "Download" on a phone's storage), else the home
  ## folder: where Save As starts for a file that came from elsewhere (an
  ## attachment, a download).
  when androidApp:
    for p in ["/storage/emulated/0/Download", "/sdcard/Download"]:
      if dirExists(p): return p
    return dataDir("")
  else:
    let p = standardFolder("downloads")
    if p.len > 0 and dirExists(p): return p
    for sub in ["Downloads", "Download"]:
      if dirExists(getHomeDir() / sub): return getHomeDir() / sub
    getHomeDir()

proc listDrives(): seq[string] =
  when defined(windows):
    for c in 'A' .. 'Z':
      if dirExists($c & ":\\"): result.add $c & ":"
  elif phone:
    result.add dataDir("")
  else:
    result.add "/"
    result.add getHomeDir()

proc shortDir(d: string; maxW: int): string =
  result = d
  while result.len > 4 and textWidth(result) > maxW:
    result = "..." & result[min(result.len - 1, 4) .. ^1]

proc fileDialog*(open: var bool; path: var string; mode = fmOpen;
                 filters: openArray[string] = ["All Files (*.*)"];
                 title = ""): bool =
  ## The 3.1 Open / Save As dialog while `open`. Returns true once, with
  ## `path` set, when the user confirms a file. (In a web page: the
  ## browser's file chooser, and Save As through `/downloads`.)
  when defined(wasm):
    if mode != fmFolder:
      var pats: seq[string]
      for f in filters: pats.add patternsOf(f)
      return webFileDialog(open, path, mode, pats, "fileDialog")
  if not open:
    fdlg.opened = false
    return false
  if not fdlg.opened:
    fdlg.opened = true
    fdlg.msg = ""
    fdlg.custom = ""
    fdlg.filterIdx = 0
    if path.len > 0 and dirExists(path):
      fdlg.dir = path
      fdlg.name = ""
    elif path.len > 0:
      fdlg.dir = if path.parentDir.len > 0: path.parentDir else: startDir()
      fdlg.name = path.extractFilename
    else:
      fdlg.dir = startDir()
      fdlg.name = ""
    fdlg.dir = absolutePath(fdlg.dir)
    fdlg.drives = listDrives()
    fdlg.driveIdx = 0
    rescan(filters)
  template enter(d: string) =
    fdlg.dir = normalizedPath(d)
    fdlg.msg = ""
    rescan(filters)
  template accept() =
    let n = fdlg.name.strip
    if n.contains('*') or n.contains('?'):
      fdlg.custom = n.toLowerAscii
      rescan(filters)
    elif n.len > 0:
      let full = if isAbsolute(n): n else: fdlg.dir / n
      if dirExists(full):
        enter(full)
        fdlg.name = ""
      elif mode == fmOpen and not fileExists(full):
        fdlg.msg = n & ": file not found."
      else:
        path = full
        open = false
        result = true
  let ttl = if title.len > 0: title elif mode == fmOpen: "Open" elif mode == fmFolder: "Choose a Folder"
            else: "Save As"
  if beginDialog(open, ttl, 440):
    row([-1, 170]):
      col:
        label "File &Name:"
        edit fdlg.name
        if listbox(fdlg.files, fdlg.fileSel, rows = 8):
          fdlg.name = fdlg.files[fdlg.fileSel]
        if doubleClicked(): accept()
        label "List Files of &Type:"
        if combo(filters, fdlg.filterIdx, w = available()):
          fdlg.custom = ""
          rescan(filters)
      col:
        label "&Directories:"
        label shortDir(fdlg.dir, 160)
        discard listbox(fdlg.dirs, fdlg.dirSel, rows = 8)
        if doubleClicked() and fdlg.dirSel >= 0:
          let d = fdlg.dirs[fdlg.dirSel]
          enter(if d == "..": fdlg.dir.parentDir else: fdlg.dir / d)
        label "Dri&ves:"
        if combo(fdlg.drives, fdlg.driveIdx, w = available()):
          enter(fdlg.drives[fdlg.driveIdx] & (when defined(windows): "\\" else: ""))
    if fdlg.msg.len > 0: label fdlg.msg, color = color(192, 0, 0)
    case buttonRow(["OK", "Cancel"])
    of 1: accept()
    of 2: open = false
    else: discard
    endDialog()

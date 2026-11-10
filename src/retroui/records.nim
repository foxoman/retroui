## Business controls for data-entry apps:
##
## - `maskedEdit`: a field typed into a mask ("(###) ####-####", "UU-####")
## - `recordNav`: the record navigator of database forms (``|< < 3 of 20 > >|``,
##   New, Delete, Save, Cancel)
## - `dualList`: two lists to move items between (Available / Chosen)
## - `dateRange`: from and to dates with presets (This month, Last year...)
## - `propertyGrid`: names and values by category, each edited in place
##   (text, numbers, yes / no, choices, colors, dates), with a help line
## - `treeGrid`: a tree with columns (a chart of accounts, a bill of
##   materials) that opens and closes
## - `wizard`: a dialog of steps with Back, Next, Finish and Cancel
##
## All of them take the mouse, the keyboard and fingers, and scroll with
## the standard scroll bar when they hold more than fits.
##
## ```nim
## var phone = ""
## var pos = 0
## var props = @[textProp("Name", "Main store", "General"),
##               boolProp("Open on Fridays", true, "Hours")]
## var propSel = 0
## app "Records", 600, 400:
##   form 0:
##     field "&Phone:": maskedEdit(phone, "+### #### ####")
##   case recordNav(pos, 20)
##   of raNew: echo "a new record"
##   else: discard
##   discard propertyGrid(props, propSel, height = 200)
## ```

import std/[strutils, tables, unicode, algorithm, hashes]
import gfx, core, widgets, business, extras, pixelicons, nerdicons
import uirelays/input

template th: untyped = ui.theme

var intSlots: Table[Id, ref int]

proc slot(key: Id): ref int =
  ## An int that lives as long as the app (for widgets bound to a var).
  result = intSlots.getOrDefault(key, nil)
  if result == nil:
    new(result)
    intSlots[key] = result

# ---- masked fields -------------------------------------------------------------------------------

type MaskTok = tuple[slot: bool; c: char]

proc parseMask(mask: string): seq[MaskTok] =
  var i = 0
  while i < mask.len:
    let c = mask[i]
    if c == '\\' and i + 1 < mask.len:
      result.add (false, mask[i + 1])
      i += 2
      continue
    result.add (c in {'#', '9', 'A', 'U', 'L', 'X', '*'}, c)
    inc i

proc fits(kind, ch: char): bool =
  case kind
  of '#', '9': ch in Digits
  of 'A', 'U', 'L': ch in Letters
  of 'X': ch in Letters + Digits
  else: ch in {' ' .. '~'}

proc shaped(kind, ch: char): char =
  case kind
  of 'U': ch.toUpperAscii
  of 'L': ch.toLowerAscii
  else: ch

proc maskSlotCount*(mask: string): int =
  ## How many characters `mask` takes.
  for t in parseMask(mask):
    if t.slot: inc result

proc maskValid(value: string; toks: seq[MaskTok]): bool =
  var k = 0
  for t in toks:
    if not t.slot: continue
    if k >= value.len: return true
    if not fits(t.c, value[k]): return false
    inc k
  k >= value.len

proc maskFormat*(value, mask: string; blank = '_'): string =
  ## `value` (the characters typed) laid into `mask`:
  ## `maskFormat("96891234567", "+### #### ####")` is "+968 9123 4567";
  ## slots not typed yet show `blank`. Mask characters: `#` or `9` a
  ## digit, `A` a letter, `U` a letter made upper case, `L` lower case,
  ## `X` a letter or digit, `*` any; ``\`` takes the next one as it is; the
  ## rest is shown as it is.
  var k = 0
  for t in parseMask(mask):
    if t.slot:
      if k < value.len:
        result.add value[k]
        inc k
      else: result.add blank
    else: result.add t.c

proc maskFull*(value, mask: string): bool =
  ## Every slot of `mask` is typed, each with what it takes.
  let toks = parseMask(mask)
  value.len == maskSlotCount(mask) and maskValid(value, toks)

proc maskRaw*(text, mask: string): string =
  ## The characters typed, from a text laid out like `mask` (or typed
  ## loosely: what does not fit the next slot is skipped).
  let toks = parseMask(mask)
  var k = 0
  var slots: seq[char]
  for t in toks:
    if t.slot: slots.add t.c
  for ch in text:
    if k >= slots.len: break
    if fits(slots[k], ch):
      result.add shaped(slots[k], ch)
      inc k

proc asciiDigit(r: Rune): char =
  ## Arabic-Indic and Persian digits typed: the digit they are.
  let c = int(r)
  if c in 0x0660 .. 0x0669: char(ord('0') + c - 0x0660)
  elif c in 0x06F0 .. 0x06F9: char(ord('0') + c - 0x06F0)
  elif c < 128: char(c)
  else: '\0'

var maskCaretT: int

proc maskedEdit*(value: var string; mask: string; w = 0;
                 enabled = true): bool {.discardable.} =
  ## A field typed into `mask` (see `maskFormat`): the literals are there
  ## already, the caret jumps over them, only what a slot takes goes in
  ## (Arabic-Indic digits become digits). `value` holds the characters
  ## typed, without the literals (`maskFormat` shows them, `maskFull`
  ## tells when it is complete). Left, Right, Home, End, Backspace,
  ## Delete, Ctrl+C / Ctrl+V. True when `value` changed.
  let toks = parseMask(mask)
  var slots: seq[char]
  for t in toks:
    if t.slot: slots.add t.c
  let n = slots.len
  if value.len > n: value.setLen(n)
  var sample = ""
  for t in toks: sample.add(if t.slot: 'W' else: t.c)
  let r = place(if w > 0: w else: textWidth(sample) + dp(12), EditH)
  let id = idOf(value, "masked")
  var hit = interact(id, r, enabled = enabled)
  var st = state(id)
  var caret = clamp(st.caret, 0, value.len)
  let inner = inset(r, 2)
  let tx = inner.x + 2
  # where each slot sits on screen
  var slotX = newSeq[int](n + 1)
  var x = tx
  var k = 0
  let shownText = maskFormat(value, mask)
  var ti = 0
  for t in toks:
    let ch = shownText[ti]
    if t.slot:
      slotX[k] = x
      inc k
    x += textWidth($ch)
    inc ti
  slotX[n] = x
  proc tryPut(v: var string; at: int; ch: char): bool =
    if at >= n or not fits(slots[at], ch): return false
    let c = shaped(slots[at], ch)
    # typing over: the slot's character is replaced; at the end: added
    var cand = v
    if at < cand.len: cand[at] = c else: cand.add c
    if maskValid(cand, toks):
      v = cand
      return true
  var changed = false
  if accessOn and enabled and accessValueFor(id):
    # (a screen reader put a text in: what fits the slots goes in)
    var nv = ""
    for ch in accessSet.text:
      let d = asciiDigit(Rune(ord(ch)))
      discard tryPut(nv, nv.len, if d != '\0': d else: ch)
    if nv != value:
      value = nv
      caret = nv.len
      changed = true
  if enabled and canInput():
    if hit.down and ui.pressed or (hit.clicked and finger()):
      # the slot nearest to the click
      var best = 0
      for i in 0 .. min(n, value.len):
        if abs(slotX[i] - ui.mx) < abs(slotX[best] - ui.mx): best = i
      caret = best
      maskCaretT = ui.now
    if hit.focused:
      ui.takesText = true                   # (the on-screen keyboard on phones)
      let ctrl = CtrlPressed in ui.mods
      case ui.key
      of KeyLeft: caret = max(0, caret - 1); ui.keyUsed = true
      of KeyRight: caret = min(value.len, caret + 1); ui.keyUsed = true
      of KeyHome: caret = 0; ui.keyUsed = true
      of KeyEnd: caret = value.len; ui.keyUsed = true
      of KeyBackspace:
        ui.keyUsed = true
        if caret > 0:
          var cand = value
          cand.delete(caret - 1 .. caret - 1)
          while not maskValid(cand, toks): cand.setLen(cand.len - 1)
          value = cand
          dec caret
          changed = true
      of KeyDelete:
        ui.keyUsed = true
        if caret < value.len:
          var cand = value
          cand.delete(caret .. caret)
          while not maskValid(cand, toks): cand.setLen(cand.len - 1)
          value = cand
          changed = true
      of KeyC:
        if ctrl:
          putClipboardText(maskFormat(value, mask, ' ').strip)
          ui.keyUsed = true
      of KeyX:
        if ctrl:
          putClipboardText(maskFormat(value, mask, ' ').strip)
          value = ""
          caret = 0
          changed = true
          ui.keyUsed = true
      of KeyV:
        if ctrl:
          ui.keyUsed = true
          for r in getClipboardText().runes:
            let ch = asciiDigit(r)
            if ch != '\0' and tryPut(value, caret, ch):
              inc caret
              changed = true
      else: discard
      if ui.typed.len > 0:
        for r in ui.typed.runes:
          let ch = asciiDigit(r)
          if ch != '\0' and tryPut(value, caret, ch):
            inc caret
            changed = true
        ui.typed.setLen(0)
      if ui.keyUsed or changed: maskCaretT = ui.now
  if hit.focused and st.aux2 == 0: maskCaretT = ui.now   # the caret shows at once on focus
  st.aux2 = ord(hit.focused)
  st.caret = clamp(caret, 0, value.len)
  state(id) = st
  # draw: what is typed in the field's color, the blanks gray
  fill(r, if enabled: th.field else: th.face)
  fieldFrame(r, enabled)
  pushClip(inset(r, 1))
  let ty = r.y + (r.h - FontH) div 2
  let full = maskFormat(value, mask)
  x = tx
  k = 0
  ti = 0
  for t in toks:
    let ch = $full[ti]
    let c = if not enabled: th.gray
            elif t.slot and k >= value.len: th.gray
            else: th.fieldText
    if t.slot: inc k
    text(x, ty, ch, c)
    x += textWidth(ch)
    inc ti
  if hit.focused and enabled:
    let since = ui.now - maskCaretT
    if since >= CaretBlinkFor or (since div 530) mod 2 == 0:
      vline(slotX[st.caret], ty, FontH, th.fieldText)
    if since < CaretBlinkFor: wakeIn(min(530 - since mod 530, CaretBlinkFor - since))
  popClip()
  if accessOn:
    let k = accessNode(arTextField, value = full, states = accessOff(enabled), id = id, r = r,
                       help = mask)
    accessText(k, st.caret, st.caret, st.caret)
  ui.lastId = id
  ui.lastRect = r
  changed

# ---- the record navigator ----------------------------------------------------------------------

type RecordAction* = enum
  ## What `recordNav` asks for.
  raNone, raFirst, raPrev, raNext, raLast, raGoto, raNew, raDelete, raSave, raCancel

proc vcrButton(id: Id; kind: int; enabled: bool; size: int): bool =
  ## |< < > >| buttons, drawn as the triangles of a tape deck (4 and 5:
  ## up and down).
  let r = place(size, CtrlH)
  var hit = interact(id, r, focusable = false, enabled = enabled)
  if accessOn:
    accessNode(arButton, ["First", "Previous", "Next", "Last", "Up", "Down"][clamp(kind, 0, 5)],
               id = id, r = r, states = accessOff(enabled))
  buttonFace(r, hit.down, rounded = false, bevel = 1, hot = enabled and hovered(r))
  let c = if enabled: th.text else: th.gray
  let o = if hit.down: 1 else: 0
  let cx = r.x + r.w div 2 + o
  let cy = r.y + r.h div 2 + o
  let a = dp(5)
  case kind
  of 0:
    vline(cx - a + 1, cy - a + 1, 2 * a - 1, c)
    arrow(cx + 1, cy, dLeft, c, a)
  of 1: arrow(cx, cy, dLeft, c, a)
  of 2: arrow(cx, cy, dRight, c, a)
  of 3:
    arrow(cx - 1, cy, dRight, c, a)
    vline(cx + a - 1, cy - a + 1, 2 * a - 1, c)
  of 4: arrow(cx, cy, dUp, c, a)
  else: arrow(cx, cy, dDown, c, a)
  hit.clicked

proc recordNav*(pos: var int; count: int; dirty = false; canAdd = true;
                canDelete = true; key = ""): RecordAction {.discardable.} =
  ## The navigator of a form over records: first, previous, "Record 3 of
  ## 20" (type a number to go there), next, last, then New, Delete, Save and
  ## Cancel (Save and Cancel while the record is `dirty`). `pos` is the
  ## record shown (0-based); the moves change it. Ctrl+Home / Ctrl+End,
  ## Ctrl+PageUp / Ctrl+PageDown move too. On phones it is shorter.
  let id = idOf("recordnav:" & key)
  let last = max(0, count - 1)
  pos = clamp(pos, 0, last)
  let before = pos
  let s = CtrlH
  let compact = isCompact()
  # keys: Ctrl + Home / End / PageUp / PageDown (before the record number's
  # box, which would take Ctrl+Home and Ctrl+End for its caret)
  if canInput() and not ui.keyUsed and CtrlPressed in ui.mods and count > 0:
    case ui.key
    of KeyHome: pos = 0; result = raFirst; ui.keyUsed = true
    of KeyEnd: pos = last; result = raLast; ui.keyUsed = true
    of KeyPageUp: pos = max(0, pos - 1); result = raPrev; ui.keyUsed = true
    of KeyPageDown: pos = min(last, pos + 1); result = raNext; ui.keyUsed = true
    else: discard
  row:
    if vcrButton(id + 1, 0, pos > 0, s): pos = 0; result = raFirst
    if vcrButton(id + 2, 1, pos > 0, s): pos = max(0, pos - 1); result = raPrev
    if not compact: label "Record"
    let shown = slot(id + 3)
    shown[] = pos + 1
    if intEdit(shown[], w = dp(52), lo = 1, hi = max(1, count)) and count > 0:
      pos = clamp(shown[] - 1, 0, last)
      result = raGoto
    label("of " & $count)
    if vcrButton(id + 4, 2, pos < last, s): pos = min(last, pos + 1); result = raNext
    if vcrButton(id + 5, 3, pos < last, s): pos = last; result = raLast
    if not compact: space(dp(12))
    if canAdd:
      if (if compact: toolButton(retroOr(pxNew, nfPlus), "New record")
          else: button("&New", enabled = not dirty)): result = raNew
    if canDelete:
      if (if compact: toolButton(retroOr(pxDelete, nfTrash), "Delete the record",
                                 enabled = count > 0)
          else: button("&Delete", enabled = count > 0 and not dirty)): result = raDelete
    if dirty:
      if (if compact: toolButton(retroOr(pxSave, nfSave), "Save")
          else: button("&Save", isDefault = true)): result = raSave
      if (if compact: toolButton(retroOr(pxUndo, nfUndo), "Cancel the changes")
          else: button("Cancel")): result = raCancel
  if result in {raFirst, raPrev, raNext, raLast, raGoto} and pos == before and
     result != raGoto:
    result = raNone

# ---- two lists ----------------------------------------------------------------------------------

proc dualList*(available, chosen: var seq[string]; rows = 8;
               titles = ("&Available:", "&Chosen:"); sortAvailable = true;
               key = ""): bool {.discardable.} =
  ## Two lists and the buttons between them: > moves the item picked on
  ## the left to the right, >> all of them, < and << back; a double click
  ## (or Enter) moves an item across. Up / Down buttons order the chosen
  ## ones. On phones the lists are stacked. True when the lists changed.
  let id = idOf("duallist:" & key)
  let a = slot(id + 1)
  let b = slot(id + 2)
  a[] = clamp(a[], 0, max(0, available.high))
  b[] = clamp(b[], 0, max(0, chosen.high))
  template moveRight(i: int) =
    let at = i
    if at in 0 .. available.high:
      chosen.add available[at]
      available.delete(at)
      result = true
  template moveLeft(i: int) =
    let at = i
    if at in 0 .. chosen.high:
      available.add chosen[at]
      chosen.delete(at)
      if sortAvailable: available.sort(proc (x, y: string): int = cmpIgnoreCase(x, y))
      result = true
  let bw = if fingers(): dp(56) else: dp(44)
  template buttons() =
    if button(">", enabled = available.len > 0, w = bw): moveRight(a[])
    if button(">>", enabled = available.len > 0, w = bw):
      chosen.add available
      available.setLen(0)
      result = true
    if button("<", enabled = chosen.len > 0, w = bw): moveLeft(b[])
    if button("<<", enabled = chosen.len > 0, w = bw):
      available.add chosen
      chosen.setLen(0)
      if sortAvailable: available.sort(proc (x, y: string): int = cmpIgnoreCase(x, y))
      result = true
  template leftList() =
    label titles[0]
    discard listbox(available, a[], rows = rows)
    if doubleClicked(): moveRight(a[])
  template rightList() =
    label titles[1]
    discard listbox(chosen, b[], rows = rows)
    if doubleClicked(): moveLeft(b[])
    row:
      if vcrButton(id + 5, 4, b[] > 0, CtrlH):           # up
        swap(chosen[b[]], chosen[b[] - 1])
        dec b[]
        result = true
      if vcrButton(id + 6, 5, b[] < chosen.high, CtrlH): # down
        swap(chosen[b[]], chosen[b[] + 1])
        inc b[]
        result = true
  if isCompact():
    leftList()
    row: buttons()
    rightList()
  else:
    beginRowPx([-1, bw + dp(8), -1], CtrlH)
    block:
      col: leftList()
      col:
        space(FontH + dp(16))
        buttons()
      col: rightList()
    endRow()
  a[] = clamp(a[], 0, max(0, available.high))
  b[] = clamp(b[], 0, max(0, chosen.high))

# ---- date ranges ----------------------------------------------------------------------------------

type RangePreset* = enum
  ## The periods `dateRange` offers.
  rpCustom = "Custom", rpToday = "Today", rpYesterday = "Yesterday",
  rpThisWeek = "This week", rpLastWeek = "Last week",
  rpThisMonth = "This month", rpLastMonth = "Last month",
  rpThisQuarter = "This quarter", rpLastQuarter = "Last quarter",
  rpThisYear = "This year", rpLastYear = "Last year",
  rpLast7 = "Last 7 days", rpLast30 = "Last 30 days", rpLast90 = "Last 90 days"

proc presetRange*(p: RangePreset; day = today()): tuple[a, b: Date] =
  ## The first and last day of the period `p` around `day` (weeks start on
  ## `firstWeekday`).
  let d = day
  proc weekStart(x: Date): Date =
    x.addDays(-((weekday(x) - firstWeekday + 7) mod 7))
  case p
  of rpCustom, rpToday: (d, d)
  of rpYesterday: (d.addDays(-1), d.addDays(-1))
  of rpThisWeek: (weekStart(d), weekStart(d).addDays(6))
  of rpLastWeek: (weekStart(d).addDays(-7), weekStart(d).addDays(-1))
  of rpThisMonth: (date(d.year, d.month, 1), date(d.year, d.month, daysInMonth(d.year, d.month)))
  of rpLastMonth:
    let m = date(d.year, d.month, 1).addMonths(-1)
    (m, date(m.year, m.month, daysInMonth(m.year, m.month)))
  of rpThisQuarter, rpLastQuarter:
    var q = date(d.year, (d.month - 1) div 3 * 3 + 1, 1)
    if p == rpLastQuarter: q = q.addMonths(-3)
    let e = q.addMonths(2)
    (q, date(e.year, e.month, daysInMonth(e.year, e.month)))
  of rpThisYear: (date(d.year, 1, 1), date(d.year, 12, 31))
  of rpLastYear: (date(d.year - 1, 1, 1), date(d.year - 1, 12, 31))
  of rpLast7: (d.addDays(-6), d)
  of rpLast30: (d.addDays(-29), d)
  of rpLast90: (d.addDays(-89), d)

proc dateRange*(a, b: var Date; presets = true; key = ""): bool {.discardable.} =
  ## From and to dates (each with its drop-down calendar) and, with
  ## `presets`, a list of periods (Today, This month, Last year...) that
  ## sets both; it shows the period the dates make, else "Custom". The
  ## "to" date is never before the "from" one. True when they changed.
  let id = idOf("daterange:" & key)
  if not a.valid: a = today()
  if not b.valid: b = a
  let p = slot(id + 1)
  p[] = 0
  for k in RangePreset:
    if k != rpCustom and presetRange(k) == (a, b):
      p[] = ord(k)
      break
  var names: seq[string]
  for k in RangePreset: names.add $k
  let before = (a, b)
  row:
    if presets:
      if combo(names, p[], w = dp(130)) and p[] != 0:
        (a, b) = presetRange(RangePreset(p[]))
    label "&From"
    discard datePicker(a)
    label "&To"
    discard datePicker(b)
  if dayNumber(b) < dayNumber(a):
    if a != before[0]: b = a else: a = b
  (a, b) != before

# ---- the property grid --------------------------------------------------------------------------

type
  PropKind* = enum
    ## What a `Prop` holds and how it is edited (`pkInfo`: shown, not edited).
    pkText, pkNumber, pkInt, pkBool, pkChoice, pkColor, pkDate, pkInfo
  Prop* = object
    ## One line of a `propertyGrid`.
    name*, category*, help*: string
      ## its name, the category it is listed under, and the help line shown
      ## when it is chosen
    kind*: PropKind        ## what it holds (the fields below say whose they are)
    text*: string          ## pkText, pkInfo
    num*: float            ## pkNumber
    decimals*: int         ## ... the digits after the point
    n*: int                ## pkInt; pkChoice: the one chosen
    on*: bool              ## pkBool
    choices*: seq[string]  ## pkChoice
    color*: Color          ## pkColor
    date*: Date            ## pkDate
    readOnly*: bool        ## shown, not edited

proc textProp*(name, value: string; category = ""; help = ""): Prop =
  ## A line of text to edit.
  Prop(name: name, kind: pkText, text: value, category: category, help: help)
proc numberProp*(name: string; value: float; decimals = 2; category = "";
                 help = ""): Prop =
  ## A number to edit, shown with `decimals` places.
  Prop(name: name, kind: pkNumber, num: value, decimals: clamp(decimals, 0, 12),
       category: category, help: help)
proc intProp*(name: string; value: int; category = ""; help = ""): Prop =
  ## A whole number to edit.
  Prop(name: name, kind: pkInt, n: value, category: category, help: help)
proc boolProp*(name: string; value: bool; category = ""; help = ""): Prop =
  ## A check box.
  Prop(name: name, kind: pkBool, on: value, category: category, help: help)
proc choiceProp*(name: string; choices: openArray[string]; chosen = 0;
                 category = ""; help = ""): Prop =
  ## One of `choices` (`chosen` is the index of the one chosen).
  Prop(name: name, kind: pkChoice, choices: @choices, n: chosen,
       category: category, help: help)
proc colorProp*(name: string; value: Color; category = ""; help = ""): Prop =
  ## A color to pick.
  Prop(name: name, kind: pkColor, color: value, category: category, help: help)
proc dateProp*(name: string; value: Date; category = ""; help = ""): Prop =
  ## A date to pick.
  Prop(name: name, kind: pkDate, date: value, category: category, help: help)
proc infoProp*(name, value: string; category = ""; help = ""): Prop =
  ## Text shown, not edited.
  Prop(name: name, kind: pkInfo, text: value, category: category, help: help,
       readOnly: true)

proc valueText*(p: Prop): string =
  ## A property's value as the grid shows it.
  case p.kind
  of pkText, pkInfo: p.text
  of pkNumber: formatNumber(p.num, clamp(p.decimals, 0, 12))
  of pkInt: $p.n
  of pkBool: (if p.on: "Yes" else: "No")
  of pkChoice: (if p.n in 0 .. p.choices.high: p.choices[p.n] else: "")
  of pkColor: hexOf(p.color)
  of pkDate: $p.date

var propFold: Table[string, bool]       # categories folded away
var propBuf: Table[Id, string]          # the text being typed into a value

proc propertyGrid*(props: var seq[Prop]; sel: var int; height = -1;
                   help = true; key = ""): int {.discardable.} =
  ## Properties as names and values in two columns, by `category` (a
  ## category folds away with its ``[-]`` box), the chosen one edited in place:
  ## text and numbers typed, Yes / No flipped with a click or Space,
  ## choices dropped down (or flipped through with a double click), colors
  ## typed as #RRGGBB or picked, dates with their calendar. The `help` line
  ## under it tells what the chosen property is. Up / Down move, Enter (or
  ## typing) edits, Esc goes back to the list. Drag the line between the
  ## columns to resize them. Returns the index of the property changed this
  ## frame, -1 if none.
  result = -1
  let id = idOf("propgrid:" & key)
  let h = if height < 0: remainingH() else: height
  let whole = place(0, h, fill = true)
  var st = state(id)
  let helpH = if help: FontH * 3 + dp(10) else: 0
  let gridR = rect(whole.x, whole.y, whole.w, whole.h - helpH - (if help: dp(4) else: 0))
  let rh = max(ItemH + 4, EditH)
  # the rows: categories and properties (those of folded categories left out)
  type Line = tuple[cat: string; prop: int]
  var lines: seq[Line]
  var cats: seq[string]
  for p in props:
    if p.category.len > 0 and p.category notin cats: cats.add p.category
  let grouped = cats.len > 0
  if grouped:
    for c in cats:
      lines.add (c, -1)
      if not propFold.getOrDefault(key & "\0" & c, false):
        for i, p in props:
          if p.category == c: lines.add ("", i)
    for i, p in props:
      if p.category.len == 0: lines.add ("", i)
  else:
    for i in 0 ..< props.len: lines.add ("", i)
  sel = clamp(sel, 0, max(0, props.high))
  let contentH = lines.len * rh
  let bar = contentH > gridR.h - 2
  let area = rect(gridR.x + 1, gridR.y + 1, gridR.w - 2 - (if bar: SbW - 1 else: 0),
                  gridR.h - 2)
  let indent = if grouped: dp(14) else: 0
  var nameW = if st.aux2 > 0: st.aux2 else: area.w * 2 div 5
  nameW = clamp(nameW, dp(60), max(dp(60), area.w - dp(60)))
  var top = clamp(st.scrollY, 0, max(0, contentH - area.h))
  let hit = interact(id, area)
  let editId = id + 100
  let lineOfSel = block:
    var at = -1
    for k, l in lines:
      if l.prop == sel: at = k
    at
  var follow = false
  # the line between the columns: drag it
  let divX = area.x + indent + nameW
  let divR = rect(divX - 3, area.y, 6, area.h)
  if canInput() and mouseIn(divR): ui.cursor = curSizeWE
  if canInput() and hover(divR) and takePress():
    ui.active = id + 7
    ui.dragsActive = true
  if ui.active == id + 7 and ui.mouseDown:
    nameW = clamp(ui.mx - area.x - indent, dp(60), max(dp(60), area.w - dp(60)))
    ui.cursor = curSizeWE
  # the mouse and fingers
  let maxTop = max(0, contentH - area.h)
  if canInput():
    scrollWheel(id, top, maxTop, area, 3 * rh)
    scrollPan(id, top, maxTop, area)
    if tapped(id, hit) and ui.active != id + 7:
      let k = (ui.my - area.y + top) div rh
      if k in 0 .. lines.high:
        let l = lines[k]
        if l.prop < 0:
          let fk = key & "\0" & l.cat
          propFold[fk] = not propFold.getOrDefault(fk, false)
        else:
          let onValue = ui.mx >= divX
          let i = l.prop
          if i != sel:
            sel = i
            follow = true
          if onValue and not props[i].readOnly:
            case props[i].kind
            of pkBool:
              props[i].on = not props[i].on
              result = i
            of pkChoice:
              if ui.clicks >= 2 and props[i].choices.len > 0:
                props[i].n = (props[i].n + 1) mod props[i].choices.len
                result = i
              else:
                openPopupMenu("propgrid-choice:" & key, divX, area.y + (k + 1) * rh - top)
            of pkText, pkNumber, pkInt, pkColor:
              ui.focus = editId
            else: discard
  # keys
  if hit.focused and sel in 0 ..< props.len and not props[sel].readOnly:
    ui.takesEnter = true           # (Enter edits it or opens its choices: #9)
  if hit.focused and canInput() and props.len > 0:
    var k = lineOfSel
    if ui.key == KeyDown and AltPressed in ui.mods and sel in 0 ..< props.len and
       props[sel].kind == pkChoice and not props[sel].readOnly and k >= 0:
      # (Alt+Down drops a choice's list, as F4 and Enter do)
      openPopupMenu("propgrid-choice:" & key, divX, area.y + (k + 1) * rh - top)
      ui.keyUsed = true
    case ui.key
    of KeyUp, KeyDown:
      if not ui.keyUsed:
        let d = if ui.key == KeyUp: -1 else: 1
        var j = k + d
        while j in 0 .. lines.high and lines[j].prop < 0: j += d
        if j in 0 .. lines.high:
          sel = lines[j].prop
          follow = true
        ui.keyUsed = true
    of KeyHome, KeyEnd:
      var j = if ui.key == KeyHome: 0 else: lines.high
      let d = if ui.key == KeyHome: 1 else: -1
      while j in 0 .. lines.high and lines[j].prop < 0: j += d
      if j in 0 .. lines.high:
        sel = lines[j].prop
        follow = true
      ui.keyUsed = true
    of KeySpace:
      if props[sel].kind == pkBool and not props[sel].readOnly:
        props[sel].on = not props[sel].on
        result = sel
        ui.keyUsed = true
    of KeyEnter, KeyF2, KeyF4:
      if not props[sel].readOnly:
        case props[sel].kind
        of pkText, pkNumber, pkInt, pkColor: ui.focus = editId
        of pkChoice:
          if k >= 0: openPopupMenu("propgrid-choice:" & key, divX, area.y + (k + 1) * rh - top)
        of pkBool:
          props[sel].on = not props[sel].on
          result = sel
        else: discard
        ui.keyUsed = true
    else:
      if ui.typed.len > 0 and not props[sel].readOnly and
         props[sel].kind in {pkText, pkNumber, pkInt, pkColor}:
        propBuf[editId] = ui.typed
        ui.focus = editId
        var es = state(editId)
        es.caret = ui.typed.len
        es.anchor = es.caret
        state(editId) = es
        ui.typed.setLen(0)
  # a screen reader: a row picked (a category folded), a value put in
  template catId(c: string): Id = accessSubId(id, 0x200000 + int(hash(c) and 0xFFFFF))
  template valId(i: int): Id = accessSubId(id, 0x100000 + i)
  if accessPress != 0:
    for l in lines:
      if l.prop < 0:
        if accessPress == catId(l.cat):
          accessPress = 0
          let fk = key & "\0" & l.cat
          propFold[fk] = not propFold.getOrDefault(fk, false)
          ui.redraw = true
      elif accessPress == accessSubId(id, l.prop) or accessPress == valId(l.prop):
        let onValue = accessPress == valId(l.prop)
        accessPress = 0
        sel = l.prop
        follow = true
        ui.focus = id
        if onValue and not props[sel].readOnly and props[sel].kind == pkBool:
          props[sel].on = not props[sel].on
          result = sel
      if accessPress == 0: break
  if accessOn:
    for i in 0 ..< props.len:
      if not props[i].readOnly and accessValueFor(valId(i)):
        let t = accessSet.text
        case props[i].kind
        of pkText: props[i].text = t
        of pkNumber:
          var v: float
          if parseNumber(t, v): props[i].num = v
        of pkInt:
          try: props[i].n = parseInt(t.strip) except ValueError: discard
        of pkBool: props[i].on = t.toLowerAscii in ["yes", "1", "true", "on"]
        of pkChoice:
          let at = props[i].choices.find(t)
          if at >= 0: props[i].n = at
        of pkColor:
          var c: Color
          if parseHexColor(t, c): props[i].color = c
        of pkDate:
          var d: Date
          if parseDate(t, d): props[i].date = d
        else: discard
        sel = i
        result = i
        break
  let selLine = block:
    var at = -1
    for k, l in lines:
      if l.prop == sel: at = k
    at
  if follow and selLine >= 0:
    scrollShow(id, top, selLine * rh, (selLine + 1) * rh, area.h, maxTop)
  scrollTick(id, top, maxTop)
  if bar:
    scrollBarFor(id + 9, id, rect(gridR.x + gridR.w - SbW, gridR.y, SbW, gridR.h), true,
                 top, maxTop, max(rh, area.h - 2 * rh), rh)
  top = clamp(top, 0, maxTop)
  # draw
  fill(gridR, th.field)
  box(gridR, th.edge)
  pushClip(area)
  let first = top div rh
  for k in first .. min(lines.high, first + area.h div rh + 1):
    let y = area.y + k * rh - top
    let l = lines[k]
    if l.prop < 0:
      # a category: its fold box and its name, on the face color
      fill(rect(area.x, y, area.w, rh), th.face)
      let folded = propFold.getOrDefault(key & "\0" & l.cat, false)
      let bs = dp(9)
      let b = rect(area.x + (indent - bs) div 2, y + (rh - bs) div 2, bs, bs)
      fill(b, th.field)
      box(b, th.shadow)
      hline(b.x + 2, b.y + bs div 2, bs - 4, th.text)
      if folded: vline(b.x + bs div 2, b.y + 2, bs - 4, th.text)
      text(area.x + indent + dp(2), y + (rh - FontH) div 2, l.cat, th.text, true)
      hline(area.x, y + rh - 1, area.w, th.shadow)
      continue
    let i = l.prop
    let p = props[i]
    if grouped: fill(rect(area.x, y, indent, rh), th.face)
    let nameR = rect(area.x + indent, y, nameW, rh)
    let valR = rect(divX + 1, y, area.x + area.w - divX - 1, rh - 1)
    let isSel = i == sel
    if isSel: fill(nameR, if hit.focused: th.select else: th.face)
    pushClip(intersect(nameR, area))
    text(nameR.x + dp(4), y + (rh - FontH) div 2, p.name,
         if isSel and hit.focused: th.selectText elif p.readOnly: th.gray else: th.fieldText)
    popClip()
    vline(divX, y, rh, th.face)
    hline(area.x + indent, y + rh - 1, area.w - indent, th.face)
    # the value
    pushClip(intersect(valR, area))
    let editing = ui.focus == editId and isSel
    case p.kind
    of pkBool:
      let bs = dp(13)
      let b = rect(valR.x + dp(4), y + (rh - bs) div 2, bs, bs)
      checkBox(b, p.on, false, not p.readOnly)
      text(b.x + bs + dp(6), y + (rh - FontH) div 2, valueText(p),
           if p.readOnly: th.gray else: th.fieldText)
    of pkColor:
      let sw = rh - dp(8)
      let b = rect(valR.x + dp(4), y + (rh - sw) div 2, sw * 3 div 2, sw)
      fill(b, p.color)
      box(b, th.frame)
      if not editing:
        text(b.x + b.w + dp(6), y + (rh - FontH) div 2, valueText(p), th.fieldText)
    else:
      if not editing:
        text(valR.x + dp(4), y + (rh - FontH) div 2, valueText(p),
             if p.readOnly: th.gray else: th.fieldText)
      if isSel and p.kind == pkChoice and not p.readOnly:
        let bw = SbW
        let br = rect(valR.x + valR.w - bw, y + 1, bw, rh - 3)
        buttonFace(br, false, rounded = false, bevel = 1)
        arrow(br.x + br.w div 2, br.y + br.h div 2, dDown, th.text, 3)
    popClip()
    # the editor of the chosen text, number or color
    if isSel and not p.readOnly and p.kind in {pkText, pkNumber, pkInt, pkColor}:
      let er = if p.kind == pkColor:
                 let sw = (rh - dp(8)) * 3 div 2 + dp(10)
                 rect(valR.x + sw, y + 1, valR.w - sw, rh - 2)
               else: rect(valR.x + 1, y + 1, valR.w - 1, rh - 2)
      if editing:
        var buf = propBuf.getOrDefault(editId, valueText(p))
        let allowed = case p.kind
                      of pkNumber: {'0'..'9', '-', '.', ','}
                      of pkInt: {'0'..'9', '-'}
                      of pkColor: {'0'..'9', 'a'..'f', 'A'..'F', '#'}
                      else: {}
        let ch = editAt(editId, buf, er, false, false, true, allowed,
                        right = false, frameless = true)
        propBuf[editId] = buf
        if ch:
          case p.kind
          of pkText:
            props[i].text = buf
            result = i
          of pkNumber:
            var v: float
            if parseNumber(buf, v):
              props[i].num = v
              result = i
          of pkInt:
            try:
              props[i].n = parseInt(buf.strip)
              result = i
            except ValueError: discard
          of pkColor:
            var c: Color
            if parseHexColor(buf, c):
              props[i].color = c
              result = i
          else: discard
        if ui.focus == editId: ui.takesEnter = true    # (Enter ends the edit: #9)
        if canInput() and (keyHit(KeyEnter) or keyHit(KeyEsc)):
          ui.focus = id
          propBuf.del editId
      else:
        propBuf.del editId
  popClip()
  if accessOn:
    # (a table of names and values; a category a row that folds)
    accessBegin(arTable, "", gridR, id, takesLabel = true)
    for k in first .. min(lines.high, first + area.h div rh + 1):
      let y = area.y + k * rh - top
      let l = lines[k]
      if l.prop < 0:
        let folded = propFold.getOrDefault(key & "\0" & l.cat, false)
        accessNode(arRow, l.cat, id = catId(l.cat), r = rect(area.x, y, area.w, rh),
                   states = {asExpandable} + (if folded: {} else: {asExpanded}))
        continue
      let i = l.prop
      let p = props[i]
      let row = accessBegin(arRow, p.name, rect(area.x, y, area.w, rh), accessSubId(id, i),
                            (if i == sel: {asSelected} else: {}))
      accessItem(row, i + 1, props.len)
      accessNode(arCell, p.name, id = accessSubId(id, 0x300000 + i),
                 r = rect(area.x + indent, y, nameW, rh))
      let v = accessNode(if p.kind == pkBool: arCheckBox else: arCell, p.name, valueText(p),
                         (if p.readOnly: {asReadOnly} else: {}) +
                           (if p.kind == pkBool and p.on: {asChecked} else: {}),
                         valId(i), rect(divX + 1, y, area.x + area.w - divX - 1, rh), help = p.help)
      if i == sel and hit.focused: accessFocus(v)
      accessEnd()
    accessEnd()
  vline(divX, area.y + max(0, lines.len * rh - top), max(0, area.h - lines.len * rh + top), th.face)
  # the date of the chosen one: its calendar under the grid row
  if sel in 0 .. props.high and props[sel].kind == pkDate and not props[sel].readOnly and
     selLine >= 0:
    let y = area.y + selLine * rh - top
    if y >= area.y and y + rh <= area.y + area.h:
      pushFrame(rect(divX + 1, y + (rh - EditH) div 2, area.x + area.w - divX - 1, 0))
      if datePicker(props[sel].date, w = area.x + area.w - divX - 1): result = sel
      discard popFrame()
  # the choices of the chosen one
  popupMenu("propgrid-choice:" & key):
    if sel in 0 .. props.high:
      for ci, c in props[sel].choices:
        if menuItem(c.replace("&", "&&"), checked = ci == props[sel].n):
          props[sel].n = ci
          result = sel
  # the help line
  if help:
    let hr = rect(whole.x, whole.y + whole.h - helpH, whole.w, helpH)
    fill(hr, th.face)
    sunken(hr)
    if sel in 0 .. props.high:
      let p = props[sel]
      text(hr.x + dp(6), hr.y + dp(4), p.name, th.text, true)
      var y = hr.y + dp(4) + FontH
      for line in wrapLines(p.help, hr.w - dp(12)):
        if y + FontH > hr.y + hr.h: break
        text(hr.x + dp(6), y, line, th.text)
        y += FontH
  st.scrollY = top
  st.aux2 = nameW
  state(id) = st
  ui.lastId = id
  ui.lastRect = whole

# ---- a tree with columns ------------------------------------------------------------------------

type
  TreeRow* = object
    ## A row of a `treeGrid`: its depth, its cells, open or closed.
    level*: int              ## its depth (0: at the top): the deeper rows after it are its children
    cells*: seq[string]      ## its cells, one per column
    open*: bool              ## its children are shown
    glyph*: string           ## an icon before the first cell ("" none)
  TreeGridEvent* = object
    ## What happened in a `treeGrid` this frame.
    selChanged*, activated*, toggled*: bool
      ## `sel` changed; a row was double-clicked (or Enter); a row was opened or closed
    row*: int                ## the row (index in `rows`) it happened to

proc hasKids(rows: seq[TreeRow]; i: int): bool {.inline.} =
  i + 1 < rows.len and rows[i + 1].level > rows[i].level

proc treeGrid*(cols: var seq[Column]; rows: var seq[TreeRow]; sel: var int;
               height = 10; w = 0; boldParents = true): TreeGridEvent {.discardable.} =
  ## A tree whose rows have columns (accounts with their balances, parts
  ## with their quantities): rows with deeper rows after them open and
  ## close with their ``[+]`` box, a double click, Right / Left or Space;
  ## Up, Down, Page Up, Page Down, Home, End move; Enter (or a double click
  ## on a row without children) activates. Drag a header's edge to resize
  ## its column. `height` in rows (-1 fills). Parents are bold.
  result.row = -1
  let rowH = ItemH + 2
  let hdrH = ItemH + 4
  let h = if height < 0: remainingH() else: hdrH + height * rowH + 2
  let r = place(if w > 0: w else: 0, h, fill = w <= 0)
  let id = idOf(sel, "treegrid")
  var st = state(id)
  var widths: seq[int]
  for c in cols: widths.add dp(c.width)
  var totalW = 0
  for x in widths: totalW += x
  # the rows shown: those under a closed row are left out
  var shown: seq[int]
  var hideBelow = high(int)
  for i, row in rows:
    if row.level > hideBelow: continue
    hideBelow = high(int)
    shown.add i
    if hasKids(rows, i) and not row.open: hideBelow = row.level
  var vBar, hBar = false
  for _ in 0 .. 1:
    hBar = totalW > r.w - 2 - (if vBar: SbW - 1 else: 0)
    vBar = shown.len * rowH > max(1, r.h - 2 - hdrH - (if hBar: SbW - 1 else: 0))
  let area = rect(r.x + 1, r.y + 1, r.w - 2 - (if vBar: SbW - 1 else: 0),
                  r.h - 2 - (if hBar: SbW - 1 else: 0))
  let body = rect(area.x, area.y + hdrH, area.w, area.h - hdrH)
  let vis = max(1, body.h div rowH)
  # the rows scroll by the pixel (`oy`), smoothly
  let maxOy = max(0, shown.len * rowH - body.h)
  let maxX = max(0, totalW - area.w)
  let sxId = id + 26
  var oy = clamp(st.scrollY, 0, maxOy)
  var sx = clamp(st.scrollX, 0, maxX)
  if vBar:
    scrollBarFor(id + 9, id, rect(r.x + r.w - SbW, r.y, SbW,
                 r.h - (if hBar: SbW - 1 else: 0)), true, oy,
                 maxOy, max(rowH, body.h - rowH), rowH)
  if hBar:
    scrollBarFor(id + 15, sxId, rect(r.x, r.y + r.h - SbW,
                 r.w - (if vBar: SbW - 1 else: 0), SbW), false, sx,
                 maxX, max(10, area.w - 20), dp(20))
  let hit = interact(id, body)
  let indentW = dp(16)
  let x0 = area.x - sx
  var at = -1                           # where `sel` is among the rows shown
  for k, i in shown:
    if i == sel: at = k
  if at < 0 and shown.len > 0:
    # the selected row was folded away: its nearest shown parent
    var p = clamp(sel, 0, rows.high)
    while p > 0 and p notin shown: dec p
    at = max(0, shown.find(p))
    sel = shown[at]
  var follow = false
  template toggleAt(i: int; ev: var TreeGridEvent) =
    let ti = i
    rows[ti].open = not rows[ti].open
    ev.toggled = true
    ev.row = ti
  # header: resizing by the edges
  var x = x0
  for ci in 0 ..< cols.len:
    let edge = rect(x + widths[ci] - 3, area.y, 6, hdrH)
    if canInput() and mouseIn(edge): ui.cursor = curSizeWE
    if canInput() and hover(edge) and takePress():
      ui.active = id + 40 + uint32(ci)
      ui.dragsActive = true
      st.aux = ui.mx - (x + widths[ci])
    if ui.active == id + 40 + uint32(ci) and ui.mouseDown:
      widths[ci] = max(dp(24), ui.mx - st.aux - x)
      cols[ci].width = max(16, int(float(widths[ci]) / max(0.1, ui.k) + 0.5))
      ui.cursor = curSizeWE
    x += widths[ci]
  if canInput():
    scrollWheel(sxId, sx, maxX, r, 3 * rowH, sideways = true)
    scrollWheel(id, oy, maxOy, r, 3 * rowH)
    scrollPan2(id, oy, maxOy, sxId, sx, maxX, r)
    if tapped(id, hit):
      let k = (ui.my - body.y + oy) div rowH
      if k in 0 .. shown.high:
        let i = shown[k]
        let boxX = x0 + rows[i].level * indentW
        if hasKids(rows, i) and ui.mx >= boxX and ui.mx < boxX + indentW:
          toggleAt(i, result)
        else:
          if sel != i:
            sel = i
            result.selChanged = true
          if ui.clicks >= 2:
            if hasKids(rows, i): toggleAt(i, result)
            else:
              result.activated = true
              result.row = i
              markDouble(id)
  if hit.focused and canInput() and shown.len > 0:
    var k = at
    case ui.key
    of KeyUp: k = max(0, k - 1)
    of KeyDown: k = min(shown.high, k + 1)
    of KeyPageUp: k = max(0, k - vis + 1)
    of KeyPageDown: k = min(shown.high, k + vis - 1)
    of KeyHome: k = 0
    of KeyEnd: k = shown.high
    of KeyRight:
      if hasKids(rows, sel):
        if not rows[sel].open: toggleAt(sel, result)
        else: k = min(shown.high, k + 1)
    of KeyLeft:
      if hasKids(rows, sel) and rows[sel].open: toggleAt(sel, result)
      else:
        var p = sel - 1
        while p >= 0 and rows[p].level >= rows[sel].level: dec p
        if p >= 0: k = max(0, shown.find(p))
    of KeySpace:
      if hasKids(rows, sel): toggleAt(sel, result)
    of KeyEnter:
      result.activated = true
      result.row = sel
      markDouble(id)
    else: discard
    if ui.key in {KeyUp, KeyDown, KeyPageUp, KeyPageDown, KeyHome, KeyEnd, KeyRight,
                  KeyLeft, KeySpace, KeyEnter}:
      ui.keyUsed = true
    if k != at and k in 0 .. shown.high:
      sel = shown[k]
      at = k
      result.selChanged = true
      follow = true
  if accessPress != 0:
    # (a screen reader picked a row: selected, or opened / closed when it was)
    for i in 0 ..< rows.len:
      if accessPress == accessSubId(id, i):
        accessPress = 0
        ui.focus = id
        if sel == i and hasKids(rows, i): toggleAt(i, result)
        elif sel != i:
          sel = i
          result.selChanged = true
          follow = true
        break
  if result.toggled:
    # opened or closed: the rows shown again
    shown.setLen(0)
    hideBelow = high(int)
    for i, row in rows:
      if row.level > hideBelow: continue
      hideBelow = high(int)
      shown.add i
      if hasKids(rows, i) and not row.open: hideBelow = row.level
    at = max(0, shown.find(sel))
    ui.redraw = true
  let maxNow = max(0, shown.len * rowH - body.h)    # (rows folded or opened)
  if follow:
    scrollShow(id, oy, at * rowH, (at + 1) * rowH, body.h, maxNow)
  scrollTick(id, oy, maxNow)
  scrollTick(sxId, sx, maxX)
  oy = clamp(oy, 0, maxNow)
  let top = oy div rowH
  # draw
  fill(rect(r.x, r.y, area.w + 2, area.h + 2), th.field)
  box(rect(r.x, r.y, area.w + 2, area.h + 2), th.edge)
  if vBar and hBar: fill(r.x + r.w - SbW, r.y + r.h - SbW, SbW, SbW, th.face)
  pushClip(area)
  x = x0
  for ci in 0 ..< cols.len:
    let hr = rect(x, area.y, widths[ci], hdrH)
    fill(hr, th.face)
    hline(hr.x, hr.y, hr.w - 1, th.light)
    vline(hr.x, hr.y, hr.h - 1, th.light)
    hline(hr.x, hr.y + hr.h - 1, hr.w, th.edge)
    vline(hr.x + hr.w - 1, hr.y, hr.h, th.edge)
    pushClip(intersect(rect(hr.x + 1, hr.y, hr.w - 2, hr.h), area))
    let tw = textWidth(cols[ci].title)
    let tx = case cols[ci].align
             of alLeft: hr.x + 4
             of alCenter: hr.x + (hr.w - tw) div 2
             of alRight: hr.x + hr.w - 5 - tw
    text(tx, hr.y + (hr.h - FontH) div 2, cols[ci].title, th.text)
    popClip()
    x += widths[ci]
  if x < area.x + area.w:
    fill(x, area.y, area.x + area.w - x, hdrH, th.face)
    hline(x, area.y + hdrH - 1, area.x + area.w - x, th.edge)
  pushClip(body)
  let rowW = min(area.w, x - area.x)
  for k in top ..< min(shown.len, top + vis + 2):
    let i = shown[k]
    let row = rows[i]
    let y = body.y + k * rowH - oy
    let selected = i == sel
    if selected: fill(rect(area.x, y, rowW, rowH), th.select)
    elif hovered(rect(area.x, y, rowW, rowH)): fill(rect(area.x, y, rowW, rowH), hoverColor())
    let fg = if selected: th.selectText else: th.fieldText
    let parent = hasKids(rows, i)
    let bold = boldParents and parent
    var cx = x0
    for ci in 0 ..< cols.len:
      var cr = rect(cx, y, widths[ci], rowH)
      if cr.x + cr.w > area.x and cr.x < area.x + area.w:
        pushClip(intersect(rect(cr.x, cr.y, cr.w - 1, cr.h), body))
        let v = if ci < row.cells.len: row.cells[ci] else: ""
        if ci == 0:
          let bx = cr.x + row.level * indentW
          if parent:
            let bs = dp(9)
            let b = rect(bx + (indentW - bs) div 2, y + (rowH - bs) div 2, bs, bs)
            fill(b, th.field)
            box(b, th.shadow)
            hline(b.x + 2, b.y + bs div 2, bs - 4, th.text)
            if not row.open: vline(b.x + bs div 2, b.y + 2, bs - 4, th.text)
          var tx = bx + indentW
          if row.glyph.len > 0:
            let k2 = min(rowH - 2, max(16, FontH + 2))
            image(tx, y + (rowH - k2) div 2, glyphIcon(row.glyph, fg, k2))
            tx += k2 + dp(4)
          text(tx, y + (rowH - FontH) div 2, v, fg, bold)
        else:
          let tw = textWidth(v, bold)
          let tx = case cols[ci].align
                   of alLeft: cr.x + 4
                   of alCenter: cr.x + (cr.w - tw) div 2
                   of alRight: cr.x + cr.w - 5 - tw
          text(tx, y + (rowH - FontH) div 2, v, fg, bold)
        popClip()
      vline(cx + widths[ci] - 1, y, rowH, th.face)
      cx += widths[ci]
    hline(area.x, y + rowH - 1, rowW, th.face)
    if selected and hit.focused: dots(rect(area.x, y, rowW, rowH - 1), th.selectText)
  popClip()
  popClip()
  if accessOn:
    # (a tree: each row an item at its depth, its other cells told after its name)
    accessBegin(arTree, "", r, id, takesLabel = true)
    for k in top ..< min(shown.len, top + vis + 2):
      let i = shown[k]
      let row = rows[i]
      var more = ""
      for ci in 1 ..< cols.len:
        if ci < row.cells.len and row.cells[ci].len > 0:
          if more.len > 0: more.add ", "
          more.add cols[ci].title & ": " & row.cells[ci]
      let parent = hasKids(rows, i)
      let n = accessNode(arTreeItem, (if row.cells.len > 0: row.cells[0] else: ""),
                         id = accessSubId(id, i), r = rect(area.x, body.y + k * rowH - oy, rowW, rowH),
                         states = (if i == sel: {asSelected} else: {}) +
                                  (if parent: {asExpandable} else: {}) +
                                  (if parent and row.open: {asExpanded} else: {}),
                         help = more)
      accessItem(n, k + 1, shown.len, row.level + 1)
      if i == sel and hit.focused: accessFocus(n)
    accessEnd()
  st.scrollY = oy
  st.scrollX = sx
  state(id) = st
  ui.lastId = id
  ui.lastRect = r

# ---- wizards -------------------------------------------------------------------------------------

type WizardAction* = enum
  ## What a `wizard`'s buttons did this frame.
  waNone, waBack, waNext, waFinish, waCancel

var
  wizardOk = true
  wizardSteps: seq[tuple[step, count: int]]

proc stepDone*(ok: bool) =
  ## In a `wizard`'s page: Next (or Finish) is enabled only when `ok`
  ## (what this page asks is filled in).
  wizardOk = wizardOk and ok

proc beginWizard*(open: var bool; title: string; step: var int;
                  steps: openArray[string]; width = 560): bool =
  ## Begins a `wizard`'s dialog at page `step` (its steps at the left);
  ## false when it is not open. Draw the page, then call `endWizard`.
  if steps.len == 0: return false
  step = clamp(step, 0, steps.high)
  if not beginDialog(open, title, width): return false
  wizardOk = true
  wizardSteps.add (step, steps.len)
  if isCompact():
    label("Step " & $(step + 1) & " of " & $steps.len, color = th.gray)
    heading(steps[step], 3)
    beginCol()
  else:
    beginRow([150, -1])
    # the steps at the left: done ones checked, this one bold
    beginCol()
    let k = dp(16)
    for i, s in steps:
      row:
        if i < step: image(glyphIcon(retroOr(pxCheck, nfCheck), color(0, 128, 0), k))
        elif i == step: image(glyphIcon(retroOr(pxForward, nfChevronRight), th.text, k))
        else: space(k)
        label(s, bold = i == step, color = if i > step: th.gray else: Color())
    endCol()
    beginCol()
    heading(steps[step], 3)
  true

proc endWizard*(open: var bool; step: var int): WizardAction =
  ## Ends a `beginWizard`: Back, Next > (or Finish) and Cancel; what was
  ## pressed (`step` and `open` already changed).
  let (_, count) = if wizardSteps.len > 0: wizardSteps.pop() else: (0, 1)
  if isCompact(): endCol()
  else:
    endCol()
    endRow()
  separator()
  let lastStep = step >= count - 1
  row:
    spring()
    if button("< &Back", enabled = step > 0): result = waBack
    if lastStep:
      if button("&Finish", isDefault = true, enabled = wizardOk): result = waFinish
    else:
      if button("&Next >", isDefault = true, enabled = wizardOk): result = waNext
    if button("Cancel"): result = waCancel
  endDialog()
  case result
  of waBack: step = max(0, step - 1)
  of waNext: step = min(count - 1, step + 1)
  of waFinish, waCancel: open = false
  else:
    if not open: result = waCancel         # Esc or the control-menu box
  wizardOk = true

template wizard*(open: var bool; title: string; step: var int;
                 steps: openArray[string]; width: int; body: untyped): WizardAction =
  ## A dialog of `steps` (their names at the left, Back, Next >, Finish and
  ## Cancel at the bottom); `body` draws the page of `step` (a `case
  ## step`). Call `stepDone(false)` in a page whose fields are not filled in
  ## yet. Returns what was pressed: `waFinish` (then `open` is false),
  ## `waCancel` (also Esc), `waNext`, `waBack` (`step` already moved).
  block:
    var act = waNone
    let wasOpen = open
    if open and beginWizard(open, title, step, steps, width):
      body
      act = endWizard(open, step)
    elif wasOpen and not open:
      act = waCancel                       # Esc, or the control-menu box
    act

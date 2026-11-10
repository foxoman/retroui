## Business planning views: what a project, sales or service app shows its
## work with.
##
## - `kanbanBoard`: lanes of cards, dragged from lane to lane
## - `ganttView`: tasks on a time line, moved and stretched with the mouse
## - `agendaView`: appointments by month, week or day
## - `kpiTile`, `statCard`, `kpiRow`: the numbers of a dashboard
## - `orgChart`: who reports to whom, as boxes and lines
##
## They take the mouse, the keyboard and fingers (a finger held on a card,
## a bar or an appointment, then moved, drags it; a finger that just moves
## scrolls), draw only what is in view -- thousands of tasks or cards stay
## fast -- and scroll with the standard 3.1 scroll bars.
##
## ```nim
## var lanes = @[KanbanLane(title: "To do", cards: @[KanbanCard(title: "Call the bank")]),
##               KanbanLane(title: "Done")]
## var sel: KanbanPos = (0, 0)
## app "Plans", 800, 500:
##   kpiRow:
##     discard kpiTile("Revenue", "OMR 84,120", 0.125, "vs last month")
##   let e = kanbanBoard(lanes, sel)
##   if e.added: lanes[e.lane].cards.add KanbanCard(title: "New card")
## ```

import std/[tables, math, algorithm, hashes, strutils]
from std/times import nil
import gfx, core, widgets, business, extras, pixelicons, nerdicons
import uirelays/input

template th: untyped = ui.theme

# ---- shared helpers -------------------------------------------------------------------------------

var intSlots: Table[string, ref int]

proc intSlot(key: string): ref int =
  ## An int that lives as long as the app (for widgets bound to a var).
  result = intSlots.getOrDefault(key, nil)
  if result == nil:
    new(result)
    intSlots[key] = result

const tints = [color(66, 133, 244), color(219, 68, 55), color(244, 160, 0),
               color(15, 157, 88), color(171, 71, 188), color(0, 150, 170),
               color(240, 98, 50), color(121, 85, 72)]

proc tintOf(s: string): Color =
  ## A color of its own for a name (the same name, the same color).
  tints[int(cast[uint](hash(s)) mod uint(tints.len))]

proc good(): Color = color(0, 128, 0)
proc bad(): Color = color(200, 0, 0)

proc smallSt(bold = false): TextStyle = style(bold = bold, size = 0.85)

proc miniButton(id: Id; r: Rect; label: string; enabled = true): bool =
  ## A small flat push button drawn at `r`.
  let hit = interact(id, r, focusable = false, enabled = enabled)
  if accessOn: accessNode(arButton, label, id = id, r = r, states = accessOff(enabled))
  buttonFace(r, hit.down, rounded = false, bevel = 1, hot = enabled and hovered(r))
  let o = if hit.down: 1 else: 0
  let tw = textWidth(label)
  text(r.x + (r.w - tw) div 2 + o, r.y + (r.h - FontH) div 2 + o, label,
       if enabled: th.text else: th.gray)
  hit.clicked

proc foldBox(b: Rect; open: bool) =
  ## The [+] / [-] box of something that folds.
  fill(b, th.field)
  box(b, th.shadow)
  hline(b.x + 2, b.y + b.h div 2, b.w - 4, th.text)
  if not open: vline(b.x + b.w div 2, b.y + 2, b.h - 4, th.text)

proc badge(cx, cy, d: int; name: string) =
  ## Someone's initials in a round badge of their color.
  disc(float(cx), float(cy), d / 2, tintOf(name))
  let size = max(0.5, d / FontH / 1.9)
  var st = style(bold = true, size = size)
  let s = initialsOf(name)
  # (initials as wide as the badge allows: two wide letters shrink to fit)
  let room = max(1, d - max(2, d div 6))
  let tw = textWidth(s, st)
  if tw > room: st = style(bold = true, size = max(0.4, size * float(room) / float(tw)))
  text(cx - textWidth(s, st) div 2, cy - lineHeight(st) div 2, s, color(255, 255, 255), st)

proc monthShort(m: int): string = monthNames[clamp(m, 1, 12) - 1][0 .. 2]

const dayNamesLong = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday",
                      "Friday", "Saturday"]

proc weekStart(d: Date): Date =
  ## The first day of `d`'s week (`firstWeekday`).
  d.addDays(-((weekday(d) - firstWeekday + 7) mod 7))

# ---- the kanban board -----------------------------------------------------------------------------

type
  KanbanCard* = object
    ## A card of a `kanbanBoard`.
    title*, detail*: string  ## its title, and a line under it ("" none)
    tag*: Color            ## the color strip at its left (alpha 0: none)
    due*: Date             ## when it is due (year 0: no date)
    who*: string           ## who has it: their initials in a badge ("" none)
  KanbanLane* = object
    ## A lane (a column) of a `kanbanBoard`.
    title*: string         ## its heading
    cards*: seq[KanbanCard]  ## its cards, top to bottom
    limit*: int            ## the work allowed in it (0: no limit); over it the count is red
  KanbanPos* = tuple[lane, card: int]
    ## A place on a board (`card` -1: an empty lane).
  KanbanEvent* = object
    ## What happened on a `kanbanBoard` this frame.
    selChanged*: bool      ## `sel` changed
    moved*: bool           ## a card was moved, already done in the lanes ...
    fromPos*, toPos*: KanbanPos   ## ... from here to there
    opened*: bool          ## the card at `sel` was double-clicked (or Enter)
    added*: bool           ## "+ Add card" of `lane` was clicked (or Insert)
    lane*: int             ## the lane of `added`

var kanbanPress: tuple[id: Id; lane, card, x, y: int]

proc cardHeight(c: KanbanCard): int =
  result = dp(8) + FontH
  if c.detail.len > 0: result += FontH
  if c.due.year > 0 or c.who.len > 0: result += FontH + dp(4)
  result += dp(6)

proc moveCard(lanes: var seq[KanbanLane]; a, b: KanbanPos): KanbanPos =
  ## Moves the card at `a` to stand before card `b.card` of lane `b.lane`
  ## (the lane's end when there is none); where it went.
  let c = lanes[a.lane].cards[a.card]
  lanes[a.lane].cards.delete(a.card)
  var t = b.card
  if a.lane == b.lane and a.card < t: dec t
  t = clamp(t, 0, lanes[b.lane].cards.len)
  lanes[b.lane].cards.insert(c, t)
  (b.lane, t)

proc drawCard(r: Rect; c: KanbanCard; selected, focused: bool) =
  fill(r, th.field)
  hline(r.x + 2, r.y + r.h, r.w - 1, th.shadow)          # a shadow under it
  vline(r.x + r.w, r.y + 2, r.h - 1, th.shadow)
  box(r, if selected: th.select else: th.edge)
  if selected: box(inset(r, 1), th.select)
  let edge = if selected: 2 else: 1
  if c.tag.a != 0: fill(rect(r.x + edge, r.y + edge, dp(4), r.h - 2 * edge), c.tag)
  let tx = r.x + dp(10)
  let tw = max(10, r.w - dp(16))
  var y = r.y + dp(4)
  text(tx, y, ellipsize(c.title, tw, style(bold = true)), th.fieldText, true)
  y += FontH
  if c.detail.len > 0:
    text(tx, y, ellipsize(c.detail, tw), th.gray)
    y += FontH
  if c.due.year > 0 or c.who.len > 0:
    y += dp(4)
    let d = FontH + dp(2)
    if c.due.year > 0:
      let late = dayNumber(c.due) < dayNumber(today())
      let s = (if late: "Late " else: "Due ") & $c.due.day & " " & monthShort(c.due.month)
      text(tx, y + (d - lineHeight(smallSt())) div 2, s,
           if late: bad() else: th.gray, smallSt(late))
    if c.who.len > 0: badge(r.x + r.w - dp(6) - d div 2, y + d div 2, d, c.who)
  if selected and focused: dots(inset(r, 3), th.text)

proc kanbanBoard*(lanes: var seq[KanbanLane]; sel: var KanbanPos; height = -1;
                  key = ""): KanbanEvent {.discardable.} =
  ## A board of `lanes` side by side, each a list of cards, for work that
  ## moves through stages (To do, Doing, Done). Drag a card to another place
  ## or lane (a finger: hold it, then move); Ctrl + the arrows move the
  ## chosen card too. The arrows choose, Enter or a double click opens
  ## (`opened`), "+ Add card" (or Insert) asks for a new card (`added`).
  ## Lanes over their `limit` show their count in red. Lanes scroll on their
  ## own, the board sideways when they do not fit (a phone shows about one
  ## and a half). `height` in pixels (-1: the room left).
  result.lane = -1
  result.fromPos = (-1, -1)
  result.toPos = (-1, -1)
  let h = if height < 0: remainingH() else: height
  let r = place(0, h, fill = true)
  let id = idOf("kanban:" & key)
  let kind = "kanban:" & key
  var st = state(id)
  let n = lanes.len
  fill(r, th.window)
  if n == 0:
    let s = "No lanes"
    text(r.x + (r.w - textWidth(s)) div 2, r.y + (r.h - FontH) div 2, s, th.gray)
    ui.lastId = id
    ui.lastRect = r
    return
  let gap = dp(8)
  let minW = if fingers(): dp(240) else: dp(210)
  let laneW = max(minW, (r.w - gap * (n + 1)) div n)
  let totalW = n * laneW + (n + 1) * gap
  let hBar = totalW > r.w
  let view = rect(r.x, r.y, r.w, r.h - (if hBar: SbW else: 0))
  var sx = clamp(st.scrollX, 0, max(0, totalW - view.w))
  let oldSel = sel
  sel.lane = clamp(sel.lane, 0, n - 1)
  sel.card = if lanes[sel.lane].cards.len == 0: -1
             else: clamp(sel.card, 0, lanes[sel.lane].cards.high)
  let focused = tabStop(id, r)
  let hdrH = FontH + dp(12)
  let addH = if fingers(): CtrlH else: FontH + dp(10)
  let cardGap = dp(6)
  template laneR(i: int): Rect =
    rect(view.x + gap + i * (laneW + gap) - sx, view.y + gap, laneW, view.h - 2 * gap)
  template listR(i: int): Rect =
    let lr = laneR(i)
    rect(lr.x + 1, lr.y + hdrH, lr.w - 2, max(0, lr.h - hdrH - addH - dp(6)))
  proc contentH(cards: seq[KanbanCard]): int =
    result = cardGap
    for c in cards: result += cardHeight(c) + cardGap
  proc cardAt(cards: seq[KanbanCard]; y0, my: int): int =
    ## The card at `my` (the list's cards start at `y0`), -1 none.
    var y = y0
    for k, c in cards:
      let ch = cardHeight(c)
      if my >= y and my < y + ch: return k
      y += ch + cardGap
    -1
  proc slotAt(cards: seq[KanbanCard]; y0, my: int): int =
    ## Where a card dropped at `my` goes: before the first card whose middle
    ## is below it.
    var y = y0
    for k, c in cards:
      let ch = cardHeight(c)
      if my < y + ch div 2: return k
      y += ch + cardGap
    cards.len
  var follow = false
  # the keys: arrows choose, Ctrl + arrows move the card
  if focused and canInput() and not ui.keyUsed:
    let ctrl = CtrlPressed in ui.mods
    let cur = sel
    case ui.key
    of KeyUp, KeyDown:
      let d = if ui.key == KeyUp: -1 else: 1
      if ctrl and sel.card >= 0:
        let t = sel.card + d
        if t in 0 .. lanes[sel.lane].cards.high:
          swap(lanes[sel.lane].cards[sel.card], lanes[sel.lane].cards[t])
          result.moved = true
          result.fromPos = cur
          result.toPos = (sel.lane, t)
          sel.card = t
      elif sel.card >= 0:
        sel.card = clamp(sel.card + d, 0, lanes[sel.lane].cards.high)
      ui.keyUsed = true
      follow = true
    of KeyLeft, KeyRight:
      let d = if ui.key == KeyLeft: -1 else: 1
      let t = sel.lane + d
      if t in 0 ..< n:
        if ctrl and sel.card >= 0:
          let dest = (t, min(sel.card, lanes[t].cards.len))
          sel = moveCard(lanes, cur, dest)
          result.moved = true
          result.fromPos = cur
          result.toPos = sel
        else:
          sel.lane = t
          sel.card = if lanes[t].cards.len == 0: -1
                     else: clamp(max(sel.card, 0), 0, lanes[t].cards.high)
      ui.keyUsed = true
      follow = true
    of KeyHome, KeyEnd:
      if lanes[sel.lane].cards.len > 0:
        sel.card = if ui.key == KeyHome: 0 else: lanes[sel.lane].cards.high
      ui.keyUsed = true
      follow = true
    of KeyEnter:
      if sel.card >= 0: result.opened = true
      ui.keyUsed = true
    of KeyInsert:
      result.added = true
      result.lane = sel.lane
      ui.keyUsed = true
    else: discard
  # the board sideways: the wheel over the headers (or with Shift), a finger
  # (each lane's cards scroll up and down: scroller id + 100 + lane, the
  # board sideways: id + 98; they glide and a flick goes on)
  let boardId = id + 98
  let hiX = max(0, totalW - view.w)
  template laneHi(i: int): int = max(0, contentH(lanes[i].cards) - listR(i).h)
  if canInput():
    var panLane = -1
    for i in 0 ..< n:
      if listR(i).contains(ui.panFrom) or (ui.pressed and mouseIn(listR(i))): panLane = i
    if panLane >= 0:
      var ls = state(id + 100 + uint32(panLane))
      scrollPan2(id + 100 + uint32(panLane), ls.scrollY, laneHi(panLane), boardId, sx, hiX, view)
      state(id + 100 + uint32(panLane)) = ls
    else:
      scrollPan(boardId, sx, hiX, view, sideways = true)
    if mouseIn(view) and ui.wheel != 0 and not ui.wheelUsed:
      var inList = -1
      for i in 0 ..< n:
        if mouseIn(listR(i)): inList = i
      if inList >= 0 and ShiftPressed notin ui.mods:
        var ls = state(id + 100 + uint32(inList))
        scrollBy(id + 100 + uint32(inList), ls.scrollY, -ui.wheel * 3 * FontH, laneHi(inList))
        state(id + 100 + uint32(inList)) = ls
      elif hBar:
        scrollBy(boardId, sx, -ui.wheel * dp(60), hiX)
      ui.wheelUsed = true
    # a drag near the board's ends scrolls it
    if dragging(kind) and mouseIn(view) and hBar:
      if ui.mx < view.x + dp(24): scrollStop(boardId); sx -= dp(6); wakeIn(16)
      elif ui.mx > view.x + view.w - dp(24): scrollStop(boardId); sx += dp(6); wakeIn(16)
  scrollTick(boardId, sx, hiX)
  sx = clamp(sx, 0, hiX)
  pushClip(view)
  var dropAt: tuple[lane, slot, y: int] = (-1, -1, 0)
  for i in 0 ..< n:
    let lr = laneR(i)
    if lr.x + lr.w < view.x or lr.x > view.x + view.w: continue
    let lst = listR(i)
    let laneId = id + 200 + uint32(i)
    var ls = state(id + 100 + uint32(i))
    let ch = contentH(lanes[i].cards)
    let vBar = ch > lst.h
    let inner = rect(lst.x, lst.y, lst.w - (if vBar: SbW else: 0), lst.h)
    # the chosen card in view
    let laneSid = id + 100 + uint32(i)
    if follow and sel.lane == i and sel.card >= 0:
      var y = cardGap
      for k in 0 ..< sel.card: y += cardHeight(lanes[i].cards[k]) + cardGap
      let cy = cardHeight(lanes[i].cards[sel.card])
      scrollShow(laneSid, ls.scrollY, y - cardGap, y + cy + cardGap, lst.h, max(0, ch - lst.h))
    if dragging(kind) and mouseIn(inner):
      if ui.my < inner.y + dp(20): scrollStop(laneSid); ls.scrollY -= dp(5); wakeIn(16)
      elif ui.my > inner.y + inner.h - dp(20): scrollStop(laneSid); ls.scrollY += dp(5); wakeIn(16)
    scrollTick(laneSid, ls.scrollY, max(0, ch - lst.h))
    ls.scrollY = clamp(ls.scrollY, 0, max(0, ch - lst.h))
    let y0 = inner.y + cardGap - ls.scrollY
    # presses on the cards: choose, open, start a drag
    let hit = interact(laneId, inner, focusable = false)
    if ui.active == laneId and ui.pressed:
      let k = cardAt(lanes[i].cards, y0, ui.my)
      kanbanPress = (id, i, k, ui.mx, ui.my)
      ui.focus = id
    if tapped(laneId, hit):
      let k = cardAt(lanes[i].cards, y0, ui.my)
      if k >= 0 or sel.lane != i:
        sel = (i, (if k >= 0: k elif lanes[i].cards.len > 0: sel.card else: -1))
        if sel.card >= lanes[i].cards.len: sel.card = lanes[i].cards.high
      if k >= 0 and ui.clicks >= 2:
        result.opened = true
        markDouble(id)
    # the lane, its title and count
    fill(lr, th.face)
    box(lr, th.edge)
    let hr = rect(lr.x + 1, lr.y + 1, lr.w - 2, hdrH - 2)
    hline(hr.x, hr.y + hr.h, hr.w, th.shadow)
    let cnt = lanes[i].cards.len
    let over = lanes[i].limit > 0 and cnt > lanes[i].limit
    let cs = if lanes[i].limit > 0: $cnt & " / " & $lanes[i].limit else: $cnt
    let cw = textWidth(cs, true)
    text(hr.x + hr.w - cw - dp(8), hr.y + (hr.h - FontH) div 2, cs,
         if over: bad() else: th.gray, true)
    text(hr.x + dp(8), hr.y + (hr.h - FontH) div 2,
         ellipsize(lanes[i].title, hr.w - cw - dp(24), style(bold = true)), th.text, true)
    # its cards (only those in view)
    fill(lst, mixColor(th.face, th.window, 0.45))
    pushClip(inner)
    var y = y0
    for k in 0 ..< cnt:
      let c = lanes[i].cards[k]
      let chh = cardHeight(c)
      if y + chh >= inner.y and y <= inner.y + inner.h:
        drawCard(rect(inner.x + dp(6), y, inner.w - dp(12), chh), c,
                 sel.lane == i and sel.card == k, focused)
      elif y > inner.y + inner.h: break
      y += chh + cardGap
    if cnt == 0:
      let s = "No cards"
      text(inner.x + (inner.w - textWidth(s)) div 2, inner.y + dp(12), s, th.gray)
    popClip()
    # a dragged card over the lane: where it would go
    case dropTarget(lr, kind)
    of dsOver:
      let slot = slotAt(lanes[i].cards, y0, ui.my)
      var yy = y0
      for k in 0 ..< slot: yy += cardHeight(lanes[i].cards[k]) + cardGap
      dropAt = (i, slot, yy - cardGap div 2 - 1)
    of dsDropped:
      let s = if ui.drag.items.len > 0: ui.drag.items[0] else: ""
      let parts = s.split(',')
      var a = (-1, -1)
      if parts.len == 2:
        try: a = (parseInt(parts[0]), parseInt(parts[1]))
        except ValueError: discard
      if a[0] in 0 ..< n and a[1] in 0 .. lanes[a[0]].cards.high:
        let dest = (i, slotAt(lanes[i].cards, y0, ui.my))
        let src = (a[0], a[1])
        let got = moveCard(lanes, src, dest)
        if got != src:
          result.moved = true
          result.fromPos = src
          result.toPos = got
        sel = got
    else: discard
    if vBar:
      var sy = ls.scrollY
      scrollBarFor(id + 300 + uint32(i), laneSid, rect(lst.x + lst.w - SbW, lst.y, SbW, lst.h),
                   true, sy, max(0, ch - lst.h), max(FontH, lst.h - FontH * 2), FontH)
      ls.scrollY = sy
    state(id + 100 + uint32(i)) = ls
    # "+ Add card"
    let ar = rect(lr.x + dp(4), lr.y + lr.h - addH - dp(4), lr.w - dp(8), addH)
    let ah = interact(id + 400 + uint32(i), ar, focusable = false)
    buttonFace(ar, ah.down, rounded = false, bevel = 1, hot = hovered(ar))
    let lbl = "+ Add card"
    let o = if ah.down: 1 else: 0
    text(ar.x + (ar.w - textWidth(lbl)) div 2 + o, ar.y + (ar.h - FontH) div 2 + o, lbl, th.text)
    if ah.clicked:
      result.added = true
      result.lane = i
  if dropAt.lane >= 0:
    let lst = listR(dropAt.lane)
    fill(rect(lst.x + dp(4), dropAt.y - 1, lst.w - dp(8) - SbW div 2, dp(3)), th.select)
    dropHighlight(laneR(dropAt.lane))
  popClip()
  # a drag starts: the mouse moved from a card, a finger held on one moved
  if kanbanPress.id == id and kanbanPress.card >= 0 and kanbanPress.lane < n and
     kanbanPress.card < lanes[kanbanPress.lane].cards.len and not dragging():
    let moved = abs(ui.mx - kanbanPress.x) + abs(ui.my - kanbanPress.y) > dp(6)
    if (not finger() and ui.mouseDown and moved and
        ui.active == id + 200 + uint32(kanbanPress.lane)) or lifted():
      let c = lanes[kanbanPress.lane].cards[kanbanPress.card]
      sel = (kanbanPress.lane, kanbanPress.card)
      startDrag(kind, [$kanbanPress.lane & "," & $kanbanPress.card], c.title,
                retroOr(pxDocument, nfFile))
      kanbanPress.id = 0
  if not ui.mouseDown and not ui.pressed: kanbanPress.id = 0
  if hBar:
    scrollBarFor(id + 1, boardId, rect(r.x, r.y + r.h - SbW, r.w, SbW), false, sx,
                 hiX, max(dp(40), view.w - laneW), dp(40))
  if follow:
    let lr = laneR(sel.lane)
    let a = lr.x - view.x + sx - gap                  # (where the lane is on the board)
    scrollShow(boardId, sx, a, a + lr.w + 2 * gap, view.w, hiX)
    sx = clamp(sx, 0, hiX)
  if sx != st.scrollX: ui.redraw = true
  st.scrollX = sx
  state(id) = st
  if accessOn:
    # (the lanes as lists of their cards; a press picks a card)
    accessBegin(arPane, "", r, id, takesLabel = true)
    for li in 0 ..< n:
      let lr = laneR(li)
      accessBegin(arList, lanes[li].title & " (" & $lanes[li].cards.len & ")", lr,
                  accessSubId(id, 50000 + li))
      for ci, c in lanes[li].cards:
        let cid = accessSubId(id, 100000 + li * 4096 + ci)
        if accessPress != 0 and accessPress == cid:
          accessPress = 0
          sel = (li, ci)
          ui.focus = id
        var more = c.detail
        if c.who.len > 0: more.add (if more.len > 0: ", " else: "") & c.who
        if c.due.valid: more.add (if more.len > 0: ", " else: "") & $c.due
        let k = accessNode(arListItem, c.title, id = cid, r = lr,
                           states = (if sel == (li, ci): {asSelected} else: {}), help = more)
        accessItem(k, ci + 1, lanes[li].cards.len)
        if sel == (li, ci) and focused: accessFocus(k)
      accessEnd()
    accessEnd()
  if sel != oldSel: result.selChanged = true
  ui.lastId = id
  ui.lastRect = r

# ---- the Gantt chart ------------------------------------------------------------------------------

type
  GanttTask* = object
    ## A task of a `ganttView`.
    name*: string          ## shown in the list at its left
    start*, finish*: Date  ## its first and its last day
    progress*: float       ## how much is done, 0 .. 1
    color*: Color          ## (alpha 0: the selection color)
    level*: int            ## how deep it is: the deeper tasks after it are its parts
    deps*: seq[int]        ## the tasks (indices) that must end before it starts
    milestone*: bool       ## a moment, not a span: a diamond at `start`
    closed*: bool          ## its parts are folded away
  GanttScale* = enum
    ## How much of the time line a column is.
    gsDay = "Days", gsWeek = "Weeks", gsMonth = "Months"
  GanttEvent* = object
    ## What happened in a `ganttView` this frame.
    selChanged*: bool      ## `sel` changed
    changed*: bool         ## `task` was moved or stretched (its dates are changed already)
    opened*: bool          ## `task` was double-clicked (or Enter)
    toggled*: bool         ## `task`'s parts were folded or unfolded
    task*: int             ## the task the others speak of (an index)

proc doneShare(progress: float): float =
  ## (a task's progress as drawn: 0 .. 1, and 0 for NaN -- a file's or a
  ## formula's -- whose conversion to a whole number is undefined)
  if progress.isNaN: 0.0 else: clamp(progress, 0.0, 1.0)

var
  ganttDrag: tuple[id: Id; task, part, x0: int; s0, f0: Date; live: bool]
    ## a bar being dragged; part: 0 the whole bar, 1 its start, 2 its end
  gShown, gRowOf: seq[int]
  gSpan: seq[tuple[lo, hi: int]]
  gAcc: seq[tuple[level, lo, hi: int]]

proc hasParts(tasks: seq[GanttTask]; i: int): bool {.inline.} =
  i + 1 < tasks.len and tasks[i + 1].level > tasks[i].level

proc ownSpan(t: GanttTask): tuple[lo, hi: int] =
  let a = dayNumber(t.start)
  let b = dayNumber(t.finish)
  if t.milestone or b < a: (a, a) else: (a, b)

proc pxPerDay(s: GanttScale): int =
  case s
  of gsDay: dp(26)
  of gsWeek: dp(7)
  of gsMonth: dp(3)

proc ganttRange(tasks: seq[GanttTask]; s: GanttScale): tuple[d0, d1: int] =
  ## The days the time line shows: the tasks', with room around, and today.
  let t = dayNumber(today())
  var lo = t
  var hi = t
  for k in tasks:
    let (a, b) = ownSpan(k)
    lo = min(lo, a)
    hi = max(hi, b)
  var d0 = fromDayNumber(lo - 7)
  let d1 = hi + 35
  d0 = case s
       of gsMonth: date(d0.year, d0.month, 1)
       else: weekStart(d0)
  (dayNumber(d0), d1)

proc ganttView*(tasks: var seq[GanttTask]; sel: var int; scale: var GanttScale;
                height = -1; listW = 0; weekend: openArray[int] = [0, 6];
                key = ""): GanttEvent {.discardable.} =
  ## Tasks on a time line: their names at the left (deeper ones indented
  ## under the task they are part of, which shows as a summary bar and folds
  ## with its ``[-]`` box), their bars at the right with how much is done, the
  ## `deps` as arrows, milestones as diamonds, today as a red line, the
  ## `weekend` days (0 Sunday .. 6 Saturday) shaded. Drag a bar to move it,
  ## its ends to change its dates (whole days; a finger: hold, then move);
  ## Ctrl + Left / Right move the chosen task a day, Ctrl + Shift + Left /
  ## Right change its end. Zoom with the - and + buttons, the - and + keys or
  ## Ctrl + the wheel; T or "Today" scrolls to today. Up, Down, Page Up, Page
  ## Down, Home, End choose; Space folds; Enter or a double click opens.
  ## `listW`: the width of the names (design pixels; 0: chosen; drag the
  ## line to change it). `height` in pixels (-1: the room left).
  result.task = -1
  let h = if height < 0: remainingH() else: height
  let r = place(0, h, fill = true)
  let id = idOf("gantt:" & key)
  var st = state(id)
  let n = tasks.len
  let oldSel = sel
  if n > 0: sel = clamp(sel, 0, n - 1) else: sel = -1
  let focused = tabStop(id, r)
  let lineH = FontH + dp(6)
  let hdrH = 2 * lineH
  let rowH = max(ItemH + dp(8), if fingers(): dp(32) else: 0)
  var lw = if st.aux2 > 0: st.aux2 elif listW > 0: dp(listW)
           elif isCompact(): dp(130) else: dp(220)
  lw = clamp(lw, dp(80), max(dp(80), r.w div 2))
  # the rows shown (parts of folded tasks left out) and the summary spans
  gShown.setLen(0)
  gRowOf.setLen(n)
  for i in 0 ..< n: gRowOf[i] = -1
  var hideBelow = high(int)
  for i in 0 ..< n:
    if tasks[i].level > hideBelow: continue
    hideBelow = high(int)
    gRowOf[i] = gShown.len
    gShown.add i
    if hasParts(tasks, i) and tasks[i].closed: hideBelow = tasks[i].level
  gSpan.setLen(n)
  gAcc.setLen(0)
  for i in countdown(n - 1, 0):
    var s = ownSpan(tasks[i])
    if hasParts(tasks, i):
      s = (high(int), low(int))
      while gAcc.len > 0 and gAcc[^1].level > tasks[i].level:
        s.lo = min(s.lo, gAcc[^1].lo)
        s.hi = max(s.hi, gAcc[^1].hi)
        discard gAcc.pop()
      if s.lo > s.hi: s = ownSpan(tasks[i])
    gSpan[i] = s
    gAcc.add (tasks[i].level, s.lo, s.hi)
  # zoom: Ctrl + the wheel (keeping the day under the mouse), the keys
  var zoomTo = scale
  var anchorX = -1
  if st.caret > 0:                       # the - or + button, last frame
    zoomTo = GanttScale(clamp(st.caret - 1, 0, 2))
    st.caret = 0
  if canInput():
    if mouseIn(r) and ui.wheel != 0 and not ui.wheelUsed and CtrlPressed in ui.mods:
      zoomTo = GanttScale(clamp(ord(scale) - sgn(ui.wheel), 0, 2))
      anchorX = ui.mx
      ui.wheelUsed = true
    if focused and not ui.keyUsed and CtrlPressed notin ui.mods:
      if ui.key in {KeyPlus, KeyEqual}:
        zoomTo = GanttScale(max(0, ord(scale) - 1))
        ui.keyUsed = true
      elif ui.key == KeyMinus:
        zoomTo = GanttScale(min(2, ord(scale) + 1))
        ui.keyUsed = true
  var (d0, d1) = ganttRange(tasks, scale)
  var ppd = pxPerDay(scale)
  var sx = st.scrollX
  var sy = st.scrollY
  let tlX0 = r.x + lw + 1
  if zoomTo != scale:
    let ax = if anchorX >= tlX0: anchorX else: tlX0 + (r.w - lw) div 2
    let dayAt = d0 + (ax - tlX0 + sx) div max(1, ppd)
    scale = zoomTo
    (d0, d1) = ganttRange(tasks, scale)
    ppd = pxPerDay(scale)
    sx = (dayAt - d0) * ppd - (ax - tlX0)
  let totalW = (d1 - d0 + 1) * ppd
  let contentH = gShown.len * rowH
  var vBar, hBar = false
  for _ in 0 .. 1:
    hBar = totalW > r.w - lw - 1 - (if vBar: SbW else: 0)
    vBar = contentH > r.h - hdrH - (if hBar: SbW else: 0)
  let tl = rect(tlX0, r.y + hdrH, r.w - lw - 1 - (if vBar: SbW else: 0),
                r.h - hdrH - (if hBar: SbW else: 0))
  let lst = rect(r.x, tl.y, lw, tl.h)
  # the scrollers (they glide, a flick goes on): the rows id + 61, the time
  # line id + 62
  let hiYg = max(0, contentH - tl.h)
  let hiXg = max(0, totalW - tl.w)
  let tdn = dayNumber(today())
  if st.aux == 0:                        # first shown: today near the left
    st.aux = 1
    sx = (tdn - d0 - (if scale == gsDay: 3 else: 14)) * ppd
  template xOf(dn: int): int = tl.x - sx + (dn - d0) * ppd
  var follow = false
  # the line between the names and the time line: drag it
  let divR = rect(r.x + lw - 3, r.y, 7, r.h - (if hBar: SbW else: 0))
  if canInput() and mouseIn(divR) and ganttDrag.id != id: ui.cursor = curSizeWE
  if canInput() and hover(divR) and takePress():
    ui.active = id + 7
    ui.dragsActive = true
  if ui.active == id + 7 and ui.mouseDown:
    st.aux2 = clamp(ui.mx - r.x, dp(80), max(dp(80), r.w div 2))
    ui.cursor = curSizeWE
    ui.redraw = true
  # the parts of a bar: where `i`'s bar is, and which part `mx` is on
  proc barSpan(i: int; d0, ppd, x0: int): tuple[a, b: int] =
    let s = gSpan[i]
    (x0 + (s.lo - d0) * ppd, x0 + (s.hi + 1 - d0) * ppd)
  let edgeW = if fingers(): dp(12) else: dp(5)
  # presses: on the names, on the time line
  let listHit = interact(id + 1, lst, focusable = false)
  let tlHit = interact(id + 2, tl, focusable = false)
  if canInput():
    if tapped(id + 1, listHit):
      let k = (ui.my - lst.y + sy) div rowH
      if k in 0 .. gShown.high:
        let i = gShown[k]
        let boxX = lst.x + dp(4) + tasks[i].level * dp(14)
        if hasParts(tasks, i) and ui.mx >= boxX - dp(2) and ui.mx < boxX + dp(14):
          tasks[i].closed = not tasks[i].closed
          result.toggled = true
          result.task = i
        else:
          sel = i
          if ui.clicks >= 2:
            result.opened = true
            result.task = i
            markDouble(id)
        ui.focus = id
    # the time line: a press on a bar may drag it
    if ui.active == id + 2 and ui.pressed:
      ui.focus = id
      let k = (ui.my - tl.y + sy) div rowH
      ganttDrag.id = 0
      if k in 0 .. gShown.high:
        let i = gShown[k]
        sel = i
        let (a, b) = barSpan(i, d0, ppd, tl.x - sx)
        let isParent = hasParts(tasks, i)
        let pad = if tasks[i].milestone: rowH div 2 else: 0
        if not isParent and ui.mx >= a - edgeW - pad and ui.mx <= b + edgeW + pad:
          var part = 0
          if not tasks[i].milestone and b - a > 3 * edgeW:
            if ui.mx <= a + edgeW: part = 1
            elif ui.mx >= b - edgeW: part = 2
          ganttDrag = (id, i, part, ui.mx, tasks[i].start, tasks[i].finish, false)
          if not finger(): ui.dragsActive = true
        if ui.clicks >= 2:
          result.opened = true
          result.task = i
          markDouble(id)
    if tapped(id + 2, tlHit) and finger():
      let k = (ui.my - tl.y + sy) div rowH
      if k in 0 .. gShown.high: sel = gShown[k]
    # dragging a bar: whole days
    if ganttDrag.id == id and ui.mouseDown and ganttDrag.task < n:
      if not ganttDrag.live:
        if finger(): ganttDrag.live = lifted()
        elif abs(ui.mx - ganttDrag.x0) > dp(4): ganttDrag.live = true
        if ganttDrag.live: ui.dragsActive = true
      if ganttDrag.live:
        let i = ganttDrag.task
        let d = int(round((ui.mx - ganttDrag.x0) / max(1, ppd)))
        var s = ganttDrag.s0
        var f = ganttDrag.f0
        case ganttDrag.part
        of 1:
          s = ganttDrag.s0.addDays(d)
          if dayNumber(s) > dayNumber(f): s = f
        of 2:
          f = ganttDrag.f0.addDays(d)
          if dayNumber(f) < dayNumber(s): f = s
        else:
          s = ganttDrag.s0.addDays(d)
          f = ganttDrag.f0.addDays(d)
        if s != tasks[i].start or f != tasks[i].finish:
          tasks[i].start = s
          tasks[i].finish = f
          result.changed = true
          result.task = i
        ui.cursor = curSizeWE
        # near the ends: the time line scrolls on
        if ui.mx > tl.x + tl.w - dp(16): sx += ppd; wakeIn(40)
        elif ui.mx < tl.x + dp(16): sx -= ppd; wakeIn(40)
    if not ui.mouseDown: ganttDrag.id = 0
    # the cursor over a bar's ends
    if ganttDrag.id != id and mouseIn(tl) and not ui.mouseDown:
      let k = (ui.my - tl.y + sy) div rowH
      if k in 0 .. gShown.high:
        let i = gShown[k]
        if not hasParts(tasks, i) and not tasks[i].milestone:
          let (a, b) = barSpan(i, d0, ppd, tl.x - sx)
          if b - a > 3 * edgeW and (abs(ui.mx - a) <= edgeW or abs(ui.mx - b) <= edgeW):
            ui.cursor = curSizeWE
    # the wheel and fingers
    scrollWheel(id + 62, sx, hiXg, r, dp(60), sideways = true)
    scrollWheel(id + 61, sy, hiYg, r, 3 * rowH)
    if mouseIn(r) and ui.wheel != 0 and not ui.wheelUsed: ui.wheelUsed = true
    let rowsR = rect(r.x, tl.y, r.w, tl.h)
    if tl.contains(ui.panFrom) or (ui.pressed and mouseIn(tl)):
      scrollPan2(id + 61, sy, hiYg, id + 62, sx, hiXg, rowsR)
    else:
      scrollPan(id + 61, sy, hiYg, rowsR)
  # the keys
  if focused and canInput() and not ui.keyUsed and n > 0:
    let ctrl = CtrlPressed in ui.mods
    let shift = ShiftPressed in ui.mods
    var k = max(0, gRowOf[max(0, sel)])
    let vis = max(1, tl.h div rowH)
    case ui.key
    of KeyUp: k = max(0, k - 1); follow = true
    of KeyDown: k = min(gShown.high, k + 1); follow = true
    of KeyPageUp: k = max(0, k - vis + 1); follow = true
    of KeyPageDown: k = min(gShown.high, k + vis - 1); follow = true
    of KeyHome: k = 0; follow = true
    of KeyEnd: k = gShown.high; follow = true
    of KeyLeft, KeyRight:
      let d = if ui.key == KeyLeft: -1 else: 1
      if ctrl and sel >= 0 and not hasParts(tasks, sel):
        if shift and not tasks[sel].milestone:
          let f = tasks[sel].finish.addDays(d)
          if dayNumber(f) >= dayNumber(tasks[sel].start): tasks[sel].finish = f
        else:
          tasks[sel].start = tasks[sel].start.addDays(d)
          tasks[sel].finish = tasks[sel].finish.addDays(d)
        result.changed = true
        result.task = sel
      else: scrollBy(id + 62, sx, d * 7 * ppd, hiXg)
    of KeySpace:
      if sel >= 0 and hasParts(tasks, sel):
        tasks[sel].closed = not tasks[sel].closed
        result.toggled = true
        result.task = sel
    of KeyEnter:
      if sel >= 0:
        result.opened = true
        result.task = sel
    of KeyT: scrollTo(id + 62, sx, (tdn - d0 - (if scale == gsDay: 3 else: 14)) * ppd, hiXg)
    else: discard
    if ui.key in {KeyUp, KeyDown, KeyPageUp, KeyPageDown, KeyHome, KeyEnd, KeyLeft,
                  KeyRight, KeySpace, KeyEnter, KeyT}:
      ui.keyUsed = true
    if follow and k in 0 .. gShown.high: sel = gShown[k]
  if result.toggled:
    ui.redraw = true                      # (the rows shown change next frame)
  if follow and sel >= 0 and gRowOf[sel] >= 0:
    let y = gRowOf[sel] * rowH
    scrollShow(id + 61, sy, y, y + rowH, tl.h, hiYg)
    let (a, b) = barSpan(sel, d0, ppd, tl.x - sx)
    if b < tl.x or a > tl.x + tl.w: scrollTo(id + 62, sx, sx + a - tl.x - dp(40), hiXg)
  scrollTick(id + 61, sy, hiYg)
  scrollTick(id + 62, sx, hiXg)
  sx = clamp(sx, 0, max(0, totalW - tl.w))
  sy = clamp(sy, 0, max(0, contentH - tl.h))
  # ---- draw: the corner with the zoom buttons and the column titles
  let corner = rect(r.x, r.y, lw, hdrH)
  fill(corner, th.face)
  hline(corner.x, corner.y + corner.h - 1, corner.w, th.edge)
  let bh = lineH - dp(4)
  let bw = max(bh, textWidth("+") + dp(12))
  if miniButton(id + 11, rect(corner.x + dp(4), corner.y + dp(2), bw, bh), "-",
                ord(scale) < 2):
    st.caret = ord(scale) + 2            # (zoomed out next frame)
    ui.redraw = true
  if miniButton(id + 12, rect(corner.x + dp(6) + bw, corner.y + dp(2), bw, bh), "+",
                ord(scale) > 0):
    st.caret = ord(scale)                # (zoomed in next frame)
    ui.redraw = true
  let tdW = textWidth("Today") + dp(12)
  if miniButton(id + 13, rect(corner.x + dp(8) + 2 * bw, corner.y + dp(2), tdW, bh), "Today"):
    sx = (tdn - d0 - (if scale == gsDay: 3 else: 14)) * ppd
    sx = clamp(sx, 0, max(0, totalW - tl.w))
  let durW = textWidth("000d") + dp(8)
  text(corner.x + dp(6), corner.y + lineH + (lineH - FontH) div 2, "Task", th.text, true)
  text(corner.x + corner.w - durW, corner.y + lineH + (lineH - FontH) div 2, "Days", th.text, true)
  # the time line's header: months (or years) over days (or weeks, months)
  let hdr = rect(tl.x, r.y, tl.w, hdrH)
  fill(hdr, th.face)
  hline(hdr.x, hdr.y + lineH - 1, hdr.w, th.shadow)
  hline(hdr.x, hdr.y + hdrH - 1, hdr.w, th.edge)
  pushClip(hdr)
  let firstDay = d0 + max(0, sx div max(1, ppd)) - 1
  let lastDay = min(d1, d0 + (sx + tl.w) div max(1, ppd) + 1)
  var dn = firstDay
  while dn <= lastDay:
    let d = fromDayNumber(dn)
    let x = xOf(dn)
    let ty = hdr.y + lineH + (lineH - FontH) div 2
    case scale
    of gsDay:
      if weekday(d) in weekend: fill(rect(x, hdr.y + lineH, ppd, lineH - 1), mixColor(th.face, th.shadow, 0.25))
      vline(x, hdr.y + lineH, lineH, th.shadow)
      let s = $d.day
      text(x + (ppd - textWidth(s, smallSt())) div 2, ty + dp(1), s, th.text, smallSt())
    of gsWeek:
      if weekday(d) == firstWeekday:
        vline(x, hdr.y + lineH, lineH, th.shadow)
        let s = $d.day & " " & monthShort(d.month)
        if textWidth(s, smallSt()) < 7 * ppd - 2:
          text(x + dp(3), ty + dp(1), s, th.text, smallSt())
    of gsMonth:
      if d.day == 1:
        vline(x, hdr.y + lineH, lineH, th.shadow)
        text(x + dp(3), ty + dp(1), monthShort(d.month), th.text, smallSt())
    # the upper line: months (years when zoomed out)
    let topStart = if scale == gsMonth: d.month == 1 and d.day == 1 else: d.day == 1
    if topStart or dn == firstDay:
      let label = if scale == gsMonth: $d.year else: monthNames[d.month - 1] & " " & $d.year
      if topStart: vline(x, hdr.y, lineH, th.shadow)
      let lx = max(x + dp(4), hdr.x + dp(4))
      text(lx, hdr.y + (lineH - FontH) div 2, label, th.text, true)
    inc dn
  popClip()
  # the names
  fill(lst, th.field)
  pushClip(lst)
  let firstRow = max(0, sy div rowH)
  let lastRow = min(gShown.high, (sy + tl.h) div rowH)
  for k in firstRow .. lastRow:
    let i = gShown[k]
    let y = lst.y + k * rowH - sy
    let rr = rect(lst.x, y, lst.w, rowH)
    let isSel = i == sel
    if isSel: fill(rr, if focused: th.select else: mixColor(th.field, th.select, 0.2))
    hline(rr.x, y + rowH - 1, rr.w, th.face)
    let fg = if isSel and focused: th.selectText else: th.fieldText
    let parts = hasParts(tasks, i)
    let ix = lst.x + dp(4) + tasks[i].level * dp(14)
    if parts:
      let bs = dp(9)
      foldBox(rect(ix + 1, y + (rowH - bs) div 2, bs, bs), not tasks[i].closed)
    let nx = ix + dp(14)
    let s = gSpan[i]
    let days = if tasks[i].milestone: "0d" else: $(s.hi - s.lo + 1) & "d"
    text(lst.x + lst.w - durW, y + (rowH - FontH) div 2, days,
         if isSel and focused: th.selectText else: th.gray)
    text(nx, y + (rowH - FontH) div 2,
         ellipsize(tasks[i].name, max(10, lst.x + lst.w - durW - nx - dp(6)), style(bold = parts)),
         fg, parts)
    if isSel and focused: dots(inset(rr, 1), th.selectText)
  popClip()
  vline(r.x + lw, r.y, r.h - (if hBar: SbW else: 0), th.edge)
  # the time line: weekends, lines, today, the rows
  fill(tl, th.field)
  pushClip(tl)
  dn = firstDay
  while dn <= lastDay:
    let d = fromDayNumber(dn)
    let x = xOf(dn)
    if scale != gsMonth and weekday(d) in weekend:
      fill(rect(x, tl.y, ppd, tl.h), mixColor(th.field, th.face, 0.45))
    let lineAt = case scale
                 of gsDay: true
                 of gsWeek: weekday(d) == firstWeekday
                 of gsMonth: d.day == 1
    if lineAt: vline(x, tl.y, tl.h, mixColor(th.field, th.face, 0.8))
    inc dn
  for k in firstRow .. lastRow:
    let y = tl.y + k * rowH - sy
    if gShown[k] == sel: fill(rect(tl.x, y, tl.w, rowH), mixColor(th.field, th.select, 0.08))
    hline(tl.x, y + rowH - 1, tl.w, mixColor(th.field, th.face, 0.6))
  let tx = xOf(tdn) + ppd div 2
  vline(tx, tl.y, tl.h, bad())
  # dependency arrows (to the rows in view)
  let lineC = mixColor(th.text, th.field, 0.35)
  for k in firstRow .. lastRow:
    let t = gShown[k]
    for dep in tasks[t].deps:
      if dep < 0 or dep >= n or dep == t or gRowOf[dep] < 0: continue
      let (_, xe) = barSpan(dep, d0, ppd, tl.x - sx)
      let (xs, _) = barSpan(t, d0, ppd, tl.x - sx)
      let ya = tl.y + gRowOf[dep] * rowH - sy + rowH div 2
      let yb = tl.y + k * rowH - sy + rowH div 2
      let xm = xe + dp(6)
      if xs - dp(6) >= xm:
        hline(xe, ya, xm - xe, lineC)
        vline(xm, min(ya, yb), abs(yb - ya) + 1, lineC)
        hline(xm, yb, xs - xm - dp(3), lineC)
      else:
        # back to the left: down between the rows first
        let yr = (if yb > ya: tl.y + gRowOf[dep] * rowH - sy + rowH
                  else: tl.y + gRowOf[dep] * rowH - sy)
        hline(xe, ya, xm - xe, lineC)
        vline(xm, min(ya, yr), abs(yr - ya) + 1, lineC)
        let xl = xs - dp(10)
        hline(min(xl, xm), yr, abs(xm - xl) + 1, lineC)
        vline(xl, min(yr, yb), abs(yb - yr) + 1, lineC)
        hline(xl, yb, xs - xl - dp(3), lineC)
      arrow(xs - dp(3), yb, dRight, lineC, dp(5))
  # the bars
  for k in firstRow .. lastRow:
    let i = gShown[k]
    let y = tl.y + k * rowH - sy
    let (a, b) = barSpan(i, d0, ppd, tl.x - sx)
    let c = if tasks[i].color.a == 0: th.select else: tasks[i].color
    let by = y + rowH div 5
    let bh2 = rowH - 2 * (rowH div 5) - 1
    var labelX = b + dp(6)
    if hasParts(tasks, i):
      # a summary: a dark band with its ends pointing down
      let sh = max(dp(4), bh2 div 3)
      fill(rect(a, by + dp(1), b - a, sh), th.text)
      arrow(a + dp(3), by + dp(1) + sh + dp(2), dDown, th.text, dp(5))
      arrow(b - dp(4), by + dp(1) + sh + dp(2), dDown, th.text, dp(5))
    elif tasks[i].milestone:
      let cx = float(a + ppd div 2)
      let cy = float(y + rowH div 2)
      let s = float(bh2) * 0.6
      polygon([(cx, cy - s), (cx + s, cy), (cx, cy + s), (cx - s, cy)], th.text)
      labelX = int(cx + s) + dp(6)
    else:
      let w = max(dp(3), b - a)
      let br = rect(a, by, w, bh2)
      fill(br, mixColor(c, th.field, 0.55))
      let done = int(float(w) * doneShare(tasks[i].progress))
      if done > 0: fill(rect(a, by, done, bh2), c)
      box(br, mixColor(c, th.frame, 0.4))
      if tasks[i].progress > 0 and w > textWidth("100%", smallSt()) + dp(6):
        let ps = $int(round(doneShare(tasks[i].progress) * 100)) & "%"
        text(a + dp(3), by + (bh2 - lineHeight(smallSt())) div 2, ps,
             if done > textWidth(ps, smallSt()) + dp(3): th.selectText else: th.text, smallSt())
    if i == sel:
      box(rect(a - 2, by - 2, max(dp(3), b - a) + 4, bh2 + 4), th.select)
    if labelX < tl.x + tl.w:
      text(labelX, y + (rowH - FontH) div 2, tasks[i].name, th.gray)
  popClip()
  if n == 0:
    let s = "No tasks"
    text(tl.x + (tl.w - textWidth(s)) div 2, tl.y + dp(12), s, th.gray)
  # the scroll bars
  if vBar:
    scrollBarFor(id + 21, id + 61, rect(r.x + r.w - SbW, r.y + hdrH, SbW, tl.h), true, sy,
                 hiYg, max(rowH, tl.h - 2 * rowH), rowH)
  if hBar:
    scrollBarFor(id + 22, id + 62, rect(tl.x, r.y + r.h - SbW, tl.w + (if vBar: SbW else: 0), SbW),
                 false, sx, hiXg, max(ppd, tl.w - dp(60)), ppd)
    fill(rect(r.x, r.y + r.h - SbW, lw + 1, SbW), th.face)
  fieldFrame(r)
  if sx != st.scrollX or sy != st.scrollY: ui.redraw = true
  st.scrollX = sx
  st.scrollY = sy
  state(id) = st
  if accessOn:
    # (the tasks as a tree: each at its depth, its days and how far along)
    accessBegin(arTree, "", r, id, takesLabel = true)
    for i in 0 ..< n:
      let t = tasks[i]
      let nid = accessSubId(id, i)
      if accessPress != 0 and accessPress == nid:
        accessPress = 0
        sel = i
        ui.focus = id
      let k = accessNode(arTreeItem, t.name, id = nid, r = r,
                         states = (if i == sel: {asSelected} else: {}),
                         help = $t.start & " - " & $t.finish & ", " & $int(doneShare(t.progress) * 100 + 0.5) & "%")
      accessItem(k, i + 1, n, t.level + 1)
      if i == sel and focused: accessFocus(k)
    accessEnd()
  if sel != oldSel: result.selChanged = true
  ui.lastId = id
  ui.lastRect = r

# ---- the agenda -----------------------------------------------------------------------------------

type
  Appointment* = object
    ## An entry of an `agendaView`.
    title*: string         ## what it is
    day*: Date             ## the day it is on
    start*, finish*: int   ## minutes after midnight, 0 .. 1440
    allDay*: bool          ## the whole day (`start` and `finish` not used)
    color*: Color          ## (alpha 0: the selection color)
  AgendaMode* = enum
    ## How much an `agendaView` shows at once.
    amMonth = "Month", amWeek = "Week", amDay = "Day"
  AgendaEvent* = object
    ## What happened in an `agendaView` this frame.
    opened*: bool          ## `item` was clicked (or tapped)
    moved*: bool           ## `item` was dragged to another day or time (changed already)
    added*: bool           ## an empty day or time was clicked: a new entry at
    addDay*: Date          ## `addDay`, `addMinute` (-1: all day)
    addMinute*: int        ## ... the minute after midnight clicked (-1: all day)
    navigated*: bool       ## `day` or `mode` changed
    item*: int             ## the entry of `opened` and `moved` (an index)

var agendaDrag: tuple[id: Id; item, x0, y0, grab, part: int; live: bool]
  ## an entry pressed (and maybe dragged); part 0 moves it, 1 its end

proc periodTitle(day: Date; mode: AgendaMode): string =
  case mode
  of amMonth: monthNames[day.month - 1] & " " & $day.year
  of amWeek:
    let a = weekStart(day)
    let b = a.addDays(6)
    if a.month == b.month: $a.day & " - " & $b.day & " " & monthShort(b.month) & " " & $b.year
    else: $a.day & " " & monthShort(a.month) & " - " & $b.day & " " &
          monthShort(b.month) & " " & $b.year
  of amDay: dayNamesLong[weekday(day)] & " " & $day.day & " " & monthNames[day.month - 1] &
            " " & $day.year

proc timeText(m: int): string =
  let mm = clamp(m, 0, 1440)
  align($(mm div 60), 2, '0') & ":" & align($(mm mod 60), 2, '0')

proc chip(r: Rect; a: Appointment; selected: bool) =
  ## An entry in a month cell or the all-day row.
  let c = if a.color.a == 0: th.select else: a.color
  fill(r, if a.allDay: c else: mixColor(c, th.field, 0.8))
  if not a.allDay: fill(rect(r.x, r.y, dp(3), r.h), c)
  if selected: box(r, th.frame)
  let s = if a.allDay: a.title else: timeText(a.start) & " " & a.title
  pushClip(intersect(r, clipRect()))
  text(r.x + dp(5), r.y + (r.h - lineHeight(smallSt())) div 2, ellipsize(s, r.w - dp(6), smallSt()),
       if a.allDay: color(255, 255, 255) else: th.fieldText, smallSt())
  popClip()

proc agendaView*(items: var seq[Appointment]; day: var Date; mode: var AgendaMode;
                 height = -1; key = ""): AgendaEvent {.discardable.} =
  ## Appointments by month (a grid of weeks with the entries of each day,
  ## "+3 more" when they do not fit), by week (seven days of hours, the
  ## all-day ones on top) or by day; `day` is the day in focus. Previous,
  ## Next and Today (also Page Up, Page Down, Home) move through time, the
  ## arrows move the day. A click on an entry opens it (`opened`), on an
  ## empty day or time asks for a new one (`added`); drag an entry to
  ## another day or time (a finger: hold, then move), or its lower edge to
  ## change when it ends (15 minutes at a time). `height` in pixels (-1: the
  ## room left).
  result.item = -1
  result.addMinute = -1
  if not day.valid: day = today()
  let id = idOf("agenda:" & key)
  let ip = addr items                    # (for the procs inside: not a var param)
  let before = (day, mode)
  let total = if height < 0: remainingH() else: height
  # the bar: previous, next, today, the period, the view
  let modeSlot = intSlot("agenda-mode:" & key)
  modeSlot[] = ord(mode)
  template step(d: int) =
    case mode
    of amMonth: day = day.addMonths(d)
    of amWeek: day = day.addDays(7 * d)
    of amDay: day = day.addDays(d)
  row:
    if toolButton(retroOr(pxBack, nfChevronLeft), "Previous (Page Up)"): step(-1)
    if toolButton(retroOr(pxForward, nfChevronRight), "Next (Page Down)"): step(1)
    if button("&Today"): day = today()
    label(periodTitle(day, mode), bold = true)
    spring()
    if segmented(["Month", "Week", "Day"], modeSlot[]): mode = AgendaMode(modeSlot[])
  let h = if height < 0: remainingH() else: max(dp(80), total - CtrlH - Gap)
  let r = place(0, h, fill = true)
  var st = state(id)
  let focused = tabStop(id, r)
  # the keys
  if focused and canInput() and not ui.keyUsed:
    case ui.key
    of KeyLeft: day = day.addDays(-1); ui.keyUsed = true
    of KeyRight: day = day.addDays(1); ui.keyUsed = true
    of KeyUp:
      if mode == amMonth: day = day.addDays(-7)
      else: st.scrollY -= (if fingers(): dp(52) else: dp(42))
      ui.keyUsed = true
    of KeyDown:
      if mode == amMonth: day = day.addDays(7)
      else: st.scrollY += (if fingers(): dp(52) else: dp(42))
      ui.keyUsed = true
    of KeyPageUp: step(-1); ui.keyUsed = true
    of KeyPageDown: step(1); ui.keyUsed = true
    of KeyHome: day = today(); ui.keyUsed = true
    of KeyEnter:
      result.added = true
      result.addDay = day
      result.addMinute = -1
      ui.keyUsed = true
    else: discard
  fill(r, th.field)
  let tdn = dayNumber(today())
  if mode == amMonth:
    # ---- a month: six weeks of days
    let first = date(day.year, day.month, 1)
    let gridStart = weekStart(first)
    let dn0 = dayNumber(gridStart)
    let headH = FontH + dp(6)
    let cw = max(1, r.w div 7)
    let ch = max(1, (r.h - headH) div 6)
    let grid = rect(r.x, r.y + headH, r.w, r.h - headH)
    # (the columns and rows share the room exactly)
    template colX(c: int): int = grid.x + c * grid.w div 7
    template rowY(rw: int): int = grid.y + rw * grid.h div 6
    var perDay: array[42, seq[int]]
    for i, it in items:
      let k = dayNumber(it.day) - dn0
      if k in 0 .. 41: perDay[k].add i
    for k in 0 .. 41:
      if perDay[k].len > 1:
        # all-day ones first, then by the time they start
        var keyed: seq[tuple[at, i: int]]
        for i in perDay[k]: keyed.add ((if ip[][i].allDay: -1 else: ip[][i].start), i)
        keyed.sort()
        for j, kk in keyed: perDay[k][j] = kk.i
    let numH = FontH + dp(2)
    let chipH = lineHeight(smallSt()) + dp(3)
    let fits = max(0, (ch - numH - dp(2)) div (chipH + dp(1)))
    template cellOf(k: int): Rect =
      rect(colX(k mod 7), rowY(k div 7), colX(k mod 7 + 1) - colX(k mod 7),
           rowY(k div 7 + 1) - rowY(k div 7))
    template chipOf(k, j: int): Rect =
      let c = cellOf(k)
      rect(c.x + dp(2), c.y + numH + j * (chipH + dp(1)), c.w - dp(4), chipH)
    # what is under the mouse: an entry, "+N more", or the day
    proc pick(mx, my: int): tuple[k, item: int; more: bool] =
      result = (-1, -1, false)
      if not grid.contains(point(mx, my)): return
      var cc = 0
      while cc < 6 and mx >= colX(cc + 1): inc cc
      var rr = 0
      while rr < 5 and my >= rowY(rr + 1): inc rr
      let k = rr * 7 + cc
      result.k = k
      let shownN = if perDay[k].len > fits: max(0, fits - 1) else: perDay[k].len
      for j in 0 ..< shownN:
        if chipOf(k, j).contains(point(mx, my)):
          result.item = perDay[k][j]
          return
      if perDay[k].len > fits and fits > 0 and chipOf(k, fits - 1).contains(point(mx, my)):
        result.more = true
    let hit = interact(id + 1, grid, focusable = false)
    if canInput():
      if ui.active == id + 1 and ui.pressed:
        ui.focus = id
        let p = pick(ui.mx, ui.my)
        agendaDrag = (id, p.item, ui.mx, ui.my, 0, 0, false)
      if agendaDrag.id == id and agendaDrag.item >= 0 and ui.mouseDown and not agendaDrag.live:
        if (not finger() and abs(ui.mx - agendaDrag.x0) + abs(ui.my - agendaDrag.y0) > dp(6)) or
           lifted():
          agendaDrag.live = true
          ui.dragsActive = true
      if ui.released and agendaDrag.id == id:
        let p = pick(ui.mx, ui.my)
        if agendaDrag.live:
          let it = agendaDrag.item
          if it in 0 .. items.high and p.k >= 0:
            let d = fromDayNumber(dn0 + p.k)
            if d != items[it].day:
              items[it].day = d
              result.moved = true
              result.item = it
        elif hit.clicked or (finger() and hit.clicked):
          if p.item >= 0 and p.item == agendaDrag.item:
            result.opened = true
            result.item = p.item
          elif p.more:
            day = fromDayNumber(dn0 + p.k)
            mode = amDay
          elif p.k >= 0 and agendaDrag.item < 0:
            day = fromDayNumber(dn0 + p.k)
            result.added = true
            result.addDay = day
            result.addMinute = -1
        agendaDrag.id = 0
      if not ui.mouseDown and not ui.released: agendaDrag.id = 0
    # draw: the names of the days, the cells, the entries
    let head = rect(r.x, r.y, r.w, headH)
    fill(head, th.face)
    hline(head.x, head.y + head.h - 1, head.w, th.edge)
    for c in 0 .. 6:
      let wd = (c + firstWeekday) mod 7
      let s = if cw > textWidth("Wednesday") + dp(8): dayNamesLong[wd]
              else: dayNamesLong[wd][0 .. 2]
      text(colX(c) + (colX(c + 1) - colX(c) - textWidth(s)) div 2, r.y + (headH - FontH) div 2,
           s, th.text)
    let dragTo = if agendaDrag.id == id and agendaDrag.live: pick(ui.mx, ui.my).k else: -1
    for k in 0 .. 41:
      let c = cellOf(k)
      let d = fromDayNumber(dn0 + k)
      let other = d.month != day.month
      if other: fill(c, mixColor(th.field, th.face, 0.35))
      if k == dragTo: fill(c, mixColor(th.field, th.select, 0.15))
      hline(c.x, c.y + c.h - 1, c.w, th.face)
      vline(c.x + c.w - 1, c.y, c.h, th.face)
      let s = $d.day
      let nw = textWidth(s, true) + dp(8)
      let nr = rect(c.x + c.w - nw - dp(3), c.y + dp(1), nw, FontH + 1)
      if dn0 + k == tdn:
        fill(nr, th.select)
        text(nr.x + dp(4), nr.y, s, th.selectText, true)
      else:
        text(nr.x + dp(4), nr.y, s, if other: th.gray else: th.text, d.day == 1)
      if d == day:
        box(inset(c, 1), if focused: th.select else: th.shadow)
        if focused: box(inset(c, 2), th.select)
      let shownN = if perDay[k].len > fits: max(0, fits - 1) else: perDay[k].len
      for j in 0 ..< shownN:
        let it = perDay[k][j]
        chip(chipOf(k, j), items[it], agendaDrag.id == id and agendaDrag.item == it)
      if perDay[k].len > fits and fits > 0:
        let mr = chipOf(k, fits - 1)
        let ms = "+" & $(perDay[k].len - shownN) & " more"
        text(mr.x + dp(4), mr.y + (mr.h - lineHeight(smallSt())) div 2, ms, th.link, smallSt(true))
    if dragTo >= 0 and agendaDrag.item in 0 .. items.high:
      # the entry at the pointer
      let g = rect(ui.mx - cw div 2 + dp(4), ui.my - chipH div 2, cw - dp(8), chipH)
      pushLayer(LayerTip)
      chip(g, items[agendaDrag.item], true)
      popLayer()
  else:
    # ---- a week or a day: hours
    let days = if mode == amWeek: 7 else: 1
    let wStart = if mode == amWeek: weekStart(day) else: day
    let dn0 = dayNumber(wStart)
    let gutter = textWidth("00:00") + dp(12)
    let headH = FontH + dp(8)
    let chipH = lineHeight(smallSt()) + dp(4)
    var allDay: array[7, seq[int]]
    var timed: array[7, seq[int]]
    for i, it in items:
      let k = dayNumber(it.day) - dn0
      if k in 0 ..< days:
        if it.allDay: allDay[k].add i else: timed[k].add i
    var most = 1
    for k in 0 ..< days: most = max(most, allDay[k].len)
    let adRows = min(most, 3)
    let adH = adRows * (chipH + dp(2)) + dp(4)
    let hourH = if fingers(): dp(52) else: dp(42)
    let body = rect(r.x + gutter, r.y + headH + adH, r.w - gutter - SbW, r.h - headH - adH)
    let colW = max(1, body.w div days)
    if st.aux == 0:                      # first shown: the working day in view
      st.aux = 1
      st.scrollY = 8 * hourH
    var sy = clamp(st.scrollY, 0, max(0, 24 * hourH - body.h))
    # overlapping entries side by side: a column each in their cluster
    var colOf = initTable[int, tuple[col, cols: int]]()
    for k in 0 ..< days:
      var keyed: seq[tuple[at, i: int]]
      for i in timed[k]: keyed.add (ip[][i].start, i)
      keyed.sort()
      var lst: seq[int]
      for kk in keyed: lst.add kk.i
      var cluster: seq[int]
      var ends: seq[int]
      var clusterEnd = -1
      proc closeCluster(cl: seq[int]; n: int) =
        for i in cl: colOf[i] = (colOf.getOrDefault(i).col, n)
      for i in lst:
        let s = ip[][i].start
        let f = max(ip[][i].finish, s + 15)
        if s >= clusterEnd and cluster.len > 0:
          closeCluster(cluster, ends.len)
          cluster.setLen(0)
          ends.setLen(0)
        var c = -1
        for j, e in ends:
          if e <= s:
            c = j
            break
        if c < 0:
          c = ends.len
          ends.add f
        else: ends[c] = f
        colOf[i] = (c, 1)
        cluster.add i
        clusterEnd = max(clusterEnd, f)
      if cluster.len > 0: closeCluster(cluster, ends.len)
    template blockOf(i, k: int): Rect =
      let cc = colOf.getOrDefault(i, (0, 1))
      let it = ip[][i]
      let w = max(dp(8), (colW - dp(6)) div max(1, cc.cols))
      rect(body.x + k * colW + dp(2) + cc.col * w,
           body.y - sy + it.start * hourH div 60,
           w - dp(1), max(chipH, (max(it.finish, it.start + 15) - it.start) * hourH div 60 - dp(1)))
    proc pickTimed(mx, my: int): tuple[item, part, k, minute: int] =
      result = (-1, 0, -1, -1)
      if not body.contains(point(mx, my)): return
      result.k = clamp((mx - body.x) div colW, 0, days - 1)
      result.minute = clamp((my - body.y + sy) * 60 div hourH, 0, 1439)
      for i in countdown(timed[result.k].high, 0):
        let b = blockOf(timed[result.k][i], result.k)
        if b.contains(point(mx, my)):
          result.item = timed[result.k][i]
          result.part = if my >= b.y + b.h - dp(6) and b.h > dp(14): 1 else: 0
          return
    let adR = rect(r.x + gutter, r.y + headH, body.w, adH)
    proc pickAllDay(mx, my: int): tuple[item, k: int] =
      result = (-1, -1)
      if not adR.contains(point(mx, my)): return
      result.k = clamp((mx - adR.x) div colW, 0, days - 1)
      for j in 0 ..< min(allDay[result.k].len, adRows):
        let cr = rect(adR.x + result.k * colW + dp(2), adR.y + dp(2) + j * (chipH + dp(2)),
                      colW - dp(4), chipH)
        if cr.contains(point(mx, my)):
          result.item = allDay[result.k][j]
          return
    let hit = interact(id + 2, body, focusable = false)
    let adHit = interact(id + 3, adR, focusable = false)
    let hiA = max(0, 24 * hourH - body.h)       # (the hours: scroller id + 41)
    if canInput():
      scrollWheel(id + 41, sy, hiA, body, hourH)
      scrollPan(id + 41, sy, hiA, body)
      if ui.active == id + 2 and ui.pressed:
        ui.focus = id
        let p = pickTimed(ui.mx, ui.my)
        let grab = if p.item >= 0: p.minute - items[p.item].start else: 0
        agendaDrag = (id, p.item, ui.mx, ui.my, grab, p.part, false)
      if ui.active == id + 3 and ui.pressed:
        ui.focus = id
        let p = pickAllDay(ui.mx, ui.my)
        agendaDrag = (id, p.item, ui.mx, ui.my, 0, 2, false)
      if agendaDrag.id == id and agendaDrag.item >= 0 and ui.mouseDown and not agendaDrag.live:
        if (not finger() and abs(ui.mx - agendaDrag.x0) + abs(ui.my - agendaDrag.y0) > dp(6)) or
           lifted():
          agendaDrag.live = true
          ui.dragsActive = true
      if agendaDrag.id == id and agendaDrag.live and ui.mouseDown and
         agendaDrag.item in 0 .. items.high:
        # live: the entry follows the pointer, 15 minutes at a time
        let it = agendaDrag.item
        let k = clamp((ui.mx - body.x) div colW, 0, days - 1)
        let d = fromDayNumber(dn0 + k)
        if agendaDrag.part == 2:
          if d != items[it].day:
            items[it].day = d
            result.moved = true
            result.item = it
        else:
          let m = clamp((ui.my - body.y + sy) * 60 div hourH, 0, 1440)
          if agendaDrag.part == 1:
            let f = clamp((m + 7) div 15 * 15, items[it].start + 15, 1440)
            if f != items[it].finish:
              items[it].finish = f
              result.moved = true
              result.item = it
          else:
            let len = max(15, items[it].finish - items[it].start)
            let s = clamp((m - agendaDrag.grab + 7) div 15 * 15, 0, 1440 - len)
            if s != items[it].start or d != items[it].day:
              items[it].start = s
              items[it].finish = s + len
              items[it].day = d
              result.moved = true
              result.item = it
          if ui.my < body.y + dp(16): sy -= hourH div 4; wakeIn(40)
          elif ui.my > body.y + body.h - dp(16): sy += hourH div 4; wakeIn(40)
      if ui.released and agendaDrag.id == id:
        if not agendaDrag.live:
          if agendaDrag.part == 2:
            let p = pickAllDay(ui.mx, ui.my)
            if p.item >= 0 and p.item == agendaDrag.item:
              result.opened = true
              result.item = p.item
            elif p.k >= 0 and agendaDrag.item < 0 and adHit.clicked:
              day = fromDayNumber(dn0 + p.k)
              result.added = true
              result.addDay = day
              result.addMinute = -1
          else:
            let p = pickTimed(ui.mx, ui.my)
            if p.item >= 0 and p.item == agendaDrag.item:
              result.opened = true
              result.item = p.item
            elif p.k >= 0 and agendaDrag.item < 0 and hit.clicked:
              day = fromDayNumber(dn0 + p.k)
              result.added = true
              result.addDay = day
              result.addMinute = p.minute div 30 * 30
        agendaDrag.id = 0
      if not ui.mouseDown and not ui.released: agendaDrag.id = 0
    scrollTick(id + 41, sy, hiA)
    sy = clamp(sy, 0, max(0, 24 * hourH - body.h))
    # draw: the days' names, the all-day row, the hours
    let head = rect(r.x, r.y, r.w, headH)
    fill(head, th.face)
    hline(head.x, head.y + head.h - 1, head.w, th.edge)
    for k in 0 ..< days:
      let d = fromDayNumber(dn0 + k)
      let s = (if colW > textWidth("Wed 30") + dp(8): dayNamesLong[weekday(d)][0 .. 2] & " " else: "") &
              $d.day
      let isToday = dn0 + k == tdn
      let x = body.x + k * colW
      if isToday: fill(rect(x + 1, head.y + 1, colW - 2, headH - 3), th.select)
      text(x + (colW - textWidth(s, true)) div 2, head.y + (headH - FontH) div 2, s,
           if isToday: th.selectText else: th.text, true)
      if d == day and focused: box(rect(x, head.y, colW, headH), th.select)
    fill(rect(r.x, adR.y, r.w, adH), mixColor(th.field, th.face, 0.3))
    hline(r.x, adR.y + adH - 1, r.w, th.edge)
    text(r.x + dp(4), adR.y + dp(2), "all day", th.gray, smallSt())
    for k in 0 ..< days:
      for j in 0 ..< min(allDay[k].len, adRows):
        let it = allDay[k][j]
        let cr = rect(adR.x + k * colW + dp(2), adR.y + dp(2) + j * (chipH + dp(2)),
                      colW - dp(4), chipH)
        if adRows < allDay[k].len and j == adRows - 1:
          text(cr.x + dp(4), cr.y, "+" & $(allDay[k].len - j) & " more", th.link, smallSt(true))
        else: chip(cr, items[it], agendaDrag.id == id and agendaDrag.item == it)
    # the hours
    let gut = rect(r.x, body.y, gutter, body.h)
    fill(gut, th.face)
    pushClip(rect(r.x, body.y, r.w, body.h))
    let h0 = sy div hourH
    let h1 = min(23, (sy + body.h) div hourH)
    for hh in h0 .. h1:
      let y = body.y + hh * hourH - sy
      hline(body.x, y, colW * days, th.face)
      hline(body.x, y + hourH div 2, colW * days, mixColor(th.field, th.face, 0.45))
      if hh > 0 and y - FontH div 2 >= body.y:
        text(r.x + dp(4), y - FontH div 2, timeText(hh * 60), th.text, smallSt())
    for k in 0 .. days:
      vline(body.x + k * colW, body.y, body.h, th.face)
    for k in 0 ..< days:
      for i in timed[k]:
        let b = blockOf(i, k)
        if b.y + b.h < body.y or b.y > body.y + body.h: continue
        let it = items[i]
        let c = if it.color.a == 0: th.select else: it.color
        let picked = agendaDrag.id == id and agendaDrag.item == i
        fill(b, mixColor(c, th.field, if picked: 0.55 else: 0.75))
        fill(rect(b.x, b.y, dp(3), b.h), c)
        box(b, if picked: th.frame else: mixColor(c, th.field, 0.3))
        pushClip(intersect(inset(b, 1), clipRect()))
        text(b.x + dp(6), b.y + dp(2), it.title, th.fieldText, smallSt(true))
        if b.h > 2 * chipH:
          text(b.x + dp(6), b.y + dp(2) + lineHeight(smallSt()),
               timeText(it.start) & " - " & timeText(it.finish), th.gray, smallSt())
        popClip()
    # now: a red line across today
    let tk = tdn - dn0
    if tk in 0 ..< days:
      let n = times.now()
      let m = times.hour(n) * 60 + times.minute(n)
      let y = body.y - sy + m * hourH div 60
      hline(body.x + tk * colW, y, colW, bad())
      disc(float(body.x + tk * colW), float(y), float(dp(3)), bad())
      wakeIn(30_000)
    popClip()
    scrollBarFor(id + 9, id + 41, rect(r.x + r.w - SbW, body.y, SbW, body.h), true, sy,
                 hiA, max(hourH, body.h - hourH), hourH div 2)
    st.scrollY = sy
  fieldFrame(r)
  state(id) = st
  if accessOn:
    # (the entries of the days shown, as a list: a press opens one)
    let a = case mode
            of amDay: day
            of amWeek: weekStart(day)
            of amMonth: date(day.year, day.month, 1)
    let b = case mode
            of amDay: day
            of amWeek: weekStart(day).addDays(6)
            of amMonth: date(day.year, day.month, daysInMonth(day.year, day.month))
    accessBegin(arList, periodTitle(day, mode), r, id, takesLabel = true)
    var shownN = 0
    for i, it in items:
      if not it.day.valid or dayNumber(it.day) < dayNumber(a) or dayNumber(it.day) > dayNumber(b): continue
      let iid = accessSubId(id, i)
      if accessPress != 0 and accessPress == iid:
        accessPress = 0
        result.opened = true
        result.item = i
      inc shownN
      let at = if it.allDay: "all day"
               else: align($(it.start div 60), 2, '0') & ":" & align($(it.start mod 60), 2, '0') &
                     " - " & align($(it.finish div 60), 2, '0') & ":" & align($(it.finish mod 60), 2, '0')
      accessNode(arListItem, it.title, id = iid, r = r, help = $it.day & ", " & at)
    accessEnd()
  if (day, mode) != before: result.navigated = true
  ui.lastId = id
  ui.lastRect = r

# ---- dashboard tiles ------------------------------------------------------------------------------

proc trendLine(r: Rect; values: openArray[float]; c: Color) =
  if values.len < 2: return
  var lo = values[0]
  var hi = values[0]
  for v in values:
    if v.isNaN: continue
    lo = min(lo, v)
    hi = max(hi, v)
  let span = if hi > lo: hi - lo else: 1.0
  var pts: seq[(float, float)]
  for i, v in values:
    let vv = if v.isNaN: lo else: v
    pts.add (float(r.x) + float(r.w - 1) * float(i) / float(values.high),
             float(r.y + r.h - 2) - float(r.h - 4) * (vv - lo) / span)
  var area = pts
  area.add (float(r.x + r.w - 1), float(r.y + r.h))
  area.add (float(r.x), float(r.y + r.h))
  polygon(area, mixColor(th.field, c, 0.18))
  for i in 1 ..< pts.len:
    thickLine(pts[i - 1][0], pts[i - 1][1], pts[i][0], pts[i][1], max(1.0, float(dp(2)) * 0.75), c)
  disc(pts[^1][0], pts[^1][1], float(dp(2)), c)

proc fitted(s: string; w: int; size: float): TextStyle =
  ## A bold style of `size` (times the text), smaller when `s` does not
  ## fit in `w` (a number is better smaller than cut).
  result = style(bold = true, size = size)
  let tw = textWidth(s, result)
  if tw > w and tw > 0:
    result = style(bold = true, size = max(1.0, size * float(w) / float(tw)))

proc tileCell(w, natural: int): Rect =
  ## The room of a tile: `w` wide (0: all of it), as tall as the tallest
  ## tile of its line (tiles in a `kpiRow` line up).
  result = beginCell(if w > 0: w else: 0, fill = w <= 0)
  let h = max(natural, rowHeight())
  result.h = h
  endCell(result, h, natural)

proc tileFrame(r: Rect; accent: Color; hot, focused: bool) =
  fill(r, if hot: mixColor(th.field, th.select, 0.05) else: th.field)
  hline(r.x + 2, r.y + r.h, r.w - 1, th.shadow)
  vline(r.x + r.w, r.y + 2, r.h - 1, th.shadow)
  box(r, th.edge)
  fill(rect(r.x + 1, r.y + 1, r.w - 2, dp(3)), accent)
  if focused: focusDots(inset(r, 3))

proc kpiTile*(label, value: string; delta = NaN; deltaNote = "";
              lowerIsBetter = false; trend: openArray[float] = [];
              target = NaN; color = Color(); w = 0): bool {.discardable.} =
  ## A number of a dashboard: what it is, the value (big), how it moved
  ## (`delta` a fraction: 0.125 shows "▲ 12.5 %", green when that is good,
  ## red when it is not -- costs and complaints are better lower:
  ## `lowerIsBetter`), with a `deltaNote` ("vs last month"), the `trend`
  ## drawn small and how much of a `target` is reached (0..1). `w`: its width
  ## (0: the room there is; see `kpiRow`). True when clicked (or Enter),
  ## to show what is behind the number.
  let big = style(bold = true, size = 1.9)
  let hasDelta = not delta.isNaN
  var h = dp(12) + FontH + lineHeight(big) + dp(2)
  if hasDelta or deltaNote.len > 0: h += FontH + dp(2)
  if trend.len >= 2: h += dp(28)
  if not target.isNaN: h += dp(16)
  h += dp(8)
  let r = tileCell(w, h)
  let id = idOf("kpi:" & label)
  var hit = interact(id, r)
  spaceKey(id, hit)
  if hit.focused: ui.takesEnter = true   # (as a button: before a default button too)
  if hit.focused and keyHit(KeyEnter): hit.clicked = true
  let accent = if color.a == 0: th.select else: color
  tileFrame(r, accent, hovered(r), hit.focused)
  let x = r.x + dp(10)
  let tw = r.w - dp(20)
  var y = r.y + dp(9)
  text(x, y, ellipsize(label, tw), th.gray)
  y += FontH
  let vs = fitted(value, tw, 1.9)
  text(x, y + (lineHeight(big) - lineHeight(vs)), ellipsize(value, tw, vs), th.fieldText, vs)
  y += lineHeight(big) + dp(2)
  if hasDelta:
    let c = if delta == 0: th.gray elif (delta > 0) != lowerIsBetter: good() else: bad()
    let a = dp(5)
    if delta != 0: arrow(x + a, y + FontH div 2, if delta > 0: dUp else: dDown, c, a)
    let pct = formatNumber(abs(delta) * 100, 1) & " %"
    text(x + 2 * a + dp(4), y, pct, c, true)
    if deltaNote.len > 0:
      let nx = x + 2 * a + dp(10) + textWidth(pct, true)
      text(nx, y, ellipsize(deltaNote, max(0, x + tw - nx)), th.gray)
    y += FontH + dp(2)
  elif deltaNote.len > 0:
    text(x, y, ellipsize(deltaNote, tw), th.gray)
    y += FontH + dp(2)
  if trend.len >= 2:
    trendLine(rect(x, y + dp(3), tw, dp(22)), trend, accent)
    y += dp(28)
  if not target.isNaN:
    let f = clamp(target, 0.0, 1.0)
    let ps = $int(round(clamp(target, 0.0, 9.99) * 100)) & "%"
    let pw = textWidth("100%", smallSt()) + dp(6)
    let b = rect(x, y + dp(5), tw - pw, dp(6))
    fill(b, th.face)
    fill(rect(b.x, b.y, int(float(b.w) * f), b.h), if target >= 1: good() else: accent)
    text(b.x + b.w + dp(6), y + (dp(16) - lineHeight(smallSt())) div 2, ps, th.gray, smallSt())
  if accessOn:
    var more = ""
    if hasDelta: more = (if delta >= 0: "+" else: "") & formatFloat(delta * 100, ffDecimal, 1) & "%"
    if deltaNote.len > 0: more.add (if more.len > 0: " " else: "") & deltaNote
    accessNode(arButton, label & ": " & value, id = id, r = r, help = more)
  ui.lastId = id
  ui.lastRect = r
  hit.clicked

proc statCard*(glyph, label, value: string; detail = ""; color = Color();
               w = 0): bool {.discardable.} =
  ## A tile with an icon (a pixel icon or an icon-font glyph) beside a
  ## label, a value and a line of detail ("12 new today"). True when clicked.
  let big = style(bold = true, size = 1.5)
  let h = dp(14) + FontH + lineHeight(big) + (if detail.len > 0: FontH else: 0) + dp(6)
  let r = tileCell(w, h)
  let id = idOf("stat:" & label)
  var hit = interact(id, r)
  spaceKey(id, hit)
  if hit.focused: ui.takesEnter = true   # (as a button: before a default button too)
  if hit.focused and keyHit(KeyEnter): hit.clicked = true
  let accent = if color.a == 0: th.select else: color
  tileFrame(r, accent, hovered(r), hit.focused)
  let s = min(h - dp(18), dp(44))
  let sq = rect(r.x + dp(10), r.y + (r.h - s) div 2 + dp(1), s, s)
  fill(sq, mixColor(th.field, accent, 0.15))
  let k = max(16, s - dp(12))
  image(sq.x + (s - k) div 2, sq.y + (s - k) div 2, glyphIcon(glyph, accent, k))
  let x = sq.x + s + dp(10)
  let tw = max(10, r.x + r.w - dp(8) - x)
  var y = r.y + dp(8) + (r.h - h) div 2              # (in the middle of a taller tile)
  text(x, y, ellipsize(label, tw), th.gray)
  y += FontH
  let vs = fitted(value, tw, 1.5)
  text(x, y + (lineHeight(big) - lineHeight(vs)), ellipsize(value, tw, vs), th.fieldText, vs)
  y += lineHeight(big)
  if detail.len > 0: text(x, y, ellipsize(detail, tw), th.gray)
  if accessOn: accessNode(arButton, label & ": " & value, id = id, r = r, help = detail)
  ui.lastId = id
  ui.lastRect = r
  hit.clicked

template kpiRow*(minW: int; body: untyped) =
  ## Tiles side by side, as many as fit (each at least `minW` design pixels
  ## wide), wrapping onto more lines on phones.
  adaptive(minW):
    body

template kpiRow*(body: untyped) =
  ## Tiles side by side, as many as fit, wrapping onto more lines on phones.
  adaptive(170):
    body

# ---- the org chart --------------------------------------------------------------------------------

type
  OrgNode* = object
    ## A person (or a unit) of an `orgChart`.
    name*, title*: string  ## who, and their post (shown under the name)
    parent*: int           ## the index of the one above (-1: at the top)
    color*: Color          ## the strip on top of the box (alpha 0: the selection color)
    closed*: bool          ## the ones under it are folded away
  OrgEvent* = object
    ## What happened in an `orgChart` this frame.
    selChanged*: bool      ## `sel` changed
    opened*: bool          ## `node` was double-clicked (or Enter)
    toggled*: bool         ## `node`'s ones under it were folded or unfolded
    node*: int             ## the node the others speak of (an index)
  OrgLayout = object
    stamp: Hash
    kids: seq[seq[int]]
    roots: seq[int]
    pos: seq[tuple[x: float; depth: int]]  ## depth -1: folded away
    slots: float
    depth: int

var orgLayouts: Table[Id, OrgLayout]

proc layoutOrg(nodes: seq[OrgNode]; L: var OrgLayout) =
  ## Places the boxes: leaves side by side, each box over the middle of the
  ## ones under it (loops and parents that are not there: at the top).
  let n = nodes.len
  L.kids = newSeq[seq[int]](n)
  L.roots.setLen(0)
  for i, nd in nodes:
    if nd.parent in 0 ..< n and nd.parent != i: L.kids[nd.parent].add i
    else: L.roots.add i
  L.pos = newSeq[tuple[x: float; depth: int]](n)
  for p in L.pos.mitems: p = (0.0, -1)
  var visited = newSeq[bool](n)
  var next = 0.0
  L.depth = 0
  var stack: seq[tuple[node, depth, k: int]]
  proc run(root: int; L: var OrgLayout; visited: var seq[bool]; next: var float;
           stack: var seq[tuple[node, depth, k: int]]) =
    visited[root] = true
    stack.add (root, 0, 0)
    while stack.len > 0:
      let nd = stack[^1].node
      let depth = stack[^1].depth
      let k = stack[^1].k
      let open = not nodes[nd].closed
      if open and k < L.kids[nd].len:
        inc stack[^1].k
        let c = L.kids[nd][k]
        if not visited[c]:
          visited[c] = true
          stack.add (c, depth + 1, 0)
      else:
        var lo = Inf
        var hi = -Inf
        if open:
          for c in L.kids[nd]:
            if L.pos[c].depth == depth + 1:
              lo = min(lo, L.pos[c].x)
              hi = max(hi, L.pos[c].x)
        if lo > hi:
          L.pos[nd] = (next, depth)
          next += 1.0
        else: L.pos[nd] = ((lo + hi) / 2, depth)
        L.depth = max(L.depth, depth)
        discard stack.pop()
  for r in L.roots:
    if not visited[r]: run(r, L, visited, next, stack)
  for i in 0 ..< n:                       # loops: what no root reaches
    if not visited[i]:
      var j = i
      var steps = 0
      while nodes[j].parent in 0 ..< n and not visited[nodes[j].parent] and steps < n:
        j = nodes[j].parent
        inc steps
      if not visited[j]:
        L.roots.add j
        run(j, L, visited, next, stack)
  L.slots = next

proc orgChart*(nodes: var seq[OrgNode]; sel: var int; height = -1;
               key = ""): OrgEvent {.discardable.} =
  ## Who reports to whom: each node a box (name, title) under the one in
  ## its `parent`, joined by lines; a box with ones under it folds with the
  ## ``[-]`` box at its foot. Click to choose, double-click (or Enter) to open;
  ## Up goes to the one above, Down to the first under, Left and Right to
  ## the ones beside; Space folds. Bigger than its room, it scrolls (the
  ## bars, the wheel -- Shift for sideways --, a finger). `height` in pixels
  ## (-1: the room left).
  result.node = -1
  let h = if height < 0: remainingH() else: height
  let r = place(0, h, fill = true)
  let id = idOf("orgchart:" & key)
  var st = state(id)
  let n = nodes.len
  let oldSel = sel
  sel = if n == 0: -1 else: clamp(sel, 0, n - 1)
  let focused = tabStop(id, r)
  # the layout, made again only when the tree changed
  var stamp: Hash = n
  for nd in nodes: stamp = stamp !& nd.parent !& ord(nd.closed)
  stamp = !$stamp
  let L = addr orgLayouts.mgetOrPut(id, OrgLayout())
  if L.stamp != stamp or L.pos.len != n or n == 0:
    layoutOrg(nodes, L[])
    L.stamp = stamp
  let boxW = dp(150)
  let boxH = FontH * 2 + dp(14)
  let hgap = dp(16)
  let vgap = dp(36)
  let margin = dp(12)
  let cW = int(L.slots) * (boxW + hgap) - hgap + 2 * margin
  let cH = (L.depth + 1) * (boxH + vgap) - vgap + 2 * margin
  var vBar, hBar = false
  for _ in 0 .. 1:
    hBar = cW > r.w - (if vBar: SbW else: 0)
    vBar = cH > r.h - (if hBar: SbW else: 0)
  let view = rect(r.x, r.y, r.w - (if vBar: SbW else: 0), r.h - (if hBar: SbW else: 0))
  var sx = clamp(st.scrollX, 0, max(0, cW - view.w))
  var sy = clamp(st.scrollY, 0, max(0, cH - view.h))
  let ox = view.x + margin - sx + max(0, (view.w - cW) div 2)
  let oy = view.y + margin - sy
  template boxOf(i: int): Rect =
    rect(ox + int(L.pos[i].x * float(boxW + hgap)), oy + L.pos[i].depth * (boxH + vgap),
         boxW, boxH)
  let fb = dp(11)
  template foldOf(i: int): Rect =
    let b = boxOf(i)
    rect(b.x + (b.w - fb) div 2, b.y + b.h - fb div 2, fb, fb)
  var follow = false
  let hit = interact(id + 1, view, focusable = false)
  if canInput():
    if tapped(id + 1, hit):
      ui.focus = id
      for i in 0 ..< n:
        if L.pos[i].depth < 0: continue
        if L.kids[i].len > 0 and foldOf(i).contains(point(ui.mx, ui.my)):
          nodes[i].closed = not nodes[i].closed
          result.toggled = true
          result.node = i
          break
        if boxOf(i).contains(point(ui.mx, ui.my)):
          sel = i
          if ui.clicks >= 2:
            result.opened = true
            result.node = i
            markDouble(id)
          break
    # (scrollers: id + 61 up and down, id + 62 sideways)
    scrollWheel(id + 62, sx, max(0, cW - view.w), view, dp(60), sideways = true)
    scrollWheel(id + 61, sy, max(0, cH - view.h), view, 3 * FontH)
    if mouseIn(view) and ui.wheel != 0 and not ui.wheelUsed: ui.wheelUsed = true
    scrollPan2(id + 61, sy, max(0, cH - view.h), id + 62, sx, max(0, cW - view.w), view)
  if focused and canInput() and not ui.keyUsed and sel >= 0:
    let p = nodes[sel].parent
    let sibs = if p in 0 ..< n and p != sel: L.kids[p] else: L.roots
    let at = sibs.find(sel)
    case ui.key
    of KeyUp:
      if p in 0 ..< n and p != sel: sel = p
      ui.keyUsed = true
    of KeyDown:
      if L.kids[sel].len > 0:
        if nodes[sel].closed:
          nodes[sel].closed = false
          result.toggled = true
          result.node = sel
        sel = L.kids[sel][0]
      ui.keyUsed = true
    of KeyLeft:
      if at > 0: sel = sibs[at - 1]
      ui.keyUsed = true
    of KeyRight:
      if at >= 0 and at < sibs.high: sel = sibs[at + 1]
      ui.keyUsed = true
    of KeySpace:
      if L.kids[sel].len > 0:
        nodes[sel].closed = not nodes[sel].closed
        result.toggled = true
        result.node = sel
      ui.keyUsed = true
    of KeyEnter:
      result.opened = true
      result.node = sel
      ui.keyUsed = true
    else: discard
    follow = ui.keyUsed
  if result.toggled: ui.redraw = true
  if follow and sel >= 0 and L.pos[sel].depth >= 0:
    let b = boxOf(sel)                     # (on the chart: + sx, + sy)
    let bx = b.x - view.x + sx
    let by = b.y - view.y + sy
    scrollShow(id + 62, sx, bx - margin, bx + b.w + margin, view.w, max(0, cW - view.w))
    scrollShow(id + 61, sy, by - margin, by + b.h + margin, view.h, max(0, cH - view.h))
  scrollTick(id + 61, sy, max(0, cH - view.h))
  scrollTick(id + 62, sx, max(0, cW - view.w))
  sx = clamp(sx, 0, max(0, cW - view.w))
  sy = clamp(sy, 0, max(0, cH - view.h))
  # draw: the lines first, then the boxes in view
  fill(view, th.window)
  pushClip(view)
  let lineC = mixColor(th.text, th.window, 0.45)
  for i in 0 ..< n:
    if L.pos[i].depth < 0 or nodes[i].closed or L.kids[i].len == 0: continue
    let b = boxOf(i)
    let midY = b.y + b.h + vgap div 2
    var lo = high(int)
    var hi = low(int)
    for c in L.kids[i]:
      if L.pos[c].depth != L.pos[i].depth + 1: continue
      let cb = boxOf(c)
      lo = min(lo, cb.x + cb.w div 2)
      hi = max(hi, cb.x + cb.w div 2)
    if lo > hi: continue
    if hi < view.x or lo > view.x + view.w or midY - vgap > view.y + view.h or
       midY + vgap < view.y: continue
    vline(b.x + b.w div 2, b.y + b.h, midY - b.y - b.h, lineC)
    hline(lo, midY, hi - lo + 1, lineC)
    for c in L.kids[i]:
      if L.pos[c].depth != L.pos[i].depth + 1: continue
      let cb = boxOf(c)
      vline(cb.x + cb.w div 2, midY, cb.y - midY, lineC)
  for i in 0 ..< n:
    if L.pos[i].depth < 0: continue
    let b = boxOf(i)
    if b.x + b.w + 2 < view.x or b.x > view.x + view.w or b.y + b.h + fb < view.y or
       b.y > view.y + view.h: continue
    let isSel = i == sel
    fill(b, th.field)
    hline(b.x + 2, b.y + b.h, b.w - 1, th.shadow)
    vline(b.x + b.w, b.y + 2, b.h - 1, th.shadow)
    box(b, if isSel: th.select else: th.edge)
    if isSel: box(inset(b, 1), th.select)
    let c = if nodes[i].color.a == 0: th.select else: nodes[i].color
    fill(rect(b.x + 2, b.y + 2, b.w - 4, dp(3)), c)
    let tw = b.w - dp(12)
    text(b.x + (b.w - min(tw, textWidth(nodes[i].name, true))) div 2, b.y + dp(7),
         ellipsize(nodes[i].name, tw, style(bold = true)), th.fieldText, true)
    text(b.x + (b.w - min(tw, textWidth(nodes[i].title))) div 2, b.y + dp(7) + FontH,
         ellipsize(nodes[i].title, tw), th.gray)
    if isSel and focused: dots(inset(b, 3), th.text)
    if L.kids[i].len > 0: foldBox(foldOf(i), not nodes[i].closed)
  popClip()
  if n == 0:
    let s = "Nobody here yet"
    text(view.x + (view.w - textWidth(s)) div 2, view.y + dp(12), s, th.gray)
  if vBar:
    scrollBarFor(id + 9, id + 61, rect(r.x + r.w - SbW, r.y, SbW, view.h), true, sy,
                 max(0, cH - view.h), max(FontH, view.h - boxH), FontH)
  if hBar:
    scrollBarFor(id + 15, id + 62, rect(r.x, r.y + r.h - SbW, view.w, SbW), false, sx,
                 max(0, cW - view.w), max(FontH, view.w - boxW), FontH)
  if vBar and hBar: fill(rect(r.x + r.w - SbW, r.y + r.h - SbW, SbW, SbW), th.face)
  fieldFrame(r)
  if sx != st.scrollX or sy != st.scrollY: ui.redraw = true
  st.scrollX = sx
  st.scrollY = sy
  state(id) = st
  if accessOn:
    # (a tree of the people: each under the one above, at its depth)
    accessBegin(arTree, "", r, id, takesLabel = true)
    for i in 0 ..< n:
      let nid = accessSubId(id, i)
      if accessPress != 0 and accessPress == nid:
        accessPress = 0
        sel = i
        ui.focus = id
      var kids = false
      for j in 0 ..< n:
        if nodes[j].parent == i: kids = true
      let k = accessNode(arTreeItem, nodes[i].name, id = nid, r = r,
                         states = (if i == sel: {asSelected} else: {}) +
                                  (if kids: {asExpandable} else: {}) +
                                  (if kids and not nodes[i].closed: {asExpanded} else: {}),
                         help = nodes[i].title)
      var depth = 0
      var up = nodes[i].parent
      while up >= 0 and up < n and depth < n:
        inc depth
        up = nodes[up].parent
      accessItem(k, i + 1, n, depth + 1)
      if i == sel and focused: accessFocus(k)
    accessEnd()
  if sel != oldSel: result.selChanged = true
  ui.lastId = id
  ui.lastRect = r

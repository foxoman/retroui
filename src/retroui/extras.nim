## More widgets: icons, search box, switch, segmented buttons, expander,
## card, chips, badges, star rating, busy spinner, toasts, color and time
## pickers, a fast line viewer for big texts (logs, hex dumps), settings
## rows, avatars, steps, banners, pages, a bottom navigation bar, a
## floating action button, sparklines, progress rings, empty and busy
## states, and label / value lists.

import std/[strutils, math, tables]
import std/unicode except strip   # (its strip cuts letters: docs/nim-bugs.md)
import uirelays/target   # (androidApp: an APK, not a program in Termux)
import core, widgets, business, platform, nerdicons, pixelicons
import uirelays/input

template th: untyped = ui.theme

proc orText(c: Color): Color {.inline.} =
  if c.a == 0: th.text else: c

# ---- icons and labels ------------------------------------------------------------------

proc icon*(glyph: string; color = Color(); size = 1.0): Rect {.discardable.} =
  ## An icon of the icon font (`nfStar`...) as a widget, `size` times the
  ## text size; returns where it is.
  let st = style(size = size)
  result = place(textWidth(glyph, st), lineHeight(st))
  ui.lastId = 0
  ui.lastRect = result
  text(result.x, result.y, glyph, orText(color), st)

proc iconLabel*(glyph, s: string; color = Color(); iconColor = Color();
                bold = false) =
  ## An icon followed by a label: `iconLabel(nfFolder, "Documents")`.
  let gw = textWidth(glyph)
  let tw = labelWidth(s, bold)
  let r = place(gw + dp(6) + tw, FontH)
  ui.lastId = 0
  ui.lastRect = r
  text(r.x, r.y, glyph, if iconColor.a == 0: orText(color) else: iconColor)
  drawLabel(r.x + gw + dp(6), r.y, s, orText(color), bold)

proc heading*(s: string; level = 1; color = Color()) =
  ## A title in large bold text (level 1 largest .. 4).
  let size = case level
    of 1: 1.6
    of 2: 1.35
    of 3: 1.15
    else: 1.0
  let st = style(bold = true, size = size)
  let s = tr(s)
  let r = place(textWidth(s, st), lineHeight(st))
  ui.lastId = 0
  ui.lastRect = r
  text(r.x, r.y, s, orText(color), st)

proc styledText*(s: string; st: TextStyle; color = Color()) =
  ## One line of text in any style (`style(italic = true, size = 1.2)`).
  let r = place(textWidth(s, st), lineHeight(st))
  ui.lastId = 0
  ui.lastRect = r
  text(r.x, r.y, s, orText(color), st)

# ---- search box ------------------------------------------------------------------------

proc searchBox*(s: var string; placeholder = "Search"; w = 0;
                enabled = true): bool {.discardable.} =
  ## A text box with a magnifier and a clear button; true when the text
  ## changed. Esc clears it.
  let r = place(if w > 0: w else: 0, EditH, fill = w <= 0)
  let id = idOf(s, "search")
  let iw = r.h
  let cw = if s.len > 0: r.h else: 0
  fill(r, th.field)
  fieldFrame(r, enabled)
  let glass = retroOr(pxSearch, nfSearch)
  let gw = textWidth(glass)
  text(r.x + (iw - gw) div 2, r.y + (r.h - FontH) div 2, glass, th.gray)
  let er = rect(r.x + iw - 4, r.y, r.w - iw + 4 - cw, r.h)
  if accessOn: accessNameOr(tr(placeholder))
  result = editAt(id, s, er, false, false, enabled, frameless = true)
  fieldFrame(r, enabled)
  if s.len == 0:
    pushClip(inset(er, 1))
    text(er.x + 3, r.y + (r.h - FontH) div 2, tr(placeholder), th.gray)
    popClip()
  if cw > 0:
    let cr = rect(r.x + r.w - cw, r.y, cw, r.h)
    let hit = interact(id + 5, cr, focusable = false, enabled = enabled)
    if accessOn: accessNode(arButton, "Clear", id = id + 5, r = cr, states = accessOff(enabled))
    let xw = textWidth(nfTimesCircle)
    text(cr.x + (cw - xw) div 2, cr.y + (cr.h - FontH) div 2, nfTimesCircle,
         if hit.showsHover: th.text else: th.gray)
    if hit.clicked or (ui.focus == id and keyHit(KeyEsc)):
      s = ""
      ui.focus = id
      result = true

# ---- switch, segmented buttons --------------------------------------------------------

proc switchSize*(): tuple[w, h: int] =
  ## The size of a switch's slot (bigger on touch screens).
  let h = if fingers(): dp(24) else: max(dp(16), FontH + 1)
  (h * 2 + h div 3, h)

proc drawSwitch*(track: Rect; on, enabled: bool; down = false; thumbX = -1) =
  ## A slide switch in the manner of Windows 3.1: a black-edged slot, navy
  ## on the "on" side with the IEC "I", white with the "O" when off, and a
  ## raised gray thumb with grip lines (at `thumbX` while it is slid).
  let inner = inset(track, 1)
  let tw = inner.w div 2
  let tx = if thumbX >= 0: clamp(thumbX, inner.x, inner.x + inner.w - tw)
           elif on: inner.x + inner.w - tw else: inner.x
  # the slot: navy left of the thumb (the "on" part), white right of it
  let onW = tx - inner.x
  fill(rect(inner.x, inner.y, onW, inner.h), if enabled: th.select else: th.face)
  fill(rect(tx + tw, inner.y, inner.x + inner.w - tx - tw, inner.h),
       if enabled: th.field else: th.face)
  box(track, if enabled: th.frame else: th.gray)
  # the symbols: "I" on the navy part, "O" on the white part
  let sh = max(4, inner.h * 9 div 20)
  if onW >= tw div 2:
    let cx = inner.x + onW div 2
    fill(rect(cx - max(1, inner.h div 14), inner.y + (inner.h - sh) div 2,
              max(2, inner.h div 7), sh), if enabled: th.selectText else: th.gray)
  let offW = inner.x + inner.w - tx - tw
  if offW >= tw div 2:
    let cx = float(tx + tw) + offW / 2
    let cy = float(inner.y) + inner.h / 2
    ring(cx, cy, sh / 2, max(1.2, inner.h / 12), if enabled: th.shadow else: th.gray)
  # the thumb: a raised 3.1 button with three grip lines
  let t = rect(tx, inner.y, tw, inner.h)
  fill(t, th.face)
  if tx > inner.x: vline(t.x, t.y, t.h, th.frame)
  if tx + tw < inner.x + inner.w: vline(t.x + t.w - 1, t.y, t.h, th.frame)
  let b = rect(t.x + (if tx > inner.x: 1 else: 0), t.y,
               t.w - (if tx > inner.x: 1 else: 0) - (if tx + tw < inner.x + inner.w: 1 else: 0), t.h)
  let o = if down: 1 else: 0
  if down:
    hline(b.x, b.y, b.w, th.shadow)
    vline(b.x, b.y, b.h, th.shadow)
  else:
    raised(b, if b.h >= dp(20): 2 else: 1)
  let gh = max(3, b.h * 2 div 5)
  let gx = b.x + b.w div 2 - 3 + o
  let gy = b.y + (b.h - gh) div 2 + o
  for k in 0 .. 2:
    vline(gx + k * 3, gy, gh, if enabled: th.shadow else: th.gray)
    vline(gx + k * 3 + 1, gy, gh, th.light)

proc switchAt*(id: Id; track: Rect; v: var bool; hit: var Hit;
               enabled = true): bool =
  ## The behavior of a slide switch at `track` (`hit`: the interaction of
  ## the widget it is part of, which may be bigger): a click or a tap flips
  ## it, the thumb can be slid with the mouse or a finger, Space flips it,
  ## Left / Right turn it off / on. Draws it; true when it changed.
  var st = state(id + 7)
  let inner = inset(track, 1)
  let tw = inner.w div 2
  let lo = inner.x
  let hi = inner.x + inner.w - tw
  var thumbX = -1
  if enabled and canInput():
    # a press on the slot: the switch takes the drag (not the page)
    if ui.pressed and ui.active == id and mouseIn(track):
      ui.dragsActive = true
      st.aux = 1                                   # pressed on the slot
      st.aux2 = ui.mx
      let cur = if v: hi else: lo
      st.scrollX = if ui.mx >= cur and ui.mx < cur + tw: ui.mx - cur else: tw div 2
      st.anchor = 0                                # not slid yet
    if st.aux == 1 and ui.active == id and ui.mouseDown:
      if abs(ui.mx - st.aux2) > dp(3): st.anchor = 1
      if st.anchor == 1: thumbX = clamp(ui.mx - st.scrollX, lo, hi)
    if st.aux == 1 and ui.released:
      if st.anchor == 1:
        let nv = clamp(ui.mx - st.scrollX, lo, hi) + tw div 2 > inner.x + inner.w div 2
        if nv != v:
          v = nv
          result = true
        hit.clicked = false                        # slid: that was not a click
      st.aux = 0
      st.anchor = 0
    elif st.aux == 1 and not ui.mouseDown:
      st.aux = 0
      st.anchor = 0
    if hit.clicked:
      v = not v
      result = true
    if hit.focused and not ui.keyUsed:
      if ui.key == KeyLeft and v:
        v = false
        result = true
        ui.keyUsed = true
      elif ui.key == KeyRight and not v:
        v = true
        result = true
        ui.keyUsed = true
  state(id + 7) = st
  drawSwitch(track, v, enabled, hit.down and thumbX < 0, thumbX)
  if thumbX >= 0: wakeIn(16)

proc toggle*(label: string; v: var bool; enabled = true): bool {.discardable.} =
  ## An on/off slide switch with a label; true when flipped. Click, tap or
  ## slide it; Space, Left and Right with the focus; Alt + its letter.
  let id = idOf(v, label)
  let (sw, sh) = switchSize()
  let lw = labelWidth(label)
  let gap = if label.len > 0: dp(8) else: 0
  let r = place(sw + gap + lw, if fingers(): max(CtrlH, sh + 4) else: max(sh + 4, FontH))
  var hit = interact(id, r, enabled = enabled)
  if enabled:
    spaceKey(id, hit)
    if mnemonicHit(label): hit.clicked = true
  let track = rect(r.x, r.y + (r.h - sh) div 2, sw, sh)
  result = switchAt(id, track, v, hit, enabled)
  let ty = r.y + (r.h - FontH) div 2
  if label.len > 0:
    drawLabel(r.x + sw + gap, ty, label, if enabled: th.text else: th.gray)
    if hit.focused: focusDots(rect(r.x + sw + gap - 2, ty - 1, lw + 4, FontH + 2))
  elif hit.focused:
    focusDots(inset(track, -2))
  if accessOn:
    accessNode(arCheckBox, label, id = id, r = r,
               states = accessOff(enabled) + (if v: {asChecked} else: {}))
  ui.lastId = id
  ui.lastRect = r

proc segmented*(options: openArray[string]; sel: var int; w = 0;
                enabled = true): bool {.discardable.} =
  ## Buttons joined in a row, one of them pressed in: a choice of a few.
  ## A click or a tap picks one; Left, Right, Home and End move the choice;
  ## Alt + a letter picks that one.
  var widths: seq[int]
  var total = 0
  for o in options:
    widths.add labelWidth(o) + dp(20)
    total += widths[^1]
  let r = place(if w > 0: w else: total, CtrlH)
  if w > 0 and total > 0:
    var given = 0
    for i in 0 ..< widths.len:
      widths[i] = if i == widths.high: r.w - given else: widths[i] * r.w div total
      given += widths[i]
  let id = idOf(sel, "segmented")
  var hit = interact(id, r, enabled = enabled)
  if accessPress != 0 and enabled:
    # (a screen reader picked one)
    for i in 0 ..< options.len:
      if accessPress == accessSubId(id, i):
        accessPress = 0
        ui.focus = id
        if sel != i:
          sel = i
          result = true
  if hit.focused and enabled and canInput():
    if keyHit(KeyLeft) and sel > 0:
      dec sel
      result = true
    elif keyHit(KeyRight) and sel < options.high:
      inc sel
      result = true
    elif keyHit(KeyHome) and sel != 0:
      sel = 0
      result = true
    elif keyHit(KeyEnd) and sel != options.high:
      sel = options.high
      result = true
  var x = r.x
  for i, o in options:
    let br = rect(x, r.y, widths[i] + (if i < options.high: 1 else: 0), r.h)
    let down = i == sel
    if enabled and hit.clicked and br.contains(point(ui.mx, ui.my)) and sel != i:
      sel = i
      result = true
    buttonFace(br, down, rounded = i == 0 or i == options.high, bevel = 1)
    if down:
      fill(inset(br, 2), th.light)
    let tw = labelWidth(o, down)
    let o1 = if down: 1 else: 0
    drawLabel(br.x + (br.w - tw) div 2 + o1, br.y + (br.h - FontH) div 2 + o1, o,
              if enabled: th.text else: th.gray, down)
    if mnemonicHit(o) and enabled:
      sel = i
      result = true
    x += widths[i]
  if hit.focused: focusDots(inset(r, 3))
  if accessOn:
    # (a group of options, the one pressed in checked)
    accessBegin(arGroup, "", r, id, accessOff(enabled), takesLabel = true)
    var ax = r.x
    for i, o in options:
      let k = accessNode(arRadioButton, o, id = accessSubId(id, i),
                         r = rect(ax, r.y, widths[i], r.h),
                         states = accessOff(enabled) + (if i == sel: {asChecked} else: {}))
      accessItem(k, i + 1, options.len)
      if i == sel and hit.focused: accessFocus(k)
      ax += widths[i]
    accessEnd()

# ---- expander, card ---------------------------------------------------------------------

proc beginExpander*(label: string; open: var bool): bool =
  ## A header that folds the widgets under it away; true when open.
  let id = idOf(open, label)
  let r = place(0, ItemH + dp(4), fill = true)
  var hit = interact(id, r)
  spaceKey(id, hit)
  if hit.clicked or mnemonicHit(label): open = not open
  if hit.focused and canInput():
    if keyHit(KeyRight): open = true
    elif keyHit(KeyLeft): open = false
  if hit.showsHover: fill(r, th.face)
  hline(r.x, r.y + r.h - 1, r.w, th.line)
  let a = dp(5)
  arrow(r.x + a + 2, r.y + r.h div 2, if open: dDown else: dRight, th.text)
  let ty = r.y + (r.h - FontH) div 2
  drawLabel(r.x + 2 * a + dp(8), ty, label, th.text, true)
  if hit.focused:
    focusDots(rect(r.x + 2 * a + dp(6), ty - 1, labelWidth(label, true) + 4, FontH + 2))
  if accessOn:
    accessNode(arButton, label, id = id, r = r,
               states = {asExpandable} + (if open: {asExpanded} else: {}))
  if open:
    beginCol()
    space(dp(2))
  open

proc endExpander*() =
  ## Ends the content of an open `beginExpander`.
  endCol()

template expander*(label: string; open: var bool; body: untyped) =
  ## A section that opens and closes (click its header, or Left/Right).
  if beginExpander(label, open):
    body
    endExpander()

var cardStack: seq[tuple[cell: Rect; fillAt: int; title: string; minH: int]]

proc beginCard*(title = "") =
  ## A panel holding widgets, drawn as a Windows 3.1 group box: a frame
  ## with its title set into the top line.
  let cell = beginCell(0, fill = true)
  let minH = rowHeight()
  let titleH = if title.len > 0: FontH + dp(2) else: 0
  cardStack.add (cell, reserveFill(), title, minH)
  pushFrame(rect(cell.x + Pad + 2, cell.y + Pad + 2 + titleH,
                 cell.w - 2 * Pad - 4, 0), reserve = Pad + 2, inPage = true)

proc endCard*() =
  ## Ends a `beginCard`: draws its frame around what was placed in it.
  let h = popFrame()
  let (cell, fillAt, title, minH) = cardStack.pop()
  let titleH = if title.len > 0: FontH + dp(2) else: 0
  let natural = h + 2 * Pad + 4 + titleH
  let r = rect(cell.x, cell.y, cell.w, max(natural, minH))
  patchFill(fillAt, r, th.window)
  let top = if title.len > 0: FontH div 2 else: 0
  etchedBox(rect(r.x, r.y + top, r.w, r.h - top))
  if title.len > 0:
    let tw = labelWidth(title, true)
    fill(r.x + dp(8), r.y, tw + dp(8), FontH, th.window)
    drawLabel(r.x + dp(12), r.y, title, th.text, true)
  endCell(r, r.h, natural)

template card*(title: string; body: untyped) =
  ## A panel drawn as a 3.1 group box (its title set into the top line);
  ## in an `adaptive` row, cards make a dashboard that reflows from one
  ## column (phone) to several.
  ##
  ## .. code-block:: nim
  ##   adaptive(260):
  ##     card "Sales": label "12,400"
  ##     card "Orders": label "318"
  beginCard(title)
  body
  endCard()

# ---- chips, badges ------------------------------------------------------------------------

type ChipEvent* = object
  ## What happened in a row of `chips` this frame.
  clicked*: int        ## the chip clicked, or -1
  closed*: int         ## the chip whose x was clicked, or -1

proc chips*(items: openArray[string]; selected: openArray[bool] = [];
            closable = false; enabled = true): ChipEvent {.discardable.} =
  ## Rounded tags in a row that wraps: filters, labels, recipients. One
  ## stop for Tab: Left / Right move between them, Space or Enter clicks
  ## one, Delete closes it (`closable`).
  result = ChipEvent(clicked: -1, closed: -1)
  let h = FontH + dp(8)
  let gid = makeId(fnv("chip-row"))
  var st = state(gid)
  let focused = enabled and ui.focus == gid and canInput()
  if items.len > 0: st.caret = clamp(st.caret, 0, items.high)
  if focused and items.len > 0 and not ui.keyUsed:
    case ui.key
    of KeyLeft: st.caret = max(0, st.caret - 1); ui.keyUsed = true
    of KeyRight: st.caret = min(items.high, st.caret + 1); ui.keyUsed = true
    of KeyHome: st.caret = 0; ui.keyUsed = true
    of KeyEnd: st.caret = items.high; ui.keyUsed = true
    of KeySpace, KeyEnter:
      result.clicked = st.caret
      ui.keyUsed = true
    of KeyDelete, KeyBackspace:
      if closable:
        result.closed = st.caret
        ui.keyUsed = true
    else: discard
  var area = rect(0, 0, 0, 0)
  if accessOn: accessBegin(arList, "", rect(0, 0, 0, 0), gid, accessOff(enabled), takesLabel = true)
  beginRow([], h)
  for i, s in items:
    let on = i < selected.len and selected[i]
    let tw = textWidth(s)
    let xw = if closable: textWidth(nfTimes) + dp(6) else: 0
    let r = place(tw + dp(20) + xw, h)
    area = if area.w == 0: r else: union(area, r)
    let id = idOf("chip:" & s & $i)
    let hit = interact(id, r, focusable = false, enabled = enabled)
    if hit.down and ui.pressed:
      ui.focus = gid
      st.caret = i
    let bg = if on: th.select elif hit.showsHover: th.face else: th.window
    roundRect(r, h / 2, if on: th.select else: th.shadow)
    roundRect(inset(r, 1), (h - 2) / 2, bg)
    let fg = if on: th.selectText elif enabled: th.text else: th.gray
    text(r.x + dp(10), r.y + (h - FontH) div 2, s, fg)
    if ui.focus == gid and i == st.caret and not ui.touch:
      focusDots(rect(r.x + dp(7), r.y + (h - FontH) div 2 - 1, tw + 6, FontH + 2))
    if accessOn:
      let k = accessNode(if i < selected.len: arToggleButton else: arButton, s, id = id, r = r,
                         states = accessOff(enabled) + (if on: {asPressed, asChecked} else: {}))
      accessItem(k, i + 1, items.len)
      if ui.focus == gid and i == st.caret: accessFocus(k)
    if closable:
      let xr = rect(r.x + r.w - xw - dp(6), r.y, xw + dp(6), h)
      text(xr.x, r.y + (h - FontH) div 2, nfTimes,
           if mouseIn(xr) and canInput() and canHover(): th.text else: th.gray)
      if accessOn:
        if accessPress != 0 and accessPress == accessSubId(id, 1) and enabled:
          accessPress = 0
          result.closed = i
        accessNode(arButton, "Remove " & s, id = accessSubId(id, 1), r = xr,
                   states = accessOff(enabled))
      if hit.clicked and xr.contains(point(ui.mx, ui.my)) and accessPressed != id:
        result.closed = i
        continue
    if hit.clicked: result.clicked = i
  endRow()
  if accessOn: accessEnd(area)
  state(gid) = st
  if enabled and items.len > 0: discard tabStop(gid, area)

proc badge*(s: string; bg = color(200, 0, 0); fg = color(255, 255, 255)) =
  ## A small rounded count or status label ("3", "NEW").
  let st = style(bold = true, size = 0.85)
  let tw = textWidth(s, st)
  let h = lineHeight(st) + dp(2)
  let r = place(max(h, tw + dp(10)), h)
  ui.lastId = 0
  ui.lastRect = r
  roundRect(r, h / 2, bg)
  text(r.x + (r.w - tw) div 2, r.y + (h - lineHeight(st)) div 2, s, fg, st)

proc rating*(v: var int; stars = 5; enabled = true): bool {.discardable.} =
  ## Stars to click or tap, 0..`stars`; clicking the current one clears it.
  ## With the focus: Left / Right one star less / more, Home none, End all.
  let st = style(size = 1.3)
  let sw = textWidth(nfStar, st) + dp(2)
  # (a finger's height: the stars in its middle)
  let r = place(sw * stars, max(lineHeight(st), if fingers(): dp(30) else: 0))
  let sy = r.y + (r.h - lineHeight(st)) div 2
  let id = idOf(v, "rating")
  var hit = interact(id, r, enabled = enabled)
  if accessOn and enabled and accessValueFor(id):
    let nv = clamp(int(round(accessSet.num)), 0, stars)
    if nv != v:
      v = nv
      result = true
  if accessPressed == id: hit.clicked = false   # (pressed by a screen reader: no star under it)
  let at = if hit.hover and enabled: clamp((ui.mx - r.x) div sw + 1, 1, stars) else: 0
  let over = if canHover(): at else: 0           # (the stars under the mouse light up)
  if hit.clicked and at > 0:
    v = if v == at: 0 else: at
    result = true
  if hit.focused and enabled:
    if keyHit(KeyRight) and v < stars: inc v; result = true
    elif keyHit(KeyLeft) and v > 0: dec v; result = true
    elif keyHit(KeyHome) and v != 0: v = 0; result = true
    elif keyHit(KeyEnd) and v != stars: v = stars; result = true
  let gold = color(230, 170, 0)
  for i in 0 ..< stars:
    let lit = if over > 0: i < over else: i < v
    text(r.x + i * sw, sy, if lit: nfStar else: nfStarO,
         if not enabled: th.gray elif lit: gold else: th.shadow, st)
  if hit.focused: focusDots(r)
  if accessOn:
    accessNameOr(tr("Rating"))
    let k = accessNode(arSlider, value = $v & " / " & $stars, id = id, r = r,
                       states = accessOff(enabled))
    accessRange(k, 0, float(stars), float(v))

# ---- spinner, toasts ---------------------------------------------------------------------

proc drawSpinner*(cx, cy, d: int; color = Color()) =
  ## The busy dots of `spinner`, `d` pixels across, centered at `cx`, `cy`
  ## (for drawing them inside your own widgets). With `retroIcons` it is
  ## the hourglass of the early 1990s, its sand running.
  if retroIcons:
    let g = if (ui.now div 600) mod 2 == 0: pxHourglass else: pxHourglass2
    pixelIconAt(rect(cx - d div 2, cy - d div 2, d, d), g)
    wakeIn(600 - ui.now mod 600)
    return
  let c = if color.a == 0: th.select else: color
  let n = 10
  let step = (ui.now div 90) mod n
  let rad = d / 2 - d / 8
  for i in 0 ..< n:
    let a = 2 * PI * float(i) / float(n) - PI / 2
    let k = 1.0 - ((step - i + n) mod n) / n
    disc(float(cx) + rad * cos(a), float(cy) + rad * sin(a), d / 10 + d / 30 * k,
         mixColor(th.window, c, k))
  wakeIn(90 - ui.now mod 90)

proc spinner*(size = 0; color = Color()) =
  ## A busy indicator: dots going round (animates by itself).
  let d = if size > 0: size else: FontH + dp(4)
  let r = place(d, d)
  ui.lastId = 0
  ui.lastRect = r
  drawSpinner(r.x + d div 2, r.y + d div 2, d, color)

var
  toastMsg: string
  toastTitle: string
  toastUntil: int
  toastIcon: string
  toastRect: Rect

proc toast*(msg: string; ms = 3500; glyph = ""; title = "") =
  ## A notification in the style of the Windows 95 / 98 balloons: pale
  ## yellow, a black border, a tail pointing at the corner, an optional
  ## icon and bold `title`. It goes away by itself (or when clicked).
  toastMsg = tr(msg)
  toastTitle = tr(title)
  toastIcon = glyph
  toastUntil = ui.now + ms
  ui.redraw = true

proc dismissToast*() =
  ## Closes the balloon (`toast`) now.
  toastMsg = ""
  ui.redraw = true

proc toastShown*(): bool = toastMsg.len > 0
  ## A balloon (`toast`) is on screen.

proc toastArea*(): Rect = toastRect
  ## Where the balloon was drawn last (empty before the first one).

proc toastClick() {.nimcall.} =
  # a click on the balloon closes it (and reaches nothing under it)
  if toastMsg.len > 0 and ui.pressed and not ui.pressUsed and
     toastRect.contains(point(ui.mx, ui.my)):
    ui.pressUsed = true
    dismissToast()

proc drawToast() {.nimcall.} =
  if toastMsg.len == 0: return
  if ui.now >= toastUntil:
    toastMsg = ""
    ui.redraw = true
    return
  pushLayer(LayerTip)
  let pad = dp(8)
  let gw = if toastIcon.len > 0: textWidth(toastIcon, style(size = 1.3)) + dp(8) else: 0
  let xw = dp(14)                                   # the close box
  let maxText = min(dp(300), ui.w - dp(40)) - gw - xw - 2 * pad
  let lines = wrapLines(toastMsg, maxText)
  var tw = if toastTitle.len > 0: textWidth(toastTitle, true) else: 0
  for l in lines: tw = max(tw, textWidth(l))
  let w = gw + tw + xw + 2 * pad + dp(4)
  let h = (lines.len + (if toastTitle.len > 0: 1 else: 0)) * FontH + 2 * pad
  let tail = dp(12)
  let x = max(dp(4), ui.w - ui.safe.right - w - dp(10))
  let y = max(dp(4), ui.bottom - h - tail - dp(2))
  let r = rect(x, y, w, h)
  toastRect = rect(r.x, r.y, r.w, r.h + tail)
  let bg = ui.theme.tip
  let fg = ui.theme.tipText
  # the balloon and its tail, pointing down at the corner
  roundRect(r, float(dp(7)), fg)
  roundRect(inset(r, 1), float(dp(6)), bg)
  let tx = r.x + r.w - dp(36)
  polygon([(float(tx), float(r.y + r.h - 1)), (float(tx + dp(16)), float(r.y + r.h - 1)),
           (float(tx + dp(22)), float(r.y + r.h + tail))], fg)
  polygon([(float(tx + 1), float(r.y + r.h - 2)), (float(tx + dp(15)), float(r.y + r.h - 2)),
           (float(tx + dp(20)), float(r.y + r.h + tail - dp(3)))], bg)
  var ty = r.y + pad
  if toastIcon.len > 0:
    let ic = style(size = 1.3)
    text(r.x + pad, ty, toastIcon, color(0, 70, 200), ic)
  let lx = r.x + pad + gw
  if toastTitle.len > 0:
    text(lx, ty, toastTitle, fg, true)
    ty += FontH
  for l in lines:
    text(lx, ty, l, fg)
    ty += FontH
  # the little close box
  let cb = rect(r.x + r.w - xw - dp(5), r.y + dp(5), xw, xw)
  box(cb, fg)
  let m = dp(4)
  thickLine(float(cb.x + m), float(cb.y + m), float(cb.x + cb.w - m), float(cb.y + cb.h - m), 1.3, fg)
  thickLine(float(cb.x + cb.w - m), float(cb.y + m), float(cb.x + m), float(cb.y + cb.h - m), 1.3, fg)
  popLayer()
  wakeIn(toastUntil - ui.now)

beginFrameHooks.add toastClick
endFrameHooks.add drawToast

# ---- color and time ---------------------------------------------------------------------------

const basicColors* = [
  color(255, 128, 128), color(255, 255, 128), color(128, 255, 128), color(0, 255, 128),
  color(128, 255, 255), color(0, 128, 255), color(255, 128, 192), color(255, 128, 255),
  color(255, 0, 0), color(255, 255, 0), color(128, 255, 0), color(0, 255, 64),
  color(0, 255, 255), color(0, 128, 192), color(128, 128, 192), color(255, 0, 255),
  color(128, 64, 64), color(255, 128, 64), color(0, 255, 0), color(0, 128, 128),
  color(0, 64, 128), color(128, 128, 255), color(128, 0, 64), color(255, 0, 128),
  color(128, 0, 0), color(255, 128, 0), color(0, 128, 0), color(0, 128, 64),
  color(0, 0, 255), color(0, 0, 160), color(128, 0, 128), color(128, 0, 255),
  color(64, 0, 0), color(128, 64, 0), color(0, 64, 0), color(0, 64, 64),
  color(0, 0, 128), color(0, 0, 64), color(64, 0, 64), color(64, 0, 128),
  color(0, 0, 0), color(128, 128, 0), color(128, 128, 64), color(128, 128, 128),
  color(64, 128, 128), color(192, 192, 192), color(64, 0, 64), color(255, 255, 255)]
  ## The 48 "Basic colors" of the 3.1 color dialog.

proc hexOf*(c: Color): string =
  ## "#RRGGBB" of `c`.
  "#" & toHex(int(c.r), 2) & toHex(int(c.g), 2) & toHex(int(c.b), 2)

proc parseHexColor*(s: string; c: var Color): bool =
  ## "#RRGGBB" or "RRGGBB" (or "#RGB") into `c`.
  var t = s.strip()
  if t.startsWith("#"): t = t[1 .. ^1]
  if t.len == 3: t = t[0] & t[0] & t[1] & t[1] & t[2] & t[2]
  if t.len != 6: return false
  try:
    c = color(uint8(parseHexInt(t[0 .. 1])), uint8(parseHexInt(t[2 .. 3])),
              uint8(parseHexInt(t[4 .. 5])))
    true
  except ValueError: false

proc colorPicker*(c: var Color; enabled = true): bool {.discardable.} =
  ## The 48 basic colors of the 3.1 color dialog to pick from (a click, a
  ## tap, or the arrow keys with the focus), a preview and a "#RRGGBB" box
  ## to type any color in. True when `c` changed.
  let cell = max(dp(18), FontH + 4)
  let cols = 8
  let r = place(cols * cell + 2, 6 * cell + 2)
  let id = idOf(c, "colors")
  let hit = interact(id, r, enabled = enabled)
  if accessPress != 0 and enabled:
    for i, k in basicColors:
      if accessPress == accessSubId(id, i):
        accessPress = 0
        ui.focus = id
        if c != k:
          c = k
          result = true
  if hit.focused and enabled and canInput() and not ui.keyUsed and
     ui.key in {KeyLeft, KeyRight, KeyUp, KeyDown, KeyHome, KeyEnd}:
    var at = max(0, basicColors.find(c))
    case ui.key
    of KeyLeft: at = max(0, at - 1)
    of KeyRight: at = min(basicColors.high, at + 1)
    of KeyUp: at = if at >= cols: at - cols else: at
    of KeyDown: at = if at + cols <= basicColors.high: at + cols else: at
    of KeyHome: at = 0
    else: at = basicColors.high
    ui.keyUsed = true
    if basicColors[at] != c:
      c = basicColors[at]
      result = true
  sunken(r)
  for i, k in basicColors:
    let cr = rect(r.x + 1 + (i mod cols) * cell, r.y + 1 + (i div cols) * cell,
                  cell, cell)
    fill(inset(cr, 2), k)
    box(inset(cr, 2), th.frame)
    if k == c:
      box(inset(cr, 0), th.text)
      box(inset(cr, 1), th.window)
      if hit.focused: dots(inset(cr, -1), th.text)
    if hit.clicked and cr.contains(point(ui.mx, ui.my)) and c != k:
      c = k
      result = true
  if accessOn:
    accessBegin(arList, "", r, id, accessOff(enabled), takesLabel = true)
    for i, k in basicColors:
      let n = accessNode(arListItem, hexOf(k), id = accessSubId(id, i),
                         r = rect(r.x + 1 + (i mod cols) * cell, r.y + 1 + (i div cols) * cell, cell, cell),
                         states = (if k == c: {asSelected} else: {}))
      accessItem(n, i + 1, basicColors.len)
      if k == c and hit.focused: accessFocus(n)
    accessEnd()
  row:
    let pv = place(cell * 2, EditH)
    fill(pv, c)
    box(pv, th.frame)
    var hex = hexOf(c)
    let st = addr state(id + 3)
    if ui.focus != id + 4: st.buf = hex
    var buf = st.buf
    let er = place(textWidth("#WWWWWW") + dp(12), EditH)
    if accessOn: accessName("#RRGGBB")
    if editAt(id + 4, buf, er, false, false, enabled):
      var nc: Color
      if parseHexColor(buf, nc) and nc != c:
        c = nc
        result = true
    state(id + 3).buf = buf
  ui.lastId = id
  ui.lastRect = r

# ---- the Color dialog, opened out, and color wells ---------------------------------------------

var customColors*: array[16, Color] = [
  color(255, 255, 255), color(255, 255, 255), color(255, 255, 255), color(255, 255, 255),
  color(255, 255, 255), color(255, 255, 255), color(255, 255, 255), color(255, 255, 255),
  color(255, 255, 255), color(255, 255, 255), color(255, 255, 255), color(255, 255, 255),
  color(255, 255, 255), color(255, 255, 255), color(255, 255, 255), color(255, 255, 255)]
  ## The "Custom colors" of the Color dialog (white until defined; keep them
  ## with `storeCustomColors`).

proc toHsl*(c: Color): tuple[h, s, l: float] =
  ## Hue 0..360, saturation and luminosity 0..1.
  let r = c.r.float / 255
  let g = c.g.float / 255
  let b = c.b.float / 255
  let mx = max(r, max(g, b))
  let mn = min(r, min(g, b))
  result.l = (mx + mn) / 2
  let d = mx - mn
  if d < 1e-9: return
  result.s = if result.l > 0.5: d / (2 - mx - mn) else: d / (mx + mn)
  var h = if mx == r: (g - b) / d + (if g < b: 6.0 else: 0.0)
          elif mx == g: (b - r) / d + 2
          else: (r - g) / d + 4
  result.h = h * 60

proc fromHsl*(h, s, l: float): Color =
  ## The color of hue `h` (0..360), saturation and luminosity `s`, `l` (0..1).
  proc hue(p, q, t0: float): float =
    var t = t0
    if t < 0: t += 1
    if t > 1: t -= 1
    if t < 1 / 6: p + (q - p) * 6 * t
    elif t < 1 / 2: q
    elif t < 2 / 3: p + (q - p) * (2 / 3 - t) * 6
    else: p
  let s = clamp(s, 0.0, 1.0)
  let l = clamp(l, 0.0, 1.0)
  if s <= 0:
    let v = uint8(round(l * 255))
    return color(v, v, v)
  let q = if l < 0.5: l * (1 + s) else: l + s - l * s
  let p = 2 * l - q
  let hh = (h mod 360) / 360
  color(uint8(round(hue(p, q, hh + 1 / 3) * 255)), uint8(round(hue(p, q, hh) * 255)),
        uint8(round(hue(p, q, hh - 1 / 3) * 255)))

var cdlg: tuple[open: bool; key, title: string; c, was: Color; h, s, l: float; done: bool;
                spectrum: Bitmap; specKey: string; custom: int]
  ## (the one Color dialog: whose well opened it, the color being made)

proc setDialogColor(c: Color) =
  let hsl = toHsl(c)
  if hsl.s > 0: cdlg.h = hsl.h
  cdlg.s = hsl.s
  cdlg.l = hsl.l
  cdlg.c = c

proc openColorDialog*(key: string; c: Color; title = "Color") =
  ## Opens the Color dialog for `key` at color `c`; `colorDialogResult(key)`
  ## gives the color chosen (`colorWell` does both).
  cdlg.open = true
  cdlg.key = key
  cdlg.title = title
  cdlg.was = c
  cdlg.done = false
  setDialogColor(c)

proc colorDialogResult*(key: string; c: var Color): bool =
  ## True once, after OK in the Color dialog opened for `key`: `c` is set.
  if cdlg.done and cdlg.key == key:
    cdlg.done = false
    c = cdlg.c
    return true

proc colorDialogBody() =
  ## (the dialog, drawn at the end of the frame -- over everything)
  if not cdlg.open: return
  var open = true
  dialog(open, cdlg.title, 600):
    let cell = max(dp(18), FontH + 4)
    rowPx([8 * cell + dp(6), -1]):
      col:
        label "&Basic colors:"
        let br = place(8 * cell + 2, 6 * cell + 2)
        sunken(br)
        for i, k in basicColors:
          let cr = rect(br.x + 1 + (i mod 8) * cell, br.y + 1 + (i div 8) * cell, cell, cell)
          fill(inset(cr, 2), k)
          box(inset(cr, 2), th.frame)
          if k == cdlg.c: box(cr, th.text)
          if interact(idOf("cdbasic" & $i), cr, focusable = false).clicked: setDialogColor(k)
        space(dp(6))
        label "&Custom colors:"
        let cr0 = place(8 * cell + 2, 2 * cell + 2)
        sunken(cr0)
        for i, k in customColors:
          let cr = rect(cr0.x + 1 + (i mod 8) * cell, cr0.y + 1 + (i div 8) * cell, cell, cell)
          fill(inset(cr, 2), k)
          box(inset(cr, 2), th.frame)
          if i == cdlg.custom: dots(inset(cr, 1), th.text)
          if interact(idOf("cdcustom" & $i), cr, focusable = false).clicked:
            cdlg.custom = i
            setDialogColor(k)
      col:
        # the spectrum: hue across, saturation up (at middle luminosity), and
        # the luminosity strip of the color beside it
        let sw = max(dp(160), available() - dp(28))
        let sh = 6 * cell
        let row0 = place(sw + dp(26), sh)
        let sr = rect(row0.x, row0.y, sw, sh)
        let lr = rect(sr.x + sw + dp(8), sr.y, dp(14), sh)
        let key = $sw & "x" & $sh & "@" & $pxScale
        if cdlg.specKey != key or cdlg.spectrum == nil:
          let bw = sw * pxScale
          let bh = sh * pxScale
          cdlg.spectrum = newBitmap(bw, bh)
          for y in 0 ..< bh:
            for x in 0 ..< bw:
              let c = fromHsl(x / max(1, bw - 1) * 360, 1 - y / max(1, bh - 1), 0.5)
              cdlg.spectrum.px[y * bw + x] = 0xFF000000'u32 or (uint32(c.r) shl 16) or
                                             (uint32(c.g) shl 8) or uint32(c.b)
          cdlg.spectrum.changed()
          cdlg.specKey = key
        drawBitmap(sr, cdlg.spectrum)
        box(inset(sr, -1), th.frame)
        let sid = idOf("cdspectrum")
        let sh2 = interact(sid, sr, focusable = false)
        if (sh2.down or ui.active == sid) and ui.mouseDown:
          ui.dragsActive = true
          cdlg.h = clamp((ui.mx - sr.x) / max(1, sr.w - 1), 0.0, 1.0) * 360
          cdlg.s = clamp(1 - (ui.my - sr.y) / max(1, sr.h - 1), 0.0, 1.0)
          if cdlg.l <= 0.02 or cdlg.l >= 0.98: cdlg.l = 0.5
          cdlg.c = fromHsl(cdlg.h, cdlg.s, cdlg.l)
        let cx = sr.x + int(cdlg.h / 360 * (sr.w - 1).float)
        let cy = sr.y + int((1 - cdlg.s) * (sr.h - 1).float)
        for (dx, dy) in [(-6, 0), (3, 0)]:
          hline(cx + dx, cy, 4, color(0, 0, 0))
        for (dx, dy) in [(0, -6), (0, 3)]:
          vline(cx, cy + dy, 4, color(0, 0, 0))
        for y in 0 ..< lr.h:
          hline(lr.x, lr.y + y, lr.w, fromHsl(cdlg.h, cdlg.s, 1 - y / max(1, lr.h - 1)))
        box(inset(lr, -1), th.frame)
        let lid = idOf("cdlum")
        let lh = interact(lid, rect(lr.x, lr.y, lr.w + dp(10), lr.h), focusable = false)
        if (lh.down or ui.active == lid) and ui.mouseDown:
          ui.dragsActive = true
          cdlg.l = clamp(1 - (ui.my - lr.y) / max(1, lr.h - 1), 0.0, 1.0)
          cdlg.c = fromHsl(cdlg.h, cdlg.s, cdlg.l)
        let ay = lr.y + int((1 - cdlg.l) * (lr.h - 1).float)
        arrow(lr.x + lr.w + dp(6), ay, dLeft, th.text)
        space(dp(6))
        row:
          # Color|Solid: the new color over the one the well had
          let pv = place(dp(64), 2 * EditH)
          fill(rect(pv.x, pv.y, pv.w, pv.h div 2), cdlg.c)
          fill(rect(pv.x, pv.y + pv.h div 2, pv.w, pv.h - pv.h div 2), cdlg.was)
          box(pv, th.frame)
          col:
            var h = int(round(cdlg.h * 239 / 360))
            var sat = int(round(cdlg.s * 240))
            var lum = int(round(cdlg.l * 240))
            var r = int(cdlg.c.r)
            var g = int(cdlg.c.g)
            var b = int(cdlg.c.b)
            row([30, 52, 36, 52]):
              label "&Hue:"
              if intEdit(h, w = dp(52), lo = 0, hi = 239):
                cdlg.h = h / 239 * 360
                cdlg.c = fromHsl(cdlg.h, cdlg.s, cdlg.l)
              label "&Red:"
              if intEdit(r, w = dp(52), lo = 0, hi = 255): setDialogColor(color(uint8(r), cdlg.c.g, cdlg.c.b))
            row([30, 52, 36, 52]):
              label "&Sat:"
              if intEdit(sat, w = dp(52), lo = 0, hi = 240):
                cdlg.s = sat / 240
                cdlg.c = fromHsl(cdlg.h, cdlg.s, cdlg.l)
              label "&Green:"
              if intEdit(g, w = dp(52), lo = 0, hi = 255): setDialogColor(color(cdlg.c.r, uint8(g), cdlg.c.b))
            row([30, 52, 36, 52]):
              label "&Lum:"
              if intEdit(lum, w = dp(52), lo = 0, hi = 240):
                cdlg.l = lum / 240
                cdlg.c = fromHsl(cdlg.h, cdlg.s, cdlg.l)
              label "Bl&ue:"
              if intEdit(b, w = dp(52), lo = 0, hi = 255): setDialogColor(color(cdlg.c.r, cdlg.c.g, uint8(b)))
        row:
          label "He&x:"
          var hex = hexOf(cdlg.c)
          let st = addr state(idOf("cdhexbuf"))
          if ui.focus != idOf("cdhex"): st.buf = hex
          var buf = st.buf
          let er = place(textWidth("#WWWWWW") + dp(12), EditH)
          if editAt(idOf("cdhex"), buf, er, false, false, true):
            var nc: Color
            if parseHexColor(buf, nc): setDialogColor(nc)
          state(idOf("cdhexbuf")).buf = buf
          if button("&Add to Custom Colors", w = dp(170)):
            customColors[cdlg.custom] = cdlg.c
            cdlg.custom = (cdlg.custom + 1) mod customColors.len
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)):
        cdlg.done = true
        open = false
      if button("Cancel", w = dp(80)): open = false
  if not open: cdlg.open = false

endFrameHooks.add colorDialogBody

proc colorWell*(c: var Color; key: string; w = 0; title = "Color"; enabled = true): bool {.discardable.} =
  ## A swatch of `c` in a sunken frame: a click (Enter, Space) opens the
  ## Color dialog -- the basic and custom colors, the spectrum, Hue / Sat /
  ## Lum, Red / Green / Blue, "#RRGGBB" -- and OK sets `c` (true then).
  ## Use one wherever a color is chosen; `key` tells the wells apart.
  let r = place(if w > 0: w else: dp(40), EditH)
  # (one id for the well, its keys and its node: a label's second `idOf` in
  # a frame is another id)
  let wid = idOf("colorwell:" & key)
  var hit = interact(wid, r, enabled = enabled)
  if enabled: spaceKey(wid, hit)
  if hit.focused: ui.takesEnter = true     # (as a button: a default button leaves Enter to it)
  if hit.focused and keyHit(KeyEnter): hit.clicked = true
  sunken(r)
  fill(inset(r, 2), if enabled: c else: mixColor(c, th.face, 0.6))
  box(inset(r, 2), th.frame)
  if hit.focused: dots(inset(r, -1), th.text)
  if accessOn:
    accessNameOr(tr(title))
    accessNode(arButton, "", id = wid, r = r, states = accessOff(enabled),
               help = hexOf(c))
  if hit.clicked and enabled: openColorDialog(key, c, title)
  if colorDialogResult(key, c): result = true

proc storeCustomColors*(s: var Settings) =
  ## The custom colors into the settings (`restoreCustomColors` reads them).
  var parts: seq[string]
  for c in customColors: parts.add hexOf(c)
  s["colors.custom"] = parts.join(",")

proc restoreCustomColors*(s: Settings) =
  ## The custom colors as `storeCustomColors` kept them.
  let parts = s.getOrDefault("colors.custom", "").split(',')
  for i, p in parts:
    if i > customColors.high: break
    var c: Color
    if parseHexColor(p, c): customColors[i] = c

proc timePicker*(h, m: var int; enabled = true): bool {.discardable.} =
  ## Hours (0..23) and minutes as two spin boxes.
  row:
    accessName(tr("Hours"))
    if spin(h, 0, 23, w = dp(64), enabled = enabled): result = true
    label ":"
    accessName(tr("Minutes"))
    if spin(m, 0, 59, w = dp(64), enabled = enabled): result = true

# ---- the line viewer ------------------------------------------------------------------------

type LineViewEvent* = object
  ## What happened in a `lineView` this frame.
  activated*: bool     ## double click or Enter on `sel`
  copied*: bool        ## Ctrl+C copied the selected lines

proc lineView*(count: int; line: proc (i: int): string; sel: var int;
               height = -1; w = 0; mono = true; numbers = false;
               wrap = false): LineViewEvent {.discardable.} =
  ## A fast read-only view of `count` lines (only the visible ones are asked
  ## for): logs, big text files, hex dumps. A click (or the arrows) selects
  ## a line, Shift or a mouse drag extends, Ctrl+A all, Ctrl+C copies them.
  ## The wheel scrolls (Shift + the wheel sideways), a finger drags. `wrap`
  ## is off: long lines scroll sideways.
  let st0 = style(mono = mono)
  let lh = lineHeight(st0) + (if fingers(): dp(6) else: 1)
  let r = place(if w > 0: w else: 0, if height < 0: remainingH() else: height,
                fill = w <= 0)
  let id = idOf(sel, "lines")
  var st = state(id)
  var hit = interact(id, r)
  let gutter = if numbers: textWidth($max(1, count), st0) + dp(18) else: 0
  let barV = SbW
  let barH = if wrap: 0 else: SbW
  let body = rect(r.x + 1, r.y + 1, r.w - 2 - barV + 1, r.h - 2 - barH + 1)
  let vis = max(1, body.h div lh)
  let maxOff = max(0, count * lh - body.h)      # (scrolled by the pixel)
  var off = clamp(st.scrollY, 0, maxOff)
  let sxId = id + 26                            # (the sideways scroller)
  let maxX = if wrap: 0 else: max(0, st.aux - (body.w - gutter) + dp(16))
  var sx = clamp(st.scrollX, 0, maxX)
  scrollWheel(sxId, sx, maxX, r, dp(40), sideways = true)   # Shift + the wheel
  scrollWheel(id, off, maxOff, r, 3 * lh)
  scrollPan2(id, off, maxOff, sxId, sx, maxX, r)
  # selection: anchor in st.anchor
  if hit.focused and canInput() and count > 0:
    let shift = ShiftPressed in ui.mods
    let ctrl = CtrlPressed in ui.mods
    var ns = sel
    case ui.key
    of KeyUp: ns = sel - 1
    of KeyDown: ns = sel + 1
    of KeyPageUp: ns = sel - vis
    of KeyPageDown: ns = sel + vis
    of KeyHome: ns = 0
    of KeyEnd: ns = count - 1
    of KeyEnter:
      result.activated = true
      ui.keyUsed = true
    of KeyA:
      if ctrl:
        st.anchor = 0
        sel = count - 1
        ui.keyUsed = true
    of KeyC:
      if ctrl:
        var t = ""
        for i in min(sel, st.anchor) .. max(sel, st.anchor):
          if i >= 0 and i < count:
            t.add line(i)
            t.add '\n'
        putClipboardText(t)
        result.copied = true
        ui.keyUsed = true
    of KeyLeft:
      if not wrap: scrollBy(sxId, sx, -dp(40), maxX); ui.keyUsed = true
    of KeyRight:
      if not wrap: scrollBy(sxId, sx, dp(40), maxX); ui.keyUsed = true
    else: discard
    if ns != sel and ui.key in {KeyUp, KeyDown, KeyPageUp, KeyPageDown, KeyHome, KeyEnd}:
      ui.keyUsed = true
      sel = clamp(ns, 0, count - 1)
      if not shift: st.anchor = sel
      scrollShow(id, off, sel * lh, (sel + 1) * lh, body.h, maxOff)
  if accessPress != 0:
    # (a screen reader picked a line)
    for i in off div lh ..< min(count, off div lh + vis + 2):
      if accessPress == accessSubId(id, i):
        accessPress = 0
        sel = i
        st.anchor = i
        ui.focus = id
        break
  if hit.focused and tapped(id, hit) and mouseIn(body):
    let i = (ui.my - body.y + off) div lh
    if i < count:
      sel = i
      if ShiftPressed notin ui.mods: st.anchor = i
  elif not finger() and ui.active == id and ui.mouseDown and count > 0:
    # the mouse dragged over lines: they are selected (scrolling at the edges)
    let my = ui.my - body.y
    if my < 0 and off > 0:
      scrollStop(id)
      off = max(0, off - max(2, lh div 3))
      wakeIn(16)
    elif my >= body.h and off < maxOff:
      scrollStop(id)
      off = min(maxOff, off + max(2, lh div 3))
      wakeIn(16)
    sel = clamp((clamp(my, 0, body.h - 1) + off) div lh, 0, count - 1)
  if canInput() and ui.pressed and ui.clicks >= 2 and mouseIn(body):
    result.activated = true
  scrollTick(id, off, maxOff)
  scrollTick(sxId, sx, maxX)
  off = clamp(off, 0, maxOff)
  sx = clamp(sx, 0, maxX)
  scrollBarFor(id + 9, id, rect(r.x + r.w - SbW, r.y, SbW, r.h - barH + (if barH > 0: 1 else: 0)),
               true, off, maxOff, max(lh, body.h - lh), lh)
  if barH > 0:
    scrollBarFor(id + 15, sxId, rect(r.x, r.y + r.h - SbW, r.w - SbW + 1, SbW),
                 false, sx, maxX, max(10, body.w div 2), dp(40))
  # draw
  fill(body, th.field)
  fieldFrame(r)
  pushClip(body)
  if gutter > 0:
    fill(rect(body.x, body.y, gutter - dp(4), body.h), th.face)
  let a = min(sel, st.anchor)
  let b = max(sel, st.anchor)
  var widest = 0
  let top = off div lh
  for k in 0 .. vis + 1:
    let i = top + k
    if i >= count: break
    let y = body.y + i * lh - off
    let s = line(i)
    let selected = i >= a and i <= b and count > 0
    if selected:
      fill(rect(body.x + gutter, y, body.w - gutter, lh),
           if hit.focused: th.select else: th.face)
    if gutter > 0:
      let n = $(i + 1)
      text(body.x + gutter - dp(8) - textWidth(n, st0), y + (lh - FontH) div 2, n,
           th.gray, st0)
    pushClip(rect(body.x + gutter, y, body.w - gutter, lh))
    let tw = textWidth(s, st0)
    widest = max(widest, tw)
    text(body.x + gutter + dp(4) - sx, y + (lh - lineHeight(st0)) div 2, s,
         if selected and hit.focused: th.selectText else: th.fieldText, st0)
    popClip()
  popClip()
  if hit.focused: dots(inset(r, 1), th.text)
  if accessOn:
    # (a list of the lines in view)
    accessBegin(arList, "", r, id, takesLabel = true)
    for k in 0 .. vis + 1:
      let i = top + k
      if i >= count: break
      let n = accessNode(arListItem, line(i), id = accessSubId(id, i),
                         r = rect(body.x, body.y + i * lh - off, body.w, lh),
                         states = (if i >= a and i <= b: {asSelected} else: {}))
      accessItem(n, i + 1, count)
      if i == sel and hit.focused: accessFocus(n)
    accessEnd()
  if widest > st.aux: st.aux = widest
  if off != st.scrollY or sx != st.scrollX:
    st.scrollY = off
    st.scrollX = sx
    ui.redraw = true
  state(id) = st
  ui.lastId = id
  ui.lastRect = r

# ---- empty and busy states, facts -------------------------------------------------------------

proc emptyState*(glyph, msg: string; h = -1; detail = "") =
  ## A framed area with a large glyph and a message ("This folder is
  ## empty", "No results"); `h` -1: the room left.
  let r = canvas(0, if h < 0: remainingH() else: h)
  fill(r, th.field)
  fieldFrame(r)
  let st = style(size = 3.0)
  let gh = lineHeight(st)
  let lines = wrapLines(tr(msg), r.w - dp(16))
  let more = if detail.len > 0: wrapLines(tr(detail), r.w - dp(16)) else: @[]
  let showGlyph = glyph.len > 0 and r.h > gh + FontH * (lines.len + more.len + 1)
  var y = r.y + (r.h - (if showGlyph: gh else: 0) - FontH * (lines.len + more.len)) div 2
  if showGlyph:
    text(r.x + (r.w - textWidth(glyph, st)) div 2, y, glyph, th.face, st)
    y += gh
  for line in lines:
    text(r.x + (r.w - textWidth(line)) div 2, y, line, th.text)
    y += FontH
  for line in more:
    text(r.x + (r.w - textWidth(line)) div 2, y, line, th.gray)
    y += FontH

proc busyState*(msg: string; h = -1) =
  ## A framed area with busy dots and a message ("Loading...").
  let r = canvas(0, if h < 0: remainingH() else: h)
  fill(r, th.field)
  fieldFrame(r)
  let d = FontH * 2
  drawSpinner(r.x + r.w div 2, r.y + r.h div 2 - d div 2, d)
  let line = ellipsize(tr(msg), r.w - dp(16))
  text(r.x + (r.w - textWidth(line)) div 2, r.y + r.h div 2 + d div 2 + dp(6), line, th.gray)

proc drawFacts*(x, y, w: int; facts: openArray[(string, string)];
                bottom = high(int)): int =
  ## "Size:  4.5 KB" lines (labels gray, values wrapped) drawn from `x`, `y`,
  ## `w` wide, stopping above `bottom`; returns the y under them. The
  ## labels are translated (`setUiLanguage`), the values are not.
  var lw = 0
  for (k, _) in facts: lw = max(lw, textWidth(tr(k) & ":"))
  lw = min(lw, w div 2)
  var y = y
  for (k, v) in facts:
    if y + FontH > bottom: break
    text(x, y, tr(k) & ":", th.gray)
    var vy = y
    # a label too long for the label column (a narrow card): the value
    # goes under it
    if textWidth(tr(k) & ":") > lw: vy += FontH
    for line in wrapLines(v, max(dp(40), w - lw - dp(8))):
      if vy + FontH > bottom: break
      text(x + lw + dp(8), vy, line, th.fieldText)
      vy += FontH
    y = max(y + FontH, vy) + dp(2)
  y

proc factList*(facts: openArray[(string, string)]; w = 0) =
  ## Label / value lines as a widget: `factList({"Size": "4.5 KB",
  ## "Modified": "today"})`; long values wrap under themselves.
  let width = if w > 0: w else: available()
  var lw = 0
  for (k, _) in facts: lw = max(lw, textWidth(tr(k) & ":"))
  lw = min(lw, width div 2)
  var h = 0
  for (k, v) in facts:
    h += max(1, wrapLines(v, max(dp(40), width - lw - dp(8))).len) * FontH + dp(2)
    if textWidth(tr(k) & ":") > lw: h += FontH
  let r = place(width, h)
  ui.lastId = 0
  ui.lastRect = r
  discard drawFacts(r.x, r.y, r.w, facts)

# ---- settings rows ------------------------------------------------------------------------------

proc settingRow(title, detail: string; controlW: int; stack: var bool):
    tuple[r, ctl: Rect; textW: int] =
  ## The cell of a settings row: the title and its detail at the left, the
  ## control at the right (or under them, when the row is narrow).
  let w = available()
  stack = controlW > w * 11 div 20
  let textW = if stack: w - dp(16) else: w - controlW - dp(24)
  let st = style(size = 0.9)
  let lines = if detail.len > 0: wrapLines(tr(detail), textW) else: @[]
  let textH = FontH + lines.len * lineHeight(st)
  let minH = if fingers(): dp(52) else: dp(36)
  let h = if stack: textH + CtrlH + dp(20) else: max(minH, max(textH, CtrlH) + dp(14))
  let r = place(0, h, fill = true)
  ui.lastRect = r
  var y = if stack: r.y + dp(6) else: r.y + (r.h - textH) div 2
  drawLabel(r.x + dp(8), y, title, th.text)
  if accessOn:
    accessLabelFor(title)
    if detail.len > 0: accessNode(arLabel, tr(detail), id = 0, r = rect(r.x, y + FontH, textW, h - FontH))
  y += FontH
  for line in lines:
    text(r.x + dp(8), y, line, th.gray, st)
    y += lineHeight(st)
  let ctl = if stack: rect(r.x + dp(8), r.y + r.h - CtrlH - dp(8), r.w - dp(16), CtrlH)
            else: rect(r.x + r.w - controlW - dp(8), r.y + (r.h - CtrlH) div 2, controlW, CtrlH)
  (r, ctl, textW)

proc settingToggle*(title: string; v: var bool; detail = "";
                    enabled = true): bool {.discardable.} =
  ## A settings row: a title, a line or two of detail, and a switch at the
  ## right; a click anywhere on the row flips it. True when it changed.
  var stack = false
  let (sw, sh) = switchSize()
  let (r, ctl, _) = settingRow(title, detail, sw, stack)
  let id = idOf(v, title)
  var hit = interact(id, r, enabled = enabled)
  if enabled:
    spaceKey(id, hit)
    if mnemonicHit(title): hit.clicked = true
  let track = rect(r.x + r.w - sw - dp(8), r.y + (r.h - sh) div 2, sw, sh)
  discard ctl
  result = switchAt(id, track, v, hit, enabled)
  if hit.focused: focusDots(inset(r, 2))
  if accessOn:
    accessNode(arCheckBox, title, id = id, r = r,
               states = accessOff(enabled) + (if v: {asChecked} else: {}), help = tr(detail))
  ui.lastId = id
  ui.lastRect = r

proc settingChoice*(title: string; options: openArray[string]; v: var int;
                    detail = ""; enabled = true): bool {.discardable.} =
  ## A settings row with a choice of a few (segmented buttons), under the
  ## title when the row is narrow.
  var widths = 0
  for o in options: widths += labelWidth(o) + dp(20)
  var stack = false
  let (r, ctl, _) = settingRow(title, detail, widths, stack)
  pushFrame(rect(ctl.x, ctl.y, ctl.w, 0))
  result = segmented(options, v, w = (if stack: ctl.w else: widths), enabled = enabled)
  discard popFrame()
  ui.lastRect = r

proc settingCombo*(title: string; options: openArray[string]; v: var int;
                   detail = ""; enabled = true): bool {.discardable.} =
  ## A settings row with a drop-down list at the right (a choice of many).
  var widest = 0
  for o in options: widest = max(widest, labelWidth(o))
  let cw = widest + SbW + dp(20)
  var stack = false
  let (r, ctl, _) = settingRow(title, detail, cw, stack)
  pushFrame(rect(ctl.x, ctl.y, ctl.w, 0))
  result = combo(options, v, w = (if stack: ctl.w else: cw), enabled = enabled)
  discard popFrame()
  ui.lastRect = r

proc settingSlider*(title: string; v: var int; lo, hi: int; detail = "";
                    suffix = ""; enabled = true): bool {.discardable.} =
  ## A settings row with a slider and its value ("120%").
  var stack = false
  let vw = textWidth($hi & suffix) + dp(8)
  let (r, ctl, _) = settingRow(title, detail, dp(200) + vw, stack)
  pushFrame(rect(ctl.x, ctl.y, ctl.w, 0))
  row:
    result = slider(v, lo, hi, w = ctl.w - vw - Gap, ticks = 0, enabled = enabled)
    label $v & suffix
  discard popFrame()
  ui.lastRect = r

proc settingButtons*(title: string; buttons: openArray[string]; detail = "";
                     enabled = true): int =
  ## A settings row with buttons (`["Smaller", "Normal", "Larger"]`);
  ## which was clicked (1-based), 0 if none.
  var widths = 0
  for b in buttons: widths += max(dp(56), labelWidth(b) + dp(20)) + Gap
  var stack = false
  let (r, ctl, _) = settingRow(title, detail, widths, stack)
  pushFrame(rect(ctl.x, ctl.y, ctl.w, 0))
  row:
    if not stack: spring()
    for i, b in buttons:
      if button(b, enabled = enabled, w = max(dp(56), labelWidth(b) + dp(20))):
        result = i + 1
  discard popFrame()
  ui.lastRect = r

proc settingLink*(title: string; detail = ""; glyph = nfChevronRight;
                  enabled = true): bool =
  ## A settings row that leads somewhere (another page, a dialog): true
  ## when clicked.
  var stack = false
  let gw = textWidth(glyph) + dp(8)
  let (r, ctl, _) = settingRow(title, detail, gw, stack)
  let id = idOf("settinglink:" & title)
  var hit = interact(id, r, enabled = enabled)
  if enabled:
    spaceKey(id, hit)
    if mnemonicHit(title): hit.clicked = true
  text(ctl.x + ctl.w - gw, r.y + (r.h - FontH) div 2, glyph, th.gray)
  if hit.focused: focusDots(inset(r, 2))
  if accessOn:
    accessNode(arButton, title, id = id, r = r, states = accessOff(enabled), help = tr(detail))
  hit.clicked

var
  fontFileOpen = false
  fontFilePath = ""
  fontFileError = ""

proc extractFilenameOf(p: string): string =
  var i = p.len - 1
  while i >= 0 and p[i] notin {'/', '\\'}: dec i
  p[i + 1 .. ^1]

proc appearanceRows(): bool

proc appearanceSettings*(): bool {.discardable.} =
  ## Settings rows for how every app looks: the color scheme, the size of
  ## everything, the size of the text, the size of controls (for a mouse
  ## or fingers), the window's frame (on desktops: the system's or Windows
  ## 3.1's), the title bars' buttons (`captionButtons`) and the font. True
  ## when something changed (store them with
  ## `storeAppearance`; `app`'s `look` keeps them by itself).
  result = appearanceRows()
  if result: noteLookChanged()

proc appearanceRows(): bool =
  var t = max(0, themeIndex())
  var names: seq[string]
  for th in builtinThemes: names.add th.name
  if settingCombo("Color scheme", names, t):
    ui.theme = builtinThemes[t].theme
    invalidate()
    result = true
  case settingButtons("Size of everything", ["Smaller", "Normal", "Larger"],
                      $uiScale() & "%")
  of 1: setUiScale(scaleStep(-1)); result = true
  of 2: setUiScale(100); result = true
  of 3: setUiScale(scaleStep(1)); result = true
  else: discard
  var cs = ord(controlSizes())
  if settingCombo("Controls", ["Automatic (touch sizes on phones)", "Desktop sizes (mouse, pen)",
                               "Touch sizes (fingers)"], cs):
    setControlSizes(ControlSizes(cs))
    result = true
  if canClassicFrame() and userFrameChoice:
    # (the window's frame: the desktop's, or the 3.1 one the app draws --
    # on X11 and Wayland the way back to the 3.1 one, their window
    # managers' menus taking no item of the app's)
    var fr = ord(classicFrame())
    let own = if platformName() == "windows": "Windows' own frame"
              else: "The desktop's own frame"
    if settingCombo("Window", [own, "Windows 3.1 frame"], fr):
      chooseClassicFrame(fr == 1)       # (kept for the app's next start)
      result = true
  # (the title bars the toolkit draws: the 3.1 frame's, dialogs', the windows' in the app)
  var cb = ord(captionButtons)
  if settingCombo("Title bar buttons", ["Windows 95 (with close)", "Windows 3.1 (no close)"], cb):
    captionButtons = CaptionButtons(cb)
    invalidate()
    result = true
  var gm = ord(gpuMode())
  if settingCombo("Drawing", ["Automatic (the GPU when there is a real one)", "With the GPU",
                              "On the CPU"], gm):
    setGpuMode(GpuMode(gm))
    result = true
  case settingButtons("Size of the text", ["A-", "A", "A+"], $textScale() & "%")
  of 1: setTextScale(textScale() - 10); result = true
  of 2: setTextScale(100); result = true
  of 3: setTextScale(textScale() + 10); result = true
  else: discard
  # (GNU FreeFont's three in their menu order, then a font from a file)
  var fonts: seq[UiFont]
  var fontNames: seq[string]
  for u in builtinUiFonts:
    fonts.add u
    fontNames.add $u
  fonts.add ufFile
  fontNames.add(if uiFontPath.len > 0: tr("Font File: ") & uiFontPath.extractFilenameOf else: "A Font File...")
  var f = max(0, fonts.find(uiFont()))
  if settingCombo("Font", fontNames, f):
    if fonts[f] == ufFile and uiFontPath.len == 0:
      fontFileOpen = true                 # (which font: asked first)
    elif fonts[f] == ufFile:
      try:
        loadUiFontFile(uiFontPath)
        result = true
      except CatchableError: fontFileOpen = true
    else:
      setUiFont(fonts[f])
      result = true
  when not androidApp and not defined(ios):
    if pxScale == 1:
      var sharp = if subpixelText(): 0 else: 1
      if settingCombo("Text edges", ["Sharp", "Smooth"], sharp):
        setSubpixelText(sharp == 0)
        result = true
  if pxScale >= 2:
    var hd = if hdText(): 0 else: 1
    if settingCombo("Pixel icons on HD screens", ["Smooth", "Pixels (as in 1998, magnified)"], hd):
      setHdText(hd == 0)
      result = true
  var ics = ord(iconStyle())
  if settingCombo("Icons", ["Automatic (line icons in dark colors)", "Pixels (as in 1994)",
                            "Line (Nerd Fonts symbols)"], ics):
    setIconStyle(IconStyle(ics))
    result = true
  if uiFont() == ufFile:
    if settingButtons("Font file", ["Choose..."], uiFontPath.extractFilenameOf) == 1: fontFileOpen = true
  if fileDialog(fontFileOpen, fontFilePath, fmOpen, ["TrueType Fonts (*.ttf;*.ttc)", "All Files (*.*)"],
                "Font File"):
    try:
      loadUiFontFile(fontFilePath)
      result = true
    except CatchableError:
      fontFileError = fontFilePath.extractFilenameOf & ": not a font we read"
  if fontFileError.len > 0:
    label(fontFileError, color = color(160, 0, 0))
  var smooth = smoothScrolling
  if settingToggle("Smooth scrolling", smooth,
                   "Lists and pages glide; a flicked finger keeps them moving"):
    setSmoothScrolling(smooth)
    result = true

# ---- avatar, steps, banner, pages --------------------------------------------------------------

const avatarColors = [color(219, 68, 55), color(15, 157, 88), color(66, 133, 244),
                      color(171, 71, 188), color(0, 172, 193), color(255, 112, 67),
                      color(124, 179, 66), color(92, 107, 192), color(240, 98, 146),
                      color(141, 110, 99)]

proc initialsOf*(name: string): string =
  ## "Sultan Al-Said" -> "SA" (the first letters of the first two words).
  for word in strutils.splitWhitespace(name):
    if result.runeLen >= 2: break
    let r = word.runeAt(0)
    result.add toUpper(r).toUTF8

proc avatar*(name: string; size = 0; color = Color()): bool {.discardable.} =
  ## A round badge with someone's initials, in a color of their own (from
  ## the name); true when clicked.
  let d = if size > 0: size else: FontH * 2 + dp(4)
  let r = place(d, d)
  let id = idOf("avatar:" & name)
  var hit = interact(id, r)
  spaceKey(id, hit)
  if hit.focused: ui.takesEnter = true     # (as a button: a default button leaves Enter to it)
  if hit.focused and keyHit(KeyEnter): hit.clicked = true
  var h = 0'u32
  for c in name: h = h * 31 + uint32(ord(c))
  let bg = if color.a == 0: avatarColors[int(h mod uint32(avatarColors.len))] else: color
  disc(float(r.x) + d / 2, float(r.y) + d / 2, d / 2,
       if hit.showsHover: mixColor(bg, th.text, 0.2) else: bg)
  let st = style(bold = true, size = d / FontH / 2.2)
  let s = initialsOf(name)
  text(r.x + (d - textWidth(s, st)) div 2, r.y + (d - lineHeight(st)) div 2, s,
       color(255, 255, 255), st)
  if hit.focused: focusDots(inset(r, -2))
  if accessOn: accessNode(arButton, name, id = id, r = r)
  hit.clicked

proc stepper*(steps: openArray[string]; current: int; enabled = true): int =
  ## The steps of a task (a wizard, a checkout) as numbered circles joined
  ## by a line: done ones ticked, the current one highlighted. Returns the
  ## step clicked (only steps already done can be), -1 if none.
  result = -1
  if steps.len == 0: return
  let d = FontH + (if fingers(): dp(12) else: dp(8))   # (a finger can hit a step)
  let showLabels = available() div max(1, steps.len) > dp(60)
  let r = place(0, d + (if showLabels: FontH + dp(4) else: 0), fill = true)
  ui.lastId = 0
  ui.lastRect = r
  let slot = r.w div steps.len
  let gid = idOf("stepper:" & steps[0] & $steps.len)
  let focused = enabled and current > 0 and tabStop(gid, r)
  if accessOn: accessBegin(arList, "", r, gid, accessOff(enabled), takesLabel = true)
  if focused and canInput() and not ui.keyUsed:
    if ui.key in {KeyLeft, KeyBackspace}:
      ui.keyUsed = true
      result = current - 1
    elif ui.key == KeyHome:
      ui.keyUsed = true
      result = 0
  for i, s in steps:
    let cx = r.x + slot * i + slot div 2
    if i < steps.high:
      let nx = r.x + slot * (i + 1) + slot div 2
      thickLine(float(cx + d div 2 + dp(4)), float(r.y + d div 2),
                float(nx - d div 2 - dp(4)), float(r.y + d div 2), float(dp(2)),
                if i < current: th.select else: th.shadow)
    let cr = rect(cx - d div 2, r.y, d, d)
    let id = idOf("step:" & $i & s)
    let hit = interact(id, cr, focusable = false, enabled = enabled and i < current)
    if hit.clicked:
      result = i
      ui.focus = gid
    let done = i < current
    let now = i == current
    let fillC = if done or now: th.select else: th.field
    disc(float(cx), float(r.y) + d / 2, d / 2, if done or now: th.select else: th.shadow)
    disc(float(cx), float(r.y) + d / 2, d / 2 - 1.5,
         if hit.showsHover: mixColor(fillC, th.text, 0.2) else: fillC)
    let mark = if done: nfCheck else: $(i + 1)
    let mc = if done or now: th.selectText else: th.gray
    text(cx - textWidth(mark, now) div 2, r.y + (d - FontH) div 2, mark, mc, now)
    if showLabels:
      let label = ellipsize(s, slot - dp(4))
      text(cx - textWidth(label, now) div 2, r.y + d + dp(4), label,
           if done or now: th.text else: th.gray, now)
    if focused and now: focusDots(inset(cr, -3))
    if accessOn:
      let k = accessNode(if done: arButton else: arListItem, s, id = id, r = cr,
                         states = (if now: {asSelected} else: {}) + accessOff(enabled and done),
                         help = (if done: "done" elif now: "now" else: ""))
      accessItem(k, i + 1, steps.len)
      if focused and now: accessFocus(k)
  if accessOn: accessEnd()
  ui.lastId = gid
  ui.lastRect = r

type BannerKind* = enum
  ## The color and sign of a `banner`.
  bkInfo, bkSuccess, bkWarning, bkError

proc banner*(msg: string; kind = bkInfo; actions: openArray[string] = [];
             closable = true): int =
  ## A colored strip with an icon, a message and buttons ("Update", "Undo"):
  ## the button clicked (1-based), 0 when closed with its x, -1 if none.
  result = -1
  let (glyph, accent) = case kind
    of bkInfo: (retroOr(pxInfo, nfInfo), color(33, 110, 200))
    of bkSuccess: (retroOr(pxCheck, nfCheckCircle), color(30, 140, 70))
    of bkWarning: (retroOr(pxWarning, nfWarning), color(200, 140, 0))
    of bkError: (retroOr(pxError, nfExclamation), color(200, 40, 40))
  let w = available()
  # (the text starts after the icon, however wide the icon is drawn)
  let tx = max(dp(34), dp(12) + textWidth(glyph) + dp(6))
  var bw = 0
  for a in actions: bw += buttonWidth(a) + Gap
  let xw = if closable: CtrlH else: 0
  let narrow = bw > w div 2
  let textW = w - tx - dp(6) - xw - (if narrow: 0 else: bw)
  let lines = wrapLines(tr(msg), max(dp(60), textW))
  # narrow: the buttons under the text, in as many rows as they need (a
  # button wider than the strip gets a row of its own)
  var rows: seq[seq[int]]
  if narrow:
    let room = max(dp(60), w - tx - dp(8))
    var x = 0
    for i, a in actions:
      let bwi = buttonWidth(a) + Gap
      if rows.len == 0 or (x + bwi > room and x > 0):
        rows.add @[]
        x = 0
      rows[^1].add i
      x += bwi
  let h = max(CtrlH + dp(12), lines.len * FontH + dp(16)) +
          rows.len * (CtrlH + dp(6)) + (if rows.len > 0: dp(2) else: 0)
  let r = place(0, h, fill = true)
  ui.lastId = 0
  ui.lastRect = r
  fill(r, mixColor(th.window, accent, 0.12))
  fill(rect(r.x, r.y, dp(4), r.h), accent)
  box(r, mixColor(th.window, accent, 0.5))
  if accessOn:
    accessBegin(arAlert, tr(msg), r, idOf("banner:" & msg))
  text(r.x + dp(12), r.y + dp(8), glyph, accent)
  var y = r.y + dp(8)
  for line in lines:
    text(r.x + tx, y, line, th.text)
    y += FontH
  if closable:
    let xr = rect(r.x + r.w - xw, r.y + dp(4), xw, CtrlH)
    let id = idOf("banner-x:" & msg)
    var hit = interact(id, xr)
    spaceKey(id, hit)
    text(xr.x + (xw - textWidth(nfTimes)) div 2, xr.y + (CtrlH - FontH) div 2, nfTimes,
         if hit.showsHover or hit.focused: th.text else: th.gray)
    if hit.focused:
      ui.takesEnter = true
      focusDots(inset(xr, dp(4)))
      if keyHit(KeyEnter) or keyHit(KeyEsc): hit.clicked = true
    if accessOn: accessNode(arButton, "Close", id = id, r = xr)
    if hit.clicked: result = 0
  if actions.len > 0 and not narrow:
    pushFrame(rect(r.x + r.w - xw - bw, r.y + (r.h - CtrlH) div 2, bw, 0))
    row:
      for i, a in actions:
        if button(a): result = i + 1
    discard popFrame()
  elif actions.len > 0:
    var ay = r.y + r.h - rows.len * (CtrlH + dp(6))
    for line in rows:
      var lw = 0
      for i in line: lw += buttonWidth(actions[i]) + Gap
      pushFrame(rect(r.x + tx, ay, min(lw, r.w - tx - dp(6)), 0))
      row:
        for i in line:
          if button(actions[i], w = min(buttonWidth(actions[i]), r.w - tx - dp(6))): result = i + 1
      discard popFrame()
      ay += CtrlH + dp(6)
  if accessOn: accessEnd()
  ui.lastId = 0
  ui.lastRect = r

proc pager*(page: var int; pages: int; enabled = true): bool {.discardable.} =
  ## Page buttons: "< 1 ... 4 5 6 ... 20 >"; `page` is 0-based. True when
  ## it changed.
  if pages <= 1: return false
  page = clamp(page, 0, pages - 1)
  var shown: seq[int]                      # -1: "..."
  let around = if available() < dp(360): 1 else: 2
  for p in 0 ..< pages:
    if p == 0 or p == pages - 1 or abs(p - page) <= around:
      shown.add p
    elif shown.len > 0 and shown[^1] != -1:
      shown.add -1
  row:
    if toolButton(retroOr(pxBack, nfChevronLeft), "Previous page", enabled = enabled and page > 0):
      dec page
      result = true
    for p in shown:
      if p < 0:
        label "..."
      elif toolButton($(p + 1), "Page " & $(p + 1), down = p == page,
                      bold = p == page, enabled = enabled):
        if p != page:
          page = p
          result = true
    if toolButton(retroOr(pxForward, nfChevronRight), "Next page", enabled = enabled and page < pages - 1):
      inc page
      result = true

# ---- bottom navigation, floating button --------------------------------------------------------

proc bottomNav*(items: openArray[(string, string)]; sel: var int): bool {.discardable.} =
  ## The navigation bar of a phone app at the bottom of the window: a glyph
  ## and a label per place (`[(nfHome, "Home"), (nfSearch, "Search")]`).
  ## Call it before the content (like `statusbar`). True when `sel` changed.
  if items.len == 0: return
  let st = style(size = 0.8)
  # (the bottom-most bar also covers the system's gesture area)
  let below = if ui.bottom >= ui.h - ui.safe.bottom: ui.h - ui.bottom else: 0
  let h = (if fingers(): dp(56) else: dp(44))
  let r = rect(0, ui.bottom - h, ui.w, h + below)
  pushLayer(LayerBase)
  defer: popLayer()
  fill(r, th.face)
  hline(0, r.y, ui.w, th.frame)
  hline(0, r.y + 1, ui.w, th.light)
  ui.bottom = r.y
  let inner = rect(ui.safe.left, r.y + 2, ui.w - ui.safe.left - ui.safe.right, h - 2)
  let slot = inner.w div items.len
  let gst = style(size = 1.35)
  let gid = idOf("bottomnav:" & $items.len & items[0][1])
  let focused = tabStop(gid, inner)
  if accessOn: accessBegin(arTabList, "", inner, gid)
  if focused and canInput() and not ui.keyUsed:
    let before = sel
    case ui.key
    of KeyLeft: sel = max(0, sel - 1)
    of KeyRight: sel = min(items.high, sel + 1)
    of KeyHome: sel = 0
    of KeyEnd: sel = items.high
    else: discard
    if sel != before:
      ui.keyUsed = true
      result = true
  for i, (glyph, label) in items:
    let cell = rect(inner.x + slot * i, inner.y, slot, inner.h)
    let id = idOf("bottomnav:" & $i & label)
    let hit = interact(id, cell, focusable = false)
    if hit.down and ui.pressed: ui.focus = gid
    if hit.clicked and sel != i:
      sel = i
      result = true
    let on = i == sel
    if hit.showsHover and not on: fill(inset(cell, 2), hoverColor())
    let c = if on: th.select else: th.gray
    if on:
      roundRect(rect(cell.x + cell.w div 2 - dp(28), cell.y + dp(4), dp(56),
                     lineHeight(gst) + dp(2)), (lineHeight(gst) + dp(2)) / 2,
                mixColor(th.face, th.select, 0.18))
    text(cell.x + (cell.w - textWidth(glyph, gst)) div 2, cell.y + dp(5), glyph, c, gst)
    let l = ellipsize(label, slot - dp(4), st)
    text(cell.x + (cell.w - textWidth(l, st)) div 2,
         cell.y + dp(6) + lineHeight(gst), l, if on: th.text else: th.gray, st)
    if on and focused and not ui.touch: focusDots(inset(cell, dp(3)))
    if accessOn:
      let k = accessNode(arTab, label, id = id, r = cell, states = (if on: {asSelected} else: {}))
      accessItem(k, i + 1, items.len)
      if on and focused: accessFocus(k)
  if accessOn: accessEnd()

proc fab*(glyph: string; tip = ""; color = Color()): bool =
  ## The round "floating action button" at the bottom right, over the
  ## content (the main action of a screen: new message, add item). Call it
  ## after the status or navigation bar and before the content.
  let d = if fingers(): dp(56) else: dp(46)
  let r = rect(ui.w - ui.safe.right - d - dp(16), ui.bottom - d - dp(16), d, d)
  # it takes input with the window's widgets (and keeps the mouse from the
  # content under it), but is drawn over them
  let id = idOf("fab:" & glyph & tip)
  ui.overlayOwner = true
  var hit = interact(id, r)
  ui.overlayOwner = false
  if canInput() and ui.overlayNow.w == 0:
    ui.overlayNow = r
    ui.overlayLayerNow = layer()
  spaceKey(id, hit)
  if hit.focused: ui.takesEnter = true     # (as a button: a default button leaves Enter to it)
  if hit.focused and keyHit(KeyEnter): hit.clicked = true
  if tip.len > 0: tooltip(tip)
  pushLayer(LayerDialog)
  defer: popLayer()
  let bg = if color.a == 0: th.select else: color
  disc(float(r.x) + d / 2 + 1, float(r.y) + d / 2 + 3, d / 2, mixColor(th.shadow, th.window, 0.3))
  disc(float(r.x) + d / 2, float(r.y) + d / 2, d / 2,
       if hit.down: mixColor(bg, th.text, 0.3) elif hit.showsHover: mixColor(bg, th.window, 0.15)
       else: bg)
  let st = style(size = 1.5)
  text(r.x + (d - textWidth(glyph, st)) div 2, r.y + (d - lineHeight(st)) div 2, glyph,
       th.selectText, st)
  if hit.focused and not ui.touch: focusDots(inset(r, -3))
  if accessOn: accessNode(arButton, tip, id = id, r = r)
  hit.clicked

# ---- small charts ------------------------------------------------------------------------------

proc sparkline*(values: openArray[float]; w = 0; h = 0; color = Color();
                fillUnder = true) =
  ## A tiny line chart without axes, for a trend next to a number.
  let r = place(if w > 0: w else: dp(90), if h > 0: h else: FontH + dp(4))
  ui.lastId = 0
  ui.lastRect = r
  if values.len < 2: return
  var lo = values[0]
  var hi = values[0]
  for v in values:
    lo = min(lo, v)
    hi = max(hi, v)
  let span = if hi > lo: hi - lo else: 1.0
  let c = if color.a == 0: th.select else: color
  var pts: seq[(float, float)]
  for i, v in values:
    pts.add (float(r.x) + float(r.w - 1) * float(i) / float(values.high),
             float(r.y + r.h - 2) - float(r.h - 4) * (v - lo) / span)
  if fillUnder:
    var area = pts
    area.add (float(r.x + r.w - 1), float(r.y + r.h))
    area.add (float(r.x), float(r.y + r.h))
    polygon(area, mixColor(th.window, c, 0.2))
  for i in 1 ..< pts.len:
    thickLine(pts[i - 1][0], pts[i - 1][1], pts[i][0], pts[i][1], max(1.0, float(dp(2)) * 0.75), c)
  disc(pts[^1][0], pts[^1][1], float(dp(2)), c)

proc progressRing*(value: float; size = 0; color = Color(); showText = true) =
  ## A round progress indicator, `value` from 0.0 to 1.0.
  let d = if size > 0: size else: FontH * 3
  let r = place(d, d)
  ui.lastId = 0
  ui.lastRect = r
  let v = if value.isNaN: 0.0 else: clamp(value, 0.0, 1.0)
  let cx = float(r.x) + d / 2
  let cy = float(r.y) + d / 2
  let width = max(3.0, d / 9)
  let c = if color.a == 0: th.select else: color
  ring(cx, cy, d / 2 - width / 2, width, th.face)
  if v > 0:
    # the arc: along the outer edge, back along the inner one
    let n = max(6, int(72 * v))
    let a1 = -PI / 2 + 2 * PI * v
    var pts: seq[(float, float)]
    for i in 0 .. n:
      let a = -PI / 2 + (a1 + PI / 2) * float(i) / float(n)
      pts.add (cx + d / 2 * cos(a), cy + d / 2 * sin(a))
    for i in countdown(n, 0):
      let a = -PI / 2 + (a1 + PI / 2) * float(i) / float(n)
      pts.add (cx + (d / 2 - width) * cos(a), cy + (d / 2 - width) * sin(a))
    polygon(pts, c)
  if showText:
    let s = $int(round(v * 100)) & "%"
    let st = style(bold = true, size = max(0.7, d / FontH / 3.2))
    text(int(cx) - textWidth(s, st) div 2, int(cy) - lineHeight(st) div 2, s, th.text, st)

proc usageBar*(used, total: int64; w = 0; h = 0) =
  ## How full something is (a drive): a bar, red when over 90%.
  let r = place(if w > 0: w else: 0, if h > 0: h else: dp(8), fill = w <= 0)
  ui.lastId = 0
  ui.lastRect = r
  fill(r, th.field)
  box(r, th.shadow)
  if total > 0:
    let k = clamp(used.float / total.float, 0.0, 1.0)
    let c = if k > 0.9: color(200, 40, 40) else: th.select
    fill(rect(r.x + 1, r.y + 1, int(float(r.w - 2) * k), r.h - 2), c)

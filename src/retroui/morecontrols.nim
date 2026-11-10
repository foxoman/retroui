## More controls, in the 3.1 manner, for what apps of today expect on every
## platform: a two-thumb range slider, menu and split buttons, a tag box,
## a text box that suggests (autocomplete), a knob, status lights, an
## accordion, a timeline, a rating of stars, a color-coded "pill".
##
## .. code-block:: nim
##   var lo, hi = 20                  # (hi = 80)
##   rangeSlider(lo, hi, 0, 100)
##   let pick = menuButton("&Export", ["PNG", "JPEG", "PDF"])
##   if pick >= 0: echo "export as ", pick
##   tagInput(tags, newTag)
##   autocomplete(city, ["Muscat", "Sohar", "Salalah", "Nizwa"])

import std/[strutils, math]
import gfx, core, widgets

template th: untyped = ui.theme

# ---- a range: two thumbs ---------------------------------------------------------------------------

proc rangeSlider*(lo, hi: var int; minV, maxV: int; w = 0; ticks = 10;
                  enabled = true): bool {.discardable.} =
  ## A track bar with two thumbs, `lo` and `hi` (`minV <= lo <= hi <=
  ## maxV`): drag either (the nearer is taken), or the band between them
  ## to move both. Keys: Tab stops at each end, the left first; the arrows
  ## move the focused one (Shift+arrows the other). True when either
  ## changed.
  let tw = if fingers(): dp(28) else: dp(11)      # (a finger's width)
  let tht = if fingers(): dp(30) else: dp(18)
  let tick = if ticks > 0: dp(5) else: 0
  let r = place(if w > 0: w else: 0, max(tht + tick + dp(2), FontH + 8), fill = w <= 0)
  let id = idOf(lo, "range")
  let hit = interact(id, r, enabled = enabled)
  # (the right end: Tab's second stop, no place of its own for the mouse)
  let hid = idOf(lo, "range-to")
  let hit2 = interact(hid, rect(r.x, r.y, 0, 0), enabled = enabled)
  ui.lastId = id                          # (the slider is what was drawn last: its tooltip, its place)
  ui.lastRect = r
  let span = max(1, maxV - minV)
  let chan = rect(r.x + tw div 2, r.y + tht div 2 - dp(2), max(1, r.w - tw), dp(4))
  let travel = max(1, chan.w)
  template xOf(v: int): int = chan.x + (clamp(v, minV, maxV) - minV) * travel div span
  template vOf(px: int): int = minV + ((px - chan.x) * span + travel div 2) div travel
  var st = state(id)
  var nlo = lo
  var nhi = hi
  if enabled:
    if hit.down and ui.pressed:
      # which: the nearer thumb, or the band (aux 1 lo, 2 hi, 3 band)
      let dl = abs(ui.mx - xOf(lo))
      let dh = abs(ui.mx - xOf(hi))
      st.aux = if ui.mx > xOf(lo) + tw div 2 and ui.mx < xOf(hi) - tw div 2: 3
               elif dl < dh or (dl == dh and ui.mx < xOf(lo)): 1
               else: 2
      st.aux2 = vOf(ui.mx) - lo
      if st.aux == 2: ui.focus = hid          # (the right end taken: the keys move it)
    if ui.active == id and ui.mouseDown:
      ui.dragsActive = true
      let v = vOf(ui.mx)
      case st.aux
      of 1: nlo = min(v, hi)
      of 2: nhi = max(v, lo)
      of 3:
        let width = hi - lo
        nlo = clamp(v - st.aux2, minV, maxV - width)
        nhi = nlo + width
      else: discard
    if (hit.focused or hit2.focused) and canInput():
      let big = max(1, span div 10)
      let right = hit2.focused xor (ShiftPressed in ui.mods)
      var d = 0
      case ui.key
      of KeyLeft, KeyDown: d = -1
      of KeyRight, KeyUp: d = 1
      of KeyPageDown: d = -big
      of KeyPageUp: d = big
      else: discard
      if d != 0:
        ui.keyUsed = true
        if right: nhi = max(lo, hi + d) else: nlo = min(hi, lo + d)
  if accessOn and enabled:
    # (a screen reader set one end)
    if accessValueFor(id): nlo = min(int(round(accessSet.num)), hi)
    if accessValueFor(hid): nhi = max(int(round(accessSet.num)), lo)
  nlo = clamp(nlo, minV, maxV)
  nhi = clamp(nhi, nlo, maxV)
  if nlo != lo or nhi != hi:
    lo = nlo
    hi = nhi
    result = true
  state(id) = st
  sunken(chan)
  hline(chan.x + 1, chan.y + 1, chan.w - 2, th.frame)
  # (the range: in the highlight color)
  let a = xOf(lo)
  let b = xOf(hi)
  if b > a: fill(rect(a, chan.y + 1, b - a, chan.h - 2), if enabled: th.select else: th.gray)
  for (v, k) in [(lo, 1), (hi, 2)]:
    let cx = xOf(v)
    let thumb = rect(cx - tw div 2, r.y, tw, tht)
    buttonFace(thumb, ui.active == id and st.aux == k and ui.mouseDown, rounded = false, bevel = 1,
               hot = enabled and hovered(thumb))
  if ticks > 0:
    for i in 0 .. ticks:
      vline(chan.x + i * travel div ticks, r.y + tht + dp(2), dp(3), if enabled: th.text else: th.gray)
  if hit.focused or hit2.focused:
    focusDots(rect(r.x, r.y - 1, r.w, r.h + 2))
    let v = if hit2.focused: hi else: lo
    ui.focusRect = rect(xOf(v) - tw div 2, r.y, tw, tht)
  if accessOn:
    # (its two ends, as two sliders in a group)
    accessBegin(arGroup, "", r, accessSubId(id, 2), accessOff(enabled), takesLabel = true)
    for (v, k, n) in [(lo, 0, "From"), (hi, 1, "To")]:
      let i = accessNode(arSlider, tr(n), $v, accessOff(enabled), (if k == 0: id else: hid),
                         rect(xOf(v) - tw div 2, r.y, tw, tht))
      accessRange(i, float(minV), float(maxV), float(v))
      if (k == 0 and hit.focused) or (k == 1 and hit2.focused): accessFocus(i)
    accessEnd()

# ---- buttons that open a menu ------------------------------------------------------------------------

proc menuButton*(label: string; items: openArray[string]; w = 0; enabled = true): int =
  ## A button with an arrow that drops a menu of `items`: the index
  ## chosen, or -1. ("-" in `items` is a separator.) A click, Space,
  ## Enter, Down, Alt+Down or F4 drop it.
  result = -1
  let bw = if w > 0: w else: labelWidth(label) + dp(34)
  let r = place(bw, CtrlH)
  let key = "menubtn:" & label
  let bid = idOf(key)                        # (one id: a second `idOf` is another)
  var hit = interact(bid, r, enabled = enabled)
  let open = popupMenuOpen(key)
  if enabled:
    spaceKey(bid, hit)                       # (Space, Enter: it drops, as a click does)
    if hit.focused:
      ui.takesEnter = true
      if keyHit(KeyEnter): hit.clicked = true
  buttonFace(r, hit.down or open, 1, hot = enabled and hovered(r))
  let o = if hit.down or open: 1 else: 0
  drawLabel(r.x + dp(8) + o, r.y + (r.h - FontH) div 2 + o, label, if enabled: th.text else: th.gray)
  arrow(r.x + r.w - dp(11) + o, r.y + r.h div 2 + o, dDown, if enabled: th.text else: th.gray)
  if accessOn:
    accessNode(arButton, label, id = bid, r = r,
               states = accessOff(enabled) + {asExpandable} + (if open: {asExpanded} else: {}))
  if hit.focused and dropKey(): hit.clicked = true
  if hit.clicked or (enabled and mnemonicHit(label)) or (hit.focused and keyHit(KeyDown)):
    openPopupMenu(key, r.x, r.y + r.h)
  popupMenu(key):
    for i, it in items:
      if it == "-": menuSeparator()
      elif menuItem(it): result = i

proc splitButton*(label: string; items: openArray[string]; w = 0; enabled = true): tuple[clicked: bool; chose: int] =
  ## A button whose left part does its default (`clicked`: a click, Space,
  ## Enter) and whose arrow part drops a menu of the other ways (`chose`:
  ## the index, else -1; Alt+Down or F4 drop it too).
  result.chose = -1
  let aw = if fingers(): dp(28) else: dp(16)       # (a finger's width)
  let bw = if w > 0: w else: labelWidth(label) + dp(24) + aw
  let r = place(bw, CtrlH)
  let main = rect(r.x, r.y, r.w - aw + 1, r.h)
  let drop = rect(r.x + r.w - aw, r.y, aw, r.h)
  let key = "splitbtn:" & label
  let mainId = idOf(key & ":main")           # (one id each: a second `idOf` is another)
  let dropId = idOf(key & ":drop")
  var mh = interact(mainId, main, enabled = enabled)
  if enabled:
    spaceKey(mainId, mh)                     # (Space, Enter: its default)
    if mh.focused:
      ui.takesEnter = true
      if keyHit(KeyEnter): mh.clicked = true
  let dh = interact(dropId, drop, focusable = false, enabled = enabled)
  let open = popupMenuOpen(key)
  buttonFace(main, mh.down, 1, hot = enabled and hovered(main))
  buttonFace(drop, dh.down or open, 1, hot = enabled and hovered(drop))
  let o = if mh.down: 1 else: 0
  let tw = labelWidth(label)
  drawLabel(main.x + (main.w - tw) div 2 + o, main.y + (main.h - FontH) div 2 + o, label,
            if enabled: th.text else: th.gray)
  let o2 = if dh.down or open: 1 else: 0
  arrow(drop.x + drop.w div 2 + o2, drop.y + drop.h div 2 + o2, dDown, if enabled: th.text else: th.gray)
  if mh.focused: focusDots(inset(main, 3))
  if accessOn:
    accessNode(arButton, label, id = mainId, r = main, states = accessOff(enabled))
    accessNode(arButton, plainName(label) & ": more", id = dropId, r = drop,
               states = accessOff(enabled) + {asExpandable} + (if open: {asExpanded} else: {}))
  result.clicked = mh.clicked or (enabled and mnemonicHit(label))
  if dh.clicked or (mh.focused and dropKey()):
    openPopupMenu(key, r.x, r.y + r.h)
  popupMenu(key):
    for i, it in items:
      if it == "-": menuSeparator()
      elif menuItem(it): result.chose = i
  ui.lastId = idOf(key & ":main")              # (the whole button, for a tooltip after it)
  ui.lastRect = r

# ---- tags --------------------------------------------------------------------------------------------

proc tagInput*(tags: var seq[string]; text: var string; w = 0; enabled = true;
               placeholder = "Add a tag"): bool {.discardable.} =
  ## Tags as chips (each with its ×) and a box to type the next: Enter, a
  ## comma or Tab adds it, Backspace in the empty box takes the last off.
  ## True when the tags changed.
  let room = if w > 0: w else: available()
  let st = style(size = 0.9)
  let chipH = FontH + (if fingers(): dp(12) else: dp(4))   # (a finger's height)
  # (where each chip goes: wrapping; then the box)
  var x = 0
  var y = 0
  var spots: seq[(int, int, int)]
  for t in tags:
    let cw = textWidth(t, st) + dp(22)
    if x > 0 and x + cw > room - dp(4):
      x = 0
      y += chipH + dp(3)
    spots.add (x, y, cw)
    x += cw + dp(3)
  let boxW = max(dp(80), room - x - dp(6))
  if x > 0 and boxW < dp(80):
    x = 0
    y += chipH + dp(3)
  let h = y + max(chipH, EditH) + dp(4)
  let r = place(room, h + 2)
  fill(r, th.field)
  fieldFrame(r, enabled)
  var drop = -1
  for i, (cx, cy, cw) in spots:
    let cr = rect(r.x + dp(3) + cx, r.y + dp(3) + cy, cw, chipH)
    fill(cr, th.face)
    raised(cr, 1)
    text(cr.x + dp(6), cr.y + (cr.h - lineHeight(st)) div 2, tags[i], th.text, st)
    let xr = rect(cr.x + cr.w - dp(14), cr.y + (cr.h - dp(10)) div 2, dp(10), dp(10))
    let xid = idOf("tagx:" & tags[i] & $i)     # (one id: a second `idOf` is another)
    let xh = interact(xid, xr, focusable = false, enabled = enabled)
    if accessOn:
      accessNode(arButton, tags[i], id = xid, r = cr,
                 states = accessOff(enabled), help = "Remove")
    let c = if xh.hover: th.select else: th.gray
    line(xr.x + 1, xr.y + 1, xr.x + xr.w - 2, xr.y + xr.h - 2, c)
    line(xr.x + 1, xr.y + xr.h - 2, xr.x + xr.w - 2, xr.y + 1, c)
    if xh.clicked: drop = i
  if drop >= 0:
    tags.delete(drop)
    result = true
  let er = rect(r.x + dp(3) + x, r.y + dp(2) + y + (max(chipH, EditH) - EditH) div 2, max(dp(60), r.w - x - dp(8)), EditH)
  let id = idOf(text, "taginput")
  let focused = ui.focus == id
  # (Backspace in the empty box: the last tag off -- before the box takes the key)
  if focused and enabled and text.len == 0 and tags.len > 0 and keyHit(KeyBackspace):
    ui.keyUsed = true
    tags.setLen(tags.len - 1)
    result = true
  if accessOn: accessNameOr(tr(placeholder))
  discard editAt(id, text, er, false, false, enabled, frameless = true)
  if text.len == 0 and not focused:
    text(er.x + dp(3), er.y + (er.h - FontH) div 2, placeholder, th.gray)
  if ui.focus == id and enabled:
    ui.takesEnter = true                  # (Enter adds the tag: #9)
    var add = false
    if text.endsWith(","):
      text.setLen(text.len - 1)
      add = true
    if keyHit(KeyEnter):
      ui.keyUsed = true
      add = true
    if add and text.strip.len > 0:
      let t = text.strip
      if t notin tags:
        tags.add t
        result = true
      text = ""

# ---- a text box that suggests ---------------------------------------------------------------------------

proc autocomplete*(s: var string; choices: openArray[string]; w = 0; rows = 6;
                   enabled = true): bool {.discardable.} =
  ## A text box whose list of `choices` that begin with (or hold) what is
  ## typed drops under it: Down and Up pick, Enter or Tab or a click takes
  ## one, Esc closes it. True when the text changed.
  let r = place(if w > 0: w else: 0, EditH, fill = w <= 0)
  let id = idOf(s, "auto")
  var st = state(id)
  let before = s
  if editAt(id, s, r, false, false, enabled): result = true
  if s != before: st.aux = 0            # (typed: the list again, the first picked)
  let focused = ui.focus == id
  var shown: seq[string]
  let q = s.toLowerAscii
  if focused and q.len > 0 and st.aux2 == 0:
    for c in choices:
      if c.toLowerAscii.startsWith(q) and c != s: shown.add c
    for c in choices:
      if q in c.toLowerAscii and not c.toLowerAscii.startsWith(q) and c != s: shown.add c
  if shown.len == 0:
    if s != before: st.aux2 = 0
    state(id) = st
    return
  let vis = min(rows, shown.len)
  var lr = rect(r.x, r.y + r.h, r.w, vis * ItemH + 2)
  if lr.y + lr.h > ui.h: lr.y = r.y - lr.h
  st.aux = clamp(st.aux, 0, shown.high)
  if canInput():
    ui.takesEnter = true                  # (Enter takes the suggestion: #9)
    case ui.key
    of KeyDown: st.aux = min(shown.high, st.aux + 1); ui.keyUsed = true
    of KeyUp: st.aux = max(0, st.aux - 1); ui.keyUsed = true
    of KeyEnter, KeyTab:
      s = shown[st.aux]
      result = true
      ui.keyUsed = ui.key == KeyEnter
      st.aux2 = 1                         # (taken: closed until typed again)
    of KeyEsc:
      st.aux2 = 1
      ui.keyUsed = true
    else: discard
  # the list, over what is under it (it takes the mouse first)
  let picking = mouseIn(lr)
  if picking:
    ui.hot = id
    let i = (ui.my - lr.y - 1) div ItemH
    if i in 0 .. vis - 1 and ui.mouseMoved: st.aux = i
    if ui.pressed and takePress():
      s = shown[clamp(i, 0, shown.high)]
      result = true
      st.aux2 = 1
  if st.aux2 == 0:
    pushLayer(LayerPopup)
    fill(lr, th.field)
    box(lr, th.frame)
    for i in 0 ..< vis:
      let ir = rect(lr.x + 1, lr.y + 1 + i * ItemH, lr.w - 2, ItemH)
      if i == st.aux:
        fill(ir, th.select)
        text(ir.x + dp(4), ir.y + (ItemH - FontH) div 2, shown[i], th.selectText)
      else:
        text(ir.x + dp(4), ir.y + (ItemH - FontH) div 2, shown[i], th.fieldText)
    popLayer()
  if s != before and st.aux2 == 1 and result and not picking: discard
  state(id) = st

# ---- a knob --------------------------------------------------------------------------------------------

proc knob*(v: var int; lo, hi: int; size = 0; label = ""; enabled = true): bool {.discardable.} =
  ## A round knob (a volume, a pan): drag up or right to turn it up, the
  ## wheel and the arrow keys too; its value under it.
  let d = if size > 0: size else: dp(40)
  let r = place(max(d, if label.len > 0: textWidth(label) else: 0), d + FontH + dp(2))
  let id = idOf(v, "knob")
  let hit = interact(id, r, enabled = enabled)
  var st = state(id)
  var nv = v
  if accessOn and enabled and accessValueFor(id): nv = int(round(accessSet.num))
  let span = max(1, hi - lo)
  if enabled:
    if hit.down and ui.pressed:
      st.aux = ui.mx - ui.my
      st.aux2 = v
    if ui.active == id and ui.mouseDown:
      ui.dragsActive = true
      nv = st.aux2 + ((ui.mx - ui.my) - st.aux) * span div max(1, dp(150))
    if hit.hover and canInput() and ui.wheel != 0 and not ui.wheelUsed:
      ui.wheelUsed = true
      nv -= ui.wheel * max(1, span div 20)
    if hit.focused and canInput():
      case ui.key
      of KeyLeft, KeyDown: dec nv; ui.keyUsed = true
      of KeyRight, KeyUp: inc nv; ui.keyUsed = true
      of KeyHome: nv = lo; ui.keyUsed = true
      of KeyEnd: nv = hi; ui.keyUsed = true
      else: discard
  state(id) = st
  nv = clamp(nv, lo, hi)
  if nv != v:
    v = nv
    result = true
  # (a raised disc, its pointer from 7 to 5 o'clock)
  let cx = r.x + r.w div 2
  let cy = r.y + d div 2
  let rad = d div 2 - 1
  for yy in -rad .. rad:
    let half = int(sqrt(float(rad * rad - yy * yy)))
    let c = if yy < -rad div 3: th.light elif yy > rad div 3: th.shadow else: th.face
    hline(cx - half, cy + yy, 2 * half + 1, c)
  for a in 0 ..< 64:
    let t = a.float / 64 * 2 * PI
    let px = cx + int(round(cos(t) * rad.float))
    let py = cy + int(round(sin(t) * rad.float))
    fill(rect(px, py, 1, 1), th.frame)
  let f = (v - lo).float / span.float
  let ang = degToRad(135.0 + 270.0 * f)
  let ex = cx + int(round(cos(ang) * (rad - dp(4)).float))
  let ey = cy + int(round(sin(ang) * (rad - dp(4)).float))
  line(cx, cy, ex, ey, if enabled: th.text else: th.gray)
  line(cx + 1, cy, ex + 1, ey, if enabled: th.text else: th.gray)
  let txt = if label.len > 0: label & " " & $v else: $v
  text(r.x + (r.w - textWidth(txt)) div 2, r.y + d + dp(1), txt, if enabled: th.text else: th.gray)
  if hit.focused: focusDots(r)
  if accessOn:
    let k = accessNode(arSlider, label, $v, accessOff(enabled), id, r)
    accessRange(k, float(lo), float(hi), float(v))

# ---- status lights ---------------------------------------------------------------------------------

proc led*(on: bool; label = ""; c = Color()) =
  ## A small light: lit (in `c`, green when not given) or dark, with a label.
  let s = dp(10)
  let r = place(s + (if label.len > 0: dp(5) + labelWidth(label) else: 0), max(s, FontH))
  let lr = rect(r.x, r.y + (r.h - s) div 2, s, s)
  let col = if c.a == 0: color(0, 200, 0) else: c
  let lit = if on: col else: mixColor(col, th.shadow, 0.75)
  for yy in 0 ..< s:
    let dy = yy.float - (s - 1) / 2
    let half = int(sqrt(max(0.0, (s.float / 2) ^ 2 - dy * dy)))
    hline(lr.x + s div 2 - half, lr.y + yy, 2 * half, lit)
  if on: fill(rect(lr.x + s div 3, lr.y + s div 4, dp(2), dp(2)), color(255, 255, 255))
  if label.len > 0: drawLabel(lr.x + s + dp(5), r.y + (r.h - FontH) div 2, label, th.text)

# ---- an accordion ---------------------------------------------------------------------------------------

proc accordionHeader*(title: string; index: int; open: var int): bool =
  ## One header of an accordion (sections of which one is open at a time):
  ## true when section `index` is the open one -- draw its contents then.
  ## A click opens it (or closes it when it was open: `open` -1).
  ##
  ## .. code-block:: nim
  ##   for i, t in ["General", "Advanced"]:
  ##     if accordionHeader(t, i, openSection): label "..."
  let r = place(0, CtrlH, fill = true)
  let hid = idOf("accordion:" & title & $index)  # (one id: a second `idOf` is another)
  let hit = interact(hid, r)
  if hit.focused: ui.takesEnter = true
  if hit.clicked or (hit.focused and (keyHit(KeyEnter) or keyHit(KeySpace))):
    open = if open == index: -1 else: index
    ui.redraw = true
  let isOpen = open == index
  buttonFace(r, false, 1, hot = hovered(r), rounded = false)
  arrow(r.x + dp(10), r.y + r.h div 2, if isOpen: dDown else: dRight, th.text)
  drawLabel(r.x + dp(20), r.y + (r.h - FontH) div 2, title, th.text, bold = isOpen)
  if hit.focused: focusDots(inset(r, 3))
  if accessOn:
    accessNode(arButton, title, id = hid, r = r,
               states = {asExpandable} + (if isOpen: {asExpanded} else: {}))
  isOpen

# ---- a timeline ----------------------------------------------------------------------------------------

proc timeline*(items: openArray[tuple[time, title, detail: string]]; current = -1) =
  ## Events down a line: their time, a dot (the `current` one filled), the
  ## title and a line of detail.
  let st = style(size = 0.9)
  for i, it in items:
    let h = FontH * (if it.detail.len > 0: 2 else: 1) + dp(8)
    let r = place(0, h, fill = true)
    let tx = r.x + dp(70)
    text(r.x, r.y, it.time, th.gray, st)
    if i < items.high: vline(tx, r.y + dp(6), h, th.shadow)
    if i > 0: vline(tx, r.y - dp(2), dp(8), th.shadow)
    let dot = rect(tx - dp(4), r.y + dp(2), dp(9), dp(9))
    fill(dot, if i == current: th.select else: th.field)
    box(dot, th.frame)
    drawLabel(tx + dp(12), r.y, it.title, th.text, bold = i == current)
    if it.detail.len > 0: text(tx + dp(12), r.y + FontH, it.detail, th.gray, st)

# ---- a pill ---------------------------------------------------------------------------------------------

proc pill*(text: string; c = Color()) =
  ## A short word in a colored, rounded tag ("Paid", "Overdue", "New").
  let st = style(size = 0.85, bold = true)
  let col = if c.a == 0: th.select else: c
  let w = textWidth(text, st) + dp(12)
  let h = lineHeight(st) + dp(2)
  let r = place(w, max(h, FontH))
  let pr = rect(r.x, r.y + (r.h - h) div 2, w, h)
  fill(rect(pr.x + 1, pr.y, pr.w - 2, pr.h), col)
  vline(pr.x, pr.y + 1, pr.h - 2, col)
  vline(pr.x + pr.w - 1, pr.y + 1, pr.h - 2, col)
  text(pr.x + dp(6), pr.y + dp(1), text, contrastInk(col, color(255, 255, 255), color(0, 0, 0)), st)

# ---- a snack bar: what just happened, and Undo ---------------------------------------------------

var snack: tuple[msg, action: string; until: int; id: int]

proc showSnackbar*(msg: string; action = "Undo"; ms = 8000) =
  ## Shows a bar at the bottom of the window saying what was just done
  ## ("3 messages deleted") with one action (`action`, "" none) for `ms`
  ## milliseconds: the Undo of today's apps. `snackbar` draws it and says
  ## when the action was clicked.
  inc snack.id
  snack = (msg, action, ui.now + ms, snack.id)
  ui.redraw = true

proc hideSnackbar*() =
  ## Takes the bar (`showSnackbar`) away now.
  snack.msg = ""
  ui.redraw = true

proc snackbarShown*(): bool = snack.msg.len > 0 and ui.now < snack.until
  ## The bar (`showSnackbar`) is on screen.

proc snackbarLeft*(): int = max(0, snack.until - ui.now)
  ## Milliseconds before the bar goes away by itself.

proc snackbar*(): bool =
  ## Draws the bar `showSnackbar` asked for (call it once a frame, after the
  ## window's content); true the frame its action is clicked (or Ctrl+Z
  ## pressed and no text box took it), which also takes the bar away.
  if snack.msg.len == 0: return false
  if ui.now >= snack.until:
    snack.msg = ""
    ui.redraw = true
    return false
  wakeIn(min(500, snack.until - ui.now))
  # (drawn last on the window's own layer: over its content, under dialogs,
  # and it takes clicks and keys as the window does)
  let pad = dp(10)
  let aw = if snack.action.len > 0: textWidth(snack.action, true) + 2 * pad else: 0
  let w = min(ui.w - dp(24), textWidth(snack.msg) + aw + 3 * pad)
  let h = FontH + 2 * pad
  let r = rect(ui.safe.left + dp(12), ui.bottom - h - dp(10), w, h)
  ui.overlayNow = r
  fill(rect(r.x + 3, r.y + 3, r.w, r.h), th.shadow)
  fill(r, color(48, 48, 48))
  box(r, th.frame)
  text(r.x + pad, r.y + pad, ellipsize(snack.msg, r.w - aw - 2 * pad), color(255, 255, 255))
  if accessOn: accessBegin(arAlert, snack.msg, r, idOf("snackbar-msg" & $snack.id))
  defer:
    if accessOn: accessEnd()
  if snack.action.len > 0:
    let ar = rect(r.x + r.w - aw, r.y, aw, r.h)
    let aid = idOf("snackbar" & $snack.id)     # (one id: a second `idOf` is another)
    let hit = interact(aid, ar, focusable = false)
    if hit.hover: fill(inset(ar, 2), color(80, 80, 80))
    text(ar.x + pad, r.y + pad, snack.action, color(120, 190, 255), true)
    if accessOn: accessNode(arButton, snack.action, id = aid, r = ar)
    let key = canInput() and not ui.keyUsed and ui.key == KeyZ and CtrlPressed in ui.mods
    if hit.clicked or key:
      if key: ui.keyUsed = true
      snack.msg = ""
      ui.redraw = true
      return true
  false

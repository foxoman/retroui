## Controls from phones, for phones and desktops alike: a navigation bar, wheel pickers (a
## day, a time), a number with - and + on either side, page dots, rows with actions behind
## them, an action sheet, a bottom sheet and a popover. Drawn in every look (Classic, Glass,
## Matte, Gloss); a mouse, the keyboard, fingers and screen readers work them all.
##
## .. code-block:: nim
##   case navBar("Settings", back = "Home", action = "Edit")
##   of npBack: nav.pop()
##   of npAction: editing = true
##   of npNone: discard
##   wheelPicker(["Small", "Medium", "Large"], size)
##   dateWheels(birthday)
##   quantity(cups, 1, 12)
##   pageDots(page, 5)
##   let hit = swipeRow("Invoice 1042", ["Archive", "Delete"], detail = "Al Noor Trading")
##   if hit.action == 1: deleteInvoice()
##   let pick = actionSheet(shareOpen, "Share", ["Mail", "Messages", "Delete"], destructive = 2)
##   bottomSheet(filtersOpen, "Filters"):
##     checkbox "Paid only", paidOnly
##   popover(infoOpen, infoAt, 240):
##     label "Saved two minutes ago"
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net

import std/[tables, math, unicode]
import gfx, core, widgets, business, desktop, extras
import uirelays/input

template th: untyped = ui.theme

const white = color(255, 255, 255)
const black = color(0, 0, 0)

proc onDarkWindow(): bool {.inline.} = lumaOfColor(th.window) < 128

proc accentText(): Color =
  ## (the highlight as the color of text: lighter on a dark window, where it reads dim)
  if onDarkWindow(): mixColor(accentColor(), white, 0.4) else: accentColor()

proc offIf(enabled: bool): set[AccessState] {.inline.} =
  if enabled: {} else: {asDisabled}

proc chevron(cx, cy, size: int; left: bool; c: Color; weight: float) =
  ## (a chevron `size` tall, its point to the left or the right: drawn, not a letter, so a
  ## right-to-left interface turns it round with the rest)
  let h = float(size) / 2
  let w = h * 0.62
  let x = float(cx)
  let y = float(cy)
  let tip = if left: x - w / 2 else: x + w / 2
  let back = if left: x + w / 2 else: x - w / 2
  thickLine(back, y - h, tip, y, weight, c)
  thickLine(tip, y, back, y + h, weight, c)

proc fade(r: Rect; c: Color; aTop, aFoot: int) =
  ## (`c` over `r`, from `aTop` opaque at its top to `aFoot` at its foot: a line at a time)
  if r.h <= 0: return
  for k in 0 ..< r.h:
    let a = aTop + (aFoot - aTop) * k div max(1, r.h - 1)
    if a > 0: hline(r.x, r.y + k, r.w, withAlpha(c, a))

proc sign(cx, cy, size: int; plus: bool; c: Color) =
  ## (a minus or a plus, `size` wide, in rectangles: sharp at every size)
  let t = max(1, dp(2))
  fill(rect(cx - size div 2, cy - t div 2, size, t), c)
  if plus: fill(rect(cx - t div 2, cy - size div 2, t, size), c)

# ---- the navigation bar -----------------------------------------------------------------------

type NavPick* = enum
  ## What was pressed in a `navBar`.
  npNone,      ## nothing
  npBack,      ## its Back button (or Alt+Left)
  npAction     ## its button at the end

proc bleed(cell: Rect): Rect =
  ## (a bar placed at the content's own edges: drawn from one side of the window to the other,
  ## up to the bars over it or to the cell before it -- as a phone's bars are)
  result = cell
  if cell.x <= ui.winX + ui.safe.left + Pad + 1 and
     cell.x + cell.w >= ui.winX + ui.w - ui.safe.right - Pad - 1:
    result.x = ui.winX
    result.w = ui.w
    let top = if cell.y - Pad <= ui.barY + 1: ui.barY else: cell.y - Gap
    result.h += cell.y - top
    result.y = top

proc navButton(id: Id; r: Rect; label: string; back, primary: bool; bg: Color; enabled: bool): bool =
  ## (a bar's button: 3.1's raised one; Glass its label alone in the highlight; Matte the same,
  ## the primary one filled with it; Gloss a bordered one darker than the bar, Back with a
  ## point, its label white)
  var hit = interact(id, r, enabled = enabled)
  if enabled:
    spaceKey(id, hit)
    if hit.focused:
      ui.takesEnter = true
      if keyHit(KeyEnter): hit.clicked = true
  var ink: Color
  if glossLook():
    glossBarButton(r, hit.down, back = back, done = primary)
    let st = style(bold = true, size = 0.9)
    let tw = labelWidth(label, st)
    let x0 = if back: r.x + min(r.h div 2, dp(13)) + (r.w - min(r.h div 2, dp(13)) - tw) div 2 - dp(2)
             else: r.x + (r.w - tw) div 2
    let ty = r.y + (r.h - lineHeight(st)) div 2
    drawLabel(x0, ty - 1, label, withAlpha(black, 100), st)
    drawLabel(x0, ty, label, if enabled: white else: mixColor(white, bg, 0.5), st)
    if hit.focused: focusDots(inset(r, 3))
    if accessOn: accessNode(arButton, label, id = id, r = r, states = offIf(enabled))
    return hit.clicked
  elif matteLook() and primary:
    roundRect(r, float(dp(2)), if hit.down: mixColor(accentColor(), black, 0.2) else: accentColor())
    ink = accentInk()
  elif glassLook():
    if hit.down or hit.showsHover:
      roundRect(r, glassRadius(r), withAlpha(th.text, if hit.down: 40 else: 18))
    ink = accentText()
  else:
    buttonFace(r, hit.down, 1, hot = enabled and hit.hover)
    ink = th.text
  if not enabled: ink = mixColor(ink, bg, 0.55)
  let cw = if back: dp(11) else: 0
  let tw = labelWidth(label)
  let x0 = r.x + (r.w - tw - cw) div 2
  if back:
    chevron(x0 + dp(3), r.y + r.h div 2, max(dp(9), FontH * 2 div 3), true, ink,
            max(1.5, float(dp(2))))
  drawLabel(x0 + cw, r.y + (r.h - FontH) div 2, label, ink)
  if hit.focused: focusDots(inset(r, 2))
  if accessOn: accessNode(arButton, label, id = id, r = r, states = offIf(enabled))
  hit.clicked

proc navBar*(title: string; back = ""; action = ""; enabled = true; done = false): NavPick =
  ## A phone's navigation bar, the width of the row: the page's `title` in the middle, bold;
  ## a Back button before it (`back`: its label, a chevron before it; "" for none) and a
  ## button after it (`action`). Returns what was pressed. Alt+Left is Back too. Classic: a
  ## raised bar; Glass and Matte: the title bar's, its buttons' labels in the highlight; Gloss:
  ## the glossy blue-gray bar, white title, bordered buttons, Back with a point. `done`: the
  ## action is the one that finishes the page (Done, Save): blue in Gloss, filled in Matte.
  ## (With a `PageStack`, `pageHeader` says Back by itself.)
  let h = if fingers(): dp(44) else: max(dp(32), CtrlH + dp(8))
  let cell = place(0, h, fill = true)
  let full = bleed(cell)
  let r = rect(full.x, cell.y, full.w, h)     # (its buttons and title: in the cell's height)
  let key = "navbar:" & title
  let bg = if glassLook(): titleColors(true).bg else: th.face
  let fg = if glassLook(): titleColors(true).fg else: th.text
  if glassLook():
    titleBar(full, true)
    if glossLook():
      # (a soft shadow under it on the page, as the bar stood over it)
      for k in 0 ..< max(2, dp(3)):
        hline(full.x, full.y + full.h + k, full.w, withAlpha(color(0, 0, 0), max(6, 46 - 16 * k)))
  else:
    fill(full, th.face)
    hline(full.x, full.y, full.w, th.light)
    hline(full.x, full.y + full.h - 2, full.w, th.shadow)
    hline(full.x, full.y + full.h - 1, full.w, th.frame)
  let bh = if glossLook(): min(h - dp(10), if fingers(): dp(30) else: CtrlH)
           else: h - (if fingers(): dp(12) else: dp(8))
  let by = r.y + (h - bh) div 2
  let gloss = glossLook()
  let bst = style(bold = true, size = 0.9)
  let leftW = if back.len == 0: 0
              elif gloss: labelWidth(back, bst) + min(bh div 2, dp(13)) + dp(12)
              else: labelWidth(back) + dp(11) + dp(18)
  let rightW = if action.len == 0: 0
               elif gloss: max(dp(48), labelWidth(action, bst) + dp(20))
               else: labelWidth(action) + dp(18)
  if back.len > 0 and navButton(idOf(key & ":back"), rect(r.x + dp(6), by, leftW, bh), back, true,
                                false, bg, enabled):
    result = npBack
  if action.len > 0 and navButton(idOf(key & ":action"), rect(r.x + r.w - dp(6) - rightW, by, rightW, bh),
                                  action, false, done, bg, enabled):
    result = npAction
  # the title in the middle of the bar, short of the buttons
  let st = if glossLook(): style(bold = true, size = 1.2) else: style(bold = true)
  let t = ellipsize(tr(title), max(dp(24), r.w - 2 * (max(leftW, rightW) + dp(12))), st)
  let tw = textWidth(t, st)
  let tx = r.x + (r.w - tw) div 2
  let ty = r.y + (h - lineHeight(st)) div 2
  if glossLook(): text(tx, ty - 1, t, withAlpha(black, 110), st)    # (pressed in, as Gloss writes on bars)
  text(tx, ty, t, fg, st)
  if back.len > 0 and enabled and result == npNone and canInput() and not ui.keyUsed and
     ui.popup == 0 and hotkeyPressed("Alt+Left"):
    ui.keyUsed = true
    result = npBack
  if accessOn: accessNode(arHeading, title, r = r)
  ui.lastId = 0
  ui.lastRect = cell

# ---- wheel pickers -----------------------------------------------------------------------------

type WheelTurn = object
  pos: float              # the row at the band: between two while it turns
  vel: float              # rows a second, flung
  target: int             # the row it comes to rest on
  fromY, lastY, lastT, t: int
  fromPos: float
  dragging, moved: bool
  sel: int                # (`sel` as it was: the app may change it)

var
  turns: Table[Id, WheelTurn]
  wheelGroupOn: bool                                 # (wheels drawn now go in one frame)
  wheelRects: seq[tuple[r: Rect; focused: bool]]     # (... these, so far)

proc drumColor(): Color =
  ## (a wheel's face: white, as phones had it; the field's in a dark scheme)
  if glossLook() and not onDarkWindow(): color(252, 252, 252) else: th.field

proc drumFrame(): int =
  ## (how thick a wheel's frame is: Gloss's a dark band round it)
  if glossLook(): dp(5) else: 2

proc drumFace(r: Rect; enabled, focused: bool) =
  ## (a wheel's frame and face: Gloss's dark frame round a white drum)
  if glossLook():
    roundRectShaded(r, float(dp(6)), color(92, 94, 100), color(18, 18, 20))
    fill(inset(r, drumFrame()), drumColor())
  elif glassLook(): fieldFace(r, th.field, enabled, focused)
  else: fieldFace(r, th.field, enabled)

proc drumOverlay(inner, band: Rect; enabled, focused: bool) =
  ## (over the rows: the drum darker or fading toward its top and foot; the band across it)
  pushClip(inner)
  let third = inner.h div 3
  let dark = onDarkWindow()
  if glossLook():
    # (a drum: darker toward its top and its foot; the band a pane of blue glass over it)
    fade(rect(inner.x, inner.y, inner.w, third), black, if dark: 170 else: 110, 0)
    fade(rect(inner.x, inner.y + inner.h - third, inner.w, third), black, 0, if dark: 170 else: 110)
    roundRectShaded(band, 0, withAlpha(glossTone(0.15, 0.93), 110), glossTone(0.49, 0.75))
    hline(band.x, band.y, band.w, withAlpha(glossTone(0.2, 0.59), 220))
    hline(band.x, band.y + 1, band.w, withAlpha(white, 120))
    hline(band.x, band.y + band.h - 1, band.w, withAlpha(glossTone(0.36, 0.43), 220))
  elif glassLook():
    # (the rows fading into the field toward its top and its foot)
    fade(rect(inner.x, inner.y, inner.w, third), th.field, 210, 0)
    fade(rect(inner.x, inner.y + inner.h - third, inner.w, third), th.field, 0, 210)
    if matteLook():
      let lw = max(1, dp(1))
      fill(rect(band.x, band.y, band.w, lw), accentColor())
      fill(rect(band.x, band.y + band.h - lw, band.w, lw), accentColor())
    else:
      roundRect(rect(band.x + dp(3), band.y, band.w - dp(6), band.h), float(dp(6)),
                withAlpha(th.fieldText, if dark: 30 else: 16))
  else:
    hline(band.x, band.y, band.w, th.frame)
    hline(band.x, band.y + band.h - 1, band.w, th.frame)
    if focused: focusDots(inset(band, 2))
  popClip()

proc wheelRowH*(): int =
  ## The height of a wheel picker's row (taller for fingers).
  if fingers(): dp(34) else: ItemH + dp(7)

proc wheelImpl(items: openArray[string]; gen: proc (i: int): string; count: int; sel: var int;
               rows, w: int; enabled: bool; key, label: string): bool =
  template itemAt(i: int): string = (if gen != nil: gen(i) else: items[i])
  let n = max(0, count)
  let rows = max(3, rows or 1)                 # (odd: a row in the middle)
  let rh = wheelRowH()
  var ww = w
  if ww <= 0:
    if gen == nil:
      for s in items: ww = max(ww, textWidth(s))
    elif n > 0:
      for i in [0, n - 1, clamp(sel, 0, n - 1)]: ww = max(ww, textWidth(itemAt(i)))
    ww += dp(30)
  let r = place(ww, rh * rows + 4)
  let id = if key.len > 0: idOf("wheel:" & key) else: idOf(sel, "wheel")
  let hit = interact(id, r, enabled = enabled and n > 0)
  # (in a group: its face alone, the group's frame and band round them all at its end)
  let grouped = wheelGroupOn and glassLook()
  if grouped:
    fill(r, drumColor())
    wheelRects.add (r, hit.focused)
  else: drumFace(r, enabled, hit.focused)
  if n == 0: return
  sel = clamp(sel, 0, n - 1)
  var t = turns.getOrDefault(id, WheelTurn(pos: float(sel), target: sel, sel: sel, t: ui.now))
  if not t.dragging and sel != t.sel:             # (the app set it: there at once)
    t.target = sel
    t.pos = float(sel)
    t.vel = 0
  let dt = clamp(float(ui.now - t.t) / 1000, 0.0, 0.1)
  t.t = ui.now
  let cy = r.y + r.h div 2
  var picked = -1
  if enabled:
    if hit.down and ui.pressed:
      t.dragging = true
      t.moved = false
      t.fromY = ui.my
      t.fromPos = t.pos
      t.vel = 0
      t.lastY = ui.my
      t.lastT = ui.now
    if t.dragging:
      if ui.active == id and ui.mouseDown:
        ui.dragsActive = true
        if abs(ui.my - t.fromY) > dp(4): t.moved = true
        if t.moved:
          var p = t.fromPos - float(ui.my - t.fromY) / float(rh)
          # (past either end: held back, as by a rubber band)
          if p < 0: p = p / 3
          elif p > float(n - 1): p = float(n - 1) + (p - float(n - 1)) / 3
          t.pos = p
          let ms = ui.now - t.lastT
          if ms > 0 and ui.my != t.lastY:
            let v = -float(ui.my - t.lastY) / float(rh) / (float(ms) / 1000)
            t.vel = if ms > 80: v else: t.vel * 0.3 + v * 0.7
            t.lastY = ui.my
            t.lastT = ui.now
      else:
        # let go: a click brings the row under it to the band; a drag flings it on
        t.dragging = false
        if not t.moved:
          picked = clamp(int(round(t.pos + float(ui.my - cy) / float(rh))), 0, n - 1)
          t.vel = 0
        elif not smoothScrolling or ui.now - t.lastT > 100 or abs(t.vel) < 2.0:
          t.vel = 0
          picked = clamp(int(round(t.pos)), 0, n - 1)
        else:
          t.vel = clamp(t.vel, -40.0, 40.0)
    if hit.hover and canInput() and ui.wheel != 0 and not ui.wheelUsed:
      ui.wheelUsed = true
      picked = clamp(t.target - ui.wheel, 0, n - 1)
      t.vel = 0
    if hit.focused and canInput() and not ui.keyUsed:
      var k = int.low
      case ui.key
      of KeyUp: k = t.target - 1
      of KeyDown: k = t.target + 1
      of KeyPageUp: k = t.target - (rows - 1)
      of KeyPageDown: k = t.target + (rows - 1)
      of KeyHome: k = 0
      of KeyEnd: k = n - 1
      else: discard
      if k != int.low:
        ui.keyUsed = true
        picked = clamp(k, 0, n - 1)
        t.vel = 0
      elif ui.typed.len > 0 and ui.typed[0] > ' ':
        # (a letter typed: the next row that starts with it)
        let want = ui.typed.runeAt(0).toLower
        for j in 1 .. n:
          let i = (t.target + j) mod n
          let s = itemAt(i)
          if s.len > 0 and s.runeAt(0).toLower == want:
            picked = i
            t.vel = 0
            break
  if accessOn and enabled and accessValueFor(id): picked = clamp(int(round(accessSet.num)), 0, n - 1)
  if picked >= 0:
    t.target = picked
    if not smoothScrolling: t.pos = float(picked)
  # turning by itself: flung, slowing, then settling on a row
  if not t.dragging:
    if t.vel != 0:
      t.pos += t.vel * dt
      t.vel *= pow(0.03, dt)
      if t.pos < -0.4 or t.pos > float(n) - 0.6 or abs(t.vel) < 2.0:
        t.vel = 0
        t.target = clamp(int(round(t.pos)), 0, n - 1)
        picked = t.target
    if t.vel == 0:
      let d = float(t.target) - t.pos
      if abs(d) < 0.01: t.pos = float(t.target)
      else: t.pos += d * min(1.0, dt * 14)
    if t.vel != 0 or t.pos != float(t.target): wakeIn(16)
  if picked >= 0 and picked != sel:
    sel = picked
    result = true
  t.sel = sel
  turns[id] = t
  # the rows, round the wheel: those away from the band closer together and fainter
  let inner = if grouped: r else: inset(r, drumFrame())
  let band = rect(inner.x, cy - rh div 2, inner.w, rh)
  let classic = not glassLook()
  if classic: fill(band, if enabled: th.select else: mixColor(th.field, th.gray, 0.4))
  let rad = float(inner.h) / 2              # (the drum's radius: its edge a quarter turn from the band)
  let fieldInk = if enabled: th.fieldText else: th.gray
  let bandInk = if not enabled: th.gray
                elif classic: th.selectText
                elif matteLook(): accentText()
                else: th.fieldText
  for pass in 0 .. 2:
    # (above the band, under it, in it: a row half in the band in two colors)
    let clip = case pass
               of 0: rect(inner.x, inner.y, inner.w, band.y - inner.y)
               of 1: rect(inner.x, band.y + band.h, inner.w, inner.y + inner.h - band.y - band.h)
               else: band
    pushClip(clip)
    let reach = rad * PI / 2 / float(rh) + 1
    for i in max(0, int(floor(t.pos - reach))) .. min(n - 1, int(ceil(t.pos + reach))):
      let ang = (float(i) - t.pos) * float(rh) / rad
      if abs(ang) >= PI / 2: continue
      let y = float(cy) + rad * sin(ang)
      let s = itemAt(i)
      let c = if pass == 2: bandInk
              else: mixColor(fieldInk, drumColor(), min(0.82, 0.3 + (1 - cos(ang)) * 0.9))
      let st = if glossLook(): style(bold = true, size = 1.15) else: TextStyle()
      text(inner.x + (inner.w - textWidth(s, st)) div 2, int(round(y)) - lineHeight(st) div 2, s, c, st)
    popClip()
  if not grouped: drumOverlay(inner, band, enabled, hit.focused)
  if accessOn:
    let k = accessNode(arSpinButton, label, value = itemAt(sel), id = id, r = r, states = offIf(enabled))
    accessRange(k, 0, float(n - 1), float(sel))

proc wheelPicker*(items: openArray[string]; sel: var int; rows = 5; w = 0; enabled = true;
                  key = ""; label = ""): bool {.discardable.} =
  ## A phone's picker wheel: `items` round a drum, `sel` in the band across its middle, `rows`
  ## of them showing (odd). Drag it -- let go fast and it spins on, slowing, and stops on a row
  ## --, click a row to bring it to the band, turn the mouse wheel; the keys: Up and Down, Page
  ## Up and Down, Home and End, a letter (the next item that starts with it). `w`: its width
  ## (0: the widest item's). `key`: its own id (wheels made in a loop); `label`: the name a
  ## screen reader says. True when `sel` changed (when it comes to rest on another row).
  wheelImpl(items, nil, items.len, sel, rows, w, enabled, key, label)

proc wheelPicker*(count: int; item: proc (i: int): string; sel: var int; rows = 5; w = 0;
                  enabled = true; key = ""; label = ""): bool {.discardable.} =
  ## A wheel of `count` items made as they show (`item(i)`): a long list (years, numbers)
  ## needs no seq of them. As the other `wheelPicker`; give `w` (else it is measured from the
  ## first, the last and the chosen item).
  wheelImpl([], item, count, sel, rows, w, enabled, key, label)

proc beginWheelGroup*() =
  ## Starts a group of wheels (see `wheelGroup`).
  wheelGroupOn = true
  wheelRects.setLen(0)

proc endWheelGroup*() =
  ## Ends a `beginWheelGroup`: the frame round its wheels, the band across them.
  wheelGroupOn = false
  if wheelRects.len == 0: return
  var u = wheelRects[0].r
  for (r, _) in wheelRects:
    let x1 = max(u.x + u.w, r.x + r.w)
    let y1 = max(u.y + u.h, r.y + r.h)
    u = rect(min(u.x, r.x), min(u.y, r.y), x1 - min(u.x, r.x), y1 - min(u.y, r.y))
  # (between the wheels: the drum's color, or Gloss's frame as a line)
  for i in 1 ..< wheelRects.len:
    let a = wheelRects[i - 1].r
    let b = wheelRects[i].r
    if b.x > a.x + a.w:
      fill(rect(a.x + a.w, u.y, b.x - a.x - a.w, u.h), if glossLook(): color(48, 48, 52) else: drumColor())
  let rh = wheelRowH()
  let band = rect(u.x, u.y + u.h div 2 - rh div 2, u.w, rh)
  drumOverlay(u, band, true, false)
  if glossLook():
    let f = drumFrame()
    let o = rect(u.x - f, u.y - f, u.w + 2 * f, u.h + 2 * f)
    roundFrame(o, float(dp(6)), float(f), color(44, 44, 48))
    hline(o.x + dp(6), o.y, o.w - 2 * dp(6), color(120, 122, 128))
    hline(u.x, u.y - 1, u.w, color(20, 20, 22))
  else:
    roundFrame(rect(u.x - 1, u.y - 1, u.w + 2, u.h + 2), float(if matteLook(): dp(2) else: dp(6)), 1,
               mixColor(th.field, th.fieldText, if onDarkWindow(): 0.34 else: 0.28))
  for (r, focused) in wheelRects:
    if focused: roundFrame(rect(r.x - 1, r.y - 1, r.w + 2, r.h + 2), float(dp(4)), 2,
                           withAlpha(accentColor(), 190))
  wheelRects.setLen(0)

template wheelGroup*(body: untyped) =
  ## Wheels side by side as one picker, the way phones show a day or a time: one frame round
  ## them, one band across them (Classic: each in its own box).
  ##
  ## .. code-block:: nim
  ##   wheelGroup:
  ##     wheelPicker(sizes, size, w = 110)
  ##     wheelPicker(colors, color, w = 90)
  beginWheelGroup()
  try:
    row:
      body
  finally:
    endWheelGroup()

proc dayLabel(i: int): string = $(i + 1)

proc twoDigits(i: int): string =
  if i < 10: "0" & $i else: $i

proc dateWheels*(d: var Date; years = 1900 .. 2100; enabled = true): bool {.discardable.} =
  ## A day as a phone picks one: wheels for the day, the month and the year side by side, in
  ## the order `dateStyle` writes them. True when `d` changed. (A day the month has not --
  ## 31 with April -- becomes its last.)
  if not valid(d): d = today()
  var day = d.day - 1
  var mon = d.month - 1
  var yr = clamp(d.year, years.a, years.b) - years.a
  let k = "datewheels:" & $cast[uint](addr d)
  let first = years.a
  var monthW = 0
  for m in monthNames: monthW = max(monthW, textWidth(tr(m)))
  let order = case dateStyle
              of dsDMY: [0, 1, 2]
              of dsMDY: [1, 0, 2]
              of dsISO: [2, 1, 0]
  var changed = false
  wheelGroup:
    for part in order:
      case part
      of 0:
        accessName(tr("Day"))
        if wheelPicker(daysInMonth(d.year, d.month), dayLabel, day, w = textWidth("30") + dp(30),
                       enabled = enabled, key = k & "d", label = tr("Day")): changed = true
      of 1:
        accessName(tr("Month"))
        if wheelPicker(12, proc (i: int): string = tr(monthNames[i]), mon, w = monthW + dp(30),
                       enabled = enabled, key = k & "m", label = tr("Month")): changed = true
      else:
        accessName(tr("Year"))
        if wheelPicker(years.b - years.a + 1, proc (i: int): string = $(first + i), yr,
                       w = textWidth("2000") + dp(30), enabled = enabled, key = k & "y",
                       label = tr("Year")): changed = true
  if changed:
    let y = years.a + yr
    let m = mon + 1
    let nd = date(y, m, min(day + 1, daysInMonth(y, m)))
    if nd != d:
      d = nd
      result = true

proc timeWheels*(h, m: var int; minuteStep = 1; hours12 = false; enabled = true): bool {.discardable.} =
  ## A time as a phone picks one: wheels for the hour (0 to 23; or 1 to 12 and AM/PM with
  ## `hours12`) and the minute (by `minuteStep`). True when it changed.
  let step = clamp(minuteStep, 1, 30)
  let k = "timewheels:" & $cast[uint](addr h)
  var hi = if hours12: h mod 12 else: clamp(h, 0, 23)
  var half = if h >= 12: 1 else: 0
  var mi = clamp(m, 0, 59) div step
  var changed = false
  wheelGroup:
    accessName(tr("Hours"))
    if hours12:
      if wheelPicker(12, proc (i: int): string = (if i == 0: "12" else: $i), hi,
                     w = textWidth("12") + dp(30), enabled = enabled, key = k & "h",
                     label = tr("Hours")): changed = true
    elif wheelPicker(24, twoDigits, hi, w = textWidth("00") + dp(30), enabled = enabled,
                     key = k & "h", label = tr("Hours")): changed = true
    accessName(tr("Minutes"))
    if wheelPicker(60 div step, proc (i: int): string = twoDigits(i * step), mi,
                   w = textWidth("00") + dp(30), enabled = enabled, key = k & "m",
                   label = tr("Minutes")): changed = true
    if hours12:
      if wheelPicker(["AM", "PM"], half, w = max(textWidth("AM"), textWidth("PM")) + dp(30),
                     enabled = enabled, key = k & "p", label = "AM/PM"): changed = true
  if changed:
    let nh = if hours12: hi + 12 * half else: hi
    let nm = mi * step
    if nh != h or nm != m:
      h = nh
      m = nm
      result = true

# ---- a number with - and + ---------------------------------------------------------------------

proc quantity*(v: var int; lo, hi: int; step = 1; w = 0; enabled = true; label = ""): bool {.discardable.} =
  ## A number between a - and a + (a phone's stepper: how many in a basket, a text's size).
  ## Click or tap either -- held, it goes on --; the keys: Up and Down (Right and Left too),
  ## + and -, Page Up and Down (ten steps), Home and End; the mouse wheel over it. `lo` and
  ## `hi` bound it; `label`: the name a screen reader says. True when `v` changed.
  let gloss = glossLook()
  let bh = if gloss and fingers(): dp(29) else: CtrlH
  let bw = if gloss: max(bh * 3 div 2, dp(40)) else: max(bh, dp(30))
  let vw = max(textWidth($lo), textWidth($hi)) + dp(18)
  let r = place(if w > 0: w else: 2 * bw + vw, bh)
  let id = if label.len > 0: idOf("quantity:" & label) else: idOf(v, "quantity")
  # (Gloss: the number, then the stepper of its time -- - and + in one piece)
  let minus = if gloss: rect(r.x + r.w - 2 * bw, r.y, bw, r.h) else: rect(r.x, r.y, bw, r.h)
  let plus = rect(r.x + r.w - bw, r.y, bw, r.h)
  let mid = if gloss: rect(r.x, r.y, r.w - 2 * bw, r.h) else: rect(minus.x + minus.w, r.y, r.w - 2 * bw, r.h)
  let hm = interact(id + 1, minus, focusable = false, enabled = enabled and v > lo)
  let hp = interact(id + 2, plus, focusable = false, enabled = enabled and v < hi)
  let hit = interact(id, r, enabled = enabled)
  var st = state(id)
  var nv = v
  if enabled:
    if (hm.down or hp.down) and ui.pressed:
      ui.focus = id
      st.aux2 = ui.now
      nv += (if hp.down: step else: -step)
    elif hm.down or hp.down:
      # (held: on, a step every 80 ms after the first 400)
      if heldFor() > 400 and ui.now - st.aux2 >= 80:
        st.aux2 = ui.now
        nv += (if hp.down: step else: -step)
      wakeIn(40)
    if hit.hover and canInput() and ui.wheel != 0 and not ui.wheelUsed:
      ui.wheelUsed = true
      nv += ui.wheel * step
    if hit.focused and canInput() and not ui.keyUsed:
      let fwd = if ui.rtl: KeyLeft else: KeyRight
      let bwd = if ui.rtl: KeyRight else: KeyLeft
      if ui.key == KeyUp or ui.key == fwd: nv += step; ui.keyUsed = true
      elif ui.key == KeyDown or ui.key == bwd: nv -= step; ui.keyUsed = true
      elif ui.key == KeyPageUp: nv += 10 * step; ui.keyUsed = true
      elif ui.key == KeyPageDown: nv -= 10 * step; ui.keyUsed = true
      elif ui.key == KeyHome: nv = lo; ui.keyUsed = true
      elif ui.key == KeyEnd: nv = hi; ui.keyUsed = true
      elif ui.typed == "+" or ui.typed == "=": nv += step
      elif ui.typed == "-": nv -= step
    if accessOn and accessValueFor(id): nv = int(round(accessSet.num))
  state(id) = st
  nv = clamp(nv, lo, hi)
  if nv != v:
    v = nv
    result = true
  # (3.1: two raised buttons, the number sunk between them; the newer looks: two faces, the
  # number between them on the window)
  let size = max(dp(8), FontH * 3 div 5)
  if gloss:
    # (one rounded piece, light gray lit from above, a line between its halves; a half pressed
    # darker)
    let s = rect(minus.x, r.y, 2 * bw, r.h)
    let rad = float(min(dp(6), r.h div 2))
    let dark = onDarkWindow()
    if not dark: roundRect(rect(s.x, s.y + 1, s.w, s.h), rad, withAlpha(white, 150))
    roundRect(s, rad, if dark: black else: color(140, 142, 148))
    for (b, hh) in [(minus, hm), (plus, hp)]:
      pushClip(b)
      let f = inset(s, 1)
      if dark:
        glossTwoTone(f, rad - 1, color(96, 98, 104), color(66, 68, 74), color(52, 54, 58),
                     color(36, 38, 42))
      elif hh.down:
        glossTwoTone(f, rad - 1, color(206, 206, 210), color(186, 186, 192), color(172, 172, 178),
                     color(160, 160, 166))
      else:
        glossTwoTone(f, rad - 1, white, color(242, 242, 244), color(229, 229, 233), color(212, 212, 218))
      popClip()
    vline(plus.x, s.y + 1, s.h - 2, if dark: black else: color(140, 142, 148))
    for (b, plusSign, on) in [(minus, false, v > lo), (plus, true, v < hi)]:
      let ink = if not (enabled and on): (if dark: color(110, 110, 116) else: color(170, 170, 176))
                elif dark: white else: color(70, 72, 78)
      if not dark: sign(b.x + b.w div 2, b.y + b.h div 2 + 1, size + dp(2), plusSign, withAlpha(white, 200))
      sign(b.x + b.w div 2, b.y + b.h div 2, size + dp(2), plusSign, ink)
  else:
    for (b, hh, plusSign, on) in [(minus, hm, false, v > lo), (plus, hp, true, v < hi)]:
      buttonFace(b, hh.down, 1, hot = enabled and on and hh.hover)
      let d = if hh.down and not glassLook(): 1 else: 0
      sign(b.x + b.w div 2 + d, b.y + b.h div 2 + d, size, plusSign,
           if enabled and on: th.text else: th.gray)
  let s = $v
  if not glassLook(): fieldFace(rect(mid.x - 1, mid.y, mid.w + 2, mid.h), th.field, enabled)
  let ink = if not enabled: th.gray elif glassLook(): th.text else: th.fieldText
  let tx = mid.x + (mid.w - textWidth(s, true)) div 2
  let ty = mid.y + (mid.h - FontH) div 2
  text(tx, ty, s, ink, true)
  if hit.focused:
    if glassLook(): roundFrame(inset(r, -2), glassRadius(r) + 2, 2, withAlpha(accentColor(), 170))
    else: focusDots(rect(tx - 3, ty - 1, textWidth(s, true) + 6, FontH + 2))
  if accessOn:
    let k = accessNode(arSpinButton, label, value = s, id = id, r = r, states = offIf(enabled))
    accessRange(k, float(lo), float(hi), float(v), float(step))
  ui.lastId = id
  ui.lastRect = r

# ---- page dots ---------------------------------------------------------------------------------

proc pageDots*(page: var int; pages: int; enabled = true; label = "Page"): bool {.discardable.} =
  ## A phone's page dots, in the middle of the row: one a page, the one shown filled. Click a
  ## dot for its page, either side of them for the page before or after; the keys: Left and
  ## Right, Home and End. `page` from 0. True when it changed.
  if pages <= 0: return
  page = clamp(page, 0, pages - 1)
  let d = if fingers(): dp(8) else: dp(7)
  let gap = if fingers(): dp(18) else: dp(14)
  let h = if fingers(): dp(30) else: dp(20)
  let r = place(gap * pages + dp(16), h, fill = true)
  let id = idOf(page, "pagedots")
  let hit = interact(id, r, enabled = enabled)
  let x0 = r.x + (r.w - gap * pages) div 2
  var np = page
  if enabled:
    if hit.clicked:
      if ui.mx >= x0 and ui.mx < x0 + gap * pages: np = (ui.mx - x0) div gap
      elif ui.mx < x0: np = page - 1
      else: np = page + 1
    if hit.focused and canInput() and not ui.keyUsed:
      let fwd = if ui.rtl: KeyLeft else: KeyRight
      let bwd = if ui.rtl: KeyRight else: KeyLeft
      if ui.key == fwd: inc np; ui.keyUsed = true
      elif ui.key == bwd: dec np; ui.keyUsed = true
      elif ui.key == KeyHome: np = 0; ui.keyUsed = true
      elif ui.key == KeyEnd: np = pages - 1; ui.keyUsed = true
    if accessOn and accessValueFor(id): np = int(round(accessSet.num)) - 1
  np = clamp(np, 0, pages - 1)
  if np != page:
    page = np
    result = true
  let cur = if not enabled: th.gray
            elif glassLook() and not glossLook(): accentText()
            else: th.text
  let other = mixColor(th.text, th.window, if enabled: 0.72 else: 0.82)
  let cy = float(r.y + h div 2)
  for i in 0 ..< pages:
    let cx = float(x0 + gap * i + gap div 2)
    if i == page:
      disc(cx, cy, float(d) / 2, cur)
    elif not glassLook():
      # (3.1: the others hollow)
      disc(cx, cy, float(d) / 2, th.text)
      disc(cx, cy, float(d) / 2 - 1.2, th.window)
    else:
      disc(cx, cy, float(d) / 2, other)
  if hit.focused: focusDots(rect(x0 - dp(3), r.y + 1, gap * pages + dp(6), h - 2))
  if accessOn:
    let k = accessNode(arSlider, label, value = $(page + 1) & " / " & $pages, id = id, r = r,
                       states = offIf(enabled))
    accessRange(k, 1, float(pages), float(page + 1))

# ---- rows with actions behind them -------------------------------------------------------------

type SwipeHit* = object
  ## What happened to a `swipeRow`.
  clicked*: bool     ## the row was clicked or tapped (or Enter on it)
  action*: int       ## the action picked behind it (-1: none)

var
  swipeOpen: Id                                        # (the row whose actions show: one at a time)
  swipeDrag: tuple[id: Id; x, y, off, mode: int]       # (the row being dragged; mode 1 across, 2 up or down)

proc swipeRow*(title: string; actions: openArray[string]; detail = ""; glyph = "";
               colors: openArray[Color] = []; back = Color(); key = ""): SwipeHit =
  ## A list's row with actions behind it, as phones have them (Archive, Delete): swiped
  ## left -- or dragged with the mouse --, the row slides aside and shows them; a tap on one
  ## picks it, a tap on the row closes them. With the keyboard: Left shows them (Right in a
  ## right-to-left interface), Left and Right go along them, Enter picks, Esc hides them; a
  ## right click (a long press) opens them as a menu too. `detail`: a second, gray line;
  ## `glyph`: an icon before it (an icon font's); `colors`: the actions' (the last red when
  ## none is given); `back`: the row's color (the window's). One row's actions show at a
  ## time. `key`: its own id (rows of the same title).
  result.action = -1
  let two = detail.len > 0
  let h = (if two: FontH * 2 + dp(12) else: FontH + dp(14)) + (if fingers(): dp(12) else: 0)
  let r = place(0, h, fill = true)
  let id = idOf("swiperow:" & (if key.len > 0: key else: title))
  var st = state(id)          # aux: how far it is slid now; aux2: where it goes; caret: the action keyed + 1
  let pad = dp(14)
  var total = 0
  for a in actions: total += max(dp(64), labelWidth(a) + 2 * pad)
  if swipeOpen != id and st.aux2 != 0:
    st.aux2 = 0                                  # (another row's shown: this one's go)
    st.caret = 0
  let open = st.aux2 != 0 and st.aux == st.aux2
  # the actions behind it, at its end
  var ax = r.x + r.w - total
  for i, a in actions:
    let aw = max(dp(64), labelWidth(a) + 2 * pad)
    let ar = rect(ax, r.y, aw, r.h)
    let aid = id + Id(10 + i)
    let ah = interact(aid, if open: ar else: rect(ar.x, ar.y, 0, 0), focusable = false)
    if ah.clicked:
      result.action = i
      st.aux2 = 0
      st.caret = 0
    if st.aux < 0:
      let c = if i < colors.len and colors[i].a != 0: colors[i]
              elif i == actions.high: badColor()
              else: mixColor(th.gray, th.text, 0.25)
      if glossLook(): tintedFace(inset(ar, dp(5)), c, ah.down)
      else: fill(ar, if ah.down: mixColor(c, black, 0.2) else: c)
      drawLabel(ar.x + (aw - labelWidth(a)) div 2, ar.y + (ar.h - FontH) div 2, a, white)
      if st.caret == i + 1: focusDots(inset(ar, dp(4)))
    if accessOn: accessNode(arButton, a, id = aid, r = ar)
    ax += aw
  # the row over them, slid aside by its offset
  let face = rect(r.x + st.aux, r.y, r.w, r.h)
  var hit = interact(id, rect(r.x, r.y, max(0, r.w + st.aux), r.h))
  if hit.down and ui.pressed: swipeDrag = (id, ui.mx, ui.my, st.aux, 0)
  if swipeDrag.id == id:
    if ui.mouseDown:
      let dx = ui.mx - swipeDrag.x
      let dy = ui.my - swipeDrag.y
      if swipeDrag.mode == 0 and max(abs(dx), abs(dy)) > dp(8):
        swipeDrag.mode = if abs(dx) > abs(dy) and actions.len > 0: 1 else: 2
      if swipeDrag.mode == 1:
        ui.dragsActive = true
        st.aux = clamp(swipeDrag.off + dx, -total - dp(24), 0)
    else:
      # let go: open past half way, else closed
      if swipeDrag.mode == 1:
        st.aux2 = if st.aux < -total div 2: -total else: 0
        if st.aux2 != 0: swipeOpen = id
        hit.clicked = false
      elif swipeDrag.mode == 2:
        hit.clicked = false
      swipeDrag.id = 0
  if hit.clicked:
    if st.aux2 != 0:
      st.aux2 = 0                    # (a tap on a row whose actions show: they go)
      st.caret = 0
    else:
      result.clicked = true
  # the keys
  if hit.focused and canInput() and not ui.keyUsed and actions.len > 0:
    ui.takesEnter = true              # (Enter is the row's: its click, or the action picked)
    let opens = if ui.rtl: KeyRight else: KeyLeft
    let closes = if ui.rtl: KeyLeft else: KeyRight
    if ui.key == opens:
      ui.keyUsed = true
      if st.aux2 == 0:
        st.aux2 = -total
        swipeOpen = id
        st.caret = 1
      else: st.caret = max(1, st.caret - 1)
    elif ui.key == closes and st.aux2 != 0:
      ui.keyUsed = true
      if st.caret < actions.len: inc st.caret
      else:
        st.aux2 = 0
        st.caret = 0
    elif ui.key == KeyEsc and st.aux2 != 0:
      ui.keyUsed = true
      st.aux2 = 0
      st.caret = 0
    elif (ui.key == KeyEnter or ui.key == KeySpace) and st.caret > 0:   # (Enter claimed above)
      ui.keyUsed = true
      result.action = st.caret - 1
      st.aux2 = 0
      st.caret = 0
    elif ui.key == KeyEnter:          # (Enter claimed above)
      ui.keyUsed = true
      result.clicked = true
  # sliding to where it goes
  if swipeDrag.id != id or swipeDrag.mode != 1:
    if not smoothScrolling: st.aux = st.aux2
    elif st.aux != st.aux2:
      let d = st.aux2 - st.aux
      st.aux += (if abs(d) <= 2: d else: d div 3 + (if d > 0: 1 else: -1))
      wakeIn(16)
  state(id) = st
  # the row's face (slid aside: what goes past the row's start is cut off)
  pushClip(r)
  let bg = if back.a != 0: back else: th.window
  fill(face, bg)
  if hit.down and swipeDrag.mode == 0: fill(face, withAlpha(th.select, 40))
  elif hit.showsHover: fill(face, hoverColor())
  var tx = face.x + Pad
  if glyph.len > 0:
    let gs = style(size = 1.3)
    text(tx, face.y + (face.h - lineHeight(gs)) div 2, glyph, accentColor(), gs)
    tx += textWidth(glyph, gs) + dp(10)
  let room = face.x + face.w - Pad - tx
  if two:
    let y0 = face.y + (face.h - 2 * FontH - dp(2)) div 2
    text(tx, y0, ellipsize(title, room), th.text, true)
    text(tx, y0 + FontH + dp(2), ellipsize(detail, room), th.gray)
  else:
    text(tx, face.y + (face.h - FontH) div 2, ellipsize(title, room), th.text)
  hline(tx, r.y + r.h - 1, r.x + r.w - tx, mixColor(th.window, th.text, 0.14))
  popClip()
  if hit.focused and st.caret == 0 and st.aux == 0: focusDots(inset(r, 2))
  if accessOn:
    accessNode(arListItem, title, value = detail, id = id, r = r)
  # a right click: the actions as a menu
  ui.lastId = id
  ui.lastRect = r
  if actions.len > 0:
    contextMenu:
      for i, a in actions:
        if menuItem(a): result.action = i

# ---- sheets: an action sheet, a bottom sheet, a popover ----------------------------------------

type SheetKind = enum skBottom, skMiddle, skPopover

var
  sheetSeen: Table[Id, int]                            # (the frame each was drawn last: one just opened slides in)
  sheets: seq[tuple[id: Id; was: Id; r: Rect]]         # (those being drawn, one in another)
  sheetRect: Rect                                      # (where the one begun last is: its caller draws its face)

proc beginSheet(open: var bool; id: Id; title: string; kind: SheetKind; width: int;
                anchor = Rect(); handle = false; drawFace = true; tapCloses = true;
                escCloses = true): bool =
  if not open: return false
  var st = state(id)          # aux: its content's height last frame; aux2: when it opened; scrollY: dragged down by
  if sheetSeen.getOrDefault(id, -10) < ui.frameNo - 1:
    st.aux2 = ui.now
    st.scrollY = 0
  sheetSeen[id] = ui.frameNo
  let was = ui.curDialog
  ui.curDialog = id
  ui.dialogTopNow = id
  pushLayer(LayerDialog)
  let room = rect(ui.winX, ui.winY, ui.w, ui.h - ui.winY)
  let handleH = if handle: dp(18) else: 0
  let titleH = if title.len > 0: FontH + dp(12) else: 0
  let below = if kind == skBottom: ui.safe.bottom else: 0
  # (Gloss's popover: a dark frame round its white inside, as tablets had it then)
  let edge = if glossLook() and kind == skPopover and drawFace: dp(7) else: 0
  let w = if kind == skBottom and sizeClass() == scCompact: room.w
          else: min(dp(width), room.w - 2 * dp(8))
  let h = min(handleH + titleH + st.aux + 2 * Pad + below + 2 * edge, room.h - dp(24))
  var x = room.x + (room.w - w) div 2
  var y = room.y + (room.h - h) div 2
  var arrowUp = true
  var ax = 0
  case kind
  of skBottom:
    y = room.y + room.h - h + st.scrollY
    if smoothScrolling and ui.now - st.aux2 < 240:
      # (sliding up from below)
      let t = 1.0 - (ui.now - st.aux2) / 240
      y += int(float(h) * t * t * t)
      wakeIn(16)
  of skMiddle: discard
  of skPopover:
    let gap = dp(10)
    let under = anchor.y + anchor.h + gap
    if under + h <= room.y + room.h - dp(4) or anchor.y - gap - h < room.y: y = under
    else:
      y = anchor.y - gap - h
      arrowUp = false
    x = clamp(anchor.x + anchor.w div 2 - w div 2, room.x + dp(6), max(room.x + dp(6), room.x + room.w - w - dp(6)))
    ax = clamp(anchor.x + anchor.w div 2, x + dp(18), x + w - dp(18))
  let r = rect(x, y, w, h)
  if kind != skPopover:
    fill(room, withAlpha(black, if onDarkWindow(): 120 else: 80))     # (what is behind it, dimmed)
  notePlaced(r)
  # Esc, Back, a press outside close it; a bottom one's top drags it down
  if canInput():
    if escCloses and keyHit(KeyEsc): open = false
    elif escCloses and backPressed():
      cancelClose()
      open = false
    elif ui.pressed and not mouseIn(r) and takePress():
      if tapCloses: open = false
    elif kind == skBottom:
      let grab = rect(r.x, r.y, r.w, max(handleH + titleH, dp(12)))
      if hover(grab) and takePress():
        ui.active = id
        ui.dragsActive = true
        st.anchor = ui.my - st.scrollY
      if ui.active == id:
        if ui.mouseDown: st.scrollY = max(0, ui.my - st.anchor)
        else:
          if st.scrollY > h div 3: open = false
          st.scrollY = 0
          ui.active = 0
  if not open:
    popLayer()
    ui.curDialog = was
    ui.redraw = true
    state(id) = st
    return false
  # its face: 3.1's frame with a shadow; the newer looks' rounded, a soft shadow under it (a
  # bottom one's corners rounded at its top only)
  let rad = if matteLook(): float(dp(2))
            elif glassLook(): float(if kind == skPopover: dp(10) else: dp(14)) else: 0.0
  let fr = if kind == skBottom: rect(r.x, r.y, r.w, r.h + int(rad)) else: r
  sheetRect = r
  let navy = (glossTone(0.385, 0.41), glossTone(0.65, 0.13))
  if not drawFace: discard
  elif edge > 0:
    softShadow(fr, rad, 6)
    roundRect(fr, rad, glossTone(0.7, 0.08))
    roundRectShaded(inset(fr, 1), rad - 1, navy[0], navy[1])
    hline(fr.x + int(rad), fr.y + 1, fr.w - 2 * int(rad), withAlpha(white, 70))
    let inner = inset(fr, edge)
    roundRect(inner, max(0.0, rad - float(edge) + 2), th.field)
  elif glassLook():
    softShadow(fr, rad, 6)
    if not frostedFace(fr, th.window, rad): roundRect(fr, rad, th.window)
    roundFrame(fr, rad, 1, glassHair())
  else:
    fill(rect(fr.x + 3, fr.y + 3, fr.w, fr.h), withAlpha(black, 70))
    fill(fr, th.window)
    box(fr, th.frame)
  if kind == skPopover:
    # (its arrow, to the middle of what it is for)
    let s = dp(9)
    let at = if arrowUp: r.y else: r.y + r.h - 1
    let line = if edge > 0: glossTone(0.7, 0.08) elif glassLook(): glassHair() else: th.frame
    let inside = if edge > 0: (if arrowUp: navy[0] else: navy[1]) else: th.window
    for k in 0 .. s:
      let yy = if arrowUp: at - k else: at + k
      let half = s - k
      hline(ax - half, yy, 2 * half + 1, inside)
      fill(rect(ax - half - 1, yy, 1, 1), line)
      fill(rect(ax + half + 1, yy, 1, 1), line)
  if handle:
    roundRect(rect(r.x + r.w div 2 - dp(18), r.y + dp(7), dp(36), dp(5)), float(dp(5)) / 2,
              mixColor(th.window, th.text, 0.3))
  if titleH > 0:
    let t = ellipsize(tr(title), r.w - 2 * Pad, style(bold = true))
    text(r.x + (r.w - textWidth(t, true)) div 2, r.y + handleH + dp(6), t, th.text, true)
  if accessOn: accessBegin(arDialog, title, r, id, {asModal})
  state(id) = st
  sheets.add (id, was, r)
  pushClip(inset(r, edge))
  pushFrame(rect(r.x + Pad + edge, r.y + handleH + titleH + Pad + edge, r.w - 2 * Pad - 2 * edge, 0))
  true

proc endSheet() =
  let s = sheets.pop()
  let used = popFrame()
  popClip()
  if accessOn: accessEnd()
  var st = state(s.id)
  if used != st.aux:
    st.aux = used
    ui.redraw = true
  state(s.id) = st
  popLayer()
  ui.curDialog = s.was

proc actionSheet*(open: var bool; title: string; actions: openArray[string]; destructive = -1;
                  cancel = "Cancel"; message = ""): int =
  ## A phone's action sheet, shown while `open`: what can be done to something, a button each
  ## -- the `destructive` one (Delete) in red --, Cancel apart under them. On a phone it comes
  ## up from the bottom, elsewhere in the middle of the window; what is behind it dims. Returns
  ## the action picked (and closes); -1 meanwhile, or when it was cancelled -- Cancel, Esc,
  ## the phone's Back, a tap beside it. Up and Down go along its buttons. Gloss: white glossy
  ## buttons on a dark sheet; Glass: its actions in a rounded card, Cancel in its own; Matte:
  ## flat rows.
  result = -1
  let compact = sizeClass() == scCompact or ui.touch
  let key = "actionsheet:" & title & $actions.len
  let sid = idOf(key)
  let gloss = glossLook()
  let matte = matteLook()
  let cards = glassLook() and not gloss and not matte
  if not beginSheet(open, sid, "", if compact: skBottom else: skMiddle, 320,
                    drawFace = not (gloss or cards)): return
  defer: endSheet()
  let sr = sheetRect
  if gloss:
    # (a dark sheet, see-through, lit along its top)
    roundRectShaded(sr, float(if compact: 0 else: dp(10)), withAlpha(glossTone(0.29, 0.24), 236), glossTone(0.6, 0.04))
    hline(sr.x, sr.y, sr.w, withAlpha(white, 90))
  let bh = if fingers(): dp(44) else: CtrlH + dp(10)
  let titleInk = if gloss: color(208, 212, 220) else: th.gray
  # (the title's and the message's places first: Glass draws its card under them too)
  var titleR, messageR: Rect
  if title.len > 0: titleR = place(0, FontH + dp(if cards: 12 else: 2), fill = true)
  if message.len > 0: messageR = place(0, FontH + dp(2), fill = true)
  if title.len > 0 or message.len > 0:
    if cards: space(-Gap)
    else: space(dp(4))
  # (Glass and Matte: the actions one block, a line between them; Cancel apart)
  let joined = cards or matte
  let blockR = if joined and actions.len > 0: place(0, bh * actions.len, fill = true) else: Rect()
  let cardRad = float(dp(12))
  if cards and actions.len > 0:
    let top = if title.len > 0: titleR.y - dp(6) elif message.len > 0: messageR.y - dp(6) else: blockR.y
    let card = rect(blockR.x, top, blockR.w, blockR.y + blockR.h - top)
    if not frostedFace(card, glassCard(), cardRad): roundRect(card, cardRad, glassCard())
    if top < blockR.y: hline(blockR.x, blockR.y, blockR.w, glassHair())
  if title.len > 0:
    let t = ellipsize(tr(title), titleR.w, style(bold = true))
    text(titleR.x + (titleR.w - textWidth(t, true)) div 2, titleR.y + (if cards: dp(4) else: 0), t,
         titleInk, true)
  if message.len > 0:
    let t = ellipsize(tr(message), messageR.w)
    text(messageR.x + (messageR.w - textWidth(t)) div 2, messageR.y, t, titleInk)
  var focusedAt = -1
  for i in 0 .. actions.len:
    let isCancel = i == actions.len
    if isCancel: space(dp(8))
    let a = if isCancel: cancel else: actions[i]
    let r = if joined and not isCancel: rect(blockR.x, blockR.y + i * bh, blockR.w, bh)
            else: place(0, bh, fill = true)
    let aid = sid + Id(1 + i)
    var hit = interact(aid, r)
    spaceKey(aid, hit)
    if hit.focused:
      focusedAt = i
      ui.takesEnter = true
      if keyHit(KeyEnter): hit.clicked = true
    if mnemonicHit(a): hit.clicked = true
    var ink = th.text
    var bold = isCancel
    if gloss:
      bold = true
      if i == destructive:
        tintedFace(r, color(206, 28, 28), hit.down, float(dp(8)))
        ink = white
      elif isCancel:
        tintedFace(r, color(58, 62, 72), hit.down, float(dp(8)))
        ink = white
      else:
        let rad = float(dp(8))
        roundRect(r, rad, color(20, 22, 26))
        roundRectShaded(inset(r, 1), rad - 1, if hit.down: color(200, 200, 204) else: white,
                        if hit.down: color(170, 170, 176) else: color(214, 214, 220))
        ink = color(20, 20, 22)
    elif cards:
      if isCancel:
        if not frostedFace(r, glassCard(), cardRad): roundRect(r, cardRad, glassCard())
        if hit.down: roundRect(r, cardRad, withAlpha(th.text, 24))
      else:
        if i > 0: hline(r.x, r.y, r.w, glassHair())
        if hit.down:
          pushClip(r)
          roundRect(blockR, cardRad, withAlpha(th.text, 24))
          popClip()
      ink = if i == destructive: badColor() else: accentText()
    elif matte:
      let face = if isCancel: r else: r
      if hit.down: fill(face, mixColor(th.window, accentColor(), 0.3))
      elif hit.showsHover: fill(face, hoverColor())
      if not isCancel and i > 0: hline(r.x, r.y, r.w, mixColor(th.window, th.text, 0.16))
      if isCancel: box(r, mixColor(th.window, th.text, 0.22))
      ink = if i == destructive: badColor() else: th.text
    elif i == destructive:
      tintedFace(r, badColor(), hit.down)
      ink = white
    else:
      buttonFace(r, hit.down, 1, hot = hovered(r))
    let lw = labelWidth(a, bold)
    let ly = r.y + (r.h - FontH) div 2
    if gloss and ink == white: drawLabel(r.x + (r.w - lw) div 2, ly - 1, a, withAlpha(black, 100), bold)
    drawLabel(r.x + (r.w - lw) div 2, ly, a, ink, bold)
    if hit.focused: focusDots(inset(r, 3))
    if accessOn: accessNode(arButton, a, id = aid, r = r)
    if hit.clicked:
      result = if isCancel: -1 else: i
      open = false
  if focusedAt >= 0 and canInput() and not ui.keyUsed:
    if ui.key == KeyDown and focusedAt < actions.len:
      ui.keyUsed = true
      ui.focus = sid + Id(2 + focusedAt)
    elif ui.key == KeyUp and focusedAt > 0:
      ui.keyUsed = true
      ui.focus = sid + Id(focusedAt)

proc beginBottomSheet*(open: var bool; title: string; width = 560): bool =
  ## Starts a bottom sheet (see `bottomSheet`): true while it is `open`.
  beginSheet(open, idOf("bottomsheet:" & title), title, skBottom, width, handle = true)

proc endBottomSheet*() =
  ## Ends a `beginBottomSheet`.
  endSheet()

template bottomSheet*(open: var bool; title: string; body: untyped) =
  ## A sheet that comes up from the bottom of the window while `open`, over the rest (dimmed),
  ## with a handle and its `title` at its top: filters, options, a short form. The full width
  ## on a phone, 560 pixels at most elsewhere. Esc, the phone's Back, a tap beside it or a
  ## drag of its top downward close it.
  if beginBottomSheet(open, title):
    try:
      body
    finally:
      endBottomSheet()

proc beginPopover*(open: var bool; anchor: Rect; width = 280): bool =
  ## Starts a popover (see `popover`): true while it is `open`.
  beginSheet(open, idOf(open, "popover"), "", skPopover, width, anchor)

proc endPopover*() =
  ## Ends a `beginPopover`.
  endSheet()

template popover*(open: var bool; anchor: Rect; width: int; body: untyped) =
  ## A bubble with an arrow to `anchor` -- the button that opened it (`ui.lastRect` right after
  ## it) --, under it or over it as there is room, `width` pixels wide, while `open`: a few
  ## controls or a note about it. Esc or a click outside it closes it.
  if beginPopover(open, anchor, width):
    try:
      body
    finally:
      endPopover()

# ---- an alert ------------------------------------------------------------------------------------

proc alertBox*(open: var bool; title: string; message = ""; buttons: openArray[string] = ["OK"];
               cancel = -1): int =
  ## A phone's alert while `open`: a title, a message, its buttons -- two side by side, more one
  ## under another. Returns the button pressed (and closes); -1 meanwhile. Enter presses the
  ## last one (it has the keys first); Esc and the phone's Back press `cancel` (-1: they do
  ## nothing); a tap beside it does nothing -- it waits for an answer. Gloss: the dark blue
  ## glossy box of its time; Glass: frosted, its buttons in the highlight; Matte: a dark box,
  ## flat buttons; Classic: a 3.1 message box.
  result = -1
  let sid = idOf("alert:" & title & "\x1F" & message)
  let wasOpen = open
  if not beginSheet(open, sid, "", skMiddle, 284, drawFace = false, tapCloses = false,
                    escCloses = cancel >= 0):
    if wasOpen and not open: result = cancel
    return
  defer: endSheet()
  let r = sheetRect
  let gloss = glossLook()
  let matte = matteLook()
  let glass = glassLook() and not gloss and not matte
  var ink, sub: Color
  if gloss:
    let rad = float(dp(10))
    roundRect(r, rad, withAlpha(glossTone(0.07, 0.95), 240))
    let f = inset(r, max(2, dp(2)))
    roundRectShaded(f, rad - 2, withAlpha(glossTone(0.58, 0.53), 238), glossTone(0.8, 0.24))
    # (the shine across its top, curved at its foot)
    pushClip(rect(f.x, f.y, f.w, dp(36)))
    disc(float(f.x + f.w div 2), float(f.y + dp(30)) - float(f.w) * 1.4, float(f.w) * 1.4, withAlpha(white, 40))
    popClip()
    ink = white
    sub = glossTone(0.05, 0.96)
  elif glass:
    let rad = float(dp(14))
    if not frostedFace(r, glassCard(), rad): roundRect(r, rad, glassCard())
    ink = th.text
    sub = th.text
  elif matte:
    fill(r, color(40, 40, 42))
    fill(rect(r.x, r.y, r.w, max(2, dp(3))), accentColor())
    ink = white
    sub = color(204, 204, 208)
  else:
    fill(r, th.window)
    box(r, th.frame)
    box(inset(r, 1), th.face)
    box(inset(r, 2), th.frame)
    ink = th.text
    sub = th.text
  let room = cellRoom()
  let centered = gloss or glass
  for (txt, bold, c) in [(title, true, ink), (message, false, sub)]:
    if txt.len == 0: continue
    for ln in wrapLines(tr(txt), room, bold):
      let lr = place(0, FontH + dp(2), fill = true)
      let tw = textWidth(ln, bold)
      let tx = if centered: lr.x + (lr.w - tw) div 2 else: lr.x
      if gloss: text(tx, lr.y - 1, ln, withAlpha(black, 120), bold)
      text(tx, lr.y, ln, c, bold)
  space(dp(8))
  let bh = if fingers(): dp(44) else: CtrlH + dp(8)
  let side = buttons.len == 2
  let pairR = if side: place(0, bh, fill = true) else: Rect()
  if glass:
    # (its buttons across its foot, a hairline over them and between them)
    let top = if side: pairR.y else: frameBottom()
    hline(r.x, top - dp(2), r.w, glassHair())
  if canInput() and ui.focus == 0 and buttons.len > 0: ui.focus = sid + Id(buttons.len)
  for i, b in buttons:
    let br = if side: rect(pairR.x + (if i == 0: 0 else: pairR.w div 2 + dp(3)), pairR.y,
                           pairR.w div 2 - dp(3), bh)
             else: place(0, bh, fill = true)
    let bid = sid + Id(1 + i)
    var hit = interact(bid, br)
    spaceKey(bid, hit)
    if hit.focused:
      ui.takesEnter = true
      if keyHit(KeyEnter): hit.clicked = true
    if mnemonicHit(b): hit.clicked = true
    var lc = th.text
    var bold = i == buttons.high and buttons.len > 1
    if gloss:
      tintedFace(br, if i == cancel: glossTone(0.63, 0.36) else: glossTone(0.53, 0.61), hit.down, float(dp(6)))
      lc = white
      bold = true
    elif glass:
      if side and i == 1: vline(br.x - dp(3), br.y - dp(2), br.h + dp(2), glassHair())
      elif not side and i > 0: hline(r.x, br.y - dp(1), r.w, glassHair())
      if hit.down: fill(br, withAlpha(th.text, 20))
      lc = accentText()
    elif matte:
      let primary = i == buttons.high and buttons.len > 1
      fill(br, if hit.down: mixColor(color(64, 64, 68), accentColor(), 0.5)
               elif primary: accentColor() else: color(64, 64, 68))
      lc = white
    else:
      buttonFace(br, hit.down, if i == buttons.high: 2 else: 1, hot = hovered(br))
    let lw = labelWidth(b, bold)
    let ly = br.y + (br.h - FontH) div 2
    if gloss: drawLabel(br.x + (br.w - lw) div 2, ly - 1, b, withAlpha(black, 110), bold)
    drawLabel(br.x + (br.w - lw) div 2, ly, b, lc, bold)
    if hit.focused: focusDots(inset(br, 3))
    if accessOn: accessNode(arButton, b, id = bid, r = br)
    if hit.clicked:
      result = i
      open = false

# ---- grouped tables: rows in groups, as a phone's settings ----------------------------------------

type
  TableAccessory* = enum
    ## What a `tableRow` shows at its end.
    taNone,      ## nothing
    taChevron,   ## a chevron: it leads to another page
    taCheck,     ## a check mark: the one chosen
    taInfo       ## a round info button, clicked apart from the row (`TableHit.info`)
  TableHit* = object
    ## What happened to a `tableRow`.
    clicked*: bool   ## it was clicked or tapped (or Enter, Space)
    info*: bool      ## its info button was

var
  tableGroups: seq[tuple[id: Id; r: Rect; rows, rowsBefore, gap: int; footer: string]]
  tableNo: tuple[frame, n: int]

proc tableRadius(): float =
  if glossLook(): float(dp(9)) elif matteLook(): 0.0 elif glassLook(): float(dp(10)) else: 0.0

proc tableRowH(two: bool): int =
  let base = if fingers(): dp(44) else: max(dp(30), FontH + dp(14))
  if two: max(base + dp(10), 2 * FontH + dp(14)) else: base

proc beginTableGroup*(header = ""; footer = "") =
  ## Starts a group of table rows (see `tableGroup`).
  if tableNo.frame != ui.frameNo: tableNo = (ui.frameNo, 0)
  inc tableNo.n
  if header.len > 0:
    let gloss = glossLook()
    let st = if gloss: style(bold = true, size = 1.05)
             elif glassLook() and not matteLook(): style(size = 0.85)
             else: style(bold = true, size = 0.9)
    let t = if glassLook() and not gloss and not matteLook(): tr(header).toUpper else: tr(header)
    let hr = place(0, lineHeight(st) + dp(if fingers(): 10 else: 4), fill = true)
    let tx = hr.x + (if glassLook(): dp(12) else: 0)
    let ty = hr.y + hr.h - lineHeight(st) - dp(2)
    if gloss:
      if not onDarkWindow(): text(tx, ty + 1, t, withAlpha(white, 200), st)
      text(tx, ty, t, if onDarkWindow(): color(196, 200, 210) else: glossTone(0.30, 0.42), st)
    elif matteLook():
      text(tx, ty, t, accentText(), st)
      fill(rect(hr.x, hr.y + hr.h - 1, hr.w, 1), mixColor(th.window, accentColor(), 0.5))
    else: text(tx, ty, t, if glassLook(): th.gray else: th.text, st)
    if accessOn: accessNode(arHeading, header, r = hr)
  let id = idOf("tablegroup:" & $tableNo.n & ":" & header)
  let st = state(id)
  let cell = place(0, max(1, st.aux), fill = true)
  # its face: Gloss's white, a gray line round it; Glass's a rounded card; 3.1's a sunk field;
  # Matte's the window, a line between the rows
  let rad = tableRadius()
  if glossLook(): roundRect(cell, rad, if onDarkWindow(): th.field else: color(247, 247, 247))   # (an off-white, as then)
  elif matteLook(): discard
  elif glassLook(): roundRect(cell, rad, th.field)
  else: fill(cell, th.field)
  tableGroups.add (id, cell, 0, st.aux2, ui.m.gap, footer)
  ui.m.gap = 0
  pushFrame(rect(cell.x, cell.y, cell.w, 0))

proc endTableGroup*() =
  ## Ends a `beginTableGroup`: its outline, and its footer under it.
  let g = tableGroups.pop()
  let used = popFrame()
  ui.m.gap = g.gap
  var st = state(g.id)
  if used != st.aux or g.rows != st.aux2:
    st.aux = used
    st.aux2 = g.rows
    ui.redraw = true
  state(g.id) = st
  let r = g.r
  let rad = tableRadius()
  if glossLook():
    roundFrame(r, rad, 1, if onDarkWindow(): black else: color(171, 171, 171))
    if not onDarkWindow(): hline(r.x + int(rad), r.y + r.h, r.w - 2 * int(rad), withAlpha(white, 200))
  elif matteLook():
    hline(r.x, r.y, r.w, mixColor(th.window, th.text, 0.16))
    hline(r.x, r.y + r.h - 1, r.w, mixColor(th.window, th.text, 0.16))
  elif glassLook(): discard
  else: fieldFrame(r)
  if g.footer.len > 0:
    let gloss = glossLook()
    let room = cellRoom() - (if glassLook(): 2 * dp(12) else: 0)
    for ln in wrapLines(tr(g.footer), room):
      let lr = place(0, FontH + dp(1), fill = true)
      let tw = textWidth(ln)
      let tx = if gloss: lr.x + (lr.w - tw) div 2 elif glassLook(): lr.x + dp(12) else: lr.x
      if gloss:
        if not onDarkWindow(): text(tx, lr.y + 1, ln, withAlpha(white, 200))
        text(tx, lr.y, ln, if onDarkWindow(): color(176, 180, 190) else: glossTone(0.30, 0.42))
      else: text(tx, lr.y, ln, th.gray)

template tableGroup*(header, footer: string; body: untyped) =
  ## Rows (`tableRow`, `tableSwitch`, `tableButton`) in a group, as a phone's settings show
  ## them: `header` over it, `footer` (a note) under it. Gloss: a white rounded group with a gray
  ## line round it on the window, a line between its rows; Glass: a rounded card; Matte:
  ## full-width rows, the header in the highlight; Classic: a sunk white field.
  beginTableGroup(header, footer)
  try:
    body
  finally:
    endTableGroup()

template tableGroup*(header: string; body: untyped) =
  ## A group of rows with a header and no footer (see the other `tableGroup`).
  tableGroup(header, "", body)

proc rowFrame(r: Rect; pressed: bool): tuple[first, last: bool; ink, sub, link: Color] =
  ## (a row's line over it, its pressed face; the colors of its text)
  let inGroup = tableGroups.len > 0
  let idx = if inGroup: tableGroups[^1].rows else: 0
  let first = idx == 0
  let last = not inGroup or idx >= tableGroups[^1].rowsBefore - 1
  if inGroup: inc tableGroups[^1].rows
  let g = if inGroup: tableGroups[^1].r else: r
  let rad = tableRadius()
  let gloss = glossLook()
  if not first:
    let lc = if gloss: (if onDarkWindow(): color(20, 20, 22) else: color(224, 224, 224))
             elif glassLook() and not matteLook(): glassHair()
             else: mixColor(th.field, th.fieldText, 0.14)
    let lx = if glassLook() and not gloss and not matteLook(): r.x + dp(14) else: r.x + 1
    hline(lx, r.y, r.x + r.w - 1 - lx, lc)
  if pressed:
    pushClip(r)
    if gloss: glossBlue(g, rad)
    elif matteLook(): fill(r, mixColor(th.window, accentColor(), 0.32))
    elif glassLook(): roundRect(g, rad, mixColor(th.field, th.fieldText, 0.12))
    else: fill(r, th.select)
    popClip()
  let classicPressed = pressed and not glassLook()
  result.first = first
  result.last = last
  result.ink = if (pressed and gloss) or classicPressed: (if gloss: white else: th.selectText)
               else: th.fieldText
  result.sub = if pressed and gloss: white elif classicPressed: th.selectText else: th.gray
  result.link = if pressed and gloss: white
                elif classicPressed: th.selectText
                elif gloss: glossDetail()
                elif glassLook(): th.gray
                else: th.gray

proc rowChevron(cx, cy: int; c: Color) =
  # (Gloss's bolder, as phones drew it then)
  if glossLook(): chevron(cx, cy, max(dp(12), FontH * 4 div 5), false, c, max(2.2, float(dp(3)) - 0.4))
  else: chevron(cx, cy, max(dp(9), FontH * 3 div 5), false, c, max(1.6, float(dp(2))))

proc rowCheck(cx, cy: int; c: Color) =
  let k = float(max(dp(5), FontH div 3))
  let w = max(1.8, float(dp(2)) + 0.4)
  thickLine(float(cx) - k, float(cy), float(cx) - k / 3, float(cy) + k * 0.7, w, c)
  thickLine(float(cx) - k / 3, float(cy) + k * 0.7, float(cx) + k, float(cy) - k * 0.8, w, c)

proc rowGlyph(r: Rect; x: var int; glyph: string; tint: Color; pressed: bool; ink: Color) =
  ## (a row's icon: Gloss's on a glossy rounded tile -- gray, or `tint` --, white; Glass's on a
  ## flat tile of `tint` or the highlight; Matte's and Classic's the glyph alone)
  var blank = true
  for ch in glyph:
    if ch notin {' ', '\t'}: blank = false
  if blank:
    if glyph.len > 0: x += max(dp(26), dp(10))       # (" ": room kept, the rows' titles in line)
    return
  let gloss = glossLook()
  if gloss or (glassLook() and not matteLook()):
    let d = min(r.h - dp(12), dp(29))
    let t = rect(x, r.y + (r.h - d) div 2, d, d)
    let rad = float(dp(6))
    if gloss:
      let c = if tint.a != 0: tint else: color(142, 142, 148)
      roundRect(rect(t.x, t.y + 1, t.w, t.h), rad, withAlpha(black, 60))
      roundRect(t, rad, mixColor(c, black, 0.45))
      roundRectShaded(inset(t, 1), rad - 1, mixColor(c, white, 0.3), mixColor(c, black, 0.12))
      pushClip(rect(t.x, t.y, t.w, t.h div 2))
      roundRect(inset(t, 1), rad - 1, withAlpha(white, 50))
      popClip()
    else:
      roundRect(t, rad, if tint.a != 0: tint else: accentColor())
    let gs = style(size = 1.05)
    let gw = textWidth(glyph, gs)
    let gy = t.y + (d - lineHeight(gs)) div 2
    if gloss: text(t.x + (d - gw) div 2, gy - 1, glyph, withAlpha(black, 100), gs)
    text(t.x + (d - gw) div 2, gy, glyph, white, gs)
    x += d + dp(12)
  else:
    let gs = style(size = 1.25)
    text(x, r.y + (r.h - lineHeight(gs)) div 2, glyph,
         if matteLook(): (if pressed: ink else: accentText()) else: ink, gs)
    x += max(dp(26), textWidth(glyph, gs) + dp(10))

proc tableRow*(title: string; detail = ""; accessory = taNone; glyph = ""; subtitle = "";
               enabled = true; key = ""; picture: Bitmap = nil; tint = Color();
               selected = false): TableHit =
  ## A row of a `tableGroup`: an icon (`glyph`, an icon font's -- Gloss and Glass draw it white
  ## on a rounded tile, gray or `tint`) or a `picture` (a cover, a face: square, its corners
  ## rounded), its `title`, a gray
  ## `subtitle` under it, a `detail` at its end (Gloss: in its blue-gray, as values were
  ## written), and an `accessory` -- a chevron (it leads to another page), a check mark (the
  ## one chosen) or an info button. A click, a tap, Enter or Space: `clicked`; the info
  ## button: `info`. `key`: its own id (rows of the same title). `selected`: the row whose
  ## page is shown beside the list (a tablet's): drawn chosen -- Gloss's blue.
  let two = subtitle.len > 0
  let r = place(0, tableRowH(two), fill = true)
  let gid = if tableGroups.len > 0: tableGroups[^1].id else: Id(0)
  let id = Id(mixId(uint32(gid), fnv("tablerow:" & (if key.len > 0: key else: title))))
  let pad = if fingers(): dp(12) else: dp(10)
  # (the info button first: it takes its own press)
  let d = max(dp(22), FontH + dp(5))
  let ir = rect(r.x + r.w - pad - d, r.y + (r.h - d) div 2, d, d)
  var ih: Hit
  if accessory == taInfo:
    ih = interact(id + 1, ir, focusable = false, enabled = enabled)
    if ih.clicked: result.info = true
  var hit = interact(id, r, enabled = enabled)
  if enabled:
    spaceKey(id, hit)
    if hit.focused:
      ui.takesEnter = true
      if keyHit(KeyEnter): hit.clicked = true
  result.clicked = hit.clicked
  let pressed = (hit.down and not ih.down) or (selected and enabled)
  let (_, _, ink0, sub, link) = rowFrame(r, pressed)
  let gloss = glossLook()
  var ink = if not enabled: th.gray else: ink0
  if accessory == taCheck and gloss and not pressed: ink = link
  var x = r.x + pad
  if glyph.len > 0: rowGlyph(r, x, glyph, tint, pressed, ink)
  if picture != nil and picture.w > 0:
    let d = r.h - dp(10)
    let pr = rect(x, r.y + dp(5), d, d)
    masked(pr, float(if glassLook(): dp(5) else: 0)):
      drawBitmap(pr, picture)
    x += d + dp(10)
  # the end: the accessory, then the detail before it
  var endX = r.x + r.w - pad
  case accessory
  of taChevron:
    rowChevron(endX - dp(4), r.y + r.h div 2,
               if pressed and gloss: white elif gloss: color(112, 112, 112) else: th.gray)
    endX -= dp(if gloss: 20 else: 18)
  of taCheck:
    rowCheck(endX - dp(7), r.y + r.h div 2,
             if pressed and gloss: white elif gloss: link elif glassLook(): accentText() else: ink)
    endX -= dp(24)
  of taInfo:
    let cx = float(ir.x) + float(d) / 2
    let cy = float(ir.y) + float(d) / 2
    if gloss:
      disc(cx, cy, float(d) / 2, if onDarkWindow(): black else: color(255, 255, 255))
      discShaded(cx, cy, float(d) / 2 - 1.5, if ih.down: glossTone(0.89, 0.75) else: glossTone(0.71, 0.96),
                 glossTone(0.93, 0.84))
      chevron(int(cx) + 1, int(cy), d * 2 div 5, false, white, max(1.6, float(dp(2))))
    else:
      ring(cx, cy, float(d) / 2, max(1.3, float(dp(1)) + 0.3), accentText())
      let it = "i"
      text(int(cx) - textWidth(it, true) div 2, int(cy) - FontH div 2, it, accentText(), true)
    endX = ir.x - dp(8)
  of taNone: discard
  let room = endX - x
  if detail.len > 0:
    let dt = ellipsize(detail, max(dp(30), room div 2))
    let dw = textWidth(dt)
    text(endX - dw, r.y + (r.h - FontH) div 2, dt, if enabled: link else: th.gray)
    endX -= dw + dp(10)
  let bold = gloss
  if two:
    let y0 = r.y + (r.h - 2 * FontH - dp(2)) div 2
    text(x, y0, ellipsize(title, endX - x, style(bold = bold)), ink, bold)
    text(x, y0 + FontH + dp(2), ellipsize(subtitle, endX - x), sub)
  else:
    text(x, r.y + (r.h - FontH) div 2, ellipsize(title, endX - x, style(bold = bold)), ink, bold)
  if hit.focused: focusDots(inset(r, 2))
  if accessOn:
    accessNode(if accessory == taChevron: arButton else: arListItem, title, value = detail, id = id,
               r = r, states = offIf(enabled) + (if accessory == taCheck or selected: {asSelected} else: {}))
    if accessory == taInfo: accessNode(arButton, "More about " & title, id = id + 1, r = ir)
  ui.lastId = id
  ui.lastRect = r

proc tableSwitch*(title: string; v: var bool; glyph = ""; subtitle = ""; enabled = true;
                  tint = Color()): bool {.discardable.} =
  ## A row of a `tableGroup` with a switch at its end (Wi-Fi, Airplane Mode): a click or a tap
  ## on the row or the switch flips it, Space too. True when `v` changed.
  let two = subtitle.len > 0
  let r = place(0, tableRowH(two), fill = true)
  let gid = if tableGroups.len > 0: tableGroups[^1].id else: Id(0)
  let id = Id(mixId(uint32(gid), fnv("tableswitch:" & title)))
  let pad = if fingers(): dp(12) else: dp(10)
  var hit = interact(id, r, enabled = enabled)
  if enabled:
    spaceKey(id, hit)
    if mnemonicHit(title): hit.clicked = true
  let (_, _, ink0, sub, link) = rowFrame(r, false)
  let ink = if enabled: ink0 else: th.gray
  let (sw, sh) = switchSize()
  let track = rect(r.x + r.w - pad - sw, r.y + (r.h - sh) div 2, sw, sh)
  result = switchAt(id, track, v, hit, enabled)
  var x = r.x + pad
  if glyph.len > 0: rowGlyph(r, x, glyph, tint, false, ink)
  discard link
  let bold = glossLook()
  let room = track.x - dp(10) - x
  if two:
    let y0 = r.y + (r.h - 2 * FontH - dp(2)) div 2
    drawLabel(x, y0, title, ink, bold)
    text(x, y0 + FontH + dp(2), ellipsize(subtitle, room), sub)
  else: drawLabel(x, r.y + (r.h - FontH) div 2, title, ink, bold)
  if hit.focused: focusDots(inset(r, 2))
  if accessOn:
    accessNode(arCheckBox, title, id = id, r = r, states = offIf(enabled) + (if v: {asChecked} else: {}))
  ui.lastId = id
  ui.lastRect = r

proc tableButton*(title: string; destructive = false; enabled = true): bool =
  ## A row of a `tableGroup` that does something at once (Sign Out, Reset): its title in the
  ## middle -- red when `destructive`. True when clicked.
  let r = place(0, tableRowH(false), fill = true)
  let gid = if tableGroups.len > 0: tableGroups[^1].id else: Id(0)
  let id = Id(mixId(uint32(gid), fnv("tablebutton:" & title)))
  var hit = interact(id, r, enabled = enabled)
  if enabled:
    spaceKey(id, hit)
    if hit.focused:
      ui.takesEnter = true
      if keyHit(KeyEnter): hit.clicked = true
    if mnemonicHit(title): hit.clicked = true
  let (_, _, ink0, _, _) = rowFrame(r, hit.down)
  let gloss = glossLook()
  let ink = if not enabled: th.gray
            elif hit.down and (gloss or not glassLook()): ink0
            elif destructive: badColor()
            elif gloss: ink0
            elif glassLook(): accentText()
            else: ink0
  let lw = labelWidth(title, gloss)
  drawLabel(r.x + (r.w - lw) div 2, r.y + (r.h - FontH) div 2, title, ink, gloss)
  if hit.focused: focusDots(inset(r, 2))
  if accessOn: accessNode(arButton, title, id = id, r = r, states = offIf(enabled))
  ui.lastId = id
  ui.lastRect = r
  hit.clicked

# ---- a shelf of cards ----------------------------------------------------------------------------

type ShelfCard* = tuple[title, subtitle: string; picture: Bitmap; glyph: string]
  ## A card of a `cardShelf`: its picture (nil: `glyph` on a tint instead), its title, a line
  ## under it.

proc cardShelf*(cards: openArray[ShelfCard]; key: string; side = 0): int =
  ## A shelf of cards in a row the finger slides sideways, as phone apps show "your playlists"
  ## or "recently played": each a square picture with rounded corners, its title and a gray line
  ## under it; `side` its width (0: about a third of a phone's). Returns the one tapped (-1:
  ## none). A wheel or Shift+wheel slides it too; the cards are read as buttons.
  result = -1
  let w = if side > 0: side else: clamp(cellRoom() * 2 div 5, dp(110), dp(150))
  let gap = dp(12)
  let lh = lineHeight(style(bold = true))
  let h = w + dp(6) + lh + FontH + dp(4)
  let r = place(0, h, fill = true)
  let id = idOf("shelf:" & key)
  var st = state(id)
  let total = cards.len * w + max(0, cards.len - 1) * gap
  let hi = max(0, total - r.w)
  var x = clamp(st.scrollX, 0, hi)
  if hi > 0:
    scrollPan(id, x, hi, r, sideways = true)
    if hover(r) and canInput() and (ui.wheel != 0 or ui.wheelX != 0):
      x = clamp(x - (if ui.wheelX != 0: -ui.wheelX else: ui.wheel) * dp(48), 0, hi)
      ui.wheel = 0
      ui.wheelX = 0
    scrollTick(id, x, hi)
  pushClip(r)
  for i, c in cards:
    let cx = r.x + i * (w + gap) - x
    if cx + w < r.x or cx > r.x + r.w: continue
    let pic = rect(cx, r.y, w, w)
    let hit = interact(id + 7 + Id(i), rect(cx, r.y, w, h), focusable = true)
    if c.picture != nil:
      masked(pic, float(dp(10))):
        drawBitmap(pic, c.picture)
    else:
      roundRect(pic, float(dp(10)), mixColor(th.window, accentColor(), 0.25))
      if c.glyph.len > 0:
        let gs = style(size = 2.6)
        text(pic.x + (pic.w - textWidth(c.glyph, gs)) div 2, pic.y + (pic.h - lineHeight(gs)) div 2, c.glyph,
             withAlpha(th.text, 150), gs)
    if hit.down: roundRect(pic, float(dp(10)), withAlpha(black, 50))     # (pressed: darker)
    if hit.focused: focusDots(inset(pic, 2))
    text(cx, r.y + w + dp(6), ellipsize(c.title, w, style(bold = true)), th.text, style(bold = true))
    if c.subtitle.len > 0: text(cx, r.y + w + dp(6) + lh, ellipsize(c.subtitle, w), th.gray)
    if accessOn: accessNode(arButton, c.title, id = id + 7 + Id(i), r = pic)
    if hit.clicked and not scrollCaught(): result = i
  popClip()
  if x != st.scrollX:
    st.scrollX = x
    state(id) = st
    ui.redraw = true
  ui.lastId = 0
  ui.lastRect = r

# ---- a search bar --------------------------------------------------------------------------------

proc searchBar*(s: var string; placeholder = "Search"; cancel = "Cancel"): bool {.discardable.} =
  ## A phone's search bar, the width of the row: the search box on its bar, and while it has
  ## the keys or text, `cancel` beside it -- it empties the box and lets the keyboard go ("":
  ## none). True when the text changed. Gloss: the steel-blue bar, a capsule in it.
  let h = if fingers(): dp(44) else: EditH + dp(12)
  let cell = place(0, h, fill = true)
  let full = bleed(cell)
  let r = rect(full.x, cell.y, full.w, h)
  let boxId = idOf(s, "search")
  let showCancel = cancel.len > 0 and (ui.focus == boxId or s.len > 0)
  let gloss = glossLook()
  if gloss and not onDarkWindow():
    # (its bar lighter than a navigation bar's, as then)
    roundRectShaded(full, 0, glossTone(0.066, 0.90), glossTone(0.143, 0.77))
    hline(full.x, full.y, full.w, withAlpha(white, 160))
    hline(full.x, full.y + full.h - 1, full.w, glossTone(0.2, 0.58))
  elif gloss: glossBarFill(full)
  elif matteLook():
    fill(full, th.face)
    hline(full.x, full.y + full.h - 1, full.w, mixColor(th.face, th.text, 0.2))
  elif glassLook(): fill(full, mixColor(th.window, th.face, 0.5))
  else:
    fill(full, th.face)
    hline(full.x, full.y, full.w, th.light)
    hline(full.x, full.y + full.h - 1, full.w, th.shadow)
  let bst = style(bold = gloss, size = if gloss: 0.9 else: 1.0)
  let cw = if showCancel: labelWidth(cancel, bst) + dp(if gloss: 22 else: 16) else: 0
  pushFrame(rect(r.x + dp(8), r.y + (h - EditH) div 2, r.w - dp(16) - (if cw > 0: cw + dp(8) else: 0), 0))
  result = searchBox(s, placeholder)
  discard popFrame()
  if showCancel:
    let bh = if gloss: min(h - dp(12), CtrlH) else: EditH
    let cr = rect(r.x + r.w - dp(8) - cw, r.y + (h - bh) div 2, cw, bh)
    let cid = boxId + 9
    var ch = interact(cid, cr, focusable = false)
    var ink = accentText()
    if gloss:
      glossBarButton(cr, ch.down)
      ink = white
    elif not glassLook():
      buttonFace(cr, ch.down, 1)
      ink = th.text
    elif ch.down: roundRect(cr, glassRadius(cr), withAlpha(th.text, 30))
    let lw = labelWidth(cancel, bst)
    let ly = cr.y + (cr.h - lineHeight(bst)) div 2
    if gloss: drawLabel(cr.x + (cr.w - lw) div 2, ly - 1, cancel, withAlpha(black, 100), bst)
    drawLabel(cr.x + (cr.w - lw) div 2, ly, cancel, ink, bst)
    if accessOn: accessNode(arButton, cancel, id = cid, r = cr)
    if ch.clicked:
      if s.len > 0:
        s = ""
        result = true
      if ui.focus == boxId: ui.focus = 0
  ui.lastRect = cell

# ---- an action bar -------------------------------------------------------------------------------

proc actionBar*(actions: openArray[(string, string)]; back = ""; signature = -1): int =
  ## The bar of a phone screen's actions along the bottom of the window (call it before the
  ## content, as `bottomNav`): a glyph and a label each (`[(nfPlus, "New"), (nfTrash,
  ## "Delete")]`), Back at its start (`back`: its label; "" none). Returns the action tapped,
  ## -2 for Back, -1 meanwhile. `signature`: the screen's main action, in the middle, in a
  ## circle of the highlight (Matte). Gloss: the steel-blue tool bar, white glyphs; Matte:
  ## the dark bar, Back a tab with a slanted edge; Glass: see-through, glyphs in the highlight;
  ## Classic: a 3.1 tool bar at the foot.
  result = -1
  if keyboardUp(): return       # (the on-screen keyboard up: the bar left out, as phone apps leave it)
  let gloss = glossLook()
  let matte = matteLook()
  let below = if ui.bottom >= ui.h - ui.safe.bottom: ui.h - ui.bottom else: 0
  let h = if fingers() and not gloss: dp(54) else: dp(44)
  let r = rect(ui.winX, ui.bottom - h, ui.w, h + below)
  pushLayer(LayerBase)
  defer: popLayer()
  if gloss: glossBarFill(r)
  elif matte:
    fill(r, color(30, 30, 32))
    hline(r.x, r.y, r.w, color(64, 64, 68))
  elif glassLook():
    if not frostedFace(r, th.window): fill(r, mixColor(th.window, th.face, 0.6))
    hline(r.x, r.y, r.w, glassHair())
  else:
    fill(r, th.face)
    hline(r.x, r.y, r.w, th.frame)
    hline(r.x, r.y + 1, r.w, th.light)
  notePlaced(r)
  ui.bottom = r.y
  if accessOn: accessBegin(arToolBar, "", r)
  let inner = rect(ui.winX + ui.safe.left, r.y, ui.w - ui.safe.left - ui.safe.right, h)
  var x0 = inner.x
  let onBar = if gloss or matte: white elif glassLook(): accentText() else: th.text
  if back.len > 0:
    let bw = labelWidth(back) + dp(if gloss: 30 else: 34)
    let br = if gloss: rect(inner.x + dp(6), inner.y + (h - min(h - dp(14), CtrlH)) div 2, bw,
                            min(h - dp(14), CtrlH))
             else: rect(inner.x, inner.y, bw, h)
    let bid = idOf("actionbar:back:" & back)
    var bh = interact(bid, br)
    spaceKey(bid, bh)
    if bh.focused:
      ui.takesEnter = true
      if keyHit(KeyEnter): bh.clicked = true
    if gloss:
      glossBarButton(br, bh.down, back = true)
      let p = min(br.h div 2, dp(13))
      drawLabel(br.x + p + (br.w - p - labelWidth(back)) div 2 - dp(2), br.y + (br.h - FontH) div 2 - 1, back,
                withAlpha(black, 100))
      drawLabel(br.x + p + (br.w - p - labelWidth(back)) div 2 - dp(2), br.y + (br.h - FontH) div 2, back, white)
    else:
      if matte:
        # (a tab with a slanted edge, a little lighter than the bar)
        let sl = float(dp(12))
        polygon([(float(br.x), float(br.y)), (float(br.x + br.w) - sl, float(br.y)),
                 (float(br.x + br.w), float(br.y + br.h)), (float(br.x), float(br.y + br.h))],
                if bh.down: mixColor(color(52, 52, 56), accentColor(), 0.4) else: color(52, 52, 56))
      elif bh.down: fill(br, withAlpha(th.text, 30))
      chevron(br.x + dp(12), br.y + h div 2, max(dp(10), FontH * 2 div 3), true, onBar, max(1.6, float(dp(2))))
      drawLabel(br.x + dp(20), br.y + (h - FontH) div 2, back, onBar)
    if bh.focused: focusDots(inset(br, 3))
    if accessOn: accessNode(arButton, back, id = bid, r = br)
    if bh.clicked: result = -2
    x0 = br.x + br.w + dp(6)
  if actions.len == 0:
    if accessOn: accessEnd()
    return
  let slot = (inner.x + inner.w - x0) div actions.len
  let gst = style(size = 1.3)
  let lst = style(size = 0.78, bold = gloss)
  for i, (glyph, label) in actions:
    let cell = rect(x0 + slot * i, inner.y, slot, h)
    let aid = idOf("actionbar:" & $i & ":" & label)
    var hit = interact(aid, cell)
    spaceKey(aid, hit)
    if hit.focused:
      ui.takesEnter = true
      if keyHit(KeyEnter): hit.clicked = true
    if hit.clicked: result = i
    if gloss:
      # (Gloss: the tool bar of its time -- white glyphs pressed into it, no words under them; a
      # glow round the one pressed)
      let big = style(size = 1.55)
      let gw = textWidth(glyph, big)
      let gx = cell.x + (cell.w - gw) div 2
      let gy = cell.y + (h - lineHeight(big)) div 2
      if hit.down:
        disc(float(cell.x + cell.w div 2), float(cell.y + h div 2), float(h) * 0.42, withAlpha(white, 60))
        disc(float(cell.x + cell.w div 2), float(cell.y + h div 2), float(h) * 0.26, withAlpha(white, 70))
      text(gx, gy - 1, glyph, withAlpha(black, 120), big)
      text(gx, gy, glyph, white, big)
      tooltip(label)
      if hit.focused: focusDots(inset(cell, dp(3)))
      if accessOn: accessNode(arButton, label, id = aid, r = cell)
      continue
    let gy = cell.y + (h - lineHeight(gst) - lineHeight(lst)) div 2
    if i == signature and matte:
      let d = float(min(h - dp(6), lineHeight(gst) + lineHeight(lst) + dp(8)))
      disc(float(cell.x + cell.w div 2), float(cell.y + h div 2), d / 2,
           if hit.down: mixColor(accentColor(), black, 0.25) else: accentColor())
    elif hit.down:
      if gloss: roundRect(inset(cell, dp(4)), float(dp(5)), withAlpha(black, 60))
      else: fill(inset(cell, 2), withAlpha(if matte: white else: th.text, 30))
    elif hit.showsHover: fill(inset(cell, 2), withAlpha(if gloss or matte: white else: th.text, 16))
    let gw = textWidth(glyph, gst)
    if gloss: text(cell.x + (cell.w - gw) div 2, gy - 1, glyph, withAlpha(black, 110), gst)
    text(cell.x + (cell.w - gw) div 2, gy, glyph, onBar, gst)
    let l = ellipsize(tr(label), slot - dp(4), lst)
    text(cell.x + (cell.w - textWidth(l, lst)) div 2, gy + lineHeight(gst), l,
         if gloss or matte: (if matte: color(200, 200, 206) else: white) else: onBar, lst)
    if hit.focused: focusDots(inset(cell, dp(3)))
    if accessOn: accessNode(arButton, label, id = aid, r = cell)
  if accessOn: accessEnd()

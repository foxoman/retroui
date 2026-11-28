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

import std/[tables, math, unicode, algorithm]
from std/strutils import nil
import uirelays/target   # (androidApp: an APK, not a program in Termux)
import gfx, core, widgets, business, desktop, extras, platform, nerdicons
import uirelays/input
from typeset import textIsRtl

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
    let st = glossButtonStyle()
    let tw = labelWidth(label, st)
    let p = min(r.h div 2, dp(13))
    let x0 = if back: r.x + p + (r.w - p - dp(8) - tw) div 2
             else: r.x + (r.w - tw) div 2
    let ty = r.y + (r.h - lineHeight(st)) div 2
    drawLabel(x0, ty - 1, label, withAlpha(black, 102), st)
    drawLabel(x0, ty, label, if enabled: white else: mixColor(white, bg, 0.5), st)
    if hit.focused: focusDots(inset(r, 3))
    if accessOn: accessNode(arButton, label, id = id, r = r, states = offIf(enabled))
    return hit.clicked
  elif matteLook() and primary:
    roundRect(r, float(dp(2)), if hit.down: mixColor(accentColor(), black, 0.2) else: accentColor())
    ink = accentInk()
  elif modernGlass() and not back:
    # (Glass: a pill of glass on the bar, its label in the highlight; the one that finishes the
    # page the highlight's glowing blue, its label white)
    let pr = float(r.h) / 2
    if primary:
      glassBlue(r, pr, hit.down, glow = false)
      ink = white
    elif glassFx():
      glassSurface(r, pr, if hit.down: mixColor(th.field, th.text, 0.08) else: th.field, lift = 2)
      ink = accentText()
    else:
      glassPlate(r, pr, if hit.down: mixColor(th.field, th.text, 0.08) else: th.field, lift = 2)
      ink = accentText()
  elif glassFx() and back:
    # (the modern glass effect: Back a capsule of glass too, its point and label in the highlight)
    glassSurface(r, float(r.h) / 2, if hit.down: mixColor(th.field, th.text, 0.08) else: th.field, lift = 2)
    ink = accentText()
  elif glassLook():
    if hit.down or hit.showsHover:
      roundRect(r, glassRadius(r), withAlpha(th.text, if hit.down: 40 else: 18))
    ink = accentText()
  else:
    buttonFace(r, hit.down, 1, hot = enabled and hit.hover)
    ink = th.text
  # (a label straight on a bar of the app's own color: in its words' color, `MobileStyle`)
  if mobileStyle.bar.a != 0 and glassLook() and (back or not modernGlass()) and not (matteLook() and primary):
    ink = titleColors(true).fg
  if not enabled: ink = mixColor(ink, bg, 0.55)
  let cw = if back: dp(11) else: 0
  let bold = modernGlass() and not back
  let tw = labelWidth(label, bold)
  let x0 = r.x + (r.w - tw - cw) div 2
  if back:
    chevron(x0 + dp(3), r.y + r.h div 2, max(dp(9), FontH * 2 div 3), true, ink,
            max(1.5, float(dp(2))))
  drawLabel(x0 + cw, r.y + (r.h - FontH) div 2, label, ink, bold)
  if hit.focused: focusDots(inset(r, 2))
  if accessOn: accessNode(arButton, label, id = id, r = r, states = offIf(enabled))
  hit.clicked

proc navBar*(title: string; back = ""; action = ""; enabled = true; done = false;
             menu = false): NavPick =
  ## A phone's navigation bar, the width of the row: the page's `title` in the middle, bold;
  ## a Back button before it (`back`: its label, a chevron before it; "" for none) and a
  ## button after it (`action`). Returns what was pressed. Alt+Left is Back too. Classic: a
  ## raised bar; Glass and Matte: the title bar's, its buttons' labels in the highlight; Gloss:
  ## the glossy blue-gray bar, white title, bordered buttons, Back with a point. `done`: the
  ## action is the one that finishes the page (Done, Save): blue in Gloss, filled in Matte.
  ## `menu` (with no `back`): the button at its start is three lines -- the app's `sideMenu` --
  ## and returns `npBack`. (With a `PageStack`, `pageHeader` says Back by itself.)
  let h = if fingers(): dp(44) else: max(dp(32), CtrlH + dp(8))
  let cell = place(0, h, fill = true)
  let full = bleed(cell)
  let r = rect(full.x, cell.y, full.w, h)     # (its buttons and title: in the cell's height)
  let key = "navbar:" & title
  let own = mobileStyle.bar.a != 0        # (the app's color for its bars: `MobileStyle`)
  let bg = if glassLook() or own: titleColors(true).bg else: th.face
  let fg = if mobileStyle.barText.a != 0: mobileStyle.barText
           elif glassLook() or own: titleColors(true).fg else: th.text
  if glassFx() and not own:
    # (the modern glass effect: no band -- the page's own face, its buttons glass floating on it)
    fill(full, th.window)
  elif glassLook():
    titleBar(full, true)
    # (a soft shadow under it on the page, as the bar stood over it; Glass: a hairline)
    if glossLook(): glossBarShadow(full)
    elif modernGlass(): hline(full.x, full.y + full.h - 1, full.w, glassHair())
  else:
    fill(full, bg)
    hline(full.x, full.y, full.w, th.light)
    hline(full.x, full.y + full.h - 2, full.w, th.shadow)
    hline(full.x, full.y + full.h - 1, full.w, th.frame)
  # (Gloss: iOS 6's buttons -- 29 high on a 44 bar, 10 either side of their label, at least
  # 32 for it; Back's point 13 wide, 8 after its label)
  let bh = if glossLook(): min(h - dp(10), if fingers(): dp(29) else: CtrlH)
           elif modernGlass() and action.len > 0: min(h - dp(12), if fingers(): dp(32) else: CtrlH)
           else: h - (if fingers(): dp(12) else: dp(8))
  let by = r.y + (h - bh) div 2
  let gloss = glossLook()
  let bst = glossButtonStyle()
  let glassPill = if fingers(): dp(34) else: CtrlH        # (Glass: its round buttons)
  let leftW = if back.len == 0: (if menu: (if gloss: dp(40) elif modernGlass(): glassPill else: dp(36)) else: 0)
              elif gloss: min(bh div 2, dp(13)) + max(dp(24), labelWidth(back, bst)) + dp(10)
              else: labelWidth(back) + dp(11) + dp(18)
  let rightW = if action.len == 0: 0
               elif gloss: max(dp(32), labelWidth(action, bst)) + dp(20)
               elif modernGlass(): max(dp(40), labelWidth(action, true) + dp(28))
               else: labelWidth(action) + dp(18)
  let edge = if gloss: dp(5) elif modernGlass(): dp(8) else: dp(6)
  let backH = if modernGlass(): h - (if fingers(): dp(12) else: dp(8)) else: bh
  if back.len > 0 and navButton(idOf(key & ":back"), rect(r.x + edge, r.y + (h - backH) div 2, leftW, backH),
                                back, true, false, bg, enabled):
    result = npBack
  if back.len == 0 and menu:
    # (the side menu's button: three lines on a bar button)
    let mr = if modernGlass(): rect(r.x + edge, r.y + (h - glassPill) div 2, glassPill, glassPill)
             else: rect(r.x + edge, by, leftW, bh)
    let mid = idOf(key & ":menu")
    var mh = interact(mid, mr, enabled = enabled)
    if enabled: spaceKey(mid, mh)
    var ink = fg
    if gloss: glossBarButton(mr, mh.down)
    elif modernGlass():
      # (a round button of glass, its lines in the highlight)
      if glassFx(): glassSurface(mr, float(mr.h) / 2, if mh.down: mixColor(th.field, th.text, 0.1) else: th.field,
                                 lift = 2)
      else: glassPlate(mr, float(mr.h) / 2, if mh.down: mixColor(th.field, th.text, 0.1) else: th.field, lift = 2)
      ink = accentText()
    elif glassLook():
      if mh.down or mh.showsHover: roundRect(mr, glassRadius(mr), withAlpha(th.text, if mh.down: 40 else: 18))
      ink = accentText()
    else: buttonFace(mr, mh.down, 1, hot = enabled and mh.hover)
    if gloss: ink = white
    let lw = if modernGlass(): mr.w * 7 div 16 else: min(mr.w - dp(16), dp(18))
    let t = max(1, dp(2))
    let gap = max(t + 2, dp(5))
    for k in -1 .. 1:
      let ly = mr.y + mr.h div 2 + k * gap - t div 2
      if gloss: fill(rect(mr.x + (mr.w - lw) div 2, ly - 1, lw, t), withAlpha(black, 102))
      fill(rect(mr.x + (mr.w - lw) div 2, ly, lw, t), ink)
    if mh.focused: focusDots(inset(mr, 2))
    if accessOn: accessNode(arButton, "Menu", id = mid, r = mr)
    if mh.clicked: result = npBack
  if action.len > 0 and navButton(idOf(key & ":action"), rect(r.x + r.w - edge - rightW, by, rightW, bh),
                                  action, false, done, bg, enabled):
    result = npAction
  # the title in the middle of the bar, short of the buttons
  let st = if glossLook(): style(bold = true, size = if fingers(): 1.333 else: 1.2)
           elif modernGlass(): style(bold = true, size = if fingers(): 1.2 else: 1.1)
           else: style(bold = true)
  let t = ellipsize(tr(title), max(dp(24), r.w - 2 * (max(leftW, rightW) + dp(12))), st)
  let tw = textWidth(t, st)
  let tx = r.x + (r.w - tw) div 2
  let ty = r.y + (h - lineHeight(st)) div 2
  if glossLook(): text(tx, ty - 1, t, withAlpha(black, 102), st)    # (pressed in, as Gloss writes on bars)
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
  if glossLook(): dp(6) else: 2

proc wheelStyle(): TextStyle =
  ## (a wheel's rows: Gloss's bold, iOS 6's 25 points on a phone)
  if glossLook(): style(bold = true, size = if fingers(): 1.67 else: 1.15) else: TextStyle()

proc drumSide(x, y, h: int; left: bool) =
  ## (Gloss: a drum's side at `x` -- a black line, then a band of lavender gray fading into the
  ## drum, to its right (`left`: the drum's left side) or to its left)
  let edge = if onDarkWindow(): mixColor(drumColor(), black, 0.5) else: glossTint(color(200, 202, 220))
  let n = max(4, dp(4))
  for k in 1 .. n:
    vline(if left: x + k else: x - k, y, h, mixColor(edge, drumColor(), float(k - 1) / float(n)))
  vline(x, y, h, black)

proc drumColumn(c: Rect) =
  ## (Gloss: a wheel's white drum, its sides shaded as it turns away)
  fill(c, drumColor())
  if c.w < 12: return
  drumSide(c.x, c.y, c.h, true)
  drumSide(c.x + c.w - 1, c.y, c.h, false)

proc glossDrumFrame(o, u: Rect) =
  ## (Gloss: the picker's dark glass round its wheels -- `o` its outside, `u` the wheels --, lit
  ## as glass at its top, a black line round the wheels and a faint light one under them)
  let bg = glossTint(color(32, 33, 47))
  let rad = float(dp(6))
  for strip in [rect(o.x, o.y, o.w, u.y - o.y), rect(o.x, u.y + u.h, o.w, o.y + o.h - u.y - u.h),
                rect(o.x, u.y, u.x - o.x, u.h), rect(u.x + u.w, u.y, o.x + o.w - u.x - u.w, u.h)]:
    if strip.w <= 0 or strip.h <= 0: continue
    pushClip(strip)
    glossTwoTone(o, rad, mixColor(bg, white, 0.35), mixColor(bg, white, 0.1), bg, mixColor(bg, white, 0.05))
    hline(o.x + int(rad), o.y, o.w - 2 * int(rad), withAlpha(black, 153))
    hline(o.x + int(rad), o.y + 1, o.w - 2 * int(rad), withAlpha(white, 102))
    roundFrame(rect(u.x - 1, u.y - 1, u.w + 2, u.h + 3), float(dp(4)), 1, withAlpha(white, 51))
    roundFrame(rect(u.x - 1, u.y - 1, u.w + 2, u.h + 2), float(dp(4)), 1, black)
    popClip()

proc drumFace(r: Rect; enabled, focused: bool) =
  ## (a wheel's frame and face: Gloss's dark glass round a white drum)
  if glossLook():
    let u = inset(r, drumFrame())
    glossDrumFrame(r, u)
    drumColumn(u)
  elif glassLook(): fieldFace(r, th.field, enabled, focused)
  else: fieldFace(r, th.field, enabled)

proc glossWheelBand(band: Rect) =
  ## (Gloss: the band across the wheels, under its rows -- iOS 6's pane of lavender glass, its
  ## top half lighter with a hard edge at its middle)
  let base = if onDarkWindow(): mixColor(drumColor(), glossTint(color(85, 92, 153)), 0.5)
             else: glossTint(color(170, 173, 204))
  glossTwoTone(band, 0, mixColor(base, white, 0.8), mixColor(base, white, 0.2), base, mixColor(base, white, 0.2))

proc drumOverlay(inner, band: Rect; enabled, focused: bool) =
  ## (over the rows: the drum darker or fading toward its top and foot; the band across it)
  pushClip(inner)
  let third = inner.h div 3
  let dark = onDarkWindow()
  if glossLook():
    # (a drum: darker toward its top and its foot, darkest at its very ends; the band's lines,
    # and its shadow on the rows under it -- its glass is under the rows, `glossWheelBand`)
    let edge = max(4, inner.h div 14)
    fade(rect(inner.x, inner.y, inner.w, edge), black, if dark: 190 else: 150, 0)
    fade(rect(inner.x, inner.y + inner.h - edge, inner.w, edge), black, 0, if dark: 190 else: 150)
    fade(rect(inner.x, inner.y, inner.w, third), black, if dark: 140 else: 102, 0)
    fade(rect(inner.x, inner.y + inner.h - third, inner.w, third), black, 0, if dark: 140 else: 102)
    fade(rect(band.x, band.y + band.h, band.w, max(3, dp(5))), black, 77, 0)
    hline(band.x, band.y, band.w, withAlpha(black, 166))
    hline(band.x, band.y + 1, band.w, withAlpha(white, 26))
    hline(band.x, band.y + band.h - 1, band.w, withAlpha(black, 100))
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
  ## The height of a wheel picker's row (taller for fingers; Gloss's iOS 6's 44 there).
  if fingers(): (if glossLook(): dp(44) else: dp(34)) else: ItemH + dp(7)

proc wheelImpl(items: openArray[string]; gen: proc (i: int): string; count: int; sel: var int;
               rows, w: int; enabled: bool; key, label: string): bool =
  template itemAt(i: int): string = (if gen != nil: gen(i) else: items[i])
  let n = max(0, count)
  let rows = max(3, rows or 1)                 # (odd: a row in the middle)
  let rh = wheelRowH()
  var ww = w
  if ww <= 0:
    if gen == nil:
      for s in items: ww = max(ww, textWidth(s, wheelStyle()))
    elif n > 0:
      for i in [0, n - 1, clamp(sel, 0, n - 1)]: ww = max(ww, textWidth(itemAt(i), wheelStyle()))
    ww += dp(30)
  let r = place(ww, rh * rows + 4)
  let id = if key.len > 0: idOf("wheel:" & key) else: idOf(sel, "wheel")
  let hit = interact(id, r, enabled = enabled and n > 0)
  # (in a group: its face alone, the group's frame and band round them all at its end)
  let grouped = wheelGroupOn and glassLook()
  if grouped:
    fill(r, drumColor())             # (Gloss: its sides drawn with the group's, `endWheelGroup`)
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
  elif glossLook():
    pushClip(rect(inner.x + 1, inner.y, inner.w - 2, inner.h))
    glossWheelBand(band)
    popClip()
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
      # (Gloss: black, as iOS 6's -- the drum's shading darkens the rows toward its ends)
      let c = if pass == 2: bandInk
              elif glossLook(): mixColor(fieldInk, drumColor(), min(0.4, (1 - cos(ang)) * 0.45))
              else: mixColor(fieldInk, drumColor(), min(0.82, 0.3 + (1 - cos(ang)) * 0.9))
      let st = wheelStyle()
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
  let rh = wheelRowH()
  let band = rect(u.x, u.y + u.h div 2 - rh div 2, u.w, rh)
  # (between the wheels: the drum's color -- Gloss: the band across too, a dark line in the
  # middle with each drum's side shaded either side of it, and at the group's ends)
  for i in 1 ..< wheelRects.len:
    let a = wheelRects[i - 1].r
    let b = wheelRects[i].r
    if b.x > a.x + a.w:
      let gap = rect(a.x + a.w, u.y, b.x - a.x - a.w, u.h)
      fill(gap, drumColor())
      if glossLook():
        pushClip(gap)
        glossWheelBand(band)
        popClip()
    if glossLook():
      let mid = (a.x + a.w + b.x) div 2
      let lw = max(2, dp(2))
      drumSide(mid - lw div 2 - 1, u.y, u.h, false)
      drumSide(mid + lw - lw div 2, u.y, u.h, true)
      fill(rect(mid - lw div 2, u.y, lw, u.h), black)
  if glossLook():
    drumSide(u.x, u.y, u.h, true)
    drumSide(u.x + u.w - 1, u.y, u.h, false)
  drumOverlay(u, band, true, false)
  if glossLook():
    let f = drumFrame()
    glossDrumFrame(rect(u.x - f, u.y - f, u.w + 2 * f, u.h + 2 * f), u)
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
  for m in monthNames: monthW = max(monthW, textWidth(tr(m), wheelStyle()))
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
        if wheelPicker(daysInMonth(d.year, d.month), dayLabel, day, w = textWidth("30", wheelStyle()) + dp(30),
                       enabled = enabled, key = k & "d", label = tr("Day")): changed = true
      of 1:
        accessName(tr("Month"))
        if wheelPicker(12, proc (i: int): string = tr(monthNames[i]), mon, w = monthW + dp(30),
                       enabled = enabled, key = k & "m", label = tr("Month")): changed = true
      else:
        accessName(tr("Year"))
        if wheelPicker(years.b - years.a + 1, proc (i: int): string = $(first + i), yr,
                       w = textWidth("2000", wheelStyle()) + dp(30), enabled = enabled, key = k & "y",
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
                     w = textWidth("12", wheelStyle()) + dp(30), enabled = enabled, key = k & "h",
                     label = tr("Hours")): changed = true
    elif wheelPicker(24, twoDigits, hi, w = textWidth("00", wheelStyle()) + dp(30), enabled = enabled,
                     key = k & "h", label = tr("Hours")): changed = true
    accessName(tr("Minutes"))
    if wheelPicker(60 div step, proc (i: int): string = twoDigits(i * step), mi,
                   w = textWidth("00", wheelStyle()) + dp(30), enabled = enabled, key = k & "m",
                   label = tr("Minutes")): changed = true
    if hours12:
      if wheelPicker(["AM", "PM"], half, w = max(textWidth("AM", wheelStyle()), textWidth("PM", wheelStyle())) + dp(30),
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
    if glossLook():
      # (iOS 6's: white dots in a dark halo, a shadow under them, the others half as strong)
      let k = if i == page: 1.0 else: 0.5
      let rd = float(d) / 2 - 0.5
      disc(cx, cy + 1.5, rd, withAlpha(black, int(51 * k)))
      disc(cx, cy, rd + 1.5, withAlpha(black, int(110 * k)))
      disc(cx, cy, rd, if enabled: withAlpha(white, int(235 * k)) else: withAlpha(th.gray, int(235 * k)))
      continue
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

type SheetKind = enum skBottom, skMiddle, skPopover, skSide

var
  sheetSeen: Table[Id, int]                            # (the frame each was drawn last: one just opened slides in)
  sheets: seq[tuple[id: Id; was: Id; r: Rect]]         # (those being drawn, one in another)
  sheetRect: Rect                                      # (where the one begun last is: its caller draws its face)

proc sheetGlass(): Color =
  ## (Glass: the face of a sheet, an alert, an action sheet's cards -- white glass on a light
  ## window, smoked glass on a dark one, so its words in the scheme's ink read on it)
  if onDarkWindow(): mixColor(th.field, th.face, 0.35) else: th.field

proc ownCharcoal(): bool {.inline.} =
  ## (Gloss's side menu in iOS 6's charcoal: a scheme of its own, no colors of the app's)
  glossOwnScheme() and mobileStyle.bar.a == 0 and mobileStyle.sideMenu.a == 0

proc sideMenuFace(): Color =
  ## (a side menu's face: Gloss's charcoal, as the menus that slid out from under a page had it --
  ## in another scheme the bars' color, darker --; the window's in the other looks;
  ## `MobileStyle.sideMenu`)
  if mobileStyle.sideMenu.a != 0: mobileStyle.sideMenu
  elif glossLook(): (if ownCharcoal(): color(44, 45, 48) else: glossBarColors().foot)
  else: th.window

proc sideGlass(r: Rect): Rect =
  ## (Glass: the side menu's card in its sheet `r`: under the status bar, over the gesture bar,
  ## in from the screen's edge)
  let m = dp(10)
  rect(r.x + (if ui.rtl: 0 else: m), r.y + ui.safe.top + m, r.w - m, r.h - ui.safe.top - ui.safe.bottom - 2 * m)

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
          elif kind == skSide: min(dp(width), room.w - dp(56))
          else: min(dp(width), room.w - 2 * dp(8))
  let h = if kind == skSide: room.h
          else: min(handleH + titleH + st.aux + 2 * Pad + below + 2 * edge, room.h - dp(24))
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
  of skSide:
    # (from the left edge -- the right one in a right-to-left interface -- sliding in)
    y = room.y
    x = if ui.rtl: room.x + room.w - w else: room.x
    if smoothScrolling and ui.now - st.aux2 < 220:
      let t = 1.0 - (ui.now - st.aux2) / 220
      let off = int(float(w) * t * t * t)
      x += (if ui.rtl: off else: -off)
      wakeIn(16)
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
    # (what is behind it, dimmed: Gloss as iOS 6 dimmed it, by half)
    fill(room, withAlpha(black, if glossLook(): 128 elif onDarkWindow(): 120 else: 80))
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
  let rad = if kind == skSide: 0.0
            elif matteLook(): float(dp(2))
            elif glassLook(): float(if kind == skPopover: dp(10) else: dp(14)) else: 0.0
  let fr = if kind == skBottom: rect(r.x, r.y, r.w, r.h + int(rad)) else: r
  sheetRect = r
  let navy = (glossTone(0.385, 0.41), glossTone(0.65, 0.13))
  if not drawFace: discard
  elif kind == skSide and modernGlass():
    # (Glass: a card of frosted glass over the page, in from the screen's edges, its corners round)
    let g = sideGlass(fr)
    softShadow(g, float(dp(22)), 8)
    if not frostedFace(g, sheetGlass(), float(dp(22))): roundRect(g, float(dp(22)), withAlpha(sheetGlass(), 246))
    roundFrame(g, float(dp(22)), 1, if onDarkWindow(): withAlpha(white, 30) else: withAlpha(white, 200))
  elif kind == skSide:
    # (its shadow on the page beside it; its face the menu's: Gloss's charcoal, the others' window)
    let sx = if ui.rtl: fr.x - dp(6) else: fr.x + fr.w
    for k in 0 ..< dp(6):
      let a = 70 * (dp(6) - k) div dp(6)
      let lx = if ui.rtl: fr.x - 1 - k else: sx + k
      fill(rect(lx, fr.y, 1, fr.h), withAlpha(black, a))
    fill(fr, sideMenuFace())
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
  if kind == skSide and modernGlass():
    # (in the card, below its rounded top)
    let g = sideGlass(r)
    pushFrame(rect(g.x + dp(4), g.y + dp(10), g.w - dp(8), g.h - dp(20)))
  elif kind == skSide:
    # (its items from one side to the other, under the status bar: the whole height, for a panel)
    pushFrame(rect(r.x, r.y + ui.safe.top, r.w, r.h - ui.safe.top - ui.safe.bottom))
  else:
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
    # (iOS 6's: a gray sheet, see-through -- black on a dark window --, a shadow over what is
    # behind it, the light along its top fading out)
    let dark = onDarkWindow()
    let rad = float(if compact: 0 else: dp(10))
    if compact:
      hline(sr.x, sr.y - 1, sr.w, withAlpha(black, 102))
      hline(sr.x, sr.y - 2, sr.w, withAlpha(black, 40))
    else: softShadow(sr, rad, 5)
    roundRect(sr, rad, if dark: withAlpha(black, 153) else: withAlpha(glossTint(color(93, 98, 109)), 204))
    let fade = dp(30)
    var light = newSeq[int](fade)
    for k in 0 ..< fade: light[k] = int(float(if dark: 89 else: 102) * (1 - k / fade))
    light[0] = max(light[0], 178)
    if fade > 1: light[1] += 50
    glossTopShade(sr, rad, light, white)
  let bh = if fingers(): dp(44) else: CtrlH + dp(10)
  let titleInk = if gloss: color(235, 236, 240) else: th.gray
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
  let cardRad = float(dp(14))
  if cards and actions.len > 0:
    let top = if title.len > 0: titleR.y - dp(6) elif message.len > 0: messageR.y - dp(6) else: blockR.y
    let card = rect(blockR.x, top, blockR.w, blockR.y + blockR.h - top)
    if not frostedFace(card, sheetGlass(), cardRad): roundRect(card, cardRad, withAlpha(sheetGlass(), 245))
    if top < blockR.y: hline(blockR.x, blockR.y, blockR.w, glassHair())
  if title.len > 0:
    # (Gloss: iOS 6's small title, not bold)
    let st = if gloss: style(size = if fingers(): 0.93 else: 1.0) else: style(bold = true)
    let t = ellipsize(tr(title), titleR.w, st)
    let tx = titleR.x + (titleR.w - textWidth(t, st)) div 2
    if gloss: text(tx, titleR.y - 1, t, withAlpha(black, 110), st)
    text(tx, titleR.y + (if cards: dp(4) else: 0), t, titleInk, st)
  if message.len > 0:
    let t = ellipsize(tr(message), messageR.w)
    text(messageR.x + (messageR.w - textWidth(t)) div 2, messageR.y, t, titleInk)
  var focusedAt = -1
  for i in 0 .. actions.len:
    let isCancel = i == actions.len
    if isCancel: space(if gloss: dp(14) else: dp(8))
    let a = if isCancel: cancel else: actions[i]
    let r0 = if joined and not isCancel: rect(blockR.x, blockR.y + i * bh, blockR.w, bh)
             else: place(0, bh, fill = true)
    # (Gloss: iOS 6's buttons 20 in from the sheet's sides)
    let r = if gloss and r0.w > dp(120): rect(r0.x + dp(12), r0.y, r0.w - dp(24), r0.h) else: r0
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
      glossSheetButton(r, hit.down, if i == destructive: 1 elif isCancel: 2 else: 0)
      ink = if i == destructive or isCancel or hit.down: white else: color(0, 0, 0)
    elif cards:
      if isCancel:
        if not frostedFace(r, sheetGlass(), cardRad): roundRect(r, cardRad, withAlpha(sheetGlass(), 245))
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
    let lst = if gloss: style(bold = true, size = if fingers(): 1.33 else: 1.1)
              elif cards and fingers(): style(bold = bold, size = 1.15)
              else: style(bold = bold)
    let lw = labelWidth(a, lst)
    let ly = r.y + (r.h - lineHeight(lst)) div 2
    if gloss:
      if ink == white: drawLabel(r.x + (r.w - lw) div 2, ly - 1, a, withAlpha(black, 102), lst)
      else: drawLabel(r.x + (r.w - lw) div 2, ly + 1, a, withAlpha(white, 102), lst)
    drawLabel(r.x + (r.w - lw) div 2, ly, a, ink, lst)
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

# ---- a side menu: the app's places, sliding out from the left ---------------------------------------

proc beginSideMenu*(open: var bool; width = 280): bool =
  ## Starts a side menu (see `sideMenu`): true while it is `open`.
  beginSheet(open, idOf(open, "sidemenu"), "", skSide, width)

proc endSideMenu*() =
  ## Ends a `beginSideMenu`.
  endSheet()

template sideMenu*(open: var bool; width: int; body: untyped) =
  ## The app's places in a menu that slides out from the left edge while `open` (the right one
  ## in a right-to-left interface), over the page -- dimmed beside it --, as tall as the window,
  ## `width` pixels wide at most: its `sideMenuItem`s and `sideMenuHeader`s, a search box, a
  ## panel when they are many. Esc, the phone's Back, a tap beside it close it. On a tablet the
  ## same items sit down the left of the window, always there (`sideMenuItem` outside a
  ## `sideMenu`). Gloss: the charcoal menu that slid out from under a page, its headers in
  ## lighter bars.
  if beginSideMenu(open, width):
    try:
      body
    finally:
      endSideMenu()

proc sideMenuBack*(r: Rect) =
  ## The face of a side menu's items drawn outside a `sideMenu` -- a tablet's column of them
  ## down the left: Gloss's charcoal, the window in the other looks.
  fill(r, sideMenuFace())

proc sideMenuHeader*(title: string) =
  ## A section's header in a side menu (or a column of its items): Gloss a lighter bar, its
  ## title gray; the other looks the title small, gray.
  let st = style(bold = true, size = 0.85)
  let h = lineHeight(st) + dp(8)
  let r = place(0, h, fill = true)
  if glossLook():
    let f = sideMenuFace()
    if ownCharcoal():
      roundRectShaded(r, 0, color(84, 86, 90), color(68, 70, 74))
      hline(r.x, r.y, r.w, color(104, 106, 110))
      hline(r.x, r.y + r.h - 1, r.w, color(36, 37, 40))
    else:
      roundRectShaded(r, 0, mixColor(f, white, 0.25), mixColor(f, white, 0.15))
      hline(r.x, r.y, r.w, mixColor(f, white, 0.38))
      hline(r.x, r.y + r.h - 1, r.w, mixColor(f, black, 0.2))
    text(r.x + dp(12), r.y + (h - lineHeight(st)) div 2 + 1, tr(title), withAlpha(black, 120), st)
    text(r.x + dp(12), r.y + (h - lineHeight(st)) div 2, tr(title), color(196, 198, 202), st)
  else:
    text(r.x + dp(12), r.y + h - lineHeight(st) - dp(2), tr(title).toUpper, th.gray, st)
  if accessOn: accessNode(arHeading, title, r = r)

proc sideMenuItem*(title: string; glyph = ""; detail = ""; selected = false; enabled = true;
                   key = ""): bool =
  ## An item of a side menu (or of a tablet's column of them): its icon, its title, a gray
  ## `detail` at its end (a count); `selected`: the place shown now, drawn chosen. True when
  ## clicked or tapped (Enter, Space with the focus). Gloss: white on the charcoal, a light line
  ## along its top and a dark one under it, the chosen one darker with the highlight's bar at
  ## its edge.
  let h = if fingers(): dp(44) else: FontH + dp(16)
  let r = place(0, h, fill = true)
  let id = idOf("sidemenuitem:" & (if key.len > 0: key else: title))
  var hit = interact(id, r, enabled = enabled)
  if enabled:
    spaceKey(id, hit)
    if hit.focused:
      ui.takesEnter = true
      if keyHit(KeyEnter): hit.clicked = true
  let gloss = glossLook()
  let on = selected or hit.down
  var ink, sub: Color
  if gloss:
    let f = sideMenuFace()
    if on:
      if ownCharcoal(): roundRectShaded(r, 0, color(28, 29, 31), color(36, 37, 40))
      else: roundRectShaded(r, 0, mixColor(f, black, 0.36), mixColor(f, black, 0.18))
      fill(rect(if ui.rtl: r.x + r.w - dp(4) else: r.x, r.y, dp(4), r.h), glossTint(color(36, 112, 216)))
    else:
      hline(r.x, r.y, r.w, withAlpha(white, 16))
    hline(r.x, r.y + r.h - 1, r.w, if ownCharcoal(): color(26, 27, 29) else: mixColor(f, black, 0.4))
    ink = if enabled: white else: color(120, 120, 124)
    sub = color(150, 152, 158)
  elif modernGlass():
    let p = rect(r.x + dp(6), r.y + dp(3), r.w - dp(12), r.h - dp(6))
    if selected: glassBlue(p, float(min(dp(12), p.h div 2)), hit.down, glow = false)
    elif hit.down: roundRect(p, float(min(dp(12), p.h div 2)), withAlpha(th.text, 26))
    ink = if selected: white elif enabled: th.text else: th.gray
    sub = if selected: withAlpha(white, 210) else: th.gray
  elif glassLook():
    if on: roundRect(inset(r, dp(4)), float(dp(8)), withAlpha(accentColor(), if hit.down: 70 else: 46))
    ink = if enabled: th.text else: th.gray
    sub = th.gray
  else:
    if on: fill(r, th.select)
    ink = if on: th.selectText elif enabled: th.text else: th.gray
    sub = if on: th.selectText else: th.gray
  if mobileStyle.sideMenuText.a != 0 and enabled and not (modernGlass() and selected):
    ink = mobileStyle.sideMenuText
    sub = mixColor(ink, sideMenuFace(), 0.35)
  var x = r.x + dp(14)
  if glyph.len > 0:
    let gs = style(size = 1.15)
    let gw = max(dp(24), textWidth(glyph, gs))
    let gc = if gloss: (if on: white else: color(186, 188, 194))
             elif modernGlass() and selected: white
             elif glassLook() and not on: accentText()
             elif modernGlass(): accentText()
             else: ink
    text(x + (gw - textWidth(glyph, gs)) div 2, r.y + (h - lineHeight(gs)) div 2, glyph, gc, gs)
    x += gw + dp(12)
  var endX = r.x + r.w - dp(14)
  if detail.len > 0:
    let dt = ellipsize(detail, max(dp(30), (endX - x) div 3))
    text(endX - textWidth(dt), r.y + (h - FontH) div 2, dt, sub)
    endX -= textWidth(dt) + dp(8)
  let bold = gloss
  if gloss: text(x, r.y + (h - FontH) div 2 - 1, ellipsize(tr(title), endX - x, style(bold = bold)), withAlpha(black, 140), bold)
  text(x, r.y + (h - FontH) div 2, ellipsize(tr(title), endX - x, style(bold = bold)), ink, bold)
  if hit.focused: focusDots(inset(r, 2))
  if accessOn:
    accessNode(arButton, title, value = detail, id = id, r = r,
               states = offIf(enabled) + (if selected: {asSelected} else: {}))
  ui.lastId = id
  ui.lastRect = r
  hit.clicked

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
  if not beginSheet(open, sid, "", skMiddle, if glossLook(): 276 else: 284, drawFace = false, tapCloses = false,
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
    # (iOS 6's: dark blue, see-through, a white line round it, the shine across its top curved
    # at its foot)
    let rad = float(dp(10))
    softShadow(r, rad, 5)
    let e = max(2, dp(2))
    roundFrame(r, rad, float(e), withAlpha(white, 178))
    let f = inset(r, e)
    roundRect(f, rad - float(e), withAlpha(glossTint(color(8, 26, 80)), 214))
    pushClip(rect(f.x, f.y, f.w, dp(29)))
    disc(float(f.x + f.w div 2), float(f.y + dp(29)) - float(f.w) * 1.4, float(f.w) * 1.4, withAlpha(white, 46))
    popClip()
    ink = white
    sub = glossTone(0.05, 0.96)
  elif glass:
    let rad = float(dp(14))
    if not frostedFace(r, sheetGlass(), rad): roundRect(r, rad, withAlpha(sheetGlass(), 245))
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
    # (Gloss: iOS 6's sizes -- the title 18, the message 16 -- wrapped as wide as they are)
    let k = if not gloss: 1.0 elif bold: (if fingers(): 1.2 else: 1.1) else: (if fingers(): 1.07 else: 1.0)
    let st = style(bold = bold, size = k)
    let lh = (if gloss: lineHeight(st) else: FontH) + dp(2)
    let lines = wrapLines(tr(txt), (if k > 1.0: int(float(room) / k) - 1 else: room), bold)
    let br = place(0, lines.len * lh, fill = true)     # (its lines close together)
    for i, ln in lines:
      let lr = rect(br.x, br.y + i * lh, br.w, lh)
      let tw = textWidth(ln, st)
      let tx = if centered: lr.x + (lr.w - tw) div 2 else: lr.x
      if gloss: text(tx, lr.y - 1, ln, withAlpha(black, 204), st)
      text(tx, lr.y, ln, c, st)
  space(dp(8))
  let bh = if gloss and fingers(): dp(40) elif fingers(): dp(44) else: CtrlH + dp(8)
  let side = buttons.len == 2
  let pairR = if side: place(0, bh, fill = true) else: Rect()
  let between = if gloss: dp(10) else: dp(6)
  if glass:
    # (its buttons across its foot, a hairline over them and between them)
    let top = if side: pairR.y else: frameBottom()
    hline(r.x, top - dp(2), r.w, glassHair())
  if canInput() and ui.focus == 0 and buttons.len > 0: ui.focus = sid + Id(buttons.len)
  for i, b in buttons:
    let br = if side: rect(pairR.x + (if i == 0: 0 else: pairR.w - (pairR.w - between) div 2), pairR.y,
                           (pairR.w - between) div 2, bh)
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
      glossAlertButton(br, hit.down, primary = i == buttons.high and buttons.len > 1)
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
    let bst = if gloss: style(bold = true, size = if fingers(): 1.2 else: 1.0) else: style(bold = bold)
    let lw = labelWidth(b, bst)
    let ly = br.y + (br.h - lineHeight(bst)) div 2
    if gloss: drawLabel(br.x + (br.w - lw) div 2, ly - 1, b, withAlpha(black, 160), bst)
    drawLabel(br.x + (br.w - lw) div 2, ly, b, lc, bst)
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
    toggled*: bool   ## `checkRow`: its check was tapped (Space): ticked or not
    menu*: bool      ## `tableRow`: a right click on it or a finger held on it: the app's menu
                     ## for it (an `actionSheet`)

var
  tableGroups: seq[tuple[id: Id; r: Rect; rows, rowsBefore, gap: int; footer: string]]
  tableNo: tuple[frame, n: int]

proc tableRadius(): float =
  if mobileStyle.groupCorner < 0: 0.0
  elif mobileStyle.groupCorner > 0: float(dp(1)) * mobileStyle.groupCorner
  elif glossLook(): float(dp(9)) elif matteLook(): 0.0 elif glassLook(): float(dp(14)) else: 0.0

proc tableRowH(two: bool): int =
  let base = if mobileStyle.rowHeight > 0: dp(mobileStyle.rowHeight)
             elif fingers(): dp(44) else: max(dp(30), FontH + dp(14))
  if two: max(base + dp(10), 2 * FontH + dp(14)) else: base

proc beginTableGroup*(header = ""; footer = "") =
  ## Starts a group of table rows (see `tableGroup`).
  if tableNo.frame != ui.frameNo: tableNo = (ui.frameNo, 0)
  inc tableNo.n
  if header.len > 0:
    let gloss = glossLook()
    let st = if gloss: style(bold = true, size = 1.05)
             elif glassLook() and not matteLook(): style(bold = true, size = 0.8)
             else: style(bold = true, size = 0.9)
    let t = if glassLook() and not gloss and not matteLook(): tr(header).toUpper else: tr(header)
    let hr = place(0, lineHeight(st) + dp(if fingers(): 10 else: 4), fill = true)
    let tx = hr.x + (if modernGlass(): dp(16) elif glassLook(): dp(12) else: 0)
    let ty = hr.y + hr.h - lineHeight(st) - dp(2)
    if gloss:
      if not onDarkWindow(): text(tx, ty + 1, t, withAlpha(white, 204), st)
      text(tx, ty, t, if onDarkWindow(): color(196, 200, 210) else: glossTint(color(76, 86, 108)), st)
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
  if mobileStyle.group.a != 0:
    if glassLook() and not glossLook() and not matteLook(): glassPlate(cell, rad, mobileStyle.group)
    else: roundRect(cell, rad, mobileStyle.group)
  elif glossLook(): roundRect(cell, rad, if onDarkWindow(): th.field else: color(247, 247, 247))   # (an off-white, as then)
  elif matteLook(): discard
  elif glassLook(): glassPlate(cell, rad, th.field)
  else: fill(cell, th.field)
  tableGroups.add (id, cell, 0, st.aux2, ui.m.gap, footer)
  ui.m.gap = 0
  pushFrame(rect(cell.x, cell.y, cell.w, 0))

proc floatingRow(gid: Id; g: Rect)

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
    # (iOS 6's: a faint dark line round it, a shadow inside along its top, a light line under it)
    roundFrame(r, rad, 1, if onDarkWindow(): black else: withAlpha(black, 46))
    if not onDarkWindow():
      glossTopShade(inset(r, 1), rad - 1, [26])
      hline(r.x + int(rad), r.y + r.h, r.w - 2 * int(rad), withAlpha(white, 204))
  elif matteLook():
    hline(r.x, r.y, r.w, mixColor(th.window, th.text, 0.16))
    hline(r.x, r.y + r.h - 1, r.w, mixColor(th.window, th.text, 0.16))
  elif glassLook(): discard
  else: fieldFrame(r)
  floatingRow(g.id, r)
  if g.footer.len > 0:
    let gloss = glossLook()
    let room = cellRoom() - (if glassLook(): 2 * dp(12) else: 0)
    let note = tr(g.footer)
    let lines = wrapLines(note, room)
    let lh = FontH + dp(1)
    let rtl = textIsRtl(note)       # (Arabic: from the right where it is not in the middle)
    # (one place for its lines: close together, not a row's gap apart)
    let fr = place(0, lines.len * lh, fill = true)
    for i, ln in lines:
      let lr = rect(fr.x, fr.y + i * lh, fr.w, lh)
      let tw = textWidth(ln)
      let inner = if glassLook() and not gloss: rect(lr.x + dp(12), lr.y, lr.w - 2 * dp(12), lh) else: lr
      let tx = if gloss: lr.x + (lr.w - tw) div 2 else: lineStart(inner, tw, rtl)
      if gloss:
        if not onDarkWindow(): text(tx, lr.y + 1, ln, withAlpha(white, 204))
        text(tx, lr.y, ln, if onDarkWindow(): color(176, 180, 190) else: glossTint(color(76, 86, 108)))
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
    let lc = if mobileStyle.groupLine.a != 0: mobileStyle.groupLine
             elif gloss: (if onDarkWindow(): mixColor(th.field, white, 0.08) else: color(217, 217, 217))
             elif glassLook() and not matteLook(): glassHair()
             else: mixColor(th.field, th.fieldText, 0.14)
    let lx = if glassLook() and not gloss and not matteLook(): r.x + dp(14) else: r.x + 1
    hline(lx, r.y, r.x + r.w - 1 - lx, lc)
    # (Gloss: a white line under it, as iOS 6's rows)
    if gloss and not onDarkWindow() and not pressed: hline(lx, r.y + 1, r.x + r.w - 1 - lx, withAlpha(white, 204))
  if pressed:
    pushClip(r)
    if gloss: glossBlue(g, rad)
    elif matteLook(): fill(r, mixColor(th.window, accentColor(), 0.32))
    elif glassLook():
      popClip()
      let pr = rect(r.x + dp(5), r.y + dp(3), r.w - dp(10), r.h - dp(6))
      glassBlue(pr, float(min(dp(11), pr.h div 2)))
      pushClip(r)
    else: fill(r, th.select)
    popClip()
  let classicPressed = pressed and not glassLook()
  let lit = pressed and (gloss or modernGlass())
  result.first = first
  result.last = last
  result.ink = if lit or classicPressed: (if lit: white else: th.selectText)
               else: th.fieldText
  result.sub = if lit: (if gloss: white else: withAlpha(white, 210)) elif classicPressed: th.selectText else: th.gray
  result.link = if lit: white
                elif classicPressed: th.selectText
                elif mobileStyle.rowDetail.a != 0: mobileStyle.rowDetail
                elif gloss: glossDetail()
                elif glassLook(): th.gray
                else: th.gray
  if mobileStyle.rowText.a != 0 and not lit and not classicPressed: result.ink = mobileStyle.rowText

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
      let c = if tint.a != 0: tint else: accentColor()
      if pressed and modernGlass(): roundRect(inset(t, -1), rad + 1, withAlpha(white, 120))
      roundRectShaded(t, rad, mixColor(c, white, 0.2), mixColor(c, black, 0.08))
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
               selected = false; count = ""): TableHit =
  ## A row of a `tableGroup`: an icon (`glyph`, an icon font's -- Gloss and Glass draw it white
  ## on a rounded tile, gray or `tint`) or a `picture` (a cover, a face: square, its corners
  ## rounded), its `title`, a gray
  ## `subtitle` under it, a `detail` at its end (Gloss: in its blue-gray, as values were
  ## written), and an `accessory` -- a chevron (it leads to another page), a check mark (the
  ## one chosen) or an info button. A click, a tap, Enter or Space: `clicked`; the info
  ## button: `info`. `key`: its own id (rows of the same title). `selected`: the row whose
  ## page is shown beside the list (a tablet's): drawn chosen -- Gloss's blue. `count`: a
  ## number in a capsule before the end ("3" unread; Gloss: iOS 6's slate gray, white on it).
  ## A right click or a finger held on it: `menu` -- the app shows what can be done to it (an
  ## `actionSheet`).
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
  if enabled and ui.rpressed and canInput() and mouseIn(r) and not mouseIn(ir):
    result.menu = true
    result.clicked = false
  let pressed = (hit.down and not ih.down) or (selected and enabled)
  let (_, _, ink0, sub, link) = rowFrame(r, pressed)
  let gloss = glossLook()
  let lit = pressed and (gloss or modernGlass())     # (on the blue: white)
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
               if lit: white elif gloss: color(123, 123, 123) else: th.gray)
    endX -= dp(if gloss: 20 else: 18)
  of taCheck:
    rowCheck(endX - dp(7), r.y + r.h div 2,
             if lit: white elif gloss: link elif glassLook(): accentText() else: ink)
    endX -= dp(24)
  of taInfo:
    let cx = float(ir.x) + float(d) / 2
    let cy = float(ir.y) + float(d) / 2
    if gloss:
      disc(cx, cy, float(d) / 2, if onDarkWindow(): black else: color(255, 255, 255))
      let blue = glossTint(color(36, 112, 216))
      discShaded(cx, cy, float(d) / 2 - 1.5, mixColor(blue, if ih.down: black else: white, 0.3),
                 if ih.down: mixColor(blue, black, 0.25) else: blue)
      chevron(int(cx) + 1, int(cy), d * 2 div 5, false, white, max(1.6, float(dp(2))))
    else:
      let ic = if lit: white else: accentText()
      ring(cx, cy, float(d) / 2, max(1.3, float(dp(1)) + 0.3), ic)
      let it = "i"
      text(int(cx) - textWidth(it, true) div 2, int(cy) - FontH div 2, it, ic, true)
    endX = ir.x - dp(8)
  of taNone: discard
  if count.len > 0:
    let cst = style(bold = true, size = if gloss and fingers(): 1.13 else: 1.0)
    let ch = lineHeight(cst) + dp(2)
    let cw = max(ch * 3 div 2, textWidth(count, cst) + dp(14))
    let cr = rect(endX - cw, r.y + (r.h - ch) div 2, cw, ch)
    let cbg = if lit and gloss: white
              elif lit: withAlpha(white, 230)
              elif gloss: (if onDarkWindow(): color(90, 96, 110) else: glossTint(color(135, 149, 175)))
              elif modernGlass(): mixColor(th.field, accentColor(), if onDarkWindow(): 0.3 else: 0.14)
              elif glassLook(): mixColor(th.window, th.text, 0.15)
              else: th.shadow
    roundRect(cr, float(ch) / 2, cbg)
    if gloss and not pressed: glossTopShade(cr, float(ch) / 2, [51])
    let cink = if lit and gloss: glossTint(color(135, 149, 175))
               elif lit or modernGlass(): accentText()
               elif gloss: white elif glassLook(): th.text else: th.light
    text(cr.x + (cw - textWidth(count, cst)) div 2, cr.y + (ch - lineHeight(cst)) div 2, count, cink, cst)
    endX -= cw + dp(8)
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
    accessNode(if accessory == taChevron: arButton else: arListItem, title,
               value = (if count.len > 0 and detail.len > 0: detail & ", " & count else: detail & count), id = id,
               r = r, states = offIf(enabled) + (if accessory == taCheck or selected: {asSelected} else: {}))
    if accessory == taInfo: accessNode(arButton, "More about " & title, id = id + 1, r = ir)
  ui.lastId = id
  ui.lastRect = r

proc checkRow*(title: string; v: var bool; detail = ""; subtitle = ""; accessory = taNone;
               flagged = false; detailColor = Color(); enabled = true; key = ""): TableHit =
  ## A row of a `tableGroup` with a round check at its start -- a to-do, a reminder: a tap on the
  ## check ticks it or not (`toggled`; Space with the focus), a tap on the rest of the row is
  ## `clicked` (Enter) -- its page. Ticked, its title is gray. `detail` at its end (a due date;
  ## `detailColor`: red when it is late), `subtitle` under the title, `flagged`: an orange flag
  ## before the end, `accessory` as `tableRow`'s. Gloss: the check a shining blue disc with a
  ## white tick, an empty ring before; Glass and Matte in the highlight; Classic 3.1's round
  ## check.
  let two = subtitle.len > 0
  let r = place(0, tableRowH(two), fill = true)
  let gid = if tableGroups.len > 0: tableGroups[^1].id else: Id(0)
  let id = Id(mixId(uint32(gid), fnv("checkrow:" & (if key.len > 0: key else: title))))
  let pad = if fingers(): dp(12) else: dp(10)
  let d = if fingers(): dp(24) else: max(dp(18), FontH + dp(2))
  let cr = rect(r.x + pad, r.y + (r.h - d) div 2, d, d)
  let ch = interact(id + 1, inset(cr, -dp(8)), focusable = false, enabled = enabled)
  var hit = interact(id, r, enabled = enabled)
  if enabled:
    if hit.focused and canInput():
      ui.takesEnter = true
      if keyHit(KeyEnter): hit.clicked = true
      if keyHit(KeySpace): result.toggled = true
    if ch.clicked: result.toggled = true
  if result.toggled: v = not v
  result.clicked = hit.clicked and not ch.clicked
  let (_, _, ink0, sub, link) = rowFrame(r, hit.down and not ch.down)
  let gloss = glossLook()
  let pressed = hit.down and not ch.down and gloss
  let cx = float(cr.x) + float(d) / 2
  let cy = float(cr.y) + float(d) / 2
  let rad = float(d) / 2
  if v:
    let base = if gloss: glossTint(color(36, 112, 216)) else: accentColor()
    if gloss:
      disc(cx, cy + 1, rad, withAlpha(black, 50))
      discShaded(cx, cy, rad, mixColor(base, white, 0.35), mixColor(base, black, 0.1))
    elif glassLook(): disc(cx, cy, rad, base)
    else:
      disc(cx, cy, rad, th.frame)
      disc(cx, cy, rad - 1, th.field)
    let k = float(d) * 0.22
    let w = max(1.8, float(dp(2)) + 0.2)
    let c = if gloss or glassLook(): white else: th.fieldText
    thickLine(cx - k * 1.1, cy, cx - k * 0.25, cy + k * 0.9, w, c)
    thickLine(cx - k * 0.25, cy + k * 0.9, cx + k * 1.2, cy - k * 0.9, w, c)
  else:
    let ring0 = if gloss: color(170, 170, 170) elif glassLook(): mixColor(th.field, th.fieldText, 0.35)
                else: th.frame
    ring(cx, cy, rad - 0.75, max(1.2, float(dp(1)) + 0.3), if ch.down: accentColor() else: ring0)
    if gloss: glossTopShade(cr, rad, [30])
  var x = cr.x + d + dp(10)
  var endX = r.x + r.w - pad
  if accessory == taChevron:
    rowChevron(endX - dp(4), r.y + r.h div 2, if pressed: white elif gloss: color(123, 123, 123) else: th.gray)
    endX -= dp(if gloss: 20 else: 18)
  if flagged:
    let fw = dp(10)
    let fh = dp(12)
    let fx = endX - fw
    let fy = r.y + (r.h - fh) div 2
    let fc = color(255, 149, 0)
    fill(rect(fx, fy, max(1, dp(1)), fh), fc)
    polygon([(float(fx + 1), float(fy)), (float(fx + fw), float(fy) + float(fh) * 0.25),
             (float(fx + 1), float(fy) + float(fh) * 0.55)], fc)
    endX -= fw + dp(8)
  if detail.len > 0:
    let dt = ellipsize(detail, max(dp(30), (endX - x) div 2))
    let dw = textWidth(dt)
    text(endX - dw, r.y + (r.h - FontH) div 2, dt,
         if pressed: white elif detailColor.a != 0: detailColor else: link)
    endX -= dw + dp(10)
  let ink = if not enabled or v: th.gray elif pressed: white else: ink0
  let bold = gloss and not v
  if two:
    let y0 = r.y + (r.h - 2 * FontH - dp(2)) div 2
    text(x, y0, ellipsize(title, endX - x, style(bold = bold)), ink, bold)
    text(x, y0 + FontH + dp(2), ellipsize(subtitle, endX - x), if pressed: white else: sub)
  else:
    text(x, r.y + (r.h - FontH) div 2, ellipsize(title, endX - x, style(bold = bold)), ink, bold)
  if hit.focused: focusDots(inset(r, 2))
  if accessOn:
    accessNode(arCheckBox, title, value = detail, id = id, r = r,
               states = offIf(enabled) + (if v: {asChecked} else: {}),
               help = "Space ticks it; Enter opens it")
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
            elif hit.down and (gloss or modernGlass() or not glassLook()): ink0
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

# ---- settings rows ------------------------------------------------------------------------------

type SettingCell = tuple[r, ctl: Rect; textW: int; hit: Hit; link: Color; lit: bool]

proc settingRow(title, detail: string; controlW: int; stack: var bool; ctlH = -1;
                pid = Id(0); enabled = true): SettingCell =
  ## The cell of a settings row: the title and its detail at the left, the
  ## control at the right (or under them, when the row is narrow). In a `tableGroup`: a row of
  ## it, as a phone's settings are -- the title bold in Gloss, the line between the rows, its
  ## detail gray under the title; `pid`: the row is pressed as one (it leads somewhere), its
  ## face lit while it is down.
  let inGroup = tableGroups.len > 0
  let ch = if ctlH < 0: CtrlH else: ctlH
  let pad = if not inGroup: dp(8) elif fingers(): dp(12) else: dp(10)
  let w = available()
  stack = controlW > w * 11 div 20
  let textW = if stack: w - 2 * pad else: w - controlW - 3 * pad
  let st = style(size = 0.9)
  let lines = if detail.len > 0: wrapLines(tr(detail), textW) else: @[]
  let textH = FontH + lines.len * lineHeight(st) + (if inGroup and lines.len > 0: dp(2) else: 0)
  let minH = if inGroup: tableRowH(lines.len > 0) elif fingers(): dp(52) else: dp(36)
  let h = if stack: textH + ch + dp(20) else: max(minH, max(textH, ch) + dp(14))
  let r = place(0, h, fill = true)
  ui.lastRect = r
  if pid != Id(0):
    result.hit = interact(pid, r, enabled = enabled)
    if enabled:
      spaceKey(pid, result.hit)
      if result.hit.focused:
        ui.takesEnter = true
        if keyHit(KeyEnter): result.hit.clicked = true
      if mnemonicHit(title): result.hit.clicked = true
  var ink = th.text
  var sub = th.gray
  result.link = th.gray
  if inGroup:
    let pressed = pid != Id(0) and result.hit.down
    let f = rowFrame(r, pressed)
    ink = f.ink
    sub = f.sub
    result.link = f.link
    result.lit = pressed and (glossLook() or modernGlass())
  if not enabled: ink = th.gray
  var y = if stack: r.y + dp(6) else: r.y + (r.h - textH) div 2
  drawLabel(r.x + pad, y, title, ink, inGroup and glossLook())
  if accessOn:
    accessLabelFor(title)
    if detail.len > 0: accessNode(arLabel, tr(detail), id = 0, r = rect(r.x, y + FontH, textW, h - FontH))
  y += FontH + (if inGroup: dp(2) else: 0)
  for line in lines:
    text(r.x + pad, y, line, sub, st)
    y += lineHeight(st)
  result.r = r
  result.textW = textW
  result.ctl = if stack: rect(r.x + pad, r.y + r.h - ch - dp(8), r.w - 2 * pad, ch)
               else: rect(r.x + r.w - controlW - pad, r.y + (r.h - ch) div 2, controlW, ch)

proc settingToggle*(title: string; v: var bool; detail = "";
                    enabled = true): bool {.discardable.} =
  ## A settings row: a title, a line or two of detail, and a switch at the
  ## right; a click anywhere on the row flips it. True when it changed. In a `tableGroup`: a
  ## row of it, as a phone's settings have them (`tableSwitch`, with the detail under the
  ## title).
  var stack = false
  let (sw, sh) = switchSize()
  let c = settingRow(title, detail, sw, stack, ctlH = sh)
  let r = c.r
  let id = idOf(v, title)
  var hit = interact(id, r, enabled = enabled)
  if enabled:
    spaceKey(id, hit)
    if mnemonicHit(title): hit.clicked = true
  let track = rect(c.ctl.x + c.ctl.w - sw, r.y + (r.h - sh) div 2, sw, sh)
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
  let c = settingRow(title, detail, widths, stack)
  pushFrame(rect(c.ctl.x, c.ctl.y, c.ctl.w, 0))
  result = segmented(options, v, w = (if stack: c.ctl.w else: widths), enabled = enabled)
  discard popFrame()
  ui.lastRect = c.r

proc choiceParts(s: string): tuple[name, more: string] =
  ## ("Classic (Windows 3.1)": "Classic" and "Windows 3.1" -- a choice's name, and what it is)
  let t = tr(s)
  let k = strutils.find(t, " (")
  if k > 0 and strutils.endsWith(t, ")") and k + 2 < t.len - 1:
    (t[0 ..< k], capitalize(t[k + 2 .. ^2]))
  else: (t, "")

var
  choiceFor: Id     # (the settings row whose choices are open: a page of them)
  choiceSince: int  # (the frame it opened in)
  choiceDrawn: int  # (... the frame it was drawn in last: a row gone, its page closed)
  choicePicked: tuple[id: Id; v: int] = (Id(0), -1)
    # (one chosen on a page drawn after its dialog: taken by its row the next frame)

proc choicePage(id: Id; title, detail: string; options: openArray[string]; v: var int;
                enabled: bool): bool =
  ## (a row's choices, as a phone's settings showed them: a page -- or a dialog -- of rows, a
  ## check by the chosen one; a tap chooses, Close goes back)
  var open = true
  choiceDrawn = ui.frameNo
  if beginDialog(open, title, 380):
    try:
      tableGroup("", detail):
        for i, o in options:
          let (name, more) = choiceParts(o)
          let hit = tableRow(name, subtitle = more, accessory = (if i == v: taCheck else: taNone),
                             key = $i & ":" & o, enabled = enabled)
          # (the chosen one brought into sight as the page opens: a long list's)
          if i == v and ui.frameNo - choiceSince <= 2: bringIntoSight(ui.lastRect)
          if hit.clicked and i != v:
            v = i
            result = true
    finally:
      endDialog()
  if not open: choiceFor = Id(0)

proc settingCombo*(title: string; options: openArray[string]; v: var int;
                   detail = ""; enabled = true): bool {.discardable.} =
  ## A settings row with a drop-down list at the right (a choice of many). In a `tableGroup`: a
  ## row of it with the chosen one at its end and a chevron, as a phone's settings have them --
  ## a tap shows the choices on a page of their own (a dialog where dialogs are windows), a check
  ## by the chosen one; "Name (what it is)" is shown as the name, what it is under it.
  if tableGroups.len > 0:
    let id = idOf("settingcombo:" & title)
    let value = if v >= 0 and v < options.len: choiceParts(options[v]).name else: ""
    let chevW = dp(if glossLook(): 20 else: 18)
    let vw = min(textWidth(value) + dp(8), available() * 2 div 5)
    var stack = false
    let c = settingRow(title, detail, chevW + vw, stack, ctlH = FontH, pid = id, enabled = enabled)
    let r = c.r
    let pad = if fingers(): dp(12) else: dp(10)
    let endX = r.x + r.w - pad
    rowChevron(endX - dp(4), r.y + r.h div 2,
               if c.lit: white elif glossLook(): color(123, 123, 123) else: th.gray)
    let shown = ellipsize(value, vw - dp(4))
    text(endX - chevW - textWidth(shown), r.y + (r.h - FontH) div 2, shown,
         if not enabled: th.gray else: c.link)
    # (its page left open while the row was not drawn -- another look, another page --: closed)
    if choiceFor == id and ui.frameNo - choiceDrawn > 1: choiceFor = Id(0)
    if enabled and choiceFor != id and (c.hit.clicked or accessPressed == id):
      choiceFor = id
      choiceSince = ui.frameNo
    if c.hit.focused: focusDots(inset(r, 2))
    if accessOn:
      accessNode(arComboBox, title, value = (if v >= 0 and v < options.len: tr(options[v]) else: ""),
                 id = id, r = r, states = accessOff(enabled) + {asExpandable} +
                                         (if choiceFor == id: {asExpanded} else: {}))
    if choicePicked.id == id:
      if choicePicked.v != v and choicePicked.v >= 0 and choicePicked.v < options.len:
        v = choicePicked.v
        result = true
      choicePicked = (Id(0), -1)
    if choiceFor == id:
      if ui.curDialog == 0: result = choicePage(id, title, detail, options, v, enabled) or result
      else:
        # (a row in a dialog -- an app's Appearance --: its page drawn as that dialog ends, over
        # it, not under the rows after this one)
        let opts = @options
        let now = v
        afterDialog(proc () =
          var w = now
          if choicePage(id, title, detail, opts, w, enabled):
            choicePicked = (id, w)
            ui.redraw = true)
    ui.lastId = id
    ui.lastRect = r
    return
  var widest = 0
  for o in options: widest = max(widest, labelWidth(o))
  let cw = widest + SbW + dp(20)
  var stack = false
  let c = settingRow(title, detail, cw, stack)
  pushFrame(rect(c.ctl.x, c.ctl.y, c.ctl.w, 0))
  result = combo(options, v, w = (if stack: c.ctl.w else: cw), enabled = enabled)
  discard popFrame()
  ui.lastRect = c.r

proc settingSlider*(title: string; v: var int; lo, hi: int; detail = "";
                    suffix = ""; enabled = true): bool {.discardable.} =
  ## A settings row with a slider and its value ("120%").
  var stack = false
  let vw = textWidth($hi & suffix) + dp(8)
  let c = settingRow(title, detail, dp(200) + vw, stack)
  pushFrame(rect(c.ctl.x, c.ctl.y, c.ctl.w, 0))
  row:
    result = slider(v, lo, hi, w = c.ctl.w - vw - Gap, ticks = 0, enabled = enabled)
    label $v & suffix
  discard popFrame()
  ui.lastRect = c.r

proc settingButtons*(title: string; buttons: openArray[string]; detail = "";
                     enabled = true): int =
  ## A settings row with buttons (`["Smaller", "Normal", "Larger"]`);
  ## which was clicked (1-based), 0 if none.
  var widths = 0
  for b in buttons: widths += max(dp(56), labelWidth(b) + dp(20)) + Gap
  var stack = false
  let c = settingRow(title, detail, widths, stack)
  pushFrame(rect(c.ctl.x, c.ctl.y, c.ctl.w, 0))
  row:
    if not stack: spring()
    for i, b in buttons:
      if button(b, enabled = enabled, w = max(dp(56), labelWidth(b) + dp(20))):
        result = i + 1
  discard popFrame()
  ui.lastRect = c.r

proc settingLink*(title: string; detail = ""; glyph = nfChevronRight;
                  enabled = true): bool =
  ## A settings row that leads somewhere (another page, a dialog): true
  ## when clicked. In a `tableGroup`: a row of it with a chevron, lit while it is pressed.
  var stack = false
  let gw = textWidth(glyph) + dp(8)
  let id = idOf("settinglink:" & title)
  let c = settingRow(title, detail, gw, stack, ctlH = FontH, pid = id, enabled = enabled)
  let r = c.r
  if tableGroups.len > 0 and glyph == nfChevronRight:
    let pad = if fingers(): dp(12) else: dp(10)
    rowChevron(r.x + r.w - pad - dp(4), r.y + r.h div 2,
               if c.lit: white elif glossLook(): color(123, 123, 123) else: th.gray)
  else:
    text(c.ctl.x + c.ctl.w - gw, r.y + (r.h - FontH) div 2, glyph, if c.lit: white else: th.gray)
  if c.hit.focused: focusDots(inset(r, 2))
  if accessOn:
    accessNode(arButton, title, id = id, r = r, states = accessOff(enabled), help = tr(detail))
  ui.lastId = id
  ui.lastRect = r
  c.hit.clicked

var stepKeep: Table[string, int]   # (the steppers' segments: none chosen)

proc stepRow(title, value: string; enabled = true): int =
  ## (a settings row with its value and a stepper at its end, - and +, as a phone's: -1 or 1
  ## when one is pressed)
  let sw = if fingers(): dp(94) else: dp(64)
  let sh = if fingers(): min(CtrlH, dp(30)) else: CtrlH
  let vw = textWidth(value) + dp(12)
  var stack = false
  let c = settingRow(title, "", sw + vw, stack, ctlH = sh)
  discard stepKeep.hasKeyOrPut(title, -1)
  stepKeep[title] = -1
  text(c.ctl.x + c.ctl.w - sw - vw + dp(4), c.r.y + (c.r.h - FontH) div 2, value,
       if enabled: c.link else: th.gray)
  let was = ui.m.ctrlH
  ui.m.ctrlH = sh
  pushFrame(rect(c.ctl.x + c.ctl.w - sw, c.ctl.y, sw, 0))
  if segmented(["−", "+"], stepKeep[title], w = sw, enabled = enabled):
    result = if stepKeep[title] == 0: -1 else: 1
  discard popFrame()
  ui.m.ctrlH = was
  stepKeep[title] = -1
  ui.lastRect = c.r

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
  ## Settings rows for how every app looks: the color scheme, the look of the controls
  ## (`uiLook`: Classic, Glass, Matte or Gloss), the size of
  ## everything, the size of the text, the size of controls (for a mouse
  ## or fingers), the window's frame (on desktops: the system's or Windows
  ## 3.1's), the title bars' buttons (`captionButtons`) and the font. In an
  ## Android or iOS app only the look, its colors, the sizes and the font. With touch sizes in
  ## Glass, Matte or Gloss: in groups, as a phone's settings are -- a choice a row with a
  ## chevron and a page of its own, the sizes with - and +. True
  ## when something changed (store them with
  ## `storeAppearance`; `app`'s `look` keeps them by itself).
  result = appearanceRows()
  if result: noteLookChanged()

const phoneSystem = androidApp or defined(ios)
  ## (an Android or iOS app: Appearance has what matters on a phone or a tablet -- the look, its
  ## colors, the sizes, the font --, not a desktop's frame, title bar buttons, drawing, icons)

proc appearanceRows(): bool =
  # (with touch sizes in Glass, Matte or Gloss: the rows in groups, as a phone's settings --
  # not when the app has put them in a group of its own)
  let framed = fingers() and glassLook() and tableGroups.len == 0
  template framedGroup(header, footer: string; body: untyped) =
    if framed: beginTableGroup(header, footer)
    try:
      body
    finally:
      if framed: endTableGroup()
  var t = max(0, themeIndex())
  var names: seq[string]
  for th in builtinThemes: names.add th.name
  framedGroup("", if framed: "With Light or dark as the system, the look's own colors are dark when the system's are."
            else: ""):
    # (the controls' look, in whatever scheme: Windows 3.1's, or frosted glass)
    var lk = ord(uiLook)
    if settingCombo("Look", ["Classic (Windows 3.1)", "Glass", "Matte", "Gloss"], lk):
      let was = uiLook
      uiLook = UiLook(lk)
      # (a look picked with a scheme of before, or with another look's own: its own colors with
      # it, light or dark as the scheme was)
      let (wl, wd) = lookSchemes(was)
      if uiLook != lookClassic and (t in [0, 1, 2, 3] or (was != lookClassic and ui.theme in [wl, wd])):
        let dark = t in [2, 3] or ui.theme == wd
        let (l, d) = lookSchemes(uiLook)
        ui.theme = if dark: d else: l
        t = max(0, themeIndex())
      invalidate()
      result = true
    if settingCombo("Color scheme", names, t):
      ui.theme = builtinThemes[t].theme
      systemColors = false
      invalidate()
      result = true
    # (the look's own colors, light or dark as the system is: a phone's way -- a scheme picked
    # turns it off)
    if settingToggle("Light or dark as the system", systemColors,
                     if framed: "" else: "The look's own colors, dark when the system is"):
      invalidate()
      result = true
    if uiLook == lookGlass:
      if settingToggle("Glass effect", glassEffect,
                       if framed: "" else: "The tab bar floating over the page, the buttons and menus of glass"):
        invalidate()
        result = true
      if settingToggle("See-through menus and dialogs", frostedGlass,
                       if framed: "" else: "What is under them shows blurred, as through frosted glass"):
        invalidate()
        result = true
  framedGroup("Sizes", ""):
    if framed:
      case stepRow("Size of everything", $uiScale() & "%")
      of -1: setUiScale(scaleStep(-1)); result = true
      of 1: setUiScale(scaleStep(1)); result = true
      else: discard
      case stepRow("Size of the text", $textScale() & "%")
      of -1: setTextScale(textScale() - 10); result = true
      of 1: setTextScale(textScale() + 10); result = true
      else: discard
    else:
      case settingButtons("Size of everything", ["Smaller", "Normal", "Larger"],
                          $uiScale() & "%")
      of 1: setUiScale(scaleStep(-1)); result = true
      of 2: setUiScale(100); result = true
      of 3: setUiScale(scaleStep(1)); result = true
      else: discard
    var cs = ord(controlSizes())
    # (on a phone or a tablet too: Glass and Gloss have touch sizes there, and a tablet's user may
    # want the desktop's back)
    if settingCombo("Controls", [if phoneSystem: "Automatic (touch sizes in Glass and Gloss)"
                                 else: "Automatic (touch sizes on phones)",
                                 "Desktop sizes (mouse, pen)", "Touch sizes (fingers)"], cs):
      setControlSizes(ControlSizes(cs))
      result = true
    if framed and (uiScale() != 100 or textScale() != 100):
      if tableButton("Normal Sizes"):
        setUiScale(100)
        setTextScale(100)
        result = true
    if not framed:
      case settingButtons("Size of the text", ["A-", "A", "A+"], $textScale() & "%")
      of 1: setTextScale(textScale() - 10); result = true
      of 2: setTextScale(100); result = true
      of 3: setTextScale(textScale() + 10); result = true
      else: discard
  framedGroup(if framed: "Text" else: "", ""):
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
    if uiFont() == ufFile:
      if framed:
        if settingLink("Font file", uiFontPath.extractFilenameOf): fontFileOpen = true
      elif settingButtons("Font file", ["Choose..."], uiFontPath.extractFilenameOf) == 1: fontFileOpen = true
    when not androidApp and not defined(ios):
      if pxScale == 1:
        var sharp = if subpixelText(): 0 else: 1
        if settingCombo("Text edges", ["Sharp", "Smooth"], sharp):
          setSubpixelText(sharp == 0)
          result = true
  if not phoneSystem:
    framedGroup(if framed: "This Computer" else: "", ""):
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
      var smooth = smoothScrolling
      if settingToggle("Smooth scrolling", smooth,
                       "Lists and pages glide; a flicked finger keeps them moving"):
        setSmoothScrolling(smooth)
        result = true
  if fileDialog(fontFileOpen, fontFilePath, fmOpen, ["Fonts (*.ttf;*.otf;*.ttc;*.otc)", "All Files (*.*)"],
                "Font File"):
    try:
      loadUiFontFile(fontFilePath)
      result = true
    except CatchableError:
      fontFileError = fontFilePath.extractFilenameOf & ": not a font we read"
  if fontFileError.len > 0:
    label(fontFileError, color = color(160, 0, 0))

# ---- a shelf of cards ----------------------------------------------------------------------------

type ShelfCard* = tuple[title, subtitle: string; picture: Bitmap; glyph: string]
  ## A card of a `cardShelf`: its picture (nil: `glyph` on a tint instead), its title, a line
  ## under it.

proc cardShelf*(cards: openArray[ShelfCard]; key: string; side = 0;
                art: proc (i: int; r: Rect) {.closure.} = nil): int =
  ## A shelf of cards in a row the finger slides sideways, as phone apps show "your playlists"
  ## or "recently played": each a square picture with rounded corners, its title and a gray line
  ## under it; `side` its width (0: about a third of a phone's). Returns the one tapped (-1:
  ## none). A wheel or Shift+wheel slides it too; the cards are read as buttons. A card with no
  ## picture: `art` draws card `i`'s in `r` when it is given (its corners rounded), else its
  ## glyph on a tint.
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
    elif art != nil:
      masked(pic, float(dp(10))):
        art(i, pic)
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
  if gloss and not onDarkWindow(): glossSearchFill(full)    # (lighter than a navigation bar, as then)
  elif gloss: glossBarFill(full)
  elif matteLook():
    fill(full, th.face)
    hline(full.x, full.y + full.h - 1, full.w, mixColor(th.face, th.text, 0.2))
  elif modernGlass(): fill(full, titleColors(true).bg)       # (the navigation bar's glass, the box a capsule on it)
  elif glassLook(): fill(full, mixColor(th.window, th.face, 0.5))
  else:
    fill(full, th.face)
    hline(full.x, full.y, full.w, th.light)
    hline(full.x, full.y + full.h - 1, full.w, th.shadow)
  let bst = if gloss: glossButtonStyle() else: style()
  let cw = if not showCancel: 0
           elif gloss: max(dp(55), labelWidth(cancel, bst) + dp(20))
           else: labelWidth(cancel, bst) + dp(16)
  pushFrame(rect(r.x + dp(8), r.y + (h - EditH) div 2, r.w - dp(16) - (if cw > 0: cw + dp(8) else: 0), 0))
  result = searchBox(s, placeholder)
  discard popFrame()
  if showCancel:
    let bh = if gloss: min(h - dp(12), if fingers(): dp(30) else: CtrlH) else: EditH
    let cr = rect(r.x + r.w - dp(8) - cw, r.y + (h - bh) div 2, cw, bh)
    let cid = boxId + 9
    var ch = interact(cid, cr, focusable = false)
    var ink = accentText()
    if gloss:
      glossBarButton(cr, ch.down, onSearch = not onDarkWindow())
      ink = white
    elif not glassLook():
      buttonFace(cr, ch.down, 1)
      ink = th.text
    elif ch.down: roundRect(cr, glassRadius(cr), withAlpha(th.text, 30))
    let lw = labelWidth(cancel, bst)
    let ly = cr.y + (cr.h - lineHeight(bst)) div 2
    if gloss: drawLabel(cr.x + (cr.w - lw) div 2, ly - 1, cancel, withAlpha(black, 102), bst)
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
  if gloss: glossToolFill(r)
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
    let gbh = min(h - dp(14), if fingers(): dp(29) else: CtrlH)
    let bw = if gloss: min(gbh div 2, dp(13)) + max(dp(24), labelWidth(back, glossButtonStyle())) + dp(10)
             else: labelWidth(back) + dp(34)
    let br = if gloss: rect(inner.x + dp(5), inner.y + (h - gbh) div 2, bw, gbh)
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
      let bst = glossButtonStyle()
      let lx = br.x + p + (br.w - p - dp(8) - labelWidth(back, bst)) div 2
      let ly = br.y + (br.h - lineHeight(bst)) div 2
      drawLabel(lx, ly - 1, back, withAlpha(black, 102), bst)
      drawLabel(lx, ly, back, white, bst)
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

# ---- more of a phone's parts: round buttons, an index, bubbles, a clock, app icons, surfaces -----

type RoundKind* = enum
  ## What a `roundButton` is for.
  rkAdd,       ## a plus, green: add (a row of an editing list)
  rkRemove,    ## a minus, red: take away (a row of an editing list)
  rkDetail,    ## a chevron, blue: more about it
  rkInfo       ## an "i": about it

proc roundColor(kind: RoundKind): Color =
  case kind
  of rkAdd: color(4, 143, 1)
  of rkRemove: color(189, 20, 33)
  of rkDetail: glossTint(color(36, 112, 216))
  of rkInfo: accentColor()

proc roundSign(cx, cy: float; d: int; kind: RoundKind; c: Color) =
  ## (a round button's sign, `d` across its middle)
  let s = max(5, d * 13 div 23)
  case kind
  of rkAdd: sign(int(cx), int(cy), s, true, c)
  of rkRemove: sign(int(cx), int(cy), s, false, c)
  of rkDetail: chevron(int(cx) + 1, int(cy), s * 2 div 3, false, c, max(1.8, float(dp(2)) + 0.3))
  of rkInfo:
    let st = style(bold = true, size = float(d) / 26)
    text(int(cx) - textWidth("i", st) div 2, int(cy) - lineHeight(st) div 2, "i", c, st)

proc roundFace(cx, cy: float; d: int; kind: RoundKind; down, enabled: bool; upright = false)

proc roundButton*(kind: RoundKind; label = ""; enabled = true): bool =
  ## A small round button with a sign on it, as a phone's lists have them: a green plus to add,
  ## a red minus to take away (an editing list's rows), a blue chevron for more about one, an
  ## "i". `label`: what it does, for its tooltip and screen readers (else the sign's name).
  ## True when clicked (Space and Enter with the focus). Gloss: iOS 6's -- a shining disc, a
  ## white ring round it, a shadow under it; Glass and Matte: a flat disc; Classic: 3.1's
  ## round button, the sign in its color.
  let d = if fingers(): dp(23) else: max(dp(18), FontH + dp(2))
  let r = place(d + dp(4), d + dp(4))
  let name = if label.len > 0: label else: ["Add", "Remove", "More", "About"][ord(kind)]
  let id = idOf("roundbutton:" & $ord(kind) & ":" & name)
  var hit = interact(id, r, enabled = enabled)
  if enabled:
    spaceKey(id, hit)
    if hit.focused:
      ui.takesEnter = true
      if keyHit(KeyEnter): hit.clicked = true
  roundFace(float(r.x) + float(r.w) / 2, float(r.y) + float(r.h) / 2, d, kind, hit.down, enabled)
  if hit.focused: focusDots(inset(r, 1))
  tooltip(name)
  if accessOn: accessNode(arButton, name, id = id, r = r, states = offIf(enabled))
  ui.lastId = id
  ui.lastRect = r
  hit.clicked

proc roundFace(cx, cy: float; d: int; kind: RoundKind; down, enabled: bool; upright = false) =
  ## (a round button's face, `d` across, at its middle: Gloss's shining disc in a white ring,
  ## Glass's flat one, 3.1's raised one; `upright`: its minus turned up, as a row's before its
  ## Delete)
  let rad = float(d) / 2
  var base = if enabled: roundColor(kind) else: mixColor(th.face, th.gray, 0.4)
  if down: base = mixColor(base, black, 0.25)
  template signOf(dy: float; c: Color) =
    if upright and kind == rkRemove:
      let s = max(5, d * 13 div 23)
      let t = max(1, dp(2))
      fill(rect(int(cx) - t div 2, int(cy + dy) - s div 2, t, s), c)
    else: roundSign(cx, cy + dy, d, kind, c)
  if glossLook():
    disc(cx, cy + 2, rad + 1, withAlpha(black, 60))
    disc(cx, cy, rad + 0.5, withAlpha(black, 70))
    disc(cx, cy, rad, white)
    let f = rad - max(1.5, float(dp(2)))
    disc(cx, cy, f, base)
    # (its shine: the top two thirds, white fading)
    pushClip(rect(int(cx - rad), int(cy - f), int(2 * rad) + 1, int(f * 1.28)))
    discShaded(cx, cy, f, mixColor(base, white, 0.4), mixColor(base, white, 0.16))
    popClip()
    signOf(-0.6, withAlpha(black, 60))
    signOf(0.0, white)
  elif glassLook():
    disc(cx, cy, rad, base)
    signOf(0.0, white)
  else:
    disc(cx, cy, rad, th.frame)
    disc(cx, cy, rad - 1, if down: th.shadow else: th.face)
    if not down:
      pushClip(rect(int(cx - rad), int(cy - rad), int(rad * 2) + 1, int(rad)))
      ring(cx, cy, rad - 1, 1.4, th.light)
      popClip()
    signOf(0.0, if enabled: roundColor(kind) else: th.gray)

proc indexBar*(letters: openArray[string]; h = 0): int =
  ## The letters down the side of a long list -- A to Z, a contacts list's: touch one, or drag
  ## along them, and it returns the one under the finger (or the mouse) while it is down -- -1
  ## otherwise --, for the list to go to. `h`: its height (0: as the letters need); too many
  ## for it, every other one shows. Screen readers get a button each. Gloss: iOS 6's gray bold
  ## letters, a gray band behind them while they are touched; Glass and Matte: in the
  ## highlight; Classic: the text's color.
  result = -1
  if letters.len == 0: return
  let st = style(bold = true, size = if fingers(): 0.73 else: 0.8)
  let lh = lineHeight(st)
  var w = if fingers(): dp(28) else: dp(20)
  for l in letters: w = max(w, textWidth(l, st) + dp(6))
  let pad = dp(6)
  let r = place(w, if h > 0: h else: letters.len * (lh + dp(4)) + 2 * pad)
  let id = idOf("indexbar:" & $letters.len & ":" & letters[0] & letters[^1])
  let hit = interact(id, r, focusable = false)
  let held = ui.active == id and ui.mouseDown
  let gloss = glossLook()
  if held:
    ui.dragsActive = true
    result = clamp((ui.my - r.y - pad) * letters.len div max(1, r.h - 2 * pad), 0, letters.high)
    wakeIn(16)
  if held or (hit.showsHover and not gloss):
    roundRect(r, float(w) / 2, if gloss: withAlpha(black, 51) else: withAlpha(th.text, 20))
  let ink = if gloss: (if onDarkWindow(): color(176, 182, 192) else: glossTint(color(106, 115, 125)))
            elif glassLook(): accentText()
            else: th.text
  let step = float(r.h - 2 * pad) / float(letters.len)
  let every = if step >= float(lh) * 0.85: 1 else: int(ceil(float(lh) * 0.85 / step))
  for i, l in letters:
    let y = r.y + pad + int(step * float(i) + (step - float(lh)) / 2)
    if i mod every == 0:
      text(r.x + (r.w - textWidth(l, st)) div 2, y, l, ink, st)
    elif every == 2:
      disc(float(r.x) + float(r.w) / 2, float(y) + float(lh) / 2, max(1.5, float(dp(2))), ink)
    if accessOn:
      let sid = accessSubId(id, i)
      if accessPress == sid:
        accessPress = 0
        result = i
      accessNode(arButton, l, id = sid, r = rect(r.x, r.y + pad + int(step * float(i)), r.w, max(1, int(step))))
  ui.lastId = id
  ui.lastRect = r

type BubbleKind* = enum
  ## Whose a `messageBubble` is, and how it went.
  bkTheirs,     ## the other's: on the left, gray
  bkMine,       ## yours: on the right, in the highlight (Gloss: iOS 6's pale blue)
  bkMineText    ## yours, sent as a text message: on the right, green

proc bubbleTail(r: Rect; right: bool; c: Color) =
  ## (a bubble's tail at its foot, curling out to its side)
  let t = float(max(5, dp(7)))
  let y1 = float(r.y + r.h)
  let x = if right: float(r.x + r.w) else: float(r.x)
  let s = if right: 1.0 else: -1.0
  polygon([(x - s * t * 1.6, y1 - t * 1.9), (x - s * t * 0.2, y1 - t * 1.2), (x + s * t * 0.75, y1),
           (x - s * t * 0.4, y1 - 0.5), (x - s * t * 1.9, y1 - t * 0.6)], c)

proc messageBubble*(text: string; kind = bkTheirs; time = ""; maxW = 0) =
  ## A message of a conversation, as a phone's messages show them: in a bubble with a tail, the
  ## other's (`bkTheirs`) on the left in gray, yours on the right (`bkMine`; `bkMineText`, sent
  ## as a text message: green); `time` (or "Delivered") small under it. Its text wraps at
  ## `maxW` pixels (0: three quarters of the row). Gloss: iOS 6's -- shining, a dark edge, the
  ## words black with a light line under them; Glass: flat, rounded; Matte: flat, nearly
  ## square; Classic: 3.1's colors, a line round it.
  let room = cellRoom()
  let mine = kind != bkTheirs
  let gloss = glossLook()
  let padX = dp(10)
  let padY = dp(if gloss: 3 else: 5)
  let tail = dp(7)
  let maxText = max(dp(40), (if maxW > 0: maxW else: room * 3 div 4) - 2 * padX - tail)
  let lines = wrapLines(tr(text), maxText)
  var tw = 0
  for l in lines: tw = max(tw, textWidth(l))
  let bw = tw + 2 * padX
  let bh = max(lines.len, 1) * FontH + 2 * padY + dp(2)
  let small = style(bold = gloss, size = 0.8)
  let timeH = if time.len > 0: lineHeight(small) + dp(2) else: 0
  let cell = place(0, bh + timeH, fill = true)
  let b = if mine: rect(cell.x + cell.w - tail - bw, cell.y, bw, bh) else: rect(cell.x + tail, cell.y, bw, bh)
  let dark = onDarkWindow()
  var ink = th.text
  if gloss:
    let base = case kind
               of bkTheirs: (if dark: color(84, 86, 92) else: color(221, 221, 221))
               of bkMine: glossTint(color(152, 199, 255))
               of bkMineText: color(140, 207, 62)
    let rad = float(min(dp(13), bh div 2))
    let edge = mixColor(base, black, 0.45)
    # (its shadow, its dark edge, then its face: lighter at its foot, a shine along its top)
    roundRect(rect(b.x, b.y + 1, b.w, b.h), rad, withAlpha(black, 50))
    roundRect(b, rad, edge)
    bubbleTail(rect(b.x, b.y, b.w, b.h), mine, edge)
    let f = inset(b, 1)
    roundRectShaded(f, rad - 1, base, mixColor(base, white, 0.35))
    bubbleTail(inset(rect(b.x, b.y, b.w, b.h), 1), mine, mixColor(base, white, 0.3))
    let shine = rect(f.x + dp(6), f.y, f.w - dp(12), min(dp(13), f.h div 2))
    if shine.w > 0: roundRectShaded(shine, float(shine.h) / 2, mixColor(base, white, 0.7), mixColor(base, white, 0.2))
    ink = if dark and kind == bkTheirs: white else: black
  elif glassLook():
    let base = case kind
               of bkTheirs: mixColor(th.window, th.text, if dark: 0.18 else: 0.1)
               of bkMine: accentColor()
               of bkMineText: color(52, 199, 89)
    let rad = if matteLook(): float(dp(3)) else: float(min(dp(17), bh div 2))
    roundRect(b, rad, base)
    if not matteLook(): bubbleTail(b, mine, base)
    ink = if kind == bkTheirs: th.text elif kind == bkMine: accentInk() else: white
  else:
    let base = if kind == bkTheirs: th.field elif kind == bkMine: th.select else: color(0, 128, 0)
    bubbleTail(b, mine, th.frame)
    roundRect(b, float(dp(6)), th.frame)
    roundRect(inset(b, 1), float(dp(5)), base)
    bubbleTail(inset(b, 1), mine, base)
    ink = if kind == bkTheirs: th.fieldText else: th.selectText
  for i, l in lines:
    let y = b.y + padY + dp(1) + i * FontH
    if gloss and not (dark and kind == bkTheirs): text(b.x + padX, y + 1, l, withAlpha(white, 150))
    text(b.x + padX, y, l, ink)
  if time.len > 0:
    let tw2 = textWidth(time, small)
    let tx = if mine: b.x + b.w - tw2 else: b.x
    let tc = if gloss and not dark: glossTint(color(136, 146, 165)) else: th.gray
    if gloss and not dark: text(tx, b.y + b.h + dp(2) + 1, time, withAlpha(white, 204), small)
    text(tx, b.y + b.h + dp(2), time, tc, small)
  if accessOn: accessNode(arLabel, (if mine: "You: " else: "") & text, value = time, id = 0, r = b)
  ui.lastId = 0
  ui.lastRect = cell

proc clockFace*(h, m: int; s = -1; size = 0; night = false; label = "") =
  ## A clock with hands: the hour `h` (0 to 23), the minute `m`, the second `s` (-1: no second
  ## hand), `size` pixels across (0: as a phone's world clock has it); `label` under it (a
  ## city). Gloss: iOS 6's world clock -- light gray (`night`: black), the hours' numbers, black
  ## hands, a red second hand, a shine across its top; Glass and Matte: flat, the hours as
  ## marks; Classic: 3.1's Clock -- dots for the minutes, squares for the hours.
  let d = if size > 0: size elif fingers(): dp(76) else: dp(96)
  let small = style(bold = true, size = 0.9)
  let lh = if label.len > 0: lineHeight(small) + dp(4) else: 0
  let cell = place(max(d, if label.len > 0: textWidth(label, small) else: 0), d + lh)
  let cx = float(cell.x) + float(cell.w) / 2
  let cy = float(cell.y) + float(d) / 2
  let rad = float(d) / 2
  let gloss = glossLook()
  let glass = glassLook() and not gloss
  var face, ink, mark: Color
  if gloss:
    face = if night: black else: color(222, 222, 222)
    ink = if night: white else: black
    disc(cx, cy - 0.5, rad + 0.5, withAlpha(black, 128))
    if night: disc(cx, cy, rad, black)
    else: discShaded(cx, cy, rad, color(213, 213, 213), color(231, 231, 231))
    # (its numbers, a line of shadow under each)
    let nst = style(bold = true, size = float(d) / 76 * (if fingers(): 0.62 else: 0.55))
    for k in 1 .. 12:
      let a = float(k) * PI / 6
      let nx = cx + sin(a) * rad * 0.79
      let ny = cy - cos(a) * rad * 0.79
      let t = $k
      let x = int(nx) - textWidth(t, nst) div 2
      let y = int(ny) - lineHeight(nst) div 2
      text(x, y + 1, t, if night: withAlpha(black, 204) else: withAlpha(white, 204), nst)
      text(x, y, t, ink, nst)
  elif glass:
    face = th.field
    ink = th.fieldText
    mark = mixColor(th.field, th.fieldText, 0.5)
    disc(cx, cy, rad, if matteLook(): mixColor(th.field, th.fieldText, 0.3) else: glassHair())
    disc(cx, cy, rad - 1, face)
    for k in 0 ..< 12:
      let a = float(k) * PI / 6
      let r0 = if k mod 3 == 0: rad * 0.78 else: rad * 0.85
      thickLine(cx + sin(a) * r0, cy - cos(a) * r0, cx + sin(a) * rad * 0.92, cy - cos(a) * rad * 0.92,
                if k mod 3 == 0: max(2.0, float(dp(2))) else: 1.2, mark)
  else:
    face = th.face
    ink = th.text
    disc(cx, cy, rad, th.frame)
    disc(cx, cy, rad - 1, face)
    for k in 0 ..< 60:
      let a = float(k) * PI / 30
      let px = cx + sin(a) * rad * 0.88
      let py = cy - cos(a) * rad * 0.88
      if k mod 5 == 0:
        let q = max(2, dp(3))
        fill(rect(int(px) - q div 2, int(py) - q div 2, q, q), th.select)
      else: fill(rect(int(px), int(py), 1, 1), th.shadow)
  # the hands
  let hh = (float(h mod 12) + float(m) / 60) * PI / 6
  let mm = (float(m) + (if s >= 0: float(s) / 60 else: 0.0)) * PI / 30
  let wH = max(2.5, rad * 0.09)
  let wM = max(2.0, rad * 0.065)
  thickLine(cx - sin(hh) * rad * 0.12, cy + cos(hh) * rad * 0.12, cx + sin(hh) * rad * 0.5, cy - cos(hh) * rad * 0.5, wH, ink)
  thickLine(cx - sin(mm) * rad * 0.12, cy + cos(mm) * rad * 0.12, cx + sin(mm) * rad * 0.74, cy - cos(mm) * rad * 0.74, wM, ink)
  disc(cx, cy, wH * 0.9, ink)
  if s >= 0:
    let ss = float(s) * PI / 30
    let red = if gloss or not glassLook(): color(218, 8, 18) else: accentColor()
    thickLine(cx - sin(ss) * rad * 0.18, cy + cos(ss) * rad * 0.18, cx + sin(ss) * rad * 0.84,
              cy - cos(ss) * rad * 0.84, max(1.2, rad * 0.025), red)
    disc(cx, cy, max(2.0, rad * 0.06), red)
  if gloss:
    # (the shine across its top half)
    pushClip(rect(int(cx - rad), int(cy - rad), int(2 * rad) + 1, int(rad * 0.92)))
    disc(cx, cy, rad - 0.5, withAlpha(white, if night: 30 else: 80))
    popClip()
  if label.len > 0:
    let tw = textWidth(label, small)
    let ly = cell.y + d + dp(4)
    if gloss and not onDarkWindow(): text(int(cx) - tw div 2, ly + 1, label, withAlpha(white, 204), small)
    text(int(cx) - tw div 2, ly, label, th.text, small)
  if accessOn:
    accessNode(arImage, if label.len > 0: label else: "Clock",
               value = $(h mod 24) & ":" & (if m < 10: "0" else: "") & $m, id = 0, r = cell)
  ui.lastId = 0
  ui.lastRect = cell

proc appIcon*(glyph, label: string; tint = Color(); badge = ""; picture: Bitmap = nil;
              enabled = true): bool =
  ## An app to open, as a phone's home screen shows one: a rounded square with `glyph` (an
  ## icon font's) or `picture` on it, `label` under it, a red `badge` at its corner ("3"; ""
  ## none). True when clicked (Space and Enter with the focus). Put them in a `row` for a grid.
  ## Gloss: iOS 6's -- `tint` (else the highlight) lit as glass, a shine across its top half, a
  ## shadow under it; Glass: flat `tint`, white glyph; Matte: nearly square; Classic: Program
  ## Manager's -- the glyph alone, its label chosen while it has the focus.
  let gloss = glossLook()
  let d = if fingers(): dp(57) else: dp(44)
  let lst = style(bold = gloss, size = if fingers(): 0.73 else: 0.85)
  let w = d + dp(20)
  let r = place(w, d + dp(6) + lineHeight(lst) + dp(4))
  let id = idOf("appicon:" & label & ":" & glyph)
  var hit = interact(id, r, enabled = enabled)
  if enabled:
    spaceKey(id, hit)
    if hit.focused:
      ui.takesEnter = true
      if keyHit(KeyEnter): hit.clicked = true
  let ic = rect(r.x + (w - d) div 2, r.y + dp(3), d, d)
  let base = if tint.a != 0: tint else: accentColor()
  let classic = not glassLook()
  let rad = if gloss: float(d) * 0.18 elif matteLook(): float(dp(4)) else: float(d) * 0.22
  if not classic:
    if gloss:
      roundRect(rect(ic.x, ic.y + 2, ic.w, ic.h), rad, withAlpha(black, 70))
      roundRect(rect(ic.x, ic.y + 1, ic.w, ic.h), rad, withAlpha(black, 60))
    if picture != nil and picture.w > 0:
      masked(ic, rad):
        drawBitmap(ic, picture)
    elif gloss: roundRectShaded(ic, rad, mixColor(base, white, 0.25), mixColor(base, black, 0.2))
    else: roundRect(ic, rad, base)
    if glyph.len > 0 and (picture == nil or picture.w == 0):
      let gs = style(size = float(d) / 22)
      let gw = textWidth(glyph, gs)
      let gy = ic.y + (d - lineHeight(gs)) div 2
      if gloss: text(ic.x + (d - gw) div 2, gy - 1, glyph, withAlpha(black, 90), gs)
      text(ic.x + (d - gw) div 2, gy, glyph, white, gs)
    if gloss:
      # (the shine: the top half, curved at its foot)
      pushClip(rect(ic.x, ic.y, ic.w, ic.h * 47 div 100))
      roundRect(ic, rad, withAlpha(white, 64))
      popClip()
      roundFrame(ic, rad, 1, withAlpha(black, 46))
    if hit.down: roundRect(ic, rad, withAlpha(black, 90))
  else:
    let gs = style(size = float(d) / 18)
    let gw = textWidth(glyph, gs)
    text(ic.x + (d - gw) div 2, ic.y + (d - lineHeight(gs)) div 2, glyph,
         if tint.a != 0: tint else: th.text, gs)
  if badge.len > 0:
    let bst = style(bold = true, size = 0.8)
    let bh = lineHeight(bst) + dp(4)
    let bw2 = max(bh, textWidth(badge, bst) + dp(10))
    let br = rect(ic.x + ic.w - bw2 + dp(8), ic.y - dp(6), bw2, bh)
    if gloss:
      roundRect(rect(br.x, br.y + 1, br.w, br.h), float(bh) / 2, withAlpha(black, 80))
      roundRect(br, float(bh) / 2, white)
      tintedFace(inset(br, max(1, dp(2))), color(200, 0, 0), radius = float(bh) / 2 - 2)
    else: roundRect(br, float(bh) / 2, badColor())
    text(br.x + (br.w - textWidth(badge, bst)) div 2, br.y + (bh - lineHeight(bst)) div 2, badge, white, bst)
  let l = ellipsize(tr(label), w, lst)
  let lw = textWidth(l, lst)
  let lr = rect(r.x + (w - lw) div 2, ic.y + d + dp(4), lw, lineHeight(lst))
  if classic and hit.focused:
    fill(inset(lr, -2), th.select)
    text(lr.x, lr.y, l, th.selectText, lst)
  else:
    if gloss: text(lr.x, lr.y + (if onDarkWindow(): -1 else: 1), l,
                   if onDarkWindow(): withAlpha(black, 160) else: withAlpha(white, 204), lst)
    text(lr.x, lr.y, l, if enabled: th.text else: th.gray, lst)
    if hit.focused: focusDots(inset(ic, -2))
  if accessOn: accessNode(arButton, label, value = badge, id = id, r = r, states = offIf(enabled))
  ui.lastId = id
  ui.lastRect = r
  hit.clicked

type Texture* = enum
  ## A surface `texture` draws.
  txLinen,      ## linen, gray: the back of a phone's panels, a notification list's
  ## (the others' colors: `texture`'s `tint` changes them)
  txPaper,      ## lined paper, pale yellow, a red line down its margin: a notepad's
  txFelt,       ## felt, green: a game table's
  txLeather,    ## leather, brown, stitched round its edge: a diary's cover
  txPinstripe   ## thin upright stripes: Gloss's window (`glossPinstripes`)

var textureTiles: Table[(Texture, uint32, int), Bitmap]

proc textureTile(kind: Texture; c: Color; scale: int): Bitmap =
  ## (a square of `kind`'s grain in `c`, made once: textures repeat it)
  let key = (kind, (uint32(c.r) shl 16) or (uint32(c.g) shl 8) or uint32(c.b), scale)
  textureTiles.withValue(key, t):
    return t[]
  let n = 128 * scale
  result = newBitmap(n, n, 0xFF000000'u32)
  var seed = 0x9E3779B9'u32 xor uint32(ord(kind) * 7919)
  proc rnd(): float =
    seed = seed xor (seed shl 13)
    seed = seed xor (seed shr 17)
    seed = seed xor (seed shl 5)
    float(seed and 0xFFFF) / 65535.0
  var rows = newSeq[float](n)
  var cols = newSeq[float](n)
  for i in 0 ..< n:
    rows[i] = rnd() - 0.5
    cols[i] = rnd() - 0.5
  # (felt's and leather's soft blotches: noise on a coarse grid, smoothed)
  let g = 16
  var blot = newSeq[float](g * g)
  for i in 0 ..< g * g: blot[i] = rnd() - 0.5
  proc blotAt(x, y: int): float =
    let fx = float(x) / float(n) * float(g)
    let fy = float(y) / float(n) * float(g)
    let x0 = int(fx) mod g
    let y0 = int(fy) mod g
    let x1 = (x0 + 1) mod g
    let y1 = (y0 + 1) mod g
    let tx = fx - floor(fx)
    let ty = fy - floor(fy)
    let a = blot[y0 * g + x0] * (1 - tx) + blot[y0 * g + x1] * tx
    let b = blot[y1 * g + x0] * (1 - tx) + blot[y1 * g + x1] * tx
    a * (1 - ty) + b * ty
  for y in 0 ..< n:
    for x in 0 ..< n:
      let p = rnd() - 0.5
      let k = case kind
              of txLinen: rows[y] * 0.10 + cols[x] * 0.08 + p * 0.07 +
                          (if (x + y div 2) mod 3 == 0: 0.025 else: 0.0)
              of txPaper: p * 0.025 + cols[x] * 0.01
              of txFelt: p * 0.11 + blotAt(x, y) * 0.07
              of txLeather: p * 0.06 + blotAt(x, y) * 0.10 +
                            (if ((x * 7 + y * 3) mod 11) < 2: -0.04 else: 0.0)
              of txPinstripe: 0.0
      template ch(v: uint8): uint32 = uint32(clamp(int(float(v) * (1 + k)), 0, 255))
      result.px[y * n + x] = 0xFF000000'u32 or (ch(c.r) shl 16) or (ch(c.g) shl 8) or ch(c.b)
  textureTiles[key] = result

proc texture*(r: Rect; kind: Texture; tint = Color(); lineH = 0) =
  ## Fills `r` with a surface drawn in code, in every look: linen, lined paper, felt, stitched
  ## leather, pinstripes -- a page's background, a notes page, a card table, a cover. `tint`:
  ## its color (alpha 0: its own -- linen gray, paper pale yellow, felt green, leather brown,
  ## pinstripes the window's). `lineH`: paper's line spacing (0: a line of text's, `FontH`
  ## and a little).
  if r.w <= 0 or r.h <= 0: return
  let own = case kind
            of txLinen: color(62, 64, 70)
            of txPaper: color(252, 243, 192)
            of txFelt: color(36, 106, 58)
            of txLeather: color(104, 64, 38)
            of txPinstripe: th.window
  let c = if tint.a != 0: tint else: own
  pushClip(r)
  if kind == txPinstripe:
    fill(r, c)
    let lite = mixColor(c, white, 0.12)
    let period = max(5, dp(7))
    let sw = max(2, period * 3 div 7)
    var x = r.x
    while x < r.x + r.w:
      fill(rect(x, r.y, sw, r.h), lite)
      x += period
  else:
    let t = textureTile(kind, c, max(1, pxScale))
    let side = 128
    var y = r.y
    while y < r.y + r.h:
      var x = r.x
      while x < r.x + r.w:
        drawBitmap(rect(x, y, side, side), t)
        x += side
      y += side
    if kind == txPaper:
      let lh = if lineH > 0: lineH else: FontH + dp(8)
      var ly = r.y + lh + dp(10)
      let line = mixColor(c, color(120, 132, 170), 0.35)
      while ly < r.y + r.h:
        hline(r.x, ly, r.w, line)
        ly += lh
      let mx = r.x + dp(32)
      vline(mx, r.y, r.h, color(214, 120, 104))
      vline(mx + max(2, dp(3)), r.y, r.h, color(214, 120, 104))
    elif kind == txLeather and r.w > dp(40) and r.h > dp(40):
      # (stitches round it, a little in: light, a dark line beside each)
      let e = dp(9)
      let dash = dp(6)
      let gap = dp(4)
      let st = mixColor(c, color(255, 236, 200), 0.55)
      var x = r.x + e
      while x + dash <= r.x + r.w - e:
        fill(rect(x, r.y + e, dash, max(1, dp(1))), st)
        fill(rect(x, r.y + e + max(1, dp(1)), dash, 1), withAlpha(black, 90))
        fill(rect(x, r.y + r.h - e, dash, max(1, dp(1))), st)
        fill(rect(x, r.y + r.h - e + max(1, dp(1)), dash, 1), withAlpha(black, 90))
        x += dash + gap
      var y2 = r.y + e
      while y2 + dash <= r.y + r.h - e:
        fill(rect(r.x + e, y2, max(1, dp(1)), dash), st)
        fill(rect(r.x + e + max(1, dp(1)), y2, 1, dash), withAlpha(black, 90))
        fill(rect(r.x + r.w - e, y2, max(1, dp(1)), dash), st)
        fill(rect(r.x + r.w - e + max(1, dp(1)), y2, 1, dash), withAlpha(black, 90))
        y2 += dash + gap
  popClip()

type SlideState = object
  ## (a `slideToConfirm`'s knob: where it is, where the drag took it from)
  x: float               # its offset along the track (pixels)
  grab: int              # the pointer's x where the drag began (-1: not dragged)
  t: int                 # when it last sprang back a step

var slides: Table[Id, SlideState]

proc slideArrow(k: Rect; c: Color) =
  ## (the arrow on a `slideToConfirm`'s knob, pointing the way it goes)
  let s = float(min(k.w, k.h)) * 0.42
  let cx = float(k.x) + float(k.w) / 2
  let cy = float(k.y) + float(k.h) / 2
  let w = max(2.0, s / 6)
  thickLine(cx - s / 2, cy, cx + s / 2, cy, w, c)
  thickLine(cx + s / 2, cy, cx + s / 8, cy - s * 0.38, w, c)
  thickLine(cx + s / 2, cy, cx + s / 8, cy + s * 0.38, w, c)

proc slideToConfirm*(label: string; key = ""; enabled = true): bool =
  ## A track with a knob to slide to its end before something happens that should not happen by
  ## a stray tap -- "slide to answer", "slide to power off", "slide to pay": dragged all the way
  ## (or nearly), true once; let go before, it slides back. With the focus, Enter or Space
  ## confirms (a keyboard's press is meant); a screen reader's press too. Gloss: iOS 6's -- a
  ## dark track sunk into the window, a light gray knob with an arrow on it, the words lit by
  ## a shine that crosses them; Glass and Matte: a capsule, the knob in the highlight; Classic:
  ## a groove with a 3.1 button in it.
  let h = if fingers(): dp(56) else: max(dp(36), FontH + dp(16))
  let r = place(0, h, fill = true)
  let id = idOf("slideconfirm:" & (if key.len > 0: key else: label))
  var hit = interact(id, r, enabled = enabled)
  var st = slides.getOrDefault(id, SlideState(grab: -1))
  let gloss = glossLook()
  let pad = if gloss: dp(4) else: dp(3)
  let kw = if gloss: h * 3 div 2 else: h - 2 * pad
  let kh = h - 2 * pad
  let travel = float(max(1, r.w - 2 * pad - kw))
  let knob0 = rect(r.x + pad + int(st.x), r.y + pad, kw, kh)
  if enabled:
    if hit.focused:
      ui.takesEnter = true
      if keyHit(KeyEnter) or keyHit(KeySpace): result = true
    if accessOn and accessPress == id:
      accessPress = 0
      result = true
    if ui.pressed and ui.active == id and knob0.contains(point(ui.mx, ui.my)):
      st.grab = ui.mx - int(st.x)
    if st.grab >= 0:
      if ui.mouseDown and ui.active == id:
        ui.dragsActive = true
        st.x = clamp(float(ui.mx - st.grab), 0, travel)
        wakeIn(16)
      else:
        # let go: at the end -- or nearly -- it is done; else it slides back
        if st.x >= travel * 0.92:
          result = true
          if touchFeel != nil: touchFeel(5)
        st.grab = -1
        st.t = ui.now
  if st.grab < 0 and st.x > 0:
    let dt = float(max(1, min(50, ui.now - st.t)))
    st.t = ui.now
    st.x = if result: 0.0 else: st.x * exp(-dt / 60)
    if st.x < 0.5: st.x = 0
    if st.x > 0: wakeIn(16)
  if result: st.x = 0
  slides[id] = st
  let knob = rect(r.x + pad + int(st.x), r.y + pad, kw, kh)
  let shownFrac = st.x / travel
  let tst = style(size = if gloss and fingers(): 1.33 else: 1.1)
  let lw = textWidth(label, tst)
  let tx = knob.x + kw + (r.x + r.w - knob.x - kw - lw) div 2
  let ty = r.y + (h - lineHeight(tst)) div 2
  let fade = clamp(1 - shownFrac * 2.2, 0, 1)
  if gloss:
    let rad = float(dp(10))
    roundRect(rect(r.x, r.y + 1, r.w, r.h), rad, withAlpha(white, if onDarkWindow(): 30 else: 90))
    roundRect(r, rad, withAlpha(black, 178))
    glossTopShade(r, rad, [150, 70, 25])
    if fade > 0:
      pushClip(rect(knob.x + kw, r.y, r.x + r.w - knob.x - kw, r.h))
      text(tx, ty, label, withAlpha(color(140, 140, 140), int(255 * fade)), tst)
      # (the shine crossing the words: brighter in a band that moves along them)
      let period = 2200
      let p = float(ui.now mod period) / float(period)
      let bx = tx - dp(40) + int(p * float(lw + dp(80)))
      pushClip(rect(bx - dp(24), r.y, dp(48), r.h))
      text(tx, ty, label, withAlpha(white, int(235 * fade)), tst)
      popClip()
      popClip()
      wakeIn(33)
    let kr = float(dp(8))
    roundRectShaded(rect(knob.x, knob.y + 1, knob.w, knob.h), kr, withAlpha(black, 120), withAlpha(black, 120))
    roundRectShaded(knob, kr, color(252, 252, 252), color(196, 196, 198))
    pushClip(rect(knob.x, knob.y, knob.w, knob.h div 2))
    roundRect(inset(knob, 1), kr - 1, withAlpha(white, 120))
    popClip()
    roundFrame(knob, kr, 1, color(120, 120, 124))
    slideArrow(knob, if enabled: color(150, 150, 154) else: color(200, 200, 200))
  elif glassLook():
    let rad = if matteLook(): float(dp(3)) else: float(h) / 2
    roundRect(r, rad, mixColor(th.window, th.text, if onDarkWindow(): 0.16 else: 0.08))
    if fade > 0:
      text(tx, ty, label, withAlpha(th.gray, int(255 * fade)), tst)
    let kc = if enabled: accentColor() else: th.gray
    roundRect(knob, if matteLook(): float(dp(2)) else: float(kh) / 2, kc)
    slideArrow(knob, accentInk())
  else:
    fill(r, th.shadow)
    box(r, th.frame)
    if fade > 0: text(tx, ty, label, if fade > 0.5: th.text else: th.gray, tst)
    buttonFace(knob, st.grab >= 0)
    slideArrow(knob, th.text)
  if hit.focused: focusDots(inset(r, 2))
  if accessOn: accessNode(arButton, label, id = id, r = r, states = offIf(enabled))
  ui.lastId = id
  ui.lastRect = r

type BigTone* = enum
  ## A `bigButton`'s color.
  btGray,      ## the usual
  btGreen,     ## going on: Start, Call, Accept
  btRed,       ## stopping, ending, taking away: Stop, End, Delete
  btBlue       ## the highlight: Save, Done, Buy

proc bigButton*(label: string; tone = btGray; enabled = true; key = ""): bool =
  ## A button as wide as the row and tall for a thumb, for the one thing a screen is for --
  ## Start and Stop, Call, End, Pay. True when clicked (Space and Enter with the focus). Gloss:
  ## iOS 6's -- its color lit as glass in a dark frame, the label large and white; Glass: a
  ## flat capsule-cornered slab; Matte: flat, square; Classic: a 3.1 push button, bold.
  let h = if fingers(): dp(52) else: max(dp(40), FontH + dp(18))
  let r = place(0, h, fill = true)
  let id = idOf("bigbutton:" & (if key.len > 0: key else: label))
  var hit = interact(id, r, enabled = enabled)
  if enabled:
    spaceKey(id, hit)
    if hit.focused:
      ui.takesEnter = true
      if keyHit(KeyEnter): hit.clicked = true
  let base = if modernGlass():
               (case tone
                of btGray: color(139, 139, 139)
                of btGreen: color(36, 178, 84)
                of btRed: color(232, 58, 58)
                of btBlue: accentColor())
             else:
               (case tone
                of btGray: color(139, 139, 139)
                of btGreen: color(7, 177, 22)
                of btRed: color(178, 12, 14)
                of btBlue: glossTint(color(37, 98, 217)))
  var c = if enabled: base else: mixColor(base, th.window, 0.55)
  if hit.down: c = mixColor(c, black, 0.25)
  let gloss = glossLook()
  let lst = style(bold = true, size = if gloss and fingers(): 1.4 else: 1.15)
  var ink = white
  if gloss:
    # (a dark frame, the face inside it lit: its top half lighter, a hard edge at the middle)
    let rad = float(dp(12))
    roundRect(rect(r.x, r.y + 1, r.w, r.h), rad, withAlpha(white, if onDarkWindow(): 26 else: 120))
    roundRectShaded(r, rad, color(70, 70, 72), color(20, 20, 22))
    let f = inset(r, max(3, dp(4)))
    let fr = rad - float(max(3, dp(4)))
    glossTwoTone(f, fr, mixColor(c, white, 0.4), mixColor(c, white, 0.1), c,
                 mixColor(c, if tone == btGray: white else: black, 0.2))
    roundFrame(f, fr, 1, withAlpha(black, 110))
  elif modernGlass():
    # (a capsule lit from above, glowing in its color on the window; the gray one a pill of
    # glass, its label in the text's color)
    let pr = float(r.h) / 2
    if tone == btGray:
      if glassFx(): glassSurface(r, pr, if hit.down: mixColor(th.field, th.text, 0.1) else: th.field, lift = 3)
      else: glassPlate(r, pr, if hit.down: mixColor(th.field, th.text, 0.1) else: th.field)
      ink = if enabled: th.text else: th.gray
    else: glassBlue(r, pr, hit.down, c = c, glow = enabled)
  elif glassLook():
    roundRect(r, if matteLook(): float(dp(2)) else: float(dp(12)), c)
    if tone == btGray: ink = th.text
  else:
    buttonFace(r, hit.down)
    ink = if enabled: (case tone
                       of btGreen: color(0, 128, 0)
                       of btRed: color(170, 0, 0)
                       of btBlue: th.select
                       of btGray: th.text)
          else: th.gray
  let l = ellipsize(label, r.w - dp(16), lst)
  let lw = textWidth(l, lst)
  let ly = r.y + (h - lineHeight(lst)) div 2 + (if hit.down and not glassLook(): 1 else: 0)
  if gloss: text(r.x + (r.w - lw) div 2, ly - 1, l, withAlpha(black, 110), lst)
  text(r.x + (r.w - lw) div 2, ly, l, ink, lst)
  if hit.focused: focusDots(inset(r, 3))
  if accessOn: accessNode(arButton, label, id = id, r = r, states = offIf(enabled))
  ui.lastId = id
  ui.lastRect = r
  hit.clicked

# ---- a slider standing up: an equalizer's band, a mixer's channel -------------------------------------

proc vslider*(v: var int; lo, hi: int; h = 0; label = ""; enabled = true): bool {.discardable.} =
  ## A slider standing up, bound to `v` in `lo..hi` -- `hi` at its top: an equalizer's band, a
  ## mixer's channel; `label` under it (a band's "125"). Drag its knob, or click along it; Up,
  ## Down, Page Up, Page Down, Home, End with the focus; the wheel while it has it. `h`: its
  ## height (0: 8 lines). Gloss: iOS 6's -- a track cut in, blue from its foot up to a round
  ## knob, gray to white above it; Glass, Matte and Classic their sliders' faces, standing.
  ## True when `v` changed.
  let kd = if fingers(): dp(23) else: dp(17)
  let lst = style(size = 0.85)
  let lh = if label.len > 0: lineHeight(lst) + dp(4) else: 0
  let w = max(kd + dp(6), (if label.len > 0: textWidth(label, lst) + dp(4) else: 0))
  let r = place(w, (if h > 0: h else: FontH * 8) + lh)
  let id = idOf(v, "vslider:" & label)
  let track = rect(r.x, r.y + kd div 2, r.w, max(1, r.h - lh - kd))
  let hit = interact(id, rect(r.x, r.y, r.w, r.h - lh), enabled = enabled)
  let span = max(1, hi - lo)
  var nv = v
  if enabled:
    if ui.active == id and ui.mouseDown:
      ui.dragsActive = true
      nv = lo + ((track.y + track.h - ui.my) * span + track.h div 2) div max(1, track.h)
    if hit.focused and canInput() and mouseIn(r) and ui.wheel != 0 and not ui.wheelUsed:
      ui.wheelUsed = true
      nv -= ui.wheel * max(1, span div 20)
    if hit.focused and canInput():
      let big = max(1, span div 10)
      case ui.key
      of KeyUp, KeyRight: (inc nv; ui.keyUsed = true)
      of KeyDown, KeyLeft: (dec nv; ui.keyUsed = true)
      of KeyPageUp: (nv += big; ui.keyUsed = true)
      of KeyPageDown: (nv -= big; ui.keyUsed = true)
      of KeyHome: (nv = hi; ui.keyUsed = true)
      of KeyEnd: (nv = lo; ui.keyUsed = true)
      else: discard
  if accessOn and enabled and accessValueFor(id): nv = int(round(accessSet.num))
  nv = clamp(nv, lo, hi)
  if nv != v:
    v = nv
    result = true
  let cy = track.y + track.h - (clamp(v, lo, hi) - lo) * track.h div span
  let cx = r.x + r.w div 2
  if glossLook():
    let dark = onDarkWindow()
    let tk = if fingers(): dp(9) else: dp(7)
    let tr = rect(cx - tk div 2, track.y - tk div 2, tk, track.h + tk)
    let trad = float(tk) / 2
    let ti = inset(tr, 1)
    pushClip(rect(tr.x, cy, tr.w, max(0, tr.y + tr.h - cy)))
    if enabled:
      roundRectShaded(tr, trad, glossTint(color(30, 56, 107)), glossTint(color(97, 128, 183)))
      roundRectShaded(ti, trad - 1, glossTint(color(46, 89, 168)), glossTint(color(109, 159, 232)))
    else:
      roundRectShaded(tr, trad, color(120, 120, 120), color(160, 160, 160))
      roundRectShaded(ti, trad - 1, color(150, 150, 150), color(200, 200, 200))
    popClip()
    pushClip(rect(tr.x, tr.y, tr.w, max(0, cy - tr.y)))
    if dark:
      roundRect(tr, trad, black)
      roundRectShaded(ti, trad - 1, color(30, 30, 34), color(70, 72, 78))
    else:
      roundRectShaded(tr, trad, color(130, 130, 130), color(172, 172, 172))
      roundRectShaded(ti, trad - 1, color(184, 184, 184), white)
    popClip()
    let kcx = float(cx)
    let kcy = float(cy)
    disc(kcx, kcy + 1.5, float(kd) / 2, withAlpha(black, 77))
    disc(kcx, kcy, float(kd) / 2, if dark: black else: color(60, 60, 60))
    if hit.down: discShaded(kcx, kcy, float(kd) / 2 - 1, color(140, 140, 140), color(228, 228, 228))
    else: discShaded(kcx, kcy, float(kd) / 2 - 1, color(166, 166, 166), color(252, 252, 252))
    pushClip(rect(int(kcx) - kd, int(kcy) - kd, 2 * kd, kd div 2))
    ring(kcx, kcy, float(kd) / 2 - 1, 1, withAlpha(white, 178))
    popClip()
  elif matteLook():
    let tk = max(2, dp(3))
    let tx = cx - tk div 2
    fill(rect(tx, track.y, tk, track.h), mixColor(th.window, th.text, if onDarkWindow(): 0.3 else: 0.2))
    if enabled: fill(rect(tx, cy, tk, track.y + track.h - cy), accentColor())
    let kcy = float(cy)
    disc(float(cx), kcy, float(kd) / 2, mixColor(th.face, th.text, 0.3))
    disc(float(cx), kcy, float(kd) / 2 - float(max(2, dp(2))), th.light)
    disc(float(cx), kcy, float(kd) / 5, if hit.down or hit.focused: accentColor() else: mixColor(th.face, th.text, 0.2))
  elif glassLook():
    let tk = dp(4)
    let tr = rect(cx - tk div 2, track.y, tk, track.h)
    roundRect(tr, float(tk) / 2, mixColor(th.window, th.text, 0.12))
    if enabled: roundRect(rect(tr.x, cy, tk, tr.y + tr.h - cy), float(tk) / 2, accentColor())
    let knob = rect(cx - kd div 2, cy - kd div 2, kd, kd)
    disc(float(cx), float(cy) + 1, float(kd) / 2, withAlpha(black, 40))
    disc(float(cx), float(cy), float(kd) / 2, if hit.down: th.face else: th.field)
    ring(float(cx), float(cy), float(kd) / 2 - 0.5, 1, mixColor(th.window, th.text, 0.18))
    discard knob
  else:
    let chan = rect(cx - dp(2), track.y, dp(4), track.h)
    sunken(chan)
    let thumb = rect(r.x + (r.w - min(r.w, dp(22))) div 2, cy - dp(5), min(r.w, dp(22)), dp(11))
    buttonFace(thumb, hit.down, rounded = false, bevel = 1, hot = enabled and hovered(thumb))
  if label.len > 0:
    let lw = textWidth(label, lst)
    let ink = if glossLook() and not onDarkWindow(): glossTint(color(76, 86, 108)) else: th.gray
    text(r.x + (r.w - lw) div 2, r.y + r.h - lineHeight(lst), label, ink, lst)
  if hit.focused: focusDots(rect(r.x, r.y, r.w, r.h - lh))
  if accessOn:
    let k = accessNode(arSlider, label, value = $v, id = id, r = r, states = offIf(enabled))
    accessRange(k, lo.float, hi.float, v.float, 1.0)
  ui.lastId = id
  ui.lastRect = r

# ---- stars: a rating ------------------------------------------------------------------------------

proc starPoints(cx, cy, ro: float): seq[(float, float)] =
  ## (a five-pointed star round (`cx`, `cy`), its points `ro` out)
  let ri = ro * 0.42
  for k in 0 ..< 10:
    let a = -PI / 2 + float(k) * PI / 5
    let rr = if k mod 2 == 0: ro else: ri
    result.add (cx + cos(a) * rr, cy + sin(a) * rr)

var starsPress: tuple[id: Id; x, was: int; dragged: bool]

proc ratingStars*(v: var int; stars = 5; size = 0; enabled = true): bool {.discardable.} =
  ## A rating of 0 to `stars`: a tap or a click on a star gives that many (on the one it has
  ## again: none), a drag along them follows the finger; Left and Right, 0 to 9, Home and End
  ## with the focus. `size`: a star's height (0: a line's and a half; a finger's on a phone).
  ## Gloss: iOS 6's -- stars of the bars' slate blue, the empty ones dots; Glass and Matte the
  ## highlight's; Classic the text's. True when `v` changed.
  let d = if size > 0: size elif fingers(): dp(30) else: FontH * 3 div 2
  let r = place(stars * d, d)
  let id = idOf(v, "stars")
  var hit = interact(id, r, enabled = enabled)
  var nv = v
  if enabled:
    let k = clamp((ui.mx - r.x) div max(1, d) + 1, 1, stars)
    if ui.active == id and ui.mouseDown:
      if starsPress.id != id:
        starsPress = (id, ui.mx, v, false)
      elif abs(ui.mx - starsPress.x) > dp(4):
        starsPress.dragged = true
      if starsPress.dragged: nv = k
    if hit.clicked:
      # (a tap: that many -- on the one it has, none; a drag ended: where it ended)
      nv = if not starsPress.dragged and k == starsPress.was: 0 else: k
    if not ui.mouseDown: starsPress.id = Id(0)
    if hit.focused and canInput():
      case ui.key
      of KeyLeft, KeyDown: (dec nv; ui.keyUsed = true)
      of KeyRight, KeyUp: (inc nv; ui.keyUsed = true)
      of KeyHome: (nv = 0; ui.keyUsed = true)
      of KeyEnd: (nv = stars; ui.keyUsed = true)
      else: discard
      for c in ui.typed:
        if c in {'0' .. '9'}: nv = ord(c) - ord('0')
  if accessOn and enabled and accessValueFor(id): nv = int(round(accessSet.num))
  nv = clamp(nv, 0, stars)
  if nv != v:
    v = nv
    result = true
  let full = if glossLook(): (if onDarkWindow(): color(200, 206, 220) else: glossTint(color(76, 86, 108)))
             elif glassLook(): accentColor()
             else: th.text
  let empty = if glossLook(): mixColor(full, th.window, 0.55) else: mixColor(th.window, th.text, 0.3)
  beginKeepSides(r)
  for i in 0 ..< stars:
    let cx = float(r.x + i * d) + float(d) / 2
    let cy = float(r.y) + float(d) / 2
    let on = i < v
    let c = if enabled: (if on: full else: empty) else: mixColor(th.window, th.gray, 0.5)
    if on or not glossLook():
      if glossLook() and not onDarkWindow(): polygon(starPoints(cx, cy + 1, float(d) * 0.42), withAlpha(white, 160))
      polygon(starPoints(cx, cy, float(d) * 0.42), c)
      if not on and not glossLook():
        polygon(starPoints(cx, cy, float(d) * 0.42 - max(1.2, float(dp(1)) + 0.2)), th.window)
    else:
      disc(cx, cy, max(1.5, float(d) / 14), c)        # (iOS 6's: a dot where a star is not)
  endKeepSides()
  if hit.focused: focusDots(inset(r, 1))
  if accessOn:
    let k = accessNode(arSlider, "Rating", value = $v & " of " & $stars, id = id, r = r,
                       states = offIf(enabled))
    accessRange(k, 0, stars.float, v.float, 1.0)
  ui.lastId = id
  ui.lastRect = r

# ---- a list being edited: rows deleted, put in order ----------------------------------------------

type
  RowEditKind* = enum
    ## What was done to an `editRow`.
    reNone,      ## nothing
    reDelete,    ## delete it: its red minus, then Delete (the Delete key with the focus)
    reMove       ## move it from `index` to `to`: its grip dragged (Alt+Up, Alt+Down)
  RowEdit* = object
    ## What `editRow` says was done.
    kind*: RowEditKind
    index*, to*: int

var
  rowDrag: tuple[gid: Id; on: bool; src, to, grabY, h, frame: int; r: Rect;
                 title, detail, subtitle, glyph: string; tint: Color; picture: Bitmap;
                 deletable, movable: bool]
  rowDeleting: tuple[gid: Id; index: int; frame: int]

proc gripLines(r: Rect; c: Color) =
  ## (three lines: the handle a row is moved by)
  let w = min(r.w - dp(4), dp(18))
  let x = r.x + (r.w - w) div 2
  let t = max(1, dp(2))
  let gap = max(t + 2, dp(5))
  let y0 = r.y + r.h div 2 - gap - t div 2
  for k in 0 .. 2: fill(rect(x, y0 + k * gap, w, t), c)

proc editRowParts(r: Rect; deletable, movable, confirming: bool):
    tuple[minus, grip, del: Rect; x, endX: int] =
  ## (where a row's parts are: its minus, its grip, its Delete, its text between)
  let pad = if fingers(): dp(12) else: dp(10)
  let d = if fingers(): dp(23) else: max(dp(18), FontH + dp(2))
  result.x = r.x + pad
  result.endX = r.x + r.w - pad
  if deletable:
    result.minus = rect(r.x + pad, r.y + (r.h - d) div 2, d, d)
    result.x = result.minus.x + d + dp(10)
  if movable:
    let gw = if fingers(): dp(36) else: dp(28)
    result.grip = rect(r.x + r.w - gw, r.y, gw, r.h)
    result.endX = result.grip.x - dp(4)
  if confirming:
    let st = style(bold = true)
    let bw = textWidth(tr("Delete"), st) + dp(22)
    let bh = min(r.h - dp(12), max(FontH + dp(10), dp(30)))
    result.del = rect(result.endX - bw, r.y + (r.h - bh) div 2, bw, bh)
    result.endX = result.del.x - dp(8)

proc editRowFace(r: Rect; title, detail, subtitle, glyph: string; tint: Color; picture: Bitmap;
                 deletable, movable, confirming, delDown, minusDown: bool; ink, sub, link: Color) =
  ## (a row's face as it is edited: the minus, the icon, the text, the Delete, the grip)
  let p = editRowParts(r, deletable, movable, confirming)
  if deletable:
    roundFace(float(p.minus.x) + float(p.minus.w) / 2, float(p.minus.y) + float(p.minus.h) / 2,
              p.minus.w, rkRemove, minusDown, true, upright = confirming)
  var x = p.x
  if glyph.len > 0: rowGlyph(r, x, glyph, tint, false, ink)
  if picture != nil and picture.w > 0:
    let d = r.h - dp(10)
    let pr = rect(x, r.y + dp(5), d, d)
    masked(pr, float(if glassLook(): dp(5) else: 0)):
      drawBitmap(pr, picture)
    x += d + dp(10)
  var endX = p.endX
  if confirming:
    let st = style(bold = true)
    let dr = p.del
    if glossLook():
      glossBarButton(dr, delDown, destructive = true)
      let lw = labelWidth(tr("Delete"), st)
      let ly = dr.y + (dr.h - lineHeight(st)) div 2
      drawLabel(dr.x + (dr.w - lw) div 2, ly - 1, tr("Delete"), withAlpha(black, 102), st)
      drawLabel(dr.x + (dr.w - lw) div 2, ly, tr("Delete"), white, st)
    else:
      let red = color(200, 30, 40)
      if glassLook(): roundRect(dr, float(if matteLook(): dp(2) else: dp(8)), if delDown: mixColor(red, black, 0.2) else: red)
      else: buttonFace(dr, delDown, 1)
      let lw = labelWidth(tr("Delete"), st)
      drawLabel(dr.x + (dr.w - lw) div 2, dr.y + (dr.h - FontH) div 2, tr("Delete"),
                if glassLook(): white else: red, st)
  elif detail.len > 0:
    let dt = ellipsize(detail, max(dp(30), (endX - x) div 2))
    let dw = textWidth(dt)
    text(endX - dw, r.y + (r.h - FontH) div 2, dt, link)
    endX -= dw + dp(10)
  let bold = glossLook()
  if subtitle.len > 0:
    let y0 = r.y + (r.h - 2 * FontH - dp(2)) div 2
    text(x, y0, ellipsize(title, endX - x, style(bold = bold)), ink, bold)
    text(x, y0 + FontH + dp(2), ellipsize(subtitle, endX - x), sub)
  else:
    text(x, r.y + (r.h - FontH) div 2, ellipsize(title, endX - x, style(bold = bold)), ink, bold)
  if movable: gripLines(p.grip, if glossLook(): color(150, 150, 150) else: mixColor(th.field, th.fieldText, 0.4))

proc editRow*(title: string; index: int; detail = ""; subtitle = ""; glyph = ""; tint = Color();
              picture: Bitmap = nil; deletable = true; movable = true; key = ""): RowEdit =
  ## A row of a `tableGroup` while its list is edited, as a phone's: a red minus at its start
  ## -- tapped, it turns up and a Delete button comes at the row's end; tapped, the row is to be
  ## deleted --, a grip at its end to drag it up or down the list (the rows round it make way;
  ## let go, it is to be moved there). `index`: its place in the list, 0 at the top -- the rows
  ## in the order they are, one `editRow` each. It returns what was done (`RowEdit`): the app
  ## deletes or moves the row in its list. With the focus: Delete deletes, Alt+Up and Alt+Down
  ## move it. `deletable`, `movable`: its minus, its grip. Gloss: iOS 6's -- the shining red
  ## minus, the red Delete, the gray grip lines; the other looks their own.
  let two = subtitle.len > 0
  let slot = place(0, tableRowH(two), fill = true)
  let gid = if tableGroups.len > 0: tableGroups[^1].id else: Id(0)
  let count = if tableGroups.len > 0: max(tableGroups[^1].rowsBefore, index + 1) else: index + 1
  let id = Id(mixId(uint32(gid), fnv("editrow:" & (if key.len > 0: key else: title))))
  if rowDrag.on and rowDrag.frame < ui.frameNo - 1: rowDrag.on = false     # (the list went away)
  let dragging = rowDrag.on and rowDrag.gid == gid
  # (a drag going on: this row the one dragged, or one making way for it)
  if dragging and index == rowDrag.src:
    rowDrag.frame = ui.frameNo
    if tableGroups.len > 0: inc tableGroups[^1].rows
    if ui.mouseDown:
      let dy = ui.my - rowDrag.grabY
      rowDrag.to = clamp(rowDrag.src + int(round(dy.float / max(1, rowDrag.h).float)), 0, count - 1)
      rowDrag.r = slot
      ui.dragsActive = true
      ui.redraw = true
    else:
      rowDrag.on = false
      if rowDrag.to != rowDrag.src: result = RowEdit(kind: reMove, index: rowDrag.src, to: rowDrag.to)
      ui.redraw = true
    ui.lastId = id
    ui.lastRect = slot
    return
  var r = slot
  if dragging:
    let (a, b) = (rowDrag.src, rowDrag.to)
    if a < b and index > a and index <= b: r.y -= rowDrag.h
    elif b < a and index >= b and index < a: r.y += rowDrag.h
  if rowDeleting.frame < ui.frameNo - 1: rowDeleting.gid = Id(0)
  let confirming = rowDeleting.gid == gid and rowDeleting.index == index and not dragging
  if confirming: rowDeleting.frame = ui.frameNo
  let p = editRowParts(r, deletable, movable, confirming)
  var mh, dh, gh: Hit
  if deletable and not dragging:
    mh = interact(id + 1, inset(p.minus, -dp(8)), focusable = false)
    if mh.clicked:
      if confirming: rowDeleting.gid = Id(0)
      else: rowDeleting = (gid, index, ui.frameNo)
  if confirming:
    dh = interact(id + 2, p.del, focusable = false)
    if dh.clicked:
      rowDeleting.gid = Id(0)
      result = RowEdit(kind: reDelete, index: index, to: index)
  if movable and not dragging:
    gh = interact(id + 3, p.grip, focusable = false)
    if gh.down and ui.mouseDown and ui.active == id + 3:
      rowDrag = (gid, true, index, index, ui.my, slot.h, ui.frameNo, slot, title, detail, subtitle, glyph,
                 tint, picture, deletable, movable)
      rowDeleting.gid = Id(0)
      ui.redraw = true
  var hit = interact(id, r)
  if hit.clicked and confirming and not dh.clicked: rowDeleting.gid = Id(0)   # (a tap beside it: not deleted)
  if hit.focused and canInput():
    if keyHit(KeyDelete) and deletable: result = RowEdit(kind: reDelete, index: index, to: index)
    elif ui.key == KeyUp and AltPressed in ui.mods and movable and index > 0:
      ui.keyUsed = true
      result = RowEdit(kind: reMove, index: index, to: index - 1)
    elif ui.key == KeyDown and AltPressed in ui.mods and movable and index + 1 < count:
      ui.keyUsed = true
      result = RowEdit(kind: reMove, index: index, to: index + 1)
  let (_, _, ink, sub, link) = rowFrame(r, false)
  editRowFace(r, title, detail, subtitle, glyph, tint, picture, deletable, movable, confirming,
              dh.down, mh.down, ink, sub, link)
  if hit.focused: focusDots(inset(r, 2))
  if accessOn:
    accessNode(arListItem, title, value = detail, id = id, r = r,
               help = "Delete deletes it; Alt+Up and Alt+Down move it")
    if deletable: accessNode(arButton, "Delete " & title, id = id + 2, r = p.minus)
  ui.lastId = id
  ui.lastRect = r

proc floatingRow(gid: Id; g: Rect) =
  ## (the row being dragged, over the others of its group, under the finger)
  if not (rowDrag.on and rowDrag.gid == gid and rowDrag.frame == ui.frameNo): return
  var r = rowDrag.r
  r.y = clamp(r.y + ui.my - rowDrag.grabY, g.y, max(g.y, g.y + g.h - r.h))
  fill(rect(r.x + 1, r.y + r.h, r.w - 2, dp(3)), withAlpha(black, 40))
  fill(rect(r.x, r.y - 1, r.w, 1), withAlpha(black, 30))
  fill(r, if glossLook(): (if onDarkWindow(): th.field else: color(250, 250, 250)) else: th.field)
  hline(r.x, r.y, r.w, mixColor(th.field, th.fieldText, 0.14))
  hline(r.x, r.y + r.h - 1, r.w, mixColor(th.field, th.fieldText, 0.14))
  editRowFace(r, rowDrag.title, rowDrag.detail, rowDrag.subtitle, rowDrag.glyph, rowDrag.tint,
              rowDrag.picture, rowDrag.deletable, rowDrag.movable, false, false, false, th.fieldText,
              th.gray, if glossLook(): glossDetail() else: th.gray)

# ---- Cover Flow: covers in a row, the one in the middle facing you --------------------------------

type FlowState = object
  at: float          # (where it is: the cover in the middle, between two while it moves)
  grabbing: bool
  grabX: int
  grabAt: float
  t: int
  vel: float

var
  flows: Table[Id, FlowState]
  flipped: Table[pointer, (uint64, Bitmap)]     # (each cover upside down, for the floor)

proc flippedOf(b: Bitmap): Bitmap =
  ## (`b` upside down: made once, again when it changed)
  let k = cast[pointer](b)
  let have = flipped.getOrDefault(k)
  if have[1] != nil and have[0] == stampOf(b) and have[1].w == b.w and have[1].h == b.h: return have[1]
  if flipped.len > 64: flipped.clear()
  result = newBitmap(b.w, b.h)
  for y in 0 ..< b.h:
    copyMem(addr result.px[y * b.w], unsafeAddr b.px[(b.h - 1 - y) * b.w], b.w * 4)
  result.changed()
  flipped[k] = (stampOf(b), result)

proc coverFlow*(covers: openArray[Bitmap]; sel: var int; titles: openArray[string] = [];
                subtitles: openArray[string] = []; h = 0; key = ""): int =
  ## Covers in a row, the chosen one (`sel`) in the middle facing you, the others turned away to
  ## its sides and shining on the floor under them -- the music player's Cover Flow: drag or
  ## flick them along, tap one at a side to bring it to the middle, Left and Right, Home and End
  ## with the focus; the middle one's title and subtitle under it. `covers`: the pictures (nil:
  ## a plain square). It returns the cover tapped, or Enter pressed on, in the middle (-1 none).
  ## `h`: its height (0: as the room and the width allow).
  result = -1
  let n = covers.len
  let r = place(0, if h > 0: h else: max(dp(160), min(remainingH(), cellRoom() * 11 div 20)), fill = true)
  let id = idOf("coverflow:" & key)
  var hit = interact(id, r)
  var fs = flows.getOrDefault(id, FlowState(at: float(sel), t: ui.now))
  if n == 0:
    fill(r, black)
    flows[id] = fs
    return
  sel = clamp(sel, 0, n - 1)
  let tst = style(bold = true)
  let textH = 2 * FontH + dp(10)
  let side = max(dp(40), min((r.h - textH - dp(10)) * 100 div 135, r.w * 9 div 20))
  let step = max(dp(8), side * 2 div 7)          # (how far apart the turned ones are)
  let dt = float(clamp(ui.now - fs.t, 0, 100))
  fs.t = ui.now
  # the finger, the mouse: dragged along, flicked; a tap at a side, the cover there
  if hit.down and ui.mouseDown and ui.active == id:
    if not fs.grabbing:
      fs.grabbing = true
      fs.grabX = ui.mx
      fs.grabAt = fs.at
      fs.vel = 0
    else:
      let prev = fs.at
      fs.at = clamp(fs.grabAt - float(ui.mx - fs.grabX) / float(step), -0.4, float(n - 1) + 0.4)
      if dt > 0: fs.vel = fs.vel * 0.5 + 0.5 * (fs.at - prev) / dt
    ui.dragsActive = true
  elif fs.grabbing:
    fs.grabbing = false
    if abs(fs.at - fs.grabAt) > 0.15:
      sel = clamp(int(round(fs.at + fs.vel * 200)), 0, n - 1)
    elif hit.clicked:
      let off = ui.mx - (r.x + r.w div 2)
      if abs(off) <= side div 2: result = sel
      else:
        # (the cover there: the first beside it 0.62 of a side out, the next a step further each)
        let k = 1 + max(0, (abs(off) - side * 62 div 100 + step div 2) div step)
        sel = clamp(sel + (if off > 0: k else: -k), 0, n - 1)
    fs.vel = 0
  if hit.focused and canInput():
    ui.takesEnter = true
    if keyHit(KeyLeft): sel = max(0, sel - 1)
    elif keyHit(KeyRight): sel = min(n - 1, sel + 1)
    elif keyHit(KeyHome): sel = 0
    elif keyHit(KeyEnd): sel = n - 1
    elif keyHit(KeyEnter): result = sel
  # (it glides to the chosen one)
  if not fs.grabbing:
    let goal = float(sel)
    fs.at += (goal - fs.at) * (1 - exp(-dt / 70))
    if abs(goal - fs.at) < 0.002: fs.at = goal
    else: wakeInShown(r, 15)
  flows[id] = fs
  # drawing: black, the covers farthest first, the middle one last
  fill(r, black)
  pushClip(r)
  let cx = r.x + r.w div 2
  let top = r.y + dp(6)
  let floorY = top + side
  let rh = side * 35 div 100
  var order: seq[int]
  for i in 0 ..< n:
    if abs(float(i) - fs.at) < 9: order.add i
  order.sort(proc (p, q: int): int = cmp(abs(float(q) - fs.at), abs(float(p) - fs.at)))
  for i in order:
    block drawIt:
      let off = float(i) - fs.at                  # (-1 the one to the left, 1 to the right)
      let a = clamp(abs(off), 0, 1)               # (how far turned: 0 facing, 1 turned away)
      let sgn = if off < 0: -1.0 else: 1.0
      let mid = float(cx) + sgn * (a * float(side) * 0.62 + max(0.0, abs(off) - 1) * float(step))
      let w = float(side) * (1 - 0.62 * a)        # (its width, foreshortened)
      let x0 = mid - w / 2
      if x0 > float(r.x + r.w) or x0 + w < float(r.x): break drawIt
      let b = covers[i]
      let fb = if b != nil: flippedOf(b) else: nil
      # (its near edge full height, its far edge shorter: in strips)
      let strips = if a < 0.02: 1 else: clamp(int(w) div 3, 4, 24)
      for s in 0 ..< strips:
        let f0 = float(s) / float(strips)
        let f1 = float(s + 1) / float(strips)
        let far = if off < 0: 1 - (f0 + f1) / 2 else: (f0 + f1) / 2     # (0 near edge, 1 far)
        let hh = max(1, int(float(side) * (1 - 0.22 * a * far)))
        let sx0 = int(x0 + w * f0)
        let sx1 = max(sx0 + 1, int(x0 + w * f1))
        let yt = floorY - hh
        let dw = max(1, int(w))
        pushClip(rect(sx0, yt, sx1 - sx0, hh))
        if b != nil: drawBitmap(rect(int(x0), yt, dw, hh), b)
        else:
          fill(rect(int(x0), yt, dw, hh), color(70, 74, 82))
          fill(rect(int(x0) + 1, yt + 1, dw - 2, hh - 2), color(40, 42, 48))
        if a > 0: fill(rect(sx0, yt, sx1 - sx0, hh), withAlpha(black, int(110 * a)))
        popClip()
        # (the floor's reflection: the cover upside down under it, fading)
        pushClip(rect(sx0, floorY + 1, sx1 - sx0, min(hh, rh)))
        if fb != nil: drawBitmap(rect(int(x0), floorY + 1, dw, hh), fb)
        else: fill(rect(int(x0), floorY + 1, dw, hh), color(40, 42, 48))
        popClip()
      roundRectShaded(rect(int(x0), floorY + 1, max(1, int(w)), rh), 0, withAlpha(black, 150), black)
  popClip()
  let ty = floorY + rh + dp(4)
  let t = if sel < titles.len: titles[sel] else: ""
  let st = if sel < subtitles.len: subtitles[sel] else: ""
  if t.len > 0:
    let tt = ellipsize(t, r.w - dp(20), tst)
    text(cx - textWidth(tt, tst) div 2, min(ty, r.y + r.h - textH), tt, white, tst)
  if st.len > 0:
    let ss = ellipsize(st, r.w - dp(20))
    text(cx - textWidth(ss) div 2, min(ty, r.y + r.h - textH) + FontH + dp(3), ss, color(170, 170, 176))
  if hit.focused: focusDots(inset(r, 2))
  if accessOn:
    accessNode(arListItem, (if t.len > 0: t else: "Cover " & $(sel + 1)), value = st, id = id, r = r,
               help = $(sel + 1) & " of " & $n & "; Left and Right go along, Enter opens it")
  ui.lastId = id
  ui.lastRect = r

# ---- the About box as a phone's page ---------------------------------------------------------------

var aboutCopiedAt = -1_000_000   # (when its Copy Info was tapped)

proc wordsRows(items: openArray[string]; bullet: bool) =
  ## (rows of words in a `tableGroup`, each wrapped -- in the UI font's cut for reading --, a dot
  ## before each when `bullet`)
  withTextStyle(style(read = true)):
    let pad = if fingers(): dp(12) else: dp(10)
    let dot = if bullet: dp(16) else: 0
    for it in items:
      let w = available()
      let t = tr(it)
      let lines = wrapLines(t, max(dp(40), w - 2 * pad - dot))
      let h = max(tableRowH(false), lines.len * FontH + dp(18))
      let r = place(0, h, fill = true)
      let f = rowFrame(r, false)
      var y = r.y + (r.h - lines.len * FontH) div 2
      # (a right-to-left one -- Arabic -- set from the right, its dot at the right)
      let rtl = textIsRtl(t) and not ui.rtl
      let room = rect(r.x + pad + (if rtl: 0 else: dot), r.y, r.w - 2 * pad - dot, r.h)
      if bullet:
        let s = float(max(dp(3), 3))
        let dx = if rtl: r.x + r.w - pad - dp(4) else: r.x + pad + dp(4)
        disc(float(dx), float(y + FontH div 2), s, if glossLook(): glossDetail() else: accentColor())
      for ln in lines:
        text(lineStart(room, textWidth(ln), rtl), y, ln, f.ink)
        y += FontH
      if accessOn: accessNode(arLabel, tr(it), id = 0, r = r)

proc phoneAbout(open: var bool; a: AboutShown) =
  ## (`aboutBox` on a phone or a tablet: a page -- the icon large over the name, the version and
  ## what it is for; then groups: the version, who made it, the website and the e-mail; what it
  ## is; What's New; Credits; This Device; Copy Info)
  dialog(open, "About " & a.app, 460):
    # the icon, the name, the version, the tagline
    let d = if fingers(): dp(84) else: dp(72)
    let big = style(bold = true, size = 1.6)
    let hr = place(0, dp(14) + d + dp(10) + lineHeight(big) + FontH + dp(4) +
                      (if a.tagline.len > 0: FontH + dp(2) else: 0) + dp(6), fill = true)
    let ic = rect(hr.x + (hr.w - d) div 2, hr.y + dp(14), d, d)
    let gloss = glossLook()
    let rad = if gloss: float(d) * 0.18 elif matteLook(): float(dp(6)) else: float(d) * 0.22
    if gloss:
      roundRect(rect(ic.x, ic.y + 2, ic.w, ic.h), rad, withAlpha(black, 70))
      roundRect(rect(ic.x, ic.y + 1, ic.w, ic.h), rad, withAlpha(black, 60))
    else: softShadow(ic, rad, 6)
    if a.pic != nil and a.pic.w > 0:
      masked(ic, rad):
        drawBitmap(ic, a.pic)
    else:
      let base = accentColor()
      roundRectShaded(ic, rad, mixColor(base, white, 0.25), mixColor(base, black, 0.2))
      let g = if a.glyph.len > 0: a.glyph else: nfWindowMaximize
      let gs = style(size = float(d) / 22)
      text(ic.x + (d - textWidth(g, gs)) div 2, ic.y + (d - lineHeight(gs)) div 2, g, white, gs)
    if gloss:
      # (the shine of an icon of then: its top half)
      pushClip(rect(ic.x, ic.y, ic.w, ic.h * 47 div 100))
      roundRect(ic, rad, withAlpha(white, 64))
      popClip()
      roundFrame(ic, rad, 1, withAlpha(black, 46))
    var y = ic.y + d + dp(10)
    let name = ellipsize(a.app, hr.w - dp(16), big)
    text(hr.x + (hr.w - textWidth(name, big)) div 2, y, name, th.text, big)
    y += lineHeight(big)
    if a.version.len > 0:
      let v = tr("Version ") & a.version
      text(hr.x + (hr.w - textWidth(v)) div 2, y, v, th.gray)
    y += FontH + dp(2)
    if a.tagline.len > 0:
      let t = ellipsize(tr(a.tagline), hr.w - dp(16))
      text(hr.x + (hr.w - textWidth(t)) div 2, y, t, th.gray)
    if accessOn:
      accessNode(arHeading, a.app & (if a.version.len > 0: " " & a.version else: ""), id = 0, r = hr,
                 help = a.tagline)
    # who made it, where to write
    tableGroup(""):
      if a.version.len > 0: discard tableRow("Version", a.version, key = "about-version")
      discard tableRow("Developer", RetroDeveloper, key = "about-dev")
      if tableRow("Website", RetroWebsite, taChevron, key = "about-web").clicked:
        discard openUrl("https://" & RetroWebsite)
      if tableRow("Email", RetroEmail, taChevron, key = "about-mail").clicked:
        discard openUrl("mailto:" & RetroEmail)
      if a.url.len > 0 and tableRow("More", a.url, taChevron, key = "about-url").clicked:
        discard openUrl(a.url)
    if a.lines.len > 0:
      tableGroup("About"):
        wordsRows(a.lines, false)
    if a.whatsNew.len > 0:
      tableGroup(tr("What's New") & (if a.version.len > 0: " " & tr("in") & " " & a.version else: "")):
        wordsRows(a.whatsNew, true)
    if a.credits.len > 0:
      tableGroup("Credits"):
        wordsRows(a.credits, false)
    tableGroup("This Device"):
      for (k, v) in a.facts:
        if k in ["Version", "Developer"]: continue      # (above)
        discard tableRow(k, v, key = "about-fact:" & k)
    let copied = ui.now - aboutCopiedAt < 1500
    tableGroup("", "What it runs on, as text: for a report of a fault."):
      if tableButton(if copied: "Copied" else: "Copy Info"):
        putClipboardText(a.info)
        aboutCopiedAt = ui.now
        wakeIn(1600)

aboutPhone = phoneAbout

## The standard widgets, drawn and behaving like Windows 3.1, by mouse,
## keyboard and finger:
##
## - text: `label`, `paragraph`, `separator`, `image`, `canvas`
## - buttons and choices: `button`, `checkbox`, `radio`, `combo`, `listbox`
## - text boxes: `edit`, `editArea` (`editAt` for widgets made of one)
## - values: `slider`, `spin`, `progress`, `vscroll`, `hscroll`
## - containers: `group`, `tabs`, `tabStrip`, `scrollPanel`, `dialog`,
##   `msgBox`
## - bars and menus: `menubar` / `menu` / `menuItem` / `submenu`,
##   `contextMenu`, `popupMenu`, `toolbar` / `toolButton`, `statusbar`,
##   `captionBar` (and the Windows 3.1 window frame on desktops:
##   `frameLayout`, `framePartAt`, `sizingBorder`)
## - the pieces they are made of: `buttonFace`, `raised`, `sunken`,
##   `checkBox`, `radioDisc`, `arrow`, `scrollbarAt`, `focusDots`

import std/[strutils, tables, math, hashes]
from std/os import getEnv
import std/unicode except strip   # (its strip cuts letters: docs/nim-bugs.md)
import uirelays/input
import core, nerdicons, pixelicons, busy
from typeset import bidiInfo, visualOrderOf, isMark, shownRtl, plainLetters, joinsAt, plainAscii

template th: untyped = ui.theme

const CaretBlinkFor* = 10_000
  ## How long a caret blinks after it last moved, in milliseconds; then it
  ## stays shown, and a window left with a text box focused runs no frames.

var
  caretT: int      ## when the caret last moved; it blinks from there
  repeatAt: int    ## next auto-repeat of a held scroll arrow or spin button
  grab: int        ## where a dragged scroll thumb was taken hold of

# ---- look -------------------------------------------------------------------

proc lookHair(): Color =
  ## (the Glass look's hairline: see `glassHair`)
  if (int(th.window.r) * 77 + int(th.window.g) * 151 + int(th.window.b) * 28) shr 8 < 128:
    Color(r: 255, g: 255, b: 255, a: 36)
  else: Color(r: 20, g: 30, b: 60, a: 46)

proc raised*(r: Rect; t = 2) =
  ## A raised 3D edge `t` pixels thick inside `r`. (Glass: a hairline, the light along its top.)
  if glassLook():
    box(r, lookHair())
    if r.w > 2: hline(r.x + 1, r.y + 1, r.w - 2, Color(r: 255, g: 255, b: 255, a: 90))
    return
  for i in 0 ..< t:
    hline(r.x, r.y + i, r.w - i, th.light)
    vline(r.x + i, r.y, r.h - i, th.light)
    hline(r.x + i, r.y + r.h - 1 - i, r.w - i, th.shadow)
    vline(r.x + r.w - 1 - i, r.y + i, r.h - i, th.shadow)

proc sunken*(r: Rect) =
  ## A 1-pixel sunken 3D edge inside `r`. (Glass: a hairline.)
  if glassLook():
    box(r, lookHair())
    return
  hline(r.x, r.y, r.w, th.shadow)
  vline(r.x, r.y, r.h, th.shadow)
  hline(r.x, r.y + r.h - 1, r.w, th.light)
  vline(r.x + r.w - 1, r.y, r.h, th.light)

proc outline*(r: Rect; t = 1; rounded = true) =
  ## The black frame of a button; `rounded` leaves the corner pixels out.
  let o = if rounded: 1 else: 0
  hline(r.x + o, r.y, r.w - 2*o, th.frame)
  hline(r.x + o, r.y + r.h - 1, r.w - 2*o, th.frame)
  vline(r.x, r.y + o, r.h - 2*o, th.frame)
  vline(r.x + r.w - 1, r.y + o, r.h - 2*o, th.frame)
  if t > 1: outline(inset(r, 1), t - 1, false)

const InvalidRed* = Color(r: 224, g: 32, b: 32, a: 255)
  ## The red of a text box whose text is not right (`edit(invalid = true)`).

proc mixColor*(a, b: Color; t: float): Color =
  ## `a` moved `t` (0..1) of the way to `b`.
  template m(x, y: uint8): uint8 = uint8(float(x) + (float(y) - float(x)) * t + 0.5)
  color(m(a.r, b.r), m(a.g, b.g), m(a.b, b.b))

proc hoverColor*(): Color =
  ## The background of a row or item under the mouse.
  if th.hover.a != 0: th.hover else: mixColor(th.field, th.select, 0.13)

proc onDark(): bool {.inline.} = (int(th.window.r) * 77 + int(th.window.g) * 151 + int(th.window.b) * 28) shr 8 < 128
  ## (the scheme is a dark one: its states' colours lighter)

proc goodColor*(): Color =
  ## The scheme's colour of "all is well" (`Theme.good`, else a green that
  ## shows on its window).
  if th.good.a != 0: th.good elif onDark(): color(84, 200, 122) else: color(30, 140, 70)

proc warnColor*(): Color =
  ## ... of "take care" (`Theme.warn`, else an amber).
  if th.warn.a != 0: th.warn elif onDark(): color(240, 190, 70) else: color(200, 140, 0)

proc badColor*(): Color =
  ## ... of "something is wrong" (`Theme.bad`, else a red).
  if th.bad.a != 0: th.bad elif onDark(): color(244, 110, 110) else: color(200, 40, 40)

proc infoColor*(): Color =
  ## ... of "for your information" (`Theme.info`, else a blue).
  if th.info.a != 0: th.info elif onDark(): color(110, 176, 250) else: color(33, 110, 200)

proc goodBack*(): Color =
  ## The pale green behind text that says all is well: a cell, a strip
  ## (`Theme.goodBack`, else the window a fifth of the way to `goodColor`).
  if th.goodBack.a != 0: th.goodBack else: mixColor(th.window, goodColor(), 0.22)

proc warnBack*(): Color =
  ## ... behind "take care".
  if th.warnBack.a != 0: th.warnBack else: mixColor(th.window, warnColor(), 0.22)

proc badBack*(): Color =
  ## ... behind "something is wrong".
  if th.badBack.a != 0: th.badBack else: mixColor(th.window, badColor(), 0.22)

proc infoBack*(): Color =
  ## ... behind "for your information".
  if th.infoBack.a != 0: th.infoBack else: mixColor(th.window, infoColor(), 0.22)

proc accentColor*(): Color =
  ## The face of the button that matters most (`Theme.accent`, else the
  ## highlight's).
  if th.accent.a != 0: th.accent else: th.select

proc accentInk*(): Color =
  ## ... and its text (`Theme.accentText`, else the highlight's text).
  if th.accentText.a != 0: th.accentText else: th.selectText

proc accentTheme*(): Theme =
  ## The scheme with a button's face, edges and text in the accent's
  ## colours: what `button(accent = true)` is drawn in (`withTheme`).
  result = th
  let a = accentColor()
  let ink = accentInk()
  result.face = a
  result.text = ink
  result.light = mixColor(a, color(255, 255, 255), 0.45)
  result.face2 = mixColor(a, color(255, 255, 255), 0.2)
  result.shadow = mixColor(a, color(0, 0, 0), 0.55)
  result.gray = mixColor(a, ink, 0.5)

template withTheme*(t: Theme; body: untyped) =
  ## Draws `body` in the colours of `t`, then puts the window's own back:
  ## one control, or a part of the window, in colours of its own.
  let savedTheme = ui.theme
  ui.theme = t
  try:
    body
  finally:
    ui.theme = savedTheme

type MobileStyle* = object
  ## How the phone controls are drawn, past the scheme and the look: a color with alpha 0, a size
  ## 0, is the look's own (in the scheme's colors). Set `mobileStyle` for the whole app, or
  ## `withMobileStyle` for a part of it -- as `withTheme` does for colors.
  bar*, barText*: Color      ## the bars at the top: `navBar`, a page's, the app's title bar
  statusBar*: Color          ## under the system's status bar (alpha 0: the top bar's, darker)
  tabBar*, tabText*, tabChosen*: Color
    ## `bottomNav`: its bar, a place's glyph and label, the chosen place's
  sideMenu*, sideMenuText*: Color   ## `sideMenu`: its face, its items' words
  group*, groupLine*: Color  ## a `tableGroup`'s face, the line between its rows
  rowText*, rowDetail*: Color       ## a row's title, the value at its end
  groupCorner*: float        ## a `tableGroup`'s corners (a negative: square)
  rowHeight*: int            ## a row's height, in design pixels (`dp`)

var mobileStyle*: MobileStyle
  ## The phone controls' colors and sizes of the app's own (see `MobileStyle`): none, the look's.

template withMobileStyle*(s: MobileStyle; body: untyped) =
  ## Draws `body` with the phone controls in `s` (`MobileStyle`), then as they were.
  let savedMobile = mobileStyle
  mobileStyle = s
  try:
    body
  finally:
    mobileStyle = savedMobile

proc hotFace*(): Color =
  ## A button face under the mouse: a little lighter.
  mixColor(th.face, th.light, 0.45)

proc lumaOfColor*(c: Color): int =
  ## How light a color is (0..255).
  (int(c.r) * 77 + int(c.g) * 151 + int(c.b) * 28) shr 8

proc contrastInk*(bg, a, b: Color): Color =
  ## Of `a` and `b`, the one that shows better on `bg`.
  if abs(lumaOfColor(a) - lumaOfColor(bg)) >= abs(lumaOfColor(b) - lumaOfColor(bg)): a else: b

proc softLight*(): Color =
  ## The second, softer highlight inside a raised face (`Theme.face2`).
  if th.face2.a != 0: th.face2 else: mixColor(th.face, th.light, 0.5)

# ---- the Glass look (`uiLook`) ---------------------------------------------------------------
# (the light on a face's upper half and along its top edge, a hairline round it, a soft shadow
# under it; the scheme's colors -- its face, its highlight -- so Glass goes with every scheme;
# menus, dialogs and dropped lists of frosted glass, what is under them blurred: `frostedGlass`)

proc withAlpha*(c: Color; a: int): Color {.inline.} =
  ## `c` with alpha `a` (0..255): drawn see-through.
  Color(r: c.r, g: c.g, b: c.b, a: uint8(clamp(a, 0, 255)))

proc glassHair*(): Color =
  ## The hairline round a surface of the Glass look.
  lookHair()

proc modernGlass*(): bool {.inline.} =
  ## The controls drawn in the Glass look itself now -- not Matte or Gloss, which share its
  ## shapes (`glassLook`).
  uiLook == lookGlass and glassLook()

proc glossOnyx*(): bool {.inline.} =
  ## Gloss with its black scheme, `GlossOnyx`: its tab bar a floating capsule, its buttons pills.
  uiLook == lookGloss and glassLook() and th.window == GlossOnyx.window and th.select == GlossOnyx.select

proc glassRadius*(r: Rect): float =
  ## (a surface's corners: a capsule for a button, a card's rounding for what is bigger; Matte's
  ## all but square, Gloss's a rounded rectangle)
  if matteLook(): return min(float(min(r.w, r.h)) / 2, float(dp(3)))
  if glossLook(): return min(float(min(r.w, r.h)) / 2, float(dp(6)))
  min(float(min(r.w, r.h)) / 2, float(dp(12)))

const white = color(255, 255, 255)
const black = color(0, 0, 0)

# ---- Gloss's colors: the scheme's own hue ---------------------------------------------------------

proc hsvOf(c: Color): tuple[h, s, v: float] =
  let r = float(c.r) / 255
  let g = float(c.g) / 255
  let b = float(c.b) / 255
  let mx = max(r, max(g, b))
  let mn = min(r, min(g, b))
  let d = mx - mn
  result.v = mx
  result.s = if mx > 0: d / mx else: 0.0
  if d <= 0: return
  var h = if mx == r: (g - b) / d elif mx == g: 2 + (b - r) / d else: 4 + (r - g) / d
  h *= 60
  if h < 0: h += 360
  result.h = h

proc hsvColor(h, s, v: float): Color =
  let s = clamp(s, 0.0, 1.0)
  let v = clamp(v, 0.0, 1.0)
  let c = v * s
  let hh = (h mod 360) / 60
  let x = c * (1 - abs(hh mod 2 - 1))
  let (r, g, b) = if hh < 1: (c, x, 0.0) elif hh < 2: (x, c, 0.0) elif hh < 3: (0.0, c, x)
                  elif hh < 4: (0.0, x, c) elif hh < 5: (x, 0.0, c) else: (c, 0.0, x)
  let m = v - c
  Color(r: uint8(clamp(int((r + m) * 255 + 0.5), 0, 255)), g: uint8(clamp(int((g + m) * 255 + 0.5), 0, 255)),
        b: uint8(clamp(int((b + m) * 255 + 0.5), 0, 255)), a: 255)

proc glossTone*(s, v: float): Color =
  ## Gloss: a color of the scheme's own hue -- its accent's (`accentColor`) --, `s` as colored
  ## as iOS 6's blue parts were (less in a scheme whose accent is grayish), `v` as bright. Every
  ## part of Gloss that was steel blue or blue takes its color from here: the bars, the chosen
  ## row, the default button, the switch, the slider, the alert, the popover -- so a scheme's
  ## accent colors them all (Gloss Light's own: the blue of then).
  let (h, sa, va) = hsvOf(accentColor())
  # (how colored the scheme's accent is: a grayish one grays them, a near-black one too)
  let k = clamp(sa / 0.6, 0.0, 1.0) * clamp(va / 0.3, 0.0, 1.0)
  result = hsvColor(h, s * k, v)
  # (as light as the blue would be: a green or a yellow as bright as the blue reads lighter --
  # darker, so a hue looks as deep as Gloss's blue)
  let want = min(255, lumaOfColor(hsvColor(215, s * k, v)) * 4 div 3)
  let got = lumaOfColor(result)
  if got > want and got > 0: result = hsvColor(h, s * k, v * float(want) / float(got))

proc glossTint*(c: Color): Color =
  ## Gloss: one of iOS 6's colors -- drawn then in its blue, Gloss Light's highlight's hue -- in
  ## the scheme's own hue, as `glossTone` colors Gloss's parts: in Gloss Light the very color, in
  ## a green scheme the same steel in green, grayed in a grayish one. Its alpha kept.
  let (ah, sa, va) = hsvOf(accentColor())
  let k = clamp(sa / 0.6, 0.0, 1.0) * clamp(va / 0.3, 0.0, 1.0)
  let shift = ah - hsvOf(GlossLight.select).h
  if abs(shift) < 0.5 and k > 0.999: return c
  let (h, s, v) = hsvOf(c)
  result = hsvColor(h + shift, s * k, v)
  # (as light as the color was: a green or a yellow as bright reads lighter -- darker, as
  # `glossTone` does)
  let want = min(255, lumaOfColor(c) * 4 div 3)
  let got = lumaOfColor(result)
  if got > want and got > 0: result = hsvColor(h + shift, s * k, v * float(want) / float(got))
  result.a = c.a

proc towards(a, b: Color; t: float): Color =
  ## (the color `t` of the way from `a` to `b` -- past `b` when `t` > 1 --, clamped)
  template ch(x, y: uint8): uint8 = uint8(clamp(int(round(float(x) + (float(y) - float(x)) * t)), 0, 255))
  Color(r: ch(a.r, b.r), g: ch(a.g, b.g), b: ch(a.b, b.b), a: a.a)

proc bandOf(r: Rect; stops: openArray[Color]; i: int): tuple[band: Rect; top, foot: Color] =
  ## (the `i`th band of a face shaded through `stops`, and the colors at the face's top and foot
  ## a gradient through that band's two stops would have)
  let n = stops.len - 1
  let y0 = r.y + r.h * i div n
  let bh = r.y + r.h * (i + 1) div n - y0
  if bh <= 0: return (rect(r.x, y0, r.w, 0), stops[i], stops[i])
  let (a, b) = (stops[i], stops[i + 1])
  (rect(r.x, y0, r.w, bh), towards(a, b, float(r.y - y0) / float(bh)),
   towards(a, b, float(r.y + r.h - y0) / float(bh)))

proc glossStopsAt*(r: Rect; rad: float; stops: openArray[(float, Color)]) =
  ## Gloss: a face shaded through `stops` -- each a place from its top (0.0) to its foot (1.0)
  ## and the color there --, its corners rounded `rad`: iOS 6's bars, buttons, sheets.
  if r.w <= 0 or r.h <= 0 or stops.len == 0: return
  if stops.len == 1 or r.h < 2 * stops.high:
    roundRectShaded(r, rad, stops[0][1], stops[^1][1])
    return
  let ext = int(ceil(min(rad, float(min(r.w, r.h)) / 2)))
  for i in 0 ..< stops.high:
    let y0 = r.y + int(round(float(r.h) * clamp(stops[i][0], 0.0, 1.0)))
    let y1 = r.y + int(round(float(r.h) * clamp(stops[i + 1][0], 0.0, 1.0)))
    let bh = y1 - y0
    if bh <= 0: continue
    let (a, b) = (stops[i][1], stops[i + 1][1])
    # (the band drawn longer than it is where it meets another, so the rounded corners fall
    # outside it there: only the face's own top and foot are rounded)
    let up = if i == 0: 0 else: ext
    let down = if i == stops.high - 1: 0 else: ext
    pushClip(rect(r.x, y0, r.w, bh))
    roundRectShaded(rect(r.x, y0 - up, r.w, bh + up + down), rad,
                    towards(a, b, -float(up) / float(bh)), towards(a, b, float(bh + down) / float(bh)))
    popClip()

proc glossStops*(r: Rect; rad: float; stops: openArray[Color]) =
  ## Gloss: a face shaded through `stops`, spaced evenly from its top to its foot -- iOS 6's bars
  ## and buttons, four (at 0, a third, two thirds, the foot) --, its corners rounded `rad`.
  if stops.len == 0: return
  var at: seq[(float, Color)]
  for i, c in stops:
    let t = if stops.len == 1: 0.0 else: float(i) / float(stops.high)
    at.add (t, c)
  glossStopsAt(r, rad, at)

proc glossStopsShape*(pts: openArray[(float, float)]; r: Rect; stops: openArray[Color]) =
  ## Gloss: the polygon `pts` (`r` round it) shaded through `stops` as `glossStops` -- a Back
  ## button's pointed end.
  if r.w <= 0 or r.h <= 0 or stops.len == 0: return
  let n = stops.len - 1
  if n == 0 or r.h < 2 * n:
    polygonShaded(pts, stops[0], stops[^1])
    return
  for i in 0 ..< n:
    let (band, top, foot) = bandOf(r, stops, i)
    if band.h <= 0: continue
    pushClip(band)
    polygonShaded(pts, top, foot)
    popClip()

proc glossInsetLines*(r: Rect; top: openArray[Color]; foot: openArray[Color] = []; cut = 0) =
  ## Gloss: the lines just inside a face's top (`top`, from the top down) and its foot (`foot`,
  ## from the foot up) -- iOS 6's inner shadows and lights --, `cut` short of its ends.
  for k, c in top:
    if c.a != 0 and k < r.h: hline(r.x + cut, r.y + k, r.w - 2 * cut, c)
  for k, c in foot:
    if c.a != 0 and k < r.h: hline(r.x + cut, r.y + r.h - 1 - k, r.w - 2 * cut, c)

proc alphaOf(c: Color; a: float): Color = withAlpha(c, int(round(a * 255)))

proc glossTopShade*(f: Rect; rad: float; alphas: openArray[int]; ink = black) =
  ## Gloss: the shadow inside a sunk face's top (`f`, its corners rounded `rad`) -- a row of
  ## `ink` (black) each `alphas`, from the top down, as wide as the face is at that row: iOS 6's
  ## fields and wells, cut into what holds them; in white, the light along a sheet's top.
  let rr = min(rad, float(min(f.w, f.h)) / 2)
  for k, a in alphas:
    if k >= f.h or a <= 0: continue
    let dy = rr - float(k) - 0.5
    let dx = if dy > 0: rr - sqrt(max(0.0, rr * rr - dy * dy)) else: 0.0
    let cut = int(round(dx))
    if f.w > 2 * cut: hline(f.x + cut, f.y + k, f.w - 2 * cut, withAlpha(ink, min(255, a)))

proc glossDetail*(): Color =
  ## Gloss: the color of a value at a row's end, a check mark, a link in a table -- iOS 6's
  ## slate blue in the scheme's hue, dark on a light window, light on a dark one.
  if lumaOfColor(th.field) < 128 or lumaOfColor(th.window) < 100: glossTone(0.4, 0.92)
  else: glossTint(color(56, 84, 135))

proc glossShine*(f: Rect; rad: float; base: Color; dark: bool) =
  ## (Gloss: a face in `base` with its shine -- its top half lighter, a hard edge at its middle,
  ## the light falling off down its top half; its foot a little darker)
  roundRectShaded(f, rad, mixColor(base, white, if dark: 0.08 else: 0.25),
                  mixColor(base, black, if dark: 0.16 else: 0.10))
  let hh = f.h div 2
  if hh >= 2:
    pushClip(rect(f.x, f.y, f.w, hh))
    roundRectShaded(f, rad, mixColor(base, white, if dark: 0.26 else: 0.9),
                    mixColor(base, white, if dark: 0.10 else: 0.42))
    popClip()

proc glassFace*(r: Rect; pressed = false; hot = false; radius = -1.0; ring = Color(); shadow = true) =
  ## A surface of frosted glass in `r` (the Glass look): a soft shadow under it, a hairline round
  ## it (`ring`, when given: in its color -- the default button's), its face in the scheme's face
  ## color (lighter under the pointer, darker pressed), the light on its upper half and along its
  ## top edge. `radius` -1: as round as `glassRadius`.
  if r.w <= 0 or r.h <= 0: return
  let rad = if radius < 0: glassRadius(r) else: radius
  let dark = onDark()
  if matteLook():
    # (flat: a thin line round one color; under the pointer a little darker, pressed the
    # highlight's tint)
    roundRect(r, rad, if ring.a != 0: ring else: mixColor(th.face, th.text, if dark: 0.30 else: 0.22))
    let f = inset(r, 1)
    if f.w > 0 and f.h > 0:
      roundRect(f, max(0.0, rad - 1), if pressed: mixColor(th.face, accentColor(), 0.32)
                                      elif hot: mixColor(th.face, th.text, if dark: 0.10 else: 0.05)
                                      else: th.face)
    return
  if glossLook():
    # (a shine on its top half, a deep outline, on a light window a white line under it: pressed
    # in, it reads as cut into the window)
    if shadow and not dark and r.h >= 8:
      roundRect(rect(r.x, r.y + 1, r.w, r.h), rad, withAlpha(white, 170))
    roundRect(r, rad, if ring.a != 0: ring else: mixColor(th.face, black, if dark: 0.6 else: 0.46))
    let f = inset(r, 1)
    if f.w > 0 and f.h > 0:
      let base = if pressed: mixColor(th.face, th.shadow, 0.45)
                 elif hot: mixColor(th.face, th.light, 0.35)
                 else: th.face
      glossShine(f, max(0.0, rad - 1), base, dark)
    return
  if shadow and not pressed and r.h >= 8:
    # (a soft shadow: wide and faint, then close and a little darker)
    roundRect(rect(r.x - 1, r.y + 1, r.w + 2, r.h + 2), rad + 1, withAlpha(color(0, 0, 0), if dark: 60 else: 12))
    roundRect(rect(r.x, r.y + 1, r.w, r.h), rad, withAlpha(color(0, 0, 0), if dark: 90 else: 22))
  roundRect(r, rad, if ring.a != 0: ring else: glassHair())
  let f = inset(r, 1)
  if f.w <= 0 or f.h <= 0: return
  let fr = max(0.0, rad - 1)
  let base = if pressed: mixColor(th.face, th.shadow, 0.16)
             elif hot: mixColor(th.face, th.light, 0.45)
             else: th.face
  # (the light from above: the face shaded from lighter at its top to a little darker at its
  # foot, a bright line along its top; pressed, the other way round)
  let top = if pressed: mixColor(base, th.shadow, 0.12)
            else: mixColor(base, color(255, 255, 255), if dark: 0.14 else: 0.7)
  let foot = if pressed: base else: mixColor(base, color(0, 0, 0), if dark: 0.10 else: 0.05)
  roundRectShaded(f, fr, top, foot)
  let cut = int(fr * 0.7)
  if f.w > 2 * cut + 2:
    if not pressed:
      hline(f.x + cut, f.y, f.w - 2 * cut, withAlpha(color(255, 255, 255), if dark: 52 else: 220))
    else:
      hline(f.x + cut, f.y, f.w - 2 * cut, withAlpha(color(0, 0, 0), if dark: 70 else: 30))

proc glassWell*(r: Rect; radius = -1.0; back = th.field) =
  ## A sunk surface of the Glass look -- a check box's, a switch's track, a field: `back`, a
  ## hairline round it, a soft shadow inside along its top.
  if r.w <= 0 or r.h <= 0: return
  let rad = if radius < 0: glassRadius(r) else: radius
  if matteLook():
    roundRect(r, rad, mixColor(back, th.text, if onDark(): 0.34 else: 0.3))
    roundRect(inset(r, 1), max(0.0, rad - 1), back)
    return
  if glossLook():
    # (cut into the window: a deep line round it, its inside shaded along its top)
    roundRect(r, rad, mixColor(back, black, if onDark(): 0.5 else: 0.42))
    let f = inset(r, 1)
    roundRectShaded(f, max(0.0, rad - 1), mixColor(back, black, if onDark(): 0.25 else: 0.16), back)
    return
  roundRect(r, rad, glassHair())
  let f = inset(r, 1)
  roundRect(f, max(0.0, rad - 1), back)
  let cut = int(rad * 0.7)
  if f.w > 2 * cut + 2: hline(f.x + cut, f.y, f.w - 2 * cut, withAlpha(color(0, 0, 0), if onDark(): 60 else: 22))

proc glassAccent*(r: Rect; radius = -1.0) =
  ## What is on in the Glass look -- a check box ticked, a radio button chosen, a switch on, a
  ## slider's filled part: the scheme's highlight, lit from above.
  if r.w <= 0 or r.h <= 0: return
  let rad = if radius < 0: glassRadius(r) else: radius
  let a = accentColor()
  if matteLook():
    roundRect(r, rad, a)
    return
  if glossLook():
    roundRect(r, rad, mixColor(a, black, 0.42))
    let f = inset(r, 1)
    if f.w > 0 and f.h > 0: glossShine(f, max(0.0, rad - 1), a, onDark())
    return
  roundRect(r, rad, mixColor(a, color(0, 0, 0), 0.2))
  let f = inset(r, 1)
  roundRectShaded(f, max(0.0, rad - 1), mixColor(a, color(255, 255, 255), 0.22), mixColor(a, color(0, 0, 0), 0.06))
  let cut = int(max(0.0, rad - 1) * 0.7)
  if f.w > 2 * cut + 2: hline(f.x + cut, f.y, f.w - 2 * cut, withAlpha(color(255, 255, 255), 70))

proc tintedFace*(r: Rect; base: Color; pressed = false; radius = -1.0) =
  ## A button's face in a color of its own (`base`: a destructive one's red, a bar's buttons), as
  ## the look draws one: 3.1's raised edges round it; Glass lit from above; Matte flat; Gloss
  ## with its shine. Pressed: darker.
  if r.w <= 0 or r.h <= 0: return
  let b = if pressed: mixColor(base, black, 0.22) else: base
  if not glassLook():
    box(r, th.frame)
    let f = inset(r, 1)
    fill(f, b)
    if pressed:
      hline(f.x, f.y, f.w, mixColor(b, black, 0.4))
      vline(f.x, f.y, f.h, mixColor(b, black, 0.4))
    else:
      hline(f.x, f.y, f.w, mixColor(b, white, 0.45))
      vline(f.x, f.y, f.h, mixColor(b, white, 0.45))
      hline(f.x, f.y + f.h - 1, f.w, mixColor(b, black, 0.4))
      vline(f.x + f.w - 1, f.y, f.h, mixColor(b, black, 0.4))
    return
  let rad = if radius < 0: glassRadius(r) else: radius
  if matteLook():
    roundRect(r, rad, b)
    return
  if glossLook():
    # (the gentler shine: white on it reads)
    roundRect(r, rad, mixColor(b, black, 0.45))
    let f = inset(r, 1)
    if f.w > 0 and f.h > 0: glossShine(f, max(0.0, rad - 1), b, true)
    return
  roundRect(r, rad, mixColor(b, black, 0.2))
  let f = inset(r, 1)
  roundRectShaded(f, max(0.0, rad - 1), mixColor(b, white, 0.22), mixColor(b, black, 0.06))

# ---- Gloss's parts as phones drew them then: bars, bar buttons, the blue of a chosen row ---------

const
  # (iOS 6's own colors, as the Legacy iOS UI Kit measures them: in Gloss Light's hue, tinted
  # to a scheme's by `glossTint`)
  navStops = [color(193, 209, 228), color(161, 178, 201), color(117, 140, 171), color(85, 112, 148)]
    ## a navigation bar, a title bar
  toolStops = [color(181, 196, 215), color(152, 171, 195), color(113, 137, 168), color(87, 114, 150)]
    ## a tool bar at the foot
  steelStops = [color(162, 178, 201), color(121, 142, 172), color(80, 109, 148), color(64, 95, 138)]
    ## a bar's button, a chosen segment
  blueStops = [color(147, 181, 246), color(103, 144, 225), color(60, 113, 218), color(37, 98, 217)]
    ## a bar's blue button (Done, Save)
  redStops = [color(219, 139, 146), color(195, 98, 106), color(178, 48, 59), color(176, 26, 39)]
    ## a bar's red button (Delete)
  segStops = [color(177, 193, 213), color(145, 163, 187), color(114, 138, 169), color(96, 125, 160)]
    ## a bar's segment not chosen
  cancelStops = [color(141, 155, 175), color(130, 145, 167), color(111, 129, 154), color(101, 120, 146)]
    ## a search bar's Cancel
  searchStops = [color(214, 221, 226), color(204, 212, 217), color(189, 199, 205), color(178, 189, 196)]
    ## a search bar

proc tinted(stops: openArray[Color]): array[4, Color] =
  for i in 0 .. 3: result[i] = glossTint(stops[min(i, stops.high)])

proc glossOwnScheme*(): bool =
  ## Gloss in a scheme of its own (Gloss Light, Gloss Dark, Gloss Onyx): iOS 6's steel blue and
  ## black bars. In another scheme the bars, the tab bar and the side menu take its colors.
  for t in [GlossLight, GlossDark, GlossOnyx]:
    if th.window == t.window and th.face == t.face and th.select == t.select: return true
  false

proc glossBarColors*(): tuple[top, foot: Color] =
  ## Gloss: a navigation bar's, a tool bar's, a title bar's gradient -- on a light window iOS
  ## 6's steel blue in the scheme's hue (`glossTint`); on a dark one black in Gloss's own schemes,
  ## the scheme's face in its highlight's hue in the others (`MobileStyle.bar`: that color's).
  if mobileStyle.bar.a != 0: (mixColor(mobileStyle.bar, white, 0.22), mixColor(mobileStyle.bar, black, 0.22))
  elif onDark() and glossOwnScheme(): (color(80, 82, 88), color(12, 12, 14))
  elif onDark():
    let base = mixColor(th.face, accentColor(), 0.4)
    (mixColor(base, white, 0.2), mixColor(base, black, 0.35))
  else: (glossTint(navStops[0]), glossTint(navStops[3]))

proc glossDarkFace*(): Color =
  ## Gloss: the face of its dark parts -- the tab bar, the side menu: iOS 6's black and charcoal
  ## in Gloss's own schemes, the bars' color made darker in the others.
  if glossOwnScheme() and mobileStyle.bar.a == 0: color(30, 30, 33)
  else: mixColor(glossBarColors().foot, black, 0.35)

proc glossBarFill*(r: Rect) =
  ## Gloss: a navigation bar's face in `r`: iOS 6's steel blue through its four stops, a light
  ## line along its top (two: the glass catching it), a faint dark one along its foot; black
  ## gloss on a dark window.
  if r.w <= 0 or r.h <= 0: return
  if onDark() or mobileStyle.bar.a != 0:
    let (top, foot) = glossBarColors()
    roundRectShaded(r, 0, top, foot)
    hline(r.x, r.y, r.w, withAlpha(white, 46))
    hline(r.x, r.y + 1, r.w, withAlpha(white, 14))
    hline(r.x, r.y + r.h - 1, r.w, black)
    return
  glossStops(r, 0, tinted(navStops))
  glossInsetLines(r, [alphaOf(white, 0.6), alphaOf(white, 0.3)], [alphaOf(black, 0.1)])

proc glossToolFill*(r: Rect) =
  ## Gloss: a tool bar's face at the foot of the window in `r` -- a little lighter than a
  ## navigation bar, a dark line along its top and two of light under it; black on a dark one.
  if r.w <= 0 or r.h <= 0: return
  if onDark():
    glossBarFill(r)
    return
  glossStops(r, 0, tinted(toolStops))
  glossInsetLines(r, [glossTint(color(95, 116, 140)), alphaOf(white, 0.4), alphaOf(white, 0.2)])

proc glossSearchFill*(r: Rect) =
  ## Gloss: a search bar's face in `r` -- grayer and lighter than a navigation bar, a dark line
  ## along its foot; black on a dark window.
  if r.w <= 0 or r.h <= 0: return
  if onDark():
    glossBarFill(r)
    return
  glossStops(r, 0, tinted(searchStops))
  glossInsetLines(r, [alphaOf(white, 0.3), alphaOf(white, 0.2)], [alphaOf(black, 0.5)])

proc glossBarShadow*(r: Rect; up = false) =
  ## Gloss: the soft shadow a bar casts on the page -- under a navigation bar, over a tool bar
  ## (`up`).
  for k in 0 ..< max(2, dp(2)):
    let a = if k == 0: 70 else: 26
    if up: hline(r.x, r.y - 1 - k, r.w, withAlpha(black, a))
    else: hline(r.x, r.y + r.h + k, r.w, withAlpha(black, a))

proc glossBlue*(r: Rect; radius = 0.0) =
  ## Gloss: the blue of a chosen row, a pressed button, a chosen segment -- lighter at its top;
  ## in the scheme's hue (`glossTone`).
  if r.w > 0 and r.h > 0: roundRectShaded(r, radius, glossTone(0.98, 0.96), glossTone(1.0, 0.86))

proc arrowPoints(r: Rect; point, radius, inset: float): seq[(float, float)] =
  ## (a button's outline with its left end a point and its right corners rounded, `inset` in)
  let x0 = float(r.x) + inset * 1.4
  let y0 = float(r.y) + inset
  let x1 = float(r.x + r.w) - inset
  let y1 = float(r.y + r.h) - inset
  let rr = max(0.0, radius - inset)
  result.add (x0, (y0 + y1) / 2)
  result.add (float(r.x) + point, y0)
  for k in 0 .. 5:
    let a = -PI / 2 + PI / 2 * float(k) / 5
    result.add (x1 - rr + rr * cos(a), y0 + rr + rr * sin(a))
  for k in 0 .. 5:
    let a = PI / 2 * float(k) / 5
    result.add (x1 - rr + rr * cos(a), y1 - rr + rr * sin(a))
  result.add (float(r.x) + point, y1)

proc darker(stops: openArray[Color]; k: float): array[4, Color] =
  for i in 0 .. 3: result[i] = mixColor(stops[min(i, stops.high)], black, k)

proc glossBarButton*(r: Rect; pressed: bool; back = false; done = false; destructive = false;
                     onSearch = false) =
  ## Gloss: a bar's bordered button, as iOS 6 drew one -- the bar's steel a shade deeper through
  ## its four stops, a dark edge round it and a darker line inside its top (set into the bar), a
  ## light line under it; `back`: its left end a point (a navigation bar's Back); `done`: blue
  ## (Done, Save); `destructive`: red (Delete); `onSearch`: a search bar's grayer steel (Cancel).
  ## Pressed: darker. Its label goes on it white, bold (`glossButtonStyle`), a dark line over it.
  if r.w <= 0 or r.h <= 0: return
  let dark = onDark()
  # (on bars of the scheme's or the app's color: that color, a shade deeper)
  let own = mobileStyle.bar.a != 0 or (dark and not glossOwnScheme())
  let (bt, bf) = glossBarColors()
  var stops = if destructive: @redStops
              elif done: @(tinted(blueStops))
              elif own: @[mixColor(bt, black, 0.05), mixColor(bt, bf, 0.55), mixColor(bf, black, 0.15),
                          mixColor(bf, black, 0.3)]
              elif dark: @[color(92, 94, 100), color(58, 60, 66), color(34, 35, 39), color(20, 20, 22)]
              elif onSearch: @(tinted(cancelStops))
              else: @(tinted(steelStops))
  if pressed: stops = @(darker(stops, 0.25))
  let edge = mixColor(stops[3], black, if dark: 0.7 else: 0.45)
  let rad = float(min(dp(5), r.h div 2))
  let lift = withAlpha(white, if dark: 26 else: 102)
  if back:
    let p = float(min(r.h div 2, dp(13)))
    # (the light under it, then its edge, then its face)
    polygon(arrowPoints(rect(r.x, r.y + 1, r.w, r.h), p, rad, 0), lift)
    polygon(arrowPoints(r, p, rad, 0), edge)
    let f = inset(r, 1)
    glossStopsShape(arrowPoints(r, p, rad, 1), f, stops)
    hline(r.x + int(p), r.y + 1, r.w - int(p) - int(rad), withAlpha(black, 102))
  else:
    roundRect(rect(r.x, r.y + 1, r.w, r.h), rad, lift)
    roundRect(r, rad, edge)
    glossStops(inset(r, 1), max(0.0, rad - 1), stops)
    hline(r.x + int(rad), r.y + 1, r.w - 2 * int(rad), withAlpha(black, 102))

proc glossButtonStyle*(): TextStyle =
  ## Gloss: the style of a bar button's label -- bold, iOS 6's 12 points on a phone.
  style(bold = true, size = if fingers(): 0.8 else: 0.9)

proc beyond(a, b: Color): Color =
  ## (the color as far past `b` as `b` is from `a`: a gradient's end whose middle is `b`)
  template ch(x, y: uint8): uint8 = uint8(clamp(2 * int(y) - int(x), 0, 255))
  Color(r: ch(a.r, b.r), g: ch(a.g, b.g), b: ch(a.b, b.b), a: b.a)

proc glossTwoTone*(f: Rect; rad: float; top, mid, low, foot: Color) =
  ## Gloss: a face lit as glass was then -- its top half from `top` to `mid`, a hard edge at its
  ## middle, its lower half from `low` to `foot`.
  if f.w <= 0 or f.h <= 0: return
  roundRectShaded(f, rad, beyond(foot, low), foot)
  let hh = f.h div 2
  if hh >= 1:
    pushClip(rect(f.x, f.y, f.w, hh))
    roundRectShaded(f, rad, top, beyond(top, mid))
    popClip()

proc glossButtonFace*(r: Rect; pressed: bool; primary = false; hot = false) =
  ## Gloss on a light window: a push button as iOS 6 drew one -- light gray to a shade darker,
  ## a gray line round it (darker at its top), a white line inside its top and one under it;
  ## the default one (`primary`) blue, and blue while it is pressed.
  if r.w <= 0 or r.h <= 0: return
  let rad = float(min(if fingers(): dp(10) else: dp(7), r.h div 2))
  if r.h >= 8: roundRect(rect(r.x, r.y + 1, r.w, r.h), rad, white)
  let f = inset(r, 1)
  if pressed or primary:
    # (in the scheme's hue: iOS 6's blue in Gloss Light's)
    var stops = tinted(blueStops)
    if pressed:
      for c in stops.mitems: c = mixColor(c, black, 0.12)
    roundRectShaded(r, rad, mixColor(stops[0], black, 0.45), mixColor(stops[3], black, 0.4))
    glossStops(f, max(0.0, rad - 1), stops)
    glossTopShade(f, max(0.0, rad - 1), [90, 30], white)
  else:
    let (top, foot) = if hot: (color(246, 246, 246), color(226, 226, 226))
                      else: (color(239, 239, 239), color(219, 219, 219))
    roundRectShaded(r, rad, color(179, 179, 179), color(186, 186, 186))
    roundRectShaded(f, max(0.0, rad - 1), top, foot)
    glossTopShade(f, max(0.0, rad - 1), [255, 140], white)

proc glossSheetButton*(r: Rect; pressed: bool; kind = 0) =
  ## Gloss: a button of an action sheet, as iOS 6 drew one -- in a dark well, light gray lit at
  ## its top (`kind` 0), red (1: Delete), slate (2: Cancel; black on a dark window); blue while
  ## it is pressed.
  if r.w <= 0 or r.h <= 0: return
  let wr = float(min(dp(12), r.h div 2))
  # (its well: darker than the sheet, a light line under it, a shadow inside along its top)
  roundRect(rect(r.x, r.y + 1, r.w, r.h), wr, withAlpha(white, 51))
  roundRect(r, wr, withAlpha(black, 77))
  glossTopShade(r, wr, [150, 70, 20])
  let p = max(2, dp(3))
  let f = inset(r, p)
  let fr = max(0.0, wr - float(p))
  roundRect(rect(f.x, f.y + 1, f.w, f.h + 1), fr, withAlpha(black, 90))
  let (top, mid, foot) =
    if pressed: (mixColor(glossTint(blueStops[0]), white, 0.2), glossTint(blueStops[2]), glossTint(blueStops[3]))
    elif kind == 1: (mixColor(color(212, 12, 13), white, 0.55), color(212, 12, 13), mixColor(color(212, 12, 13), white, 0.3))
    elif kind == 2 and lumaOfColor(th.window) < 128: (mixColor(color(8, 8, 8), white, 0.35), color(8, 8, 8), mixColor(color(8, 8, 8), white, 0.1))
    elif kind == 2: (mixColor(color(43, 48, 56), white, 0.3), color(43, 48, 56), mixColor(color(43, 48, 56), white, 0.05))
    else: (white, color(194, 195, 197), mixColor(color(194, 195, 197), white, 0.6))
  glossStopsAt(f, fr, [(0.0, top), (0.7, mid), (1.0, foot)])
  roundFrame(f, fr, 1, withAlpha(white, 26))

proc glossAlertButton*(r: Rect; pressed: bool; primary = false) =
  ## Gloss: a button of an alert, as iOS 6 drew one -- the alert's blue lit as glass, its top
  ## half lighter with a hard edge at its middle (`primary`, the last of two: lighter still), a
  ## dark line round it, a faint light one under it. Pressed: darker.
  if r.w <= 0 or r.h <= 0: return
  let rad = float(min(dp(5), r.h div 2))
  roundRect(rect(r.x, r.y + 1, r.w, r.h), rad, withAlpha(white, 51))
  roundRect(r, rad, withAlpha(black, 102))
  let base = glossTint(color(16, 32, 78))
  let ks = if primary: [0.6, 0.36, 0.24, 0.36] else: [0.4, 0.16, 0.04, 0.08]
  var c: array[4, Color]
  for i in 0 .. 3:
    c[i] = mixColor(base, white, ks[i])
    if pressed: c[i] = mixColor(c[i], black, 0.3)
  glossTwoTone(inset(r, 1), max(0.0, rad - 1), c[0], c[1], c[2], c[3])

proc glossText*(x, y: int; s: string; c: Color; bold = true; shadowDown = false) =
  ## Gloss: text pressed into its face, as it was written then: a dark line above white text
  ## (on a bar, a blue button), a white one under dark text (`shadowDown`: on a light face).
  if shadowDown: text(x, y + 1, s, withAlpha(white, 190), bold)
  else: text(x, y - 1, s, withAlpha(black, 95), bold)
  text(x, y, s, c, bold)

proc buttonBold*(): bool =
  ## A push button's label is bold (Gloss's buttons on a light window).
  glossLook() and not onDark() and lumaOfColor(th.face) >= 160

proc buttonInk*(pressed: bool; enabled = true; primary = false): Color =
  ## The color of a push button's label as the look writes it: the scheme's text; Gloss on a
  ## light window, iOS 6's dark gray -- white on the blue of the default button (`primary`)
  ## and of one pressed.
  if not enabled: th.gray
  elif buttonBold() and (pressed or primary): white
  elif primary and modernGlass(): white
  elif buttonBold(): color(60, 60, 60)
  else: th.text

proc buttonLabel*(x, y: int; label: string; ink: Color; bold: bool) =
  ## (a push button's label with its mnemonic: Gloss's pressed into its face -- a white line
  ## under dark text, a dark one over white text)
  if buttonBold():
    if lumaOfColor(ink) >= 160: drawLabel(x, y - 1, label, withAlpha(black, 100), bold)
    else: drawLabel(x, y + 1, label, withAlpha(white, 200), bold)
  drawLabel(x, y, label, ink, bold)

proc glassTrack*(r: Rect) =
  ## Glass: the track a segmented choice sits in -- a page's tabs, `segmented`: a capsule a
  ## little darker than the window (lighter on a dark one).
  if r.w > 0 and r.h > 0:
    if matteLook():
      roundRect(r, float(dp(3)), mixColor(th.face, th.text, if onDark(): 0.30 else: 0.22))
      roundRect(inset(r, 1), float(dp(2)), th.face)
      return
    if glossLook():
      glassFace(r, radius = float(min(dp(6), r.h div 2)))
      return
    roundRect(r, float(r.h) / 2, mixColor(th.window, th.text, if onDark(): 0.12 else: 0.07))

proc softShadow*(r: Rect; radius: float; depth = 4) =
  ## Glass: the soft shadow of a surface floating over the window -- a menu, a dropped list, a
  ## dialog -- under `r`, `depth` pixels wide; drawn before the surface. (Matte: a faint one
  ## pixel; Gloss: deeper.)
  let dark = onDark()
  if matteLook():
    roundFrame(rect(r.x - 1, r.y, r.w + 2, r.h + 2), radius + 1, 2, withAlpha(black, if dark: 70 else: 26))
    return
  let depth = if glossLook(): depth + 2 else: depth
  for k in 0 ..< depth:
    let g = k + 1
    # (a band round each, as wide as it shows past the surface: the surface covers the rest, and
    # a frosted one does not blur its own shadow)
    roundFrame(rect(r.x - g + 1, r.y - g + 3, r.w + 2 * g - 2, r.h + 2 * g - 2), radius + float(g),
               float(g + 3), withAlpha(color(0, 0, 0), max(2, (if dark: 34 else: 12) - (if dark: 5 else: 2) * k)))

proc glassPlate*(r: Rect; radius: float; back = th.field; lift = 3) =
  ## Glass: a card standing over the window -- a group of rows, a floating tab bar, a pill of a
  ## button: a soft shadow round it (`lift` pixels wide), faintly blue on a light window; `back`
  ## in it, a hairline round it.
  if r.w <= 0 or r.h <= 0: return
  let dark = onDark()
  let tint = if dark: black else: color(34, 64, 128)
  for k in 0 ..< lift:
    let g = k + 1
    roundFrame(rect(r.x - g + 1, r.y - g + 2, r.w + 2 * g - 2, r.h + 2 * g - 2), radius + float(g),
               float(g + 2), withAlpha(tint, max(2, (if dark: 46 else: 12) - (if dark: 10 else: 3) * k)))
  roundRect(r, radius, if dark: mixColor(back, white, 0.09) else: mixColor(back, color(176, 190, 214), 0.45))
  roundRect(inset(r, 1), max(0.0, radius - 1), back)

proc glassBlue*(r: Rect; radius: float; pressed = false; c = Color(); glow = true) =
  ## Glass: a vivid face in the highlight (or `c`) -- the chosen row, the default button, the
  ## chosen segment: lit from above, a light line along its top, glowing on the window round it
  ## (`glow`; not while `pressed`).
  if r.w <= 0 or r.h <= 0: return
  let c = if c.a == 0: accentColor() else: c
  let base = if pressed: mixColor(c, black, 0.18) else: c
  if glow and not pressed:
    for k in 0 ..< 3:
      let g = k + 1
      roundFrame(rect(r.x - g, r.y - g + 2, r.w + 2 * g, r.h + 2 * g), radius + float(g),
                 float(g + 1), withAlpha(c, 40 - 12 * k))
  roundRectShaded(r, radius, mixColor(base, white, 0.24), mixColor(base, black, 0.12))
  let cut = int(radius * 0.8)
  if r.w > 2 * cut + 2 and r.h >= 6 and not pressed:
    hline(r.x + cut, r.y + 1, r.w - 2 * cut, withAlpha(white, 84))

proc glossMenuEdge*(): int =
  ## Gloss: how wide the dark frame round a popover, a menu, a dropped list is (0 in the other
  ## looks).
  if glossLook(): max(4, dp(6)) else: 0

proc glossPopoverFrame*(r: Rect; arrowX = -1; arrowUp = true) =
  ## Gloss: the dark frame of a popover round `r` -- as tablets had it then: in the scheme's
  ## hue (`glossTone`), lit at its top, the corners of `r` rounded off in it, an arrow at
  ## `arrowX` (up from its top, or down from its foot; -1: none). Drawn outside `r`: what is in
  ## `r` is the caller's, before or after.
  let edge = max(4, dp(6))
  let fr = inset(r, -edge)
  let rad = float(dp(10))
  let top = glossTone(0.385, 0.41)
  let foot = glossTone(0.65, 0.13)
  let line = glossTone(0.7, 0.08)
  for strip in [rect(fr.x, fr.y, fr.w, edge), rect(fr.x, r.y + r.h, fr.w, edge),
                rect(fr.x, r.y, edge, r.h), rect(r.x + r.w, r.y, edge, r.h)]:
    pushClip(strip)
    roundRect(fr, rad, line)
    roundRectShaded(inset(fr, 1), rad - 1, top, foot)
    popClip()
  hline(fr.x + int(rad), fr.y + 1, fr.w - 2 * int(rad), withAlpha(white, 80))
  # (the corners of `r` rounded: the frame's color outside a small arc in each)
  let cr = float(max(3, dp(5)))
  for (cx, cy, sx, sy) in [(r.x, r.y, 1, 1), (r.x + r.w, r.y, -1, 1), (r.x, r.y + r.h, 1, -1),
                           (r.x + r.w, r.y + r.h, -1, -1)]:
    var pts: seq[(float, float)]
    pts.add (float(cx), float(cy))
    for k in 0 .. 6:
      let a = PI / 2 * float(k) / 6
      pts.add (float(cx) + float(sx) * (cr - cr * cos(a)), float(cy) + float(sy) * (cr - cr * sin(a)))
    let t = clamp(float(cy - fr.y) / float(max(1, fr.h)), 0.0, 1.0)
    polygon(pts, mixColor(top, foot, t))
  if arrowX >= 0:
    let ah = max(6, dp(9))
    let ax = clamp(arrowX, fr.x + int(rad) + ah, fr.x + fr.w - int(rad) - ah)
    let at = if arrowUp: fr.y else: fr.y + fr.h - 1
    for k in 0 .. ah:
      let yy = if arrowUp: at - k else: at + k
      let half = ah - k
      hline(ax - half, yy, 2 * half + 1, if arrowUp: top else: foot)
      fill(rect(ax - half - 1, yy, 1, 1), line)
      fill(rect(ax + half + 1, yy, 1, 1), line)
proc frosted*(): bool {.inline.} = uiLook == lookGlass and glassLook() and frostedGlass
  ## Menus, dialogs and dropped lists drawn as frosted glass now (`frostedGlass`, in the Glass
  ## look).

proc frostAlpha(): uint8 = (if onDark(): 208 else: 196)
  ## (how much of a frosted face's color is over the blur)

proc frostedFace*(r: Rect; back: Color; corner = 0.0): bool {.discardable.} =
  ## A face of frosted glass in `r` when the look draws them so (`frosted`): what is under it
  ## blurred, `back` over it most of the way, its corners rounded `corner`; false -- nothing
  ## drawn -- otherwise.
  if not frosted(): return false
  backdropBlur(r, dp(16), withAlpha(back, int(frostAlpha())), corner)
  true

proc selectFill*(r: Rect) =
  ## The highlight behind a chosen row -- a menu's item, a list's, an open menu's title: the
  ## scheme's highlight color (Glass: a rounded pill of it, a little in from the row's ends).
  if matteLook():
    fill(r, th.select)
    return
  if glossLook():
    # (the blue of a chosen row, lighter at its top)
    if onDark(): roundRectShaded(r, 0, mixColor(th.select, white, 0.28), mixColor(th.select, black, 0.12))
    else: glossBlue(r)
    return
  if glassLook():
    # (lit from above: lighter at its top)
    let p = rect(r.x + dp(3), r.y + 1, r.w - 2 * dp(3), r.h - 2)
    if p.w > 0 and p.h > 0:
      roundRectShaded(p, float(min(dp(6), p.h div 2)), mixColor(th.select, white, 0.16),
                      mixColor(th.select, black, 0.06))
    return
  fill(r, th.select)

proc raisedFace*(f: Rect; bevel = 2) =
  ## The 3D edge of a raised face inside its black border: white at the
  ## top left (and, with `bevel` 2, a softer line inside it), gray at the
  ## bottom right -- the look of the Win31 desktop. (Glass: its light along the top only.)
  if glassLook():
    hline(f.x + 1, f.y, max(0, f.w - 2), withAlpha(color(255, 255, 255), if onDark(): 40 else: 170))
    return
  hline(f.x, f.y, f.w - 1, th.light)
  vline(f.x, f.y, f.h - 1, th.light)
  if bevel >= 2 and f.w > 4 and f.h > 4:
    hline(f.x + 1, f.y + 1, f.w - 3, softLight())
    vline(f.x + 1, f.y + 1, f.h - 3, softLight())
  hline(f.x, f.y + f.h - 1, f.w, th.shadow)
  vline(f.x + f.w - 1, f.y, f.h, th.shadow)

proc buttonFace*(r: Rect; pressed: bool; t = 1; rounded = true; bevel = 2;
                 hot = false; primary = false) =
  ## A push button's face: a black border, the gray face with its raised
  ## edge (`bevel` 2: two highlight lines, 1: one), or sunk in while
  ## `pressed`. `t` 2 adds the ring of the default button around it (one
  ## pixel apart, as the Win31 desktop draws it). `hot`: the mouse is over
  ## it (a little lighter). (`rounded` is kept for compatibility.) In the Glass look: a capsule
  ## of frosted glass (`glassFace`), the default button's ring in the highlight. Gloss on a light
  ## window: the button of its time (`glossButtonFace`) -- light gray, the default one
  ## (`primary`) blue, blue while pressed (its label in `buttonInk`); `t` 2 a glow round it.
  if buttonBold():
    glossButtonFace(r, pressed, primary, hot)
    if t >= 2 and not primary and not pressed:
      # (the keys on it: a line of the highlight inside its edge)
      roundFrame(inset(r, 1), float(max(0, min(dp(7), r.h div 2) - 1)), 2, withAlpha(accentColor(), 150))
    return
  if glossOnyx():
    # (Gloss Onyx: pills of black gloss -- the default one lit in the highlight --, a light line
    # under them on the window, lighter under the mouse)
    let rad = float(r.h) / 2
    roundRect(rect(r.x, r.y + 1, r.w, r.h), rad, withAlpha(white, 20))
    let base = if primary: accentColor() else: color(36, 37, 41)
    roundRect(r, rad, if primary: mixColor(base, black, 0.5) else: black)
    let f = inset(r, 1)
    if f.w > 0 and f.h > 0:
      glossShine(f, max(0.0, rad - 1), if pressed: mixColor(base, black, 0.35)
                                       elif hot: mixColor(base, white, 0.08) else: base, true)
    if t >= 2 and not primary and not pressed:
      roundFrame(inset(r, 1), max(0.0, rad - 1), 2, withAlpha(accentColor(), 170))
    return
  if glassLook():
    if primary and modernGlass():
      # (Glass's default button: the highlight's blue, glowing, its label white -- as Gloss's
      # is blue)
      glassBlue(r, glassRadius(r), pressed, c = if hot and not pressed: mixColor(accentColor(), white, 0.08)
                                               else: accentColor())
    elif t >= 2 and r.w > 6 and r.h > 6:
      glassFace(inset(r, 1), pressed, hot, ring = withAlpha(accentColor(), 200))
    else:
      glassFace(r, pressed, hot)
    return
  var b = r
  if t >= 2 and r.w > 6 and r.h > 6:
    box(r, th.frame)
    b = inset(r, 2)
  box(b, th.frame)
  let f = inset(b, 1)
  fill(f, if hot and not pressed: hotFace() else: th.face)
  if pressed:
    hline(f.x, f.y, f.w, th.shadow)
    vline(f.x, f.y, f.h, th.shadow)
  else:
    raisedFace(f, bevel)

proc fieldFrame*(r: Rect; enabled = true) =
  ## The frame of an edit field, list or other sunken area: a black border
  ## with a gray inner shadow at the top left. (Glass: a hairline, a soft shadow inside its top.)
  if glassLook():
    box(r, if enabled: mixColor(th.field, th.fieldText, 0.2) else: mixColor(th.field, th.gray, 0.4))
    if r.w > 4 and r.h > 4: hline(r.x + 1, r.y + 1, r.w - 2, withAlpha(color(0, 0, 0), if onDark(): 60 else: 18))
    return
  box(r, if enabled: th.edge else: th.gray)
  if r.w > 4 and r.h > 4:
    hline(r.x + 1, r.y + 1, r.w - 2, th.shadow)
    vline(r.x + 1, r.y + 1, r.h - 2, th.shadow)

proc fieldFace*(r: Rect; back: Color; enabled = true; focused = false; hot = false) =
  ## The face of a text box, a list or another field: `back` in its frame -- the 3.1 look's
  ## black border with its gray shadow inside; Glass: rounded, a hairline round it, a soft
  ## shadow inside its top, a ring in the highlight while it has the keyboard. `hot`: under
  ## the mouse -- Glass and Matte draw its line darker, as the systems of now do (3.1 and
  ## Gloss did not).
  if not glassLook():
    fill(r, back)
    fieldFrame(r, enabled)
    return
  if r.w <= 0 or r.h <= 0: return
  let dark = onDark()
  if matteLook():
    # (a box: a thin line round it, two of the highlight while it has the keyboard)
    let rad = float(dp(2))
    if focused and enabled:
      roundRect(r, rad, accentColor())
      roundRect(inset(r, 2), max(0.0, rad - 2), back)
    else:
      roundRect(r, rad, if enabled: mixColor(th.field, th.fieldText, if hot: (if dark: 0.55 else: 0.5)
                                                                     elif dark: 0.34 else: 0.3)
                        else: mixColor(th.field, th.gray, 0.4))
      roundRect(inset(r, 1), max(0.0, rad - 1), back)
    return
  if glossLook():
    # (rounded, cut in: shaded inside along its top; a glow of the highlight while it has the
    # keyboard)
    let rad = float(min(dp(6), r.h div 2))
    if focused and enabled:
      let a = accentColor()
      roundFrame(inset(r, -3), rad + 3, 2, withAlpha(a, 60))
      roundFrame(inset(r, -1), rad + 1, 1, withAlpha(a, 200))
    roundRect(r, rad, if enabled: mixColor(back, black, if dark: 0.5 else: 0.40) else: mixColor(th.field, th.gray, 0.4))
    let f = inset(r, 1)
    roundRect(f, max(0.0, rad - 1), back)
    let cut = int(rad * 0.6)
    if f.w > 2 * cut + 2:
      hline(f.x + cut, f.y, f.w - 2 * cut, withAlpha(black, if dark: 80 else: 40))
      hline(f.x + cut div 2, f.y + 1, f.w - cut, withAlpha(black, if dark: 40 else: 16))
    return
  let rad = float(min(dp(6), r.h div 2))
  if focused and enabled:
    # (the ring: two hairlines round it, the outer fainter -- outlines, not fills under it)
    let a = accentColor()
    roundFrame(inset(r, -2), rad + 2, 1, Color(r: a.r, g: a.g, b: a.b, a: 70))
    roundFrame(inset(r, -1), rad + 1, 1, Color(r: a.r, g: a.g, b: a.b, a: 186))
  roundRect(r, rad, if focused and enabled: mixColor(accentColor(), th.field, 0.2)
                    elif enabled and hot: mixColor(th.field, th.fieldText, if dark: 0.5 else: 0.42)
                    elif enabled: mixColor(th.field, th.fieldText, if dark: 0.3 else: 0.22)
                    else: mixColor(th.field, th.gray, 0.4))
  let f = inset(r, 1)
  roundRect(f, max(0.0, rad - 1), back)
  let cut = int(rad)
  if f.w > 2 * cut + 2:
    hline(f.x + cut, f.y, f.w - 2 * cut, withAlpha(color(0, 0, 0), if dark: 60 else: 16))

proc etchedBox*(r: Rect) =
  ## A group box's etched line: gray, with white one pixel down and right. (Glass: a hairline
  ## with rounded corners.)
  if glassLook():
    roundFrame(r, float(dp(10)), 1, glassHair())
    return
  box(rect(r.x + 1, r.y + 1, r.w - 1, r.h - 1), th.light)
  box(rect(r.x, r.y, r.w - 1, r.h - 1), th.line)

proc etchedLine*(x, y, w: int) =
  ## A horizontal etched separator. (Glass: a hairline.)
  if glassLook():
    hline(x, y, w, glassHair())
    return
  hline(x, y, w, th.line)
  hline(x, y + 1, w, th.light)

proc glossBar*(): Color =
  ## Gloss: the color of a title bar, a navigation bar, a tool bar -- the middle of its gradient
  ## (`glossBarColors`): steel blue, near black on a dark window.
  let (top, foot) = glossBarColors()
  mixColor(top, foot, 0.5)

proc titleColors*(active: bool): tuple[bg, fg: Color] =
  ## A title bar's colors: navy for the window in front, white for the
  ## others (`Theme.inactiveTitle`). (Glass: the window's face with its text, the others
  ## fainter: a bar of glass, not a band of color.)
  if active and mobileStyle.bar.a != 0:
    return (mobileStyle.bar, if mobileStyle.barText.a != 0: mobileStyle.barText
                             elif lumaOfColor(mobileStyle.bar) < 150: white else: color(0, 0, 0))
  if glossLook():
    return if active: (glossBar(), white) else: (mixColor(glossBar(), th.window, 0.55), mixColor(white, th.window, 0.3))
  if glassLook():
    return if active: (mixColor(th.window, th.face, 0.6), th.text)
           else: (th.window, mixColor(th.window, th.text, 0.55))
  if active: (th.select, th.selectText)
  else: ((if th.inactiveTitle.a != 0: th.inactiveTitle else: th.window),
         (if th.inactiveTitleText.a != 0: th.inactiveTitleText else: th.text))

proc statusBarColor*(): Color =
  ## What the app draws under the system's status bar over its own bars (`appNavBars`): the top
  ## bar's color, darker -- as iOS 6 tinted its status bar to the navigation bar --, so the
  ## system's icons stand on the scheme's colors (`MobileStyle.statusBar`: that color).
  if mobileStyle.statusBar.a != 0: mobileStyle.statusBar
  elif glossLook(): mixColor(glossBarColors().foot, black, 0.3)
  elif matteLook(): mixColor(titleColors(true).bg, black, 0.3)
  else: mixColor(titleColors(true).bg, black, 0.1)

proc titleBar*(r: Rect; active: bool) =
  ## A title bar's band in `r`, as the look draws it: one color (`titleColors`); Matte's with a
  ## line of the highlight under it; Gloss's a glossy bar of `glossBar`.
  let bg = titleColors(active).bg
  if glossLook():
    if active: glossBarFill(r)
    elif r.w > 0 and r.h > 0: roundRectShaded(r, 0, mixColor(bg, white, 0.3), bg)
    return
  fill(r, bg)
  if matteLook() and active and r.h > dp(6):
    fill(rect(r.x, r.y + r.h - dp(2), r.w, dp(2)), accentColor())

proc barFace*(r: Rect) =
  ## A tool bar's or a status bar's face in `r`: the scheme's face color; Gloss's lit from
  ## above, lighter at its top.
  if r.w <= 0 or r.h <= 0: return
  if glossLook():
    let dark = onDark()
    roundRectShaded(r, 0, mixColor(th.face, white, if dark: 0.08 else: 0.55),
                    mixColor(th.face, black, if dark: 0.22 else: 0.07))
  else:
    fill(r, th.face)

proc windowFrame*(r: Rect; border = 5) =
  ## A window's frame, `border` pixels wide: a black line, the gray band
  ## with its 3D edge, and the black line around the inside (the title bar
  ## and the client area go inside `inset(r, border)`). (Glass: the band in the window's color,
  ## a hairline round it.)
  if glassLook():
    let b = inset(r, 1)
    fill(rect(b.x, b.y, b.w, border - 1), th.window)
    fill(rect(b.x, b.y + b.h - border + 1, b.w, border - 1), th.window)
    fill(rect(b.x, b.y, border - 1, b.h), th.window)
    fill(rect(b.x + b.w - border + 1, b.y, border - 1, b.h), th.window)
    box(r, mixColor(th.window, th.text, 0.3))
    return
  let band = max(1, border - 2)
  box(r, th.frame)
  let b = inset(r, 1)
  fill(rect(b.x, b.y, b.w, band), th.face)
  fill(rect(b.x, b.y + b.h - band, b.w, band), th.face)
  fill(rect(b.x, b.y, band, b.h), th.face)
  fill(rect(b.x + b.w - band, b.y, band, b.h), th.face)
  hline(b.x, b.y, b.w - 1, th.light)
  vline(b.x, b.y, b.h - 1, th.light)
  hline(b.x, b.y + b.h - 1, b.w, th.shadow)
  vline(b.x + b.w - 1, b.y, b.h, th.shadow)
  box(inset(r, border - 1), th.frame)

proc captionButton*(r: Rect; pressed: bool) =
  ## A button of a title bar (the control-menu box, minimize, maximize):
  ## the gray face with its edge, sunk in while pressed. (Glass: a round button of glass.)
  if glassLook():
    let d = max(4, min(r.w, r.h) - 2)
    glassFace(rect(r.x + (r.w - d) div 2, r.y + (r.h - d) div 2, d, d), pressed, radius = float(d) / 2,
              shadow = false)
    return
  fill(r, th.face)
  if pressed:
    hline(r.x, r.y, r.w, th.shadow)
    vline(r.x, r.y, r.h, th.shadow)
    hline(r.x, r.y + r.h - 1, r.w, th.light)
    vline(r.x + r.w - 1, r.y, r.h, th.light)
  else:
    hline(r.x, r.y, r.w - 1, th.light)
    vline(r.x, r.y, r.h - 1, th.light)
    hline(r.x, r.y + r.h - 1, r.w, th.shadow)
    vline(r.x + r.w - 1, r.y, r.h, th.shadow)

proc controlMenuMark*(r: Rect; pressed = false) =
  ## The bar in the control-menu box: white, black-edged, with a gray
  ## shadow under it.
  let o = if pressed: 1 else: 0
  if glassLook():
    # (Glass: a short smooth bar)
    let w = float(max(dp(8), r.w * 2 div 5))
    let cx = float(r.x + o) + float(r.w) / 2
    let cy = float(r.y + o) + float(r.h) / 2
    thickLine(cx - w / 2, cy, cx + w / 2, cy, max(1.5, float(dp(2))), th.text)
    return
  let w = max(dp(13), r.w * 13 div 23)
  let h = max(5, dp(5))
  let x = r.x + (r.w - w) div 2 + o
  let y = r.y + (r.h - h) div 2 + o
  fill(rect(x, y, w, h), th.field)
  box(rect(x, y, w, h), th.frame)
  hline(x + 1, y + h, w, th.shadow)

proc ditherFill*(r: Rect; a, b: Color) =
  ## `r` in a checkerboard of `a` and `b` (a scroll bar's track).
  fill(r, a)
  if a != b: checker(r, b)

type Dir* = enum
  ## Where an `arrow` points.
  dUp, dDown, dLeft, dRight

proc hdDetail*(): bool {.inline.} =
  ## Small shapes (check marks, radio dots, arrows) drawn at the screen's
  ## own resolution: on HD screens, with smooth large text on (`setHdText`).
  hdText() and pxScale >= 2

proc arrow*(cx, cy: int; d: Dir; c: Color; n = 0) =
  ## A filled triangle centered on `cx`, `cy`, `n` pixels high (0: the
  ## normal size).
  let n = if n > 0: n else: dp(4)
  if hdDetail():
    # (the same triangle, its edges smooth at the screen's resolution)
    let a = float(cx) + 0.5
    let t = float(cy - n div 2)
    let b = t + float(n)
    let m = float(cy) + 0.5
    let l = float(cx - n div 2)
    let r = l + float(n)
    case d
    of dUp: polygon([(a, t), (a + float(n), b), (a - float(n), b)], c)
    of dDown: polygon([(a - float(n), t), (a + float(n), t), (a, b)], c)
    of dLeft: polygon([(l, m), (r, m - float(n)), (r, m + float(n))], c)
    of dRight: polygon([(l, m - float(n)), (r, m), (l, m + float(n))], c)
    return
  for i in 0 ..< n:
    let k = case d
      of dUp, dLeft: i
      of dDown, dRight: n - 1 - i
    case d
    of dUp, dDown: hline(cx - k, cy - n div 2 + i, 2*k + 1, c)
    of dLeft, dRight: vline(cx - n div 2 + i, cy - k, 2*k + 1, c)

proc captionArrow*(r: Rect; up: bool; pressed = false) =
  ## The triangle of a minimize (down) or maximize (up) button.
  let o = if pressed: 1 else: 0
  arrow(r.x + r.w div 2 + o, r.y + r.h div 2 + o, if up: dUp else: dDown, th.text,
        max(4, r.h * 7 div 23 + 1))

proc captionRestore*(r: Rect; pressed = false) =
  ## The two triangles of a restore button.
  let o = if pressed: 1 else: 0
  let n = max(3, r.h * 5 div 23 + 1)
  arrow(r.x + r.w div 2 + o, r.y + r.h div 2 - n div 2 - 1 + o, dUp, th.text, n)
  arrow(r.x + r.w div 2 + o, r.y + r.h div 2 + n div 2 + 1 + o, dDown, th.text, n)

type CaptionMark* = enum
  ## The mark on a title bar's button (`captionMark`).
  cmMinimize, cmMaximize, cmRestore, cmClose

proc captionMark*(r: Rect; mark: CaptionMark; pressed = false; enabled = true) =
  ## The mark on a title bar's button in `r`, in the style of
  ## `captionButtons`: Windows 95's _ □ (restore: two windows) X, or 3.1's
  ## triangles (3.1 had no close button: `cmClose` draws its X then too).
  ## `enabled` false: grayed.
  if captionButtons == cbWin31 and mark != cmClose:
    case mark
    of cmMinimize: captionArrow(r, false, pressed)
    of cmMaximize: captionArrow(r, true, pressed)
    else: captionRestore(r, pressed)
    return
  let o = if pressed: 1 else: 0
  if glassLook():
    # (Glass: fine smooth strokes, a little smaller)
    let c = if enabled: th.text else: mixColor(th.text, th.face, 0.55)
    let g = float(max(6, r.h * 2 div 5))
    let w = float(dp(3)) / 2
    let x0 = float(r.x + o) + (float(r.w) - g) / 2
    let y0 = float(r.y + o) + (float(r.h) - g) / 2
    case mark
    of cmMinimize: thickLine(x0, y0 + g / 2, x0 + g, y0 + g / 2, w, c)
    of cmMaximize: roundFrame(rect(int(x0), int(y0), int(g), int(g)), 2.0, w, c)
    of cmRestore:
      let s = int(g * 0.75)
      roundFrame(rect(int(x0 + g) - s, int(y0), s, s), 2.0, w, c)
      roundRect(rect(int(x0), int(y0 + g) - s, s, s), 2.0, th.face)
      roundFrame(rect(int(x0), int(y0 + g) - s, s, s), 2.0, w, c)
    of cmClose:
      thickLine(x0, y0, x0 + g, y0 + g, w, c)
      thickLine(x0 + g, y0, x0, y0 + g, w, c)
    return
  let g = max(7, r.h * 9 div 16)             # (the mark's square: 11 in a 20-pixel button)
  let t = max(2, (g + 3) div 7)              # (its strokes)
  let x = r.x + (r.w - g) div 2 + o
  let y = r.y + (r.h - g) div 2 + o
  let c = if enabled: th.text else: th.shadow
  case mark
  of cmMinimize:
    fill(rect(x + g div 6, y + g - t, g - g div 3, t), c)
  of cmMaximize:
    box(rect(x, y, g, g), c)
    fill(rect(x, y, g, t), c)
  of cmRestore:
    # (the window behind, and the one in front of it)
    let s = g * 3 div 4
    box(rect(x + g - s, y, s, s), c)
    fill(rect(x + g - s, y, s, t), c)
    fill(rect(x, y + g - s, s, s), th.face)
    box(rect(x, y + g - s, s, s), c)
    fill(rect(x, y + g - s, s, t), c)
  of cmClose:
    for k in 0 ..< t:
      line(x + k, y, x + g - t + k, y + g - 1, c)
      line(x + g - t + k, y, x + k, y + g - 1, c)

proc pattern*(x, y: int; rows: openArray[string]; keys: string;
             cols: openArray[Color]) =
  ## Pixel art: each character of `rows` is a pixel whose color is the
  ## entry of `cols` at that character's place in `keys`.
  for j, row in rows:
    var i = 0
    while i < row.len:
      let k = keys.find(row[i])
      var e = i + 1
      while e < row.len and row[e] == row[i]: inc e
      if k >= 0: hline(x + i, y + j, e - i, cols[k])
      i = e

const
  radioRing = [
    "....kkkk....", "..kkwwwwkk..", ".kwwwwwwwwk.", ".kwwwwwwwwk.",
    "kwwwwwwwwwwk", "kwwwwwwwwwwk", "kwwwwwwwwwwk", "kwwwwwwwwwwk",
    ".kwwwwwwwwk.", ".kwwwwwwwwk.", "..kkwwwwkk..", "....kkkk...."]
  radioDot = ["..kk..", ".kkkk.", "kkkkkk", "kkkkkk", ".kkkk.", "..kk.."]
  checkMark = ["......k", ".....kk", "k...kkk", "kk.kkk.", "kkkkk..",
               ".kkk...", "..k...."]

proc focusDots*(r: Rect) =
  ## The dotted rectangle around the widget with the keyboard focus. (Glass, Matte, Gloss: a
  ## soft ring in the highlight, shown only while the keyboard moves the focus -- Tab, the
  ## arrows --, as browsers do: a tap or a click takes the focus without it.)
  if glassLook():
    if not ui.focusCues: return
    let f = inset(r, -1)
    roundFrame(f, min(float(f.h) / 2, float(dp(8))), 2, Color(r: accentColor().r, g: accentColor().g,
                                                                b: accentColor().b, a: 120))
    return
  dots(r, th.text)

template itemTextY*(y: int): int = y + (ItemH - FontH) div 2
  ## Text in a list or menu row of `ItemH` pixels, centered.

template boxH*: int =
  ## Height of a check box or radio button row: a touch screen gets a
  ## finger-sized row around the same 13-pixel box.
  (if fingers(): CtrlH else: max(dp(13), FontH))

proc checkBox*(b: Rect; checked, down, enabled: bool; hot = false) =
  ## The square of a check box (pixel exact at 100%, drawn smooth when
  ## scaled). (Glass: rounded; ticked, the highlight with a white check mark.) `hot`: under
  ## the mouse -- the newer looks light it (3.1 did not).
  if glassLook():
    let rad = if matteLook(): float(max(1, dp(2))) else: max(2.0, float(b.w) / 4)
    if checked and enabled:
      glassAccent(b, rad)
      if hot and not down and not glossLook(): roundRect(b, rad, withAlpha(white, 46))
      let ink = accentInk()
      let (x0, y0) = (float(b.x), float(b.y))
      let w = float(b.w)
      let t = max(1.4, w / 8)
      thickLine(x0 + w * 0.24, y0 + w * 0.52, x0 + w * 0.43, y0 + w * 0.72, t, ink)
      thickLine(x0 + w * 0.41, y0 + w * 0.72, x0 + w * 0.78, y0 + w * 0.3, t, ink)
    else:
      glassWell(b, rad, if down: mixColor(th.field, th.select, 0.15)
                        elif hot and enabled and not glossLook(): mixColor(th.field, th.select, 0.08)
                        else: th.field)
      if checked:
        let (x0, y0) = (float(b.x), float(b.y))
        let w = float(b.w)
        let t = max(1.4, w / 8)
        thickLine(x0 + w * 0.24, y0 + w * 0.52, x0 + w * 0.43, y0 + w * 0.72, t, th.gray)
        thickLine(x0 + w * 0.41, y0 + w * 0.72, x0 + w * 0.78, y0 + w * 0.3, t, th.gray)
    return
  fill(b, th.field)
  box(b, if enabled: th.edge else: th.gray)
  if down: box(inset(b, 1), th.edge)
  if not checked: return
  let c = if enabled: th.fieldText else: th.gray
  if b.w == 13 and not hdDetail():
    for i in 0 ..< 11:
      fill(b.x + 1 + i, b.y + 1 + i, 1, 1, c)
      fill(b.x + 11 - i, b.y + 1 + i, 1, 1, c)
  else:
    let t = max(1.0, b.w / 12)
    let (x0, y0) = (float(b.x) + 1, float(b.y) + 1)
    let (x1, y1) = (float(b.x + b.w) - 1, float(b.y + b.h) - 1)
    pushClip(inset(b, 1))
    thickLine(x0, y0, x1, y1, t, c)
    thickLine(x1, y0, x0, y1, t, c)
    popClip()

proc radioDisc*(x, y, d: int; selected, down, enabled: bool; hot = false) =
  ## The circle of a radio button, `d` pixels across, top-left at `x`, `y`. (Glass: chosen, the
  ## highlight with a white dot.) `hot`: under the mouse -- the newer looks light it.
  if matteLook():
    # (a ring; chosen, the highlight's dot in it)
    let r = d / 2
    let (cx, cy) = (float(x) + r, float(y) + r)
    disc(cx, cy, r, if selected and enabled: accentColor()
                    elif hot and enabled: mixColor(th.field, th.fieldText, if onDark(): 0.6 else: 0.55)
                    else: mixColor(th.field, th.fieldText, if onDark(): 0.4 else: 0.32))
    disc(cx, cy, r - max(1.0, d / 10), if down: mixColor(th.field, th.select, 0.15)
                                       elif hot and enabled: mixColor(th.field, th.select, 0.06)
                                       else: th.field)
    if selected: disc(cx, cy, d / 4, if enabled: accentColor() else: th.gray)
    return
  if glassLook():
    let r = rect(x, y, d, d)
    if selected and enabled:
      glassAccent(r, float(d) / 2)
      if hot and not down and not glossLook(): roundRect(r, float(d) / 2, withAlpha(white, 46))
      disc(float(x) + d / 2, float(y) + d / 2, max(1.5, d / 6), accentInk())
    else:
      glassWell(r, float(d) / 2, if down: mixColor(th.field, th.select, 0.15)
                                 elif hot and enabled and not glossLook(): mixColor(th.field, th.select, 0.08)
                                 else: th.field)
      if selected: disc(float(x) + d / 2, float(y) + d / 2, max(1.5, d / 6), th.gray)
    return
  let k = if enabled: th.edge else: th.gray
  if d == 12 and not hdDetail():
    pattern(x, y, radioRing, "kw", [k, th.field])
    if down: pattern(x + 1, y + 1, ["..kkkkkk..", ".k......k.",
      "k........k", "k........k", "k........k", "k........k", "k........k",
      "k........k", ".k......k.", "..kkkkkk.."], "k", [k])
    if selected:
      pattern(x + 3, y + 3, radioDot, "k", [if enabled: th.fieldText else: th.gray])
  else:
    let r = d / 2
    let (cx, cy) = (float(x) + r, float(y) + r)
    disc(cx, cy, r, k)
    disc(cx, cy, r - max(1.0, d / 12), th.field)
    if down: ring(cx, cy, r - max(1.0, d / 12), max(1.0, d / 12), k)
    if selected:
      disc(cx, cy, d / 4, if enabled: th.fieldText else: th.gray)

# ---- shared behavior ---------------------------------------------------------

proc spaceKey*(id: Id; hit: var Hit) =
  ## Space presses a focused button and releases it as a click, as in 3.1.
  if hit.focused and canInput():
    # (Space alone: Alt+Space is the window's menu, Ctrl+Space the app's)
    if ui.key == KeySpace and not ui.keyUsed and
       ui.mods * {AltPressed, CtrlPressed, GuiPressed} == {}:
      ui.keyUsed = true
      ui.active = id
      ui.spaceDown = true
    elif ui.keyUp == KeySpace and ui.active == id and ui.spaceDown:
      hit.clicked = true
      ui.active = 0
      ui.spaceDown = false
  if ui.active == id and ui.spaceDown: hit.down = true

proc dropKey*(): bool =
  ## F4 or Alt+Down was pressed (and is taken): what drops a drop-down with
  ## the focus open, or closes it, as in Windows -- combo boxes, date
  ## pickers, menu buttons, a grid's drop-down cells. (Enter opens a closed
  ## one too; Alt+Up and Esc close an open one.)
  if canInput() and not ui.keyUsed and
     ((ui.key == KeyDown and AltPressed in ui.mods) or
      (ui.key == KeyF4 and ui.mods * {AltPressed, CtrlPressed, ShiftPressed, GuiPressed} == {})):
    ui.keyUsed = true
    result = true

proc mnemonicHit*(label: string): bool =
  ## Alt + the underlined letter.
  if ui.mnemonic != '\0' and not ui.keyUsed and canInput() and
     mnemonicOf(label) == ui.mnemonic:
    ui.keyUsed = true
    true
  else: false

proc doubleClicked*(): bool =
  ## The list, grid, tree or edit just drawn got a double click (or Enter
  ## in a list) this frame.
  ui.doubleClick and ui.doubleClickId == ui.lastId

proc tapped*(id: Id; hit: Hit): bool =
  ## Where a list-like widget picks its item: on the press with a mouse, on
  ## the release of a tap (that did not turn into a drag) with a finger --
  ## not a tap that only stopped a flicked list (`scrollCaught`).
  if accessPressed == id and hit.clicked: true    # (a screen reader pressed it)
  elif finger(): hit.clicked and not scrollCaught() else: ui.active == id and ui.pressed

proc tooltip*(text: string) =
  ## Show `text` when the mouse rests on the widget drawn last (never after
  ## a finger was lifted there).
  if text.len > 0 and canInput() and canHover() and mouseIn(ui.lastRect): ui.tip = text

# ---- static widgets ---------------------------------------------------------

proc wrapLines*(s: string; maxW: int; bold = false): seq[string]
  ## Word-wrap `s` to `maxW` pixels; a word longer than a line is broken.

proc scrubLabel*(s: string; v: var int; lo, hi: int; step = 1): bool {.discardable.} =
  ## A label that changes a number when dragged across: right more, left
  ## less (Shift: ten times as fast), as Photoshop's "scrubby sliders" --
  ## the field or slider beside it shows it. True when `v` changed.
  let w = labelWidth(s, false)
  let r = place(w, FontH + dp(4))
  let id = idOf("scrub:" & s)
  let hit = interact(id, r, focusable = false)
  var st = state(id)
  if hit.hover or ui.active == id: ui.cursor = curSizeWE
  if hit.down and ui.pressed:
    st.anchor = ui.mx
    st.caret = v
    ui.dragsActive = true
  if ui.active == id and ui.mouseDown and not ui.pressed:
    let k = if ShiftPressed in ui.mods: 10 * step else: step
    let nv = clamp(st.caret + (ui.mx - st.anchor) div max(1, dp(2)) * k, lo, hi)
    if nv != v:
      v = nv
      result = true
  state(id) = st
  drawLabel(r.x, r.y + (r.h - FontH) div 2, s, th.text)    # (in the app's language, as it was measured)
  if accessOn:
    # (read as the label it is, naming the field after it)
    accessLabelFor(s)
    accessNode(arLabel, s, id = 0, r = r)

template offWhen(enabled: bool): set[AccessState] =
  ## (a screen reader's state of a control that is grayed)
  (if enabled: {} else: {asDisabled})

proc label*(s: string; bold = false; color = Color(); enabled = true; literal = false) =
  ## Static text; '\n' starts a new line, '&' underlines the next letter
  ## (Alt + that letter moves the focus to the control after the label, as
  ## in a 3.1 dialog).
  ## Wider than the room it is in (a narrow dialog, a phone), it wraps, as
  ## a 3.1 static text does. In another language (`setUiLanguage`) the
  ## whole text is looked up before it wraps (glued from fixed parts and
  ## values -- `"Page " & $i & " of " & $n` -- those parts, see `tr`).
  ## `literal`: shown as it is -- a file's name: not translated, its '&'
  ## kept.
  ## Ending in ':', it names the field after it: in a row that wraps, the
  ## two go to the next line together (`keepWithNext`).
  if not literal and s.len > 1 and s[^1] == ':': keepWithNext()
  if '\n' notin s and (literal or uiLanguageCode() in ["", "en"]):
    # (one line, nothing to look up: when it fits, drawn as below, without
    # the text split into lines and copied every frame)
    let w1 = if literal: textWidth(s, bold) else: labelWidth(s, bold)
    let room1 = cellRoom()
    if not (w1 > room1 and room1 > dp(40)):
      let r = place(max(1, min(w1, max(room1, w1))), FontH)
      ui.lastId = 0
      ui.lastRect = r
      if accessOn:
        accessLabelFor(s)
        accessNode(arLabel, s, id = 0, r = r, states = offWhen(enabled))
      if enabled and not literal and '&' in s and mnemonicHit(s): focusNext()
      let c = if not enabled: th.gray elif color.a == 0: th.text else: color
      if literal: text(r.x, r.y, s, c, bold)
      else: drawLabel(r.x, r.y, s, c, bold)
      return
  var shown = s
  if not literal and uiLanguageCode() notin ["", "en"]:
    let plain = s.replace("&&", "\1").replace("&", "").replace("\1", "&")
    let t = tr(plain)
    if t != plain: shown = t
  var lines = shown.split('\n')
  var w = 0
  template width(line: string): int =
    (if literal: textWidth(line, bold) else: labelWidth(line, bold))
  for line in lines: w = max(w, width(line))
  let room = cellRoom()
  if w > room and room > dp(40):
    var wrapped: seq[string]
    for line in lines: wrapped.add wrapLines(line, room, bold)
    lines = wrapped
    w = 0
    for line in lines: w = max(w, width(line))
  # (an empty label is 1 pixel wide: 0 would ask for the whole row)
  let r = place(max(1, min(w, max(room, w))), lines.len * FontH)
  ui.lastId = 0
  ui.lastRect = r
  if accessOn:
    accessLabelFor(shown)
    accessNode(arLabel, shown, id = 0, r = r, states = offWhen(enabled))
  # Alt + its underlined letter: the control after it takes the focus
  if enabled and not literal and '&' in s and mnemonicHit(s): focusNext()
  let c = if not enabled: th.gray elif color.a == 0: th.text else: color
  var y = r.y
  for line in lines:
    if literal: text(r.x, y, line, c, bold)
    else: drawLabel(r.x, y, line, c, bold)
    y += FontH

proc wrapAscii(para: string; maxW: int; bold: bool; lines: var seq[string]) =
  ## (`wrapUncached` for a paragraph of plain ASCII: the same lines, each word measured once and
  ## the line's width carried on by `LineMeter` -- not the whole line measured again for every
  ## word -- and each line a piece of `para`, not a string grown word by word)
  let none = lineMeter(bold)
  proc widthOf(a, b: int): int =
    var m = none
    m.add para.toOpenArray(a, b - 1)
    m.width
  var line = none                       # the line so far: para[ls ..< le], its width `line`
  var ls, le = 0
  var ws = 0                            # each word: para[ws ..< we] (split at every space)
  while true:
    var we = para.find(' ', ws)
    if we < 0: we = para.len
    var startsLine = true
    if le > ls:
      var cand = line                   # the line, a space and the word
      cand.add " "
      cand.add para.toOpenArray(ws, we - 1)
      if cand.width > maxW:
        lines.add para[ls ..< le]
      else:
        (le, line, startsLine) = (we, cand, false)
    else:
      var word = none                   # (measured alone only when it is a line's first)
      word.add para.toOpenArray(ws, we - 1)
      if word.width <= maxW:
        (ls, le, line, startsLine) = (ws, we, word, false)
    if startsLine:
      # the word starts a line; broken while it is too wide -- after a "/" or "-" when there is
      # one (paths, names), else where it must
      var a = ws
      while widthOf(a, we) > maxW and we - a > 1:
        var lo = 1
        var hi = min(we - a - 1, max(1, maxW))
        while lo < hi:                  # the longest start that fits
          let mid = (lo + hi + 1) div 2
          if widthOf(a, a + mid) <= maxW: lo = mid
          else: hi = mid - 1
        var cut = -1
        for i in countdown(lo - 1, lo div 2):
          if para[a + i] in {'/', '\\', '-', '_', '.', ',', ';'}:
            cut = i
            break
        if cut > 0:
          lines.add para[a .. a + cut]
          a += cut + 1
        else:
          lines.add para[a ..< a + lo]
          a += lo
      ls = a
      le = we
      line = none
      line.add para.toOpenArray(a, we - 1)
    if we >= para.len: break
    ws = we + 1
  lines.add para[ls ..< le]

proc wrapUncached(s: string; maxW: int; bold: bool): seq[string] =
  let plain = lineMeter(bold).ok
  for para in s.split('\n'):
    if plain and plainAscii(para):
      wrapAscii(para, maxW, bold, result)  # (no right-to-left letters: no marks to add)
      continue
    let first = result.len
    var line = ""
    for w in para.split(' '):
      var word = w
      let cand = if line.len == 0: word else: line & " " & word
      if line.len > 0 and textWidth(cand, bold) > maxW:
        result.add line
        line = ""
      elif line.len > 0 or textWidth(word, bold) <= maxW:
        line = cand
        continue
      # `word` starts a line; break it while it is too wide -- after a
      # "/" or "-" when there is one (paths, names), else where it must
      while textWidth(word, bold) > maxW and word.runeLen > 1:
        var lo = 1
        var hi = min(word.runeLen - 1, max(1, maxW))   # (glyphs are 1 px or more)
        while lo < hi:                   # the longest start that fits
          let mid = (lo + hi + 1) div 2
          if textWidth(word.runeSubStr(0, mid), bold) <= maxW: lo = mid
          else: hi = mid - 1
        let head = word.runeSubStr(0, lo)
        var cut = -1
        for i in countdown(head.high, head.len div 2):
          if head[i] in {'/', '\\', '-', '_', '.', ',', ';'}:
            cut = i
            break
        if cut > 0:
          result.add head[0 .. cut]
          word = word[cut + 1 .. ^1]
        else:
          result.add head
          word = word.runeSubStr(lo)
      line = word
    result.add line
    # a line of the paragraph keeps its direction: an English paragraph's
    # line that starts with an Arabic word is still read from the left
    if result.len - first > 1:
      let rtl = textIsRtl(para)
      for i in first ..< result.len:
        if textIsRtl(result[i]) != rtl:
          result[i] = (if rtl: "\u200F" else: "\u200E") & result[i]

# Lists and icon views wrap the same names every frame: what was wrapped is
# kept (a thousand texts at most), and forgotten when the font changes.
var
  wrapMemo: Table[(string, int, bool), seq[string]]
  wrapFont: tuple[frame, w: int] = (-1, 0)

proc wrapLines*(s: string; maxW: int; bold = false): seq[string] =
  ## Word-wrap `s` to `maxW` pixels; a word longer than a line is broken.
  if wrapFont.frame != ui.frameNo:
    let w = textWidth("The quick brown fox, 0123456789!") +
            1000 * textWidth("Wide WM", true)
    if w != wrapFont.w: wrapMemo.clear()
    wrapFont = (ui.frameNo, w)
  let key = (s, maxW, bold)
  wrapMemo.withValue(key, v):
    return v[]
  result = wrapUncached(s, maxW, bold)
  if wrapMemo.len >= 1024: wrapMemo.clear()
  wrapMemo[key] = result

proc ellipsize*(s: string; maxW: int; st = TextStyle()): string =
  ## `s`, cut short with "..." to fit `maxW` pixels.
  if textWidth(s, st) <= maxW: return s
  let ell = "\u2026"
  # the longest start that fits with the "..."
  var lo = 0
  var hi = s.runeLen - 1
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    if textWidth(s.runeSubStr(0, mid) & ell, st) <= maxW: lo = mid
    else: hi = mid - 1
  result = s.runeSubStr(0, lo) & ell

proc paragraph*(s: string; w = 0; color = Color()) =
  ## Word-wrapped text as wide as the space it is in (or `w`).
  let maxW = if w > 0: w else: available()
  let lines = wrapLines(tr(s), maxW)
  let r = place(maxW, lines.len * FontH)
  ui.lastId = 0
  ui.lastRect = r
  if accessOn: accessNode(arLabel, tr(s), id = 0, r = r)
  let c = if color.a == 0: th.text else: color
  for i, line in lines: text(r.x, r.y + i * FontH, line, c)

proc separator*() =
  ## A horizontal etched line.
  let r = place(0, 2, fill = true)
  etchedLine(r.x, r.y, r.w)

proc image*(ic: Icon) =
  ## A picture at its own size.
  let r = place(ic.w, ic.h)
  ui.lastId = 0
  ui.lastRect = r
  image(r.x, r.y, ic)

proc canvas*(w, h: int): Rect =
  ## Room for your own drawing: draw into the returned rectangle with
  ## `fill`, `box`, `hline`, `vline`, `text` and `image`. `w` and `h` are
  ## pixels as they are (0 or less for `w`: all the width there is): give
  ## `dp(74)` for a size that follows the UI's scale, as a row's widths do
  ## by themselves.
  result = place(w, h, fill = w <= 0)
  ui.lastId = 0
  ui.lastRect = result

# ---- buttons ----------------------------------------------------------------

proc buttonWidth*(label: string): int =
  ## How wide `button(label)` is.
  max(dp(72), labelWidth(label, buttonBold()) + dp(24))

template dressed(accent: bool; st: TextStyle; body: untyped) =
  ## (`body` in the accent's colours and in the text style `st`)
  let dressedTheme = ui.theme
  if accent: ui.theme = accentTheme()
  try:
    withTextStyle(st):
      body
  finally:
    ui.theme = dressedTheme

proc styledH(h, plain, uiFontH: int): int {.inline.} =
  ## (a control's height: `h`, else its usual one grown by the text's)
  if h > 0: h else: plain + max(0, FontH - uiFontH)

proc pushButton(label: string; isDefault, enabled: bool; w, h, uiFontH: int): bool =
  let id = idOf(label)
  let bw = if w > 0: w else: buttonWidth(label)
  let r = place(bw, styledH(h, CtrlH, uiFontH))
  var hit = interact(id, r, enabled = enabled)
  if enabled:
    spaceKey(id, hit)
    if hit.focused:
      ui.takesEnter = true
      if keyHit(KeyEnter): hit.clicked = true
    elif isDefault and not ui.prevTakesEnter and keyHit(KeyEnter):
      hit.clicked = true
    if mnemonicHit(label): hit.clicked = true
  let thick = enabled and (hit.focused or (isDefault and not ui.prevTakesEnter))
  let primary = enabled and isDefault
  buttonFace(r, hit.down, if thick: 2 else: 1, hot = enabled and hovered(r), primary = primary)
  let bold = buttonBold()
  let tw = labelWidth(label, bold)
  let d = if hit.down and not bold: 1 else: 0
  let tx = r.x + (r.w - tw) div 2 + d
  let ty = r.y + (r.h - FontH) div 2 + d
  if not enabled and not bold: drawLabel(tx + 1, ty + 1, label, th.light, bold)   # embossed, as 3.1 grays text
  buttonLabel(tx, ty, label, buttonInk(hit.down, enabled, primary), bold)
  if hit.focused: focusDots(rect(tx - 2, ty - 1, tw + 4, FontH + 2))
  if accessOn:
    accessNode(arButton, label, id = id, r = r,
               states = (if isDefault: {asDefault} else: {}) + offWhen(enabled))
  hit.clicked

proc button*(label: string; isDefault = false; enabled = true;
             w = 0; accent = false; style = TextStyle(); h = 0): bool {.discardable.} =
  ## A push button; true when clicked. `isDefault` = Enter clicks it.
  ## `accent`: in the scheme's accent colours -- the button that matters
  ## most, one a window. `style`: its label's (`style(bold = true, size =
  ## 1.3)`): the button grows with it; `h`: its height, else by its text.
  let uiFontH = FontH
  dressed(accent, style):
    result = pushButton(label, isDefault, enabled, w, h, uiFontH)

proc buttonAt*(key: string; r: Rect; label: string; st = TextStyle(); enabled = true;
               down = false): bool {.discardable.} =
  ## A push button at `r` (for bars and overlays laid out by hand); true
  ## when clicked. `down` draws it held in (a toggle that is on).
  let hit = interact(idOf("btnat:" & key), r, focusable = false, enabled = enabled)
  if accessOn:
    accessNode(if down: arToggleButton else: arButton, label,
               states = (if down: {asPressed} else: {}) + offWhen(enabled))
  let pressed = down or hit.down
  buttonFace(r, pressed, 1, hot = enabled and hit.hover)
  let d = if pressed and not buttonBold(): 1 else: 0
  let tx = r.x + (r.w - textWidth(label, st)) div 2 + d
  let ty = r.y + (r.h - lineHeight(st)) div 2 + d
  let ink = buttonInk(pressed, enabled)
  if not enabled and not buttonBold(): text(tx + 1, ty + 1, label, th.light, st)
  elif buttonBold():
    if lumaOfColor(ink) >= 160: text(tx, ty - 1, label, withAlpha(black, 100), st)
    else: text(tx, ty + 1, label, withAlpha(white, 200), st)
  text(tx, ty, label, ink, st)
  hit.clicked

proc checkbox*(label: string; v: var bool; enabled = true): bool {.discardable.} =
  ## A check box bound to `v`; true when toggled.
  let id = idOf(v, label)
  let tw = labelWidth(label)
  let r = place(dp(19) + tw + 2, boxH)
  var hit = interact(id, r, enabled = enabled)
  if enabled:
    spaceKey(id, hit)
    if mnemonicHit(label): hit.clicked = true
  if hit.clicked:
    v = not v
    result = true
  let bs = dp(13)
  let b = rect(r.x, r.y + (r.h - bs) div 2, bs, bs)
  checkBox(b, v, hit.down, enabled, hot = enabled and hit.showsHover)
  let y0 = r.y + (r.h - FontH) div 2
  drawLabel(r.x + bs + dp(6), y0, label, if enabled: th.text else: th.gray)
  if hit.focused: focusDots(rect(r.x + bs + dp(4), y0 - 1, tw + 4, FontH + 2))
  if accessOn:
    accessNode(arCheckBox, label, id = id, r = r,
               states = (if v: {asChecked} else: {}) + offWhen(enabled))

type RadioGroup = object
  key: uint                            # the variable the options share
  ids, prevIds: seq[Id]                # its options this frame, and last frame
  values, prevValues: seq[int]

var radioGroups: tuple[frame: int; groups: seq[RadioGroup]]
  ## The radio buttons drawn this frame and the last, by group, for the
  ## arrow keys.

proc radioGroup(key: uint): int =
  if radioGroups.frame != ui.frameNo:
    radioGroups.frame = ui.frameNo
    # (last frame's options kept for the arrow keys; their seqs used again,
    # so a frame takes no memory for them)
    var n = 0
    for i in 0 ..< radioGroups.groups.len:
      if radioGroups.groups[i].ids.len > 0:    # (groups not drawn any more are forgotten)
        if n != i: swap(radioGroups.groups[n], radioGroups.groups[i])
        template g: untyped = radioGroups.groups[n]
        swap(g.prevIds, g.ids)
        swap(g.prevValues, g.values)
        g.ids.setLen(0)
        g.values.setLen(0)
        inc n
    radioGroups.groups.setLen(n)
  for i in 0 ..< radioGroups.groups.len:     # (by index: no copy of a group)
    if radioGroups.groups[i].key == key: return i
  radioGroups.groups.add RadioGroup(key: key)
  radioGroups.groups.high

proc radio*(label: string; v: var int; value: int;
            enabled = true; boxed = false): bool {.discardable.} =
  ## One option of a group: selected when `v == value`; true when chosen.
  ## The options sharing `v` are a group: the arrow keys move the choice
  ## (and the focus) between them, as in 3.1. `boxed`: an option button --
  ## the option in a box of its own as wide as its cell, all of it taking
  ## the click, the chosen one tinted with the highlight.
  let id = idOf(v, label)
  let gk = cast[uint](addr v)
  let tw = labelWidth(label)
  let whole = if boxed: place(dp(19) + tw + dp(22), boxH + dp(12), fill = true)
              else: place(dp(19) + tw + 2, boxH)
  # (the disc and the label: in the box, a little in from its left)
  let r = if boxed: rect(whole.x + dp(9), whole.y + (whole.h - boxH) div 2, whole.w - dp(12), boxH)
          else: whole
  let d = dp(12)
  var hit = interact(id, whole, enabled = enabled)
  let gi = radioGroup(gk)
  if enabled:
    radioGroups.groups[gi].ids.add id
    radioGroups.groups[gi].values.add value
  # the group's options as drawn last frame: where the arrows go
  template prevIds: untyped = radioGroups.groups[gi].prevIds
  template prevValues: untyped = radioGroups.groups[gi].prevValues
  if enabled:
    spaceKey(id, hit)
    if mnemonicHit(label): hit.clicked = true
    if hit.focused and canInput() and not ui.keyUsed and
       ui.key in {KeyUp, KeyDown, KeyLeft, KeyRight}:
      let at = prevIds.find(id)
      if at >= 0 and prevIds.len > 1:
        let d = if ui.key in {KeyUp, KeyLeft}: -1 else: 1
        let to = (at + d + prevIds.len) mod prevIds.len
        ui.focus = prevIds[to]
        ui.focusMoved = ui.frameNo
        ui.focusByKeys = true
        ui.focusCues = true
        if v != prevValues[to]:
          v = prevValues[to]
          result = true
        ui.keyUsed = true
        ui.redraw = true
  if hit.clicked and v != value:
    v = value
    result = true
  if boxed:
    let on = v == value
    let base = mixColor(th.face, th.light, 0.6)
    let bg = if on: mixColor(base, th.select, 0.25)
             elif enabled and hit.showsHover: mixColor(base, th.light, 0.5)
             else: base
    roundRect(whole, float(dp(4)), mixColor(bg, th.shadow, if on: 0.7 else: 0.5))
    roundRect(inset(whole, 1), float(dp(3)), bg)
  radioDisc(r.x, r.y + (r.h - d) div 2, d, v == value, hit.down, enabled, hot = enabled and hit.showsHover)
  let y0 = r.y + (r.h - FontH) div 2
  drawLabel(r.x + dp(19), y0, label, if enabled: th.text else: th.gray)
  if hit.focused: focusDots(rect(r.x + dp(17), y0 - 1, tw + 4, FontH + 2))
  if accessOn:
    let k = accessNode(arRadioButton, label, id = id, r = whole,
                       states = (if v == value: {asChecked} else: {}) + offWhen(enabled))
    let at = radioGroups.groups[gi].ids.find(id)
    accessItem(k, at + 1, max(at + 1, radioGroups.groups[gi].prevIds.len))

# ---- scroll bars --------------------------------------------------------------

proc scrollbarAt*(id: Id; r: Rect; vert: bool; v: var int; lo, hi, page: int;
                  enabled = true; step = 1): bool =
  ## A scroll bar at `r` (for widgets that scroll their own content): its
  ## arrows move `v` by `step`, a click on the track by `page`, the thumb
  ## drags it (see `scrollBarFor` for one that glides).
  let a = if vert: r.w else: r.h
  let len = if vert: r.h else: r.w
  let span = max(1, hi - lo)
  let track = len - 2 * a
  let can = enabled and hi > lo and track > 0
  let thumbOn = can and track >= a
  let pos = if thumbOn: (clamp(v, lo, hi) - lo) * (track - a) div span else: 0
  # (a template, not a nested proc: that would be a closure made anew
  # every frame)
  template part(o, n: int): Rect =
    (if vert: rect(r.x, r.y + o, r.w, n) else: rect(r.x + o, r.y, n, r.h))
  let a1 = part(0, a)
  let a2 = part(len - a, a)
  let thumb = part(a + pos, a)
  let before = part(a, pos)
  let after = part(a + pos + a, max(0, track - pos - a))
  let ids = [id + 1, id + 2, id + 3, id + 4, id + 5]
  let rects = [a1, a2, before, after, thumb]
  let steps = [-max(1, step), max(1, step), -max(1, page), max(1, page), 0]
  var nv = v
  if can and canInput():
    for i in 0 .. 4:
      if hover(rects[i]) and takePress():
        ui.active = ids[i]
        ui.dragsActive = true
        if i == 4:
          grab = (if vert: ui.my - thumb.y else: ui.mx - thumb.x)
        else:
          nv += steps[i]
          repeatAt = ui.now + 400
    for i in 0 .. 3:
      if ui.active == ids[i] and ui.mouseDown and not ui.pressed:
        if ui.now >= repeatAt:
          if mouseIn(rects[i]): nv += steps[i]
          repeatAt = ui.now + 50
        wakeIn(repeatAt - ui.now)
    if ui.active == ids[4] and ui.mouseDown and track > a:
      let m = (if vert: ui.my - r.y else: ui.mx - r.x) - grab - a
      nv = lo + (m * span + (track - a) div 2) div (track - a)
  nv = clamp(nv, lo, max(lo, hi))
  if nv != v:
    v = nv
    result = true
  # draw: the track dithered white and gray, its arrow buttons and the
  # thumb as raised faces in black borders (Glass: a plain track, the arrows
  # alone, a slim rounded thumb)
  if glassLook():
    fill(r, mixColor(th.window, th.scroll, 0.6))
    let ac = if can: mixColor(th.window, th.text, 0.5) else: mixColor(th.window, th.text, 0.22)
    for i, d in [(if vert: dUp else: dLeft), (if vert: dDown else: dRight)]:
      let pr = ui.active == ids[i] and ui.mouseDown and mouseIn(rects[i])
      if pr or (can and hovered(rects[i])):
        let c = min(rects[i].w, rects[i].h) - 4
        roundRect(rect(rects[i].x + (rects[i].w - c) div 2, rects[i].y + (rects[i].h - c) div 2, c, c),
                  float(c) / 2, withAlpha(th.text, if pr: 46 else: 22))
      arrow(rects[i].x + rects[i].w div 2, rects[i].y + rects[i].h div 2, d, ac, max(3, dp(3)))
    if thumbOn:
      let hot = hovered(thumb) or ui.active == ids[4]
      let slim = max(4, a * (if hot: 9 else: 6) div 16)
      let tr = if vert: rect(thumb.x + (thumb.w - slim) div 2, thumb.y + 2, slim, max(2, thumb.h - 4))
               else: rect(thumb.x + 2, thumb.y + (thumb.h - slim) div 2, max(2, thumb.w - 4), slim)
      roundRect(tr, float(slim) / 2, withAlpha(th.text, if hot: 120 else: 80))
    return
  ditherFill(r, th.scroll, th.light)
  box(r, th.frame)
  for i in 2 .. 3:
    if ui.active == ids[i] and ui.mouseDown and mouseIn(rects[i]):
      fill(inset(rects[i], 1), th.shadow)
  let ac = if can: th.frame else: th.gray
  for i, d in [(if vert: dUp else: dLeft), (if vert: dDown else: dRight)]:
    let pr = ui.active == ids[i] and ui.mouseDown and mouseIn(rects[i])
    buttonFace(rects[i], pr, bevel = 1, hot = can and hovered(rects[i]))
    let o = if pr: 1 else: 0
    arrow(rects[i].x + rects[i].w div 2 + o, rects[i].y + rects[i].h div 2 + o,
          d, ac)
  if thumbOn:
    buttonFace(thumb, false, bevel = 1,
               hot = hovered(thumb) or ui.active == ids[4])

proc scrollBarFor*(barId, id: Id; r: Rect; vert: bool; v: var int; hi, page, step: int;
                   enabled = true): bool {.discardable.} =
  ## The standard scroll bar at `r` of the scroller `id` (see `scrollTo`),
  ## for a position `v` in pixels (0 .. `hi`): the thumb drags it pixel by
  ## pixel, the arrows (`step`) and a click on the track (`page`) glide.
  var nv = v
  if scrollbarAt(barId, r, vert, nv, 0, max(0, hi), page, enabled, step):
    if ui.active == barId + 5 or not smoothScrolling:   # the thumb
      scrollStop(id)
      v = nv
    else:
      scrollBy(id, v, nv - v, hi)
    result = true

pageBar = proc (view: Rect; v: var int; hi: int): bool {.nimcall.} =
  scrollBarFor(Id(0x9a6e5c11'u32), Id(0x9a6e5c90'u32), view, true, v, hi,
               max(ItemH, view.h - 2 * ItemH), ItemH)
pageBarX = proc (view: Rect; v: var int; hi: int): bool {.nimcall.} =
  scrollBarFor(Id(0x9a6e5c51'u32), Id(0x9a6e5c91'u32), view, false, v, hi,
               max(ItemH, view.w - 2 * ItemH), ItemH)

proc wheelOn(r: Rect; v: var int; lo, hi, step: int; enabled: bool): bool =
  ## The wheel over `r` moves `v` by `step` a notch.
  if enabled and canInput() and mouseIn(r) and ui.wheel != 0 and not ui.wheelUsed:
    ui.wheelUsed = true
    let nv = clamp(v - ui.wheel * step, lo, max(lo, hi))
    if nv != v:
      v = nv
      result = true

proc vscroll*(v: var int; lo, hi: int; page = 1; h = 0;
              enabled = true): bool {.discardable.} =
  ## A vertical scroll bar bound to `v` in `lo..hi`; `page` is how far a
  ## click on the track moves it. The wheel over it moves it too.
  let r = place(SbW, if h > 0: h else: 100)
  let id = idOf(v, "vs")
  result = wheelOn(r, v, lo, hi, max(1, page div 3), enabled)
  if scrollbarAt(id, r, true, v, lo, hi, page, enabled): result = true
  ui.lastId = id
  ui.lastRect = r

proc hscroll*(v: var int; lo, hi: int; page = 1; w = 0;
              enabled = true): bool {.discardable.} =
  ## A horizontal scroll bar bound to `v` in `lo..hi` (`w` 0: as wide as
  ## the room). The wheel over it moves it too.
  let r = place(if w > 0: w else: 0, SbW, fill = w <= 0)
  let id = idOf(v, "hs")
  result = wheelOn(r, v, lo, hi, max(1, page div 3), enabled)
  if scrollbarAt(id, r, false, v, lo, hi, page, enabled): result = true
  ui.lastId = id
  ui.lastRect = r

# ---- edit ---------------------------------------------------------------------

proc runeBefore(s: string; i: int): int =
  var j = i - 1
  while j > 0 and (s[j].uint8 and 0xC0) == 0x80: dec j
  max(0, j)

proc runeAfter(s: string; i: int): int =
  if i >= s.len: return s.len
  var j = i + 1
  while j < s.len and (s[j].uint8 and 0xC0) == 0x80: inc j
  j

proc lineEnd(s: string; i: int): int =
  result = i
  while result < s.len and s[result] != '\n': inc result

proc cpAt(s: string; i: int): int =
  ## (the character starting at byte `i`; -1 past the end)
  if i >= s.len: -1 else: int(unicode.runeAt(s, i))

proc extends(cp: int): bool {.inline.} =
  ## (a character that belongs to the one before it: a mark -- an Arabic
  ## vowel, an accent --, a joiner or non-joiner)
  cp >= 0x300 and (isMark(cp) or cp == 0x200C or cp == 0x200D)

proc clusterAfter*(s: string; i: int): int =
  ## The caret's next stop after byte `i`: a letter and the marks on it
  ## are one step (the caret never stands between them).
  result = runeAfter(s, i)
  while result < s.len and extends(cpAt(s, result)): result = runeAfter(s, result)

proc clusterBefore*(s: string; i: int): int =
  ## The caret's stop before byte `i` (see `clusterAfter`).
  result = runeBefore(s, i)
  while result > 0 and extends(cpAt(s, result)): result = runeBefore(s, result)

proc wordChar(c: char): bool = c.isAlphaNumeric or c == '_' or c.uint8 >= 0x80

proc wordLeft(s: string; i: int): int =
  result = i
  while result > 0 and not wordChar(s[result - 1]): dec result
  while result > 0 and wordChar(s[result - 1]): dec result

proc wordRight(s: string; i: int): int =
  result = i
  while result < s.len and wordChar(s[result]): inc result
  while result < s.len and not wordChar(s[result]) and s[result] != '\n':
    inc result

proc shownInto(t: var string; s: string; a, b: int; pass: bool) =
  ## Shown line `a ..< b` into `t` (its room kept from frame to frame: a
  ## frame takes no memory for it).
  if not pass:
    t.setLen(b - a)
    if b > a: copyMem(addr t[0], unsafeAddr s[a], b - a)
    return
  t.setLen(0)
  var i = a
  while i < b:
    t.add '*'
    i = runeAfter(s, i)

var shownBuf, lineBuf: string   # (the text being shown, measured or drawn)

template shown(s: string; a, b: int; pass: bool): string =
  ## What `s[a ..< b]` shows (stars for a password), in a buffer used again
  ## (taken as it is, at once: the next `shown` changes it).
  shownInto(shownBuf, s, a, b, pass)
  shownBuf

proc indexAt(s: string; a, b, x: int; pass: bool): int =
  ## The character boundary in `s[a..<b]` nearest to `x` pixels.
  var i = a
  var px = 0
  while i < b:
    let j = runeAfter(s, i)
    let cw = textWidth(shown(s, i, j, pass))
    if x < px + cw div 2: return i
    px += cw
    i = j
  b

type VLine = tuple[a, b: int; soft: bool]
  ## A line as shown in a multi-line text box: bytes `a ..< b` of the
  ## text; `soft` when it was wrapped (the next one goes on at `b`).

var wrapCache: Table[Id, tuple[text: string; w: int; look: Hash; lines: seq[VLine]]]
  ## (the text kept as it was wrapped: a change is found by comparing, and
  ## only the lines of the text it touched are wrapped again)

proc wrapInto(s: string; w: int; first, last: int; res: var seq[VLine]) =
  ## The lines as shown (`visualLines`) of the text's lines from the one
  ## starting at byte `first` to the one holding byte `last`, added to `res`.
  # (each character measured once: its width alone is what wrapping adds up)
  var asciiW: array[128, int32]           # width + 1; 0: not measured yet
  var otherW: Table[int, int32]
  var a = first
  while true:
    let e = lineEnd(s, a)
    if w <= 0:
      res.add (a, e, false)
    else:
      var segA = a
      var i = a
      var x = 0
      var lastBreak = -1
      while i < e:
        let j = runeAfter(s, i)
        var cw: int
        if j == i + 1 and ord(s[i]) < 128:
          let k = ord(s[i])
          if asciiW[k] == 0: asciiW[k] = int32(textWidth(s[i ..< j])) + 1
          cw = int(asciiW[k]) - 1
        elif j - i <= 4:
          var key = 0
          for p in i ..< j: key = (key shl 8) or ord(s[p])
          otherW.withValue(key, v):
            cw = int(v[])
          do:
            cw = textWidth(s[i ..< j])
            otherW[key] = int32(cw)
        else:
          cw = textWidth(s[i ..< j])
        if x + cw > w and i > segA and s[i] != ' ':
          let cut = if lastBreak > segA: lastBreak else: i
          res.add (segA, cut, true)
          segA = cut
          i = cut
          x = 0
          lastBreak = -1
        else:
          x += cw
          if s[i] == ' ': lastBreak = j
          i = j
      res.add (segA, e, false)
    if e >= s.len or e >= last: break
    a = e + 1

proc visualLines(s: string; w: int): seq[VLine] =
  ## The lines of `s` as shown: one per line of the text, or (`w` > 0)
  ## word-wrapped to `w` pixels -- after a space where there is one, else
  ## where the line is full.
  wrapInto(s, w, 0, s.len, result)

proc wrapLook(): Hash =
  ## (what the characters' widths depend on: the font, its size, the scale)
  !$(hashF(textSize()) !& ord(uiFont()) !& pxScale !& ord(hdText()) !& FontH !&
     textWidth("Wide words wrap: 0123456789, mm ii"))

proc samePrefix(a, b: string): int =
  ## How many bytes `a` and `b` start with alike.
  let m = min(a.len, b.len)
  const Chunk = 256
  while result + Chunk <= m and equalMem(unsafeAddr a[result], unsafeAddr b[result], Chunk):
    result += Chunk
  while result < m and a[result] == b[result]: inc result

proc sameSuffix(a, b: string; most: int): int =
  ## How many bytes `a` and `b` end with alike (`most` at most).
  const Chunk = 256
  while result + Chunk <= most and
        equalMem(unsafeAddr a[a.len - result - Chunk], unsafeAddr b[b.len - result - Chunk], Chunk):
    result += Chunk
  while result < most and a[a.len - 1 - result] == b[b.len - 1 - result]: inc result

proc linesOf(id: Id; s: string; w: int): seq[VLine] =
  ## `visualLines`, remembered while the text, the width and the font stay;
  ## when the text changed, only the lines of it the change touched are
  ## wrapped again (typing in a long text costs what its line costs).
  let look = wrapLook()
  wrapCache.withValue(id, c):
    if c.w == w and c.look == look:
      if c.text == s: return c.lines
      let o = c.text.len
      let n = s.len
      let p = samePrefix(c.text, s)
      let q = sameSuffix(c.text, s, min(o, n) - p)
      # the text's lines from the one the change starts in to the one it
      # ends in are wrapped again; those before stay, those after move
      var hs = p
      while hs > 0 and s[hs - 1] != '\n': dec hs
      let heOld = lineEnd(c.text, o - q)
      let heNew = lineEnd(s, n - q)
      template firstFrom(lo0: int; past: untyped): int =
        # (the first shown line starting past where it is said: they are in order)
        var lo = lo0
        var hi = c.lines.len
        while lo < hi:
          let m = (lo + hi) shr 1
          let a {.inject.} = c.lines[m].a
          if past: hi = m else: lo = m + 1
        lo
      let k0 = firstFrom(0, a >= hs)
      let k1 = firstFrom(k0, a > heOld)
      var lines = newSeqOfCap[VLine](c.lines.len + 8)
      for k in 0 ..< k0: lines.add c.lines[k]
      wrapInto(s, w, hs, heNew, lines)
      let d = n - o
      for k in k1 ..< c.lines.len:
        lines.add (c.lines[k].a + d, c.lines[k].b + d, c.lines[k].soft)
      c.text = s
      c.lines = lines
      return lines
  result = visualLines(s, w)
  if wrapCache.len > 64: wrapCache.clear()
  wrapCache[id] = (s, w, look, result)

var editLines: seq[VLine]   # (the lines of the text box being drawn)

proc runeLenOf(s: string; b: int): int =
  ## The characters (not bytes) in `s[0 ..< b]`.
  var i = 0
  while i < b:
    i += max(1, runeLenAt(s, i))
    inc result

proc typedText(t: string; multi: bool; allowed: set[char]): string =
  ## What of `t` goes into a text box: no CR, no new line in a one-line
  ## box, only the `allowed` characters (when any are given).
  for c in plainLetters(t):
    if c == '\r': continue
    if c == '\n' and not multi: continue
    if allowed != {} and c notin allowed: continue
    result.add c

proc shownLines(dst: var seq[VLine]; id: Id; s: string; w: int; multi: bool) =
  ## The lines a text box shows, into `dst` (its room kept from frame to
  ## frame: a frame takes no memory for them).
  if not multi:
    dst.setLen(1)
    dst[0] = (0, s.len, false)
    return
  let look = wrapLook()
  var hit = false
  wrapCache.withValue(id, c):
    if c.w == w and c.look == look and c.text == s:
      dst.setLen(c.lines.len)
      for i in 0 ..< c.lines.len: dst[i] = c.lines[i]
      hit = true
  if not hit:
    let l = linesOf(id, s, w)
    dst.setLen(l.len)
    for i in 0 ..< l.len: dst[i] = l[i]

proc lineOf(vl: seq[VLine]; i: int): int =
  ## The shown line the caret at byte `i` is on.
  var lo = 0
  var hi = vl.high
  while lo < hi:
    let m = (lo + hi + 1) shr 1
    if vl[m].a <= i: lo = m else: hi = m - 1
  lo

proc onLine(s: string; vl: seq[VLine]; k, x: int; pass: bool): int =
  ## The character boundary nearest to `x` on shown line `k` (a wrapped
  ## line ends before its last character: its end starts the next one).
  result = indexAt(s, vl[k].a, vl[k].b, x, pass)
  if vl[k].soft and result >= vl[k].b and vl[k].b > vl[k].a: result = runeBefore(s, vl[k].b)

type
  DirRun = tuple[a, b, x, w: int; rtl: bool]
    ## (a piece of a shown line in one direction: bytes `a ..< b` of the
    ## text, `x` pixels from the line's left, `w` wide)
  LineGeo = tuple[rtl: bool; w, left: int; runs: seq[DirRun]]
    ## (`runs`: a line that mixes directions -- Arabic with Latin words or
    ## numbers in it -- in its pieces as shown; empty for one direction)

proc partW(s: string; a, i: int): int =
  ## Width of bytes `a ..< i`, the letter before `i` joined as it is in the
  ## whole word (a zero width joiner after it).
  if i <= a: 0
  elif joinsAt(s, i): textWidth(s[a ..< i] & "\u200D")
  else: textWidth(s[a ..< i])

proc lineRtl(t: string; pass: bool): bool =
  ## (a shown line of a text box reads right to left: drawn so; in a
  ## right-to-left interface a line with no letters -- an empty one -- too)
  not pass and (shownRtl(t) or (ui.rtl and strongDir(t) < 0))

proc lineGeo(s: string; a, b: int; pass: bool; tx, avail: int; runs = true): LineGeo =
  ## How shown line `a ..< b` sits in a text box whose text starts at `tx`:
  ## a right-to-left one (Arabic) at the right edge when it fits. `runs`:
  ## its pieces in each direction too (for its caret and selection).
  shownInto(lineBuf, s, a, b, pass)
  template t: untyped = lineBuf
  result.rtl = lineRtl(t, pass)
  result.w = textWidth(t)
  result.left = if result.rtl and result.w < avail: tx + avail - result.w else: tx
  if pass or not runs or t.len == 0: return
  var high = false
  for c in t:
    if c.uint8 >= 0xD6: high = true            # (U+0580 on: Hebrew, Arabic and the rest)
  if not high and not result.rtl: return
  let info = bidiInfo(t, ord(result.rtl))
  var lv: seq[int8]
  var i = 0
  var ri = 0
  while i < t.len and ri < info.levels.len:
    let l = info.levels[ri]
    var j = i
    while j < t.len and ri < info.levels.len and info.levels[ri] == l:
      j = runeAfter(t, j)
      inc ri
    result.runs.add (a: a + i, b: a + j, x: 0, w: partW(t, i, j), rtl: (l and 1) == 1)
    lv.add l
    i = j
  if result.runs.len == 1 and result.runs[0].rtl == result.rtl:
    result.runs.setLen(0)                      # (one direction: as plain text)
    return
  var x = 0
  for o in visualOrderOf(lv):
    result.runs[o].x = x
    x += result.runs[o].w

proc vxOf(s: string; a, i: int; pass: bool; g: LineGeo): int =
  ## Where the caret at byte `i` of the line starting at `a` is, from the
  ## line's left end (from its right end the text goes on, right to left).
  ## In a line of both directions: just after the character before it --
  ## where the next one typed goes --, the line's start before its first.
  if g.runs.len > 0:
    var k = 0
    if i > g.runs[0].a:
      while k < g.runs.high and g.runs[k].b < i: inc k
    let r = g.runs[k]
    let w = partW(s, r.a, clamp(i, r.a, r.b))
    return if r.rtl: r.x + r.w - w else: r.x + w
  let w = if pass: textWidth(shown(s, a, i, pass)) else: partW(s, a, i)
  if g.rtl: g.w - w else: w

proc hitOf(s: string; vl: seq[VLine]; k, vx: int; pass: bool; g: LineGeo): int =
  ## The character boundary of shown line `k` nearest to `vx` from its left end.
  if g.runs.len == 0:
    return onLine(s, vl, k, (if g.rtl: g.w - vx else: vx), pass)
  var bestD = high(int)
  for r in g.runs:
    var o = r.a
    while true:
      let w = partW(s, r.a, o)
      let d = abs((if r.rtl: r.x + r.w - w else: r.x + w) - vx)
      if d < bestD:
        bestD = d
        result = o
      if o >= r.b: break
      o = min(r.b, clusterAfter(s, o))
  if vl[k].soft and result >= vl[k].b and vl[k].b > vl[k].a: result = runeBefore(s, vl[k].b)

# (the menus come later in this file; a text box has one)
proc openPopupMenu*(key: string; x, y: int)
  ## Opens the menu `key` with its top left at `x`, `y` (under a button
  ## that drops it down); draw it with `popupMenu(key)`.
proc beginPopupMenuFor*(key: string): bool
  ## The menu `key` opened with `openPopupMenu` (see `popupMenu`): true while
  ## it is open.
proc menuItem*(label: string; shortcut = ""; checked = false; enabled = true): bool
  ## An item of the open menu; true when chosen.
proc menuSeparator*()
  ## A line between groups of menu items.
proc endMenu*()
  ## Ends an open menu (`beginMenu`, `beginSubmenu`, `beginContextMenu`,
  ## `beginPopupMenuFor`): draws its frame; Up, Down, Home, End, Esc.

var tapFocus: Id
  ## A text box a finger landed on: it takes the focus (and the on-screen
  ## keyboard comes up) when the finger is lifted without scrolling.

proc editAt*(id: Id; s: var string; r: Rect; multi, pass, enabled: bool;
             allowed: set[char] = {}; right = false; frameless = false;
             wrap = false; readOnly = false; invalid = false): bool =
  ## A text box at `r` (for widgets made of one: spin, number fields...).
  ## `allowed` limits the characters typed, `right` aligns the text right,
  ## `frameless` leaves out the border (the widget around draws one),
  ## `wrap` (several lines) wraps long lines at the words, `readOnly`: the
  ## text is selected, copied and scrolled through, not changed.
  ## `invalid`: what is typed is not right yet (a date that is none): the
  ## box is red until it is.
  ## Its menu (a right click, a long press): Cut, Copy, Paste, Delete,
  ## Select all. In a right-to-left interface its text keeps its own
  ## direction (a line of Arabic at the right, of Latin at the left, an
  ## empty box's caret at the right), not mirrored with the frame.
  # (the keyboard asked for it -- `textKeyboard` --, taken by this box alone)
  let kb = ui.nextKeyboard
  ui.nextKeyboard.set = false
  var st: WState
  swap(st, state(id))         # (taken out and put back: no copy of its text)
  let barW = if multi: SbW else: 0
  let area = rect(r.x, r.y, r.w - barW, r.h)
  let inner = inset(area, 1)
  var tx = inner.x + 2
  if right and not multi:
    tx += max(0, inner.w - 6 - textWidth(shown(s, 0, s.len, pass)))
  let visLines = max(1, (inner.h - 2) div FontH)
  let ty = if multi: inner.y + 1 else: inner.y + (inner.h - FontH) div 2
  var changed = false
  var moved = false
  # the lines as shown (wrapped, or one per line of the text)
  let wrapW = if multi and wrap and not pass: max(FontH, inner.w - 6) else: 0
  shownLines(editLines, id, s, wrapW, multi)
  template vl: untyped = editLines
  if wrapW > 0: st.scrollX = 0
  # The scroll bar of a multi-line edit comes first: it is on top. (Its
  # lines scroll by the pixel: `st.scrollY`.)
  let viewH = inner.h - 2
  let maxOff = if multi: max(0, vl.len * FontH - viewH) else: 0
  if multi:
    var sy = clamp(st.scrollY, 0, maxOff)
    scrollBarFor(id + 9, id, rect(r.x + r.w - SbW, r.y, SbW, r.h), true, sy,
                 maxOff, max(FontH, viewH - FontH), FontH, enabled)
    if enabled:
      scrollWheel(id, sy, maxOff, r, 3 * FontH)
      scrollPan(id, sy, maxOff, r)
    st.scrollY = sy
  if ui.textFocusWanted and enabled and canInput() and
     (not ui.textFocusInDialog or layer() >= LayerDialog):
    ui.textFocusWanted = false
    ui.focus = id
  let focusBefore = ui.focus
  beginKeepSides(area)           # (the text as it reads, the mouse with it)
  var hit = interact(id, area, enabled = enabled)
  if hit.focused: focusFrame(r)
  if hit.hover and canHover(): ui.cursor = curIbeam
  if accessOn and enabled and not readOnly and accessValueFor(id):
    # (a screen reader put text in it)
    let t = typedText(accessSet.text, multi, allowed)
    if t != s:
      s = t
      changed = true
    st.caret = s.len
    st.anchor = s.len
  var tapAt = false
  if finger() and enabled:
    # a finger that lands on a text box may be scrolling the page: the box
    # takes the focus (and the keyboard comes up) only when it is lifted
    # there without moving away
    if ui.pressed and ui.active == id and focusBefore != id:
      ui.focus = focusBefore
      hit.focused = false
      tapFocus = id
    elif hit.clicked and tapFocus == id:
      ui.focus = id
      hit.focused = true
      tapAt = true
      ui.redraw = true
    if not ui.mouseDown and not hit.clicked and tapFocus == id: tapFocus = 0
  st.caret = clamp(st.caret, 0, s.len)
  st.anchor = clamp(st.anchor, 0, s.len)
  let focusedNow = hit.focused and enabled
  if focusedNow and st.aux == 0:
    caretT = ui.now
    if not multi and not ui.pressed and not tapAt:
      st.anchor = 0                       # (focused by Tab: all of it selected)
      st.caret = s.len
  st.aux = ord(focusedNow)
  template hitIndex(st: WState): int =
    let ln = if multi: clamp((st.scrollY + ui.my - ty) div FontH, 0, vl.high) else: 0
    let g = lineGeo(s, vl[ln].a, vl[ln].b, pass, tx, inner.w - 6)
    hitOf(s, vl, ln, ui.mx - (g.left - st.scrollX), pass, g)
  if focusedNow:
    ui.takesText = true
    ui.editsText = true
    if multi: ui.takesEnter = true
    # (a phone's keyboard for it: a password's, what the app asked, else letters)
    ui.keyboard = if pass: kbPassword elif kb.set: kb.kind else: kbText
    ui.keyboardEnter = if kb.set: kb.enter else: keReturn
    # mouse; a tap puts the caret where the finger was
    if tapAt:
      st.caret = hitIndex(st)
      st.anchor = st.caret
      moved = true
    elif ui.active == id and ui.pressed:
      let i = hitIndex(st)
      st.caret = i
      if ShiftPressed notin ui.mods: st.anchor = i
      if ui.clicks >= 2 and not pass:
        st.anchor = wordLeft(s, i)
        st.caret = wordRight(s, i)
        markDouble(id)
      moved = true
    elif ui.active == id and ui.mouseDown:
      let i = hitIndex(st)
      if i != st.caret:
        st.caret = i
        moved = true
      if not mouseIn(inner): wakeIn(50)
    # keys
    let shift = ShiftPressed in ui.mods
    let ctrl = CtrlPressed in ui.mods
    let a0 = min(st.caret, st.anchor)
    let b0 = max(st.caret, st.anchor)
    template moveTo(n: int) =
      st.caret = n
      if not shift: st.anchor = st.caret
      moved = true
      ui.keyUsed = true
    template replaceSel(t: string) =
      if not readOnly:
        let a = min(st.caret, st.anchor)
        let b = max(st.caret, st.anchor)
        s = s[0 ..< a] & t & s[b .. ^1]
        st.caret = a + t.len
        st.anchor = st.caret
        changed = true
        moved = true
    # (a template: a nested proc would be a closure, made on every call)
    template clean(t: string): string = typedText(t, multi, allowed)
    if canInput() and not ui.keyUsed:
      case ui.key
      of KeyLeft, KeyRight:
        # (in a right-to-left line Left goes on through the text, as it reads)
        let ln = if multi: lineOf(vl, st.caret) else: 0
        let fwd = (ui.key == KeyRight) != lineRtl(s[vl[ln].a ..< vl[ln].b], pass)
        if not shift and a0 != b0: moveTo(if fwd: b0 else: a0)
        elif fwd: moveTo(if ctrl: wordRight(s, st.caret) else: clusterAfter(s, st.caret))
        else: moveTo(if ctrl: wordLeft(s, st.caret) else: clusterBefore(s, st.caret))
      of KeyHome:
        moveTo(if ctrl or not multi: 0 else: vl[lineOf(vl, st.caret)].a)
      of KeyEnd:
        if ctrl or not multi: moveTo(s.len)
        else:
          let k = lineOf(vl, st.caret)
          moveTo(if vl[k].soft and vl[k].b > vl[k].a: runeBefore(s, vl[k].b) else: vl[k].b)
      of KeyUp, KeyDown, KeyPageUp, KeyPageDown:
        if multi:
          let ln = lineOf(vl, st.caret)
          let g0 = lineGeo(s, vl[ln].a, vl[ln].b, pass, tx, inner.w - 6)
          let x = g0.left + vxOf(s, vl[ln].a, st.caret, pass, g0)
          let d = case ui.key
            of KeyUp: -1
            of KeyDown: 1
            of KeyPageUp: -visLines
            else: visLines
          let t = clamp(ln + d, 0, vl.high)
          let g1 = lineGeo(s, vl[t].a, vl[t].b, pass, tx, inner.w - 6)
          moveTo(hitOf(s, vl, t, x - g1.left, pass, g1))
      of KeyBackspace:
        # (Ctrl+Backspace -- Option on a Mac -- the word before the caret;
        # Cmd+Backspace on a Mac, the line before it; a password's words
        # are not shown: all of it before the caret)
        ui.keyUsed = true
        let byWord = when defined(macosx): AltPressed in ui.mods else: ctrl
        let byLine = when defined(macosx): ctrl else: false
        if a0 != b0: replaceSel("")
        elif st.caret > 0:
          st.anchor =
            if pass and (byWord or byLine): 0
            elif byLine: s.rfind('\n', 0, st.caret - 1) + 1
            elif byWord: wordLeft(s, st.caret)
            else: runeBefore(s, st.caret)
          replaceSel("")
      of KeyDelete:
        ui.keyUsed = true
        let byWord = when defined(macosx): AltPressed in ui.mods else: ctrl
        if shift and a0 != b0 and not pass:
          putClipboardText(s[a0 ..< b0])
          replaceSel("")
        elif a0 != b0: replaceSel("")
        elif st.caret < s.len:
          # (Ctrl+Delete -- Option on a Mac -- the word after the caret)
          st.anchor = if byWord: (if pass: s.len else: wordRight(s, st.caret))
                      else: clusterAfter(s, st.caret)    # (a letter with its marks)
          replaceSel("")
      of KeyInsert:
        ui.keyUsed = true
        if ctrl and a0 != b0 and not pass: putClipboardText(s[a0 ..< b0])
        elif shift: replaceSel(clean(getClipboardText()))
      of KeyEnter:
        if multi and not readOnly:
          ui.keyUsed = true
          replaceSel("\n")
      of KeyA:
        if ctrl:
          ui.keyUsed = true
          st.anchor = 0
          st.caret = s.len
      of KeyC:
        if ctrl:
          ui.keyUsed = true
          if a0 != b0 and not pass: putClipboardText(s[a0 ..< b0])
      of KeyX:
        if ctrl:
          ui.keyUsed = true
          if a0 != b0 and not pass:
            putClipboardText(s[a0 ..< b0])
            replaceSel("")
      of KeyV:
        if ctrl:
          ui.keyUsed = true
          replaceSel(clean(getClipboardText()))
      else: discard
    if ui.typed.len > 0 and canInput():
      let t = clean(ui.typed)
      if t.len > 0: replaceSel(t)
  if moved: caretT = ui.now
  if changed: shownLines(editLines, id, s, wrapW, multi)
  # keep the caret in view
  let ln = if multi: lineOf(vl, st.caret) else: 0
  let cl = vl[ln].a
  let gc = lineGeo(s, cl, vl[ln].b, pass, tx, inner.w - 6)
  let cx = gc.left - tx + vxOf(s, cl, st.caret, pass, gc)
  if moved or changed:
    if wrapW == 0:
      if cx - st.scrollX > inner.w - 6: st.scrollX = cx - inner.w + 6 + inner.w div 4
      if cx - st.scrollX < 0: st.scrollX = max(0, cx - inner.w div 4)
    if multi:
      let maxNow = max(0, vl.len * FontH - viewH)
      if ui.key in {KeyPageUp, KeyPageDown}:     # a page: it glides
        scrollShow(id, st.scrollY, ln * FontH, (ln + 1) * FontH, viewH, maxNow)
      else:                                        # typing, arrows: at once
        let nv = clamp(clamp(st.scrollY, (ln + 1) * FontH - viewH, ln * FontH), 0, maxNow)
        if nv != st.scrollY:
          scrollStop(id)
          st.scrollY = nv
  if multi: scrollTick(id, st.scrollY, max(0, vl.len * FontH - viewH))
  # draw
  if right and not multi:
    tx = inner.x + 2 + max(0, inner.w - 6 - textWidth(shown(s, 0, s.len, pass)))
    if tx > inner.x + 2: st.scrollX = 0
  let back = if invalid and enabled: mixColor(th.field, InvalidRed, 0.3) else: th.field
  if frameless: fill(area, back)
  else: fieldFace(area, back, enabled, hit.focused, hot = enabled and hovered(area))
  if invalid and enabled:
    if glassLook(): roundFrame(area, float(min(dp(6), area.h div 2)), 1, InvalidRed)
    else: box(area, InvalidRed)
  pushClip(inset(inner, 1))
  let fg = if enabled: th.fieldText else: th.gray
  let selA = min(st.caret, st.anchor)
  let selB = max(st.caret, st.anchor)
  let firstLine = if multi: clamp(st.scrollY div FontH, 0, vl.high) else: 0
  var k = firstLine
  var y = if multi: ty + firstLine * FontH - st.scrollY else: ty
  var shownLines = 0
  while shownLines < (if multi: visLines + 2 else: 1) and k < vl.len:
    let a = vl[k].a
    let b = vl[k].b
    let marked = focusedNow and (selA != selB and selA <= b and selB >= a or st.caret in a .. b)
    let g = lineGeo(s, a, b, pass, tx, inner.w - 6, runs = marked)
    let x0 = g.left - st.scrollX
    var lst = textStyleNow()          # (the UI's text, or `withTextStyle`'s)
    lst.rtl = g.rtl
    text(x0, y, shown(s, a, b, pass), fg, lst)
    if focusedNow and selA != selB and selA <= b and selB >= a and
       not (vl[k].soft and selA == b):
      let sa = max(selA, a)
      let sb = min(selB, b)
      if g.runs.len > 0 or (g.rtl and not pass):
        # (right-to-left text: the selected part of each piece in one
        # direction -- a selection of mixed text can be in several places
        # --, the line drawn again over it in the selection's colors, its
        # letters joined as they are)
        let pieces = if g.runs.len > 0: g.runs else: @[(a: a, b: b, x: 0, w: g.w, rtl: true)]
        for r in pieces:
          let ra = max(sa, r.a)
          let rb = min(sb, r.b)
          if ra >= rb: continue
          let wa = partW(s, r.a, ra)
          let wb = partW(s, r.a, rb)
          let xa = if r.rtl: x0 + r.x + r.w - wb else: x0 + r.x + wa
          let sel = rect(xa, y, max(1, wb - wa), FontH)
          fill(sel, th.select)
          pushClip(intersect(sel, inset(inner, 1)))
          text(x0, y, shown(s, a, b, pass), th.selectText, lst)
          popClip()
      else:
        let xa = x0 + vxOf(s, a, sa, pass, g)
        let xb = x0 + vxOf(s, a, sb, pass, g)
        let px0 = min(xa, xb)
        var pw = abs(xb - xa)
        if selB > b and multi and not vl[k].soft and not g.rtl: pw += 4
        fill(px0, y, pw, FontH, th.select)
        text(px0, y, shown(s, sa, sb, pass), th.selectText)
    if focusedNow and ui.active31 and st.caret >= a and
       (st.caret < b or (st.caret == b and not vl[k].soft)) and
       (ui.now - caretT >= CaretBlinkFor or ((ui.now - caretT) div 530) mod 2 == 0):
      vline(x0 + vxOf(s, a, st.caret, pass, g), y, FontH, fg)
    inc shownLines
    inc k
    y += FontH
  popClip()
  if focusedNow and ui.active31 and ui.now - caretT < CaretBlinkFor:
    # (it blinks a while after it last moved, then stays: no frames for a
    # caret nobody is using, as Windows stops its blinking)
    wakeIn(min(530 - (ui.now - caretT) mod 530, CaretBlinkFor - (ui.now - caretT)))
    # (the system's input method composes at the caret)
    noteTextCaret(rect(globalX(gc.left - st.scrollX + vxOf(s, cl, st.caret, pass, gc)),
                       (if multi: ty + ln * FontH - st.scrollY else: ty), 1, FontH))
  if focusedNow and ui.composing.len > 0 and not pass:
    # What the input method composes, in the box at the caret, underlined,
    # its own caret in it -- over the text, until it is settled (then it
    # comes as typed text).
    let cx = gc.left - st.scrollX + vxOf(s, cl, st.caret, pass, gc)
    let cy = if multi: ty + ln * FontH - st.scrollY else: ty
    let cw = textWidth(ui.composing)
    pushClip(inset(inner, 1))
    fill(rect(cx, cy, cw + 3, FontH), th.field)
    text(cx + 1, cy, ui.composing, th.fieldText)
    hline(cx + 1, cy + FontH - 1, max(1, cw), th.fieldText)
    let kx = cx + 1 + textWidth(ui.composing[0 ..< clamp(ui.composeCaret, 0, ui.composing.len)])
    vline(kx, cy, FontH - 1, th.fieldText)
    popClip()
  # (a finger held on a word, nothing chosen: the word chosen, as phones do -- its menu then
  # has Cut and Copy for it)
  if enabled and canInput() and ui.rpressed and finger() and longPressed() and not pass and
     st.caret == st.anchor and s.len > 0 and mouseIn(inner):
    let i = hitIndex(st)
    st.anchor = wordLeft(s, i)
    st.caret = wordRight(s, i)
  endKeepSides()
  # its menu: a right click, a long press, the menu key
  # (its name made only when a menu is open: a frame takes no memory)
  template menuKey: string = "edit-menu:" & $uint32(id)
  if enabled and canInput() and ui.rpressed and mouseIn(area):
    ui.focus = id
    st.aux = 1                            # (focused by the menu: what was chosen stays so)
    openPopupMenu(menuKey, ui.mx, ui.my)
  if ui.popup != 0 and beginPopupMenuFor(menuKey):
    let a0 = min(st.caret, st.anchor)
    let b0 = max(st.caret, st.anchor)
    let some = a0 != b0
    template put(t: string) =
      s = s[0 ..< a0] & t & s[b0 .. ^1]
      st.caret = a0 + t.len
      st.anchor = st.caret
      changed = true
    if menuItem("Cu&t", "Ctrl+X", enabled = some and not pass and enabled and not readOnly):
      putClipboardText(s[a0 ..< b0])
      put("")
    if menuItem("&Copy", "Ctrl+C", enabled = some and not pass):
      putClipboardText(s[a0 ..< b0])
    if menuItem("&Paste", "Ctrl+V", enabled = enabled and not readOnly):
      var t = ""
      for c in plainLetters(getClipboardText()):
        if c == '\r' or (c == '\n' and not multi): continue
        if allowed != {} and c notin allowed: continue
        t.add c
      put(t)
    if menuItem("&Delete", "Del", enabled = some and enabled and not readOnly): put("")
    menuSeparator()
    if menuItem("Select &all", "Ctrl+A", enabled = s.len > 0):
      st.anchor = 0
      st.caret = s.len
    endMenu()
  if accessOn:
    let k = accessNode(if pass: arPasswordField elif multi: arTextArea else: arTextField,
                       value = (if pass: "" else: s), id = id, r = area,
                       states = offWhen(enabled) + (if readOnly: {asReadOnly} else: {}) +
                                (if multi: {asMultiLine} else: {}) +
                                (if pass: {asProtected} else: {}))
    if not pass:
      let c = runeLenOf(s, clamp(st.caret, 0, s.len))
      let a = runeLenOf(s, clamp(min(st.caret, st.anchor), 0, s.len))
      let b = runeLenOf(s, clamp(max(st.caret, st.anchor), 0, s.len))
      accessText(k, c, a, b)
  swap(state(id), st)
  changed

proc edit*(s: var string; w = 0; password = false;
           enabled = true; readOnly = false; invalid = false;
           h = 0; style = TextStyle(); hint = ""): bool {.discardable.} =
  ## A one-line text box bound to `s`; true when the text changed.
  ## `readOnly`: selected and copied, not changed. `invalid`: red, what is
  ## typed is not right yet (a form says so as it is typed). `style`: its
  ## text's (large, bold, serif): the box grows with it; `h`: its height.
  ## `hint`: gray words in it while it is empty ("New task"), its name for screen readers.
  let uiFontH = FontH
  withTextStyle(style):
    let r = place(if w > 0: w else: 0, styledH(h, EditH, uiFontH), fill = w <= 0)
    if hint.len > 0 and accessOn: accessNameOr(tr(hint))
    result = editAt(idOf(s, "edit"), s, r, false, password, enabled, readOnly = readOnly,
                    invalid = invalid)
    if hint.len > 0 and s.len == 0:
      pushClip(inset(r, 2))
      text(r.x + dp(4), r.y + (r.h - FontH) div 2, tr(hint), th.gray)
      popClip()

proc editArea*(s: var string; lines = 6; w = 0;
               enabled = true; wrap = true; readOnly = false): bool {.discardable.} =
  ## A multi-line text box with a scroll bar. `lines` < 0 fills the
  ## height left in the window. Long lines wrap at the words (`wrap`
  ## false: they scroll sideways). `readOnly`: the text can be selected,
  ## copied and scrolled through, not changed (a log, a message's source).
  let h = if lines < 0: remainingH() else: lines * FontH + 6
  let r = place(if w > 0: w else: 0, h, fill = w <= 0)
  editAt(idOf(s, "area"), s, r, true, false, enabled, wrap = wrap, readOnly = readOnly)

# ---- lists ------------------------------------------------------------------

var itemBuf: string    # (a column of a list's item)
var numBuf: string     # (a number shown: a progress bar's, a spin box's)

proc drawItem(x, y, w: int; s: string; c: Color; tabs: openArray[int]) =
  ## An item; '\t' moves to the next tab stop. (The stops grow with the
  ## UI's size, as the text does, and a column's text stops short of the
  ## next: at 150% the columns ran into each other.)
  if '\t' notin s:
    text(x, y, s, c)
    return
  var cx = x
  var k = 0
  var a = 0
  while true:
    let t = s.find('\t', a)
    let e = if t < 0: s.len else: t
    let next = x + dp(if k < tabs.len: tabs[k] else: (k + 1) * 90)
    # (the column into a buffer used again: a frame takes no memory for it)
    itemBuf.setLen(e - a)
    if e > a: copyMem(addr itemBuf[0], unsafeAddr s[a], e - a)
    if t >= 0 and textWidth(itemBuf) > next - cx - dp(4):
      text(cx, y, ellipsize(itemBuf, next - cx - dp(4)), c)
    else:
      text(cx, y, itemBuf, c)
    if t < 0: break
    cx = next
    a = t + 1
    inc k

proc listbox*(items: openArray[string]; sel: var int; rows = 6; w = 0;
              tabs: openArray[int] = []; enabled = true): bool {.discardable.} =
  ## A list bound to the selected index `sel`; true when it changed.
  ## Items may hold '\t' columns aligned on `tabs` (pixels at 100%: they
  ## grow with the UI's size).
  let h = if rows < 0: remainingH() else: rows * ItemH + 2
  let r = place(if w > 0: w else: 0, h, fill = w <= 0)
  let id = idOf(sel, "list")
  var st = state(id)
  let viewH = r.h - 2
  let vis = max(1, viewH div ItemH)
  let n = items.len
  let maxOff = max(0, n * ItemH - viewH)        # (scrolled by the pixel)
  let bar = maxOff > 0
  let area = if bar: rect(r.x, r.y, r.w - SbW + 1, r.h) else: r
  var off = clamp(st.scrollY, 0, maxOff)
  # (the selection set by the app since the last frame: shown at once, as
  #  `tree` does)
  if st.aux2 != 0 and st.aux2 - 1 != sel and sel >= 0 and sel < n:
    scrollStop(id)
    off = clamp(clamp(off, (sel + 1) * ItemH - viewH, sel * ItemH), 0, maxOff)
  if bar:
    scrollBarFor(id + 9, id, rect(r.x + r.w - SbW, r.y, SbW, r.h), true,
                 off, maxOff, max(ItemH, viewH - ItemH), ItemH, enabled)
  let hit = interact(id, area, enabled = enabled)
  if hit.focused: focusFrame(r)
  var nsel = sel
  var follow = false
  if enabled and canInput():
    scrollWheel(id, off, maxOff, r, 3 * ItemH)
    scrollPan(id, off, maxOff, r)
    # (a right click, or a finger held on a row: that row chosen first -- the menu the app opens
    # then is for it, as in the tree and the grids)
    if ui.rpressed and n > 0 and mouseIn(r) and ui.my - (r.y + 1) in 0 ..< viewH:
      nsel = clamp((ui.my - (r.y + 1) + off) div ItemH, 0, n - 1)
      ui.focus = id
    if finger():
      # A tap selects (on release); a drag scrolls instead.
      if tapped(id, hit) and n > 0:
        nsel = clamp((ui.my - (r.y + 1) + off) div ItemH, 0, n - 1)
        if ui.clicks >= 2: markDouble(id)
    elif ui.active == id and ui.mouseDown and n > 0:
      let my = ui.my - (r.y + 1)
      if my < 0 and off > 0:
        if ui.now >= repeatAt:
          scrollStop(id)
          off = max(0, off - ItemH)
          repeatAt = ui.now + 60
        wakeIn(60)
      elif my >= viewH and off < maxOff:
        if ui.now >= repeatAt:
          scrollStop(id)
          off = min(maxOff, off + ItemH)
          repeatAt = ui.now + 60
        wakeIn(60)
      nsel = clamp((clamp(my, 0, viewH - 1) + off) div ItemH, 0, n - 1)
      if ui.pressed and ui.clicks >= 2: markDouble(id)
    if hit.focused and n > 0:
      if not ui.touch: ui.takesText = true   # type-ahead; no keyboard pops up
      # (with Ctrl or Alt the keys are the app's: a list in a panel does not
      # move as the app's own shortcut runs)
      let plain = not ui.keyUsed and ui.mods * {CtrlPressed, AltPressed, GuiPressed} == {}
      case (if plain: ui.key else: KeyNone)
      of KeyUp: nsel = max(0, nsel - 1); follow = true
      of KeyDown: nsel = min(n - 1, nsel + 1); follow = true
      of KeyPageUp: nsel = max(0, nsel - vis + 1); follow = true
      of KeyPageDown: nsel = min(n - 1, nsel + vis - 1); follow = true
      of KeyHome: nsel = 0; follow = true
      of KeyEnd: nsel = n - 1; follow = true
      of KeyEnter:
        markDouble(id)
      else: discard
      if follow: ui.keyUsed = true
      if ui.typed.len > 0:
        let c = ui.typed[0].toLowerAscii
        for k in 1 .. n:
          let i = (max(0, nsel) + k) mod n
          if items[i].len > 0 and items[i][0].toLowerAscii == c:
            nsel = i
            follow = true
            break
  if accessPress != 0 and enabled:
    # (a screen reader picked an item)
    for i in 0 ..< n:
      if accessSubId(id, i) == accessPress:
        nsel = i
        follow = true
        accessPress = 0
        ui.focus = id
        break
  if nsel != sel and nsel >= 0 and nsel < n:
    sel = nsel
    result = true
  st.aux2 = sel + 1
  if follow and sel >= 0:
    scrollShow(id, off, sel * ItemH, (sel + 1) * ItemH, viewH, maxOff)
  scrollTick(id, off, maxOff)
  st.scrollY = off
  state(id) = st
  # draw
  fieldFace(area, th.field, enabled, hit.focused)
  pushClip(inset(area, 1))
  let top = off div ItemH
  let glass = glassLook()
  for i in top ..< min(n, top + vis + 2):
    let y = r.y + 1 + i * ItemH - off
    let ir = rect(area.x + 1, y, area.w - 2, ItemH)
    if i != sel and enabled and hovered(ir):
      if glass:
        let p = rect(ir.x + dp(3), ir.y + 1, ir.w - 2 * dp(3), ir.h - 2)
        roundRect(p, float(min(dp(6), p.h div 2)), hoverColor())
      else: fill(ir, hoverColor())
    if i == sel:
      if glass:
        # (Glass: a rounded pill of the highlight, a little in from the row's ends)
        if enabled: selectFill(ir)
        else:
          let p = rect(ir.x + dp(3), ir.y + 1, ir.w - 2 * dp(3), ir.h - 2)
          roundRect(p, float(min(dp(6), p.h div 2)), th.gray)
      else: fill(ir, if enabled: th.select else: th.gray)
      drawItem(ir.x + 2 + (if glass: dp(4) else: 0), itemTextY(y), ir.w, items[i], th.selectText, tabs)
      if hit.focused and not glass: dots(ir, th.selectText)
    else:
      drawItem(ir.x + 2 + (if glass: dp(4) else: 0), itemTextY(y), ir.w, items[i],
               if enabled: th.fieldText else: th.gray, tabs)
  if hit.focused and (sel < 0 or sel >= n):
    dots(rect(area.x + 1, r.y + 1, area.w - 2, ItemH), th.fieldText)
  popClip()
  if accessOn:
    # (the list and the items it shows; the selected one has the focus)
    accessBegin(arList, id = id, r = area, states = offWhen(enabled), takesLabel = true)
    for i in top ..< min(n, top + vis + 2):
      let y = r.y + 1 + i * ItemH - off
      let k = accessNode(arListItem, items[i], id = accessSubId(id, i),
                         r = rect(area.x + 1, y, area.w - 2, ItemH),
                         states = (if i == sel: {asSelected} else: {}))
      accessItem(k, i + 1, n)
      if i == sel and hit.focused: accessFocus(k)
    accessEnd()

type ItemPreview* = proc (i: int; r: Rect; selected: bool) {.closure.}
  ## Draws item `i` of a drop-down list in `r` (its background is drawn
  ## already): a font's name in the font, a color, a line style.

var typeAhead: tuple[id: Id; text: string; at: int]

proc typeAheadPick(id: Id; items: openArray[string]; current: int): int =
  ## (letters typed on a list: the next item that starts with them; typed
  ## quickly one after the other, a longer start -- "fr" finds France after
  ## Finland; the same letter again goes on to the next with it) -1 none.
  result = -1
  if ui.typed.len == 0 or items.len == 0: return
  if typeAhead.id != id or ui.now - typeAhead.at > 1000: typeAhead.text = ""
  typeAhead.id = id
  typeAhead.at = ui.now
  let t = unicode.toLower(ui.typed)
  var want = typeAhead.text & t
  var same = true
  for c in want:
    if c != want[0]: same = false
  if same and want.len > 1: want = t          # (the same letter again: the next one)
  typeAhead.text = want
  let start = if want.len > t.len: max(0, current) else: current + 1
  for k in 0 ..< items.len:
    let i = (start + k + items.len) mod items.len
    if unicode.toLower(tr(items[i])).startsWith(want): return i

proc popupList(id: Id; r: Rect; items: openArray[string]; sel: var int;
               preview: ItemPreview = nil; arrowX = -1; arrowUp = true): bool =
  ## The list a combo box drops down. Runs in the popup layer. (Gloss: in a popover's frame, its
  ## arrow at `arrowX` toward the box.)
  var st = state(id)
  let vis = min(items.len, 8)
  let viewH = vis * ItemH
  let maxOff = max(0, items.len * ItemH - viewH)
  var off = clamp(st.scrollY, 0, maxOff)
  let gloss = glossLook()
  let edge = glossMenuEdge()
  pushLayer(LayerPopup)
  ui.popupRectNow = if gloss: inset(r, -edge - max(6, dp(9))) else: r
  if gloss:
    # (Gloss: as a select list was then, a popover -- its white inside, its dark frame round it)
    softShadow(inset(r, -edge), float(dp(10)))
    roundRect(r, float(max(3, dp(5))), th.field)
    glossPopoverFrame(r, arrowX, arrowUp)
  let bar = maxOff > 0
  let area = if bar: rect(r.x, r.y, r.w - SbW + 1, r.h) else: r
  if bar:
    scrollBarFor(id + 9, id, rect(r.x + r.w - SbW, r.y, SbW, r.h), true,
                 off, maxOff, max(ItemH, viewH - ItemH), ItemH)
  if canInput():
    scrollWheel(id, off, maxOff, r, 3 * ItemH)
    if ui.pressed: st.anchor = 0                 # (a new touch: not scrolled yet)
    if scrollPan(id, off, maxOff, r):
      st.anchor = 1                              # a finger scrolled: no pick on release
    if mouseIn(area):
      let i = (ui.my - area.y - 1 + off) div ItemH
      if i >= 0 and i < items.len and (ui.mouseMoved or ui.mouseDown):
        ui.popupHi = i
      if ui.released and ui.popupHi >= 0 and st.anchor == 0 and
         not (finger() and longPressed()):
        sel = ui.popupHi
        result = true
        ui.popup = 0
    if dropKey() or (ui.key == KeyUp and AltPressed in ui.mods and not ui.keyUsed):
      # F4, Alt+Down, Alt+Up: closed, the item lit picked (as Windows does)
      if ui.popupHi >= 0 and ui.popupHi != sel:
        sel = ui.popupHi
        result = true
      ui.popup = 0
      ui.keyUsed = true
    case ui.key
    of KeyUp: ui.popupHi = max(0, ui.popupHi - 1); ui.keyUsed = true
    of KeyDown: ui.popupHi = min(items.len - 1, ui.popupHi + 1); ui.keyUsed = true
    of KeyPageUp: ui.popupHi = max(0, ui.popupHi - vis + 1); ui.keyUsed = true
    of KeyPageDown: ui.popupHi = min(items.len - 1, ui.popupHi + vis - 1); ui.keyUsed = true
    of KeyHome: ui.popupHi = 0; ui.keyUsed = true
    of KeyEnd: ui.popupHi = items.len - 1; ui.keyUsed = true
    of KeyEnter:
      if ui.popupHi >= 0:
        sel = ui.popupHi
        result = true
      ui.popup = 0
      ui.keyUsed = true
    of KeyEsc, KeyTab:
      ui.popup = 0
      ui.keyUsed = true
    else: discard
    if ui.typed.len > 0:
      # (letters typed: the item that starts with them, lit)
      ui.takesText = true
      let i = typeAheadPick(id, items, ui.popupHi)
      if i >= 0:
        ui.popupHi = i
        ui.keyUsed = true
      ui.typed = ""
    if ui.popupHi >= 0 and ui.keyUsed:
      scrollShow(id, off, ui.popupHi * ItemH, (ui.popupHi + 1) * ItemH, viewH, maxOff)
    elif ui.popupHi >= 0 and not scrolling(id) and not mouseIn(area):
      # (just opened: the current item in view at once)
      off = clamp(off, (ui.popupHi + 1) * ItemH - viewH, ui.popupHi * ItemH)
      off = clamp(off, 0, maxOff)
  scrollTick(id, off, maxOff)
  if gloss: discard          # (drawn above, under its scroll bar)
  elif glassLook():
    # (Glass: rounded, a soft shadow under it, a hairline round it; frosted, what is under it
    # blurred through it)
    let rad = float(dp(8))
    softShadow(area, rad)
    if not frostedFace(area, th.field, rad): roundRect(area, rad, th.field)
    roundFrame(area, rad, 1, glassHair())
  else:
    fill(area, th.field)
    box(area, th.edge)
  pushClip(inset(area, 1))
  let top = off div ItemH
  for i in top ..< min(items.len, top + vis + 1):
    let ir = rect(area.x + 1, area.y + 1 + i * ItemH - off, area.w - 2, ItemH)
    if gloss and i > top and i != ui.popupHi and i - 1 != ui.popupHi:
      # (Gloss: a line between the rows)
      hline(ir.x, ir.y, ir.w, mixColor(th.field, th.fieldText, 0.12))
    if i == ui.popupHi: selectFill(ir)
    if preview != nil:
      pushClip(ir)
      preview(i, ir, i == ui.popupHi)
      popClip()
    elif gloss:
      # (bold, as a list's rows were; the one chosen with a check mark at its end)
      let ink = if i == ui.popupHi: th.selectText else: th.fieldText
      text(ir.x + dp(8), itemTextY(ir.y), tr(items[i]), ink, style(bold = true))
      if i == sel:
        let k = float(max(dp(4), FontH div 4))
        let cx = float(ir.x + ir.w - dp(14))
        let cy = float(ir.y + ir.h div 2)
        let w = max(1.8, float(dp(2)))
        let ck = if i == ui.popupHi: ink else: glossDetail()
        thickLine(cx - k, cy, cx - k / 3, cy + k * 0.7, w, ck)
        thickLine(cx - k / 3, cy + k * 0.7, cx + k, cy - k * 0.8, w, ck)
    elif i == ui.popupHi:
      text(ir.x + 2, itemTextY(ir.y), tr(items[i]), th.selectText)
    else:
      text(ir.x + 2, itemTextY(ir.y), tr(items[i]), th.fieldText)
  popClip()
  if accessOn:
    # (the open list and the items it shows, the lit one focused; a screen
    # reader's press on one picks it)
    accessBegin(arList, id = id, r = area)
    for i in top ..< min(items.len, top + vis + 1):
      let iid = accessSubId(id, i)
      if accessPress != 0 and accessPress == iid:
        accessPress = 0
        sel = i
        result = true
        ui.popup = 0
        ui.redraw = true
      let k = accessNode(arListItem, tr(items[i]), id = iid,
                         r = rect(area.x + 1, area.y + 1 + i * ItemH - off, area.w - 2, ItemH),
                         states = (if i == ui.popupHi: {asSelected} else: {}))
      accessItem(k, i + 1, items.len)
      if i == ui.popupHi: accessFocus(k)
    accessEnd()
  st.scrollY = off
  state(id) = st
  popLayer()

proc combo*(items: openArray[string]; sel: var int; w = 0;
            enabled = true; preview: ItemPreview = nil): bool {.discardable.} =
  ## A drop-down list bound to the selected index `sel`; `preview` draws
  ## its items in the list (a font's name in the font). With the focus:
  ## Enter, Alt+Down or F4 open it (F4, Alt+Up or Enter close it on
  ## the item lit; Esc without), Up / Down / Home / End pick, letters typed
  ## pick the item that starts with them (in the open list; in the closed
  ## one when Tab brought the focus -- a list clicked leaves the letters to
  ## the app's keys).
  var mw = 40
  for it in items: mw = max(mw, textWidth(tr(it)))
  let r = place(if w > 0: w else: mw + SbW + 12, EditH)
  let id = idOf(sel, "combo")
  let open = ui.popup == id
  let hit = interact(id, r, enabled = enabled)
  if accessOn and enabled:
    if accessPressed == id and not open:
      # (a screen reader opened it)
      ui.popup = id
      ui.menuOpen = false
      ui.popupHi = sel
      ui.redraw = true
    if accessValueFor(id):
      for i, it in items:
        if tr(it) == accessSet.text or it == accessSet.text:
          if sel != i:
            sel = i
            result = true
          break
    accessNode(arComboBox, value = (if sel >= 0 and sel < items.len: tr(items[sel]) else: ""),
               id = id, r = r, states = offWhen(enabled) + {asExpandable} +
                                       (if open: {asExpanded} else: {}))
  if enabled:
    # a press opens it (a tap, with a finger: a finger may be scrolling)
    if not open and ((not finger() and hit.hover and ui.active == id and ui.pressed) or
                     (finger() and hit.clicked)):
      ui.popup = id
      ui.menuOpen = false
      ui.popupHi = sel
      ui.redraw = true
    # (Enter is its own while it has the focus: it opens the list, or picks
    # in it -- a default button drawn before it leaves Enter to it, #9)
    if hit.focused: ui.takesEnter = true
    if hit.focused and canInput() and not open:
      # (type-ahead when the keyboard brought the focus: a list clicked once
      # does not take the letters an app's keys of one letter are -- a
      # paint program's tools; no keyboard pops up on a touch screen)
      let ahead = ui.focusByKeys and not ui.touch
      if ahead: ui.takesText = true
      # (not Space, as in Windows: an app's Space -- a paint program's Hand
      # -- still works with a list focused)
      if not ui.keyUsed and ((ui.key == KeyDown and AltPressed in ui.mods) or ui.key == KeyF4 or
                             (ui.key == KeyEnter and ui.mods == {})):
        ui.popup = id
        ui.popupHi = sel
        ui.keyUsed = true
        ui.redraw = true
      elif ui.typed.len > 0 and ahead:
        let i = typeAheadPick(id, items, sel)
        if i >= 0 and i != sel:
          sel = i
          result = true
        ui.typed = ""
      elif ui.key == KeyUp and sel > 0:
        dec sel
        ui.keyUsed = true
        result = true
      elif ui.key == KeyDown and sel < items.len - 1:
        inc sel
        ui.keyUsed = true
        result = true
  let field = rect(r.x, r.y, r.w - SbW + 1, r.h)
  let btn = rect(r.x + r.w - SbW, r.y, SbW, r.h)
  let s = if sel >= 0 and sel < items.len: tr(items[sel]) else: ""
  let ty = r.y + (r.h - FontH) div 2
  if glassLook():
    # (Glass: one rounded field, a chevron at its end; lit under the pointer, the highlight's
    # ring while open or with the keyboard)
    fieldFace(r, if enabled and hovered(r) and not open: mixColor(th.field, th.light, 0.5) else: th.field,
              enabled, hit.focused or open)
    pushClip(rect(r.x + 2, r.y, r.w - SbW - 2, r.h))
    text(field.x + dp(6), ty, s, if enabled: th.fieldText else: th.gray)
    popClip()
    let cx = float(btn.x + btn.w div 2)
    let cy = float(r.y + r.h div 2)
    let k = float(max(3, min(btn.w, r.h) div 5))
    let ink = if enabled: mixColor(th.fieldText, th.field, 0.25) else: th.gray
    thickLine(cx - k, cy - k / 2, cx, cy + k / 2, 1.6, ink)
    thickLine(cx, cy + k / 2, cx + k, cy - k / 2, 1.6, ink)
  else:
    fill(field, th.field)
    fieldFrame(field, enabled)
    if hit.focused and not open:
      let tr = rect(field.x + 2, field.y + 2, field.w - 4, field.h - 4)
      fill(tr, th.select)
      text(field.x + 4, ty, s, th.selectText)
      dots(tr, th.selectText)
    else:
      text(field.x + 4, ty, s, if enabled: th.fieldText else: th.gray)
    let pressedBtn = open
    buttonFace(btn, pressedBtn, rounded = false, bevel = 1,
               hot = enabled and hovered(r))
  # (the wheel over it while it has the focus: the one before or after, as Windows' drop-down
  # lists do -- not when it hasn't, so a page scrolled past it never changes it)
  if enabled and hit.focused and canInput() and not open and items.len > 0 and mouseIn(r) and
     ui.wheel != 0 and not ui.wheelUsed:
    ui.wheelUsed = true
    let to = clamp(sel - ui.wheel, 0, items.high)
    if to != sel:
      sel = to
      result = true
  # (Home / End pick the first / last when it is closed)
  if enabled and hit.focused and canInput() and not open and items.len > 0 and
     ui.key in {KeyHome, KeyEnd} and not ui.keyUsed:
    let to = if ui.key == KeyHome: 0 else: items.high
    if to != sel:
      sel = to
      result = true
    ui.keyUsed = true
  if not glassLook():
    let o = if open: 1 else: 0
    let c = if enabled: th.frame else: th.gray
    arrow(btn.x + btn.w div 2 + o, btn.y + btn.h div 2 - 2 + o, dDown, c)
    hline(btn.x + btn.w div 2 - 3 + o, btn.y + btn.h div 2 + 3 + o, 7, c)
  if ui.popup == id:
    let vis = min(items.len, 8)
    # (Gloss: a popover's frame and arrow between it and the box)
    let gap = if glossLook(): glossMenuEdge() + max(6, dp(9)) + dp(2) elif glassLook(): dp(3) else: 0
    var pr = rect(r.x, r.y + r.h - 1 + gap, r.w, vis * ItemH + 2)
    var up = true
    if pr.y + pr.h + glossMenuEdge() > ui.h:
      pr.y = r.y - pr.h + 1 - gap
      up = false
    if popupList(id + 17, pr, items, sel, preview, if glossLook(): r.x + r.w div 2 else: -1, up):
      result = true

# ---- values -------------------------------------------------------------------

proc slider*(v: var int; lo, hi: int; w = 0; ticks = 10;
             enabled = true): bool {.discardable.} =
  ## A track bar bound to `v` in `lo..hi`; arrows, PgUp/PgDn, Home/End.
  ## On touch screens the thumb is large enough for a finger.
  let tw = if fingers(): dp(20) else: dp(11)            # the thumb
  let tht = if fingers(): dp(26) else: dp(18)
  let tick = if ticks > 0: dp(5) else: 0
  let r = place(if w > 0: w else: 0, max(tht + tick + dp(2), FontH + 8), fill = w <= 0)
  let id = idOf(v, "slider")
  let hit = interact(id, r, enabled = enabled)
  let span = max(1, hi - lo)
  let chan = rect(r.x + tw div 2, r.y + tht div 2 - dp(2), max(1, r.w - tw), dp(4))
  let travel = max(1, chan.w)
  var nv = v
  if enabled:
    if ui.active == id and ui.mouseDown:
      ui.dragsActive = true
      nv = lo + ((ui.mx - chan.x) * span + travel div 2) div travel
    if hit.focused and canInput() and mouseIn(r) and ui.wheel != 0 and not ui.wheelUsed:
      ui.wheelUsed = true                         # (the wheel: only when focused,
      nv += ui.wheel * max(1, span div 20)        #  so scrolling a page never moves it)
    if hit.focused and canInput():
      let big = max(1, span div 10)
      case ui.key
      of KeyLeft, KeyDown: dec nv; ui.keyUsed = true
      of KeyRight, KeyUp: inc nv; ui.keyUsed = true
      of KeyPageDown: nv -= big; ui.keyUsed = true
      of KeyPageUp: nv += big; ui.keyUsed = true
      of KeyHome: nv = lo; ui.keyUsed = true
      of KeyEnd: nv = hi; ui.keyUsed = true
      else: discard
  if accessOn and enabled and accessValueFor(id):
    nv = int(round(accessSet.num))
  nv = clamp(nv, lo, hi)
  if nv != v:
    v = nv
    result = true
  if accessOn:
    let k = accessNode(arSlider, value = $v, id = id, r = r, states = offWhen(enabled))
    accessRange(k, lo.float, hi.float, v.float, 1.0)
  let cx = chan.x + (clamp(v, lo, hi) - lo) * travel div span
  let thumb = rect(cx - tw div 2, r.y, tw, tht)
  if glossLook():
    # (as phones had it then: a track cut in, blue up to a round white knob, light after it)
    # (iOS 6's: a track 9 high cut in -- blue darker at its top up to the knob, gray to white
    # after it, a shadow inside along its top --, a round knob gray at its top to white at its
    # foot, a dark line round it and a light one inside its top)
    let dark = onDark()
    let tk = if fingers(): dp(9) else: dp(7)
    let tr = rect(chan.x - tk div 2, r.y + tht div 2 - tk div 2, chan.w + tk, tk)
    let trad = float(tk) / 2
    let ti = inset(tr, 1)
    pushClip(rect(tr.x, tr.y, max(0, cx - tr.x), tr.h))
    if enabled:
      roundRectShaded(tr, trad, glossTint(color(30, 56, 107)), glossTint(color(97, 128, 183)))
      roundRectShaded(ti, trad - 1, glossTint(color(46, 89, 168)), glossTint(color(109, 159, 232)))
    else:
      roundRectShaded(tr, trad, color(120, 120, 120), color(160, 160, 160))
      roundRectShaded(ti, trad - 1, color(150, 150, 150), color(200, 200, 200))
    popClip()
    pushClip(rect(cx, tr.y, max(0, tr.x + tr.w - cx), tr.h))
    if dark:
      roundRect(tr, trad, black)
      roundRectShaded(ti, trad - 1, color(30, 30, 34), color(70, 72, 78))
    else:
      roundRectShaded(tr, trad, color(130, 130, 130), color(172, 172, 172))
      roundRectShaded(ti, trad - 1, color(184, 184, 184), white)
    popClip()
    glossTopShade(ti, trad - 1, [51])
    let kd = if fingers(): dp(23) else: dp(17)
    let kcx = float(cx)
    let kcy = float(r.y + tht div 2)
    disc(kcx, kcy + 1.5, float(kd) / 2, withAlpha(black, 77))
    disc(kcx, kcy, float(kd) / 2, if dark: black else: color(60, 60, 60))
    if hit.down: discShaded(kcx, kcy, float(kd) / 2 - 1, color(140, 140, 140), color(228, 228, 228))
    else: discShaded(kcx, kcy, float(kd) / 2 - 1, color(166, 166, 166), color(252, 252, 252))
    pushClip(rect(int(kcx) - kd, int(kcy) - kd, 2 * kd, kd div 2))
    ring(kcx, kcy, float(kd) / 2 - 1, 1, withAlpha(white, 178))
    popClip()
  elif matteLook():
    # (a thin line, the highlight up to a round knob: a ring round a light middle, the
    # highlight's dot in it while it is held)
    let dark = onDark()
    let tk = max(2, dp(3))
    let ty = r.y + tht div 2 - tk div 2
    fill(rect(chan.x, ty, chan.w, tk), mixColor(th.window, th.text, if dark: 0.3 else: 0.2))
    if enabled and cx > chan.x: fill(rect(chan.x, ty, cx - chan.x, tk), accentColor())
    let kd = if fingers(): dp(26) else: dp(18)
    let kcx = float(cx)
    let kcy = float(r.y + tht div 2)
    disc(kcx, kcy, float(kd) / 2, mixColor(th.face, th.text, if dark: 0.4 else: 0.3))
    disc(kcx, kcy, float(kd) / 2 - float(max(2, dp(2))), if dark: mixColor(th.face, white, 0.2) else: th.light)
    disc(kcx, kcy, float(kd) / 5, if hit.down or hit.focused or (enabled and hovered(thumb)): accentColor()
                                 else: mixColor(th.face, th.text, 0.2))
  elif glassLook():
    # (a slim track, filled in the highlight up to a round knob of glass)
    let tr = rect(chan.x, chan.y, chan.w, chan.h)
    glassWell(tr, float(tr.h) / 2, mixColor(th.window, th.text, 0.12))
    if enabled and cx > chan.x: glassAccent(rect(chan.x, chan.y, cx - chan.x + tr.h div 2, tr.h), float(tr.h) / 2)
    let kd = min(tht, tw + dp(6))
    let knob = rect(cx - kd div 2, r.y + (tht - kd) div 2, kd, kd)
    glassFace(knob, hit.down, enabled and hovered(thumb), radius = float(kd) / 2)
  else:
    sunken(chan)
    hline(chan.x + 1, chan.y + 1, chan.w - 2, th.frame)
    buttonFace(thumb, hit.down, rounded = false, bevel = 1,
               hot = enabled and hovered(thumb))
  if ticks > 0:
    for i in 0 .. ticks:
      vline(chan.x + i * travel div ticks, r.y + tht + dp(2), dp(3),
            if enabled: th.text else: th.gray)
  if hit.focused: focusDots(rect(r.x, r.y - 1, r.w, r.h + 2))

proc progress*(value: float; w = 0; showText = true) =
  ## A progress bar, `value` from 0.0 to 1.0, with the percentage.
  let r = place(if w > 0: w else: 0, max(dp(18), FontH + 4), fill = w <= 0)
  ui.lastId = 0
  ui.lastRect = r
  let f = if value.isNaN: 0.0 else: clamp(value, 0.0, 1.0)
  if accessOn:
    let k = accessNode(arProgressBar, value = $int(f * 100.0 + 0.5) & "%", id = 0, r = r)
    accessRange(k, 0, 100, f * 100.0, 1.0)
  if glossLook():
    # (Gloss: the thin bar of its time -- a gray track cut in, the blue part lit from above --,
    # the percentage after it)
    var tw = 0
    if showText:
      numBuf.setLen(0)
      numBuf.addInt int(f * 100.0 + 0.5)
      numBuf.add '%'
      tw = textWidth("100%") + dp(8)
    let bh = max(dp(9), 7)
    let track = rect(r.x, r.y + (r.h - bh) div 2, max(bh, r.w - tw), bh)
    let rad = float(bh) / 2
    let dark = onDark()
    roundRect(track, rad, if dark: black else: color(132, 136, 144))
    roundRectShaded(inset(track, 1), rad - 1, if dark: color(30, 30, 34) else: color(196, 198, 204),
                    if dark: color(70, 70, 76) else: color(248, 248, 250))
    let fw = int(float(track.w) * f + 0.5)
    if fw > 0:
      let bar = rect(track.x, track.y, max(bh, fw), bh)
      roundRect(bar, rad, glossTone(0.88, 0.63))
      glossTwoTone(inset(bar, 1), rad - 1, glossTone(0.52, 0.98), glossTone(0.72, 0.93),
                   glossTone(0.82, 0.88), glossTone(0.85, 0.81))
    if showText:
      text(track.x + track.w + dp(8), r.y + (r.h - FontH) div 2, numBuf,
           if dark: th.text else: glossTone(0.30, 0.42))
    return
  let inner = inset(r, 1)
  let done = rect(inner.x, inner.y, int(inner.w.float * f + 0.5), inner.h)
  if glassLook():
    # (a rounded well, filled in the highlight, lit from above)
    glassWell(r, glassRadius(r))
    if done.w > 0:
      let bar = rect(r.x, r.y, max(r.h, done.w + 1), r.h)
      if glossLook():
        # (Gloss: the blue bar of its time, its top half shining)
        tintedFace(bar, color(32, 116, 230), radius = glassRadius(r))
      else: glassAccent(bar, glassRadius(r))
  else:
    fill(inner, th.field)
    fill(done, th.select)
    box(r, th.edge)
  if showText:
    # (in a buffer used again: a frame takes no memory for it)
    numBuf.setLen(0)
    numBuf.addInt int(f * 100.0 + 0.5)
    numBuf.add '%'
    template s: untyped = numBuf
    let tx = r.x + (r.w - textWidth(s)) div 2
    let ty = r.y + (r.h - FontH) div 2
    pushClip(rect(done.x + done.w, inner.y, inner.w - done.w, inner.h))
    text(tx, ty, s, th.select)
    popClip()
    pushClip(done)
    if glossLook():
      # (Gloss: on the striped bar, the label pressed in: a darker line under it)
      text(tx, ty - 1, s, withAlpha(black, 110))
    text(tx, ty, s, th.selectText)
    popClip()

type SumReader = object
  t: string
  i: int
  bad: bool

proc sumExpr(r: var SumReader): float

proc sumAtom(r: var SumReader): float =
  if r.i < r.t.len and r.t[r.i] in {'-', '+'}:
    let neg = r.t[r.i] == '-'
    inc r.i
    let x = r.sumAtom()
    return (if neg: -x else: x)
  if r.i < r.t.len and r.t[r.i] == '(':
    inc r.i
    result = r.sumExpr()
    if r.i < r.t.len and r.t[r.i] == ')': inc r.i else: r.bad = true
    return
  let st = r.i
  while r.i < r.t.len and r.t[r.i] in {'0'..'9', '.'}: inc r.i
  if r.i == st:
    r.bad = true
    return 0
  try: result = parseFloat(r.t[st ..< r.i])
  except ValueError: r.bad = true

proc sumTerm(r: var SumReader): float =
  result = r.sumAtom()
  while not r.bad and r.i < r.t.len and r.t[r.i] in {'*', '/'}:
    let op = r.t[r.i]
    inc r.i
    let y = r.sumAtom()
    if op == '*': result *= y
    elif y == 0: r.bad = true
    else: result /= y

proc sumExpr(r: var SumReader): float =
  result = r.sumTerm()
  while not r.bad and r.i < r.t.len and r.t[r.i] in {'+', '-'}:
    let op = r.t[r.i]
    inc r.i
    let y = r.sumTerm()
    if op == '+': result += y else: result -= y

proc evalNumber*(s: string; v: var float): bool =
  ## A number typed, or a little sum that makes one -- "1200/2", "40+15",
  ## "3*(8-2)", "-2.5" -- into `v` (as a photo editor's fields take them): + - * /,
  ## brackets, decimals, spaces; thousands separators (",") ignored. False (`v`
  ## left alone) when it is not one yet ("12*"), divides by nothing, or is too big.
  var r = SumReader()
  for c in s:
    if c notin {' ', ','}: r.t.add c
  if r.t.len == 0: return false
  let x = r.sumExpr()
  if r.bad or r.i != r.t.len or classify(x) in {fcNan, fcInf, fcNegInf}: return false
  v = x
  true

const NumberSumChars* = {'0'..'9', '-', '+', '*', '/', '(', ')', ' '}
  ## (what a number box takes: digits and a little sum's signs)

proc spinBox(v: var int; lo, hi, w, step: int; enabled: bool; h, uiFontH: int): bool =
  let r = place(w, styledH(h, EditH, uiFontH))
  let id = idOf(v, "spin")
  var st: WState
  swap(st, state(id))         # (taken out and put back: no copy of its text)
  let editId = id + 31
  if ui.focus != editId:
    # (the number as text only when it changed: a frame takes no memory)
    numBuf.setLen(0)
    numBuf.addInt v
    if st.buf != numBuf: st.buf = numBuf
  var nv = v
  # the arrows: finger-sized on touch, and as wide as a tall box asks
  let aw = max(if fingers(): dp(26) else: dp(16), r.h * 2 div 3)
  let ups = rect(r.x + r.w - aw, r.y, aw, r.h div 2 + 1)
  let downs = rect(r.x + r.w - aw, r.y + r.h div 2, aw, r.h - r.h div 2)
  if editAt(editId, st.buf, rect(r.x, r.y, r.w - aw + 1, r.h), false, false,
             enabled, NumberSumChars):
    var x: float
    if evalNumber(st.buf, x) and abs(x) < 1e15: nv = int(round(x))
  if enabled and canInput():
    if ui.focus == editId:
      if keyHit(KeyUp): nv += step
      if keyHit(KeyDown): nv -= step
      if keyHit(KeyPageUp): nv += step * 10
      if keyHit(KeyPageDown): nv -= step * 10
      if mouseIn(r) and ui.wheel != 0 and not ui.wheelUsed:
        ui.wheelUsed = true
        nv += ui.wheel * step
    for i, b in [ups, downs]:
      let bid = id + 40 + i.uint32
      if hover(b) and takePress():
        ui.active = bid
        nv += (if i == 0: step else: -step)
        repeatAt = ui.now + 400
      elif ui.active == bid and ui.mouseDown:
        if ui.now >= repeatAt:
          if mouseIn(b): nv += (if i == 0: step else: -step)
          repeatAt = ui.now + 50
        wakeIn(repeatAt - ui.now)
  nv = clamp(nv, lo, hi)
  if nv != v:
    v = nv
    st.buf = $v
    result = true
  swap(state(id), st)
  if accessOn:
    # (one node for the box and its arrows, named as its text box was: by
    # the label before it; a value a screen reader puts comes through the box)
    var nm = ""
    if accessTree.len > 0 and accessTree[^1].id == uint32(editId):
      nm = accessTree[^1].name
      accessTree.setLen(accessTree.len - 1)
    let k = accessNode(arSpinButton, nm, value = $v, id = editId, r = r, states = offWhen(enabled))
    accessRange(k, lo.float, hi.float, v.float, step.float)
  if glassLook():
    # (Glass: a stepper of glass beside the field, a chevron each way, a hairline between)
    let sr = rect(ups.x + dp(2), r.y, aw - dp(2), r.h)
    glassFace(sr, false, enabled and hovered(sr), radius = float(min(dp(7), sr.w div 2)), shadow = false)
    for i, b in [ups, downs]:
      let half = if i == 0: rect(sr.x + 1, sr.y + 1, sr.w - 2, sr.h div 2 - 1)
                 else: rect(sr.x + 1, sr.y + sr.h div 2, sr.w - 2, sr.h - sr.h div 2 - 1)
      if ui.active == id + 40 + i.uint32 and ui.mouseDown and mouseIn(b):
        fill(half, withAlpha(color(0, 0, 0), if onDark(): 50 else: 22))
      let cx = float(half.x + half.w div 2)
      let cy = float(half.y + half.h div 2)
      let k = float(max(2, min(half.w, half.h * 2) div 6))
      let ink = if enabled: mixColor(th.text, th.face, 0.2) else: th.gray
      let d = if i == 0: -1.0 else: 1.0
      thickLine(cx - k, cy - d * k / 2, cx, cy + d * k / 2, 1.5, ink)
      thickLine(cx, cy + d * k / 2, cx + k, cy - d * k / 2, 1.5, ink)
    hline(sr.x + dp(3), sr.y + sr.h div 2, sr.w - 2 * dp(3), glassHair())
  else:
    for i, b in [ups, downs]:
      let pr = ui.active == id + 40 + i.uint32 and ui.mouseDown and mouseIn(b)
      buttonFace(b, pr, rounded = false, bevel = 1)
      let o = if pr: 1 else: 0
      arrow(b.x + b.w div 2 + o, b.y + b.h div 2 + o, if i == 0: dUp else: dDown,
            if enabled: th.frame else: th.gray, max(3, b.h div 4))
  ui.lastId = editId
  ui.lastRect = r

proc spin*(v: var int; lo, hi: int; w = 80; step = 1;
           enabled = true; h = 0; style = TextStyle()): bool {.discardable.} =
  ## A number box with up and down arrows bound to `v` in `lo..hi`: type a
  ## number (or a little sum: "1200/2", `evalNumber`), click or hold the arrows, or with the
  ## focus Up / Down (`step`), Page Up / Page Down (ten steps) and the wheel. `style`: its
  ## digits' (`style(size = 1.6, bold = true)`); the box and its arrows grow with
  ## them, or to `h`.
  let uiFontH = FontH
  if not ui.nextKeyboard.set: textKeyboard(if lo < 0: kbDecimal else: kbNumber)   # (digits)
  withTextStyle(style):
    result = spinBox(v, lo, hi, w, step, enabled, h, uiFontH)

proc popupSlider*(v: var int; lo, hi: int; w = 0; unit = "%";
                  enabled = true): bool {.discardable.} =
  ## A number box with a slider that drops down from its arrow, as a tool's
  ## options bar has for Opacity, Flow or Tolerance: type the number (or a sum); or
  ## press the arrow and drag (letting go closes it); or click the arrow,
  ## then click or drag on the slider (Enter, Esc or a click outside close
  ## it). Up / Down and the wheel step it when it has the focus; F4 or
  ## Alt+Down drop the slider from the keyboard (Left / Right move it).
  let r = place(if w > 0: w else: textWidth($hi & unit) + SbW + dp(14), EditH)
  let id = idOf(v, "popslider")
  let editId = id + 31
  let popId = id + 7
  let dragId = id + 8
  var st = state(id)
  if ui.focus != editId: st.buf = $v & unit
  let field = rect(r.x, r.y, r.w - SbW + 1, r.h)
  let btn = rect(r.x + r.w - SbW, r.y, SbW, r.h)
  var allowed = NumberSumChars
  for c in unit: allowed.incl c
  var buf = st.buf
  var nv = v
  if editAt(editId, buf, field, false, false, enabled, allowed):
    var sum = ""
    for c in buf:
      if c in NumberSumChars: sum.add c
    var x: float
    if evalNumber(sum, x) and abs(x) < 1e15: nv = int(round(x))
  st.buf = buf
  if enabled and canInput():
    if hover(btn) and takePress():
      ui.popup = if ui.popup == popId: 0 else: popId
      ui.menuOpen = false
      if ui.popup == popId:
        ui.active = dragId
        st.anchor = 0                        # (pressed on the arrow, not dragged yet)
        st.aux = ui.mx
      ui.redraw = true
    if ui.focus == editId:
      if ui.popup != popId and dropKey():
        # (F4, Alt+Down: the slider drops; again, or Alt+Up: it closes)
        ui.popup = popId
        ui.menuOpen = false
        st.anchor = 1                        # (it stays open: Left / Right move it)
        ui.redraw = true
      if keyHit(KeyUp): inc nv
      if keyHit(KeyDown): dec nv
      if keyHit(KeyPageUp): nv += 10
      if keyHit(KeyPageDown): nv -= 10
      if mouseIn(r) and ui.wheel != 0 and not ui.wheelUsed:
        ui.wheelUsed = true
        nv += ui.wheel
  buttonFace(btn, ui.popup == popId, rounded = false, bevel = 1, hot = enabled and hovered(btn))
  let o = if ui.popup == popId: 1 else: 0
  arrow(btn.x + btn.w div 2 + o, btn.y + btn.h div 2 - 1 + o, dDown, if enabled: th.frame else: th.gray)
  if ui.popup == popId:
    let pw = max(r.w, dp(170))
    let ph = if fingers(): dp(40) else: dp(28)
    var pr = rect(r.x + r.w - pw, r.y + r.h - 1, pw, ph)
    if pr.x < 0: pr.x = 0
    if pr.x + pr.w > ui.w: pr.x = max(0, ui.w - pr.w)
    if pr.y + pr.h > ui.h: pr.y = r.y - ph + 1
    let tw = if fingers(): dp(16) else: dp(9)
    let chan = rect(pr.x + dp(8) + tw div 2, pr.y + ph div 2 - dp(2), pr.w - dp(16) - tw, dp(4))
    let span = max(1, hi - lo)
    let travel = max(1, chan.w)
    pushLayer(LayerPopup)
    ui.popupRectNow = pr
    if canInput() and hover(pr) and takePress():
      ui.active = dragId
      st.anchor = 1                          # (pressed on the slider: it stays open)
    if ui.active == dragId and ui.mouseDown:
      ui.dragsActive = true
      nv = lo + ((ui.mx - chan.x) * span + travel div 2) div travel
      if st.anchor == 0 and abs(ui.mx - st.aux) > dp(3): st.anchor = 2
    if ui.active == dragId and ui.released and st.anchor == 2:
      ui.popup = 0
    if canInput(): ui.takesEnter = true    # (Enter closes the slider: #9)
    if canInput() and (keyHit(KeyEsc) or keyHit(KeyEnter) or dropKey() or
                       (ui.key == KeyUp and AltPressed in ui.mods and keyHit(KeyUp))):
      ui.popup = 0
    if canInput():
      if keyHit(KeyLeft): dec nv
      if keyHit(KeyRight): inc nv
    fill(pr, th.face)
    box(pr, th.frame)
    raisedFace(inset(pr, 1))
    sunken(chan)
    hline(chan.x + 1, chan.y + 1, chan.w - 2, th.frame)
    let cx = chan.x + (clamp(nv, lo, hi) - lo) * travel div span
    let thumb = rect(cx - tw div 2, chan.y - dp(6), tw, dp(16))
    buttonFace(thumb, ui.active == dragId and ui.mouseDown, rounded = false, bevel = 1)
    popLayer()
  nv = clamp(nv, lo, hi)
  if nv != v:
    v = nv
    st.buf = $v & unit
    result = true
  state(id) = st
  ui.lastId = editId
  ui.lastRect = r

# ---- containers ---------------------------------------------------------------

type GroupLook* = enum
  ## How a group of controls is framed (`group`, `card`).
  glEtched     ## 3.1's: an etched line, the title set into it
  glCaption    ## a raised panel, its title in a strip of the highlight colour

var groupLook* = glEtched
  ## The look of the groups and cards that do not say theirs.

var captionGroups: seq[tuple[cell: Rect; fillAt: int; title: string; minH, depth: int]]

proc captionStripH(): int = FontH + dp(10)

var glassGroups: seq[tuple[slot, depth: int]]

proc glassCard*(): Color =
  ## Glass: the colour of a card on the window (a group, a tab's page) -- white, a little of it
  ## (more on a light window), so a frosted dialog still shows through it and a card on a
  ## card stands out of it.
  withAlpha(color(255, 255, 255), if onDark(): 11 else: 150)

proc beginGroup*(title: string; look: GroupLook) =
  ## Starts a group in the `look` way (see `group`); `endGroup` ends it.
  if look == glEtched:
    # (Glass: a card under it -- its place kept, drawn as tall as it is at the end)
    let slot = if glassLook(): reserveFill() else: -1
    beginGroup(title)
    if slot >= 0: glassGroups.add (slot, layoutDepth())
    return
  let cell = beginCell(0, fill = true)
  if accessOn: accessBegin(arGroup, title, rect(cell.x, cell.y, cell.w, FontH))
  let minH = rowHeight()
  let head = if title.len > 0: captionStripH() + dp(4) else: 0
  let fillAt = reserveFill()
  pushFrame(rect(cell.x + Pad + 3, cell.y + Pad + 3 + head, cell.w - 2 * Pad - 6, 0),
            reserve = Pad + 3, inPage = true)
  captionGroups.add (cell, fillAt, title, minH, layoutDepth())

proc raisedPanel*(r: Rect; c: Color) =
  ## A panel standing out of the window: `c` inside a gray line, lighter
  ## along its top and left, darker along its bottom and right.
  fill(r, c)
  box(r, th.shadow)
  if r.w > 4 and r.h > 4:
    hline(r.x + 1, r.y + 1, r.w - 2, th.light)
    vline(r.x + 1, r.y + 1, r.h - 2, th.light)
    hline(r.x + 1, r.y + r.h - 2, r.w - 2, mixColor(c, th.shadow, 0.3))
    vline(r.x + r.w - 2, r.y + 1, r.h - 2, mixColor(c, th.shadow, 0.3))

proc captionStrip*(r: Rect; title: string) =
  ## A strip in the highlight colour with a bold title: the head of a
  ## panel (`glCaption`'s). (Glass: rounded, lit from above.)
  if glassLook():
    glassAccent(r, float(dp(6)))
    pushClip(r)
    drawLabel(r.x + dp(8), r.y + (r.h - FontH) div 2, title, accentInk(), true)
    popClip()
    return
  fill(r, th.select)
  hline(r.x, r.y, r.w, mixColor(th.select, th.selectText, 0.25))
  pushClip(r)
  drawLabel(r.x + dp(8), r.y + (r.h - FontH) div 2, title, th.selectText, true)
  popClip()

proc endGroup*() =
  ## Ends a `beginGroup`: draws the box and its title.
  if captionGroups.len > 0 and captionGroups[^1].depth == layoutDepth():
    let (cell, fillAt, title, minH, _) = captionGroups.pop()
    let h = popFrame()
    let head = if title.len > 0: captionStripH() + dp(4) else: 0
    let natural = h + 2 * Pad + 6 + head
    let r = rect(cell.x, cell.y, cell.w, max(natural, minH))
    if glassLook():
      # (Glass: a rounded card, its title strip a band of the highlight rounded inside it)
      let rad = float(dp(10))
      patchRoundRect(fillAt, r, rad, glassCard())
      roundFrame(r, rad, 1, glassHair())
      if title.len > 0:
        captionStrip(rect(r.x + dp(4), r.y + dp(4), r.w - dp(8), captionStripH()), title)
      endCell(r, r.h, natural)
      if accessOn: accessEnd(r)
      return
    # (the panel under what was placed in it: its place kept, filled now)
    patchFill(fillAt, r, mixColor(th.window, th.light, 0.35))
    box(r, th.shadow)
    hline(r.x + 1, r.y + 1, r.w - 2, th.light)
    vline(r.x + 1, r.y + 1, r.h - 2, th.light)
    if title.len > 0:
      captionStrip(rect(r.x + dp(4), r.y + dp(4), r.w - dp(8), captionStripH()), title)
    endCell(r, r.h, natural)
    if accessOn: accessEnd(r)
    return
  let slot = if glassGroups.len > 0 and glassGroups[^1].depth == layoutDepth(): glassGroups.pop().slot
             else: -1
  let (cell, title) = groupEnd()
  if accessOn: accessEnd(cell)
  if slot >= 0:
    # (Glass: a rounded card with a hairline round it, its title a quiet bold line at its top)
    let rad = float(dp(10))
    let card = if title.len > 0: cell else: rect(cell.x, cell.y + FontH div 2 - 1, cell.w, cell.h - FontH div 2 + 1)
    patchRoundRect(slot, card, rad, glassCard())
    roundFrame(card, rad, 1, glassHair())
    if title.len > 0:
      pushClip(rect(cell.x + 4, cell.y, cell.w - 8, FontH + 4))
      drawLabel(cell.x + 10, cell.y + 3, title, mixColor(th.text, th.window, 0.3), true)
      popClip()
    return
  let top = FontH div 2 - 1
  etchedBox(rect(cell.x, cell.y + top, cell.w, cell.h - top))
  if title.len > 0:
    let tw = labelWidth(title)
    fill(cell.x + 6, cell.y, tw + 8, FontH, th.window)
    drawLabel(cell.x + 10, cell.y, title, th.text)

template group*(title: string; body: untyped) =
  ## A group box: a frame with a title around `body` (in the look
  ## `groupLook` says: 3.1's etched line, or a panel with a title strip).
  beginGroup(title, groupLook)
  body
  endGroup()

template group*(title: string; look: GroupLook; body: untyped) =
  ## A group in a look of its own: `group "Your Measurements", glCaption:`.
  beginGroup(title, look)
  body
  endGroup()

var tabStack: seq[tuple[x, y, w, selX, selW, tabH: int; id: Id; same: bool; card: int]]

type TabLook* = enum
  ## How tabs look (`tabs`, `tabStrip`; `tabLook` for all of them).
  tlDocument     ## Windows 3.1's: rounded, the chosen one white with its label in bold
  tlPalette      ## Retro Photo's (a palette's, `paletteTabs`): gray folder tabs, the
                 ## chosen one joined to the page under it, the others darker behind it

var tabLook* = tlPalette
  ## How the app's tabs look, unless a call says (`setTabLook`); Retro
  ## Photo's palette tabs since 0.9.

proc setTabLook*(look: TabLook) =
  ## Every `tabs` and `tabStrip` from now on in this look (a change draws
  ## again; the same look again, nothing).
  if look == tabLook: return
  tabLook = look
  ui.redraw = true

proc paletteTabH*(): int =
  ## The height of a palette's tabs -- the docked panels', a document's
  ## (`tabStrip` in `tlPalette`), a dialog's: the same everywhere.
  FontH + dp(5) + (if fingers(): dp(8) else: 0)

proc paletteTabFace*(r: Rect; front, hover: bool): Color =
  ## Draws a palette tab's face in `r` (the one in `front` the panel's gray
  ## and joined to it, its edges lit; the others darker behind it) and
  ## gives the color its label is drawn in. One look for the docked
  ## panels, the documents' tabs and the dialogs' tabs. (Glass: the one in front a tab of
  ## glass rounded at its top, joined to the page; the others plain, lit under the pointer.)
  if glassLook():
    let rad = float(min(dp(7), r.h div 2))
    if front:
      roundRect(rect(r.x, r.y, r.w, r.h + int(rad)), rad, glassHair())
      roundRect(rect(r.x + 1, r.y + 1, r.w - 2, r.h + int(rad)), max(0.0, rad - 1), th.face)
      hline(r.x + int(rad), r.y + 1, max(0, r.w - 2 * int(rad)),
            withAlpha(color(255, 255, 255), if onDark(): 46 else: 200))
      return th.text
    if hover:
      roundRect(rect(r.x + 2, r.y + 2, r.w - 4, r.h - 3), rad, withAlpha(th.text, 20))
    return mixColor(th.window, th.text, 0.7)
  if front:
    fill(r, th.face)
    hline(r.x + 1, r.y, r.w - 2, th.frame)
    vline(r.x, r.y + 1, r.h - 1, th.frame)
    vline(r.x + r.w - 1, r.y + 1, r.h - 1, th.frame)
    hline(r.x + 1, r.y + 1, r.w - 2, th.light)
    vline(r.x + 1, r.y + 1, r.h - 2, th.light)
    th.text
  else:
    # (behind: darker than the panel -- in a dark theme, where the shadow
    # is the panel's own black, lifted a little instead)
    let back = if hover: th.gray
               elif lumaOfColor(th.shadow) + 24 >= lumaOfColor(th.face): mixColor(th.face, th.light, 0.45)
               else: th.shadow
    fill(rect(r.x, r.y, r.w, r.h - 1), back)
    hline(r.x + 1, r.y, r.w - 2, th.frame)
    vline(r.x, r.y + 1, r.h - 2, th.frame)
    vline(r.x + r.w - 1, r.y + 1, r.h - 2, th.frame)
    # (the light color a candidate too: in Gray the window's color is the
    # panel's gray, and labels were gray on dark gray -- hard to read; and the text's
    # color when none of them stands out: Matte Light's light gray, white on it)
    let ink = contrastInk(back, contrastInk(back, th.window, th.light), th.gray)
    if abs(lumaOfColor(ink) - lumaOfColor(back)) < 70: contrastInk(back, ink, th.text) else: ink

proc plainLabel(l: string): string =
  ## A label shown plain: "&&" an "&", a lone "&" left out (in one pass what
  ## `.replace("&&", "\0").replace("&", "").replace("\0", "&")` gives).
  if '&' notin l and '\0' notin l: return l
  result = newStringOfCap(l.len)
  var i = 0
  while i < l.len:
    if l[i] == '&':
      if i + 1 < l.len and l[i + 1] == '&':
        result.add '&'
        inc i
    elif l[i] == '\0': result.add '&'
    else: result.add l[i]
    inc i

proc beginTabs*(sel: var int; labels: openArray[string]; sameHeight = false) =
  ## Tabs over a page (see `tabs`). When they do not fit, two arrow
  ## buttons scroll them, as on Windows 95; the chosen one is kept in view.
  ## `sameHeight`: the page keeps the height of the tallest page shown so
  ## far (a settings dialog does not jump when another tab is chosen).
  let cell = beginCell(0, fill = true)
  let id = idOf(sel, "tabs")
  # (Glass: a page's tabs a segmented control over a card, whichever look -- a palette's own
  # tabs, the docked panels', stay joined to their panels)
  let pal = tabLook == tlPalette and not glassLook()
  let pst = style(size = 0.9)
  let tabH = if pal: paletteTabH() else: CtrlH - 1
  let strip = rect(cell.x, cell.y, cell.w, tabH)
  let ty = cell.y + (tabH - (if pal: lineHeight(pst) else: FontH)) div 2
  if labels.len > 0: sel = clamp(sel, 0, labels.high)
  var ws = newSeq[int](labels.len)
  var total = 0
  # (the palette's labels as shown, worked out once a frame)
  var plain: seq[string]
  if pal:
    plain = newSeq[string](labels.len)
    for i, l in labels: plain[i] = core.tr(plainLabel(l))
  for i, l in labels:
    ws[i] = if pal: textWidth(plain[i], pst) + dp(12)
            else: labelWidth(l, true) + dp(22)          # room for the bold (chosen) label
    total += ws[i]
  # the arrows, when the tabs are wider than the page
  var st = state(id)
  let arrowW = if fingers(): CtrlH else: SbW
  let over = total + 6 > cell.w and labels.len > 1
  let room = if over: cell.w - 2 * arrowW - 6 else: cell.w - 4
  var first = if over: clamp(st.aux, 0, labels.high) else: 0
  proc widthFrom(ws: seq[int]; a, b: int): int =
    for k in a .. b: result += ws[k]
  if over:
    let lr = rect(cell.x + cell.w - 2 * arrowW, cell.y + 1, arrowW, tabH - 3)
    let rr = rect(lr.x + arrowW, lr.y, arrowW, lr.h)
    let canL = first > 0
    let canR = widthFrom(ws, first, labels.high) > room
    let hl = interact(id + 1, lr, focusable = false, enabled = canL)
    let hr = interact(id + 2, rr, focusable = false, enabled = canR)
    if hl.clicked and canL: dec first
    if hr.clicked and canR: inc first
    # a finger swiping over the tabs, or the wheel, scrolls them too
    if canInput():
      let p = takePanX(strip)
      if p != 0:
        st.scrollY += p
        if st.scrollY >= dp(36) and canR:
          inc first
          st.scrollY = 0
        elif st.scrollY <= -dp(36) and canL:
          dec first
          st.scrollY = 0
      if mouseIn(strip) and ui.wheel != 0 and not ui.wheelUsed:
        ui.wheelUsed = true
        if ui.wheel > 0 and canL: dec first
        elif ui.wheel < 0 and canR: inc first
    for (r, d, can, h) in [(lr, dLeft, canL, hl), (rr, dRight, canR, hr)]:
      let pr = h.down and can
      buttonFace(r, pr, rounded = false, bevel = 1, hot = can and h.showsHover)
      let o = if pr: 1 else: 0
      arrow(r.x + r.w div 2 + o, r.y + r.h div 2 + o, d, if can: th.frame else: th.gray)
  let hit = interact(id, rect(strip.x, strip.y, room + 4, strip.h))
  # a click on a tab, its letter (Alt), the arrow keys, Ctrl+Tab
  var x = cell.x + 2
  for i in first ..< labels.len:
    let tr = rect(x, cell.y + 2, ws[i], tabH - 1)
    # a press picks it; with a finger, a tap (a finger may be swiping)
    if x < cell.x + 2 + room and
       ((not finger() and hover(tr) and ui.active == id and ui.pressed) or
        (finger() and hit.clicked and mouseIn(tr))):
      sel = i
    x += ws[i]
  for i, l in labels:
    if mnemonicHit(l): sel = i
    if accessPress != 0 and accessPress == accessSubId(id, i):
      # (a screen reader chose it)
      accessPress = 0
      sel = i
      ui.focus = id
      ui.redraw = true
  if hit.focused and canInput() and not ui.keyUsed:
    case ui.key
    of KeyLeft:
      if sel > 0: dec sel
      ui.keyUsed = true
    of KeyRight:
      if sel < labels.len - 1: inc sel
      ui.keyUsed = true
    of KeyHome: sel = 0; ui.keyUsed = true
    of KeyEnd: sel = max(0, labels.high); ui.keyUsed = true
    else: discard
  # Ctrl+Tab, Ctrl+PageDown: the next page; with Shift, Ctrl+PageUp: back
  if canInput() and labels.len > 0 and not ui.keyUsed and CtrlPressed in ui.mods:
    if ui.key == KeyTab:
      sel = if ShiftPressed in ui.mods: (sel + labels.len - 1) mod labels.len
            else: (sel + 1) mod labels.len
      ui.keyUsed = true
    elif ui.key == KeyPageDown:
      sel = (sel + 1) mod labels.len
      ui.keyUsed = true
    elif ui.key == KeyPageUp:
      sel = (sel + labels.len - 1) mod labels.len
      ui.keyUsed = true
  # the chosen tab in view (when it changed; the arrows may look away)
  if over and sel != st.aux2 - 1:
    if sel < first: first = sel
    while first < sel and widthFrom(ws, first, sel) > room: inc first
  st.aux = first
  st.aux2 = sel + 1
  state(id) = st
  var selX, selW = 0
  x = cell.x + 2
  if pal:
    # (the page in the panels' gray, as the dock's panels -- as tall as it
    # was last time: what is on it is drawn after)
    let ph = state(id + 3).aux
    if ph > 0: fill(rect(cell.x, cell.y + tabH, cell.w, ph), th.face)
  pushClip(rect(strip.x, strip.y, room + 4, strip.h + 2))
  if glassLook() and not pal:
    # (Glass: the track the tabs sit in, as wide as the ones shown)
    var tw = 0
    for i in first ..< labels.len:
      if cell.x + 2 + tw >= cell.x + 2 + room: break
      tw += ws[i]
    glassTrack(rect(cell.x, cell.y + dp(1), min(tw + 4, room + 4), tabH - dp(1)))
  for i in first ..< labels.len:
    let l = labels[i]
    let tw = ws[i]
    if x >= cell.x + 2 + room: break
    let up = i == sel
    if pal:
      # (Retro Photo's: the chosen one in the page's color, joined to it; the
      # others darker behind it, a little lower; the labels small, plain)
      let tr = if up: rect(x, cell.y, tw, tabH + 1) else: rect(x, cell.y + dp(2), tw, tabH - dp(2))
      if up:
        selX = x
        selW = tw
      let ink = paletteTabFace(tr, up, hovered(tr) and canInput() and not up)
      template shown: untyped = plain[i]
      let lw = textWidth(shown, pst)
      let lx = x + dp(6)                       # (as the docked panels': at the left)
      text(lx, tr.y + (tr.h - lineHeight(pst)) div 2, shown, ink, pst)
      if up and hit.focused:
        focusDots(rect(lx - 3, ty - 1, lw + 6, lineHeight(pst) + 2))
      x += tw
      continue
    if glassLook():
      # (Glass: a segmented control -- the chosen one a pill of glass on a track, the others
      # their labels, lit under the pointer; the page a card below)
      let pill = rect(x, cell.y + dp(3), tw, tabH - dp(5))
      if up: glassFace(pill, false, false, radius = float(pill.h) / 2, shadow = true)
      elif hovered(pill) and canInput():
        roundRect(pill, float(pill.h) / 2, withAlpha(th.text, if onDark(): 26 else: 14))
      let lw = labelWidth(l, up)
      let lx = x + (tw - lw) div 2
      drawLabel(lx, pill.y + (pill.h - FontH) div 2, l, if up: th.text else: mixColor(th.text, th.window, 0.25), up)
      if up and hit.focused: focusDots(pill)
      x += tw
      continue
    if up:
      selX = x - 2
      selW = tw + 4
    let tr = if up: rect(x - 2, cell.y, tw + 4, tabH + 1)
             else: rect(x, cell.y + 2, tw, tabH - 2)
    # (the tabs behind: the face; in a dark theme, where it is the window's
    # own black, lifted a little)
    if up: fill(tr, th.window)
    else: fill(inset(tr, 1), if lumaOfColor(th.face) == lumaOfColor(th.window): mixColor(th.face, th.light, 0.45)
                             else: th.face)
    hline(tr.x + 2, tr.y, tr.w - 4, th.edge)
    vline(tr.x, tr.y + 2, tr.h - 2, th.edge)
    vline(tr.x + tr.w - 1, tr.y + 2, tr.h - 2, th.edge)
    fill(tr.x + 1, tr.y + 1, 1, 1, th.edge)
    fill(tr.x + tr.w - 2, tr.y + 1, 1, 1, th.edge)
    let lw = labelWidth(l, up)
    let lx = x + (tw - lw) div 2                    # centered, bold or not
    drawLabel(lx, ty + (if up: 0 else: 1), l, th.text, up)
    if up and hit.focused:
      focusDots(rect(lx - 3, ty - 1, lw + 6, FontH + 2))
    x += tw
  popClip()
  if selW > 0 and selX + selW > cell.x + 4 + room: selW = max(0, cell.x + 4 + room - selX)
  if accessOn:
    # (the tabs, then the page of the chosen one: its controls inside)
    accessBegin(arTabList, "", strip, id)
    var ax = cell.x + 2
    for i in first ..< labels.len:
      let k = accessNode(arTab, labels[i], id = accessSubId(id, i),
                         r = rect(ax, cell.y, ws[i], tabH),
                         states = (if i == sel: {asSelected} else: {}))
      accessItem(k, i + 1, labels.len)
      if i == sel and hit.focused: accessFocus(k)
      ax += ws[i]
    accessEnd()
    accessBegin(arPane, (if sel >= 0 and sel < labels.len: labels[sel] else: ""),
                rect(cell.x, cell.y + tabH, cell.w, FontH), accessSubId(id, 8888))
  # (Glass: the page a card under what is put on it -- its place kept, drawn as tall as it is
  # at the end)
  let card = if glassLook(): reserveFill() else: -1
  tabStack.add (cell.x, cell.y, cell.w, selX, selW, tabH, id, sameHeight, card)
  let gap = if card >= 0: dp(4) else: 0          # (Glass: the card a little under the tabs)
  pushFrame(rect(cell.x + Pad + 2, cell.y + tabH + gap + Pad + 2,
                 cell.w - 2*Pad - 4, 0), reserve = Pad + 2, inPage = true)

proc endTabs*() =
  ## Ends a `beginTabs`: draws the page's frame.
  var h = popFrame()
  let t = tabStack.pop()
  if t.same:
    var st = state(t.id)
    if h > st.anchor:
      st.anchor = h
      state(t.id) = st
    h = st.anchor
  let gap = if t.card >= 0: dp(4) else: 0
  let page = rect(t.x, t.y + t.tabH + gap, t.w, h + 2*Pad + 4)
  if accessOn: accessEnd(page)
  if tabLook == tlPalette and t.card < 0:
    var ps = state(t.id + 3)
    if ps.aux != page.h:
      ps.aux = page.h
      state(t.id + 3) = ps
      ui.redraw = true                 # (its gray drawn as tall as it is now)
  if t.card >= 0:
    # (Glass: a rounded card, a little lighter than the window, a hairline round it)
    let rad = float(dp(10))
    patchRoundRect(t.card, page, rad, glassCard())
    roundFrame(page, rad, 1, glassHair())
    endCell(rect(t.x, t.y, t.w, 0), page.y + page.h - t.y)
    return
  let line = if glassLook(): glassHair() elif tabLook == tlPalette: th.frame else: th.edge
  if t.selW > 0:
    hline(page.x, page.y, t.selX - page.x, line)
    hline(t.selX + t.selW, page.y, page.x + page.w - t.selX - t.selW, line)
  else:
    hline(page.x, page.y, page.w, line)   # the chosen tab is scrolled away
  vline(page.x, page.y, page.h, line)
  vline(page.x + page.w - 1, page.y, page.h, line)
  hline(page.x, page.y + page.h - 1, page.w, line)
  endCell(rect(t.x, t.y, t.w, 0), page.y + page.h - t.y)

type TabStripEvent* = object
  ## What happened in a `tabStrip` this frame.
  selected*: bool          ## `sel` changed
  closed*: int             ## the tab whose x was clicked (or middle-clicked), -1
  added*: bool             ## the + button was clicked (or the empty part double-clicked)
  dropOn*: int             ## a drag was dropped on this tab, -1
  menu*: int               ## a tab right-clicked or long-pressed (its menu), -1
  tornOff*: int            ## a tab dragged out of the strip (up or down), -1: float it
  moved*: tuple[a, b: int] ## tab `a` dragged to where `b` is (move it there); a -1: none

var tabSpring: tuple[id: Id; tab, since: int]


proc tabStrip*(labels: openArray[string]; sel: var int; glyphs: openArray[string] = [];
               closable = true; addButton = true; dropKind = "";
               enabled = true; look = tabLook): TabStripEvent =
  ## Document tabs (a browser's, a file manager's): a strip of tabs with
  ## an x to close each and a + to add one; the page is yours to draw under
  ## it. Tabs shrink when there are many, and scroll when they still do not
  ## fit (arrow buttons, the wheel, a finger). With `dropKind`, a drag of
  ## that kind resting on a tab selects it, and dropping on it is reported.
  ## Keys: Ctrl+Tab / Ctrl+Shift+Tab anywhere; Left, Right, Home, End when
  ## the strip has the focus. The middle button closes a tab; a right click
  ## or a long press reports `menu` (show a menu with `contextMenu` after).
  result.closed = -1
  result.dropOn = -1
  result.menu = -1
  result.tornOff = -1
  result.moved = (-1, -1)
  let pal = look == tlPalette
  let lst = if pal: style(size = 0.9) else: style(bold = true)
  let tabH = if pal: paletteTabH()
             else: CtrlH + (if fingers(): dp(4) else: dp(2))
  let r = place(0, tabH, fill = true)
  if pal: fill(r, th.face)
  let id = idOf(sel, "tabstrip")
  ui.lastRect = r
  let n = labels.len
  if n > 0: sel = clamp(sel, 0, n - 1)
  var st = state(id + 97)
  let addW = if addButton: tabH else: 0
  let xw = if closable: textWidth(nfTimes) + dp(10) else: 0
  var natural = 0
  var widths: seq[int]
  for i, l in labels:
    let g = if i < glyphs.len and glyphs[i].len > 0: textWidth(glyphs[i]) + dp(6) else: 0
    widths.add min(dp(240), g + textWidth(l, lst) + xw + (if pal: dp(16) else: dp(26)))
    natural += widths[^1]
  var room = r.w - addW - dp(4)
  let minW = if fingers(): dp(96) else: dp(80)
  if natural > room and n > 0:
    for wd in widths.mitems: wd = max(min(wd, minW), wd * room div natural)
  var total = 0
  for wd in widths: total += wd
  # still too wide: the tabs scroll, with two arrows at the right
  let arrowW = if fingers(): CtrlH else: SbW + dp(2)
  let over = total > room
  if over: room -= 2 * arrowW
  let maxOff = max(0, total - room)
  var off = clamp(st.scrollX, 0, maxOff)
  let live = enabled and canInput()
  if over and live:
    scrollPan(id + 97, off, maxOff, r, sideways = true)       # a finger (flicks too)
    if mouseIn(r) and ui.wheel != 0 and not ui.wheelUsed:     # the wheel: it glides
      ui.wheelUsed = true
      scrollBy(id + 97, off, -ui.wheel * dp(60), maxOff)
  # keys
  let strip = rect(r.x, r.y, room + dp(2), r.h)
  if live and ui.focus == id and n > 0 and not ui.keyUsed:
    let before = sel
    case ui.key
    of KeyLeft: sel = max(0, sel - 1)
    of KeyRight: sel = min(n - 1, sel + 1)
    of KeyHome: sel = 0
    of KeyEnd: sel = n - 1
    else: discard
    if sel != before:
      ui.keyUsed = true
      result.selected = true
  if live and ui.key == KeyTab and CtrlPressed in ui.mods and not ui.keyUsed and n > 1:
    sel = if ShiftPressed in ui.mods: (sel + n - 1) mod n else: (sel + 1) mod n
    result.selected = true
    ui.keyUsed = true
  # the chosen tab in view when it changed
  if over and sel != st.aux2 - 1 and n > 0:
    var left = 0
    for k in 0 ..< sel: left += widths[k]
    scrollShow(id + 97, off, left, left + widths[sel], room, maxOff)
  scrollTick(id + 97, off, maxOff)
  st.aux2 = sel + 1
  hline(r.x, r.y + r.h - 1, r.w, if pal: th.frame else: th.edge)
  var x = r.x + dp(2) - off
  pushClip(strip)
  if accessOn: accessBegin(arTabList, "", r, accessSubId(id, 7777), takesLabel = true)
  for i, l in labels:
    let tw = widths[i]
    if x + tw < strip.x or x > strip.x + strip.w:
      x += tw
      continue
    let up = i == sel
    let tr = if up: rect(x, r.y, tw, r.h) else: rect(x, r.y + dp(2), tw, r.h - dp(2))
    let tabId = id + uint32(i * 2 + 1)
    let hit = interact(tabId, tr, focusable = false, enabled = enabled)
    let xr = rect(tr.x + tr.w - xw - dp(2), tr.y, xw, tr.h)
    if hit.down and ui.pressed: ui.focus = id      # the strip takes the keys
    if live and ui.active == tabId and ui.mouseDown and not ui.pressed and result.moved.a < 0:
      # dragged: out of the strip (torn off), or past a neighbor's middle (moved)
      if abs(ui.my - (r.y + r.h div 2)) > r.h + dp(16):
        result.tornOff = i
        ui.active = 0
      elif i > 0 and ui.mx < x - widths[i - 1] div 2:
        result.moved = (i, i - 1)
        ui.active = id + uint32((i - 1) * 2 + 1)
      elif i < n - 1 and ui.mx > x + tw + widths[i + 1] div 2:
        result.moved = (i, i + 1)
        ui.active = id + uint32((i + 1) * 2 + 1)
      if result.moved.a >= 0 or result.tornOff >= 0: ui.redraw = true
    if accessOn:
      let k = accessNode(arTab, l, id = tabId, r = tr,
                         states = accessOff(enabled) + (if up: {asSelected} else: {}))
      accessItem(k, i + 1, n)
      if up and ui.focus == id: accessFocus(k)
      if closable:
        let cid = accessSubId(tabId, 0)
        if accessPress != 0 and accessPress == cid and enabled:
          accessPress = 0
          result.closed = i
        accessNode(arButton, "Close " & plainName(l), id = cid, r = xr, states = accessOff(enabled))
    if hit.clicked:
      if closable and xr.contains(point(ui.mx, ui.my)) and accessPressed != tabId: result.closed = i
      elif sel != i:
        sel = i
        result.selected = true
    if live and mouseIn(tr) and mouseIn(strip):
      if closable and middleClicked(tr): result.closed = i
      if ui.rpressed:
        result.menu = i
        ui.focus = id
    if dropKind.len > 0:
      case dropTarget(tr, dropKind)
      of dsOver:
        if tabSpring.id != id or tabSpring.tab != i:
          tabSpring = (id, i, ui.now)
        elif ui.now - tabSpring.since > 600 and sel != i:
          sel = i
          result.selected = true
        wakeIn(100)
      of dsDropped: result.dropOn = i
      else: discard
    var ink = if enabled: th.text else: th.gray
    if pal:
      # (a palette's tabs, as the docked panels': the chosen one gray and
      # joined to the panel, the others dark behind it)
      let k = paletteTabFace(tr, up, hit.showsHover)
      if enabled: ink = k
    else:
      let behind = if lumaOfColor(th.face) == lumaOfColor(th.window): mixColor(th.face, th.light, 0.45)
                   else: th.face            # (a dark theme's tabs behind: lifted from the black)
      let bg = if up: th.window elif hit.showsHover: hoverColor() else: behind
      fill(inset(tr, 1), bg)
      hline(tr.x + 2, tr.y, tr.w - 4, th.edge)
      vline(tr.x, tr.y + 2, tr.h - 2, th.edge)
      vline(tr.x + tr.w - 1, tr.y + 2, tr.h - 2, th.edge)
      if up: hline(tr.x + 1, tr.y + tr.h - 1, tr.w - 2, th.window)
    # the glyph and the label centered in the room left of the x, whether
    # the label is bold (the chosen tab) or not
    let tst = if pal: lst else: style(bold = up)
    let lh = lineHeight(tst)
    let ty = tr.y + (tr.h - lh) div 2
    let roomL = tr.x + (if pal: dp(6) else: dp(8))
    let roomR = tr.x + tr.w - xw - (if pal: dp(2) else: dp(6))
    let gw = if i < glyphs.len and glyphs[i].len > 0: textWidth(glyphs[i]) + dp(6) else: 0
    let shown = ellipsize(l, max(0, roomR - roomL - gw), tst)
    var tx = if pal: roomL else: roomL + max(0, (roomR - roomL - gw - textWidth(shown, tst)) div 2)
    pushClip(rect(tr.x + 1, tr.y, tr.w - xw - dp(4), tr.h))
    if gw > 0:
      text(tx, ty, glyphs[i], ink)
      tx += gw
    text(tx, ty, shown, ink, tst)
    if up and ui.focus == id:
      focusDots(rect(tx - 2, ty - 1, textWidth(shown, tst) + 4, lh + 2))
    popClip()
    if closable:
      let overX = canInput() and canHover() and mouseIn(xr)
      if glassLook():
        # (Glass: a round spot under the pointer, the x in the label's gray)
        let d = min(xr.w, tr.h) - dp(6)
        if overX: disc(float(xr.x) + float(xr.w) / 2, float(tr.y) + float(tr.h) / 2, float(d) / 2,
                       withAlpha(th.text, if onDark(): 40 else: 22))
        text(xr.x + (xr.w - textWidth(nfTimes)) div 2, tr.y + (tr.h - FontH) div 2, nfTimes,
             if overX: th.text else: mixColor(th.text, th.window, 0.45))
      else:
        if overX: fill(inset(xr, dp(3)), if pal and not up: th.gray else: th.face)
        text(xr.x + (xr.w - textWidth(nfTimes)) div 2, tr.y + (tr.h - FontH) div 2, nfTimes,
             if overX: th.text elif pal and not up: th.light else: th.gray)
    if result.dropOn == i or (dragging(dropKind) and dropKind.len > 0 and
                              tabSpring.id == id and tabSpring.tab == i and
                              mouseIn(tr)):
      dropHighlight(tr)
    x += tw
  popClip()
  if accessOn: accessEnd()
  # the arrows (scrolling) and the + button
  var bx = strip.x + strip.w + dp(2)
  if over:
    for (d, delta) in [(dLeft, -1), (dRight, 1)]:
      let ar = rect(bx, r.y + dp(3), arrowW - dp(2), r.h - dp(6))
      let can = if delta < 0: off > 0 else: off < maxOff
      let h = interact(id + uint32(200 + delta), ar, focusable = false, enabled = enabled and can)
      buttonFace(ar, h.down, rounded = false, bevel = 1, hot = can and h.showsHover)
      let o = if h.down: 1 else: 0
      arrow(ar.x + ar.w div 2 + o, ar.y + ar.h div 2 + o, d, if can: th.frame else: th.gray)
      if h.clicked: scrollBy(id + 97, off, delta * max(dp(80), room div 2), maxOff)
      if h.down and heldFor() > 400:                       # held: keeps going
        scrollStop(id + 97)
        off = clamp(off + delta * dp(8), 0, maxOff)
        wakeIn(30)
      bx += arrowW
  if addButton:
    let ax = if over: bx else: min(x + dp(2), r.x + r.w - addW)
    # (with fingers as tall as the strip, and as wide)
    let m = if fingers(): dp(1) else: dp(3)
    let plusR = rect(ax, r.y + m, addW - (if fingers(): dp(2) else: dp(4)), r.h - 2 * m)
    # (an id of its own: the strip's is its stop of Tab, the tabs' focus)
    let pid = id + 300'u32
    let hit = interact(pid, plusR, focusable = false, enabled = enabled)
    if accessOn: accessNode(arButton, tr("New tab"), id = pid, r = plusR, states = accessOff(enabled))
    buttonFace(plusR, hit.down, bevel = 1, hot = hovered(plusR))
    text(plusR.x + (plusR.w - textWidth(nfPlus)) div 2, plusR.y + (plusR.h - FontH) div 2, nfPlus,
         th.text)
    if hit.clicked: result.added = true
  # a double click on the empty part of the strip: a new tab
  if addButton and live and ui.pressed and ui.clicks >= 2 and mouseIn(r) and
     not ui.pressUsed and x < r.x + r.w and ui.mx > x and ui.mx < strip.x + strip.w:
    ui.pressUsed = true
    result.added = true
  st.scrollX = off
  state(id + 97) = st
  # the strip is a stop for Tab (the arrow keys then move between tabs)
  if enabled: discard tabStop(id, r)
  ui.lastId = id
  ui.lastRect = r

template tabs*(sel: var int; labels: openArray[string]; body: untyped) =
  ## Tabs bound to `sel`; draw the page for `sel` in `body`.
  beginTabs(sel, labels)
  body
  endTabs()

template tabs*(sel: var int; labels: openArray[string]; sameHeight: bool;
               body: untyped) =
  ## Tabs whose page keeps the height of the tallest one shown so far
  ## (property sheets, settings dialogs).
  beginTabs(sel, labels, sameHeight)
  body
  endTabs()

var scrollStack: seq[tuple[id: Id; r: Rect; framed: bool]]
var
  dlgClient: Rect      ## the dialog being drawn: its client area
  dlgTall: bool        ## ... scrolls

proc beginScroll*(height: int; key = ""; framed = true) =
  ## A framed area whose content scrolls (`key` tells several apart);
  ## `height` 0 or less: down to the bottom of the pane or window. Not
  ## `framed`: on the background it is in (a tab's page, a dialog), its
  ## scroll bar shown only when the content is taller.
  let r = place(0, (if height <= 0: remainingH() else: height), fill = true)
  let id = makeId(fnv("scroll-panel" & key))
  let st = state(id)
  if framed: fieldFrame(r)
  let inner = rect(r.x + 1, r.y + 1, r.w - SbW, r.h - 2)
  pushClip(inner)
  scrollStack.add (id, r, framed)
  ui.focusRect = rect(0, 0, 0, 0)
  beginClipped()
  pushFrame(rect(inner.x + Pad, inner.y + Pad - st.scrollY,
                 inner.w - 2 * Pad, 0))

proc endScroll*() =
  ## Ends a `beginScroll`: its scroll bar, the wheel, a finger, and Tab
  ## into a widget out of view.
  let ch = popFrame() + 2 * Pad
  endClipped()
  popClip()
  let (id, r, framed) = scrollStack.pop()
  var st = state(id)
  let maxY = max(0, ch - (r.h - 2))
  var y = clamp(st.scrollY, 0, maxY)
  scrollWheel(id, y, maxY, r, 3 * ItemH)
  scrollPan(id, y, maxY, r)
  scrollTick(id, y, maxY)
  # Tab into a widget out of view scrolls it into view (one a screen
  # reader asks to see too).
  let f = wantSeen()
  if f.w > 0:
    if f.y < r.y + 1: y = clamp(y - (r.y + 1 + Pad - f.y), 0, maxY)
    elif f.y + f.h > r.y + r.h - 1:
      y = clamp(y + (f.y + f.h + Pad - (r.y + r.h - 1)), 0, maxY)
  if framed or maxY > 0:
    scrollBarFor(id + 9, id, rect(r.x + r.w - SbW, r.y, SbW, r.h), true, y,
                 maxY, max(ItemH, r.h - 2 - ItemH), ItemH)
  if y != st.scrollY:
    st.scrollY = y
    ui.redraw = true
  state(id) = st

template scrollPanel*(height: int; body: untyped) =
  ## A framed area of `height` pixels whose content scrolls (-1: down to
  ## the bottom).
  beginScroll(height)
  body
  endScroll()

var panelStack: seq[tuple[id: Id; inner: Rect; top, reveal: int; glide: bool]]

proc overlayBars*(): bool =
  ## A page's scroll bar is a thin line over its content, taking no room, as phones show it:
  ## the newer looks on a touch screen (the finger moves the page).
  glassLook() and ui.touch

proc scrollLine*(r: Rect; y, maxY: int; alpha = 1.0) =
  ## The thin scroll bar of `overlayBars`: a rounded line along the right of `r`, as long as the
  ## part of the content in view, where it is (`alpha`: how much of it shows).
  if maxY <= 0 or r.h <= 0 or alpha <= 0: return
  let total = r.h + maxY
  let len = max(dp(24), r.h * r.h div total)
  let top = r.y + dp(2) + (r.h - dp(4) - len) * y div maxY
  let w = max(2, dp(3))
  roundRect(rect(r.x + r.w - w - dp(2), top, w, len), float(w) / 2,
            if onDark(): withAlpha(white, int(110 * alpha)) else: withAlpha(black, int(100 * alpha)))

type ScrollHint = object
  frame, shownAt, lastY, lastMax: int

var scrollHints: Table[Id, ScrollHint]

proc scrollHint*(id: Id; r: Rect; y, maxY: int; line = true) =
  ## On a touch screen, as phones say there is more to see: the thin scroll line flashed when the
  ## page comes up (or grows) with more than shows, shown while it moves, fading a second after;
  ## a hairline with a soft shadow under the top edge once the content has gone up under it.
  ## (`overlayBars` pages call it; a scroller of your own may, `line` false when it draws its own.)
  var h = scrollHints.getOrDefault(id)
  if h.frame < ui.frameNo - 1 or y != h.lastY or maxY > h.lastMax: h.shownAt = ui.now   # (come up, moved, grown)
  h.frame = ui.frameNo
  h.lastY = y
  h.lastMax = maxY
  scrollHints[id] = h
  if maxY > 0 and y > 0:
    # (the edge content went under: a hairline, a soft shadow below it)
    let c = if onDark(): black else: color(0, 0, 0)
    hline(r.x, r.y, r.w, withAlpha(c, if onDark(): 120 else: 46))
    for k in 1 .. max(2, dp(3)):
      hline(r.x, r.y + k, r.w, withAlpha(c, max(4, (if onDark(): 60 else: 22) - 7 * k)))
  if line and maxY > 0:
    let age = ui.now - h.shownAt
    let a = if age < 1000: 1.0 elif age < 1400: 1 - float(age - 1000) / 400 else: 0.0
    scrollLine(r, y, maxY, a)
    if a > 0: wakeIn(if age < 1000: 1000 - age + 16 else: 33)

# ---- touch: the ends stretched, pull to refresh, the fast-scroll thumb ---------------------------

type PanelPull = object
  ## (a panel's stretch on a touch screen: pulled past its top or its end, as a phone's page)
  tracking, moved: bool     # the finger down in it; past the slop
  startY, lastY: int
  off: float                # > 0: pulled down at the top; < 0: up at the end (pixels)
  vel: float                # how fast `off` moves as it springs (pixels a millisecond)
  t: int                    # when it last sprang back a step
  wants: bool               # `pullRefresh` this frame: let go far enough asks for fresh content
  refreshing: bool          # ... and it is being fetched: held open, a spinner in it
  fired: bool               # let go past the threshold: true once to the app
  frame: int                # the frame it was last drawn in

var panelPulls: Table[Id, PanelPull]

template PullAt: int = dp(64)          # (how far a pull asks for fresh content)

proc stretched*(): bool =
  ## The ends of panels stretch under the finger and spring back, as on phones: a touch screen.
  ui.touch

proc pullRefresh*(refreshing: bool): bool =
  ## Inside a panel (right after `beginPanel`), on a touch screen: pulling its content down from
  ## the top and letting go past a threshold asks for fresh content -- true once, with a tap felt.
  ## While `refreshing` is true it stays pulled open a little, a spinner turning in the room, and
  ## closes when it is false again. (Elsewhere: false, nothing drawn.)
  if panelStack.len == 0 or not stretched(): return false
  let (id, inner, _, _, _) = panelStack[^1]
  var ps = panelPulls.getOrDefault(id)
  ps.wants = true
  ps.refreshing = refreshing
  result = ps.fired
  ps.fired = false
  panelPulls[id] = ps
  let room = int(ps.off)
  if room <= dp(4) and not refreshing: return
  # the spinner in the room the pull opened, over the content's top
  let d = dp(26)
  let cx = inner.x + inner.w div 2
  let cy = inner.y + max(d div 2 + dp(4), room div 2)
  pushClip(rect(inner.x, inner.y, inner.w, max(room, 0)))
  if glossLook() and not refreshing and room < PullAt:
    # (Gloss: iOS 6's drop -- a gray bead with the turning arrow on it, its foot drawn out
    # thinner the further it is pulled, until it lets go at the threshold)
    let t = clamp(float(room) / float(PullAt), 0, 1)
    let r0 = float(dp(15)) * (1 - 0.3 * t)
    let r1 = float(dp(15)) * (1 - 0.78 * t)
    let x = float(cx)
    let y0 = float(inner.y + dp(6)) + r0
    let y1 = max(y0, float(inner.y + room - dp(6)) - r1)
    proc drop(g: float): seq[(float, float)] =
      for i in 0 .. 20:
        let a = PI + PI * float(i) / 20          # (the top half of the head)
        result.add (x + cos(a) * (r0 + g), y0 + sin(a) * (r0 + g))
      for i in 0 .. 20:
        # (the lower half: from the head's width at its middle down to the foot, narrowing)
        let a = PI * float(i) / 20
        let w = (r1 + g) + (r0 - r1) * (1 - sin(a))
        result.add (x + cos(a) * w, y0 + sin(a) * (y1 - y0 + r1 + g))
    let slate = if onDark(): color(120, 126, 138) else: glossTint(color(146, 154, 167))
    polygon(drop(1.0), mixColor(slate, black, 0.35))
    polygonShaded(drop(0.0), mixColor(slate, white, 0.3), slate)
    let gs = style(size = r0 / float(FontH) * 1.25)
    let gx = int(x) - textWidth(nfRefresh, gs) div 2
    let gy = int(y0) - lineHeight(gs) div 2
    text(gx, gy - 1, nfRefresh, withAlpha(black, 70), gs)
    text(gx, gy, nfRefresh, white, gs)
    popClip()
    wakeIn(16)
    return
  let ink = if onDark(): withAlpha(white, 200) else: withAlpha(black, 150)
  let spokes = 12
  let turn = if refreshing: (ui.now div 80) mod spokes else: 0
  let shown = if refreshing: spokes else: clamp(int(float(spokes) * float(room) / float(PullAt)), 0, spokes)
  for k in 0 ..< shown:
    let a = float(k) * 2 * PI / float(spokes) - PI / 2
    let fade = if refreshing: 60 + 195 * ((k - turn + spokes) mod spokes) div spokes else: 220
    let (r0, r1) = (float(d) * 0.22, float(d) * 0.48)
    thickLine(float(cx) + cos(a) * r0, float(cy) + sin(a) * r0, float(cx) + cos(a) * r1,
              float(cy) + sin(a) * r1, float(max(2, dp(2))), withAlpha(ink, fade))
  popClip()
  if refreshing: wakeIn(80)

proc pullStep(id: Id; inner: Rect; y: var int; maxY: int) =
  ## (endPanel's: the finger's pull past either end -- a pan up or down begun in it, no widget
  ## dragging by itself, no scroller inside it taking the gesture --, the spring back after it)
  var ps = panelPulls.getOrDefault(id)
  ps.frame = ui.frameNo
  let mine = finger() and ui.mouseDown and ui.panAlong == 2 and not ui.dragsActive and
             inner.contains(ui.panFrom) and (ui.panOwner == 0 or ui.panOwner == uint32(id))
  if mine:
    ps.tracking = true
    let d = float(-ui.panY)                   # (down: more than 0)
    let most = float(inner.h) * 0.4
    if y <= 0 and (d > 0 or ps.off > 0):
      # (past the top: held back more the further it goes; moved back first when it turns)
      if d > 0: ps.off += d * 0.55 * max(0.1, 1 - ps.off / most)
      else: ps.off = max(0, ps.off + d)
      y = 0
    elif y >= maxY and (d < 0 or ps.off < 0):
      if d < 0: ps.off += d * 0.55 * max(0.1, 1 + ps.off / most)
      else: ps.off = min(0, ps.off + d)
      y = maxY
  elif ps.tracking and not ui.mouseDown:
    # let go: past the threshold with `pullRefresh`, fresh content asked for
    ps.tracking = false
    ps.vel = 0
    if ps.wants and ps.off >= float(PullAt):
      ps.fired = true
      ps.refreshing = true
      if touchFeel != nil: touchFeel(5)
    ps.t = ui.now
  if not mine:
    # a flick that ran into an end goes on past it as far as its speed takes it, and comes
    # back (as phones' pages bounce): the speed handed to the spring
    let hit = flingHitEnd(id)
    if hit != 0 and maxY > 0:
      ps.vel = clamp(-hit, -2.5, 2.5)
      ps.t = ui.now - 16
  let goal = if ps.wants and (ps.refreshing or ps.fired): float(PullAt) * 0.75 else: 0.0
  if not ps.tracking and (ps.off != goal or ps.vel != 0):
    # (springing back -- to the spinner's room while it refreshes --: a spring damped just
    # enough not to swing past, in steps of a few milliseconds)
    if ps.t == 0: ps.t = ui.now - 16
    var dt = float(max(1, min(50, ui.now - ps.t)))
    ps.t = ui.now
    const w = 1 / 75.0                      # (its stiffness: back in about 0.4 s)
    while dt > 0:
      let h = min(dt, 4.0)
      let acc = -w * w * (ps.off - goal) - 2 * w * ps.vel
      ps.vel += acc * h
      ps.off += ps.vel * h
      dt -= h
    if abs(ps.off - goal) < 0.5 and abs(ps.vel) < 0.01:
      ps.off = goal
      ps.vel = 0
    if ps.off != goal or ps.vel != 0: wakeIn(16)
  elif ps.tracking: wakeIn(16)
  ps.wants = false
  if ps.off == 0 and ps.vel == 0 and not ps.tracking and not ps.fired and not ps.refreshing:
    panelPulls.del(id)
  else: panelPulls[id] = ps

type FastThumb = object
  shownAt: int              # (when the list last moved: the thumb shows for a while after)
  lastY: int
  grab: int                 # dragged: where in the thumb it was taken (-1: not dragged)

var fastThumbs: Table[Id, FastThumb]

proc fastScroll(id: Id; r: Rect; y: var int; maxY: int): bool =
  ## (a long page's thumb on a touch screen, as phones have it: shown while it moves, a pill at
  ## the right a finger drags to go anywhere at once; true while it is dragged)
  var ft = fastThumbs.getOrDefault(id, FastThumb(grab: -1))
  if y != ft.lastY:
    ft.lastY = y
    ft.shownAt = ui.now
  let tw = dp(6)
  let th = dp(44)
  let span = max(1, r.h - th - dp(8))
  let top = r.y + dp(4) + span * y div maxY
  let hitR = rect(r.x + r.w - dp(30), top - dp(6), dp(30), th + dp(12))
  let shown = ft.grab >= 0 or ui.now - ft.shownAt < 1500
  if shown and canInput() and ui.pressed and hover(hitR) and takePress():
    ft.grab = ui.my - top
    if touchFeel != nil: touchFeel(5)
  if ft.grab >= 0:
    if ui.mouseDown:
      y = clamp((ui.my - ft.grab - r.y - dp(4)) * maxY div span, 0, maxY)
      ft.shownAt = ui.now
      ft.lastY = y
      result = true
    else: ft.grab = -1
  let age = ui.now - ft.shownAt
  if shown:
    # (fading out after it stopped)
    let a = if ft.grab >= 0 or age < 1100: 1.0 else: max(0.0, 1 - float(age - 1100) / 400)
    let base = if onDark(): white else: color(60, 60, 64)
    let pill = rect(r.x + r.w - tw - dp(4), top, tw + (if ft.grab >= 0: dp(2) else: 0), th)
    roundRect(pill, float(pill.w) / 2, withAlpha(base, int(170 * a)))
    if age < 1500: wakeIn(40)
  fastThumbs[id] = ft

proc beginPanel*(height = -1; key = ""; plain = false) =
  ## Starts a `panel`: a framed white area (as a list's) whose content sits
  ## `Pad` in from every side and scrolls when it is taller, with a scroll
  ## bar only then. `height` -1: down to the bottom of the pane or window.
  ## `plain`: no frame, no white (a `pane`: the dialog's own face).
  let r = place(0, (if height <= 0: remainingH() else: height), fill = true)
  let id = makeId(fnv("panel" & key))
  let st = state(id)
  if not plain:
    fill(r, th.window)
    fieldFrame(r)
  let inner = if plain: rect(r.x - Pad + 1, r.y - Pad + 1, r.w + 2 * Pad - 2, r.h + 2 * Pad - 2)
              else: rect(r.x + 2, r.y + 2, r.w - 3, r.h - 3)
  let over = st.aux != 0                     # (it was taller last frame)
  let y = if over: st.scrollY else: 0
  # (pulled past an end on a touch screen: the content follows the finger, held back)
  let pull = if id in panelPulls: int(panelPulls[id].off) else: 0
  pushClip(inner)
  beginClipped()
  ui.focusRect = rect(0, 0, 0, 0)
  panelStack.add (id, inner, inner.y + Pad - y, -1, true)
  pushFrame(rect(inner.x + Pad, inner.y + Pad - y + pull,
                 inner.w - 2 * Pad - (if over and not overlayBars(): SbW else: 0), inner.h - 2 * Pad))

proc endPanel*() =
  ## Ends a `beginPanel`.
  let ch = popFrame() + 2 * Pad
  endClipped()
  popClip()
  let (id, inner, _, reveal, glide) = panelStack.pop()
  var st = state(id)
  let maxY = if ch - inner.h > dp(2): ch - inner.h else: 0
  var y = clamp(st.scrollY, 0, maxY)
  if reveal >= 0:
    let goal = clamp(reveal, 0, maxY)
    if not glide:
      scrollStop(id)
      y = goal
    elif scrollTarget(id, y) != goal: scrollTo(id, y, goal, maxY)
  var thumbHeld = false
  if maxY > 0 and overlayBars() and maxY > 2 * inner.h:
    thumbHeld = fastScroll(id + 41, inner, y, maxY)       # (a long page: its fast-scroll thumb)
  if maxY > 0 and not thumbHeld:
    scrollWheel(id, y, maxY, inner, 3 * ItemH)
    scrollPan(id, y, maxY, inner)
    scrollTick(id, y, maxY)
    let f = wantSeen()                        # Tab to a widget out of view
    if f.w > 0:
      if f.y < inner.y: y = clamp(y - (inner.y + Pad - f.y), 0, maxY)
      elif f.y + f.h > inner.y + inner.h:
        y = clamp(y + (f.y + f.h + Pad - (inner.y + inner.h)), 0, maxY)
  if stretched() and not thumbHeld: pullStep(id, inner, y, maxY)
  if maxY > 0:
    if overlayBars(): scrollHint(id + 43, inner, y, maxY, line = maxY <= 2 * inner.h)
    else:
      scrollBarFor(id + 9, id, rect(inner.x + inner.w - SbW, inner.y, SbW, inner.h), true,
                   y, maxY, max(ItemH, inner.h - ItemH), ItemH)
  let over = ord(maxY > 0)
  if y != st.scrollY or over != st.aux:
    st.scrollY = y
    st.aux = over
    ui.redraw = true
  state(id) = st

proc revealInPanel*(r: Rect; glide = true) =
  ## Inside a `panel` (or `pane`): scrolls it so that `r` (drawn this frame)
  ## comes to its top, or as near as it can: a message picked in a
  ## conversation, a heading jumped to. `glide` false: at once.
  if panelStack.len == 0: return
  let p = addr panelStack[^1]
  p.reveal = r.y - p.top
  p.glide = glide

template panel*(body: untyped) =
  ## A framed white area down to the bottom, its content `Pad` in from
  ## every edge, scrolling (with a scroll bar) only when it is taller: the
  ## page of an app beside a tree or a list, as in File Manager.
  beginPanel()
  body
  endPanel()

template panel*(height: int; body: untyped) =
  ## `panel` `height` pixels high.
  beginPanel(height)
  body
  endPanel()

# ---- rows in view -------------------------------------------------------------------------------

type RowsMemo = ref object
  pitch: int              ## same height: a row's height and the gap after it, as drawn
  heights: seq[int32]     ## varying: each row's, when it was last drawn (0: not yet)

var rowsMemo: Table[Id, RowsMemo]

iterator visibleRows*(n: int; rowH = -1; key = ""; varying = false): int =
  ## The rows `0 ..< n` that are in view, to draw in the loop's body: in a
  ## `panel`, `scrollPanel`, `pane` or the page, a list you draw yourself
  ## costs what is on the screen, not its length (3,000 labels, a release
  ## build: 1.5 ms a frame drawn all, under 0.1 ms so; `tests/test_rows.nim`
  ## measures it). The others keep their room, so
  ## the scroll bar and what comes after are where they would be.
  ##
  ## Each row is what the body places in the column for its index, the same
  ## height each (`rowH`: its cells' height, `ItemH` when -1; measured as
  ## drawn) or, `varying`, its own -- text that wraps, a message with a
  ## picture: each row's is kept from the last time it was drawn, `rowH`
  ## guessed for those not drawn yet. `key` tells several lists apart.
  ## Rows not drawn take no focus, no Tab stop; never `break` out of it (the
  ## room of the rows after would be lost). In a `row` it draws them all.
  ##
  ## .. code-block:: nim
  ##   panel:
  ##     for i in visibleRows(lines.len, key = "log"):
  ##       withId(i): label(lines[i])
  let est = (if rowH > 0: rowH else: ItemH) + Gap
  if n > 0 and not inColumn():
    for i in 0 ..< n: yield i
  elif n > 0:
    let id = makeId(fnv("visible-rows" & key))
    var m = rowsMemo.getOrDefault(id)
    if m == nil:
      m = RowsMemo()
      rowsMemo[id] = m
    # (a row's height is kept until it is drawn again: wider or narrower,
    # the rows in view are measured anew, the others as they were)
    let clip = clipRect()
    let top0 = layoutY()
    var changed = false
    if not varying:
      let p = if m.pitch > 0: m.pitch else: est
      let first = clamp((clip.y - top0) div p, 0, n)
      let last = if clip.y + clip.h <= top0: -1
                 else: min(n - 1, (clip.y + clip.h - top0 - 1) div p)
      skipDown(first * p)
      for i in first .. last:
        let y0 = layoutY()
        yield i
        let got = layoutY() - y0
        if i == first and got > 0 and got != m.pitch:   # (the first one's: all alike)
          m.pitch = got
          changed = true
      skipDown((n - max(last + 1, first)) * p)
    else:
      if m.heights.len != n: m.heights.setLen(n)
      var y = top0
      var i = 0
      while i < n:                        # (the rows above the view: room only)
        let h = if m.heights[i] > 0: int(m.heights[i]) else: est
        if y + h - Gap > clip.y: break
        y += h
        inc i
      skipDown(y - top0)
      while i < n and layoutY() < clip.y + clip.h:
        let y0 = layoutY()
        yield i
        let got = layoutY() - y0
        if got > 0 and got != int(m.heights[i]):
          if m.heights[i] != 0 or got != est: changed = true
          m.heights[i] = int32(got)
        inc i
      var rest = 0
      while i < n:
        rest += (if m.heights[i] > 0: int(m.heights[i]) else: est)
        inc i
      skipDown(rest)
    # (a guess that was wrong: once more, where the rows really are)
    if changed: ui.redraw = true

template pane*(height: int; body: untyped) =
  ## An area `height` pixels high on the dialog's face (no frame) whose
  ## content scrolls when it is taller: the pages of a dialog that keeps its
  ## size (Preferences).
  beginPanel(height, plain = true)
  body
  endPanel()

# ---- menus ------------------------------------------------------------------

const MenuShadeN = 4      # (Glass: the soft shadow under a menu, in so many fills)

type PopMenu = object
  id: Id
  x, y, w, cy: int
  n, bg, measured, level: int
  shade: int        ## (Glass: the first of the soft shadow's fills, under its face)
  subAt: int        ## index of the item whose submenu is open, or -1
  colX: int         ## the column being filled (a menu taller than the screen
                    ## breaks into columns, as 3.1's long menus did)
  cols: int         ## how many columns so far
  bottom: int       ## the lowest a row may reach
  maxCy: int        ## the longest column's end
  natural: int      ## the height of the rows in one column
  mark: int         ## where its drawing starts (`cmdMark`)
  fixedTop: bool    ## a menu bar's (it stays under its title)
  letters: seq[char]  ## each item's underlined letter ('\0': none, or disabled)
  arrowX: int       ## (Gloss: where its arrow points up at its title; 0: none)

var
  menuLetters: Table[Id, seq[char]]
    ## (each open menu's items' letters, as the last frame drew them: a
    ## letter two items have lights the next of them, as Windows' menus do)
  barX: int
  barIds: seq[Id]
  barRow: int                    # (the menu bar's row the next title goes on)
  barRowsOf: array[bool, int] = [1, 1]
    ## (its rows last frame, the app's window's and a window's of its own:
    ## the menus wrap on a narrow screen)
  menuSwitch: int
  pms: seq[PopMenu]  ## the open menu, and its open submenus (one in another)
  lastPopup: Id
  waitSince: int

const MenuDepth = 4
  ## (a menu and the submenus open one in another: four deep at most)

var
  subIds: array[MenuDepth, Id]
    ## (the submenu each open menu has open, by the menu's level: 0 the menu's own)
  subHis: array[MenuDepth, int] = [-1, -1, -1, -1]   ## (... the item lit in it)
  subSpans: array[MenuDepth, tuple[a, b: int]] = [(-1, -1), (-1, -1), (-1, -1), (-1, -1)]
    ## (... its drawing, put over its menu's)
  subRects: array[MenuDepth, Rect]                   ## (... where it was drawn)
  aims: array[MenuDepth, tuple[x, y: int]]
    ## (where the pointer was last frame, by the menu's level: on its way to its submenu?)
  waitRows: array[MenuDepth, int] = [-1, -1, -1, -1]
    ## (the row the pointer rests on while the submenu stays open, by the menu's level)

proc closeSubs(level: int) =
  ## (the submenus open from the menu at `level` -- and those in them -- closed)
  for j in max(0, level) ..< MenuDepth: subIds[j] = 0

proc openSub(level: int; id: Id; hi: int) =
  ## (the menu at `level` opens its submenu `id`, item `hi` of it lit; one in it closes)
  subIds[level] = id
  subHis[level] = hi
  closeSubs(level + 1)
  ui.redraw = true

const SubMenuRest = 300
  ## (ms the pointer, on its way to an open submenu, may rest on another
  ## row before that row takes over; moving any other way, it does at once)

template pm: untyped = pms[^1]

template MenuRowH: int =
  ## A row of a drop-down menu: roomy as on the Win31 desktop (finger-sized
  ## on touch screens).
  (if fingers(): ItemH + 2 else: max(ItemH + 2, dp(21)))

proc hiOf(level: int): var int =
  if level == 0: return ui.popupHi
  return subHis[clamp(level - 1, 0, MenuDepth - 1)]

# ---- the menus walked, not drawn: what the command search lists (retroui/commandhud) ----------

type MenuCommand* = tuple[path: seq[string]; keys: string; enabled, checked: bool]
  ## An item of the menu bar's menus: its menus and its label (no '&'), its shortcut, whether it
  ## can be chosen now, whether it is checked.

var
  menuWalk*: bool
    ## This frame the menu bar's menus are walked, not drawn: each item noted in `menuWalked`
    ## (set before the menu bar by `menubarHooks.before`: the command search's).
  menuWalked*: seq[MenuCommand]
    ## The items the walk found, in the menus' order.
  menuWalkRun*: seq[string]
    ## An item to choose (its menus and label, as `menuWalked` has it): the walk's `menuItem`
    ## for it returns true, as a click would, and this is emptied.
  menubarHooks*: tuple[before, after: proc () {.nimcall.}]
    ## Called as the menu bar begins (before its menus) and as it ends (after them).
  walkDepth: int                  # (how deep in the menus the walk is: 0 not walking)
  walkPath: seq[string]

proc walkItem(label, shortcut: string; checked, enabled: bool): bool =
  var path = walkPath
  path.add splitMnemonic(label).text
  if menuWalkRun.len > 0 and enabled and menuWalkRun == path:
    menuWalkRun.setLen(0)
    result = true
  menuWalked.add (path, shortcut, enabled, checked)

proc beginMenubar*() =
  ## Starts the menu bar (see `menubar`).
  pushLayer(LayerBase)              # above the scrolled content, unclipped
  # (as many rows as its menus took last frame: on a phone they wrap)
  let barRows = barRowsOf[inWindow()]
  let r = rect(ui.winX, ui.barY, ui.w, MenuH * barRows)
  if glossLook():
    # (Gloss: a bar lit from above in the scheme's hue, as a tool bar was then)
    glossBarFill(r)
    hline(ui.winX, r.y + r.h, ui.w, withAlpha(black, 70))
  else:
    fill(r, th.window)
    hline(ui.winX, r.y + r.h, ui.w, th.edge)
  notePlaced(rect(r.x, r.y, r.w, r.h + 1))
  barX = ui.winX + ui.safe.left
  barRow = 0
  barIds.setLen(0)
  menuSwitch = 0
  shiftContent(MenuH * barRows + 1)
  if accessOn: accessBegin(arMenuBar, "", r)
  walkDepth = 0
  walkPath.setLen(0)
  if menubarHooks.before != nil: menubarHooks.before()

proc endMenubar*() =
  ## Ends the menu bar: F10 opens its first menu; Left / Right go along it.
  if accessOn: accessEnd()
  popLayer()
  walkDepth = 0
  if menubarHooks.after != nil: menubarHooks.after()
  ui.barY += MenuH * barRowsOf[inWindow()] + 1
  if barRow + 1 != barRowsOf[inWindow()]:
    barRowsOf[inWindow()] = barRow + 1   # (the rows its menus took: the bar that tall next frame)
    ui.redraw = true
  if ui.menuOpen and menuSwitch != 0 and barIds.len > 0:
    let i = barIds.find(ui.popup)
    if i >= 0:
      ui.popup = barIds[(i + menuSwitch + barIds.len) mod barIds.len]
      ui.popupHi = 0
      ui.redraw = true
  if ui.menuOpen and menuSwitch != 0: ui.popupOpened = true
  if barIds.len > 0: noteMenuBar(barIds[0])     # (F6 after the last area)
  # F10, or Alt pressed and let go alone: the first menu, its first item lit
  # (the arrows go on from there); again: closed
  let opener = (ui.key == KeyF10 and ShiftPressed notin ui.mods) or ui.altTapped
  if opener and ui.popup == 0 and barIds.len > 0 and
     ui.inputLayer == LayerBase and not ui.keyUsed:
    ui.popup = barIds[0]
    ui.menuOpen = true
    ui.popupHi = 0
    ui.popupOpened = true             # (drawn from the next frame: kept till then)
    ui.keyUsed = true
    ui.redraw = true
  elif opener and ui.menuOpen and barIds.find(ui.popup) >= 0 and not ui.keyUsed:
    ui.popup = 0
    ui.menuOpen = false
    ui.keyUsed = true
    ui.redraw = true

template menubar*(body: untyped) =
  ## The menu bar at the top of the window; call it first.
  beginMenubar()
  body
  endMenubar()

proc menuCols(st: WState; y: int; fixedTop: bool): int =
  ## (how many columns a menu opened at `y` takes, by last frame: one unless
  ## it is taller than the room it has)
  let room = if fixedTop: ui.h - dp(6) - y else: ui.h - dp(8)
  if st.caret == 0 or st.caret <= room: 1 else: max(1, st.anchor)

proc beginPopupMenu(id: Id; x, y: int; level = 0; fixedTop = false; arrowAt = -1): bool =
  ## (`fixedTop`: a menu bar's menu, which hangs from its title; `arrowAt`: Gloss's arrow
  ## points up there)
  let st = state(id)
  # (Gloss: the rows inside its frame -- under the arrow for a menu bar's menu)
  let edge = glossMenuEdge()
  let x = x + edge
  let y0 = y + edge + (if edge > 0 and arrowAt >= 0: max(6, dp(9)) else: 0)
  if level < MenuDepth: subSpans[level] = (-1, -1)
  if level == 0:
    if id != lastPopup:
      lastPopup = id
      closeSubs(0)
      for w in waitRows.mitems: w = -1
  # A menu that would pass the bottom of the screen moves up as far as it
  # needs (by last frame's height in one column); only one taller than the
  # whole screen -- or a menu bar's, which stays under its title -- goes on
  # in columns beside.
  let top = dp(2)
  let bottom = ui.h - dp(6)
  let nh = st.caret
  var y = y0
  if not fixedTop and nh > 0 and y + nh > bottom: y = max(top, bottom - nh)
  var m = PopMenu(id: id, x: x, y: y, w: max(st.aux, dp(120)), cy: y + 3,
                  level: level, subAt: -1, fixedTop: fixedTop,
                  arrowX: if edge > 0 and arrowAt >= 0: arrowAt else: 0)
  # (not measured yet: in one column -- a frame later it is in place)
  m.bottom = if nh == 0 and not fixedTop: high(int) div 4 else: bottom
  if nh > 0:
    # (in columns: of about the same height, not a full one and a stub)
    let rowsH = nh - 6
    let avail = bottom - (y + 3)
    if rowsH > avail and avail > MenuRowH:
      let cols = (rowsH + avail - 1) div avail
      let t = (rowsH + cols - 1) div cols
      m.bottom = min(bottom, y + 3 + t + MenuRowH + dp(9))
  m.cols = 1
  m.maxCy = m.cy
  let cols = menuCols(st, y, fixedTop)
  if m.x + m.w * cols + 3 + edge > ui.winX + ui.w:
    m.x = max(ui.winX + edge, ui.winX + ui.w - m.w * cols - 3 - edge)
  m.colX = m.x
  pushLayer(LayerPopup)
  m.mark = cmdMark()
  m.shade = -1
  if glassLook():
    m.shade = reserveFill()
    for k in 1 ..< MenuShadeN: discard reserveFill()
  m.bg = reserveFill()
  pms.add m
  if accessOn:
    # (its items go inside; its place is known once they are drawn)
    accessBegin(arMenu, "", rect(m.x, y, m.w, MenuRowH), accessSubId(id, 9999))
  true

proc endMenu*() =
  ## Ends an open menu (`beginMenu`, `beginSubmenu`, `beginContextMenu`,
  ## `beginPopupMenuFor`): draws its frame; Up, Down, Home, End, Esc.
  if walkDepth > 0:
    dec walkDepth
    if walkPath.len > 0: walkPath.setLen(walkPath.len - 1)
    return
  var m = pms.pop()
  if menuLetters.getOrDefault(m.id) != m.letters: menuLetters[m.id] = move m.letters
  if menuLetters.len > 64: menuLetters.clear()     # (menus opened long ago)
  let r = rect(m.x, m.y, m.w * m.cols, max(m.cy, m.maxCy) - m.y + 3)
  notePlaced(r)
  if accessOn: accessEnd(r)
  let edge = glossMenuEdge()
  let arrowH = if m.arrowX > 0: max(6, dp(9)) else: 0
  if edge > 0:
    # (Gloss: as a popover was then -- its rows on white in a dark frame in the scheme's hue,
    # lit at its top, an arrow up at the title it hangs from, a deep shadow under it)
    let fr = inset(r, -edge)
    let rad = float(dp(10))
    if m.shade >= 0:
      for k in 0 ..< MenuShadeN:
        let g = k + 1
        patchRoundRect(m.shade + k, rect(fr.x - g + 1, fr.y - g + 4, fr.w + 2 * g - 2, fr.h + 2 * g - 2),
                       rad + float(g), withAlpha(color(0, 0, 0), 30 - 6 * k), width = float(g + 3))
    patchFill(m.bg, r, th.field)
    glossPopoverFrame(r, if m.arrowX > 0: m.arrowX else: -1)
  elif glassLook():
    # (Glass: rounded, a hairline round it, a soft shadow under it -- its fills kept before its
    # face; frosted, what is under it blurred through it)
    let rad = float(dp(8))
    if m.shade >= 0:
      for k in 0 ..< MenuShadeN:
        let g = k + 1
        patchRoundRect(m.shade + k, rect(r.x - g + 1, r.y - g + 3, r.w + 2 * g - 2, r.h + 2 * g - 2),
                       rad + float(g), withAlpha(color(0, 0, 0), if onDark(): 34 - 5 * k else: 12 - 2 * k),
                       width = float(g + 3))
    if frosted(): patchBlur(m.bg, r, dp(16), withAlpha(th.window, int(frostAlpha())), rad)
    else: patchRoundRect(m.bg, r, rad, th.window)
    roundFrame(r, rad, 1, glassHair())
  else:
    patchFill(m.bg, r, th.window)
    box(r, th.edge)
    # the hard black shadow of the Win31 menus, 3 pixels down and right
    fill(r.x + 3, r.y + r.h, r.w, 3, th.frame)
    fill(r.x + r.w, r.y + 3, 3, r.h, th.frame)
  # (its place for the clicks it keeps: Gloss's frame and arrow with it)
  let pr = rect(r.x - edge, r.y - edge - arrowH, r.w + 2 * edge, r.h + 2 * edge + arrowH)
  if m.level == 0: ui.popupRectNow = rect(pr.x, pr.y, pr.w + 3, pr.h + 3)
  elif ui.popupRect2Now.w == 0: ui.popupRect2Now = rect(pr.x, pr.y, pr.w + 3, pr.h + 3)
  else:
    # (submenus one in another: the box round them all)
    let o = ui.popupRect2Now
    let x0 = min(o.x, pr.x)
    let y0 = min(o.y, pr.y)
    ui.popupRect2Now = rect(x0, y0, max(o.x + o.w, pr.x + pr.w + 3) - x0, max(o.y + o.h, pr.y + pr.h + 3) - y0)
  # (the lines between columns)
  for c in 1 ..< m.cols: vline(m.x + c * m.w, m.y + 2, r.h - 4, th.shadow)
  let lv = clamp(m.level, 0, MenuDepth - 1)
  if m.level >= 1:
    # (a submenu: where it is, for the menu it opened from)
    subSpans[lv - 1] = (m.mark, cmdMark())
    subRects[lv - 1] = rect(pr.x, pr.y, pr.w + 3, pr.h + 3)
    if subRects[lv - 1].contains(point(ui.mx, ui.my)): waitRows[lv - 1] = -1
  aims[lv] = (ui.mx, ui.my)
  if subIds[lv] == 0: subRects[lv] = rect(0, 0, 0, 0)
  if subSpans[lv].a >= 0:
    # (its submenu over the rows and frame of this menu drawn after it)
    let e = cmdMark()
    let sp = subSpans[lv]
    if sp.a < sp.b and sp.b <= e:
      reorderSpans([sp, (sp.b, e)], [1, 0])
    subSpans[lv] = (-1, -1)
  var st = state(m.id)
  let natural = m.natural + 6
  if m.measured != st.aux or r.h != st.aux2 or m.cols != st.anchor or
     natural != st.caret:
    st.aux = m.measured
    st.aux2 = r.h
    st.anchor = m.cols
    st.caret = natural
    state(m.id) = st
    ui.redraw = true
  if canInput() and not ui.keyUsed and subIds[lv] == 0:
    var hi = addr hiOf(m.level)
    case ui.key
    of KeyUp:
      hi[] = (max(0, hi[]) + m.n - 1) mod max(1, m.n)
      ui.keyUsed = true
    of KeyDown:
      hi[] = (hi[] + 1) mod max(1, m.n)
      ui.keyUsed = true
    of KeyHome:
      hi[] = 0
      ui.keyUsed = true
    of KeyEnd:
      hi[] = max(0, m.n - 1)
      ui.keyUsed = true
    of KeyLeft:
      if m.level >= 1: closeSubs(lv - 1)
      else: menuSwitch = -1
      ui.keyUsed = true
    of KeyRight:
      if m.level == 0: menuSwitch = 1
      ui.keyUsed = true
    of KeyEsc:
      if m.level >= 1: closeSubs(lv - 1)
      else:
        ui.popup = 0
        ui.menuOpen = false
      ui.keyUsed = true
    else: discard
  popLayer()

var boldMenus* = true
  ## Menus in bold, as Windows 3.1's System font drew them.

proc beginMenu*(title: string): bool =
  ## A menu of the menu bar (see `menu`): true while it is open (draw its
  ## items, then `endMenu`).
  let id = idOfLabel("menu:", title)
  let tw = labelWidth(title, boldMenus) + dp(16)
  if barX + tw > ui.winX + ui.w - ui.safe.right and barX > ui.winX + ui.safe.left:
    # (no room left on this row: the next one -- a phone's narrow screen)
    barX = ui.winX + ui.safe.left
    inc barRow
  let tr = rect(barX, ui.barY + barRow * MenuH, tw, MenuH)
  notePlaced(tr)
  barX += tr.w
  barIds.add id
  let barLive = ui.inputLayer == LayerBase or
                (ui.inputLayer == LayerPopup and ui.menuOpen)
  if barLive and tr.contains(point(ui.mx, ui.my)):
    if ui.pressed and not ui.pressUsed:
      ui.pressUsed = true
      if ui.popup == id:
        ui.popup = 0
        ui.menuOpen = false
      else:
        ui.popup = id
        ui.menuOpen = true
        ui.popupHi = -1
      ui.redraw = true
    elif ui.menuOpen and ui.popup != id and ui.popup != 0 and (ui.mouseMoved or ui.mouseDown):
      # (the pointer moved onto another menu's title: that one opens -- only
      # when it moved: a pointer resting there leaves the arrow keys free)
      ui.popup = id
      ui.popupHi = -1
      ui.redraw = true
  if barLive and ui.mnemonic != '\0' and mnemonicOf(title) == ui.mnemonic and
     not ui.keyUsed:
    ui.keyUsed = true
    ui.popup = id
    ui.menuOpen = true
    ui.popupHi = 0
    ui.redraw = true
  if accessPress != 0 and accessPress == id:
    # (a screen reader opened it)
    accessPress = 0
    ui.popup = id
    ui.menuOpen = true
    ui.popupHi = 0
    ui.redraw = true
  let open = ui.popup == id
  if accessOn:
    accessNode(arMenu, title, id = id, r = tr,
               states = {asExpandable, asFocusable} + (if open: {asExpanded} else: {}))
  let lx = tr.x + dp(8)
  if glossLook():
    # (Gloss: white titles pressed into the bar; the open one a bar button held down)
    let ty = tr.y + (MenuH - FontH) div 2
    if open: glossBarButton(rect(tr.x + dp(2), tr.y + dp(3), tr.w - dp(4), tr.h - dp(6)), true)
    elif barLive and canHover() and not ui.mouseDown and tr.contains(point(ui.mx, ui.my)):
      roundRect(rect(tr.x + dp(2), tr.y + dp(3), tr.w - dp(4), tr.h - dp(6)), float(dp(5)),
                withAlpha(white, 46))
    drawLabel(lx, ty - 1, title, withAlpha(black, 100), boldMenus)
    drawLabel(lx, ty, title, white, boldMenus)
  elif open:
    selectFill(tr)
    drawLabel(lx, tr.y + (MenuH - FontH) div 2, title, th.selectText, boldMenus)
  else:
    if barLive and canHover() and not ui.mouseDown and
       tr.contains(point(ui.mx, ui.my)):
      fill(inset(tr, 1), hoverColor())
    drawLabel(lx, tr.y + (MenuH - FontH) div 2, title, th.text, boldMenus)
  if menuWalk and walkDepth == 0:
    # (walked, not opened: its items noted)
    walkDepth = 1
    walkPath = @[splitMnemonic(title).text]
    return true
  if open: beginPopupMenu(id, tr.x, tr.y + tr.h, fixedTop = true, arrowAt = tr.x + tr.w div 2)
  else: false

template menu*(title: string; body: untyped) =
  ## A menu of the menu bar; `body` (its items) runs only while it is open.
  if beginMenu(title):
    body
    endMenu()

type MenuShown* = object
  ## What `showMenu` put aside (for `hideMenu`).
  popup: Id
  subs: array[MenuDepth, Id]
  open: bool
  hi: int
  subHis: array[MenuDepth, int]

proc showMenu*(path: openArray[string]): MenuShown =
  ## Opens the menu bar's menu `path[0]` -- and in it the submenu `path[1]`
  ## -- as if it had been clicked, for the menu bar drawn next: a designer
  ## showing the menu whose items are being set, a tour of an app. The
  ## titles are written as in `menu` and `submenu`; `hideMenu` puts back
  ## what was open.
  result = MenuShown(popup: ui.popup, open: ui.menuOpen, hi: ui.popupHi, subs: subIds,
                     subHis: subHis)
  if path.len == 0: return
  let id = peekId(fnv(path[0], fnv("menu:")))     # (the id its `menu` will take)
  ui.popup = id
  ui.menuOpen = true
  ui.popupHi = -1
  closeSubs(0)
  if path.len > 1: subIds[0] = mixId(id, fnv("sub:" & path[1]))
  subHis[0] = -1

proc hideMenu*(s: MenuShown) =
  ## What was open before `showMenu` open again.
  ui.popup = s.popup
  ui.menuOpen = s.open
  ui.popupHi = s.hi
  subIds = s.subs
  subHis = s.subHis

proc newMenuColumn() =
  ## (the open menu goes on in a column beside)
  pm.maxCy = max(pm.maxCy, pm.cy)
  pm.colX += pm.w
  inc pm.cols
  pm.cy = pm.y + 3

proc menuSlot(h: int): Rect =
  ## (where the open menu's next row goes: under the last, or at the top of
  ## a new column when it would pass the bottom of the screen)
  if pm.cy + h > pm.bottom and pm.cy > pm.y + 3 + h: newMenuColumn()
  rect(pm.colX + 1, pm.cy, pm.w - 2, h)

proc itemRow(label, shortcut: string; checked, enabled, arrowRight: bool;
             i: int): Rect =
  ## Lays out and draws one row of the open menu (its shortcut in this
  ## system's words: Cmd+S on a Mac for Ctrl+S).
  let shortcut = shortcutText(shortcut)
  result = menuSlot(MenuRowH)
  notePlaced(result)
  pm.cy += result.h
  pm.natural += result.h
  let sw = if shortcut.len > 0: textWidth(shortcut, boldMenus) + dp(24) else: 0
  pm.measured = max(pm.measured, labelWidth(label, boldMenus) + sw + dp(42))
  let r = result
  let hi = hiOf(pm.level) == i
  let gloss = glossLook()
  let c = if not enabled: th.gray elif hi: th.selectText elif gloss: th.fieldText else: th.text
  if gloss and r.y > pm.y + 4 and not hi:
    # (Gloss: a line between rows, as a list in a popover)
    hline(r.x, r.y, r.w, mixColor(th.field, th.fieldText, 0.12))
  if hi: selectFill(r)
  let ty = r.y + (r.h - FontH) div 2
  if checked and gloss:
    # (Gloss: the check mark of a list, in the scheme's hue)
    let k = float(max(dp(4), FontH div 4))
    let cx = float(r.x + dp(11))
    let cy = float(r.y + r.h div 2)
    let w = max(1.8, float(dp(2)))
    let ck = if hi: c else: glossDetail()
    thickLine(cx - k, cy, cx - k / 3, cy + k * 0.7, w, ck)
    thickLine(cx - k / 3, cy + k * 0.7, cx + k, cy - k * 0.8, w, ck)
  elif checked: pattern(r.x + dp(7), r.y + (r.h - 7) div 2, checkMark, "k", [c])
  drawLabel(r.x + dp(22), ty, label, c, boldMenus)
  if shortcut.len > 0:
    text(r.x + r.w - dp(14) - textWidth(shortcut, boldMenus), ty, shortcut, c, boldMenus)
  if arrowRight: arrow(r.x + r.w - dp(10), r.y + r.h div 2, dRight, c)

proc overSub(): bool =
  ## (the pointer is on an open submenu of this menu -- or one in it --, over this menu's rows:
  ## they leave it alone)
  for j in clamp(pm.level, 0, MenuDepth - 1) ..< MenuDepth:
    if subIds[j] != 0 and subRects[j].contains(point(ui.mx, ui.my)): return true

proc towardSub(): bool =
  ## (the pointer moving toward the open submenu: inside the triangle from
  ## where it was last frame to the submenu's near edge. The rows it crosses
  ## on the way -- another column of the menu among them -- leave it open;
  ## moving any other way, down the menu say, the row under it takes over
  ## at once, as Windows' and the Mac's menus do)
  let lv = clamp(pm.level, 0, MenuDepth - 1)
  let subRect = subRects[lv]
  let (aimX, aimY) = aims[lv]
  if subIds[lv] == 0 or subRect.w == 0 or ui.mouseDown or ui.mx == aimX: return false
  let right = subRect.x >= aimX
  if right != (ui.mx > aimX): return false
  let nx = float(if right: subRect.x else: subRect.x + subRect.w)
  let ax = float(aimX)
  let ay = float(aimY)
  if abs(nx - ax) < 1: return true
  let t = (float(ui.mx) - ax) / (nx - ax)         # (how far to that edge)
  if t <= 0: return false
  let slack = float(dp(6))
  let top = ay + (float(subRect.y) - slack - ay) * t
  let bottom = ay + (float(subRect.y + subRect.h) + slack - ay) * t
  float(ui.my) >= top and float(ui.my) <= bottom

proc rowTakesOver(i: int): bool =
  ## (row `i` under the pointer, another submenu open: true when the row
  ## takes over -- a click, a move that is not toward the submenu, a rest
  ## on the way of `SubMenuRest`; false while it heads for the submenu)
  let lv = clamp(pm.level, 0, MenuDepth - 1)
  if ui.pressed: return true
  if ui.mouseMoved:
    if not towardSub():
      waitRows[lv] = -1
      return true
    waitRows[lv] = i                      # (on its way: the rest starts again)
    waitSince = ui.now
    wakeIn(SubMenuRest)
    return false
  if waitRows[lv] != i: return false
  let left = SubMenuRest - (ui.now - waitSince)
  if left > 0:
    wakeIn(left)
    return false
  waitRows[lv] = -1
  true

proc menuKeysLive(): bool =
  ## Keys reach this menu level: a menu with an open submenu leaves them
  ## to the submenu.
  canInput() and not ui.keyUsed and subIds[clamp(pm.level, 0, MenuDepth - 1)] == 0

proc menuLetter(label: string; enabled: bool; i, level: int): bool =
  ## (the letter pressed is item `i`'s: true when it is chosen by it -- the
  ## only item with that letter; one of several: the next of them is lit
  ## instead, as in Windows, and the key taken)
  let c = if enabled: mnemonicOf(label) else: '\0'
  pm.letters.add(if c in {'a'..'z', '0'..'9'}: c else: '\0')
  if not menuKeysLive() or c == '\0' or ui.mods * {CtrlPressed, AltPressed} != {}: return
  let k = if ui.key in KeyA..KeyZ: char(ord('a') + ord(ui.key) - ord(KeyA))
          elif ui.key in Key0..Key9: char(ord('0') + ord(ui.key) - ord(Key0))
          else: '\0'
  if k != c: return
  ui.keyUsed = true
  # (the letter is the menu's, not typed in the box with the focus: its text
  # came with this frame's events, or comes with the next one's)
  if ui.typed.len > 0: ui.typed = "" else: dropKeyText = true
  let before = menuLetters.getOrDefault(pm.id)
  var same = 0
  for x in before:
    if x == c: inc same
  if same <= 1: return true
  # several: from the one lit on, the next that has it
  let n = before.len
  let at = hiOf(level)
  for step in 1 .. n:
    let j = (at + step + n) mod n
    if j >= 0 and before[j] == c:
      hiOf(level) = j
      break
  ui.redraw = true

proc menuItem*(label: string; shortcut = ""; checked = false;
               enabled = true): bool =
  ## An item of the open menu; true when chosen.
  if walkDepth > 0: return walkItem(label, shortcut, checked, enabled)
  let i = pm.n
  inc pm.n
  let level = pm.level
  let r = menuSlot(MenuRowH)
  if canInput() and not overSub():
    let lv = clamp(level, 0, MenuDepth - 1)
    if mouseIn(r) and (ui.mouseMoved or ui.mouseDown or waitRows[lv] == i):
      if subIds[lv] != 0:
        if rowTakesOver(i):
          hiOf(level) = i
          closeSubs(lv)
          ui.redraw = true
      else:
        hiOf(level) = i
    # chosen on release (not the release of the long press that opened it)
    if ui.released and mouseIn(r) and enabled and not (finger() and longPressed()):
      result = true
  if menuKeysLive():
    if hiOf(level) == i and enabled and keyHit(KeyEnter): result = true  # (an open menu's)
  if menuLetter(label, enabled, i, level): result = true
  let itemId = accessSubId(pm.id, i)
  if accessPress != 0 and accessPress == itemId and enabled:
    # (a screen reader chose it)
    accessPress = 0
    result = true
  if result:
    ui.popup = 0
    ui.menuOpen = false
    closeSubs(0)
    ui.redraw = true
  discard itemRow(label, shortcut, checked, enabled, false, i)
  if accessOn:
    let k = accessNode(arMenuItem, label, id = itemId, r = r,
                       states = offWhen(enabled) + (if checked: {asChecked} else: {}))
    if k >= 0: accessTree[k].key = shortcut
    accessItem(k, i + 1, 0)
    if hiOf(level) == i: accessFocus(k)

proc beginSubmenu*(label: string; enabled = true): bool =
  ## An item that opens a menu of its own (see `submenu`): true while it is
  ## open.
  if walkDepth > 0:
    if not enabled: return false
    inc walkDepth
    walkPath.add splitMnemonic(label).text
    return true
  let i = pm.n
  inc pm.n
  let level = pm.level
  let id = mixId(pm.id, fnv("sub:" & label))
  let r = itemRow(label, "", false, enabled, true, i)
  let lv = clamp(level, 0, MenuDepth - 1)
  let deeper = level < MenuDepth - 1               # (room for a menu in it)
  if menuLetter(label, enabled and deeper, i, level):
    # (its letter: it opens, its first item lit)
    hiOf(level) = i
    openSub(lv, id, 0)
  if accessOn:
    let k = accessNode(arMenuItem, label, id = id, r = r,
                       states = offWhen(enabled) + {asExpandable} +
                                (if subIds[lv] == id: {asExpanded} else: {}))
    if hiOf(level) == i: accessFocus(k)
  if accessPress != 0 and accessPress == id and enabled and deeper:
    accessPress = 0
    hiOf(level) = i
    openSub(lv, id, 0)
  if not deeper or not enabled: return false
  if canInput() and not overSub():
    if mouseIn(r) and (ui.mouseMoved or ui.pressed or waitRows[lv] == i):
      if subIds[lv] == 0 or (subIds[lv] != id and rowTakesOver(i)):
        hiOf(level) = i
        openSub(lv, id, -1)
      elif subIds[lv] == id:
        hiOf(level) = i
    if hiOf(level) == i and subIds[lv] == 0 and not ui.keyUsed and
       (ui.key == KeyRight or ui.key == KeyEnter):   # (an open menu's)
      ui.keyUsed = true
      openSub(lv, id, 0)
  if subIds[lv] != id: return false
  # Right of the whole menu (all its columns), else left of it, else on the
  # side with more room
  let st = state(id)
  let sw = max(st.aux, dp(120)) * menuCols(st, r.y - 3, false)
  let mw = pm.w * max(menuCols(state(pm.id), pm.y, pm.fixedTop), pm.cols)
  let edge = glossMenuEdge()
  var x = pm.x + mw - 3 + edge
  let right = ui.winX + ui.w
  if x + sw + 3 > right:
    if pm.x - sw + 3 >= ui.winX: x = pm.x - sw + 3
    elif right - (pm.x + mw) >= pm.x - ui.winX: x = max(ui.winX, right - sw - 3)
    else: x = ui.winX
  beginPopupMenu(id, x, r.y - 3, level + 1)

template submenu*(label: string; body: untyped) =
  ## An item that opens a menu of its own -- in a menu, or in a submenu (four deep at most).
  if beginSubmenu(label):
    body
    endMenu()

proc menuSeparator*() =
  ## A line between groups of menu items (none at the top of a column).
  if walkDepth > 0: return
  pm.natural += dp(9)
  if pm.cy + dp(9) + MenuRowH > pm.bottom and pm.cy > pm.y + 3 + MenuRowH:
    newMenuColumn()                      # (the next row starts a column: no line)
    return
  if pm.cy <= pm.y + 3 and pm.cols > 1: return
  notePlaced(rect(pm.colX + 1, pm.cy, pm.w - 2, dp(9)))
  if glossLook():
    # (Gloss: a band between the groups of rows, as between a list's groups)
    fill(rect(pm.colX, pm.cy, pm.w, dp(9)), mixColor(th.field, th.window, 0.55))
    hline(pm.colX, pm.cy, pm.w, mixColor(th.field, th.fieldText, 0.16))
    hline(pm.colX, pm.cy + dp(9) - 1, pm.w, mixColor(th.field, th.fieldText, 0.16))
  elif glassLook(): hline(pm.colX + dp(10), pm.cy + dp(4), pm.w - 2 * dp(10), glassHair())
  else: hline(pm.colX + 3, pm.cy + dp(4), pm.w - 6, th.shadow)
  pm.cy += dp(9)

proc beginContextMenu*(): bool =
  ## The menu of the widget drawn last (see `contextMenu`): true while it is
  ## open.
  let id = mixId(ui.lastId, fnv("context") + uint32(ui.lastRect.x * 7 +
                 ui.lastRect.y))
  if ui.rpressed and canInput() and mouseIn(ui.lastRect):
    ui.popup = id
    ui.menuOpen = false
    ui.popupHi = -1
    var st = state(id)
    st.scrollX = ui.mx
    st.scrollY = ui.my
    state(id) = st
    ui.redraw = true
  if ui.popup != id: return false
  let st = state(id)
  beginPopupMenu(id, st.scrollX, st.scrollY)

template contextMenu*(body: untyped) =
  ## A menu that a right click (a long press on a touch screen) on the
  ## widget drawn last opens.
  if beginContextMenu():
    body
    endMenu()

proc popupId(key: string): Id = Id(mixId(fnv(key), 0x5f1d0b17'u32))

proc openPopupMenu*(key: string; x, y: int) =
  ## Opens the menu `key` with its top left at `x`, `y` (under a button
  ## that drops it down); draw it with `popupMenu(key)`.
  let id = popupId(key)
  ui.popup = id
  ui.menuOpen = false
  ui.popupHi = -1
  var st = state(id)
  st.scrollX = globalX(x)
  st.scrollY = y
  state(id) = st
  ui.redraw = true

proc popupMenuOpen*(key: string): bool = ui.popup == popupId(key)
  ## The menu `key` is open.

proc beginPopupMenuFor*(key: string): bool =
  ## The menu `key` opened with `openPopupMenu` (see `popupMenu`): true while
  ## it is open.
  let id = popupId(key)
  if ui.popup != id: return false
  let st = state(id)
  beginPopupMenu(id, st.scrollX, st.scrollY)

template popupMenu*(key: string; body: untyped) =
  ## The menu opened with `openPopupMenu(key, x, y)`: `menuItem`s in
  ## `body`; it closes when one is chosen, on Esc or a click outside.
  if beginPopupMenuFor(key):
    body
    endMenu()

# ---- tool bar, status bar ---------------------------------------------------

type ButtonLook* = enum
  ## How a button with an icon and a label shows them.
  blDefault = "Default"            ## tool bars: `toolbarLook`; other buttons: text beside the icon
  blIconOnly = "Icon only"         ## the label is its tooltip
  blTextOnly = "Text only"
  blTextBelow = "Text below icon"  ## (a tool bar of these is taller, as Explorer's)
  blTextBeside = "Text beside icon"

var toolbarLook* = blIconOnly
  ## How tool bars show `barButton`s that do not say (Explorer's "Text
  ## Labels"; a setting the app can offer: `setToolbarLook`).

proc setToolbarLook*(look: ButtonLook) =
  ## Every tool bar's buttons from now on (blDefault: icon only). Cheap to
  ## call every frame: only a change draws again.
  let l = if look == blDefault: blIconOnly else: look
  if l != toolbarLook:
    toolbarLook = l
    ui.redraw = true

template ToolH: int =
  (if toolbarLook == blTextBelow: CtrlH + FontH + dp(5) else: CtrlH + 5)

var tbar: tuple[on, full: bool; y, h: int; chosen: string;
                items: seq[tuple[key, label: string; enabled, down: bool]];
                tailId: Id; sprung, jumped, again: bool]
  ## The tool bar being drawn: buttons that do not fit go into its "more"
  ## menu (`chosen`: the one picked there, which clicks next frame).
  ## `toolSpace()`: what follows it is at the bar's right end (`sprung`),
  ## as wide as it was measured the frame before (kept under `tailId`);
  ## `jumped`: it was put there this frame; `again`: it did not fit there
  ## -- measured again, where it falls.

# A run of tool buttons -- a tool bar's, between its boxes; a palette's tools
# -- is one stop of Tab, as Windows' tool bars are: the arrows go along it,
# Home and End to its ends, Space or Enter presses the one lit. It is the
# buttons drawn one after another with no other control between them.
var trun: tuple[id, last: Id; frame, n, hot, mask: int; on: bool]
const RunBits = sizeof(int) * 8 - 2
  ## (the buttons of a run whose being enabled `trun.mask` keeps: 62, or 30
  ## where an int has 32 bits -- the rest count as enabled)

proc runNext(mask, n, start, step: int): int =
  ## (the next button of the run that is enabled, from `start` going `step`)
  var i = start
  for _ in 0 ..< n:
    i = (i + step + n) mod n
    if i >= RunBits or (mask and (1 shl i)) != 0: return i
  start

proc toolRun(id: Id; r: Rect; enabled: bool): bool =
  ## (button `id` joins the run of tool buttons drawn now; true: it is the
  ## one lit, the run having the focus -- it draws the focus and takes
  ## Space and Enter)
  if trun.frame != ui.frameNo or ui.lastId != trun.last or trun.last == 0:
    # a new run: one stop of Tab (not the one a window starts at), the
    # arrows going along it by last frame's buttons
    trun.frame = ui.frameNo
    trun.id = Id(uint32(id) xor 0x544F_4F4C'u32)
    trun.n = 0
    trun.mask = 0
    let st = state(trun.id)
    let (count, was) = (st.aux2, st.anchor)
    trun.hot = st.aux
    trun.on = false
    if not (count > 0 and was == 0):          # (none enabled: no stop)
      trun.on = tabStop(trun.id, r, first = false)
    if count > 0:
      if trun.hot < 0 or trun.hot >= count or
         (trun.hot < RunBits and (was and (1 shl trun.hot)) == 0):
        trun.hot = runNext(was, count, max(0, min(trun.hot, count - 1)) - 1, 1)
      if trun.on and not ui.keyUsed and canInput() and
         ui.mods * {CtrlPressed, AltPressed, GuiPressed} == {}:
        let fwd = if ui.rtl: KeyLeft else: KeyRight
        let bwd = if ui.rtl: KeyRight else: KeyLeft
        let k = ui.key
        let to = if k == fwd or k == KeyDown: runNext(was, count, trun.hot, 1)
                 elif k == bwd or k == KeyUp: runNext(was, count, trun.hot, -1)
                 elif k == KeyHome: runNext(was, count, count - 1, 1)
                 elif k == KeyEnd: runNext(was, count, 0, -1)
                 else: -1
        if to >= 0:
          ui.keyUsed = true
          ui.spaceDown = false
          ui.focusMoved = ui.frameNo
          ui.redraw = true
          trun.hot = to
    state(trun.id).aux = trun.hot
  let i = trun.n
  inc trun.n
  if enabled and i < RunBits: trun.mask = trun.mask or (1 shl i)
  trun.last = id
  var st = addr state(trun.id)
  st.aux2 = trun.n
  st.anchor = trun.mask
  if ui.focus == id and id != 0:
    # (a screen reader or the driver focused the button itself: the run,
    # lit there)
    ui.focus = trun.id
    trun.on = true
    trun.hot = i
    st.aux = i
  result = trun.on and i == trun.hot and enabled
  if result: focusAt(r)

proc runClicked(hit: Hit) =
  ## (a button of the run clicked with the run focused: it is the one lit)
  if hit.clicked and trun.on:
    state(trun.id).aux = trun.n - 1

proc runNode(n: int; lit: bool) =
  ## (the reader's node of a run's button: the lit one takes the focus)
  if n < 0: return
  if trun.hot == trun.n - 1: accessTree[n].states.incl asFocusable
  if lit: accessFocus(n)

proc runKeys(id: Id; hit: var Hit) =
  ## (the lit button of a focused run: Space and Enter press it)
  hit.focused = true
  spaceKey(id, hit)
  ui.takesEnter = true
  if keyHit(KeyEnter): hit.clicked = true

proc beginToolbar*() =
  ## Starts the tool bar (see `toolbar`).
  pushLayer(LayerBase)
  tbar.h = ToolH
  let r = rect(ui.winX, ui.barY, ui.w, tbar.h)
  notePlaced(r)
  barFace(r)
  hline(ui.winX, r.y, ui.w, th.light)
  hline(ui.winX, r.y + r.h - 1, ui.w, th.shadow)
  pushRow(rect(ui.winX + ui.safe.left + 6, r.y + 3, ui.w - ui.safe.left - 12, tbar.h - 6),
          tbar.h - 6)
  shiftContent(tbar.h)
  if accessOn: accessBegin(arToolBar, "", r)
  beginArea(makeId(uint32(ui.barY) * 0x9E3779B1'u32 + 0x7B))   # (F6: the tool bar)
  tbar.on = true
  inBarNow = true
  tbar.full = false
  tbar.y = r.y
  tbar.items.setLen(0)
  tbar.tailId = makeId(uint32(ui.barY) * 0x9E3779B1'u32 + 0x7C)
  tbar.sprung = false
  tbar.jumped = false
  tbar.again = false

proc overflowsNow(w: int): bool {.inline.} =
  # (what was put at the bar's right end fits there as measured: no room kept for "more")
  tbar.on and (tbar.full or available() < w + (if tbar.jumped: 0 else: (CtrlH + 1) + Gap))

template overflows(w: int; key, label: string; enabled, down: bool; clicked: var bool): bool =
  ## In a tool bar too narrow for it: the button goes into the "more" menu
  ## (and is clicked when it was picked there). (`key` and `label` are made
  ## only then: a tool button takes no memory every frame for them.)
  (if overflowsNow(w): overflowItem(key, label, enabled, down, clicked) else: false)

proc overflowItem(key, label: string; enabled, down: bool; clicked: var bool): bool =
  if tbar.jumped: tbar.again = true      # (it grew since it was measured)
  tbar.full = true
  tbar.items.add (key, label, enabled, down)
  if tbar.chosen == key:
    tbar.chosen = ""
    clicked = enabled
  true

proc endToolbar*() =
  ## Ends the tool bar: the buttons that did not fit go into its "more" menu.
  if tbar.sprung:
    # (how wide what followed `toolSpace()` is, for the next frame to put it at the
    # right end: kept as it was where the bar is too narrow to tell)
    let st = addr state(tbar.tailId)
    let tail = if tbar.again: 0 elif tbar.full and not tbar.jumped: st.aux2 else: barTail()
    if tail != st.aux2:
      st.aux2 = tail
      ui.redraw = true
  tbar.on = false
  inBarNow = false
  if tbar.items.len > 0:
    # the buttons that did not fit, in a menu
    let r = place(CtrlH + 1, CtrlH - 1)
    let id = idOf("toolbar-more")
    let lit = toolRun(id, r, true)
    var hit = interact(id, r, focusable = false)
    if lit: runKeys(id, hit)
    let open = ui.popup == id
    if accessOn:
      runNode(accessNode(arButton, tr("More"), id = id, r = r,
                         states = {asExpandable} + (if open: {asExpanded} else: {})), lit)
    buttonFace(r, open or hit.down, bevel = 1, hot = hovered(r))
    let g = "\uf142"                     # a vertical ellipsis (nfEllipsisV)
    text(r.x + (r.w - textWidth(g)) div 2, r.y + (r.h - FontH) div 2, g, th.text)
    if lit: focusDots(inset(r, 3))
    if accessOn: accessEnd()
    if hit.clicked:
      ui.popup = if open: 0 else: id
      ui.menuOpen = false
      ui.popupHi = if lit: 0 else: -1     # (opened with the keys: its first item lit)
      ui.redraw = true
    if ui.popup == id and beginPopupMenu(id, max(0, r.x + r.w - dp(200)), tbar.y + tbar.h):
      for it in tbar.items:
        if menuItem(it.label, checked = it.down, enabled = it.enabled):
          tbar.chosen = it.key
      endMenu()
  elif accessOn: accessEnd()
  endArea()
  discard popFrame()
  popLayer()
  ui.barY += tbar.h

template toolbar*(body: untyped) =
  ## A bar of tool buttons below the menu bar.
  beginToolbar()
  body
  endToolbar()

proc grayed(ic: Icon): Icon =
  result = ic
  for p in result.px.mitems:
    if (p shr 24) != 0: p = 0xFF808080'u32

proc toolButton*(ic: Icon; tip = ""; down = false;
                 enabled = true): bool {.discardable.} =
  ## A tool bar button with a 16x16 icon. `down` shows it pressed in.
  if overflows(CtrlH + 1, "tool:" & tip, tip, enabled, down, result): return
  let r = place(CtrlH + 1, if tbar.on: tbar.h - 6 else: CtrlH - 1)
  let id = idOfLabel("tool:", tip)
  let lit = toolRun(id, r, enabled)
  var hit = interact(id, r, focusable = false, enabled = enabled)
  if lit: runKeys(id, hit)
  runClicked(hit)
  if accessOn:
    runNode(accessNode(if down: arToggleButton else: arButton, tip,
                       states = offWhen(enabled) + (if down: {asPressed} else: {})), lit)
  let pr = hit.down or down
  buttonFace(r, pr, bevel = 1, hot = enabled and hovered(r))
  if down and not hit.down: checker(inset(r, 2), th.light)   # a switched-on button: dithered
  let o = if pr: 1 else: 0
  # (the icon itself, not a copy of it, when it is not grayed)
  if enabled: image(r.x + (r.w - ic.w) div 2 + o, r.y + (r.h - ic.h) div 2 + o, ic)
  else: image(r.x + (r.w - ic.w) div 2 + o, r.y + (r.h - ic.h) div 2 + o, grayed(ic))
  if lit: focusDots(inset(r, 3))
  tooltip(tip)
  hit.clicked

proc toolButton*(caption: string; tip = ""; down = false; bold = false;
                 enabled = true; size = 1.0): bool {.discardable.} =
  ## A tool bar button showing a short text, or an icon of the icon font
  ## (`toolButton(nfCopy, "Copy", size = 1.3)`).
  let st = style(bold = bold, size = size)
  let shown = tr(caption)
  let tw = textWidth(shown, st)
  if overflows(max(CtrlH + 1, tw + dp(10)), "tool:" & caption & tip,
               caption & "   " & tip, enabled, down, result): return
  let r = place(max(CtrlH + 1, tw + dp(10)), if tbar.on: tbar.h - 6 else: CtrlH - 1)
  let id = idOf("tool:" & caption & tip)
  let lit = toolRun(id, r, enabled)
  var hit = interact(id, r, focusable = false, enabled = enabled)
  if lit: runKeys(id, hit)
  runClicked(hit)
  if accessOn:
    runNode(accessNode(if down: arToggleButton else: arButton, (if tip.len > 0: tip else: caption),
                       states = offWhen(enabled) + (if down: {asPressed} else: {})), lit)
  let pr = hit.down or down
  buttonFace(r, pr, bevel = 1, hot = enabled and hovered(r))
  if down and not hit.down: checker(inset(r, 2), th.light)   # a switched-on button: dithered
  let o = if pr: 1 else: 0
  text(r.x + (r.w - tw) div 2 + o, r.y + (r.h - lineHeight(st)) div 2 + o, shown,
       if enabled: th.text else: th.gray, st)
  if lit: focusDots(inset(r, 3))
  tooltip(tip)
  hit.clicked

# ---- buttons with an icon and a label: icon only, text only, text below or beside ----

type ButtonPic* = object
  ## What a labeled button shows as its picture: a bitmap icon, or a glyph
  ## of the icon font (`nfCopy`...).
  icon*: Icon
  glyph*: string
  size*: float                  ## the glyph's size (1.0: the text's)

converter toButtonPic*(ic: Icon): ButtonPic = ButtonPic(icon: ic)
  ## (an icon where a picture is asked for)

proc glyphPic*(glyph: string; size = 1.25): ButtonPic =
  ## An icon-font glyph as a button's picture (`glyphPic(nfCopy)`).
  ButtonPic(glyph: glyph, size: size)

proc glyphStyle(p: ButtonPic): TextStyle =
  ## (a glyph's size: its own times the text's -- `withTextStyle`)
  style(size = (if p.size > 0: p.size else: 1.0) * textScaleNow())

proc picSize(p: ButtonPic): (int, int) =
  if p.glyph.len > 0:
    let st = glyphStyle(p)
    (textWidth(p.glyph, st), lineHeight(st))
  else: (p.icon.w, p.icon.h)

proc drawPic(p: ButtonPic; x, y: int; enabled: bool) =
  if p.glyph.len > 0:
    text(x, y, p.glyph, if enabled: th.text else: th.gray, glyphStyle(p))
  elif p.icon.w > 0:
    if enabled: image(x, y, p.icon) else: image(x, y, grayed(p.icon))

proc labeledSize*(pic: ButtonPic; label: string; look: ButtonLook; minH = CtrlH): (int, int) =
  ## How big a button showing `pic` and `label` the `look` way is.
  let (pw, ph) = pic.picSize
  let tw = labelWidth(label)
  case look
  of blIconOnly: (max(minH + 1, pw + dp(10)), max(minH, ph + dp(6)))
  of blTextOnly: (max(minH + 1, tw + dp(14)), minH)
  of blTextBelow: (max(max(pw, tw) + dp(14), dp(50)), max(minH, ph + FontH + dp(8)))
  of blTextBeside, blDefault: (pw + dp(5) + tw + dp(14), max(minH, ph + dp(6)))

proc drawLabeled*(r: Rect; pic: ButtonPic; label: string; look: ButtonLook; enabled, pressed: bool) =
  ## The picture and the label inside a button's face at `r`, the `look`
  ## way (pressed: a pixel down and right, as 3.1 did).
  let (pw, ph) = pic.picSize
  let tw = labelWidth(label)
  let o = if pressed: 1 else: 0
  template lab(x, y: int) =
    if not enabled: drawLabel(x + 1, y + 1, label, th.light)
    drawLabel(x, y, label, if enabled: th.text else: th.gray)
  case look
  of blIconOnly:
    pic.drawPic(r.x + (r.w - pw) div 2 + o, r.y + (r.h - ph) div 2 + o, enabled)
  of blTextOnly:
    lab(r.x + (r.w - tw) div 2 + o, r.y + (r.h - FontH) div 2 + o)
  of blTextBelow:
    let top = r.y + (r.h - ph - FontH - dp(2)) div 2 + o
    pic.drawPic(r.x + (r.w - pw) div 2 + o, top, enabled)
    lab(r.x + (r.w - tw) div 2 + o, top + ph + dp(2))
  of blTextBeside, blDefault:
    let x0 = r.x + (r.w - pw - dp(5) - tw) div 2 + o
    pic.drawPic(x0, r.y + (r.h - ph) div 2 + o, enabled)
    lab(x0 + pw + dp(5), r.y + (r.h - FontH) div 2 + o)

proc picButton(label: string; pic: ButtonPic; look: ButtonLook; isDefault, enabled: bool;
               w, h: int): bool =
  let id = idOf("picbutton:" & label)
  let lk = if look == blDefault: blTextBeside else: look
  let (nw, nh) = labeledSize(pic, label, lk)
  let r = place(if w > 0: w else: max(nw, if lk == blTextOnly: buttonWidth(label) else: 0),
                if h > 0: h else: nh)
  var hit = interact(id, r, enabled = enabled)
  if accessOn:
    accessNode(arButton, label, states = offWhen(enabled) + (if isDefault: {asDefault} else: {}))
  if enabled:
    spaceKey(id, hit)
    if hit.focused:
      ui.takesEnter = true
      if keyHit(KeyEnter): hit.clicked = true
    elif isDefault and not ui.prevTakesEnter and keyHit(KeyEnter):
      hit.clicked = true
    if mnemonicHit(label): hit.clicked = true
  let thick = enabled and (hit.focused or (isDefault and not ui.prevTakesEnter))
  buttonFace(r, hit.down, if thick: 2 else: 1, hot = enabled and hovered(r))
  drawLabeled(inset(r, 2), pic, label, lk, enabled, hit.down)
  if hit.focused: focusDots(inset(r, 4))
  if lk == blIconOnly: tooltip(label.replace("&", ""))
  hit.clicked

proc button*(label: string; pic: ButtonPic; look = blTextBeside; isDefault = false;
             enabled = true; w = 0; h = 0; accent = false;
             style = TextStyle()): bool {.discardable.} =
  ## A push button with a picture: icon only (the label its tooltip), text
  ## only, the text below the icon, or beside it. True when clicked.
  ## `accent` and `style` as the plain button's: the picture of the icon
  ## font grows with the label.
  dressed(accent, style):
    result = picButton(label, pic, look, isDefault, enabled, w, h)

proc barButton*(pic: ButtonPic; label: string; tip = ""; down = false; enabled = true;
                look = blDefault): bool {.discardable.} =
  ## A tool bar button with a picture and a label, shown as the bar's look
  ## (`toolbarLook`, Explorer's "Text Labels") or as `look` says.
  let lk = if look == blDefault: toolbarLook else: look
  let rowH = if tbar.on: tbar.h - 6 else: CtrlH - 1
  let (bw, _) = labeledSize(pic, label, lk, minH = CtrlH - 1)
  let key = "bar:" & label & tip
  if overflows(bw, key, label, enabled, down, result): return
  let r = place(bw, rowH)
  let id = idOf(key)
  let lit = toolRun(id, r, enabled)
  var hit = interact(id, r, focusable = false, enabled = enabled)
  if lit: runKeys(id, hit)
  runClicked(hit)
  if accessOn:
    runNode(accessNode(if down: arToggleButton else: arButton, (if label.len > 0: label else: tip),
                       states = offWhen(enabled) + (if down: {asPressed} else: {}), help = tip), lit)
  let pr = hit.down or down
  buttonFace(r, pr, bevel = 1, hot = enabled and hovered(r))
  if down and not hit.down: checker(inset(r, 2), th.light)   # a switched-on button: dithered
  drawLabeled(inset(r, 1), pic, label, lk, enabled, pr)
  if lit: focusDots(inset(r, 3))
  tooltip(if tip.len > 0: tip elif lk == blIconOnly: label.replace("&", "") else: "")
  hit.clicked

proc buttonAt*(key: string; r: Rect; label: string; pic: ButtonPic; look = blTextBeside;
               enabled = true; down = false): bool {.discardable.} =
  ## `buttonAt` with a picture, the `look` way.
  let hit = interact(idOf("btnat:" & key), r, focusable = false, enabled = enabled)
  if accessOn:
    accessNode(if down: arToggleButton else: arButton, label,
               states = (if down: {asPressed} else: {}) + offWhen(enabled))
  let pressed = down or hit.down
  buttonFace(r, pressed, 1, hot = enabled and hit.hover)
  drawLabeled(inset(r, 1), pic, label, if look == blDefault: blTextBeside else: look, enabled, pressed)
  if look == blIconOnly: tooltip(label.replace("&", ""))
  hit.clicked

proc button*(label: string; glyph: string; look = blTextBeside; isDefault = false;
             enabled = true; w = 0; h = 0; accent = false;
             style = TextStyle()): bool {.discardable.} =
  ## `button` with a glyph of the icon font as its picture (`pxSave`,
  ## `nfCopy`...).
  button(label, glyphPic(glyph, 1.0), look, isDefault, enabled, w, h, accent, style)

proc barButton*(glyph: string; label: string; tip = ""; down = false; enabled = true;
                look = blDefault): bool {.discardable.} =
  ## `barButton` with a glyph of the icon font as its picture.
  barButton(glyphPic(glyph, 1.0), label, tip, down, enabled, look)

proc buttonAt*(key: string; r: Rect; label: string; glyph: string; look = blTextBeside;
               enabled = true; down = false): bool {.discardable.} =
  ## `buttonAt` with a glyph of the icon font as its picture.
  buttonAt(key, r, label, glyphPic(glyph, 1.0), look, enabled, down)

proc toolSeparator*(line = false) =
  ## A gap between groups of tool buttons. `line`: an etched line in the
  ## gap, as the tool bars after 3.1 have between their groups.
  if tbar.on and tbar.full: return
  if not line:
    space(8)
    return
  let r = place(dp(9), if tbar.on: tbar.h - 6 else: CtrlH - 1)
  let x = r.x + r.w div 2
  vline(x - 1, r.y + 2, r.h - 4, th.shadow)
  vline(x, r.y + 2, r.h - 4, th.light)
  ui.lastId = 0
  ui.lastRect = r

proc toolSpace*(w = 0) =
  ## Room between tool buttons: `w` pixels of it, or -- 0 -- all the bar
  ## has left, so what comes after it is at the bar's right end (a search
  ## box, a Help button).
  if tbar.on and tbar.full: return
  if w > 0: space(w)
  elif not tbar.on: spring()
  else:
    let tail = state(tbar.tailId).aux2
    tbar.sprung = true
    tbar.jumped = tail > 0 and available() >= tail
    barSpring(if tbar.jumped: tail else: 0)

proc statusbar*(parts: varargs[string]) =
  ## The status bar at the bottom of the window: the first part takes the
  ## spare room. Content above it can fill down to it (`rows = -1`).
  let h = FontH + 8
  let r = rect(ui.winX, ui.bottom - h, ui.w, h)
  notePlaced(rect(ui.winX, r.y, ui.w, ui.h - r.y))
  pushLayer(LayerBase)
  defer: popLayer()
  barFace(rect(ui.winX, r.y, ui.w, ui.h - r.y))
  hline(ui.winX, r.y, ui.w, th.shadow)
  hline(ui.winX, r.y + 1, ui.w, th.light)
  ui.bottom = r.y
  # the parts, the first one taking the spare room, between etched lines
  # (the last one left of the frame's size grip, in the bar's corner)
  let ty = r.y + 1 + (h - 1 - FontH) div 2
  let grip = sizeGrip()
  var x = r.x + r.w - 6 - ui.safe.right - (if grip.y >= r.y: grip.w else: 0)
  for i in countdown(parts.high, 1):
    let part = tr(parts[i])
    let w = textWidth(part) + 14
    x -= w
    text(x + 8, ty, part, th.text)
    vline(x, r.y + 4, h - 7, th.shadow)
    vline(x + 1, r.y + 4, h - 7, th.light)
  if parts.len > 0:
    let x0 = r.x + 6 + ui.safe.left
    pushClip(rect(x0, r.y + 2, max(0, x - x0 - 4), h - 3))
    text(x0, ty, tr(parts[0]), th.text)
    popClip()
  if accessOn:
    # (its parts read as one line)
    var all = ""
    for p in parts:
      if p.len > 0:
        if all.len > 0: all.add ", "
        all.add tr(p)
    accessNode(arStatusBar, all, id = 0, r = r)

proc beginStatusBar*(): Rect =
  ## Starts a status bar of your own at the bottom of the window (see
  ## `statusBar`); returns where it is.
  let h = max(FontH + 8, EditH + 4)
  let r = rect(ui.winX, ui.bottom - h, ui.w, h)
  notePlaced(rect(ui.winX, r.y, ui.w, ui.h - r.y))
  pushLayer(LayerBase)
  fill(rect(ui.winX, r.y, ui.w, ui.h - r.y), th.face)
  hline(ui.winX, r.y, ui.w, th.shadow)
  hline(ui.winX, r.y + 1, ui.w, th.light)
  ui.bottom = r.y
  if accessOn: accessBegin(arStatusBar, "", r)
  let grip = sizeGrip()
  let gw = if grip.y >= r.y: grip.w else: 0     # (the frame's size grip at its end)
  pushFrame(rect(r.x + dp(4) + ui.safe.left, r.y + 3,
                 r.w - dp(8) - ui.safe.left - ui.safe.right - gw, h - 4))
  beginClipped()                 # (not the page's content: it does not scroll it)
  r

proc endStatusBar*() =
  ## Ends a `beginStatusBar`.
  endClipped()
  discard popFrame()
  popLayer()
  if accessOn: accessEnd()

template statusRow*(body: untyped) =
  ## A status bar with controls in it (an editable zoom field, a menu
  ## arrow, texts), laid out by `body` -- usually one `row`. Separate the
  ## parts with `statusSep`. (`statusbar` is the one of texts only.)
  discard beginStatusBar()
  body
  endStatusBar()

proc statusSep*() =
  ## The etched line between two parts of a status bar.
  let r = place(dp(4), max(FontH, EditH) - 2)
  vline(r.x + r.w div 2 - 1, r.y + 1, r.h - 2, th.shadow)
  vline(r.x + r.w div 2, r.y + 1, r.h - 2, th.light)

# ---- dialogs -------------------------------------------------------------------

template TitleH: int = FontH + (if fingers(): dp(10) else: dp(5))

var dlgCloseOff = false     # (the next dialog's close button grayed: `msgBox`)
var dlgAlert = false        # (the next dialog a message box: a small alert, even where dialogs are pages)
var dlgPage = false         # (the dialog drawn now is a page)

type DialogPages* = enum
  ## How dialogs open (`dialogPages`).
  dpAuto,      ## as pages of the app in the Glass and Gloss looks on Android and iOS; else over it
  dpPages,     ## always as pages of the app
  dpWindows    ## always as windows over the app

var dialogPages* = case getEnv("RETRO_DIALOGS")
                   of "pages": dpPages
                   of "windows": dpWindows
                   else: dpAuto
  ## Dialogs as pages of the app -- the whole window, sliding up, a navigation bar with their
  ## title and Close, their content scrolling -- as phone apps have them, or as windows over
  ## the app. A message box (`msgBox`) stays a small alert either way, as phones show them.
  ## $RETRO_DIALOGS ("pages", "windows") sets it at the start: to try an app's pages on a
  ## computer.

proc dialogsAsPages*(): bool =
  ## Dialogs open as pages now (`dialogPages`).
  case dialogPages
  of dpPages: true
  of dpWindows: false
  of dpAuto: (defined(android) or defined(ios)) and phoneLook()

var pageDialogsOpen: Table[Id, tuple[opened, frame: int]]

proc beginPageDialog(open: var bool; title: string; id: Id; st: var WState): bool =
  ## (a dialog as a page: the whole window, sliding up when it opens, its title and Close in a
  ## navigation bar, its content scrolling under it)
  var pd = pageDialogsOpen.getOrDefault(id, (-1, -1))
  if pd.frame < ui.frameNo - 1: pd.opened = ui.now          # (just opened: it slides up)
  pd.frame = ui.frameNo
  pageDialogsOpen[id] = pd
  let room = ui.h - ui.winY
  let age = ui.now - pd.opened
  let slide = if not smoothScrolling or age >= 300: 0.0 else: pow(1 - float(age) / 300, 3)
  if slide > 0: wakeIn(16)
  let dy = int(slide * float(room))
  let full = rect(ui.winX, ui.winY + dy, ui.w, room)
  notePlaced(full)
  # its face, and a dimmed shadow of the page under it while it slides
  if dy > 0: fill(rect(ui.winX, ui.winY, ui.w, dy), withAlpha(black, int(60 * (1 - slide))))
  fill(full, if glossLook() and not onDark(): mixColor(th.window, color(222, 226, 232), 0.5) else: th.window)
  # the navigation bar: under the status bar, its title in the middle, Close at its start
  let safeTop = max(0, ui.safe.top - ui.winY)
  let barH = if fingers(): dp(44) else: max(dp(32), CtrlH + dp(8))
  let bar = rect(full.x, full.y, full.w, safeTop + barH)
  let inBar = rect(full.x + ui.safe.left, full.y + safeTop, full.w - ui.safe.left - ui.safe.right, barH)
  if glassLook(): titleBar(bar, true)
  else:
    fill(bar, th.face)
    hline(bar.x, bar.y + bar.h - 1, bar.w, th.frame)
  let (_, tfg) = if glassLook(): titleColors(true) else: (th.face, th.text)
  let bst = style(bold = true, size = 0.9)
  let closeLabel = tr("Close")
  let bw = labelWidth(closeLabel, bst) + dp(20)
  let bh = if glossLook(): min(barH - dp(10), dp(30)) else: barH - dp(10)
  let br = rect(inBar.x + dp(6), inBar.y + (barH - bh) div 2, bw, bh)
  var hit: Hit
  if canInput():
    hit = interact(id + 3, br, focusable = false)
    if hit.clicked or keyHit(KeyEsc) or backPressed():
      if backPressed(): cancelClose()
      open = false
  if not open:
    pageDialogsOpen.del(id)
    popLayer()
    ui.curDialog = 0
    ui.redraw = true
    return false
  var ink = tfg
  if glossLook():
    glossBarButton(br, hit.down)
    ink = white
  elif hit.down: roundRect(br, float(dp(6)), withAlpha(th.text, 30))
  let lw = labelWidth(closeLabel, bst)
  let ly = br.y + (br.h - lineHeight(bst)) div 2
  if glossLook(): drawLabel(br.x + (br.w - lw) div 2, ly - 1, closeLabel, withAlpha(black, 100), bst)
  drawLabel(br.x + (br.w - lw) div 2, ly, closeLabel, if glossLook(): ink else: accentColor(), bst)
  let tst = if glossLook(): style(bold = true, size = 1.2) else: style(bold = true)
  let t = ellipsize(tr(title), max(dp(24), inBar.w - 2 * (bw + dp(16))), tst)
  let tw = textWidth(t, tst)
  let tx = inBar.x + (inBar.w - tw) div 2
  let ty = inBar.y + (barH - lineHeight(tst)) div 2
  if glossLook(): text(tx, ty - 1, t, withAlpha(black, 110), tst)
  text(tx, ty, t, tfg, tst)
  # its content, as wide as reads well, scrolling
  let cy = bar.y + bar.h
  let client = rect(full.x + ui.safe.left, cy, full.w - ui.safe.left - ui.safe.right,
                    full.y + full.h - cy - ui.safe.bottom)
  let cw = min(client.w, dp(680))
  if accessOn:
    accessBegin(arDialog, title, full, id, {asModal})
    accessNode(arButton, closeLabel, id = id + 3, r = br)
  dlgClient = client
  dlgTall = true
  dlgPage = true
  pushClip(client)
  pushFrame(rect(client.x + (client.w - cw) div 2 + Pad, client.y + Pad - st.caret, cw - 2 * Pad, 0))
  true

proc beginDialog*(open: var bool; title: string; width: int): bool =
  ## Starts a modal dialog (see `dialog`): true while it is `open`.
  let closeOff = dlgCloseOff
  dlgCloseOff = false
  let alert = dlgAlert
  dlgAlert = false
  dlgPage = false
  if not open: return false
  # (known by its title, not by where `open` is: a dialog drawn from a proc's own flag -- the
  # Color dialog's -- has it on the stack, at an address the same each frame only by luck; under
  # AddressSanitizer each frame's is another, the dialog never the one on top: no keys, no Tab)
  let id = idOf("\x1Fdialog\x1F" & title)
  var st = state(id)
  ui.curDialog = id
  ui.dialogTopNow = id
  pushLayer(LayerDialog)
  if dialogsAsPages() and not alert:
    result = beginPageDialog(open, title, id, st)
    state(id) = st
    return
  let w = min(dp(width), ui.w - 8)
  let room = ui.h - ui.winY             # (the window's height: a box's in a `windowBox`)
  var h = TitleH + 10 + st.aux + 2 * Pad
  let tall = h > room - 4               # taller than the screen: it scrolls
  if tall: h = room - 4
  var x = ui.winX + (ui.w - w) div 2 + st.scrollX
  var y = ui.winY + (room - h) div 2 + st.scrollY
  x = clamp(x, ui.winX, ui.winX + max(0, ui.w - w))
  y = clamp(y, ui.winY, ui.winY + max(0, room - h))
  let r = rect(x, y, w, h)
  notePlaced(r)
  let bar = rect(x + 5, y + 5, w - 10, TitleH)
  let sysBox = rect(bar.x, bar.y, TitleH, TitleH)
  # (Windows 95's close button at the right: what Esc does)
  let xBox = if captionButtons == cbWin95: rect(bar.x + bar.w - TitleH, bar.y, TitleH, TitleH)
             else: rect(bar.x + bar.w, bar.y, 0, TitleH)
  var xHit: Hit
  if canInput():
    if xBox.w > 0 and not closeOff: xHit = interact(id + 3, xBox, focusable = false)
    if xHit.clicked or keyHit(KeyEsc):
      open = false
    elif hover(sysBox) and takePress():
      open = false
    elif hover(bar) and takePress():
      ui.active = id
      ui.dragsActive = true
      st.aux2 = ui.mx - st.scrollX
      st.anchor = ui.my - st.scrollY
    if ui.active == id and ui.mouseDown:
      st.scrollX = ui.mx - st.aux2
      st.scrollY = ui.my - st.anchor
  if not open:
    popLayer()
    ui.curDialog = 0
    ui.redraw = true
    state(id) = st
    return false
  # the frame of the Win31 desktop: a black line, the gray border with its
  # 3D edge, a black line; the title bar navy in front (white while
  # another dialog is over this one), the control-menu box at its left
  let active = ui.dialogTop == id or ui.dialogTop == 0
  let (tbg, tfg) = titleColors(active)
  let glass = frosted()
  if glass:
    # (Glass, frosted: a soft shadow round it, what is under it blurred through it, a hairline
    # round it, its title bar a little darker glass)
    let rad = float(dp(10))
    for k in 1 .. 6:
      roundFrame(rect(r.x - k, r.y - k + 4, r.w + 2 * k, r.h + 2 * k), rad + float(k), float(k + 5),
                 withAlpha(color(0, 0, 0), if onDark(): 30 - 4 * k else: 13 - 2 * k))
    frostedFace(r, th.window, rad)
    roundFrame(r, rad, 1, glassHair())
    fill(bar, withAlpha(tbg, if active: 150 else: 90))
  else:
    windowFrame(r)
    titleBar(bar, active)
  hline(bar.x, bar.y + bar.h, bar.w, if glass: glassHair() else: th.frame)
  captionButton(sysBox, ui.active == id + 1)
  if not glass: vline(sysBox.x + sysBox.w, sysBox.y, sysBox.h, th.frame)
  controlMenuMark(sysBox)
  if xBox.w > 0:
    if not glass: vline(xBox.x, xBox.y, xBox.h, th.frame)
    let face = rect(xBox.x + 1, xBox.y, xBox.w - 1, xBox.h)
    captionButton(face, xHit.down)
    captionMark(face, cmClose, xHit.down, enabled = not closeOff)
    if xHit.hover and canHover(): ui.tip = "Close"
  let title = tr(title)
  let tw = textWidth(title, true)
  let titleRoom = bar.w - TitleH - xBox.w
  text(bar.x + TitleH + max(dp(4), (titleRoom - tw) div 2),
       bar.y + (TitleH - FontH) div 2, ellipsize(title, titleRoom - dp(8), style(bold = true)),
       tfg, true)
  let client = rect(x + 5, bar.y + bar.h + 1, w - 10, h - TitleH - 11)
  if not glass: fill(client, th.window)
  if accessOn:
    accessBegin(arDialog, title, r, id, {asModal})
    if xBox.w > 0: accessNode(arButton, "Close", id = id + 3, r = xBox, states = accessOff(not closeOff))
  if not tall: st.caret = 0
  state(id) = st
  dlgClient = client
  dlgTall = tall
  pushClip(client)                       # nothing drawn outside the frame
  let barW = if tall: SbW else: 0
  pushFrame(rect(client.x + Pad, client.y + Pad - st.caret,
                 client.w - 2 * Pad - barW, 0))
  true

proc endDialog*() =
  ## Ends a `beginDialog`: it scrolls (with its scroll bar) when it is
  ## taller than the window.
  if accessOn: accessEnd()
  let ch = popFrame()
  let id = ui.curDialog
  var st = state(id)
  if ch != st.aux:
    st.aux = ch
    ui.redraw = true
  popClip()
  if dlgTall:
    let c = dlgClient
    let hi = max(0, st.aux + 2 * Pad - c.h)
    var y = clamp(st.caret, 0, hi)
    if canInput():
      scrollWheel(id, y, hi, c, 3 * ItemH)
      scrollPan(id, y, hi, c)
    scrollTick(id, y, hi)
    let f = wantSeen()
    if canInput() and f.w > 0:
      if f.y < c.y: y -= c.y + Pad - f.y
      elif f.y + f.h > c.y + c.h: y += f.y + f.h + Pad - (c.y + c.h)
    # the standard scroll bar, fingers too (they can also drag the content); a page's, the thin
    # line phones show
    y = clamp(y, 0, hi)
    if dlgPage: scrollHint(id + 78, c, y, hi)
    else:
      scrollBarFor(id + 77, id, rect(c.x + c.w - SbW, c.y, SbW, c.h), true,
                   y, hi, max(ItemH, c.h - 2 * ItemH), ItemH)
    y = clamp(y, 0, hi)
    if y != st.caret:
      st.caret = y
      ui.redraw = true
  state(id) = st
  popLayer()
  ui.curDialog = 0
  dlgPage = false

template dialog*(open: var bool; title: string; width: int; body: untyped) =
  ## A modal dialog, `width` pixels wide, shown while `open` is true. Esc,
  ## the close button (`captionButtons`) and the control-menu box close it;
  ## drag it by its title. Work that
  ## takes a while in it (its OK) is named by its title in the box that
  ## comes up.
  if beginDialog(open, title, width):
    beginBusy(title)
    try:
      body
    finally:
      endBusy()
    endDialog()

template window*(open: var bool; title: string; w, h: int; body: untyped) =
  ## A window of the system's own besides the app's, `w` x `h` design
  ## pixels when it opens, shown while `open` is true: a tool palette, a
  ## second view for another monitor, a preview. It is laid out and drawn
  ## as the app's window is (menus, dialogs, tool bars in it are its own),
  ## at the place in the frame the app draws it; its close button sets
  ## `open` to false; it closes when it is no longer drawn. Where the
  ## system has one window (phones, the browser) it is a dialog over the
  ## app (`dialog`).
  ##
  ## .. code-block:: nim
  ##   var toolsOpen = true
  ##   app "Editor", 800, 600:
  ##     if menuItem("&Tools"): toolsOpen = true
  ##     window(toolsOpen, "Tools", 240, 360):
  ##       if button("&Bold"): bold = not bold
  if windowsAvailable() and open:
    if beginWindow(open, title, w, h):
      var closedNow = false
      try:
        captionBar()
        body
      finally:
        closedNow = endWindow()
      if closedNow: open = false
    elif not windowsAvailable():
      dialog(open, title, w):
        body
  else:
    dialog(open, title, w):
      body

type MsgIcon* = enum
  ## The sign of a message box.
  miNone, miInfo, miQuestion, miWarning, miStop

proc disc(x, y, d: int; c: Color) =
  let r = d div 2
  for j in 0 ..< d:
    let dy = j - r + 1
    var dx = 0
    while (dx + 1) * (dx + 1) + dy * dy <= r * r: inc dx
    hline(x + r - dx, y + j, 2 * dx, c)

proc msgIcon*(kind: MsgIcon) =
  ## A 32x32 message box icon (at 100%: it grows with the UI's size).
  let cell = place(dp(32), dp(32))
  if retroIcons and kind != miNone:
    pixelIconAt(cell, case kind
      of miStop: pxError
      of miQuestion: pxQuestion
      of miWarning: pxWarning
      else: pxInfo)
    return
  # (the drawn icons are 32 pixels: in the middle of the cell)
  let r = rect(cell.x + (cell.w - 32) div 2, cell.y + (cell.h - 32) div 2, 32, 32)
  case kind
  of miNone: discard
  of miStop:
    for j in 0 ..< 32:
      let cut = max(0, max(9 - j, j - 22))
      hline(r.x + cut, r.y + j, 32 - 2 * cut, th.frame)
      if j > 0 and j < 31:
        let c2 = max(0, max(9 - j, j - 22)) + 1
        hline(r.x + c2, r.y + j, 32 - 2 * c2, color(220, 0, 0))
    let tw = textWidth("STOP", true)
    text(r.x + (32 - tw) div 2, r.y + 10, "STOP", color(255, 255, 255), true)
  else:
    disc(r.x, r.y, 32, th.frame)
    disc(r.x + 1, r.y + 1, 30,
         if kind == miWarning: color(255, 255, 0) else: color(255, 255, 255))
    let g = case kind
      of miInfo: "i"
      of miQuestion: "?"
      else: "!"
    let gc = if kind == miWarning: color(0, 0, 0) else: color(0, 0, 255)
    let tw = textWidth(g, true, 2)
    text(r.x + (32 - tw) div 2 + 1, r.y + 4, g, gc, true, 2)

proc msgBox*(open: var bool; title, msg: string;
             buttons: openArray[string] = ["OK"]; icon = miInfo): int =
  ## A message box while `open`. Returns the number of the button clicked
  ## (1 = first) once, closing it; Esc and the close button count as the
  ## last button. A question with no way out but its answers -- its last
  ## button not Cancel, Close or OK: Yes and No, Abort, Retry and Ignore --
  ## has its close button grayed, as Windows has it (Esc still counts).
  var tw = 0
  # (the sizes grow with the UI's: at 300% a message wrapped at 360
  # pixels broke after every word or two, beside a tiny icon)
  for line in wrapLines(msg, dp(360)): tw = max(tw, textWidth(line))
  let bw = buttons.len * dp(72) + (buttons.len - 1) * Gap
  let inner = max(tw + (if icon == miNone: 0 else: dp(48)), bw) + 8
  let w = min(inner + 2 * Pad + 10, ui.w - 16)
  let was = open
  let last = if buttons.len > 0: buttons[^1].replace("&", "").toLowerAscii else: ""
  dlgCloseOff = buttons.len > 1 and last notin ["cancel", "close", "ok"]
  dlgAlert = true
  if beginDialog(open, title, w):
    row:
      if icon != miNone: msgIcon(icon)
      col:
        space(if msg.contains('\n') or tw > dp(300): dp(2) else: dp(9))
        paragraph(msg, min(tw + 2, available()))
    space(4)
    beginRow()
    space(max(0, (available() - bw) div 2))
    for i, b in buttons:
      if button(b, isDefault = i == 0):
        result = i + 1
        open = false
    endRow()
    endDialog()
  if was and not open and result == 0: result = buttons.len

# ---- the 3.1 window frame on desktops ---------------------------------------------

import uirelays/services

type
  FramePart* = enum
    ## A part of the 3.1 window frame (`framePartAt`).
    fpNone,                                ## not the frame: the window's content
    fpCaption,                             ## the title bar: drags the window,
                                           ## a double click maximizes it
    fpControlBox, fpMinimize, fpMaximize,  ## the title bar's buttons (and
    fpClose,                               ## Windows 95's close: `captionButtons`)
    fpLeft, fpRight, fpTop, fpBottom,      ## the sizing border...
    fpTopLeft, fpTopRight, fpBottomLeft, fpBottomRight  ## ... and its corners

  FrameLayout* = object
    ## Where the parts of the 3.1 frame are this frame (`frameLayout`), in
    ## logical pixels.
    border*: int                           ## the sizing border's width (0 maximized)
    corner*: int                           ## how far a corner's part reaches along
                                           ## the border (to the dark lines across it)
    caption*: Rect                         ## the title bar, without the line under it
    controlBox*, minimize*, maximize*: Rect
    close*: Rect                           ## empty with 3.1's buttons (`captionButtons`)

const
  ClassicMenuId = Id(0x31f2a7c5'u32)       # the control menu
  ClassicMinId = Id(0x31f2a7c6'u32)
  ClassicMaxId = Id(0x31f2a7c7'u32)

var
  classicDrawn = -1        # the frame `classicCaption` last ran in
  classicHeld = fpNone     # the button the mouse went down on

proc frameLayout*(): FrameLayout =
  ## The parts of the 3.1 frame (`setClassicFrame`): the sizing border all
  ## round, the title bar inside it with the control-menu box at its left
  ## and the minimize, maximize and close buttons at its right -- the close
  ## button a little apart, as Windows 95 has it (with 3.1's buttons,
  ## `captionButtons`, no close button). All empty when the frame is not
  ## drawn. A window that keeps its size (`setResizable`) has no maximize
  ## button.
  if not ui.ownFrame or ui.captionH == 0: return
  let b = ui.frameBorder
  let h = max(1, ui.captionH - 1)
  result.border = b
  result.corner = b + h          # (in line with the title bar's bottom)
  result.caption = rect(b, b, ui.w - 2 * b, h)
  result.controlBox = rect(b, b, h, h)
  var right = ui.w - b
  if captionButtons == cbWin95:
    result.close = rect(right - h, b, h, h)
    right -= h + dp(2)           # (a slip off the maximize button doesn't close)
  if resizable():
    result.maximize = rect(right - h, b, h, h)
    right -= h
  result.minimize = rect(right - h, b, h, h)

proc framePartAt*(x, y: int): FramePart =
  ## Which part of the 3.1 frame is at `x`, `y` (`fpNone`: the content, or
  ## no such frame). A corner's part reaches as far along the border as
  ## the title bar is low, as in 3.1.
  if not ui.ownFrame or ui.captionH == 0: return fpNone
  let f = frameLayout()
  let p = point(x, y)
  if f.controlBox.contains(p): return fpControlBox
  if f.minimize.contains(p): return fpMinimize
  if f.maximize.contains(p): return fpMaximize
  if f.close.contains(p): return fpClose
  if rect(f.caption.x, f.caption.y, f.caption.w, ui.captionH).contains(p): return fpCaption
  # (the size grip sizes the window as the corner does)
  if sizeGrip().contains(p): return fpBottomRight
  let b = f.border
  if b <= 0 or not resizable() or x < 0 or y < 0 or x >= ui.w or y >= ui.h: return fpNone
  let left = x < b
  let right = x >= ui.w - b
  let top = y < b
  let bottom = y >= ui.h - b
  if not (left or right or top or bottom): return fpNone
  let c = f.corner
  let nearL = x < c
  let nearR = x >= ui.w - c
  let nearT = y < c
  let nearB = y >= ui.h - c
  if nearT and nearL: fpTopLeft
  elif nearT and nearR: fpTopRight
  elif nearB and nearL: fpBottomLeft
  elif nearB and nearR: fpBottomRight
  elif left: fpLeft
  elif right: fpRight
  elif top: fpTop
  else: fpBottom

proc onScreen(p: FramePart): FramePart =
  ## (a part as the system sees it: right to left, the window is drawn
  ## mirrored, and its left edge is on the right)
  if not ui.rtl: return p
  case p
  of fpLeft: fpRight
  of fpRight: fpLeft
  of fpTopLeft: fpTopRight
  of fpTopRight: fpTopLeft
  of fpBottomLeft: fpBottomRight
  of fpBottomRight: fpBottomLeft
  else: p

proc systemPart*(p: FramePart): WindowPart =
  ## The part of the window the system moves or sizes it by
  ## (`startWindowResize`) for a part of the 3.1 frame.
  case onScreen(p)
  of fpCaption: wpCaption
  of fpLeft: wpLeft
  of fpRight: wpRight
  of fpTop: wpTop
  of fpBottom: wpBottom
  of fpTopLeft: wpTopLeft
  of fpTopRight: wpTopRight
  of fpBottomLeft: wpBottomLeft
  of fpBottomRight: wpBottomRight
  else: wpClient

proc classicPartAt(x, y: int): WindowPart =
  ## (`windowPartAt` for the drivers whose system asks where the frame is
  ## before a press comes: the part of the 3.1 frame at `x`, `y` in the
  ## window's pixels; none while a menu is open, which a press closes. The
  ## maximize button is `wpMaxButton`: Windows 11 shows its snap layouts
  ## over it, and the press still comes here)
  if not ui.ownFrame or ui.captionH == 0 or ui.popup != 0: return wpClient
  let z = max(1, zoomLevel())
  let lx = x div z
  let p = framePartAt(if ui.rtl: ui.w - 1 - lx else: lx, y div z)
  if p == fpMaximize: wpMaxButton else: systemPart(p)

windowPartAt = classicPartAt

proc frameCursor(p: FramePart): CursorKind =
  case onScreen(p)
  of fpLeft, fpRight: curSizeWE
  of fpTop, fpBottom: curSizeNS
  of fpTopLeft, fpBottomRight: curSizeNWSE
  of fpTopRight, fpBottomLeft: curSizeNESW
  else: curDefault

proc sizeGripMark*(r: Rect) =
  ## A size grip in `r` (the bottom right corner of a window): three
  ## ridges across the corner, light over dark, as on the status bars of
  ## the Windows that came after 3.1. Right to left, it is drawn mirrored,
  ## in the bottom left corner.
  if r.w <= 0 or r.h <= 0: return
  let u = max(1, r.w div 16)               # (16: a scroll bar's width at 100 %)
  let x1 = r.x + r.w - 1 - u
  let y1 = r.y + r.h - 1 - u
  for k in 0 .. 2:
    let d = (3 + 4 * k) * u
    for i in 0 ..< u:
      line(x1 - d - i, y1, x1, y1 - d - i, th.light)
    for i in 1 .. 2 * u:
      line(x1 - d - u - i + 1, y1, x1, y1 - d - u - i + 1, th.shadow)

proc sizingBorder*(r: Rect; border, corner: int) =
  ## The 3.1 window's sizing border round `r`: the gray band between two
  ## black lines, cut by dark lines `corner` pixels from each corner -- the
  ## parts that size the window both ways. A window that keeps its size
  ## (`setResizable`) has the band without the cuts, as 3.1's dialogs had.
  windowFrame(r, border)
  if border < 3 or not resizable(): return
  let band = border - 2
  for x in [r.x + corner, r.x + r.w - corner]:
    vline(x, r.y + 1, band, th.frame)
    vline(x, r.y + r.h - 1 - band, band, th.frame)
  for y in [r.y + corner, r.y + r.h - 1 - corner]:
    hline(r.x + 1, y, band, th.frame)
    hline(r.x + r.w - 1 - band, y, band, th.frame)

proc openControlMenu() =
  ui.popup = ClassicMenuId
  ui.menuOpen = false
  ui.popupHi = -1
  ui.redraw = true

var captionPic: tuple[bmp: Bitmap; size, source: int]

proc captionPicture(want: int): Bitmap =
  ## (the app's icon for a title bar `want` device pixels high: the window
  ## icon's picture of that size, or the next larger)
  if windowIcon.len < 3: return nil
  if captionPic.bmp != nil and captionPic.size == want and captionPic.source == windowIcon.len:
    return captionPic.bmp
  var at = 0
  var best = -1
  var bestN = 0
  while at + 2 <= windowIcon.len:
    let n = int(windowIcon[at])
    if n <= 0 or at + 2 + n * n > windowIcon.len: break
    if best < 0 or (bestN < want and n > bestN) or (n >= want and n < bestN):
      best = at
      bestN = n
    at += 2 + n * n
  if best < 0: return nil
  let b = newBitmap(bestN, bestN)
  for i in 0 ..< bestN * bestN: b.px[i] = windowIcon[best + 2 + i]
  b.changed()
  captionPic = (b, want, windowIcon.len)
  b

proc captionTitle(left, right, y, h: int; fg: Color) =
  ## (a title bar's icon and title between `left` and `right`: centred, or
  ## at the left -- `captionAlign`, `captionIcon`, `captionStyle`)
  let st = captionTitleStyle()
  var x0 = left
  var pic: Bitmap
  var ps = 0
  if captionIcon:
    ps = max(8, h - dp(6))
    pic = captionPicture(ps * pxScale)
    if pic == nil: ps = 0
  let room = right - x0 - dp(8) - (if ps > 0: ps + dp(6) else: 0)
  let t = ellipsize(ui.title, room, st)
  let tw = textWidth(t, st)
  let whole = tw + (if ps > 0: ps + dp(6) else: 0)
  var x = if captionAlign == caLeft: x0 + dp(6)
          else: x0 + max(dp(4), (right - x0 - whole) div 2)
  if ps > 0:
    drawBitmap(rect(x, y + (h - ps) div 2, ps, ps), pic)
    x += ps + dp(6)
  text(x, y + (h - lineHeight(st)) div 2, t, fg, st)

proc classicCaption() =
  ## (the 3.1 frame's title bar: drawn first in the frame, so its presses
  ## are its own; the border is drawn last, over the bars, by
  ## `classicFrameEnd`)
  classicDrawn = ui.frameNo
  pushLayer(LayerBase)
  defer: popLayer()
  let f = frameLayout()
  let maxed = windowMaximized()
  # the frame takes the mouse (in front of the dialogs too) unless a menu is
  # open, which a press anywhere closes
  let free = ui.popup == 0
  let part = framePartAt(ui.mx, ui.my)
  if ui.pressed and not ui.pressUsed and part != fpNone:
    if part == fpControlBox and ui.popup == ClassicMenuId:
      # (its own menu open: a second click closes the window, one closes the menu)
      ui.pressUsed = true
      ui.popup = 0
      ui.redraw = true
      if ui.clicks >= 2: requestClose()
    elif free:
      ui.pressUsed = true
      case part
      of fpControlBox:
        if ui.clicks >= 2: requestClose() else: openControlMenu()
      of fpMinimize, fpMaximize, fpClose:
        classicHeld = part
        ui.redraw = true
      of fpCaption:
        if ui.clicks >= 2 and resizable(): maximizeWindow(not maxed)
        elif ui.clicks < 2: startWindowMove()
      else:
        startWindowResize(systemPart(part))
  if classicHeld != fpNone and (ui.released or not ui.mouseDown):
    if ui.released and part == classicHeld:
      case classicHeld
      of fpMinimize: minimizeApp()
      of fpClose: requestClose()
      else: maximizeWindow(not maxed)
    classicHeld = fpNone
    ui.redraw = true
  # the keyboard: Alt+Space opens the control menu; Alt+F4 closes (Windows
  # closes on its own)
  if not ui.keyUsed and AltPressed in ui.mods:
    if ui.key == KeySpace:
      ui.keyUsed = true
      if ui.popup == ClassicMenuId: ui.popup = 0 else: openControlMenu()
    elif ui.key == KeyF4 and not defined(windows):
      ui.keyUsed = true
      requestClose()
  if free and ui.active == 0 and not ui.mouseDown:
    let c = frameCursor(part)
    if c != curDefault: ui.cursor = c
    if canHover():
      case part
      of fpMinimize: ui.tip = "Minimize"
      of fpMaximize: ui.tip = if maxed: "Restore" else: "Maximize"
      of fpClose: ui.tip = "Close"
      else: discard
  # draw: the title bar in the active colors (white while another window is
  # in front), the line under it, its buttons, the title
  let (tbg, tfg) = titleColors(ui.active31 and windowActive())
  let cap = f.caption
  titleBar(cap, ui.active31 and windowActive())
  hline(cap.x, cap.y + cap.h, cap.w, th.frame)
  let cb = f.controlBox
  captionButton(cb, false)
  vline(cb.x + cb.w, cap.y, cap.h, th.frame)
  controlMenuMark(cb)
  for (r, p) in [(f.minimize, fpMinimize), (f.maximize, fpMaximize), (f.close, fpClose)]:
    if r.w <= 0: continue            # (no maximize button: a window that keeps its size)
    vline(r.x, r.y, r.h, th.frame)
    let face = rect(r.x + 1, r.y, r.w - 1, r.h)
    let down = classicHeld == p and part == p and ui.mouseDown
    captionButton(face, down)
    captionMark(face, (case p
                       of fpMinimize: cmMinimize
                       of fpClose: cmClose
                       else: (if maxed: cmRestore else: cmMaximize)), down)
  captionTitle(cb.x + cb.w + 1, f.minimize.x, cap.y, cap.h, tfg)
  # (nothing under the frame answers the mouse)
  ui.blockers.add rect(0, 0, ui.w, f.border + ui.captionH)
  if f.border > 0:
    ui.blockers.add rect(0, 0, f.border, ui.h)
    ui.blockers.add rect(ui.w - f.border, 0, f.border, ui.h)
    ui.blockers.add rect(0, ui.h - f.border, ui.w, f.border)
  let grip = sizeGrip()
  if grip.w > 0: ui.blockers.add grip
  # the control menu
  # (hanging from the box, as a menu bar's menu from its title)
  if ui.popup == ClassicMenuId and
     beginPopupMenu(ClassicMenuId, cb.x, cap.y + ui.captionH, fixedTop = true):
    let sizes = resizable()
    if menuItem("&Restore", enabled = maxed): maximizeWindow(false)
    if menuItem("&Move", enabled = not maxed): startWindowMove(keyboard = true)
    if menuItem("&Size", enabled = sizes and not maxed):
      startWindowResize(wpBottomRight, keyboard = true)
    if menuItem("Mi&nimize"): minimizeApp()
    if menuItem("Ma&ximize", enabled = sizes and not maxed): maximizeWindow(true)
    menuSeparator()
    if menuItem("&Close", "Alt+F4"): requestClose()
    menuSeparator()
    # (the user's choice of frame, kept for the app: `userFrameChoice`)
    if userFrameChoice and
       menuItem(if platformName() == "windows": "&Windows' Own Frame" else: "&Desktop's Own Frame"):
      chooseClassicFrame(false)
    # (the title bars' buttons, as "Title bar buttons" in `appearanceSettings`)
    if menuItem(if captionButtons == cbWin95: "Windows 3.1 &Buttons" else: "Windows 95 &Buttons"):
      captionButtons = if captionButtons == cbWin95: cbWin31 else: cbWin95
      noteLookChanged()
      ui.redraw = true
    menuSeparator()
    if menuItem("&Larger", "Ctrl++", enabled = uiScale() < 300):
      setUiScale(scaleStep(1))
    if menuItem("Sm&aller", "Ctrl+-", enabled = uiScale() > 50):
      setUiScale(scaleStep(-1))
    if menuItem("N&ormal size", "Ctrl+0", enabled = uiScale() != 100):
      setUiScale(100)
    endMenu()

proc classicFrameEnd() =
  ## (end of the frame: the sizing border over the bars and the content
  ## that reach the window's edges; the sizing arrows over it)
  if not ui.ownFrame or ui.captionH == 0: return
  # (an app whose own loop does not call `captionBar`: its title bar now)
  if classicDrawn != ui.frameNo: classicCaption()
  let f = frameLayout()
  if f.border > 0:
    pushLayer(LayerBase)
    sizingBorder(rect(0, 0, ui.w, ui.h), f.border, f.corner)
    # (the size grip, over what is in the corner: the content's, a scroll
    # bar's corner, the status bar's end)
    let grip = sizeGrip()
    if grip.w > 0:
      fill(grip, th.face)
      sizeGripMark(grip)
    popLayer()
  if ui.popup == 0 and ui.active == 0 and not ui.mouseDown:
    let c = frameCursor(framePartAt(ui.mx, ui.my))
    if c != curDefault: ui.cursor = c

endFrameHooks.add classicFrameEnd

# ---- the title bar on phones ---------------------------------------------------

proc captionBar*() =
  ## The window's 3.1 title bar where the app draws it. Phones and tablets:
  ## the system does not draw one there -- navy from the top of the screen
  ## (under the status bar, whose icons turn white over it), the
  ## control-menu box (zoom, minimize, close; also Alt+Space), the title,
  ## and the minimize button where the system has one (Android); a window
  ## besides the app's also gets the close button (`captionButtons`).
  ## Desktops with the 3.1 frame on (`setClassicFrame`): the title bar
  ## inside the sizing border, its control-menu box, its minimize, maximize
  ## and close buttons. `app` calls it every frame; with the system's frame
  ## it draws nothing.
  if ui.ownFrame:
    if ui.captionH > 0: classicCaption()
    return
  if ui.captionH == 0:
    if ui.ownCaption and ui.safe.top > 0 and glassLook():
      # (the app's own bars: the status bar over it -- black in Gloss, as phones had it then, and
      # in Matte; Glass's the window's)
      pushLayer(LayerBase)
      defer: popLayer()
      fill(rect(0, 0, ui.w, ui.safe.top), statusBarColor())
    return
  pushLayer(LayerBase)
  defer: popLayer()
  let top = ui.safe.top
  let ch = ui.captionH
  # (the newer looks: their title bar's color, Gloss's steel blue lit from above; under the
  # system's status bar the same, darker)
  if glassLook(): titleBar(rect(0, top, ui.w, ch), true)
  else: fill(rect(0, top, ui.w, ch), titleColors(true).bg)
  if top > 0: fill(rect(0, 0, ui.w, top), statusBarColor())
  let cap = rect(ui.safe.left, top, ui.w - ui.safe.left - ui.safe.right, ch)
  let s = ch - 6
  let boxR = rect(cap.x + 3, cap.y + 3, s, s)
  let id = idOf("captionbar")
  let menuId = id + 1
  # the control-menu box: a gray square with the "space bar"
  let hit = interact(id + 2, boxR, focusable = false)
  if accessOn:
    accessNode(arButton, "Window menu", id = id + 2, r = boxR,
               states = {asExpandable} + (if ui.popup == menuId: {asExpanded} else: {}))
  box(boxR, th.frame)
  captionButton(inset(boxR, 1), hit.down)
  controlMenuMark(inset(boxR, 1), hit.down)
  if hit.clicked or (ui.key == KeySpace and AltPressed in ui.mods and
                     canInput() and not ui.keyUsed):
    ui.keyUsed = true
    ui.popup = menuId
    ui.menuOpen = false
    ui.popupHi = -1
    ui.redraw = true
  var right = cap.x + cap.w
  # a window besides the app's (where the system draws no frame round it):
  # Windows 95's close button -- not the app's own window, which a phone
  # closes with Back and a kiosk's screen must not close with a tap
  if inWindow() and captionButtons == cbWin95:
    let xr = rect(right - s - 3, cap.y + 3, s, s)
    let xh = interact(id + 4, xr, focusable = false)
    if accessOn: accessNode(arButton, "Close", id = id + 4, r = xr)
    box(xr, th.frame)
    captionButton(inset(xr, 1), xh.down)
    captionMark(inset(xr, 1), cmClose, xh.down)
    if xh.clicked: requestClose()
    right = xr.x
  # the minimize button, where the system can do it
  let canMin = platformName() == "android"
  if canMin:
    let mr = rect(right - s - 3, cap.y + 3, s, s)
    let mh = interact(id + 3, mr, focusable = false)
    if accessOn: accessNode(arButton, "Minimize", id = id + 3, r = mr)
    box(mr, th.frame)
    captionButton(inset(mr, 1), mh.down)
    captionMark(inset(mr, 1), cmMinimize, mh.down)
    if mh.clicked: minimizeApp()
    right = mr.x
  # (a desktop's window: dragged by its title bar)
  when not (defined(android) or defined(ios)):
    let barR = rect(boxR.x + boxR.w + 3, cap.y, right - (boxR.x + boxR.w + 3), ch)
    if canInput() and hover(barR) and takePress(): discard startWindowMove()
  # the title, centered between them (or as `captionAlign` says)
  let titleInk = if glassLook(): titleColors(true).fg else: th.selectText
  if captionAlign == caLeft or captionIcon or captionStyle != TextStyle():
    captionTitle(boxR.x + boxR.w + 3, right - 3, cap.y, ch, titleInk)
  else:
    let room = right - (boxR.x + boxR.w) - 12
    let t = ellipsize(ui.title, room, style(bold = true))
    let tw = textWidth(t, true)
    let tx = max(boxR.x + boxR.w + 6, cap.x + (cap.w - tw) div 2)
    if glossLook(): text(tx, cap.y + (ch - FontH) div 2 - 1, t, withAlpha(black, 110), true)
    text(tx, cap.y + (ch - FontH) div 2, t, titleInk, true)
  # its menu
  if ui.popup == menuId and inWindow() and beginPopupMenu(menuId, boxR.x, cap.y + ch):
    # (a window besides the app's: its size is the app's)
    if menuItem("&Close", "Alt+F4"): requestClose()
    endMenu()
  elif ui.popup == menuId and beginPopupMenu(menuId, boxR.x, cap.y + ch):
    if menuItem("&Larger", "Ctrl++", enabled = uiScale() < 300):
      setUiScale(scaleStep(1))
    if menuItem("&Smaller", "Ctrl+-", enabled = uiScale() > 50):
      setUiScale(scaleStep(-1))
    if menuItem("&Normal size", "Ctrl+0", enabled = uiScale() != 100):
      setUiScale(100)
    menuSeparator()
    if canMin and menuItem("Mi&nimize"): minimizeApp()
    if menuItem("&Close", "Alt+F4"): requestClose()
    endMenu()

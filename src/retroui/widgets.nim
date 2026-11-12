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
import std/unicode except strip   # (its strip cuts letters: docs/nim-bugs.md)
import uirelays/input
import core, nerdicons, pixelicons, busy
from typeset import bidiInfo, visualOrderOf, isMark, shownRtl, plainLetters, joinsAt

template th: untyped = ui.theme

const CaretBlinkFor* = 10_000
  ## How long a caret blinks after it last moved, in milliseconds; then it
  ## stays shown, and a window left with a text box focused runs no frames.

var
  caretT: int      ## when the caret last moved; it blinks from there
  repeatAt: int    ## next auto-repeat of a held scroll arrow or spin button
  grab: int        ## where a dragged scroll thumb was taken hold of

# ---- look -------------------------------------------------------------------

proc raised*(r: Rect; t = 2) =
  ## A raised 3D edge `t` pixels thick inside `r`.
  for i in 0 ..< t:
    hline(r.x, r.y + i, r.w - i, th.light)
    vline(r.x + i, r.y, r.h - i, th.light)
    hline(r.x + i, r.y + r.h - 1 - i, r.w - i, th.shadow)
    vline(r.x + r.w - 1 - i, r.y + i, r.h - i, th.shadow)

proc sunken*(r: Rect) =
  ## A 1-pixel sunken 3D edge inside `r`.
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

proc raisedFace*(f: Rect; bevel = 2) =
  ## The 3D edge of a raised face inside its black border: white at the
  ## top left (and, with `bevel` 2, a softer line inside it), gray at the
  ## bottom right -- the look of the Win31 desktop.
  hline(f.x, f.y, f.w - 1, th.light)
  vline(f.x, f.y, f.h - 1, th.light)
  if bevel >= 2 and f.w > 4 and f.h > 4:
    hline(f.x + 1, f.y + 1, f.w - 3, softLight())
    vline(f.x + 1, f.y + 1, f.h - 3, softLight())
  hline(f.x, f.y + f.h - 1, f.w, th.shadow)
  vline(f.x + f.w - 1, f.y, f.h, th.shadow)

proc buttonFace*(r: Rect; pressed: bool; t = 1; rounded = true; bevel = 2;
                 hot = false) =
  ## A push button's face: a black border, the gray face with its raised
  ## edge (`bevel` 2: two highlight lines, 1: one), or sunk in while
  ## `pressed`. `t` 2 adds the ring of the default button around it (one
  ## pixel apart, as the Win31 desktop draws it). `hot`: the mouse is over
  ## it (a little lighter). (`rounded` is kept for compatibility.)
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
  ## with a gray inner shadow at the top left.
  box(r, if enabled: th.edge else: th.gray)
  if r.w > 4 and r.h > 4:
    hline(r.x + 1, r.y + 1, r.w - 2, th.shadow)
    vline(r.x + 1, r.y + 1, r.h - 2, th.shadow)

proc etchedBox*(r: Rect) =
  ## A group box's etched line: gray, with white one pixel down and right.
  box(rect(r.x + 1, r.y + 1, r.w - 1, r.h - 1), th.light)
  box(rect(r.x, r.y, r.w - 1, r.h - 1), th.line)

proc etchedLine*(x, y, w: int) =
  ## A horizontal etched separator.
  hline(x, y, w, th.line)
  hline(x, y + 1, w, th.light)

proc titleColors*(active: bool): tuple[bg, fg: Color] =
  ## A title bar's colors: navy for the window in front, white for the
  ## others (`Theme.inactiveTitle`).
  if active: (th.select, th.selectText)
  else: ((if th.inactiveTitle.a != 0: th.inactiveTitle else: th.window),
         (if th.inactiveTitleText.a != 0: th.inactiveTitleText else: th.text))

proc windowFrame*(r: Rect; border = 5) =
  ## A window's frame, `border` pixels wide: a black line, the gray band
  ## with its 3D edge, and the black line around the inside (the title bar
  ## and the client area go inside `inset(r, border)`).
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
  ## the gray face with its edge, sunk in while pressed.
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

proc focusDots*(r: Rect) = dots(r, th.text)
  ## The dotted rectangle around the widget with the keyboard focus.

template itemTextY*(y: int): int = y + (ItemH - FontH) div 2
  ## Text in a list or menu row of `ItemH` pixels, centered.

template boxH*: int =
  ## Height of a check box or radio button row: a touch screen gets a
  ## finger-sized row around the same 13-pixel box.
  (if fingers(): CtrlH else: max(dp(13), FontH))

proc checkBox*(b: Rect; checked, down, enabled: bool) =
  ## The square of a check box (pixel exact at 100%, drawn smooth when
  ## scaled).
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

proc radioDisc*(x, y, d: int; selected, down, enabled: bool) =
  ## The circle of a radio button, `d` pixels across, top-left at `x`, `y`.
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
  text(r.x, r.y + (r.h - FontH) div 2, s, th.text)
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
  ## whole text is looked up before it wraps. `literal`: shown as it is --
  ## a file's name: not translated, its '&' kept.
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

proc wrapUncached(s: string; maxW: int; bold: bool): seq[string] =
  for para in s.split('\n'):
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
  ## `fill`, `box`, `hline`, `vline`, `text` and `image`.
  result = place(w, h, fill = w <= 0)
  ui.lastId = 0
  ui.lastRect = result

# ---- buttons ----------------------------------------------------------------

proc buttonWidth*(label: string): int =
  ## How wide `button(label)` is.
  max(dp(72), labelWidth(label) + dp(24))

proc button*(label: string; isDefault = false; enabled = true;
             w = 0): bool {.discardable.} =
  ## A push button; true when clicked. `isDefault` = Enter clicks it.
  let id = idOf(label)
  let bw = if w > 0: w else: buttonWidth(label)
  let r = place(bw, CtrlH)
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
  buttonFace(r, hit.down, if thick: 2 else: 1, hot = enabled and hovered(r))
  let tw = labelWidth(label)
  let d = if hit.down: 1 else: 0
  let tx = r.x + (r.w - tw) div 2 + d
  let ty = r.y + (r.h - FontH) div 2 + d
  if not enabled: drawLabel(tx + 1, ty + 1, label, th.light)   # embossed, as 3.1 grays text
  drawLabel(tx, ty, label, if enabled: th.text else: th.gray)
  if hit.focused: focusDots(rect(tx - 2, ty - 1, tw + 4, FontH + 2))
  if accessOn:
    accessNode(arButton, label, id = id, r = r,
               states = (if isDefault: {asDefault} else: {}) + offWhen(enabled))
  hit.clicked

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
  let d = if pressed: 1 else: 0
  let tx = r.x + (r.w - textWidth(label, st)) div 2 + d
  let ty = r.y + (r.h - lineHeight(st)) div 2 + d
  if not enabled: text(tx + 1, ty + 1, label, th.light, st)
  text(tx, ty, label, if enabled: th.text else: th.gray, st)
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
  checkBox(b, v, hit.down, enabled)
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
            enabled = true): bool {.discardable.} =
  ## One option of a group: selected when `v == value`; true when chosen.
  ## The options sharing `v` are a group: the arrow keys move the choice
  ## (and the focus) between them, as in 3.1.
  let id = idOf(v, label)
  let gk = cast[uint](addr v)
  let tw = labelWidth(label)
  let r = place(dp(19) + tw + 2, boxH)
  let d = dp(12)
  var hit = interact(id, r, enabled = enabled)
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
        if v != prevValues[to]:
          v = prevValues[to]
          result = true
        ui.keyUsed = true
        ui.redraw = true
  if hit.clicked and v != value:
    v = value
    result = true
  radioDisc(r.x, r.y + (r.h - d) div 2, d, v == value, hit.down, enabled)
  let y0 = r.y + (r.h - FontH) div 2
  drawLabel(r.x + dp(19), y0, label, if enabled: th.text else: th.gray)
  if hit.focused: focusDots(rect(r.x + dp(17), y0 - 1, tw + 4, FontH + 2))
  if accessOn:
    let k = accessNode(arRadioButton, label, id = id, r = r,
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
  # thumb as raised faces in black borders
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
    if multi: ui.takesEnter = true
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
  fill(area, if invalid and enabled: mixColor(th.field, InvalidRed, 0.3) else: th.field)
  if not frameless: fieldFrame(area, enabled)
  if invalid and enabled: box(area, InvalidRed)
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
    let lst = TextStyle(size: 1, rtl: g.rtl)
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
  endKeepSides()
  # its menu: a right click, a long press, the menu key
  # (its name made only when a menu is open: a frame takes no memory)
  template menuKey: string = "edit-menu:" & $uint32(id)
  if enabled and canInput() and ui.rpressed and mouseIn(area):
    ui.focus = id
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
           enabled = true; readOnly = false; invalid = false): bool {.discardable.} =
  ## A one-line text box bound to `s`; true when the text changed.
  ## `readOnly`: selected and copied, not changed. `invalid`: red, what is
  ## typed is not right yet (a form says so as it is typed).
  let r = place(if w > 0: w else: 0, EditH, fill = w <= 0)
  editAt(idOf(s, "edit"), s, r, false, password, enabled, readOnly = readOnly,
         invalid = invalid)

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
  var nsel = sel
  var follow = false
  if enabled and canInput():
    scrollWheel(id, off, maxOff, r, 3 * ItemH)
    scrollPan(id, off, maxOff, r)
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
  fill(area, th.field)
  fieldFrame(area, enabled)
  pushClip(inset(area, 1))
  let top = off div ItemH
  for i in top ..< min(n, top + vis + 2):
    let y = r.y + 1 + i * ItemH - off
    let ir = rect(area.x + 1, y, area.w - 2, ItemH)
    if i != sel and enabled and hovered(ir): fill(ir, hoverColor())
    if i == sel:
      fill(ir, if enabled: th.select else: th.gray)
      drawItem(ir.x + 2, itemTextY(y), ir.w, items[i], th.selectText, tabs)
      if hit.focused: dots(ir, th.selectText)
    else:
      drawItem(ir.x + 2, itemTextY(y), ir.w, items[i],
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
               preview: ItemPreview = nil): bool =
  ## The list a combo box drops down. Runs in the popup layer.
  var st = state(id)
  let vis = min(items.len, 8)
  let viewH = vis * ItemH
  let maxOff = max(0, items.len * ItemH - viewH)
  var off = clamp(st.scrollY, 0, maxOff)
  pushLayer(LayerPopup)
  ui.popupRectNow = r
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
  fill(area, th.field)
  box(area, th.edge)
  pushClip(inset(area, 1))
  let top = off div ItemH
  for i in top ..< min(items.len, top + vis + 1):
    let ir = rect(area.x + 1, area.y + 1 + i * ItemH - off, area.w - 2, ItemH)
    if i == ui.popupHi: fill(ir, th.select)
    if preview != nil:
      pushClip(ir)
      preview(i, ir, i == ui.popupHi)
      popClip()
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
  fill(field, th.field)
  fieldFrame(field, enabled)
  let s = if sel >= 0 and sel < items.len: tr(items[sel]) else: ""
  let ty = r.y + (r.h - FontH) div 2
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
  # (Home / End pick the first / last when it is closed)
  if enabled and hit.focused and canInput() and not open and items.len > 0 and
     ui.key in {KeyHome, KeyEnd} and not ui.keyUsed:
    let to = if ui.key == KeyHome: 0 else: items.high
    if to != sel:
      sel = to
      result = true
    ui.keyUsed = true
  let o = if pressedBtn: 1 else: 0
  let c = if enabled: th.frame else: th.gray
  arrow(btn.x + btn.w div 2 + o, btn.y + btn.h div 2 - 2 + o, dDown, c)
  hline(btn.x + btn.w div 2 - 3 + o, btn.y + btn.h div 2 + 3 + o, 7, c)
  if ui.popup == id:
    let vis = min(items.len, 8)
    var pr = rect(r.x, r.y + r.h - 1, r.w, vis * ItemH + 2)
    if pr.y + pr.h > ui.h: pr.y = r.y - pr.h + 1
    if popupList(id + 17, pr, items, sel, preview): result = true

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
  sunken(chan)
  hline(chan.x + 1, chan.y + 1, chan.w - 2, th.frame)
  let cx = chan.x + (clamp(v, lo, hi) - lo) * travel div span
  let thumb = rect(cx - tw div 2, r.y, tw, tht)
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
  let inner = inset(r, 1)
  let done = rect(inner.x, inner.y, int(inner.w.float * f + 0.5), inner.h)
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
    text(tx, ty, s, th.selectText)
    popClip()

proc spin*(v: var int; lo, hi: int; w = 80; step = 1;
           enabled = true): bool {.discardable.} =
  ## A number box with up and down arrows bound to `v` in `lo..hi`: type a
  ## number, click or hold the arrows, or with the focus Up / Down (`step`),
  ## Page Up / Page Down (ten steps) and the wheel.
  let r = place(w, EditH)
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
  let aw = if fingers(): dp(26) else: dp(16)            # the arrows: finger-sized on touch
  let ups = rect(r.x + r.w - aw, r.y, aw, r.h div 2 + 1)
  let downs = rect(r.x + r.w - aw, r.y + r.h div 2, aw, r.h - r.h div 2)
  if editAt(editId, st.buf, rect(r.x, r.y, r.w - aw + 1, r.h), false, false,
             enabled, {'0'..'9', '-'}):
    try: nv = parseInt(st.buf)
    except ValueError: discard
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
  for i, b in [ups, downs]:
    let pr = ui.active == id + 40 + i.uint32 and ui.mouseDown and mouseIn(b)
    buttonFace(b, pr, rounded = false, bevel = 1)
    let o = if pr: 1 else: 0
    arrow(b.x + b.w div 2 + o, b.y + b.h div 2 + o, if i == 0: dUp else: dDown,
          if enabled: th.frame else: th.gray, 3)
  ui.lastId = editId
  ui.lastRect = r

proc popupSlider*(v: var int; lo, hi: int; w = 0; unit = "%";
                  enabled = true): bool {.discardable.} =
  ## A number box with a slider that drops down from its arrow, as a tool's
  ## options bar has for Opacity, Flow or Tolerance: type the number; or
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
  var allowed = {'0'..'9', '-'}
  for c in unit: allowed.incl c
  var buf = st.buf
  var nv = v
  if editAt(editId, buf, field, false, false, enabled, allowed):
    var digits = ""
    for c in buf:
      if c in {'0'..'9'} or (c == '-' and digits.len == 0): digits.add c
    try: nv = parseInt(digits)
    except ValueError: discard
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

proc endGroup*() =
  ## Ends a `beginGroup`: draws the box and its title.
  let (cell, title) = groupEnd()
  if accessOn: accessEnd(cell)
  let top = FontH div 2 - 1
  etchedBox(rect(cell.x, cell.y + top, cell.w, cell.h - top))
  if title.len > 0:
    let tw = labelWidth(title)
    fill(cell.x + 6, cell.y, tw + 8, FontH, th.window)
    drawLabel(cell.x + 10, cell.y, title, th.text)

template group*(title: string; body: untyped) =
  ## A group box: a frame with a title around `body`.
  beginGroup(title)
  body
  endGroup()

var tabStack: seq[tuple[x, y, w, selX, selW, tabH: int; id: Id; same: bool]]

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
  ## panels, the documents' tabs and the dialogs' tabs.
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
    # panel's gray, and labels were gray on dark gray -- hard to read)
    contrastInk(back, contrastInk(back, th.window, th.light), th.gray)

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
  let pal = tabLook == tlPalette
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
  tabStack.add (cell.x, cell.y, cell.w, selX, selW, tabH, id, sameHeight)
  pushFrame(rect(cell.x + Pad + 2, cell.y + tabH + Pad + 2,
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
  let page = rect(t.x, t.y + t.tabH, t.w, h + 2*Pad + 4)
  if accessOn: accessEnd(page)
  if tabLook == tlPalette:
    var ps = state(t.id + 3)
    if ps.aux != page.h:
      ps.aux = page.h
      state(t.id + 3) = ps
      ui.redraw = true                 # (its gray drawn as tall as it is now)
  let line = if tabLook == tlPalette: th.frame else: th.edge
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
  pushClip(inner)
  beginClipped()
  ui.focusRect = rect(0, 0, 0, 0)
  panelStack.add (id, inner, inner.y + Pad - y, -1, true)
  pushFrame(rect(inner.x + Pad, inner.y + Pad - y,
                 inner.w - 2 * Pad - (if over: SbW else: 0), inner.h - 2 * Pad))

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
  if maxY > 0:
    scrollWheel(id, y, maxY, inner, 3 * ItemH)
    scrollPan(id, y, maxY, inner)
    scrollTick(id, y, maxY)
    let f = wantSeen()                        # Tab to a widget out of view
    if f.w > 0:
      if f.y < inner.y: y = clamp(y - (inner.y + Pad - f.y), 0, maxY)
      elif f.y + f.h > inner.y + inner.h:
        y = clamp(y + (f.y + f.h + Pad - (inner.y + inner.h)), 0, maxY)
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

type PopMenu = object
  id: Id
  x, y, w, cy: int
  n, bg, measured, level: int
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

var
  menuLetters: Table[Id, seq[char]]
    ## (each open menu's items' letters, as the last frame drew them: a
    ## letter two items have lights the next of them, as Windows' menus do)
  barX: int
  barIds: seq[Id]
  menuSwitch: int
  pms: seq[PopMenu]  ## the open menu, and its open submenu
  subId: Id          ## the open submenu
  subHi = -1         ## highlighted item in the submenu
  lastPopup: Id
  subSpan = (a: -1, b: -1)  ## the open submenu's drawing (put over its menu)
  subRect: Rect      ## where the open submenu was drawn
  aimX, aimY: int    ## where the pointer was last frame (on its way to a submenu?)
  waitRow = -1       ## the row the pointer rests on while a submenu stays open
  waitSince: int

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
  return subHi

proc beginMenubar*() =
  ## Starts the menu bar (see `menubar`).
  pushLayer(LayerBase)              # above the scrolled content, unclipped
  let r = rect(ui.winX, ui.barY, ui.w, MenuH)
  fill(r, th.window)
  hline(ui.winX, r.y + r.h, ui.w, th.edge)
  notePlaced(rect(r.x, r.y, r.w, r.h + 1))
  barX = ui.winX + ui.safe.left
  barIds.setLen(0)
  menuSwitch = 0
  shiftContent(MenuH + 1)
  if accessOn: accessBegin(arMenuBar, "", r)

proc endMenubar*() =
  ## Ends the menu bar: F10 opens its first menu; Left / Right go along it.
  if accessOn: accessEnd()
  popLayer()
  ui.barY += MenuH + 1
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

proc beginPopupMenu(id: Id; x, y: int; level = 0; fixedTop = false): bool =
  ## (`fixedTop`: a menu bar's menu, which hangs from its title)
  let st = state(id)
  if level == 0:
    subSpan = (-1, -1)
    if id != lastPopup:
      lastPopup = id
      subId = 0
      waitRow = -1
  # A menu that would pass the bottom of the screen moves up as far as it
  # needs (by last frame's height in one column); only one taller than the
  # whole screen -- or a menu bar's, which stays under its title -- goes on
  # in columns beside.
  let top = dp(2)
  let bottom = ui.h - dp(6)
  let nh = st.caret
  var y = y
  if not fixedTop and nh > 0 and y + nh > bottom: y = max(top, bottom - nh)
  var m = PopMenu(id: id, x: x, y: y, w: max(st.aux, dp(120)), cy: y + 3,
                  level: level, subAt: -1, fixedTop: fixedTop)
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
  if m.x + m.w * cols + 3 > ui.winX + ui.w: m.x = max(ui.winX, ui.winX + ui.w - m.w * cols - 3)
  m.colX = m.x
  pushLayer(LayerPopup)
  m.mark = cmdMark()
  m.bg = reserveFill()
  pms.add m
  if accessOn:
    # (its items go inside; its place is known once they are drawn)
    accessBegin(arMenu, "", rect(m.x, y, m.w, MenuRowH), accessSubId(id, 9999))
  true

proc endMenu*() =
  ## Ends an open menu (`beginMenu`, `beginSubmenu`, `beginContextMenu`,
  ## `beginPopupMenuFor`): draws its frame; Up, Down, Home, End, Esc.
  var m = pms.pop()
  if menuLetters.getOrDefault(m.id) != m.letters: menuLetters[m.id] = move m.letters
  if menuLetters.len > 64: menuLetters.clear()     # (menus opened long ago)
  let r = rect(m.x, m.y, m.w * m.cols, max(m.cy, m.maxCy) - m.y + 3)
  notePlaced(r)
  if accessOn: accessEnd(r)
  patchFill(m.bg, r, th.window)
  box(r, th.edge)
  # the hard black shadow of the Win31 menus, 3 pixels down and right
  fill(r.x + 3, r.y + r.h, r.w, 3, th.frame)
  fill(r.x + r.w, r.y + 3, 3, r.h, th.frame)
  if m.level == 0: ui.popupRectNow = rect(r.x, r.y, r.w + 3, r.h + 3)
  else: ui.popupRect2Now = rect(r.x, r.y, r.w + 3, r.h + 3)
  # (the lines between columns)
  for c in 1 ..< m.cols: vline(m.x + c * m.w, m.y + 2, r.h - 4, th.shadow)
  if m.level == 1:
    subSpan = (m.mark, cmdMark())
    subRect = rect(r.x, r.y, r.w + 3, r.h + 3)
    if subRect.contains(point(ui.mx, ui.my)): waitRow = -1
  if m.level == 0:
    aimX = ui.mx
    aimY = ui.my
    if subId == 0: subRect = rect(0, 0, 0, 0)
  if m.level == 0 and subSpan.a >= 0:
    # (the submenu over the rows and frame of its menu drawn after it)
    let e = cmdMark()
    if subSpan.a < subSpan.b and subSpan.b <= e:
      reorderSpans([subSpan, (subSpan.b, e)], [1, 0])
    subSpan = (-1, -1)
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
  if canInput() and not ui.keyUsed and (m.level == 1 or subId == 0):
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
      if m.level == 1: subId = 0
      else: menuSwitch = -1
      ui.keyUsed = true
    of KeyRight:
      if m.level == 0: menuSwitch = 1
      ui.keyUsed = true
    of KeyEsc:
      if m.level == 1: subId = 0
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
  let tr = rect(barX, ui.barY, labelWidth(title, boldMenus) + dp(16), MenuH)
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
  if open:
    fill(tr, th.select)
    drawLabel(lx, tr.y + (MenuH - FontH) div 2, title, th.selectText, boldMenus)
  else:
    if barLive and canHover() and not ui.mouseDown and
       tr.contains(point(ui.mx, ui.my)):
      fill(inset(tr, 1), hoverColor())
    drawLabel(lx, tr.y + (MenuH - FontH) div 2, title, th.text, boldMenus)
  if open: beginPopupMenu(id, tr.x, tr.y + tr.h, fixedTop = true) else: false

template menu*(title: string; body: untyped) =
  ## A menu of the menu bar; `body` (its items) runs only while it is open.
  if beginMenu(title):
    body
    endMenu()

type MenuShown* = object
  ## What `showMenu` put aside (for `hideMenu`).
  popup, sub: Id
  open: bool
  hi, subHi: int

proc showMenu*(path: openArray[string]): MenuShown =
  ## Opens the menu bar's menu `path[0]` -- and in it the submenu `path[1]`
  ## -- as if it had been clicked, for the menu bar drawn next: a designer
  ## showing the menu whose items are being set, a tour of an app. The
  ## titles are written as in `menu` and `submenu`; `hideMenu` puts back
  ## what was open.
  result = MenuShown(popup: ui.popup, open: ui.menuOpen, hi: ui.popupHi, sub: subId,
                     subHi: subHi)
  if path.len == 0: return
  let id = peekId(fnv(path[0], fnv("menu:")))     # (the id its `menu` will take)
  ui.popup = id
  ui.menuOpen = true
  ui.popupHi = -1
  subId = if path.len > 1: mixId(id, fnv("sub:" & path[1])) else: Id(0)
  subHi = -1

proc hideMenu*(s: MenuShown) =
  ## What was open before `showMenu` open again.
  ui.popup = s.popup
  ui.menuOpen = s.open
  ui.popupHi = s.hi
  subId = s.sub
  subHi = s.subHi

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
  let c = if not enabled: th.gray elif hi: th.selectText else: th.text
  if hi: fill(r, th.select)
  let ty = r.y + (r.h - FontH) div 2
  if checked: pattern(r.x + dp(7), r.y + (r.h - 7) div 2, checkMark, "k", [c])
  drawLabel(r.x + dp(22), ty, label, c, boldMenus)
  if shortcut.len > 0:
    text(r.x + r.w - dp(14) - textWidth(shortcut, boldMenus), ty, shortcut, c, boldMenus)
  if arrowRight: arrow(r.x + r.w - dp(10), r.y + r.h div 2, dRight, c)

proc overSub(): bool =
  ## (the pointer is on the open submenu, over its menu's rows: they leave
  ## it alone)
  pm.level == 0 and subId != 0 and subRect.contains(point(ui.mx, ui.my))

proc towardSub(): bool =
  ## (the pointer moving toward the open submenu: inside the triangle from
  ## where it was last frame to the submenu's near edge. The rows it crosses
  ## on the way -- another column of the menu among them -- leave it open;
  ## moving any other way, down the menu say, the row under it takes over
  ## at once, as Windows' and the Mac's menus do)
  if subId == 0 or subRect.w == 0 or ui.mouseDown or ui.mx == aimX: return false
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
  if ui.pressed: return true
  if ui.mouseMoved:
    if not towardSub():
      waitRow = -1
      return true
    waitRow = i                           # (on its way: the rest starts again)
    waitSince = ui.now
    wakeIn(SubMenuRest)
    return false
  if waitRow != i: return false
  let left = SubMenuRest - (ui.now - waitSince)
  if left > 0:
    wakeIn(left)
    return false
  waitRow = -1
  true

proc menuKeysLive(): bool =
  ## Keys reach this menu level: a menu with an open submenu leaves them
  ## to the submenu.
  canInput() and not ui.keyUsed and (pm.level == 1 or subId == 0)

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
  let i = pm.n
  inc pm.n
  let level = pm.level
  let r = menuSlot(MenuRowH)
  if canInput() and not overSub():
    if mouseIn(r) and (ui.mouseMoved or ui.mouseDown or (level == 0 and waitRow == i)):
      if level == 0 and subId != 0:
        if rowTakesOver(i):
          hiOf(level) = i
          subId = 0
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
    subId = 0
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
  let i = pm.n
  inc pm.n
  let level = pm.level
  let id = mixId(pm.id, fnv("sub:" & label))
  let r = itemRow(label, "", false, enabled, true, i)
  if menuLetter(label, enabled and level == 0, i, level):
    # (its letter: it opens, its first item lit)
    ui.popupHi = i
    subId = id
    subHi = 0
    ui.redraw = true
  if accessOn:
    let k = accessNode(arMenuItem, label, id = id, r = r,
                       states = offWhen(enabled) + {asExpandable} +
                                (if subId == id: {asExpanded} else: {}))
    if ui.popupHi == i and level == 0: accessFocus(k)
  if accessPress != 0 and accessPress == id and enabled and level == 0:
    accessPress = 0
    ui.popupHi = i
    subId = id
    subHi = 0
    ui.redraw = true
  if level != 0 or not enabled: return false
  if canInput() and not overSub():
    if mouseIn(r) and (ui.mouseMoved or ui.pressed or waitRow == i):
      if subId == 0 or (subId != id and rowTakesOver(i)):
        ui.popupHi = i
        subId = id
        subHi = -1
        ui.redraw = true
      elif subId == id:
        ui.popupHi = i
    if ui.popupHi == i and subId != id and not ui.keyUsed and
       (ui.key == KeyRight or ui.key == KeyEnter):   # (an open menu's)
      ui.keyUsed = true
      subId = id
      subHi = 0
      ui.redraw = true
  if subId != id: return false
  # Right of the whole menu (all its columns), else left of it, else on the
  # side with more room
  let st = state(id)
  let sw = max(st.aux, dp(120)) * menuCols(st, r.y - 3, false)
  let mw = pm.w * max(menuCols(state(pm.id), pm.y, pm.fixedTop), pm.cols)
  var x = pm.x + mw - 3
  let right = ui.winX + ui.w
  if x + sw + 3 > right:
    if pm.x - sw + 3 >= ui.winX: x = pm.x - sw + 3
    elif right - (pm.x + mw) >= pm.x - ui.winX: x = max(ui.winX, right - sw - 3)
    else: x = ui.winX
  beginPopupMenu(id, x, r.y - 3, 1)

template submenu*(label: string; body: untyped) =
  ## An item that opens a menu of its own (one level deep).
  if beginSubmenu(label):
    body
    endMenu()

proc menuSeparator*() =
  ## A line between groups of menu items (none at the top of a column).
  pm.natural += dp(9)
  if pm.cy + dp(9) + MenuRowH > pm.bottom and pm.cy > pm.y + 3 + MenuRowH:
    newMenuColumn()                      # (the next row starts a column: no line)
    return
  if pm.cy <= pm.y + 3 and pm.cols > 1: return
  notePlaced(rect(pm.colX + 1, pm.cy, pm.w - 2, dp(9)))
  hline(pm.colX + 3, pm.cy + dp(4), pm.w - 6, th.shadow)
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
                items: seq[tuple[key, label: string; enabled, down: bool]]]
  ## The tool bar being drawn: buttons that do not fit go into its "more"
  ## menu (`chosen`: the one picked there, which clicks next frame).

# A run of tool buttons -- a tool bar's, between its boxes; a palette's tools
# -- is one stop of Tab, as Windows' tool bars are: the arrows go along it,
# Home and End to its ends, Space or Enter presses the one lit. It is the
# buttons drawn one after another with no other control between them.
var trun: tuple[id, last: Id; frame, n, hot, mask: int; on: bool]

proc runNext(mask, n, start, step: int): int =
  ## (the next button of the run that is enabled, from `start` going `step`)
  var i = start
  for _ in 0 ..< n:
    i = (i + step + n) mod n
    if i >= 62 or (mask and (1 shl i)) != 0: return i
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
      if trun.hot >= count or (trun.hot < 62 and (was and (1 shl trun.hot)) == 0):
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
  if enabled and i < 62: trun.mask = trun.mask or (1 shl i)
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
  if result: ui.focusRect = r

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
  fill(r, th.face)
  hline(ui.winX, r.y, ui.w, th.light)
  hline(ui.winX, r.y + r.h - 1, ui.w, th.shadow)
  pushRow(rect(ui.winX + ui.safe.left + 6, r.y + 3, ui.w - ui.safe.left - 12, tbar.h - 6),
          tbar.h - 6)
  shiftContent(tbar.h)
  if accessOn: accessBegin(arToolBar, "", r)
  beginArea(makeId(uint32(ui.barY) * 0x9E3779B1'u32 + 0x7B))   # (F6: the tool bar)
  tbar.on = true
  tbar.full = false
  tbar.y = r.y
  tbar.items.setLen(0)

proc overflowsNow(w: int): bool {.inline.} =
  tbar.on and (tbar.full or available() < w + (CtrlH + 1) + Gap)

template overflows(w: int; key, label: string; enabled, down: bool; clicked: var bool): bool =
  ## In a tool bar too narrow for it: the button goes into the "more" menu
  ## (and is clicked when it was picked there). (`key` and `label` are made
  ## only then: a tool button takes no memory every frame for them.)
  (if overflowsNow(w): overflowItem(key, label, enabled, down, clicked) else: false)

proc overflowItem(key, label: string; enabled, down: bool; clicked: var bool): bool =
  tbar.full = true
  tbar.items.add (key, label, enabled, down)
  if tbar.chosen == key:
    tbar.chosen = ""
    clicked = enabled
  true

proc endToolbar*() =
  ## Ends the tool bar: the buttons that did not fit go into its "more" menu.
  tbar.on = false
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

proc picSize(p: ButtonPic): (int, int) =
  if p.glyph.len > 0:
    let st = style(size = if p.size > 0: p.size else: 1.0)
    (textWidth(p.glyph, st), lineHeight(st))
  else: (p.icon.w, p.icon.h)

proc drawPic(p: ButtonPic; x, y: int; enabled: bool) =
  if p.glyph.len > 0:
    text(x, y, p.glyph, if enabled: th.text else: th.gray, style(size = if p.size > 0: p.size else: 1.0))
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

proc button*(label: string; pic: ButtonPic; look = blTextBeside; isDefault = false;
             enabled = true; w = 0; h = 0): bool {.discardable.} =
  ## A push button with a picture: icon only (the label its tooltip), text
  ## only, the text below the icon, or beside it. True when clicked.
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
             enabled = true; w = 0; h = 0): bool {.discardable.} =
  ## `button` with a glyph of the icon font as its picture (`pxSave`,
  ## `nfCopy`...).
  button(label, glyphPic(glyph, 1.0), look, isDefault, enabled, w, h)

proc barButton*(glyph: string; label: string; tip = ""; down = false; enabled = true;
                look = blDefault): bool {.discardable.} =
  ## `barButton` with a glyph of the icon font as its picture.
  barButton(glyphPic(glyph, 1.0), label, tip, down, enabled, look)

proc buttonAt*(key: string; r: Rect; label: string; glyph: string; look = blTextBeside;
               enabled = true; down = false): bool {.discardable.} =
  ## `buttonAt` with a glyph of the icon font as its picture.
  buttonAt(key, r, label, glyphPic(glyph, 1.0), look, enabled, down)

proc toolSeparator*() =
  ## A gap between groups of tool buttons.
  if not (tbar.on and tbar.full): space(8)

proc statusbar*(parts: varargs[string]) =
  ## The status bar at the bottom of the window: the first part takes the
  ## spare room. Content above it can fill down to it (`rows = -1`).
  let h = FontH + 8
  let r = rect(ui.winX, ui.bottom - h, ui.w, h)
  notePlaced(rect(ui.winX, r.y, ui.w, ui.h - r.y))
  pushLayer(LayerBase)
  defer: popLayer()
  fill(rect(ui.winX, r.y, ui.w, ui.h - r.y), th.face)
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

proc beginDialog*(open: var bool; title: string; width: int): bool =
  ## Starts a modal dialog (see `dialog`): true while it is `open`.
  let closeOff = dlgCloseOff
  dlgCloseOff = false
  if not open: return false
  let id = idOf(open, "dialog")
  var st = state(id)
  ui.curDialog = id
  ui.dialogTopNow = id
  pushLayer(LayerDialog)
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
  windowFrame(r)
  fill(bar, tbg)
  hline(bar.x, bar.y + bar.h, bar.w, th.frame)
  captionButton(sysBox, ui.active == id + 1)
  vline(sysBox.x + sysBox.w, sysBox.y, sysBox.h, th.frame)
  controlMenuMark(sysBox)
  if xBox.w > 0:
    vline(xBox.x, xBox.y, xBox.h, th.frame)
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
  fill(client, th.window)
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
    # the standard scroll bar, fingers too (they can also drag the content)
    y = clamp(y, 0, hi)
    scrollBarFor(id + 77, id, rect(c.x + c.w - SbW, c.y, SbW, c.h), true,
                 y, hi, max(ItemH, c.h - 2 * ItemH), ItemH)
    y = clamp(y, 0, hi)
    if y != st.caret:
      st.caret = y
      ui.redraw = true
  state(id) = st
  popLayer()
  ui.curDialog = 0

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
  if not ui.ownFrame: return
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
  if not ui.ownFrame: return fpNone
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
  if not ui.ownFrame or ui.popup != 0: return wpClient
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
  fill(cap, tbg)
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
  let left = cb.x + cb.w + 1
  let room = f.minimize.x - left - dp(8)
  let t = ellipsize(ui.title, room, style(bold = true))
  text(left + max(dp(4), (f.minimize.x - left - textWidth(t, true)) div 2),
       cap.y + (cap.h - FontH) div 2, t, tfg, true)
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
  if not ui.ownFrame: return
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
    classicCaption()
    return
  if ui.captionH == 0: return
  pushLayer(LayerBase)
  defer: popLayer()
  let top = ui.safe.top
  let ch = ui.captionH
  fill(rect(0, 0, ui.w, top + ch), th.select)
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
  # the title, centered between them
  let room = right - (boxR.x + boxR.w) - 12
  let t = ellipsize(ui.title, room, style(bold = true))
  let tw = textWidth(t, true)
  text(max(boxR.x + boxR.w + 6, cap.x + (cap.w - tw) div 2),
       cap.y + (ch - FontH) div 2, t, th.selectText, true)
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

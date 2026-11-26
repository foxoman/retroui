## Tests of what a control takes to look different (docs/customizing.md):
## the accent button, a text style and a height for buttons and number
## boxes, groups with a title strip, option buttons in a box, the gauge in
## bands and the range bar, the state colours of every scheme, a tool bar's
## separator line and space, a tag with an icon, `withTheme` and
## `withTextStyle` putting back what was -- and the colour schemes: each
## one's text readable on its window, its highlight, its fields.

import std/math
import retroui
import retroui/[charts, textwidgets, textengine]
import std/[strutils, algorithm]
import harness

fakeDriver()
startApp("looks", W, H)

proc count(c: Color; r: Rect): int =
  ## (the pixels of one colour in `r`)
  let want = (uint32(c.r) shl 16) or (uint32(c.g) shl 8) or uint32(c.b)
  for y in max(0, r.y) ..< min(H, r.y + r.h):
    for x in max(0, r.x) ..< min(W, r.x + r.w):
      if px(x, y) == want: inc result

proc countNear(c: Color; r: Rect; tol = 40): int =
  ## (the pixels close to one colour in `r`: Glass lights what is on from above, so a shade of it)
  for y in max(0, r.y) ..< min(H, r.y + r.h):
    for x in max(0, r.x) ..< min(W, r.x + r.w):
      let p = px(x, y)
      if abs(int((p shr 16) and 255) - int(c.r)) + abs(int((p shr 8) and 255) - int(c.g)) +
         abs(int(p and 255) - int(c.b)) <= tol: inc result

# ---- buttons: the accent, a style, a height ---------------------------------------------------------

var plain, accent, big, tall, pic: Rect
var hits = 0
let bands = [Band(upTo: 10, label: "Low"), Band(upTo: 20, label: "Fine"), Band(upTo: 30, label: "High"),
             Band(upTo: 40, label: "Over")]
view = proc () =
  button("Plain")
  plain = ui.lastRect
  if button("Go", accent = true): inc hits
  accent = ui.lastRect
  button("Big", style = style(bold = true, size = 2.0))
  big = ui.lastRect
  button("Tall", h = 50, w = 70)
  tall = ui.lastRect
  button("Save", nfCheck, accent = true, style = style(size = 1.5), h = 44)
  pic = ui.lastRect
run(3)
doAssert plain.h == tall.h - (50 - plain.h) and tall.h == 50 and tall.w == 70
doAssert big.h > plain.h + 8, "a bigger label: a taller button"
doAssert pic.h == 44
doAssert count(ui.theme.select, accent) > accent.w * accent.h div 3, "the accent button: the highlight's colour"
doAssert count(ui.theme.select, plain) == 0
click(accent)
run(2)
doAssert hits == 1
move(W - 4, H - 4)                 # (off it: under the pointer its face is lighter)
run(2)
# a scheme's own accent
var mine = ui.theme
mine.accent = color(200, 30, 90)
mine.accentText = color(255, 255, 255)
let before = ui.theme
ui.theme = mine
ui.redraw = true
run(2)
doAssert count(color(200, 30, 90), accent) > accent.w * accent.h div 3 and accentColor() == color(200, 30, 90)
ui.theme = before
doAssert accentColor() == ui.theme.select and accentInk() == ui.theme.selectText

# ---- number boxes and text boxes: a height, a style ---------------------------------------------------

var n = 5
var f = 2.5
var s = "text"
var spinR, intR, numR, editR, spinPlain: Rect
view = proc () =
  spin(n, 0, 99)
  spinPlain = ui.lastRect
  spin(n, 0, 99, w = 120, h = 46, style = style(bold = true, size = 1.6))
  spinR = ui.lastRect
  intEdit(n, h = 40, style = style(size = 1.4))
  intR = ui.lastRect
  numberEdit(f, h = 40)
  numR = ui.lastRect
  edit(s, h = 38, style = style(size = 1.3))
  editR = ui.lastRect
run(3)
doAssert spinR.h == 46 and spinR.w == 120 and intR.h == 40 and numR.h == 40 and editR.h == 38
doAssert spinPlain.h < 30
# its arrows grew with it: a press near the right edge, three quarters down, counts down
down(spinR.x + spinR.w - 8, spinR.y + spinR.h * 3 div 4)
up(spinR.x + spinR.w - 8, spinR.y + spinR.h * 3 div 4)
run(2)
doAssert n == 4
down(spinR.x + spinR.w - 8, spinR.y + spinR.h div 4)
up(spinR.x + spinR.w - 8, spinR.y + spinR.h div 4)
run(2)
doAssert n == 5

# ---- a group with a title strip; option buttons in a box ---------------------------------------------

var unit = 0
var strip, inner, boxA, boxB, after: Rect
view = proc () =
  group "Your Measurements", glCaption:
    strip = ui.lastRect
    row([120, 120]):
      radio("Metric", unit, 0, boxed = true)
      boxA = ui.lastRect
      radio("Imperial", unit, 1, boxed = true)
      boxB = ui.lastRect
    label "inside"
    inner = ui.lastRect
  label "after"
  after = ui.lastRect
run(3)
doAssert count(ui.theme.select, rect(0, 0, W, inner.y)) > 2000, "the strip, in the highlight's colour"
doAssert after.y > inner.y + inner.h and boxB.x >= boxA.x + boxA.w
doAssert boxA.w >= 110 and boxA.h > 20
# the whole box takes the press, not the dot alone
down(boxB.x + boxB.w - 6, boxB.y + boxB.h - 5)
up(boxB.x + boxB.w - 6, boxB.y + boxB.h - 5)
run(2)
doAssert unit == 1
# ... and the arrows go between the boxes
key(KeyLeft)
run(2)
doAssert unit == 0
# every group that way, where the app says
groupLook = glCaption
view = proc () =
  group "All of them":
    label "x"
    inner = ui.lastRect
run(2)
doAssert count(ui.theme.select, rect(0, 0, W, inner.y)) > 1000
groupLook = glEtched
ui.redraw = true
run(2)
doAssert count(ui.theme.select, rect(0, 0, W, inner.y)) == 0

# ---- the gauge in bands, the range bar ---------------------------------------------------------------

doAssert bandOf(bands, 5) == 0 and bandOf(bands, 10) == 1 and bandOf(bands, 39.9) == 3 and bandOf(bands, 99) == 3
doAssert bandOf(bands, NaN) == -1 and bandOf([], 1) == -1
var gaugeR, barR: Rect
var value = 15.0
view = proc () =
  gauge("Level", value, 0, 40, bands, height = 180)
  gaugeR = ui.lastRect
  rangeBar(bands, value, 0)
  barR = ui.lastRect
run(3)
# the bands take the scheme's state colours by turn: blue, green, amber, red (a little
# brighter on a light scheme, as areas; pale in the bar's cells, under their names)
for c in [infoColor(), goodColor(), warnColor(), badColor()]:
  let tone = mixColor(c, color(255, 255, 255), 0.2)
  doAssert count(tone, gaugeR) > 150, "a band on the dial"
  doAssert count(mixColor(ui.theme.field, tone, 0.45), barR) > 400, "its cell in the bar"
doAssert barR.y >= gaugeR.y + gaugeR.h and barR.h > 20
# the marker over the value's cell (the second), nowhere else
let cellW = barR.w div 4
doAssert count(ui.theme.text, rect(barR.x + cellW, barR.y, cellW, 8)) > 20
doAssert count(ui.theme.text, rect(barR.x, barR.y, cellW, 8)) == 0
# what cannot be drawn is not: no number, one end on the other, no bands
for (v, lo, hi) in [(NaN, 0.0, 40.0), (5.0, 3.0, 3.0), (1e308, 0.0, 40.0), (-5.0, 0.0, 40.0)]:
  let (v2, lo2, hi2) = (v, lo, hi)
  view = proc () =
    gauge("Level", v2, lo2, hi2, bands, height = 120)
    rangeBar(bands, v2, lo2)
    gauge("None", v2, lo2, hi2, [], height = 120)
    rangeBar([], v2, lo2)
  run(2)

# ---- every scheme: its state colours, its text readable ----------------------------------------------

proc lum(c: Color): float =
  proc ch(v: uint8): float =
    let x = v.float / 255
    if x <= 0.03928: x / 12.92 else: pow((x + 0.055) / 1.055, 2.4)
  0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b)
proc contrast(a, b: Color): float =
  let (x, y) = (lum(a), lum(b))
  (max(x, y) + 0.05) / (min(x, y) + 0.05)

doAssert builtinThemes.len == 34
var names: seq[string]
for (name, t) in builtinThemes:
  doAssert name notin names, name
  names.add name
  ui.theme = t
  doAssert contrast(t.text, t.window) >= 4.5, name & ": text on the window"
  doAssert contrast(t.selectText, t.select) >= 4.5, name & ": the highlight"
  doAssert contrast(t.fieldText, t.field) >= 4.5, name & ": a field"
  doAssert contrast(t.text, t.face) >= 4.5, name & ": a button"
  doAssert contrast(accentInk(), accentColor()) >= 4.5, name & ": the accent button"
  for c in [goodColor(), warnColor(), badColor(), infoColor()]:
    doAssert contrast(c, t.window) >= 1.25, name & ": a state colour seen on the window"
  for c in [goodBack(), warnBack(), badBack(), infoBack()]:
    doAssert contrast(t.text, c) >= 4.5, name & ": text on a state's background"
  doAssert goodColor() != badColor() and warnColor() != infoColor()
for want in ["Notes", "Snow", "Mint", "Sky", "Blossom", "Lavender", "Sunset", "Graphite", "Dusk", "Night Notes",
             "Glass Light", "Glass Dark", "Matte Light", "Matte Dark", "Gloss Light", "Gloss Dark"]:
  doAssert want in names, want
ui.theme = before

# ---- the Glass look: rounded, see-through, the highlight on what is on; every scheme; not the high
# contrast ones. Matte and Gloss the same, each with its own schemes ------------------------------------

var gb, gc, gs: Rect
var gOn = true
var gSw = true
view = proc () =
  button("Glass")
  gb = ui.lastRect
  checkbox("On", gOn)
  gc = ui.lastRect
  toggle("Switch", gSw)
  gs = ui.lastRect
for look in [lookGlass, lookMatte, lookGloss]:
  let (ownLight, ownDark) = lookSchemes(look)
  doAssert ownLight != ownDark and ownLight.window != Classic.window
  for (t, want) in [(ownLight, true), (ownDark, true), (Emerald, true), (HighContrast, false)]:
    ui.theme = t
    uiLook = look
    invalidate()
    run(3)
    doAssert glassLook() == want
    doAssert matteLook() == (want and look == lookMatte) and glossLook() == (want and look == lookGloss)
    let corner = px(gb.x, gb.y)
    let win = (uint32(t.window.r) shl 16) or (uint32(t.window.g) shl 8) or uint32(t.window.b)
    # (Gloss on a light window: its pinstripes, a shade lighter than it -- `glossPinstripes`)
    let stripe = (min(255'u32, uint32(t.window.r) + 6) shl 16) or (min(255'u32, uint32(t.window.g) + 6) shl 8) or
                 min(255'u32, uint32(t.window.b) + 5)
    if want:
      doAssert corner == win or (glossLook() and corner == stripe),
        $look & ": a button's corner: rounded off, the window under it " & $corner
      doAssert countNear(accentColor(), gc) > 10, $look & ": a check box ticked: in the highlight"
      # (Gloss's switch: iOS 6's blue in the highlight's hue -- `glossTint`)
      let on = if glossLook(): glossTint(color(0, 127, 234)) else: accentColor()
      doAssert countNear(on, gs) > 20, $look & ": a switch on: in the highlight"
    else:
      doAssert corner != win, "High Contrast: its square, black-edged buttons"
    uiLook = lookClassic
    invalidate()
    run(3)
    doAssert px(gb.x, gb.y) != win or not want, "Classic again: square " & $gb & " " & $px(gb.x, gb.y)
ui.theme = before

# ---- a font list: the fonts used last, then all of them from A to Z ---------------------------------

block:
  let all = fontFamilies()
  var order = fontListOrder()
  var az = all
  az.sort(proc (a, b: string): int = cmpIgnoreCase(a, b))
  doAssert order == az, "none used yet: A to Z"
  noteFontUsed("FreeSerif")
  noteFontUsed("FreeMono")
  noteFontUsed("FreeSerif")
  noteFontUsed("No Such Font")
  order = fontListOrder()
  doAssert order[0] == "FreeSerif" and order[1] == "FreeMono" and order[2 .. ^1] == az,
           "the last used first (one there is), then A to Z: " & $order[0 .. 3]
  recentFonts.setLen(0)

# ---- the tool bar: a line between groups, room ------------------------------------------------------

var b1, b2, b3, b4, sepR: Rect
view = proc () =
  toolbar:
    toolButton("One")
    b1 = ui.lastRect
    toolSeparator(line = true)
    sepR = ui.lastRect
    toolButton("Two")
    b2 = ui.lastRect
    toolSpace(40)
    toolButton("Three")
    b3 = ui.lastRect
    toolSpace()
    toolButton("Help")
    b4 = ui.lastRect
run(3)
doAssert sepR.x >= b1.x + b1.w and b2.x >= sepR.x + sepR.w and sepR.w < 16
doAssert count(ui.theme.shadow, sepR) >= sepR.h - 6 and count(ui.theme.light, sepR) >= sepR.h - 6, "the etched line"
doAssert b3.x >= b2.x + b2.w + 40, "40 pixels of room"
doAssert b4.x + b4.w >= W - 12, "what comes after the space: at the bar's right end"

# ---- a tag with an icon; colours and a text style for a part, then what was -------------------------

var tag, tagIcon, bigTag: Rect
view = proc () =
  pill("Fine", goodColor())
  tag = ui.lastRect
  pill("Fine", goodColor(), nfCheck)
  tagIcon = ui.lastRect
  withTextStyle(style(size = 1.6)):
    pill("Fine", goodColor(), nfCheck)
    bigTag = ui.lastRect
  doAssert textScaleNow() == 1
  let t0 = ui.theme
  withTheme(accentTheme()):
    doAssert ui.theme.face == accentColor()
    button("In the accent's colours")
  doAssert ui.theme == t0
  # (put back after an error too)
  try:
    withTextStyle(style(bold = true, size = 2.0)):
      withTheme(accentTheme()):
        raise newException(ValueError, "x")
  except ValueError: discard
  doAssert textScaleNow() == 1 and ui.theme == t0
run(3)
doAssert tagIcon.w > tag.w + 6 and bigTag.w > tagIcon.w + 6 and bigTag.h > tagIcon.h, $tag & $tagIcon & $bigTag

# ---- docs/customizing.md's own samples: controls put together, a control drawn -------------------

proc unitField(label: string; v: var int; lo, hi: int; unit: string): bool =
  ## A number with its unit after it; true when it changed.
  let before = v
  row([70, 120, -1]):
    label label
    spin(v, lo, hi, w = 120, h = 40, style = style(bold = true, size = 1.5))
    label unit
  v != before

template panel(title: string; body: untyped) =
  group title, glCaption:
    withTextStyle(style(size = 1.1)):
      body

proc star(on: var bool; label: string): bool {.discardable.} =
  ## A star that is on or off; true when it was pressed.
  let r = canvas(dp(28), dp(28))
  let id = idOf(on)                          # who it is: its variable
  var hit = interact(id, r)                  # hover, down, clicked, focused
  spaceKey(id, hit)                          # Space and Enter press it
  if hit.clicked:
    on = not on
    result = true
  let c = if on: warnColor() elif hit.hover: ui.theme.shadow else: ui.theme.gray
  disc(float(r.x + r.w div 2), float(r.y + r.h div 2), float(r.w) / 2 - 3, c)
  if hit.focused: focusDots(inset(r, 2))     # 3.1's dotted rectangle (the ring is the kit's)
  accessNode(arCheckBox, label, id = id, r = r, states = (if on: {asChecked} else: {}))

var heightCm = 175
var changed = 0
var fav = false
var pressed = 0
var starR, fieldR: Rect
view = proc () =
  if unitField("Height:", heightCm, 50, 250, "cm"): inc changed
  fieldR = ui.lastRect
  panel "A panel":
    if star(fav, "Favourite"): inc pressed
    starR = ui.lastRect
run(3)
doAssert starR.w == 28 and starR.h == 28 and not fav
click(starR)
run(2)
doAssert fav and pressed == 1 and count(warnColor(), starR) > 100
key(KeySpace)                                # (it has the focus: Space presses it)
run(2)
doAssert not fav and pressed == 2
heightCm = 180
run(1)
doAssert changed == 0                        # (changed from outside: not by the field)
echo "looks ok"

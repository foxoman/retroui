## Tests of the phone's newer parts (retroui/mobile) and of the Gloss look's iOS 6 colors: round
## buttons, the index down a list's side, message bubbles, the clock, app icons, the textures --
## by the mouse and the keys, in every look --; Gloss's own colors in its schemes, its window's
## pinstripes; a row in a row after one that took the line.

import retroui
import retroui/uirelays/[coords, input]
import harness

fakeDriver()
startApp("phoneparts", W, H)

proc rgb(c: Color): uint32 = (uint32(c.r) shl 16) or (uint32(c.g) shl 8) or uint32(c.b)

proc near(p: uint32; c: Color; tol = 30): bool =
  abs(int((p shr 16) and 255) - int(c.r)) + abs(int((p shr 8) and 255) - int(c.g)) +
    abs(int(p and 255) - int(c.b)) <= tol

proc countNear(c: Color; r: Rect; tol = 30): int =
  for y in max(0, r.y) ..< min(H, r.y + r.h):
    for x in max(0, r.x) ..< min(W, r.x + r.w):
      if near(px(x, y), c, tol): inc result

proc inLook(look: UiLook; body: proc ()) =
  uiLook = look
  ui.theme = lookSchemes(look).light
  body()
  uiLook = lookClassic
  ui.theme = Classic

# ---- round buttons: a click, Space, disabled; Gloss's white ring --------------------------------

for look in [lookClassic, lookGlass, lookMatte, lookGloss]:
  inLook(look, proc () =
    var adds, removes = 0
    var ar, rr: Rect
    var on = true
    view = proc () =
      row:
        if roundButton(rkAdd, "Add a row", enabled = on): inc adds
        ar = ui.lastRect
        if roundButton(rkRemove): inc removes
        rr = ui.lastRect
    run(2)
    doAssert ar.w > 10 and ar.h == ar.w and rr.x > ar.x
    click(ar, dx = ar.w div 2)
    doAssert adds == 1 and removes == 0, $look
    click(rr, dx = rr.w div 2)
    doAssert removes == 1
    click(ar, dx = ar.w div 2)        # (it takes the focus: Space then clicks it)
    doAssert adds == 2
    key(KeySpace)
    run(2)
    doAssert adds == 3, "Space: " & $look
    if look == lookGloss:
      # (green inside, a white ring round it)
      doAssert countNear(color(4, 143, 1), ar, 60) > 10
      doAssert countNear(color(255, 255, 255), ar, 12) > 6
    on = false
    run(2)
    click(ar, dx = ar.w div 2)
    doAssert adds == 3, "disabled: no click")

# ---- the index: the letter under the finger while it is down, -1 after ---------------------------

block:
  var letters: seq[string]
  for c in 'A' .. 'Z': letters.add $c
  var at = -9
  var seen: seq[int]
  var ir: Rect
  view = proc () =
    at = indexBar(letters, h = 26 * 14)
    ir = ui.lastRect
    if at >= 0: seen.add at
  run(2)
  doAssert at == -1 and ir.h == 26 * 14
  down(ir.x + ir.w div 2, ir.y + 8)
  run(2)
  doAssert at == 0, "the top: A, " & $at
  move(ir.x + ir.w div 2, ir.y + ir.h - 8)
  run(2)
  doAssert at == 25, "dragged down: Z, " & $at
  move(ir.x + ir.w div 2, ir.y + ir.h + 200)
  run(2)
  doAssert at == 25, "past its foot: still Z"
  up(ir.x + ir.w div 2, ir.y + ir.h + 200)
  run(2)
  doAssert at == -1, "let go: none"

# ---- bubbles: the other's on the left, yours on the right ---------------------------------------

inLook(lookGloss, proc () =
  var cells: seq[Rect]
  view = proc () =
    cells.setLen(0)
    messageBubble("Are we still on?", bkTheirs)
    cells.add ui.lastRect
    messageBubble("Yes, at ten.", bkMine, time = "Delivered")
    cells.add ui.lastRect
  run(2)
  doAssert cells.len == 2 and cells[1].y > cells[0].y
  let half0 = rect(cells[0].x, cells[0].y, cells[0].w div 2, cells[0].h)
  let half1 = rect(cells[1].x + cells[1].w div 2, cells[1].y, cells[1].w div 2, cells[1].h)
  doAssert countNear(color(221, 221, 221), half0, 24) > 50, "theirs: gray, on the left"
  doAssert countNear(color(152, 199, 255), half1, 40) > 50, "mine: pale blue, on the right"
  doAssert countNear(color(152, 199, 255), rect(cells[1].x, cells[1].y, cells[1].w div 3, cells[1].h), 40) == 0)

# ---- the clock: its hands, a red second hand ----------------------------------------------------

for look in [lookClassic, lookGloss]:
  inLook(look, proc () =
    var cr: Rect
    view = proc () =
      clockFace(3, 0, 30, size = 120, label = "Sohar")
      cr = ui.lastRect
    run(2)
    doAssert cr.w >= 120 and cr.h > 120
    let face = rect(cr.x + (cr.w - 120) div 2, cr.y, 120, 120)
    doAssert countNear(color(218, 8, 18), face, 60) > 20, "the second hand, red: " & $look
    # (3 o'clock: the hour hand to the right of the middle, nothing of it to the left)
    let cx = face.x + 60
    let cy = face.y + 60
    let ink = if look == lookGloss: color(0, 0, 0) else: ui.theme.text
    doAssert near(px(cx + 20, cy), ink, 40), "the hour hand at three")

# ---- app icons: a click, Enter, the badge -------------------------------------------------------

for look in [lookClassic, lookGloss]:
  inLook(look, proc () =
    var opened = 0
    var r: Rect
    view = proc () =
      if appIcon(nfEnvelope, "Mail", tint = color(36, 112, 216), badge = "3"): inc opened
      r = ui.lastRect
    run(2)
    click(r, dx = r.w div 2, dy = r.h div 3)
    doAssert opened == 1, $look
    key(KeyEnter)                     # (the click gave it the focus)
    run(2)
    doAssert opened == 2, "Enter: " & $look
    doAssert countNear(if look == lookGloss: color(200, 0, 0) else: badColor(), r, 70) > 10, "its badge")

# ---- textures: their own colors, the same every time --------------------------------------------

block:
  var tr: Rect
  view = proc () =
    tr = canvas(0, 140)
    let w = tr.w div 4
    for i, k in [txLinen, txPaper, txFelt, txLeather]:
      texture(rect(tr.x + i * w, tr.y, w, tr.h), k)
  run(2)
  let w = tr.w div 4
  doAssert countNear(color(62, 64, 70), rect(tr.x, tr.y, w, tr.h), 40) > w * tr.h div 2, "linen"
  doAssert countNear(color(252, 243, 192), rect(tr.x + w, tr.y, w, tr.h), 30) > w * tr.h div 2, "paper"
  doAssert countNear(color(36, 106, 58), rect(tr.x + 2 * w, tr.y, w, tr.h), 50) > w * tr.h div 2, "felt"
  doAssert countNear(color(104, 64, 38), rect(tr.x + 3 * w, tr.y, w, tr.h), 50) > w * tr.h div 2, "leather"
  let a = px(tr.x + 17, tr.y + 23)
  run(2)
  doAssert px(tr.x + 17, tr.y + 23) == a, "the same grain each frame"

# ---- Gloss's colors: iOS 6's in Gloss Light, the scheme's hue in another ------------------------

inLook(lookGloss, proc () =
  doAssert glossTint(color(193, 209, 228)) == color(193, 209, 228), "Gloss Light: iOS 6's own"
  let (top, foot) = glossBarColors()
  doAssert top == color(193, 209, 228) and foot == color(85, 112, 148)
  # (the window plain by default, its pinstripes when asked for)
  view = proc () = discard
  run(2)
  for x in W div 2 ..< W div 2 + 14:
    doAssert px(x, H div 2) == rgb(ui.theme.window), "plain"
  glossPinstripes = true
  run(2)
  let a = px(W div 2, H div 2)
  var differs = false
  for x in W div 2 ..< W div 2 + 14:
    if px(x, H div 2) != a: differs = true
  doAssert differs, "pinstripes"
  glossPinstripes = false)

block:
  # (a green scheme: the bar's steel in green)
  uiLook = lookGloss
  var t = GlossLight
  t.select = color(30, 160, 60)
  t.accent = t.select
  ui.theme = t
  let c = glossTint(color(193, 209, 228))
  doAssert c.g > c.b and c.g > c.r, "green: " & $c
  uiLook = lookClassic
  ui.theme = Classic

# ---- a row in a row after one that took the line: the whole of the next line ---------------------

block:
  var a, b: Rect
  view = proc () =
    row:
      row:
        label "The first takes the line"
      row:
        label "x"
        a = ui.lastRect
        label "y"
        b = ui.lastRect
  run(3)
  doAssert a.y == b.y and b.x > a.x, "side by side on the new line: " & $a & " " & $b

echo "phoneparts: ok"

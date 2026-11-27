## Tests of the phone's newer parts (retroui/mobile) and of the Gloss look's iOS 6 colors: round
## buttons, the index down a list's side, message bubbles, the clock, app icons, the textures --
## by the mouse and the keys, in every look --; Gloss's own colors in its schemes, its window's
## pinstripes; a row in a row after one that took the line; vslider, ratingStars, editRow (the minus
## and Delete, the grip dragged, Alt+Down), coverFlow.

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

# ---- vslider: dragged to its top, the keys -------------------------------------------------------

for look in [lookClassic, lookGloss]:
  inLook(look, proc () =
    var v = 0
    var r: Rect
    view = proc () =
      discard vslider(v, -12, 12, h = 200, label = "125")
      r = ui.lastRect
    run(2)
    doAssert r.h > 200 and r.w > 10
    let x = r.x + r.w div 2
    down(x, r.y + (r.h - 20) div 2)
    run(2)
    move(x, r.y - 50)
    run(2)
    up(x, r.y - 50)
    run(2)
    doAssert v == 12, "dragged up past its top: its highest, " & $v & " " & $look
    key(KeyDown); run(2)
    doAssert v == 11
    key(KeyEnd); run(2)
    doAssert v == -12, "End: its lowest")

# ---- ratingStars: a tap, the same again, the keys ------------------------------------------------

block:
  var stars = 0
  var r: Rect
  view = proc () =
    discard ratingStars(stars)
    r = ui.lastRect
  run(2)
  let d = r.w div 5
  click(r, dx = 2 * d + d div 2, dy = r.h div 2)
  doAssert stars == 3, "the third star: 3, " & $stars
  click(r, dx = 2 * d + d div 2, dy = r.h div 2)
  doAssert stars == 0, "the same again: none"
  click(r, dx = 4 * d + d div 2, dy = r.h div 2)
  doAssert stars == 5
  key(KeyLeft); run(2)
  doAssert stars == 4
  typeText("2"); run(2)
  doAssert stars == 2, "a digit: " & $stars

# ---- editRow: the minus then Delete; the grip dragged; Alt+Down ----------------------------------

for look in [lookClassic, lookGloss]:
  inLook(look, proc () =
    var items = @["One", "Two", "Three", "Four"]
    var rows: seq[Rect]
    var last: RowEdit
    view = proc () =
      rows.setLen(0)
      tableGroup "List":
        for i, t in items:
          let e = editRow(t, i)
          rows.add ui.lastRect
          if e.kind != reNone: last = e
      case last.kind
      of reDelete: items.delete(last.index)
      of reMove:
        let x = items[last.index]
        items.delete(last.index)
        items.insert(x, last.to)
      of reNone: discard
      last = RowEdit()
    run(3)
    doAssert rows.len == 4
    # (the minus of "Two", then the Delete that came at its end)
    click(rows[1], dx = 22, dy = rows[1].h div 2)
    run(2)
    doAssert items.len == 4, "the minus alone deletes nothing"
    let delAt = rows[1].x + rows[1].w - 80
    var reddish = 0
    for x in rows[1].x + rows[1].w div 2 ..< rows[1].x + rows[1].w - 10:
      let p = px(x, rows[1].y + rows[1].h div 2)
      if int((p shr 16) and 255) > int((p shr 8) and 255) + 60: inc reddish
    if look == lookGloss: doAssert reddish > 10, "its red Delete: " & $reddish
    var hitDel = false
    for dx in countdown(rows[1].w - 40, rows[1].w div 2, 6):
      if hitDel: break
      click(rows[1], dx = dx, dy = rows[1].h div 2)
      run(2)
      if items.len == 3: hitDel = true
    doAssert hitDel and items == @["One", "Three", "Four"], "Delete: " & $items & " " & $look
    discard delAt
    # (the grip of "One" dragged two rows down)
    run(2)
    let g = rows[0]
    let gx = g.x + g.w - 12
    down(gx, g.y + g.h div 2); run(2)
    for k in 1 .. 8:
      move(gx, g.y + g.h div 2 + k * g.h * 2 div 8); run(2)
    up(gx, g.y + g.h div 2 + g.h * 2); run(3)
    doAssert items == @["Three", "Four", "One"], "dragged down two: " & $items & " " & $look
    # (Alt+Down on the focused row: "Three" after "Four")
    click(rows[0], dx = rows[0].w div 2, dy = rows[0].h div 2)
    run(2)
    key(KeyDown, {AltPressed}); run(3)
    doAssert items == @["Four", "Three", "One"], "Alt+Down: " & $items)

# ---- coverFlow: Right, a tap at its side, a flick, a tap in the middle -----------------------------

block:
  var covers: seq[Bitmap]
  for i in 0 ..< 7:
    let b = newBitmap(20, 20)
    for k in 0 ..< b.px.len: b.px[k] = 0xFF000000'u32 or uint32(i * 30) shl 16
    b.changed()
    covers.add b
  var sel = 0
  var opened = -1
  var r: Rect
  view = proc () =
    let o = coverFlow(covers, sel, ["a", "b", "c", "d", "e", "f", "g"], h = 260)
    if o >= 0: opened = o
    r = ui.lastRect
  run(3)
  click(r, dx = r.w div 2, dy = r.h div 3)
  doAssert opened == 0, "the middle one tapped: opened, " & $opened
  key(KeyRight); run(2)
  doAssert sel == 1
  click(r, dx = r.w - 30, dy = r.h div 3)
  doAssert sel > 1, "a tap at its right side: further on, " & $sel
  key(KeyHome); run(2)
  ticks += 1000; run(2)
  let before = sel
  let y = r.y + r.h div 3
  down(r.x + r.w div 2, y); run(1)
  for k in 1 .. 6:
    move(r.x + r.w div 2 - k * 30, y); ticks += 16; run(1)
  up(r.x + r.w div 2 - 180, y); run(2)
  doAssert sel > before, "dragged to the left: on along, " & $before & " -> " & $sel
  key(KeyEnd); run(2)
  doAssert sel == 6

# ---- sideMenu: the navigation bar's button, a place, a click beside it, Esc; on the right in RTL --

block:
  for look in [lookClassic, lookGlass, lookMatte, lookGloss]:
    uiLook = look
    var open = false
    var place = 0
    var bar = rect(0, 0, 0, 0)
    view = proc () =
      if navBar("Places", menu = true) == npBack: open = true
      bar = ui.lastRect
      sideMenu(open, 240):
        sideMenuHeader("Listen")
        for i, name in ["Home", "Radio", "Library"]:
          if sideMenuItem(name, nfHome, if i == 1: "4" else: "", selected = place == i):
            place = i
            open = false
    run(3)
    accessKeep = true
    run(2)
    let m = findNode(accessLast, "Menu", {arButton})
    doAssert m >= 0, "the navigation bar's menu button"
    click(nodeRect(accessLast[m]), dx = nodeRect(accessLast[m]).w div 2)
    ticks += 400; run(3)
    doAssert open, "its button: the menu out"
    let radio = findNode(accessLast, "Radio", {arButton})
    doAssert radio >= 0 and nodeRect(accessLast[radio]).x < 40, "its items at the left"
    click(nodeRect(accessLast[radio]), dx = 30)
    doAssert place == 1 and not open, "an item: it, the menu in"
    open = true
    ticks += 400; run(3)
    click(rect(W - 20, H div 2, 4, 4), dx = 2)
    doAssert not open, "a click beside it: in"
    open = true
    ticks += 400; run(3)
    key(KeyEsc); run(2)
    doAssert not open, "Esc: in"
    # right to left: from the right
    ui.rtl = true
    open = true
    ticks += 400; run(3)
    let r2 = findNode(accessLast, "Radio", {arButton})
    doAssert r2 >= 0 and nodeRect(accessLast[r2]).x + nodeRect(accessLast[r2]).w > W - 40,
             "right to left: the menu at the right"
    ui.rtl = false
    open = false
    run(2)
    accessKeep = false
  uiLook = lookClassic

# ---- the About box: a phone's page with touch sizes in the newer looks, the desktop's otherwise ----------

block aboutPage:
  accessKeep = true
  var aboutOpen = true
  view = proc () =
    aboutBox(aboutOpen, "Ledger", "2.0", ["Small business accounts."], tagline = "Accounts",
             whatsNew = ["Invoices in PDF"], credits = [RetroFontCredit])
  run(3)
  doAssert findNode(accessLast, "OK", {arButton}) >= 0 and findNode(accessLast, "Website", {arButton}) < 0,
           "Classic: the desktop's About box, OK to close it"
  for look in [lookGloss, lookGlass, lookMatte]:
    uiLook = look
    setControlSizes(csTouch)
    aboutOpen = true
    run(3)
    doAssert findNode(accessLast, "Website", {arButton}) >= 0 and findNode(accessLast, "Copy Info", {arButton}) >= 0 and
             findNode(accessLast, "OK", {arButton}) < 0, $look & ": the phone's page of it"
    let c = findNode(accessLast, "Copy Info", {arButton})
    let cr = nodeRect(accessLast[c])
    if cr.y + cr.h < H:
      click(cr)
      run(2)
      doAssert getClipboardText().len >= 6 and getClipboardText()[0 .. 5] == "Ledger",
               $look & ": Copy Info, the facts on the clipboard"
    setControlSizes(csAuto)
  uiLook = lookClassic
  aboutOpen = false
  run(2)
  accessKeep = false

echo "phoneparts: ok"

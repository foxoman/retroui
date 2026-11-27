## Tests of Gloss on a touch screen: a flick that runs into a page's end goes on past it and
## springs back; pull to refresh's drop; the banner a toast is on a phone; slideToConfirm (all
## the way: once; part way: back, nothing); bigButton; a row's count; the Glass looks' focus
## ring only while the keys move the focus, not after a tap.

import std/os
import retroui
import retroui/uirelays/input
import harness

putEnv("RETRO_TOUCH", "1")
fakeDriver()
startApp("glosstouch", W, H)
doAssert ui.touch, "a touch screen"
uiLook = lookGloss
ui.theme = GlossLight

var passed = 0
template check(cond: bool; what: string) =
  doAssert cond, what
  inc passed
  echo "  ok   ", what

proc near(p: uint32; c: Color; tol = 30): bool =
  abs(int((p shr 16) and 255) - int(c.r)) + abs(int((p shr 8) and 255) - int(c.g)) +
    abs(int(p and 255) - int(c.b)) <= tol

proc countNear(c: Color; r: Rect; tol = 30): int =
  for y in max(0, r.y) ..< min(H, r.y + r.h):
    for x in max(0, r.x) ..< min(W, r.x + r.w):
      if near(px(x, y), c, tol): inc result

proc step(n = 1; ms = 16) =
  for _ in 0 ..< n:
    ticks += ms
    run()

# ---- a flick into the top: past it, and back ------------------------------------------------------

block:
  var firstRow: Rect
  view = proc () =
    beginPanel(-1, "long")
    tableGroup "":
      for i in 0 ..< 40:
        discard tableRow("Row " & $i, "", taChevron)
        if i == 0: firstRow = ui.lastRect
    endPanel()
  step(3)
  let rest = firstRow.y
  # (down the page first, then a quick flick back up into its top)
  let x = W div 2
  down(x, 400); step()
  for k in 1 .. 10:
    move(x, 400 - k * 30); step()
  up(x, 100); step()
  step(60)
  check firstRow.y < rest, "a flick down the page moves it"
  down(x, 100); step()
  for k in 1 .. 4:
    move(x, 100 + k * 60); step(ms = 10)
  up(x, 340); step(ms = 10)
  var most = rest
  for _ in 0 ..< 120:
    step()
    most = max(most, firstRow.y)
  check most > rest + 4, "the flick runs past the top and the page comes down further: " & $(most - rest)
  step(60)
  check firstRow.y == rest, "and springs back to its top"

# ---- pull to refresh: Gloss's drop ----------------------------------------------------------------

block:
  var loading = false
  var asked = 0
  view = proc () =
    beginPanel(-1, "inbox")
    if pullRefresh(loading):
      loading = true
      inc asked
    tableGroup "":
      for i in 0 ..< 5: discard tableRow("Message " & $i)
    endPanel()
  step(3)
  let x = W div 2
  down(x, 100); step()
  for k in 1 .. 8:
    move(x, 100 + k * 12); step()
  let slate = glossTint(color(146, 154, 167))
  check countNear(slate, rect(x - 40, 0, 80, 120), 40) > 40, "the drop, slate gray, as it is pulled"
  for k in 9 .. 20:
    move(x, 100 + k * 12); step()
  up(x, 340); step()
  step(5)
  check asked == 1 and loading, "pulled past the threshold: fresh content asked for, once"
  loading = false
  step(60)

# ---- a toast: the banner across a phone's top -------------------------------------------------------

block:
  view = proc () = label "The page"
  step(2)
  toast("Your order is ready.", title = "Store")
  step(30)
  check countNear(color(0, 0, 0), rect(0, ui.safe.top + 30, W, 6), 10) > W, "the banner: black across the top"
  dismissToast()
  step(2)

# ---- slideToConfirm: all the way, once; part way, back --------------------------------------------

block:
  var done = 0
  var sr: Rect
  view = proc () =
    if slideToConfirm("slide to pay"): inc done
    sr = ui.lastRect
  step(3)
  let y = sr.y + sr.h div 2
  let x0 = sr.x + 20
  down(x0, y); step()
  for k in 1 .. 6:
    move(x0 + k * 30, y); step()
  up(x0 + 180, y); step()
  check done == 0, "let go part way: nothing"
  step(40)
  let knobGray = color(220, 220, 222)
  check countNear(knobGray, rect(sr.x, sr.y, 60, sr.h), 40) > 100, "and the knob slid back to its start"
  down(x0, y); step()
  for k in 1 .. 12:
    move(x0 + k * (sr.w div 10), y); step()
  up(sr.x + sr.w, y); step()
  check done == 1, "dragged to its end: confirmed, once"
  step(5)
  check done == 1, "only once"

# ---- bigButton, a row's count -----------------------------------------------------------------------

block:
  var started = 0
  var br, rr: Rect
  view = proc () =
    if bigButton("Start", btGreen): inc started
    br = ui.lastRect
    tableGroup "":
      discard tableRow("Messages", "", taChevron, count = "3")
      rr = ui.lastRect
  step(3)
  check countNear(color(7, 177, 22), br, 60) > 200, "a big green button"
  click(br, dx = br.w div 2)
  check started == 1, "a tap: clicked"
  check countNear(glossTint(color(135, 149, 175)), rr, 20) > 60, "the count's slate capsule"

# ---- the Glass looks' focus ring: the keys, not a tap -----------------------------------------------

block:
  uiLook = lookGlass
  ui.theme = lookSchemes(lookGlass).light
  var a, b: Rect
  view = proc () =
    discard button("First")
    a = ui.lastRect
    discard button("Second")
    b = ui.lastRect
  step(3)
  let ringC = accentColor()
  click(b, dx = b.w div 2)
  step(2)
  let around = rect(b.x - 4, b.y - 4, b.w + 8, b.h + 8)
  let tapped = countNear(ringC, around, 40)
  key(KeyTab); step(2)
  key(KeyTab, {ShiftPressed}); step(2)
  let keyed = countNear(ringC, around, 40)
  check keyed > tapped + 20, "the ring shows when the keys bring the focus, not after a tap: " &
    $tapped & " / " & $keyed

echo "glosstouch: ", passed, " ok"

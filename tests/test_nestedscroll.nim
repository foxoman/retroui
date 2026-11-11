## Scrolling areas inside one another share a finger's swipe as Android's
## do: a list in a scrolling panel takes the swipes it can follow, and
## passes on the ones it cannot -- at its top swiped down, at its bottom
## swiped up, a swipe up and down over a sideways carousel -- to the panel
## around it; the scroller a gesture began with keeps it, the way back too;
## one that reaches its end in the middle of a gesture hands the rest on.
## The wheel does the same at a list's end, but notches that keep coming
## stay with the scroller they began in.

import harness, retroui
import retroui/uirelays/input

fakeDriver()
startApp("nested scrolling", W, H)

var items: seq[string]
for i in 0 ..< 47: items.add "Server " & $(i + 1)
var sel = 0
var listId: Id
var listR, stripR: Rect
var carousel = 0                     # the carousel's position, pixels
var withCarousel = false

view = proc () =
  panel:
    label "Resolvers"
    discard button("Search")
    label "Pick one:"
    listbox(items, sel, rows = 8)
    listR = ui.lastRect
    listId = ui.lastId
    if withCarousel:
      let r = place(0, dp(60), fill = true)
      stripR = r
      carousel -= takePanX(r)
    for i in 0 ..< 30: label "Detail " & $i
    discard button("Apply")

proc listOff(): int = state(listId).scrollY
proc setListOff(v: int) =
  state(listId).scrollY = v
  run(2)

proc rest() =
  ## (frames until nothing glides on)
  for i in 0 .. 120:
    if not scrolling(listId): break
    run(1)
  run(2)

proc swipe(x, y0, y1: int; flick = false; steps = 8) =
  ## A finger from `y0` to `y1`, held still before it lifts (no flick)
  ## unless `flick`.
  down(x, y0)
  run(1)
  for i in 1 .. steps:
    move(x, y0 + (y1 - y0) * i div steps)
    run(1)
  if not flick: run(8)
  up(x, y1)
  run(2)

ui.touch = true
run(3)
let top0 = listR.y                    # the list's place with the page at its top
proc pageOff(): int = top0 - listR.y  # how far the panel scrolled
let midX = listR.x + listR.w div 2

block a_swipeUpOnListAtTop:
  # the list at its top, the finger up: the list scrolls, the page stays
  doAssert listOff() == 0 and pageOff() == 0
  swipe(midX, listR.y + listR.h - 10, listR.y + 20)
  doAssert listOff() > 0, "the list scrolled: " & $listOff()
  doAssert pageOff() == 0, "the page did not: " & $pageOff()

block b_swipeDownOnListAtTop:
  # the page scrolled down a little (a swipe below the list), the list at
  # its top: a finger down on the list moves the page back
  setListOff(0)
  swipe(midX, H - 40, H - 90)
  let before = pageOff()
  doAssert before > 0 and listR.y > 20, "the page scrolled first, the list in view: " & $before
  doAssert listOff() == 0
  let y = listR.y + 10
  swipe(midX, y, y + 60)
  doAssert listOff() == 0, "the list at its top stays: " & $listOff()
  doAssert pageOff() < before, "the page moved down: " & $before & " -> " & $pageOff()

block c_listAtBottomSwipedUp:
  # the list at its bottom, the finger up on it: the list stays at its end
  # and the page goes on, in the same gesture
  setListOff(1_000_000)
  let bottom = listOff()
  doAssert bottom > 0
  let before = pageOff()
  let y = listR.y + listR.h - 10
  swipe(midX, y, y - 60)
  doAssert listOff() == bottom, "the list stays at its end"
  doAssert pageOff() > before, "the page went on: " & $before & " -> " & $pageOff()
  # and a list near its end that reaches it on the way hands the rest on
  setListOff(bottom - 15)
  let p2 = pageOff()
  let y2 = listR.y + listR.h - 10
  swipe(midX, y2, y2 - 80)
  doAssert listOff() == bottom, "the list reached its end: " & $listOff() & " of " & $bottom
  doAssert pageOff() > p2, "the rest of the swipe moved the page: " & $p2 & " -> " & $pageOff()

block d_theWayBackStaysWithThePage:
  # a gesture that began by moving the page keeps moving it when it turns
  # back over the list, the list at its top
  setListOff(0)
  # (the page scrolled some 40 pixels, the list in view)
  while listR.y < 40:
    swipe(midX, listR.y + listR.h + 20, listR.y + listR.h + 50)
  let before = pageOff()
  doAssert before > 20, "the page is scrolled: " & $before
  let y = listR.y + 20
  down(midX, y)
  run(1)
  for i in 1 .. 6:                    # down: the page (the list is at its top)
    move(midX, y + i * 4)
    run(1)
  let mid = pageOff()
  doAssert mid < before, "the page moved down: " & $mid
  for i in 1 .. 8:                    # back up, over the list
    move(midX, y + 24 - i * 10)
    run(1)
  run(8)
  up(midX, y - 56)
  run(2)
  doAssert listOff() == 0, "the list did not take the gesture back: " & $listOff()
  doAssert pageOff() > mid, "the page followed the finger back: " & $mid & " -> " & $pageOff()

block e_tapSelectsDragDoesNot:
  setListOff(0)
  sel = 0
  run(2)
  let row = listR.y + 1 + 3 * ItemH + ItemH div 2     # the fourth row
  down(midX, row)
  run(1)
  up(midX, row)
  run(2)
  doAssert sel == 3, "a tap picks the row: " & $sel
  let row2 = listR.y + 1 + 1 * ItemH + ItemH div 2
  down(midX, row2)
  run(1)
  for i in 1 .. 4:
    move(midX, row2 - i * 8)
    run(1)
  run(8)
  up(midX, row2 - 32)
  run(2)
  doAssert sel == 3, "a drag picks nothing: " & $sel

block f_carouselInAPanel:
  # a sideways carousel in the panel: up and down on it scrolls the panel,
  # sideways moves it
  withCarousel = true
  setListOff(0)
  run(2)
  # (the carousel brought into view, its middle)
  while stripR.y + stripR.h > H - 20:
    swipe(midX, H - 30, H - 130)
  let before = pageOff()
  let c0 = carousel
  let cy = stripR.y + stripR.h div 2
  swipe(midX, cy, cy - 80)
  doAssert carousel == c0, "a swipe up does not move the carousel: " & $carousel
  doAssert pageOff() > before, "it scrolls the panel: " & $before & " -> " & $pageOff()
  let p2 = pageOff()
  let cy2 = stripR.y + stripR.h div 2
  down(midX + 80, cy2)
  run(1)
  for i in 1 .. 8:
    move(midX + 80 - i * 15, cy2 + (if i mod 2 == 0: 2 else: -2))
    run(1)
  run(8)
  up(midX - 40, cy2)
  run(2)
  doAssert carousel != c0, "a swipe sideways moves the carousel: " & $carousel
  doAssert pageOff() == p2, "and not the panel: " & $p2 & " -> " & $pageOff()
  withCarousel = false
  run(2)

block g_aCaughtFlingStopsOnlyTheList:
  # a list flicked flies on; a finger landing on it stops it, and the page
  # does not move
  setListOff(0)
  # (the list in view)
  while listR.y < 40:
    swipe(midX, listR.y + listR.h + 30, listR.y + listR.h + 130)
  let y = listR.y + listR.h - 10
  swipe(midX, y, listR.y + 10, flick = true, steps = 4)
  doAssert scrolling(listId), "the list flies on"
  let page = pageOff()
  down(midX, listR.y + listR.h div 2)
  run(1)
  let caught = listOff()
  doAssert not scrolling(listId), "the finger stops it"
  doAssert scrollCaught(), "the tap only stops it"
  up(midX, listR.y + listR.h div 2)
  run(3)
  doAssert listOff() == caught, "it stays where it stopped"
  doAssert pageOff() == page, "the page did not move: " & $page & " -> " & $pageOff()

block h_theWheelAtAListsEnd:
  # the mouse: a wheel over a list at its bottom scrolls the page, once the
  # notches that brought the list there have stopped
  ui.touch = false
  setSmoothScrolling(false)
  setListOff(1_000_000)
  let bottom = listOff()
  # (the list in view, not at the window's bottom)
  while listR.y < 40:
    swipe(midX, listR.y + listR.h + 30, listR.y + listR.h + 130)
  let at = point(midX, listR.y + listR.h div 2)
  move(at.x, at.y)
  run(30)                             # (more than the latch's 400 ms)
  let before = pageOff()
  queue.add Event(kind: MouseWheelEvent, y: -1)
  run(2)
  doAssert listOff() == bottom
  doAssert pageOff() > before, "the page scrolled on: " & $before & " -> " & $pageOff()
  # notches that scroll the list to its end stay with it, without a pause
  setListOff(bottom - 10)
  move(at.x, at.y + 1)
  run(30)
  let p2 = pageOff()
  queue.add Event(kind: MouseWheelEvent, y: -1)        # to its end
  run(1)
  queue.add Event(kind: MouseWheelEvent, y: -1)        # and on, at once
  run(1)
  doAssert listOff() == bottom
  doAssert pageOff() == p2, "the page waited: " & $p2 & " -> " & $pageOff()
  setSmoothScrolling(true)

echo "test_nestedscroll: ok"

## Tests of a page under the finger on a touch screen: pulled down past its top and let go it
## asks for fresh content once (`pullRefresh`), a pull too short asks nothing; a dialog as a page
## of the app (`dialogPages`: its Close closes it); a shelf of cards (`cardShelf`: the one
## tapped); Back by a swipe from a page's left edge (`pageView`), a swipe too short staying; the
## keyboard a text box asks for (`textKeyboard`, a number box's digits), a tap on nothing letting
## it go.

import std/os
import retroui
import retroui/uirelays/input
import harness

putEnv("RETRO_TOUCH", "1")
fakeDriver()
startApp("touchpages", W, H)
doAssert ui.touch, "a touch screen"

var passed = 0
template check(cond: bool; what: string) =
  doAssert cond, what
  inc passed
  echo "  ok   ", what

proc drag(x0, y0, x1, y1: int; steps = 8) =
  ## (a finger down at x0, y0, moved to x1, y1 a frame a step, let go)
  down(x0, y0)
  run(1)
  for k in 1 .. steps:
    move(x0 + (x1 - x0) * k div steps, y0 + (y1 - y0) * k div steps)
    run(1)
  up(x1, y1)
  run(3)

block pullToRefresh:
  var fired = 0
  var loading = false
  view = proc () =
    beginPanel(-1, "inbox")
    if pullRefresh(loading):
      inc fired
      loading = true
    for i in 0 ..< 40: label "Message " & $i
    endPanel()
  run(3)
  drag(200, 80, 200, 120)
  check fired == 0, "a short pull: nothing asked"
  run(30)
  drag(200, 60, 200, 360, 12)
  check fired == 1, "pulled down past the threshold and let go: fresh content asked, once"
  run(5)
  check fired == 1, "once"
  loading = false
  run(30)

block dialogAsPage:
  dialogPages = dpPages
  var open = true
  view = proc () =
    label "Under it"
    dialog(open, "Settings", 300):
      label "A setting"
  run(25)                                   # (slid up)
  check open, "a dialog as a page"
  down(dp(6) + 12, dp(22))                  # (Close, at the navigation bar's start)
  up(dp(6) + 12, dp(22))
  run(3)
  check not open, "its Close closes it"
  dialogPages = dpAuto

block shelf:
  var tapped = -1
  var cards: seq[ShelfCard] = @[("One", "a", Bitmap(nil), nfMusic), ("Two", "b", Bitmap(nil), nfHeart)]
  view = proc () =
    let k = cardShelf(cards, "test", side = 120)
    if k >= 0: tapped = k
  run(3)
  down(Pad + 120 + dp(12) + 30, Pad + 40)
  up(Pad + 120 + dp(12) + 30, Pad + 40)
  run(3)
  check tapped == 1, "the card tapped: " & $tapped

block swipeBack:
  var nav = initPages("home")
  nav.push("detail")
  view = proc () =
    pageView(nav):
      label nav.page
  run(20)
  drag(Pad + 4, 200, Pad + 80, 200, 6)
  check nav.page == "detail", "a short swipe: the page stays"
  run(20)
  drag(Pad + 4, 200, W - 20, 200, 10)
  check nav.page == "home", "a swipe past a third of the way: back a page"

block keyboards:
  # (a text box's keyboard on a phone: the kind asked for, a number box's digits; a tap on
  # nothing lets the keyboard go)
  var host = ""
  var n = 3
  var hostR, nR: Rect
  view = proc () =
    textKeyboard(kbUrl, keNext)
    edit host
    hostR = ui.lastRect
    intEdit(n, lo = 0, hi = 99)
    nR = ui.lastRect
    space(dp(200))
  run(3)
  click(hostR)
  run(2)
  check keyboardWanted() and WantUrl in keyboardFlagsNow() and EnterNext in keyboardFlagsNow(),
        "a web address's keyboard asked of the system, Next on its Enter key"
  click(nR)
  run(2)
  check WantNumbers in keyboardFlagsNow(), "a number box: digits"
  check not keyboardUp(), "no keyboard on this screen: the bars stay"
  down(300, 400)
  up(300, 400)
  run(3)
  check not keyboardWanted(), "a tap on nothing: the keyboard goes"

echo "touchpages: ", passed, " passed"

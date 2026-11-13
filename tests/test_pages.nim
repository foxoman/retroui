## Tests of retroui/pages (pages over pages, Back, a list beside its
## details) and of `animated`.

import harness, retroui
import retroui/uirelays/input

fakeDriver()
startApp("t", W, H)

var
  nav = initPages("home")
  opened = false
  homeDrawn, detailDrawn, listDrawn = 0
  pageX = 0
  showDetail = false
  target = 0.0
  shown = 0.0

view = proc () =
  pageView(nav):
    case nav.page
    of "home":
      pageHeader(nav, "Home")
      inc homeDrawn
      if button("Open"): nav.push("detail")
    of "detail":
      pageHeader(nav, "Detail")
      pageX = ui.lastRect.x
      inc detailDrawn
  shown = animated(target, 200)

run(2)
doAssert nav.page == "home" and nav.atHome and homeDrawn > 0

block pushAndBack:
  nav.push("detail")
  run()
  let first = pageX
  for _ in 0 ..< 20: run()           # (16 ms a frame: the slide is over)
  doAssert nav.page == "detail" and not nav.atHome
  doAssert pageX < first, $(pageX, first)   # (it slid in from the right)
  key(KeyEsc); run()
  doAssert nav.page == "home"
  nav.push("detail"); run()
  key(KeyLeft, {AltPressed}); run()
  doAssert nav.page == "home"
  nav.push("a"); nav.push("b")
  doAssert nav.pages.len == 3
  nav.goHome()
  doAssert nav.pages == @["home"] and not nav.pop()

block animate:
  target = 100.0
  run()
  let early = shown
  doAssert early < 100.0, $early
  for _ in 0 ..< 20: run()
  doAssert shown == 100.0, $shown
  smoothScrolling = false
  target = 0.0
  run()
  doAssert shown == 0.0                  # (less movement asked: there at once)
  smoothScrolling = true

block listDetailWide:
  # 640 pixels: room for both, side by side
  var bothSeen = false
  view = proc () =
    listDetail(showDetail, 200):
      inc listDrawn
    do:
      inc detailDrawn
      bothSeen = listDrawn > 0
  listDrawn = 0
  detailDrawn = 0
  run()
  doAssert listDrawn > 0 and detailDrawn > 0 and bothSeen

echo "pages OK"

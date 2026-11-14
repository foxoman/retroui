#> phone(300, 360)
#> clickMark(0)
#> frames(20)
#> shot("09-phone-layouts--step2")
import retroui

var nav = initPages("shop")
var tab = 0

app "Shop", 300, 360:
  # the bottom bar of a phone app (drawn first: it keeps its room at the bottom)
  if bottomNav([(pxHome, "Shop"), (pxSearch, "Search"), (pxUser, "Account")], tab):
    nav.goHome()
  pageView(nav):                     # pages over pages, sliding in; Back goes back
    case nav.page
    of "shop":
      pageHeader(nav, "Shop")
      if button("Dates, 1 kg"): nav.push("dates")
      mark "dates"
      button("Coffee, 250 g")
    of "dates":
      pageHeader(nav, "Dates, 1 kg")       # Back: its button, the phone's, Esc
      label "OMR 2.800"
      button("&Add to the basket")

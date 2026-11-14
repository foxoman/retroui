#> shot("09-phone-layouts--step1")
#> phone(300, 360)
#> shot("09-phone-layouts--step1-phone")
import retroui

var products = ["Dates, 1 kg", "Coffee, 250 g", "Halwa, small box", "Rose water"]
var prices = ["2.800", "3.500", "4.200", "1.100"]
var sel = 0
var open = false

app "Shop", 520, 200:
  listDetail(open, 200):             # two columns where there is room
    if listbox(products, sel, rows = 7): open = true   # on a phone: the details over it
  do:
    label products[sel], bold = true
    label "OMR " & prices[sel]
    button("&Add to the basket")

#> shot("03-tip-calculator--step3")
import std/strutils
import retroui

var bill = 42.50
var tip = 15
var people = 3

proc money(x: float): string = formatFloat(x, ffDecimal, 2)

app "Tip", 340, 230:
  form 70:                           # captions in a column (above the fields on a phone)
    field "&Bill:": numberEdit bill, lo = 0
    field "&Tip:":
      row([-1, 40]):
        slider tip, 0, 30
        label $tip & " %"
    field "&People:": spin people, 1, 20
  separator()
  let total = bill * (1 + tip.float / 100)
  row([70, -1]):
    label "Total:"
    label money(total)
  row([70, -1]):
    label "Each:"
    label money(total / people.float), bold = true

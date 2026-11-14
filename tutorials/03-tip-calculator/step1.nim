#> shot("03-tip-calculator--step1")
import std/strutils
import retroui

var bill = 42.50
var tip = 15                         # percent

app "Tip", 320, 170:
  label "Bill:"
  numberEdit bill, lo = 0
  label "Tip: " & $tip & " %"
  slider tip, 0, 30
  label "Tip to leave: " & formatFloat(bill * tip.float / 100, ffDecimal, 2)

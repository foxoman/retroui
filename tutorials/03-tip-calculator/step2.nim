#> shot("03-tip-calculator--step2")
import std/strutils
import retroui

var bill = 42.50
var tip = 15

app "Tip", 340, 150:
  row([70, -1]):                     # a column of 70 for the captions, the rest for the controls
    label "&Bill:"
    numberEdit bill, lo = 0
  row([70, -1, 40]):
    label "&Tip:"
    slider tip, 0, 30
    label $tip & " %"
  row([70, -1]):
    label "Leave:"
    label formatFloat(bill * tip.float / 100, ffDecimal, 2), bold = true

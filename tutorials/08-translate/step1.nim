#> shot("08-translate--step1")
import retroui

var name = "Maryam"

app "Greeter", 300, 140:
  row([60, -1]):
    label "&Name:"                   # every text a control shows is looked up (`tr`)
    edit name
  if button("&Greet"): discard
  label tr("Hello") & ", " & name & "!"   # a text of your own: `tr` it too

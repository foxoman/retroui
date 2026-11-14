#> shot("08-translate--step2")
#> setUiLanguage("en")
import retroui

setUiLanguage("ar", @[("Name:", "الاسم:"), ("Greet", "رحّب"), ("Hello", "مرحبًا"),
                     ("Greeter", "المرحِّب")])
var name = "مريم"

app "Greeter", 300, 140:             # the window mirrored: right to left
  row([60, -1]):
    label "&Name:"
    edit name
  if button("&Greet"): discard
  label tr("Hello") & "، " & name & "!"

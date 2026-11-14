#> clickMark(0)
#> shot("01-hello--step3")
import retroui

var name = "World"
var greeted = ""
var times = 0

app "Hello", 320, 150:
  row([50, -1]):
    label "&Name:"
    edit name
  row:
    if button("&Greet", isDefault = true):   # true on the frame it is clicked
      greeted = "Hello, " & name & "!"
      inc times
    mark "greet"
    if button("E&xit"): quitApp()
  label greeted & (if times > 1: " (" & $times & " times)" else: "")

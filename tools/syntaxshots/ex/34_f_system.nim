#> clickMark(0)
#> shot("f-system")
import retroui
import retroui/system

var asked = false

app "Where", 320, 110:
  row:
    if button("&Where am I?"): asked = true      # from a click: the user may be asked
    mark "where"
    if button("&Share"):
      if not share(text = "Order 1042"):         # false: no share sheet here
        putClipboardText("Order 1042")           # so the app offers what it can
  if asked:
    let p = location()                           # asked every frame: the answer comes later
    case p.state
    of psOk: label "At " & $p.lat & ", " & $p.lon
    of psWaiting: label "Looking..."
    of psDenied: label "The place was not allowed."
    of psNone: label "No place on this device."  # "not here" is an answer

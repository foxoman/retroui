#> shot("12-own-control--step1")
import std/math
import retroui

var level = 70

app "Gauge", 220, 170:
  let r = canvas(150, 150)           # a place of your own to draw in
  let cx = float(r.x + r.w div 2)
  let cy = float(r.y + r.h div 2)
  ring(cx, cy, 60, 12, ui.theme.face)                     # the track
  pieSlice(cx, cy, 66, -PI / 2, -PI / 2 + 2 * PI * level.float / 100, ui.theme.select)
  disc(cx, cy, 54, ui.theme.window)                       # the hole
  let s = $level & " %"
  text(int(cx) - textWidth(s, bold = true) div 2, int(cy) - 8, s, ui.theme.text, bold = true)

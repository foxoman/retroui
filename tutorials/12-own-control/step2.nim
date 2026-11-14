#> clickMark(0, 0.8, 0.5)
#> shot("12-own-control--step2")
import std/math
import retroui

proc gauge(v: var int; size = 150): bool {.discardable.} =
  ## A round gauge bound to `v` (0..100); a click or a drag on it sets it.
  let r = canvas(size, size)
  let id = idOf(v, "gauge")          # its id: from the variable it is bound to
  let hit = interact(id, r)          # the mouse and the focus, as every control has them
  let cx = float(r.x + r.w div 2)
  let cy = float(r.y + r.h div 2)
  if hit.down:                       # pressed (and dragged): the angle is the value
    var a = arctan2(float(ui.my) - cy, float(ui.mx) - cx) + PI / 2
    if a < 0: a += 2 * PI
    let nv = clamp(int(a / (2 * PI) * 100 + 0.5), 0, 100)
    if nv != v:
      v = nv
      result = true
  let rad = float(size) / 2 - 8
  ring(cx, cy, rad - 6, 12, ui.theme.face)
  pieSlice(cx, cy, rad, -PI / 2, -PI / 2 + 2 * PI * v.float / 100, ui.theme.select)
  disc(cx, cy, rad - 12, ui.theme.window)
  let s = $v & " %"
  text(int(cx) - textWidth(s, bold = true) div 2, int(cy) - 8, s, ui.theme.text, bold = true)

var level = 30

app "Gauge", 220, 190:
  if gauge(level): discard           # true on the frames it changed
  mark "gauge"
  label "Level: " & $level

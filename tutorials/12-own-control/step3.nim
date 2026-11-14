#> key(KeyTab)
#> key(KeyRight)
#> key(KeyRight)
#> shot("12-own-control--step3")
import std/math
import retroui

proc gauge(v: var int; name: string; size = 150): bool {.discardable.} =
  ## A round gauge bound to `v`: the mouse, the keyboard (Left, Right, Home,
  ## End) and screen readers ("Volume, slider, 40 %").
  let r = canvas(size, size)
  let id = idOf(v, "gauge")
  let hit = interact(id, r)
  let cx = float(r.x + r.w div 2)
  let cy = float(r.y + r.h div 2)
  var nv = v
  if hit.down:
    var a = arctan2(float(ui.my) - cy, float(ui.mx) - cx) + PI / 2
    if a < 0: a += 2 * PI
    nv = int(a / (2 * PI) * 100 + 0.5)
  if hit.focused and canInput():     # its keys, while it has the focus
    if keyHit(KeyRight) or keyHit(KeyUp): nv += 5
    elif keyHit(KeyLeft) or keyHit(KeyDown): nv -= 5
    elif keyHit(KeyHome): nv = 0
    elif keyHit(KeyEnd): nv = 100
  nv = clamp(nv, 0, 100)
  if nv != v:
    v = nv
    result = true
  let rad = float(size) / 2 - 8
  ring(cx, cy, rad - 6, 12, ui.theme.face)
  pieSlice(cx, cy, rad, -PI / 2, -PI / 2 + 2 * PI * v.float / 100, ui.theme.select)
  disc(cx, cy, rad - 12, ui.theme.window)
  let s = $v & " %"
  text(int(cx) - textWidth(s, bold = true) div 2, int(cy) - 8, s, ui.theme.text, bold = true)
  if hit.focused: focusDots(r)       # where the keyboard is
  # what a screen reader says of it
  accessNode(arSlider, name, $v & " %", {asFocusable} + (if hit.focused: {asFocused} else: {}))

var volume = 40

app "Gauge", 220, 190:
  gauge(volume, "Volume")
  label "Volume: " & $volume

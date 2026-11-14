#> for i in 0 ..< 60:
#>   ticks += 1000
#>   frames(1)
#> shot("07-dashboard--step3")
import std/[math, times]
import retroui

var load: seq[float]                 # the last minute, a value a second
var version = 0                      # changes when `load` does
var lastAdded = 0

app "Load", 420, 210:
  if ui.now - lastAdded >= 1000:     # a new value each second
    lastAdded = ui.now
    load.add 50 + 30 * sin(load.len.float / 6) + 10 * sin(load.len.float * 1.7)
    if load.len > 60: load.delete(0)
    inc version
  label "Processor: " & (if load.len > 0: $int(load[^1]) & " %" else: "-"), bold = true
  liveGraph("load", load, version, maxValue = 100, h = dp(110))
  wakeIn(1000)                       # the next frame in a second, even untouched

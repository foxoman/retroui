#> build-only
import retroui

# The five calls `app` is made of: your own loop, for a program that already
# has one (a game, an embedded tool) or wants to decide when frames run.
var count = 0
openApp("Own loop", 300, 100)
while beginFrame():                  # false once the window is closed
  if button("&Count"): inc count
  label "Counted " & $count
  endFrame()                         # draws the frame; waits for input when nothing moves
closeApp()

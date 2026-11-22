## The kit's GPU renderer in a web page, checked in a real browser (tests/web/gpu.js): asked
## for (`?gpu=1`), the canvas's WebGL 2 drawn on as OpenGL ES 2 -- the frames the same as the
## CPU draws them --; not asked for, the CPU's frames as before. The app says which drew
## ("GPU yes ..." / "GPU no ...") once its frames have settled, then "READY".
##
##   sh tests/web/run.sh

import retroui

var
  frames = 0
  text = "Typed on the GPU"
  ticked = true
  level = 40
  picked = 1
  rows = @["Alpha", "Beta", "Gamma", "Delta"]

app "gpucheck", 480, 320:
  inc frames
  if frames == 1: ui.focus = Id(0)      # (no caret blinking: two pages compared)
  label "Retro Nim UI, drawn on the GPU"
  row:
    discard button("&OK", w = dp(80))
    discard button("Cancel", w = dp(80))
  edit text
  checkbox("A box ticked", ticked)
  discard slider(level, 0, 100)
  discard listbox(rows, picked, rows = 3)
  progress(0.6)
  if frames == 20:
    echo "GPU ", (if drawnWithGpu(): "yes " else: "no "), gpuDescription()
    echo "READY"
  if frames < 25: wakeIn(16)

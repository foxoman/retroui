## Frames take no memory of their own: rows, labels with their '&', text,
## fills, and the tiles drawn and sent where a little changed -- after the
## first frames, a frame of the toolkit's own drawing allocates nothing (the
## widgets an app uses may still make strings). And the drawing's caches,
## let go of (`dropDrawingCaches`, as when memory is short), are made again:
## the same pixels. Headless.

import retroui
import harness

var
  lit = 0
  boxes: array[4, Rect]

view = proc () =
  # (only the core's and the drawing's own calls: no widget)
  beginRow([-1, -1, -1])
  for i in 0 ..< 3:
    let r = beginCell(80, fill = true)
    fill(r, if i == lit: ui.theme.select else: ui.theme.face)
    drawLabel(r.x + 4, r.y + 2, "&Item number", ui.theme.text)
    text(r.x + 4, r.y + 2 + FontH, "plain text, no mnemonic", ui.theme.text)
    discard labelWidth("&Wide label")
    boxes[i] = r
  endRow()
  fill(rect(10, 300, 200, 40), ui.theme.window)
  text(14, 310, (if (lit and 1) == 0: "Frame even" else: "Frame odd"), ui.theme.text)

proc allocs(): int = cast[array[2, int]](getAllocStats())[0]

fakeDriver()
startApp("allocations", W, H)
run(4)
for i in 0 ..< 6:          # (every state seen once: the buffers grown)
  lit = i mod 3
  run(1)
const N = 60
proc perFrame(): float =
  let a0 = allocs()
  for i in 0 ..< N:
    lit = i mod 3
    run(1)
  (allocs() - a0) / N
# (up to three times: on a busy machine one of the kit's threads, or a
# timer, takes memory now and then while these frames are drawn -- one
# allocation in sixty frames, a test in six failed with the others
# running; a frame that allocates does it every time)
var per = perFrame()
for _ in 0 ..< 2:
  if per > 0: per = min(per, perFrame())
doAssert per == 0, "a frame takes " & $per & " allocations"

# the caches let go of, then the frame drawn again: the same pixels
let before = pixels
dropDrawingCaches()
invalidate()
run(1)
doAssert pixels == before, "drawn the same after the caches were let go of"
# (`idOfLabel(kind, label)` is `idOf(kind & label)` without the string: the
# same seed, so a widget keeps its id)
doAssert fnv("Copy", fnv("tool:")) == fnv("tool:Copy")
doAssert fnv("", fnv("Copy", fnv("tool:"))) == fnv("tool:Copy")
echo "draw allocation tests passed (", per, " allocations a frame)"

## Tests of retroui/motion on a clock of the test's own: a spring keeps its speed when its
## target changes and is the same at any frame rate, a bouncy one goes past, a box comes in
## and goes out before it is gone, a box the layout moved glides (a scroll does not), a box
## dragged and let go springs to the nearest point, rows come in one after another, a fixed
## time step counts whole steps -- less movement asked puts each at its end at once, and
## nothing asks for frames once it is all at rest.

import std/math
import retroui, retroui/[headless, motion]
import retroui/uirelays/input

useHeadless(400, 300)
startApp("Motion", 400, 300)
var clock = 1000
inputRelays.getTicks = proc (): int = clock

template frame(ms: int; body: untyped) =
  clock += ms
  discard beginFrame()
  body
  endFrame()

var rested = false
template rest(body: untyped) =
  ## (a frame of `body`: `rested` when it asked for no other)
  frame(16): body
  rested = ui.wakeAt == 0

block springKeepsItsSpeed:
  let id = Id(101)
  var v: float
  frame(16): v = sprungAt(id, 0.0)
  doAssert v == 0.0                                  # (the first time: where it is)
  var last = 0.0
  for i in 0 ..< 6:
    frame(16): v = sprungAt(id, 100.0)
    doAssert v > last, "on its way: " & $v
    last = v
  doAssert v > 5 and v < 95
  # sent back half way: it goes on up a little with the speed it had, then turns
  frame(16): v = sprungAt(id, 0.0)
  doAssert v > last, "kept its speed: " & $v & " after " & $last
  for i in 0 ..< 120:
    frame(16): v = sprungAt(id, 0.0)
  doAssert v == 0.0, "at rest where it was sent: " & $v
  rest: discard sprungAt(id, 0.0)
  doAssert rested

block theSameAtAnyFrameRate:
  var a, b: float
  frame(16):
    a = sprungAt(Id(102), 0.0)
    b = sprungAt(Id(103), 0.0)
  # a at 8 ms a frame, b at 40: 200 ms of each
  let t0 = clock
  for i in 0 ..< 25:
    frame(8):
      a = sprungAt(Id(102), 100.0)
      if (clock - t0) mod 40 == 0: b = sprungAt(Id(103), 100.0)
  doAssert clock - t0 == 200
  doAssert abs(a - b) < 1.0, "8 ms frames " & $a & ", 40 ms frames " & $b

block bouncyGoesPast:
  var v, top: float
  frame(16): v = sprungAt(Id(104), 0.0, springBouncy)
  for i in 0 ..< 150:
    frame(16): v = sprungAt(Id(104), 100.0, springBouncy)
    top = max(top, v)
  doAssert top > 105, "past and back: " & $top
  doAssert v == 100.0
  var smooth: float
  for i in 0 ..< 150:
    frame(16): smooth = max(smooth, sprungAt(Id(105), 100.0, springSmooth, start = 0))
  doAssert smooth <= 100.0 + 1e-6, "smooth never goes past: " & $smooth

block presenceInAndOut:
  let id = Id(201)
  var p: Presence
  frame(16): p = presenceAt(id, false)
  doAssert not p.present                             # (not shown: nothing drawn)
  var ts: seq[float]
  for i in 0 ..< 20:
    frame(16): p = presenceAt(id, true)
    ts.add p.t
  doAssert p.present and p.t == 1.0 and not p.leaving
  doAssert ts[0] > 0 and ts[0] < 1                    # (it came in, frame by frame)
  # out: still drawn, leaving, until it is out
  frame(16): p = presenceAt(id, false)
  doAssert p.present and p.leaving and p.t < 1
  for i in 0 ..< 20:
    frame(16): p = presenceAt(id, false)
  doAssert not p.present
  # turned back half way: from where it was, no jump
  for i in 0 ..< 5:
    frame(16): p = presenceAt(id, true)
  let half = p.t
  frame(16): p = presenceAt(id, false)
  doAssert abs(p.t - half) < 0.25 and p.present, $half & " -> " & $p.t
  # shown the first time it is asked: in at once -- unless it is to come in (a row just added)
  frame(16): p = presenceAt(Id(202), true)
  doAssert p.t == 1.0
  frame(16): p = presenceAt(Id(203), true, enter = true)
  doAssert p.present and p.t < 1.0
  for i in 0 ..< 20:
    frame(16): discard presenceAt(id, false)
  for i in 0 ..< 20:
    frame(16): p = presenceAt(Id(203), true, enter = true)
  rest:
    discard presenceAt(Id(203), true)
    discard presenceAt(id, false)
  doAssert rested

block layoutGlides:
  let id = Id(301)
  var r: Rect
  frame(16): r = glidedAt(id, rect(10, 10, 100, 20))
  doAssert r == rect(10, 10, 100, 20)
  frame(16): r = glidedAt(id, rect(10, 60, 100, 20))  # (moved down the list)
  doAssert r.y > 10 and r.y < 60, "on its way: " & $r
  for i in 0 ..< 100:
    frame(16): r = glidedAt(id, rect(10, 60, 100, 20))
  doAssert r == rect(10, 60, 100, 20)
  # scrolled: its place in what holds it is the same -- there at once
  frame(16): r = glidedAt(id, rect(10, -40, 100, 20), origin = (0, -100))
  doAssert r == rect(10, -40, 100, 20), "a scroll does not glide: " & $r
  rest: discard glidedAt(id, rect(10, -40, 100, 20), origin = (0, -100))
  doAssert rested

block draggedAndSnapped:
  let id = Id(401)
  let home = rect(20, 20, 40, 40)
  let snaps = [(200, 20), (200, 200)]
  var d: Drag
  frame(16): d = dragSnapAt(id, home, snaps)
  doAssert d.r == home and d.snapped == -1 and not d.dragging
  headlessInput(Event(kind: MouseMoveEvent, x: 40, y: 40))
  frame(16): d = dragSnapAt(id, home, snaps)
  headlessInput(Event(kind: MouseDownEvent, x: 40, y: 40, button: LeftButton, clicks: 1))
  frame(16): d = dragSnapAt(id, home, snaps)
  doAssert d.dragging
  # dragged to near the second point, slowly
  for (x, y) in [(60, 80), (100, 140), (150, 190), (205, 205)]:
    headlessInput(Event(kind: MouseMoveEvent, x: x, y: y))
    frame(40): d = dragSnapAt(id, home, snaps)
  doAssert d.dragging and d.r.x == 205 - 20 and d.r.y == 205 - 20, "follows the pointer: " & $d.r
  frame(200): d = dragSnapAt(id, home, snaps)            # (held still a moment)
  headlessInput(Event(kind: MouseUpEvent, x: 205, y: 205, button: LeftButton))
  frame(16): d = dragSnapAt(id, home, snaps)
  doAssert d.dropped and d.snapped == 1 and not d.dragging
  for i in 0 ..< 100:
    frame(16): d = dragSnapAt(id, home, snaps)
  doAssert d.r == rect(200, 200, 40, 40) and d.snapped == 1, "sprung to the point: " & $d.r
  rest: discard dragSnapAt(id, home, snaps)
  doAssert rested
  # scrolled 50 up: the box and its points with it, at once
  frame(16): d = dragSnapAt(id, rect(20, -30, 40, 40), [(200, -30), (200, 150)], origin = (0, -50))
  doAssert d.r == rect(200, 150, 40, 40), "a scroll does not spring: " & $d.r
  frame(16): d = dragSnapAt(id, home, snaps)
  # thrown: let go half way, moving fast toward the first point -- it goes there
  let id2 = Id(402)
  frame(16): d = dragSnapAt(id2, home, snaps)
  headlessInput(Event(kind: MouseMoveEvent, x: 40, y: 40))
  frame(16): d = dragSnapAt(id2, home, snaps)
  headlessInput(Event(kind: MouseDownEvent, x: 40, y: 40, button: LeftButton, clicks: 1))
  frame(16): d = dragSnapAt(id2, home, snaps)
  for x in [70, 100, 130]:
    headlessInput(Event(kind: MouseMoveEvent, x: x, y: 40))
    frame(16): d = dragSnapAt(id2, home, snaps)
  headlessInput(Event(kind: MouseUpEvent, x: 130, y: 40, button: LeftButton))
  frame(16): d = dragSnapAt(id2, home, snaps)
  doAssert d.dropped and d.snapped == 0, "thrown to the point it went at: " & $d.snapped
  # no points: back to its place
  let id3 = Id(403)
  frame(16): d = dragSnapAt(id3, home, [])
  headlessInput(Event(kind: MouseMoveEvent, x: 40, y: 40))
  frame(16): d = dragSnapAt(id3, home, [])
  headlessInput(Event(kind: MouseDownEvent, x: 40, y: 40, button: LeftButton, clicks: 1))
  frame(16): d = dragSnapAt(id3, home, [])
  headlessInput(Event(kind: MouseMoveEvent, x: 140, y: 140))
  frame(16): d = dragSnapAt(id3, home, [])
  frame(200): d = dragSnapAt(id3, home, [])
  headlessInput(Event(kind: MouseUpEvent, x: 140, y: 140, button: LeftButton))
  for i in 0 ..< 100:
    frame(16): d = dragSnapAt(id3, home, [])
  doAssert d.r == home and d.snapped == -1

block rowsOneAfterAnother:
  let id = Id(501)
  var a: array[6, float]
  frame(16):
    for i in 0 ..< 6: a[i] = staggeredAt(id, i)
  for i in 0 ..< 6: doAssert a[i] < 0.2
  frame(100):
    for i in 0 ..< 6: a[i] = staggeredAt(id, i)
  doAssert a[0] > a[2] and a[2] > a[5], $a
  for k in 0 ..< 40:
    frame(16):
      for i in 0 ..< 6: a[i] = staggeredAt(id, i)
  for i in 0 ..< 6: doAssert a[i] == 1.0
  # gone for a while, then shown again: in again
  frame(1000):
    for i in 0 ..< 6: a[i] = staggeredAt(id, i)
  doAssert a[0] < 0.2
  for k in 0 ..< 40:
    frame(16):
      for i in 0 ..< 6: a[i] = staggeredAt(id, i)
  rest:
    for i in 0 ..< 6: discard staggeredAt(id, i)
  doAssert rested

block fixedTimeStep:
  let id = Id(601)
  var n = 0
  var s: tuple[n: int; alpha: float]
  frame(16): s = fixedStepsAt(id, 10)
  for i in 0 ..< 10:
    frame(16):
      s = fixedStepsAt(id, 10)
      n += s.n
      doAssert s.alpha >= 0 and s.alpha < 1
  doAssert n == 16, "160 ms in steps of 10: " & $n
  frame(1000): s = fixedStepsAt(id, 10)
  doAssert s.n == 8, "a slow frame: no more than 8 steps " & $s.n
  frame(16): s = fixedStepsAt(id, 10, running = false)
  doAssert s.n == 0
  rest: discard fixedStepsAt(id, 10, running = false)
  doAssert rested
  rest: discard fixedStepsAt(id, 10)
  doAssert not rested                                        # (running: frames at its pace)

block lessMovement:
  setSmoothScrolling(false)
  doAssert reducedMotion()
  var v: float
  var p: Presence
  frame(16):
    v = sprungAt(Id(701), 0.0)
    p = presenceAt(Id(702), false)
  frame(16):
    v = sprungAt(Id(701), 100.0)
    p = presenceAt(Id(702), true)
  doAssert v == 100.0 and p.t == 1.0, "at the end at once"
  frame(16): p = presenceAt(Id(702), false)
  doAssert not p.present
  frame(16): v = sprungAt(Id(703), 50.0, start = 0)
  doAssert v == 50.0
  rest:
    discard sprungAt(Id(703), 50.0)
    discard presenceAt(Id(702), false)
  doAssert rested
  setSmoothScrolling(true)

stopApp()
echo "test_motion: ok"

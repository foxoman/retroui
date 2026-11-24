## Movement that feels like a thing moving: springs that keep their speed when where they go
## changes half way, boxes that come in and go out before they are gone, boxes the layout
## moved gliding to their new place, a box dragged that springs to where it is let go, rows
## coming in one after another, and a fixed time step for a simulation.
##
## Each call keeps its own state in the kit -- by where it is in the code, and `key` for one
## call in a loop -- so the app holds nothing; frames are asked for only while something moves,
## an app at rest takes no time; with less movement asked (the system's setting, or
## `smoothScrolling` off) everything is at its end at once.
##
## .. code-block:: nim
##   let x = sprung(if open: 0.0 else: -260.0)                # a panel, quick to change its mind
##   let p = presence(toastShown)                              # in, then out before it is gone
##   if p.present: drawToast(y = mix(-40.0, 12.0, p.t), alpha = p.t)
##   let r = glided(place(200, 40), key = item.name)           # a row the list moved
##   let d = dragSnap(r, snaps)                                # dragged, thrown, snapped
##   let a = staggered(i)                                      # row i comes in after row i - 1
##   let s = fixedSteps(1000 / 60, running = playing)          # a game's steps this frame
##   for _ in 0 ..< s.n: world.step()
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[tables, math, hashes]
import core
import uirelays/coords

type
  Spring* = object
    ## How a spring moves: `response` seconds for one swing (smaller: quicker); `damping` 1
    ## comes to rest without going past, less goes past and settles (0.5: a bounce).
    response*: float
    damping*: float

const
  springSmooth* = Spring(response: 0.35, damping: 1.0)    ## there without going past
  springSnappy* = Spring(response: 0.25, damping: 0.86)   ## quick, a touch past
  springBouncy* = Spring(response: 0.45, damping: 0.55)   ## past and back

proc reducedMotion*(): bool = not smoothScrolling
  ## Less movement is asked (the system's setting when the app started, or `smoothScrolling`
  ## turned off): every movement here is at its end at once.

proc mix*(a, b, t: float): float {.inline.} = a + (b - a) * t
  ## From `a` (t 0) to `b` (t 1).

proc mix*(a, b: Rect; t: float): Rect =
  ## A box between `a` (t 0) and `b` (t 1).
  rect(int(round(mix(a.x.float, b.x.float, t))), int(round(mix(a.y.float, b.y.float, t))),
       int(round(mix(a.w.float, b.w.float, t))), int(round(mix(a.h.float, b.h.float, t))))

# ---- springs ------------------------------------------------------------------------------------

type SpringState = object
  x, v, to: float          # where, how fast (per second), where to
  scale: float             # how far it was sent: when it is close enough to rest
  t, seen: int             # the last step, the last call (ms)

var springs: Table[Id, SpringState]

proc forget[T](tab: var Table[Id, T]) =
  ## (those not asked for 10 seconds: a page gone)
  if tab.len <= 256: return
  var old: seq[Id]
  for k, v in tab:
    if ui.now - v.seen > 10_000: old.add k
  for k in old: tab.del k

proc resting(s: SpringState): bool =
  abs(s.x - s.to) <= 0.001 * s.scale + 1e-4 and abs(s.v) <= 0.01 * s.scale + 1e-3

proc step(s: var SpringState; spec: Spring; now: int) =
  ## (from the last step to `now`, a few milliseconds at a time: the same at any frame rate)
  let el = clamp(now - s.t, 0, 100)    # (a frame late after a pause: not a leap)
  s.t = now
  if el == 0 or s.resting: return
  let w = 2 * PI / max(0.02, spec.response)
  let k = w * w
  let c = 2 * clamp(spec.damping, 0.05, 2.0) * w
  var left = el.float / 1000
  while left > 0:
    let dt = min(left, 0.004)
    s.v += (-k * (s.x - s.to) - c * s.v) * dt
    s.x += s.v * dt
    left -= dt
  if s.resting:
    s.x = s.to
    s.v = 0

proc sprungAt*(id: Id; target: float; spec = springSmooth; start = NaN): float =
  ## `sprung` for a value of your own id (`idOf`).
  let now = ui.now
  if id notin springs:
    let x = if start.isNaN or reducedMotion(): target else: start
    springs[id] = SpringState(x: x, to: target, scale: max(1e-6, abs(target - x)), t: now, seen: now)
    if x != target: wakeIn(16)
    return x
  var s = springs[id]
  s.seen = now
  if target != s.to:
    s.scale = max(1e-6, abs(target - s.x) + abs(s.v) * spec.response)
    s.to = target
  if reducedMotion():
    s.x = target
    s.v = 0
    s.t = now
  else:
    s.step(spec, now)
    if not s.resting: wakeIn(16)
  springs[id] = s
  forget(springs)
  s.x

template sprung*(target: float; spec = springSmooth; key = ""; start = NaN): float =
  ## `target`, reached as a spring would (`Spring`: `springSmooth`, `springSnappy`,
  ## `springBouncy`): sent somewhere else on the way, it turns from where it is with the speed
  ## it has -- no stop and start again as `animated` does. The first time it is `target` at
  ## once, or springs there from `start`. Each call is its own value, by where it is in the code
  ## (and `key`, for one call in a loop).
  const at = instantiationInfo(-1, true)
  const site = at.filename & ":" & $at.line & ":" & $at.column & ":"
  sprungAt(idOf(site & key), target, spec, start)

proc springSet(id: Id; x, v: float) =
  ## (a spring put where a finger has it, with its speed: let go, it goes on from there)
  var s = springs.getOrDefault(id)
  s.x = x
  s.v = v
  s.to = x
  s.t = ui.now
  s.seen = ui.now
  springs[id] = s

# ---- presence: in, and out before it is gone -------------------------------------------------------

type
  Presence* = object
    ## A box that comes and goes (`presence`).
    present*: bool    ## to be drawn: in, coming in or going out (false: gone, draw nothing)
    t*: float         ## 0 out .. 1 in, eased: what to move and fade by
    leaving*: bool    ## going out (to leave another way than it came in)

  PresenceState = object
    p: float
    t, seen: int

var presences: Table[Id, PresenceState]

proc presenceAt*(id: Id; shown: bool; ms = 180; msOut = -1; enter = false): Presence =
  ## `presence` for a box of your own id (`idOf`).
  let now = ui.now
  if id notin presences:
    let p = if shown and not (enter and not reducedMotion()): 1.0 else: 0.0
    presences[id] = PresenceState(p: p, t: now, seen: now)
  var s = presences[id]
  let el = clamp(now - s.t, 0, 100).float
  s.t = now
  s.seen = now
  if reducedMotion(): s.p = if shown: 1.0 else: 0.0
  elif shown: s.p = min(1.0, s.p + el / max(1, ms).float)
  else: s.p = max(0.0, s.p - el / max(1, (if msOut >= 0: msOut else: ms)).float)
  presences[id] = s
  forget(presences)
  if s.p > 0 and s.p < 1: wakeIn(16)
  # (one curve both ways: turned back half way, it goes on from where it was; out, it starts
  # slowly and goes faster -- as a thing leaving does)
  Presence(present: shown or s.p > 0, t: easeOut(s.p), leaving: not shown and s.p > 0)

template presence*(shown: bool; ms = 180; msOut = -1; key = ""; enter = false): Presence =
  ## A box that comes in when `shown` turns true and goes out when it turns false -- still
  ## drawn, `present`, until it is out: a toast, a menu, a row deleted. `t` goes 0 to 1 in `ms`
  ## milliseconds (out in `msOut`, -1 the same), eased; move and fade the box by it. The first
  ## time it is where `shown` says at once, unless `enter` (a row just added: it comes in).
  ##
  ## .. code-block:: nim
  ##   let p = presence(saved)
  ##   if p.present:
  ##     let r = rect(x, int(mix(-40.0, 12.0, p.t)), 220, 32)
  ##     fill(r, withAlpha(ui.theme.tip, uint8(255 * p.t)))
  const at = instantiationInfo(-1, true)
  const site = at.filename & ":" & $at.line & ":" & $at.column & ":"
  presenceAt(idOf(site & key), shown, ms, msOut, enter)

# ---- boxes the layout moved, gliding there -------------------------------------------------------

proc glidedAt*(id: Id; r: Rect; origin: (int, int) = (0, 0); spec = springSmooth): Rect =
  ## `glided` for a box of your own id (`idOf`), its place taken from `origin` (what moving it
  ## does not glide: a scroll).
  let (ox, oy) = origin
  let x = sprungAt(mixId(id, 1), float(r.x - ox), spec)
  let y = sprungAt(mixId(id, 2), float(r.y - oy), spec)
  let w = sprungAt(mixId(id, 3), float(r.w), spec)
  let h = sprungAt(mixId(id, 4), float(r.h), spec)
  rect(int(round(x)) + ox, int(round(y)) + oy, int(round(w)), int(round(h)))

template glided*(r: Rect; key = ""; spec = springSmooth): Rect =
  ## Where to draw a box the layout put at `r`: when the layout puts it somewhere else (a row
  ## moved up a list, a card to another column, a window made wider), it springs there from
  ## where it was. Its place is taken in the row or column it is in, so a scroll moves it at
  ## once. A box in a loop takes the `key` of what it shows (its name, not its index: the row
  ## keeps its key when it moves).
  ##
  ## .. code-block:: nim
  ##   for t in tasks:
  ##     let r = glided(place(dp(240), dp(28)), key = t.name)
  ##     drawTask(r, t)
  const at = instantiationInfo(-1, true)
  const site = at.filename & ":" & $at.line & ":" & $at.column & ":"
  glidedAt(idOf(site & key), r, layoutOrigin(), spec)

# ---- dragged, and sprung to where it is let go -----------------------------------------------------

type
  Drag* = object
    ## A box that is dragged (`dragSnap`).
    r*: Rect          ## where to draw it now
    dragging*: bool   ## held now
    dropped*: bool    ## let go this frame
    snapped*: int     ## the point it went to, of those given (-1: back to its place)

  DragState = object
    held: bool
    grabX, grabY: int          # where in the box it was taken
    lastX, lastY: float        # the pointer, a moment ago
    vx, vy: float              # its speed (px/s)
    lastT, seen: int
    snapped: int

var drags: Table[Id, DragState]

proc dragSnapAt*(id: Id; r: Rect; snaps: openArray[(int, int)]; origin: (int, int) = (0, 0);
                 spec = springSnappy; throw = 0.12): Drag =
  ## `dragSnap` for a box of your own id (`idOf`); its springs kept from `origin` (what moving
  ## it does not spring: a scroll).
  let now = ui.now
  let (ox, oy) = origin
  var s = drags.getOrDefault(id, DragState(snapped: -1))
  s.seen = now
  let xid = mixId(id, 1)
  let yid = mixId(id, 2)
  let home = if s.snapped >= 0 and s.snapped < snaps.len: snaps[s.snapped] else: (r.x, r.y)
  # where the box is now: where the finger has it, else on its spring home
  var cx, cy: float
  if s.held and ui.active == id and ui.mouseDown and xid in springs:
    cx = springs[xid].x
    cy = springs[yid].x
  else:
    cx = sprungAt(xid, float(home[0] - ox), spec)
    cy = sprungAt(yid, float(home[1] - oy), spec)
  let shown = rect(int(round(cx)) + ox, int(round(cy)) + oy, r.w, r.h)
  discard interact(id, shown, focusable = false)
  result.snapped = s.snapped
  if ui.active == id and ui.mouseDown:
    if not s.held:
      s.held = true
      s.grabX = ui.mx - shown.x
      s.grabY = ui.my - shown.y
      s.lastX = ui.mx.float
      s.lastY = ui.my.float
      s.lastT = now
      s.vx = 0
      s.vy = 0
    let dt = float(now - s.lastT) / 1000
    if dt > 0.004:
      # (the pointer's speed, smoothed: the throw when it is let go)
      s.vx = 0.6 * (ui.mx.float - s.lastX) / dt + 0.4 * s.vx
      s.vy = 0.6 * (ui.my.float - s.lastY) / dt + 0.4 * s.vy
      s.lastX = ui.mx.float
      s.lastY = ui.my.float
      s.lastT = now
    let x = ui.mx - s.grabX
    let y = ui.my - s.grabY
    springSet(xid, float(x - ox), s.vx)
    springSet(yid, float(y - oy), s.vy)
    result.r = rect(x, y, r.w, r.h)
    result.dragging = true
  else:
    if s.held:
      # let go: to the point nearest where it was thrown (or back to its place)
      s.held = false
      if now - s.lastT > 80:
        s.vx = 0                 # (held still before it was let go: no throw)
        s.vy = 0
      let px = float(ui.mx - s.grabX) + s.vx * throw
      let py = float(ui.my - s.grabY) + s.vy * throw
      var best = -1
      var bestD = Inf
      for i, p in snaps:
        let d = (p[0].float - px) ^ 2 + (p[1].float - py) ^ 2
        if d < bestD:
          bestD = d
          best = i
      s.snapped = best
      result.snapped = best
      result.dropped = true
      let to = if best >= 0: snaps[best] else: (r.x, r.y)
      discard sprungAt(xid, float(to[0] - ox), spec)
      discard sprungAt(yid, float(to[1] - oy), spec)
    result.r = shown
  drags[id] = s
  forget(drags)

template dragSnap*(r: Rect; snaps: openArray[(int, int)] = []; key = ""; spec = springSnappy): Drag =
  ## A box at `r` that a mouse or a finger drags: it follows the pointer, and let go it springs
  ## -- with the speed it was thrown at -- to the nearest of `snaps` (top left corners), and
  ## stays there; with none, back to `r`. Draw it at `.r`; `.snapped` says which point it is
  ## at (keep it: the box's new place). Its place is taken in the row or column it is in, so
  ## a scroll moves it at once.
  ##
  ## .. code-block:: nim
  ##   let d = dragSnap(place(dp(64), dp(64)), [(20, 300), (200, 300)])
  ##   fill(d.r, if d.dragging: ui.theme.select else: ui.theme.face)
  const at = instantiationInfo(-1, true)
  const site = at.filename & ":" & $at.line & ":" & $at.column & ":"
  dragSnapAt(idOf(site & key), r, snaps, layoutOrigin(), spec)

# ---- rows one after another ------------------------------------------------------------------------

var staggers: Table[Id, tuple[t0, seen: int]]

proc staggeredAt*(id: Id; i: int; ms = 220; step = 40; maxDelay = 400): float =
  ## `staggered` for a list of your own id (`idOf`).
  let now = ui.now
  var s = staggers.getOrDefault(id, (now, now))
  if now - s.seen > 500: s.t0 = now        # (not shown for a while: it comes in again)
  s.seen = now
  staggers[id] = s
  forget(staggers)
  easedSince(s.t0, ms, delay = min(i * step, maxDelay))

template staggered*(i: int; ms = 220; step = 40; maxDelay = 400; key = ""): float =
  ## How far row `i` of a list that has just come into view is in, 0 .. 1: each row `step`
  ## milliseconds after the one before (no more than `maxDelay`), `ms` to come in. All the rows
  ## of one call share when the list came; not shown for half a second, it comes in again.
  ##
  ## .. code-block:: nim
  ##   for i, m in mails:
  ##     let a = staggered(i)
  ##     let r = place(dp(300), dp(40))
  ##     drawMail(rect(r.x + int(24 * (1 - a)), r.y, r.w, r.h), m, alpha = a)
  const at = instantiationInfo(-1, true)
  const site = at.filename & ":" & $at.line & ":" & $at.column & ":"
  staggeredAt(Id(hash(site & key) and 0x7FFFFFFF) + 1, i, ms, step, maxDelay)

# ---- a fixed time step -----------------------------------------------------------------------------

var fixedClocks: Table[Id, tuple[acc: float; t, seen: int]]

proc fixedStepsAt*(id: Id; stepMs: float; running = true; maxSteps = 8): tuple[n: int; alpha: float] =
  ## `fixedSteps` for a simulation of your own id (`idOf`).
  let now = ui.now
  var s = fixedClocks.getOrDefault(id, (0.0, now, now))
  let el = float(now - s.t)
  s.t = now
  s.seen = now
  let dt = max(0.1, stepMs)
  if not running:
    s.acc = 0
  else:
    s.acc = min(s.acc + el, dt * maxSteps.float)   # (a frame late: steps dropped, not a leap)
    result.n = int(floor(s.acc / dt))
    s.acc -= result.n.float * dt
    result.alpha = s.acc / dt
    wakeIn(max(1, int(ceil(dt - s.acc))))
  fixedClocks[id] = s
  forget(fixedClocks)

template fixedSteps*(stepMs = 1000 / 60; running = true; maxSteps = 8; key = ""): tuple[n: int; alpha: float] =
  ## How many steps of `stepMs` milliseconds a simulation (a game, physics) takes this frame,
  ## whatever the frame rate: the time since the last frame, plus what was left over, in whole
  ## steps -- `alpha` is how far into the next one this frame is (draw between the last two
  ## states by it). No more than `maxSteps` at once (a slow frame drops time, not the app);
  ## while `running`, frames come at the step's pace; not running, nothing is counted. Less
  ## movement does not change it: a simulation is not a decoration.
  const at = instantiationInfo(-1, true)
  const site = at.filename & ":" & $at.line & ":" & $at.column & ":"
  fixedStepsAt(Id(hash(site & key) and 0x7FFFFFFF) + 1, stepMs, running, maxSteps)

# ---- timed steps, one after another: played forward and back -----------------------------------

type
  Curve* = enum
    ## The shape of a timed movement (`Tween`): from even (`cvLinear`) to slow at the end
    ## (`cvQuad` .. `cvExpo`), going a little past (`cvBack`), a spring's (`cvElastic`), a
    ## ball's (`cvBounce`).
    cvLinear, cvQuad, cvCubic, cvQuart, cvQuint, cvSine, cvExpo, cvCirc, cvBack, cvElastic, cvBounce
  EaseSide* = enum
    ## Where a curve's slowness is: at the end (`easeEnd`, the default), the start, both.
    easeEnd, easeStart, easeBoth
  Tween* = object
    ## One timed step: from `a` to `b` in `ms` milliseconds, after `delay`, along `curve`.
    a*, b*: float
    ms*, delay*: int
    curve*: Curve
    side*: EaseSide

proc tween*(a, b: float; ms = 300; curve = cvCubic; side = easeEnd; delay = 0): Tween =
  ## A step from `a` to `b` (`played` runs them).
  Tween(a: a, b: b, ms: max(1, ms), delay: max(0, delay), curve: curve, side: side)

proc bounceOut(t: float): float =
  const n = 7.5625
  const d = 2.75
  if t < 1 / d: n * t * t
  elif t < 2 / d: (let u = t - 1.5 / d; n * u * u + 0.75)
  elif t < 2.5 / d: (let u = t - 2.25 / d; n * u * u + 0.9375)
  else: (let u = t - 2.625 / d; n * u * u + 0.984375)

proc easeIn(c: Curve; t: float): float =
  ## (the curve slow at the start)
  case c
  of cvLinear: t
  of cvQuad: t * t
  of cvCubic: t * t * t
  of cvQuart: t * t * t * t
  of cvQuint: t * t * t * t * t
  of cvSine: 1 - cos(t * PI / 2)
  of cvExpo: (if t <= 0: 0.0 else: pow(2.0, 10 * t - 10))
  of cvCirc: 1 - sqrt(max(0.0, 1 - t * t))
  of cvBack: 2.70158 * t * t * t - 1.70158 * t * t
  of cvElastic:
    (if t <= 0: 0.0 elif t >= 1: 1.0 else: -pow(2.0, 10 * t - 10) * sin((t * 10 - 10.75) * 2 * PI / 3))
  of cvBounce: 1 - bounceOut(1 - t)

proc eased*(t: float; curve = cvCubic; side = easeEnd): float =
  ## How far a movement `t` (0 .. 1) of the time along is, along `curve`: 0 at 0, 1 at 1 (in
  ## between beyond them for `cvBack` and `cvElastic`).
  let t = clamp(t, 0.0, 1.0)
  case side
  of easeStart: easeIn(curve, t)
  of easeEnd: 1 - easeIn(curve, 1 - t)
  of easeBoth:
    if t < 0.5: easeIn(curve, 2 * t) / 2 else: 1 - easeIn(curve, 2 - 2 * t) / 2

proc playLength*(steps: openArray[Tween]; together = false): int =
  ## How long `steps` take, in milliseconds: one after another, or `together`.
  for s in steps:
    if together: result = max(result, s.delay + s.ms) else: result += s.delay + s.ms

var plays: Table[Id, tuple[pos: float; forward: bool; t, seen: int]]
  ## (each `played`: how far along, in milliseconds; which way it goes; the last frame)

proc playedAt*(id: Id; forward: bool; steps: openArray[Tween]; together = false; loop = false): seq[float] =
  ## `played` for steps of your own id (`idOf`).
  let total = max(1, playLength(steps, together))
  let now = ui.now
  var p = plays.getOrDefault(id, (0.0, forward, now, now))
  if id notin plays and not forward: p.pos = 0
  let el = float(clamp(now - p.t, 0, 100))     # (a frame late after a pause: not a leap)
  p.t = now
  p.seen = now
  p.forward = forward
  if reducedMotion() and not loop: p.pos = if forward: total.float else: 0.0
  elif forward:
    p.pos += el
    if loop and p.pos >= total.float: p.pos = p.pos mod total.float
  else: p.pos -= el
  p.pos = clamp(p.pos, 0.0, total.float)
  if (forward and (loop or p.pos < total.float)) or (not forward and p.pos > 0): wakeIn(16)
  plays[id] = p
  forget(plays)
  # each step's value where the time is
  var at = 0
  for s in steps:
    let start = at + s.delay
    let t = (p.pos - start.float) / s.ms.float
    result.add mix(s.a, s.b, if t <= 0: 0.0 else: eased(t, s.curve, s.side))
    if not together: at = start + s.ms

template played*(forward: bool; steps: openArray[Tween]; together = false; loop = false;
                 key = ""): seq[float] =
  ## Timed steps -- a value each, from its `a` to its `b` along its curve -- one after another
  ## (or `together`), played on while `forward` is true and back the same way when it turns
  ## false, from wherever they were: a door that swings open then a panel that slides out, and
  ## closing, the panel first. `loop`: over again while `forward` (a spinner, a pulse). Frames
  ## are asked for only while they move; with less movement asked, at their end at once (a
  ## loop still turns).
  ##
  ## .. code-block:: nim
  ##   let v = played(open, [tween(0, 90, 400, cvExpo), tween(0, 1, 250, cvBack)])
  ##   drawDoor(angle = v[0])
  ##   drawPanel(scale = v[1])
  ##   let spin = played(busy, [tween(0, 360, 1200, cvLinear)], loop = true)[0]
  const at = instantiationInfo(-1, true)
  const site = at.filename & ":" & $at.line & ":" & $at.column & ":"
  playedAt(Id(hash(site & key) and 0x7FFFFFFF) + 1, forward, steps, together, loop)

# ---- a box that travels between places of the window --------------------------------------------

proc travelledAt*(id: Id; r: Rect; spec = springSmooth): Rect =
  ## `travelled` for a box of your own id (`idOf`).
  glidedAt(id, r, (0, 0), spec)

template travelled*(r: Rect; key: string; spec = springSmooth): Rect =
  ## Where to draw a box that moves from one part of the window to another -- a card from a
  ## grid into the dialog that shows it bigger, a picture from a list to the page that opens,
  ## and back when it closes: drawn in one place at a time with the same `key`, it flies from
  ## where it was to where it is now (in the window's own coordinates, unlike `glided`, whose
  ## place is in its row or column). Leave the place it left empty while it is away.
  ##
  ## .. code-block:: nim
  ##   if shown == i:                                      # (its dialog open: the card is there)
  ##     dialog(open, "Card"): drawCard(travelled(place(dp(200), dp(200)), "card" & $i), i)
  ##   else: drawCard(travelled(place(dp(96), dp(96)), "card" & $i), i)
  travelledAt(idOf("travelled:" & key), r, spec)

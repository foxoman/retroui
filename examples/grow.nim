## Grow -- a savings goal planner for phones, made with Retro Nim UI alone.
##
## Two pages (`pageView`): the plan, then the result -- sliding in, with
## the phone's Back. The result counts up, fills a ring, raises a 3D bar
## for each year one after another under a camera that sways round them,
## and spins a gold coin over the last one. A tap on a bar says what it
## holds; Share opens the phone's share sheet; a goal reached is felt
## (haptic).
##
## What it shows of the kit: a page's timeline (`easedSince`: a bar a year,
## each starting a little after the one before), the main button at the
## thumb (`spring()` in a column), a number that glides as it changes
## (`animated`), a 3D scene made in code -- boxes, a coin, lines, labels,
## materials of a color (`material3`) -- drawn on the GPU where there is
## one, tapped (`picked`) and turned with a finger; `kpiTile`, `progressRing`,
## `segmented`, `share`, `haptic`, `snackbar`. Made for a phone (portrait);
## it runs on a desktop too, in a window of a phone's size.
##
##   nim c -r -d:release -d:useMalloc examples/grow.nim
##   RETRO_APP=grow nimble appapk          (build/Grow.apk)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/math
import retroui, retroui/system

const GrowVersion* = "1.0.0"

type Plan* = object
  years*: seq[float]     ## the balance at the end of each year
  paidIn*, total*: float
  goalMonth*: int        ## the month the goal is reached (0: not in time)

proc compute*(monthly, target: float; years: int; ratePct: float): Plan =
  ## Saving `monthly` at the end of each month for `years`, growing
  ## `ratePct` a year (compounded monthly).
  let r = ratePct / 100 / 12
  var b = 0.0
  for m in 1 .. years * 12:
    b = b * (1 + r) + monthly
    if result.goalMonth == 0 and b >= target: result.goalMonth = m
    if m mod 12 == 0: result.years.add b
  result.paidIn = monthly * float(years * 12)
  result.total = b

proc money*(v: float): string = formatNumber(v, 0)

const
  Rates = [0.0, 3.0, 5.0, 8.0]
  RateNames = ["0%", "3%", "5%", "8%"]
  Grow = 650        # ms a bar takes to rise
  Lead = 300        # ms before the first bar starts
  Tall = 4.0        # the tallest bar, in scene units

var
  nav = initPages("plan")
  goal = "New car"
  target = 8000.0
  monthly = 150.0
  years = 5
  rateSel = 2
  plan: Plan
  scene: Scene3
  cam: Camera3
  unitH = 1.0
  coin = -1
  shownAt = 0       # when the result opened: its timeline starts there
  lastNow = 0
  orbit = true
  spin = 0.0
  felt = false
  tapped = ""

proc stagger(): int = min(140, 1600 div max(1, plan.years.len))
  ## (how long after the one before each bar starts)

proc buildScene() =
  ## A bar a year (green from the year the goal is reached), the goal's
  ## level as a frame of lines, the coin; framed at full height, then the
  ## bars laid flat to rise.
  scene = Scene3(ambient: 0.5)
  scene.materials.add material3("Saving", color(66, 120, 235), metallic = 0.15, roughness = 0.4)
  scene.materials.add material3("Reached", color(32, 190, 120), metallic = 0.15, roughness = 0.4)
  scene.materials.add material3("Gold", color(255, 196, 60), metallic = 0.7, roughness = 0.3, glow = 0.45)
  let n = plan.years.len
  let cols = min(n, 10)                  # (a decade a row, the first in front)
  let rows = (n + cols - 1) div cols
  unitH = Tall / max(plan.total, target)
  for i, v in plan.years:
    var b = box(0.7, 1, 0.7, name = "Year " & $(i + 1) & ": " & money(v))
    b.material = if v >= target: 1 else: 0
    b.pos = vec3(float(i mod cols) - float(cols - 1) / 2, v * unitH / 2,
                 float(rows - 1) / 2 - float(i div cols))
    b.scale = vec3(1, v * unitH, 1)
    scene.add b
    if n <= 12 or i == 0 or (i + 1) mod 5 == 0:
      scene.addLabel(vec3(b.pos.x, 0, b.pos.z + 0.6), $(i + 1))
  let (x1, z1) = (cols.float / 2 + 0.4, rows.float / 2 + 0.4)
  scene.add plane(2 * x1 + 0.4, 2 * z1 + 0.4, mixColor(ui.theme.window, ui.theme.text, 0.22), "")
  let gy = target * unitH
  let gc = color(255, 170, 40)
  for (a, b) in [(vec3(-x1, gy, -z1), vec3(x1, gy, -z1)), (vec3(x1, gy, -z1), vec3(x1, gy, z1)),
                 (vec3(x1, gy, z1), vec3(-x1, gy, z1)), (vec3(-x1, gy, z1), vec3(-x1, gy, -z1))]:
    scene.addLine(a, b, gc)
  scene.addLabel(vec3(-x1, gy + 0.25, z1), "Goal", gc, bold = true)
  var c = cylinder(0.36, 0.08, name = "Your goal: " & goal)
  c.material = 2
  c.pos = scene.meshes[n - 1].pos
  c.pos.y = plan.total * unitH + 0.75
  coin = scene.add c
  cam = camera3(yaw = 28, pitch = 22)
  fitView(scene, cam)
  for i in 0 ..< n: scene.meshes[i].scale.y = 0.001

proc animateScene(dt: int): bool =
  ## The bars rising one after another, the coin over the last, turning.
  ## True once the coin is all there.
  let n = plan.years.len
  for i in 0 ..< n:
    let h = plan.years[i] * unitH * easedSince(shownAt, Grow, delay = Lead + i * stagger())
    scene.meshes[i].scale.y = max(0.001, h)
    scene.meshes[i].pos.y = h / 2
  let last = easedSince(shownAt, 500, delay = Lead + (n - 1) * stagger() + Grow div 2)
  let el = ui.now - shownAt
  spin = (spin + dt.float * 0.18) mod 360
  scene.meshes[coin].scale = vec3(last, last, last)
  scene.meshes[coin].rot = vec3(90, spin, 0)
  scene.meshes[coin].pos.y = scene.meshes[n - 1].scale.y + 0.75 + 0.08 * sin(el.float / 380)
  if orbit: cam.yaw = float32(28 + 26 * sin(el.float / 2600))   # (a slow sway, never end-on)
  last >= 1.0

proc see() =
  if goal.len == 0: goal = "My goal"
  plan = compute(monthly, target, years, Rates[rateSel])
  buildScene()
  shownAt = ui.now
  lastNow = ui.now
  orbit = true
  felt = false
  tapped = ""
  haptic(hTap)
  nav.push("result")

proc planPage() =
  space(dp(6))
  heading "Grow"
  label "Plan a savings goal and watch it grow.", color = ui.theme.gray
  space(dp(6))
  card "Your goal":
    form(0):
      field("&Goal:"): edit goal
      field("&Target:"): numberEdit(target, decimals = 0, w = 0, lo = 1, hi = 1e12)
      field("Each &month:"): numberEdit(monthly, decimals = 0, w = 0, lo = 0, hi = 1e9)
      field("&Years: " & $years):
        slider(years, 1, 30, ticks = 6)
      field("Gro&wth a year:"):
        segmented(RateNames, rateSel, w = layoutWidth())
  # (a first look that glides as the numbers change)
  let est = compute(monthly, target, years, Rates[rateSel])
  card "In " & $years & (if years == 1: " year" else: " years"):
    row([-1, 0]):
      styledText(money(animated(est.total, 300)), style(bold = true, size = 1.8))
      label $int(round(est.total / target * 100)) & "% of the goal", color = ui.theme.gray
    progress(min(1.0, animated(est.total / target, 300)))
  spring()                                      # (the main action where the thumb is)
  if button("&See my plan", nfLineChart, isDefault = true, w = layoutWidth(), h = dp(48)):
    if monthly <= 0:
      haptic(hError)
      showSnackbar("Save something each month to see it grow", action = "")
    else:
      see()

proc hero(shown, ring: float) =
  ## The total counting up, what was put in, the ring of the goal.
  let r = canvas(0, dp(132))
  let th = ui.theme
  roundRect(r, dp(14).float, mixColor(th.window, th.select, 0.16))
  pushClip(r)        # (two soft circles drifting behind the numbers)
  let t = (ui.now - shownAt).float / 1000
  disc(float(r.x + r.w) - 30 + 10 * sin(t * 0.7), float(r.y) + 10 + 8 * cos(t * 0.9), dp(70).float,
       mixColor(th.window, th.select, 0.26))
  disc(float(r.x) + r.w / 3 + 14 * cos(t * 0.5), float(r.y + r.h) + 20, dp(46).float,
       mixColor(th.window, th.select, 0.22))
  popClip()
  if smoothScrolling: wakeInShown(r, 33)
  pushFrame(inset(r, dp(14)))
  row([-1, 0]):
    col:
      label "In " & $years & (if years == 1: " year you will have" else: " years you will have"),
            color = th.gray
      styledText(money(shown), style(bold = true, size = 2.3))
      if plan.goalMonth > 0:
        pill "Goal in " & $(plan.goalMonth div 12) & "y " & $(plan.goalMonth mod 12) & "m",
             color(32, 170, 110)
      else:
        pill "Short by " & money(target - plan.total), color(220, 120, 40)
    progressRing(ring, size = dp(92))
  discard popFrame()

proc resultPage() =
  let now = ui.now
  let dt = clamp(now - lastNow, 0, 100)
  lastNow = now
  if animateScene(if smoothScrolling: dt else: 0) and not felt:
    felt = true
    if plan.goalMonth > 0: haptic(hSuccess)
  let k = easedSince(shownAt, 1500, delay = 150)
  pageHeader(nav, goal)
  hero(plan.total * k, min(1.0, plan.total / target) * k)
  kpiRow(150):
    kpiTile("You put in", money(plan.paidIn), trend = plan.years)
    kpiTile("Growth", money(plan.total - plan.paidIn),
            delta = (if plan.paidIn > 0: (plan.total - plan.paidIn) / plan.paidIn else: NaN),
            deltaNote = "return")
  let below = CtrlH + dp(44) + 3 * Gap        # (the line under it, the buttons)
  let vh = max(dp(240), remainingH() - below)
  if smoothScrolling: wakeInShown(rect(0, layoutY(), ui.w, vh), 33)   # (the coin turns while seen)
  let ev = view3d(scene, cam, height = vh, key = "grow")
  if ev.cameraChanged: orbit = false           # (a finger took it: leave it there)
  if ev.clicked:
    tapped = if ev.picked >= 0: scene.meshes[ev.picked].name else: ""
  label(if tapped.len > 0: tapped else: "Tap a bar for its year. Drag to turn.",
        color = ui.theme.gray)
  row([-1, -1]):
    if button("&Share", nfShare, h = dp(44)):
      let msg = "My " & goal & " plan: " & money(monthly) & " a month for " & $years &
                " years grows to " & money(plan.total) & " (" & money(plan.paidIn) & " put in). Made with Grow."
      if not share(text = msg, title = "Grow"):
        putClipboardText(msg)
        toast("Copied to the clipboard", glyph = nfCheck)
    if button("Plan &again", nfRefresh, h = dp(44)):
      nav.pop()

when isMainModule and not declared(growUnderTest):
  app "Grow", 400, 820, id = "grow", look = "grow", theme = Midnight, version = GrowVersion:
    pageView(nav):
      case nav.page
      of "result": resultPage()
      else: planPage()
    discard snackbar()

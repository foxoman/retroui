## Brush presets as Photoshop keeps them: a tip, its dynamics and its
## settings, named, in folders -- General, Dry Media, Wet Media and Special
## Effects Brushes, as Photoshop 2026 has them. The built-in tips are drawn
## here (chalk grain, charcoal, bristles, watercolor, spatter, leaves,
## stars, grass, confetti, smoke...): none of them is Adobe's. A preset is
## kept as JSON; a stroke shows each. Use it for a paint program's Brushes
## palette (with `retroui/photopaint`'s tools).
##
## ```nim
## var presets = defaultPresets()
## let px = strokePreview(presets[0], 160, 40)       # (ARGB, w x h)
## ```

import std/[math, random, json, strutils, base64]
import photo, photopaint
from codec import unbase64

type
  TipKind* = enum
    ## The built-in sampled tips.
    tkChalk = "Chalk", tkCharcoal = "Charcoal", tkPastel = "Pastel", tkGrainPencil = "Grain",
    tkWatercolor = "Watercolor", tkBristle = "Bristle", tkDryBrush = "Dry Brush",
    tkSpatter = "Spatter", tkLeaf = "Leaf", tkStar = "Star", tkGrass = "Grass", tkConfetti = "Confetti",
    tkSmoke = "Smoke", tkSponge = "Sponge", tkSquare = "Square", tkFlat = "Flat"

  BrushPreset* = object
    ## A brush of the Brushes palette: its tip, its dynamics, its settings.
    name*, folder*: string       ## its name, and the folder it is listed in ("Dry Media")
    tip*: BrushTip               ## its tip
    dyn*: BrushDynamics          ## how size, angle, scatter, color... change along a stroke
    wet*: bool                   ## Wet Edges
    smoothing*: int              ## Smoothing, 0..100 (0: the tool's)
    opacity*: int                ## 0: the tool's
    sizeByPressure*, opacityByPressure*: bool  ## the pen's pressure sets its size, its opacity

const
  presetFolders* = ["General Brushes", "Dry Media Brushes", "Wet Media Brushes", "Special Effects Brushes"]
    ## The folders of the built-in brushes.
  TipSide = 128                  ## the built-in sampled tips' size (they are scaled to the brush's)

# ---- the tips ----------------------------------------------------------------------------------------

proc blob(px: var seq[float]; n: int; cx, cy, r, v: float; soft = 0.6) =
  ## A soft round spot added to `px` (n x n).
  let x0 = max(0, int(cx - r) - 1)
  let x1 = min(n - 1, int(cx + r) + 1)
  let y0 = max(0, int(cy - r) - 1)
  let y1 = min(n - 1, int(cy + r) + 1)
  for y in y0 .. y1:
    for x in x0 .. x1:
      let d = sqrt((x.float + 0.5 - cx) ^ 2 + (y.float + 0.5 - cy) ^ 2) / max(0.5, r)
      if d >= 1: continue
      let a = if d <= 1 - soft: 1.0 else: 0.5 + 0.5 * cos((d - (1 - soft)) / max(0.001, soft) * PI)
      px[y * n + x] = max(px[y * n + x], a * v)

proc polygon(px: var seq[float]; n: int; pts: openArray[(float, float)]; v = 1.0) =
  ## A filled polygon (4 samples a pixel: smooth edges).
  var x0, y0 = n
  var x1, y1 = 0
  for (px0, py0) in pts:
    x0 = min(x0, int(floor(px0)))
    y0 = min(y0, int(floor(py0)))
    x1 = max(x1, int(ceil(px0)))
    y1 = max(y1, int(ceil(py0)))
  for y in max(0, y0) .. min(n - 1, y1):
    for x in max(0, x0) .. min(n - 1, x1):
      var hits = 0
      for (sx, sy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)]:
        let px0 = x.float + sx
        let py0 = y.float + sy
        var inside = false
        var j = pts.high
        for i in 0 .. pts.high:
          let (xi, yi) = pts[i]
          let (xj, yj) = pts[j]
          if (yi > py0) != (yj > py0) and px0 < (xj - xi) * (py0 - yi) / (yj - yi) + xi: inside = not inside
          j = i
        if inside: inc hits
      if hits > 0: px[y * n + x] = max(px[y * n + x], v * hits.float / 4)

proc noiseField(n: int; rng: var Rand; cell: int): seq[float] =
  ## Smooth value noise, `cell` pixels a lump.
  let g = n div max(1, cell) + 2
  var grid = newSeq[float](g * g)
  for v in grid.mitems: v = rng.rand(1.0)
  result = newSeq[float](n * n)
  for y in 0 ..< n:
    for x in 0 ..< n:
      let fx = x / cell
      let fy = y / cell
      let ix = int(fx)
      let iy = int(fy)
      let tx = fx - ix.float
      let ty = fy - iy.float
      let sx = tx * tx * (3 - 2 * tx)
      let sy = ty * ty * (3 - 2 * ty)
      let a = grid[iy * g + ix] * (1 - sx) + grid[iy * g + ix + 1] * sx
      let b = grid[(iy + 1) * g + ix] * (1 - sx) + grid[(iy + 1) * g + ix + 1] * sx
      result[y * n + x] = a * (1 - sy) + b * sy

proc makeTip*(kind: TipKind; seed = 7): BrushTip =
  ## A built-in sampled tip (128 x 128; the brush's size scales it).
  let n = TipSide
  var px = newSeq[float](n * n)
  var rng = initRand(seed * 7919 + ord(kind) * 104729 + 1)
  let c = n.float / 2
  case kind
  of tkChalk, tkPastel, tkGrainPencil:
    # a disc of paper grain: lumps of chalk, gaps where the paper shows
    let grain = noiseField(n, rng, if kind == tkGrainPencil: 3 else: 5)
    let fine = noiseField(n, rng, 2)
    let edgeSoft = if kind == tkPastel: 0.45 else: 0.25
    for y in 0 ..< n:
      for x in 0 ..< n:
        let d = sqrt((x.float + 0.5 - c) ^ 2 + (y.float + 0.5 - c) ^ 2) / (c - 2)
        if d >= 1: continue
        let disc = if d <= 1 - edgeSoft: 1.0 else: 0.5 + 0.5 * cos((d - (1 - edgeSoft)) / edgeSoft * PI)
        let g = grain[y * n + x] * 0.7 + fine[y * n + x] * 0.3
        let t = if kind == tkPastel: 0.25 else: 0.38
        px[y * n + x] = disc * clamp((g - t) / 0.35, 0.0, 1.0)
  of tkCharcoal:
    # streaks along one way, broken by grain
    let grain = noiseField(n, rng, 4)
    var streaks = newSeq[float](n)
    for v in streaks.mitems: v = rng.rand(1.0)
    for y in 0 ..< n:
      let s = streaks[y] * 0.6 + streaks[max(0, y - 1)] * 0.2 + streaks[min(n - 1, y + 1)] * 0.2
      for x in 0 ..< n:
        let dx = (x.float + 0.5 - c) / (c - 2)
        let dy = (y.float + 0.5 - c) / (c * 0.55)
        let d = sqrt(dx * dx + dy * dy)
        if d >= 1: continue
        let shape = 1 - d * d
        px[y * n + x] = clamp(shape * (s * 0.8 + grain[y * n + x] * 0.6) * 1.4 - 0.25, 0.0, 1.0)
  of tkWatercolor:
    # a soft wash, darker at its rim, mottled
    let mottle = noiseField(n, rng, 10)
    for y in 0 ..< n:
      for x in 0 ..< n:
        let wob = (mottle[y * n + x] - 0.5) * 0.18
        let d = sqrt((x.float + 0.5 - c) ^ 2 + (y.float + 0.5 - c) ^ 2) / (c - 2) + wob
        if d >= 1: continue
        let body = 0.35 + 0.25 * mottle[y * n + x]
        let rim = exp(-((d - 0.88) ^ 2) / 0.006) * 0.55
        px[y * n + x] = clamp(body + rim, 0.0, 1.0) * clamp((1 - d) * 12, 0.0, 1.0)
  of tkBristle, tkFlat:
    # hairs: little round dabs in an ellipse (Flat: a wide row of them)
    let hairs = if kind == tkFlat: 70 else: 46
    for i in 0 ..< hairs:
      let a = rng.rand(2 * PI)
      let rr = sqrt(rng.rand(1.0))
      let hx = c + cos(a) * rr * (c - 8) * (if kind == tkFlat: 1.0 else: 0.9)
      let hy = c + sin(a) * rr * (c - 8) * (if kind == tkFlat: 0.25 else: 0.7)
      blob(px, n, hx, hy, 3.5 + rng.rand(3.5), 0.55 + rng.rand(0.45), 0.7)
  of tkDryBrush:
    # broken streaks: a dry brush dragged
    for row in 0 ..< 22:
      let y = 14 + row.float * (n - 28).float / 21
      var x = 6.0 + rng.rand(20.0)
      let stop = n.float - 6 - rng.rand(20.0)
      while x < stop:
        let len = 6 + rng.rand(30.0)
        let v = 0.5 + rng.rand(0.5)
        var t = 0.0
        while t < len and x + t < stop:
          blob(px, n, x + t, y + rng.rand(1.5), 1.6 + rng.rand(0.8), v, 0.8)
          t += 1.5
        x += len + rng.rand(10.0)
  of tkSpatter:
    for i in 0 ..< 60:
      let a = rng.rand(2 * PI)
      let rr = pow(rng.rand(1.0), 0.6) * (c - 8)
      blob(px, n, c + cos(a) * rr, c + sin(a) * rr, 1.5 + rng.rand(1.0) * (1 - rr / c) * 9, 0.7 + rng.rand(0.3), 0.4)
  of tkLeaf:
    # a leaf: two curves to a point, a vein down the middle
    var pts: seq[(float, float)]
    for i in 0 .. 40:
      let t = i / 40
      pts.add (c + sin(t * PI) * (c - 18) * 0.62, 8 + t * (n.float - 16))
    for i in countdown(40, 0):
      let t = i / 40
      pts.add (c - sin(t * PI) * (c - 18) * 0.62, 8 + t * (n.float - 16))
    polygon(px, n, pts)
    for y in 10 ..< n - 10:
      for x in int(c) - 1 .. int(c):
        px[y * n + x] = px[y * n + x] * 0.35
  of tkStar:
    var pts: seq[(float, float)]
    for i in 0 ..< 10:
      let a = -PI / 2 + i.float * PI / 5
      let r = if i mod 2 == 0: c - 4 else: (c - 4) * 0.42
      pts.add (c + cos(a) * r, c + sin(a) * r)
    polygon(px, n, pts)
  of tkGrass:
    # blades: thin curved spikes from the bottom
    for i in 0 ..< 9:
      let bx = c + (rng.rand(2.0) - 1) * c * 0.55
      let lean = (rng.rand(2.0) - 1) * 26
      let hgt = n.float * (0.55 + rng.rand(0.4))
      let wid = 3.0 + rng.rand(3.0)
      var pts: seq[(float, float)]
      for k in 0 .. 12:
        let t = k / 12
        pts.add (bx - wid * (1 - t) + lean * t * t, n.float - 2 - hgt * t)
      for k in countdown(12, 0):
        let t = k / 12
        pts.add (bx + wid * (1 - t) + lean * t * t, n.float - 2 - hgt * t)
      polygon(px, n, pts, 0.75 + rng.rand(0.25))
  of tkConfetti:
    for i in 0 ..< 7:
      let x = 14 + rng.rand(n.float - 28)
      let y = 14 + rng.rand(n.float - 28)
      let s = 5 + rng.rand(7.0)
      let a = rng.rand(PI)
      var pts: seq[(float, float)]
      for (u, v) in [(-1.0, -0.5), (1.0, -0.5), (1.0, 0.5), (-1.0, 0.5)]:
        pts.add (x + (u * cos(a) - v * sin(a)) * s, y + (u * sin(a) + v * cos(a)) * s)
      polygon(px, n, pts)
  of tkSmoke:
    let f1 = noiseField(n, rng, 18)
    let f2 = noiseField(n, rng, 7)
    for y in 0 ..< n:
      for x in 0 ..< n:
        let d = sqrt((x.float + 0.5 - c) ^ 2 + (y.float + 0.5 - c) ^ 2) / (c - 2)
        if d >= 1: continue
        let fall = 0.5 + 0.5 * cos(d * PI)
        px[y * n + x] = clamp((f1[y * n + x] * 0.7 + f2[y * n + x] * 0.3) * fall * 1.5 - 0.15, 0.0, 1.0)
  of tkSponge:
    let holes = noiseField(n, rng, 6)
    for y in 0 ..< n:
      for x in 0 ..< n:
        let d = sqrt((x.float + 0.5 - c) ^ 2 + (y.float + 0.5 - c) ^ 2) / (c - 2)
        if d >= 1: continue
        px[y * n + x] = if holes[y * n + x] > 0.42: clamp((1 - d) * 6, 0.0, 1.0) else: 0.0
  of tkSquare:
    for y in 8 ..< n - 8:
      for x in 8 ..< n - 8: px[y * n + x] = 1
  result = BrushTip(name: $kind, custom: newSeq[uint8](n * n), cw: n, ch: n, diameter: n,
                    spacing: 25, roundness: 100, hardness: 100)
  for i, v in px: result.custom[i] = uint8(clamp(int(round(v * 255)), 0, 255))

proc sized*(t: BrushTip; d: int): BrushTip =
  ## `t` at `d` pixels across (a sampled tip: its picture averaged down
  ## when that is smaller; bigger, it is read smoothly scaled).
  result = t
  let d = clamp(d, 1, MaxDiameter)
  result.diameter = d
  if t.custom.len == 0 or t.cw <= 0 or t.ch <= 0: return
  let side = max(t.cw, t.ch)
  if d >= side: return
  let k = d / side
  let nw = max(1, int(round(t.cw.float * k)))
  let nh = max(1, int(round(t.ch.float * k)))
  var o = newSeq[uint8](nw * nh)
  for y in 0 ..< nh:
    let y0 = y * t.ch div nh
    let y1 = max(y0 + 1, (y + 1) * t.ch div nh)
    for x in 0 ..< nw:
      let x0 = x * t.cw div nw
      let x1 = max(x0 + 1, (x + 1) * t.cw div nw)
      var acc = 0
      for yy in y0 ..< y1:
        for xx in x0 ..< x1: acc += int(t.custom[yy * t.cw + xx])
      o[y * nw + x] = uint8(acc div ((y1 - y0) * (x1 - x0)))
  result.custom = o
  result.cw = nw
  result.ch = nh

proc tipSize*(t: BrushTip): int =
  ## A tip's size in pixels (across its longer side).
  if t.diameter > 0: t.diameter elif t.custom.len > 0: max(t.cw, t.ch) else: 1

# ---- the built-in presets --------------------------------------------------------------------------------

proc preset(name, folder: string; tip: BrushTip; dyn = BrushDynamics(); wet = false;
            size = 0; sizeP = false; opacityP = false; opacity = 0): BrushPreset =
  var t = tip
  if size > 0: t = t.sized(size)
  t.name = name
  BrushPreset(name: name, folder: folder, tip: t, dyn: dyn, wet: wet, sizeByPressure: sizeP,
              opacityByPressure: opacityP, opacity: opacity)

proc round(d, hardness: int; spacing = 25; roundness = 100; angle = 0): BrushTip =
  BrushTip(diameter: d, hardness: hardness, spacing: spacing, roundness: roundness, angle: angle)

proc defaultPresets*(): seq[BrushPreset] =
  ## The brushes a new Brushes palette has, in Photoshop's four folders.
  const g = presetFolders[0]
  const dry = presetFolders[1]
  const wetF = presetFolders[2]
  const fx = presetFolders[3]
  result.add preset("Soft Round", g, round(30, 0))
  result.add preset("Hard Round", g, round(30, 100))
  result.add preset("Soft Round Pressure Size", g, round(45, 0), BrushDynamics(sizeControl: dcPressure), sizeP = true)
  result.add preset("Hard Round Pressure Size", g, round(19, 100), BrushDynamics(sizeControl: dcPressure), sizeP = true)
  result.add preset("Soft Round Pressure Opacity", g, round(65, 0),
                    BrushDynamics(opacityControl: dcPressure), opacityP = true)
  result.add preset("Hard Round Pressure Opacity", g, round(13, 100),
                    BrushDynamics(opacityControl: dcPressure), opacityP = true)
  result.add preset("Soft Airbrush", g, round(100, 0), BrushDynamics(buildUp: true, flow: 10))
  result.add preset("Hard Square", g, makeTip(tkSquare), size = 24)
  result.add preset("Calligraphic", g, round(28, 100, 10, 22, 45))
  result.add preset("Hard Round 1 px", g, round(1, 100, 1))
  result.add preset("Soft Round Big", g, round(300, 0))
  result.add preset("Soft Round 2500", g, round(2500, 0))
  # dry media
  result.add preset("Grain Pencil", dry, makeTip(tkGrainPencil), BrushDynamics(sizeControl: dcPressure,
                    angleJitter: 100), size = 9, sizeP = true)
  result.add preset("Charcoal", dry, makeTip(tkCharcoal), BrushDynamics(angleControl: anDirection,
                    sizeJitter: 20, minDiameter: 60), size = 40)
  result.add preset("Chalk", dry, makeTip(tkChalk), BrushDynamics(angleJitter: 100, sizeJitter: 10,
                    minDiameter: 70), size = 36)
  result.add preset("Soft Pastel", dry, makeTip(tkPastel), BrushDynamics(angleJitter: 100, flow: 70,
                    opacityJitter: 20), size = 34)
  result.add preset("Crayon", dry, makeTip(tkChalk, 3), BrushDynamics(angleControl: anDirection,
                    roundJitter: 0), size = 22)
  result.add preset("Graphite Smudge", dry, makeTip(tkPastel, 5), BrushDynamics(flow: 25, angleJitter: 100,
                    noise: true), size = 50)
  # wet media
  result.add preset("Watercolor Wash", wetF, makeTip(tkWatercolor), BrushDynamics(flow: 30, angleJitter: 100,
                    sizeJitter: 15, minDiameter: 70, buildUp: true), wet = true, size = 90)
  result.add preset("Watercolor Round", wetF, round(40, 20), BrushDynamics(flow: 45, opacityJitter: 15),
                    wet = true)
  result.add preset("Oil Bristle", wetF, makeTip(tkBristle), BrushDynamics(angleControl: anDirection,
                    flow: 85, brightJitter: 4), size = 40)
  result.add preset("Flat Bristle", wetF, makeTip(tkFlat), BrushDynamics(angleControl: anDirection,
                    flow: 80), size = 48)
  result.add preset("Ink Pen", wetF, round(6, 100, 5, 70, 30), BrushDynamics(sizeControl: dcPressure,
                    minDiameter: 30), sizeP = true)
  result.add preset("Dry Brush", wetF, makeTip(tkDryBrush), BrushDynamics(angleControl: anDirection,
                    flow: 90), size = 60)
  result.add preset("Gouache", wetF, makeTip(tkBristle, 11), BrushDynamics(angleControl: anDirection,
                    flow: 95, fgBgJitter: 6), size = 36)
  # special effects
  result.add preset("Spatter", fx, makeTip(tkSpatter), BrushDynamics(scatter: 120, sizeJitter: 60,
                    angleJitter: 100, minDiameter: 20), size = 60)
  result.add preset("Leaves", fx, makeTip(tkLeaf), BrushDynamics(scatter: 180, scatterBoth: true, count: 2,
                    sizeJitter: 50, minDiameter: 40, angleJitter: 100, fgBgJitter: 100, hueJitter: 6,
                    flipXJitter: true), size = 50)
  result.add preset("Stars", fx, makeTip(tkStar), BrushDynamics(scatter: 300, scatterBoth: true, count: 3,
                    sizeJitter: 80, minDiameter: 10, angleJitter: 30, opacityJitter: 40), size = 36)
  result.add preset("Grass", fx, makeTip(tkGrass), BrushDynamics(scatter: 60, sizeJitter: 50, minDiameter: 40,
                    angleJitter: 6, fgBgJitter: 70, flipXJitter: true), size = 70)
  result.add preset("Confetti", fx, makeTip(tkConfetti), BrushDynamics(scatter: 400, scatterBoth: true,
                    count: 3, sizeJitter: 40, angleJitter: 100, hueJitter: 100, satJitter: 20), size = 40)
  result.add preset("Smoke", fx, makeTip(tkSmoke), BrushDynamics(flow: 20, scatter: 40, angleJitter: 100,
                    sizeJitter: 40, minDiameter: 50, opacityJitter: 50), size = 140)
  result.add preset("Sponge", fx, makeTip(tkSponge), BrushDynamics(angleJitter: 100, opacityJitter: 30),
                    size = 50)
  for p in result.mitems:
    case p.name
    of "Hard Square", "Charcoal", "Crayon", "Oil Bristle", "Flat Bristle", "Dry Brush", "Gouache":
      p.tip.spacing = 10
    of "Spatter", "Leaves", "Stars", "Confetti": p.tip.spacing = 60
    of "Grass": p.tip.spacing = 35
    of "Smoke", "Watercolor Wash": p.tip.spacing = 15
    else: discard

# ---- kept as JSON ------------------------------------------------------------------------------------

proc toJson*(p: BrushPreset): JsonNode =
  ## A preset as JSON, its tip too (see `presetOf`).
  result = %*{"name": p.name, "folder": p.folder, "wet": p.wet, "smoothing": p.smoothing,
              "opacity": p.opacity, "sizeByPressure": p.sizeByPressure,
              "opacityByPressure": p.opacityByPressure}
  let t = p.tip
  var tj = %*{"name": t.name, "diameter": t.diameter, "hardness": t.hardness, "spacing": t.spacing,
              "angle": t.angle, "roundness": t.roundness, "flipX": t.flipX, "flipY": t.flipY}
  if t.custom.len > 0:
    var raw = newString(t.custom.len)
    for i, v in t.custom: raw[i] = char(v)
    tj["cw"] = %t.cw
    tj["ch"] = %t.ch
    tj["custom"] = %encode(raw)
  result["tip"] = tj
  result["dyn"] = %p.dyn

proc presetOf*(j: JsonNode): BrushPreset =
  ## A preset from its JSON (`toJson`); what is missing keeps its default.
  result.name = j{"name"}.getStr("Brush")
  result.folder = j{"folder"}.getStr(presetFolders[0])
  result.wet = j{"wet"}.getBool(false)
  result.smoothing = j{"smoothing"}.getInt(0)
  result.opacity = j{"opacity"}.getInt(0)
  result.sizeByPressure = j{"sizeByPressure"}.getBool(false)
  result.opacityByPressure = j{"opacityByPressure"}.getBool(false)
  let t = j{"tip"}
  if t != nil:
    result.tip = BrushTip(name: t{"name"}.getStr(result.name), diameter: clamp(t{"diameter"}.getInt(30), 1, MaxDiameter),
                          hardness: t{"hardness"}.getInt(100), spacing: t{"spacing"}.getInt(25),
                          angle: t{"angle"}.getInt(0), roundness: t{"roundness"}.getInt(100),
                          flipX: t{"flipX"}.getBool(false), flipY: t{"flipY"}.getBool(false))
    if t{"custom"} != nil:
      let raw = unbase64(t{"custom"}.getStr(""))
      let cw = t{"cw"}.getInt(0)
      let ch = t{"ch"}.getInt(0)
      if cw > 0 and ch > 0 and raw.len == cw * ch:
        result.tip.cw = cw
        result.tip.ch = ch
        result.tip.custom = newSeq[uint8](raw.len)
        for i, c in raw: result.tip.custom[i] = uint8(ord(c))
  else:
    result.tip = BrushTip(diameter: 30, hardness: 100, spacing: 25, roundness: 100)
  if j{"dyn"} != nil:
    try: result.dyn = j["dyn"].to(BrushDynamics)
    except CatchableError: discard

proc presetsToJson*(ps: openArray[BrushPreset]): string =
  ## Presets as a JSON file's text.
  var a = newJArray()
  for p in ps: a.add p.toJson
  $(%*{"retroBrushes": 1, "presets": a})

proc presetsFromJson*(s: string): seq[BrushPreset] =
  ## Presets from `presetsToJson`'s text; raises `ValueError` when it is
  ## not that.
  let j = try: parseJson(s) except CatchableError: raise newException(ValueError, "not a brushes file")
  if j.kind != JObject or j{"presets"} == nil or j["presets"].kind != JArray:
    raise newException(ValueError, "not a brushes file")
  for p in j["presets"]: result.add presetOf(p)

# ---- a stroke that shows a brush -----------------------------------------------------------------------

proc strokePreview*(p: BrushPreset; w, h: int; color = 0xFF000000'u32; bg = 0xFFFFFFFF'u32;
                    sizeTo = -1): seq[uint32] =
  ## A wave painted with the brush on `bg`, `w` x `h` (ARGB): its size
  ## made to fit (`sizeTo` pixels across; -1: two fifths of the height).
  let d = newDoc(w, h, bg)
  var o = PaintOpts(tool: tkBrush, color: color, bg: 0xFFFFFFFF'u32, opacity: max(1, if p.opacity > 0: p.opacity else: 100),
                    wet: p.wet, dyn: p.dyn)
  o.dyn.symmetry = syNone
  o.sizeByPressure = p.sizeByPressure
  o.opacityByPressure = p.opacityByPressure
  let want = if sizeTo > 0: sizeTo else: max(2, h * 2 div 5)
  var tip = p.tip.sized(min(p.tip.tipSize, want))
  if tip.custom.len > 0: tip.diameter = min(tip.diameter, want)
  d.beginStep("Preview")
  let steps = 48
  let fy = proc (i: int): float = h / 2 + sin(i.float / steps.float * PI * 2) * h.float * 0.22
  var st = d.beginStroke(o, tip, 8, fy(0), pressure = 0.25)
  st.startStroke()
  for i in 1 .. steps:
    # (the pressure rises and falls along it: pressure-driven brushes show it)
    let pr = 0.25 + 0.75 * sin(i.float / steps.float * PI)
    st.strokeTo(8 + (w - 16).float * i.float / steps.float, fy(i), pr)
  st.endStroke()
  d.endStep()
  d.updateComposite()
  result = newSeq[uint32](w * h)
  for i in 0 ..< w * h: result[i] = d.compPtr[i]

proc tipPreview*(t: BrushTip; side: int): seq[uint8] =
  ## The tip's shape, `side` x `side` (0..255), its size made to fit.
  var tip = t
  if tip.custom.len > 0: tip = tip.sized(min(tip.tipSize, side - 2))
  else: tip.diameter = min(tip.diameter, side - 2)
  let m = tipMask(tip)
  result = newSeq[uint8](side * side)
  let ox = (side - m.fullW) div 2
  let oy = (side - m.fullH) div 2
  for y in 0 ..< min(side, m.fullH):
    for x in 0 ..< min(side, m.fullW):
      let xx = x + ox
      let yy = y + oy
      if xx >= 0 and yy >= 0 and xx < side and yy < side:
        result[yy * side + xx] = uint8(clamp(int(round(m.maskAt(x, y) * 255)), 0, 255))

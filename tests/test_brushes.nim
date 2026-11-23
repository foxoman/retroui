## Brush presets (retroui/photobrushes) and the brush engine's sizes and
## dynamics: every built-in brush paints, presets survive JSON, a brush up
## to 5000 pixels keeps a small mask, Fade, Direction, Flip, Build-up,
## Noise and Brush Pose do what they say.

import std/[unittest, math, sets]
import retroui/[photo, photopaint, photobrushes]

proc painted(px: openArray[uint32]; bg = 0xFFFFFFFF'u32): int =
  for p in px:
    if p != bg: inc result

proc darkSum(d: Doc): int =
  d.updateComposite()
  for i in 0 ..< d.w * d.h: result += 255 - (d.compPtr[i] and 255).int

suite "brush presets":
  test "Photoshop's four folders, and every brush paints":
    let ps = defaultPresets()
    var folders: HashSet[string]
    for p in ps: folders.incl p.folder
    check folders.len == 4
    for f in presetFolders: check f in folders
    check ps.len >= 28
    var names: HashSet[string]
    for p in ps:
      check p.name notin names
      names.incl p.name
      let px = strokePreview(p, 120, 32)
      check px.len == 120 * 32
      check painted(px) > 40
      let tp = tipPreview(p.tip, 32)
      var any = false
      for v in tp:
        if v > 0: any = true
      check any

  test "the built-in tips are our own pictures":
    for k in TipKind:
      let t = makeTip(k)
      check t.cw == 128 and t.ch == 128 and t.custom.len == 128 * 128
      var on = 0
      for v in t.custom:
        if v > 0: inc on
      check on > 100                       # (something drawn)
      check on < 128 * 128                 # (not all of it)
    # the same seed, the same tip; another, another
    check makeTip(tkSpatter, 3).custom == makeTip(tkSpatter, 3).custom
    check makeTip(tkSpatter, 3).custom != makeTip(tkSpatter, 4).custom

  test "kept as JSON":
    let ps = defaultPresets()
    let back = presetsFromJson(presetsToJson(ps))
    check back.len == ps.len
    for i in 0 ..< ps.len:
      check back[i].name == ps[i].name and back[i].folder == ps[i].folder
      check back[i].tip == ps[i].tip
      check back[i].dyn == ps[i].dyn
      check back[i].wet == ps[i].wet
    expect ValueError: discard presetsFromJson("not json at all")
    expect ValueError: discard presetsFromJson("""{"x": 1}""")

suite "brush sizes":
  test "1 to 5000 pixels, the mask at most 1024 across":
    for dia in [1, 3, 30, 300, 1024, 1500, 2500, 5000]:
      for hard in [0, 100]:
        let m = tipMask(BrushTip(diameter: dia, hardness: hard, spacing: 25, roundness: 100))
        check m.w <= MaxMaskSide + 2 and m.h <= MaxMaskSide + 2
        check abs(m.fullW - (dia + 2)) <= max(3, dia div 200)
        # (the middle is full, the corner empty)
        check m.maskAt(m.fullW div 2, m.fullH div 2) > (if dia >= 30: 0.99 else: 0.5)
        check m.maskAt(0, 0) == 0
    # a big hard brush's edge: smooth over about a pixel, not a staircase
    let m = tipMask(BrushTip(diameter: 4000, hardness: 100, spacing: 25, roundness: 100))
    let c = m.fullW div 2
    var partial = 0
    for x in c + 1980 .. c + 2010:
      let a = m.maskAt(x, c)
      if a > 0.02 and a < 0.98: inc partial
    check partial in 1 .. 12
    # a sampled tip at 3000: painted that big, from its 128-pixel picture
    let t = makeTip(tkChalk).sized(3000)
    check t.diameter == 3000 and t.cw == 128
    let tm = tipMask(t)
    check tm.fullW == 3000 and tm.w <= MaxMaskSide

  test "a 5000-pixel stroke paints, and quickly enough":
    let d = newDoc(6000, 3000, 0xFFFFFFFF'u32)
    d.beginStep("Paint")
    var s = d.beginStroke(PaintOpts(tool: tkBrush, color: 0xFF000000'u32, opacity: 100),
                          BrushTip(diameter: 5000, hardness: 0, spacing: 25, roundness: 100), 3000, 1500)
    s.startStroke()
    s.strokeTo(3300, 1500)
    s.endStroke()
    d.endStep()
    d.updateComposite()
    check d.compPtr[1500 * 6000 + 3000] != 0xFFFFFFFF'u32
    check d.compPtr[1500 * 6000 + 600] != 0xFFFFFFFF'u32        # (2400 from the middle: inside)
    check d.compPtr[0] == 0xFFFFFFFF'u32           # (a corner: outside the brush)

  test "sizes of a sampled tip":
    let t = makeTip(tkLeaf)
    check t.sized(32).cw == 32 and t.sized(32).diameter == 32
    check t.sized(400).cw == 128 and t.sized(400).diameter == 400
    let turned = t.sized(64).turned(45)
    check turned.angle == 0 and turned.cw > 64 and turned.diameter > 64

suite "dynamics":
  proc strokeOf(dyn: BrushDynamics; tip = BrushTip(diameter: 20, hardness: 100, spacing: 25, roundness: 100);
                opts = PaintOpts(); ticks = 0): Doc =
    result = newDoc(400, 100, 0xFFFFFFFF'u32)
    var o = opts
    o.tool = if o.tool == tkBrush: tkBrush else: o.tool
    o.color = 0xFF000000'u32
    o.opacity = 100
    o.dyn = dyn
    result.beginStep("Paint")
    var s = result.beginStroke(o, tip, 20, 50)
    s.startStroke()
    for k in 0 ..< ticks: s.strokeTick()
    for i in 1 .. 36: s.strokeTo(20 + i.float * 10, 50)
    s.endStroke()
    result.endStep()

  test "Size: Fade makes the stroke thinner along it":
    let d = strokeOf(BrushDynamics(sizeControl: dcFade, sizeFade: 60, minDiameter: 10))
    d.updateComposite()
    proc thick(x: int): int =
      for y in 0 ..< 100:
        if d.compPtr[y * 400 + x] != 0xFFFFFFFF'u32: inc result
    check thick(40) > thick(330) + 6

  test "Angle: Direction turns a flat tip with the stroke":
    let flat = BrushTip(diameter: 30, hardness: 100, spacing: 10, roundness: 15, angle: 0)
    # along the stroke (x): the flat tip lies along it -- a thin line
    let along = strokeOf(BrushDynamics(angleControl: anDirection), flat)
    # without it, the tip stands across -- turned 90: thick
    let across = strokeOf(BrushDynamics(), BrushTip(diameter: 30, hardness: 100, spacing: 10, roundness: 15,
                                                     angle: 90))
    check along.darkSum < across.darkSum

  test "Build-up: paint keeps coming while held":
    let soft = BrushTip(diameter: 30, hardness: 0, spacing: 25, roundness: 100)
    let held = strokeOf(BrushDynamics(buildUp: true, flow: 20), soft, ticks = 20)
    let quick = strokeOf(BrushDynamics(buildUp: true, flow: 20), soft, ticks = 0)
    check held.darkSum > quick.darkSum

  test "Noise, Flip, Brush Pose and Color Dynamics paint":
    let soft = BrushTip(diameter: 30, hardness: 0, spacing: 25, roundness: 100)
    check strokeOf(BrushDynamics(noise: true), soft).darkSum != strokeOf(BrushDynamics(), soft).darkSum
    check strokeOf(BrushDynamics(flipXJitter: true, flipYJitter: true), makeTip(tkLeaf).sized(30)).darkSum > 0
    let posed = strokeOf(BrushDynamics(pose: true, tiltX: 100, posePressure: 100), soft)
    check posed.darkSum < strokeOf(BrushDynamics(), soft).darkSum      # (tilted: a flatter dab)
    let d = strokeOf(BrushDynamics(hueJitter: 100, satJitter: 50, purity: 30))
    check d.darkSum > 0

  test "Size: Pen Pressure":
    let d = newDoc(400, 100, 0xFFFFFFFF'u32)
    d.beginStep("Paint")
    var s = d.beginStroke(PaintOpts(tool: tkBrush, color: 0xFF000000'u32, opacity: 100,
                                    dyn: BrushDynamics(sizeControl: dcPressure)),
                          BrushTip(diameter: 40, hardness: 100, spacing: 10, roundness: 100), 20, 50, 0.1)
    s.startStroke()
    for i in 1 .. 36: s.strokeTo(20 + i.float * 10, 50, if i < 18: 0.1 else: 1.0)
    s.endStroke()
    d.endStep()
    d.updateComposite()
    proc thick(x: int): int =
      for y in 0 ..< 100:
        if d.compPtr[y * 400 + x] != 0xFFFFFFFF'u32: inc result
    check thick(320) > thick(80) * 2

suite "the tip's outline (the pointer over the picture)":
  proc bounds(segs: seq[array[4, float32]]): (float32, float32, float32, float32) =
    result = (1e9'f32, 1e9'f32, -1e9'f32, -1e9'f32)
    for s in segs:
      for (x, y) in [(s[0], s[1]), (s[2], s[3])]:
        result[0] = min(result[0], x); result[1] = min(result[1], y)
        result[2] = max(result[2], x); result[3] = max(result[3], y)

  test "a round tip: a circle its size, at every size":
    for d in [9, 40, 300, 2500]:
      let segs = tipOutline(hardTip(d))
      check segs.len >= 8
      let (x0, y0, x1, y1) = bounds(segs)
      check abs((x1 - x0) - d.float32) <= max(2'f32, d.float32 * 0.04)
      check abs(x0 + x1) <= max(2'f32, d.float32 * 0.04) and abs(y0 + y1) <= max(2'f32, d.float32 * 0.04)
      check segs.len <= 2000

  test "an ellipse at its angle and roundness, and a soft tip's half point":
    var t = hardTip(100)
    t.roundness = 40
    let (x0, y0, x1, y1) = bounds(tipOutline(t))
    check x1 - x0 > 90 and y1 - y0 < 50
    t.angle = 90
    let (a0, b0, a1, b1) = bounds(tipOutline(t))
    check b1 - b0 > 90 and a1 - a0 < 50
    let soft = softTip(100)
    let half = bounds(tipOutline(soft))
    let all = bounds(tipOutline(soft, full = true))
    check half[2] - half[0] < all[2] - all[0] and all[2] - all[0] >= 90

  test "a sampled tip: its own shape, turned with it":
    # an L: its outline has the L's corner, nothing at the empty quarter
    var t = BrushTip(diameter: 80, hardness: 100, spacing: 25, roundness: 100, cw: 20, ch: 20)
    t.custom = newSeq[uint8](400)
    for y in 0 ..< 20:
      for x in 0 ..< 20:
        if x < 6 or y >= 14: t.custom[y * 20 + x] = 255
    proc inEmpty(segs: seq[array[4, float32]]; sx, sy: float32): bool =
      # (a piece well inside the empty quarter: x > 0, y < 0 for the upright L)
      for s in segs:
        let mx = (s[0] + s[2]) / 2
        let my = (s[1] + s[3]) / 2
        if mx * sx > 15 and my * sy < -15: return true
    let up = tipOutline(t)
    check up.len > 8 and not inEmpty(up, 1, 1)
    let (x0, y0, x1, y1) = bounds(up)
    check x1 - x0 > 70 and y1 - y0 > 70
    t.angle = 180
    check not inEmpty(tipOutline(t), -1, -1)

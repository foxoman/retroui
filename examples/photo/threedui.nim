# (included by photo.nim) Layer > Live Effects > 3D and Materials: a shape extruded (with a
# bevel), revolved round its left edge or inflated, turned, seen with perspective, lit and
# shaded -- live while the box is open, kept with the shape (change its outline: the 3D
# follows); None takes it off. The engine is `retroui/threed`.

var
  t3: tuple[open: bool; layer: Layer; t: ThreeD; shown: string]
  t3Pending = false

proc startThreeD() =
  let d = cur()
  if d == nil or not d.current.isShape:
    status = "3D and Materials: pick a shape layer first"
    return
  let L = d.current
  if te.on: commitType()
  var t = L.shape.threeD
  if t.kind == tdNone: t = defaultThreeD(tdExtrude)
  t3 = (true, L, t, "")
  t3Pending = true
  d.beginStep("3D and Materials")
  d.touchLayers()

proc threeDDialog() =
  if not t3.open:
    if t3Pending:
      # (closed from outside: as Cancel)
      t3Pending = false
      let d = cur()
      if d != nil and d.stepOpen: d.cancelStep()
    return
  let d = cur()
  if d == nil or t3.layer notin d.layers:
    t3.open = false
    return
  var ok, cancel = false
  dialog(t3.open, "3D and Materials", 460):
    var k = ord(t3.t.kind)
    var names: seq[string]
    for x in ThreeDKind: names.add tr($x)
    row([120, -1]):
      label "Type:"
      if combo(names, k, w = dp(200)):
        let was = t3.t
        t3.t = defaultThreeD(ThreeDKind(k))
        if was.kind != tdNone and t3.t.kind != tdNone:
          # (the turn and the light kept from before)
          t3.t.rx = was.rx; t3.t.ry = was.ry; t3.t.rz = was.rz; t3.t.perspective = was.perspective
          t3.t.lightAngle = was.lightAngle; t3.t.lightHeight = was.lightHeight
    template num(cap: string; v: untyped; lo, hi: int) =
      row([120, -1, 60]):
        label cap
        var i = int(round(v))
        if slider(i, lo, hi, ticks = 0): v = i.float
        if spin(i, lo, hi, w = dp(58)): v = i.float
    if t3.t.kind != tdNone:
      group("Object"):
        case t3.t.kind
        of tdExtrude:
          num("Depth:", t3.t.depth, 0, 1000)
          num("Bevel:", t3.t.bevel, 0, 200)
        of tdRevolve:
          num("Angle:", t3.t.angle, 1, 360)
          row([120, -1]):
            label "Faces round:"
            spin(t3.t.segments, 6, 180, w = dp(64))
        of tdInflate:
          num("Height:", t3.t.depth, 0, 500)
          row([120, -1]):
            label "Rings:"
            spin(t3.t.segments, 2, 24, w = dp(64))
        else: discard
      group("Rotation"):
        num("Across (X):", t3.t.rx, -180, 180)
        num("Up and down (Y):", t3.t.ry, -180, 180)
        num("Round (Z):", t3.t.rz, -180, 180)
        num("Perspective:", t3.t.perspective, 0, 160)
      group("Lighting"):
        num("Light from:", t3.t.lightAngle, 0, 359)
        num("Height:", t3.t.lightHeight, 0, 90)
        num("Intensity:", t3.t.intensity, 0, 200)
        num("Ambient:", t3.t.ambient, 0, 100)
        num("Highlight:", t3.t.highlight, 0, 100)
        row([120, -1]):
          label "Material:"
          combo(["Matte", "Shiny", "Flat colors"], t3.t.shading, w = dp(140))
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): cancel = true
  # (live: the shape takes the settings as they change)
  let key = $t3.t
  if key != t3.shown and (t3.open or ok):
    t3.shown = key
    var s = t3.layer.shape
    s.threeD = t3.t
    d.setShape(t3.layer, s)
  if ok:
    t3.open = false
    t3Pending = false
    if d.stepOpen: d.endStep()
    status = if t3.t.kind == tdNone: tr("3D taken off") else: tr("3D: ") & tr($t3.t.kind)
  elif cancel:
    t3.open = false
    t3Pending = false
    if d.stepOpen: d.cancelStep()

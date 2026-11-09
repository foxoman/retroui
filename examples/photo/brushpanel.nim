# (included by photo.nim) Brushes as today's editors have them: the Brushes
# palette (the size, then the presets in their folders, a stroke each),
# Brush Settings (Brush Tip Shape, Shape Dynamics, Scattering, Texture, Dual
# Brush, Color Dynamics, Transfer, Brush Pose, Noise, Wet Edges, Build-up,
# Smoothing, Protect Texture -- with a live stroke under them), the preset
# picker of the options bar, and the keys: [ and ] the size, Shift+[ and ]
# the hardness, , and . the brush before and after, Alt + the right button
# dragged across (size) and up and down (hardness).

type BrushSection = enum
  bsTip = "Brush Tip Shape", bsShape = "Shape Dynamics", bsScatter = "Scattering", bsTexture = "Texture",
  bsDual = "Dual Brush", bsColor = "Color Dynamics", bsTransfer = "Transfer", bsPose = "Brush Pose",
  bsNoise = "Noise", bsWet = "Wet Edges", bsBuildUp = "Build-up", bsSmoothing = "Smoothing",
  bsProtect = "Protect Texture"

var
  folded: seq[string]                       ## folders closed in the palette
  strokePrevs: Table[string, Bitmap]        ## the presets' strokes (by name, version, size)
  tipPrevs: Table[string, Bitmap]
  settingsPage = bsTip
  dynAside: array[Tool, BrushDynamics]      ## what a section switched off had
  protectTexture = false
  brushDrag: tuple[on: bool; x0, y0, size0, hard0: int]   ## Alt + the right button
  presetsVer = 0
  presetDlg: tuple[open: bool; kind: int; name: string; idx: int]   ## (new brush, new group, rename)
  livePrev: tuple[key: string; b: Bitmap]
  renameFrom = ""                           ## (Rename Group: the folder's old name)

proc presetsPath(): string = dataDir(AppName) / "Brushes.json"

proc loadPresets() =
  ## The presets kept from last time (the built-in ones the first time).
  try: presets = presetsFromJson(readFile(presetsPath()))
  except CatchableError: presets = defaultPresets()
  if presets.len == 0: presets = defaultPresets()
  inc presetsVer

proc savePresets() =
  inc presetsVer
  try: writeFile(presetsPath(), presetsToJson(presets))
  except CatchableError: status = "Could not keep the brushes: " & getCurrentExceptionMsg()

proc brushOwner(): Tool = (if tool in brushTools: tool else: tBrush)
  ## The tool whose brush the palettes show (the Paintbrush when the tool has none).

proc presetIndex(name: string): int =
  for i, p in presets:
    if p.name == name: return i
  -1

proc applyPreset(p: BrushPreset; t = brushOwner()) =
  ## The preset as the tool's brush: its tip, dynamics and settings.
  opts[t].tip = p.tip
  var dy = p.dyn
  if protectTexture:
    # (Protect Texture: the texture stays as it was)
    let o = opts[t].dyn
    dy.textureOn = o.textureOn
    dy.textureDepth = o.textureDepth
    dy.textureScale = o.textureScale
    dy.textureInvert = o.textureInvert
  opts[t].dyn = dy
  opts[t].wet = p.wet
  opts[t].sizeByPressure = p.sizeByPressure
  opts[t].opacityByPressure = p.opacityByPressure
  if p.opacity > 0: opts[t].opacity = p.opacity
  if p.smoothing > 0: brushSmoothing = p.smoothing
  opts[t].preset = p.name

proc presetOfTool(t: Tool; name = ""): BrushPreset =
  ## The tool's brush as a preset (New Brush Preset).
  BrushPreset(name: name, folder: "", tip: opts[t].tip, dyn: opts[t].dyn, wet: opts[t].wet,
              smoothing: brushSmoothing, sizeByPressure: opts[t].sizeByPressure,
              opacityByPressure: opts[t].opacityByPressure)

proc toBitmapOf(px: seq[uint32]; w, h: int): Bitmap =
  result = newBitmap(w, h)
  result.px = px
  result.changed()

proc inkPx(): uint32 =
  ## (what previews are drawn in: the text's color -- black, or light in a
  ## dark theme)
  rgbOf(ui.theme.text) or 0xFF000000'u32

proc tipBitmap(t: BrushTip; side: int): Bitmap =
  ## A tip's shape in the text's color on the window's (cached).
  let ink = inkPx()
  let key = $t.diameter & "/" & $t.hardness & "/" & $t.angle & "/" & $t.roundness & "/" & $t.cw & "x" & $t.ch &
            "/" & $(if t.custom.len > 0: hash(t.custom) else: 0) & "/" & $side & $t.flipX & $t.flipY & "/" & $ink
  result = tipPrevs.getOrDefault(key)
  if result != nil: return
  let a = tipPreview(t, side)
  var px = newSeq[uint32](side * side)
  for i, v in a: px[i] = (ink and 0xFFFFFF'u32) or (uint32(v) shl 24)
  result = toBitmapOf(px, side, side)
  if tipPrevs.len > 400: tipPrevs.clear()
  tipPrevs[key] = result

var strokesMade = 0      ## (strokes worked out this frame: a few a frame, the palette stays quick)

proc strokeBitmap(p: BrushPreset; w, h: int): Bitmap =
  ## The preset's stroke (cached; nil while it waits its turn).
  let key = p.name & "/" & $presetsVer & "/" & $w & "x" & $h & "/" & $inkPx() & "/" & $rgbOf(ui.theme.window)
  result = strokePrevs.getOrDefault(key)
  if result != nil: return
  if strokesMade >= 3:
    wakeIn(16)
    result = nil; return
  inc strokesMade
  result = toBitmapOf(strokePreview(p, w, h, inkPx(), rgbOf(ui.theme.window) or 0xFF000000'u32), w, h)
  if strokePrevs.len > 300: strokePrevs.clear()
  strokePrevs[key] = result

# ---- sizes ---------------------------------------------------------------------------------------

proc sizeToPos(s: int): int = int(round(ln(clamp(s, 1, MaxDiameter).float) / ln(MaxDiameter.float) * 1000))
proc posToSize(p: int): int = clamp(int(round(exp(p.float / 1000 * ln(MaxDiameter.float)))), 1, MaxDiameter)

proc setBrushSize(t: Tool; s: int) =
  opts[t].tip.diameter = clamp(s, 1, MaxDiameter)

proc stepSize(s: int; up: bool): int =
  ## [ and ]: the usual steps (1 under 10, then 10, 25, 50, 100).
  let st = if s < 10 or (not up and s <= 10): 1
           elif s < 100 or (not up and s <= 100): 10
           elif s < 200 or (not up and s <= 200): 25
           elif s < 300 or (not up and s <= 300): 50
           else: 100
  clamp(if up: s + st else: s - st, 1, MaxDiameter)

proc sizeRows(t: Tool) =
  ## The size (slider from 1 to 5000 pixels, the steps finer when small)
  ## and the hardness of a round tip.
  row([44, -1, 60]):
    var sz0 = opts[t].tip.diameter
    if scrubLabel("Size:", sz0, 1, MaxDiameter): setBrushSize(t, sz0)
    var pos = sizeToPos(opts[t].tip.diameter)
    if slider(pos, 0, 1000, ticks = 0): setBrushSize(t, posToSize(pos))
    var sz = opts[t].tip.diameter
    if intEdit(sz, w = dp(56), lo = 1, hi = MaxDiameter): setBrushSize(t, sz)
  if opts[t].tip.custom.len == 0:
    row([44, -1, 60]):
      label "Hard:"
      slider(opts[t].tip.hardness, 0, 100, ticks = 0)
      label $opts[t].tip.hardness & "%"

# ---- the list of presets ---------------------------------------------------------------------------

proc folderList(): seq[string] =
  for p in presets:
    if p.folder notin result: result.add p.folder

proc presetList(t: Tool; height: int; compact = false) =
  ## The presets in their folders: a folder's row opens or closes it; a
  ## brush's row (its tip, its name, its stroke) chooses it; a double click
  ## opens Brush Settings; a right click has the brush's menu.
  let rowH = if compact: max(ItemH, dp(22)) else: dp(38)
  beginPanel(height, "presets" & (if compact: "c" else: ""))
  let th = ui.theme
  for f in folderList():
    let open = f notin folded
    let fr = place(0, ItemH + dp(2), fill = true)
    let fh = interact(idOf("pfold:" & f & $compact), fr, focusable = false)
    arrow(fr.x + dp(6), fr.y + fr.h div 2, if open: dDown else: dRight, th.text, dp(4))
    image(fr.x + dp(14), fr.y + (fr.h - dp(16)) div 2, glyphIcon(if open: pxFolderOpen else: pxFolder, th.text, dp(16)))
    text(fr.x + dp(34), fr.y + (fr.h - FontH) div 2, f, th.text)
    if fh.clicked:
      if open: folded.add f else: folded.delete(folded.find(f))
    if fh.showsHover and ui.rpressed:
      presetDlg = (false, 0, f, -1)
      openPopupMenu("pfoldmenu", ui.mx, ui.my)
    if not open: continue
    for i, p in presets:
      if p.folder != f: continue
      let r = place(0, rowH, fill = true)
      let ph = interact(idOf("preset:" & $i & $compact), r, focusable = false)
      let chosen = opts[t].preset == p.name
      if chosen: fill(r, th.select)
      elif ph.showsHover: fill(r, hoverColor())
      let tc = if chosen: th.selectText else: th.text
      let ts = if compact: dp(20) else: dp(30)
      let tr = rect(r.x + dp(18), r.y + (r.h - ts) div 2, ts, ts)
      fill(tr, th.window)
      drawBitmap(tr, tipBitmap(p.tip, ts))
      let tx = tr.x + ts + dp(6)
      if compact:
        text(tx, r.y + (r.h - FontH) div 2, p.name, tc)
        let sz = $p.tip.diameter
        text(r.x + r.w - textWidth(sz) - dp(4), r.y + (r.h - FontH) div 2, sz, tc)
      else:
        text(tx, r.y + dp(2), ellipsize(p.name, max(dp(20), r.w - (tx - r.x) - dp(40))), tc)
        let sz = $p.tip.diameter
        text(r.x + r.w - textWidth(sz) - dp(4), r.y + dp(2), sz, tc)
        let sw = max(dp(20), r.w - (tx - r.x) - dp(4))
        let sh = r.h - FontH - dp(4)
        let sr = rect(tx, r.y + FontH + dp(2), sw, sh)
        let b = strokeBitmap(p, sw * pxScale, sh * pxScale)
        if b != nil: drawBitmap(sr, b)
      if ph.down and ui.pressed:
        applyPreset(p, t)
        if ui.clicks >= 2:
          showPanel("brushsettings")
          palettesHidden = false
      if ph.showsHover and ui.rpressed:
        applyPreset(p, t)
        presetDlg = (false, 0, p.name, i)
        openPopupMenu("presetmenu", ui.mx, ui.my)
  endPanel()
  popupMenu("presetmenu"):
    let i = presetDlg.idx
    if menuItem("&Rename Brush...", enabled = i in 0 .. presets.high):
      presetDlg = (true, 2, presets[i].name, i)
    if menuItem("&Duplicate Brush", enabled = i in 0 .. presets.high):
      var p = presets[i]
      p.name = p.name & " Copy"
      presets.insert(p, i + 1)
      savePresets()
    if menuItem("D&elete Brush", enabled = i in 0 .. presets.high and presets.len > 1):
      presets.delete(i)
      savePresets()
  popupMenu("pfoldmenu"):
    let f = presetDlg.name
    if menuItem("&Rename Group..."):
      presetDlg = (true, 3, f, -1)
      renameFrom = f
    if menuItem("&Delete Group", enabled = folderList().len > 1):
      var keep: seq[BrushPreset]
      for p in presets:
        if p.folder != f: keep.add p
      if keep.len > 0:
        presets = keep
        savePresets()

proc presetDialog() =
  ## New Brush Preset, New Group, Rename.
  if not presetDlg.open: return
  let titles = ["New Brush Preset", "New Brush Group", "Rename Brush", "Rename Group"]
  dialog(presetDlg.open, titles[clamp(presetDlg.kind, 0, 3)], 340):
    form 0:
      field "Name:": edit(presetDlg.name)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)) and presetDlg.name.strip.len > 0:
        let n = presetDlg.name.strip
        let t = brushOwner()
        case presetDlg.kind
        of 0:
          var p = presetOfTool(t, n)
          let at = presetIndex(opts[t].preset)
          p.folder = if at >= 0: presets[at].folder else: presetFolders[0]
          presets.insert(p, if at >= 0: at + 1 else: presets.len)
          opts[t].preset = n
        of 1:
          var p = presetOfTool(t, opts[t].tip.name & " " & $opts[t].tip.diameter)
          if p.name.strip.len == 0: p.name = "Brush " & $opts[t].tip.diameter
          p.folder = n
          presets.add p
        of 2:
          if presetDlg.idx in 0 .. presets.high:
            for k in Tool:
              if opts[k].preset == presets[presetDlg.idx].name: opts[k].preset = n
            presets[presetDlg.idx].name = n
        else:
          for p in presets.mitems:
            if p.folder == renameFrom: p.folder = n
          let fi = folded.find(renameFrom)
          if fi >= 0: folded[fi] = n
        savePresets()
        presetDlg.open = false
      if button("Cancel", w = dp(80)): presetDlg.open = false


# ---- the Brushes palette ---------------------------------------------------------------------------

proc brushesBody() =
  let t = brushOwner()
  sizeRows(t)
  space(dp(2))
  let barH = CtrlH + dp(2)
  presetList(t, max(dp(60), remainingH() - barH - dp(4)))
  row:
    if toolButton(glyphIcon(pxBrush, ui.theme.text, dp(16)), "Brush Settings (F5)", down = panelShown("brushsettings")):
      togglePanel("brushsettings")
      palettesHidden = false
    if toolButton(glyphIcon(pxFolder, ui.theme.text, dp(16)), "New Group"):
      presetDlg = (true, 1, "New Group", -1)
    if toolButton(glyphIcon(pxNew, ui.theme.text, dp(16)), "New Brush Preset (the brush as it is now)"):
      presetDlg = (true, 0, opts[t].tip.name & (if opts[t].tip.name.len > 0: " " else: "Brush ") &
                   $opts[t].tip.diameter, -1)
    if toolButton(glyphIcon(pxTrash, ui.theme.text, dp(16)), "Delete the Brush",
                  enabled = presets.len > 1 and presetIndex(opts[t].preset) >= 0):
      presets.delete(presetIndex(opts[t].preset))
      savePresets()
  if t != tool:
    label("(the Paintbrush's)", color = ui.theme.gray)

# ---- Brush Settings --------------------------------------------------------------------------------

proc sectionOn(t: Tool; s: BrushSection): bool =
  let d = opts[t].dyn
  case s
  of bsTip: true
  of bsShape: d.sizeJitter > 0 or d.angleJitter > 0 or d.roundJitter > 0 or d.sizeControl != dcOff or
              d.angleControl != anOff or d.flipXJitter or d.flipYJitter
  of bsScatter: d.scatter > 0 or d.count > 1 or d.countJitter > 0
  of bsTexture: d.textureOn
  of bsDual: d.dualBrush > 0
  of bsColor: d.fgBgJitter > 0 or d.hueJitter > 0 or d.satJitter > 0 or d.brightJitter > 0 or d.purity != 0
  of bsTransfer: d.opacityJitter > 0 or (d.flow > 0 and d.flow < 100) or d.flowJitter > 0 or
                 d.opacityControl != dcOff or d.flowControl != dcOff or opts[t].opacityByPressure
  of bsPose: d.pose
  of bsNoise: d.noise
  of bsWet: opts[t].wet
  of bsBuildUp: d.buildUp
  of bsSmoothing: brushSmoothing > 0
  of bsProtect: protectTexture

proc setSection(t: Tool; s: BrushSection; on: bool) =
  ## A section switched on (what it had before back) or off (kept aside).
  template d: untyped = opts[t].dyn
  template a: untyped = dynAside[t]
  template swap2(field: untyped) =
    if on: d.field = a.field
    else:
      a.field = d.field
      d.field = default(typeof(d.field))
  case s
  of bsTip: discard
  of bsShape:
    swap2(sizeJitter); swap2(minDiameter); swap2(angleJitter); swap2(roundJitter); swap2(sizeControl)
    swap2(sizeFade); swap2(angleControl); swap2(flipXJitter); swap2(flipYJitter)
    if on and not sectionOn(t, bsShape): d.sizeControl = dcPressure
  of bsScatter:
    swap2(scatter); swap2(scatterBoth); swap2(count); swap2(countJitter)
    if on and not sectionOn(t, bsScatter): d.scatter = 100
  of bsTexture:
    d.textureOn = on and pattern.len > 0
    if on and pattern.len == 0: status = "Define a pattern first (Edit > Define Pattern)"
  of bsDual:
    swap2(dualBrush); swap2(dualScatter)
    if on and d.dualBrush == 0: d.dualBrush = 1
  of bsColor:
    swap2(fgBgJitter); swap2(hueJitter); swap2(satJitter); swap2(brightJitter); swap2(purity)
    if on and not sectionOn(t, bsColor): d.fgBgJitter = 50
  of bsTransfer:
    swap2(opacityJitter); swap2(flow); swap2(flowJitter); swap2(opacityControl); swap2(flowControl)
    swap2(opacityFade); swap2(flowFade)
    if on and not sectionOn(t, bsTransfer): d.opacityControl = dcPressure
    if not on: opts[t].opacityByPressure = false
  of bsPose:
    d.pose = on
    if on and d.posePressure == 0: d.posePressure = 100
  of bsNoise: d.noise = on
  of bsWet: opts[t].wet = on
  of bsBuildUp: d.buildUp = on
  of bsSmoothing: brushSmoothing = if on: max(brushSmoothing, 40) else: 0
  of bsProtect: protectTexture = on
  opts[t].preset = ""

proc setRow(lab: string; v: var int; lo, hi: int; unit = "%"): bool {.discardable.} =
  row([92, -1, 46]):
    label lab
    result = slider(v, lo, hi, ticks = 0)
    label $v & unit

proc controlRow(lab: string; c: var DynControl; fade: var int) =
  row:
    label lab
    var k = ord(c)
    if combo(["Off", "Fade", "Pen Pressure", "Pen Tilt"], k, w = dp(110)): c = DynControl(k)
    if c == dcFade:
      if fade <= 0: fade = 25
      spin(fade, 1, 9999, w = dp(60))

proc angleWidget(t: Tool) =
  ## Angle and roundness: drag the arrow round (angle), the dots in and out
  ## (roundness), as the usual has it.
  let r = place(dp(70), dp(70))
  let th = ui.theme
  fill(r, th.window)
  box(r, th.frame)
  let cx = r.x + r.w div 2
  let cy = r.y + r.h div 2
  let rad = r.w div 2 - dp(6)
  let a = degToRad(opts[t].tip.angle.float)
  let rnd = clamp(opts[t].tip.roundness, 1, 100).float / 100
  # the ellipse
  var px, py = 0
  for k in 0 .. 48:
    let u = k.float / 48 * 2 * PI
    let ex = cos(u) * rad.float
    let ey = sin(u) * rad.float * rnd
    let x = cx + int(round(ex * cos(a) + ey * sin(a)))
    let y = cy + int(round(-ex * sin(a) + ey * cos(a)))
    if k > 0: line(px, py, x, y, th.text)
    px = x
    py = y
  # the arrow (angle)
  let ax = cx + int(round(cos(a) * rad.float))
  let ay = cy - int(round(sin(a) * rad.float))
  line(cx, cy, ax, ay, th.text)
  fill(rect(ax - 2, ay - 2, 5, 5), th.text)
  let hit = interact(idOf("anglewidget"), r, focusable = false)
  if ui.active == idOf("anglewidget") and ui.mouseDown:
    let dx = (ui.mx - cx).float
    let dy = (cy - ui.my).float
    let d = sqrt(dx * dx + dy * dy)
    if hit.down and ui.pressed:
      var st = state(idOf("anglewidget"))
      st.aux = ord(d < rad.float * 0.6)        # (pressed inside: roundness; at the rim: the angle)
      state(idOf("anglewidget")) = st
    if state(idOf("anglewidget")).aux == 1:
      # the roundness: how far across the ellipse's narrow axis the mouse is
      let across = abs(-dx * sin(a) + dy * cos(a))
      opts[t].tip.roundness = clamp(int(round(across / rad.float * 100)), 1, 100)
    else:
      opts[t].tip.angle = int(round(radToDeg(arctan2(dy, dx))))
    opts[t].preset = ""

proc tipPage(t: Tool) =
  ## Brush Tip Shape: the tips of the presets to choose from, then the size,
  ## flips, angle, roundness, hardness and spacing.
  var tips: seq[BrushTip]
  var seen: seq[string]
  for p in presets:
    let k = $p.tip.custom.len & "/" & $p.tip.hardness & "/" & $p.tip.roundness & "/" & $p.tip.angle &
            "/" & $(if p.tip.custom.len > 0: hash(p.tip.custom) else: 0)
    if k in seen: continue
    seen.add k
    tips.add p.tip
    if tips.len >= 24: break
  let cell = dp(30)
  let cols = max(1, available() div cell)
  let gr = place(cols * cell + 1, ((tips.len + cols - 1) div cols) * cell + 1)
  fill(gr, ui.theme.window)
  let gh = interact(idOf("tipgrid"), gr, focusable = false)
  for i, tp in tips:
    let cr = rect(gr.x + (i mod cols) * cell, gr.y + (i div cols) * cell, cell + 1, cell + 1)
    box(cr, ui.theme.face)
    drawBitmap(inset(cr, dp(3)), tipBitmap(tp, cell - dp(6)))
    let cur = opts[t].tip
    if tp.custom == cur.custom and tp.hardness == cur.hardness and tp.roundness == cur.roundness:
      box(inset(cr, 1), ui.theme.text)
    if gh.down and ui.pressed and mouseIn(cr):
      let size = opts[t].tip.diameter
      opts[t].tip = tp
      opts[t].tip.diameter = size
      opts[t].preset = ""
  row([44, -1, 60]):
    label "Size:"
    var pos = sizeToPos(opts[t].tip.diameter)
    if slider(pos, 0, 1000, ticks = 0): setBrushSize(t, posToSize(pos))
    var sz = opts[t].tip.diameter
    if intEdit(sz, w = dp(56), lo = 1, hi = MaxDiameter): setBrushSize(t, sz)
  row:
    checkbox("Flip X", opts[t].tip.flipX)
    checkbox("Flip Y", opts[t].tip.flipY)
  row:
    angleWidget(t)
    col:
      setRow("Angle:", opts[t].tip.angle, -180, 180, "°")
      setRow("Roundness:", opts[t].tip.roundness, 1, 100)
      if opts[t].tip.custom.len == 0: setRow("Hardness:", opts[t].tip.hardness, 0, 100)
  row([92, -1, 46]):
    var sp = opts[t].tip.spacing > 0
    if checkbox("Spacing:", sp): opts[t].tip.spacing = (if sp: 25 else: 0)
    var v = max(1, opts[t].tip.spacing)
    if slider(v, 1, 1000, ticks = 0, enabled = sp): opts[t].tip.spacing = v
    label $opts[t].tip.spacing & "%"

proc settingsPageBody(t: Tool; s: BrushSection) =
  template d: untyped = opts[t].dyn
  case s
  of bsTip: tipPage(t)
  of bsShape:
    setRow("Size Jitter:", d.sizeJitter, 0, 100)
    controlRow("Control:", d.sizeControl, d.sizeFade)
    setRow("Minimum:", d.minDiameter, 0, 100)
    setRow("Angle Jitter:", d.angleJitter, 0, 100)
    row:
      label "Control:"
      var k = ord(d.angleControl)
      if combo(["Off", "Direction", "Initial Direction", "Pen Tilt", "Rotation"], k, w = dp(130)):
        d.angleControl = AngleControl(k)
    setRow("Round Jitter:", d.roundJitter, 0, 100)
    checkbox("Roundness Control: Pen Tilt", d.roundTilt)
    label(if ui.pen: "Pen: pressure " & $int(round(ui.pressure * 100)) & "%, tilt " &
            $int(round(ui.tilt * 90)) & "°, " & $int(round(radToDeg(ui.azimuth))) & "°"
          else: "(a pen's pressure, tilt and rotation: when one is used)", color = ui.theme.gray)
    row:
      checkbox("Flip X Jitter", d.flipXJitter)
      checkbox("Flip Y Jitter", d.flipYJitter)
  of bsScatter:
    setRow("Scatter:", d.scatter, 0, 1000)
    checkbox("Both Axes", d.scatterBoth)
    var c = max(1, d.count)
    if setRow("Count:", c, 1, 16, ""): d.count = c
    setRow("Count Jitter:", d.countJitter, 0, 100)
  of bsTexture:
    if pattern.len == 0:
      paragraph("Make a pattern first: select a part of a picture, then Edit > Define Pattern.",
                color = ui.theme.gray)
    checkbox("Use the Pattern as Texture", d.textureOn, enabled = pattern.len > 0)
    checkbox("Invert", d.textureInvert)
    var sc = if d.textureScale <= 0: 100 else: d.textureScale
    if setRow("Scale:", sc, 10, 400): d.textureScale = sc
    var dd = if d.textureDepth <= 0: 100 else: d.textureDepth
    if setRow("Depth:", dd, 1, 100): d.textureDepth = dd
  of bsDual:
    var names = @["None"]
    for p in presets: names.add p.name
    var k = clamp(d.dualBrush, 0, names.high)
    row:
      label "Brush:"
      if combo(names, k, w = dp(170)): d.dualBrush = k
    setRow("Scatter:", d.dualScatter, 0, 400)
  of bsColor:
    setRow("Fg/Bg Jitter:", d.fgBgJitter, 0, 100)
    setRow("Hue Jitter:", d.hueJitter, 0, 100)
    setRow("Saturation:", d.satJitter, 0, 100)
    setRow("Brightness:", d.brightJitter, 0, 100)
    setRow("Purity:", d.purity, -100, 100)
  of bsTransfer:
    setRow("Opacity Jitter:", d.opacityJitter, 0, 100)
    controlRow("Control:", d.opacityControl, d.opacityFade)
    var f = if d.flow <= 0: 100 else: d.flow
    if setRow("Flow:", f, 1, 100): d.flow = f
    setRow("Flow Jitter:", d.flowJitter, 0, 100)
    controlRow("Control:", d.flowControl, d.flowFade)
  of bsPose:
    checkbox("Override the Pen (the values below)", d.pose)
    setRow("Tilt X:", d.tiltX, -100, 100, "")
    setRow("Tilt Y:", d.tiltY, -100, 100, "")
    setRow("Rotation:", d.rotation, 0, 360, "°")
    var pr = if d.posePressure <= 0: 100 else: d.posePressure
    if setRow("Pressure:", pr, 1, 100): d.posePressure = pr
  of bsNoise: paragraph("Grain in the soft edges of the dabs.", color = ui.theme.gray)
  of bsWet: paragraph("The paint gathers at the edges of the stroke, as watercolor does.", color = ui.theme.gray)
  of bsBuildUp: paragraph("Paint keeps coming while the brush is held still, as an airbrush's.",
                          color = ui.theme.gray)
  of bsSmoothing:
    setRow("Smoothing:", brushSmoothing, 0, 100)
  of bsProtect: paragraph("The texture stays as it is when another brush is chosen.", color = ui.theme.gray)

proc livePreview(t: Tool; w, h: int): Bitmap =
  ## The brush as it is now, painted across (Brush Settings' bottom).
  let p = presetOfTool(t)
  let key = $p.tip.diameter & $p.tip.hardness & $p.tip.angle & $p.tip.roundness & $p.tip.spacing &
            $p.tip.flipX & $p.tip.flipY & $p.tip.custom.len & $p.dyn & $p.wet & $fg & $w & "x" & $h
  if livePrev.b != nil and livePrev.key == key: return livePrev.b
  livePrev = (key, toBitmapOf(strokePreview(p, w, h, fg or 0xFF000000'u32,
                                            rgbOf(ui.theme.window) or 0xFF000000'u32), w, h))
  livePrev.b

proc brushSettingsBody() =
  let t = brushOwner()
  let th = ui.theme
  row([118, -1]):
    col:
      for s in BrushSection:
        let r = place(0, ItemH + dp(1), fill = true)
        let h = interact(idOf("bsec:" & $s), r, focusable = false)
        let chosen = settingsPage == s
        if chosen: fill(r, th.select)
        var on = sectionOn(t, s)
        let tc = if chosen: th.selectText else: th.text
        if s != bsTip:
          let cb = rect(r.x + dp(2), r.y + (r.h - dp(11)) div 2, dp(11), dp(11))
          fill(cb, th.window)
          box(cb, th.frame)
          if on:
            line(cb.x + 2, cb.y + 5, cb.x + 4, cb.y + 8, th.text)
            line(cb.x + 4, cb.y + 8, cb.x + 8, cb.y + 2, th.text)
          if h.clicked and mouseIn(cb):
            setSection(t, s, not on)
          elif h.clicked:
            settingsPage = s
        elif h.clicked: settingsPage = s
        text(r.x + dp(16), r.y + (r.h - FontH) div 2, $s, tc)
    col:
      settingsPageBody(t, settingsPage)
  # the stroke as the brush is now
  let r = place(0, dp(52), fill = true)
  fill(r, th.window)
  box(r, th.frame)
  drawBitmap(inset(r, 1), livePreview(t, (r.w - 2) * pxScale, (r.h - 2) * pxScale))
  row:
    if button("New Brush Preset...", w = dp(140)):
      presetDlg = (true, 0, (if opts[t].preset.len > 0: opts[t].preset & " 2" else: "Brush " & $opts[t].tip.diameter), -1)
    if t != tool: label("(the Paintbrush's)", color = ui.theme.gray)

# ---- the options bar's brush picker ---------------------------------------------------------------

proc brushPicker(t: Tool) =
  ## The brush in the options bar: its tip and size; a click drops down the
  ## size, the hardness and the presets.
  let pid = idOf("brushpicker")
  let tipIc = tipBitmap(opts[t].tip, dp(16))
  let cap = $opts[t].tip.diameter
  let r = place(dp(16) + textWidth(cap) + SbW + dp(14), EditH)
  let hit = interact(pid + 1, r, focusable = false)
  buttonFace(r, ui.popup == pid, rounded = false, bevel = 1, hot = hit.showsHover)
  fill(rect(r.x + dp(3), r.y + (r.h - dp(16)) div 2, dp(16), dp(16)), ui.theme.window)
  drawBitmap(rect(r.x + dp(3), r.y + (r.h - dp(16)) div 2, dp(16), dp(16)), tipIc)
  text(r.x + dp(22), r.y + (r.h - FontH) div 2, cap, ui.theme.text)
  arrow(r.x + r.w - SbW div 2 - dp(2), r.y + r.h div 2 - 1, dDown, ui.theme.frame)
  tooltip("The brush: its size, hardness and the presets")
  if hit.down and ui.pressed:
    ui.popup = if ui.popup == pid: 0 else: pid
    ui.menuOpen = false
    ui.redraw = true
  if ui.popup == pid:
    let pw = dp(280)
    let ph = min(dp(380), ui.h - r.y - r.h - dp(8))
    var pr = rect(r.x, r.y + r.h + 1, pw, max(dp(160), ph))
    if pr.x + pr.w > ui.w: pr.x = max(0, ui.w - pr.w)
    pushLayer(LayerPopup)
    ui.popupRectNow = pr
    fill(pr, ui.theme.face)
    box(pr, ui.theme.frame)
    pushFrame(inset(pr, Pad))
    sizeRows(t)
    presetList(t, max(dp(80), pr.h - 2 * Pad - 2 * (CtrlH + Gap) - dp(4)), compact = true)
    discard popFrame()
    popLayer()
    if keyHit(KeyEsc) or keyHit(KeyEnter): ui.popup = 0

# ---- keys and Alt + the right button ----------------------------------------------------------------

proc brushKeys() =
  ## [ ] the size, Shift: the hardness; , . the presets before and after;
  ## F5 Brush Settings.
  if ui.keyUsed or not canInput() or ui.takesText: return      # (not while a box is typed in)
  let t = brushOwner()
  let shift = ShiftPressed in ui.mods
  case ui.key
  of KeyLeftBracket, KeyRightBracket:
    let up = ui.key == KeyRightBracket
    if tool == tWand and wandMode in {1, 3}:
      # (the Quick Selection's and Selection Brush's own size; Shift: the hardness)
      if shift and wandMode == 3: selBrushHard = clamp(selBrushHard + (if up: 25 else: -25), 0, 100)
      else: quickSize = clamp(stepSize(quickSize, up), 1, 1000)
    elif shift:
      opts[t].tip.hardness = clamp(opts[t].tip.hardness + (if up: 25 else: -25), 0, 100)
    else: setBrushSize(t, stepSize(opts[t].tip.diameter, up))
    ui.keyUsed = true
  of KeyComma, KeyPeriod:
    if presets.len > 0:
      var i = presetIndex(opts[t].preset)
      i = if i < 0: 0 elif ui.key == KeyPeriod: (i + 1) mod presets.len else: (i + presets.len - 1) mod presets.len
      if shift: i = (if ui.key == KeyPeriod: presets.high else: 0)
      applyPreset(presets[i], t)
      status = "Brush: " & presets[i].name
    ui.keyUsed = true
  of KeyF5:
    togglePanel("brushsettings")
    palettesHidden = false
    ui.keyUsed = true
  else: discard

proc brushDragOn(dw: DocWin; ev: PhotoEvent): bool =
  ## Alt + the right button held on the image: across sizes the brush, up
  ## and down its hardness, the dab shown in red (true while it goes on).
  if tool notin brushTools: return false
  let t = tool
  if not brushDrag.on:
    if ev.over and ev.right and AltPressed in ui.mods:
      brushDrag = (true, ui.mx, ui.my, opts[t].tip.diameter, opts[t].tip.hardness)
      return true
    return false
  if not ui.rmouseDown:
    brushDrag.on = false
    return false
  let dx = ui.mx - brushDrag.x0
  let dy = ui.my - brushDrag.y0
  let k = dw.view.scaleOf / pxScale.float
  setBrushSize(t, clamp(int(round(brushDrag.size0.float + dx.float * 2 / max(0.01, k))), 1, MaxDiameter))
  if opts[t].tip.custom.len == 0:
    opts[t].tip.hardness = clamp(brushDrag.hard0 - dy, 0, 100)
  # the dab in red where the drag began
  let tip = opts[t].tip
  let side = clamp(int(tip.diameter.float * k), 4, max(ui.w, ui.h))
  let m = tipMask(tip, side.float / max(1, tip.diameter).float)
  let w = min(m.fullW, 1200)
  let h = min(m.fullH, 1200)
  var px = newSeq[uint32](w * h)
  for y in 0 ..< h:
    for x in 0 ..< w: px[y * w + x] = argb(int(m.maskAt(x, y) * 160), 255, 0, 0)
  drawBitmap(rect(brushDrag.x0 - w div 2, brushDrag.y0 - h div 2, w, h), toBitmapOf(px, w, h))
  text(brushDrag.x0 + w div 2 + dp(6), brushDrag.y0 - FontH,
       $tip.diameter & " px" & (if tip.custom.len == 0: ", " & $tip.hardness & "%" else: ""), color(255, 0, 0))
  ui.cursor = curCrosshair
  true

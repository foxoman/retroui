# (included by photo.nim) Layer > Path Operations > Apply Brush to Path (retroui/pathbrush), as
# a drawing program's Brushes panel puts a brush on a path: the shape's outline (or the work
# path) drawn with artwork instead of a plain stroke -- Art stretched along it, a Pattern of
# copies, copies Scattered -- in the stroke's color, as a new shape layer over it (the path's own
# layer hidden, to apply another brush later). The brushes it comes with, or the artwork of the
# other shape picked with it (Shift+click: its outline is the brush). Live; Cancel takes it back.

var
  pbDlg: tuple[open: bool; src: Layer; brush, kind, width, spacing: int; flip: bool; made: Layer; art: Path;
               path: Path; color: uint32]    ## (`path`, `color`: what it goes along, as it was opened)
  pbApplied = ""
  pbPending = false
  pbBrushWas = 0                        ## (the brush last set: another picked takes its own type)

proc pbPath(d: Doc): tuple[path: Path; color: uint32; layer: Layer] =
  ## (what the brush goes along: the current shape's outline, else the path shown)
  let L = d.current
  if L.isShape and not L.isFill:
    let s = L.shape
    let c = if s.stroke.kind == spColor and s.strokeWidth > 0: s.stroke.color
            elif s.fill.kind == spColor: s.fill.color
            else: fg or 0xFF000000'u32
    return (s.path, c, L)
  if d.curPath >= 0 and d.curPath < d.paths.len: return (d.paths[d.curPath], fg or 0xFF000000'u32, nil)

proc startPathBrush() =
  let d = cur()
  if d == nil: return
  let (p, c, L) = d.pbPath
  if p.subs.len == 0:
    status = "Apply Brush to Path: pick a shape (or show a path in Paths) first."
    return
  # (another shape picked with it: its outline a brush of its own)
  var art: Path
  for M in d.layers:
    if M.picked and M != L and M.isShape and M.shape.path.subs.len > 0: art = M.shape.path
  let first = if art.subs.len > 0: BuiltinBrushes.len else: 0
  let w = if L != nil and L.shape.strokeWidth > 0: int(max(4.0, L.shape.strokeWidth * 3)) else: 16
  let b = if first < BuiltinBrushes.len: builtinBrush(BuiltinBrushes[first]) else: PathBrush(kind: pbArt)
  pbDlg = (true, L, first, ord(b.kind), w, int(b.spacing * 100), false, nil, art, p, c)
  pbApplied = ""
  pbBrushWas = first
  pbPending = true
  d.beginStep("Apply Brush to Path")
  d.touchLayers()

proc pbBrush(): PathBrush =
  if pbDlg.brush >= BuiltinBrushes.len:
    result = PathBrush(art: pbDlg.art)
  else:
    result = builtinBrush(BuiltinBrushes[pbDlg.brush])
  result.kind = PathBrushKind(pbDlg.kind)
  result.width = pbDlg.width.float
  result.spacing = pbDlg.spacing / 100
  result.flip = pbDlg.flip

proc pbApply(d: Doc) =
  ## (the brushed outline made again, as the box says: along the path it was opened with -- the
  ## layer made is the current one after the first time)
  let (p, c, L) = (pbDlg.path, pbDlg.color, pbDlg.src)
  let r = brushedPath(p, pbBrush())
  let s = ShapeData(path: r, fill: solidPaint(c), stroke: ShapePaint(kind: spNone, color: c, color2: c, opacity: 100))
  if pbDlg.made == nil or pbDlg.made notin d.layers:
    let at = if L != nil: d.layers.find(L) else: -1
    pbDlg.made = d.addShapeLayer(s, (if L != nil: L.name & " (brushed)" else: "Brushed Path"), above = at)
    if L != nil:
      d.cur = d.layers.find(L)
      L.visible = false
      d.cur = d.layers.find(pbDlg.made)
    d.markAll()
  else: d.setShape(pbDlg.made, s)

proc pathBrushCommand(name: string): bool =
  result = true
  case name
  of "Apply Brush to Path...": startPathBrush()
  else: result = false

proc pathBrushDialog() =
  let d = cur()
  if not pbDlg.open:
    if pbPending:
      # (closed from outside: as Cancel)
      pbPending = false
      if d != nil and d.stepOpen:
        d.cancelStep()
        d.markAll()
    return
  if d == nil:
    pbDlg.open = false
    return
  var ok, cancel = false
  dialog(pbDlg.open, "Apply Brush to Path", 420):
    row([110, -1]):
      label "Brush:"
      var names: seq[string]
      for n in BuiltinBrushes: names.add tr(n)
      if pbDlg.art.subs.len > 0: names.add tr("The other shape picked")
      combo(names, pbDlg.brush, w = dp(220))
    row([110, -1]):
      label "Type:"
      var kinds: seq[string]
      for k in PathBrushKind: kinds.add tr($k)
      combo(kinds, pbDlg.kind, w = dp(160))
    row([110, 90, -1]):
      label "Width:"
      spin(pbDlg.width, 1, 2000, w = dp(80))
      label "px"
    if pbDlg.kind != ord(pbArt):
      row([110, 90, -1]):
        label "Spacing:"
        spin(pbDlg.spacing, -90, 1000, w = dp(80))
        label "%"
    checkbox("Flip Across", pbDlg.flip)
    paragraph(case PathBrushKind(pbDlg.kind)
              of pbArt: "Art: the artwork stretched along the whole path, bent with it."
              of pbPattern: "Pattern: copies one after another along the path, each bent with it."
              of pbScatter: "Scatter: copies set along the path, turned with it, not bent.", color = ui.theme.gray)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): cancel = true
  if pbDlg.brush != pbBrushWas and pbDlg.brush < BuiltinBrushes.len:
    # (a brush picked: its own way along the path, its own spacing)
    let b = builtinBrush(BuiltinBrushes[pbDlg.brush])
    pbDlg.kind = ord(b.kind)
    pbDlg.spacing = int(b.spacing * 100)
  pbBrushWas = pbDlg.brush
  let key = $(pbDlg.brush, pbDlg.kind, pbDlg.width, pbDlg.spacing, pbDlg.flip)
  if key != pbApplied and not cancel:
    pbApplied = key
    d.pbApply()
  if ok:
    pbDlg.open = false
    pbPending = false
    if d.stepOpen: d.endStep()
    status = "Brushed: \"" & pbDlg.made.name & "\" (the path's own layer hidden)"
  elif cancel:
    pbDlg.open = false
    pbPending = false
    if d.stepOpen:
      d.cancelStep()
      d.markAll()

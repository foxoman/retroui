# (included by photo.nim) Image > Image Trace: the current layer (or the
# picture as it shows) made vector shapes with retroui/imagetrace -- a
# preset or settings of your own, a preview that follows them, then shape
# layers in a group (the picture hidden under them), or an SVG file.

var
  itDlg = false
  itOpts = tracePreset(tp6Colors)
  itPresetI = ord(tp6Colors)
  itPreview: Bitmap
  itKey = ""
  itSrc: tuple[px: seq[uint32]; w, h: int]       ## (what is traced: kept while the dialog is open)
  itSmall: tuple[px: seq[uint32]; w, h: int]     ## (... smaller, for the preview)
  itInfo = ""
  itCover = 0.0                                  ## (the pixels the preview's shapes cover, at full size)
  itSvgPick = false
  itSvgPath = ""

proc itSource(d: Doc): tuple[px: seq[uint32]; w, h: int] =
  ## (the current layer's pixels when it has some of its own, else the picture as it shows)
  let L = d.current
  if not L.group and not L.isText and not L.isShape and L.adjust.kind.len == 0 and L.px.len == d.w * d.h and
     d.contentBounds(L).w > 0:
    return (L.px, d.w, d.h)
  let b = d.toBitmap(0'u32)
  (b.px, b.w, b.h)

proc startImageTrace() =
  let d = cur()
  if d == nil: return
  itSrc = itSource(d)
  # (the preview from a copy at most 420 pixels across)
  let k = min(1.0, 420 / max(itSrc.w, itSrc.h).float)
  let sw = max(1, int(itSrc.w.float * k))
  let sh = max(1, int(itSrc.h.float * k))
  var small = newSeq[uint32](sw * sh)
  for y in 0 ..< sh:
    let sy = min(itSrc.h - 1, int((y.float + 0.5) / k))
    for x in 0 ..< sw: small[y * sw + x] = itSrc.px[sy * itSrc.w + min(itSrc.w - 1, int((x.float + 0.5) / k))]
  itSmall = (small, sw, sh)
  itKey = ""
  itDlg = true

proc itMegabytes(): int =
  ## (what the shape layers will take: a layer takes memory where it draws -- its box)
  int(itCover * 4 / 1_000_000 + 0.5)

proc itPreviewNow() =
  let key = $itOpts
  if key == itKey: return
  itKey = key
  var o = itOpts
  # (the preview is traced small: noise in its pixels)
  let k = itSmall.w / max(1, itSrc.w)
  o.noise = max(1, int(o.noise.float * k * k + 0.5))
  let r = traceImage(itSmall.px, itSmall.w, itSmall.h, o)
  let pd = newDoc(itSmall.w, itSmall.h, 0xFFFFFFFF'u32)
  itCover = 0
  for s in r.shapes:
    discard pd.addShapeLayer(ShapeData(path: s.path, fill: solidPaint(s.color)))
    let (x0, y0, x1, y1) = pathBounds(s.path)
    itCover += max(0.0, x1 - x0) * max(0.0, y1 - y0) / (k * k)
  itPreview = pd.toBitmap(0xFFFFFFFF'u32)
  itInfo = $r.shapes.len & (if r.shapes.len == 1: tr(" color") else: tr(" colors"))

proc itNow(): TraceResult =
  beginBusy("Tracing")
  try: result = traceImage(itSrc.px, itSrc.w, itSrc.h, itOpts)
  finally: endBusy()

proc itMake() =
  ## Trace: shape layers, one a color, in a group above the current layer; the picture hidden.
  let d = cur()
  if d == nil: return
  let r = itNow()
  if r.shapes.len == 0:
    status = "Nothing to trace: the picture is all one color, or all of it was left out"
    return
  let src = d.current
  d.beginStep("Image Trace")
  d.touchLayers()
  var idxs: seq[int]
  var at = d.cur
  for k, s in r.shapes:
    let L = d.addShapeLayer(ShapeData(path: s.path, fill: solidPaint(s.color)), "Traced " & $(k + 1), above = at)
    at = d.layers.find(L)
    idxs.add at
  let g = d.groupLayers(idxs, "Image Trace")
  if not src.background and not src.group and src.px.len == d.w * d.h and not src.isShape and not src.isText:
    src.visible = false
  if g != nil: d.cur = d.layers.find(g)
  d.endStep()
  d.markAll()
  status = "Traced: " & $r.shapes.len & " shapes, " & $r.points & " points, in the group \"Image Trace\"" &
           (if src.visible: "" else: " (the picture under it is hidden)")

proc imageTraceDialog() =
  if itDlg:
    let d = cur()
    if d == nil:
      itDlg = false
      return
    dialog(itDlg, "Image Trace", 680):
      row:
        col(250):
          var names: seq[string]
          for p in TracePreset: names.add $p
          names.add "Custom"
          label "Preset:"
          if combo(names, itPresetI, w = dp(240)) and itPresetI <= ord(high(TracePreset)):
            itOpts = tracePreset(TracePreset(itPresetI))
          var o = itOpts
          var mode = ord(o.mode)
          label "Mode:"
          if combo(["Color", "Grayscale", "Black and White"], mode, w = dp(240)): o.mode = TraceMode(mode)
          if o.mode == tmBlackWhite:
            label "Threshold: " & $o.threshold
            slider(o.threshold, 0, 255, w = dp(240))
          else:
            label tr("Colors: ") & $o.colors
            slider(o.colors, 2, 64, w = dp(240))
          var paths = int(o.paths * 100 + 0.5)
          label tr("Paths (how closely): ") & $paths & "%"
          if slider(paths, 0, 100, w = dp(240)): o.paths = paths / 100
          var corners = int(o.corners * 100 + 0.5)
          label tr("Corners: ") & $corners & "%"
          if slider(corners, 0, 100, w = dp(240)): o.corners = corners / 100
          label tr("Noise: ") & $o.noise & tr(" px")
          slider(o.noise, 1, 200, w = dp(240))
          var blur = int(o.blur * 2 + 0.5)
          label tr("Soften first: ") & formatFloat(blur / 2, ffDecimal, 1) & tr(" px")
          if slider(blur, 0, 20, w = dp(240)): o.blur = blur / 2
          checkbox("Ignore white", o.ignoreWhite)
          checkbox("Stacked (no gaps between shapes)", o.stacked)
          if o != itOpts:
            itOpts = o
            itPresetI = ord(high(TracePreset)) + 1
            for p in TracePreset:
              if tracePreset(p) == o: itPresetI = ord(p)
        col(360):
          itPreviewNow()
          let pr = place(dp(360), dp(360))
          fill(pr, color(255, 255, 255))
          if itPreview != nil and itPreview.w > 0:
            let k = min(pr.w / itPreview.w, pr.h / itPreview.h)
            let w = max(1, int(itPreview.w.float * k))
            let h = max(1, int(itPreview.h.float * k))
            drawBitmap(rect(pr.x + (pr.w - w) div 2, pr.y + (pr.h - h) div 2, w, h), itPreview)
          box(pr, ui.theme.edge)
          let mb = itMegabytes()
          label(itInfo & tr("; as shape layers: about ") & $mb & tr(" MB"), color = ui.theme.gray)
          if mb > 1500:
            paragraph("That is a lot of memory: fewer colors, or Save as SVG (it takes none).", color = ui.theme.gray)
      row:
        if button("Save as SVG...", w = dp(120)):
          let base = if d.path.len > 0: d.path.splitFile.dir / d.path.splitFile.name
                     else: picturesDir() / (if d.name.len > 0: d.name else: "Untitled")
          itSvgPath = base & "-traced.svg"
          itSvgPick = true
        spring()
        if button("Trace", isDefault = true, w = dp(80)):
          itDlg = false
          itMake()
        if button("Cancel", w = dp(80)): itDlg = false
    if not itDlg and not itSvgPick:
      itSrc = (@[], 0, 0)
      itSmall = (@[], 0, 0)
  if filePicker(itSvgPick, itSvgPath, fmSave, ["*.svg"], "Save Trace as SVG"):
    var p = itSvgPath
    if p.splitFile.ext.toLowerAscii != ".svg": p.add ".svg"
    try:
      let r = itNow()
      writeFile(p, tracedSvg(r))
      rememberFile(p)
      status = "Saved " & p.extractFilename & " (" & $r.shapes.len & " shapes, " & $r.points & " points)"
    except CatchableError:
      status = "Could not save " & p.extractFilename & ": " & getCurrentExceptionMsg()

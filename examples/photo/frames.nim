# (included by photo.nim) Pictures inside shapes and type: Layer > Place
# Into puts a picture in a frame (a shape, type, a frame of the Frame
# tool), clipped to it; Layer > Fitting sets how it sits there -- Fill
# Frame Proportionally, Fit Content Proportionally, Fit Content to Frame,
# Center Content, Original Size -- and Frame Options its size, turn, place
# and flips, live. The picture stays a Smart Object: nothing is lost.

var
  frDlg: tuple[open: bool; fit: int; scale, angle, dx, dy: float; flipH, flipV: bool; was: Quad]
  frApplied = ""                       ## (the settings last put on the picture)
  frPending = false                    ## (Frame Options' step is open: OK ends it, anything else lets it go)

proc frameAndContent(d: Doc): tuple[frame, content: Layer] =
  ## (the current frame and the picture in it: the current layer is the picture -- a Smart
  ## Object clipped to the layer under it -- or the frame with such a picture above it)
  if d == nil or d.cur < 0 or d.cur >= d.layers.len: return
  let c = d.cur
  let L = d.layers[c]
  if L.isSmart and L.clipped:
    var i = c - 1
    while i >= 0 and d.layers[i].clipped: dec i
    if i >= 0: return (d.layers[i], L)
  elif not L.clipped and c + 1 < d.layers.len and d.layers[c + 1].clipped and d.layers[c + 1].isSmart:
    return (L, d.layers[c + 1])

proc fitContent(d: Doc; fit: FrameFit; scale = 100.0; angle = 0.0; dx = 0.0; dy = 0.0; flipH = false;
                flipV = false; step = true) =
  let (frame, content) = frameAndContent(d)
  if content == nil:
    status = "Pick a frame with a picture in it (Layer > Place Into puts one in a shape or in type)."
    return
  let box = d.layerBox(frame)
  if box.w <= 0 or box.h <= 0: return
  let s = content.smart
  let q = contentQuad(box, s.w, s.h, fit, scale, angle, dx, dy, flipH, flipV, s.quad)
  let ns = SmartData(src: s.src, w: s.w, h: s.h, quad: q, filters: s.filters, name: s.name, file: s.file,
                     warp: s.warp, link: s.link, linkStamp: s.linkStamp)
  if step:
    d.beginStep($fit)
    d.touchLayers()
    d.touch(content, d.bounds)
  content.smart = ns
  d.renderSmartLayer(content)
  if step: d.endStep()

proc startFrameOptions() =
  let d = cur()
  let (_, content) = frameAndContent(d)
  if content == nil:
    status = "Frame Options: pick a frame with a picture in it (Layer > Place Into)."
    return
  frDlg = (true, ord(ffFill), 100.0, 0.0, 0.0, 0.0, false, false, content.smart.quad)
  frApplied = $(frDlg.fit, frDlg.scale, frDlg.angle, frDlg.dx, frDlg.dy, frDlg.flipH, frDlg.flipV)   # (nothing yet)
  frPending = true
  d.beginStep("Frame Options")
  d.touchLayers()
  d.touch(content, d.bounds)

proc framesCommand(name: string): bool =
  ## (Layer > Fitting; true: done here)
  result = true
  let d = cur()
  case name
  of "Fill Frame Proportionally": d.fitContent(ffFill)
  of "Fit Content Proportionally": d.fitContent(ffFit)
  of "Fit Content to Frame": d.fitContent(ffStretch)
  of "Center Content": d.fitContent(ffCenter)
  of "Original Size": d.fitContent(ffOriginal)
  of "Frame Options...": startFrameOptions()
  of "Anchor to Text":
    # (the current layer anchored to a type layer: the one picked with it, else the nearest)
    let A = d.current
    var T: Layer = nil
    for L in d.layers:
      if L.picked and L.isText and L != A: T = L
    if T == nil:
      let o = d.anchorOrigin(A)
      var best = 1e18
      for L in d.layers:
        if not L.isText or L == A or L.text.path.len > 0: continue
        let r = L.textArea
        let cx = clamp(o.x.float, r.x.float, float(r.x + r.w))
        let cy = clamp(o.y.float, r.y.float, float(r.y + r.h))
        let dd = (cx - o.x) * (cx - o.x) + (cy - o.y) * (cy - o.y)
        if dd < best:
          best = dd
          T = L
    if T == nil:
      status = "Anchor to Text: there is no text on this page to anchor it to."
      return
    d.beginStep("Anchor to Text")
    d.touchLayers()
    d.touch(T, d.bounds)
    if d.anchorToText(A, T):
      d.endStep()
      status = A.name & " moves with its line of " & T.name & " now (Layer > Release Anchor lets it stay)"
    else: d.cancelStep()
  of "Release Anchor":
    d.beginStep("Release Anchor")
    d.touchLayers()
    for T in d.layers:
      if T.isText and T.uid == d.current.anchorTo: d.touch(T, d.bounds)
    d.releaseAnchor(d.current)
    d.endStep()
  of "Remove Content":
    let (_, content) = frameAndContent(d)
    if content != nil:
      d.layersChange("Remove Content"): d.deleteLayer(d.layers.find(content))
  else: result = false

proc frameDialogs() =
  if not frDlg.open:
    if frPending:
      # (closed from outside the dialog: as Cancel)
      frPending = false
      let d = cur()
      if d != nil and d.stepOpen:
        d.cancelStep()
        d.markAll()
    return
  let d = cur()
  let (_, content) = frameAndContent(d)
  if content == nil:
    frDlg.open = false
    frPending = false
    if d != nil and d.stepOpen: d.endStep()
    return
  var ok, cancel = false
  let before = frDlg
  dialog(frDlg.open, "Frame Options", 380):
    row([110, -1]):
      label "Fitting:"
      var names: seq[string]
      for f in FrameFit: names.add tr($f)
      combo(names, frDlg.fit, w = dp(230))
    template frNum(lab: string; v: untyped; lo, hi: float; unit: string) =
      row([110, -1]):
        label lab
        var i = int(round(v))
        row:
          if spin(i, int(lo), int(hi), w = dp(70)): v = i.float
          label unit
    frNum("Scale:", frDlg.scale, 1, 2000, "%")
    frNum("Rotate:", frDlg.angle, -360, 360, "°")
    for (lab, k) in [("Move across:", 0), ("Move down:", 1)]:
      # (lengths in the rulers' unit)
      row([110, -1]):
        label lab
        var v = float32(if k == 0: frDlg.dx else: frDlg.dy)
        row:
          if cur().lengthField(v, dp(70), -20000, 20000):
            if k == 0: frDlg.dx = v.float else: frDlg.dy = v.float
          label unitShort()
    row:
      checkbox("Flip across", frDlg.flipH)
      checkbox("Flip down", frDlg.flipV)
    label("The picture stays whole: change it again any time.", color = ui.theme.gray)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): cancel = true
  let now = $(frDlg.fit, frDlg.scale, frDlg.angle, frDlg.dx, frDlg.dy, frDlg.flipH, frDlg.flipV)
  if (frDlg != before or now != frApplied) and not cancel and (frDlg.open or ok):
    frApplied = now
    d.fitContent(FrameFit(clamp(frDlg.fit, 0, ord(high(FrameFit)))), frDlg.scale, frDlg.angle, frDlg.dx,
                 frDlg.dy, frDlg.flipH, frDlg.flipV, step = false)
  if cancel or not frDlg.open and not ok:
    # (as it was: the step let go of)
    frDlg.open = false
    frPending = false
    if d.stepOpen: d.cancelStep()
    d.markAll()
  elif ok:
    frDlg.open = false
    frPending = false
    if d.stepOpen: d.endStep()

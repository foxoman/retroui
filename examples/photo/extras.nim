# Retro Atelier -- included by photo.nim
#
# What the photo editors of 2026 added that Retro Atelier did not have (retroui/photomore):
# SDR to HDR; masks from a range of lightness or of hues, and two masks made one (Affinity's
# Luminosity, Hue Range and Compound masks).

var
  hdrUp: tuple[open: bool; peak, start: int] = (false, 200, 60)
    ## SDR to HDR: how much brighter the whitest becomes (% of a stop: 200 two stops), from what
    ## lightness on (%)
  rangeMask: tuple[open: bool; hue: bool; lo, hi, soft: int; h, width, hsoft, minSat: int; key: string] =
    (false, false, 128, 255, 30, 30, 25, 30, 10, "")
    ## Layer Mask > From Luminosity Range / From Hue Range: its settings
  compound: tuple[open: bool; src, op: int] = (false, 0, 0)
    ## Layer Mask > Compound Mask: with what (0 the selection, then each saved one), how

proc maskTarget(d: Doc): Layer =
  ## (the layer whose mask is made: the current one, if it can have one)
  let L = d.current
  if L == nil or L.background: nil else: L

proc setMask(d: Doc; L: Layer; m: seq[uint8]; what: string) =
  ## (`L`'s mask made `m`, one step to undo: a mask added when it has none -- an adjustment
  ## layer's pixels are its mask)
  d.beginStep(what)
  d.touchLayers()
  if L.adjust.kind.len > 0:
    for i in 0 ..< min(m.len, L.px.len): L.px[i] = grayPx(int(m[i]))
    inc L.ver
  else:
    if L.mask == nil: d.addLayerMask(mfRevealAll, d.layers.find(L))
    if L.mask != nil:
      for i in 0 ..< min(m.len, L.mask.px.len): L.mask.px[i] = grayPx(int(m[i]))
      inc L.mask.ver
  d.markAll()
  d.endStep()
  d.modified = true

proc rangeMaskOf(d: Doc): seq[uint8] =
  ## (the mask the Range Mask dialog's settings make, from the image as it shows)
  d.updateComposite()
  var im = Img(w: d.w, h: d.h, px: newSeqUninit[uint32](d.w * d.h))
  let c = d.compPtr
  for i in 0 ..< d.w * d.h: im.px[i] = c[i]
  if rangeMask.hue: hueRangeMask(im, rangeMask.h.float, rangeMask.width.float, rangeMask.hsoft.float, rangeMask.minSat)
  else: luminosityMask(im, rangeMask.lo, rangeMask.hi, rangeMask.soft)

proc rangeMaskDialog() =
  if not rangeMask.open: return
  let d = cur()
  if d == nil or d.maskTarget == nil:
    rangeMask.open = false
    return
  var go = false
  dialog(rangeMask.open, if rangeMask.hue: "Hue Range Mask" else: "Luminosity Range Mask", 420):
    if rangeMask.hue:
      paragraph("The current layer shown where the image below has these hues -- the sky, the leaves, " &
                "skin -- and hidden elsewhere.", color = ui.theme.gray)
      optSlider("Hue:", rangeMask.h, 0, 359, "°")
      let r = place(dp(300), dp(8))
      for x in 0 ..< r.w: vline(r.x + x, r.y, r.h, colorOf(fromHsb(float(x) * 360 / float(max(1, r.w)), 1, 1)))
      optSlider("Range:", rangeMask.width, 1, 180, "°")
      optSlider("Softness:", rangeMask.hsoft, 0, 180, "°")
      optSlider("Least Saturation:", rangeMask.minSat, 0, 100)
    else:
      paragraph("The current layer shown where the image is this light -- the highlights, the shadows -- and " &
                "hidden elsewhere.", color = ui.theme.gray)
      optSlider("From:", rangeMask.lo, 0, 255, "")
      optSlider("To:", rangeMask.hi, 0, 255, "")
      optSlider("Softness:", rangeMask.soft, 0, 128, "")
      row:
        for (n, a, b) in [("Shadows", 0, 85), ("Midtones", 70, 185), ("Highlights", 170, 255)]:
          if button(n, w = dp(96)):
            rangeMask.lo = a
            rangeMask.hi = b
    row:
      spring()
      if button("OK", isDefault = true, w = dp(86)): go = true
      if button("Cancel", w = dp(86)): rangeMask.open = false
  if go:
    rangeMask.open = false
    let L = d.maskTarget
    if L != nil:
      d.setMask(L, rangeMaskOf(d), if rangeMask.hue: "Hue Range Mask" else: "Luminosity Range Mask")

proc compoundDialog() =
  if not compound.open: return
  let d = cur()
  if d == nil or d.maskTarget == nil:
    compound.open = false
    return
  let L = d.maskTarget
  var srcs = @[tr("The selection")]
  for a in d.alphas: srcs.add a.name
  var go = false
  dialog(compound.open, "Compound Mask", 400):
    paragraph("The current layer's mask made one with the selection or a saved selection.", color = ui.theme.gray)
    row:
      label "With:"
      compound.src = clamp(compound.src, 0, srcs.high)
      combo(srcs, compound.src, w = dp(200))
    label("How:", bold = true)
    for k, n in ["Add (either)", "Subtract (the mask without it)", "Intersect (both)", "Difference (one, not both)"]:
      radio(n, compound.op, k)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(86)): go = true
      if button("Cancel", w = dp(86)): compound.open = false
  if go:
    compound.open = false
    let n = d.w * d.h
    var a = newSeq[uint8](n)
    let pxs = if L.adjust.kind.len > 0: L.px elif L.mask != nil: L.mask.px else: @[]
    for i in 0 ..< n: a[i] = (if pxs.len == n: uint8(rOf(pxs[i])) else: 255'u8)
    var b = newSeq[uint8](n)
    if compound.src == 0:
      for i in 0 ..< n: b[i] = uint8(d.selAt(i))
    elif compound.src - 1 < d.alphas.len and d.alphas[compound.src - 1].m.len == n:
      b = d.alphas[compound.src - 1].m
    d.setMask(L, compoundMask(a, b, compound.op), "Compound Mask")

proc sdrToHdrDialog() =
  if not hdrUp.open: return
  let d = cur()
  if d == nil:
    hdrUp.open = false
    return
  var go = false
  dialog(hdrUp.open, "SDR to HDR", 420):
    paragraph("The picture's highlights given back their light -- a white sky, a lamp, the sun on water made " &
              "brighter than white -- for an HDR screen or for printing it lighter or darker later. The document " &
              "becomes 32 bits a channel.", color = ui.theme.gray)
    optSlider("Highlights Up:", hdrUp.peak, 25, 400, "% of a stop")
    optSlider("From Lightness:", hdrUp.start, 20, 95)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(86)): go = true
      if button("Cancel", w = dp(86)): hdrUp.open = false
  if go:
    hdrUp.open = false
    let peak = pow(2.0, hdrUp.peak.float / 100)
    let start = hdrUp.start.float / 100
    d.beginStep("SDR to HDR")
    d.touchLayers()
    if d.depth != 32: d.toHdr()
    let f = withHi(proc (src: Img; inner: Rect): Img = src, HiWay(deep: sdrToHdrDeep(peak, start)))
    d.applyFilter(0, f)
    d.endStep()
    d.modified = true
    status = tr("Its highlights made brighter, up to ") & $(hdrUp.peak div 100) & "." & $(hdrUp.peak mod 100 div 10) &
             tr(" stops: View > 32-bit Preview Options shows them")

proc extrasDialogs() =
  ttDialog()
  objectDialogs()
  layoutExtraDialogs()
  fileMoreDialogs()
  aiMoreDialogs()
  rangeMaskDialog()
  compoundDialog()
  sdrToHdrDialog()

proc extrasCommand(name: string): bool =
  ## The commands above (true: done here).
  let d = cur()
  result = true
  case name
  of "SDR to HDR...":
    if d != nil and d.mode in {cmRGB, cmGray}: hdrUp.open = true
  of "From Luminosity Range...", "From Hue Range...":
    if d != nil and d.maskTarget != nil:
      rangeMask.hue = name == "From Hue Range..."
      rangeMask.open = true
    elif d != nil: status = tr("The Background has no mask: make it a layer first")
  of "Compound Mask...":
    if d != nil and d.maskTarget != nil: compound.open = true
  else: result = fileMoreCommand(name)

# Retro Atelier -- included by photo.nim
#
# Filter > Neural Filters: the usual workspace for them -- the picture
# large, the filters in a list beside it, each switched on with its own
# settings, the result seen as it is set; the output to the layer, a new
# layer or a new document. (Made here without a network: offline, on the
# device -- see retroui/photoneural.)

type NfKind = enum
  nfSkin = "Skin Smoothing", nfJpeg = "JPEG Artifacts Removal", nfRestore = "Photo Restoration",
  nfColorize = "Colorize", nfDepth = "Depth Blur", nfTransfer = "Color Transfer", nfHarmony = "Harmonization",
  nfZoom = "Super Zoom"

const
  nfBlurb: array[NfKind, string] = [
    "Evens out skin -- blemishes, shine -- keeping its texture, the eyes and hair sharp.",
    "Smooths away the blocks and ringing of a photo saved too small.",
    "Mends old photos: scratches and dust, grain, halftone dots, faded tones.",
    "Colors a black and white photo: click the picture to put the foreground color there -- each " &
      "color runs out along what is alike and stops at edges. With no colors put: a warm old-photo tint.",
    "Blurs what is far, as a wide-open lens does: the subject is found, the ground is taken " &
      "as nearer at the bottom, what is soft already as far.",
    "Gives the picture the colors of another open document, or of a look.",
    "Matches the layer's colors and light to the layers under it, so it sits in the picture.",
    "Makes the picture 2 to 4 times bigger, its edges kept sharp (opens as a new document)."]
  nfLooks = [("Golden Hour", [62.0, 14, 34], [22.0, 10, 18]), ("Blue Hour", [42.0, 6, -26], [20.0, 8, 14]),
             ("Teal and Orange", [55.0, 2, 8], [25.0, 16, 30]), ("Vintage Film", [58.0, 6, 16], [17.0, 6, 10]),
             ("Forest", [46.0, -16, 20], [20.0, 12, 14]), ("Desert", [66.0, 10, 28], [18.0, 8, 12]),
             ("Black and White", [55.0, 0, 0], [24.0, 0.01, 0.01])]

type NfState = object
  open: bool
  doc: Doc
  sel: NfKind
  on: array[NfKind, bool]
  skinBlur, skinSmooth: int
  jpegStrength: int
  rEnhance, rScratch, rNoise, rColorNoise, rHalftone: int
  dFocusSubject: bool
  dFocal, dRange, dStrength, dHaze, dWarm, dBright, dSat, dGrain: int
  dDepthOnly: bool
  tSource, tLum, tIntensity, tSat, tFade: int
  hIntensity, hBright, hSat: int
  cHints: seq[ColorHint]         ## Colorize: the colors put on the picture (where: 0..1 of it)
  cStrength, cSpread: int
  zFactor, zDetails, zNoise: int
  zJpeg: bool
  output: int
  small: Img                     ## the layer, small: what the preview is made from
  depthSmall: seq[uint8]
  key: string
  shown, before: Bitmap
  holdBefore: bool

var nf: NfState

proc startNeural() =
  let d = cur()
  if d == nil: return
  if d.mode notin {cmRGB, cmGray} and d.mode != cmCMYK:
    status = "Neural Filters work on RGB, CMYK and Grayscale images"
    return
  if not d.needPixels("Neural Filters..."): return
  nf.open = true
  nf.doc = d
  nf.key = ""
  # (the defaults, as the usual)
  if nf.skinBlur == 0:
    nf.skinBlur = 8; nf.skinSmooth = 60; nf.jpegStrength = 1
    nf.rEnhance = 50; nf.rScratch = 50; nf.rNoise = 30; nf.rColorNoise = 40
    nf.dFocusSubject = true; nf.dRange = 30; nf.dStrength = 50
    nf.tLum = 100; nf.tIntensity = 100
    nf.hIntensity = 70
    nf.cStrength = 100; nf.cSpread = 50
    nf.zFactor = 0; nf.zDetails = 50
  # the layer, small: what the preview is made from
  let L = d.layer
  let k = min(1.0, 560 / max(d.w, d.h).float)
  let sw = max(1, int(d.w.float * k))
  let sh = max(1, int(d.h.float * k))
  var px = if k < 1: resample(L.px, d.w, d.h, sw, sh, rsBicubic) else: L.px
  if L.background or L.lockAlpha:
    for p in px.mitems: p = p or 0xFF000000'u32
  nf.small = Img(w: sw, h: sh, px: px)
  nf.depthSmall = @[]
  nf.before = newBitmap(sw, sh)
  for i, p in px: nf.before.px[i] = blendPx(0xFFFFFFFF'u32, p, 255, bmNormal)
  nf.before.changed()
  nf.shown = nil

proc transferSources(): seq[string] =
  for (n, _, _) in nfLooks: result.add n
  for dw in docs:
    if dw.doc != nf.doc: result.add dw.doc.name

proc transferStats(): ColorStats =
  let k = nf.tSource
  if k < nfLooks.len:
    let (_, m, s) = nfLooks[k]
    return ColorStats(mean: m, sd: s)
  var n = nfLooks.len
  for dw in docs:
    if dw.doc == nf.doc: continue
    if n == k:
      dw.doc.updateComposite()
      return colorStatsOf(dw.doc.compCopy)
    inc n
  ColorStats(mean: [50.0, 0, 0], sd: [20.0, 10, 10])

proc runNeural(src: Img; depth: var seq[uint8]; full: bool): Img =
  ## The filters switched on, in the usual order, on `src`.
  var im = src
  if nf.on[nfJpeg]: im = jpegCleanImg(im, nf.jpegStrength)
  if nf.on[nfRestore]: im = restoreImg(im, nf.rEnhance, nf.rScratch, nf.rNoise, nf.rColorNoise, nf.rHalftone)
  if nf.on[nfColorize]:
    var hs: seq[ColorHint]
    for h in nf.cHints: hs.add (h.x * im.w.float, h.y * im.h.float, h.color)
    im = Img(w: im.w, h: im.h, px: colorizePixels(im.px, im.w, im.h, hs, nf.cStrength, nf.cSpread))
  if nf.on[nfSkin]: im = skinSmoothingImg(im, nf.skinBlur, nf.skinSmooth)
  if nf.on[nfTransfer]:
    im = colorTransferImg(im, transferStats(), nf.tLum, nf.tIntensity, nf.tSat, nf.tFade)
  if nf.on[nfHarmony] and nf.doc != nil:
    let f = harmonize(nf.doc, nf.doc.layer, nf.hIntensity, nf.hBright, nf.hSat)
    im = f(im, rect(0, 0, im.w, im.h))
  if nf.on[nfDepth]:
    if depth.len != im.w * im.h: depth = depthMapOf(im)
    if nf.dDepthOnly:
      var o = newImg(im.w, im.h)
      for i, v in depth: o.px[i] = grayPx(255 - int(v))
      im = o
    else:
      im = depthBlurImg(im, depth, nf.dStrength, (if nf.dFocusSubject: 0 else: nf.dFocal), nf.dRange,
                        nf.dHaze, nf.dWarm, nf.dBright, nf.dSat, nf.dGrain)
  if nf.on[nfZoom] and full:
    im = superZoomImg(im, nf.zFactor + 2, nf.zDetails, nf.zJpeg, nf.zNoise)
  im

proc neuralKey(): string =
  $nf.on & $(nf.skinBlur, nf.skinSmooth, nf.jpegStrength, nf.rEnhance, nf.rScratch, nf.rNoise, nf.rColorNoise,
             nf.rHalftone) & $(nf.dFocusSubject, nf.dFocal, nf.dRange, nf.dStrength, nf.dHaze, nf.dWarm,
             nf.dBright, nf.dSat, nf.dGrain, nf.dDepthOnly) & $(nf.tSource, nf.tLum, nf.tIntensity, nf.tSat,
             nf.tFade, nf.hIntensity, nf.hBright, nf.hSat) & $nf.cHints & $(nf.cStrength, nf.cSpread)

proc applyNeural() =
  ## OK: the filters on the whole layer, to where Output says.
  let d = nf.doc
  var there = false
  for dw in docs:
    if dw.doc == d: there = true
  if d == nil or not there: return
  var any = false
  for k in NfKind:
    if nf.on[k]: any = true
  if not any: return
  let L = d.layer
  let toDoc = nf.output == 2 or nf.on[nfZoom]
  beginBusy("Neural Filters", cancel = true)
  try:
    var src = Img(w: d.w, h: d.h, px: L.px)
    var depth: seq[uint8]
    let o = runNeural(src, depth, true)
    if toDoc:
      let nd = newDoc(o.w, o.h, 0xFFFFFFFF'u32, dpi = d.dpi, name = d.name & " (Neural Filters)")
      for i in 0 ..< min(o.px.len, nd.layers[0].px.len): nd.layers[0].px[i] = o.px[i] or 0xFF000000'u32
      inc nd.layers[0].ver
      nd.markAll()
      nd.modified = true
      addDoc(nd)
    elif nf.output == 1:
      d.layersChange("Neural Filters"):
        let nl = d.duplicateLayer()
        nl.name = L.name & " (Neural Filters)"
        nl.background = false
        nl.px = o.px
        inc nl.ver
        d.markAll()
    else:
      d.beginStep("Neural Filters")
      d.writeBack(L, d.bounds, o)
      d.endStep()
    status = "Neural Filters done"
  except BusyCancelled:
    status = "Cancelled"
  finally: endBusy(cancel = true)

proc nfSlider(lab: string; v: var int; lo, hi: int; unit = "") =
  row([138, -1, 40]):
    label lab
    discard slider(v, lo, hi, ticks = 0)
    label $v & unit

proc neuralDialog() =
  if not nf.open: return
  if nf.doc == nil or nf.doc != cur():
    nf.open = false
    return
  let wide = not isCompact()
  let dlgW = if wide: min(ui.w - dp(30), dp(940)) else: ui.w
  var ok = false
  dialog(nf.open, "Neural Filters", dlgW):
    # the result, made again when something changed (once the slider is let go)
    let key = neuralKey()
    if key != nf.key and not ui.mouseDown:
      nf.key = key
      var any = false
      for k in NfKind:
        if nf.on[k] and k != nfZoom: any = true
      if any:
        var o = runNeural(nf.small, nf.depthSmall, false)
        let b = newBitmap(o.w, o.h)
        for i, p in o.px: b.px[i] = blendPx(0xFFFFFFFF'u32, p, 255, bmNormal)
        b.changed()
        nf.shown = b
      else: nf.shown = nil
    let picW = if wide: dlgW - dp(320) else: dlgW - dp(24)
    let picH = if wide: dp(430) else: dp(240)
    template pictureArea() =
      let r = place(picW, picH)
      fill(r, ui.theme.shadow)
      let showBefore = nf.holdBefore or nf.shown == nil
      drawFit(inset(r, dp(4)), if showBefore: nf.before else: nf.shown)
      box(r, ui.theme.frame)
      let hit = interact(idOf("nfpic"), r, focusable = false)
      # (where the picture is in it, as drawFit puts it)
      let ir = inset(r, dp(4))
      let pb = nf.before
      var pr = ir
      if pb != nil and pb.w > 0 and pb.h > 0:
        let kk = min(ir.w / pb.w, ir.h / pb.h)
        let pw = max(1, int(pb.w.float * kk))
        let ph = max(1, int(pb.h.float * kk))
        pr = rect(ir.x + (ir.w - pw) div 2, ir.y + (ir.h - ph) div 2, pw, ph)
      if nf.sel == nfColorize and nf.on[nfColorize]:
        # Colorize: a click puts the foreground color there
        if hit.clicked and pr.contains(point(ui.mx, ui.my)):
          nf.cHints.add (((ui.mx - pr.x).float + 0.5) / pr.w.float, ((ui.my - pr.y).float + 0.5) / pr.h.float, fg)
        for h in nf.cHints:
          let cx = pr.x + int(h.x * pr.w.float)
          let cy = pr.y + int(h.y * pr.h.float)
          let mr = rect(cx - dp(5), cy - dp(5), dp(11), dp(11))
          fill(mr, colorOf(h.color))
          box(mr, ui.theme.text)
          box(inset(mr, -1), ui.theme.window)
        if hit.hover: ui.tip = "Click: the foreground color put there"
        label("Click the picture to put a color", color = ui.theme.gray)
      else:
        nf.holdBefore = hit.down
        if hit.hover: ui.tip = "Hold the mouse down on it: the picture as it was"
        label(if showBefore: "Before" else: "Preview (hold to compare)", color = ui.theme.gray)
    template filterList() =
      for k in NfKind:
        row([22, -1]):
          discard checkbox("", nf.on[k])
          let r = place(available(), ItemH)
          let hit = interact(idOf("nfrow:" & $k), r, focusable = false)
          if k == nf.sel: fill(r, ui.theme.select)
          elif hit.hover: fill(r, hoverColor())
          text(r.x + dp(4), r.y + (r.h - FontH) div 2, $k, if k == nf.sel: ui.theme.selectText else: ui.theme.text)
          if hit.clicked: nf.sel = k
      separator()
      label($nf.sel, bold = true)
      paragraph(nfBlurb[nf.sel], color = ui.theme.gray)
      case nf.sel
      of nfSkin:
        nfSlider("Blur:", nf.skinBlur, 1, 30, " px")
        nfSlider("Smoothness:", nf.skinSmooth, 0, 100)
      of nfColorize:
        row:
          label "Color:"
          colorWell(fg, "nfcolor", dp(40))
          label($nf.cHints.len & (if nf.cHints.len == 1: " color put" else: " colors put"), color = ui.theme.gray)
        row:
          if button("Undo Last", w = dp(96), enabled = nf.cHints.len > 0): nf.cHints.setLen(nf.cHints.len - 1)
          if button("Clear All", w = dp(96), enabled = nf.cHints.len > 0): nf.cHints.setLen(0)
        nfSlider("Strength:", nf.cStrength, 0, 100)
        nfSlider("Spread:", nf.cSpread, 0, 100)
        if not nf.on[nfColorize]: label("(Tick it in the list to put colors)", color = ui.theme.gray)
      of nfJpeg:
        row:
          label "Strength:"
          discard combo(["Low", "Medium", "High"], nf.jpegStrength, w = dp(110))
      of nfRestore:
        nfSlider("Photo Enhancement:", nf.rEnhance, 0, 100)
        nfSlider("Scratch Reduction:", nf.rScratch, 0, 100)
        nfSlider("Noise Reduction:", nf.rNoise, 0, 100)
        nfSlider("Color Noise:", nf.rColorNoise, 0, 100)
        nfSlider("Halftone Artifacts:", nf.rHalftone, 0, 100)
      of nfDepth:
        checkbox("Focus Subject", nf.dFocusSubject)
        if not nf.dFocusSubject: nfSlider("Focal Distance:", nf.dFocal, 0, 100)
        nfSlider("Focal Range:", nf.dRange, 0, 100)
        nfSlider("Blur Strength:", nf.dStrength, 0, 100)
        nfSlider("Haze:", nf.dHaze, 0, 100)
        nfSlider("Warmness:", nf.dWarm, -100, 100)
        nfSlider("Brightness:", nf.dBright, -100, 100)
        nfSlider("Saturation:", nf.dSat, -100, 100)
        nfSlider("Grain:", nf.dGrain, 0, 100)
        checkbox("Output Depth Map Only", nf.dDepthOnly)
      of nfTransfer:
        row:
          label "Source:"
          discard combo(transferSources(), nf.tSource, w = dp(170))
        nfSlider("Luminance:", nf.tLum, 0, 100)
        nfSlider("Color Intensity:", nf.tIntensity, 0, 200)
        nfSlider("Saturation:", nf.tSat, -100, 100)
        nfSlider("Fade:", nf.tFade, 0, 100)
      of nfHarmony:
        nfSlider("Intensity:", nf.hIntensity, 0, 100)
        nfSlider("Brightness:", nf.hBright, -50, 50)
        nfSlider("Saturation:", nf.hSat, -100, 100)
        if nf.doc.cur == 0: label("(The bottom layer: nothing under it to match)", color = ui.theme.gray)
      of nfZoom:
        row:
          label "Zoom:"
          discard combo(["2x", "3x", "4x"], nf.zFactor, w = dp(70))
        let (nw, nh) = (nf.doc.w * (nf.zFactor + 2), nf.doc.h * (nf.zFactor + 2))
        label($nw & " x " & $nh & " pixels", color = ui.theme.gray)
        nfSlider("Enhance Details:", nf.zDetails, 0, 100)
        nfSlider("Noise Reduction:", nf.zNoise, 0, 100)
        checkbox("Remove JPEG Artifacts", nf.zJpeg)
        if nf.on[nfZoom]: label("(Seen once it is made: a new document)", color = ui.theme.gray)
    if wide:
      row([-1, 290]):
        col: pictureArea()
        col:
          beginScroll(picH + dp(20), "nflist")
          filterList()
          endScroll()
    else:
      pictureArea()
      beginScroll(max(dp(160), ui.h - picH - dp(200)), "nflist")
      filterList()
      endScroll()
    row:
      label "Output:"
      discard combo(["Current Layer", "New Layer", "New Document"], nf.output, w = dp(140),
                    enabled = not nf.on[nfZoom])
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): nf.open = false
  if ok:
    nf.open = false
    applyNeural()
  if not nf.open:
    nf.small = Img()
    nf.depthSmall = @[]
    nf.shown = nil
    nf.before = nil

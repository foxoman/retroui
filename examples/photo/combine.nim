# (included by photo.nim) Pictures put together: File > Automate >
# Photomerge, Merge to HDR Pro and Load Files into Stack; Edit > Auto-Align
# Layers and Auto-Blend Layers; Edit > Sky Replacement. (The work is in
# retroui/photomerge.)

# ---- the pictures to put together ---------------------------------------------------------------------------

type MergeKind = enum mkPanorama = "Photomerge", mkHdr = "Merge to HDR Pro", mkStack = "Load Files into Stack"

var
  mgOpen = false
  mgKind = mkPanorama
  mgFiles: seq[string]           ## files, or "doc:<n>" for an open image
  mgPick = 0
  mgAddPick = false
  mgAddPath = ""
  mgFolderPick = false
  mgFolder = ""
  mgLayout = 0                   ## Perspective, Collage, Reposition
  mgBlend = true
  mgCrop = false
  mgFill = false
  mgAlign = true
  mgDetail = 100                 ## HDR: contrast, saturation, exposure weights (%)
  mgSat = 100
  mgExp = 100
  mgStackAlign = false
  aaOpen = false                 ## Auto-Align Layers
  aaLayout = 0                   ## Auto (Perspective), Collage, Reposition
  abOpen = false                 ## Auto-Blend Layers
  abMethod = 0                   ## Panorama, Stack Images

proc wideSlider(lab: string; v: var int; lo, hi: int; unit = ""): bool {.discardable.} =
  ## A slider with room for a longer name.
  row([96, -1, 44]):
    label lab
    result = slider(v, lo, hi, ticks = 0)
    label $v & unit

proc startMerge(k: MergeKind) =
  mgKind = k
  mgFiles.setLen(0)
  mgPick = 0
  mgOpen = true

proc mergeName(f: string): string =
  if f.startsWith("doc:"):
    let i = (try: parseInt(f[4 .. ^1]) except ValueError: -1)
    if i in 0 .. docs.high: docs[i].doc.name & " (open)" else: "(closed)"
  else: f.extractFilename

proc mergeImages(): (seq[Img], seq[string]) =
  ## The pictures picked, read (and the names of those that could not be).
  var imgs: seq[Img]
  var names: seq[string]
  for f in mgFiles:
    if f.startsWith("doc:"):
      let i = (try: parseInt(f[4 .. ^1]) except ValueError: -1)
      if i notin 0 .. docs.high: continue
      let d = docs[i].doc
      imgs.add Img(w: d.w, h: d.h, px: d.flattened(white))
      names.add d.name
    else:
      try:
        let d = openPicture(f)
        imgs.add Img(w: d.w, h: d.h, px: d.flattened(white))
        names.add f.splitFile.name
      except CatchableError:
        status = "Could not read " & f.extractFilename
  (imgs, names)

proc maskLayer(m: seq[uint8]): Layer =
  ## A layer mask from 0..255.
  result = Layer(name: "Layer Mask", pxRaw: newSeq[uint32](m.len), opacity: 100, visible: true, gray: true)
  for i, v in m: result.px[i] = grayPx(int(v))

proc alignedToFirst(imgs: seq[Img]; model: AlignModel): seq[Img] =
  ## The pictures moved onto the first one's place (as big as it), where
  ## they do not reach: the first one's pixels.
  var feats: seq[Features]
  for im in imgs: feats.add featuresOf(im)
  let (hs, ok, _) = alignAll(feats, model, reference = 0)
  let w = imgs[0].w
  let h = imgs[0].h
  for i, im in imgs:
    if i == 0 or not ok[i]:
      if im.w == w and im.h == h: result.add im
      else: result.add Img(w: w, h: h, px: warp(im, Identity, w, h))
      continue
    var px = warp(im, hs[i], w, h)
    for t in 0 ..< px.len:
      if (px[t] shr 24) < 255: px[t] = mix(imgs[0].px[t], px[t] or 0xFF000000'u32, int(px[t] shr 24) / 255)
    result.add Img(w: w, h: h, px: px)

proc runMerge() =
  let (imgs, names) = mergeImages()
  if imgs.len < (if mgKind == mkStack: 1 else: 2):
    status = "Pick two pictures or more"
    return
  case mgKind
  of mkPanorama:
    beginBusy("Photomerge")
    try:
      let p = photomerge(imgs, [amPerspective, amSimilarity, amTranslation][clamp(mgLayout, 0, 2)], mgBlend,
                         maxPixels)
      if p.used.len < 2:
        status = "The pictures do not overlap: nothing to put together"
        return
      let d = newUntitled(p.w, p.h, 0, name = "Untitled Panorama")
      d.layers.setLen(0)
      for k, i in p.used:
        let L = d.newLayer(names[i])
        L.px = p.layers[k]
        if p.masks.len > 0 and k > 0: L.mask = maskLayer(p.masks[k])
        d.layers.add L
      d.cur = d.layers.high
      d.markAll()
      if mgFill:
        # (what the pictures do not cover made up, on a layer of its own)
        var all = newSeq[uint32](d.w * d.h)
        d.compositeInto(all, d.bounds, d.layers)
        let L = d.newLayer("Filled")
        L.px = all
        d.layers.add L
        d.cur = d.layers.high
        var hole = newSeq[uint8](d.w * d.h)
        for i, v in all: hole[i] = uint8(255 - int(v shr 24))
        d.sel = hole
        inc d.selVer
        d.contentAwareFill(7)
        d.sel = @[]
        inc d.selVer
      if mgCrop:
        let r = p.fullRect()
        if r.w > 0 and (r.w < d.w or r.h < d.h): d.crop(r)
      d.modified = true
      d.clearHistory()
      addDoc(d)
      if p.left.len > 0:
        var miss: seq[string]
        for i in p.left: miss.add names[i]
        status = "Left out (they overlap none of the others): " & miss.join(", ")
    finally: endBusy()
  of mkHdr:
    beginBusy("Merge to HDR Pro")
    try:
      var src = imgs
      if mgAlign: src = alignedToFirst(imgs, amSimilarity)
      else:
        for im in src.mitems:
          if im.w != src[0].w or im.h != src[0].h: im = Img(w: src[0].w, h: src[0].h, px: warp(im, Identity, src[0].w, src[0].h))
      let f = exposureFusion(src, mgDetail / 100, mgSat / 100, mgExp / 100)
      let d = newUntitled(f.w, f.h, white, name = "Untitled HDR")
      d.layers[0].px = f.px
      inc d.layers[0].ver
      d.markAll()
      d.modified = true
      d.clearHistory()
      addDoc(d)
    finally: endBusy()
  of mkStack:
    beginBusy("Load Files into Stack")
    try:
      var src = imgs
      var w = 0
      var h = 0
      for im in src:
        w = max(w, im.w)
        h = max(h, im.h)
      if mgStackAlign and src.len > 1:
        var feats: seq[Features]
        for im in src: feats.add featuresOf(im)
        let (hs, ok, _) = alignAll(feats, amPerspective, reference = 0)
        for i in 1 ..< src.len:
          if ok[i]: src[i] = Img(w: w, h: h, px: warp(src[i], hs[i], w, h))
      let d = newUntitled(w, h, 0, name = "Untitled Stack")
      d.layers.setLen(0)
      for i, im in src:
        let L = d.newLayer(names[i])
        if im.w == w and im.h == h: L.px = im.px
        else: L.px = warp(im, Identity, w, h)
        d.layers.add L
      d.cur = d.layers.high
      d.markAll()
      d.modified = true
      d.clearHistory()
      addDoc(d)
    finally: endBusy()

proc mergeDialog() =
  if mgOpen:
    dialog(mgOpen, $mgKind, 480):
      label(case mgKind
            of mkPanorama: "Pictures that overlap, taken turning from one place: put together into one."
            of mkHdr: "Pictures of one scene at different exposures: one with the detail of all."
            of mkStack: "Pictures as the layers of one new image.", color = ui.theme.gray)
      row([-1, 130]):
        var items: seq[string]
        for f in mgFiles: items.add mergeName(f)
        listbox(items, mgPick, rows = 6)
        col:
          if button("Add Open Images", w = dp(126), enabled = docs.len > 0):
            for i in 0 .. docs.high:
              if ("doc:" & $i) notin mgFiles: mgFiles.add "doc:" & $i
          if button("Add File...", w = dp(126)):
            proc go() =
              if mgAddPath.len == 0: mgAddPath = picturesDir()
              mgAddPick = true
            if storageFor(go): go()
          if button("Add Folder...", w = dp(126)):
            proc go() =
              if mgFolder.len == 0: mgFolder = picturesDir()
              mgFolderPick = true
            if storageFor(go): go()
          if button("Remove", w = dp(126), enabled = mgPick in 0 .. mgFiles.high):
            mgFiles.delete(mgPick)
            mgPick = min(mgPick, mgFiles.high)
      case mgKind
      of mkPanorama:
        row:
          label "Layout:"
          combo(["Perspective", "Collage (turned, scaled)", "Reposition (moved only)"], mgLayout, w = dp(200))
        checkbox("Blend Images Together", mgBlend)
        checkbox("Content-Aware Fill Transparent Areas", mgFill)
        checkbox("Crop to the Filled Part", mgCrop)
      of mkHdr:
        checkbox("Attempt to Automatically Align Source Images", mgAlign)
        wideSlider("Detail:", mgDetail, 0, 300, "%")
        wideSlider("Color:", mgSat, 0, 300, "%")
        wideSlider("Exposure:", mgExp, 0, 300, "%")
      of mkStack:
        checkbox("Attempt to Automatically Align Source Images", mgStackAlign)
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80), enabled = mgFiles.len >= (if mgKind == mkStack: 1 else: 2)):
          mgOpen = false
          runMerge()
        if button("Cancel", w = dp(80)): mgOpen = false
  if filePicker(mgAddPick, mgAddPath, fmOpen, openPatterns, "Add a Picture"):
    if mgAddPath notin mgFiles: mgFiles.add mgAddPath
  if filePicker(mgFolderPick, mgFolder, fmFolder, [], "Add the Pictures of a Folder"):
    for f in batchFiles(mgFolder, false):
      if f notin mgFiles: mgFiles.add f

# ---- Auto-Align, Auto-Blend ----------------------------------------------------------------------------------

proc pickedPixelLayers(d: Doc): seq[int] =
  ## The picked layers that hold pixels, bottom first.
  for i in d.pickedLayers:
    let L = d.layers[i]
    if not L.group and L.adjust.kind.len == 0 and not L.isVector and not L.isSmart: result.add i
  result.reverse()

proc autoAlign(d: Doc; model: AlignModel) =
  let idx = d.pickedPixelLayers
  if idx.len < 2:
    status = "Pick two layers or more (Shift+click in the Layers palette)"
    return
  beginBusy("Auto-Align Layers")
  try:
    var feats: seq[Features]
    for i in idx: feats.add featuresOf(Img(w: d.w, h: d.h, px: d.layers[i].px))
    let (hs, ok, r) = alignAll(feats, model)
    var moved = 0
    d.layersChange("Auto-Align Layers"):
      for k, i in idx:
        if k == r or not ok[k]: continue
        let L = d.layers[i]
        d.touch(L, d.bounds)
        L.px = warp(Img(w: d.w, h: d.h, px: L.px), hs[k], d.w, d.h)
        inc L.ver
        if L.mask != nil:
          d.touch(L.mask, d.bounds)
          var m = warp(Img(w: d.w, h: d.h, px: L.mask.px), hs[k], d.w, d.h)
          for v in m.mitems: v = v or 0xFF000000'u32
          L.mask.px = m
          inc L.mask.ver
        inc moved
      d.markAll()
    var missed = 0
    for k in 0 ..< idx.len:
      if not ok[k]: inc missed
    status = $moved & " layers aligned to " & d.layers[idx[r]].name &
             (if missed > 0: "; " & $missed & " share nothing with the others" else: "")
  finally: endBusy()

proc edgeWeights(px: seq[uint32]; w, h: int): seq[float32] =
  ## How far in from where a layer is transparent each pixel is (0..1).
  var m = newSeq[uint8](w * h)
  for i, p in px: m[i] = if (p shr 24) >= 128: 255'u8 else: 0'u8
  var b = m
  blurMask(b, w, h, max(4.0, min(w, h).float / 12))
  result = newSeq[float32](w * h)
  for i in 0 ..< w * h:
    result[i] = if m[i] == 0: 0'f32 else: max(0.001'f32, float32(b[i].int - 127) / 128'f32)

proc autoBlend(d: Doc; stack: bool) =
  let idx = d.pickedPixelLayers
  if idx.len < 2:
    status = "Pick two layers or more (Shift+click in the Layers palette)"
    return
  beginBusy("Auto-Blend Layers")
  try:
    var masks: seq[seq[uint8]]
    if stack:
      var imgs: seq[Img]
      for i in idx: imgs.add Img(w: d.w, h: d.h, px: d.layers[i].px)
      masks = focusStackMasks(imgs)
    else:
      var ws: seq[seq[float32]]
      for i in idx: ws.add edgeWeights(d.layers[i].px, d.w, d.h)
      masks = blendMasks(ws)
    d.layersChange("Auto-Blend Layers"):
      for k, i in idx:
        if k == 0 and stack: continue
        let L = d.layers[i]
        L.mask = maskLayer(masks[k])
        L.maskOff = false
      d.markAll()
  finally: endBusy()

proc alignDialogs() =
  if aaOpen:
    dialog(aaOpen, "Auto-Align Layers", 380):
      label("The picked layers moved onto the one most of them overlap, by what they share.",
            color = ui.theme.gray)
      group("Projection"):
        radio("Auto (Perspective)", aaLayout, 0)
        radio("Collage (moved, turned and scaled)", aaLayout, 1)
        radio("Reposition (moved only)", aaLayout, 2)
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)):
          aaOpen = false
          let d = cur()
          if d != nil: d.autoAlign([amPerspective, amSimilarity, amTranslation][clamp(aaLayout, 0, 2)])
        if button("Cancel", w = dp(80)): aaOpen = false
  if abOpen:
    dialog(abOpen, "Auto-Blend Layers", 380):
      group("Blend Method"):
        radio("Panorama", abMethod, 0)
        radio("Stack Images (focus)", abMethod, 1)
      label(if abMethod == 0: "Masks that join the layers where they overlap, gently."
            else: "Masks that show each layer where it is sharpest: one picture in focus throughout.",
            color = ui.theme.gray)
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)):
          abOpen = false
          let d = cur()
          if d != nil: d.autoBlend(abMethod == 1)
        if button("Cancel", w = dp(80)): abOpen = false

# ---- Sky Replacement ------------------------------------------------------------------------------------------

var
  skOpen = false
  skDoc: Doc
  skKind = 1                     ## index into SkyKind; SkyKind.high + 1: a picture
  skPicture: Img                 ## the sky from a file
  skPictureName = ""
  skPick = false
  skPath = ""
  skShift = 0
  skFade = 30
  skBright = 0
  skTemp = 0
  skScale = 100
  skFlip = false
  skMove = 0
  skLight = 50
  skOutput = 0                   ## New Layers, Duplicate Layer
  skMask: seq[uint8]             ## the sky (full size)
  skSmall: tuple[img: Img; mask: seq[uint8]; k: float]
  skPreview: Bitmap
  skKey = ""
  skSkyCache: tuple[key: string; img: Img]

proc startSky() =
  let d = cur()
  if d == nil: return
  beginBusy("Finding the sky")
  try:
    d.updateComposite()
    let comp = d.compCopy
    skMask = selectSky(Img(w: d.w, h: d.h, px: comp))
    var any = 0
    for v in skMask:
      if v >= 128: inc any
    if any < d.w * d.h div 100:
      status = "No sky found"
      return
    let k = min(1.0, 360.0 / max(d.w, d.h).float)
    let pw = max(1, int(d.w.float * k))
    let ph = max(1, int(d.h.float * k))
    let small = thumbnailOf(comp, d.w, d.h, pw, ph, checker = false)
    var m = newSeq[uint8](pw * ph)
    for y in 0 ..< ph:
      for x in 0 ..< pw:
        m[y * pw + x] = skMask[min(d.h - 1, int(y.float / k)) * d.w + min(d.w - 1, int(x.float / k))]
    skSmall = (Img(w: small.w, h: small.h, px: small.px), m, k)
    skDoc = d
    skKey = ""
    skOpen = true
  finally: endBusy()

proc skySource(w, reach: int): Img =
  ## The sky chosen, about as wide as `w`.
  if skKind > SkyKind.high.ord and skPicture.w > 0: return skPicture
  let kind = SkyKind(clamp(skKind, 0, SkyKind.high.ord))
  let sw = clamp(w, 64, 2400)
  let sh = max(32, int(sw.float * max(0.3, reach.float / max(1, w).float)))
  let key = $kind & "/" & $sw & "/" & $sh
  if skSkyCache.key != key:
    skSkyCache = (key, makeSky(kind, sw, sh, seed = 3))
  skSkyCache.img

proc skyResult(src: Img; mask0: seq[uint8]; k: float): (Img, seq[uint8], Img, uint32) =
  ## The sky put in: the sky placed, the mask refined, the whole as it will
  ## look, and the light for the foreground.
  let w = src.w
  let h = src.h
  var mask = mask0
  shiftEdge(mask, w, h, int(round(skShift.float * k)))
  if skFade > 0: blurMask(mask, w, h, max(0.5, skFade.float * k / 4))
  let horizon = skyHorizon(mask, w, h)
  var sky = placeSky(skySource(w, horizon), w, h, horizon, skScale / 100, skFlip, skMove / 100)
  adjustSky(sky, skBright, skTemp)
  let light = skyLight(sky, mask, horizon)
  var shown = newImg(w, h)
  let amt = skLight / 100 * 0.6
  for i in 0 ..< w * h:
    let p = src.px[i]
    let lit = if amt > 0: mix(p, blendPx(p, light, 255, bmSoftLight), amt) else: p
    shown.px[i] = mix(lit, sky.px[i], mask[i].int / 255) or 0xFF000000'u32
  (sky, mask, shown, light)

proc applySky(d: Doc)

proc skyDialog() =
  if not skOpen or skDoc == nil: return
  let d = skDoc
  var there = false
  for dw in docs:
    if dw.doc == d: there = true
  if not there:
    skOpen = false
    return
  var go = false
  dialog(skOpen, "Sky Replacement", 680):
    row([370, -1]):
      col:
        let key = $skKind & "/" & skPictureName & "/" & $skShift & "/" & $skFade & "/" & $skBright & "/" & $skTemp &
                  "/" & $skScale & "/" & $skFlip & "/" & $skMove & "/" & $skLight
        if key != skKey or skPreview == nil:
          let (_, _, shown, _) = skyResult(skSmall.img, skSmall.mask, skSmall.k)
          skPreview = newBitmap(shown.w, shown.h)
          skPreview.px = shown.px
          skKey = key
        discard pictureBox("skypreview", skPreview, dp(362), dp(270))
      col:
        var names: seq[string]
        for s in SkyKind: names.add $s
        names.add(if skPictureName.len > 0: "Picture: " & skPictureName else: "A Picture...")
        label "Sky:"
        if combo(names, skKind, w = available()) and skKind > SkyKind.high.ord and skPicture.w == 0:
          proc goPick() =
            if skPath.len == 0: skPath = picturesDir()
            skPick = true
          if askStorage(AppName, filesWhy, goPick): goPick()
        if skKind > SkyKind.high.ord:
          if button("Choose a Picture...", w = dp(160)):
            proc goPick() =
              if skPath.len == 0: skPath = picturesDir()
              skPick = true
            if askStorage(AppName, filesWhy, goPick): goPick()
        wideSlider("Shift Edge:", skShift, -50, 50)
        wideSlider("Fade Edge:", skFade, 0, 100)
        wideSlider("Brightness:", skBright, -100, 100)
        wideSlider("Temperature:", skTemp, -100, 100)
        wideSlider("Scale:", skScale, 20, 300, "%")
        wideSlider("Move:", skMove, -100, 100)
        checkbox("Flip", skFlip)
        wideSlider("Lighting:", skLight, 0, 100, "%")
        row:
          label "Output:"
          combo(["New Layers", "Duplicate Layer"], skOutput, w = dp(140))
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): go = true
      if button("Cancel", w = dp(80)): skOpen = false
  if filePicker(skPick, skPath, fmOpen, openPatterns, "A Picture of the Sky"):
    try:
      let pd = openPicture(skPath)
      skPicture = Img(w: pd.w, h: pd.h, px: pd.flattened(white))
      skPictureName = skPath.extractFilename
      skKind = SkyKind.high.ord + 1
      skKey = ""
    except CatchableError:
      status = "Could not read " & skPath.extractFilename
  if go:
    skOpen = false
    applySky(d)

proc applySky(d: Doc) =
  ## Sky Replacement's OK: the sky put in, at full size.
  if true:
    beginBusy("Sky Replacement")
    try:
      d.updateComposite()
      let comp = Img(w: d.w, h: d.h, px: d.compCopy)
      let (sky, mask, shown, light) = skyResult(comp, skMask, 1.0)
      d.layersChange("Sky Replacement"):
        if skOutput == 1:
          let L = d.newLayer("Sky Replacement")
          L.px = shown.px
          d.insertLayer(L, d.layers.high)
        else:
          var inv = newSeq[uint8](mask.len)
          for i, v in mask: inv[i] = 255'u8 - v
          let lt = d.newLayer("Foreground Lighting", light)
          lt.mode = bmSoftLight
          lt.opacity = clamp(int(skLight.float * 0.6), 0, 100)
          lt.mask = maskLayer(inv)
          d.insertLayer(lt, d.layers.high)
          let s = d.newLayer("Sky")
          s.px = sky.px
          s.mask = maskLayer(mask)
          d.insertLayer(s, d.layers.high)
          let g = d.groupLayers(@[d.layers.high, d.layers.high - 1], "Sky Replacement Group")
          if g != nil: g.passThrough = true
        d.markAll()
    finally: endBusy()

proc combineDialogs() =
  mergeDialog()
  alignDialogs()
  skyDialog()

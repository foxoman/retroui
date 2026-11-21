# (included by photo.nim) The Timeline panel (Window > Timeline): an animation's frames, as
# the usual frame animation has them -- side by side, each with its picture and how long it
# shows; a click shows one; New Frame (a copy of the one shown, to change), Delete, Tween (frames
# between this one and the next), Make Frames From Layers, Flatten Frames Into Layers; play,
# stop, first, back, on, last; how many times it plays; onion skin (the frame before shown
# faint on the image). An animated GIF, WebP or PNG opens as its frames; File > Export >
# Save Animation saves them back.

var
  tline: tuple[playing: bool; since: float; onion: bool; tween: int]
    ## (playing since then; the frame before shown faint; how many frames Tween puts in)
  tlThumbs: Table[(pointer, int), tuple[key: string; b: Bitmap]]
    ## (each frame's picture, small: made again when the frame or its layers change)
  tlOnion: tuple[key: string; b: Bitmap]

var tlGen = ""       ## (the document's changes, as its history has them: showing a frame is none)

proc frameKey(d: Doc; k: int): string =
  ## (what a frame's picture depends on: its states, and the document's changes)
  result = tlGen & "/" & $d.frames[k].layers.len
  for fl in d.frames[k].layers:
    result.add "|" & $fl.uid & (if fl.visible: "v" else: "h") & $fl.opacity & "@" & $fl.dx & "," & $fl.dy

proc smallOf(px: seq[uint32]; w, h, side: int; alpha = 255): Bitmap =
  ## (a picture made small, its longest side `side`, as opaque as `alpha` says)
  let s = max(1.0, max(w, h) / side)
  let tw = max(1, int(w.float / s))
  let th = max(1, int(h.float / s))
  result = newBitmap(tw, th)
  for y in 0 ..< th:
    let sy = min(h - 1, int((y.float + 0.5) * s))
    for x in 0 ..< tw:
      let c = px[sy * w + min(w - 1, int((x.float + 0.5) * s))]
      let a = int(c shr 24) * alpha div 255
      result.px[y * tw + x] = (uint32(a) shl 24) or (c and 0xFFFFFF'u32)
  changed(result)

proc frameThumb(d: Doc; k: int): Bitmap =
  let key = d.frameKey(k)
  let ck = (cast[pointer](d), k)
  if tlThumbs.hasKey(ck) and tlThumbs[ck].key == key: return tlThumbs[ck].b
  if tlThumbs.len > 400: tlThumbs.clear()
  let px = d.frameComposite(k)
  result = smallOf(px, d.w, d.h, 64)
  tlThumbs[ck] = (key, result)

proc timelineStep(d: Doc) =
  ## (playing: the frames shown in turn, each as long as its delay; stopped at the end of the
  ## times it plays)
  if not tline.playing or d == nil or d.frames.len < 2: return
  let now = epochTime()
  let k = clamp(d.frameCur, 0, d.frames.high)
  let wait = max(20, d.frames[k].delay).float / 1000
  if now - tline.since >= wait:
    tline.since = now
    var nk = k + 1
    if nk > d.frames.high:
      nk = 0
      if d.animLoop == 1:
        tline.playing = false
        return
    d.showFrame(nk)
  wakeIn(20)

proc timelineBody() =
  let d = cur()
  if d == nil:
    label("(no image)", color = ui.theme.gray)
    return
  d.timelineStep()
  tlGen = $cast[int](d) & ":" & $d.historyAt & ":" & $d.historyStates.len
  if d.frames.len == 0:
    paragraph("No frames yet: the image as it is becomes the first. Change what shows in the next one -- " &
              "layers shown, hidden, moved -- and play them.", color = ui.theme.gray)
    row:
      if button("New Frame", w = dp(100)):
        d.layersChange("New Frame"):
          d.ensureFrames()
          d.addFrame()
      if button("Make Frames From Layers", w = dp(180)):
        d.layersChange("Make Frames From Layers"): d.framesFromLayers()
    return
  d.syncFrame()
  # play, stop, go through them
  row:
    if toolButton("|<", "First Frame"): d.showFrame(0)
    if toolButton("<", "Previous Frame"): d.showFrame(max(0, d.frameCur - 1))
    if toolButton(if tline.playing: "||" else: ">", if tline.playing: "Stop" else: "Play"):
      tline.playing = not tline.playing
      tline.since = epochTime()
      if tline.playing: wakeIn(20)
    if toolButton(">|", "Next Frame"): d.showFrame(min(d.frames.high, d.frameCur + 1))
    if toolButton(">>|", "Last Frame"): d.showFrame(d.frames.high)
  row:
    var lp = case d.animLoop
             of 1: 0
             of 3: 1
             else: 2
    if combo(["Once", "3 Times", "Forever"], lp, w = dp(90)):
      let v = [1, 3, 0][lp]
      d.layersChange("Looping Options"): d.animLoop = v
    discard checkbox("Onion Skin", tline.onion)
  # the frames side by side, as many as there is room for, the one shown among them
  let cellH = dp(62)
  let strip = place(0, cellH, fill = true)
  fill(strip, ui.theme.window)
  box(strip, ui.theme.shadow)
  let thH = cellH - FontH - dp(8)
  let thW = max(dp(24), thH * d.w div max(1, d.h))
  let cellW = thW + dp(8)
  let fit = max(1, (strip.w - dp(4)) div cellW)
  let first = clamp(d.frameCur - fit div 2, 0, max(0, d.frames.len - fit))
  for i in 0 ..< min(fit, d.frames.len - first):
    let k = first + i
    let c = rect(strip.x + dp(2) + i * cellW, strip.y + dp(2), cellW - dp(2), cellH - dp(4))
    let h = interact(idOf("tlframe" & $k), c)
    let on = k == d.frameCur
    if on: fill(c, ui.theme.select)
    let b = d.frameThumb(k)
    let tr0 = rect(c.x + dp(3), c.y + dp(2), thW, thH)
    fill(tr0, color(255, 255, 255))
    drawBitmap(tr0, b)
    box(tr0, ui.theme.shadow)
    let cap = $(k + 1) & "  " & (if d.frames[k].delay <= 0: "0" else: $d.frames[k].delay)
    text(c.x + dp(3), tr0.y + thH + dp(2), ellipsize(cap, c.w - dp(4)), if on: ui.theme.selectText else: ui.theme.text)
    if h.clicked:
      tline.playing = false
      d.showFrame(k)
    tooltip(tr("Frame ") & $(k + 1) & ": " & (if d.frames[k].delay <= 0: tr("no delay") else: $d.frames[k].delay & " ms"))
  # the frame shown: its delay; New, Delete, Tween; the rest
  let k = clamp(d.frameCur, 0, d.frames.high)
  row:
    label "Delay:"
    var dl = d.frames[k].delay
    if spin(dl, 0, 60000, w = dp(70), step = 10):
      let v = dl
      d.layersChange("Frame Delay"): d.frames[k].delay = v
    label "ms"
    if button("All Frames", w = dp(90)):
      let v = d.frames[k].delay
      d.layersChange("Frame Delay"):
        for f in d.frames.mitems: f.delay = v
  row:
    if button("New Frame", w = dp(90)):
      tline.playing = false
      d.layersChange("New Frame"): d.addFrame()
    if button("Delete", w = dp(70), enabled = d.frames.len > 0):
      tline.playing = false
      d.layersChange("Delete Frame"): d.deleteFrame(k)
    if button("Tween", w = dp(64), enabled = k < d.frames.high):
      tline.playing = false
      let n = max(1, tline.tween)
      d.layersChange("Tween"): d.tweenFrames(k, k + 1, n)
    spin(tline.tween, 1, 50, w = dp(52))
  row:
    if button("Flatten Frames Into Layers", w = dp(190)):
      tline.playing = false
      d.layersChange("Flatten Frames Into Layers"): d.flattenFramesIntoLayers()

proc timelineOverlay(dw: DocWin) =
  ## (onion skin: the frame before the one shown, faint over the image)
  let d = dw.doc
  if not tline.onion or tline.playing or d.frames.len < 2 or not panelShown("timeline"): return
  let k = d.frameCur - 1
  if k < 0: return
  tlGen = $cast[int](d) & ":" & $d.historyAt & ":" & $d.historyStates.len
  let key = $k & "/" & d.frameKey(k) & "/" & d.frameKey(d.frameCur)
  if tlOnion.key != key:
    # (only what the frame before has that the layers both frames show alike do not: what moved,
    # came or went there -- not over this frame's own)
    var prev = d.frameComposite(k)
    var same: seq[Layer]
    let fa = d.frames[k]
    let fb = d.frames[clamp(d.frameCur, 0, d.frames.high)]
    for L in d.layers:
      if not L.visible: continue
      var alike = L.group or L.adjust.kind.len > 0
      for x in fa.layers:
        if x.uid != L.uidOf: continue
        for y in fb.layers:
          if y.uid == x.uid and x.visible == y.visible and x.opacity == y.opacity and x.dx == y.dx and x.dy == y.dy:
            alike = true
      if alike: same.add L
    var base = newSeq[uint32](d.w * d.h)
    d.compositeInto(base, d.bounds, same)
    for i in 0 ..< min(prev.len, base.len):
      if prev[i] == base[i]: prev[i] = 0
    tlOnion = (key, smallOf(prev, d.w, d.h, 1024, alpha = 110))
  let v = dw.view
  let (x0, y0) = v.toScreen(d, 0, 0)
  let (x1, y1) = v.toScreen(d, d.w.float, d.h.float)
  drawBitmap(rect(x0, y0, x1 - x0, y1 - y0), tlOnion.b)

var
  tlSavePick = false           ## (File > Export > Save Animation's file picker open)
  tlSavePath = ""

proc startSaveAnimation() =
  ## (File > Export > Save Animation: where to, by the document's name)
  let d = cur()
  if d == nil: return
  tlSavePath = (if d.path.len > 0: d.path else: d.name).changeFileExt(".gif")
  tlSavePick = true

proc timelineDialogs() =
  ## (Save Animation: the frames as an animated GIF, WebP or PNG, by the name's ending)
  if filePicker(tlSavePick, tlSavePath, fmSave, ["*.gif", "*.webp", "*.png"], "Save Animation"):
    let d = cur()
    if d == nil: return
    var p = tlSavePath
    var ext = p.splitFile.ext.toLowerAscii
    if ext notin [".gif", ".webp", ".png"]:
      p.add ".gif"
      ext = ".gif"
    try:
      beginBusy("Saving " & p.extractFilename)
      try:
        case ext
        of ".webp":
          d.exportAnimation(p, proc (fr: seq[tuple[bmp: Bitmap; delayMs: int]]; loop: int): string =
            encodeWebpFrames(fr, loop))
        of ".png": d.exportAnimation(p, format = "apng")
        else: d.exportAnimation(p)
      finally: endBusy()
      rememberFile(p)
      status = tr("Saved the animation: ") & p.extractFilename & " (" & $max(1, d.frames.len) & tr(" frames") & ")"
    except CatchableError: status = tr("Could not save ") & p.extractFilename & ": " & getCurrentExceptionMsg()

# (included by photo.nim) The Channels panel's Split Channels -- each channel (and each saved
# selection) an image of its own in grays, named for it -- and Merge Channels: open gray images of
# one size put together as one in RGB, Lab or CMYK, a channel each. The engine is `splitChannels`
# and `mergeChannels` (retroui/photo).

var mergeBox: tuple[open: bool; mode: int; pick: array[4, int]]
  ## (Merge Channels: RGB 0, Lab 1, CMYK 2; the image for each channel, by its place in `docs`)

proc splitChannelsNow() =
  let d = cur()
  if d == nil: return
  if d.depth != 8:
    status = tr("Split Channels: 8 bits a channel only")
    return
  let parts = d.splitChannels()
  for (name, px) in parts:
    let n = newUntitled(d.w, d.h, white, d.dpi, cmGray, name)
    n.layers[0].px = px
    inc n.layers[0].ver
    n.markAll()
    n.modified = true
    addDoc(n)
  status = $parts.len & tr(" images made, a channel each (the image itself stays open)")

proc grayDocs(): seq[int] =
  ## (the open gray images, by their place in `docs`)
  for i, dw in docs:
    if dw.doc.mode == cmGray and dw.doc.layers.len > 0: result.add i

proc startMergeChannels() =
  let g = grayDocs()
  if g.len < 3:
    status = tr("Merge Channels: open three gray images of one size first (four for CMYK)")
    return
  mergeBox.open = true
  mergeBox.mode = 0
  for k in 0 .. 3: mergeBox.pick[k] = g[min(k, g.high)]

proc mergeChannelsDialog() =
  if not mergeBox.open: return
  let g = grayDocs()
  if g.len == 0:
    mergeBox.open = false
    return
  var names: seq[string]
  for i in g: names.add docs[i].doc.name
  var ok = false
  dialog(mergeBox.open, "Merge Channels", 400):
    row([110, -1]):
      label "Mode:"
      discard combo(["RGB Color", "Lab Color", "CMYK Color"], mergeBox.mode, w = dp(160))
    let chans = case mergeBox.mode
                of 1: @["Lightness:", "a:", "b:"]
                of 2: @["Cyan:", "Magenta:", "Yellow:", "Black:"]
                else: @["Red:", "Green:", "Blue:"]
    for k, cap in chans:
      row([110, -1]):
        label cap
        var at = max(0, g.find(mergeBox.pick[k]))
        if combo(names, at, w = dp(240)): mergeBox.pick[k] = g[at]
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): mergeBox.open = false
  if ok:
    mergeBox.open = false
    let mode = [cmRGB, cmLab, cmCMYK][clamp(mergeBox.mode, 0, 2)]
    let n = if mode == cmCMYK: 4 else: 3
    var grays: seq[seq[uint32]]
    var w, h = -1
    for k in 0 ..< n:
      let i = mergeBox.pick[k]
      if i notin 0 .. docs.high: return
      let src = docs[i].doc
      if w < 0: (w, h) = (src.w, src.h)
      if src.w != w or src.h != h:
        status = tr("Merge Channels: the images must be the same size")
        return
      src.updateComposite()
      grays.add src.compCopy
    let px = mergeChannels(grays, mode)
    if px.len == 0: return
    let nd = newUntitled(w, h, white, docs[mergeBox.pick[0]].doc.dpi, mode)
    nd.layers[0].px = px
    inc nd.layers[0].ver
    nd.markAll()
    nd.modified = true
    addDoc(nd)
    status = tr("Channels merged: ") & nd.name

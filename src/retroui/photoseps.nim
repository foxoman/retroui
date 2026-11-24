## A document's inks seen before it is printed: Separations Preview -- the plates it makes
## (`retroui/inks`: the four process inks and its spot inks, as the Ink Manager says), each
## alone or some together, how much ink is at a point -- and Overprint Preview: the layers
## that overprint (`LayerAttrs.overprintFill`) printed over what is under them, their inks
## mixed with those under instead of knocking them out.
##
## A spot ink is where a shape is filled with it (`ShapePaint.spot`: the layer's own pixels,
## by its tint); what is under a spot is knocked out unless the shape overprints. The pictures are worked out once for each change of the
## document (on all the cores) and read by the views as they draw.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import photo, parallel

proc docPlates*(d: Doc): seq[Plate] =
  ## The plates the document makes, as the Ink Manager says.
  plates(d.spotInks, d.inkSettings)

proc spotLayers(d: Doc): seq[tuple[layer: Layer; spot: int; tint: int]] =
  for L in d.layers:
    if not L.visible or not L.isShape or L.attrs.nonprinting: continue
    let f = L.shape.fill
    if f.kind != spColor or f.spot.len == 0: continue
    let k = d.spotInks.findSpot(f.spot)
    if k >= 0: result.add (L, k, (if f.tint in 1 .. 99: f.tint else: 100))

proc spotPlanes*(d: Doc): ptr seq[seq[uint8]] =
  ## Each spot ink's amounts over the image (0..255, `d.w` x `d.h`; empty: none of it):
  ## made again when the document changed.
  if d.sepCache.ver == d.ver and d.sepCache.planes.len == d.spotInks.len: return addr d.sepCache.planes
  var planes = newSeq[seq[uint8]](d.spotInks.len)
  let n = d.w * d.h
  for (L, k, tint) in d.spotLayers:
    if L.px.len != n: continue
    if planes[k].len == 0: planes[k] = newSeq[uint8](n)
    let pl = cast[ptr UncheckedArray[uint8]](addr planes[k][0])
    let lp = cast[ptr UncheckedArray[uint32]](addr L.px[0])
    let op = L.opacity
    let tn = tint
    parallelFor(n, proc (lo, hi: int) =
      for i in lo ..< hi:
        let a = int(lp[i] shr 24) * op div 100 * tn div 100
        if a > 0: pl[i] = uint8(min(255, int(pl[i]) + a - int(pl[i]) * a div 255))
    , grain = 16384)
  d.sepCache = (d.ver, move(planes))
  addr d.sepCache.planes

proc knockedOut(d: Doc; x, y: int; planes: ptr seq[seq[uint8]]): int =
  ## (how much of a point a spot that does not overprint covers: what is under it is not printed)
  for (L, k, _) in d.spotLayers:
    if L.attrs.overprintFill: continue
    if planes[k].len > 0: result = max(result, int(planes[k][y * d.w + x]))

proc inkAmountsAt*(d: Doc; x, y: int; color: uint32; ps: openArray[Plate]): seq[int] =
  ## How much of each plate's ink (0..255) point `x`, `y` of the image gets, `color` the picture
  ## there: its process inks -- those under a spot that knocks them out taken away -- and its
  ## spot inks.
  let planes = d.spotPlanes
  var amt = newSeq[uint8](d.spotInks.len)
  var process = inkOf(color)
  if x >= 0 and y >= 0 and x < d.w and y < d.h:
    for k in 0 ..< amt.len:
      if planes[k].len > 0: amt[k] = planes[k][y * d.w + x]
    let ko = d.knockedOut(x, y, planes)
    if ko > 0:
      for n in 0 .. 3: process[n] = uint8(int(process[n]) * (255 - ko) div 255)
  inkAmounts(ps, process, amt, d.spotInks)

proc separationsOn*(d: Doc): bool =
  ## Separations Preview is on.
  d.sepView.on

proc shownPlates*(d: Doc; ps: openArray[Plate]): seq[bool] =
  ## Which of the plates Separations Preview shows.
  for p in ps: result.add p.name notin d.sepView.hidden

proc overprintPicture*(d: Doc): ptr seq[uint32] =
  ## Overprint Preview: the image with its layers' inks mixed bottom to top, as a press prints
  ## them -- each layer's process inks over those under by its pixels' alpha, opacity and mask,
  ## an overprinting one's zero inks leaving those under it, a spot ink's color over what is
  ## under it (knocked out unless it overprints) -- seen as the inks print (nil when the image
  ## is not ready). Made again when the document changed.
  let n = d.w * d.h
  if d.opCache.ver == d.ver and d.opCache.px.len == n: return addr d.opCache.px
  var ink = newSeq[uint32](n)             # (C M Y K a byte each)
  var spotOver = newSeq[uint32](n)        # (the spot inks' color over the inks, and how much)
  let ip = cast[ptr UncheckedArray[uint32]](addr ink[0])
  let sp = cast[ptr UncheckedArray[uint32]](addr spotOver[0])
  for L in d.layers:
    if not L.visible or L.group or L.attrs.nonprinting or L.adjust.kind.len > 0: continue
    if L.px.len != n or L.opacity <= 0: continue
    let lp = cast[ptr UncheckedArray[uint32]](addr L.px[0])
    let mp = if L.mask != nil and not L.maskOff and L.mask.px.len == n:
               cast[ptr UncheckedArray[uint32]](addr L.mask.px[0]) else: nil
    let op = L.opacity * L.fill div 100
    let over = L.attrs.overprintFill
    var spotCol = 0'u32
    var spotTint = 0
    if L.isShape and L.shape.fill.kind == spColor and L.shape.fill.spot.len > 0:
      let k = d.spotInks.findSpot(L.shape.fill.spot)
      if k >= 0 and not d.inkSettings.toProcessOn(L.shape.fill.spot):
        spotCol = d.spotInks[k].color
        spotTint = if L.shape.fill.tint in 1 .. 99: L.shape.fill.tint else: 100
    parallelFor(n, proc (lo, hi: int) =
      for i in lo ..< hi:
        var a = int(lp[i] shr 24) * op div 100
        if mp != nil: a = a * int(mp[i] and 255) div 255
        if a <= 0: continue
        let u = ip[i]
        let under: Ink = [uint8(u shr 24), uint8((u shr 16) and 255), uint8((u shr 8) and 255), uint8(u and 255)]
        if spotCol != 0:
          # (a spot ink: its own plate -- what is under it stays when it overprints, else goes)
          let t = a * spotTint div 100
          if not over:
            var o: Ink
            for c in 0 .. 3: o[c] = uint8(int(under[c]) * (255 - t) div 255)
            ip[i] = (uint32(o[0]) shl 24) or (uint32(o[1]) shl 16) or (uint32(o[2]) shl 8) or uint32(o[3])
          let prev = int(sp[i] shr 24)
          let tot = min(255, prev + t - prev * t div 255)
          sp[i] = (uint32(tot) shl 24) or (spotCol and 0xFFFFFF'u32)
          continue
        let o = overprinted(under, inkOf(lp[i]), a, over)
        ip[i] = (uint32(o[0]) shl 24) or (uint32(o[1]) shl 16) or (uint32(o[2]) shl 8) or uint32(o[3])
        if not over and sp[i] != 0:
          # (process inks that knock out: the spot under them gone where they are)
          let prev = int(sp[i] shr 24) * (255 - a) div 255
          sp[i] = (uint32(prev) shl 24) or (sp[i] and 0xFFFFFF'u32)
    , grain = 8192)
  var o = newSeq[uint32](n)
  let opx = cast[ptr UncheckedArray[uint32]](addr o[0])
  discard printedFast(0, 0, 0, 0)        # (its table made here, before the cores read it)
  parallelFor(n, proc (lo, hi: int) =
    for i in lo ..< hi:
      let v = ip[i]
      var c = printedFast(int(v shr 24), int((v shr 16) and 255), int((v shr 8) and 255), int(v and 255))
      let s = sp[i]
      let t = int(s shr 24)
      if t > 0:
        # (the spot ink over the process inks: its color filters theirs)
        var r = int((c shr 16) and 255)
        var g = int((c shr 8) and 255)
        var b = int(c and 255)
        r = r * (255 * 255 - t * (255 - int((s shr 16) and 255))) div (255 * 255)
        g = g * (255 * 255 - t * (255 - int((s shr 8) and 255))) div (255 * 255)
        b = b * (255 * 255 - t * (255 - int(s and 255))) div (255 * 255)
        c = (uint32(r) shl 16) or (uint32(g) shl 8) or uint32(b)
      opx[i] = 0xFF000000'u32 or (c and 0xFFFFFF'u32)
  , grain = 16384)
  d.opCache = (d.ver, move(o))
  addr d.opCache.px

# ---- for a view drawing every pixel: no allocation a point ------------------------------------

const MaxSepInks = 16

type
  SepCtx* = object
    ## (Separations Preview made ready for a view: `sepPixel` for each point)
    on*: bool
    n, nsp, nko, nshown, one: int
    black: bool
    plateColor: array[MaxSepInks, uint32]
    shown: array[MaxSepInks, bool]
    process: array[MaxSepInks, int]
    spPlane: array[MaxSepInks, ptr UncheckedArray[uint8]]
    spPlate: array[MaxSepInks, int]
    spCmyk: array[MaxSepInks, Ink]
    ko: array[MaxSepInks, ptr UncheckedArray[uint8]]

proc sepContext*(d: Doc): SepCtx =
  ## Separations Preview of `d` made ready (`on` false when it is off).
  if not d.sepView.on: return
  result.on = true
  discard inkOf(0xFFFFFFFF'u32)   # (the ink tables made here, on all the cores -- not by the view's
                                  # threads, one at a time, as each asks for its first point)
  let ps = d.docPlates
  result.n = min(ps.len, MaxSepInks)
  result.black = d.sepView.black
  result.one = -1
  for k in 0 ..< result.n:
    result.plateColor[k] = ps[k].color
    result.shown[k] = ps[k].name notin d.sepView.hidden
    result.process[k] = ps[k].process
    if result.shown[k]:
      inc result.nshown
      result.one = k
  let planes = d.spotPlanes
  result.nsp = min(d.spotInks.len, MaxSepInks)
  for s in 0 ..< result.nsp:
    result.spPlane[s] = if planes[s].len > 0: cast[ptr UncheckedArray[uint8]](addr planes[s][0]) else: nil
    result.spPlate[s] = ps.plateOfSpot(s)
    result.spCmyk[s] = d.spotInks[s].cmyk
  for (L, k, _) in d.spotLayers:
    if not L.attrs.overprintFill and k < result.nsp and result.spPlane[k] != nil and result.nko < MaxSepInks:
      # (a spot that knocks out what is under it -- not twice for one ink)
      var dup = false
      for q in 0 ..< result.nko:
        if result.ko[q] == result.spPlane[k]: dup = true
      if not dup:
        result.ko[result.nko] = result.spPlane[k]
        inc result.nko

proc sepPixel*(c: ptr SepCtx; p: uint32; i: int): uint32 {.inline.} =
  ## How image point `i` (y * w + x), `p` its color, looks with the plates shown.
  var amt: array[MaxSepInks, int]
  let ink = inkOf(p)
  var cm = [int(ink[0]), int(ink[1]), int(ink[2]), int(ink[3])]
  var ko = 0
  for q in 0 ..< c.nko: ko = max(ko, int(c.ko[q][i]))
  if ko > 0:
    for n in 0 .. 3: cm[n] = cm[n] * (255 - ko) div 255
  for s in 0 ..< c.nsp:
    if c.spPlane[s] == nil: continue
    let a = int(c.spPlane[s][i])
    if a == 0: continue
    let k = c.spPlate[s]
    if k >= 0: amt[k] = min(255, amt[k] + a)
    else:
      for n in 0 .. 3:
        let v = int(c.spCmyk[s][n]) * a div 255
        cm[n] = cm[n] + v - cm[n] * v div 255
  for k in 0 ..< c.n:
    if c.process[k] >= 0: amt[k] = clamp(cm[c.process[k]], 0, 255)
  if c.nshown == 1 and c.black:
    let v = uint32(255 - amt[c.one])
    return 0xFF000000'u32 or (v shl 16) or (v shl 8) or v
  var r, g, b = 255
  for k in 0 ..< c.n:
    let a = amt[k]
    if not c.shown[k] or a == 0: continue
    let col = c.plateColor[k]
    r = r * (255 * 255 - a * (255 - int((col shr 16) and 255))) div (255 * 255)
    g = g * (255 * 255 - a * (255 - int((col shr 8) and 255))) div (255 * 255)
    b = b * (255 * 255 - a * (255 - int(col and 255))) div (255 * 255)
  0xFF000000'u32 or (uint32(r) shl 16) or (uint32(g) shl 8) or uint32(b)

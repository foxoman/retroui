## Everyday edits in one step, as Photoshop's Quick Actions and the
## automations of File > Automate: Blur Background and Black & White
## Background (the subject found, a layer with its mask over the rest),
## Frequency Separation for retouching skin, Select > Focus Area, Crop and
## Straighten Photos (several photos scanned at once, each cut out and
## made straight), Match Color, and color themes (harmonies) for design.
##
## ```nim
## d.beginStep("Blur Background")
## discard d.blurBackground(amount = 60)        # a new masked layer, editable
## d.endStep()
## for im in findPhotos(scan): echo im.w, " x ", im.h   # each photo of a scan
## let five = colorTheme(0xFF2A9D8F'u32, chSplitComplementary)
## ```

import std/[math, algorithm]
import photo, photofx, photosmart

# ---- masks ----------------------------------------------------------------------------------------------

proc grayImg(m: openArray[uint8]; w, h: int): Img =
  result = newImg(w, h)
  for i in 0 ..< w * h: result.px[i] = grayPx(int(m[i]))

proc featherMask*(m: openArray[uint8]; w, h: int; radius: float): seq[uint8] =
  ## A mask's edges softened by `radius` pixels.
  result = newSeq[uint8](w * h)
  if radius <= 0.3:
    for i in 0 ..< w * h: result[i] = m[i]
    return
  let b = gaussianBlurImg(grayImg(m, w, h), radius)
  for i in 0 ..< w * h: result[i] = uint8(b.px[i] and 255)

proc inverted(m: openArray[uint8]): seq[uint8] =
  result = newSeq[uint8](m.len)
  for i, v in m: result[i] = 255'u8 - v

proc found(m: openArray[uint8]): bool =
  for v in m:
    if v >= 128: return true

proc maskedLayer(d: Doc; name: string; px: seq[uint32]; mask: seq[uint8]): Layer =
  ## (a new layer on top, its pixels and its mask)
  d.touchLayers()
  result = d.addLayer(name, above = d.layers.high)
  result.px = px
  inc result.ver
  d.addLayerMask(mfRevealAll, d.layers.find(result))
  if result.mask != nil:
    for i in 0 ..< mask.len: result.mask.px[i] = grayPx(int(mask[i]))
    inc result.mask.ver
  d.cur = d.layers.find(result)
  d.editMask = false
  d.markAll()

# ---- Quick Actions --------------------------------------------------------------------------------------

proc blurBackground*(d: Doc; amount = 50; subject: seq[uint8] = @[]): Layer =
  ## Quick Action > Blur Background: the picture as it looks, blurred, on a
  ## layer of its own on top whose mask hides it over the subject (found
  ## when `subject` is empty) -- so the subject stays sharp, and the blur
  ## can be painted out or in. The subject's colors are kept out of the
  ## blur (no halo round it). `amount` 1..100. Nil when no subject is found.
  ## Undoable in a step.
  let m = if subject.len == d.w * d.h: subject else: d.selectSubject()
  if not found(m): return nil
  let px = d.flattened(0xFFFFFFFF'u32)
  let radius = max(2.0, min(d.w, d.h).float * clamp(amount, 1, 100).float / 2600)
  # (blurred by what is behind the subject only: its alpha the weight)
  let hard = featherMask(m, d.w, d.h, radius * 0.15)
  var weighted = newImg(d.w, d.h)
  for i in 0 ..< d.w * d.h:
    let a = 255 - int(hard[i])
    weighted.px[i] = (px[i] and 0xFFFFFF'u32) or (uint32(a) shl 24)
  let b = gaussianBlurImg(weighted, radius)
  var o = newSeq[uint32](d.w * d.h)
  for i in 0 ..< o.len:
    o[i] = if (b.px[i] shr 24) == 0: px[i] else: b.px[i] or 0xFF000000'u32
  d.maskedLayer("Blurred Background", o, featherMask(inverted(m), d.w, d.h, 2))

proc bwBackground*(d: Doc; subject: seq[uint8] = @[]): Layer =
  ## Quick Action > Make B&W Background (a color pop): the picture as it
  ## looks, in black and white, on a layer on top whose mask leaves the
  ## subject in color. Nil when no subject is found. Undoable in a step.
  let m = if subject.len == d.w * d.h: subject else: d.selectSubject()
  if not found(m): return nil
  var px = d.flattened(0xFFFFFFFF'u32)
  for p in px.mitems:
    let v = lumaOf(p)
    p = grayPx(v)
  d.maskedLayer("Black & White Background", px, featherMask(inverted(m), d.w, d.h, 1.5))

proc frequencySeparation*(d: Doc; L: Layer; radius = 6.0): Layer =
  ## Frequency Separation, as retouchers make it: the layer's colors and
  ## tones blurred on "Low Frequency" (smooth the skin's tone there) and its
  ## texture on "High Frequency" above it in Linear Light (heal the pores
  ## there), together in a group that looks as the layer did. Undoable in a
  ## step. Nil when `L` has no pixels.
  if L == nil or L.px.len != d.w * d.h or L.group: return nil
  let src = Img(w: d.w, h: d.h, px: L.px)
  let low = gaussianBlurImg(src, max(0.5, radius))
  var high = newSeq[uint32](d.w * d.h)
  for i in 0 ..< high.len:
    let a = L.px[i]
    let b = low.px[i]
    template ch(s: int): int = clamp((int((a shr s) and 255) - int((b shr s) and 255)) div 2 + 128, 0, 255)
    high[i] = (a and 0xFF000000'u32) or (uint32(ch(16)) shl 16) or (uint32(ch(8)) shl 8) or uint32(ch(0))
  d.touchLayers()
  let k = d.layers.find(L)
  let lowL = d.addLayer("Low Frequency", above = k)
  lowL.px = low.px
  inc lowL.ver
  let highL = d.addLayer("High Frequency", above = d.layers.find(lowL))
  highL.px = high
  highL.mode = bmLinearLight
  inc highL.ver
  result = d.groupLayers(@[d.layers.find(lowL), d.layers.find(highL)], "Frequency Separation")
  d.cur = d.layers.find(lowL)
  d.markAll()

proc focusArea*(d: Doc; L: Layer; range = 50; noise = 0; soften = true): seq[uint8] =
  ## Select > Focus Area: what is in focus (sharp detail) in the layer, as a
  ## mask 0..255. `range` 0..100: how much of what is less sharp it takes
  ## too; `noise`: how much fine grain is ignored.
  let w = d.w
  let h = d.h
  result = newSeq[uint8](w * h)
  if L == nil or L.px.len != w * h: return
  # the detail: how much each pixel differs from its neighbors (a Laplacian)
  var src = Img(w: w, h: h, px: L.px)
  if noise > 0: src = gaussianBlurImg(src, noise.float / 25)
  var e = newSeq[float32](w * h)
  for y in 1 ..< h - 1:
    for x in 1 ..< w - 1:
      let i = y * w + x
      let c = lumaOf(src.px[i]) * 4 - lumaOf(src.px[i - 1]) - lumaOf(src.px[i + 1]) - lumaOf(src.px[i - w]) -
              lumaOf(src.px[i + w])
      e[i] = float32(c * c)
  # spread over a neighborhood (focus is a region, not single edges)
  let r = max(2.0, min(w, h).float / 60)
  var ei = newImg(w, h)
  var mx = 1e-6'f32
  for v in e: mx = max(mx, v)
  for i in 0 ..< w * h:
    let v = int(sqrt(e[i] / mx) * 255 + 0.5)
    ei.px[i] = grayPx(clamp(v, 0, 255))
  let spread = gaussianBlurImg(ei, r)
  # where the detail is: above a threshold set by the range (Otsu's, moved)
  var hist: array[256, int]
  for p in spread.px: inc hist[int(p and 255)]
  var total = w * h
  var sumAll = 0.0
  for v in 0 .. 255: sumAll += v.float * hist[v].float
  var wB = 0
  var sumB = 0.0
  var best = 0.0
  var t = 128
  for v in 0 .. 255:
    wB += hist[v]
    if wB == 0: continue
    let wF = total - wB
    if wF == 0: break
    sumB += v.float * hist[v].float
    let mB = sumB / wB.float
    let mF = (sumAll - sumB) / wF.float
    let between = wB.float * wF.float * (mB - mF) * (mB - mF)
    if between > best:
      best = between
      t = v
  let thr = clamp(int(t.float * (1.5 - clamp(range, 0, 100).float / 100)), 1, 254)
  for i in 0 ..< w * h:
    result[i] = if int(spread.px[i] and 255) >= thr: 255 else: 0
  if soften:
    # (the outline follows the picture's edges)
    result = refineEdge(Img(w: w, h: h, px: L.px), result, radius = max(2.0, r), colorAware = true)

# ---- Crop and Straighten Photos -------------------------------------------------------------------------

type FoundPhoto* = object
  ## A photo found on a scan: its middle, size and turn (degrees, clockwise).
  cx*, cy*: float          ## its middle (the scan's pixels)
  w*, h*: float            ## its size, before it is turned
  angle*: float            ## how far it is turned (degrees, clockwise)

proc cross(o, a, b: (float, float)): float =
  (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

proc hull(pts: seq[(float, float)]): seq[(float, float)] =
  var p = pts
  p.sort(proc (a, b: (float, float)): int = cmp(a[0], b[0]) * 2 + cmp(a[1], b[1]))
  if p.len < 3: return p
  var lower, upper: seq[(float, float)]
  for q in p:
    while lower.len >= 2 and cross(lower[^2], lower[^1], q) <= 0: lower.setLen(lower.len - 1)
    lower.add q
  for k in countdown(p.high, 0):
    let q = p[k]
    while upper.len >= 2 and cross(upper[^2], upper[^1], q) <= 0: upper.setLen(upper.len - 1)
    upper.add q
  lower.setLen(lower.len - 1)
  upper.setLen(upper.len - 1)
  lower & upper

proc minRect(h: seq[(float, float)]): FoundPhoto =
  ## The smallest rectangle round a convex polygon (one of its sides lies
  ## on a side of the polygon).
  var best = Inf
  for i in 0 ..< h.len:
    let a = h[i]
    let b = h[(i + 1) mod h.len]
    let len = hypot(b[0] - a[0], b[1] - a[1])
    if len < 1e-9: continue
    let ux = (b[0] - a[0]) / len
    let uy = (b[1] - a[1]) / len
    var lo0, lo1 = Inf
    var hi0, hi1 = -Inf
    for q in h:
      let s = q[0] * ux + q[1] * uy
      let t = -q[0] * uy + q[1] * ux
      lo0 = min(lo0, s); hi0 = max(hi0, s); lo1 = min(lo1, t); hi1 = max(hi1, t)
    let area = (hi0 - lo0) * (hi1 - lo1)
    if area < best:
      best = area
      let ms = (lo0 + hi0) / 2
      let mt = (lo1 + hi1) / 2
      result.cx = ms * ux - mt * uy
      result.cy = ms * uy + mt * ux
      result.w = hi0 - lo0
      result.h = hi1 - lo1
      result.angle = arctan2(uy, ux) * 180 / PI
  # (the turn kept small: -45..45, its sides swapped as needed)
  while result.angle > 45:
    result.angle -= 90
    swap(result.w, result.h)
  while result.angle <= -45:
    result.angle += 90
    swap(result.w, result.h)

proc findPhotos*(im: Img; tolerance = 24; minPart = 0.01): seq[FoundPhoto] =
  ## File > Automate > Crop and Straighten Photos: the photos on a scan (on
  ## the scanner's plain background: the color its edges have), each as a
  ## turned rectangle, biggest first. `minPart`: the least part of the scan
  ## a photo is.
  if im.w < 8 or im.h < 8: return
  # worked out on a small copy
  let f = max(1, max(im.w, im.h) div 700)
  let w = max(1, im.w div f)
  let h = max(1, im.h div f)
  let small = resample(im.px, im.w, im.h, w, h, rsBilinear)
  # the background: the median of the edges' colors
  var rs, gs, bs: seq[int]
  for x in 0 ..< w:
    for y in [0, 1, h - 2, h - 1]:
      let p = small[clamp(y, 0, h - 1) * w + x]
      rs.add int((p shr 16) and 255); gs.add int((p shr 8) and 255); bs.add int(p and 255)
  for y in 0 ..< h:
    for x in [0, 1, w - 2, w - 1]:
      let p = small[y * w + clamp(x, 0, w - 1)]
      rs.add int((p shr 16) and 255); gs.add int((p shr 8) and 255); bs.add int(p and 255)
  rs.sort(); gs.sort(); bs.sort()
  let (br, bg, bb) = (rs[rs.len div 2], gs[gs.len div 2], bs[bs.len div 2])
  var fg = newSeq[bool](w * h)
  for i in 0 ..< w * h:
    let p = small[i]
    let dr = int((p shr 16) and 255) - br
    let dg = int((p shr 8) and 255) - bg
    let db = int(p and 255) - bb
    fg[i] = max(abs(dr), max(abs(dg), abs(db))) > tolerance
  # closed (small holes in a photo filled), then opened (specks of dust gone)
  proc grow(m: seq[bool]; on: bool): seq[bool] =
    result = m
    for y in 0 ..< h:
      for x in 0 ..< w:
        if m[y * w + x] == on: continue
        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
          let xx = x + dx
          let yy = y + dy
          if xx >= 0 and yy >= 0 and xx < w and yy < h and m[yy * w + xx] == on:
            result[y * w + x] = on
            break
  for _ in 0 .. 1: fg = grow(fg, true)
  for _ in 0 .. 3: fg = grow(fg, false)
  for _ in 0 .. 1: fg = grow(fg, true)
  # the parts, each one photo
  var lab = newSeq[int32](w * h)
  var n = 0'i32
  var stack: seq[int]
  for s in 0 ..< w * h:
    if not fg[s] or lab[s] != 0: continue
    inc n
    var pts: seq[(float, float)]
    stack.setLen(0)
    stack.add s
    lab[s] = n
    var area = 0
    while stack.len > 0:
      let i = stack.pop()
      inc area
      let x = i mod w
      let y = i div w
      var edge = false
      for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
        let xx = x + dx
        let yy = y + dy
        if xx < 0 or yy < 0 or xx >= w or yy >= h or not fg[yy * w + xx]:
          edge = true
          continue
        let j = yy * w + xx
        if lab[j] == 0:
          lab[j] = n
          stack.add j
      if edge:
        for (ox, oy) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)]:
          pts.add ((x.float + ox) * f.float, (y.float + oy) * f.float)
    if area.float < minPart * (w * h).float: continue
    var r = minRect(hull(pts))
    # (in a little from the edge: no background left round the photo)
    r.w = max(1.0, r.w - 2 * f.float)
    r.h = max(1.0, r.h - 2 * f.float)
    result.add r
  result.sort(proc (a, b: FoundPhoto): int = cmp(b.w * b.h, a.w * a.h))

proc cutPhoto*(im: Img; p: FoundPhoto): Img =
  ## A photo found on a scan (`findPhotos`), cut out and made straight.
  let w = max(1, int(round(p.w)))
  let h = max(1, int(round(p.h)))
  result = newImg(w, h)
  let a = p.angle * PI / 180
  let (ca, sa) = (cos(a), sin(a))
  for y in 0 ..< h:
    for x in 0 ..< w:
      let u = x.float + 0.5 - w.float / 2
      let v = y.float + 0.5 - h.float / 2
      let sx = p.cx + u * ca - v * sa - 0.5
      let sy = p.cy + u * sa + v * ca - 0.5
      let x0 = clamp(int(floor(sx)), 0, im.w - 1)
      let y0 = clamp(int(floor(sy)), 0, im.h - 1)
      let x1 = min(x0 + 1, im.w - 1)
      let y1 = min(y0 + 1, im.h - 1)
      let fx = clamp(sx - x0.float, 0.0, 1.0)
      let fy = clamp(sy - y0.float, 0.0, 1.0)
      var acc: array[4, float]
      for (xx, yy, wt) in [(x0, y0, (1 - fx) * (1 - fy)), (x1, y0, fx * (1 - fy)), (x0, y1, (1 - fx) * fy),
                           (x1, y1, fx * fy)]:
        let c = im.px[yy * im.w + xx]
        for k in 0 .. 3: acc[k] += float((c shr (24 - 8 * k)) and 255) * wt
      result.px[y * w + x] = argb(int(acc[0] + 0.5), int(acc[1] + 0.5), int(acc[2] + 0.5), int(acc[3] + 0.5))

# ---- color themes ---------------------------------------------------------------------------------------

type ColorHarmony* = enum
  ## The rules of a color theme, as Adobe Color's.
  chAnalogous = "Analogous", chMonochromatic = "Monochromatic", chTriad = "Triad",
  chComplementary = "Complementary", chSplitComplementary = "Split Complementary", chSquare = "Square",
  chCompound = "Compound", chShades = "Shades"

proc toHsv(c: uint32): (float, float, float) =
  let r = float((c shr 16) and 255) / 255
  let g = float((c shr 8) and 255) / 255
  let b = float(c and 255) / 255
  let mx = max(r, max(g, b))
  let mn = min(r, min(g, b))
  let dd = mx - mn
  var hh = 0.0
  if dd > 1e-9:
    if mx == r: hh = 60 * (((g - b) / dd) mod 6)
    elif mx == g: hh = 60 * ((b - r) / dd + 2)
    else: hh = 60 * ((r - g) / dd + 4)
  if hh < 0: hh += 360
  (hh, (if mx > 0: dd / mx else: 0.0), mx)

proc fromHsv(h, s, v: float): uint32 =
  let hh = ((h mod 360) + 360) mod 360
  let s = clamp(s, 0.0, 1.0)
  let v = clamp(v, 0.0, 1.0)
  let c = v * s
  let x = c * (1 - abs(((hh / 60) mod 2) - 1))
  let m = v - c
  var (r, g, b) = (0.0, 0.0, 0.0)
  case int(hh / 60)
  of 0: (r, g, b) = (c, x, 0.0)
  of 1: (r, g, b) = (x, c, 0.0)
  of 2: (r, g, b) = (0.0, c, x)
  of 3: (r, g, b) = (0.0, x, c)
  of 4: (r, g, b) = (x, 0.0, c)
  else: (r, g, b) = (c, 0.0, x)
  argb(255, int((r + m) * 255 + 0.5), int((g + m) * 255 + 0.5), int((b + m) * 255 + 0.5))

proc colorTheme*(base: uint32; rule: ColorHarmony): array[5, uint32] =
  ## Five colors that go together by `rule`, the base color in the middle
  ## (as Adobe Color makes a theme).
  let (h, s, v) = toHsv(base)
  let s2 = max(0.15, s)
  let v2 = max(0.25, v)
  result[2] = base or 0xFF000000'u32
  case rule
  of chAnalogous:
    for k, dh in [-40.0, -20, 0, 20, 40]:
      if k != 2: result[k] = fromHsv(h + dh, s2 * (if k mod 2 == 0: 0.9 else: 1.0), v2 * (if k mod 2 == 0: 1.0 else: 0.85))
  of chMonochromatic:
    for k, (ds, dv) in [(0.0, -0.35), (-0.3, 0.0), (0.0, 0.0), (0.0, 0.25), (-0.5, 0.15)]:
      if k != 2: result[k] = fromHsv(h, s2 + ds, v2 + dv)
  of chTriad:
    for k, (dh, dv) in [(120.0, 0.0), (120.0, -0.3), (0.0, 0.0), (240.0, -0.3), (240.0, 0.0)]:
      if k != 2: result[k] = fromHsv(h + dh, s2, v2 + dv)
  of chComplementary:
    for k, (dh, ds, dv) in [(0.0, 0.0, -0.3), (0.0, -0.4, 0.15), (0.0, 0.0, 0.0), (180.0, 0.0, 0.0),
                           (180.0, 0.0, -0.3)]:
      if k != 2: result[k] = fromHsv(h + dh, s2 + ds, v2 + dv)
  of chSplitComplementary:
    for k, (dh, dv) in [(150.0, 0.0), (150.0, -0.3), (0.0, 0.0), (210.0, -0.3), (210.0, 0.0)]:
      if k != 2: result[k] = fromHsv(h + dh, s2, v2 + dv)
  of chSquare:
    for k, dh in [90.0, 180, 0, 270, 45]:
      if k != 2: result[k] = fromHsv(h + dh, s2, v2 * (if k == 4: 0.75 else: 1.0))
  of chCompound:
    for k, (dh, ds, dv) in [(30.0, 0.0, 0.0), (30.0, -0.2, -0.3), (0.0, 0.0, 0.0), (165.0, 0.0, -0.2),
                           (150.0, 0.0, 0.0)]:
      if k != 2: result[k] = fromHsv(h + dh, s2 + ds, v2 + dv)
  of chShades:
    for k, dv in [-0.45, -0.25, 0.0, 0.15, 0.3]:
      if k != 2: result[k] = fromHsv(h, s, v2 + dv)

## Today's Photoshop features, offline (no cloud, no generative AI): Layer
## Cleanup, Harmonize with a shadow, Colorize from color hints,
## Content-Aware Expand, and artboards. Each works on a `Doc` inside an
## undo step (`beginStep` ... `endStep`).
##
## ```nim
## d.beginStep("Layer Cleanup")
## let rep = d.cleanupLayers()
## d.endStep()
## ```

import std/[math, strutils]
import photo, photofx, photosmart, photoneural, photoshapes, gfx, textengine

# ---- Layer Cleanup -------------------------------------------------------------------------------------------------

type CleanupReport* = object
  ## What `cleanupLayers` did.
  emptyRemoved*, hiddenRemoved*, groupsRemoved*, renamed*: int
    ## how many empty layers, hidden layers and empty groups it removed, and
    ## how many layers it named after what they hold

proc isEmptyLayer*(d: Doc; L: Layer): bool =
  ## A layer of pixels with nothing in it (all transparent).
  if L.group or L.background or L.adjust.kind.len > 0 or L.isText or L.isShape or L.isSmart: return false
  if L.px.len != d.w * d.h: return false
  for p in L.px:
    if (p shr 24) != 0: return false
  true

proc genericName*(name: string): bool =
  ## A name the program gave ("Layer 3", "Layer 1 copy 2", "Group 2",
  ## "Shape 1", "Rectangle 1"...): one Layer Cleanup may change.
  var n = name.strip
  while n.endsWith(" copy") or (n.contains(" copy ") and n.rsplit(" copy ", 1)[1].allCharsInSet(Digits)):
    n = if n.endsWith(" copy"): n[0 ..< n.len - 5] else: n.rsplit(" copy ", 1)[0]
  for base in ["Layer", "Group", "Shape", "Rectangle", "Ellipse", "Polygon", "Line", "Star", "Spiral",
               "Custom Shape", "Path", "Artboard", "Color Fill", "Gradient Fill", "Pattern Fill"]:
    if n == base: return true
    if n.startsWith(base & " ") and n[base.len + 1 .. ^1].strip.allCharsInSet(Digits): return true
  false

proc colorName(r, g, b: int): string =
  ## (a plain name for a color)
  let mx = max(r, max(g, b))
  let mn = min(r, min(g, b))
  let l = (mx + mn) div 2
  let s = if mx == mn: 0.0 else: (mx - mn).float / (if l < 128: (mx + mn).float else: (510 - mx - mn).float)
  if s < 0.15:
    return (if l < 50: "Black" elif l > 205: "White" else: "Gray")
  var h = 0.0
  let d = (mx - mn).float
  if mx == r: h = 60 * (((g - b).float / d) mod 6)
  elif mx == g: h = 60 * ((b - r).float / d + 2)
  else: h = 60 * ((r - g).float / d + 4)
  if h < 0: h += 360
  if l < 70 and (h < 50 or h > 330): return "Brown"
  if h < 15 or h >= 345: "Red"
  elif h < 40: (if l < 110: "Brown" else: "Orange")
  elif h < 65: "Yellow"
  elif h < 160: "Green"
  elif h < 195: "Cyan"
  elif h < 255: "Blue"
  elif h < 290: "Purple"
  else: "Pink"

proc contentName*(d: Doc; L: Layer): string =
  ## A name from what the layer holds: its words, its kind of shape or
  ## fill, its adjustment, or its color and how much it covers.
  if L.isText:
    var t = L.text.plainText.replace("\n", " ").strip
    if t.len > 32: t = t[0 ..< 30].strip & "..."
    return if t.len > 0: t else: "Text"
  if L.adjust.kind.len > 0: return L.adjust.kind
  if L.isFill:
    return case L.shape.fill.kind
           of spGradient: "Gradient Fill"
           of spPattern: "Pattern Fill"
           else: colorName(rOf(L.shape.fill.color), gOf(L.shape.fill.color), bOf(L.shape.fill.color)) & " Fill"
  if L.isSmart: return (if L.smart.name.len > 0: L.smart.name else: "Smart Object")
  if L.group: return "Group"
  # pixels: the mean color of what is there, and how much of the image
  var r, g, b, n = 0
  let step = max(1, int(sqrt(d.w.float * d.h.float / 40000)))
  var y = 0
  while y < d.h:
    var x = 0
    while x < d.w:
      let p = L.px[y * d.w + x]
      if (p shr 24) > 32:
        r += rOf(p); g += gOf(p); b += bOf(p)
        inc n
      x += step
    y += step
  if n == 0: return "Empty"
  let cover = n.float / ((d.w div step + 1) * (d.h div step + 1)).float
  let c = colorName(r div n, g div n, b div n)
  let shape = if L.isShape: "Shape" elif cover > 0.85: "Picture" elif cover > 0.3: "Area" else: "Shape"
  c & " " & shape

proc cleanupLayers*(d: Doc; removeEmpty = true; removeHidden = false; removeEmptyGroups = true;
                    rename = true): CleanupReport =
  ## Layer > Layer Cleanup: empty layers and groups thrown away, hidden
  ## ones too when asked, and layers with the names the program gave
  ## named after what they hold. Undoable in a step (`touchLayers` is done
  ## here).
  d.touchLayers()
  var i = d.layers.high
  while i >= 0 and i < d.layers.len:
    let L = d.layers[i]
    var gone = false
    if removeHidden and not L.visible and not L.background:
      let lo = d.blockStart(i)
      let n = i - lo + 1
      var others = 0
      for j, M in d.layers:
        if (j < lo or j > i) and not M.group: inc others
      if others > 0:
        for j in countdown(i, lo): d.layers.delete(j)
        inc result.hiddenRemoved, n
        i = lo                       # (then the one under it)
        gone = true
    if not gone and removeEmpty and d.isEmptyLayer(L) and d.layers.len > 1:
      d.layers.delete(i)
      inc result.emptyRemoved
      gone = true
    if not gone and rename and not L.background and genericName(L.name):
      let nm = d.contentName(L)
      if nm.len > 0 and nm != L.name and nm != "Empty":
        L.name = nm
        inc result.renamed
    dec i
  # (groups left with nothing in them -- and the groups they were in, then)
  var again = removeEmptyGroups
  while again:
    again = false
    for j in countdown(d.layers.high, 0):
      if d.layers[j].group and d.blockStart(j) == j:
        d.layers.delete(j)
        inc result.groupsRemoved
        again = true
        break
  d.cur = clamp(d.cur, 0, d.layers.high)
  inc d.ver
  d.markAll()

# ---- Harmonize, with a shadow --------------------------------------------------------------------------------------

proc lightFrom*(d: Doc; below: seq[uint32]): tuple[x, y: float] =
  ## Where the light comes from in a picture (a unit vector, image
  ## coordinates; from above when it cannot be told): the side its bright
  ## part leans to.
  var sx, sy, sw = 0.0
  let step = max(1, int(sqrt(d.w.float * d.h.float / 60000)))
  var y = 0
  while y < d.h:
    var x = 0
    while x < d.w:
      let p = below[y * d.w + x]
      let l = (rOf(p) * 77 + gOf(p) * 150 + bOf(p) * 29).float / 65280
      let wgt = l * l * l
      sx += wgt * (x.float / d.w.float - 0.5)
      sy += wgt * (y.float / d.h.float - 0.5)
      sw += wgt
      x += step
    y += step
  if sw <= 0: return (0.0, -1.0)
  var lx = sx / sw
  var ly = sy / sw
  let n = sqrt(lx * lx + ly * ly)
  if n < 0.03: return (0.0, -1.0)
  lx /= n
  ly /= n
  if ly > 0.3: ly = -0.3               # (light from below is rare: the shadow still falls down)
  let m = sqrt(lx * lx + ly * ly)
  (lx / m, ly / m)

proc harmonizeLayer*(d: Doc; L: Layer; intensity = 70; shadow = 50; brightness = 0;
                     saturation = 0): Layer =
  ## Layer > Harmonize: a placed object (the layer) made to fit the
  ## picture under it -- its colors and light -- and, `shadow` > 0, a
  ## shadow cast on it: a layer under the object, falling away from the
  ## light, with a darker touch where it stands (returned; nil without a
  ## shadow). Undoable in a step.
  let k = d.layers.find(L)
  if k < 0 or L.px.len != d.w * d.h: return nil
  let f = harmonize(d, L, intensity, brightness, saturation)
  let keep = d.cur
  d.cur = k
  d.applyFilter(0, f)
  d.cur = keep
  if shadow <= 0: return nil
  # what is under it, for where the light comes from and the shadow's color
  var below = newSeq[uint32](d.w * d.h)
  var under: seq[Layer]
  for j in 0 ..< k: under.add d.layers[j]
  d.compositeInto(below, d.bounds, under)
  let b = d.contentBounds(L)
  if b.w <= 0 or b.h <= 0: return nil
  let (lx, ly) = d.lightFrom(below)
  let size = max(b.w, b.h).float
  let dist = size * 0.06
  let dx = -lx * dist
  let dy = -ly * dist
  let blurR = max(2, int(size * 0.035))
  # the shadow: the object's shape, moved away from the light, softened;
  # and where it stands, a short dark ellipse
  let pad = blurR * 3 + int(abs(dx) + abs(dy)) + 4
  let r = d.clip(rect(b.x - pad, b.y - pad, b.w + 2 * pad, b.h + 2 * pad))
  var a = newSeq[float32](r.w * r.h)
  for y in 0 ..< r.h:
    for x in 0 ..< r.w:
      let sx = int(round((r.x + x).float - dx))
      let sy = int(round((r.y + y).float - dy))
      if sx >= 0 and sy >= 0 and sx < d.w and sy < d.h:
        a[y * r.w + x] = float32(L.px[sy * d.w + sx] shr 24) / 255
  let cx = (b.x + b.w div 2 - r.x).float
  let cy = (b.y + b.h - r.y).float - 1
  let ew = b.w.float * 0.38
  let eh = max(2.0, b.h.float * 0.035)
  for y in 0 ..< r.h:
    for x in 0 ..< r.w:
      let ex = (x.float - cx) / ew
      let ey = (y.float - cy) / eh
      let e = ex * ex + ey * ey
      if e < 1: a[y * r.w + x] = max(a[y * r.w + x], float32(1 - e) * 1.2'f32)
  # (softened: three box blurs)
  var t = newSeq[float32](a.len)
  for pass in 0 .. 2:
    for y in 0 ..< r.h:
      var acc = 0'f32
      for x in -blurR .. blurR: acc += a[y * r.w + clamp(x, 0, r.w - 1)]
      for x in 0 ..< r.w:
        t[y * r.w + x] = acc / float32(2 * blurR + 1)
        acc += a[y * r.w + clamp(x + blurR + 1, 0, r.w - 1)] - a[y * r.w + clamp(x - blurR, 0, r.w - 1)]
    for x in 0 ..< r.w:
      var acc = 0'f32
      for y in -blurR .. blurR: acc += t[clamp(y, 0, r.h - 1) * r.w + x]
      for y in 0 ..< r.h:
        a[y * r.w + x] = acc / float32(2 * blurR + 1)
        acc += t[clamp(y + blurR + 1, 0, r.h - 1) * r.w + x] - t[clamp(y - blurR, 0, r.h - 1) * r.w + x]
  # its color: what is under it, darkened
  var sr, sg, sb, n = 0
  for y in b.y ..< b.y + b.h:
    for x in b.x ..< b.x + b.w:
      let p = below[y * d.w + x]
      sr += rOf(p); sg += gOf(p); sb += bOf(p)
      inc n
  n = max(1, n)
  let col = argb(255, sr div n div 4, sg div n div 4, sb div n div 4)
  result = d.newLayer("Shadow")
  for y in 0 ..< r.h:
    for x in 0 ..< r.w:
      let v = clamp(a[y * r.w + x], 0, 1)
      if v > 0.002: result.px[(r.y + y) * d.w + r.x + x] = withAlpha(col, int(v * 255))
  result.mode = bmMultiply
  result.opacity = clamp(shadow, 0, 100)
  inc result.ver
  d.insertLayer(result, k - 1)
  d.cur = d.layers.find(L)
  d.markAll()

# ---- Colorize, from color hints --------------------------------------------------------------------------------------

type ColorHint* = tuple[x, y: float; color: uint32]
  ## A color put on a point of the picture (where Colorize starts from).

proc colorizePixels*(px: seq[uint32]; w, h: int; hints: openArray[ColorHint]; strength = 100;
                     spread = 50): seq[uint32] =
  ## The picture colored from `hints`: each hint's color runs out from its
  ## point along what is alike (it stops at edges: the light changes),
  ## the picture's own light kept. `strength` (0..100): how much of the
  ## colors; `spread` (0..100): how far they run over changes of light.
  ## Without hints: a warm, old-photo tint.
  result = px
  if w <= 0 or h <= 0 or px.len != w * h: return
  # (the light: Y; the color: Cb, Cr)
  proc yOf(p: uint32): float32 = (rOf(p).float32 * 0.299 + gOf(p).float32 * 0.587 + bOf(p).float32 * 0.114)
  proc cbOf(p: uint32): float32 = -0.168736'f32 * rOf(p).float32 - 0.331264 * gOf(p).float32 + 0.5 * bOf(p).float32
  proc crOf(p: uint32): float32 = 0.5'f32 * rOf(p).float32 - 0.418688 * gOf(p).float32 - 0.081312 * bOf(p).float32
  # a small grid to work on
  let s = max(1.0, max(w, h).float / 240)
  let gw = max(2, int(ceil(w.float / s)))
  let gh = max(2, int(ceil(h.float / s)))
  var gy = newSeq[float32](gw * gh)
  var cnt = newSeq[int](gw * gh)
  for y in 0 ..< h:
    let yy = min(gh - 1, int(y.float / s))
    for x in 0 ..< w:
      let xx = min(gw - 1, int(x.float / s))
      gy[yy * gw + xx] += yOf(px[y * w + x])
      inc cnt[yy * gw + xx]
  for i in 0 ..< gy.len: gy[i] /= float32(max(1, cnt[i]))
  var cb = newSeq[float32](gw * gh)
  var cr = newSeq[float32](gw * gh)
  var fixed = newSeq[bool](gw * gh)
  if hints.len == 0:
    for i in 0 ..< gy.len:
      let t = gy[i] / 255
      cb[i] = -14 * t - 4
      cr[i] = 12 * t + 4
      fixed[i] = true
  else:
    let rad = max(1, int(spread / 30))
    for hnt in hints:
      let hx = int(hnt.x / s)
      let hy = int(hnt.y / s)
      for yy in max(0, hy - rad) .. min(gh - 1, hy + rad):
        for xx in max(0, hx - rad) .. min(gw - 1, hx + rad):
          cb[yy * gw + xx] = cbOf(hnt.color)
          cr[yy * gw + xx] = crOf(hnt.color)
          fixed[yy * gw + xx] = true
    # the colors run out along what is alike (weights fall where the light
    # changes): many passes, the far ones first got from a coarser start
    let sigma = 4.0'f32 + float32(spread) / 4
    let inv = 1 / (2 * sigma * sigma)
    # (a start: each place the nearest hint's color)
    for i in 0 ..< gy.len:
      if fixed[i]: continue
      var best = Inf
      for hnt in hints:
        let ddx = (i mod gw).float - hnt.x / s
        let ddy = (i div gw).float - hnt.y / s
        let dd = ddx * ddx + ddy * ddy
        if dd < best:
          best = dd
          cb[i] = cbOf(hnt.color)
          cr[i] = crOf(hnt.color)
    for pass in 0 ..< 220:
      for i in 0 ..< gy.len:
        if fixed[i]: continue
        let x = i mod gw
        let y = i div gw
        var sw, sb, sr = 0'f32
        for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]:
          if nx < 0 or ny < 0 or nx >= gw or ny >= gh: continue
          let j = ny * gw + nx
          let dl = gy[i] - gy[j]
          let wt = exp(-dl * dl * inv)
          sw += wt
          sb += wt * cb[j]
          sr += wt * cr[j]
        if sw > 1e-6:
          cb[i] = sb / sw
          cr[i] = sr / sw
  # back at full size, read between the grid's points; the light kept
  let k = clamp(strength, 0, 100).float32 / 100
  for y in 0 ..< h:
    let fy = clamp((y.float + 0.5) / s - 0.5, 0, (gh - 1).float)
    let y0 = min(int(fy), gh - 2)
    let ty = float32(fy - y0.float)
    for x in 0 ..< w:
      let fx = clamp((x.float + 0.5) / s - 0.5, 0, (gw - 1).float)
      let x0 = min(int(fx), gw - 2)
      let tx = float32(fx - x0.float)
      template lerp2(a: seq[float32]): float32 =
        (a[y0 * gw + x0] * (1 - tx) + a[y0 * gw + x0 + 1] * tx) * (1 - ty) +
          (a[(y0 + 1) * gw + x0] * (1 - tx) + a[(y0 + 1) * gw + x0 + 1] * tx) * ty
      let p = px[y * w + x]
      let yy = yOf(p)
      let b0 = cbOf(p)
      let r0 = crOf(p)
      let b1 = b0 + (lerp2(cb) - b0) * k
      let r1 = r0 + (lerp2(cr) - r0) * k
      result[y * w + x] = argb(aOf(p), int(yy + 1.402 * r1 + 0.5), int(yy - 0.344136 * b1 - 0.714136 * r1 + 0.5),
                               int(yy + 1.772 * b1 + 0.5))

proc colorizeLayer*(d: Doc; L: Layer; hints: openArray[ColorHint]; strength = 100; spread = 50) =
  ## Filter > Neural Filters > Colorize on a layer (where selected). Undoable
  ## in a step.
  if L.px.len != d.w * d.h: return
  d.touch(L, d.bounds)
  let o = colorizePixels(L.px, d.w, d.h, hints, strength, spread)
  for i in 0 ..< o.len:
    let s = d.selAt(i)
    if s >= 255: L.px[i] = o[i]
    elif s > 0: L.px[i] = mix(L.px[i], o[i], s / 255)
  inc L.ver
  d.markAll()

# ---- Content-Aware Expand ------------------------------------------------------------------------------------------

proc contentAwareExpand*(d: Doc; r: Rect; seed = 1) =
  ## The Crop tool's Content-Aware: the image cropped to `r` -- which may
  ## reach past its edges -- the new room made up from what is near it (on
  ## the Background, and on layers that covered the whole image). Undoable
  ## in a step.
  if r.w < 1 or r.h < 1: return
  let ux0 = min(0, r.x)
  let uy0 = min(0, r.y)
  let ux1 = max(d.w, r.x + r.w)
  let uy1 = max(d.h, r.y + r.h)
  let ow = d.w
  let oh = d.h
  # (the layers that covered the whole image: made up past it too)
  var full: seq[Layer]
  for L in d.layers:
    if L.group or L.px.len != ow * oh or L.isText or L.isShape or L.adjust.kind.len > 0: continue
    var all = true
    for p in L.px:
      if (p shr 24) < 250:
        all = false
        break
    if all: full.add L
  d.touchLayers()
  for L in d.layers: d.touch(L, d.bounds)
  d.canvasSizeAt(ux1 - ux0, uy1 - uy0, -ux0, -uy0, 0)
  let ox = -ux0
  let oy = -uy0
  # each side's new room, a strip at a time (small regions: quick)
  var strips: seq[Rect]
  if oy > 0: strips.add rect(0, 0, d.w, oy)
  if uy1 > oh: strips.add rect(0, oy + oh, d.w, uy1 - oh)
  if ox > 0: strips.add rect(0, oy, ox, oh)
  if ux1 > ow: strips.add rect(ox + ow, oy, ux1 - ow, oh)
  let keepSel = d.sel
  let keepCur = d.cur
  for L in full:
    # (opaque there first: what is made up keeps the alpha it finds)
    for s in strips:
      for y in s.y ..< s.y + s.h:
        for x in s.x ..< s.x + s.w: L.px[y * d.w + x] = 0xFF000000'u32
    d.cur = d.layers.find(L)
    for k, s in strips:
      var m = newSeq[uint8](d.w * d.h)
      for y in s.y ..< s.y + s.h:
        for x in s.x ..< s.x + s.w: m[y * d.w + x] = 255
      d.sel = m
      d.contentAwareFill(seed + k)
    inc L.ver
  d.sel = keepSel
  d.cur = keepCur
  d.crop(rect(r.x - ux0, r.y - uy0, r.w, r.h))
  d.markAll()

# ---- artboards -------------------------------------------------------------------------------------------------------

proc isArtboard*(L: Layer): bool = L.group and L.board.w > 0
  ## An artboard: a group with a page of its own (`board`), what is in it
  ## shown only there.

proc artboards*(d: Doc): seq[int] =
  ## The artboards, by their place in the layers (the top first).
  for i in countdown(d.layers.high, 0):
    if d.layers[i].isArtboard: result.add i

proc boardMask(d: Doc; r: Rect): Layer =
  result = Layer(name: "Layer Mask", opacity: 100, visible: true, gray: true, px: newSeq[uint32](d.w * d.h))
  let c = d.clip(r)
  for i in 0 ..< result.px.len: result.px[i] = grayPx(0)
  for y in c.y ..< c.y + c.h:
    for x in c.x ..< c.x + c.w: result.px[y * d.w + x] = grayPx(255)

proc addArtboard*(d: Doc; r: Rect; name = ""; color = 0xFFFFFFFF'u32): Layer =
  ## The Artboard tool: a new artboard in `r` (its page filled with `color`;
  ## transparent: none), at the top. Undoable in a step.
  let c = d.clip(r)
  if c.w <= 0 or c.h <= 0: return nil
  d.touchLayers()
  var n = 1
  for i in d.artboards: inc n
  let nm = if name.len > 0: name else: "Artboard " & $n
  d.cur = d.layers.high
  while d.cur > 0 and d.layers[d.cur].depth > 0: dec d.cur
  var fillL: Layer = nil
  if (color shr 24) > 0:
    fillL = d.addShapeLayer(ShapeData(path: rectPath(c.x.float, c.y.float, (c.x + c.w).float, (c.y + c.h).float),
                                      fill: solidPaint(color)), "Page")
  else:
    fillL = d.addLayer("Layer 1")
  let k = d.layers.find(fillL)
  result = d.groupLayers(@[k], nm)
  if result == nil: return
  result.board = c
  result.passThrough = false
  result.mask = d.boardMask(c)
  result.collapsed = false
  d.cur = d.layers.find(fillL)
  d.markAll()

proc artboardAt*(d: Doc; x, y: int): int =
  ## The artboard at a point (its place in the layers; -1 none): the top one.
  for i in d.artboards:
    let b = d.layers[i].board
    if x >= b.x and y >= b.y and x < b.x + b.w and y < b.y + b.h: return i
  -1

proc moveArtboard*(d: Doc; i: int; dx, dy: int) =
  ## An artboard moved with all on it. Undoable in a step.
  if i < 0 or i >= d.layers.len or not d.layers[i].isArtboard: return
  let G = d.layers[i]
  var inside: seq[Layer]
  for j in d.blockStart(i) ..< i: inside.add d.layers[j]
  d.shiftLayers(inside, dx, dy)
  d.touchLayers()
  G.board = rect(G.board.x + dx, G.board.y + dy, G.board.w, G.board.h)
  G.mask = d.boardMask(G.board)
  d.markAll()

proc resizeArtboard*(d: Doc; i: int; r: Rect) =
  ## An artboard's page made `r` (its fill follows; what is on it stays where
  ## it is). Undoable in a step.
  if i < 0 or i >= d.layers.len or not d.layers[i].isArtboard: return
  let c = d.clip(r)
  if c.w <= 0 or c.h <= 0: return
  d.touchLayers()
  let G = d.layers[i]
  G.board = c
  G.mask = d.boardMask(c)
  let lo = d.blockStart(i)
  if lo < i and d.layers[lo].isFill.not and d.layers[lo].isShape and d.layers[lo].name == "Page":
    var s = d.layers[lo].shape
    s.path = rectPath(c.x.float, c.y.float, (c.x + c.w).float, (c.y + c.h).float)
    d.setShape(d.layers[lo], s)
  d.markAll()

proc artboardPicture*(d: Doc; i: int): Bitmap =
  ## File > Export > Artboards to Files: what one artboard shows, cut to its
  ## page.
  if i < 0 or i >= d.layers.len or not d.layers[i].isArtboard: return nil
  let G = d.layers[i]
  let b = d.clip(G.board)
  var ls: seq[Layer]
  for j in d.blockStart(i) .. i: ls.add d.layers[j]
  var px = newSeq[uint32](d.w * d.h)
  d.compositeInto(px, b, ls)
  result = newBitmap(b.w, b.h)
  for y in 0 ..< b.h:
    copyMem(addr result.px[y * b.w], addr px[(b.y + y) * d.w + b.x], b.w * 4)

# ---- the Magnetic Lasso -----------------------------------------------------------------------------------------------

import std/heapqueue

proc magneticPath*(d: Doc; ax, ay, bx, by: float; width = 10; contrast = 10): seq[(float, float)] =
  ## The Magnetic Lasso's side from `ax`, `ay` to `bx`, `by`: along the
  ## strongest edges of the picture (as it looks) within `width` pixels of
  ## the straight line between them -- the cheapest way through, edges
  ## cheap and flat places dear (a live wire). `contrast` (1..100): how weak
  ## an edge is still followed. The points in image coordinates, from the
  ## start to the end.
  d.updateComposite()
  let src = d.compPtr
  if src == nil: return @[(ax, ay), (bx, by)]
  let wd = max(2, width)
  let x0 = clamp(int(min(ax, bx)) - wd, 0, d.w - 1)
  let y0 = clamp(int(min(ay, by)) - wd, 0, d.h - 1)
  let x1 = clamp(int(max(ax, bx)) + wd, 0, d.w - 1)
  let y1 = clamp(int(max(ay, by)) + wd, 0, d.h - 1)
  let area = (x1 - x0 + 1) * (y1 - y0 + 1)
  let step = max(1, int(ceil(sqrt(area.float / 90_000))))
  let gw = (x1 - x0) div step + 1
  let gh = (y1 - y0) div step + 1
  if gw < 2 or gh < 2: return @[(ax, ay), (bx, by)]
  var lum = newSeq[float32](gw * gh)
  for gy in 0 ..< gh:
    for gx in 0 ..< gw:
      let p = src[(y0 + gy * step) * d.w + x0 + gx * step]
      lum[gy * gw + gx] = float32(rOf(p) * 77 + gOf(p) * 150 + bOf(p) * 29) / 256
  # (the edges: how much the light changes across each point)
  var grad = newSeq[float32](gw * gh)
  var gmax = 1'f32
  for gy in 0 ..< gh:
    for gx in 0 ..< gw:
      let l = lum[gy * gw + max(0, gx - 1)]
      let r = lum[gy * gw + min(gw - 1, gx + 1)]
      let u = lum[max(0, gy - 1) * gw + gx]
      let dn = lum[min(gh - 1, gy + 1) * gw + gx]
      let g = sqrt((r - l) * (r - l) + (dn - u) * (dn - u))
      grad[gy * gw + gx] = g
      gmax = max(gmax, g)
  let floorG = gmax * float32(clamp(contrast, 1, 100)) / 200
  # (the straight line: far from it is dear)
  let lx = bx - ax
  let ly = by - ay
  let ll = max(1e-6, sqrt(lx * lx + ly * ly))
  var cost = newSeq[float32](gw * gh)
  for gy in 0 ..< gh:
    for gx in 0 ..< gw:
      let ix = (x0 + gx * step).float
      let iy = (y0 + gy * step).float
      let dist = abs((ix - ax) * ly - (iy - ay) * lx) / ll
      let g = max(0'f32, grad[gy * gw + gx] - floorG) / max(1'f32, gmax - floorG)
      var c = 1'f32 + 12'f32 * (1 - g) * (1 - g)
      if dist > wd.float: c += float32(dist - wd.float) * 4
      cost[gy * gw + gx] = c
  let sx = clamp(int((ax - x0.float) / step.float + 0.5), 0, gw - 1)
  let sy = clamp(int((ay - y0.float) / step.float + 0.5), 0, gh - 1)
  let ex = clamp(int((bx - x0.float) / step.float + 0.5), 0, gw - 1)
  let ey = clamp(int((by - y0.float) / step.float + 0.5), 0, gh - 1)
  var dist = newSeq[float32](gw * gh)
  for v in dist.mitems: v = Inf.float32
  var prev = newSeq[int32](gw * gh)
  for v in prev.mitems: v = -1
  var heap = initHeapQueue[(float32, int32)]()
  dist[sy * gw + sx] = 0
  heap.push((0'f32, int32(sy * gw + sx)))
  let goal = ey * gw + ex
  while heap.len > 0:
    let (dcur, i) = heap.pop()
    if dcur > dist[i]: continue
    if i == goal: break
    let cx = int(i) mod gw
    let cy = int(i) div gw
    for (ddx, ddy, k) in [(-1, 0, 1'f32), (1, 0, 1'f32), (0, -1, 1'f32), (0, 1, 1'f32),
                          (-1, -1, 1.4142'f32), (1, -1, 1.4142'f32), (-1, 1, 1.4142'f32), (1, 1, 1.4142'f32)]:
      let nx = cx + ddx
      let ny = cy + ddy
      if nx < 0 or ny < 0 or nx >= gw or ny >= gh: continue
      let j = ny * gw + nx
      let nd = dcur + k * cost[j]
      if nd < dist[j]:
        dist[j] = nd
        prev[j] = i
        heap.push((nd, int32(j)))
  var path: seq[(float, float)]
  var at = goal
  if prev[at] < 0 and at != sy * gw + sx: return @[(ax, ay), (bx, by)]
  while at >= 0:
    path.add (((at mod gw) * step + x0).float + 0.5, ((at div gw) * step + y0).float + 0.5)
    if at == sy * gw + sx: break
    at = int(prev[at])
  # (the start first; every few points kept)
  result.add (ax, ay)
  let keep = max(1, 3 div step)
  var k = 0
  for i in countdown(path.high - 1, 1):
    inc k
    if k mod keep == 0: result.add path[i]
  result.add (bx, by)

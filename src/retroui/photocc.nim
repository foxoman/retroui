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

import std/[algorithm, math, strutils]
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
  if L.group:
    # (a group: after what is in it -- its own layers' names, the first ones)
    let i = d.layers.find(L)
    if i < 0: return "Group"
    var names: seq[string]
    var n = 0
    var j = i - 1
    let lo = d.blockStart(i)
    while j >= lo:
      let M = d.layers[j]
      if d.blockStart(j) < j: j = d.blockStart(j)   # (a group in it: counted as one)
      inc n
      if names.len < 2 and M.name.len > 0 and M.name notin names: names.add M.name
      dec j
    if names.len == 0: return "Group"
    return (if n <= 1: names[0]
            elif n == 2 and names.len == 2: names[0] & " and " & names[1]
            else: names.join(", ") & " and " & $(n - names.len) & " more")
  if L.isShape and L.shape.fill.kind == spColor or (L.isShape and L.shape.strokeWidth > 0):
    # (a shape: its color and what drew it)
    let solid = L.shape.fill.kind == spColor and (L.shape.fill.color shr 24) > 0
    let c = if solid: L.shape.fill.color else: L.shape.stroke.color
    let what = if L.shape.kind.len > 0: L.shape.kind
               elif not solid: "Outline"
               else: "Shape"
    return colorName(rOf(c), gOf(c), bOf(c)) & " " & what
  # pixels: the mean color of what is there, how much of the image, and where
  var r, g, b, n = 0
  var x0 = d.w
  var y0 = d.h
  var x1, y1 = -1
  let step = max(1, int(sqrt(d.w.float * d.h.float / 40000)))
  var y = 0
  while y < d.h:
    var x = 0
    while x < d.w:
      let p = L.px[y * d.w + x]
      if (p shr 24) > 32:
        r += rOf(p); g += gOf(p); b += bOf(p)
        inc n
        x0 = min(x0, x); x1 = max(x1, x)
        y0 = min(y0, y); y1 = max(y1, y)
      x += step
    y += step
  if n == 0: return "Empty"
  let cover = n.float / ((d.w div step + 1) * (d.h div step + 1)).float
  let c = colorName(r div n, g div n, b div n)
  let wide = (x1 - x0 + step).float >= d.w.float * 0.8
  # (a wide band of blue or white at the top: the sky; of green at the bottom: grass)
  if wide and y0 <= d.h div 20 and y1 < d.h * 3 div 4 and cover > 0.15 and c in ["Blue", "Cyan", "White", "Gray"]:
    return "Sky"
  if wide and y1 >= d.h - d.h div 20 and y0 > d.h div 3 and cover > 0.15 and c == "Green": return "Grass"
  if cover > 0.85: return c & " Picture"
  if cover > 0.3: return c & " Area"
  # (a small thing: where it is)
  let cx = (x0 + x1) div 2
  let cy = (y0 + y1) div 2
  let v = if cy < d.h div 3: "Top" elif cy >= d.h * 2 div 3: "Bottom" else: ""
  let h = if cx < d.w div 3: "Left" elif cx >= d.w * 2 div 3: "Right" else: ""
  let where = if v.len > 0 and h.len > 0: v & " " & h
              elif v.len > 0 or h.len > 0: v & h
              else: "Middle"
  c & " Shape, " & where

proc autoRename*(d: Doc; which: seq[int]): int =
  ## Rename Layers: the layers `which` (indexes; the picked ones, say) named after what they
  ## hold -- whatever names they had -- a group after what is in it (its layers named first).
  ## How many were renamed; undoable in a step (`touchLayers` is done here).
  d.touchLayers()
  var order = which
  order.sort()
  for i in order:
    if i < 0 or i >= d.layers.len: continue
    let L = d.layers[i]
    if L.background: continue
    let nm = d.contentName(L)
    if nm.len > 0 and nm != "Empty" and nm != L.name:
      L.name = nm
      inc result
  inc d.ver

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
#
# As the drawing program has them: pages of the canvas (`Doc.boards`), not layers -- the artwork on the
# layers lies anywhere, on an artboard or round it on the canvas; each is exported and printed as what
# is on it. A Photoshop file's artboards (groups with a page: `isArtboard`) are made these when it is
# opened (`boardsFromGroups`).

proc artboards*(d: Doc): seq[int] =
  ## The artboards, by their number (from 0): `d.boards`' places.
  for i in 0 ..< d.boards.len: result.add i

proc artboardName*(d: Doc; i: int): string =
  ## Artboard `i` as the drawing program names it: its number and its name ("01 - Artboard 1").
  if i < 0 or i >= d.boards.len: return ""
  (if i + 1 < 10: "0" else: "") & $(i + 1) & " - " & d.boards[i].name

proc nextBoardName(d: Doc): string =
  var n = d.boards.len + 1
  while true:
    var used = false
    for b in d.boards:
      if b.name == "Artboard " & $n: used = true
    if not used: return "Artboard " & $n
    inc n

proc growCanvasFor*(d: Doc; r: Rect; margin = 0): (int, int) =
  ## The canvas made big enough to hold `r` (and `margin` round it): room added where it is
  ## outside -- at the left or the top, everything moved over (the artboards, the artwork); how far
  ## (add it to `r`). The Background, if there is one, grown in its color. Undoable in a step: the
  ## whole image saved (`snapStep`) -- so before anything else of the step.
  let want = rect(r.x - margin, r.y - margin, r.w + 2 * margin, r.h + 2 * margin)
  let x0 = min(0, want.x)
  let y0 = min(0, want.y)
  let x1 = max(d.w, want.x + want.w)
  let y1 = max(d.h, want.y + want.h)
  if x0 == 0 and y0 == 0 and x1 == d.w and y1 == d.h: return (0, 0)
  if d.stepOpen: d.snapStep(d.undoName)
  var bg = 0xFFFFFFFF'u32
  for L in d.layers:
    if L.background and L.px.len > 0: bg = L.px[0]
  d.canvasSizeAt(x1 - x0, y1 - y0, -x0, -y0, bg)
  d.grown = (d.grown.x - x0, d.grown.y - y0)
  (-x0, -y0)

proc boardMargin(d: Doc; r: Rect): int =
  ## (the canvas round a new artboard: a third of its size, at least 40 pixels)
  max(40, max(r.w, r.h) div 3)

proc addArtboard*(d: Doc; r: Rect; name = ""; color = 0xFFFFFFFF'u32): int =
  ## A new artboard in `r` (the Artboard tool's box, New Artboard), its paper `color` (alpha 0:
  ## none), picked; the canvas grown to hold it (`r` moved over with everything if it grew left or
  ## up). Its number (-1: too small). Undoable in a step.
  if r.w < 1 or r.h < 1: return -1
  let (sx, sy) = d.growCanvasFor(r, d.boardMargin(r))
  d.touchLayers()
  d.boards.add Artboard(name: (if name.len > 0: name else: d.nextBoardName), r: rect(r.x + sx, r.y + sy, r.w, r.h),
                        color: color)
  d.boardCur = d.boards.high
  inc d.boardsVer
  d.markAll()
  d.boardCur

proc artboardArt*(d: Doc; i: int): seq[Layer] =
  ## The artwork on artboard `i` -- what the drawing program moves with it: each layer (a group:
  ## all in it) whose middle is on it, not locked in place, not the Background.
  if i < 0 or i >= d.boards.len: return
  let b = d.boards[i].r
  for L in d.layers:
    if L.group or L.background or L.lockPosition or L.locked: continue
    let c = d.layerBox(L)
    if c.w <= 0 or c.h <= 0: continue
    let mx = c.x + c.w div 2
    let my = c.y + c.h div 2
    if mx >= b.x and mx < b.x + b.w and my >= b.y and my < b.y + b.h: result.add L

proc deleteArtboard*(d: Doc; i: int) =
  ## Artboard `i` gone (its artwork stays on the canvas). Undoable in a step.
  if i < 0 or i >= d.boards.len: return
  d.touchLayers()
  d.boards.delete(i)
  d.boardCur = clamp(if d.boardCur > i: d.boardCur - 1 else: d.boardCur, 0, max(0, d.boards.high))
  inc d.boardsVer
  d.markAll()

proc moveArtboard*(d: Doc; i: int; dx, dy: int; withArt = true) =
  ## Artboard `i` moved -- with its artwork (Move/Copy Artwork with Artboard), or alone; the canvas
  ## grown to hold it. Undoable in a step.
  if i < 0 or i >= d.boards.len or (dx == 0 and dy == 0): return
  let art = if withArt: d.artboardArt(i) else: @[]
  let b0 = d.boards[i].r
  let to = rect(b0.x + dx, b0.y + dy, b0.w, b0.h)
  let (sx, sy) = d.growCanvasFor(to, d.boardMargin(to))
  d.touchLayers()
  if art.len > 0: d.shiftLayers(art, dx, dy)
  d.boards[i].r = rect(to.x + sx, to.y + sy, to.w, to.h)
  inc d.boardsVer
  d.markAll()

proc duplicateArtboard*(d: Doc; i: int; dx, dy: int; withArt = true): int =
  ## A copy of artboard `i` so far over -- its artwork copied with it (as Alt+drag with the Artboard
  ## tool) -- picked. Its number. Undoable in a step.
  if i < 0 or i >= d.boards.len: return -1
  let src = d.boards[i]
  let to = rect(src.r.x + dx, src.r.y + dy, src.r.w, src.r.h)
  discard d.growCanvasFor(to, d.boardMargin(to))
  d.touchLayers()
  let ob = d.boards[i].r                               # (where it is now the canvas grew)
  let art = if withArt: d.artboardArt(i) else: @[]
  var copies: seq[Layer]
  for L in art:
    let k = d.layers.find(L)
    if k < 0: continue
    let C = d.duplicateLayer(k)
    if C != nil: copies.add C
  let n = d.addArtboard(rect(ob.x + dx, ob.y + dy, ob.w, ob.h), src.name & " copy", src.color)
  if n < 0: return -1
  d.boards[n].centerMark = src.centerMark
  d.boards[n].crossHairs = src.crossHairs
  d.boards[n].videoSafe = src.videoSafe
  if copies.len > 0: d.shiftLayers(copies, dx, dy)
  d.markAll()
  n

proc artboardColor*(d: Doc; i: int): uint32 =
  ## Artboard Options: the color of artboard `i`'s paper (0: none, the transparency grid shown).
  if i < 0 or i >= d.boards.len: 0'u32 else: d.boards[i].color

proc setArtboardColor*(d: Doc; i: int; color: uint32) =
  ## Artboard Options: artboard `i`'s paper in `color` (alpha 0: none). Undoable in a step.
  if i < 0 or i >= d.boards.len: return
  d.touchLayers()
  d.boards[i].color = color
  inc d.boardsVer
  d.markAll()

proc artboardAt*(d: Doc; x, y: int): int =
  ## The artboard at a point (its number; -1 none): the last made of those there.
  for i in countdown(d.boards.high, 0):
    let b = d.boards[i].r
    if x >= b.x and y >= b.y and x < b.x + b.w and y < b.y + b.h: return i
  -1

proc pinnedBox*(box, was, now: Rect; pins: set[LayerPin]): Rect =
  ## Where a layer's box `box` goes when the board it is on goes from `was` to `now`, by its
  ## Constraints (`pins`; {} it stays).
  if pins == {}: return box
  proc axis(p, size, wp, ws, np, ns: int; lo, hi, mid: LayerPin): (int, int) =
    let before = p - wp                       # (its gap to the board's left / top)
    let after = wp + ws - (p + size)          # (... to its right / bottom)
    if lpScale in pins:
      let k = ns.float / max(1, ws).float
      (np + int(round(before.float * k)), max(1, int(round(size.float * k))))
    elif lo in pins and hi in pins: (np + before, max(1, ns - before - after))
    elif hi in pins: (np + ns - after - size, size)
    elif mid in pins:
      let c = (p.float + size / 2 - wp.float) / max(1, ws).float
      (int(round(np.float + c * ns.float - size / 2)), size)
    else: (np + before, size)
  let (x, w) = axis(box.x, box.w, was.x, was.w, now.x, now.w, lpLeft, lpRight, lpCenterX)
  let (y, h) = axis(box.y, box.h, was.y, was.h, now.y, now.h, lpTop, lpBottom, lpCenterY)
  rect(x, y, w, h)

proc fitLayerTo*(d: Doc; L: Layer; was, now: Rect) =
  ## `L` (its box `was`) moved and sized to `now`: a shape's outline and a text box stretched, a
  ## painted layer's pixels resampled, anything else moved. (Undoable in a step: `touchLayers` first.)
  if was == now or was.w <= 0 or was.h <= 0: return
  if was.w == now.w and was.h == now.h or L.group or L.isSmart:
    d.shiftLayers(@[L], now.x - was.x, now.y - was.y)
    return
  let (sx, sy) = (now.w / was.w, now.h / was.h)
  if L.isShape:
    var s = L.shape
    s.path.mapPoints(proc (x, y: float): (float, float) =
      (now.x.float + (x - was.x.float) * sx, now.y.float + (y - was.y.float) * sy))
    d.setShape(L, s)
  elif L.isText:
    var t = L.text
    t.x = now.x.float32 + (t.x - was.x.float32) * sx.float32
    t.y = now.y.float32 + (t.y - was.y.float32) * sy.float32
    if t.boxW > 0 and t.boxH > 0:
      t.boxW = t.boxW * sx.float32
      t.boxH = t.boxH * sy.float32
    L.text = t
    d.drawText(L)
  elif L.px.len == d.w * d.h:
    d.transformLayer(L, was, now)
  else: d.shiftLayers(@[L], now.x - was.x, now.y - was.y)
  inc L.ver

proc resizeArtboard*(d: Doc; i: int; r: Rect) =
  ## Artboard `i` made `r`; its artwork stays where it is -- or, with Constraints (`Layer.pins`),
  ## follows it (`pinnedBox`). The canvas grown to hold it. Undoable in a step.
  if i < 0 or i >= d.boards.len or r.w < 1 or r.h < 1: return
  let art = d.artboardArt(i)
  let (sx, sy) = d.growCanvasFor(r, d.boardMargin(r))
  d.touchLayers()
  let was = d.boards[i].r
  let now = rect(r.x + sx, r.y + sy, r.w, r.h)
  for L in art:
    if L.pins == {}: continue
    let b = d.layerBox(L)
    if b.w > 0 and b.h > 0: d.fitLayerTo(L, b, pinnedBox(b, was, now, L.pins))
  d.boards[i].r = now
  inc d.boardsVer
  d.markAll()

proc artboardPicture*(d: Doc; i: int): Bitmap =
  ## File > Export > Artboards to Files: what artboard `i` shows -- the artwork on it, over its
  ## paper -- cut to it.
  if i < 0 or i >= d.boards.len: return nil
  let bd = d.boards[i]
  let b = d.clip(bd.r)
  if b.w <= 0 or b.h <= 0: return nil
  var ls: seq[Layer]
  for L in d.layers: ls.add L
  var px = newSeq[uint32](d.w * d.h)
  d.compositeInto(px, b, ls)
  result = newBitmap(b.w, b.h)
  let paper = bd.color
  for y in 0 ..< b.h:
    for x in 0 ..< b.w:
      let p = px[(b.y + y) * d.w + b.x + x]
      result.px[y * b.w + x] = if (paper shr 24) == 0: p else: blendPx(paper or 0xFF000000'u32, p, 255, bmNormal)

type ArrangeLayout* = enum
  ## Rearrange All Artboards: how they are laid out.
  alGridByRow = "Grid by Row", alGridByColumn = "Grid by Column", alRow = "Arrange by Row",
  alColumn = "Arrange by Column"

proc rearrangeArtboards*(d: Doc; layout: ArrangeLayout; columns: int; spacing: int; rightToLeft = false;
                         withArt = true) =
  ## Rearrange All Artboards: in a grid -- `columns` across (by row) or down (by column) -- or in one
  ## row or one column, `spacing` apart, in their order (right to left: the first at the right), from
  ## the first one's top left; their artwork with them. Undoable in a step.
  if d.boards.len == 0: return
  let n = d.boards.len
  let cols = max(1, case layout
                    of alRow: n
                    of alColumn: 1
                    else: columns)
  let byCol = layout in {alGridByColumn, alColumn}
  let per = if byCol: (if layout == alColumn: n else: max(1, cols)) else: cols
  # (each cell as wide as the widest in its column, as tall as the tallest in its row)
  var colW, rowH: seq[int]
  for k in 0 ..< n:
    let (c, rw) = if byCol: (k div per, k mod per) else: (k mod per, k div per)
    while colW.len <= c: colW.add 0
    while rowH.len <= rw: rowH.add 0
    colW[c] = max(colW[c], d.boards[k].r.w)
    rowH[rw] = max(rowH[rw], d.boards[k].r.h)
  let x0 = d.boards[0].r.x
  let y0 = d.boards[0].r.y
  var targets = newSeq[Rect](n)
  for k in 0 ..< n:
    var (c, rw) = if byCol: (k div per, k mod per) else: (k mod per, k div per)
    if rightToLeft: c = colW.high - c
    var x = x0
    for q in 0 ..< c: x += colW[q] + spacing
    var y = y0
    for q in 0 ..< rw: y += rowH[q] + spacing
    targets[k] = rect(x, y, d.boards[k].r.w, d.boards[k].r.h)
  # (each moved where it goes -- its artwork picked before any moves, so none is taken twice)
  var arts = newSeq[seq[Layer]](n)
  if withArt:
    for k in 0 ..< n: arts[k] = d.artboardArt(k)
  var all = targets[0]
  for t in targets: all = union(all, t)
  let (sx, sy) = d.growCanvasFor(all, d.boardMargin(targets[0]))
  d.touchLayers()
  for k in 0 ..< n:
    let t = rect(targets[k].x + sx, targets[k].y + sy, targets[k].w, targets[k].h)
    let b = d.boards[k].r
    if arts[k].len > 0: d.shiftLayers(arts[k], t.x - b.x, t.y - b.y)
    d.boards[k].r = t
  inc d.boardsVer
  d.markAll()

proc artBounds(d: Doc; layers: openArray[Layer]): Rect =
  for L in layers:
    if L.group or not L.visible: continue
    let c = d.layerBox(L)
    if c.w > 0 and c.h > 0: result = if result.w > 0: union(result, c) else: c

proc fitArtboardTo*(d: Doc; i: int; layers: seq[Layer] = @[]) =
  ## Object > Artboards > Fit to Artwork Bounds (no `layers`: what is on it) or Fit to Selected Art
  ## (`layers`): artboard `i` made the size of the artwork, the artwork staying where it is.
  ## Undoable in a step.
  if i < 0 or i >= d.boards.len: return
  let r = d.artBounds(if layers.len > 0: layers else: d.artboardArt(i))
  if r.w <= 0 or r.h <= 0 or r == d.boards[i].r: return
  let (sx, sy) = d.growCanvasFor(r, d.boardMargin(r))
  d.touchLayers()
  d.boards[i].r = rect(r.x + sx, r.y + sy, r.w, r.h)
  inc d.boardsVer
  d.markAll()

proc convertToArtboards*(d: Doc; layers: seq[Layer]): seq[int] =
  ## Object > Artboards > Convert to Artboards: each shape picked made an artboard of its size (the
  ## shape gone, as the drawing program does); the new artboards' numbers. Undoable in a step.
  var boxes: seq[(Rect, string)]
  var gone: seq[Layer]
  for L in layers:
    if not L.isShape or L.locked: continue
    let c = d.layerBox(L)
    if c.w < 1 or c.h < 1: continue
    boxes.add (c, L.name)
    gone.add L
  if boxes.len == 0: return
  d.touchLayers()
  for L in gone:
    let k = d.layers.find(L)
    if k >= 0 and d.layers.len > 1: d.layers.delete(k)
  d.cur = clamp(d.cur, 0, d.layers.high)
  for (c, _) in boxes:
    let n = d.addArtboard(c)
    if n >= 0: result.add n
  d.markAll()

proc deleteEmptyArtboards*(d: Doc): int =
  ## The Artboards panel's Delete Empty Artboards: those with no artwork on them gone; how many.
  ## Undoable in a step.
  var i = d.boards.high
  while i >= 0:
    var any = false
    let b = d.boards[i].r
    for L in d.layers:
      if L.group or L.background or not L.visible: continue
      let c = d.layerBox(L)
      if c.w > 0 and c.intersects(b): any = true
    if not any:
      d.deleteArtboard(i)
      inc result
    dec i

proc renameArtboard*(d: Doc; i: int; name: string) =
  ## The Artboards panel: artboard `i` named `name`. Undoable in a step.
  if i < 0 or i >= d.boards.len or name.len == 0 or d.boards[i].name == name: return
  d.touchLayers()
  d.boards[i].name = name
  inc d.boardsVer

proc reorderArtboard*(d: Doc; i, to: int) =
  ## The Artboards panel's Move Up / Move Down: artboard `i` made number `to` (the order they are
  ## exported, printed and rearranged in). Undoable in a step.
  if i < 0 or i >= d.boards.len or to < 0 or to >= d.boards.len or i == to: return
  d.touchLayers()
  let b = d.boards[i]
  d.boards.delete(i)
  d.boards.insert(b, to)
  d.boardCur = to
  inc d.boardsVer
  d.markAll()

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

## Light put on a photo after it was taken, and a photo made bigger keeping its detail --
## both worked out here, nothing sent anywhere:
##
## - Relight: lights put where you like on the picture -- a bulb, a spot, the sun -- each its
##   color, brightness and reach, over a light all round; with the picture's depth (how far
##   each part seems: `photoneural.depthMapOf`, or a map of your own) the faces turned to a
##   light are lit and those turned away left in shade, as a relief.
## - Upscale: the picture two, three or four times as big, its edges kept sharp along their
##   own lines (an edge-directed scaling) and the detail made again from the picture itself
##   (back-projection: made smaller, it is the picture it was made from).
##
## .. code-block:: nim
##   let fn = relight(@[RelightLight(x: 0.3, y: 0.25, height: 0.4, radius: 0.8, intensity: 1.2,
##                                   color: 0xFFFFE0B0'u32)], ambient = 0.45)
##   let big = upscaleDetail(img, 2)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[math, json]
import photo, photofx, parallel

type
  RelightKind* = enum
    ## What a light is.
    rlPoint = "Point",           ## a bulb: light all round it, less further off
    rlSpot = "Spot",             ## a spot: a cone of light the way it points
    rlSun = "Sun"                ## the sun: from a way, the same everywhere

  RelightLight* = object
    ## A light of Relight.
    kind*: RelightKind
    x*, y*: float                ## where it is, 0..1 of the picture across and down
    height*: float               ## how high over the picture, 0..1 of its size (0: 0.3)
    radius*: float               ## how far it reaches, 0..1 of its size (0: 0.7; the sun: all of it)
    intensity*: float            ## how bright, 0..3 (1: as the picture is lit)
    color*: uint32               ## its color
    angle*: float                ## a spot's, the sun's way, degrees (0 to the right, 90 up)
    cone*: float                 ## a spot: how wide, degrees (0: 50)

proc toJson*(l: RelightLight): JsonNode =
  %*{"kind": $l.kind, "x": l.x, "y": l.y, "height": l.height, "radius": l.radius, "intensity": l.intensity,
     "color": int64(l.color), "angle": l.angle, "cone": l.cone}

proc relightLightFrom*(j: JsonNode): RelightLight =
  for k in RelightKind:
    if $k == j{"kind"}.getStr: result.kind = k
  result.x = clamp(j{"x"}.getFloat(0.5), -1.0, 2.0)
  result.y = clamp(j{"y"}.getFloat(0.5), -1.0, 2.0)
  result.height = clamp(j{"height"}.getFloat(0.3), 0.0, 5.0)
  result.radius = clamp(j{"radius"}.getFloat(0.7), 0.0, 10.0)
  result.intensity = clamp(j{"intensity"}.getFloat(1), 0.0, 3.0)
  result.color = uint32(j{"color"}.getBiggestInt(0xFFFFFFFF) and 0xFFFFFFFF)
  result.angle = j{"angle"}.getFloat(0)
  result.cone = clamp(j{"cone"}.getFloat(50), 1.0, 179.0)

proc relight*(lights: seq[RelightLight]; ambient = 0.5; depth: seq[uint8] = @[]; depthW = 0; depthH = 0;
              relief = 1.0): FilterFn =
  ## Filter > Render > Relight: the picture lit again by `lights` over `ambient` (0..1 of its
  ## own light). `depth` (`depthW` x `depthH`, 0 near .. 255 far; empty: a flat picture) makes
  ## its relief, `relief` 0..3 times as deep.
  result = proc (src: Img; inner: Rect): Img =
    let w = src.w
    let h = src.h
    result = newImgUninit(w, h)
    if w == 0 or h == 0: return
    let size = max(w, h).float
    # (the surface: how high each point is, smoothed, its normals from that)
    var hz: seq[float32]
    let fullW0 = if filterSize[0] > 0: filterSize[0] else: w
    let fullH0 = if filterSize[1] > 0: filterSize[1] else: h
    if depth.len > 0 and depthW > 0 and depthH > 0 and depth.len == depthW * depthH:
      hz = newSeq[float32](w * h)
      let ox = filterOrigin[0]
      let oy = filterOrigin[1]
      for y in 0 ..< h:
        let sy = clamp((y + oy) * depthH div max(1, fullH0), 0, depthH - 1)
        for x in 0 ..< w:
          let sx = clamp((x + ox) * depthW div max(1, fullW0), 0, depthW - 1)
          hz[y * w + x] = float32(255 - int(depth[sy * depthW + sx])) / 255 * float32(relief) * float32(size) * 0.03
      # (blurred in proportion to the picture: the relief of shapes, not of their grain, and an
      # object's outline a slope, not a step; running sums, as quick at any radius)
      let br = max(2, int(size / 120))
      var tmp = hz
      let hzp = cast[ptr UncheckedArray[float32]](addr hz[0])
      let tp = cast[ptr UncheckedArray[float32]](addr tmp[0])
      for pass in 0 ..< 3:
        parallelRows(h, y):
          var s = 0'f32
          for k in -br .. br: s += hzp[y * w + clamp(k, 0, w - 1)]
          for x in 0 ..< w:
            tp[y * w + x] = s / float32(2 * br + 1)
            s += hzp[y * w + min(w - 1, x + br + 1)] - hzp[y * w + max(0, x - br)]
        parallelRows(w, x):
          var s = 0'f32
          for k in -br .. br: s += tp[clamp(k, 0, h - 1) * w + x]
          for y in 0 ..< h:
            hzp[y * w + x] = s / float32(2 * br + 1)
            s += tp[min(h - 1, y + br + 1) * w + x] - tp[max(0, y - br) * w + x]
    let hp = if hz.len > 0: cast[ptr UncheckedArray[float32]](addr hz[0]) else: nil
    let sp = cast[ptr UncheckedArray[uint32]](unsafeAddr src.px[0])
    let op = cast[ptr UncheckedArray[uint32]](addr result.px[0])
    var ls = lights
    let lp = if ls.len > 0: cast[ptr UncheckedArray[RelightLight]](addr ls[0]) else: nil
    let nl = ls.len
    let amb = clamp(ambient, 0.0, 2.0)
    let fx = filterOrigin[0].float
    let fy = filterOrigin[1].float
    let fullW = if filterSize[0] > 0: filterSize[0].float else: w.float
    let fullH = if filterSize[1] > 0: filterSize[1].float else: h.float
    let full = max(fullW, fullH)
    parallelRows(h, y):
      for x in 0 ..< w:
        let i = y * w + x
        let p = sp[i]
        var nx = 0.0
        var ny = 0.0
        var nz = 1.0
        var z = 0.0
        if hp != nil:
          let xl = max(0, x - 1)
          let xr = min(w - 1, x + 1)
          let yu = max(0, y - 1)
          let yd = min(h - 1, y + 1)
          let gx = float(hp[y * w + xr] - hp[y * w + xl]) / float(max(1, xr - xl))
          let gy = float(hp[yd * w + x] - hp[yu * w + x]) / float(max(1, yd - yu))
          let n = sqrt(gx * gx + gy * gy + 1)
          nx = -gx / n
          ny = -gy / n
          nz = 1 / n
          z = float(hp[i])
        var lr = amb
        var lg = amb
        var lb = amb
        let px = x.float + fx
        let py = y.float + fy
        for k in 0 ..< nl:
          let L = lp[k]
          var vx, vy, vz: float
          var att = 1.0
          if L.kind == rlSun:
            let a = degToRad(L.angle)
            vx = cos(a)
            vy = -sin(a)
            vz = if L.height > 0: L.height * 3 else: 1.0
          else:
            let lh = (if L.height > 0: L.height else: 0.3) * full
            vx = L.x * fullW - px
            vy = L.y * fullH - py
            vz = lh - z
            let dist = sqrt(vx * vx + vy * vy)
            let reach = (if L.radius > 0: L.radius else: 0.7) * full
            att = max(0.0, 1 - dist / reach)
            att = att * att
            if L.kind == rlSpot:
              # (a cone in space from the light down to a place on the picture -- half its reach
              # the way it points: its pool of light an ellipse there, soft at its edge)
              let a = degToRad(L.angle)
              let aim = reach * 0.5
              var dx = cos(a) * aim
              var dy = -sin(a) * aim
              var dz = -lh
              let dn = sqrt(dx * dx + dy * dy + dz * dz)
              dx /= dn
              dy /= dn
              dz /= dn
              let pl = sqrt(vx * vx + vy * vy + vz * vz)
              if pl > 1e-6:
                let c = -(vx * dx + vy * dy + vz * dz) / pl
                let half = degToRad((if L.cone > 0: L.cone else: 50.0) / 2)
                let edge = cos(half)
                att = clamp(1.5 - dist / reach, 0.0, 1.0) *
                      clamp((c - edge) / max(1e-6, (1 - edge) * 0.35), 0.0, 1.0)
          let vl = sqrt(vx * vx + vy * vy + vz * vz)
          if vl < 1e-9 or att <= 0: continue
          let ndl = max(0.0, (nx * vx + ny * vy + nz * vz) / vl)
          let f = ndl * att * L.intensity
          lr += f * float((L.color shr 16) and 255) / 255
          lg += f * float((L.color shr 8) and 255) / 255
          lb += f * float(L.color and 255) / 255
        template ch(sh: int; k: float): uint32 =
          uint32(clamp(int(round(float((p shr sh) and 255) * k)), 0, 255))
        op[i] = (p and 0xFF000000'u32) or (ch(16, lr) shl 16) or (ch(8, lg) shl 8) or ch(0, lb)

# ---- Upscale ------------------------------------------------------------------------------------------

proc bicubicUp(src: Img; k: int): Img =
  ## (bigger by `k`, each new pixel from the 4 x 4 round it -- Catmull-Rom, premultiplied)
  let w = src.w
  let h = src.h
  let nw = w * k
  let nh = h * k
  result = newImgUninit(nw, nh)
  let sp = cast[ptr UncheckedArray[uint32]](unsafeAddr src.px[0])
  let op = cast[ptr UncheckedArray[uint32]](addr result.px[0])
  proc cr(t: float): array[4, float] =
    let t2 = t * t
    let t3 = t2 * t
    [-0.5 * t3 + t2 - 0.5 * t, 1.5 * t3 - 2.5 * t2 + 1, -1.5 * t3 + 2 * t2 + 0.5 * t, 0.5 * t3 - 0.5 * t2]
  parallelRows(nh, y):
    let fy = (y.float + 0.5) / k.float - 0.5
    let y0 = int(floor(fy))
    let wy = cr(fy - y0.float)
    for x in 0 ..< nw:
      let fxx = (x.float + 0.5) / k.float - 0.5
      let x0 = int(floor(fxx))
      let wx = cr(fxx - x0.float)
      var a, r, g, b = 0.0
      for j in 0 .. 3:
        let yy = clamp(y0 - 1 + j, 0, h - 1)
        for i in 0 .. 3:
          let xx = clamp(x0 - 1 + i, 0, w - 1)
          let p = sp[yy * w + xx]
          let wt = wx[i] * wy[j]
          let pa = float(p shr 24)
          a += pa * wt
          r += float((p shr 16) and 255) * pa * wt
          g += float((p shr 8) and 255) * pa * wt
          b += float(p and 255) * pa * wt
      let ia = clamp(int(round(a)), 0, 255)
      if ia == 0:
        op[y * nw + x] = 0
      else:
        op[y * nw + x] = (uint32(ia) shl 24) or (uint32(clamp(int(round(r / a)), 0, 255)) shl 16) or
                         (uint32(clamp(int(round(g / a)), 0, 255)) shl 8) or uint32(clamp(int(round(b / a)), 0, 255))

proc edgeDirected(src: Img; up: var Img; k: int) =
  ## (where the picture has an edge, the new pixels taken along it -- not across it, which
  ## blurs it and makes stairs of a slant: from the two neighbours the edge runs between)
  let w = src.w
  let h = src.h
  let nw = up.w
  let sp = cast[ptr UncheckedArray[uint32]](unsafeAddr src.px[0])
  let op = cast[ptr UncheckedArray[uint32]](addr up.px[0])
  template lum(p: uint32): float =
    float((p shr 16) and 255) * 0.299 + float((p shr 8) and 255) * 0.587 + float(p and 255) * 0.114
  parallelRows(h, sy):
    for sx in 0 ..< w:
      let c = sp[sy * w + sx]
      let xl = max(0, sx - 1)
      let xr = min(w - 1, sx + 1)
      let yu = max(0, sy - 1)
      let yd = min(h - 1, sy + 1)
      let gx = lum(sp[sy * w + xr]) - lum(sp[sy * w + xl])
      let gy = lum(sp[yd * w + sx]) - lum(sp[yu * w + sx])
      let g = sqrt(gx * gx + gy * gy)
      if g < 24: continue                       # (flat: the cubic is right there)
      # (the edge runs across the gradient: its way, the neighbours before and after along it)
      let ex = -gy / g
      let ey = gx / g
      for j in 0 ..< k:
        for i in 0 ..< k:
          let ux = (i.float + 0.5) / k.float - 0.5
          let uy = (j.float + 0.5) / k.float - 0.5
          # (how far the new point is along the edge, and across it)
          let along = ux * ex + uy * ey
          let ax = clamp(sx + int(round(ex * sgn(along).float)), 0, w - 1)
          let ay = clamp(sy + int(round(ey * sgn(along).float)), 0, h - 1)
          let q = sp[ay * w + ax]
          let t = min(1.0, abs(along)) * 0.5
          # (the point's own pixel, a little of the next along the edge; the cubic for the rest)
          let o = op[(sy * k + j) * nw + sx * k + i]
          template ch(sh: int): uint32 =
            let along0 = float((c shr sh) and 255) * (1 - t) + float((q shr sh) and 255) * t
            uint32(clamp(int(round(along0 * 0.6 + float((o shr sh) and 255) * 0.4)), 0, 255))
          op[(sy * k + j) * nw + sx * k + i] = (o and 0xFF000000'u32) or (ch(16) shl 16) or (ch(8) shl 8) or ch(0)

proc downBox(src: Img; k: int; w, h: int): Img =
  ## (made `k` times smaller again, a box average: what the picture it came from would be)
  result = newImgUninit(w, h)
  let sp = cast[ptr UncheckedArray[uint32]](unsafeAddr src.px[0])
  let op = cast[ptr UncheckedArray[uint32]](addr result.px[0])
  let nw = src.w
  let n = k * k
  parallelRows(h, y):
    for x in 0 ..< w:
      var a, r, g, b = 0
      for j in 0 ..< k:
        for i in 0 ..< k:
          let p = sp[(y * k + j) * nw + x * k + i]
          a += int(p shr 24)
          r += int((p shr 16) and 255)
          g += int((p shr 8) and 255)
          b += int(p and 255)
      op[y * w + x] = (uint32(a div n) shl 24) or (uint32(r div n) shl 16) or (uint32(g div n) shl 8) or
                      uint32(b div n)

proc upscaleDetail*(src: Img; factor = 2; passes = 3; sharpen = 0.35): Img =
  ## Image > Upscale (Preserve Details 2.0): `src` `factor` (2..4) times as big -- a cubic first,
  ## its edges made again along their own lines, then (`passes` times) what it is short of when
  ## made smaller again put back (back-projection), a touch of sharpening (`sharpen` 0..1) on
  ## its edges. Nothing invented: what is there kept, sharper.
  let k = clamp(factor, 2, 4)
  let w = src.w
  let h = src.h
  if w == 0 or h == 0: return newImg(w * k, h * k)
  result = bicubicUp(src, k)
  edgeDirected(src, result, k)
  for pass in 0 ..< clamp(passes, 0, 8):
    let back = downBox(result, k, w, h)
    # (what the smaller one lacks, made big and added)
    var err = newImgUninit(w, h)
    for i in 0 ..< w * h:
      let a = src.px[i]
      let b = back.px[i]
      template d(sh: int): uint32 = uint32(clamp(int((a shr sh) and 255) - int((b shr sh) and 255) + 128, 0, 255))
      err.px[i] = (a and 0xFF000000'u32) or (d(16) shl 16) or (d(8) shl 8) or d(0)
    let eu = bicubicUp(err, k)
    let rp = cast[ptr UncheckedArray[uint32]](addr result.px[0])
    let ep = cast[ptr UncheckedArray[uint32]](unsafeAddr eu.px[0])
    parallelFor(result.px.len, proc (lo, hi: int) =
      for i in lo ..< hi:
        let p = rp[i]
        let e = ep[i]
        template ch(sh: int): uint32 =
          uint32(clamp(int((p shr sh) and 255) + int((e shr sh) and 255) - 128, 0, 255))
        rp[i] = (p and 0xFF000000'u32) or (ch(16) shl 16) or (ch(8) shl 8) or ch(0)
    , grain = 16384)
  if sharpen > 0:
    # (an unsharp mask on the edges alone: flat parts and their grain left smooth)
    let s = clamp(sharpen, 0.0, 1.0)
    let nw = result.w
    let nh = result.h
    let blurred = result
    let bp = cast[ptr UncheckedArray[uint32]](unsafeAddr blurred.px[0])
    let rp = cast[ptr UncheckedArray[uint32]](addr result.px[0])
    var outp = newImgUninit(nw, nh)
    let op = cast[ptr UncheckedArray[uint32]](addr outp.px[0])
    parallelRows(nh, y):
      for x in 0 ..< nw:
        let c = bp[y * nw + x]
        var r, g, b = 0
        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
          let q = bp[clamp(y + dy, 0, nh - 1) * nw + clamp(x + dx, 0, nw - 1)]
          r += int((q shr 16) and 255)
          g += int((q shr 8) and 255)
          b += int(q and 255)
        let dr = int((c shr 16) and 255) - r div 4
        let dg = int((c shr 8) and 255) - g div 4
        let db = int(c and 255) - b div 4
        let edge = abs(dr) + abs(dg) + abs(db) > 18
        if not edge:
          op[y * nw + x] = c
          continue
        template ch(sh, dv: int): uint32 = uint32(clamp(int((c shr sh) and 255) + int(round(dv.float * s)), 0, 255))
        op[y * nw + x] = (c and 0xFF000000'u32) or (ch(16, dr) shl 16) or (ch(8, dg) shl 8) or ch(0, db)
    discard rp
    result = outp

# ---- an object's shadow --------------------------------------------------------------------------------

proc shadowOf*(src: Img; sel: openArray[uint8]; reach = 0.8): seq[uint8] =
  ## The shadow an object casts (`sel` the object, 0..255 a pixel): the ground round it that is
  ## darker than the ground further off -- the same color, less light -- and touches it, up to
  ## `reach` times its size away. For Remove: the object and its shadow go together.
  let w = src.w
  let h = src.h
  result = newSeq[uint8](w * h)
  if sel.len != w * h or w == 0 or h == 0: return
  var x0 = w
  var y0 = h
  var x1, y1 = -1
  for y in 0 ..< h:
    for x in 0 ..< w:
      if sel[y * w + x] >= 128:
        x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
  if x1 < 0: return
  let size = max(x1 - x0, y1 - y0) + 1
  let r = max(4, int(float(size) * reach))
  # (the light the ground has away from the object: the ring further off)
  proc lumOf(p: uint32): float =
    float((p shr 16) and 255) * 0.299 + float((p shr 8) and 255) * 0.587 + float(p and 255) * 0.114
  let bx0 = max(0, x0 - 2 * r)
  let by0 = max(0, y0 - 2 * r)
  let bx1 = min(w - 1, x1 + 2 * r)
  let by1 = min(h - 1, y1 + 2 * r)
  # (each point's distance from the object, in steps -- a few passes of a chamfer)
  var dist = newSeq[int32](w * h)
  for i in 0 ..< w * h: dist[i] = (if sel[i] >= 128: 0'i32 else: int32.high div 2)
  for y in by0 .. by1:
    for x in bx0 .. bx1:
      let i = y * w + x
      if x > bx0: dist[i] = min(dist[i], dist[i - 1] + 1)
      if y > by0: dist[i] = min(dist[i], dist[i - w] + 1)
  for y in countdown(by1, by0):
    for x in countdown(bx1, bx0):
      let i = y * w + x
      if x < bx1: dist[i] = min(dist[i], dist[i + 1] + 1)
      if y < by1: dist[i] = min(dist[i], dist[i + w] + 1)
  var far = 0.0
  var nf = 0
  for y in by0 .. by1:
    for x in bx0 .. bx1:
      let d = dist[y * w + x]
      if d > r and d <= 2 * r:
        far += lumOf(src.px[y * w + x])
        inc nf
  if nf == 0: return
  let ground = far / nf.float
  if ground < 12: return                       # (a dark picture all over: no shadow to tell)
  # (darker than the ground, near the object)
  var cand = newSeq[bool](w * h)
  for y in by0 .. by1:
    for x in bx0 .. bx1:
      let i = y * w + x
      let d = dist[i]
      if d == 0 or d > r: continue
      let l = lumOf(src.px[i])
      if l < ground * 0.82 and l > ground * 0.12: cand[i] = true
  # (only what joins the object)
  var keep = newSeq[bool](w * h)
  var stack: seq[int]
  for y in by0 .. by1:
    for x in bx0 .. bx1:
      let i = y * w + x
      if dist[i] == 1 and cand[i]:
        keep[i] = true
        stack.add i
  while stack.len > 0:
    let i = stack.pop()
    let px = i mod w
    let py = i div w
    for (nx, ny) in [(px - 1, py), (px + 1, py), (px, py - 1), (px, py + 1)]:
      if nx < bx0 or ny < by0 or nx > bx1 or ny > by1: continue
      let j = ny * w + nx
      if cand[j] and not keep[j]:
        keep[j] = true
        stack.add j
  # (soft: how dark it is, and a pixel round it)
  for y in by0 .. by1:
    for x in bx0 .. bx1:
      let i = y * w + x
      if keep[i]:
        let l = lumOf(src.px[i])
        result[i] = uint8(clamp(int(round((1 - l / ground) / 0.18 * 255)), 128, 255))
  var grown = result
  for y in by0 .. by1:
    for x in bx0 .. bx1:
      let i = y * w + x
      if result[i] != 0 or sel[i] >= 128: continue
      var m = 0
      for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]:
        if nx >= 0 and ny >= 0 and nx < w and ny < h: m = max(m, int(result[ny * w + nx]))
      if m > 0: grown[i] = uint8(m div 2)
  result = grown

proc upscaleDoc*(d: Doc; factor = 2; sharpen = 0.35; dpi = 0.0) =
  ## Image > Upscale: the whole image `factor` (2..4) times as big -- its type and shapes drawn
  ## again at the size (sharp as ever), its pixels made bigger by `upscaleDetail`. (Undoable:
  ## `snapStep` first.) Raises `ValueError` when too big.
  let k = clamp(factor, 2, 4)
  let w = d.w
  let h = d.h
  var before: seq[seq[uint32]]
  for L in d.layers: before.add (if L.px.len == w * h and not L.isText and not L.isShape and not L.gray: L.px else: @[])
  d.imageSize(w * k, h * k, rsLanczos, dpi)
  for i, L in d.layers:
    if before[i].len == 0 or L.px.len != d.w * d.h: continue
    L.px = upscaleDetail(Img(w: w, h: h, px: before[i]), k, sharpen = sharpen).px
    inc L.ver
  d.markAll()

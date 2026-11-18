## Warping a photo: Liquify (push, twirl, pucker, bloat and reconstruct
## with a brush, on a mesh), Lens Correction (distortion, chromatic
## aberration, vignette, perspective, angle, scale), Straighten, Warp (a
## grid of 4 x 4 points, or a style), Puppet Warp (pins), Smart Objects
## drawn from what they hold, and the Blur Gallery (Field, Iris and
## Tilt-Shift blurs).
##
## ```nim
## var m = newLiquifyMesh(img.w, img.h)
## m.push(200, 150, 12, 0, radius = 60, pressure = 0.5)   # a drag of the Forward Warp
## let out = liquifyImg(img, m)
## ```

import std/math
import gfx, photo, photofx, parallel, textengine

template pptr(s: seq[uint32]): ptr UncheckedArray[uint32] =
  cast[ptr UncheckedArray[uint32]](if s.len > 0: unsafeAddr s[0] else: nil)

template fptr(s: seq[float32]): ptr UncheckedArray[float32] =
  cast[ptr UncheckedArray[float32]](if s.len > 0: unsafeAddr s[0] else: nil)

{.push boundChecks: off, overflowChecks: off.}

proc bilinear(sp: ptr UncheckedArray[uint32]; w, h: int; x, y: float32; edge: uint32; extend: bool): uint32 =
  ## The picture at `x`, `y` (pixel centres at .5), read between pixels;
  ## outside it `edge`, or the nearest edge pixel with `extend`.
  let fx = x - 0.5'f32
  let fy = y - 0.5'f32
  if not extend and (fx < -1 or fy < -1 or fx > float32(w) or fy > float32(h)): return edge
  var x0 = int(floor(fx))
  var y0 = int(floor(fy))
  let tx = fx - float32(x0)
  let ty = fy - float32(y0)
  var acc: array[4, float32]
  for (dx, dy, wt) in [(0, 0, (1 - tx) * (1 - ty)), (1, 0, tx * (1 - ty)), (0, 1, (1 - tx) * ty), (1, 1, tx * ty)]:
    if wt <= 0: continue
    let xx = x0 + dx
    let yy = y0 + dy
    let p = if xx >= 0 and yy >= 0 and xx < w and yy < h: sp[yy * w + xx]
            elif extend: sp[clamp(yy, 0, h - 1) * w + clamp(xx, 0, w - 1)]
            else: edge
    let a = float32(p shr 24) * wt
    acc[0] += a
    acc[1] += float32((p shr 16) and 255) * a
    acc[2] += float32((p shr 8) and 255) * a
    acc[3] += float32(p and 255) * a
  if acc[0] <= 0.01: return 0
  (uint32(min(255'f32, acc[0] + 0.5)) shl 24) or (uint32(acc[1] / acc[0] + 0.5) shl 16) or
    (uint32(acc[2] / acc[0] + 0.5) shl 8) or uint32(acc[3] / acc[0] + 0.5)

{.pop.}

# ---- Liquify ----------------------------------------------------------------------------------------------

type LiquifyMesh* = object
  ## How each part of a picture has moved: at each point of a mesh over it,
  ## where the picture shown there comes from (`dx`, `dy`, in pixels of the
  ## picture). Made by brushing; read between its points.
  w*, h*: int                    ## the mesh's points across and down
  imgW*, imgH*: int              ## the picture's size
  step*: float                   ## picture pixels between points
  dx*, dy*: seq[float32]         ## at each point, how far the picture shown there comes from
  frozen*: seq[float32]          ## Freeze Mask: how much each point is kept from moving (0..1; empty none)

proc newLiquifyMesh*(imgW, imgH: int; maxSide = 512): LiquifyMesh =
  ## A mesh over a picture `imgW` x `imgH` that has not moved.
  result.imgW = max(1, imgW)
  result.imgH = max(1, imgH)
  result.step = max(1.0, max(imgW, imgH) / maxSide)
  result.w = int(ceil(result.imgW.float / result.step)) + 1
  result.h = int(ceil(result.imgH.float / result.step)) + 1
  result.dx = newSeq[float32](result.w * result.h)
  result.dy = newSeq[float32](result.w * result.h)

proc isFlat*(m: LiquifyMesh): bool =
  ## Nothing has moved.
  for v in m.dx:
    if v != 0: return false
  for v in m.dy:
    if v != 0: return false
  true

proc at*(m: LiquifyMesh; x, y: float): (float32, float32) =
  ## Where the picture shown at `x`, `y` comes from, as a move.
  if m.w == 0: return (0'f32, 0'f32)
  let gx = clamp(x / m.step, 0.0, float(m.w - 1))
  let gy = clamp(y / m.step, 0.0, float(m.h - 1))
  let x0 = min(int(gx), m.w - 2).max(0)
  let y0 = min(int(gy), m.h - 2).max(0)
  let x1 = min(x0 + 1, m.w - 1)
  let y1 = min(y0 + 1, m.h - 1)
  let tx = float32(gx - x0.float)
  let ty = float32(gy - y0.float)
  template lerp2(s: seq[float32]): float32 =
    (s[y0 * m.w + x0] * (1 - tx) + s[y0 * m.w + x1] * tx) * (1 - ty) +
      (s[y1 * m.w + x0] * (1 - tx) + s[y1 * m.w + x1] * tx) * ty
  (lerp2(m.dx), lerp2(m.dy))

proc falloff(d, r: float): float {.inline.} =
  ## The brush: full in the middle, nothing at its edge (smooth).
  if d >= r: 0.0
  else:
    let t = d / r
    let u = 1 - t * t
    u * u

template brushPoints(m: LiquifyMesh; cx, cy, radius: float; body: untyped) =
  ## `body` for each mesh point under the brush, with `i`, `px`, `py`
  ## (the point in picture pixels) and `w` (the brush there, 0..1).
  let gx0 = max(0, int(floor((cx - radius) / m.step)))
  let gy0 = max(0, int(floor((cy - radius) / m.step)))
  let gx1 = min(m.w - 1, int(ceil((cx + radius) / m.step)))
  let gy1 = min(m.h - 1, int(ceil((cy + radius) / m.step)))
  for gy {.inject.} in gy0 .. gy1:
    for gx {.inject.} in gx0 .. gx1:
      let px {.inject.} = gx.float * m.step
      let py {.inject.} = gy.float * m.step
      let i {.inject.} = gy * m.w + gx
      let w {.inject.} = falloff(hypot(px - cx, py - cy), radius) *
                         (if m.frozen.len > 0: 1 - m.frozen[i].float else: 1.0)
      if w <= 0: continue
      body

proc push*(m: var LiquifyMesh; cx, cy, mx, my: float; radius: float; pressure = 0.5) =
  ## Forward Warp: what is under the brush at `cx`, `cy` pushed by `mx`,
  ## `my` (a part of a drag), most in the middle.
  var ndx = m.dx
  var ndy = m.dy
  m.brushPoints(cx, cy, radius):
    let k = w * pressure
    let (ox, oy) = m.at(px - mx * k, py - my * k)
    ndx[i] = ox - float32(mx * k)
    ndy[i] = oy - float32(my * k)
  m.dx = ndx
  m.dy = ndy

proc reconstruct*(m: var LiquifyMesh; cx, cy, radius: float; pressure = 0.5) =
  ## Reconstruct: back toward how it was, under the brush.
  m.brushPoints(cx, cy, radius):
    let k = float32(1 - w * pressure)
    m.dx[i] *= k
    m.dy[i] *= k

proc twirl*(m: var LiquifyMesh; cx, cy, radius: float; pressure = 0.5; clockwise = true) =
  ## Twirl: what is under the brush turned around its middle (a dab).
  var ndx = m.dx
  var ndy = m.dy
  let turn = (if clockwise: 1.0 else: -1.0) * 0.25 * pressure
  m.brushPoints(cx, cy, radius):
    let a = -turn * w
    let rx = px - cx
    let ry = py - cy
    let qx = cx + rx * cos(a) - ry * sin(a)
    let qy = cy + rx * sin(a) + ry * cos(a)
    let (ox, oy) = m.at(qx, qy)
    ndx[i] = ox + float32(qx - px)
    ndy[i] = oy + float32(qy - py)
  m.dx = ndx
  m.dy = ndy

proc pucker*(m: var LiquifyMesh; cx, cy, radius: float; pressure = 0.5; bloat = false) =
  ## Pucker: what is under the brush drawn in toward its middle (a dab);
  ## Bloat (`bloat`): pushed out from it.
  var ndx = m.dx
  var ndy = m.dy
  let s = (if bloat: -1.0 else: 1.0) * 0.12 * pressure
  m.brushPoints(cx, cy, radius):
    let k = 1 + s * w
    let qx = cx + (px - cx) * k
    let qy = cy + (py - cy) * k
    let (ox, oy) = m.at(qx, qy)
    ndx[i] = ox + float32(qx - px)
    ndy[i] = oy + float32(qy - py)
  m.dx = ndx
  m.dy = ndy

proc reconstructAll*(m: var LiquifyMesh) =
  ## Restore All.
  for v in m.dx.mitems: v = 0
  for v in m.dy.mitems: v = 0

proc smooth*(m: var LiquifyMesh; cx, cy, radius: float; pressure = 0.5) =
  ## Smooth: the moves under the brush evened out with their neighbors'
  ## (a jagged warp made gentle).
  var ndx = m.dx
  var ndy = m.dy
  m.brushPoints(cx, cy, radius):
    var sx, sy = 0'f32
    var n = 0'f32
    for oy in -1 .. 1:
      for ox in -1 .. 1:
        let x = clamp(gx + ox, 0, m.w - 1)
        let y = clamp(gy + oy, 0, m.h - 1)
        sx += m.dx[y * m.w + x]
        sy += m.dy[y * m.w + x]
        n += 1
    let k = float32(w * pressure)
    ndx[i] = m.dx[i] + (sx / n - m.dx[i]) * k
    ndy[i] = m.dy[i] + (sy / n - m.dy[i]) * k
  m.dx = ndx
  m.dy = ndy

proc pushLeft*(m: var LiquifyMesh; cx, cy, mx, my: float; radius: float; pressure = 0.5) =
  ## Push Left: what is under the brush moved to the left of the way it
  ## goes (down when it goes right; Alt: to the right).
  let n = hypot(mx, my)
  if n < 1e-9: return
  m.push(cx, cy, my / n * n * 0.5, -mx / n * n * 0.5, radius, pressure)

proc freeze*(m: var LiquifyMesh; cx, cy, radius: float; pressure = 1.0; thaw = false) =
  ## Freeze Mask: the points under the brush kept from moving (Thaw: let
  ## go again).
  if m.frozen.len != m.w * m.h: m.frozen = newSeq[float32](m.w * m.h)
  let gx0 = max(0, int(floor((cx - radius) / m.step)))
  let gy0 = max(0, int(floor((cy - radius) / m.step)))
  let gx1 = min(m.w - 1, int(ceil((cx + radius) / m.step)))
  let gy1 = min(m.h - 1, int(ceil((cy + radius) / m.step)))
  for gy in gy0 .. gy1:
    for gx in gx0 .. gx1:
      let f = falloff(hypot(gx.float * m.step - cx, gy.float * m.step - cy), radius) * pressure
      if f <= 0: continue
      let i = gy * m.w + gx
      m.frozen[i] = if thaw: max(0'f32, m.frozen[i] - float32(f)) else: min(1'f32, m.frozen[i] + float32(f))

proc frozenAt*(m: LiquifyMesh; x, y: float): float32 =
  ## How frozen the picture is at `x`, `y` (0..1).
  if m.frozen.len != m.w * m.h: return 0
  let gx = clamp(int(round(x / m.step)), 0, m.w - 1)
  let gy = clamp(int(round(y / m.step)), 0, m.h - 1)
  m.frozen[gy * m.w + gx]

proc liquifyImg*(src: Img; m: LiquifyMesh; ox = 0.0; oy = 0.0; scale = 1.0; preview = false): Img =
  ## `src` moved by the mesh. `src` is the picture, or a part of it (its
  ## top left at `ox`, `oy` in the picture) or a smaller copy (`scale`
  ## picture pixels per pixel: a preview). On all the cores -- a `preview`
  ## on the GPU when frames are drawn with it (`gpuWarpMesh`: as near as a
  ## preview needs; the picture itself always the CPU's).
  let w = src.w
  let h = src.h
  if w <= 0 or h <= 0: return newImg(w, h)
  let full = ox == 0 and oy == 0
  if preview and w * h >= 40_000 and gpuFiltersReady():
    let g = gpuWarpMesh(src.px, w, h, m.dx, m.dy, m.w, m.h, m.step, ox, oy, scale, full)
    if g.len == w * h: return Img(w: w, h: h, px: g)
  result = newImg(w, h)
  let sp = pptr(src.px)
  let dp = pptr(result.px)
  let mp = addr m
  parallelRows(h, y):
    for x in 0 ..< w:
      let fx = ox + (x.float + 0.5) * scale
      let fy = oy + (y.float + 0.5) * scale
      let (mx, my) = mp[].at(fx, fy)
      # (where it comes from, in pixels of `src`)
      let sx = float32((fx + mx.float - ox) / scale)
      let sy = float32((fy + my.float - oy) / scale)
      dp[y * w + x] = bilinear(sp, w, h, sx, sy, 0, full)

proc liquify*(m: LiquifyMesh): FilterFn =
  ## Liquify as a filter of the picture the mesh was made for.
  result = proc (src: Img; inner: Rect): Img = liquifyImg(src, m)

# ---- Lens Correction ---------------------------------------------------------------------------------------

type
  LensEdge* = enum
    ## What fills where the corrected picture leaves the frame empty.
    leTransparent = "Transparency", leExtend = "Edge Extension", leColor = "Background Color"

  LensCorrection* = object
    ## The settings, each 0 when it changes nothing.
    distortion*: int             ## -100..100: + takes out barrel (bulging) distortion, - pincushion
    redCyan*, blueYellow*: int   ## -100..100: chromatic aberration (color fringes at the edges)
    vignette*: int               ## -100..100: + lightens dark corners
    vignetteMid*: int            ## 0..100: how far in the vignette reaches (50)
    vertical*, horizontal*: int  ## -100..100: perspective (converging lines made upright)
    angle*: float                ## degrees, clockwise
    scale*: int                  ## 50..150 (100)
    edge*: LensEdge              ## what fills the empty edges
    edgeColor*: uint32           ## ... with `leColor` (ARGB)

proc lensDefault*(): LensCorrection =
  ## Settings that change nothing (the vignette's midpoint and the scale at
  ## their defaults).
  LensCorrection(vignetteMid: 50, scale: 100)

proc isNeutral*(c: LensCorrection): bool =
  ## The settings change nothing.
  c.distortion == 0 and c.redCyan == 0 and c.blueYellow == 0 and c.vignette == 0 and c.vertical == 0 and
    c.horizontal == 0 and c.angle == 0 and (c.scale == 100 or c.scale == 0)

proc lensImg*(src: Img; c: LensCorrection; fullW = 0; fullH = 0; ox = 0.0; oy = 0.0; scale = 1.0): Img =
  ## `src` corrected. `fullW` x `fullH`: the picture's size (0: `src`'s);
  ## `src` is it, a part (at `ox`, `oy`) or a smaller copy (`scale`).
  let w = src.w
  let h = src.h
  result = newImg(w, h)
  if w <= 0 or h <= 0: return
  let W = (if fullW > 0: fullW.float else: w.float * scale)
  let H = (if fullH > 0: fullH.float else: h.float * scale)
  let cx = W / 2
  let cy = H / 2
  let R = sqrt(cx * cx + cy * cy)                 # (half the diagonal: 1 in the corners)
  let k = -float(clamp(c.distortion, -100, 100)) / 100 * 0.35
  let car = float(clamp(c.redCyan, -100, 100)) / 100 * 0.006
  let cab = float(clamp(c.blueYellow, -100, 100)) / 100 * 0.006
  let vig = float(clamp(c.vignette, -100, 100)) / 100
  let mid = clamp(c.vignetteMid, 0, 100).float / 100
  let pv = float(clamp(c.vertical, -100, 100)) / 100 * 0.6
  let ph = float(clamp(c.horizontal, -100, 100)) / 100 * 0.6
  let ang = degToRad(c.angle)
  let sc = (if c.scale <= 0: 100 else: clamp(c.scale, 10, 400)).float / 100
  let edge = case c.edge
             of leColor: c.edgeColor or 0xFF000000'u32
             else: 0'u32
  let extend = c.edge == leExtend
  let sp = pptr(src.px)
  let dp = pptr(result.px)
  let aspect = H / W
  parallelRows(h, y):
    for x in 0 ..< w:
      # the output pixel in units of the half diagonal, from the middle
      var u = (ox + (x.float + 0.5) * scale - cx) / R
      var v = (oy + (y.float + 0.5) * scale - cy) / R
      # scale, then turn (where it comes from: the other way)
      u /= sc
      v /= sc
      let ca = cos(-ang)
      let sa = sin(-ang)
      let ru = u * ca - v * sa
      let rv = u * sa + v * ca
      u = ru
      v = rv
      # perspective: the far side made as wide as the near one
      let wv = 1 + pv * v / max(0.01, aspect) * 0.5 + ph * u * 0.5
      u /= wv
      v /= wv
      # lens distortion, the channels each a little apart
      let r2 = u * u + v * v
      let f = 1 + k * r2
      var o: array[3, uint32]
      var a = 0'u32
      for ch in 0 .. 2:
        let fc = f * (1 + (if ch == 0: car elif ch == 2: cab else: 0.0) * r2 * 10)
        let sx = float32((cx + u * fc * R - ox) / scale)
        let sy = float32((cy + v * fc * R - oy) / scale)
        let p = bilinear(sp, w, h, sx, sy, edge, extend)
        o[ch] = (p shr (16 - 8 * ch)) and 255
        if ch == 1: a = p shr 24
      var r = o[0].float
      var g = o[1].float
      var b = o[2].float
      if vig != 0:
        # the corners lighter (or darker), from `mid` of the way out
        let t = clamp((sqrt(r2) - mid * 0.7) / (1.05 - mid * 0.7), 0.0, 1.0)
        let m = 1 + vig * t * t * 0.9
        r *= m; g *= m; b *= m
      dp[y * w + x] = (a shl 24) or (uint32(clamp(r, 0, 255) + 0.5) shl 16) or
                      (uint32(clamp(g, 0, 255) + 0.5) shl 8) or uint32(clamp(b, 0, 255) + 0.5)

proc lensCorrection*(c: LensCorrection): FilterFn =
  ## Lens Correction as a filter: the part worked on is the picture.
  result = proc (src: Img; inner: Rect): Img = lensImg(src, c)

# ---- Straighten -------------------------------------------------------------------------------------------

proc innerRect*(w, h: int; deg: float): (int, int) =
  ## The biggest upright rectangle inside a `w` x `h` one turned by `deg`.
  if w <= 0 or h <= 0: return (0, 0)
  let a = degToRad(deg)
  let longer = w >= h
  let sl = (if longer: w else: h).float
  let ss = (if longer: h else: w).float
  let sa = abs(sin(a))
  let ca = abs(cos(a))
  var wr, hr: float
  if ss <= 2 * sa * ca * sl or abs(sa - ca) < 1e-10:
    let x = 0.5 * ss
    if longer: (wr, hr) = (x / max(sa, 1e-9), x / max(ca, 1e-9))
    else: (wr, hr) = (x / max(ca, 1e-9), x / max(sa, 1e-9))
  else:
    let c2 = ca * ca - sa * sa
    wr = (w.float * ca - h.float * sa) / c2
    hr = (h.float * ca - w.float * sa) / c2
  (max(1, int(floor(min(wr, w.float * 4)))), max(1, int(floor(min(hr, h.float * 4)))))

proc straighten*(d: Doc; deg: float; bg: uint32) =
  ## The image turned by `deg` (clockwise) and cut to what it fills -- no
  ## empty corners: the horizon made level. (Undoable: `snapStep` first.)
  if abs(deg) < 0.01: return
  let (iw, ih) = innerRect(d.w, d.h, deg)
  d.rotateArbitrary(deg, bg)
  let x0 = max(0, (d.w - iw) div 2)
  let y0 = max(0, (d.h - ih) div 2)
  d.crop(rect(x0, y0, min(iw, d.w - x0), min(ih, d.h - y0)))


# ---- pictures drawn on bent grids --------------------------------------------------------------------------

type MeshPt* = (float, float)
  ## A point of a grid: x, y (pixels).

proc drawMesh*(dst: var seq[uint32]; dw, dh: int; src: Img; cols, rows: int; pos, tex: seq[MeshPt]) =
  ## `src` drawn over `dst` (`dw` x `dh`) on a grid of (`cols` + 1) x
  ## (`rows` + 1) points: `tex` where each point is in `src` (pixels), `pos`
  ## where it goes. Each cell is two triangles, read between `src`'s pixels.
  let n = (cols + 1) * (rows + 1)
  if pos.len < n or tex.len < n or src.w == 0 or dw == 0: return
  var tris: seq[array[3, int]]
  for j in 0 ..< rows:
    for i in 0 ..< cols:
      let a = j * (cols + 1) + i
      let b = a + 1
      let c = a + cols + 1
      let e = c + 1
      tris.add [a, b, e]
      tris.add [a, e, c]
  # each triangle's rows, to find those in a band quickly
  var ys = newSeq[(int, int)](tris.len)
  for t, tr in tris:
    var y0 = 1e18
    var y1 = -1e18
    for k in tr:
      y0 = min(y0, pos[k][1]); y1 = max(y1, pos[k][1])
    ys[t] = (int(floor(y0)), int(ceil(y1)))
  let sp = pptr(src.px)
  let dp = pptr(dst)
  let sw = src.w
  let sh = src.h
  parallelChunks(dh, lo, hi):
    for t, tr in tris:
      if ys[t][1] < lo or ys[t][0] >= hi: continue
      let (ax, ay) = pos[tr[0]]
      let (bx, by) = pos[tr[1]]
      let (cx, cy) = pos[tr[2]]
      let area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
      if abs(area) < 1e-9: continue
      let x0 = max(0, int(floor(min(ax, min(bx, cx)))))
      let x1 = min(dw - 1, int(ceil(max(ax, max(bx, cx)))))
      let y0 = max(lo, int(floor(min(ay, min(by, cy)))))
      let y1 = min(hi - 1, int(ceil(max(ay, max(by, cy)))))
      for y in y0 .. y1:
        let py = y.float + 0.5
        for x in x0 .. x1:
          let px = x.float + 0.5
          let w0 = ((bx - px) * (cy - py) - (by - py) * (cx - px)) / area
          let w1 = ((cx - px) * (ay - py) - (cy - py) * (ax - px)) / area
          let w2 = 1 - w0 - w1
          if w0 < -1e-7 or w1 < -1e-7 or w2 < -1e-7: continue
          let u = w0 * tex[tr[0]][0] + w1 * tex[tr[1]][0] + w2 * tex[tr[2]][0]
          let v = w0 * tex[tr[0]][1] + w1 * tex[tr[1]][1] + w2 * tex[tr[2]][1]
          let p = bilinear(sp, sw, sh, float32(u), float32(v), 0, false)
          if (p shr 24) == 0: continue
          let i = y * dw + x
          dp[i] = if (p shr 24) == 255: p else: blendPx(dp[i], p, 255, bmNormal)

# ---- Warp: a grid of 4 x 4 points ---------------------------------------------------------------------------

type WarpMesh* = array[16, MeshPt]
  ## Where the points of a 4 x 4 grid over a picture go, in its size (0..1
  ## across and down); the picture follows smoothly (Catmull-Rom).

proc identityMesh*(): WarpMesh =
  ## A mesh that leaves the picture as it is.
  for j in 0 .. 3:
    for i in 0 .. 3: result[j * 4 + i] = (i / 3, j / 3)

proc isIdentity*(m: WarpMesh): bool =
  ## The mesh leaves the picture as it is.
  let id = identityMesh()
  for k in 0 .. 15:
    if abs(m[k][0] - id[k][0]) > 1e-6 or abs(m[k][1] - id[k][1]) > 1e-6: return false
  true

proc catmull(p0, p1, p2, p3, t: float): float {.inline.} =
  0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t + (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t)

proc meshPoint*(m: WarpMesh; u, v: float): MeshPt =
  ## Where the picture's point (`u`, `v`, 0..1) goes.
  proc at(i, j: int): MeshPt =
    # (beyond the edges: carried on in a straight line)
    let ci = clamp(i, 0, 3)
    let cj = clamp(j, 0, 3)
    var p = m[cj * 4 + ci]
    if i < 0: p = (2 * m[cj * 4][0] - m[cj * 4 + 1][0], 2 * m[cj * 4][1] - m[cj * 4 + 1][1])
    elif i > 3: p = (2 * m[cj * 4 + 3][0] - m[cj * 4 + 2][0], 2 * m[cj * 4 + 3][1] - m[cj * 4 + 2][1])
    if j < 0:
      let a = m[ci]
      let b = m[4 + ci]
      p = (p[0] + (a[0] - b[0]), p[1] + (a[1] - b[1]))
    elif j > 3:
      let a = m[12 + ci]
      let b = m[8 + ci]
      p = (p[0] + (a[0] - b[0]), p[1] + (a[1] - b[1]))
    p
  let fu = clamp(u, 0.0, 1.0) * 3
  let fv = clamp(v, 0.0, 1.0) * 3
  let i = min(2, int(fu))
  let j = min(2, int(fv))
  let tu = fu - i.float
  let tv = fv - j.float
  var rowsX, rowsY: array[4, float]
  for k in 0 .. 3:
    let jj = j - 1 + k
    rowsX[k] = catmull(at(i - 1, jj)[0], at(i, jj)[0], at(i + 1, jj)[0], at(i + 2, jj)[0], tu)
    rowsY[k] = catmull(at(i - 1, jj)[1], at(i, jj)[1], at(i + 1, jj)[1], at(i + 2, jj)[1], tu)
  (catmull(rowsX[0], rowsX[1], rowsX[2], rowsX[3], tv), catmull(rowsY[0], rowsY[1], rowsY[2], rowsY[3], tv))

proc presetMesh*(w: TextWarp; aspect: float): WarpMesh =
  ## The grid a warp style (Arc, Bulge, Flag, Wave...) bends a picture into
  ## (`aspect`: its height over its width).
  for j in 0 .. 3:
    for i in 0 .. 3:
      let u = i / 3 * 2 - 1
      let v = 1 - j / 3 * 2
      let (x, y) = warpPoint(w, u, v, aspect)
      result[j * 4 + i] = ((x + 1) / 2, (1 - y) / 2)

proc meshGrid*(m: WarpMesh; place: proc (u, v: float): MeshPt; srcW, srcH: int; n = 24):
    tuple[pos, tex: seq[MeshPt]] =
  ## The grid to draw a picture `srcW` x `srcH` bent by `m`: `place` puts
  ## the bent picture's points (0..1) where they go.
  for j in 0 .. n:
    for i in 0 .. n:
      let u = i / n
      let v = j / n
      let (bu, bv) = m.meshPoint(u, v)
      result.pos.add place(bu, bv)
      result.tex.add (u * srcW.float, v * srcH.float)

proc warpRect*(px: seq[uint32]; w, h: int; r: Rect; m: WarpMesh; vacated = 0'u32): seq[uint32] =
  ## Edit > Transform > Warp on pixels: what is in `r` taken up and put
  ## down bent by `m` (over the rectangle `r`).
  result = px
  if r.w <= 0 or r.h <= 0: return
  var part = newImg(r.w, r.h)
  for y in 0 ..< r.h:
    for x in 0 ..< r.w:
      let xx = r.x + x
      let yy = r.y + y
      if xx < 0 or yy < 0 or xx >= w or yy >= h: continue
      part.px[y * r.w + x] = px[yy * w + xx]
      result[yy * w + xx] = vacated
  let rx = r.x.float
  let ry = r.y.float
  let rw = r.w.float
  let rh = r.h.float
  let g = m.meshGrid(proc (u, v: float): MeshPt = (rx + u * rw, ry + v * rh), r.w, r.h)
  drawMesh(result, w, h, part, 24, 24, g.pos, g.tex)

# ---- Puppet Warp: pins --------------------------------------------------------------------------------------

type PuppetMode* = enum
  ## How Puppet Warp bends what is between the pins: kept stiff, a little
  ## stretched, or freely stretched.
  pmRigid = "Rigid", pmNormal = "Normal", pmDistort = "Distort"

proc puppetPoint*(pins, moved: openArray[MeshPt]; x, y: float; mode = pmRigid): MeshPt =
  ## Where the point (`x`, `y`) goes when the pins at `pins` are moved to
  ## `moved` (moving least squares: as rigid, as-similar or as-affine as
  ## can be).
  let n = min(pins.len, moved.len)
  if n == 0: return (x, y)
  if n == 1: return (x + moved[0][0] - pins[0][0], y + moved[0][1] - pins[0][1])
  var ws = newSeq[float](n)
  var sw = 0.0
  for i in 0 ..< n:
    let d2 = (pins[i][0] - x) ^ 2 + (pins[i][1] - y) ^ 2
    if d2 < 1e-9: return moved[i]
    ws[i] = 1 / d2
    sw += ws[i]
  var px, py, qx, qy = 0.0
  for i in 0 ..< n:
    px += ws[i] * pins[i][0]; py += ws[i] * pins[i][1]
    qx += ws[i] * moved[i][0]; qy += ws[i] * moved[i][1]
  px /= sw; py /= sw; qx /= sw; qy /= sw
  let vx = x - px
  let vy = y - py
  case mode
  of pmDistort:
    # the affine map that fits best
    var a11, a12, a22, b11, b12, b21, b22 = 0.0
    for i in 0 ..< n:
      let hx = pins[i][0] - px
      let hy = pins[i][1] - py
      let gx = moved[i][0] - qx
      let gy = moved[i][1] - qy
      a11 += ws[i] * hx * hx; a12 += ws[i] * hx * hy; a22 += ws[i] * hy * hy
      b11 += ws[i] * hx * gx; b12 += ws[i] * hx * gy; b21 += ws[i] * hy * gx; b22 += ws[i] * hy * gy
    let det = a11 * a22 - a12 * a12
    if abs(det) < 1e-12: return (x + qx - px, y + qy - py)
    let i11 = a22 / det
    let i12 = -a12 / det
    let i22 = a11 / det
    let m11 = i11 * b11 + i12 * b21
    let m12 = i11 * b12 + i12 * b22
    let m21 = i12 * b11 + i22 * b21
    let m22 = i12 * b12 + i22 * b22
    (vx * m11 + vy * m21 + qx, vx * m12 + vy * m22 + qy)
  of pmNormal, pmRigid:
    var fx, fy, mu = 0.0
    for i in 0 ..< n:
      let hx = pins[i][0] - px
      let hy = pins[i][1] - py
      let gx = moved[i][0] - qx
      let gy = moved[i][1] - qy
      # A_i = w [h; -h⊥] [v; -v⊥]^T, applied to g
      let a = ws[i] * (hx * vx + hy * vy)
      let b = ws[i] * (hx * vy - hy * vx)
      fx += gx * a - gy * b
      fy += gx * b + gy * a
      mu += ws[i] * (hx * hx + hy * hy)
    if mode == pmNormal:
      if mu < 1e-12: return (x + qx - px, y + qy - py)
      (fx / mu + qx, fy / mu + qy)
    else:
      let l = sqrt(fx * fx + fy * fy)
      let vl = sqrt(vx * vx + vy * vy)
      if l < 1e-12: return (qx, qy)
      (fx / l * vl + qx, fy / l * vl + qy)

proc puppetWarp*(px: seq[uint32]; w, h: int; r: Rect; pins, moved: openArray[MeshPt]; mode = pmRigid;
                 step = 12): seq[uint32] =
  ## Edit > Puppet Warp: what is in `r` bent by its pins (at `pins`, moved
  ## to `moved`), on a grid of `step` pixels; the rest of the layer as it
  ## was, what is taken up made transparent.
  result = px
  if r.w <= 0 or r.h <= 0: return
  var part = newImg(r.w, r.h)
  for y in 0 ..< r.h:
    for x in 0 ..< r.w:
      let xx = r.x + x
      let yy = r.y + y
      if xx < 0 or yy < 0 or xx >= w or yy >= h: continue
      part.px[y * r.w + x] = px[yy * w + xx]
      result[yy * w + xx] = 0
  let cols = max(1, (r.w + step - 1) div step)
  let rows = max(1, (r.h + step - 1) div step)
  var pos, tex: seq[MeshPt]
  for j in 0 .. rows:
    for i in 0 .. cols:
      let u = min(r.w.float, i.float * step.float)
      let v = min(r.h.float, j.float * step.float)
      tex.add (u, v)
      pos.add puppetPoint(pins, moved, r.x.float + u, r.y.float + v, mode)
  drawMesh(result, w, h, part, cols, rows, pos, tex)

# ---- Smart Objects --------------------------------------------------------------------------------------------

proc quadGrid*(src: Img; q: Quad; mesh: seq[MeshPt]; n = 24): tuple[pos, tex: seq[MeshPt]] =
  ## The grid to draw a Smart Object's picture into its corners `q` (bent
  ## by its warp, 16 points, when there is one).
  let m = squareToQuad(q)
  proc place(u, v: float): MeshPt =
    let w = m[6] * u + m[7] * v + m[8]
    let k = if abs(w) < 1e-12: 1e12 else: 1 / w
    ((m[0] * u + m[1] * v + m[2]) * k, (m[3] * u + m[4] * v + m[5]) * k)
  var wm = identityMesh()
  if mesh.len == 16:
    for k in 0 .. 15: wm[k] = mesh[k]
  wm.meshGrid(place, src.w, src.h, n)

type
  FrameFit* = enum
    ## How a picture sits in its frame (a shape, type, a frame it is
    ## clipped to): the usual layout app's Fitting.
    ffFill = "Fill Frame Proportionally"       ## covers the frame, its sides cut off
    ffFit = "Fit Content Proportionally"       ## all of it in the frame, room left beside it
    ffStretch = "Fit Content to Frame"         ## as big as the frame, its proportions changed
    ffCenter = "Center Content"                ## its size kept, in the middle of the frame
    ffOriginal = "Original Size"               ## at 100 %, in the middle

proc contentQuad*(frame: Rect; w, h: int; fit: FrameFit; scale = 100.0; angle = 0.0; dx = 0.0; dy = 0.0;
                  flipH = false; flipV = false; current: Quad = default(Quad)): Quad =
  ## Where a picture `w` x `h` goes in `frame` -- its corners (top left,
  ## top right, bottom right, bottom left): fitted as `fit` says, then
  ## scaled (`scale` %), turned (`angle` degrees, about the frame's
  ## middle), moved (`dx`, `dy` pixels), flipped. `ffCenter` keeps the size
  ## of `current` (where it is now).
  let fw = max(1, frame.w).float
  let fh = max(1, frame.h).float
  var pw, ph: float
  case fit
  of ffFill:
    let k = max(fw / w.float, fh / h.float)
    pw = w.float * k
    ph = h.float * k
  of ffFit:
    let k = min(fw / w.float, fh / h.float)
    pw = w.float * k
    ph = h.float * k
  of ffStretch:
    pw = fw
    ph = fh
  of ffCenter:
    pw = hypot(current[1][0] - current[0][0], current[1][1] - current[0][1])
    ph = hypot(current[3][0] - current[0][0], current[3][1] - current[0][1])
    if pw <= 0 or ph <= 0:
      pw = w.float
      ph = h.float
  of ffOriginal:
    pw = w.float
    ph = h.float
  pw *= scale / 100
  ph *= scale / 100
  let cx = frame.x.float + fw / 2 + dx
  let cy = frame.y.float + fh / 2 + dy
  let a = angle * PI / 180
  let (ca, sa) = (cos(a), sin(a))
  var corners = [(-pw / 2, -ph / 2), (pw / 2, -ph / 2), (pw / 2, ph / 2), (-pw / 2, ph / 2)]
  if flipH:
    swap(corners[0], corners[1])
    swap(corners[2], corners[3])
  if flipV:
    swap(corners[0], corners[3])
    swap(corners[1], corners[2])
  for i, (x, y) in corners: result[i] = (cx + x * ca - y * sa, cy + x * sa + y * ca)

proc renderSmart*(s: SmartData; w, h: int; filterOf: proc (f: SmartFilter): FilterFn = nil): seq[uint32] =
  ## A Smart Object's pixels in a `w` x `h` image: its picture put in its
  ## corners (and warp), its Smart Filters done on that in order.
  result = newSeq[uint32](w * h)
  if s == nil or s.src.len != s.w * s.h or s.w == 0: return
  let src = Img(w: s.w, h: s.h, px: s.src)
  # (more grid on a big picture in perspective)
  let g = quadGrid(src, s.quad, s.warp, if s.warp.len == 16: 32 else: 8)
  drawMesh(result, w, h, src, (if s.warp.len == 16: 32 else: 8), (if s.warp.len == 16: 32 else: 8), g.pos, g.tex)
  if filterOf == nil: return
  for f in s.filters:
    if f.off: continue
    let fn = filterOf(f)
    if fn == nil: continue
    let before = result
    let o = fn(Img(w: w, h: h, px: before), rect(0, 0, w, h))
    if o.px.len != before.len: continue
    let op = if f.opacity <= 0: 100 else: clamp(f.opacity, 0, 100)
    if op == 100 and f.mode == bmNormal:
      result = o.px
    else:
      let a = op * 255 div 100
      for i in 0 ..< result.len:
        let p = o.px[i]
        result[i] = (before[i] and 0xFF000000'u32) or
                    (blendPx(before[i] or 0xFF000000'u32, p or 0xFF000000'u32, a, f.mode) and 0x00FFFFFF'u32)

proc smartOf*(px: seq[uint32]; w, h: int; r: Rect; name = ""): SmartData =
  ## A Smart Object holding what is in `r` of the pixels, where it is.
  var src = newSeq[uint32](r.w * r.h)
  for y in 0 ..< r.h:
    for x in 0 ..< r.w:
      let xx = r.x + x
      let yy = r.y + y
      if xx >= 0 and yy >= 0 and xx < w and yy < h: src[y * r.w + x] = px[yy * w + xx]
  SmartData(src: src, w: r.w, h: r.h, quad: quadOf(r), name: name)

proc withQuad*(s: SmartData; q: Quad): SmartData =
  ## The same Smart Object with its corners elsewhere (a new one: they are
  ## never changed).
  SmartData(src: s.src, w: s.w, h: s.h, quad: q, filters: s.filters, name: s.name, file: s.file, warp: s.warp,
           link: s.link, linkStamp: s.linkStamp)

proc withFilters*(s: SmartData; f: seq[SmartFilter]): SmartData =
  ## The same Smart Object with the Smart Filters `f` (a new one).
  SmartData(src: s.src, w: s.w, h: s.h, quad: s.quad, filters: f, name: s.name, file: s.file, warp: s.warp,
           link: s.link, linkStamp: s.linkStamp)

proc withWarp*(s: SmartData; m: seq[MeshPt]): SmartData =
  ## The same Smart Object warped by `m` (a new one).
  SmartData(src: s.src, w: s.w, h: s.h, quad: s.quad, filters: s.filters, name: s.name, file: s.file, warp: m,
           link: s.link, linkStamp: s.linkStamp)

proc withSource*(s: SmartData; src: seq[uint32]; w, h: int; file = ""): SmartData =
  ## The same Smart Object holding another picture (Edit Contents, Replace
  ## Contents): in the same corners.
  SmartData(src: src, w: w, h: h, quad: s.quad, filters: s.filters, name: s.name, file: file, warp: s.warp, link: s.link,
           linkStamp: s.linkStamp)

# ---- the Blur Gallery -------------------------------------------------------------------------------------------

proc variableBlur*(src: Img; radius: seq[float32]; maxRadius: float; bokeh = 0.0; bokehLevel = 191): Img =
  ## Each pixel blurred by its own radius (0..`maxRadius`, from `radius`):
  ## between blurs of the whole picture at a few radii. `bokeh` (0..1)
  ## makes the bright parts of the blur glow (Light Bokeh), from
  ## `bokehLevel` up.
  let w = src.w
  let h = src.h
  result = newImg(w, h)
  if radius.len != w * h or maxRadius <= 0.3:
    result.px = src.px
    return
  var base = src
  if bokeh > 0:
    base = newImg(w, h)
    for i, p in src.px:
      let l = luma(rOf(p), gOf(p), bOf(p))
      if l > bokehLevel:
        let k = 1 + bokeh * 3 * (l - bokehLevel).float / max(1, 255 - bokehLevel).float
        base.px[i] = argb(aOf(p), min(255, int(rOf(p).float * k)), min(255, int(gOf(p).float * k)),
                          min(255, int(bOf(p).float * k)))
      else: base.px[i] = p
  # the radii of the levels: 0, then doubling up to the most
  var radii = @[0.0]
  var r = maxRadius
  var rs: seq[float]
  while r >= 0.75 and rs.len < 6:
    rs.insert(r, 0)
    r /= 2
  radii.add rs
  var levels = @[src]
  for k in 1 ..< radii.len:
    levels.add gaussianBlur(radii[k])(base, rect(0, 0, w, h))
  let rp = pptr(result.px)
  let radp = fptr(radius)
  parallelRows(h, y):
    for x in 0 ..< w:
      let i = y * w + x
      let want = clamp(radp[i].float, 0.0, maxRadius)
      var k = 0
      while k + 1 < radii.len and radii[k + 1] < want: inc k
      if k + 1 >= radii.len:
        rp[i] = levels[^1].px[i]
        continue
      let t = (want - radii[k]) / max(1e-9, radii[k + 1] - radii[k])
      rp[i] = mix(levels[k].px[i], levels[k + 1].px[i], clamp(t, 0.0, 1.0))

proc smoothstep(a, b, x: float): float {.inline.} =
  let t = clamp((x - a) / max(1e-9, b - a), 0.0, 1.0)
  t * t * (3 - 2 * t)

proc irisRadius*(w, h: int; cx, cy, rx, ry, angle, sharp, blur: float): seq[float32] =
  ## Iris Blur: sharp inside an ellipse (round `cx`, `cy`, radii `rx`, `ry`,
  ## turned by `angle` degrees) up to `sharp` (0..1) of the way out, more
  ## blurred to its edge, `blur` beyond.
  result = newSeq[float32](w * h)
  let ca = cos(degToRad(angle))
  let sa = sin(degToRad(angle))
  let rp = fptr(result)
  parallelRows(h, y):
    for x in 0 ..< w:
      let dx = x.float + 0.5 - cx
      let dy = y.float + 0.5 - cy
      let u = (dx * ca + dy * sa) / max(1.0, rx)
      let v = (-dx * sa + dy * ca) / max(1.0, ry)
      let d = sqrt(u * u + v * v)
      rp[y * w + x] = float32(blur * smoothstep(sharp, 1.0, d))

proc tiltShiftRadius*(w, h: int; cx, cy, angle, band, fade, blur: float): seq[float32] =
  ## Tilt-Shift: sharp in a band through `cx`, `cy` at `angle` degrees,
  ## `band` pixels each side, blurring over `fade` more pixels to `blur`.
  result = newSeq[float32](w * h)
  let nx = -sin(degToRad(angle))
  let ny = cos(degToRad(angle))
  let rp = fptr(result)
  parallelRows(h, y):
    for x in 0 ..< w:
      let d = abs((x.float + 0.5 - cx) * nx + (y.float + 0.5 - cy) * ny)
      rp[y * w + x] = float32(blur * smoothstep(band, band + max(1.0, fade), d))

proc fieldRadius*(w, h: int; pins: openArray[(float, float, float)]): seq[float32] =
  ## Field Blur: each pin (x, y, its blur) blurs round it, between them a
  ## mix by how near each is.
  result = newSeq[float32](w * h)
  if pins.len == 0: return
  let rp = fptr(result)
  let ps = @pins
  parallelRows(h, y):
    for x in 0 ..< w:
      var s, sw = 0.0
      var exact = -1.0
      for (px, py, b) in ps:
        let d2 = (x.float + 0.5 - px) ^ 2 + (y.float + 0.5 - py) ^ 2
        if d2 < 0.25:
          exact = b
          break
        let wt = 1 / d2
        s += wt * b
        sw += wt
      rp[y * w + x] = float32(if exact >= 0: exact else: s / sw)

# ---- several layers transformed together ---------------------------------------------------------

type
  ShotKind* = enum
    ## What a layer is, for a transform of several (`LayerShot`).
    skPixels   ## pixels: shown warped live, put down once (`putDownShots`)
    skShape    ## a shape: its outline carried, drawn again sharp
    skText     ## type: its letters scaled and carried -- turned, slanted or in perspective, set
               ## flat and drawn through the corners (`TextData.persp`): it stays type
    skSmart    ## a Smart Object: its corners carried, drawn again from what it holds
  LayerShot* = object
    ## A layer as it was when a transform of several began (`shotsOf`): what
    ## it is made again from as the box's corners move.
    layer*: Layer
    kind*: ShotKind
    shape*: ShapeData
    text*: TextData
    smart*: SmartData
    box*: Rect          ## where it was

proc shotsOf*(d: Doc; ls: openArray[Layer]): seq[LayerShot] =
  ## The layers `ls` as they are, for a transform of them all together (Free
  ## Transform with several picked): not the Background, a group (its layers
  ## are given), an adjustment, a layer locked or locked in place, nor one
  ## with nothing in it.
  for L in ls:
    if L == nil or L.background or L.group or L.adjust.kind.len > 0 or L.locked or L.lockPosition: continue
    var s = LayerShot(layer: L, box: d.layerBox(L))
    if L.isText: (s.kind = skText; s.text = L.text)
    elif L.isShape and not L.isFill: (s.kind = skShape; s.shape = L.shape)
    elif L.isSmart: (s.kind = skSmart; s.smart = L.smart)
    elif L.px.len == d.w * d.h:
      s.kind = skPixels
      s.box = d.contentBounds(L)
    else: continue
    if s.box.w > 0 and s.box.h > 0: result.add s

proc shotsBox*(shots: openArray[LayerShot]): Rect =
  ## The box round them all: what the transform's handles hold.
  var x0, y0 = high(int)
  var x1, y1 = low(int)
  for s in shots:
    x0 = min(x0, s.box.x); y0 = min(y0, s.box.y)
    x1 = max(x1, s.box.x + s.box.w); y1 = max(y1, s.box.y + s.box.h)
  if x1 > x0 and y1 > y0: rect(x0, y0, x1 - x0, y1 - y0) else: rect(0, 0, 0, 0)

proc squareQuad*(q: Quad): bool =
  ## The corners make a rectangle square to the image (scaled, moved, maybe
  ## flipped -- not turned, slanted or in perspective).
  abs(q[0][1] - q[1][1]) < 1e-6 and abs(q[2][1] - q[3][1]) < 1e-6 and
    abs(q[0][0] - q[3][0]) < 1e-6 and abs(q[1][0] - q[2][0]) < 1e-6

proc textBoxOf(d: Doc; L: Layer; t: TextData): array[4, float32] =
  ## (the flat box type is set in: its box, else its lines' with a little room)
  if t.boxW > 0 and t.boxH > 0: return [t.x, t.y, t.x + t.boxW, t.y + t.boxH]
  let lay = layoutText(d.effectiveText(L))
  [lay.x0 - 2, lay.y0 - 2, lay.x1 + 2, lay.y1 + 2]

proc carryShots*(d: Doc; shots: openArray[LayerShot]; r: Rect; q: Quad;
                 smartDrawn: proc (L: Layer) = nil) =
  ## The shapes, type and Smart Objects of `shots` made again where box `r`
  ## went (its corners `q`), each staying what it is; `smartDrawn` draws a
  ## Smart Object again from what it holds (the app's: its filters).
  ## (The pixel layers are shown live, `liveShots`, and put down at the end.)
  let f = quadMap(r, q)
  let square = squareQuad(q)
  let sx = (q[1][0] - q[0][0]) / max(1.0, r.w.float)
  let sy = (q[3][1] - q[0][1]) / max(1.0, r.h.float)
  for s in shots:
    let L = s.layer
    case s.kind
    of skPixels: discard
    of skShape:
      var sh = s.shape
      sh.path.mapPoints(f)
      d.setShape(L, sh)
    of skSmart:
      var c: Quad
      for k in 0 .. 3: c[k] = f(s.smart.quad[k][0], s.smart.quad[k][1])
      L.smart = s.smart.withQuad(c)
      if smartDrawn != nil: smartDrawn(L)
    of skText:
      var t = s.text
      if square and not t.perspOn and sx > 0 and sy > 0:
        # (scaled and moved: its letters as much bigger, wider when it is wider)
        for sp in t.spans.mitems:
          sp.style.size = max(1'f32, sp.style.size * float32(sy))
          let hs = if sp.style.hScale <= 0: 1'f32 else: sp.style.hScale
          sp.style.hScale = hs * float32(sx / sy)
          if sp.style.leading > 0: sp.style.leading *= float32(sy)
        let (nx, ny) = f(t.x.float, t.y.float)
        t.x = float32(nx)
        t.y = float32(ny)
        if t.boxW > 0:
          t.boxW *= float32(sx)
          t.boxH *= float32(sy)
      else:
        # (turned, slanted, flipped, in perspective: set flat where it was, drawn through
        # where its corners went)
        let b = if t.perspOn: t.perspBox else: d.textBoxOf(L, t)
        let from0 = if t.perspOn: t.persp
                    else: [(b[0], b[1]), (b[2], b[1]), (b[2], b[3]), (b[0], b[3])]
        for k in 0 .. 3:
          let (cx, cy) = f(from0[k][0].float, from0[k][1].float)
          t.persp[k] = (float32(cx), float32(cy))
        t.perspBox = b
        t.perspOn = true
      d.setText(L, t)

proc pixelPart(d: Doc; r: Rect; q: Quad; own: Rect): tuple[r: Rect; q: Quad] =
  ## (a pixel layer's own part of box `r` -- where it has something, on the
  ## image -- and where its corners go: only that is warped)
  let c = d.clip(intersect(own, r))
  if c.w <= 0 or c.h <= 0: return (c, q)
  let f = quadMap(r, q)
  (c, [f(c.x.float, c.y.float), f((c.x + c.w).float, c.y.float), f((c.x + c.w).float, (c.y + c.h).float),
       f(c.x.float, (c.y + c.h).float)])

proc liveShots*(d: Doc; shots: openArray[LayerShot]; r: Rect; q: Quad): seq[LivePart] =
  ## How the pixel layers of `shots` are shown while the corners move (each
  ## stretched from box `r` into `q`, nothing left where they were): for
  ## `setLive`.
  for s in shots:
    if s.kind != skPixels: continue
    let (pr, pq) = d.pixelPart(r, q, s.box)
    if pr.w <= 0 or pr.h <= 0: continue
    let L = s.layer
    result.add LivePart(layer: L, kind: lkWarp, src: cast[ptr UncheckedArray[uint32]](addr L.px[pr.y * d.w + pr.x]),
                        srcStride: d.w, srcR: pr, quad: pq, hole: true)

proc putDownShots*(d: Doc; shots: openArray[LayerShot]; r: Rect; q: Quad) =
  ## The pixel layers of `shots` put down where box `r` went (`q`): each
  ## warped at full size once (on all the cores), its pixels as they were
  ## to the step open (`touchWhole`).
  for s in shots:
    if s.kind != skPixels: continue
    let (pr, pq) = d.pixelPart(r, q, s.box)
    if pr.w <= 0 or pr.h <= 0 or not quadIsFine(pq): continue
    let L = s.layer
    var res = d.vacatedCopy(L.px, pr, 0'u32)
    d.warpOnto(res, cast[ptr UncheckedArray[uint32]](addr L.px[pr.y * d.w + pr.x]), d.w, pr, pq)
    discard d.touchWhole(L)
    L.px = move(res)
    inc L.ver
  d.markAll()

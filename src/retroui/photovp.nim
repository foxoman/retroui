## Vanishing Point, as Photoshop's: a plane drawn on a picture in
## perspective (its four corners: a wall, a floor, a side of a box), then
## a picture pasted onto it -- smaller as it goes back -- or the plane's
## own texture cloned along it (Stamp), the copy following the
## perspective.
##
## ```nim
## let p = vpPlane([(120.0, 80.0), (400.0, 110.0), (420.0, 300.0), (100.0, 360.0)])
## d.vpPaste(d.layer, p, logo, (0.2, 0.2), 0.5)        # a logo on the wall
## d.vpClone(d.layer, p, (0.1, 0.5), (0.6, 0.5), 30)   # a window copied along it
## ```

import std/math
import gfx, photo, photofx

type
  VpPlane* = object
    ## A plane in perspective: its corners (clockwise from the one at its
    ## top left as it lies), and the maps between it and the picture.
    quad*: Quad                  ## its corners, in the picture's pixels
    toImg, toUnit: array[9, float]
    aspect*: float              ## how much wider than tall it is, as it lies (its sides' lengths)

proc vpPlane*(q: Quad): VpPlane =
  ## The plane with corners `q` (image pixels).
  result.quad = q
  result.toImg = squareToQuad(q)
  result.toUnit = inverse3(result.toImg)
  let top = hypot(q[1][0] - q[0][0], q[1][1] - q[0][1])
  let bottom = hypot(q[2][0] - q[3][0], q[2][1] - q[3][1])
  let left = hypot(q[3][0] - q[0][0], q[3][1] - q[0][1])
  let right = hypot(q[2][0] - q[1][0], q[2][1] - q[1][1])
  result.aspect = max(0.05, (top + bottom) / max(1e-6, left + right))

proc ok*(p: VpPlane): bool = quadIsFine(p.quad)
  ## The plane can be used (not folded, not flat).

proc project(m: array[9, float]; x, y: float): (float, float) {.inline.} =
  let w = m[6] * x + m[7] * y + m[8]
  if abs(w) < 1e-12: return (1e9, 1e9)
  ((m[0] * x + m[1] * y + m[2]) / w, (m[3] * x + m[4] * y + m[5]) / w)

proc toImage*(p: VpPlane; u, v: float): (float, float) {.inline.} = project(p.toImg, u, v)
  ## A point of the plane (0..1 across and down it) in the picture.

proc toPlane*(p: VpPlane; x, y: float): (float, float) {.inline.} = project(p.toUnit, x, y)
  ## A point of the picture on the plane (0..1 inside it).

proc onFront*(p: VpPlane; x, y: float): bool =
  ## The picture's point is on the plane's side of its horizon (the plane, made as big as it
  ## goes, reaches it; past the horizon it would be behind the eye).
  let (cx, cy) = p.toImage(0.5, 0.5)
  let a = p.toUnit[6] * cx + p.toUnit[7] * cy + p.toUnit[8]
  let b = p.toUnit[6] * x + p.toUnit[7] * y + p.toUnit[8]
  a * b > 0

proc inside*(p: VpPlane; x, y: float): bool =
  ## The picture's point is on the plane.
  let (u, v) = p.toPlane(x, y)
  u >= 0 and v >= 0 and u <= 1 and v <= 1

proc localScale*(p: VpPlane; u, v: float): float =
  ## Picture pixels per unit of the plane's width there (it shrinks as the
  ## plane goes back).
  let (x0, y0) = p.toImage(u, v)
  let (x1, y1) = p.toImage(u + 0.001, v)
  hypot(x1 - x0, y1 - y0) / 0.001

proc sampleAt(px: ptr UncheckedArray[uint32]; w, h: int; x, y: float): uint32 =
  ## (bilinear, colors weighed by alpha; nothing outside)
  let x0 = int(floor(x - 0.5))
  let y0 = int(floor(y - 0.5))
  let fx = x - 0.5 - x0.float
  let fy = y - 0.5 - y0.float
  var acc = [0.0, 0.0, 0.0, 0.0]
  for (dx, dy, wt) in [(0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)), (0, 1, (1 - fx) * fy),
                       (1, 1, fx * fy)]:
    let xx = x0 + dx
    let yy = y0 + dy
    if wt <= 0 or xx < 0 or yy < 0 or xx >= w or yy >= h: continue
    let c = px[yy * w + xx]
    let a = (c shr 24).float * wt
    acc[0] += a; acc[1] += ((c shr 16) and 255).float * a; acc[2] += ((c shr 8) and 255).float * a
    acc[3] += (c and 255).float * a
  if acc[0] <= 0.01: return 0
  argb(int(acc[0] + 0.5), int(acc[1] / acc[0] + 0.5), int(acc[2] / acc[0] + 0.5), int(acc[3] / acc[0] + 0.5))

proc vpPaste*(d: Doc; L: Layer; p: VpPlane; img: Img; at: (float, float); width: float; opacity = 100) =
  ## A picture put on the plane: its top left at `at` (the plane's 0..1),
  ## `width` of the plane's width wide (its height as its shape says, the
  ## plane's sides measured), each pixel read through the perspective; in
  ## the selection. Undoable in a step.
  if not p.ok or img.w <= 0 or img.h <= 0 or L.px.len != d.w * d.h: return
  let wU = max(1e-4, width)
  let hU = wU * img.h.float / img.w.float * p.aspect
  # (the part of the picture it covers)
  var x0 = 1e9
  var y0 = 1e9
  var x1 = -1e9
  var y1 = -1e9
  for (u, v) in [(at[0], at[1]), (at[0] + wU, at[1]), (at[0] + wU, at[1] + hU), (at[0], at[1] + hU)]:
    let (x, y) = p.toImage(u, v)
    x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
  let r = d.clip(rect(int(floor(x0)), int(floor(y0)), int(ceil(x1 - x0)) + 2, int(ceil(y1 - y0)) + 2))
  if r.w <= 0 or r.h <= 0: return
  d.touch(L, r)
  let sp = cast[ptr UncheckedArray[uint32]](unsafeAddr img.px[0])
  let op = clamp(opacity, 0, 100) * 255 div 100
  for y in r.y ..< r.y + r.h:
    for x in r.x ..< r.x + r.w:
      let i = y * d.w + x
      if d.selAt(i) == 0: continue
      let (u, v) = p.toPlane(x.float + 0.5, y.float + 0.5)
      let s = (u - at[0]) / wU
      let t = (v - at[1]) / hU
      if s < 0 or t < 0 or s > 1 or t > 1: continue
      let c = sampleAt(sp, img.w, img.h, s * img.w.float, t * img.h.float)
      if (c shr 24) == 0: continue
      let before = L.px[i]
      L.px[i] = d.applyAt(L, i, before, blendPx(before, c, op, bmNormal), 255)
  inc L.ver
  d.markDirty(r)

proc vpClone*(d: Doc; L: Layer; p: VpPlane; src, dst: (float, float); radius: float; opacity = 100;
              hardness = 50) =
  ## Stamp on the plane: a round brush `radius` pixels wide where `dst`
  ## (the plane's 0..1) is, filled from where `src` is -- the copy smaller
  ## or bigger as the plane goes back or comes forward. What it reads is the
  ## layer as the step began (strokes do not copy what they just painted).
  ## Undoable in a step.
  if not p.ok or L.px.len != d.w * d.h: return
  let (cx, cy) = p.toImage(dst[0], dst[1])
  let r = d.clip(rect(int(cx - radius) - 1, int(cy - radius) - 1, int(2 * radius) + 3, int(2 * radius) + 3))
  if r.w <= 0 or r.h <= 0: return
  d.touch(L, r)
  var orig = d.origReader(L)
  # (what the step began with, for the brush's area and where it reads)
  let sx = p.localScale(dst[0], dst[1])
  let reach = radius * 2 + 4
  let (scx, scy) = p.toImage(src[0], src[1])
  let sr = rect(int(scx - reach * 2), int(scy - reach * 2), int(reach * 4), int(reach * 4))
  let rr = d.clip(sr)
  var buf = newSeq[uint32](max(1, rr.w * rr.h))
  for y in 0 ..< rr.h:
    for x in 0 ..< rr.w: buf[y * rr.w + x] = orig.at(rr.x + x, rr.y + y)
  let bp = cast[ptr UncheckedArray[uint32]](addr buf[0])
  let op = clamp(opacity, 0, 100)
  let hard = clamp(hardness, 0, 100).float / 100
  for y in r.y ..< r.y + r.h:
    for x in r.x ..< r.x + r.w:
      let dist = hypot(x.float + 0.5 - cx, y.float + 0.5 - cy)
      if dist > radius: continue
      let i = y * d.w + x
      if d.selAt(i) == 0: continue
      let (u, v) = p.toPlane(x.float + 0.5, y.float + 0.5)
      let (qx, qy) = p.toImage(u + src[0] - dst[0], v + src[1] - dst[1])
      if qx < rr.x.float or qy < rr.y.float or qx >= (rr.x + rr.w).float or qy >= (rr.y + rr.h).float: continue
      let c = sampleAt(bp, rr.w, rr.h, qx - rr.x.float, qy - rr.y.float)
      if (c shr 24) == 0: continue
      let edge = dist / radius
      let k = if edge <= hard: 1.0 else: max(0.0, 1 - (edge - hard) / max(1e-6, 1 - hard))
      let a = int(k * op.float * 255 / 100 + 0.5)
      if a <= 0: continue
      let before = L.px[i]
      L.px[i] = d.applyAt(L, i, before, blendPx(before, c, a, bmNormal), 255)
  discard sx
  inc L.ver
  d.markDirty(r)

proc gridLines*(p: VpPlane; n = 8): seq[((float, float), (float, float))] =
  ## The plane's grid (`n` x `n`), as lines in the picture.
  for k in 0 .. n:
    let t = k / n
    result.add (p.toImage(t, 0), p.toImage(t, 1))
    result.add (p.toImage(0, t), p.toImage(1, t))

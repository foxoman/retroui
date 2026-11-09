## Drawing into a buffer of pixels the driver owns: for the drivers whose
## window is memory they fill themselves (Wayland's shared memory, a
## framebuffer, a DRM dumb buffer). Rectangles, lines, points, pictures
## (opaque or premultiplied, at their size or resized), letters from a
## coverage mask; one clip rectangle; what changed kept as one rectangle,
## for the driver to send only that.
##
## Pixels are 0x00RRGGBB (or 0xAARRGGBB) in host byte order, which is what
## Wayland's XRGB8888/ARGB8888 and a 32-bit framebuffer take.

import ../[coords, screen, pixelutils]

type
  PixBuf* = object
    px*: ptr UncheckedArray[uint32]   ## nil: nothing to draw on
    w*, h*: int
    stride*: int                       ## pixels from one row to the next
    clip*: Rect                        ## where drawing lands, when `clipped`
    clipped*: bool
    damage*: Rect                      ## what was drawn since `takeDamage`
    serial*: uint64                    ## counts the drawing calls (a frame with none shows nothing new)

proc fullRect(b: PixBuf): Rect {.inline.} = Rect(x: 0, y: 0, w: b.w, h: b.h)

proc attach*(b: var PixBuf; px: ptr UncheckedArray[uint32]; w, h, stride: int) =
  ## Draw on `px` from now on, `w` x `h`, `stride` pixels a row.
  b.px = px
  b.w = w
  b.h = h
  b.stride = stride

proc intersect(a, b: Rect): Rect =
  let x0 = max(a.x, b.x)
  let y0 = max(a.y, b.y)
  let x1 = min(a.x + a.w, b.x + b.w)
  let y1 = min(a.y + a.h, b.y + b.h)
  if x1 <= x0 or y1 <= y0: Rect() else: Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)

proc union*(a, b: Rect): Rect =
  ## The rectangle around both (an empty one is no part of it).
  if a.w <= 0 or a.h <= 0: return b
  if b.w <= 0 or b.h <= 0: return a
  let x0 = min(a.x, b.x)
  let y0 = min(a.y, b.y)
  Rect(x: x0, y: y0, w: max(a.x + a.w, b.x + b.w) - x0, h: max(a.y + a.h, b.y + b.h) - y0)

proc area(b: PixBuf; r: Rect): Rect {.inline.} =
  ## `r` within the buffer and the clip.
  result = intersect(r, b.fullRect)
  if b.clipped: result = intersect(result, b.clip)

proc touched(b: var PixBuf; r: Rect) {.inline.} =
  inc b.serial
  if r.w > 0 and r.h > 0: b.damage = union(b.damage, r)

proc takeDamage*(b: var PixBuf): Rect =
  ## What was drawn since the last time, and nothing from now on.
  result = b.damage
  b.damage = Rect()

proc setClip*(b: var PixBuf; r: Rect) =
  ## Drawing lands in `r` only (until `noClip`).
  b.clip = r
  b.clipped = true

proc noClip*(b: var PixBuf) =
  b.clipped = false

proc blend(dst, src: uint32): uint32 {.inline.} =
  ## Premultiplied `src` over opaque `dst`.
  let a = src shr 24
  if a == 255: return src or 0xFF000000'u32
  if a == 0: return dst
  let na = 255 - a
  let rb = ((dst and 0xFF00FF) * na + 0x800080) shr 8 and 0xFF00FF
  let g = ((dst and 0x00FF00) * na + 0x008000) shr 8 and 0x00FF00
  (((src and 0xFFFFFF) + rb + g) and 0xFFFFFF) or 0xFF000000'u32

proc premul(c: Color): uint32 {.inline.} =
  let a = c.a.uint32
  (a shl 24) or ((c.r.uint32 * a + 127) div 255 shl 16) or
    ((c.g.uint32 * a + 127) div 255 shl 8) or ((c.b.uint32 * a + 127) div 255)

proc fill*(b: var PixBuf; r: Rect; c: Color) =
  ## `r` in `c` (blended when it is not opaque).
  if b.px == nil or c.a == 0: return
  let d = b.area(r)
  if d.w <= 0 or d.h <= 0: return
  b.touched(d)
  if c.a == 255:
    let v = 0xFF000000'u32 or (c.r.uint32 shl 16) or (c.g.uint32 shl 8) or c.b.uint32
    for y in d.y ..< d.y + d.h:
      let row = y * b.stride
      for x in d.x ..< d.x + d.w: b.px[row + x] = v
  else:
    let s = premul(c)
    for y in d.y ..< d.y + d.h:
      let row = y * b.stride
      for x in d.x ..< d.x + d.w: b.px[row + x] = blend(b.px[row + x], s)

proc point*(b: var PixBuf; x, y: int; c: Color) =
  b.fill(Rect(x: x, y: y, w: 1, h: 1), c)

proc line*(b: var PixBuf; x1, y1, x2, y2: int; c: Color) =
  ## One pixel wide, both ends in it.
  if b.px == nil: return
  if y1 == y2:
    b.fill(Rect(x: min(x1, x2), y: y1, w: abs(x2 - x1) + 1, h: 1), c)
    return
  if x1 == x2:
    b.fill(Rect(x: x1, y: min(y1, y2), w: 1, h: abs(y2 - y1) + 1), c)
    return
  var x = x1
  var y = y1
  let dx = abs(x2 - x1)
  let dy = -abs(y2 - y1)
  let sx = if x1 < x2: 1 else: -1
  let sy = if y1 < y2: 1 else: -1
  var err = dx + dy
  let s = premul(c)
  let cl = b.area(b.fullRect)
  while true:
    if x >= cl.x and y >= cl.y and x < cl.x + cl.w and y < cl.y + cl.h:
      let i = y * b.stride + x
      b.px[i] = if c.a == 255: s else: blend(b.px[i], s)
    if x == x2 and y == y2: break
    let e2 = 2 * err
    if e2 >= dy:
      err += dy
      x += sx
    if e2 <= dx:
      err += dx
      y += sy
  b.touched(Rect(x: min(x1, x2), y: min(y1, y2), w: dx + 1, h: -dy + 1).intersect(cl))

proc blit*(b: var PixBuf; src: ptr UncheckedArray[uint32]; w, h: int; dst: Rect;
           format: RGBAFormat): bool =
  ## `w` x `h` pixels at `dst`'s corner (`dst`'s size only clips).
  if b.px == nil or src == nil or w <= 0 or h <= 0: return false
  let d = b.area(Rect(x: dst.x, y: dst.y, w: min(w, dst.w), h: min(h, dst.h)))
  if d.w <= 0 or d.h <= 0: return true
  b.touched(d)
  let sx0 = d.x - dst.x
  let sy0 = d.y - dst.y
  if format == RGBAFormat.argbPremultiplied:
    for y in 0 ..< d.h:
      let srow = (sy0 + y) * w + sx0
      let drow = (d.y + y) * b.stride + d.x
      for x in 0 ..< d.w: b.px[drow + x] = blend(b.px[drow + x], src[srow + x])
  else:
    for y in 0 ..< d.h:
      copyMem(addr b.px[(d.y + y) * b.stride + d.x], unsafeAddr src[(sy0 + y) * w + sx0], d.w * 4)
  true

proc draw*(b: var PixBuf; src: ptr UncheckedArray[uint32]; w, h: int; dst: Rect;
           format: RGBAFormat): bool =
  ## All of the picture into `dst`, resized when the sizes differ.
  if src == nil or w <= 0 or h <= 0 or dst.w <= 0 or dst.h <= 0: return false
  if w == dst.w and h == dst.h: return b.blit(src, w, h, dst, format)
  let r = resizedRGBA(src, w, h, dst.w, dst.h,
                      preserveAlpha = format == RGBAFormat.argbPremultiplied)
  b.blit(cast[ptr UncheckedArray[uint32]](unsafeAddr r[0]), dst.w, dst.h, dst, format)

proc cover*(b: var PixBuf; mask: openArray[uint8]; w, h, x, y: int; c: Color) =
  ## Letters: `c` where `mask` (`w` x `h`, 0..255 coverage) covers.
  if b.px == nil or w <= 0 or h <= 0 or mask.len < w * h: return
  let d = b.area(Rect(x: x, y: y, w: w, h: h))
  if d.w <= 0 or d.h <= 0: return
  b.touched(d)
  for yy in 0 ..< d.h:
    let mrow = (d.y - y + yy) * w + (d.x - x)
    let drow = (d.y + yy) * b.stride + d.x
    for xx in 0 ..< d.w:
      let m = mask[mrow + xx].uint32 * c.a.uint32 div 255
      if m == 0: continue
      let s = (m shl 24) or ((c.r.uint32 * m + 127) div 255 shl 16) or
              ((c.g.uint32 * m + 127) div 255 shl 8) or ((c.b.uint32 * m + 127) div 255)
      b.px[drow + xx] = blend(b.px[drow + xx], s)

proc copyFrom*(b: var PixBuf; o: PixBuf; r: Rect) =
  ## `r` of `o` (the same size) into this one, as it is: a buffer catching up
  ## with what the one shown before it got.
  if b.px == nil or o.px == nil or b.w != o.w or b.h != o.h: return
  let d = intersect(r, b.fullRect)
  if d.w <= 0 or d.h <= 0: return
  for y in d.y ..< d.y + d.h:
    copyMem(addr b.px[y * b.stride + d.x], unsafeAddr o.px[y * o.stride + d.x], d.w * 4)

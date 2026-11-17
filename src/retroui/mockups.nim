## Mockups: a design shown on a thing -- a T-shirt, a mug, a phone, a laptop, a poster on a
## wall, a book, business cards, a tote bag -- as a new document: the scene (drawn here, no
## photos needed), the design a Smart Object in the place it goes (in perspective; round a
## mug), the scene's light and shade over it. Change the design (its Smart Object) and the
## mockup follows.
##
## .. code-block:: nim
##   let d = makeMockup(mkMug, design, 1200, 900, color = 0xFFFFFFFF'u32)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/math
import photo, photoshapes, photowarp

type
  MockupKind* = enum
    ## The things a design can be shown on.
    mkTShirt = "T-Shirt", mkMug = "Mug", mkPhone = "Phone", mkLaptop = "Laptop", mkPoster = "Poster on a Wall",
    mkBook = "Book Cover", mkCards = "Business Cards", mkTote = "Tote Bag"

  MockupScene* = object
    ## (a scene drawn: under the design, the place it goes, the light and shade over it)
    under*: seq[uint32]
    over*: seq[uint32]          ## light and shade (gray, mixed by Multiply), where the design is
    quad*: Quad
    warp*: seq[(float, float)]  ## (a mug: the design bent round it, 4 x 4)
    clip*: seq[uint8]           ## where the design shows (empty: all of its place)

proc shade(c: uint32; k: float): uint32 =
  ## (a color darker, `k` < 1, or lighter)
  template ch(sh: int): uint32 =
    let v = float((c shr sh) and 255)
    uint32(clamp(int(round(if k <= 1: v * k else: v + (255 - v) * (k - 1))), 0, 255))
  (c and 0xFF000000'u32) or (ch(16) shl 16) or (ch(8) shl 8) or ch(0)

proc drawn(w, h: int; bg: uint32; shapes: openArray[ShapeData]): seq[uint32] =
  ## (shapes drawn one over another on `bg`)
  let d = newDoc(w, h, bg)
  for s in shapes: discard d.addShapeLayer(s)
  d.markAll()
  d.updateComposite()
  d.compCopy

proc fillOf(p: Path; c: uint32): ShapeData = ShapeData(path: p, fill: solidPaint(c))
proc gradOf(p: Path; c0, c1: uint32; angle = 90; style = 0): ShapeData =
  ShapeData(path: p, fill: gradientPaint(c0, c1, angle, style))

proc maskOf(p: Path; w, h: int): seq[uint8] = shapeMask(p, w, h)

proc softShadow(w, h: int; cx, cy, rx, ry: float; strength = 0.35): ShapeData =
  ## (a soft shadow on the ground: a radial fade)
  gradOf(ellipsePath(cx - rx, cy - ry, cx + rx, cy + ry), argb(int(255 * strength), 0, 0, 0), argb(0, 0, 0, 0),
         style = 1)

proc wall(w, h: int): seq[ShapeData] =
  @[gradOf(rectPath(0, 0, w.float, h.float), 0xFFF3F1EC'u32, 0xFFD9D5CC'u32, angle = 270)]

proc scene*(kind: MockupKind; w, h: int; color = 0xFFFFFFFF'u32): MockupScene =
  ## The scene of a mockup, `w` x `h`, the thing in `color` (a shirt's, a mug's, a cover's).
  let W = w.float
  let H = h.float
  var under: seq[ShapeData] = wall(w, h)
  var over: seq[ShapeData]
  var clipPath: Path
  case kind
  of mkTShirt:
    # (a shirt laid flat: its body, its sleeves, its collar; the print on its chest)
    let cx = W / 2
    let top = H * 0.12
    let bw = W * 0.36
    let shirt = svgPath("M30 8 L42 4 Q50 12 58 4 L70 8 L92 22 L84 38 L74 33 L74 96 L26 96 L26 33 L16 38 L8 22 Z",
                        cx - bw, top, cx + bw, H * 0.94)
    under.add softShadow(w, h, cx, H * 0.94, bw * 0.95, H * 0.03)
    under.add fillOf(shirt, color)
    under.add fillOf(svgPath("M42 4 Q50 12 58 4 L60 6 Q50 16 40 6 Z", cx - bw, top, cx + bw, H * 0.94), shade(color, 0.85))
    # (the folds: soft darker bands down it, a light on its shoulders)
    over.add gradOf(shirt, 0xFFFFFFFF'u32, 0xFFDDDDDD'u32, angle = 270)
    over.add gradOf(svgPath("M33 30 Q37 60 31 96 L35 96 Q41 60 37 30 Z", cx - bw, top, cx + bw, H * 0.94),
                    0x55B0B0B0'u32, 0x00B0B0B0'u32, angle = 270)
    over.add gradOf(svgPath("M63 30 Q59 60 66 96 L70 96 Q63 60 67 30 Z", cx - bw, top, cx + bw, H * 0.94),
                    0x55B0B0B0'u32, 0x00B0B0B0'u32, angle = 270)
    let pw = bw * 0.62
    result.quad = [(cx - pw / 2, H * 0.32), (cx + pw / 2, H * 0.32), (cx + pw / 2, H * 0.32 + pw * 1.1),
                   (cx - pw / 2, H * 0.32 + pw * 1.1)]
    clipPath = shirt
  of mkMug:
    # (a mug on a table: its body round, its handle; the design bent round it)
    let cx = W * 0.46
    let bw = W * 0.24
    let y0 = H * 0.2
    let y1 = H * 0.82
    under.add fillOf(rectPath(0, H * 0.72, W, H), 0xFFCBB79A'u32)                        # (the table)
    under.add softShadow(w, h, cx + bw * 0.15, y1, bw * 1.2, H * 0.04, 0.4)
    let handle = svgPath("M0 20 Q60 10 60 50 Q60 90 0 80 L0 66 Q42 72 42 50 Q42 28 0 34 Z", cx + bw * 0.92, y0 + (y1 - y0) * 0.2,
                         cx + bw * 1.55, y0 + (y1 - y0) * 0.75)
    under.add fillOf(handle, shade(color, 0.8))
    let body = rectPath(cx - bw, y0, cx + bw, y1, radius = bw * 0.08)
    under.add fillOf(body, color)
    under.add fillOf(ellipsePath(cx - bw, y0 - H * 0.025, cx + bw, y0 + H * 0.025), shade(color, 0.7))
    # (round: dark at its sides, a light down it)
    over.add gradOf(body, 0xFFFFFFFF'u32, 0xFFA8A8A8'u32, angle = 0, style = 3)
    let m = bw * 0.12
    result.quad = [(cx - bw + m, y0 + H * 0.08), (cx + bw - m, y0 + H * 0.08), (cx + bw - m, y1 - H * 0.08),
                   (cx - bw + m, y1 - H * 0.08)]
    # (the design round the body: its sides squeezed as a cylinder shows them, its edges bowed)
    for j in 0 .. 3:
      for i in 0 .. 3:
        let u = i.float / 3
        let v = j.float / 3
        let a = (u - 0.5) * PI * 0.62
        let x = 0.5 + sin(a) / (2 * sin(PI * 0.31))
        let bow = (1 - cos(a)) * 0.05
        result.warp.add (x, v + bow * (if v < 0.5: -1.0 else: 1.0) * 0.4)
    clipPath = body
  of mkPhone:
    let pw = min(W * 0.32, H * 0.42)
    let ph = pw * 2.05
    let cx = W / 2
    let cy = H / 2
    under.add softShadow(w, h, cx + pw * 0.08, cy + ph * 0.48, pw * 0.7, ph * 0.05, 0.4)
    under.add fillOf(rectPath(cx - pw / 2, cy - ph / 2, cx + pw / 2, cy + ph / 2, radius = pw * 0.14), 0xFF1C1C1E'u32)
    let s = pw * 0.05
    let screen = rectPath(cx - pw / 2 + s, cy - ph / 2 + s, cx + pw / 2 - s, cy + ph / 2 - s, radius = pw * 0.1)
    under.add fillOf(screen, 0xFF000000'u32)
    over.add fillOf(screen, 0xFFFFFFFF'u32)
    over.add gradOf(svgPath("M0 0 L100 0 L0 60 Z", cx - pw / 2 + s, cy - ph / 2 + s, cx + pw / 2 - s, cy),
                    0x22FFFFFF'u32, 0x00FFFFFF'u32, angle = 315)
    under.add fillOf(rectPath(cx - pw * 0.13, cy - ph / 2 + s * 1.6, cx + pw * 0.13, cy - ph / 2 + s * 2.6, radius = s),
                     0xFF000000'u32)
    result.quad = [(cx - pw / 2 + s, cy - ph / 2 + s), (cx + pw / 2 - s, cy - ph / 2 + s),
                   (cx + pw / 2 - s, cy + ph / 2 - s), (cx - pw / 2 + s, cy + ph / 2 - s)]
    clipPath = screen
  of mkLaptop:
    let lw = W * 0.62
    let cx = W / 2
    let sy0 = H * 0.16
    let sy1 = H * 0.7
    under.add fillOf(rectPath(0, H * 0.78, W, H), 0xFFE4E0D8'u32)
    under.add softShadow(w, h, cx, H * 0.83, lw * 0.6, H * 0.03, 0.4)
    under.add fillOf(rectPath(cx - lw / 2, sy0, cx + lw / 2, sy1, radius = W * 0.012), 0xFF2B2B2E'u32)
    let b = W * 0.016
    let screen = rectPath(cx - lw / 2 + b, sy0 + b, cx + lw / 2 - b, sy1 - b * 1.6)
    under.add fillOf(screen, 0xFF000000'u32)
    under.add gradOf(svgPath("M8 0 L92 0 L100 70 L0 70 Z", cx - lw * 0.58, sy1, cx + lw * 0.58, H * 0.8),
                     0xFFC9C9CC'u32, 0xFF9C9CA0'u32, angle = 270)
    under.add fillOf(rectPath(cx - lw * 0.08, H * 0.775, cx + lw * 0.08, H * 0.79, radius = 3), 0xFF8A8A8E'u32)
    over.add fillOf(screen, 0xFFFFFFFF'u32)
    result.quad = [(cx - lw / 2 + b, sy0 + b), (cx + lw / 2 - b, sy0 + b), (cx + lw / 2 - b, sy1 - b * 1.6),
                   (cx - lw / 2 + b, sy1 - b * 1.6)]
    clipPath = screen
  of mkPoster:
    # (a framed poster on a wall, seen a little from the left)
    let cx = W / 2
    let fw = min(W * 0.42, H * 0.5)
    let fh = fw * 1.36
    let y0 = H * 0.12
    under.add fillOf(rectPath(0, H * 0.86, W, H), 0xFFB89870'u32)                   # (the floor)
    let frame = [(cx - fw / 2, y0), (cx + fw / 2 * 0.94, y0 + H * 0.02), (cx + fw / 2 * 0.94, y0 + fh - H * 0.02),
                 (cx - fw / 2, y0 + fh)]
    var fp = Path()
    var sp = SubPath(closed: true)
    for (x, y) in frame: sp.pts.add PathPoint(p: (x, y), inH: (x, y), outH: (x, y))
    fp.subs.add sp
    under.add fillOf(translated(fp, W * 0.012, H * 0.016), 0x40000000'u32)          # (its shadow on the wall)
    under.add fillOf(fp, 0xFF262626'u32)
    let m = fw * 0.06
    result.quad = [(frame[0][0] + m, frame[0][1] + m), (frame[1][0] - m, frame[1][1] + m),
                   (frame[2][0] - m, frame[2][1] - m), (frame[3][0] + m, frame[3][1] - m)]
    var inner = Path()
    var ip = SubPath(closed: true)
    for (x, y) in result.quad: ip.pts.add PathPoint(p: (x, y), inH: (x, y), outH: (x, y))
    inner.subs.add ip
    over.add gradOf(inner, 0xFFFFFFFF'u32, 0xFFE8E8E8'u32, angle = 315)
    clipPath = inner
  of mkBook:
    # (a hardback standing a little turned: its cover, its spine, the edge of its pages)
    let cx = W * 0.52
    let bw = min(W * 0.34, H * 0.42)
    let bh = bw * 1.42
    let y0 = H * 0.1
    under.add softShadow(w, h, cx, y0 + bh + H * 0.02, bw * 0.75, H * 0.03, 0.45)
    let cover = [(cx - bw / 2, y0 + H * 0.02), (cx + bw / 2, y0), (cx + bw / 2, y0 + bh), (cx - bw / 2, y0 + bh - H * 0.02)]
    var spine = Path()
    var s1 = SubPath(closed: true)
    for (x, y) in [(cx - bw / 2 - bw * 0.12, y0 + H * 0.05), (cx - bw / 2, y0 + H * 0.02),
                   (cx - bw / 2, y0 + bh - H * 0.02), (cx - bw / 2 - bw * 0.12, y0 + bh - H * 0.005)]:
      s1.pts.add PathPoint(p: (x, y), inH: (x, y), outH: (x, y))
    spine.subs.add s1
    under.add fillOf(spine, shade(color, 0.6))
    var cp = Path()
    var s2 = SubPath(closed: true)
    for (x, y) in cover: s2.pts.add PathPoint(p: (x, y), inH: (x, y), outH: (x, y))
    cp.subs.add s2
    under.add fillOf(cp, color)
    result.quad = [cover[0], cover[1], cover[2], cover[3]]
    over.add gradOf(cp, 0xFFE6E6E6'u32, 0xFFFFFFFF'u32, angle = 0)
    clipPath = cp
  of mkCards:
    # (two cards on a desk: one flat and turned, one leaning on it)
    under.add gradOf(rectPath(0, 0, W, H), 0xFF5B6B73'u32, 0xFF3E4A50'u32, angle = 270)
    let cw = W * 0.42
    let ch = cw / 1.75
    let cx = W * 0.5
    let cy = H * 0.52
    let a = -0.12
    proc rot(x, y: float): (float, float) = (cx + x * cos(a) - y * sin(a), cy + x * sin(a) + y * cos(a))
    let q = [rot(-cw / 2, -ch / 2), rot(cw / 2, -ch / 2), rot(cw / 2, ch / 2), rot(-cw / 2, ch / 2)]
    var back = Path()
    var sb = SubPath(closed: true)
    for (x, y) in [rot(-cw / 2 + cw * 0.18, -ch / 2 + ch * 0.55), rot(cw / 2 + cw * 0.18, -ch / 2 + ch * 0.55),
                   rot(cw / 2 + cw * 0.18, ch / 2 + ch * 0.55), rot(-cw / 2 + cw * 0.18, ch / 2 + ch * 0.55)]:
      sb.pts.add PathPoint(p: (x, y), inH: (x, y), outH: (x, y))
    back.subs.add sb
    under.add fillOf(translated(back, 6, 10), 0x50000000'u32)
    under.add fillOf(back, shade(color, 0.93))
    var front = Path()
    var sf = SubPath(closed: true)
    for (x, y) in q: sf.pts.add PathPoint(p: (x, y), inH: (x, y), outH: (x, y))
    front.subs.add sf
    under.add fillOf(translated(front, 5, 9), 0x60000000'u32)
    under.add fillOf(front, color)
    over.add gradOf(front, 0xFFFFFFFF'u32, 0xFFEDEDED'u32, angle = 300)
    result.quad = q
    clipPath = front
  of mkTote:
    let cx = W / 2
    let bw = W * 0.3
    let y0 = H * 0.3
    let y1 = H * 0.92
    under.add softShadow(w, h, cx, y1, bw * 1.05, H * 0.03, 0.4)
    let handle = ShapeData(path: ellipsePath(cx - bw * 0.45, y0 - H * 0.22, cx + bw * 0.45, y0 + H * 0.12),
                           stroke: solidPaint(shade(color, 0.85)), strokeWidth: W * 0.018, align: saCenter)
    under.add handle
    let bag = svgPath("M4 0 L96 0 L100 100 L0 100 Z", cx - bw, y0, cx + bw, y1)
    under.add fillOf(bag, color)
    over.add gradOf(bag, 0xFFFFFFFF'u32, 0xFFD8D8D8'u32, angle = 270)
    let m = bw * 0.25
    result.quad = [(cx - bw + m, y0 + H * 0.12), (cx + bw - m, y0 + H * 0.12), (cx + bw - m, y1 - H * 0.12),
                   (cx - bw + m, y1 - H * 0.12)]
    clipPath = bag
  result.under = drawn(w, h, 0xFFFFFFFF'u32, under)
  result.over = drawn(w, h, 0xFFFFFFFF'u32, over)
  if clipPath.subs.len > 0: result.clip = maskOf(clipPath, w, h)

proc makeMockup*(kind: MockupKind; design: seq[uint32]; dw, dh: int; w = 1600; h = 1200;
                 color = 0xFFFFFFFF'u32): Doc =
  ## A new document: the scene, the design (`dw` x `dh`) a Smart Object in its place -- its
  ## mask where it shows --, the light and shade over it (Multiply, clipped to it).
  let sc = scene(kind, w, h, color)
  result = newDoc(w, h, 0xFFFFFFFF'u32, name = $kind & " Mockup")
  let bg = result.layers[0]
  bg.px = sc.under
  inc bg.ver
  bg.name = "Scene"
  let D = result.newLayer("Your Design")
  D.smart = SmartData(src: design, w: dw, h: dh, quad: sc.quad, name: "Your Design",
                      warp: (if sc.warp.len == 16: sc.warp else: @[]))
  D.px = renderSmart(D.smart, w, h)
  if sc.clip.len == w * h:
    let M = Layer(name: "Layer Mask", pxRaw: newSeq[uint32](w * h), opacity: 100, visible: true, gray: true)
    for i in 0 ..< w * h:
      let v = uint32(sc.clip[i])
      M.px[i] = 0xFF000000'u32 or (v shl 16) or (v shl 8) or v
    D.mask = M
  result.insertLayer(D)
  let S = result.newLayer("Light and Shade")
  S.px = sc.over
  S.mode = bmMultiply
  S.clipped = true
  inc S.ver
  result.insertLayer(S)
  result.cur = result.layers.find(D)
  result.markAll()

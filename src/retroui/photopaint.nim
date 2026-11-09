## The painting tools of `photo` documents: brush tips, strokes of the
## paintbrush, pencil, airbrush, eraser, smudge, blur and sharpen, dodge,
## burn and sponge, and the rubber stamp; the paint bucket and the magic
## wand (contiguous or similar colors), gradients, lines with arrowheads,
## type, and paths made with the pen (filled, stroked, made a selection).
## A stroke goes into the undo step open around it. `retroui/photobrushes`
## has brush presets for these tools.
##
## .. code-block:: nim
##   d.beginStep("Paintbrush")
##   var s = d.beginStroke(PaintOpts(tool: tkBrush, color: red, opacity: 100), tip, 10, 10)
##   s.strokeTo(200, 120)
##   s.endStroke()
##   d.endStep()

import std/[math, algorithm, strutils, tables, unicode, random]
import parallel
import gfx, photo, canvas2d

# ---- brush tips --------------------------------------------------------------------------------------

type
  BrushTip* = object
    ## A brush: its size, how soft its edge is, how far apart its dabs are,
    ## its angle and roundness; or a mask made from a selection.
    name*: string           ## shown in the Brushes palette
    diameter*: int          ## 1..999 pixels
    hardness*: int          ## 0 (soft) .. 100 (hard edge)
    spacing*: int           ## % of the diameter between dabs (0: at each point)
    angle*: int             ## degrees
    roundness*: int         ## 100 a circle .. 1 a thin ellipse
    custom*: seq[uint8]     ## a brush defined from the image (0..255)
    cw*, ch*: int           ## ... its size (empty `custom`: a round tip)
    flipX*, flipY*: bool    ## mirrored across (Flip X) or up and down (Flip Y)

  TipMask* = object
    ## A brush tip as alpha (0..1), `w` x `h`, its middle at w/2, h/2. A
    ## brush bigger than `MaxMaskSide` keeps a smaller mask: `step` image
    ## pixels to a mask pixel (it is read smoothly, see `maskAt`).
    w*, h*: int             ## its size
    a*: seq[float32]        ## its alpha, row by row
    step*: float32          ## 0 or 1: one to one

const
  MaxDiameter* = 5000
    ## The biggest brush (pixels across).
  MaxMaskSide* = 1024
    ## A brush's mask is at most this many pixels across (a bigger brush
    ## reads it smoothly scaled: 4 MB instead of 100 for a 5000-pixel one).

proc fullW*(m: TipMask): int {.inline.} =
  ## The dab's width in image pixels.
  if m.step > 1: int(round(m.w.float32 * m.step)) else: m.w

proc fullH*(m: TipMask): int {.inline.} =
  ## The dab's height in image pixels.
  if m.step > 1: int(round(m.h.float32 * m.step)) else: m.h

proc maskScaled*(m: TipMask; dx, dy: int): float32 =
  ## The tip's alpha at (`dx`, `dy`) image pixels from the dab's corner,
  ## read smoothly from a mask kept smaller than the dab (`step` > 1).
  let fx = (dx.float32 + 0.5'f32) / m.step - 0.5'f32
  let fy = (dy.float32 + 0.5'f32) / m.step - 0.5'f32
  let x0 = clamp(int(floor(fx)), 0, m.w - 1)
  let y0 = clamp(int(floor(fy)), 0, m.h - 1)
  let x1 = min(x0 + 1, m.w - 1)
  let y1 = min(y0 + 1, m.h - 1)
  let tx = clamp(fx - x0.float32, 0, 1)
  let ty = clamp(fy - y0.float32, 0, 1)
  let a = m.a[y0 * m.w + x0] + (m.a[y0 * m.w + x1] - m.a[y0 * m.w + x0]) * tx
  let b = m.a[y1 * m.w + x0] + (m.a[y1 * m.w + x1] - m.a[y1 * m.w + x0]) * tx
  a + (b - a) * ty

template maskAt*(m: TipMask; dx, dy: int): float32 =
  ## The dab's alpha `dx`, `dy` image pixels from its corner.
  (if m.step <= 1: m.a[(dy) * m.w + (dx)] else: maskScaled(m, dx, dy))

proc hardTip*(d: int): BrushTip =
  ## A round, hard brush `d` pixels across.
  BrushTip(diameter: d, hardness: 100, spacing: 25, roundness: 100)

proc softTip*(d: int): BrushTip =
  ## A round, soft brush `d` pixels across.
  BrushTip(diameter: d, hardness: 0, spacing: 25, roundness: 100)

proc defaultBrushes*(): seq[BrushTip] =
  ## The brushes of a new palette: hard 1..19, soft 5..27, soft 35..100.
  for d in [1, 3, 5, 9, 13, 19]: result.add hardTip(d)
  for d in [5, 9, 13, 17, 21, 27]: result.add softTip(d)
  for d in [35, 45, 65, 100]: result.add softTip(d)

proc tipMask*(t: BrushTip; scale = 1.0): TipMask =
  ## The alpha of a dab of `t` (sized by `scale`: stylus pressure, size
  ## jitter). Small round brushes are worked out 9 samples a pixel; big
  ## ones from their distance to the middle (the edge smoothed over a
  ## pixel); brushes over `MaxMaskSide` at that size, read scaled.
  if t.custom.len > 0 and t.cw > 0 and t.ch > 0:
    # (its size: the diameter across its longer side)
    let side = max(t.cw, t.ch).float
    let target = (if t.diameter > 0: t.diameter.float else: side) * scale
    let fw = max(1.0, t.cw.float * target / side)
    let fh = max(1.0, t.ch.float * target / side)
    let k = max(1.0, max(fw, fh) / MaxMaskSide.float)
    let w = max(1, int(round(fw / k)))
    let h = max(1, int(round(fh / k)))
    result = TipMask(w: w, h: h, a: newSeq[float32](w * h), step: k.float32)
    let up = w > t.cw or h > t.ch
    for y in 0 ..< h:
      let yy = if t.flipY: h - 1 - y else: y
      if not up:
        let sy0 = y * t.ch div h
        let sy1 = max(sy0 + 1, (y + 1) * t.ch div h)
        for x in 0 ..< w:
          # (smaller: the source's pixels under it averaged)
          let sx0 = x * t.cw div w
          let sx1 = max(sx0 + 1, (x + 1) * t.cw div w)
          var acc = 0
          for sy in sy0 ..< sy1:
            for sx in sx0 ..< sx1: acc += int(t.custom[sy * t.cw + sx])
          let xx = if t.flipX: w - 1 - x else: x
          result.a[yy * w + xx] = float32(acc) / float32(255 * (sy1 - sy0) * (sx1 - sx0))
      else:
        # (bigger: read smoothly)
        let fy = (y.float + 0.5) * t.ch.float / h.float - 0.5
        let y0 = clamp(int(floor(fy)), 0, t.ch - 1)
        let y1 = min(y0 + 1, t.ch - 1)
        let ty = clamp(fy - y0.float, 0.0, 1.0)
        for x in 0 ..< w:
          let fx = (x.float + 0.5) * t.cw.float / w.float - 0.5
          let x0 = clamp(int(floor(fx)), 0, t.cw - 1)
          let x1 = min(x0 + 1, t.cw - 1)
          let tx = clamp(fx - x0.float, 0.0, 1.0)
          let a = t.custom[y0 * t.cw + x0].float * (1 - tx) + t.custom[y0 * t.cw + x1].float * tx
          let b = t.custom[y1 * t.cw + x0].float * (1 - tx) + t.custom[y1 * t.cw + x1].float * tx
          let xx = if t.flipX: w - 1 - x else: x
          result.a[yy * w + xx] = float32((a * (1 - ty) + b * ty) / 255)
    return
  let full = max(1.0, min(MaxDiameter.float * 1.5, t.diameter.float * scale))
  let k = max(1.0, full / MaxMaskSide.float)          # (image pixels to a mask pixel)
  let dia = full / k
  let n = max(1, int(ceil(dia)) + 2)
  result = TipMask(w: n, h: n, a: newSeq[float32](n * n), step: k.float32)
  let r = dia / 2
  let c = n.float / 2
  var angle = t.angle.float
  if t.flipX: angle = 180 - angle
  if t.flipY: angle = -angle
  let ang = degToRad(angle)
  let ca = cos(ang)
  let sa = sin(ang)
  let round = clamp(t.roundness, 1, 100).float / 100
  let hard = clamp(t.hardness, 0, 100).float / 100
  if dia <= 1.5:
    # one pixel (a 1-pixel brush is a pixel)
    result.a[(n div 2) * n + n div 2] = 1
    return
  if dia <= 48:
    const ss = 3
    for y in 0 ..< n:
      for x in 0 ..< n:
        var acc = 0.0
        for sy in 0 ..< ss:
          for sx in 0 ..< ss:
            let dx = x.float + (sx.float + 0.5) / ss - c
            let dy = y.float + (sy.float + 0.5) / ss - c
            # the ellipse's own axes
            let u = (dx * ca + dy * sa)
            let v = (-dx * sa + dy * ca) / round
            let dist = sqrt(u * u + v * v) / r
            if dist >= 1: continue
            if hard >= 0.999 or dist <= hard: acc += 1
            else:
              let t2 = (dist - hard) / (1 - hard)
              acc += 0.5 + 0.5 * cos(t2 * PI)       # soft: falls smoothly to 0
        result.a[y * n + x] = float32(acc / (ss * ss))
    return
  # big: the falloff from a table by the distance, the hard edge smoothed
  # over one pixel of the ellipse's narrow side; the rows on all the cores
  const LutN = 2048
  var lut: array[LutN + 1, float32]
  for i in 0 .. LutN:
    let dist = i.float / LutN
    lut[i] = if hard >= 0.999 or dist <= hard: 1'f32
             else: float32(0.5 + 0.5 * cos((dist - hard) / (1 - hard) * PI))
  let edge = r * round                     # (pixels across the edge's width: its narrow side)
  let ap = cast[ptr UncheckedArray[float32]](addr result.a[0])
  let lp = cast[ptr UncheckedArray[float32]](addr lut[0])
  parallelFor(n, proc (lo, hi: int) =
    for y in lo ..< hi:
      let dy = y.float + 0.5 - c
      for x in 0 ..< n:
        let dx = x.float + 0.5 - c
        let u = (dx * ca + dy * sa)
        let v = (-dx * sa + dy * ca) / round
        let dist = sqrt(u * u + v * v) / r
        # (coverage of the edge: how far inside it the pixel's middle is)
        let cover = clamp((1 - dist) * edge + 0.5, 0.0, 1.0)
        if cover <= 0: continue
        ap[y * n + x] = lp[min(LutN, int(dist * LutN))] * float32(cover), grain = 16)

proc tipDia(t: BrushTip): int {.inline.} =
  if t.diameter > 0: t.diameter else: max(t.cw, t.ch)

proc turned*(t: BrushTip; deg: int): BrushTip =
  ## A sampled tip's picture turned by `deg` degrees (its angle then 0); a
  ## round tip just takes the angle.
  result = t
  if t.custom.len == 0 or t.cw <= 0 or t.ch <= 0:
    result.angle = deg
    return
  let a = degToRad(deg.float)
  let ca = cos(a)
  let sa = sin(a)
  let n = max(1, int(ceil(sqrt((t.cw * t.cw + t.ch * t.ch).float))))
  result.custom = newSeq[uint8](n * n)
  result.cw = n
  result.ch = n
  result.angle = 0
  result.diameter = max(1, int(round(t.tipDia.float * n.float / max(t.cw, t.ch).float)))
  let c = n.float / 2
  let sx0 = t.cw.float / 2
  let sy0 = t.ch.float / 2
  for y in 0 ..< n:
    let dy = y.float + 0.5 - c
    for x in 0 ..< n:
      let dx = x.float + 0.5 - c
      # (where this pixel comes from in the upright picture: bilinear)
      let fx = dx * ca + dy * sa + sx0 - 0.5
      let fy = -dx * sa + dy * ca + sy0 - 0.5
      if fx < -1 or fy < -1 or fx > t.cw.float or fy > t.ch.float: continue
      let x0 = int(floor(fx))
      let y0 = int(floor(fy))
      let tx = fx - x0.float
      let ty = fy - y0.float
      var acc = 0.0
      for (xx, yy, wgt) in [(x0, y0, (1 - tx) * (1 - ty)), (x0 + 1, y0, tx * (1 - ty)),
                            (x0, y0 + 1, (1 - tx) * ty), (x0 + 1, y0 + 1, tx * ty)]:
        if xx >= 0 and yy >= 0 and xx < t.cw and yy < t.ch:
          acc += t.custom[yy * t.cw + xx].float * wgt
      result.custom[y * n + x] = uint8(clamp(int(round(acc)), 0, 255))

proc pencilMask*(dia: int): TipMask =
  ## A hard, jagged dab (the pencil): pixels in the circle or out.
  let n = max(1, dia)
  result = TipMask(w: n, h: n, a: newSeq[float32](n * n))
  let r = n.float / 2
  for y in 0 ..< n:
    for x in 0 ..< n:
      let dx = x.float + 0.5 - r
      let dy = y.float + 0.5 - r
      if dx * dx + dy * dy <= r * r + 0.25 or n <= 2: result.a[y * n + x] = 1

proc tipFromSelection*(d: Doc): BrushTip =
  ## Define Brush: the selected part of the image (dark is paint).
  let r = d.clip(d.selBounds)
  result = BrushTip(name: "Custom", spacing: 25, roundness: 100, hardness: 100,
                    cw: max(1, r.w), ch: max(1, r.h), diameter: max(r.w, r.h))
  result.custom = newSeq[uint8](result.cw * result.ch)
  d.updateComposite()
  let cp = d.compPtr
  for y in 0 ..< r.h:
    for x in 0 ..< r.w:
      let i = (r.y + y) * d.w + r.x + x
      let p = cp[i]
      let dark = 255 - lumaOf(p)
      result.custom[y * r.w + x] = uint8(dark * aOf(p) div 255 * d.selAt(i) div 255)

type TileBuf*[T] = object
  ## A stroke's own buffer: as big as the image but made only where it
  ## paints, in 64 x 64 tiles.
  w, h, tw: int
  tiles: seq[seq[T]]

proc initTileBuf[T](w, h: int): TileBuf[T] =
  result.w = w
  result.h = h
  result.tw = (w + 63) shr 6
  result.tiles = newSeq[seq[T]](result.tw * ((h + 63) shr 6))

proc slot[T](b: var TileBuf[T]; x, y: int): ptr T {.inline.} =
  let ti = (y shr 6) * b.tw + (x shr 6)
  if b.tiles[ti].len == 0: b.tiles[ti] = newSeq[T](4096)
  addr b.tiles[ti][((y and 63) shl 6) or (x and 63)]

proc get[T](b: TileBuf[T]; x, y: int): T {.inline.} =
  let ti = (y shr 6) * b.tw + (x shr 6)
  if ti < 0 or ti >= b.tiles.len or b.tiles[ti].len == 0: return default(T)
  b.tiles[ti][((y and 63) shl 6) or (x and 63)]

proc used[T](b: TileBuf[T]): bool = b.tiles.len > 0

# ---- strokes --------------------------------------------------------------------------------------------

type
  ToolKind* = enum
    ## The painting tool a stroke is made with (the strings: their names).
    tkBrush = "Paintbrush", tkPencil = "Pencil", tkAirbrush = "Airbrush", tkEraser = "Eraser",
    tkSmudge = "Smudge", tkBlur = "Blur", tkSharpen = "Sharpen", tkDodge = "Dodge",
    tkBurn = "Burn", tkSponge = "Sponge", tkStamp = "Rubber Stamp", tkMixer = "Mixer Brush"

  ToneRange* = enum
    ## The tones the Dodge and Burn tools change most.
    trShadows = "Shadows", trMidtones = "Midtones", trHighlights = "Highlights"

  EraserMode* = enum
    ## How the Eraser rubs out: as the paintbrush, airbrush, pencil, or a square block.
    emPaintbrush = "Paintbrush", emAirbrush = "Airbrush", emPencil = "Pencil", emBlock = "Block"

  StampMode* = enum
    ## What the Rubber Stamp paints with: the image at the source (moving
    ## with the brush, or starting again at each stroke), the pattern, the
    ## snapshot, the file as saved, or strokes in the manner of a painting.
    smCloneAligned = "Clone (aligned)", smClone = "Clone (non-aligned)",
    smPatternAligned = "Pattern (aligned)", smPattern = "Pattern (non-aligned)",
    smFromSnapshot = "From Snapshot", smFromSaved = "From Saved",
    smImpressionist = "Impressionist"

  SymmetryKind* = enum
    ## Symmetry painting: what is painted is painted again mirrored or turned.
    syNone = "Off", syVertical = "Vertical", syHorizontal = "Horizontal", syDual = "Dual Axis",
    syRadial = "Radial", syMandala = "Mandala"

  DynControl* = enum
    ## What drives a dynamic besides its jitter.
    dcOff = "Off", dcFade = "Fade", dcPressure = "Pen Pressure", dcTilt = "Pen Tilt"

  AngleControl* = enum
    ## What turns the tip besides its jitter: the stroke's direction, its
    ## first direction, the pen's tilt or rotation.
    anOff = "Off", anDirection = "Direction", anInitial = "Initial Direction",
    anPenTilt = "Pen Tilt", anRotation = "Rotation"

  BrushDynamics* = object
    ## How a brush changes as it paints (Brush Dynamics): the dabs' size,
    ## angle, roundness, place, number, opacity, flow and color vary.
    sizeJitter*: int            ## % the size varies
    minDiameter*: int           ## % the size goes down to
    angleJitter*: int           ## % of a full turn
    roundJitter*: int           ## % the roundness varies
    scatter*: int               ## % of the diameter the dabs stray from the line
    scatterBoth*: bool          ## ... along it too
    count*: int                 ## dabs at each place (0, 1: one)
    countJitter*: int           ## %
    opacityJitter*: int         ## %
    flow*: int                  ## % of the paint each dab lays (0: all of it)
    flowJitter*: int            ## %
    hueJitter*: int             ## % of the color wheel
    fgBgJitter*: int            ## % toward the background color
    brightJitter*: int          ## %
    symmetry*: SymmetryKind     ## Symmetry: what is painted is painted again so
    axes*: int                  ## Radial and Mandala: how many (2..16)
    textureOn*: bool            ## Texture: the paint takes a grain (the pattern, as `PaintOpts.texture`)
    textureDepth*: int          ## ... %
    textureScale*: int          ## ... % (0: 100)
    textureInvert*: bool        ## ... its light and dark the other way
    dualBrush*: int             ## Dual Brush: 1 + the index of the second brush (0: none; `PaintOpts.dual`)
    dualScatter*: int           ## ... %
    centerX*, centerY*: float   ## the symmetry's middle (negative: the image's)
    sizeControl*: DynControl    ## what sets the size besides the jitter: the pen's pressure, a fade
    sizeFade*: int              ## ... over so many dabs
    opacityControl*: DynControl ## Transfer: what sets the opacity
    opacityFade*: int           ## ... over so many dabs (Fade)
    flowControl*: DynControl    ## ... and the flow
    flowFade*: int              ## ... over so many dabs (Fade)
    angleControl*: AngleControl ## the tip turns with the stroke (Direction) or its start
    flipXJitter*, flipYJitter*: bool ## dabs flipped at random
    satJitter*: int             ## Color Dynamics: saturation jitter, %
    purity*: int                ## ... -100 (gray) .. 100 (saturated)
    noise*: bool                ## Noise: grain in the soft edges
    buildUp*: bool              ## Build-up: paint keeps coming while the brush is held still
    pose*: bool                 ## Brush Pose: the tilt, rotation and pressure below, not the pen's
    tiltX*, tiltY*: int         ## ... -100..100 (a tilted pen: a flatter dab)
    rotation*: int              ## ... degrees
    roundTilt*: bool            ## Roundness Control: Pen Tilt (a pen laid down: a flatter dab)
    posePressure*: int          ## ... 1..100 %

  PaintOpts* = object
    ## How a stroke paints.
    dyn*: BrushDynamics         ## how the dabs vary along it
    tool*: ToolKind             ## the tool
    color*, bg*: uint32         ## the foreground and background colors
    opacity*: int               ## 1..100: opacity, pressure (airbrush, smudge,
                                ## blur, sponge) or exposure (dodge, burn)
    mode*: BlendMode            ## how the paint mixes with the layer
    fade*: int                  ## the stroke fades out over this many steps (0 not)
    fadeToBg*: bool             ## fades to the background color (else transparent)
    wet*: bool                  ## Wet Edges: darker at the edges (paintbrush)
    autoErase*: bool            ## pencil: starting on the foreground color paints the background
    eraseMode*: EraserMode      ## the eraser: how it rubs out
    blockSize*: int             ## the Block eraser, in image pixels
    tone*: ToneRange            ## dodge and burn
    saturate*: bool             ## sponge: saturate (else desaturate)
    finger*: bool               ## smudge: Finger Painting (starts with the foreground)
    stamp*: StampMode           ## the rubber stamp: what it paints with
    pattern*: seq[uint32]       ## the pattern (Define Pattern)
    pw*, ph*: int               ## ... its size
    srcX*, srcY*: float         ## the rubber stamp's source (Alt+click)
    saved*: seq[uint32]         ## the picture to go back to (as big as the image): the
                                ## snapshot or the file as saved -- for the stamp's From
                                ## Snapshot / From Saved and the eraser's Erase to Saved
    eraseToSaved*: bool         ## the eraser brings back `saved`
    sizeByPressure*, opacityByPressure*: bool  ## the pen's pressure sets the size, the opacity
    wetness*: int               ## the mixer brush: how much paint it takes up from the canvas, %
    load*: int                  ## ... how much paint it holds (how long it lasts), %
    mixRatio*: int              ## ... the canvas's paint to its own in the mix, %
    texture*: seq[uint8]        ## a texture the paint takes (its grain: 0..255), tiled; empty none
    tw*, th*: int               ## ... its size
    textureDepth*: int          ## ... how deep the grain shows, %
    textureScale*: int          ## ... its size, % (0: 100)
    textureInvert*: bool        ## ... its light and dark the other way
    dual*: BrushTip             ## Dual Brush: a second tip the dabs are seen through (diameter 0: none)
    dualScatter*: int           ## ... how far its dabs stray, % of its diameter
    bgErase*: bool              ## the eraser is the Background Eraser: it rubs out the color under
                                ## the brush's middle (and those like it), to transparency
    bgTolerance*: int           ## ... how alike, 0..100 %
    bgSampling*: int            ## ... the color: 0 sampled all along (Continuous), 1 where the
                                ## stroke began (Once), 2 the background color (Background Swatch)
    bgLimits*: int              ## ... 0 anywhere under the brush (Discontiguous), 1 touching the
                                ## middle (Contiguous), 2 contiguous, its edges kept sharp (Find Edges)
    bgProtectFg*: bool          ## ... the foreground color is never rubbed out (Protect Foreground Color)
    colorReplace*: bool         ## the brush is the Color Replacement tool: it paints (in its mode:
                                ## Color, Hue...) only over the color sampled as the Background
                                ## Eraser does -- `bgTolerance`, `bgSampling`, `bgLimits`

  Stroke* = object
    ## A stroke being painted (between the press and the release).
    d: Doc
    L: Layer
    o: PaintOpts
    tip: BrushTip
    mask: TipMask
    lastX, lastY: float
    carry: float                 # the distance left before the next dab
    dabs*: int                   ## the dabs painted so far
    cov: TileBuf[uint16]         # what the stroke covers (0..65535), in tiles made as painted
    col: TileBuf[uint32]         # the color each pixel was given (fades)
    rng: Rand
    dirX, dirY: float            # the way the stroke goes (scattering)
    area*: Rect                  ## where it painted (image pixels)
    smudge: seq[array[4, float]] # the paint the smudge carries
    offX, offY: float            # the stamp: from the brush to its source
    useBg: bool                  # auto erase
    pressure: float
    reservoir: array[4, float]   # the mixer brush: the paint it holds (a, r, g, b)
    paintLeft: float             # ... how much (1 full)
    dualMask: TipMask            # the dual brush's dab
    needCol: bool                # each pixel keeps its own color (it changes along the stroke)
    startDir: float              # the stroke's first direction (Initial Direction), radians
    hasStartDir: bool
    tilt: float                  # the pen: how far it leans (0 upright .. 1 flat)
    azimuth: float               # ... which way (radians, 0 to the right, clockwise)
    twist: float                 # ... turned on its own axis (degrees; where it is not known, its azimuth)
    bgSample: uint32             # the Background Eraser's color (and whether it has one yet)
    bgSampled: bool

var stampAnchor: tuple[set: bool; ox, oy: float]   ## (aligned clone: kept between strokes)


proc resetStampAlignment*() =
  ## A new source point: the next stroke starts aligned on it.
  stampAnchor.set = false

proc spacingOf(s: Stroke): float =
  if s.o.tool == tkPencil or (s.o.tool == tkEraser and s.o.eraseMode == emPencil): return 1.0
  if s.o.tool == tkEraser and s.o.eraseMode == emBlock: return max(1.0, s.o.blockSize.float / 4)
  if s.tip.spacing <= 0: return 0.0
  max(1.0, s.mask.fullW.float * s.tip.spacing.float / 100)

proc dabMask(s: Stroke): TipMask =
  if s.o.tool == tkPencil or (s.o.tool == tkEraser and s.o.eraseMode == emPencil):
    return pencilMask(s.tip.diameter)
  if s.o.tool == tkEraser and s.o.eraseMode == emBlock:
    let n = max(1, s.o.blockSize)
    result = TipMask(w: n, h: n, a: newSeq[float32](n * n))
    for v in result.a.mitems: v = 1
    return
  tipMask(s.tip)

proc beginStroke*(d: Doc; o: PaintOpts; tip: BrushTip; x, y: float; pressure = 1.0): Stroke =
  ## Starts a stroke at `x`, `y` (a dab is put there). The undo step must
  ## be open.
  result = Stroke(d: d, L: d.paintTarget, o: o, tip: tip, lastX: x, lastY: y, pressure: pressure)
  if result.o.opacity <= 0: result.o.opacity = 100
  result.tip.diameter = clamp(result.tip.diameter, 1, MaxDiameter)
  if o.tool in {tkSmudge, tkBlur, tkSharpen, tkMixer}:
    # (these carry or read the pixels under the whole dab: up to the mask's size)
    result.tip.diameter = min(result.tip.diameter, MaxMaskSide)
  if o.dyn.pose: result.pressure = clamp(o.dyn.posePressure, 1, 100).float / 100
  if result.tip.custom.len > 0 and result.tip.angle mod 360 != 0:
    result.tip = result.tip.turned(result.tip.angle)        # (once for the stroke)
  result.mask = result.dabMask()
  let dy = o.dyn
  result.needCol = o.tool == tkStamp or (o.fade > 0 and o.fadeToBg) or dy.fgBgJitter > 0 or dy.hueJitter > 0 or
                   dy.brightJitter > 0 or dy.satJitter > 0
  result.area = rect(0, 0, 0, 0)
  if result.L.gray:
    # a mask (the Quick Mask, a layer mask): paint is gray
    result.o.color = grayPx(lumaOf(o.color))
    result.o.bg = grayPx(lumaOf(o.bg))
  else:
    result.o.color = d.fitColor(o.color)
    result.o.bg = d.fitColor(o.bg)
  if o.tool in {tkBrush, tkPencil, tkAirbrush, tkEraser, tkStamp}:
    result.cov = initTileBuf[uint16](d.w, d.h)
    if result.needCol: result.col = initTileBuf[uint32](d.w, d.h)
  if o.tool == tkMixer:
    let c = result.o.color
    result.reservoir = [255.0, rOf(c).float, gOf(c).float, bOf(c).float]
    result.paintLeft = 1.0
  if o.dual.diameter > 0 or o.dual.custom.len > 0:
    result.dualMask = tipMask(o.dual)
  result.rng = initRand(int64(x * 7919 + y * 104729) + 1)
  if o.tool == tkPencil and o.autoErase:
    let xi = int(x)
    let yi = int(y)
    if xi >= 0 and yi >= 0 and xi < d.w and yi < d.h and
       (result.L.px[yi * d.w + xi] and 0xFFFFFF'u32) == (result.o.color and 0xFFFFFF'u32):
      result.useBg = true
  if o.tool == tkStamp:
    if o.stamp in {smCloneAligned, smPatternAligned} and stampAnchor.set:
      (result.offX, result.offY) = (stampAnchor.ox, stampAnchor.oy)
    else:
      result.offX = o.srcX - x
      result.offY = o.srcY - y
      if o.stamp == smCloneAligned:
        stampAnchor = (true, result.offX, result.offY)
  if o.tool == tkSmudge:
    result.smudge = newSeq[array[4, float]](result.mask.w * result.mask.h)
    let c = o.color
    for j in 0 ..< result.mask.h:
      for i in 0 ..< result.mask.w:
        let xx = int(x) - result.mask.w div 2 + i
        let yy = int(y) - result.mask.h div 2 + j
        let p = if o.finger: c
                elif xx >= 0 and yy >= 0 and xx < d.w and yy < d.h: result.L.px[yy * d.w + xx]
                else: 0'u32
        result.smudge[j * result.mask.w + i] = [aOf(p).float, rOf(p).float, gOf(p).float, bOf(p).float]

proc toneWeight(t: ToneRange; l: float): float =
  case t
  of trShadows: (1 - l) * (1 - l)
  of trMidtones: 1 - abs(2 * l - 1)
  of trHighlights: l * l

proc patternAt*(o: PaintOpts; x, y: int): uint32 =
  ## The pattern's pixel at `x`, `y` (tiled); the color when there is no
  ## pattern.
  if o.pattern.len == 0 or o.pw <= 0 or o.ph <= 0: return o.color
  o.pattern[(((y mod o.ph) + o.ph) mod o.ph) * o.pw + (((x mod o.pw) + o.pw) mod o.pw)]

proc wetEdge(c: float): float =
  ## Wet Edges: the middle of the stroke lighter than its edges.
  min(1.0, c * 0.55 + c * (1 - c) * 1.8)

proc colorDistance(a, b: uint32): int {.inline.} =
  ## (how far apart two colors are: their most different channel, 0..255)
  max(abs(rOf(a) - rOf(b)), max(abs(gOf(a) - gOf(b)), abs(bOf(a) - bOf(b))))

proc dab(s: var Stroke; cx, cy: float) =
  let d = s.d
  let L = s.L
  var m = s.mask
  let dy = s.o.dyn
  let shaped = s.o.tool in {tkBrush, tkAirbrush, tkEraser, tkStamp, tkSmudge, tkBlur, tkSharpen, tkDodge, tkMixer,
                            tkBurn, tkSponge} and not (s.o.tool == tkEraser and s.o.eraseMode in {emPencil, emBlock})
  let byPressure = s.o.sizeByPressure or dy.sizeControl == dcPressure
  var k = if byPressure and s.pressure < 0.999 and s.o.tool in {tkBrush, tkAirbrush, tkEraser, tkMixer}:
            s.pressure else: 1.0
  var tip = s.tip
  var changed = k < 0.999
  if shaped and dy.sizeControl == dcTilt and s.tilt > 0.01:
    # (Pen Tilt: smaller as the pen is laid down)
    k *= max(clamp(dy.minDiameter, 0, 100).float / 100, 1 - s.tilt)
    changed = true
  if shaped and dy.sizeControl == dcFade and dy.sizeFade > 0:
    # (smaller each dab, down to the minimum)
    let lo = clamp(dy.minDiameter, 0, 100).float / 100
    k *= max(lo, 1 - s.dabs.float / dy.sizeFade.float)
    changed = true
  if shaped and dy.sizeJitter > 0:
    let lo = clamp(dy.minDiameter, 0, 100).float / 100
    k *= max(lo, 1 - s.rng.rand(1.0) * dy.sizeJitter.float / 100)
    changed = true
  if shaped and dy.angleControl != anOff:
    # (the tip turns as the stroke does, or as it began)
    if not s.hasStartDir:
      s.startDir = arctan2(s.dirY, s.dirX)
      s.hasStartDir = true
    let a = if dy.angleControl == anDirection: arctan2(s.dirY, s.dirX) else: s.startDir
    tip.angle = tip.angle - int(round(radToDeg(a)))
    changed = true
  if shaped and not dy.pose and dy.angleControl in {anPenTilt, anRotation}:
    # (a real pen: the tip turns the way it leans, or as it is turned)
    let deg = if dy.angleControl == anPenTilt: radToDeg(s.azimuth) else: s.twist
    tip.angle = tip.angle - int(round(deg))
    changed = true
  if shaped and not dy.pose and dy.roundTilt and s.tilt > 0.02 and tip.custom.len == 0:
    tip.roundness = max(5, int(round(tip.roundness.float * (1 - 0.75 * min(1.0, s.tilt)))))
    changed = true
  if shaped and dy.angleJitter > 0:
    tip.angle = tip.angle + int(round((s.rng.rand(2.0) - 1) * 180 * dy.angleJitter.float / 100))
    changed = true
  if shaped and dy.roundJitter > 0 and tip.custom.len == 0:
    tip.roundness = max(1, int(round(tip.roundness.float * (1 - s.rng.rand(1.0) * dy.roundJitter.float / 100))))
    changed = true
  if shaped and dy.pose:
    # (a tilted pen: a flatter dab, turned the way it leans; and a rotation)
    let tilt = sqrt((dy.tiltX * dy.tiltX + dy.tiltY * dy.tiltY).float) / 100
    if tilt > 0.01:
      tip.roundness = max(5, int(round(tip.roundness.float * (1 - 0.7 * min(1.0, tilt)))))
      tip.angle = tip.angle + int(round(radToDeg(arctan2(dy.tiltY.float, dy.tiltX.float))))
    tip.angle = tip.angle + dy.rotation
    changed = true
  if shaped and dy.flipXJitter and s.rng.rand(1.0) < 0.5:
    tip.flipX = not tip.flipX
    changed = true
  if shaped and dy.flipYJitter and s.rng.rand(1.0) < 0.5:
    tip.flipY = not tip.flipY
    changed = true
  if tip.custom.len > 0 and tip.angle mod 360 != 0:
    # (a sampled tip turned: its picture turned)
    tip = tip.turned(tip.angle)
    changed = true
  if changed: m = tipMask(tip, max(0.02, k))
  let fw = m.fullW
  let fh = m.fullH
  let x0 = int(floor(cx)) - fw div 2
  let y0 = int(floor(cy)) - fh div 2
  let r = d.clip(rect(x0, y0, fw, fh))
  if r.w <= 0 or r.h <= 0:
    inc s.dabs
    return
  # the stroke's own sources first (the stamp), then what it paints on
  if s.o.tool == tkStamp and s.o.stamp in {smCloneAligned, smClone, smImpressionist}:
    d.touch(L, d.clip(rect(x0 + int(s.offX), y0 + int(s.offY), fw, fh)))
  d.touch(L, r)
  s.area = if s.area.w <= 0: r else: union(s.area, r)
  # fading
  var strength = s.o.opacity.float / 100
  if s.o.opacityByPressure or dy.opacityControl == dcPressure: strength *= s.pressure
  if dy.opacityControl == dcTilt: strength *= max(0.05, 1 - s.tilt)
  if dy.opacityControl == dcFade and dy.opacityFade > 0: strength *= max(0.0, 1 - s.dabs.float / dy.opacityFade.float)
  if dy.opacityJitter > 0: strength *= 1 - s.rng.rand(1.0) * dy.opacityJitter.float / 100
  var flowK = if dy.flow > 0 and dy.flow < 100: dy.flow.float / 100 else: 1.0
  if dy.flowControl == dcPressure: flowK *= s.pressure
  if dy.flowControl == dcFade and dy.flowFade > 0: flowK *= max(0.0, 1 - s.dabs.float / dy.flowFade.float)
  if dy.flowJitter > 0: flowK *= 1 - s.rng.rand(1.0) * dy.flowJitter.float / 100
  var color = if s.useBg: s.o.bg else: s.o.color
  if dy.fgBgJitter > 0: color = mix(color, s.o.bg, s.rng.rand(1.0) * dy.fgBgJitter.float / 100)
  if dy.hueJitter > 0 or dy.brightJitter > 0 or dy.satJitter > 0 or dy.purity != 0:
    var hsb = toHsb(color)
    hsb.h = floorMod(hsb.h + (s.rng.rand(2.0) - 1) * 180 * dy.hueJitter.float / 100, 360.0)
    hsb.s = clamp(hsb.s * (1 - s.rng.rand(1.0) * dy.satJitter.float / 100), 0.0, 1.0)
    if dy.purity != 0:
      let p = clamp(dy.purity, -100, 100).float / 100
      hsb.s = clamp(if p > 0: hsb.s + (1 - hsb.s) * p else: hsb.s * (1 + p), 0.0, 1.0)
    hsb.b = clamp(hsb.b * (1 - s.rng.rand(1.0) * dy.brightJitter.float / 100), 0.0, 1.0)
    color = fromHsb(hsb.h, hsb.s, hsb.b, aOf(color))
  if s.o.fade > 0:
    let t = s.dabs.float / s.o.fade.float
    if s.o.fadeToBg: color = mix(s.o.color, s.o.bg, min(1.0, t))
    elif t >= 1:
      inc s.dabs
      return
    else: strength *= 1 - t
  let w = d.w
  # the texture's grain, the dual brush: how much of the dab shows at a pixel
  let textured = s.o.texture.len > 0 and s.o.tw > 0 and s.o.th > 0 and s.o.texture.len == s.o.tw * s.o.th
  let tscale = (if s.o.textureScale > 0: s.o.textureScale else: 100).float / 100
  let tdepth = clamp(s.o.textureDepth, 0, 100).float32 / 100
  let texP = if textured: cast[ptr UncheckedArray[uint8]](addr s.o.texture[0]) else: nil
  let texW = s.o.tw
  let texH = s.o.th
  let texInv = s.o.textureInvert
  template grainAt(x, y: int): float32 =
    block:
      let tx = floorMod(int(x.float / tscale), texW)
      let ty = floorMod(int(y.float / tscale), texH)
      var g = texP[ty * texW + tx].float32 / 255
      if texInv: g = 1 - g
      1 - tdepth * (1 - g)
  let dualOn = s.dualMask.w > 0
  let dsc = clamp(s.o.dualScatter, 0, 400).float / 100
  let dox = if dualOn: int((s.rng.rand(2.0) - 1) * dsc * s.dualMask.w.float) else: 0
  let doy = if dualOn: int((s.rng.rand(2.0) - 1) * dsc * s.dualMask.h.float) else: 0
  let dmW = max(1, s.dualMask.w)
  let dmH = max(1, s.dualMask.h)
  let dmP = if dualOn: cast[ptr UncheckedArray[float32]](addr s.dualMask.a[0]) else: nil
  template dualAt(x, y: int): float32 =
    block:
      let dxm = floorMod(x + dox, dmW)
      let dym = floorMod(y + doy, dmH)
      dmP[dym * dmW + dxm]
  # Noise: grain in the soft part of the dab (the same at a pixel each time)
  let noisy = dy.noise
  template noiseAt(x, y: int): float32 =
    block:
      var h = uint32(x) * 0x9E3779B1'u32 xor uint32(y) * 0x85EBCA77'u32
      h = (h xor (h shr 15)) * 0x2C1B3C6D'u32
      0.35'f32 + 1.3'f32 * float32(h shr 8) / 16777216'f32
  case s.o.tool
  of tkMixer:
    # the paint on the canvas under the dab, and the paint the brush holds,
    # mixed; the brush takes some of the canvas's up (wet), and runs dry
    var acc = [0.0, 0.0, 0.0, 0.0]
    var tot = 0.0
    for y in r.y ..< r.y + r.h:
      for x in r.x ..< r.x + r.w:
        let a = m.maskAt(x - x0, y - y0).float
        if a <= 0: continue
        let p = L.px[y * w + x]
        let pa = aOf(p).float * a
        acc[0] += pa
        acc[1] += rOf(p).float * pa
        acc[2] += gOf(p).float * pa
        acc[3] += bOf(p).float * pa
        tot += a
    let wet = clamp(s.o.wetness, 0, 100).float / 100
    let mixK = clamp(s.o.mixRatio, 0, 100).float / 100 * wet
    var canvas = s.reservoir
    if acc[0] > 0:
      canvas = [acc[0] / max(1e-9, tot), acc[1] / acc[0], acc[2] / acc[0], acc[3] / acc[0]]
    var paint: array[4, float]
    for k in 0 .. 3: paint[k] = s.reservoir[k] * (1 - mixK) + canvas[k] * mixK
    # (what the brush holds: dirtied by the canvas, drained)
    for k in 0 .. 3: s.reservoir[k] = s.reservoir[k] * (1 - wet * 0.35) + canvas[k] * wet * 0.35
    let load = max(1, s.o.load).float
    s.paintLeft = max(0.0, s.paintLeft - 1 / (2 + load * 1.5))
    let amount = strength * flowK * (0.25 + 0.75 * max(s.paintLeft, wet))
    let pc = argb(clamp(int(round(paint[0])), 0, 255), clamp(int(round(paint[1])), 0, 255),
                  clamp(int(round(paint[2])), 0, 255), clamp(int(round(paint[3])), 0, 255))
    for y in r.y ..< r.y + r.h:
      for x in r.x ..< r.x + r.w:
        var a = m.maskAt(x - x0, y - y0)
        if textured: a *= grainAt(x, y)
        if dualOn: a *= dualAt(x, y)
        let k = int(round(a.float * amount * 255))
        if k <= 0: continue
        let i = y * w + x
        let p = L.px[i]
        let np = if aOf(p) == 0: withAlpha(pc, k) else: blendPx(p, pc, k, bmNormal)
        L.px[i] = d.applyAt(L, i, p, np, 255)
  of tkBrush, tkPencil, tkAirbrush, tkEraser, tkStamp:
    let air = s.o.tool == tkAirbrush or (s.o.tool == tkEraser and s.o.eraseMode == emAirbrush) or
              (dy.buildUp and s.o.tool == tkBrush)
    let flow = if air: strength * 0.18 else: 1.0
    let erase = s.o.tool == tkEraser
    let toBg = erase and (L.background or L.lockAlpha or L.gray) and not (s.o.bgErase and not L.gray and
                                                                           not L.lockAlpha and not L.background)
    # (the stroke's tiles made first: then the rows can go on all the cores)
    for ty in (r.y shr 6) .. ((r.y + r.h - 1) shr 6):
      for tx in (r.x shr 6) .. ((r.x + r.w - 1) shr 6):
        discard s.cov.slot(tx shl 6, ty shl 6)
        if s.needCol: discard s.col.slot(tx shl 6, ty shl 6)
    let sp = addr s
    let mp = addr m
    let top = if air: 65535.0 else: strength * 65535
    let fk = if air: flow else: flowK
    let wet = s.o.wet and s.o.tool == tkBrush
    let needCol = s.needCol
    let stamp = s.o.tool == tkStamp
    let mode = s.o.mode
    # the Background Eraser: the color to rub out, how alike, and (contiguous)
    # what of the dab touches its middle through such colors
    let bgE = ((erase and s.o.bgErase) or (s.o.tool == tkBrush and s.o.colorReplace)) and not L.gray
    var reach: seq[bool]
    var bgCol = 0'u32
    let bgTol = clamp(s.o.bgTolerance, 0, 100).float * 2.55 + 0.5
    let fgCol = s.o.color
    let protect = s.o.bgProtectFg
    if bgE:
      var rd = origReader(d, L)
      let ci = clamp(int(floor(cx)), 0, d.w - 1)
      let cj = clamp(int(floor(cy)), 0, d.h - 1)
      case s.o.bgSampling
      of 1:
        if not s.bgSampled: s.bgSample = rd.at(ci, cj)
      of 2: s.bgSample = s.o.bg
      else: s.bgSample = rd.at(ci, cj)
      s.bgSampled = true
      bgCol = s.bgSample
      if s.o.bgLimits >= 1:
        reach = newSeq[bool](r.w * r.h)
        var todo = @[(ci, cj)]
        template alike(p: uint32): bool = colorDistance(p, bgCol).float <= bgTol
        if ci >= r.x and cj >= r.y and ci < r.x + r.w and cj < r.y + r.h and alike(rd.at(ci, cj)):
          reach[(cj - r.y) * r.w + (ci - r.x)] = true
          while todo.len > 0:
            let (px, py) = todo.pop()
            for (nx, ny) in [(px + 1, py), (px - 1, py), (px, py + 1), (px, py - 1)]:
              if nx < r.x or ny < r.y or nx >= r.x + r.w or ny >= r.y + r.h: continue
              let k = (ny - r.y) * r.w + (nx - r.x)
              if reach[k] or m.maskAt(nx - x0, ny - y0) <= 0: continue
              if alike(rd.at(nx, ny)):
                reach[k] = true
                todo.add (nx, ny)
    let reachP = if reach.len > 0: cast[ptr UncheckedArray[bool]](addr reach[0]) else: nil
    let sharpEdges = s.o.bgLimits == 2
    parallelFor(r.h, proc (lo, hi: int) =
      let s = sp
      var orig = origReader(d, L)
      var srcR = origReader(d, L)
      for y in r.y + lo ..< r.y + hi:
        for x in r.x ..< r.x + r.w:
          var a = mp[].maskAt(x - x0, y - y0)
          if a <= 0: continue
          if textured: a *= grainAt(x, y)
          if dualOn: a *= dualAt(x, y)
          if noisy and a < 0.999: a = min(1'f32, a * noiseAt(x, y))
          if a <= 0: continue
          if bgE:
            # (only what is like the sampled color goes: the more alike, the more)
            if reachP != nil and not reachP[(y - r.y) * r.w + (x - r.x)]: continue
            let p0 = orig.at(x, y)
            if protect and erase and colorDistance(p0, fgCol).float <= bgTol: continue
            let dist = colorDistance(p0, bgCol).float
            if dist > bgTol: continue
            let t = dist / max(1.0, bgTol)
            let wgt = if sharpEdges: (if t < 0.85: 1.0 else: (1 - t) / 0.15) else: 1 - t * t
            a *= float32(wgt)
            if a <= 0: continue
          let i = y * w + x
          let cp = s.cov.slot(x, y)
          var c = int(cp[])
          # dabs build up as layers of paint do (up to the stroke's opacity)
          let want = if c.float >= top: c
                     else: int(c.float + (top - c.float) * a * fk)
          if want <= c: continue
          cp[] = uint16(want)
          var pc = color
          if needCol:
            let colp = s.col.slot(x, y)
            if stamp:
              let sx = int(floor(x.float + s.offX))
              let sy = int(floor(y.float + s.offY))
              colp[] =
                case s.o.stamp
                of smPattern, smPatternAligned:
                  s.o.patternAt(if s.o.stamp == smPattern: x - int(s.lastX) else: x,
                                if s.o.stamp == smPattern: y - int(s.lastY) else: y)
                of smFromSnapshot, smFromSaved:
                  if s.o.saved.len == d.w * d.h: s.o.saved[i] else: orig.at(x, y)
                else:
                  if sx < 0 or sy < 0 or sx >= d.w or sy >= d.h: 0'u32
                  elif s.o.stamp == smImpressionist:
                    srcR.at(clamp(int(cx + s.offX), 0, d.w - 1), clamp(int(cy + s.offY), 0, d.h - 1))
                  else: srcR.at(sx, sy)
            else:
              colp[] = color
            pc = colp[]
          c = want
          let before = orig.at(x, y)
          var cov = c.float / 65535
          if wet: cov = wetEdge(cov)
          let amt = int(round(cov * 255))
          var after: uint32
          if erase and s.o.eraseToSaved and s.o.saved.len == d.w * d.h:
            after = mix(before, s.o.saved[i], amt / 255)
          elif erase:
            if toBg: after = blendPx(before, s.o.bg, amt, bmNormal)
            else: after = withAlpha(before, aOf(before) * (255 - amt) div 255)
          else:
            after = blendPx(before, pc, amt, mode, x, y)
          L.px[i] = d.applyAt(L, i, before, after, 255),
      grain = max(1, 16384 div max(1, r.w)))
  of tkSmudge:
    for y in r.y ..< r.y + r.h:
      for x in r.x ..< r.x + r.w:
        let j = (y - y0) * m.w + (x - x0)
        let a = m.maskAt(x - x0, y - y0).float * strength
        if a <= 0: continue
        let i = y * w + x
        let p = L.px[i]
        var car = s.smudge[j]
        let cur = [aOf(p).float, rOf(p).float, gOf(p).float, bOf(p).float]
        var outc: array[4, float]
        for k in 0 .. 3: outc[k] = cur[k] + (car[k] - cur[k]) * a
        let np = argb(int(round(outc[0])), int(round(outc[1])), int(round(outc[2])), int(round(outc[3])))
        L.px[i] = d.applyAt(L, i, p, np, 255)
        # the paint carried picks up some of what is here
        for k in 0 .. 3: car[k] = car[k] + (cur[k] - car[k]) * (1 - strength) * 0.5
        s.smudge[j] = car
  of tkBlur, tkSharpen:
    var src = newSeq[uint32](r.w * r.h)
    for y in 0 ..< r.h:
      for x in 0 ..< r.w: src[y * r.w + x] = L.px[(r.y + y) * w + r.x + x]
    for y in r.y ..< r.y + r.h:
      for x in r.x ..< r.x + r.w:
        let a = m.maskAt(x - x0, y - y0).float * strength
        if a <= 0: continue
        var acc = [0.0, 0.0, 0.0, 0.0]
        var n = 0.0
        for dy in -1 .. 1:
          for dx in -1 .. 1:
            let xx = clamp(x + dx, 0, d.w - 1)
            let yy = clamp(y + dy, 0, d.h - 1)
            let p = if xx >= r.x and yy >= r.y and xx < r.x + r.w and yy < r.y + r.h:
                      src[(yy - r.y) * r.w + xx - r.x] else: L.px[yy * w + xx]
            acc[0] += aOf(p).float; acc[1] += rOf(p).float; acc[2] += gOf(p).float
            acc[3] += bOf(p).float
            n += 1
        let i = y * w + x
        let p = src[(y - r.y) * r.w + x - r.x]
        let cur = [aOf(p).float, rOf(p).float, gOf(p).float, bOf(p).float]
        var o: array[4, float]
        for k in 0 .. 3:
          let blur = acc[k] / n
          o[k] = if s.o.tool == tkBlur: cur[k] + (blur - cur[k]) * a * 0.5
                 else: cur[k] + (cur[k] - blur) * a * 0.6
        let np = argb(int(round(o[0])), int(round(o[1])), int(round(o[2])), int(round(o[3])))
        L.px[i] = d.applyAt(L, i, p, if s.o.tool == tkSharpen: np.withAlpha(aOf(p)) else: np, 255)
  of tkDodge, tkBurn, tkSponge:
    for y in r.y ..< r.y + r.h:
      for x in r.x ..< r.x + r.w:
        let a = m.maskAt(x - x0, y - y0).float * strength * 0.25
        if a <= 0: continue
        let i = y * w + x
        let p = L.px[i]
        var np: uint32
        if s.o.tool == tkSponge:
          var hsl = toHsl(p)
          hsl.s = clamp(hsl.s + (if s.o.saturate: a else: -a), 0.0, 1.0)
          np = fromHsl(hsl.h, hsl.s, hsl.l, aOf(p))
        else:
          let l = lumaOf(p).float / 255
          let k = a * toneWeight(s.o.tone, l) * 2
          var ch: array[3, float]
          for c, v in [rOf(p), gOf(p), bOf(p)]:
            let f = v.float / 255
            ch[c] = if s.o.tool == tkDodge: f + (1 - f) * k else: f * (1 - k)
          np = argb(aOf(p), int(round(ch[0] * 255)), int(round(ch[1] * 255)), int(round(ch[2] * 255)))
        L.px[i] = d.applyAt(L, i, p, np, 255)
  inc s.dabs
  inc L.ver
  d.markDirty(r)

proc symmetric*(o: PaintOpts; w, h: int; x, y: float): seq[(float, float)] =
  ## Where a dab at `x`, `y` is painted with the symmetry (itself first).
  result = @[(x, y)]
  let dy = o.dyn
  if dy.symmetry == syNone or o.tool in {tkSmudge, tkStamp}: return
  let cx = if dy.centerX >= 0 and dy.centerX > 0: dy.centerX else: w / 2
  let cy = if dy.centerY >= 0 and dy.centerY > 0: dy.centerY else: h / 2
  case dy.symmetry
  of syVertical: result.add (2 * cx - x, y)
  of syHorizontal: result.add (x, 2 * cy - y)
  of syDual:
    result.add (2 * cx - x, y)
    result.add (x, 2 * cy - y)
    result.add (2 * cx - x, 2 * cy - y)
  of syRadial, syMandala:
    let n = clamp(dy.axes, 2, 16)
    let rx = x - cx
    let ry = y - cy
    for k in 1 ..< n:
      let a = k.float * 2 * PI / n.float
      result.add (cx + rx * cos(a) - ry * sin(a), cy + rx * sin(a) + ry * cos(a))
    if dy.symmetry == syMandala:
      for k in 0 ..< n:
        let a = k.float * 2 * PI / n.float
        let mx = -rx
        result.add (cx + mx * cos(a) - ry * sin(a), cy + mx * sin(a) + ry * cos(a))
  else: discard

proc place(s: var Stroke; x, y: float) =
  ## The dabs of one step: scattered, counted, mirrored.
  let dy = s.o.dyn
  var n = max(1, dy.count)
  if dy.countJitter > 0: n = max(1, int(round(n.float * (1 - s.rng.rand(1.0) * dy.countJitter.float / 100))))
  let dia = max(1, s.mask.fullW).float
  for _ in 0 ..< n:
    var px = x
    var py = y
    if dy.scatter > 0:
      let amt = dia * dy.scatter.float / 100
      # (across the stroke; along it too when asked)
      let nx = -s.dirY
      let ny = s.dirX
      let off = (s.rng.rand(2.0) - 1) * amt
      px += nx * off
      py += ny * off
      if dy.scatterBoth:
        let off2 = (s.rng.rand(2.0) - 1) * amt
        px += s.dirX * off2
        py += s.dirY * off2
    for (qx, qy) in s.o.symmetric(s.d.w, s.d.h, px, py): s.dab(qx, qy)

proc penPose*(s: var Stroke; tilt, azimuth, twist: float) =
  ## The pen as it is now (a stylus's tilt 0 upright .. 1 flat, the way it
  ## leans in radians, its barrel turned in degrees): Pen Tilt and Rotation
  ## in the brush's dynamics follow it.
  s.tilt = clamp(tilt, 0.0, 1.0)
  s.azimuth = azimuth
  s.twist = twist

proc strokeTo*(s: var Stroke; x, y: float; pressure = 1.0) =
  ## The stroke goes on to `x`, `y`: dabs along the way, spaced as the
  ## brush says.
  s.pressure = pressure
  let sp = s.spacingOf()
  let dx = x - s.lastX
  let dy = y - s.lastY
  let dist = sqrt(dx * dx + dy * dy)
  if dist > 1e-9:
    s.dirX = dx / dist
    s.dirY = dy / dist
  if sp <= 0:
    s.place(x, y)
  elif dist > 0:
    var t = sp - s.carry
    while t <= dist:
      s.place(s.lastX + dx * t / dist, s.lastY + dy * t / dist)
      t += sp
    s.carry = dist - (t - sp)
  s.lastX = x
  s.lastY = y
  if s.L == s.d.maskLayer: s.d.syncQuickMask()

proc startStroke*(s: var Stroke) =
  ## The first dab, where the stroke began.
  if s.dirX == 0 and s.dirY == 0: s.dirX = 1
  s.place(s.lastX, s.lastY)
  if s.L == s.d.maskLayer: s.d.syncQuickMask()

proc strokeTick*(s: var Stroke) =
  ## The airbrush held still: more paint where it is.
  if s.o.tool == tkAirbrush or (s.o.tool == tkEraser and s.o.eraseMode == emAirbrush) or
     (s.o.dyn.buildUp and s.o.tool in {tkBrush, tkMixer}):
    s.place(s.lastX, s.lastY)

proc strokeDoc*(s: Stroke): Doc = s.d
  ## The document a stroke paints on.
proc strokeLayer*(s: Stroke): Layer = s.L
  ## The layer a stroke paints on.
proc coverage*(s: Stroke; i: int): int =
  ## How much of pixel `i` the stroke covers, 0..65535 (until `endStroke`).
  if i < 0 or not s.cov.used or i >= s.d.w * s.d.h: return 0
  int(s.cov.get(i mod s.d.w, i div s.d.w))
proc stampOffset*(s: Stroke): (float, float) = (s.offX, s.offY)
  ## The rubber stamp's stroke: from where it paints to where it copies.

proc endStroke*(s: var Stroke) =
  ## Ends the stroke (the Quick Mask takes it as the selection).
  if s.L == s.d.maskLayer: s.d.syncQuickMask()
  s.cov = TileBuf[uint16]()
  s.col = TileBuf[uint32]()

# ---- filling, the magic wand ------------------------------------------------------------------------------

proc colorDiff(a, b: uint32): int {.inline.} =
  max(max(abs(rOf(a) - rOf(b)), abs(gOf(a) - gOf(b))),
      max(abs(bOf(a) - bOf(b)), abs(aOf(a) - aOf(b))))

proc regionMask*(d: Doc; x, y: int; tolerance: int; merged = false; contiguous = true;
                 antialias = true): seq[uint8] =
  ## The pixels like the one at `x`, `y` (within `tolerance` on every
  ## channel): those touching it, or all of them. Soft-edged with
  ## `antialias`.
  result = newSeq[uint8](d.w * d.h)
  if x < 0 or y < 0 or x >= d.w or y >= d.h: return
  if merged: d.updateComposite()
  let src = if merged: d.compPtr else: cast[ptr UncheckedArray[uint32]](addr d.layer.px[0])
  let seed = src[y * d.w + x]
  let tol = clamp(tolerance, 0, 255)
  if not contiguous:
    for i in 0 ..< d.w * d.h:
      if colorDiff(src[i], seed) <= tol: result[i] = 255
  else:
    var stack = @[(x, y)]
    while stack.len > 0:
      let (sx, sy) = stack.pop()
      var lx = sx
      let row = sy * d.w
      if result[row + lx] != 0 or colorDiff(src[row + lx], seed) > tol: continue
      while lx > 0 and result[row + lx - 1] == 0 and colorDiff(src[row + lx - 1], seed) <= tol: dec lx
      var rx = sx
      while rx + 1 < d.w and result[row + rx + 1] == 0 and colorDiff(src[row + rx + 1], seed) <= tol: inc rx
      for xx in lx .. rx: result[row + xx] = 255
      for ny in [sy - 1, sy + 1]:
        if ny < 0 or ny >= d.h: continue
        var xx = lx
        let nrow = ny * d.w
        while xx <= rx:
          if result[nrow + xx] == 0 and colorDiff(src[nrow + xx], seed) <= tol:
            stack.add (xx, ny)
            while xx <= rx and result[nrow + xx] == 0 and colorDiff(src[nrow + xx], seed) <= tol: inc xx
          inc xx
  if antialias:
    # the edge: partly in, by how near it is to the tolerance
    var soft = result
    for yy in 0 ..< d.h:
      for xx in 0 ..< d.w:
        let i = yy * d.w + xx
        if result[i] != 0: continue
        var near = 0
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
          let nx = xx + dx
          let ny = yy + dy
          if nx >= 0 and ny >= 0 and nx < d.w and ny < d.h and result[ny * d.w + nx] != 0: inc near
        if near > 0:
          let over = colorDiff(src[i], seed) - tol
          let k = clamp(1.0 - over.float / 48.0, 0.0, 1.0) * near.float / 4
          soft[i] = uint8(round(k * 160))
    result = soft

proc growSelection*(d: Doc; tolerance: int; similar = false) =
  ## Select > Grow (the colors touching the selection) and Similar (those
  ## anywhere).
  if not d.hasSelection: return
  d.updateComposite()
  let cp = d.compPtr
  var seeds: seq[uint32]
  var tally: seq[(int, int)]
  for i, v in d.sel:
    if v >= 128:
      tally.add (i mod d.w, i div d.w)
      if tally.len > 4000: break
  if tally.len == 0: return
  var m = newSeq[uint8](d.w * d.h)
  for s in tally:
    seeds.add cp[s[1] * d.w + s[0]]
  # the range of colors in the selection, grown by the tolerance
  var lo = [255, 255, 255]
  var hi = [0, 0, 0]
  for c in seeds:
    for k, v in [rOf(c), gOf(c), bOf(c)]:
      lo[k] = min(lo[k], v); hi[k] = max(hi[k], v)
  let tol = tolerance
  proc fits(p: uint32): bool =
    for k, v in [rOf(p), gOf(p), bOf(p)]:
      if v < lo[k] - tol or v > hi[k] + tol: return false
    true
  if similar:
    for i in 0 ..< d.w * d.h:
      if d.sel[i] >= 128 or fits(cp[i]): m[i] = 255
  else:
    var stack: seq[int]
    for i, v in d.sel:
      if v >= 128:
        m[i] = 255
        stack.add i
    while stack.len > 0:
      let i = stack.pop()
      let x = i mod d.w
      let y = i div d.w
      for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
        let nx = x + dx
        let ny = y + dy
        if nx < 0 or ny < 0 or nx >= d.w or ny >= d.h: continue
        let j = ny * d.w + nx
        if m[j] == 0 and fits(cp[j]):
          m[j] = 255
          stack.add j
  d.sel = m
  inc d.selVer

proc bucketFill*(d: Doc; x, y: int; o: PaintOpts; tolerance: int; antialias = true;
                 usePattern = false; contiguous = true; allLayers = false) =
  ## The paint bucket: the pixels like the one clicked (touching it, or all
  ## of them when not `contiguous`) take the foreground color (or the
  ## pattern); with `allLayers`, alike in the picture as it shows, the
  ## paint going on the layer.
  let m = d.regionMask(x, y, tolerance, allLayers, contiguous, antialias)
  let L = d.paintTarget
  var r = rect(d.w, d.h, 0, 0)
  var x0 = d.w
  var y0 = d.h
  var x1 = -1
  var y1 = -1
  for i, v in m:
    if v != 0:
      let xx = i mod d.w
      let yy = i div d.w
      x0 = min(x0, xx); y0 = min(y0, yy); x1 = max(x1, xx); y1 = max(y1, yy)
  if x1 < 0: return
  r = rect(x0, y0, x1 - x0 + 1, y1 - y0 + 1)
  d.touch(L, r)
  let op = clamp(o.opacity, 1, 100) * 255 div 100
  let c = if L.gray: grayPx(lumaOf(o.color)) else: d.fitColor(o.color)
  for yy in r.y ..< r.y + r.h:
    for xx in r.x ..< r.x + r.w:
      let i = yy * d.w + xx
      if m[i] == 0: continue
      let p = L.px[i]
      let paint = if usePattern: o.patternAt(xx, yy) else: c
      L.px[i] = d.applyAt(L, i, p, blendPx(p, paint, op, o.mode, xx, yy), int(m[i]))
  inc L.ver
  if L == d.maskLayer: d.syncQuickMask()
  d.markDirty(r)

# ---- the Art History Brush ------------------------------------------------------------------------------

type
  ArtStyle* = enum
    ## How the Art History Brush's strokes go (as Photoshop's).
    asTightShort = "Tight Short", asTightMedium = "Tight Medium", asTightLong = "Tight Long",
    asLooseMedium = "Loose Medium", asLooseLong = "Loose Long", asDab = "Dab",
    asTightCurl = "Tight Curl", asTightCurlLong = "Tight Curl Long", asLooseCurl = "Loose Curl",
    asLooseCurlLong = "Loose Curl Long"

proc artHistoryDabs*(d: Doc; src: seq[uint32]; x, y: float; size: float; style: ArtStyle;
                     area: float; tolerance: int; opacity: int; seed: var uint32; mode = bmNormal) =
  ## The Art History Brush at (`x`, `y`): quick strokes, `size` pixels wide,
  ## scattered over `area` (a radius), each in the color the source
  ## (`src`: the state or snapshot the History palette marks) has where it
  ## starts, going along its edges -- tight or loose, short or long, curled
  ## -- only where the layer differs from the source by `tolerance` levels
  ## or more. In the selection; saved for undo when a step is open.
  let L = d.paintTarget
  if L == nil or src.len != d.w * d.h or L.px.len != d.w * d.h: return
  proc rnd(s: var uint32): float =
    s = s xor (s shl 13); s = s xor (s shr 17); s = s xor (s shl 5)
    float(s and 0xFFFFFF) / float(0x1000000)
  let rad = max(0.5, size / 2)
  let lum = proc (i: int): float =
    let p = src[i]
    0.299 * rOf(p).float + 0.587 * gOf(p).float + 0.114 * bOf(p).float
  let (lenK, loose, curl) = case style
    of asTightShort: (1.5, false, 0.0)
    of asTightMedium: (3.0, false, 0.0)
    of asTightLong: (6.0, false, 0.0)
    of asLooseMedium: (3.0, true, 0.0)
    of asLooseLong: (6.0, true, 0.0)
    of asDab: (0.01, false, 0.0)
    of asTightCurl: (3.0, false, 0.35)
    of asTightCurlLong: (6.0, false, 0.25)
    of asLooseCurl: (3.0, true, 0.35)
    of asLooseCurlLong: (6.0, true, 0.25)
  let count = clamp(int(area * area / max(1.0, rad * rad * 4)), 1, 24)
  let op = clamp(opacity, 1, 100) * 255 div 100
  for k in 0 ..< count:
    # where it starts: somewhere in the area
    let a = rnd(seed) * 2 * PI
    let rr = sqrt(rnd(seed)) * area
    var px = x + cos(a) * rr
    var py = y + sin(a) * rr
    var ix = int(px)
    var iy = int(py)
    if ix < 1 or iy < 1 or ix >= d.w - 1 or iy >= d.h - 1: continue
    let i0 = iy * d.w + ix
    if d.selAt(i0) == 0: continue
    let c = src[i0] or 0xFF000000'u32
    if tolerance > 0:
      let cur = L.px[i0]
      let diff = max(abs(rOf(cur) - rOf(c)), max(abs(gOf(cur) - gOf(c)), abs(bOf(cur) - bOf(c))))
      if diff < tolerance: continue
    # along the edge there: across the source's slope (loose: a little off it)
    var gx = lum(i0 + 1) - lum(i0 - 1)
    var gy = lum(i0 + d.w) - lum(i0 - d.w)
    var dir = if abs(gx) + abs(gy) < 1e-6: rnd(seed) * 2 * PI else: arctan2(gy, gx) + PI / 2
    if loose: dir += (rnd(seed) - 0.5) * 1.2
    if rnd(seed) < 0.5: dir += PI
    let total = max(0.0, lenK * rad * 2 * (0.6 + rnd(seed) * 0.8))
    let step = max(0.75, rad / 2)
    let steps = max(1, int(total / step))
    let turn = if curl > 0: curl * (if rnd(seed) < 0.5: 1.0 else: -1.0) else: 0.0
    # the stroke's box saved, then its dabs
    let reach = total + rad + 2
    let box = d.clip(rect(int(px - reach), int(py - reach), int(2 * reach) + 1, int(2 * reach) + 1))
    if box.w <= 0 or box.h <= 0: continue
    d.touch(L, box)
    for sIdx in 0 .. steps:
      let r0 = int(floor(rad))
      for dy in -r0 - 1 .. r0 + 1:
        for dx in -r0 - 1 .. r0 + 1:
          let qx = int(px) + dx
          let qy = int(py) + dy
          if qx < 0 or qy < 0 or qx >= d.w or qy >= d.h: continue
          let dist = hypot(qx.float + 0.5 - px, qy.float + 0.5 - py)
          if dist > rad + 0.5: continue
          let cov = if dist <= rad - 0.5: 255 else: int((rad + 0.5 - dist) * 255)
          let i = qy * d.w + qx
          let before = L.px[i]
          L.px[i] = d.applyAt(L, i, before, blendPx(before, c, op * cov div 255, mode, qx, qy), 255)
      px += cos(dir) * step
      py += sin(dir) * step
      dir += turn
      if px < 0 or py < 0 or px >= d.w.float or py >= d.h.float: break
    inc L.ver
    d.markDirty(box)

# ---- gradients --------------------------------------------------------------------------------------------

type
  GradientStyle* = enum
    ## The colors of a gradient the Gradient tool draws (`gradient`).
    gsFgToBg = "Foreground to Background", gsFgToTransparent = "Foreground to Transparent",
    gsTransparentToFg = "Transparent to Foreground"
  GradientKind* = enum
    ## The shape of a gradient: along a line, round a point, round it as an
    ## angle, along a line both ways, or a diamond.
    gkLinear = "Linear", gkRadial = "Radial", gkAngle = "Angle", gkReflected = "Reflected",
    gkDiamond = "Diamond"

var deepGradientHook*: proc (d: Doc; L: Layer; r: Rect; opacity: float32;
                             colorAt: proc (x, y: int): array[4, float32]) {.nimcall.}
  ## Draws a gradient at 16 or 32 bits (set by `retroui/photodeep`).

proc gradientColorF*(stops: openArray[GradientStop]; t: float): array[4, float32] =
  ## `gradientColor` in floats (R G B A 0 .. 1): no steps between levels.
  template f(c: uint32): array[4, float32] =
    [float32((c shr 16) and 255) / 255, float32((c shr 8) and 255) / 255, float32(c and 255) / 255,
     float32(c shr 24) / 255]
  if stops.len == 0: return
  if t <= stops[0].at: return f(stops[0].color)
  for k in 1 .. stops.high:
    if t <= stops[k].at:
      let a = stops[k - 1]
      let b = stops[k]
      let span = b.at - a.at
      if span <= 1e-9: result = f(b.color); return
      var u = (t - a.at) / span
      let m = if a.mid <= 0.001 or a.mid >= 0.999: 0.5 else: a.mid
      if abs(m - 0.5) > 1e-6 and u > 0: u = pow(u, ln(0.5) / ln(m))
      let ca = f(a.color)
      let cb = f(b.color)
      let wa = ca[3] * float32(1 - u)
      let wb = cb[3] * float32(u)
      let al = wa + wb
      result[3] = ca[3] + (cb[3] - ca[3]) * float32(u)
      for c in 0 .. 2:
        result[c] = if al > 1e-9: (ca[c] * wa + cb[c] * wb) / al else: ca[c] + (cb[c] - ca[c]) * float32(u)
      return
  f(stops[^1].color)

{.push boundChecks: off, overflowChecks: off.}

proc gradientFill*(d: Doc; x0, y0, x1, y1: float; o: PaintOpts; stops: seq[GradientStop];
                   kind = gkLinear; reverse = false; dither = true; radialOffset = 0) =
  ## The gradient tool: through `stops` from (`x0`, `y0`) to (`x1`, `y1`)
  ## -- along a line, round in circles, round the start point (Angle),
  ## both ways (Reflected), in a diamond -- in the selection, on all the
  ## cores. At 16 and 32 bits (Normal mode) it is drawn at those bits.
  let L = d.paintTarget
  let r = d.clip(d.selBounds)
  if r.w <= 0 or r.h <= 0 or stops.len == 0: return
  if d.depth >= 16 and deepGradientHook != nil and o.mode == bmNormal and not L.gray and
     L != d.maskLayer and d.mode in {cmRGB, cmGray}:
    let sx0 = x0
    let sy0 = y0
    let gdx = x1 - x0
    let gdy = y1 - y0
    let glen2 = max(1e-9, gdx * gdx + gdy * gdy)
    let glen = sqrt(glen2)
    let gang = arctan2(gdy, gdx)
    let goff = clamp(radialOffset, 0, 99).float / 100
    let gst = stops
    deepGradientHook(d, L, r, float32(clamp(o.opacity, 1, 100)) / 100, proc (x, y: int): array[4, float32] =
      let ux = x.float + 0.5 - sx0
      let uy = y.float + 0.5 - sy0
      var t = case kind
              of gkLinear: (ux * gdx + uy * gdy) / glen2
              of gkRadial: sqrt(ux * ux + uy * uy) / glen
              of gkAngle:
                var a = (arctan2(uy, ux) - gang) / (2 * PI)
                a - floor(a)
              of gkReflected: abs((ux * gdx + uy * gdy) / glen2)
              of gkDiamond: (abs(ux * gdx + uy * gdy) + abs(ux * gdy - uy * gdx)) / glen2
      if kind == gkRadial and goff > 0: t = (t - goff) / (1 - goff)
      t = clamp(t, 0.0, 1.0)
      gradientColorF(gst, if reverse: 1 - t else: t))
    return
  d.touch(L, r)
  # (the colors as the layer takes them: gray on a mask, the mode's)
  var st = stops
  for s in st.mitems:
    let a = aOf(s.color)
    s.color = (if L.gray: grayPx(lumaOf(s.color)) else: d.fitColor(s.color or 0xFF000000'u32)).withAlpha(a)
  # (a table of 1024 colors along it)
  var table = newSeq[uint32](1025)
  for k in 0 .. 1024:
    let t = k / 1024
    table[k] = gradientColor(st, if reverse: 1 - t else: t)
  let dx = x1 - x0
  let dy = y1 - y0
  let len2 = max(1e-9, dx * dx + dy * dy)
  let len = sqrt(len2)
  let ang0 = arctan2(dy, dx)
  let off = clamp(radialOffset, 0, 99).float / 100
  let op = clamp(o.opacity, 1, 100) * 255 div 100
  let w = d.w
  let lp = cast[ptr UncheckedArray[uint32]](addr L.px[0])
  let tp = cast[ptr UncheckedArray[uint32]](addr table[0])
  let mode = o.mode
  parallelRows(r.h, yy):
    let y = r.y + yy
    for x in r.x ..< r.x + r.w:
      let i = y * w + x
      if d.selAt(i) == 0: continue
      let px = x.float + 0.5
      let py = y.float + 0.5
      let ux = px - x0
      let uy = py - y0
      var t = case kind
              of gkLinear: (ux * dx + uy * dy) / len2
              of gkRadial: sqrt(ux * ux + uy * uy) / len
              of gkAngle:
                var a = (arctan2(uy, ux) - ang0) / (2 * PI)
                a - floor(a)
              of gkReflected: abs((ux * dx + uy * dy) / len2)
              of gkDiamond: (abs(ux * dx + uy * dy) + abs(ux * dy - uy * dx)) / len2
      if kind == gkRadial and off > 0: t = (t - off) / (1 - off)
      t = clamp(t, 0.0, 1.0)
      if dither: t = clamp(t + (float(hash2(x, y) and 255) / 255 - 0.5) / 255, 0.0, 1.0)
      let c = tp[int(t * 1024 + 0.5)]
      let p = lp[i]
      lp[i] = d.applyAt(L, i, p, blendPx(p, c, op, mode, x, y), 255)
  inc L.ver
  if L == d.maskLayer: d.syncQuickMask()
  d.markDirty(r)

{.pop.}

proc styleStops*(style: GradientStyle; fg, bg: uint32; midpoint = 50): seq[GradientStop] =
  ## The stops of the three gradients of 1994.
  let (c0, c1) = case style
                 of gsFgToBg: (fg, bg)
                 of gsFgToTransparent: (fg, fg.withAlpha(0))
                 of gsTransparentToFg: (fg.withAlpha(0), fg)
  @[GradientStop(at: 0, color: c0, mid: clamp(midpoint, 13, 87) / 100), GradientStop(at: 1, color: c1)]

proc gradient*(d: Doc; x0, y0, x1, y1: float; o: PaintOpts; style = gsFgToBg; kind = gkLinear;
               midpoint = 50; radialOffset = 0; dither = true) =
  ## The gradient tool of 1994: from the foreground color to the background
  ## (or transparency).
  d.gradientFill(x0, y0, x1, y1, o, styleStops(style, o.color, o.bg, midpoint), kind,
                 dither = dither, radialOffset = radialOffset)

# ---- lines and shapes ---------------------------------------------------------------------------------------

type Arrowhead* = object
  ## The arrowheads of the line tool.
  atStart*, atEnd*: bool   ## an arrowhead at the line's start, at its end
  width*, length*: int     ## % of the line's width
  concavity*: int          ## -50..50 %

proc linePolygons*(x0, y0, x1, y1, width: float; arrows: Arrowhead): seq[seq[(float, float)]] =
  ## The outline of a thick line with its arrowheads.
  let dx = x1 - x0
  let dy = y1 - y0
  let l = sqrt(dx * dx + dy * dy)
  if l < 0.01: return
  let ux = dx / l
  let uy = dy / l
  let nx = -uy
  let ny = ux
  let hw = max(0.5, width / 2)
  var a = (x0, y0)
  var b = (x1, y1)
  let aw = max(width, 1) * max(10, arrows.width).float / 100 / 2
  let al = max(width, 1) * max(10, arrows.length).float / 100
  proc head(tipX, tipY, dirX, dirY: float): seq[(float, float)] =
    let bx = tipX - dirX * al
    let by = tipY - dirY * al
    let cv = clamp(arrows.concavity, -50, 50).float / 100 * al
    @[(tipX, tipY), (bx + (-dirY) * aw, by + dirX * aw), (bx + dirX * cv, by + dirY * cv),
      (bx - (-dirY) * aw, by - dirX * aw)]
  if arrows.atEnd:
    result.add head(x1, y1, ux, uy)
    b = (x1 - ux * al * 0.9, y1 - uy * al * 0.9)
  if arrows.atStart:
    result.add head(x0, y0, -ux, -uy)
    a = (x0 + ux * al * 0.9, y0 + uy * al * 0.9)
  result.add @[(a[0] + nx * hw, a[1] + ny * hw), (b[0] + nx * hw, b[1] + ny * hw),
               (b[0] - nx * hw, b[1] - ny * hw), (a[0] - nx * hw, a[1] - ny * hw)]

proc paintMask*(d: Doc; m: seq[uint8]; c: uint32; opacity = 100; mode = bmNormal) =
  ## Paints `c` where mask `m` is (in the selection).
  let L = d.paintTarget
  var x0 = d.w
  var y0 = d.h
  var x1 = -1
  var y1 = -1
  for i, v in m:
    if v != 0:
      x0 = min(x0, i mod d.w); x1 = max(x1, i mod d.w)
      y0 = min(y0, i div d.w); y1 = i div d.w
  if x1 < 0: return
  let r = rect(x0, y0, x1 - x0 + 1, y1 - y0 + 1)
  d.touch(L, r)
  let col = if L.gray: grayPx(lumaOf(c)) else: d.fitColor(c)
  let op = clamp(opacity, 1, 100) * 255 div 100
  for y in r.y ..< r.y + r.h:
    for x in r.x ..< r.x + r.w:
      let i = y * d.w + x
      if m[i] == 0: continue
      let p = L.px[i]
      L.px[i] = d.applyAt(L, i, p, blendPx(p, col, op * int(m[i]) div 255, mode, x, y), 255)
  inc L.ver
  if L == d.maskLayer: d.syncQuickMask()
  d.markDirty(r)

proc drawLine*(d: Doc; x0, y0, x1, y1: float; width: float; o: PaintOpts; arrows = Arrowhead();
               antialias = true) =
  ## The line tool.
  var m = newSeq[uint8](d.w * d.h)
  for poly in linePolygons(x0, y0, x1, y1, width, arrows):
    let pm = d.polygonMask(poly, antialias)
    for i in 0 ..< m.len: m[i] = max(m[i], pm[i])
  d.paintMask(m, o.color, o.opacity, o.mode)

# ---- type ----------------------------------------------------------------------------------------------------

type
  TypeAlign* = enum
    ## Where the lines of the Type tool's text stand: from the point to the
    ## right, round it, or to its left.
    taLeft = "Left", taCenter = "Center", taRight = "Right"
  TypeOpts* = object
    ## The Type tool's dialog.
    text*: string            ## what it says (lines separated by newlines)
    font*: string            ## "Sans" (FreeSans), "Serif" (FreeSerif), "Mono" (FreeMono)
    size*: float             ## pixels
    leading*: float          ## 0: automatic
    spacing*: float          ## extra pixels between letters
    bold*, italic*, underline*, outline*: bool  ## its style (`outline`: only the letters' edges)
    antialias*: bool         ## smooth edges (else every pixel all or nothing)
    align*: TypeAlign        ## where the lines stand

proc typeMask*(d: Doc; o: TypeOpts; x, y: float): seq[uint8] =
  ## The letters of `o.text` at `x`, `y` (the top of the first line, its
  ## left, middle or right end by the alignment) as a mask.
  let c = newCanvas2D(d.w, d.h)
  var f = ""
  if o.bold: f.add "bold "
  if o.italic: f.add "italic "
  f.add $max(1.0, o.size) & "px "
  f.add (case o.font
         of "Mono": "monospace"
         of "Serif": "serif"
         else: "FreeSans")
  c.font = f
  c.fillStyle = "#ffffff"
  c.strokeStyle = "#ffffff"
  c.textBaseline = "top"
  c.textAlign = case o.align
                of taLeft: "left"
                of taCenter: "center"
                of taRight: "right"
  let lead = if o.leading > 0: o.leading else: o.size * 1.25
  var yy = y
  for line in o.text.split('\n'):
    if o.spacing != 0:
      # letter by letter, spaced
      var widths: seq[float]
      var total = 0.0
      for ch in line.runes:
        let w = c.measureText($ch).width + o.spacing
        widths.add w
        total += w
      var xx = case o.align
               of taLeft: x
               of taCenter: x - total / 2
               of taRight: x - total
      let saved = c.textAlign
      c.textAlign = "left"
      var k = 0
      for ch in line.runes:
        if o.outline: c.strokeText($ch, xx, yy) else: c.fillText($ch, xx, yy)
        xx += widths[k]
        inc k
      c.textAlign = saved
    elif o.outline:
      c.lineWidth = max(1.0, o.size / 18)
      c.strokeText(line, x, yy)
    else:
      c.fillText(line, x, yy)
    if o.underline and line.len > 0:
      let w = c.measureText(line).width
      let lx = case o.align
               of taLeft: x
               of taCenter: x - w / 2
               of taRight: x - w
      c.fillRect(lx, yy + o.size * 1.02, w, max(1.0, o.size / 14))
    yy += lead
  let b = c.toBitmap()
  result = newSeq[uint8](d.w * d.h)
  for i in 0 ..< min(result.len, b.px.len):
    var a = aOf(b.px[i])
    if not o.antialias: a = if a >= 128: 255 else: 0
    result[i] = uint8(a)

proc typeLayer*(d: Doc; o: TypeOpts; x, y: float; color: uint32): Layer =
  ## The Type tool: the text in the foreground color, in a new layer named
  ## after it. (Undoable: `snapStep` first.)
  let m = d.typeMask(o, x, y)
  var name = o.text.replace("\n", " ").strip
  if name.len > 24: name = name[0 ..< 24] & "..."
  result = d.addLayer(if name.len > 0: name else: "Type")
  let c = d.fitColor(color)
  for i, v in m:
    if v != 0: result.px[i] = withAlpha(c, int(v))
  d.markAll()

# ---- paths ----------------------------------------------------------------------------------------------------

proc flatten*(p: Path; steps = 16): seq[seq[(float, float)]] =
  ## The path as polygons (its curves in short straight pieces); open
  ## subpaths too.
  for s in p.subs:
    if s.pts.len == 0: continue
    var poly: seq[(float, float)]
    poly.add s.pts[0].p
    let n = s.pts.len
    let segs = if s.closed: n else: n - 1
    for k in 0 ..< segs:
      let a = s.pts[k]
      let b = s.pts[(k + 1) mod n]
      if a.outH == a.p and b.inH == b.p:
        poly.add b.p
      else:
        for t in 1 .. steps:
          let u = t / steps
          let mu = 1 - u
          let x = mu * mu * mu * a.p[0] + 3 * mu * mu * u * a.outH[0] + 3 * mu * u * u * b.inH[0] + u * u * u * b.p[0]
          let y = mu * mu * mu * a.p[1] + 3 * mu * mu * u * a.outH[1] + 3 * mu * u * u * b.inH[1] + u * u * u * b.p[1]
          poly.add (x, y)
    if s.closed and poly.len > 1 and poly[^1] == poly[0]: poly.setLen(poly.len - 1)
    result.add poly

proc bezierAt(a, b: PathPoint; u: float): (float, float) =
  let mu = 1 - u
  (mu * mu * mu * a.p[0] + 3 * mu * mu * u * a.outH[0] + 3 * mu * u * u * b.inH[0] + u * u * u * b.p[0],
   mu * mu * mu * a.p[1] + 3 * mu * mu * u * a.outH[1] + 3 * mu * u * u * b.inH[1] + u * u * u * b.p[1])

type PathHit* = object
  ## What of a path is near a place (`hitPoint`, `nearestSegment`).
  sub*, i*: int            ## the subpath and its point (-1: none)
  part*: int               ## 0 the point, 1 its in handle, 2 its out handle
  t*: float                ## along the segment from point `i` to the next
  dist*: float             ## how far it is (image pixels)

proc hitPoint*(p: Path; x, y, radius: float; handles = true): PathHit =
  ## The point (or handle) of `p` nearest to (`x`, `y`) within `radius`.
  result = PathHit(sub: -1, i: -1, dist: radius)
  for si, sp in p.subs:
    for i, q in sp.pts:
      var parts = @[(0, q.p)]
      if handles:
        if q.inH != q.p: parts.add (1, q.inH)
        if q.outH != q.p: parts.add (2, q.outH)
      for (k, pt) in parts:
        let dd = sqrt((pt[0] - x) ^ 2 + (pt[1] - y) ^ 2)
        if dd <= result.dist:
          result = PathHit(sub: si, i: i, part: k, dist: dd)

proc nearestSegment*(p: Path; x, y, radius: float): PathHit =
  ## The place on a segment of `p` nearest to (`x`, `y`) within `radius`.
  result = PathHit(sub: -1, i: -1, dist: radius)
  for si, sp in p.subs:
    let n = sp.pts.len
    let segs = if sp.closed: n else: n - 1
    for k in 0 ..< segs:
      let a = sp.pts[k]
      let b = sp.pts[(k + 1) mod n]
      for step in 1 .. 63:
        let u = step / 64
        let q = bezierAt(a, b, u)
        let dd = sqrt((q[0] - x) ^ 2 + (q[1] - y) ^ 2)
        if dd < result.dist: result = PathHit(sub: si, i: k, t: u, dist: dd)

proc addPoint*(p: var Path; at: PathHit) =
  ## A point put in the segment `at` (from `nearestSegment`), the curve
  ## kept as it was (the segment split in two).
  if at.sub < 0 or at.sub >= p.subs.len: return
  let sp = addr p.subs[at.sub]
  let n = sp.pts.len
  if at.i < 0 or at.i >= n: return
  let j = (at.i + 1) mod n
  let a = sp.pts[at.i]
  let b = sp.pts[j]
  let t = clamp(at.t, 0.0, 1.0)
  proc lerp(u, v: (float, float)): (float, float) = (u[0] + (v[0] - u[0]) * t, u[1] + (v[1] - u[1]) * t)
  let ab = lerp(a.p, a.outH)
  let bc = lerp(a.outH, b.inH)
  let cd = lerp(b.inH, b.p)
  let abc = lerp(ab, bc)
  let bcd = lerp(bc, cd)
  let m = lerp(abc, bcd)
  sp.pts[at.i].outH = ab
  sp.pts[j].inH = cd
  sp.pts.insert(PathPoint(p: m, inH: abc, outH: bcd), at.i + 1)

proc deletePoint*(p: var Path; sub, i: int) =
  ## Takes point `i` out of a subpath (the subpath goes when it is empty).
  if sub < 0 or sub >= p.subs.len: return
  if i < 0 or i >= p.subs[sub].pts.len: return
  p.subs[sub].pts.delete(i)
  if p.subs[sub].pts.len == 0: p.subs.delete(sub)
  elif p.subs[sub].pts.len < 3: p.subs[sub].closed = false

proc convertPoint*(p: var Path; sub, i: int) =
  ## A smooth point becomes a corner (its handles on it); a corner keeps
  ## its place (drag from it to make it smooth).
  if sub < 0 or sub >= p.subs.len: return
  if i < 0 or i >= p.subs[sub].pts.len: return
  let q = addr p.subs[sub].pts[i]
  q.inH = q.p
  q.outH = q.p

proc smoothThrough*(sp: var SubPath; corners: seq[bool] = @[]) =
  ## The Curvature Pen's curve: the handles of every point set so the path
  ## goes smoothly through them all (Catmull-Rom); a point marked in
  ## `corners` stays a corner. (The ends of an open subpath: their handles
  ## halfway toward their neighbor's.)
  let n = sp.pts.len
  if n == 0: return
  template corner(i: int): bool = i < corners.len and corners[i]
  let openEnds = not sp.closed
  for i in 0 ..< n:
    let q = addr sp.pts[i]
    q.inH = q.p
    q.outH = q.p
    if corner(i) or n < 3 or (openEnds and (i == 0 or i == n - 1)): continue
    let a = sp.pts[(i + n - 1) mod n].p
    let b = sp.pts[(i + 1) mod n].p
    let tx = (b[0] - a[0]) / 6
    let ty = (b[1] - a[1]) / 6
    q.inH = (q.p[0] - tx, q.p[1] - ty)
    q.outH = (q.p[0] + tx, q.p[1] + ty)
  if openEnds and n >= 3:
    if not corner(0):
      let h = sp.pts[1].inH
      sp.pts[0].outH = ((sp.pts[0].p[0] + h[0]) / 2, (sp.pts[0].p[1] + h[1]) / 2)
    if not corner(n - 1):
      let h = sp.pts[n - 2].outH
      sp.pts[n - 1].inH = ((sp.pts[n - 1].p[0] + h[0]) / 2, (sp.pts[n - 1].p[1] + h[1]) / 2)

proc fitPath*(pts: seq[(float, float)]; tolerance = 2.0; closed = false; cornerAngle = 100.0): SubPath =
  ## The Freeform Pen: a hand-drawn line made a path of few points and
  ## smooth curves (Curve Fit: `tolerance`, in pixels -- the farther the
  ## curve may stray, the fewer the points). Turns sharper than
  ## `cornerAngle` degrees stay corners.
  result.closed = closed
  if pts.len == 0: return
  # (the points too close together dropped, then the fewest that keep the line within the tolerance)
  var clean = @[pts[0]]
  for q in pts:
    if hypot(q[0] - clean[^1][0], q[1] - clean[^1][1]) >= 0.75: clean.add q
  if clean.len == 1 and pts.len > 1: clean.add pts[^1]
  var keep = newSeq[bool](clean.len)
  keep[0] = true
  keep[^1] = true
  var stack = @[(0, clean.high)]
  let tol = max(0.25, tolerance)
  while stack.len > 0:
    let (lo, hi) = stack.pop()
    if hi <= lo + 1: continue
    let (ax, ay) = clean[lo]
    let (bx, by) = clean[hi]
    let len = hypot(bx - ax, by - ay)
    var worst = -1.0
    var at = -1
    for k in lo + 1 ..< hi:
      let (px, py) = clean[k]
      # (from the line between the ends -- or, where they meet, a loop, from the end)
      let dd = if len < 1e-6: hypot(px - ax, py - ay)
               else: abs((bx - ax) * (ay - py) - (ax - px) * (by - ay)) / len
      if dd > worst:
        worst = dd
        at = k
    if worst > tol:
      keep[at] = true
      stack.add (lo, at)
      stack.add (at, hi)
  for k, q in clean:
    if keep[k]: result.pts.add PathPoint(p: q, inH: q, outH: q)
  if closed and result.pts.len > 2 and
     hypot(result.pts[^1].p[0] - result.pts[0].p[0], result.pts[^1].p[1] - result.pts[0].p[1]) < tol * 2:
    result.pts.setLen(result.pts.len - 1)
  # (a sharp turn -- more than about 100 degrees -- is a corner)
  let n = result.pts.len
  var corners = newSeq[bool](n)
  for i in 0 ..< n:
    if not closed and (i == 0 or i == n - 1): continue
    let a = result.pts[(i + n - 1) mod n].p
    let b = result.pts[i].p
    let c = result.pts[(i + 1) mod n].p
    let v1 = (b[0] - a[0], b[1] - a[1])
    let v2 = (c[0] - b[0], c[1] - b[1])
    let l1 = hypot(v1[0], v1[1])
    let l2 = hypot(v2[0], v2[1])
    if l1 < 1e-9 or l2 < 1e-9: continue
    let cosA = (v1[0] * v2[0] + v1[1] * v2[1]) / (l1 * l2)
    corners[i] = cosA < cos(degToRad(cornerAngle))
  result.smoothThrough(corners)

proc pathMask*(d: Doc; p: Path; antialias = true): seq[uint8] =
  ## The inside of the path (each subpath closed).
  result = newSeq[uint8](d.w * d.h)
  for poly in p.flatten():
    if poly.len < 3: continue
    let m = d.polygonMask(poly, antialias)
    for i in 0 ..< m.len:
      result[i] = uint8(int(result[i]) xor int(m[i]))   # (even-odd between subpaths)

proc fillPath*(d: Doc; p: Path; c: uint32; opacity = 100; mode = bmNormal) =
  ## Fills the inside of the path with `c` (in the selection).
  d.paintMask(d.pathMask(p), c, opacity, mode)

proc strokePath*(d: Doc; p: Path; o: PaintOpts; tip: BrushTip) =
  ## The path stroked with a painting tool's brush.
  for poly in p.flatten():
    if poly.len == 0: continue
    var s = d.beginStroke(o, tip, poly[0][0], poly[0][1])
    s.startStroke()
    for i in 1 ..< poly.len: s.strokeTo(poly[i][0], poly[i][1])
    if poly.len > 2 and poly[0] != poly[^1]:
      for sp in p.subs:
        if sp.closed:
          s.strokeTo(poly[0][0], poly[0][1])
          break
    s.endStroke()

proc selectionOutlines*(d: Doc): seq[seq[(float, float)]] =
  ## The edges of the (hard) selection as closed outlines, clockwise, with
  ## a point only where they turn.
  if not d.hasSelection: return
  let w = d.w
  let h = d.h
  proc inside(x, y: int): bool =
    x >= 0 and y >= 0 and x < w and y < h and d.sel[y * w + x] >= 128
  # every pixel edge with the selection on its right, by where it starts
  var starts = initTable[(int, int), seq[int]]()
  var edges: seq[((int, int), (int, int))]
  template add(a, b: (int, int)) =
    starts.mgetOrPut(a, @[]).add edges.len
    edges.add (a, b)
  for y in 0 ..< h:
    for x in 0 ..< w:
      if not inside(x, y): continue
      if not inside(x, y - 1): add((x, y), (x + 1, y))
      if not inside(x + 1, y): add((x + 1, y), (x + 1, y + 1))
      if not inside(x, y + 1): add((x + 1, y + 1), (x, y + 1))
      if not inside(x - 1, y): add((x, y + 1), (x, y))
  var used = newSeq[bool](edges.len)
  for e0 in 0 ..< edges.len:
    if used[e0]: continue
    var loop: seq[(int, int)]
    var e = e0
    while not used[e]:
      used[e] = true
      loop.add edges[e][0]
      let nexts = starts.getOrDefault(edges[e][1])
      var nx = -1
      for k in nexts:
        if not used[k]:
          nx = k
          break
      if nx < 0: break
      e = nx
    if loop.len < 3: continue
    var keep: seq[(float, float)]
    for i, q in loop:
      let pr = loop[(i - 1 + loop.len) mod loop.len]
      let nq = loop[(i + 1) mod loop.len]
      if (q[0] - pr[0]) * (nq[1] - q[1]) - (q[1] - pr[1]) * (nq[0] - q[0]) != 0:
        keep.add (q[0].float, q[1].float)
    if keep.len >= 3: result.add keep

proc pathFromSelection*(d: Doc; tolerance = 2.0): Path =
  ## Make Work Path: the selection's outline as a path (its corners, the
  ## steps of curved edges thinned to `tolerance` pixels).
  result = Path(name: "Work Path")
  for loop in d.selectionOutlines():
    var thin: seq[(float, float)] = @[loop[0]]
    for q in loop[1 .. ^1]:
      if abs(q[0] - thin[^1][0]) + abs(q[1] - thin[^1][1]) >= tolerance: thin.add q
    if thin.len < 3: continue
    var sp = SubPath(closed: true)
    for q in thin: sp.pts.add PathPoint(p: q, inH: q, outH: q)
    result.subs.add sp

## Widgets for paint programs (with `photo` documents): the canvas view
## (zoomed by whole ratios, scroll bars, rulers, a checkerboard under what
## is transparent, the selection's marching ants, the Quick Mask in red,
## one channel in gray), the color picker of the 1990s editors (a field
## and a strip for one of H, S, B, R, G, B), a curves editor, the levels
## sliders over a histogram, brush tips, swatches, the rows of a layers
## or channels palette, the foreground/background colors, a 3 x 3 anchor
## and gradient sliders. Retro Photo (examples/photo.nim) is built with
## them.
##
## ```nim
## var d = newDoc(800, 600, 0xFFFFFFFF'u32, 72, "Untitled-1")
## var view = PhotoView(zoom: 1, rulers: true)
## var stroke: Stroke
## app "Paint", 1000, 700:
##   let ev = photoView(d, view)
##   if ev.pressed:
##     d.beginStep("Paintbrush")
##     stroke = d.beginStroke(PaintOpts(tool: tkBrush, color: 0xFF000000'u32, opacity: 100),
##                            BrushTip(diameter: 9, hardness: 100), ev.x, ev.y)
##   elif ev.down: stroke.strokeTo(ev.x, ev.y)
##   elif ev.released:
##     stroke.endStroke()
##     d.endStep()
## ```

import std/[math, strutils, tables, algorithm]
import uirelays/input
import core, gfx, widgets, photo, photopaint, pixelicons, nerdicons, parallel, iccprofile, photoinks, adobefiles

template th: untyped = ui.theme

# ---- the canvas -----------------------------------------------------------------------------------

type
  PhotoView* = object
    ## How a document is shown in a window: its zoom and where it is scrolled.
    zoom*: int               ## 2: 2:1 (bigger), 1: 1:1, -2: 1:2 (smaller)...
    offX*, offY*: int        ## the scroll, in screen pixels of the zoomed image
    rulers*: bool            ## the rulers shown (top and left)
    showGuides*: bool        ## the guides drawn (and dragged from the rulers)
    lockGuides*: bool        ## ... not moved
    showGrid*: bool          ## the grid drawn
    gridStep*: float         ## the grid's lines, so many image pixels apart (0: 64)
    gridSub*: int            ## ... each divided in so many (lighter lines)
    guideColor*: Color       ## the guides' color
    guideDrag: tuple[on, vertical: bool; idx: int]
    allowGuideGrab*: bool    ## a press on a guide drags it (the Move tool)
    view*: Rect              ## where the image area was last drawn
    keepRect*: Rect          ## all of it (rulers, scroll bars): kept left to right in a mirrored
                             ## (Arabic) interface -- draw over the image in `beginKeepSides` of it
    statusRect*: Rect        ## (with `statusW`) the room left of the scroll bar under the image for
                             ## its status (the zoom, the document's sizes), as today's Photoshop
    fitWanted*: bool         ## fit the image in the window at the next frame
    hideEdges*: bool         ## the selection's marching ants not drawn
    angle*: float            ## the view turned so many degrees clockwise (Rotate View, R); the
                             ## image itself unchanged
    buf: Bitmap
    big: Bitmap              # (turned: the view drawn straight, bigger, then turned into `buf`)
    forced: bool             # (... `origin` given while it is drawn)
    forcedOrigin: (int, int)
    key: string
    shownVer: int            # the document's version the view shows
    shownOff: (int, int)     # (and its origin then)
    gpuKey: uint64           # (with the GPU) its textures: the image, and its smaller copies
    gpuDoc: pointer
    gpuVers: array[8, int]   # ... the version each has (0: none)
    antsVer: int
    hEdges, vEdges: seq[(int32, int32, int32)]   # (line, from, to)
    antsPhase: int
    antsAt: int
    lastMx, lastMy: int
    started: bool

  PhotoEvent* = object
    ## What the mouse did on the canvas this frame (image coordinates).
    over*: bool              ## over the image's window area
    x*, y*: float            ## where (image pixels; may be outside the image)
    pressed*, down*, released*: bool
      ## the button went down this frame; is held; went up this frame
    clicks*: int             ## 1 a click, 2 a double click... (with `pressed`)
    shift*, ctrl*, alt*: bool  ## the keys held
    moved*: bool             ## the mouse moved this frame
    right*: bool             ## a right click (or a long press)
    guideMoved*: bool        ## a guide made, moved or taken away (the press was its)

const zoomSteps* = [-16, -12, -8, -6, -5, -4, -3, -2, 1, 2, 3, 4, 5, 6, 8, 12, 16]
  ## The zooms of Zoom In and Zoom Out, as `PhotoView.zoom` (-2: 1:2, 2: 2:1).

# ---- how every view looks (Preferences) ------------------------------------------------------------

type
  CheckerSize* = enum
    ## The checkerboard under what is transparent.
    ckNone = "None", ckSmall = "Small", ckMedium = "Medium", ckLarge = "Large"
  CheckerColors* = enum
    ## The checkerboard's colors (`checkerPair`).
    ccLight = "Light", ccMedium = "Medium", ccDark = "Dark", ccRed = "Red", ccOrange = "Orange",
    ccGreen = "Green", ccBlue = "Blue", ccPurple = "Purple"
  RulerUnit* = enum
    ## The rulers' (and the grid's) unit.
    ruPixels = "Pixels", ruInches = "Inches", ruCentimeters = "Centimeters",
    ruMillimeters = "Millimeters", ruPoints = "Points", ruPicas = "Picas", ruPercent = "Percent"
  LineStyle* = enum
    ## How the grid's or the guides' lines are drawn.
    lsLines = "Lines", lsDashed = "Dashed Lines", lsDots = "Dots"
  ViewPrefs* = object
    ## How every `photoView` looks and what its wheel does.
    checkerSize*: CheckerSize      ## the checkerboard's squares under what is transparent
    checkerColors*: CheckerColors  ## ... and their colors
    rulerUnit*: RulerUnit          ## the rulers' unit
    gridEvery*: float          ## a grid line every so many `gridUnit`s
    gridUnit*: RulerUnit       ## the unit of `gridEvery`
    gridSub*: int              ## ... each cut in so many (lighter lines)
    gridColor*: Color          ## the grid's color
    gridStyle*: LineStyle      ## ... and its lines
    guideColor*: Color         ## the guides' color
    guideStyle*: LineStyle     ## ... and their lines
    wheelZooms*: bool          ## the wheel zooms (Ctrl or Alt + the wheel: scrolls)

var gamutColor* = 0xFF808080'u32
  ## The color out-of-gamut pixels are shown in (View › Gamut Warning).

var viewPrefs* = ViewPrefs(checkerSize: ckMedium, checkerColors: ccLight, rulerUnit: ruPixels,
                           gridEvery: 64, gridUnit: ruPixels, gridSub: 4,
                           gridColor: color(128, 128, 128), gridStyle: lsLines,
                           guideColor: color(0, 200, 255), guideStyle: lsLines)
  ## The Preferences of every view (Transparency, Units & Rulers, Guides & Grid).

proc checkerPair*(c: CheckerColors): (uint32, uint32) =
  ## The checkerboard's two colors.
  case c
  of ccLight: (0xFFFFFFFF'u32, 0xFFCCCCCC'u32)
  of ccMedium: (0xFFCCCCCC'u32, 0xFF999999'u32)
  of ccDark: (0xFF666666'u32, 0xFF333333'u32)
  of ccRed: (0xFFFFFFFF'u32, 0xFFFFCCCC'u32)
  of ccOrange: (0xFFFFFFFF'u32, 0xFFFFE5CC'u32)
  of ccGreen: (0xFFFFFFFF'u32, 0xFFCCFFCC'u32)
  of ccBlue: (0xFFFFFFFF'u32, 0xFFCCE5FF'u32)
  of ccPurple: (0xFFFFFFFF'u32, 0xFFE5CCFF'u32)

proc checkerShift*(c: CheckerSize): int =
  ## Its squares: 1 shl this device pixels (before the screen's scale).
  case c
  of ckNone: 0
  of ckSmall: 2
  of ckMedium: 3
  of ckLarge: 4

proc unitPixels*(u: RulerUnit; dpi: float; side: int): float =
  ## Image pixels in one `u` (at `dpi`; percent: of `side` pixels).
  let dpi = if dpi > 0: dpi else: 72.0
  case u
  of ruPixels: 1.0
  of ruInches: dpi
  of ruCentimeters: dpi / 2.54
  of ruMillimeters: dpi / 25.4
  of ruPoints: dpi / 72
  of ruPicas: dpi / 6
  of ruPercent: max(1, side).float / 100

proc unitAbbrev*(u: RulerUnit): string =
  ## The unit's short name: "px", "in", "cm", "mm", "pt", "pc", "%".
  case u
  of ruPixels: "px"
  of ruInches: "in"
  of ruCentimeters: "cm"
  of ruMillimeters: "mm"
  of ruPoints: "pt"
  of ruPicas: "pc"
  of ruPercent: "%"

proc inUnits*(px: float; u: RulerUnit; dpi: float; side: int): string =
  ## `px` image pixels as a number of `u`s, with as many decimals as the
  ## unit needs ("12.70 cm", "300 px").
  let v = px / unitPixels(u, dpi, side)
  let dec = case u
            of ruPixels, ruPercent, ruPoints: (if abs(v - round(v)) < 1e-6 or u == ruPixels: 0 else: 1)
            of ruMillimeters, ruPicas: 1
            else: 2
  (if dec == 0: $int(round(v)) else: formatFloat(v, ffDecimal, dec)) & " " & unitAbbrev(u)

proc gridStepOf*(d: Doc): float =
  ## The Preferences' grid line spacing in this document's pixels.
  max(1.0, viewPrefs.gridEvery * unitPixels(viewPrefs.gridUnit, d.dpi, d.w))

proc gridCell*(v: PhotoView; d: Doc): float =
  ## The grid's finest spacing in the view (what snaps to it), image pixels.
  let step = if v.gridStep > 0: v.gridStep else: gridStepOf(d)
  step / max(1, if v.gridStep > 0: v.gridSub else: viewPrefs.gridSub).float

proc initPhotoView*(): PhotoView =
  ## A new view: the image fitted, guides shown.
  PhotoView(zoom: 1, fitWanted: true, showGuides: true, gridStep: 0, gridSub: 4,
            guideColor: color(0, 200, 255))

proc scaleOf*(v: PhotoView): float =
  ## Screen pixels per image pixel.
  if v.zoom >= 1: v.zoom.float elif v.zoom <= -1: 1 / (-v.zoom).float else: 1.0

proc zoomText*(z: int): string =
  ## "1:1", "2:1", "1:4".
  if z >= 1: $z & ":1" else: "1:" & $(-z)

proc zoomPercent*(z: int): string =
  ## The zoom `z` in percent: "200%", "33.3%".
  if z >= 1: $(z * 100) & "%"
  else: formatFloat(100 / (-z).float, ffDecimal, 1).replace(".0", "") & "%"

proc devSize(v: PhotoView; d: Doc): (int, int) =
  ## The zoomed image in device pixels.
  if v.zoom >= 1: (d.w * v.zoom, d.h * v.zoom)
  else: ((d.w + (-v.zoom) - 1) div (-v.zoom), (d.h + (-v.zoom) - 1) div (-v.zoom))

proc origin(v: PhotoView; d: Doc): (int, int) =
  ## Where the image's top left is, in device pixels from the view's.
  if v.forced: return v.forcedOrigin
  let s = pxScale
  let (iw, ih) = v.devSize(d)
  let vw = v.view.w * s
  let vh = v.view.h * s
  let ox = if iw <= vw: (vw - iw) div 2 else: -v.offX
  let oy = if ih <= vh: (vh - ih) div 2 else: -v.offY
  (ox, oy)

proc turned(v: PhotoView; x, y: float; back: bool): (float, float) =
  ## (a screen point turned round the view's middle by the view's angle;
  ## `back`: the other way)
  let cx = v.view.x.float + v.view.w.float / 2
  let cy = v.view.y.float + v.view.h.float / 2
  let a = degToRad(if back: -v.angle else: v.angle)
  let dx = x - cx
  let dy = y - cy
  (cx + dx * cos(a) - dy * sin(a), cy + dx * sin(a) + dy * cos(a))

proc toImageF*(v: PhotoView; d: Doc; sx, sy: float): (float, float) =
  ## A screen point (logical pixels, between them) in image pixels.
  let s = pxScale.float
  let (ox, oy) = v.origin(d)
  var (x, y) = (sx, sy)
  if v.angle != 0: (x, y) = v.turned(x, y, true)
  let dx = (x - v.view.x.float) * s - ox.float
  let dy = (y - v.view.y.float) * s - oy.float
  (dx / v.scaleOf, dy / v.scaleOf)

proc toImage*(v: PhotoView; d: Doc; sx, sy: int): (float, float) =
  ## A screen point (logical pixels) in image pixels.
  if v.angle != 0: return v.toImageF(d, sx.float, sy.float)
  let s = pxScale
  let (ox, oy) = v.origin(d)
  let dx = (sx - v.view.x) * s - ox
  let dy = (sy - v.view.y) * s - oy
  (dx.float / v.scaleOf, dy.float / v.scaleOf)

proc toScreenF*(v: PhotoView; d: Doc; x, y: float): (float, float) =
  ## An image point on the screen (logical pixels, between them).
  let s = pxScale.float
  let (ox, oy) = v.origin(d)
  let px = v.view.x.float + (x * v.scaleOf + ox.float) / s
  let py = v.view.y.float + (y * v.scaleOf + oy.float) / s
  if v.angle != 0: v.turned(px, py, false) else: (px, py)

proc toScreen*(v: PhotoView; d: Doc; x, y: float): (int, int) =
  ## An image point on the screen (logical pixels).
  if v.angle != 0:
    let (fx, fy) = v.toScreenF(d, x, y)
    return (int(floor(fx)), int(floor(fy)))
  let s = pxScale
  let (ox, oy) = v.origin(d)
  (v.view.x + int(floor((x * v.scaleOf + ox.float) / s.float)),
   v.view.y + int(floor((y * v.scaleOf + oy.float) / s.float)))

proc clampScroll(v: var PhotoView; d: Doc) =
  let s = pxScale
  let (iw, ih) = v.devSize(d)
  v.offX = clamp(v.offX, 0, max(0, iw - v.view.w * s))
  v.offY = clamp(v.offY, 0, max(0, ih - v.view.h * s))

proc setZoom*(v: var PhotoView; d: Doc; z: int; ax = NaN; ay = NaN) =
  ## Zooms to `z`, keeping image point (`ax`, `ay`) where it is (the middle
  ## of the view when not given).
  let s = pxScale
  var cx = ax
  var cy = ay
  var sx, sy: int
  if cx != cx:
    (cx, cy) = v.toImage(d, v.view.x + v.view.w div 2, v.view.y + v.view.h div 2)
    sx = v.view.w * s div 2
    sy = v.view.h * s div 2
  else:
    let (px, py) = v.toScreen(d, cx, cy)
    sx = (px - v.view.x) * s
    sy = (py - v.view.y) * s
  v.zoom = clamp(z, -16, 16)
  if v.zoom == 0 or v.zoom == -1: v.zoom = 1
  v.offX = int(cx * v.scaleOf) - sx
  v.offY = int(cy * v.scaleOf) - sy
  v.clampScroll(d)
  v.key = ""

proc zoomIn*(v: var PhotoView; d: Doc; ax = NaN; ay = NaN) =
  ## Zooms in one step (see `setZoom`).
  for z in zoomSteps:
    if (if z >= 1: z.float else: 1 / (-z).float) > v.scaleOf + 0.0001:
      v.setZoom(d, z, ax, ay)
      return

proc zoomOut*(v: var PhotoView; d: Doc; ax = NaN; ay = NaN) =
  ## Zooms out one step (see `setZoom`).
  for i in countdown(zoomSteps.high, 0):
    let z = zoomSteps[i]
    if (if z >= 1: z.float else: 1 / (-z).float) < v.scaleOf - 0.0001:
      v.setZoom(d, z, ax, ay)
      return

proc fitZoom*(d: Doc; w, h: int): int =
  ## The biggest whole ratio at which a `w` x `h` (device pixels) view
  ## shows all of the image.
  result = -16
  for z in zoomSteps:
    let (iw, ih) = if z >= 1: (d.w * z, d.h * z) else: (d.w div (-z), d.h div (-z))
    if iw <= w and ih <= h: result = z

proc fit*(v: var PhotoView; d: Doc) =
  ## Zoom to Screen: all of the image in the view, as big as it goes.
  v.zoom = fitZoom(d, v.view.w * pxScale, v.view.h * pxScale)
  v.offX = 0
  v.offY = 0
  v.key = ""

proc centerOn*(v: var PhotoView; d: Doc; x, y: float) =
  ## Scrolls so image point `x`, `y` is in the middle of the view (the
  ## Navigator).
  let s = pxScale
  v.offX = int(x * v.scaleOf) - v.view.w * s div 2
  v.offY = int(y * v.scaleOf) - v.view.h * s div 2
  v.clampScroll(d)


proc zoomToRect*(v: var PhotoView; d: Doc; x0, y0, x1, y1: float) =
  ## The Zoom tool's box: the biggest ratio at which image box `x0`, `y0`
  ## - `x1`, `y1` fits in the view, in its middle.
  let bw = max(1.0, abs(x1 - x0))
  let bh = max(1.0, abs(y1 - y0))
  let w = (v.view.w * pxScale).float
  let h = (v.view.h * pxScale).float
  var best = zoomSteps[0]
  for z in zoomSteps:
    let k = if z >= 1: z.float else: 1 / (-z).float
    if bw * k <= w and bh * k <= h: best = z
  v.zoom = best
  v.centerOn(d, (x0 + x1) / 2, (y0 + y1) / 2)

proc visibleRect*(v: PhotoView; d: Doc): (float, float, float, float) =
  ## The part of the image in the view: x, y, w, h in image pixels.
  let (x0, y0) = v.toImage(d, v.view.x, v.view.y)
  let (x1, y1) = v.toImage(d, v.view.x + v.view.w, v.view.y + v.view.h)
  let ax = max(0.0, x0)
  let ay = max(0.0, y0)
  (ax, ay, min(d.w.float, x1) - ax, min(d.h.float, y1) - ay)

proc scrollBy*(v: var PhotoView; d: Doc; dx, dy: int) =
  ## Scrolls by screen (logical) pixels.
  v.offX += dx * pxScale
  v.offY += dy * pxScale
  v.clampScroll(d)

proc computeEdges(v: var PhotoView; d: Doc) =
  ## The selection's edges (where it changes between in and out): the rows
  ## on all the cores, skipping eight pixels at a time where nothing
  ## changes (a big photo's selection outlined at once).
  v.hEdges.setLen(0)
  v.vEdges.setLen(0)
  if not d.hasSelection: return
  let w = d.w
  let h = d.h
  let sp = cast[ptr UncheckedArray[uint8]](addr d.sel[0])
  # across: row y against the row above (y = h: the last row against nothing)
  var hRuns = newSeq[seq[(int32, int32)]](h + 1)
  # down: where row y changes from one column to the next (x = w: the edge)
  var vCols = newSeq[seq[int32]](h)
  let hp = cast[ptr UncheckedArray[seq[(int32, int32)]]](addr hRuns[0])
  let vp = cast[ptr UncheckedArray[seq[int32]]](addr vCols[0])
  template inRow(y, x: int): bool = (y >= 0 and y < h and sp[y * w + x] >= 128)
  template word8(i: int): uint64 =
    # (eight bytes from any offset: copied, as a uint64 pointer there
    # would be unaligned -- undefined behaviour in C)
    var v: uint64
    copyMem(addr v, addr sp[i], 8)
    v
  proc work(a, b: int) {.closure.} =
    for y in a ..< b:
      var runs: seq[(int32, int32)]
      var x = 0
      while x < w:
        if y > 0 and y < h and x + 8 <= w and
           word8(y * w + x) == word8((y - 1) * w + x):
          x += 8
          continue
        if inRow(y, x) != inRow(y - 1, x):
          let a0 = x
          while x < w and inRow(y, x) != inRow(y - 1, x): inc x
          runs.add (int32(a0), int32(x))
        else: inc x
      hp[y] = runs
      if y < h:
        var cols: seq[int32]
        var prev = false
        x = 0
        let row = y * w
        while x < w:
          if x + 8 <= w:
            let word = word8(row + x)
            if (word == 0 and not prev) or (word == 0xFFFFFFFFFFFFFFFF'u64 and prev):
              x += 8
              continue
          let now = sp[row + x] >= 128
          if now != prev:
            cols.add int32(x)
            prev = now
          inc x
        if prev: cols.add int32(w)
        vp[y] = cols
  parallelFor(h + 1, work, grain = 32, keepAlive = false)
  for y in 0 .. h:
    for (a0, b0) in hRuns[y]: v.hEdges.add (int32(y), a0, b0)
  # (the columns' changes, row after row, joined into runs down)
  var open: seq[(int32, int32)]           # (column, the row it began)
  var next: seq[(int32, int32)]
  for y in 0 .. h:
    let cur = if y < h: vCols[y] else: @[]
    next.setLen(0)
    var i = 0
    var j = 0
    while i < open.len or j < cur.len:
      if j >= cur.len or (i < open.len and open[i][0] < cur[j]):
        v.vEdges.add (open[i][0], open[i][1], int32(y))
        inc i
      elif i >= open.len or cur[j] < open[i][0]:
        next.add (cur[j], int32(y))
        inc j
      else:
        next.add open[i]
        inc i
        inc j
    swap(open, next)

var
  quickMaskColor* = 0xFFFF0000'u32  ## the Quick Mask's color over the image
  quickMaskOpacity* = 50            ## ... and its opacity (%)
  quickMaskOnSelected* = false      ## the color over the selected areas (else the masked)

{.push boundChecks: off, overflowChecks: off.}

var iccShown: tuple[key: string; table: seq[uint32]]

proc iccDisplayPtr(icc: string): ptr UncheckedArray[uint32] =
  ## The table that shows colors of the profile `icc` as they look (made
  ## once for each profile; nil when it cannot be used).
  if iccShown.key != icc:
    iccShown = (icc, displayTable(icc))
  if iccShown.table.len == 0: nil else: cast[ptr UncheckedArray[uint32]](addr iccShown.table[0])

proc renderView(v: var PhotoView; d: Doc; bw, bh: int; bg: uint32; part = rect(0, 0, -1, -1)) =
  ## The view's pixels: the image at the zoom (zoomed out, from the
  ## smaller copy that fits -- smooth, and quick for a big photo), the
  ## checkerboard under what is transparent, the channel shown, the Quick
  ## Mask. On all the cores. Only `part` (the view's device pixels) when
  ## given.
  if v.buf == nil or v.buf.w != bw or v.buf.h != bh:
    v.buf = newBitmap(bw, bh)
    v.buf.opaque = true
  let part = if part.w < 0: rect(0, 0, bw, bh) else: intersect(part, rect(0, 0, bw, bh))
  if part.w <= 0 or part.h <= 0: return
  let px0 = part.x
  let px1 = part.x + part.w
  let py0 = part.y
  let liveOn = d.live.len > 0
  if not liveOn:
    d.updateComposite()
    if d.compPtr == nil: return
  let (ox, oy) = v.origin(d)
  let z = v.zoom
  # zoomed out 1:n: the copy at 1/2^level of the size, read every n/2^level
  var level = 0
  if z <= -2:
    while (1 shl (level + 1)) <= -z: inc level
  let (src, lw, lh) = if liveOn: (nil, 1, 1) else: d.mipLevel(level)
  var livePx: seq[uint32]
  if liveOn:
    # (something being moved, turned, adjusted: the view's points made
    # straight from the layers -- the middle of what each screen pixel
    # covers -- nothing done to the whole image)
    let half = if z <= -2: (-z) div 2 else: 0
    var lxs = newSeq[int32](part.w)
    var lys = newSeq[int32](part.h)
    for i in 0 ..< part.w:
      let dx = px0 + i - ox
      let ix = if dx < 0: -1 elif z >= 1: dx div z else: dx * (-z) + half
      lxs[i] = if dx < 0 or ix >= d.w: -1'i32 else: int32(min(ix, d.w - 1))
    for i in 0 ..< part.h:
      let dy = py0 + i - oy
      let iy = if dy < 0: -1 elif z >= 1: dy div z else: dy * (-z) + half
      lys[i] = if dy < 0 or iy >= d.h: -1'i32 else: int32(min(iy, d.h - 1))
    d.compositeSampled(lxs, lys, livePx)
  let lpw = part.w
  let lpp = if livePx.len > 0: cast[ptr UncheckedArray[uint32]](addr livePx[0]) else: nil
  # the image column of each screen column (in the copy, and in the image)
  var xs = newSeq[int32](bw)
  var xs0 = newSeq[int32](bw)
  for bx in 0 ..< bw:
    let dx = bx - ox
    let ix0 = if dx < 0: -1 elif z >= 1: dx div z else: dx * (-z)
    if dx < 0 or ix0 >= d.w:
      xs[bx] = -1
      xs0[bx] = -1
    else:
      xs0[bx] = int32(ix0)
      xs[bx] = int32(min(lw - 1, ix0 shr level))
  let quick = d.quickMask and d.maskLayer != nil and d.maskLayer.px.len == d.w * d.h
  let mask = if quick: cast[ptr UncheckedArray[uint32]](addr d.maskLayer.px[0]) else: nil
  var ch = d.viewChannel
  var mode = d.mode
  if mode == cmMultichannel:
    # (an ink of a Multichannel image: the channel of the mode it came from)
    if ch >= 0 and ch < d.spots.len: ch = d.spots[ch].ch
    mode = d.spotBase
  # (how the colors are shown: as they print in CMYK or with Proof Colors,
  # in the inks of a Duotone, what cannot print in gray)
  let proofT = if ch < 0 and (mode == cmCMYK or d.proof or d.gamutWarning): proofTablePtr() else: nil
  # (a picture in another color profile: shown as it looks)
  let iccT = if ch < 0 and proofT == nil and d.icc.len > 0 and mode in {cmRGB, cmIndexed, cmGray}: iccDisplayPtr(d.icc)
             else: nil
  let reproof = mode == cmCMYK or d.proof
  let warn = d.gamutWarning and ch < 0
  var duo: seq[uint32]
  if ch < 0 and mode == cmDuotone: duo = @(duotoneTable(d.duotone))
  let duoP = if duo.len == 256: cast[ptr UncheckedArray[uint32]](addr duo[0]) else: nil
  let px = cast[ptr UncheckedArray[uint32]](addr v.buf.px[0])
  let xp = cast[ptr UncheckedArray[int32]](addr xs[0])
  let xp0 = cast[ptr UncheckedArray[int32]](addr xs0[0])
  let dw = d.w
  let dh = d.h
  let qColor = quickMaskColor or 0xFF000000'u32
  let qOpacity = quickMaskOpacity
  let qSel = quickMaskOnSelected
  let (ck0, ck1) = checkerPair(viewPrefs.checkerColors)
  let cks = if viewPrefs.checkerSize == ckNone: 0
            else: checkerShift(viewPrefs.checkerSize) + (if pxScale >= 4: 2 elif pxScale >= 2: 1 else: 0)
  drawingRows(part.h, ry):
    let by = py0 + ry
    let dy = by - oy
    let iy0 = if dy < 0: -1 elif z >= 1: dy div z else: dy * (-z)
    let row = by * bw
    if iy0 < 0 or iy0 >= dh:
      for bx in px0 ..< px1: px[row + bx] = bg
    else:
      let lrow = min(lh - 1, iy0 shr level) * lw
      let irow0 = iy0 * dw
      for bx in px0 ..< px1:
        let ix = xp[bx]
        if ix < 0:
          px[row + bx] = bg
          continue
        var p = if lpp != nil: lpp[ry * lpw + bx - px0] else: src[lrow + int(ix)]
        if ch >= 0 and ch <= 3:
          let v2 = if mode in {cmCMYK, cmLab}: uint32(channelGray(mode, p, ch))
                   else: (p shr (16 - 8 * min(ch, 2))) and 255
          p = (p and 0xFF000000'u32) or (v2 * 0x010101'u32)
        elif duoP != nil:
          p = (duoP[(p shr 16) and 255] and 0xFFFFFF'u32) or (p and 0xFF000000'u32)
        elif proofT != nil:
          let q = lookupProof(proofT, p)
          if warn and max(abs(int((p shr 16) and 255) - int((q shr 16) and 255)),
                          max(abs(int((p shr 8) and 255) - int((q shr 8) and 255)),
                              abs(int(p and 255) - int(q and 255)))) > 14:
            p = (p and 0xFF000000'u32) or (gamutColor and 0xFFFFFF'u32)
          elif reproof: p = q
        elif iccT != nil:
          p = lookupProof(iccT, p)
        let a = p shr 24
        var o: uint32
        if a == 255: o = p
        else:
          let chk = if cks == 0: ck0
                    elif ((((bx - ox) shr cks) + ((by - oy) shr cks)) and 1) == 0: ck0
                    else: ck1
          o = if a == 0: chk else: blendPx(chk, p, 255, bmNormal)
        if mask != nil:
          # the Quick Mask: red where not selected (or where selected)
          var m = 255 - lumaOf(mask[irow0 + int(xp0[bx])])
          if qSel: m = 255 - m
          if m > 0: o = blendPx(o, qColor, m * qOpacity div 100, bmNormal)
        px[row + bx] = o or 0xFF000000'u32

proc viewRect(v: PhotoView; d: Doc; r: Rect; bw, bh: int): Rect =
  ## Where image rectangle `r` is in the view (device pixels), a pixel
  ## wider all round; zoomed out, whole cells of the smaller copy it is
  ## drawn from.
  let (ox, oy) = v.origin(d)
  let z = v.zoom
  var x0, y0, x1, y1: int
  if z >= 1:
    x0 = ox + r.x * z; x1 = ox + (r.x + r.w) * z
    y0 = oy + r.y * z; y1 = oy + (r.y + r.h) * z
  else:
    let n = -z
    var level = 0
    while (1 shl (level + 1)) <= n: inc level
    let a = (r.x shr level) shl level
    let b = (r.y shr level) shl level
    let c = (((r.x + r.w - 1) shr level) + 1) shl level
    let e = (((r.y + r.h - 1) shr level) + 1) shl level
    x0 = ox + a div n; x1 = ox + (c + n - 1) div n
    y0 = oy + b div n; y1 = oy + (e + n - 1) div n
  intersect(rect(x0 - 1, y0 - 1, x1 - x0 + 2, y1 - y0 + 2), rect(0, 0, bw, bh))

proc shiftView(v: var PhotoView; dx, dy: int) =
  ## The view's pixels moved by `dx`, `dy` (what scrolled stays drawn).
  let bw = v.buf.w
  let bh = v.buf.h
  let p = cast[ptr UncheckedArray[uint32]](addr v.buf.px[0])
  let w = bw - abs(dx)
  if w <= 0 or abs(dy) >= bh: return
  let sx = max(0, -dx)
  let tx = max(0, dx)
  if dy > 0:
    for y in countdown(bh - 1, dy): moveMem(addr p[y * bw + tx], addr p[(y - dy) * bw + sx], w * 4)
  else:
    for y in 0 ..< bh + dy: moveMem(addr p[y * bw + tx], addr p[(y - dy) * bw + sx], w * 4)

var nextGpuKey = 1'u64

proc renderTurned(v: var PhotoView; d: Doc; bw, bh: int; bg: uint32) =
  ## (the view turned: drawn straight into a square big enough for any
  ## angle, then turned into the view's pixels, read between them)
  let big = int(ceil(sqrt(float(bw * bw + bh * bh)))) + 2
  let (ox, oy) = v.origin(d)
  let keep = v.buf
  v.buf = v.big
  v.forced = true
  v.forcedOrigin = (ox + (big - bw) div 2, oy + (big - bh) div 2)
  try: v.renderView(d, big, big, bg)
  finally:
    v.forced = false
    v.big = v.buf
    v.buf = keep
  if v.buf == nil or v.buf.w != bw or v.buf.h != bh:
    v.buf = newBitmap(bw, bh)
    v.buf.opaque = true
  let sp = cast[ptr UncheckedArray[uint32]](addr v.big.px[0])
  let dp = cast[ptr UncheckedArray[uint32]](addr v.buf.px[0])
  let a = degToRad(v.angle)
  let ca = cos(a)
  let sa = sin(a)
  let hb = big.float / 2
  let fill = bg or 0xFF000000'u32
  parallelRows(bh, by):
    let dy = by.float + 0.5 - bh.float / 2
    for bx in 0 ..< bw:
      let dx = bx.float + 0.5 - bw.float / 2
      let ux = dx * ca + dy * sa + hb - 0.5
      let uy = -dx * sa + dy * ca + hb - 0.5
      let x0 = int(floor(ux))
      let y0 = int(floor(uy))
      if x0 < 0 or y0 < 0 or x0 + 1 >= big or y0 + 1 >= big:
        dp[by * bw + bx] = fill
        continue
      let tx = int((ux - x0.float) * 256)
      let ty = int((uy - y0.float) * 256)
      let i = y0 * big + x0
      let p00 = sp[i]
      let p10 = sp[i + 1]
      let p01 = sp[i + big]
      let p11 = sp[i + big + 1]
      var o = 0xFF000000'u32
      for sh in [16, 8, 0]:
        template c(p: uint32): int = int((p shr sh) and 255)
        let top = c(p00) * (256 - tx) + c(p10) * tx
        let bot = c(p01) * (256 - tx) + c(p11) * tx
        o = o or (uint32((top * (256 - ty) + bot * ty + 32768) shr 16) shl sh)
      dp[by * bw + bx] = o
  v.buf.changed()

proc gpuView(v: var PhotoView; d: Doc; area: Rect; bg: uint32): bool =
  ## (with the GPU) The image as a texture the GPU zooms and moves: nothing
  ## drawn again on the processor when the view scrolls or zooms, only what
  ## was painted on sent. False when the view needs the processor (a
  ## channel or the inks shown, a profile converted, the Quick Mask).
  if not drawnWithGpu() or d.live.len > 0: return false
  let quick = d.quickMask and d.maskLayer != nil
  if d.viewChannel >= 0 or d.mode notin {cmRGB, cmGray, cmIndexed} or d.proof or d.gamutWarning or
     quick or (d.icc.len > 0 and iccDisplayPtr(d.icc) != nil):
    return false
  if v.gpuKey == 0:
    v.gpuKey = nextGpuKey shl 8
    inc nextGpuKey
  if v.gpuDoc != cast[pointer](d):
    v.gpuDoc = cast[pointer](d)
    for x in v.gpuVers.mitems: x = 0
  let z = v.zoom
  var level = 0
  if z <= -2:
    while (1 shl (level + 1)) <= -z and level < 7: inc level
  let (src, lw, lh) = d.mipLevel(level)
  if src == nil: return false
  let key = v.gpuKey or uint64(level)
  # (all of it the first time; then the part painted on, in this copy's pixels)
  let was = v.gpuVers[level]
  if was == 0 or was > d.ver or not gpuHasImage(key):
    gpuImage(key, lw, lh, src, rect(0, 0, 0, 0), whole = true)
  elif was != d.ver:
    let c = d.changedSince(was)
    if c.w > 0 and c.h > 0:
      let x0 = c.x shr level
      let y0 = c.y shr level
      gpuImage(key, lw, lh, src, rect(x0, y0, ((c.x + c.w - 1) shr level) - x0 + 1,
                                      ((c.y + c.h - 1) shr level) - y0 + 1))
  v.gpuVers[level] = max(1, d.ver)
  let s = pxScale
  let (ox, oy) = v.origin(d)
  let (iw, ih) = v.devSize(d)
  fill(area, color(uint8(bg shr 16), uint8(bg shr 8), uint8(bg)))
  let img = rect(area.x * s + ox, area.y * s + oy, iw, ih)
  let (ck0, ck1) = checkerPair(viewPrefs.checkerColors)
  template col(c: uint32): Color = color(uint8(c shr 16), uint8(c shr 8), uint8(c))
  pushClip(area)
  if viewPrefs.checkerSize == ckNone:
    checkerAt(img, 1 shl 20, img.x, img.y, col(ck0), col(ck0))
  else:
    let cks = checkerShift(viewPrefs.checkerSize) + (if pxScale >= 4: 2 elif pxScale >= 2: 1 else: 0)
    checkerAt(img, 1 shl cks, img.x, img.y, col(ck0), col(ck1))
  drawGpuImage(key, img, d.ver, smooth = lw != iw)
  popClip()
  true

proc antsSegments(v: PhotoView; d: Doc; bw, bh: int): seq[array[4, int32]] =
  ## The selection's outline in the view (device pixels); moved with what
  ## is being moved (`liveSel`).
  var (ox, oy) = v.origin(d)
  let k = v.scaleOf
  if d.live.len > 0 or d.liveSel.dx != 0 or d.liveSel.dy != 0:
    ox += int(floor(d.liveSel.dx.float * k))
    oy += int(floor(d.liveSel.dy.float * k))
  for (yy, a, b) in v.hEdges:
    let sy = min(bh - 1, oy + int(floor(yy.float * k)))
    if sy < 0 or sy >= bh: continue
    let x0 = max(0, ox + int(floor(a.float * k)))
    let x1 = min(bw, ox + int(floor(b.float * k)))
    if x1 > x0: result.add [int32(x0), int32(sy), int32(x1), int32(sy + 1)]
  for (xx, a, b) in v.vEdges:
    let sx = min(bw - 1, ox + int(floor(xx.float * k)))
    if sx < 0 or sx >= bw: continue
    let y0 = max(0, oy + int(floor(a.float * k)))
    let y1 = min(bh, oy + int(floor(b.float * k)))
    if y1 > y0: result.add [int32(sx), int32(y0), int32(sx + 1), int32(y1)]

{.pop.}

proc rulerTicks(len, origin: int; scale: float; unit = 1.0): seq[(int, int, string)] =
  ## Ticks along a ruler (screen offset, size 0..2, label): `scale` screen
  ## pixels per image pixel, `unit` image pixels per the ruler's unit.
  let su = scale * unit                       # (screen pixels per unit)
  var step = 1.0
  for c in [0.01, 0.02, 0.05, 0.1, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 25.0, 50.0, 100.0, 200.0,
            250.0, 500.0, 1000.0, 2000.0, 5000.0, 10000.0, 20000.0, 50000.0]:
    step = c
    if c * su >= dp(48).float: break
  let parts = if step in [0.25, 25.0, 250.0]: 5 elif abs(step / pow(10, floor(log10(step))) - 2) < 1e-9: 4 else: 5
  let small = step / parts.float
  let dec = max(0, int(ceil(-log10(step) - 1e-9)))
  template lab(v: float): string = (if dec == 0: $int(round(v)) else: formatFloat(v, ffDecimal, dec))
  var i = int(floor(-origin.float / su / small))
  while true:
    let v = i.float * small
    let at = int(round(v * su)) + origin
    if at > len: break
    if at >= 0:
      if i mod parts == 0: result.add (at, 2, lab(v))
      elif parts mod 2 == 0 and i mod (parts div 2) == 0: result.add (at, 1, "")
      else: result.add (at, 0, "")
    inc i

proc photoView*(d: Doc; v: var PhotoView; height = -1; key = ""; drawAntsNow = true;
                statusW = 0): PhotoEvent =
  ## The document in the space left (scroll bars, rulers when `v.rulers`).
  ## Reports the mouse in image pixels; the wheel scrolls (Shift: across,
  ## Ctrl: zoom). `statusW` > 0: so much room at the left of the bottom
  ## scroll bar for a status (`v.statusRect`: draw it after), the strip as
  ## tall as a box.
  let r = place(0, if height < 0: remainingH() else: height, fill = true)
  v.keepRect = r
  beginKeepSides(r)              # (the image as it is, in a right-to-left interface too)
  defer: endKeepSides()
  let id = idOf(v, "photoview" & key)
  let rw = if v.rulers: dp(16) else: 0
  let sb = SbW
  let stw = if statusW > 0: clamp(statusW, 0, max(0, r.w - rw - sb - dp(40))) else: 0
  let stH = if stw > 0: max(sb, EditH + dp(2)) else: sb
  var area = rect(r.x + rw, r.y + rw, r.w - rw - sb, r.h - rw - stH)
  if area.w < 8 or area.h < 8: return
  let firstFrame = v.view.w == 0
  v.view = area
  if v.fitWanted or firstFrame:
    v.fit(d)
    v.fitWanted = false
  let s = pxScale
  let (iw, ih) = v.devSize(d)
  v.clampScroll(d)
  # scroll bars
  var hx = v.offX
  var hy = v.offY
  let maxX = max(0, iw - area.w * s)
  let maxY = max(0, ih - area.h * s)
  v.statusRect = if stw > 0: rect(area.x, area.y + area.h, stw, stH) else: rect(0, 0, 0, 0)
  if stw > 0:
    # (the status's strip, the scroll bar beside it at the bottom of the strip)
    fill(rect(area.x, area.y + area.h, area.w + sb, stH), th.face)
    hline(area.x, area.y + area.h, area.w + sb, th.frame)
  if scrollbarAt(id + 1, rect(area.x + stw, area.y + area.h + stH - sb, area.w - stw, sb), false, hx, 0, maxX,
                 max(1, area.w * s * 3 div 4), maxX > 0, step = max(1, 16 * s)):
    v.offX = hx
  if scrollbarAt(id + 2, rect(area.x + area.w, area.y, sb, area.h), true, hy, 0, maxY,
                 max(1, area.h * s * 3 div 4), maxY > 0, step = max(1, 16 * s)):
    v.offY = hy
  fill(rect(area.x + area.w, area.y + area.h + stH - sb, sb, sb), th.face)
  # the mouse
  let hit = interact(id, area, focusable = false)
  if hit.down and ui.pressed: ui.focus = id   # (the keys go to the image: off any palette box)
  if hit.down or ui.active == id: ui.dragsActive = true
  let (mx, my) = v.toImage(d, ui.mx, ui.my)
  result.x = mx
  result.y = my
  result.over = mouseIn(area) and canInput()
  result.shift = ShiftPressed in ui.mods
  result.ctrl = CtrlPressed in ui.mods
  result.alt = AltPressed in ui.mods
  result.moved = ui.mx != v.lastMx or ui.my != v.lastMy
  v.lastMx = ui.mx
  v.lastMy = ui.my
  if ui.active == id:
    if ui.pressed and hit.down:
      result.pressed = true
      result.clicks = ui.clicks
    result.down = ui.mouseDown
  if ui.released and (ui.active == id or (hit.down and not ui.mouseDown)):
    result.released = true
  if hit.hover and ui.rpressed:
    result.right = true
  # the wheel
  if result.over and ui.wheel != 0 and not ui.wheelUsed:
    ui.wheelUsed = true
    if (result.ctrl or result.alt) != viewPrefs.wheelZooms:
      if ui.wheel > 0: v.zoomIn(d, mx, my) else: v.zoomOut(d, mx, my)
    elif result.shift: v.offX -= ui.wheel * 48 * s
    else: v.offY -= ui.wheel * 48 * s
    v.clampScroll(d)
  # what is shown: made again when something changed
  let bw = area.w * s
  let bh = area.h * s
  let bg = rgbOf(th.shadow)
  let k = $v.zoom & "/" & $bw & "x" & $bh &
          "/" & $d.viewChannel & "/" & $d.mode & "/" & $d.proof & "/" & $d.gamutWarning & "/" & $d.duotone.len &
          "/" & $d.icc.len & "/" & $viewPrefs.checkerSize & $viewPrefs.checkerColors & $gamutColor &
          "/" & $d.quickMask & "/" & $d.w & "x" & $d.h & "/" & $bg &
          (if d.live.len > 0: "/live" & $d.liveVer else: "") &
          (if d.quickMask: "/" & $quickMaskColor & $quickMaskOpacity & $quickMaskOnSelected else: "")
  # (made again only where something changed: what scrolled is moved, what
  # was painted on is drawn again -- the composite first, so that a layer
  # style that moved says where its shadow was)
  if d.live.len == 0: d.updateComposite()
  let org = v.origin(d)
  if v.angle != 0:
    let kt = k & "/turned" & $v.angle & "/" & $org
    if kt != v.key or v.buf == nil or v.buf.w != bw or v.buf.h != bh or d.ver != v.shownVer:
      v.renderTurned(d, bw, bh, bg)
      v.key = kt
  elif v.gpuView(d, area, bg):
    v.buf = nil                  # (not needed while the GPU shows the image)
    v.key = ""
  elif k != v.key or v.buf == nil or v.buf.w != bw or v.buf.h != bh:
    v.renderView(d, bw, bh, bg)
    v.key = k
    v.buf.changed()
  else:
    var part = rect(0, 0, 0, 0)
    if org != v.shownOff:
      let dx = org[0] - v.shownOff[0]
      let dy = org[1] - v.shownOff[1]
      if abs(dx) >= bw or abs(dy) >= bh:
        part = rect(0, 0, bw, bh)
      else:
        v.shiftView(dx, dy)
        if dx > 0: part = union(part, rect(0, 0, dx, bh))
        elif dx < 0: part = union(part, rect(bw + dx, 0, -dx, bh))
        if dy > 0: part = union(part, rect(0, 0, bw, dy))
        elif dy < 0: part = union(part, rect(0, bh + dy, bw, -dy))
        # (the strips that came into view: each drawn on its own)
        if dx != 0 and dy != 0:
          v.renderView(d, bw, bh, bg, if dx > 0: rect(0, 0, dx, bh) else: rect(bw + dx, 0, -dx, bh))
          part = if dy > 0: rect(0, 0, bw, dy) else: rect(0, bh + dy, bw, -dy)
    if d.ver != v.shownVer:
      let c = d.changedSince(v.shownVer)
      let vr = v.viewRect(d, c, bw, bh)
      if org != v.shownOff:
        v.renderView(d, bw, bh, bg, part)
        v.renderView(d, bw, bh, bg, vr)
        v.buf.changed()
      else:
        v.renderView(d, bw, bh, bg, vr)
        v.buf.changed(vr)
    elif org != v.shownOff:
      v.renderView(d, bw, bh, bg, part)
      v.buf.changed()
  v.shownVer = d.ver
  v.shownOff = org
  if v.buf != nil: drawBitmap(area, v.buf)
  if d.selVer != v.antsVer:
    v.computeEdges(d)
    v.antsVer = d.selVer
  let ants = drawAntsNow and not v.hideEdges and (v.hEdges.len > 0 or v.vEdges.len > 0) and not d.quickMask and
             not (d.live.len > 0 and d.liveSel.hidden)
  if ants:
    if ui.now - v.antsAt >= 140:
      v.antsPhase = (v.antsPhase + 7) and 7
      v.antsAt = ui.now
    wakeIn(150)
    if v.angle != 0:
      # (turned: the outline's runs turned with it, dashed lines)
      let s = pxScale.float
      for sg in v.antsSegments(d, bw, bh):
        let (ax, ay) = v.turned(area.x.float + sg[0].float / s, area.y.float + sg[1].float / s, false)
        let (bx, by) = v.turned(area.x.float + sg[2].float / s, area.y.float + sg[3].float / s, false)
        pushClip(area)
        line(int(ax) + 1, int(ay) + 1, int(bx) + 1, int(by) + 1, color(255, 255, 255))
        line(int(ax), int(ay), int(bx), int(by), color(0, 0, 0))
        popClip()
    else:
      marchingAnts(area, v.antsSegments(d, bw, bh), v.antsPhase)
  # rulers
  if v.rulers:
    let rh = rect(area.x, r.y, area.w, rw)
    let rv = rect(r.x, area.y, rw, area.h)
    fill(rect(r.x, r.y, rw, rw), th.face)
    fill(rh, th.window)
    fill(rv, th.window)
    hline(rh.x, rh.y + rh.h - 1, rh.w, th.frame)
    vline(rv.x + rv.w - 1, rv.y, rv.h, th.frame)
    let (ox, oy) = v.origin(d)
    let small = style(size = 0.8)
    pushClip(rh)
    let ux = unitPixels(viewPrefs.rulerUnit, d.dpi, d.w)
    let uy = unitPixels(viewPrefs.rulerUnit, d.dpi, d.h)
    for (at, sz, lab) in rulerTicks(area.w, ox div s, v.scaleOf / s.float, ux):
      let h = [dp(3), dp(5), rw - 1][sz]
      vline(rh.x + at, rh.y + rw - h, h, th.text)
      if lab.len > 0: text(rh.x + at + 2, rh.y, lab, th.text, small)
    if result.over:
      let (cx, _) = v.toScreen(d, mx, my)
      vline(cx, rh.y, rw, color(255, 0, 0))
    popClip()
    pushClip(rv)
    for (at, sz, lab) in rulerTicks(area.h, oy div s, v.scaleOf / s.float, uy):
      let w = [dp(3), dp(5), rw - 1][sz]
      hline(rv.x + rw - w, rv.y + at, w, th.text)
      if lab.len > 0:
        var yy = rv.y + at + 2
        for ch in lab:
          text(rv.x + 1, yy, $ch, th.text, small)
          yy += lineHeight(small) - dp(3)
    if result.over:
      let (_, cy) = v.toScreen(d, mx, my)
      hline(rv.x, cy, rw, color(255, 0, 0))
    popClip()
  # the grid and the guides (over the image)
  pushClip(area)
  var (gx0, gy0) = v.toImage(d, area.x, area.y)
  var (gx1, gy1) = v.toImage(d, area.x + area.w, area.y + area.h)
  if v.angle != 0:
    # (turned: the image all the view's corners reach)
    gx0 = Inf; gy0 = Inf; gx1 = -Inf; gy1 = -Inf
    for (cx, cy) in [(area.x, area.y), (area.x + area.w, area.y), (area.x, area.y + area.h),
                     (area.x + area.w, area.y + area.h)]:
      let (ix, iy) = v.toImage(d, cx, cy)
      gx0 = min(gx0, ix); gy0 = min(gy0, iy); gx1 = max(gx1, ix); gy1 = max(gy1, iy)
  template gridLine(vertical: bool; at, a, n: int; c: Color; st: LineStyle; img: float) =
    if v.angle != 0:
      # (turned: across the image, from one side to the other)
      let (p0x, p0y) = v.toScreenF(d, (if vertical: img else: 0.0), (if vertical: 0.0 else: img))
      let (p1x, p1y) = v.toScreenF(d, (if vertical: img else: d.w.float), (if vertical: d.h.float else: img))
      line(int(p0x), int(p0y), int(p1x), int(p1y), c)
    elif st == lsLines:
      if vertical: vline(at, a, n, c) else: hline(a, at, n, c)
    else:
      let on = if st == lsDashed: dp(4) else: 1
      let period = if st == lsDashed: dp(7) else: dp(3)
      var k = 0
      while k < n:
        if vertical: fill(rect(at, a + k, 1, min(on, n - k)), c)
        else: fill(rect(a + k, at, min(on, n - k), 1), c)
        k += period
  if v.showGrid:
    let step = if v.gridStep > 0: v.gridStep else: gridStepOf(d)
    let sub = max(1, if v.gridStep > 0: v.gridSub else: viewPrefs.gridSub)
    let gc = viewPrefs.gridColor
    let light = color(uint8((gc.r.int + 2 * 255) div 3), uint8((gc.g.int + 2 * 255) div 3),
                      uint8((gc.b.int + 2 * 255) div 3))
    let fine = step / sub.float
    # (the lighter lines only when they are not too close on the screen)
    let showFine = fine * v.scaleOf / pxScale.float >= dp(6).float
    let unit = if showFine: fine else: step
    if unit * v.scaleOf / pxScale.float >= dp(3).float:
      var k = int(floor(max(0.0, gx0) / unit))
      while k.float * unit <= min(d.w.float, gx1):
        let major = (k mod (if showFine: sub else: 1)) == 0
        let (sx, _) = v.toScreen(d, k.float * unit, 0)
        gridLine(true, sx, area.y, area.h, if major: gc else: light, viewPrefs.gridStyle, k.float * unit)
        inc k
      k = int(floor(max(0.0, gy0) / unit))
      while k.float * unit <= min(d.h.float, gy1):
        let major = (k mod (if showFine: sub else: 1)) == 0
        let (_, sy) = v.toScreen(d, 0, k.float * unit)
        gridLine(false, sy, area.x, area.w, if major: gc else: light, viewPrefs.gridStyle, k.float * unit)
        inc k
  if v.showGuides:
    for g in d.guides:
      let (sx, sy) = v.toScreen(d, g.pos, g.pos)
      if g.vertical: gridLine(true, sx, area.y, area.h, viewPrefs.guideColor, viewPrefs.guideStyle, g.pos)
      else: gridLine(false, sy, area.x, area.w, viewPrefs.guideColor, viewPrefs.guideStyle, g.pos)
  popClip()
  # guides: dragged out of a ruler, moved, dragged back onto it to go
  if v.showGuides and not v.lockGuides:
    let rh = rect(area.x, r.y, area.w, rw)
    let rv = rect(r.x, area.y, rw, area.h)
    let gid = id + 3
    if v.rulers and ui.pressed and canInput() and (mouseIn(rh) or mouseIn(rv)) and not v.guideDrag.on:
      let vert = mouseIn(rv)
      d.guides.add Guide(vertical: vert, pos: (if vert: mx else: my))
      v.guideDrag = (true, vert, d.guides.high)
      ui.active = gid
    if v.guideDrag.on:
      ui.dragsActive = true
      let gi = v.guideDrag.idx
      if gi < d.guides.len:
        if ui.mouseDown:
          let (ix, iy) = v.toImage(d, ui.mx, ui.my)
          d.guides[gi].pos = round(if d.guides[gi].vertical: ix else: iy)
          ui.cursor = if d.guides[gi].vertical: curSizeWE else: curSizeNS
          result.guideMoved = true
        else:
          # (let go over a ruler or outside the image: gone)
          if not mouseIn(area): d.guides.delete(gi)
          v.guideDrag.on = false
          result.guideMoved = true
          inc d.ver
      else: v.guideDrag.on = false
    elif result.over and v.allowGuideGrab:
      # a guide under the mouse: it can be dragged
      for gi, g in d.guides:
        let (sx, sy) = v.toScreen(d, g.pos, g.pos)
        let near = if g.vertical: abs(ui.mx - sx) <= dp(3) else: abs(ui.my - sy) <= dp(3)
        if near:
          ui.cursor = if g.vertical: curSizeWE else: curSizeNS
          if ui.pressed:
            v.guideDrag = (true, g.vertical, gi)
            result.pressed = false
            result.down = false
            result.guideMoved = true
          break
  if accessOn:
    accessNode(arImage, "Picture", id = id, r = area, help = $d.w & " x " & $d.h)
  ui.lastId = id
  ui.lastRect = area

proc ellipseOnScreen*(x0, y0, x1, y1: int; c: Color) =
  ## An ellipse's outline (thin), e.g. a brush's size under the mouse.
  let cx = (x0 + x1) / 2
  let cy = (y0 + y1) / 2
  let rx = abs(x1 - x0) / 2
  let ry = abs(y1 - y0) / 2
  let n = clamp(int((rx + ry) * 1.2), 12, 160)
  var px = int(round(cx + rx))
  var py = int(round(cy))
  for i in 1 .. n:
    let a = i.float / n.float * 2 * PI
    let nx = int(round(cx + cos(a) * rx))
    let ny = int(round(cy + sin(a) * ry))
    line(px, py, nx, ny, c)
    px = nx
    py = ny

proc dashedRect*(r: Rect; phase = 0) =
  ## A rubber band: black and white dashes.
  for (x, y, w, h) in [(r.x, r.y, r.w, 1), (r.x, r.y + r.h - 1, r.w, 1), (r.x, r.y, 1, r.h),
                       (r.x + r.w - 1, r.y, 1, r.h)]:
    fill(rect(x, y, w, h), color(255, 255, 255))
    if w > 1:
      var i = (phase mod 8)
      while i < w:
        fill(rect(x + i, y, min(4, w - i), 1), color(0, 0, 0))
        i += 8
    else:
      var i = (phase mod 8)
      while i < h:
        fill(rect(x, y + i, 1, min(4, h - i)), color(0, 0, 0))
        i += 8

proc dashedLine*(x0, y0, x1, y1: int) =
  ## A line in black over white (seen on any color).
  line(x0 + 1, y0 + 1, x1 + 1, y1 + 1, color(255, 255, 255))
  line(x0, y0, x1, y1, color(0, 0, 0))

# ---- the color picker ---------------------------------------------------------------------------------

type PickerChannel* = enum
  ## The channel the color picker's strip shows (the field shows the other two).
  pcHue = "H", pcSat = "S", pcBright = "B", pcRed = "R", pcGreen = "G", pcBlue = "B "

type ColorPickerState* = object
  ## What the color picker keeps while open.
  h*, s*, b*: float          ## the color as hue 0..360, saturation, brightness 0..1
  chan*: PickerChannel       ## the channel of the strip (the radio button picked)
  chanSel: int
  original*: uint32          ## the color when the picker opened (shown beside the new one)
  field, strip: Bitmap
  fieldKey, stripKey: string
  opened: bool
  libraries*: bool           ## Color Libraries shown in the picker's place
  book*: int                 ## ... the book shown
  libSel*: int               ## ... its color chosen
  libKey: string             ## ... the name or number typed to find one
  pickedName*: string        ## the library color's name, when OK took one

var colorBooks*: seq[ColorBook]
  ## The Color Libraries: the kit's own (`builtinBooks`, there from the
  ## first use) and the ones the app adds (.acb files the user has).

proc ensureBooks() =
  if colorBooks.len == 0: colorBooks = builtinBooks()

proc pickerColor*(p: ColorPickerState): uint32 = fromHsb(p.h, p.s, p.b)
  ## The color the picker is at (opaque).

proc setPickerColor*(p: var ColorPickerState; c: uint32) =
  ## Puts the picker at `c` (the hue stays for a gray).
  let hsb = toHsb(c)
  if hsb.s > 0 and hsb.b > 0: p.h = hsb.h
  p.s = hsb.s
  p.b = hsb.b

proc fieldColor(p: ColorPickerState; u, v: float): uint32 =
  ## The field's color at (u, v) in 0..1 (v up) for the channel the strip holds.
  let c = pickerColor(p)
  case p.chan
  of pcHue: fromHsb(p.h, u, v)
  of pcSat: fromHsb(u * 360, p.s, v)
  of pcBright: fromHsb(u * 360, v, p.b)
  of pcRed: argb(255, rOf(c), int(v * 255), int(u * 255))
  of pcGreen: argb(255, int(v * 255), gOf(c), int(u * 255))
  of pcBlue: argb(255, int(u * 255), int(v * 255), bOf(c))

proc stripColor(p: ColorPickerState; t: float): uint32 =
  let c = pickerColor(p)
  case p.chan
  of pcHue: fromHsb(t * 360, 1, 1)
  of pcSat: fromHsb(p.h, t, p.b)
  of pcBright: fromHsb(p.h, p.s, t)
  of pcRed: argb(255, int(t * 255), gOf(c), bOf(c))
  of pcGreen: argb(255, rOf(c), int(t * 255), bOf(c))
  of pcBlue: argb(255, rOf(c), gOf(c), int(t * 255))

proc fieldPos(p: ColorPickerState): (float, float) =
  let c = pickerColor(p)
  case p.chan
  of pcHue: (p.s, p.b)
  of pcSat: (p.h / 360, p.b)
  of pcBright: (p.h / 360, p.s)
  of pcRed: (bOf(c) / 255, gOf(c) / 255)
  of pcGreen: (bOf(c) / 255, rOf(c) / 255)
  of pcBlue: (rOf(c) / 255, gOf(c) / 255)

proc stripPos(p: ColorPickerState): float =
  let c = pickerColor(p)
  case p.chan
  of pcHue: p.h / 360
  of pcSat: p.s
  of pcBright: p.b
  of pcRed: rOf(c) / 255
  of pcGreen: gOf(c) / 255
  of pcBlue: bOf(c) / 255

proc setField(p: var ColorPickerState; u, v: float) =
  let c = pickerColor(p)
  case p.chan
  of pcHue: (p.s, p.b) = (u, v)
  of pcSat: (p.h, p.b) = (u * 360, v)
  of pcBright: (p.h, p.s) = (u * 360, v)
  of pcRed: p.setPickerColor(argb(255, rOf(c), int(v * 255), int(u * 255)))
  of pcGreen: p.setPickerColor(argb(255, int(v * 255), gOf(c), int(u * 255)))
  of pcBlue: p.setPickerColor(argb(255, int(u * 255), int(v * 255), bOf(c)))

proc setStrip(p: var ColorPickerState; t: float) =
  let c = pickerColor(p)
  case p.chan
  of pcHue: p.h = t * 360
  of pcSat: p.s = t
  of pcBright: p.b = t
  of pcRed: p.setPickerColor(argb(255, int(t * 255), gOf(c), bOf(c)))
  of pcGreen: p.setPickerColor(argb(255, rOf(c), int(t * 255), bOf(c)))
  of pcBlue: p.setPickerColor(argb(255, rOf(c), gOf(c), int(t * 255)))

proc colorField*(p: var ColorPickerState; size: int): bool {.discardable.} =
  ## The big square of colors with a ring on the one chosen; dragging
  ## chooses.
  let r = place(size + 2, size + 2)
  beginKeepSides(r)               # (as it is in a right-to-left interface too)
  defer: endKeepSides()
  let id = idOf(p, "field")
  let hit = interact(id, r, focusable = false)
  if hit.down or ui.active == id: ui.dragsActive = true
  let inner = inset(r, 1)
  if ui.active == id and ui.mouseDown:
    let u = clamp((ui.mx - inner.x).float / (inner.w - 1).float, 0.0, 1.0)
    let v = clamp(1 - (ui.my - inner.y).float / (inner.h - 1).float, 0.0, 1.0)
    p.setField(u, v)
    result = true
  let n = 128
  let key = $p.chan & (case p.chan
                       of pcHue: $p.h
                       of pcSat: $p.s
                       of pcBright: $p.b
                       else: $stripPos(p))
  if p.field == nil or key != p.fieldKey:
    p.field = newBitmap(n, n)
    for y in 0 ..< n:
      for x in 0 ..< n:
        p.field.px[y * n + x] = fieldColor(p, x / (n - 1), 1 - y / (n - 1))
    p.field.changed()
    p.fieldKey = key
  box(r, th.frame)
  drawBitmap(inner, p.field)
  let (u, v) = fieldPos(p)
  let cx = inner.x + int(u * (inner.w - 1).float)
  let cy = inner.y + int((1 - v) * (inner.h - 1).float)
  pushClip(inner)
  let ring = if lumaOf(pickerColor(p)) > 140: color(0, 0, 0) else: color(255, 255, 255)
  ellipseOnScreen(cx - dp(5), cy - dp(5), cx + dp(5), cy + dp(5), ring)
  popClip()

proc colorStrip*(p: var ColorPickerState; w, h: int): bool {.discardable.} =
  ## The narrow strip of the channel chosen, with its two arrows.
  let r = place(w, h)
  beginKeepSides(r)               # (as it is in a right-to-left interface too)
  defer: endKeepSides()
  let id = idOf(p, "strip")
  let hit = interact(id, r, focusable = false)
  if hit.down or ui.active == id: ui.dragsActive = true
  let bar = rect(r.x + dp(7), r.y, r.w - dp(14), r.h)
  if ui.active == id and ui.mouseDown:
    p.setStrip(clamp(1 - (ui.my - bar.y).float / (bar.h - 1).float, 0.0, 1.0))
    result = true
  let key = $p.chan & $p.h & $p.s & $p.b
  if p.strip == nil or key != p.stripKey:
    p.strip = newBitmap(1, 128)
    for y in 0 ..< 128: p.strip.px[y] = stripColor(p, 1 - y / 127)
    p.strip.changed()
    p.stripKey = key
  fill(r, th.window)
  box(bar, th.frame)
  drawBitmap(inset(bar, 1), p.strip)
  let y = bar.y + int((1 - stripPos(p)) * (bar.h - 1).float)
  arrow(r.x + dp(3), y, dRight, th.text, dp(4))
  arrow(r.x + r.w - dp(4), y, dLeft, th.text, dp(4))

proc colorPickerDialog*(open: var bool; title: string; c: var uint32;
                        p: var ColorPickerState): bool =
  ## The color picker: a field and a strip for the channel chosen (H, S,
  ## B, R, G, B), the new color over the old one, and the numbers in HSB,
  ## RGB, Lab and CMYK to type. True (once) on OK, with `c` set.
  if not open:
    p.opened = false
    return
  if not p.opened:
    p.opened = true
    p.original = c
    p.setPickerColor(c)
  if p.libraries:
    # Color Libraries: a book's named colors (Photoshop's dialog in place of the picker)
    ensureBooks()
    dialog(open, "Color Libraries", 560):
      var names: seq[string]
      for b in colorBooks: names.add b.title
      p.book = clamp(p.book, 0, colorBooks.high)
      row:
        label "Book:"
        if combo(names, p.book, w = dp(260)): p.libSel = 0
      let b = colorBooks[p.book]
      row:
        label "Find:"
        if edit(p.libKey, w = dp(160)) and p.libKey.len > 0:
          let k = p.libKey.toLowerAscii
          for i, c in b.colors:
            if c.name.toLowerAscii.startsWith(k) or c.code.toLowerAscii.startsWith(k) or
               b.fullName(c).toLowerAscii.contains(k):
              p.libSel = i
              break
        label(if b.spot: "spot colors" else: $b.model & " process colors", color = th.gray)
      row([-1, 110]):
        col:
          var items: seq[string]
          for c in b.colors: items.add b.fullName(c)
          let lh = max(ItemH, dp(22))
          let r = place(0, lh * 12, fill = true)
          let id = idOf(p, "library")
          var st = state(id)
          let top = clamp(st.scrollY, 0, max(0, b.colors.len * lh - r.h))
          let hit = interact(id, r)
          if hit.down and ui.pressed:
            p.libSel = clamp((ui.my - r.y + top) div lh, 0, b.colors.high)
          if hit.focused and not ui.keyUsed:
            if ui.key == KeyDown: p.libSel = min(b.colors.high, p.libSel + 1); ui.keyUsed = true
            if ui.key == KeyUp: p.libSel = max(0, p.libSel - 1); ui.keyUsed = true
          var off = top
          if p.libSel * lh < off: off = p.libSel * lh
          if (p.libSel + 1) * lh > off + r.h: off = (p.libSel + 1) * lh - r.h
          if mouseIn(r) and ui.wheel != 0:
            off = clamp(off - ui.wheel * lh * 3, 0, max(0, b.colors.len * lh - r.h))
            ui.wheelUsed = true
          st.scrollY = off
          state(id) = st
          fill(r, th.field)
          box(r, th.frame)
          pushClip(inset(r, 1))
          for i in max(0, off div lh) .. min(b.colors.high, (off + r.h) div lh):
            let y = r.y + i * lh - off
            let row = rect(r.x + 1, y, r.w - 2, lh)
            if i == p.libSel: fill(row, th.select)
            let sw = rect(row.x + dp(4), row.y + dp(3), dp(36), lh - dp(6))
            fill(sw, colorOf(b.colors[i].color))
            box(sw, th.frame)
            text(sw.x + sw.w + dp(8), row.y + (lh - FontH) div 2, items[i],
                 if i == p.libSel: th.selectText else: th.fieldText)
          popClip()
        col:
          let c = b.colors[clamp(p.libSel, 0, b.colors.high)]
          if button("OK", isDefault = true, w = dp(100)):
            p.setPickerColor(c.color)
            p.pickedName = b.fullName(c)
            p.libraries = false
          if button("Cancel", w = dp(100)):
            p.libraries = false
            open = false
          if button("Picker", w = dp(100)): p.libraries = false
          space(dp(8))
          let big = place(dp(100), dp(60))
          fill(big, colorOf(c.color))
          box(big, th.frame)
          label(b.fullName(c))
          if b.model == bkCmyk:
            label("C " & $c.cmyk[0] & "  M " & $c.cmyk[1])
            label("Y " & $c.cmyk[2] & "  K " & $c.cmyk[3])
          elif b.model == bkLab:
            label("L " & $c.lab[0] & "  a " & $c.lab[1] & "  b " & $c.lab[2])
          else:
            label("#" & toHex(int(c.color and 0xFFFFFF'u32), 6))
    return
  dialog(open, title, 600):
    label(title & ":")
    row([260, 36, -1, 96]):
      p.colorField(dp(256))
      p.colorStrip(dp(28), dp(256) + 2)
      col:
        # the new color over the old
        let sw = place(dp(70), dp(60))
        fill(rect(sw.x, sw.y, sw.w, sw.h div 2), colorOf(pickerColor(p)))
        fill(rect(sw.x, sw.y + sw.h div 2, sw.w, sw.h - sw.h div 2), colorOf(p.original))
        box(sw, th.frame)
        let back = interact(idOf(p, "old"), rect(sw.x, sw.y + sw.h div 2, sw.w, sw.h div 2), focusable = false)
        if back.clicked: p.setPickerColor(p.original)
        space(dp(10))
        let cur = pickerColor(p)
        var hh = int(round(p.h)) mod 360
        var ss = int(round(p.s * 100))
        var bb = int(round(p.b * 100))
        var rr = rOf(cur)
        var gg = gOf(cur)
        var bl = bOf(cur)
        p.chanSel = ord(p.chan)
        template chanRow(ch: PickerChannel; lab: string; v: var int; hi: int; unit: string; onChange: untyped) {.redefine.} =
          row:
            if radio(lab, p.chanSel, ord(ch)): p.chan = ch
            if spin(v, 0, hi, w = dp(64)):
              onChange
            label unit
        chanRow(pcHue, "H:", hh, 360, "°"):
          p.h = hh.float
        chanRow(pcSat, "S:", ss, 100, "%"):
          p.s = ss / 100
        chanRow(pcBright, "B:", bb, 100, "%"):
          p.b = bb / 100
        chanRow(pcRed, "R:", rr, 255, ""):
          p.setPickerColor(argb(255, rr, gg, bl))
        chanRow(pcGreen, "G:", gg, 255, ""):
          p.setPickerColor(argb(255, rr, gg, bl))
        chanRow(pcBlue, "B:", bl, 255, ""):
          p.setPickerColor(argb(255, rr, gg, bl))
      col:
        if button("OK", isDefault = true, w = dp(100)):
          c = pickerColor(p)
          open = false
          result = true
        if button("Cancel", w = dp(100)): open = false
        if button("Color Libraries", w = dp(100)):
          p.libraries = true
          p.pickedName = ""
        space(dp(6))
        # Lab and CMYK to type, as in Photoshop's picker
        var lab = toLab(pickerColor(p))
        var cm = toCmyk(pickerColor(p))
        var (ll, la, lb) = (lab.l, lab.a, lab.b)
        template labRow(lab0: string; v: var int; lo, hi: int) {.redefine.} =
          row:
            label lab0
            if spin(v, lo, hi, w = dp(64)):
              p.setPickerColor(fromLab(ll.float, la.float, lb.float))
        labRow("L:", ll, 0, 100)
        labRow("a:", la, -128, 127)
        labRow("b:", lb, -128, 127)
        var (cc, mm, yy, kk) = (cm.c, cm.m, cm.y, cm.k)
        template inkRow(lab0: string; v: var int) {.redefine.} =
          row:
            label lab0
            if spin(v, 0, 100, w = dp(64)):
              p.setPickerColor(fromInk([uint8(cc * 255 div 100), uint8(mm * 255 div 100),
                                        uint8(yy * 255 div 100), uint8(kk * 255 div 100)]))
            label "%"
        inkRow("C:", cc)
        inkRow("M:", mm)
        inkRow("Y:", yy)
        inkRow("K:", kk)
        if not inGamut(pickerColor(p)):
          label("! Cannot print", color = color(170, 0, 0))
          tooltip("Out of the inks' gamut: it prints as the color beside it")
          let pr = place(dp(40), dp(14))
          fill(pr, colorOf(proofOf(pickerColor(p))))
          box(pr, ui.theme.text)
        space(dp(6))
        var hex = "#" & toHex(int(pickerColor(p) and 0xFFFFFF'u32), 6)
        if edit(hex, w = dp(90)):
          var v: int
          if hex.len == 7 and hex[0] == '#':
            try:
              v = parseHexInt(hex[1 .. ^1])
              p.setPickerColor(0xFF000000'u32 or uint32(v))
            except ValueError: discard

# ---- curves ---------------------------------------------------------------------------------------------

proc shearEditor*(pts: var seq[(float, float)]; size: int;
                  curve: proc (y: float): float): bool {.discardable.} =
  ## The square of Shear: a grid and an upright line through `pts`
  ## (sideways -1..1, height 0..1; `curve` gives the line between them). A
  ## click adds a point, dragging moves it, dragging it out of the square
  ## takes it away (the top and bottom ones stay).
  let r = place(size + 2, size + 2)
  let id = idOf(pts, "shear")
  let hit = interact(id, r, focusable = false)
  if hit.down or ui.active == id: ui.dragsActive = true
  let inner = inset(r, 1)
  var st = state(id)
  proc toPt(x, y: int): (float, float) =
    (clamp((x - inner.x).float / (inner.w - 1).float * 2 - 1, -1.0, 1.0),
     clamp((y - inner.y).float / (inner.h - 1).float, 0.0, 1.0))
  proc toScr(p: (float, float)): (int, int) =
    (inner.x + int((p[0] + 1) / 2 * (inner.w - 1).float), inner.y + int(p[1] * (inner.h - 1).float))
  if hit.down and ui.pressed:
    var best = -1
    var bd = dp(8) * dp(8)
    for i, p in pts:
      let (sx, sy) = toScr(p)
      let dd = (sx - ui.mx) ^ 2 + (sy - ui.my) ^ 2
      if dd <= bd:
        bd = dd
        best = i
    if best < 0:
      pts.add toPt(ui.mx, ui.my)
      best = pts.high
    st.aux = best
    result = true
  if ui.active == id and ui.mouseDown and st.aux >= 0 and st.aux < pts.len:
    let outside = not mouseIn(inset(r, -dp(12)))
    var p = toPt(ui.mx, ui.my)
    let ends = pts[st.aux][1] <= 0.0 or pts[st.aux][1] >= 1.0
    if outside and not ends and pts.len > 2:
      pts.delete(st.aux)
      st.aux = -1
    else:
      if ends: p[1] = pts[st.aux][1]          # (the ends stay at the top and the bottom)
      pts[st.aux] = p
    result = true
  if ui.released: st.aux = -1
  state(id) = st
  fill(r, th.window)
  box(r, th.frame)
  for k in 1 .. 3:
    vline(inner.x + inner.w * k div 4, inner.y, inner.h, th.face)
    hline(inner.x, inner.y + inner.h * k div 4, inner.w, th.face)
  var last = (0, 0)
  for y in 0 ..< inner.h:
    let v = y / max(1, inner.h - 1)
    let x = inner.x + int((clamp(curve(v), -1.0, 1.0) + 1) / 2 * (inner.w - 1).float)
    if y > 0: line(last[0], last[1], x, inner.y + y, th.text)
    last = (x, inner.y + y)
  for p in pts:
    let (sx, sy) = toScr(p)
    fill(rect(sx - 2, sy - 2, 5, 5), th.text)

proc curvesEditor*(pts: var seq[(int, int)]; size: int; lut: openArray[uint8]): bool {.discardable.} =
  ## The 0..255 square with a grid, the curve (`lut`) and its points: a
  ## click on the curve adds one, dragging moves it, dragging it out of the
  ## square takes it away (the two ends stay).
  let r = place(size + 2, size + 2)
  beginKeepSides(r)               # (as it is in a right-to-left interface too)
  defer: endKeepSides()
  let id = idOf(pts, "curves")
  let hit = interact(id, r, focusable = false)
  if hit.down or ui.active == id: ui.dragsActive = true
  let inner = inset(r, 1)
  var st = state(id)
  proc toPt(x, y: int): (int, int) =
    (clamp(int(round((x - inner.x).float / (inner.w - 1).float * 255)), 0, 255),
     clamp(int(round((1 - (y - inner.y).float / (inner.h - 1).float) * 255)), 0, 255))
  proc toScr(p: (int, int)): (int, int) =
    (inner.x + int(p[0].float / 255 * (inner.w - 1).float),
     inner.y + int((1 - p[1].float / 255) * (inner.h - 1).float))
  if hit.down and ui.pressed:
    var best = -1
    var bd = dp(8) * dp(8)
    for i, p in pts:
      let (sx, sy) = toScr(p)
      let dd = (sx - ui.mx) ^ 2 + (sy - ui.my) ^ 2
      if dd <= bd:
        bd = dd
        best = i
    if best < 0:
      pts.add toPt(ui.mx, ui.my)
      best = pts.high
    st.aux = best
    result = true
  if ui.active == id and ui.mouseDown and st.aux >= 0 and st.aux < pts.len:
    let outside = not mouseIn(inset(r, -dp(12)))
    let (px, py) = toPt(ui.mx, ui.my)
    var minX = 0
    var maxX = 255
    for i, p in pts:
      if i == st.aux: continue
      if p[0] < pts[st.aux][0]: minX = max(minX, p[0] + 1)
      else: maxX = min(maxX, p[0] - 1)
    if outside and pts.len > 2:
      pts.delete(st.aux)
      st.aux = -1
    else:
      pts[st.aux] = (clamp(px, minX, maxX), py)
    result = true
  if ui.released: st.aux = -1
  state(id) = st
  fill(r, th.window)
  box(r, th.frame)
  for k in 1 .. 3:
    let x = inner.x + inner.w * k div 4
    let y = inner.y + inner.h * k div 4
    vline(x, inner.y, inner.h, th.face)
    hline(inner.x, y, inner.w, th.face)
  line(inner.x, inner.y + inner.h - 1, inner.x + inner.w - 1, inner.y, th.face)
  var prev = (0, 0)
  for x in 0 .. 255:
    let p = toScr((x, int(lut[x])))
    if x > 0: line(prev[0], prev[1], p[0], p[1], th.text)
    prev = p
  for p in pts:
    let (sx, sy) = toScr(p)
    fill(rect(sx - 2, sy - 2, 5, 5), th.window)
    box(rect(sx - 2, sy - 2, 5, 5), th.text)

# ---- levels -----------------------------------------------------------------------------------------------

proc histogramView*(counts: openArray[int]; w, h: int; c = Color()) =
  ## Bars of a histogram (256 levels) in `w` x `h`.
  let r = place(w, h)
  fill(r, th.window)
  box(r, th.frame)
  var mx = 1
  var sorted = @counts
  sorted.sort()
  # the tallest few are cut so the rest shows (as editors do)
  mx = max(1, sorted[int(sorted.high.float * 0.995)])
  let col = if c.a == 0: th.text else: c
  let inner = inset(r, 1)
  for x in 0 ..< inner.w:
    let lv = x * 256 div inner.w
    let lv2 = max(lv + 1, (x + 1) * 256 div inner.w)
    var v = 0
    for k in lv ..< min(256, lv2): v = max(v, counts[k])
    let bh = min(inner.h, v * inner.h div mx)
    if bh > 0: vline(inner.x + x, inner.y + inner.h - bh, bh, col)

proc levelSlider*(vals: var seq[int]; w: int; colors: openArray[Color] = []): int =
  ## Triangles on a line that slide (Levels' input black, gray, white or
  ## output black, white): `vals` in 0..255, kept in order. Returns the
  ## one moved (-1 none).
  result = -1
  let h = dp(12)
  let r = place(w, h)
  beginKeepSides(r)               # (as it is in a right-to-left interface too)
  defer: endKeepSides()
  let id = idOf(vals, "levelslider")
  let hit = interact(id, r, focusable = false)
  if hit.down or ui.active == id: ui.dragsActive = true
  var st = state(id)
  proc xOf(v: int): int = r.x + v * (r.w - 1) div 255
  if hit.down and ui.pressed:
    var best = -1
    var bd = 1 shl 30
    for i, v in vals:
      let dd = abs(xOf(v) - ui.mx)
      if dd < bd:
        bd = dd
        best = i
    st.aux = best
  if ui.active == id and ui.mouseDown and st.aux >= 0 and st.aux < vals.len:
    let v = clamp((ui.mx - r.x) * 255 div max(1, r.w - 1), 0, 255)
    let lo = if st.aux > 0: vals[st.aux - 1] + 2 else: 0
    let hi = if st.aux < vals.high: vals[st.aux + 1] - 2 else: 255
    let nv = clamp(v, lo, hi)
    if nv != vals[st.aux]:
      vals[st.aux] = nv
      result = st.aux
  state(id) = st
  hline(r.x, r.y + 1, r.w, th.shadow)
  for i, v in vals:
    let x = xOf(v)
    let c = if i < colors.len: colors[i] else: (if i == 0: color(0, 0, 0) elif i == vals.high: color(255, 255, 255)
                                                 else: color(128, 128, 128))
    for k in 0 .. dp(6):
      hline(x - k, r.y + 2 + k, 2 * k + 1, c)
    line(x, r.y + 2, x - dp(6), r.y + 2 + dp(6), th.frame)
    line(x, r.y + 2, x + dp(6), r.y + 2 + dp(6), th.frame)
    hline(x - dp(6), r.y + 2 + dp(6), 2 * dp(6) + 1, th.frame)

proc gradientBar*(w, h: int; c0, c1: Color) =
  ## A bar going from `c0` to `c1`.
  let r = place(w, h)
  for x in 0 ..< r.w:
    let t = x / max(1, r.w - 1)
    vline(r.x + x, r.y, r.h, colorOf(mix(rgbOf(c0), rgbOf(c1), t)))
  box(r, th.frame)

proc gradientSlider*(v: var int; hi: int; w: int; colorAt: proc (t: float): uint32): bool {.discardable.} =
  ## A bar of the colors a value gives (`colorAt(0..1)`) with a triangle
  ## under it to slide (the Picker palette's sliders).
  let barH = dp(10)
  let r = place(w, barH + dp(7))
  beginKeepSides(r)               # (as it is in a right-to-left interface too)
  defer: endKeepSides()
  let id = idOf(v, "gradslider")
  let hit = interact(id, r, focusable = false)
  if hit.down or ui.active == id: ui.dragsActive = true
  let bar = rect(r.x + dp(4), r.y, r.w - dp(8), barH)
  if ui.active == id and ui.mouseDown:
    let nv = clamp(int(round((ui.mx - bar.x).float / max(1, bar.w - 1).float * hi.float)), 0, hi)
    if nv != v:
      v = nv
      result = true
  for x in 0 ..< bar.w:
    vline(bar.x + x, bar.y, bar.h, colorOf(colorAt(x / max(1, bar.w - 1))))
  box(bar, th.frame)
  let x = bar.x + v * (bar.w - 1) div max(1, hi)
  for k in 0 .. dp(5):
    hline(x - k, bar.y + bar.h + 1 + k, 2 * k + 1, th.text)

proc blendRange*(key: string; v: var array[4, int]; w: int; tint = (0'u32, 0xFFFFFFFF'u32);
                 split = false): bool {.discardable.} =
  ## Blend If's range: a bar from black to white (`tint`) with a pair of
  ## triangles at each end -- black's and its split, white's split and white
  ## (`v`, 0..255). A pair moves together; held apart (Alt, or `split`) each
  ## half moves alone. The values are written over it.
  let barH = dp(10)
  let r = place(w, lineHeight() + barH + dp(9))
  beginKeepSides(r)               # (as it is in a right-to-left interface too)
  defer: endKeepSides()
  let id = idOf("blendrange:" & key)
  let hit = interact(id, r, focusable = false)
  if hit.down or ui.active == id: ui.dragsActive = true
  let bar = rect(r.x + dp(6), r.y + lineHeight() + 1, r.w - dp(12), barH)
  template xOf(val: int): int = bar.x + val * (bar.w - 1) div 255
  var st = state(id)
  if hit.down and ui.pressed:
    # the handle under the mouse: the nearest (of a pair together, the half)
    var best = 0
    var bd = high(int)
    for i in 0 .. 3:
      let dd = abs(ui.mx - xOf(v[i]))
      if dd < bd or (dd == bd and ui.mx > xOf(v[i]) and i in [1, 3]):
        bd = dd
        best = i
    st.aux = best + 1
  if ui.active == id and ui.mouseDown and st.aux > 0:
    let i = st.aux - 1
    let nv = clamp(int(round((ui.mx - bar.x).float / max(1, bar.w - 1).float * 255)), 0, 255)
    let pair = if i < 2: [0, 1] else: [2, 3]
    let together = v[pair[0]] == v[pair[1]] and not split and AltPressed notin ui.mods
    var nw = v
    if together:
      let lo = if i < 2: 0 else: v[1]
      let hi = if i < 2: v[2] else: 255
      nw[pair[0]] = clamp(nv, lo, hi)
      nw[pair[1]] = nw[pair[0]]
    else:
      let lo = if i == 0: 0 else: nw[i - 1]
      let hi = if i == 3: 255 else: nw[i + 1]
      nw[i] = clamp(nv, lo, hi)
    if nw != v:
      v = nw
      result = true
  if ui.released: st.aux = 0
  state(id) = st
  # the values, the bar, the handles
  let lo = if v[0] == v[1]: $v[0] else: $v[0] & "/" & $v[1]
  let whiteT = if v[2] == v[3]: $v[2] else: $v[2] & "/" & $v[3]
  text(bar.x, r.y, lo, th.text)
  text(bar.x + bar.w - textWidth(whiteT), r.y, whiteT, th.text)
  for x in 0 ..< bar.w:
    vline(bar.x + x, bar.y, bar.h, colorOf(mix(tint[0], tint[1], x / max(1, bar.w - 1))))
  box(bar, th.frame)
  for i in 0 .. 3:
    let x = xOf(v[i])
    let half = (i == 0 and v[0] != v[1]) or (i == 2 and v[2] != v[3])
    let half2 = (i == 1 and v[0] != v[1]) or (i == 3 and v[2] != v[3])
    let fillC = if i < 2: color(0, 0, 0) else: color(255, 255, 255)
    for k in 0 .. dp(5):
      let x0 = if half2: x else: x - k
      let ww = if half or half2: k + 1 else: 2 * k + 1
      hline(x0, bar.y + bar.h + 2 + k, ww, fillC)
    line(x, bar.y + bar.h + 2, x - dp(5), bar.y + bar.h + 2 + dp(5), th.frame)
    line(x, bar.y + bar.h + 2, x + dp(5), bar.y + bar.h + 2 + dp(5), th.frame)
    hline(x - dp(5), bar.y + bar.h + 2 + dp(5), 2 * dp(5) + 1, th.frame)

# ---- gradients --------------------------------------------------------------------------------------------

proc gradientStrip*(stops: seq[GradientStop]; w, h: int; reverse = false): Bitmap =
  ## A gradient drawn across `w` x `h` pixels, over a checkerboard where it
  ## is transparent.
  result = newBitmap(max(1, w), max(1, h))
  for x in 0 ..< result.w:
    let t = x / max(1, result.w - 1)
    let c = gradientColor(stops, if reverse: 1 - t else: t)
    for y in 0 ..< result.h:
      let ck = if ((x div 4) + (y div 4)) mod 2 == 0: 0xFFFFFFFF'u32 else: 0xFFC0C0C0'u32
      result.px[y * result.w + x] = blendPx(ck, c, 255, bmNormal)
  result.changed()

proc gradientSwatch*(key: string; stops: seq[GradientStop]; w, h: int; selected = false;
                     reverse = false): Hit {.discardable.} =
  ## A gradient in a framed box (a preset to pick).
  let r = place(w, h)
  beginKeepSides(r)               # (as it is in a right-to-left interface too)
  defer: endKeepSides()
  result = interact(idOf("gradswatch:" & key), r, focusable = false)
  let b = gradientStrip(stops, max(1, (r.w - 2) * pxScale), max(1, (r.h - 2) * pxScale), reverse)
  drawBitmap(inset(r, 1), b)
  box(r, if selected: th.text else: th.frame)
  if selected: box(inset(r, -1), th.text)

proc gradientEditBar*(key: string; stops: var seq[GradientStop]; sel: var int; w: int;
                      newColor = 0xFF000000'u32): bool {.discardable.} =
  ## The Gradient Editor's bar: the gradient, its stops under it (a click
  ## between them adds one, a drag moves one, dragging one well away takes
  ## it off), each pair's midpoint (a diamond) over it. `sel` is the stop
  ## picked (its color and place are set beside). True when it changed.
  let barH = dp(26)
  let stopH = dp(12)
  let r = place(w, dp(9) + barH + stopH + dp(4))
  beginKeepSides(r)               # (as it is in a right-to-left interface too)
  defer: endKeepSides()
  let id = idOf("gradedit:" & key)
  let hit = interact(id, r, focusable = false)
  if hit.down or ui.active == id: ui.dragsActive = true
  let bar = rect(r.x + dp(7), r.y + dp(9), r.w - dp(14), barH)
  template xOf(tt: float): int = bar.x + int(round(tt * (bar.w - 1).float))
  template tOf(px: int): float = clamp((px - bar.x).float / max(1, bar.w - 1).float, 0.0, 1.0)
  var st = state(id)
  if stops.len == 0:
    stops = @[GradientStop(at: 0, color: 0xFF000000'u32), GradientStop(at: 1, color: 0xFFFFFFFF'u32)]
  # the bar
  drawBitmap(bar, gradientStrip(stops, bar.w * pxScale, bar.h * pxScale))
  box(inset(bar, -1), th.frame)
  # the stops (sorted by place)
  proc order(s: var seq[GradientStop]; keep: var int) =
    let picked = if keep >= 0 and keep < s.len: s[keep] else: GradientStop(at: -1)
    s.sort(proc (a, b: GradientStop): int = cmp(a.at, b.at))
    if picked.at >= 0:
      for k, v in s:
        if v == picked:
          keep = k
          break
  if hit.down and ui.pressed:
    st.aux = 0
    # a midpoint, a stop, or a new stop
    if ui.my < bar.y:
      for k in 0 ..< stops.high:
        let m = if stops[k].mid <= 0.001: 0.5 else: stops[k].mid
        let mx = xOf(stops[k].at + (stops[k + 1].at - stops[k].at) * m)
        if abs(ui.mx - mx) <= dp(5):
          st.aux = 1000 + k
          sel = k
    else:
      var best = -1
      var bd = dp(7)
      for k, s0 in stops:
        let dd = abs(ui.mx - xOf(s0.at))
        if dd <= bd:
          bd = dd
          best = k
      if best >= 0:
        sel = best
        st.aux = best + 1
      elif ui.my >= bar.y + bar.h:
        let t = tOf(ui.mx)
        var c = gradientColor(stops, t)
        if newColor != 0: c = newColor.withAlpha(aOf(c))
        stops.add GradientStop(at: t, color: c)
        sel = stops.high
        order(stops, sel)
        st.aux = sel + 1
        result = true
  if ui.active == id and ui.mouseDown and st.aux > 0:
    if st.aux >= 1000:
      let k = st.aux - 1000
      if k < stops.high:
        let a = stops[k].at
        let b = stops[k + 1].at
        if b - a > 1e-6:
          let m = clamp((tOf(ui.mx) - a) / (b - a), 0.05, 0.95)
          if abs(m - stops[k].mid) > 1e-6:
            stops[k].mid = m
            result = true
    else:
      let k = st.aux - 1
      if k < stops.len:
        let t = tOf(ui.mx)
        if abs(t - stops[k].at) > 1e-6:
          stops[k].at = t
          result = true
        if result:
          sel = k
          order(stops, sel)
          st.aux = sel + 1
  if ui.released and st.aux > 0 and st.aux < 1000:
    # (pulled well away under the bar, with more than two: taken off)
    let k = st.aux - 1
    if ui.my > r.y + r.h + dp(24) and stops.len > 2 and k < stops.len:
      stops.delete(k)
      sel = min(sel, stops.high)
      result = true
  if ui.released: st.aux = 0
  state(id) = st
  # the stops: a house of their color, the picked one dark-roofed
  for k, s0 in stops:
    let x = xOf(s0.at)
    let y0 = bar.y + bar.h + 1
    let picked = k == sel
    for i in 0 .. dp(4):
      hline(x - i, y0 + i, 2 * i + 1, if picked: th.text else: th.face)
    let sq = rect(x - dp(5), y0 + dp(5), dp(11), dp(7))
    fill(sq, colorOf(s0.color or 0xFF000000'u32))
    box(sq, th.frame)
    line(x, y0, x - dp(5), y0 + dp(5), th.frame)
    line(x, y0, x + dp(5), y0 + dp(5), th.frame)
  # the midpoints
  for k in 0 ..< stops.high:
    let m = if stops[k].mid <= 0.001: 0.5 else: stops[k].mid
    let mx = xOf(stops[k].at + (stops[k + 1].at - stops[k].at) * m)
    let my = bar.y - dp(5)
    for i in 0 .. dp(3):
      hline(mx - i, my - dp(3) + i, 2 * i + 1, if k == sel: th.text else: th.gray)
      hline(mx - i, my + dp(3) - i, 2 * i + 1, if k == sel: th.text else: th.gray)

# ---- brushes, swatches -------------------------------------------------------------------------------------

proc brushGrid*(tips: seq[BrushTip]; sel: var int; w: int; cell = 0): tuple[changed, activated: bool] =
  ## The Brushes palette: a cell per brush (its dab, or its size in figures
  ## when it is too big to show), the chosen one framed. A double click
  ## reports `activated` (Brush Options).
  let c = if cell > 0: cell else: dp(26)
  let cols = max(1, w div c)
  let rows = max(1, (tips.len + cols - 1) div cols)
  let r = place(cols * c + 1, rows * c + 1)
  let id = idOf(sel, "brushes")
  let hit = interact(id, r)
  fill(r, th.window)
  for i, t in tips:
    let cr = rect(r.x + (i mod cols) * c, r.y + (i div cols) * c, c + 1, c + 1)
    box(cr, th.face)
    let room = c - dp(6)
    if t.custom.len > 0 or t.diameter <= room:
      let m = if t.custom.len > 0: tipMask(t, min(1.0, room.float / max(t.cw, t.ch).float)) else: tipMask(t)
      let b = newBitmap(m.w, m.h)
      for k, a in m.a: b.px[k] = argb(int(a * 255), 0, 0, 0)
      b.changed()
      drawBitmap(rect(cr.x + (c + 1 - m.w) div 2, cr.y + (c + 1 - m.h) div 2, m.w, m.h), b)
    else:
      let s = $t.diameter
      let small = style(size = 0.8)
      text(cr.x + (c + 1 - textWidth(s, small)) div 2, cr.y + (c + 1 - lineHeight(small)) div 2,
           s, th.text, small)
    if i == sel:
      box(inset(cr, 1), th.text)
    if hit.down and ui.pressed and mouseIn(cr):
      if sel != i: result.changed = true
      sel = i
      if ui.clicks >= 2: result.activated = true
  if hit.focused and canInput() and not ui.keyUsed:
    case ui.key
    of KeyLeft: sel = max(0, sel - 1); result.changed = true; ui.keyUsed = true
    of KeyRight: sel = min(tips.high, sel + 1); result.changed = true; ui.keyUsed = true
    of KeyUp: sel = max(0, sel - cols); result.changed = true; ui.keyUsed = true
    of KeyDown: sel = min(tips.high, sel + cols); result.changed = true; ui.keyUsed = true
    else: discard

type SwatchEvent* = object
  ## A click on the swatches: `pick` the index, `alt`/`shift`/`ctrl` held;
  ## `empty` a click after the last one (to add a color).
  pick*: int                 ## the swatch clicked (-1 none)
  empty*: bool               ## the click was after the last swatch
  alt*, shift*, ctrl*: bool  ## the keys held

proc swatchGrid*(colors: seq[uint32]; w: int; cell = 0): SwatchEvent =
  ## The Swatches palette: small squares of colors.
  result.pick = -1
  let c = if cell > 0: cell else: dp(11)
  let cols = max(1, w div c)
  let rows = max(1, (colors.len + cols) div cols)
  let r = place(cols * c, rows * c)
  let id = idOf("swatchgrid" & $colors.len)
  let hit = interact(id, r, focusable = false)
  fill(r, th.window)
  for i, col in colors:
    let cr = rect(r.x + (i mod cols) * c, r.y + (i div cols) * c, c, c)
    fill(inset(cr, 1), colorOf(col))
    if hit.clicked and mouseIn(cr): result.pick = i
  if hit.clicked and result.pick < 0: result.empty = true
  if hit.clicked:
    result.alt = AltPressed in ui.mods
    result.shift = ShiftPressed in ui.mods
    result.ctrl = CtrlPressed in ui.mods
  if hit.hover and canInput(): ui.cursor = curCrosshair

# ---- the foreground and background colors --------------------------------------------------------------------

type ColorPairEvent* = enum
  ## What was clicked in `colorPair`: nothing, the foreground square, the
  ## background square, the arrow that swaps them, the pair that resets them.
  cpNone, cpFg, cpBg, cpSwap, cpDefault

proc colorPair*(fg, bg: uint32; size: int): ColorPairEvent =
  ## The foreground square over the background one, the little arrow that
  ## swaps them and the small black-and-white pair that resets them.
  let r = place(size, size)
  let s = size * 3 div 5
  let fr = rect(r.x, r.y, s, s)
  let br = rect(r.x + size - s, r.y + size - s, s, s)
  let swapR = rect(r.x + s + 1, r.y, size - s - 1, size - s - 1)
  let defR = rect(r.x, r.y + s + 1, size - s - 1, size - s - 1)
  fill(br, colorOf(bg)); box(br, th.frame)
  box(inset(br, 1), th.window)
  fill(fr, colorOf(fg)); box(fr, th.frame)
  box(inset(fr, 1), th.window)
  # the swap arrow (a curve with two heads)
  let ax = swapR.x + 2
  let ay = swapR.y + 2
  let aw = swapR.w - 4
  hline(ax + 2, ay, aw - 4, th.text)
  vline(ax + aw - 1, ay + 2, aw - 4, th.text)
  line(ax + aw - 3, ay, ax + aw - 1, ay + 2, th.text)
  arrow(ax + 1, ay, dLeft, th.text, dp(2))
  arrow(ax + aw - 1, ay + aw - 2, dDown, th.text, dp(2))
  # the default pair
  let ds = defR.w * 3 div 5
  fill(rect(defR.x + defR.w - ds, defR.y + defR.h - ds, ds, ds), color(255, 255, 255))
  box(rect(defR.x + defR.w - ds, defR.y + defR.h - ds, ds, ds), th.text)
  fill(rect(defR.x, defR.y, ds, ds), color(0, 0, 0))
  for (rr, ev) in [(swapR, cpSwap), (defR, cpDefault), (fr, cpFg), (br, cpBg)]:
    let hit = interact(idOf("colorpair" & $ev), rr, focusable = false)
    if hit.clicked:
      return ev

# ---- rows of layers and channels ---------------------------------------------------------------------------------

type
  LayerRow* = object
    ## A row of the Layers or Channels palette.
    name*: string             ## the layer's or channel's name
    thumb*: Bitmap            ## its thumbnail
    visible*: bool            ## its eye is open
    active*: bool             ## the one painted on (selected)
    note*: string             ## at the right ("Ctrl+1")
    lock*: bool               ## shows the transparency kept (Preserve Transparency)
    icon*: string             ## a glyph before the thumbnail (an adjustment layer)
    maskThumb*: Bitmap        ## its mask, beside the thumbnail (nil: none)
    maskActive*: bool         ## the mask is what is painted (framed; a mask in the brush column)
    maskOff*: bool            ## the mask is not used (crossed out)
    thumbGlyph*: string       ## drawn in a white box in the thumbnail's place (a type layer's "T")
    fx*: bool                 ## it has a layer style (an "fx" mark at the right)
    fxOff*: bool              ## ... turned off (the mark grayed)
    clipped*: bool            ## in a clipping mask (set in, with a bent arrow)
    indent*: int              ## how deep in groups (set in so much)
    group*: bool              ## a group: a folder with a triangle that opens and closes it
    collapsed*: bool          ## ... closed
    picked*: bool             ## picked with others (highlighted too)
    locked*: bool             ## all locked (a padlock)
    linked*: bool             ## linked to other layers (a chain at the right)
  LayerRowsEvent* = object
    ## What happened in `layerRows` this frame.
    clicked*: int             ## the row clicked (-1 none)
    thumbClicked*: int        ## ... on its thumbnail (-1 none)
    maskClicked*: int         ## ... on its mask's thumbnail (-1 none)
    eyeToggled*: int          ## the eye clicked (-1 none)
    activated*: int           ## a double click (Options)
    fxClicked*: int           ## the "fx" mark clicked (-1 none)
    moved*: tuple[src, dst: int]   ## a row dragged elsewhere (-1, -1 none): `dst` the gap (0 over
                                   ## the top row); `into` a group row it was dropped on (-1 none)
    into*: int                ## the group row it was dropped on (-1 none)
    dropIndent*: int          ## how far right it was dropped: how deep it may go (in indents)
    toggled*: int             ## a group's triangle clicked (-1 none)
    clipAt*: int              ## Alt+click on the line under a row: that row clipped to
                              ## the one under it, or let go (-1 none)
    shift*, ctrl*, alt*: bool ## the keys held at the click

proc layerRows*(rows: seq[LayerRow]; w: int; rowH: int; key: string;
                brushColumn = false): LayerRowsEvent =
  ## Rows with an eye, a thumbnail and a name, the active one highlighted
  ## (the top row first: give them in the order shown). Dragging a row
  ## moves it. `brushColumn`: a second column with a paintbrush beside the
  ## row that painting goes to (the Layers palette of 1994).
  result = LayerRowsEvent(clicked: -1, eyeToggled: -1, activated: -1, moved: (-1, -1), thumbClicked: -1,
                          maskClicked: -1, fxClicked: -1, toggled: -1, into: -1, clipAt: -1)
  let indentW = dp(12)
  let eyeW = dp(20)
  let brushW = if brushColumn: dp(20) + 1 else: 0
  let r = place(w, max(rowH, rows.len * rowH))
  let id = idOf("layerrows:" & key)
  let hit = interact(id, r)
  if hit.down or ui.active == id: ui.dragsActive = true
  var st = state(id)
  fill(r, th.window)
  for i, row in rows:
    let rr = rect(r.x, r.y + i * rowH, r.w, rowH)
    let eye = rect(rr.x, rr.y, eyeW, rowH)
    fill(eye, th.face)
    vline(eye.x + eye.w, rr.y, rowH, th.shadow)
    if row.visible:
      image(eye.x + (eye.w - dp(16)) div 2, eye.y + (rowH - dp(16)) div 2, glyphIcon(pxEye, th.text, dp(16)))
    if brushColumn:
      let bc = rect(eye.x + eyeW + 1, rr.y, brushW - 1, rowH)
      fill(bc, th.face)
      vline(bc.x + bc.w, rr.y, rowH, th.shadow)
      if row.active:
        image(bc.x + (bc.w - dp(16)) div 2, bc.y + (rowH - dp(16)) div 2,
              glyphIcon(if row.maskActive: pxLayerMask else: pxBrush, th.text, dp(16)))
    let body = rect(eye.x + eyeW + 1 + brushW, rr.y, rr.w - eyeW - 1 - brushW, rowH)
    if row.active or row.picked: fill(body, th.select)
    let fg = if row.active or row.picked: th.selectText else: th.text
    var x = body.x + dp(3) + row.indent * indentW
    let th2 = rowH - dp(6)
    var thumbR, maskR, fxR, triR: Rect
    if row.group:
      # (a group: its triangle and its folder)
      triR = rect(x - dp(2), body.y, dp(14), rowH)
      arrow(x + dp(4), body.y + rowH div 2, (if row.collapsed: dRight else: dDown), fg, dp(4))
      x += dp(13)
      let fr = rect(x, body.y + dp(3), th2, th2)
      image(fr.x + (fr.w - dp(16)) div 2, fr.y + (fr.h - dp(16)) div 2,
            glyphIcon(if row.collapsed: pxFolder else: pxFolderOpen, fg, dp(16)))
      thumbR = rect(x, body.y, th2, rowH)
      x += th2 + dp(6)
    if row.clipped:
      image(x, body.y + (rowH - dp(16)) div 2, glyphIcon(pxClipLayer, fg, dp(16)))
      x += dp(17)
    if row.icon.len > 0:
      image(x, body.y + (rowH - dp(16)) div 2, glyphIcon(row.icon, fg, dp(16)))
      x += dp(19)
    if row.thumbGlyph.len > 0:
      # (a type layer: a "T" in a white box)
      let tr = rect(x, body.y + dp(3), th2, th2)
      fill(tr, color(255, 255, 255))
      box(inset(tr, -1), th.frame)
      let gs = max(dp(12), th2 - dp(4))
      image(tr.x + (tr.w - gs) div 2, tr.y + (tr.h - gs) div 2, glyphIcon(row.thumbGlyph, th.text, gs))
      if row.active and row.maskThumb != nil and not row.maskActive:
        box(inset(tr, -2), fg)
        box(inset(tr, -3), fg)
      thumbR = rect(x, body.y, th2, rowH)
      x += th2 + dp(6)
    for (bmp, isMask) in [(row.thumb, false), (row.maskThumb, true)]:
      if bmp == nil: continue
      if not isMask and row.thumbGlyph.len > 0: continue
      let k = min(th2 / bmp.w, th2 / bmp.h)
      let tw = max(1, int(bmp.w.float * k))
      let thh = max(1, int(bmp.h.float * k))
      let tr = rect(x + (th2 - tw) div 2, body.y + (rowH - thh) div 2, tw, thh)
      drawBitmap(tr, bmp)
      box(inset(tr, -1), th.frame)
      if isMask and row.maskOff:
        line(tr.x, tr.y, tr.x + tr.w - 1, tr.y + tr.h - 1, color(220, 0, 0))
        line(tr.x + tr.w - 1, tr.y, tr.x, tr.y + tr.h - 1, color(220, 0, 0))
      # (the one painted on, framed twice)
      if row.active and row.maskThumb != nil and isMask == row.maskActive:
        box(inset(tr, -2), fg)
        box(inset(tr, -3), fg)
      if isMask: maskR = rect(x, body.y, th2, rowH) else: thumbR = rect(x, body.y, th2, rowH)
      x += th2 + dp(6)
    var right = body.x + body.w - textWidth(row.note) - dp(4)
    let locks = row.lock or row.locked
    if locks: right -= dp(18)
    if row.fx:
      # the layer style's mark: "fx" (a click: its effects shown or not)
      let fw = dp(18)
      fxR = rect(right - fw, body.y, fw, rowH)
      let fst = style(bold = true, italic = true)
      text(fxR.x + (fw - textWidth("fx", fst)) div 2, body.y + (rowH - lineHeight(fst)) div 2, "fx",
           (if row.fxOff: th.gray else: fg), fst)
      right = fxR.x - dp(2)
    if row.linked:
      # (linked: a chain, as Photoshop marks it)
      right -= dp(16)
      image(right, body.y + (rowH - dp(14)) div 2, glyphIcon(nfLink, fg, dp(14)))
      right -= dp(2)
    text(x, body.y + (rowH - FontH) div 2, ellipsize(row.name, right - x - dp(4)), fg, row.active)
    if row.note.len > 0:
      text(body.x + body.w - textWidth(row.note) - dp(4), body.y + (rowH - FontH) div 2, row.note, fg)
    if locks:
      text(body.x + body.w - textWidth(row.note) - dp(22), body.y + (rowH - FontH) div 2, pxLock,
           (if row.locked: fg else: (if row.active or row.picked: th.selectText else: th.gray)))
    hline(rr.x, rr.y + rowH - 1, rr.w, th.face)
    if accessOn:
      # (a list item: its eye a check box in it; a press picks the layer)
      let lid = accessSubId(id, i)
      let eid = accessSubId(id, 0x10000 + i)
      if accessPress != 0 and accessPress == lid:
        accessPress = 0
        result.clicked = i
      if accessPress != 0 and accessPress == eid:
        accessPress = 0
        result.eyeToggled = i
      if i == 0: accessBegin(arList, "", r, accessSubId(id, 0x20000), takesLabel = true)
      let k = accessBegin(arListItem, row.name, rr, lid,
                          (if row.active or row.picked: {asSelected} else: {}) +
                          (if row.group: {asExpandable} else: {}) +
                          (if row.group and not row.collapsed: {asExpanded} else: {}))
      accessItem(k, i + 1, rows.len, row.indent + 1)
      if row.active and hit.focused: accessFocus(k)
      accessNode(arCheckBox, "Visible", id = eid, r = eye,
                 states = (if row.visible: {asChecked} else: {}))
      accessEnd()
      if i == rows.high: accessEnd()
    # Alt over the line between two rows: the clipping cursor; a click clips
    # the row over the line to the one under it (or lets it go)
    let seam = rect(body.x, rr.y + rowH - dp(4), body.w, dp(8))
    let onSeam = AltPressed in ui.mods and i < rows.len - 1 and mouseIn(seam) and canInput()
    if onSeam:
      ui.cursor = curSizeNS
      hline(body.x, rr.y + rowH - 1, body.w, th.text)
    if hit.down and ui.pressed and onSeam:
      result.clipAt = i
    elif hit.down and ui.pressed and mouseIn(rr):
      if mouseIn(eye): result.eyeToggled = i
      elif triR.w > 0 and mouseIn(triR): result.toggled = i
      else:
        result.clicked = i
        result.shift = ShiftPressed in ui.mods
        result.ctrl = CtrlPressed in ui.mods
        result.alt = AltPressed in ui.mods
        if maskR.w > 0 and mouseIn(maskR): result.maskClicked = i
        elif thumbR.w > 0 and mouseIn(thumbR): result.thumbClicked = i
        elif fxR.w > 0 and mouseIn(fxR): result.fxClicked = i
        st.aux = i + 1
        st.aux2 = ui.my
        if ui.clicks >= 2: result.activated = i
  # dragging a row: a line where it would go (set in as deep as it would
  # go), or a frame round the group it would go into
  template dropAt(): tuple[gap, into, indent: int] =
    let over = (ui.my - r.y) div rowH
    let inRow = (ui.my - r.y) mod rowH
    let src = st.aux - 1
    if over >= 0 and over < rows.len and rows[over].group and over != src and
       inRow > rowH div 4 and inRow < rowH - rowH div 4:
      (-1, over, 0)
    else:
      let gap = clamp((ui.my - r.y + rowH div 2) div rowH, 0, rows.len)
      let ind = max(0, (ui.mx - (r.x + eyeW + 1 + brushW + dp(3))) div indentW)
      (gap, -1, ind)
  if ui.active == id and ui.mouseDown and st.aux > 0 and abs(ui.my - st.aux2) > dp(6):
    let (gap, into, ind) = dropAt()
    if into >= 0:
      let fr = rect(r.x + eyeW + 1 + brushW, r.y + into * rowH, r.w - eyeW - 1 - brushW, rowH)
      box(fr, th.text)
      box(inset(fr, 1), th.text)
    else:
      # (as deep as the row over the gap allows, and the mouse says)
      var depth = 0
      if gap > 0:
        let up = rows[gap - 1]
        depth = if up.group and not up.collapsed: up.indent + 1 else: up.indent
      depth = min(depth, ind)
      let lx = r.x + eyeW + 1 + brushW + dp(3) + depth * indentW
      hline(lx, r.y + gap * rowH - 1, r.x + r.w - lx, th.text)
      hline(lx, r.y + gap * rowH, r.x + r.w - lx, th.text)
  if ui.released and st.aux > 0:
    if abs(ui.my - st.aux2) > dp(6):
      let (gap, into, ind) = dropAt()
      let src = st.aux - 1
      if into >= 0: result.moved = (src, -1)
      else: result.moved = (src, gap)
      result.into = into
      result.dropIndent = ind
    st.aux = 0
  state(id) = st

# ---- a picture fitted in a box ---------------------------------------------------------------------------------

proc pictureBox*(key: string; bmp: Bitmap; w, h: int; fit = true):
    tuple[box, pic: Rect; hit: Hit; dragging: bool] =
  ## A framed box `w` x `h` (logical pixels) with `bmp` in its middle:
  ## made as big as the box allows, its shape kept (`fit`), or shown 1:1 on
  ## the screen's pixels. `pic` is where it is drawn (for mapping the mouse
  ## to the picture); `hit` the mouse on the box; `dragging` while the
  ## mouse pressed on it is held (even outside it).
  let r = place(w + 2, h + 2)
  result.box = r
  let id = idOf("picturebox:" & key)
  result.hit = interact(id, r, focusable = false)
  result.dragging = ui.mouseDown and (result.hit.down or ui.active == id)
  if result.dragging: ui.dragsActive = true
  fill(inset(r, 1), th.face)
  box(r, th.frame)
  if bmp == nil or bmp.w <= 0 or bmp.h <= 0: return
  var bw = bmp.w.float / pxScale.float
  var bh = bmp.h.float / pxScale.float
  if fit:
    let k = min(w.float / bw, h.float / bh)
    bw *= k
    bh *= k
  let pw = max(1, int(bw))
  let ph = max(1, int(bh))
  result.pic = rect(r.x + 1 + (w - pw) div 2, r.y + 1 + (h - ph) div 2, pw, ph)
  pushClip(inset(r, 1))
  drawBitmap(result.pic, bmp)
  popClip()

proc toPicture*(pic: Rect; picW, picH: int; x, y: int): (float, float) =
  ## A point on the screen, in the pixels of a picture `picW` x `picH`
  ## drawn at `pic` (`pictureBox`).
  ((x - pic.x).float * picW.float / max(1, pic.w).float,
   (y - pic.y).float * picH.float / max(1, pic.h).float)

# ---- the anchor of Canvas Size ---------------------------------------------------------------------------------

proc anchorGrid*(ax, ay: var int; cell = 0): bool {.discardable.} =
  ## Nine squares: where the image stays when the canvas changes size.
  let c = if cell > 0: cell else: dp(24)
  let r = place(3 * c, 3 * c)
  for j in 0 .. 2:
    for i in 0 .. 2:
      let cr = rect(r.x + i * c, r.y + j * c, c, c)
      let hit = interact(idOf("anchor" & $i & $j), cr, focusable = false)
      buttonFace(cr, i == ax and j == ay, bevel = 1)
      if i == ax and j == ay:
        fill(inset(cr, c div 3), th.text)
      elif abs(i - ax) <= 1 and abs(j - ay) <= 1:
        let d = if i < ax: dLeft elif i > ax: dRight elif j < ay: dUp else: dDown
        arrow(cr.x + c div 2, cr.y + c div 2, d, th.gray, dp(4))
      if hit.clicked:
        ax = i
        ay = j
        result = true

# ---- the color picker on the canvas (Photoshop's HUD) ---------------------------------------------------------------

var hudSquare {.threadvar.}: tuple[hue: int; b: Bitmap]
var hudStrip {.threadvar.}: Bitmap

proc hudPickerRects*(cx, cy: int; area: Rect): tuple[square, strip: Rect] =
  ## Where the on-canvas color picker goes for a press at `cx`, `cy`: a
  ## square of saturation and brightness with the press at its middle, the
  ## strip of hues at its right -- moved to stay inside `area`.
  let s = if fingers(): dp(190) else: dp(150)
  let sw = if fingers(): dp(30) else: dp(20)
  let gap = dp(6)
  var x = cx - s div 2
  var y = cy - s div 2
  x = clamp(x, area.x + dp(2), max(area.x + dp(2), area.x + area.w - s - gap - sw - dp(2)))
  y = clamp(y, area.y + dp(2), max(area.y + dp(2), area.y + area.h - s - dp(2)))
  (rect(x, y, s, s), rect(x + s + gap, y, sw, s))

proc drawHudPicker*(square, strip: Rect; h, s, v: float) =
  ## The on-canvas color picker: the square for hue `h` (0..360), its mark
  ## at `s`, `v` (0..1); the hue strip, its mark at `h`.
  let hk = int(round(h)) mod 360
  if hudSquare.b == nil or hudSquare.hue != hk:
    const N = 64
    let b = newBitmap(N, N)
    for y in 0 ..< N:
      for x in 0 ..< N:
        b.px[y * N + x] = fromHsb(hk.float, x / (N - 1), 1 - y / (N - 1))
    b.changed()
    hudSquare = (hk, b)
  if hudStrip == nil:
    hudStrip = newBitmap(1, 180)
    for y in 0 ..< 180: hudStrip.px[y] = fromHsb(y.float * 2, 1, 1)
    hudStrip.changed()
  for r in [square, strip]:
    fill(inset(r, -3), ui.theme.face)
    box(inset(r, -3), ui.theme.frame)
  drawBitmap(square, hudSquare.b)
  drawBitmap(strip, hudStrip)
  box(square, ui.theme.frame)
  box(strip, ui.theme.frame)
  # the marks: a ring on the square, a bar on the strip
  let mx = square.x + int(s * (square.w - 1).float)
  let my = square.y + int((1 - v) * (square.h - 1).float)
  let ring = if fingers(): dp(7) else: dp(5)
  box(rect(mx - ring, my - ring, 2 * ring + 1, 2 * ring + 1), if v > 0.5: color(0, 0, 0) else: color(255, 255, 255))
  box(rect(mx - ring - 1, my - ring - 1, 2 * ring + 3, 2 * ring + 3), if v > 0.5: color(255, 255, 255) else: color(0, 0, 0))
  let hy = strip.y + int(h / 360 * (strip.h - 1).float)
  fill(rect(strip.x - dp(3), hy - 1, strip.w + dp(6), 3), color(0, 0, 0))
  hline(strip.x - dp(3), hy, strip.w + dp(6), color(255, 255, 255))
  # the color picked, beside
  let pr = rect(strip.x, square.y + square.h + dp(6), strip.w, strip.w)
  fill(pr, colorOf(fromHsb(h, s, v)))
  box(pr, ui.theme.frame)

proc hudPick*(square, strip: Rect; mx, my: int; h, s, v: var float; zone: var int): bool =
  ## The mouse at `mx`, `my` over the on-canvas color picker: the color it
  ## points at (`zone`: 0 not yet, 1 the square, 2 the strip -- kept while
  ## the button is held, so a drag past the edge still works). True when
  ## the color changed.
  if zone == 0:
    if square.contains(point(mx, my)): zone = 1
    elif strip.contains(point(mx, my)): zone = 2
  case zone
  of 1:
    let ns = clamp((mx - square.x) / max(1, square.w - 1), 0.0, 1.0)
    let nv = clamp(1 - (my - square.y) / max(1, square.h - 1), 0.0, 1.0)
    result = ns != s or nv != v
    s = ns
    v = nv
  of 2:
    let nh = clamp((my - strip.y) / max(1, strip.h - 1), 0.0, 1.0) * 359.9
    result = nh != h
    h = nh
  else: discard

## A world map for dashboards -- sales by country, branches, routes --
## that needs nothing from the network: the countries of Natural Earth
## (public domain, 1:50m, simplified) are built in (about 70 KB, linked
## only into apps that use the map).
##
## .. code-block:: nim
##   var world = MapState()
##   app "Sales", 900, 600:
##     let ev = mapView(world, values = [("OM", 120.0), ("AE", 340.0)],
##                      markers = [cityMarker("Muscat"), cityMarker("Dubai")])
##     if ev.clicked and ev.country >= 0: echo ev.name
##
## - countries colored by a value (`values`: ISO alpha-2 or alpha-3 codes
##   or names), with a legend; countries without one are gray
## - markers (`MapMarker`: a dot or a bubble with a label) and routes
##   (`MapRoute`: great-circle arcs)
## - drag (mouse or finger) to move, the wheel, a double click, the + / -
##   keys and the buttons in the corner to zoom; arrows move it and Home
##   shows the whole world while it has the focus
## - the country under the mouse is lit and named (with its value); a
##   click or a tap reports it (`MapEvent`)
## - `fitTo`, `zoomTo`, `resetView`; `countryName`, `countryCode`,
##   `latLonOf`, `cityMarker` for lookups
##
## The map is drawn into a picture of its own at the screen's resolution
## (anti-aliased, every border once) only when the view or the colors
## change; hovering and markers cost a few drawing commands a frame.

import std/[math, tables, strutils, hashes, algorithm]
import gfx, core, widgets, worlddata

template th: untyped = ui.theme

type
  MapProjection* = enum
    ## How the round world is laid flat.
    mpMercator     ## the web maps' projection: shapes kept, the poles stretched
    mpEquirect     ## longitude and latitude as they are (plate carrée)

  MapMarker* = object
    ## A point on the map: a dot, or a bubble as big as `size`.
    lat*, lon*: float    ## where (degrees; north and east positive)
    label*: string       ## shown beside it ("" none)
    size*: float         ## radius in design pixels (0: a small dot)
    color*: Color        ## (alpha 0: the theme's selection color)
    info*: string        ## shown when the mouse rests on it ("" the label)

  MapRoute* = object
    ## A line between two places, drawn along the great circle.
    fromLat*, fromLon*, toLat*, toLon*: float  ## where it starts and ends (degrees)
    color*: Color        ## (alpha 0: the theme's text color)
    width*: float        ## design pixels (0: 2)

  MapState* = object
    ## Where a `mapView` looks; keep one per map (a global).
    zoom*: float         ## 1 shows the whole world (0: not set yet)
    lat*, lon*: float    ## the middle of the view
    projection*: MapProjection  ## how the world is laid flat
    showAntarctica*: bool       ## draw Antarctica (it is left out by default)
    lowColor*, highColor*: Color   ## the value scale (alpha 0: the theme's)
    # what the view needs from frame to frame
    inited: bool
    view: Rect
    bmp: Bitmap
    key: uint64
    hover, hoverMarker, picked: int
    pressX, pressY, lastX, lastY: int
    moved: bool
    fitPending: seq[string]

  MapEvent* = object
    ## What happened in a `mapView` this frame.
    clicked*: bool       ## a click or tap (not a drag) on the map
    country*: int        ## the country clicked or under the mouse (-1: none)
    code*: string        ## its ISO 3166 alpha-3 code ("OMN"; "" if it has none)
    code2*: string       ## alpha-2 ("OM")
    name*: string        ## its name
    marker*: int         ## the marker clicked or under the mouse (-1: none)
    lat*, lon*: float    ## where the mouse is (or was clicked)
    moved*: bool         ## the view moved or zoomed

const
  MaxZoom = 48.0
  TopLat = 84.0          # the north end of the map
  SouthNoAnt = -58.0     # the south end without Antarctica
  MercLimit = 85.0511

# ---- the countries -------------------------------------------------------------------------

type World = object
  ready: bool
  pts: seq[float32]          # lon, lat of every point
  ringFirst: seq[int32]      # first point of each ring (WorldRings + 1)
  proj: MapProjection        # what `uv` and `boxUV` are projected for
  projReady: bool
  uv: seq[float32]           # the points projected: u (0..1 west to east), v (down)
  boxUV: seq[float32]        # each country's u0, v0, u1, v1
  index: Table[string, int]  # lower-case codes, names and other names

var world: World

proc decodeWorld() =
  if world.ready: return
  world.ready = true
  world.pts = newSeqOfCap[float32](60_000)
  world.ringFirst = newSeqOfCap[int32](WorldRings + 1)
  var p = 0
  template varint(): int =
    var v = 0
    var shift = 0
    while p < worldPts.len:
      let b = ord(worldPts[p])
      inc p
      v = v or ((b and 0x7F) shl shift)
      if b < 0x80: break
      shift += 7
    (v shr 1) xor -(v and 1)
  for r in 0 ..< WorldRings:
    p = int(worldRingOff[r])
    world.ringFirst.add int32(world.pts.len div 2)
    let n = varint()
    var x, y = 0
    for _ in 0 ..< n:
      x += varint()
      y += varint()
      world.pts.add float32(x) / WorldScale
      world.pts.add float32(y) / WorldScale
  world.ringFirst.add int32(world.pts.len div 2)
  # what lookups accept: codes, names and names people use
  for i in 0 ..< WorldCount:
    world.index[worldNames[i].toLowerAscii] = i
    let a2 = worldA2[2*i .. 2*i + 1]
    let a3 = worldA3[3*i .. 3*i + 2]
    if a2 != "--": world.index[a2.toLowerAscii] = i
    if a3 != "---": world.index[a3.toLowerAscii] = i
  for (alias, code) in [("usa", "us"), ("united states of america", "us"),
                        ("america", "us"), ("uk", "gb"), ("great britain", "gb"),
                        ("britain", "gb"), ("england", "gb"), ("uae", "ae"),
                        ("emirates", "ae"), ("ksa", "sa"), ("russian federation", "ru"),
                        ("turkey", "tr"), ("holland", "nl"), ("korea", "kr"),
                        ("czech republic", "cz"), ("ivory coast", "ci"),
                        ("swaziland", "sz"), ("burma", "mm"), ("macedonia", "mk"),
                        ("cape verde", "cv"), ("east timor", "tl"),
                        ("democratic republic of the congo", "cd"),
                        ("republic of the congo", "cg"), ("vatican city", "va")]:
    let i = world.index.getOrDefault(code, -1)
    if i >= 0: world.index[alias] = i

proc mercV(lat: float): float =
  let l = clamp(lat, -MercLimit, MercLimit) * PI / 180
  (1 - ln(tan(PI / 4 + l / 2)) / PI) / 2

proc projV(lat: float; p: MapProjection): float =
  case p
  of mpMercator: mercV(lat)
  of mpEquirect: (90 - lat) / 180

proc unprojV(v: float; p: MapProjection): float =
  case p
  of mpMercator: arctan(sinh(PI * (1 - 2 * v))) * 180 / PI
  of mpEquirect: 90 - v * 180

proc projectWorld(p: MapProjection) =
  decodeWorld()
  if world.projReady and world.proj == p: return
  world.proj = p
  world.projReady = true
  world.uv.setLen(world.pts.len)
  var i = 0
  while i < world.pts.len:
    world.uv[i] = float32((float(world.pts[i]) + 180) / 360)
    world.uv[i + 1] = float32(projV(float(world.pts[i + 1]), p))
    i += 2
  world.boxUV.setLen(WorldCount * 4)
  for c in 0 ..< WorldCount:
    var u0, v0 = 1e9'f32
    var u1, v1 = -1e9'f32
    for r in int(worldRingStart[c]) ..< int(worldRingStart[c + 1]):
      for k in world.ringFirst[r] ..< world.ringFirst[r + 1]:
        let u = world.uv[2 * k]
        let v = world.uv[2 * k + 1]
        u0 = min(u0, u); u1 = max(u1, u)
        v0 = min(v0, v); v1 = max(v1, v)
    world.boxUV[4*c] = u0
    world.boxUV[4*c + 1] = v0
    world.boxUV[4*c + 2] = u1
    world.boxUV[4*c + 3] = v1

proc countryCount*(): int = WorldCount
  ## How many countries the map has.

proc countryIndex*(codeOrName: string): int =
  ## The country with this ISO 3166 alpha-2 or alpha-3 code or name (case
  ## does not matter; "UAE", "USA", "UK" work too); -1 when there is none.
  decodeWorld()
  world.index.getOrDefault(codeOrName.strip.toLowerAscii, -1)

proc countryNameAt*(i: int): string =
  ## The name of country `i` ("" outside the range).
  if i in 0 ..< WorldCount: worldNames[i] else: ""

proc countryA2At*(i: int): string =
  ## The ISO alpha-2 code of country `i` ("" if it has none).
  if i notin 0 ..< WorldCount: return ""
  result = worldA2[2*i .. 2*i + 1]
  if result == "--": result = ""

proc countryA3At*(i: int): string =
  ## The ISO alpha-3 code of country `i` ("" if it has none).
  if i notin 0 ..< WorldCount: return ""
  result = worldA3[3*i .. 3*i + 2]
  if result == "---": result = ""

proc countryName*(code: string): string =
  ## The name of the country with this code (or other name); "" if none.
  countryNameAt(countryIndex(code))

proc countryCode*(name: string; alpha3 = true): string =
  ## The ISO code of the country called `name` (alpha-3, or alpha-2).
  let i = countryIndex(name)
  if alpha3: countryA3At(i) else: countryA2At(i)

proc latLonOf*(code: string): tuple[lat, lon: float] =
  ## A point well inside the country (for its label or a marker); (0, 0)
  ## when there is no such country.
  let i = countryIndex(code)
  if i < 0: return
  (float(worldLabel[2*i + 1]) / WorldScale, float(worldLabel[2*i]) / WorldScale)

proc cityLatLon*(name: string): tuple[found: bool; lat, lon: float] =
  ## One of the cities the map knows (capitals and business cities: Muscat,
  ## Dubai, London...); case does not matter.
  let n = name.strip.toLowerAscii
  for i in 0 ..< WorldCities:
    if worldCityNames[i].toLowerAscii == n:
      return (true, float(worldCityAt[2*i + 1]) / WorldScale,
              float(worldCityAt[2*i]) / WorldScale)

proc cityMarker*(name: string; label = "\0"; size = 0.0; color = Color();
                 info = ""): MapMarker =
  ## A marker at one of the cities the map knows (else at a country of that
  ## name or code), labeled with its name unless `label` is given.
  let c = cityLatLon(name)
  let (lat, lon) = if c.found: (c.lat, c.lon) else: latLonOf(name)
  MapMarker(lat: lat, lon: lon, label: (if label == "\0": name else: label),
            size: size, color: color, info: info)

# ---- the view ---------------------------------------------------------------------------------

proc southLat(m: MapState): float =
  if m.showAntarctica: (if m.projection == mpMercator: -MercLimit else: -90.0)
  else: SouthNoAnt

proc northLat(m: MapState): float =
  if m.showAntarctica and m.projection == mpEquirect: 90.0 else: TopLat

proc worldV(m: MapState): tuple[top, bottom: float] =
  (projV(m.northLat, m.projection), projV(m.southLat, m.projection))

proc baseScale(m: MapState; w, h: float): float =
  ## Pixels per unit of u at zoom 1: the whole map fits `w` x `h`.
  let (t, b) = worldV(m)
  min(w, h / max(1e-6, b - t))

proc resetView*(m: var MapState) =
  ## The whole world.
  m.zoom = 1
  m.lon = 0
  let (t, b) = worldV(m)
  m.lat = unprojV((t + b) / 2, m.projection)
  m.inited = true

proc zoomTo*(m: var MapState; lat, lon: float; zoom: float) =
  ## Centers the view on a place at a zoom (1: the whole world).
  if not m.inited: resetView(m)
  if not (lat - lat == 0 and lon - lon == 0 and zoom - zoom == 0): return
  m.lat = clamp(lat, -89.0, 89.0)
  m.lon = clamp(lon, -180.0, 180.0)
  m.zoom = clamp(zoom, 1.0, MaxZoom)

proc applyFit(m: var MapState; codes: openArray[string]) =
  projectWorld(m.projection)
  var u0, v0 = 1e9
  var u1, v1 = -1e9
  for c in codes:
    let i = countryIndex(c)
    if i < 0: continue
    u0 = min(u0, float(world.boxUV[4*i])); v0 = min(v0, float(world.boxUV[4*i + 1]))
    u1 = max(u1, float(world.boxUV[4*i + 2])); v1 = max(v1, float(world.boxUV[4*i + 3]))
  if u1 < u0: return
  let w = float(max(1, m.view.w))
  let h = float(max(1, m.view.h))
  let s0 = baseScale(m, w, h)
  let z = min(w / max(1e-6, (u1 - u0) * s0), h / max(1e-6, (v1 - v0) * s0)) * 0.85
  m.zoom = clamp(z, 1.0, MaxZoom)
  m.lon = (u0 + u1) / 2 * 360 - 180
  m.lat = unprojV((v0 + v1) / 2, m.projection)

proc fitTo*(m: var MapState; codes: openArray[string]) =
  ## Zooms the view onto these countries (codes or names). Before the map
  ## was first drawn, it happens when it is.
  if not m.inited: resetView(m)
  if m.view.w == 0: m.fitPending = @codes
  else: applyFit(m, codes)

type View = object
  s: float                   # device pixels per unit of u
  cu, cv: float              # the middle of the view, in u, v
  w, h: float                # device pixels

proc toScreen(v: View; u, vv: float): (float, float) {.inline.} =
  ((u - v.cu) * v.s + v.w / 2, (vv - v.cv) * v.s + v.h / 2)

proc fromScreen(v: View; x, y: float): (float, float) {.inline.} =
  ((x - v.w / 2) / v.s + v.cu, (y - v.h / 2) / v.s + v.cv)

proc finite(x: float): bool {.inline.} = x - x == 0.0
  ## Not NaN, not infinite.

proc clampView(m: var MapState; w, h: float) =
  ## Keeps the map on screen: centered where it is smaller than the view.
  if not (finite(m.zoom) and finite(m.lat) and finite(m.lon)):
    m.zoom = 1
    m.lat = 0
    m.lon = 0
  m.zoom = clamp(if m.zoom == 0: 1.0 else: m.zoom, 1.0, MaxZoom)
  let s = baseScale(m, w, h) * m.zoom
  let (t, b) = worldV(m)
  var cu = (m.lon + 180) / 360
  var cv = projV(m.lat, m.projection)
  let hw = w / 2 / s
  let hh = h / 2 / s
  cu = if 2 * hw >= 1: 0.5 else: clamp(cu, hw, 1 - hw)
  cv = if 2 * hh >= b - t: (t + b) / 2 else: clamp(cv, t + hh, b - hh)
  m.lon = cu * 360 - 180
  m.lat = unprojV(cv, m.projection)

proc viewOf(m: MapState; w, h: float): View =
  View(s: baseScale(m, w, h) * max(1.0, m.zoom), cu: (m.lon + 180) / 360,
       cv: projV(m.lat, m.projection), w: w, h: h)

proc mapPoint*(m: MapState; lat, lon: float): tuple[x, y: int] =
  ## Where a place is on screen in the map drawn last (logical pixels;
  ## for drawing your own things over it).
  let w = float(max(1, m.view.w * pxScale))
  let h = float(max(1, m.view.h * pxScale))
  let v = viewOf(m, w, h)
  let (x, y) = toScreen(v, (lon + 180) / 360, projV(lat, m.projection))
  (m.view.x + int(round(x / float(pxScale))), m.view.y + int(round(y / float(pxScale))))

proc mapLatLonAt*(m: MapState; x, y: int): tuple[lat, lon: float] =
  ## The place at a point of the screen in the map drawn last.
  let w = float(max(1, m.view.w * pxScale))
  let h = float(max(1, m.view.h * pxScale))
  let v = viewOf(m, w, h)
  let (u, vv) = fromScreen(v, float((x - m.view.x) * pxScale), float((y - m.view.y) * pxScale))
  (unprojV(vv, m.projection), u * 360 - 180)

# ---- drawing into the map's picture --------------------------------------------------------------

type Edge = object
  x0, y0, x1, y1, dxdy: float32

var
  edges: seq[Edge]
  active: seq[int32]
  cover: seq[float32]
  xs: seq[float32]

proc argb(c: Color): uint32 {.inline.} =
  0xFF000000'u32 or (uint32(c.r) shl 16) or (uint32(c.g) shl 8) or uint32(c.b)

proc mixPx(q: uint32; c: uint32; a: float32): uint32 {.inline.} =
  if a >= 0.998: return c
  let t = uint32(a * 256)
  let nt = 256'u32 - t
  let rb = (((q and 0xFF00FF'u32) * nt + (c and 0xFF00FF'u32) * t) shr 8) and 0xFF00FF'u32
  let g = (((q and 0x00FF00'u32) * nt + (c and 0x00FF00'u32) * t) shr 8) and 0x00FF00'u32
  0xFF000000'u32 or rb or g

proc fillEdges(b: Bitmap; color: uint32) =
  ## The shape made by `edges` (even-odd, so holes stay open), filled with
  ## anti-aliased borders: 4 rows of samples a pixel, exact across.
  if edges.len == 0: return
  var y0f = 1e9'f32
  var y1f = -1e9'f32
  for e in edges:
    y0f = min(y0f, e.y0)
    y1f = max(y1f, e.y1)
  let ya = max(0, int(floor(y0f)))
  let yb = min(b.h - 1, int(ceil(y1f)))
  if ya > yb: return
  if cover.len < b.w + 2: cover.setLen(b.w + 2)
  # the edges by where they start; those under the row being filled are
  # kept in `active`
  edges.sort(proc (a, b: Edge): int = cmp(a.y0, b.y0))
  active.setLen(0)
  var next = 0
  const Sub = 4
  while next < edges.len and edges[next].y1 <= float32(ya): inc next
  for y in ya .. yb:
    var lo = b.w
    var hi = -1
    for k in 0 ..< Sub:
      let sy = float32(y) + (float32(k) + 0.5) / Sub
      while next < edges.len and edges[next].y0 <= sy:
        active.add int32(next)
        inc next
      xs.setLen(0)
      var j = 0
      while j < active.len:
        let e = addr edges[active[j]]
        if e.y1 <= sy:
          active[j] = active[^1]
          active.setLen(active.len - 1)
          continue
        if sy >= e.y0: xs.add e.x0 + (sy - e.y0) * e.dxdy
        inc j
      if xs.len < 2: continue
      # few crossings: insertion sort
      for i in 1 ..< xs.len:
        let v = xs[i]
        var j = i - 1
        while j >= 0 and xs[j] > v:
          xs[j + 1] = xs[j]
          dec j
        xs[j + 1] = v
      var i = 0
      while i + 1 < xs.len:
        let a = clamp(xs[i], 0'f32, float32(b.w))
        let z = clamp(xs[i + 1], 0'f32, float32(b.w))
        i += 2
        if z <= a: continue
        let ia = int(a)
        let iz = int(z)
        lo = min(lo, ia)
        hi = max(hi, min(b.w - 1, iz))
        if ia == iz:
          cover[ia] += (z - a) / Sub
        else:
          cover[ia] += (float32(ia + 1) - a) / Sub
          for x in ia + 1 ..< iz: cover[x] += 1'f32 / Sub
          if iz < b.w: cover[iz] += (z - float32(iz)) / Sub
    if hi < lo: continue
    let row = y * b.w
    for x in lo .. hi:
      let a = min(1'f32, cover[x])
      cover[x] = 0
      if a > 0.004: b.px[row + x] = mixPx(b.px[row + x], color, a)

proc addRing(v: View; r: int) =
  let a = int(world.ringFirst[r])
  let n = int(world.ringFirst[r + 1]) - a
  if n < 3: return
  var (px, py) = toScreen(v, float(world.uv[2*(a + n - 1)]), float(world.uv[2*(a + n - 1) + 1]))
  for k in a ..< a + n:
    let (x, y) = toScreen(v, float(world.uv[2*k]), float(world.uv[2*k + 1]))
    if py != y:
      let (x0, y0, x1, y1) = if py < y: (px, py, x, y) else: (x, y, px, py)
      edges.add Edge(x0: float32(x0), y0: float32(y0), x1: float32(x1), y1: float32(y1),
                     dxdy: float32((x1 - x0) / (y1 - y0)))
    px = x
    py = y

proc wuLine(b: Bitmap; x0, y0, x1, y1: float; c: uint32; alpha: float32) =
  ## A thin anti-aliased line (Xiaolin Wu).
  var (x0, y0, x1, y1) = (x0, y0, x1, y1)
  let steep = abs(y1 - y0) > abs(x1 - x0)
  if steep:
    swap(x0, y0)
    swap(x1, y1)
  if x0 > x1:
    swap(x0, x1)
    swap(y0, y1)
  let dx = x1 - x0
  let g = if dx == 0: 1.0 else: (y1 - y0) / dx
  let xa = max(int(round(x0)), if steep: 0 else: 0)
  let xb = int(round(x1))
  var y = y0 + g * (float(xa) - x0)
  template plot(qx, qy: int; a: float) =
    let (ix, iy) = if steep: (qy, qx) else: (qx, qy)
    if ix >= 0 and iy >= 0 and ix < b.w and iy < b.h:
      let i = iy * b.w + ix
      b.px[i] = mixPx(b.px[i], c, float32(a) * alpha)
  let lim = if steep: b.h else: b.w
  for x in max(xa, -1) .. min(xb, lim):
    let fy = floor(y)
    let f = y - fy
    plot(x, int(fy), 1 - f)
    plot(x, int(fy) + 1, f)
    y += g

proc scaleColor(lo, hi: Color; t: float): Color = mixColor(lo, hi, clamp(t, 0.0, 1.0))

proc oceanColor(): Color =
  let l = int(th.field.r) + int(th.field.g) + int(th.field.b)
  if l > 384: mixColor(th.field, color(110, 160, 215), 0.32)
  else: mixColor(th.field, color(40, 80, 140), 0.45)

proc landColor(): Color = mixColor(th.face, th.field, 0.45)

proc renderMap(m: var MapState; v: View; dw, dh: int; vals: seq[float];
               lo, hi: float; loC, hiC: Color) =
  if m.bmp == nil or m.bmp.w != dw or m.bmp.h != dh:
    m.bmp = newBitmap(dw, dh)
  let b = m.bmp
  let ocean = argb(oceanColor())
  for p in b.px.mitems: p = ocean
  let land = landColor()
  let border = argb(mixColor(th.text, oceanColor(), 0.55))
  let span = max(1e-12, hi - lo)
  # the countries in view, large ones first (enclaves are drawn on top)
  var shown: seq[int]
  for c in 0 ..< WorldCount:
    if not m.showAntarctica and worldA3[3*c .. 3*c + 2] == "ATA": continue
    let (x0, y0) = toScreen(v, float(world.boxUV[4*c]), float(world.boxUV[4*c + 1]))
    let (x1, y1) = toScreen(v, float(world.boxUV[4*c + 2]), float(world.boxUV[4*c + 3]))
    if x1 < -2 or y1 < -2 or x0 > float(dw) + 2 or y0 > float(dh) + 2: continue
    shown.add c
    var col = land
    if c < vals.len and vals[c] == vals[c]:            # (not NaN: has a value)
      col = scaleColor(loC, hiC, (vals[c] - lo) / span)
    if c == m.hover: col = mixColor(col, th.select, 0.35)
    edges.setLen(0)
    for r in int(worldRingStart[c]) ..< int(worldRingStart[c + 1]): addRing(v, r)
    fillEdges(b, argb(col))
  # the borders, once each (thin, a little darker at larger zooms)
  let alpha = float32(clamp(0.55 + v.s / 9000, 0.55, 0.9))
  for c in shown:
    for r in int(worldRingStart[c]) ..< int(worldRingStart[c + 1]):
      let a = int(world.ringFirst[r])
      let n = int(world.ringFirst[r + 1]) - a
      if n < 2: continue
      var (px, py) = toScreen(v, float(world.uv[2*(a + n - 1)]), float(world.uv[2*(a + n - 1) + 1]))
      for k in a ..< a + n:
        let (x, y) = toScreen(v, float(world.uv[2*k]), float(world.uv[2*k + 1]))
        if not ((px < 0 and x < 0) or (py < 0 and y < 0) or
                (px > float(dw) and x > float(dw)) or (py > float(dh) and y > float(dh))):
          wuLine(b, px, py, x, y, border, alpha)
        px = x
        py = y
  if m.hover >= 0 and m.hover in shown:
    let sel = argb(th.select)
    for r in int(worldRingStart[m.hover]) ..< int(worldRingStart[m.hover + 1]):
      let a = int(world.ringFirst[r])
      let n = int(world.ringFirst[r + 1]) - a
      var (px, py) = toScreen(v, float(world.uv[2*(a + n - 1)]), float(world.uv[2*(a + n - 1) + 1]))
      for k in a ..< a + n:
        let (x, y) = toScreen(v, float(world.uv[2*k]), float(world.uv[2*k + 1]))
        wuLine(b, px, py, x, y, sel, 1)
        px = x
        py = y
  b.changed()

# ---- finding what is under the mouse -----------------------------------------------------------

proc insideCountry(c: int; u, vv: float): bool =
  if u < float(world.boxUV[4*c]) or u > float(world.boxUV[4*c + 2]) or
     vv < float(world.boxUV[4*c + 1]) or vv > float(world.boxUV[4*c + 3]): return false
  var inside = false
  for r in int(worldRingStart[c]) ..< int(worldRingStart[c + 1]):
    let a = int(world.ringFirst[r])
    let n = int(world.ringFirst[r + 1]) - a
    var j = a + n - 1
    for i in a ..< a + n:
      let xi = float(world.uv[2*i])
      let yi = float(world.uv[2*i + 1])
      let xj = float(world.uv[2*j])
      let yj = float(world.uv[2*j + 1])
      if (yi > vv) != (yj > vv) and u < (xj - xi) * (vv - yi) / (yj - yi) + xi:
        inside = not inside
      j = i
  inside

proc countryAt(m: MapState; u, vv: float): int =
  ## The country at u, v: the smallest one there (an enclave over the
  ## country around it).
  for c in countdown(WorldCount - 1, 0):
    if not m.showAntarctica and worldA3[3*c .. 3*c + 2] == "ATA": continue
    if insideCountry(c, u, vv): return c
  -1

proc countryAtLatLon*(lat, lon: float; projection = mpMercator): int =
  ## The country at a place on Earth (-1: the sea).
  projectWorld(projection)
  let m = MapState(projection: projection, showAntarctica: true)
  countryAt(m, (lon + 180) / 360, projV(lat, projection))

# ---- the widget -------------------------------------------------------------------------------

proc dpf(v: float): float = v * float(dp(1000)) / 1000
  ## `dp` for fractions.

proc fmtValue(v: float): string =
  ## 1234567 as "1,234,567"; 12.5 as "12.50".
  result = ""         # (a value at once: see tools/writecheck.py)
  if v != v: return
  let a = abs(v)
  if a >= 1e15: result = formatFloat(v, ffScientific, 3); return
  let whole = a == floor(a)
  let cents = int64(round(a * 100))
  let digits = $(cents div 100)
  for i, ch in digits:
    if i > 0 and (digits.len - i) mod 3 == 0: result.add ','
    result.add ch
  if not whole: result.add "." & align($(cents mod 100), 2, '0')
  if v < 0: result = "-" & result

proc zoomAt(m: var MapState; v: View; x, y: float; factor: float) =
  ## Zooms by `factor` keeping the point at device x, y where it is.
  let (u, vv) = fromScreen(v, x, y)
  let nz = clamp(m.zoom * factor, 1.0, MaxZoom)
  let s = v.s / m.zoom * nz
  let cu = u - (x - v.w / 2) / s
  let cv = vv - (y - v.h / 2) / s
  m.zoom = nz
  m.lon = cu * 360 - 180
  m.lat = unprojV(cv, m.projection)

proc mapView*(m: var MapState; height = -1;
              values: openArray[(string, float)] = [];
              markers: openArray[MapMarker] = [];
              routes: openArray[MapRoute] = [];
              legend = true; legendTitle = "";
              countryLabels = true; markerLabels = true;
              valueText: proc (v: float): string = nil;
              key = ""): MapEvent {.discardable.} =
  ## The world map, `height` pixels high (-1: the room left), as wide as
  ## the space it is in. `values` color the countries (ISO alpha-2 or
  ## alpha-3 codes, or names) from `lowColor` to `highColor`, with a legend;
  ## `markers` and `routes` are drawn over it. Drag to move it, the wheel,
  ## a double click, + / - (with the focus) or its buttons zoom; arrows
  ## move it and Home shows the whole world. The country and marker under
  ## the mouse are named; `clicked` reports a click or a tap.
  result.country = -1
  result.marker = -1
  let h = if height < 0: remainingH() else: height
  let r = place(0, max(dp(60), h), fill = true)
  # (a right-to-left interface does not mirror the map: west stays at the left)
  beginKeepSides(r)
  defer: endKeepSides()
  let id = idOf("mapview:" & key)
  m.view = r
  if not m.inited: resetView(m)
  projectWorld(m.projection)
  let dw = max(1, r.w * pxScale)
  let dh = max(1, r.h * pxScale)
  if m.fitPending.len > 0:
    applyFit(m, m.fitPending)
    m.fitPending.setLen(0)
  clampView(m, float(dw), float(dh))
  var v = viewOf(m, float(dw), float(dh))
  let before = (m.zoom, m.lat, m.lon)
  # the zoom buttons take their presses before the map does
  let bs = if fingers(): dp(30) else: dp(20)
  let zr = [rect(r.x + dp(6), r.y + dp(6), bs, bs),
            rect(r.x + dp(6), r.y + dp(6) + bs + dp(2), bs, bs),
            rect(r.x + dp(6), r.y + dp(6) + 2 * (bs + dp(2)), bs, bs)]
  var zhit: array[3, Hit]
  for k in 0 .. 2:
    zhit[k] = interact(id + uint32(10 + k), zr[k], focusable = false)
  let hit = interact(id, r)
  let center = (float(dw) / 2, float(dh) / 2)
  if zhit[0].clicked: zoomAt(m, v, center[0], center[1], 2)
  if zhit[1].clicked: zoomAt(m, v, center[0], center[1], 0.5)
  if zhit[2].clicked: resetView(m)
  let mx = float(ui.mx - r.x) * float(pxScale)
  let my = float(ui.my - r.y) * float(pxScale)
  if canInput():
    # the mouse: a drag moves the map; let go without moving, a click
    if ui.pressed and mouseIn(r):
      m.pressX = ui.mx
      m.pressY = ui.my
      m.lastX = ui.mx
      m.lastY = ui.my
      m.moved = false
      if ui.active == id and ui.clicks >= 2 and not finger():
        zoomAt(m, v, mx, my, 2)
        m.moved = true
    elif ui.active == id and ui.mouseDown and not finger():
      if abs(ui.mx - m.pressX) + abs(ui.my - m.pressY) > dp(4): m.moved = true
      if m.moved and (ui.mx != m.lastX or ui.my != m.lastY):
        let s = v.s
        let cu = (m.lon + 180) / 360 - float(ui.mx - m.lastX) * float(pxScale) / s
        let cv = projV(m.lat, m.projection) - float(ui.my - m.lastY) * float(pxScale) / s
        m.lon = cu * 360 - 180
        m.lat = unprojV(cv, m.projection)
        m.lastX = ui.mx
        m.lastY = ui.my
      ui.cursor = curHand
    # a finger: it drags the map both ways
    if (ui.panX != 0 or ui.panY != 0) and not ui.panUsed and r.contains(ui.panFrom):
      ui.panUsed = true
      m.moved = true
      let cu = (m.lon + 180) / 360 + float(ui.panX) * float(pxScale) / v.s
      let cv = projV(m.lat, m.projection) + float(ui.panY) * float(pxScale) / v.s
      m.lon = cu * 360 - 180
      m.lat = unprojV(cv, m.projection)
    if finger() and hit.clicked and ui.clicks >= 2: zoomAt(m, v, mx, my, 2)
    # the wheel zooms at the mouse
    if mouseIn(r) and ui.wheel != 0 and not ui.wheelUsed:
      ui.wheelUsed = true
      zoomAt(m, v, mx, my, pow(1.25, float(ui.wheel)))
    # keys, with the focus
    if hit.focused:
      let step = 0.125 / max(1.0, m.zoom)
      case ui.key
      of KeyLeft, KeyRight:
        m.lon += (if ui.key == KeyLeft: -360.0 else: 360.0) * step
        ui.keyUsed = true
      of KeyUp, KeyDown:
        let cv = projV(m.lat, m.projection) + (if ui.key == KeyUp: -1.0 else: 1.0) * step *
                 float(dh) / max(1.0, baseScale(m, float(dw), float(dh)))
        m.lat = unprojV(cv, m.projection)
        ui.keyUsed = true
      of KeyPlus, KeyEqual:
        if CtrlPressed notin ui.mods:
          zoomAt(m, v, center[0], center[1], 2)
          ui.keyUsed = true
      of KeyMinus:
        if CtrlPressed notin ui.mods:
          zoomAt(m, v, center[0], center[1], 0.5)
          ui.keyUsed = true
      of KeyHome:
        resetView(m)
        ui.keyUsed = true
      else: discard
  clampView(m, float(dw), float(dh))
  v = viewOf(m, float(dw), float(dh))
  result.moved = before != (m.zoom, m.lat, m.lon)
  # values: per country (NaN: none)
  var vals = newSeq[float](WorldCount)
  for x in vals.mitems: x = NaN
  var lo = Inf
  var hi = -Inf
  var vh = 0'u64
  for (code, val) in values:
    let i = countryIndex(code)
    if i >= 0 and finite(val):
      vals[i] = val
      lo = min(lo, val)
      hi = max(hi, val)
      vh = vh * 0x100000001B3'u64 + uint64(i) * 31 + cast[uint64](val)
  if hi < lo: (lo, hi) = (0.0, 1.0)
  let loC = if m.lowColor.a != 0: m.lowColor else: mixColor(th.field, th.select, 0.12)
  let hiC = if m.highColor.a != 0: m.highColor else: th.select
  # what the mouse is over (not while a drag moves the map)
  var markerAt = -1
  if (canHover() or finger()) and mouseIn(r) and not (ui.mouseDown and m.moved):
    let (u, vv) = fromScreen(v, mx, my)
    result.lon = u * 360 - 180
    result.lat = unprojV(vv, m.projection)
    for k in countdown(markers.high, 0):
      if not (finite(markers[k].lat) and finite(markers[k].lon) and finite(markers[k].size)):
        continue
      let (x, y) = toScreen(v, (markers[k].lon + 180) / 360, projV(markers[k].lat, m.projection))
      let rad = (dpf(if markers[k].size > 0: markers[k].size else: 4.0) + 3) * float(pxScale)
      if (x - mx) * (x - mx) + (y - my) * (y - my) <= rad * rad:
        markerAt = k
        break
    let c = if markerAt >= 0: -1 else: countryAt(m, u, vv)
    if canHover():
      m.hover = c
      m.hoverMarker = markerAt
  elif not mouseIn(r) and canHover():
    m.hover = -1
    m.hoverMarker = -1
  if finger() and hit.clicked:
    m.picked = m.hover
    let (u, vv) = fromScreen(v, mx, my)
    m.picked = if markerAt >= 0: -1 else: countryAt(m, u, vv)
    m.hoverMarker = markerAt
    m.hover = m.picked
  if hit.clicked and not m.moved:
    result.clicked = true
  result.marker = if markerAt >= 0: markerAt else: m.hoverMarker
  result.country = if result.marker >= 0: -1 else: m.hover
  if result.country >= 0:
    result.name = countryNameAt(result.country)
    result.code = countryA3At(result.country)
    result.code2 = countryA2At(result.country)
  # the picture, made again only when something in it changed
  var key = hash((dw, dh, ord(m.projection), m.showAntarctica)) !& hashF(m.zoom) !& hashF(m.lat) !& hashF(m.lon)
  key = key !& hash(vh) !& hash(m.hover) !& hashF(lo) !& hashF(hi)
  key = key !& hash((argb(th.field), argb(th.face), argb(th.select), argb(th.text)))
  key = key !& hash((argb(loC), argb(hiC)))
  let k64 = uint64(!$key)
  if k64 != m.key or m.bmp == nil:
    m.key = k64
    renderMap(m, v, dw, dh, vals, lo, hi, loC, hiC)
  drawBitmap(r, m.bmp)
  pushClip(r)
  let ps = float(pxScale)
  template scr(lat, lon: float): (float, float) =
    let (dx, dy) = toScreen(v, (lon + 180) / 360, projV(lat, m.projection))
    (float(r.x) + dx / ps, float(r.y) + dy / ps)
  # routes: great circles, split where they cross the date line
  for rt in routes:
    if not (finite(rt.fromLat) and finite(rt.fromLon) and finite(rt.toLat) and
            finite(rt.toLon)): continue
    let c = if rt.color.a != 0: rt.color else: th.text
    let wdt = dpf(if rt.width > 0: rt.width else: 2.0)
    let la1 = rt.fromLat * PI / 180
    let lo1 = rt.fromLon * PI / 180
    let la2 = rt.toLat * PI / 180
    let lo2 = rt.toLon * PI / 180
    let p1 = (cos(la1) * cos(lo1), cos(la1) * sin(lo1), sin(la1))
    let p2 = (cos(la2) * cos(lo2), cos(la2) * sin(lo2), sin(la2))
    let d = arccos(clamp(p1[0]*p2[0] + p1[1]*p2[1] + p1[2]*p2[2], -1.0, 1.0))
    let n = if d < 1e-9: 1 else: clamp(int(d * 40), 4, 64)
    var prev = scr(rt.fromLat, rt.fromLon)
    var prevLon = rt.fromLon
    for i in 1 .. n:
      let t = float(i) / float(n)
      var x, y, z: float
      if d < 1e-9: (x, y, z) = p2
      else:
        let a = sin((1 - t) * d) / sin(d)
        let b2 = sin(t * d) / sin(d)
        x = a * p1[0] + b2 * p2[0]
        y = a * p1[1] + b2 * p2[1]
        z = a * p1[2] + b2 * p2[2]
      let lat = arctan2(z, sqrt(x * x + y * y)) * 180 / PI
      let lon = arctan2(y, x) * 180 / PI
      let cur = scr(lat, lon)
      if abs(lon - prevLon) < 180:
        thickLine(prev[0], prev[1], cur[0], cur[1], wdt, c)
      prev = cur
      prevLon = lon
  # country names where they fit
  if countryLabels and m.zoom >= 1.5:
    var n = 0
    for c in 0 ..< WorldCount:
      if n >= 80: break
      if not m.showAntarctica and worldA3[3*c .. 3*c + 2] == "ATA": continue
      let (x0, y0) = toScreen(v, float(world.boxUV[4*c]), float(world.boxUV[4*c + 1]))
      let (x1, y1) = toScreen(v, float(world.boxUV[4*c + 2]), float(world.boxUV[4*c + 3]))
      let bw = (x1 - x0) / ps
      if (y1 - y0) / ps < float(FontH) * 1.5: continue
      let name = worldNames[c]
      let tw = textWidth(name)
      if bw < float(tw + dp(12)): continue
      let (lx, ly) = scr(float(worldLabel[2*c + 1]) / WorldScale, float(worldLabel[2*c]) / WorldScale)
      let tx = int(lx) - tw div 2
      let ty = int(ly) - FontH div 2
      if tx < r.x or ty < r.y or tx + tw > r.x + r.w or ty + FontH > r.y + r.h: continue
      # dark text on light countries, light on dark ones
      var fillC = landColor()
      if vals[c] == vals[c]:
        fillC = scaleColor(loC, hiC, (vals[c] - lo) / max(1e-12, hi - lo))
      let lum = 0.299 * float(fillC.r) + 0.587 * float(fillC.g) + 0.114 * float(fillC.b)
      text(tx, ty, name, if lum < 120: mixColor(th.window, fillC, 0.15)
                         else: mixColor(th.text, fillC, 0.25))
      inc n
  # markers (a label that would cover another goes to the other side, or is
  # left out: the tooltip still names the marker)
  var placed: seq[Rect]
  for mk in markers:                       # the dots themselves stay readable
    if finite(mk.lat) and finite(mk.lon) and finite(mk.size):
      let (x, y) = scr(mk.lat, mk.lon)
      let rad = dpf(if mk.size > 0: mk.size else: 4.0) + 1.5
      if abs(x) < 1e6 and abs(y) < 1e6:
        placed.add rect(int(x - rad), int(y - rad), int(2 * rad) + 1, int(2 * rad) + 1)
  for k, mk in markers:
    if not (finite(mk.lat) and finite(mk.lon) and finite(mk.size)): continue
    let (x, y) = scr(mk.lat, mk.lon)
    let rad = dpf(if mk.size > 0: mk.size else: 4.0)
    if x < float(r.x) - rad or y < float(r.y) - rad or x > float(r.x + r.w) + rad or
       y > float(r.y + r.h) + rad: continue
    let c = if mk.color.a != 0: mk.color else: th.select
    let lit = k == m.hoverMarker
    disc(x, y, rad + 1.5, th.window)
    disc(x, y, rad, if lit: mixColor(c, th.window, 0.3) else: c)
    ring(x, y, rad + 1.5, 1.2, mixColor(c, th.text, 0.5))
    if markerLabels and mk.label.len > 0:
      let tw = textWidth(mk.label, lit)
      let spots = [(int(x + rad) + dp(4), int(y) - FontH div 2),
                   (int(x - rad) - dp(4) - tw, int(y) - FontH div 2),
                   (int(x) - tw div 2, int(y - rad) - dp(2) - FontH),
                   (int(x) - tw div 2, int(y + rad) + dp(2))]
      var at = -1
      for i, (sx, sy) in spots:
        let lr = rect(sx - 1, sy - 1, tw + 2, FontH + 2)
        var free = true
        for q in placed:
          if q.x < lr.x + lr.w and lr.x < q.x + q.w and q.y < lr.y + lr.h and lr.y < q.y + q.h:
            free = false
            break
        if free:
          at = i
          placed.add lr
          break
      if at >= 0:
        let (tx, ty) = spots[at]
        for (ox, oy) in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
          text(tx + ox, ty + oy, mk.label, th.window)
        text(tx, ty, mk.label, th.text, lit)
  # the legend
  if legend and values.len > 0 and hi >= lo:
    let lw = min(dp(160), r.w div 3)
    let lh = dp(10)
    let pad = dp(6)
    let boxH = (if legendTitle.len > 0: FontH else: 0) + lh + FontH + pad * 2
    let lb = rect(r.x + pad, r.y + r.h - boxH - pad, lw + 2 * pad, boxH)
    fill(lb, mixColor(th.window, th.face, 0.3))
    box(lb, th.edge)
    var yy = lb.y + pad
    if legendTitle.len > 0:
      text(lb.x + pad, yy, legendTitle, th.text, true)
      yy += FontH
    let steps = 24
    for s in 0 ..< steps:
      let x0 = lb.x + pad + lw * s div steps
      let x1 = lb.x + pad + lw * (s + 1) div steps
      fill(rect(x0, yy, x1 - x0, lh), scaleColor(loC, hiC, (float(s) + 0.5) / float(steps)))
    box(rect(lb.x + pad, yy, lw, lh), th.edge)
    yy += lh + dp(2)
    let fmt = if valueText != nil: valueText else: fmtValue
    let a = fmt(lo)
    let b2 = fmt(hi)
    let small = style(size = 0.85)
    text(lb.x + pad, yy, a, th.text, small)
    text(lb.x + pad + lw - textWidth(b2, small), yy, b2, th.text, small)
  # the zoom buttons: + - and the whole world
  for k in 0 .. 2:
    let b = zr[k]
    buttonFace(b, zhit[k].down, rounded = false, bevel = 1, hot = hovered(b))
    let o = if zhit[k].down: 1 else: 0
    let cx = b.x + b.w div 2 + o
    let cy = b.y + b.h div 2 + o
    let a = max(3, b.w div 4)
    case k
    of 0:
      fill(rect(cx - a, cy - 1, 2 * a + 1, 2), th.text)
      fill(rect(cx - 1, cy - a, 2, 2 * a + 1), th.text)
    of 1: fill(rect(cx - a, cy - 1, 2 * a + 1, 2), th.text)
    else:
      box(rect(cx - a, cy - a, 2 * a + 1, 2 * a + 1), th.text)
      hline(cx - a, cy, 2 * a + 1, th.text)
      vline(cx, cy - a, 2 * a + 1, th.text)
  for k, t in ["Zoom in (+)", "Zoom out (-)", "The whole world (Home)"]:
    if canInput() and mouseIn(zr[k]): ui.tip = t
  # the name of what is under the mouse (or was tapped), with its value
  var tip = ""
  var tipAt = (ui.mx + dp(14), ui.my + dp(12))
  if m.hoverMarker >= 0 and m.hoverMarker < markers.len:
    let mk = markers[m.hoverMarker]
    tip = if mk.info.len > 0: mk.info else: mk.label
  elif m.hover >= 0:
    tip = worldNames[m.hover]
    if vals[m.hover] == vals[m.hover]:
      tip.add ": " & (if valueText != nil: valueText(vals[m.hover]) else: fmtValue(vals[m.hover]))
    if finger():
      let (lx, ly) = scr(float(worldLabel[2*m.hover + 1]) / WorldScale,
                         float(worldLabel[2*m.hover]) / WorldScale)
      tipAt = (int(lx), int(ly))
  if tip.len > 0 and (canHover() or finger()) and not (ui.mouseDown and m.moved):
    let tw = textWidth(tip) + dp(10)
    var tx = tipAt[0]
    var ty = tipAt[1]
    if tx + tw > r.x + r.w: tx = max(r.x, r.x + r.w - tw)
    if ty + FontH + dp(6) > r.y + r.h: ty = max(r.y, ty - FontH - dp(26))
    let tb = rect(tx, ty, tw, FontH + dp(6))
    fill(tb, th.tip)
    box(tb, th.edge)
    text(tb.x + dp(5), tb.y + dp(3), tip, th.tipText)
  popClip()
  box(r, th.edge)
  if hit.focused: focusDots(inset(r, 2))
  if accessOn:
    accessNode(arImage, "Map", id = id, r = r)
  ui.lastId = id
  ui.lastRect = r

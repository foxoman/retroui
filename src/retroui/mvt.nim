## Vector map tiles (Mapbox Vector Tiles, `.mvt` / `.pbf`: what MapTiler,
## Mapbox, Protomaps, OpenFreeMap, Azure Maps and an MBTiles or PMTiles
## file of OpenMapTiles hold): read, and drawn into a picture with a style
## -- water, land, parks, roads by their kind, railways, buildings,
## borders -- with the names of places and roads as labels the map draws
## over the tiles (upright, and never over each other).
##
## .. code-block:: nim
##   let t = decodeMvt(readFile("14-10342-7065.pbf"))
##   for l in t: echo l.name, " ", l.features.len
##   let pic = renderMvt(t, zoom = 14, size = 512, style = classicStyle())
##
## A style (`VectorStyle`) is a list of rules: which features of which
## layer (by the values of their properties) are drawn how, from which
## zoom on. `classicStyle` and `darkStyle` draw the three common schemas:
## OpenMapTiles (MapTiler, OpenFreeMap), Protomaps' and Mapbox Streets'.
## Only what the kit draws is used of a feature; nothing is drawn of a
## layer no rule names.
##
## Everything here is pure computation: it runs on any thread (the map
## draws its tiles in the background).

import std/[math, strutils]
import gfx, raster, codec

type
  MvtValueKind* = enum mvNone, mvString, mvFloat, mvInt, mvBool
  MvtValue* = object
    case kind*: MvtValueKind
    of mvString: s*: string
    of mvFloat: f*: float
    of mvInt: i*: int64
    of mvBool: b*: bool
    of mvNone: discard

  MvtGeom* = enum mgUnknown, mgPoint, mgLine, mgPolygon

  MvtFeature* = object
    id*: uint64
    kind*: MvtGeom
    tags*: seq[uint32]          ## key index, value index, ...
    parts*: seq[seq[(float32, float32)]]   ## points, lines, or rings (tile units: 0 .. extent)

  MvtLayer* = object
    name*: string
    extent*: int                ## the tile's size in its own units (4096)
    keys*: seq[string]
    values*: seq[MvtValue]
    features*: seq[MvtFeature]

  MvtTile* = seq[MvtLayer]

  MvtError* = object of CatchableError

proc bad(why: string) {.noreturn.} = raise newException(MvtError, "vector tile: " & why)

# ---- protocol buffers ---------------------------------------------------------------

type Pb = object
  s: ptr UncheckedArray[char]
  pos, stop: int

proc varint(p: var Pb): uint64 =
  var shift = 0
  while true:
    if p.pos >= p.stop: bad("cut short")
    let b = uint8(p.s[p.pos])
    inc p.pos
    result = result or (uint64(b and 0x7F) shl shift)
    if (b and 0x80) == 0: return
    shift += 7
    if shift > 63: bad("a number too long")

proc skip(p: var Pb; wire: int) =
  case wire
  of 0: discard p.varint()
  of 1: p.pos += 8
  of 2:
    let n = p.varint()
    if n > uint64(p.stop - p.pos): bad("cut short")
    p.pos += int(n)
  of 5: p.pos += 4
  else: bad("a field of an unknown kind")
  if p.pos > p.stop: bad("cut short")

proc sub(p: var Pb): Pb =
  let n = p.varint()
  if n > uint64(p.stop - p.pos): bad("cut short")
  result = Pb(s: p.s, pos: p.pos, stop: p.pos + int(n))
  p.pos += int(n)

proc str(p: var Pb): string =
  var q = p.sub()
  result = newString(q.stop - q.pos)
  if result.len > 0: copyMem(addr result[0], addr q.s[q.pos], result.len)

proc packed(p: var Pb; into: var seq[uint32]) =
  var q = p.sub()
  while q.pos < q.stop: into.add uint32(q.varint() and 0xFFFFFFFF'u64)

proc zigzag(v: uint32): int32 {.inline.} = cast[int32]((v shr 1) xor (not (v and 1) + 1))

proc fixed32(p: var Pb): uint32 =
  if p.pos + 4 > p.stop: bad("cut short")
  for k in 0 .. 3: result = result or (uint32(uint8(p.s[p.pos + k])) shl (8 * k))
  p.pos += 4

proc fixed64(p: var Pb): uint64 =
  if p.pos + 8 > p.stop: bad("cut short")
  for k in 0 .. 7: result = result or (uint64(uint8(p.s[p.pos + k])) shl (8 * k))
  p.pos += 8

# ---- gzip ------------------------------------------------------------------------------

proc gunzip*(data: string): string =
  ## `data` unpacked when it is gzip's (tiles are often stored so), else as
  ## it is.
  if data.len < 18 or data[0] != '\x1f' or data[1] != '\x8b': return data
  let flags = uint8(data[3])
  var at = 10
  if (flags and 4) != 0:
    if at + 2 > data.len: bad("gzip cut short")
    at += 2 + (ord(data[at]) or (ord(data[at + 1]) shl 8))
  if (flags and 8) != 0:
    while at < data.len and data[at] != '\0': inc at
    inc at
  if (flags and 16) != 0:
    while at < data.len and data[at] != '\0': inc at
    inc at
  if (flags and 2) != 0: at += 2
  if at >= data.len: bad("gzip cut short")
  let o = try: inflate(toOpenArrayByte(data, 0, data.high), at, maxOut = 64 shl 20)
          except CatchableError: bad("gzip damaged")
  result = newString(o.len)
  if o.len > 0: copyMem(addr result[0], unsafeAddr o[0], o.len)

# ---- reading a tile ----------------------------------------------------------------

proc geometry(cmds: seq[uint32]; kind: MvtGeom): seq[seq[(float32, float32)]] =
  var x, y = 0'i32
  var i = 0
  var cur: seq[(float32, float32)]
  while i < cmds.len:
    let c = cmds[i]
    inc i
    let id = c and 7
    let count = int(c shr 3)
    case id
    of 1, 2:                               # MoveTo, LineTo
      if id == 1 and cur.len > 0 and kind != mgPoint:
        result.add cur
        cur = @[]
      for _ in 0 ..< count:
        if i + 2 > cmds.len: return
        x += zigzag(cmds[i])
        y += zigzag(cmds[i + 1])
        i += 2
        if kind == mgPoint: result.add @[(float32(x), float32(y))]
        else: cur.add (float32(x), float32(y))
    of 7:                                  # ClosePath
      if cur.len > 0:
        cur.add cur[0]
        result.add cur
        cur = @[]
    else: return
  if cur.len > 0: result.add cur

proc decodeMvt*(data: string): MvtTile =
  ## The layers of a vector tile (gzip's or not); `MvtError` when it is not
  ## one.
  let d = gunzip(data)
  if d.len == 0: return
  var p = Pb(s: cast[ptr UncheckedArray[char]](unsafeAddr d[0]), pos: 0, stop: d.len)
  while p.pos < p.stop:
    let key = p.varint()
    let field = int(key shr 3)
    let wire = int(key and 7)
    if field == 3 and wire == 2:
      var lp = p.sub()
      var l = MvtLayer(extent: 4096)
      while lp.pos < lp.stop:
        let k = lp.varint()
        let f = int(k shr 3)
        let w = int(k and 7)
        case f
        of 1:
          if w != 2: bad("a layer's name")
          l.name = lp.str()
        of 2:
          if w != 2: bad("a feature")
          var fp = lp.sub()
          var feat = MvtFeature()
          var cmds: seq[uint32]
          while fp.pos < fp.stop:
            let fk = fp.varint()
            case int(fk shr 3)
            of 1: feat.id = fp.varint()
            of 2:
              if int(fk and 7) == 2: fp.packed(feat.tags)
              else: feat.tags.add uint32(fp.varint() and 0xFFFFFFFF'u64)
            of 3: feat.kind = MvtGeom(min(3'u64, fp.varint()))
            of 4:
              if int(fk and 7) == 2: fp.packed(cmds)
              else: cmds.add uint32(fp.varint() and 0xFFFFFFFF'u64)
            else: fp.skip(int(fk and 7))
          feat.parts = geometry(cmds, feat.kind)
          l.features.add feat
        of 3:
          if w != 2: bad("a key")
          l.keys.add lp.str()
        of 4:
          if w != 2: bad("a value")
          var vp = lp.sub()
          var v = MvtValue(kind: mvNone)
          while vp.pos < vp.stop:
            let vk = vp.varint()
            case int(vk shr 3)
            of 1: v = MvtValue(kind: mvString, s: vp.str())
            of 2: v = MvtValue(kind: mvFloat, f: float(cast[float32](vp.fixed32())))
            of 3: v = MvtValue(kind: mvFloat, f: cast[float64](vp.fixed64()))
            of 4: v = MvtValue(kind: mvInt, i: cast[int64](vp.varint()))
            of 5: v = MvtValue(kind: mvInt, i: cast[int64](vp.varint()))
            of 6:
              let u = vp.varint()
              v = MvtValue(kind: mvInt, i: cast[int64]((u shr 1) xor (not (u and 1) + 1)))
            of 7: v = MvtValue(kind: mvBool, b: vp.varint() != 0)
            else: vp.skip(int(vk and 7))
          l.values.add v
        of 5: l.extent = max(1, int(min(1'u64 shl 20, lp.varint())))
        of 15: discard lp.varint()
        else: lp.skip(w)
      result.add l
    else:
      p.skip(wire)

proc `$`*(v: MvtValue): string =
  case v.kind
  of mvString: v.s
  of mvFloat: (if v.f == floor(v.f) and abs(v.f) < 1e15: $int64(v.f) else: $v.f)
  of mvInt: $v.i
  of mvBool: $v.b
  of mvNone: ""

proc prop*(l: MvtLayer; f: MvtFeature; key: string): string =
  ## The value of `key` for feature `f`, as text ("" not there).
  var i = 0
  while i + 1 < f.tags.len:
    let k = int(f.tags[i])
    if k < l.keys.len and l.keys[k] == key:
      let v = int(f.tags[i + 1])
      return if v < l.values.len: $l.values[v] else: ""
    i += 2
  ""

# ---- styles ----------------------------------------------------------------------------

type
  VectorRule* = object
    ## How features of a layer are drawn.
    layers*: seq[string]               ## the tile's layers it is for ("water"; any of them)
    key*: string                       ## the property it looks at ("class"; "" every feature)
    values*: seq[string]               ## ... the values it takes ([] any)
    minZoom*, maxZoom*: int            ## from, to (0, 0: always)
    fill*: Color                       ## areas: their color (alpha 0: not filled)
    line*: Color                       ## lines (and outlines): their color (alpha 0: none)
    width*: float                      ## a line's width at zoom 15, in pixels of a 256-pixel tile
    minWidth*: float                   ## (thinnest it gets; 0: half a pixel)
    dash*: bool                        ## a dashed line (paths, borders)
    label*: string                     ## the property shown as a label ("name"; "" none)
    labelSize*: int                    ## 0 small, 1 normal, 2 large, 3 largest (cities)
    labelColor*: Color
    priority*: int                     ## which labels win the room (higher first)

  VectorStyle* = object
    ## A style: the color under everything and the rules, drawn in order.
    background*: Color
    rules*: seq[VectorRule]
    labelHalo*: Color                  ## around the labels' letters

  TileLabel* = object
    ## A name the map draws over a tile.
    x*, y*: float32                    ## where (pixels of the tile picture)
    text*: string
    size*: int                         ## as `VectorRule.labelSize`
    color*: Color
    priority*: int

proc rgb(s: string): Color =
  ## "#rrggbb"
  let h = s.strip(chars = {'#'})
  if h.len != 6: return color(0, 0, 0)
  color(uint8(parseHexInt(h[0 .. 1])), uint8(parseHexInt(h[2 .. 3])), uint8(parseHexInt(h[4 .. 5])))

proc rule(layers: openArray[string]; key = ""; values: openArray[string] = []; fill = "";
          line = ""; width = 0.0; minZoom = 0; maxZoom = 0; dash = false; label = "";
          labelSize = 1; labelColor = ""; priority = 0; minWidth = 0.0): VectorRule =
  VectorRule(layers: @layers, key: key, values: @values, minZoom: minZoom, maxZoom: maxZoom,
             fill: (if fill.len > 0: rgb(fill) else: Color()),
             line: (if line.len > 0: rgb(line) else: Color()),
             width: width, minWidth: minWidth, dash: dash, label: label, labelSize: labelSize,
             labelColor: (if labelColor.len > 0: rgb(labelColor) else: color(40, 40, 40)),
             priority: priority)

type Palette = object
  bg, water, waterLine, land, park, wood, residential, industrial, sand, ice, building,
    motorway, trunk, primary, secondary, minor, path, rail, border, casing, text, waterText: string

proc styleOf(c: Palette): VectorStyle =
  ## The three common schemas, drawn alike: OpenMapTiles (`class`), Protomaps
  ## (`kind`) and Mapbox Streets (`class`, its layers named otherwise).
  let land = ["landuse", "landcover", "landuse_overlay", "park"]
  result.background = rgb(c.bg)
  result.labelHalo = rgb(c.bg)
  var r: seq[VectorRule]
  r.add rule(["earth"], fill = c.bg)
  r.add rule(land, "class", ["residential", "suburb", "neighbourhood"], fill = c.residential)
  r.add rule(["landuse"], "kind", ["residential", "neighbourhood"], fill = c.residential)
  r.add rule(land, "class", ["industrial", "commercial", "retail", "railway"], fill = c.industrial)
  r.add rule(["landuse"], "kind", ["industrial", "commercial", "retail"], fill = c.industrial)
  r.add rule(land, "class", ["wood", "forest", "scrub"], fill = c.wood)
  r.add rule(["landuse", "landcover"], "kind", ["forest", "wood", "scrub"], fill = c.wood)
  r.add rule(land, "class", ["grass", "park", "pitch", "garden", "cemetery", "golf_course",
                             "national_park", "nature_reserve", "playground", "farmland", "meadow"],
             fill = c.park)
  r.add rule(["landuse", "landcover"], "kind", ["park", "grass", "garden", "cemetery", "golf_course",
                                                "national_park", "nature_reserve", "farmland", "meadow"],
             fill = c.park)
  r.add rule(["park"], fill = c.park)
  r.add rule(land, "class", ["sand", "beach", "desert"], fill = c.sand)
  r.add rule(["landuse", "landcover"], "kind", ["sand", "beach", "barren"], fill = c.sand)
  r.add rule(land, "class", ["ice", "glacier"], fill = c.ice)
  r.add rule(["water", "ocean"], fill = c.water)
  r.add rule(["waterway"], line = c.waterLine, width = 1.5, minZoom = 9)
  r.add rule(["aeroway"], "class", ["runway"], line = c.minor, width = 8, minZoom = 11)
  r.add rule(["building", "buildings"], fill = c.building, minZoom = 13)
  r.add rule(["boundary", "admin", "boundaries"], "admin_level", ["2"], line = c.border, width = 1.2,
             dash = true)
  r.add rule(["boundaries"], "kind", ["country"], line = c.border, width = 1.2, dash = true)
  r.add rule(["boundary", "admin"], "admin_level", ["3", "4"], line = c.border, width = 0.7,
             dash = true, minZoom = 4)
  r.add rule(["boundaries"], "kind", ["region"], line = c.border, width = 0.7, dash = true, minZoom = 4)
  # roads: the casing under, the color over; minor ones first
  let roads = ["transportation", "road", "roads"]
  r.add rule(roads, "class", ["path", "track", "pedestrian", "footway", "cycleway"], line = c.path,
             width = 1, dash = true, minZoom = 14)
  r.add rule(["roads"], "kind", ["path"], line = c.path, width = 1, dash = true, minZoom = 14)
  r.add rule(roads, "class", ["rail", "transit"], line = c.rail, width = 1.2, minZoom = 10)
  r.add rule(["roads"], "kind", ["rail"], line = c.rail, width = 1.2, minZoom = 10)
  r.add rule(["transit"], "kind", ["rail"], line = c.rail, width = 1.2, minZoom = 10)
  r.add rule(roads, "class", ["minor", "service", "street", "street_limited", "residential",
                              "unclassified", "living_street"], line = c.casing, width = 6, minZoom = 13)
  r.add rule(["roads"], "kind", ["minor_road"], line = c.casing, width = 6, minZoom = 13)
  r.add rule(roads, "class", ["minor", "service", "street", "street_limited", "residential",
                              "unclassified", "living_street"], line = c.minor, width = 4.5, minZoom = 13)
  r.add rule(["roads"], "kind", ["minor_road"], line = c.minor, width = 4.5, minZoom = 13)
  r.add rule(roads, "class", ["secondary", "tertiary", "secondary_link", "tertiary_link"],
             line = c.casing, width = 8, minZoom = 9)
  r.add rule(["roads"], "kind", ["medium_road"], line = c.casing, width = 8, minZoom = 9)
  r.add rule(roads, "class", ["secondary", "tertiary", "secondary_link", "tertiary_link"],
             line = c.secondary, width = 6.5, minZoom = 9)
  r.add rule(["roads"], "kind", ["medium_road"], line = c.secondary, width = 6.5, minZoom = 9)
  r.add rule(roads, "class", ["primary", "primary_link", "trunk", "trunk_link"], line = c.casing,
             width = 9, minZoom = 6)
  r.add rule(["roads"], "kind", ["major_road"], line = c.casing, width = 9, minZoom = 6)
  r.add rule(roads, "class", ["primary", "primary_link"], line = c.primary, width = 7.5, minZoom = 6)
  r.add rule(roads, "class", ["trunk", "trunk_link"], line = c.trunk, width = 7.5, minZoom = 5)
  r.add rule(["roads"], "kind", ["major_road"], line = c.primary, width = 7.5, minZoom = 6)
  r.add rule(roads, "class", ["motorway", "motorway_link"], line = c.casing, width = 10, minZoom = 4)
  r.add rule(["roads"], "kind", ["highway"], line = c.casing, width = 10, minZoom = 4)
  r.add rule(roads, "class", ["motorway", "motorway_link"], line = c.motorway, width = 8.5, minZoom = 4,
             minWidth = 0.8)
  r.add rule(["roads"], "kind", ["highway"], line = c.motorway, width = 8.5, minZoom = 4, minWidth = 0.8)
  # names
  r.add rule(["transportation_name", "road"], label = "name", labelSize = 0, labelColor = c.text,
             minZoom = 14, priority = 1)
  r.add rule(["roads"], "kind", ["highway", "major_road", "medium_road", "minor_road"], label = "name",
             labelSize = 0, labelColor = c.text, minZoom = 14, priority = 1)
  r.add rule(["water_name", "natural_label"], label = "name", labelSize = 1, labelColor = c.waterText,
             priority = 2)
  r.add rule(["place", "place_label", "places"], "class", ["country"], label = "name", labelSize = 2,
             labelColor = c.text, maxZoom = 7, priority = 9)
  r.add rule(["places"], "kind", ["country"], label = "name", labelSize = 2, labelColor = c.text,
             maxZoom = 7, priority = 9)
  r.add rule(["place", "place_label"], "class", ["city", "settlement"], label = "name", labelSize = 3,
             labelColor = c.text, priority = 8)
  r.add rule(["places"], "kind", ["locality"], label = "name", labelSize = 2, labelColor = c.text, priority = 7)
  r.add rule(["place", "place_label"], "class", ["town", "state"], label = "name", labelSize = 2,
             labelColor = c.text, minZoom = 6, priority = 6)
  r.add rule(["place", "place_label"], "class", ["village", "suburb", "settlement_subdivision"],
             label = "name", labelSize = 1, labelColor = c.text, minZoom = 10, priority = 4)
  r.add rule(["places"], "kind", ["neighbourhood", "macrohood"], label = "name", labelSize = 1,
             labelColor = c.text, minZoom = 12, priority = 4)
  r.add rule(["place", "place_label"], "class", ["hamlet", "neighbourhood", "quarter", "locality"],
             label = "name", labelSize = 0, labelColor = c.text, minZoom = 13, priority = 3)
  result.rules = r

proc classicStyle*(): VectorStyle =
  ## A light map in the colors of paper maps.
  styleOf(Palette(bg: "#f2efe9", water: "#a0c8f0", waterLine: "#8ab4e0", land: "#f2efe9",
                  park: "#c8e0b0", wood: "#b0d098", residential: "#e8e4dc", industrial: "#e6dcd8",
                  sand: "#f0e6c0", ice: "#ffffff", building: "#d9d0c9", motorway: "#e892a2",
                  trunk: "#f9b29c", primary: "#fcd6a4", secondary: "#f7fabf", minor: "#ffffff",
                  path: "#a08070", rail: "#909090", border: "#9e7ca8", casing: "#c0b8b0",
                  text: "#333333", waterText: "#4a6fa0"))

proc darkStyle*(): VectorStyle =
  ## A dark map (night, a dashboard in the dark theme).
  styleOf(Palette(bg: "#1e2124", water: "#22384c", waterLine: "#2c4a64", land: "#1e2124",
                  park: "#24342a", wood: "#22302a", residential: "#24272a", industrial: "#28272a",
                  sand: "#2c2a24", ice: "#3a3e44", building: "#2e3236", motorway: "#8a5a40",
                  trunk: "#7a5838", primary: "#5c5440", secondary: "#4a4a42", minor: "#3a3d40",
                  path: "#6a6058", rail: "#55595e", border: "#7a6a90", casing: "#141618",
                  text: "#d8d8d8", waterText: "#7aa0c8"))

proc matches(r: VectorRule; l: MvtLayer; f: MvtFeature; zoom: int): bool =
  if r.minZoom > 0 and zoom < r.minZoom: return false
  if r.maxZoom > 0 and zoom > r.maxZoom: return false
  if r.key.len == 0: return true
  let v = l.prop(f, r.key)
  if r.values.len == 0: return v.len > 0
  v in r.values

# ---- drawing ---------------------------------------------------------------------------

proc pack(c: Color): uint32 {.inline.} =
  0xFF000000'u32 or (uint32(c.r) shl 16) or (uint32(c.g) shl 8) or uint32(c.b)

proc paint(px: var seq[uint32]; cov: seq[uint8]; c: Color) =
  ## `c` over the picture as much as `cov` covers each pixel.
  let cr = uint32(c.r)
  let cg = uint32(c.g)
  let cb = uint32(c.b)
  for i in 0 ..< min(px.len, cov.len):
    let a = uint32(cov[i])
    if a == 0: continue
    if a == 255:
      px[i] = 0xFF000000'u32 or (cr shl 16) or (cg shl 8) or cb
    else:
      let d = px[i]
      let ia = 255 - a
      let r = (cr * a + ((d shr 16) and 255) * ia + 127) div 255
      let g = (cg * a + ((d shr 8) and 255) * ia + 127) div 255
      let b = (cb * a + (d and 255) * ia + 127) div 255
      px[i] = 0xFF000000'u32 or (r shl 16) or (g shl 8) or b

proc strokeSeg(r: var Raster; x0, y0, x1, y1, hw: float32) =
  ## A piece of a line `2 hw` wide as a rectangle (always turning the same
  ## way, so pieces that overlap add up, never cancel).
  let dx = x1 - x0
  let dy = y1 - y0
  let len = sqrt(dx * dx + dy * dy)
  if len < 1e-4: return
  let nx = -dy / len * hw
  let ny = dx / len * hw
  r.line(x0 + nx, y0 + ny, x1 + nx, y1 + ny)
  r.line(x1 + nx, y1 + ny, x1 - nx, y1 - ny)
  r.line(x1 - nx, y1 - ny, x0 - nx, y0 - ny)
  r.line(x0 - nx, y0 - ny, x0 + nx, y0 + ny)

proc joint(r: var Raster; x, y, hw: float32) =
  ## A round joint (an octagon) where pieces of a line meet.
  if hw < 0.75: return
  const n = 8
  var px = x + hw
  var py = y
  for k in 1 .. n:
    let a = float32(k) * 2 * PI / n
    let qx = x + hw * cos(a)
    let qy = y + hw * sin(a)
    r.line(px, py, qx, qy)
    px = qx
    py = qy

proc widthAt(rl: VectorRule; zoom: int; k: float32): float32 =
  ## A line's width at `zoom` in pixels of the picture (`k` of them a pixel
  ## of a 256-pixel tile): thinner as the map shows more of the world.
  let w = rl.width * pow(2.0, (float(zoom) - 15) * 0.6)
  float32(max(if rl.minWidth > 0: rl.minWidth else: 0.5, min(rl.width * 2.5, w))) * k

proc renderMvtPixels*(t: MvtTile; zoom, size: int; style: VectorStyle;
                      labels: ptr seq[TileLabel] = nil): seq[uint32] =
  ## Tile `t` (of zoom `zoom`) drawn `size` x `size` pixels in `style`
  ## (0xFFRRGGBB, row by row); the names it shows into `labels`.
  var px = newSeq[uint32](size * size)
  let bg = pack(style.background)
  for p in px.mitems: p = bg
  var ras = newRaster(size, size)
  var cov: seq[uint8]
  let k = float32(size) / 256
  for rl in style.rules:
    if rl.label.len > 0 and rl.fill.a == 0 and rl.line.a == 0:
      # labels: where the names go
      if labels == nil: continue
      for l in t:
        if l.name notin rl.layers: continue
        let s = float32(size) / float32(l.extent)
        for f in l.features:
          if not rl.matches(l, f, zoom): continue
          let text = l.prop(f, rl.label)
          if text.len == 0: continue
          var x, y: float32
          var found = false
          case f.kind
          of mgPoint:
            if f.parts.len > 0 and f.parts[0].len > 0:
              (x, y) = f.parts[0][0]
              found = true
          of mgLine:
            # (the middle of its longest piece)
            var best = -1.0'f32
            for part in f.parts:
              for i in 1 ..< part.len:
                let dx = part[i][0] - part[i - 1][0]
                let dy = part[i][1] - part[i - 1][1]
                let d = dx * dx + dy * dy
                if d > best:
                  best = d
                  x = (part[i][0] + part[i - 1][0]) / 2
                  y = (part[i][1] + part[i - 1][1]) / 2
                  found = true
          of mgPolygon:
            if f.parts.len > 0 and f.parts[0].len > 0:
              var sx, sy = 0'f32
              for q in f.parts[0]:
                sx += q[0]
                sy += q[1]
              x = sx / float32(f.parts[0].len)
              y = sy / float32(f.parts[0].len)
              found = true
          else: discard
          if not found: continue
          x *= s
          y *= s
          if x < 0 or y < 0 or x >= float32(size) or y >= float32(size): continue
          labels[].add TileLabel(x: x, y: y, text: text, size: rl.labelSize, color: rl.labelColor,
                                 priority: rl.priority)
      continue
    var drew = false
    let isFill = rl.fill.a > 0
    ras.clear()
    for l in t:
      if l.name notin rl.layers: continue
      let s = float32(size) / float32(l.extent)
      for f in l.features:
        if not rl.matches(l, f, zoom): continue
        if isFill:
          if f.kind != mgPolygon: continue
          for ring in f.parts:
            for i in 1 ..< ring.len:
              ras.line(ring[i - 1][0] * s, ring[i - 1][1] * s, ring[i][0] * s, ring[i][1] * s)
            drew = true
        elif rl.line.a > 0 and f.kind in {mgLine, mgPolygon}:
          let hw = rl.widthAt(zoom, k) / 2
          for part in f.parts:
            var along = 0'f32
            for i in 1 ..< part.len:
              let x0 = part[i - 1][0] * s
              let y0 = part[i - 1][1] * s
              let x1 = part[i][0] * s
              let y1 = part[i][1] * s
              # (off the picture by more than the line's width: nothing to draw)
              if max(x0, x1) < -hw or max(y0, y1) < -hw or min(x0, x1) > float32(size) + hw or
                 min(y0, y1) > float32(size) + hw:
                continue
              if rl.dash:
                # dashes of 4 widths and gaps of 3, along the line
                let dx = x1 - x0
                let dy = y1 - y0
                let len = sqrt(dx * dx + dy * dy)
                let period = max(3'f32, hw * 2 * 7)
                var t0 = 0'f32
                while t0 < len:
                  let phase = (along + t0) mod period
                  let onLeft = period * 4 / 7 - phase
                  if onLeft > 0:
                    let t1 = min(len, t0 + onLeft)
                    ras.strokeSeg(x0 + dx * t0 / len, y0 + dy * t0 / len, x0 + dx * t1 / len,
                                  y0 + dy * t1 / len, hw)
                    t0 = t1
                  else:
                    t0 += period - phase
                along += len
              else:
                ras.strokeSeg(x0, y0, x1, y1, hw)
                ras.joint(x1, y1, hw)
              drew = true
    if drew:
      ras.coverageInto(cov)
      px.paint(cov, if isFill: rl.fill else: rl.line)
  px

proc renderMvt*(t: MvtTile; zoom, size: int; style: VectorStyle;
                labels: ptr seq[TileLabel] = nil): Bitmap =
  ## Tile `t` (of zoom `zoom`) drawn `size` x `size` pixels in `style`;
  ## the names it shows into `labels` (the map draws them, upright).
  result = newBitmap(size, size)
  result.px = renderMvtPixels(t, zoom, size, style, labels)
  result.opaque = true
  result.changed()

proc layerNames*(t: MvtTile): seq[string] =
  ## The names of a tile's layers (which schema it is: "transportation" is
  ## OpenMapTiles', "roads" Protomaps', "road" Mapbox's).
  for l in t: result.add l.name

# ---- writing (tests, tiles of an app's own) ------------------------------------------

type MvtWriter* = object
  ## A vector tile written (an app's own data as tiles; the tests' tiles).
  layers: seq[(string, int, seq[string], seq[string], seq[string])]   # name, extent, keys, values, features

proc putVar(o: var string; v: uint64) =
  var v = v
  while v >= 0x80:
    o.add char((v and 0x7F) or 0x80)
    v = v shr 7
  o.add char(v)

proc putBytes(o: var string; field: int; data: string) =
  o.putVar(uint64(field shl 3 or 2))
  o.putVar(uint64(data.len))
  o.add data

proc zz(v: int): uint64 = uint64(if v < 0: ((-v) shl 1) - 1 else: v shl 1)

proc addFeature*(w: var MvtWriter; layer: string; kind: MvtGeom; parts: openArray[seq[(int, int)]];
                 props: openArray[(string, string)] = []; extent = 4096) =
  ## A feature (`parts` in tile units: points, a line's pieces, a polygon's
  ## rings -- the outline clockwise on the screen, holes the other way)
  ## with text properties.
  var li = -1
  for i, l in w.layers:
    if l[0] == layer: li = i
  if li < 0:
    w.layers.add (layer, extent, newSeq[string](), newSeq[string](), newSeq[string]())
    li = w.layers.high
  var tags: seq[uint64]
  for (k, v) in props:
    var ki = w.layers[li][2].find(k)
    if ki < 0:
      w.layers[li][2].add k
      ki = w.layers[li][2].high
    var vi = w.layers[li][3].find(v)
    if vi < 0:
      w.layers[li][3].add v
      vi = w.layers[li][3].high
    tags.add uint64(ki)
    tags.add uint64(vi)
  var cmds: seq[uint64]
  var cx, cy = 0
  if kind == mgPoint:
    cmds.add uint64(1 or (parts.len shl 3))
    for p in parts:
      for q in p:
        cmds.add zz(q[0] - cx)
        cmds.add zz(q[1] - cy)
        (cx, cy) = q
  else:
    for p in parts:
      let pts = if kind == mgPolygon and p.len > 1 and p[0] == p[^1]: p[0 ..< ^1] else: p
      if pts.len == 0: continue
      cmds.add uint64(1 or (1 shl 3))
      cmds.add zz(pts[0][0] - cx)
      cmds.add zz(pts[0][1] - cy)
      (cx, cy) = pts[0]
      if pts.len > 1:
        cmds.add uint64(2 or ((pts.len - 1) shl 3))
        for q in pts[1 .. ^1]:
          cmds.add zz(q[0] - cx)
          cmds.add zz(q[1] - cy)
          (cx, cy) = q
      if kind == mgPolygon: cmds.add uint64(7 or (1 shl 3))
  var f = ""
  var t = ""
  for v in tags: t.putVar(v)
  f.putBytes(2, t)
  f.putVar(uint64(3 shl 3))
  f.putVar(uint64(ord(kind)))
  var g = ""
  for v in cmds: g.putVar(v)
  f.putBytes(4, g)
  w.layers[li][4].add f

proc toMvt*(w: MvtWriter): string =
  ## The tile's bytes (not compressed).
  for (name, extent, keys, values, feats) in w.layers:
    var l = ""
    l.putVar(uint64(15 shl 3))
    l.putVar(2)
    l.putBytes(1, name)
    for f in feats: l.putBytes(2, f)
    for k in keys: l.putBytes(3, k)
    for v in values:
      var vb = ""
      vb.putBytes(1, v)
      l.putBytes(4, vb)
    l.putVar(uint64(5 shl 3))
    l.putVar(uint64(extent))
    result.putBytes(3, l)

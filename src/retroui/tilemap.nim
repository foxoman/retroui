## A street map of the whole world from any map service -- OpenStreetMap,
## Google, Azure Maps, Mapbox, HERE, MapTiler, Esri, TomTom, Stadia,
## CARTO, OpenTopoMap, China's AMap, Tencent and Tianditu -- or from a map
## of your own (vector or raster tiles, an MBTiles or PMTiles file, a
## folder): dragged, zoomed with the wheel, the fingers, the keys, with
## markers, lines, areas and circles over it, and the routes `geo` finds.
##
## .. code-block:: nim
##   import retroui, retroui/[tilemap, geo]
##   var city = TileMapState(lat: 23.588, lon: 58.3829, zoom: 12)
##   let src = osmTiles()                       # or googleTiles(key), mapTilerVector(key)...
##   app "Deliveries", 900, 600:
##     let ev = tileMap(city, src, markers = [MapMarker(lat: 23.614, lon: 58.593, label: "Airport")])
##     if ev.clicked: echo ev.lat, " ", ev.lon
##
## - Tiles come in the background (several at once), are kept in memory
##   and on the disk (`TileSource.cacheDays`: a week), and while one comes
##   the one above it is shown larger; past a service's last zoom its
##   tiles are shown larger still.
## - Vector tiles (`TileFormat.tfVector`: Mapbox Vector Tiles) are drawn by
##   the kit in a style (`mvt.classicStyle`, `mvt.darkStyle`, your own),
##   their names drawn over them upright.
## - On a dense screen a service's tiles of twice the pixels are taken
##   where it has them.
## - Maps of China (AMap, Tencent) are drawn in GCJ-02: the markers, lines
##   and the view are given in GPS coordinates (WGS 84) all the same, and
##   moved to match (`TileSource.gcj02`).
## - The services' names and copyright are shown in the corner, as each
##   asks (`attribution`); a key is the service's (`googleTiles(key)`).
##   OpenStreetMap's own tile servers are for light use: a business app
##   takes a service with a key, or its own tiles.
## - Apple's maps and Google's own JavaScript map are not tiles another
##   program may draw: `mapKitPage` and `googleMapsPage` make a page of
##   theirs for `webView`.

import std/[math, strutils, tables, os, hashes, json, times, algorithm, sequtils]
import gfx, core, widgets, imaging, jpeg, webp, http, mvt, pmtiles, geo
from mapview import MapMarker
from uirelays/input import getTicks
export MapMarker, LatLon
when compileOption("threads"):
  import std/[locks, typedthreads]

template th: untyped = ui.theme

# ---- sources -------------------------------------------------------------------------

type
  TileFormat* = enum
    tfRaster        ## pictures (PNG, JPEG, WebP)
    tfVector        ## Mapbox Vector Tiles, drawn by the kit

  TileSource* = object
    ## Where the map's tiles come from, and how they are drawn.
    name*: string                       ## its name (a list of maps)
    url*: string                        ## the address of a tile: {z} {x} {y}, {-y} (rows
                                        ## from the south), {s} a subdomain, {q} a quadkey,
                                        ## {r} "@2x" on a dense screen ("" else)
    subdomains*: seq[string]            ## what {s} takes, in turn
    tileSize*: int                      ## pixels a tile covers at its zoom (256; 512)
    minZoom*, maxZoom*: int             ## the zooms it has (0 .. 19)
    attribution*: string                ## what must be shown with it
    headers*: seq[(string, string)]     ## sent with each tile (a key some take so)
    format*: TileFormat
    style*: VectorStyle                 ## tfVector: how it is drawn (classicStyle else)
    gcj02*: bool                        ## a map of China in GCJ-02 (see above)
    hiDpi*: bool                        ## {r} or the service gives tiles of twice the pixels
    file*: string                       ## an .mbtiles or .pmtiles file (or a .pmtiles address)
    cacheDays*: int                     ## days a tile is kept on the disk (0: 7; -1: never)
    googleKey*, googleMapType*, googleLanguage*, googleRegion*: string
      ## (Google's tiles: a session is made for them)

  TileMapState* = object
    ## Where a `tileMap` looks; keep one per map.
    lat*, lon*: float                   ## the middle of the view (degrees, WGS 84)
    zoom*: float                        ## 0 the whole world in a tile .. 22 (fractions too)
    minZoom*, maxZoom*: float           ## (0, 0: the source's)
    inited: bool
    view: Rect
    pressX, pressY, lastX, lastY: int
    moved: bool
    hoverMarker: int
    fitPending: bool
    fitBox: array[4, float]

  MapShapeKind* = enum
    msLine, msPolygon, msCircle

  MapShape* = object
    ## A line, an area or a circle on the map.
    kind*: MapShapeKind
    points*: seq[LatLon]                ## the line, the area's outline; a circle's middle
    holes*: seq[seq[LatLon]]            ## msPolygon: cut out of it
    radiusM*: float                     ## msCircle: in meters
    color*: Color                       ## the line (alpha 0: the theme's selection)
    fill*: Color                        ## an area's inside (alpha 0: none)
    width*: float                       ## the line, design pixels (0: 3)
    label*: string                      ## named by a tip when the mouse is on it

  TileMapEvent* = object
    ## What happened in a `tileMap` this frame.
    clicked*: bool                      ## a click or tap (not a drag) on the map
    lat*, lon*: float                   ## where the mouse is (or was clicked), WGS 84
    marker*: int                        ## the marker clicked or under the mouse (-1 none)
    shape*: int                         ## the shape clicked or under the mouse (-1 none)
    moved*: bool                        ## the view moved or zoomed
    loading*: int                       ## tiles still coming

proc source(name, url, attribution: string; maxZoom = 19; subdomains: seq[string] = @[];
            tileSize = 256; hiDpi = false; format = tfRaster): TileSource =
  TileSource(name: name, url: url, attribution: attribution, maxZoom: maxZoom,
             subdomains: subdomains, tileSize: tileSize, hiDpi: hiDpi, format: format,
             style: classicStyle())

proc osmTiles*(): TileSource =
  ## OpenStreetMap's own map (its servers are for light use; your app's
  ## name goes with each request: `tileAgent`).
  source("OpenStreetMap", "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
         "© OpenStreetMap contributors")

proc openTopoMap*(): TileSource =
  ## OpenTopoMap: heights, contour lines, paths (to zoom 17).
  source("OpenTopoMap", "https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png",
         "© OpenStreetMap contributors, SRTM; style © OpenTopoMap (CC-BY-SA)", 17, @["a", "b", "c"])

proc cartoTiles*(style = "light_all"): TileSource =
  ## CARTO's basemaps: "light_all" (Positron), "dark_all" (Dark Matter),
  ## "rastertiles/voyager" (Voyager); their `_nolabels` and `_only_labels`.
  source("CARTO " & style, "https://{s}.basemaps.cartocdn.com/" & style & "/{z}/{x}/{y}{r}.png",
         "© OpenStreetMap contributors, © CARTO", 20, @["a", "b", "c", "d"], hiDpi = true)

proc googleTiles*(key: string; mapType = "roadmap"; language = "en-US"; region = "US"): TileSource =
  ## Google's Map Tiles API (2D tiles): `mapType` "roadmap", "satellite"
  ## or "terrain"; a key with the Map Tiles API enabled.
  result = source("Google " & mapType, "https://tile.googleapis.com/v1/2dtiles/{z}/{x}/{y}?key=" & key,
                  "Map data © Google", 22)
  result.googleKey = key
  result.googleMapType = mapType
  result.googleLanguage = language
  result.googleRegion = region

proc azureTiles*(key: string; tileset = "microsoft.base.road"; language = ""): TileSource =
  ## Azure Maps (Render, Get Map Tile): "microsoft.base.road",
  ## "microsoft.base.darkgrey", "microsoft.imagery", "microsoft.base.hybrid.road"...
  result = source("Azure Maps", "https://atlas.microsoft.com/map/tile?api-version=2024-04-01&tilesetId=" &
                  tileset & "&zoom={z}&x={x}&y={y}&tileSize=512" &
                  (if language.len > 0: "&language=" & language else: ""),
                  "© " & $now().year & " Microsoft, © TomTom", 22, tileSize = 512)
  if tileset == "microsoft.imagery": result.maxZoom = 19
  result.headers = @[("subscription-key", key)]

proc mapboxTiles*(token: string; style = "mapbox/streets-v12"): TileSource =
  ## Mapbox's styles as pictures: "mapbox/streets-v12", "mapbox/outdoors-v12",
  ## "mapbox/light-v11", "mapbox/dark-v11", "mapbox/satellite-streets-v12"
  ## or a style of your own ("you/abc123").
  source("Mapbox", "https://api.mapbox.com/styles/v1/" & style & "/tiles/512/{z}/{x}/{y}{r}?access_token=" & token,
         "© Mapbox © OpenStreetMap", 22, tileSize = 512, hiDpi = true)

proc mapboxVector*(token: string; style = classicStyle()): TileSource =
  ## Mapbox Streets v8 as vector tiles, drawn by the kit in `style`.
  result = source("Mapbox Streets", "https://api.mapbox.com/v4/mapbox.mapbox-streets-v8/{z}/{x}/{y}.mvt?access_token=" &
                  token, "© Mapbox © OpenStreetMap", 16, tileSize = 512, format = tfVector)
  result.style = style

proc hereTiles*(key: string; style = "explore.day"): TileSource =
  ## HERE's Raster Tile API: "explore.day", "explore.night", "lite.day",
  ## "satellite.day", "explore.satellite.day", "logistics.day"...
  source("HERE", "https://maps.hereapi.com/v3/base/mc/{z}/{x}/{y}/png?style=" & style & "&size=512&apiKey=" & key,
         "© HERE " & $now().year, 20, tileSize = 512)

proc mapTilerTiles*(key: string; map = "streets-v2"): TileSource =
  ## MapTiler's maps as pictures: "streets-v2", "outdoor-v2", "basic-v2",
  ## "bright-v2", "satellite", "topo-v2", "dataviz"...
  source("MapTiler", "https://api.maptiler.com/maps/" & map & "/256/{z}/{x}/{y}{r}.png?key=" & key,
         "© MapTiler © OpenStreetMap contributors", 22, hiDpi = true)

proc mapTilerVector*(key: string; style = classicStyle()): TileSource =
  ## MapTiler's vector tiles (OpenMapTiles), drawn by the kit in `style`.
  result = source("MapTiler", "https://api.maptiler.com/tiles/v3/{z}/{x}/{y}.pbf?key=" & key,
                  "© MapTiler © OpenStreetMap contributors", 14, tileSize = 512, format = tfVector)
  result.style = style

proc protomapsVector*(key: string; style = classicStyle()): TileSource =
  ## Protomaps' basemap (its API; or a .pmtiles file of it: `pmtilesSource`).
  result = source("Protomaps", "https://api.protomaps.com/tiles/v4/{z}/{x}/{y}.mvt?key=" & key,
                  "Protomaps © OpenStreetMap", 15, tileSize = 512, format = tfVector)
  result.style = style

proc esriTiles*(service = "World_Street_Map"; token = ""): TileSource =
  ## Esri's (ArcGIS) basemaps: "World_Street_Map", "World_Imagery",
  ## "World_Topo_Map", "World_Terrain_Base"...; with a token of your
  ## ArcGIS account, through its basemap service.
  let base = if token.len > 0: "https://ibasemaps-api.arcgis.com/arcgis/rest/services/"
             else: "https://server.arcgisonline.com/ArcGIS/rest/services/"
  source("Esri " & service, base & service & "/MapServer/tile/{z}/{y}/{x}" &
         (if token.len > 0: "?token=" & token else: ""), "Esri, HERE, Garmin, © OpenStreetMap contributors", 19)

proc tomTomTiles*(key: string; layer = "basic"; style = "main"): TileSource =
  ## TomTom's Map Display API: `layer` "basic", "hybrid" or "labels",
  ## `style` "main" or "night".
  source("TomTom", "https://{s}.api.tomtom.com/map/1/tile/" & layer & "/" & style &
         "/{z}/{x}/{y}.png?tileSize=512&key=" & key, "© " & $now().year & " TomTom", 22,
         @["a", "b", "c", "d"], tileSize = 512)

proc stadiaTiles*(key = ""; style = "alidade_smooth"): TileSource =
  ## Stadia Maps: "alidade_smooth", "alidade_smooth_dark", "outdoors",
  ## "osm_bright", "stamen_toner", "stamen_terrain" (a key, or your app's
  ## web address registered with them).
  source("Stadia " & style, "https://tiles.stadiamaps.com/tiles/" & style & "/{z}/{x}/{y}{r}.png" &
         (if key.len > 0: "?api_key=" & key else: ""),
         "© Stadia Maps © OpenMapTiles © OpenStreetMap contributors", 20, hiDpi = true)

proc amapTiles*(satellite = false; language = "zh_cn"): TileSource =
  ## AMap (Gaode) of China: its streets, or satellite pictures; GCJ-02.
  result = if satellite:
             source("AMap satellite", "https://webst0{s}.is.autonavi.com/appmaptile?style=6&x={x}&y={y}&z={z}",
                    "© AutoNavi", 18, @["1", "2", "3", "4"])
           else:
             source("AMap", "https://webrd0{s}.is.autonavi.com/appmaptile?lang=" & language &
                    "&size=1&scale=1&style=8&x={x}&y={y}&z={z}", "© AutoNavi", 18, @["1", "2", "3", "4"])
  result.gcj02 = true

proc tencentTiles*(): TileSource =
  ## Tencent's map of China; GCJ-02.
  result = source("Tencent", "https://rt{s}.map.gtimg.com/tile?z={z}&x={x}&y={-y}&type=vector&styleid=3",
                  "© Tencent", 18, @["0", "1", "2", "3"])
  result.gcj02 = true

proc tiandituTiles*(key: string; layer = "vec"): TileSource =
  ## Tianditu, China's national map (CGCS2000, as GPS): `layer` "vec"
  ## (streets), "img" (satellite), "ter" (terrain); their names over them
  ## are the "cva", "cia", "cta" layers.
  source("Tianditu", "https://t{s}.tianditu.gov.cn/" & layer & "_w/wmts?SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0&LAYER=" &
         layer & "&STYLE=default&TILEMATRIXSET=w&FORMAT=tiles&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}&tk=" & key,
         "© Tianditu", 18, @["0", "1", "2", "3", "4", "5", "6", "7"])

proc pmtilesSource*(path: string; style = classicStyle(); attribution = "© OpenStreetMap contributors"): TileSource =
  ## A PMTiles archive (a file, or its web address: read in pieces),
  ## raster or vector as it holds.
  result = source(path.extractFilename, "", attribution, 15)
  result.file = path
  result.style = style
  let pm = openPmtiles(path)
  if pm.ok:
    result.minZoom = pm.minZoom
    result.maxZoom = pm.maxZoom
    result.format = if pm.tileType == ptMvt: tfVector else: tfRaster
    result.tileSize = if result.format == tfVector: 512 else: 256
    let a = pm.metadata(){"attribution"}.getStr
    if a.len > 0: result.attribution = a
    pm.close()

proc mbtilesSource*(path: string; style = classicStyle(); attribution = "© OpenStreetMap contributors"): TileSource =
  ## An MBTiles file, raster or vector as it holds.
  result = source(path.extractFilename, "", attribution, 15)
  result.file = path
  result.style = style
  let mb = openMbtiles(path)
  if mb.ok:
    result.format = if mb.format in ["pbf", "mvt"]: tfVector else: tfRaster
    result.tileSize = if result.format == tfVector: 512 else: 256
    try:
      result.minZoom = parseInt(mb.meta.getOrDefault("minzoom", "0"))
      result.maxZoom = parseInt(mb.meta.getOrDefault("maxzoom", "15"))
    except ValueError: discard
    let a = mb.meta.getOrDefault("attribution")
    if a.len > 0: result.attribution = a
    mb.close()

proc folderSource*(dir: string; ext = "png"; maxZoom = 18; attribution = ""): TileSource =
  ## Tiles in folders of your own: `dir`/z/x/y.`ext` (what a tile tool
  ## writes; "pbf" for vector tiles).
  result = source(dir.extractFilename, "file://" & dir & "/{z}/{x}/{y}." & ext, attribution, maxZoom)
  if ext in ["pbf", "mvt"]:
    result.format = tfVector
    result.tileSize = 512

proc tileJsonSource*(url: string; style = classicStyle()): TileSource =
  ## A TileJSON's tiles (OpenFreeMap: "https://tiles.openfreemap.org/planet";
  ## a tile server's). Waits for it.
  let r = httpRequest("GET", url, timeoutSec = 20)
  result = source(url, "", "", 14)
  result.style = style
  if r.status != 200: return
  try:
    let j = parseJson(r.body)
    result.name = j{"name"}.getStr(url)
    let tiles = j{"tiles"}
    if tiles != nil and tiles.len > 0: result.url = tiles[0].getStr
    result.minZoom = j{"minzoom"}.getInt(0)
    result.maxZoom = j{"maxzoom"}.getInt(14)
    result.attribution = j{"attribution"}.getStr.multiReplace(("<a href=", "<"), ("</a>", ""))
    # (links in it as plain text)
    var plain = ""
    var inTag = false
    for c in result.attribution:
      if c == '<': inTag = true
      elif c == '>': inTag = false
      elif not inTag: plain.add c
    result.attribution = plain.strip
    if j{"vector_layers"} != nil or result.url.contains(".pbf") or result.url.contains(".mvt"):
      result.format = tfVector
      result.tileSize = 512
  except CatchableError:
    discard

proc mapKitPage*(token: string; lat, lon: float; zoomMeters = 5000.0): string =
  ## A page with Apple's map (MapKit JS) for `webView`: `token` a MapKit JS
  ## token of your Apple developer account; the map around `lat`, `lon`,
  ## `zoomMeters` across.
  """<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<script src="https://cdn.apple-mapkit.com/mk/5.x.x/mapkit.js"></script>
<style>html,body,#map{margin:0;height:100%}</style></head><body><div id="map"></div><script>
mapkit.init({authorizationCallback: function(done) { done("""" & token & """"); }});
var map = new mapkit.Map("map");
map.region = new mapkit.CoordinateRegion(new mapkit.Coordinate(""" & $lat & ", " & $lon &
    """), new mapkit.CoordinateSpan(""" & $(zoomMeters / 111000) & ", " & $(zoomMeters / 111000) & """));
map.addEventListener("region-change-end", function() {
  var c = map.center; if (window.retro) retro.post("center " + c.latitude + " " + c.longitude);
});
</script></body></html>"""

proc googleMapsPage*(key: string; lat, lon: float; zoom = 12): string =
  ## A page with Google's own JavaScript map for `webView` (a key with the
  ## Maps JavaScript API enabled).
  """<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<style>html,body,#map{margin:0;height:100%}</style></head><body><div id="map"></div><script>
function start() {
  var map = new google.maps.Map(document.getElementById("map"), {center: {lat: """ & $lat & ", lng: " & $lon &
    """}, zoom: """ & $zoom & """});
  map.addListener("idle", function() {
    var c = map.getCenter(); if (window.retro) retro.post("center " + c.lat() + " " + c.lng());
  });
}
</script><script async src="https://maps.googleapis.com/maps/api/js?key=""" & key & """&callback=start"></script>
</body></html>"""

# ---- tile addresses ------------------------------------------------------------------

var tileAgent* = ""
  ## The User-Agent tiles are asked with ("" your app's name and the kit's):
  ## OpenStreetMap's servers want one that says who asks.

proc agent(): string =
  if tileAgent.len > 0: tileAgent
  else: getAppFilename().extractFilename.changeFileExt("") & " (Retro Nim UI map)"

proc quadkey*(z, x, y: int): string =
  ## A tile's quadkey (Bing's and Azure's numbering).
  for i in countdown(z, 1):
    var d = 0
    let mask = 1 shl (i - 1)
    if (x and mask) != 0: d += 1
    if (y and mask) != 0: d += 2
    result.add char(ord('0') + d)

proc tileUrl*(s: TileSource; z, x, y: int; dense = false): string =
  ## The address of tile `z`/`x`/`y` of `s` (`dense`: the one with twice the pixels).
  result = s.url
  let n = 1 shl z
  result = result.multiReplace(("{z}", $z), ("{x}", $x), ("{y}", $y), ("{-y}", $(n - 1 - y)),
                               ("{q}", quadkey(z, x, y)), ("{r}", if dense and s.hiDpi: "@2x" else: ""))
  if s.subdomains.len > 0:
    result = result.replace("{s}", s.subdomains[(x + y) mod s.subdomains.len])

proc sourceId(s: TileSource): int =
  ## (what makes two sources' tiles different)
  var h: Hash = 0
  h = h !& hash(s.url) !& hash(s.file) !& hash(ord(s.format))
  if s.format == tfVector:
    for r in s.style.rules: h = h !& hash(r.layers) !& hash(r.key) !& hash(r.values) !& hash(r.fill.r)
    h = h !& hash(s.style.background.r) !& hash(s.style.background.g)
  !$h

# ---- the tiles kept --------------------------------------------------------------------

type
  TileKey = tuple[src, z, x, y, px: int]
  TileState = enum tsLoading, tsReady, tsMissing, tsFailed
  TileEntry = ref object
    state: TileState
    bmp: Bitmap
    labels: seq[TileLabel]
    used: int                       # the frame it was last drawn in
    bytes: int
    retryAt: int

  TileJob = object
    key: TileKey
    url, file, diskPath: string
    headers: seq[(string, string)]
    z, x, y: int
    vector, flipY: bool
    style: VectorStyle
    diskDays: int
    google: array[4, string]

  TileDone = object
    key: TileKey
    w, h: int
    px: seq[uint32]
    labels: seq[TileLabel]
    missing: bool
    error: string

var
  tiles: Table[TileKey, TileEntry]
  tileBytes = 0
  tileFrame = 0
  maxTileBytes* = 192 shl 20
    ## How much memory the tiles may take (192 MB); the least lately seen go.
  pendingKeys: Table[TileKey, int]  # asked: the frame it was last wanted in

proc cacheRoot(): string =
  getCacheDir() / "retroui" / "tiles"

proc diskPathOf(s: TileSource; z, x, y: int; dense: bool): string =
  if s.cacheDays < 0 or s.file.len > 0 or s.url.startsWith("file://") or s.url.len == 0: return ""
  let ext = if s.format == tfVector: "mvt" else: "tile"
  cacheRoot() / toHex(cast[uint32](sourceId(s))) / $z / $x / ($y & (if dense: "@2x." else: ".") & ext)

proc decodeTile(data: string): (int, int, seq[uint32]) =
  ## (a tile's picture: PNG, JPEG, WebP)
  try:
    var b: Bitmap = nil
    if data.len >= 8 and data[0 .. 7] == "\x89PNG\r\n\x1a\n": b = decodePng(data)
    elif data.len >= 3 and data[0] == '\xFF' and data[1] == '\xD8': b = decodeJpeg(data)
    elif data.len >= 12 and data[0 .. 3] == "RIFF" and data[8 .. 11] == "WEBP": b = decodeWebp(data)
    if b != nil and b.w > 0 and b.h > 0: return (b.w, b.h, move b.px)
  except CatchableError, Defect:
    discard
  (0, 0, @[])

# Google's tiles need a session (a token for a key, a map type, a language)
var googleSessions: Table[string, string]
when compileOption("threads"):
  var googleLock: Lock
  initLock(googleLock)

proc googleSession(g: array[4, string]): string =
  let k = g.join("|")
  when compileOption("threads"): acquire(googleLock)
  result = googleSessions.getOrDefault(k)
  when compileOption("threads"): release(googleLock)
  if result.len > 0: return
  let body = $(%*{"mapType": g[1], "language": g[2], "region": g[3], "scale": "scaleFactor2x", "highDpi": true})
  let r = httpRequest("POST", "https://tile.googleapis.com/v1/createSession?key=" & g[0],
                      [("Content-Type", "application/json")], body, timeoutSec = 20)
  if r.status == 200:
    try: result = parseJson(r.body){"session"}.getStr
    except CatchableError: discard
  if result.len > 0:
    when compileOption("threads"): acquire(googleLock)
    googleSessions[k] = result
    when compileOption("threads"): release(googleLock)

proc fresh(path: string; days: int): bool =
  try:
    fileExists(path) and (getTime() - getLastModificationTime(path)).inDays < (if days == 0: 7 else: days)
  except OSError: false

proc finish(job: TileJob; data: string; d: var TileDone) =
  ## A tile's bytes made a picture (and its labels).
  if data.len == 0:
    d.missing = true
    return
  if job.vector:
    try:
      let t = decodeMvt(data)
      d.px = renderMvtPixels(t, job.z, job.key.px, job.style, addr d.labels)
      d.w = job.key.px
      d.h = job.key.px
    except CatchableError as e:
      d.error = e.msg
  else:
    (d.w, d.h, d.px) = decodeTile(data)
    if d.w == 0: d.error = "the tile is not a picture"

when compileOption("threads"):
  var fileArchives {.threadvar.}: Table[string, (Pmtiles, Mbtiles)]
else:
  var fileArchives: Table[string, (Pmtiles, Mbtiles)]

proc fromFile(job: TileJob): string =
  if job.file notin fileArchives:
    if job.file.toLowerAscii.endsWith(".mbtiles"):
      fileArchives[job.file] = (nil, openMbtiles(job.file))
    else:
      fileArchives[job.file] = (openPmtiles(job.file), nil)
  let (pm, mb) = fileArchives[job.file]
  if pm != nil: pm.tile(job.z, job.x, job.y)
  elif mb != nil: mb.tile(job.z, job.x, job.y)
  else: ""

proc runTile(job: TileJob): TileDone =
  ## Gets a tile (the disk, its file, the network) and draws it.
  result.key = job.key
  var data = ""
  if job.diskPath.len > 0 and fresh(job.diskPath, job.diskDays):
    data = try: readFile(job.diskPath) except IOError, OSError: ""
  if data.len == 0:
    if job.file.len > 0:
      data = fromFile(job)
    elif job.url.startsWith("file://"):
      data = try: readFile(job.url[7 .. ^1]) except IOError, OSError: ""
    else:
      var url = job.url
      if job.google[0].len > 0:
        let s = googleSession(job.google)
        if s.len == 0:
          result.error = "Google's session could not be made (the key, the Map Tiles API)"
          return
        url.add "&session=" & s
      let r = httpRequest("GET", url, job.headers, timeoutSec = 30)
      if r.status == 404 or r.status == 204:
        result.missing = true
        return
      if r.status != 200:
        result.error = if r.status == 0: r.error else: "HTTP " & $r.status
        return
      data = r.body
      if job.diskPath.len > 0 and data.len > 0:
        try:
          createDir(job.diskPath.parentDir)
          writeFile(job.diskPath, data)
        except IOError, OSError: discard
  if job.key.px == 0: return              # (only kept on the disk: `keepArea`)
  finish(job, data, result)

# ---- the workers -------------------------------------------------------------------------

when compileOption("threads"):
  type TileShared = object
    todo: seq[TileJob]
    done: seq[TileDone]
  # (never freed: a worker may still be at work as the program ends, after
  # Nim has destroyed the program's globals -- these are not among them)
  let tileSh = cast[ptr TileShared](allocShared0(sizeof(TileShared)))
  template tileTodo: untyped = tileSh.todo
  template tileDone: untyped = tileSh.done
  var
    tileLock: Lock
    tileReady: Cond
    tileThreads: seq[Thread[void]]
    tileStarted = false

  proc tileWorker() {.thread.} =
    {.cast(gcsafe).}:
      while true:
        acquire(tileLock)
        while tileTodo.len == 0: wait(tileReady, tileLock)
        let job = tileTodo.pop()           # (the newest first: what is looked at now)
        release(tileLock)
        let d = runTile(job)
        acquire(tileLock)
        tileDone.add d
        release(tileLock)

  proc queueTile(job: sink TileJob) =
    if not tileStarted:
      tileStarted = true
      initLock(tileLock)
      initCond(tileReady)
      tileThreads.setLen(6)
      for t in tileThreads.mitems: createThread(t, tileWorker)
    acquire(tileLock)
    tileTodo.add job
    signal(tileReady)
    release(tileLock)

  proc takeDone(): seq[TileDone] =
    if not tileStarted: return
    acquire(tileLock)
    result = move tileDone
    tileDone = @[]
    # (what is no longer looked at is not fetched)
    var keep: seq[TileJob]
    for j in tileTodo:
      if pendingKeys.getOrDefault(j.key, -1000) >= tileFrame - 2: keep.add j
      else: pendingKeys.del j.key
    tileTodo = keep
    release(tileLock)

elif defined(wasm):
  proc rwFetchStart(url, headers: cstring): cint {.importc: "rw_fetch_start", cdecl.}
  proc rwFetchState(id: cint): cint {.importc: "rw_fetch_state", cdecl.}
  proc rwFetchPart(id, part: cint; buf: pointer; cap: cint): cint {.importc: "rw_fetch_part", cdecl.}
  proc rwFetchFree(id: cint) {.importc: "rw_fetch_free", cdecl.}
  var
    webJobs: seq[(cint, TileJob)]     # fetching
    readyJobs: seq[TileJob]           # to run here (files, the disk, fetched)
    fetched: Table[TileKey, string]

  proc queueTile(job: sink TileJob) =
    if job.file.len > 0 or job.url.startsWith("file://") or
       job.diskPath.len > 0 and fresh(job.diskPath, job.diskDays):
      readyJobs.add job
      return
    var hs = "User-Agent: " & agent() & "\r\n"
    for (k, v) in job.headers: hs.add k & ": " & v & "\r\n"
    let id = rwFetchStart(cstring(job.url), cstring(hs))
    if id > 0: webJobs.add (id, job)

  proc takeDone(): seq[TileDone] =
    var i = 0
    while i < webJobs.len:
      let (id, job) = webJobs[i]
      let st = rwFetchState(id)
      if st == 0:
        inc i
        continue
      var d = TileDone(key: job.key)
      if st == 200:
        let n = rwFetchPart(id, 2, nil, 0)
        var body = newString(max(0, n))
        if n > 0: discard rwFetchPart(id, 2, addr body[0], n)
        fetched[job.key] = body
        readyJobs.add job
      elif st == 404 or st == 204:
        d.missing = true
        result.add d
      else:
        d.error = "HTTP " & $st
        result.add d
      rwFetchFree(id)
      webJobs.delete(i)
    # (drawn here: two a frame at most, the frame keeps its pace)
    let t0 = getTicks()
    while readyJobs.len > 0 and getTicks() - t0 < 10:
      let job = readyJobs.pop()
      var d = TileDone(key: job.key)
      if job.key in fetched:
        finish(job, fetched[job.key], d)
        fetched.del job.key
      else:
        d = runTile(job)
      result.add d

else:
  var doneHere: seq[TileDone]
  proc queueTile(job: sink TileJob) =
    doneHere.add runTile(job)
  proc takeDone(): seq[TileDone] =
    result = move doneHere
    doneHere = @[]

proc evict() =
  ## The least lately seen tiles go until the tiles fit `maxTileBytes`.
  if tileBytes <= maxTileBytes: return
  var order: seq[(int, TileKey)]
  for k, e in tiles:
    if e.state == tsReady and e.used < tileFrame: order.add (e.used, k)
  order.sort(proc (a, b: (int, TileKey)): int = cmp(a[0], b[0]))
  for (u, k) in order:
    if tileBytes <= maxTileBytes * 3 div 4: break
    tileBytes -= tiles[k].bytes
    tiles.del k

proc collect(): bool =
  ## Finished tiles into the cache; true when any came.
  for d in takeDone():
    pendingKeys.del d.key
    if d.key.px == 0: continue             # (kept on the disk only)
    result = true
    var e = tiles.getOrDefault(d.key)
    if e == nil:
      e = TileEntry()
      tiles[d.key] = e
    if d.w > 0 and d.px.len >= d.w * d.h:
      let b = newBitmap(d.w, d.h)
      b.px = d.px
      b.opaque = false
      b.changed()
      e.bmp = b
      e.labels = d.labels
      e.state = tsReady
      e.bytes = d.w * d.h * 4
      tileBytes += e.bytes
    elif d.missing:
      e.state = tsMissing
    else:
      e.state = tsFailed
      e.retryAt = getTicks() + 15000
  evict()

proc request(s: TileSource; sid, z, x, y, px: int; dense: bool) =
  let key: TileKey = (sid, z, x, y, px)
  pendingKeys[key] = tileFrame
  if key in tiles:
    let e = tiles[key]
    if e.state != tsFailed or getTicks() < e.retryAt: return
    e.state = tsLoading
  else:
    tiles[key] = TileEntry(state: tsLoading)
  var job = TileJob(key: key, z: z, x: x, y: y, vector: s.format == tfVector, file: s.file,
                    diskDays: s.cacheDays)
  job.style = s.style
  if s.file.len == 0:
    job.url = s.tileUrl(z, x, y, dense)
    job.headers = s.headers
    if not s.headers.anyIt(cmpIgnoreCase(it[0], "User-Agent") == 0):
      job.headers.add ("User-Agent", agent())
    job.diskPath = s.diskPathOf(z, x, y, dense)
  if s.googleKey.len > 0:
    job.google = [s.googleKey, s.googleMapType, s.googleLanguage, s.googleRegion]
  queueTile(job)

proc loadingTiles*(): int =
  ## Tiles asked for and not yet come.
  for k, e in tiles:
    if e.state == tsLoading: inc result

proc clearTileCache*(disk = false) =
  ## Forgets the tiles kept in memory (and on the disk with `disk`).
  tiles.clear()
  tileBytes = 0
  if disk:
    try: removeDir(cacheRoot())
    except OSError: discard

# ---- the view ----------------------------------------------------------------------------

const MercMax = 85.05112878

proc worldX(lon, scale: float): float = (lon + 180) / 360 * scale
proc worldY(lat, scale: float): float =
  let la = clamp(lat, -MercMax, MercMax) * PI / 180
  (1 - ln(tan(la) + 1 / cos(la)) / PI) / 2 * scale
proc lonOf(x, scale: float): float = x / scale * 360 - 180
proc latOf(y, scale: float): float = arctan(sinh(PI * (1 - 2 * y / scale))) * 180 / PI

proc dpf(v: float): float = v * float(dp(1000)) / 1000

proc fitBounds*(m: var TileMapState; south, west, north, east: float) =
  ## Shows the area from `south`, `west` to `north`, `east` (degrees) as
  ## large as the map shows it (done when it is next drawn).
  m.fitPending = true
  m.fitBox = [south, west, north, east]

proc fitPoints*(m: var TileMapState; points: openArray[LatLon]) =
  ## Shows all of `points` (a route, the markers).
  if points.len == 0: return
  var s = 90.0
  var n = -90.0
  var w = 180.0
  var e = -180.0
  for p in points:
    s = min(s, p.lat)
    n = max(n, p.lat)
    w = min(w, p.lon)
    e = max(e, p.lon)
  m.fitBounds(s, w, n, e)

proc centerOn*(m: var TileMapState; lat, lon: float; zoom = -1.0) =
  ## Moves the view to `lat`, `lon` (and `zoom` when given).
  m.lat = lat
  m.lon = lon
  if zoom >= 0: m.zoom = zoom
  m.inited = true

proc metersPerPixel*(m: TileMapState): float =
  ## How many meters a design pixel covers at the middle of the view.
  156543.03392 * cos(m.lat * PI / 180) / pow(2.0, m.zoom)

proc tileMap*(m: var TileMapState; src: TileSource; height = -1;
              markers: openArray[MapMarker] = []; shapes: openArray[MapShape] = [];
              overlays: openArray[TileSource] = []; showScale = true; showZoom = true;
              key = ""): TileMapEvent {.discardable.} =
  ## The map of `src`, `height` pixels high (-1: the room left), as wide as
  ## the space it is in; `overlays` drawn over it (labels, sea marks, rain),
  ## `shapes` and `markers` over them. Drag to move it; the wheel, a double
  ## click, two fingers, + / - (with the focus) or its buttons zoom; arrows
  ## move it. `clicked` reports a click or a tap and where.
  result.marker = -1
  result.shape = -1
  inc tileFrame
  let h = if height < 0: remainingH() else: height
  let r = place(0, max(dp(80), h), fill = true)
  beginKeepSides(r)
  defer: endKeepSides()
  let id = idOf("tilemap:" & key)
  m.view = r
  let lo = if m.minZoom > 0: m.minZoom else: float(src.minZoom)
  let hi = if m.maxZoom > 0: m.maxZoom else: 22.0
  if not m.inited:
    m.inited = true
    if m.zoom <= 0: m.zoom = 2
  # the size of the world in logical pixels: 256 design pixels a tile at zoom 0
  let base = dpf(256)
  if m.fitPending and r.w > 0 and r.h > 0:
    m.fitPending = false
    let (s, w, n, e) = (m.fitBox[0], m.fitBox[1], m.fitBox[2], m.fitBox[3])
    let pad = dpf(24)
    let dx = max(1e-9, worldX(e, base) - worldX(w, base))
    let dy = max(1e-9, worldY(s, base) - worldY(n, base))
    m.zoom = clamp(log2(min((float(r.w) - 2 * pad) / dx, (float(r.h) - 2 * pad) / dy)), lo, min(hi, 18.0))
    m.lat = latOf((worldY(s, base) + worldY(n, base)) / 2, base)
    m.lon = (w + e) / 2
  m.zoom = clamp(m.zoom, lo, hi)
  let gcj = src.gcj02
  template toMap(p: LatLon): LatLon = (if gcj: wgsToGcj(p) else: p)
  template fromMap(p: LatLon): LatLon = (if gcj: gcjToWgs(p) else: p)
  var scale = base * pow(2.0, m.zoom)
  let c0 = toMap((m.lat, m.lon))
  var cx = worldX(c0.lon, scale)
  var cy = worldY(c0.lat, scale)
  let before = (m.zoom, m.lat, m.lon)
  # input first, so this frame shows where the map is now
  let bs = if fingers(): dp(30) else: dp(20)
  let zr = [rect(r.x + r.w - bs - dp(6), r.y + dp(6), bs, bs),
            rect(r.x + r.w - bs - dp(6), r.y + dp(6) + bs + dp(2), bs, bs)]
  var zhit: array[2, Hit]
  if showZoom:
    for k in 0 .. 1: zhit[k] = interact(id + uint32(10 + k), zr[k], focusable = false)
  let hit = interact(id, r)
  proc setCenter(m: var TileMapState; x, y, scale: float) =
    let p = fromMap((latOf(clamp(y, 0, scale), scale), lonOf(x, scale)))
    m.lat = p.lat
    m.lon = ((p.lon + 540) mod 360) - 180
  proc zoomAround(m: var TileMapState; px, py, dz: float) =
    ## zoom by `dz` keeping the point at screen `px`, `py` where it is
    let nz = clamp(m.zoom + dz, lo, hi)
    if nz == m.zoom: return
    let wx = cx + (px - float(r.x + r.w div 2))
    let wy = cy + (py - float(r.y + r.h div 2))
    let k = pow(2.0, nz - m.zoom)
    m.zoom = nz
    scale = base * pow(2.0, nz)
    cx = wx * k - (px - float(r.x + r.w div 2))
    cy = wy * k - (py - float(r.y + r.h div 2))
    m.setCenter(cx, cy, scale)
  if showZoom:
    if zhit[0].clicked: m.zoomAround(float(r.x + r.w div 2), float(r.y + r.h div 2), 1)
    if zhit[1].clicked: m.zoomAround(float(r.x + r.w div 2), float(r.y + r.h div 2), -1)
  if canInput():
    if ui.pressed and mouseIn(r):
      m.pressX = ui.mx
      m.pressY = ui.my
      m.lastX = ui.mx
      m.lastY = ui.my
      m.moved = false
      if ui.active == id and ui.clicks >= 2 and not finger():
        m.zoomAround(float(ui.mx), float(ui.my), 1)
        m.moved = true
    elif ui.active == id and ui.mouseDown and not finger():
      if abs(ui.mx - m.pressX) + abs(ui.my - m.pressY) > dp(4): m.moved = true
      if m.moved and (ui.mx != m.lastX or ui.my != m.lastY):
        cx -= float(ui.mx - m.lastX)
        cy -= float(ui.my - m.lastY)
        m.setCenter(cx, cy, scale)
        m.lastX = ui.mx
        m.lastY = ui.my
      ui.cursor = curHand
    if (ui.panX != 0 or ui.panY != 0) and not ui.panUsed and r.contains(ui.panFrom):
      ui.panUsed = true
      m.moved = true
      cx -= float(ui.panX)
      cy -= float(ui.panY)
      m.setCenter(cx, cy, scale)
    if ui.gesturing and ui.pinch != 1 and r.contains(point(ui.pinchX, ui.pinchY)):
      m.zoomAround(float(ui.pinchX), float(ui.pinchY), log2(ui.pinch))
      m.moved = true
    if finger() and hit.clicked and ui.clicks >= 2: m.zoomAround(float(ui.mx), float(ui.my), 1)
    if mouseIn(r) and ui.wheel != 0 and not ui.wheelUsed:
      ui.wheelUsed = true
      m.zoomAround(float(ui.mx), float(ui.my), float(ui.wheel) * 0.5)
    if hit.focused and ui.key != KeyNone:
      let step = float(dp(80))
      case ui.key
      of KeyLeft: (cx -= step; m.setCenter(cx, cy, scale))
      of KeyRight: (cx += step; m.setCenter(cx, cy, scale))
      of KeyUp: (cy -= step; m.setCenter(cx, cy, scale))
      of KeyDown: (cy += step; m.setCenter(cx, cy, scale))
      of KeyPlus, KeyEqual: m.zoomAround(float(r.x + r.w div 2), float(r.y + r.h div 2), 1)
      of KeyMinus: m.zoomAround(float(r.x + r.w div 2), float(r.y + r.h div 2), -1)
      else: discard
  result.moved = before != (m.zoom, m.lat, m.lon)
  # where things are on the screen
  let ox = float(r.x + r.w div 2) - cx
  let oy = float(r.y + r.h div 2) - cy
  proc scr(p: LatLon): (float, float) =
    let q = toMap(p)
    (worldX(q.lon, scale) + ox, worldY(q.lat, scale) + oy)
  let mx = float(ui.mx)
  let my = float(ui.my)
  block:
    let p = fromMap((latOf(clamp(my - oy, 0, scale), scale), lonOf(mx - ox, scale)))
    result.lat = p.lat
    result.lon = ((p.lon + 540) mod 360) - 180
  # ---- the tiles
  fill(r, if src.format == tfVector: src.style.background else: mixColor(th.face, th.field, 0.5))
  pushClip(r)
  if collect(): ui.redraw = true
  let dense = pxScale >= 2 or uiScale() >= 150
  var labelsHere: seq[(float, float, float, TileLabel)]     # x, y (screen), the tile's scale
  let zoomNow = m.zoom
  proc drawLayer(s: TileSource; collectLabels: bool) =
    let sid = sourceId(s)
    # the tiles' zoom: a 512-pixel tile covers the area of four 256-pixel ones
    let off = if s.tileSize >= 512: 1.0 else: 0.0
    let wantZ = int(round(zoomNow - off))
    let z = clamp(wantZ, s.minZoom, max(s.minZoom, s.maxZoom))
    let n = 1 shl z
    let tw = scale / float(n)                       # a tile's size on the screen
    # vector tiles drawn at the screen's pixels (a whole number of them, 256 .. 1024)
    let px = if s.format == tfVector: clamp(int(ceil(tw * float(pxScale) / 128)) * 128, 256, 1024)
             elif dense and s.hiDpi: 2 else: 1
    let x0 = int(floor((float(r.x) - ox) / tw))
    let x1 = int(floor((float(r.x + r.w - 1) - ox) / tw))
    let y0 = max(0, int(floor((float(r.y) - oy) / tw)))
    let y1 = min(n - 1, int(floor((float(r.y + r.h - 1) - oy) / tw)))
    # the middle ones first
    var wanted: seq[(float, int, int)]
    for ty in y0 .. y1:
      for tx in x0 .. x1:
        let d = abs(float(tx) + 0.5 - (cx / tw)) + abs(float(ty) + 0.5 - (cy / tw))
        wanted.add (d, tx, ty)
    wanted.sort(proc (a, b: (float, int, int)): int = cmp(a[0], b[0]))
    for (_, tx, ty) in wanted:
      let wx = ((tx mod n) + n) mod n                # the world again east and west
      let sx = float(tx) * tw + ox
      let sy = float(ty) * tw + oy
      let rr = rect(int(floor(sx)), int(floor(sy)), int(floor(sx + tw)) - int(floor(sx)),
                    int(floor(sy + tw)) - int(floor(sy)))
      let key: TileKey = (sid, z, wx, ty, px)
      let e = tiles.getOrDefault(key)
      if e != nil and e.state == tsReady:
        e.used = tileFrame
        drawBitmap(rr, e.bmp)
        if collectLabels and e.labels.len > 0:
          let k = tw / float(e.bmp.w)
          for l in e.labels: labelsHere.add (sx + l.x * k, sy + l.y * k, k, l)
        continue
      if e == nil or e.state in {tsLoading, tsFailed}: request(s, sid, z, wx, ty, px, dense and s.hiDpi)
      # while it comes (or where the service has none at this zoom): a tile
      # above it, larger (up to four zooms up)
      for up in 1 .. min(4, z - s.minZoom):
        let pz = z - up
        let pkey: TileKey = (sid, pz, wx shr up, ty shr up, px)
        let pe = tiles.getOrDefault(pkey)
        if pe != nil and pe.state == tsReady:
          pe.used = tileFrame
          let span = tw * float(1 shl up)
          let px0 = sx - float(wx and ((1 shl up) - 1)) * tw
          let py0 = sy - float(ty and ((1 shl up) - 1)) * tw
          pushClip(rr)
          drawBitmap(rect(int(floor(px0)), int(floor(py0)), int(ceil(span)) + 1, int(ceil(span)) + 1), pe.bmp)
          popClip()
          break
  drawLayer(src, true)
  for o in overlays: drawLayer(o, true)
  result.loading = loadingTiles()
  if result.loading > 0: wakeIn(40)
  # ---- shapes
  let lineDefault = th.select
  for k, sh in shapes:
    let col = if sh.color.a != 0: sh.color else: lineDefault
    let wdt = dpf(if sh.width > 0: sh.width else: 3.0)
    case sh.kind
    of msLine:
      var prev = (0.0, 0.0)
      for i, p in sh.points:
        let q = scr(p)
        if i > 0:
          thickLine(prev[0], prev[1], q[0], q[1], wdt, col)
          disc(q[0], q[1], wdt / 2, col)
        prev = q
    of msPolygon:
      var rings: seq[seq[(float, float)]]
      var outer: seq[(float, float)]
      for p in sh.points: outer.add scr(p)
      rings.add outer
      for hole in sh.holes:
        var hr: seq[(float, float)]
        for p in hole: hr.add scr(p)
        rings.add hr
      if sh.fill.a != 0: fillContours(rings, sh.fill)
      if sh.color.a != 0 or sh.fill.a == 0:
        for ring in rings:
          for i in 0 ..< ring.len:
            let a = ring[i]
            let b = ring[(i + 1) mod ring.len]
            thickLine(a[0], a[1], b[0], b[1], wdt, col)
    of msCircle:
      if sh.points.len == 0: continue
      let c = scr(sh.points[0])
      let edge = scr(destination(sh.points[0], 90, sh.radiusM))
      let rad = abs(edge[0] - c[0])
      if sh.fill.a != 0: disc(c[0], c[1], rad, sh.fill)
      ring(c[0], c[1], rad, wdt, col)
    # what the mouse is on
    if canHover() and mouseIn(r) and sh.label.len > 0:
      var on = false
      case sh.kind
      of msCircle:
        if sh.points.len > 0:
          on = distanceM(sh.points[0], (result.lat, result.lon)) <= sh.radiusM
      of msPolygon:
        var inside = false
        let pts = sh.points
        var j = pts.high
        for i in 0 .. pts.high:
          if (pts[i].lat > result.lat) != (pts[j].lat > result.lat) and
             result.lon < (pts[j].lon - pts[i].lon) * (result.lat - pts[i].lat) /
                          (pts[j].lat - pts[i].lat) + pts[i].lon:
            inside = not inside
          j = i
        on = inside
      of msLine:
        for i in 1 ..< sh.points.len:
          let a = scr(sh.points[i - 1])
          let b = scr(sh.points[i])
          let dx = b[0] - a[0]
          let dy = b[1] - a[1]
          let l2 = dx * dx + dy * dy
          let t = if l2 > 0: clamp(((mx - a[0]) * dx + (my - a[1]) * dy) / l2, 0, 1) else: 0.0
          if hypot(mx - a[0] - t * dx, my - a[1] - t * dy) <= wdt / 2 + dpf(3):
            on = true
            break
      if on: result.shape = k
  # ---- the labels of vector tiles: the most important first, none over another
  if labelsHere.len > 0:
    labelsHere.sort(proc (a, b: (float, float, float, TileLabel)): int = cmp(b[3].priority, a[3].priority))
    var placed: seq[Rect]
    var seen: Table[string, (float, float)]
    for (x, y, k, l) in labelsHere:
      if placed.len >= 160: break
      if l.text in seen:
        let (px0, py0) = seen[l.text]
        if abs(px0 - x) < dpf(260) and abs(py0 - y) < dpf(160): continue
      let st = case l.size
               of 0: style(size = 0.85)
               of 2: style(bold = true, size = 1.1)
               of 3: style(bold = true, size = 1.25)
               else: style()
      let tw = textWidth(l.text, st)
      let lh = lineHeight(st)
      let lr = rect(int(x) - tw div 2 - dp(2), int(y) - lh div 2 - dp(1), tw + dp(4), lh + dp(2))
      if lr.x < r.x or lr.y < r.y or lr.x + lr.w > r.x + r.w or lr.y + lr.h > r.y + r.h: continue
      var free = true
      for q in placed:
        if q.x < lr.x + lr.w and lr.x < q.x + q.w and q.y < lr.y + lr.h and lr.y < q.y + q.h:
          free = false
          break
      if not free: continue
      placed.add lr
      seen[l.text] = (x, y)
      let tx = int(x) - tw div 2
      let ty = int(y) - lh div 2
      let halo = src.style.labelHalo
      for (ddx, ddy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)]:
        text(tx + ddx, ty + ddy, l.text, halo, st)
      text(tx, ty, l.text, l.color, st)
  # ---- markers
  m.hoverMarker = -1
  for k, mk in markers:
    let (x, y) = scr((mk.lat, mk.lon))
    let rad = dpf(if mk.size > 0: mk.size else: 6.0)
    if x < float(r.x) - rad - 200 or y < float(r.y) - rad - 50 or x > float(r.x + r.w) + rad + 200 or
       y > float(r.y + r.h) + rad + 50: continue
    if canHover() and hypot(mx - x, my - y) <= rad + dpf(3): m.hoverMarker = k
  for k, mk in markers:
    let (x, y) = scr((mk.lat, mk.lon))
    let rad = dpf(if mk.size > 0: mk.size else: 6.0)
    if x < float(r.x) - rad or y < float(r.y) - rad or x > float(r.x + r.w) + rad or
       y > float(r.y + r.h) + rad: continue
    let c = if mk.color.a != 0: mk.color else: th.select
    let lit = k == m.hoverMarker
    disc(x, y + dpf(1.5), rad + 1.5, mixColor(th.text, th.window, 0.6))     # (its shadow)
    disc(x, y, rad + 1.5, th.window)
    disc(x, y, rad, if lit: mixColor(c, th.window, 0.3) else: c)
    if mk.label.len > 0:
      let tw = textWidth(mk.label, lit)
      let tx = int(x + rad) + dp(4)
      let ty = int(y) - FontH div 2
      for (ddx, ddy) in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
        text(tx + ddx, ty + ddy, mk.label, th.window)
      text(tx, ty, mk.label, th.text, lit)
  result.marker = m.hoverMarker
  # ---- a click (not a drag)
  if hit.clicked and not m.moved:
    result.clicked = true
  # ---- the scale, the zoom buttons, the attribution
  if showScale:
    let mpp = 156543.03392 * cos(m.lat * PI / 180) / pow(2.0, m.zoom) * 256 / base
    let want = mpp * float(dp(100))
    let p10 = pow(10.0, floor(log10(max(1e-9, want))))
    var nice = p10
    for f in [5.0, 2.0, 1.0]:
      if f * p10 <= want:
        nice = f * p10
        break
    let len = int(nice / mpp)
    let label = if nice >= 1000: $int(nice / 1000) & " km" else: $int(nice) & " m"
    let sx = r.x + dp(8)
    let sy = r.y + r.h - dp(10)
    let st = style(size = 0.85)
    for (ddx, ddy) in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
      text(sx + ddx, sy - lineHeight(st) - dp(2) + ddy, label, th.window, st)
    text(sx, sy - lineHeight(st) - dp(2), label, th.text, st)
    fill(rect(sx, sy, len, dp(3)), th.window)
    fill(rect(sx, sy + 1, len, max(1, dp(1))), th.text)
    fill(rect(sx, sy - dp(3), max(1, dp(1)), dp(5)), th.text)
    fill(rect(sx + len - 1, sy - dp(3), max(1, dp(1)), dp(5)), th.text)
  if showZoom:
    for k in 0 .. 1:
      let b = zr[k]
      buttonFace(b, zhit[k].down, rounded = false, bevel = 1, hot = hovered(b))
      let o = if zhit[k].down: 1 else: 0
      let bx = b.x + b.w div 2 + o
      let by = b.y + b.h div 2 + o
      let a = max(3, b.w div 4)
      fill(rect(bx - a, by - 1, 2 * a + 1, 2), th.text)
      if k == 0: fill(rect(bx - 1, by - a, 2, 2 * a + 1), th.text)
    for k, t in ["Zoom in (+)", "Zoom out (-)"]:
      if canInput() and mouseIn(zr[k]): ui.tip = t
  var attr = src.attribution
  for o in overlays:
    if o.attribution.len > 0 and o.attribution notin attr: attr.add " · " & o.attribution
  if attr.len > 0:
    let st = style(size = 0.8)
    let tw = min(r.w - dp(8), textWidth(attr, st) + dp(8))
    let ab = rect(r.x + r.w - tw, r.y + r.h - lineHeight(st) - dp(2), tw, lineHeight(st) + dp(2))
    fill(ab, mixColor(th.window, th.face, 0.2))
    text(ab.x + dp(4), ab.y + dp(1), attr, mixColor(th.text, th.window, 0.25), st)
  # what is under the mouse
  var tip = ""
  if m.hoverMarker >= 0:
    let mk = markers[m.hoverMarker]
    tip = if mk.info.len > 0: mk.info else: mk.label
  elif result.shape >= 0:
    tip = shapes[result.shape].label
  if tip.len > 0 and canHover() and not (ui.mouseDown and m.moved):
    let tw = textWidth(tip) + dp(10)
    var tx = ui.mx + dp(14)
    var ty = ui.my + dp(12)
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

proc mapPointOf*(m: TileMapState; src: TileSource; p: LatLon): tuple[x, y: int] =
  ## Where `p` is drawn in the last `tileMap` of `m` (logical pixels).
  let base = dpf(256)
  let scale = base * pow(2.0, m.zoom)
  let c = if src.gcj02: wgsToGcj((m.lat, m.lon)) else: (m.lat, m.lon)
  let q = if src.gcj02: wgsToGcj(p) else: p
  let r = m.view
  (int(worldX(q.lon, scale) - worldX(c.lon, scale) + float(r.x + r.w div 2)),
   int(worldY(q.lat, scale) - worldY(c.lat, scale) + float(r.y + r.h div 2)))

# ---- maps kept for when there is no network ---------------------------------------

proc tilesIn*(south, west, north, east: float; minZoom, maxZoom: int): int =
  ## How many tiles an area has from `minZoom` to `maxZoom`.
  for z in minZoom .. maxZoom:
    let n = 1 shl z
    let s = float(n)
    let x0 = clamp(int(floor(worldX(west, s))), 0, n - 1)
    let x1 = clamp(int(floor(worldX(east, s))), 0, n - 1)
    let y0 = clamp(int(floor(worldY(north, s))), 0, n - 1)
    let y1 = clamp(int(floor(worldY(south, s))), 0, n - 1)
    result += (x1 - x0 + 1) * (y1 - y0 + 1)

proc keepArea*(src: TileSource; south, west, north, east: float; minZoom, maxZoom: int): string =
  ## Fetches an area's tiles into the disk cache, for a map that works
  ## without the network (a car, a kiosk); "" when it was asked, else why
  ## not. OpenStreetMap's own servers do not allow it (their rule):
  ## take a service that does, or a .pmtiles file of the area.
  if "tile.openstreetmap.org" in src.url:
    return "OpenStreetMap's tile servers are not for keeping areas (their usage policy)"
  if src.file.len > 0: return ""
  let n = tilesIn(south, west, north, east, minZoom, maxZoom)
  if n > 50_000: return "too many tiles (" & $n & "): a smaller area or fewer zooms"
  var s = src
  if s.cacheDays <= 0: s.cacheDays = 3650
  let sid = sourceId(s)
  for z in minZoom .. maxZoom:
    let nn = 1 shl z
    let sc = float(nn)
    for x in clamp(int(floor(worldX(west, sc))), 0, nn - 1) .. clamp(int(floor(worldX(east, sc))), 0, nn - 1):
      for y in clamp(int(floor(worldY(north, sc))), 0, nn - 1) .. clamp(int(floor(worldY(south, sc))), 0, nn - 1):
        # (only the bytes kept: px 0 marks a tile not drawn)
        var job = TileJob(key: (sid, z, x, y, 0), z: z, x: x, y: y, url: s.tileUrl(z, x, y),
                          headers: s.headers & @[("User-Agent", agent())], diskDays: s.cacheDays)
        job.diskPath = s.diskPathOf(z, x, y, false)
        if job.diskPath.len > 0 and not fresh(job.diskPath, s.cacheDays):
          pendingKeys[job.key] = high(int) div 2
          queueTile(job)
  ""

# ---- shapes from what `geo` gives ---------------------------------------------------

proc routeShape*(r: Route; color = Color(); width = 5.0; label = ""): MapShape =
  ## A route found by `geo.route` as a line on the map.
  MapShape(kind: msLine, points: r.points, color: color, width: width,
           label: if label.len > 0: label else: distanceText(r.distanceM) & ", " & durationText(r.durationS))

proc geoJsonShapes*(text: string; color = Color(); fill = Color()): tuple[shapes: seq[MapShape]; markers: seq[MapMarker]] =
  ## The lines and areas of a GeoJSON text as shapes, its points as markers.
  for f in readGeoJson(text):
    case f.kind
    of gkPoint:
      result.markers.add MapMarker(lat: f.points[0].lat, lon: f.points[0].lon, label: f.name)
    of gkLine:
      result.shapes.add MapShape(kind: msLine, points: f.points, color: color, label: f.name)
    of gkPolygon:
      result.shapes.add MapShape(kind: msPolygon, points: f.points, holes: f.holes, color: color,
                                 fill: fill, label: f.name)

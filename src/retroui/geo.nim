## Places and ways on the earth: finding a place by its name or address
## (geocoding) and the name of a place (reverse), a route between places
## with its turns, and what goes with them -- distances, the encoded lines
## routing services send, China's map coordinates, GeoJSON.
##
## .. code-block:: nim
##   let found = geocode("Royal Opera House Muscat")          # OpenStreetMap's Nominatim
##   if found.ok and found.places.len > 0:
##     echo found.places[0].name, " ", found.places[0].lat, " ", found.places[0].lon
##   let r = route(@[(23.588, 58.382), (23.614, 58.593)])    # OSRM
##   if r.ok: echo r.route.distanceM / 1000, " km, ", r.route.durationS div 60, " min"
##
## Every service there is: `GeoService` names whose (OpenStreetMap's
## Nominatim and Photon, OSRM, Valhalla, GraphHopper, OpenRouteService,
## Google, Mapbox, HERE, Azure Maps, TomTom, MapTiler, Esri), with the key
## the service gave you (`GeoService.key`). The free ones of OpenStreetMap
## are for light use (one request a second, a name for your app:
## `GeoService.agent`); a business app takes a service with a key, or its
## own server (`GeoService.base`: your Nominatim, OSRM or Valhalla).
##
## The calls wait for the answer (a second, about): from a frame, ask in
## the background (`geocodeAsync`, `routeAsync`) and take the answer when
## it is there (`geoFinished`). What a service sends back is read by
## `readPlaces` and `readRoute` (for answers fetched another way).
##
## Coordinates are degrees, (latitude, longitude), north and east
## positive, WGS 84 (GPS) -- except where it says GCJ-02 (`wgsToGcj`).

import std/[json, math, strutils, uri]
import http

type
  LatLon* = tuple[lat, lon: float]

  GeoProvider* = enum
    ## Who answers.
    gpNominatim = "Nominatim"           ## OpenStreetMap's search (places, reverse)
    gpPhoton = "Photon"                 ## komoot's search over OpenStreetMap
    gpOsrm = "OSRM"                     ## routes over OpenStreetMap
    gpValhalla = "Valhalla"             ## routes over OpenStreetMap
    gpGraphHopper = "GraphHopper"       ## routes (a key)
    gpOpenRouteService = "OpenRouteService"  ## routes and places (a key)
    gpGoogle = "Google"                 ## Geocoding API, Routes API (a key)
    gpMapbox = "Mapbox"                 ## Geocoding v6, Directions (a token)
    gpHere = "HERE"                     ## Geocoding & Search, Routing v8 (a key)
    gpAzure = "Azure Maps"              ## Search, Route (a key)
    gpTomTom = "TomTom"                 ## Search, Routing (a key)
    gpMapTiler = "MapTiler"             ## Geocoding (a key)
    gpEsri = "Esri"                     ## ArcGIS geocoding, routing (a key)

  GeoService* = object
    ## A service and how to reach it.
    provider*: GeoProvider
    key*: string          ## the key (the token) the service gave you
    base*: string         ## its address when it is your own server ("" theirs)
    language*: string     ## the names in this language ("en", "ar"; "" the service's)
    agent*: string        ## your app's name and how to reach you (OpenStreetMap's rule)
    profile*: string      ## routes: "car" (default), "bike", "foot", "truck"

  Place* = object
    ## A place found.
    name*: string         ## its address or name, as the service writes it
    lat*, lon*: float
    kind*: string         ## what it is ("city", "street", "house"...; "" not said)
    country*: string      ## its country (a code or a name, as given)
    south*, west*, north*, east*: float   ## the area it covers (all 0: not given)

  RouteStep* = object
    ## One turn of a route.
    text*: string         ## "Turn left onto Sultan Qaboos Street"
    distanceM*: float     ## how far to the next one
    durationS*: int
    lat*, lon*: float     ## where it is

  Route* = object
    ## A way from the first place to the last.
    points*: seq[LatLon]  ## the way on the map
    distanceM*: float     ## how long, in meters
    durationS*: int       ## how long it takes, in seconds
    steps*: seq[RouteStep]

  PlacesAnswer* = object
    ok*: bool
    places*: seq[Place]
    error*: string        ## why not (no network, a wrong key...)

  RouteAnswer* = object
    ok*: bool
    route*: Route         ## the best one
    alternatives*: seq[Route]
    error*: string

proc service*(provider: GeoProvider; key = ""; base = ""; language = ""): GeoService =
  ## A service to ask: `service(gpGoogle, "AIza...")`.
  GeoService(provider: provider, key: key, base: base, language: language)

# ---- distances ----------------------------------------------------------------------

const EarthRadiusM* = 6371008.8   ## the earth's mean radius

proc distanceM*(a, b: LatLon): float =
  ## How far apart two places are on the earth (meters, along its surface).
  let p1 = degToRad(a.lat)
  let p2 = degToRad(b.lat)
  let dp = p2 - p1
  let dl = degToRad(b.lon - a.lon)
  let h = sin(dp / 2) ^ 2 + cos(p1) * cos(p2) * sin(dl / 2) ^ 2
  2 * EarthRadiusM * arcsin(min(1.0, sqrt(h)))

proc bearing*(a, b: LatLon): float =
  ## Which way `b` is from `a`: degrees from north, clockwise (0..360).
  let p1 = degToRad(a.lat)
  let p2 = degToRad(b.lat)
  let dl = degToRad(b.lon - a.lon)
  let y = sin(dl) * cos(p2)
  let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
  (radToDeg(arctan2(y, x)) + 360) mod 360

proc destination*(a: LatLon; bearingDeg, distM: float): LatLon =
  ## Where you are after `distM` meters toward `bearingDeg` from `a`.
  let d = distM / EarthRadiusM
  let t = degToRad(bearingDeg)
  let p1 = degToRad(a.lat)
  let l1 = degToRad(a.lon)
  let p2 = arcsin(sin(p1) * cos(d) + cos(p1) * sin(d) * cos(t))
  let l2 = l1 + arctan2(sin(t) * sin(d) * cos(p1), cos(d) - sin(p1) * sin(p2))
  (radToDeg(p2), ((radToDeg(l2) + 540) mod 360) - 180)

proc lengthM*(points: openArray[LatLon]): float =
  ## How long a line through `points` is (meters).
  for i in 1 ..< points.len: result += distanceM(points[i - 1], points[i])

proc distanceText*(m: float): string =
  ## "850 m", "12.4 km", "120 km".
  if m < 1000: $int(round(m)) & " m"
  elif m < 100_000: formatFloat(m / 1000, ffDecimal, 1) & " km"
  else: $int(round(m / 1000)) & " km"

proc durationText*(s: int): string =
  ## "45 s", "12 min", "2 h 5 min".
  if s < 60: $s & " s"
  elif s < 3600: $((s + 30) div 60) & " min"
  else:
    let m = (s + 30) div 60
    $(m div 60) & " h" & (if m mod 60 > 0: " " & $(m mod 60) & " min" else: "")

# ---- the lines routing services send ---------------------------------------------

proc decodePolyline*(s: string; precision = 5): seq[LatLon] =
  ## Google's encoded polyline (OSRM, Mapbox, Valhalla and GraphHopper send
  ## it too; their `precision` is 6 or 5 as they say).
  let k = pow(10.0, float(precision))
  var i = 0
  var lat, lon = 0
  while i < s.len:
    var vals: array[2, int]
    for n in 0 .. 1:
      var shift = 0
      var v = 0
      while true:
        if i >= s.len: return
        let b = ord(s[i]) - 63
        inc i
        if b < 0: return
        v = v or ((b and 0x1F) shl shift)
        shift += 5
        if b < 0x20: break
        if shift > 60: return
      vals[n] = if (v and 1) != 0: not (v shr 1) else: v shr 1
    lat += vals[0]
    lon += vals[1]
    result.add (lat.float / k, lon.float / k)

proc encodePolyline*(points: openArray[LatLon]; precision = 5): string =
  ## `points` as an encoded polyline (what `decodePolyline` reads).
  let k = pow(10.0, float(precision))
  var plat, plon = 0
  proc put(r: var string; v: int) =
    var u = if v < 0: not (v shl 1) else: v shl 1
    while u >= 0x20:
      r.add char((0x20 or (u and 0x1F)) + 63)
      u = u shr 5
    r.add char(u + 63)
  for p in points:
    let la = int(round(p.lat * k))
    let lo = int(round(p.lon * k))
    result.put(la - plat)
    result.put(lo - plon)
    plat = la
    plon = lo

proc decodeFlexPolyline*(s: string): seq[LatLon] =
  ## HERE's flexible polyline (what Routing v8 sends): its header says the
  ## precision and whether a third number (height) comes with each point.
  const table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  var i = 0
  proc next(ok: var bool): int64 =
    var shift = 0
    var v = 0'i64
    while true:
      if i >= s.len:
        ok = false
        return
      let b = table.find(s[i])
      inc i
      if b < 0:
        ok = false
        return
      v = v or (int64(b and 0x1F) shl shift)
      shift += 5
      if b < 0x20: break
      if shift > 60:
        ok = false
        return
    v
  var ok = true
  let version = next(ok)
  if not ok or version != 1: return
  let header = next(ok)
  if not ok: return
  let prec = int(header and 15)
  let third = int((header shr 4) and 7)
  let k = pow(10.0, float(prec))
  var lat, lon = 0'i64
  while i < s.len:
    var vals: array[3, int64]
    for n in 0 ..< (if third != 0: 3 else: 2):
      let u = next(ok)
      if not ok: return
      vals[n] = if (u and 1) != 0: not (u shr 1) else: u shr 1
    lat += vals[0]
    lon += vals[1]
    result.add (lat.float / k, lon.float / k)

# ---- China's coordinates ------------------------------------------------------------

# Maps of China (AMap/Gaode, Tencent; Baidu on top of it) are drawn in
# GCJ-02, GPS's coordinates moved by a few hundred meters: a GPS position
# drawn on them as it is lands beside the road. These move between them.

proc outOfChina(lat, lon: float): bool =
  lon < 72.004 or lon > 137.8347 or lat < 0.8293 or lat > 55.8271

proc gcjDelta(lat, lon: float): LatLon =
  const a = 6378245.0
  const ee = 0.00669342162296594323
  let x = lon - 105.0
  let y = lat - 35.0
  var dLat = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
  dLat += (20.0 * sin(6.0 * x * PI) + 20.0 * sin(2.0 * x * PI)) * 2.0 / 3.0
  dLat += (20.0 * sin(y * PI) + 40.0 * sin(y / 3.0 * PI)) * 2.0 / 3.0
  dLat += (160.0 * sin(y / 12.0 * PI) + 320 * sin(y * PI / 30.0)) * 2.0 / 3.0
  var dLon = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
  dLon += (20.0 * sin(6.0 * x * PI) + 20.0 * sin(2.0 * x * PI)) * 2.0 / 3.0
  dLon += (20.0 * sin(x * PI) + 40.0 * sin(x / 3.0 * PI)) * 2.0 / 3.0
  dLon += (150.0 * sin(x / 12.0 * PI) + 300.0 * sin(x / 30.0 * PI)) * 2.0 / 3.0
  let radLat = lat / 180.0 * PI
  var magic = sin(radLat)
  magic = 1 - ee * magic * magic
  let sqrtMagic = sqrt(magic)
  dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * PI)
  dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * PI)
  (dLat, dLon)

proc wgsToGcj*(p: LatLon): LatLon =
  ## A GPS (WGS 84) position as China's maps draw it (GCJ-02); outside
  ## China as it is.
  if outOfChina(p.lat, p.lon): return p
  let d = gcjDelta(p.lat, p.lon)
  (p.lat + d.lat, p.lon + d.lon)

proc gcjToWgs*(p: LatLon): LatLon =
  ## A GCJ-02 position (from a map of China) as GPS has it: found again by
  ## steps, within a few centimeters.
  if outOfChina(p.lat, p.lon): return p
  var g = (lat: p.lat, lon: p.lon)
  for _ in 0 ..< 8:
    let back = wgsToGcj(g)
    g = (g.lat - (back.lat - p.lat), g.lon - (back.lon - p.lon))
  g

proc gcjToBd*(p: LatLon): LatLon =
  ## GCJ-02 to Baidu's BD-09.
  let x = p.lon
  let y = p.lat
  let z = sqrt(x * x + y * y) + 0.00002 * sin(y * PI * 3000.0 / 180.0)
  let t = arctan2(y, x) + 0.000003 * cos(x * PI * 3000.0 / 180.0)
  (z * sin(t) + 0.006, z * cos(t) + 0.0065)

proc bdToGcj*(p: LatLon): LatLon =
  ## Baidu's BD-09 to GCJ-02.
  let x = p.lon - 0.0065
  let y = p.lat - 0.006
  let z = sqrt(x * x + y * y) - 0.00002 * sin(y * PI * 3000.0 / 180.0)
  let t = arctan2(y, x) - 0.000003 * cos(x * PI * 3000.0 / 180.0)
  (z * sin(t), z * cos(t))

# ---- GeoJSON --------------------------------------------------------------------------

type
  GeoKind* = enum
    gkPoint, gkLine, gkPolygon
  GeoFeature* = object
    ## A thing of a GeoJSON file: a point, a line or an area (with its holes).
    kind*: GeoKind
    points*: seq[LatLon]          ## gkPoint: one; gkLine: the line; gkPolygon: its outline
    holes*: seq[seq[LatLon]]      ## gkPolygon: what is cut out of it
    properties*: JsonNode         ## what the file says of it ({} none)
    name*: string                 ## properties.name (or title), "" none

proc readGeoJson*(text: string): seq[GeoFeature] =
  ## The points, lines and areas of a GeoJSON text (a FeatureCollection, a
  ## Feature or a geometry); multi-geometries as many features. Nothing
  ## when it is not GeoJSON.
  let root = try: parseJson(text) except CatchableError: return
  proc pos(n: JsonNode): (bool, LatLon) =
    if n == nil or n.kind != JArray or n.len < 2: return (false, (0.0, 0.0))
    let lon = n[0].getFloat(n[0].getInt.float)
    let lat = n[1].getFloat(n[1].getInt.float)
    (true, (lat, lon))
  proc ring(n: JsonNode): seq[LatLon] =
    if n == nil or n.kind != JArray: return
    for p in n:
      let (ok, q) = pos(p)
      if ok: result.add q
  var res: seq[GeoFeature]
  proc geometry(g: JsonNode; props: JsonNode) =
    if g == nil or g.kind != JObject: return
    let t = g{"type"}.getStr
    let c = g{"coordinates"}
    let name = if props != nil and props.kind == JObject:
                 (if props.hasKey("name"): props["name"].getStr else: props{"title"}.getStr)
               else: ""
    let pr = if props == nil: newJObject() else: props
    case t
    of "Point":
      let (ok, q) = pos(c)
      if ok: res.add GeoFeature(kind: gkPoint, points: @[q], properties: pr, name: name)
    of "MultiPoint":
      for p in ring(c): res.add GeoFeature(kind: gkPoint, points: @[p], properties: pr, name: name)
    of "LineString":
      res.add GeoFeature(kind: gkLine, points: ring(c), properties: pr, name: name)
    of "MultiLineString":
      if c != nil and c.kind == JArray:
        for l in c: res.add GeoFeature(kind: gkLine, points: ring(l), properties: pr, name: name)
    of "Polygon":
      if c != nil and c.kind == JArray and c.len > 0:
        var f = GeoFeature(kind: gkPolygon, points: ring(c[0]), properties: pr, name: name)
        for k in 1 ..< c.len: f.holes.add ring(c[k])
        res.add f
    of "MultiPolygon":
      if c != nil and c.kind == JArray:
        for poly in c:
          if poly.kind == JArray and poly.len > 0:
            var f = GeoFeature(kind: gkPolygon, points: ring(poly[0]), properties: pr, name: name)
            for k in 1 ..< poly.len: f.holes.add ring(poly[k])
            res.add f
    of "GeometryCollection":
      if g{"geometries"} != nil:
        for sub in g["geometries"]: geometry(sub, props)
    else: discard
  case root{"type"}.getStr
  of "FeatureCollection":
    if root{"features"} != nil and root["features"].kind == JArray:
      for f in root["features"]: geometry(f{"geometry"}, f{"properties"})
  of "Feature": geometry(root{"geometry"}, root{"properties"})
  else: geometry(root, nil)
  res

proc toGeoJson*(features: openArray[GeoFeature]): string =
  ## A FeatureCollection of `features` (what `readGeoJson` reads).
  var fc = %*{"type": "FeatureCollection", "features": []}
  proc arr(ps: openArray[LatLon]): JsonNode =
    result = newJArray()
    for p in ps: result.add %*[p.lon, p.lat]
  for f in features:
    var g: JsonNode
    case f.kind
    of gkPoint: g = %*{"type": "Point", "coordinates": (if f.points.len > 0: %*[f.points[0].lon, f.points[0].lat] else: newJArray())}
    of gkLine: g = %*{"type": "LineString", "coordinates": arr(f.points)}
    of gkPolygon:
      var rings = newJArray()
      rings.add arr(f.points)
      for h in f.holes: rings.add arr(h)
      g = %*{"type": "Polygon", "coordinates": rings}
    var props = if f.properties != nil and f.properties.kind == JObject: f.properties.copy else: newJObject()
    if f.name.len > 0 and not props.hasKey("name"): props["name"] = %f.name
    fc["features"].add %*{"type": "Feature", "geometry": g, "properties": props}
  $fc

# ---- asking the services --------------------------------------------------------------

proc enc(s: string): string = encodeUrl(s, usePlus = false)

proc agentOf(s: GeoService): string =
  if s.agent.len > 0: s.agent else: "RetroNimUI-app (retroui)"

proc baseOr(s: GeoService; theirs: string): string =
  (if s.base.len > 0: s.base else: theirs).strip(chars = {'/'}, leading = false)

proc fnum(n: JsonNode): float =
  ## A number sent as a number or as text.
  if n == nil: return 0
  case n.kind
  of JFloat: n.getFloat
  of JInt: n.getInt.float
  of JString: (try: parseFloat(n.getStr) except ValueError: 0.0)
  else: 0

proc geocodeRequest*(s: GeoService; query: string; limit = 5): tuple[meth, url, body: string; headers: seq[(string, string)]] =
  ## The request that finds `query` at `s` (for `readPlaces`).
  let lang = s.language
  result.meth = "GET"
  result.headers = @[("User-Agent", agentOf(s)), ("Accept", "application/json")]
  case s.provider
  of gpNominatim:
    result.url = s.baseOr("https://nominatim.openstreetmap.org") & "/search?format=jsonv2&addressdetails=0&limit=" &
                 $limit & "&q=" & enc(query) & (if lang.len > 0: "&accept-language=" & enc(lang) else: "")
  of gpPhoton:
    result.url = s.baseOr("https://photon.komoot.io") & "/api/?limit=" & $limit & "&q=" & enc(query) &
                 (if lang.len > 0: "&lang=" & enc(lang) else: "")
  of gpGoogle:
    result.url = s.baseOr("https://maps.googleapis.com") & "/maps/api/geocode/json?address=" & enc(query) &
                 "&key=" & enc(s.key) & (if lang.len > 0: "&language=" & enc(lang) else: "")
  of gpMapbox:
    result.url = s.baseOr("https://api.mapbox.com") & "/search/geocode/v6/forward?limit=" & $limit & "&q=" &
                 enc(query) & "&access_token=" & enc(s.key) & (if lang.len > 0: "&language=" & enc(lang) else: "")
  of gpHere:
    result.url = s.baseOr("https://geocode.search.hereapi.com") & "/v1/geocode?limit=" & $limit & "&q=" &
                 enc(query) & "&apiKey=" & enc(s.key) & (if lang.len > 0: "&lang=" & enc(lang) else: "")
  of gpAzure:
    result.url = s.baseOr("https://atlas.microsoft.com") & "/geocode?api-version=2023-06-01&top=" & $limit &
                 "&query=" & enc(query)
    result.headers.add ("subscription-key", s.key)
    if lang.len > 0: result.headers.add ("Accept-Language", lang)
  of gpTomTom:
    result.url = s.baseOr("https://api.tomtom.com") & "/search/2/geocode/" & enc(query) & ".json?limit=" &
                 $limit & "&key=" & enc(s.key) & (if lang.len > 0: "&language=" & enc(lang) else: "")
  of gpMapTiler:
    result.url = s.baseOr("https://api.maptiler.com") & "/geocoding/" & enc(query) & ".json?limit=" & $limit &
                 "&key=" & enc(s.key) & (if lang.len > 0: "&language=" & enc(lang) else: "")
  of gpEsri:
    result.url = s.baseOr("https://geocode-api.arcgis.com") &
                 "/arcgis/rest/services/World/GeocodeServer/findAddressCandidates?f=json&outFields=Addr_type&maxLocations=" &
                 $limit & "&SingleLine=" & enc(query) & "&token=" & enc(s.key) &
                 (if lang.len > 0: "&langCode=" & enc(lang) else: "")
  of gpOpenRouteService:
    result.url = s.baseOr("https://api.openrouteservice.org") & "/geocode/search?size=" & $limit & "&text=" &
                 enc(query) & "&api_key=" & enc(s.key)
  else:
    result.url = ""

proc reverseRequest*(s: GeoService; p: LatLon): tuple[meth, url, body: string; headers: seq[(string, string)]] =
  ## The request that names the place at `p` (for `readPlaces`).
  let lang = s.language
  let la = formatFloat(p.lat, ffDecimal, 7)
  let lo = formatFloat(p.lon, ffDecimal, 7)
  result.meth = "GET"
  result.headers = @[("User-Agent", agentOf(s)), ("Accept", "application/json")]
  case s.provider
  of gpNominatim:
    result.url = s.baseOr("https://nominatim.openstreetmap.org") & "/reverse?format=jsonv2&lat=" & la & "&lon=" & lo &
                 (if lang.len > 0: "&accept-language=" & enc(lang) else: "")
  of gpPhoton:
    result.url = s.baseOr("https://photon.komoot.io") & "/reverse?lat=" & la & "&lon=" & lo
  of gpGoogle:
    result.url = s.baseOr("https://maps.googleapis.com") & "/maps/api/geocode/json?latlng=" & la & "," & lo &
                 "&key=" & enc(s.key) & (if lang.len > 0: "&language=" & enc(lang) else: "")
  of gpMapbox:
    result.url = s.baseOr("https://api.mapbox.com") & "/search/geocode/v6/reverse?longitude=" & lo & "&latitude=" &
                 la & "&access_token=" & enc(s.key)
  of gpHere:
    result.url = s.baseOr("https://revgeocode.search.hereapi.com") & "/v1/revgeocode?at=" & la & "," & lo &
                 "&apiKey=" & enc(s.key) & (if lang.len > 0: "&lang=" & enc(lang) else: "")
  of gpAzure:
    result.url = s.baseOr("https://atlas.microsoft.com") & "/reverseGeocode?api-version=2023-06-01&coordinates=" &
                 lo & "," & la
    result.headers.add ("subscription-key", s.key)
  of gpTomTom:
    result.url = s.baseOr("https://api.tomtom.com") & "/search/2/reverseGeocode/" & la & "," & lo & ".json?key=" &
                 enc(s.key)
  of gpMapTiler:
    result.url = s.baseOr("https://api.maptiler.com") & "/geocoding/" & lo & "," & la & ".json?key=" & enc(s.key)
  of gpEsri:
    result.url = s.baseOr("https://geocode-api.arcgis.com") &
                 "/arcgis/rest/services/World/GeocodeServer/reverseGeocode?f=json&location=" & lo & "," & la &
                 "&token=" & enc(s.key)
  of gpOpenRouteService:
    result.url = s.baseOr("https://api.openrouteservice.org") & "/geocode/reverse?point.lat=" & la &
                 "&point.lon=" & lo & "&api_key=" & enc(s.key)
  else:
    result.url = ""

proc readPlaces*(provider: GeoProvider; body: string): PlacesAnswer =
  ## The places in what `provider` sent back.
  let j = try: parseJson(body) except CatchableError:
    return PlacesAnswer(error: "the answer is not JSON")
  result.ok = true
  proc geoFeatures(j: JsonNode; nameKeys: openArray[string]): seq[Place] =
    let fs = j{"features"}
    if fs == nil or fs.kind != JArray: return
    for f in fs:
      let c = f{"geometry"}{"coordinates"}
      if c == nil or c.kind != JArray or c.len < 2: continue
      var p = Place(lon: fnum(c[0]), lat: fnum(c[1]))
      let pr = f{"properties"}
      for k in nameKeys:
        var n = pr
        for part in k.split('.'):
          n = if n != nil and n.kind == JObject: n{part} else: nil
        if n != nil and n.kind == JString and n.getStr.len > 0:
          p.name = n.getStr
          break
      if p.name.len == 0: p.name = f{"place_name"}.getStr(f{"text"}.getStr)
      p.kind = pr{"type"}.getStr(pr{"feature_type"}.getStr(pr{"osm_value"}.getStr))
      p.country = pr{"country"}.getStr(pr{"country_code"}.getStr)
      let bb = f{"bbox"}
      if bb != nil and bb.kind == JArray and bb.len == 4:
        (p.west, p.south, p.east, p.north) = (fnum(bb[0]), fnum(bb[1]), fnum(bb[2]), fnum(bb[3]))
      result.add p
  case provider
  of gpNominatim:
    let arr = if j.kind == JArray: j else: (if j.kind == JObject and j.hasKey("lat"): %*[j] else: newJArray())
    if j.kind == JObject and j.hasKey("error"):
      result = PlacesAnswer(error: j["error"].getStr($j["error"])); return
    for e in arr:
      var p = Place(name: e{"display_name"}.getStr, lat: fnum(e{"lat"}), lon: fnum(e{"lon"}),
                    kind: e{"type"}.getStr(e{"addresstype"}.getStr))
      let bb = e{"boundingbox"}
      if bb != nil and bb.kind == JArray and bb.len == 4:
        (p.south, p.north, p.west, p.east) = (fnum(bb[0]), fnum(bb[1]), fnum(bb[2]), fnum(bb[3]))
      result.places.add p
  of gpPhoton:
    result.places = geoFeatures(j, ["name", "street", "city"])
    # (Photon gives the parts: a name, then where)
    for i, p in result.places.mpairs:
      let pr = j["features"][i]{"properties"}
      var parts: seq[string]
      for k in ["name", "street", "housenumber", "city", "state", "country"]:
        let v = pr{k}.getStr
        if v.len > 0 and v notin parts: parts.add v
      if parts.len > 0: p.name = parts.join(", ")
  of gpGoogle:
    let st = j{"status"}.getStr
    if st notin ["OK", "ZERO_RESULTS"]:
      result = PlacesAnswer(error: st & (if j{"error_message"} != nil: ": " & j["error_message"].getStr else: "")); return
    for e in j{"results"}.getElems:
      let loc = e{"geometry"}{"location"}
      var p = Place(name: e{"formatted_address"}.getStr, lat: fnum(loc{"lat"}), lon: fnum(loc{"lng"}))
      let types = e{"types"}
      if types != nil and types.len > 0: p.kind = types[0].getStr
      let vp = e{"geometry"}{"viewport"}
      if vp != nil:
        (p.south, p.west, p.north, p.east) = (fnum(vp{"southwest"}{"lat"}), fnum(vp{"southwest"}{"lng"}),
                                              fnum(vp{"northeast"}{"lat"}), fnum(vp{"northeast"}{"lng"}))
      for c in e{"address_components"}.getElems:
        for t in c{"types"}.getElems:
          if t.getStr == "country": p.country = c{"short_name"}.getStr
      result.places.add p
  of gpMapbox:
    result.places = geoFeatures(j, ["full_address", "name_preferred", "name", "place_formatted"])
    for i, p in result.places.mpairs:
      let pr = j["features"][i]{"properties"}
      let co = pr{"coordinates"}
      if co != nil and co.kind == JObject:
        p.lat = fnum(co{"latitude"})
        p.lon = fnum(co{"longitude"})
      p.country = pr{"context"}{"country"}{"country_code"}.getStr(p.country)
  of gpHere:
    for e in j{"items"}.getElems:
      let pos = e{"position"}
      var p = Place(name: e{"title"}.getStr(e{"address"}{"label"}.getStr), lat: fnum(pos{"lat"}),
                    lon: fnum(pos{"lng"}), kind: e{"resultType"}.getStr,
                    country: e{"address"}{"countryCode"}.getStr)
      let mv = e{"mapView"}
      if mv != nil:
        (p.south, p.west, p.north, p.east) = (fnum(mv{"south"}), fnum(mv{"west"}), fnum(mv{"north"}), fnum(mv{"east"}))
      result.places.add p
    if j{"error"} != nil or j{"title"} != nil and j{"items"} == nil:
      result = PlacesAnswer(error: j{"title"}.getStr(j{"error"}.getStr("an error"))); return
  of gpAzure:
    result.places = geoFeatures(j, ["address.formattedAddress", "name"])
    for i, p in result.places.mpairs:
      let pr = j["features"][i]{"properties"}
      p.kind = pr{"type"}.getStr
      p.country = pr{"address"}{"countryRegion"}{"ISO"}.getStr
  of gpTomTom:
    for e in j{"results"}.getElems:
      let pos = e{"position"}
      var p = Place(name: e{"address"}{"freeformAddress"}.getStr(e{"poi"}{"name"}.getStr),
                    lat: fnum(pos{"lat"}), lon: fnum(pos{"lon"}), kind: e{"type"}.getStr,
                    country: e{"address"}{"countryCode"}.getStr)
      let vp = e{"viewport"}
      if vp != nil:
        (p.north, p.west) = (fnum(vp{"topLeftPoint"}{"lat"}), fnum(vp{"topLeftPoint"}{"lon"}))
        (p.south, p.east) = (fnum(vp{"btmRightPoint"}{"lat"}), fnum(vp{"btmRightPoint"}{"lon"}))
      result.places.add p
    # (reverse: "addresses")
    for e in j{"addresses"}.getElems:
      let ps = e{"position"}.getStr.split(',')
      if ps.len == 2:
        result.places.add Place(name: e{"address"}{"freeformAddress"}.getStr,
                                lat: (try: parseFloat(ps[0]) except ValueError: 0.0),
                                lon: (try: parseFloat(ps[1]) except ValueError: 0.0),
                                country: e{"address"}{"countryCode"}.getStr)
  of gpMapTiler, gpOpenRouteService:
    result.places = geoFeatures(j, ["label", "place_name", "name"])
    for i, p in result.places.mpairs:
      let f = j["features"][i]
      if f{"place_name"} != nil: p.name = f["place_name"].getStr
      let pt = f{"place_type"}
      if pt != nil and pt.kind == JArray and pt.len > 0: p.kind = pt[0].getStr
  of gpEsri:
    if j{"error"} != nil: result = PlacesAnswer(error: j["error"]{"message"}.getStr("an error")); return
    for e in j{"candidates"}.getElems:
      let loc = e{"location"}
      var p = Place(name: e{"address"}.getStr, lat: fnum(loc{"y"}), lon: fnum(loc{"x"}),
                    kind: e{"attributes"}{"Addr_type"}.getStr)
      let ex = e{"extent"}
      if ex != nil:
        (p.west, p.south, p.east, p.north) = (fnum(ex{"xmin"}), fnum(ex{"ymin"}), fnum(ex{"xmax"}), fnum(ex{"ymax"}))
      result.places.add p
    if j{"address"} != nil and j{"location"} != nil:
      let a = j["address"]
      result.places.add Place(name: a{"LongLabel"}.getStr(a{"Match_addr"}.getStr),
                              lat: fnum(j["location"]{"y"}), lon: fnum(j["location"]{"x"}),
                              country: a{"CountryCode"}.getStr)
  else:
    result = PlacesAnswer(error: $provider & " does not find places"); return

proc ask(meth, url, body: string; headers: seq[(string, string)]): (bool, string) =
  if url.len == 0: return (false, "this service does not do that")
  let r = httpRequest(meth, url, headers, body, timeoutSec = 30)
  if r.status == 0: return (false, r.error)
  if r.status >= 400:
    # (the service's own words when it gives them)
    let why = try:
                let j = parseJson(r.body)
                j{"error_message"}.getStr(j{"message"}.getStr(j{"error"}{"message"}.getStr(
                  j{"title"}.getStr(j{"error"}.getStr(""))))).strip
              except CatchableError: ""
    return (false, "HTTP " & $r.status & (if why.len > 0: ": " & why else: ""))
  (true, r.body)

proc geocode*(query: string; s = GeoService()): PlacesAnswer =
  ## The places `query` names (an address, a place, a postcode), the
  ## likeliest first. Waits for the answer.
  let q = geocodeRequest(s, query)
  let (ok, body) = ask(q.meth, q.url, q.body, q.headers)
  if not ok: return PlacesAnswer(error: body)
  readPlaces(s.provider, body)

proc reverseGeocode*(p: LatLon; s = GeoService()): PlacesAnswer =
  ## What is at `p` (its address), the nearest first. Waits for the answer.
  let q = reverseRequest(s, p)
  let (ok, body) = ask(q.meth, q.url, q.body, q.headers)
  if not ok: return PlacesAnswer(error: body)
  readPlaces(s.provider, body)

# ---- routes --------------------------------------------------------------------------

proc profileOf(s: GeoService; car, bike, foot, truck: string): string =
  case s.profile.toLowerAscii
  of "bike", "bicycle", "cycling": bike
  of "foot", "walk", "walking", "pedestrian": foot
  of "truck", "hgv": truck
  else: car

proc ll(p: LatLon; lonFirst = false; sep = ","): string =
  let la = formatFloat(p.lat, ffDecimal, 6)
  let lo = formatFloat(p.lon, ffDecimal, 6)
  if lonFirst: lo & sep & la else: la & sep & lo

proc routeRequest*(s: GeoService; stops: openArray[LatLon]; alternatives = false): tuple[meth, url, body: string; headers: seq[(string, string)]] =
  ## The request for a route through `stops` at `s` (for `readRoute`).
  result.meth = "GET"
  result.headers = @[("User-Agent", agentOf(s)), ("Accept", "application/json")]
  let lang = s.language
  case s.provider
  of gpOsrm, gpMapbox:
    var path: seq[string]
    for p in stops: path.add ll(p, lonFirst = true)
    let alt = if alternatives: "true" else: "false"
    if s.provider == gpOsrm:
      result.url = s.baseOr("https://router.project-osrm.org") & "/route/v1/" &
                   s.profileOf("driving", "cycling", "foot", "driving") & "/" & path.join(";") &
                   "?overview=full&geometries=polyline6&steps=true&alternatives=" & alt
    else:
      result.url = s.baseOr("https://api.mapbox.com") & "/directions/v5/mapbox/" &
                   s.profileOf("driving", "cycling", "walking", "driving-traffic") & "/" & path.join(";") &
                   "?overview=full&geometries=polyline6&steps=true&alternatives=" & alt & "&access_token=" & enc(s.key) &
                   (if lang.len > 0: "&language=" & enc(lang) else: "")
  of gpValhalla:
    result.meth = "POST"
    var locs = newJArray()
    for p in stops: locs.add %*{"lat": p.lat, "lon": p.lon}
    var body = %*{"locations": locs, "costing": s.profileOf("auto", "bicycle", "pedestrian", "truck"),
                  "directions_options": {"units": "kilometers"}}
    if lang.len > 0: body["directions_options"]["language"] = %lang
    if alternatives: body["alternates"] = %2
    result.body = $body
    result.headers.add ("Content-Type", "application/json")
    result.url = s.baseOr("https://valhalla1.openstreetmap.de") & "/route" &
                 (if s.key.len > 0: "?api_key=" & enc(s.key) else: "")
  of gpGraphHopper:
    var q = ""
    for p in stops: q.add "&point=" & ll(p)
    result.url = s.baseOr("https://graphhopper.com/api/1") & "/route?profile=" &
                 s.profileOf("car", "bike", "foot", "truck") & q & "&points_encoded=true&instructions=true&key=" &
                 enc(s.key) & (if lang.len > 0: "&locale=" & enc(lang) else: "") &
                 (if alternatives: "&algorithm=alternative_route" else: "")
  of gpOpenRouteService:
    result.meth = "POST"
    var cs = newJArray()
    for p in stops: cs.add %*[p.lon, p.lat]
    var body = %*{"coordinates": cs, "instructions": true}
    if lang.len > 0: body["language"] = %lang
    if alternatives and stops.len == 2: body["alternative_routes"] = %*{"target_count": 2}
    result.body = $body
    result.headers.add ("Content-Type", "application/json")
    result.headers.add ("Authorization", s.key)
    result.url = s.baseOr("https://api.openrouteservice.org") & "/v2/directions/" &
                 s.profileOf("driving-car", "cycling-regular", "foot-walking", "driving-hgv")
  of gpGoogle:
    result.meth = "POST"
    proc wp(p: LatLon): JsonNode = %*{"location": {"latLng": {"latitude": p.lat, "longitude": p.lon}}}
    var body = %*{"origin": wp(stops[0]), "destination": wp(stops[^1]),
                  "travelMode": s.profileOf("DRIVE", "BICYCLE", "WALK", "DRIVE"),
                  "computeAlternativeRoutes": alternatives}
    if stops.len > 2:
      var mids = newJArray()
      for p in stops[1 ..< ^1]: mids.add wp(p)
      body["intermediates"] = mids
    if lang.len > 0: body["languageCode"] = %lang
    result.body = $body
    result.headers.add ("Content-Type", "application/json")
    result.headers.add ("X-Goog-Api-Key", s.key)
    result.headers.add ("X-Goog-FieldMask", "routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline," &
                        "routes.legs.steps.navigationInstruction,routes.legs.steps.distanceMeters," &
                        "routes.legs.steps.staticDuration,routes.legs.steps.startLocation")
    result.url = s.baseOr("https://routes.googleapis.com") & "/directions/v2:computeRoutes"
  of gpHere:
    var via = ""
    for p in stops[1 ..< ^1]: via.add "&via=" & ll(p)
    result.url = s.baseOr("https://router.hereapi.com") & "/v8/routes?transportMode=" &
                 s.profileOf("car", "bicycle", "pedestrian", "truck") & "&origin=" & ll(stops[0]) &
                 "&destination=" & ll(stops[^1]) & via & "&return=polyline,summary,actions,instructions&apiKey=" &
                 enc(s.key) & (if lang.len > 0: "&lang=" & enc(lang) else: "") &
                 (if alternatives: "&alternatives=2" else: "")
  of gpAzure, gpTomTom:
    var path: seq[string]
    for p in stops: path.add ll(p)
    let mode = s.profileOf("car", "bicycle", "pedestrian", "truck")
    if s.provider == gpAzure:
      result.url = s.baseOr("https://atlas.microsoft.com") & "/route/directions/json?api-version=1.0&query=" &
                   path.join(":") & "&travelMode=" & mode & "&instructionsType=text" &
                   (if lang.len > 0: "&language=" & enc(lang) else: "") &
                   (if alternatives: "&maxAlternatives=2" else: "")
      result.headers.add ("subscription-key", s.key)
    else:
      result.url = s.baseOr("https://api.tomtom.com") & "/routing/1/calculateRoute/" & path.join(":") &
                   "/json?travelMode=" & mode & "&instructionsType=text&key=" & enc(s.key) &
                   (if lang.len > 0: "&language=" & enc(lang) else: "") &
                   (if alternatives: "&maxAlternatives=2" else: "")
  of gpEsri:
    var feats = newJArray()
    for p in stops: feats.add %*{"geometry": {"x": p.lon, "y": p.lat}}
    result.url = s.baseOr("https://route-api.arcgis.com") &
                 "/arcgis/rest/services/World/Route/NAServer/Route_World/solve?f=json&returnDirections=true" &
                 "&directionsOutputType=esriDOTStandard&stops=" & enc($(%*{"features": feats})) & "&token=" & enc(s.key) &
                 (if lang.len > 0: "&directionsLanguage=" & enc(lang) else: "")
  else:
    result.url = ""

proc readRoute*(provider: GeoProvider; body: string): RouteAnswer =
  ## The route in what `provider` sent back.
  let j = try: parseJson(body) except CatchableError:
    return RouteAnswer(error: "the answer is not JSON")
  var routes: seq[Route]
  case provider
  of gpOsrm, gpMapbox:
    let code = j{"code"}.getStr("Ok")
    if code != "Ok": return RouteAnswer(error: code & ": " & j{"message"}.getStr)
    for r in j{"routes"}.getElems:
      var rt = Route(points: decodePolyline(r{"geometry"}.getStr, 6), distanceM: fnum(r{"distance"}),
                     durationS: int(round(fnum(r{"duration"}))))
      for leg in r{"legs"}.getElems:
        for st in leg{"steps"}.getElems:
          let m = st{"maneuver"}
          var text = m{"instruction"}.getStr
          if text.len == 0:
            # (OSRM gives the kind of turn and the road's name: said in words)
            let kind = m{"type"}.getStr
            let modifier = m{"modifier"}.getStr
            let road = st{"name"}.getStr
            text = case kind
              of "depart": "Start" & (if road.len > 0: " on " & road else: "")
              of "arrive": "Arrive"
              of "roundabout", "rotary": "At the roundabout, take exit " & $m{"exit"}.getInt(1)
              else:
                (if modifier.len > 0: "Turn " & modifier else: kind.capitalizeAscii) &
                  (if road.len > 0: " onto " & road else: "")
          let loc = m{"location"}
          rt.steps.add RouteStep(text: text, distanceM: fnum(st{"distance"}),
                                 durationS: int(round(fnum(st{"duration"}))),
                                 lon: (if loc != nil and loc.len >= 2: fnum(loc[0]) else: 0.0),
                                 lat: (if loc != nil and loc.len >= 2: fnum(loc[1]) else: 0.0))
      routes.add rt
  of gpValhalla:
    if j{"error"} != nil: return RouteAnswer(error: j["error"].getStr)
    var trips = @[j{"trip"}]
    for a in j{"alternates"}.getElems: trips.add a{"trip"}
    for t in trips:
      if t == nil: continue
      var rt = Route(distanceM: fnum(t{"summary"}{"length"}) * 1000, durationS: int(round(fnum(t{"summary"}{"time"}))))
      for leg in t{"legs"}.getElems:
        let pts = decodePolyline(leg{"shape"}.getStr, 6)
        for m in leg{"maneuvers"}.getElems:
          let at = m{"begin_shape_index"}.getInt
          rt.steps.add RouteStep(text: m{"instruction"}.getStr, distanceM: fnum(m{"length"}) * 1000,
                                 durationS: int(round(fnum(m{"time"}))),
                                 lat: (if at < pts.len: pts[at].lat else: 0.0),
                                 lon: (if at < pts.len: pts[at].lon else: 0.0))
        rt.points.add pts
      routes.add rt
  of gpGraphHopper:
    if j{"message"} != nil and j{"paths"} == nil: return RouteAnswer(error: j["message"].getStr)
    for p in j{"paths"}.getElems:
      let pts = decodePolyline(p{"points"}.getStr, 5)
      var rt = Route(points: pts, distanceM: fnum(p{"distance"}), durationS: int(round(fnum(p{"time"}) / 1000)))
      for ins in p{"instructions"}.getElems:
        let iv = ins{"interval"}
        let at = if iv != nil and iv.len > 0: iv[0].getInt else: 0
        rt.steps.add RouteStep(text: ins{"text"}.getStr, distanceM: fnum(ins{"distance"}),
                               durationS: int(round(fnum(ins{"time"}) / 1000)),
                               lat: (if at < pts.len: pts[at].lat else: 0.0),
                               lon: (if at < pts.len: pts[at].lon else: 0.0))
      routes.add rt
  of gpOpenRouteService:
    if j{"error"} != nil:
      return RouteAnswer(error: j["error"]{"message"}.getStr(j["error"].getStr("an error")))
    for r in j{"routes"}.getElems:
      let pts = decodePolyline(r{"geometry"}.getStr, 5)
      var rt = Route(points: pts, distanceM: fnum(r{"summary"}{"distance"}),
                     durationS: int(round(fnum(r{"summary"}{"duration"}))))
      for seg in r{"segments"}.getElems:
        for st in seg{"steps"}.getElems:
          let wp = st{"way_points"}
          let at = if wp != nil and wp.len > 0: wp[0].getInt else: 0
          rt.steps.add RouteStep(text: st{"instruction"}.getStr, distanceM: fnum(st{"distance"}),
                                 durationS: int(round(fnum(st{"duration"}))),
                                 lat: (if at < pts.len: pts[at].lat else: 0.0),
                                 lon: (if at < pts.len: pts[at].lon else: 0.0))
      routes.add rt
  of gpGoogle:
    if j{"error"} != nil: return RouteAnswer(error: j["error"]{"message"}.getStr("an error"))
    for r in j{"routes"}.getElems:
      let dur = r{"duration"}.getStr("0s")
      var rt = Route(points: decodePolyline(r{"polyline"}{"encodedPolyline"}.getStr, 5),
                     distanceM: fnum(r{"distanceMeters"}),
                     durationS: int(round(try: parseFloat(dur.strip(chars = {'s'})) except ValueError: 0.0)))
      for leg in r{"legs"}.getElems:
        for st in leg{"steps"}.getElems:
          let sd = st{"staticDuration"}.getStr("0s")
          let loc = st{"startLocation"}{"latLng"}
          rt.steps.add RouteStep(text: st{"navigationInstruction"}{"instructions"}.getStr,
                                 distanceM: fnum(st{"distanceMeters"}),
                                 durationS: int(round(try: parseFloat(sd.strip(chars = {'s'})) except ValueError: 0.0)),
                                 lat: fnum(loc{"latitude"}), lon: fnum(loc{"longitude"}))
      routes.add rt
  of gpHere:
    if j{"title"} != nil and j{"routes"} == nil: return RouteAnswer(error: j["title"].getStr)
    for r in j{"routes"}.getElems:
      var rt = Route()
      for sec in r{"sections"}.getElems:
        let pts = decodeFlexPolyline(sec{"polyline"}.getStr)
        rt.distanceM += fnum(sec{"summary"}{"length"})
        rt.durationS += int(round(fnum(sec{"summary"}{"duration"})))
        for a in sec{"actions"}.getElems:
          let at = a{"offset"}.getInt
          rt.steps.add RouteStep(text: a{"instruction"}.getStr(a{"action"}.getStr),
                                 distanceM: fnum(a{"length"}), durationS: int(round(fnum(a{"duration"}))),
                                 lat: (if at < pts.len: pts[at].lat else: 0.0),
                                 lon: (if at < pts.len: pts[at].lon else: 0.0))
        rt.points.add pts
      routes.add rt
  of gpAzure, gpTomTom:
    if j{"error"} != nil: return RouteAnswer(error: j["error"]{"description"}.getStr(j["error"]{"message"}.getStr("an error")))
    for r in j{"routes"}.getElems:
      var rt = Route(distanceM: fnum(r{"summary"}{"lengthInMeters"}),
                     durationS: int(round(fnum(r{"summary"}{"travelTimeInSeconds"}))))
      for leg in r{"legs"}.getElems:
        for p in leg{"points"}.getElems: rt.points.add (fnum(p{"latitude"}), fnum(p{"longitude"}))
      let ins = r{"guidance"}{"instructions"}
      var lastAt = 0.0
      for k, i in ins.getElems:
        let p = i{"point"}
        let off = fnum(i{"routeOffsetInMeters"})
        rt.steps.add RouteStep(text: i{"message"}.getStr, lat: fnum(p{"latitude"}), lon: fnum(p{"longitude"}))
        if k > 0: rt.steps[^2].distanceM = off - lastAt
        lastAt = off
      routes.add rt
  of gpEsri:
    if j{"error"} != nil: return RouteAnswer(error: j["error"]{"message"}.getStr("an error"))
    for f in j{"routes"}{"features"}.getElems:
      var rt = Route(distanceM: fnum(f{"attributes"}{"Total_Kilometers"}) * 1000,
                     durationS: int(round(fnum(f{"attributes"}{"Total_TravelTime"}) * 60)))
      for path in f{"geometry"}{"paths"}.getElems:
        for p in path.getElems:
          if p.len >= 2: rt.points.add (fnum(p[1]), fnum(p[0]))
      routes.add rt
    for d in j{"directions"}.getElems:
      for f in d{"features"}.getElems:
        if routes.len == 0: break
        let a = f{"attributes"}
        routes[0].steps.add RouteStep(text: a{"text"}.getStr, distanceM: fnum(a{"length"}) * 1000,
                                      durationS: int(round(fnum(a{"time"}) * 60)))
  else:
    return RouteAnswer(error: $provider & " does not make routes")
  if routes.len == 0: return RouteAnswer(error: "no route between these places")
  result.ok = true
  result.route = routes[0]
  if routes.len > 1: result.alternatives = routes[1 .. ^1]

proc route*(stops: openArray[LatLon]; s = GeoService(provider: gpOsrm); alternatives = false): RouteAnswer =
  ## A route through `stops` (two or more: from the first to the last),
  ## by car unless `s.profile` says otherwise. Waits for the answer.
  if stops.len < 2: return RouteAnswer(error: "a route needs two places")
  let q = routeRequest(s, stops, alternatives)
  let (ok, body) = ask(q.meth, q.url, q.body, q.headers)
  if not ok: return RouteAnswer(error: body)
  readRoute(s.provider, body)

# ---- asking in the background ------------------------------------------------------

type
  GeoAnswer* = object
    ## A finished `geocodeAsync`, `reverseAsync` or `routeAsync`.
    ticket*: int
    places*: PlacesAnswer
    route*: RouteAnswer

when compileOption("threads"):
  import std/[locks, typedthreads]
  type GeoJob = object
    ticket: int
    kind: int                   # 0 places, 1 reverse, 2 route
    service: GeoService
    query: string
    stops: seq[LatLon]
    alternatives: bool
  type GeoShared = object
    todo: seq[GeoJob]
    done: seq[GeoAnswer]
  # (never freed: a worker may still be at work as the program ends, after
  # Nim has destroyed the program's globals -- these are not among them)
  let geoSh = cast[ptr GeoShared](allocShared0(sizeof(GeoShared)))
  template geoTodo: untyped = geoSh.todo
  template geoDone: untyped = geoSh.done
  var
    geoLock: Lock
    geoReady: Cond
    geoThreads: seq[Thread[void]]
    geoStarted = false
  proc geoWorker() {.thread.} =
    {.cast(gcsafe).}:
      while true:
        var job: GeoJob
        acquire(geoLock)
        while geoTodo.len == 0: wait(geoReady, geoLock)
        job = move geoTodo[0]
        geoTodo.delete(0)
        release(geoLock)
        var a = GeoAnswer(ticket: job.ticket)
        case job.kind
        of 0: a.places = geocode(job.query, job.service)
        of 1: a.places = reverseGeocode(job.stops[0], job.service)
        else: a.route = route(job.stops, job.service, job.alternatives)
        acquire(geoLock)
        geoDone.add a
        release(geoLock)
  proc geoQueue(j: GeoJob) =
    if not geoStarted:
      geoStarted = true
      initLock(geoLock)
      initCond(geoReady)
      geoThreads.setLen(2)
      for t in geoThreads.mitems: createThread(t, geoWorker)
    acquire(geoLock)
    geoTodo.add j
    signal(geoReady)
    release(geoLock)
else:
  var geoDone: seq[GeoAnswer]

var
  geoTickets = 0
  geoOutstanding = 0             ## asked and not yet handed over

proc geocodeAsync*(query: string; s = GeoService()): int =
  ## `geocode` in the background: a ticket, its answer in `geoFinished`.
  inc geoTickets
  inc geoOutstanding
  result = geoTickets
  when compileOption("threads"):
    geoQueue(GeoJob(ticket: result, kind: 0, service: s, query: query))
  else:
    geoDone.add GeoAnswer(ticket: result, places: geocode(query, s))

proc reverseAsync*(p: LatLon; s = GeoService()): int =
  ## `reverseGeocode` in the background: a ticket, its answer in `geoFinished`.
  inc geoTickets
  inc geoOutstanding
  result = geoTickets
  when compileOption("threads"):
    geoQueue(GeoJob(ticket: result, kind: 1, service: s, stops: @[p]))
  else:
    geoDone.add GeoAnswer(ticket: result, places: reverseGeocode(p, s))

proc routeAsync*(stops: openArray[LatLon]; s = GeoService(provider: gpOsrm); alternatives = false): int =
  ## `route` in the background: a ticket, its answer in `geoFinished`.
  inc geoTickets
  inc geoOutstanding
  result = geoTickets
  when compileOption("threads"):
    geoQueue(GeoJob(ticket: result, kind: 2, service: s, stops: @stops, alternatives: alternatives))
  else:
    geoDone.add GeoAnswer(ticket: result, route: route(stops, s, alternatives))

proc geoFinished*(): seq[GeoAnswer] =
  ## The answers that came since the last call (call it every frame while
  ## one is awaited: `geoPending`).
  when compileOption("threads"):
    if not geoStarted: return
    acquire(geoLock)
    result = move geoDone
    geoDone = @[]
    release(geoLock)
  else:
    result = move geoDone
    geoDone = @[]
  geoOutstanding -= result.len

proc geoPending*(): bool =
  ## Answers are awaited (asked, and not yet taken by `geoFinished`).
  geoOutstanding > 0

## Maps of the world from tiles (`tilemap`), vector tiles (`mvt`), tile
## archives (`pmtiles`) and places and routes (`geo`): the encodings
## against the services' own examples, what each service sends back read,
## tiles written and read again, and the map widget headless -- tiles from
## a folder and from a PMTiles file shown where they belong, dragged,
## zoomed, clicked, with markers and shapes.

import std/[os, math, strutils, json, tables, monotimes, times]
import retroui/[core, gfx, imaging, codec, db]
import retroui/[tilemap, mvt, pmtiles, geo]
import retroui/uirelays/[coords, screen, input]

const W = 640
const H = 480
var
  queue: seq[Event]
  pixels = newSeq[uint32](W * H)
  ticks = 1000
  view: proc ()

proc fakeDriver() =
  windowRelays.createWindow = proc (l: var ScreenLayout; icon: pointer; iconLen: int) =
    l.width = W; l.height = H; l.scaleX = 1; l.scaleY = 1; l.uiScale = 100
  windowRelays.getWindowLayout = proc (): ScreenLayout =
    ScreenLayout(width: W, height: H, scaleX: 1, scaleY: 1, uiScale: 100)
  windowRelays.refresh = proc () = discard
  windowRelays.setWindowTitle = proc (t: string) = discard
  windowRelays.setCursor = proc (c: CursorKind) = discard
  drawRelays.blitRGBA = proc (p: ptr UncheckedArray[uint32]; w, h: int; dst: Rect;
                              f: RGBAFormat): bool =
    for y in 0 ..< h:
      for x in 0 ..< w: pixels[(dst.y + y) * W + dst.x + x] = p[y * w + x]
    true
  inputRelays.pollEvent = proc (e: var Event; fl: set[InputFlag]): bool =
    if queue.len == 0: return false
    e = queue[0]
    queue.delete(0)
    true
  inputRelays.waitEvent = proc (e: var Event; t: int; fl: set[InputFlag]): bool =
    inputRelays.pollEvent(e, fl)
  inputRelays.getTicks = proc (): int = ticks
  inputRelays.shutdown = proc () = discard
  clipboardRelays.getText = proc (): string = ""
  clipboardRelays.putText = proc (t: string) = discard
  fontRelays.openFont = proc (path: string; size: int; style: FontStyles;
                              metrics: var FontMetrics): Font = Font(0)
  fontRelays.closeFont = proc (f: Font) = discard
  fontRelays.getFontMetrics = proc (f: Font): FontMetrics = FontMetrics()
  fontRelays.measureText = proc (f: Font; text: string): TextExtent = TextExtent()
  fontRelays.drawText = proc (f: Font; x, y: int; text: string; fg, bg: Color): TextExtent =
    TextExtent()
  fontRelays.drawMeasuredText = nil

proc down(x, y: int; clicks = 1) =
  queue.add Event(kind: MouseMoveEvent, x: x, y: y)
  queue.add Event(kind: MouseDownEvent, x: x, y: y, button: LeftButton, clicks: clicks)
proc up(x, y: int) = queue.add Event(kind: MouseUpEvent, x: x, y: y, button: LeftButton)
proc move(x, y: int) = queue.add Event(kind: MouseMoveEvent, x: x, y: y)
proc px(x, y: int): uint32 = pixels[y * W + x] and 0xFFFFFF'u32
proc run(n = 1) =
  var i = 0
  var tail = 1
  while i < n or queue.len > 0 or tail > 0:
    if i >= n and queue.len == 0: dec tail
    discard beginFrame()
    view()
    endFrame()
    inc i
    ticks += 16

proc near(a, b: float; eps = 1e-6): bool = abs(a - b) <= eps

# ---- the encodings --------------------------------------------------------------------------

block polylines:
  # Google's own example
  let p = decodePolyline("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
  doAssert p.len == 3
  doAssert near(p[0].lat, 38.5) and near(p[0].lon, -120.2)
  doAssert near(p[1].lat, 40.7) and near(p[1].lon, -120.95)
  doAssert near(p[2].lat, 43.252) and near(p[2].lon, -126.453)
  doAssert encodePolyline(p) == "_p~iF~ps|U_ulLnnqC_mqNvxq`@"
  # precision 6 (OSRM, Valhalla) both ways
  let q = @[(23.588123, 58.382456), (23.614321, 58.593210), (-33.868820, 151.209296)]
  let back = decodePolyline(encodePolyline(q, 6), 6)
  for i in 0 .. 2: doAssert near(back[i].lat, q[i][0]) and near(back[i].lon, q[i][1])
  doAssert decodePolyline("").len == 0
  discard decodePolyline("\x01\x02garbage~~~~~~~~~~~~~~")     # (damaged: no crash)
  # HERE's flexible polyline, its documented example
  let f = decodeFlexPolyline("BFoz5xJ67i1B1B7PzIhaxL7Y")
  doAssert f.len == 4
  doAssert near(f[0].lat, 50.10228) and near(f[0].lon, 8.69821)
  doAssert near(f[3].lat, 50.09878) and near(f[3].lon, 8.68752)
  doAssert decodeFlexPolyline("!!!").len == 0

block distances:
  # Muscat to Seeb: about 21.7 km; a degree of the equator 111.2 km
  doAssert abs(distanceM((23.588, 58.382), (23.614, 58.593)) - 21693) < 50
  doAssert abs(distanceM((0.0, 0.0), (0.0, 1.0)) - 111195) < 5
  doAssert near(bearing((0.0, 0.0), (1.0, 0.0)), 0, 1e-9) and near(bearing((0.0, 0.0), (0.0, 1.0)), 90, 1e-9)
  let d = destination((23.588, 58.382), 45, 10_000)
  doAssert abs(distanceM((23.588, 58.382), d) - 10_000) < 0.5
  doAssert abs(bearing((23.588, 58.382), d) - 45) < 0.01
  doAssert distanceText(850) == "850 m" and distanceText(12_400) == "12.4 km" and distanceText(120_400) == "120 km"
  doAssert durationText(45) == "45 s" and durationText(720) == "12 min" and durationText(7500) == "2 h 5 min"
  doAssert abs(lengthM([(0.0, 0.0), (0.0, 1.0), (0.0, 2.0)]) - 2 * 111195) < 10

block china:
  # Beijing: moved by some hundreds of meters, and back within centimeters
  let wgs = (39.9042, 116.4074)
  let gcj = wgsToGcj(wgs)
  doAssert distanceM(wgs, gcj) > 200 and distanceM(wgs, gcj) < 900
  doAssert distanceM(gcjToWgs(gcj), wgs) < 0.05
  let bd = gcjToBd(gcj)
  doAssert distanceM(bdToGcj(bd), gcj) < 0.5
  # outside China nothing moves
  doAssert wgsToGcj((23.588, 58.382)) == (23.588, 58.382)
  doAssert gcjToWgs((48.85, 2.35)) == (48.85, 2.35)

block geojson:
  let text = """{"type":"FeatureCollection","features":[
    {"type":"Feature","geometry":{"type":"Point","coordinates":[58.38,23.58]},"properties":{"name":"Muscat"}},
    {"type":"Feature","geometry":{"type":"LineString","coordinates":[[58.38,23.58],[58.59,23.61]]},"properties":{"title":"road"}},
    {"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[0,0],[1,0],[1,1],[0,0]],[[0.2,0.2],[0.3,0.2],[0.3,0.3],[0.2,0.2]]]},"properties":{}},
    {"type":"Feature","geometry":{"type":"MultiPoint","coordinates":[[1,2],[3,4]]},"properties":null}]}"""
  let fs = readGeoJson(text)
  doAssert fs.len == 5
  doAssert fs[0].kind == gkPoint and fs[0].name == "Muscat" and near(fs[0].points[0].lat, 23.58)
  doAssert fs[1].kind == gkLine and fs[1].name == "road" and fs[1].points.len == 2
  doAssert fs[2].kind == gkPolygon and fs[2].holes.len == 1 and fs[2].points.len == 4
  doAssert fs[3].kind == gkPoint and near(fs[4].points[0].lon, 3)
  let again = readGeoJson(toGeoJson(fs))
  doAssert again.len == 5 and again[0].name == "Muscat" and again[2].holes.len == 1
  doAssert readGeoJson("not json").len == 0 and readGeoJson("{}").len == 0
  let (shapes, marks) = geoJsonShapes(text)
  doAssert marks.len == 3 and shapes.len == 2 and shapes[1].kind == msPolygon

# ---- what the services send back ------------------------------------------------------------

block places:
  var a = readPlaces(gpNominatim, """[{"lat":"23.5880","lon":"58.3829","display_name":"Muscat, Oman","type":"city","boundingbox":["23.4","23.7","58.2","58.6"]}]""")
  doAssert a.ok and a.places.len == 1 and a.places[0].name == "Muscat, Oman"
  doAssert near(a.places[0].lat, 23.588) and near(a.places[0].north, 23.7) and near(a.places[0].west, 58.2)
  a = readPlaces(gpNominatim, """{"lat":"23.6","lon":"58.5","display_name":"Seeb"}""")
  doAssert a.ok and a.places.len == 1 and a.places[0].name == "Seeb", "reverse: one object"
  a = readPlaces(gpGoogle, """{"status":"OK","results":[{"formatted_address":"Muscat, Oman","types":["locality"],
    "geometry":{"location":{"lat":23.58,"lng":58.38},"viewport":{"southwest":{"lat":23.4,"lng":58.2},"northeast":{"lat":23.7,"lng":58.6}}},
    "address_components":[{"short_name":"OM","types":["country","political"]}]}]}""")
  doAssert a.ok and a.places[0].kind == "locality" and a.places[0].country == "OM" and near(a.places[0].east, 58.6)
  a = readPlaces(gpGoogle, """{"status":"REQUEST_DENIED","error_message":"The provided API key is invalid."}""")
  doAssert not a.ok and "invalid" in a.error
  a = readPlaces(gpMapbox, """{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[58.38,23.58]},
    "properties":{"full_address":"Muscat, Oman","feature_type":"place","coordinates":{"latitude":23.58,"longitude":58.38},
    "context":{"country":{"country_code":"OM"}}}}]}""")
  doAssert a.ok and a.places[0].name == "Muscat, Oman" and a.places[0].country == "OM" and a.places[0].kind == "place"
  a = readPlaces(gpHere, """{"items":[{"title":"Muscat, Oman","resultType":"locality","position":{"lat":23.58,"lng":58.38},
    "address":{"countryCode":"OMN","label":"Muscat"},"mapView":{"west":58.2,"south":23.4,"east":58.6,"north":23.7}}]}""")
  doAssert a.ok and a.places[0].name == "Muscat, Oman" and a.places[0].country == "OMN" and near(a.places[0].south, 23.4)
  a = readPlaces(gpAzure, """{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[58.38,23.58]},
    "properties":{"type":"PopulatedPlace","address":{"formattedAddress":"Muscat, Oman","countryRegion":{"ISO":"OM"}}}}]}""")
  doAssert a.ok and a.places[0].name == "Muscat, Oman" and a.places[0].country == "OM" and near(a.places[0].lon, 58.38)
  a = readPlaces(gpTomTom, """{"results":[{"type":"Geography","position":{"lat":23.58,"lon":58.38},
    "address":{"freeformAddress":"Muscat","countryCode":"OM"},"viewport":{"topLeftPoint":{"lat":23.7,"lon":58.2},"btmRightPoint":{"lat":23.4,"lon":58.6}}}]}""")
  doAssert a.ok and a.places[0].name == "Muscat" and near(a.places[0].north, 23.7) and near(a.places[0].east, 58.6)
  a = readPlaces(gpTomTom, """{"addresses":[{"address":{"freeformAddress":"Al Khuwair","countryCode":"OM"},"position":"23.6,58.4"}]}""")
  doAssert a.ok and a.places[0].name == "Al Khuwair" and near(a.places[0].lat, 23.6)
  a = readPlaces(gpMapTiler, """{"type":"FeatureCollection","features":[{"type":"Feature","place_name":"Muscat, Oman","place_type":["municipality"],
    "geometry":{"type":"Point","coordinates":[58.38,23.58]},"properties":{}}]}""")
  doAssert a.ok and a.places[0].name == "Muscat, Oman" and a.places[0].kind == "municipality"
  a = readPlaces(gpEsri, """{"candidates":[{"address":"Muscat, OMN","location":{"x":58.38,"y":23.58},"attributes":{"Addr_type":"Locality"},
    "extent":{"xmin":58.2,"ymin":23.4,"xmax":58.6,"ymax":23.7}}]}""")
  doAssert a.ok and a.places[0].kind == "Locality" and near(a.places[0].lat, 23.58) and near(a.places[0].north, 23.7)
  a = readPlaces(gpPhoton, """{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[58.38,23.58]},
    "properties":{"name":"Muscat","country":"Oman","osm_value":"city"}}]}""")
  doAssert a.ok and a.places[0].name == "Muscat, Oman" and a.places[0].kind == "city"
  doAssert not readPlaces(gpNominatim, "<html>").ok
  doAssert not readPlaces(gpOsrm, "[]").ok, "a router does not find places"

block routes:
  let line6 = encodePolyline([(23.588, 58.382), (23.600, 58.450), (23.614, 58.593)], 6)
  let line5 = encodePolyline([(23.588, 58.382), (23.614, 58.593)], 5)
  var a = readRoute(gpOsrm, $(%*{"code": "Ok", "routes": [{"geometry": line6, "distance": 23456.7, "duration": 1500.4,
    "legs": [{"steps": [{"maneuver": {"type": "depart", "location": [58.382, 23.588]}, "name": "Sultan Qaboos St", "distance": 1000, "duration": 60},
                        {"maneuver": {"type": "turn", "modifier": "left", "location": [58.45, 23.6]}, "name": "Airport Rd", "distance": 22456, "duration": 1440},
                        {"maneuver": {"type": "arrive", "location": [58.593, 23.614]}, "name": "", "distance": 0, "duration": 0}]}]}]}))
  doAssert a.ok and a.route.points.len == 3 and near(a.route.points[2].lon, 58.593)
  doAssert near(a.route.distanceM, 23456.7) and a.route.durationS == 1500
  doAssert a.route.steps.len == 3 and a.route.steps[0].text == "Start on Sultan Qaboos St"
  doAssert a.route.steps[1].text == "Turn left onto Airport Rd" and a.route.steps[2].text == "Arrive"
  doAssert near(a.route.steps[1].lat, 23.6)
  doAssert not readRoute(gpOsrm, """{"code":"NoRoute","message":"Impossible route"}""").ok
  a = readRoute(gpValhalla, $(%*{"trip": {"summary": {"length": 23.4, "time": 1500},
    "legs": [{"shape": line6, "maneuvers": [{"instruction": "Drive east.", "length": 1.0, "time": 60, "begin_shape_index": 0},
                                            {"instruction": "Turn left.", "length": 22.4, "time": 1440, "begin_shape_index": 1}]}]}}))
  doAssert a.ok and near(a.route.distanceM, 23400) and a.route.steps[1].text == "Turn left." and near(a.route.steps[1].lon, 58.45)
  a = readRoute(gpGraphHopper, $(%*{"paths": [{"points": line5, "distance": 23456, "time": 1500000,
    "instructions": [{"text": "Continue", "distance": 23456, "time": 1500000, "interval": [0, 1]}]}]}))
  doAssert a.ok and a.route.durationS == 1500 and a.route.points.len == 2 and a.route.steps[0].text == "Continue"
  a = readRoute(gpOpenRouteService, $(%*{"routes": [{"geometry": line5, "summary": {"distance": 23456, "duration": 1500},
    "segments": [{"steps": [{"instruction": "Head east", "distance": 23456, "duration": 1500, "way_points": [0, 1]}]}]}]}))
  doAssert a.ok and a.route.steps[0].text == "Head east" and near(a.route.points[1].lat, 23.614)
  a = readRoute(gpGoogle, $(%*{"routes": [{"distanceMeters": 23456, "duration": "1500s", "polyline": {"encodedPolyline": line5},
    "legs": [{"steps": [{"navigationInstruction": {"instructions": "Head east on Route 1"}, "distanceMeters": 23456,
                         "staticDuration": "1500s", "startLocation": {"latLng": {"latitude": 23.588, "longitude": 58.382}}}]}]},
    {"distanceMeters": 25000, "duration": "1600s", "polyline": {"encodedPolyline": line5}}]}))
  doAssert a.ok and a.route.durationS == 1500 and a.alternatives.len == 1 and a.alternatives[0].durationS == 1600
  doAssert a.route.steps[0].text == "Head east on Route 1" and near(a.route.steps[0].lat, 23.588)
  a = readRoute(gpHere, $(%*{"routes": [{"sections": [{"polyline": "BFoz5xJ67i1B1B7PzIhaxL7Y",
    "summary": {"length": 500, "duration": 60}, "actions": [{"action": "depart", "instruction": "Head west.", "offset": 0, "length": 200, "duration": 20}]}]}]}))
  doAssert a.ok and a.route.points.len == 4 and near(a.route.distanceM, 500) and a.route.steps[0].text == "Head west."
  for p in [gpAzure, gpTomTom]:
    a = readRoute(p, $(%*{"routes": [{"summary": {"lengthInMeters": 23456, "travelTimeInSeconds": 1500},
      "legs": [{"points": [{"latitude": 23.588, "longitude": 58.382}, {"latitude": 23.614, "longitude": 58.593}]}],
      "guidance": {"instructions": [{"message": "Leave from Muscat", "routeOffsetInMeters": 0, "point": {"latitude": 23.588, "longitude": 58.382}},
                                     {"message": "You have arrived", "routeOffsetInMeters": 23456, "point": {"latitude": 23.614, "longitude": 58.593}}]}}]}))
    doAssert a.ok and a.route.points.len == 2 and a.route.steps.len == 2 and near(a.route.steps[0].distanceM, 23456), $p
  a = readRoute(gpEsri, $(%*{"routes": {"features": [{"attributes": {"Total_Kilometers": 23.4, "Total_TravelTime": 25},
    "geometry": {"paths": [[[58.382, 23.588], [58.593, 23.614]]]}}]},
    "directions": [{"features": [{"attributes": {"text": "Start at Muscat", "length": 23.4, "time": 25}}]}]}))
  doAssert a.ok and a.route.durationS == 1500 and a.route.steps[0].text == "Start at Muscat" and near(a.route.points[1].lon, 58.593)
  doAssert not readRoute(gpNominatim, "{}").ok

block requests:
  let s = service(gpGoogle, "KEY123", language = "ar")
  let g = geocodeRequest(s, "Royal Opera House, Muscat")
  doAssert g.url.startsWith("https://maps.googleapis.com/maps/api/geocode/json?address=Royal%20Opera%20House%2C%20Muscat")
  doAssert "key=KEY123" in g.url and "language=ar" in g.url
  let az = geocodeRequest(service(gpAzure, "AZ"), "Muscat")
  doAssert ("subscription-key", "AZ") in az.headers and "AZ" notin az.url, "Azure's key in a header"
  let own = geocodeRequest(GeoService(provider: gpNominatim, base: "https://geo.example.com/", agent: "MyApp/1.0 (me@example.com)"), "x")
  doAssert own.url.startsWith("https://geo.example.com/search?") and ("User-Agent", "MyApp/1.0 (me@example.com)") in own.headers
  let r = routeRequest(GeoService(provider: gpOsrm), [(23.588, 58.382), (23.614, 58.593)])
  doAssert r.url == "https://router.project-osrm.org/route/v1/driving/58.382000,23.588000;58.593000,23.614000?overview=full&geometries=polyline6&steps=true&alternatives=false", r.url
  let gr = routeRequest(GeoService(provider: gpGoogle, key: "K", profile: "foot"), [(1.0, 2.0), (3.0, 4.0), (5.0, 6.0)])
  doAssert gr.meth == "POST" and parseJson(gr.body)["travelMode"].getStr == "WALK"
  doAssert parseJson(gr.body)["intermediates"].len == 1 and ("X-Goog-Api-Key", "K") in gr.headers
  let vr = routeRequest(GeoService(provider: gpValhalla, profile: "bike"), [(1.0, 2.0), (3.0, 4.0)])
  doAssert parseJson(vr.body)["costing"].getStr == "bicycle"
  doAssert route([(1.0, 2.0)]).error.len > 0, "a route needs two places"

# ---- vector tiles --------------------------------------------------------------------------

proc gzipOf(s: string): string =
  let b = toBytes(s)
  let d = deflate(b)
  result = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff"
  for c in d: result.add char(c)
  let crc = crc32(b)
  for k in 0 .. 3: result.add char((crc shr (8 * k)) and 255)
  for k in 0 .. 3: result.add char((uint32(s.len) shr (8 * k)) and 255)

proc sampleTile(): string =
  var w: MvtWriter
  w.addFeature("water", mgPolygon, [@[(0, 0), (4096, 0), (4096, 2048), (0, 2048), (0, 0)]])
  w.addFeature("landuse", mgPolygon, [@[(0, 3072), (1024, 3072), (1024, 4096), (0, 4096), (0, 3072)]],
               {"class": "park"})
  w.addFeature("transportation", mgLine, [@[(0, 2600), (4096, 2600)]], {"class": "motorway"})
  w.addFeature("place", mgPoint, [@[(3000, 3500)]], {"class": "city", "name": "Muscat"})
  w.addFeature("transportation_name", mgLine, [@[(0, 2600), (4096, 2600)]], {"name": "Highway 1"})
  w.toMvt()

block vectorTiles:
  let data = sampleTile()
  for bytes in [data, gzipOf(data)]:
    let t = decodeMvt(bytes)
    doAssert t.layerNames == @["water", "landuse", "transportation", "place", "transportation_name"]
    doAssert t[0].extent == 4096 and t[0].features[0].kind == mgPolygon
    doAssert t[0].features[0].parts[0].len == 5, "the ring closed: " & $t[0].features[0].parts[0]
    doAssert t[2].prop(t[2].features[0], "class") == "motorway"
    doAssert t[3].prop(t[3].features[0], "name") == "Muscat" and t[3].prop(t[3].features[0], "none") == ""
  var labels: seq[TileLabel]
  let b = renderMvt(decodeMvt(data), 15, 512, classicStyle(), addr labels)
  let st = classicStyle()
  proc packed(c: Color): uint32 = (uint32(c.r) shl 16) or (uint32(c.g) shl 8) or uint32(c.b)
  doAssert (b.px[100 * 512 + 100] and 0xFFFFFF) == 0xA0C8F0, "water"
  doAssert (b.px[480 * 512 + 50] and 0xFFFFFF) == 0xC8E0B0, "a park"
  doAssert (b.px[400 * 512 + 400] and 0xFFFFFF) == packed(st.background), "land"
  doAssert (b.px[325 * 512 + 256] and 0xFFFFFF) == 0xE892A2, "the motorway"
  var names: seq[string]
  for l in labels: names.add l.text
  doAssert "Muscat" in names and "Highway 1" in names, $names
  doAssert renderMvt(decodeMvt(data), 15, 256, darkStyle()).px[10 * 256 + 10] != b.px[0]
  # damaged tiles: refused, never a crash
  var refused = 0
  for cut in [1, 5, 17, 40, data.len - 3]:
    try: discard decodeMvt(data[0 ..< cut])
    except MvtError: inc refused
  doAssert refused >= 3
  doAssert decodeMvt("").len == 0

# ---- tile archives -------------------------------------------------------------------------

let tmp = getTempDir() / "retro_tilemap_test"
removeDir(tmp)
createDir(tmp)

proc colorTile(c: uint32): string =
  let b = newBitmap(256, 256)
  for p in b.px.mitems: p = 0xFF000000'u32 or c
  encodePng(b)

block pmtilesFiles:
  doAssert tileId(0, 0, 0) == 0
  doAssert tileId(1, 0, 0) == 1 and tileId(1, 0, 1) == 2 and tileId(1, 1, 1) == 3 and tileId(1, 1, 0) == 4
  doAssert tileId(2, 0, 0) == 5
  # every tile of a zoom has a number of its own, the zoom's numbers in a row
  for z in 2 .. 5:
    let n = 1 shl z
    var seen = newSeq[bool](n * n)
    let first = tileId(z, 0, 0) - (if z > 0: 0'u64 else: 0'u64)
    var lo = high(uint64)
    for x in 0 ..< n:
      for y in 0 ..< n: lo = min(lo, tileId(z, x, y))
    for x in 0 ..< n:
      for y in 0 ..< n:
        let i = int(tileId(z, x, y) - lo)
        doAssert i >= 0 and i < n * n and not seen[i]
        seen[i] = true
    doAssert lo == (pow(4.0, float(z)).uint64 - 1) div 3 and first >= lo
  let path = tmp / "colors.pmtiles"
  var ts: seq[(int, int, int, string)]
  for z in 0 .. 3:
    let n = 1 shl z
    for x in 0 ..< n:
      for y in 0 ..< n: ts.add (z, x, y, colorTile(uint32(z * 0x400000 + x * 0x2000 + y * 0x10)))
  doAssert writePmtiles(path, ts, ptPng, """{"attribution":"test tiles"}""")
  let pm = openPmtiles(path)
  doAssert pm.ok, pm.error
  doAssert pm.minZoom == 0 and pm.maxZoom == 3 and pm.tileType == ptPng
  doAssert pm.metadata()["attribution"].getStr == "test tiles"
  for (z, x, y, d) in ts: doAssert pm.tile(z, x, y) == d, $z & "/" & $x & "/" & $y
  doAssert pm.tile(4, 0, 0) == "" and pm.tile(3, 9, 9) == ""
  pm.close()
  doAssert not openPmtiles(tmp / "nothing.pmtiles").ok
  writeFile(tmp / "bad.pmtiles", "PMTiles\x02" & repeat('\0', 200))
  doAssert "version" in openPmtiles(tmp / "bad.pmtiles").error
  # vector tiles in it, packed with gzip
  let vpath = tmp / "vector.pmtiles"
  doAssert writePmtiles(vpath, [(0, 0, 0, gzipOf(sampleTile()))], ptMvt, gzipTiles = true)
  let vp = openPmtiles(vpath)
  doAssert vp.ok and vp.tileType == ptMvt and vp.tile(0, 0, 0) == sampleTile()

block mbtilesFiles:
  let path = tmp / "colors.mbtiles"
  let d = openDb(path)
  d.execScript """
    CREATE TABLE metadata (name TEXT, value TEXT);
    CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB);"""
  d.exec("INSERT INTO metadata VALUES ('format', 'png'), ('minzoom', '0'), ('maxzoom', '2'), ('attribution', 'mb test')")
  for z in 0 .. 2:
    let n = 1 shl z
    for x in 0 ..< n:
      for y in 0 ..< n:
        d.exec("INSERT INTO tiles VALUES (?, ?, ?, ?)", z, x, n - 1 - y, blob(colorTile(uint32(x * 0x100 + y))))
  d.close()
  let mb = openMbtiles(path)
  doAssert mb.ok and mb.format == "png" and mb.meta["attribution"] == "mb test"
  doAssert mb.tile(2, 1, 3) == colorTile(uint32(1 * 0x100 + 3)), "rows turned from the south"
  doAssert mb.tile(5, 0, 0) == ""
  mb.close()
  let src = mbtilesSource(path)
  doAssert src.maxZoom == 2 and src.attribution == "mb test" and src.format == tfRaster

block addresses:
  var s = TileSource(url: "https://{s}.t.example/{z}/{x}/{y}{r}.png?q={q}&ty={-y}", subdomains: @["a", "b"], hiDpi: true)
  doAssert s.tileUrl(3, 3, 5) == "https://a.t.example/3/3/5.png?q=213&ty=2"
  doAssert s.tileUrl(3, 4, 5, dense = true) == "https://b.t.example/3/4/5@2x.png?q=" & quadkey(3, 4, 5) & "&ty=2"
  doAssert quadkey(3, 3, 5) == "213" and quadkey(0, 0, 0) == ""
  doAssert osmTiles().url == "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
  doAssert "tilesetId=microsoft.base.road" in azureTiles("K").url and ("subscription-key", "K") in azureTiles("K").headers
  doAssert googleTiles("G", "satellite").googleMapType == "satellite"
  doAssert amapTiles().gcj02 and tencentTiles().gcj02 and not osmTiles().gcj02
  doAssert mapTilerVector("K").format == tfVector and "/tiles/v3/" in mapTilerVector("K").url
  doAssert "explore.day" in hereTiles("K").url and "/map/1/tile/basic/main/" in tomTomTiles("K").url
  doAssert "World_Imagery/MapServer/tile/{z}/{y}/{x}" in esriTiles("World_Imagery").url
  doAssert "tk=T" in tiandituTiles("T").url
  doAssert "mapkit.init" in mapKitPage("TOKEN", 23.5, 58.4) and "TOKEN" in mapKitPage("TOKEN", 23.5, 58.4)
  doAssert "maps.googleapis.com/maps/api/js?key=K" in googleMapsPage("K", 1, 2)
  doAssert tilesIn(23.0, 58.0, 24.0, 59.0, 0, 0) == 1
  doAssert tilesIn(-85, -180, 85, 179.99, 2, 2) == 16
  doAssert "usage policy" in keepArea(osmTiles(), 23, 58, 24, 59, 10, 12)

# ---- the widget ------------------------------------------------------------------------------

fakeDriver()
startApp("maps", W, H)

proc waitTiles(maxMs = 8000) =
  ## (the tiles come from worker threads: frames until they are all there)
  let t0 = getMonoTime()
  run(2)
  while loadingTiles() > 0 and (getMonoTime() - t0).inMilliseconds < maxMs:
    os.sleep(10)
    run()
  run(2)

# tiles of a folder: each one colored by its zoom, column and row
let dir = tmp / "folder"
for z in 0 .. 6:
  let n = 1 shl z
  for x in 0 ..< n:
    for y in 0 ..< n:
      createDir(dir / $z / $x)
      writeFile(dir / $z / $x / ($y & ".png"), colorTile(uint32(((z * 37) and 255) shl 16 or ((x * 5) and 255) shl 8 or ((y * 5) and 255))))
proc tileColor(z, x, y: int): uint32 = uint32(((z * 37) and 255) shl 16 or ((x * 5) and 255) shl 8 or ((y * 5) and 255))

block folderMap:
  let src = folderSource(dir, maxZoom = 6, attribution = "test")
  var st = TileMapState(lat: 0, lon: 0, zoom: 3)
  var ev, clickEv: TileMapEvent
  var marks = @[MapMarker(lat: 23.588, lon: 58.382, label: "Muscat")]
  var shapes = @[MapShape(kind: msPolygon, points: @[(10.0, -10.0), (10.0, 10.0), (-10.0, 10.0), (-10.0, -10.0)],
                          fill: color(255, 0, 255, 255), label: "the square")]
  view = proc () =
    ev = tileMap(st, src, height = 400, markers = marks, shapes = shapes, showScale = false, showZoom = false)
    if ev.clicked: clickEv = ev
  waitTiles()
  let mr = ui.lastRect
  doAssert mr.w > 560 and mr.h == 400, $mr
  # at zoom 3 the middle of the map is the corner of four tiles: (3, 3, 3) up left, (3, 4, 4) down right
  let cxm = mr.x + mr.w div 2
  let cym = mr.y + mr.h div 2
  doAssert px(cxm - 120, cym - 120) == tileColor(3, 3, 3), toHex(px(cxm - 120, cym - 120))
  doAssert px(cxm + 120, cym + 120) == tileColor(3, 4, 4), toHex(px(cxm + 120, cym + 120))
  # the square over the middle, filled
  doAssert px(cxm + 3, cym + 3) == 0xFF00FF'u32, toHex(px(cxm + 3, cym + 3))
  # the attribution in the corner
  doAssert px(W - 3, H - 3) != tileColor(3, 4, 4)
  # drag a tile's width to the left: the view moves east by 45 degrees
  down(cxm, cym)
  run()
  for k in 1 .. 8:
    move(cxm - k * 32, cym)
    run()
  up(cxm - 256, cym)
  run()
  doAssert abs(st.lon - 45) < 0.5, $st.lon
  doAssert not clickEv.clicked, "a drag is not a click"
  waitTiles()
  doAssert px(cxm - 120, cym - 120) == tileColor(3, 4, 3), toHex(px(cxm - 120, cym - 120))
  # the wheel: half a zoom a notch, the point under the mouse stays
  st.centerOn(0, 0, 3)
  run()
  move(cxm + 100, cym)
  run()
  let lonBefore = ev.lon
  queue.add Event(kind: MouseWheelEvent, y: 2)
  run()
  doAssert near(st.zoom, 4, 1e-9), $st.zoom
  doAssert abs(ev.lon - lonBefore) < 0.05, $ev.lon & " " & $lonBefore
  waitTiles()
  # a click names where
  st.centerOn(0, 0, 3)
  run()
  down(cxm + 128, cym)
  run()
  up(cxm + 128, cym)
  run()
  doAssert clickEv.clicked and abs(clickEv.lon - 22.5) < 0.5 and abs(clickEv.lat) < 0.5, $clickEv.lon & " " & $clickEv.lat
  # the marker under the mouse
  st.centerOn(23.588, 58.382, 6)
  waitTiles()
  move(cxm, cym)
  run()
  doAssert ev.marker == 0, "the marker under the mouse"
  # past the folder's last zoom: its tiles larger (zoom 8 shows the zoom 6 ones)
  st.centerOn(30.5, 30.5, 8)
  waitTiles()
  block:
    # (where that point is in the tiles of zoom 6)
    let wx = (30.5 + 180) / 360 * 64 + 40 / 1024
    let la = 30.5 * PI / 180
    let wy = (1 - ln(tan(la) + 1 / cos(la)) / PI) / 2 * 64 - 40 / 1024
    doAssert px(cxm + 40, cym - 40) == tileColor(6, int(wx), int(wy)), toHex(px(cxm + 40, cym - 40))
  # fitting the view
  st.fitPoints([(10.0, 10.0), (20.0, 30.0)])
  run()
  doAssert st.lon > 19 and st.lon < 21 and st.lat > 14 and st.lat < 16 and st.zoom > 3, $st

block vectorMap:
  # a PMTiles file of vector tiles: water above, land below
  var ts: seq[(int, int, int, string)]
  for z in 0 .. 2:
    let n = 1 shl z
    for x in 0 ..< n:
      for y in 0 ..< n: ts.add (z, x, y, gzipOf(sampleTile()))
  let vpath = tmp / "world.pmtiles"
  doAssert writePmtiles(vpath, ts, ptMvt, gzipTiles = true)
  let src = pmtilesSource(vpath)
  doAssert src.format == tfVector and src.maxZoom == 2
  var st = TileMapState(lat: 0, lon: 0, zoom: 1)
  view = proc () =
    discard tileMap(st, src, height = 400, showScale = false, showZoom = false)
  waitTiles()
  # at zoom 1 (512-pixel tiles at zoom 0): the upper half of each tile is water
  let mr = ui.lastRect
  doAssert px(mr.x + mr.w div 2 - 60, mr.y + mr.h div 2 - 150) == 0xA0C8F0, toHex(px(mr.x + mr.w div 2 - 60, mr.y + mr.h div 2 - 150))
  doAssert px(mr.x + mr.w div 2 - 60, mr.y + mr.h div 2 + 40) != 0xA0C8F0

removeDir(tmp)
echo "tilemap: ok"

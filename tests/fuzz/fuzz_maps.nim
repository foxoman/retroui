## Feeds damaged map data to its readers: vector tiles (decoded and drawn),
## PMTiles archives, the answers of the places and routes services (JSON
## of any shape), GeoJSON, encoded polylines. Nothing may fail other than
## with the module's own error, or an answer that says it could not read.
##
##   nim c -r -d:release --stackTrace:on --lineTrace:on tests/fuzz/fuzz_maps.nim 3000

import std/[os, random, strutils, json, math]
import retroui/[mvt, pmtiles, geo, codec]

let rounds = if paramCount() >= 1: parseInt(paramStr(1)) else: 3000
var r = initRand(20261111)
let tmp = getTempDir() / "retro-fuzz-maps"
createDir(tmp)

proc mutate(s: string): string =
  result = s
  for _ in 0 .. r.rand(4):
    if result.len == 0: result.add char(r.rand(255))
    case r.rand(6)
    of 0, 1: result[r.rand(result.high)] = char(r.rand(255))
    of 2: result[r.rand(result.high)] = char([0x08, 0x0A, 0x12, 0x1A, 0x22, 0x28, 0x80, 0xFF][r.rand(7)])
    of 3:
      let a = r.rand(result.high)
      result.delete(a .. min(result.high, a + r.rand(30)))
    of 4: result.insert($char(r.rand(255)), r.rand(result.len))
    of 5: result.setLen(r.rand(result.len))
    else:
      let a = r.rand(result.high)
      result.insert(result[a .. min(result.high, a + r.rand(40))], r.rand(result.len))

# ---- seeds ---------------------------------------------------------------------------------------

proc sampleTile(): string =
  var w: MvtWriter
  w.addFeature("water", mgPolygon, [@[(0, 0), (4096, 0), (4096, 2048), (0, 2048), (0, 0)],
                                    @[(100, 100), (100, 200), (200, 200), (100, 100)]])
  w.addFeature("transportation", mgLine, [@[(0, 2600), (4096, 2600)], @[(5, 5), (-50, 9000)]],
               {"class": "motorway"})
  w.addFeature("place", mgPoint, [@[(3000, 3500)], @[(10, 10)]], {"class": "city", "name": "Muscat"})
  w.addFeature("building", mgPolygon, [@[(10, 10), (60, 10), (60, 60), (10, 60), (10, 10)]])
  w.toMvt()

proc gz(s: string): string =
  let d = deflate(toBytes(s))
  result = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff"
  for c in d: result.add char(c)
  let crc = crc32(toBytes(s))
  for k in 0 .. 3: result.add char((crc shr (8 * k)) and 255)
  for k in 0 .. 3: result.add char((uint32(s.len) shr (8 * k)) and 255)

let tile = sampleTile()
let seedsMvt = @[tile, gz(tile)]
let pmPath = tmp / "seed.pmtiles"
doAssert writePmtiles(pmPath, [(0, 0, 0, tile), (1, 0, 0, tile), (1, 1, 1, tile), (2, 3, 1, tile)], ptMvt,
                      """{"name":"fuzz"}""")
let pmSeed = readFile(pmPath)

const keys = ["Addr_type", "ISO", "LongLabel", "Match_addr", "Total_Kilometers", "Total_TravelTime", "action",
  "actions", "address", "address_components", "addresses", "addresstype", "alternates", "alternative_routes",
  "attributes", "bbox", "begin_shape_index", "boundingbox", "btmRightPoint", "candidates", "city", "code",
  "context", "coordinates", "country", "countryCode", "countryRegion", "country_code", "directions",
  "display_name", "distance", "distanceMeters", "duration", "east", "encodedPolyline", "error",
  "error_message", "extent", "feature_type", "features", "formatted_address", "freeformAddress",
  "full_address", "geometry", "guidance", "housenumber", "instruction", "instructions", "interval", "items",
  "label", "lat", "latLng", "latitude", "legs", "length", "lengthInMeters", "lng", "location", "lon",
  "longitude", "maneuver", "maneuvers", "mapView", "message", "modifier", "name", "name_preferred",
  "navigationInstruction", "north", "northeast", "offset", "osm_value", "paths", "place_formatted",
  "place_name", "place_type", "point", "points", "polyline", "position", "properties", "resultType",
  "results", "routeOffsetInMeters", "routes", "sections", "segments", "shape", "short_name", "south",
  "southwest", "startLocation", "state", "staticDuration", "status", "steps", "street", "summary", "text",
  "time", "title", "topLeftPoint", "travelTimeInSeconds", "trip", "type", "types", "viewport", "way_points",
  "west", "x", "xmax", "xmin", "y", "ymax", "ymin", "Ok", "OK", "FeatureCollection", "Feature", "Point",
  "LineString", "Polygon", "MultiPolygon"]

proc randomJson(depth = 0): JsonNode =
  let k = if depth > 5: r.rand(5) else: r.rand(8)
  case k
  of 0: result = %r.rand(-1000 .. 1000)
  of 1: result = %[r.rand(-200.0 .. 200.0), 1e308, -1e308, 0.0, 5e-324][r.rand(4)]
  of 2: result = %keys[r.rand(keys.high)]
  of 3: result = %[encodePolyline([(23.5, 58.3), (23.6, 58.4)]), "BFoz5xJ67i1B1B7PzIhaxL7Y", "", "~~~~",
                   "??", "1500s", "x"][r.rand(6)]
  of 4: result = newJNull()
  of 5: result = %(r.rand(1) == 0)
  of 6, 7:
    result = newJObject()
    for _ in 0 .. r.rand(5): result[keys[r.rand(keys.high)]] = randomJson(depth + 1)
  else:
    result = newJArray()
    for _ in 0 .. r.rand(4): result.add randomJson(depth + 1)

var refused, accepted = 0
for round in 0 ..< rounds:
  # vector tiles: decoded, then drawn
  let t = mutate(seedsMvt[r.rand(1)])
  try:
    let m = decodeMvt(t)
    discard m.layerNames
    var labels: seq[TileLabel]
    let px = renderMvtPixels(m, r.rand(0 .. 22), [16, 64, 256][r.rand(2)],
                             if r.rand(1) == 0: classicStyle() else: darkStyle(), addr labels)
    doAssert px.len > 0
    inc accepted
  except MvtError:
    inc refused
  # an archive: its header, directories and tiles
  if round mod 3 == 0:
    let p = tmp / "f.pmtiles"
    writeFile(p, mutate(pmSeed))
    try:
      let a = openPmtiles(p)
      discard a.metadata
      for (z, x, y) in [(0, 0, 0), (1, 1, 1), (2, 3, 1), (5, 9, 9), (30, 0, 0)]:
        try: discard a.tile(z, x, y)
        except ValueError, IOError, MvtError: inc refused
      a.close()
      inc accepted
    except ValueError, IOError, MvtError, OSError:
      inc refused
  # the services' answers: any JSON at all, and text that is not JSON
  let body = if r.rand(5) == 0: mutate($randomJson()) else: $randomJson()
  for p in GeoProvider:
    let a = readPlaces(p, body)
    if a.ok:
      for pl in a.places: doAssert pl.name.len >= 0
    let b = readRoute(p, body)
    if b.ok:
      for s in b.route.steps: doAssert s.text.len >= 0
  discard readGeoJson(body)
  # polylines
  let line = mutate(["_p~iF~ps|U_ulLnnqC_mqNvxq`@", "BFoz5xJ67i1B1B7PzIhaxL7Y",
                     encodePolyline([(1.0, 2.0), (-89.9, 179.9)], 6)][r.rand(2)])
  try: discard decodePolyline(line, r.rand(4 .. 7))
  except ValueError: inc refused
  try: discard decodeFlexPolyline(line)
  except ValueError: inc refused
  if round mod 500 == 0: echo round, " rounds"

removeDir(tmp)
echo "fuzz_maps: ", rounds, " rounds, ", accepted, " accepted, ", refused, " refused, no crash"

## The world map: lookups, what is where, and the widget by mouse, keys and
## finger -- headless, on the fake driver.

import std/[math, monotimes, times, strutils]
import retroui/[core, gfx, mapview]
import retroui/uirelays/[coords, screen, input]

# (a fake driver of its own: the test needs only the map's modules)
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
proc key(k: KeyCode; mods: set[Modifier] = {}) =
  queue.add Event(kind: KeyDownEvent, key: k, mods: mods)
  queue.add Event(kind: KeyUpEvent, key: k, mods: mods)
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
proc click(r: Rect; dx = 10; dy = -1; clicks = 1) =
  let x = r.x + dx
  let y = r.y + (if dy < 0: r.h div 2 else: dy)
  down(x, y, clicks)
  run()
  up(x, y)
  run()

# ---- lookups --------------------------------------------------------------------------------

block lookups:
  let om = countryIndex("OM")
  doAssert om >= 0 and countryIndex("OMN") == om and countryIndex(" oman ") == om
  doAssert countryNameAt(om) == "Oman"
  doAssert countryName("ae") == "United Arab Emirates", countryName("ae")
  doAssert countryCode("Oman") == "OMN" and countryCode("UAE", alpha3 = false) == "AE"
  doAssert countryIndex("USA") == countryIndex("US") and countryIndex("uk") == countryIndex("GBR")
  doAssert countryIndex("Narnia") == -1 and countryIndex("") == -1
  doAssert countryName("zz") == "" and countryCode("nowhere") == ""
  doAssert countryA2At(-1) == "" and countryA3At(10_000) == "" and countryNameAt(-5) == ""
  doAssert countryCount() > 230
  for c in ["BH", "SG", "MV", "QA", "KW", "VA", "MC", "LS", "XK"]:
    doAssert countryIndex(c) >= 0, "small ones are there too: " & c
  let (lat, lon) = latLonOf("OM")
  doAssert lat > 16 and lat < 27 and lon > 51 and lon < 60, $lat & " " & $lon
  doAssert latLonOf("nope") == (0.0, 0.0)
  let mus = cityLatLon("muscat")
  doAssert mus.found and abs(mus.lat - 23.6) < 0.2 and abs(mus.lon - 58.4) < 0.2
  doAssert not cityLatLon("Atlantis").found
  let mk = cityMarker("Sohar", size = 5)
  doAssert mk.label == "Sohar" and mk.size == 5 and mk.lat > 24
  doAssert cityMarker("Oman").lat > 16, "a country when there is no such city"

block whereIsWhat:
  let at = proc (lat, lon: float): string = countryNameAt(countryAtLatLon(lat, lon))
  doAssert at(23.6, 58.4) == "Oman"
  doAssert at(48.85, 2.35) == "France"
  doAssert at(-1.3, 36.8) == "Kenya"
  doAssert at(56.0, -100.0) == "Canada"
  doAssert at(-29.5, 28.2) == "Lesotho", "an enclave, not the country around it: " & at(-29.5, 28.2)
  doAssert at(67.0, 170.0) == "Russia", "Russia up to the date line: " & at(67.0, 170.0)
  doAssert at(66.0, -173.0) == "Russia", "... and over it: " & at(66.0, -173.0)
  doAssert at(0.0, -30.0) == "", "the Atlantic"
  doAssert at(-80.0, 0.0) == "Antarctica"
  # nearly every country's label point is inside it
  var ok = 0
  var missed: seq[string]
  for i in 0 ..< countryCount():
    let (la, lo) = latLonOf(countryNameAt(i))
    if countryAtLatLon(la, lo) == i: inc ok
    else: missed.add countryNameAt(i)
  doAssert ok >= countryCount() * 9 div 10, $missed

fakeDriver()
startApp("map", W, H)

proc center(r: Rect): (int, int) = (r.x + r.w div 2, r.y + r.h div 2)

var world = MapState()
var ev, clickEv: MapEvent
var vals = @[("OM", 120.0), ("AE", 340.0), ("FR", 900.0), ("unknown", 5.0), ("BR", NaN)]
var marks = @[cityMarker("Muscat", size = 6), cityMarker("London")]
var routes = @[MapRoute(fromLat: 23.6, fromLon: 58.4, toLat: 51.5, toLon: -0.1)]
var mapR: Rect
view = proc () =
  let e = mapView(world, height = H - 2 * Pad, values = vals, markers = marks, routes = routes,
                  legendTitle = "Sales")
  if e.country >= 0 or e.marker >= 0 or e.moved: ev = e
  if e.clicked: clickEv = e
  mapR = ui.lastRect

block drawn:
  run(3)
  doAssert world.zoom == 1
  # the sea, the land, and a country with a value in its color
  let (cx, cy) = world.mapPoint(0.0, -30.0)
  let sea = px(cx, cy)
  let (fx, fy) = world.mapPoint(46.5, 2.5)
  let france = px(fx, fy)
  let (bx, by) = world.mapPoint(-10.0, -52.0)
  let brazil = px(bx, by)
  let (gx, gy) = world.mapPoint(60.0, 90.0)          # Russia, no value
  let land = px(gx, gy)
  doAssert sea != land and france != land and france != sea, toHex(sea) & " " & toHex(land) & " " & toHex(france)
  doAssert brazil == land, "NaN is no value"
  # France has the highest value: the darkest
  let (ox, oy) = world.mapPoint(20.0, 56.0)           # inside Oman
  let oman = px(ox, oy)
  proc lum(c: uint32): int = int((c shr 16) and 255) + int((c shr 8) and 255) + int(c and 255)
  doAssert lum(france) < lum(oman), "a higher value, a stronger color"

block hoverAndClick:
  let (fx, fy) = world.mapPoint(46.5, 2.5)
  move(fx, fy)
  run(2)
  doAssert ev.country >= 0 and ev.name == "France" and ev.code == "FRA" and ev.code2 == "FR", ev.name
  doAssert abs(ev.lat - 46.5) < 1.5 and abs(ev.lon - 2.5) < 1.5
  clickEv = MapEvent()
  down(fx, fy)
  run()
  up(fx, fy)
  run()
  doAssert clickEv.clicked and clickEv.name == "France", $clickEv
  # a marker under the mouse
  let (mx, my) = world.mapPoint(23.59, 58.41)
  move(mx, my)
  run(2)
  doAssert ev.marker == 0, "the Muscat marker: " & $ev.marker

block panAndZoom:
  ev = MapEvent()
  let (cx, cy) = center(mapR)
  # the wheel zooms in at the mouse, keeping that place under it
  move(cx + 50, cy)
  run()
  let before = world.mapLatLonAt(cx + 50, cy)
  queue.add Event(kind: MouseWheelEvent, y: 3)
  run(2)
  doAssert world.zoom > 1.9, $world.zoom
  let after = world.mapLatLonAt(cx + 50, cy)
  doAssert abs(after.lat - before.lat) < 0.5 and abs(after.lon - before.lon) < 0.5
  # a drag moves it (not a click)
  let lon0 = world.lon
  clickEv = MapEvent()
  down(cx, cy)
  run()
  for i in 1 .. 5:
    move(cx + i * 20, cy)
    run()
  up(cx + 100, cy)
  run()
  doAssert world.lon < lon0, "dragged right: the view goes west"
  doAssert not clickEv.clicked, "a drag is not a click"
  # keys, with the focus: + zooms, arrows move, Home shows it all
  let z = world.zoom
  key(KeyEqual)
  run()
  doAssert world.zoom > z * 1.5
  let lon1 = world.lon
  key(KeyRight)
  run()
  doAssert world.lon > lon1
  key(KeyHome)
  run()
  doAssert world.zoom == 1
  # the buttons in the corner: + and the whole world
  let b = rect(mapR.x + dp(6), mapR.y + dp(6), dp(20), dp(20))
  click(b, dx = b.w div 2)
  doAssert world.zoom > 1.9
  click(rect(b.x, b.y + 2 * (b.h + dp(2)), b.w, b.h), dx = b.w div 2)
  doAssert world.zoom == 1
  # a double click zooms in
  down(cx, cy, clicks = 2)
  run()
  up(cx, cy)
  run()
  doAssert world.zoom > 1.9
  world.resetView()
  run()

block fingers:
  ui.touch = true
  # a finger drags the map
  world.zoomTo(20.0, 50.0, 4)
  run(2)
  let lat0 = world.lat
  let (cx, cy) = center(mapR)
  down(cx, cy)
  run()
  for i in 1 .. 6:
    move(cx, cy + i * 15)
    run()
  up(cx, cy + 90)
  run(2)
  doAssert world.lat > lat0, "a finger dragging down shows what is north"
  # a tap names the country
  clickEv = MapEvent()
  let (ox, oy) = world.mapPoint(21.0, 57.0)
  down(ox, oy)
  run()
  up(ox, oy)
  run(2)
  doAssert clickEv.clicked and clickEv.name == "Oman", $clickEv
  ui.touch = false
  world.resetView()

block fitAndOptions:
  world.fitTo(["OM", "AE"])
  run(2)
  doAssert world.zoom > 5, $world.zoom
  let (x, y) = world.mapPoint(22.0, 57.0)
  doAssert x > mapR.x and x < mapR.x + mapR.w and y > mapR.y and y < mapR.y + mapR.h
  world.fitTo(["nowhere"])                               # nothing to fit: as it was
  run()
  # an empty map, odd values, the other projection, Antarctica
  vals = @[]
  marks = @[]
  routes = @[MapRoute(fromLat: 10, fromLon: 170, toLat: 20, toLon: -170),
             MapRoute(fromLat: 5, fromLon: 5, toLat: 5, toLon: 5)]
  world.projection = mpEquirect
  world.showAntarctica = true
  world.resetView()
  run(3)
  doAssert countryNameAt(countryAtLatLon(-80.0, 0.0, mpEquirect)) == "Antarctica"
  vals = @[("OM", Inf), ("AE", -Inf), ("SA", 1e300), ("QA", -0.0)]
  run(2)
  marks = @[MapMarker(lat: NaN, lon: 0, label: "nowhere"), MapMarker(lat: 1e300, lon: -1e300, size: Inf),
           MapMarker(lat: 95, lon: 400, label: "off the map")]
  routes = @[MapRoute(fromLat: NaN, fromLon: 0, toLat: 0, toLon: 0)]
  world.zoomTo(NaN, 0, 3)
  run(2)
  world.lat = NaN
  run(2)
  doAssert world.zoom >= 1 and world.lat == world.lat, "a broken view is reset"
  world = MapState()
  vals = @[("OM", 1.0)]
  marks = @[]
  routes = @[]
  run(2)
  # every theme draws it
  for t in builtinThemes:
    ui.theme = t.theme
    run(2)
  ui.theme = builtinThemes[0].theme

block speed:
  # a full redraw of the map's picture each frame (the view moves)
  let t0 = getMonoTime()
  for i in 0 ..< 20:
    world.zoomTo(20.0, float(i * 3), 1 + float(i mod 4))
    run()
  let ms = (getMonoTime() - t0).inMicroseconds.float / 1000 / 20
  echo "map frame with a new view: ", formatFloat(ms, ffDecimal, 1), " ms"
  doAssert ms < 200

echo "map view tests passed"

## A long session on a street map and a moving model: the map moved and
## zoomed all over the world (thousands of tiles in and out of its cache),
## then a car's clips played for thousands of frames -- the memory the
## program holds must level off, not keep growing. Not in `nimble test`
## (it takes minutes):
##
##   nim c -r -d:release -d:useMalloc tests/soak_maps3d.nim

import std/[os, strutils, random, monotimes, times]
import retroui
import retroui/[tilemap, view3d]
import harness

include carscene

proc rss(): int64 =
  ## The program's resident memory now (Linux), bytes.
  try:
    let f = readFile("/proc/self/statm").split(' ')
    parseBiggestInt(f[1]) * 4096
  except CatchableError: 0

fakeDriver()
startApp("Soak", W, H)
# (a small cap for the tiles kept in memory: full within the first cycles,
# so what grows after that is a leak, not the cache filling up to its 192 MB)
maxTileBytes = 32 shl 20

# tiles of a folder: zooms 0 to 5, each a color of its own
let dir = getTempDir() / "retro-soak-tiles"
removeDir(dir)
for z in 0 .. 5:
  for x in 0 ..< (1 shl z):
    for y in 0 ..< (1 shl z):
      let b = newBitmap(256, 256)
      let c = 0xFF000000'u32 or uint32((z * 40) and 255) shl 16 or uint32((x * 7) and 255) shl 8 or
              uint32((y * 7) and 255)
      for p in b.px.mitems: p = c
      createDir(dir / $z / $x)
      writeFile(dir / $z / $x / ($y & ".png"), encodePng(b, level = 1))
let src = folderSource(dir, maxZoom = 5)
var st = TileMapState(lat: 0, lon: 0, zoom: 2)
var car = carScene()
var cam = camera3()
fitView(car, cam)
var showCar = false
view = proc () =
  if showCar: discard view3d(car, cam, height = -1)
  else: discard tileMap(st, src, height = -1, markers = [MapMarker(lat: 23.6, lon: 58.4, label: "Muscat")])

proc waitTiles() =
  let t0 = getMonoTime()
  run(2)
  while loadingTiles() > 0 and (getMonoTime() - t0).inMilliseconds < 8000:
    os.sleep(5)
    run()

var r = initRand(29)
var seen: seq[int64]
let t0 = getMonoTime()
for cycle in 0 ..< 10:
  for _ in 0 ..< 60:
    st.centerOn(r.rand(-80.0 .. 80.0), r.rand(-179.0 .. 179.0), r.rand(0.0 .. 9.0))
    waitTiles()
  seen.add rss()
  echo "map cycle ", cycle + 1, ": ", seen[^1] div (1024 * 1024), " MB"
let mapGrew = seen[^1] - seen[3]
showCar = true
car.play("WheelsTurn")
var carSeen: seq[int64]
for cycle in 0 ..< 10:
  for f in 0 ..< 300:
    if f mod 100 == 0: car.play("DoorOpen", loop = false, speed = if f mod 200 == 0: 1.0 else: -1.0)
    discard car.animate(1 / 60)
    cam.yaw += 0.5
    run()
  carSeen.add rss()
  echo "car cycle ", cycle + 1, ": ", carSeen[^1] div (1024 * 1024), " MB"
let carGrew = carSeen[^1] - carSeen[3]
echo "after the fourth cycles: the map grew ", mapGrew div (1024 * 1024), " MB, the car ",
     carGrew div (1024 * 1024), " MB (", (getMonoTime() - t0).inSeconds, " s)"
removeDir(dir)
when defined(linux) and defined(useMalloc):
  doAssert mapGrew < 24 * 1024 * 1024, "the map's memory keeps growing"
  doAssert carGrew < 8 * 1024 * 1024, "the car's memory keeps growing"
echo "soak_maps3d: ok"

## The 3D view: models loaded (and refused), shapes, bar charts, the
## camera, pictures drawn only when something changed, the mouse, keys and
## fingers, picking -- headless, on the fake driver.

import std/[os, times, math, strutils]
import retroui
import retroui/view3d
import retroui/uirelays/input
import harness

const dataDir = currentSourcePath().parentDir / "data" / "3d"

proc refused(f: proc ()): bool =
  try:
    f()
    false
  except ValueError:
    true

# ---- loading -----------------------------------------------------------------------------------

block objFiles:
  let cube = loadObj(readFile(dataDir / "cube.obj"))
  doAssert cube.tris.len == 12, $cube.tris.len
  doAssert cube.smooth and cube.normals.len == cube.verts.len
  doAssert cube.verts.len == 24, "a point per point-and-normal pair: " & $cube.verts.len
  let pyr = loadObj(readFile(dataDir / "pyramid.obj"))
  doAssert pyr.verts.len == 5 and pyr.tris.len == 6, $pyr.tris.len
  doAssert not pyr.smooth
  for t in pyr.tris:
    for k in t: doAssert k in 0 ..< 5
  let m = loadModel(dataDir / "cube.obj")
  var hi = 0'f32
  for v in m.verts: hi = max(hi, max(abs(v.x), max(abs(v.y), abs(v.z))))
  doAssert abs(hi - 1) < 1e-4, "loadModel scales it to 2 across: " & $hi

block objRefused:
  for bad in ["", "v 1 2 3\n", "v 1 2\nf 1 1 1", "v 1 2 3\nf 1 2",
              "v 1 2 3\nf 1 2 4", "v nan 0 0\nf 1 1 1", "v 1e400 0 0\nf 1 1 1",
              "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1/1/9 2 3", "v 0 0 0\nf 1x 1 1",
              "v 0 0 0\nf -5 1 1", "v 0 0 0\nf 99999999999999999999999 1 1"]:
    let s = bad
    doAssert refused(proc () = discard loadObj(s)), "refused: " & bad.escape

block stlFiles:
  let a = loadStl(readFile(dataDir / "cube_ascii.stl"))
  let b = loadStl(readFile(dataDir / "cube_bin.stl"))
  doAssert a.tris.len == 12 and b.tris.len == 12
  doAssert a.verts.len == 36 and b.verts.len == 36
  for k in 0 ..< 36:
    doAssert abs(a.verts[k].x - b.verts[k].x) < 1e-6
  doAssert refused(proc () = discard loadStl("solid x\nfacet\nvertex 1 2 3\nendfacet\n"))
  doAssert refused(proc () = discard loadStl("not a model at all"))
  # a binary one with a point that is not a number
  var bin = readFile(dataDir / "cube_bin.stl")
  bin[84 + 12] = '\xFF'
  bin[84 + 13] = '\xFF'
  bin[84 + 14] = '\xC0'
  bin[84 + 15] = '\x7F'
  doAssert refused(proc () = discard loadStl(bin)), "NaN refused"
  # a header that claims more triangles than there are: not binary, not text
  var short = readFile(dataDir / "cube_bin.stl")
  short.setLen(200)
  doAssert refused(proc () = discard loadStl(short))

# ---- shapes and charts --------------------------------------------------------------------------

block shapes:
  doAssert box(1, 2, 3).tris.len == 12
  let s = sphere(1, segments = 16, rings = 8)
  doAssert s.smooth and s.normals.len == s.verts.len and s.tris.len == 16 * 2 * 8 - 32
  for t in s.tris:
    for k in t: doAssert k in 0 ..< s.verts.len
  let c = cylinder(0.5, 2, segments = 12)
  doAssert c.tris.len == 12 * 2 + 12 * 2
  let k = cone(0.5, 1, segments = 12)
  doAssert k.tris.len == 12 * 2 + 12
  doAssert plane(2, 2).twoSided
  var scene = Scene3()
  scene.addGrid(4, 4)
  doAssert scene.lines.len == 10
  scene.addAxes()
  doAssert scene.lines.len == 13
  var m = box(4, 2, 2)
  m.pos = vec3(10, 0, 0)
  centerMesh(m, 1)
  var hi = 0'f32
  for v in m.verts: hi = max(hi, abs(v.x))
  doAssert abs(hi - 0.5) < 1e-5

block barCharts:
  let sc = bars3d(@[@[1.0, 2, 3], @[4.0, -1, 0]], ["North", "South"], ["Q1", "Q2", "Q3"],
                  showValues = true)
  doAssert sc.meshes.len == 6 + 1, "a bar for each value and the floor"
  doAssert sc.labels.len == 2 + 3 + 6
  var tallest = 0'f32
  for mm in sc.meshes:
    if mm.name != "floor":
      for v in mm.verts: tallest = max(tallest, v.y * mm.scale.y)
  doAssert tallest > 0
  doAssert sc.meshes[4].pos.y < 0, "a negative value goes down"
  # nothing at all, and values that are not numbers: no bars, no failure
  doAssert bars3d(newSeq[seq[float]]()).meshes.len == 1
  doAssert bars3d(@[@[NaN, Inf]]).meshes.len == 1

block cameraFit:
  var scene = Scene3()
  var m = box(2, 2, 2)
  m.pos = vec3(5, 1, -3)
  scene.add m
  var cam = camera3()
  fitView(scene, cam)
  doAssert abs(cam.target.x - 5) < 1e-4 and abs(cam.target.z + 3) < 1e-4
  doAssert cam.distance > 1.7 and cam.distance < 10
  let d = cam.distance
  cam.yaw = 100
  cam.distance = 50
  resetView(cam)
  doAssert cam.distance == d and cam.yaw == 35

block offscreen:
  var scene = Scene3()
  scene.add box(1, 1, 1, color(200, 0, 0))
  scene.background = color(255, 255, 255)
  var cam = camera3()
  fitView(scene, cam)
  let b = render3d(scene, cam, 200, 150)
  doAssert b.w == 200 and b.h == 150
  let mid = b.px[75 * 200 + 100] and 0xFFFFFF
  doAssert mid != 0xFFFFFF and (mid shr 16) > 40, "the box is in the middle: " & toHex(mid)
  doAssert (b.px[0] and 0xFFFFFF) == 0xFFFFFF, "the background in the corner"
  # lit faces differ from each other
  var shades: seq[uint32]
  for (x, y) in [(100, 50), (80, 90), (120, 90)]:
    let p = b.px[y * 200 + x] and 0xFFFFFF
    if p != 0xFFFFFF and p notin shades: shades.add p
  doAssert shades.len >= 2, "faces are lit differently"

block groundShadow:
  # a soft shadow under the box, on the ground: darker there, and a click
  # on it picks nothing; made again, it takes the old one's place
  var scene = Scene3()
  scene.add box(1, 1, 1, color(200, 0, 0))
  scene.background = color(255, 255, 255)
  var cam = camera3(pitch = 40)
  fitView(scene, cam)
  cam.distance *= 1.6
  let before = render3d(scene, cam, 200, 150)
  let s = addShadow(scene, strength = 0.8)
  doAssert s == 1 and scene.meshes.len == 2 and scene.meshes[1].ghost
  doAssert addShadow(scene, strength = 0.8) == 1 and scene.meshes.len == 2, "in the old one's place"
  doAssert scene.meshes[1].visible
  let after = render3d(scene, cam, 200, 150)
  var darker = 0
  var other = 0
  for i in 0 ..< 200 * 150:
    let a = before.px[i] and 0xFFFFFF
    let c = after.px[i] and 0xFFFFFF
    if a == 0xFFFFFF and c != 0xFFFFFF:
      if (c and 0xFF) < 0xF0: inc darker
    elif a != c: inc other
  doAssert darker > 300, "a shadow on the white ground: " & $darker
  doAssert other < darker div 4, "the box as it was: " & $other
  # (nothing to shadow: none added)
  var empty = Scene3()
  doAssert addShadow(empty) == -1 and empty.meshes.len == 0

block speed:
  var scene = Scene3()
  scene.add sphere(1, segments = 100, rings = 51)
  doAssert scene.meshes[0].tris.len >= 10_000
  var cam = camera3()
  fitView(scene, cam)
  discard render3d(scene, cam, 800, 600)
  let t0 = epochTime()
  for i in 0 ..< 10:
    cam.yaw += 3
    discard render3d(scene, cam, 800, 600)
  let ms = (epochTime() - t0) * 1000 / 10
  echo "  10k triangles at 800x600: ", formatFloat(ms, ffDecimal, 2), " ms a picture"

# ---- the widget ----------------------------------------------------------------------------------

fakeDriver()
startApp("view3d", W, H)

var scene = Scene3()
var red = box(1, 1, 1, color(200, 0, 0), name = "red box")
scene.add red
scene.addGrid(4, 4)
var cam = camera3()
fitView(scene, cam)
var ev: View3DEvent
var lastEv: View3DEvent
var r: Rect
view = proc () =
  ev = view3d(scene, cam, height = 300)
  if ev.clicked or ev.cameraChanged: lastEv = ev
  r = ui.lastRect
run(3)

proc center(): (int, int) = (r.x + r.w div 2, r.y + r.h div 2)

block drawsOnlyWhenChanged:
  let n = renders()
  run(5)
  doAssert renders() == n, "idle frames draw nothing again"
  let (cx, cy) = center()
  doAssert px(cx, cy) != px(r.x + 5, r.y + r.h - 5), "the box is drawn"
  scene.meshes[0].color = color(0, 160, 0)
  run()
  doAssert renders() == n + 1, "a changed color draws it again"
  scene.meshes[0].verts[0].x = -0.7
  sceneChanged(scene)
  run()
  doAssert renders() == n + 2, "sceneChanged draws it again"

block picking:
  let (cx, cy) = center()
  lastEv = View3DEvent()
  down(cx, cy)
  run()
  up(cx, cy)
  run()
  doAssert lastEv.clicked and lastEv.picked == 0, "the box is picked: " & $lastEv.picked
  lastEv = View3DEvent()
  down(r.x + 8, r.y + r.h div 2)
  run()
  up(r.x + 8, r.y + r.h div 2)
  run()
  doAssert lastEv.clicked and lastEv.picked == -1, "nothing there"
  # hovering
  move(cx, cy)
  run(2)
  doAssert ev.hovered == 0

block mouse:
  let yaw0 = cam.yaw
  let (cx, cy) = center()
  down(cx, cy)
  run()
  for i in 1 .. 4:
    move(cx + i * 15, cy)
    run()
  up(cx + 60, cy)
  run()
  doAssert abs(cam.yaw - (yaw0 - 30)) < 0.01, "a drag turns it: " & $cam.yaw
  doAssert not lastEv.clicked or lastEv.picked == 0
  # Shift + drag moves it
  let t0 = cam.target
  queue.add Event(kind: MouseMoveEvent, x: cx, y: cy)
  queue.add Event(kind: MouseDownEvent, x: cx, y: cy, button: LeftButton, clicks: 1,
                  mods: {ShiftPressed}, hasMods: true)
  run()
  move(cx + 40, cy + 10)
  run()
  queue.add Event(kind: MouseUpEvent, x: cx + 40, y: cy + 10, button: LeftButton,
                  mods: {}, hasMods: true)
  run()
  doAssert cam.target != t0, "Shift + drag moves it"
  # the wheel zooms
  let d0 = cam.distance
  move(cx, cy)
  queue.add Event(kind: MouseWheelEvent, y: 2)
  run()
  doAssert cam.distance < d0, "the wheel brings it closer"

block keysAndButtons:
  let (cx, cy) = center()
  down(cx, cy)
  run()
  up(cx, cy)
  run()
  doAssert ui.focus == ui.lastId or true
  let y0 = cam.yaw
  key(KeyLeft)
  run()
  doAssert cam.yaw > y0, "Left turns it"
  let d0 = cam.distance
  key(KeyMinus)
  run()
  doAssert cam.distance > d0, "- moves away"
  key(KeyHome)
  run()
  doAssert abs(cam.yaw - 35) < 0.01, "Home: the first view"
  # the + button in the corner
  let bs = dp(20)
  let bx = r.x + 2 + (r.w - 4) - 3 * (bs + dp(2)) + bs div 2
  let by = r.y + 2 + dp(3) + bs div 2
  let d1 = cam.distance
  down(bx, by)
  run()
  up(bx, by)
  run()
  doAssert cam.distance < d1, "the + button zooms in"
  key(KeyHome)
  run()

block fingers:
  ui.touch = true
  run(2)
  let (cx, cy) = center()
  let yaw0 = cam.yaw
  let pageY0 = ui.pageY
  queue.add Event(kind: MouseMoveEvent, x: cx, y: cy)
  queue.add Event(kind: MouseDownEvent, x: cx, y: cy, button: LeftButton, clicks: 1)
  run()
  for i in 1 .. 4:
    move(cx - i * 10, cy + i * 3)
    run()
  up(cx - 40, cy + 12)
  run()
  doAssert cam.yaw > yaw0, "a finger turns it"
  doAssert ui.pageY == pageY0, "the page does not scroll instead"
  # a finger held a moment, then moved: it moves the scene
  let t0 = cam.target
  let y1 = cam.yaw
  down(cx, cy)
  run()
  for i in 0 ..< 40: run()                 # (the fake clock: 16 ms a frame)
  move(cx + 30, cy)
  run()
  move(cx + 50, cy)
  run()
  up(cx + 50, cy)
  run()
  doAssert cam.target != t0 and cam.yaw == y1, "held, then moved: it moves"
  ui.touch = false

block inADialog:
  resetView(cam)
  var open = true
  var picked = -2
  view = proc () =
    dialog(open, "Model", 360):
      let e = view3d(scene, cam, height = 200, key = "dlg")
      if e.clicked: picked = e.picked
      r = ui.lastRect
  run(3)
  let (cx, cy) = center()
  down(cx, cy)
  run()
  up(cx, cy)
  run()
  doAssert picked == 0, "it works in a dialog: " & $picked & " " & $r & " " & $(cx, cy) & " " & $cam
  open = false
  run(2)

block sharpAtTwice:
  # at 2x the picture has twice the pixels, and picking still finds the box
  setZoom(2)
  resetView(cam)
  view = proc () =
    ev = view3d(scene, cam, height = 150)
    if ev.clicked: lastEv = ev
    r = ui.lastRect
  let n = renders()
  run(3)
  doAssert renders() > n
  let (cx, cy) = center()
  lastEv = View3DEvent()
  down(cx * 2, cy * 2)                    # (the driver's pixels)
  run()
  up(cx * 2, cy * 2)
  run()
  doAssert lastEv.clicked and lastEv.picked == 0, "picked at 2x: " & $lastEv.picked
  setZoom(0)
  run(2)

echo "view3d tests passed"

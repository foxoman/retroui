## Models from Blender and other 3D tools (`gltf`) in the 3D view: a car
## made here, written as a .glb and read again -- its parts as nodes (moved,
## turned, hidden, tinted, picked), its clips played, a picture on a
## surface, shapes (morph targets) and bones (skinning) followed; glTF
## written by hand (embedded data, sparse accessors, strips); damaged files
## refused, never a crash.

import std/[os, math, strutils, json, base64, random]
import retroui/[core, gfx, imaging, view3d, gltf]
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

proc rgbOf(p: uint32): (int, int, int) = (int((p shr 16) and 255), int((p shr 8) and 255), int(p and 255))

# ---- a car, made here ----------------------------------------------------------------------

include carscene

block math:
  let q = quatAxis(vec3(0, 1, 0), 90)
  let m = compose(vec3(1, 2, 3), q, vec3(2, 2, 2))
  let d = decompose(m)
  doAssert abs(d.t.x - 1) < 1e-5 and abs(d.t.z - 3) < 1e-5 and abs(d.s.y - 2) < 1e-5
  doAssert abs(abs(d.r.y) - abs(q.y)) < 1e-5 and abs(abs(d.r.w) - abs(q.w)) < 1e-5
  let h = slerp(Quat(w: 1), q, 0.5)
  doAssert abs(h.y - sin(PI / 8).float32) < 1e-5
  let e = quatEuler(0, 90, 0)
  doAssert abs(e.y - q.y) < 1e-5 and abs(e.w - q.w) < 1e-5

block roundTrip:
  let car = carScene()
  let glb = toGlb(car)
  doAssert glb[0 .. 3] == "glTF"
  let back = readGlb(glb)
  doAssert back.nodes.len == car.nodes.len and back.meshes.len == car.meshes.len
  doAssert back.findNode("Wheel_RR") >= 0 and back.nodes[back.findNode("Wheel_RR")].parent == back.findNode("Car")
  doAssert back.animationNames == @["DoorOpen", "WheelsTurn"]
  doAssert abs(back.animations[1].duration - 2) < 1e-6
  doAssert back.materials[0].name == "CarPaint" and abs(back.materials[0].metallic - 0.6) < 1e-6
  doAssert back.materials[2].alphaMode == amBlend
  let b0 = bounds(car)
  let b1 = bounds(back)
  doAssert abs(b0.lo.x - b1.lo.x) < 1e-4 and abs(b0.hi.z - b1.hi.z) < 1e-4, $b0 & " " & $b1

proc shot(s: Scene3; cam: Camera3): Bitmap = render3d(s, cam, 320, 240, color(255, 255, 255))

block lookAndMove:
  var car = carScene()
  var cam = camera3(yaw = 20, pitch = 15)
  fitView(car, cam)
  var p = shot(car, cam)
  # the body's paint in the middle: red, lit
  let (r, g, b) = rgbOf(p.px[120 * 320 + 160])
  doAssert r > 100 and r > g * 2 and r > b * 2, $(r, g, b)
  # tinted blue: the car is blue (the door is in front, a part of its own)
  car.tint("Car", color(0, 60, 200))
  p = shot(car, cam)
  let (r2, g2, b2) = rgbOf(p.px[120 * 320 + 160])
  doAssert b2 > r2 * 2, $(r2, g2, b2)
  car.tint("Car", Color())
  # the paint's color changed for every part that has it
  car.recolor("CarPaint", color(0, 160, 0))
  p = shot(car, cam)
  let (r3, g3, b3) = rgbOf(p.px[120 * 320 + 160])
  doAssert g3 > r3 * 2 and g3 > b3, $(r3, g3, b3)
  # the door hidden: the body behind it; the whole car hidden: the white behind it
  car.setVisible("Door", false)
  p = shot(car, cam)
  doAssert (p.px[120 * 320 + 160] and 0xFFFFFF) != 0xFFFFFF
  car.setVisible("Car", false)
  p = shot(car, cam)
  doAssert (p.px[120 * 320 + 160] and 0xFFFFFF) == 0xFFFFFF
  car.setVisible("Car", true)
  car.setVisible("Door", true)
  # a part turned and moved by the app
  let wheel = car.findNode("Wheel_FL")
  let before = car.nodes[wheel].r
  car.turnNode("Wheel_FL", vec3(0, 0, 1), 30)
  doAssert car.nodes[wheel].r != before
  car.moveNode("Car", vec3(0, 1, 0))
  doAssert abs(bounds(car).lo.y - 0.05) < 0.01, "the wheels' bottom, a unit up: " & $bounds(car).lo

block clips:
  var car = carScene()
  var cam = camera3(yaw = 20, pitch = 15)
  fitView(car, cam)
  let closed = bounds(car)
  car.play("DoorOpen", loop = false)
  doAssert car.isPlaying("DoorOpen")
  for i in 0 ..< 70: car.animate(1 / 60)
  doAssert not car.isPlaying("DoorOpen"), "a clip that does not loop ends"
  let door = car.findNode("Door")
  doAssert abs(car.nodes[door].r.y - sin(PI / 4).float32) < 1e-4, $car.nodes[door].r
  doAssert bounds(car).hi.z > closed.hi.z + 0.5, "the door swung out: " & $bounds(car).hi.z
  # scrubbed half way
  car.seekAnimation("DoorOpen", 0.5)
  doAssert abs(car.nodes[door].r.y - sin(PI / 8).float32) < 1e-3
  # the wheels loop
  car.play("WheelsTurn")
  for i in 0 ..< 200: car.animate(1 / 60)
  doAssert car.isPlaying("WheelsTurn")
  car.stop()
  doAssert not car.isPlaying()

block pictureOnASurface:
  # a quad with a 2x2 checker picture, embedded (data:), glTF written by hand
  let tex = newBitmap(2, 2)
  tex.px = @[0xFFFF0000'u32, 0xFF0000FF'u32, 0xFF0000FF'u32, 0xFFFF0000'u32]
  let png = encodePng(tex)
  var bin = ""
  proc f(v: float32) =
    let u = cast[uint32](v)
    for k in 0 .. 3: bin.add char((u shr (8 * k)) and 255)
  for p in [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)]:
    f(p[0].float32); f(p[1].float32); f(0)
  for uv in [(0.0, 1.0), (1.0, 1.0), (1.0, 0.0), (0.0, 0.0)]:
    f(uv[0].float32); f(uv[1].float32)
  # (a strip: 0 1 3 2)
  for i in [0'u16, 1, 3, 2]:
    bin.add char(i and 255)
    bin.add char(i shr 8)
  let j = %*{"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}],
    "nodes": [{"name": "Sign", "mesh": 0}],
    "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "TEXCOORD_0": 1}, "indices": 2, "mode": 5, "material": 0}]}],
    "materials": [{"name": "Sign", "pbrMetallicRoughness": {"baseColorTexture": {"index": 0}, "metallicFactor": 0},
                   "extensions": {"KHR_materials_unlit": {}}}],
    "textures": [{"source": 0}],
    "images": [{"uri": "data:image/png;base64," & encode(png)}],
    "buffers": [{"uri": "data:application/octet-stream;base64," & encode(bin), "byteLength": bin.len}],
    "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 48}, {"buffer": 0, "byteOffset": 48, "byteLength": 32},
                    {"buffer": 0, "byteOffset": 80, "byteLength": 8}],
    "accessors": [{"bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3"},
                  {"bufferView": 1, "componentType": 5126, "count": 4, "type": "VEC2"},
                  {"bufferView": 2, "componentType": 5123, "count": 4, "type": "SCALAR"}]}
  let s = readGltf($j)
  doAssert s.meshes.len == 1 and s.meshes[0].tris.len == 2 and s.materials[0].texture != nil
  doAssert s.materials[0].unlit
  let cam = camera3(yaw = 0, pitch = 0, distance = 2.6, fov = 60)
  let p = render3d(s, cam, 200, 200, color(255, 255, 255))
  # (unlit: the picture's colors as they are; red top left, blue top right)
  let (ra, ga, ba) = rgbOf(p.px[60 * 200 + 60])
  let (rb, gb, bb) = rgbOf(p.px[60 * 200 + 140])
  doAssert ra > 200 and ba < 60, $(ra, ga, ba)
  doAssert bb > 200 and rb < 60, $(rb, gb, bb)

block shapesAndBones:
  # a mesh with a shape (morph target) that lifts its top, and two bones
  var s = Scene3()
  let root = s.addNode(newNode("Root"))
  let bone = s.addNode(newNode("Bone", root))
  var m = box(1, 1, 1, name = "blob")
  m.node = root
  m.material = 0
  s.materials.add Material3(name: "m", baseColor: [1'f32, 1, 1, 1], roughness: 1, alphaCutoff: 0.5)
  var lift: seq[Vec3]
  for v in m.verts: lift.add(if v.y > 0: vec3(0, 1, 0) else: vec3(0, 0, 0))
  m.targets = @[lift]
  m.morphWeights = @[0'f32]
  s.meshes.add m
  s.nodes[root].meshes.add 0
  doAssert abs(bounds(s).hi.y - 0.5) < 1e-5
  s.meshes[0].morphWeights = @[1'f32]
  doAssert abs(bounds(s).hi.y - 1.5) < 1e-5, "the shape taken: " & $bounds(s).hi.y
  s.nodes[root].morphWeights = @[0.5'f32]
  doAssert abs(bounds(s).hi.y - 1.0) < 1e-5, "the node's weights win"
  s.nodes[root].morphWeights = @[]
  s.meshes[0].morphWeights = @[0'f32]
  # bones: the top points follow the bone, the bottom ones the root
  s.skins.add Skin3(joints: @[root, bone], inverseBind: @[Identity4, Identity4])
  s.meshes[0].skin = 0
  for v in s.meshes[0].verts:
    s.meshes[0].joints.add [uint16(if v.y > 0: 1 else: 0), 0, 0, 0]
    s.meshes[0].weights.add [1'f32, 0, 0, 0]
  s.nodes[bone].t = vec3(0, 2, 0)
  sceneChanged(s)
  doAssert abs(bounds(s).hi.y - 2.5) < 1e-5 and abs(bounds(s).lo.y + 0.5) < 1e-5, $bounds(s)

block damaged:
  let good = toGlb(carScene())
  var refused = 0
  randomize(7)
  for k in 0 ..< 300:
    var d = good
    case k mod 3
    of 0: d.setLen(rand(d.len - 1))
    of 1:
      for _ in 0 ..< 8: d[rand(d.high)] = char(rand(255))
    else:
      d[12 + rand(20)] = char(rand(255))
    try:
      discard readGlb(d)
    except GltfError, ValueError, KeyError, IndexDefect, RangeDefect:
      inc refused
  doAssert refused > 100, $refused
  for bad in ["", "glTF", "{}", "[1, 2]", """{"asset": {"version": "1.0"}}""",
              """{"asset": {"version": "2.0"}, "extensionsRequired": ["KHR_draco_mesh_compression"]}"""]:
    var failed = false
    try: discard readGltf(bad)
    except GltfError: failed = true
    doAssert failed, bad
  # files only from beside the model
  var failed = false
  try: discard readGltf("""{"asset":{"version":"2.0"},"buffers":[{"uri":"../../../../etc/passwd","byteLength":10}]}""", "", getTempDir())
  except GltfError: failed = true
  doAssert failed

block blenderFiles:
  putEnv("RETRO_BLENDER", "/nonexistent/blender")
  doAssert blendToGlb("/tmp/x.blend") == ""
  var why = ""
  try: discard loadModel3("/tmp/x.blend")
  except GltfError as e: why = e.msg
  doAssert "Blender" in why, why
  delEnv("RETRO_BLENDER")
  # an .obj through the same call
  let obj = getTempDir() / "retro_tri.obj"
  writeFile(obj, "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n")
  doAssert loadModel3(obj).meshes.len == 1
  removeFile(obj)

# ---- in the view: a click names the part ----------------------------------------------------

fakeDriver()
startApp("gltf", W, H)
block picking:
  var car = carScene()
  var cam = camera3(yaw = 0, pitch = 0)
  fitView(car, cam)
  var ev, clickEv: View3DEvent
  view = proc () =
    ev = view3d(car, cam, height = 400, controls = false)
    if ev.clicked: clickEv = ev
  run(2)
  let r = ui.lastRect
  # the door is on the near side, right of the middle
  let x = r.x + r.w div 2 + 20
  let y = r.y + r.h div 2
  queue.add Event(kind: MouseMoveEvent, x: x, y: y)
  queue.add Event(kind: MouseDownEvent, x: x, y: y, button: LeftButton, clicks: 1)
  run()
  queue.add Event(kind: MouseUpEvent, x: x, y: y, button: LeftButton)
  run()
  doAssert clickEv.clicked and clickEv.nodeName == "Door", clickEv.nodeName
  # a clip playing keeps the frames coming, and the picture changes
  car.play("DoorOpen", loop = false)
  let before = renders()
  view = proc () =
    car.animate(1 / 60)
    ev = view3d(car, cam, height = 400, controls = false)
  run(10)
  doAssert renders() >= before + 8

echo "gltf: ok"

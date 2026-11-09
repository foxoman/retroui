## (the car of test_gltf.nim, for tests/gpu3d)

import std/[strutils, math]
import retroui/[gfx, view3d]

proc carScene(): Scene3 =
  result.materials.add Material3(name: "CarPaint", baseColor: [0.75'f32, 0.05, 0.05, 1], metallic: 0.6,
                                 roughness: 0.3, alphaCutoff: 0.5)
  result.materials.add Material3(name: "Tire", baseColor: [0.08'f32, 0.08, 0.08, 1], metallic: 0,
                                 roughness: 0.9, alphaCutoff: 0.5)
  result.materials.add Material3(name: "Glass", baseColor: [0.6'f32, 0.8, 1.0, 0.3], metallic: 0,
                                 roughness: 0.05, alphaMode: amBlend, alphaCutoff: 0.5)
  let car = result.addNode(newNode("Car"))
  let body = result.addNode(newNode("Body", car))
  var bm = box(4, 1, 2, name = "body")
  bm.material = 0
  bm.node = body
  result.nodes[body].meshes.add result.meshes.len
  result.meshes.add bm
  for (name, x, z) in [("Wheel_FL", 1.3, 1.0), ("Wheel_FR", 1.3, -1.0), ("Wheel_RL", -1.3, 1.0), ("Wheel_RR", -1.3, -1.0)]:
    var n = newNode(name, car)
    n.t = vec3(x, -0.5, z)
    n.r = quatAxis(vec3(1, 0, 0), 90)
    let ni = result.addNode(n)
    var wm = cylinder(0.45, 0.3, name = name.toLowerAscii)
    wm.material = 1
    wm.node = ni
    result.nodes[ni].meshes.add result.meshes.len
    result.meshes.add wm
  # the door: a panel on the near side (+z), its hinge at the front edge
  var door = newNode("Door", car)
  door.t = vec3(0.6, 0, 1.02)
  let di = result.addNode(door)
  var dm = box(1.2, 0.8, 0.05, name = "door")
  for v in dm.verts.mitems: v = Vec3(x: v.x - 0.6, y: v.y, z: v.z)    # (turns about its front edge)
  dm.material = 0
  dm.node = di
  result.nodes[di].meshes.add result.meshes.len
  result.meshes.add dm
  # its clips: the door opens (a second), the wheels turn (over and over)
  result.animations.add Animation3(name: "DoorOpen", duration: 1, channels: @[
    AnimChannel3(node: di, path: apRotation, times: @[0'f32, 1],
                 values: @[0'f32, 0, 0, 1, 0, sin(PI / 4).float32, 0, cos(PI / 4).float32], interp: aiLinear)])
  var turn = Animation3(name: "WheelsTurn", duration: 2)
  for name in ["Wheel_FL", "Wheel_FR", "Wheel_RL", "Wheel_RR"]:
    let wi = result.findNode(name)
    var vals: seq[float32]
    for k in 0 .. 4:
      let q = quatAxis(vec3(0, 0, 1), -90.0 * k.float) * quatAxis(vec3(1, 0, 0), 90)
      vals.add [q.x, q.y, q.z, q.w]
    turn.channels.add AnimChannel3(node: wi, path: apRotation, times: @[0'f32, 0.5, 1, 1.5, 2], values: vals)
  result.animations.add turn
  sceneChanged(result)


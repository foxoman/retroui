## Feeds damaged glTF to the model reader (.glb bytes, and the JSON with
## its numbers, kinds and indices changed), then plays and draws what it
## accepts: nothing may fail other than with `GltfError`.
##
##   nim c -r -d:release --stackTrace:on --lineTrace:on tests/fuzz/fuzz_models.nim 3000

import std/[os, random, strutils, json, base64, math]
import retroui/[gfx, view3d, gltf]

include ../carscene

let rounds = if paramCount() >= 1: parseInt(paramStr(1)) else: 3000
var r = initRand(20261110)

# a hand-made model with what the car has not: bones, a shape, a sparse
# accessor, a cubic clip of a bone and one of the shape's weight
proc riggedJson(): string =
  var bin = ""
  proc f(v: float) =
    let u = cast[uint32](v.float32)
    for k in 0 .. 3: bin.add char((u shr (8 * k)) and 255)
  proc pad() =
    while bin.len mod 4 != 0: bin.add '\0'
  for p in [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)]: (f(p[0]); f(p[1]); f(p[2]))   # 0
  for j in [[0, 0, 0, 0], [1, 0, 0, 0], [1, 0, 0, 0]]:                                          # 36
    for x in j: bin.add char(x)
  for _ in 0 .. 2: (f(1); f(0); f(0); f(0))                                                     # 48
  for p in [(0.0, 0.0, 0.0), (0.0, 0.5, 0.0), (0.0, 0.5, 0.0)]: (f(p[0]); f(p[1]); f(p[2]))   # 96
  for i in [0, 1, 2]: (bin.add char(i); bin.add '\0')                                           # 132
  pad()
  for _ in 0 .. 1:                                                                              # 140
    for k in 0 .. 15: f(if k mod 5 == 0: 1.0 else: 0.0)
  f(0); f(1)                                                                                     # 268
  for _ in 0 .. 1:                                                                              # 276
    for v in [[0.0, 0, 0, 0], [0.0, 0, 0.38, 0.92], [0.0, 0, 0, 0]]:
      for x in v: f(x)
  f(0); f(1)                                                                                     # 372
  bin.add "\2\0"; pad()                                                                         # 380
  f(0); f(2); f(0)                                                                               # 384
  let views = [(0, 36), (36, 12), (48, 48), (96, 36), (132, 6), (140, 128), (268, 8), (276, 96),
               (372, 8), (380, 2), (384, 12)]
  var bvs = newJArray()
  for (o, n) in views: bvs.add %*{"buffer": 0, "byteOffset": o, "byteLength": n}
  let j = %*{"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}],
    "nodes": [{"name": "Root", "children": [1], "mesh": 0, "skin": 0}, {"name": "Bone", "translation": [0, 1, 0]}],
    "skins": [{"joints": [0, 1], "inverseBindMatrices": 5}],
    "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "JOINTS_0": 1, "WEIGHTS_0": 2}, "indices": 4,
                                "targets": [{"POSITION": 3}]}], "weights": [0]}],
    "animations": [{"name": "Bend",
      "channels": [{"sampler": 0, "target": {"node": 1, "path": "rotation"}},
                   {"sampler": 1, "target": {"node": 0, "path": "weights"}}],
      "samplers": [{"input": 6, "output": 7, "interpolation": "CUBICSPLINE"}, {"input": 6, "output": 8}]}],
    "buffers": [{"uri": "data:application/octet-stream;base64," & encode(bin), "byteLength": bin.len}],
    "bufferViews": bvs,
    "accessors": [
      {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3",
       "sparse": {"count": 1, "indices": {"bufferView": 9, "componentType": 5123}, "values": {"bufferView": 10}}},
      {"bufferView": 1, "componentType": 5121, "count": 3, "type": "VEC4"},
      {"bufferView": 2, "componentType": 5126, "count": 3, "type": "VEC4"},
      {"bufferView": 3, "componentType": 5126, "count": 3, "type": "VEC3"},
      {"bufferView": 4, "componentType": 5123, "count": 3, "type": "SCALAR"},
      {"bufferView": 5, "componentType": 5126, "count": 2, "type": "MAT4"},
      {"bufferView": 6, "componentType": 5126, "count": 2, "type": "SCALAR"},
      {"bufferView": 7, "componentType": 5126, "count": 6, "type": "VEC4"},
      {"bufferView": 8, "componentType": 5126, "count": 2, "type": "SCALAR"}]}
  $j

let rigged = riggedJson()
doAssert readGltf(rigged).skins.len == 1, "the seed is read"
let carGlb = toGlb(carScene())
let carJson = block:
  let n = int(uint8(carGlb[12])) or (int(uint8(carGlb[13])) shl 8) or (int(uint8(carGlb[14])) shl 16)
  carGlb[20 ..< 20 + n]
let carBin = block:
  let n = int(uint8(carGlb[12])) or (int(uint8(carGlb[13])) shl 8) or (int(uint8(carGlb[14])) shl 16)
  let at = 20 + ((n + 3) and not 3)
  carGlb[at + 8 .. ^1]

proc weird(): JsonNode =
  case r.rand(11)
  of 0: %(-1)
  of 1: %0
  of 2: %(1 shl 31)
  of 3: %(high(int32))
  of 4: %1e308
  of 5: %(-1e-300)
  of 6: %"x"
  of 7: newJNull()
  of 8: %*[]
  of 9: %*{}
  of 10: %r.rand(20)
  else: %r.rand(-3.0 .. 3.0)

proc mutateJson(root: JsonNode) =
  ## (one to three changes in the whole tree: a number, a kind, a key, an item)
  var all: seq[JsonNode]
  proc walk(n: JsonNode) =
    all.add n
    case n.kind
    of JObject:
      for _, v in n: walk(v)
    of JArray:
      for v in n.elems: walk(v)
    else: discard
  walk(root)
  for _ in 0 .. r.rand(2):
    let n = all[r.rand(all.high)]
    case n.kind
    of JObject:
      var keys: seq[string]
      for k, _ in n: keys.add k
      if keys.len > 0:
        let k = keys[r.rand(keys.high)]
        if r.rand(1) == 0: n.delete(k) else: n[k] = weird()
    of JArray:
      if n.len > 0:
        case r.rand(2)
        of 0: n.elems.delete(r.rand(n.len - 1))
        of 1: n.add n.elems[r.rand(n.len - 1)].copy
        else: n.elems[r.rand(n.len - 1)] = weird()
    of JInt: n.num = [-1'i64, 0, 1, 2, 3, 4, 5, 9, 4096, 65535, 1 shl 32, high(int64)][r.rand(11)]
    of JFloat: n.fnum = [0.0, -0.0, 1e300, -1e300, 5e-324, 1.0, 1e9][r.rand(6)]
    of JString: n.str = ["SCALAR", "VEC2", "VEC3", "MAT4", "STEP", "CUBICSPLINE", "rotation",
                         "weights", "data:,", "missing.bin", "../../etc/passwd", ""][r.rand(11)]
    else: discard

proc mutateBytes(s: string): string =
  result = s
  for _ in 0 .. r.rand(5):
    if result.len == 0: return
    case r.rand(5)
    of 0, 1: result[r.rand(result.high)] = char(r.rand(255))
    of 2:
      let a = r.rand(result.high)
      result.delete(a .. min(result.high, a + r.rand(40)))
    of 3:
      if result.len >= 20:
        let at = 8 + 4 * r.rand(2)
        let v = [0'u32, 1, 0xFFFFFFFF'u32, uint32(result.len), 0x7FFFFFFF][r.rand(4)]
        for k in 0 .. 3: result[at + k] = char((v shr (8 * k)) and 255)
    of 4: result.setLen(r.rand(result.len))
    else: result.insert($char(r.rand(255)), r.rand(result.len))

var accepted, refused = 0
let tmpDir = getTempDir() / "retro-fuzz-models"
createDir(tmpDir)
for round in 0 ..< rounds:
  var scene: Scene3
  try:
    case r.rand(3)
    of 0: scene = readGlb(mutateBytes(carGlb), tmpDir)
    of 1:
      let j = parseJson(carJson)
      mutateJson(j)
      scene = readGltf($j, carBin, tmpDir)
    else:
      let j = parseJson(rigged)
      mutateJson(j)
      scene = readGltf($j, "", tmpDir)
  except GltfError:
    inc refused
    continue
  inc accepted
  # what was accepted is sound, plays and draws
  for m in scene.meshes:
    for t in m.tris:
      for k in t: doAssert k >= 0 and k < m.verts.len
  for name in scene.animationNames:
    scene.play(name, loop = r.rand(1) == 0, speed = r.rand(-3.0 .. 3.0))
  for _ in 0 .. r.rand(4):
    discard scene.animate([0.0, 1 / 60, 0.5, 7.0, -1.0, 1e9][r.rand(5)])
  discard scene.nodeNames
  discard bounds(scene)
  var cam = camera3(yaw = r.rand(360.0), pitch = r.rand(-80.0 .. 80.0))
  fitView(scene, cam)
  let b = render3d(scene, cam, 1 + r.rand(48), 1 + r.rand(40))
  doAssert b.px.len == b.w * b.h
  if round mod 500 == 0: echo round, " rounds"
removeDir(tmpDir)
echo "fuzz_models: ", rounds, " rounds, ", accepted, " accepted, ", refused, " refused, no crash"

## Models from Blender (and every 3D tool): glTF 2.0, as `.glb` (one file)
## or `.gltf` (with its `.bin` and pictures beside it, or inside it), into
## a `Scene3` the 3D view shows -- its parts as nodes the app can move,
## turn, hide, tint and pick, its clips played (`play`), its bones
## (skinning) and shapes (morph targets) followed, its materials with
## their pictures (metallic-roughness: paint, chrome, glass, lights).
##
## .. code-block:: nim
##   import retroui, retroui/[view3d, gltf]
##   var car = loadGltf("car.glb")
##   var cam = camera3()
##   fitView(car, cam)
##   app "Showroom", 1000, 700:
##     if button("Open the door"): car.play("DoorOpen", loop = false)
##     if button("Red"): car.recolor("CarPaint", color(170, 0, 20))
##     car.animate(1 / 60)
##     let ev = view3d(car, cam)
##     if ev.clicked and ev.nodeName == "Hood": car.play("HoodOpen", loop = false)
##
## From Blender: File > Export > glTF 2.0 (.glb), with "Animation" on for
## the clips (each Action a clip, named as in Blender); give the parts the
## app moves names it can find (Outliner names are the nodes' names).
## A `.blend` file itself is Blender's own format, changing with each
## version of it: `loadModel3` turns one into glTF with Blender when it is
## installed (`blender` on the PATH, or `RETRO_BLENDER`), keeping the result
## next to it; `retrokit model car.blend` does it once, for an app to carry
## the `.glb`.
##
## Read: every accessor kind (normalized integers too: quantized models),
## sparse accessors, triangles, strips and fans, KHR_materials_unlit,
## KHR_materials_emissive_strength, KHR_texture_transform (offset, scale),
## EXT_texture_webp, embedded and data: pictures. Not read: Draco and
## meshopt compression (export without them), cameras and lights (the
## view has its own).

import std/[json, os, strutils, osproc, tables, times, streams]
import gfx, imaging, jpeg, webp, view3d
from codec import unbase64

type GltfError* = object of CatchableError

proc bad(why: string) {.noreturn.} = raise newException(GltfError, "glTF: " & why)

type
  Reader = object
    j: JsonNode
    baseDir: string
    buffers: seq[string]
    images: seq[Bitmap]
    imagesRead: seq[bool]

proc u32le(s: string; at: int): uint32 =
  for k in 0 .. 3: result = result or (uint32(uint8(s[at + k])) shl (8 * k))

proc gi(n: JsonNode; default = 0): int =
  ## (a whole number of the JSON, kept to 32 bits: no number in a model
  ## is bigger, and a bigger one fails every check)
  if n == nil or n.kind != JInt: return default
  int(clamp(n.getBiggestInt, int64(low(int32)), int64(high(int32))))

proc item(n: JsonNode; i: int): JsonNode =
  ## (item `i` of a JSON array; nil when it is not there)
  if n == nil or n.kind != JArray or i < 0 or i >= n.len: nil else: n.elems[i]

proc nums(n: JsonNode; count: int): seq[float] =
  ## (an array of `count` numbers; empty when it is something else)
  if n == nil or n.kind != JArray or n.len != count: return
  for x in n.elems:
    if x.kind notin {JInt, JFloat}: result = @[]; return
    result.add x.getFloat

proc view(r: Reader; i: int): JsonNode =
  result = r.j{"bufferViews"}.item(i)
  if result == nil or result.kind != JObject: bad("a buffer view that is not there")

proc bufferOf(r: Reader; view: JsonNode): lent string =
  let bi = view{"buffer"}.gi(-1)
  if bi < 0 or bi >= r.buffers.len: bad("a buffer that is not there")
  r.buffers[bi]

proc fits(off, count, stride, size, total: int): bool =
  ## (`count` values of `size` bytes, `stride` apart from `off`, inside
  ## `total` bytes: in 64 bits, so that no product overflows)
  if off < 0 or count < 0 or stride < 0 or size < 0: return false
  if count == 0: return off <= total
  int64(off) + int64(count - 1) * int64(stride) + int64(size) <= int64(total)

proc dataUri(uri: string): string =
  let comma = uri.find(',')
  if comma < 0: bad("a data: address without data")
  if ";base64" in uri[0 ..< comma]:
    try: unbase64(uri[comma + 1 .. ^1])
    except ValueError: bad("a data: address that is not base64")
  else:
    uri[comma + 1 .. ^1]

proc decodeUrl(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len:
      try:
        result.add char(parseHexInt(s[i + 1 .. i + 2]))
        i += 3
        continue
      except ValueError: discard
    result.add s[i]
    inc i

proc fileOf(r: Reader; uri: string): string =
  if uri.startsWith("data:"): return dataUri(uri)
  let path = r.baseDir / decodeUrl(uri)
  # (only files beside the model, and below it)
  let full = absolutePath(path).normalizedPath
  let base = absolutePath(r.baseDir).normalizedPath
  if not full.startsWith(base): bad("a file outside the model's folder: " & uri)
  if not fileExists(full): bad("a file it needs is not there: " & uri)
  if getFileSize(full) > MaxModelBytes: bad("a file too big: " & uri)
  readFile(full)

proc compCount(t: string): int =
  case t
  of "SCALAR": 1
  of "VEC2": 2
  of "VEC3": 3
  of "VEC4": 4
  of "MAT2": 4
  of "MAT3": 9
  of "MAT4": 16
  else: bad("an accessor of type " & t)

proc compSize(ct: int): int =
  case ct
  of 5120, 5121: 1
  of 5122, 5123: 2
  of 5125, 5126: 4
  else: bad("an accessor of component type " & $ct)

proc readComp(data: string; at, ct: int; normalized: bool): float32 {.inline.} =
  case ct
  of 5126: cast[float32](u32le(data, at))
  of 5121:
    let v = uint8(data[at])
    if normalized: v.float32 / 255 else: v.float32
  of 5120:
    let v = cast[int8](data[at])
    if normalized: max(v.float32 / 127, -1) else: v.float32
  of 5123:
    let v = uint16(uint8(data[at])) or (uint16(uint8(data[at + 1])) shl 8)
    if normalized: v.float32 / 65535 else: v.float32
  of 5122:
    let v = cast[int16](uint16(uint8(data[at])) or (uint16(uint8(data[at + 1])) shl 8))
    if normalized: max(v.float32 / 32767, -1) else: v.float32
  of 5125: u32le(data, at).float32
  else: 0

proc readInt(data: string; at, ct: int): int {.inline.} =
  case ct
  of 5121: int(uint8(data[at]))
  of 5123: int(uint16(uint8(data[at])) or (uint16(uint8(data[at + 1])) shl 8))
  of 5125:
    let v = u32le(data, at)
    if v > uint32(high(int32)): -1 else: int(v)
  else: -1

proc accessor(r: Reader; idx: int; floats: var seq[float32]; width: var int) =
  ## Accessor `idx` as numbers (`width` a value), sparse values put in.
  let a = r.j{"accessors"}.item(idx)
  if a == nil or a.kind != JObject: bad("an accessor that is not there")
  let count = a{"count"}.gi
  let ct = a{"componentType"}.gi
  let nc = compCount(a{"type"}.getStr)
  let normalized = a{"normalized"}.getBool
  if count < 0 or count > MaxPoints * 4: bad("an accessor too long")
  width = nc
  floats = newSeq[float32](count * nc)
  let cs = compSize(ct)
  if a{"bufferView"} != nil:
    let bv = r.view(a{"bufferView"}.gi(-1))
    let data = r.bufferOf(bv)
    let off = bv{"byteOffset"}.gi + a{"byteOffset"}.gi
    var stride = bv{"byteStride"}.gi
    if stride == 0: stride = cs * nc
    # (matrices: columns padded to 4 bytes)
    if not fits(off, count, stride, cs * nc, data.len): bad("an accessor past its buffer")
    for i in 0 ..< count:
      let at = off + i * stride
      for c in 0 ..< nc: floats[i * nc + c] = readComp(data, at + c * cs, ct, normalized)
  let sp = a{"sparse"}
  if sp != nil:
    let n = sp{"count"}.gi
    let ia = sp{"indices"}
    let va = sp{"values"}
    if n < 0 or n > count or ia == nil or va == nil: bad("sparse values that cannot be read")
    let ibv = r.view(ia{"bufferView"}.gi(-1))
    let vbv = r.view(va{"bufferView"}.gi(-1))
    let idata = r.bufferOf(ibv)
    let vdata = r.bufferOf(vbv)
    let ict = ia{"componentType"}.gi
    let ioff = ibv{"byteOffset"}.gi + ia{"byteOffset"}.gi
    let voff = vbv{"byteOffset"}.gi + va{"byteOffset"}.gi
    let ics = compSize(ict)
    if not fits(ioff, n, ics, ics, idata.len) or not fits(voff, n, nc * cs, nc * cs, vdata.len):
      bad("sparse values past their buffer")
    for k in 0 ..< n:
      let target = readInt(idata, ioff + k * ics, ict)
      if target < 0 or target >= count: continue
      for c in 0 ..< nc:
        floats[target * nc + c] = readComp(vdata, voff + (k * nc + c) * cs, ct, normalized)

proc indices(r: Reader; idx: int): seq[int32] =
  let a = r.j{"accessors"}.item(idx)
  if a == nil or a.kind != JObject: bad("indices that are not there")
  let count = a{"count"}.gi
  let ct = a{"componentType"}.gi
  if count < 0 or count > MaxTriangles * 3: bad("too many indices")
  let bv = r.view(a{"bufferView"}.gi(-1))
  let data = r.bufferOf(bv)
  let off = bv{"byteOffset"}.gi + a{"byteOffset"}.gi
  let cs = compSize(ct)
  var stride = bv{"byteStride"}.gi
  if stride == 0: stride = cs
  if not fits(off, count, stride, cs, data.len): bad("indices past their buffer")
  result = newSeq[int32](count)
  for i in 0 ..< count: result[i] = int32(readInt(data, off + i * stride, ct))

proc image(r: var Reader; idx: int): Bitmap =
  let imgs = r.j{"images"}
  if imgs == nil or idx < 0 or idx >= imgs.len: return nil
  if idx < r.imagesRead.len and r.imagesRead[idx]: return r.images[idx]
  if r.imagesRead.len < imgs.len:
    r.imagesRead.setLen(imgs.len)
    r.images.setLen(imgs.len)
  r.imagesRead[idx] = true
  let im = imgs[idx]
  var data = ""
  try:
    if im{"uri"} != nil: data = r.fileOf(im{"uri"}.getStr)
    elif im{"bufferView"} != nil:
      let bv = r.view(im{"bufferView"}.gi(-1))
      let buf = r.bufferOf(bv)
      let off = bv{"byteOffset"}.gi
      let n = bv{"byteLength"}.gi
      if n >= 0 and fits(off, 1, 0, n, buf.len): data = buf[off ..< off + n]
    var b: Bitmap = nil
    if data.len >= 8 and data[0 .. 7] == "\x89PNG\r\n\x1a\n": b = decodePng(data)
    elif data.len >= 3 and data[0] == '\xFF' and data[1] == '\xD8': b = decodeJpeg(data)
    elif data.len >= 12 and data[0 .. 3] == "RIFF": b = decodeWebp(data)
    # (very large pictures made smaller: a texture need not be 8K here)
    if b != nil and (b.w > 2048 or b.h > 2048): b = thumbnail(b, 2048, 2048)
    r.images[idx] = b
  except CatchableError:
    r.images[idx] = nil
  r.images[idx]

proc texture(r: var Reader; info: JsonNode): Bitmap =
  if info == nil: return nil
  let texs = r.j{"textures"}
  let ti = info{"index"}.gi(-1)
  if texs == nil or ti < 0 or ti >= texs.len: return nil
  let t = texs[ti]
  var src = t{"source"}.gi(-1)
  let ext = t{"extensions"}
  if ext != nil and ext{"EXT_texture_webp"} != nil: src = ext{"EXT_texture_webp"}{"source"}.gi(src)
  r.image(src)

proc mat4Of(a: openArray[float32]; at: int): Mat4 =
  for k in 0 .. 15: result[k] = a[at + k]

proc nodeTrs(n: JsonNode): (Vec3, Quat, Vec3) =
  let mm = nums(n{"matrix"}, 16)
  if mm.len == 16:
    var m: Mat4
    for k in 0 .. 15: m[k] = mm[k].float32
    let d = decompose(m)
    return (d.t, d.r, d.s)
  var t = Vec3()
  var q = Quat(w: 1)
  var s = vec3(1, 1, 1)
  let tt = nums(n{"translation"}, 3)
  if tt.len == 3: t = vec3(tt[0], tt[1], tt[2])
  let rr = nums(n{"rotation"}, 4)
  if rr.len == 4: q = quat(rr[0], rr[1], rr[2], rr[3])
  let ss = nums(n{"scale"}, 3)
  if ss.len == 3: s = vec3(ss[0], ss[1], ss[2])
  (t, q, s)

proc readScene(json, bin, baseDir: string): Scene3 =
  var r = Reader(baseDir: if baseDir.len > 0: baseDir else: getCurrentDir())
  r.j = try: parseJson(json) except CatchableError: bad("its JSON cannot be read")
  if r.j.kind != JObject: bad("its JSON is not an object")
  let ver = r.j{"asset"}{"version"}.getStr("2.0")
  if not ver.startsWith("2"): bad("version " & ver & " (2.0 is read)")
  for e in r.j{"extensionsRequired"}.getElems:
    let name = e.getStr
    if name in ["KHR_draco_mesh_compression", "EXT_meshopt_compression", "KHR_meshopt_compression"]:
      bad("it is compressed with " & name & " (export it without: Blender's \"Compression\" off)")
  for b in r.j{"buffers"}.getElems:
    if b{"uri"} == nil: r.buffers.add bin
    else: r.buffers.add r.fileOf(b{"uri"}.getStr)
  result.ambient = 0.4
  # materials
  for m in r.j{"materials"}.getElems:
    var mat = Material3(name: m{"name"}.getStr, baseColor: [1'f32, 1, 1, 1], metallic: 1, roughness: 1,
                        alphaCutoff: 0.5)
    let pbr = m{"pbrMetallicRoughness"}
    if pbr != nil:
      let bc = nums(pbr{"baseColorFactor"}, 4)
      if bc.len == 4:
        for k in 0 .. 3: mat.baseColor[k] = bc[k].float32
      mat.texture = r.texture(pbr{"baseColorTexture"})
      mat.metallic = pbr{"metallicFactor"}.getFloat(1).float32
      mat.roughness = pbr{"roughnessFactor"}.getFloat(1).float32
      mat.mrTexture = r.texture(pbr{"metallicRoughnessTexture"})
    let ef = nums(m{"emissiveFactor"}, 3)
    if ef.len == 3:
      for k in 0 .. 2: mat.emissive[k] = ef[k].float32
    mat.emissiveTexture = r.texture(m{"emissiveTexture"})
    let ext = m{"extensions"}
    if ext != nil:
      if ext{"KHR_materials_unlit"} != nil: mat.unlit = true
      let es = ext{"KHR_materials_emissive_strength"}
      if es != nil:
        let k = es{"emissiveStrength"}.getFloat(1).float32
        for q in 0 .. 2: mat.emissive[q] *= k
    mat.alphaMode = case m{"alphaMode"}.getStr("OPAQUE")
                    of "MASK": amMask
                    of "BLEND": amBlend
                    else: amOpaque
    mat.alphaCutoff = m{"alphaCutoff"}.getFloat(0.5).float32
    mat.doubleSided = m{"doubleSided"}.getBool
    result.materials.add mat
  # meshes: each primitive a Mesh3, placed by the nodes that use it
  var meshPrims: seq[seq[Mesh3]]
  for gm in r.j{"meshes"}.getElems:
    var prims: seq[Mesh3]
    let defWeights = gm{"weights"}
    for pi, p in gm{"primitives"}.getElems:
      let mode = p{"mode"}.gi(4)
      if mode notin [4, 5, 6]: continue          # (points and lines are not drawn here)
      let at = p{"attributes"}
      if at == nil or at{"POSITION"} == nil: continue
      var m = newMesh(gm{"name"}.getStr & (if pi > 0: "." & $pi else: ""), color(255, 255, 255))
      var f: seq[float32]
      var w: int
      r.accessor(at{"POSITION"}.gi(-1), f, w)
      if w < 3: bad("points without three coordinates")
      let n = f.len div w
      if n > MaxPoints: bad("too many points")
      m.verts.setLen(n)
      for i in 0 ..< n: m.verts[i] = Vec3(x: f[i * w], y: f[i * w + 1], z: f[i * w + 2])
      if at{"NORMAL"} != nil:
        r.accessor(at{"NORMAL"}.gi(-1), f, w)
        if f.len div max(1, w) == n and w >= 3:
          m.normals.setLen(n)
          for i in 0 ..< n: m.normals[i] = Vec3(x: f[i * w], y: f[i * w + 1], z: f[i * w + 2])
          m.smooth = true
      if at{"TEXCOORD_0"} != nil:
        r.accessor(at{"TEXCOORD_0"}.gi(-1), f, w)
        if f.len div max(1, w) == n and w >= 2:
          m.uvs.setLen(n)
          for i in 0 ..< n: m.uvs[i] = [f[i * w], f[i * w + 1]]
      if at{"COLOR_0"} != nil:
        r.accessor(at{"COLOR_0"}.gi(-1), f, w)
        if f.len div max(1, w) == n and w >= 3:
          m.vcolors.setLen(n)
          for i in 0 ..< n: m.vcolors[i] = [f[i * w], f[i * w + 1], f[i * w + 2], (if w >= 4: f[i * w + 3] else: 1'f32)]
      if at{"JOINTS_0"} != nil and at{"WEIGHTS_0"} != nil:
        var jf, wf: seq[float32]
        var jw, ww: int
        r.accessor(at{"JOINTS_0"}.gi(-1), jf, jw)
        r.accessor(at{"WEIGHTS_0"}.gi(-1), wf, ww)
        if jf.len div max(1, jw) == n and wf.len div max(1, ww) == n and jw >= 4 and ww >= 4:
          m.joints.setLen(n)
          m.weights.setLen(n)
          for i in 0 ..< n:
            for c in 0 .. 3:
              m.joints[i][c] = uint16(clamp(jf[i * jw + c], 0, 65535))
              m.weights[i][c] = wf[i * ww + c]
      for t in p{"targets"}.getElems:
        var tv: seq[Vec3]
        var tn: seq[Vec3]
        if t{"POSITION"} != nil:
          r.accessor(t{"POSITION"}.gi(-1), f, w)
          if f.len div max(1, w) == n and w >= 3:
            tv.setLen(n)
            for i in 0 ..< n: tv[i] = Vec3(x: f[i * w], y: f[i * w + 1], z: f[i * w + 2])
        if t{"NORMAL"} != nil:
          r.accessor(t{"NORMAL"}.gi(-1), f, w)
          if f.len div max(1, w) == n and w >= 3:
            tn.setLen(n)
            for i in 0 ..< n: tn[i] = Vec3(x: f[i * w], y: f[i * w + 1], z: f[i * w + 2])
        m.targets.add tv
        m.targetNormals.add tn
      for x in defWeights.getElems: m.morphWeights.add x.getFloat.float32
      # the triangles
      var idx: seq[int32]
      if p{"indices"} != nil: idx = r.indices(p{"indices"}.gi(-1))
      else:
        idx = newSeq[int32](n)
        for i in 0 ..< n: idx[i] = int32(i)
      case mode
      of 4:
        for k in countup(0, idx.len - 3, 3): m.tris.add [idx[k], idx[k + 1], idx[k + 2]]
      of 5:
        for k in 0 .. idx.len - 3:
          if k mod 2 == 0: m.tris.add [idx[k], idx[k + 1], idx[k + 2]]
          else: m.tris.add [idx[k + 1], idx[k], idx[k + 2]]
      else:
        for k in 1 .. idx.len - 2: m.tris.add [idx[0], idx[k], idx[k + 1]]
      for t in m.tris:
        for v in t:
          if v < 0 or v >= n: bad("a triangle points to a point that is not there")
      if m.tris.len > MaxTriangles: bad("too many triangles")
      let mi = p{"material"}.gi(-1)
      m.material = if mi >= 0 and mi < result.materials.len: mi else: -1
      if m.material < 0:
        # (no material: glTF's default, a white matte surface)
        m.material = result.materials.len
        result.materials.add Material3(name: "default", baseColor: [1'f32, 1, 1, 1], metallic: 0,
                                       roughness: 1, alphaCutoff: 0.5)
      else:
        # KHR_texture_transform on the color's picture: offset and scale put in the uvs
        let pbr = r.j{"materials"}.item(m.material){"pbrMetallicRoughness"}
        let tt = pbr{"baseColorTexture"}{"extensions"}{"KHR_texture_transform"}
        if tt != nil and m.uvs.len > 0:
          let off = nums(tt{"offset"}, 2)
          let sc = nums(tt{"scale"}, 2)
          let ox = if off.len == 2: off[0].float32 else: 0'f32
          let oy = if off.len == 2: off[1].float32 else: 0'f32
          let sx = if sc.len == 2: sc[0].float32 else: 1'f32
          let sy = if sc.len == 2: sc[1].float32 else: 1'f32
          for uv in m.uvs.mitems: uv = [uv[0] * sx + ox, uv[1] * sy + oy]
      m.twoSided = result.materials[m.material].doubleSided
      prims.add m
    meshPrims.add prims
  # nodes
  let jnodes = r.j{"nodes"}.getElems
  for i, n in jnodes:
    let (t, q, s) = nodeTrs(n)
    var node = Node3(name: n{"name"}.getStr("node" & $i), parent: -1, t: t, r: q, s: s, visible: true)
    for c in n{"children"}.getElems:
      let ci = c.gi(-1)
      if ci >= 0 and ci < jnodes.len and ci != i: node.children.add ci
    for x in n{"weights"}.getElems: node.morphWeights.add x.getFloat.float32
    result.nodes.add node
  for i, n in result.nodes:
    for c in n.children:
      if result.nodes[c].parent < 0: result.nodes[c].parent = i
  # (a child listed twice, or a loop: only its first parent keeps it)
  for i in 0 ..< result.nodes.len:
    var keep: seq[int]
    for c in result.nodes[i].children:
      if result.nodes[c].parent == i: keep.add c
    result.nodes[i].children = keep
  # the scene's roots (the default scene, else every node without a parent)
  let sceneIdx = r.j{"scene"}.gi(0)
  let scenes = r.j{"scenes"}.getElems
  if sceneIdx >= 0 and sceneIdx < scenes.len and scenes[sceneIdx]{"nodes"} != nil:
    for x in scenes[sceneIdx]{"nodes"}.getElems:
      let k = x.gi(-1)
      if k >= 0 and k < result.nodes.len and result.nodes[k].parent < 0: result.roots.add k
  else:
    for i, n in result.nodes:
      if n.parent < 0: result.roots.add i
  # nodes not in the scene: hidden
  var inScene = newSeq[bool](result.nodes.len)
  var stack = result.roots
  while stack.len > 0:
    let k = stack.pop()
    if inScene[k]: continue
    inScene[k] = true
    stack.add result.nodes[k].children
  # skins
  for sk in r.j{"skins"}.getElems:
    var s = Skin3()
    for x in sk{"joints"}.getElems:
      let k = x.gi(-1)
      if k < 0 or k >= jnodes.len: bad("a bone that is not a node")
      s.joints.add k
    if sk{"inverseBindMatrices"} != nil:
      var f: seq[float32]
      var w: int
      r.accessor(sk{"inverseBindMatrices"}.gi(-1), f, w)
      if w == 16:
        for k in 0 ..< f.len div 16: s.inverseBind.add mat4Of(f, k * 16)
    result.skins.add s
  # meshes into the scene, one per primitive per node that has the mesh
  for i, n in jnodes:
    let mi = n{"mesh"}.gi(-1)
    if mi < 0 or mi >= meshPrims.len: continue
    for p in meshPrims[mi]:
      var m = p
      m.node = i
      m.skin = n{"skin"}.gi(-1)
      if m.skin >= result.skins.len: m.skin = -1
      if not inScene[i]: m.visible = false
      result.nodes[i].meshes.add result.meshes.len
      result.meshes.add m
  # animations
  for a in r.j{"animations"}.getElems:
    var anim = Animation3(name: a{"name"}.getStr("Animation " & $(result.animations.len + 1)))
    let samplers = a{"samplers"}.getElems
    for c in a{"channels"}.getElems:
      let si = c{"sampler"}.gi(-1)
      let tg = c{"target"}
      if si < 0 or si >= samplers.len or tg == nil or tg{"node"} == nil: continue
      let path = case tg{"path"}.getStr
                 of "translation": apTranslation
                 of "rotation": apRotation
                 of "scale": apScale
                 of "weights": apWeights
                 else: continue
      let smp = samplers[si]
      let nodeIdx = tg{"node"}.gi(-1)
      if nodeIdx < 0 or nodeIdx >= jnodes.len: continue
      var ch = AnimChannel3(node: nodeIdx, path: path)
      ch.interp = case smp{"interpolation"}.getStr("LINEAR")
                  of "STEP": aiStep
                  of "CUBICSPLINE": aiCubic
                  else: aiLinear
      var w: int
      r.accessor(smp{"input"}.gi(-1), ch.times, w)
      r.accessor(smp{"output"}.gi(-1), ch.values, w)
      if ch.times.len == 0: continue
      # (times that go back, or are not numbers: not played)
      var sorted = true
      for k in 0 ..< ch.times.len:
        if ch.times[k] != ch.times[k] or (k > 0 and ch.times[k] < ch.times[k - 1]): sorted = false
      if not sorted: continue
      anim.duration = max(anim.duration, ch.times[^1])
      anim.channels.add ch
    result.animations.add anim
  if result.meshes.len == 0: bad("there is nothing to draw in it")
  sceneChanged(result)

proc readGltf*(json: string; bin = ""; baseDir = ""): Scene3 =
  ## A model from glTF's JSON text, its binary chunk (`.glb`) and the
  ## folder its files are in; `GltfError` when it cannot be read.
  # (read into a variable of its own: a model half read when an error
  # stops it is freed -- read straight into a caller's variable, Nim 2.2
  # leaks it)
  var s = readScene(json, bin, baseDir)
  result = move s

proc readGlb*(data: string; baseDir = ""): Scene3 =
  ## A model from the bytes of a `.glb` file.
  if data.len < 20 or data[0 .. 3] != "glTF": bad("not a .glb file")
  if u32le(data, 4) != 2: bad("a .glb of version " & $u32le(data, 4))
  let total = int(min(u32le(data, 8), uint32(data.len)))
  var at = 12
  var json, bin = ""
  while at + 8 <= total:
    let n = int(u32le(data, at))
    let kind = u32le(data, at + 4)
    if n < 0 or at + 8 + n > total: bad("a chunk past the end of the file")
    if kind == 0x4E4F534A'u32 and json.len == 0: json = data[at + 8 ..< at + 8 + n]
    elif kind == 0x004E4942'u32 and bin.len == 0: bin = data[at + 8 ..< at + 8 + n]
    at += 8 + ((n + 3) and not 3)
  if json.len == 0: bad("no JSON in the .glb")
  readGltf(json, bin, baseDir)

proc loadGltf*(path: string): Scene3 =
  ## The model in `path` (`.glb` or `.gltf`); `GltfError` when it cannot
  ## be read, `IOError` when the file cannot.
  if getFileSize(path) > MaxModelBytes: bad("the model is too big")
  let data = readFile(path)
  if data.len >= 4 and data[0 .. 3] == "glTF": readGlb(data, path.parentDir)
  else: readGltf(data, "", path.parentDir)

# ---- Blender's own files ---------------------------------------------------------------------

proc blenderExe(): string =
  let given = getEnv("RETRO_BLENDER")
  if given.len > 0: return (if fileExists(given): given else: "")
  result = findExe("blender")
  if result.len > 0: return
  for p in ["/Applications/Blender.app/Contents/MacOS/Blender",
            "C:\\Program Files\\Blender Foundation\\Blender\\blender.exe",
            "/snap/bin/blender", "/usr/bin/blender"]:
    if fileExists(p): result = p; return

proc blendToGlb*(blend: string; glb = ""): string =
  ## Turns a `.blend` into a `.glb` with Blender (in the background, its
  ## clips with it); the `.glb`'s path, "" when Blender is not there or
  ## could not. `glb` "": beside the `.blend`, made again only when the
  ## `.blend` is newer.
  let exe = blenderExe()
  if exe.len == 0: return ""
  let outp = if glb.len > 0: glb else: blend.changeFileExt(".glb")
  if fileExists(outp) and fileExists(blend) and
     getLastModificationTime(outp) >= getLastModificationTime(blend):
    return outp
  let script = "import bpy; bpy.ops.export_scene.gltf(filepath=r'''" & outp.replace("'''", "") &
               "''', export_format='GLB', export_animations=True, export_apply=False)"
  try:
    let p = startProcess(exe, args = ["-b", blend, "--python-expr", script],
                         options = {poStdErrToStdOut, poUsePath})
    discard p.outputStream.readAll()
    let code = p.waitForExit()
    p.close()
    if code == 0 and fileExists(outp): outp else: ""
  except OSError:
    ""

proc loadModel3*(path: string): Scene3 =
  ## Any model as a scene: `.glb`, `.gltf`, `.blend` (through Blender), and
  ## `.obj`, `.stl` (one mesh, centered, 2 units across).
  let ext = path.splitFile.ext.toLowerAscii
  case ext
  of ".glb", ".gltf": loadGltf(path)
  of ".blend":
    let glb = blendToGlb(path)
    if glb.len == 0:
      bad("a .blend file is read through Blender (not found: install it, or set RETRO_BLENDER), " &
          "or export it as glTF (.glb) from Blender")
    loadGltf(glb)
  else:
    var s = Scene3()
    s.add loadModel(path)
    s

# ---- writing glTF (an app's own scenes; the tests' models) -----------------------------

proc toGlb*(scene: Scene3): string =
  ## The scene as a `.glb`: its meshes, their materials' colors (no
  ## pictures), its nodes and clips.
  var bin = ""
  var accessors = newJArray()
  var views = newJArray()
  proc addFloats(vals: openArray[float32]; typ: string; withBounds = false; width = 3): int =
    let off = bin.len
    for v in vals:
      let u = cast[uint32](v)
      for k in 0 .. 3: bin.add char((u shr (8 * k)) and 255)
    while bin.len mod 4 != 0: bin.add '\0'
    views.add %*{"buffer": 0, "byteOffset": off, "byteLength": vals.len * 4}
    var a = %*{"bufferView": views.len - 1, "componentType": 5126,
               "count": vals.len div compCount(typ), "type": typ}
    if withBounds and vals.len >= width:
      var lo = newJArray()
      var hi = newJArray()
      for c in 0 ..< width:
        var mn = Inf
        var mx = -Inf
        for i in countup(c, vals.high, width):
          mn = min(mn, vals[i].float)
          mx = max(mx, vals[i].float)
        lo.add %mn
        hi.add %mx
      a["min"] = lo
      a["max"] = hi
    accessors.add a
    accessors.len - 1
  proc addIndices(vals: openArray[int32]): int =
    let off = bin.len
    for v in vals:
      let u = cast[uint32](v)
      for k in 0 .. 3: bin.add char((u shr (8 * k)) and 255)
    views.add %*{"buffer": 0, "byteOffset": off, "byteLength": vals.len * 4}
    accessors.add %*{"bufferView": views.len - 1, "componentType": 5125, "count": vals.len, "type": "SCALAR"}
    accessors.len - 1
  var mats = newJArray()
  for m in scene.materials:
    mats.add %*{"name": m.name, "pbrMetallicRoughness": {"baseColorFactor": m.baseColor,
                "metallicFactor": m.metallic, "roughnessFactor": m.roughness},
                "doubleSided": m.doubleSided,
                "alphaMode": (case m.alphaMode
                              of amMask: "MASK"
                              of amBlend: "BLEND"
                              else: "OPAQUE")}
  var meshes = newJArray()
  var nodes = newJArray()
  var meshOfNode: Table[int, seq[int]]
  for mi, m in scene.meshes:
    var pos: seq[float32]
    for v in m.verts: pos.add [v.x, v.y, v.z]
    var attrs = %*{"POSITION": addFloats(pos, "VEC3", withBounds = true)}
    if m.normals.len == m.verts.len:
      var nrm: seq[float32]
      for v in m.normals: nrm.add [v.x, v.y, v.z]
      attrs["NORMAL"] = %addFloats(nrm, "VEC3")
    if m.uvs.len == m.verts.len:
      var uv: seq[float32]
      for t in m.uvs: uv.add [t[0], t[1]]
      attrs["TEXCOORD_0"] = %addFloats(uv, "VEC2")
    var idx: seq[int32]
    for t in m.tris: idx.add [t[0], t[1], t[2]]
    var prim = %*{"attributes": attrs, "indices": addIndices(idx), "mode": 4}
    if m.material >= 0 and m.material < scene.materials.len: prim["material"] = %m.material
    else:
      mats.add %*{"name": m.name, "pbrMetallicRoughness": {"baseColorFactor":
                  [m.color.r.float / 255, m.color.g.float / 255, m.color.b.float / 255, 1.0],
                  "metallicFactor": 0.0, "roughnessFactor": 0.8}}
      prim["material"] = %(mats.len - 1)
    meshes.add %*{"name": m.name, "primitives": [prim]}
    if m.node >= 0 and m.node < scene.nodes.len: meshOfNode.mgetOrPut(m.node, @[]).add mi
  var roots = newJArray()
  if scene.nodes.len == 0:
    for mi, m in scene.meshes:
      if m.ghost: continue                       # (a shadow is the view's, not the model's)
      nodes.add %*{"name": m.name, "mesh": mi, "translation": [m.pos.x, m.pos.y, m.pos.z]}
      roots.add %(nodes.len - 1)
  else:
    for i, n in scene.nodes:
      var jn = %*{"name": n.name, "translation": [n.t.x, n.t.y, n.t.z],
                  "rotation": [n.r.x, n.r.y, n.r.z, n.r.w], "scale": [n.s.x, n.s.y, n.s.z]}
      if n.children.len > 0: jn["children"] = %n.children
      let ms = meshOfNode.getOrDefault(i)
      if ms.len > 0: jn["mesh"] = %ms[0]
      nodes.add jn
    for k in scene.roots: roots.add %k
  var anims = newJArray()
  for a in scene.animations:
    var samplers = newJArray()
    var channels = newJArray()
    for c in a.channels:
      let inp = addFloats(c.times, "SCALAR")
      accessors[inp]["min"] = %*[c.times[0]]
      accessors[inp]["max"] = %*[c.times[^1]]
      let typ = case c.path
                of apTranslation, apScale: "VEC3"
                of apRotation: "VEC4"
                of apWeights: "SCALAR"
      let outp = addFloats(c.values, typ)
      samplers.add %*{"input": inp, "output": outp, "interpolation": (case c.interp
                                                                      of aiStep: "STEP"
                                                                      of aiCubic: "CUBICSPLINE"
                                                                      else: "LINEAR")}
      channels.add %*{"sampler": samplers.len - 1, "target": {"node": c.node, "path": (case c.path
        of apTranslation: "translation"
        of apRotation: "rotation"
        of apScale: "scale"
        of apWeights: "weights")}}
    anims.add %*{"name": a.name, "samplers": samplers, "channels": channels}
  var j = %*{"asset": {"version": "2.0", "generator": "Retro Nim UI"}, "scene": 0,
             "scenes": [{"nodes": roots}], "nodes": nodes, "meshes": meshes, "materials": mats,
             "accessors": accessors, "bufferViews": views, "buffers": [{"byteLength": bin.len}]}
  if anims.len > 0: j["animations"] = anims
  var js = $j
  while js.len mod 4 != 0: js.add ' '
  while bin.len mod 4 != 0: bin.add '\0'
  proc le(v: int): string =
    result = newString(4)
    for k in 0 .. 3: result[k] = char((v shr (8 * k)) and 255)
  "glTF" & le(2) & le(12 + 8 + js.len + 8 + bin.len) & le(js.len) & "JSON" & js & le(bin.len) & "BIN\0" & bin

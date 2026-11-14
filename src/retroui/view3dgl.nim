# (included by view3d.nim) The 3D view drawn on the GPU: when frames are
# drawn with it (`drawnWithGpu`), the posed
# points (worked out as for the CPU) are sent each time the picture changes,
# and the GPU fills the triangles into a texture of the view's own -- the
# same light (metal, paint, the sky in it), pictures, see-through parts --
# which the frame then shows as any picture. Meshes without a material are
# shaded as the CPU shades them (a color a triangle too), outlines where
# they fold. A wireframe, a driver that cannot draw into a texture with a
# depth buffer, or a program that fails to compile: the CPU draws it.

import glapi

# (the GPU it draws with: the frames' (`retroui/gfx`), or in a web page a
# WebGL 2 context of its own whose picture is read back -- the page's frames
# are drawn by the CPU; `webgl3d`)
when defined(wasm):
  import webgl3d
  template v3Ready(): bool = webGl3dReady()
  template v3Gl(): ptr GlTable = webGl3d()
  template v3Epoch(): int = webGl3dEpoch()
  template v3Compile(vs, fs: string; attribs: openArray[string]): GLuint = webGl3dProgram(vs, fs, attribs)
  template v3Begin(): GLint = webGl3dBegin()
  template v3End(old: GLint) = webGl3dEnd(old)
  template v3Show(key: uint64; tex: GLuint; w, h: int) = webGl3dShow(key, w, h)
else:
  template v3Ready(): bool = drawnWithGpu() and gpuFiltersReady()
  template v3Gl(): ptr GlTable = gpuGl()
  template v3Epoch(): int = gpuEpoch()
  template v3Compile(vs, fs: string; attribs: openArray[string]): GLuint = gpuCompileProgram(vs, fs, attribs)
  template v3Begin(): GLint = gpuBeginOffscreen()
  template v3End(old: GLint) = gpuEndOffscreen(old)
  template v3Show(key: uint64; tex: GLuint; w, h: int) = gpuShowTexture(key, tex, w, h)

const
  Vert3D = """
attribute vec3 aPos;
attribute vec3 aNrm;
attribute vec2 aUV;
attribute vec4 aCol;
uniform vec4 uProj;
varying vec3 vPos;
varying vec3 vNrm;
varying vec2 vUV;
varying vec4 vCol;
void main() {
  vPos = aPos;
  vNrm = aNrm;
  vUV = aUV;
  vCol = aCol;
  gl_Position = vec4(aPos.x * uProj.x, -aPos.y * uProj.y, aPos.z * uProj.z + uProj.w, aPos.z);
}
"""
  Frag3D = """
varying vec3 vPos;
varying vec3 vNrm;
varying vec2 vUV;
varying vec4 vCol;
uniform float uMode;
uniform vec4 uBase;
uniform vec3 uEmis;
uniform vec3 uMR;
uniform vec3 uTex;
uniform sampler2D sBase;
uniform sampler2D sMR;
uniform sampler2D sEmis;
uniform vec2 uAlpha;
uniform float uTwoSided;
uniform vec3 uKey;
uniform vec3 uFill;
uniform vec3 uUp;
uniform vec2 uLight;
void main() {
  if (uMode > 1.5) {
    // a mesh without a material, shaded as the CPU shades it
    vec3 pn = normalize(vNrm);
    bool pf = !gl_FrontFacing;
    if (!pf && uTwoSided < 0.5) discard;
    float d = dot(pf ? pn : -pn, uKey);
    if (uTwoSided > 0.5) d = abs(d);
    float amb = (uLight.y - 0.3) / 0.6;
    float sh = amb + (1.0 - amb) * max(d, 0.0);
    vec4 pc = uBase * vCol;
    gl_FragColor = vec4(pc.b * sh, pc.g * sh, pc.r * sh, 1.0);
    return;
  }
  if (uMode > 0.5) {
    gl_FragColor = vec4(vCol.b, vCol.g, vCol.r, 1.0);
    return;
  }
  bool front = !gl_FrontFacing;
  if (!front && uTwoSided < 0.5) discard;
  vec4 base = uBase * vCol;
  if (uTex.x > 0.5) base *= texture2D(sBase, vUV).bgra;
  if (uAlpha.x > 0.5 && uAlpha.x < 1.5 && base.a < uAlpha.y) discard;
  float outA = uAlpha.x > 1.5 ? base.a : 1.0;
  if (uMR.z > 0.5) {
    gl_FragColor = vec4(base.b, base.g, base.r, outA);
    return;
  }
  float rough = uMR.y;
  float metal = uMR.x;
  if (uTex.y > 0.5) {
    vec4 t = texture2D(sMR, vUV).bgra;
    rough *= t.g;
    metal *= t.b;
  }
  rough = clamp(rough, 0.03, 1.0);
  metal = clamp(metal, 0.0, 1.0);
  vec3 n = normalize(vNrm);
  if (!front) n = -n;
  vec3 v = normalize(-vPos);
  float ndotv = max(dot(n, v), 0.0);
  float shin = exp2(1.0 + 11.0 * (1.0 - rough));
  float specNorm = (shin + 8.0) / 25.13;
  float fres = pow(1.0 - ndotv, 5.0);
  vec3 r = n * (2.0 * dot(n, v)) - v;
  float upness = clamp(dot(r, uUp), -1.0, 1.0);
  float sky = upness > 0.0 ? 0.55 + 0.45 * upness : 0.18 + 0.37 * (1.0 + upness);
  float hemi = 0.6 + 0.4 * dot(n, uUp);
  vec3 albedo = base.rgb * base.rgb;
  vec3 f0 = mix(vec3(0.04), albedo, metal);
  vec3 f = f0 + (1.0 - f0) * fres;
  vec3 c = albedo * (1.0 - metal) * uLight.y * hemi;
  float ndotl = dot(n, uKey);
  if (ndotl > 0.0) {
    vec3 h = normalize(uKey + v);
    c += ndotl * (albedo * (1.0 - metal) + specNorm * pow(max(dot(n, h), 0.0), shin) * f);
  }
  float ndotf = dot(n, uFill);
  if (ndotf > 0.0) c += 0.3 * ndotf * albedo * (1.0 - metal * 0.7);
  c += f * sky * (1.0 - rough) * (1.0 - rough) * (0.35 + 0.65 * metal);
  vec3 e = uEmis;
  if (uTex.z > 0.5) {
    vec3 t = texture2D(sEmis, vUV).bgr;
    e *= t * t;
  }
  c = sqrt(max((c + e) * uLight.x, 0.0));
  gl_FragColor = vec4(min(c.b, 1.0), min(c.g, 1.0), min(c.r, 1.0), outA);
}
"""

type
  GlMesh = object
    plain: bool                    # no material: shaded as the CPU's plain meshes
    perFace: bool                  # ... a color a triangle
    vbo, ibo: GLuint
    indexCount: int
    wide: bool                     # 32-bit indices
    trisAt: pointer                # (the triangles they were made from)
    trisLen: int
  GlView = ref object
    epoch: int
    failed: bool
    prog: GLuint
    fb, color, depth: GLuint
    w, h: int
    meshes: seq[GlMesh]
    lineVbo: GLuint
    textures: Table[pointer, tuple[tex: GLuint; stamp: uint64]]
    loc: Table[string, GLint]
    key: uint64

var
  glViews: Table[Id, GlView]
  uintIndices = -1                 # (the GPU takes 32-bit indices: -1 not asked yet)

proc glReady3D(): bool =
  if not v3Ready(): return false
  let gl = v3Gl()
  gl.genRenderbuffers != nil and gl.bindRenderbuffer != nil and gl.renderbufferStorage != nil and
    gl.framebufferRenderbuffer != nil and gl.drawElements != nil and gl.depthFunc != nil and
    gl.depthMask != nil and gl.uniform3f != nil and gl.uniform4f != nil and gl.uniform1f != nil

proc forget(v: GlView) =
  ## (what the view made on the GPU given back)
  if v.epoch != v3Epoch(): return            # (gone with the context)
  let gl = v3Gl()
  for m in v.meshes.mitems:
    if m.vbo != 0: gl.deleteBuffers(1, addr m.vbo)
    if m.ibo != 0: gl.deleteBuffers(1, addr m.ibo)
  v.meshes.setLen(0)
  for k, t in v.textures:
    var id = t.tex
    gl.deleteTextures(1, addr id)
  v.textures.clear()
  if v.lineVbo != 0: gl.deleteBuffers(1, addr v.lineVbo)
  if v.fb != 0: gl.deleteFramebuffers(1, addr v.fb)
  if v.color != 0: gl.deleteTextures(1, addr v.color)
  if v.depth != 0 and gl.deleteRenderbuffers != nil: gl.deleteRenderbuffers(1, addr v.depth)
  if v.prog != 0: gl.deleteProgram(v.prog)
  v.lineVbo = 0
  v.fb = 0
  v.color = 0
  v.depth = 0
  v.prog = 0

proc u(v: GlView; name: string): GLint =
  result = v.loc.getOrDefault(name, -2)
  if result == -2:
    result = v3Gl().getUniformLocation(v.prog, cstring(name))
    v.loc[name] = result

proc textureOf(v: GlView; b: Bitmap): GLuint =
  ## A material's picture on the GPU (sent again when it changed).
  if b == nil or b.w <= 0 or b.h <= 0 or b.px.len < b.w * b.h: return 0
  let gl = v3Gl()
  let k = cast[pointer](b)
  let have = v.textures.getOrDefault(k, (0'u32, 0'u64))
  if have.tex != 0 and have.stamp == stampOf(b): return have.tex
  var t = have.tex
  if t == 0: gl.genTextures(1, addr t)
  gl.bindTexture(GL_TEXTURE_2D, t)
  gl.pixelStorei(GL_UNPACK_ALIGNMENT, 4)
  gl.texImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA), GLsizei(b.w), GLsizei(b.h), 0, GL_RGBA, GL_UNSIGNED_BYTE,
                unsafeAddr b.px[0])
  # (repeated past its edges, as glTF's pictures are; read between pixels)
  let pow2 = (b.w and (b.w - 1)) == 0 and (b.h and (b.h - 1)) == 0
  let wrap = if pow2 or not gl.es: GLint(GL_REPEAT) else: GLint(GL_CLAMP_TO_EDGE)
  gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, wrap)
  gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, wrap)
  gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_LINEAR))
  gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GLint(GL_LINEAR))
  v.textures[k] = (t, stampOf(b))
  t

proc ensureTarget(v: GlView; w, h: int): bool =
  ## The texture drawn into and its depth buffer, `w` x `h`.
  let gl = v3Gl()
  if v.fb != 0 and v.w == w and v.h == h: return true
  if v.fb == 0: gl.genFramebuffers(1, addr v.fb)
  if v.color == 0: gl.genTextures(1, addr v.color)
  if v.depth == 0: gl.genRenderbuffers(1, addr v.depth)
  gl.bindTexture(GL_TEXTURE_2D, v.color)
  gl.texImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA), GLsizei(w), GLsizei(h), 0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
  gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_LINEAR))
  gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GLint(GL_LINEAR))
  gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GLint(GL_CLAMP_TO_EDGE))
  gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GLint(GL_CLAMP_TO_EDGE))
  gl.bindRenderbuffer(GL_RENDERBUFFER, v.depth)
  let ext = gl.getString(GL_EXTENSIONS)
  let deep = not gl.es or (ext != nil and "GL_OES_depth24" in $ext)
  gl.renderbufferStorage(GL_RENDERBUFFER, if deep: 0x81A6'u32 else: GL_DEPTH_COMPONENT16, GLsizei(w), GLsizei(h))
  gl.bindFramebuffer(GL_FRAMEBUFFER, v.fb)
  gl.framebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, v.color, 0)
  gl.framebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, v.depth)
  if gl.checkFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE: return false
  v.w = w
  v.h = h
  true

proc renderGpu(v: GlView; ctx: var RenderCtx; scene: Scene3; cam: Camera3; bg: Color): bool =
  ## The scene drawn by the GPU into the view's texture; false: it could not
  ## (the CPU draws it). `ctx.view` gets the posed points as the CPU's
  ## drawing does (for picking).
  let gl = v3Gl()
  if v.epoch != v3Epoch():
    v.meshes.setLen(0)
    v.textures.clear()
    v.fb = 0
    v.color = 0
    v.depth = 0
    v.prog = 0
    v.lineVbo = 0
    v.loc.clear()
    v.epoch = v3Epoch()
  if v.prog == 0:
    v.prog = v3Compile(Vert3D, Frag3D, ["aPos", "aNrm", "aUV", "aCol"])
    if v.prog == 0:
      v.failed = true
      return false
    v.loc.clear()
  if uintIndices < 0:
    let ext = gl.getString(GL_EXTENSIONS)
    uintIndices = if not gl.es or (ext != nil and "GL_OES_element_index_uint" in $ext): 1 else: 0
  let w = ctx.w
  let h = ctx.h
  let oldFb = v3Begin()
  defer: v3End(oldFb)
  if not v.ensureTarget(w, h):
    v.failed = true
    return false
  gl.bindFramebuffer(GL_FRAMEBUFFER, v.fb)
  gl.viewport(0, 0, GLsizei(w), GLsizei(h))
  # the background: the scene's color, or the soft gradient (as two colors, top and bottom)
  let top = if bg.a != 0: bg else: mixColor(th.field, th.face, 0.15)
  let bottom = if bg.a != 0: bg else: mixColor(th.field, th.face, 0.85)
  gl.depthMask(1)
  gl.clearColor(0, 0, 0, 1)
  gl.clear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  gl.useProgram(v.prog)
  for i in 0'u32 .. 3'u32: gl.enableVertexAttribArray(i)
  proc attribs(gl: ptr GlTable) =
    let stride = GLsizei(12 * 4)
    gl.vertexAttribPointer(0, 3, GL_FLOAT, 0, stride, cast[pointer](0))
    gl.vertexAttribPointer(1, 3, GL_FLOAT, 0, stride, cast[pointer](12))
    gl.vertexAttribPointer(2, 2, GL_FLOAT, 0, stride, cast[pointer](24))
    gl.vertexAttribPointer(3, 4, GL_FLOAT, 0, stride, cast[pointer](32))
  let b = basis(cam)
  let focal = (h.float32 * 0.5'f32) / tan(clamp(cam.fov, 5, 170) * PI.float32 / 360)
  ctx.focal = focal
  ctx.near = max(1e-4'f32, cam.distance * 0.002'f32)
  # (the depth buffer's precision spent where the scene is: from just before
  # its nearest point to just past its farthest)
  let bd = bounds(scene)
  let center = (bd.lo + bd.hi) * 0.5'f32
  let radius = len(bd.hi - bd.lo) * 0.5'f32 + 1e-3'f32
  let toCenter = dot(center - b.eye, b.fwd)
  let near = max(ctx.near, (toCenter - radius) * 0.9'f32)
  let far = max(near * 4, (toCenter + radius) * 1.1'f32)
  gl.uniform4f(v.u("uProj"), 2 * focal / w.float32, 2 * focal / h.float32, (far + near) / (far - near),
               -2 * far * near / (far - near))
  let ambient = if scene.ambient > 0: clamp(scene.ambient, 0, 1) else: 0.35'f32
  let up = Vec3(x: b.right.y, y: b.up.y, z: b.fwd.y)
  let key = unit(LightDir)
  let fill = unit(Vec3(x: 0.55, y: -0.15, z: -0.6))
  gl.uniform3f(v.u("uKey"), key.x, key.y, key.z)
  gl.uniform3f(v.u("uFill"), fill.x, fill.y, fill.z)
  gl.uniform3f(v.u("uUp"), up.x, up.y, up.z)
  gl.uniform2f(v.u("uLight"), if scene.exposure > 0: scene.exposure else: 1'f32, 0.3'f32 + ambient * 0.6'f32)
  gl.uniform1i(v.u("sBase"), 0)
  gl.uniform1i(v.u("sMR"), 1)
  gl.uniform1i(v.u("sEmis"), 2)
  # the background, a quad at the far end (flat colors)
  if v.lineVbo == 0: gl.genBuffers(1, addr v.lineVbo)
  block:
    let z = far * 0.999'f32
    let xr = z * w.float32 / (2 * focal)
    let yr = z * h.float32 / (2 * focal)
    proc c4(c: Color): array[4, float32] = [c.r.float32 / 255, c.g.float32 / 255, c.b.float32 / 255, 1'f32]
    let ct = c4(top)
    let cb = c4(bottom)
    var q: seq[float32]
    for (x, y, c) in [(-xr, yr, ct), (xr, yr, ct), (xr, -yr, cb), (-xr, yr, ct), (xr, -yr, cb), (-xr, -yr, cb)]:
      q.add [x, y, z, 0, 0, -1, 0, 0, c[0], c[1], c[2], c[3]]
    gl.bindBuffer(GL_ARRAY_BUFFER, v.lineVbo)
    gl.bufferData(GL_ARRAY_BUFFER, q.len * 4, addr q[0], GL_STREAM_DRAW)
    attribs(gl)
    gl.uniform1f(v.u("uMode"), 1)
    gl.disable(GL_DEPTH_TEST)
    gl.drawArrays(GL_TRIANGLES, 0, 6)
  gl.enable(GL_DEPTH_TEST)
  gl.depthFunc(GL_LEQUAL)
  # the meshes: posed as the CPU poses them, sent, drawn (see-through ones last, farthest first)
  let worlds = nodeWorlds(scene)
  ctx.view.setLen(scene.meshes.len)
  ctx.spheres.setLen(scene.meshes.len)
  if v.meshes.len != scene.meshes.len: v.meshes.setLen(scene.meshes.len)
  var posedV, posedN: seq[Vec3]
  var data: seq[float32]
  var order: seq[(bool, float32, int)]          # (see-through, depth, mesh)
  for mi, m in scene.meshes:
    ctx.view[mi].setLen(0)
    ctx.spheres[mi] = (Vec3(), -1'f32)
    if not scene.meshShown(m) or m.verts.len == 0 or m.tris.len == 0: continue
    let hasN = poseMesh(scene, worlds, mi, posedV, posedN)
    var vv = newSeq[Vec3](posedV.len)
    var lo, hi: Vec3
    for k in 0 ..< posedV.len:
      vv[k] = toView(b, posedV[k])
      if k == 0: (lo, hi) = (vv[k], vv[k])
      else:
        lo = Vec3(x: min(lo.x, vv[k].x), y: min(lo.y, vv[k].y), z: min(lo.z, vv[k].z))
        hi = Vec3(x: max(hi.x, vv[k].x), y: max(hi.y, vv[k].y), z: max(hi.z, vv[k].z))
    ctx.spheres[mi] = ((lo + hi) * 0.5'f32, len(hi - lo) * 0.5'f32)
    # normals: given (posed), or from the faces (a flat mesh: a point for each
    # corner, with its face's normal)
    let plain = not (m.material >= 0 and m.material < scene.materials.len) and
                m.uvs.len == 0 and m.vcolors.len == 0
    let perFace = plain and m.colors.len > 0 and m.colors.len == m.tris.len
    let flat = (not hasN and not m.smooth) or perFace
    var en = newSeq[Vec3](vv.len)
    var corners: seq[int32]
    var faceN: seq[Vec3]
    if hasN:
      for k in 0 ..< posedN.len: en[k] = Vec3(x: dot(posedN[k], b.right), y: dot(posedN[k], b.up), z: dot(posedN[k], b.fwd))
      if flat:
        # (a color a triangle: a point for each corner, the normals given)
        for t in m.tris:
          if t[0] < 0 or t[1] < 0 or t[2] < 0 or t[0] >= vv.len or t[1] >= vv.len or t[2] >= vv.len:
            corners.add [0'i32, 0, 0]
          else: corners.add [t[0], t[1], t[2]]
    else:
      for t in m.tris:
        if t[0] < 0 or t[1] < 0 or t[2] < 0 or t[0] >= vv.len or t[1] >= vv.len or t[2] >= vv.len:
          if flat:
            corners.add [0'i32, 0, 0]
            faceN.add Vec3(y: 1)
          continue
        let fnrm = cross(vv[t[2]] - vv[t[0]], vv[t[1]] - vv[t[0]])
        if flat:
          corners.add [t[0], t[1], t[2]]
          faceN.add unit(fnrm)
        else:
          for k in 0 .. 2: en[t[k]] = en[t[k]] + fnrm
    let count = if flat: corners.len else: vv.len
    data.setLen(count * 12)
    for q in 0 ..< count:
      let k = if flat: int(corners[q]) else: q
      let o = q * 12
      let nn = if flat and not hasN: faceN[q div 3] else: unit(en[k])
      data[o] = vv[k].x
      data[o + 1] = vv[k].y
      data[o + 2] = vv[k].z
      data[o + 3] = nn.x
      data[o + 4] = nn.y
      data[o + 5] = nn.z
      if k < m.uvs.len:
        data[o + 6] = m.uvs[k][0]
        data[o + 7] = m.uvs[k][1]
      else:
        data[o + 6] = 0
        data[o + 7] = 0
      if perFace:
        let c = m.colors[q div 3]
        data[o + 8] = c.r.float32 / 255
        data[o + 9] = c.g.float32 / 255
        data[o + 10] = c.b.float32 / 255
        data[o + 11] = 1
      elif k < m.vcolors.len:
        for q in 0 .. 3: data[o + 8 + q] = m.vcolors[k][q]
      else:
        for q in 0 .. 3: data[o + 8 + q] = 1
    ctx.view[mi] = move vv
    var gm = addr v.meshes[mi]
    gm.plain = plain
    gm.perFace = perFace
    if gm.vbo == 0: gl.genBuffers(1, addr gm.vbo)
    gl.bindBuffer(GL_ARRAY_BUFFER, gm.vbo)
    gl.bufferData(GL_ARRAY_BUFFER, data.len * 4, addr data[0], GL_STREAM_DRAW)
    # the triangles: sent once (again when the mesh's change); a flat mesh's in order
    let at = if flat: cast[pointer](1) else: cast[pointer](unsafeAddr m.tris[0])
    if flat and (gm.ibo == 0 or gm.trisAt != at or gm.trisLen != count div 3):
      if gm.ibo == 0: gl.genBuffers(1, addr gm.ibo)
      gl.bindBuffer(GL_ELEMENT_ARRAY_BUFFER, gm.ibo)
      if count <= 65535:
        var idx = newSeq[uint16](count)
        for i in 0 ..< count: idx[i] = uint16(i)
        gl.bufferData(GL_ELEMENT_ARRAY_BUFFER, idx.len * 2, addr idx[0], GL_STATIC_DRAW)
        gm.wide = false
      elif uintIndices == 1:
        var idx = newSeq[uint32](count)
        for i in 0 ..< count: idx[i] = uint32(i)
        gl.bufferData(GL_ELEMENT_ARRAY_BUFFER, idx.len * 4, addr idx[0], GL_STATIC_DRAW)
        gm.wide = true
      else:
        gl.bindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0)
        v.failed = true
        return false
      gm.indexCount = count
      gm.trisAt = at
      gm.trisLen = count div 3
    elif not flat and (gm.ibo == 0 or gm.trisAt != at or gm.trisLen != m.tris.len):
      if gm.ibo == 0: gl.genBuffers(1, addr gm.ibo)
      gl.bindBuffer(GL_ELEMENT_ARRAY_BUFFER, gm.ibo)
      if m.verts.len <= 65535:
        var idx = newSeq[uint16](m.tris.len * 3)
        for i, t in m.tris:
          for k in 0 .. 2: idx[i * 3 + k] = uint16(clamp(int(t[k]), 0, m.verts.high))
        gl.bufferData(GL_ELEMENT_ARRAY_BUFFER, idx.len * 2, addr idx[0], GL_STATIC_DRAW)
        gm.wide = false
      elif uintIndices == 1:
        var idx = newSeq[uint32](m.tris.len * 3)
        for i, t in m.tris:
          for k in 0 .. 2: idx[i * 3 + k] = uint32(clamp(int(t[k]), 0, m.verts.high))
        gl.bufferData(GL_ELEMENT_ARRAY_BUFFER, idx.len * 4, addr idx[0], GL_STATIC_DRAW)
        gm.wide = true
      else:
        # (a GPU without 32-bit indices, a mesh of more than 65535 points: the CPU draws it all)
        gl.bindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0)
        v.failed = true
        return false
      gm.indexCount = m.tris.len * 3
      gm.trisAt = at
      gm.trisLen = m.tris.len
    let mat = if m.material >= 0 and m.material < scene.materials.len: scene.materials[m.material].alphaMode else: amOpaque
    order.add (mat == amBlend, ctx.spheres[mi][0].z, mi)
  order.sort(proc (a, b: (bool, float32, int)): int =
    if a[0] != b[0]: cmp(a[0], b[0]) elif a[0]: cmp(b[1], a[1]) else: cmp(a[1], b[1]))
  gl.uniform1f(v.u("uMode"), 0)
  for (see, depth, mi) in order:
    let m = scene.meshes[mi]
    let gm = v.meshes[mi]
    let tint = if m.node >= 0 and m.node < scene.nodes.len: scene.nodes[m.node].tint else: Color()
    var base = if gm.perFace: [1'f32, 1, 1, 1]
               else: [m.color.r.float32 / 255, m.color.g.float32 / 255, m.color.b.float32 / 255, 1'f32]
    gl.uniform1f(v.u("uMode"), if gm.plain: 2 else: 0)
    var mr = [0'f32, 0.9, 0]
    var emis = [0'f32, 0, 0]
    var alpha = [0'f32, 0.5]
    var twoSided = m.twoSided
    var tBase, tMr, tEmis: GLuint
    if m.material >= 0 and m.material < scene.materials.len:
      let mt = scene.materials[m.material]
      base = mt.baseColor
      mr = [mt.metallic, mt.roughness, (if mt.unlit: 1'f32 else: 0)]
      emis = mt.emissive
      alpha = [float32(ord(mt.alphaMode)), mt.alphaCutoff]
      twoSided = twoSided or mt.doubleSided
      if tint.a == 0: tBase = v.textureOf(mt.texture)
      tMr = v.textureOf(mt.mrTexture)
      tEmis = v.textureOf(mt.emissiveTexture)
    if tint.a != 0:
      base = [tint.r.float32 / 255, tint.g.float32 / 255, tint.b.float32 / 255, base[3]]
    gl.uniform4f(v.u("uBase"), base[0], base[1], base[2], base[3])
    gl.uniform3f(v.u("uMR"), mr[0], mr[1], mr[2])
    gl.uniform3f(v.u("uEmis"), emis[0], emis[1], emis[2])
    gl.uniform2f(v.u("uAlpha"), alpha[0], alpha[1])
    gl.uniform1f(v.u("uTwoSided"), if twoSided: 1 else: 0)
    gl.uniform3f(v.u("uTex"), float32(ord(tBase != 0)), float32(ord(tMr != 0)), float32(ord(tEmis != 0)))
    for (unit, t) in [(0'u32, tBase), (1'u32, tMr), (2'u32, tEmis)]:
      gl.activeTexture(GL_TEXTURE0 + unit)
      gl.bindTexture(GL_TEXTURE_2D, t)
    gl.activeTexture(GL_TEXTURE0)
    if see:
      gl.enable(GL_BLEND)
      gl.blendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
      gl.colorMask(1, 1, 1, 0)
      gl.depthMask(0)
    gl.bindBuffer(GL_ARRAY_BUFFER, gm.vbo)
    attribs(gl)
    gl.bindBuffer(GL_ELEMENT_ARRAY_BUFFER, gm.ibo)
    gl.drawElements(GL_TRIANGLES, GLsizei(gm.indexCount), if gm.wide: GL_UNSIGNED_INT else: GL_UNSIGNED_SHORT, nil)
    if see:
      gl.disable(GL_BLEND)
      gl.colorMask(1, 1, 1, 1)
      gl.depthMask(1)
  # lines (grids, axes), and the outlines of meshes that ask for them --
  # only where the surface folds, as the CPU draws them; a little toward
  # the eye, so their own faces do not hide them
  var q: seq[float32]
  if not scene.wireframe:
    for mi, m in scene.meshes:
      if not m.edges or mi >= ctx.view.len or ctx.view[mi].len == 0: continue
      let vv = ctx.view[mi]
      var fold: Table[int64, tuple[n: Vec3; count: int]]
      for t in m.tris:
        if t[0] < 0 or t[1] < 0 or t[2] < 0 or t[0] >= vv.len or t[1] >= vv.len or t[2] >= vv.len: continue
        let fn = unit(cross(vv[t[1]] - vv[t[0]], vv[t[2]] - vv[t[0]]))
        for k in 0 .. 2:
          let a = t[k]
          let b2 = t[(k + 1) mod 3]
          let ek = (min(a, b2).int64 shl 32) or max(a, b2).int64
          let e = fold.getOrDefault(ek, (Vec3(), 0))
          let keep = if e.count == 0: fn
                     elif dot(e.n, fn) > 0.999: e.n
                     else: Vec3()
          fold[ek] = (keep, e.count + 1)
      let ec = mixColor(m.color, color(0, 0, 0), 0.6)
      let cc = [ec.r.float32 / 255, ec.g.float32 / 255, ec.b.float32 / 255, 1'f32]
      for ek, e in fold:
        if e.count >= 2 and not (e.n.x == 0 and e.n.y == 0 and e.n.z == 0): continue
        let a = vv[int(ek shr 32)] * 0.997'f32
        let c = vv[int(ek and 0xFFFFFFFF'i64)] * 0.997'f32
        if not (finite(a) and finite(c)) or a.z < near or c.z < near: continue
        for p in [a, c]: q.add [p.x, p.y, p.z, 0, 0, -1, 0, 0, cc[0], cc[1], cc[2], cc[3]]
  if scene.lines.len > 0 or q.len > 0:
    for l in scene.lines:
      var a = toView(b, l.a)
      var c = toView(b, l.b)
      if not (finite(a) and finite(c)) or (a.z < near and c.z < near): continue
      if a.z < near: a = a + (c - a) * ((near - a.z) / (c.z - a.z))
      elif c.z < near: c = c + (a - c) * ((near - c.z) / (a.z - c.z))
      let lc = [l.color.r.float32 / 255, l.color.g.float32 / 255, l.color.b.float32 / 255, 1'f32]
      for p in [a, c]: q.add [p.x, p.y, p.z, 0, 0, -1, 0, 0, lc[0], lc[1], lc[2], lc[3]]
    if q.len > 0:
      gl.bindBuffer(GL_ARRAY_BUFFER, v.lineVbo)
      gl.bufferData(GL_ARRAY_BUFFER, q.len * 4, addr q[0], GL_STREAM_DRAW)
      attribs(gl)
      gl.uniform1f(v.u("uMode"), 1)
      gl.drawArrays(GL_LINES, 0, GLsizei(q.len div 12))
  gl.bindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0)
  gl.disable(GL_DEPTH_TEST)
  gl.depthMask(1)
  # where the labels go (as the CPU's drawing has them)
  ctx.labels.setLen(scene.labels.len)
  for k, lb in scene.labels:
    let p = toView(b, lb.at)
    if finite(p) and p.z >= near:
      let s = project(ctx, p, 1)
      ctx.labels[k] = (s.x, s.y, finite(s.x) and finite(s.y))
    else: ctx.labels[k] = (0'f32, 0'f32, false)
  v3Show(v.key, v.color, w, h)
  true

## Numbers worked out on the GPU, from any thread: an off-screen OpenGL ES context of the thread's
## own (EGL -- Linux, Android; elsewhere none: the CPU), products of matrices drawn into a texture
## a part of the shared length a pass, read back. With OpenGL ES 3 and float textures to draw into,
## four floats a texel, four sums a pixel; else (any OpenGL ES 2 GPU with 32-bit floats in its
## fragment shaders) the floats carried in ordinary 8-bit textures -- each float's four bytes a
## texel, taken apart and put together again in the shader. For the image models' runner
## (`retroui/nnet`): its big products -- convolutions as such, linear layers, attention's -- the
## same numbers as the CPU's within rounding.
##
## ```nim
## if computeReady():                       # (this thread's context, made the first time)
##   let c = gpuMatmul(a, b, m, k, n)       # a: m x k, b: k x n, row by row; empty: the CPU
## ```
##
## A context is made for each thread that asks and kept while the program runs (letting one go
## could end the others'), never on a thread with an EGL context of its own already (the one that
## draws the window: `computeReady` is false there); `computeSoftware` says when the "GPU" is the
## processor drawing (llvmpipe, SwiftShader): slower than the CPU's own vectors.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

when not defined(wasm):
  import std/[strutils, locks]
  import glapi
  import uirelays/eglload

  const
    Pass = 256                      ## the shared length summed in one pass

    Vertex = """
attribute vec2 aPos;
uniform vec2 uSize;
varying vec2 vPos;
void main() {
  gl_Position = vec4(aPos, 0.0, 1.0);
  vPos = (aPos * 0.5 + 0.5) * uSize;
}
"""

    Fragment = """
uniform sampler2D uA;
uniform sampler2D uB;
uniform sampler2D uC;
uniform vec2 uASize;
uniform vec2 uBSize;
uniform vec2 uSize;
uniform float uT0;
uniform float uCount;
uniform float uFirst;
varying vec2 vPos;

float unpackF(vec4 c) {
  vec4 b = floor(c * 255.0 + 0.5);
  float e = mod(b.w, 128.0) * 2.0 + floor(b.z * (1.0 / 128.0));
  if (e < 0.5) return 0.0;
  float m = mod(b.z, 128.0) * 65536.0 + b.y * 256.0 + b.x;
  float v = exp2(e - 127.0) * (1.0 + m * (1.0 / 8388608.0));
  return b.w >= 128.0 ? -v : v;
}

vec4 packF(float v) {
  if (v == 0.0) return vec4(0.0);
  float s = v < 0.0 ? 128.0 : 0.0;
  float av = abs(v);
  float e = floor(log2(av));
  if (exp2(e) > av) e -= 1.0;
  else if (exp2(e + 1.0) <= av) e += 1.0;
  if (e < -126.0) return vec4(0.0);
  float m = floor((av * exp2(-e) - 1.0) * 8388608.0 + 0.5);
  if (m >= 8388608.0) { m = 0.0; e += 1.0; }
  float be = min(e + 127.0, 254.0);
  float hi = floor(m * (1.0 / 65536.0));
  float mid = floor((m - hi * 65536.0) * (1.0 / 256.0));
  float lo = m - hi * 65536.0 - mid * 256.0;
  return vec4(lo, mid, mod(be, 2.0) * 128.0 + hi, s + floor(be * 0.5)) * (1.0 / 255.0);
}

void main() {
  float acc = uFirst > 0.5 ? 0.0 : unpackF(texture2D(uC, vPos / uSize));
  float ay = vPos.y / uASize.y;
  float bx = vPos.x / uBSize.x;
  for (int q = 0; q < 256; q++) {
    if (float(q) >= uCount) break;
    float t = uT0 + float(q) + 0.5;
    acc += unpackF(texture2D(uA, vec2(t / uASize.x, ay))) * unpackF(texture2D(uB, vec2(bx, t / uBSize.y)));
  }
  gl_FragColor = packF(acc);
}
"""

    Vertex3 = """#version 300 es
in vec2 aPos;
void main() { gl_Position = vec4(aPos, 0.0, 1.0); }
"""

    Fragment3 = """#version 300 es
precision highp float;
precision highp int;
uniform highp sampler2D uA;
uniform highp sampler2D uB;
uniform highp sampler2D uC;
uniform int uT0;
uniform int uCount;
uniform int uFirst;
uniform int uN;
out vec4 outC;
void main() {
  ivec2 p = ivec2(gl_FragCoord.xy);
  vec4 acc = uFirst == 1 ? vec4(0.0) : texelFetch(uC, p, 0);
  int j0 = p.x * 4;
  int j1 = min(j0 + 1, uN - 1);
  int j2 = min(j0 + 2, uN - 1);
  int j3 = min(j0 + 3, uN - 1);
  for (int t = uT0; t < uT0 + uCount; t++) {
    vec4 a = texelFetch(uA, ivec2(t, p.y), 0);
    acc += vec4(dot(a, texelFetch(uB, ivec2(t, j0), 0)), dot(a, texelFetch(uB, ivec2(t, j1), 0)),
                dot(a, texelFetch(uB, ivec2(t, j2), 0)), dot(a, texelFetch(uB, ivec2(t, j3), 0)));
  }
  outC = acc;
}
"""

    Pass3 = 512                     ## (... four floats each, with float textures)
    GL_RGBA32F = 0x8814'u32

  type
    Compute = object
      tried, ok: bool
      egl: Egl
      gl: GlTable
      prog: GLuint
      vbo: GLuint
      maxTex: int
      renderer: array[96, char]     # (its name: no string in a thread's own variable -- never freed when it ends)
      floats: bool                  # (OpenGL ES 3, float textures drawn into: `prog` is Fragment3's)

  var
    here {.threadvar.}: Compute     # (this thread's context)
    procEgl {.threadvar.}: Egl      # (... whose GL functions `loadGl` asks for)
    openLock: Lock                  # (EGL's library loaded by one thread at a time)
    computeOff* = false
      ## No GPU for numbers at all (a test, a comparison): `computeReady` false.
    computeNoFloats* {.threadvar.}: bool
      ## This thread's context made without float textures (the 8-bit way: a test). Before its first
      ## `computeReady`.

  initLock(openLock)

  proc computeProc(name: cstring): pointer {.nimcall.} = procEgl.glProc(name)

  proc compile(gl: GlTable; kind: GLenum; src: string): GLuint =
    let head = if src.startsWith("#version"): ""
               else: "#version 100\n" & (if kind == GL_FRAGMENT_SHADER: "precision highp float;\n" else: "")
    let full = head & src
    result = gl.createShader(kind)
    var cs = cstring(full)
    gl.shaderSource(result, 1, addr cs, nil)
    gl.compileShader(result)
    var ok: GLint
    gl.getShaderiv(result, GL_COMPILE_STATUS, addr ok)
    if ok == 0:
      gl.deleteShader(result)
      result = 0

  proc open(c: var Compute): bool =
    ## (this thread's context: an off-screen EGL one, its functions, the program)
    c.tried = true
    if computeOff: return false
    # (OpenGL ES 3 first; the display left alone when a context cannot be made: others may be on it)
    var version = 3
    withLock openLock:
      # (never on a thread that draws a window with EGL: its context would be taken away)
      if contextCurrentHere(): return false
      c.egl.shared = true
      if not c.egl.openOffscreen(1, 1, 3):
        c.egl = Egl(shared: true)
        version = 2
        if not c.egl.openOffscreen(1, 1, 2): return false
    procEgl = c.egl
    if not loadGl(c.gl, computeProc, es = true) or c.gl.genFramebuffers == nil or
       c.gl.bindFramebuffer == nil or c.gl.framebufferTexture2D == nil or c.gl.checkFramebufferStatus == nil or
       c.gl.uniform1f == nil:
      return false
    let gl = c.gl
    let r = gl.getString(GL_RENDERER)
    if r != nil:
      let name = $r
      for i in 0 ..< min(name.len, c.renderer.high): c.renderer[i] = name[i]
    var mt: GLint
    gl.getIntegerv(GL_MAX_TEXTURE_SIZE, addr mt)
    c.maxTex = int(mt)
    let ext = gl.getString(GL_EXTENSIONS)
    c.floats = version >= 3 and ext != nil and "GL_EXT_color_buffer_float" in $ext and not computeNoFloats
    var vs = compile(gl, GL_VERTEX_SHADER, if c.floats: Vertex3 else: Vertex)
    var fs = compile(gl, GL_FRAGMENT_SHADER, if c.floats: Fragment3 else: Fragment)
    if c.floats and (vs == 0 or fs == 0):
      # (float textures, but not these shaders: the 8-bit way)
      if vs != 0: gl.deleteShader(vs)
      if fs != 0: gl.deleteShader(fs)
      c.floats = false
      vs = compile(gl, GL_VERTEX_SHADER, Vertex)
      fs = compile(gl, GL_FRAGMENT_SHADER, Fragment)     # (no 32-bit floats: it does not compile)
    if vs == 0 or fs == 0: return false
    let p = gl.createProgram()
    gl.attachShader(p, vs)
    gl.attachShader(p, fs)
    gl.bindAttribLocation(p, 0, "aPos")
    gl.linkProgram(p)
    gl.deleteShader(vs)
    gl.deleteShader(fs)
    var ok: GLint
    gl.getProgramiv(p, GL_LINK_STATUS, addr ok)
    if ok == 0:
      gl.deleteProgram(p)
      return false
    c.prog = p
    var quad = [-1'f32, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]
    gl.genBuffers(1, addr c.vbo)
    gl.bindBuffer(GL_ARRAY_BUFFER, c.vbo)
    gl.bufferData(GL_ARRAY_BUFFER, sizeof(quad), addr quad[0], GL_STREAM_DRAW)
    gl.disable(GL_BLEND)
    gl.disable(GL_SCISSOR_TEST)
    gl.disable(GL_DITHER)
    c.ok = true
    true

  proc computeReady*(): bool =
    ## This thread can work out numbers on the GPU (its context made the first time it asks).
    if not here.tried: discard here.open()
    here.ok and not computeOff

  proc computeRenderer*(): string =
    ## The GPU this thread's numbers are worked out on ("" without one).
    if computeReady(): $cast[cstring](addr here.renderer[0]) else: ""

  proc computeSoftware*(): bool =
    ## The "GPU" is the processor drawing (llvmpipe, softpipe, SwiftShader...): slower than the CPU's
    ## own vectors for numbers.
    let r = computeRenderer().toLowerAscii
    r.len > 0 and ("llvmpipe" in r or "softpipe" in r or "swiftshader" in r or "software" in r or
                   "swrast" in r)

  proc computeMaxSide*(): int =
    ## The longest side of a matrix the GPU takes (0 without one).
    if computeReady(): here.maxTex else: 0

  proc texOf(gl: GlTable; w, h: int; data: pointer): GLuint =
    gl.genTextures(1, addr result)
    gl.bindTexture(GL_TEXTURE_2D, result)
    gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
    gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
    gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
    gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
    gl.pixelStorei(GL_UNPACK_ALIGNMENT, 4)
    gl.texImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA), GLsizei(w), GLsizei(h), 0, GL_RGBA, GL_UNSIGNED_BYTE, data)

  proc computeFloats*(): bool =
    ## This thread's GPU works on float textures (four floats a texel: quicker), else on 8-bit ones.
    computeReady() and here.floats

  proc floatTex(gl: GlTable; w, h: int; data: pointer): GLuint =
    gl.genTextures(1, addr result)
    gl.bindTexture(GL_TEXTURE_2D, result)
    gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
    gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
    gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
    gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
    gl.pixelStorei(GL_UNPACK_ALIGNMENT, 4)
    gl.texImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA32F), GLsizei(w), GLsizei(h), 0, GL_RGBA, GL_FLOAT, data)

  proc matmul4(a, b: openArray[float32]; m, k, n: int): seq[float32] =
    ## (with float textures: `a`'s rows four floats a texel, `b` turned so its columns are too, four
    ## sums a pixel)
    result = @[]
    let gl = here.gl
    let mt = here.maxTex
    let k4 = (k + 3) div 4
    let n4 = (n + 3) div 4
    if k4 > mt or n > mt or n4 > mt: return
    # (b's columns as rows, each as long as a's rows: zeros past the end)
    var bt = newSeq[float32](n * k4 * 4)
    for t in 0 ..< k:
      for j in 0 ..< n: bt[j * k4 * 4 + t] = b[t * n + j]
    let band = min(m, mt)
    var ans = newSeq[float32](m * n)
    var row4 = newSeq[float32](band * n4 * 4)
    var arow: seq[float32]
    let texB = floatTex(gl, k4, n, addr bt[0])
    var fb: GLuint
    gl.genFramebuffers(1, addr fb)
    gl.bindFramebuffer(GL_FRAMEBUFFER, fb)
    gl.useProgram(here.prog)
    gl.bindBuffer(GL_ARRAY_BUFFER, here.vbo)
    gl.vertexAttribPointer(0, 2, GL_FLOAT, 0, 8, nil)
    gl.enableVertexAttribArray(0)
    let p = here.prog
    gl.uniform1i(gl.getUniformLocation(p, "uA"), 0)
    gl.uniform1i(gl.getUniformLocation(p, "uB"), 1)
    gl.uniform1i(gl.getUniformLocation(p, "uC"), 2)
    gl.uniform1i(gl.getUniformLocation(p, "uN"), GLint(n))
    let uT0 = gl.getUniformLocation(p, "uT0")
    let uCount = gl.getUniformLocation(p, "uCount")
    let uFirst = gl.getUniformLocation(p, "uFirst")
    var good = true
    var r0 = 0
    while r0 < m and good:
      let rows = min(band, m - r0)
      var aptr = unsafeAddr a[r0 * k]
      if k != k4 * 4:
        arow.setLen(rows * k4 * 4)
        for i in 0 ..< rows:
          copyMem(addr arow[i * k4 * 4], unsafeAddr a[(r0 + i) * k], k * sizeof(float32))
          for t in k ..< k4 * 4: arow[i * k4 * 4 + t] = 0
        aptr = addr arow[0]
      let texA = floatTex(gl, k4, rows, aptr)
      var acc = [floatTex(gl, n4, rows, nil), floatTex(gl, n4, rows, nil)]
      gl.viewport(0, 0, GLsizei(n4), GLsizei(rows))
      gl.activeTexture(GL_TEXTURE0)
      gl.bindTexture(GL_TEXTURE_2D, texA)
      gl.activeTexture(GL_TEXTURE0 + 1)
      gl.bindTexture(GL_TEXTURE_2D, texB)
      var t0 = 0
      var cur = 0
      while t0 < k4:
        gl.framebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, acc[cur], 0)
        if gl.checkFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE:
          good = false
          break
        gl.activeTexture(GL_TEXTURE0 + 2)
        gl.bindTexture(GL_TEXTURE_2D, acc[1 - cur])
        gl.uniform1i(uT0, GLint(t0))
        gl.uniform1i(uCount, GLint(min(Pass3, k4 - t0)))
        gl.uniform1i(uFirst, GLint(ord(t0 == 0)))
        gl.drawArrays(GL_TRIANGLES, 0, 6)
        t0 += Pass3
        cur = 1 - cur
      if good:
        gl.pixelStorei(GL_PACK_ALIGNMENT, 4)
        gl.readPixels(0, 0, GLsizei(n4), GLsizei(rows), GL_RGBA, GL_FLOAT, addr row4[0])
        if gl.getError() != 0: good = false
        else:
          for i in 0 ..< rows:
            copyMem(addr ans[(r0 + i) * n], addr row4[i * n4 * 4], n * sizeof(float32))
      var ta = texA
      gl.deleteTextures(1, addr ta)
      gl.deleteTextures(2, addr acc[0])
      r0 += rows
    gl.bindFramebuffer(GL_FRAMEBUFFER, 0)
    gl.deleteFramebuffers(1, addr fb)
    var tb = texB
    gl.deleteTextures(1, addr tb)
    if good: result = ans

  proc gpuMatmul*(a, b: openArray[float32]; m, k, n: int): seq[float32] =
    ## `a` (`m` x `k`) times `b` (`k` x `n`), both row by row, on the GPU: `m` x `n`, row by row --
    ## within rounding of the CPU's (the sums in another order). Empty when the GPU cannot (none
    ## here, a side longer than the GPU takes: `computeMaxSide`).
    result = @[]         # (a value at once: see tools/writecheck.py)
    if m <= 0 or n <= 0 or k <= 0 or a.len < m * k or b.len < k * n: return
    if not computeReady(): return
    if here.floats:
      result = matmul4(a, b, m, k, n)
      return
    let gl = here.gl
    let mt = here.maxTex
    if k > mt or n > mt: return
    let band = min(m, mt)                   # (rows of the answer drawn at once)
    var ans = newSeq[float32](m * n)
    let texB = texOf(gl, n, k, unsafeAddr b[0])
    var fb: GLuint
    gl.genFramebuffers(1, addr fb)
    gl.bindFramebuffer(GL_FRAMEBUFFER, fb)
    gl.useProgram(here.prog)
    gl.bindBuffer(GL_ARRAY_BUFFER, here.vbo)
    gl.vertexAttribPointer(0, 2, GL_FLOAT, 0, 8, nil)
    gl.enableVertexAttribArray(0)
    let p = here.prog
    gl.uniform1i(gl.getUniformLocation(p, "uA"), 0)
    gl.uniform1i(gl.getUniformLocation(p, "uB"), 1)
    gl.uniform1i(gl.getUniformLocation(p, "uC"), 2)
    let uASize = gl.getUniformLocation(p, "uASize")
    let uSize = gl.getUniformLocation(p, "uSize")
    let uT0 = gl.getUniformLocation(p, "uT0")
    let uCount = gl.getUniformLocation(p, "uCount")
    let uFirst = gl.getUniformLocation(p, "uFirst")
    gl.uniform2f(gl.getUniformLocation(p, "uBSize"), GLf32(n), GLf32(k))
    var good = true
    var r0 = 0
    while r0 < m and good:
      let rows = min(band, m - r0)
      let texA = texOf(gl, k, rows, unsafeAddr a[r0 * k])
      var acc = [texOf(gl, n, rows, nil), texOf(gl, n, rows, nil)]
      gl.uniform2f(uASize, GLf32(k), GLf32(rows))
      gl.uniform2f(uSize, GLf32(n), GLf32(rows))
      gl.viewport(0, 0, GLsizei(n), GLsizei(rows))
      gl.activeTexture(GL_TEXTURE0)
      gl.bindTexture(GL_TEXTURE_2D, texA)
      gl.activeTexture(GL_TEXTURE0 + 1)
      gl.bindTexture(GL_TEXTURE_2D, texB)
      var t0 = 0
      var cur = 0
      while t0 < k:
        # (a pass: the sums so far, from the other texture, and 256 more of the shared length)
        gl.framebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, acc[cur], 0)
        if gl.checkFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE:
          good = false
          break
        gl.activeTexture(GL_TEXTURE0 + 2)
        gl.bindTexture(GL_TEXTURE_2D, acc[1 - cur])
        gl.uniform1f(uT0, GLf32(t0))
        gl.uniform1f(uCount, GLf32(min(Pass, k - t0)))
        gl.uniform1f(uFirst, GLf32(ord(t0 == 0)))
        gl.drawArrays(GL_TRIANGLES, 0, 6)
        t0 += Pass
        cur = 1 - cur
      if good:
        # (the last pass's texture is the one bound now: its bytes are the floats)
        gl.pixelStorei(GL_PACK_ALIGNMENT, 4)
        gl.readPixels(0, 0, GLsizei(n), GLsizei(rows), GL_RGBA, GL_UNSIGNED_BYTE, addr ans[r0 * n])
        if gl.getError() != 0: good = false
      var ta = texA
      gl.deleteTextures(1, addr ta)
      gl.deleteTextures(2, addr acc[0])
      r0 += rows
    gl.bindFramebuffer(GL_FRAMEBUFFER, 0)
    gl.deleteFramebuffers(1, addr fb)
    var tb = texB
    gl.deleteTextures(1, addr tb)
    if good: result = ans

when defined(wasm):
  # (a page: WebGPU beside the window's WebGL2, the page's own device -- `retro.js` -- asked by a
  # thread, which waits on a word of the shared memory until it is done; never the page's thread)

  var
    computeOff* = false
      ## No GPU for numbers at all (a test, a comparison): `computeReady` false.
    computeNoFloats* {.threadvar.}: bool
      ## (natively, the 8-bit way; a page's WebGPU always has floats)
    pageThread = -1

  when compileOption("threads"):
    pageThread = getThreadId()
    proc rwGpuReady(): cint {.importc: "rw_gpu_ready", cdecl.}
    proc rwGpuInfo(buf: pointer; cap: cint): cint {.importc: "rw_gpu_info", cdecl.}
    proc rwGpuMatmul(a, b, c: pointer; m, k, n: cint; flag: pointer): cint {.importc: "rw_gpu_matmul", cdecl.}
    proc atomicWait32(p: ptr int32; expected: int32; timeoutNs: int64): int32
      {.importc: "__builtin_wasm_memory_atomic_wait32", nodecl.}

  proc computeReady*(): bool =
    ## This thread can work out numbers on the GPU: a page's thread (not the page's own), WebGPU
    ## there.
    when compileOption("threads"):
      not computeOff and getThreadId() != pageThread and rwGpuReady() > 0
    else: false

  proc computeRenderer*(): string =
    ## The GPU this thread's numbers are worked out on ("" without one).
    when compileOption("threads"):
      if not computeReady(): return ""
      var buf = newString(200)
      let n = rwGpuInfo(addr buf[0], 200)
      buf.setLen(max(0, n))
      buf
    else: ""

  proc computeSoftware*(): bool =
    ## The "GPU" is the processor drawing (WebGPU's fallback adapter, SwiftShader).
    when compileOption("threads"): computeReady() and rwGpuReady() == 2
    else: false

  proc computeMaxSide*(): int =
    ## The longest side of a matrix the GPU takes (0 without one).
    if computeReady(): 1 shl 20 else: 0

  proc computeFloats*(): bool =
    ## Floats as they are (WebGPU's storage buffers).
    computeReady()

  proc gpuMatmul*(a, b: openArray[float32]; m, k, n: int): seq[float32] =
    ## `a` (`m` x `k`) times `b` (`k` x `n`), both row by row, on the GPU: `m` x `n`, row by row --
    ## within rounding of the CPU's. Empty when the GPU cannot.
    result = @[]
    when compileOption("threads"):
      if m <= 0 or n <= 0 or k <= 0 or a.len < m * k or b.len < k * n or not computeReady(): return
      var ans = newSeq[float32](m * n)
      var flag {.align: 8.}: int32 = 0
      if rwGpuMatmul(unsafeAddr a[0], unsafeAddr b[0], addr ans[0], cint(m), cint(k), cint(n), addr flag) == 0:
        return
      while atomicLoadN(addr flag, ATOMIC_SEQ_CST) == 0:
        discard atomicWait32(addr flag, 0, -1)
      if flag == 1: result = ans

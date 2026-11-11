# (included by gfx.nim) The frame drawn with OpenGL ES 2 / OpenGL 2.1.
#
# Every drawing command becomes rectangles: fills of a color, glyphs and
# shapes from a texture of masks (made on the CPU by the same code that
# draws them there, so the text looks the same), icons from a texture of
# pictures, photos and other bitmaps from textures of their own (only what
# changed is sent again), patterns (the 3.1 dither, a selection's marching
# ants) worked out by the shader. As on the CPU, only the tiles whose
# drawing changed are drawn again (see `gpuPresent`), and nothing at all
# when nothing did.
## Frames drawn with the GPU (gfxgpu, included by `gfx`): `setGpuMode`
## chooses it, `drawnWithGpu` tells whether it is in use.

import glapi
import uirelays/target   # (androidApp: an APK, not a program in Termux)

type
  GpuMode* = enum
    ## How frames are drawn (`setGpuMode`).
    gmAuto = "Automatic"       ## with the GPU when it is a real one, else the CPU
    gmGpu = "GPU"              ## with the GPU when there is one (even a software one)
    gmCpu = "CPU"              ## on the CPU, always

  Vtx = object
    x, y, u, v: float32
    col: array[4, uint8]
    mode: array[4, uint8]

  AtlasEntry = tuple[x, y, w, h: int32]

  Atlas = object
    tex: GLuint
    size: int
    fmt: GLenum
    curX, curY, shelfH: int
    map: Table[uint64, AtlasEntry]

  TexTile = tuple[tex: GLuint; x, y, w, h: int; filter: GLint]

  TexEntry = object
    tiles: seq[TexTile]
    w, h: int
    whole: uint64              ## the bitmap's version (all of it) the texture has
    outside: bool              ## a texture of other code's (`gpuShowTexture`): not given back here
    stamp: uint64              ## ... and its last change
    used: int                  ## the frame it was last drawn in

  Batch = tuple[first, count: int; tex: GLuint; filter: GLint; lcd: uint32]
    ## (`lcd`: 0, or text in the screen's color strips in that color or'd
    ## with 1 shl 24 -- the GPU's blend color)

const
  ModeSolid = 0'u8
  ModeMask = 1'u8
  ModeColor = 2'u8
  ModeBitmap = 3'u8
  ModeChecker = 4'u8
  ModeAnts = 5'u8
  ModeChecker2 = 6'u8
  AtlasMaskSize = 2048
  AtlasColorSize = 1024
  MaxParts = 8                 ## rectangles a frame's change is drawn in

var
  gpuThreadId = -1             # (the thread the GPU draws on: its filters there only)
  gl: GlTable
  gpuNoDevice = false          # (auto: no graphics device found, OpenGL not tried)
  gpuWanted = gmAuto
  gpuOn: bool                  ## frames drawn with OpenGL now
  gpuTried: bool               ## a start was tried (again when the mode changes)
  gpuGen = -1
  gpuRenderer: string
  gpuSoftware: bool
  gpuCrashed: bool             ## the last run stopped while starting the GPU
  gpuTextureBudget* = 160 * 1024 * 1024
    ## The pictures' textures kept on the GPU at most (bytes): past it the
    ## least recently drawn are given back at once (not only those not
    ## drawn for a while) -- a viewer flicking through photos keeps a few.
  gpuGuardPath*: string
    ## A file that is there while the GPU is being started and for the first
    ## frames: found at the next start, it says that run crashed there, and
    ## frames are drawn on the CPU (set by the app's start).
  gpuFramesOk: int
  prog, vbo: GLuint
  uScaleLoc: GLint
  maskAtlas, colorAtlas: Atlas
  texCache: Table[pointer, TexEntry]
  verts: seq[Vtx]
  batches: seq[Batch]
  lastVerts: seq[Vtx]          ## the last frame shown (`overlayNow`)
  lastBatches: seq[Batch]
  gpuFrame: int
  maxTex = 2048
  scratchBytes: seq[uint8]
  scratchPx: seq[uint32]
  tempTextures: seq[GLuint]    ## made for one frame (shapes too big for the atlas)
  gpuEpochN: int               ## goes up whenever all made on the GPU is forgotten (`gpuEpoch`)
  # The frame kept between frames, in a texture: when little changed, only
  # the tiles whose drawing changed are drawn again into it (as the CPU
  # does), then all of it is put on the screen -- a caret's blink or the
  # mouse over a button costs what they cover, not a whole frame. A frame
  # that changed much (scrolled, resized) is drawn whole straight onto the
  # screen, as where the GPU cannot keep one.
  keptFbo, keptTex: GLuint     ## the kept frame (0: none)
  keptW, keptH: int
  keptValid: bool              ## it holds the frame on the screen (but `overlayNow`'s)
  intoKept: bool               ## this frame is drawn into it (else onto the screen)
  blitProg, blitVbo: GLuint    ## puts it on the screen
  blitTried: bool
  screenFb: GLint              ## the screen's framebuffer (not 0 everywhere: iOS)
  screenStale: bool            ## the screen shows more than the frame (`overlayNow`)
  staleRect: Rect              ## ... there
  # (what changed, in parts: see `gpuPresent`)
  partsNow: seq[Rect]          ## this frame's change, gathered
  partsDrawn: seq[Rect]        ## ... and what is drawn (with older frames' changes)
  partsTmp: seq[Rect]
  partHist: array[4, seq[Rect]]   ## the changes of the last frames ([0] the last)
  partHistN: int               ## how many of them are known
  directPart: bool             ## (parts drawn straight onto the screen: not kept for `overlayNow`)

let gpuDebugOn = getEnv("RETRO_GPU_DEBUG") == "1"

proc gpuDebug(msg: string) =
  if gpuDebugOn: stderr.writeLine("[gpu] " & msg)

# ---- the program --------------------------------------------------------------------------------

const VertexSrc = """
attribute vec2 aPos;
attribute vec2 aUv;
attribute vec4 aCol;
attribute vec4 aMode;
uniform vec2 uScale;
varying vec2 vUv;
varying vec2 vPos;
varying vec4 vCol;
varying vec4 vMode;
void main() {
  gl_Position = vec4(aPos.x * uScale.x - 1.0, 1.0 - aPos.y * uScale.y, 0.0, 1.0);
  vUv = aUv;
  vPos = aPos;
  vCol = aCol;
  vMode = aMode;
}
"""

const FragmentSrc = """
uniform sampler2D uMask;
uniform sampler2D uColor;
uniform sampler2D uBitmap;
varying vec2 vUv;
varying vec2 vPos;
varying vec4 vCol;
varying vec4 vMode;
void main() {
  float m = vMode.x;
  if (m < 0.5) {
    gl_FragColor = vCol;
  } else if (m < 1.5) {
    gl_FragColor = vec4(vCol.rgb, vCol.a * texture2D(uMask, vUv).a);
  } else if (m < 2.5) {
    vec4 t = texture2D(uColor, vUv).bgra;
    gl_FragColor = vec4(t.rgb, t.a * vCol.a);
  } else if (m < 3.5) {
    vec4 t = texture2D(uBitmap, vUv).bgra;
    gl_FragColor = vec4(t.rgb, t.a * vCol.a);
  } else if (m < 4.5) {
    // (the pixel's own place, from the top left, as the CPU counts: not
    // gl_FragCoord, whose rows a driver may count from either end)
    vec2 p = floor(vPos / vMode.y);
    if (mod(p.x + p.y, 2.0) > 0.5) discard;
    gl_FragColor = vCol;
  } else if (m < 5.5) {
    float t = mod(floor(vUv.x) + floor(vUv.y) + vMode.y, 8.0);
    gl_FragColor = t < 4.0 ? vec4(0.0, 0.0, 0.0, 1.0) : vec4(1.0, 1.0, 1.0, 1.0);
  } else {
    if (mod(floor(vUv.x) + floor(vUv.y), 2.0) > 0.5) discard;
    gl_FragColor = vCol;
  }
}
"""

proc compile(kind: GLenum; src: string; needHigh = false): GLuint =
  ## (`needHigh`: a fragment shader that must have 32-bit floats: on an ES
  ## GPU without them it does not compile)
  let low = if needHigh and kind == GL_FRAGMENT_SHADER: "#error no highp floats\n"
            else: "precision mediump float;\n"
  let head = if gl.es: "#version 100\n#ifdef GL_FRAGMENT_PRECISION_HIGH\nprecision highp float;\n" &
                       "#else\n" & low & "#endif\n"
             else: "#version 110\n"
  let full = head & src
  result = gl.createShader(kind)
  var cs = cstring(full)
  gl.shaderSource(result, 1, addr cs, nil)
  gl.compileShader(result)
  var ok: GLint
  gl.getShaderiv(result, GL_COMPILE_STATUS, addr ok)
  if ok == 0:
    var log = newString(2048)
    var n: GLsizei
    gl.getShaderInfoLog(result, 2048, addr n, cstring(log))
    gpuDebug("shader: " & log[0 ..< max(0, n)])
    gl.deleteShader(result)
    result = 0

proc makeProgram(): bool =
  let vs = compile(GL_VERTEX_SHADER, VertexSrc)
  let fs = compile(GL_FRAGMENT_SHADER, FragmentSrc)
  if vs == 0 or fs == 0: return false
  prog = gl.createProgram()
  gl.attachShader(prog, vs)
  gl.attachShader(prog, fs)
  gl.bindAttribLocation(prog, 0, "aPos")
  gl.bindAttribLocation(prog, 1, "aUv")
  gl.bindAttribLocation(prog, 2, "aCol")
  gl.bindAttribLocation(prog, 3, "aMode")
  gl.linkProgram(prog)
  gl.deleteShader(vs)
  gl.deleteShader(fs)
  var ok: GLint
  gl.getProgramiv(prog, GL_LINK_STATUS, addr ok)
  if ok == 0: return false
  gl.useProgram(prog)
  gl.uniform1i(gl.getUniformLocation(prog, "uMask"), 0)
  gl.uniform1i(gl.getUniformLocation(prog, "uColor"), 1)
  gl.uniform1i(gl.getUniformLocation(prog, "uBitmap"), 2)
  uScaleLoc = gl.getUniformLocation(prog, "uScale")
  gl.genBuffers(1, addr vbo)
  true

proc newTexture(w, h: int; fmt: GLenum; filter = GL_NEAREST; data: pointer = nil): GLuint =
  gl.genTextures(1, addr result)
  gl.bindTexture(GL_TEXTURE_2D, result)
  gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, filter)
  gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, filter)
  gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
  gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
  gl.texImage2D(GL_TEXTURE_2D, 0, GLint(fmt), GLsizei(w), GLsizei(h), 0, fmt, GL_UNSIGNED_BYTE, data)

proc initAtlas(a: var Atlas; size: int; fmt: GLenum) =
  a.size = size
  a.fmt = fmt
  a.tex = newTexture(size, size, fmt)
  a.curX = 0
  a.curY = 0
  a.shelfH = 0
  a.map.clear()

proc dropGpuState() =
  ## Everything made on the GPU forgotten (a lost context: it is gone).
  inc gpuEpochN
  prog = 0
  vbo = 0
  maskAtlas = Atlas()
  colorAtlas = Atlas()
  texCache.clear()
  tempTextures.setLen(0)
  lastVerts.setLen(0)
  lastBatches.setLen(0)
  keptFbo = 0
  keptTex = 0
  keptW = 0
  keptH = 0
  keptValid = false
  intoKept = false
  partHistN = 0
  blitProg = 0
  blitVbo = 0
  blitTried = false
  screenStale = false

proc freeGpuState() =
  ## Everything made on the GPU given back (the context stays).
  if not gl.ok: return
  for e in texCache.values:
    for t in e.tiles:
      var id = t.tex
      gl.deleteTextures(1, addr id)
  for a in [addr maskAtlas, addr colorAtlas]:
    if a.tex != 0: gl.deleteTextures(1, addr a.tex)
  if vbo != 0: gl.deleteBuffers(1, addr vbo)
  if prog != 0: gl.deleteProgram(prog)
  if keptFbo != 0 and gl.deleteFramebuffers != nil: gl.deleteFramebuffers(1, addr keptFbo)
  if keptTex != 0: gl.deleteTextures(1, addr keptTex)
  if blitVbo != 0: gl.deleteBuffers(1, addr blitVbo)
  if blitProg != 0: gl.deleteProgram(blitProg)
  dropGpuState()

# ---- drawing ------------------------------------------------------------------------------------

proc flushDraw() =
  ## The rectangles so far drawn.
  if verts.len == 0:
    batches.setLen(0)
    return
  gl.bindBuffer(GL_ARRAY_BUFFER, vbo)
  gl.bufferData(GL_ARRAY_BUFFER, verts.len * sizeof(Vtx), addr verts[0], GL_STREAM_DRAW)
  let st = GLsizei(sizeof(Vtx))
  gl.vertexAttribPointer(0, 2, GL_FLOAT, 0, st, cast[pointer](0))
  gl.vertexAttribPointer(1, 2, GL_FLOAT, 0, st, cast[pointer](8))
  gl.vertexAttribPointer(2, 4, GL_UNSIGNED_BYTE, 1, st, cast[pointer](16))
  gl.vertexAttribPointer(3, 4, GL_UNSIGNED_BYTE, 0, st, cast[pointer](20))
  for i in 0'u32 .. 3'u32: gl.enableVertexAttribArray(i)
  gl.activeTexture(GL_TEXTURE0 + 2)
  var blendNow = 0'u32
  var texNow = GLuint(0)
  var filterNow = GLint(-1)
  for b in batches:
    if b.count <= 0: continue
    if b.lcd != blendNow:
      # (strips: the text's color times each strip's coverage, over what is
      # there times the rest -- one pass, the color the blend constant)
      if b.lcd != 0:
        gl.blendFunc(GL_CONSTANT_COLOR, GL_ONE_MINUS_SRC_COLOR)
        gl.blendColor(GLf32((b.lcd shr 16) and 255) / 255, GLf32((b.lcd shr 8) and 255) / 255,
                      GLf32(b.lcd and 255) / 255, 1)
      else:
        gl.blendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
      blendNow = b.lcd
    if b.tex != 0 and (b.tex != texNow or b.filter != filterNow):
      # (a picture's texture: bound and its filter set only when another)
      gl.bindTexture(GL_TEXTURE_2D, b.tex)
      gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, b.filter)
      gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, b.filter)
      texNow = b.tex
      filterNow = b.filter
    gl.drawArrays(GL_TRIANGLES, GLint(b.first), GLsizei(b.count))
  if blendNow != 0: gl.blendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
  if not intoKept and not directPart:
    # (drawn onto the screen: `overlayNow` draws this again under what it shows)
    for b in batches: lastBatches.add (b.first + lastVerts.len, b.count, b.tex, b.filter, b.lcd)
    lastVerts.add verts
  verts.setLen(0)
  batches.setLen(0)

proc quad(x0, y0, x1, y1, u0, v0, u1, v1: float32; col: uint32; alpha: uint8; mode: uint8;
          clip: Rect; p1 = 0'u8; tex: GLuint = 0; filter = GL_NEAREST; lcd = 0'u32) =
  ## A rectangle (device pixels), clipped, its texture coordinates cut with it.
  let cx0 = max(x0, float32(clip.x))
  let cy0 = max(y0, float32(clip.y))
  let cx1 = min(x1, float32(clip.x + clip.w))
  let cy1 = min(y1, float32(clip.y + clip.h))
  if cx0 >= cx1 or cy0 >= cy1: return
  var nu0 = u0
  var nv0 = v0
  var nu1 = u1
  var nv1 = v1
  if x1 > x0 and (cx0 != x0 or cx1 != x1):
    let du = (u1 - u0) / (x1 - x0)
    nu0 = u0 + (cx0 - x0) * du
    nu1 = u0 + (cx1 - x0) * du
  if y1 > y0 and (cy0 != y0 or cy1 != y1):
    let dv = (v1 - v0) / (y1 - y0)
    nv0 = v0 + (cy0 - y0) * dv
    nv1 = v0 + (cy1 - y0) * dv
  if batches.len > 0 and batches[^1].lcd != lcd:
    batches.add (verts.len, 0, tex, filter, lcd)
  elif tex != 0 and (batches.len == 0 or batches[^1].tex != tex or batches[^1].filter != filter):
    if batches.len > 0 and batches[^1].tex == 0:
      batches[^1].tex = tex
      batches[^1].filter = filter
    else:
      batches.add (verts.len, 0, tex, filter, lcd)
  elif batches.len == 0:
    batches.add (verts.len, 0, GLuint(0), GL_NEAREST, lcd)
  let c = [uint8((col shr 16) and 255), uint8((col shr 8) and 255), uint8(col and 255), alpha]
  let md = [mode, p1, 0'u8, 0'u8]
  template v(px, py, pu, pv: float32) =
    verts.add Vtx(x: px, y: py, u: pu, v: pv, col: c, mode: md)
  v(cx0, cy0, nu0, nv0); v(cx1, cy0, nu1, nv0); v(cx1, cy1, nu1, nv1)
  v(cx0, cy0, nu0, nv0); v(cx1, cy1, nu1, nv1); v(cx0, cy1, nu0, nv1)
  batches[^1].count += 6

proc resetAtlas(a: var Atlas) =
  flushDraw()                     # (what was drawn from it first)
  a.curX = 0
  a.curY = 0
  a.shelfH = 0
  a.map.clear()

proc atlasPut(a: var Atlas; key: uint64; w, h: int; data: pointer): AtlasEntry =
  ## Room in the atlas for a `w` x `h` picture (sent to the GPU); the room
  ## it already has when `key` is there. `w` < 0 when it is too big.
  a.map.withValue(key, e):
    return e[]
  if w <= 0 or h <= 0 or w > a.size or h > a.size: return (0'i32, 0'i32, -1'i32, -1'i32)   # (`w` < 0: too big)
  if a.curX + w > a.size:
    a.curY += a.shelfH
    a.curX = 0
    a.shelfH = 0
  if a.curY + h > a.size:
    resetAtlas(a)
  gl.activeTexture(GL_TEXTURE0 + (if a.fmt == GL_ALPHA: 0'u32 else: 1'u32))
  gl.bindTexture(GL_TEXTURE_2D, a.tex)
  gl.pixelStorei(GL_UNPACK_ALIGNMENT, 1)
  gl.texSubImage2D(GL_TEXTURE_2D, 0, GLint(a.curX), GLint(a.curY), GLsizei(w), GLsizei(h),
                   a.fmt, GL_UNSIGNED_BYTE, data)
  result = (int32(a.curX), int32(a.curY), int32(w), int32(h))
  a.map[key] = result
  a.curX += w + 1
  a.shelfH = max(a.shelfH, h + 1)

proc atlasQuad(a: Atlas; e: AtlasEntry; x, y, w, h: float32; col: uint32; alpha: uint8;
               clip: Rect; lcd = 0'u32) =
  ## Atlas picture `e` drawn at `x`, `y`, `w` x `h` device pixels.
  let k = 1'f32 / float32(a.size)
  quad(x, y, x + w, y + h, float32(e.x) * k, float32(e.y) * k, float32(e.x + e.w) * k,
       float32(e.y + e.h) * k, col, alpha, if a.fmt == GL_ALPHA: ModeMask else: ModeColor, clip,
       lcd = lcd)

proc lcdQuad(key: uint64; m: ptr Mask; x, y: int; col: uint32; clip: Rect;
             lut: ptr array[256, uint8]): bool =
  ## A glyph in the screen's color strips (`Mask.lcd`) at `x`, `y`: its
  ## coverage as the colors of a picture in the color atlas, mixed by the
  ## blend (see `flushDraw`). False when the GPU cannot (no glBlendColor).
  if gl.blendColor == nil: return false
  result = true
  if m.w <= 0 or m.h <= 0 or m.a.len < 3 * m.w * m.h: return
  var e: AtlasEntry
  colorAtlas.map.withValue(key, found):
    e = found[]
  do:
    scratchPx.setLen(m.w * m.h)
    for i in 0 ..< m.w * m.h:
      var r = m.a[3 * i]
      var g = m.a[3 * i + 1]
      var b = m.a[3 * i + 2]
      if lut != nil:
        r = lut[r]; g = lut[g]; b = lut[b]
      scratchPx[i] = 0xFF000000'u32 or (uint32(r) shl 16) or (uint32(g) shl 8) or uint32(b)
    e = colorAtlas.atlasPut(key, m.w, m.h, addr scratchPx[0])
  if e.w < 0: return
  colorAtlas.atlasQuad(e, float32(x), float32(y), float32(m.w), float32(m.h), 0xFFFFFF'u32, 255,
                       clip, lcd = (col and 0xFFFFFF'u32) or (1'u32 shl 24))

proc maskQuad(key: uint64; m: ptr Mask; x, y: int; col: uint32; clip: Rect;
              lut: ptr array[256, uint8] = nil) =
  ## A coverage mask at `x`, `y` (device pixels) in `col`.
  if m.w <= 0 or m.h <= 0 or m.a.len < m.w * m.h: return
  var data = unsafeAddr m.a[0]
  if lut != nil:
    scratchBytes.setLen(m.w * m.h)
    for i in 0 ..< m.w * m.h: scratchBytes[i] = lut[m.a[i]]
    data = addr scratchBytes[0]
  let e = maskAtlas.atlasPut(key, m.w, m.h, data)
  if e.w < 0:
    # (bigger than the atlas: a texture of its own, for this frame -- what
    # was drawn from the atlas before it drawn first, while it is bound)
    flushDraw()
    gl.activeTexture(GL_TEXTURE0)
    gl.pixelStorei(GL_UNPACK_ALIGNMENT, 1)
    let t = newTexture(m.w, m.h, GL_ALPHA, data = data)
    tempTextures.add t
    quad(float32(x), float32(y), float32(x + m.w), float32(y + m.h), 0, 0, 1, 1, col, 255,
         ModeMask, clip)
    # (drawn at once with the texture on the mask unit, then the atlas again)
    flushDraw()
    gl.activeTexture(GL_TEXTURE0)
    gl.bindTexture(GL_TEXTURE_2D, maskAtlas.tex)
    return
  maskAtlas.atlasQuad(e, float32(x), float32(y), float32(m.w), float32(m.h), col, 255, clip)

proc bitsMask(key: uint64; w, h: int; build: proc (put: proc (x, y: int) {.closure.}) {.closure.}): AtlasEntry =
  ## A mask made from pixels (a bitmap glyph, an icon's shape), in the atlas.
  maskAtlas.map.withValue(key, e):
    return e[]
  scratchBytes.setLen(w * h)
  for b in scratchBytes.mitems: b = 0
  build(proc (x, y: int) =
    if x >= 0 and y >= 0 and x < w and y < h: scratchBytes[y * w + x] = 255)
  maskAtlas.atlasPut(key, w, h, addr scratchBytes[0])

proc gpuSysText(c: Cmd; clip: Rect) =
  ## The platform's text (scripts the built-in fonts lack), as the driver
  ## hands it out (`renderText`): its coverage in the mask atlas, in the
  ## text's color. (A driver without it: not drawn on the GPU.)
  let run = sysRunOf(arena[c.a ..< c.a + c.b])
  if run == nil or run.w <= 0 or run.h <= 0: return
  var key = 0xcbf29ce484222325'u64
  for ch in arena[c.a ..< c.a + c.b]: key = (key xor ord(ch).uint64) * 0x100000001B3'u64
  key = (7'u64 shl 56) xor (key shr 8) xor uint64(FontH * pxScale)
  let e = maskAtlas.atlasPut(key, run.w, run.h, addr run.cover[0])
  if e.w < 0: return
  let y = c.r.y * pxScale + max(0, (c.r.h * pxScale - run.h) div 2)
  maskAtlas.atlasQuad(e, float32(c.r.x * pxScale), float32(y), float32(run.w), float32(run.h),
                      c.color, 255, clip)

proc gpuVText(c: Cmd; clip: Rect) =
  ## Vector text: the glyphs made ready as for the CPU, their masks drawn.
  var cc = c
  prepVText(cc)
  let sp = prepSpans[cc.mag - 1]
  let lut = lutFor(c.color, sp.emDev < 20)
  let lutBits = if lut == nil: 0'u64 else: 1'u64
  let st = styleOf(c.flags, c.size)
  for i in sp.a ..< sp.a + sp.n:
    let g = prepGlyphs[i]
    let m = maskAt(g.slot)
    var key = if g.slot >= 0: maskKeys[g.slot] or (lutBits shl 61)
              else: (0x7F'u64 shl 56) or (uint64(gpuFrame and 0xFFFF) shl 24) or uint64(-g.slot) or
                    (lutBits shl 61)
    if m.lcd:
      # (in the color atlas: kept apart from its pictures by bit 60)
      if lcdQuad(key or (1'u64 shl 60), m, int(g.x), int(g.y), c.color, clip, lut): continue
      # (a GPU without the blend color: its strips' middle, as gray)
      var gray = Mask(w: m.w, h: m.h, left: m.left, top: m.top)
      gray.a = newSeq[uint8](m.w * m.h)
      for j in 0 ..< m.w * m.h: gray.a[j] = m.a[3 * j + 1]
      maskQuad(key, addr gray, int(g.x), int(g.y), c.color, clip, lut)
      continue
    maskQuad(key, m, int(g.x), int(g.y), c.color, clip, lut)
  if st.underline or st.strike:
    let emDev = sp.emDev
    let base = int(sp.base)
    let t = max(1, int(round(emDev / 14)))
    let w = c.r.w * pxScale
    if st.underline:
      let y = base + max(1, int(round(emDev * 0.09)))
      quad(float32(c.r.x * pxScale), float32(y), float32(c.r.x * pxScale + w), float32(y + t),
           0, 0, 0, 0, c.color, 255, ModeSolid, clip)
    if st.strike:
      let y = base - int(round(emDev * 0.3))
      quad(float32(c.r.x * pxScale), float32(y), float32(c.r.x * pxScale + w), float32(y + t),
           0, 0, 0, 0, c.color, 255, ModeSolid, clip)

proc gpuPath(c: Cmd; screen: Rect) =
  # (kept in its clip, as the CPU draws it: a canvas's shapes stay out of the
  # bars over and under it)
  let clip = intersect(screen, devClip(c.clip))
  let cl = intersect(clip, devClip(c.r))
  if cl.w <= 0 or cl.h <= 0: return
  let al = c.color shr 24
  # (a see-through rectangle, as `fill` makes them: a rectangle)
  if c.b == 10:
    template p: untyped = pathArena          # (not a copy of the whole arena per shape)
    let a = c.a.int
    let s = float32(pxScale)
    let xs = [p[a] * s, p[a + 2] * s, p[a + 4] * s, p[a + 6] * s]
    let ys = [p[a + 1] * s, p[a + 3] * s, p[a + 5] * s, p[a + 7] * s]
    if xs[0] == xs[3] and xs[1] == xs[2] and ys[0] == ys[1] and ys[2] == ys[3] and
       xs[0] == round(xs[0]) and xs[1] == round(xs[1]) and ys[0] == round(ys[0]) and ys[2] == round(ys[2]):
      quad(min(xs[0], xs[1]), min(ys[0], ys[2]), max(xs[0], xs[1]), max(ys[0], ys[2]), 0, 0, 0, 0,
           c.color and 0xFFFFFF'u32, if al == 0: 255'u8 else: uint8(al), ModeSolid, clip)
      return
  # (the shape's mask is what it covers of `cl` at this scale: one already in
  # the atlas is drawn as it is, not rasterized again every frame)
  var key = c.h
  mixRect(key, cl)
  mix(key, uint64(pxScale))
  key = (4'u64 shl 56) xor (key shr 8)
  maskAtlas.map.withValue(key, e):
    maskAtlas.atlasQuad(e[], float32(cl.x - 1), float32(cl.y), float32(e.w), float32(e.h),
                        c.color and 0xFFFFFF'u32, 255, clip)
    return
  let m = pathMask(c, cl)
  maskQuad(key, unsafeAddr m, cl.x - 1, cl.y, c.color and 0xFFFFFF'u32, clip)

proc gpuDots(c: Cmd; clip: Rect) =
  let s = pxScale
  let r = c.r
  let cl = intersect(clip, devClip(c.clip))
  template q(x, y, w, h: int) =
    quad(float32(x * s), float32(y * s), float32((x + w) * s), float32((y + h) * s), 0, 0, 0, 0,
         c.color, 255, ModeChecker, cl, uint8(s))
  if c.bold:
    q(r.x, r.y, r.w, r.h)
  else:
    q(r.x, r.y, r.w, 1)
    if r.h > 1: q(r.x, r.y + r.h - 1, r.w, 1)
    if r.h > 2:
      q(r.x, r.y + 1, 1, r.h - 2)
      q(r.x + r.w - 1, r.y + 1, 1, r.h - 2)

proc gpuLine(c: Cmd; clip: Rect) =
  let cl = intersect(clip, devClip(c.clip))
  let s = pxScale
  var x = c.r.x
  var y = c.r.y
  let x2 = c.r.w
  let y2 = c.r.h
  let dx = abs(x2 - x)
  let dy = -abs(y2 - y)
  let sx = if x < x2: 1 else: -1
  let sy = if y < y2: 1 else: -1
  var err = dx + dy
  while true:
    quad(float32(x * s), float32(y * s), float32((x + 1) * s), float32((y + 1) * s), 0, 0, 0, 0,
         c.color, 255, ModeSolid, cl)
    if x == x2 and y == y2: break
    let e2 = 2 * err
    if e2 >= dy:
      err += dy
      x += sx
    if e2 <= dx:
      err += dx
      y += sy

proc colorPicture(key: uint64; w, h: int; src: proc (i: int): uint32 {.closure.}): AtlasEntry =
  ## A picture in the color atlas (alpha 0 or 255, as the CPU draws icons).
  colorAtlas.map.withValue(key, e):
    return e[]
  scratchPx.setLen(w * h)
  for i in 0 ..< w * h:
    let p = src(i)
    scratchPx[i] = if (p shr 24) != 0: p or 0xFF000000'u32 else: 0'u32
  colorAtlas.atlasPut(key, w, h, addr scratchPx[0])

proc gpuImage(c: Cmd; clip: Rect) =
  let cl = intersect(clip, devClip(c.clip))
  let m = max(1, c.mag.int)
  let w = c.b.int
  let h = c.r.h div m
  if w <= 0 or h <= 0: return
  var key = 0xcbf29ce484222325'u64
  for i in 0 ..< w * h: key = (key xor uint64(imgArena[c.a.int + i])) * 0x100000001B3'u64
  key = (5'u64 shl 56) xor (key shr 8) xor uint64(w)
  let a = c.a.int
  let e = colorPicture(key, w, h, proc (i: int): uint32 = imgArena[a + i])
  if e.w < 0: return
  let s = pxScale * m
  colorAtlas.atlasQuad(e, float32(c.r.x * pxScale), float32(c.r.y * pxScale), float32(w * s),
                       float32(h * s), 0, 255, cl)

proc gpuPixIcon(c: Cmd; clip: Rect) =
  let cl = intersect(clip, devClip(c.clip))
  if cl.w <= 0 or cl.h <= 0 or c.a < 0 or c.a.int >= pixIcons.len: return
  let boxW = c.r.w * pxScale
  let boxH = c.r.h * pxScale
  let (big, f0, size) = pixArt(c.a.int, if c.r.w > c.r.h * 2: boxH else: min(boxW + 2 * pxScale, boxH))
  let ic0 = if big: addr pixIcons[c.a].big else: addr pixIcons[c.a].small
  if ic0.w <= 0 or ic0.px.len < ic0.w * ic0.h: return
  let ox = c.r.x * pxScale + (boxW - size) div 2
  let oy = c.r.y * pxScale + (boxH - size) div 2
  let d0 = max(1, f0 div 2)
  let (ic, f) = hdArt(ic0, c.a.int, big, f0)
  let iw = ic.w
  let ih = ic.h
  let hk = uint64(iw) shl 40          # (the HD art: another picture)
  if c.flags != 0:
    # disabled: the dark pixels embossed (white, then gray one pixel up-left)
    let key = (7'u64 shl 56) or (uint64(c.a) shl 1) or uint64(ord(big)) or hk
    let px = ic.px
    let e = bitsMask(key, iw, ih, proc (put: proc (x, y: int) {.closure.}) =
      for j in 0 ..< ih:
        for i in 0 ..< iw:
          let p = px[j * iw + i]
          if (p shr 24) == 0: continue
          let luma = ((p shr 16) and 0xFF) * 3 + ((p shr 8) and 0xFF) * 6 + (p and 0xFF)
          if luma < 1300: put(i, j))
    if e.w < 0: return
    let d = float32(d0)
    maskAtlas.atlasQuad(e, float32(ox) + d, float32(oy) + d, float32(iw * f), float32(ih * f),
                        0xFFFFFF'u32, 255, cl)
    maskAtlas.atlasQuad(e, float32(ox), float32(oy), float32(iw * f), float32(ih * f),
                        0x808080'u32, 255, cl)
    return
  let key = (6'u64 shl 56) or (uint64(c.a) shl 1) or uint64(ord(big)) or hk
  let px = ic.px
  let e = colorPicture(key, iw, ih, proc (i: int): uint32 = px[i])
  if e.w < 0: return
  colorAtlas.atlasQuad(e, float32(ox), float32(oy), float32(iw * f), float32(ih * f), 0, 255, cl)

proc uploadRows(t: TexTile; px: ptr UncheckedArray[uint32]; pw: int; y0, y1: int; full: bool) =
  ## Rows `y0 ..< y1` of the pixels (`pw` wide) that are in tile `t`, sent
  ## (all of the tile when `full`).
  let ra = if full: t.y else: max(y0, t.y)
  let rb = if full: t.y + t.h else: min(y1, t.y + t.h)
  if rb <= ra: return
  gl.bindTexture(GL_TEXTURE_2D, t.tex)
  gl.pixelStorei(GL_UNPACK_ALIGNMENT, 4)
  var p: pointer
  if t.x == 0 and t.w == pw:
    p = addr px[ra * pw]
  else:
    scratchPx.setLen(t.w * (rb - ra))
    for y in ra ..< rb:
      copyMem(addr scratchPx[(y - ra) * t.w], addr px[y * pw + t.x], t.w * 4)
    p = addr scratchPx[0]
  if full:
    gl.texImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA), GLsizei(t.w), GLsizei(t.h), 0, GL_RGBA,
                  GL_UNSIGNED_BYTE, p)
  else:
    gl.texSubImage2D(GL_TEXTURE_2D, 0, 0, GLint(ra - t.y), GLsizei(t.w), GLsizei(rb - ra), GL_RGBA,
                     GL_UNSIGNED_BYTE, p)

proc syncPixels(e: var TexEntry; px: ptr UncheckedArray[uint32]; w, h: int; dirty: Rect; whole: bool) =
  ## The textures of a picture brought up to date: made again (in tiles no
  ## bigger than the GPU takes) when `whole` or of another size, else only
  ## the rows of `dirty` sent.
  e.used = gpuFrame
  gl.activeTexture(GL_TEXTURE0 + 2)
  if whole or e.w != w or e.h != h or e.tiles.len == 0:
    for t in e.tiles:
      var id = t.tex
      gl.deleteTextures(1, addr id)
    e.tiles.setLen(0)
    e.w = w
    e.h = h
    let ts = max(64, maxTex)
    var y = 0
    while y < h:
      var x = 0
      let th = min(ts, h - y)
      while x < w:
        let tw = min(ts, w - x)
        let t: TexTile = (newTexture(tw, th, GL_RGBA), x, y, tw, th, GL_NEAREST)
        uploadRows(t, px, w, 0, 0, true)
        e.tiles.add t
        x += tw
      y += th
  elif dirty.w > 0 and dirty.h > 0:
    for t in e.tiles:
      if dirty.x < t.x + t.w and dirty.x + dirty.w > t.x:
        uploadRows(t, px, w, dirty.y, dirty.y + dirty.h, false)

proc syncBitmap(b: Bitmap): ptr TexEntry =
  ## The bitmap's textures, brought up to date (only the rows that changed
  ## sent again, when that is all).
  let key = cast[pointer](b)
  result = addr texCache.mgetOrPut(key, TexEntry())
  let px = cast[ptr UncheckedArray[uint32]](unsafeAddr b.px[0])
  if result.whole != b.whole or result.tiles.len == 0 or result.w != b.w or result.h != b.h:
    syncPixels(result[], px, b.w, b.h, rect(0, 0, 0, 0), true)
    result.whole = b.whole
    result.stamp = b.stamp
  elif result.stamp != b.stamp:
    syncPixels(result[], px, b.w, b.h, (if b.dirty.w > 0: b.dirty else: rect(0, 0, b.w, b.h)), false)
    result.stamp = b.stamp
  result.used = gpuFrame

proc beginGpuFrame(): bool

proc gpuImage*(key: uint64; w, h: int; px: ptr UncheckedArray[uint32]; changed: Rect;
               whole = false) =
  ## (with the GPU) A picture of the app's own -- a document as it looks --
  ## sent to the GPU now, while its pixels are there: all of it when
  ## `whole` (or new, or of another size), else the rows of `changed`.
  ## `drawGpuImage` draws it; nothing happens when the CPU draws.
  if not gpuOn or px == nil or w <= 0 or h <= 0: return
  if gpuGen < 0 and not beginGpuFrame(): return       # (the GPU's things made first)
  let e = addr texCache.mgetOrPut(cast[pointer](key), TexEntry())
  syncPixels(e[], px, w, h, intersect(changed, rect(0, 0, w, h)), whole)

proc gpuBitmap(c: Cmd; clip: Rect) =
  let b = frameBitmaps[c.a]
  if b.px.len < b.w * b.h or b.w <= 0 or b.h <= 0: return
  let cl = intersect(clip, devClip(c.clip))
  let s = float32(pxScale)
  let dx = float32(c.r.x) * s
  let dy = float32(c.r.y) * s
  let dw = float32(c.r.w) * s
  let dh = float32(c.r.h) * s
  let e = syncBitmap(b)
  let filter = if dw >= float32(b.w) and dh >= float32(b.h): GL_NEAREST else: GL_LINEAR
  let kx = dw / float32(b.w)
  let ky = dh / float32(b.h)
  for t in e.tiles:
    quad(dx + float32(t.x) * kx, dy + float32(t.y) * ky, dx + float32(t.x + t.w) * kx,
         dy + float32(t.y + t.h) * ky, 0, 0, 1, 1, 0, 255, ModeBitmap, cl, tex = t.tex, filter = filter)

proc gpuTex(c: Cmd; clip: Rect) =
  ## A picture sent with `gpuImage`, at its device rectangle.
  let cl = intersect(clip, devClip(c.clip))
  let key = uint64(imgArena[c.a]) or (uint64(imgArena[c.a + 1]) shl 32)
  let p = texCache.getOrDefault(cast[pointer](key))
  if p.tiles.len == 0 or p.w <= 0 or p.h <= 0: return
  texCache[cast[pointer](key)].used = gpuFrame
  let dx = float32(cast[int32](imgArena[c.a + 2]))
  let dy = float32(cast[int32](imgArena[c.a + 3]))
  let dw = float32(cast[int32](imgArena[c.a + 4]))
  let dh = float32(cast[int32](imgArena[c.a + 5]))
  let filter = if (c.flags and 1) != 0: GL_LINEAR else: GL_NEAREST
  let kx = dw / float32(p.w)
  let ky = dh / float32(p.h)
  for t in p.tiles:
    quad(dx + float32(t.x) * kx, dy + float32(t.y) * ky, dx + float32(t.x + t.w) * kx,
         dy + float32(t.y + t.h) * ky, 0, 0, 1, 1, 0, 255, ModeBitmap, cl, tex = t.tex, filter = filter)

proc gpuChecker(c: Cmd; clip: Rect) =
  let cl = intersect(clip, devClip(c.clip))
  let x0 = float32(cast[int32](imgArena[c.a]))
  let y0 = float32(cast[int32](imgArena[c.a + 1]))
  let x1 = float32(cast[int32](imgArena[c.a + 2]))
  let y1 = float32(cast[int32](imgArena[c.a + 3]))
  let ox = float32(cast[int32](imgArena[c.a + 4]))
  let oy = float32(cast[int32](imgArena[c.a + 5]))
  let cell = float32(max(1, c.mag))
  let c0 = imgArena[c.a + 6]
  let c1 = imgArena[c.a + 7]
  quad(x0, y0, x1, y1, 0, 0, 0, 0, c1, 255, ModeSolid, cl)
  quad(x0, y0, x1, y1, (x0 - ox) / cell, (y0 - oy) / cell, (x1 - ox) / cell, (y1 - oy) / cell,
       c0, 255, ModeChecker2, cl)

proc gpuAnts(c: Cmd; clip: Rect) =
  let cl = intersect(clip, devClip(c.clip))
  let ox = int(cast[int32](imgArena[c.a]))
  let oy = int(cast[int32](imgArena[c.a + 1]))
  var i = c.a.int + 2
  let e = c.a.int + 2 + c.b.int
  while i + 3 < e:
    let x0 = float32(cast[int32](imgArena[i]))
    let y0 = float32(cast[int32](imgArena[i + 1]))
    let x1 = float32(cast[int32](imgArena[i + 2]))
    let y1 = float32(cast[int32](imgArena[i + 3]))
    quad(float32(ox) + x0, float32(oy) + y0, float32(ox) + x1, float32(oy) + y1, x0, y0, x1, y1,
         0, 255, ModeAnts, cl, uint8(c.mag))
    i += 4

proc gpuCmd(c: Cmd) =
  let screen = rect(0, 0, fbW, fbH)
  case c.kind
  of ckFill:
    quad(float32(c.r.x * pxScale), float32(c.r.y * pxScale), float32((c.r.x + c.r.w) * pxScale),
         float32((c.r.y + c.r.h) * pxScale), 0, 0, 0, 0, c.color, 255, ModeSolid, screen)
  of ckVText: gpuVText(c, devClip(c.clip))
  of ckPath: gpuPath(c, screen)
  of ckDots: gpuDots(c, screen)
  of ckImage: gpuImage(c, screen)
  of ckPixIcon: gpuPixIcon(c, screen)
  of ckBitmap: gpuBitmap(c, screen)
  of ckLine: gpuLine(c, screen)
  of ckAnts: gpuAnts(c, screen)
  of ckTex: gpuTex(c, screen)
  of ckChecker: gpuChecker(c, screen)
  of ckSysText: gpuSysText(c, devClip(c.clip))

proc beginGpuFrame(): bool =
  if gpuRelays.gpuReady != nil and not gpuRelays.gpuReady(): return false
  let g = if gpuRelays.gpuGeneration != nil: gpuRelays.gpuGeneration() else: 0
  if g != gpuGen:
    # (a new context: everything made again)
    dropGpuState()
    gpuGen = g
    if not makeProgram(): return false
    maskAtlas.initAtlas(AtlasMaskSize, GL_ALPHA)
    colorAtlas.initAtlas(AtlasColorSize, GL_RGBA)
  inc gpuFrame
  gl.useProgram(prog)
  gl.viewport(0, 0, GLsizei(fbW), GLsizei(fbH))
  gl.disable(GL_DEPTH_TEST)
  gl.disable(GL_CULL_FACE)
  gl.disable(GL_SCISSOR_TEST)
  gl.disable(GL_DITHER)
  gl.enable(GL_BLEND)
  gl.blendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
  gl.colorMask(1, 1, 1, 0)
  gl.uniform2f(uScaleLoc, 2'f32 / float32(fbW), 2'f32 / float32(fbH))
  gl.activeTexture(GL_TEXTURE0)
  gl.bindTexture(GL_TEXTURE_2D, maskAtlas.tex)
  gl.activeTexture(GL_TEXTURE0 + 1)
  gl.bindTexture(GL_TEXTURE_2D, colorAtlas.tex)
  verts.setLen(0)
  batches.setLen(0)
  bandClip = rect(0, 0, fbW, fbH)
  true

proc endGpuFrame(changed: openArray[Rect] = []): bool =
  ## The frame put on the screen (told what `changed` since the last, when
  ## that is known); false when the context was lost.
  flushDraw()
  for t in tempTextures:
    var id = t
    gl.deleteTextures(1, addr id)
  tempTextures.setLen(0)
  # textures of bitmaps not drawn for a while given back; and past the
  # budget, the least recently drawn at once
  if gpuFrame mod 16 == 0:
    var gone: seq[pointer]
    var all: seq[(int, int, pointer)]           # (used, bytes, key)
    var total = 0
    for k, e in texCache:
      var bytes = 0
      for t in e.tiles: bytes += t.w * t.h * 4
      if gpuFrame - e.used > 120 and gpuFrame mod 64 == 0: gone.add k
      else:
        total += bytes
        all.add (e.used, bytes, k)
    if total > gpuTextureBudget:
      all.sort(proc (a, b: (int, int, pointer)): int = cmp(a[0], b[0]))
      for (used, bytes, k) in all:
        if total <= gpuTextureBudget * 3 div 4 or used >= gpuFrame - 1: break
        gone.add k
        total -= bytes
    for k in gone:
      if not texCache[k].outside:
        for t in texCache[k].tiles:
          var id = t.tex
          gl.deleteTextures(1, addr id)
      texCache.del k
  result = if changed.len > 0 and gpuRelays.swapGpuDamage != nil: gpuRelays.swapGpuDamage(changed)
           else: gpuRelays.swapGpu == nil or gpuRelays.swapGpu()
  if result and gpuFramesOk < 30:
    inc gpuFramesOk
    if gpuFramesOk == 30 and gpuGuardPath.len > 0:
      try: removeFile(gpuGuardPath) except CatchableError: discard

const BlitVertex = """
attribute vec2 aPos;
varying vec2 vUv;
void main() {
  gl_Position = vec4(aPos * 2.0 - 1.0, 0.0, 1.0);
  vUv = aPos;
}
"""

const BlitFragment = """
uniform sampler2D uFrame;
varying vec2 vUv;
void main() {
  gl_FragColor = vec4(texture2D(uFrame, vUv).rgb, 1.0);
}
"""

proc makeBlit(): bool =
  ## The program that puts the kept frame on the screen. It must have 32-bit
  ## floats (to land on every pixel of a big screen exactly), and the GPU
  ## framebuffers to draw into a texture: else no frame is kept.
  blitTried = true
  if getEnv("RETRO_GPU_KEEP") == "0": return false
  if gl.genFramebuffers == nil or gl.bindFramebuffer == nil or gl.framebufferTexture2D == nil or
     gl.checkFramebufferStatus == nil or gl.deleteFramebuffers == nil or
     gl.disableVertexAttribArray == nil: return false
  let vs = compile(GL_VERTEX_SHADER, BlitVertex)
  let fs = compile(GL_FRAGMENT_SHADER, BlitFragment, needHigh = true)
  if vs == 0 or fs == 0:
    if vs != 0: gl.deleteShader(vs)
    if fs != 0: gl.deleteShader(fs)
    return false
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
  gl.useProgram(p)
  gl.uniform1i(gl.getUniformLocation(p, "uFrame"), 2)
  gl.useProgram(prog)
  var corners = [0'f32, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1]
  gl.genBuffers(1, addr blitVbo)
  gl.bindBuffer(GL_ARRAY_BUFFER, blitVbo)
  gl.bufferData(GL_ARRAY_BUFFER, sizeof(corners), addr corners[0], GL_STREAM_DRAW)
  blitProg = p
  gpuDebug("the frame is kept on the GPU: only what changes is drawn again")
  true

proc keepFrame(): bool =
  ## The kept frame, at the screen's size (made anew when that changed: then
  ## all of it is drawn into it); false where the GPU cannot keep one.
  if blitProg == 0: return false
  if keptFbo != 0 and keptW == fbW and keptH == fbH: return true
  if keptFbo != 0: gl.deleteFramebuffers(1, addr keptFbo)
  if keptTex != 0: gl.deleteTextures(1, addr keptTex)
  keptFbo = 0
  keptTex = 0
  if fbW > maxTex or fbH > maxTex: return false
  gl.activeTexture(GL_TEXTURE0 + 2)
  keptTex = newTexture(fbW, fbH, GL_RGBA)
  gl.bindTexture(GL_TEXTURE_2D, 0)
  gl.genFramebuffers(1, addr keptFbo)
  gl.bindFramebuffer(GL_FRAMEBUFFER, keptFbo)
  gl.framebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, keptTex, 0)
  let ok = gl.checkFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
  gl.bindFramebuffer(GL_FRAMEBUFFER, GLuint(screenFb))
  if not ok:
    gpuDebug("no framebuffer for the kept frame: every frame is drawn whole")
    gl.deleteFramebuffers(1, addr keptFbo)
    gl.deleteTextures(1, addr keptTex)
    keptFbo = 0
    keptTex = 0
    gl.deleteProgram(blitProg)
    blitProg = 0
    return false
  keptW = fbW
  keptH = fbH
  keptValid = false
  true

proc blitKept(parts: openArray[Rect] = []) =
  ## The kept frame onto the screen's framebuffer (bound now): all of it, or
  ## only `parts` (device rectangles) where the screen has the rest.
  gl.disable(GL_BLEND)
  gl.colorMask(1, 1, 1, 1)
  gl.useProgram(blitProg)
  gl.activeTexture(GL_TEXTURE0 + 2)
  gl.bindTexture(GL_TEXTURE_2D, keptTex)
  gl.bindBuffer(GL_ARRAY_BUFFER, blitVbo)
  for i in 1'u32 .. 3'u32: gl.disableVertexAttribArray(i)
  gl.vertexAttribPointer(0, 2, GL_FLOAT, 0, 8, nil)
  gl.enableVertexAttribArray(0)
  if parts.len == 0:
    gl.disable(GL_SCISSOR_TEST)
    gl.drawArrays(GL_TRIANGLES, 0, 6)
  else:
    gl.enable(GL_SCISSOR_TEST)
    for p in parts:
      gl.scissor(GLint(p.x), GLint(fbH - p.y - p.h), GLsizei(p.w), GLsizei(p.h))
      gl.drawArrays(GL_TRIANGLES, 0, 6)
    gl.disable(GL_SCISSOR_TEST)
  # (not left on a unit while the next frame is drawn into it)
  gl.bindTexture(GL_TEXTURE_2D, 0)
  gl.useProgram(prog)
  gl.enable(GL_BLEND)
  gl.colorMask(1, 1, 1, 0)

proc gpuKeepAlive(c: Cmd) =
  ## (a picture outside what is drawn again is still on the screen: its
  ## texture is kept as if it had been drawn)
  case c.kind
  of ckBitmap:
    texCache.withValue(cast[pointer](frameBitmaps[c.a]), e): e.used = gpuFrame
  of ckTex:
    let key = uint64(imgArena[c.a]) or (uint64(imgArena[c.a + 1]) shl 32)
    texCache.withValue(cast[pointer](key), e): e.used = gpuFrame
  else: discard

# What changed is drawn in a few rectangles: the runs of tiles that changed,
# gathered into at most `MaxParts` (a caret and a lit button far apart are
# two small ones, not the room between them). Where the screen's own buffer
# keeps its pixels from frame to frame (`gpuBufferAge` 1: an X11 window, a
# pbuffer...), they are drawn straight onto it and nothing else is touched;
# where it holds an older frame (2, 3: a chain of buffers), the frame is kept
# in a texture and only what changed since that older frame is put back from
# it; where nothing is known, the kept frame is put back whole.


proc gatherParts(src: openArray[Rect]; dst: var seq[Rect]) =
  ## Rectangles `src` gathered into at most `MaxParts`: a run under one of
  ## the same width makes it taller; then the two whose box adds the least
  ## are made one, until few enough are left.
  dst.setLen(0)
  for r in src:
    if r.w <= 0 or r.h <= 0: continue
    var merged = false
    for i in countdown(dst.high, max(0, dst.len - 4)):
      if dst[i].x == r.x and dst[i].w == r.w and dst[i].y + dst[i].h == r.y:
        dst[i].h += r.h
        merged = true
        break
    if not merged: dst.add r
  if dst.len > 4 * MaxParts:
    # (scattered all over: their box)
    var u = dst[0]
    for r in dst: u = union(u, r)
    dst.setLen(1)
    dst[0] = u
    return
  while dst.len > MaxParts:
    var bi = 0
    var bj = 1
    var best = high(int)
    for i in 0 ..< dst.len:
      for j in i + 1 ..< dst.len:
        let u = union(dst[i], dst[j])
        let waste = u.w * u.h - dst[i].w * dst[i].h - dst[j].w * dst[j].h
        if waste < best:
          best = waste
          bi = i
          bj = j
    dst[bi] = union(dst[bi], dst[bj])
    dst.del(bj)

proc regather(v: var seq[Rect]) =
  ## `v` gathered again (`gatherParts`), in its place.
  partsTmp.setLen(v.len)
  for i in 0 ..< v.len: partsTmp[i] = v[i]
  gatherParts(partsTmp, v)

proc partsArea(parts: openArray[Rect]): int =
  for p in parts: result += p.w * p.h

proc rememberParts(parts: openArray[Rect]) =
  ## This frame's change, for the frames after it (`gpuBufferAge`).
  for k in countdown(partHist.high, 1):
    partHist[k].setLen(partHist[k - 1].len)
    for i in 0 ..< partHist[k - 1].len: partHist[k][i] = partHist[k - 1][i]
  partHist[0].setLen(parts.len)
  for i in 0 ..< parts.len: partHist[0][i] = parts[i]
  partHistN = min(partHist.len, partHistN + 1)

proc forgetParts() =
  ## (what the screen's buffers hold is not known from here: drawn whole)
  partHistN = 0

proc drawFrameParts(parts: openArray[Rect]; whole: bool) =
  ## The frame's commands drawn onto the framebuffer bound now: all of
  ## them (`whole`), or each part's (the GPU touches no pixel outside it, and
  ## what lies wholly outside is not even sent).
  gl.clearColor(float32((clearColor shr 16) and 255) / 255, float32((clearColor shr 8) and 255) / 255,
                float32(clearColor and 255) / 255, 1)
  if whole:
    gl.colorMask(1, 1, 1, 1)
    gl.clear(GL_COLOR_BUFFER_BIT)
    gl.colorMask(1, 1, 1, 0)
    for l in 0 ..< MaxLayers:
      for c in layers[l]: gpuCmd(c)
    flushDraw()
    return
  # (each command's box: from `tileRuns`, which this frame went through)
  gl.enable(GL_SCISSOR_TEST)
  for p in parts:
    gl.scissor(GLint(p.x), GLint(fbH - p.y - p.h), GLsizei(p.w), GLsizei(p.h))
    gl.colorMask(1, 1, 1, 1)
    gl.clear(GL_COLOR_BUFFER_BIT)
    gl.colorMask(1, 1, 1, 0)
    for l in 0 ..< MaxLayers:
      for i in 0 ..< layers[l].len:
        if intersects(cmdDev[l][i], p): gpuCmd(layers[l][i])
    flushDraw()
  gl.disable(GL_SCISSOR_TEST)
  for l in 0 ..< MaxLayers:
    for i in 0 ..< layers[l].len:
      var inside = false
      for p in parts:
        if intersects(cmdDev[l][i], p):
          inside = true
          break
      if not inside: gpuKeepAlive(layers[l][i])

proc gpuPresent(force: bool; shown: var bool): bool =
  ## The frame drawn with OpenGL and shown (`shown`: the screen got a new
  ## one); false when the context was lost. Only the tiles whose drawing
  ## changed are drawn again (as on the CPU): straight onto the screen where
  ## it keeps its pixels, else into the kept frame, which is then put on
  ## the screen; a frame that changed much is drawn whole.
  shown = false
  if not beginGpuFrame(): return false
  if gl.genFramebuffers != nil and gl.bindFramebuffer != nil:
    var bound: GLint
    gl.getIntegerv(GL_FRAMEBUFFER_BINDING, addr bound)
    if keptFbo == 0 or bound != GLint(keptFbo): screenFb = bound
  if not blitTried: discard makeBlit()
  let canKeep = blitProg != 0 and fbW <= maxTex and fbH <= maxTex
  let age = if gpuRelays.gpuBufferAge != nil: gpuRelays.gpuBufferAge() else: 0
  let screenR = rect(0, 0, fbW, fbH)
  var full = force
  tileRuns(full, frameRuns)
  if not full and frameRuns.len == 0 and not screenStale:
    # (nothing on the screen changed: nothing drawn, nothing sent)
    for b in frameBitmaps: b.dirty = rect(0, 0, 0, 0)
    for t in 0 ..< tilesX * tilesY: shownTiles[t] = tileHash[t]
    return true
  if full:
    partsNow.setLen(1)
    partsNow[0] = screenR
  else:
    gatherParts(frameRuns, partsNow)
    if screenStale:
      # (what `overlayNow` put over the frame taken away too)
      partsNow.add staleRect
      if partsNow.len > MaxParts: regather(partsNow)
  let big = full or partsArea(partsNow) * 2 >= fbW * fbH
  # what the screen's buffer lacks: this frame's change, and the changes of
  # the frames since the one it holds
  var known = not big and age >= 1 and age <= partHistN + 1
  if known:
    partsDrawn.setLen(0)
    for p in partsNow: partsDrawn.add p
    for k in 0 ..< age - 1:
      for p in partHist[k]: partsDrawn.add p
    if partsDrawn.len > MaxParts: regather(partsDrawn)
    known = partsArea(partsDrawn) * 2 < fbW * fbH
  lastVerts.setLen(0)
  lastBatches.setLen(0)
  inc frameNo
  prepGlyphs.setLen(0)
  prepSpans.setLen(0)
  frameMasks.setLen(0)
  intoKept = false
  var blit = false
  var blitParts = false
  if age == 1 and known:
    # the screen holds the last frame: only what changed, straight onto it
    directPart = true
    drawFrameParts(partsDrawn, false)
    directPart = false
  elif age >= 2 and canKeep and keepFrame():
    # the screen holds an older frame: this one kept (what changed drawn
    # into it, all of it when it holds none), then put on the screen where
    # the screen differs
    intoKept = true
    gl.bindFramebuffer(GL_FRAMEBUFFER, keptFbo)
    drawFrameParts(partsNow, big or not keptValid)
    gl.bindFramebuffer(GL_FRAMEBUFFER, GLuint(screenFb))
    blit = true
    blitParts = known
  elif not big and canKeep and keepFrame():
    # (the screen's buffer not known: into the kept frame -- all of it, when
    # it does not hold the frame on the screen -- then all of that shown)
    intoKept = true
    gl.bindFramebuffer(GL_FRAMEBUFFER, keptFbo)
    if frameRuns.len > 0 or not keptValid:
      drawFrameParts(partsNow, not keptValid)
    gl.bindFramebuffer(GL_FRAMEBUFFER, GLuint(screenFb))
    blit = true
  else:
    drawFrameParts(partsNow, true)
  if blit:
    if blitParts: blitKept(partsDrawn) else: blitKept()
  if gpuDebugOn:
    gpuDebug("frame: age " & $age & (if intoKept: ", kept" else: "") & (if big: ", whole" else: "") &
             ", changed " & $partsNow & (if blit and blitParts: ", put back " & $partsDrawn
                                         elif blit: ", put back whole" else: ""))
  for b in frameBitmaps: b.dirty = rect(0, 0, 0, 0)
  if full: partsNow.setLen(0)          # (all of it changed: swapped whole)
  if not endGpuFrame(partsNow):
    gpuDebug("swap failed: back to the CPU")
    gpuOn = false
    return false
  for t in 0 ..< tilesX * tilesY: shownTiles[t] = tileHash[t]
  if intoKept: keptValid = true
  elif keptFbo != 0: keptValid = false
  intoKept = false
  if full:
    partsNow.setLen(1)
    partsNow[0] = screenR
  rememberParts(partsNow)
  screenStale = false
  shown = true
  true

proc gpuOverlay(r: Rect) =
  ## (`overlayNow`) The last frame again, what was just recorded over it.
  if not beginGpuFrame(): return
  let age = if gpuRelays.gpuBufferAge != nil: gpuRelays.gpuBufferAge() else: 0
  staleRect = if screenStale: union(staleRect, r) else: r
  if age == 1:
    # (the screen's buffer holds the last frame: drawn over it)
    directPart = true
    for c in layers[0]: gpuCmd(c)
    flushDraw()
    directPart = false
    discard endGpuFrame([r])
    rememberParts([r])
    screenStale = true
    return
  forgetParts()
  if keptValid and keptFbo != 0 and keptW == fbW and keptH == fbH:
    # (the kept frame on the screen, what was recorded over it; the next
    # frame puts the kept one back)
    blitKept()
    for c in layers[0]: gpuCmd(c)
    discard endGpuFrame()
    screenStale = true
    return
  let keepV = lastVerts
  let keepB = lastBatches
  verts = keepV
  batches = keepB
  lastVerts.setLen(0)
  lastBatches.setLen(0)
  gl.colorMask(1, 1, 1, 1)
  gl.clear(GL_COLOR_BUFFER_BIT)
  gl.colorMask(1, 1, 1, 0)
  flushDraw()
  for c in layers[0]: gpuCmd(c)
  discard endGpuFrame()
  lastVerts = keepV
  lastBatches = keepB
  screenStale = true

proc gpuSelfTest(): bool =
  ## A few pixels drawn and read back: a GPU (or driver) that draws them
  ## wrong is not used.
  if not beginGpuFrame(): return false
  gl.clearColor(0.0, 0.0, 1.0, 1)
  gl.colorMask(1, 1, 1, 1)
  gl.clear(GL_COLOR_BUFFER_BIT)
  gl.colorMask(1, 1, 1, 0)
  let all = rect(0, 0, fbW, fbH)
  quad(0, 0, 8, 8, 0, 0, 0, 0, 0xFF0000'u32, 255, ModeSolid, all)
  quad(8, 0, 16, 8, 0, 0, 0, 0, 0x00FF00'u32, 255, ModeChecker, all, 1)
  var m = Mask(w: 4, h: 4, a: newSeq[uint8](16))
  for v in m.a.mitems: v = 128
  maskQuad(0xFFFF_FFFF'u64, addr m, 16, 0, 0xFFFFFF'u32, all)
  flushDraw()
  var px: array[4, array[4, uint8]]
  # (GL's rows count from the bottom)
  let yb = GLint(fbH - 1)
  gl.pixelStorei(GL_PACK_ALIGNMENT, 4)
  gl.readPixels(1, yb, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, addr px[0])
  gl.readPixels(8, yb, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, addr px[1])
  gl.readPixels(9, yb, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, addr px[2])
  gl.readPixels(17, yb, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, addr px[3])
  lastVerts.setLen(0)
  lastBatches.setLen(0)
  maskAtlas.map.clear()
  maskAtlas.curX = 0
  maskAtlas.curY = 0
  maskAtlas.shelfH = 0
  template near(a, b: uint8): bool = abs(int(a) - int(b)) <= 3
  result = px[0][0] == 255 and px[0][2] == 0 and px[1][1] == 255 and px[2][2] == 255 and
           px[2][1] == 0 and near(px[3][0], 128) and near(px[3][2], 255)
  if not result: gpuDebug("self test: " & $px)

proc stopGpu() =
  if gpuOn: freeGpuState()
  if gpuRelays.stopGpu != nil: gpuRelays.stopGpu()
  gpuOn = false
  gpuGen = -1

from std/os import nil

proc hasGpuDevice(): bool =
  ## A desktop Linux or BSD with a graphics device (/dev/dri: a card or a
  ## render node). Without one, OpenGL could only be a software renderer
  ## (llvmpipe) -- slower than drawing on the CPU here, and loading it
  ## costs some 70 MB -- so it is not even started.
  when (defined(linux) or defined(bsd)) and not androidApp:
    try:
      for kind, p in os.walkDir("/dev/dri"):
        let n = os.extractFilename(p)
        if (n.len >= 7 and n[0 ..< 7] == "renderD") or (n.len >= 4 and n[0 ..< 4] == "card"): return true
    except OSError: discard
    false
  else: true

proc startGpu(): bool =
  ## OpenGL tried (once): the context, the functions, the program, a test.
  gpuTried = true
  if gpuWanted == gmCpu or gpuRelays.startGpu == nil or gpuRelays.gpuProc == nil: return false
  let forced = getEnv("RETRO_GPU").toLowerAscii in ["1", "gpu"]
  if gpuWanted == gmAuto and not forced and not hasGpuDevice():
    gpuNoDevice = true
    gpuDebug("no graphics device: drawing on the CPU (OpenGL not loaded)")
    return false
  if gpuGuardPath.len > 0 and fileExists(gpuGuardPath) and not forced:
    gpuCrashed = true
    gpuDebug("the last run stopped while starting the GPU: drawing on the CPU")
    return false
  if gpuGuardPath.len > 0:
    try:
      createDir(parentDir(gpuGuardPath))
      writeFile(gpuGuardPath, "starting the GPU\n")
    except CatchableError: discard
  gpuFramesOk = 0
  if not gpuRelays.startGpu():
    gpuDebug("no OpenGL context")
    if gpuGuardPath.len > 0: (try: removeFile(gpuGuardPath) except CatchableError: discard)
    return false
  let es = gpuRelays.gpuIsEs == nil or gpuRelays.gpuIsEs()
  if not gl.loadGl(gpuRelays.gpuProc, es):
    gpuDebug("OpenGL functions missing")
    stopGpu()
    return false
  gpuRenderer = $gl.getString(GL_RENDERER)
  let lr = gpuRenderer.toLowerAscii
  gpuSoftware = "llvmpipe" in lr or "softpipe" in lr or "swiftshader" in lr or "software" in lr or
                "swrast" in lr
  var mt: GLint
  gl.getIntegerv(GL_MAX_TEXTURE_SIZE, addr mt)
  maxTex = clamp(int(mt), 256, 8192)
  gpuDebug("renderer: " & gpuRenderer & ", max texture " & $maxTex)
  if gpuSoftware and gpuWanted == gmAuto and not forced:
    gpuDebug("a software renderer: drawing on the CPU")
    stopGpu()
    if gpuGuardPath.len > 0: (try: removeFile(gpuGuardPath) except CatchableError: discard)
    return false
  gpuGen = -1
  if fbW <= 0 or fbH <= 0 or not gpuSelfTest():
    gpuDebug("the self test failed")
    stopGpu()
    if gpuGuardPath.len > 0: (try: removeFile(gpuGuardPath) except CatchableError: discard)
    return false
  gpuOn = true
  gpuThreadId = getThreadId()
  true

proc setGpuMode*(m: GpuMode) =
  ## How frames are drawn: `gmAuto` (the default: with the GPU when it is
  ## a real one), `gmGpu` or `gmCpu`. Takes effect at the next frame.
  if m == gpuWanted: return
  gpuWanted = m
  if gpuOn and m == gmCpu: stopGpu()
  gpuTried = false
  gpuCrashed = false
  if gpuGuardPath.len > 0: (try: removeFile(gpuGuardPath) except CatchableError: discard)
  shownHash = 0
  for t in shownTiles.mitems: t = 0

proc gpuMode*(): GpuMode = gpuWanted
  ## How frames are to be drawn (see `setGpuMode`).

proc drawnWithGpu*(): bool = gpuOn
  ## Frames are being drawn with the GPU now.

proc gpuDescription*(): string =
  ## What draws the frames, for a settings page: the GPU's name, or why it
  ## is the CPU.
  if gpuOn: "GPU: " & gpuRenderer
  elif gpuCrashed: "CPU (the GPU failed to start last time)"
  elif gpuNoDevice: "CPU (no graphics device)"
  elif gpuRenderer.len > 0 and gpuSoftware: "CPU (" & gpuRenderer & " is not a real GPU)"
  elif gpuWanted == gmCpu: "CPU"
  elif gpuRelays.startGpu == nil: "CPU (no GPU drawing on this platform)"
  else: "CPU"

proc gpuSnapshot*(): seq[uint32] =
  ## The frame last drawn with the GPU, read back (0x00RRGGBB, top row
  ## first): for tests. Empty when the GPU is not drawing.
  if not gpuOn or fbW <= 0 or fbH <= 0: return
  var raw = newSeq[uint8](fbW * fbH * 4)
  gl.pixelStorei(GL_PACK_ALIGNMENT, 4)
  gl.readPixels(0, 0, GLsizei(fbW), GLsizei(fbH), GL_RGBA, GL_UNSIGNED_BYTE, addr raw[0])
  result = newSeq[uint32](fbW * fbH)
  for y in 0 ..< fbH:
    let src = (fbH - 1 - y) * fbW * 4
    for x in 0 ..< fbW:
      let i = src + x * 4
      result[y * fbW + x] = (uint32(raw[i]) shl 16) or (uint32(raw[i + 1]) shl 8) or uint32(raw[i + 2])

proc gpuHasImage*(key: uint64): bool =
  ## The GPU has picture `key` (sent with `gpuImage`, not given back since).
  gpuOn and texCache.getOrDefault(cast[pointer](key)).tiles.len > 0

# ---- filters on the GPU -----------------------------------------------------------------------------------
#
# A picture's filter worked out by the GPU when frames are drawn with it:
# the picture sent as a texture, drawn through a shader into another, read
# back. The Gaussian blur (two passes, its colors weighed by alpha) and a
# table of colors (every change of each pixel by itself: Levels, Curves,
# Hue/Saturation... read between the table's colors). Where there is no
# GPU, or the picture is too big for its textures: nil, the CPU does it.

var
  fxProgs: array[2, GLuint]
  fxVbo: GLuint
  fxFailed: array[2, bool]

const FxVertex = """
attribute vec2 aPos;
void main() { gl_Position = vec4(aPos, 0.0, 1.0); }
"""

const FxBlur = """
uniform sampler2D uTex;
uniform vec2 uSize;
uniform vec2 uDir;
uniform float uW[64];
uniform float uR;
uniform float uPass;
vec4 pre(vec4 c) { return uPass < 0.5 ? vec4(c.rgb * c.a, c.a) : c; }
void main() {
  vec2 uv = gl_FragCoord.xy / uSize;
  vec4 acc = pre(texture2D(uTex, uv)) * uW[0];
  for (int i = 1; i < 64; i++) {
    if (float(i) > uR) break;
    vec2 o = uDir * float(i) / uSize;
    acc += (pre(texture2D(uTex, uv + o)) + pre(texture2D(uTex, uv - o))) * uW[i];
  }
  if (uPass > 0.5) {
    if (acc.a > 0.002) acc.rgb = acc.rgb / acc.a; else acc = vec4(0.0);
  }
  gl_FragColor = clamp(acc, 0.0, 1.0);
}
"""

const FxLut = """
uniform sampler2D uTex;
uniform sampler2D uLut;
uniform vec2 uSize;
uniform float uN;
vec3 at(float r, float g, float b) {
  vec2 p = vec2((g * uN + b + 0.5) / (uN * uN), (r + 0.5) / uN);
  return texture2D(uLut, p).bgr;
}
void main() {
  vec4 c = texture2D(uTex, gl_FragCoord.xy / uSize);
  vec3 rgb = c.bgr * (uN - 1.0);
  vec3 i0 = floor(min(rgb, vec3(uN - 2.0)));
  vec3 f = rgb - i0;
  vec3 c00 = mix(at(i0.r, i0.g, i0.b), at(i0.r, i0.g, i0.b + 1.0), f.b);
  vec3 c01 = mix(at(i0.r, i0.g + 1.0, i0.b), at(i0.r, i0.g + 1.0, i0.b + 1.0), f.b);
  vec3 c10 = mix(at(i0.r + 1.0, i0.g, i0.b), at(i0.r + 1.0, i0.g, i0.b + 1.0), f.b);
  vec3 c11 = mix(at(i0.r + 1.0, i0.g + 1.0, i0.b), at(i0.r + 1.0, i0.g + 1.0, i0.b + 1.0), f.b);
  vec3 o = mix(mix(c00, c01, f.g), mix(c10, c11, f.g), f.r);
  gl_FragColor = vec4(o.b, o.g, o.r, c.a);
}
"""

proc gpuFiltersReady*(): bool =
  ## Filters can be worked out on the GPU now (frames drawn with it, on
  ## this thread, the driver able to draw into a texture).
  {.cast(gcsafe).}:
    gpuOn and gl.ok and gl.genFramebuffers != nil and gl.bindFramebuffer != nil and
      gl.framebufferTexture2D != nil and gl.checkFramebufferStatus != nil and gl.uniform1fv != nil and
      gl.uniform1f != nil and getThreadId() == gpuThreadId

proc fxProgram(k: int): GLuint =
  if fxProgs[k] != 0 or fxFailed[k]: return fxProgs[k]
  let vs = compile(GL_VERTEX_SHADER, FxVertex)
  let fs = compile(GL_FRAGMENT_SHADER, if k == 0: FxBlur else: FxLut)
  if vs == 0 or fs == 0:
    fxFailed[k] = true
    return 0
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
    fxFailed[k] = true
    gl.deleteProgram(p)
    return 0
  fxProgs[k] = p
  p

proc maxTexture(): int =
  var v: GLint
  gl.getIntegerv(GL_MAX_TEXTURE_SIZE, addr v)
  int(v)

template withFx(w, h: int; body: untyped) =
  ## (the GPU's state kept, a quad over `w` x `h`, put back after `body`)
  var oldFb: GLint
  gl.getIntegerv(GL_FRAMEBUFFER_BINDING, addr oldFb)
  if fxVbo == 0:
    gl.genBuffers(1, addr fxVbo)
  var quadV = [-1'f32, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]
  gl.bindBuffer(GL_ARRAY_BUFFER, fxVbo)
  gl.bufferData(GL_ARRAY_BUFFER, sizeof(quadV), addr quadV[0], GL_STREAM_DRAW)
  gl.vertexAttribPointer(0, 2, GL_FLOAT, 0, 8, nil)
  gl.enableVertexAttribArray(0)
  gl.disable(GL_BLEND)
  gl.disable(GL_SCISSOR_TEST)
  gl.colorMask(1, 1, 1, 1)               # (the frame keeps its alpha; a filter writes it)
  gl.viewport(0, 0, GLsizei(w), GLsizei(h))
  try:
    body
  finally:
    gl.bindFramebuffer(GL_FRAMEBUFFER, GLuint(oldFb))
    gl.useProgram(prog)
    gl.colorMask(1, 1, 1, 0)
    gl.enable(GL_BLEND)
    gl.viewport(0, 0, GLsizei(fbW), GLsizei(fbH))
    gl.activeTexture(GL_TEXTURE0)

proc fxTarget(tex: GLuint): GLuint =
  gl.genFramebuffers(1, addr result)
  gl.bindFramebuffer(GL_FRAMEBUFFER, result)
  gl.framebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0)
  if gl.checkFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE:
    gl.deleteFramebuffers(1, addr result)
    result = 0

proc gpuBlur*(px: openArray[uint32]; w, h: int; radius: float): seq[uint32] =
  ## A Gaussian blur of `radius` pixels worked out by the GPU (its colors
  ## weighed by their alpha); empty when it cannot be (no GPU, too big, a
  ## radius past 40 pixels): the CPU does it then.
  result = @[]         # (a value at once: see tools/writecheck.py)
  {.cast(gcsafe).}:
    if not gpuFiltersReady() or w <= 0 or h <= 0 or px.len != w * h or radius <= 0.05 or radius > 40: return
    if w > maxTexture() or h > maxTexture(): return
    let p = fxProgram(0)
    if p == 0: return
    # the kernel: as the CPU's (sigma = radius / 2), at most 63 a side
    let sigma = max(0.1, radius / 2)
    let r = min(63, int(ceil(sigma * 3)))
    var wts: array[64, GLf32]
    var tot = 0.0
    for i in 0 .. r:
      let v = exp(-(i * i).float / (2 * sigma * sigma))
      wts[i] = GLf32(v)
      tot += (if i == 0: v else: 2 * v)
    for i in 0 .. r: wts[i] = GLf32(wts[i].float / tot)
    var texIn = newTexture(w, h, GL_RGBA, GL_NEAREST, unsafeAddr px[0])
    var texMid = newTexture(w, h, GL_RGBA, GL_NEAREST)
    var texOut = newTexture(w, h, GL_RGBA, GL_NEAREST)
    var fb1, fb2: GLuint
    withFx(w, h):
      fb1 = fxTarget(texMid)
      fb2 = fxTarget(texOut)
      if fb1 != 0 and fb2 != 0:
        gl.useProgram(p)
        gl.uniform1i(gl.getUniformLocation(p, "uTex"), 0)
        gl.uniform2f(gl.getUniformLocation(p, "uSize"), GLf32(w), GLf32(h))
        gl.uniform1fv(gl.getUniformLocation(p, "uW"), 64, addr wts[0])
        gl.uniform1f(gl.getUniformLocation(p, "uR"), GLf32(r))
        gl.activeTexture(GL_TEXTURE0)
        # across, into the middle texture (multiplied by alpha)
        gl.bindFramebuffer(GL_FRAMEBUFFER, fb1)
        gl.bindTexture(GL_TEXTURE_2D, texIn)
        gl.uniform2f(gl.getUniformLocation(p, "uDir"), 1, 0)
        gl.uniform1f(gl.getUniformLocation(p, "uPass"), 0)
        gl.drawArrays(GL_TRIANGLES, 0, 6)
        # down, into the last (divided again)
        gl.bindFramebuffer(GL_FRAMEBUFFER, fb2)
        gl.bindTexture(GL_TEXTURE_2D, texMid)
        gl.uniform2f(gl.getUniformLocation(p, "uDir"), 0, 1)
        gl.uniform1f(gl.getUniformLocation(p, "uPass"), 1)
        gl.drawArrays(GL_TRIANGLES, 0, 6)
        result = newSeq[uint32](w * h)
        gl.pixelStorei(GL_PACK_ALIGNMENT, 4)
        gl.readPixels(0, 0, GLsizei(w), GLsizei(h), GL_RGBA, GL_UNSIGNED_BYTE, addr result[0])
        let err = gl.getError()
        gpuDebug("blur " & $w & "x" & $h & " r" & $radius & ": error " & $err & ", first " & $result[0] &
                 ", middle " & $result[(h div 2) * w + w div 2] & " from " & $px[(h div 2) * w + w div 2])
        if err != GL_NO_ERROR: result = @[]
      else: gpuDebug("blur: no framebuffer")
    for f in [fb1, fb2]:
      if f != 0:
        var ff = f
        gl.deleteFramebuffers(1, addr ff)
    for t in [texIn, texMid, texOut]:
      var tt = t
      gl.deleteTextures(1, addr tt)

proc gpuColorTable*(px: openArray[uint32]; w, h: int; lut: openArray[uint32]; n: int): seq[uint32] =
  ## Each pixel through a table of `n` x `n` x `n` colors (0xRRGGBB, red
  ## slowest), read between them, on the GPU (the alpha kept); empty when it
  ## cannot be.
  result = @[]         # (a value at once: see tools/writecheck.py)
  {.cast(gcsafe).}:
    if not gpuFiltersReady() or w <= 0 or h <= 0 or px.len != w * h or lut.len != n * n * n or n < 2: return
    if w > maxTexture() or h > maxTexture() or n * n > maxTexture(): return
    let p = fxProgram(1)
    if p == 0: return
    var lutPx = newSeq[uint32](lut.len)
    for i, c in lut: lutPx[i] = c or 0xFF000000'u32
    var texIn = newTexture(w, h, GL_RGBA, GL_NEAREST, unsafeAddr px[0])
    var texLut = newTexture(n * n, n, GL_RGBA, GL_NEAREST, addr lutPx[0])
    var texOut = newTexture(w, h, GL_RGBA, GL_NEAREST)
    var fb: GLuint
    withFx(w, h):
      fb = fxTarget(texOut)
      if fb != 0:
        gl.useProgram(p)
        gl.uniform1i(gl.getUniformLocation(p, "uTex"), 0)
        gl.uniform1i(gl.getUniformLocation(p, "uLut"), 1)
        gl.uniform2f(gl.getUniformLocation(p, "uSize"), GLf32(w), GLf32(h))
        gl.uniform1f(gl.getUniformLocation(p, "uN"), GLf32(n))
        gl.activeTexture(GL_TEXTURE0 + 1)
        gl.bindTexture(GL_TEXTURE_2D, texLut)
        gl.activeTexture(GL_TEXTURE0)
        gl.bindTexture(GL_TEXTURE_2D, texIn)
        gl.bindFramebuffer(GL_FRAMEBUFFER, fb)
        gl.drawArrays(GL_TRIANGLES, 0, 6)
        result = newSeq[uint32](w * h)
        gl.pixelStorei(GL_PACK_ALIGNMENT, 4)
        gl.readPixels(0, 0, GLsizei(w), GLsizei(h), GL_RGBA, GL_UNSIGNED_BYTE, addr result[0])
        if gl.getError() != GL_NO_ERROR: result = @[]
    if fb != 0: gl.deleteFramebuffers(1, addr fb)
    for t in [texIn, texLut, texOut]:
      var tt = t
      gl.deleteTextures(1, addr tt)

# ---- other work on the GPU, off the screen (retroui/photogpu: layers mixed there) ----------------------------
#
# Code of its own that draws into textures: the functions, a program made
# as the filters' are, the state frames are drawn with put aside and put
# back. Only while `gpuFiltersReady` (on the GPU's thread).

proc gpuGl*(): ptr GlTable =
  ## The OpenGL functions (for work of one's own on the GPU: only while
  ## `gpuFiltersReady`).
  {.cast(gcsafe).}: addr gl

proc gpuEpoch*(): int =
  ## Changes whenever all that was made on the GPU is gone (its context
  ## lost or let go): textures, programs... kept by other code are then
  ## forgotten, not given back.
  {.cast(gcsafe).}: gpuEpochN

proc gpuMaxTextureSize*(): int =
  ## The longest side of a texture the GPU takes (0 without the GPU).
  {.cast(gcsafe).}:
    if not gpuOn or not gl.ok: 0 else: maxTexture()

proc gpuCompileProgram*(vertex, fragment: string; attribs: openArray[string]; needHigh = false): GLuint =
  ## A program of two shaders (`#version` and the float precision put
  ## first, as for the filters), its attributes at locations 0, 1...; 0 when
  ## it does not compile or link. `needHigh`: the fragment shader must have
  ## 32-bit floats (an ES GPU without them fails it).
  {.cast(gcsafe).}:
    if not gpuOn or not gl.ok: return 0
    let vs = compile(GL_VERTEX_SHADER, vertex)
    let fs = compile(GL_FRAGMENT_SHADER, fragment, needHigh)
    if vs == 0 or fs == 0:
      if vs != 0: gl.deleteShader(vs)
      if fs != 0: gl.deleteShader(fs)
      return 0
    let p = gl.createProgram()
    gl.attachShader(p, vs)
    gl.attachShader(p, fs)
    for i, a in attribs: gl.bindAttribLocation(p, GLuint(i), cstring(a))
    gl.linkProgram(p)
    gl.deleteShader(vs)
    gl.deleteShader(fs)
    var ok: GLint
    gl.getProgramiv(p, GL_LINK_STATUS, addr ok)
    if ok == 0:
      var log = newString(2048)
      var n: GLsizei
      gl.getProgramInfoLog(p, 2048, addr n, cstring(log))
      gpuDebug("link: " & log[0 ..< max(0, n)])
      gl.deleteProgram(p)
      return 0
    p

proc gpuBeginOffscreen*(): GLint =
  ## The state for drawing into textures (no blending, no scissor, all four
  ## channels written; attributes 1..3 off); returns the framebuffer that was
  ## bound, for `gpuEndOffscreen`.
  {.cast(gcsafe).}:
    gl.getIntegerv(GL_FRAMEBUFFER_BINDING, addr result)
    gl.disable(GL_BLEND)
    gl.disable(GL_SCISSOR_TEST)
    gl.disable(GL_DITHER)
    gl.disable(GL_DEPTH_TEST)
    gl.disable(GL_CULL_FACE)
    gl.colorMask(1, 1, 1, 1)
    if gl.disableVertexAttribArray != nil:
      for i in 1'u32 .. 3'u32: gl.disableVertexAttribArray(i)

proc gpuShowTexture*(key: uint64; tex: GLuint; w, h: int) =
  ## Texture `tex` (drawn by other code: `retroui/view3d` on the GPU) shown
  ## as the picture `key` (`drawGpuImage`); its rows from the top, its
  ## colors as the bitmaps' (blue, green, red, alpha). The texture stays
  ## the caller's to give back.
  {.cast(gcsafe).}:
    texCache[cast[pointer](key)] = TexEntry(tiles: @[(tex, 0, 0, w, h, GLint(GL_LINEAR))], w: w, h: h,
                                            outside: true, used: gpuFrame)

proc gpuEndOffscreen*(oldFb: GLint) =
  ## The state frames are drawn with put back (after `gpuBeginOffscreen`).
  {.cast(gcsafe).}:
    gl.bindFramebuffer(GL_FRAMEBUFFER, GLuint(oldFb))
    if prog != 0: gl.useProgram(prog)
    gl.colorMask(1, 1, 1, 0)
    gl.enable(GL_BLEND)
    gl.blendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
    gl.viewport(0, 0, GLsizei(fbW), GLsizei(fbH))
    if vbo != 0: gl.bindBuffer(GL_ARRAY_BUFFER, vbo)
    for i in 0'u32 .. 3'u32: gl.enableVertexAttribArray(i)
    gl.activeTexture(GL_TEXTURE0 + 1)
    gl.bindTexture(GL_TEXTURE_2D, colorAtlas.tex)
    gl.activeTexture(GL_TEXTURE0)
    gl.bindTexture(GL_TEXTURE_2D, maskAtlas.tex)

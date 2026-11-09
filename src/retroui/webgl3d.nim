## The 3D view's GPU in a web page: a WebGL 2 context of its own (the
## page's frames are drawn by the CPU and shown through another), its
## functions as `glapi`'s table -- each a call into the page (`rw_gl`,
## retro.js) -- and the picture it drew read back for the frame. Used by
## `retroui/view3d` alone.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/tables
import glapi, gfx

proc rwGl(op: cint; a, b, c, d, e, f, g, h, i: float64): float64 {.importc: "rw_gl", cdecl.}

type Op = enum
  # (retro.js has them in this order)
  oReady, oEpoch, oViewport, oClearColor, oClear, oEnable, oDisable, oBlendFunc, oColorMask,
  oGenTextures, oDeleteTextures, oBindTexture, oActiveTexture, oTexImage2D, oTexParameteri,
  oPixelStorei, oReadPixels, oUseProgram, oDeleteProgram, oUniformLocation, oUniform1i, oUniform1f,
  oUniform2f, oUniform3f, oUniform4f, oGenBuffers, oDeleteBuffers, oBindBuffer, oBufferData,
  oAttribPointer, oEnableAttrib, oDisableAttrib, oDrawArrays, oDrawElements, oGenFramebuffers,
  oDeleteFramebuffers, oBindFramebuffer, oFramebufferTexture2D, oCheckFramebuffer, oGenRenderbuffers,
  oDeleteRenderbuffers, oBindRenderbuffer, oRenderbufferStorage, oFramebufferRenderbuffer,
  oDepthFunc, oDepthMask, oProgram, oFinish

template call(op: Op; a = 0.0; b = 0.0; c = 0.0; d = 0.0; e = 0.0; f = 0.0; g = 0.0; h = 0.0; i = 0.0): float64 =
  rwGl(cint(ord(op)), a, b, c, d, e, f, g, h, i)

template p(x: pointer): float64 = float64(cast[uint](x))
template n(x: SomeNumber): float64 = float64(x)

var
  table: GlTable
  made = false
  ready = false
  pictures: Table[uint64, Bitmap]

proc glString(name: GLenum): cstring {.cdecl, gcsafe.} =
  # (WebGL 2: 24-bit depth and 32-bit indices are always there)
  if name == GL_EXTENSIONS: cstring"GL_OES_depth24 GL_OES_element_index_uint" else: cstring"WebGL 2"

proc make() =
  made = true
  ready = call(oReady) > 0
  if not ready: return
  table.es = true
  table.getString = glString
  table.getError = proc (): GLenum {.cdecl, gcsafe.} = 0
  table.viewport = proc (x, y: GLint; w, h: GLsizei) {.cdecl, gcsafe.} =
    discard call(oViewport, n x, n y, n w, n h)
  table.clearColor = proc (r, g, b, a: GLf32) {.cdecl, gcsafe.} =
    discard call(oClearColor, n r, n g, n b, n a)
  table.clear = proc (mask: GLbitfield) {.cdecl, gcsafe.} = discard call(oClear, n mask)
  table.enable = proc (cap: GLenum) {.cdecl, gcsafe.} = discard call(oEnable, n cap)
  table.disable = proc (cap: GLenum) {.cdecl, gcsafe.} = discard call(oDisable, n cap)
  table.blendFunc = proc (s, d: GLenum) {.cdecl, gcsafe.} = discard call(oBlendFunc, n s, n d)
  table.colorMask = proc (r, g, b, a: GLboolean) {.cdecl, gcsafe.} =
    discard call(oColorMask, n r, n g, n b, n a)
  table.genTextures = proc (k: GLsizei; t: ptr GLuint) {.cdecl, gcsafe.} = discard call(oGenTextures, n k, p t)
  table.deleteTextures = proc (k: GLsizei; t: ptr GLuint) {.cdecl, gcsafe.} = discard call(oDeleteTextures, n k, p t)
  table.bindTexture = proc (target: GLenum; t: GLuint) {.cdecl, gcsafe.} = discard call(oBindTexture, n target, n t)
  table.activeTexture = proc (unit: GLenum) {.cdecl, gcsafe.} = discard call(oActiveTexture, n unit)
  table.texImage2D = proc (target: GLenum; level, internal: GLint; w, h: GLsizei; border: GLint;
                           format, typ: GLenum; data: pointer) {.cdecl, gcsafe.} =
    discard call(oTexImage2D, n target, n level, n internal, n w, n h, n border, n format, n typ, p data)
  table.texParameteri = proc (target, name: GLenum; v: GLint) {.cdecl, gcsafe.} =
    discard call(oTexParameteri, n target, n name, n v)
  table.pixelStorei = proc (name: GLenum; v: GLint) {.cdecl, gcsafe.} = discard call(oPixelStorei, n name, n v)
  table.readPixels = proc (x, y: GLint; w, h: GLsizei; format, typ: GLenum; data: pointer) {.cdecl, gcsafe.} =
    discard call(oReadPixels, n x, n y, n w, n h, n format, n typ, p data)
  table.useProgram = proc (q: GLuint) {.cdecl, gcsafe.} = discard call(oUseProgram, n q)
  table.deleteProgram = proc (q: GLuint) {.cdecl, gcsafe.} = discard call(oDeleteProgram, n q)
  table.getUniformLocation = proc (q: GLuint; name: cstring): GLint {.cdecl, gcsafe.} =
    GLint(call(oUniformLocation, n q, p cast[pointer](name)))
  table.uniform1i = proc (loc: GLint; v: GLint) {.cdecl, gcsafe.} = discard call(oUniform1i, n loc, n v)
  table.uniform1f = proc (loc: GLint; v: GLf32) {.cdecl, gcsafe.} = discard call(oUniform1f, n loc, n v)
  table.uniform2f = proc (loc: GLint; a, b: GLf32) {.cdecl, gcsafe.} = discard call(oUniform2f, n loc, n a, n b)
  table.uniform3f = proc (loc: GLint; a, b, c: GLf32) {.cdecl, gcsafe.} =
    discard call(oUniform3f, n loc, n a, n b, n c)
  table.uniform4f = proc (loc: GLint; a, b, c, d: GLf32) {.cdecl, gcsafe.} =
    discard call(oUniform4f, n loc, n a, n b, n c, n d)
  table.genBuffers = proc (k: GLsizei; b: ptr GLuint) {.cdecl, gcsafe.} = discard call(oGenBuffers, n k, p b)
  table.deleteBuffers = proc (k: GLsizei; b: ptr GLuint) {.cdecl, gcsafe.} = discard call(oDeleteBuffers, n k, p b)
  table.bindBuffer = proc (target: GLenum; b: GLuint) {.cdecl, gcsafe.} = discard call(oBindBuffer, n target, n b)
  table.bufferData = proc (target: GLenum; size: int; data: pointer; usage: GLenum) {.cdecl, gcsafe.} =
    discard call(oBufferData, n target, n size, p data, n usage)
  table.vertexAttribPointer = proc (i: GLuint; size: GLint; typ: GLenum; normalized: GLboolean;
                                    stride: GLsizei; offset: pointer) {.cdecl, gcsafe.} =
    discard call(oAttribPointer, n i, n size, n typ, n normalized, n stride, p offset)
  table.enableVertexAttribArray = proc (i: GLuint) {.cdecl, gcsafe.} = discard call(oEnableAttrib, n i)
  table.disableVertexAttribArray = proc (i: GLuint) {.cdecl, gcsafe.} = discard call(oDisableAttrib, n i)
  table.drawArrays = proc (mode: GLenum; first: GLint; count: GLsizei) {.cdecl, gcsafe.} =
    discard call(oDrawArrays, n mode, n first, n count)
  table.drawElements = proc (mode: GLenum; count: GLsizei; typ: GLenum; offset: pointer) {.cdecl, gcsafe.} =
    discard call(oDrawElements, n mode, n count, n typ, p offset)
  table.genFramebuffers = proc (k: GLsizei; f: ptr GLuint) {.cdecl, gcsafe.} = discard call(oGenFramebuffers, n k, p f)
  table.deleteFramebuffers = proc (k: GLsizei; f: ptr GLuint) {.cdecl, gcsafe.} =
    discard call(oDeleteFramebuffers, n k, p f)
  table.bindFramebuffer = proc (target: GLenum; f: GLuint) {.cdecl, gcsafe.} =
    discard call(oBindFramebuffer, n target, n f)
  table.framebufferTexture2D = proc (target, attach, textarget: GLenum; tex: GLuint; level: GLint) {.cdecl, gcsafe.} =
    discard call(oFramebufferTexture2D, n target, n attach, n textarget, n tex, n level)
  table.checkFramebufferStatus = proc (target: GLenum): GLenum {.cdecl, gcsafe.} =
    GLenum(call(oCheckFramebuffer, n target))
  table.genRenderbuffers = proc (k: GLsizei; r: ptr GLuint) {.cdecl, gcsafe.} = discard call(oGenRenderbuffers, n k, p r)
  table.deleteRenderbuffers = proc (k: GLsizei; r: ptr GLuint) {.cdecl, gcsafe.} =
    discard call(oDeleteRenderbuffers, n k, p r)
  table.bindRenderbuffer = proc (target: GLenum; r: GLuint) {.cdecl, gcsafe.} =
    discard call(oBindRenderbuffer, n target, n r)
  table.renderbufferStorage = proc (target, internal: GLenum; w, h: GLsizei) {.cdecl, gcsafe.} =
    discard call(oRenderbufferStorage, n target, n internal, n w, n h)
  table.framebufferRenderbuffer = proc (target, attach, rbTarget: GLenum; r: GLuint) {.cdecl, gcsafe.} =
    discard call(oFramebufferRenderbuffer, n target, n attach, n rbTarget, n r)
  table.depthFunc = proc (f: GLenum) {.cdecl, gcsafe.} = discard call(oDepthFunc, n f)
  table.depthMask = proc (on: GLboolean) {.cdecl, gcsafe.} = discard call(oDepthMask, n on)
  table.finish = proc () {.cdecl, gcsafe.} = discard call(oFinish)
  table.flush = proc () {.cdecl, gcsafe.} = discard
  table.ok = true

proc webGl3dReady*(): bool =
  ## The page has WebGL 2 (RETRO_3D_GPU=0, `view3dGpu`: not used).
  if not made: make()
  ready

proc webGl3d*(): ptr GlTable = addr table

proc webGl3dEpoch*(): int =
  ## (changes when the context was lost: everything made on it is gone)
  int(call(oEpoch))

proc webGl3dProgram*(vertex, fragment: string; attribs: openArray[string]): GLuint =
  ## The two shaders compiled and linked (GLSL ES 1.0, the precision put
  ## first), their attributes at 0, 1...; 0 when they do not.
  var names = ""
  for a in attribs: names.add a & "\n"
  GLuint(call(oProgram, p cast[pointer](cstring(vertex)), p cast[pointer](cstring(fragment)),
              p cast[pointer](cstring(names))))

proc webGl3dBegin*(): GLint =
  table.disable(GL_BLEND)
  table.disable(GL_SCISSOR_TEST)
  table.disable(GL_DEPTH_TEST)
  table.disable(GL_CULL_FACE)
  table.colorMask(1, 1, 1, 1)
  for i in 1'u32 .. 3'u32: table.disableVertexAttribArray(i)
  0

proc webGl3dEnd*(old: GLint) =
  table.bindFramebuffer(GL_FRAMEBUFFER, GLuint(old))

proc webGl3dShow*(key: uint64; w, h: int) =
  ## The picture just drawn (its framebuffer still bound) read back as the
  ## bitmap `key`: blue, green, red, alpha as the bitmaps', its rows from
  ## the top.
  var b = pictures.getOrDefault(key, nil)
  if b == nil or b.w != w or b.h != h:
    b = newBitmap(w, h)
    pictures[key] = b
  table.pixelStorei(GL_PACK_ALIGNMENT, 4)
  table.readPixels(0, 0, GLsizei(w), GLsizei(h), GL_RGBA, GL_UNSIGNED_BYTE, addr b.px[0])
  for i in 0 ..< b.px.len: b.px[i] = b.px[i] or 0xFF000000'u32
  b.opaque = true
  b.changed()

proc webGl3dPicture*(key: uint64): Bitmap =
  ## The last picture `webGl3dShow` read for `key` (nil: none).
  pictures.getOrDefault(key, nil)

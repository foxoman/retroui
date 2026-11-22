## OpenGL ES 2 for a browser page: the functions a renderer of 2D frames
## uses -- textures, buffers, shaders and programs, framebuffers, blending,
## the scissor -- each a call into the page (`rw_glu`, retro.js) on the
## canvas's own WebGL 2 context, its objects kept there by number. The web
## driver hands them out by their C names (`webGlProc`, its `gpuProc`), so a
## program that draws with OpenGL ES 2 elsewhere draws the page the same way.
## The page draws so only when it is asked to (`Retro.boot({ gpu: true })`,
## `?gpu=1`): else its frames stay pixels sent from the CPU.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

proc rwGlu(op: cint; a, b, c, d, e, f, g, h, i: float64): float64 {.importc: "rw_glu", cdecl.}

type
  GLenum = uint32
  GLuint = uint32
  GLint = int32
  GLsizei = int32
  GLboolean = uint8
  GLbitfield = uint32

const
  # (retro.js has them by these numbers)
  oReady = 0
  oEpoch = 1
  oViewport = 2
  oClearColor = 3
  oClear = 4
  oEnable = 5
  oDisable = 6
  oBlendFunc = 7
  oColorMask = 8
  oGenTextures = 9
  oDeleteTextures = 10
  oBindTexture = 11
  oActiveTexture = 12
  oTexImage2D = 13
  oTexParameteri = 14
  oPixelStorei = 15
  oReadPixels = 16
  oUseProgram = 17
  oDeleteProgram = 18
  oUniformLocation = 19
  oUniform1i = 20
  oUniform1f = 21
  oUniform2f = 22
  oUniform3f = 23
  oUniform4f = 24
  oGenBuffers = 25
  oDeleteBuffers = 26
  oBindBuffer = 27
  oBufferData = 28
  oAttribPointer = 29
  oEnableAttrib = 30
  oDisableAttrib = 31
  oDrawArrays = 32
  oDrawElements = 33
  oGenFramebuffers = 34
  oDeleteFramebuffers = 35
  oBindFramebuffer = 36
  oFramebufferTexture2D = 37
  oCheckFramebuffer = 38
  oGenRenderbuffers = 39
  oDeleteRenderbuffers = 40
  oBindRenderbuffer = 41
  oRenderbufferStorage = 42
  oFramebufferRenderbuffer = 43
  oDepthFunc = 44
  oDepthMask = 45
  oFinish = 47
  oScissor = 48
  oTexSubImage2D = 49
  oGetIntegerv = 50
  oCreateShader = 51
  oShaderSource = 52
  oCompileShader = 53
  oGetShaderiv = 54
  oGetShaderInfoLog = 55
  oDeleteShader = 56
  oCreateProgram = 57
  oAttachShader = 58
  oBindAttribLocation = 59
  oLinkProgram = 60
  oGetProgramiv = 61
  oGetProgramInfoLog = 62
  oUniform1fv = 63
  oBlendColor = 64
  oFlush = 65
  oGetString = 66
  oGetError = 67

template call(op: int; a = 0.0; b = 0.0; c = 0.0; d = 0.0; e = 0.0; f = 0.0; g = 0.0; h = 0.0;
              i = 0.0): float64 =
  rwGlu(cint(op), a, b, c, d, e, f, g, h, i)

template p(x: pointer): float64 = float64(cast[uint](x))
template p(x: cstring): float64 = float64(cast[uint](x))
template n(x: SomeNumber): float64 = float64(x)

var strings: seq[tuple[name: GLenum; s: string]]   # (glGetString's answers, kept as C wants)

proc webGlReady*(): bool =
  ## The page draws its frames with WebGL 2 now: it has it, and it was asked to.
  call(oReady) > 0

proc webGlEpoch*(): int =
  ## Changes when the context was lost (what was made on it is gone).
  int(call(oEpoch))

proc glGetString(name: GLenum): cstring {.cdecl, gcsafe.} =
  {.cast(gcsafe).}:
    for e in strings:
      if e.name == name: return cstring(e.s)
    let k = int(call(oGetString, n name))
    var s = newString(k + 1)
    let got = int(call(oGetString, n name, p cstring(s), n(k + 1)))
    s.setLen(clamp(got, 0, k))
    strings.add (name, s)
    cstring(strings[^1].s)

proc glGetIntegerv(name: GLenum; v: ptr GLint) {.cdecl, gcsafe.} = discard call(oGetIntegerv, n name, p v)
proc glGetError(): GLenum {.cdecl, gcsafe.} = GLenum(call(oGetError))
proc glViewport(x, y: GLint; w, h: GLsizei) {.cdecl, gcsafe.} = discard call(oViewport, n x, n y, n w, n h)
proc glClearColor(r, g, b, a: float32) {.cdecl, gcsafe.} = discard call(oClearColor, n r, n g, n b, n a)
proc glClear(mask: GLbitfield) {.cdecl, gcsafe.} = discard call(oClear, n mask)
proc glEnable(cap: GLenum) {.cdecl, gcsafe.} = discard call(oEnable, n cap)
proc glDisable(cap: GLenum) {.cdecl, gcsafe.} = discard call(oDisable, n cap)
proc glBlendFunc(s, d: GLenum) {.cdecl, gcsafe.} = discard call(oBlendFunc, n s, n d)
proc glColorMask(r, g, b, a: GLboolean) {.cdecl, gcsafe.} = discard call(oColorMask, n r, n g, n b, n a)
proc glScissor(x, y: GLint; w, h: GLsizei) {.cdecl, gcsafe.} = discard call(oScissor, n x, n y, n w, n h)
proc glGenTextures(k: GLsizei; t: ptr GLuint) {.cdecl, gcsafe.} = discard call(oGenTextures, n k, p t)
proc glDeleteTextures(k: GLsizei; t: ptr GLuint) {.cdecl, gcsafe.} = discard call(oDeleteTextures, n k, p t)
proc glBindTexture(target: GLenum; t: GLuint) {.cdecl, gcsafe.} = discard call(oBindTexture, n target, n t)
proc glActiveTexture(unit: GLenum) {.cdecl, gcsafe.} = discard call(oActiveTexture, n unit)
proc glTexImage2D(target: GLenum; level, internal: GLint; w, h: GLsizei; border: GLint;
                  format, typ: GLenum; data: pointer) {.cdecl, gcsafe.} =
  discard call(oTexImage2D, n target, n level, n internal, n w, n h, n border, n format, n typ, p data)
proc glTexSubImage2D(target: GLenum; level, x, y: GLint; w, h: GLsizei; format, typ: GLenum;
                     data: pointer) {.cdecl, gcsafe.} =
  discard call(oTexSubImage2D, n target, n level, n x, n y, n w, n h, n format, n typ, p data)
proc glTexParameteri(target, name: GLenum; v: GLint) {.cdecl, gcsafe.} =
  discard call(oTexParameteri, n target, n name, n v)
proc glPixelStorei(name: GLenum; v: GLint) {.cdecl, gcsafe.} = discard call(oPixelStorei, n name, n v)
proc glReadPixels(x, y: GLint; w, h: GLsizei; format, typ: GLenum; data: pointer) {.cdecl, gcsafe.} =
  discard call(oReadPixels, n x, n y, n w, n h, n format, n typ, p data)
proc glCreateShader(kind: GLenum): GLuint {.cdecl, gcsafe.} = GLuint(call(oCreateShader, n kind))
proc glShaderSource(s: GLuint; k: GLsizei; src: ptr cstring; lens: ptr GLint) {.cdecl, gcsafe.} =
  # (the pieces as one text: the page takes one)
  let parts = cast[ptr UncheckedArray[cstring]](src)
  let sizes = cast[ptr UncheckedArray[GLint]](lens)
  var all = ""
  for j in 0 ..< int(k):
    if parts[j] == nil: continue
    if lens != nil and sizes[j] >= 0:
      for c in 0 ..< int(sizes[j]): all.add parts[j][c]
    else: all.add $parts[j]
  discard call(oShaderSource, n s, p cstring(all))
proc glCompileShader(s: GLuint) {.cdecl, gcsafe.} = discard call(oCompileShader, n s)
proc glGetShaderiv(s: GLuint; name: GLenum; v: ptr GLint) {.cdecl, gcsafe.} =
  discard call(oGetShaderiv, n s, n name, p v)
proc glGetShaderInfoLog(s: GLuint; k: GLsizei; len: ptr GLsizei; log: cstring) {.cdecl, gcsafe.} =
  discard call(oGetShaderInfoLog, n s, n k, p len, p log)
proc glDeleteShader(s: GLuint) {.cdecl, gcsafe.} = discard call(oDeleteShader, n s)
proc glCreateProgram(): GLuint {.cdecl, gcsafe.} = GLuint(call(oCreateProgram))
proc glAttachShader(q, s: GLuint) {.cdecl, gcsafe.} = discard call(oAttachShader, n q, n s)
proc glBindAttribLocation(q, i: GLuint; name: cstring) {.cdecl, gcsafe.} =
  discard call(oBindAttribLocation, n q, n i, p name)
proc glLinkProgram(q: GLuint) {.cdecl, gcsafe.} = discard call(oLinkProgram, n q)
proc glGetProgramiv(q: GLuint; name: GLenum; v: ptr GLint) {.cdecl, gcsafe.} =
  discard call(oGetProgramiv, n q, n name, p v)
proc glGetProgramInfoLog(q: GLuint; k: GLsizei; len: ptr GLsizei; log: cstring) {.cdecl, gcsafe.} =
  discard call(oGetProgramInfoLog, n q, n k, p len, p log)
proc glUseProgram(q: GLuint) {.cdecl, gcsafe.} = discard call(oUseProgram, n q)
proc glDeleteProgram(q: GLuint) {.cdecl, gcsafe.} = discard call(oDeleteProgram, n q)
proc glGetUniformLocation(q: GLuint; name: cstring): GLint {.cdecl, gcsafe.} =
  GLint(call(oUniformLocation, n q, p name))
proc glUniform1i(loc, v: GLint) {.cdecl, gcsafe.} = discard call(oUniform1i, n loc, n v)
proc glUniform1f(loc: GLint; v: float32) {.cdecl, gcsafe.} = discard call(oUniform1f, n loc, n v)
proc glUniform2f(loc: GLint; a, b: float32) {.cdecl, gcsafe.} = discard call(oUniform2f, n loc, n a, n b)
proc glUniform3f(loc: GLint; a, b, c: float32) {.cdecl, gcsafe.} =
  discard call(oUniform3f, n loc, n a, n b, n c)
proc glUniform4f(loc: GLint; a, b, c, d: float32) {.cdecl, gcsafe.} =
  discard call(oUniform4f, n loc, n a, n b, n c, n d)
proc glUniform1fv(loc: GLint; k: GLsizei; v: ptr float32) {.cdecl, gcsafe.} =
  discard call(oUniform1fv, n loc, n k, p v)
proc glBlendColor(r, g, b, a: float32) {.cdecl, gcsafe.} = discard call(oBlendColor, n r, n g, n b, n a)
proc glGenBuffers(k: GLsizei; b: ptr GLuint) {.cdecl, gcsafe.} = discard call(oGenBuffers, n k, p b)
proc glDeleteBuffers(k: GLsizei; b: ptr GLuint) {.cdecl, gcsafe.} = discard call(oDeleteBuffers, n k, p b)
proc glBindBuffer(target: GLenum; b: GLuint) {.cdecl, gcsafe.} = discard call(oBindBuffer, n target, n b)
proc glBufferData(target: GLenum; size: int; data: pointer; usage: GLenum) {.cdecl, gcsafe.} =
  discard call(oBufferData, n target, n size, p data, n usage)
proc glVertexAttribPointer(i: GLuint; size: GLint; typ: GLenum; normalized: GLboolean;
                           stride: GLsizei; offset: pointer) {.cdecl, gcsafe.} =
  discard call(oAttribPointer, n i, n size, n typ, n normalized, n stride, p offset)
proc glEnableVertexAttribArray(i: GLuint) {.cdecl, gcsafe.} = discard call(oEnableAttrib, n i)
proc glDisableVertexAttribArray(i: GLuint) {.cdecl, gcsafe.} = discard call(oDisableAttrib, n i)
proc glDrawArrays(mode: GLenum; first: GLint; count: GLsizei) {.cdecl, gcsafe.} =
  discard call(oDrawArrays, n mode, n first, n count)
proc glDrawElements(mode: GLenum; count: GLsizei; typ: GLenum; offset: pointer) {.cdecl, gcsafe.} =
  discard call(oDrawElements, n mode, n count, n typ, p offset)
proc glFinish() {.cdecl, gcsafe.} = discard call(oFinish)
proc glFlush() {.cdecl, gcsafe.} = discard call(oFlush)
proc glGenFramebuffers(k: GLsizei; f: ptr GLuint) {.cdecl, gcsafe.} = discard call(oGenFramebuffers, n k, p f)
proc glDeleteFramebuffers(k: GLsizei; f: ptr GLuint) {.cdecl, gcsafe.} =
  discard call(oDeleteFramebuffers, n k, p f)
proc glBindFramebuffer(target: GLenum; f: GLuint) {.cdecl, gcsafe.} =
  discard call(oBindFramebuffer, n target, n f)
proc glFramebufferTexture2D(target, attach, textarget: GLenum; tex: GLuint; level: GLint) {.cdecl, gcsafe.} =
  discard call(oFramebufferTexture2D, n target, n attach, n textarget, n tex, n level)
proc glCheckFramebufferStatus(target: GLenum): GLenum {.cdecl, gcsafe.} =
  GLenum(call(oCheckFramebuffer, n target))
proc glGenRenderbuffers(k: GLsizei; r: ptr GLuint) {.cdecl, gcsafe.} = discard call(oGenRenderbuffers, n k, p r)
proc glDeleteRenderbuffers(k: GLsizei; r: ptr GLuint) {.cdecl, gcsafe.} =
  discard call(oDeleteRenderbuffers, n k, p r)
proc glBindRenderbuffer(target: GLenum; r: GLuint) {.cdecl, gcsafe.} =
  discard call(oBindRenderbuffer, n target, n r)
proc glRenderbufferStorage(target, internal: GLenum; w, h: GLsizei) {.cdecl, gcsafe.} =
  discard call(oRenderbufferStorage, n target, n internal, n w, n h)
proc glFramebufferRenderbuffer(target, attach, rbTarget: GLenum; r: GLuint) {.cdecl, gcsafe.} =
  discard call(oFramebufferRenderbuffer, n target, n attach, n rbTarget, n r)
proc glDepthFunc(f: GLenum) {.cdecl, gcsafe.} = discard call(oDepthFunc, n f)
proc glDepthMask(on: GLboolean) {.cdecl, gcsafe.} = discard call(oDepthMask, n on)

proc webGlProc*(name: cstring): pointer =
  ## An OpenGL ES 2 function by its C name ("glViewport"); nil for one the
  ## page does not offer (pixel buffers and fences: WebGL reads back
  ## otherwise).
  case $name
  of "glGetString": cast[pointer](glGetString)
  of "glGetIntegerv": cast[pointer](glGetIntegerv)
  of "glGetError": cast[pointer](glGetError)
  of "glViewport": cast[pointer](glViewport)
  of "glClearColor": cast[pointer](glClearColor)
  of "glClear": cast[pointer](glClear)
  of "glEnable": cast[pointer](glEnable)
  of "glDisable": cast[pointer](glDisable)
  of "glBlendFunc": cast[pointer](glBlendFunc)
  of "glColorMask": cast[pointer](glColorMask)
  of "glScissor": cast[pointer](glScissor)
  of "glGenTextures": cast[pointer](glGenTextures)
  of "glDeleteTextures": cast[pointer](glDeleteTextures)
  of "glBindTexture": cast[pointer](glBindTexture)
  of "glActiveTexture": cast[pointer](glActiveTexture)
  of "glTexImage2D": cast[pointer](glTexImage2D)
  of "glTexSubImage2D": cast[pointer](glTexSubImage2D)
  of "glTexParameteri": cast[pointer](glTexParameteri)
  of "glPixelStorei": cast[pointer](glPixelStorei)
  of "glReadPixels": cast[pointer](glReadPixels)
  of "glCreateShader": cast[pointer](glCreateShader)
  of "glShaderSource": cast[pointer](glShaderSource)
  of "glCompileShader": cast[pointer](glCompileShader)
  of "glGetShaderiv": cast[pointer](glGetShaderiv)
  of "glGetShaderInfoLog": cast[pointer](glGetShaderInfoLog)
  of "glDeleteShader": cast[pointer](glDeleteShader)
  of "glCreateProgram": cast[pointer](glCreateProgram)
  of "glAttachShader": cast[pointer](glAttachShader)
  of "glBindAttribLocation": cast[pointer](glBindAttribLocation)
  of "glLinkProgram": cast[pointer](glLinkProgram)
  of "glGetProgramiv": cast[pointer](glGetProgramiv)
  of "glGetProgramInfoLog": cast[pointer](glGetProgramInfoLog)
  of "glUseProgram": cast[pointer](glUseProgram)
  of "glDeleteProgram": cast[pointer](glDeleteProgram)
  of "glGetUniformLocation": cast[pointer](glGetUniformLocation)
  of "glUniform1i": cast[pointer](glUniform1i)
  of "glUniform1f": cast[pointer](glUniform1f)
  of "glUniform2f": cast[pointer](glUniform2f)
  of "glUniform3f": cast[pointer](glUniform3f)
  of "glUniform4f": cast[pointer](glUniform4f)
  of "glUniform1fv": cast[pointer](glUniform1fv)
  of "glBlendColor": cast[pointer](glBlendColor)
  of "glGenBuffers": cast[pointer](glGenBuffers)
  of "glDeleteBuffers": cast[pointer](glDeleteBuffers)
  of "glBindBuffer": cast[pointer](glBindBuffer)
  of "glBufferData": cast[pointer](glBufferData)
  of "glVertexAttribPointer": cast[pointer](glVertexAttribPointer)
  of "glEnableVertexAttribArray": cast[pointer](glEnableVertexAttribArray)
  of "glDisableVertexAttribArray": cast[pointer](glDisableVertexAttribArray)
  of "glDrawArrays": cast[pointer](glDrawArrays)
  of "glDrawElements": cast[pointer](glDrawElements)
  of "glFinish": cast[pointer](glFinish)
  of "glFlush": cast[pointer](glFlush)
  of "glGenFramebuffers": cast[pointer](glGenFramebuffers)
  of "glDeleteFramebuffers": cast[pointer](glDeleteFramebuffers)
  of "glBindFramebuffer": cast[pointer](glBindFramebuffer)
  of "glFramebufferTexture2D": cast[pointer](glFramebufferTexture2D)
  of "glCheckFramebufferStatus": cast[pointer](glCheckFramebufferStatus)
  of "glGenRenderbuffers": cast[pointer](glGenRenderbuffers)
  of "glDeleteRenderbuffers": cast[pointer](glDeleteRenderbuffers)
  of "glBindRenderbuffer": cast[pointer](glBindRenderbuffer)
  of "glRenderbufferStorage": cast[pointer](glRenderbufferStorage)
  of "glFramebufferRenderbuffer": cast[pointer](glFramebufferRenderbuffer)
  of "glDepthFunc": cast[pointer](glDepthFunc)
  of "glDepthMask": cast[pointer](glDepthMask)
  else: nil

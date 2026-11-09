## The part of OpenGL ES 2.0 (and of desktop OpenGL 2.1, which has the same
## calls) the GPU renderer uses, loaded at run time: nothing to link, no
## headers, and a program that runs where there is no OpenGL at all. The
## driver hands out the functions (`gpuProc`); `loadGl` fills the table.
## Only the GPU renderer (`retroui/gfx`) and `retroui/photogpu` use it; an app
## draws through `retroui/gfx` and never calls it.
##
## ```nim
## var gl: GlTable
## if loadGl(gl, relays.gpuProc, es = false):   # the screen driver's lookup
##   echo gl.getString(GL_RENDERER)
## ```

type
  GLenum* = uint32  ## OpenGL's `GLenum`: a name of a constant
  GLuint* = uint32  ## OpenGL's `GLuint`: a name of an object (texture, buffer, shader)
  GLint* = int32  ## OpenGL's `GLint`
  GLsizei* = int32  ## OpenGL's `GLsizei`: a count or a size
  GLf32* = float32  ## OpenGL's `GLfloat`
  GLboolean* = uint8  ## OpenGL's `GLboolean` (0 or 1)
  GLbitfield* = uint32  ## OpenGL's `GLbitfield`

const
  GL_COLOR_BUFFER_BIT* = 0x4000'u32  ## `clear`: the color buffer
  GL_TRIANGLES* = 0x0004'u32  ## `drawArrays`: separate triangles
  GL_BLEND* = 0x0BE2'u32  ## `enable`: blending
  GL_SCISSOR_TEST* = 0x0C11'u32  ## `enable`: clipping to the `scissor` box
  GL_DEPTH_TEST* = 0x0B71'u32  ## `disable`: the depth test
  GL_CULL_FACE* = 0x0B44'u32  ## `disable`: culling of back faces
  GL_DITHER* = 0x0BD0'u32  ## `disable`: dithering
  GL_SRC_ALPHA* = 0x0302'u32  ## `blendFunc`: the source's alpha
  GL_ONE_MINUS_SRC_ALPHA* = 0x0303'u32  ## `blendFunc`: 1 - the source's alpha
  GL_ONE_MINUS_SRC_COLOR* = 0x0301'u32  ## `blendFunc`: 1 - the source's color
  GL_CONSTANT_COLOR* = 0x8001'u32  ## `blendFunc`: the `blendColor`
  GL_ONE* = 1'u32  ## `blendFunc`: 1
  GL_ZERO* = 0'u32  ## `blendFunc`: 0
  GL_TEXTURE_2D* = 0x0DE1'u32  ## a 2D texture (`bindTexture`, `texImage2D`)
  GL_TEXTURE0* = 0x84C0'u32  ## `activeTexture`: the first unit (+ n for unit n)
  GL_TEXTURE_MIN_FILTER* = 0x2801'u32  ## `texParameteri`: how a texture is made smaller
  GL_TEXTURE_MAG_FILTER* = 0x2800'u32  ## `texParameteri`: how a texture is made larger
  GL_TEXTURE_WRAP_S* = 0x2802'u32  ## `texParameteri`: what is beyond a texture across
  GL_TEXTURE_WRAP_T* = 0x2803'u32  ## `texParameteri`: what is beyond a texture down
  GL_NEAREST* = 0x2600'i32  ## a filter: the nearest texel
  GL_LINEAR* = 0x2601'i32  ## a filter: the four nearest texels mixed
  GL_CLAMP_TO_EDGE* = 0x812F'i32  ## a wrap: the edge texels go on
  GL_RGBA* = 0x1908'u32  ## a texture format: red, green, blue, alpha
  GL_ALPHA* = 0x1906'u32  ## a texture format: alpha only
  GL_UNSIGNED_BYTE* = 0x1401'u32  ## a data type: 8-bit unsigned
  GL_FLOAT* = 0x1406'u32  ## a data type: 32-bit float
  GL_UNPACK_ALIGNMENT* = 0x0CF5'u32  ## `pixelStorei`: the row alignment of data given
  GL_PACK_ALIGNMENT* = 0x0D05'u32  ## `pixelStorei`: the row alignment of `readPixels`' data
  GL_ARRAY_BUFFER* = 0x8892'u32  ## `bindBuffer`: the vertex buffer
  GL_STREAM_DRAW* = 0x88E0'u32  ## `bufferData`: data given once, drawn a few times
  GL_VERTEX_SHADER* = 0x8B31'u32  ## `createShader`: a vertex shader
  GL_FRAGMENT_SHADER* = 0x8B30'u32  ## `createShader`: a fragment shader
  GL_COMPILE_STATUS* = 0x8B81'u32  ## `getShaderiv`: did it compile
  GL_LINK_STATUS* = 0x8B82'u32  ## `getProgramiv`: did it link
  GL_INFO_LOG_LENGTH* = 0x8B84'u32  ## `getShaderiv`, `getProgramiv`: the length of the log
  GL_MAX_TEXTURE_SIZE* = 0x0D33'u32  ## `getIntegerv`: the largest texture's side
  GL_VENDOR* = 0x1F00'u32  ## `getString`: who made the driver
  GL_RENDERER* = 0x1F01'u32  ## `getString`: the GPU's name
  GL_VERSION* = 0x1F02'u32  ## `getString`: the OpenGL version
  GL_NO_ERROR* = 0'u32  ## `getError`: none
  GL_OUT_OF_MEMORY* = 0x0505'u32  ## `getError`: out of memory
  GL_FRAMEBUFFER* = 0x8D40'u32  ## `bindFramebuffer`: the framebuffer drawn into
  GL_COLOR_ATTACHMENT0* = 0x8CE0'u32  ## `framebufferTexture2D`: the color attachment
  GL_FRAMEBUFFER_COMPLETE* = 0x8CD5'u32  ## `checkFramebufferStatus`: ready to draw into
  GL_FRAMEBUFFER_BINDING* = 0x8CA6'u32  ## `getIntegerv`: the framebuffer bound
  GL_VIEWPORT* = 0x0BA2'u32  ## `getIntegerv`: the viewport (4 values)
  GL_CURRENT_PROGRAM* = 0x8B8D'u32  ## `getIntegerv`: the program in use
  GL_TEXTURE_BINDING_2D* = 0x8069'u32  ## `getIntegerv`: the 2D texture bound
  GL_ACTIVE_TEXTURE* = 0x84E0'u32  ## `getIntegerv`: the active texture unit
  GL_ARRAY_BUFFER_BINDING* = 0x8894'u32  ## `getIntegerv`: the vertex buffer bound
  GL_MAX_TEXTURE_IMAGE_UNITS* = 0x8872'u32  ## `getIntegerv`: how many texture units a fragment shader has
  # (for the 3D view drawn on the GPU, `retroui/view3d`)
  GL_DEPTH_BUFFER_BIT* = 0x0100'u32  ## `clear`: the depth buffer
  GL_LEQUAL* = 0x0203'u32  ## `depthFunc`: nearer or as near passes
  GL_LINES* = 0x0001'u32  ## `drawArrays`: separate lines
  GL_ELEMENT_ARRAY_BUFFER* = 0x8893'u32  ## `bindBuffer`: indices
  GL_STATIC_DRAW* = 0x88E4'u32  ## `bufferData`: set once
  GL_UNSIGNED_SHORT* = 0x1403'u32  ## `drawElements`: 16-bit indices
  GL_UNSIGNED_INT* = 0x1405'u32  ## `drawElements`: 32-bit indices
  GL_RENDERBUFFER* = 0x8D41'u32  ## `bindRenderbuffer`
  GL_DEPTH_COMPONENT16* = 0x81A5'u32  ## `renderbufferStorage`: 16-bit depth
  GL_DEPTH_ATTACHMENT* = 0x8D00'u32  ## `framebufferRenderbuffer`: the depth buffer
  GL_REPEAT* = 0x2901'u32  ## `texParameteri`: a picture repeated
  GL_EXTENSIONS* = 0x1F03'u32  ## `getString`: the extensions

type
  GlTable* = object
    ## The functions, once loaded (`ok`): each field is the OpenGL function
    ## its comment names.
    ok*: bool               ## every function needed was found (`loadGl` returned true)
    es*: bool                ## OpenGL ES (else desktop OpenGL)
    getString*: proc (name: GLenum): cstring {.cdecl, gcsafe.}
      ## `glGetString`
    getIntegerv*: proc (name: GLenum; v: ptr GLint) {.cdecl, gcsafe.}
      ## `glGetIntegerv`
    getError*: proc (): GLenum {.cdecl, gcsafe.}
      ## `glGetError`
    viewport*: proc (x, y: GLint; w, h: GLsizei) {.cdecl, gcsafe.}
      ## `glViewport`
    clearColor*: proc (r, g, b, a: GLf32) {.cdecl, gcsafe.}
      ## `glClearColor`
    clear*: proc (mask: GLbitfield) {.cdecl, gcsafe.}
      ## `glClear`
    enable*: proc (cap: GLenum) {.cdecl, gcsafe.}
      ## `glEnable`
    disable*: proc (cap: GLenum) {.cdecl, gcsafe.}
      ## `glDisable`
    blendFunc*: proc (s, d: GLenum) {.cdecl, gcsafe.}
      ## `glBlendFunc`
    colorMask*: proc (r, g, b, a: GLboolean) {.cdecl, gcsafe.}
      ## `glColorMask`
    scissor*: proc (x, y: GLint; w, h: GLsizei) {.cdecl, gcsafe.}
      ## `glScissor`
    genTextures*: proc (n: GLsizei; t: ptr GLuint) {.cdecl, gcsafe.}
      ## `glGenTextures`
    deleteTextures*: proc (n: GLsizei; t: ptr GLuint) {.cdecl, gcsafe.}
      ## `glDeleteTextures`
    bindTexture*: proc (target: GLenum; t: GLuint) {.cdecl, gcsafe.}
      ## `glBindTexture`
    activeTexture*: proc (unit: GLenum) {.cdecl, gcsafe.}
      ## `glActiveTexture`
    texImage2D*: proc (target: GLenum; level, internal: GLint; w, h: GLsizei; border: GLint;
                       format, typ: GLenum; data: pointer) {.cdecl, gcsafe.}
      ## `glTexImage2D`
    texSubImage2D*: proc (target: GLenum; level, x, y: GLint; w, h: GLsizei;
                          format, typ: GLenum; data: pointer) {.cdecl, gcsafe.}
      ## `glTexSubImage2D`
    texParameteri*: proc (target, name: GLenum; v: GLint) {.cdecl, gcsafe.}
      ## `glTexParameteri`
    pixelStorei*: proc (name: GLenum; v: GLint) {.cdecl, gcsafe.}
      ## `glPixelStorei`
    readPixels*: proc (x, y: GLint; w, h: GLsizei; format, typ: GLenum; data: pointer) {.cdecl, gcsafe.}
      ## `glReadPixels`
    createShader*: proc (kind: GLenum): GLuint {.cdecl, gcsafe.}
      ## `glCreateShader`
    shaderSource*: proc (s: GLuint; n: GLsizei; src: ptr cstring; lens: ptr GLint) {.cdecl, gcsafe.}
      ## `glShaderSource`
    compileShader*: proc (s: GLuint) {.cdecl, gcsafe.}
      ## `glCompileShader`
    getShaderiv*: proc (s: GLuint; name: GLenum; v: ptr GLint) {.cdecl, gcsafe.}
      ## `glGetShaderiv`
    getShaderInfoLog*: proc (s: GLuint; n: GLsizei; len: ptr GLsizei; log: cstring) {.cdecl, gcsafe.}
      ## `glGetShaderInfoLog`
    deleteShader*: proc (s: GLuint) {.cdecl, gcsafe.}
      ## `glDeleteShader`
    createProgram*: proc (): GLuint {.cdecl, gcsafe.}
      ## `glCreateProgram`
    attachShader*: proc (p, s: GLuint) {.cdecl, gcsafe.}
      ## `glAttachShader`
    bindAttribLocation*: proc (p, i: GLuint; name: cstring) {.cdecl, gcsafe.}
      ## `glBindAttribLocation`
    linkProgram*: proc (p: GLuint) {.cdecl, gcsafe.}
      ## `glLinkProgram`
    getProgramiv*: proc (p: GLuint; name: GLenum; v: ptr GLint) {.cdecl, gcsafe.}
      ## `glGetProgramiv`
    getProgramInfoLog*: proc (p: GLuint; n: GLsizei; len: ptr GLsizei; log: cstring) {.cdecl, gcsafe.}
      ## `glGetProgramInfoLog`
    useProgram*: proc (p: GLuint) {.cdecl, gcsafe.}
      ## `glUseProgram`
    deleteProgram*: proc (p: GLuint) {.cdecl, gcsafe.}
      ## `glDeleteProgram`
    getUniformLocation*: proc (p: GLuint; name: cstring): GLint {.cdecl, gcsafe.}
      ## `glGetUniformLocation`
    uniform1i*: proc (loc: GLint; v: GLint) {.cdecl, gcsafe.}
      ## `glUniform1i`
    uniform2f*: proc (loc: GLint; a, b: GLf32) {.cdecl, gcsafe.}
      ## `glUniform2f`
    genBuffers*: proc (n: GLsizei; b: ptr GLuint) {.cdecl, gcsafe.}
      ## `glGenBuffers`
    deleteBuffers*: proc (n: GLsizei; b: ptr GLuint) {.cdecl, gcsafe.}
      ## `glDeleteBuffers`
    bindBuffer*: proc (target: GLenum; b: GLuint) {.cdecl, gcsafe.}
      ## `glBindBuffer`
    bufferData*: proc (target: GLenum; size: int; data: pointer; usage: GLenum) {.cdecl, gcsafe.}
      ## `glBufferData`
    vertexAttribPointer*: proc (i: GLuint; size: GLint; typ: GLenum; normalized: GLboolean;
                                stride: GLsizei; offset: pointer) {.cdecl, gcsafe.}
      ## `glVertexAttribPointer`
    enableVertexAttribArray*: proc (i: GLuint) {.cdecl, gcsafe.}
      ## `glEnableVertexAttribArray`
    drawArrays*: proc (mode: GLenum; first: GLint; count: GLsizei) {.cdecl, gcsafe.}
      ## `glDrawArrays`
    finish*: proc () {.cdecl, gcsafe.}
      ## `glFinish`
    flush*: proc () {.cdecl, gcsafe.}
      ## `glFlush`
    # (drawing into a texture: for filters on the GPU; nil where the driver has none)
    genFramebuffers*: proc (n: GLsizei; f: ptr GLuint) {.cdecl, gcsafe.}
      ## `glGenFramebuffers`
    deleteFramebuffers*: proc (n: GLsizei; f: ptr GLuint) {.cdecl, gcsafe.}
      ## `glDeleteFramebuffers`
    bindFramebuffer*: proc (target: GLenum; f: GLuint) {.cdecl, gcsafe.}
      ## `glBindFramebuffer`
    framebufferTexture2D*: proc (target, attach, textarget: GLenum; tex: GLuint; level: GLint) {.cdecl, gcsafe.}
      ## `glFramebufferTexture2D`
    checkFramebufferStatus*: proc (target: GLenum): GLenum {.cdecl, gcsafe.}
      ## `glCheckFramebufferStatus`
    uniform1f*: proc (loc: GLint; v: GLf32) {.cdecl, gcsafe.}
      ## `glUniform1f`
    uniform1fv*: proc (loc: GLint; n: GLsizei; v: ptr GLf32) {.cdecl, gcsafe.}
      ## `glUniform1fv`
    # (for layers mixed on the GPU, `retroui/photogpu`; nil where the driver has none)
    uniform4f*: proc (loc: GLint; a, b, c, d: GLf32) {.cdecl, gcsafe.}
      ## `glUniform4f`
    blendColor*: proc (r, g, b, a: GLf32) {.cdecl, gcsafe.}
      ## `glBlendColor`
    disableVertexAttribArray*: proc (i: GLuint) {.cdecl, gcsafe.}
      ## `glDisableVertexAttribArray`
    # (for the 3D view drawn on the GPU; nil where the driver has none)
    genRenderbuffers*: proc (n: GLsizei; r: ptr GLuint) {.cdecl, gcsafe.}
      ## `glGenRenderbuffers`
    deleteRenderbuffers*: proc (n: GLsizei; r: ptr GLuint) {.cdecl, gcsafe.}
      ## `glDeleteRenderbuffers`
    bindRenderbuffer*: proc (target: GLenum; r: GLuint) {.cdecl, gcsafe.}
      ## `glBindRenderbuffer`
    renderbufferStorage*: proc (target, internal: GLenum; w, h: GLsizei) {.cdecl, gcsafe.}
      ## `glRenderbufferStorage`
    framebufferRenderbuffer*: proc (target, attach, rbTarget: GLenum; r: GLuint) {.cdecl, gcsafe.}
      ## `glFramebufferRenderbuffer`
    drawElements*: proc (mode: GLenum; count: GLsizei; typ: GLenum; offset: pointer) {.cdecl, gcsafe.}
      ## `glDrawElements`
    depthFunc*: proc (f: GLenum) {.cdecl, gcsafe.}
      ## `glDepthFunc`
    depthMask*: proc (on: GLboolean) {.cdecl, gcsafe.}
      ## `glDepthMask`
    uniform3f*: proc (loc: GLint; a, b, c: GLf32) {.cdecl, gcsafe.}
      ## `glUniform3f`

proc loadGl*(t: var GlTable; getProc: proc (name: cstring): pointer {.nimcall.}; es: bool): bool =
  ## Every function from `getProc` (the driver's) into `t`; `es`: the driver
  ## is OpenGL ES. False when one that is needed is missing (those after
  ## `flush` may be nil: the driver has none).
  t.es = es
  var missing = false
  template get(field: untyped; name: string) =
    let p = getProc(cstring(name))
    if p == nil: missing = true
    else: t.field = cast[typeof(t.field)](p)
  get(getString, "glGetString")
  get(getIntegerv, "glGetIntegerv")
  get(getError, "glGetError")
  get(viewport, "glViewport")
  get(clearColor, "glClearColor")
  get(clear, "glClear")
  get(enable, "glEnable")
  get(disable, "glDisable")
  get(blendFunc, "glBlendFunc")
  get(colorMask, "glColorMask")
  get(scissor, "glScissor")
  get(genTextures, "glGenTextures")
  get(deleteTextures, "glDeleteTextures")
  get(bindTexture, "glBindTexture")
  get(activeTexture, "glActiveTexture")
  get(texImage2D, "glTexImage2D")
  get(texSubImage2D, "glTexSubImage2D")
  get(texParameteri, "glTexParameteri")
  get(pixelStorei, "glPixelStorei")
  get(readPixels, "glReadPixels")
  get(createShader, "glCreateShader")
  get(shaderSource, "glShaderSource")
  get(compileShader, "glCompileShader")
  get(getShaderiv, "glGetShaderiv")
  get(getShaderInfoLog, "glGetShaderInfoLog")
  get(deleteShader, "glDeleteShader")
  get(createProgram, "glCreateProgram")
  get(attachShader, "glAttachShader")
  get(bindAttribLocation, "glBindAttribLocation")
  get(linkProgram, "glLinkProgram")
  get(getProgramiv, "glGetProgramiv")
  get(getProgramInfoLog, "glGetProgramInfoLog")
  get(useProgram, "glUseProgram")
  get(deleteProgram, "glDeleteProgram")
  get(getUniformLocation, "glGetUniformLocation")
  get(uniform1i, "glUniform1i")
  get(uniform2f, "glUniform2f")
  get(genBuffers, "glGenBuffers")
  get(deleteBuffers, "glDeleteBuffers")
  get(bindBuffer, "glBindBuffer")
  get(bufferData, "glBufferData")
  get(vertexAttribPointer, "glVertexAttribPointer")
  get(enableVertexAttribArray, "glEnableVertexAttribArray")
  get(drawArrays, "glDrawArrays")
  get(finish, "glFinish")
  get(flush, "glFlush")
  template opt(field: untyped; name: string) =
    let p = getProc(cstring(name))
    if p != nil: t.field = cast[typeof(t.field)](p)
  opt(genFramebuffers, "glGenFramebuffers")
  opt(deleteFramebuffers, "glDeleteFramebuffers")
  opt(bindFramebuffer, "glBindFramebuffer")
  opt(framebufferTexture2D, "glFramebufferTexture2D")
  opt(checkFramebufferStatus, "glCheckFramebufferStatus")
  opt(uniform1f, "glUniform1f")
  opt(uniform1fv, "glUniform1fv")
  opt(uniform4f, "glUniform4f")
  opt(blendColor, "glBlendColor")
  opt(disableVertexAttribArray, "glDisableVertexAttribArray")
  opt(genRenderbuffers, "glGenRenderbuffers")
  opt(deleteRenderbuffers, "glDeleteRenderbuffers")
  opt(bindRenderbuffer, "glBindRenderbuffer")
  opt(renderbufferStorage, "glRenderbufferStorage")
  opt(framebufferRenderbuffer, "glFramebufferRenderbuffer")
  opt(drawElements, "glDrawElements")
  opt(depthFunc, "glDepthFunc")
  opt(depthMask, "glDepthMask")
  opt(uniform3f, "glUniform3f")
  t.ok = not missing
  t.ok

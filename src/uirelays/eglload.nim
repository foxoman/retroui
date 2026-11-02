# EGL, loaded at run time (libEGL.so.1): an OpenGL ES 2 context on an X11
# window, or off screen (a pbuffer, for tests). Nothing is linked: a
# machine without EGL simply has no GPU drawing.

import std/dynlib

type
  EGLDisplay* = pointer
  EGLConfig* = pointer
  EGLContext* = pointer
  EGLSurface* = pointer
  EGLint* = int32
  EGLBoolean* = uint32

const
  EGL_NONE = 0x3038'i32
  EGL_SURFACE_TYPE = 0x3033'i32
  EGL_WINDOW_BIT = 0x0004'i32
  EGL_PBUFFER_BIT = 0x0001'i32
  EGL_RENDERABLE_TYPE = 0x3040'i32
  EGL_OPENGL_ES2_BIT = 0x0004'i32
  EGL_RED_SIZE = 0x3024'i32
  EGL_GREEN_SIZE = 0x3023'i32
  EGL_BLUE_SIZE = 0x3022'i32
  EGL_ALPHA_SIZE = 0x3021'i32
  EGL_CONTEXT_CLIENT_VERSION = 0x3098'i32
  EGL_OPENGL_ES_API = 0x30A0'u32
  EGL_WIDTH = 0x3057'i32
  EGL_HEIGHT = 0x3056'i32
  EGL_NATIVE_VISUAL_ID = 0x302E'i32
  EGL_PLATFORM_X11_KHR = 0x31D5'u32
  EGL_PLATFORM_SURFACELESS_MESA = 0x31DD'u32
  EGL_SUCCESS* = 0x3000'i32
  EGL_CONTEXT_LOST* = 0x300E'i32

type
  Egl* = object
    ## A context and its surface (`ok`), and the calls.
    ok*: bool
    lib: LibHandle
    dpy*: EGLDisplay
    cfg*: EGLConfig
    ctx*: EGLContext
    surf*: EGLSurface
    getProcAddress: proc (name: cstring): pointer {.cdecl, gcsafe.}
    getDisplay: proc (native: pointer): EGLDisplay {.cdecl, gcsafe.}
    getPlatformDisplay: proc (platform: uint32; native: pointer;
                              attrs: ptr EGLint): EGLDisplay {.cdecl, gcsafe.}
    initialize: proc (d: EGLDisplay; major, minor: ptr EGLint): EGLBoolean {.cdecl, gcsafe.}
    terminate: proc (d: EGLDisplay): EGLBoolean {.cdecl, gcsafe.}
    bindAPI: proc (api: uint32): EGLBoolean {.cdecl, gcsafe.}
    chooseConfig: proc (d: EGLDisplay; attrs: ptr EGLint; cfgs: ptr EGLConfig; size: EGLint;
                        n: ptr EGLint): EGLBoolean {.cdecl, gcsafe.}
    getConfigAttrib: proc (d: EGLDisplay; c: EGLConfig; attr: EGLint;
                           v: ptr EGLint): EGLBoolean {.cdecl, gcsafe.}
    createContext: proc (d: EGLDisplay; c: EGLConfig; share: EGLContext;
                         attrs: ptr EGLint): EGLContext {.cdecl, gcsafe.}
    destroyContext: proc (d: EGLDisplay; c: EGLContext): EGLBoolean {.cdecl, gcsafe.}
    createWindowSurface: proc (d: EGLDisplay; c: EGLConfig; win: pointer;
                               attrs: ptr EGLint): EGLSurface {.cdecl, gcsafe.}
    createPbufferSurface: proc (d: EGLDisplay; c: EGLConfig;
                                attrs: ptr EGLint): EGLSurface {.cdecl, gcsafe.}
    destroySurface: proc (d: EGLDisplay; s: EGLSurface): EGLBoolean {.cdecl, gcsafe.}
    makeCurrent: proc (d: EGLDisplay; draw, read: EGLSurface;
                       c: EGLContext): EGLBoolean {.cdecl, gcsafe.}
    swapBuffers: proc (d: EGLDisplay; s: EGLSurface): EGLBoolean {.cdecl, gcsafe.}
    swapInterval: proc (d: EGLDisplay; n: EGLint): EGLBoolean {.cdecl, gcsafe.}
    getError: proc (): EGLint {.cdecl, gcsafe.}

var glesLib: LibHandle

var current*: Egl
  ## The context the GPU renderer draws with (one window).

proc loadEgl(e: var Egl): bool =
  e.lib = loadLib("libEGL.so.1")
  if e.lib == nil: e.lib = loadLib("libEGL.so")
  if e.lib == nil: return false
  template sym(field: untyped; name: string) =
    e.field = cast[typeof(e.field)](symAddr(e.lib, name))
    if e.field == nil: return false
  sym(getProcAddress, "eglGetProcAddress")
  sym(getDisplay, "eglGetDisplay")
  sym(initialize, "eglInitialize")
  sym(terminate, "eglTerminate")
  sym(bindAPI, "eglBindAPI")
  sym(chooseConfig, "eglChooseConfig")
  sym(getConfigAttrib, "eglGetConfigAttrib")
  sym(createContext, "eglCreateContext")
  sym(destroyContext, "eglDestroyContext")
  sym(createWindowSurface, "eglCreateWindowSurface")
  sym(createPbufferSurface, "eglCreatePbufferSurface")
  sym(destroySurface, "eglDestroySurface")
  sym(makeCurrent, "eglMakeCurrent")
  sym(swapBuffers, "eglSwapBuffers")
  sym(swapInterval, "eglSwapInterval")
  sym(getError, "eglGetError")
  e.getPlatformDisplay = cast[typeof(e.getPlatformDisplay)](
    e.getProcAddress("eglGetPlatformDisplayEXT"))
  true

proc close*(e: var Egl) =
  ## The context and its surface let go of.
  if e.dpy != nil:
    if e.makeCurrent != nil: discard e.makeCurrent(e.dpy, nil, nil, nil)
    if e.surf != nil: discard e.destroySurface(e.dpy, e.surf)
    if e.ctx != nil: discard e.destroyContext(e.dpy, e.ctx)
    discard e.terminate(e.dpy)
  e.surf = nil
  e.ctx = nil
  e.dpy = nil
  e.ok = false

proc pickConfig(e: var Egl; surfaceBit: EGLint; visual: int): bool =
  var attrs = [EGL_SURFACE_TYPE, surfaceBit, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
               EGL_RED_SIZE, 8'i32, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_NONE]
  var cfgs: array[64, EGLConfig]
  var n: EGLint
  if e.chooseConfig(e.dpy, addr attrs[0], addr cfgs[0], 64, addr n) == 0 or n <= 0: return false
  e.cfg = cfgs[0]
  if visual != 0:
    # The one whose pixels are the window's own.
    for i in 0 ..< n:
      var v: EGLint
      if e.getConfigAttrib(e.dpy, cfgs[i], EGL_NATIVE_VISUAL_ID, addr v) != 0 and int(v) == visual:
        e.cfg = cfgs[i]
        return true
  true

proc makeContext(e: var Egl): bool =
  discard e.bindAPI(EGL_OPENGL_ES_API)
  var ca = [EGL_CONTEXT_CLIENT_VERSION, 2'i32, EGL_NONE]
  e.ctx = e.createContext(e.dpy, e.cfg, nil, addr ca[0])
  e.ctx != nil

proc openOnWindow*(e: var Egl; xDisplay: pointer; xWindow: uint; visual: int): bool =
  ## A context drawing on X11 window `xWindow` (of `visual`, its id).
  if not loadEgl(e): return false
  if e.getPlatformDisplay != nil:
    e.dpy = e.getPlatformDisplay(EGL_PLATFORM_X11_KHR, xDisplay, nil)
  if e.dpy == nil: e.dpy = e.getDisplay(xDisplay)
  if e.dpy == nil: return false
  var ma, mi: EGLint
  if e.initialize(e.dpy, addr ma, addr mi) == 0:
    e.dpy = nil
    return false
  if not e.pickConfig(EGL_WINDOW_BIT, visual) or not e.makeContext():
    e.close()
    return false
  e.surf = e.createWindowSurface(e.dpy, e.cfg, cast[pointer](xWindow), nil)
  if e.surf == nil or e.makeCurrent(e.dpy, e.surf, e.surf, e.ctx) == 0:
    e.close()
    return false
  discard e.swapInterval(e.dpy, 1)
  e.ok = true
  true

proc openOffscreen*(e: var Egl; w, h: int): bool =
  ## A context drawing into an off-screen surface `w` x `h` (no window, no
  ## display: Mesa's surfaceless platform when there is one).
  if not loadEgl(e): return false
  if e.getPlatformDisplay != nil:
    e.dpy = e.getPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, nil, nil)
  if e.dpy == nil: e.dpy = e.getDisplay(nil)
  if e.dpy == nil: return false
  var ma, mi: EGLint
  if e.initialize(e.dpy, addr ma, addr mi) == 0:
    e.dpy = nil
    return false
  if not e.pickConfig(EGL_PBUFFER_BIT, 0) or not e.makeContext():
    e.close()
    return false
  var sa = [EGL_WIDTH, EGLint(w), EGL_HEIGHT, EGLint(h), EGL_NONE]
  e.surf = e.createPbufferSurface(e.dpy, e.cfg, addr sa[0])
  if e.surf == nil or e.makeCurrent(e.dpy, e.surf, e.surf, e.ctx) == 0:
    e.close()
    return false
  e.ok = true
  true

proc glProc*(e: Egl; name: cstring): pointer =
  ## A GL function: from EGL, else from the GL ES library itself.
  result = e.getProcAddress(name)
  if result == nil:
    if glesLib == nil:
      glesLib = loadLib("libGLESv2.so.2")
      if glesLib == nil: glesLib = loadLib("libGLESv2.so")
    if glesLib != nil: result = symAddr(glesLib, name)

proc swap*(e: Egl): bool =
  ## The frame drawn shown.
  e.ok and e.swapBuffers(e.dpy, e.surf) != 0

proc lastError*(e: Egl): int =
  ## EGL's last error code (0 when it cannot be asked).
  if e.getError == nil: 0 else: int(e.getError())

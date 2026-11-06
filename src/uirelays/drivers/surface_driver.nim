# The relays both phone drivers (Android, iOS) share. Each platform's C or
# Objective-C side owns the window, a frame of pixels and the input, and
# offers the same small `uirelays_*` C API; this module turns it into
# relays. The app draws into pixels (`blitRGBA`); text outside the built-in
# font is drawn by the platform's own text stack, which shapes Arabic and
# other scripts.

import std/os
import ../[coords, screen, input, services]

type
  UrEvent {.bycopy.} = object
    kind, x, y, button, clicks, key, meta: int32
    text: array[8, char]
    pressure, tilt, azimuth, twist: float32   # a pen's (pressure < 0: not a pen)

const
  evMove = 1'i32
  evDown = 2'i32
  evUp = 3'i32
  evWheel = 4'i32
  evKeyDown = 5'i32
  evKeyUp = 6'i32
  evText = 7'i32
  evResize = 8'i32
  evMetrics = 9'i32
  evFocus = 10'i32
  evUnfocus = 11'i32
  evPause = 12'i32
  evResume = 13'i32
  evQuit = 14'i32
  evGesture = 15'i32     # two fingers (Android): x, y their middle; button the phase;
                         # pressure the scale, tilt and azimuth the move

proc urWait(e: ptr UrEvent; timeoutMs: cint): cint {.importc: "uirelays_wait", cdecl.}
proc urWaitWindow() {.importc: "uirelays_wait_window", cdecl.}
proc urLayout(w, h, density, top, left, bottom, right: ptr cint)
  {.importc: "uirelays_layout", cdecl.}
proc urBlit(p: ptr UncheckedArray[uint32]; w, h, dx, dy: cint): cint
  {.importc: "uirelays_blit", cdecl.}
proc urRefresh() {.importc: "uirelays_refresh", cdecl.}
proc urClip(x, y, w, h: cint) {.importc: "uirelays_clip", cdecl.}
proc urSave() {.importc: "uirelays_save", cdecl.}
proc urRestore() {.importc: "uirelays_restore", cdecl.}
proc urTextWidth(s: cstring; n, size: cint): cint {.importc: "uirelays_text_width", cdecl.}
proc urTextDraw(s: cstring; n, size, x, y: cint; fg, bg: uint32): cint
  {.importc: "uirelays_text_draw", cdecl.}
when defined(android):
  proc urTextRender(s: cstring; n, size: cint; fg: uint32; outp: ptr ptr UncheckedArray[uint32];
                       h: ptr cint): cint {.importc: "uirelays_text_render", cdecl.}
proc urClipboardGet(len: ptr cint): cstring {.importc: "uirelays_clipboard_get", cdecl.}
proc urClipboardPut(s: cstring; n: cint) {.importc: "uirelays_clipboard_put", cdecl.}
proc urOpenUrl(s: cstring; n: cint): cint {.importc: "uirelays_open_url", cdecl.}
proc urDataDir(): cstring {.importc: "uirelays_data_dir", cdecl.}
proc urKeyboard(show: cint) {.importc: "uirelays_keyboard", cdecl.}
proc urFinish() {.importc: "uirelays_finish", cdecl.}
proc urTicks(): int64 {.importc: "uirelays_ticks", cdecl.}
proc urMinimize(): cint {.importc: "uirelays_minimize", cdecl.}
proc urHasStorage(): cint {.importc: "uirelays_has_storage", cdecl.}
proc urAskStorage() {.importc: "uirelays_ask_storage", cdecl.}
proc urOpenFile(s: cstring; n, mode: cint): cint {.importc: "uirelays_open_file", cdecl.}
proc urDecodeImage(s: cstring; n, maxW, maxH: cint; w, h: ptr cint):
  ptr UncheckedArray[uint32] {.importc: "uirelays_decode_image", cdecl.}
proc urFill(x, y, w, h: cint; c: uint32) {.importc: "uirelays_fill", cdecl.}
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}
when defined(android):
  proc urCall(name: cstring; nn: cint; arg: cstring; na: cint; len: ptr cint): cstring
    {.importc: "uirelays_call", cdecl.}

var mapKey: proc (code: int32): KeyCode {.nimcall.}
  ## the platform's key codes to ours

proc layoutNow(): ScreenLayout =
  ## `density` is in dots per inch, 160 being 100%.
  var w, h, d, t, l, b, r: cint
  urLayout(addr w, addr h, addr d, addr t, addr l, addr b, addr r)
  ScreenLayout(width: w, height: h, scaleX: 1, scaleY: 1,
               uiScale: max(100, d.int * 100 div 160), fullScreen: true,
               safeTop: t, safeLeft: l, safeBottom: b, safeRight: r,
               touch: true)

proc mapMods(meta: int32): set[Modifier] =
  ## Android's meta bits; the iOS side sends the same ones.
  if (meta and 0x1) != 0: result.incl ShiftPressed       # AMETA_SHIFT_ON
  if (meta and 0x2) != 0: result.incl AltPressed         # AMETA_ALT_ON
  if (meta and 0x1000) != 0: result.incl CtrlPressed     # AMETA_CTRL_ON
  if (meta and 0x10000) != 0: result.incl GuiPressed     # AMETA_META_ON

proc next(e: var Event; timeoutMs: int; flags: set[InputFlag]): bool =
  urKeyboard(cint(WantTextInput in flags))
  var r: UrEvent
  if urWait(addr r, cint(timeoutMs)) == 0: return false
  e = Event()
  case r.kind
  # (every event says which modifiers are held -- the pointer's too, so a
  # Ctrl let go while nothing was typed is let go for the wheel and the
  # clicks; 0x100 of a pointer's `meta`: a mouse or a pen, not a finger)
  of evMove:
    e = Event(kind: MouseMoveEvent, x: r.x, y: r.y,
              mods: mapMods(r.meta), hasMods: true,
              fromMouse: (r.meta and 0x100) != 0)
    if r.pressure >= 0:
      e.pen = true
      e.pressure = r.pressure
      e.tilt = r.tilt
      e.azimuth = r.azimuth
      e.twist = r.twist
  of evDown, evUp:
    e = Event(kind: if r.kind == evDown: MouseDownEvent else: MouseUpEvent,
              x: r.x, y: r.y, clicks: max(1, r.clicks.int),
              button: if r.button == 1: RightButton else: LeftButton,
              mods: mapMods(r.meta), hasMods: true,
              fromMouse: (r.meta and 0x100) != 0)
    if r.pressure >= 0:
      e.pen = true
      e.pressure = r.pressure
      e.tilt = r.tilt
      e.azimuth = r.azimuth
      e.twist = r.twist
  of evWheel:
    e = Event(kind: MouseWheelEvent, x: r.x, y: r.y, mods: mapMods(r.meta), hasMods: true)
  of evKeyDown, evKeyUp:
    e = Event(kind: if r.kind == evKeyDown: KeyDownEvent else: KeyUpEvent,
              key: mapKey(r.key), mods: mapMods(r.meta), hasMods: true)
  of evText:
    e = Event(kind: TextInputEvent)
    for i in 0 .. 3: e.text[i] = r.text[i]
  of evResize: e = Event(kind: WindowResizeEvent, x: r.x, y: r.y)
  of evMetrics:
    let l = layoutNow()
    e = Event(kind: WindowMetricsEvent, x: l.width, y: l.height, scaleX: 1,
              scaleY: 1, uiScale: l.uiScale)
  of evFocus: e = Event(kind: WindowFocusGainedEvent)
  of evUnfocus: e = Event(kind: WindowFocusLostEvent)
  of evPause: e = Event(kind: AppPauseEvent)
  of evResume: e = Event(kind: AppResumeEvent)
  of evQuit: e = Event(kind: QuitEvent)
  of evGesture:
    e = Event(kind: GestureEvent, x: r.x, y: r.y, scale: r.pressure, dx: r.tilt, dy: r.azimuth,
              phase: GesturePhase(clamp(r.button, 0, 2)))
  else: return false
  true

proc pack(c: Color): uint32 =
  (c.r.uint32 shl 16) or (c.g.uint32 shl 8) or c.b.uint32

proc argb(c: Color): uint32 = (c.a.uint32 shl 24) or pack(c)

proc surfaceLine(x1, y1, x2, y2: int; color: Color) =
  # Bresenham, each run of pixels on one row filled at once.
  let c = argb(color)
  var x = x1
  var y = y1
  let dx = abs(x2 - x1)
  let dy = -abs(y2 - y1)
  let sx = if x1 < x2: 1 else: -1
  let sy = if y1 < y2: 1 else: -1
  var err = dx + dy
  var runX = x
  while true:
    let last = x == x2 and y == y2
    let e2 = 2 * err
    var nx = x
    var ny = y
    if e2 >= dy:
      err += dy
      nx += sx
    if e2 <= dx:
      err += dx
      ny += sy
    if last or ny != y:
      urFill(cint min(runX, x), cint y, cint(abs(x - runX) + 1), 1, c)
      if last: break
      runX = nx
    x = nx
    y = ny

proc metricsOf(size: int): FontMetrics =
  FontMetrics(ascent: size * 11 div 13, descent: size - size * 11 div 13,
              lineHeight: size)

proc initSurfaceDriver*(keys: proc (code: int32): KeyCode {.nimcall.}) =
  ## Points the relays at the platform's `uirelays_*` side; `keys` turns its
  ## key codes into `KeyCode`s.
  mapKey = keys
  windowRelays = WindowRelays(
    createWindow: proc (layout: var ScreenLayout; icon: pointer; n: int) =
      urWaitWindow()
      layout = layoutNow(),
    getWindowLayout: proc (): ScreenLayout = layoutNow(),
    refresh: proc () = urRefresh(),
    saveState: proc () = urSave(),
    restoreState: proc () = urRestore(),
    setClipRect: proc (r: Rect) = urClip(cint r.x, cint r.y, cint r.w, cint r.h),
    setCursor: proc (c: CursorKind) = discard,
    setWindowTitle: proc (title: string) = discard)
  drawRelays.fillRect = proc (r: Rect; c: Color) =
    urFill(cint r.x, cint r.y, cint r.w, cint r.h, argb(c))
  drawRelays.drawLine = surfaceLine
  drawRelays.drawPoint = proc (x, y: int; c: Color) =
    urFill(cint x, cint y, 1, 1, argb(c))
  drawRelays.blitRGBA = proc (p: ptr UncheckedArray[uint32]; w, h: int;
                              dst: Rect; f: RGBAFormat): bool =
    urBlit(p, cint w, cint h, cint dst.x, cint dst.y) != 0
  fontRelays = FontRelays(
    openFont: proc (path: string; size: int; style: FontStyles;
                    m: var FontMetrics): Font =
      m = metricsOf(max(1, size))
      Font(max(1, size)),
    closeFont: proc (f: Font) = discard,
    getFontMetrics: proc (f: Font): FontMetrics = metricsOf(int(f)),
    measureText: proc (f: Font; text: string): TextExtent =
      TextExtent(w: urTextWidth(text.cstring, cint text.len, cint f), h: int(f)),
    drawText: proc (f: Font; x, y: int; text: string; fg, bg: Color): TextExtent =
      TextExtent(w: urTextDraw(text.cstring, cint text.len, cint f, cint x,
                                cint y, pack(fg), pack(bg)), h: int(f)))
  when defined(android):
    # The run as pixels, for the app to blend in (not on iOS yet).
    fontRelays.renderText = proc (f: Font; text: string; fg: Color;
                                  pixels: var seq[uint32]): TextExtent =
      var p: ptr UncheckedArray[uint32]
      var h: cint
      let w = urTextRender(text.cstring, cint text.len, cint f, pack(fg), addr p, addr h)
      if w <= 0 or p == nil:
        pixels.setLen 0
        return
      pixels.setLen(int(w) * int(h))
      copyMem(addr pixels[0], p, pixels.len * 4)
      c_free(p)
      TextExtent(w: int(w), h: int(h))
  inputRelays = InputRelays(
    pollEvent: proc (e: var Event; flags: set[InputFlag]): bool =
      next(e, 0, flags),
    waitEvent: proc (e: var Event; t: int; flags: set[InputFlag]): bool =
      next(e, t, flags),
    getTicks: proc (): int = int(urTicks()),
    sleep: proc (ms: int) = os.sleep(ms),
    shutdown: proc () = urFinish())
  clipboardRelays = ClipboardRelays(
    getText: proc (): string =
      var n: cint
      let p = urClipboardGet(addr n)
      if p != nil:
        result = newString(n)
        if n > 0: copyMem(addr result[0], p, n)
        c_free(p),
    putText: proc (t: string) = urClipboardPut(t.cstring, cint t.len))
  systemRelays.dataDir = proc (app: string): string =
    result = $urDataDir()
    try: createDir(result) except OSError: discard
  systemRelays.openUrl = proc (url: string): bool =
    urOpenUrl(url.cstring, cint url.len) != 0
  systemRelays.openFile = proc (path: string; share: bool): bool =
    urOpenFile(path.cstring, cint path.len, cint(if share: 2 else: 0)) != 0
  systemRelays.storageAccess = proc (): bool = urHasStorage() != 0
  systemRelays.requestStorageAccess = proc () = urAskStorage()
  systemRelays.minimize = proc (): bool = urMinimize() != 0
  when defined(android):
    systemRelays.call = proc (name, arg: string): string =
      var n: cint
      let r = urCall(cstring(name), cint(name.len), cstring(arg), cint(arg.len), addr n)
      if r == nil: return "\0"                    # failed
      result = newString(n)
      if n > 0: copyMem(addr result[0], r, n)
      c_free(r)
  systemRelays.decodeImage = proc (path: string; maxW, maxH: int):
                                  tuple[w, h: int; px: seq[uint32]] =
    var w, h: cint
    let p = urDecodeImage(path.cstring, cint path.len, cint maxW, cint maxH,
                           addr w, addr h)
    if p != nil:
      result.w = w
      result.h = h
      result.px = newSeq[uint32](w.int * h.int)
      if w > 0 and h > 0: copyMem(addr result.px[0], p, w.int * h.int * 4)
      c_free(p)

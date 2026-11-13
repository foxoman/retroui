## Wayland, spoken directly: the driver talks to the compositor over its
## socket with the protocol's own messages (`wlwire`), with no libwayland,
## no toolkit and nothing to link. What it uses:
##
## - `wl_compositor`, `wl_shm`, `xdg_wm_base`: windows, drawn by the driver
##   into shared memory (`PixBuf`), two or three buffers a window, each
##   brought up to date with what the one shown before it got, so a frame
##   sends only what changed (`damage_buffer`).
## - `wl_seat`: the mouse (and the wheel in notches, touch pads' too),
##   the keyboard with the system's layout (libxkbcommon, loaded at run
##   time; a US keyboard without it), dead keys and compose, key repeat as
##   the compositor says, and touch (the first finger as the mouse).
## - `wl_output`, `wp_fractional_scale_v1` + `wp_viewporter`: the screen's
##   scale, fractional too; the window is drawn in device pixels and
##   `uiScale` says how much to enlarge (as on X11).
## - `wl_data_device_manager`: the clipboard, and files dropped on a window.
## - `zxdg_decoration_manager_v1`: the system's frame where the compositor
##   draws one; else (GNOME) the app draws its own, and its title bar and
##   edges move and size the window (`xdg_toplevel.move`, `.resize`).
## - `wp_cursor_shape_manager_v1`: the system's cursors; else the classic
##   ones, drawn at the screen's scale (`cursorart`).
## - `zwp_text_input_v3`: input methods (composing, then committing).
## - `xdg_activation_v1`: a window started from a launcher comes to the
##   front.
## - Text in the system's fonts through fontconfig and FreeType (`ftfonts`);
##   screen readers through AT-SPI, as on X11.
## - More windows than the program's own (`windowsRelays`), each a
##   toplevel whose parent is the program's window.
##
## `-d:wayland` builds with this driver alone; a Linux build without it has
## X11 and this one, and takes this one when `RETRO_DRIVER=wayland`, or when
## there is a Wayland session and no X display (see `backend`).

import std/[posix, os, strutils, tables]
import ../[coords, input, screen, services, access, atspi]
import wlwire, pixbuf, ftfonts, xkbload, keysyms, cursorart

type
  ObjKind = enum
    okNone, okRegistry, okCallback, okCompositor, okShm, okBuffer, okSurface,
    okWmBase, okXdgSurface, okToplevel, okSeat, okPointer, okKeyboard, okTouch,
    okOutput, okDataManager, okDataDevice, okDataSource, okDataOffer,
    okDecoManager, okDeco, okFracManager, okFrac, okViewporter, okViewport,
    okShapeManager, okShapeDevice, okTextInputManager, okTextInput, okActivation,
    okActivationToken, okCursorSurface

  Obj = object
    kind: ObjKind
    win: int          ## the window's number (surfaces, buffers, its objects)
    tag: int          ## a buffer's place among its window's; an output's index

  WlBuf = object
    id: uint32        ## the wl_buffer
    mem: pointer
    size: int
    w, h: int
    busy: bool        ## the compositor has it (attached, not released)
    stale: Rect       ## what changed on the window since it was last shown
    fresh: bool       ## never drawn: all of it is stale

  WlWin = ref object
    id: int           ## 0 the program's window, else `openWindow`'s
    surface, xdgSurface, toplevel, deco, frac, viewport: uint32
    lw, lh: int       ## its size in the compositor's (logical) units
    w, h: int         ## ... in pixels: what it is drawn at
    scale120: int     ## pixels a unit, in 120ths (fractional scaling)
    outScale: int     ## the scale of the outputs it is on (integer)
    prefScale: int    ## wl_surface's preferred_buffer_scale (0: not said)
    bufScale: int     ## what was set with set_buffer_scale
    viewW, viewH: int ## what the viewport was set to
    configured: bool
    pendW, pendH: int
    pendStates: string
    maximized, fullscreen, activated: bool
    suspended: bool   ## (xdg-shell 6: minimized or fully covered -- not seen)
    floatW, floatH: int ## its size before it was maximized (given back after)
    ssd: bool         ## the compositor draws its frame
    bufs: seq[WlBuf]
    back, front: int  ## the buffer being drawn, the one last shown (-1: none)
    pb: PixBuf
    outputs: seq[uint32]
    closing: bool

  Output = object
    id: uint32
    name: uint32      ## the registry's
    scale: int
    w, h: int         ## its mode, in pixels

  Global = object
    name: uint32
    iface: string
    version: uint32

var
  conn: WlConn
  objs: Table[uint32, Obj]
  globals: seq[Global]
  registry: uint32
  compositorId, shmId, wmBaseId, seatId, dataManagerId, decoManagerId: uint32
  fracManagerId, viewporterId, shapeManagerId, textInputManagerId, activationId: uint32
  compositorVersion, seatVersion, wmBaseVersion, dataVersion: uint32
  outputs: seq[Output]
  wins: seq[WlWin]                ## the program's window first
  cur: WlWin                      ## the window drawing goes to
  nextWinId = 1
  eventQueue: seq[input.Event]
  syncDone: seq[uint32]           ## callbacks that came back
  failedOnce = false

  # the seat
  pointerId, keyboardId, touchId, dataDeviceId, shapeDeviceId, textInputId: uint32
  seatCaps: uint32
  pointerWin = -1                 ## the window the pointer is in (its number)
  pointerX, pointerY: float       ## ... where, in its units
  enterSerial, inputSerial, buttonSerial: uint32
  buttonsDown: set[MouseButton]
  dragPending = false             ## the compositor moves or sizes the window
  lastClickTime: uint32
  lastClickX, lastClickY, clickCount: int
  lastClickButton: MouseButton
  axisAcc: array[2, float]        ## the wheel: what came this frame, in 120ths of a notch
  axisDiscrete: array[2, int]
  axisValue120 = false
  axisFinger = false
  axisFrac: array[2, float]       ## (fractions of a notch kept)
  keyboardWin = -1
  xkb: XkbKeyboard
  mods: set[Modifier]
  shiftDown = false
  repeatRate = 25
  repeatDelay = 600
  repeatKey = -1                  ## the key held (evdev code)
  repeatAt = 0                    ## when it repeats next (getTicks)
  touchPrimary = -1               ## the finger that is the mouse
  touchX, touchY: float

  # the clipboard and drops
  ownSource: uint32               ## our selection's wl_data_source (0: not ours)
  clipText: string
  clipPng: string                 ## a picture put on the clipboard ("" none: the text)
  offerMimes: Table[uint32, seq[string]]
  selectionOffer: uint32
  dndOffer: uint32
  dndWin = -1
  dndX, dndY: float
  dndSerial: uint32

  # the cursor
  cursorKind = curDefault
  cursorSurface: uint32
  cursorBufs: Table[(CursorKind, int), WlBuf]
  cursorHeight = 0

  # what the app asked for
  wantSystemFrame = false
  systemFrameNow = false
  resizable = true
  appTitle = ""

  # input methods
  tiPreedit = ""
  tiPreeditCaret = 0
  tiCommit = ""
  tiHasPreedit = false
  tiEnabled = false
  tiSerial = 0'u32
  tiCaret = Rect()

  activationToken = ""

# ---- time ----

proc wlTicks(): int =
  var ts: Timespec
  discard clock_gettime(CLOCK_MONOTONIC, ts)
  int(ts.tv_sec.int64 * 1000 + ts.tv_nsec.int64 div 1_000_000)

proc wlDelay(ms: int) =
  if ms > 0: os.sleep(ms)

# ---- objects ----

proc obj(id: uint32; kind: ObjKind; win = 0; tag = 0): uint32 {.discardable.} =
  objs[id] = Obj(kind: kind, win: win, tag: tag)
  id

proc newObj(kind: ObjKind; win = 0; tag = 0): uint32 =
  obj(conn.newId(), kind, win, tag)

proc winById(id: int): WlWin =
  for w in wins:
    if w.id == id: return w
  nil

proc winOfSurface(s: uint32): WlWin =
  for w in wins:
    if w.surface == s: return w
  nil

var debugEvents = getEnv("RETRO_WAYLAND_DEBUG") == "2"

proc pushEvent(e: input.Event; win = 0) =
  var e = e
  e.window = win
  if debugEvents:
    stderr.writeLine "wayland event: ", e.kind, " window ", win, " at ", e.x, ",", e.y,
                     " key ", e.key, " button ", e.button, " clicks ", e.clicks, " mods ", e.mods
  # (a move behind another not read yet replaces it)
  if e.kind == MouseMoveEvent and eventQueue.len > 0 and
     eventQueue[^1].kind == MouseMoveEvent and eventQueue[^1].window == win:
    eventQueue[^1] = e
  else:
    eventQueue.add e

# ---- scale ----

proc uiScaleOf(w: WlWin): int = (w.scale120 * 100 + 60) div 120

proc fractional(w: WlWin): bool = w.frac != 0 and w.viewport != 0

proc toPx(w: WlWin; v: float): int =
  ## A length in the compositor's units, in the window's pixels.
  int(v * float(w.scale120) / 120.0)

proc computeSize(w: WlWin) =
  if w.fractional:
    w.w = max(1, (w.lw * w.scale120 + 60) div 120)
    w.h = max(1, (w.lh * w.scale120 + 60) div 120)
  else:
    let s = max(1, w.scale120 div 120)
    w.w = max(1, w.lw * s)
    w.h = max(1, w.lh * s)

proc outputsScale(): int =
  result = 1
  for o in outputs: result = max(result, o.scale)

proc rescale(w: WlWin) =
  ## The window's scale from what the compositor said, and its size with
  ## it; the app told when they changed.
  let oldW = w.w
  let oldH = w.h
  let oldScale = w.scale120
  if not w.fractional:
    var s = if w.prefScale > 0: w.prefScale else: 0
    if s == 0:
      for o in outputs:
        if o.id in w.outputs: s = max(s, o.scale)
    if s == 0: s = outputsScale()
    w.scale120 = s * 120
  computeSize(w)
  if w.w != oldW or w.h != oldH or w.scale120 != oldScale:
    if w.id == 0:
      pushEvent(input.Event(kind: WindowMetricsEvent, x: w.w, y: w.h, scaleX: 1, scaleY: 1,
                            uiScale: w.uiScaleOf))
    else:
      pushEvent(input.Event(kind: WindowResizeEvent, x: w.w, y: w.h), w.id)

# ---- buffers ----

proc destroyBuf(b: var WlBuf) =
  if b.id != 0:
    conn.send(b.id, 0)                      # wl_buffer.destroy
  if b.mem != nil: discard munmap(b.mem, b.size)
  b = WlBuf()

proc newBuf(w, h: int; format: uint32; win, tag: int; kind = okBuffer): WlBuf =
  let size = w * h * 4
  let fd = memFile(size)
  if fd < 0: return
  let mem = mmap(nil, size, PROT_READ or PROT_WRITE, MAP_SHARED, fd, 0)
  if mem == MAP_FAILED:
    discard posix.close(fd)
    return
  let pool = conn.newId()
  conn.send(shmId, 0, wu(pool), wfd(fd), wi(size))            # wl_shm.create_pool
  let id = newObj(kind, win, tag)
  conn.send(pool, 0, wu(id), wi(0), wi(w), wi(h), wi(w * 4), wu(format))  # create_buffer
  conn.send(pool, 1)                                          # wl_shm_pool.destroy
  discard conn.flush()
  discard posix.close(fd)
  WlBuf(id: id, mem: mem, size: size, w: w, h: h, fresh: true)

proc dispatch()

proc ensureBack(w: WlWin): bool =
  ## A buffer to draw the window's next frame in, up to date with the one
  ## shown.
  if w == nil or conn == nil or conn.failed or not w.configured: return false
  if w.back >= 0: return true
  # (buffers of another size are let go of once the compositor is done with them)
  var i = 0
  while i < w.bufs.len:
    if (w.bufs[i].w != w.w or w.bufs[i].h != w.h) and not w.bufs[i].busy:
      destroyBuf(w.bufs[i])
      w.bufs.delete(i)
      if w.front == i: w.front = -1
      elif w.front > i: dec w.front
    else: inc i
  var pick = -1
  let t0 = wlTicks()
  while true:
    for j, b in w.bufs:
      if not b.busy and b.w == w.w and b.h == w.h:
        pick = j
        break
    if pick >= 0: break
    var same = 0
    for b in w.bufs:
      if b.w == w.w and b.h == w.h: inc same
    let waited = wlTicks() - t0
    if same < 3 or (same < 4 and waited >= 16):
      let b = newBuf(w.w, w.h, 1, w.id, w.bufs.len)          # XRGB8888
      if b.id == 0: return false
      w.bufs.add b
      pick = w.bufs.len - 1
      break
    if waited >= 100:
      # (the compositor keeps them all -- a window it does not show: the
      # one it has longest)
      for j, b in w.bufs:
        if j != w.front and b.w == w.w and b.h == w.h:
          pick = j
          break
      if pick < 0: pick = w.front
      break
    discard conn.flush()
    if conn.readSome(5): dispatch()
    if conn.failed: return false
  # its tags follow its place
  for j in 0 ..< w.bufs.len:
    if w.bufs[j].id in objs: objs[w.bufs[j].id].tag = j
  var b = addr w.bufs[pick]
  w.pb.attach(cast[ptr UncheckedArray[uint32]](b.mem), b.w, b.h, b.w)
  if w.front >= 0 and w.front != pick and w.front < w.bufs.len:
    let f = w.bufs[w.front]
    if f.w == b.w and f.h == b.h:
      var src: PixBuf
      src.attach(cast[ptr UncheckedArray[uint32]](f.mem), f.w, f.h, f.w)
      let r = if b.fresh: Rect(x: 0, y: 0, w: b.w, h: b.h) else: b.stale
      w.pb.copyFrom(src, r)
  b.fresh = false
  b.stale = Rect()
  w.pb.damage = Rect()
  w.back = pick
  true

proc present(w: WlWin) =
  ## What was drawn in the back buffer shown.
  if w == nil or w.back < 0 or conn == nil or conn.failed: return
  let d = w.pb.takeDamage()
  if d.w <= 0 or d.h <= 0: return            # (kept: the next frame draws on it)
  let i = w.back
  if w.bufs[i].w != w.w or w.bufs[i].h != w.h:
    # (drawn at the size the window had: the app draws it again at the new
    # one, told by the event that came)
    w.back = -1
    w.bufs[i].fresh = true
    return
  conn.send(w.surface, 1, wu(w.bufs[i].id), wi(0), wi(0))   # attach
  if compositorVersion >= 4:
    conn.send(w.surface, 9, wi(d.x), wi(d.y), wi(d.w), wi(d.h))   # damage_buffer
  else:
    let s = max(1, w.bufScale)
    conn.send(w.surface, 2, wi(d.x div s), wi(d.y div s),
              wi((d.w + s - 1) div s + 1), wi((d.h + s - 1) div s + 1))
  if w.fractional:
    if w.viewW != w.lw or w.viewH != w.lh:
      conn.send(w.viewport, 2, wi(w.lw), wi(w.lh))            # set_destination
      w.viewW = w.lw
      w.viewH = w.lh
  else:
    let s = max(1, w.scale120 div 120)
    if s != w.bufScale and compositorVersion >= 3:
      conn.send(w.surface, 8, wi(s))                          # set_buffer_scale
      w.bufScale = s
  conn.send(w.surface, 6)                                     # commit
  w.bufs[i].busy = true
  for j in 0 ..< w.bufs.len:
    if j != i: w.bufs[j].stale = union(w.bufs[j].stale, d)
  w.front = i
  w.back = -1
  discard conn.flush()

# ---- the connection ----

proc fail(why: string) =
  if not failedOnce:
    failedOnce = true
    stderr.writeLine "wayland: ", why
    pushEvent(input.Event(kind: QuitEvent))

proc bindGlobal(g: Global; kind: ObjKind; maxVersion: uint32; tag = 0): uint32 =
  let v = min(g.version, maxVersion)
  result = newObj(kind, 0, tag)
  conn.send(registry, 0, wu(g.name), ws(g.iface), wu(v), wu(result))

proc roundtrip(timeoutMs = 3000): bool =
  ## Everything asked so far answered.
  if conn == nil or conn.failed: return false
  let cb = newObj(okCallback)
  conn.send(1, 0, wu(cb))                                     # wl_display.sync
  if not conn.flush(): return false
  let t0 = wlTicks()
  while cb notin syncDone:
    let left = timeoutMs - (wlTicks() - t0)
    if left <= 0 or conn.failed: return false
    if conn.readSome(left): dispatch()
  syncDone.delete(syncDone.find(cb))
  true

proc bindSeatParts()

proc ensureConn(): bool =
  if conn != nil: return not conn.failed
  conn = wlConnect()
  if conn == nil: return false
  registry = newObj(okRegistry)
  conn.send(1, 1, wu(registry))                               # get_registry
  if not roundtrip(): return false
  let debug = getEnv("RETRO_WAYLAND_DEBUG") == "1"
  for g in globals:
    if debug: stderr.writeLine "wayland: ", g.iface, " ", g.version
    case g.iface
    of "wl_compositor":
      compositorVersion = min(g.version, 6)
      compositorId = bindGlobal(g, okCompositor, 6)
    of "wl_shm": shmId = bindGlobal(g, okShm, 1)
    of "xdg_wm_base":
      # (6: a toplevel says when it is suspended -- minimized, or covered)
      wmBaseVersion = min(g.version, 6)
      wmBaseId = bindGlobal(g, okWmBase, 6)
    of "wl_seat":
      if seatId == 0:
        seatVersion = min(g.version, 8)
        seatId = bindGlobal(g, okSeat, 8)
    of "wl_output":
      outputs.add Output(scale: 1, name: g.name)
      outputs[^1].id = bindGlobal(g, okOutput, 4)
    of "wl_data_device_manager":
      dataVersion = min(g.version, 3)
      dataManagerId = bindGlobal(g, okDataManager, 3)
    of "zxdg_decoration_manager_v1": decoManagerId = bindGlobal(g, okDecoManager, 1)
    of "wp_fractional_scale_manager_v1": fracManagerId = bindGlobal(g, okFracManager, 1)
    of "wp_viewporter": viewporterId = bindGlobal(g, okViewporter, 1)
    of "wp_cursor_shape_manager_v1": shapeManagerId = bindGlobal(g, okShapeManager, 1)
    of "zwp_text_input_manager_v3": textInputManagerId = bindGlobal(g, okTextInputManager, 1)
    of "xdg_activation_v1": activationId = bindGlobal(g, okActivation, 1)
    else: discard
  if compositorId == 0 or shmId == 0 or wmBaseId == 0:
    conn.close()
    return false
  discard roundtrip()                       # (the seat's parts, the outputs' scales)
  bindSeatParts()
  discard roundtrip()
  true

proc wlAvailable*(): bool =
  ## A Wayland compositor is there to talk to (one with the windows this
  ## driver needs).
  ensureConn()

# ---- the seat ----

proc bindSeatParts() =
  if seatId == 0: return
  if (seatCaps and 1) != 0 and pointerId == 0:
    pointerId = newObj(okPointer)
    conn.send(seatId, 0, wu(pointerId))                       # get_pointer
    if shapeManagerId != 0:
      shapeDeviceId = newObj(okShapeDevice)
      conn.send(shapeManagerId, 1, wu(shapeDeviceId), wu(pointerId))
  if (seatCaps and 2) != 0 and keyboardId == 0:
    keyboardId = newObj(okKeyboard)
    conn.send(seatId, 1, wu(keyboardId))                      # get_keyboard
  if (seatCaps and 4) != 0 and touchId == 0:
    touchId = newObj(okTouch)
    conn.send(seatId, 2, wu(touchId))                         # get_touch
  if dataManagerId != 0 and dataDeviceId == 0:
    dataDeviceId = newObj(okDataDevice)
    conn.send(dataManagerId, 1, wu(dataDeviceId), wu(seatId)) # get_data_device
  if textInputManagerId != 0 and textInputId == 0:
    textInputId = newObj(okTextInput)
    conn.send(textInputManagerId, 1, wu(textInputId), wu(seatId))
  discard conn.flush()

# ---- cursors ----

proc shapeOf(c: CursorKind): uint32 =
  case c
  of curDefault, curArrow: 1
  of curIbeam: 9
  of curWait: 6
  of curCrosshair: 8
  of curHand: 4
  of curSizeNS: 27
  of curSizeWE: 26
  of curSizeNWSE: 29
  of curSizeNESW: 28
  of curMove: 13

proc drawnCursor(c: CursorKind; k: int): WlBuf =
  ## Cursor `c`, each pixel of its drawing `k` x `k` (made once, kept).
  if (c, k) in cursorBufs: return cursorBufs[(c, k)]
  let art = classicCursorArt(c)
  var aw = 0
  for r in art.rows: aw = max(aw, r.len)
  let w = aw * k
  let h = art.rows.len * k
  result = newBuf(w, h, 0, -1, 0)                             # ARGB8888
  if result.id == 0: return
  let px = cast[ptr UncheckedArray[uint32]](result.mem)
  for y in 0 ..< h:
    let row = art.rows[y div k]
    for x in 0 ..< w:
      let col = x div k
      let ch = if col < row.len: row[col] else: ' '
      px[y * w + x] = case ch
        of 'X': 0xFF000000'u32
        of '.': 0xFFFFFFFF'u32
        else: 0'u32
  cursorBufs[(c, k)] = result

proc applyCursor() =
  if pointerId == 0 or enterSerial == 0 or pointerWin < 0: return
  if shapeDeviceId != 0:
    conn.send(shapeDeviceId, 1, wu(enterSerial), wu(shapeOf(cursorKind)))
    cursorHeight = 0
  else:
    let w = winById(pointerWin)
    let k = if w != nil: max(1, (w.scale120 + 60) div 120) else: 1
    let b = drawnCursor(cursorKind, k)
    if b.id == 0: return
    if cursorSurface == 0:
      cursorSurface = newObj(okCursorSurface)
      conn.send(compositorId, 0, wu(cursorSurface))           # create_surface
    let art = classicCursorArt(cursorKind)
    conn.send(cursorSurface, 1, wu(b.id), wi(0), wi(0))       # attach
    if compositorVersion >= 3: conn.send(cursorSurface, 8, wi(k))  # set_buffer_scale
    conn.send(cursorSurface, 2, wi(0), wi(0), wi(b.w), wi(b.h))
    conn.send(cursorSurface, 6)                               # commit
    conn.send(pointerId, 0, wu(enterSerial), wu(cursorSurface), wi(art.hx), wi(art.hy))
    cursorHeight = b.h
  discard conn.flush()

proc wlSetCursor(c: CursorKind) =
  if c == cursorKind: return
  cursorKind = c
  applyCursor()

proc wlPointerHeight(): int =
  let w = if pointerWin >= 0: winById(pointerWin) else: (if wins.len > 0: wins[0] else: nil)
  if cursorHeight > 0: cursorHeight
  elif w != nil: 24 * w.scale120 div 120
  else: 24

# ---- keys ----

proc modsAfter(sym: uint32; down: bool): set[Modifier] =
  ## The modifiers after a key: Wayland says them after the key's event.
  result = mods
  let m = case int(sym)
          of 0xffe1, 0xffe2: ShiftPressed
          of 0xffe3, 0xffe4: CtrlPressed
          of 0xffe7, 0xffe8, 0xffe9, 0xffea: AltPressed
          of 0xffeb, 0xffec: GuiPressed
          else: return
  if down: result.incl m else: result.excl m

proc keyOfCode(code: int; sym: uint32): KeyCode =
  result = keyOfSym(sym.uint)
  if result != KeyNone: return
  # (a letter of another script: the key the Latin layout has there)
  for s in xkb.latinSyms(uint32(code + 8)):
    result = keyOfSym(s.uint)
    if result != KeyNone: return
  result = keyOfSym(usKeysym(code, false))

proc pushText(text: string; win: int) =
  if text.len == 0 or text[0].uint8 < 32 or text[0].uint8 == 127: return
  var i = 0
  while i < text.len:
    var te = input.Event(kind: TextInputEvent)
    var k = 0
    while true:
      if k < te.text.len: te.text[k] = text[i]
      inc k
      inc i
      if i >= text.len or (text[i].uint8 and 0xC0) != 0x80: break
    pushEvent(te, win)

proc keyPress(code: int; down, repeat: bool) =
  let win = max(0, keyboardWin)
  var sym: uint32
  var text = ""
  if xkb.ready:
    sym = xkb.sym(uint32(code + 8))
    if down: text = xkb.text(uint32(code + 8))
  else:
    sym = uint32(usKeysym(code, shiftDown))
    if down and CtrlPressed notin mods: text = symText(sym.uint)
  if down and not repeat and xkb.ready and sym != 0:
    var composed = text
    let st = xkb.compose(sym, composed)
    if st == XKB_COMPOSE_COMPOSING or st == XKB_COMPOSE_CANCELLED: text = ""
    elif st == XKB_COMPOSE_COMPOSED: text = composed
  if sym == 0xffe1 or sym == 0xffe2: shiftDown = down
  var e = input.Event(kind: if down: KeyDownEvent else: KeyUpEvent, hasMods: true)
  e.key = keyOfCode(code, sym)
  e.mods = modsAfter(sym, down)
  pushEvent(e, win)
  if down: pushText(text, win)

# ---- the clipboard ----

proc readAll(fd: cint; timeoutMs: int): string =
  ## What comes through `fd` until it closes (or nothing comes for a while).
  var buf: array[4096, char]
  var p = TPollfd(fd: fd, events: POLLIN)
  while result.len < 64 * 1024 * 1024:
    if poll(addr p, 1, cint(timeoutMs)) <= 0: break
    let n = posix.read(fd, addr buf[0], buf.len)
    if n <= 0: break
    let at = result.len
    result.setLen(at + n)
    copyMem(addr result[at], addr buf[0], n)

proc receive(offer: uint32; mime: string): string =
  ## What an offer has as `mime`.
  var fds: array[2, cint]
  if pipe(fds) != 0: return ""
  discard fcntl(fds[0], F_SETFD, FD_CLOEXEC)
  conn.send(offer, 1, ws(mime), wfd(fds[1]))                  # wl_data_offer.receive
  discard conn.flush()
  discard posix.close(fds[1])
  result = readAll(fds[0], 1000)
  discard posix.close(fds[0])

proc bestText(mimes: seq[string]): string =
  for m in ["text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "TEXT", "STRING"]:
    if m in mimes: return m

proc wlGetClipboardText(): string =
  if ownSource != 0: return clipText
  if conn == nil or selectionOffer == 0: return ""
  let mime = bestText(offerMimes.getOrDefault(selectionOffer))
  if mime.len == 0: return ""
  receive(selectionOffer, mime)

proc ownSelection(mimes: openArray[string]): bool =
  ## (a data source of ours with `mimes`, the selection now)
  if conn == nil or dataManagerId == 0 or dataDeviceId == 0: return false
  if ownSource != 0:
    conn.send(ownSource, 1)                                   # destroy
  ownSource = newObj(okDataSource)
  conn.send(dataManagerId, 0, wu(ownSource))                  # create_data_source
  for m in mimes:
    conn.send(ownSource, 0, ws(m))                            # offer
  conn.send(dataDeviceId, 1, wu(ownSource), wu(inputSerial))  # set_selection
  discard conn.flush()
  true

proc wlPutClipboardText(text: string) =
  clipText = text
  clipPng = ""
  discard ownSelection(["text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "TEXT", "STRING"])

proc wlGetClipboardImage(): ClipImage =
  if ownSource != 0: return ClipImage(png: clipPng)
  if conn == nil or selectionOffer == 0 or
     "image/png" notin offerMimes.getOrDefault(selectionOffer): return
  result.png = receive(selectionOffer, "image/png")

proc wlPutClipboardImage(png: string; w, h: int; px: seq[uint32]): bool =
  if png.len == 0: return false
  clipPng = png
  clipText = ""
  ownSelection(["image/png"])

proc fileUris(list: string): seq[string] =
  ## The files of a text/uri-list.
  for line in list.splitLines:
    let l = line.strip
    if l.len == 0 or l[0] == '#' or not l.startsWith("file://"): continue
    var p = l[7 .. ^1]
    if not p.startsWith("/"):
      let slash = p.find('/')
      if slash < 0: continue
      p = p[slash .. ^1]                     # (file://host/path)
    var s = ""
    var i = 0
    while i < p.len:
      if p[i] == '%' and i + 2 < p.len:
        try:
          s.add char(parseHexInt(p[i + 1 .. i + 2]))
          i += 3
          continue
        except ValueError: discard
      s.add p[i]
      inc i
    result.add s

proc dropOffer(id: uint32) =
  if id == 0: return
  conn.send(id, 2)                                            # wl_data_offer.destroy
  offerMimes.del id

# ---- events ----

proc handleConfigure(w: WlWin; serial: uint32) =
  let wasMax = w.maximized
  let wasFull = w.fullscreen
  let wasActive = w.activated
  let wasSuspended = w.suspended
  if not wasMax and not wasFull and w.configured:
    w.floatW = w.lw
    w.floatH = w.lh
  w.maximized = false
  w.fullscreen = false
  w.activated = false
  w.suspended = false
  var i = 0
  while i + 4 <= w.pendStates.len:
    var st: uint32
    copyMem(addr st, unsafeAddr w.pendStates[i], 4)
    case st
    of 1: w.maximized = true
    of 2: w.fullscreen = true
    of 4: w.activated = true
    of 9: w.suspended = true
    else: discard
    i += 4
  if w.pendW > 0 and w.pendH > 0:
    w.lw = w.pendW
    w.lh = w.pendH
  elif (wasMax or wasFull) and not w.maximized and not w.fullscreen and w.floatW > 0:
    # (restored, the size left to the window: the one it had)
    w.lw = w.floatW
    w.lh = w.floatH
  conn.send(w.xdgSurface, 4, wu(serial))                      # ack_configure
  let first = not w.configured
  w.configured = true
  let oldW = w.w
  let oldH = w.h
  rescale(w)
  if not first and (w.w != oldW or w.h != oldH):
    discard   # (rescale told the app)
  if w.id == 0 and not first:
    if w.maximized != wasMax:
      pushEvent(input.Event(kind: WindowResizeEvent, x: w.w, y: w.h))
  if w.activated != wasActive and not first:
    pushEvent(input.Event(kind: if w.activated: WindowFocusGainedEvent
                                else: WindowFocusLostEvent), w.id)
  if w.id == 0 and w.suspended != wasSuspended:
    pushEvent(input.Event(kind: if w.suspended: WindowHiddenEvent else: WindowShownEvent))

proc flushAxis() =
  ## The wheel's notches of this frame, as the app counts them (up: y > 0).
  for axis in 0 .. 1:
    var notches = 0.0
    if axisValue120 and axisAcc[axis] != 0: notches = axisAcc[axis] / 120.0
    elif axisDiscrete[axis] != 0: notches = float(axisDiscrete[axis])
    elif axisAcc[axis] != 0: notches = axisAcc[axis] / 10.0  # (surface units: 10 a notch)
    axisAcc[axis] = 0
    axisDiscrete[axis] = 0
    if notches == 0: continue
    axisFrac[axis] += notches
    let whole = int(axisFrac[axis])
    if whole == 0: continue
    axisFrac[axis] -= float(whole)
    var e = input.Event(kind: MouseWheelEvent, hasMods: true, mods: mods)
    if axis == 0: e.y = -whole else: e.x = whole
    pushEvent(e, max(0, pointerWin))
  axisValue120 = false

proc releaseDrag() =
  ## The compositor is done moving or sizing the window: the press that
  ## started it is let go of, as the app expects.
  if dragPending:
    dragPending = false
    buttonsDown.excl LeftButton
    let w = winById(max(0, pointerWin))
    var e = input.Event(kind: MouseUpEvent, hasMods: true, mods: mods, button: LeftButton)
    if w != nil:
      e.x = w.toPx(pointerX)
      e.y = w.toPx(pointerY)
    pushEvent(e, max(0, pointerWin))

proc pointerEvent(m: var WlMsg) =
  if m.obj != pointerId: return                               # (one let go of)
  case m.op
  of 0:                                                       # enter
    let serial = m.u32
    let s = m.u32
    let x = m.fixed
    let y = m.fixed
    let w = winOfSurface(s)
    if w == nil: return
    enterSerial = serial
    pointerWin = w.id
    pointerX = x
    pointerY = y
    releaseDrag()
    applyCursor()
    pushEvent(input.Event(kind: MouseMoveEvent, hasMods: true, mods: mods,
                          x: w.toPx(x), y: w.toPx(y)), w.id)
  of 1:                                                       # leave
    discard m.u32
    let s = m.u32
    let w = winOfSurface(s)
    if w != nil and buttonsDown.len == 0 and not dragPending:
      pushEvent(input.Event(kind: MouseMoveEvent, hasMods: true, mods: mods,
                            x: OutsideWindow, y: OutsideWindow), w.id)
    pointerWin = -1
  of 2:                                                       # motion
    discard m.u32
    pointerX = m.fixed
    pointerY = m.fixed
    let w = winById(pointerWin)
    if w == nil: return
    releaseDrag()
    pushEvent(input.Event(kind: MouseMoveEvent, hasMods: true, mods: mods,
                          x: w.toPx(pointerX), y: w.toPx(pointerY)), w.id)
  of 3:                                                       # button
    let serial = m.u32
    let time = m.u32
    let button = m.u32
    let state = m.u32
    inputSerial = serial
    let w = winById(pointerWin)
    if w == nil: return
    let b = case button
      of 0x110: LeftButton
      of 0x111: RightButton
      of 0x112: MiddleButton
      of 0x113: BackButton
      of 0x114: ForwardButton
      else: return
    var e = input.Event(kind: MouseDownEvent, hasMods: true, mods: mods, button: b,
                        x: w.toPx(pointerX), y: w.toPx(pointerY))
    if state == 1:
      if dragPending: releaseDrag()
      buttonSerial = serial
      buttonsDown.incl b
      let near = max(4, 4 * w.uiScaleOf div 100)
      if b == lastClickButton and time - lastClickTime < 500 and
         abs(e.x - lastClickX) < near and abs(e.y - lastClickY) < near:
        inc clickCount
      else:
        clickCount = 1
      lastClickButton = b
      lastClickTime = time
      lastClickX = e.x
      lastClickY = e.y
      e.clicks = clickCount
    else:
      e.kind = MouseUpEvent
      if b notin buttonsDown: return                        # (a drag's, told already)
      buttonsDown.excl b
    pushEvent(e, w.id)
  of 4:                                                       # axis
    discard m.u32
    let axis = int(m.u32)
    let v = m.fixed
    if axis in 0 .. 1 and not axisValue120: axisAcc[axis] += v
    if pointerId != 0 and seatVersion < 5: flushAxis()
  of 5: flushAxis()                                           # frame
  of 6: axisFinger = m.u32 == 1                               # axis_source
  of 8:                                                       # axis_discrete
    let axis = int(m.u32)
    let d = m.i32
    if axis in 0 .. 1: axisDiscrete[axis] += d
  of 9:                                                       # axis_value120
    let axis = int(m.u32)
    let v = m.i32
    if axis in 0 .. 1:
      if not axisValue120:
        axisAcc = [0.0, 0.0]
        axisValue120 = true
      axisAcc[axis] += float(v)
  else: discard

proc keyboardEvent(m: var WlMsg) =
  if m.obj != keyboardId:
    # (one let go of: a layout it still sent is closed)
    if m.op == 0:
      discard m.u32
      let fd = m.fd
      if fd >= 0: discard posix.close(fd)
    return
  case m.op
  of 0:                                                       # keymap
    let format = m.u32
    let fd = m.fd
    let size = int(m.u32)
    if fd >= 0:
      if format == 1 and size > 0:
        let p = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0)
        if p != MAP_FAILED:
          var text = newString(size)
          copyMem(addr text[0], p, size)
          discard munmap(p, size)
          let nul = text.find('\0')
          if nul >= 0: text.setLen(nul)
          discard xkb.fromText(text)
      discard posix.close(fd)
  of 1:                                                       # enter
    inputSerial = m.u32
    let w = winOfSurface(m.u32)
    keyboardWin = if w != nil: w.id else: -1
  of 2:                                                       # leave
    discard m.u32
    discard m.u32
    keyboardWin = -1
    repeatKey = -1
    shiftDown = false
  of 3:                                                       # key
    inputSerial = m.u32
    discard m.u32
    let key = int(m.u32)
    let state = m.u32
    if state == 1:
      keyPress(key, true, false)
      if repeatRate > 0 and xkb.repeats(uint32(key + 8)) and
         key notin [29, 42, 54, 56, 97, 100, 125, 126]:        # (not the modifiers)
        repeatKey = key
        repeatAt = wlTicks() + repeatDelay
      else:
        repeatKey = -1
    else:
      if repeatKey == key: repeatKey = -1
      keyPress(key, false, false)
  of 4:                                                       # modifiers
    discard m.u32
    let dep = m.u32
    let lat = m.u32
    let lock = m.u32
    let group = m.u32
    xkb.updateMask(dep, lat, lock, group)
    mods = {}
    if xkb.ready:
      if xkb.shift: mods.incl ShiftPressed
      if xkb.ctrl: mods.incl CtrlPressed
      if xkb.alt: mods.incl AltPressed
      if xkb.super: mods.incl GuiPressed
    else:
      if (dep and 1) != 0: mods.incl ShiftPressed
      if (dep and 4) != 0: mods.incl CtrlPressed
      if (dep and 8) != 0: mods.incl AltPressed
      if (dep and 64) != 0: mods.incl GuiPressed
      shiftDown = (dep and 1) != 0 or (lock and 2) != 0
  of 5:                                                       # repeat_info
    repeatRate = m.i32
    repeatDelay = m.i32
  else: discard

proc touchEvent(m: var WlMsg) =
  if m.obj != touchId: return
  case m.op
  of 0:                                                       # down
    let serial = m.u32
    discard m.u32
    let s = m.u32
    let id = m.i32
    let x = m.fixed
    let y = m.fixed
    let w = winOfSurface(s)
    if w == nil or touchPrimary >= 0: return
    inputSerial = serial
    buttonSerial = serial
    touchPrimary = id
    touchX = x
    touchY = y
    pointerWin = w.id
    pointerX = x
    pointerY = y
    pushEvent(input.Event(kind: MouseMoveEvent, x: w.toPx(x), y: w.toPx(y)), w.id)
    pushEvent(input.Event(kind: MouseDownEvent, button: LeftButton, clicks: 1,
                          x: w.toPx(x), y: w.toPx(y)), w.id)
    buttonsDown.incl LeftButton
  of 1:                                                       # up
    discard m.u32
    discard m.u32
    let id = m.i32
    if id != touchPrimary: return
    touchPrimary = -1
    buttonsDown.excl LeftButton
    let w = winById(pointerWin)
    if w == nil: return
    pushEvent(input.Event(kind: MouseUpEvent, button: LeftButton,
                          x: w.toPx(touchX), y: w.toPx(touchY)), w.id)
  of 2:                                                       # motion
    discard m.u32
    let id = m.i32
    let x = m.fixed
    let y = m.fixed
    if id != touchPrimary: return
    touchX = x
    touchY = y
    let w = winById(pointerWin)
    if w == nil: return
    pushEvent(input.Event(kind: MouseMoveEvent, x: w.toPx(x), y: w.toPx(y)), w.id)
  of 4:                                                       # cancel
    if touchPrimary >= 0:
      touchPrimary = -1
      buttonsDown.excl LeftButton
      let w = winById(pointerWin)
      if w != nil:
        pushEvent(input.Event(kind: MouseUpEvent, button: LeftButton,
                              x: w.toPx(touchX), y: w.toPx(touchY)), w.id)
  else: discard

proc dataDeviceEvent(m: var WlMsg) =
  case m.op
  of 0:                                                       # data_offer
    let id = m.u32
    obj(id, okDataOffer)
    offerMimes[id] = @[]
  of 1:                                                       # enter
    dndSerial = m.u32
    let s = m.u32
    dndX = m.fixed
    dndY = m.fixed
    let offer = m.u32
    let w = winOfSurface(s)
    if dndOffer != 0 and dndOffer != offer: dropOffer(dndOffer)
    dndOffer = offer
    dndWin = if w != nil: w.id else: -1
    if offer != 0:
      let files = "text/uri-list" in offerMimes.getOrDefault(offer)
      conn.send(offer, 0, wu(dndSerial), ws(if files: "text/uri-list" else: ""))   # accept
      if files and dataVersion >= 3:
        conn.send(offer, 4, wu(1), wu(1))                     # set_actions: copy
      discard conn.flush()
  of 2:                                                       # leave
    if dndOffer != 0: dropOffer(dndOffer)
    dndOffer = 0
    dndWin = -1
  of 3:                                                       # motion
    discard m.u32
    dndX = m.fixed
    dndY = m.fixed
  of 4:                                                       # drop
    if dndOffer != 0 and dndWin >= 0:
      let files = fileUris(receive(dndOffer, "text/uri-list"))
      if dataVersion >= 3: conn.send(dndOffer, 3)             # finish
      let w = winById(dndWin)
      if files.len > 0 and w != nil:
        pushEvent(input.Event(kind: FileDropEvent, files: files,
                              x: w.toPx(dndX), y: w.toPx(dndY)), w.id)
      dropOffer(dndOffer)
      dndOffer = 0
      dndWin = -1
  of 5:                                                       # selection
    let id = m.u32
    if selectionOffer != 0 and selectionOffer != id and selectionOffer != dndOffer:
      dropOffer(selectionOffer)
    selectionOffer = id
  else: discard

proc dataSourceEvent(m: var WlMsg) =
  case m.op
  of 1:                                                       # send
    discard m.str
    let fd = m.fd
    if fd >= 0 and m.obj != ownSource:
      discard posix.close(fd)                                 # (a selection that is not ours now)
    elif fd >= 0:
      let data = if clipPng.len > 0: clipPng else: clipText
      var at = 0
      while at < data.len:
        let n = posix.write(fd, unsafeAddr data[at], data.len - at)
        if n <= 0:
          if errno == EINTR: continue
          break
        at += n
      discard posix.close(fd)
  of 2:                                                       # cancelled
    if m.obj == ownSource: ownSource = 0
    conn.send(m.obj, 1)                                       # destroy
  else: discard

proc textInputEvent(m: var WlMsg) =
  case m.op
  of 0:                                                       # enter
    discard m.u32
    conn.send(textInputId, 1)                                 # enable
    conn.send(textInputId, 5, wu(0), wu(0))                   # set_content_type: normal
    if tiCaret.w > 0 or tiCaret.h > 0:
      conn.send(textInputId, 6, wi(tiCaret.x), wi(tiCaret.y), wi(tiCaret.w), wi(tiCaret.h))
    conn.send(textInputId, 7)                                 # commit
    inc tiSerial
    tiEnabled = true
    discard conn.flush()
  of 1:                                                       # leave
    discard m.u32
    conn.send(textInputId, 2)                                 # disable
    conn.send(textInputId, 7)
    inc tiSerial
    tiEnabled = false
    discard conn.flush()
  of 2:                                                       # preedit_string
    tiPreedit = m.str
    let b = m.i32
    discard m.i32
    tiPreeditCaret = if b >= 0: int(b) else: tiPreedit.len
    tiHasPreedit = true
  of 3:                                                       # commit_string
    tiCommit.add m.str
  of 5:                                                       # done
    let win = max(0, keyboardWin)
    if tiCommit.len > 0:
      # (what was composing is done with first)
      pushEvent(input.Event(kind: TextEditingEvent), win)
      pushText(tiCommit, win)
      tiCommit = ""
    if tiHasPreedit:
      var e = input.Event(kind: TextEditingEvent, composing: tiPreedit)
      e.x = clamp(tiPreeditCaret, 0, tiPreedit.len)
      pushEvent(e, win)
      tiHasPreedit = false
      tiPreedit = ""
  else: discard

proc dispatchOne(m: var WlMsg) =
  if m.obj == 1:                                              # wl_display
    case m.op
    of 0:
      let o = m.u32
      let code = m.u32
      fail("protocol error on object " & $o & " (" & $code & "): " & m.str)
    of 1:
      let id = m.u32
      objs.del id
      conn.idDeleted(id)
    else: discard
    return
  let o = objs.getOrDefault(m.obj)
  case o.kind
  of okRegistry:
    if m.op == 0:
      let name = m.u32
      let iface = m.str
      let version = m.u32
      globals.add Global(name: name, iface: iface, version: version)
      if iface == "wl_output" and compositorId != 0:
        # (a monitor plugged in)
        outputs.add Output(scale: 1, name: name)
        outputs[^1].id = bindGlobal(globals[^1], okOutput, 4)
    elif m.op == 1:
      # (a monitor unplugged)
      let name = m.u32
      for i in countdown(outputs.high, 0):
        if outputs[i].name == name:
          let id = outputs[i].id
          objs.del id
          outputs.delete(i)
          for w in wins:
            let at = w.outputs.find(id)
            if at >= 0: w.outputs.delete(at)
            if w.configured: rescale(w)
  of okCallback:
    syncDone.add m.obj
  of okWmBase:
    if m.op == 0: conn.send(wmBaseId, 3, wu(m.u32))           # ping -> pong
  of okSeat:
    if m.op == 0:
      let caps = m.u32
      # (a device gone: its object let go of; one that comes back gets a new one)
      if (caps and 1) == 0 and pointerId != 0:
        if shapeDeviceId != 0:
          conn.send(shapeDeviceId, 0)
          shapeDeviceId = 0
        if seatVersion >= 3: conn.send(pointerId, 1)         # wl_pointer.release
        pointerId = 0
        pointerWin = -1
        buttonsDown = {}
      if (caps and 2) == 0 and keyboardId != 0:
        if seatVersion >= 3: conn.send(keyboardId, 0)        # wl_keyboard.release
        keyboardId = 0
        keyboardWin = -1
        repeatKey = -1
      if (caps and 4) == 0 and touchId != 0:
        if seatVersion >= 3: conn.send(touchId, 0)           # wl_touch.release
        touchId = 0
        touchPrimary = -1
      seatCaps = caps
      if registry != 0 and compositorId != 0: bindSeatParts()
  of okOutput:
    var i = -1
    for j, op in outputs:
      if op.id == m.obj: i = j
    if i < 0: return
    case m.op
    of 1:                                                     # mode
      let flags = m.u32
      let w = m.i32
      let h = m.i32
      if (flags and 1) != 0:
        outputs[i].w = w
        outputs[i].h = h
    of 3: outputs[i].scale = max(1, int(m.i32))               # scale
    of 2:                                                     # done
      for w in wins:
        if w.configured: rescale(w)
    else: discard
  of okSurface:
    let w = winById(o.win)
    if w == nil: return
    case m.op
    of 0:                                                     # enter
      let output = m.u32
      if output notin w.outputs: w.outputs.add output
      if w.configured: rescale(w)
    of 1:                                                     # leave
      let output = m.u32
      let at = w.outputs.find(output)
      if at >= 0: w.outputs.delete(at)
      if w.configured: rescale(w)
    of 2:                                                     # preferred_buffer_scale
      w.prefScale = max(1, int(m.i32))
      if w.configured: rescale(w)
    else: discard
  of okXdgSurface:
    let w = winById(o.win)
    if w != nil and m.op == 0: handleConfigure(w, m.u32)
  of okToplevel:
    let w = winById(o.win)
    if w == nil: return
    case m.op
    of 0:                                                     # configure
      w.pendW = m.i32
      w.pendH = m.i32
      w.pendStates = m.arr
    of 1: pushEvent(input.Event(kind: WindowCloseEvent), w.id)    # close
    else: discard
  of okFrac:
    let w = winById(o.win)
    if w != nil and m.op == 0:
      w.scale120 = max(120, int(m.u32))
      if w.configured: rescale(w)
  of okDeco:
    if m.op == 0:
      let ssd = m.u32 == 2
      let w = winById(o.win)
      if w != nil: w.ssd = ssd
      if o.win == 0: systemFrameNow = ssd
  of okBuffer:
    if m.op == 0:                                             # release
      let w = winById(o.win)
      if w != nil and o.tag < w.bufs.len and w.bufs[o.tag].id == m.obj:
        w.bufs[o.tag].busy = false
      elif w != nil:
        for b in w.bufs.mitems:
          if b.id == m.obj: b.busy = false
  of okPointer: pointerEvent(m)
  of okKeyboard: keyboardEvent(m)
  of okTouch: touchEvent(m)
  of okDataDevice: dataDeviceEvent(m)
  of okDataOffer:
    if m.op == 0: offerMimes.mgetOrPut(m.obj, @[]).add m.str
  of okDataSource: dataSourceEvent(m)
  of okTextInput: textInputEvent(m)
  of okActivationToken:
    if m.op == 0:
      let token = m.str
      if wins.len > 0: conn.send(activationId, 2, ws(token), wu(wins[0].surface))
      conn.send(m.obj, 4)                                     # destroy
  else:
    # (an event with a descriptor for something unknown: let it go)
    discard

proc dispatch() =
  var m: WlMsg
  while conn != nil and conn.next(m):
    dispatchOne(m)
  if conn != nil and conn.failed: fail(conn.error)

proc keyRepeats() =
  if repeatKey < 0 or keyboardWin < 0 or repeatRate <= 0: return
  let now = wlTicks()
  var n = 0
  while now >= repeatAt and n < 10:
    keyPress(repeatKey, true, true)
    repeatAt += max(1, 1000 div repeatRate)
    inc n
  if now >= repeatAt: repeatAt = now + max(1, 1000 div repeatRate)

# ---- the window ----

proc appName(): string =
  getAppFilename().extractFilename.changeFileExt("")

proc makeWindow(w: WlWin; title: string; parent: WlWin) =
  w.back = -1
  w.front = -1
  w.surface = newObj(okSurface, w.id)
  conn.send(compositorId, 0, wu(w.surface))                   # create_surface
  if fracManagerId != 0 and viewporterId != 0:
    w.frac = newObj(okFrac, w.id)
    conn.send(fracManagerId, 1, wu(w.frac), wu(w.surface))
    w.viewport = newObj(okViewport, w.id)
    conn.send(viewporterId, 1, wu(w.viewport), wu(w.surface))
  w.xdgSurface = newObj(okXdgSurface, w.id)
  conn.send(wmBaseId, 2, wu(w.xdgSurface), wu(w.surface))     # get_xdg_surface
  w.toplevel = newObj(okToplevel, w.id)
  conn.send(w.xdgSurface, 1, wu(w.toplevel))                  # get_toplevel
  if parent != nil: conn.send(w.toplevel, 1, wu(parent.toplevel))   # set_parent
  conn.send(w.toplevel, 2, ws(title))                         # set_title
  conn.send(w.toplevel, 3, ws(appName()))                     # set_app_id
  if decoManagerId != 0:
    w.deco = newObj(okDeco, w.id)
    conn.send(decoManagerId, 1, wu(w.deco), wu(w.toplevel))
    conn.send(w.deco, 1, wu(if wantSystemFrame or parent != nil: 2 else: 1))   # set_mode
  if not resizable and parent == nil:
    conn.send(w.toplevel, 8, wi(w.lw), wi(w.lh))              # set_min_size
    conn.send(w.toplevel, 7, wi(w.lw), wi(w.lh))              # set_max_size

proc waitConfigured(w: WlWin) =
  let t0 = wlTicks()
  while not w.configured and conn != nil and not conn.failed and wlTicks() - t0 < 3000:
    discard conn.flush()
    if conn.readSome(50): dispatch()

proc wlCreateWindow(layout: var ScreenLayout; icon: pointer; iconLen: int) =
  if not ensureConn():
    quit("Cannot reach a Wayland compositor (WAYLAND_DISPLAY)")
  let w = WlWin(id: 0)
  wins.insert(w, 0)
  cur = w
  let s = outputsScale()
  w.scale120 = s * 120
  var big = (w: 1280, h: 800)
  for o in outputs:
    if o.w > 0: big = (o.w div max(1, o.scale), o.h div max(1, o.scale))
  let maximized = layout.width < 0 or layout.height < 0
  # (asked for in design pixels: the same in the compositor's units, on a
  # screen at 200% twice as many pixels)
  w.lw = if layout.width < 0 or layout.fullScreen: big.w else: max(1, layout.width)
  w.lh = if layout.height < 0 or layout.fullScreen: big.h else: max(1, layout.height)
  w.floatW = if layout.width > 0: layout.width else: big.w * 2 div 3
  w.floatH = if layout.height > 0: layout.height else: big.h * 2 div 3
  makeWindow(w, if appTitle.len > 0: appTitle else: appName(), nil)
  if layout.fullScreen: conn.send(w.toplevel, 11, wu(0))      # set_fullscreen
  elif maximized: conn.send(w.toplevel, 9)                    # set_maximized
  conn.send(w.surface, 6)                                     # commit (no buffer: asks for a configure)
  waitConfigured(w)
  if not w.configured:
    quit("The Wayland compositor did not configure the window")
  # started from a launcher: to the front
  activationToken = getEnv("XDG_ACTIVATION_TOKEN")
  delEnv("XDG_ACTIVATION_TOKEN")
  delEnv("DESKTOP_STARTUP_ID")
  if activationToken.len > 0 and activationId != 0:
    conn.send(activationId, 2, ws(activationToken), wu(w.surface))   # activate
  bindSeatParts()
  discard conn.flush()
  layout.width = w.w
  layout.height = w.h
  layout.scaleX = 1
  layout.scaleY = 1
  layout.uiScale = w.uiScaleOf
  layout.touch = (seatCaps and 4) != 0 and (seatCaps and 1) == 0

proc wlGetWindowLayout(): ScreenLayout =
  let w = if wins.len > 0: wins[0] else: nil
  if w == nil: return ScreenLayout(scaleX: 1, scaleY: 1, uiScale: 100)
  ScreenLayout(width: w.w, height: w.h, scaleX: 1, scaleY: 1, uiScale: w.uiScaleOf,
               fullScreen: w.fullscreen,
               touch: (seatCaps and 4) != 0 and (seatCaps and 1) == 0)

proc wlRefresh() =
  present(cur)

proc wlSetWindowTitle(title: string) =
  appTitle = title
  if wins.len > 0 and wins[0].toplevel != 0:
    conn.send(wins[0].toplevel, 2, ws(title))
    discard conn.flush()

# ---- drawing ----

proc target(): ptr PixBuf =
  if cur == nil or not ensureBack(cur): nil else: addr cur.pb

proc wlFillRect(r: Rect; c: Color) =
  let b = target()
  if b != nil: b[].fill(r, c)

proc wlDrawLine(x1, y1, x2, y2: int; c: Color) =
  let b = target()
  if b != nil: b[].line(x1, y1, x2, y2, c)

proc wlDrawPoint(x, y: int; c: Color) =
  let b = target()
  if b != nil: b[].point(x, y, c)

proc wlBlitRGBA(px: ptr UncheckedArray[uint32]; w, h: int; dst: Rect; f: RGBAFormat): bool =
  let b = target()
  b != nil and b[].blit(px, w, h, dst, f)

proc wlDrawRGBA(px: ptr UncheckedArray[uint32]; w, h: int; dst: Rect; f: RGBAFormat): bool =
  let b = target()
  b != nil and b[].draw(px, w, h, dst, f)

proc wlSetClipRect(r: Rect) =
  if cur != nil:
    cur.pb.setClip(r)

proc wlSaveState() = discard
proc wlRestoreState() =
  if cur != nil: cur.pb.noClip()

proc wlTextCaret(x, y, w, h: int) =
  let win = if keyboardWin >= 0: winById(keyboardWin) else: cur
  if win == nil or textInputId == 0: return
  let k = float(win.scale120) / 120.0
  let r = Rect(x: int(float(x) / k), y: int(float(y) / k),
               w: max(1, int(float(w) / k)), h: max(1, int(float(h) / k)))
  if r == tiCaret: return
  tiCaret = r
  if tiEnabled:
    conn.send(textInputId, 6, wi(r.x), wi(r.y), wi(r.w), wi(r.h))
    conn.send(textInputId, 7)
    inc tiSerial
    discard conn.flush()

# ---- the frame ----

proc wlSetSystemFrame(on: bool): bool =
  wantSystemFrame = on
  if conn == nil: discard ensureConn()
  if on and decoManagerId == 0: return false
  for w in wins:
    if w.deco != 0: conn.send(w.deco, 1, wu(if on: 2 else: 1))
  if conn != nil: discard conn.flush()
  true

proc wlDragWindow(part: WindowPart; keyboard: bool): bool =
  if keyboard or wins.len == 0 or seatId == 0 or buttonSerial == 0: return false
  if LeftButton notin buttonsDown: return false
  let w = winById(max(0, pointerWin))
  if w == nil: return false
  if part == wpCaption:
    conn.send(w.toplevel, 5, wu(seatId), wu(buttonSerial))   # move
  else:
    let edges = case part
      of wpTop: 1'u32
      of wpBottom: 2
      of wpLeft: 4
      of wpTopLeft: 5
      of wpBottomLeft: 6
      of wpRight: 8
      of wpTopRight: 9
      of wpBottomRight: 10
      else: return false
    conn.send(w.toplevel, 6, wu(seatId), wu(buttonSerial), wu(edges))   # resize
  dragPending = true
  discard conn.flush()
  true

proc wlSetMaximized(on: bool) =
  if wins.len == 0: return
  conn.send(wins[0].toplevel, if on: 9 else: 10)
  discard conn.flush()

proc wlSetFullScreen(on: bool) =
  if wins.len == 0: return
  if on: conn.send(wins[0].toplevel, 11, wu(0))       # set_fullscreen (its output)
  else: conn.send(wins[0].toplevel, 12)               # unset_fullscreen
  discard conn.flush()

proc wlMinimize(): bool =
  if wins.len == 0: return false
  conn.send(wins[0].toplevel, 13)                             # set_minimized
  discard conn.flush()
  true

proc wlSetResizable(on: bool) =
  resizable = on
  if wins.len == 0: return
  let w = wins[0]
  if on:
    conn.send(w.toplevel, 8, wi(0), wi(0))
    conn.send(w.toplevel, 7, wi(0), wi(0))
  else:
    conn.send(w.toplevel, 8, wi(w.lw), wi(w.lh))
    conn.send(w.toplevel, 7, wi(w.lw), wi(w.lh))
  conn.send(w.surface, 6)
  discard conn.flush()

# ---- more windows ----

proc wlOpenWindow(title: string; w, h: int): int =
  if conn == nil or conn.failed or wins.len == 0: return 0
  let main = wins[0]
  let x = WlWin(id: nextWinId)
  inc nextWinId
  x.scale120 = main.scale120
  x.lw = max(1, w * 120 div x.scale120)
  x.lh = max(1, h * 120 div x.scale120)
  wins.add x
  makeWindow(x, title, main)
  conn.send(x.surface, 6)
  waitConfigured(x)
  if not x.configured:
    wins.delete(wins.find(x))
    return 0
  x.id

proc destroyWin(w: WlWin) =
  for b in w.bufs.mitems: destroyBuf(b)
  w.bufs.setLen 0
  if w.deco != 0: conn.send(w.deco, 0)
  if w.toplevel != 0: conn.send(w.toplevel, 0)
  if w.xdgSurface != 0: conn.send(w.xdgSurface, 0)
  if w.frac != 0: conn.send(w.frac, 0)
  if w.viewport != 0: conn.send(w.viewport, 0)
  if w.surface != 0: conn.send(w.surface, 0)
  discard conn.flush()

proc wlCloseWindow(id: int) =
  let w = winById(id)
  if w == nil or id == 0: return
  if cur == w: cur = wins[0]
  if pointerWin == id: pointerWin = -1
  if keyboardWin == id: keyboardWin = -1
  destroyWin(w)
  wins.delete(wins.find(w))

proc wlWindowTitle(id: int; title: string) =
  let w = winById(id)
  if w != nil and w.toplevel != 0:
    conn.send(w.toplevel, 2, ws(title))
    discard conn.flush()

proc wlWindowLayout(id: int): ScreenLayout =
  let w = winById(id)
  if w == nil: return ScreenLayout(scaleX: 1, scaleY: 1, uiScale: 100)
  ScreenLayout(width: w.w, height: w.h, scaleX: 1, scaleY: 1, uiScale: w.uiScaleOf)

proc wlWindowFramed(id: int): bool =
  let w = winById(id)
  w != nil and w.ssd

proc wlTarget(id: int) =
  let w = winById(id)
  if w != nil: cur = w

# ---- events ----

proc takeEvent(e: var input.Event): bool =
  if eventQueue.len == 0: return false
  e = eventQueue[0]
  eventQueue.delete(0)
  true

var gAtspi = false

proc wlPollEvent(e: var input.Event; flags: set[InputFlag]): bool =
  if gAtspi: atspiProcess()
  if conn != nil and not conn.failed:
    discard conn.flush()
    while conn.readSome(0): discard
    dispatch()
  keyRepeats()
  takeEvent(e)

proc wlWaitEvent(e: var input.Event; timeoutMs: int; flags: set[InputFlag]): bool =
  if takeEvent(e): return true
  if wlPollEvent(e, flags): return true
  if conn == nil or conn.failed: return false
  let t0 = wlTicks()
  while true:
    var wait = if timeoutMs < 0: -1 else: max(0, timeoutMs - (wlTicks() - t0))
    if repeatKey >= 0 and keyboardWin >= 0:
      let toRepeat = max(0, repeatAt - wlTicks())
      wait = if wait < 0: toRepeat else: min(wait, toRepeat)
    var fds = @[TPollfd(fd: conn.fd, events: POLLIN)]
    if gAtspi:
      for fd in atspiFds(): fds.add TPollfd(fd: fd, events: POLLIN)
    discard poll(addr fds[0], Tnfds(fds.len), cint(wait))
    if wlPollEvent(e, flags): return true
    if conn.failed: return takeEvent(e)
    if timeoutMs >= 0 and wlTicks() - t0 >= timeoutMs: return false

proc wlShutdown() =
  if conn == nil: return
  for w in wins: destroyWin(w)
  wins.setLen 0
  for b in cursorBufs.mvalues: destroyBuf(b)
  cursorBufs.clear()
  discard conn.flush()
  conn.close()
  conn = nil

proc wlAccessStart(): bool =
  if conn == nil: return false
  atspiOrigin = proc (): tuple[x, y: int] = (0, 0)       # (Wayland says no window where it is)
  atspiWake = proc () = pushEvent(input.Event(kind: NoEvent))
  gAtspi = atspiStart()
  gAtspi

proc wlWake*() = pushEvent(input.Event(kind: NoEvent))
  ## Wakes whoever waits for the driver's events.

proc initWaylandDriver*() =
  ftTarget = target
  accessRelays = AccessRelays(start: wlAccessStart, update: atspiUpdate)
  textCaretRelay = wlTextCaret
  windowsRelays = WindowsRelays(openWindow: wlOpenWindow, closeWindow: wlCloseWindow,
                                setTitle: wlWindowTitle, layout: wlWindowLayout,
                                target: wlTarget, framed: wlWindowFramed)
  windowRelays = WindowRelays(
    createWindow: wlCreateWindow, getWindowLayout: wlGetWindowLayout,
    refresh: wlRefresh, saveState: wlSaveState, restoreState: wlRestoreState,
    setClipRect: wlSetClipRect, setCursor: wlSetCursor, pointerHeight: wlPointerHeight,
    setWindowTitle: wlSetWindowTitle)
  fontRelays = ftFontRelays()
  drawRelays = DrawRelays(fillRect: wlFillRect, drawLine: wlDrawLine, drawPoint: wlDrawPoint,
                          blitRGBA: wlBlitRGBA, drawRGBA: wlDrawRGBA)
  frameRelays = FrameRelays(
    setSystemFrame: wlSetSystemFrame, dragWindow: wlDragWindow,
    setMaximized: wlSetMaximized, setFullScreen: wlSetFullScreen,
    maximized: proc (): bool = wins.len > 0 and wins[0].maximized,
    active: proc (): bool = wins.len == 0 or wins[0].activated,
    setResizable: wlSetResizable)
  systemRelays.minimize = wlMinimize
  inputRelays = InputRelays(pollEvent: wlPollEvent, waitEvent: wlWaitEvent,
                            getTicks: wlTicks, sleep: wlDelay, shutdown: wlShutdown)
  clipboardRelays = ClipboardRelays(getText: wlGetClipboardText, putText: wlPutClipboardText,
                                    getImage: wlGetClipboardImage, putImage: wlPutClipboardImage)

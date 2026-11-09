## The screen itself, with no windowing system: a kiosk, a till, a machine's
## panel, a board with a display (Linux). The app has the whole screen.
##
## - The picture: DRM/KMS (`/dev/dri/card*`): the connected screen's own
##   mode, a buffer of the card's ("dumb") the screen shows; else the old
##   framebuffer device (`/dev/fb0`). The app draws into memory (`PixBuf`)
##   and only what changed is copied to the screen, in the screen's pixel
##   format (32 bits, 24, or 16: RGB565).
## - The mouse pointer: drawn by the driver over the picture (the classic
##   arrows, `cursorart`), hidden while the screen is touched.
## - Input: the kernel's input devices (`/dev/input/event*`, evdev), taken
##   for the app alone while it runs (another program does not get them)
##   and looked for again every two seconds (a keyboard plugged in). The
##   keyboard with the system's layout (libxkbcommon, loaded at run time;
##   `/etc/default/keyboard` or XKB_DEFAULT_LAYOUT; a US keyboard without
##   it), dead keys and compose; mice and touch pads, wheels; touch screens
##   (the first finger); pens with their pressure.
## - Text in the system's fonts through fontconfig and FreeType (`ftfonts`)
##   when they are there, else the kit's own.
## - The text console: kept from drawing over the app while it runs; when
##   the program started on a console (a VT), Ctrl+Alt+F1..F12 go to the
##   other consoles and back (the screen and the keys given up and taken
##   again). Ctrl+Alt+Backspace asks the app to close.
##
## The user needs to be allowed the devices: the `video` and `input`
## groups (or root). `RETRO_DRIVER=kms` (or `fb`) takes this driver; a
## Linux build takes it by itself when the program starts on a text
## console with no X display and no Wayland session (see `backend`);
## `-d:kiosk` builds with it alone.
##
## More: `RETRO_KMS_CARD=/dev/dri/card1`, `RETRO_KMS_MODE=1280x720`,
## `RETRO_FBDEV=/dev/fb1`, `RETRO_FB_ROTATE` is not done (the screen as it
## is), `RETRO_FB_GRAB=0` (the input devices not taken for the app alone).
## For tests: `RETRO_FB_FILE=PATH:WxH` (a file as the screen, 32 bits a
## pixel) and `RETRO_FB_INPUT=PATH,...` (files or pipes of input events, as
## the kernel writes them).

import std/[posix, os, strutils, math, exitprocs]
import ../[coords, input, screen]
import pixbuf, ftfonts, xkbload, keysyms, cursorart

# ---- the kernel's interfaces ----------------------------------------------------------

proc c_ioctl(fd: cint; req: culong): cint {.importc: "ioctl", header: "<sys/ioctl.h>", varargs.}

func iocode(dir, typ, nr, size: int): culong =
  culong((dir shl 30) or (size shl 16) or (typ shl 8) or nr)
func ioc(typ: char; nr: int): culong = iocode(0, ord(typ), nr, 0)
func iow(typ: char; nr, size: int): culong = iocode(1, ord(typ), nr, size)
func ior(typ: char; nr, size: int): culong = iocode(2, ord(typ), nr, size)
func iowr(typ: char; nr, size: int): culong = iocode(3, ord(typ), nr, size)

type
  DrmGetCap = object
    capability, value: uint64
  DrmCardRes = object
    fbIdPtr, crtcIdPtr, connectorIdPtr, encoderIdPtr: uint64
    countFbs, countCrtcs, countConnectors, countEncoders: uint32
    minWidth, maxWidth, minHeight, maxHeight: uint32
  DrmModeInfo = object
    clock: uint32
    hdisplay, hsyncStart, hsyncEnd, htotal, hskew: uint16
    vdisplay, vsyncStart, vsyncEnd, vtotal, vscan: uint16
    vrefresh, flags, typ: uint32
    name: array[32, char]
  DrmCrtc = object
    setConnectorsPtr: uint64
    countConnectors, crtcId, fbId, x, y, gammaSize, modeValid: uint32
    mode: DrmModeInfo
  DrmEncoder = object
    encoderId, encoderType, crtcId, possibleCrtcs, possibleClones: uint32
  DrmConnector = object
    encodersPtr, modesPtr, propsPtr, propValuesPtr: uint64
    countModes, countProps, countEncoders: uint32
    encoderId, connectorId, connectorType, connectorTypeId: uint32
    connection, mmWidth, mmHeight, subpixel, pad: uint32
  DrmFbCmd = object
    fbId, width, height, pitch, bpp, depth, handle: uint32
  DrmFbDirty = object
    fbId, flags, color, numClips: uint32
    clipsPtr: uint64
  DrmClipRect = object
    x1, y1, x2, y2: uint16
  DrmCreateDumb = object
    height, width, bpp, flags, handle, pitch: uint32
    size: uint64
  DrmMapDumb = object
    handle, pad: uint32
    offset: uint64
  DrmDestroyDumb = object
    handle: uint32

  FbBitfield = object
    offset, length, msbRight: uint32
  FbVarInfo = object
    xres, yres, xresVirtual, yresVirtual, xoffset, yoffset, bitsPerPixel, grayscale: uint32
    red, green, blue, transp: FbBitfield
    nonstd, activate, height, width, accelFlags, pixclock: uint32
    leftMargin, rightMargin, upperMargin, lowerMargin, hsyncLen, vsyncLen: uint32
    sync, vmode, rotate, colorspace: uint32
    reserved: array[4, uint32]
  FbFixInfo = object
    id: array[16, char]
    smemStart: culong
    smemLen, typ, typAux, visual: uint32
    xpanstep, ypanstep, ywrapstep: uint16
    lineLength: uint32
    mmioStart: culong
    mmioLen, accel: uint32
    capabilities: uint16
    reserved: array[2, uint16]

  InputEvent = object
    sec, usec: culong              ## (the kernel's struct input_event)
    typ, code: uint16
    value: int32
  AbsInfo = object
    value, minimum, maximum, fuzz, flat, resolution: int32

  VtMode = object
    mode, waitv: char
    relsig, acqsig, frsig: int16

const
  DRM_IOCTL_GET_CAP = iowr('d', 0x0c, sizeof(DrmGetCap))
  DRM_IOCTL_SET_MASTER = ioc('d', 0x1e)
  DRM_IOCTL_DROP_MASTER = ioc('d', 0x1f)
  DRM_IOCTL_MODE_GETRESOURCES = iowr('d', 0xA0, sizeof(DrmCardRes))
  DRM_IOCTL_MODE_GETCRTC = iowr('d', 0xA1, sizeof(DrmCrtc))
  DRM_IOCTL_MODE_SETCRTC = iowr('d', 0xA2, sizeof(DrmCrtc))
  DRM_IOCTL_MODE_GETENCODER = iowr('d', 0xA6, sizeof(DrmEncoder))
  DRM_IOCTL_MODE_GETCONNECTOR = iowr('d', 0xA7, sizeof(DrmConnector))
  DRM_IOCTL_MODE_ADDFB = iowr('d', 0xAE, sizeof(DrmFbCmd))
  DRM_IOCTL_MODE_RMFB = iowr('d', 0xAF, sizeof(cuint))
  DRM_IOCTL_MODE_DIRTYFB = iowr('d', 0xB1, sizeof(DrmFbDirty))
  DRM_IOCTL_MODE_CREATE_DUMB = iowr('d', 0xB2, sizeof(DrmCreateDumb))
  DRM_IOCTL_MODE_MAP_DUMB = iowr('d', 0xB3, sizeof(DrmMapDumb))
  DRM_IOCTL_MODE_DESTROY_DUMB = iowr('d', 0xB4, sizeof(DrmDestroyDumb))
  DRM_CAP_DUMB_BUFFER = 1'u64
  DRM_MODE_TYPE_PREFERRED = 1'u32 shl 3
  DRM_MODE_CONNECTED = 1'u32

  FBIOGET_VSCREENINFO = 0x4600.culong
  FBIOGET_FSCREENINFO = 0x4602.culong

  EV_SYN = 0'u16
  EV_KEY = 1'u16
  EV_REL = 2'u16
  EV_ABS = 3'u16
  SYN_REPORT = 0'u16
  SYN_DROPPED = 3'u16
  REL_X = 0'u16
  REL_Y = 1'u16
  REL_HWHEEL = 6'u16
  REL_WHEEL = 8'u16
  ABS_X = 0'u16
  ABS_Y = 1'u16
  ABS_PRESSURE = 0x18'u16
  ABS_MT_SLOT = 0x2f'u16
  ABS_MT_POSITION_X = 0x35'u16
  ABS_MT_POSITION_Y = 0x36'u16
  ABS_MT_TRACKING_ID = 0x39'u16
  BTN_LEFT = 0x110
  BTN_RIGHT = 0x111
  BTN_MIDDLE = 0x112
  BTN_SIDE = 0x113
  BTN_EXTRA = 0x114
  BTN_TOOL_PEN = 0x140
  BTN_TOOL_RUBBER = 0x141
  BTN_TOUCH = 0x14a
  BTN_TOOL_FINGER = 0x145
  INPUT_PROP_DIRECT = 1

  KDSETMODE = 0x4B3A.culong
  KD_TEXT = 0.cint
  KD_GRAPHICS = 1.cint
  VT_SETMODE = 0x5602.culong
  VT_RELDISP = 0x5605.culong
  VT_ACTIVATE = 0x5606.culong
  VT_AUTO = '\0'
  VT_PROCESS = '\1'
  VT_ACKACQ = 2

func eviocgbit(ev, len: int): culong = ior('E', 0x20 + ev, len)
func eviocgabs(axis: int): culong = ior('E', 0x40 + axis, sizeof(AbsInfo))
func eviocgprop(len: int): culong = ior('E', 0x09, len)
func eviocgname(len: int): culong = ior('E', 0x06, len)
let EVIOCGRAB = iow('E', 0x90, sizeof(cint))

# ---- the screen ------------------------------------------------------------------------

type
  ScreenKind = enum skNone, skKms, skFbdev, skFile
  Device = object
    fd: cint
    path: string
    keys, rel, abs, direct, pipe: bool
    absX, absY, absP: AbsInfo
    mtX, mtY: AbsInfo
    hasMt: bool
    slot, touchSlot: int
    # (this report so far)
    dx, dy, wheel, hwheel: int
    ax, ay, pressure: int
    moved, absMoved: bool
    touching, wasTouching, pen, penWas: bool
    trackingIds: array[10, int]

var
  kind = skNone
  scrW, scrH, pitchBytes, bpp = 0
  redOff = 16
  greenOff = 8
  blueOff = 0
  redLen, greenLen, blueLen = 8
  scanout: ptr UncheckedArray[uint8]
  scanoutLen = 0
  shadow: seq[uint32]                ## the app's picture (the screen is copied from it)
  pb: PixBuf
  mmW, mmH = 0
  uiPercent = 100
  # DRM
  drmFd: cint = -1
  crtcId, connectorId, fbId, dumbHandle = 0'u32
  mode: DrmModeInfo
  savedCrtc: DrmCrtc
  haveSaved = false
  dirtyOk = true
  # fbdev, the test file
  fbFd: cint = -1
  # input
  devices: seq[Device]
  lastScan = 0
  grab = true
  queue: seq[input.Event]
  xkb: XkbKeyboard
  shiftDown, ctrlDown, altDown, superDown = false
  ptrX, ptrY = 0.0
  buttons: set[MouseButton]
  lastClick: tuple[t, x, y, n: int; b: MouseButton]
  touchOnly = false
  # the pointer drawn
  cursorKind = curDefault
  cursorShown = false
  cursorAt: Rect                     ## where it is drawn on the screen now
  cursorPx: seq[uint32]              ## its pixels (0: see-through)
  cursorW, cursorH, cursorHx, cursorHy, cursorK = 0
  # the console
  ttyFd: cint = -1
  vtSwitching = false
  away = false                       ## another console is shown
  releaseAsked, acquireAsked = false
  clipboardText: string
  started = false
  rowBuf: seq[uint32]               ## (a row with the pointer drawn over it)

proc ticks(): int =
  var ts: Timespec
  discard clock_gettime(CLOCK_MONOTONIC, ts)
  int(ts.tv_sec) * 1000 + int(ts.tv_nsec) div 1_000_000

proc say(s: string) = stderr.writeLine "screen: ", s

proc ptrOf[T](x: var T): uint64 = cast[uint64](cast[uint](addr x))

# ---- DRM/KMS ---------------------------------------------------------------------------

proc drmIo(req: culong; arg: pointer): bool =
  while true:
    if c_ioctl(drmFd, req, arg) == 0: return true
    if errno != EINTR and errno != EAGAIN: return false

proc wantedMode(): (int, int) =
  let s = getEnv("RETRO_KMS_MODE").toLowerAscii
  let x = s.find('x')
  if x > 0:
    try: return (parseInt(s[0 ..< x]), parseInt(s[x + 1 .. ^1]))
    except ValueError: discard
  (0, 0)

proc openKms(path: string): bool =
  drmFd = posix.open(cstring(path), O_RDWR or O_CLOEXEC)
  if drmFd < 0: return false
  block found:
    var cap = DrmGetCap(capability: DRM_CAP_DUMB_BUFFER)
    if not drmIo(DRM_IOCTL_GET_CAP, addr cap) or cap.value == 0: break found
    var res: DrmCardRes
    if not drmIo(DRM_IOCTL_MODE_GETRESOURCES, addr res): break found
    if res.countConnectors == 0 or res.countCrtcs == 0: break found
    var crtcs = newSeq[uint32](res.countCrtcs)
    var conns = newSeq[uint32](res.countConnectors)
    var encs = newSeq[uint32](max(1'u32, res.countEncoders))
    var res2 = DrmCardRes(countCrtcs: res.countCrtcs, countConnectors: res.countConnectors,
                          countEncoders: res.countEncoders)
    res2.crtcIdPtr = ptrOf(crtcs[0])
    res2.connectorIdPtr = ptrOf(conns[0])
    res2.encoderIdPtr = ptrOf(encs[0])
    if not drmIo(DRM_IOCTL_MODE_GETRESOURCES, addr res2): break found
    let (wantW, wantH) = wantedMode()
    for cid in conns[0 ..< min(conns.len, int(res2.countConnectors))]:
      var c = DrmConnector(connectorId: cid)
      if not drmIo(DRM_IOCTL_MODE_GETCONNECTOR, addr c): continue
      if c.connection != DRM_MODE_CONNECTED or c.countModes == 0: continue
      var modes = newSeq[DrmModeInfo](c.countModes)
      var cencs = newSeq[uint32](max(1'u32, c.countEncoders))
      var c2 = DrmConnector(connectorId: cid, countModes: c.countModes,
                            countEncoders: c.countEncoders)
      c2.modesPtr = ptrOf(modes[0])
      c2.encodersPtr = ptrOf(cencs[0])
      if not drmIo(DRM_IOCTL_MODE_GETCONNECTOR, addr c2): continue
      if c2.countModes == 0: continue
      modes.setLen(min(modes.len, int(c2.countModes)))
      # the mode: the one asked for, else the screen's own (preferred), else the first
      var pick = 0
      for i, m in modes:
        if (m.typ and DRM_MODE_TYPE_PREFERRED) != 0:
          pick = i
          break
      if wantW > 0:
        for i, m in modes:
          if int(m.hdisplay) == wantW and int(m.vdisplay) == wantH:
            pick = i
            break
      # the CRTC: the encoder's now, else one it can drive
      var crtc = 0'u32
      if c2.encoderId != 0:
        var e = DrmEncoder(encoderId: c2.encoderId)
        if drmIo(DRM_IOCTL_MODE_GETENCODER, addr e): crtc = e.crtcId
      if crtc == 0:
        for k in 0 ..< min(cencs.len, int(c2.countEncoders)):
          var e = DrmEncoder(encoderId: cencs[k])
          if not drmIo(DRM_IOCTL_MODE_GETENCODER, addr e): continue
          for j in 0 ..< crtcs.len:
            if (e.possibleCrtcs and (1'u32 shl j)) != 0:
              crtc = crtcs[j]
              break
          if crtc != 0: break
      if crtc == 0: continue
      connectorId = cid
      crtcId = crtc
      mode = modes[pick]
      mmW = int(c2.mmWidth)
      mmH = int(c2.mmHeight)
      break
    if crtcId == 0: break found
    scrW = int(mode.hdisplay)
    scrH = int(mode.vdisplay)
    var cd = DrmCreateDumb(width: uint32(scrW), height: uint32(scrH), bpp: 32)
    if not drmIo(DRM_IOCTL_MODE_CREATE_DUMB, addr cd): break found
    dumbHandle = cd.handle
    pitchBytes = int(cd.pitch)
    var fb = DrmFbCmd(width: uint32(scrW), height: uint32(scrH), pitch: cd.pitch, bpp: 32,
                      depth: 24, handle: cd.handle)
    if not drmIo(DRM_IOCTL_MODE_ADDFB, addr fb): break found
    fbId = fb.fbId
    var md = DrmMapDumb(handle: cd.handle)
    if not drmIo(DRM_IOCTL_MODE_MAP_DUMB, addr md): break found
    scanoutLen = int(cd.size)
    let p = mmap(nil, scanoutLen, PROT_READ or PROT_WRITE, MAP_SHARED, drmFd, Off(md.offset))
    if p == MAP_FAILED: break found
    scanout = cast[ptr UncheckedArray[uint8]](p)
    zeroMem(scanout, scanoutLen)
    savedCrtc = DrmCrtc(crtcId: crtcId)
    haveSaved = drmIo(DRM_IOCTL_MODE_GETCRTC, addr savedCrtc)
    var cid = connectorId
    var sc = DrmCrtc(crtcId: crtcId, fbId: fbId, countConnectors: 1, modeValid: 1, mode: mode)
    sc.setConnectorsPtr = ptrOf(cid)
    if not drmIo(DRM_IOCTL_MODE_SETCRTC, addr sc):
      say "the screen is another program's (" & $strerror(errno) & "): a desktop runs there?"
      break found
    bpp = 32
    kind = skKms
    return true
  # (not this card: what was made undone)
  if scanout != nil: discard munmap(scanout, scanoutLen)
  scanout = nil
  if fbId != 0: discard drmIo(DRM_IOCTL_MODE_RMFB, addr fbId)
  if dumbHandle != 0:
    var d = DrmDestroyDumb(handle: dumbHandle)
    discard drmIo(DRM_IOCTL_MODE_DESTROY_DUMB, addr d)
  fbId = 0
  dumbHandle = 0
  crtcId = 0
  discard posix.close(drmFd)
  drmFd = -1
  false

proc kmsTakeBack(): bool =
  ## (back from another console: the screen ours again)
  discard drmIo(DRM_IOCTL_SET_MASTER, nil)
  var cid = connectorId
  var sc = DrmCrtc(crtcId: crtcId, fbId: fbId, countConnectors: 1, modeValid: 1, mode: mode)
  sc.setConnectorsPtr = ptrOf(cid)
  drmIo(DRM_IOCTL_MODE_SETCRTC, addr sc)

proc closeKms() =
  if drmFd < 0: return
  if haveSaved and savedCrtc.fbId != 0:
    var cid = connectorId
    savedCrtc.setConnectorsPtr = ptrOf(cid)
    savedCrtc.countConnectors = 1
    discard drmIo(DRM_IOCTL_MODE_SETCRTC, addr savedCrtc)
  if scanout != nil: discard munmap(scanout, scanoutLen)
  scanout = nil
  if fbId != 0: discard drmIo(DRM_IOCTL_MODE_RMFB, addr fbId)
  if dumbHandle != 0:
    var d = DrmDestroyDumb(handle: dumbHandle)
    discard drmIo(DRM_IOCTL_MODE_DESTROY_DUMB, addr d)
  discard posix.close(drmFd)
  drmFd = -1

# ---- the framebuffer device, and a file as the screen (tests) ----------------------

proc openFbdev(path: string): bool =
  fbFd = posix.open(cstring(path), O_RDWR or O_CLOEXEC)
  if fbFd < 0: return false
  var v: FbVarInfo
  var f: FbFixInfo
  if c_ioctl(fbFd, FBIOGET_VSCREENINFO, addr v) != 0 or
     c_ioctl(fbFd, FBIOGET_FSCREENINFO, addr f) != 0 or
     v.bitsPerPixel notin [16'u32, 24, 32]:
    discard posix.close(fbFd)
    fbFd = -1
    return false
  scrW = int(v.xres)
  scrH = int(v.yres)
  bpp = int(v.bitsPerPixel)
  pitchBytes = int(f.lineLength)
  redOff = int(v.red.offset); redLen = int(v.red.length)
  greenOff = int(v.green.offset); greenLen = int(v.green.length)
  blueOff = int(v.blue.offset); blueLen = int(v.blue.length)
  if int(v.height) > 0 and int(v.width) > 0 and int(v.height) < 10000:
    mmW = int(v.width)
    mmH = int(v.height)
  scanoutLen = int(f.smemLen)
  if scanoutLen <= 0: scanoutLen = pitchBytes * int(max(v.yresVirtual, v.yres))
  let p = mmap(nil, scanoutLen, PROT_READ or PROT_WRITE, MAP_SHARED, fbFd, 0)
  if p == MAP_FAILED:
    discard posix.close(fbFd)
    fbFd = -1
    return false
  # (the part shown: where the panning has it)
  let start = int(v.yoffset) * pitchBytes + int(v.xoffset) * bpp div 8
  scanout = cast[ptr UncheckedArray[uint8]](cast[uint](p) + uint(start))
  scanoutLen -= start
  kind = skFbdev
  true

proc openFile(spec: string): bool =
  ## RETRO_FB_FILE=PATH:WxH[:BITS] -- a file the size of the screen, 32 bits a
  ## pixel (XRGB), or 24 (BGR), or 16 (RGB565).
  var parts = spec.split(':')
  var bits = 32
  if parts.len >= 3 and parts[^1] in ["16", "24", "32"]:
    bits = parseInt(parts[^1])
    parts.setLen(parts.len - 1)
  if parts.len < 2: return false
  let dims = parts[^1].toLowerAscii.split('x')
  if dims.len != 2: return false
  try:
    scrW = parseInt(dims[0])
    scrH = parseInt(dims[1])
  except ValueError: return false
  if scrW <= 0 or scrH <= 0 or scrW > 16384 or scrH > 16384: return false
  let path = parts[0 ..< ^1].join(":")
  fbFd = posix.open(cstring(path), O_RDWR or O_CREAT or O_CLOEXEC, 0o644)
  if fbFd < 0: return false
  bpp = bits
  pitchBytes = scrW * bits div 8
  scanoutLen = pitchBytes * scrH
  if ftruncate(fbFd, Off(scanoutLen)) != 0: return false
  let p = mmap(nil, scanoutLen, PROT_READ or PROT_WRITE, MAP_SHARED, fbFd, 0)
  if p == MAP_FAILED: return false
  scanout = cast[ptr UncheckedArray[uint8]](p)
  if bits == 16:
    redOff = 11; redLen = 5
    greenOff = 5; greenLen = 6
    blueOff = 0; blueLen = 5
  mmW = scrW * 254 div 960        # (96 dots an inch)
  mmH = scrH * 254 div 960
  kind = skFile
  true

proc closeFb() =
  if scanout != nil and kind in {skFbdev, skFile}:
    discard munmap(scanout, scanoutLen)
  scanout = nil
  if fbFd >= 0: discard posix.close(fbFd)
  fbFd = -1

# ---- copying to the screen -----------------------------------------------------------

proc toScreen(c: uint32): uint32 {.inline.} =
  ## A pixel of ours (XRGB) in the screen's format.
  let r = (c shr 16) and 255
  let g = (c shr 8) and 255
  let b = c and 255
  ((r shr (8 - redLen)) shl redOff) or ((g shr (8 - greenLen)) shl greenOff) or
    ((b shr (8 - blueLen)) shl blueOff)

proc copyRow(y, x0, x1: int; src: ptr UncheckedArray[uint32]) =
  ## Pixels x0 ..< x1 of row `y` to the screen.
  if x1 <= x0: return
  let rowAt = y * pitchBytes
  case bpp
  of 32:
    if redOff == 16 and greenOff == 8 and blueOff == 0:
      copyMem(addr scanout[rowAt + x0 * 4], addr src[x0], (x1 - x0) * 4)
    else:
      let d = cast[ptr UncheckedArray[uint32]](addr scanout[rowAt])
      for x in x0 ..< x1: d[x] = toScreen(src[x])
  of 24:
    for x in x0 ..< x1:
      let v = toScreen(src[x])
      let at = rowAt + x * 3
      scanout[at] = uint8(v and 255)
      scanout[at + 1] = uint8((v shr 8) and 255)
      scanout[at + 2] = uint8((v shr 16) and 255)
  of 16:
    let d = cast[ptr UncheckedArray[uint16]](addr scanout[rowAt])
    for x in x0 ..< x1: d[x] = uint16(toScreen(src[x]))
  else: discard

proc clipToScreen(r: Rect): Rect =
  let x0 = max(0, r.x)
  let y0 = max(0, r.y)
  let x1 = min(scrW, r.x + r.w)
  let y1 = min(scrH, r.y + r.h)
  if x1 <= x0 or y1 <= y0: Rect() else: Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)

proc copyOut(r: Rect) =
  ## The app's picture in `r` to the screen (the pointer over it).
  let r = clipToScreen(r)
  if r.w <= 0 or scanout == nil or away: return
  if rowBuf.len != scrW: rowBuf = newSeq[uint32](scrW)
  template row: untyped = rowBuf
  let hasCursor = cursorShown and cursorAt.w > 0
  for y in r.y ..< r.y + r.h:
    let src = cast[ptr UncheckedArray[uint32]](addr shadow[y * scrW])
    if hasCursor and y >= cursorAt.y and y < cursorAt.y + cursorAt.h and
       r.x < cursorAt.x + cursorAt.w and cursorAt.x < r.x + r.w:
      # (the pointer's pixels over the picture in this row)
      copyMem(addr row[r.x], addr src[r.x], r.w * 4)
      let cy = y - cursorAt.y
      for x in max(r.x, cursorAt.x) ..< min(r.x + r.w, cursorAt.x + cursorAt.w):
        let c = cursorPx[cy * cursorW + (x - cursorAt.x)]
        if c != 0: row[x] = c
      copyRow(y, r.x, r.x + r.w, cast[ptr UncheckedArray[uint32]](addr row[0]))
    else:
      copyRow(y, r.x, r.x + r.w, src)

proc tellDirty(r: Rect) =
  ## (KMS: some cards show what changed only when told: virtual ones, USB)
  if kind != skKms or not dirtyOk or r.w <= 0: return
  var clip = DrmClipRect(x1: uint16(r.x), y1: uint16(r.y), x2: uint16(r.x + r.w),
                         y2: uint16(r.y + r.h))
  var d = DrmFbDirty(fbId: fbId, numClips: 1)
  d.clipsPtr = ptrOf(clip)
  if c_ioctl(drmFd, DRM_IOCTL_MODE_DIRTYFB, addr d) != 0 and errno in [ENOSYS, EINVAL, ENOTTY]:
    dirtyOk = false

# ---- the pointer, drawn -----------------------------------------------------------

proc makeCursor() =
  let art = classicCursorArt(cursorKind)
  let k = max(1, (uiPercent + 50) div 100)
  var aw = 0
  for r in art.rows: aw = max(aw, r.len)
  cursorW = aw * k
  cursorH = art.rows.len * k
  cursorHx = art.hx * k
  cursorHy = art.hy * k
  cursorK = k
  cursorPx = newSeq[uint32](cursorW * cursorH)
  for y in 0 ..< cursorH:
    let row = art.rows[y div k]
    for x in 0 ..< cursorW:
      let col = x div k
      let ch = if col < row.len: row[col] else: ' '
      cursorPx[y * cursorW + x] = case ch
        of 'X': 0xFF000001'u32          # (black, not see-through)
        of '.': 0xFFFFFFFF'u32
        else: 0'u32

proc placeCursor() =
  ## The pointer drawn where it is now (what it covered before put back).
  let old = cursorAt
  let shown = cursorShown and not touchOnly
  cursorAt = if shown: clipToScreen(Rect(x: int(ptrX) - cursorHx, y: int(ptrY) - cursorHy,
                                         w: cursorW, h: cursorH))
             else: Rect()
  if old.w > 0: copyOut(old)
  if cursorAt.w > 0: copyOut(cursorAt)
  tellDirty(union(old, cursorAt))

proc fbSetCursor(c: CursorKind) =
  if c == cursorKind and cursorPx.len > 0: return
  cursorKind = c
  makeCursor()
  placeCursor()

proc fbPointerHeight(): int = cursorH

# ---- the console ------------------------------------------------------------------------

proc onRelease(sig: cint) {.noconv.} = releaseAsked = true
proc onAcquire(sig: cint) {.noconv.} = acquireAsked = true

proc openConsole() =
  ## The VT the program started on: the console kept from drawing, and its
  ## switching to the others done with us.
  var name = ""
  for fd in [0.cint, 1, 2]:
    let n = ttyname(fd)
    if n != nil:
      name = $n
      break
  if not (name.startsWith("/dev/tty") and name.len > 8 and name[8] in '0' .. '9'):
    return
  ttyFd = posix.open(cstring(name), O_RDWR or O_CLOEXEC or O_NOCTTY)
  if ttyFd < 0: return
  discard c_ioctl(ttyFd, KDSETMODE, KD_GRAPHICS)
  if kind == skKms:
    var m = VtMode(mode: VT_PROCESS, relsig: int16(SIGUSR1), acqsig: int16(SIGUSR2))
    if c_ioctl(ttyFd, VT_SETMODE, addr m) == 0:
      vtSwitching = true
      signal(SIGUSR1, onRelease)
      signal(SIGUSR2, onAcquire)

proc closeConsole() =
  if ttyFd < 0: return
  if vtSwitching:
    var m = VtMode(mode: VT_AUTO)
    discard c_ioctl(ttyFd, VT_SETMODE, addr m)
  discard c_ioctl(ttyFd, KDSETMODE, KD_TEXT)
  discard posix.close(ttyFd)
  ttyFd = -1

proc setGrab(on: bool) =
  for d in devices:
    if not d.pipe and grab: discard c_ioctl(d.fd, EVIOCGRAB, cint(ord(on)))

proc consoleSwitches() =
  ## Another console asked for, or ours given back.
  if releaseAsked:
    releaseAsked = false
    away = true
    setGrab(false)
    discard drmIo(DRM_IOCTL_DROP_MASTER, nil)
    discard c_ioctl(ttyFd, VT_RELDISP, 1.cint)
    queue.add input.Event(kind: AppPauseEvent)
    queue.add input.Event(kind: WindowFocusLostEvent)
  if acquireAsked:
    acquireAsked = false
    discard c_ioctl(ttyFd, VT_RELDISP, cint(VT_ACKACQ))
    away = false
    discard kmsTakeBack()
    setGrab(true)
    copyOut(Rect(x: 0, y: 0, w: scrW, h: scrH))
    queue.add input.Event(kind: AppResumeEvent)
    queue.add input.Event(kind: WindowFocusGainedEvent)

proc toConsole(n: int) =
  if vtSwitching and ttyFd >= 0: discard c_ioctl(ttyFd, VT_ACTIVATE, cint(n))

# ---- input devices ------------------------------------------------------------------

proc bitSet(bits: openArray[uint8]; n: int): bool =
  n div 8 < bits.len and (bits[n div 8] and (1'u8 shl (n mod 8))) != 0

proc defaultAxis(size: int): AbsInfo = AbsInfo(minimum: 0, maximum: int32(max(1, size - 1)))

proc openDevice(path: string; pipe = false): bool =
  for d in devices:
    if d.path == path: return false
  let fd = posix.open(cstring(path), (if pipe: O_RDWR else: O_RDONLY) or O_NONBLOCK or O_CLOEXEC)
  if fd < 0: return false
  var d = Device(fd: fd, path: path, pipe: pipe, slot: 0, touchSlot: -1)
  for t in d.trackingIds.mitems: t = -1
  var evBits: array[4, uint8]
  if pipe or c_ioctl(fd, eviocgbit(0, evBits.len), addr evBits[0]) < 0:
    # (not a device of the kernel's: a test's pipe; it may say anything)
    d.keys = true
    d.rel = true
    d.abs = true
    d.direct = true
    d.absX = defaultAxis(scrW)
    d.absY = defaultAxis(scrH)
    d.absP = AbsInfo(minimum: 0, maximum: 255)
  else:
    var keyBits: array[96, uint8]
    var relBits: array[4, uint8]
    var absBits: array[8, uint8]
    var props: array[4, uint8]
    if bitSet(evBits, int(EV_KEY)): discard c_ioctl(fd, eviocgbit(int(EV_KEY), keyBits.len), addr keyBits[0])
    if bitSet(evBits, int(EV_REL)): discard c_ioctl(fd, eviocgbit(int(EV_REL), relBits.len), addr relBits[0])
    if bitSet(evBits, int(EV_ABS)): discard c_ioctl(fd, eviocgbit(int(EV_ABS), absBits.len), addr absBits[0])
    discard c_ioctl(fd, eviocgprop(props.len), addr props[0])
    d.keys = bitSet(keyBits, 30) and bitSet(keyBits, 28)        # (A and Enter: a keyboard)
    d.rel = bitSet(relBits, int(REL_X)) and bitSet(relBits, int(REL_Y))
    d.abs = bitSet(absBits, int(ABS_X)) and bitSet(absBits, int(ABS_Y))
    d.hasMt = bitSet(absBits, int(ABS_MT_POSITION_X))
    d.direct = bitSet(props, INPUT_PROP_DIRECT)
    if d.abs:
      discard c_ioctl(fd, eviocgabs(int(ABS_X)), addr d.absX)
      discard c_ioctl(fd, eviocgabs(int(ABS_Y)), addr d.absY)
      if bitSet(absBits, int(ABS_PRESSURE)): discard c_ioctl(fd, eviocgabs(int(ABS_PRESSURE)), addr d.absP)
    if d.hasMt:
      discard c_ioctl(fd, eviocgabs(int(ABS_MT_POSITION_X)), addr d.mtX)
      discard c_ioctl(fd, eviocgabs(int(ABS_MT_POSITION_Y)), addr d.mtY)
    let buttons = bitSet(keyBits, BTN_LEFT) or bitSet(keyBits, BTN_TOUCH)
    if not (d.keys or d.rel or d.abs and buttons):
      discard posix.close(fd)                 # (a power button, a lid, a sensor)
      return false
    if grab and not pipe: discard c_ioctl(fd, EVIOCGRAB, 1.cint)
  devices.add d
  true

proc scanDevices() =
  lastScan = ticks()
  let given = getEnv("RETRO_FB_INPUT")
  if given.len > 0:
    for p in given.split(','):
      if p.len > 0: discard openDevice(p, pipe = true)
    return
  for f in walkDir("/dev/input"):
    if f.kind in {pcFile, pcLinkToFile} and f.path.extractFilename.startsWith("event"):
      discard openDevice(f.path)
  # a screen touched, and no mouse: no pointer drawn
  var mouse, touch = false
  for d in devices:
    if d.rel or d.abs and not d.direct: mouse = true
    if d.abs and d.direct: touch = true
  touchOnly = touch and not mouse

proc closeDevice(i: int) =
  if grab and not devices[i].pipe: discard c_ioctl(devices[i].fd, EVIOCGRAB, 0.cint)
  discard posix.close(devices[i].fd)
  devices.delete(i)

# ---- events ----------------------------------------------------------------------------

proc modsNow(): set[Modifier] =
  if xkb.ready:
    if xkb.shift: result.incl ShiftPressed
    if xkb.ctrl: result.incl CtrlPressed
    if xkb.alt: result.incl AltPressed
    if xkb.super: result.incl GuiPressed
  else:
    if shiftDown: result.incl ShiftPressed
    if ctrlDown: result.incl CtrlPressed
    if altDown: result.incl AltPressed
    if superDown: result.incl GuiPressed

proc pushText(text: string) =
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
    queue.add te

proc keyOfCode(code: int; sym: uint32): KeyCode =
  result = keyOfSym(sym.uint)
  if result != KeyNone: return
  for s in xkb.latinSyms(uint32(code + 8)):
    result = keyOfSym(s.uint)
    if result != KeyNone: return
  result = keyOfSym(usKeysym(code, false))

proc keyEvent(code, value: int) =
  let down = value != 0
  let repeat = value == 2
  var sym: uint32
  var text = ""
  if xkb.ready:
    sym = xkb.sym(uint32(code + 8))
    if down: text = xkb.text(uint32(code + 8))
  else:
    sym = uint32(usKeysym(code, shiftDown))
    if down and not ctrlDown and not altDown: text = symText(sym.uint)
  if down and not repeat and xkb.ready and sym != 0:
    var composed = text
    let st = xkb.compose(sym, composed)
    if st == XKB_COMPOSE_COMPOSING or st == XKB_COMPOSE_CANCELLED: text = ""
    elif st == XKB_COMPOSE_COMPOSED: text = composed
  let mods = modsNow()
  case code
  of 42, 54: shiftDown = down
  of 29, 97: ctrlDown = down
  of 56, 100: altDown = down
  of 125, 126: superDown = down
  else: discard
  if not repeat: xkb.updateKey(uint32(code + 8), down)
  let ctrlAlt = CtrlPressed in mods and AltPressed in mods
  if down and ctrlAlt and code == 14:                     # Ctrl+Alt+Backspace
    queue.add input.Event(kind: WindowCloseEvent)
    return
  if down and not repeat and ctrlAlt and vtSwitching:
    let n = case code
            of 59 .. 68: code - 58                        # F1 .. F10
            of 87: 11
            of 88: 12
            else: 0
    if n > 0:
      toConsole(n)
      return
  queue.add input.Event(kind: if down: KeyDownEvent else: KeyUpEvent, key: keyOfCode(code, sym),
                        mods: mods, hasMods: true)
  if down: pushText(text)

proc mouseButton(b: MouseButton; down: bool; fromMouse = true; pen = false; pressure = 0.0'f32) =
  if down == (b in buttons): return
  if down: buttons.incl b else: buttons.excl b
  var e = input.Event(kind: if down: MouseDownEvent else: MouseUpEvent, x: int(ptrX), y: int(ptrY),
                      button: b, mods: modsNow(), hasMods: true, fromMouse: fromMouse, pen: pen,
                      pressure: pressure)
  if down:
    let now = ticks()
    let near = max(4, 4 * uiPercent div 100)
    if b == lastClick.b and now - lastClick.t < 500 and abs(e.x - lastClick.x) < near and
       abs(e.y - lastClick.y) < near:
      inc lastClick.n
    else:
      lastClick.n = 1
    lastClick = (now, e.x, e.y, lastClick.n, b)
    e.clicks = lastClick.n
  queue.add e

proc moveTo(x, y: float; fromMouse = true; pen = false; pressure = 0.0'f32) =
  ptrX = clamp(x, 0.0, float(scrW - 1))
  ptrY = clamp(y, 0.0, float(scrH - 1))
  let e = input.Event(kind: MouseMoveEvent, x: int(ptrX), y: int(ptrY), mods: modsNow(),
                      hasMods: true, fromMouse: fromMouse, pen: pen, pressure: pressure)
  if queue.len > 0 and queue[^1].kind == MouseMoveEvent: queue[^1] = e
  else: queue.add e

proc scaled(v: int; a: AbsInfo; size: int): float =
  let span = max(1, int(a.maximum) - int(a.minimum))
  float(v - int(a.minimum)) * float(size - 1) / float(span)

proc report(d: var Device) =
  ## A device's report (all it said since the last SYN_REPORT) as events.
  if d.moved and (d.dx != 0 or d.dy != 0):
    # (a mouse: a little faster when it is moved fast, and on dense screens)
    let k = max(1.0, uiPercent / 100)
    let speed = sqrt(float(d.dx * d.dx + d.dy * d.dy))
    let accel = if speed > 6: 1.6 elif speed > 3: 1.25 else: 1.0
    if not cursorShown and not touchOnly:
      cursorShown = true
    moveTo(ptrX + float(d.dx) * k * accel, ptrY + float(d.dy) * k * accel)
  if d.absMoved:
    let (ax, ay) = (if d.hasMt and not d.pen: (d.mtX, d.mtY) else: (d.absX, d.absY))
    let pressure = if d.absP.maximum > 0: float32(d.pressure) / float32(d.absP.maximum) else: 0.0'f32
    if d.direct or d.pen:
      # a screen touched, a pen on a tablet: where it is
      let fromMouse = d.pen
      if not d.pen and cursorShown:
        cursorShown = false
      moveTo(scaled(d.ax, ax, scrW), scaled(d.ay, ay, scrH), fromMouse, d.pen, pressure)
    elif d.touching and d.wasTouching:
      # a touch pad: the finger's way moves the pointer
      discard
  if d.direct and not d.pen:
    if d.touching and not d.wasTouching: mouseButton(LeftButton, true, fromMouse = false)
    elif not d.touching and d.wasTouching: mouseButton(LeftButton, false, fromMouse = false)
  if d.pen:
    if d.touching != d.penWas:
      mouseButton(LeftButton, d.touching, fromMouse = true, pen = true,
                  pressure = if d.absP.maximum > 0: float32(d.pressure) / float32(d.absP.maximum) else: 1)
      d.penWas = d.touching
  if d.wheel != 0 or d.hwheel != 0:
    queue.add input.Event(kind: MouseWheelEvent, x: d.hwheel, y: d.wheel, mods: modsNow(),
                          hasMods: true)
  d.wasTouching = d.touching
  d.dx = 0
  d.dy = 0
  d.wheel = 0
  d.hwheel = 0
  d.moved = false
  d.absMoved = false

proc touchPadMove(d: var Device; axis: uint16; v: int) =
  ## (a touch pad: how far the finger went since the last report)
  let prev = if axis == ABS_X or axis == ABS_MT_POSITION_X: d.ax else: d.ay
  if d.touching and d.wasTouching and prev >= 0:
    let a = if axis == ABS_X or axis == ABS_MT_POSITION_X: d.absX else: d.absY
    let span = max(1, int(a.maximum) - int(a.minimum))
    # (the pad's width is about a third of the screen's)
    let delta = float(v - prev) * float(if axis == ABS_X or axis == ABS_MT_POSITION_X: scrW else: scrH) /
                float(span) / 3
    if axis == ABS_X or axis == ABS_MT_POSITION_X: d.dx += int(delta) else: d.dy += int(delta)
    d.moved = true

proc handle(d: var Device; ev: InputEvent) =
  case ev.typ
  of EV_SYN:
    if ev.code == SYN_REPORT: d.report()
    elif ev.code == SYN_DROPPED:
      d.dx = 0
      d.dy = 0
  of EV_KEY:
    let c = int(ev.code)
    let v = int(ev.value)
    case c
    of BTN_LEFT: mouseButton(LeftButton, v != 0)
    of BTN_RIGHT: mouseButton(RightButton, v != 0)
    of BTN_MIDDLE: mouseButton(MiddleButton, v != 0)
    of BTN_SIDE: mouseButton(BackButton, v != 0)
    of BTN_EXTRA: mouseButton(ForwardButton, v != 0)
    of BTN_TOUCH: d.touching = v != 0
    of BTN_TOOL_PEN, BTN_TOOL_RUBBER: d.pen = v != 0
    of BTN_TOOL_FINGER: discard
    of 0 .. 0xff, 0x160 .. 0x2ff:
      if d.keys or d.pipe: keyEvent(c, v)
    else: discard
  of EV_REL:
    case ev.code
    of REL_X: (d.dx += int(ev.value); d.moved = true)
    of REL_Y: (d.dy += int(ev.value); d.moved = true)
    of REL_WHEEL: d.wheel += int(ev.value)
    of REL_HWHEEL: d.hwheel += int(ev.value)
    else: discard
  of EV_ABS:
    let v = int(ev.value)
    case ev.code
    of ABS_X, ABS_Y:
      if not d.hasMt or d.pen:
        if not (d.direct or d.pen): d.touchPadMove(ev.code, v)
        if ev.code == ABS_X: d.ax = v else: d.ay = v
        d.absMoved = true
    of ABS_PRESSURE: d.pressure = v
    of ABS_MT_SLOT: d.slot = v
    of ABS_MT_TRACKING_ID:
      if d.slot in 0 .. d.trackingIds.high: d.trackingIds[d.slot] = v
      # (the first finger down is the one followed)
      if v >= 0 and d.touchSlot < 0: d.touchSlot = d.slot
      elif v < 0 and d.slot == d.touchSlot:
        d.touchSlot = -1
        for i, t in d.trackingIds:
          if t >= 0:
            d.touchSlot = i
            break
    of ABS_MT_POSITION_X, ABS_MT_POSITION_Y:
      if d.hasMt and not d.pen and (d.touchSlot < 0 or d.slot == d.touchSlot):
        if not d.direct: d.touchPadMove(ev.code, v)
        if ev.code == ABS_MT_POSITION_X: d.ax = v else: d.ay = v
        d.absMoved = true
    else: discard
  else: discard

proc readDevices() =
  var i = 0
  var buf: array[64, InputEvent]
  while i < devices.len:
    var gone = false
    while true:
      let n = posix.read(devices[i].fd, addr buf[0], sizeof(buf))
      if n <= 0:
        if n == 0 and not devices[i].pipe: gone = true
        elif n < 0 and errno notin [EAGAIN, EINTR]: gone = true
        break
      for k in 0 ..< n div sizeof(InputEvent): devices[i].handle(buf[k])
      if n < sizeof(buf): break
    if gone: closeDevice(i) else: inc i
  if devices.len > 0 and queue.len > 0:
    for e in queue:
      if e.kind == MouseMoveEvent:
        placeCursor()
        break

# ---- the relays ------------------------------------------------------------------------

proc layoutNow(): ScreenLayout =
  ScreenLayout(width: scrW, height: scrH, scaleX: 1, scaleY: 1, uiScale: uiPercent,
               fullScreen: true, touch: touchOnly)

proc keyboardLayout(): (string, string) =
  ## /etc/default/keyboard (Debian's, Raspberry Pi OS's), /etc/vconsole.conf
  var layout, variant = ""
  for f in ["/etc/default/keyboard", "/etc/vconsole.conf"]:
    let text = try: readFile(f) except IOError, OSError: ""
    for line in text.splitLines:
      let i = line.find('=')
      if i <= 0: continue
      let k = line[0 ..< i].strip
      let v = line[i + 1 .. ^1].strip.strip(chars = {'"', '\''})
      if k in ["XKBLAYOUT", "XKBLAYOUTS"] and layout.len == 0: layout = v.split(',')[0]
      elif k == "XKBVARIANT" and variant.len == 0: variant = v.split(',')[0]
    if layout.len > 0: break
  (layout, variant)

proc cleanUp() =
  if not started: return
  started = false
  for i in countdown(devices.high, 0): closeDevice(i)
  closeConsole()
  case kind
  of skKms: closeKms()
  of skFbdev, skFile: closeFb()
  else: discard

proc cleanUpAtExit() {.noconv.} = cleanUp()

proc onStop(sig: cint) {.noconv.} =
  cleanUp()
  quit(128 + sig)

proc fbAvailable*(): bool =
  ## A screen this driver can show the app on (a file for tests, a card, a
  ## framebuffer), as far as can be told without taking it.
  if getEnv("RETRO_FB_FILE").len > 0: return true
  for i in 0 .. 7:
    if fileExists("/dev/dri/card" & $i): return true
  fileExists("/dev/fb0")

proc fbCreateWindow(layout: var ScreenLayout; icon: pointer; iconLen: int) =
  let file = getEnv("RETRO_FB_FILE")
  var ok = false
  if file.len > 0: ok = openFile(file)
  if not ok and getEnv("RETRO_DRIVER").toLowerAscii notin ["fb", "fbdev"]:
    let card = getEnv("RETRO_KMS_CARD")
    if card.len > 0: ok = openKms(card)
    else:
      for i in 0 .. 7:
        if fileExists("/dev/dri/card" & $i) and openKms("/dev/dri/card" & $i):
          ok = true
          break
  if not ok:
    let dev = getEnv("RETRO_FBDEV", "/dev/fb0")
    ok = openFbdev(dev)
  if not ok:
    say "no screen to show the app on (no /dev/dri/card*, no /dev/fb0 this user may use: " &
        "the video group?)"
    quit 1
  started = true
  addExitProc(cleanUpAtExit)
  signal(SIGINT, onStop)
  signal(SIGTERM, onStop)
  signal(SIGHUP, onStop)
  # how dense the screen is: the UI as large as on a desktop's screen
  uiPercent = 100
  if mmW > 0 and mmW < 5000:
    let dpi = float(scrW) * 25.4 / float(mmW)
    if dpi > 120: uiPercent = clamp(int(dpi / 96 * 4 + 0.5) * 25, 100, 300)
  shadow = newSeq[uint32](scrW * scrH)
  pb.attach(cast[ptr UncheckedArray[uint32]](addr shadow[0]), scrW, scrH, scrW)
  grab = getEnv("RETRO_FB_GRAB") != "0"
  let (lay, variant) = keyboardLayout()
  discard xkb.fromSystem(lay, variant)
  scanDevices()
  openConsole()
  ptrX = float(scrW div 2)
  ptrY = float(scrH div 2)
  cursorShown = not touchOnly
  makeCursor()
  copyOut(Rect(x: 0, y: 0, w: scrW, h: scrH))
  layout = layoutNow()
  queue.add input.Event(kind: WindowFocusGainedEvent)

proc fbRefresh() =
  let d = pb.takeDamage()
  if d.w <= 0 or d.h <= 0: return
  copyOut(d)
  tellDirty(d)

proc takeEvent(e: var input.Event): bool =
  if queue.len == 0: return false
  e = queue[0]
  queue.delete(0)
  true

proc fbPollEvent(e: var input.Event; flags: set[InputFlag]): bool =
  if takeEvent(e): return true
  consoleSwitches()
  if ticks() - lastScan > 2000 and getEnv("RETRO_FB_INPUT").len == 0: scanDevices()
  readDevices()
  takeEvent(e)

proc fbWaitEvent(e: var input.Event; timeoutMs: int; flags: set[InputFlag]): bool =
  if fbPollEvent(e, flags): return true
  let t0 = ticks()
  while true:
    var wait = if timeoutMs < 0: 2000 else: max(0, timeoutMs - (ticks() - t0))
    wait = min(wait, max(0, 2000 - (ticks() - lastScan)))
    var fds: seq[TPollfd]
    for d in devices: fds.add TPollfd(fd: d.fd, events: POLLIN)
    if fds.len > 0: discard poll(addr fds[0], Tnfds(fds.len), cint(wait))
    else: discard poll(nil, 0, cint(wait))
    if fbPollEvent(e, flags): return true
    if timeoutMs >= 0 and ticks() - t0 >= timeoutMs: return false

proc fbScreenPixel*(x, y: int): uint32 =
  ## (tests) The pixel the screen shows at `x`, `y`, as ours (XRGB): what was
  ## copied to it, the pointer too.
  if scanout == nil or x < 0 or y < 0 or x >= scrW or y >= scrH: return 0
  let at = y * pitchBytes
  let v = case bpp
    of 32: cast[ptr UncheckedArray[uint32]](addr scanout[at])[x]
    of 24: uint32(scanout[at + x * 3]) or (uint32(scanout[at + x * 3 + 1]) shl 8) or
           (uint32(scanout[at + x * 3 + 2]) shl 16)
    of 16: uint32(cast[ptr UncheckedArray[uint16]](addr scanout[at])[x])
    else: 0'u32
  proc chan(off, len: int): uint32 =
    let m = (1'u32 shl len) - 1
    let c = (v shr off) and m
    if len >= 8: c shr (len - 8) else: (c shl (8 - len)) or (c shr (2 * len - 8).max(0))
  (chan(redOff, redLen) shl 16) or (chan(greenOff, greenLen) shl 8) or chan(blueOff, blueLen)

proc fbScreenKind*(): string =
  ## (tests, the about box) What shows the app: "kms", "fbdev", "file" or "".
  case kind
  of skKms: "kms"
  of skFbdev: "fbdev"
  of skFile: "file"
  else: ""

proc initFbDriver*() =
  ftTarget = proc (): ptr PixBuf = addr pb
  windowRelays = WindowRelays(
    createWindow: fbCreateWindow, getWindowLayout: layoutNow, refresh: fbRefresh,
    saveState: proc () = discard, restoreState: proc () = pb.noClip(),
    setClipRect: proc (r: Rect) = pb.setClip(r), setCursor: fbSetCursor,
    pointerHeight: fbPointerHeight, setWindowTitle: proc (t: string) = discard)
  fontRelays = ftFontRelays()
  drawRelays = DrawRelays(
    fillRect: proc (r: Rect; c: Color) = pb.fill(r, c),
    drawLine: proc (x1, y1, x2, y2: int; c: Color) = pb.line(x1, y1, x2, y2, c),
    drawPoint: proc (x, y: int; c: Color) = pb.point(x, y, c),
    blitRGBA: proc (p: ptr UncheckedArray[uint32]; w, h: int; dst: Rect; f: RGBAFormat): bool =
      pb.blit(p, w, h, dst, f),
    drawRGBA: proc (p: ptr UncheckedArray[uint32]; w, h: int; dst: Rect; f: RGBAFormat): bool =
      pb.draw(p, w, h, dst, f))
  inputRelays = InputRelays(pollEvent: fbPollEvent, waitEvent: fbWaitEvent, getTicks: ticks,
                            sleep: proc (ms: int) = os.sleep(ms), shutdown: cleanUp)
  clipboardRelays = ClipboardRelays(getText: proc (): string = clipboardText,
                                    putText: proc (t: string) = clipboardText = t)

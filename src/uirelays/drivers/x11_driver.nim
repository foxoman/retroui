# X11 + Xft backend driver. Sets all hooks from core/input and core/screen.
# Uses Xlib for windowing/events, Xft for antialiased font rendering.
# Double-buffered via X Pixmap.

import ../coords, ../input, ../screen, ../eglload, ../services
import penaxes
from ../pixelutils import resizedRGBA
import std/[strutils, os, dynlib]
when defined(nimony):
  {.feature: "lenientnils".}
  import std/syncio  # for `quit`

# All X11/Xft entry points below are loaded at runtime via the `dynlib`
# pragma (dlopen of libX11.so / libXft.so), so no link-time `-lX11 -lXft`
# is required and the dev packages need not be installed to build.

# ---- Cross-compiler helpers ----
# Nimony needs `toCString` for runtime string -> cstring; Nim uses the
# `cstring` converter.

proc cstr(s: var string): cstring =
  when defined(nimony): toCString(s)
  else: s.cstring

# ---- POSIX timing (libc; works under Nim and Nimony) ----

type
  ClockId {.importc: "clockid_t", header: "<time.h>".} = distinct cint
  Timespec {.importc: "struct timespec", header: "<time.h>".} = object
    tv_sec: clong
    tv_nsec: clong

proc c_setlocale(category: cint; locale: cstring): cstring
  {.importc: "setlocale", header: "<locale.h>".}
var LC_CTYPE {.importc: "LC_CTYPE", header: "<locale.h>".}: cint

proc clock_gettime(clk: ClockId; tp: var Timespec): cint
  {.importc, header: "<time.h>".}
proc nanosleep(req: var Timespec; rem: var Timespec): cint
  {.importc, header: "<time.h>".}

# ---- POSIX environment (libc) ----
# Read and unread directly rather than through `std/os`, which the second
# compiler this file is built with does not have all of.

proc c_getenv(name: cstring): cstring
  {.importc: "getenv", header: "<stdlib.h>".}
proc c_unsetenv(name: cstring): cint
  {.importc: "unsetenv", header: "<stdlib.h>".}

proc sleepMs(ms: int) =
  var req = Timespec(tv_sec: clong(ms div 1000),
                     tv_nsec: clong((ms mod 1000) * 1_000_000))
  var rem = Timespec(tv_sec: 0, tv_nsec: 0)
  discard nanosleep(req, rem)

# ---- X11 type definitions ----

const
  libX11 = "libX11.so(|.6)"
  libXft = "libXft.so(|.2)"

type
  XID = culong
  Atom = culong
  XTime = culong
  XKeySym = culong
  XBool = cint
  XStatus = cint

  XRectangle {.pure.} = object
    x, y: cshort
    width, height: cushort

  XClassHint {.pure.} = object
    res_name: cstring
    res_class: cstring

  XColor {.pure, used.} = object
    pixel: culong
    red, green, blue: cushort
    flags: uint8
    pad: uint8

  # ---- Event types ----

  XAnyEvent {.pure.} = object
    theType: cint
    serial: culong
    send_event: XBool
    display: pointer
    window: XID

  XKeyEvent {.pure.} = object
    theType: cint
    serial: culong
    send_event: XBool
    display: pointer
    window: XID
    root: XID
    subwindow: XID
    time: XTime
    x, y: cint
    x_root, y_root: cint
    state: cuint
    keycode: cuint
    same_screen: XBool

  XButtonEvent {.pure.} = object
    theType: cint
    serial: culong
    send_event: XBool
    display: pointer
    window: XID
    root: XID
    subwindow: XID
    time: XTime
    x, y: cint
    x_root, y_root: cint
    state: cuint
    button: cuint
    same_screen: XBool

  XMotionEvent {.pure.} = object
    theType: cint
    serial: culong
    send_event: XBool
    display: pointer
    window: XID
    root: XID
    subwindow: XID
    time: XTime
    x, y: cint
    x_root, y_root: cint
    state: cuint
    is_hint: uint8
    same_screen: XBool

  XConfigureEvent {.pure.} = object
    theType: cint
    serial: culong
    send_event: XBool
    display: pointer
    event: XID
    window: XID
    x, y: cint
    width, height: cint
    border_width: cint
    above: XID
    override_redirect: XBool

  XExposeEvent {.pure.} = object
    theType: cint
    serial: culong
    send_event: XBool
    display: pointer
    window: XID
    x, y: cint
    width, height: cint
    count: cint

  XClientMessageEvent {.pure.} = object
    theType: cint
    serial: culong
    send_event: XBool
    display: pointer
    window: XID
    message_type: Atom
    format: cint
    data: array[5, clong]

  XFocusChangeEvent {.pure.} = object
    theType: cint
    serial: culong
    send_event: XBool
    display: pointer
    window: XID
    mode: cint
    detail: cint

  XPropertyEvent {.pure.} = object
    theType: cint
    serial: culong
    send_event: XBool
    display: pointer
    window: XID
    atom: Atom
    time: XTime
    state: cint

  XSelectionRequestEvent {.pure.} = object
    theType: cint
    serial: culong
    send_event: XBool
    display: pointer
    owner: XID
    requestor: XID
    selection: Atom
    target: Atom
    property: Atom
    time: XTime

  XSelectionEvent {.pure.} = object
    theType: cint
    serial: culong
    send_event: XBool
    display: pointer
    requestor: XID
    selection: Atom
    target: Atom
    property: Atom
    time: XTime

  XGenericEventCookie {.pure.} = object
    ## An extension's event (XInput 2's), its data fetched by `XGetEventData`.
    theType: cint
    serial: culong
    send_event: XBool
    display: pointer
    extension: cint
    evtype: cint
    cookie: cuint
    data: pointer

  XEvent {.union.} = object
    theType: cint
    xany: XAnyEvent
    xkey: XKeyEvent
    xbutton: XButtonEvent
    xmotion: XMotionEvent
    xconfigure: XConfigureEvent
    xexpose: XExposeEvent
    xclient: XClientMessageEvent
    xfocus: XFocusChangeEvent
    xselection: XSelectionEvent
    xselectionrequest: XSelectionRequestEvent
    xproperty: XPropertyEvent
    xcookie: XGenericEventCookie
    pad: array[24, clong]  # XEvent is 192 bytes on 64-bit

  # ---- Xft types ----

  XRenderColor {.pure.} = object
    red, green, blue, alpha: cushort

  XftColor {.pure.} = object
    pixel: culong
    color: XRenderColor

  XftFont {.pure.} = object
    ascent: cint
    descent: cint
    height: cint
    max_advance_width: cint
    charset: pointer
    pattern: pointer

  XGlyphInfo {.pure.} = object
    width, height: cushort
    x, y: cshort
    xOff, yOff: cshort

# ---- X11 constants ----

const
  None = 0.XID
  CurrentTime = 0.XTime
  XA_ATOM = 4.Atom
  XA_STRING = 31.Atom
  XA_CARDINAL = 6.Atom
  PropModeReplace = 0.cint

  # Event types
  KeyPress = 2.cint
  KeyRelease = 3.cint
  ButtonPress = 4.cint
  ButtonRelease = 5.cint
  MotionNotify = 6.cint
  FocusIn = 9.cint
  FocusOut = 10.cint
  Expose = 12.cint
  ConfigureNotify = 22.cint
  PropertyNotify = 28.cint
  SelectionNotify = 31.cint
  SelectionRequest = 30.cint
  ClientMessage = 33.cint
  GenericEvent = 35.cint

  # Event masks
  ExposureMask = 1 shl 15
  KeyPressMask = 1 shl 0
  KeyReleaseMask = 1 shl 1
  ButtonPressMask = 1 shl 2
  ButtonReleaseMask = 1 shl 3
  PointerMotionMask = 1 shl 6
  StructureNotifyMask = 1 shl 17
  SubstructureNotifyMask = 1 shl 19
  SubstructureRedirectMask = 1 shl 20
  FocusChangeMask = 1 shl 21
  PropertyChangeMask = 1 shl 22

  # Focus changes that only a grab made (a window manager moving the window)
  NotifyGrab = 1.cint
  NotifyUngrab = 2.cint

  # Modifier masks
  ShiftMask = 1'u32
  ControlMask = 4'u32
  Mod1Mask = 8'u32   # Alt
  Mod4Mask = 64'u32  # Super/GUI

  # Mouse buttons
  Button1 = 1'u32
  Button2 = 2'u32
  Button3 = 3'u32
  Button4 = 4'u32  # scroll up
  Button5 = 5'u32  # scroll down
  Button1Mask {.used.} = 1'u32 shl 8
  Button2Mask {.used.} = 1'u32 shl 9
  Button3Mask {.used.} = 1'u32 shl 10

  # Cursor shapes
  XC_left_ptr = 68'u32
  XC_xterm = 152'u32
  XC_watch = 150'u32
  XC_crosshair = 34'u32
  XC_hand2 = 60'u32
  XC_sb_v_double_arrow = 116'u32
  XC_sb_h_double_arrow = 108'u32
  XC_bottom_right_corner = 14'u32   # top left to bottom right
  XC_bottom_left_corner = 12'u32    # top right to bottom left
  XC_fleur = 52'u32                 # four arrows: move

  # KeySyms
  XK_a = 0x61'u
  XK_z = 0x7a'u
  XK_CapitalA = 0x41'u
  XK_CapitalZ = 0x5a'u
  XK_0 = 0x30'u
  XK_9 = 0x39'u
  XK_F1 = 0xffbe'u
  XK_F12 = 0xffc9'u
  XK_Return = 0xff0d'u
  XK_space = 0x20'u
  XK_Escape = 0xff1b'u
  XK_Tab = 0xff09'u
  XK_ISO_Left_Tab = 0xfe20'u
  XK_BackSpace = 0xff08'u
  XK_Delete = 0xffff'u
  XK_Insert = 0xff63'u
  XK_Left = 0xff51'u
  XK_Up = 0xff52'u
  XK_Right = 0xff53'u
  XK_Down = 0xff54'u
  XK_Page_Up = 0xff55'u
  XK_Page_Down = 0xff56'u
  XK_Home = 0xff50'u
  XK_End = 0xff57'u
  XK_Caps_Lock = 0xffe5'u
  XK_plus = 0x2b'u
  XK_comma = 0x2c'u
  XK_period = 0x2e'u
  XK_minus = 0x2d'u
  XK_equal = 0x3d'u

  # Input method
  XIMPreeditNothing = 0x0008
  XIMStatusNothing = 0x0400
  XBufferOverflow = -1.cint
  XLookupChars = 2.cint
  XLookupKeySymVal = 3.cint
  XLookupBoth = 4.cint

# ---- POSIX select for timeout waiting ----

proc ConnectionNumber(dpy: pointer): cint
  {.cdecl, dynlib: libX11, importc: "XConnectionNumber".}

type
  XFdSet {.importc: "fd_set", header: "<sys/select.h>".} = object
  XTimeval {.importc: "struct timeval", header: "<sys/time.h>".} = object
    tv_sec {.importc.}: clong
    tv_usec {.importc.}: clong

proc xFdZero(s: ptr XFdSet)
  {.importc: "FD_ZERO", header: "<sys/select.h>".}
proc xFdSet(fd: cint; s: ptr XFdSet)
  {.importc: "FD_SET", header: "<sys/select.h>".}
proc xSelect(nfds: cint; readfds, writefds, exceptfds: ptr XFdSet;
             timeout: ptr XTimeval): cint
  {.importc: "select", header: "<sys/select.h>".}

# ---- X11 function imports ----

proc XOpenDisplay(name: cstring): pointer
  {.cdecl, dynlib: libX11, importc.}
proc XResourceManagerString(dpy: pointer): cstring
  {.cdecl, dynlib: libX11, importc.}
proc XDefaultScreen(dpy: pointer): cint
  {.cdecl, dynlib: libX11, importc.}
proc XDisplayWidth(dpy: pointer; screen: cint): cint
  {.cdecl, dynlib: libX11, importc.}
proc XDisplayHeight(dpy: pointer; screen: cint): cint
  {.cdecl, dynlib: libX11, importc.}
proc XRootWindow(dpy: pointer; screen: cint): XID
  {.cdecl, dynlib: libX11, importc.}
proc XDefaultVisual(dpy: pointer; screen: cint): pointer
  {.cdecl, dynlib: libX11, importc.}
proc XDefaultColormap(dpy: pointer; screen: cint): XID
  {.cdecl, dynlib: libX11, importc.}
proc XDefaultDepth(dpy: pointer; screen: cint): cint
  {.cdecl, dynlib: libX11, importc.}
proc XBlackPixel(dpy: pointer; screen: cint): culong
  {.cdecl, dynlib: libX11, importc.}
proc XWhitePixel(dpy: pointer; screen: cint): culong
  {.cdecl, dynlib: libX11, importc, used.}
proc XCreateSimpleWindow(dpy: pointer; parent: XID;
  x, y: cint; w, h, border: cuint; borderColor, bgColor: culong): XID
  {.cdecl, dynlib: libX11, importc.}
proc XMapWindow(dpy: pointer; w: XID): cint
  {.cdecl, dynlib: libX11, importc.}
proc XDestroyWindow(dpy: pointer; w: XID): cint
  {.cdecl, dynlib: libX11, importc.}
proc XSelectInput(dpy: pointer; w: XID; mask: clong): cint
  {.cdecl, dynlib: libX11, importc.}
proc XCreatePixmap(dpy: pointer; d: XID; w, h, depth: cuint): XID
  {.cdecl, dynlib: libX11, importc.}
proc XFreePixmap(dpy: pointer; p: XID): cint
  {.cdecl, dynlib: libX11, importc.}
proc XCreateGC(dpy: pointer; d: XID; mask: culong; values: pointer): pointer
  {.cdecl, dynlib: libX11, importc.}
proc XFreeGC(dpy: pointer; gc: pointer): cint
  {.cdecl, dynlib: libX11, importc, used.}
proc XSetForeground(dpy: pointer; gc: pointer; pixel: culong): cint
  {.cdecl, dynlib: libX11, importc.}
proc XFillRectangle(dpy: pointer; d: XID; gc: pointer;
  x, y: cint; w, h: cuint): cint
  {.cdecl, dynlib: libX11, importc.}
proc XDrawLine(dpy: pointer; d: XID; gc: pointer;
  x1, y1, x2, y2: cint): cint
  {.cdecl, dynlib: libX11, importc.}
proc XDrawPoint(dpy: pointer; d: XID; gc: pointer; x, y: cint): cint
  {.cdecl, dynlib: libX11, importc.}
proc XCopyArea(dpy: pointer; src, dst: XID; gc: pointer;
  srcX, srcY: cint; w, h: cuint; dstX, dstY: cint): cint
  {.cdecl, dynlib: libX11, importc.}

type
  XImageObj = object
    ## The front of Xlib's `XImage`, which is longer than this. Only a prefix
    ## is declared because only a prefix is touched, and a prefix of a C
    ## struct is at the same offsets as the whole of it. Nothing here is ever
    ## allocated on this side -- `XCreateImage` makes it and the fields are
    ## read back through the pointer it returns.
    width, height: cint
    xoffset: cint
    format: cint
    data: pointer
    byteOrder: cint         ## LSBFirst / MSBFirst, the *server's*
    bitmapUnit: cint
    bitmapBitOrder: cint
    bitmapPad: cint
    depth: cint
    bytesPerLine: cint
    bitsPerPixel: cint      ## 32 for the depth-24 visual nearly everything
                            ## has; the one field worth asking about
    redMask, greenMask, blueMask: culong

const
  ZPixmap = 2
  LSBFirst = 0
  MSBFirst = 1

proc XCreateImage(dpy: pointer; visual: pointer; depth: cuint; format: cint;
  offset: cint; data: pointer; w, h: cuint;
  bitmapPad, bytesPerLine: cint): ptr XImageObj
  {.cdecl, dynlib: libX11, importc.}
proc XGetImage(dpy: pointer; d: XID; x, y: cint; w, h: cuint;
  planeMask: culong; format: cint): ptr XImageObj
  {.cdecl, dynlib: libX11, importc.}
proc XPutImage(dpy: pointer; d: XID; gc: pointer; image: ptr XImageObj;
  srcX, srcY: cint; dstX, dstY: cint; w, h: cuint): cint
  {.cdecl, dynlib: libX11, importc.}
proc XSetClipRectangles(dpy: pointer; gc: pointer;
  x, y: cint; rects: ptr XRectangle; n, ordering: cint): cint
  {.cdecl, dynlib: libX11, importc.}
proc XSetClipMask(dpy: pointer; gc: pointer; pixmap: XID): cint
  {.cdecl, dynlib: libX11, importc.}
proc XNextEvent(dpy: pointer; ev: ptr XEvent): cint
  {.cdecl, dynlib: libX11, importc.}
proc XPeekEvent(dpy: pointer; ev: ptr XEvent): cint
  {.cdecl, dynlib: libX11, importc.}
proc XkbSetDetectableAutoRepeat(dpy: pointer; detectable: XBool;
                                supported: ptr XBool): XBool
  {.cdecl, dynlib: libX11, importc.}
proc XPending(dpy: pointer): cint
  {.cdecl, dynlib: libX11, importc.}
proc XFlush(dpy: pointer): cint
  {.cdecl, dynlib: libX11, importc.}
proc XStoreName(dpy: pointer; w: XID; name: cstring): cint
  {.cdecl, dynlib: libX11, importc.}
proc XSetClassHint(dpy: pointer; w: XID; class_hints: ptr XClassHint): cint
  {.cdecl, dynlib: libX11, importc.}
proc XInternAtom(dpy: pointer; name: cstring; onlyIfExists: XBool): Atom
  {.cdecl, dynlib: libX11, importc.}
proc XSetWMProtocols(dpy: pointer; w: XID; protocols: ptr Atom; count: cint): XStatus
  {.cdecl, dynlib: libX11, importc.}
proc XCreateFontCursor(dpy: pointer; shape: cuint): XID
  {.cdecl, dynlib: libX11, importc.}
proc XDefineCursor(dpy: pointer; w: XID; cursor: XID): cint
  {.cdecl, dynlib: libX11, importc.}
proc XLookupString(ev: ptr XKeyEvent; buf: cstring; bufSize: cint;
  keysym: ptr XKeySym; compose: pointer): cint
  {.cdecl, dynlib: libX11, importc.}
proc XSetLocaleModifiers(modifiers: cstring): cstring
  {.cdecl, dynlib: libX11, importc.}
proc XOpenIM(dpy: pointer; rdb: pointer; resName, resClass: cstring): pointer
  {.cdecl, dynlib: libX11, importc.}
proc XCloseIM(im: pointer): XStatus
  {.cdecl, dynlib: libX11, importc.}
# The two varargs calls take a NULL-terminated list of name/value pairs. Every
# argument is passed as a pointer, so the list is of one type.
proc XCreateIC(im: pointer): pointer
  {.cdecl, dynlib: libX11, importc, varargs.}
proc XGetICValues(ic: pointer): cstring
  {.cdecl, dynlib: libX11, importc, varargs.}
proc XDestroyIC(ic: pointer)
  {.cdecl, dynlib: libX11, importc.}
proc XSetICFocus(ic: pointer)
  {.cdecl, dynlib: libX11, importc.}
proc XUnsetICFocus(ic: pointer)
  {.cdecl, dynlib: libX11, importc.}
proc Xutf8LookupString(ic: pointer; ev: ptr XKeyEvent; buf: cstring;
  bufSize: cint; keysym: ptr XKeySym; status: ptr cint): cint
  {.cdecl, dynlib: libX11, importc.}
proc XFilterEvent(ev: ptr XEvent; w: XID): XBool
  {.cdecl, dynlib: libX11, importc.}
proc XSetSelectionOwner(dpy: pointer; selection: Atom; owner: XID; time: XTime): cint
  {.cdecl, dynlib: libX11, importc.}
proc XConvertSelection(dpy: pointer; selection, target, property: Atom;
  requestor: XID; time: XTime): cint
  {.cdecl, dynlib: libX11, importc.}
proc XChangeProperty(dpy: pointer; w: XID; property, propType: Atom;
  format, mode: cint; data: pointer; nelements: cint): cint
  {.cdecl, dynlib: libX11, importc.}
proc XGetWindowProperty(dpy: pointer; w: XID; property: Atom;
  offset, length: clong; delete: XBool; reqType: Atom;
  actualType: ptr Atom; actualFormat: ptr cint;
  nitems, bytesAfter: ptr culong; prop: ptr pointer): cint
  {.cdecl, dynlib: libX11, importc.}
proc XSendEvent(dpy: pointer; w: XID; propagate: XBool;
  mask: clong; ev: ptr XEvent): XStatus
  {.cdecl, dynlib: libX11, importc.}
proc XDeleteProperty(dpy: pointer; w: XID; property: Atom): cint
  {.cdecl, dynlib: libX11, importc.}
proc XQueryPointer(dpy: pointer; w: XID; root, child: ptr XID;
  rootX, rootY, winX, winY: ptr cint; mask: ptr cuint): XBool
  {.cdecl, dynlib: libX11, importc.}
proc XUngrabPointer(dpy: pointer; time: XTime): cint
  {.cdecl, dynlib: libX11, importc.}
proc XIconifyWindow(dpy: pointer; w: XID; screen: cint): XStatus
  {.cdecl, dynlib: libX11, importc.}
proc XTranslateCoordinates(dpy: pointer; src, dst: XID; srcX, srcY: cint;
  dstX, dstY: ptr cint; child: ptr XID): XBool
  {.cdecl, dynlib: libX11, importc.}
proc XFree(data: pointer): cint
  {.cdecl, dynlib: libX11, importc.}
proc XCloseDisplay(dpy: pointer): cint
  {.cdecl, dynlib: libX11, importc.}

# ---- Xft function imports ----

proc XftFontOpenName(dpy: pointer; screen: cint; name: cstring): ptr XftFont
  {.cdecl, dynlib: libXft, importc.}
proc XftFontClose(dpy: pointer; font: ptr XftFont): void
  {.cdecl, dynlib: libXft, importc.}
proc XftDrawCreate(dpy: pointer; d: XID; visual: pointer; cmap: XID): pointer
  {.cdecl, dynlib: libXft, importc.}
proc XftDrawDestroy(draw: pointer): void
  {.cdecl, dynlib: libXft, importc.}
proc XftDrawChange(draw: pointer; d: XID): void
  {.cdecl, dynlib: libXft, importc, used.}
proc XftDrawStringUtf8(draw: pointer; color: ptr XftColor; font: ptr XftFont;
  x, y: cint; text: cstring; len: cint): void
  {.cdecl, dynlib: libXft, importc.}
proc XftTextExtentsUtf8(dpy: pointer; font: ptr XftFont;
  text: cstring; len: cint; extents: ptr XGlyphInfo): void
  {.cdecl, dynlib: libXft, importc.}
proc XftDrawCreateAlpha(dpy: pointer; pixmap: XID; depth: cint): pointer
  {.cdecl, dynlib: libXft, importc.}
proc XftDrawRect(draw: pointer; color: ptr XftColor;
  x, y: cint; w, h: cuint): void
  {.cdecl, dynlib: libXft, importc.}
proc XftDrawSetClipRectangles(draw: pointer; x, y: cint;
  rects: ptr XRectangle; n: cint): XBool
  {.cdecl, dynlib: libXft, importc.}
proc XftDrawSetClip(draw: pointer; region: pointer): XBool
  {.cdecl, dynlib: libXft, importc.}

# ---- Helpers ----

proc toXftColor(c: screen.Color): XftColor =
  result = XftColor(
    pixel: (c.r.culong shl 16) or (c.g.culong shl 8) or c.b.culong,
    color: XRenderColor(
      red: c.r.cushort * 257,
      green: c.g.cushort * 257,
      blue: c.b.cushort * 257,
      alpha: c.a.cushort * 257))

proc toPixel(c: screen.Color): culong {.inline.} =
  (c.r.culong shl 16) or (c.g.culong shl 8) or c.b.culong

# ---- Font handle management ----

type
  FontSlot = object
    xftFont: ptr XftFont
    metrics: FontMetrics

var fonts: seq[FontSlot]

proc getFontPtr(f: screen.Font): ptr XftFont {.inline.} =
  let idx = f.int - 1
  if idx >= 0 and idx < fonts.len: fonts[idx].xftFont
  else: nil

# ---- Driver state ----

var
  gDisplay: pointer
  gScreen: cint
  gVisual: pointer
  gColormap: XID
  gDepth: cint
  gWindow: XID
  gGC: pointer         # Xlib GC for primitives
  gBackPixmap: XID     # double buffer
  gXftDraw: pointer    # Xft draw context on back pixmap
  gWidth, gHeight: cint
  gWmDeleteWindow: Atom
  gClipboard: Atom
  gUtf8String: Atom
  gTargets: Atom
  gClipboardText: string
  gClipProperty: Atom
  gUiScale: int = 100
  gXim: pointer        # input method, nil if none could be opened
  gSystemFrame = true  # the window manager draws the frame (else the app does)
  gFocused = true      # the window has the keyboard
  gMaximized = false   # _NET_WM_STATE says maximized, both ways
  gNetWmState: Atom
  gXic: pointer        # its input context for `gWindow`

var eventQueue: seq[input.Event]

type XRenderPictFormat = ptr object

proc XRenderFindStandardFormat(display: pointer; format: cint): XRenderPictFormat
  {.cdecl, dynlib: "libXrender.so(|.1)", importc.}
proc XRenderFindVisualFormat(display, visual: pointer): XRenderPictFormat
  {.cdecl, dynlib: "libXrender.so(|.1)", importc.}
proc XRenderCreatePicture(display: pointer; drawable: XID;
    format: XRenderPictFormat; mask: culong; attributes: pointer): XID
  {.cdecl, dynlib: "libXrender.so(|.1)", importc.}
proc XRenderFreePicture(display: pointer; picture: XID)
  {.cdecl, dynlib: "libXrender.so(|.1)", importc.}
proc XRenderComposite(display: pointer; operation: cint; source, mask, dest: XID;
    sx, sy, mx, my, dx, dy: cint; width, height: cuint)
  {.cdecl, dynlib: "libXrender.so(|.1)", importc.}
proc XRenderFillRectangle(display: pointer; operation: cint; dest: XID;
    color: ptr XRenderColor; x, y: cint; width, height: cuint)
  {.cdecl, dynlib: "libXrender.so(|.1)", importc.}
proc XRenderSetPictureClipRectangles(display: pointer; picture: XID;
    x, y: cint; rectangles: ptr XRectangle; count: cint)
  {.cdecl, dynlib: "libXrender.so(|.1)", importc.}

var
  rgbaClipActive: bool
  rgbaClip: XRectangle

var gGpu = false    ## the window is drawn with OpenGL

proc pushEvent(e: input.Event) =
  # Pointer motion is coalesced: X11 sends one event per hardware sample --
  # a thousand a second with the mice that report that fast -- and a host that
  # repaints per event would repaint a thousand times to follow one sweep of
  # the pointer. Only the newest position is of any use, so a motion that
  # arrives behind another that nobody has read yet replaces it. Anything
  # else in between (a click, a key) ends the run and is kept in order.
  if e.kind == MouseMoveEvent and eventQueue.len > 0 and
     eventQueue[^1].kind == MouseMoveEvent:
    eventQueue[^1] = e
  else:
    eventQueue.add e

# ---- Frame de-duplication ----
#
# What puts a frame on screen is a copy of the whole back pixmap over the
# window, and that copy is the expensive half of drawing one: a maximized
# window on a large display is ten megapixels for the X server to read and
# write, and every one of them is damage the compositor then has to work
# through. An app written as a redraw-and-present loop asks for that copy
# once per turn of the loop whether or not the turn had anything new to show,
# and most turns do not -- a caret that did not blink, a progress line that
# still says what it said thirty milliseconds ago, a timeout that expired
# with nothing behind it.
#
# So the driver checksums the drawing. Everything that can change a pixel of
# the back pixmap folds its arguments into a running hash, and `x11Refresh`
# skips the copy when the hash matches the picture the window is already
# showing: the same calls with the same arguments in the same order cannot
# have produced a different picture, so the copy that is skipped is provably
# the window onto itself. Nothing else depends on it -- `Expose` repaints
# from the pixmap on its own, so a window that was covered still comes back,
# and a resize throws the pixmap away and forces the next copy.

const FrameHashSeed = 0xcbf29ce484222325'u64

var
  gFrameHash = FrameHashSeed  ## the frame being drawn now
  gShownHash = FrameHashSeed  ## the frame the window is showing
  gFrameForced = true         ## the window is showing nothing yet

var
  gDamage: coords.Rect        ## what pictures were put on the back buffer this frame
  gDamageAll = false          ## ... or something drawn that was not one
  gBlitSerial = 0'u64

proc damage(x, y, w, h: int) =
  ## A picture put at `x`, `y`: that part of the window is copied at the
  ## refresh (not all of it), and the frame is not the one shown.
  inc gBlitSerial
  if w <= 0 or h <= 0: return
  if gDamage.w <= 0 or gDamage.h <= 0:
    gDamage = coords.Rect(x: x, y: y, w: w, h: h)
  else:
    let x0 = min(gDamage.x, x)
    let y0 = min(gDamage.y, y)
    let x1 = max(gDamage.x + gDamage.w, x + w)
    let y1 = max(gDamage.y + gDamage.h, y + h)
    gDamage = coords.Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)

proc mixFrame(x: uint64) {.inline.} =
  var h = (gFrameHash xor x) * 0x9E3779B97F4A7C15'u64
  gFrameHash = h xor (h shr 29)

proc mixFrame(x: int) {.inline.} =
  mixFrame(cast[uint64](x))

proc mixFrame(c: screen.Color) {.inline.} =
  mixFrame(c.r.uint64 or (c.g.uint64 shl 8) or
           (c.b.uint64 shl 16) or (c.a.uint64 shl 24))

proc mixFrameText(t: cstring; len: cint) =
  let bytes = cast[ptr UncheckedArray[char]](t)
  for i in 0 ..< len.int: mixFrame(bytes[i].uint64)

# ---- Back-buffer management ----

proc recreateBackBuffer() =
  if gBackPixmap != None:
    XftDrawDestroy(gXftDraw)
    discard XFreePixmap(gDisplay, gBackPixmap)
  gBackPixmap = XCreatePixmap(gDisplay, gWindow,
    gWidth.cuint, gHeight.cuint, gDepth.cuint)
  gXftDraw = XftDrawCreate(gDisplay, gBackPixmap, gVisual, gColormap)
  # Clear to black
  discard XSetForeground(gDisplay, gGC, 0)
  discard XFillRectangle(gDisplay, gBackPixmap, gGC, 0, 0,
    gWidth.cuint, gHeight.cuint)
  # A new pixmap is a new window: whatever the next frame hashes to, it has
  # never been on screen.
  gFrameForced = true

# ---- Key translation ----

proc translateKeySym(ks: XKeySym): input.KeyCode =
  if ks >= XK_a and ks <= XK_z:
    return input.KeyCode(ord(KeyA) + (ks.int - XK_a.int))
  # With Shift (or Caps Lock) down, X hands over the capital's keysym. It is
  # the same key: a press has to say so, and a release all the more -- the
  # release of W is what stops the running, Shift or not.
  if ks >= XK_CapitalA and ks <= XK_CapitalZ:
    return input.KeyCode(ord(KeyA) + (ks.int - XK_CapitalA.int))
  if ks >= XK_0 and ks <= XK_9:
    return input.KeyCode(ord(Key0) + (ks.int - XK_0.int))
  if ks >= XK_F1 and ks <= XK_F12:
    return input.KeyCode(ord(KeyF1) + (ks.int - XK_F1.int))
  case ks.uint
  of XK_Return: KeyEnter
  of XK_space: KeySpace
  of XK_Escape: KeyEsc
  of XK_Tab, XK_ISO_Left_Tab: KeyTab
  of XK_BackSpace: KeyBackspace
  of XK_Delete: KeyDelete
  of XK_Insert: KeyInsert
  of XK_Left: KeyLeft
  of XK_Right: KeyRight
  of XK_Up: KeyUp
  of XK_Down: KeyDown
  of XK_Page_Up: KeyPageUp
  of XK_Page_Down: KeyPageDown
  of XK_Home: KeyHome
  of XK_End: KeyEnd
  of XK_Caps_Lock: KeyCapslock
  of 0xff67'u: KeyMenu                  # XK_Menu
  of XK_plus: KeyPlus
  of XK_comma: KeyComma
  of XK_period: KeyPeriod
  of XK_minus: KeyMinus
  of 0x2f'u, 0x3f'u: KeySlash
  of 0x5b'u, 0x7b'u: KeyLeftBracket
  of 0x5d'u, 0x7d'u: KeyRightBracket
  of 0x3b'u, 0x3a'u: KeySemicolon
  of 0x27'u, 0x22'u: KeyQuote
  of 0x5c'u, 0x7c'u: KeyBackslash
  of 0x60'u, 0x7e'u: KeyBackquote
  of XK_equal: KeyEqual
  else: KeyNone

proc translateMods(state: cuint): set[Modifier] =
  result = {}
  if (state and ShiftMask) != 0: result.incl ShiftPressed
  if (state and ControlMask) != 0: result.incl CtrlPressed
  if (state and Mod1Mask) != 0: result.incl AltPressed
  if (state and Mod4Mask) != 0: result.incl GuiPressed

proc modsAfter(state: cuint; ks: XKeySym; down: bool): set[Modifier] =
  ## X reports the modifiers as they were before the event; for a modifier
  ## key itself this is what they are after it.
  result = translateMods(state)
  let m = case int(ks)
          of 0xffe1, 0xffe2: ShiftPressed
          of 0xffe3, 0xffe4: CtrlPressed
          of 0xffe7, 0xffe8, 0xffe9, 0xffea: AltPressed
          of 0xffeb, 0xffec: GuiPressed
          else: return
  if down: result.incl m else: result.excl m

proc translateButton(button: cuint): MouseButton =
  case button
  of Button1: LeftButton
  of Button3: RightButton
  of Button2: MiddleButton
  of 8: BackButton
  of 9: ForwardButton
  else: LeftButton

# ---- Clipboard handling ----

proc handleSelectionRequest(req: XSelectionRequestEvent) =
  var ev {.noinit.}: XEvent
  zeroMem(addr ev, sizeof(XEvent))
  ev.xselection.theType = SelectionNotify
  ev.xselection.requestor = req.requestor
  ev.xselection.selection = req.selection
  ev.xselection.target = req.target
  ev.xselection.time = req.time

  if req.target == gUtf8String or req.target == XA_STRING:
    discard XChangeProperty(gDisplay, req.requestor, req.property,
      gUtf8String, 8, PropModeReplace,
      cast[pointer](cstr(gClipboardText)), gClipboardText.len.cint)
    ev.xselection.property = req.property
  elif req.target == gTargets:
    var targets = [gUtf8String, XA_STRING, gTargets]
    discard XChangeProperty(gDisplay, req.requestor, req.property,
      XA_ATOM, 32, PropModeReplace,
      addr targets[0], 3)
    ev.xselection.property = req.property
  else:
    ev.xselection.property = None

  discard XSendEvent(gDisplay, req.requestor, 0, 0, addr ev)

# ---- Event processing ----

var gRepeatsPaired = true
  ## Whether the server still sends a held key's auto-repeat as release/press
  ## pairs -- set once, by asking for XKB's detectable auto-repeat.

proc isAutoRepeatRelease(xev: XEvent): bool =
  ## A release that auto-repeat made up: the very next event is a press of
  ## the same key with the same timestamp. Only asked where the server could
  ## not be told to leave those out, and only of an event straight off the
  ## queue: an input method that wants releases takes them in through
  ## `XFilterEvent` and hands them back later, by which time the press that
  ## came with a made-up one is no longer next to it.
  if not gRepeatsPaired or XPending(gDisplay) == 0: return false
  var next {.noinit.}: XEvent
  discard XPeekEvent(gDisplay, addr next)
  result = next.xkey.theType == KeyPress and
           next.xkey.keycode == xev.xkey.keycode and
           next.xkey.time == xev.xkey.time

var lastClickTime: XTime
var lastClickX, lastClickY: int
var clickCount: int

# ---- Pen tablets (XInput 2) ----
#
# The mouse path is left as it is: clicks and motion still come as the core
# events above, from the master pointer, whatever moved it. What a pen adds
# -- pressure, lean, turn, its eraser end -- only XInput 2 carries, in the
# valuators of the tablet's own (slave) device. So the window asks for the
# XInput 2 motion and buttons of the tablet devices only; asking for a slave
# device's events does not take the core events away (those come from the
# master), and the server sends the slave's event first, then the master's
# core event made from it with the same timestamp. The newest pen state is
# kept, and a core event of that very time is the pen's.
#
# libXi is opened at run time, and only used if it is there: nothing new is
# needed to build or to start.

type
  XIEventMask {.pure.} = object
    deviceid: cint
    mask_len: cint
    mask: ptr uint8

  XIAnyClassInfo {.pure.} = object
    theType: cint
    sourceid: cint

  XIValuatorClassInfo {.pure.} = object
    theType: cint
    sourceid: cint
    number: cint
    label: Atom
    min, max, value: cdouble
    resolution: cint
    mode: cint

  XIDeviceInfo {.pure.} = object
    deviceid: cint
    name: cstring
    use: cint
    attachment: cint
    enabled: XBool
    num_classes: cint
    classes: ptr UncheckedArray[ptr XIAnyClassInfo]

  XIButtonState {.pure.} = object
    mask_len: cint
    mask: ptr uint8

  XIValuatorState {.pure.} = object
    mask_len: cint
    mask: ptr UncheckedArray[uint8]
    values: ptr UncheckedArray[float64]

  XIModifierState {.pure.} = object
    base, latched, locked, effective: cint

  XIDeviceEvent {.pure.} = object
    theType: cint
    serial: culong
    send_event: XBool
    display: pointer
    extension: cint
    evtype: cint
    time: XTime
    deviceid, sourceid, detail: cint
    root, event, child: XID
    root_x, root_y, event_x, event_y: cdouble
    flags: cint
    buttons: XIButtonState
    valuators: XIValuatorState
    mods: XIModifierState
    group: XIModifierState

  XDeviceInfoXI1 {.pure.} = object
    ## XInput 1's `XDeviceInfo`: what is left of a device's type ("ERASER").
    id: XID
    devType: Atom
    name: cstring
    num_classes: cint
    use: cint
    inputclassinfo: pointer

  XErrorHandler = proc (d: pointer; e: pointer): cint {.cdecl.}
  XIQueryDeviceProc = proc (d: pointer; id: cint;
                            n: ptr cint): ptr UncheckedArray[XIDeviceInfo] {.cdecl.}
  XIFreeProc = proc (p: pointer) {.cdecl.}
  XISelectEventsProc = proc (d: pointer; w: XID; masks: ptr XIEventMask; n: cint): cint {.cdecl.}
  XListInputDevicesProc = proc (d: pointer;
                                n: ptr cint): ptr UncheckedArray[XDeviceInfoXI1] {.cdecl.}
  XGetEventDataProc = proc (d: pointer; c: ptr XGenericEventCookie): XBool {.cdecl.}
  XFreeEventDataProc = proc (d: pointer; c: ptr XGenericEventCookie) {.cdecl.}

const
  XIAllDevices = 0.cint
  XISlavePointer = 3.cint
  XIValuatorClass = 2.cint
  XI_ButtonPress = 4.cint
  XI_ButtonRelease = 5.cint
  XI_Motion = 6.cint
  XI_HierarchyChanged = 11.cint

proc XQueryExtension(dpy: pointer; name: cstring;
                     major, firstEvent, firstError: ptr cint): XBool
  {.cdecl, dynlib: libX11, importc.}
proc XSync(dpy: pointer; discardEvents: XBool): cint
  {.cdecl, dynlib: libX11, importc.}
proc XSetErrorHandler(handler: XErrorHandler): XErrorHandler
  {.cdecl, dynlib: libX11, importc.}

var
  gXiOpcode: cint = 0   ## XInput's major opcode; 0: pens are not followed
  gXiQueryDevice: XIQueryDeviceProc
  gXiFreeDeviceInfo: XIFreeProc
  gXiSelectEvents: XISelectEventsProc
  gXListInputDevices: XListInputDevicesProc
  gXFreeDeviceList: XIFreeProc
  gXGetEventData: XGetEventDataProc
  gXFreeEventData: XFreeEventDataProc
  gTablets: seq[TabletDevice]
  gPenTablet = -1       ## the tablet the newest pen event came from
  gPenTime: XTime       ## ... and its time: the core event of that time is the pen's

proc ignoreXError(d: pointer; e: pointer): cint {.cdecl.} = 0

proc scanTablets() =
  ## Which input devices are pens (and which of those an eraser end), and
  ## asks for their XInput 2 events on the window. Again whenever devices
  ## come and go (xf86-input-libinput makes a pen's device the first time
  ## the pen comes near).
  gTablets.setLen(0)
  gPenTablet = -1
  var labels: array[PenAxisLabels.len, Atom]
  for i in 0 ..< PenAxisLabels.len:
    labels[i] = XInternAtom(gDisplay, cstring(PenAxisLabels[i]), 1)
  let eraserType = XInternAtom(gDisplay, "ERASER", 1)
  var n: cint = 0
  let infos = gXiQueryDevice(gDisplay, XIAllDevices, addr n)
  if infos != nil:
    for i in 0 ..< n.int:
      if infos[i].use != XISlavePointer or infos[i].name == nil: continue
      var t = newTabletDevice(infos[i].deviceid.int, $infos[i].name)
      for c in 0 ..< infos[i].num_classes.int:
        let cls = infos[i].classes[c]
        if cls == nil or cls.theType != XIValuatorClass: continue
        let v = cast[ptr XIValuatorClassInfo](cls)
        if v.label == None: continue
        for k in 0 ..< labels.len:
          if labels[k] != None and v.label == labels[k]:
            t.addValuator(PenAxisLabels[k], v.number.int, v.min, v.max, v.value)
      if t.isTablet:
        t.eraser = isEraserName(t.name)
        gTablets.add t
    gXiFreeDeviceInfo(infos)
  if gTablets.len > 0 and eraserType != None and gXListInputDevices != nil:
    # XInput 1 still knows a device's type: the Wacom driver's "ERASER".
    var m: cint = 0
    let list = gXListInputDevices(gDisplay, addr m)
    if list != nil:
      for i in 0 ..< m.int:
        if list[i].devType != eraserType: continue
        for t in gTablets.mitems:
          if XID(t.id) == list[i].id: t.eraser = true
      gXFreeDeviceList(list)
  # Devices coming and going, and the motion and buttons of each pen.
  var bits = newSeq[uint8](4 * (gTablets.len + 1))
  var masks = newSeq[XIEventMask](gTablets.len + 1)
  bits[XI_HierarchyChanged shr 3] = uint8(1 shl (XI_HierarchyChanged and 7))
  masks[0] = XIEventMask(deviceid: XIAllDevices, mask_len: 4, mask: addr bits[0])
  for i in 0 ..< gTablets.len:
    let o = 4 * (i + 1)
    for ev in [XI_ButtonPress, XI_ButtonRelease, XI_Motion]:
      bits[o + (ev shr 3)] = bits[o + (ev shr 3)] or uint8(1 shl (ev and 7))
    masks[i + 1] = XIEventMask(deviceid: gTablets[i].id.cint, mask_len: 4,
                               mask: addr bits[o])
  # A device that went away in the meantime is an X error, which by default
  # ends the program: not this one.
  discard XSync(gDisplay, 0)
  let previous = XSetErrorHandler(ignoreXError)
  discard gXiSelectEvents(gDisplay, gWindow, addr masks[0], masks.len.cint)
  discard XSync(gDisplay, 0)
  discard XSetErrorHandler(previous)

proc startPenInput() =
  ## Follows pen tablets when the X server and libXi can (XInput 2).
  let lib = loadLib("libXi.so.6")
  if lib == nil: return
  let x11 = loadLib("libX11.so.6")
  if x11 == nil: return
  type QueryVersion = proc (d: pointer; major, minor: ptr cint): XStatus {.cdecl.}
  let queryVersion = cast[QueryVersion](lib.symAddr("XIQueryVersion"))
  gXiQueryDevice = cast[XIQueryDeviceProc](lib.symAddr("XIQueryDevice"))
  gXiFreeDeviceInfo = cast[XIFreeProc](lib.symAddr("XIFreeDeviceInfo"))
  gXiSelectEvents = cast[XISelectEventsProc](lib.symAddr("XISelectEvents"))
  gXListInputDevices = cast[XListInputDevicesProc](lib.symAddr("XListInputDevices"))
  gXFreeDeviceList = cast[XIFreeProc](lib.symAddr("XFreeDeviceList"))
  gXGetEventData = cast[XGetEventDataProc](x11.symAddr("XGetEventData"))
  gXFreeEventData = cast[XFreeEventDataProc](x11.symAddr("XFreeEventData"))
  if queryVersion == nil or gXiQueryDevice == nil or gXiFreeDeviceInfo == nil or
     gXiSelectEvents == nil or gXGetEventData == nil or gXFreeEventData == nil or
     gXFreeDeviceList == nil:
    return
  var opcode, firstEvent, firstError: cint
  if XQueryExtension(gDisplay, "XInputExtension", addr opcode, addr firstEvent,
                     addr firstError) == 0:
    return
  var major: cint = 2
  var minor: cint = 0
  if queryVersion(gDisplay, addr major, addr minor) != 0 or major < 2: return
  # libXi stays open: it decodes the events from now on.
  gXiOpcode = opcode
  scanTablets()

proc processXiEvent(xev: var XEvent) =
  ## An XInput 2 event: a pen moved, touched or lifted (its state kept for
  ## the core event that follows), or devices came or went.
  if gXGetEventData(gDisplay, addr xev.xcookie) == 0: return
  let evtype = xev.xcookie.evtype
  if evtype == XI_Motion or evtype == XI_ButtonPress or evtype == XI_ButtonRelease:
    let d = cast[ptr XIDeviceEvent](xev.xcookie.data)
    for i in 0 ..< gTablets.len:
      if gTablets[i].id == d.deviceid.int:
        gTablets[i].updateValuators(d.valuators.mask, d.valuators.mask_len.int,
                                    d.valuators.values)
        gPenTablet = i
        gPenTime = d.time
        break
  gXFreeEventData(gDisplay, addr xev.xcookie)
  if evtype == XI_HierarchyChanged: scanTablets()

proc withPen(e: var input.Event; time: XTime) =
  ## A core pointer event that a pen made: how the pen is held.
  if gPenTablet >= 0 and gPenTablet < gTablets.len and time == gPenTime:
    penFromTablet(e, gTablets[gPenTablet])

# ---- The window's frame ----
#
# An app that draws its own title bar and borders asks the window manager for
# a window without decorations (`_MOTIF_WM_HINTS`, which every window manager
# reads). Moving and sizing it stay the window manager's: the app hands it the
# press it got on its title bar or an edge (`_NET_WM_MOVERESIZE`), and the
# window manager drags the window from there -- snapping, edge tiling and all
# -- as from a frame of its own. Maximizing is `_NET_WM_STATE`, the same
# request a panel's button sends, so the panels stay in view.

proc atomsOf(w: XID; prop: Atom): seq[Atom] =
  ## The atoms in a window's property of type ATOM (`_NET_WM_STATE`...).
  var actualType: Atom
  var actualFormat: cint
  var n, after: culong
  var data: pointer
  if XGetWindowProperty(gDisplay, w, prop, 0, 1024, 0, XA_ATOM,
                        addr actualType, addr actualFormat, addr n, addr after,
                        addr data) == 0 and data != nil:
    # (format 32 comes as C longs)
    let items = cast[ptr UncheckedArray[clong]](data)
    if actualFormat == 32:
      for i in 0 ..< n.int: result.add Atom(items[i])
    discard XFree(data)

proc readMaximized(): bool =
  if gDisplay == nil or gWindow == None or gNetWmState == 0: return false
  let st = atomsOf(gWindow, gNetWmState)
  XInternAtom(gDisplay, "_NET_WM_STATE_MAXIMIZED_HORZ", 0) in st and
    XInternAtom(gDisplay, "_NET_WM_STATE_MAXIMIZED_VERT", 0) in st

proc sendWmState(add: bool; a, b: Atom) =
  ## Ask the window manager to add or remove states (the EWMH message, to
  ## the root window; only once the window is mapped).
  var ev = XEvent()
  ev.xclient.theType = ClientMessage
  ev.xclient.window = gWindow
  ev.xclient.message_type = XInternAtom(gDisplay, "_NET_WM_STATE", 0)
  ev.xclient.format = 32
  ev.xclient.data[0] = (if add: 1 else: 0)    # _NET_WM_STATE_ADD / _REMOVE
  ev.xclient.data[1] = a.clong
  ev.xclient.data[2] = b.clong
  ev.xclient.data[3] = 1  # a normal application, per the spec's source field
  discard XSendEvent(gDisplay, XRootWindow(gDisplay, gScreen), 0,
                     (SubstructureNotifyMask or SubstructureRedirectMask).clong,
                     addr ev)
  discard XFlush(gDisplay)

proc putFrameHints() =
  ## `_MOTIF_WM_HINTS`: no decorations, or (deleted) what the window manager
  ## gives any window.
  let hints = XInternAtom(gDisplay, "_MOTIF_WM_HINTS", 0)
  if hints == 0: return
  if gSystemFrame:
    discard XDeleteProperty(gDisplay, gWindow, hints)
  else:
    # flags, functions, decorations, input mode, status: the decorations
    # (MWM_HINTS_DECORATIONS) are none
    var v = [clong(2), 0, 0, 0, 0]
    discard XChangeProperty(gDisplay, gWindow, hints, hints, 32,
                            PropModeReplace, addr v[0], 5)

# ---- Files dropped from a file manager (XDND) ----
#
# The window says it takes drops (`XdndAware`, version 5). A file manager
# dragging over it sends XdndEnter (what it offers), XdndPosition (where;
# answered with XdndStatus: taken as a copy when it offers `text/uri-list`)
# and XdndDrop; the list is then asked for (XdndSelection converted to
# `text/uri-list`), its files become a FileDropEvent, and XdndFinished
# tells the file manager it is done.

type XdndState = object
  source: XID          # the window dragging over this one (None: no drag)
  version: int
  uriList: bool        # it offers text/uri-list
  x, y: int            # where it is, in the window
  dropping: bool       # dropped: the list is being asked for

type XdndAtom = enum
  xaAware, xaEnter, xaPosition, xaStatus, xaLeave, xaDrop, xaFinished,
  xaSelection, xaActionCopy, xaTypeList, xaUriList, xaProperty,
  xaActionMove, xaActionList, xaProxy, xaDelete, xaNull

var
  gXdnd: XdndState
  gXdndAtoms: array[XdndAtom, Atom]   # (interned when the window is made)

proc xa(a: XdndAtom): Atom {.inline.} = gXdndAtoms[a]

proc internXdnd() =
  const names = [cstring"XdndAware", "XdndEnter", "XdndPosition", "XdndStatus",
                 "XdndLeave", "XdndDrop", "XdndFinished", "XdndSelection",
                 "XdndActionCopy", "XdndTypeList", "text/uri-list",
                 "UIRELAYS_DROP", "XdndActionMove", "XdndActionList",
                 "XdndProxy", "DELETE", "NULL"]
  for a in XdndAtom: gXdndAtoms[a] = XInternAtom(gDisplay, names[ord(a)], 0)
  # (version 5 of the protocol)
  var version = clong(5)
  discard XChangeProperty(gDisplay, gWindow, xa(xaAware), XA_ATOM, 32,
                          PropModeReplace, addr version, 1)

proc xdndSend(to: XID; kind: Atom; d1, d2, d3, d4: clong; via = None) =
  ## An XDND message about window `to`, sent to it -- or to `via`, its
  ## proxy.
  var ev = XEvent()
  ev.xclient.theType = ClientMessage
  ev.xclient.window = to
  ev.xclient.message_type = kind
  ev.xclient.format = 32
  ev.xclient.data = [gWindow.clong, d1, d2, d3, d4]
  discard XSendEvent(gDisplay, if via != None: via else: to, 0, 0, addr ev)
  discard XFlush(gDisplay)

proc xdndFinish(accepted: bool) =
  if gXdnd.source != None:
    xdndSend(gXdnd.source, xa(xaFinished), (if accepted: 1 else: 0),
             (if accepted: xa(xaActionCopy).clong else: 0), 0, 0)
  gXdnd = XdndState()

proc xdndMessage(m: XClientMessageEvent) =
  let kind = m.message_type
  let source = XID(m.data[0])
  if kind == xa(xaEnter):
    gXdnd = XdndState(source: source, version: int((m.data[1] shr 24) and 0xFF))
    var offered: seq[Atom]
    if (m.data[1] and 1) != 0:
      offered = atomsOf(source, xa(xaTypeList))      # (more than three)
    else:
      for i in 2 .. 4:
        if m.data[i] != 0: offered.add Atom(m.data[i])
    gXdnd.uriList = xa(xaUriList) in offered
  elif kind == xa(xaPosition):
    if gXdnd.source == None: gXdnd.source = source
    var wx, wy: cint
    var child: XID
    discard XTranslateCoordinates(gDisplay, XRootWindow(gDisplay, gScreen), gWindow,
      cint((m.data[2] shr 16) and 0xFFFF), cint(m.data[2] and 0xFFFF),
      addr wx, addr wy, addr child)
    gXdnd.x = wx.int
    gXdnd.y = wy.int
    # taken (as a copy) anywhere in the window when it offers files
    xdndSend(source, xa(xaStatus), (if gXdnd.uriList: 1 else: 0), 0, 0,
             (if gXdnd.uriList: xa(xaActionCopy).clong else: 0))
  elif kind == xa(xaLeave):
    gXdnd = XdndState()
  elif kind == xa(xaDrop):
    if gXdnd.source == None: gXdnd.source = source
    if gXdnd.uriList:
      gXdnd.dropping = true
      discard XConvertSelection(gDisplay, xa(xaSelection), xa(xaUriList),
        xa(xaProperty), gWindow, (if gXdnd.version >= 1: XTime(m.data[2]) else: CurrentTime))
      discard XFlush(gDisplay)
    else:
      xdndFinish(false)

proc xdndReceive(sel: XSelectionEvent) =
  ## (the dropped list has come: its files as an event)
  var files: seq[string]
  if sel.property != None:
    var actualType: Atom
    var actualFormat: cint
    var n, after: culong
    var data: pointer
    if XGetWindowProperty(gDisplay, gWindow, xa(xaProperty), 0, 1 shl 22, 1, 0,
                          addr actualType, addr actualFormat, addr n, addr after,
                          addr data) == 0 and data != nil:
      if actualFormat == 8:
        var text = newString(n.int)
        if n > 0: copyMem(addr text[0], data, n.int)
        files = filesOfUriList(text)
      discard XFree(data)
  if files.len > 0:
    var root, child: XID
    var rx, ry, wx, wy: cint
    var mask: cuint
    discard XQueryPointer(gDisplay, gWindow, addr root, addr child,
                          addr rx, addr ry, addr wx, addr wy, addr mask)
    pushEvent(input.Event(kind: FileDropEvent, x: gXdnd.x, y: gXdnd.y, files: files,
                          hasMods: true, mods: translateMods(mask)))
  xdndFinish(files.len > 0)

# ---- Files dragged out of the window (XDND, as the source) ----
#
# `dragOut` runs the drag here until the button is let go. The files are
# offered as `text/uri-list` on XdndSelection, and the pointer is grabbed: as
# it moves, the window under it that takes drops (`XdndAware`, or its
# `XdndProxy`) gets XdndEnter, then an XdndPosition at each move -- the next
# only once XdndStatus answered the last: does it take them, as a copy or a
# move -- and XdndLeave when the pointer leaves it. Let go over one that takes
# them, it gets XdndDrop, asks for the list (and for DELETE after a move:
# nothing is deleted here, the file manager moved them) and says
# XdndFinished, waited for a few seconds at most. This window is no target
# of its own drags.

type XdndOut = object
  list: string         # the files, as text/uri-list
  target: XID          # the window under the pointer that takes drops (None: none)
  proxy: XID           # ... where its messages go (None: to it)
  version: int         # ... the protocol's version both speak
  accepted: bool       # ... its last XdndStatus: it takes them
  action: Atom         # ... with this action
  waiting: bool        # an XdndPosition went, its XdndStatus has not come
  waitSince: int
  moved: bool          # ... and the pointer moved meanwhile
  x, y: int            # the pointer, on the screen
  time: XTime          # ... the time it was there
  wanted: Atom         # the action asked for (copy, or move)
  sent: bool           # the list was handed over
  deleted: bool        # ... and DELETE asked for: a move

var
  gOut: XdndOut
  gOutGrab = false     # the pointer is held for the button's release (Esc, back
                       # over the window: the drag ended with the button down)

proc answerDragList(req: XSelectionRequestEvent) =
  ## A program asks for the files of the drag: as text/uri-list, the
  ## targets there are, or DELETE (it moved them).
  var ev = XEvent()
  ev.xselection.theType = SelectionNotify
  ev.xselection.requestor = req.requestor
  ev.xselection.selection = req.selection
  ev.xselection.target = req.target
  ev.xselection.time = req.time
  # (a requestor of ICCCM's first days names no property: the target's name)
  let prop = if req.property != None: req.property else: req.target
  ev.xselection.property = prop
  if req.target == xa(xaUriList) and gOut.list.len > 0:
    discard XChangeProperty(gDisplay, req.requestor, prop, xa(xaUriList), 8,
                            PropModeReplace, addr gOut.list[0], gOut.list.len.cint)
    gOut.sent = true
  elif req.target == gTargets:
    var targets = [gTargets, xa(xaUriList)]
    discard XChangeProperty(gDisplay, req.requestor, prop, XA_ATOM, 32,
                            PropModeReplace, addr targets[0], targets.len.cint)
  elif req.target == xa(xaDelete):
    # (done: a property of type NULL, as ICCCM has it)
    discard XChangeProperty(gDisplay, req.requestor, prop, xa(xaNull), 32,
                            PropModeReplace, nil, 0)
    gOut.deleted = true
  else:
    ev.xselection.property = None
  discard XSendEvent(gDisplay, req.requestor, 0, 0, addr ev)
  discard XFlush(gDisplay)

proc processXEvent(xev: XEvent) =
  case xev.theType
  of Expose:
    if xev.xexpose.count == 0 and gGpu:
      # Drawn with OpenGL: the app draws the window again.
      pushEvent(input.Event(kind: AppResumeEvent))
    elif xev.xexpose.count == 0 and gBackPixmap != None:
      discard XCopyArea(gDisplay, gBackPixmap, gWindow, gGC,
        0, 0, gWidth.cuint, gHeight.cuint, 0, 0)
      # This copy was of a pixmap the frame in progress is halfway through
      # drawing -- an app asks for events in the middle of a frame, and the
      # background it cleared to is all that is on the pixmap by then. So the
      # window is not showing any frame now, and the next `x11Refresh` has to
      # copy however little the frame it finishes turns out to have changed.
      gFrameForced = true

  of ConfigureNotify:
    let newW = xev.xconfigure.width
    let newH = xev.xconfigure.height
    if newW > 0 and newH > 0 and (newW != gWidth or newH != gHeight):
      gWidth = newW
      gHeight = newH
      recreateBackBuffer()
      var e = input.Event(kind: WindowMetricsEvent)
      e.x = gWidth
      e.y = gHeight
      e.scaleX = 1
      e.scaleY = 1
      e.uiScale = gUiScale
      pushEvent(e)

  of ClientMessage:
    let kind = xev.xclient.message_type
    if kind != 0 and kind in [xa(xaEnter), xa(xaPosition), xa(xaLeave), xa(xaDrop)]:
      xdndMessage(xev.xclient)
    elif xev.xclient.data[0] == gWmDeleteWindow.clong:
      pushEvent(input.Event(kind: WindowCloseEvent))

  of SelectionNotify:
    # (a drop's list of files; the clipboard's is waited for where it is asked)
    if gXdnd.dropping and xev.xselection.selection == xa(xaSelection):
      xdndReceive(xev.xselection)

  of FocusIn:
    # (a grab's -- the window manager moving the window -- is no change)
    if xev.xfocus.mode notin [NotifyGrab, NotifyUngrab]:
      if gXic != nil: XSetICFocus(gXic)
      gFocused = true
      pushEvent(input.Event(kind: WindowFocusGainedEvent))

  of FocusOut:
    if xev.xfocus.mode notin [NotifyGrab, NotifyUngrab]:
      if gXic != nil: XUnsetICFocus(gXic)
      gFocused = false
      pushEvent(input.Event(kind: WindowFocusLostEvent))

  of PropertyNotify:
    # maximized or restored (by the app, a key, a double click in a panel):
    # the app lays its frame out again
    if xev.xproperty.atom == gNetWmState and gNetWmState != 0:
      let m = readMaximized()
      if m != gMaximized:
        gMaximized = m
        pushEvent(input.Event(kind: WindowResizeEvent, x: gWidth.int, y: gHeight.int))

  of KeyPress:
    # The text a key types is UTF-8 from the input method, which is also what
    # composes dead keys and runs an IME. `XLookupString` is only the fallback
    # for a display without one: it speaks ISO 8859-1, so its byte for an 'ä'
    # is re-encoded here -- passed on as it is, it is not UTF-8.
    var buf {.noinit.}: array[64, char]
    var ks: XKeySym = 0
    var text = ""
    var hasKey = true
    if gXic != nil:
      var status: cint = 0
      var n = Xutf8LookupString(gXic, unsafeAddr xev.xkey,
        cast[cstring](addr buf[0]), buf.len.cint, addr ks, addr status)
      if status == XBufferOverflow:
        text = newString(n)
        n = Xutf8LookupString(gXic, unsafeAddr xev.xkey, cstr(text),
          n.cint, addr ks, addr status)
        text.setLen(max(n, 0))
      elif status == XLookupChars or status == XLookupBoth:
        for i in 0 ..< n: text.add buf[i]
      # Text an IME commits arrives without a key to go with it.
      hasKey = status == XLookupKeySymVal or status == XLookupBoth
    else:
      let n = XLookupString(unsafeAddr xev.xkey, cast[cstring](addr buf[0]),
        buf.len.cint, addr ks, nil)
      for i in 0 ..< n:
        let b = buf[i].uint8
        if b < 0x80:
          text.add buf[i]
        else:
          text.add char(0xC0'u8 or (b shr 6))
          text.add char(0x80'u8 or (b and 0x3F))
    if hasKey:
      var e = input.Event(kind: KeyDownEvent, hasMods: true)
      e.key = translateKeySym(ks)
      e.mods = modsAfter(xev.xkey.state, ks, true)
      pushEvent(e)
    # Text input (if printable), one event per codepoint
    if text.len > 0 and text[0].uint8 >= 32 and text[0].uint8 != 127:
      var i = 0
      while i < text.len:
        var te = input.Event(kind: TextInputEvent)
        var k = 0
        while true:
          if k < te.text.len: te.text[k] = text[i]
          inc k
          inc i
          if i >= text.len or (text[i].uint8 and 0xC0) != 0x80: break
        pushEvent(te)

  of KeyRelease:
    var ks {.noinit.}: XKeySym
    discard XLookupString(unsafeAddr xev.xkey, nil, 0, addr ks, nil)
    var e = input.Event(kind: KeyUpEvent, hasMods: true)
    e.key = translateKeySym(ks)
    e.mods = modsAfter(xev.xkey.state, ks, false)
    pushEvent(e)

  of ButtonPress:
    let btn = xev.xbutton.button
    if btn == Button4 or btn == Button5:
      # Scroll wheel
      var e = input.Event(kind: MouseWheelEvent, hasMods: true)
      e.y = if btn == Button4: 1 else: -1
      e.mods = translateMods(xev.xbutton.state)
      pushEvent(e)
    else:
      var e = input.Event(kind: MouseDownEvent, hasMods: true)
      e.x = xev.xbutton.x
      e.y = xev.xbutton.y
      e.button = translateButton(btn)
      e.mods = translateMods(xev.xbutton.state)
      # Click counting for double/triple click
      let now = xev.xbutton.time
      if now - lastClickTime < 500 and
         abs(e.x - lastClickX) < 4 and abs(e.y - lastClickY) < 4:
        inc clickCount
      else:
        clickCount = 1
      lastClickTime = now
      lastClickX = e.x
      lastClickY = e.y
      e.clicks = clickCount
      withPen(e, now)
      pushEvent(e)

  of ButtonRelease:
    let btn = xev.xbutton.button
    if gOutGrab and btn == Button1:
      # (the release a drag of files out ended without: the pointer is free)
      gOutGrab = false
      discard XUngrabPointer(gDisplay, CurrentTime)
    if btn != Button4 and btn != Button5:
      var e = input.Event(kind: MouseUpEvent, hasMods: true)
      e.x = xev.xbutton.x
      e.y = xev.xbutton.y
      e.button = translateButton(btn)
      e.mods = translateMods(xev.xbutton.state)
      withPen(e, xev.xbutton.time)
      pushEvent(e)

  of MotionNotify:
    var e = input.Event(kind: MouseMoveEvent, hasMods: true)
    e.x = xev.xmotion.x
    e.y = xev.xmotion.y
    e.mods = translateMods(xev.xmotion.state)
    withPen(e, xev.xmotion.time)
    pushEvent(e)

  of SelectionRequest:
    if xev.xselectionrequest.selection == xa(xaSelection):
      answerDragList(xev.xselectionrequest)     # (a drag of files out's)
    else:
      handleSelectionRequest(xev.xselectionrequest)

  else:
    discard

proc dispatchXEvent(xev: var XEvent) =
  ## One event just taken off the queue: a release that auto-repeat made up
  ## goes nowhere, the input method gets the first look at the rest, and
  ## what it leaves is ours.
  if xev.xkey.theType == KeyRelease and isAutoRepeatRelease(xev): return
  if xev.theType == GenericEvent:
    if gXiOpcode != 0 and xev.xcookie.extension == gXiOpcode: processXiEvent(xev)
    return
  if XFilterEvent(addr xev, None) == 0:
    processXEvent(xev)

proc drainXEvents() =
  while XPending(gDisplay) > 0:
    var xev {.noinit.}: XEvent
    discard XNextEvent(gDisplay, addr xev)
    dispatchXEvent(xev)

# ---- Display density ----

proc matchesAt(s: string; i: int; prefix: string): bool =
  if i + prefix.len > s.len: return false
  for k in 0 ..< prefix.len:
    if s[i + k] != prefix[k]: return false
  result = true

proc dpiFromResources(): int =
  ## `Xft.dpi` from the root window's resource manager string, 0 if unset.
  ## The server's own idea of the physical size is no use here -- Xwayland
  ## reports a flat 96 dpi no matter the monitor -- so this resource, which is
  ## what the desktop environment writes, is the only honest source.
  result = 0
  let rm = XResourceManagerString(gDisplay)
  if rm == nil: return
  let db = $rm
  const key = "Xft.dpi:"
  var i = 0
  while i < db.len:
    var lineEnd = i
    while lineEnd < db.len and db[lineEnd] != '\n': inc lineEnd
    if db.matchesAt(i, key):
      var j = i + key.len
      while j < lineEnd and (db[j] == ' ' or db[j] == '\t'): inc j
      var dpi = 0
      while j < lineEnd and db[j] in {'0'..'9'}:
        dpi = dpi * 10 + (ord(db[j]) - ord('0'))
        inc j
      if dpi > 0: return dpi
    i = lineEnd + 1

# ---- the monitor's real size (XRandR), when no desktop said how to scale ----
#
# libXrandr is opened when needed and only if it is there: a missing library
# must not keep the app from starting.

type
  XRRScreenResources = object
    timestamp, configTimestamp: culong
    ncrtc: cint
    crtcs: ptr UncheckedArray[culong]
    noutput: cint
    outputs: ptr UncheckedArray[culong]
    nmode: cint
    modes: pointer
  XRROutputInfo = object
    timestamp: culong
    crtc: culong
    name: cstring
    nameLen: cint
    mmWidth, mmHeight: culong
    connection, subpixelOrder: cushort
  XRRCrtcInfo = object
    timestamp: culong
    x, y: cint
    width, height: cuint

proc dpiFromMonitor(): int =
  ## Pixels per inch of the main monitor from the size it reports (EDID),
  ## 0 when that cannot be had or makes no sense (projectors say 0 mm).
  let lib = loadLib("libXrandr.so.2")
  if lib == nil: return 0
  defer: unloadLib(lib)
  type
    GetRes = proc (d: pointer; w: XID): ptr XRRScreenResources {.cdecl.}
    GetPrimary = proc (d: pointer; w: XID): culong {.cdecl.}
    GetOutput = proc (d: pointer; r: ptr XRRScreenResources; o: culong): ptr XRROutputInfo {.cdecl.}
    GetCrtc = proc (d: pointer; r: ptr XRRScreenResources; c: culong): ptr XRRCrtcInfo {.cdecl.}
    Free = proc (p: pointer) {.cdecl.}
  let getRes = cast[GetRes](lib.symAddr("XRRGetScreenResourcesCurrent"))
  let getPrimary = cast[GetPrimary](lib.symAddr("XRRGetOutputPrimary"))
  let getOutput = cast[GetOutput](lib.symAddr("XRRGetOutputInfo"))
  let getCrtc = cast[GetCrtc](lib.symAddr("XRRGetCrtcInfo"))
  let freeRes = cast[Free](lib.symAddr("XRRFreeScreenResources"))
  let freeOut = cast[Free](lib.symAddr("XRRFreeOutputInfo"))
  let freeCrtc = cast[Free](lib.symAddr("XRRFreeCrtcInfo"))
  if getRes == nil or getOutput == nil or getCrtc == nil or freeRes == nil or
     freeOut == nil or freeCrtc == nil: return 0
  let root = XRootWindow(gDisplay, gScreen)
  let res = getRes(gDisplay, root)
  if res == nil: return 0
  defer: freeRes(res)
  let primary = if getPrimary != nil: getPrimary(gDisplay, root) else: 0
  for pass in 0 .. 1:
    for i in 0 ..< res.noutput:
      let o = res.outputs[i]
      if pass == 0 and o != primary: continue
      let info = getOutput(gDisplay, res, o)
      if info == nil: continue
      if info.connection == 0 and info.crtc != 0 and info.mmWidth >= 100:
        let crtc = getCrtc(gDisplay, res, info.crtc)
        if crtc != nil:
          let dpi = int(float(crtc.width) * 25.4 / float(info.mmWidth))
          freeCrtc(crtc)
          freeOut(info)
          if dpi in 60 .. 600: return dpi
          continue
      freeOut(info)

proc computeUiScale(): int =
  ## X11 coordinates are raw device pixels and nothing on the way to the screen
  ## scales them, so the display's full density has to land in `uiScale`.
  ## In order: what the desktop set (`Xft.dpi`, GDK_SCALE, QT_SCALE_FACTOR),
  ## else the monitor's own size (a 4K screen is not left at 100%), in steps
  ## of 25%. Never below 100: shrinking an app's hardcoded sizes is more
  ## likely to make it unusable than to be what the user meant.
  let dpi = dpiFromResources()
  if dpi > 0: return max(100, dpi * 100 div 96)
  let gdk = getEnv("GDK_SCALE")
  if gdk.len > 0:
    try: return clamp(parseInt(gdk) * 100, 100, 400) except ValueError: discard
  let qt = getEnv("QT_SCALE_FACTOR")
  if qt.len > 0:
    try: return clamp(int(parseFloat(qt) * 100), 100, 400) except ValueError: discard
  let mon = dpiFromMonitor()
  if mon > 0:
    # 25% steps; a little over (a 110 dpi laptop) stays at 100%
    return clamp(((mon * 100 div 96) + 8) div 25 * 25, 100, 400)
  100

# ---- Screen hook implementations ----

# ---- Startup notification ----
#
# A desktop that launches an application from a `.desktop` entry shows launch
# feedback while it comes up: the busy pointer, a bouncing icon, a greyed
# placeholder in the taskbar. It stops when the application says it is up --
# and an application that never says so is fed back until the window manager
# gives up on waiting for it, which is fifteen seconds under mutter and more
# elsewhere. The window is on screen for all but the first of those seconds,
# which is what makes it look like the desktop is stuck rather than the app.
#
# Saying so is `_NET_STARTUP_INFO`: the launcher puts an id in the
# environment, the window carries it as `_NET_STARTUP_ID` so the window
# manager can tell which launch this window is the answer to, and a `remove:`
# message on the root window ends the sequence for the desktops that watch
# for it instead. The id is taken back out of the environment on the way
# past, because it names this one launch: a program started from inside this
# one -- everything a built-in terminal ever runs -- would otherwise inherit
# it and end somebody else's launch feedback with a window of its own.

proc snQuote(s: string): string =
  ## `_NET_STARTUP_INFO` fields are separated by spaces, so a value holding
  ## one -- or a quote, or a backslash -- is quoted and escaped.
  var special = false
  for c in s:
    if c == ' ' or c == '"' or c == '\\': special = true
  if not special: return s
  result = "\""
  for c in s:
    if c == '"' or c == '\\': result.add '\\'
    result.add c
  result.add '"'

proc sendStartupInfo(msg: string) =
  let beginAtom = XInternAtom(gDisplay, "_NET_STARTUP_INFO_BEGIN", 0)
  let moreAtom = XInternAtom(gDisplay, "_NET_STARTUP_INFO", 0)
  if beginAtom == 0 or moreAtom == 0: return
  let root = XRootWindow(gDisplay, gScreen)
  var ev = XEvent()
  ev.xclient.theType = ClientMessage
  ev.xclient.window = gWindow
  ev.xclient.format = 8
  ev.xclient.message_type = beginAtom
  # Twenty bytes to a message, the terminating NUL among them -- so a message
  # whose length is a multiple of twenty still gets the chunk that ends it.
  var i = 0
  while true:
    let bytes = cast[ptr UncheckedArray[char]](addr ev.xclient.data[0])
    for k in 0 ..< 20:
      let j = i + k
      bytes[k] = if j < msg.len: msg[j] else: '\0'
    discard XSendEvent(gDisplay, root, 0, PropertyChangeMask.clong, addr ev)
    ev.xclient.message_type = moreAtom
    i += 20
    if i > msg.len: break
  discard XFlush(gDisplay)

proc openInputMethod() =
  ## The input method the environment asks for (`XMODIFIERS`, an IBus or
  ## Fcitx say), else the one built into Xlib, which does dead keys and
  ## Compose. Either hands out UTF-8. The locale's character type is what
  ## picks the Compose table, so it is taken from the environment first.
  discard c_setlocale(LC_CTYPE, "")
  discard XSetLocaleModifiers("")
  gXim = XOpenIM(gDisplay, nil, nil, nil)
  if gXim == nil:
    discard XSetLocaleModifiers("@im=none")
    gXim = XOpenIM(gDisplay, nil, nil, nil)
  if gXim == nil: return
  gXic = XCreateIC(gXim,
    cstring"inputStyle", cast[pointer](XIMPreeditNothing or XIMStatusNothing),
    cstring"clientWindow", cast[pointer](gWindow),
    cstring"focusWindow", cast[pointer](gWindow),
    nil)
  if gXic == nil:
    discard XCloseIM(gXim)
    gXim = nil

proc x11CreateWindow(layout: var ScreenLayout; icon: pointer; iconLen: int) =
  # Fonts opened before the window already have the connection.
  if gDisplay == nil: gDisplay = XOpenDisplay(nil)
  if gDisplay == nil:
    quit("Cannot open X11 display")
  gUiScale = computeUiScale()
  gScreen = XDefaultScreen(gDisplay)
  gVisual = XDefaultVisual(gDisplay, gScreen)
  gColormap = XDefaultColormap(gDisplay, gScreen)
  gDepth = XDefaultDepth(gDisplay, gScreen)

  if layout.fullScreen:
    layout.width = XDisplayWidth(gDisplay, gScreen)
    layout.height = XDisplayHeight(gDisplay, gScreen)

  # A negative dimension is MaxWindowWidth/MaxWindowHeight. The window is
  # created at the display size and then asked to maximize below: the window
  # manager is the one that knows where its panels are, and it answers with a
  # ConfigureNotify carrying the size that was actually granted.
  let maximized = layout.width < 0 or layout.height < 0
  if layout.width < 0: layout.width = XDisplayWidth(gDisplay, gScreen)
  if layout.height < 0: layout.height = XDisplayHeight(gDisplay, gScreen)

  gWindow = XCreateSimpleWindow(gDisplay, XRootWindow(gDisplay, gScreen),
    0, 0, layout.width.cuint, layout.height.cuint, 0,
    XBlackPixel(gDisplay, gScreen), XBlackPixel(gDisplay, gScreen))

  openInputMethod()
  # Key releases are reported, as every other backend reports them: a game
  # moves for as long as a key is *held*, and only the release says when that
  # ends. What they must not be is one release per auto-repeat. Plain X11
  # repeats a held key as release/press pairs, and a host that repaints per
  # event would pay a frame for every one of them -- the one place where the
  # keyboard produces events faster than a person types. XKB's "detectable
  # auto-repeat" makes the server send the presses alone, so a `KeyUpEvent`
  # means a finger came off the key. A server without XKB gets the pairs, and
  # `isAutoRepeatRelease` takes them apart on this side instead.
  #
  # An input method may ask for events of its own (IBus wants the releases
  # too); it takes what it asked for out again in `XFilterEvent`, before any
  # of it becomes an event here.
  var imEvents: clong = 0
  if gXic != nil:
    discard XGetICValues(gXic, cstring"filterEvents", addr imEvents, nil)
  discard XSelectInput(gDisplay, gWindow,
    (ExposureMask or KeyPressMask or KeyReleaseMask or
     ButtonPressMask or ButtonReleaseMask or PointerMotionMask or
     StructureNotifyMask or FocusChangeMask or PropertyChangeMask).clong or
    imEvents)
  var detectable: XBool = 0
  discard XkbSetDetectableAutoRepeat(gDisplay, 1, addr detectable)
  gRepeatsPaired = detectable == 0
  # A pen tablet's pressure and lean, when there is one (see "Pen tablets").
  startPenInput()

  # Register WM_DELETE_WINDOW
  gWmDeleteWindow = XInternAtom(gDisplay, "WM_DELETE_WINDOW", 0)
  discard XSetWMProtocols(gDisplay, gWindow, addr gWmDeleteWindow, 1)

  # Clipboard atoms
  gClipboard = XInternAtom(gDisplay, "CLIPBOARD", 0)
  gUtf8String = XInternAtom(gDisplay, "UTF8_STRING", 0)
  gTargets = XInternAtom(gDisplay, "TARGETS", 0)
  gClipProperty = XInternAtom(gDisplay, "NIMEDIT_CLIP", 0)

  # Files dropped from a file manager (see "XDND")
  internXdnd()

  # See "Startup notification" above. Both names are cleared: X11 launches
  # set the first, Wayland ones the second, and this window is the answer to
  # whichever it was.
  var startupId = ""
  let rawId = c_getenv("DESKTOP_STARTUP_ID")
  if rawId != nil: startupId = $rawId
  discard c_unsetenv("DESKTOP_STARTUP_ID")
  discard c_unsetenv("XDG_ACTIVATION_TOKEN")

  # WM_CLASS: who this window belongs to, which is what groups the windows of
  # one application in a taskbar and what a `.desktop` file's StartupWMClass
  # has to match. It is the name of the executable -- the convention every X11
  # toolkit follows, and the one thing about the window that cannot change
  # while it runs, unlike its title. Nothing configures it: the file that is
  # running is a fact of the running program, so an installed entry that names
  # it cannot be pointing at the wrong thing.
  # Set before mapping: ICCCM has the window manager read it at that point.
  var instName = getAppFilename().extractFilename.changeFileExt("")
  var className = instName
  if className.len > 0: className[0] = className[0].toUpperAscii
  var classHint = XClassHint(res_name: cstr(instName),
                             res_class: cstr(className))
  discard XSetClassHint(gDisplay, gWindow, addr classHint)

  # `_NET_WM_ICON`: the taskbar bitmap, for a window whose application has no
  # installed entry to look one up in. Also before the map, so the window
  # manager has it the first time it draws the window rather than a frame or
  # two later. Xlib's format-32 `XChangeProperty` wants an array of `clong`
  # (8 bytes each on LP64) with the value in the low 32 bits, so the packed
  # `uint32` payload is expanded on the way in.
  if icon != nil and iconLen > 0:
    let iconAtom = XInternAtom(gDisplay, "_NET_WM_ICON", 0)
    if iconAtom != 0:
      let src = cast[ptr UncheckedArray[uint32]](icon)
      var longs = newSeq[clong](iconLen)
      for i in 0 ..< iconLen:
        longs[i] = clong(src[i])
      discard XChangeProperty(gDisplay, gWindow, iconAtom, XA_CARDINAL, 32,
                              PropModeReplace, addr longs[0], iconLen.cint)

  # Before the map, like `WM_CLASS` and for the same reason: this is what the
  # window manager reads the window's identity out of when it takes it over.
  if startupId.len > 0:
    let startupAtom = XInternAtom(gDisplay, "_NET_STARTUP_ID", 0)
    if startupAtom != 0:
      discard XChangeProperty(gDisplay, gWindow, startupAtom, gUtf8String, 8,
                              PropModeReplace,
                              cast[pointer](cstr(startupId)),
                              startupId.len.cint)

  # Without the window manager's frame (the app draws its own): said before
  # the map, so the window never shows with one.
  gNetWmState = XInternAtom(gDisplay, "_NET_WM_STATE", 0)
  if not gSystemFrame: putFrameHints()

  discard XStoreName(gDisplay, gWindow, instName.cstr)
  discard XMapWindow(gDisplay, gWindow)

  if maximized:
    # _NET_WM_STATE_MAXIMIZED_{HORZ,VERT} is what a panel's maximize button
    # sends, so the window manager keeps its panels and docks visible --
    # unlike the _NET_WM_STATE_FULLSCREEN that `layout.fullScreen` asks for.
    # The message goes to the root window, as the EWMH spec requires, and only
    # after XMapWindow: a window manager ignores state changes for a window it
    # has not taken over yet.
    let maxHorz = XInternAtom(gDisplay, "_NET_WM_STATE_MAXIMIZED_HORZ", 0)
    let maxVert = XInternAtom(gDisplay, "_NET_WM_STATE_MAXIMIZED_VERT", 0)
    if gNetWmState != 0 and maxHorz != 0 and maxVert != 0:
      sendWmState(true, maxHorz, maxVert)

  # The window is up, so the launch is over. After the map: a desktop that
  # acts on this message drops the feedback the moment it arrives, and it
  # should not drop it before there is a window to drop it for.
  if startupId.len > 0:
    sendStartupInfo("remove: ID=" & snQuote(startupId))

  gGC = XCreateGC(gDisplay, gWindow, 0, nil)

  # Wait for the first Expose/ConfigureNotify to get actual size
  gWidth = layout.width.cint
  gHeight = layout.height.cint
  recreateBackBuffer()

  layout.scaleX = 1
  layout.scaleY = 1
  layout.uiScale = gUiScale

proc x11GetWindowLayout(): ScreenLayout =
  ## Re-reads `Xft.dpi`: X11 has no event for a density change, so an app that
  ## cares has to ask. `WindowMetricsEvent` carries the value cached at
  ## startup.
  if gDisplay != nil:
    gUiScale = computeUiScale()
  ScreenLayout(width: gWidth.int, height: gHeight.int,
               scaleX: 1, scaleY: 1, uiScale: gUiScale)

proc x11Refresh() =
  if gBackPixmap != None and (gFrameForced or gFrameHash != gShownHash):
    if gFrameForced or gDamageAll or gDamage.w <= 0 or gDamage.h <= 0:
      discard XCopyArea(gDisplay, gBackPixmap, gWindow, gGC,
        0, 0, gWidth.cuint, gHeight.cuint, 0, 0)
    else:
      # Only pictures were put: copy only where they went.
      discard XCopyArea(gDisplay, gBackPixmap, gWindow, gGC,
        gDamage.x.cint, gDamage.y.cint, gDamage.w.cuint, gDamage.h.cuint,
        gDamage.x.cint, gDamage.y.cint)
    gShownHash = gFrameHash
    gFrameForced = false
  gFrameHash = FrameHashSeed
  gDamage = coords.Rect()
  gDamageAll = false
  discard XFlush(gDisplay)

proc x11SaveState() = discard
proc x11RestoreState() =
  rgbaClipActive = false
  # Reset clip on both GC and XftDraw
  mixFrame(1)
  discard XSetClipMask(gDisplay, gGC, None)
  discard XftDrawSetClip(gXftDraw, nil)

proc x11SetClipRect(r: coords.Rect) =
  mixFrame(2); mixFrame(r.x); mixFrame(r.y); mixFrame(r.w); mixFrame(r.h)
  var xr = XRectangle(
    x: r.x.cshort, y: r.y.cshort,
    width: r.w.cushort, height: r.h.cushort)
  rgbaClipActive = true
  rgbaClip = xr
  discard XSetClipRectangles(gDisplay, gGC, 0, 0, addr xr, 1, 0)
  discard XftDrawSetClipRectangles(gXftDraw, 0, 0, addr xr, 1)

proc ensureDisplay(): bool =
  ## Fonts are opened before the window, and without one by a renderer that
  ## draws in a window of its own; either way they need the connection.
  if gDisplay == nil:
    gDisplay = XOpenDisplay(nil)
    if gDisplay == nil: return false
    gScreen = XDefaultScreen(gDisplay)
  true

proc x11OpenFont(path: string; size: int; style: FontStyles;
                 metrics: var FontMetrics): screen.Font =
  if not ensureDisplay(): return screen.Font(0)
  # Asked for outright, or -- for a path that names one face of a family --
  # detected from the filename.
  # Note: `substr in str` is avoided on purpose -- Nimony's system `in`
  # template early-binds `contains` and never sees strutils' string overload,
  # so we call `.contains` explicitly here.
  let lpath = path.toLowerAscii()
  let isBold = FontStyle.bold in style or lpath.contains("bold")
  let isItalic = FontStyle.italics in style or
                 lpath.contains("italic") or lpath.contains("oblique")

  # Map known font filenames to fontconfig names
  var faceName = "monospace"  # safe default
  let baseName = path.extractFilename.toLowerAscii
  if baseName.contains("dejavu") and baseName.contains("mono"):
    faceName = "DejaVu Sans Mono"
  elif baseName.contains("dejavu"):
    faceName = "DejaVu Sans"
  elif baseName.contains("consola"):
    faceName = "Consolas"
  elif baseName.contains("courier"):
    faceName = "Courier New"
  elif baseName.contains("arial"):
    faceName = "Arial"
  elif baseName.contains("cascadia"):
    if baseName.contains("mono"): faceName = "Cascadia Mono"
    else: faceName = "Cascadia Code"
  elif baseName.contains("hack"):
    faceName = "Hack"
  elif baseName.contains("fira") and baseName.contains("code"):
    faceName = "Fira Code"
  elif baseName.contains("roboto") and baseName.contains("mono"):
    faceName = "Roboto Mono"
  elif baseName.contains("source") and baseName.contains("code"):
    faceName = "Source Code Pro"
  elif baseName.contains("jetbrains"):
    faceName = "JetBrains Mono"

  # Build Xft/fontconfig pattern
  var pattern = faceName & ":pixelsize=" & $size
  if isBold: pattern &= ":weight=bold"
  if isItalic: pattern &= ":slant=italic"

  let f = XftFontOpenName(gDisplay, gScreen, cstr(pattern))
  if f == nil: return screen.Font(0)

  metrics.ascent = f.ascent
  metrics.descent = f.descent
  metrics.lineHeight = f.height
  fonts.add FontSlot(xftFont: f, metrics: metrics)
  result = screen.Font(fonts.len)

proc x11CloseFont(f: screen.Font) =
  let idx = f.int - 1
  if idx >= 0 and idx < fonts.len and fonts[idx].xftFont != nil:
    XftFontClose(gDisplay, fonts[idx].xftFont)
    fonts[idx].xftFont = nil

proc x11MeasureText(f: screen.Font; text: string): TextExtent =
  result = TextExtent(w: 0, h: 0)
  let fp = getFontPtr(f)
  if fp != nil and text.len > 0:
    var t = text
    var extents {.noinit.}: XGlyphInfo
    XftTextExtentsUtf8(gDisplay, fp, cstr(t), text.len.cint, addr extents)
    result = TextExtent(w: extents.xOff.int, h: fp.height.int)

proc paintText(fp: ptr XftFont; x, y: int; t: cstring; len: cint;
               w: cuint; fg, bg: screen.Color) =
  ## The drawing both entry points below share, once the width of the
  ## background is known -- by measuring, or because the caller said so.
  gDamageAll = true
  mixFrame(3); mixFrame(cast[int](fp)); mixFrame(x); mixFrame(y)
  mixFrame(w.int); mixFrame(fg); mixFrame(bg); mixFrameText(t, len)
  var bgColor = toXftColor(bg)
  XftDrawRect(gXftDraw, addr bgColor, x.cint, y.cint, w, fp.height.cuint)
  # `y` is the top of the line, Xft draws from the baseline.
  var fgColor = toXftColor(fg)
  XftDrawStringUtf8(gXftDraw, addr fgColor, fp,
    x.cint, (y + fp.ascent).cint, t, len)

proc x11DrawText(f: screen.Font; x, y: int; text: string;
                 fg, bg: screen.Color): TextExtent =
  result = TextExtent(w: 0, h: 0)
  let fp = getFontPtr(f)
  if fp == nil or text.len == 0: return
  var t = text
  # Measure first for background fill
  var extents {.noinit.}: XGlyphInfo
  XftTextExtentsUtf8(gDisplay, fp, cstr(t), text.len.cint, addr extents)
  result = TextExtent(w: extents.xOff.int, h: fp.height.int)
  paintText(fp, x, y, cstr(t), text.len.cint, extents.xOff.cuint, fg, bg)

proc x11DrawMeasuredText(f: screen.Font; x, y: int; text: string;
                         fg, bg: screen.Color; size: TextExtent) =
  ## `x11DrawText` without the measuring: an editor measures every run it
  ## draws anyway, to know where it ends, and walking the same glyphs again
  ## here was a second pass over every character on the screen per frame.
  let fp = getFontPtr(f)
  if fp == nil or text.len == 0: return
  var t = text
  paintText(fp, x, y, cstr(t), text.len.cint, size.w.cuint, fg, bg)

proc x11RenderText(f: screen.Font; text: string; fg: screen.Color;
                  pixels: var seq[uint32]): TextExtent =
  ## Xft draws the run into an 8-bit alpha pixmap of its own: what lands
  ## there is coverage, and coverage times `fg` is the premultiplied pixel.
  pixels.setLen 0
  let fp = getFontPtr(f)
  if fp == nil or text.len == 0: return
  var t = text
  var extents {.noinit.}: XGlyphInfo
  XftTextExtentsUtf8(gDisplay, fp, cstr(t), text.len.cint, addr extents)
  let w = extents.xOff.int
  let h = fp.height.int
  if w <= 0 or h <= 0: return
  let pixmap = XCreatePixmap(gDisplay, XRootWindow(gDisplay, gScreen),
    w.cuint, h.cuint, 8)
  let draw = XftDrawCreateAlpha(gDisplay, pixmap, 8)
  if draw == nil:
    discard XFreePixmap(gDisplay, pixmap)
    return
  # A new pixmap holds garbage; Xft fills rectangles with PictOpSrc.
  var clear = XftColor()
  XftDrawRect(draw, addr clear, 0, 0, w.cuint, h.cuint)
  var ink = XftColor(color: XRenderColor(red: 0xFFFF, green: 0xFFFF,
                                         blue: 0xFFFF, alpha: 0xFFFF))
  XftDrawStringUtf8(draw, addr ink, fp, 0, fp.ascent, cstr(t), text.len.cint)
  let image = XGetImage(gDisplay, pixmap, 0, 0, w.cuint, h.cuint,
    not 0.culong, ZPixmap)
  XftDrawDestroy(draw)
  discard XFreePixmap(gDisplay, pixmap)
  if image == nil: return
  defer:
    # What `XDestroyImage` -- a macro -- does for an image Xlib allocated.
    discard XFree(image.data)
    discard XFree(cast[pointer](image))
  if image.depth != 8 or image.bitsPerPixel != 8: return
  let src = cast[ptr UncheckedArray[uint8]](image.data)
  pixels.setLen w * h
  for y in 0 ..< h:
    for x in 0 ..< w:
      let a = src[y * image.bytesPerLine.int + x].uint32 * fg.a.uint32 div 255
      pixels[y * w + x] = (a shl 24) or ((fg.r.uint32 * a div 255) shl 16) or
                          ((fg.g.uint32 * a div 255) shl 8) or
                          (fg.b.uint32 * a div 255)
  result = TextExtent(w: w, h: h)

proc x11GetFontMetrics(f: screen.Font): FontMetrics =
  let idx = f.int - 1
  if idx >= 0 and idx < fonts.len: fonts[idx].metrics
  else: screen.FontMetrics()

proc x11FillRect(r: coords.Rect; color: screen.Color) =
  if r.w <= 0 or r.h <= 0 or color.a == 0: return
  gDamageAll = true
  mixFrame(4); mixFrame(r.x); mixFrame(r.y); mixFrame(r.w); mixFrame(r.h)
  mixFrame(color)
  var c = toXftColor(color)
  # XRender's source channels are premultiplied, including solid Xft fills.
  let alpha = color.a.uint32
  c.color.red = ((c.color.red.uint32 * alpha + 127) div 255).cushort
  c.color.green = ((c.color.green.uint32 * alpha + 127) div 255).cushort
  c.color.blue = ((c.color.blue.uint32 * alpha + 127) div 255).cushort
  if color.a < 255:
    # XftDrawRect replaces destination pixels; translucent fills need Over.
    let format = XRenderFindVisualFormat(gDisplay, gVisual)
    if format == nil:
      raise newException(ValueError, "Cannot find the XRender destination format")
    let dest = XRenderCreatePicture(gDisplay, gBackPixmap, format, 0, nil)
    if dest == None:
      raise newException(ValueError, "Cannot create the XRender destination")
    defer: XRenderFreePicture(gDisplay, dest)
    if rgbaClipActive:
      XRenderSetPictureClipRectangles(gDisplay, dest, 0, 0, addr rgbaClip, 1)
    XRenderFillRectangle(gDisplay, 3, dest, addr c.color,
      r.x.cint, r.y.cint, r.w.cuint, r.h.cuint)
  else:
    XftDrawRect(gXftDraw, addr c, r.x.cint, r.y.cint, r.w.cuint, r.h.cuint)

proc x11DrawLine(x1, y1, x2, y2: int; color: screen.Color) =
  gDamageAll = true
  mixFrame(5); mixFrame(x1); mixFrame(y1); mixFrame(x2); mixFrame(y2)
  mixFrame(color)
  discard XSetForeground(gDisplay, gGC, toPixel(color))
  discard XDrawLine(gDisplay, gBackPixmap, gGC,
    x1.cint, y1.cint, x2.cint, y2.cint)

proc x11DrawPoint(x, y: int; color: screen.Color) =
  gDamageAll = true
  mixFrame(6); mixFrame(x); mixFrame(y); mixFrame(color)
  discard XSetForeground(gDisplay, gGC, toPixel(color))
  discard XDrawPoint(gDisplay, gBackPixmap, gGC, x.cint, y.cint)

# ---- Pixel blitting ----

var gBlitVerdict = 0
  ## 0 = nobody has asked yet, 1 = the surface takes pixels, -1 = it does not.
  ## Whether it does is a property of the visual, which does not change while
  ## the program runs, so the answer is worth keeping rather than building a
  ## throwaway XImage every frame to hear it again.

proc x11BlendRGBA(pixels: ptr UncheckedArray[uint32]; w, h: int;
                  dst: coords.Rect): bool =
  if gDisplay == nil or gBackPixmap == None: return false
  if w > 65535 or h > 65535: return false # X11 pixmap dimensions are CARD16.
  let sourceFormat = XRenderFindStandardFormat(gDisplay, 0) # PictStandardARGB32
  let destFormat = XRenderFindVisualFormat(gDisplay, gVisual)
  if sourceFormat == nil or destFormat == nil: return false
  let pixmap = XCreatePixmap(gDisplay, gWindow, w.cuint, h.cuint, 32)
  if pixmap == None: return false
  defer: discard XFreePixmap(gDisplay, pixmap)
  let gc = XCreateGC(gDisplay, pixmap, 0, nil)
  if gc == nil: return false
  defer: discard XFreeGC(gDisplay, gc)
  let image = XCreateImage(gDisplay, gVisual, 32, ZPixmap, 0,
    cast[pointer](pixels), w.cuint, h.cuint, 32, (w * 4).cint)
  if image == nil: return false
  defer:
    image.data = nil
    discard XFree(cast[pointer](image))
  when cpuEndian == littleEndian:
    let hostOrder = LSBFirst
  else:
    let hostOrder = MSBFirst
  if image.bitsPerPixel != 32 or image.byteOrder != hostOrder:
    return false
  discard XPutImage(gDisplay, pixmap, gc, image, 0, 0, 0, 0, w.cuint, h.cuint)
  let source = XRenderCreatePicture(gDisplay, pixmap, sourceFormat, 0, nil)
  if source == None: return false
  defer: XRenderFreePicture(gDisplay, source)
  let dest = XRenderCreatePicture(gDisplay, gBackPixmap, destFormat, 0, nil)
  if dest == None: return false
  defer: XRenderFreePicture(gDisplay, dest)
  if rgbaClipActive:
    XRenderSetPictureClipRectangles(gDisplay, dest, 0, 0, addr rgbaClip, 1)
  let cw = min(w, dst.w)
  let ch = min(h, dst.h)
  # Every picture put counts as a change; the window is copied where it went.
  damage(dst.x, dst.y, cw, ch)
  mixFrame(8); mixFrame(dst.x); mixFrame(dst.y)
  mixFrame(w); mixFrame(h); mixFrame(cw); mixFrame(ch); mixFrame(gBlitSerial)
  XRenderComposite(gDisplay, 3, source, None, dest, 0, 0, 0, 0,
    dst.x.cint, dst.y.cint, cw.cuint, ch.cuint) # PictOpOver
  true

proc x11BlitRGBA(pixels: ptr UncheckedArray[uint32]; w, h: int;
                 dst: coords.Rect; format: RGBAFormat): bool =
  if pixels == nil or w <= 0 or h <= 0 or dst.w <= 0 or dst.h <= 0: return false
  if format == RGBAFormat.argbPremultiplied:
    return x11BlendRGBA(pixels, w, h, dst)
  if gDisplay == nil or gBackPixmap == None or gBlitVerdict < 0: return false
  if pixels == nil or w <= 0 or h <= 0 or dst.w <= 0 or dst.h <= 0: return false

  var img = XCreateImage(gDisplay, gVisual, gDepth.cuint, ZPixmap.cint, 0,
                         cast[pointer](pixels), w.cuint, h.cuint, 32, 0)
  if img == nil:
    gBlitVerdict = -1
    return false

  # What came in is one `uint32` per pixel in this machine's byte order, so
  # the server has to want exactly that: 32 bits to a pixel, and the same end
  # of the word first. Both hold on every ordinary desktop -- the depth-24
  # TrueColor visual nearly everything has is padded to 32 bits a pixel, and
  # a client almost always talks to a server on its own machine. Where they
  # do not hold there is no fix worth having here, so the answer is no, once,
  # and the caller draws whatever it draws when there is no picture.
  let hostOrder = (if cpuEndian == littleEndian: LSBFirst else: MSBFirst).cint
  if img.bitsPerPixel != 32 or img.byteOrder != hostOrder:
    img.data = nil
    discard XFree(cast[pointer](img))
    gBlitVerdict = -1
    return false
  gBlitVerdict = 1

  let cw = min(w, dst.w)
  let ch = min(h, dst.h)

  # Every picture put changes the frame (the caller only sends what changed:
  # hashing its pixels would cost as much as sending them), and the refresh
  # copies to the window only the part the pictures covered.
  damage(dst.x, dst.y, cw, ch)
  mixFrame(7); mixFrame(dst.x); mixFrame(dst.y)
  mixFrame(w); mixFrame(h); mixFrame(cw); mixFrame(ch); mixFrame(gBlitSerial)

  discard XPutImage(gDisplay, gBackPixmap, gGC, img, 0, 0,
                    dst.x.cint, dst.y.cint, cw.cuint, ch.cuint)

  # `XDestroyImage` is a C macro, not a symbol to bind, and it frees the
  # pixels along with the struct -- but the pixels are the caller's and it
  # still wants them. Letting go of them first leaves `XFree` exactly what
  # `XCreateImage` allocated, which is the struct.
  img.data = nil
  discard XFree(cast[pointer](img))
  result = true

proc x11DrawRGBA(pixels: ptr UncheckedArray[uint32]; w, h: int;
                 dst: coords.Rect; format: RGBAFormat): bool =
  if pixels == nil or w <= 0 or h <= 0 or dst.w <= 0 or dst.h <= 0:
    return false
  if w == dst.w and h == dst.h:
    return x11BlitRGBA(pixels, w, h, dst, format)
  let resized = resizedRGBA(pixels, w, h, dst.w, dst.h,
    preserveAlpha = format == RGBAFormat.argbPremultiplied)
  x11BlitRGBA(cast[ptr UncheckedArray[uint32]](unsafeAddr resized[0]),
              dst.w, dst.h, dst, format)

proc x11SetCursor(c: CursorKind) =
  let shape = case c
    of curDefault, curArrow: XC_left_ptr
    of curIbeam: XC_xterm
    of curWait: XC_watch
    of curCrosshair: XC_crosshair
    of curHand: XC_hand2
    of curSizeNS: XC_sb_v_double_arrow
    of curSizeWE: XC_sb_h_double_arrow
    of curSizeNWSE: XC_bottom_right_corner
    of curSizeNESW: XC_bottom_left_corner
    of curMove: XC_fleur
  let cur = XCreateFontCursor(gDisplay, shape)
  discard XDefineCursor(gDisplay, gWindow, cur)

proc x11SetWindowTitle(title: string) =
  var t = title
  discard XStoreName(gDisplay, gWindow, cstr(t))

# ---- Frame hook implementations ----

proc x11SetSystemFrame(on: bool): bool =
  gSystemFrame = on
  if gDisplay != nil and gWindow != None:
    putFrameHints()           # (window managers follow the property's changes)
    discard XFlush(gDisplay)
  true

proc x11DragWindow(part: WindowPart; keyboard: bool): bool =
  if gDisplay == nil or gWindow == None or part == wpClient: return false
  let moveResize = XInternAtom(gDisplay, "_NET_WM_MOVERESIZE", 0)
  let supported = XInternAtom(gDisplay, "_NET_SUPPORTED", 0)
  # (no window manager, or one that cannot)
  if moveResize == 0 or
     moveResize notin atomsOf(XRootWindow(gDisplay, gScreen), supported):
    return false
  var root, child: XID
  var rx, ry, wx, wy: cint
  var mask: cuint
  discard XQueryPointer(gDisplay, gWindow, addr root, addr child,
                        addr rx, addr ry, addr wx, addr wy, addr mask)
  # Let go already: nothing to drag.
  if not keyboard and (mask and Button1Mask) == 0: return false
  let direction = if keyboard: (if part == wpCaption: 10 else: 9)   # _KEYBOARD
                  else:
                    case part
                    of wpTopLeft: 0
                    of wpTop: 1
                    of wpTopRight: 2
                    of wpRight: 3
                    of wpBottomRight: 4
                    of wpBottom: 5
                    of wpBottomLeft: 6
                    of wpLeft: 7
                    else: 8                                      # _MOVE
  # The press's own grab of the pointer goes first: the window manager takes
  # the pointer from here, and the button's release with it.
  discard XUngrabPointer(gDisplay, CurrentTime)
  var ev = XEvent()
  ev.xclient.theType = ClientMessage
  ev.xclient.window = gWindow
  ev.xclient.message_type = moveResize
  ev.xclient.format = 32
  ev.xclient.data[0] = rx.clong
  ev.xclient.data[1] = ry.clong
  ev.xclient.data[2] = direction.clong
  ev.xclient.data[3] = (if keyboard: 0 else: 1)                # the button
  ev.xclient.data[4] = 1                                       # an application
  discard XSendEvent(gDisplay, root, 0,
                     (SubstructureNotifyMask or SubstructureRedirectMask).clong,
                     addr ev)
  discard XFlush(gDisplay)
  if not keyboard:
    pushEvent(input.Event(kind: MouseUpEvent, hasMods: true, x: wx.int, y: wy.int,
                          button: LeftButton,
                          mods: translateMods(mask)))
  true

proc x11SetMaximized(on: bool) =
  if gDisplay == nil or gWindow == None: return
  sendWmState(on, XInternAtom(gDisplay, "_NET_WM_STATE_MAXIMIZED_HORZ", 0),
              XInternAtom(gDisplay, "_NET_WM_STATE_MAXIMIZED_VERT", 0))

proc x11Minimize(): bool =
  if gDisplay == nil or gWindow == None: return false
  result = XIconifyWindow(gDisplay, gWindow, gScreen) != 0
  discard XFlush(gDisplay)

# ---- Input hook implementations ----

proc x11PollEvent(e: var input.Event; flags: set[InputFlag]): bool =
  drainXEvents()
  if eventQueue.len > 0:
    e = eventQueue[0]
    eventQueue.delete(0)
    return true
  return false

proc x11WaitEvent(e: var input.Event; timeoutMs: int;
                  flags: set[InputFlag]): bool =
  if eventQueue.len > 0:
    e = eventQueue[0]
    eventQueue.delete(0)
    return true
  if x11PollEvent(e, flags): return true

  # Block on the X11 connection fd using select() with timeout.
  let xfd = ConnectionNumber(gDisplay)
  var fds {.noinit.}: XFdSet
  xFdZero(addr fds)
  xFdSet(xfd, addr fds)

  if timeoutMs < 0:
    discard xSelect(xfd + 1, addr fds, nil, nil, nil)
  else:
    var tv = XTimeval(tv_sec: (timeoutMs div 1000).clong,
                      tv_usec: ((timeoutMs mod 1000) * 1000).clong)
    discard xSelect(xfd + 1, addr fds, nil, nil, addr tv)

  # select() returned -- drain whatever arrived
  drainXEvents()
  if eventQueue.len > 0:
    e = eventQueue[0]
    eventQueue.delete(0)
    return true
  return false

proc x11GetClipboardText(): string =
  result = ""
  discard XConvertSelection(gDisplay, gClipboard, gUtf8String,
    gClipProperty, gWindow, CurrentTime)
  discard XFlush(gDisplay)
  # Wait for SelectionNotify (with timeout)
  let deadline = getTicks() + 500  # 500ms timeout
  while getTicks() < deadline:
    if XPending(gDisplay) > 0:
      var xev {.noinit.}: XEvent
      discard XNextEvent(gDisplay, addr xev)
      if xev.theType == SelectionNotify and xev.xselection.selection == gClipboard:
        if xev.xselection.property != None:
          var actualType {.noinit.}: Atom
          var actualFormat {.noinit.}: cint
          var nitems {.noinit.}: culong
          var bytesAfter {.noinit.}: culong
          var data {.noinit.}: pointer
          discard XGetWindowProperty(gDisplay, gWindow, gClipProperty,
            0, 1024*1024, 1, 0, # delete=True, AnyPropertyType
            addr actualType, addr actualFormat,
            addr nitems, addr bytesAfter, addr data)
          if data != nil:
            result = $cast[cstring](data)
            discard XFree(data)
        return
      else:
        dispatchXEvent(xev)
    else:
      sleepMs(5)

proc x11PutClipboardText(text: string) =
  gClipboardText = text
  discard XSetSelectionOwner(gDisplay, gClipboard, gWindow, CurrentTime)

proc x11GetTicks(): int =
  # Use POSIX clock
  var ts {.noinit.}: Timespec
  discard clock_gettime(0.ClockId, ts)  # CLOCK_REALTIME = 0
  result = int(ts.tv_sec.int64 * 1000 + ts.tv_nsec.int64 div 1_000_000)

proc x11Delay(ms: int) =
  # Drain events during delay to stay responsive
  let deadline = x11GetTicks() + ms
  while true:
    let now = x11GetTicks()
    if now >= deadline: break
    drainXEvents()
    sleepMs(min(deadline - now, 10))

# ---- Files dragged out: the drag (see "XDND, as the source") ----

proc XGrabPointer(dpy: pointer; w: XID; ownerEvents: XBool; mask: cuint;
  pointerMode, keyboardMode: cint; confineTo, cursor: XID; time: XTime): cint
  {.cdecl, dynlib: libX11, importc.}
proc XGrabKeyboard(dpy: pointer; w: XID; ownerEvents: XBool;
  pointerMode, keyboardMode: cint; time: XTime): cint
  {.cdecl, dynlib: libX11, importc.}
proc XUngrabKeyboard(dpy: pointer; time: XTime): cint
  {.cdecl, dynlib: libX11, importc.}
proc XChangeActivePointerGrab(dpy: pointer; mask: cuint; cursor: XID;
  time: XTime): cint
  {.cdecl, dynlib: libX11, importc.}
proc XGetSelectionOwner(dpy: pointer; selection: Atom): XID
  {.cdecl, dynlib: libX11, importc.}

const
  GrabModeAsync = 1.cint
  GrabSuccess = 0.cint
  XA_WINDOW = 33.Atom
  XC_circle = 24'u32
  OutGrabMask = cuint(ButtonPressMask or ButtonReleaseMask or PointerMotionMask)

var gDndCursors: array[3, XID]   # (over nothing that takes it, a copy, a move)

proc dndCursor(kind: int): XID =
  ## The pointer of a drag over nothing that takes it (0), a copy (1), a
  ## move (2): the theme's where libXcursor finds them, else X's own.
  if gDndCursors[kind] == None:
    const names = [[cstring"dnd-no-drop", "no-drop"], [cstring"dnd-copy", "copy"],
                   [cstring"dnd-move", "move"]]
    let lib = loadLib("libXcursor.so.1")
    if lib != nil:
      let load = cast[proc (dpy: pointer; name: cstring): XID {.cdecl.}](
        lib.symAddr("XcursorLibraryLoadCursor"))
      if load != nil:
        for n in names[kind]:
          if gDndCursors[kind] == None: gDndCursors[kind] = load(gDisplay, n)
    if gDndCursors[kind] == None:
      gDndCursors[kind] = XCreateFontCursor(gDisplay, [XC_circle, XC_hand2, XC_fleur][kind])
  gDndCursors[kind]

proc windowProp(w: XID; prop: Atom): XID =
  ## A window's property of type WINDOW (`XdndProxy`); None: it has none.
  var actualType: Atom
  var actualFormat: cint
  var n, after: culong
  var data: pointer
  if XGetWindowProperty(gDisplay, w, prop, 0, 1, 0, XA_WINDOW, addr actualType,
                        addr actualFormat, addr n, addr after, addr data) == 0 and
     data != nil:
    if actualFormat == 32 and n >= 1: result = XID(cast[ptr clong](data)[])
    discard XFree(data)

proc xdndTargetAt(x, y: int): tuple[w, via: XID; version: int] =
  ## The window at `x`, `y` on the screen that takes drops (None: none),
  ## where its messages go (its proxy; None: to it) and its protocol's
  ## version: the first window down from the root that says `XdndAware`.
  let root = XRootWindow(gDisplay, gScreen)
  var w = root
  for depth in 0 .. 32:
    # (a proxy counts when it says it is its own)
    var via = windowProp(w, xa(xaProxy))
    if via != None and windowProp(via, xa(xaProxy)) != via: via = None
    let aware = atomsOf(if via != None: via else: w, xa(xaAware))
    if aware.len > 0 and (w != root or via != None):
      return (w, via, int(aware[0]))
    var cx, cy: cint
    var child: XID
    if XTranslateCoordinates(gDisplay, root, w, x.cint, y.cint, addr cx, addr cy,
                             addr child) == 0 or child == None:
      break
    w = child
  result = (None, None, 0)

proc outSend(kind: Atom; d1, d2, d3, d4: clong) =
  xdndSend(gOut.target, kind, d1, d2, d3, d4, gOut.proxy)

proc outPosition() =
  ## (where the pointer is, to the window under it -- once it answered the
  ## last one)
  if gOut.target == None: return
  if gOut.waiting:
    gOut.moved = true
    return
  outSend(xa(xaPosition), 0, clong((gOut.x shl 16) or (gOut.y and 0xFFFF)),
          clong(gOut.time), clong(gOut.wanted))
  gOut.waiting = true
  gOut.waitSince = x11GetTicks()
  gOut.moved = false

proc outCursor() =
  let kind = if gOut.target == None or not gOut.accepted: 0
             elif gOut.action == xa(xaActionMove): 2
             else: 1
  discard XChangeActivePointerGrab(gDisplay, OutGrabMask, dndCursor(kind), CurrentTime)

proc outLeave() =
  if gOut.target != None: outSend(xa(xaLeave), 0, 0, 0, 0)
  gOut.target = None
  gOut.accepted = false
  gOut.waiting = false

proc outMoveTo(x, y: int; back: bool): bool =
  ## The pointer at `x`, `y` on the screen: the window under it is told.
  ## False when it came back over this window, a little way in, and `back`
  ## ends the drag there.
  gOut.x = x
  gOut.y = y
  var t = xdndTargetAt(x, y)
  if t.w == gWindow:
    if back:
      var wx, wy: cint
      var child: XID
      discard XTranslateCoordinates(gDisplay, XRootWindow(gDisplay, gScreen), gWindow,
                                    x.cint, y.cint, addr wx, addr wy, addr child)
      const m = 4
      if wx >= m and wy >= m and wx < gWidth - m and wy < gHeight - m:
        outLeave()
        return false
    t = (None, None, 0)                  # (no target of its own drags)
  elif t.version < 3:
    t = (None, None, 0)                  # (older than this speaks)
  if t.w != gOut.target:
    outLeave()
    gOut.target = t.w
    gOut.proxy = t.via
    gOut.version = min(5, t.version)
    if t.w != None:
      outSend(xa(xaEnter), clong(gOut.version shl 24), clong(xa(xaUriList)), 0, 0)
  outPosition()
  outCursor()
  true

proc outStatus(m: XClientMessageEvent) =
  ## (the window under the pointer answered: it takes them or not, and how)
  if gOut.target == None or XID(m.data[0]) != gOut.target: return
  gOut.waiting = false
  gOut.accepted = (m.data[1] and 1) != 0
  gOut.action = Atom(m.data[4])
  if gOut.moved: outPosition()
  outCursor()

proc x11DragFilesOut(paths: seq[string]; move, backInside: bool): DragOutResult =
  if gDisplay == nil or gWindow == None or paths.len == 0 or xa(xaSelection) == 0:
    return drNone
  var root, child: XID
  var rx, ry, wx, wy: cint
  var mask: cuint
  discard XQueryPointer(gDisplay, gWindow, addr root, addr child,
                        addr rx, addr ry, addr wx, addr wy, addr mask)
  if (mask and Button1Mask) == 0: return drNone          # (let go already)
  # The files on XdndSelection, from the press's time on, and what may be
  # done with them: a copy, or a move too (asked for unless Ctrl is down).
  discard XSetSelectionOwner(gDisplay, xa(xaSelection), gWindow, lastClickTime)
  if XGetSelectionOwner(gDisplay, xa(xaSelection)) != gWindow: return drNone
  if move:
    var actions = [xa(xaActionCopy), xa(xaActionMove)]
    discard XChangeProperty(gDisplay, gWindow, xa(xaActionList), XA_ATOM, 32,
                            PropModeReplace, addr actions[0], 2)
  else:
    discard XDeleteProperty(gDisplay, gWindow, xa(xaActionList))
  gOut = XdndOut(list: uriListOfFiles(paths), time: lastClickTime,
                 wanted: if move and (mask and ControlMask) == 0: xa(xaActionMove)
                         else: xa(xaActionCopy))
  # (the windows asked about may go away meanwhile)
  let oldHandler = XSetErrorHandler(ignoreXError)
  if XGrabPointer(gDisplay, gWindow, 0, OutGrabMask, GrabModeAsync, GrabModeAsync,
                  None, dndCursor(0), CurrentTime) != GrabSuccess:
    discard XSetErrorHandler(oldHandler)
    return drNone
  discard XGrabKeyboard(gDisplay, gWindow, 0, GrabModeAsync, GrabModeAsync, CurrentTime)
  gOutGrab = false
  result = drCancelled
  var released = false       # the button was let go (its release came here)
  var relX, relY: cint
  var relState: cuint
  var dropAt = 0             # when XdndDrop went (0: not yet)
  let xfd = ConnectionNumber(gDisplay)
  block drag:
    if not outMoveTo(rx, ry, backInside):
      result = drBack
      break drag
    while true:
      while XPending(gDisplay) > 0:
        var xev {.noinit.}: XEvent
        discard XNextEvent(gDisplay, addr xev)
        case xev.theType
        of MotionNotify:
          if not released:
            gOut.time = xev.xmotion.time
            if not outMoveTo(xev.xmotion.x_root, xev.xmotion.y_root, backInside):
              result = drBack
              break drag
        of ButtonRelease:
          if xev.xbutton.button == Button1 and not released:
            released = true
            relX = xev.xbutton.x
            relY = xev.xbutton.y
            relState = xev.xbutton.state
            gOut.time = xev.xbutton.time
        of KeyPress:
          var ks: XKeySym
          discard XLookupString(addr xev.xkey, nil, 0, addr ks, nil)
          if ks == XK_Escape and dropAt == 0:
            outLeave()
            break drag
        of ClientMessage:
          let k = xev.xclient.message_type
          if k == xa(xaStatus):
            outStatus(xev.xclient)
          elif k == xa(xaFinished):
            if dropAt != 0 and XID(xev.xclient.data[0]) == gOut.target:
              # (version 5 says whether it went well, and what it did)
              let ok = gOut.version < 5 or (xev.xclient.data[1] and 1) != 0
              let did = if gOut.version >= 5: Atom(xev.xclient.data[2]) else: gOut.action
              result = if not ok: drCancelled
                       elif did == xa(xaActionMove) or gOut.deleted: drMoved
                       else: drCopied
              break drag
          elif k in [xa(xaEnter), xa(xaPosition), xa(xaLeave), xa(xaDrop)]:
            discard                       # (this window takes no drop now)
          else:
            processXEvent(xev)
        of ButtonPress, KeyRelease, GenericEvent:
          discard                         # (the drag's)
        else:
          processXEvent(xev)              # (painting, sizes, selections...)
      let now = x11GetTicks()
      # Let go: dropped where the last answer said they are taken (once it
      # came, or a second later).
      if released and dropAt == 0 and (not gOut.waiting or now - gOut.waitSince > 1000):
        if gOut.target != None and gOut.accepted:
          outSend(xa(xaDrop), 0, clong(gOut.time), 0, 0)
          dropAt = now
        else:
          outLeave()
          break drag
      if dropAt != 0 and now - dropAt > 5000:
        # (no word from it: taken if it took the list)
        result = if not gOut.sent: drCancelled elif gOut.deleted: drMoved else: drCopied
        break drag
      if gOut.waiting and not released and now - gOut.waitSince > 2000:
        gOut.waiting = false              # (it does not answer: asked again)
        if gOut.moved: outPosition()
      var fds {.noinit.}: XFdSet
      xFdZero(addr fds)
      xFdSet(xfd, addr fds)
      var tv = XTimeval(tv_sec: 0, tv_usec: 20_000)
      discard xSelect(xfd + 1, addr fds, nil, nil, addr tv)
  discard XUngrabKeyboard(gDisplay, CurrentTime)
  if released:
    discard XUngrabPointer(gDisplay, CurrentTime)
    pushEvent(input.Event(kind: MouseUpEvent, hasMods: true, x: relX.int, y: relY.int,
                          button: LeftButton, mods: translateMods(relState)))
  else:
    # The button is still down (Esc, or back over the window): the window
    # keeps the pointer until it is let go, as the press's own grab did.
    gOutGrab = true
    discard XChangeActivePointerGrab(gDisplay, OutGrabMask, None, CurrentTime)
    discard XQueryPointer(gDisplay, gWindow, addr root, addr child,
                          addr rx, addr ry, addr wx, addr wy, addr mask)
    pushEvent(input.Event(kind: MouseMoveEvent, hasMods: true, x: wx.int, y: wy.int,
                          mods: translateMods(mask)))
  discard XSync(gDisplay, 0)
  discard XSetErrorHandler(oldHandler)

proc x11QuitRequest() =
  if gDisplay != nil:
    if gXic != nil: XDestroyIC(gXic)
    if gXim != nil: discard XCloseIM(gXim)
    discard XDestroyWindow(gDisplay, gWindow)
    discard XCloseDisplay(gDisplay)


# ---- Init ----

# ---- OpenGL (EGL) ----

proc XVisualIDFromVisual(v: pointer): culong
  {.cdecl, dynlib: libX11, importc.}

proc x11StartGpu(): bool =
  if gDisplay == nil or gWindow == None: return false
  result = eglload.current.openOnWindow(gDisplay, uint(gWindow), int(XVisualIDFromVisual(gVisual)))
  gGpu = result

proc x11StopGpu() =
  eglload.current.close()
  gGpu = false

proc initX11Driver*() =
  gpuRelays = GpuRelays(
    startGpu: x11StartGpu, stopGpu: x11StopGpu,
    swapGpu: proc (): bool = eglload.current.swap(),
    gpuProc: proc (name: cstring): pointer = eglload.current.glProc(name),
    gpuIsEs: proc (): bool = true,
    gpuGeneration: proc (): int = 0,
    gpuReady: proc (): bool = gGpu)
  windowRelays = WindowRelays(
    createWindow: x11CreateWindow, getWindowLayout: x11GetWindowLayout,
    refresh: x11Refresh,
    saveState: x11SaveState, restoreState: x11RestoreState,
    setClipRect: x11SetClipRect, setCursor: x11SetCursor,
    setWindowTitle: x11SetWindowTitle)
  fontRelays = FontRelays(
    openFont: x11OpenFont, closeFont: x11CloseFont,
    getFontMetrics: x11GetFontMetrics, measureText: x11MeasureText,
    drawText: x11DrawText, drawMeasuredText: x11DrawMeasuredText,
    renderText: x11RenderText)
  drawRelays = DrawRelays(
    fillRect: x11FillRect, drawLine: x11DrawLine, drawPoint: x11DrawPoint,
    blitRGBA: x11BlitRGBA, drawRGBA: x11DrawRGBA)
    # No `loadImage` here, and so no `imageSize` either: this driver does not
    # decode pictures. `blitRGBA` is how one gets on the screen -- whoever
    # can turn a file into pixels hands them over and gets the clip rectangle
    # and the frame's dirty tracking of this driver for free.
  frameRelays = FrameRelays(
    setSystemFrame: x11SetSystemFrame, dragWindow: x11DragWindow,
    setMaximized: x11SetMaximized,
    maximized: proc (): bool = gMaximized,
    active: proc (): bool = gFocused)
  systemRelays.minimize = x11Minimize
  fileDragRelays = FileDragRelays(dragOut: x11DragFilesOut)
  inputRelays = InputRelays(
    pollEvent: x11PollEvent, waitEvent: x11WaitEvent,
    getTicks: x11GetTicks, sleep: x11Delay,
    shutdown: x11QuitRequest)
  clipboardRelays = ClipboardRelays(
    getText: x11GetClipboardText, putText: x11PutClipboardText)

proc attachSiwinSurface*(display: pointer; window: uint64; width, height: int) =
  ## Borrow Siwin's X11 connection/window, retaining native Xft/XRender drawing.
  if gDisplay != display or gWindow != XID(window) or gGC == nil:
    gDisplay = display
    gWindow = XID(window)
    gScreen = XDefaultScreen(display)
    gVisual = XDefaultVisual(display, gScreen)
    gColormap = XDefaultColormap(display, gScreen)
    gDepth = XDefaultDepth(display, gScreen)
    gGC = XCreateGC(display, gWindow, 0, nil)
  if gWidth != width.cint or gHeight != height.cint or gBackPixmap == None:
    let previousPixmap = gBackPixmap
    let previousDraw = gXftDraw
    let previousWidth = gWidth
    let previousHeight = gHeight
    gBackPixmap = None
    gXftDraw = nil
    gWidth = width.cint
    gHeight = height.cint
    recreateBackBuffer()
    if previousPixmap != None:
      let copyGC = XCreateGC(gDisplay, gBackPixmap, 0, nil)
      discard XCopyArea(gDisplay, previousPixmap, gBackPixmap, copyGC, 0, 0,
        min(previousWidth, gWidth).cuint, min(previousHeight, gHeight).cuint, 0, 0)
      discard XFreeGC(gDisplay, copyGC)
      XftDrawDestroy(previousDraw)
      discard XFreePixmap(gDisplay, previousPixmap)

proc presentSiwinSurface*() =
  ## Repaint exposed areas even when the application's frame hash is unchanged.
  if gDisplay != nil and gBackPixmap != None:
    discard XCopyArea(gDisplay, gBackPixmap, gWindow, gGC, 0, 0,
      gWidth.cuint, gHeight.cuint, 0, 0)
    discard XFlush(gDisplay)

proc detachSiwinSurface*() =
  ## Release our drawing resources without closing Siwin's borrowed connection.
  if gDisplay != nil:
    for font in fonts.mitems:
      if font.xftFont != nil: XftFontClose(gDisplay, font.xftFont)
      font.xftFont = nil
    if gXftDraw != nil: XftDrawDestroy(gXftDraw)
    if gBackPixmap != None: discard XFreePixmap(gDisplay, gBackPixmap)
    if gGC != nil: discard XFreeGC(gDisplay, gGC)
  fonts.setLen(0)
  gXftDraw = nil
  gBackPixmap = None
  gGC = nil
  gDisplay = nil
  gWindow = None
  gWidth = 0
  gHeight = 0

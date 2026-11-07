# Android backend driver. Sets all hooks from core/input and core/screen.
# android_glue.c runs the app on its own thread under a NativeActivity,
# queues its input and puts its pixels in the window; surface_driver turns
# that into relays.
#
# Build with `--os:android --cpu:arm64 --app:lib --noMain` into libmain.so
# and pack it into an APK whose activity is android.app.NativeActivity (or
# android/UiRelaysActivity.java); see README.md.

import ../input, ../screen, ../services, ../access
import surface_driver
import std/strutils

{.compile: "android_glue.c".}
{.passL: "-landroid -llog -ldl".}

proc androidKey(code: int32): KeyCode =
  ## AKEYCODE_* to ours.
  case code
  of 29..54: KeyCode(ord(KeyA) + code - 29)       # A..Z
  of 7..16: KeyCode(ord(Key0) + code - 7)         # 0..9
  of 131..142: KeyCode(ord(KeyF1) + code - 131)   # F1..F12
  of 66, 160, 23: KeyEnter                        # ENTER, NUMPAD_ENTER, DPAD_CENTER
  of 62: KeySpace
  of 111, 4: KeyEsc                               # ESCAPE, BACK
  of 61: KeyTab
  of 67: KeyBackspace                             # DEL
  of 112: KeyDelete                               # FORWARD_DEL
  of 124: KeyInsert
  of 21: KeyLeft
  of 22: KeyRight
  of 19: KeyUp
  of 20: KeyDown
  of 92: KeyPageUp
  of 93: KeyPageDown
  of 122: KeyHome
  of 123: KeyEnd
  of 115: KeyCapslock
  of 55: KeyComma
  of 56: KeyPeriod
  of 76: KeySlash
  of 69: KeyMinus
  of 71: KeyLeftBracket
  of 72: KeyRightBracket
  of 73: KeyBackslash
  of 74: KeySemicolon
  of 75: KeyQuote
  of 68: KeyBackquote
  of 70: KeyEqual
  of 81, 157: KeyPlus                             # PLUS, NUMPAD_ADD
  of 82: KeyMenu                                  # MENU
  of 144..153: KeyCode(ord(Key0) + code - 144)    # NUMPAD_0..9
  of 154: KeySlash                                # NUMPAD_DIVIDE
  of 156: KeyMinus                                # NUMPAD_SUBTRACT
  of 158: KeyPeriod                               # NUMPAD_DOT
  of 159: KeyComma                                # NUMPAD_COMMA
  of 161: KeyEqual                                # NUMPAD_EQUALS
  else: KeyNone

proc urGlStart(): cint {.importc: "uirelays_gl_start", cdecl.}
proc urGlStop() {.importc: "uirelays_gl_stop", cdecl.}
proc urGlSwap(): cint {.importc: "uirelays_gl_swap", cdecl.}
proc urGlReady(): cint {.importc: "uirelays_gl_ready", cdecl.}
proc urGlGen(): cint {.importc: "uirelays_gl_gen", cdecl.}
proc urGlProc(name: cstring): pointer {.importc: "uirelays_gl_proc", cdecl.}

proc urAccessTake(action: ptr cint; id: ptr uint32; num: ptr float64; text: ptr cstring): cint
  {.importc: "uirelays_access_take", cdecl.}
proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>".}
proc urComposeTake(caret: ptr cint): cstring {.importc: "uirelays_compose_take", cdecl.}

proc takeAccessAsks() =
  ## (what TalkBack asked, from the UI thread, into `accessRequests`)
  var action: cint
  var id: uint32
  var num: float64
  var text: cstring
  while urAccessTake(addr action, addr id, addr num, addr text) != 0:
    let t = if text != nil: $text else: ""
    if text != nil: cFree(text)
    if action == -1: accessListening = true
    elif action == -2: accessListening = false
    elif action >= 0 and action <= ord(high(AccessAction)):
      accessRequests.add AccessRequest(action: AccessAction(action), id: id, text: t, num: num)

proc flat(s: string): string =
  ## (a field of the tree as RetroAccess.java reads it: no tab, no separators)
  result = newStringOfCap(s.len)
  for c in s:
    result.add(if c in {'\t', '\x1e', '\x1f'}: ' ' else: c)

var basePoll: proc (e: var Event; flags: set[InputFlag]): bool {.nimcall.}
var baseWait: proc (e: var Event; t: int; flags: set[InputFlag]): bool {.nimcall.}

proc androidAccessUpdate(nodes: openArray[AccessNode]; focus: int) =
  ## The tree to RetroAccess.java (TalkBack's node provider): a node a
  ## record, its fields apart.
  var s = newStringOfCap(nodes.len * 64)
  for n in nodes:
    for f in [$n.id, $n.parent, $ord(n.role), $cast[uint16](n.states), $n.x, $n.y, $n.w, $n.h,
              $n.lo, $n.hi, $n.now, $n.step, $n.pos, $n.count, $n.caret,
              flat(n.name), flat(n.value), flat(n.help)]:
      s.add f
      s.add '\x1f'
    s.add '\x1e'
  discard systemRelays.call("access.update", s & "\t" & $focus)

proc initAndroidDriver*() =
  ## Points the relays at Android: the surface driver's, and OpenGL ES on
  ## the window.
  initSurfaceDriver(androidKey)
  # what the keyboard composes (RetroInput)
  composeTake = proc (caret: var int): string =
    var c: cint
    let p = urComposeTake(addr c)
    caret = int(c)
    if p != nil:
      result = $p
      cFree(p)
  # screen readers (TalkBack): what it asks taken with every event
  basePoll = inputRelays.pollEvent
  baseWait = inputRelays.waitEvent
  inputRelays.pollEvent = proc (e: var Event; flags: set[InputFlag]): bool =
    result = basePoll(e, flags)
    takeAccessAsks()
  inputRelays.waitEvent = proc (e: var Event; t: int; flags: set[InputFlag]): bool =
    result = baseWait(e, t, flags)
    takeAccessAsks()
  accessRelays = AccessRelays(
    start: proc (): bool =
      # (on now: TalkBack runs)
      if systemRelays.call("access.enabled", "") == "1": accessListening = true
      true,
    update: androidAccessUpdate)
  # OpenGL ES on the window (android_glue.c: EGL, opened at run time)
  gpuRelays = GpuRelays(
    startGpu: proc (): bool = urGlStart() != 0,
    stopGpu: proc () = urGlStop(),
    swapGpu: proc (): bool = urGlSwap() != 0,
    gpuProc: proc (name: cstring): pointer = urGlProc(name),
    gpuIsEs: proc (): bool = true,
    gpuGeneration: proc (): int = int(urGlGen()),
    gpuReady: proc (): bool = urGlReady() != 0)

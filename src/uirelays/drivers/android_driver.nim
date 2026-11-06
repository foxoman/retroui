# Android backend driver. Sets all hooks from core/input and core/screen.
# android_glue.c runs the app on its own thread under a NativeActivity,
# queues its input and puts its pixels in the window; surface_driver turns
# that into relays.
#
# Build with `--os:android --cpu:arm64 --app:lib --noMain` into libmain.so
# and pack it into an APK whose activity is android.app.NativeActivity (or
# android/UiRelaysActivity.java); see README.md.

import ../input, ../screen
import surface_driver

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

proc initAndroidDriver*() =
  ## Points the relays at Android: the surface driver's, and OpenGL ES on
  ## the window.
  initSurfaceDriver(androidKey)
  # OpenGL ES on the window (android_glue.c: EGL, opened at run time)
  gpuRelays = GpuRelays(
    startGpu: proc (): bool = urGlStart() != 0,
    stopGpu: proc () = urGlStop(),
    swapGpu: proc (): bool = urGlSwap() != 0,
    gpuProc: proc (name: cstring): pointer = urGlProc(name),
    gpuIsEs: proc (): bool = true,
    gpuGeneration: proc (): int = int(urGlGen()),
    gpuReady: proc (): bool = urGlReady() != 0)

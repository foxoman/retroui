# iOS backend driver. Sets all hooks from core/input and core/screen.
# uikit_backend.m starts UIKit, shows the app's pixels and queues touches
# and keys; surface_driver turns that into relays.
#
# Build on a Mac: compile the app with `--os:macosx -d:ios` and the iOS
# SDK's clang, and put it in an .app bundle (see README.md).

import ../input
import surface_driver

{.compile("uikit_backend.m", "-fobjc-arc").}
{.passL: "-framework UIKit -framework Foundation -framework CoreGraphics " &
         "-framework CoreText -framework QuartzCore".}

proc hidKey(code: int32): KeyCode =
  ## USB HID keyboard usages (UIKeyboardHIDUsage) to ours.
  case code
  of 4..29: KeyCode(ord(KeyA) + code - 4)         # a..z
  of 30..38: KeyCode(ord(Key1) + code - 30)       # 1..9
  of 39: Key0
  of 58..69: KeyCode(ord(KeyF1) + code - 58)      # F1..F12
  of 40, 88: KeyEnter                             # Return, keypad Enter
  of 41: KeyEsc
  of 42: KeyBackspace
  of 43: KeyTab
  of 44: KeySpace
  of 45: KeyMinus
  of 47: KeyLeftBracket
  of 48: KeyRightBracket
  of 49: KeyBackslash
  of 51: KeySemicolon
  of 52: KeyQuote
  of 53: KeyBackquote
  of 46: KeyEqual
  of 54: KeyComma
  of 55: KeyPeriod
  of 56: KeySlash
  of 57: KeyCapslock
  of 73: KeyInsert
  of 74: KeyHome
  of 75: KeyPageUp
  of 76: KeyDelete
  of 77: KeyEnd
  of 78: KeyPageDown
  of 79: KeyRight
  of 80: KeyLeft
  of 81: KeyDown
  of 82: KeyUp
  of 87: KeyPlus                                  # keypad +
  else: KeyNone

proc initUIKitDriver*() = initSurfaceDriver(hidKey)
  ## Points the relays at iOS (the surface driver's, with its keys).

## X's keysyms -- X11's, and the ones xkbcommon hands out on Wayland and
## elsewhere -- as our keys; and, without xkbcommon, what a US keyboard
## types on each of Linux's (evdev) key codes.

import ../input

const
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
  XK_slash = 0x2f'u
  XK_KP_Enter = 0xff8d'u
  XK_KP_0 = 0xffb0'u
  XK_KP_9 = 0xffb9'u

proc keyOfSym*(ks: uint): KeyCode =
  ## The key of keysym `ks` (KeyNone: none of ours).
  if ks >= XK_a and ks <= XK_z:
    return KeyCode(ord(KeyA) + (ks.int - XK_a.int))
  # With Shift (or Caps Lock) down, X hands over the capital's keysym. It is
  # the same key: a press has to say so, and a release all the more -- the
  # release of W is what stops the running, Shift or not.
  if ks >= XK_CapitalA and ks <= XK_CapitalZ:
    return KeyCode(ord(KeyA) + (ks.int - XK_CapitalA.int))
  if ks >= XK_0 and ks <= XK_9:
    return KeyCode(ord(Key0) + (ks.int - XK_0.int))
  if ks >= XK_F1 and ks <= XK_F12:
    return KeyCode(ord(KeyF1) + (ks.int - XK_F1.int))
  # the keypad's keys are the keys they stand for, as on the other systems:
  # its digits with Num Lock on, else its arrows, Home, End, Insert, Delete
  if ks >= XK_KP_0 and ks <= XK_KP_9:
    return KeyCode(ord(Key0) + (ks.int - XK_KP_0.int))
  case ks.uint
  of XK_KP_Enter: KeyEnter
  of 0xff80'u: KeySpace                 # XK_KP_Space
  of 0xff89'u: KeyTab                   # XK_KP_Tab
  of 0xff95'u: KeyHome                  # XK_KP_Home
  of 0xff96'u: KeyLeft                  # XK_KP_Left
  of 0xff97'u: KeyUp                    # XK_KP_Up
  of 0xff98'u: KeyRight                 # XK_KP_Right
  of 0xff99'u: KeyDown                  # XK_KP_Down
  of 0xff9a'u: KeyPageUp                # XK_KP_Page_Up
  of 0xff9b'u: KeyPageDown              # XK_KP_Page_Down
  of 0xff9c'u: KeyEnd                   # XK_KP_End
  of 0xff9e'u: KeyInsert                # XK_KP_Insert
  of 0xff9f'u: KeyDelete                # XK_KP_Delete
  of 0xffab'u: KeyPlus                  # XK_KP_Add
  of 0xffac'u: KeyComma                 # XK_KP_Separator
  of 0xffad'u: KeyMinus                 # XK_KP_Subtract
  of 0xffae'u: KeyPeriod                # XK_KP_Decimal
  of 0xffaf'u: KeySlash                 # XK_KP_Divide
  of 0xffbd'u: KeyEqual                 # XK_KP_Equal
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
  of XK_slash, 0x3f'u: KeySlash
  of 0x5b'u, 0x7b'u: KeyLeftBracket
  of 0x5d'u, 0x7d'u: KeyRightBracket
  of 0x3b'u, 0x3a'u: KeySemicolon
  of 0x27'u, 0x22'u: KeyQuote
  of 0x5c'u, 0x7c'u: KeyBackslash
  of 0x60'u, 0x7e'u: KeyBackquote
  of XK_equal: KeyEqual
  else: KeyNone

const usKeys: array[0 .. 58, (uint, uint)] = [
  ## evdev key code -> keysym, unshifted and with Shift (a US keyboard)
  (0'u, 0'u), (0xff1b'u, 0xff1b'u),                                 # 0, 1 Esc
  (0x31'u, 0x21'u), (0x32'u, 0x40'u), (0x33'u, 0x23'u), (0x34'u, 0x24'u), (0x35'u, 0x25'u),
  (0x36'u, 0x5e'u), (0x37'u, 0x26'u), (0x38'u, 0x2a'u), (0x39'u, 0x28'u), (0x30'u, 0x29'u),
  (0x2d'u, 0x5f'u), (0x3d'u, 0x2b'u), (0xff08'u, 0xff08'u), (0xff09'u, 0xfe20'u),   # 12 .. 15
  (0x71'u, 0x51'u), (0x77'u, 0x57'u), (0x65'u, 0x45'u), (0x72'u, 0x52'u), (0x74'u, 0x54'u),
  (0x79'u, 0x59'u), (0x75'u, 0x55'u), (0x69'u, 0x49'u), (0x6f'u, 0x4f'u), (0x70'u, 0x50'u),
  (0x5b'u, 0x7b'u), (0x5d'u, 0x7d'u), (0xff0d'u, 0xff0d'u), (0xffe3'u, 0xffe3'u),   # 26 .. 29
  (0x61'u, 0x41'u), (0x73'u, 0x53'u), (0x64'u, 0x44'u), (0x66'u, 0x46'u), (0x67'u, 0x47'u),
  (0x68'u, 0x48'u), (0x6a'u, 0x4a'u), (0x6b'u, 0x4b'u), (0x6c'u, 0x4c'u), (0x3b'u, 0x3a'u),
  (0x27'u, 0x22'u), (0x60'u, 0x7e'u), (0xffe1'u, 0xffe1'u), (0x5c'u, 0x7c'u),       # 40 .. 43
  (0x7a'u, 0x5a'u), (0x78'u, 0x58'u), (0x63'u, 0x43'u), (0x76'u, 0x56'u), (0x62'u, 0x42'u),
  (0x6e'u, 0x4e'u), (0x6d'u, 0x4d'u), (0x2c'u, 0x3c'u), (0x2e'u, 0x3e'u), (0x2f'u, 0x3f'u),
  (0xffe2'u, 0xffe2'u), (0xffaa'u, 0xffaa'u), (0xffe9'u, 0xffe9'u), (0x20'u, 0x20'u), # 54 .. 57
  (0xffe5'u, 0xffe5'u)]                                             # 58 Caps Lock

proc usKeysym*(code: int; shift: bool): uint =
  ## What a US keyboard types on evdev key code `code` (0: nothing known).
  if code >= usKeys.low and code <= usKeys.high:
    return if shift: usKeys[code][1] else: usKeys[code][0]
  case code
  of 59 .. 68: 0xffbe'u + uint(code - 59)       # F1 .. F10
  of 87: 0xffc8'u                                # F11
  of 88: 0xffc9'u                                # F12
  of 96: 0xff8d'u                                # the keypad's Enter
  of 97: 0xffe4'u                                # right Ctrl
  of 100: 0xffea'u                               # right Alt
  of 102: 0xff50'u                               # Home
  of 103: 0xff52'u                               # Up
  of 104: 0xff55'u                               # Page Up
  of 105: 0xff51'u                               # Left
  of 106: 0xff53'u                               # Right
  of 107: 0xff57'u                               # End
  of 108: 0xff54'u                               # Down
  of 109: 0xff56'u                               # Page Down
  of 110: 0xff63'u                               # Insert
  of 111: 0xffff'u                               # Delete
  of 125: 0xffeb'u                               # left Super
  of 126: 0xffec'u                               # right Super
  of 127: 0xff67'u                               # Menu
  of 71 .. 73, 75 .. 77, 79 .. 82:               # the keypad's digits (Num Lock on)
    const kp = [7, 8, 9, -1, 4, 5, 6, -1, 1, 2, 3, 0]
    let d = kp[code - 71]
    if d >= 0: 0xffb0'u + uint(d) else: 0'u
  of 74: 0xffad'u                                # KP -
  of 78: 0xffab'u                                # KP +
  of 83: 0xffae'u                                # KP .
  of 98: 0xffaf'u                                # KP /
  else: 0'u

proc symText*(ks: uint): string =
  ## The text a keysym types: Latin-1's and Unicode's (0x01000000 + code
  ## point) keysyms, and the keypad's; "" for the others.
  var cp = -1
  if ks >= 0x20 and ks <= 0x7e or ks >= 0xa0 and ks <= 0xff: cp = int(ks)
  elif ks >= 0x01000100'u and ks <= 0x0110ffff'u: cp = int(ks - 0x01000000'u)
  elif ks >= 0xffb0'u and ks <= 0xffb9'u: cp = int(ks - 0xffb0'u) + 0x30
  else:
    case ks
    of 0xffaa'u: cp = 0x2a
    of 0xffab'u: cp = 0x2b
    of 0xffad'u: cp = 0x2d
    of 0xffae'u: cp = 0x2e
    of 0xffaf'u: cp = 0x2f
    of 0xff80'u: cp = 0x20
    else: discard
  if cp < 0: return ""
  if cp < 0x80: result.add char(cp)
  elif cp < 0x800:
    result.add char(0xC0 or (cp shr 6))
    result.add char(0x80 or (cp and 0x3F))
  elif cp < 0x10000:
    result.add char(0xE0 or (cp shr 12))
    result.add char(0x80 or ((cp shr 6) and 0x3F))
    result.add char(0x80 or (cp and 0x3F))
  else:
    result.add char(0xF0 or (cp shr 18))
    result.add char(0x80 or ((cp shr 12) and 0x3F))
    result.add char(0x80 or ((cp shr 6) and 0x3F))
    result.add char(0x80 or (cp and 0x3F))

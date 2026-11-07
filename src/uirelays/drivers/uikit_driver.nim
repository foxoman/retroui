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
  of 84: KeySlash                                 # keypad /
  of 86: KeyMinus                                 # keypad -
  of 87: KeyPlus                                  # keypad +
  of 89..97: KeyCode(ord(Key1) + code - 89)       # keypad 1..9
  of 98: Key0                                     # keypad 0
  of 99: KeyPeriod                                # keypad .
  of 103: KeyEqual                                # keypad =
  of 133: KeyComma                                # keypad ,
  else: KeyNone

proc initUIKitAccess*()

proc initUIKitDriver*() =
  initSurfaceDriver(hidKey)
  initUIKitAccess()
  ## Points the relays at iOS (the surface driver's, with its keys).

# ---- screen readers (VoiceOver) ----

import ../access, ../services

type
  UrAccessNode {.bycopy.} = object
    ## (uikit_backend.m's, field for field)
    nodeId: uint32
    parent, role: cint
    states: uint32
    x, y, w, h: cint
    lo, hi, now, step: float64
    caret, selA, selB, pos, count, level: cint
    name, value, help, key: cstring

proc urAccessUpdate(nodes: ptr UrAccessNode; n, focus: cint) {.importc: "uirelays_access_update", cdecl.}
proc urAccessTake(action: ptr cint; id: ptr uint32; num: ptr float64; text: ptr cstring): cint
  {.importc: "uirelays_access_take", cdecl.}
proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>".}

proc uikitAccessUpdate(nodes: openArray[AccessNode]; focus: int) =
  var arr = newSeq[UrAccessNode](nodes.len)
  for i, n in nodes:
    arr[i] = UrAccessNode(nodeId: n.id, parent: n.parent.cint, role: ord(n.role).cint,
                          states: uint32(cast[uint16](n.states)),
                          x: n.x.cint, y: n.y.cint, w: n.w.cint, h: n.h.cint,
                          lo: n.lo, hi: n.hi, now: n.now, step: n.step,
                          name: cstring(n.name), value: cstring(n.value),
                          help: cstring(n.help), key: cstring(n.key))
  urAccessUpdate(if arr.len > 0: addr arr[0] else: nil, arr.len.cint, focus.cint)

proc takeAccessAsks() =
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

var basePoll: proc (e: var Event; flags: set[InputFlag]): bool {.nimcall.}
var baseWait: proc (e: var Event; t: int; flags: set[InputFlag]): bool {.nimcall.}

proc initUIKitAccess*() =
  ## Screen readers (VoiceOver): the tree given to the view, what it asks
  ## taken with every event.
  basePoll = inputRelays.pollEvent
  baseWait = inputRelays.waitEvent
  inputRelays.pollEvent = proc (e: var Event; flags: set[InputFlag]): bool =
    result = basePoll(e, flags)
    takeAccessAsks()
  inputRelays.waitEvent = proc (e: var Event; t: int; flags: set[InputFlag]): bool =
    result = baseWait(e, t, flags)
    takeAccessAsks()
  accessRelays = AccessRelays(start: proc (): bool = true, update: uikitAccessUpdate)

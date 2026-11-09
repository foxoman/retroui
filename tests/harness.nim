## A fake uirelays driver for headless tests: scripted input in, pixels
## kept in memory.

import retroui/uirelays/[coords, screen, input]
import retroui

const W* = 640
const H* = 480

var
  queue*: seq[Event]
  pixels* = newSeq[uint32](W * H)
  ticks* = 1000
  clip = ""
  view*: proc ()     ## the UI under test, run once per frame

proc fakeDriver*() =
  # (the same keys on every system: a Mac's Option + a letter picks the
  # underlined one here, as Alt does elsewhere)
  optionLetters = true
  windowRelays.createWindow = proc (l: var ScreenLayout; icon: pointer;
                                    iconLen: int) =
    l.width = W; l.height = H; l.scaleX = 1; l.scaleY = 1; l.uiScale = 100
  windowRelays.getWindowLayout = proc (): ScreenLayout =
    ScreenLayout(width: W, height: H, scaleX: 1, scaleY: 1, uiScale: 100)
  windowRelays.refresh = proc () = discard
  windowRelays.setWindowTitle = proc (t: string) = discard
  windowRelays.setCursor = proc (c: CursorKind) = discard
  drawRelays.blitRGBA = proc (p: ptr UncheckedArray[uint32]; w, h: int;
                              dst: Rect; f: RGBAFormat): bool =
    for y in 0 ..< h:
      for x in 0 ..< w: pixels[(dst.y + y) * W + dst.x + x] = p[y * w + x]
    true
  inputRelays.pollEvent = proc (e: var Event; fl: set[InputFlag]): bool =
    if queue.len == 0: return false
    e = queue[0]
    queue.delete(0)
    true
  inputRelays.waitEvent = proc (e: var Event; t: int;
                                fl: set[InputFlag]): bool =
    inputRelays.pollEvent(e, fl)
  inputRelays.getTicks = proc (): int = ticks
  inputRelays.shutdown = proc () = discard
  clipboardRelays.getText = proc (): string = clip
  clipboardRelays.putText = proc (t: string) = clip = t
  # no system fonts: what the built-in fonts lack is measured as nothing
  fontRelays.openFont = proc (path: string; size: int; style: FontStyles;
                              metrics: var FontMetrics): Font = Font(0)
  fontRelays.closeFont = proc (f: Font) = discard
  fontRelays.getFontMetrics = proc (f: Font): FontMetrics = FontMetrics()
  fontRelays.measureText = proc (f: Font; text: string): TextExtent = TextExtent()
  fontRelays.drawText = proc (f: Font; x, y: int; text: string;
                              fg, bg: Color): TextExtent = TextExtent()
  fontRelays.drawMeasuredText = nil

proc down*(x, y: int; clicks = 1) =
  queue.add Event(kind: MouseMoveEvent, x: x, y: y)
  queue.add Event(kind: MouseDownEvent, x: x, y: y, button: LeftButton,
                  clicks: clicks)
proc up*(x, y: int) =
  queue.add Event(kind: MouseUpEvent, x: x, y: y, button: LeftButton)
proc move*(x, y: int) =
  queue.add Event(kind: MouseMoveEvent, x: x, y: y)
proc key*(k: KeyCode; mods: set[Modifier] = {}) =
  queue.add Event(kind: KeyDownEvent, key: k, mods: mods)
  queue.add Event(kind: KeyUpEvent, key: k, mods: mods)
proc typeText*(s: string) =
  ## Like a keyboard: a key press (without Ctrl) comes before each character.
  for c in s:
    queue.add Event(kind: KeyDownEvent, key: KeyNone)
    var e = Event(kind: TextInputEvent)
    e.text[0] = c
    queue.add e
proc closeWindow*() =
  ## The window's close box (or the phone's Back).
  queue.add Event(kind: WindowCloseEvent)
proc px*(x, y: int): uint32 = pixels[y * W + x] and 0xFFFFFF'u32

proc run*(n = 1) =
  ## Run frames until the scripted input is used up (at least `n`).
  var i = 0
  var tail = 1
  while i < n or queue.len > 0 or tail > 0:
    if i >= n and queue.len == 0: dec tail
    discard beginFrame()
    view()
    endFrame()
    inc i
    ticks += 16

proc click*(r: Rect; dx = 10; dy = -1; clicks = 1) =
  ## Press and release inside `r` (`dy` -1: the middle).
  let x = r.x + dx
  let y = r.y + (if dy < 0: r.h div 2 else: dy)
  down(x, y, clicks)
  run()
  up(x, y)
  run()

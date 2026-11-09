## Headless tests: a fake uirelays driver feeds scripted input and keeps
## the pixels, so no window or display is needed -- the relay idea at work.
##
##   nimble test

import retroui/uirelays/[coords, screen, input]
import retroui

const W = 320
const H = 240

var
  queue: seq[Event]
  pixels = newSeq[uint32](W * H)
  blits = 0
  ticks = 1000
  clip = ""

proc fakeDriver() =
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
    inc blits
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

proc down(x, y: int) =
  queue.add Event(kind: MouseMoveEvent, x: x, y: y)
  queue.add Event(kind: MouseDownEvent, x: x, y: y, button: LeftButton, clicks: 1)
proc up(x, y: int) =
  queue.add Event(kind: MouseUpEvent, x: x, y: y, button: LeftButton)
proc key(k: KeyCode; mods: set[Modifier] = {}) =
  queue.add Event(kind: KeyDownEvent, key: k, mods: mods)
  queue.add Event(kind: KeyUpEvent, key: k, mods: mods)
proc typeText(s: string) =
  for c in s:
    var e = Event(kind: TextInputEvent)
    e.text[0] = c
    queue.add e
proc px(x, y: int): uint32 = pixels[y * W + x] and 0xFFFFFF'u32

var
  clicks = 0
  checked = false
  name = ""
  sel = 0
  showDlg = false
  okRect, checkRect, editRect: Rect
  hotOk = false
  backs, closes = 0
  keepOpen = false

proc ui1() =
  if keepOpen and closeRequested():
    if backPressed(): inc backs else: inc closes
    cancelClose()
  if button("&OK", isDefault = true): inc clicks
  okRect = ui.lastRect
  hotOk = hovered(okRect)
  checkbox "&Check me", checked
  checkRect = ui.lastRect
  edit name
  editRect = ui.lastRect
  listbox ["one", "two", "three"], sel, rows = 3
  dialog showDlg, "Dialog", 200:
    label "Modal"

proc run(n = 1) =
  ## Run frames until the scripted input is used up (at least `n`).
  var i = 0
  var tail = 1   # one more frame for an event the loop already peeked at
  while i < n or queue.len > 0 or tail > 0:
    if i >= n and queue.len == 0: dec tail
    discard beginFrame()
    ui1()
    endFrame()
    inc i
    ticks += 16

fakeDriver()
startApp("test", W, H)
run(3)

block pixelsOnScreen:
  doAssert blits > 0, "the frame was put on screen"
  doAssert px(0, 0) == 0xFFFFFF, "window background is white"
  let c = point(okRect.x + 6, okRect.y + okRect.h div 2)
  doAssert px(c.x, c.y) == 0xC0C0C0, "button face is 3.1 gray"
  doAssert px(okRect.x + 1, okRect.y) == 0, "the default button's ring is black"
  doAssert px(okRect.x + 2, okRect.y + 2) == 0, "button outline is black"
  doAssert px(okRect.x + 3, okRect.y + 3) == 0xFFFFFF, "its edge is white at the top left"
  doAssert px(okRect.x + 4, okRect.y + 4) == 0xDFDFDF, "with the softer highlight inside"

block unchangedFramesCostNothing:
  let before = blits
  run(3)
  doAssert blits == before, "an unchanged frame is not drawn again"

block mouseClick:
  let c = point(okRect.x + 10, okRect.y + 10)
  down(c.x, c.y)
  run()
  doAssert clicks == 0, "a click happens on release"
  up(c.x, c.y)
  run()
  doAssert clicks == 1

block slideOffCancels:
  down(okRect.x + 10, okRect.y + 10)
  run()
  queue.add Event(kind: MouseMoveEvent, x: 300, y: 230)
  up(300, 230)
  run()
  doAssert clicks == 1, "releasing outside the button does not click"

block enterClicksDefault:
  down(editRect.x + 5, editRect.y + 5)
  up(editRect.x + 5, editRect.y + 5)
  run()
  key(KeyEnter)
  run()
  doAssert clicks == 2, "Enter in an edit clicks the default button"

block typing:
  typeText("Nimx")
  run()
  doAssert name == "Nimx"
  key(KeyBackspace)
  run()
  doAssert name == "Nim"
  key(KeyA, {CtrlPressed})
  key(KeyC, {CtrlPressed})
  run()
  doAssert clip == "Nim", "Ctrl+A, Ctrl+C copies"
  key(KeyEnd)
  key(KeyV, {CtrlPressed})
  run()
  doAssert name == "NimNim"

block tabAndSpace:
  key(KeyTab, {ShiftPressed})
  run()
  key(KeySpace)
  run()
  doAssert checked, "Shift+Tab to the check box, Space toggles it"

block mnemonics:
  key(KeyC, {AltPressed})
  run()
  when defined(macosx):
    # (a Mac types with Option -- no menu letters: the box and the button
    # stay as they were; the rest of the test goes on as if pressed)
    doAssert checked, "Option+C is text on a Mac, not '&Check me'"
    checked = false
    inc clicks
  else:
    doAssert not checked, "Alt+C toggles '&Check me'"
    key(KeyO, {AltPressed})
    run()
    doAssert clicks == 3, "Alt+O clicks '&OK'"

block listKeys:
  key(KeyTab)
  key(KeyTab)
  run()
  key(KeyDown)
  run()
  doAssert sel == 1
  key(KeyEnd)
  run()
  doAssert sel == 2

block modalDialog:
  showDlg = true
  run(2)
  down(okRect.x + 10, okRect.y + 10)
  up(okRect.x + 10, okRect.y + 10)
  run()
  doAssert clicks == 3, "a modal dialog blocks the window under it"
  key(KeyEsc)
  run()
  doAssert not showDlg, "Esc closes the dialog"

block hoverAndBack:
  let c = point(okRect.x + 10, okRect.y + 10)
  queue.add Event(kind: MouseMoveEvent, x: c.x, y: c.y)
  run()
  doAssert hotOk, "a mouse over a button: hovered"
  queue.add Event(kind: MouseMoveEvent, x: W - 2, y: H - 2)
  run()
  doAssert not hotOk
  # a phone: a finger does not hover, a mouse plugged into it does
  ui.touch = true
  down(c.x, c.y)
  up(c.x, c.y)
  run()
  queue.add Event(kind: MouseMoveEvent, x: c.x + 1, y: c.y)
  run()
  doAssert not hotOk, "a lifted finger does not hover"
  queue.add Event(kind: MouseMoveEvent, x: c.x, y: c.y, fromMouse: true)
  run()
  doAssert hotOk, "a mouse on a phone hovers"
  # Back (Esc on a phone) is not Exit
  keepOpen = true
  key(KeyEsc)
  run(2)
  doAssert backs == 1 and closes == 0, "Back: backPressed"
  requestClose()
  run(2)
  doAssert backs == 1 and closes == 1, "Exit: closeRequested, not backPressed"
  keepOpen = false
  ui.touch = false
  run()

echo "all tests passed"

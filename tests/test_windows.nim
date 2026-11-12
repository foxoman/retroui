## Windows besides the program's own (`window`), headless: a fake driver
## that opens them, the window's frame run inside the program's with its
## own `ui` (its size, its pointer, its focus), its events kept for it, its
## pixels sent to it, its close button (the system's, and the caption
## bar's where the system draws no frame), and its closing once it is no
## longer drawn; and a dialog where the system has one window.

import retroui
import retroui/uirelays/[input, screen]
import harness

fakeDriver()

var
  opened: seq[tuple[title: string; w, h: int]]
  closed: seq[int]
  targets: seq[int]
  blits: seq[int]               ## the window each picture went to
  target = 0
proc fakeOpen(title: string; w, h: int): int =
  opened.add (title, w, h)
  opened.len
proc fakeClose(id: int) = closed.add id
proc fakeTitle(id: int; title: string) = discard
proc fakeLayout(id: int): ScreenLayout =
  ScreenLayout(width: 300, height: 200, scaleX: 1, scaleY: 1, uiScale: 100)
proc fakeTarget(id: int) =
  target = id
  targets.add id
windowsRelays = WindowsRelays(openWindow: fakeOpen, closeWindow: fakeClose, setTitle: fakeTitle,
                              layout: fakeLayout, target: fakeTarget)
let mainBlit = drawRelays.blitRGBA
drawRelays.blitRGBA = proc (p: ptr UncheckedArray[uint32]; w, h: int; dst: Rect;
                            f: RGBAFormat): bool =
  blits.add target
  if target == 0: mainBlit(p, w, h, dst, f) else: true

var
  toolsOpen = true
  clicks = 0
  mainClicks = 0
  insideW, insideH = 0
  draw = true
view = proc () =
  if button("Main"): inc mainClicks
  if draw:
    window(toolsOpen, "Tools", 240, 160):
      insideW = ui.w
      insideH = ui.h
      if button("Inside"): inc clicks

startApp("windows", 640, 480)
run(3)
doAssert opened == @[("Tools", 240, 160)], $opened
doAssert insideW == 240 and insideH == 160, $insideW & "x" & $insideH
doAssert 1 in blits and 0 in blits, $blits          # both windows got their pictures
doAssert target == 0                                  # the program's window is the target again

# a click in the tools window: its button, not the program's (at the same place)
queue.add Event(kind: MouseMoveEvent, x: 20, y: 18, window: 1)
queue.add Event(kind: MouseDownEvent, x: 20, y: 18, button: LeftButton, clicks: 1, window: 1)
run(2)
queue.add Event(kind: MouseUpEvent, x: 20, y: 18, button: LeftButton, window: 1)
run(3)
doAssert clicks == 1 and mainClicks == 0, $clicks & " " & $mainClicks

# the program's window: its own button
down(20, 18)
run(2)
up(20, 18)
run(3)
doAssert mainClicks == 1 and clicks == 1, $clicks & " " & $mainClicks

# the window made bigger by the user
queue.add Event(kind: WindowResizeEvent, x: 400, y: 300, window: 1)
run(3)
doAssert insideW == 400 and insideH == 300, $insideW & "x" & $insideH

# its close button: `open` false, the window closed
queue.add Event(kind: WindowCloseEvent, window: 1)
run(3)
doAssert not toolsOpen and closed == @[1], $closed
doAssert ui.running                                   # (the program goes on)

# opened again, then no longer drawn: closed by itself
toolsOpen = true
run(3)
doAssert opened.len == 2
draw = false
run(3)
doAssert closed == @[1, 2], $closed

# a window the system draws no frame round (Wayland without one): the
# caption bar, Windows 95's close button at its right closes it; 3.1's
# buttons: none (its control menu closes it)
proc unframed(id: int): bool = false
windowsRelays.framed = unframed
draw = true
toolsOpen = true
run(3)
doAssert toolsOpen and opened.len == 3
let s = MenuH - 6
proc clickTools(x, y: int) =
  queue.add Event(kind: MouseMoveEvent, x: x, y: y, window: 3)
  queue.add Event(kind: MouseDownEvent, x: x, y: y, button: LeftButton, clicks: 1, window: 3)
  run(2)
  queue.add Event(kind: MouseUpEvent, x: x, y: y, button: LeftButton, window: 3)
  run(3)
captionButtons = cbWin31
run(2)
clickTools(insideW - 3 - s div 2, 3 + s div 2)
doAssert toolsOpen, "3.1: no close button"
captionButtons = cbWin95
run(2)
clickTools(insideW - 3 - s div 2, 3 + s div 2)
doAssert not toolsOpen and closed == @[1, 2, 3], $closed
windowsRelays.framed = nil

# a system with one window: a dialog over the app
windowsRelays = WindowsRelays()
draw = true
toolsOpen = true
insideW = 0
run(3)
doAssert insideW == 640 and opened.len == 3           # (in a dialog of the program's window)
echo "test_windows: ok"

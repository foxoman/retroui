## The screen driver (`fb_driver`: no windowing system) checked by itself:
## the screen a file (`RETRO_FB_FILE`), the input devices a pipe
## (`RETRO_FB_INPUT`) this app writes the kernel's input events into, as a
## keyboard, a mouse and a touch screen would. What it checks: the whole
## screen is the app's, touches and clicks, typing (the system's layout
## through libxkbcommon, or the US one), a mouse moved by so many counts,
## the pointer drawn and hidden, the wheel, every pixel on the screen the
## app's frame, Ctrl+Alt+Backspace closing it. Lines PASS / FAIL, then
## "DONE n" (n failures); the exit code is n.
##
##   sh tests/kiosk/run.sh

import std/[os, posix, strutils]
import retroui
import retroui/uirelays/screen
import retroui/uirelays/drivers/fb_driver

var
  step = 0
  stepFrames = 0
  failed = 0
  clicks = 0
  name = "start"
  items: seq[string]
  sel = 0
  scrolled = 0
  btnR, editR, listR, noteR: Rect
  pipeFd: cint = -1
  mouseAt, touchedAt: (int, int)
  wanted: (int, int)

for i in 1 .. 60: items.add "Row " & $i

proc check(ok: bool; what: string) =
  echo (if ok: "PASS " else: "FAIL "), what
  if not ok: inc failed

proc next() =
  inc step
  stepFrames = 0

type Ev = object
  sec, usec: culong
  typ, code: uint16
  value: int32

proc ev(typ, code: int; value: int) =
  if pipeFd < 0:
    pipeFd = posix.open(cstring(getEnv("RETRO_FB_INPUT").split(',')[0]), O_WRONLY or O_NONBLOCK)
  var e = Ev(typ: uint16(typ), code: uint16(code), value: int32(value))
  discard posix.write(pipeFd, addr e, sizeof(e))

proc syn() = ev(0, 0, 0)
proc key(code: int; down: bool) = (ev(1, code, ord(down)); syn())
proc tap(code: int; shift = false) =
  if shift: key(42, true)
  key(code, true)
  key(code, false)
  if shift: key(42, false)
proc touch(x, y: int) =
  ev(3, 0, x); ev(3, 1, y); ev(1, 0x14a, 1); syn()
  ev(1, 0x14a, 0); syn()
proc centre(r: Rect): (int, int) = (r.x + r.w div 2, r.y + r.h div 2)

const typed = "Hello, kiosk!"
proc typeText(s: string) =
  const codes = {'q': 16, 'w': 17, 'e': 18, 'r': 19, 't': 20, 'y': 21, 'u': 22, 'i': 23,
                 'o': 24, 'p': 25, 'a': 30, 's': 31, 'd': 32, 'f': 33, 'g': 34, 'h': 35,
                 'j': 36, 'k': 37, 'l': 38, 'z': 44, 'x': 45, 'c': 46, 'v': 47, 'b': 48,
                 'n': 49, 'm': 50, ',': 51, ' ': 57, '1': 2}
  for c in s:
    let shifted = c in {'A' .. 'Z', '!'}
    let base = if c == '!': '1' else: c.toLowerAscii
    for (k, v) in codes:
      if k == base:
        tap(v, shifted)
        break

proc screenIsFrame(): (int, int) =
  ## (pixels differing, pixels compared) between the screen and the frame
  let pic = framePicture()
  if pic == nil: return (-1, 0)
  let l = getWindowLayout()
  let bits16 = getEnv("RETRO_FB_FILE").endsWith(":16")
  for y in 0 ..< min(pic.h, l.height):
    for x in 0 ..< min(pic.w, l.width):
      let a = pic.px[y * pic.w + x]
      let b = fbScreenPixel(x, y)
      let same =
        if bits16:
          # (RGB565: what is left of each after the screen's bits)
          ((a shr 19) and 31) == ((b shr 19) and 31) and ((a shr 10) and 63) == ((b shr 10) and 63) and
            ((a shr 3) and 31) == ((b shr 3) and 31)
        else: (a and 0xFFFFFF) == (b and 0xFFFFFF)
      if not same: inc result[0]
      inc result[1]

app "fbcheck", 640, 480:
  inc stepFrames
  wakeIn(20)
  label "The screen alone"
  if button("&Press"): inc clicks
  btnR = ui.lastRect
  edit name
  editR = ui.lastRect
  discard listbox(items, sel, rows = 8)
  listR = ui.lastRect
  label "clicks " & $clicks & ", name " & name & ", row " & $(sel + 1)
  noteR = ui.lastRect
  if ui.wheel != 0 and hover(listR): inc scrolled
  mouseAt = (ui.mx, ui.my)
  case step
  of 0:
    if stepFrames > 3:
      let l = getWindowLayout()
      let want = getEnv("RETRO_FB_FILE").split(':')[1].split('x')
      check(fbScreenKind() == "file" and $l.width == want[0] and $l.height == want[1] and l.fullScreen,
            "the whole screen: " & $l.width & " x " & $l.height & " (" & fbScreenKind() & ")")
      let (x, y) = centre(btnR)
      touch(x, y)
      touch(x, y)
      next()
  of 1:
    if clicks >= 2 or stepFrames > 100:
      check(clicks == 2, "two touches on the button: " & $clicks)
      let (x, y) = centre(editR)
      touch(x, y)
      key(29, true); tap(30); key(29, false)               # Ctrl+A
      typeText(typed)
      next()
  of 2:
    if name == typed or stepFrames > 100:
      check(name == typed, "typed: " & name)
      let (x, y) = centre(listR)
      touch(x, y)
      touchedAt = (x, y)
      tap(108)                                             # Down
      tap(108)
      next()
  of 3:
    if sel >= 2 or stepFrames > 100:
      check(sel >= 2, "the list took a touch and the arrow keys: row " & $(sel + 1))
      # a mouse moved slowly (no speeding up at that pace) from where the touch was
      wanted = (touchedAt[0] + 20, touchedAt[1] - 10)
      for i in 0 ..< 10:
        ev(2, 0, 2); ev(2, 1, -1); syn()
      next()
  of 4:
    if mouseAt == wanted or stepFrames > 100:
      check(mouseAt == wanted, "the mouse moved by its counts: " & $mouseAt & " (" & $wanted & ")")
      # (the pointer drawn where it is: the arrow's black tip at the hot spot)
      let tip = fbScreenPixel(mouseAt[0], mouseAt[1]) and 0xFFFFFF
      check(tip <= 0x000001, "the pointer drawn on the screen: " & toHex(tip, 6))
      ev(2, 8, -2); syn()                                  # the wheel, two notches down
      next()
  of 5:
    if scrolled > 0 or stepFrames > 100:
      check(scrolled > 0, "the wheel over the list")
      ev(1, 0x110, 1); syn(); ev(1, 0x110, 0); syn()       # a click where the mouse is
      next()
  of 6:
    if stepFrames > 10:
      # a touch hides the pointer: the screen is then the frame, pixel for pixel
      let (x, y) = centre(noteR)
      touch(x, y)
      next()
  of 7:
    if stepFrames > 10:
      let (bad, all) = screenIsFrame()
      check(bad == 0 and all > 0, "the screen shows the frame: " & $bad & " of " & $all & " pixels differ")
      echo "DONE ", failed
      # Ctrl+Alt+Backspace: the app asked to close
      key(29, true); key(56, true); tap(14); key(56, false); key(29, false)
      next()
  of 8:
    if stepFrames > 200:
      check(false, "Ctrl+Alt+Backspace did not close the app")
      quit failed
  else: discard

## The Wayland driver against a real compositor (sway, headless; see
## `run.sh`): the app opens full screen, then plays its own virtual mouse
## and keyboard (`vinput`) at its widgets and checks what came -- a click,
## typing, the wheel, Ctrl+A, the clipboard both ways (wl-copy, wl-paste)
## -- and that what the compositor shows (grim) is, pixel for pixel, what
## the app drew. A line per check (PASS / FAIL) on the standard output;
## the exit code is the number of failures.
##
##   tests/wayland/run.sh            (builds, starts sway, runs this at
##                                    100% and 150%)

import std/[os, osproc, strutils, streams, times]
import retroui
import retroui/imaging
import retroui/uirelays/screen

var
  step = 0
  stepAt = 0.0
  clicks = 0
  name = "start"
  items = newSeq[string]()
  listSel = 0
  failed = 0
  vin, paster, copier: Process
  pressR, editR, listR: Rect
  firstTop = -1
  scale120 = 120

for i in 1 .. 60: items.add "Item " & $i

proc check(ok: bool; what: string) =
  echo (if ok: "PASS " else: "FAIL "), what
  if not ok: inc failed

proc send(cmds: varargs[string]) =
  for c in cmds:
    vin.inputStream.writeLine c
  vin.inputStream.flush()

proc at(r: Rect): string =
  ## The middle of `r` (the app's pixels) on the screen, in the
  ## compositor's units, as `vinput`'s `abs` takes it.
  let l = getWindowLayout()
  let k = zoomLevel()
  let sw = l.width * 120 div scale120
  let sh = l.height * 120 div scale120
  let x = (r.x + r.w div 2) * k * 120 div scale120
  let y = (r.y + r.h div 2) * k * 120 div scale120
  "abs " & $x & " " & $y & " " & $sw & " " & $sh

proc shownMatches(): bool =
  ## grim's picture of the screen is what the app drew.
  let file = getTempDir() / "wlcheck-shown.png"
  if execCmd("grim " & quoteShell(file)) != 0: return false
  let shown = decodePng(readFile(file))
  let drawn = framePicture()
  removeFile(file)
  if shown == nil or drawn == nil:
    echo "  (no picture)"
    return false
  if shown.w != drawn.w or shown.h != drawn.h:
    echo "  sizes: shown ", shown.w, "x", shown.h, ", drawn ", drawn.w, "x", drawn.h
    return false
  var diff = 0
  var box = (x0: drawn.w, y0: drawn.h, x1: -1, y1: -1)
  for y in 0 ..< drawn.h:
    for x in 0 ..< drawn.w:
      let i = y * drawn.w + x
      if x >= drawn.w - 4 and y >= drawn.h - 4: continue   # (the pointer's tip)
      if (shown.px[i] and 0xFFFFFF) != (drawn.px[i] and 0xFFFFFF):
        inc diff
        box = (min(box.x0, x), min(box.y0, y), max(box.x1, x), max(box.y1, y))
  if diff > 0:
    echo "  ", diff, " pixels differ, in ", box
    let dir = getEnv("WLCHECK_SAVE")
    if dir.len > 0:
      discard shown.savePng(dir / "shown.png")
      discard drawn.savePng(dir / "drawn.png")
  diff == 0

proc wait(seconds: float): bool =
  ## This step has had `seconds` (and frames go on meanwhile).
  wakeIn(30)
  epochTime() - stepAt >= seconds

proc next() =
  inc step
  stepAt = epochTime()

app "wlcheck", 640, 420:
  scale120 = max(120, getWindowLayout().uiScale * 120 div 100)
  label "The Wayland driver, checked"
  if button("&Press"): inc clicks
  pressR = ui.lastRect
  edit name
  editR = ui.lastRect
  discard listbox(items, listSel, rows = 8)
  listR = ui.lastRect
  label "clicks " & $clicks & ", name " & name
  case step
  of 0:
    stepAt = epochTime()
    vin = startProcess(getEnv("VINPUT", "vinput"), options = {poStdErrToStdOut})
    next()
  of 1:
    if wait(1.0):
      let l = getWindowLayout()
      check(l.width > 0 and l.height > 0, "a window: " & $l.width & " x " & $l.height &
            " at " & $l.uiScale & "%")
      send(at(pressR), "click", "wait 100", "click")
      next()
  of 2:
    if clicks >= 2 or wait(3.0):
      check(clicks == 2, "two clicks on the button: " & $clicks)
      send(at(editR), "click", "key ctrl+a", "type Hello, Wayland!")
      next()
  of 3:
    if name == "Hello, Wayland!" or wait(4.0):
      check(name == "Hello, Wayland!", "typed: " & name)
      send("key backspace", "key shift+home", "key ctrl+c")
      next()
  of 4:
    if wait(1.0):
      # (the app goes on while wl-paste asks it for the text)
      paster = startProcess("wl-paste", args = ["-n"], options = {poUsePath})
      next()
  of 5:
    if not paster.running or wait(5.0):
      let pasted = paster.outputStream.readAll
      check(paster.peekExitCode == 0 and pasted == "Hello, Wayland",
            "copied out (wl-paste): " & pasted.strip)
      paster.close()
      copier = startProcess("wl-copy", args = ["Grüße ✓ 你好"], options = {poUsePath})
      next()
  of 6:
    if wait(0.8):
      send(at(editR), "click", "key ctrl+a", "key ctrl+v")
      next()
  of 7:
    if name == "Grüße ✓ 你好" or wait(3.0):
      check(name == "Grüße ✓ 你好", "pasted in (wl-copy): " & name)
      firstTop = listSel
      send(at(listR), "click", "wheel -3")
      next()
  of 8:
    if wait(1.5):
      check(listSel >= 0, "the list took a click: item " & $(listSel + 1))
      send("key down", "key down")
      next()
  of 9:
    if wait(1.0):
      check(listSel >= 2, "the arrow keys in the list: item " & $(listSel + 1))
      # (the pointer off to the corner: the compositor draws it over the window)
      let l = getWindowLayout()
      let sw = l.width * 120 div scale120
      let sh = l.height * 120 div scale120
      send("abs " & $(sw - 1) & " " & $(sh - 1) & " " & $sw & " " & $sh)
      next()
  of 10:
    if wait(1.0):
      check(shownMatches(), "what the compositor shows is what was drawn")
      next()
  of 11:
    vin.inputStream.close()
    discard vin.waitForExit(2000)
    vin.close()
    if copier != nil:
      copier.terminate()
      copier.close()
    echo if failed == 0: "ALL PASS" else: $failed & " FAILED"
    quitApp()
    next()
  else: discard

quit failed

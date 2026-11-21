## Retro Atelier's keys as the three programs' help has them, headless: a tool's letter held
## (the tool while it is, the one before after), tapped (the new one stays); Shift+Alt and a
## letter (a blend mode: the brush's, the layer's with the Move tool), Shift with + and - (the
## next and the one before), Shift and the numbers (the brush's flow); F2-F4; and Edit > Fade,
## Paste Outside, Paste in Place, Split Channels, Proof Setup's color blindness from their names.

import std/[strutils, os]
import retroui/uirelays/input
import harness

const photoUnderTest = true
include ../examples/photo

let home = getTempDir() / "retro-photo-keystest"
removeDir(home)
createDir(home)
putEnv("HOME", home)
setCurrentDir(home)

fakeDriver()
setup()
startApp("photo", W, H)
view = photoFrame
run(3)

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

proc keyDown(k: KeyCode; mods: set[Modifier] = {}) = queue.add Event(kind: KeyDownEvent, key: k, mods: mods)
proc keyUp(k: KeyCode; mods: set[Modifier] = {}) = queue.add Event(kind: KeyUpEvent, key: k, mods: mods)

proc sample(): Doc =
  result = newDoc(60, 40, 0xFFFFFFFF'u32, name = "keys.png")
  let L = result.layer
  for y in 0 ..< 40:
    for x in 0 ..< 60: L.px[y * 60 + x] = if (x div 5) mod 2 == 0: 0xFF102030'u32 else: 0xFFE0D0C0'u32
  inc L.ver
  result.markAll()
  result.modified = false

let d = sample()
addDoc(d)
run(2)

block springLoaded:
  key(KeyV)
  run(2)
  check tool == tMove, "V: the Move tool"
  # held a moment: the brush while it is, the Move tool after
  keyDown(KeyB)
  run(2)
  check tool == tBrush, "B held: the brush"
  ticks += 800
  keyDown(KeyB)                    # (the key repeating: nothing more)
  run(2)
  check tool == tBrush, "still the brush while B repeats"
  keyUp(KeyB)
  run(2)
  check tool == tMove, "B let go after a moment: the Move tool again"
  # tapped: the brush stays
  keyDown(KeyB)
  run(1)
  keyUp(KeyB)
  run(2)
  check tool == tBrush, "B tapped: the brush stays"
  # held and used (a click): back once the button is up
  key(KeyV)
  run(2)
  keyDown(KeyE)
  run(2)
  check tool == tEraser, "E held: the eraser"
  let (sx, sy) = active.view.toScreen(d, 30, 20)
  down(sx, sy)
  run(1)
  keyUp(KeyE)
  run(1)
  check tool == tEraser, "let go while erasing: the eraser till the stroke ends"
  up(sx, sy)
  run(2)
  check tool == tMove, "the stroke done: the Move tool again"
  runCommand("Undo")
  run(1)

block modes:
  key(KeyB)
  run(2)
  key(KeyM, {ShiftPressed, AltPressed})
  run(2)
  check PaintModes[opts[tBrush].mode] == bmMultiply, "Shift+Alt+M: the brush in Multiply"
  key(KeyEqual, {ShiftPressed})
  run(2)
  check PaintModes[opts[tBrush].mode] == bmColorBurn, "Shift and +: the next mode (Color Burn)"
  key(KeyMinus, {ShiftPressed})
  run(2)
  check PaintModes[opts[tBrush].mode] == bmMultiply, "Shift and -: back to Multiply"
  key(KeyN, {ShiftPressed, AltPressed})
  run(2)
  check PaintModes[opts[tBrush].mode] == bmNormal, "Shift+Alt+N: Normal"
  key(Key5, {ShiftPressed})
  run(2)
  check opts[tBrush].dyn.flow == 50, "Shift+5: the brush's flow 50%"
  ticks += 1000                    # (not typed right after the 5: 57%)
  key(Key7)
  run(2)
  check opts[tBrush].opacity == 70, "7: its opacity 70%"
  # the Move tool: the layer's mode
  d.layersChange("New Layer"): discard d.addLayer("Top")
  key(KeyV)
  run(2)
  key(KeyS, {ShiftPressed, AltPressed})
  run(2)
  check d.current.mode == bmScreen, "Shift+Alt+S with the Move tool: the layer in Screen"
  key(KeyQ, {ShiftPressed, AltPressed})
  run(2)
  check d.current.mode == bmScreen, "Behind is for painting: the layer stays in Screen"
  d.undo()
  d.undo()

block fKeysAndPaste:
  d.cur = 0
  d.beginStep("Select")
  d.touchSel()
  d.setSelection(d.rectMask(rect(10, 10, 20, 10)))
  d.endStep()
  key(KeyF3)
  run(2)
  check hasClip and clip.w == 20 and clip.x == 10, "F3: copied"
  let n0 = d.layers.len
  runCommand("Paste in Place")
  run(1)
  check d.layers.len == n0 + 1 and (d.current.px[15 * 60 + 15] shr 24) == 255 and d.current.px[5 * 60 + 5] == 0,
        "Paste in Place: where it was"
  d.beginStep("Select")
  d.touchSel()
  d.setSelection(d.rectMask(rect(12, 12, 4, 4)))
  d.endStep()
  runCommand("Paste Outside")
  run(1)
  check (d.current.px[13 * 60 + 13] shr 24) == 0 and (d.current.px[11 * 60 + 25] shr 24) == 255,
        "Paste Outside: hidden inside the selection, shown round it"
  d.undo()
  d.undo()
  d.undo()

block fade:
  d.cur = 0
  let before = d.layer.px
  d.beginStep("Gaussian Blur")
  d.applyFilter(12, gaussianBlur(3.0))
  d.endStep()
  let blurred = d.layer.px
  runCommand("Fade...")
  run(2)
  check fadeBox.open, "Edit > Fade: its box"
  fadeBox.opacity = 0
  run(2)
  check d.layer.px == before, "Fade at 0%: as before the blur, live"
  fadeBox.opacity = 100
  run(2)
  check d.layer.px == blurred, "at 100%: the blur"
  fadeBox.opacity = 0
  run(1)
  fadeBox.open = false            # (closed by its X: Cancel)
  run(2)
  check d.layer.px == blurred and d.undoName == "Gaussian Blur" and not d.canRedo,
        "Cancel: the blur as it was, nothing left to redo"

block channelsAndProof:
  let n = docs.len
  runCommand("Split Channels")
  run(2)
  check docs.len == n + 3 and docs[^3].doc.name == "keys_Red" and docs[^1].doc.mode == cmGray,
        "Split Channels: three gray images"
  runCommand("Merge Channels...")
  run(2)
  check mergeBox.open and mergeBox.pick[0] == n and mergeBox.pick[2] == n + 2,
        "Merge Channels: its box, the three gray images picked in turn"
  mergeBox.open = false
  active = docs[0]
  run(1)
  runCommand("Proof Setup: Color Blindness - Protanopia-type")
  run(2)
  check proofSetup == 1 and active.doc.blindView == 1, "Proof Setup: Protanopia shown"
  runCommand("CMYK Preview")
  run(2)
  check active.doc.blindView == 0, "Proof Colors: off again"
  runCommand("CMYK Preview")
  run(2)
  check active.doc.blindView == 1, "and on (the proof Proof Setup chose)"
  runCommand("Proof Setup: Working CMYK")
  run(2)
  check proofSetup == 0 and active.doc.blindView == 0 and active.doc.proof, "Working CMYK: the inks"
  runCommand("CMYK Preview")
  run(1)

if failures > 0:
  echo "test_photokeys: ", failures, " failed"
  quit(1)
echo "test_photokeys: all passed"

## The hand pass of Retro Atelier, run headless: every tool of the toolbar, as its group gives
## it, used on a picture as a person would -- through the window's input, not the tools' own
## procs -- with a mouse (a click, a drag, Shift, Alt and Ctrl held, a double click), a finger
## on a touch screen (a tap, a drag, a long press) and a pen (pressure, its eraser end); then
## Enter, Esc, the arrows, Delete. Nothing may fail (a fault the program caught fails the test
## too), and everything done is taken back by undoing it all: the picture as it was.

import std/[strutils, os]
import retroui/uirelays/input
import harness

const photoUnderTest = true
include ../examples/photo

let home = getTempDir() / "retro-photo-handpass"
removeDir(home)
createDir(home)
putEnv("HOME", home)
setCurrentDir(home)

fakeDriver()
setup()
startApp("photo", W, H)
view = photoFrame
run(3)

proc picture(): Doc =
  ## (a picture with something everywhere -- the tools that read it have something to read --
  ## a layer painted, a text in a box and a shape over it)
  result = newDoc(320, 220, 0xFFFFFFFF'u32, name = "hand")
  let bg = result.layers[0]
  for y in 0 ..< result.h:
    for x in 0 ..< result.w:
      let r = (x * 255) div result.w
      let g = (y * 255) div result.h
      let b = if ((x div 20) + (y div 20)) mod 2 == 0: 200 else: 60
      bg.px[y * result.w + x] = 0xFF000000'u32 or (uint32(r) shl 16) or (uint32(g) shl 8) or uint32(b)
  let P = result.addLayer("Paint")
  for y in 120 ..< 180:
    for x in 40 ..< 140: P.px[y * result.w + x] = 0xFFC03030'u32
  var t = newText("Words in a box to work on.", typeStyle, 170, 20)
  t.boxW = 130
  t.boxH = 80
  discard result.addTextLayer(t)
  discard result.addShapeLayer(ShapeData(path: ellipsePath(200, 120, 300, 200), fill: solidPaint(0xFF3060C0'u32)),
                               "Ellipse")
  result.cur = 1
  result.markAll()
  result.modified = false

proc mouse(kind: EventKind; x, y: int; mods: set[Modifier] = {}; clicks = 1; finger = false; pen = false;
           pressure = 0.0'f32; eraser = false) =
  var e = Event(kind: kind, x: x, y: y, mods: mods, fromMouse: not finger, pen: pen, pressure: pressure)
  if kind in {MouseDownEvent, MouseUpEvent}:
    e.button = LeftButton
    e.clicks = clicks
  if eraser: e.twist = -1
  queue.add e

proc stroke(a, b: (int, int); mods: set[Modifier] = {}; finger = false; pen = false; eraser = false;
            hold = 0) =
  ## (down at `a`, moved to `b` in steps, up there)
  mouse(MouseMoveEvent, a[0], a[1], mods, finger = finger, pen = pen)
  mouse(MouseDownEvent, a[0], a[1], mods, finger = finger, pen = pen, pressure = 0.4, eraser = eraser)
  run(1)
  if hold > 0:
    ticks += hold
    run(2)
  for k in 1 .. 6:
    let x = a[0] + (b[0] - a[0]) * k div 6
    let y = a[1] + (b[1] - a[1]) * k div 6
    mouse(MouseMoveEvent, x, y, mods, finger = finger, pen = pen, pressure = 0.3 + k.float32 * 0.1,
          eraser = eraser)
    run(1)
  mouse(MouseUpEvent, b[0], b[1], mods, finger = finger, pen = pen)
  run(2)

proc fault(where: string) =
  if ui.lastFault.len > 0:
    let f = ui.lastFault
    ui.lastFault = ""
    doAssert false, where & ": " & f

proc noQuit() =
  ## (a finger on the screen: an Esc that nothing took is the phone's Back, which asks
  ## "Quit Retro Atelier?" while pictures are open -- Cancel, or the next Enter quits)
  if quitConfirm:
    key(KeyEsc)
    run(2)
    doAssert not quitConfirm and appRunning(), "Cancel kept the program"

proc settle() =
  ## (what a tool left under way finished or let go: a transform, a crop, typing, a path)
  noQuit()
  for k in [KeyEnter, KeyEsc]:
    key(k)
    run(2)
  if te.on: commitType()
  if xf.on: finishTransform(false)
  if pendingCrop.on: pendingCrop.on = false
  run(2)
  noQuit()

type Act = enum
  aClick = "a click", aAltClick = "Alt+click", aDrag = "a drag", aShiftDrag = "Shift+drag",
  aAltDrag = "Alt+drag", aCtrlDrag = "Ctrl+drag", aDouble = "a double click", aArrows = "the arrows",
  aTap = "a finger's tap", aFingerDrag = "a finger's drag", aLongPress = "a long press",
  aPen = "a pen", aPenEraser = "a pen's eraser end"

let only = getEnv("HANDPASS_TOOL")             # (one tool, by its name: to look at it)
var tried = 0
var found: seq[string]
for g in 0 ..< toolGroups.len:
  for k in 0 ..< toolGroups[g].items.len:
    let name = toolGroups[g].items[k].name
    if only.len > 0 and name != only: continue
    for act in Act:
      let d = picture()
      addDoc(d)
      runCommand("Fit on Screen")
      run(3)
      let before = d.flattened(0)
      let (w0, h0) = (d.w, d.h)
      let dw = active
      pickTool(g, k)
      run(2)
      ui.touch = act in {aTap, aFingerDrag, aLongPress}
      proc at(x, y: float): (int, int) = dw.view.toScreen(d, x, y)
      let a = at(60, 50)
      let b = at(150, 140)
      let c = at(260, 170)
      let where = name & ", " & $act
      case act
      of aClick: stroke(a, a)
      of aAltClick: stroke(c, c, {AltPressed})
      of aDrag: stroke(a, b)
      of aShiftDrag: stroke(b, c, {ShiftPressed})
      of aAltDrag: stroke(c, a, {AltPressed})
      of aCtrlDrag: stroke(a, c, {CtrlPressed})
      of aDouble:
        mouse(MouseMoveEvent, b[0], b[1])
        mouse(MouseDownEvent, b[0], b[1], clicks = 1)
        mouse(MouseUpEvent, b[0], b[1])
        mouse(MouseDownEvent, b[0], b[1], clicks = 2)
        mouse(MouseUpEvent, b[0], b[1])
        run(3)
      of aArrows:
        # (a key at a time, as a person presses them)
        for kk in [KeyLeft, KeyRight, KeyUp, KeyDown]:
          key(kk)
          run(2)
          key(kk, {ShiftPressed})
          run(2)
      of aTap: stroke(a, a, finger = true)
      of aFingerDrag: stroke(a, b, finger = true)
      of aLongPress:
        stroke(c, c, finger = true, hold = 800)
        key(KeyEsc)
        run(2)
      of aPen: stroke(a, b, pen = true)
      of aPenEraser: stroke(b, c, pen = true, eraser = true)
      fault(where)
      settle()
      fault(where & ", then Enter and Esc")
      # everything taken back: as it was
      ui.touch = false
      var n = 0
      while d.canUndo and n < 500:
        d.undo()
        inc n
      run(2)
      fault(where & ", undone")
      var bad = ""
      if d.w != w0 or d.h != h0: bad = "the size not as it was after undoing all"
      else:
        let after = d.flattened(0)
        var differ = 0
        for i in 0 ..< after.len:
          if after[i] != before[i]: inc differ
        if differ > 0: bad = $differ & " pixels not as they were after undoing all"
      for L in d.layers:
        if not (L.px.len == d.w * d.h or L.group or L.px.len == 0): bad = "a layer's pixels the wrong size"
      if bad.len > 0: found.add where & ": " & bad
      inc tried
      closeDoc(dw)
      run(2)

for f in found: echo "  ", f
doAssert found.len == 0, $found.len & " of " & $tried & " not right"
notes.setLen(0)
counts.setLen(0)
slices.setLen(0)
echo "test_handpass: ", tried, " tools and ways, each undone to the picture it began with"

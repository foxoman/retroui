## The pictures of the tutorials (tutorials/*/), made by `make.sh`: as the
## syntax study's (tools/syntaxshots/core.nim), each step's program is whole
## and its `app` runs here instead, on a fake screen at 200 % in the 3.1
## frame; its script (the `#>` lines) feeds it keys and clicks, and `shot`
## saves the screen to $OUT. A close (`closeWindow`) reaches the program
## first: it may ask "Save changes?".

import std/macros

var
  W = 640
  H = 240
  pixels = newSeq[uint32](W * H)
  queue: seq[Event]
  ticks = 1000
  clip = ""
  view: proc () = proc () = discard
  script: proc () = proc () = discard
  marksNow, marks: seq[tuple[spec: string; r: Rect]]
  outDir = getEnv("OUT", "out")
  touchNow = false

const K = 2                      # the pictures' scale: 200 %

proc fakeDriver() =
  windowRelays.createWindow = proc (l: var ScreenLayout; icon: pointer; iconLen: int) =
    l.width = W; l.height = H; l.scaleX = 1; l.scaleY = 1; l.uiScale = 100
  windowRelays.getWindowLayout = proc (): ScreenLayout =
    ScreenLayout(width: W, height: H, scaleX: 1, scaleY: 1, uiScale: 100, touch: touchNow)
  windowRelays.refresh = proc () = discard
  windowRelays.setWindowTitle = proc (t: string) = discard
  windowRelays.setCursor = proc (c: CursorKind) = discard
  drawRelays.blitRGBA = proc (p: ptr UncheckedArray[uint32]; w, h: int;
                              dst: Rect; f: RGBAFormat): bool =
    for y in 0 ..< h:
      for x in 0 ..< w:
        let i = (dst.y + y) * W + dst.x + x
        if i >= 0 and i < pixels.len: pixels[i] = p[y * w + x]
    true
  inputRelays.pollEvent = proc (e: var Event; fl: set[InputFlag]): bool =
    if queue.len == 0: return false
    e = queue[0]
    queue.delete(0)
    true
  inputRelays.waitEvent = proc (e: var Event; t: int; fl: set[InputFlag]): bool =
    inputRelays.pollEvent(e, fl)
  inputRelays.getTicks = proc (): int = ticks
  inputRelays.shutdown = proc () = discard
  clipboardRelays.getText = proc (): string = clip
  clipboardRelays.putText = proc (t: string) = clip = t
  fontRelays.openFont = proc (path: string; size: int; style: FontStyles;
                              metrics: var FontMetrics): Font = Font(0)
  fontRelays.closeFont = proc (f: Font) = discard
  fontRelays.getFontMetrics = proc (f: Font): FontMetrics = FontMetrics()
  fontRelays.measureText = proc (f: Font; text: string): TextExtent = TextExtent()
  fontRelays.drawText = proc (f: Font; x, y: int; text: string;
                              fg, bg: Color): TextExtent = TextExtent()
  fontRelays.drawMeasuredText = nil
  frameRelays.setSystemFrame = proc (on: bool): bool {.nimcall.} = true

proc run(n = 1) =
  var i = 0
  while i < n or queue.len > 0:
    if i > 300:
      echo "too many frames"
      quit 1
    discard beginFrame()
    marksNow.setLen 0
    view()
    endFrame()
    marks = marksNow
    inc i
    ticks += 16

proc resize(w, h: int) =
  W = w
  H = h
  pixels = newSeq[uint32](W * H)
  queue.add Event(kind: WindowResizeEvent, x: W, y: H)
  run(3)

template mark(spec: string) =
  ## The cell of the control just drawn, measured for the picture's notes.
  marksNow.add (spec, ui.lastRect)

proc key(k: KeyCode; mods: set[Modifier] = {}) =
  queue.add Event(kind: KeyDownEvent, key: k, mods: mods, hasMods: true)
  queue.add Event(kind: KeyUpEvent, key: k, mods: mods, hasMods: true)
  run(3)

proc typeText(s: string) =
  for c in s:
    queue.add Event(kind: KeyDownEvent, key: KeyNone)
    var e = Event(kind: TextInputEvent)
    e.text[0] = c
    queue.add e
  run(3)

proc click(x, y: int) =
  ## A click at (x, y) in design pixels.
  queue.add Event(kind: MouseMoveEvent, x: x * K, y: y * K)
  queue.add Event(kind: MouseDownEvent, x: x * K, y: y * K, button: LeftButton, clicks: 1)
  run(2)
  queue.add Event(kind: MouseUpEvent, x: x * K, y: y * K, button: LeftButton)
  run(3)
  queue.add Event(kind: MouseMoveEvent, x: W + 50, y: H + 50)
  run(2)

proc frames(n: int) = run(n)

proc closeWindow() =
  ## The window's close box (a phone's Back).
  queue.add Event(kind: WindowCloseEvent)
  run(3)

proc clickMark(i: int; fx = 0.5; fy = 0.5) =
  ## A click on the cell `mark` measured as the i-th of the frame.
  let r = marks[i].r
  click((r.x + int(r.w.float * fx)) div K, (r.y + int(r.h.float * fy)) div K)

proc phone(w, h: int) =
  ## The same app on a touch screen `w` x `h` design pixels.
  touchNow = true
  resize(w * K, h * K)
  run(4)

proc shot(name: string) =
  ## The screen as a PNG, and the measured cells (in design pixels) beside it.
  run(2)
  let b = newBitmap(W, H)
  for i in 0 ..< W * H: b.px[i] = pixels[i] or 0xFF000000'u32
  createDir(outDir)
  writeFile(outDir / name & ".png", encodePng(b, level = 9))
  var j = newJArray()
  for m in marks:
    j.add %*{"spec": m.spec, "x": m.r.x, "y": m.r.y, "w": m.r.w, "h": m.r.h}
  writeFile(outDir / name & ".json", $(%*{"scale": K, "w": W, "h": H, "marks": j}))
  echo "  ", name, ".png  ", W, "x", H

proc appRun(title: string; w, h: int; theme: Theme; draw: proc ()) =
  touchNow = false
  setUiScale(100 * K)
  ui.theme = theme
  setTitle(title)
  setClassicFrame(true)
  view = proc () =
    captionBar()
    draw()
    if closeRequested(): cancelClose()      # (the program did not keep it open: here it stays)
  resize(w * K, h * K)
  queue.add Event(kind: MouseMoveEvent, x: W + 50, y: H + 50)
  run(4)
  if ui.pageOn: echo "  ", title, ": ", (ui.pageMax + K - 1) div K, " design pixels more needed"
  script()
  view = proc () = discard
  ui.focus = 0
  ui.popup = 0

macro app(args: varargs[untyped]): untyped =
  ## `app` as the kit has it (title, width, height, options, the block),
  ## run on the fake screen: the theme is the one option the pictures show.
  let body = args[^1]
  var theme: NimNode = ident"Classic"
  for i in 3 ..< args.len - 1:
    let a = args[i]
    if a.kind == nnkExprEqExpr:
      if a[0].eqIdent("theme"): theme = a[1]
    else: theme = a
  let draw = newProc(body = body, procType = nnkLambda)
  result = newCall(ident"appRun", args[0], args[1], args[2], theme, draw)

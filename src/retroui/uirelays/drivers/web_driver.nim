## A browser page, for a program built as WebAssembly (`-d:wasm`): its
## window is a canvas the program draws into as pixels (`PixBuf`), shown
## with only what changed copied (`rw_present`); the keyboard and the mouse
## (a pen, a finger) come from the page, text typed through a hidden text
## box (so the browser's own input methods and dead keys work), text in
## the system's fonts drawn by the page's canvas (every script, shaped),
## the clipboard through the page's copy and paste, links opened in a tab.
##
## The page's side is `retro.js` (`RetroWeb`): the `rw_*` functions here are
## its, imported by name (the linker lets them through). The driver never
## waits: the page runs a frame when something happened or the program
## asked for one, so `waitEvent` takes what is there and returns.

import ../[coords, input, screen, services, access]
import pixbuf
import std/[strutils, os]

type
  WebEvent {.bycopy.} = object
    ## (filled by the page: `rw_event`)
    kind, x, y, button, clicks, mods, flags: int32
    key: array[24, char]          ## KeyboardEvent.code; the text of a text event
    dx, dy, pressure: float32

const
  weMove = 1'i32
  weDown = 2'i32
  weUp = 3'i32
  weWheel = 4'i32
  weKeyDown = 5'i32
  weKeyUp = 6'i32
  weText = 7'i32
  weResize = 8'i32
  weFocus = 9'i32
  weBlur = 10'i32
  weHide = 11'i32
  weShow = 12'i32
  weCompose = 13'i32
  weLeave = 14'i32
  weClose = 15'i32
  weDrop = 16'i32

proc rwWindowOpen(title: cstring; w, h, flags: cint) {.importc: "rw_window_open", cdecl.}
proc rwWindowSize(out3: ptr array[3, int32]) {.importc: "rw_window_size", cdecl.}
proc rwPresent(px: pointer; stride, x, y, w, h, fullW, fullH: cint) {.importc: "rw_present", cdecl.}
proc rwTitle(s: cstring) {.importc: "rw_title", cdecl.}
proc rwCursor(kind: cint) {.importc: "rw_cursor", cdecl.}
proc rwEvent(e: ptr WebEvent): cint {.importc: "rw_event", cdecl.}
proc rwEventText(p: pointer; cap: cint): cint {.importc: "rw_event_text", cdecl.}
proc rwClipPut(p: cstring; n: cint) {.importc: "rw_clip_put", cdecl.}
proc rwClipGet(p: pointer; cap: cint): cint {.importc: "rw_clip_get", cdecl.}
proc rwFontOpen(size, bold, italic, mono: cint): cint {.importc: "rw_font_open", cdecl.}
proc rwFontMetrics(f: cint; out3: ptr array[3, int32]) {.importc: "rw_font_metrics", cdecl.}
proc rwTextWidth(f: cint; s: cstring; n: cint): cint {.importc: "rw_text_width", cdecl.}
proc rwTextRender(f: cint; s: cstring; n: cint; outp: pointer; cap: cint): cint {.importc: "rw_text_render", cdecl.}
proc rwOpenUrl(s: cstring): cint {.importc: "rw_open_url", cdecl.}
proc rwTextCaret(x, y, w, h: cint) {.importc: "rw_text_caret", cdecl.}
proc rwWantText(on: cint) {.importc: "rw_want_text", cdecl.}
proc rwOpenFile(path: cstring): cint {.importc: "rw_open_file", cdecl.}
proc rwCall(name, arg: cstring; outp: pointer; cap: cint): cint {.importc: "rw_call", cdecl.}
proc rwAccess(text: cstring; n, focus: cint) {.importc: "rw_access", cdecl.}

var
  pb: PixBuf
  frame: seq[uint32]            ## the window's pixels (the page copies from here)
  winW, winH, winScale = 0
  queue: seq[input.Event]
  lastCursor = -1
  lastClick: tuple[t, x, y, n: int; b: MouseButton]
  fonts: seq[tuple[h: cint; m: FontMetrics]]
  clipboardText: string

proc ticks(): int =
  proc clock_gettime(c: cint; ts: ptr array[2, int64]): cint {.importc, header: "<time.h>".}
  var ts: array[2, int64]
  discard clock_gettime(1, addr ts)
  int(ts[0] * 1000 + ts[1] div 1_000_000)

proc readSize() =
  var s: array[3, int32]
  rwWindowSize(addr s)
  winW = max(1, s[0].int)
  winH = max(1, s[1].int)
  winScale = max(25, s[2].int)
  if frame.len != winW * winH:
    frame = newSeq[uint32](winW * winH)
  pb.attach(cast[ptr UncheckedArray[uint32]](addr frame[0]), winW, winH, winW)

proc layoutNow(): ScreenLayout =
  ScreenLayout(width: winW, height: winH, scaleX: 1, scaleY: 1, uiScale: winScale)

proc webCreateWindow(layout: var ScreenLayout; icon: pointer; iconLen: int) =
  rwWindowOpen("", cint(layout.width), cint(layout.height), 0)
  readSize()
  layout = layoutNow()

proc webRefresh() =
  let d = pb.takeDamage()
  if d.w <= 0 or d.h <= 0 or frame.len == 0: return
  rwPresent(addr frame[0], cint(winW), cint(d.x), cint(d.y), cint(d.w), cint(d.h),
            cint(winW), cint(winH))

proc webSetCursor(c: CursorKind) =
  if ord(c) != lastCursor:
    lastCursor = ord(c)
    rwCursor(cint(ord(c)))

proc keyOfCode(code: string): KeyCode =
  ## KeyboardEvent.code (the key's place, whatever the layout) as our key.
  if code.len == 4 and code.startsWith("Key") and code[3] in 'A' .. 'Z':
    return KeyCode(ord(KeyA) + ord(code[3]) - ord('A'))
  if code.len == 6 and code.startsWith("Digit") and code[5] in '0' .. '9':
    return KeyCode(ord(Key0) + ord(code[5]) - ord('0'))
  if code.len == 7 and code.startsWith("Numpad") and code[6] in '0' .. '9':
    return KeyCode(ord(Key0) + ord(code[6]) - ord('0'))
  if code.len in 2 .. 3 and code[0] == 'F' and code[1] in '1' .. '9':
    var n = 0
    for c in code[1 .. ^1]: n = n * 10 + ord(c) - ord('0')
    if n in 1 .. 12: return KeyCode(ord(KeyF1) + n - 1)
  case code
  of "Enter", "NumpadEnter": KeyEnter
  of "Space": KeySpace
  of "Escape": KeyEsc
  of "Tab": KeyTab
  of "Backspace": KeyBackspace
  of "Delete": KeyDelete
  of "Insert": KeyInsert
  of "ArrowLeft": KeyLeft
  of "ArrowRight": KeyRight
  of "ArrowUp": KeyUp
  of "ArrowDown": KeyDown
  of "PageUp": KeyPageUp
  of "PageDown": KeyPageDown
  of "Home": KeyHome
  of "End": KeyEnd
  of "CapsLock": KeyCapslock
  of "Comma", "NumpadComma": KeyComma
  of "Period", "NumpadDecimal": KeyPeriod
  of "Slash", "NumpadDivide": KeySlash
  of "Minus", "NumpadSubtract": KeyMinus
  of "Equal", "NumpadEqual": KeyEqual
  of "NumpadAdd": KeyPlus
  of "BracketLeft": KeyLeftBracket
  of "BracketRight": KeyRightBracket
  of "Semicolon": KeySemicolon
  of "Quote": KeyQuote
  of "Backslash": KeyBackslash
  of "Backquote": KeyBackquote
  of "ContextMenu": KeyMenu
  else: KeyNone

proc modsOf(m: int32): set[Modifier] =
  if (m and 1) != 0: result.incl ShiftPressed
  if (m and 2) != 0: result.incl CtrlPressed
  if (m and 4) != 0: result.incl AltPressed
  if (m and 8) != 0: result.incl GuiPressed

proc textOf(e: WebEvent): string =
  for c in e.key:
    if c == '\0': break
    result.add c

proc takeText(e: WebEvent): string =
  ## A text event's whole text (longer than `key` holds: asked for).
  let n = rwEventText(nil, 0)
  if n <= 0: return textOf(e)
  result = newString(n)
  discard rwEventText(addr result[0], cint(n + 1))

proc pushText(s: string) =
  var i = 0
  while i < s.len:
    var te = input.Event(kind: TextInputEvent)
    var k = 0
    while true:
      if k < te.text.len: te.text[k] = s[i]
      inc k
      inc i
      if i >= s.len or (s[i].uint8 and 0xC0) != 0x80: break
    queue.add te

proc translate(w: WebEvent) =
  let mods = modsOf(w.mods)
  case w.kind
  of weMove:
    var e = input.Event(kind: MouseMoveEvent, x: w.x, y: w.y, hasMods: true, mods: mods,
                        fromMouse: (w.flags and 1) != 0, pen: (w.flags and 2) != 0,
                        pressure: w.pressure)
    if queue.len > 0 and queue[^1].kind == MouseMoveEvent: queue[^1] = e
    else: queue.add e
  of weDown, weUp:
    let b = case w.button
      of 1: MiddleButton
      of 2: RightButton
      of 3: BackButton
      of 4: ForwardButton
      else: LeftButton
    var e = input.Event(kind: if w.kind == weDown: MouseDownEvent else: MouseUpEvent,
                        x: w.x, y: w.y, button: b, hasMods: true, mods: mods,
                        fromMouse: (w.flags and 1) != 0, pen: (w.flags and 2) != 0,
                        pressure: w.pressure)
    if w.kind == weDown:
      let now = ticks()
      let near = max(4, 4 * winScale div 100)
      if b == lastClick.b and now - lastClick.t < 500 and abs(w.x - lastClick.x) < near and
         abs(w.y - lastClick.y) < near:
        inc lastClick.n
      else:
        lastClick.n = 1
      lastClick = (now, w.x.int, w.y.int, lastClick.n, b)
      e.clicks = lastClick.n
    queue.add e
  of weLeave:
    queue.add input.Event(kind: MouseMoveEvent, x: OutsideWindow, y: OutsideWindow,
                          hasMods: true, mods: mods)
  of weWheel:
    queue.add input.Event(kind: MouseWheelEvent, x: int(w.dx), y: int(w.dy),
                          hasMods: true, mods: mods)
  of weKeyDown, weKeyUp:
    queue.add input.Event(kind: if w.kind == weKeyDown: KeyDownEvent else: KeyUpEvent,
                          key: keyOfCode(textOf(w)), hasMods: true, mods: mods)
  of weText:
    pushText(takeText(w))
  of weCompose:
    var e = input.Event(kind: TextEditingEvent, composing: takeText(w))
    e.x = w.x
    queue.add e
  of weResize:
    readSize()
    queue.add input.Event(kind: WindowMetricsEvent, x: winW, y: winH, scaleX: 1, scaleY: 1,
                          uiScale: winScale)
  of weFocus: queue.add input.Event(kind: WindowFocusGainedEvent)
  of weBlur: queue.add input.Event(kind: WindowFocusLostEvent)
  of weHide: queue.add input.Event(kind: AppPauseEvent)
  of weShow: queue.add input.Event(kind: AppResumeEvent)
  of weClose: queue.add input.Event(kind: WindowCloseEvent)
  of weDrop:
    # (files dropped: the page put them in /tmp/dropped; their paths, one a line)
    var files: seq[string]
    var cur = ""
    for c in takeText(w):
      if c == '\n':
        if cur.len > 0: files.add cur
        cur = ""
      else: cur.add c
    if cur.len > 0: files.add cur
    if files.len > 0:
      queue.add input.Event(kind: FileDropEvent, files: files, x: w.x, y: w.y)
  else: discard

proc drain() =
  var w: WebEvent
  while rwEvent(addr w) != 0:
    translate(w)

proc webEventsWaiting*(): bool =
  ## Events read from the page and not yet taken (the next frame should
  ## come at once).
  queue.len > 0

proc takeAccess()

proc webPollEvent(e: var input.Event; flags: set[InputFlag]): bool =
  rwWantText(cint(WantTextInput in flags))
  if queue.len == 0:
    if accessListening: takeAccess()
    drain()
  if queue.len == 0: return false
  e = queue[0]
  queue.delete(0)
  when defined(webDebug): echo "event ", e.kind, " ", e.key, " ", e.text, " left ", queue.len
  true

proc webWaitEvent(e: var input.Event; timeoutMs: int; flags: set[InputFlag]): bool =
  ## (never waits: the page runs the frames)
  webPollEvent(e, flags)

# ---- drawing ----

proc webFill(r: Rect; c: Color) = pb.fill(r, c)
proc webLine(x1, y1, x2, y2: int; c: Color) = pb.line(x1, y1, x2, y2, c)
proc webPoint(x, y: int; c: Color) = pb.point(x, y, c)
proc webBlit(p: ptr UncheckedArray[uint32]; w, h: int; dst: Rect; f: RGBAFormat): bool =
  pb.blit(p, w, h, dst, f)
proc webDraw(p: ptr UncheckedArray[uint32]; w, h: int; dst: Rect; f: RGBAFormat): bool =
  pb.draw(p, w, h, dst, f)
proc webClip(r: Rect) = pb.setClip(r)
proc webSave() = discard
proc webRestore() = pb.noClip()

# ---- text in the page's fonts ----

proc webOpenFont(path: string; size: int; style: FontStyles; metrics: var FontMetrics): Font =
  let mono = path.len == 0 or "mono" in path or "courier" in path or "consol" in path
  let h = rwFontOpen(cint(size), cint(FontStyle.bold in style), cint(FontStyle.italics in style),
                     cint(mono))
  if h <= 0: return Font(0)
  var m: array[3, int32]
  rwFontMetrics(h, addr m)
  metrics = FontMetrics(ascent: m[0], descent: m[1], lineHeight: m[2])
  fonts.add (h, metrics)
  Font(fonts.len)

proc fontOf(f: Font): int =
  let i = f.int - 1
  if i >= 0 and i < fonts.len: i else: -1

proc webCloseFont(f: Font) = discard
proc webFontMetrics(f: Font): FontMetrics =
  let i = fontOf(f)
  if i >= 0: fonts[i].m else: FontMetrics()

proc webMeasure(f: Font; text: string): TextExtent =
  let i = fontOf(f)
  if i < 0 or text.len == 0: return
  TextExtent(w: rwTextWidth(fonts[i].h, cstring(text), cint(text.len)), h: fonts[i].m.lineHeight)

proc coverage(i: int; text: string; w, h: var int): seq[uint8] =
  h = fonts[i].m.lineHeight
  w = rwTextWidth(fonts[i].h, cstring(text), cint(text.len))
  if w <= 0 or h <= 0: return
  result = newSeq[uint8](w * h)
  discard rwTextRender(fonts[i].h, cstring(text), cint(text.len), addr result[0], cint(result.len))

proc webRenderText(f: Font; text: string; fg: Color; pixels: var seq[uint32]): TextExtent =
  pixels.setLen 0
  let i = fontOf(f)
  if i < 0 or text.len == 0: return
  var w, h: int
  let cov = coverage(i, text, w, h)
  if cov.len == 0: return
  pixels.setLen w * h
  for k in 0 ..< w * h:
    let a = cov[k].uint32 * fg.a.uint32 div 255
    pixels[k] = (a shl 24) or ((fg.r.uint32 * a div 255) shl 16) or
                ((fg.g.uint32 * a div 255) shl 8) or (fg.b.uint32 * a div 255)
  TextExtent(w: w, h: h)

proc webDrawText(f: Font; x, y: int; text: string; fg, bg: Color): TextExtent =
  let i = fontOf(f)
  if i < 0 or text.len == 0: return
  var w, h: int
  let cov = coverage(i, text, w, h)
  result = TextExtent(w: w, h: h)
  if cov.len == 0: return
  pb.fill(Rect(x: x, y: y, w: w, h: h), bg)
  pb.cover(cov, w, h, x, y, fg)

# ---- the clipboard, links ----

proc webGetClip(): string =
  let n = rwClipGet(nil, 0)
  if n <= 0: return clipboardText
  result = newString(n)
  discard rwClipGet(addr result[0], cint(n + 1))

proc webPutClip(text: string) =
  clipboardText = text
  rwClipPut(cstring(text), cint(text.len))

proc webCall(name, arg: string): string =
  ## The page's answer to a system call (`SystemRelays.call`); "\0" when
  ## the page has no such call.
  var buf = newString(256)
  var n = rwCall(cstring(name), cstring(arg), addr buf[0], cint(buf.len))
  if n < 0: return "\0"
  if n >= buf.len:
    buf = newString(n + 1)
    n = rwCall(cstring(name), cstring(arg), addr buf[0], cint(buf.len))
    if n < 0: return "\0"
  buf.setLen(n)
  buf

# ---- screen readers: the tree mirrored as ARIA in the page (retro.js) ----

proc webAccessStart(): bool =
  ## (a page cannot tell whether a screen reader reads it: the tree is kept
  ## unless the page said no -- `Retro.boot({ accessible: false })`)
  accessListening = webCall("access.on", "") == "1"
  accessListening

proc webAccessUpdate(nodes: openArray[AccessNode]; focus: int) =
  proc addText(t: var string; s: string) =
    for c in s:
      t.add(if c in {'\t', '\n', '\r'}: ' ' else: c)
  var t = newStringOfCap(nodes.len * 64)
  for n in nodes:
    var bits = 0
    for st in n.states: bits = bits or (1 shl ord(st))
    t.add $n.id & '\t' & $n.parent & '\t' & $ord(n.role) & '\t' & $bits & '\t' & $n.x & '\t' &
          $n.y & '\t' & $n.w & '\t' & $n.h & '\t'
    t.addText n.name
    t.add '\t'
    t.addText(if asProtected in n.states: "" else: n.value)
    t.add '\t'
    t.addText n.help
    t.add '\t' & $n.lo & '\t' & $n.hi & '\t' & $n.now & '\t' & $n.pos & '\t' & $n.count & '\t' &
          $n.level & '\t'
    t.addText n.key
    t.add '\n'
  rwAccess(cstring(t), cint(t.len), cint(focus))

proc takeAccess() =
  ## What the screen reader pressed (a click on a control's ARIA element).
  let s = webCall("access.take", "")
  if s.len == 0 or s == "\0": return
  for line in s.splitLines:
    let f = line.split('\t')
    if f.len >= 2 and f[0] == "press":
      try: accessRequests.add AccessRequest(action: aaPress, id: uint32(parseBiggestUInt(f[1])))
      except ValueError: discard
  queue.add input.Event(kind: NoEvent)

proc webTicks(): int = ticks()
proc webSleep(ms: int) = discard
proc webShutdown() = discard

proc initWebDriver*() =
  windowRelays = WindowRelays(
    createWindow: webCreateWindow, getWindowLayout: layoutNow, refresh: webRefresh,
    saveState: webSave, restoreState: webRestore, setClipRect: webClip,
    setCursor: webSetCursor, setWindowTitle: proc (t: string) = rwTitle(cstring(t)))
  fontRelays = FontRelays(openFont: webOpenFont, closeFont: webCloseFont,
                          getFontMetrics: webFontMetrics, measureText: webMeasure,
                          drawText: webDrawText, renderText: webRenderText)
  drawRelays = DrawRelays(fillRect: webFill, drawLine: webLine, drawPoint: webPoint,
                          blitRGBA: webBlit, drawRGBA: webDraw)
  inputRelays = InputRelays(pollEvent: webPollEvent, waitEvent: webWaitEvent,
                            getTicks: webTicks, sleep: webSleep, shutdown: webShutdown)
  clipboardRelays = ClipboardRelays(getText: webGetClip, putText: webPutClip)
  textCaretRelay = proc (x, y, w, h: int) = rwTextCaret(cint(x), cint(y), cint(w), cint(h))
  systemRelays.openUrl = proc (url: string): bool = rwOpenUrl(cstring(url)) != 0
  systemRelays.platform = proc (): string = "web"
  systemRelays.openFile = proc (path: string; share: bool): bool =
    # (the user's own copy: downloaded)
    rwOpenFile(cstring(path)) != 0
  systemRelays.dataDir = proc (app: string): string =
    # (made on demand, as on every system: in the page's storage, kept)
    result = "/data/" & app
    try: createDir(result)
    except OSError, IOError: discard
  accessRelays = AccessRelays(start: webAccessStart, update: webAccessUpdate,
    announce: proc (text: string) = discard webCall("access.say", text))
  systemRelays.call = proc (name, arg: string): string {.gcsafe.} =
    {.cast(gcsafe).}: webCall(name, arg)
  systemRelays.places = proc (): seq[tuple[name, path: string]] =
    # (what the app writes in Downloads is handed to the user)
    @[("Home", "/home/web"), ("Downloads", "/downloads")]

## How long a frame takes, with a fake driver (pure library cost: layout,
## widget logic, rasterizing). Run:  nimble bench
##
## Each line: a change (an input, a value, the whole window invalidated)
## and the frames it takes to be on the screen -- their time together, how
## many they are, the pixels sent.
##
## `RETRO_GPU=gpu nimble bench`: the same frames drawn with OpenGL, into an
## off-screen surface (EGL; Mesa's llvmpipe where there is no GPU -- a
## software GPU, slower than the CPU's own drawing), each frame waited for
## (glFinish) so that its time is the GPU's work too. Built with
## `-d:nimAllocStats`, each line also says how many blocks of memory a frame
## takes (0 is the aim for a frame where little changed).

import std/[monotimes, times, strutils, os]
import retroui/uirelays/[coords, screen, input, eglload]
import retroui

const W = 800
const H = 600

var
  pixelsOut = 0
  ticks = 0

windowRelays.createWindow = proc (l: var ScreenLayout; icon: pointer; n: int) =
  l.width = W; l.height = H; l.scaleX = 1; l.scaleY = 1; l.uiScale = 100
windowRelays.refresh = proc () = discard
windowRelays.setWindowTitle = proc (t: string) = discard
windowRelays.setCursor = proc (c: CursorKind) = discard
drawRelays.blitRGBA = proc (p: ptr UncheckedArray[uint32]; w, h: int;
                            dst: Rect; f: RGBAFormat): bool =
  pixelsOut += w * h
  true
var pending: seq[Event]
var pendingAt = 0
inputRelays.pollEvent = proc (e: var Event; fl: set[InputFlag]): bool =
  # (read from the front without moving the rest: the bench's own
  # bookkeeping takes no memory of a frame)
  if pendingAt >= pending.len:
    pending.setLen(0)
    pendingAt = 0
    return false
  e = pending[pendingAt]
  inc pendingAt
  true
inputRelays.waitEvent = proc (e: var Event; t: int; fl: set[InputFlag]): bool =
  inputRelays.pollEvent(e, fl)          # (no waiting: the next input is there, or none)
inputRelays.getTicks = proc (): int = ticks

let gpuBench = getEnv("RETRO_GPU").toLowerAscii in ["1", "gpu"]
var egl: Egl
if gpuBench:
  if not egl.openOffscreen(W, H):
    echo "no OpenGL here: the GPU's frames not measured"
    quit 0
  eglload.current = egl
  gpuRelays = GpuRelays(
    startGpu: proc (): bool = true,
    stopGpu: proc () = discard,
    swapGpu: proc (): bool =
      gpuGl().finish()                    # (the frame's work done before the clock is read)
      true,
    gpuProc: proc (name: cstring): pointer = eglload.current.glProc(name),
    gpuIsEs: proc (): bool = true,
    gpuGeneration: proc (): int = 0,
    gpuReady: proc (): bool = true,
    gpuBufferAge: proc (): int = 1)       # (a pbuffer keeps its pixels)

proc allocsNow(): int =
  when defined(nimAllocStats): cast[array[2, int]](getAllocStats())[0]
  else: 0

var
  name = "Untitled project"
  notes = "Line one\nLine two\nLine three\nLine four"
  a, b = true
  c = false
  r = 1
  v = 40
  sel = 2
  lang = 0
  items: seq[string]
  toolRect1, toolRect2, editRect, listRect: Rect
for i in 0 ..< 200: items.add "Item number " & $i & "\t" & $(i * 3) & " KB"

const okLabels = ["OK 0", "OK 1", "OK 2", "OK 3"]
const cancelLabels = ["Cancel 0", "Cancel 1", "Cancel 2", "Cancel 3"]

proc gallery() =
  menubar:
    menu "&File": discard menuItem("E&xit")
    menu "&Edit": discard menuItem("&Copy")
    menu "&Help": discard menuItem("&About")
  toolbar:
    for i, ic in [icNew, icOpen, icSave, icCut, icCopy, icPaste, icPrint, icHelp]:
      toolButton(ic, "tip")
      if i == 1: toolRect1 = ui.lastRect
      elif i == 3: toolRect2 = ui.lastRect
  statusbar("Ready", "NUM")
  row([-1, -1, -1]):
    group "Buttons":
      for i in 0 ..< 4:
        row:
          button(okLabels[i], isDefault = i == 0)
          button(cancelLabels[i])
    group "Choices":
      checkbox "Auto save", a
      checkbox "Backups", b
      checkbox "Grid", c
      radio "Small", r, 0
      radio "Medium", r, 1
      radio "Large", r, 2
    group "Text":
      edit name
      editRect = ui.lastRect
      spin v, 0, 100
      combo ["English", "Deutsch", "Français"], lang
  row([-1, -1]):
    group "Values":
      slider v, 0, 100
      progress(v / 100)
      hscroll v, 0, 100, 10
    group "Lists":
      listbox items, sel, rows = 8, tabs = [120]
      listRect = ui.lastRect
  editArea notes, lines = 6

var
  scene = 0
  cols = @[column("No.", 70, alRight), column("Customer", 200),
           column("Amount", 100, alRight), column("Status", 80)]
  gsel = 0
  tsel = "Sales/Invoices"
  o1, o2 = true
  navW = 180
  sales = [12.0, 19, 8, 15, 22, 17, 9, 14, 21, 18, 11, 16]

proc cell(r, c: int): string =
  case c
  of 0: $(100000 + r)
  of 1: "Customer number " & $(r mod 977)
  of 2: formatNumber(float(r mod 5000) * 1.25)
  else: (if r mod 3 == 0: "Open" else: "Paid")

proc business() =
  menubar:
    menu "&File": discard menuItem("E&xit")
  statusbar("100,000 invoices")
  split(navW, -1):
    tree(tsel, -1):
      branch "Sales", o1:
        leaf "Invoices"
        leaf "Customers"
      branch "Reports", o2:
        leaf "Monthly"
  do:
    grid(cols, 100_000, cell, gsel, height = 18)
    barChart(sales, [], "Sales", h = 150)

var folder = newFolderModel()
for i in 0 ..< 50_000:
  folder.all.add FileItem(name: "IMG_" & $(20240000 + i * 7 mod 99991) & ".jpg",
                          path: "/x/IMG_" & $i & ".jpg", size: int64(i) * 1733,
                          modified: fromUnix(1_700_000_000 + i * 60))
folder.applyView()
var fileView = fvDetails

proc files() =
  menubar:
    menu "&File": discard menuItem("E&xit")
  statusbar("50,000 files")
  discard fileList(folder, fileView, thumbnails = false)

proc frame() =
  discard beginFrame()
  case scene
  of 0: gallery()
  of 1: business()
  else: files()
  endFrame()
  ticks += 16

var framesRun = 0

proc step() =
  ## A frame, and the ones that follow it at once (what a key or a click
  ## changed late in a frame is drawn by one more): until one is shown.
  frame()
  inc framesRun
  var n = 0
  while ui.redraw and n < 6:
    frame()
    inc framesRun
    inc n

proc measure(label: string; n: int; prep: proc ()) =
  ## `n` times: what `prep` does (an input, a change), then the frames
  ## until it is on the screen.
  for _ in 0 ..< 5: (prep(); step())
  pixelsOut = 0
  framesRun = 0
  let a0 = allocsNow()
  let t0 = getMonoTime()
  for _ in 0 ..< n:
    prep()
    step()
  let us = (getMonoTime() - t0).inMicroseconds.float / n.float
  let allocs = (allocsNow() - a0).float / n.float
  var line = label.alignLeft(36) & formatFloat(us, ffDecimal, 1).align(9) & " us" &
             formatFloat(framesRun / n, ffDecimal, 1).align(5) & " frames" &
             ($(pixelsOut div n)).align(8) & " px sent"
  when defined(nimAllocStats): line.add formatFloat(allocs, ffDecimal, 1).align(8) & " allocs"
  echo line

proc at(r: Rect): Event = Event(kind: MouseMoveEvent, x: r.x + r.w div 2, y: r.y + r.h div 2)

startApp("bench", W, H)
if gpuBench:
  for _ in 0 ..< 3: frame()
  echo "drawn with ", gpuDescription()
for _ in 0 ..< 5: frame()
measure("full redraw (800x600, invalidated)", 300, proc () = invalidate())
measure("nothing changed", 3000, proc () = discard)
var k = 0
measure("one value changed (slider)", 1000, proc () =
  inc k
  v = k mod 100)
measure("hover: tool button to tool button", 1000, proc () =
  inc k
  pending.add at(if (k and 1) == 0: toolRect1 else: toolRect2))
# (the text box focused by a click, then a letter typed and taken back)
pending.add at(editRect)
pending.add Event(kind: MouseDownEvent, x: editRect.x + 8, y: editRect.y + 4, button: LeftButton, clicks: 1)
step()
pending.add Event(kind: MouseUpEvent, x: editRect.x + 8, y: editRect.y + 4, button: LeftButton)
step()
measure("typing in a text box", 1000, proc () =
  inc k
  # (a letter, then Backspace: one key a frame -- a key down ends a frame's
  # input -- the text shown after each)
  if (k and 1) == 0:
    var e = Event(kind: TextInputEvent)
    e.text[0] = 'x'
    pending.add e
  else:
    pending.add Event(kind: KeyDownEvent, key: KeyBackspace))
measure("wheel-scroll a list", 300, proc () =
  inc k
  pending.add at(listRect)
  pending.add Event(kind: MouseWheelEvent, y: (if (k div 40) mod 2 == 0: -1 else: 1)))

scene = 1
for _ in 0 ..< 5: frame()
measure("business: 100,000-row grid + chart", 300, proc () = invalidate())
measure("business: wheel-scroll the grid", 300, proc () =
  pending.add Event(kind: MouseMoveEvent, x: 500, y: 200)
  pending.add Event(kind: MouseWheelEvent, y: -1))

scene = 2
for _ in 0 ..< 5: frame()
measure("files: 50,000 files, details", 300, proc () = invalidate())
measure("files: wheel-scroll them", 300, proc () =
  pending.add Event(kind: MouseMoveEvent, x: 400, y: 300)
  pending.add Event(kind: MouseWheelEvent, y: -1))
fileView = fvIcons
for _ in 0 ..< 5: frame()
measure("files: 50,000 files, icons", 300, proc () = invalidate())
measure("files: wheel-scroll the icons", 300, proc () =
  pending.add Event(kind: MouseMoveEvent, x: 400, y: 300)
  pending.add Event(kind: MouseWheelEvent, y: -1))

# ---- work that is not drawing --------------------------------------------------------------

proc timeIt(label: string; n: int; body: proc ()) =
  body()
  let t0 = getMonoTime()
  for _ in 0 ..< n: body()
  let ms = (getMonoTime() - t0).inMicroseconds.float / 1000 / n.float
  echo label.alignLeft(36), formatFloat(ms, ffDecimal, 1).align(9), " ms"

var many = folder.all
timeIt("sort 50,000 names naturally", 5, proc () =
  var x = many
  sortFiles(x, byName))
let data = getEnv("RETRO_BENCH_DATA")
if data.len > 0:
  let png = readFile(data / "big.png")
  timeIt("decode a 2000x1500 PNG", 3, proc () = discard decodePng(png))
  let jpg = readFile(data / "photo12mp.jpg")
  timeIt("decode a 12 MP JPEG", 2, proc () = discard decodeJpeg(jpg))
  timeIt("... its 1/8 thumbnail", 5, proc () = discard decodeJpeg(jpg, 8))
  let prog = readFile(data / "photo12mp-prog.jpg")
  timeIt("decode a 12 MP progressive JPEG", 2, proc () = discard decodeJpeg(prog))

# ---- the parts new in 0.29: a vector tile, a model, a package -------------------------------------

import retroui/[mvt, gltf, msix, sign]
include carscene

block:
  var w: MvtWriter
  for i in 0 ..< 200:
    let x = (i * 37) mod 4000
    let y = (i * 91) mod 4000
    w.addFeature("building", mgPolygon, [@[(x, y), (x + 60, y), (x + 60, y + 40), (x, y + 40), (x, y)]])
    w.addFeature("transportation", mgLine, [@[(0, y), (4096, (y + 700) mod 4096)]], {"class": "primary"})
  w.addFeature("water", mgPolygon, [@[(0, 0), (4096, 0), (4096, 900), (0, 1300), (0, 0)]])
  w.addFeature("place", mgPoint, [@[(2000, 2000)]], {"class": "city", "name": "Muscat"})
  let tile = w.toMvt()
  timeIt("a vector tile decoded and drawn, 512 px", 20, proc () =
    discard renderMvtPixels(decodeMvt(tile), 14, 512, classicStyle()))
  let car = carScene()
  let glb = toGlb(car)
  timeIt("a glTF model read (the test car)", 50, proc () = discard readGlb(glb))
  var cam = camera3()
  fitView(car, cam)
  timeIt("the car drawn lit on the CPU, 800x600", 20, proc () = discard render3d(car, cam, 800, 600))
  let (key, cert) = devKey(getTempDir() / "retro-bench-keys")
  var big = newString(4 shl 20)
  for i in 0 ..< big.len: big[i] = char((i * 31 + i shr 9) and 255)
  var pe = newString(0x400)
  pe[0] = 'M'; pe[1] = 'Z'; pe[0x3C] = '\x40'; pe[0x40 .. 0x43] = "PE\0\0"
  pe[0x44] = '\x64'; pe[0x45] = '\x86'; pe[0x46] = '\1'; pe[0x54] = '\xF0'
  pe[0x58] = '\x0B'; pe[0x59] = '\x02'; pe[0x58 + 61] = '\2'; pe[0x58 + 108] = '\x10'
  let prog = pe & big
  timeIt("a 4 MB program signed (Authenticode)", 5, proc () = discard authenticodeSign(prog, key, cert))
  var app = MsixApp(name: "Retro.Bench", publisher: certSubject(cert), version: "1.0.0.0",
                    displayName: "Bench", publisherName: "Retro", exe: "b.exe")
  app.files.add ("b.exe", prog)
  timeIt("an MSIX of it made and signed", 3, proc () = discard buildMsix(app, key, cert))

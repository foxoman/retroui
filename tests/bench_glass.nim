## How long a window full of controls takes, in the 3.1 look and the Glass look (light and
## dark): every pixel redrawn (a theme changed, the window resized), the pointer moving over
## buttons, nothing changed -- at 1600 x 1000, drawn by the processor. Its tabs, groups, cards,
## fields and buttons are the rounded shapes the Glass look draws hundreds of a frame.
##
##   nim c -d:release -d:useMalloc -r tests/bench_glass.nim [3.1|Glass|"Glass, dark"]
import std/[os, strutils, monotimes, times, algorithm]
import retroui/uirelays/[coords, screen, input]
import retroui, retroui/[extras, business]

const BW = 1600
const BH = 1000
var screenPx = newSeq[uint32](BW * BH)
var queue: seq[Event]
var ticks = 1000
windowRelays.createWindow = proc (l: var ScreenLayout; icon: pointer; iconLen: int) =
  l.width = BW; l.height = BH; l.scaleX = 1; l.scaleY = 1; l.uiScale = 100
windowRelays.getWindowLayout = proc (): ScreenLayout =
  ScreenLayout(width: BW, height: BH, scaleX: 1, scaleY: 1, uiScale: 100)
windowRelays.refresh = proc () = discard
windowRelays.setWindowTitle = proc (t: string) = discard
windowRelays.setCursor = proc (c: CursorKind) = discard
drawRelays.blitRGBA = proc (p: ptr UncheckedArray[uint32]; w, h: int; dst: Rect; f: RGBAFormat): bool =
  for y in 0 ..< h: copyMem(addr screenPx[(dst.y + y) * BW + dst.x], addr p[y * w], w * 4)
  true
inputRelays.pollEvent = proc (e: var Event; fl: set[InputFlag]): bool =
  if queue.len == 0: return false
  e = queue[0]
  queue.delete(0)
  true
inputRelays.waitEvent = proc (e: var Event; t: int; fl: set[InputFlag]): bool = inputRelays.pollEvent(e, fl)
inputRelays.getTicks = proc (): int = ticks
inputRelays.shutdown = proc () = discard
fontRelays.openFont = proc (path: string; size: int; style: FontStyles; metrics: var FontMetrics): Font = Font(0)
fontRelays.closeFont = proc (f: Font) = discard
fontRelays.getFontMetrics = proc (f: Font): FontMetrics = FontMetrics()
fontRelays.measureText = proc (f: Font; text: string): TextExtent = TextExtent()
fontRelays.drawText = proc (f: Font; x, y: int; text: string; fg, bg: Color): TextExtent = TextExtent()

var
  name = "Al Noor Trading"
  paid = true
  cash = false
  room = 1
  sel = 1
  vol = 60
  qty = 3
  tab = 0
  pick = 0
  wifi = true
  seg = 1
  q = "invoice"
  notes = "Two rooms, the sea view.\nBreakfast at seven.\nA car at noon."
  strip = 0
  agree = false
  hs = 40
  rows: seq[seq[string]]
  gsel = 0
  cols = @[Column(title: "Order", width: 70), Column(title: "Customer", width: 160),
           Column(title: "Due", width: 90), Column(title: "Total", width: 90)]
for i in 0 ..< 40: rows.add @[$(1000 + i), "Customer " & $i, "2026-01-" & $(i mod 28 + 1), $(i * 37) & ".50"]
var okR, cancelR: Rect                  # (where the pointer goes: the first group's buttons)
let items = ["Rooms", "Food", "Spa", "Laundry", "Pool", "Gym", "Events", "Cars", "Tours", "Bar"]

proc view() =
  menubar:
    menu "&File":
      discard menuItem("&New", "Ctrl+N")
    menu "&Edit": discard menuItem("&Undo", "Ctrl+Z")
    menu "&View": discard menuItem("&Zoom")
  toolbar:
    discard toolButton("New", "New")
    discard toolButton("Open", "Open")
    discard toolButton("Save", "Save")
  discard tabStrip(["Order 1042.png", "Notes.txt", "Rooms"], strip)
  tabs tab, ["&General", "&Payment", "&Notes"]:
    adaptive(360):
      for k in 0 ..< 3:
        pushId("g" & $k)
        group "Order":
          edit name
          checkbox "&Paid", paid
          checkbox "&Cash", cash
          radio("&Room", room, 0)
          radio("&Suite", room, 1)
          row:
            if button("&OK", isDefault = true): discard
            if k == 0: okR = ui.lastRect
            if button("Cancel"): discard
            if k == 0: cancelR = ui.lastRect
          segmented(["Day", "Week", "Month"], seg)
          searchBox(q)
        group "Department":
          discard listbox(items, sel, rows = 6)
          discard combo(["Muscat", "Sohar", "Salalah"], pick)
          slider vol, 0, 100
          progress 0.6
          toggle "&Wi-Fi", wifi
          spin(qty, 0, 99)
        card "Payment":
          checkbox "&Agree", agree
          hscroll(hs, 0, 100, page = 20)
          editArea(notes, lines = 4)
        popId()
    discard grid(cols, rows, gsel, height = 8)
  statusbar("Ready", "3 items")

startApp("bench", BW, BH)
var recMs, presMs: float
proc frameOnce() =
  let t0 = getMonoTime()
  discard beginFrame()
  view()
  let t1 = getMonoTime()
  endFrame()
  recMs = float((t1 - t0).inMicroseconds) / 1000
  presMs = float((getMonoTime() - t1).inMicroseconds) / 1000
  ticks += 16

proc measure(label: string; n: int; prep: proc ()) =
  var ts, rs, ps: seq[float]
  for i in 0 ..< n:
    prep()
    let t0 = getMonoTime()
    frameOnce()
    ts.add float((getMonoTime() - t0).inMicroseconds) / 1000
    rs.add recMs
    ps.add presMs
  ts.sort(); rs.sort(); ps.sort()
  template f2(v: float): string = formatFloat(v, ffDecimal, 2)
  echo "  ", label.alignLeft(26), " median ", f2(ts[ts.len div 2]), " ms (building ", f2(rs[rs.len div 2]),
       ", drawing ", f2(ps[ps.len div 2]), ")"

let only = if paramCount() >= 1: paramStr(1) else: ""
for (lookName, lk, th) in [("3.1", lookClassic, Classic), ("Glass", lookGlass, GlassLight), ("Glass, dark", lookGlass, GlassDark)]:
  if only.len > 0 and only != lookName: continue
  uiLook = lk
  ui.theme = th
  invalidate()
  for i in 0 ..< 10: frameOnce()
  echo lookName, ":"
  let n = if only.len > 0: 60 else: 20
  measure("full redraw", n, proc () = invalidate())
  var flip = false
  measure("pointer over buttons", n * 2, proc () =
    flip = not flip
    let r = if flip: okR else: cancelR
    queue.add Event(kind: MouseMoveEvent, x: r.x + r.w div 2, y: r.y + r.h div 2))
  measure("nothing changed", n * 2, proc () = discard)

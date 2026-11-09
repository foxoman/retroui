## Fuzzes the drawing side headlessly: Markdown views, text with any
## Unicode (Arabic, marks, bidi controls, broken UTF-8), wrapping, edit
## fields fed random keys, lists and grids with odd values; and (every
## other round) the explorer widgets: tabs that scroll, tab strips, path
## bars, suggestions, file lists with odd names, drags, balloons; and the
## business and desktop parts: rich grids with odd cells, masks, property
## grids, tree grids, windows in the window, find bars, planning views
## with odd dates, maps with odd values, 3D views, HTML.
##
##   nim c -d:release --stackTrace:on --lineTrace:on tests/fuzz/fuzzui.nim
##   tests/fuzz/fuzzui 1000 7        # rounds, random seed

import std/[random, strutils, os]
import retroui
import retroui/uirelays/input
import ../harness

randomize(if paramCount() >= 2: parseInt(paramStr(2)) else: 7)
let rounds = if paramCount() >= 1: parseInt(paramStr(1)) else: 300

const pieces = ["# ", "## ", "> ", "- ", "* ", "1. ", "- [ ] ", "- [x] ", "```", "`",
  "**", "*", "_", "~~", "[", "](", ")", "![", "<http://a.b>", "|", "|-|", ":-:", "\n",
  "\n\n", "  \n", "    ", "\t", "\\", "&amp;", "&#", "&#x1F600;", ";", "---", "***",
  "مرحبا", "سلام", "لا", "ـ", "ً", "ّ", "123", "٣٤٥", "(", "]", "{", "}",
  "‮", "‫", "‏", "‎", "⁦", "⁩", "abc", "WORD", " ",
  "\xFF", "\xC3", "\xE2\x82", "\xF0\x9F\x98", "\0", "😀", "🇴🇲", "é", "<b>",
  "\r\n", "html", "a" .repeat(300), "-".repeat(80), "|a|b|\n|-|-|\n|1|2|",
  "> ".repeat(300), "- ".repeat(300), "*".repeat(500), "[".repeat(300), "`".repeat(200)]

proc junk(n: int): string =
  for _ in 0 ..< n: result.add sample(pieces)

var md = ""
var plain = ""
var editText = ""
var area = ""
var sel = 0
var marked: seq[bool]
var items: seq[string]
var lines: seq[string]
var scaleK = 100
var on = false

var tabSel, stripSel = 0
var tabLabels: seq[string]
var comboText = ""
var fileView = fvDetails
var iconPx = 0
let fzRoot = getTempDir() / "retro-fuzz-files"

proc oddFiles() =
  ## A folder of files with odd names (any bytes but / and NUL).
  removeDir(fzRoot)
  createDir(fzRoot / "sub")
  for i in 0 ..< rand(0 .. 25):
    var n = junk(rand(1 .. 2)).multiReplace(("/", "_"), ("\0", "_"))
    if n.len > 120: n.setLen(120)
    if n in ["", ".", ".."]: n = "x" & $i
    try: writeFile(fzRoot / n, junk(rand(0 .. 3)))
    except IOError, OSError: discard

fakeDriver()
startApp("fuzz", W, H)
oddFiles()
let model = newFolderModel(fzRoot)

proc explorerView() =
  tabs(tabSel, tabLabels):
    label plain
    discard tabStrip(tabLabels, stripSel, dropKind = "files", closable = sel mod 2 == 0)
    row:
      comboEdit(comboText, items, w = 200)
      discard pathBar(fzRoot / "sub", key = "fz", editNow = sel mod 13 == 0)
    let ev = fileList(model, fileView, iconSize = iconPx, height = 180,
                      tapActivates = sel mod 3 == 0, checkboxes = sel mod 5 == 0)
    if ev.zoom != 0: iconPx = clamp(iconPx + 24 * ev.zoom, 0, 300)
    discard filePreview(model, height = 80)

# ---- the business and desktop parts, with odd data ---------------------------------------

var biz = 0
var bizCols: seq[Column]
var bizRows: seq[seq[string]]
var bizSel, bizPos, propSel, treeSel, dsel = 0
var mask, masked = ""
var props: seq[Prop]
var trows: seq[TreeRow]
var tcols = @[column("A", 120), numberColumn("B", 80)]
var availL, chosenL: seq[string]
var d1, d2: Date
var finder = FindState(open: true)
var mw1 = MdiWindow(title: "One", open: true)
var mw2 = MdiWindow(title: "Two", open: true, r: rect(40, 30, 200, 120))
var lanes: seq[KanbanLane]
var ksel: KanbanPos
var tasks: seq[GanttTask]
var gsel = 0
var gscale = gsDay
var appts: seq[Appointment]
var aday = date(2026, 10, 27)
var amode = amMonth
var org: seq[OrgNode]
var osel = 0
var kstate: seq[float]
var mstate = MapState()
var mvalues: seq[(string, float)]
var scene = bars3d(@[@[1.0, 2], @[3.0, 4]], ["a", "b"], ["c", "d"])
var cam = camera3()
var htmlText = ""
var hk = ""

proc oddDate(): Date =
  if rand(5) == 0: Date(year: rand(-5 .. 10000), month: rand(-2 .. 14), day: rand(-3 .. 40))
  else: date(2026, rand(1 .. 12), rand(1 .. 28))

proc oddFloat(): float =
  case rand(6)
  of 0: NaN
  of 1: Inf
  of 2: -1e300
  else: rand(-1000.0 .. 1000.0)

proc newBizData() =
  bizCols = @[column("A", rand(-5 .. 200)), numberColumn("N"), checkColumn("C"),
              colorColumn("S"), progressColumn("P"),
              choiceColumn("Ch", [junk(1), junk(1)]), buttonColumn("B"), linkColumn("L"),
              iconColumn("I")]
  bizRows.setLen(0)
  for i in 0 ..< rand(0 .. 40):
    var r: seq[string]
    for c in 0 ..< rand(0 .. 10): r.add junk(rand(0 .. 2))
    bizRows.add r
  bizSel = rand(-3 .. 50)
  mask = junk(rand(0 .. 4))
  masked = junk(rand(0 .. 2))
  props = @[textProp(junk(1), junk(2), junk(1), junk(3)), boolProp(junk(1), rand(1) == 0),
            choiceProp(junk(1), (if rand(3) == 0: @[] else: @[junk(1), junk(1)]), rand(-2 .. 3)),
            numberProp(junk(1), oddFloat(), rand(-2 .. 20)), intProp(junk(1), rand(int.high)),
            colorProp(junk(1), color(1, 2, 3), junk(1)), dateProp(junk(1), oddDate()),
            infoProp(junk(1), junk(3))]
  propSel = rand(-2 .. 10)
  trows.setLen(0)
  for i in 0 ..< rand(0 .. 30):
    trows.add TreeRow(level: rand(-2 .. 12), cells: @[junk(1), junk(1)], open: rand(1) == 0,
                      glyph: if rand(3) == 0: junk(1) else: "")
  treeSel = rand(-3 .. 40)
  availL.setLen(0)
  for i in 0 ..< rand(0 .. 10): availL.add junk(1)
  chosenL.setLen(0)
  d1 = oddDate()
  d2 = oddDate()
  finder.what = junk(rand(0 .. 2))
  finder.open = true
  finder.replacing = rand(1) == 0
  lanes.setLen(0)
  for l in 0 ..< rand(0 .. 5):
    var lane = KanbanLane(title: junk(1), limit: rand(-1 .. 4))
    for c in 0 ..< rand(0 .. 8):
      lane.cards.add KanbanCard(title: junk(1), detail: junk(rand(0 .. 2)), due: oddDate(),
                                who: junk(rand(0 .. 1)))
    lanes.add lane
  ksel = (rand(-1 .. 6), rand(-1 .. 9))
  tasks.setLen(0)
  for t in 0 ..< rand(0 .. 30):
    tasks.add GanttTask(name: junk(1), start: oddDate(), finish: oddDate(),
                        progress: oddFloat(), level: rand(-1 .. 5),
                        deps: @[rand(-3 .. 40)], milestone: rand(5) == 0)
  gsel = rand(-2 .. 40)
  gscale = sample([gsDay, gsWeek, gsMonth])
  appts.setLen(0)
  for a in 0 ..< rand(0 .. 30):
    appts.add Appointment(title: junk(1), day: oddDate(), start: rand(-100 .. 2000),
                          finish: rand(-100 .. 2000), allDay: rand(3) == 0)
  aday = oddDate()
  amode = sample([amMonth, amWeek, amDay])
  org.setLen(0)
  for o in 0 ..< rand(0 .. 25):
    org.add OrgNode(name: junk(1), title: junk(1), parent: rand(-3 .. 30), closed: rand(4) == 0)
  osel = rand(-2 .. 30)
  kstate.setLen(0)
  for i in 0 ..< rand(0 .. 12): kstate.add oddFloat()
  mvalues.setLen(0)
  for i in 0 ..< rand(0 .. 20):
    mvalues.add (sample(["OM", "AE", "USA", "x", "", junk(1), "Oman", "gb"]), oddFloat())
  var vals: seq[seq[float]]
  for r in 0 ..< rand(0 .. 4):
    var row: seq[float]
    for c in 0 ..< rand(0 .. 4): row.add oddFloat()
    vals.add row
  scene = bars3d(vals, [junk(1)], [junk(1)])
  htmlText = junk(rand(0 .. 20)).multiReplace(("[", "<"), ("]", ">"))
  hk = junk(rand(0 .. 2))
  biz = rand(3)

proc businessView() =
  if closeRequested(): cancelClose()
  case biz
  of 0:
    let ev = grid(bizCols, bizRows.len, proc (r, c: int): string =
                    (if c < bizRows[r].len: bizRows[r][c] else: ""), bizSel, height = 6,
                  rowHeaders = rand(1) == 0,
                  style = proc (r, c: int): CellStyle = cellStyle(fg = color(uint8(r * 7), 0, 0)),
                  footer = proc (c: int): string = junk(1))
    if ev.edited and ev.row in 0 .. bizRows.high and ev.col in 0 .. bizRows[ev.row].high:
      bizRows[ev.row][ev.col] = ev.text
    discard recordNav(bizPos, bizRows.len, rand(1) == 0)
    row:
      discard maskedEdit(masked, mask)
      discard hotkeyEdit(hk)
      discard dateRange(d1, d2)
  of 1:
    discard propertyGrid(props, propSel, height = 200)
    discard treeGrid(tcols, trows, treeSel, height = 6)
    discard dualList(availL, chosenL, rows = 4)
  of 2:
    discard findBar(finder)
    mdiArea(150):
      mdiWindow(mw1): label junk(1)
      mdiWindow(mw2): paragraph junk(3)
    discard kanbanBoard(lanes, ksel, height = 150)
    discard ganttView(tasks, gsel, gscale, height = 150)
  else:
    discard agendaView(appts, aday, amode, height = 160)
    discard orgChart(org, osel, height = 120)
    discard kpiTile(junk(1), junk(1), oddFloat(), junk(1), trend = kstate, target = oddFloat())
    discard mapView(mstate, height = 140, values = mvalues)
    discard view3d(scene, cam, height = 120)
    discard htmlView(htmlText, height = 100)

var explorer = false
var business = false
view = proc () =
  # Esc on a touch screen is the back button: the fuzzer stays open
  if closeRequested(): cancelClose()
  if business:
    businessView()
    return
  if explorer:
    explorerView()
    return
  discard markdownView(md, height = 200)
  label plain
  paragraph plain
  row:
    discard edit(editText)
    discard toggle("t", on)
  discard editArea(area, lines = 4)
  discard listbox(items, sel, rows = 4)
  discard lineView(lines.len, proc (i: int): string = lines[i], sel)
  var c = @[column("A", 80), column("B", 60, alRight)]
  discard grid(c, items.len, proc (r, col: int): string =
    if col == 0: items[r] else: $r, sel, marked, height = 120)
  for l in wrapLines(plain, 1 + sel mod 200): discard textWidth(l)
  discard ellipsize(plain, 40)
  styledText(plain, style(bold = true, italic = true))

for round in 0 ..< rounds:
  md = junk(rand(1 .. 60))
  plain = junk(rand(0 .. 12))
  items.setLen(0)
  for i in 0 ..< rand(0 .. 30): items.add junk(rand(0 .. 3))
  lines = items
  marked.setLen(0)
  sel = rand(-3 .. 40)
  if round mod 7 == 0:
    scaleK = sample([50, 75, 100, 133, 200, 300])
    setUiScale(scaleK)
  if round mod 11 == 0: setUiFont(sample(builtinUiFonts))
  explorer = round mod 3 == 1
  business = round mod 3 == 2
  if business:
    newBizData()
    ui.touch = rand(3) == 0
  if explorer:
    tabLabels.setLen(0)
    for i in 0 ..< rand(0 .. 16): tabLabels.add junk(rand(0 .. 2))
    tabSel = rand(-2 .. 20)
    fileView = sample([fvDetails, fvTiles, fvIcons])
    ui.touch = rand(3) == 0
    if round mod 40 == 1:
      oddFiles()
      model.reload()
    if rand(9) == 0: toast(junk(rand(1 .. 4)), title = junk(1))
  # random input
  for _ in 0 ..< rand(0 .. 10):
    case rand(6)
    of 0: down(rand(-5 .. W + 5), rand(-5 .. H + 5)); up(rand(W), rand(H))
    of 1: key(sample([KeyLeft, KeyRight, KeyUp, KeyDown, KeyHome, KeyEnd, KeyBackspace,
                      KeyDelete, KeyEnter, KeyTab, KeyPageDown, KeyPageUp, KeyEsc]),
              if rand(2) == 0: {ShiftPressed} else: {})
    of 2: typeText(junk(rand(1 .. 3)))
    of 3: move(rand(W), rand(H))
    of 4:                                   # a drag (held a while on touch)
      down(rand(W), rand(H))
      for _ in 0 ..< rand(1 .. 4): move(rand(W), rand(H))
      if rand(3) == 0: queue.add Event(kind: KeyDownEvent, key: KeyNone, mods: {CtrlPressed})
      up(rand(W), rand(H))
    of 5:
      queue.add Event(kind: MouseWheelEvent, y: rand(-5 .. 5),
                      mods: (if rand(2) == 0: {CtrlPressed} else: {}), hasMods: true)
    else: key(sample([KeyTab, KeyF4, KeyF2, KeyDelete, KeyA]), {CtrlPressed})
  run(2)
  if round mod 50 == 0 or existsEnv("FUZZ_VERBOSE"): echo "round ", round
ui.touch = false
removeDir(fzRoot)
echo "ui fuzz passed (", rounds, " rounds)"

## Tests of the explorer-class parts: drag and drop (mouse and touch), file
## lists that take drops, the tab strip, the path bar, the classic tabs
## that scroll, suggestions, balloons, modifier keys, wake-ups, PNG writing,
## the jobs a drop asks for, and undo -- headless, on the fake driver.

import std/[os, times, strutils]
import retroui
import retroui/uirelays/input
import harness

fakeDriver()
startApp("explorer", W, H)

template hdrH: int = ItemH + 4  # a details list: its header row
template rowH: int = ItemH + 2  # and its rows

proc waitFor(cond: proc (): bool; what: string; seconds = 10.0) =
  let until = epochTime() + seconds
  while not cond():
    doAssert epochTime() < until, "timed out: " & what
    run()
    os.sleep(2)

proc center(r: Rect): (int, int) = (r.x + r.w div 2, r.y + r.h div 2)

# ---- drag and drop in the core ------------------------------------------------------------------

block coreDragAndDrop:
  var src, dst, other: Rect
  var got: seq[string] = @[]
  var wasOver, otherHit = false
  view = proc () =
    row([120, 120, 120]):
      src = canvas(120, 40)
      let h = interact(idOf("drag source"), src)
      if h.down and ui.mouseMoved and not dragging():
        startDrag("things", ["a", "b"], "2 things")
      dst = canvas(120, 40)
      case dropTarget(dst, "things")
      of dsOver: wasOver = true
      of dsDropped: got = ui.drag.items
      else: discard
      other = canvas(120, 40)
      if dropTarget(other, "something else") != dsNone: otherHit = true
  run(2)
  let (sx, sy) = center(src)
  let (dx, dy) = center(dst)
  down(sx, sy)
  run()
  move(sx + 20, sy)
  run()
  doAssert dragging("things") and not dragging("files")
  move(dx, dy)
  run()
  doAssert wasOver, "the target sees the drag over it"
  up(dx, dy)
  run()
  doAssert got == @["a", "b"], $got
  doAssert not dragging(), "the drag ends with the drop"
  # another kind of target never takes it; Esc cancels
  got = @[]
  down(sx, sy)
  run()
  move(sx + 20, sy)
  run()
  let (ox, oy) = center(other)
  move(ox, oy)
  run()
  key(KeyEsc)
  run()
  doAssert not dragging(), "Esc cancels the drag"
  up(ox, oy)
  run()
  doAssert not otherHit and got.len == 0

# ---- file lists that drag and take drops --------------------------------------------------------

let root = getTempDir() / "retro-explorer-test"
removeDir(root)
createDir(root / "box")
createDir(root / "other")
writeFile(root / "a.txt", "aaa")
writeFile(root / "b.txt", "bbb")

proc rowAt(r: Rect; i: int): (int, int) = (r.x + 40, r.y + 1 + hdrH + i * rowH + rowH div 2)

block fileListDrops:
  let m = newFolderModel(root)
  var ev: FileListEvent
  var r: Rect
  var drop = FileDrop()
  view = proc () =
    ev = fileList(m, fvDetails)
    r = ui.lastRect
    if ev.drop.dropped: drop = ev.drop
  waitFor(proc (): bool = m.dir == root and not m.loading and m.items.len == 4, "listing")
  run(2)
  doAssert m.items[0].name == "box" and m.items[2].name == "a.txt"
  # a.txt dragged onto the folder "box"
  let (ax, ay) = rowAt(r, 2)
  let (bx, by) = rowAt(r, 0)
  down(ax, ay)
  run()
  move(ax + 4, ay + 12)
  run()
  doAssert dragging("files") and ui.drag.items == @[root / "a.txt"], $ui.drag.items
  move(bx, by)
  run()
  up(bx, by)
  run()
  doAssert drop.dropped and drop.into == root / "box" and not drop.copy, $drop
  doAssert drop.paths == @[root / "a.txt"]
  # the job the drop asks for, then undo
  let j = jobFor(drop)
  doAssert j.kind == jkMove
  while j.state == jsRunning: j.run()
  doAssert fileExists(root / "box" / "a.txt") and not fileExists(root / "a.txt")
  remember(j)
  doAssert canUndo()
  let u = undo()
  doAssert u.error.len == 0, u.error
  doAssert fileExists(root / "a.txt") and not fileExists(root / "box" / "a.txt")
  doAssert jobFor(FileDrop(paths: @["x"], into: "::trash")).kind == jkTrash
  doAssert jobFor(FileDrop(paths: @["x"], into: root, copy: true)).kind == jkCopy
  doAssert jobFor(FileDrop()) == nil
  doAssert jobTitle(jkCopy) == "Copying"
  # Ctrl held while letting go: a copy; a drop on itself is refused
  m.reload()
  waitFor(proc (): bool = not m.loading and m.items.len == 4, "listing again")
  run(2)
  drop = FileDrop()
  down(ax, ay)
  run()
  move(ax + 4, ay + 12)
  run()
  move(ax, ay)                          # back over itself
  run()
  up(ax, ay)
  run()
  doAssert not drop.dropped, "a file is not dropped on itself"
  down(ax, ay)
  run()
  move(ax + 4, ay + 12)
  run()
  move(bx, by)
  queue.add Event(kind: KeyDownEvent, key: KeyNone, mods: {CtrlPressed})
  run()
  doAssert dragCopies()
  up(bx, by)
  run()
  doAssert drop.dropped and drop.copy, "Ctrl copies"
  queue.add Event(kind: KeyUpEvent, key: KeyNone, mods: {}, hasMods: true)
  run()
  doAssert not dragCopies(), "a key let go updates the modifiers"

block zoomWithCtrlWheel:
  let m = newFolderModel(root)
  var zoom = 0
  var r: Rect
  view = proc () =
    let ev = fileList(m, fvIcons)
    r = ui.lastRect
    if ev.zoom != 0: zoom = ev.zoom
  waitFor(proc (): bool = not m.loading and m.items.len > 0, "listing")
  let (cx, cy) = center(r)
  move(cx, cy)
  queue.add Event(kind: MouseWheelEvent, y: 1, mods: {CtrlPressed}, hasMods: true)
  run()
  doAssert zoom == 1, "Ctrl + the wheel asks for bigger icons"
  queue.add Event(kind: MouseWheelEvent, y: -1, mods: {}, hasMods: true)
  run()
  doAssert CtrlPressed notin ui.mods

block touchLiftToDrag:
  let m = newFolderModel(root)
  var r: Rect
  var drop: FileDrop
  view = proc () =
    let ev = fileList(m, fvDetails)
    r = ui.lastRect
    if ev.drop.dropped: drop = ev.drop
  waitFor(proc (): bool = not m.loading and m.items.len == 4, "listing")
  ui.touch = true
  run(2)
  let (ax, ay) = rowAt(r, 2)
  let (bx, by) = rowAt(r, 1)
  down(ax, ay)
  run(40)                               # held: the long press (a right click)
  move(ax + 30, ay + 20)                # then moved: lifted, dragged
  run()
  doAssert dragging("files"), "a held, then moved, finger drags"
  move(bx, by)
  run()
  up(bx, by)
  run()
  doAssert drop.dropped and drop.into == root / "other", $drop
  ui.touch = false

# ---- the tab strip ------------------------------------------------------------------------------

block tabStripEvents:
  var sel = 0
  var ev: TabStripEvent
  var strip: Rect
  var labels = @["One", "Two", "Three"]
  view = proc () =
    ev = tabStrip(labels, sel, dropKind = "things")
    strip = ui.lastRect
    if ev.closed >= 0: labels.delete(ev.closed)
    if ev.added: labels.add "New"
    let src = canvas(80, 30)
    let h = interact(idOf("tab drag source"), src)
    if h.down and ui.mouseMoved and not dragging(): startDrag("things", ["x"])
  run(2)
  doAssert strip.w > 100 and strip.h > 0
  key(KeyTab, {CtrlPressed})
  run()
  doAssert sel == 1, "Ctrl+Tab: the next tab"
  key(KeyTab, {CtrlPressed, ShiftPressed})
  run()
  doAssert sel == 0, "Ctrl+Shift+Tab: the one before"
  # something dragged and dropped on the first tab
  let src = rect(strip.x + 10, strip.y + strip.h + 15, 10, 10)
  down(src.x, src.y)
  run()
  move(src.x + 20, src.y)
  run()
  move(strip.x + 12, strip.y + strip.h div 2)
  run()
  var dropOn = -1
  view = proc () =
    ev = tabStrip(labels, sel, dropKind = "things")
    strip = ui.lastRect
    if ev.dropOn >= 0: dropOn = ev.dropOn
    discard canvas(80, 30)
  up(strip.x + 12, strip.y + strip.h div 2)
  run()
  doAssert dropOn == 0, $dropOn

# ---- the path bar -------------------------------------------------------------------------------

block pathBarEditing:
  var path = root
  var ev: PathBarEvent
  var bar: Rect
  var editNow = false
  view = proc () =
    ev = pathBar(path, key = "test", editNow = editNow)
    editNow = false
    bar = ui.lastRect
    if ev.go.len > 0: path = ev.go
  run(2)
  # a click on the empty part: a box to type a path in, all of it selected
  click(bar, dx = bar.w - 8)
  run()
  typeText(root / "box")
  key(KeyEnter)
  run()
  doAssert path == root / "box", path
  # F4 (editNow) and a folder that is not there
  var err = ""
  view = proc () =
    ev = pathBar(path, key = "test", editNow = editNow)
    editNow = false
    if ev.error.len > 0: err = ev.error
    if ev.go.len > 0: path = ev.go
  editNow = true
  run()
  typeText(root / "nothing")
  key(KeyEnter)
  run()
  doAssert err.len > 0 and path == root / "box", err
  # Esc gives the folders back
  editNow = true
  run()
  typeText("zzz")
  key(KeyEsc)
  run()
  doAssert path == root / "box"
  # a suggestion picked with Down, then Enter
  editNow = true
  run()
  typeText(root / "ot")
  run()
  key(KeyDown)
  key(KeyEnter)
  run()
  doAssert path == root / "other", path

block pathBarClicks:
  # a click on a folder of the path goes there; the arrow after one drops
  # its subfolders down (as in Windows)
  var path = root / "box"
  var ev: PathBarEvent
  var bar: Rect
  view = proc () =
    ev = pathBar(path, key = "clicks")
    bar = ui.lastRect
    if ev.go.len > 0: path = ev.go
  run(2)
  var names: seq[string]
  var p = path
  while true:
    names.insert(if p.extractFilename.len == 0: p else: p.extractFilename, 0)
    if p.parentDir.len == 0 or p.parentDir == p: break
    p = p.parentDir
  let lead = textWidth(retroOr(pxFolderOpen, nfFolderOpen)) + dp(8)
  let pad = dp(4)
  let sepW = textWidth(nfChevronRight) + 2 * dp(3)
  var xs, arrows: seq[int]
  var x = bar.x + lead
  for n in names:
    xs.add x + 3
    x += textWidth(n, true) + 2 * pad
    arrows.add x + sepW div 2
    x += sepW
  doAssert x < bar.x + bar.w, "the test path fits"
  let parentAt = names.high - 1                 # "retro-explorer-test"
  let cy = bar.y + bar.h div 2
  down(xs[parentAt], cy)
  run()
  up(xs[parentAt], cy)
  run(2)
  doAssert path == root, "a click on a folder of the path goes there: " & path
  # the arrow after it: its subfolders, then one chosen with the keys
  run(2)
  down(arrows[names.high - 1], cy)
  run()
  up(arrows[names.high - 1], cy)
  run(2)
  doAssert popupMenuOpen("pathbar-menu:clicks"), "the subfolders drop down"
  key(KeyDown)
  run()
  key(KeyEnter)
  run(2)
  doAssert path.parentDir == root and dirExists(path), "a subfolder chosen: " & path
  doAssert not popupMenuOpen("pathbar-menu:clicks")
  # fingers too
  ui.touch = true
  path = root / "box"
  run(3)
  var tx = bar.x + lead
  tx += 3
  # the first folder ("/" or the drive)
  down(tx, cy)
  run()
  up(tx, cy)
  run(2)
  doAssert path == names[0], "a tap goes there too: " & path
  ui.touch = false

# ---- suggestions: nothing picked until Down --------------------------------------------------------

block comboEditKeepsTyped:
  var city = ""
  var r: Rect
  view = proc () =
    comboEdit(city, ["Berlin", "Bern"], w = 150)
    r = ui.lastRect
  run(2)
  click(r, 5)
  typeText("be")
  run()
  key(KeyEnter)
  run()
  doAssert city == "be", "Enter keeps what was typed: " & city

# ---- classic tabs that do not fit ---------------------------------------------------------------

block tabsScroll:
  var sel = 0
  var labels: seq[string]
  for i in 1 .. 14: labels.add "Long tab " & $i
  var page = ""
  view = proc () =
    tabs(sel, labels):
      page = labels[sel]
      label page
  run(2)
  for i in 1 .. 13:
    key(KeyTab, {CtrlPressed})
    run()
  doAssert sel == 13 and page == "Long tab 14"
  # the arrows: the left one scrolls back, the chosen tab stays chosen
  let arrowY = Pad + 8
  for i in 0 .. 3:
    click(rect(W - Pad - 2 * SbW, 0, SbW, 40), dx = SbW div 2, dy = arrowY)
  doAssert sel == 13, "the arrows scroll, they do not choose"

# ---- balloons -----------------------------------------------------------------------------------

block balloons:
  view = proc () = label "x"
  toast("Copied 3 items", title = "Files")
  run(2)
  doAssert toastShown()
  let r = toastArea()
  doAssert r.w > 40 and r.h > 20 and r.x + r.w <= W and r.y + r.h <= H, $r
  # pale yellow inside
  var yellow = 0
  for y in r.y ..< r.y + r.h:
    for x in r.x ..< r.x + r.w:
      let t = ui.theme.tip
      if px(x, y) == (uint32(t.r) shl 16 or uint32(t.g) shl 8 or uint32(t.b)): inc yellow
  doAssert yellow > r.w * r.h div 3, $yellow
  click(r, dx = r.w div 2)
  doAssert not toastShown(), "a click on the balloon closes it"
  toast("Gone soon", ms = 100)
  run(2)
  ticks += 200
  run(2)
  doAssert not toastShown(), "it goes away by itself"

# ---- frames asked for are not lost ---------------------------------------------------------------

block wakeUps:
  var asked = false
  view = proc () =
    if not asked:
      wakeIn(300)
      asked = true
  run(1)
  let at = ui.wakeAt
  doAssert at > 0
  run(1)
  doAssert ui.wakeAt == at, "a frame in between keeps the wake-up"
  ticks += 400
  run(1)
  doAssert ui.wakeAt == 0

# ---- writing pictures ---------------------------------------------------------------------------

block pngWriting:
  let b = newBitmap(3, 2)
  for i in 0 ..< 6: b.px[i] = 0xFF000000'u32 or uint32(i * 40) shl 8
  b.px[5] = 0x80FF0000'u32
  let back = decodePng(encodePng(b))
  doAssert back.w == 3 and back.h == 2 and back.px == b.px
  doAssert savePng(b, root / "small.png") and loadPicture(root / "small.png").px == b.px
  doAssert not savePng(b, root / "no such folder" / "x.png")

removeDir(root)
block namesFirstThenSizes:
  # a folder not shown yet: its names at once, then its sizes and dates
  createDir(root / "quick")
  for i in 1 .. 30: writeFile(root / "quick" / ("f" & $i & ".txt"), "x".repeat(i))
  let m = newFolderModel(root)
  view = proc () = discard fileList(m, fvDetails)
  waitFor(proc (): bool = m.items.len > 0 and m.loadingFor == 0, "the first listing")
  m.open(root / "quick")
  waitFor(proc (): bool = m.dir == root / "quick" and m.items.len == 30 and
            m.loadingFor == 0, "the second folder")
  var total = 0'i64
  for it in m.items:
    doAssert not it.stub, "sizes and dates came: " & it.name
    total += it.size
  doAssert total == 465
  # the selection made while only the names were there stays
  m.open(root)
  waitFor(proc (): bool = m.dir == root and m.loadingFor == 0, "back")
  m.selectAfterLoad([root / "quick"])
  m.reload()
  waitFor(proc (): bool = m.loadingFor == 0 and m.markedCount == 1, "selected")
  # Small icons (Explorer's): one line each, the name beside the icon; a
  # click selects as in the other views
  m.open(root / "quick")
  view = proc () = discard fileList(m, fvSmallIcons)
  waitFor(proc (): bool = m.dir == root / "quick" and m.items.len == 30 and m.loadingFor == 0, "small icons")
  run(2)
  m.clearSelection()
  click(rect(4, 4, 150, 14))
  doAssert m.markedCount == 1, $m.markedCount

echo "explorer tests passed"

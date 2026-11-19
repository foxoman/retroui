## Tests of retroui/forcegraph: a graph laid out by its forces -- linked nodes at about their
## length, the others apart, a pinned node where it is put, the same layout every time, the
## push among neighbours as strong as among all of them; the control on a clock of the test's
## own: it settles and then asks for no frames, a node dragged stays where it is let go.

import std/math
import retroui, retroui/[headless, forcegraph, inspect]
import retroui/uirelays/input

proc dist(g: ForceGraph; a, b: int): float = hypot(g.x[a] - g.x[b], g.y[a] - g.y[b])

block layout:
  var g = newForceGraph(linkLength = 50)
  let hub = g.addNode("hub", "Hub")
  var kids: seq[int]
  for i in 0 ..< 8:
    kids.add g.addNode("k" & $i)
    g.link(hub, kids[^1])
  let far = g.addNode("alone")
  doAssert g.find("k3") == kids[3] and g.find("nobody") == -1
  doAssert g.addNode("hub") == hub and g.len == 10       # (the same key: the same node)
  g.settle()
  doAssert g.settled and g.steps < 600, "settled in " & $g.steps
  for k in kids:
    let d = g.dist(hub, k)
    doAssert d > 30 and d < 90, "a link near its length: " & $d
  for i in 0 ..< kids.len:
    for j in i + 1 ..< kids.len:
      doAssert g.dist(kids[i], kids[j]) > 15, "the hub's nodes apart"
  doAssert g.dist(hub, far) > 20
  # the same every time
  var h = newForceGraph(linkLength = 50)
  discard h.addNode("hub", "Hub")
  for i in 0 ..< 8:
    discard h.addNode("k" & $i)
    h.link(0, i + 1)
  discard h.addNode("alone")
  h.settle()
  doAssert h.x == g.x and h.y == g.y

block pinned:
  var g = newForceGraph()
  let a = g.addNode("a", x = 100, y = 100)
  g.nodes[a].pinned = true
  for i in 0 ..< 5:
    g.link(a, g.addNode("n" & $i))
  g.settle()
  doAssert g.x[a] == 100 and g.y[a] == 100, "a pinned node stays"
  for i in 1 .. 5: doAssert g.dist(a, i) < 90, "its nodes round it"

block bigGraphSettles:
  var g = newForceGraph()
  for i in 0 ..< 1500:
    let n = g.addNode($i)
    if i > 0: g.link(n, (i * 7919) mod i)
  g.settle()
  doAssert g.settled
  var worst = 0.0
  for l in g.links: worst = max(worst, g.dist(l.a, l.b))
  doAssert worst < 400, "no link stretched across: " & $worst

# ---- the control ---------------------------------------------------------------------------------------------

useHeadless(400, 300)
startApp("Graph", 400, 300)
var clock = 1000
inputRelays.getTicks = proc (): int = clock

var g = newForceGraph()
let root = g.addNode("root", "Root")
for i in 0 ..< 6: g.link(root, g.addNode("c" & $i, "Child " & $i, group = i mod 3))
var sel = -1
var ev: GraphEvent
proc frame(ms = 16) =
  clock += ms
  discard beginFrame()
  ev = graphView(g, 260, sel)
  endFrame()
frame()
doAssert ui.wakeAt != 0, "moving: frames asked for"
for i in 0 ..< 600:
  frame()
  if g.settled: break
doAssert g.settled
for i in 0 ..< 100: frame()               # (the view's fit springs to the settled graph)
frame(200)
frame()
doAssert ui.wakeAt == 0, "settled: no frames asked for"
# a node clicked is selected, dragged it stays where it is let go
let shot = headlessShot()
doAssert shot.w == 400
accessKeep = true
frame()
let n = findNode(accessLast, "Child 2", {arListItem})
doAssert n >= 0, "each node a list item for a screen reader"
let r = nodeRect(accessLast[n])
let (px, py) = (r.x + 4, r.y + r.h div 2)
headlessInput(Event(kind: MouseMoveEvent, x: px, y: py))
frame()
headlessInput(Event(kind: MouseDownEvent, x: px, y: py, button: LeftButton, clicks: 1))
frame()
doAssert ev.clicked == g.find("c2") and sel == g.find("c2"), "clicked: " & $ev.clicked
let before = (g.x[sel], g.y[sel])
headlessInput(Event(kind: MouseMoveEvent, x: px + 40, y: py + 30))
for i in 0 ..< 3: frame()
headlessInput(Event(kind: MouseUpEvent, x: px + 40, y: py + 30, button: LeftButton))
frame()
doAssert ev.dropped == sel
doAssert hypot(g.x[sel] - before[0], g.y[sel] - before[1]) > 5, "moved by the drag"
doAssert not g.nodes[sel].pinned, "let go: not held any more"
stopApp()
echo "test_forcegraph: ok"

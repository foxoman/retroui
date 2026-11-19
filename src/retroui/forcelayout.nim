## A graph that lays itself out: nodes that push each other away and keep out of each other's
## room, links that pull their ends to a length, a gentle pull to the middle -- moved a step at
## a time until they settle (as d3-force does: forces that cool down). The layout alone, with
## no window (a mind map arranged, a diagram tidied: `settle`); `retroui/forcegraph`'s
## `graphView` shows one and lets the user drag its nodes.
##
## The nodes are kept as arrays (x, y, their speeds), the push of nodes on each other only
## among neighbours (a grid of cells as big as the push reaches), so a few thousand nodes
## settle in a moment; a new node linked to one there is starts a link's length from it,
## away from the middle (a tree starts unfolded, not in a knot); the same layout every time.
##
## .. code-block:: nim
##   var g = newForceGraph()
##   let a = g.addNode("mail", "Mail")
##   let b = g.addNode("imap", "IMAP")
##   g.link(a, b)
##   g.settle()
##   echo g.x[b], " ", g.y[b]
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[math, tables, hashes]

type
  NodeLook* = enum
    ## How a node is drawn.
    nlDot,            ## a dot, its label beside it (a network, a topic map)
    nlBox             ## a box with its label in it (a mind map)

  GraphNode* = object
    ## A node: what it is called and how it looks (where it is: `ForceGraph.x`, `y`).
    key*: string      ## its own name (`find`)
    label*: string    ## what is written by it
    group*: int       ## its color: one of the chart colors (-1: the theme's)
    size*: float      ## a dot's radius, a box's room (0: the graph's own)
    pinned*: bool     ## stays where it is put; the others move round it

  GraphLink* = object
    ## Two nodes pulled to a length.
    a*, b*: int
    length*: float    ## (0: the graph's `linkLength`)
    strength*: float  ## (0: by how many links its ends have, as d3-force does)

  ForceGraph* = object
    ## The nodes and links, and where each node is now.
    nodes*: seq[GraphNode]
    links*: seq[GraphLink]
    x*, y*: seq[float]          ## where each node is
    vx, vy: seq[float]
    fresh: seq[bool]            # (placed by the spiral, not yet by a link)
    halfW, halfH: seq[float]    # (the room each takes: no other is let into it)
    linkLength*: float          ## how long links are (40)
    push*: float                ## how hard nodes push each other away (30)
    reach*: float               ## how far that push reaches (300)
    pull*: float                ## how hard the middle pulls everything (0.05)
    alpha*: float               ## how much it still moves, 1 .. 0 (it stops under `alphaMin`)
    alphaMin*: float
    alphaTarget*: float         ## what alpha goes to (0: it settles; more: it keeps moving)
    steps*: int                 ## steps taken (for tests)
    index: Table[string, int]

const
  AlphaDecay = 0.0228           # (1 - 0.001 ^ (1 / 300): settled in some 300 steps, as d3-force)
  VelocityKeep = 0.6            # (each step a node keeps this of its speed)
  Golden = PI * (3 - sqrt(5.0))

proc newForceGraph*(linkLength = 40.0; push = 30.0; pull = 0.05): ForceGraph =
  ## An empty graph.
  ForceGraph(linkLength: linkLength, push: push, reach: 300, pull: pull, alpha: 1, alphaMin: 0.001)

proc len*(g: ForceGraph): int = g.nodes.len
  ## How many nodes.

proc find*(g: ForceGraph; key: string): int = g.index.getOrDefault(key, -1)
  ## The node of `key` (-1: none).

proc reheat*(g: var ForceGraph; alpha = 1.0) =
  ## Moving again (a node or a link added, a node moved): it settles anew.
  g.alpha = max(g.alpha, alpha)

proc addNode*(g: var ForceGraph; key: string; label = ""; group = -1; x = NaN; y = NaN): int =
  ## A node (`key` its own name: one there already is given back as it is). Without `x`, `y`
  ## it starts by the nodes there are, on a spiral -- the same place every time.
  let had = g.find(key)
  if had >= 0: return had
  result = g.nodes.len
  g.nodes.add GraphNode(key: key, label: if label.len > 0: label else: key, group: group)
  g.index[key] = result
  var px = x
  var py = y
  if px.isNaN or py.isNaN:
    let r = 10 * sqrt(0.5 + result.float)
    let a = result.float * Golden
    px = r * cos(a)
    py = r * sin(a)
  g.x.add px
  g.y.add py
  g.vx.add 0
  g.vy.add 0
  g.fresh.add(x.isNaN or y.isNaN)
  g.halfW.add 0
  g.halfH.add 0
  g.reheat(0.3)

proc link*(g: var ForceGraph; a, b: int; length = 0.0; strength = 0.0) =
  ## Pulls nodes `a` and `b` to `length` (0: `linkLength`); twice the same: once.
  if a == b or a notin 0 ..< g.nodes.len or b notin 0 ..< g.nodes.len: return
  for l in g.links:
    if (l.a == a and l.b == b) or (l.a == b and l.b == a): return
  # (a new node starts a link's length from the one it is linked to, away from the middle of
  # the graph, each of its brothers turned a little more: a tree starts unfolded, not in a knot)
  var (a, b) = (a, b)
  if g.fresh[a] and not g.fresh[b]: swap(a, b)
  if g.fresh[b] and not g.nodes[b].pinned:
    var cx, cy = 0.0
    var k = 0
    for i in 0 ..< g.nodes.len:
      if not g.fresh[i]:
        cx += g.x[i]
        cy += g.y[i]
        inc k
    if k > 0:
      cx /= k.float
      cy /= k.float
    var brothers = 0
    for l in g.links:
      if l.a == a or l.b == a: inc brothers
    let away = if hypot(g.x[a] - cx, g.y[a] - cy) > 1e-6: arctan2(g.y[a] - cy, g.x[a] - cx) else: 0.0
    let turn = if brothers == 0: 0.0 else: (if brothers mod 2 == 1: 1.0 else: -1.0) * float((brothers + 1) div 2) * 0.6
    let d = if length > 0: length else: g.linkLength
    g.x[b] = g.x[a] + d * cos(away + turn)
    g.y[b] = g.y[a] + d * sin(away + turn)
    g.fresh[a] = false
    g.fresh[b] = false
  g.links.add GraphLink(a: a, b: b, length: length, strength: strength)
  g.reheat(0.3)

proc setRoom*(g: var ForceGraph; i: int; w, h: float) =
  ## Node `i` takes a box `w` x `h` (its label's, a box's): others are kept out of it.
  ## (`graphView` sets it from what it draws.)
  if i notin 0 ..< g.nodes.len: return
  if abs(g.halfW[i] - w / 2) >= 1 or abs(g.halfH[i] - h / 2) >= 1:
    g.halfW[i] = w / 2
    g.halfH[i] = h / 2
    g.reheat(0.1)

proc moveNode*(g: var ForceGraph; i: int; x, y: float) =
  ## Puts node `i` at `x`, `y` (a drag): the others make room.
  if i notin 0 ..< g.nodes.len: return
  g.x[i] = x
  g.y[i] = y
  g.vx[i] = 0
  g.vy[i] = 0
  g.reheat(0.3)

proc settled*(g: ForceGraph): bool = g.alpha < g.alphaMin and g.alphaTarget < g.alphaMin
  ## Nothing moves any more.

proc step*(g: var ForceGraph) =
  ## One step of the layout: links pull, nodes push their neighbours, the middle pulls; each
  ## node moves by its speed, which slows.
  let n = g.nodes.len
  if n == 0: return
  inc g.steps
  g.alpha += (g.alphaTarget - g.alpha) * AlphaDecay
  let alpha = g.alpha
  # links: each end pulled toward the length, the end with fewer links more (d3-force)
  var degree = newSeq[int](n)
  for l in g.links:
    inc degree[l.a]
    inc degree[l.b]
  for l in g.links:
    let (a, b) = (l.a, l.b)
    var dx = g.x[b] + g.vx[b] - g.x[a] - g.vx[a]
    var dy = g.y[b] + g.vy[b] - g.y[a] - g.vy[a]
    if dx == 0 and dy == 0:
      dx = 1e-3 * float((a * 7 + b * 13) mod 5 - 2)  # (on top of each other: apart, the same way each time)
      dy = 1e-3
    let d = sqrt(dx * dx + dy * dy)
    let length = if l.length > 0: l.length else: g.linkLength
    let strength = if l.strength > 0: l.strength else: 1 / float(min(degree[a], degree[b]))
    let f = (d - length) / d * alpha * strength
    let bias = degree[a] / (degree[a] + degree[b])
    g.vx[b] -= dx * f * bias
    g.vy[b] -= dy * f * bias
    g.vx[a] += dx * f * (1 - bias)
    g.vy[a] += dy * f * (1 - bias)
  # the push of nodes on their neighbours: a grid of cells as wide as it reaches
  let cell = max(1.0, g.reach)
  var cells: Table[(int, int), seq[int32]]
  for i in 0 ..< n:
    cells.mgetOrPut((int(floor(g.x[i] / cell)), int(floor(g.y[i] / cell))), @[]).add int32(i)
  let reach2 = g.reach * g.reach
  for i in 0 ..< n:
    let cx = int(floor(g.x[i] / cell))
    let cy = int(floor(g.y[i] / cell))
    var fx, fy = 0.0
    var sepX, sepY = 0.0
    for gx in cx - 1 .. cx + 1:
      for gy in cy - 1 .. cy + 1:
        cells.withValue((gx, gy), list):
          for j32 in list[]:
            let j = int(j32)
            if j == i: continue
            var dx = g.x[i] - g.x[j]
            var dy = g.y[i] - g.y[j]
            var d2 = dx * dx + dy * dy
            if d2 >= reach2: continue
            if d2 < 1e-6:
              dx = if i < j: 0.01 else: -0.01        # (on the same spot: apart, by their order)
              dy = 0
              d2 = 1e-4
            d2 = max(d2, 1.0)                        # (very near: not an endless push)
            fx += dx * g.push / d2
            fy += dy * g.push / d2
            # (in each other's room: apart along the way that is shorter, not weakened as it cools)
            let ox = g.halfW[i] + g.halfW[j] + 4 - abs(dx)
            let oy = g.halfH[i] + g.halfH[j] + 4 - abs(dy)
            if ox > 0 and oy > 0:
              if ox / max(1.0, g.halfW[i] + g.halfW[j]) < oy / max(1.0, g.halfH[i] + g.halfH[j]):
                sepX += (if dx >= 0: 1.0 else: -1.0) * ox * 0.35
              else:
                sepY += (if dy >= 0: 1.0 else: -1.0) * oy * 0.35
    g.vx[i] += fx * alpha + sepX
    g.vy[i] += fy * alpha + sepY
  # the middle: each node pulled toward the centre
  for i in 0 ..< n:
    g.vx[i] -= g.x[i] * g.pull * alpha
    g.vy[i] -= g.y[i] * g.pull * alpha
  # moved, slowing; a pinned node stays
  for i in 0 ..< n:
    if g.nodes[i].pinned:
      g.vx[i] = 0
      g.vy[i] = 0
      continue
    g.vx[i] *= VelocityKeep
    g.vy[i] *= VelocityKeep
    g.x[i] += g.vx[i]
    g.y[i] += g.vy[i]

proc settle*(g: var ForceGraph; most = 600) =
  ## Steps until it has settled (no more than `most`): laid out now, without a window.
  var k = 0
  while not g.settled and k < most:
    g.step()
    inc k

proc bounds*(g: ForceGraph): tuple[x0, y0, x1, y1: float] =
  ## The box round every node.
  if g.nodes.len == 0: return (0.0, 0.0, 0.0, 0.0)
  result = (Inf, Inf, -Inf, -Inf)
  for i in 0 ..< g.nodes.len:
    result.x0 = min(result.x0, g.x[i])
    result.y0 = min(result.y0, g.y[i])
    result.x1 = max(result.x1, g.x[i])
    result.y1 = max(result.y1, g.y[i])


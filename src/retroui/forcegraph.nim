## A graph shown as it lays itself out (`retroui/forcelayout`): links as lines, nodes as dots
## with their labels or as boxes (a mind map), the whole of it fitted in the box. It moves a
## fixed step at a time (`retroui/motion`'s `fixedSteps`), the same at any frame rate, until
## it settles -- frames asked for only meanwhile; a node dragged stays where it is held while
## the others make room.
##
## .. code-block:: nim
##   var g = newForceGraph()
##   g.link(g.addNode("mail", "Mail"), g.addNode("imap", "IMAP"))
##   # in a frame:
##   let ev = graphView(g, h = dp(300))
##   if ev.clicked >= 0: echo g.nodes[ev.clicked].label
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/tables
import core, gfx, motion, forcelayout
import uirelays/[coords, access]
export forcelayout

type
  GraphEvent* = object
    ## What happened in a `graphView` this frame (-1: nothing).
    clicked*: int               ## a node clicked (selected)
    doubleClicked*: int         ## ... double-clicked (open it)
    dropped*: int               ## a node dragged and let go

type ViewState = object
  held: int                     # (the node dragged, -1 none)
  grabX, grabY: float
  wasPinned: bool
  sel: int

var views: Table[Id, ViewState]

proc nodeColor(n: GraphNode): Color =
  const colors = [color(0, 0, 255), color(255, 0, 0), color(0, 128, 0), color(255, 0, 255),
                  color(0, 128, 128), color(128, 128, 0), color(128, 0, 0), color(0, 0, 128),
                  color(128, 0, 128), color(255, 128, 0)]
  if n.group < 0: ui.theme.select else: colors[n.group mod colors.len]

proc graphViewAt*(g: var ForceGraph; id: Id; h: int; sel: var int; look = nlDot): GraphEvent =
  ## `graphView` with an id of your own (`idOf`).
  result = GraphEvent(clicked: -1, doubleClicked: -1, dropped: -1)
  let area = place(0, h)
  var st = views.getOrDefault(id, ViewState(held: -1, sel: -1))
  # steps at a fixed pace while it moves (frames only then)
  let s = fixedStepsAt(id, 1000 / 60, running = not g.settled)
  for _ in 0 ..< s.n: g.step()
  # the whole graph in the box, scaled to fit (springing there, not jumping, as it grows)
  let (x0, y0, x1, y1) = g.bounds()
  let pad = float(dp(28))
  let fit = min(2.0, min((area.w.float - 2 * pad) / max(1.0, x1 - x0),
                         (area.h.float - 2 * pad) / max(1.0, y1 - y0)))
  let scale = sprungAt(mixId(id, 11), max(0.05, fit))
  let mx = sprungAt(mixId(id, 12), (x0 + x1) / 2)
  let my = sprungAt(mixId(id, 13), (y0 + y1) / 2)
  let ox = area.x.float + area.w.float / 2
  let oy = area.y.float + area.h.float / 2
  template sx(i: int): float = ox + (g.x[i] - mx) * scale
  template sy(i: int): float = oy + (g.y[i] - my) * scale
  fill(area, ui.theme.window)
  box(area, ui.theme.shadow)
  pushClip(area)
  # the links
  let lc = ui.theme.gray
  for l in g.links:
    thickLine(sx(l.a), sy(l.a), sx(l.b), sy(l.b), max(1.0, float(dp(1))), lc)
  # the nodes: where each is drawn, for the pointer
  var rects = newSeq[Rect](g.nodes.len)
  for i, n in g.nodes:
    let c = nodeColor(n)
    let x = sx(i)
    let y = sy(i)
    case look
    of nlDot:
      let r = (if n.size > 0: n.size else: 6.0) * float(dp(1))
      g.setRoom(i, 2 * r, 2 * r)
      disc(x, y, r, c)
      if i == sel: ring(x, y, r + float(dp(3)), float(dp(2)), ui.theme.select)
      let tw = textWidth(n.label)
      text(int(x + r + float(dp(4))), int(y) - FontH div 2, n.label, ui.theme.text)
      rects[i] = rect(int(x - r), int(y - r), int(2 * r) + dp(4) + tw, int(2 * r))
    of nlBox:
      let tw = textWidth(n.label)
      let bw = tw + dp(16)
      let bh = FontH + dp(10)
      g.setRoom(i, bw.float, bh.float)                # (in the graph's units: as at full size)
      let r = rect(int(x) - bw div 2, int(y) - bh div 2, bw, bh)
      roundRect(r, float(dp(6)), if i == sel: ui.theme.select else: ui.theme.face2)
      box(r, c)
      text(r.x + dp(8), r.y + dp(5), n.label, if i == sel: ui.theme.selectText else: ui.theme.text)
      rects[i] = r
  popClip()
  # a node under the pointer: picked, dragged (the others make room), let go
  let wx = (ui.mx.float - ox) / scale + mx
  let wy = (ui.my.float - oy) / scale + my
  if st.held >= 0 and st.held < g.nodes.len:
    if ui.mouseDown:
      g.moveNode(st.held, wx - st.grabX, wy - st.grabY)
      g.nodes[st.held].pinned = true
      g.alphaTarget = 0.3                  # (the others go on moving round it)
    else:
      g.nodes[st.held].pinned = st.wasPinned
      g.alphaTarget = 0
      result.dropped = st.held
      st.held = -1
  if hover(area):
    for i in countdown(rects.high, 0):
      let nid = mixId(id, uint32(1000 + i))
      let h = interact(nid, rects[i], focusable = false)
      if accessOn: accessNode(arListItem, g.nodes[i].label, states = (if i == sel: {asSelected} else: {}),
                              id = nid, r = rects[i])
      if h.down and st.held < 0 and ui.pressed:
        st.held = i
        st.grabX = wx - g.x[i]
        st.grabY = wy - g.y[i]
        st.wasPinned = g.nodes[i].pinned
        sel = i
        result.clicked = i
        if ui.clicks >= 2:
          result.doubleClicked = i
          markDouble(nid)
  elif accessOn:
    for i in 0 ..< g.nodes.len:
      accessNode(arListItem, g.nodes[i].label, states = (if i == sel: {asSelected} else: {}),
                 id = mixId(id, uint32(1000 + i)), r = rects[i])
  views[id] = st

template graphView*(g: var ForceGraph; h: int; sel: var int; look = nlDot; key = ""): GraphEvent =
  ## A graph laid out by its forces, as wide as the room and `h` pixels high: links as lines,
  ## nodes as dots with their labels (`nlDot`) or as boxes (`nlBox`: a mind map), the whole of
  ## it fitted in the box. It moves until it settles, frames asked for only meanwhile. A node
  ## clicked is selected (`sel`); dragged, it stays where it is let go while it is held and
  ## the others make room. Each call is its own view, by where it is in the code (`key` in a
  ## loop).
  const at = instantiationInfo(-1, true)
  const site = at.filename & ":" & $at.line & ":" & $at.column & ":"
  graphViewAt(g, idOf(site & key), h, sel, look)

template graphView*(g: var ForceGraph; h: int; look = nlDot; key = ""): GraphEvent =
  ## `graphView` without a node kept selected.
  var sel {.gensym.} = -1
  graphView(g, h, sel, look, key)

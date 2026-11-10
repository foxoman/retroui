## Docked panels, as today's Photoshop has them, drawn as 1994 drew its
## palettes: columns of panels down the right of an `mdiArea`.
##
## - A column holds groups of tabbed panels, one over the other: the bars
##   between them share out the height (dragged), a double-click on a
##   group's tabs folds it to its tabs (a click on a tab opens it again).
## - The arrows at the top of a column collapse it to a strip of icons; a
##   click on an icon shows that panel's group beside the strip (a click
##   elsewhere, Esc or the icon again puts it away).
## - A panel dragged by its tab (or its icon) goes into another group (its
##   tabs, or anywhere over it), between two groups (a group of its own),
##   to the left of the dock (a column of its own) -- or, let go over the
##   documents, into a floating palette of its own, dragged back onto the
##   dock by its title bar.
## - The arrow at the right of a group's tabs opens the panel's menu: yours
##   (`menu`), then Close and Close Tab Group. Closed panels come back where
##   they were (`showPanel`).
## - The left edge of a column sizes it; the bar between the documents and
##   the dock sizes the whole side panel (its first open column -- all of
##   them collapsed to icons: dragged out, the main one opens again).
##
## .. code-block:: nim
##   var dk = newDock()
##   discard dk.addColumn()
##   discard dk.addGroup(0, [dockPanel("color", "Color", nfPalette), dockPanel("swatches", "Swatches", nfThLarge)])
##   discard dk.addGroup(0, [dockPanel("layers", "Layers", nfImageMultiple)])
##   if beginMdi(-1, "ws"):
##     ... the documents' windows (their room ends at `dk.left`) ...
##     discard dockPanels(dk, "ws", proc (key: string) = panelBody(key), proc (key: string) = panelMenu(key))
##     endMdi()

import std/json
import gfx, core, widgets, desktop
import uirelays/input

template th: untyped = ui.theme

type
  DockPanel* = object
    ## A panel: `key` names it to you (your body and menu procs get it);
    ## `icon` a glyph (`nerdicons`) for the strip of icons.
    key*, title*, icon*: string  ## its name to you, its tab's text, its icon

  DockGroup* = ref object
    ## Panels sharing a place, one shown (`sel`), their tabs over it.
    panels*: seq[DockPanel]  ## in the order of their tabs
    sel*: int            ## the panel shown (an index of `panels`)
    share*: int          ## its part of its column's height (the shares are weights)
    folded*: bool        ## only its tabs shown
    win*: MdiWindow      ## (a floating group) its palette
    lastH: int           # (its body's height last drawn)

  DockColumn* = ref object
    ## Groups one over the other.
    groups*: seq[DockGroup]  ## top to bottom
    width*: int          ## its width when open (logical pixels; 0: the usual)
    iconic*: bool        ## collapsed to a strip of icons

  ZoneKind = enum zkInto, zkNewGroup, zkNewColumn
  Zone = object
    r: Rect              # where the mouse is to be
    mark: Rect           # what lights up
    kind: ZoneKind
    prio: int            # (smaller first)
    group: DockGroup     # zkInto: that group
    mids: seq[int]       # zkInto over its tabs: their middles (where it goes in)
    col: DockColumn      # zkNewGroup: that column; zkNewColumn: the column it goes left of
    before: DockGroup    # zkNewGroup: the group it goes over (nil: at the bottom)

  Dock* = ref object
    ## Columns of panels (`columns`, right to left), floating groups, and
    ## the panels closed (where they were).
    columns*: seq[DockColumn]  ## right to left
    floating*: seq[DockGroup]  ## groups in palettes of their own, over the documents
    closed*: seq[tuple[p: DockPanel; col, group: int]]
      ## panels closed, with the column and group they were in (to open them there again)
    left*: int           ## (after `dockPanels`) where the dock begins in the area: the documents' room ends there
    win, flyWin, ghostWin, markWin: MdiWindow
    fly: DockGroup       # (a collapsed column) the group shown beside its icons
    flyY: int            # (... where its icon was)
    dragging: bool
    dragPanel: DockPanel
    dragGroup: DockGroup # a floating group dragged by its title bar
    zones, nextZones: seq[Zone]
    target: int          # the zone the mouse is over (-1: none -- out: it floats)
    press: tuple[x, y: int; g: DockGroup; i: int]
    menuFor: string
    sizing: tuple[col: DockColumn; x0, w0: int]
    sharing: tuple[a, b: DockGroup; y0, ha, hb: int]

  DockEvent* = object
    ## What happened in `dockPanels` this frame.
    picked*: string      ## a panel brought up by a click on its tab or its icon
    floated*: string     ## a panel dragged out over the documents (it floats now)

proc refId(x: ref; s: string): Id = idOf(s & ":" & $cast[uint](x))

proc dockPanel*(key, title: string; icon = ""): DockPanel =
  ## A panel to put in a group.
  DockPanel(key: key, title: title, icon: icon)

proc openWidth(): int = (if fingers(): dp(290) else: dp(236))
proc iconWidth(): int = (if fingers(): dp(46) else: dp(32))
proc headH(): int = (if fingers(): dp(28) else: dp(11))    # (its arrows a finger's size)
proc tabsH(): int = paletteTabH()
proc barH(): int = (if fingers(): dp(10) else: dp(5))
proc gripW(): int = (if fingers(): dp(10) else: dp(5))
  ## (the bar between the documents and the dock: a split bar's)
const minBody = 48

proc newDock*(): Dock =
  ## An empty dock (add columns and groups, or `loadDock`).
  Dock(win: MdiWindow(palette: true, bare: true, open: true),
       flyWin: MdiWindow(palette: true, bare: true, open: true),
       ghostWin: MdiWindow(palette: true, bare: true, open: true),
       markWin: MdiWindow(palette: true, bare: true, open: true), target: -1)

proc addColumn*(d: Dock; width = 0; iconic = false): DockColumn {.discardable.} =
  ## A column at the left of the others.
  result = DockColumn(width: width, iconic: iconic)
  d.columns.add result

proc addGroup*(d: Dock; col: int; panels: openArray[DockPanel]; share = 100; sel = 0;
               folded = false): DockGroup {.discardable.} =
  ## A group of `panels` at the bottom of column `col`.
  result = DockGroup(panels: @panels, sel: sel, share: share, folded: folded)
  if col >= 0 and col < d.columns.len: d.columns[col].groups.add result

proc colWidth(c: DockColumn): int =
  if c.iconic: iconWidth() elif c.width > 0: c.width else: openWidth()

proc width*(d: Dock): int =
  ## How wide the dock is (its columns side by side, and the bar at their
  ## left that sizes them).
  for c in d.columns: result += c.colWidth
  if d.columns.len > 0: result += gripW()

proc find(d: Dock; key: string): tuple[g: DockGroup; i: int; col: int] =
  for ci, c in d.columns:
    for g in c.groups:
      for i, p in g.panels:
        if p.key == key: return (g, i, ci)
  for g in d.floating:
    for i, p in g.panels:
      if p.key == key: return (g, i, -1)
  (nil, -1, -1)

proc hasPanel*(d: Dock; key: string): bool =
  ## The panel is in the dock or floating (not closed).
  d.find(key).g != nil

proc panelShown*(d: Dock; key: string): bool =
  ## The panel can be seen now: its tab the one shown, in an open group of
  ## an open column, beside a collapsed one, or in an open palette.
  let (g, i, ci) = d.find(key)
  if g == nil or g.sel != i: return false
  if ci < 0: return g.win.open
  if d.columns[ci].iconic: return d.fly == g
  not g.folded

proc dropEmpty(d: Dock) =
  ## (groups with no panels, and columns with no groups, go)
  for c in d.columns:
    var gs: seq[DockGroup]
    for g in c.groups:
      if g.panels.len > 0: gs.add g
      elif d.fly == g: d.fly = nil
    c.groups = gs
  var cs: seq[DockColumn]
  for c in d.columns:
    if c.groups.len > 0: cs.add c
  d.columns = cs
  var fs: seq[DockGroup]
  for g in d.floating:
    if g.panels.len > 0: fs.add g
  d.floating = fs
  for g in d.floating: g.sel = clamp(g.sel, 0, g.panels.high)
  for c in d.columns:
    for g in c.groups: g.sel = clamp(g.sel, 0, g.panels.high)

proc takeOut(d: Dock; key: string): DockPanel =
  ## (the panel out of where it is; its place noted among the closed)
  let (g, i, ci) = d.find(key)
  if g == nil: return
  result = g.panels[i]
  var gi = -1
  if ci >= 0: gi = d.columns[ci].groups.find(g)
  for k in countdown(d.closed.high, 0):
    if d.closed[k].p.key == key: d.closed.delete(k)
  d.closed.add (result, ci, gi)
  g.panels.delete(i)
  if g.sel > i or g.sel >= g.panels.len: g.sel = max(0, g.sel - 1)
  d.dropEmpty()

proc closePanel*(d: Dock; key: string) =
  ## Closes a panel (`showPanel` brings it back where it was).
  discard d.takeOut(key)
  ui.redraw = true

proc showPanel*(d: Dock; key: string; p = DockPanel()) =
  ## Brings a panel up: its tab shown, its group unfolded; beside the icons
  ## of a collapsed column; a floating one's palette opened. A closed one
  ## comes back where it was (`p`: a panel never seen before -- a group of
  ## its own at the top of the first column).
  let (g, i, ci) = d.find(key)
  ui.redraw = true
  if g != nil:
    g.sel = i
    g.folded = false
    if ci < 0: g.win.open = true
    elif d.columns[ci].iconic:
      d.fly = g
      d.flyY = 0
    return
  var back = p
  var col = 0
  var at = 0
  for k in countdown(d.closed.high, 0):
    if d.closed[k].p.key == key:
      back = d.closed[k].p
      col = d.closed[k].col
      at = d.closed[k].group
      d.closed.delete(k)
      break
  if back.key.len == 0: back.key = key
  if back.title.len == 0: back.title = key
  if d.columns.len == 0: discard d.addColumn()
  if col < 0 or col >= d.columns.len: col = 0
  let c = d.columns[col]
  if at >= 0 and at < c.groups.len:
    c.groups[at].panels.add back
    c.groups[at].sel = c.groups[at].panels.high
    c.groups[at].folded = false
    if c.iconic: d.fly = c.groups[at]
  else:
    let ng = DockGroup(panels: @[back], share: 100)
    c.groups.insert(ng, clamp(at, 0, c.groups.len))
    if c.iconic: d.fly = ng

proc togglePanel*(d: Dock; key: string; p = DockPanel()) =
  ## Window menu: a panel shown is closed, else brought up (`showPanel`).
  if d.panelShown(key): d.closePanel(key) else: d.showPanel(key, p)

# ---- kept between runs ---------------------------------------------------------------------------------------

proc toJson(p: DockPanel): JsonNode = %*{"key": p.key, "title": p.title, "icon": p.icon}
proc panelOf(j: JsonNode): DockPanel =
  DockPanel(key: j{"key"}.getStr, title: j{"title"}.getStr, icon: j{"icon"}.getStr)

proc toJson(g: DockGroup): JsonNode =
  var ps = newJArray()
  for p in g.panels: ps.add p.toJson
  result = %*{"panels": ps, "sel": g.sel, "share": g.share, "folded": g.folded}
  if g.win.r.w > 0:
    result["win"] = %[g.win.r.x, g.win.r.y, g.win.r.w, g.win.r.h]
    result["open"] = %g.win.open

proc groupOf(j: JsonNode): DockGroup =
  result = DockGroup(sel: j{"sel"}.getInt, share: max(1, j{"share"}.getInt(100)), folded: j{"folded"}.getBool)
  for pj in j{"panels"}.getElems:
    let p = panelOf(pj)
    if p.key.len > 0: result.panels.add p
  let w = j{"win"}.getElems
  if w.len == 4:
    result.win = MdiWindow(palette: true, sizable: true, open: j{"open"}.getBool(true),
                           r: rect(w[0].getInt, w[1].getInt, w[2].getInt, w[3].getInt))

proc toJson*(d: Dock): JsonNode =
  ## The dock as it is: its columns, groups, floating palettes, closed panels.
  var cs = newJArray()
  for c in d.columns:
    var gs = newJArray()
    for g in c.groups: gs.add g.toJson
    cs.add %*{"width": c.width, "iconic": c.iconic, "groups": gs}
  var fs = newJArray()
  for g in d.floating: fs.add g.toJson
  var cl = newJArray()
  for (p, col, group) in d.closed: cl.add %*{"panel": p.toJson, "col": col, "group": group}
  %*{"columns": cs, "floating": fs, "closed": cl}

proc loadDock*(d: Dock; j: JsonNode): bool =
  ## The dock as `toJson` kept it (false, and unchanged: not one).
  if j == nil or j.kind != JObject or not j.hasKey("columns"): return false
  var cols: seq[DockColumn]
  for cj in j["columns"].getElems:
    let c = DockColumn(width: cj{"width"}.getInt, iconic: cj{"iconic"}.getBool)
    for gj in cj{"groups"}.getElems:
      let g = groupOf(gj)
      if g.panels.len > 0: c.groups.add g
    if c.groups.len > 0: cols.add c
  if cols.len == 0: return false
  d.columns = cols
  d.floating.setLen(0)
  for gj in j{"floating"}.getElems:
    let g = groupOf(gj)
    if g.panels.len > 0:
      if g.win.r.w <= 0: g.win = MdiWindow(palette: true, sizable: true, open: true)
      d.floating.add g
  d.closed.setLen(0)
  for cj in j{"closed"}.getElems:
    d.closed.add (panelOf(cj{"panel"}), cj{"col"}.getInt, cj{"group"}.getInt)
  d.fly = nil
  d.dropEmpty()
  true

proc keys*(d: Dock): seq[string] =
  ## Every panel in the dock or floating.
  for c in d.columns:
    for g in c.groups:
      for p in g.panels: result.add p.key
  for g in d.floating:
    for p in g.panels: result.add p.key

# ---- drawing ------------------------------------------------------------------------------------------------

proc tabLook(r: Rect; label: string; front: bool; hover: bool; st: TextStyle) =
  ## (a palette's tab: the one in front joined to the panel)
  let ink = paletteTabFace(r, front, hover)
  text(r.x + dp(6), r.y + (r.h - lineHeight(st)) div 2, label, ink, st)

proc startDrag(d: Dock; p: DockPanel) =
  d.dragging = true
  d.dragPanel = p
  d.target = -1
  ui.active = idOf("dock:drag")
  ui.dragsActive = true
  ui.redraw = true

proc groupTabs(d: Dock; g: DockGroup; r: Rect; ev: var DockEvent; folding: bool) =
  ## A group's tabs in `r`, the menu arrow at the right.
  fill(r, th.face)
  hline(r.x, r.y + r.h - 1, r.w, th.frame)
  let mw = r.h
  let room = r.w - mw - dp(2)
  # (the labels whole when they can be: less room around them first, then
  # a size smaller; only then are some cut short)
  var st = style(size = 0.9)
  var natural = newSeq[int](g.panels.len)
  var total = 0
  for (size, pad) in [(0.9, 12), (0.9, 6), (0.8, 6)]:
    st = style(size = size)
    total = 0
    for i, p in g.panels:
      natural[i] = textWidth(tr(p.title), st) + dp(pad)
      total += natural[i] - 1
    if total <= room: break
  var widths = natural
  if total > room and g.panels.len > 1:
    let mine = min(natural[clamp(g.sel, 0, g.panels.high)], room div 2)
    let each = max(dp(22), (room - mine) div (g.panels.len - 1) + 1)
    for i in 0 ..< g.panels.len:
      widths[i] = if i == g.sel: mine else: min(natural[i], each)
  var x = r.x
  var mids: seq[int]
  let shown = not g.folded
  for i, p in g.panels:
    let tw = widths[i]
    let front = i == g.sel and shown
    let tr = rect(x, r.y + (if front: 0 else: dp(2)), tw, r.h - (if front: 0 else: dp(2)))
    let tid = idOf("docktab:" & p.key)
    let hit = interact(tid, tr, focusable = false)
    if accessOn:
      let k = accessNode(arTab, tr(p.title), id = tid, r = tr,
                         states = (if front: {asSelected} else: {}))
      accessItem(k, i + 1, g.panels.len)
    if accessPressed == tid:
      if g.sel != i or g.folded: ev.picked = p.key
      g.sel = i
      g.folded = false
      ui.redraw = true
    let l = if tw < natural[i]: ellipsize(tr(p.title), max(dp(8), tw - dp(10)), st) else: tr(p.title)
    if tw < natural[i] and hit.hover: ui.tip = tr(p.title)
    tabLook(tr, l, front, hit.showsHover, st)
    mids.add tr.x + tr.w div 2
    if hit.down and ui.pressed:
      if ui.clicks >= 2 and folding and i == g.sel:
        g.folded = not g.folded
      else:
        if g.sel != i or g.folded: ev.picked = p.key
        g.sel = i
        g.folded = false
        d.press = (ui.mx, ui.my, g, i)
      ui.redraw = true
    # (pressed and dragged away: the panel goes with the mouse)
    if ui.active == tid and ui.mouseDown and not d.dragging and d.press.g == g and d.press.i == i and
       abs(ui.mx - d.press.x) + abs(ui.my - d.press.y) > dp(8):
      d.startDrag(p)
    x += tw - 1
  # (the empty part: a double-click folds the group)
  let rest = rect(x + 1, r.y, max(0, r.x + r.w - mw - x - 1), r.h)
  if rest.w > 0 and g.panels.len > 0:
    let rh = interact(idOf("dockrest:" & g.panels[0].key), rest, focusable = false)
    if rh.down and ui.pressed and ui.clicks >= 2 and folding:
      g.folded = not g.folded
      ui.redraw = true
  if g.panels.len > 0:
    let mr = rect(r.x + r.w - mw, r.y + dp(1), mw - dp(1), r.h - dp(3))
    let mid = idOf("dockmenu:" & g.panels[0].key)   # (one id: a second `idOf` is another)
    let mh = interact(mid, mr, focusable = false)
    arrow(mr.x + mr.w div 2, mr.y + mr.h div 2, dRight, if mh.showsHover: th.select else: th.text, dp(4))
    if accessOn:
      accessNode(arButton, "The panel's menu", id = mid, r = mr)
    if mh.down and ui.pressed or accessPressed == mid:
      d.menuFor = g.panels[clamp(g.sel, 0, g.panels.high)].key
      openPopupMenu("dock:menu", ui.mx, ui.my)
    ui.lastRect = mr
    tooltip("The panel's menu")
  d.nextZones.add Zone(r: r, mark: r, kind: zkInto, prio: 0, group: g, mids: mids)

proc groupBody(d: Dock; g: DockGroup; r: Rect; body: proc (key: string)) =
  ## The panel shown, in `r`: what is taller scrolls.
  if r.h <= 0 or r.w <= 0 or g.panels.len == 0: return
  let key = g.panels[clamp(g.sel, 0, g.panels.high)].key
  let id = idOf("dockbody:" & key)
  let cs = state(id)
  let scrolls = cs.aux > r.h
  let off = if scrolls: clamp(cs.scrollY, 0, cs.aux - r.h) else: 0
  fill(r, th.face)
  pushClip(r)
  beginClipped()
  let pad = PalettePad
  pushFrame(rect(r.x + pad, r.y + pad - off, r.w - 2 * pad - (if scrolls: SbW else: 0), r.h - 2 * pad + off))
  if body != nil:
    # (a panel that fails says so where it is; the program goes on)
    let before = ui.lastFault
    ui.lastFault = ""
    beginArea("dock:" & key)              # (F6 goes from panel to panel)
    guarded("the " & key & " panel"):
      body(key)
    endArea()
    if ui.lastFault.len > 0:
      label("This panel could not be shown:", bold = true)
      paragraph(ui.lastFault, color = th.gray)
    else: ui.lastFault = before
  let used = popFrame() + 2 * pad
  endClipped()
  popClip()
  var c2 = state(id)                     # (again: the body may have made states)
  var o = c2.scrollY
  if scrolls:
    let hi = max(0, used - r.h)
    scrollWheel(id, o, hi, r, 3 * ItemH)
    scrollPan(id, o, hi, r)
    scrollTick(id, o, hi)
    scrollBarFor(id + 1, id, rect(r.x + r.w - SbW, r.y, SbW, r.h), true, o, hi, max(ItemH, r.h - 2 * ItemH), ItemH)
  o = clamp(o, 0, max(0, used - r.h))
  if used != c2.aux or o != c2.scrollY:
    c2.aux = used
    c2.scrollY = o
    ui.redraw = true
  state(id) = c2

proc panelHeaderH*(): int =
  ## The height of the strip at the top of a docked column (and of a
  ## toolbar made to match it): thin, taller for a finger.
  headH()

type HeaderSide* = enum
  ## Where a `panelHeader`'s arrows go.
  hsLeft, hsCenter, hsRight

proc panelHeader*(r: Rect; id: Id; dir: Dir; tip = ""; side = hsRight): bool =
  ## The strip at the top of a docked column or a toolbar, as today's
  ## Photoshop has it, in the title bar's color (navy in 3.1) with a double
  ## arrow pointing `dir` (white): true when the arrows are clicked (a
  ## column collapsed to icons or opened, a toolbar one column or two).
  let (tbg, tfg) = titleColors(true)
  fill(r, tbg)
  hline(r.x, r.y + r.h - 1, r.w, th.frame)
  let bw = r.h + dp(6)
  let br = case side
           of hsLeft: rect(r.x, r.y, bw, r.h)
           of hsCenter: rect(r.x + (r.w - bw) div 2, r.y, bw, r.h)
           of hsRight: rect(r.x + r.w - bw, r.y, bw, r.h)
  let hit = interact(id, br, focusable = false)
  if accessOn: accessNode(arButton, (if tip.len > 0: tip else: "Fold"), id = id, r = br)
  let ink = if hit.showsHover: mixColor(tfg, tbg, 0.35) else: tfg
  let cy = r.y + r.h div 2
  let s = max(2, min(r.h div 4, dp(4)))
  let cx = br.x + br.w div 2
  arrow(cx - s - 1, cy, dir, ink, s)
  arrow(cx + s + 1, cy, dir, ink, s)
  ui.lastRect = br
  if tip.len > 0: tooltip(tip)
  hit.clicked

proc header(d: Dock; c: DockColumn; r: Rect) =
  ## The strip at the top of a column: its arrows collapse it to icons, or
  ## open it again.
  # (the title bar's color, as a 3.1 palette's: navy, its arrows white)
  if panelHeader(r, refId(c, "dockhead"), (if c.iconic: dLeft else: dRight),
                 (if c.iconic: "Expand Panels" else: "Collapse to Icons"),
                 (if c.iconic: hsCenter else: hsRight)):
    c.iconic = not c.iconic
    if not c.iconic and d.fly != nil and d.fly in c.groups: d.fly = nil
    ui.redraw = true

proc bar(r: Rect) =
  ## (the bar between two groups: a raised ridge)
  fill(r, th.face)
  hline(r.x, r.y, r.w, th.light)
  hline(r.x, r.y + r.h - 1, r.w, th.shadow)

proc openColumn(d: Dock; c: DockColumn; r: Rect; ev: var DockEvent; body: proc (key: string)) =
  let hh = headH()
  d.header(c, rect(r.x, r.y, r.w, hh))
  let th0 = tabsH()
  let bh = barH()
  let n = c.groups.len
  var open = 0
  var shares = 0
  for g in c.groups:
    if not g.folded:
      inc open
      shares += max(1, g.share)
  let room = max(0, r.h - hh - n * th0 - (n - 1) * bh)
  var y = r.y + hh
  var left = room
  var leftShares = shares
  # (the gap above the first group: a new group there)
  d.nextZones.add Zone(r: rect(r.x, r.y, r.w, hh + dp(4)), mark: rect(r.x, r.y + hh - dp(2), r.w, dp(4)),
                       kind: zkNewGroup, prio: 1, col: c, before: (if n > 0: c.groups[0] else: nil))
  for gi, g in c.groups:
    let tr = rect(r.x, y, r.w, th0)
    d.groupTabs(g, tr, ev, folding = true)
    y += th0
    var h = 0
    if not g.folded:
      h = if leftShares <= max(1, g.share): left else: left * max(1, g.share) div max(1, leftShares)
      left -= h
      leftShares -= max(1, g.share)
      d.groupBody(g, rect(r.x, y, r.w, h), body)
    g.lastH = h
    d.nextZones.add Zone(r: rect(r.x, tr.y, r.w, th0 + h), mark: rect(r.x, tr.y, r.w, th0 + h), kind: zkInto,
                         prio: 3, group: g)
    y += h
    if gi < n - 1:
      let br = rect(r.x, y, r.w, bh)
      bar(br)
      let other = c.groups[gi + 1]
      let bid = refId(g, "dockbar")
      let hit = interact(bid, br, focusable = false)
      if (hit.hover or ui.active == bid) and not g.folded and not other.folded and canInput():
        ui.cursor = curSizeNS
      if hit.down and ui.pressed and not g.folded and not other.folded:
        # (the shares made the heights they are: one bar moves two of them)
        for g2 in c.groups:
          if not g2.folded: g2.share = max(1, g2.lastH)
        d.sharing = (g, other, ui.my, g.lastH, other.lastH)
        ui.dragsActive = true
      if ui.active == bid and ui.mouseDown and d.sharing.a == g:
        let tot = d.sharing.ha + d.sharing.hb
        let ha = clamp(d.sharing.ha + ui.my - d.sharing.y0, min(dp(minBody), tot div 2), max(tot div 2, tot - dp(minBody)))
        g.share = max(1, ha)
        other.share = max(1, tot - ha)
        ui.redraw = true
      d.nextZones.add Zone(r: rect(r.x, y - dp(3), r.w, bh + dp(6)), mark: rect(r.x, y, r.w, bh), kind: zkNewGroup,
                           prio: 1, col: c, before: other)
      y += bh
  if y < r.y + r.h: fill(rect(r.x, y, r.w, r.y + r.h - y), th.face)
  d.nextZones.add Zone(r: rect(r.x, y - dp(4), r.w, max(dp(12), r.y + r.h - y + dp(4))),
                       mark: rect(r.x, max(r.y, y - dp(2)), r.w, dp(4)), kind: zkNewGroup, prio: 2, col: c)
  # the left edge sizes the column
  let er = rect(r.x, r.y + hh, dp(4) + (if fingers(): dp(4) else: 0), r.h - hh)
  let eid = refId(c, "dockedge")
  let eh = interact(eid, er, focusable = false)
  if (eh.hover or ui.active == eid) and canInput(): ui.cursor = curSizeWE
  if eh.down and ui.pressed:
    d.sizing = (c, ui.mx, c.colWidth)
    ui.dragsActive = true
  if ui.active == eid and ui.mouseDown and d.sizing.col == c:
    c.width = clamp(d.sizing.w0 + d.sizing.x0 - ui.mx, dp(160), dp(560))
    ui.redraw = true
  vline(r.x, r.y, r.h, th.frame)

proc grip(d: Dock; r: Rect; areaW: int) =
  ## The bar between the documents and the dock: dragged, the whole side
  ## panel widens or narrows (its first open column from the left); all the
  ## columns collapsed to icons, dragged out it opens the main one again.
  let gid = refId(d, "dockgrip")
  let hit = interact(gid, r, focusable = false)
  fill(r, th.face)
  raised(r, 1)
  if (hit.hover or ui.active == gid) and canInput(): ui.cursor = curSizeWE
  var col: DockColumn = nil
  for ci in countdown(d.columns.high, 0):
    if not d.columns[ci].iconic:
      col = d.columns[ci]
      break
  if hit.down and ui.pressed:
    d.sizing = (col, ui.mx, (if col != nil: col.colWidth else: 0))
    ui.dragsActive = true
  if ui.active == gid and ui.mouseDown:
    let dx = d.sizing.x0 - ui.mx
    if d.sizing.col == nil:
      if dx > dp(40) and d.columns.len > 0:
        let c = d.columns[0]
        c.iconic = false
        if d.fly != nil and d.fly in c.groups: d.fly = nil
        d.sizing = (c, d.sizing.x0, iconWidth())
    if d.sizing.col != nil:
      let c = d.sizing.col
      let others = d.width - gripW() - c.colWidth
      let most = max(dp(160), min(dp(900), areaW - others - gripW() - dp(200)))
      c.width = clamp(d.sizing.w0 + dx, dp(160), most)
    ui.redraw = true

proc iconColumn(d: Dock; ci: int; c: DockColumn; r: Rect; ev: var DockEvent) =
  let hh = headH()
  fill(r, th.face)
  d.header(c, rect(r.x, r.y, r.w, hh))
  var y = r.y + hh + dp(3)
  let ih = if fingers(): dp(40) else: dp(26)
  for gi, g in c.groups:
    let y0 = y
    for i, p in g.panels:
      let br = rect(r.x + dp(2), y, r.w - dp(4), ih)
      let iid = idOf("dockicon:" & p.key)
      let hit = interact(iid, br, focusable = false)
      let on = d.fly == g and g.sel == i
      if accessOn:
        accessNode(arToggleButton, tr(p.title), id = iid, r = br,
                   states = (if on: {asPressed, asChecked} else: {}))
      if on:
        fill(br, th.select)
        box(br, th.frame)
      elif hit.showsHover:
        raised(br, 1)
      let ink = if on: th.selectText else: th.text
      if p.icon.len > 0:
        let s = if fingers(): dp(22) else: dp(16)
        image(br.x + (br.w - s) div 2, br.y + (br.h - s) div 2, glyphIcon(p.icon, ink, s))
      else:
        let t = if p.title.len > 0: p.title[0 .. 0] else: "?"
        text(br.x + (br.w - textWidth(t)) div 2, br.y + (br.h - FontH) div 2, t, ink)
      ui.lastRect = br
      tooltip(tr(p.title))
      if hit.down and ui.pressed:
        d.press = (ui.mx, ui.my, g, i)
      if hit.clicked:
        if on: d.fly = nil
        else:
          d.fly = g
          d.flyY = br.y
          g.sel = i
          ev.picked = p.key
        ui.redraw = true
      if ui.active == iid and ui.mouseDown and not d.dragging and d.press.g == g and d.press.i == i and
         abs(ui.mx - d.press.x) + abs(ui.my - d.press.y) > dp(8):
        d.startDrag(p)
      y += ih + dp(2)
    let gr = rect(r.x, y0, r.w, y - y0)
    d.nextZones.add Zone(r: gr, mark: gr, kind: zkInto, prio: 0, group: g)
    d.nextZones.add Zone(r: rect(r.x, y0 - dp(5), r.w, dp(6)), mark: rect(r.x, y0 - dp(4), r.w, dp(3)),
                         kind: zkNewGroup, prio: 1, col: c, before: g)
    if gi < c.groups.high:
      hline(r.x + dp(4), y + dp(2), r.w - dp(8), th.shadow)
      hline(r.x + dp(4), y + dp(3), r.w - dp(8), th.light)
      y += dp(6)
  d.nextZones.add Zone(r: rect(r.x, y, r.w, max(dp(12), r.y + r.h - y)), mark: rect(r.x, y, r.w, dp(3)),
                       kind: zkNewGroup, prio: 2, col: c)
  vline(r.x, r.y, r.h, th.frame)

proc floatAt(d: Dock; a: Rect; p: DockPanel) =
  ## (a panel in a palette of its own, where the mouse is)
  let w = openWidth()
  let g = DockGroup(panels: @[p], share: 100,
                    win: MdiWindow(palette: true, sizable: true, open: true,
                                   r: rect(clamp(ui.mx - a.x - dp(30), 0, max(0, a.w - w)),
                                           clamp(ui.my - a.y - dp(8), 0, max(0, a.h - dp(120))),
                                           w, min(a.h, dp(320)))))
  d.floating.add g

proc dropPanel(d: Dock; a: Rect; ev: var DockEvent) =
  ## The panel dragged, let go: where the mouse is.
  let p = d.dragPanel
  let (src, si, _) = d.find(p.key)
  if src == nil: return
  if d.target < 0 or d.target >= d.zones.len:
    # over the documents: floating (a floating group's only panel: it stays)
    if src.win.r.w > 0 and src.panels.len == 1 and src in d.floating: return
    discard d.takeOut(p.key)
    d.closed.setLen(d.closed.len - 1)
    d.floatAt(a, p)
    ev.floated = p.key
    return
  let z = d.zones[d.target]
  case z.kind
  of zkInto:
    if z.group == src and src.panels.len == 1: return
    var at = z.group.panels.len
    for k, m in z.mids:
      if ui.mx < m:
        at = k
        break
    if z.group == src and si < at: dec at
    discard d.takeOut(p.key)
    d.closed.setLen(d.closed.len - 1)
    at = clamp(at, 0, z.group.panels.len)
    z.group.panels.insert(p, at)
    z.group.sel = at
    z.group.folded = false
  of zkNewGroup:
    if src.panels.len == 1 and (z.before == src or (z.col != nil and z.col.groups.find(src) >= 0 and
       z.col.groups.find(src) == z.col.groups.find(z.before) - 1)):
      return                                # (where it is already)
    discard d.takeOut(p.key)
    d.closed.setLen(d.closed.len - 1)
    let ng = DockGroup(panels: @[p], share: 100)
    if z.col notin d.columns: d.columns.add z.col
    let at = if z.before == nil: z.col.groups.len else: max(0, z.col.groups.find(z.before))
    z.col.groups.insert(ng, clamp(at, 0, z.col.groups.len))
    if z.col.iconic: d.fly = ng
  of zkNewColumn:
    discard d.takeOut(p.key)
    d.closed.setLen(d.closed.len - 1)
    let nc = DockColumn()
    nc.groups.add DockGroup(panels: @[p], share: 100)
    d.columns.add nc
  d.dropEmpty()

proc dropGroup(d: Dock; g: DockGroup) =
  ## A floating group dragged by its title, let go over the dock: its panels
  ## go there.
  if d.target < 0 or d.target >= d.zones.len: return
  let z = d.zones[d.target]
  if z.kind == zkInto and z.group == g: return
  let i = d.floating.find(g)
  if i < 0: return
  d.floating.delete(i)
  case z.kind
  of zkInto:
    for p in g.panels: z.group.panels.add p
    z.group.sel = z.group.panels.len - g.panels.len + clamp(g.sel, 0, g.panels.high)
    z.group.folded = false
  of zkNewGroup:
    let ng = DockGroup(panels: g.panels, sel: g.sel, share: 100)
    if z.col notin d.columns: d.columns.add z.col
    let at = if z.before == nil: z.col.groups.len else: max(0, z.col.groups.find(z.before))
    z.col.groups.insert(ng, clamp(at, 0, z.col.groups.len))
  of zkNewColumn:
    let nc = DockColumn()
    nc.groups.add DockGroup(panels: g.panels, sel: g.sel, share: 100)
    d.columns.add nc
  d.dropEmpty()
  ui.redraw = true

proc targetOf(d: Dock): int =
  ## (the zone under the mouse, the most precise first)
  result = -1
  var best = high(int)
  for i, z in d.zones:
    if z.r.contains(point(ui.mx, ui.my)) and z.prio < best:
      best = z.prio
      result = i

proc dockPanels*(d: Dock; area = ""; body: proc (key: string); menu: proc (key: string) = nil): DockEvent =
  ## Draws the dock down the right of the `mdiArea` named `area` (call it
  ## inside, after the documents' windows), its floating palettes, and
  ## what a drag of a panel shows. `body(key)` draws a panel (in a column
  ## laid out as a palette's: `place`, `row`, the widgets); `menu(key)` its
  ## menu's items (`menuItem`...), Close and Close Tab Group after them.
  ## `left` says where the documents' room ends.
  let a = mdiAreaRect(area)
  d.nextZones.setLen(0)
  let total = d.width
  d.left = a.w - total
  if total > 0:
    d.win.r = rect(a.w - total, 0, total, a.h)
    if beginMdiWindow(d.win):
      var x = a.x + a.w
      for ci, c in d.columns:
        let w = c.colWidth
        x -= w
        let r = rect(x, a.y, w, a.h)
        if c.iconic: d.iconColumn(ci, c, r, result) else: d.openColumn(c, r, result, body)
      if d.columns.len > 0: d.grip(rect(x - gripW(), a.y, gripW(), a.h), a.w)
      endMdiWindow()
    # (to the left of the dock: a column of its own)
    if d.columns.len > 0:
      d.nextZones.add Zone(r: rect(a.x + d.left - dp(14), a.y, dp(14), a.h),
                           mark: rect(a.x + d.left - dp(4), a.y, dp(4), a.h), kind: zkNewColumn, prio: 1)
  # a collapsed column's group, beside its icons
  if d.fly != nil:
    var fc = -1
    var fx = a.x + a.w
    for ci, c in d.columns:
      fx -= c.colWidth
      if d.fly in c.groups and c.iconic:
        fc = ci
        break
    if fc < 0: d.fly = nil
    else:
      let c = d.columns[fc]
      let fw = if c.width > 0: c.width else: openWidth()
      let fh = min(a.h - dp(8), max(dp(300), a.h * 2 div 3))
      let fy = clamp((if d.flyY > 0: d.flyY - a.y else: dp(20)) - dp(4), 0, max(0, a.h - fh))
      let fr = rect(fx - fw - a.x, fy, fw, fh)
      d.flyWin.r = fr
      if beginMdiWindow(d.flyWin):
        let sr = rect(a.x + fr.x, a.y + fr.y, fr.w, fr.h)
        fill(sr, th.face)
        let tr = rect(sr.x + 1, sr.y + 1, sr.w - 2, tabsH())
        d.groupTabs(d.fly, tr, result, folding = false)
        d.groupBody(d.fly, rect(sr.x + 1, tr.y + tr.h, sr.w - 2, sr.y + sr.h - 1 - tr.y - tr.h), body)
        box(sr, th.frame)
        endMdiWindow()
        # (a click elsewhere, or Esc, puts it away)
        let strip = rect(fx, a.y, c.colWidth, a.h)
        if not d.dragging and ui.pressed and not mouseIn(sr) and not mouseIn(strip) and
           not popupMenuOpen("dock:menu"):
          d.fly = nil
          ui.redraw = true
        if canInput() and not ui.keyUsed and ui.key == KeyEsc and not popupMenuOpen("dock:menu"):
          d.fly = nil
          ui.keyUsed = true
          ui.redraw = true
  # the floating groups
  var lost: seq[DockGroup]
  for g in d.floating:
    if not g.win.open:
      lost.add g
      continue
    g.win.title = ""
    if beginMdiWindow(g.win):
      let tr = place(0, tabsH(), fill = true)
      d.groupTabs(g, tr, result, folding = false)
      let rest = max(dp(minBody), remainingH())
      let br = place(0, rest, fill = true)
      d.groupBody(g, br, body)
      endMdiWindow()
    # (dragged by its title over the dock: docked there when let go)
    if mdiTitleDragged(g.win):
      d.dragGroup = g
      d.target = d.targetOf()
      if d.target >= 0 and d.zones[d.target].kind == zkInto and d.zones[d.target].group == g: d.target = -1
    elif d.dragGroup == g:
      d.dragGroup = nil
      d.dropGroup(g)
  for g in lost:
    # (its close box: its panels closed, where they were kept)
    for p in g.panels:
      d.closed.add (p, -1, -1)
    d.floating.delete(d.floating.find(g))
  # a panel dragged: where it would go lights up, its tab follows the mouse
  if d.dragging:
    d.target = d.targetOf()
    if ui.mouseDown:
      if d.target >= 0:
        let m = d.zones[d.target].mark
        d.markWin.r = rect(m.x - a.x, m.y - a.y, m.w, m.h)
        if beginMdiWindow(d.markWin):
          let mr = rect(m.x, m.y, m.w, m.h)
          if m.h <= dp(6) or m.w <= dp(6): fill(mr, th.select)
          else: dropHighlight(mr)
          endMdiWindow()
      let st = style(size = 0.9)
      let gw = textWidth(tr(d.dragPanel.title), st) + dp(14)
      let gh = tabsH()
      d.ghostWin.r = rect(ui.mx - a.x + dp(10), ui.my - a.y + dp(10), gw, gh)
      if beginMdiWindow(d.ghostWin):
        tabLook(rect(ui.mx + dp(10), ui.my + dp(10), gw, gh), tr(d.dragPanel.title), true, false, st)
        endMdiWindow()
      ui.cursor = curHand
      ui.redraw = true
    else:
      d.dragging = false
      d.dropPanel(a, result)
      ui.redraw = true
  elif d.dragGroup != nil and d.target >= 0 and d.target < d.zones.len:
    let m = d.zones[d.target].mark
    d.markWin.r = rect(m.x - a.x, m.y - a.y, m.w, m.h)
    if beginMdiWindow(d.markWin):
      let mr = rect(m.x, m.y, m.w, m.h)
      if m.h <= dp(6) or m.w <= dp(6): fill(mr, th.select)
      else: dropHighlight(mr)
      endMdiWindow()
  # the panel's menu
  popupMenu("dock:menu"):
    if menu != nil and d.menuFor.len > 0:
      menu(d.menuFor)
      menuSeparator()
    if menuItem("Close"): d.closePanel(d.menuFor)
    if menuItem("Close Tab Group"):
      let (g, _, _) = d.find(d.menuFor)
      if g != nil:
        let ps = g.panels
        for p in ps: d.closePanel(p.key)
  swap(d.zones, d.nextZones)

proc coverRects*(d: Dock; area = ""): seq[Rect] =
  ## Where the dock covers the area now (as last drawn): its columns, its
  ## floating palettes, a collapsed column's group shown beside its icons --
  ## for what the area draws by hand under them (a canvas) to leave their
  ## clicks to them.
  let a = mdiAreaRect(area)
  let total = d.width
  if total > 0: result.add rect(a.x + a.w - total, a.y, total, a.h)
  for g in d.floating:
    if g.win.open: result.add rect(a.x + g.win.r.x, a.y + g.win.r.y, g.win.r.w, g.win.r.h)
  if d.fly != nil: result.add rect(a.x + d.flyWin.r.x, a.y + d.flyWin.r.y, d.flyWin.r.w, d.flyWin.r.h)

proc dockMenuOpen*(d: Dock): bool =
  ## A panel's menu is open.
  popupMenuOpen("dock:menu")

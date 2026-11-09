## Desktop parts:
##
## - `mdiArea` / `mdiWindow`: windows inside the app's window, as in
##   Program Manager and File Manager -- moved by their title bars, sized by
##   their edges, minimized to icons, maximized, cascaded and tiled from a
##   Window menu (`mdiWindowMenu`), Ctrl+F6 to the next one, Ctrl+F4 to
##   close
## - `findBar`, `findIn`, `replaceAllIn`: find (and replace) in a text, with
##   Match case and Whole word, F3 / Shift+F3
## - `hotkeyEdit`, `hotkeyText`, `parseHotkey`, `hotkeyPressed`: shortcuts
##   the user picks ("Ctrl+Shift+S")
## - `aboutBox`: the About dialog of a 3.1 program
##
## ```nim
## var doc = MdiWindow(title: "Accounts", r: rect(10, 10, 260, 170), open: true)
## var finder: FindState
## var text = "one two three"
## app "Books", 800, 600:
##   if hotkeyPressed("Ctrl+F"): finder.open = true
##   let fe = findBar(finder)
##   if fe.next: echo findIn(text, finder.what, 0, finder.matchCase, finder.wholeWord)
##   mdiArea(-1):
##     mdiWindow(doc):
##       label "Cash: 5,400.00"
## ```

import std/[strutils, tables, hashes, uri]
import gfx, core, widgets, pixelicons, nerdicons, platform, imaging, memwatch
import uirelays/services
import uirelays/input

template th: untyped = ui.theme

# ---- windows in the window (MDI) ---------------------------------------------------------------

type
  MdiWindow* = object
    ## A window inside an `mdiArea`. Keep it in a global (or a ref): it is
    ## known by where it is stored.
    title*: string           ## shown in its title bar and the Window menu
    glyph*: string           ## its icon when minimized ("" a window icon)
    r*: Rect                 ## where it is in the area (logical pixels; set it
                             ## to place it, 0 x 0 for a place of its own)
    open*: bool              ## shown; Close (Ctrl+F4) sets it false
    minimized*, maximized*: bool  ## shown as an icon; filling the area
    palette*: bool           ## a floating palette (a tool window): a thin
                             ## title bar with a close box, always over the
                             ## other windows, never the active document
    sizable*: bool           ## a palette that can be sized (by its edges)
    flush*: bool             ## the content fills the window (no padding, no
                             ## scrolling): a canvas, a picture
    docked*: bool            ## no frame, no title bar: it fills `r` (set it each
                             ## frame) behind the other windows -- the tabbed
                             ## documents' window; a click makes it the active one
                             ## (with `sizable`: a frame, its right and bottom
                             ## edges and the grip at the corner size it)
    userSized*: bool         ## a docked window sized by the user (keep `r` then)
    grip*: bool              ## a size grip at the lower right corner, over the content's
                             ## corner (where its scroll bars meet): a window sized with a
                             ## finger as easily as with a mouse
    gripSize*: int           ## ... its size (logical pixels; 0: a scroll bar's width)
    fixed*: bool             ## a palette that is only moved: no close box (a toolbar)
    bare*: bool              ## a palette with no title bar and no frame: it fills `r`, over
                             ## the documents, and draws all of itself (a dock of panels)
    pinned*: bool            ## always on top of the other windows (the palettes still over
                             ## it): its control menu's "Always on Top", the pin in its title
                             ## bar, or the Window menu -- not while it is maximized (it fills
                             ## the area then: the pin waits, grayed, until it is restored)
    noPin*: bool             ## no pin in its title bar (a window that is never kept on top:
                             ## Program Manager's groups, as 3.1 had them)
  MdiCommand = enum mcNone, mcCascade, mcTile, mcArrange, mcActivate, mcClose, mcPin
  MdiState = object
    z: seq[uint]                          # windows, back to front
    rects: Table[uint, Rect]              # where each was on screen last frame
    titles: seq[tuple[key: uint; title: string]]
    seen: seq[uint]
    spans: seq[tuple[a, b: int]]
    spanKeys: seq[uint]
    area: Rect
    cmd: MdiCommand
    cmdKey: uint
    nOpen, nIcons, iconAt: int
    palettes: seq[uint]                   # the windows that are palettes
    pinned: seq[uint]                     # the windows always on top of the others
    maxed: seq[uint]                      # the windows maximized (their pin waits)
    docked: seq[uint]                     # the windows docked behind the others
    unpinned: seq[uint]                   # the windows never kept on top (`noPin`)
    chosen: uint                          # a docked window clicked last (the active one)
  MdiFrame = object
    key: uint
    client: Rect
    scrolls: bool
    start: int
    id: Id
    pad: int                 # the room around the content (Pad; PalettePad)
    grip: bool               # a docked window that sizes: its grip drawn over the content
    gripSize: int            # (its size: 0 the docked one's)

var
  mdis: Table[string, MdiState]
  mdiKey: string
  mdiStack: seq[MdiFrame]

template MdiTitleH: int = FontH + (if fingers(): dp(10) else: dp(5))
template PaletteTitleH*: int = (if fingers(): dp(16) else: dp(10))
  ## The height of a palette's title bar.
template PalettePad*: int = dp(3)
  ## The room around a palette's content.

proc sizable(w: MdiWindow): bool {.inline.} = w.sizable

proc paletteSize*(clientW, clientH: int): (int, int) =
  ## The size a palette needs (for `MdiWindow.r`) to hold `clientW` x
  ## `clientH` of content.
  (clientW + 2 + 2 * PalettePad, clientH + PaletteTitleH + 2 + 2 * PalettePad)

proc mdiWindowSize*(clientW, clientH: int): (int, int) =
  ## The size a document window (for `MdiWindow.r`) needs to hold `clientW`
  ## x `clientH` of content (a `flush` window's; add the padding otherwise).
  let border = dp(5)
  (clientW + 2 * border, clientH + MdiTitleH + 1 + 2 * border)

proc keyOf(w: var MdiWindow): uint = cast[uint](addr w)

proc beginMdi*(height = -1; key = ""; bg = Color(); edgeToEdge = false): bool =
  ## The workspace of `mdiWindow`s (`height` -1: the room left; `bg` its
  ## color, the panels' gray -- the face -- when not given). `edgeToEdge`:
  ## from the window's left edge to its right and (with `height` -1) down
  ## to its foot, with no margin of the window's color round it (an
  ## application's workspace, as Photoshop's).
  let above = frameBottom()
  var r = place(0, if height < 0: remainingH() else: height, fill = true)
  if edgeToEdge:
    # (flush under what is above it -- the bars at the top, or the widget
    # before it: no margin, no gap)
    let top = if r.y - barsBottom() <= Pad + 1: barsBottom() else: min(r.y, above)
    if top < r.y:
      r.h += r.y - top
      r.y = top
    r.x = ui.safe.left
    r.w = ui.w - ui.safe.left - ui.safe.right
    # (down to the foot -- or to a status bar drawn before it)
    if height < 0: r.h = max(r.h, ui.bottom - r.y)
  mdiKey = key
  var m = mdis.getOrDefault(key)
  m.area = r
  m.seen.setLen(0)
  m.spans.setLen(0)
  m.spanKeys.setLen(0)
  m.titles.setLen(0)
  m.iconAt = 0
  mdis[key] = m
  # (the workspace: the panels' gray, unless asked)
  fill(r, if bg.a == 0: th.face else: bg)
  if edgeToEdge:
    pushClip(r)
  else:
    box(r, th.edge)
    pushClip(inset(r, 1))
  ui.lastId = 0
  ui.lastRect = r
  true

proc mdiTop(m: MdiState): uint =
  ## The active window: the one on top (palettes left out), or the docked
  ## window when it was clicked last.
  if m.chosen != 0 and m.chosen in m.z: return m.chosen
  for i in countdown(m.z.high, 0):
    if m.z[i] notin m.palettes and m.z[i] notin m.docked: return m.z[i]
  for k in m.z:
    if k in m.docked: return k
  0

proc firstPalette(m: MdiState): int =
  ## Where the palettes begin in the stack (they are all on top).
  result = m.z.len
  for i, k in m.z:
    if k in m.palettes: return i

proc firstPinned(m: MdiState): int =
  ## Where the windows always on top begin (under the palettes).
  result = m.firstPalette
  for i, k in m.z:
    if k in m.pinned and k notin m.palettes: return min(i, result)

proc toFront(m: var MdiState; key: uint) =
  let i = m.z.find(key)
  if i < 0: return
  if key in m.docked:
    # (a docked window stays at the back; it is the active one now)
    if m.chosen != key: ui.redraw = true
    m.chosen = key
    return
  if key notin m.palettes:
    if m.chosen != 0: ui.redraw = true
    m.chosen = 0
  m.z.delete(i)
  if key in m.palettes: m.z.add key
  elif key in m.pinned: m.z.insert(key, m.firstPalette)
  else:
    # (under the windows always on top -- and still the active one)
    let at = m.firstPinned
    if at < m.firstPalette:
      m.chosen = key
      ui.redraw = true
    m.z.insert(key, at)
  if m.z.find(key) != i: ui.redraw = true

proc winButton(id: Id; r: Rect; kind: int): bool =
  ## The minimize (0), maximize (1) and restore (2) buttons of a title bar.
  let hit = interact(id, r, focusable = false)
  if accessOn: accessNode(arButton, ["Minimize", "Maximize", "Restore"][clamp(kind, 0, 2)], id = id, r = r)
  # the Win31 caption button: a black line at its left, a gray face
  vline(r.x, r.y, r.h, th.frame)
  let f = rect(r.x + 1, r.y, r.w - 1, r.h)
  captionButton(f, hit.down)
  case kind
  of 0: captionArrow(f, false, hit.down)
  of 1: captionArrow(f, true, hit.down)
  else: captionRestore(f, hit.down)
  hit.clicked

proc beginMdiWindow*(w: var MdiWindow): bool =
  ## A window of the current `mdiArea`; draw its content after it (see
  ## `mdiWindow`). False when it is closed or minimized (an icon then).
  if not mdis.hasKey(mdiKey): return false
  var m = mdis[mdiKey]
  let key = keyOf(w)
  if w.palette:
    if key notin m.palettes: m.palettes.add key
    w.minimized = false
    w.maximized = false
  elif key in m.palettes:
    m.palettes.delete(m.palettes.find(key))
  if w.docked:
    if key notin m.docked: m.docked.add key
    w.minimized = false
    w.maximized = false
  elif key in m.docked:
    m.docked.delete(m.docked.find(key))
    if m.chosen == key: m.chosen = 0
  if w.noPin != (key in m.unpinned):
    if w.noPin: m.unpinned.add key
    else: m.unpinned.delete(m.unpinned.find(key))
  if w.noPin: w.pinned = false
  # always on top: kept over the other documents (asked for by the Window
  # menu last frame, or set by the program)
  if m.cmd == mcPin and m.cmdKey == key and not w.maximized: w.pinned = not w.pinned
  if w.maximized != (key in m.maxed):
    if w.maximized: m.maxed.add key
    else: m.maxed.delete(m.maxed.find(key))
  let pin = w.pinned and not w.palette and not w.docked and not w.maximized
  if pin != (key in m.pinned):
    if pin: m.pinned.add key
    else: m.pinned.delete(m.pinned.find(key))
    if key in m.z: m.toFront(key)
    ui.redraw = true
  if key notin m.z:                             # new: on top (of the documents)
    if w.palette: m.z.add key
    elif w.docked: m.z.insert(key, 0)
    elif pin: m.z.insert(key, m.firstPalette)
    else: m.z.insert(key, m.firstPinned)
  elif w.docked and m.z.find(key) != 0:         # (a docked window: always at the back)
    m.z.delete(m.z.find(key))
    m.z.insert(key, 0)
  m.seen.add key
  if not w.palette and not w.docked: m.titles.add (key, w.title)
  let a = m.area
  # what the Window menu or the keys asked for last frame
  case m.cmd
  of mcActivate:
    if m.cmdKey == key:
      w.open = true
      w.minimized = false
      m.toFront(key)
  of mcClose:
    if m.cmdKey == key: w.open = false
  else: discard
  if not w.open:
    mdis[mdiKey] = m
    return false
  # a new window: a place of its own
  if w.r.w <= 0 or w.r.h <= 0:
    let k = m.z.find(key)
    w.r = rect(dp(16) + k * MdiTitleH, dp(16) + k * MdiTitleH,
               max(dp(200), a.w div 2), max(dp(140), a.h div 2))
  # cascade, tile: by the place in the stack
  if m.cmd in {mcCascade, mcTile} and not w.minimized and not w.palette and not w.docked:
    var rank = 0
    for k2 in m.z:
      if k2 == key: break
      if k2 notin m.docked: inc rank
    w.maximized = false
    let n = max(1, m.nOpen)
    if m.cmd == mcCascade:
      let step = MdiTitleH + dp(4)
      w.r = rect(rank * step, rank * step, max(dp(160), a.w * 3 div 5),
                 max(dp(120), a.h * 3 div 5))
    else:
      var cols = 1
      while cols * cols < n: inc cols
      let rowsN = (n + cols - 1) div cols
      let cw = a.w div cols
      let ch = (a.h - (if m.nIcons > 0: dp(64) else: 0)) div rowsN
      w.r = rect(rank mod cols * cw, rank div cols * ch, cw, ch)
  let id = Id(mixId(uint32(key and 0xFFFFFFFF'u), uint32(key shr 32) xor 0x6d6469'u32))
  # minimized: an icon along the bottom of the area (and not the active
  # window any more: it goes to the back)
  if w.minimized and m.z.len > 1 and m.mdiTop == key:
    m.z.delete(m.z.high)
    m.z.insert(key, 0)
    ui.redraw = true
  if w.minimized:
    let iw = dp(76)
    let ih = dp(32) + FontH + dp(6)
    let per = max(1, (a.w - dp(8)) div iw)
    let ir = rect(a.x + dp(4) + m.iconAt mod per * iw,
                  a.y + a.h - ih - dp(4) - m.iconAt div per * ih, iw, ih)
    inc m.iconAt
    # (under the windows: they keep their clicks)
    ui.blockers.setLen(0)
    for k2, wr in m.rects:
      if k2 != key: ui.blockers.add wr
    let hit = interact(id + 1, ir)
    ui.blockers.setLen(0)
    if accessOn: accessNode(arButton, tr(w.title), id = id + 1, r = ir, help = "minimized")
    if accessPressed == id + 1:
      w.minimized = false
      m.toFront(key)
    if hit.clicked: m.toFront(key)
    if (hit.down and ui.pressed and ui.clicks >= 2) or (hit.focused and keyHit(KeyEnter)):
      w.minimized = false
      m.toFront(key)
    let g = if w.glyph.len > 0: w.glyph else: retroOr(pxApp, nfWindowMaximize)
    image(ir.x + (ir.w - dp(32)) div 2, ir.y, glyphIcon(g, th.text, dp(32)))
    let label = ellipsize(tr(w.title), ir.w)
    let lr = rect(ir.x + (ir.w - textWidth(label)) div 2 - 2, ir.y + dp(34),
                  textWidth(label) + 4, FontH + 2)
    if hit.focused:
      fill(lr, th.select)
      text(lr.x + 2, lr.y + 1, label, th.selectText)
    else:
      text(lr.x + 2, lr.y + 1, label, th.text)
    mdis[mdiKey] = m
    return false
  # where it is now, and what lies over it
  var sr = if w.maximized: inset(a, 1)
           else: rect(a.x + w.r.x, a.y + w.r.y, w.r.w, w.r.h)
  # (a window in the window: a pane named by its title, its title bar's
  # buttons and its content inside; `endMdiWindow` closes it)
  if accessOn: accessBegin(arPane, tr(w.title), sr, id)
  ui.blockers.setLen(0)
  let at = m.z.find(key)
  for k2 in at + 1 .. m.z.high:
    if m.rects.hasKey(m.z[k2]): ui.blockers.add m.rects[m.z[k2]]
  let start = cmdMark()
  let active = m.mdiTop == key
  # a press anywhere on it brings it to the front
  if ui.pressed and canInput() and mouseIn(sr): m.toFront(key)
  if w.docked:
    # docked: the area it was given, no frame (the tabbed documents); sizable:
    # a frame, and its right and bottom edges and the corner drag its size
    var client = sr
    if w.sizable:
      let e = dp(6)
      let zones = [rect(sr.x + sr.w - e, sr.y, e, sr.h - e), rect(sr.x, sr.y + sr.h - e, sr.w - e, e),
                   rect(sr.x + sr.w - dp(16), sr.y + sr.h - dp(16), dp(16), dp(16))]
      for z in countdown(2, 0):
        let zid = id + uint32(20 + z)
        let hz = interact(zid, zones[z], focusable = false)
        if (hz.hover or ui.active == zid) and canInput():
          ui.cursor = if z == 0: curSizeWE else: curSizeNS
        var zs = state(zid)
        if hz.down and ui.pressed:
          zs.anchor = ui.mx
          zs.aux = ui.my
          zs.caret = w.r.w
          zs.aux2 = w.r.h
          ui.dragsActive = true
        if ui.active == zid and ui.mouseDown:
          if z in [0, 2]: w.r.w = clamp(zs.caret + ui.mx - zs.anchor, dp(160), max(dp(160), a.w - w.r.x))
          if z in [1, 2]: w.r.h = clamp(zs.aux2 + ui.my - zs.aux, dp(120), max(dp(120), a.h - w.r.y))
          w.userSized = true
        state(zid) = zs
      sr = rect(a.x + w.r.x, a.y + w.r.y, w.r.w, w.r.h)
      box(sr, th.frame)
      client = inset(sr, 1)
    m.rects[key] = sr
    mdis[mdiKey] = m
    fill(client, th.window)
    pushClip(client)
    beginClipped()
    pushFrame(client)
    mdiStack.add MdiFrame(key: key, client: client, scrolls: false, start: start, id: id, pad: 0,
                          grip: w.sizable)
    return true
  if w.palette and w.bare:
    # (nothing of its own: what it holds draws it all)
    m.rects[key] = sr
    mdis[mdiKey] = m
    pushClip(sr)
    beginClipped()
    pushFrame(sr)
    mdiStack.add MdiFrame(key: key, client: sr, scrolls: false, start: start, id: id, pad: 0)
    return true
  if w.palette:
    # a palette: a black line around, a thin title bar with a close box
    let barH = PaletteTitleH
    let title = rect(sr.x + 1, sr.y + 1, sr.w - 2, barH)
    let closeR = rect(title.x, title.y, if w.fixed: 0 else: barH, barH)
    let drag = rect(closeR.x + closeR.w, title.y, title.w - closeR.w, barH)
    let dragHit = interact(id + 2, drag, focusable = false)
    var st = state(id + 2)
    if dragHit.down and ui.pressed:
      st.anchor = ui.mx - sr.x
      st.aux = ui.my - sr.y
      ui.dragsActive = true
    if ui.active == id + 2 and ui.mouseDown:
      w.r.x = clamp(ui.mx - st.anchor - a.x, -w.r.w + dp(30), a.w - dp(30))
      w.r.y = clamp(ui.my - st.aux - a.y, 0, max(0, a.h - barH))
    state(id + 2) = st
    if w.sizable:
      let e = dp(5)
      let zones = [rect(sr.x + sr.w - e, sr.y + barH, e, sr.h - barH - e),
                   rect(sr.x, sr.y + sr.h - e, sr.w - e, e),
                   rect(sr.x + sr.w - e, sr.y + sr.h - e, e, e)]
      for z in 0 .. 2:
        let zid = id + uint32(10 + z)
        let hz = interact(zid, zones[z], focusable = false)
        if (hz.hover or ui.active == zid) and canInput():
          ui.cursor = if z == 0: curSizeWE elif z == 1: curSizeNS else: curSizeNS
        var zs = state(zid)
        if hz.down and ui.pressed:
          zs.anchor = ui.mx
          zs.aux = ui.my
          zs.caret = w.r.w
          zs.aux2 = w.r.h
          ui.dragsActive = true
        if ui.active == zid and ui.mouseDown:
          if z in [0, 2]: w.r.w = max(dp(80), zs.caret + ui.mx - zs.anchor)
          if z in [1, 2]: w.r.h = max(barH + dp(40), zs.aux2 + ui.my - zs.aux)
        state(zid) = zs
    sr = rect(a.x + w.r.x, a.y + w.r.y, w.r.w, w.r.h)
    let title2 = rect(sr.x + 1, sr.y + 1, sr.w - 2, barH)
    fill(sr, th.face)
    box(sr, th.frame)
    let (tbg, _) = titleColors(true)
    fill(title2, tbg)
    hline(title2.x, title2.y + barH, title2.w, th.frame)
    # the close box: a little square with a bar, as the 3.1 palettes had (a
    # fixed palette -- the toolbar -- has none: it is only moved)
    if not w.fixed:
      let cb = rect(title2.x, title2.y, barH, barH)
      let ch = interact(id + 5, cb, focusable = false)
      if accessOn: accessNode(arButton, "Close", id = id + 5, r = cb)
      fill(cb, th.face)
      vline(cb.x + cb.w, cb.y, cb.h, th.frame)
      let bw = max(3, barH div 2)
      fill(rect(cb.x + (cb.w - bw) div 2, cb.y + cb.h div 2 - 1, bw, max(1, barH div 6)),
           if ch.down: th.shadow else: th.text)
      if ch.clicked: w.open = false
    if sizable(w):
      # the grip at the lower right
      for k in 1 .. 3:
        line(sr.x + sr.w - 2 - k * dp(3), sr.y + sr.h - 2, sr.x + sr.w - 2, sr.y + sr.h - 2 - k * dp(3), th.shadow)
    let client = rect(sr.x + 1, title2.y + barH + 1, sr.w - 2, sr.y + sr.h - 1 - (title2.y + barH + 1))
    m.rects[key] = sr
    mdis[mdiKey] = m
    # (what is taller than the palette scrolls: a short screen, a touch screen)
    var cs = state(id + 6)
    let scrolls = cs.aux > client.h
    let off = if scrolls: clamp(cs.scrollY, 0, cs.aux - client.h) else: 0
    pushClip(client)
    beginClipped()
    pushFrame(rect(client.x + PalettePad, client.y + PalettePad - off,
                   client.w - 2 * PalettePad - (if scrolls: SbW else: 0), client.h - 2 * PalettePad + off))
    mdiStack.add MdiFrame(key: key, client: client, scrolls: scrolls, start: start, id: id,
                          pad: PalettePad)
    return true
  let border = if w.maximized: 0 else: dp(5)
  let barH = MdiTitleH
  var title = rect(sr.x + border, sr.y + border, sr.w - 2 * border, barH)
  let sysBox = rect(title.x, title.y, barH, barH)
  let bs = barH
  let maxBox = rect(title.x + title.w - bs, title.y, bs, barH)
  let minBox = rect(maxBox.x - bs, title.y, bs, barH)
  let pinBox = if w.noPin: rect(minBox.x, title.y, 0, barH)
               else: rect(minBox.x - bs - dp(2), title.y, bs, barH)
  # moving by the title bar (up to its buttons: the pin's press is the pin's), sizing by the edges
  if not w.maximized:
    let drag = rect(sysBox.x + sysBox.w, title.y, pinBox.x - sysBox.x - sysBox.w, barH)
    let dragHit = interact(id + 2, drag, focusable = false)
    var st = state(id + 2)
    if dragHit.down and ui.pressed:
      st.anchor = ui.mx - sr.x
      st.aux = ui.my - sr.y
      ui.dragsActive = true
      if ui.clicks >= 2: w.maximized = true
    if ui.active == id + 2 and ui.mouseDown:
      w.r.x = clamp(ui.mx - st.anchor - a.x, -w.r.w + dp(60), a.w - dp(60))
      w.r.y = clamp(ui.my - st.aux - a.y, 0, max(0, a.h - barH))
    state(id + 2) = st
    # edges and corners (wider for a finger); the grip, the lower right
    # corner (over the content's: where its scroll bars meet)
    let e = if fingers(): dp(10) else: dp(5)
    let gs = (if w.gripSize > 0: w.gripSize else: SbW) + border
    let zones = [rect(sr.x + sr.w - e, sr.y + e, e, sr.h - 2 * e),      # right
                 rect(sr.x, sr.y + sr.h - e, sr.w, e),                   # bottom
                 rect(sr.x, sr.y + e, e, sr.h - 2 * e),                  # left
                 rect(sr.x + e, sr.y, sr.w - 2 * e, e div 2 + 1),        # top
                 (if w.grip: rect(sr.x + sr.w - gs, sr.y + sr.h - gs, gs, gs) else: rect(0, 0, 0, 0))]
    for z in countdown(4, 0):
      let zid = id + uint32(10 + z)
      let hz = interact(zid, zones[z], focusable = false)
      if (hz.hover or ui.active == zid) and canInput():
        ui.cursor = if z in [0, 2]: curSizeWE else: curSizeNS
      var zs = state(zid)
      if hz.down and ui.pressed:
        zs.anchor = ui.mx
        zs.aux = ui.my
        zs.scrollX = w.r.x
        zs.scrollY = w.r.y
        zs.caret = w.r.w
        zs.aux2 = w.r.h
        ui.dragsActive = true
      if ui.active == zid and ui.mouseDown:
        let dx = ui.mx - zs.anchor
        let dy = ui.my - zs.aux
        let minW = dp(140)
        let minH = barH + dp(60)
        case z
        of 0: w.r.w = max(minW, zs.caret + dx)
        of 1: w.r.h = max(minH, zs.aux2 + dy)
        of 4:
          w.r.w = max(minW, zs.caret + dx)
          w.r.h = max(minH, zs.aux2 + dy)
        of 2:
          let nw = max(minW, zs.caret - dx)
          w.r.x = zs.scrollX + zs.caret - nw
          w.r.w = nw
        else:
          let nh = max(minH, zs.aux2 - dy)
          w.r.y = max(0, zs.scrollY + zs.aux2 - nh)
          w.r.h = nh
      state(zid) = zs
    sr = rect(a.x + w.r.x, a.y + w.r.y, w.r.w, w.r.h)
    title = rect(sr.x + border, sr.y + border, sr.w - 2 * border, barH)
  # draw the frame: the sizing border, the title bar, its boxes
  if border > 0: windowFrame(sr, border)
  let (tbg, tfg) = titleColors(active)
  fill(title, tbg)
  hline(title.x, title.y + title.h, title.w, th.frame)
  let sys = rect(title.x, title.y, barH, barH)
  captionButton(sys, false)
  vline(sys.x + sys.w, sys.y, sys.h, th.frame)
  controlMenuMark(sys)
  let mx2 = rect(title.x + title.w - bs, title.y, bs, barH)
  let mn2 = rect(mx2.x - bs, title.y, bs, barH)
  # (the pin: always on top -- shown pressed while it is)
  let pinR = if w.noPin: rect(mn2.x, title.y, 0, barH)
             else: rect(mn2.x - bs - dp(2), title.y, bs, barH)
  let wt = tr(w.title)
  let tw = textWidth(wt, true)
  let room = pinR.x - sys.x - sys.w - dp(8)
  let shownTitle = if tw > room: ellipsize(wt, room, style(bold = true)) else: wt
  text(sys.x + sys.w + max(dp(4), (room - textWidth(shownTitle, true)) div 2 + dp(4)),
       title.y + (barH - FontH) div 2, shownTitle, tfg, true)
  if not w.noPin:
    # (maximized: the pin waits, grayed -- a window that fills the area is not
    # kept over the others)
    let can = not w.maximized
    let ph = interact(id + 7, pinR, focusable = false, enabled = can)
    if accessOn:
      accessNode(arToggleButton, "Always on Top", id = id + 7, r = pinR,
                 states = accessOff(can) + (if w.pinned: {asPressed, asChecked} else: {}))
    let down = can and (ph.down or w.pinned)
    captionButton(pinR, down)
    # (on: latched in, as a 3.1 tool bar's button that stays down -- its face dithered)
    if can and w.pinned and not ph.down:
      ditherFill(rect(pinR.x + 1, pinR.y + 1, pinR.w - 2, pinR.h - 2), th.face, th.light)
    let pg = retroOr(pxPin, nfPin)
    let o = if down: 1 else: 0
    if can:
      text(pinR.x + (pinR.w - textWidth(pg)) div 2 + o, pinR.y + (pinR.h - FontH) div 2 + o, pg,
           if w.pinned: th.select else: th.text)
    else:
      # (grayed, as a 3.1 button that cannot be pressed)
      let gx = pinR.x + (pinR.w - textWidth(pg)) div 2
      let gy = pinR.y + (pinR.h - FontH) div 2
      text(gx + 1, gy + 1, pg, th.light)
      text(gx, gy, pg, th.gray)
    if ph.hover and canHover():
      ui.tip = if not can: "Always on Top: not while maximized"
               elif w.pinned: "Always on Top: on (click: off)"
               else: "Always on Top"
    if can and ph.clicked:
      w.pinned = not w.pinned
      ui.redraw = true
  if winButton(id + 3, mn2, 0):
    w.minimized = true
    w.maximized = false
  if winButton(id + 4, mx2, if w.maximized: 2 else: 1):
    w.maximized = not w.maximized
  # the control-menu box: a menu; a double click closes
  let sh = interact(id + 5, sys, focusable = false)
  let menuKey = "mdi-sys:" & $key
  if accessOn:
    accessNode(arButton, "Window menu", id = id + 5, r = sys,
               states = {asExpandable} + (if popupMenuOpen(menuKey): {asExpanded} else: {}))
  if accessPressed == id + 5: openPopupMenu(menuKey, sys.x, sys.y + sys.h + 1)
  if sh.down and ui.pressed:
    if ui.clicks >= 2:
      w.open = false
    else: openPopupMenu(menuKey, sys.x, sys.y + sys.h + 1)
  popupMenu(menuKey):
    if menuItem("&Restore", enabled = w.maximized): w.maximized = false
    if menuItem("Mi&nimize"): w.minimized = true
    if menuItem("Ma&ximize", enabled = not w.maximized): w.maximized = true
    menuSeparator()
    if not w.noPin:
      if menuItem("Always on &Top", checked = w.pinned and not w.maximized, enabled = not w.maximized):
        w.pinned = not w.pinned
        ui.redraw = true
    menuSeparator()
    if menuItem("&Close", "Ctrl+F4"): w.open = false
    if menuItem("Nex&t", "Ctrl+F6"):
      let fp = m.firstPalette
      if fp > 1:
        let top = m.z[fp - 1]
        m.z.delete(fp - 1)
        m.z.insert(top, 0)
        ui.redraw = true
  # the client area, scrolling when its content is taller
  let client = rect(title.x, title.y + barH + 1, title.w, sr.y + sr.h - border - (title.y + barH + 1))
  fill(client, th.window)
  m.rects[key] = sr
  mdis[mdiKey] = m
  if w.flush:
    m.rects[key] = sr
    mdis[mdiKey] = m
    pushClip(client)
    beginClipped()
    pushFrame(client)
    mdiStack.add MdiFrame(key: key, client: client, scrolls: false, start: start, id: id, pad: 0,
                          grip: w.grip and not w.maximized,
                          gripSize: (if w.gripSize > 0: w.gripSize else: SbW))
    return true
  var cs = state(id + 6)
  let scrolls = cs.aux > client.h
  let off = if scrolls: clamp(cs.scrollY, 0, cs.aux - client.h) else: 0
  pushClip(client)
  beginClipped()
  pushFrame(rect(client.x + Pad, client.y + Pad - off,
                 client.w - 2 * Pad - (if scrolls: SbW else: 0), client.h - 2 * Pad + off))
  mdiStack.add MdiFrame(key: key, client: client, scrolls: scrolls, start: start, id: id, pad: Pad,
                        grip: w.grip and not w.maximized,
                        gripSize: (if w.gripSize > 0: w.gripSize else: SbW))
  true

proc endMdiWindow*() =
  ## Ends a `beginMdiWindow`: its size grip and scroll bar.
  if mdiStack.len == 0: return
  let f = mdiStack.pop()
  defer:
    if accessOn: accessEnd()
  let used = popFrame() + 2 * f.pad
  endClipped()
  if f.grip:
    # (the size grip, over what it shows: three ridges)
    let c = f.client
    let gsz = if f.gripSize > 0: f.gripSize else: dp(14)
    let g = rect(c.x + c.w - gsz, c.y + c.h - gsz, gsz, gsz)
    fill(g, th.face)
    for k in 1 .. 3:
      let o = k * dp(4)
      line(g.x + g.w - 1 - o, g.y + g.h - 1, g.x + g.w - 1, g.y + g.h - 1 - o, th.light)
      line(g.x + g.w - o, g.y + g.h - 1, g.x + g.w - 1, g.y + g.h - o, th.shadow)
  popClip()
  var cs = state(f.id + 6)
  var off = cs.scrollY
  if f.scrolls:
    let hi = max(0, used - f.client.h)
    let sid = f.id + 6                          # (its scroller: glides, flicks)
    scrollWheel(sid, off, hi, f.client, 3 * ItemH)
    scrollPan(sid, off, hi, f.client)
    scrollTick(sid, off, hi)
    scrollBarFor(f.id + 7, sid, rect(f.client.x + f.client.w - SbW, f.client.y, SbW,
                                     f.client.h), true, off,
                 hi, max(ItemH, f.client.h - 2 * ItemH), ItemH)
  off = clamp(off, 0, max(0, used - f.client.h))
  if used != cs.aux or off != cs.scrollY:
    cs.aux = used
    cs.scrollY = off
    ui.redraw = true
  state(f.id + 6) = cs
  ui.blockers.setLen(0)
  if mdis.hasKey(mdiKey):
    mdis[mdiKey].spans.add (f.start, cmdMark())
    mdis[mdiKey].spanKeys.add f.key

proc endMdi*() =
  ## Ends a `beginMdi`: windows not drawn this frame leave it, the rest are
  ## stacked back to front; Ctrl+F6 / Ctrl+Tab and Ctrl+F4 are handled here.
  popClip()
  if not mdis.hasKey(mdiKey): return
  var m = mdis[mdiKey]
  # windows not drawn this frame leave the stack
  var z: seq[uint]
  for k in m.z:
    if k in m.seen: z.add k
  m.z = z
  var gone: seq[uint]
  for k in m.rects.keys:
    if k notin m.seen: gone.add k
  for k in gone: m.rects.del k
  var pals: seq[uint]
  for k in m.palettes:
    if k in m.seen: pals.add k
  m.palettes = pals
  var maxed: seq[uint]
  for k in m.maxed:
    if k in m.seen: maxed.add k
  m.maxed = maxed
  var docked: seq[uint]
  for k in m.docked:
    if k in m.seen: docked.add k
  m.docked = docked
  if m.chosen notin m.z: m.chosen = 0
  m.nOpen = 0
  for k in m.spanKeys:
    if k notin m.palettes and k notin m.docked: inc m.nOpen
  m.nIcons = m.iconAt
  # draw them back to front
  var order: seq[int]
  var h: Hash = 0
  for k in m.z:
    let i = m.spanKeys.find(k)
    if i >= 0: order.add i
    h = h !& hash(k)
  reorderSpans(m.spans, order)
  noteState(uint64(!$h))
  m.cmd = mcNone
  # Ctrl+F6 / Ctrl+Tab: the next window; Ctrl+F4 closes the active one
  if canInput() and not ui.keyUsed and CtrlPressed in ui.mods and m.z.len > 0:
    if ui.key == KeyF6 or (ui.key == KeyTab and m.z.len > 1):
      let fp = m.firstPalette
      let lo = if m.z.len > 0 and m.z[0] in m.docked: 1 else: 0
      if fp - lo > 1:
        let top = m.z[fp - 1]
        m.z.delete(fp - 1)
        m.z.insert(top, lo)
      ui.keyUsed = true
      ui.redraw = true
    elif ui.key == KeyF4:
      m.cmd = mcClose
      m.cmdKey = m.mdiTop
      ui.keyUsed = true
      ui.redraw = true
  mdis[mdiKey] = m

template mdiArea*(height: int; body: untyped) =
  ## A workspace for `mdiWindow`s: `mdiArea(-1): mdiWindow(w1): ...`.
  if beginMdi(height):
    body
    endMdi()

template mdiArea*(height: int; key: string; body: untyped) =
  ## An area with its own windows when there are several (`key` names it
  ## for `mdiCascade`, `mdiTile` and `mdiWindowMenu`).
  if beginMdi(height, key):
    body
    endMdi()

template mdiWindow*(w: var MdiWindow; body: untyped) =
  ## A window of the `mdiArea` around it; `body` is its content (it
  ## scrolls when taller than the window).
  if beginMdiWindow(w):
    body
    endMdiWindow()

proc mdiCommand(key: string; c: MdiCommand; target: uint = 0) =
  var m = mdis.getOrDefault(key)
  m.cmd = c
  m.cmdKey = target
  mdis[key] = m
  ui.redraw = true

proc mdiIsActive*(w: var MdiWindow; key = ""): bool =
  ## `w` is the active window of its area (the document in front).
  mdis.hasKey(key) and mdis[key].mdiTop == keyOf(w)

proc mdiTitleDragged*(w: var MdiWindow): bool =
  ## `w` is being moved by its title bar (the mouse held down on it).
  let key = keyOf(w)
  let id = Id(mixId(uint32(key and 0xFFFFFFFF'u), uint32(key shr 32) xor 0x6d6469'u32))
  ui.active == id + 2 and ui.mouseDown

proc mdiAreaRect*(key = ""): Rect =
  ## Where the area was drawn last (its windows' `r` are relative to it).
  mdis.getOrDefault(key).area

proc paletteTabs*(labels: openArray[string]; sel: var int; menu = true): tuple[changed, menu: bool] =
  ## The tabs of a palette that holds several (Brushes and Options,
  ## Layers, Channels and Paths...): the one shown joined to the palette,
  ## the others behind it; with `menu`, the little arrow at the right that
  ## opens the palette's menu (`menu` reported). (The docked panels' look:
  ## `paletteTabFace`.)
  let h = paletteTabH()
  let r = place(0, h, fill = true)
  let st = style(size = 0.9)
  hline(r.x, r.y + r.h - 1, r.w, th.frame)
  # (more tabs than fit: the one shown keeps its label, the others share
  # what is left, their labels cut short)
  var natural = newSeq[int](labels.len)
  var total = 0
  for i, l in labels:
    natural[i] = textWidth(l, st) + dp(12)
    total += natural[i] - 1
  let room = r.w - (if menu: h + dp(2) else: 0)
  var widths = natural
  if total > room and labels.len > 1:
    let mine = min(natural[clamp(sel, 0, labels.high)], room div 2)
    let each = max(dp(22), (room - mine) div (labels.len - 1) + 1)
    for i in 0 ..< labels.len:
      widths[i] = if i == sel: mine else: min(natural[i], each)
  var x = r.x
  if accessOn: accessBegin(arTabList, "", r)
  for i, l0 in labels:
    let tw = widths[i]
    let l = if tw < natural[i]: ellipsize(l0, max(dp(8), tw - dp(10)), st) else: l0
    let tr = rect(x, r.y + (if i == sel: 0 else: dp(2)), tw, h - (if i == sel: 0 else: dp(2)))
    let hit = interact(idOf("paltab:" & l0 & $i), tr, focusable = false)
    if tw < natural[i] and hit.hover: ui.tip = l0
    let ink = paletteTabFace(tr, i == sel, hit.showsHover)
    text(tr.x + dp(6), tr.y + (tr.h - lineHeight(st)) div 2, l, ink, st)
    if (hit.down and ui.pressed or accessPressed == idOf("paltab:" & l0 & $i)) and sel != i:
      sel = i
      result.changed = true
    if accessOn:
      let k = accessNode(arTab, l0, id = idOf("paltab:" & l0 & $i), r = tr,
                         states = (if i == sel: {asSelected} else: {}))
      accessItem(k, i + 1, labels.len)
    x += tw - 1
  if accessOn: accessEnd()
  if menu:
    let mr = rect(r.x + r.w - h, r.y + dp(1), h - dp(1), h - dp(3))
    let mh = interact(idOf("palmenu:" & (if labels.len > 0: labels[0] else: "")), mr, focusable = false)
    arrow(mr.x + mr.w div 2, mr.y + mr.h div 2, dRight, th.text, dp(4))
    if accessOn:
      accessNode(arButton, "Menu", id = idOf("palmenu:" & (if labels.len > 0: labels[0] else: "")), r = mr)
    if mh.down and ui.pressed or accessPressed == idOf("palmenu:" & (if labels.len > 0: labels[0] else: "")):
      result.menu = true
  ui.lastRect = r

proc mdiCascade*(key = "") = mdiCommand(key, mcCascade)
  ## Overlaps the windows of the area, each a title bar lower.
proc mdiTile*(key = "") = mdiCommand(key, mcTile)
  ## Lays the windows of the area side by side.
proc mdiActivate*(w: var MdiWindow; key = "") = mdiCommand(key, mcActivate, keyOf(w))
  ## Brings `w` to the front (restored when it was minimized).

proc mdiWindowMenu*(key = "") =
  ## The items of a 3.1 Window menu (inside `menu "&Window":`): Cascade,
  ## Tile, then the windows, the active one checked.
  let m = mdis.getOrDefault(key)
  if menuItem("&Cascade", "Shift+F5"): mdiCascade(key)
  if menuItem("&Tile", "Shift+F4"): mdiTile(key)
  let top = m.mdiTop
  if top != 0 and top notin m.docked and top notin m.unpinned:
    # (not for a maximized window: it fills the area)
    if menuItem("Always on T&op", checked = top in m.pinned, enabled = top notin m.maxed):
      mdiCommand(key, mcPin, top)
  if m.titles.len > 0: menuSeparator()
  for i, (k, t) in m.titles:
    if i >= 9: break
    if menuItem("&" & $(i + 1) & " " & t.replace("&", "&&"), checked = k == m.mdiTop):
      mdiCommand(key, mcActivate, k)

# ---- find and replace ------------------------------------------------------------------------------

type
  FindState* = object
    ## What a `findBar` holds.
    what*, with*: string      ## the text to find, and to replace it with
    matchCase*, wholeWord*: bool  ## the bar's Match case and Whole word boxes
    replacing*: bool          ## the Replace line is shown
    open*: bool               ## the bar is shown (Esc and its close box set it false)
  FindEvent* = object
    ## What a `findBar` asks for this frame.
    next*, prev*: bool        ## find the next / previous match
    replace*: bool            ## replace the match shown, then find the next
    replaceAll*: bool         ## replace every match (`replaceAllIn`)
    closed*: bool             ## the bar was closed this frame

proc isWordChar(c: char): bool {.inline.} = c in IdentChars or ord(c) >= 128

proc matchAt(text, what: string; i: int; matchCase, wholeWord: bool): bool =
  if i < 0 or i + what.len > text.len: return false
  if matchCase:
    for k in 0 ..< what.len:
      if text[i + k] != what[k]: return false
  else:
    for k in 0 ..< what.len:
      if text[i + k].toLowerAscii != what[k].toLowerAscii: return false
  if wholeWord:
    if i > 0 and isWordChar(text[i - 1]): return false
    if i + what.len < text.len and isWordChar(text[i + what.len]): return false
  true

proc findIn*(text, what: string; start: int; matchCase = false; wholeWord = false;
             backwards = false; wrap = true): int =
  ## Where `what` is in `text` from `start` on (backwards: before it); it
  ## goes round the end when `wrap`. -1 when it is not there.
  if what.len == 0 or text.len < what.len: return -1
  let last = text.len - what.len
  if not backwards:
    for i in max(0, start) .. last:
      if matchAt(text, what, i, matchCase, wholeWord): return i
    if wrap:
      for i in 0 ..< min(max(0, start), last + 1):
        if matchAt(text, what, i, matchCase, wholeWord): return i
  else:
    for i in countdown(min(start - 1, last), 0):
      if matchAt(text, what, i, matchCase, wholeWord): return i
    if wrap:
      for i in countdown(last, max(0, start)):
        if matchAt(text, what, i, matchCase, wholeWord): return i
  -1

proc replaceAllIn*(text: var string; what, with: string; matchCase = false;
                   wholeWord = false): int {.discardable.} =
  ## Replaces every match; returns how many.
  if what.len == 0: return 0
  var outS = newStringOfCap(text.len)
  var i = 0
  while i < text.len:
    if matchAt(text, what, i, matchCase, wholeWord):
      outS.add with
      i += what.len
      inc result
    else:
      outS.add text[i]
      inc i
  if result > 0: text = outS

proc findBar*(f: var FindState; key = ""): FindEvent =
  ## A bar to find (and replace) text in: Enter or F3 finds the next match,
  ## Shift+Enter or Shift+F3 the previous one, Esc closes it. With
  ## `replacing`, a second line replaces the match or all of them. The app
  ## does the finding (`findIn`, `replaceAllIn`) on its text.
  if not f.open: return
  if canInput() and not ui.keyUsed:
    if ui.key == KeyF3:
      if ShiftPressed in ui.mods: result.prev = true else: result.next = true
      ui.keyUsed = true
  let id = idOf("findbar:" & key)
  var st = state(id)
  row:
    label "Fi&nd:"
    let wasFocused = st.caret == 1
    if not wasFocused:
      focusNext()
      st.caret = 1
    edit(f.what, w = dp(180))
    let editId = ui.lastId
    if ui.focus == editId and canInput():
      if keyHit(KeyEnter):
        if ShiftPressed in ui.mods: result.prev = true else: result.next = true
    if button("&Next", enabled = f.what.len > 0, w = dp(64)): result.next = true
    if button("&Previous", enabled = f.what.len > 0, w = dp(80)): result.prev = true
    checkbox("Match &case", f.matchCase)
    checkbox("&Whole word", f.wholeWord)
    spring()
    if toolButton("x", "Close (Esc)", bold = true):
      result.closed = true
  if f.replacing:
    row:
      label "Re&place:"
      edit(f.with, w = dp(180))
      if button("&Replace", enabled = f.what.len > 0, w = dp(72)): result.replace = true
      if button("Replace &all", enabled = f.what.len > 0, w = dp(96)):
        result.replaceAll = true
  if canInput() and keyHit(KeyEsc): result.closed = true
  if result.closed:
    f.open = false
    st.caret = 0
  state(id) = st

# ---- shortcuts ---------------------------------------------------------------------------------------

proc keyName(k: KeyCode): string =
  result = $k
  if result.startsWith("Key"): result = result[3 .. ^1]
  case result
  of "Esc": result = "Esc"
  of "Backspace": result = "Backspace"
  of "LeftBracket": result = "["
  of "RightBracket": result = "]"
  of "Semicolon": result = ";"
  of "Quote": result = "'"
  of "Backslash": result = "\\"
  of "Backquote": result = "`"
  of "Slash": result = "/"
  of "Comma": result = ","
  of "Period": result = "."
  else: discard

proc hotkeyText*(key: KeyCode; mods: set[Modifier]): string =
  ## "Ctrl+Shift+S" for Ctrl + Shift + S; on a Mac "Cmd+Shift+S" -- Cmd is
  ## reported as Ctrl there, the Control key as the Gui key ("Control+"),
  ## Option as Alt ("Option+") -- elsewhere the Gui key is "Win+".
  for m in [CtrlPressed, AltPressed, ShiftPressed, GuiPressed]:
    if m in mods: result.add modifierName(m) & "+"
  result.add keyName(key)

proc parseHotkey*(s: string): tuple[key: KeyCode; mods: set[Modifier]] =
  ## "Ctrl+Shift+S" -> (KeyS, {CtrlPressed, ShiftPressed}); KeyNone when it
  ## is not a shortcut. "Cmd" is Ctrl on every system (the key shortcuts
  ## are made with: Cmd on a Mac, Ctrl elsewhere), so a shortcut kept on one
  ## is the same on the others; "Control" is a Mac's Control key there (the
  ## Gui key), Ctrl elsewhere.
  result.key = KeyNone
  let parts = s.split('+')
  if parts.len == 0: return
  for p in parts[0 ..< ^1]:
    case p.strip.toLowerAscii
    of "ctrl", "cmd", "command": result.mods.incl CtrlPressed
    of "control": result.mods.incl (when defined(macosx): GuiPressed else: CtrlPressed)
    of "alt", "option": result.mods.incl AltPressed
    of "shift": result.mods.incl ShiftPressed
    of "win", "super", "meta": result.mods.incl GuiPressed
    else: result = (KeyNone, {}); return
  let name = parts[^1].strip
  if name.len == 0: result = (KeyNone, {}); return
  for k in KeyCode:
    if k != KeyNone and cmpIgnoreCase(keyName(k), name) == 0:
      result.key = k
      return
  result.mods = {}

proc hotkeyPressed*(s: string): bool =
  ## The shortcut `s` ("Ctrl+S") was pressed this frame (and not used yet);
  ## uses it. On a Mac "Ctrl+S" is Cmd+S, as `s` written either way.
  let (k, mods) = parseHotkey(s)
  if k == KeyNone or not canInput() or ui.keyUsed or ui.key != k: return false
  let want = mods * {CtrlPressed, AltPressed, ShiftPressed, GuiPressed}
  let have = ui.mods * {CtrlPressed, AltPressed, ShiftPressed, GuiPressed}
  if want != have: return false
  ui.keyUsed = true
  true

proc hotkeyEdit*(keys: var string; w = 0; enabled = true): bool {.discardable.} =
  ## A box that takes the next key pressed, with its Ctrl, Alt and Shift,
  ## as a shortcut ("Ctrl+Shift+S"); Backspace or Delete alone clears it,
  ## Tab and Esc leave it. True when it changed.
  let r = place(if w > 0: w else: dp(150), EditH)
  let id = idOf(keys, "hotkey")
  let hit = interact(id, r, enabled = enabled)
  if hit.focused and canInput() and enabled:
    let k = ui.key
    let mods = ui.mods * {CtrlPressed, AltPressed, ShiftPressed, GuiPressed}
    if k in {KeyBackspace, KeyDelete} and mods == {}:
      if keys.len > 0:
        keys = ""
        result = true
      ui.keyUsed = true
    elif k notin {KeyNone, KeyTab, KeyEsc, KeyCapslock}:
      let t = hotkeyText(k, mods)
      if t != keys:
        keys = t
        result = true
      ui.keyUsed = true
    ui.typed.setLen(0)                       # (the letter does not go anywhere else)
  fill(r, if enabled: th.field else: th.face)
  box(r, if enabled: th.edge else: th.gray)
  let shown = if keys.len > 0: keys elif hit.focused: "Press a key..." else: "None"
  text(r.x + dp(4), r.y + (r.h - FontH) div 2, shown,
       if keys.len == 0 or not enabled: th.gray else: th.fieldText)
  if hit.focused: focusDots(inset(r, 2))
  if accessOn:
    accessNode(arTextField, value = (if keys.len > 0: keys else: "None"), id = id, r = r,
               states = accessOff(enabled) + {asReadOnly}, help = "Press a key")
  ui.lastId = id
  ui.lastRect = r

# ---- keymaps: the shortcuts of an app's commands, the user's own among them ---------------------------

type Keymap* = object
  ## An app's shortcuts: a set of defaults (command -> "Ctrl+S"), the
  ## user's changes over them. `keymapPressed` finds the command whose
  ## shortcut was pressed; `keymapEditor` lets the user change them;
  ## `storeKeymap` / `restoreKeymap` keep them.
  defaults*: seq[tuple[keys, command: string]]  ## the app's own shortcuts ("Ctrl+S", "Save")
  custom*: seq[tuple[command, keys: string]]   ## ("" keys: the default taken away)

proc keyFor*(km: Keymap; command: string): string =
  ## The shortcut of `command` ("" none).
  for (c, k) in km.custom:
    if c == command: return k
  for (k, c) in km.defaults:
    if c == command: return k
  ""

proc setKey*(km: var Keymap; command, keys: string) =
  ## `command`'s shortcut made `keys` (taken off the command that had it).
  for i in countdown(km.custom.high, 0):
    if km.custom[i].command == command: km.custom.delete(i)
  if keys.len > 0:
    for (k, c) in km.defaults:
      if k == keys and c != command and km.keyFor(c) == keys: km.custom.add (c, "")
    for i in 0 ..< km.custom.len:
      if km.custom[i].keys == keys: km.custom[i].keys = ""
  var dflt = ""
  for (k, c) in km.defaults:
    if c == command: dflt = k
  if keys != dflt: km.custom.add (command, keys)

proc keymapPressed*(km: Keymap): string =
  ## The command whose shortcut was pressed this frame ("" none); the key
  ## is used.
  if ui.keyUsed or ui.key == KeyNone or not canInput(): return ""
  var seen: seq[string]
  for (c, k) in km.custom:
    seen.add c
    if k.len > 0 and hotkeyPressed(k): return c
  for (k, c) in km.defaults:
    if c in seen: continue
    if hotkeyPressed(k): return c
  ""

proc commandsOf*(km: Keymap): seq[string] =
  ## Every command with a shortcut (or that had one), in order.
  for (_, c) in km.defaults:
    if c notin result: result.add c
  for (c, _) in km.custom:
    if c notin result: result.add c

proc storeKeymap*(s: var Settings; km: Keymap; prefix = "keys.") =
  ## The user's shortcuts into `s` (the defaults are not kept).
  var gone: seq[string]
  for k, _ in s:
    if k.startsWith(prefix): gone.add k
  for k in gone: s.del k
  for (c, k) in km.custom: s[prefix & c] = (if k.len > 0: k else: "-")

proc restoreKeymap*(s: Settings; km: var Keymap; prefix = "keys.") =
  ## The user's shortcuts back from `s` (as `storeKeymap` put them).
  km.custom.setLen(0)
  for k, v in s:
    if k.startsWith(prefix): km.custom.add (k[prefix.len .. ^1], if v == "-": "" else: v)

var keymapSel: int
var keymapEditing: string

proc keymapEditor*(km: var Keymap; commands: openArray[string]; height = 260): bool {.discardable.} =
  ## Rows to change the shortcuts: the commands (with theirs), the one
  ## chosen's box -- press the keys -- and Use Default. True when one
  ## changed.
  var items: seq[string]
  for c in commands:
    let k = km.keyFor(c)
    items.add(if k.len > 0: c & "   (" & k & ")" else: c)
  keymapSel = clamp(keymapSel, 0, max(0, commands.high))
  discard listbox(items, keymapSel, rows = max(4, height div max(1, ItemH)))
  if commands.len == 0: return
  let c = commands[keymapSel]
  if keymapEditing != c: keymapEditing = c
  row:
    label "Shortcut:"
    var k = km.keyFor(c)
    if hotkeyEdit(k, w = dp(160)):
      km.setKey(c, k)
      result = true
    if button("Use Default", w = dp(100)):
      for i in countdown(km.custom.high, 0):
        if km.custom[i].command == c: km.custom.delete(i)
      result = true
  # (the command that has the same keys)
  let mine = km.keyFor(c)
  if mine.len > 0:
    for other in km.commandsOf:
      if other != c and km.keyFor(other) == mine:
        label("Also " & other & "'s: it loses it.", color = th.gray)

# ---- the About box -----------------------------------------------------------------------------------

var aboutTab: int              ## (the page of the About box shown)
var aboutPng: string           ## (the icon given as a PNG, decoded once)
var aboutBmp: Bitmap
var aboutCopied = -1_000_000   ## (when Copy Info was pressed)

proc systemName*(): string =
  ## The name of the system the program runs on: "Linux", "Windows", ...
  case platformName()
  of "linux": "Linux"
  of "freebsd": "FreeBSD"
  of "openbsd": "OpenBSD"
  of "netbsd": "NetBSD"
  of "dragonfly": "DragonFly BSD"
  of "windows": "Windows"
  of "macos", "macosx": "macOS"
  of "android": "Android"
  of "ios": "iOS"
  else: platformName()

proc aboutFacts(app, version: string): seq[(string, string)] =
  @[("Version", (if version.len > 0: version else: "-")),
    ("System", systemName()),
    ("Screen", $ui.w & " x " & $ui.h & " at " & $(ui.k * 100).int & "%"),
    ("Toolkit", "Retro Nim UI " & RetroVersion),
    ("Developer", RetroDeveloper & " " & RetroHandle),
    ("Memory", memoryReport(prefix = false)),
    ("Compiler", "Nim " & NimVersion),
    ("Built", CompileDate)]

proc aboutInfo*(app: string; version = ""): string =
  ## What the About box tells of the program and of what it runs on, as
  ## text (its Copy Info puts it on the clipboard, for a report of a fault).
  result = app
  for (k, v) in aboutFacts(app, version): result.add "\n" & k & ": " & v

proc spectrum(t: float): Color =
  ## A color of the rainbow, red (0) to violet (1).
  let h = clamp(t, 0.0, 1.0) * 5.0
  let i = int(h)
  let f = h - i.float
  let up = uint8(f * 255)
  let dn = uint8((1 - f) * 255)
  case i
  of 0: color(255, up, 0)
  of 1: color(dn, 255, 0)
  of 2: color(0, 255, up)
  of 3: color(0, dn, 255)
  else: color(up, 0, 255)

proc aboutBanner(r: Rect; app, version, tagline, glyph: string; icon: Bitmap) =
  ## The top of the About box: the blue of a 1994 Setup screen, darker
  ## down, the program's icon, its name large, the version, a line of what
  ## it is, and a rainbow along the foot.
  sunken(r)
  let a = inset(r, 2)
  let top = titleColors(true).bg
  let deep = mixColor(top, color(0, 0, 0), 0.82)
  let sh = max(2, dp(3))
  let band = a.h - sh
  for j in 0 ..< band:
    hline(a.x, a.y + j, a.w, mixColor(top, deep, j / max(1, band - 1)))
  let step = max(1, dp(2))
  var x = 0
  while x < a.w:
    fill(rect(a.x + x, a.y + band, min(step, a.w - x), sh), spectrum(x / max(1, a.w - 1)))
    x += step
  pushClip(a)
  let isz = dp(48)
  let ix = a.x + dp(12)
  let iy = a.y + (band - isz) div 2
  if icon != nil: drawBitmap(rect(ix, iy, isz, isz), icon)
  else:
    let g = if glyph.len > 0: glyph else: retroOr(pxApp, nfWindowMaximize)
    image(ix + dp(4), iy + dp(4), glyphIcon(g, color(255, 255, 255), dp(40)))
  let big = style(bold = true, size = 1.9)
  let tx = ix + isz + dp(14)
  let nameH = lineHeight(big)
  let lines = nameH + FontH + (if tagline.len > 0: FontH + dp(2) else: 0)
  var ty = a.y + (band - lines) div 2
  text(tx + 2, ty + 2, app, color(0, 0, 32), big)
  text(tx, ty, app, color(255, 255, 255), big)
  ty += nameH
  if version.len > 0:
    text(tx + 1, ty, tr("Version ") & version, color(255, 232, 140), bold = true)
  ty += FontH + dp(2)
  if tagline.len > 0: text(tx + 1, ty, tagline, color(196, 208, 255))
  popClip()

proc aboutBullets(items: openArray[string]) =
  for it in items:
    row([14, -1]):
      col:
        let r = place(dp(14), FontH)
        let s = max(3, dp(4))
        fill(rect(r.x + dp(3), r.y + (FontH - s) div 2 + 1, s, s), th.select)
      col:
        label it

proc splashBox*(app: string; version = ""; tagline = ""; lines: openArray[string] = [];
                art: Bitmap = nil; icon: Bitmap = nil; iconPng = ""; glyph = ""; progress = -1.0;
                note = "Starting..."; width = 460) =
  ## The box a program shows while it starts, as the About box looks: a
  ## picture (`art`, else the blue of a 1994 Setup screen) with the icon,
  ## the name large and the version over it, a rainbow under it; then
  ## `tagline`, `lines`, a 3.1 progress bar of blocks (`progress` 0 .. 1;
  ## none when less than 0) and `note`. Drawn over everything, in the
  ## middle of the window.
  var pic = icon
  if pic == nil and iconPng.len > 0:
    if aboutPng != iconPng:
      aboutPng = iconPng
      aboutBmp = try: decodePng(iconPng) except CatchableError: nil
    pic = aboutBmp
  let w = min(dp(width), ui.w - dp(16))
  let artH = dp(170)
  let lh = FontH + dp(2)
  # (the note and the toolkit's name, then the credit line under them)
  let foot = dp(10) + (if tagline.len > 0: lh else: 0) + lines.len * lh +
             (if progress >= 0: dp(4) + dp(16) + dp(6) else: 0) + 2 * lh + dp(8)
  let h = artH + dp(3) + foot + 6
  pushLayer(LayerPopup)
  let r = rect((ui.w - w) div 2, (ui.h - h) div 2, w, h)
  fill(r, th.face)
  box(r, th.frame)
  raised(inset(r, 1))
  let a = rect(r.x + 3, r.y + 3, r.w - 6, artH)
  if art != nil: drawBitmap(a, art)
  else:
    let top = titleColors(true).bg
    let deep = mixColor(top, color(0, 0, 0), 0.82)
    for j in 0 ..< a.h: hline(a.x, a.y + j, a.w, mixColor(top, deep, j / max(1, a.h - 1)))
  # (the rainbow under the picture)
  let sh = max(2, dp(3))
  let step = max(1, dp(2))
  var x = 0
  while x < a.w:
    fill(rect(a.x + x, a.y + a.h, min(step, a.w - x), sh), spectrum(x / max(1, a.w - 1)))
    x += step
  # the icon, the name, the version over the picture
  pushClip(a)
  let isz = dp(48)
  let ix = a.x + dp(16)
  let iy = a.y + a.h - isz - dp(18)
  if pic != nil: drawBitmap(rect(ix, iy, isz, isz), pic)
  elif glyph.len > 0: image(ix + dp(4), iy + dp(4), glyphIcon(glyph, color(255, 255, 255), dp(40)))
  let big = style(bold = true, size = 2.1)
  let tx = ix + isz + dp(12)
  let ty = iy + (isz - lineHeight(big) - FontH) div 2
  text(tx + 2, ty + 2, app, color(0, 0, 32), big)
  text(tx, ty, app, color(255, 255, 255), big)
  if version.len > 0:
    text(tx + 1, ty + lineHeight(big), tr("Version ") & version, color(255, 232, 140), bold = true)
  popClip()
  var y = a.y + a.h + sh + dp(8)
  if tagline.len > 0:
    text(r.x + dp(14), y, tagline, th.text, bold = true)
    y += lh
  for l in lines:
    text(r.x + dp(14), y, l, th.text)
    y += lh
  if progress >= 0:
    # (a 3.1 progress bar: navy blocks in a sunken well)
    y += dp(4)
    let pr = rect(r.x + dp(14), y, r.w - dp(28), dp(16))
    sunken(pr)
    let inner = inset(pr, 3)
    let bw = dp(8)
    let n = max(1, (inner.w + dp(2)) div (bw + dp(2)))
    let k = clamp(int(progress * n.float + 0.5), 0, n)
    for i in 0 ..< k:
      fill(rect(inner.x + i * (bw + dp(2)), inner.y, bw, inner.h), th.select)
    y += pr.h + dp(6)
  text(r.x + dp(14), y, note, th.gray)
  let made = "Retro Nim UI " & RetroVersion
  text(r.x + r.w - dp(14) - textWidth(made), y, made, th.gray)
  let by = RetroCredit & "  ·  " & RetroWebsite
  text(r.x + r.w - dp(14) - textWidth(by), y + FontH + dp(2), by, th.gray)
  popLayer()

proc aboutBox*(open: var bool; app: string; version = ""; lines: openArray[string] = [];
               glyph = ""; width = 460; tagline = ""; whatsNew: openArray[string] = [];
               credits: openArray[string] = []; icon: Bitmap = nil; iconPng = "";
               url = "") =
  ## The About dialog: a banner in the blue of a 1994 Setup screen with the
  ## program's icon (`icon`, or a PNG's bytes in `iconPng`, else `glyph`),
  ## its name, version and `tagline`; then pages (tabs as the docked
  ## panels'): About -- `lines` (what it is, copyright, licence; each wraps)
  ## and what it runs on; What's New -- `whatsNew`, a line each; Credits --
  ## `credits`. Copy Info puts the facts on the clipboard; OK closes it.
  if not open:
    aboutTab = 0
    return
  var pic = icon
  if pic == nil and iconPng.len > 0:
    if aboutPng != iconPng:
      aboutPng = iconPng
      aboutBmp = try: decodePng(iconPng) except CatchableError: nil
    pic = aboutBmp
  dialog(open, "About " & app, width):
    let br = place(cellRoom(), dp(92) + (if fingers(): dp(8) else: 0))
    aboutBanner(br, app, version, tagline, glyph, pic)
    if accessOn:
      accessNode(arHeading, app & (if version.len > 0: " " & version else: ""), id = 0, r = br,
                 help = tagline)
    var pages = @["About"]
    if whatsNew.len > 0: pages.add "What's New"
    if credits.len > 0: pages.add "Credits"
    let saved = tabLook
    tabLook = tlPalette
    # (the page scrolls inside its tab when it is taller than the room: the
    # banner, the tabs and the buttons stay)
    let pageH = clamp(ui.h - br.h - 2 * CtrlH - FontH * 2 - dp(64), dp(120), dp(340))
    tabs(aboutTab, pages, true):
      let page = pages[clamp(aboutTab, 0, pages.high)]
      beginScroll(pageH, "about:" & page, framed = false)
      case page
      of "What's New":
        label("New in " & app & (if version.len > 0: " " & version else: "") & ":", bold = true)
        aboutBullets(whatsNew)
      of "Credits":
        for c in credits: label c
      else:
        for line in lines: label line
        # (who made it: every app of the kit says so, with where to write)
        label(RetroCredit, bold = true)
        row:
          for (shown, target) in [(RetroWebsite, "https://" & RetroWebsite), (RetroEmail, "mailto:" & RetroEmail)]:
            let tw = textWidth(shown)
            let r = place(tw + 2, FontH + 2)
            let id = idOf("about-dev:" & shown)
            let hit = interact(id, r)
            if hit.hover and canHover(): ui.cursor = curHand
            text(r.x + 1, r.y + 1, shown, th.link)
            hline(r.x + 1, r.y + FontAscent + 2, tw, th.link)
            if accessOn: accessNode(arLink, shown, id = id, r = r)
            if hit.clicked: discard openUrl(target)
            space(dp(12))
        separator()
        var facts = aboutFacts(app, version)
        facts.delete(0)                       # (the version: in the banner)
        let lh = FontH + dp(3)
        let fr = place(cellRoom(), facts.len * lh)
        for i, (k, v) in facts:
          text(fr.x, fr.y + i * lh, tr(k), th.gray)
          text(fr.x + dp(76), fr.y + i * lh, v, th.text)
          if accessOn: accessNode(arLabel, tr(k) & " " & v, id = 0, r = rect(fr.x, fr.y + i * lh, fr.w, lh))
        if url.len > 0:
          let tw = textWidth(url)
          let r = place(tw + 2, FontH + 2)
          let id = idOf("about-url")
          let hit = interact(id, r)
          if hit.hover and canHover(): ui.cursor = curHand
          text(r.x + 1, r.y + 1, url, th.link)
          hline(r.x + 1, r.y + FontAscent + 2, tw, th.link)
          if accessOn: accessNode(arLink, url, id = id, r = r)
          if hit.clicked: discard openUrl(url)
      endScroll()
    tabLook = saved
    row:
      let copied = ui.now - aboutCopied < 1500
      if button((if copied: "Copied" else: "&Copy Info"), w = dp(96)):
        putClipboardText(aboutInfo(app, version))
        aboutCopied = ui.now
        wakeIn(1600)
      spring()
      if button("OK", isDefault = true, w = dp(80)): open = false

# ---- Report a Problem -----------------------------------------------------------------------------

var problem: tuple[on, checked: bool; text: string]

proc reportProblem*(text = "") =
  ## Opens the "Report a Problem" box (Help > Report a Problem; draw it with
  ## `problemBox`): `text`, else what the fault log holds (`takeFaults`),
  ## for the user to add what they were doing, then copy or send.
  var t = if text.len > 0: text else: takeFaults()
  if t.len == 0: t = "(Nothing went wrong since the program started.)"
  problem = (true, true, t & "\n\nWhat I was doing:\n")

proc problemBox*(app: string; version = "") =
  ## Call it every frame: the "Report a Problem" box when it is open -- and,
  ## the first time, opened by itself when the last run left faults (the
  ## program stopped, or `guarded` caught one). Copy puts the report on the
  ## clipboard; Send by Email writes it to the developer.
  if not problem.checked:
    problem.checked = true
    let f = takeFaults()
    if f.len > 0: problem = (true, true, f & "\n\nWhat I was doing:\n")
  if not problem.on: return
  dialog(problem.on, "Report a Problem", 540):
    row:
      msgIcon(miWarning)
      paragraph("Something went wrong in " & app & " (the last time it ran, or now) -- it " &
                "went on, your work is kept. What it said is below: add what you were " &
                "doing, then send it, so it can be put right.")
    editArea(problem.text, lines = 10)
    row:
      let report = problem.text & "\n\n" & aboutInfo(app, version)
      if button("&Copy", w = dp(80)): putClipboardText(report)
      if button("&Send by Email...", w = dp(140)):
        var body = report
        if body.len > 1800: body = body[0 ..< 1800] & "\n..."
        discard openUrl("mailto:" & RetroEmail & "?subject=" &
                        encodeUrl(app & " " & version & ": a problem", usePlus = false) &
                        "&body=" & encodeUrl(body, usePlus = false))
      spring()
      if button("OK", isDefault = true, w = dp(80)): problem.on = false

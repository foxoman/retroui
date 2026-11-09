## Retro Board: an endless whiteboard in the manner of tldraw, drawn with
## Retro Nim UI -- freehand ink (pen pressure too), the highlighter, the
## eraser, the laser pointer, nineteen shapes with labels, arrows that hold
## on to shapes, lines, text (Arabic too), sticky notes, frames, pictures;
## styles (twelve colors, fills, dashes, sizes, fonts); select, move, size,
## turn, snap, group, lock, align, distribute, flip, order; copy and paste,
## undo and redo; pages; pinch to zoom, two fingers to pan; autosave;
## .board files; PNG, SVG and PDF export; a dark mode.
##
##   nimble board          (or: nim c -r -d:release examples/retroboard.nim)
##   nimble boardapk       (the Android APK: build/RetroBoard.apk)
##
## The document and its drawing are the toolkit's `retroui/board` (and its
## ink `retroui/freehand`); this file is the program round them.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, math, strutils, tables, sets, unicode, json, sequtils, hashes]
import retroui
import retroui/[board, freehand]

const
  AppName = "Retro Board"
  BoardVersion = "1.3.4"
  iconPng = staticRead("assets/board-icon.png")

type
  Tool = enum
    tSelect = "Select", tHand = "Hand", tDraw = "Draw", tHighlight = "Highlighter",
    tEraser = "Eraser", tLaser = "Laser", tGeo = "Shape", tArrow = "Arrow", tLine = "Line",
    tText = "Text", tNote = "Note", tFrame = "Frame"
  DragKind = enum
    dkNone, dkPending, dkPan, dkBrush, dkMove, dkResize, dkRotate, dkCreate, dkInk, dkErase,
    dkLaser, dkArrowEnd, dkBend, dkLinePoint, dkEditText
  Handle = enum
    hNone, hNW, hN, hNE, hE, hSE, hS, hSW, hW, hRotate
  Icon = enum
    icSelect, icHand, icDraw, icHighlight, icEraser, icLaser, icGeo, icArrow, icLine, icText,
    icNote, icFrame, icImage, icMore, icStyle, icUndo, icRedo, icDelete, icDuplicate, icPages,
    icFill, icDash, icMenu
  P = tuple[x, y: float]
  Style = object
    color: BoardColor
    fill: BoardFill
    dash: BoardDash
    size: BoardSize
    font: BoardFont
    align, textAlign: BoardAlign
    opacity: float
    head0, head1: Arrowhead
    spline: bool
    fillColor: int           ## 0: the line's color
    roughness: int
    round: bool
    elbow: bool
    valign: BoardAlign
  SelFrame = object
    ok: bool
    box: Box               ## the box (page units) before it is turned
    rot: float
    single: int            ## the shape, when one is selected

const
  toolIcon: array[Tool, Icon] = [icSelect, icHand, icDraw, icHighlight, icEraser, icLaser, icGeo,
                                 icArrow, icLine, icText, icNote, icFrame]
  toolKey: array[Tool, string] = ["V", "H", "D", "Shift+D", "E", "K", "R", "A", "L", "T", "N", "F"]
  selBlue = Color(r: 46, g: 128, b: 237, a: 255)
  guideRed = Color(r: 232, g: 54, b: 120, a: 255)
  opacities = [0.1, 0.25, 0.5, 0.75, 1.0]

var
  bd = newBoard()
  tool = tSelect
  geoKind = gkRectangle
  sel: seq[int]
  cur = Style(color: bcBlack, fill: bfNone, dash: bdDraw, size: bsM, font: bfnHand, align: baMiddle,
              textAlign: baStart, opacity: 1, head0: ahNone, head1: ahArrow, valign: baMiddle)
  view: Rect                       ## the canvas on the screen
  blockers: seq[Rect]              ## the floating bars over it
  showGrid = true
  snapOn = true
  darkMode = false
  toolLock = false
  showStatus = true
  appearDlg = false
  zenMode = false                  ## only the tool bar over the canvas
  viewMode = false                 ## looked at, not changed: no bars at all
  findDlg, posDlg, statsDlg = false
  findWhat = ""
  findHits: seq[tuple[page, id: int]]
  findAt = 0
  posX, posY, posW, posH, posA = 0
  exportDark = false
  memText = ""                     ## the memory used, for the status bar
  memAt = -100000
  # a drag on the canvas
  drag = dkNone
  dragFrom: P                      ## where it began (screen)
  dragFromPg: P                    ## ... on the page
  lastScr: P
  startShapes: seq[Shape]
  startSel: seq[int]
  startFrame: SelFrame
  dragHandle = hNone
  creating = 0                     ## the shape being made
  pressHit = 0                     ## the shape pressed (select tool)
  pressAt = 0                      ## when (a long press: the menu)
  brush: Box
  brushOn = false                  ## the box is being dragged out (moved far enough)
  guides: seq[Guide]
  erasing: HashSet[int]
  eraseTrail: seq[(P, int)]
  laser: seq[(P, int)]
  endIdx = 0                       ## the arrow's end, the line's point dragged
  bindTarget = 0                   ## the shape an arrow's end is over
  hoverId = 0
  spaceHeld = false
  # typing
  editing = 0
  editNew = false
  editOrig: Shape
  caret = 0
  caretSince = 0
  # bars and panels
  moreOpen = false
  dock: Dock                       ## the panels down the right, in tabs (as Retro Photo's)
  dockCompact = false              ## (laid out for a phone: a strip of icons)
  panelsHidden = false             ## Tab hides them, as in Retro Photo
  # files, dialogs
  status = ""
  openDlg, saveDlg, pictureDlg, exportDlg, exportPick, renameDlg, keysDlg, aboutDlg, askNew, askQuit: bool
  picked = ""
  renameText = ""
  exportFormat = 0                 ## PNG, SVG, PDF
  exportWhat = 0                   ## the page, the selection
  exportScale = 1                  ## 1x, 2x, 3x (0, 1, 2)
  exportBg = true
  exportPad = 32
  afterSave = ""                   ## what to do once saved ("new", "quit")
  # autosave
  seenVer = -1
  savedVer = -1
  changedAt = 0
  pics: Table[int, tuple[n: int; b: Bitmap]]

# ---- small things ------------------------------------------------------------------------------

template th: untyped = ui.theme

proc tint(c: uint32; fade = 1.0): Color =
  Color(r: uint8((c shr 16) and 255), g: uint8((c shr 8) and 255), b: uint8(c and 255),
        a: uint8(clamp(float((c shr 24) and 255) * fade, 0, 255)))

proc withA(c: Color; a: int): Color = Color(r: c.r, g: c.g, b: c.b, a: uint8(clamp(a, 0, 255)))

proc dist(a, b: P): float = hypot(a.x - b.x, a.y - b.y)

proc unitScale(): float =
  ## How big 100% is, in the screen's logical pixels: a page unit to each
  ## pixel of the device -- on a tablet or a phone (and a sharp desktop
  ## screen), half a logical pixel; not less.
  1.0 / float(clamp(pxScale, 1, 2))

proc zoom(): float = bd.page.zoom * unitScale()
  ## How big the page is drawn: logical pixels to a page unit (the zoom
  ## shown, `bd.page.zoom`, is this at 100%)

proc scr(x, y: float): P =
  ## (a page point on the screen)
  (view.x.float + (x - bd.page.camX) * zoom(), view.y.float + (y - bd.page.camY) * zoom())

proc scr(p: P): P = scr(p.x, p.y)

proc pageAt(sx, sy: float): P =
  ## (a screen point on the page)
  ((sx - view.x.float) / zoom() + bd.page.camX, (sy - view.y.float) / zoom() + bd.page.camY)

proc mouseScr(): P = (ui.mx.float + 0.5, ui.my.float + 0.5)
proc mousePg(): P = pageAt(ui.mx.float + 0.5, ui.my.float + 0.5)

proc linkBadge(s: Shape): P =
  ## (where a shape's link badge is on the screen: its top right)
  let b = bd.boundsOf(s)
  let p = scr(b.x + b.w, b.y)
  (p.x - float(dp(4)), p.y + float(dp(4)))


proc tolPg(): float = float(if fingers(): dp(10) else: dp(4)) / zoom()
  ## How near counts as on a shape (page units).

proc moveSlop(): float = float(if ui.touch: dp(8) else: dp(3))

proc cleanSel() =
  var keep: seq[int]
  for id in sel:
    if bd.has(id) and id notin keep: keep.add id
  sel = keep

proc docName(): string =
  if bd.path.len > 0: bd.path.extractFilename.changeFileExt("") else: "Untitled"

proc topIds(): seq[int] =
  for s in bd.page.shapes:
    if s.parent == 0: result.add s.id

proc selShapes(): seq[Shape] =
  for id in sel:
    let s = bd.find(id)
    if s != nil: result.add s[]

proc innerShapeAt(p: P): int =
  ## The shape at a page point, not its group.
  var hollow = 0
  for i in countdown(bd.page.shapes.high, 0):
    let s = bd.page.shapes[i]
    if s.kind == skGroup or s.locked: continue
    let h = bd.hitTest(s, p.x, p.y, tolPg())
    if h in {hitEdge, hitFilled}: return s.id
    if h == hitHollow and hollow == 0: hollow = s.id
  hollow

proc bindableAt(p: P; skip: int): int =
  ## The shape an arrow's end would hold on to at a page point.
  for i in countdown(bd.page.shapes.high, 0):
    let s = bd.page.shapes[i]
    if s.id == skip or s.kind notin {skGeo, skNote, skText, skFrame, skImage} or s.locked: continue
    if bd.hitTest(s, p.x, p.y, tolPg()) != hitNone: return s.id
  0

proc eraserAt(p: P): int =
  for i in countdown(bd.page.shapes.high, 0):
    let s = bd.page.shapes[i]
    if s.kind == skGroup or s.locked: continue
    if bd.hitTest(s, p.x, p.y, tolPg()) in {hitEdge, hitFilled}:
      return (if s.parent != 0: s.parent else: s.id)
  0

# ---- the view ----------------------------------------------------------------------------------

proc zoomAt(sx, sy, z: float) =
  ## Zooms to `z`, the page point at the screen point (`sx`, `sy`) staying there.
  let p = pageAt(sx, sy)
  let nz = clamp(z / unitScale(), 0.05, 8.0) * unitScale()
  bd.page.zoom = nz / unitScale()
  bd.page.camX = p.x - (sx - view.x.float) / nz
  bd.page.camY = p.y - (sy - view.y.float) / nz
  ui.redraw = true

proc zoomBy(f: float) = zoomAt(view.x.float + view.w / 2, view.y.float + view.h / 2, zoom() * f)

proc zoomSteps(up: bool) =
  const steps = [0.1, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0]
  let shown = bd.page.zoom
  var z = shown
  if up:
    z = 8.0
    for s in steps:
      if s > shown + 1e-6:
        z = s
        break
  else:
    z = 0.1
    for i in countdown(steps.high, 0):
      if steps[i] < shown - 1e-6:
        z = steps[i]
        break
  zoomAt(view.x.float + view.w / 2, view.y.float + view.h / 2, z * unitScale())

proc zoomToBox(box: Box; most = 1.0) =
  ## (`most`: the zoom shown at the most -- 1.0: 100%)
  if box.w <= 0 and box.h <= 0: return
  let pad = float(dp(48))
  let room = (w: max(50.0, view.w.float - 2 * pad), h: max(50.0, view.h.float - 2 * pad - dp(56).float))
  let u = unitScale()
  let z = clamp(min(room.w / max(1.0, box.w), room.h / max(1.0, box.h)), 0.05 * u, most * u)
  bd.page.zoom = z / u
  bd.page.camX = box.x + box.w / 2 - view.w.float / 2 / z
  bd.page.camY = box.y + box.h / 2 - (view.h.float - dp(56).float) / 2 / z
  ui.redraw = true

proc zoomToFit() =
  let ids = topIds()
  if ids.len == 0:
    bd.page.zoom = 1
    bd.page.camX = 0
    bd.page.camY = 0
  else: zoomToBox(bd.selectionBounds(ids), 1.0)

proc resetZoom() = zoomAt(view.x.float + view.w / 2, view.y.float + view.h / 2, unitScale())

# ---- style -------------------------------------------------------------------------------------

proc styled(s: var Shape) =
  ## (a new shape in the style chosen)
  s.color = cur.color
  s.fill = cur.fill
  s.dash = cur.dash
  s.size = cur.size
  s.font = cur.font
  s.align = if s.kind == skText: cur.textAlign else: cur.align
  s.opacity = cur.opacity
  if s.kind == skArrow:
    s.head0 = cur.head0
    s.head1 = cur.head1
  if s.kind == skLine: s.spline = cur.spline
  if s.kind == skNote and cur.color in {bcBlack, bcGrey}: s.color = bcYellow
  if s.kind in {skGeo, skDraw}: s.fillColor = cur.fillColor
  s.roughness = cur.roughness
  if s.kind in {skGeo, skFrame, skImage}: s.round = cur.round
  if s.kind == skArrow: s.elbow = cur.elbow
  if s.kind in {skGeo, skNote}: s.valign = cur.valign

proc styleFrom(s: Shape) =
  ## (the style shown: the selected shape's)
  cur.color = s.color
  cur.opacity = s.opacity
  if s.kind in {skGeo, skDraw}: cur.fill = s.fill
  if s.kind in {skGeo, skDraw, skArrow, skLine}: cur.dash = s.dash
  if s.kind notin {skImage, skFrame, skGroup}: cur.size = s.size
  if s.hasText: cur.font = s.font
  if s.kind == skText: cur.textAlign = s.align
  elif s.kind in {skGeo, skNote}: cur.align = s.align
  if s.kind == skArrow:
    cur.head0 = s.head0
    cur.head1 = s.head1
  if s.kind == skLine: cur.spline = s.spline
  if s.kind in {skGeo, skDraw}: cur.fillColor = s.fillColor
  if s.kind in {skGeo, skArrow, skLine, skDraw}: cur.roughness = s.roughness
  if s.kind in {skGeo, skFrame, skImage}: cur.round = s.round
  if s.kind == skArrow: cur.elbow = s.elbow
  if s.kind in {skGeo, skNote}: cur.valign = s.valign

proc finishEdit()
proc startEdit(id: int; isNew = false; at: P = (NaN, NaN))

proc restyle(name: string; f: proc (s: var Shape)) =
  ## Changes the selected shapes' style (what their groups hold too); the
  ## typing goes on after it (its own step to undo).
  if sel.len == 0: return
  let wasEditing = editing
  let keepCaret = caret
  if editing != 0: finishEdit()
  defer:
    if wasEditing != 0 and bd.has(wasEditing):
      startEdit(wasEditing)
      caret = keepCaret
  if sel.len == 0: return
  bd.change(name):
    for id in bd.members(sel):
      let s = bd.find(id)
      if s == nil or s.kind == skGroup: continue
      bd.update(id, proc (t: var Shape) =
        f(t)
        if t.kind == skText: t.fitText())

proc kindsShown(): set[ShapeKind] =
  ## The kinds of shape the style panel is for: the selection's, or the tool's.
  if sel.len > 0:
    for id in bd.members(sel):
      let s = bd.find(id)
      if s != nil and s.kind != skGroup: result.incl s.kind
    return
  case tool
  of tDraw: {skDraw}
  of tHighlight: {skHighlight}
  of tGeo: {skGeo}
  of tArrow: {skArrow}
  of tLine: {skLine}
  of tText: {skText}
  of tNote: {skNote}
  of tFrame: {skFrame}
  else: {skGeo}

# ---- typing in a shape ------------------------------------------------------------------------

proc finishEdit() =
  ## Ends the typing: one step to undo.
  if editing == 0: return
  let id = editing
  editing = 0
  let s = bd.find(id)
  if s == nil: return
  let final = s[]
  let empty = final.text.strip.len == 0
  if editNew:
    bd.removeShape(id)
    if final.kind == skText and empty:
      sel = @[]
      return
    bd.change(if final.kind == skNote: "Note" else: "Text"):
      discard bd.addShape(final, keepId = true)
    sel = @[id]
  else:
    if final.text == editOrig.text: return
    bd.setShape(editOrig)
    if final.kind == skText and empty:
      bd.change("Delete"): bd.removeShape(id)
      sel = @[]
    else:
      bd.change("Edit Text"): bd.setShape(final)
  if not toolLock and tool in {tText, tNote}: tool = tSelect

proc startEdit(id: int; isNew = false; at: P = (NaN, NaN)) =
  ## Types in shape `id` (`at`: the caret where the page point is).
  if editing != 0 and editing != id: finishEdit()
  let s = bd.find(id)
  if s == nil or not s[].hasText: return
  editing = id
  editNew = isNew
  editOrig = s[]
  caret = s.text.runeLen
  if not at.x.isNaN: caret = bd.textIndexAt(s[], at.x, at.y)
  caretSince = ui.now
  sel = @[id]
  ui.redraw = true

proc setEditText(runes: seq[Rune]) =
  let t = $runes
  bd.update(editing, proc (s: var Shape) =
    s.text = t
    if s.kind == skText: s.fitText())
  caretSince = ui.now

proc typing() =
  ## The keys and letters typed while a shape takes them.
  if editing == 0: return
  let s = bd.find(editing)
  if s == nil:
    editing = 0
    return
  ui.takesText = true
  var runes = s.text.toRunes
  caret = clamp(caret, 0, runes.len)
  var changed = false
  if ui.typed.len > 0:
    for r in ui.typed.runes:
      if r.int < 32 and r.int != 10: continue
      runes.insert(r, caret)
      inc caret
    changed = true
  if not ui.keyUsed and canInput():
    let ctrl = CtrlPressed in ui.mods
    var used = true
    # (Ctrl+Backspace / Ctrl+Delete -- Option on a Mac -- a word at a time)
    let byWord = when defined(macosx): AltPressed in ui.mods else: ctrl
    proc wordy(r: Rune): bool = r.isAlpha or (r.int32 >= ord('0') and r.int32 <= ord('9')) or r == Rune(ord('_'))
    case ui.key
    of KeyBackspace:
      if caret > 0:
        var a = caret - 1
        if byWord:
          a = caret
          while a > 0 and not wordy(runes[a - 1]): dec a
          while a > 0 and wordy(runes[a - 1]): dec a
        runes.delete(a .. caret - 1)
        caret = a
        changed = true
    of KeyDelete:
      if caret < runes.len:
        var b = caret + 1
        if byWord:
          b = caret
          while b < runes.len and wordy(runes[b]): inc b
          while b < runes.len and not wordy(runes[b]) and runes[b] != Rune(10): inc b
          b = max(b, caret + 1)
        runes.delete(caret .. b - 1)
        changed = true
    of KeyLeft: caret = max(0, caret - 1)
    of KeyRight: caret = min(runes.len, caret + 1)
    of KeyHome:
      while caret > 0 and runes[caret - 1] != Rune(10): dec caret
    of KeyEnd:
      while caret < runes.len and runes[caret] != Rune(10): inc caret
    of KeyUp, KeyDown:
      let (top, bottom) = bd.textCaret(s[], caret)
      let h = bottom.y - top.y
      let y = if ui.key == KeyUp: top.y - h * 0.5 else: bottom.y + h * 0.5
      caret = bd.textIndexAt(s[], top.x, y)
    of KeyEnter:
      if ctrl or s.kind == skFrame: finishEdit()
      else:
        runes.insert(Rune(10), caret)
        inc caret
        changed = true
    of KeyEsc: finishEdit()
    of KeyV:
      if ctrl:
        for r in getClipboardText().replace("\r\n", "\n").runes:
          runes.insert(r, caret)
          inc caret
        changed = true
      else: used = false
    of KeyA:
      if ctrl: caret = runes.len else: used = false
    else: used = false
    if used:
      ui.keyUsed = true
      caretSince = ui.now
  if changed and editing != 0: setEditText(runes)
  if editing != 0:
    wakeIn(530 - (ui.now - caretSince) mod 530)
    # (the caret where it is seen: above the phone's keyboard, under the bars)
    let e = bd.find(editing)
    if e != nil and view.h > dp(120):
      let (top, bottom) = bd.textCaret(e[], caret)
      let a = scr(top.x, top.y)
      let b = scr(bottom.x, bottom.y)
      let lo = float(view.y + dp(56))
      let hi = float(view.y + view.h - dp(72))
      if b.y > hi: bd.page.camY += (b.y - hi) / zoom()
      elif a.y < lo: bd.page.camY -= (lo - a.y) / zoom()
      let left = float(view.x + dp(16))
      let right = float(view.x + view.w - dp(16))
      if a.x > right: bd.page.camX += (a.x - right) / zoom()
      elif a.x < left: bd.page.camX -= (left - a.x) / zoom()

# ---- selection frame and handles --------------------------------------------------------------

proc selFrameNow(): SelFrame =
  if sel.len == 0: return
  if sel.len == 1:
    let s = bd.find(sel[0])
    if s == nil: return
    if s.kind in {skGeo, skNote, skText, skFrame, skImage}:
      return SelFrame(ok: true, box: (s.x, s.y, s.w, s.h), rot: s.rot, single: s.id)
  let b = bd.selectionBounds(sel)
  SelFrame(ok: b.w > 0 or b.h > 0, box: b, single: (if sel.len == 1: sel[0] else: 0))

proc framePoint(f: SelFrame; u, v: float): P =
  let cx = f.box.x + f.box.w / 2
  let cy = f.box.y + f.box.h / 2
  let lx = f.box.x + u * f.box.w - cx
  let ly = f.box.y + v * f.box.h - cy
  (cx + lx * cos(f.rot) - ly * sin(f.rot), cy + lx * sin(f.rot) + ly * cos(f.rot))

proc handleUV(h: Handle): P =
  case h
  of hNW: (0.0, 0.0)
  of hN: (0.5, 0.0)
  of hNE: (1.0, 0.0)
  of hE: (1.0, 0.5)
  of hSE: (1.0, 1.0)
  of hS: (0.5, 1.0)
  of hSW: (0.0, 1.0)
  of hW: (0.0, 0.5)
  else: (0.5, 0.0)

proc singleKind(): ShapeKind =
  if sel.len == 1:
    let s = bd.find(sel[0])
    if s != nil: return s.kind
  skGroup

proc rotatable(): bool =
  for id in bd.members(sel):
    let s = bd.find(id)
    if s != nil and s.kind == skImage: return false
  true

proc handles(f: SelFrame): seq[(Handle, P)] =
  ## The selection's handles on the page.
  if not f.ok or sel.len == 0: return
  let k = singleKind()
  if k in {skArrow, skLine}: return
  let sw = f.box.w * zoom()
  let sh = f.box.h * zoom()
  let small = float(dp(if ui.touch: 64 else: 36))
  for h in [hNW, hNE, hSE, hSW]: result.add (h, f.framePoint(h.handleUV.x, h.handleUV.y))
  if sw >= small and k != skText:
    for h in [hN, hS]: result.add (h, f.framePoint(h.handleUV.x, h.handleUV.y))
  if sh >= small or k == skText:
    for h in [hE, hW]: result.add (h, f.framePoint(h.handleUV.x, h.handleUV.y))
  if rotatable():
    let top = f.framePoint(0.5, 0)
    let off = float(dp(if ui.touch: 30 else: 22)) / zoom()
    result.add (hRotate, (top.x + sin(f.rot) * off, top.y - cos(f.rot) * off))

proc handleR(): float = float(if ui.touch: dp(7) else: dp(4))

proc handleAt(f: SelFrame; sp: P): Handle =
  let slop = handleR() + float(if ui.touch: dp(10) else: dp(3))
  var best = slop
  for (h, p) in f.handles:
    let d = dist(scr(p), sp)
    if d <= best:
      best = d
      result = h
  if result != hNone: return
  # (on an edge between its corners: that edge)
  if not f.ok or singleKind() in {skArrow, skLine} or sel.len == 0: return
  let edges = [(hN, (0.0, 0.0), (1.0, 0.0)), (hE, (1.0, 0.0), (1.0, 1.0)), (hS, (0.0, 1.0), (1.0, 1.0)),
               (hW, (0.0, 0.0), (0.0, 1.0))]
  for (h, a, b) in edges:
    if singleKind() == skText and h in {hN, hS}: continue
    let pa = scr(f.framePoint(a[0], a[1]))
    let pb = scr(f.framePoint(b[0], b[1]))
    let l = dist(pa, pb)
    if l < 1: continue
    let t = clamp(((sp.x - pa.x) * (pb.x - pa.x) + (sp.y - pa.y) * (pb.y - pa.y)) / (l * l), 0.0, 1.0)
    let q: P = (pa.x + (pb.x - pa.x) * t, pa.y + (pb.y - pa.y) * t)
    if dist(q, sp) <= float(if ui.touch: dp(8) else: dp(3)) and t > 0.1 and t < 0.9: result = h; return

proc pointHandles(): seq[P] =
  ## A single arrow's ends and bend, a line's points (page).
  if sel.len != 1: return
  let s = bd.find(sel[0])
  if s == nil: return
  if s.kind == skArrow:
    let (a, c) = bd.arrowEnds(s[])
    result = @[(a.x, a.y), (c.x, c.y), (let m = bd.arrowMiddle(s[]); (m.x, m.y))]
  elif s.kind == skLine:
    for p in s.pts:
      let q = s[].toPage(p.x.float, p.y.float)
      result.add (q.x, q.y)

proc midHandles(): seq[P] =
  ## A line's "add a point" handles, between its points.
  if sel.len != 1: return
  let s = bd.find(sel[0])
  if s == nil or s.kind != skLine: return
  for i in 1 ..< s.pts.len:
    let a = s[].toPage(s.pts[i - 1].x.float, s.pts[i - 1].y.float)
    let b = s[].toPage(s.pts[i].x.float, s.pts[i].y.float)
    result.add ((a.x + b.x) / 2, (a.y + b.y) / 2)

proc cursorFor(h: Handle; rot: float): CursorKind =
  if h == hRotate: return curHand
  var a = case h
          of hN, hS: 90.0
          of hE, hW: 0.0
          of hNE, hSW: 45.0
          else: 135.0
  a = floorMod(a + radToDeg(rot), 180.0)
  if a < 22.5 or a >= 157.5: curSizeWE
  elif a < 67.5: curSizeNESW
  elif a < 112.5: curSizeNS
  else: curSizeNWSE

# ---- making and changing shapes ---------------------------------------------------------------

proc cancelDrag() =
  ## Stops what a drag was doing, taking it back.
  case drag
  of dkMove, dkResize, dkRotate, dkCreate, dkInk, dkArrowEnd, dkBend, dkLinePoint:
    bd.cancelChange()
  of dkBrush: sel = startSel
  else: discard
  drag = dkNone
  erasing.clear()
  eraseTrail.setLen(0)
  guides.setLen(0)
  creating = 0
  bindTarget = 0
  ui.redraw = true

proc deleteSel() =
  if sel.len == 0: return
  finishEdit()
  bd.change("Delete"):
    for id in sel: bd.removeShape(id)
  sel = @[]

proc copySel() =
  if sel.len > 0: putClipboardText(bd.toClipboard(sel))

proc pasteAt(p: P) =
  let shapes = bd.fromClipboard(getClipboardText())
  if shapes.len > 0:
    bd.change("Paste"): sel = bd.pasteShapes(shapes, p.x, p.y)
  else:
    # (words: a text)
    let words = getClipboardText().strip
    if words.len == 0: return
    var t = bd.textShape(p.x, p.y, words)
    t.styled
    t.fitText()
    t.x -= t.w / 2
    t.y -= t.h / 2
    bd.change("Paste"): sel = @[bd.addShape(t)]

proc viewCenterPg(): P = pageAt(view.x.float + view.w / 2, view.y.float + view.h / 2)

proc pastePoint(): P =
  if view.contains(point(ui.mx, ui.my)): mousePg() else: viewCenterPg()

proc duplicateSel() =
  if sel.len == 0: return
  let d = 16.0 / zoom()
  bd.change("Duplicate"): sel = bd.duplicate(sel, d, d)

proc selectAll() =
  finishEdit()
  sel = @[]
  for s in bd.page.shapes:
    if s.parent == 0 and not s.locked: sel.add s.id

proc groupSel() =
  if sel.len < 2: return
  bd.change("Group"):
    let g = bd.groupShapes(sel)
    if g != 0: sel = @[g]

proc ungroupSel() =
  var out2: seq[int]
  var any = false
  for id in sel:
    let s = bd.find(id)
    if s != nil and s.kind == skGroup: any = true
  if not any: return
  bd.change("Ungroup"):
    for id in sel:
      let s = bd.find(id)
      if s != nil and s.kind == skGroup: out2.add bd.ungroupShapes(id)
      else: out2.add id
  sel = out2

proc lockSel(lock: bool) =
  if sel.len == 0: return
  bd.change(if lock: "Lock" else: "Unlock"):
    for id in bd.members(sel):
      bd.update(id, proc (s: var Shape) = s.locked = lock)
  if lock: sel = @[]

proc unlockAll() =
  var any = false
  for s in bd.page.shapes:
    if s.locked: any = true
  if not any: return
  bd.change("Unlock All"):
    for s in bd.page.shapes:
      if s.locked: bd.update(s.id, proc (t: var Shape) = t.locked = false)

proc arrange(how: string) =
  if sel.len == 0: return
  bd.change(case how
            of "front": "Bring to Front"
            of "back": "Send to Back"
            of "forward": "Bring Forward"
            else: "Send Backward"):
    bd.reorder(bd.members(sel), how)

proc nudge(dx, dy: float) =
  if sel.len == 0: return
  bd.change("Nudge"): bd.moveShapes(sel, dx, dy)

proc setTool(t: Tool) =
  finishEdit()
  if drag != dkNone: cancelDrag()
  tool = t
  moreOpen = false
  if t notin {tSelect}: sel = @[]
  ui.redraw = true

# ---- files -------------------------------------------------------------------------------------

proc autosavePath(): string = dataDir(AppName) / "autosave.board"

proc writeAutosave() =
  try:
    let p = autosavePath()
    writeFile(p & ".part", $bd.toJson)
    moveFile(p & ".part", p)
    savedVer = bd.ver
  except CatchableError: discard

proc saveSettingsNow() =
  var s = loadSettings(AppName)
  s["path"] = bd.path
  s["modified"] = $bd.modified
  s["grid"] = $showGrid
  s["snap"] = $snapOn
  s["dark"] = $darkMode
  s["toolLock"] = $toolLock
  s["status"] = $showStatus
  s["zen"] = $zenMode
  s["font"] = $cur.font
  s["sketch"] = $(cur.dash == bdSketch)
  s["panelsHidden"] = $panelsHidden
  if dock != nil:
    s["dock"] = $dock.toJson
    s["dockCompact"] = $dockCompact
  storeAppearance(s)
  discard saveSettings(AppName, s)

proc applyDark() =
  ## (the canvas drawn for its colors)
  bd.dark = darkMode
  bd.forgetDrawings()
  ui.redraw = true

proc darkScheme(): bool =
  ## (the color scheme in use is a dark one)
  let t = ui.theme
  int(t.window.r) + int(t.window.g) + int(t.window.b) < 200

proc loadStart(fresh = false) =
  ## The board as it was when the program last ended (`fresh`: the last run
  ## stopped and the user chose to start without it -- the settings alone).
  let s = loadSettings(AppName)
  showGrid = s.get("grid", "true") == "true"
  snapOn = s.get("snap", "true") == "true"
  darkMode = s.get("dark", "false") == "true"
  toolLock = s.get("toolLock", "false") == "true"
  showStatus = s.get("status", "true") == "true"
  zenMode = s.get("zen", "false") == "true"
  for f in BoardFont:
    if $f == s.get("font", "hand"): cur.font = f
  if s.get("sketch", "false") == "true": cur.dash = bdSketch
  restoreAppearance(s)
  if not fresh and fileExists(autosavePath()):
    let b = loadBoard(autosavePath())
    if b != nil:
      bd = b
      bd.path = s.get("path", "")
      bd.modified = s.get("modified", "false") == "true"
  savedVer = bd.ver
  seenVer = bd.ver

proc newBoardNow() =
  finishEdit()
  bd = newBoard()
  sel = @[]
  pics.clear()
  applyDark()
  writeAutosave()
  saveSettingsNow()

proc openBoard(path: string) =
  let b = loadBoard(path)
  if b == nil:
    status = "Not a board: " & path.extractFilename
    return
  finishEdit()
  bd = b
  bd.modified = false
  sel = @[]
  pics.clear()
  applyDark()
  writeAutosave()
  saveSettingsNow()
  status = "Opened " & path.extractFilename

proc saveTo(path: string): bool =
  var p = path
  if p.splitFile.ext.len == 0: p.add ".board"
  try:
    bd.name = p.extractFilename.changeFileExt("")
    bd.saveBoard(p)
    saveSettingsNow()
    status = "Saved " & p.extractFilename
    true
  except CatchableError:
    status = "Could not save " & p.extractFilename
    false

proc save(): bool =
  if bd.path.len == 0:
    picked = docName() & ".board"
    saveDlg = true
    false
  else: saveTo(bd.path)

proc insertPicture(path: string) =
  let pic = loadPicture(path, 2048, 2048)
  if pic == nil or pic.w <= 0:
    status = "Could not read " & path.extractFilename
    return
  var data = ""
  try:
    let raw = readFile(path)
    let ext = path.splitFile.ext.toLowerAscii
    if raw.len <= 4_000_000 and ext in [".png", ".jpg", ".jpeg", ".bmp"]:
      let big = loadPicture(path, 100000, 100000)
      if big != nil and big.w == pic.w and big.h == pic.h: data = raw
  except CatchableError: discard
  if data.len == 0: data = encodePng(pic)
  let k = min(1.0, 600.0 / max(pic.w, pic.h).float)
  let c = viewCenterPg()
  var s = bd.newShape(skImage, c.x - pic.w.float * k / 2, c.y - pic.h.float * k / 2, pic.w.float * k,
                      pic.h.float * k)
  s.image = bd.addAsset(data)
  bd.change("Insert Picture"): sel = @[bd.addShape(s)]
  setTool(tSelect)
  sel = @[bd.page.shapes[^1].id]

proc exportIds(): seq[int] =
  if exportWhat == 1 and sel.len > 0:
    result = sel
    # (a frame: what is in it too)
    for id in sel:
      let s = bd.find(id)
      if s != nil and s.kind == skFrame:
        for c in bd.contentsOf(id):
          if c notin result: result.add c

proc exportExt(): string = [".png", ".svg", ".pdf"][exportFormat]

proc exportBytes(): string =
  # (in the dark colors, asked: drawn again for it, then back)
  let wasDark = bd.dark
  if exportDark != wasDark:
    bd.dark = exportDark
    bd.forgetDrawings()
  defer:
    if bd.dark != wasDark:
      bd.dark = wasDark
      bd.forgetDrawings()
  let ids = exportIds()
  let pad = exportPad.float
  case exportFormat
  of 0: encodePng(bd.renderBitmap(ids, scale = float(exportScale + 1), background = exportBg, padding = pad))
  of 1: bd.toSvg(ids, background = exportBg, padding = pad)
  else: bd.toPdf(ids, background = exportBg, padding = pad)

proc exportTo(path: string) =
  var p = path
  if p.splitFile.ext.toLowerAscii != exportExt(): p.add exportExt()
  try:
    writeFile(p, exportBytes())
    status = "Exported " & p.extractFilename
  except CatchableError:
    status = "Could not write " & p.extractFilename

proc exportShare() =
  let dir = dataDir(AppName) / "share"
  try:
    createDir(dir)
    let p = dir / docName() & exportExt()
    writeFile(p, exportBytes())
    if not shareFile(p): status = "Saved for sharing: " & p
  except CatchableError:
    status = "Could not share the export"

# ---- drawing helpers ---------------------------------------------------------------------------

proc strokeScr(pts: openArray[P]; w: float; c: Color; closed = false) =
  ## A line through screen points.
  var ps: seq[tuple[x, y: float]]
  for p in pts: ps.add (p.x, p.y)
  if ps.len == 0: return
  fillContours(styledStroke(ps, w, closed, bdSolid, 0), c)

proc strokePg(pts: openArray[P]; w: float; c: Color; closed = false) =
  var s: seq[P]
  for p in pts: s.add scr(p)
  strokeScr(s, w, c, closed)

proc squareHandle(p: P; c: Color) =
  let r = handleR()
  if ui.touch:
    disc(p.x, p.y, r + 1, c)
    disc(p.x, p.y, r - 0.5, Color(r: 255, g: 255, b: 255, a: 255))
  else:
    let q = rect(int(p.x - r), int(p.y - r), int(2 * r) + 1, int(2 * r) + 1)
    fill(q, Color(r: 255, g: 255, b: 255, a: 255))
    box(q, c)

proc roundHandle(p: P; c: Color; filled = false) =
  let r = handleR() + 1
  disc(p.x, p.y, r + 1, c)
  disc(p.x, p.y, r - 0.5, if filled: c else: Color(r: 255, g: 255, b: 255, a: 255))

proc drawGlyph(r: Rect; glyph: string; size = 1.3) =
  drawLabeled(r, glyphPic(glyph, size), "", blIconOnly, true, false)

proc drawIcon(ic: Icon; r: Rect; c: Color; geo = gkRectangle) =
  ## A tool's picture, drawn in its button.
  let s = float(min(r.w, r.h)) * 0.56
  let ox = r.x.float + (r.w.float - s) / 2
  let oy = r.y.float + (r.h.float - s) / 2
  proc at(u, v: float): P = (ox + u * s, oy + v * s)
  let lw = max(1.5, s / 11)
  case ic
  of icSelect:
    polygon([at(0.22, 0.04), at(0.22, 0.86), at(0.42, 0.67), at(0.56, 0.97), at(0.69, 0.91),
             at(0.55, 0.61), at(0.82, 0.61)].mapIt((it.x, it.y)), c)
  of icHand:
    for (x, y0) in [(0.3, 0.22), (0.45, 0.1), (0.6, 0.14), (0.75, 0.28)]:
      strokeScr([at(x, y0), at(x, 0.6)], s * 0.12, c)
    strokeScr([at(0.12, 0.5), at(0.28, 0.72)], s * 0.12, c)
    polygon([at(0.25, 0.5), at(0.81, 0.5), at(0.78, 0.82), at(0.62, 0.98), at(0.38, 0.98), at(0.26, 0.8)].mapIt(
      (it.x, it.y)), c)
  of icDraw: drawGlyph(r, nfPencil)
  of icHighlight:
    strokeScr([at(0.12, 0.86), at(0.86, 0.16)], s * 0.3, c.withA(90))
    strokeScr([at(0.12, 0.86), at(0.86, 0.16)], lw, c)
  of icEraser: drawGlyph(r, nfEraser)
  of icLaser: drawGlyph(r, nfMagic)
  of icGeo:
    var pts: seq[P]
    for p in geoOutline(geo, s * 0.92, s * 0.92): pts.add (ox + s * 0.04 + p.x, oy + s * 0.04 + p.y)
    strokeScr(pts, lw, c, closed = true)
    for d in geoDetails(geo, s * 0.92, s * 0.92):
      var q: seq[P]
      for p in d: q.add (ox + s * 0.04 + p.x, oy + s * 0.04 + p.y)
      strokeScr(q, lw, c)
  of icArrow:
    strokeScr([at(0.12, 0.88), at(0.86, 0.14)], lw, c)
    strokeScr([at(0.42, 0.12), at(0.88, 0.12), at(0.88, 0.58)], lw, c)
  of icLine:
    strokeScr([at(0.15, 0.85), at(0.85, 0.15)], lw, c)
    disc(at(0.15, 0.85).x, at(0.15, 0.85).y, lw * 1.6, c)
    disc(at(0.85, 0.15).x, at(0.85, 0.15).y, lw * 1.6, c)
  of icText: drawGlyph(r, nfFont)
  of icNote:
    polygon([at(0.1, 0.1), at(0.9, 0.1), at(0.9, 0.62), at(0.62, 0.9), at(0.1, 0.9)].mapIt((it.x, it.y)),
            c.withA(70))
    strokeScr([at(0.1, 0.1), at(0.9, 0.1), at(0.9, 0.62), at(0.62, 0.9), at(0.1, 0.9)], lw, c, closed = true)
    strokeScr([at(0.9, 0.62), at(0.62, 0.62), at(0.62, 0.9)], lw, c)
  of icFrame:
    strokeScr([at(0.0, 0.28), at(1.0, 0.28)], lw, c)
    strokeScr([at(0.0, 0.72), at(1.0, 0.72)], lw, c)
    strokeScr([at(0.28, 0.0), at(0.28, 1.0)], lw, c)
    strokeScr([at(0.72, 0.0), at(0.72, 1.0)], lw, c)
  of icImage: drawGlyph(r, nfImage)
  of icMore: drawGlyph(r, nfChevronUp)
  of icStyle:
    disc(ox + s / 2, oy + s / 2, s * 0.5, c)
    disc(ox + s / 2, oy + s / 2, s * 0.38, tint(inkOf(cur.color, darkMode)))
  of icUndo: drawGlyph(r, nfUndo)
  of icRedo: drawGlyph(r, nfRedo)
  of icDelete: drawGlyph(r, nfTrash)
  of icDuplicate: drawGlyph(r, nfCopy)
  of icPages: drawGlyph(r, nfFiles)
  of icMenu: drawGlyph(r, nfBars)
  of icFill, icDash: discard

proc panel(r: Rect) =
  ## A raised bar floating over the canvas.
  fill(r, th.face)
  box(r, th.frame)
  hline(r.x + 1, r.y + 1, r.w - 2, th.light)
  vline(r.x + 1, r.y + 1, r.h - 2, th.light)
  hline(r.x + 1, r.y + r.h - 2, r.w - 2, th.shadow)
  vline(r.x + r.w - 2, r.y + 1, r.h - 2, th.shadow)

proc iconButton(key: string; r: Rect; down: bool; tip: string; ic: Icon; geo = gkRectangle;
                enabled = true): bool =
  ## A button of a floating bar with a picture: true when clicked.
  let hit = interact(idOf("bb:" & key), r, focusable = false, enabled = enabled)
  if accessible():
    accessNode(if down: arToggleButton else: arButton, tip, id = idOf("bb:" & key), r = r,
               states = (if down: {asPressed, asChecked} else: {}) + (if enabled: {} else: {asDisabled}))
  let pressed = down or hit.down
  buttonFace(r, pressed, 1, rounded = false, bevel = 1, hot = enabled and hovered(r))
  if down and not hit.down: checker(inset(r, 2), th.light)
  let d = if pressed: 1 else: 0
  drawIcon(ic, rect(r.x + d, r.y + d, r.w, r.h), if enabled: th.text else: th.gray, geo)
  tooltip(tip)
  hit.clicked

proc paintButton(key: string; r: Rect; down: bool; tip: string): tuple[clicked: bool; r: Rect] =
  ## A button whose picture the caller draws (in the rectangle returned).
  let hit = interact(idOf("bp:" & key), r, focusable = false)
  if accessible():
    accessNode(if down: arToggleButton else: arButton, tip, id = idOf("bp:" & key), r = r,
               states = (if down: {asPressed, asChecked} else: {}))
  let pressed = down or hit.down
  buttonFace(r, pressed, 1, rounded = false, bevel = 1, hot = hovered(r))
  if down and not hit.down: checker(inset(r, 2), th.light)
  let d = if pressed: 1 else: 0
  tooltip(tip)
  (hit.clicked, rect(r.x + d, r.y + d, r.w, r.h))

# ---- the canvas: input ------------------------------------------------------------------------

proc overBlocker(): bool =
  for r in blockers:
    if r.contains(point(ui.mx, ui.my)): return true
  false

proc startMove() =
  ## The selection begins to move (frames take what is in them).
  var ids = sel
  for id in sel:
    let s = bd.find(id)
    if s != nil and s.kind == skFrame:
      for c in bd.contentsOf(id):
        if c notin ids: ids.add c
  let moving = toHashSet(bd.members(ids))
  bd.begin("Move")
  # (arrows that hold on to shapes staying put let go of them)
  for id in moving:
    let s = bd.find(id)
    if s == nil or s.kind != skArrow: continue
    let (a, c) = bd.arrowEnds(s[])
    if (s.t0.bound != 0 and s.t0.bound notin moving) or (s.t1.bound != 0 and s.t1.bound notin moving):
      bd.update(id, proc (t: var Shape) =
        if t.t0.bound != 0 and t.t0.bound notin moving: t.t0 = Terminal(x: a.x, y: a.y)
        if t.t1.bound != 0 and t.t1.bound notin moving: t.t1 = Terminal(x: c.x, y: c.y))
  startShapes = @[]
  for s in bd.shapesOf(ids):
    if s.kind != skGroup: startShapes.add s
  drag = dkMove

proc moveTo(p: P) =
  var dx = p.x - dragFromPg.x
  var dy = p.y - dragFromPg.y
  if ShiftPressed in ui.mods:
    if abs(dx) > abs(dy): dy = 0 else: dx = 0
  guides.setLen(0)
  if snapOn xor (CtrlPressed in ui.mods):
    var ids: seq[int]
    var box: Box
    var any = false
    for s in startShapes:
      ids.add s.id
      var t = s
      t.moveBy(dx, dy)
      let k = if s.kind == skArrow: bd.boundsOf(s) else: bd.boundsOf(t)
      let kk: Box = if s.kind == skArrow: (k.x + dx, k.y + dy, k.w, k.h) else: k
      box = if any: box.union(kk) else: kk
      any = true
    let sn = bd.snapBox(box, ids, float(dp(6)) / zoom())
    dx += sn.dx
    dy += sn.dy
    guides = sn.guides
  for s in startShapes:
    var t = s
    t.moveBy(dx, dy)
    bd.setShape(t)

proc resizeTo(p: P) =
  let f = startFrame
  let cx = f.box.x + f.box.w / 2
  let cy = f.box.y + f.box.h / 2
  # (the pointer in the frame's own terms)
  let co = cos(-f.rot)
  let si = sin(-f.rot)
  let lp: P = (cx + (p.x - cx) * co - (p.y - cy) * si, cy + (p.x - cx) * si + (p.y - cy) * co)
  let uv = dragHandle.handleUV
  let ax = f.box.x + (1 - uv.x) * f.box.w
  let ay = f.box.y + (1 - uv.y) * f.box.h
  let hx = f.box.x + uv.x * f.box.w
  let hy = f.box.y + uv.y * f.box.h
  var sx = if uv.x == 0.5 or abs(hx - ax) < 1e-9: 1.0 else: (lp.x - ax) / (hx - ax)
  var sy = if uv.y == 0.5 or abs(hy - ay) < 1e-9: 1.0 else: (lp.y - ay) / (hy - ay)
  # one text: its sides set how wide it wraps (its letters stay)
  if startShapes.len == 1 and startShapes[0].kind == skText and dragHandle in {hE, hW}:
    var t = startShapes[0]
    let w = max(t.textSize, abs(lp.x - ax))
    t.autoSize = false
    t.w = w
    t.fitText()
    let left = if lp.x < ax: ax - w else: ax
    let c0 = t.center
    let nc = t.toPage(left - t.x + w / 2, t.h / 2)
    discard c0
    if f.rot == 0:
      t.x = left
    else:
      t.x = nc.x - w / 2
      t.y = nc.y - t.h / 2
    bd.setShape(t)
    return
  var keep = ShiftPressed in ui.mods
  if startShapes.len == 1 and startShapes[0].kind in {skImage, skText} and dragHandle in {hNW, hNE, hSE, hSW}:
    keep = not keep
  if keep:
    if uv.x == 0.5: sx = abs(sy)
    elif uv.y == 0.5: sy = abs(sx)
    else:
      let m = max(abs(sx), abs(sy))
      sx = m * (if sx < 0: -1.0 else: 1.0)
      sy = m * (if sy < 0: -1.0 else: 1.0)
  if abs(sx) < 1e-3: sx = 1e-3
  if abs(sy) < 1e-3: sy = 1e-3
  let anchor = f.framePoint(1 - uv.x, 1 - uv.y)
  for s0 in startShapes:
    var s = s0
    if f.rot != 0 and startShapes.len == 1:
      s.rot = 0
      s.scaleAbout(ax, ay, sx, sy)
      let c = s.center
      let qx = c.x + (ax - c.x) * cos(f.rot) - (ay - c.y) * sin(f.rot)
      let qy = c.y + (ax - c.x) * sin(f.rot) + (ay - c.y) * cos(f.rot)
      s.rot = s0.rot
      s.moveBy(anchor.x - qx, anchor.y - qy)
    else:
      s.scaleAbout(ax, ay, sx, sy)
    if s.kind == skText and s.autoSize: s.fitText()
    bd.setShape(s)

proc rotateTo(p: P) =
  let c = startFrame.framePoint(0.5, 0.5)
  var d = arctan2(p.y - c.y, p.x - c.x) - arctan2(dragFromPg.y - c.y, dragFromPg.x - c.x)
  if ShiftPressed in ui.mods:
    let step = PI / 12
    d = round((startFrame.rot + d) / step) * step - startFrame.rot
  for s0 in startShapes:
    var s = s0
    s.rotateAbout(c.x, c.y, d)
    bd.setShape(s)

proc terminalAt(p: P; skip: int): Terminal =
  ## An arrow's end at a page point: held by the shape there (not Alt).
  if AltPressed notin ui.mods:
    let t = bindableAt(p, skip)
    if t != 0:
      let s = bd.find(t)
      let l = s[].toLocal(p.x, p.y)
      bindTarget = t
      return Terminal(x: p.x, y: p.y, bound: t, nx: clamp(l.x / max(1.0, s.w), 0.0, 1.0),
                      ny: clamp(l.y / max(1.0, s.h), 0.0, 1.0), precise: CtrlPressed in ui.mods)
  bindTarget = 0
  Terminal(x: p.x, y: p.y)

proc arrowEndTo(p: P) =
  let id = if creating != 0: creating else: startShapes[0].id
  let t = terminalAt(p, id)
  let other = bd.find(id)
  if other == nil: return
  # (not both ends on the same point of the same shape)
  let idx = endIdx
  bd.update(id, proc (s: var Shape) =
    if idx == 0: s.t0 = t else: s.t1 = t)

proc bendTo(p: P) =
  let s0 = startShapes[0]
  let (a, c) = bd.arrowEnds(s0)
  let d = hypot(c.x - a.x, c.y - a.y)
  if d < 1e-6: return
  let nx = -(c.y - a.y) / d
  let ny = (c.x - a.x) / d
  var bend = (p.x - (a.x + c.x) / 2) * nx + (p.y - (a.y + c.y) / 2) * ny
  if abs(bend) * zoom() < 6: bend = 0
  var s = s0
  s.bend = bend
  bd.setShape(s)

proc linePointTo(p: P) =
  var s = startShapes[0]
  let l = s.toLocal(p.x, p.y)
  if endIdx < s.pts.len:
    s.pts[endIdx] = (float32(l.x), float32(l.y), 0.5'f32)
  bd.setShape(s)

proc newFrame(id: int) =
  ## (a frame made: named, and behind what it will hold)
  var n = 0
  for s in bd.page.shapes:
    if s.kind == skFrame: inc n
  bd.update(id, proc (s: var Shape) = s.text = "Frame " & $n)
  bd.reorder([id], "back")

proc createTo(p: P) =
  ## The shape being made follows the pointer.
  let a = dragFromPg
  case tool
  of tGeo, tFrame:
    var w = abs(p.x - a.x)
    var h = abs(p.y - a.y)
    if ShiftPressed in ui.mods:
      w = max(w, h)
      h = w
    let x = if p.x < a.x: a.x - w else: a.x
    let y = if p.y < a.y: a.y - h else: a.y
    if creating == 0:
      var s = if tool == tGeo: bd.geoShape(geoKind, x, y, w, h) else: bd.newShape(skFrame, x, y, w, h)
      s.styled
      creating = bd.addShape(s)
      if tool == tFrame: newFrame(creating)
    else:
      bd.update(creating, proc (s: var Shape) =
        s.x = x
        s.y = y
        s.w = max(1.0, w)
        s.h = max(1.0, h))
  of tArrow:
    if creating == 0:
      var s = bd.arrowShape(a.x, a.y, p.x, p.y)
      s.styled
      s.t0 = terminalAt(a, 0)
      bindTarget = 0
      creating = bd.addShape(s)
      endIdx = 1
    arrowEndTo(p)
  of tLine:
    # (begun on a shape, or brought onto one: a connector -- an arrow with no
    # heads, held by the shapes at its ends, as an arrow is)
    proc connects(q: P; skip: int): bool =
      # (a shape there, not a frame round what is drawn in it; Alt: none)
      let t = bindableAt(q, skip)
      AltPressed notin ui.mods and t != 0 and bd.find(t).kind != skFrame
    let onShape = connects(p, creating)
    let fromShape = connects(a, 0)
    let made = if creating != 0: bd.find(creating) else: nil
    if (creating == 0 and (fromShape or onShape)) or (made != nil and made.kind == skLine and onShape):
      if made != nil: bd.removeShape(creating)
      var s = bd.arrowShape(a.x, a.y, p.x, p.y)
      s.styled
      s.head0 = ahNone
      s.head1 = ahNone
      s.t0 = terminalAt(a, 0)
      bindTarget = 0
      creating = bd.addShape(s)
      endIdx = 1
    if creating != 0 and bd.find(creating).kind == skArrow:
      arrowEndTo(p)
      return
    if creating == 0:
      var s = bd.newShape(skLine, a.x, a.y, 1, 1)
      s.styled
      s.pts = @[(0'f32, 0'f32, 0.5'f32), (0'f32, 0'f32, 0.5'f32)]
      creating = bd.addShape(s)
    var dx = p.x - a.x
    var dy = p.y - a.y
    if ShiftPressed in ui.mods:
      # (at a multiple of 45 degrees)
      let ang = round(arctan2(dy, dx) / (PI / 4)) * (PI / 4)
      let l = hypot(dx, dy)
      dx = cos(ang) * l
      dy = sin(ang) * l
    bd.update(creating, proc (s: var Shape) =
      s.pts[1] = (float32(dx), float32(dy), 0.5'f32))
  else: discard

proc inkTo(p: P) =
  let s = bd.find(creating)
  if s == nil: return
  let last = s.pts[^1]
  let lx = p.x - s.x
  let ly = p.y - s.y
  if hypot(lx - last.x.float, ly - last.y.float) * zoom() < 0.8: return
  let pr = if ui.pen: float32(clamp(ui.pressure, 0.05, 1.0)) else: 0.5'f32
  bd.update(creating, proc (t: var Shape) = t.pts.add (float32(lx), float32(ly), pr))

proc eraseTo(p: P) =
  let a = pageAt(lastScr.x, lastScr.y)
  let n = max(1, int(dist(a, p) / max(1e-6, tolPg() / 2)))
  for i in 0 .. n:
    let q: P = (a.x + (p.x - a.x) * i.float / n.float, a.y + (p.y - a.y) * i.float / n.float)
    let id = eraserAt(q)
    if id != 0: erasing.incl id
  eraseTrail.add (p, ui.now)

proc openCanvasMenu(sp: P) =
  openPopupMenu("boardmenu", int(sp.x), int(sp.y))

proc pressCanvas() =
  ## The pointer went down on the canvas.
  let sp = mouseScr()
  let p = mousePg()
  dragFrom = sp
  dragFromPg = p
  lastScr = sp
  pressAt = ui.now
  ui.dragsActive = true
  moreOpen = false
  if tool == tSelect or viewMode:
    for i in countdown(bd.page.shapes.high, 0):
      let s = bd.page.shapes[i]
      if s.link.len > 0 and s.kind != skGroup and dist(linkBadge(s), sp) <= float(dp(12)):
        finishEdit()
        openUrl(if s.link.contains("://") or s.link.startsWith("mailto:"): s.link else: "https://" & s.link)
        status = "Opened " & s.link
        drag = dkNone
        return
  if viewMode:
    drag = dkPan
    return
  # typing: a press in the shape moves the caret; elsewhere it ends
  if editing != 0:
    let s = bd.find(editing)
    if s != nil and (bd.hitTest(s[], p.x, p.y, tolPg()) != hitNone or
                     (s.kind == skArrow and dist(p, (let m = bd.arrowMiddle(s[]); (m.x, m.y))) < 40)):
      caret = bd.textIndexAt(s[], p.x, p.y)
      caretSince = ui.now
      drag = dkEditText
      return
    finishEdit()
  if spaceHeld or tool == tHand:
    drag = dkPan
    return
  case tool
  of tSelect:
    let f = selFrameNow()
    # the handles of what is selected
    if sel.len == 1 and singleKind() in {skArrow, skLine}:
      let s = bd.find(sel[0])
      let ph = pointHandles()
      for i, q in ph:
        if dist(scr(q), sp) <= handleR() + float(if ui.touch: dp(12) else: dp(4)):
          startShapes = @[s[]]
          endIdx = i
          if s.kind == skArrow:
            bd.begin("Arrow")
            drag = if i == 2: dkBend else: dkArrowEnd
          else:
            bd.begin("Line")
            drag = dkLinePoint
          return
      if s.kind == skLine:
        for i, q in midHandles():
          if dist(scr(q), sp) <= handleR() + float(if ui.touch: dp(10) else: dp(3)):
            bd.begin("Add Point")
            let l = s[].toLocal(q.x, q.y)
            bd.update(s.id, proc (t: var Shape) = t.pts.insert((float32(l.x), float32(l.y), 0.5'f32), i + 1))
            startShapes = @[bd.find(sel[0])[]]
            endIdx = i + 1
            drag = dkLinePoint
            return
    let h = f.handleAt(sp)
    if h != hNone:
      startFrame = f
      startShapes = @[]
      for s in bd.shapesOf(sel):
        if s.kind != skGroup: startShapes.add s
      dragHandle = h
      if h == hRotate:
        bd.begin("Rotate")
        drag = dkRotate
      else:
        bd.begin("Resize")
        drag = dkResize
      return
    let hit = bd.topShapeAt(p.x, p.y, tolPg())
    if ui.clicks >= 2:
      # a double click: type in the shape, go into its group, or a new text
      let inner = innerShapeAt(p)
      if inner != 0:
        let s = bd.find(inner)
        if s.parent != 0 and inner notin sel:
          sel = @[inner]
        elif s[].hasText:
          startEdit(inner, at = p)
        drag = dkNone
        return
      if hit == 0:
        var t = bd.textShape(p.x, p.y)
        t.styled
        t.fitText()
        t.y -= t.h / 2
        let id = bd.addShape(t)
        startEdit(id, isNew = true)
        drag = dkNone
        return
    startSel = sel
    if hit != 0:
      if ShiftPressed in ui.mods:
        if hit in sel: sel.delete(sel.find(hit)) else: sel.add hit
      elif hit notin sel:
        sel = @[hit]
      pressHit = hit
      drag = dkPending
      let s = bd.find(hit)
      if s != nil and s.kind != skGroup: styleFrom(s[])
    elif f.ok and sel.len > 1 and inside((p.x, p.y), @[f.framePoint(0, 0), f.framePoint(1, 0),
                                                       f.framePoint(1, 1), f.framePoint(0, 1)]):
      pressHit = 0
      drag = dkPending
    else:
      if ShiftPressed notin ui.mods: sel = @[]
      pressHit = 0
      drag = dkBrush
      brush = (p.x, p.y, 0.0, 0.0)
      brushOn = false
  of tDraw, tHighlight:
    var s = bd.newShape(if tool == tDraw: skDraw else: skHighlight, p.x, p.y, 1, 1)
    s.styled
    if tool == tHighlight and cur.color == bcBlack: s.color = bcYellow
    s.isPen = ui.pen
    let pr = if ui.pen: float32(clamp(ui.pressure, 0.05, 1.0)) else: 0.5'f32
    s.pts = @[(0'f32, 0'f32, pr)]
    bd.begin(if tool == tDraw: "Draw" else: "Highlight")
    creating = bd.addShape(s)
    drag = dkInk
  of tEraser:
    erasing.clear()
    eraseTrail = @[(p, ui.now)]
    let id = eraserAt(p)
    if id != 0: erasing.incl id
    drag = dkErase
  of tLaser:
    laser.add (p, ui.now)
    drag = dkLaser
  of tGeo, tArrow, tLine, tFrame:
    bd.begin($tool)
    creating = 0
    drag = dkCreate
  of tText:
    let inner = innerShapeAt(p)
    if inner != 0 and bd.find(inner).kind in {skText, skGeo, skNote}:
      startEdit(inner, at = p)
    else:
      var t = bd.textShape(p.x, p.y)
      t.styled
      t.fitText()
      t.y -= t.h / 2
      startEdit(bd.addShape(t), isNew = true)
    drag = dkNone
  of tNote:
    var n = bd.noteShape(p.x, p.y)
    n.styled
    startEdit(bd.addShape(n), isNew = true)
    drag = dkNone
  of tHand: drag = dkPan

proc dragCanvas() =
  ## The pointer moved, held down.
  if ui.mx < -1000 or ui.my < -1000: return       # (a second finger: the first one's press ends far away)
  let sp = mouseScr()
  let p = mousePg()
  if sp == lastScr and drag notin {dkPending, dkBrush}: return
  case drag
  of dkPan:
    bd.page.camX -= (sp.x - lastScr.x) / zoom()
    bd.page.camY -= (sp.y - lastScr.y) / zoom()
  of dkPending:
    if dist(sp, dragFrom) > moveSlop():
      if sel.len > 0: startMove() else: drag = dkNone
      if drag == dkMove: moveTo(p)
    elif ui.touch and ui.now - pressAt >= 500:
      # (held still: its menu)
      drag = dkNone
      openCanvasMenu(sp)
    else:
      wakeIn(max(1, 500 - (ui.now - pressAt)))
  of dkBrush:
    if not brushOn:
      if dist(sp, dragFrom) <= moveSlop():
        # (held still: on a touch screen, the menu)
        if ui.touch:
          if ui.now - pressAt >= 500:
            drag = dkNone
            openCanvasMenu(sp)
          else: wakeIn(max(1, 500 - (ui.now - pressAt)))
        return
      brushOn = true
    let x0 = min(dragFromPg.x, p.x)
    let y0 = min(dragFromPg.y, p.y)
    brush = (x0, y0, abs(p.x - dragFromPg.x), abs(p.y - dragFromPg.y))
    block:
      let ids = bd.shapesIn(brush, touching = AltPressed notin ui.mods)
      if ShiftPressed in ui.mods:
        sel = startSel
        for id in ids:
          if id notin sel: sel.add id
      else: sel = ids
  of dkMove: moveTo(p)
  of dkResize: resizeTo(p)
  of dkRotate: rotateTo(p)
  of dkCreate:
    if creating != 0 or dist(sp, dragFrom) > moveSlop(): createTo(p)
  of dkInk: inkTo(p)
  of dkErase: eraseTo(p)
  of dkLaser:
    laser.add (p, ui.now)
  of dkArrowEnd: arrowEndTo(p)
  of dkBend: bendTo(p)
  of dkLinePoint: linePointTo(p)
  of dkEditText:
    let s = bd.find(editing)
    if s != nil: caret = bd.textIndexAt(s[], p.x, p.y)
  of dkNone: discard
  lastScr = sp
  ui.redraw = true

proc releaseCanvas() =
  ## The pointer was let go.
  # (a second finger came down: the first one's press is let go far away --
  # what it began is taken back, the fingers pinch and pan)
  if ui.mx < -1000 or ui.my < -1000:
    cancelDrag()
    return
  case drag
  of dkPending:
    # a click on a shape of the selection: just it
    if pressHit != 0 and ShiftPressed notin ui.mods and sel.len > 1 and pressHit in startSel:
      sel = @[pressHit]
  of dkBrush: discard
  of dkMove, dkResize, dkRotate, dkBend, dkLinePoint:
    if drag == dkLinePoint:
      let id = startShapes[0].id
      bd.update(id, proc (s: var Shape) = s.fitInk())
    bd.commit()
  of dkArrowEnd:
    bd.commit()
  of dkCreate:
    let p = mousePg()
    if creating == 0:
      # a click: a shape of the usual size there
      case tool
      of tGeo, tFrame:
        let (w, h) = if tool == tGeo: (100.0, 100.0) else: (320.0, 200.0)
        var s = if tool == tGeo: bd.geoShape(geoKind, p.x - w / 2, p.y - h / 2, w, h)
                else: bd.newShape(skFrame, p.x - w / 2, p.y - h / 2, w, h)
        s.styled
        creating = bd.addShape(s)
        if tool == tFrame: newFrame(creating)
      else: discard
    if creating != 0:
      let id = creating
      bd.update(id, proc (s: var Shape) =
        if s.kind == skLine: s.fitInk()
        if s.kind in {skGeo, skFrame}:
          s.w = max(s.w, 8.0)
          s.h = max(s.h, 8.0))
      bd.commit()
      sel = @[id]
      if not toolLock: tool = tSelect
    else: bd.cancelChange()
  of dkInk:
    let id = creating
    let tolClose = float(dp(12)) / zoom()
    bd.update(id, proc (s: var Shape) =
      s.fitInk()
      if s.pts.len > 6:
        let a = s.pts[0]
        let b = s.pts[^1]
        var run = 0.0
        for i in 1 ..< s.pts.len:
          run += hypot(float(s.pts[i].x - s.pts[i - 1].x), float(s.pts[i].y - s.pts[i - 1].y))
        if hypot(float(a.x - b.x), float(a.y - b.y)) < tolClose and run > tolClose * 6:
          s.closed = true)
    bd.commit()
  of dkErase:
    if erasing.len > 0:
      bd.change("Erase"):
        for id in erasing: bd.removeShape(id)
      sel = @[]
    erasing.clear()
  else: discard
  drag = dkNone
  creating = 0
  guides.setLen(0)
  bindTarget = 0
  cleanSel()
  if sel.len == 1:
    let s = bd.find(sel[0])
    if s != nil and s.kind != skGroup: styleFrom(s[])

proc canvasInput() =
  ## The pointer, the wheel and two fingers on the canvas.
  if not ui.mouseDown and drag != dkNone and not ui.released:
    # (the press ended where we did not see it: a dialog took it)
    if drag in {dkMove, dkResize, dkRotate, dkCreate, dkInk, dkArrowEnd, dkBend, dkLinePoint}: bd.commit()
    drag = dkNone
  # two fingers: zoom and pan
  if (ui.pinch != 1.0 or ui.panDX != 0 or ui.panDY != 0) and canInput():
    if drag notin {dkNone, dkPan}: cancelDrag()
    let mx = ui.pinchX.float
    let my = ui.pinchY.float
    let before = pageAt(mx - ui.panDX, my - ui.panDY)
    let nz = clamp(zoom() * ui.pinch / unitScale(), 0.05, 8.0) * unitScale()
    bd.page.zoom = nz / unitScale()
    bd.page.camX = before.x - (mx - view.x.float) / nz
    bd.page.camY = before.y - (my - view.y.float) / nz
    ui.redraw = true
  if not canInput(): return
  let over = view.contains(point(ui.mx, ui.my)) and not overBlocker()
  # the wheel zooms where the mouse is
  if ui.wheel != 0 and over and not ui.wheelUsed:
    ui.wheelUsed = true
    if ShiftPressed in ui.mods: bd.page.camX -= ui.wheel.float * 60 / zoom()
    elif AltPressed in ui.mods: bd.page.camY -= ui.wheel.float * 60 / zoom()
    else: zoomAt(ui.mx.float, ui.my.float, zoom() * pow(1.15, ui.wheel.float))
    ui.redraw = true
  # a right click: the menu
  if ui.rpressed and over and drag == dkNone:
    let p = mousePg()
    let hit = bd.topShapeAt(p.x, p.y, tolPg())
    if hit != 0 and hit notin sel: sel = @[hit]
    if hit == 0 and tool == tSelect and sel.len > 0:
      let f = selFrameNow()
      if not inside((p.x, p.y), @[f.framePoint(0, 0), f.framePoint(1, 0), f.framePoint(1, 1),
                                 f.framePoint(0, 1)]): sel = @[]
    openCanvasMenu(mouseScr())
    ui.rpressed = false
  if ui.pressed and over and not ui.pressUsed and not ui.gesturing:
    ui.pressUsed = true
    pressCanvas()
  elif ui.mouseDown and drag != dkNone:
    dragCanvas()
  if ui.released and drag != dkNone:
    releaseCanvas()
  # hover: what a click would take
  hoverId = 0
  if over and not ui.touch and not ui.mouseDown and tool == tSelect and editing == 0:
    let p = mousePg()
    hoverId = bd.topShapeAt(p.x, p.y, tolPg())
    let f = selFrameNow()
    let h = f.handleAt(mouseScr())
    if h != hNone: ui.cursor = cursorFor(h, f.rot)
  if over and not ui.touch:
    case tool
    of tHand: ui.cursor = curHand
    of tDraw, tHighlight, tGeo, tArrow, tLine, tFrame, tNote, tLaser, tEraser:
      ui.cursor = curCrosshair
    of tText: ui.cursor = curIbeam
    else: discard
    if spaceHeld or drag == dkPan: ui.cursor = curHand
    if drag == dkMove: ui.cursor = curMove

# ---- the canvas: drawing ----------------------------------------------------------------------

proc pictureOfShape(s: Shape): Bitmap =
  let n = int(hash(s.image))
  if s.id in pics and pics[s.id].n == n: return pics[s.id].b
  result = bd.pictureOf(s)
  if result != nil and max(result.w, result.h) > 1600: result = thumbnail(result, 1600, 1600)
  pics[s.id] = (n, result)

proc drawGrid() =
  var g = 20.0
  while g * zoom() < 14: g *= 4
  let c = if darkMode: Color(r: 52, g: 52, b: 58, a: 255) else: Color(r: 205, g: 208, b: 214, a: 255)
  let tl = pageAt(view.x.float, view.y.float)
  let br = pageAt(float(view.x + view.w), float(view.y + view.h))
  let d = max(1, dp(2) div 2 + 1)
  var gx = floor(tl.x / g) * g
  while gx <= br.x:
    var gy = floor(tl.y / g) * g
    let sx = int(scr(gx, 0).x) - d div 2
    while gy <= br.y:
      fill(rect(sx, int(scr(0, gy).y) - d div 2, d, d), c)
      gy += g
    gx += g

proc drawShape(s: Shape; fade: float) =
  let k = zoom()
  let ox = view.x.float - bd.page.camX * k
  let oy = view.y.float - bd.page.camY * k
  if s.kind == skImage and s.image.len > 0:
    let pic = pictureOfShape(s)
    let c = s.center
    let a = scr(c.x - s.w / 2, c.y - s.h / 2)
    let r = rect(int(a.x), int(a.y), max(1, int(s.w * k)), max(1, int(s.h * k)))
    if pic != nil: drawBitmap(r, pic)
    else: fill(r, Color(r: 128, g: 128, b: 128, a: 60))
    if fade < 1: fill(r, tint(paper(darkMode), 1 - fade))
    return
  for piece in bd.drawingOf(s).pieces:
    fillContours(piece.contours, tint(piece.color, fade), ox, oy, k)

proc outlinePg(s: Shape; c: Color; w = 1.5) =
  ## A shape's outline on the screen (hover, the arrows' target).
  case s.kind
  of skArrow: strokePg(bd.arrowPath(s).mapIt((it.x, it.y)), w, c)
  of skDraw, skHighlight, skLine:
    var pts: seq[P]
    for p in s.pts:
      let q = s.toPage(p.x.float, p.y.float)
      pts.add (q.x, q.y)
    if s.kind == skLine and s.spline: discard
    strokePg(pts, w, c)
  of skGroup:
    let b = bd.boundsOf(s)
    strokePg([(b.x, b.y), (b.x + b.w, b.y), (b.x + b.w, b.y + b.h), (b.x, b.y + b.h)], w, c, closed = true)
  else: strokePg(s.pageOutline.mapIt((it.x, it.y)), w, c, closed = true)

proc drawSelection() =
  if editing != 0:
    let s = bd.find(editing)
    if s != nil:
      outlinePg(s[], selBlue.withA(120))
      # the caret, blinking
      if (ui.now - caretSince) mod 1060 < 530:
        let (top, bottom) = bd.textCaret(s[], caret)
        strokePg([(top.x, top.y), (bottom.x, bottom.y)], max(1.5, 2.0 * min(1.0, zoom())),
                 tint(inkOf(if s.kind == skNote: bcBlack else: s.color, darkMode)))
    return
  if hoverId != 0 and hoverId notin sel and drag == dkNone:
    let s = bd.find(hoverId)
    if s != nil: outlinePg(s[], selBlue.withA(160))
  if bindTarget != 0:
    let s = bd.find(bindTarget)
    if s != nil: outlinePg(s[], selBlue, 2.5)
  if sel.len == 0 or drag in {dkInk, dkCreate} and creating == 0: return
  let f = selFrameNow()
  if not f.ok: return
  let k = singleKind()
  # each shape of several, outlined; the frame round them
  if sel.len > 1:
    for id in sel:
      let s = bd.find(id)
      if s != nil: outlinePg(s[], selBlue.withA(110), 1)
  if k notin {skArrow, skLine}:
    strokePg([f.framePoint(0, 0), f.framePoint(1, 0), f.framePoint(1, 1), f.framePoint(0, 1)], 1.25, selBlue,
             closed = true)
  if drag in {dkMove, dkRotate} or ui.gesturing: return
  if k in {skArrow, skLine}:
    if k == skArrow:
      let s = bd.find(sel[0])
      outlinePg(s[], selBlue.withA(110), 1)
    let ph = pointHandles()
    for i, q in ph: roundHandle(scr(q), selBlue, filled = k == skArrow and i == 2)
    for q in midHandles():
      let sp = scr(q)
      disc(sp.x, sp.y, handleR() - 1, selBlue.withA(110))
    return
  var locked = false
  for id in sel:
    let s = bd.find(id)
    if s != nil and s.locked: locked = true
  if locked: return
  for (h, p) in f.handles:
    if h == hRotate:
      let top = scr(f.framePoint(0.5, 0))
      let rp = scr(p)
      strokeScr([top, rp], 1, selBlue)
      roundHandle(rp, selBlue)
    else: squareHandle(scr(p), selBlue)

proc drawOverlays() =
  # the box being dragged out
  if drag == dkBrush and (brush.w > 0 or brush.h > 0):
    let a = scr(brush.x, brush.y)
    let b = scr(brush.x + brush.w, brush.y + brush.h)
    let r = rect(int(a.x), int(a.y), max(1, int(b.x - a.x)), max(1, int(b.y - a.y)))
    fill(r, selBlue.withA(30))
    box(r, selBlue.withA(160))
  for g in guides:
    strokePg([(g.x0, g.y0), (g.x1, g.y1)], 1, guideRed)
  # the eraser's trail, the laser's
  var keep: seq[(P, int)]
  for e in eraseTrail:
    if ui.now - e[1] < 200: keep.add e
  eraseTrail = keep
  if eraseTrail.len > 1: strokePg(eraseTrail.mapIt(it[0]), float(dp(4)), Color(r: 160, g: 160, b: 170, a: 120))
  keep.setLen(0)
  for e in laser:
    if ui.now - e[1] < 1400: keep.add e
  laser = keep
  if laser.len > 0:
    for i in 1 ..< laser.len:
      let age = float(ui.now - laser[i][1]) / 1400
      let a = int(255 * (1 - age))
      strokePg([laser[i - 1][0], laser[i][0]], float(dp(6)), Color(r: 255, g: 40, b: 40, a: uint8(clamp(a div 3, 0, 255))))
      strokePg([laser[i - 1][0], laser[i][0]], float(dp(2)), Color(r: 255, g: 90, b: 90, a: uint8(clamp(a, 0, 255))))
    let last = scr(laser[^1][0])
    disc(last.x, last.y, float(dp(4)), Color(r: 255, g: 40, b: 40, a: 220))
    wakeIn(16)
  if eraseTrail.len > 0: wakeIn(16)

proc drawCanvas() =
  if accessible():
    # (what a screen reader says of the board: a picture, and the words on it)
    var words: seq[string]
    for s in bd.page.shapes:
      if s.text.len > 0 and words.len < 50: words.add s.text.replace('\n', ' ')
    accessNode(arImage, "Board", id = 0, r = view,
               help = $bd.page.shapes.len & " shapes" & (if words.len > 0: ": " & words.join("; ") else: ""))
  pushClip(view)
  fill(view, tint(bd.paperOf))
  if showGrid: drawGrid()
  let tl = pageAt(view.x.float, view.y.float)
  let vis: Box = (tl.x - 50 / zoom(), tl.y - 50 / zoom(), view.w.float / zoom() + 100 / zoom(),
                  view.h.float / zoom() + 100 / zoom())
  for s in bd.page.shapes:
    if s.kind == skGroup: continue
    if not bd.boundsOf(s).overlaps(vis): continue
    let fade = if s.id in erasing or (s.parent != 0 and s.parent in erasing): 0.3 else: 1.0
    drawShape(s, fade)
  # (a shape with a link: a badge at its corner, a click opens it)
  for s in bd.page.shapes:
    if s.link.len == 0 or s.kind == skGroup: continue
    let c = linkBadge(s)
    disc(c.x, c.y, float(dp(9)), selBlue)
    disc(c.x, c.y, float(dp(8)), Color(r: 255, g: 255, b: 255, a: 255))
    drawGlyph(rect(int(c.x) - dp(9), int(c.y) - dp(9), dp(18), dp(18)), nfLink, 0.8)
  drawSelection()
  drawOverlays()
  popClip()

# ---- the floating bars ---------------------------------------------------------------------------

type BarLayout = object
  tools: seq[Tool]
  more, style: bool
  bar: Rect
  btn: int

proc barLayout(): BarLayout =
  ## Where the tool bar is, and what is on it.
  let compact = isCompact()
  result.tools = if compact: @[tSelect, tDraw, tEraser, tArrow, tText, tNote, tGeo]
                 else: @[tSelect, tHand, tDraw, tEraser, tArrow, tText, tNote, tGeo, tLine, tHighlight,
                         tLaser, tFrame]
  result.more = true
  result.style = false             # (the style: in the panels now)
  let n = result.tools.len + 1 + (if result.style: 1 else: 0)
  let want = if fingers(): dp(44) else: dp(34)
  result.btn = max(dp(26), min(want, (view.w - dp(16) - 6) div n))
  let w = n * result.btn + 6
  let h = result.btn + 6
  result.bar = rect(view.x + (view.w - w) div 2, view.y + view.h - h - dp(8), w, h)

proc morePanel(l: BarLayout): Rect =
  let b = l.btn
  let cols = min(8, max(4, (view.w - dp(16)) div b))
  let extra = [tHand, tLine, tHighlight, tLaser, tFrame]
  let n = extra.len + 1 + GeoKind.high.ord + 1
  let rows = (n + cols - 1) div cols
  let w = cols * b + 6
  let h = rows * b + 6
  rect(clamp(l.bar.x + l.bar.w - w, view.x + dp(4), view.x + view.w - w - dp(4)), l.bar.y - h - dp(6), w, h)

proc drawMore(l: BarLayout) =
  let r = morePanel(l)
  panel(r)
  let b = l.btn
  let cols = (r.w - 6) div b
  var i = 0
  proc cell(): Rect =
    result = rect(r.x + 3 + (i mod cols) * b, r.y + 3 + (i div cols) * b, b, b)
    inc i
  for t in [tHand, tLine, tHighlight, tLaser, tFrame]:
    if iconButton("more" & $t, cell(), tool == t, $t & " (" & toolKey[t] & ")", toolIcon[t]):
      setTool(t)
  if iconButton("moreimg", cell(), false, "Insert Picture...", icImage):
    moreOpen = false
    pictureDlg = true
  for g in GeoKind:
    if iconButton("geo" & $g, cell(), tool == tGeo and geoKind == g, capitalizeAscii(($g).replace("-", " ")),
                  icGeo, g):
      geoKind = g
      setTool(tGeo)

proc drawToolbar(l: BarLayout) =
  panel(l.bar)
  var x = l.bar.x + 3
  let y = l.bar.y + 3
  let b = l.btn
  for t in l.tools:
    let tip = if t == tGeo: capitalizeAscii(($geoKind).replace("-", " ")) & " (R)" else: $t & " (" & toolKey[t] & ")"
    if iconButton("tool" & $t, rect(x, y, b, b), tool == t, tip, toolIcon[t], geoKind):
      setTool(t)
    x += b
  if iconButton("more", rect(x, y, b, b), moreOpen, "More tools and shapes", icMore):
    moreOpen = not moreOpen

# the style panel: rows of buttons that wrap in its width

type Flow = object
  r: Rect
  x, y, cell, rowH: int
  measure: bool
  vis: Rect                        ## what of it is seen (the panel scrolls)

proc nextCell(f: var Flow; w = 0): Rect =
  let cw = if w > 0: w else: f.cell
  if f.x + cw > f.r.x + f.r.w - 4 and f.x > f.r.x + 4:
    f.x = f.r.x + 4
    f.y += f.rowH
  result = rect(f.x, f.y, cw, f.cell)
  f.x += cw
  f.rowH = f.cell

proc newRow(f: var Flow; gap = 4) =
  if f.x > f.r.x + 4:
    f.x = f.r.x + 4
    f.y += f.rowH + gap

proc heading(f: var Flow; title: string) =
  ## (a section's name, small, over its buttons)
  f.newRow()
  if not f.measure and f.y + FontH > f.vis.y and f.y < f.vis.y + f.vis.h:
    text(f.r.x + 5, f.y, title, th.gray)
  f.y += FontH + 1

proc fillIcon(r: Rect; fl: BoardFill; c: BoardColor) =
  let s = min(r.w, r.h) * 5 div 10
  let q = rect(r.x + (r.w - s) div 2, r.y + (r.h - s) div 2, s, s)
  case fl
  of bfNone: discard
  of bfSemi: fill(q, tint(semiOf(c, darkMode)))
  of bfSolid: fill(q, tint(inkOf(c, darkMode)))
  of bfPattern, bfCross, bfZigzag, bfDots:
    fill(q, tint(semiOf(c, darkMode)))
    var poly: seq[tuple[x, y: float]] = @[(q.x.float, q.y.float), (float(q.x + q.w), q.y.float),
                                          (float(q.x + q.w), float(q.y + q.h)), (q.x.float, float(q.y + q.h))]
    let sp = max(3.0, s.float / 4)
    fillContours(fillLines(poly, (if fl == bfPattern: bfPattern else: fl), sp, 1.0, false, 3),
                 tint(inkOf(c, darkMode)))
  box(q, th.text)

proc dashIcon(r: Rect; d: BoardDash) =
  let x0 = r.x.float + r.w.float * 0.2
  let x1 = r.x.float + r.w.float * 0.8
  let y = r.y.float + r.h.float / 2
  case d
  of bdDraw:
    var pts: seq[P]
    for i in 0 .. 12:
      let t = i.float / 12
      pts.add (x0 + (x1 - x0) * t, y + sin(t * PI * 2) * r.h.float * 0.08)
    strokeScr(pts, 2, th.text)
  of bdSolid: strokeScr([(x0, y), (x1, y)], 2, th.text)
  of bdDashed:
    let s = (x1 - x0) / 5
    for k in [0, 2, 4]: strokeScr([(x0 + k.float * s, y), (x0 + (k + 1).float * s, y)], 2, th.text)
  of bdDotted:
    for k in 0 .. 4: disc(x0 + k.float * (x1 - x0) / 4, y, 1.6, th.text)
  of bdSketch:
    # (two loose strokes, past their ends)
    strokeScr([(x0 - 2, y - 1.5), (x1 + 1, y - 0.5)], 1.3, th.text)
    strokeScr([(x0 + 1, y + 1.5), (x1 + 3, y + 0.8)], 1.3, th.text)

proc fontSample(r: Rect; f: BoardFont) =
  ## "Aa" in the board's font.
  var t = bd.textShape(0, 0, if f == bfnRuqaa: "خط" else: "Aa")
  t.id = -(100 + ord(f))
  t.font = f
  t.color = bcBlack
  t.size = bsS
  t.ver = 1
  t.fitText()
  let d = bd.drawingOf(t)
  var x0, y0 = 1e9
  var x1, y1 = -1e9
  for piece in d.pieces:
    for c in piece.contours:
      for p in c:
        x0 = min(x0, p[0]); x1 = max(x1, p[0]); y0 = min(y0, p[1]); y1 = max(y1, p[1])
  if x1 <= x0: return
  let k = min(r.w.float * 0.62 / (x1 - x0), r.h.float * 0.5 / (y1 - y0))
  let ox = r.x.float + (r.w.float - (x1 - x0) * k) / 2 - x0 * k
  let oy = r.y.float + (r.h.float - (y1 - y0) * k) / 2 - y0 * k
  for piece in d.pieces:
    fillContours(piece.contours, th.text, ox, oy, k)

proc headName(h: Arrowhead): string = capitalizeAscii($h)

proc slopIcon(r: Rect; level: int) =
  ## (a line drawn neatly, by a hand, wildly)
  let x0 = r.x.float + r.w.float * 0.18
  let x1 = r.x.float + r.w.float * 0.82
  let y = r.y.float + r.h.float / 2
  var pts: seq[P]
  for i in 0 .. 16:
    let t = i.float / 16
    let a = case level
            of -1: 0.0
            of 0: sin(t * PI * 2) * r.h.float * 0.07
            else: sin(t * PI * 5) * r.h.float * 0.14
    pts.add (x0 + (x1 - x0) * t, y + a)
  strokeScr(pts, 1.6, th.text)
  if level == 1: strokeScr(pts.mapIt((it.x + 1.5, it.y + 2.0)), 1.0, th.text)

proc edgeIcon(r: Rect; round: bool) =
  let s = min(r.w, r.h).float * 0.5
  let x0 = r.x.float + (r.w.float - s) / 2
  let y0 = r.y.float + (r.h.float - s) / 2
  if round:
    var pts: seq[P] = @[(x0, y0 + s)]
    for k in 0 .. 8:
      let a = PI + PI / 2 * k.float / 8
      pts.add (x0 + s * 0.5 + cos(a) * s * 0.5, y0 + s * 0.5 + sin(a) * s * 0.5)
    pts.add (x0 + s, y0)
    strokeScr(pts, 1.6, th.text)
  else:
    strokeScr([(x0, y0 + s), (x0, y0), (x0 + s, y0)], 1.6, th.text)

proc arrowKindIcon(r: Rect; kind: int) =
  ## (straight, curved, at right angles)
  let s = min(r.w, r.h).float * 0.56
  let x0 = r.x.float + (r.w.float - s) / 2
  let y0 = r.y.float + (r.h.float - s) / 2
  var pts: seq[P]
  case kind
  of 0: pts = @[(x0, y0 + s), (x0 + s, y0)]
  of 1:
    for i in 0 .. 12:
      let t = i.float / 12
      let u = 1 - t
      pts.add (u * u * x0 + 2 * u * t * (x0 + s * 0.05) + t * t * (x0 + s), u * u * (y0 + s) + 2 * u * t * y0 + t * t * y0)
  else: pts = @[(x0, y0 + s), (x0 + s * 0.5, y0 + s), (x0 + s * 0.5, y0), (x0 + s, y0)]
  strokeScr(pts, 1.6, th.text)
  let e = pts[^1]
  let d = pts[^2]
  let l = max(1e-6, hypot(e.x - d.x, e.y - d.y))
  let ux = (e.x - d.x) / l
  let uy = (e.y - d.y) / l
  strokeScr([(e.x - ux * 5 - uy * 4, e.y - uy * 5 + ux * 4), e, (e.x - ux * 5 + uy * 4, e.y - uy * 5 - ux * 4)],
            1.6, th.text)

proc valignIcon(r: Rect; al: BoardAlign) =
  let s = min(r.w, r.h).float * 0.56
  let x0 = r.x.float + (r.w.float - s) / 2
  let y0 = r.y.float + (r.h.float - s) / 2
  strokeScr([(x0, y0), (x0 + s, y0), (x0 + s, y0 + s), (x0, y0 + s)], 1.0, th.gray, closed = true)
  let y = case al
          of baStart: y0 + s * 0.22
          of baEnd: y0 + s * 0.78
          else: y0 + s / 2
  strokeScr([(x0 + s * 0.2, y), (x0 + s * 0.8, y)], 2.2, th.text)

proc layerIcon(r: Rect; how: string) =
  ## (an arrow down or up; to the very back or front: with a bar)
  let s = min(r.w, r.h).float * 0.5
  let cx = r.x.float + r.w.float / 2
  let y0 = r.y.float + (r.h.float - s) / 2
  let down = how in ["back", "backward"]
  let (a, b) = if down: (y0, y0 + s) else: (y0 + s, y0)
  strokeScr([(cx, a), (cx, b)], 1.6, th.text)
  let d = if down: -1.0 else: 1.0
  strokeScr([(cx - s * 0.3, b + d * s * 0.3), (cx, b), (cx + s * 0.3, b + d * s * 0.3)], 1.6, th.text)
  if how in ["back", "front"]: strokeScr([(cx - s * 0.4, b - d * 2.5), (cx + s * 0.4, b - d * 2.5)], 1.6, th.text)

proc alignIcon(r: Rect; how: string) =
  let s = min(r.w, r.h).float * 0.6
  let x0 = r.x.float + (r.w.float - s) / 2
  let y0 = r.y.float + (r.h.float - s) / 2
  let c = th.text
  case how
  of "left", "center", "right":
    let lx = case how
             of "left": x0
             of "right": x0 + s
             else: x0 + s / 2
    strokeScr([(lx, y0), (lx, y0 + s)], 1.0, c)
    for (w, y) in [(s * 0.8, y0 + s * 0.28), (s * 0.5, y0 + s * 0.72)]:
      let bx = case how
               of "left": x0 + 2
               of "right": x0 + s - 2 - w
               else: x0 + (s - w) / 2
      strokeScr([(bx, y), (bx + w, y)], 3.0, c)
  of "top", "middle", "bottom":
    let ly = case how
             of "top": y0
             of "bottom": y0 + s
             else: y0 + s / 2
    strokeScr([(x0, ly), (x0 + s, ly)], 1.0, c)
    for (h, x) in [(s * 0.8, x0 + s * 0.28), (s * 0.5, x0 + s * 0.72)]:
      let by = case how
               of "top": y0 + 2
               of "bottom": y0 + s - 2 - h
               else: y0 + (s - h) / 2
      strokeScr([(x, by), (x, by + h)], 3.0, c)
  of "hspread":
    for k in 0 .. 2: strokeScr([(x0 + s * 0.1 + k.float * s * 0.4, y0 + 2), (x0 + s * 0.1 + k.float * s * 0.4, y0 + s - 2)], 3.0, c)
  else:
    for k in 0 .. 2: strokeScr([(x0 + 2, y0 + s * 0.1 + k.float * s * 0.4), (x0 + s - 2, y0 + s * 0.1 + k.float * s * 0.4)], 3.0, c)

var
  linkDlg = false
  linkText = ""

proc nextStep(dx, dy: int) =
  ## A flowchart's next step from the shape selected: a shape like it, and
  ## an arrow to it.
  if sel.len != 1: return
  finishEdit()
  var n: tuple[shape, arrow: int]
  bd.change("Next Step"): n = bd.addConnected(sel[0], dx, dy)
  if n.shape != 0:
    sel = @[n.shape]
    let s = bd.find(n.shape)
    # (where it is seen)
    let p = scr(s.x + s.w / 2, s.y + s.h / 2)
    if not view.contains(point(int(p.x), int(p.y))): zoomToBox(bd.boundsOf(s[]), bd.page.zoom)

template cell(f: var Flow; key: string; down: bool; tip: string; w = 0): (bool, Rect) =
  ## (a button of a panel's flow: its click, where its picture goes)
  let r = f.nextCell(w)
  if f.measure or r.y + r.h <= f.vis.y or r.y >= f.vis.y + f.vis.h: (false, r)
  else:
    let (c, ir) = paintButton(key, r, down, tip)
    (c, ir)

proc swatch(r: Rect; c: uint32) =
  let q = inset(r, max(3, r.w div 5))
  fill(q, tint(c))
  box(q, th.text)

proc headIcon(r: Rect; h: Arrowhead; atStart = false) =
  ## (a short line and its arrowhead: at its right end -- at its left, for
  ## the start of an arrow)
  let cx = r.x.float + r.w.float / 2
  template X(v: float): float = (if atStart: 2 * cx - v else: v)
  let x0 = r.x.float + r.w.float * 0.18
  let x1 = r.x.float + r.w.float * 0.8
  let y = r.y.float + r.h.float / 2
  let s = r.h.float * 0.16
  strokeScr([(X(x0), y), (X(x1 - (if h in {ahTriangle, ahDiamond, ahSquare, ahDot}: s else: 0.0)), y)], 1.6, th.text)
  case h
  of ahNone: discard
  of ahArrow: strokeScr([(X(x1 - s * 1.4), y - s), (X(x1), y), (X(x1 - s * 1.4), y + s)], 1.6, th.text)
  of ahTriangle: polygon([(X(x1), y), (X(x1 - s * 1.6), y - s), (X(x1 - s * 1.6), y + s)], th.text)
  of ahDot: disc(X(x1 - s * 0.6), y, s * 0.75, th.text)
  of ahDiamond: polygon([(X(x1), y), (X(x1 - s), y - s * 0.8), (X(x1 - 2 * s), y), (X(x1 - s), y + s * 0.8)], th.text)
  of ahSquare:
    let sx = min(X(x1), X(x1 - s * 1.4))
    fill(rect(int(sx), int(y - s * 0.7), int(s * 1.4), int(s * 1.4)), th.text)
  of ahBar: strokeScr([(X(x1), y - s), (X(x1), y + s)], 1.8, th.text)

proc flipIcon(r: Rect; across: bool) =
  let s = min(r.w, r.h).float * 0.28
  let cx = r.x.float + r.w.float / 2
  let cy = r.y.float + r.h.float / 2
  if across:
    polygon([(cx - 2, cy - s), (cx - 2, cy + s), (cx - 2 - s * 1.3, cy + s)], th.text)
    strokeScr([(cx + 2, cy - s), (cx + 2, cy + s), (cx + 2 + s * 1.3, cy + s)], 1.2, th.text, closed = true)
  else:
    polygon([(cx - s, cy - 2), (cx + s, cy - 2), (cx + s, cy - 2 - s * 1.3)], th.text)
    strokeScr([(cx - s, cy + 2), (cx + s, cy + 2), (cx + s, cy + 2 + s * 1.3)], 1.2, th.text, closed = true)

proc panelCell(): int = (if fingers(): dp(40) else: dp(30))

proc flowPanel(section: proc (f: var Flow)) =
  ## (a panel's buttons, laid out in its room: measured, then drawn)
  let w = max(dp(80), available())
  var m = Flow(r: rect(0, 0, w, 100000), x: 4, y: 0, cell: panelCell(), rowH: panelCell(), measure: true)
  section(m)
  m.newRow(0)
  let r = place(w, max(1, m.y + 2), fill = true)
  var f = Flow(r: r, x: r.x + 4, y: r.y, cell: panelCell(), rowH: panelCell(), vis: clipRect())
  section(f)

# ---- the panels: Color, Stroke, Fill | Text, Arrow, Shapes | Arrange, Board, Info -----------------

proc colorSection(f: var Flow) =
  let W = f.r.w - 8
  f.heading("Stroke")
  for c in BoardColor:
    if c == bcWhite: continue
    let (clicked, r) = f.cell("col" & $c, cur.color == c, capitalizeAscii(($c).replace("-", " ")), W div 6)
    if not f.measure: disc(r.x.float + r.w / 2, r.y.float + r.h / 2, min(r.w, r.h).float * 0.32, tint(inkOf(c, darkMode)))
    if clicked:
      cur.color = c
      let cc = c
      restyle("Color", proc (s: var Shape) = s.color = cc)
  f.heading("Background")
  let (same, rs) = f.cell("bgsame", cur.fillColor == 0, "The stroke's color", W div 6)
  if not f.measure: text(rs.x + (rs.w - textWidth("=")) div 2, rs.y + (rs.h - FontH) div 2, "=", th.text)
  if same:
    cur.fillColor = 0
    restyle("Background", proc (s: var Shape) = (if s.kind in {skGeo, skDraw}: s.fillColor = 0))
  for c in BoardColor:
    if c in {bcBlack, bcWhite}: continue
    let (clicked, r) = f.cell("bg" & $c, cur.fillColor == ord(c) + 1,
                              "Background: " & capitalizeAscii(($c).replace("-", " ")), W div 6)
    if not f.measure: swatch(r, semiOf(c, darkMode))
    if clicked:
      cur.fillColor = ord(c) + 1
      if cur.fill == bfNone: cur.fill = bfSemi
      let v = cur.fillColor
      let fl = cur.fill
      restyle("Background", proc (s: var Shape) =
        if s.kind in {skGeo, skDraw}:
          s.fillColor = v
          if s.fill == bfNone: s.fill = fl)
  f.heading("Opacity")
  for i, o in opacities:
    let (clicked, r) = f.cell("op" & $i, abs(cur.opacity - o) < 0.01, "Opacity " & $int(o * 100) & "%",
                              W div opacities.len)
    if not f.measure:
      disc(r.x.float + r.w / 2, r.y.float + r.h / 2, min(r.w, r.h).float * 0.28, tint(inkOf(cur.color, darkMode), o))
    if clicked:
      cur.opacity = o
      restyle("Opacity", proc (s: var Shape) = s.opacity = o)

proc strokeSection(f: var Flow) =
  let W = f.r.w - 8
  f.heading("Stroke style")
  for d in BoardDash:
    let (clicked, r) = f.cell("dash" & $d, cur.dash == d, "Line: " & capitalizeAscii($d), W div 5)
    if not f.measure: dashIcon(r, d)
    if clicked:
      cur.dash = d
      restyle("Stroke Style", proc (s: var Shape) = (if s.kind in {skGeo, skDraw, skArrow, skLine}: s.dash = d))
  f.heading("Stroke width and size")
  for z in BoardSize:
    let (clicked, r) = f.cell("size" & $z, cur.size == z, "Size " & toUpperAscii($z), W div 4)
    if not f.measure:
      let lbl = toUpperAscii($z)
      text(r.x + (r.w - textWidth(lbl)) div 2, r.y + (r.h - FontH) div 2, lbl, th.text)
    if clicked:
      cur.size = z
      restyle("Size", proc (s: var Shape) =
        s.scale = 1                    # (the size chosen: its letters as that size has them)
        s.size = z)
  f.heading("Sloppiness")
  for (lv, name) in [(-1, "Architect"), (0, "Artist"), (1, "Cartoonist")]:
    let (clicked, r) = f.cell("slop" & $lv, cur.roughness == lv, "Sloppiness: " & name, W div 3)
    if not f.measure: slopIcon(r, lv)
    if clicked:
      cur.roughness = lv
      restyle("Sloppiness", proc (s: var Shape) = (if s.kind in {skGeo, skArrow, skLine}: s.roughness = lv))
  f.heading("Edges")
  for (rd, name) in [(false, "Sharp"), (true, "Round")]:
    let (clicked, r) = f.cell("edge" & $rd, cur.round == rd, "Edges: " & name, W div 2)
    if not f.measure: edgeIcon(r, rd)
    if clicked:
      cur.round = rd
      restyle("Edges", proc (s: var Shape) = (if s.kind in {skGeo, skFrame, skImage}: s.round = rd))

proc fillSection(f: var Flow) =
  let W = f.r.w - 8
  f.heading("Fill")
  for fl in BoardFill:
    let (clicked, r) = f.cell("fill" & $fl, cur.fill == fl,
                              "Fill: " & (if fl == bfPattern: "Hachure" else: capitalizeAscii($fl)), W div 4)
    if not f.measure: fillIcon(r, fl, (if cur.fillColor > 0: BoardColor(cur.fillColor - 1) else: cur.color))
    if clicked:
      cur.fill = fl
      restyle("Fill", proc (s: var Shape) = (if s.kind in {skGeo, skDraw}: s.fill = fl))
  f.heading("Background")
  let (same, rs) = f.cell("fbgsame", cur.fillColor == 0, "The stroke's color", W div 6)
  if not f.measure: text(rs.x + (rs.w - textWidth("=")) div 2, rs.y + (rs.h - FontH) div 2, "=", th.text)
  if same:
    cur.fillColor = 0
    restyle("Background", proc (s: var Shape) = (if s.kind in {skGeo, skDraw}: s.fillColor = 0))
  for c in BoardColor:
    if c in {bcBlack, bcWhite}: continue
    let (clicked, r) = f.cell("fbg" & $c, cur.fillColor == ord(c) + 1,
                              "Fill color: " & capitalizeAscii(($c).replace("-", " ")), W div 6)
    if not f.measure: swatch(r, semiOf(c, darkMode))
    if clicked:
      cur.fillColor = ord(c) + 1
      let v = cur.fillColor
      restyle("Background", proc (s: var Shape) = (if s.kind in {skGeo, skDraw}: s.fillColor = v))

proc textSection(f: var Flow) =
  let W = f.r.w - 8
  f.heading("Font")
  for fn in BoardFont:
    let (clicked, r) = f.cell("font" & $fn, cur.font == fn, "Font: " & fontNames[fn], W div 5)
    if not f.measure: fontSample(r, fn)
    if clicked:
      cur.font = fn
      restyle("Font", proc (s: var Shape) = s.font = fn)
  f.heading("Size")
  for z in BoardSize:
    let (clicked, r) = f.cell("tsize" & $z, cur.size == z, "Size " & toUpperAscii($z), W div 4)
    if not f.measure:
      let lbl = toUpperAscii($z)
      text(r.x + (r.w - textWidth(lbl)) div 2, r.y + (r.h - FontH) div 2, lbl, th.text)
    if clicked:
      cur.size = z
      restyle("Size", proc (s: var Shape) =
        s.scale = 1                    # (the size chosen: its letters as that size has them)
        s.size = z)
  f.heading("Align")
  for (al, g) in [(baStart, nfAlignLeft), (baMiddle, nfAlignCenter), (baEnd, nfAlignRight)]:
    let down = if singleKind() == skText: cur.textAlign == al else: cur.align == al
    let (clicked, r) = f.cell("al" & $al, down, "Align " & (case al
                                                           of baStart: "left"
                                                           of baMiddle: "center"
                                                           else: "right"), W div 6)
    if not f.measure: drawGlyph(r, g, 1.0)
    if clicked:
      cur.textAlign = al
      cur.align = al
      restyle("Align Text", proc (s: var Shape) = s.align = al)
  for al in [baStart, baMiddle, baEnd]:
    let (clicked, r) = f.cell("va" & $al, cur.valign == al, "In a shape or a note: at the " & (case al
                                                                                         of baStart: "top"
                                                                                         of baMiddle: "middle"
                                                                                         else: "bottom"), W div 6)
    if not f.measure: valignIcon(r, al)
    if clicked:
      cur.valign = al
      restyle("Align Text", proc (s: var Shape) = (if s.kind in {skGeo, skNote}: s.valign = al))

proc arrowSection(f: var Flow) =
  let W = f.r.w - 8
  f.heading("Arrow type")
  let curved = sel.len == 1 and singleKind() == skArrow and abs(bd.find(sel[0]).bend) > 0.5
  for (k, name) in [(0, "Straight"), (1, "Curved"), (2, "Elbow")]:
    let down = case k
               of 2: cur.elbow
               of 1: not cur.elbow and curved
               else: not cur.elbow and not curved
    let (clicked, r) = f.cell("akind" & $k, down, "Arrow: " & name, W div 3)
    if not f.measure: arrowKindIcon(r, k)
    if clicked:
      cur.elbow = k == 2
      let kk = k
      var lens: Table[int, float]
      for id in sel:
        let a = bd.find(id)
        if a != nil and a.kind == skArrow:
          let (p0, p1) = bd.arrowEnds(a[])
          lens[id] = hypot(p1.x - p0.x, p1.y - p0.y)
      restyle("Arrow Type", proc (s: var Shape) =
        if s.kind == skArrow:
          s.elbow = kk == 2
          if kk == 1 and abs(s.bend) < 0.5: s.bend = lens.getOrDefault(s.id, 100.0) * 0.2
          if kk != 1: s.bend = 0)
  for which in 0 .. 1:
    f.heading(if which == 0: "Arrowhead at the start" else: "Arrowhead at the end")
    for h in Arrowhead:
      let now = if which == 0: cur.head0 else: cur.head1
      let (clicked, r) = f.cell("hd" & $which & $h, now == h, headName(h), W div 7)
      if not f.measure: headIcon(r, h, atStart = which == 0)
      if clicked:
        if which == 0: cur.head0 = h else: cur.head1 = h
        let w = which
        let hh = h
        restyle("Arrowhead", proc (s: var Shape) =
          if s.kind == skArrow:
            if w == 0: s.head0 = hh else: s.head1 = hh)
  f.heading("Lines")
  for (sp, name) in [(false, "Straight"), (true, "Curved")]:
    let (clicked, r) = f.cell("spline" & $sp, cur.spline == sp, "A line through its points: " & name, W div 2)
    if not f.measure: text(r.x + (r.w - textWidth(name)) div 2, r.y + (r.h - FontH) div 2, name, th.text)
    if clicked:
      cur.spline = sp
      restyle("Line", proc (s: var Shape) = (if s.kind == skLine: s.spline = sp))

proc shapeSection(f: var Flow) =
  let W = f.r.w - 8
  f.heading(if sel.len > 0 and singleKind() == skGeo: "Change the shape" else: "Shape to draw")
  for g in GeoKind:
    let shown = if sel.len == 1 and singleKind() == skGeo: bd.find(sel[0]).geo else: geoKind
    let (clicked, r) = f.cell("pg" & $g, shown == g, capitalizeAscii(($g).replace("-", " ")), W div 6)
    if not f.measure: drawIcon(icGeo, r, th.text, g)
    if clicked:
      geoKind = g
      var any = false
      for id in bd.members(sel):
        let s = bd.find(id)
        if s != nil and s.kind == skGeo: any = true
      if any: restyle("Shape", proc (s: var Shape) = (if s.kind == skGeo: s.geo = g))
      else: setTool(tGeo)

proc openPosition()
proc freeMemory()

proc arrangeSection(f: var Flow) =
  let W = f.r.w - 8
  let some = sel.len > 0
  f.heading("Layers")
  for (how, name) in [("back", "Send to back"), ("backward", "Send backward"), ("forward", "Bring forward"),
                      ("front", "Bring to front")]:
    let (clicked, r) = f.cell("layer" & how, false, name, W div 4)
    if not f.measure: layerIcon(r, how)
    if clicked and some: arrange(how)
  f.heading("Align")
  for how in ["left", "center", "right", "top", "middle", "bottom"]:
    let (clicked, r) = f.cell("align" & how, false, "Align " & how & " (two or more)", W div 6)
    if not f.measure: alignIcon(r, how)
    if clicked and sel.len > 1:
      let h = how
      bd.change("Align"): bd.alignShapes(sel, h)
  for (hz, name) in [(true, "Distribute across (three or more)"), (false, "Distribute down (three or more)")]:
    let (clicked, r) = f.cell("spread" & $hz, false, name, W div 4)
    if not f.measure: alignIcon(r, if hz: "hspread" else: "vspread")
    if clicked and sel.len > 2:
      bd.change("Distribute"): bd.distribute(sel, hz)
  for (hz, name) in [(true, "Flip across (Shift+H)"), (false, "Flip upside down (Shift+V)")]:
    let (clicked, r) = f.cell("flip" & $hz, false, name, W div 4)
    if not f.measure: flipIcon(r, hz)
    if clicked and some:
      bd.change("Flip"): bd.flipShapes(sel, hz)
  f.heading("Actions")
  let one = sel.len == 1
  let canNext = one and singleKind() in {skGeo, skNote, skText, skImage}
  let isGroup = one and singleKind() == skGroup
  for (key, glyph, tip, ok) in [("dup", nfCopy, "Duplicate (Ctrl+D)", some), ("del", nfTrash, "Delete (Del)", some),
                                ("link", nfLink, "Link... (Ctrl+K)", one),
                                ("group", (if isGroup: nfCube else: nfCubes),
                                 (if isGroup: "Ungroup (Ctrl+Shift+G)" else: "Group (Ctrl+G)"), sel.len > 1 or isGroup),
                                ("lock", nfLock, "Lock (Ctrl+Shift+L)", some),
                                ("nextr", nfArrowRight, "Next step to the right (Ctrl+Right)", canNext),
                                ("nextd", nfArrowDown, "Next step below (Ctrl+Down)", canNext)]:
    let r = f.nextCell(W div 7)
    if f.measure or r.y + r.h <= f.vis.y or r.y >= f.vis.y + f.vis.h: continue
    let clicked = buttonAt("act" & key, r, "", glyph, blIconOnly, enabled = ok)
    tooltip(tip)
    if clicked:
      case key
      of "dup": duplicateSel()
      of "del": deleteSel()
      of "link":
        linkText = bd.find(sel[0]).link
        linkDlg = true
      of "group":
        if isGroup: ungroupSel() else: groupSel()
      of "lock": lockSel(true)
      of "nextr": nextStep(1, 0)
      of "nextd": nextStep(0, 1)
      else: discard
  f.newRow()
  let r = f.nextCell(W)
  if not f.measure and r.y + r.h > f.vis.y and r.y < f.vis.y + f.vis.h:
    if buttonAt("posdlg", r, "Position and Size...", enabled = one and singleKind() notin {skArrow, skGroup}):
      openPosition()

proc boardPanel() =
  ## The Board panel: its pages, the canvas.
  label "Pages", bold = true
  var names: seq[string]
  for p in bd.pages: names.add p.name
  var at = bd.cur
  if listbox(names, at, rows = clamp(names.len, 2, 5)):
    finishEdit()
    bd.cur = clamp(at, 0, bd.pages.high)
    sel = @[]
  row:
    if button("&New", w = dp(54)):
      finishEdit()
      bd.pages.add bd.newPage("Page " & $(bd.pages.len + 1))
      bd.cur = bd.pages.high
      sel = @[]
      bd.modified = true
      inc bd.ver
    if button("Rename", w = dp(64)):
      renameText = bd.page.name
      renameDlg = true
    if button("Delete", w = dp(58), enabled = bd.pages.len > 1):
      finishEdit()
      bd.pages.delete(bd.cur)
      bd.cur = clamp(bd.cur, 0, bd.pages.high)
      bd.clearHistory()
      sel = @[]
      bd.modified = true
      inc bd.ver
  space 4
  flowPanel(proc (f: var Flow) =
    let W = f.r.w - 8
    f.heading("Canvas")
    for i, pc in paperColors:
      let (clicked, r) = f.cell("paper" & $i, bd.paper == i, "Canvas: " & pc.name, W div paperColors.len)
      if not f.measure: swatch(r, if darkMode: pc.dark else: pc.light)
      if clicked:
        bd.paper = i
        bd.forgetDrawings()
        bd.modified = true
        inc bd.ver)
  if checkbox("Grid", showGrid): saveSettingsNow()
  if checkbox("Snap to shapes", snapOn): saveSettingsNow()
  var dk = darkMode
  if checkbox("Dark canvas", dk):
    darkMode = dk
    applyDark()
    saveSettingsNow()
  var sk = cur.dash == bdSketch
  if checkbox("Sketch style for new shapes", sk):
    cur.dash = if sk: bdSketch else: bdDraw
    saveSettingsNow()
  if checkbox("Tool lock", toolLock): saveSettingsNow()

proc infoPanel() =
  ## The Info panel: the board, the selection, the memory.
  var kinds: array[ShapeKind, int]
  for s in bd.page.shapes: inc kinds[s.kind]
  var picBytes = 0
  for k, v in bd.assets: picBytes += v.len
  proc mbs(n: int): string = formatFloat(n.float / (1024 * 1024), ffDecimal, 1) & " MB"
  label "This page", bold = true
  paragraph $kinds[skGeo] & " shapes, " & $kinds[skArrow] & " arrows, " & $(kinds[skDraw] + kinds[skHighlight]) &
            " drawings, " & $(kinds[skText] + kinds[skNote]) & " texts and notes, " & $kinds[skImage] & " pictures"
  if sel.len > 0:
    let b = bd.selectionBounds(sel)
    label "Selection", bold = true
    paragraph $sel.len & " -- x " & $int(b.x) & ", y " & $int(b.y) & ", " & $int(b.w) & " x " & $int(b.h)
  label "Memory", bold = true
  let mem = memoryNumbers()
  paragraph "The program: " & mbs(int(mem.program))
  paragraph "Drawings kept " & mbs(bd.drawingBytes) & ", steps to undo " & mbs(bd.historyBytes) & ", pictures " &
            mbs(picBytes)
  if mem.device > 0: paragraph "Free on the device: " & mbs(int(mem.free))
  if button("&Free Memory"): freeMemory()

const panelList = [("color", "Color", nfPalette), ("stroke", "Stroke", nfPencil), ("fill", "Fill", nfPaintBrush),
                   ("text", "Text", nfFont), ("arrow", "Arrow", nfArrowRight), ("shape", "Shapes", nfCube),
                   ("arrange", "Arrange", nfThLarge), ("board", "Board", nfFiles), ("info", "Info", nfInfo)]

proc panelDef(key: string): DockPanel =
  for (k, t, ic) in panelList:
    if k == key: return dockPanel(k, t, ic)
  dockPanel(key, key)

proc defaultDock(iconic: bool) =
  ## The panels in three groups of tabs, as Retro Photo has them: how it
  ## looks (Color, Stroke, Fill), what it is (Text, Arrow, Shapes), where it
  ## goes (Arrange, Board, Info). On a phone, a strip of icons.
  dock = newDock()
  discard dock.addColumn(iconic = iconic)
  discard dock.addGroup(0, [panelDef("color"), panelDef("stroke"), panelDef("fill")], share = 35)
  discard dock.addGroup(0, [panelDef("text"), panelDef("arrow"), panelDef("shape")], share = 29)
  discard dock.addGroup(0, [panelDef("arrange"), panelDef("board"), panelDef("info")], share = 36)
  dockCompact = iconic

proc panelBody(key: string) =
  case key
  of "color": flowPanel(colorSection)
  of "stroke": flowPanel(strokeSection)
  of "fill": flowPanel(fillSection)
  of "text": flowPanel(textSection)
  of "arrow": flowPanel(arrowSection)
  of "shape": flowPanel(shapeSection)
  of "arrange": flowPanel(arrangeSection)
  of "board": boardPanel()
  of "info": infoPanel()
  else: discard

proc panelMenu(key: string) =
  if menuItem("&Reset Panels"):
    defaultDock(isCompact())
    saveSettingsNow()

proc restoreDock() =
  ## The panels as they were left (else as they come), then laid out for
  ## the screen: on a phone, a strip of icons.
  let s = loadSettings(AppName)
  panelsHidden = s.get("panelsHidden", "false") == "true"
  defaultDock(isCompact())
  var j: JsonNode = nil
  try: j = parseJson(s.get("dock", ""))
  except CatchableError: discard
  var d = newDock()
  if d.loadDock(j):
    # (panels this version has that the saved layout does not: as they come)
    var missing = false
    for (k, t, ic) in panelList:
      if not d.hasPanel(k):
        var wasClosed = false
        for c in d.closed:
          if c.p.key == k: wasClosed = true
        if not wasClosed: missing = true
    if not missing:
      dock = d
      dockCompact = s.get("dockCompact", "false") == "true"

proc fitDock() =
  ## (a phone turned into a tablet's width, or back: the columns opened or
  ## folded to icons)
  let c = isCompact()
  if c != dockCompact:
    for col in dock.columns: col.iconic = c
    dockCompact = c

proc topLeftRect(): Rect =
  let b = if fingers(): dp(40) else: dp(30)
  rect(view.x + dp(8), view.y + dp(8), 4 * b + 6 + max(dp(90), textWidth(bd.page.name) + dp(30)), b + 6)

proc drawTopLeft() =
  let r = topLeftRect()
  panel(r)
  let b = r.h - 6
  var x = r.x + 3
  let y = r.y + 3
  let pr = rect(x, y, r.w - 6 - 4 * b, b)
  let (clicked, _) = paintButton("pages", pr, popupMenuOpen("pages"), "Pages")
  text(pr.x + 6, pr.y + (pr.h - FontH) div 2, bd.page.name & "  ▾", th.text)
  if clicked: openPopupMenu("pages", pr.x, pr.y + pr.h)
  x += pr.w
  if iconButton("undo", rect(x, y, b, b), false, "Undo " & bd.undoName & " (Ctrl+Z)", icUndo,
                enabled = bd.canUndo):
    finishEdit()
    bd.undo()
    cleanSel()
  x += b
  if iconButton("redo", rect(x, y, b, b), false, "Redo " & bd.redoName & " (Ctrl+Y)", icRedo,
                enabled = bd.canRedo):
    finishEdit()
    bd.redo()
    cleanSel()
  x += b
  if iconButton("dup", rect(x, y, b, b), false, "Duplicate (Ctrl+D)", icDuplicate, enabled = sel.len > 0):
    duplicateSel()
  x += b
  if iconButton("del", rect(x, y, b, b), false, "Delete (Del)", icDelete, enabled = sel.len > 0):
    deleteSel()

proc zoomRect(): Rect =
  let b = if fingers(): dp(40) else: dp(28)
  let w = 2 * b + max(dp(56), textWidth("800%") + dp(16)) + 6
  if isCompact():
    let tl = topLeftRect()
    if tl.x + tl.w + w + dp(16) <= view.x + view.w:
      return rect(view.x + view.w - w - dp(8), view.y + dp(8), w, b + 6)
    return rect(view.x + view.w - w - dp(8), tl.y + tl.h + dp(6), w, b + 6)
  let l = barLayout()
  rect(view.x + dp(8), l.bar.y + l.bar.h - b - 6, w, b + 6)

proc drawZoom() =
  let r = zoomRect()
  panel(r)
  let b = r.h - 6
  let y = r.y + 3
  if buttonAt("zoomout", rect(r.x + 3, y, b, b), "-"): zoomSteps(false)
  let mid = rect(r.x + 3 + b, y, r.w - 6 - 2 * b, b)
  let (clicked, _) = paintButton("zoommenu", mid, popupMenuOpen("zoom"), "Zoom")
  let lbl = $int(round(bd.page.zoom * 100)) & "%"
  text(mid.x + (mid.w - textWidth(lbl)) div 2, mid.y + (mid.h - FontH) div 2, lbl, th.text)
  if clicked: openPopupMenu("zoom", mid.x, mid.y - dp(160))
  if buttonAt("zoomin", rect(r.x + r.w - 3 - b, y, b, b), "+"): zoomSteps(true)

# ---- menus -------------------------------------------------------------------------------------

proc canvasMenu() =
  popupMenu("boardmenu"):
    let one = sel.len == 1
    if one and bd.find(sel[0]) != nil and bd.find(sel[0])[].hasText:
      if menuItem("Edit &Text", "Enter"): startEdit(sel[0])
      menuSeparator()
    if menuItem("Cu&t", "Ctrl+X", enabled = sel.len > 0):
      copySel()
      deleteSel()
    if menuItem("&Copy", "Ctrl+C", enabled = sel.len > 0): copySel()
    if menuItem("&Paste", "Ctrl+V"): pasteAt(dragFromPg)
    if menuItem("&Duplicate", "Ctrl+D", enabled = sel.len > 0): duplicateSel()
    if menuItem("De&lete", "Del", enabled = sel.len > 0): deleteSel()
    if one and singleKind() in {skGeo, skNote, skText, skImage}:
      if menuItem("&Next Step Right", "Ctrl+Right"): nextStep(1, 0)
      if menuItem("Next Step &Below", "Ctrl+Down"): nextStep(0, 1)
    if menuItem("Lin&k...", "Ctrl+K", enabled = one):
      linkText = bd.find(sel[0]).link
      linkDlg = true
    menuSeparator()
    if menuItem("Bring to &Front", "Ctrl+]", enabled = sel.len > 0): arrange("front")
    if menuItem("Send to &Back", "Ctrl+[", enabled = sel.len > 0): arrange("back")
    if menuItem("&Group", "Ctrl+G", enabled = sel.len > 1): groupSel()
    if menuItem("&Ungroup", "Ctrl+Shift+G", enabled = one and singleKind() == skGroup): ungroupSel()
    if menuItem("Loc&k", "Ctrl+Shift+L", enabled = sel.len > 0): lockSel(true)
    menuSeparator()
    if menuItem("Select &All", "Ctrl+A"): selectAll()
    if menuItem("&Export Selection...", enabled = sel.len > 0):
      exportWhat = 1
      exportDlg = true
    if menuItem("&Zoom to Fit", "Shift+1"): zoomToFit()
  for which in 0 .. 1:
    popupMenu("head" & $which):
      for h in Arrowhead:
        if menuItem(headName(h), checked = (if which == 0: cur.head0 else: cur.head1) == h):
          if which == 0: cur.head0 = h else: cur.head1 = h
          let w = which
          restyle("Arrowhead", proc (s: var Shape) =
            if s.kind == skArrow:
              if w == 0: s.head0 = h else: s.head1 = h)
  popupMenu("geokind"):
    for g in GeoKind:
      if menuItem(capitalizeAscii(($g).replace("-", " "))):
        geoKind = g
        restyle("Shape", proc (s: var Shape) = (if s.kind == skGeo: s.geo = g))
  popupMenu("zoom"):
    if menuItem("Zoom &In", "Ctrl+="): zoomSteps(true)
    if menuItem("Zoom &Out", "Ctrl+-"): zoomSteps(false)
    if menuItem("Zoom to &100%", "Ctrl+0"): resetZoom()
    if menuItem("Zoom to &Fit", "Shift+1"): zoomToFit()
    if menuItem("Zoom to &Selection", "Shift+2", enabled = sel.len > 0):
      zoomToBox(bd.selectionBounds(sel), 2.0)
  popupMenu("pages"):
    for i, pg in bd.pages:
      if menuItem(pg.name, checked = i == bd.cur):
        finishEdit()
        bd.cur = i
        sel = @[]
    menuSeparator()
    if menuItem("&New Page"):
      finishEdit()
      bd.pages.add bd.newPage("Page " & $(bd.pages.len + 1))
      bd.cur = bd.pages.high
      sel = @[]
      bd.modified = true
      inc bd.ver
    if menuItem("&Rename Page..."):
      renameText = bd.page.name
      renameDlg = true
    if menuItem("&Duplicate Page"):
      finishEdit()
      let shapes = bd.page.shapes
      let p = bd.newPage(bd.page.name & " copy")
      p.camX = bd.page.camX
      p.camY = bd.page.camY
      p.zoom = bd.page.zoom
      bd.pages.insert(p, bd.cur + 1)
      bd.cur = bd.cur + 1
      discard bd.cloneShapes(shapes, 0, 0)
      sel = @[]
      bd.modified = true
    if menuItem("De&lete Page", enabled = bd.pages.len > 1):
      finishEdit()
      bd.pages.delete(bd.cur)
      bd.cur = clamp(bd.cur, 0, bd.pages.high)
      bd.clearHistory()
      sel = @[]
      bd.modified = true
      inc bd.ver

proc findNext() =
  ## The next shape whose words hold what is looked for: its page shown,
  ## it selected and in view.
  if findWhat.strip.len == 0:
    findDlg = true
    return
  findHits = bd.findText(findWhat)
  if findHits.len == 0:
    status = "Cannot find \"" & findWhat & "\""
    return
  findAt = findAt mod findHits.len
  let h = findHits[findAt]
  inc findAt
  finishEdit()
  bd.cur = h.page
  sel = @[h.id]
  let s = bd.find(h.id)
  if s != nil: zoomToBox(bd.boundsOf(s[]), max(1.0, bd.page.zoom))
  status = "Found " & $findAt & " of " & $findHits.len

proc openPosition() =
  ## (the Position and Size dialog, with the selection's numbers)
  if sel.len != 1: return
  let s = bd.find(sel[0])
  if s == nil or s.kind in {skArrow, skGroup}: return
  posX = int(round(s.x))
  posY = int(round(s.y))
  posW = int(round(s.w))
  posH = int(round(s.h))
  posA = int(round(radToDeg(s.rot)))
  posDlg = true

proc freeMemory() =
  bd.forgetDrawings()
  pics.clear()
  releaseMemory(mpCritical)
  trimHeap()
  memAt = -100000
  status = "Memory let go of: " & $(programMemory() div (1024 * 1024)) & " MB in use"

proc exitApp() =
  ## Ends the program (the board saved first; a file with changes: asked).
  finishEdit()
  writeAutosave()
  saveSettingsNow()
  if bd.modified and bd.path.len > 0: askQuit = true
  else: quitApp()

proc mainMenu() =
  menubar:
    menu "&File":
      if menuItem("&New", "Ctrl+N"):
        if bd.modified and bd.page.shapes.len > 0:
          afterSave = "new"
          askNew = true
        else: newBoardNow()
      if menuItem("&Open...", "Ctrl+O"): openDlg = true
      if menuItem("&Save", "Ctrl+S"): discard save()
      if menuItem("Save &As..."):
        picked = docName() & ".board"
        saveDlg = true
      menuSeparator()
      if menuItem("Insert &Picture..."): pictureDlg = true
      if menuItem("&Export...", "Ctrl+E"):
        exportWhat = if sel.len > 0: 1 else: 0
        exportDark = darkMode
        exportDlg = true
      when defined(android):
        if menuItem("S&hare as PNG..."):
          exportFormat = 0
          exportWhat = if sel.len > 0: 1 else: 0
          exportShare()
      menuSeparator()
      if menuItem("E&xit", "Alt+F4"): exitApp()
    menu "&Edit":
      if menuItem("&Undo " & bd.undoName, "Ctrl+Z", enabled = bd.canUndo):
        finishEdit()
        bd.undo()
        cleanSel()
      if menuItem("&Redo " & bd.redoName, "Ctrl+Y", enabled = bd.canRedo):
        finishEdit()
        bd.redo()
        cleanSel()
      menuSeparator()
      if menuItem("Cu&t", "Ctrl+X", enabled = sel.len > 0):
        copySel()
        deleteSel()
      if menuItem("&Copy", "Ctrl+C", enabled = sel.len > 0): copySel()
      if menuItem("&Paste", "Ctrl+V"): pasteAt(pastePoint())
      if menuItem("&Duplicate", "Ctrl+D", enabled = sel.len > 0): duplicateSel()
      if menuItem("De&lete", "Del", enabled = sel.len > 0): deleteSel()
      menuSeparator()
      if menuItem("Select &All", "Ctrl+A"): selectAll()
      if menuItem("Select &None", "Esc", enabled = sel.len > 0): sel = @[]
      menuSeparator()
      if menuItem("&Group", "Ctrl+G", enabled = sel.len > 1): groupSel()
      if menuItem("U&ngroup", "Ctrl+Shift+G", enabled = sel.len > 0): ungroupSel()
      if menuItem("Loc&k", "Ctrl+Shift+L", enabled = sel.len > 0): lockSel(true)
      if menuItem("Unlock All"): unlockAll()
      menuSeparator()
      if menuItem("&Find...", "Ctrl+F"): findDlg = true
      if menuItem("Find &Next", "F3", enabled = findWhat.len > 0): findNext()
      if menuItem("&Link...", "Ctrl+K", enabled = sel.len == 1):
        linkText = bd.find(sel[0]).link
        linkDlg = true
    menu "&Arrange":
      let some = sel.len > 0
      if menuItem("Bring to &Front", "Ctrl+]", enabled = some): arrange("front")
      if menuItem("Bring &Forward", "]", enabled = some): arrange("forward")
      if menuItem("Send &Backward", "[", enabled = some): arrange("backward")
      if menuItem("Send to Bac&k", "Ctrl+[", enabled = some): arrange("back")
      menuSeparator()
      submenu "&Align":
        for (name, how) in [("&Left", "left"), ("&Center", "center"), ("&Right", "right"), ("&Top", "top"),
                            ("&Middle", "middle"), ("&Bottom", "bottom")]:
          if menuItem(name, enabled = sel.len > 1):
            let h = how
            bd.change("Align"): bd.alignShapes(sel, h)
      submenu "&Distribute":
        if menuItem("&Horizontally", enabled = sel.len > 2):
          bd.change("Distribute"): bd.distribute(sel, true)
        if menuItem("&Vertically", enabled = sel.len > 2):
          bd.change("Distribute"): bd.distribute(sel, false)
      if menuItem("Flip &Horizontal", "Shift+H", enabled = some):
        bd.change("Flip"): bd.flipShapes(sel, true)
      if menuItem("Flip &Vertical", "Shift+V", enabled = some):
        bd.change("Flip"): bd.flipShapes(sel, false)
      menuSeparator()
      if menuItem("&Position and Size...", enabled = sel.len == 1 and singleKind() notin {skArrow, skGroup}):
        openPosition()
      submenu "&Next Step":
        let ok = sel.len == 1 and singleKind() in {skGeo, skNote, skText, skImage}
        if menuItem("To the &Right", "Ctrl+Right", enabled = ok): nextStep(1, 0)
        if menuItem("&Below", "Ctrl+Down", enabled = ok): nextStep(0, 1)
        if menuItem("To the &Left", "Ctrl+Left", enabled = ok): nextStep(-1, 0)
        if menuItem("&Above", "Ctrl+Up", enabled = ok): nextStep(0, -1)
    menu "&View":
      if menuItem("Zoom &In", "Ctrl+="): zoomSteps(true)
      if menuItem("Zoom &Out", "Ctrl+-"): zoomSteps(false)
      if menuItem("Zoom to &100%", "Ctrl+0"): resetZoom()
      if menuItem("Zoom to &Fit", "Shift+1"): zoomToFit()
      if menuItem("Zoom to &Selection", "Shift+2", enabled = sel.len > 0): zoomToBox(bd.selectionBounds(sel), 2.0)
      menuSeparator()
      if menuItem("&Grid", checked = showGrid):
        showGrid = not showGrid
        saveSettingsNow()
      if menuItem("&Snap to Shapes", checked = snapOn):
        snapOn = not snapOn
        saveSettingsNow()
      if menuItem("&Dark Canvas", checked = darkMode):
        darkMode = not darkMode
        applyDark()
        saveSettingsNow()
      if menuItem("S&ketch Style", checked = cur.dash == bdSketch):
        # (new shapes sketched: each edge twice, loosely -- the selection too)
        let sk = cur.dash != bdSketch
        cur.dash = if sk: bdSketch else: bdDraw
        let d = cur.dash
        restyle("Sketch Style", proc (s: var Shape) =
          if s.kind in {skGeo, skArrow, skLine}: s.dash = d)
        saveSettingsNow()
      if menuItem("Tool &Lock", "Q", checked = toolLock):
        toolLock = not toolLock
        saveSettingsNow()
      menuSeparator()
      submenu "&Colors":
        for i, t in builtinThemes:
          if menuItem("&" & t.name, checked = themeIndex() == i):
            ui.theme = t.theme
            invalidate()
            darkMode = darkScheme()
            applyDark()
            saveSettingsNow()
      if menuItem("&Appearance..."): appearDlg = true
      if menuItem("Status &Bar", checked = showStatus):
        showStatus = not showStatus
        saveSettingsNow()
      submenu "Canvas Co&lor":
        for i, pc in paperColors:
          if menuItem("&" & pc.name, checked = bd.paper == i):
            bd.paper = i
            bd.forgetDrawings()
            bd.modified = true
            inc bd.ver
      menuSeparator()
      submenu "&Panels":
        if menuItem("&Show Panels", "Tab", checked = not panelsHidden):
          panelsHidden = not panelsHidden
          saveSettingsNow()
        menuSeparator()
        for (k, t, ic) in panelList:
          if menuItem("&" & t, checked = dock.panelShown(k)):
            panelsHidden = false
            dock.togglePanel(k, panelDef(k))
            saveSettingsNow()
        menuSeparator()
        if menuItem("&Reset Panels"):
          panelsHidden = false
          defaultDock(isCompact())
          saveSettingsNow()
      if menuItem("&Zen Mode", "Alt+Z", checked = zenMode):
        zenMode = not zenMode
        saveSettingsNow()
      if menuItem("&View Mode", "Alt+R", checked = viewMode):
        viewMode = not viewMode
        if viewMode:
          sel = @[]
          tool = tSelect
      if menuItem("S&tats...", "Alt+/"): statsDlg = true
    menu "&Page":
      for i, pg in bd.pages:
        if menuItem(pg.name, checked = i == bd.cur):
          finishEdit()
          bd.cur = i
          sel = @[]
      menuSeparator()
      if menuItem("&New Page"):
        finishEdit()
        bd.pages.add bd.newPage("Page " & $(bd.pages.len + 1))
        bd.cur = bd.pages.high
        sel = @[]
        bd.modified = true
        inc bd.ver
      if menuItem("&Rename Page..."):
        renameText = bd.page.name
        renameDlg = true
    menu "&Help":
      if menuItem("&Keyboard Shortcuts...", "?"): keysDlg = true
      if menuItem("&About Retro Board..."): aboutDlg = true

# ---- the keyboard -----------------------------------------------------------------------------

proc keys() =
  if ui.key == KeySpace and editing == 0: spaceHeld = true
  if ui.keyUp == KeySpace: spaceHeld = false
  if editing != 0 or ui.keyUsed or not canInput() or ui.key == KeyNone: return
  let ctrl = CtrlPressed in ui.mods
  let shift = ShiftPressed in ui.mods
  var used = true
  if ctrl:
    case ui.key
    of KeyZ:
      if shift: bd.redo() else: bd.undo()
      cleanSel()
    of KeyY:
      bd.redo()
      cleanSel()
    of KeyC: copySel()
    of KeyX:
      copySel()
      deleteSel()
    of KeyV: pasteAt(pastePoint())
    of KeyD: duplicateSel()
    of KeyA: selectAll()
    of KeyG:
      if shift: ungroupSel() else: groupSel()
    of KeyL:
      if shift: lockSel(true) else: used = false
    of KeyS: discard save()
    of KeyO: openDlg = true
    of KeyN:
      if bd.modified and bd.page.shapes.len > 0: askNew = true else: newBoardNow()
    of KeyE:
      exportWhat = if sel.len > 0: 1 else: 0
      exportDlg = true
    of KeyEqual, KeyPlus: zoomSteps(true)
    of KeyMinus: zoomSteps(false)
    of Key0: resetZoom()
    of KeyRightBracket: arrange("front")
    of KeyLeftBracket: arrange("back")
    of KeyF: findDlg = true
    of KeyK:
      if sel.len == 1:
        linkText = bd.find(sel[0]).link
        linkDlg = true
    of KeyRight: nextStep(1, 0)
    of KeyLeft: nextStep(-1, 0)
    of KeyDown: nextStep(0, 1)
    of KeyUp: nextStep(0, -1)
    else: used = false
  elif AltPressed in ui.mods:
    case ui.key
    of KeyZ:
      zenMode = not zenMode
      saveSettingsNow()
    of KeyR:
      viewMode = not viewMode
      if viewMode:
        sel = @[]
        tool = tSelect
    of KeySlash: statsDlg = not statsDlg
    else: used = false
  elif ui.key == KeyF3:
    findNext()
  else:
    let step = if shift: 10.0 else: 1.0
    case ui.key
    of KeyDelete, KeyBackspace: deleteSel()
    of KeyTab:
      panelsHidden = not panelsHidden
      saveSettingsNow()
    of KeyEsc:
      if drag != dkNone: cancelDrag()
      elif moreOpen: moreOpen = false
      elif sel.len > 0: sel = @[]
      elif tool != tSelect: setTool(tSelect)
      else: used = false
    of KeyEnter:
      if sel.len == 1 and bd.find(sel[0]) != nil and bd.find(sel[0])[].hasText: startEdit(sel[0])
      else: used = false
    of KeyLeft: nudge(-step, 0)
    of KeyRight: nudge(step, 0)
    of KeyUp: nudge(0, -step)
    of KeyDown: nudge(0, step)
    of KeyRightBracket: arrange("forward")
    of KeyLeftBracket: arrange("backward")
    of KeyV:
      if shift:
        if sel.len > 0:
          bd.change("Flip"): bd.flipShapes(sel, false)
      else: setTool(tSelect)
    of KeyH:
      if shift:
        if sel.len > 0:
          bd.change("Flip"): bd.flipShapes(sel, true)
      else: setTool(tHand)
    of KeyD, KeyP: setTool(if shift: tHighlight else: tDraw)
    of KeyE: setTool(tEraser)
    of KeyK: setTool(tLaser)
    of KeyA: setTool(tArrow)
    of KeyL: setTool(tLine)
    of KeyT: setTool(tText)
    of KeyN: setTool(tNote)
    of KeyF: setTool(tFrame)
    of KeyR:
      geoKind = gkRectangle
      setTool(tGeo)
    of KeyO:
      geoKind = gkEllipse
      setTool(tGeo)
    of KeyG: setTool(tGeo)
    of KeyQ: toolLock = not toolLock
    of KeySlash:
      if shift: keysDlg = true else: used = false
    of Key1:
      if shift: zoomToFit() else: used = false
    of Key2:
      if shift and sel.len > 0: zoomToBox(bd.selectionBounds(sel), 2.0) else: used = false
    of Key0:
      if shift: resetZoom() else: used = false
    else: used = false
  if used:
    ui.keyUsed = true
    ui.redraw = true

# ---- dialogs ----------------------------------------------------------------------------------

proc dialogs() =
  if inputBox(linkDlg, "Link", "A web address the shape opens (empty: none):", linkText) == 1 and sel.len == 1:
    let l = linkText.strip
    bd.change("Link"):
      bd.update(sel[0], proc (s: var Shape) = s.link = l)
  if inputBox(findDlg, "Find", "Words on the board:", findWhat) == 1:
    findAt = 0
    findNext()
  if beginDialog(posDlg, "Position and Size", dp(300)):
    for (lbl, v) in [("&X:", addr posX), ("&Y:", addr posY), ("&Width:", addr posW), ("&Height:", addr posH),
                     ("&Angle:", addr posA)]:
      row([dp(80), -1]):
        label lbl
        discard spin(v[], (if lbl in ["&Width:", "&Height:"]: 1 elif lbl == "&Angle:": -360 else: -1000000),
                     (if lbl == "&Angle:": 360 else: 1000000), w = dp(120))
    space 4
    case buttonRow(["OK", "Cancel"])
    of 1:
      posDlg = false
      if sel.len == 1:
        let (x, y, w, h, a) = (posX.float, posY.float, max(1, posW).float, max(1, posH).float, degToRad(posA.float))
        bd.change("Position and Size"):
          bd.update(sel[0], proc (s: var Shape) =
            if s.w > 0 and s.h > 0 and s.pts.len > 0:
              for p in s.pts.mitems:
                p.x = float32(p.x.float * w / s.w)
                p.y = float32(p.y.float * h / s.h)
            s.x = x
            s.y = y
            s.w = w
            s.h = h
            s.rot = a
            if s.kind == skText:
              s.autoSize = false
              s.fitText())
    of 2: posDlg = false
    else: discard
    endDialog()
  if beginDialog(statsDlg, "Stats", dp(360)):
    var kinds: array[ShapeKind, int]
    for s in bd.page.shapes: inc kinds[s.kind]
    var shapesAll = 0
    for p in bd.pages: shapesAll += p.shapes.len
    var picBytes = 0
    for k, v in bd.assets: picBytes += v.len
    proc mbs(n: int): string = formatFloat(n.float / (1024 * 1024), ffDecimal, 1) & " MB"
    label "Board", bold = true
    paragraph $bd.pages.len & " pages, " & $shapesAll & " shapes; this page: " & $(bd.page.shapes.len) & " -- " &
              $kinds[skGeo] & " shapes, " & $kinds[skArrow] & " arrows, " & $kinds[skDraw] & " drawings, " &
              $(kinds[skText] + kinds[skNote]) & " texts and notes, " & $kinds[skImage] & " pictures"
    if sel.len > 0:
      let b = bd.selectionBounds(sel)
      paragraph "Selection: " & $sel.len & " -- x " & $int(b.x) & ", y " & $int(b.y) & ", " & $int(b.w) & " x " &
                $int(b.h)
    space 4
    label "Memory", bold = true
    let mem = memoryNumbers()
    paragraph "In use by the program: " & mbs(int(mem.program)) & " (the graphics driver's too, when the GPU draws)"
    paragraph "Drawings kept: " & mbs(bd.drawingBytes) & " -- steps to undo: " & mbs(bd.historyBytes) &
              " -- pictures: " & $bd.assets.len & ", " & mbs(picBytes)
    if mem.device > 0: paragraph "Device: " & mbs(int(mem.free)) & " free of " & mbs(int(mem.device))
    space 4
    case buttonRow(["&Free Memory", "Close"])
    of 1: freeMemory()
    of 2: statsDlg = false
    else: discard
    endDialog()
  if filePicker(openDlg, picked, fmOpen, ["*.board", "*"], "Open Board"): openBoard(picked)
  if filePicker(saveDlg, picked, fmSave, ["*.board"], "Save Board"):
    if saveTo(picked):
      case afterSave
      of "new": newBoardNow()
      of "quit": quitApp()
      else: discard
    afterSave = ""
  if filePicker(pictureDlg, picked, fmOpen, ["*.png", "*.jpg", "*.jpeg", "*.bmp", "*.gif", "*.webp"],
                "Insert Picture"):
    insertPicture(picked)
  if filePicker(exportPick, picked, fmSave, ["*" & exportExt()], "Export"): exportTo(picked)
  if beginDialog(exportDlg, "Export", dp(330)):
    label "Format:"
    row:
      radio("&PNG", exportFormat, 0)
      radio("S&VG", exportFormat, 1)
      radio("P&DF", exportFormat, 2)
    label "What:"
    row:
      radio("The &page", exportWhat, 0)
      radio("The &selection", exportWhat, 1, enabled = sel.len > 0)
    if exportFormat == 0:
      label "Scale:"
      row:
        radio("&1x", exportScale, 0)
        radio("&2x", exportScale, 1)
        radio("&3x", exportScale, 2)
    checkbox("&Background", exportBg)
    checkbox("&Dark", exportDark)
    row:
      label "Padding:"
      discard spin(exportPad, 0, 400, w = dp(80), step = 8)
    space 4
    let buttons = when defined(android): @["Save...", "Share", "Cancel"] else: @["Save...", "Cancel"]
    let b = buttonRow(buttons)
    if b == 1:
      exportDlg = false
      picked = docName() & exportExt()
      exportPick = true
    elif b == 2 and buttons.len == 3:
      exportDlg = false
      exportShare()
    elif b == buttons.len: exportDlg = false
    endDialog()
  if beginDialog(appearDlg, "Appearance", dp(400)):
    let was = ui.theme
    if appearanceSettings():
      if ui.theme != was:
        darkMode = darkScheme()
        applyDark()
      saveSettingsNow()
    space 4
    if buttonRow(["Close"]) == 1: appearDlg = false
    endDialog()
  if inputBox(renameDlg, "Rename Page", "Page name:", renameText) == 1 and renameText.strip.len > 0:
    bd.page.name = renameText.strip
    bd.modified = true
    inc bd.ver
  if beginDialog(keysDlg, "Keyboard Shortcuts", dp(420)):
    for line in [
        "V select   H hand   D draw   Shift+D highlighter   E eraser   K laser",
        "R rectangle   O ellipse   G the last shape   A arrow   L line",
        "T text   N note   F frame   Q tool lock   Space+drag pan",
        "Double click: type in a shape, or a new text; Enter types in the one selected",
        "Del delete   Ctrl+D duplicate   Ctrl+C / X / V copy, cut, paste",
        "Ctrl+Z undo   Ctrl+Y redo   Ctrl+A select all   Esc deselect",
        "Ctrl+G group   Ctrl+Shift+G ungroup   Ctrl+Shift+L lock",
        "[ ] backward / forward   Ctrl+[ Ctrl+] to the back / front",
        "Arrows nudge (Shift: 10)   Shift+H / Shift+V flip",
        "Wheel or pinch: zoom   Ctrl+= / Ctrl+- / Ctrl+0   Shift+1 fit   Shift+2 selection",
        "Shift while dragging: straight, square, in steps of 15 degrees",
        "Ctrl while moving: snapping on or off   Alt on an arrow's end: no hold",
        "Ctrl+F find   F3 find next   Ctrl+K link   Ctrl+Arrow the next step of a flowchart",
        "Tab the panels   Alt+Z zen mode   Alt+R view mode   Alt+/ stats",
        "Ctrl+S save   Ctrl+O open   Ctrl+N new   Ctrl+E export"]:
      paragraph line
    if buttonRow(["OK"]) == 1: keysDlg = false
    endDialog()
  case msgBox(askNew, AppName, "Save the changes to " & docName() & " first?", ["&Yes", "&No", "Cancel"],
              miQuestion)
  of 1:
    afterSave = "new"
    if save():
      afterSave = ""
      newBoardNow()
  of 2: newBoardNow()
  else: discard
  case msgBox(askQuit, AppName, "Save the changes to " & docName() & "?", ["&Yes", "&No", "Cancel"],
              miWarning)
  of 1:
    afterSave = "quit"
    if save(): quitApp()
  of 2: quitApp()
  else: discard
  aboutBox(aboutDlg, AppName, BoardVersion,
           ["An endless whiteboard: ink, shapes, arrows, text, notes, frames and pictures, " &
            "on as many pages as you like.",
            "Made with Retro Nim UI " & RetroVersion & " (retroui/board, retroui/freehand)."],
           tagline = "Draw, sketch and think together", iconPng = iconPng,
           whatsNew = ["1.3.4: Ctrl+Shift+Up / Down make the next step, and only that (the pages' list " &
                       "leaves them be); Ctrl+Backspace and Ctrl+Delete take a word in a text; when the " &
                       "board stopped, the next start says why first",
                       "1.3.3: the words on the board twice as big -- as Excalidraw's beside the shapes (S, M, L, XL: " &
                       "38, 48, 68, 86); boards made before keep theirs as they were drawn until you choose a size",
                       "1.3.2: the menus answer at once; the letters drawn as before, Sharp text a choice; " &
                       "the Windows 3.1 frame on every desktop",
                       "1.3.1: a line drawn from a shape or to one holds on to it (a connector, as an arrow " &
                       "with no heads: it follows the shapes; Alt: a free line); 100% half as big on a tablet or " &
                       "a phone -- a page's unit to each dot of the screen",
                       "1.3.0: the panels as Retro Photo's -- docked down the right in tabs that belong " &
                       "together (Color, Stroke, Fill; Text, Arrow, Shapes; Arrange, Board, Info), dragged into " &
                       "other groups, floated, folded to icons, hidden with Tab, kept as you left them; on a phone " &
                       "a strip of icons. Exit Zen and Edit (View Mode) work again",
                       "1.2.0: options as Excalidraw's -- a background color of its own, fills (hachure, " &
                       "cross-hatch, zigzag, dots), sloppiness, sharp or round edges, straight, curved and elbow " &
                       "arrows, the canvas's color, layers, align, links, the next step of a flowchart (Ctrl+Arrow), " &
                       "Find, Position and Size, Stats with the memory used, Zen and View modes; shapes kept " &
                       "inside the canvas when the GPU draws",
                       "1.1.0: six handwriting fonts (Caveat, Patrick Hand, Architects Daughter, Gochi Hand, " &
                       "Indie Flower, Aref Ruqaa for Arabic); 12 more shapes; the Sketch style; the title bar, " &
                       "a status bar, color schemes and Appearance; Exit everywhere; far less memory; lines " &
                       "no longer lost when zoomed in on a phone",
                       "1.0.0: the first Retro Board -- tools, styles, pages, export to PNG, SVG and PDF"],
           credits = ["Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net",
                      "In the manner of tldraw's whiteboard",
                      "Fonts (SIL Open Font License): Caveat (Impallari Type), Patrick Hand (Patrick Wagesreiter), " &
                      "Architects Daughter and Indie Flower (Kimberly Geswein), Gochi Hand (Huerta Tipografica), " &
                      "Aref Ruqaa (Khaled Hosny and the Aref Ruqaa authors)"],
           url = "https://www.foxoman.net")

# ---- the frame ---------------------------------------------------------------------------------

const toolHints: array[Tool, string] = [
  "Click to select, drag to move; drag on the empty canvas to select several",
  "Drag to move the canvas", "Drag to draw (a pen presses harder for a thicker line)",
  "Drag to highlight", "Drag over what to erase", "Drag to point things out (it fades)",
  "Drag to make the shape (Shift: as wide as tall); click for one of the usual size",
  "Drag from a shape to another: the arrow holds on to them", "Drag to draw a line (Shift: in steps of 45 degrees); from or to a shape, it holds on to it",
  "Click to type", "Click to put a note", "Drag to make a frame"]

var statusAt = 0

proc statusLine() =
  ## The status bar: what the tool does (or what just happened), the page,
  ## the shapes, the zoom, the memory used.
  if ui.now - memAt > 2000:
    memAt = ui.now
    memText = $(programMemory() div (1024 * 1024)) & " MB"
  if status.len > 0 and statusAt == 0: statusAt = ui.now
  if status.len == 0: statusAt = 0
  let hint = if status.len > 0: status
             elif editing != 0: "Typing: Esc or a click outside ends it"
             elif sel.len > 0: $sel.len & " selected -- drag to move, the handles to size and turn"
             else: toolHints[tool]
  var n = 0
  for s in bd.page.shapes:
    if s.kind != skGroup: inc n
  let z = $int(round(bd.page.zoom * 100)) & "%"
  if isCompact(): statusbar(hint, z, memText)
  else:
    statusbar(hint, bd.page.name & " (" & $(bd.cur + 1) & "/" & $bd.pages.len & ")",
              $n & (if n == 1: " shape" else: " shapes"), z, "Memory " & memText)

proc boardFrame() =
  let wanted = AppName & " - " & docName() & (if bd.modified and bd.path.len > 0: " *" else: "")
  if ui.title != wanted: setTitle(wanted)
  if closeRequested():
    finishEdit()
    writeAutosave()
    saveSettingsNow()
    if bd.modified and bd.path.len > 0 and not ui.touch:
      cancelClose()
      askQuit = true
  captionBar()                     # (phones and tablets: the 3.1 title bar, navy)
  mainMenu()
  if showStatus: statusLine()
  cleanSel()
  fitDock()
  # (zen mode: only the tool bar; view mode: nothing over the canvas)
  let barShown = not viewMode
  let sideShown = not viewMode and not zenMode
  let panelsShown = sideShown and not panelsHidden
  if not beginMdi(-1, "board", tint(bd.paperOf), edgeToEdge = true): return
  let a = mdiAreaRect("board")
  # the canvas: the area, less the panels down its right
  view = rect(a.x, a.y, max(10, a.w - (if panelsShown: dock.width else: 0)), max(10, a.h))
  # the floating bars (they take the pointer before the canvas does)
  let l = barLayout()
  let covers = if panelsShown: dock.coverRects("board") else: @[]
  # (zen and view mode: a small button at the top right, the way back)
  let leave = rect(view.x + view.w - dp(96) - dp(8), view.y + dp(8), dp(96), (if fingers(): dp(40) else: dp(28)))
  blockers = covers
  if barShown: blockers.add l.bar
  if sideShown: blockers.add [topLeftRect(), zoomRect()]
  if moreOpen and barShown: blockers.add morePanel(l)
  if viewMode or zenMode: blockers.add leave
  keys()
  typing()
  canvasInput()
  drawCanvas()
  # (the bars: under the panels' palettes and the group shown beside their icons)
  ui.blockers = covers
  if barShown: drawToolbar(l)
  if moreOpen and barShown: drawMore(l)
  if sideShown:
    drawTopLeft()
    drawZoom()
  if viewMode or zenMode:
    if buttonAt("leavemode", leave, if viewMode: "Edit" else: "Exit Zen"):
      viewMode = false
      zenMode = false
      saveSettingsNow()
  ui.blockers.setLen(0)
  if panelsShown:
    discard dockPanels(dock, "board", panelBody, panelMenu)
  endMdi()
  if status.len > 0 and not showStatus:
    let w = textWidth(status) + dp(16)
    let r = rect(view.x + (view.w - w) div 2, l.bar.y - FontH - dp(18), w, FontH + dp(8))
    fill(r, th.tip)
    box(r, th.frame)
    text(r.x + dp(8), r.y + dp(4), status, th.tipText)
  if status.len > 0 and (ui.pressed or ui.key != KeyNone) and ui.now - statusAt > 1500: status = ""
  canvasMenu()
  dialogs()
  # autosave: a moment after the last change, and when the phone puts the app away
  if bd.ver != seenVer:
    seenVer = bd.ver
    changedAt = ui.now
  if seenVer != savedVer:
    if drag == dkNone and editing == 0 and ui.now - changedAt >= 1500: writeAutosave()
    else: wakeIn(max(1, 1500 - (ui.now - changedAt)))
  if ui.paused and seenVer != savedVer:
    finishEdit()
    writeAutosave()

proc main() =
  windowIcon = windowIconFromPng(iconPng)
  startApp(AppName, 1100, 720)
  # (the last run stopped: its board waits for the "stopped" screen's Start)
  let waiting = stoppedPending()
  if not waiting: loadStart()
  restoreDock()
  applyDark()
  # (the phone short of memory, or the program put away: what can be made again goes)
  onMemoryPressure(proc (level: MemoryPressure) =
    bd.forgetDrawings()
    pics.clear()
    ui.redraw = true)
  when not (defined(android) or defined(retroAndroidMock)):
    for a in commandLineParams():
      if a.endsWith(".board") and fileExists(a): openBoard(a)
  var first = true
  var boardWaits = waiting
  while beginFrame():
    if stoppedFrame(): (endFrame(); continue)
    if boardWaits:
      boardWaits = false
      loadStart(fresh = startFresh())
      applyDark()
    if first:
      view = rect(0, ui.barY + MenuH, ui.w, ui.h - ui.barY - MenuH)
      if bd.page.shapes.len == 0 and bd.page.camX == 0 and bd.page.camY == 0:
        bd.page.camX = -view.w.float / 2 / zoom()
        bd.page.camY = -view.h.float / 2 / zoom()
      first = false
    boardFrame()
    endFrame()
  finishEdit()
  writeAutosave()
  saveSettingsNow()
  stopApp()

when not declared(boardUnderTest): main()

## Retro Navigator's screenshots: a picture of the page, marked up with
## Retro Board's tools -- its pen, highlighter, boxes, ovals, arrows and
## words, in its colors and sizes -- then copied for any program to paste,
## or saved as a picture (PNG) or as a board Retro Board opens.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[math, os, strutils, times]
import retroui, retroui/[board, imaging]

type
  MarkTool* = enum
    mtPen = "Pen", mtMarker = "Highlighter", mtBox = "Box", mtOval = "Oval",
    mtArrow = "Arrow", mtText = "Words"

  Markup* = object
    ## A screenshot being marked up (`markupView`).
    open*: bool
    shot*: Bitmap               # the page's picture
    bd*: Board                  # what is drawn on it (the picture its first shape)
    tool*: MarkTool
    color*: BoardColor
    size*: BoardSize
    words*: string              # what the Words tool puts down
    creating: int               # (the shape being drawn)
    dragging: bool
    start: (float, float)
    saveOpen: bool
    savePath: string
    asBoard: bool
    status*: string

const
  Tools = [(mtPen, pxPencil), (mtMarker, pxBrush), (mtBox, pxMarqueeRect),
           (mtOval, pxMarqueeEllipse), (mtArrow, pxLineTool), (mtText, pxTypeTool)]
  Colors = [bcBlack, bcRed, bcOrange, bcYellow, bcGreen, bcBlue, bcViolet, bcWhite]
  Sizes = [(bsS, "S"), (bsM, "M"), (bsL, "L"), (bsXL, "XL")]

proc colorOf(c: uint32): Color =
  Color(r: uint8((c shr 16) and 255), g: uint8((c shr 8) and 255), b: uint8(c and 255),
        a: uint8((c shr 24) and 255))

proc startMarkup*(m: var Markup; shot: Bitmap) =
  ## Opens the markup with `shot`, nothing drawn on it yet.
  m.shot = shot
  m.bd = newBoard()
  var pic = m.bd.newShape(skImage, 0, 0, shot.w.float, shot.h.float)
  pic.image = m.bd.addAsset(encodePng(shot))
  pic.locked = true
  discard m.bd.addShape(pic)
  m.bd.clearHistory()
  m.bd.modified = false
  if m.words.len == 0: m.words = "Look here"
  if m.tool == mtPen and m.color == bcBlack: m.color = bcRed
  m.creating = 0
  m.dragging = false
  m.status = ""
  m.open = true

proc marked*(m: Markup): Bitmap =
  ## The picture with what is drawn on it, as large as the picture.
  if m.shot == nil: return nil
  var ids: seq[int]
  for s in m.bd.page.shapes: ids.add s.id
  let box = m.bd.selectionBounds(ids)
  let shot = m.shot
  let all = m.bd.renderBitmap(ids, background = false, padding = 0,
                              pictures = proc (s: Shape): Bitmap = shot)
  # (what goes past the picture's edges cut off)
  let ox = int(round(-box.x))
  let oy = int(round(-box.y))
  result = newBitmap(shot.w, shot.h)
  for y in 0 ..< shot.h:
    let sy = y + oy
    if sy < 0 or sy >= all.h: continue
    for x in 0 ..< shot.w:
      let sx = x + ox
      if sx >= 0 and sx < all.w: result.px[y * shot.w + x] = all.px[sy * all.w + sx]

proc styledFor(m: Markup; s: var Shape) =
  s.color = m.color
  s.size = m.size
  if s.kind in {skGeo, skArrow}:
    s.dash = bdSolid
    s.roughness = -1
  if s.kind == skText: s.font = bfnSans

proc markupView*(m: var Markup) =
  ## The markup in the rest of the window: its tools above, the picture
  ## below. Close (or Esc) ends it.
  if not m.open or m.shot == nil: return
  let bd = m.bd
  row:
    for (t, glyph) in Tools:
      if toolButton(glyph, $t, down = m.tool == t, size = 1.2): m.tool = t
    toolSeparator()
    for c in Colors:
      let r = place(CtrlH, CtrlH - 1)
      let hit = interact(idOf("markcolor:" & $c), r, focusable = false)
      buttonFace(r, m.color == c, bevel = 1)
      fill(inset(r, dp(4)), colorOf(inkOf(c)))
      box(inset(r, dp(4)), ui.theme.frame)
      if hit.hover and canHover(): ui.tip = ($c).replace("-", " ").capitalizeAscii
      if hit.clicked: m.color = c
    toolSeparator()
    for (sz, name) in Sizes:
      if toolButton(name, "Size " & name, down = m.size == sz): m.size = sz
    toolSeparator()
    if toolButton(pxUndo, "Undo (Ctrl+Z)", enabled = bd.canUndo, size = 1.2) or
       (hotkeyPressed("Ctrl+Z") and bd.canUndo): bd.undo()
    if toolButton(pxRedo, "Redo (Ctrl+Y)", enabled = bd.canRedo, size = 1.2) or
       (hotkeyPressed("Ctrl+Y") and bd.canRedo): bd.redo()
    if m.tool == mtText:
      toolSeparator()
      label "&Words:"
      edit(m.words, w = dp(140))
  row:
    if button("&Save Picture...", isDefault = true):
      m.asBoard = false
      m.savePath = picturesDir() / ("Navigator " & now().format("yyyy-MM-dd HH.mm.ss") & ".png")
      m.saveOpen = true
    if button("&Copy"):
      m.status = if copyPicture(m.marked): "Copied: paste it in any program"
                 else: "This system's clipboard takes no pictures"
    if button("Save as Bo&ard..."):
      m.asBoard = true
      m.savePath = picturesDir() / ("Navigator " & now().format("yyyy-MM-dd HH.mm.ss") & ".board")
      m.saveOpen = true
    if button("C&lear", enabled = bd.page.shapes.len > 1):
      bd.change("Clear"):
        for i in countdown(bd.page.shapes.high, 1): bd.removeShape(bd.page.shapes[i].id)
    spring()
    if m.status.len > 0: label m.status
    if button("Close") or hotkeyPressed("Esc"):
      m.open = false
      return

  # the picture, as large as it fits (not larger than it is)
  let area = place(0, remainingH(), fill = true)
  fill(area, ui.theme.shadow)
  let k = min(1.0, min(area.w / m.shot.w, area.h / m.shot.h))
  let vw = max(1, int(m.shot.w.float * k))
  let vh = max(1, int(m.shot.h.float * k))
  let view = rect(area.x + (area.w - vw) div 2, area.y + (area.h - vh) div 2, vw, vh)
  let ox = view.x.float
  let oy = view.y.float
  pushClip(area)
  drawBitmap(view, m.shot)
  for s in bd.page.shapes:
    if s.kind == skImage: continue
    for piece in bd.drawingOf(s).pieces:
      fillContours(piece.contours, colorOf(piece.color), ox, oy, k)
  popClip()
  box(rect(view.x - 1, view.y - 1, view.w + 2, view.h + 2), ui.theme.frame)

  # drawing on it
  if mouseIn(view) and canInput(): ui.cursor = curCrosshair
  let p = (clamp((ui.mx.float - ox) / k, 0.0, m.shot.w.float),
           clamp((ui.my.float - oy) / k, 0.0, m.shot.h.float))
  if not m.dragging and hover(view) and takePress():
    m.start = p
    m.creating = 0
    case m.tool
    of mtPen, mtMarker:
      var s = bd.newShape(if m.tool == mtPen: skDraw else: skHighlight, p[0], p[1], 1, 1)
      m.styledFor(s)
      if m.tool == mtMarker and m.color == bcBlack: s.color = bcYellow
      s.pts = @[(0'f32, 0'f32, 0.5'f32)]
      bd.begin($m.tool)
      m.creating = bd.addShape(s)
      m.dragging = true
    of mtBox, mtOval, mtArrow:
      bd.begin($m.tool)
      m.dragging = true
    of mtText:
      if m.words.strip.len > 0:
        bd.change("Words"):
          var s = bd.textShape(p[0], p[1], m.words.strip)
          m.styledFor(s)
          s.fitText()
          s.y -= s.h / 2
          discard bd.addShape(s)
  elif m.dragging:
    let (a, b) = (m.start, p)
    case m.tool
    of mtPen, mtMarker:
      let s = bd.find(m.creating)
      if s != nil:
        let lx = b[0] - s.x
        let ly = b[1] - s.y
        let last = s.pts[^1]
        if hypot(lx - last.x.float, ly - last.y.float) * k >= 0.8:
          bd.update(m.creating, proc (t: var Shape) = t.pts.add (float32(lx), float32(ly), 0.5'f32))
    of mtBox, mtOval:
      let x = min(a[0], b[0])
      let y = min(a[1], b[1])
      let w = max(1.0, abs(b[0] - a[0]))
      let h = max(1.0, abs(b[1] - a[1]))
      if m.creating == 0:
        var s = bd.geoShape(if m.tool == mtBox: gkRectangle else: gkEllipse, x, y, w, h)
        m.styledFor(s)
        m.creating = bd.addShape(s)
      else:
        bd.update(m.creating, proc (s: var Shape) =
          s.x = x
          s.y = y
          s.w = w
          s.h = h)
    of mtArrow:
      if m.creating != 0: bd.removeShape(m.creating)
      var s = bd.arrowShape(a[0], a[1], b[0], b[1])
      m.styledFor(s)
      m.creating = bd.addShape(s)
    of mtText: discard
    if not ui.mouseDown:
      if m.tool in {mtPen, mtMarker} and m.creating != 0:
        bd.update(m.creating, proc (s: var Shape) = s.fitInk())
      if m.creating == 0: bd.cancelChange() else: bd.commit()
      m.dragging = false
      m.creating = 0
    ui.redraw = true

  # saving
  if filePicker(m.saveOpen, m.savePath, fmSave,
                (if m.asBoard: @["*.board"] else: @["*.png"]),
                (if m.asBoard: "Save as Board" else: "Save Picture")):
    try:
      if m.asBoard:
        let path = if m.savePath.endsWith(".board"): m.savePath else: m.savePath & ".board"
        bd.saveBoard(path)
        m.status = "Saved: " & path.extractFilename
      else:
        let path = if m.savePath.toLowerAscii.endsWith(".png"): m.savePath else: m.savePath & ".png"
        writeFile(path, encodePng(m.marked))
        m.status = "Saved: " & path.extractFilename
    except CatchableError as e:
      m.status = "Not saved: " & e.msg

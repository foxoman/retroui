## The whiteboard document (retroui/board) and its freehand ink (retroui/freehand):
## shapes added, changed, undone and redone; arrows that hold on to shapes;
## hit-testing, snapping, groups; saved and read back; drawn as a picture
## and as SVG.

import std/[unittest, strutils, math, os, json, base64, tables]
import retroui/[board, freehand, gfx, imaging, raster, textengine]

proc pixelAt(b: Bitmap; x, y: int): uint32 = b.px[y * b.w + x]

suite "freehand ink":
  test "a stroke's outline goes round its points":
    var pts: seq[InkPoint]
    for i in 0 .. 40: pts.add (float32(i * 5), float32(50 + sin(i.float / 5) * 20), 0.5'f32)
    let o = strokeOutline(pts, 10)
    check o.len > 20
    var x0, y0 = 1e9
    var x1, y1 = -1e9
    for p in o:
      x0 = min(x0, p[0]); x1 = max(x1, p[0]); y0 = min(y0, p[1]); y1 = max(y1, p[1])
    check x0 < 0 and x1 > 200          # (round caps past its ends)
    check y0 < 32 and y1 > 68
  test "a dot is a circle; no points, nothing":
    check strokeOutline(@[(10'f32, 10'f32, 0.5'f32)], 8).len == 16
    check strokeOutline(newSeq[InkPoint](), 8).len == 0
  test "pressure: pressed lightly, thinner":
    var light, hard: seq[InkPoint]
    for i in 0 .. 20:
      light.add (float32(i * 10), 0'f32, 0.1'f32)
      hard.add (float32(i * 10), 0'f32, 1'f32)
    proc height(o: seq[(float, float)]): float =
      var a = 1e9
      var b = -1e9
      for p in o:
        if p[0] > 50 and p[0] < 150:
          a = min(a, p[1]); b = max(b, p[1])
      b - a
    let lo = height(strokeOutline(light, 10, simulatePressure = false))
    let hi = height(strokeOutline(hard, 10, simulatePressure = false))
    check lo < hi * 0.6

suite "the document":
  test "added, changed, undone, redone":
    let b = newBoard()
    var id: int
    b.change("Rectangle"):
      id = b.addShape(b.geoShape(gkRectangle, 10, 10, 100, 50))
    check b.page.shapes.len == 1 and b.canUndo and b.undoName == "Rectangle"
    b.change("Move"):
      b.update(id, proc (s: var Shape) = s.moveBy(20, 5))
    check b.find(id).x == 30 and b.find(id).y == 15
    b.undo()
    check b.find(id).x == 10
    b.undo()
    check b.page.shapes.len == 0 and not b.canUndo
    b.redo()
    b.redo()
    check b.find(id).x == 30
    check b.modified
  test "a change that changes nothing is no step":
    let b = newBoard()
    b.change("Nothing"): discard
    check not b.canUndo
  test "a change taken back as it goes (Esc)":
    let b = newBoard()
    var id: int
    b.change("Add"): id = b.addShape(b.geoShape(gkEllipse, 0, 0, 50, 50))
    b.begin("Drag")
    b.update(id, proc (s: var Shape) = s.moveBy(100, 100))
    discard b.addShape(b.noteShape(0, 0, "x"))
    b.cancelChange()
    check b.page.shapes.len == 1 and b.find(id).x == 0
    check b.undoName == "Add"
  test "removing a shape: arrows let go of it, a group takes its own":
    let b = newBoard()
    var r, a, g1, g2, grp: int
    b.change("Make"):
      r = b.addShape(b.geoShape(gkRectangle, 0, 0, 100, 100))
      var ar = b.arrowShape(200, 50, 300, 50)
      ar.t0 = Terminal(x: 50, y: 50, bound: r, nx: 0.5, ny: 0.5)
      a = b.addShape(ar)
      g1 = b.addShape(b.geoShape(gkStar, 400, 0, 50, 50))
      g2 = b.addShape(b.geoShape(gkHeart, 500, 0, 50, 50))
      grp = b.groupShapes([g1, g2])
    check grp != 0 and b.find(g1).parent == grp
    b.change("Delete"):
      b.removeShape(r)
      b.removeShape(grp)
    check b.has(a) and not b.has(g1) and not b.has(g2)
    check b.find(a).t0.bound == 0
    b.undo()
    check b.has(g1) and b.find(a).t0.bound == r
  test "order: to the front, back, forward, backward":
    let b = newBoard()
    var ids: seq[int]
    b.change("Make"):
      for i in 0 ..< 4: ids.add b.addShape(b.geoShape(gkRectangle, i.float * 10, 0, 5, 5))
    b.change("Front"): b.reorder([ids[0]], "front")
    check b.page.shapes[^1].id == ids[0]
    b.change("Back"): b.reorder([ids[0]], "back")
    check b.page.shapes[0].id == ids[0]
    b.change("Forward"): b.reorder([ids[0]], "forward")
    check b.page.shapes[1].id == ids[0]
    b.undo()
    check b.page.shapes[0].id == ids[0]

suite "where shapes are":
  test "hit: on the line, in a filled one, round a hollow one":
    let b = newBoard()
    var hollow, filled: int
    b.change("Make"):
      hollow = b.addShape(b.geoShape(gkRectangle, 0, 0, 200, 200))
      var f = b.geoShape(gkEllipse, 300, 0, 100, 100)
      f.fill = bfSolid
      filled = b.addShape(f)
    check b.hitTest(b.find(hollow)[], 0, 100, 4) == hitEdge
    check b.hitTest(b.find(hollow)[], 100, 100, 4) == hitHollow
    check b.hitTest(b.find(filled)[], 350, 50, 4) == hitFilled
    check b.topShapeAt(350, 50, 4) == filled
    check b.topShapeAt(100, 100, 4) == hollow
    check b.topShapeAt(1000, 1000, 4) == 0
  test "a turned shape is hit where it is drawn":
    let b = newBoard()
    var id: int
    b.change("Make"):
      var s = b.geoShape(gkRectangle, 0, 0, 200, 20)
      s.fill = bfSolid
      id = b.addShape(s)
      b.update(id, proc (s: var Shape) = s.rotateAbout(100, 10, PI / 2))
    check b.topShapeAt(100, 90, 2) == id     # (now standing up)
    check b.topShapeAt(180, 10, 2) == 0
  test "a box selects what is in it":
    let b = newBoard()
    var a, c: int
    b.change("Make"):
      a = b.addShape(b.geoShape(gkRectangle, 0, 0, 50, 50))
      c = b.addShape(b.geoShape(gkRectangle, 100, 0, 50, 50))
    check b.shapesIn((-10.0, -10.0, 80.0, 80.0)) == @[a]
    check b.shapesIn((40.0, 10.0, 70.0, 10.0), touching = true) == @[a, c]
  test "snapping: edges and middles line up":
    let b = newBoard()
    var a: int
    b.change("Make"):
      a = b.addShape(b.geoShape(gkRectangle, 0, 0, 100, 100))
    let sn = b.snapBox((103.0, 4.0, 50.0, 50.0), [], 6)
    check abs(sn.dx - (-3.0 - 4.0)) < 0.01 or abs(sn.dx + 3.0 + 4.0) < 0.01 or sn.dx != 0
    check sn.guides.len >= 1

suite "arrows":
  test "an arrow held by two shapes ends at their edges, and follows them":
    let b = newBoard()
    var r1, r2, a: int
    b.change("Make"):
      r1 = b.addShape(b.geoShape(gkRectangle, 0, 0, 100, 100))
      r2 = b.addShape(b.geoShape(gkRectangle, 300, 0, 100, 100))
      var ar = b.arrowShape(50, 50, 350, 50)
      ar.t0 = Terminal(x: 50, y: 50, bound: r1, nx: 0.5, ny: 0.5)
      ar.t1 = Terminal(x: 350, y: 50, bound: r2, nx: 0.5, ny: 0.5)
      a = b.addShape(ar)
    var (p0, p1) = b.arrowEnds(b.find(a)[])
    check p0.x > 100 and p0.x < 115 and abs(p0.y - 50) < 0.01
    check p1.x < 300 and p1.x > 285
    let before = b.drawingOf(b.find(a)[])
    b.change("Move"): b.update(r2, proc (s: var Shape) = s.moveBy(0, 200))
    (p0, p1) = b.arrowEnds(b.find(a)[])
    check p1.y > 190
    let after = b.drawingOf(b.find(a)[])
    check after.pieces.len > 0 and after.pieces[^1].contours != before.pieces[^1].contours
  test "a bent arrow passes its middle point":
    let b = newBoard()
    var ar = b.arrowShape(0, 0, 200, 0)
    ar.bend = 50
    let id = b.addShape(ar)
    let path = b.arrowPath(b.find(id)[])
    check path.len > 5
    let m = b.arrowMiddle(b.find(id)[])
    check abs(m.x - 100) < 0.01 and abs(abs(m.y) - 50) < 0.01
    var near = 1e9
    for p in path: near = min(near, hypot(p.x - m.x, p.y - m.y))
    check near < 6

suite "drawn":
  test "every shape draws (outlines in page units)":
    let b = newBoard()
    b.change("Make"):
      for g in GeoKind:
        var s = b.geoShape(g, float(ord(g) * 120), 0, 100, 80)
        s.fill = BoardFill(ord(g) mod 4)
        s.dash = BoardDash(ord(g) mod 4)
        s.text = "Hi"
        discard b.addShape(s)
      var d = b.newShape(skDraw, 0, 200, 100, 100)
      for i in 0 .. 30: d.pts.add (float32(i * 3), float32(i * 2), 0.5'f32)
      discard b.addShape(d)
      discard b.addShape(b.textShape(0, 400, "Hello, board"))
      discard b.addShape(b.noteShape(400, 400, "A note"))
      var ln = b.newShape(skLine, 0, 600, 0, 0)
      ln.pts = @[(0'f32, 0'f32, 0.5'f32), (100'f32, 50'f32, 0.5'f32), (200'f32, 0'f32, 0.5'f32)]
      ln.spline = true
      discard b.addShape(ln)
      var fr = b.newShape(skFrame, 600, 600, 300, 200)
      fr.text = "Frame"
      discard b.addShape(fr)
    for s in b.page.shapes:
      let d = b.drawingOf(s)
      check d.pieces.len > 0
      var n = 0
      for p in d.pieces: n += p.contours.len
      check n > 0
  test "text: sized to its words, set as outlines":
    let b = newBoard()
    var t = b.textShape(0, 0, "Hello")
    let w1 = t.w
    t.text = "Hello, wide world"
    t.fitText()
    check t.w > w1 * 2
    t.text = "two\nlines"
    t.fitText()
    check t.h > fontSizes[bsM] * 2
  test "drawn in part (a tile of the screen) as it is drawn whole":
    # (the outline past the part's sides drawn on them: a line that ends on
    # the left side a hair past it, by rounding, must still count, and what
    # is past the right side covers the part's last column)
    let b = newBoard()
    var s = b.geoShape(gkRectangle, -349.5, -170, 150, 100)
    s.id = 2
    b.page.shapes.add s
    var pts: seq[seq[(float32, float32)]]
    for piece in b.drawingOf(b.page.shapes[0]).pieces:
      for c in piece.contours:
        var q: seq[(float32, float32)]
        for p in c: q.add (float32(p[0] + 550), float32(p[1] + 370.5))
        pts.add q
    proc mask(cx, cy, cw, ch: int): seq[uint8] =
      let w = cw + 2
      var r = newRaster(w, ch)
      for c in pts:
        for i in 0 ..< c.len:
          let a = c[i]
          let e = c[(i + 1) mod c.len]
          r.edge(a[0] - float32(cx - 1), a[1] - float32(cy), e[0] - float32(cx - 1), e[1] - float32(cy))
      r.coverage()
    var d = b.geoShape(gkDiamond, -349.5, -175, 150, 140)
    d.id = 3
    d.fill = bfSolid
    b.page.shapes.add d
    for piece in b.drawingOf(b.page.shapes[1]).pieces:
      for c in piece.contours:
        var q: seq[(float32, float32)]
        for p in c: q.add (float32(p[0] + 550), float32(p[1] + 370.5))
        pts.add q
    let whole = mask(198, 196, 155, 108)
    for (cx, cw) in [(256, 97), (198, 58), (240, 30)]:
      let part = mask(cx, 196, cw, 28)
      var worst = 0
      for y in 0 ..< 28:
        for x in 0 ..< cw:
          worst = max(worst, abs(int(part[y * (cw + 2) + x + 1]) - int(whole[y * 157 + (cx - 198) + x + 1])))
      check worst <= 2

  test "Arabic text draws":
    let b = newBoard()
    let id = b.addShape(b.textShape(0, 0, "مرحبا بالعالم"))
    check b.drawingOf(b.find(id)[]).pieces.len > 0

suite "files and pictures":
  test "saved and read back":
    let b = newBoard()
    b.change("Make"):
      var s = b.geoShape(gkCloud, 5, 6, 70, 80)
      s.text = "سحابة"
      s.color = bcViolet
      s.rot = 0.5
      discard b.addShape(s)
      var ar = b.arrowShape(0, 0, 100, 100)
      ar.head0 = ahDot
      ar.bend = 12
      discard b.addShape(ar)
      var d = b.newShape(skDraw, 0, 0, 10, 10)
      d.pts = @[(1'f32, 2'f32, 0.25'f32), (3'f32, 4'f32, 0.75'f32)]
      d.isPen = true
      discard b.addShape(d)
    b.pages.add b.newPage("Second")
    let path = getTempDir() / "test_board.board"
    b.saveBoard(path)
    check not b.modified
    let c = loadBoard(path)
    check c != nil and c.pages.len == 2 and c.pages[1].name == "Second"
    check c.page.shapes.len == 3
    let s = c.page.shapes[0]
    check s.geo == gkCloud and s.text == "سحابة" and s.color == bcViolet and abs(s.rot - 0.5) < 1e-9
    check c.page.shapes[1].head0 == ahDot and c.page.shapes[1].bend == 12
    check c.page.shapes[2].pts.len == 2 and c.page.shapes[2].isPen
    check c.nextId >= b.nextId
    check loadBoard(getTempDir() / "no such.board") == nil
    removeFile(path)
  test "PNG: the page as a picture (transparent, or on the canvas color)":
    let b = newBoard()
    var s = b.geoShape(gkRectangle, 0, 0, 100, 100)
    s.fill = bfSolid
    s.color = bcRed
    discard b.addShape(s)
    let pic = b.renderBitmap([], scale = 2, background = false, padding = 10)
    check pic.w == 2 * (100 + 2 * 10 + 2 * 4) - 2 * 4 + 2 * 4 or pic.w > 230
    let mid = pic.pixelAt(pic.w div 2, pic.h div 2)
    check (mid shr 24) == 255 and ((mid shr 16) and 255) > 180
    check (pic.pixelAt(0, 0) shr 24) == 0          # (transparent round it)
    let opaque = b.renderBitmap([], 1, background = true)
    check opaque.pixelAt(0, 0) == paper(false)
    let png = encodePng(pic)
    check png.startsWith("\x89PNG")
    let back = decodePng(png)
    check back.w == pic.w and back.h == pic.h
  test "SVG: paths in the page's colors":
    let b = newBoard()
    discard b.addShape(b.geoShape(gkDiamond, 0, 0, 100, 100))
    discard b.addShape(b.textShape(0, 120, "SVG"))
    let svg = b.toSvg([])
    check svg.startsWith("<svg") and svg.contains("<path d=\"M") and svg.contains("</svg>")
    check svg.count("<path") >= 2

suite "more than one shape":
  test "duplicated: groups and the arrows between them kept":
    let b = newBoard()
    var r1, r2, a, g: int
    b.change("Make"):
      r1 = b.addShape(b.geoShape(gkRectangle, 0, 0, 50, 50))
      r2 = b.addShape(b.geoShape(gkRectangle, 200, 0, 50, 50))
      var ar = b.arrowShape(25, 25, 225, 25)
      ar.t0 = Terminal(bound: r1, nx: 0.5, ny: 0.5)
      ar.t1 = Terminal(bound: r2, nx: 0.5, ny: 0.5)
      a = b.addShape(ar)
      g = b.groupShapes([r1, r2])
    var copies: seq[int]
    b.change("Duplicate"): copies = b.duplicate([g, a])
    check copies.len == 2 and b.page.shapes.len == 8
    let ng = b.find(copies[0])
    let na = b.find(copies[1])
    check ng.kind == skGroup and na.kind == skArrow
    check b.find(na.t0.bound).parent == ng.id and na.t0.bound != r1
    b.undo()
    check b.page.shapes.len == 4
  test "the clipboard: copied, pasted where asked; an arrow lets go of what was not copied":
    let b = newBoard()
    var r, a: int
    b.change("Make"):
      r = b.addShape(b.geoShape(gkEllipse, 0, 0, 100, 100))
      var ar = b.arrowShape(50, 50, 300, 50)
      ar.t0 = Terminal(bound: r, nx: 0.5, ny: 0.5)
      a = b.addShape(ar)
    let clip = b.toClipboard([a])
    let shapes = b.fromClipboard(clip)
    check shapes.len == 1
    check b.fromClipboard("hello").len == 0
    var ids: seq[int]
    b.change("Paste"): ids = b.pasteShapes(shapes, 1000, 1000)
    let p = b.find(ids[0])
    check p.t0.bound == 0
    check abs((p.t0.x + p.t1.x) / 2 - 1000) < 1
  test "aligned, distributed, flipped":
    let b = newBoard()
    var ids: seq[int]
    b.change("Make"):
      ids.add b.addShape(b.geoShape(gkRectangle, 0, 0, 50, 50))
      ids.add b.addShape(b.geoShape(gkRectangle, 70, 30, 50, 50))
      ids.add b.addShape(b.geoShape(gkRectangle, 400, 60, 50, 50))
    b.change("Align"): b.alignShapes(ids, "top")
    for id in ids: check b.find(id).y == 0
    b.change("Distribute"): b.distribute(ids, horizontal = true)
    check abs(b.find(ids[1]).x - 200) < 0.01
    var d: int
    b.change("Ink"):
      var s = b.newShape(skDraw, 0, 0, 100, 10)
      s.pts = @[(0'f32, 0'f32, 0.5'f32), (100'f32, 10'f32, 0.5'f32)]
      d = b.addShape(s)
    b.change("Flip"): b.flipShapes([d], horizontal = true)
    check b.find(d).pts[0].x > 99 and b.find(d).pts[1].x < 1
  test "a frame's contents":
    let b = newBoard()
    var f, inside, outside: int
    b.change("Make"):
      f = b.addShape(b.newShape(skFrame, 0, 0, 400, 300))
      inside = b.addShape(b.geoShape(gkStar, 50, 50, 60, 60))
      outside = b.addShape(b.geoShape(gkStar, 500, 50, 60, 60))
    check b.contentsOf(f) == @[inside]

suite "typing":
  test "the caret moves along the words; a click finds the letter":
    let b = newBoard()
    let id = b.addShape(b.textShape(100, 100, "Hello"))
    let s = b.find(id)[]
    let (t0, b0) = b.textCaret(s, 0)
    let (t5, _) = b.textCaret(s, 5)
    check t5.x > t0.x + 30 and b0.y > t0.y
    check b.textIndexAt(s, t5.x + 2, (t5.y + b0.y) / 2) == 5
    check b.textIndexAt(s, t0.x - 5, (t0.y + b0.y) / 2) == 0
  test "an empty label's caret is in its middle":
    let b = newBoard()
    let id = b.addShape(b.geoShape(gkRectangle, 0, 0, 200, 100))
    let (top, bottom) = b.textCaret(b.find(id)[], 0)
    check abs(top.x - 100) < 1 and top.y < 50 and bottom.y > 50

suite "PDF":
  test "the page as a PDF of outlines":
    let b = newBoard()
    discard b.addShape(b.geoShape(gkHexagon, 0, 0, 100, 100))
    discard b.addShape(b.textShape(0, 120, "PDF"))
    let pdf = b.toPdf([])
    check pdf.startsWith("%PDF") and pdf.len > 1000
  test "Arabic text is as wide as its words":
    let b = newBoard()
    let t = b.textShape(0, 0, "مرحبا بالعالم")
    check t.w > 50 and t.w < 400

suite "undo and the drawings kept":
  test "undone, a shape is drawn as it was, not as it is now":
    let b = newBoard()
    var id: int
    b.change("Make"): id = b.addShape(b.textShape(0, 0, "A"))
    let orig = b.find(id)[]
    b.update(id, proc (s: var Shape) =
      s.text = "AB"
      s.fitText())                     # (typing: no step of its own)
    let final = b.find(id)[]
    b.setShape(orig)
    b.change("Edit Text"): b.setShape(final)
    var n = 0
    for p in b.drawingOf(b.find(id)[]).pieces: n += p.contours.len
    b.undo()
    var m = 0
    for p in b.drawingOf(b.find(id)[]).pieces: m += p.contours.len
    check b.find(id).text == "A" and m < n

suite "memory":
  test "a picture is kept once, however often it is moved; saved and read back":
    let b = newBoard()
    var pic = newString(1_000_000)
    for i in 0 ..< pic.len: pic[i] = char(i mod 251)
    var s = b.newShape(skImage, 0, 0, 100, 100)
    s.image = b.addAsset(pic)
    var id: int
    b.change("Picture"): id = b.addShape(s)
    let before = getOccupiedMem()
    for k in 0 ..< 40:
      b.change("Move"): b.update(id, proc (t: var Shape) = t.moveBy(1, 0))
    check getOccupiedMem() - before < 2_000_000
    check b.addAsset(pic) == s.image and b.assets.len == 1
    let path = getTempDir() / "test_board_pic.board"
    b.saveBoard(path)
    let c = loadBoard(path)
    check c.assetOf(c.page.shapes[0].image) == pic
    # (copied to another board: the picture goes with it)
    let d = newBoard()
    let shapes = d.fromClipboard(b.toClipboard([id]))
    check shapes.len == 1 and d.assetOf(shapes[0].image) == pic
    removeFile(path)
  test "an older file's picture (its bytes in the shape) is read too":
    let j = %*{"format": "retro-board", "pages": [{"id": 1, "name": "P", "shapes": [
      {"id": 2, "kind": "image", "x": 0, "y": 0, "w": 10, "h": 10, "image": encode("\x89PNGabc")}]}]}
    let b = boardFrom(j)
    check b.assetOf(b.page.shapes[0].image) == "\x89PNGabc"
  test "the steps to undo keep no more than their budget":
    let saved = undoBudget
    undoBudget = 2_000_000
    let b = newBoard()
    var d = b.newShape(skDraw, 0, 0, 1, 1)
    for i in 0 .. 5000: d.pts.add (float32(i), 0'f32, 0.5'f32)
    var id: int
    b.change("Draw"): id = b.addShape(d)
    for k in 0 ..< 100:
      b.change("Move"): b.update(id, proc (t: var Shape) = t.moveBy(1, 0))
    check b.historyBytes <= 2_000_000 and b.canUndo
    undoBudget = saved

suite "fonts and shapes":
  test "a hand font draws Arabic in the Arabic hand; the type faces in FreeSerif":
    let st = CharStyle(size: 24, hScale: 1, vScale: 1)
    let spans = fontSpans("Hi مرحبا", bfnHand, st)
    check spans.len == 2 and spans[0].style.family == "Caveat" and spans[1].style.family == "Aref Ruqaa"
    check fontSpans("Hi مرحبا", bfnMono, st)[^1].style.family in ["FreeSerif", "FreeMono"]
    check fontSpans("Hi مرحبا", bfnSans, st)[^1].style.family == "FreeSerif"
    check fontSpans("Hi", bfnRetro, st)[0].style.family == "FreeSerif"
    check fontSpans("Hello", bfnMarker, st).len == 1
  test "every font draws":
    let b = newBoard()
    for f in BoardFont:
      var t = b.textShape(0, 0, "Aa")
      t.font = f
      t.id = 1000 + ord(f)
      t.fitText()
      check t.w > 5 and b.drawingOf(t).pieces.len > 0
  test "every shape, hand drawn and sketched, has an outline and draws":
    let b = newBoard()
    for dash in [bdDraw, bdSketch]:
      for g in GeoKind:
        var s = b.geoShape(g, 0, 0, 120, 100)
        s.dash = dash
        s.fill = bfPattern
        let id = b.addShape(s)
        check geoOutline(g, 120, 100).len >= 3
        var n = 0
        for p in b.drawingOf(b.find(id)[]).pieces: n += p.contours.len
        check n > 2

suite "more options (as Excalidraw)":
  test "fill styles, a fill color of its own, sloppiness, round corners draw":
    let b = newBoard()
    for f in BoardFill:
      for r in -1 .. 1:
        var s = b.geoShape(gkRectangle, 0, 0, 160, 100)
        s.fill = f
        s.fillColor = ord(bcGreen) + 1
        s.roughness = r
        s.round = r == 1
        s.dash = if r == 0: bdSketch else: bdDraw
        let id = b.addShape(s)
        check b.drawingOf(b.find(id)[]).pieces.len >= (if f == bfNone: 1 else: 2)
    var s = b.geoShape(gkRectangle, 0, 0, 100, 100)
    s.round = true
    check s.localOutline.len > 4 * 6
    check s.fillOf == bcBlack
    s.fillColor = ord(bcRed) + 1
    check s.fillOf == bcRed
  test "an elbow arrow goes at right angles from side to side":
    let b = newBoard()
    var a, c, ar: int
    b.change("Make"):
      a = b.addShape(b.geoShape(gkRectangle, 0, 0, 100, 60))
      c = b.addShape(b.geoShape(gkRectangle, 300, 200, 100, 60))
      var x = b.arrowShape(0, 0, 0, 0)
      x.elbow = true
      x.t0 = Terminal(bound: a, nx: 0.5, ny: 0.5)
      x.t1 = Terminal(bound: c, nx: 0.5, ny: 0.5)
      ar = b.addShape(x)
    let p = b.arrowPath(b.find(ar)[])
    check p.len == 4
    for i in 1 ..< p.len: check abs(p[i].x - p[i - 1].x) < 1e-6 or abs(p[i].y - p[i - 1].y) < 1e-6
    check p[0].x > 100 and p[^1].x < 300
  test "a flowchart's next step, and an arrow to it; the words found":
    let b = newBoard()
    var a: int
    b.change("Make"):
      var s = b.geoShape(gkDiamond, 0, 0, 120, 80)
      s.text = "Start here"
      a = b.addShape(s)
    var n: tuple[shape, arrow: int]
    b.change("Next"): n = b.addConnected(a, 1, 0)
    let t = b.find(n.shape)
    check t.geo == gkDiamond and t.x > 120 and t.text == ""
    check b.find(n.arrow).t0.bound == a and b.find(n.arrow).t1.bound == n.shape
    var m: tuple[shape, arrow: int]
    b.change("Next"): m = b.addConnected(a, 1, 0)     # (the place is taken: below it)
    check b.find(m.shape).y > b.find(n.shape).y + 10
    check b.findText("HERE") == @[(0, a)]
  test "the new options and the canvas color are saved and read back":
    let b = newBoard()
    b.paper = 3
    var s = b.geoShape(gkHexagon, 0, 0, 100, 100)
    s.fillColor = ord(bcViolet) + 1
    s.roughness = 1
    s.round = true
    s.link = "https://www.foxoman.net"
    s.fill = bfZigzag
    discard b.addShape(s)
    var x = b.arrowShape(0, 0, 50, 50)
    x.elbow = true
    discard b.addShape(x)
    let c = boardFrom(b.toJson)
    check c.paper == 3
    let t = c.page.shapes[0]
    check t.fillOf == bcViolet and t.roughness == 1 and t.round and t.link == "https://www.foxoman.net"
    check t.fill == bfZigzag and c.page.shapes[1].elbow

suite "the letters' sizes":
  test "words as big as Excalidraw's; a board of before keeps its own":
    check fontSizes == [38.0, 48.0, 68.0, 86.0]
    let b = newBoard()
    var box = b.newShape(skGeo, 0, 0, 300, 120)
    box.text = "Test"
    discard b.addShape(box)
    check b.labelFrame(b.page.shapes[0]).size == 48.0
    # saved now (version 2) and read back: the same
    let j = b.toJson
    check j["version"].getInt == 2
    check boardFrom(j).page.shapes[0].textSize == 48.0
    # a board saved before (version 1): its words at 24, as they were drawn,
    # and so again once saved and read back
    j["version"] = %1
    let old = boardFrom(j)
    let s = old.page.shapes[0]
    check abs(s.textSize - 24.0) < 1e-9 and abs(old.labelFrame(s).size - 24.0) < 1e-9
    check abs(boardFrom(old.toJson).page.shapes[0].textSize - 24.0) < 1e-9

suite "thousands of shapes, zoomed out":
  test "too small to read: drawn in brief, fast, its words as bars":
    let b = newBoard()
    for i in 0 ..< 300:
      var s = b.newShape(skNote, float(i mod 20) * 120, float(i div 20) * 120, 100, 100)
      s.text = "A note, number " & $i
      b.addShape(s)
    let s = b.page.shapes[0]
    check b.briefAt(s, 0.1) and not b.briefAt(s, 1.0)
    let full = b.drawingOf(s)
    let brief = b.drawingOf(s, brief = true)
    var fullPts, briefPts = 0
    for p in full.pieces:
      for c in p.contours: fullPts += c.len
    for p in brief.pieces:
      for c in p.contours: briefPts += c.len
    # (the note and its words still there, but no letters' outlines: a few
    # points, not hundreds)
    check brief.pieces.len >= 2 and briefPts * 10 < fullPts
    # a page's small picture drawn in brief is the same size, its colors there
    let pic = b.renderBitmap([], scale = 0.1, brief = true)
    check pic.w > 100 and pic.h > 100
  test "the drawings kept: the oldest go when they are too many, not all":
    let b = newBoard()
    for i in 0 ..< 200:
      var s = b.newShape(skGeo, float(i) * 120, 0, 100, 70)
      s.text = "Box " & $i
      b.addShape(s)
    let before = drawingBudget
    drawingBudget = 400 * 1024
    for s in b.page.shapes: discard b.drawingOf(s)
    check b.drawingBytes <= drawingBudget
    # (the last ones asked for are still kept: drawn again, nothing is made)
    let kept = b.drawingBytes
    discard b.drawingOf(b.page.shapes[^1])
    check b.drawingBytes == kept
    drawingBudget = before
  test "a frame's time to make drawings: the rest in brief, made in the next frames":
    let b = newBoard()
    for i in 0 ..< 400:
      var s = b.newShape(skNote, float(i mod 20) * 120, float(i div 20) * 120, 100, 100)
      s.text = "A note, number " & $i
      b.addShape(s)
    var frames = 0
    while true:
      inc frames
      b.startDrawing(2)                   # (2 ms: far too little for 400)
      for s in b.page.shapes: discard b.drawingFor(s, 1.0)
      if not b.behind or frames > 500: break
    check frames > 1 and frames < 500     # (several frames, and then all in full)
    for s in b.page.shapes:
      check b.drawingFor(s, 1.0).pieces.len == b.drawingOf(s).pieces.len

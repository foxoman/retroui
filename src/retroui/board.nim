## A whiteboard's document: pages of shapes on an endless canvas -- freehand
## ink, the highlighter, geometric shapes with labels, arrows that hold on to
## shapes, lines, text, sticky notes, frames, pictures, groups -- with their
## styles (twelve colors, fills, dashes, sizes, fonts), undo and redo,
## hit-testing, snapping, and what they look like as filled outlines
## (`drawingOf`), ready to draw at any zoom on the CPU or the GPU. Saved as
## JSON (`.board`), exported as PNG (`renderBitmap`) and SVG (`toSvg`).
## Retro Board (examples/retroboard.nim) is built on it. Use it for any app
## that keeps a drawing of shapes the user moves and styles; it draws
## nothing on screen itself (the app fills each piece's outlines).
##
## ```nim
## let b = newBoard()
## b.change("Rectangle"):
##   discard b.addShape(geoShape(b, gkRectangle, 100, 100, 200, 120))
## for s in b.page.shapes:
##   for piece in b.drawingOf(s).pieces: fillContours(piece.contours, ...)
## ```
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[math, tables, json, strutils, algorithm, base64, hashes, sets, os, monotimes, times]
import std/unicode except strip   # (its strip cuts letters: docs/nim-bugs.md)
import gfx, freehand, textengine, raster, imaging, pdf, ttf
from codec import unbase64
from typeset import FaceId, unpackFacesSoon

type
  BoardColor* = enum
    ## The twelve colors of the board's palette and white (the strings:
    ## their names in a saved board). `inkOf`, `semiOf`, `noteOf` give
    ## their ARGB on a light or dark canvas.
    bcBlack = "black", bcGrey = "grey", bcLightViolet = "light-violet", bcViolet = "violet",
    bcBlue = "blue", bcLightBlue = "light-blue", bcYellow = "yellow", bcOrange = "orange",
    bcGreen = "green", bcLightGreen = "light-green", bcLightRed = "light-red", bcRed = "red",
    bcWhite = "white"
  BoardFill* = enum
    ## How a shape is filled: not at all, a light tint of its color
    ## (`semiOf`), solid, or with lines (hachure, cross-hatch, zigzag) or
    ## dots (`fillLines`).
    bfNone = "none", bfSemi = "semi", bfSolid = "solid", bfPattern = "pattern", bfCross = "cross-hatch",
    bfZigzag = "zigzag", bfDots = "dots"
  BoardDash* = enum
    ## How a shape's line is drawn: by hand (`bdDraw`), dashed, dotted,
    ## solid (neat), or sketched (several loose strokes).
    bdDraw = "draw", bdDashed = "dashed", bdDotted = "dotted", bdSolid = "solid", bdSketch = "sketch"
  BoardSize* = enum
    ## The four sizes of lines and letters (`strokeWidth`, `fontSizes`).
    bsS = "s", bsM = "m", bsL = "l", bsXL = "xl"
  BoardFont* = enum
    ## Six hands (fonts in the manner of handwriting, SIL OFL, carried in
    ## the module), then the type faces of the kit: FreeSans, FreeSerif,
    ## FreeMono and FreeSerif Italic (`bfnRetro`: the name of the font that
    ## slot had, MS W98 UI, kept for the boards saved with it).
    bfnHand = "hand", bfnMarker = "marker", bfnArchitect = "architect", bfnChunky = "chunky",
    bfnFlower = "flower", bfnRuqaa = "ruqaa", bfnSans = "sans", bfnSerif = "serif", bfnMono = "mono",
    bfnRetro = "retro"
  BoardAlign* = enum
    ## Where words stand in their box: across (left, middle, right) or down
    ## (top, middle, bottom).
    baStart = "start", baMiddle = "middle", baEnd = "end"
  GeoKind* = enum
    ## The outline of a geometric shape (`skGeo`; `geoShape` makes one).
    gkRectangle = "rectangle", gkEllipse = "ellipse", gkTriangle = "triangle", gkDiamond = "diamond",
    gkPentagon = "pentagon", gkHexagon = "hexagon", gkOctagon = "octagon", gkStar = "star",
    gkRhombus = "rhombus", gkTrapezoid = "trapezoid", gkOval = "oval", gkCloud = "cloud",
    gkHeart = "heart", gkCheckBox = "check-box", gkXBox = "x-box", gkArrowRight = "arrow-right",
    gkArrowLeft = "arrow-left", gkArrowUp = "arrow-up", gkArrowDown = "arrow-down",
    gkRoundRect = "rounded-rectangle", gkRightTriangle = "right-triangle", gkCylinder = "cylinder",
    gkDocument = "document", gkSpeech = "speech-bubble", gkCross = "cross", gkDoubleArrow = "arrow-left-right",
    gkChevron = "chevron", gkLightning = "lightning", gkMoon = "moon", gkCube = "cube", gkPerson = "person"
  ShapeKind* = enum
    ## What a shape is: freehand ink, the highlighter, a geometric shape, an
    ## arrow, a line through handles, text, a sticky note, a frame (a named
    ## area that holds shapes), a picture, a group.
    skDraw = "draw", skHighlight = "highlight", skGeo = "geo", skArrow = "arrow", skLine = "line",
    skText = "text", skNote = "note", skFrame = "frame", skImage = "image", skGroup = "group"
  Arrowhead* = enum
    ## What an end of an arrow or a line ends in.
    ahNone = "none", ahArrow = "arrow", ahTriangle = "triangle", ahDot = "dot",
    ahDiamond = "diamond", ahSquare = "square", ahBar = "bar"

  Terminal* = object
    ## An arrow's end: a point of the page, or held by a shape.
    x*, y*: float            ## where (page units; also where it was, bound)
    bound*: int              ## the shape it holds on to (0: none)
    nx*, ny*: float          ## ... where on it (0..1 of its box)
    precise*: bool           ## ... to that point (else toward its middle, stopping at its edge)

  Shape* = object
    ## A shape of a page: what it is, where, its style and what it holds.
    ## Fields that are for some kinds only say so ("text:", "ink:").
    id*: int                 ## its number on the board (given by `addShape`)
    kind*: ShapeKind         ## what it is
    x*, y*, w*, h*: float    ## its box (page units) before it is turned
    rot*: float              ## turned round its box's middle (radians)
    parent*: int             ## the group it is in (0: none)
    color*: BoardColor       ## its line's, ink's or words' color
    fill*: BoardFill         ## how it is filled
    dash*: BoardDash         ## how its line is drawn
    size*: BoardSize         ## how thick its line is and how big its words are
    font*: BoardFont         ## its words' font
    align*, valign*: BoardAlign  ## where its words stand across and down
    opacity*: float          ## 0..1
    geo*: GeoKind            ## a geometric shape's outline
    flipX*, flipY*: bool     ## mirrored across, down
    text*: string            ## a label, a note's, a text's, a frame's name
    scale*: float            ## how big its words are, times its size's (1)
    autoSize*: bool          ## text: as wide as its words (else wrapped in `w`)
    pts*: seq[InkPoint]      ## ink: its points (from its box's corner); a line: its handles
    isPen*: bool             ## ink drawn with a pen (its pressure real)
    closed*: bool            ## ink: closed (ending where it began)
    spline*: bool            ## a line: smooth through its handles
    t0*, t1*: Terminal       ## an arrow's start and end
    bend*: float             ## ... how far its middle is off the straight line
    head0*, head1*: Arrowhead  ## an arrow's or line's heads at its start and end
    locked*: bool            ## left out when shapes are picked (`topShapeAt` by default, `shapesIn`)
    fillColor*: int          ## the fill's color: 0 the line's, else a `BoardColor` + 1
    roughness*: int          ## how loosely it is drawn by hand: -1 neatly, 0 as a hand, 1 wildly
    round*: bool             ## its corners rounded
    elbow*: bool             ## an arrow: across and down, at right angles
    link*: string            ## a web address it opens
    image*: string           ## a picture's file (PNG or JPEG), kept in the document
    ver*: int                ## (new at each change, never the same twice: what is drawn of it is kept till then)

  Page* = ref object
    ## A page of a board: its shapes and where it was viewed.
    id*: int                 ## its number on the board
    name*: string            ## shown in the list of pages ("Page 1")
    shapes*: seq[Shape]      ## back to front
    camX*, camY*, zoom*: float   ## the view: the page point at the window's corner, the zoom

  Change = object
    name: string
    page: int
    before, after: seq[Shape]
    beforeIds, afterIds: HashSet[int]
    orderBefore, orderAfter: seq[int]
    cost: int                ## (about the bytes it keeps)

  Board* = ref object
    ## A whiteboard document (`newBoard`, `loadBoard`, `boardFrom`): its pages, what
    ## to undo and redo, and the drawings of its shapes kept.
    pages*: seq[Page]        ## in order
    cur*: int                ## the page shown
    nextId*: int             ## the last number given to a shape or page
    name*: string            ## the document's name ("" untitled)
    path*: string            ## its file ("" not saved)
    modified*: bool          ## changed since it was last saved or opened
    ver*: int                ## one more at every change
    dark*: bool              ## drawn for a dark canvas
    paper*: int              ## the canvas's color (`paperColors`; 0 the usual)
    assets*: Table[string, string]
      ## The pictures' bytes (PNG, JPEG), once each -- a picture shape holds
      ## the key of its own (`addAsset`), so a step to undo keeps no copy.
    undos, redos: seq[Change]
    undoCost: int            ## (the bytes the steps to undo and redo keep)
    cacheCost: int           ## (the bytes of the drawings kept)
    depth: int
    pendingName: string
    pending: Table[int, tuple[existed: bool; s: Shape]]
    orderBefore: seq[int]
    cache: Table[int, Drawing]
    briefs: Table[int, Drawing]   ## (shapes too small to read: their brief drawings)
    asked: int                    ## (drawings asked for so far: their age)
    makeLeft: Duration            ## (this frame's time left to make drawings: `startDrawing`)
    budgeted: bool                ## (a frame's time given: `startDrawing` was called)
    behindNow: bool               ## (a shape drawn in brief for want of time)
    stamps: int

  Piece* = object
    ## Outlines filled together in one color (ARGB: its alpha the opacity).
    contours*: seq[seq[(float, float)]]  ## closed outlines (page units)
    color*: uint32                       ## ARGB

  Drawing* = object
    ## What a shape looks like: pieces back to front (page units).
    pieces*: seq[Piece]      ## filled in this order
    key: Hash
    cost: int
    used: int                ## (when it was last asked for: the oldest go first)

  Box* = tuple[x, y, w, h: float]
    ## A rectangle of the page: its corner and size (page units).

  V = tuple[x, y: float]

proc stamp(b: Board): int =
  ## (a shape's version: new each time, on this board)
  inc b.stamps
  b.stamps + 1_000_000

# ---- styles ------------------------------------------------------------------------------------

const
  lightInk: array[BoardColor, uint32] = [0xFF1D1D1D'u32, 0xFF9FA8B2'u32, 0xFFE085F4'u32, 0xFFAE3EC9'u32,
    0xFF4465E9'u32, 0xFF4BA1F1'u32, 0xFFF1AC4B'u32, 0xFFE16919'u32, 0xFF099268'u32, 0xFF4CB05E'u32,
    0xFFF87777'u32, 0xFFE03131'u32, 0xFFFFFFFF'u32]
  darkInk: array[BoardColor, uint32] = [0xFFF2F2F2'u32, 0xFF9398B0'u32, 0xFFE599F7'u32, 0xFFAE3EC9'u32,
    0xFF4F72FC'u32, 0xFF4DABF7'u32, 0xFFFFC034'u32, 0xFFF76707'u32, 0xFF099268'u32, 0xFF40C057'u32,
    0xFFFF8787'u32, 0xFFE03131'u32, 0xFF1D1D1D'u32]
  strokeWidths: array[BoardSize, float] = [2.0, 3.5, 5.0, 10.0]
  fontSizes*: array[BoardSize, float] = [38.0, 48.0, 68.0, 86.0]
    ## The letters of each size (page units): M twice what it was (24),
    ## the others as Excalidraw has them to its M (0.8, 1.4, 1.8 times) --
    ## words as big beside the shapes drawn round them as Excalidraw's on
    ## a tablet, where a page unit is a screen dot at 100 %.
  oldFontSizes: array[BoardSize, float] = [18.0, 24.0, 36.0, 44.0]
    ## (the sizes of a board saved before (its `version` 1): its words are
    ## kept as big as they were, with `scale`)
  BoardFileVersion = 2
    ## (2: the letters of `fontSizes`)
  fontFamilies: array[BoardFont, string] = ["Caveat", "Patrick Hand", "Architects Daughter", "Gochi Hand",
                                            "Indie Flower", "Aref Ruqaa", "FreeSans", "FreeSerif",
                                            "FreeMono", "FreeSerif"]
  fontStyles: array[BoardFont, string] = ["Regular", "Regular", "Regular", "Regular", "Regular", "Regular",
                                          "Regular", "Regular", "Regular", "Italic"]
  fontNames*: array[BoardFont, string] = ["Caveat (handwriting)", "Patrick Hand (marker)",
                                          "Architects Daughter (sketch)", "Gochi Hand (bold marker)",
                                          "Indie Flower (casual)", "Aref Ruqaa (Arabic hand)", "Sans", "Serif",
                                          "Mono", "Italic"]
    ## What the fonts are called (for a menu).
  handFonts = [("Caveat", staticRead("fonts/hand/Caveat.ttf.z")),
               ("Patrick Hand", staticRead("fonts/hand/PatrickHand.ttf.z")),
               ("Architects Daughter", staticRead("fonts/hand/ArchitectsDaughter.ttf.z")),
               ("Gochi Hand", staticRead("fonts/hand/GochiHand.ttf.z")),
               ("Indie Flower", staticRead("fonts/hand/IndieFlower.ttf.z")),
               ("Aref Ruqaa", staticRead("fonts/hand/ArefRuqaa.ttf.z"))]
    ## (SIL Open Font License 1.1: fonts/hand/OFL-*.txt)

var handsAdded = false

proc useHandFonts*() =
  ## The board's handwriting fonts offered to the text engine (once), and
  ## its serif and mono faces unpacked on the same thread meanwhile (the
  ## Text panel's samples draw them at the start; LZMA's, unpacked when
  ## first drawn, made the first frame 30 ms later).
  if handsAdded: return
  handsAdded = true
  for (family, data) in handFonts: addFontData(family, "Regular", data, packed = true)
  unpackFacesSoon([FaceId.fSerif, FaceId.fSerifItalic, FaceId.fMono])

proc familyOf*(f: BoardFont): string = fontFamilies[f]
  ## The font family a board font is.

proc mixArgb(a, b: uint32; t: float): uint32 =
  ## (`a` toward `b` by `t`, alpha from `a`)
  proc ch(v: uint32; s: int): float = float((v shr s) and 255)
  let r = ch(a, 16) + (ch(b, 16) - ch(a, 16)) * t
  let g = ch(a, 8) + (ch(b, 8) - ch(a, 8)) * t
  let bl = ch(a, 0) + (ch(b, 0) - ch(a, 0)) * t
  (a and 0xFF000000'u32) or (uint32(clamp(r, 0, 255)) shl 16) or (uint32(clamp(g, 0, 255)) shl 8) or
    uint32(clamp(bl, 0, 255))

proc withAlpha(c: uint32; a: float): uint32 =
  (c and 0xFFFFFF'u32) or (uint32(clamp(a, 0.0, 1.0) * float((c shr 24) and 255)) shl 24)

proc paper*(dark: bool): uint32 = (if dark: 0xFF101011'u32 else: 0xFFF9FAFB'u32)
  ## The canvas's usual color.

const paperColors*: array[7, tuple[name: string; light, dark: uint32]] = [
  ("Usual", 0xFFF9FAFB'u32, 0xFF101011'u32), ("White", 0xFFFFFFFF'u32, 0xFF1E1E1E'u32),
  ("Cream", 0xFFF6F1E7'u32, 0xFF24211B'u32), ("Gray", 0xFFECEEF1'u32, 0xFF202226'u32),
  ("Blue", 0xFFEAF2FB'u32, 0xFF141E29'u32), ("Green", 0xFFECF5EA'u32, 0xFF16211A'u32),
  ("Rose", 0xFFFBEEF0'u32, 0xFF261A1C'u32)]
  ## The canvas's colors to choose from (light, dark).


proc inkOf*(c: BoardColor; dark = false): uint32 =
  ## A color's ink (lines, text).
  if dark: darkInk[c] else: lightInk[c]

proc semiOf*(c: BoardColor; dark = false): uint32 =
  ## Its light fill ("semi").
  if dark: mixArgb(darkInk[c], 0xFF101011'u32, 0.78) else: mixArgb(lightInk[c], 0xFFFFFFFF'u32, 0.84)

proc noteOf*(c: BoardColor; dark = false): uint32 =
  ## A sticky note's paper in that color.
  if c == bcWhite: return (if dark: 0xFF2C2C2E'u32 else: 0xFFFFFFFF'u32)
  if c == bcBlack: return (if dark: 0xFF3A3A3D'u32 else: 0xFFE8E8E8'u32)
  if dark: mixArgb(darkInk[c], 0xFF101011'u32, 0.45) else: mixArgb(lightInk[c], 0xFFFFFFFF'u32, 0.55)

proc fillOf*(s: Shape): BoardColor =
  ## The color its fill is in: its own, or its line's.
  if s.fillColor > 0 and s.fillColor <= ord(BoardColor.high) + 1: BoardColor(s.fillColor - 1) else: s.color

proc strokeWidth*(s: BoardSize): float = strokeWidths[s]
  ## How thick a line of that size is.

# ---- the document ------------------------------------------------------------------------------

proc paperOf*(b: Board): uint32 =
  ## The board's canvas color, light or dark as it is drawn.
  let c = paperColors[clamp(b.paper, 0, paperColors.high)]
  if b.dark: c.dark else: c.light

proc newPage*(b: Board; name: string): Page =
  ## A new empty page called `name`, with the board's next number (not yet
  ## among `b.pages`: add it there).
  inc b.nextId
  Page(id: b.nextId, name: name, zoom: 1)

proc newBoard*(): Board =
  ## An empty board of one page.
  result = Board(nextId: 0)
  result.pages.add result.newPage("Page 1")

proc page*(b: Board): Page = b.pages[clamp(b.cur, 0, b.pages.high)]
  ## The page shown.

proc indexOf*(p: Page; id: int): int =
  ## Where shape `id` is in `p.shapes` (-1: not on the page).
  for i, s in p.shapes:
    if s.id == id: return i
  -1

proc find*(b: Board; id: int): ptr Shape =
  ## The shape `id` of the page shown (nil: none).
  let i = b.page.indexOf(id)
  if i < 0: nil else: addr b.page.shapes[i]

proc has*(b: Board; id: int): bool = b.page.indexOf(id) >= 0
  ## Shape `id` is on the page shown.

proc newShape*(b: Board; kind: ShapeKind; x, y, w, h: float): Shape =
  ## A shape with the usual style (`id` given when it is added).
  Shape(kind: kind, x: x, y: y, w: w, h: h, opacity: 1, scale: 1, color: bcBlack, fill: bfNone,
        dash: bdDraw, size: bsM, font: bfnHand, align: baMiddle, valign: baMiddle, head1: ahArrow)

# ---- changes, undo and redo ----------------------------------------------------------------

var
  undoBudget* = 16 * 1024 * 1024
    ## About how many bytes the steps to undo may keep (the oldest go first;
    ## 300 steps at most).
  drawingBudget* = 32 * 1024 * 1024
    ## About how many bytes the drawings kept may take (all made again when
    ## more).

proc shapeCost(s: Shape): int {.inline.} = 200 + s.text.len + s.pts.len * sizeof(InkPoint) + s.image.len

proc addAsset*(b: Board; data: string): string =
  ## Keeps a picture's bytes in the board (once: the same bytes, the same
  ## key); the key to put in `Shape.image`.
  result = "asset:" & toHex(hash(data).int64 and 0x7FFFFFFFFFFFFFFF'i64, 16) & ":" & $data.len
  if result notin b.assets: b.assets[result] = data

proc assetOf*(b: Board; key: string): string =
  ## A picture's bytes by its key ("" none).
  if key.startsWith("asset:"): b.assets.getOrDefault(key, "") else: key

proc begin*(b: Board; name: string) =
  ## A change named `name` begins (`commit` ends it; nested ones join it).
  if b.depth == 0:
    b.pending.clear()
    b.pendingName = name
    b.orderBefore.setLen(0)
    for s in b.page.shapes: b.orderBefore.add s.id
  inc b.depth

proc touch*(b: Board; id: int) =
  ## Tells the board that shape `id` is about to change (inside `change`,
  ## or between `begin` and `commit`): it is kept as it is, for undo.
  ## Nothing outside a change.
  if b.depth == 0 or id in b.pending: return
  let i = b.page.indexOf(id)
  if i >= 0: b.pending[id] = (true, b.page.shapes[i])
  else: b.pending[id] = (false, Shape())

proc commit*(b: Board) =
  ## Ends the change: one step to undo.
  if b.depth == 0: return
  dec b.depth
  if b.depth > 0: return
  var c = Change(name: b.pendingName, page: b.cur, orderBefore: b.orderBefore)
  for s in b.page.shapes: c.orderAfter.add s.id
  var changed = c.orderBefore != c.orderAfter
  for id, was in b.pending:
    let i = b.page.indexOf(id)
    if was.existed:
      c.before.add was.s
      c.beforeIds.incl id
    if i >= 0:
      c.after.add b.page.shapes[i]
      c.afterIds.incl id
    if was.existed != (i >= 0) or (i >= 0 and was.s != b.page.shapes[i]): changed = true
  b.pending.clear()
  if not changed: return
  for s in c.before: c.cost += shapeCost(s)
  for s in c.after: c.cost += shapeCost(s)
  c.cost += (c.orderBefore.len + c.orderAfter.len) * sizeof(int)
  for r in b.redos: b.undoCost -= r.cost
  b.redos.setLen(0)
  b.undos.add c
  b.undoCost += c.cost
  # (the oldest steps go: 300 at most, and no more bytes than the budget)
  var drop = 0
  while drop < b.undos.len - 1 and (b.undos.len - drop > 300 or b.undoCost > undoBudget):
    b.undoCost -= b.undos[drop].cost
    inc drop
  if drop > 0: b.undos = b.undos[drop .. ^1]
  b.modified = true
  inc b.ver

template change*(b: Board; name: string; body: untyped) =
  ## A change to undo as one step.
  b.begin(name)
  try: body
  finally: b.commit()

proc cancelChange*(b: Board) =
  ## The change under way taken back (as it was when it began).
  if b.depth == 0: return
  b.depth = 1
  var byId: Table[int, Shape]
  for s in b.page.shapes: byId[s.id] = s
  for id, was in b.pending:
    if was.existed: byId[id] = was.s else: byId.del id
  var shapes: seq[Shape]
  for id in b.orderBefore:
    if id in byId: shapes.add byId[id]
  b.page.shapes = shapes
  b.pending.clear()
  b.depth = 0
  inc b.ver

proc apply(b: Board; c: Change; undo: bool) =
  b.cur = clamp(c.page, 0, b.pages.high)
  var byId: Table[int, Shape]
  for s in b.page.shapes: byId[s.id] = s
  let (gone, back, order) = if undo: (c.afterIds, c.before, c.orderBefore)
                            else: (c.beforeIds, c.after, c.orderAfter)
  for id in gone: byId.del id
  for s in back:
    var t = s
    t.ver = b.stamp
    byId[s.id] = t
  var shapes: seq[Shape]
  for id in order:
    if id in byId: shapes.add byId[id]
  b.page.shapes = shapes
  b.modified = true
  inc b.ver

proc clearHistory*(b: Board) =
  ## Forgets what could be undone and redone (pages taken away, a file opened).
  b.undos.setLen(0)
  b.redos.setLen(0)
  b.undoCost = 0

proc historyBytes*(b: Board): int = b.undoCost
  ## About how many bytes the steps to undo and redo keep.

proc canUndo*(b: Board): bool = b.undos.len > 0 and b.depth == 0
  ## There is a change to take back (and no `change` is under way).
proc canRedo*(b: Board): bool = b.redos.len > 0 and b.depth == 0
  ## There is a change taken back to make again (and no `change` is under way).
proc undoName*(b: Board): string = (if b.undos.len > 0: b.undos[^1].name else: "")
  ## The name of the change `undo` takes back, for the Edit menu ("Move"; "" none).
proc redoName*(b: Board): string = (if b.redos.len > 0: b.redos[^1].name else: "")
  ## The name of the change `redo` makes again ("" none).

proc undo*(b: Board) =
  ## Takes back the last change.
  if not b.canUndo: return
  let c = b.undos.pop()
  b.apply(c, true)
  b.redos.add c

proc redo*(b: Board) =
  ## Does the change taken back again.
  if not b.canRedo: return
  let c = b.redos.pop()
  b.apply(c, false)
  b.undos.add c

proc addShape*(b: Board; s: Shape; above = -1; keepId = false): int {.discardable.} =
  ## Puts `s` on the page shown (on top; or above the shape `above`), with an
  ## id of its own (or its own id, `keepId`: one taken away, put back); its id.
  var t = s
  if not keepId or t.id <= 0 or b.page.indexOf(t.id) >= 0:
    inc b.nextId
    t.id = b.nextId
  else: b.nextId = max(b.nextId, t.id)
  t.ver = b.stamp
  b.touch(t.id)
  let i = if above > 0: b.page.indexOf(above) else: -1
  if i >= 0: b.page.shapes.insert(t, i + 1) else: b.page.shapes.add t
  inc b.ver
  t.id

proc update*(b: Board; id: int; f: proc (s: var Shape)) =
  ## Changes shape `id` (kept for undo when a change is under way).
  let i = b.page.indexOf(id)
  if i < 0: return
  b.touch(id)
  f(b.page.shapes[i])
  b.page.shapes[i].ver = b.stamp
  inc b.ver

proc setShape*(b: Board; s: Shape) =
  ## Shape `s.id` becomes `s`.
  let i = b.page.indexOf(s.id)
  if i < 0: return
  b.touch(s.id)
  var t = s
  t.ver = b.stamp
  b.page.shapes[i] = t
  inc b.ver

proc removeShape*(b: Board; id: int) =
  ## Takes shape `id` away (and what is in it, a group's; arrows let go of it).
  let i = b.page.indexOf(id)
  if i < 0: return
  b.touch(id)
  let kind = b.page.shapes[i].kind
  b.page.shapes.delete(i)
  if kind == skGroup:
    var kids: seq[int]
    for s in b.page.shapes:
      if s.parent == id: kids.add s.id
    for k in kids: b.removeShape(k)
  for k in 0 ..< b.page.shapes.len:
    let s = addr b.page.shapes[k]
    if s.kind == skArrow and (s.t0.bound == id or s.t1.bound == id):
      b.touch(s.id)
      if s.t0.bound == id: s.t0.bound = 0
      if s.t1.bound == id: s.t1.bound = 0
      s.ver = b.stamp
  inc b.ver

proc reorder*(b: Board; ids: openArray[int]; how: string) =
  ## Brings `ids` "front", "forward", sends them "backward", "back".
  let sel = toHashSet(ids)
  var p = b.page
  case how
  of "front", "back":
    var moved, rest: seq[Shape]
    for s in p.shapes:
      if s.id in sel: moved.add s else: rest.add s
    p.shapes = if how == "front": rest & moved else: moved & rest
  of "forward":
    var i = p.shapes.high - 1
    while i >= 0:
      if p.shapes[i].id in sel and p.shapes[i + 1].id notin sel: swap(p.shapes[i], p.shapes[i + 1])
      dec i
  of "backward":
    for i in 1 .. p.shapes.high:
      if p.shapes[i].id in sel and p.shapes[i - 1].id notin sel: swap(p.shapes[i], p.shapes[i - 1])
  else: discard
  inc b.ver

# ---- geometry ----------------------------------------------------------------------------------

proc center*(s: Shape): V = (s.x + s.w / 2, s.y + s.h / 2)
  ## The middle of its box.

proc toPage*(s: Shape; lx, ly: float): V =
  ## A point of its box (from its corner, before turning) on the page.
  if s.rot == 0: return (s.x + lx, s.y + ly)
  let c = s.center
  let dx = s.x + lx - c.x
  let dy = s.y + ly - c.y
  let co = cos(s.rot)
  let si = sin(s.rot)
  (c.x + dx * co - dy * si, c.y + dx * si + dy * co)

proc toLocal*(s: Shape; px, py: float): V =
  ## A page point in its box's terms (from its corner, as if not turned).
  if s.rot == 0: return (px - s.x, py - s.y)
  let c = s.center
  let dx = px - c.x
  let dy = py - c.y
  let co = cos(-s.rot)
  let si = sin(-s.rot)
  (c.x + dx * co - dy * si - s.x, c.y + dx * si + dy * co - s.y)

proc boxOf(pts: openArray[V]): Box =
  if pts.len == 0: return (0.0, 0.0, 0.0, 0.0)
  var x0, y0 = 1e300
  var x1, y1 = -1e300
  for p in pts:
    x0 = min(x0, p.x); y0 = min(y0, p.y); x1 = max(x1, p.x); y1 = max(y1, p.y)
  (x0, y0, x1 - x0, y1 - y0)

proc union*(a, b: Box): Box =
  ## The smallest box holding both (an all-zero `a` counts as no box: `b`).
  if a.w <= 0 and a.h <= 0 and a.x == 0 and a.y == 0: return b
  let x0 = min(a.x, b.x)
  let y0 = min(a.y, b.y)
  (x0, y0, max(a.x + a.w, b.x + b.w) - x0, max(a.y + a.h, b.y + b.h) - y0)

proc overlaps*(a, b: Box): bool =
  ## The boxes meet (touching edges count).
  a.x <= b.x + b.w and b.x <= a.x + a.w and a.y <= b.y + b.h and b.y <= a.y + a.h

proc contains*(a: Box; x, y: float): bool = x >= a.x and y >= a.y and x <= a.x + a.w and y <= a.y + a.h
  ## The point (`x`, `y`) is in the box (its edges count).

proc ellipsePts(cx, cy, rx, ry: float; n = 0): seq[V] =
  let k = if n > 0: n else: clamp(int((rx + ry) / 3), 24, 96)
  for i in 0 ..< k:
    let a = 2 * PI * i.float / k.float
    result.add (cx + cos(a) * rx, cy + sin(a) * ry)

proc regular(w, h: float; n: int; start = -PI / 2): seq[V] =
  for i in 0 ..< n:
    let a = start + 2 * PI * i.float / n.float
    result.add (w / 2 + cos(a) * w / 2, h / 2 + sin(a) * h / 2)

proc geoOutline*(g: GeoKind; w, h: float): seq[V] =
  ## A shape's outline in its box (`w` x `h`), clockwise on the screen.
  case g
  of gkRectangle, gkCheckBox, gkXBox: @[(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)]
  of gkEllipse: ellipsePts(w / 2, h / 2, w / 2, h / 2)
  of gkTriangle: @[(w / 2, 0.0), (w, h), (0.0, h)]
  of gkDiamond: @[(w / 2, 0.0), (w, h / 2), (w / 2, h), (0.0, h / 2)]
  of gkPentagon: regular(w, h, 5)
  of gkHexagon: regular(w, h, 6, 0)
  of gkOctagon: regular(w, h, 8, PI / 8)
  of gkStar:
    var r: seq[V]
    for i in 0 ..< 10:
      let a = -PI / 2 + PI * i.float / 5
      let k = if i mod 2 == 0: 1.0 else: 0.42
      r.add (w / 2 + cos(a) * w / 2 * k, h / 2 + sin(a) * h / 2 * k)
    r
  of gkRhombus:
    let o = min(w * 0.25, h)
    @[(o, 0.0), (w, 0.0), (w - o, h), (0.0, h)]
  of gkTrapezoid:
    let o = min(w * 0.2, h)
    @[(o, 0.0), (w - o, 0.0), (w, h), (0.0, h)]
  of gkOval:
    var r: seq[V]
    if w >= h:
      let rad = h / 2
      for i in 0 .. 16: r.add (w - rad + cos(-PI / 2 + PI * i.float / 16) * rad, rad + sin(-PI / 2 + PI * i.float / 16) * rad)
      for i in 0 .. 16: r.add (rad + cos(PI / 2 + PI * i.float / 16) * rad, rad + sin(PI / 2 + PI * i.float / 16) * rad)
    else:
      let rad = w / 2
      for i in 0 .. 16: r.add (rad + cos(PI + PI * i.float / 16) * rad, rad + sin(PI + PI * i.float / 16) * rad)
      for i in 0 .. 16: r.add (rad + cos(PI * i.float / 16) * rad, h - rad + sin(PI * i.float / 16) * rad)
    r
  of gkCloud:
    # (bumps round an ellipse)
    var r: seq[V]
    let n = 9
    for i in 0 ..< n:
      let a0 = 2 * PI * i.float / n.float
      let a1 = 2 * PI * (i + 1).float / n.float
      for k in 0 .. 8:
        let t = k.float / 8
        let a = a0 + (a1 - a0) * t
        let bump = 1 + 0.16 * sin(PI * t)
        r.add (w / 2 + cos(a) * w / 2 * 0.86 * bump, h / 2 + sin(a) * h / 2 * 0.86 * bump)
    r
  of gkHeart:
    var r: seq[V]
    for i in 0 ..< 64:
      let t = 2 * PI * i.float / 64
      let x = 16 * pow(sin(t), 3)
      let y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
      r.add (w / 2 + x / 34 * w, h * 0.42 - y / 30 * h)
    r
  of gkArrowRight:
    let s = min(h * 0.5, w * 0.5)
    @[(0.0, h * 0.3), (w - s, h * 0.3), (w - s, 0.0), (w, h / 2), (w - s, h), (w - s, h * 0.7), (0.0, h * 0.7)]
  of gkArrowLeft:
    let s = min(h * 0.5, w * 0.5)
    @[(0.0, h / 2), (s, 0.0), (s, h * 0.3), (w, h * 0.3), (w, h * 0.7), (s, h * 0.7), (s, h)]
  of gkArrowUp:
    let s = min(w * 0.5, h * 0.5)
    @[(w / 2, 0.0), (w, s), (w * 0.7, s), (w * 0.7, h), (w * 0.3, h), (w * 0.3, s), (0.0, s)]
  of gkArrowDown:
    let s = min(w * 0.5, h * 0.5)
    @[(w * 0.3, 0.0), (w * 0.7, 0.0), (w * 0.7, h - s), (w, h - s), (w / 2, h), (0.0, h - s), (w * 0.3, h - s)]
  of gkRoundRect:
    let r = min(min(w, h) * 0.22, 36.0)
    var o: seq[V]
    for (cx, cy, a0) in [(w - r, r, -PI / 2), (w - r, h - r, 0.0), (r, h - r, PI / 2), (r, r, PI)]:
      for k in 0 .. 6:
        let a = a0 + PI / 2 * k.float / 6
        o.add (cx + cos(a) * r, cy + sin(a) * r)
    o
  of gkRightTriangle: @[(0.0, 0.0), (w, h), (0.0, h)]
  of gkCylinder:
    # (the top's far half, the sides, the bottom's near half)
    let ry = min(h * 0.18, w * 0.25)
    var o: seq[V]
    for k in 0 .. 16:
      let a = PI + PI * k.float / 16
      o.add (w / 2 + cos(a) * w / 2, ry + sin(a) * ry)
    for k in 0 .. 16:
      let a = PI * k.float / 16
      o.add (w / 2 + cos(a) * w / 2, h - ry + sin(a) * ry)
    o
  of gkDocument:
    # (a page whose foot is a wave)
    var o: seq[V] = @[(0.0, 0.0), (w, 0.0)]
    let wave = h * 0.08
    for k in 0 .. 24:
      let t = 1 - k.float / 24
      o.add (w * t, h - wave + sin(t * 2 * PI) * wave)
    o
  of gkSpeech:
    # (a rounded box with a tail at its foot)
    let bh = h * 0.78
    let r = min(min(w, bh) * 0.2, 30.0)
    var o: seq[V]
    for (cx, cy, a0) in [(w - r, r, -PI / 2), (w - r, bh - r, 0.0)]:
      for k in 0 .. 6:
        let a = a0 + PI / 2 * k.float / 6
        o.add (cx + cos(a) * r, cy + sin(a) * r)
    o.add (w * 0.42, bh)
    o.add (w * 0.2, h)
    o.add (w * 0.26, bh)
    for (cx, cy, a0) in [(r, bh - r, PI / 2), (r, r, PI)]:
      for k in 0 .. 6:
        let a = a0 + PI / 2 * k.float / 6
        o.add (cx + cos(a) * r, cy + sin(a) * r)
    o
  of gkCross:
    let a = w * 0.32
    let b = h * 0.32
    @[(a, 0.0), (w - a, 0.0), (w - a, b), (w, b), (w, h - b), (w - a, h - b), (w - a, h), (a, h), (a, h - b),
      (0.0, h - b), (0.0, b), (a, b)]
  of gkDoubleArrow:
    let s = min(h * 0.5, w * 0.3)
    @[(0.0, h / 2), (s, 0.0), (s, h * 0.3), (w - s, h * 0.3), (w - s, 0.0), (w, h / 2), (w - s, h),
      (w - s, h * 0.7), (s, h * 0.7), (s, h)]
  of gkChevron:
    let s = min(w * 0.35, h * 0.5)
    @[(0.0, 0.0), (w - s, 0.0), (w, h / 2), (w - s, h), (0.0, h), (s, h / 2)]
  of gkLightning:
    @[(w * 0.55, 0.0), (w * 0.12, h * 0.56), (w * 0.45, h * 0.56), (w * 0.3, h), (w * 0.88, h * 0.4),
      (w * 0.55, h * 0.4), (w * 0.78, 0.0)]
  of gkMoon:
    # (a crescent: the outer circle's arc, back along a smaller one)
    var o: seq[V]
    for k in 0 .. 32:
      let a = PI * 0.3 + (2 * PI - PI * 0.6) * k.float / 32
      o.add (w / 2 + cos(a) * w / 2, h / 2 + sin(a) * h / 2)
    let a1 = PI * 0.3
    let p0: V = (w / 2 + cos(-a1) * w / 2, h / 2 + sin(-a1) * h / 2)
    let p1: V = (w / 2 + cos(a1) * w / 2, h / 2 + sin(a1) * h / 2)
    # (back from the lower tip to the upper through a point inside)
    let m: V = (w * 0.18, h / 2)
    for k in 1 .. 15:
      let t = k.float / 16
      let u = 1 - t
      o.add (u * u * p1.x + 2 * u * t * m.x + t * t * p0.x - 0.0, u * u * p1.y + 2 * u * t * m.y + t * t * p0.y)
    o
  of gkCube:
    let d = min(w, h) * 0.25
    @[(0.0, d), (d, 0.0), (w, 0.0), (w, h - d), (w - d, h), (0.0, h)]
  of gkPerson:
    # (a head over shoulders)
    let r = min(w * 0.22, h * 0.2)
    var o: seq[V]
    let cy = r
    let neck = 0.55
    for k in 0 .. 24:
      let a = PI / 2 + neck + (2 * PI - 2 * neck) * k.float / 24
      o.add (w / 2 + cos(a) * r, cy + sin(a) * r)
    let sh = cy + r * 1.35
    o.add (w * 0.82, sh)
    for k in 0 .. 8:
      let a = -PI / 2 + PI / 2 * k.float / 8
      o.add (w * 0.82 + cos(a) * w * 0.18, sh + w * 0.18 + sin(a) * w * 0.18)
    o.add (w, h)
    o.add (0.0, h)
    for k in 0 .. 8:
      let a = PI + PI / 2 * k.float / 8
      o.add (w * 0.18 + cos(a) * w * 0.18, sh + w * 0.18 + sin(a) * w * 0.18)
    o.add (w * 0.18, sh)
    o

proc geoDetails*(g: GeoKind; w, h: float): seq[seq[V]] =
  ## The lines drawn inside a shape besides its outline (a check box's tick,
  ## a cylinder's rim, a cube's edges), in its box.
  case g
  of gkCheckBox: @[@[(w * 0.25, h * 0.52), (w * 0.45, h * 0.72), (w * 0.76, h * 0.3)]]
  of gkXBox: @[@[(0.0, 0.0), (w, h)], @[(w, 0.0), (0.0, h)]]
  of gkCylinder:
    let ry = min(h * 0.18, w * 0.25)
    var rim: seq[V]
    for k in 0 .. 16:
      let a = PI * k.float / 16
      rim.add (w / 2 + cos(a) * w / 2, ry + sin(a) * ry)
    @[rim]
  of gkCube:
    let d = min(w, h) * 0.25
    @[@[(0.0, d), (w - d, d), (w, 0.0)], @[(w - d, d), (w - d, h)]]
  else: @[]

const cornered = {gkRectangle, gkTriangle, gkDiamond, gkPentagon, gkHexagon, gkOctagon, gkStar, gkRhombus,
                  gkTrapezoid, gkCheckBox, gkXBox, gkArrowRight, gkArrowLeft, gkArrowUp, gkArrowDown,
                  gkRightTriangle, gkCross, gkDoubleArrow, gkChevron, gkLightning, gkCube}
  ## (the shapes whose corners can be rounded)

proc roundCorners*(poly: seq[V]; r: float): seq[V] =
  ## A polygon with its corners rounded (`r` along each side, at most
  ## nearly half of it).
  let n = poly.len
  if n < 3 or r <= 0: return poly
  for i in 0 ..< n:
    let p = poly[(i - 1 + n) mod n]
    let v = poly[i]
    let q = poly[(i + 1) mod n]
    let d1 = hypot(p.x - v.x, p.y - v.y)
    let d2 = hypot(q.x - v.x, q.y - v.y)
    if d1 < 1e-9 or d2 < 1e-9: continue
    let rr = min(r, min(d1, d2) * 0.45)
    let a: V = (v.x + (p.x - v.x) * rr / d1, v.y + (p.y - v.y) * rr / d1)
    let c: V = (v.x + (q.x - v.x) * rr / d2, v.y + (q.y - v.y) * rr / d2)
    for k in 0 .. 6:
      let t = k.float / 6
      let u = 1 - t
      result.add (u * u * a.x + 2 * u * t * v.x + t * t * c.x, u * u * a.y + 2 * u * t * v.y + t * t * c.y)

proc localOutline*(s: Shape): seq[V] =
  ## Its outline in its box (flipped as it is; its corners rounded, asked).
  result = case s.kind
           of skGeo: geoOutline(s.geo, s.w, s.h)
           else: @[(0.0, 0.0), (s.w, 0.0), (s.w, s.h), (0.0, s.h)]
  if s.round and ((s.kind == skGeo and s.geo in cornered) or s.kind in {skFrame, skImage}):
    result = roundCorners(result, min(min(s.w, s.h) * 0.16, 28.0))
  if s.flipX or s.flipY:
    for p in result.mitems:
      if s.flipX: p.x = s.w - p.x
      if s.flipY: p.y = s.h - p.y

proc pageOutline*(s: Shape): seq[V] =
  ## Its outline on the page.
  for p in s.localOutline: result.add s.toPage(p.x, p.y)

proc inkPoints(s: Shape): seq[V] =
  for p in s.pts: result.add s.toPage(p.x.float, p.y.float)

# ---- arrows ------------------------------------------------------------------------------------

proc segHit(a, b, c, d: V): (bool, float) =
  ## (segment a-b crosses c-d: where along a-b, 0..1)
  let r = (b.x - a.x, b.y - a.y)
  let s = (d.x - c.x, d.y - c.y)
  let den = r[0] * s[1] - r[1] * s[0]
  if abs(den) < 1e-12: return (false, 0.0)
  let t = ((c.x - a.x) * s[1] - (c.y - a.y) * s[0]) / den
  let u = ((c.x - a.x) * r[1] - (c.y - a.y) * r[0]) / den
  if t >= 0 and t <= 1 and u >= 0 and u <= 1: (true, t) else: (false, 0.0)

proc terminalPoint*(b: Board; t: Terminal; other: V; gap = 0.0): V =
  ## Where an arrow's end is: its point; or on the shape it holds -- that
  ## point of it, or where the line from `other` toward its middle meets its
  ## edge (`gap` short of it).
  if t.bound == 0: return (t.x, t.y)
  let ts = b.find(t.bound)
  if ts == nil: return (t.x, t.y)
  if t.precise: return ts[].toPage(t.nx * ts.w, t.ny * ts.h)
  let c = ts[].toPage(ts.w / 2, ts.h / 2)
  let ol = ts[].pageOutline
  var best = -1.0
  for i in 0 ..< ol.len:
    let (hit, u) = segHit(other, c, ol[i], ol[(i + 1) mod ol.len])
    if hit and u > best: discard
    if hit and (best < 0 or u < best): best = u
  if best < 0: return c
  let p: V = (other.x + (c.x - other.x) * best, other.y + (c.y - other.y) * best)
  let d = hypot(c.x - other.x, c.y - other.y)
  if d < 1e-9 or gap <= 0: return p
  (p.x - (c.x - other.x) / d * gap, p.y - (c.y - other.y) / d * gap)

proc elbowPath*(b: Board; s: Shape): seq[V] =
  ## An elbow arrow's line: across and down at right angles, its ends on the
  ## sides of the shapes it holds, facing each other.
  let gap = strokeWidths[s.size] + 3
  proc endOf(t: Terminal): tuple[held: bool; box: Box; p: V] =
    if t.bound != 0:
      let o = b.find(t.bound)
      if o != nil:
        let bx = boxOf(o[].pageOutline)
        return (true, bx, (bx.x + bx.w / 2, bx.y + bx.h / 2))
    (false, (t.x, t.y, 0.0, 0.0), (t.x, t.y))
  let e0 = endOf(s.t0)
  let e1 = endOf(s.t1)
  let horiz = abs(e1.p.x - e0.p.x) >= abs(e1.p.y - e0.p.y)
  proc side(e: tuple[held: bool; box: Box; p: V]; toward: V): V =
    if not e.held: return e.p
    if horiz:
      if toward.x >= e.p.x: (e.box.x + e.box.w + gap, e.p.y) else: (e.box.x - gap, e.p.y)
    else:
      if toward.y >= e.p.y: (e.p.x, e.box.y + e.box.h + gap) else: (e.p.x, e.box.y - gap)
  let a = side(e0, e1.p)
  let c = side(e1, e0.p)
  var pts: seq[V]
  if horiz:
    let mx = (a.x + c.x) / 2
    pts = @[a, (mx, a.y), (mx, c.y), c]
  else:
    let my = (a.y + c.y) / 2
    pts = @[a, (a.x, my), (c.x, my), c]
  for p in pts:
    if result.len == 0 or hypot(p.x - result[^1].x, p.y - result[^1].y) > 0.01: result.add p
  if result.len == 1: result.add c

proc arrowEnds*(b: Board; s: Shape): (V, V) =
  ## An arrow's start and end on the page (where they meet the shapes held).
  if s.elbow:
    let p = b.elbowPath(s)
    return (p[0], p[^1])
  let gap = strokeWidths[s.size] + 3
  let a0: V = (s.t0.x, s.t0.y)
  let b0: V = (s.t1.x, s.t1.y)
  # (each end toward the other's first guess: the shapes' middles)
  let ra = if s.t0.bound != 0 and b.find(s.t0.bound) != nil and not s.t0.precise:
             b.find(s.t0.bound)[].toPage(b.find(s.t0.bound).w / 2, b.find(s.t0.bound).h / 2) else: b.terminalPoint(s.t0, b0)
  let rb = if s.t1.bound != 0 and b.find(s.t1.bound) != nil and not s.t1.precise:
             b.find(s.t1.bound)[].toPage(b.find(s.t1.bound).w / 2, b.find(s.t1.bound).h / 2) else: b.terminalPoint(s.t1, a0)
  (b.terminalPoint(s.t0, rb, gap), b.terminalPoint(s.t1, ra, gap))

proc arcThrough(a, m, c: V; n = 32): seq[V] =
  ## (points of the circle through three points, from `a` by `m` to `c`)
  let d = 2 * (a.x * (m.y - c.y) + m.x * (c.y - a.y) + c.x * (a.y - m.y))
  if abs(d) < 1e-9: return @[a, c]
  let ux = ((a.x * a.x + a.y * a.y) * (m.y - c.y) + (m.x * m.x + m.y * m.y) * (c.y - a.y) +
            (c.x * c.x + c.y * c.y) * (a.y - m.y)) / d
  let uy = ((a.x * a.x + a.y * a.y) * (c.x - m.x) + (m.x * m.x + m.y * m.y) * (a.x - c.x) +
            (c.x * c.x + c.y * c.y) * (m.x - a.x)) / d
  let r = hypot(a.x - ux, a.y - uy)
  var a0 = arctan2(a.y - uy, a.x - ux)
  let am = arctan2(m.y - uy, m.x - ux)
  var a1 = arctan2(c.y - uy, c.x - ux)
  # (the way round that passes `m`)
  proc between(x, lo, hi: float): bool =
    var t = x
    while t < lo: t += 2 * PI
    t <= hi
  var lo = a0
  var hi = a1
  while hi < lo: hi += 2 * PI
  if not between(am, lo, hi):
    hi -= 2 * PI
  for i in 0 .. n:
    let t = lo + (hi - lo) * i.float / n.float
    result.add (ux + cos(t) * r, uy + sin(t) * r)
  discard a0
  discard a1

proc arrowPath*(b: Board; s: Shape): seq[V] =
  ## The arrow's line on the page: straight, bent through its middle, or
  ## at right angles (an elbow arrow).
  if s.elbow: return b.elbowPath(s)
  let (a, c) = b.arrowEnds(s)
  if abs(s.bend) < 0.5: return @[a, c]
  let d = hypot(c.x - a.x, c.y - a.y)
  if d < 1e-6: return @[a, c]
  let nx = -(c.y - a.y) / d
  let ny = (c.x - a.x) / d
  let m: V = ((a.x + c.x) / 2 + nx * s.bend, (a.y + c.y) / 2 + ny * s.bend)
  arcThrough(a, m, c, clamp(int(d / 12), 12, 64))

proc arrowMiddle*(b: Board; s: Shape): V =
  ## The point of its bend handle (and its label).
  if s.elbow:
    # (half way along it)
    let p = b.elbowPath(s)
    var total = 0.0
    for i in 1 ..< p.len: total += hypot(p[i].x - p[i - 1].x, p[i].y - p[i - 1].y)
    var left = total / 2
    for i in 1 ..< p.len:
      let d = hypot(p[i].x - p[i - 1].x, p[i].y - p[i - 1].y)
      if d >= left and d > 0:
        return (p[i - 1].x + (p[i].x - p[i - 1].x) * left / d, p[i - 1].y + (p[i].y - p[i - 1].y) * left / d)
      left -= d
    return p[^1]
  let (a, c) = b.arrowEnds(s)
  let d = hypot(c.x - a.x, c.y - a.y)
  if d < 1e-6: return a
  ((a.x + c.x) / 2 - (c.y - a.y) / d * s.bend, (a.y + c.y) / 2 + (c.x - a.x) / d * s.bend)

# ---- outlines of strokes ---------------------------------------------------------------------

proc ccw(c: seq[(float, float)]): seq[(float, float)] =
  ## (turned the one way: overlapping parts join)
  var a = 0.0
  for i in 0 ..< c.len:
    let p = c[i]
    let q = c[(i + 1) mod c.len]
    a += p[0] * q[1] - q[0] * p[1]
  if a < 0:
    for i in countdown(c.high, 0): result.add c[i]
  else: result = c

proc disc(c: V; r: float; n = 10): seq[(float, float)] =
  for i in 0 ..< n:
    let a = 2 * PI * i.float / n.float
    result.add (c.x + cos(a) * r, c.y + sin(a) * r)

proc segQuad(a, c: V; r: float): seq[(float, float)] =
  let d = hypot(c.x - a.x, c.y - a.y)
  if d < 1e-9: return
  let nx = -(c.y - a.y) / d * r
  let ny = (c.x - a.x) / d * r
  ccw(@[(a.x + nx, a.y + ny), (c.x + nx, c.y + ny), (c.x - nx, c.y - ny), (a.x - nx, a.y - ny)])

proc solidStroke(pts: seq[V]; width: float; closed: bool; dst: var seq[seq[(float, float)]]) =
  ## (a line `width` thick through `pts`, round where it turns and ends)
  let r = width / 2
  let n = pts.len
  if n == 0: return
  let segs = if closed: n else: n - 1
  let dn = clamp(int(r * 1.5) + 6, 6, 24)
  for i in 0 ..< segs:
    let q = segQuad(pts[i], pts[(i + 1) mod n], r)
    if q.len > 0: dst.add q
  for i in 0 ..< n: dst.add disc(pts[i], r, dn)

proc lengthOf(pts: seq[V]; closed: bool): float =
  for i in 1 ..< pts.len: result += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
  if closed and pts.len > 1: result += hypot(pts[0].x - pts[^1].x, pts[0].y - pts[^1].y)

proc walk(pts: seq[V]; closed: bool; step: float): seq[V] =
  ## (points every `step` along the line)
  var p = pts
  if closed and p.len > 1: p.add p[0]
  if p.len == 0: return
  result.add p[0]
  var left = step
  for i in 1 ..< p.len:
    var a = p[i - 1]
    let c = p[i]
    var d = hypot(c.x - a.x, c.y - a.y)
    while d >= left:
      let t = left / d
      a = (a.x + (c.x - a.x) * t, a.y + (c.y - a.y) * t)
      result.add a
      d -= left
      left = step
    left -= d
  if result.len == 0 or result[^1] != p[^1]: result.add p[^1]

proc dashes(pts: seq[V]; closed: bool; on, off: float): seq[seq[V]] =
  ## (the pieces of a dashed line)
  var p = pts
  if closed and p.len > 1: p.add p[0]
  var cur: seq[V]
  var drawing = true
  var left = on
  if p.len > 0: cur.add p[0]
  for i in 1 ..< p.len:
    var a = p[i - 1]
    let c = p[i]
    var d = hypot(c.x - a.x, c.y - a.y)
    while d >= left:
      let t = left / d
      a = (a.x + (c.x - a.x) * t, a.y + (c.y - a.y) * t)
      if drawing:
        cur.add a
        result.add cur
        cur = @[]
      else: cur = @[a]
      d -= left
      drawing = not drawing
      left = if drawing: on else: off
    if drawing: cur.add c
    left -= d
  if drawing and cur.len > 1: result.add cur

proc jitter(seed: int): proc (): float =
  var s = uint32(seed * 2654435761'i64 + 12345)
  result = proc (): float =
    s = s xor (s shl 13)
    s = s xor (s shr 17)
    s = s xor (s shl 5)
    float(s mod 10000) / 10000 - 0.5

proc roughLine(a, b: V; width: float; rnd: proc (): float; dst: var seq[seq[(float, float)]]; k = 1.0) =
  ## (a line drawn quickly by hand: past its ends a little, bowed, its ends
  ## a little off)
  let len = hypot(b.x - a.x, b.y - a.y)
  if len < 1e-6: return
  let ux = (b.x - a.x) / len
  let uy = (b.y - a.y) / len
  let off = (min(len * 0.02 + 0.8, 3.0) + width * 0.4) * k
  let over = min(len * 0.06, 6.0 + width) * min(k, 1.5)
  let o0 = over * (0.2 + rnd() + 0.5)
  let o1 = over * (0.2 + rnd() + 0.5)
  let p0: V = (a.x - ux * o0 * 0.5 + rnd() * 2 * off * -uy, a.y - uy * o0 * 0.5 + rnd() * 2 * off * ux)
  let p1: V = (b.x + ux * o1 * 0.5 + rnd() * 2 * off * -uy, b.y + uy * o1 * 0.5 + rnd() * 2 * off * ux)
  let bow = rnd() * 2 * min(len * 0.025 + 1.0, 5.0) * k
  let m: V = ((p0.x + p1.x) / 2 - uy * bow, (p0.y + p1.y) / 2 + ux * bow)
  var pts: seq[V]
  let n = clamp(int(len / 12), 2, 16)
  for k in 0 .. n:
    let t = k.float / n.float
    let u = 1 - t
    pts.add (u * u * p0.x + 2 * u * t * m.x + t * t * p1.x, u * u * p0.y + 2 * u * t * m.y + t * t * p1.y)
  solidStroke(pts, width, false, dst)

proc roughK*(roughness: int): float =
  ## How much a hand's unevenness is made more (wild) or less (neat).
  case roughness
  of -1: 0.3
  of 1: 1.9
  else: 1.0

proc styledStroke*(pts: seq[V]; width: float; closed: bool; dash: BoardDash; seed: int; rough = 0):
    seq[seq[(float, float)]] =
  ## Outlines of a line through `pts`, `width` thick, in a dash style: hand
  ## drawn (a little uneven), dashed, dotted, solid; sketched (each edge
  ## drawn twice, loosely, past its corners -- as a quick sketch is).
  case dash
  of bdSolid: solidStroke(pts, width, closed, result)
  of bdSketch:
    let rnd = jitter(seed * 31 + 7)
    let w = max(1.0, width * 0.7)
    # (straight edges: each its own two strokes; a curve: twice round, a
    # little apart)
    var edges = 0
    var corners: seq[V]
    if pts.len <= 24:
      corners = pts
      edges = if closed: pts.len else: pts.len - 1
    if edges > 0:
      for pass in 0 .. 1:
        for i in 0 ..< edges:
          roughLine(corners[i], corners[(i + 1) mod corners.len], w, rnd, result, roughK(rough))
    else:
      for pass in 0 .. 1:
        let amp = (width * 0.6 + 1.2) * roughK(rough)
        let phase = rnd() * 7
        var q: seq[V]
        let n = pts.len
        let total = lengthOf(pts, closed)
        var run = 0.0
        for i, p in pts:
          if i > 0: run += hypot(p.x - pts[i - 1].x, p.y - pts[i - 1].y)
          let a = pts[max(0, i - 1)]
          let c = pts[min(n - 1, i + 1)]
          let d = max(1e-9, hypot(c.x - a.x, c.y - a.y))
          let off = sin(run / max(1.0, total) * 2 * PI * 2 + phase) * amp + rnd() * amp * 0.3
          q.add (p.x - (c.y - a.y) / d * off, p.y + (c.x - a.x) / d * off)
        # (a closed one goes on a little past where it began)
        if closed and q.len > 4:
          for k in 0 .. min(3, q.high): q.add q[k]
        solidStroke(q, w, false, result)
  of bdDashed:
    let total = lengthOf(pts, closed)
    var on = width * 2.5 + 4
    var off = width * 2 + 4
    # (whole dashes round a closed outline)
    if closed and total > 0:
      let n = max(1.0, round(total / (on + off)))
      let k = total / (n * (on + off))
      on *= k
      off *= k
    for piece in dashes(pts, closed, on, off): solidStroke(piece, width, false, result)
  of bdDotted:
    let total = lengthOf(pts, closed)
    var step = width * 2.6 + 2
    if closed and total > 0: step = total / max(1.0, round(total / step))
    for p in walk(pts, closed, step): result.add disc(p, width * 0.65, 10)
  of bdDraw:
    # (hand drawn: the line wanders a little, its ink thicker and thinner)
    let rnd = jitter(seed)
    let total = lengthOf(pts, closed)
    let step = clamp(total / 60, 4.0, 24.0)
    var ws = walk(pts, closed, step)
    # (it goes on a little past its start, as a pen closing a shape does)
    if closed and ws.len > 3:
      for k in 1 .. min(2, ws.high): ws.add ws[k]
    var ink: seq[InkPoint]
    # (a slow wobble across the line: random offsets every so often, eased
    # between; the pressure too -- round a closed outline they come back to
    # where they began, so it meets itself)
    let amp = (width * 0.45 + 0.8) * roughK(rough)
    var knot = clamp(total / 5, 40.0, 160.0)
    let n = max(3, int(round(total / knot)))
    if closed: knot = total / n.float
    var offs, press: seq[float]
    for k in 0 .. n + 3:
      if closed and k >= n:
        offs.add offs[k - n]
        press.add press[k - n]
      else:
        offs.add rnd() * 2 * amp
        press.add 0.5 + rnd() * 0.3
    var run = 0.0
    for i, p in ws:
      if i > 0: run += hypot(p.x - ws[i - 1].x, p.y - ws[i - 1].y)
      let f = run / knot
      let k = min(int(f), offs.high - 1)
      let t = (1 - cos((f - k.float) * PI)) / 2
      let off = offs[k] + (offs[k + 1] - offs[k]) * t
      let pr = press[k] + (press[k + 1] - press[k]) * t
      let a = ws[max(0, i - 1)]
      let c = ws[min(ws.high, i + 1)]
      let d = max(1e-9, hypot(c.x - a.x, c.y - a.y))
      ink.add (float32(p.x - (c.y - a.y) / d * off), float32(p.y + (c.x - a.x) / d * off), float32(pr))
    var o = inkOptions(width * 1.2, thinning = 0.35, smoothing = 0.6, streamline = 0.3,
                       simulatePressure = false)
    result.add strokeOutline(ink, o)

proc polyFill(pts: seq[V]): seq[(float, float)] =
  for p in pts: result.add (p.x, p.y)

proc hatch(outline: seq[V]; spacing, width: float): seq[seq[(float, float)]] =
  ## (diagonal lines across a closed outline, inside it)
  if outline.len < 3: return
  let bx = boxOf(outline)
  # (a little off the grid: a line through a corner exactly would cross
  # the outline an odd number of times)
  var c = bx.x - bx.y - bx.h + spacing * 0.5 + 0.0731
  let cEnd = bx.x + bx.w - bx.y
  while c <= cEnd:
    # (x - y = c: where it crosses the outline)
    var ys: seq[float]
    for i in 0 ..< outline.len:
      let a = outline[i]
      let d = outline[(i + 1) mod outline.len]
      let fa = a.x - a.y - c
      let fd = d.x - d.y - c
      if (fa < 0) != (fd < 0) and fa != fd:
        let t = fa / (fa - fd)
        ys.add a.y + (d.y - a.y) * t
    ys.sort()
    var k = 0
    while k + 1 < ys.len:
      let p0: V = (c + ys[k], ys[k])
      let p1: V = (c + ys[k + 1], ys[k + 1])
      let q = segQuad(p0, p1, width / 2)
      if q.len > 0: result.add q
      k += 2
    c += spacing

proc inside*(p: V; poly: seq[V]): bool
  ## The point `p` is inside the closed outline `poly` (even-odd).

proc fillLines*(outline: seq[V]; style: BoardFill; spacing, width: float; sketch: bool; seed: int; k = 1.0):
    seq[seq[(float, float)]] =
  ## The lines (or dots) of a fill style inside a closed outline: hachure,
  ## cross-hatch, zigzag, dots -- drawn loosely when `sketch`.
  if outline.len < 3: return
  let bx = boxOf(outline)
  let rnd = jitter(seed * 13 + 5)
  if style == bfDots:
    let r = max(1.2, width * 1.4)
    var y = bx.y + spacing * 0.5
    var row = 0
    while y < bx.y + bx.h:
      var x = bx.x + spacing * (if row mod 2 == 0: 0.5 else: 1.0)
      while x < bx.x + bx.w:
        let p: V = (x + (if sketch: rnd() * spacing * 0.3 * k else: 0.0),
                    y + (if sketch: rnd() * spacing * 0.3 * k else: 0.0))
        if inside(p, outline): result.add disc(p, r, 8)
        x += spacing
      y += spacing * 0.86
      inc row
    return
  # (lines across: those at an angle, both ways for cross-hatch)
  var angles = @[-PI / 4]
  if style == bfCross: angles.add PI / 4
  for ai, a in angles:
    let u: V = (cos(a), sin(a))
    let n: V = (-sin(a), cos(a))
    var lo = 1e300
    var hi = -1e300
    for p in outline:
      let c = p.x * n.x + p.y * n.y
      lo = min(lo, c)
      hi = max(hi, c)
    var segs: seq[(V, V)]
    var c = lo + spacing * 0.5 + 0.0731
    while c < hi:
      var ts: seq[float]
      for i in 0 ..< outline.len:
        let p = outline[i]
        let q = outline[(i + 1) mod outline.len]
        let fp = p.x * n.x + p.y * n.y - c
        let fq = q.x * n.x + q.y * n.y - c
        if (fp < 0) != (fq < 0) and fp != fq:
          let t = fp / (fp - fq)
          let x = p.x + (q.x - p.x) * t
          let y = p.y + (q.y - p.y) * t
          ts.add x * u.x + y * u.y
      ts.sort()
      var i = 0
      while i + 1 < ts.len:
        segs.add ((n.x * c + u.x * ts[i], n.y * c + u.y * ts[i]), (n.x * c + u.x * ts[i + 1], n.y * c + u.y * ts[i + 1]))
        i += 2
      c += spacing
    if style == bfZigzag:
      # (one line back and forth, broken where the next is too far)
      var path: seq[V]
      for j, sg in segs:
        let (p0, p1) = if j mod 2 == 0: sg else: (sg[1], sg[0])
        if path.len > 0 and hypot(p0.x - path[^1].x, p0.y - path[^1].y) > spacing * 2.5:
          result.add styledStroke(path, width, false, (if sketch: bdSketch else: bdSolid), seed + j)
          path.setLen(0)
        path.add p0
        path.add p1
      if path.len > 1: result.add styledStroke(path, width, false, (if sketch: bdSketch else: bdSolid), seed)
    else:
      for j, sg in segs:
        if sketch:
          let l = hypot(sg[1].x - sg[0].x, sg[1].y - sg[0].y)
          if l < spacing * 0.4: continue
          let rl = jitter(seed + j * 13 + ai * 7)
          roughLine(sg[0], sg[1], width, rl, result, k)
        else:
          let q = segQuad(sg[0], sg[1], width / 2)
          if q.len > 0: result.add q

proc sketchHatch(outline: seq[V]; spacing, width: float; seed: int): seq[seq[(float, float)]] =
  ## (a quick hand's hatching: the diagonal lines of `hatch`, each drawn
  ## loosely, at a steeper slant)
  if outline.len < 3: return
  let rnd = jitter(seed * 17 + 3)
  # (lines across, turned: x - y * 0.6 = c)
  let k = 0.6
  let bx = boxOf(outline)
  var c = bx.x - (bx.y + bx.h) * k + spacing * 0.5 + 0.0731
  let cEnd = bx.x + bx.w - bx.y * k
  while c <= cEnd:
    var ys: seq[float]
    for i in 0 ..< outline.len:
      let a = outline[i]
      let d = outline[(i + 1) mod outline.len]
      let fa = a.x - a.y * k - c
      let fd = d.x - d.y * k - c
      if (fa < 0) != (fd < 0) and fa != fd:
        let t = fa / (fa - fd)
        ys.add a.y + (d.y - a.y) * t
    ys.sort()
    var i = 0
    while i + 1 < ys.len:
      let p0: V = (c + ys[i] * k, ys[i])
      let p1: V = (c + ys[i + 1] * k, ys[i + 1])
      # (a little short of the outline, as a hand stops)
      let l = hypot(p1.x - p0.x, p1.y - p0.y)
      if l > spacing * 0.5:
        let ux = (p1.x - p0.x) / l
        let uy = (p1.y - p0.y) / l
        let cut = min(l * 0.1, 3.0)
        let pts = @[(p0.x + ux * cut, p0.y + uy * cut), (p1.x - ux * cut, p1.y - uy * cut)]
        let rl = jitter(seed + i * 13 + int(c))
        roughLine(pts[0], pts[1], width, rl, result)
      i += 2
    c += spacing

# ---- text --------------------------------------------------------------------------------------

var faceCache: Table[string, Face]

proc hasLetter(family: string; cp: int): bool =
  if family notin faceCache: faceCache[family] = fontFace(family, "Regular").face
  faceCache[family].hasGlyph(cp)

proc isArabic(cp: int): bool {.inline.} =
  cp in 0x0600 .. 0x06FF or cp in 0x0750 .. 0x077F or cp in 0x08A0 .. 0x08FF or cp in 0xFB50 .. 0xFDFF or
    cp in 0xFE70 .. 0xFEFF

proc fontSpans*(text: string; font: BoardFont; style: CharStyle): seq[TextSpan] =
  ## `text` in `font`, what it has no letters for in another: Arabic in
  ## the Arabic hand (Aref Ruqaa) after a handwriting font, else in
  ## FreeSerif; the rest in FreeSans. Spaces stay with the letters before
  ## them.
  useHandFonts()
  let main = fontFamilies[font]
  let arabic = if font in {bfnHand .. bfnRuqaa}: "Aref Ruqaa" else: "FreeSerif"
  var cur = main
  var piece = ""
  for r in text.runes:
    let cp = int(r)
    var fam = cur
    if not (cp <= 32 or r.isWhiteSpace):
      fam = if hasLetter(main, cp): main
            elif isArabic(cp) and hasLetter(arabic, cp): arabic
            elif hasLetter("FreeSans", cp): "FreeSans"
            else: main
    if fam != cur and piece.len > 0:
      var st = style
      st.family = cur
      result.add TextSpan(text: piece, style: st)
      piece = ""
    cur = fam
    piece.add r.toUTF8
  var st = style
  st.family = cur
  result.add TextSpan(text: piece, style: st)

proc textData*(s: Shape; text: string; boxW: float; color: uint32; size: float): TextData =
  ## The shape's words `text` set in its font, `size` and `color`, as a
  ## text for `retroui/textengine`: `boxW` wide (0: as wide as they are).
  let style = CharStyle(family: fontFamilies[s.font], style: fontStyles[s.font], size: float32(size), color: color,
                        hScale: 1, vScale: 1)
  result = TextData(x: 0, y: 0, boxW: float32(if boxW > 0: boxW else: 100000.0), boxH: 100000,
                    antialias: true)
  result.spans = fontSpans(text, s.font, style)
  result.para.align = case s.align
                      of baStart: textLeft
                      of baEnd: textRight
                      else: textCenter
  if boxW <= 0: result.para.align = textLeft

proc measureText*(s: Shape; text: string; boxW: float; size: float): (float, float) =
  ## How wide and tall `text` is, set in the shape's font at `size`
  ## (wrapped in `boxW`; 0: not wrapped).
  if text.len == 0: return (0.0, size * 1.2)
  var t = s.textData(text, boxW, 0xFF000000'u32, size)
  let l = layoutText(t)
  let bb = t.drawnBounds(l)
  var w = float(bb.x1 - bb.x0)
  var h = float(bb.y1)
  let lines = max(1, text.countLines)
  h = max(h, size * 1.2 * lines.float)
  if boxW <= 0 and bb.x1 < 50000: w = max(w, float(bb.x1))    # (a right-to-left line stands at the far side)
  (w, h)

proc textSize*(s: Shape): float = fontSizes[s.size] * (if s.scale > 0: s.scale else: 1.0)
  ## How big its letters are (page units).

proc fitText*(s: var Shape) =
  ## A text shape sized to its words (as wide as they are when `autoSize`;
  ## else as tall as they wrap to in its width).
  if s.kind != skText: return
  let size = s.textSize
  if s.autoSize:
    let (w, h) = s.measureText(if s.text.len > 0: s.text else: " ", 0, size)
    s.w = max(size * 0.6, w + size * 0.15)
    s.h = h
  else:
    let (_, h) = s.measureText(if s.text.len > 0: s.text else: " ", max(10.0, s.w), size)
    s.h = max(size * 1.2, h)

# ---- what a shape looks like -----------------------------------------------------------------

proc arrowheadPieces(tip, back: V; head: Arrowhead; width: float; color: uint32;
                     strokes, fills: var seq[seq[(float, float)]]) =
  ## (an arrowhead at `tip`, the line coming from `back`)
  if head == ahNone: return
  let d = hypot(tip.x - back.x, tip.y - back.y)
  if d < 1e-6: return
  let ux = (tip.x - back.x) / d
  let uy = (tip.y - back.y) / d
  let L = width * 3.5 + 8
  let W = L * 0.55
  let base: V = (tip.x - ux * L, tip.y - uy * L)
  let left: V = (base.x - uy * W, base.y + ux * W)
  let right: V = (base.x + uy * W, base.y - ux * W)
  case head
  of ahArrow:
    solidStroke(@[left, tip, right], width, false, strokes)
  of ahTriangle:
    fills.add ccw(@[(tip.x, tip.y), (left.x, left.y), (right.x, right.y)])
    solidStroke(@[tip, left, right], width, true, strokes)
  of ahDot:
    fills.add disc(tip, W * 0.6 + width / 2, 16)
  of ahDiamond:
    let mid: V = (tip.x - ux * L / 2, tip.y - uy * L / 2)
    let back2: V = (tip.x - ux * L, tip.y - uy * L)
    fills.add ccw(@[(tip.x, tip.y), (mid.x - uy * W * 0.7, mid.y + ux * W * 0.7), (back2.x, back2.y),
                    (mid.x + uy * W * 0.7, mid.y - ux * W * 0.7)])
  of ahSquare:
    let s2 = W * 0.6
    let c: V = (tip.x - ux * s2, tip.y - uy * s2)
    fills.add ccw(@[(c.x - ux * s2 - uy * s2, c.y - uy * s2 + ux * s2), (c.x + ux * s2 - uy * s2, c.y + uy * s2 + ux * s2),
                    (c.x + ux * s2 + uy * s2, c.y + uy * s2 - ux * s2), (c.x - ux * s2 + uy * s2, c.y - uy * s2 - ux * s2)])
  of ahBar:
    solidStroke(@[(tip.x - uy * W, tip.y + ux * W), (tip.x + uy * W, tip.y - ux * W)], width, false, strokes)
  of ahNone: discard

proc labelBox(s: Shape): Box =
  ## (where a shape's label is set, in its own terms)
  let pad = 8.0 + strokeWidths[s.size]
  case s.geo
  of gkTriangle: (pad, s.h * 0.35, max(10.0, s.w - 2 * pad), s.h * 0.62 - pad)
  of gkDiamond, gkStar, gkHeart, gkCloud, gkLightning, gkMoon, gkCross, gkChevron, gkDoubleArrow:
    (s.w * 0.17, s.h * 0.17, s.w * 0.66, s.h * 0.66)
  of gkCylinder:
    let ry = min(s.h * 0.18, s.w * 0.25)
    (pad, ry * 2 + 4, max(10.0, s.w - 2 * pad), max(10.0, s.h - ry * 3 - 4))
  of gkSpeech: (pad, pad, max(10.0, s.w - 2 * pad), max(10.0, s.h * 0.78 - 2 * pad))
  of gkDocument: (pad, pad, max(10.0, s.w - 2 * pad), max(10.0, s.h * 0.86 - 2 * pad))
  of gkCube:
    let d = min(s.w, s.h) * 0.25
    (pad, d + pad, max(10.0, s.w - d - 2 * pad), max(10.0, s.h - d - 2 * pad))
  of gkRightTriangle: (pad, s.h * 0.45, s.w * 0.62, s.h * 0.5)
  of gkPerson: (pad, s.h * 0.55, max(10.0, s.w - 2 * pad), s.h * 0.42)
  else: (pad, pad, max(10.0, s.w - 2 * pad), max(10.0, s.h - 2 * pad))

type LabelFrame* = object
  ## Where a shape's words are set: a box in the terms of `host` (the shape
  ## itself, or for an arrow's label a box of its own), their size, the
  ## width they wrap in, how they stand in the box's height.
  host*: Shape             ## the shape whose terms the box is in
  x*, y*, w*, h*: float    ## the box, from the host's corner (page units)
  size*: float             ## the letters' size (page units)
  wrap*: float             ## the width the words wrap in (page units)
  valign*: BoardAlign      ## where the words stand in the box's height

proc hasText*(s: Shape): bool = s.kind in {skGeo, skNote, skText, skArrow, skFrame}
  ## Words can be typed in it (a label, a note's, a text's, a frame's name).

proc labelFrame*(b: Board; s: Shape): LabelFrame =
  ## Where shape `s`'s words are set.
  case s.kind
  of skGeo:
    let lb = s.labelBox
    LabelFrame(host: s, x: lb.x, y: lb.y, w: lb.w, h: lb.h, size: s.textSize, wrap: lb.w,
               valign: s.valign)
  of skNote:
    # (smaller letters when a word is wider than the note, or the words
    # taller: a note keeps its size)
    let w = max(10.0, s.w - 32)
    let h = max(10.0, s.h - 32)
    var size = s.textSize
    if s.text.len > 0:
      var widest = 0.0
      for word in strutils.splitWhitespace(s.text): widest = max(widest, s.measureText(word, 0, size)[0])
      if widest > w: size *= max(0.35, w / widest)
      let (_, th) = s.measureText(s.text, w, size)
      if th > h: size *= max(0.35, sqrt(h / th))
    LabelFrame(host: s, x: 16, y: 16, w: w, h: h, size: size, wrap: w, valign: s.valign)
  of skText:
    LabelFrame(host: s, x: 0, y: 0, w: s.w, h: s.h, size: s.textSize,
               wrap: (if s.autoSize: s.w + 2 else: max(10.0, s.w)), valign: baStart)
  of skFrame:
    var host = s
    host.align = baStart
    LabelFrame(host: host, x: 0, y: -26, w: max(40.0, s.w), h: 24, size: 16, wrap: max(40.0, s.w),
               valign: baEnd)
  of skArrow:
    # (on its middle, as wide as its words)
    let m = b.arrowMiddle(s)
    let size = s.textSize
    var host = s
    host.rot = 0
    host.align = baMiddle
    let (tw, th) = host.measureText(if s.text.len > 0: s.text else: " ", 0, size)
    host.w = tw + size * 0.6
    host.h = th + size * 0.3
    host.x = m.x - host.w / 2
    host.y = m.y - host.h / 2
    LabelFrame(host: host, x: 0, y: 0, w: host.w, h: host.h, size: size, wrap: host.w + 1, valign: baMiddle)
  else:
    LabelFrame(host: s, x: 0, y: 0, w: s.w, h: s.h, size: s.textSize, wrap: max(10.0, s.w),
               valign: baMiddle)

proc placed(f: LabelFrame; text: string; color: uint32): tuple[t: TextData; l: TextLayout; oy: float] =
  ## (the words set in the frame: where their top is)
  var t = f.host.textData(text, f.wrap, color, f.size)
  let l = layoutText(t)
  let bb = t.drawnBounds(l)
  let th = max(float(bb.y1), f.size * 1.2 * float(max(1, text.countLines)))
  let oy = case f.valign
           of baStart: f.y
           of baEnd: f.y + f.h - th
           else: f.y + (f.h - th) / 2
  (t, l, oy)

proc textPieces(f: LabelFrame; text: string; color: uint32; dst: var seq[Piece]) =
  ## (words set in the frame, as outlines on the page)
  if text.len == 0: return
  let (t, l, oy) = f.placed(text, color)
  var piece = Piece(color: color)
  for o in textOutlines(t, l, fine = false):
    for poly in o.polys:
      var c: seq[(float, float)]
      for p in poly:
        let q = f.host.toPage(f.x + float(p[0]), oy + float(p[1]))
        c.add (q.x, q.y)
      if c.len >= 3: piece.contours.add c
  if piece.contours.len > 0: dst.add piece

proc textCaret*(b: Board; s: Shape; index: int): (V, V) =
  ## Where the caret before character `index` of shape `s`'s words is
  ## (counted in characters, not bytes): its top and its bottom on the page.
  let f = b.labelFrame(s)
  if s.text.len == 0:
    let h = f.size * 1.2
    let x = case f.host.align
            of baStart: 0.0
            of baEnd: f.w
            else: f.w / 2
    let y = case f.valign
            of baStart: f.y
            of baEnd: f.y + f.h - h
            else: f.y + (f.h - h) / 2
    return (f.host.toPage(f.x + x, y), f.host.toPage(f.x + x, y + h))
  let (_, l, oy) = f.placed(s.text, 0xFF000000'u32)
  let c = caretAt(l, index)
  (f.host.toPage(f.x + c.x.float, oy + c.top.float), f.host.toPage(f.x + c.x.float, oy + c.bottom.float))

proc textIndexAt*(b: Board; s: Shape; x, y: float): int =
  ## The character a click at the page point (`x`, `y`) puts the caret
  ## before, in shape `s`'s words.
  if s.text.len == 0: return 0
  let f = b.labelFrame(s)
  let (_, l, oy) = f.placed(s.text, 0xFF000000'u32)
  let p = f.host.toLocal(x, y)
  charAt(l, float32(p.x - f.x), float32(p.y - oy))

proc drawKey(b: Board; s: Shape): Hash =
  var h: Hash = hash(s.ver) !& hash(s.id) !& hash(b.dark) !& hash(b.paper)
  if s.kind == skArrow:
    # (an arrow follows the shapes it holds)
    for id in [s.t0.bound, s.t1.bound]:
      if id != 0:
        let t = b.find(id)
        if t != nil: h = h !& hash(t.ver) !& hash(t.x) !& hash(t.y) !& hash(t.w) !& hash(t.h) !& hash(t.rot)
  !$h

proc buildDrawing(b: Board; s: Shape): Drawing =
  let dark = b.dark
  let ink = inkOf(s.color, dark).withAlpha(s.opacity)
  let sw = strokeWidths[s.size]
  case s.kind
  of skDraw, skHighlight:
    let hl = s.kind == skHighlight
    var pts: seq[InkPoint]
    for p in s.pts:
      let q = s.toPage(p.x.float, p.y.float)
      pts.add (float32(q.x), float32(q.y), p.p)
    if s.closed and s.fill != bfNone and pts.len > 2:
      var c: seq[(float, float)]
      for p in pts: c.add (p.x.float, p.y.float)
      let fc = (if s.fill == bfSolid: inkOf(s.fillOf, dark).withAlpha(s.opacity)
                else: semiOf(s.fillOf, dark).withAlpha(s.opacity))
      result.pieces.add Piece(contours: @[c], color: fc)
    let size = if hl: sw * 5 + 8 else: sw * 1.6 + 1
    var o = inkOptions(size, thinning = (if hl: 0.0 elif s.isPen: 0.65 else: 0.5),
                       smoothing = 0.5, streamline = 0.5, simulatePressure = not s.isPen and not hl)
    let outline = strokeOutline(pts, o)
    let col = if hl: inkOf(s.color, dark).withAlpha(0.38 * s.opacity) else: ink
    if outline.len > 2: result.pieces.add Piece(contours: @[outline], color: col)
  of skGeo:
    let ol = s.pageOutline
    let fc = s.fillOf
    case s.fill
    of bfNone: discard
    of bfSemi: result.pieces.add Piece(contours: @[polyFill(ol)], color: semiOf(fc, dark).withAlpha(s.opacity))
    of bfSolid: result.pieces.add Piece(contours: @[polyFill(ol)],
                                        color: mixArgb(inkOf(fc, dark), b.paperOf, 0.12).withAlpha(s.opacity))
    of bfPattern:
      result.pieces.add Piece(contours: @[polyFill(ol)], color: semiOf(fc, dark).withAlpha(s.opacity))
      let lines = if s.dash == bdSketch: sketchHatch(ol, sw * 3 + 6, max(1.0, sw * 0.6), s.id)
                  else: hatch(ol, sw * 2 + 6, max(1.0, sw * 0.5))
      result.pieces.add Piece(contours: lines, color: inkOf(fc, dark).withAlpha(0.55 * s.opacity))
    of bfCross, bfZigzag, bfDots:
      result.pieces.add Piece(contours: @[polyFill(ol)], color: semiOf(fc, dark).withAlpha(s.opacity * 0.6))
      let lines = fillLines(ol, s.fill, (if s.fill == bfDots: sw * 2.5 + 9 else: sw * 2.5 + 7), max(1.0, sw * 0.5),
                            s.dash == bdSketch, s.id, roughK(s.roughness))
      result.pieces.add Piece(contours: lines,
                              color: inkOf(fc, dark).withAlpha((if s.fill == bfDots: 0.85 else: 0.6) * s.opacity))
    var strokes = styledStroke(ol, sw, true, s.dash, s.id, s.roughness)
    # (a check box's tick, an x box's cross, a cylinder's rim...)
    for k, d in geoDetails(s.geo, s.w, s.h):
      var pts: seq[V]
      for p in d:
        let x = if s.flipX: s.w - p.x else: p.x
        let y = if s.flipY: s.h - p.y else: p.y
        pts.add s.toPage(x, y)
      strokes.add styledStroke(pts, sw, false, s.dash, s.id + 7 + 2 * k, s.roughness)
    result.pieces.add Piece(contours: strokes, color: ink)
    if s.text.len > 0:
      # (on a solid fill: dark or light letters, whichever shows)
      var tc = ink
      if s.fill == bfSolid:
        let f = mixArgb(inkOf(fc, dark), b.paperOf, 0.12)
        let lum = 0.3 * float((f shr 16) and 255) + 0.59 * float((f shr 8) and 255) + 0.11 * float(f and 255)
        tc = (if lum > 150: 0xFF1D1D1D'u32 else: 0xFFFFFFFF'u32).withAlpha(s.opacity)
      b.labelFrame(s).textPieces(s.text, tc, result.pieces)
  of skArrow, skLine:
    var path: seq[V] = @[]
    if s.kind == skArrow: path = b.arrowPath(s)
    else:
      for p in s.pts: path.add s.toPage(p.x.float, p.y.float)
      if s.spline and path.len > 2:
        # (smooth through its handles: Catmull-Rom)
        var sm: seq[V]
        for i in 0 ..< path.high:
          let p0 = path[max(0, i - 1)]
          let p1 = path[i]
          let p2 = path[i + 1]
          let p3 = path[min(path.high, i + 2)]
          for k in 0 ..< 12:
            let t = k.float / 12
            let t2 = t * t
            let t3 = t2 * t
            sm.add (0.5 * (2 * p1.x + (-p0.x + p2.x) * t + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 +
                          (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3),
                    0.5 * (2 * p1.y + (-p0.y + p2.y) * t + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 +
                          (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3))
        sm.add path[^1]
        path = sm
    if path.len >= 2:
      var strokes = styledStroke(path, sw, false, s.dash, s.id, s.roughness)
      var fills: seq[seq[(float, float)]]
      if s.kind == skArrow:
        let back = if s.elbow or path.len <= 2: 1 else: 2
        arrowheadPieces(path[^1], path[max(0, path.high - back)], s.head1, sw, ink, strokes, fills)
        arrowheadPieces(path[0], path[min(path.high, back)], s.head0, sw, ink, strokes, fills)
      if fills.len > 0: result.pieces.add Piece(contours: fills, color: ink)
      result.pieces.add Piece(contours: strokes, color: ink)
      if s.kind == skArrow and s.text.len > 0:
        # (its label on its middle, the line hidden behind it)
        let f = b.labelFrame(s)
        let h = f.host
        result.pieces.add Piece(contours: @[polyFill(@[(h.x, h.y), (h.x + h.w, h.y), (h.x + h.w, h.y + h.h),
                                                       (h.x, h.y + h.h)])], color: b.paperOf)
        f.textPieces(s.text, ink, result.pieces)
  of skText:
    b.labelFrame(s).textPieces(s.text, ink, result.pieces)
  of skNote:
    let ol = s.pageOutline
    var shadow: seq[(float, float)]
    for p in ol: shadow.add (p.x + 2, p.y + 4)
    result.pieces.add Piece(contours: @[shadow], color: (if dark: 0x66000000'u32 else: 0x26000000'u32))
    result.pieces.add Piece(contours: @[polyFill(ol)], color: noteOf(s.color, dark).withAlpha(s.opacity))
    let tc = (if dark: 0xFFF2F2F2'u32 else: 0xFF1D1D1D'u32).withAlpha(s.opacity)
    b.labelFrame(s).textPieces(s.text, tc, result.pieces)
  of skFrame:
    let ol = s.pageOutline
    result.pieces.add Piece(contours: @[polyFill(ol)], color: (if dark: 0xFF1A1A1C'u32 else: 0xFFFFFFFF'u32))
    var edge: seq[seq[(float, float)]]
    solidStroke(ol, 1.5, true, edge)
    result.pieces.add Piece(contours: edge, color: (if dark: 0xFF4A4A4F'u32 else: 0xFFBDBDC4'u32))
    let name = if s.text.len > 0: s.text else: "Frame"
    b.labelFrame(s).textPieces(name, (if dark: 0xFFA0A0A8'u32 else: 0xFF6B6B74'u32), result.pieces)
  of skImage:
    if s.image.len == 0:
      result.pieces.add Piece(contours: @[polyFill(s.pageOutline)], color: 0x22808080'u32)
  of skGroup: discard
  discard sw

proc buildBrief(b: Board; s: Shape): Drawing

proc drawingOf*(b: Board; s: Shape; brief = false): Drawing =
  ## What shape `s` looks like (kept until it, or what it holds on to,
  ## changes). `brief`: as it is drawn too small to read (`briefAt`) --
  ## its box and colors, its words as bars -- made in a fraction of the
  ## time and kept apart.
  let k = b.drawKey(s)
  let kept = if brief: addr b.briefs else: addr b.cache
  inc b.asked
  kept[].withValue(s.id, d):
    if d.key == k:
      d.used = b.asked
      return d[]
    b.cacheCost -= d.cost
  result = if brief: b.buildBrief(s) else: b.buildDrawing(s)
  result.key = k
  result.used = b.asked
  result.cost = 64
  for p in result.pieces:
    result.cost += 32
    for c in p.contours: result.cost += 32 + c.len * sizeof((float, float))
  if b.cacheCost + result.cost > drawingBudget:
    # (full: the half asked for longest ago go -- those of a frame drawn
    # now stay, so a board bigger than the budget is not made again whole)
    var ages: seq[int]
    for d in b.cache.values: ages.add d.used
    for d in b.briefs.values: ages.add d.used
    ages.sort()
    let cut = if ages.len > 0: ages[ages.len div 2] else: 0
    for t in [addr b.cache, addr b.briefs]:
      var gone: seq[int]
      for id, d in t[]:
        if d.used <= cut: gone.add id
      for id in gone:
        b.cacheCost -= t[][id].cost
        t[].del id
  kept[][s.id] = result
  b.cacheCost += result.cost
  if not brief:
    # (drawn in full now: its brief one, of a frame short of time, goes)
    b.briefs.withValue(s.id, d):
      b.cacheCost -= d.cost
    b.briefs.del s.id

proc textBars(f: LabelFrame; text: string; color: uint32; dst: var seq[Piece]) =
  ## (words too small to read: a bar a line, where they stand -- no letters
  ## set, none of their outlines made)
  if text.len == 0: return
  let lineH = f.size * 1.25
  let room = if f.wrap > 0 and f.wrap < 1e8: f.wrap else: max(f.w, f.size)
  let perLine = max(1, int(room / max(1e-3, f.size * 0.55)))
  var lens: seq[int]
  for para in text.split('\n'):
    var n = para.runeLen
    if n == 0:
      lens.add 0
      continue
    while n > 0:
      lens.add min(n, perLine)
      n -= perLine
  let most = max(1, int(max(f.h, lineH) / lineH))
  if lens.len > most: lens.setLen(most)
  let total = lens.len.float * lineH
  var y = case f.valign
          of baStart: f.y
          of baEnd: f.y + f.h - total
          else: f.y + (f.h - total) / 2
  var piece = Piece(color: color)
  for n in lens:
    if n > 0:
      let w = min(room, n.float * f.size * 0.55)
      let x = case f.host.align
              of baStart: f.x
              of baEnd: f.x + f.w - w
              else: f.x + (f.w - w) / 2
      let t = y + lineH * 0.35
      var c: seq[(float, float)]
      for (px, py) in [(x, t), (x + w, t), (x + w, t + f.size * 0.45), (x, t + f.size * 0.45)]:
        let q = f.host.toPage(px, py)
        c.add (q.x, q.y)
      piece.contours.add c
    y += lineH
  if piece.contours.len > 0: dst.add piece

proc buildBrief(b: Board; s: Shape): Drawing =
  ## (a shape too small on the screen to read: its box, its fill and its
  ## colors as they are, its line drawn plain, its words as bars)
  let dark = b.dark
  let ink = inkOf(s.color, dark).withAlpha(s.opacity)
  let sw = strokeWidths[s.size]
  case s.kind
  of skGeo:
    let ol = s.pageOutline
    let fc = s.fillOf
    var tc = ink
    case s.fill
    of bfNone: discard
    of bfSolid:
      let f = mixArgb(inkOf(fc, dark), b.paperOf, 0.12)
      result.pieces.add Piece(contours: @[polyFill(ol)], color: f.withAlpha(s.opacity))
      let lum = 0.3 * float((f shr 16) and 255) + 0.59 * float((f shr 8) and 255) + 0.11 * float(f and 255)
      tc = (if lum > 150: 0xFF1D1D1D'u32 else: 0xFFFFFFFF'u32).withAlpha(s.opacity)
    else: result.pieces.add Piece(contours: @[polyFill(ol)], color: semiOf(fc, dark).withAlpha(s.opacity))
    var edge: seq[seq[(float, float)]]
    solidStroke(ol, sw, true, edge)
    result.pieces.add Piece(contours: edge, color: ink)
    b.labelFrame(s).textBars(s.text, tc, result.pieces)
  of skNote:
    result.pieces.add Piece(contours: @[polyFill(s.pageOutline)], color: noteOf(s.color, dark).withAlpha(s.opacity))
    let tc = (if dark: 0xFFF2F2F2'u32 else: 0xFF1D1D1D'u32).withAlpha(s.opacity)
    # (where its words stand, not measured to fit: bars need no more)
    let f = LabelFrame(host: s, x: 16, y: 16, w: max(10.0, s.w - 32), h: max(10.0, s.h - 32),
                       size: s.textSize, wrap: max(10.0, s.w - 32), valign: s.valign)
    f.textBars(s.text, tc, result.pieces)
  of skText:
    b.labelFrame(s).textBars(s.text, ink, result.pieces)
  of skFrame:
    let ol = s.pageOutline
    result.pieces.add Piece(contours: @[polyFill(ol)], color: (if dark: 0xFF1A1A1C'u32 else: 0xFFFFFFFF'u32))
    var edge: seq[seq[(float, float)]]
    solidStroke(ol, 1.5, true, edge)
    result.pieces.add Piece(contours: edge, color: (if dark: 0xFF4A4A4F'u32 else: 0xFFBDBDC4'u32))
  else: result = b.buildDrawing(s)

const BriefLetters = 6.0
  ## (letters drawn smaller than this many pixels are not read: bars)

proc briefAt*(b: Board; s: Shape; scale: float): bool =
  ## Shape `s` is too small to read at `scale` pixels a page unit (its
  ## letters under 6 pixels, or the whole of it under 16 when it has no
  ## words): drawn in brief (`drawingOf(s, brief = true)`) -- a board of
  ## thousands of shapes, zoomed out, drawn fast.
  case s.kind
  of skGeo, skNote, skText:
    # (its letters' own size, not measured: a note's may be smaller still)
    if s.text.len > 0: s.textSize * scale < BriefLetters
    else: max(s.w, s.h) * scale < 16
  of skFrame: max(s.w, s.h) * scale < 60
  else: false

proc forgetDrawings*(b: Board) =
  ## Everything drawn again when next asked (the colors changed; memory is
  ## short).
  b.cache.clear()
  b.briefs.clear()
  b.cacheCost = 0

proc drawingBytes*(b: Board): int = b.cacheCost
  ## About how many bytes the drawings kept take.

proc startDrawing*(b: Board; ms = 8) =
  ## Before a frame's shapes: making their drawings may take `ms` of it
  ## (only the making counts, not the drawing: a board zoomed in on
  ## thousands of readable shapes, each made the first time). Past it,
  ## `drawingFor` gives the brief one, and `behind` says another frame
  ## should come to go on.
  b.makeLeft = initDuration(milliseconds = ms)
  b.budgeted = true
  b.behindNow = false

proc behind*(b: Board): bool = b.behindNow
  ## A shape of this frame was drawn in brief for want of time: ask for a
  ## frame more (`wakeIn(1)`), which makes the next ones.

proc drawingFor*(b: Board; s: Shape; scale: float): Drawing =
  ## What shape `s` looks like at `scale` pixels a page unit: in brief when
  ## it is too small to read there (`briefAt`) -- and for a frame or two
  ## when its drawing is still to make and this frame's time is up
  ## (`startDrawing`): the board keeps moving while it fills in.
  if b.briefAt(s, scale): return b.drawingOf(s, brief = true)
  b.cache.withValue(s.id, d):
    if d.key == b.drawKey(s): return b.drawingOf(s)
  if not b.budgeted: return b.drawingOf(s)
  if b.makeLeft > DurationZero:
    let t0 = getMonoTime()
    result = b.drawingOf(s)
    b.makeLeft -= getMonoTime() - t0
    return
  b.behindNow = true
  b.drawingOf(s, brief = true)

# ---- where shapes are --------------------------------------------------------------------------

proc boundsOf*(b: Board; s: Shape): Box =
  ## The page box round a shape as drawn (its ink, an arrow's line and heads,
  ## a group's shapes).
  case s.kind
  of skArrow:
    let p = b.arrowPath(s)
    var bx = boxOf(p)
    let m = b.arrowMiddle(s)
    bx = bx.union((m.x, m.y, 0.0, 0.0))
    let e = strokeWidths[s.size] * 4 + 10
    (bx.x - e, bx.y - e, bx.w + 2 * e, bx.h + 2 * e)
  of skDraw, skHighlight, skLine:
    let bx = boxOf(s.inkPoints)
    let e = strokeWidths[s.size] * (if s.kind == skHighlight: 3.0 else: 1.0) + 2
    (bx.x - e, bx.y - e, bx.w + 2 * e, bx.h + 2 * e)
  of skGroup:
    var u: Box = (0.0, 0.0, 0.0, 0.0)
    var any = false
    for t in b.page.shapes:
      if t.parent == s.id:
        let k = b.boundsOf(t)
        u = if any: u.union(k) else: k
        any = true
    u
  of skFrame:
    let bx = boxOf(s.pageOutline)
    (bx.x, bx.y - 28, bx.w, bx.h + 28)
  else:
    let bx = boxOf(s.pageOutline)
    let e = strokeWidths[s.size]
    (bx.x - e, bx.y - e, bx.w + 2 * e, bx.h + 2 * e)

proc distToSeg(p, a, c: V): float =
  let dx = c.x - a.x
  let dy = c.y - a.y
  let l2 = dx * dx + dy * dy
  if l2 < 1e-12: return hypot(p.x - a.x, p.y - a.y)
  let t = clamp(((p.x - a.x) * dx + (p.y - a.y) * dy) / l2, 0.0, 1.0)
  hypot(p.x - (a.x + dx * t), p.y - (a.y + dy * t))

proc distToLine(p: V; pts: seq[V]; closed = false): float =
  result = 1e300
  if pts.len == 1: return hypot(p.x - pts[0].x, p.y - pts[0].y)
  for i in 1 ..< pts.len: result = min(result, distToSeg(p, pts[i - 1], pts[i]))
  if closed and pts.len > 2: result = min(result, distToSeg(p, pts[^1], pts[0]))

proc inside*(p: V; poly: seq[V]): bool =
  ## The point `p` is inside the closed outline `poly` (even-odd: by the
  ## crossings of a ray).
  var c = false
  for i in 0 ..< poly.len:
    let a = poly[i]
    let d = poly[(i + 1) mod poly.len]
    if (a.y > p.y) != (d.y > p.y) and p.x < (d.x - a.x) * (p.y - a.y) / (d.y - a.y + 1e-12) + a.x:
      c = not c
  c

type ShapeHit* = enum
  ## Where a point is on a shape (`hitTest`): not on it, or:
  hitNone, hitEdge, hitFilled, hitHollow
    ## On its line or ink; inside where it is filled (or holds words); inside
    ## an empty outline (picked when nothing else is).

proc hitTest*(b: Board; s: Shape; x, y, tol: float): ShapeHit =
  ## Whether the page point (`x`, `y`) is on shape `s` (`tol`: how near
  ## counts, page units).
  let p: V = (x, y)
  let sw = strokeWidths[s.size]
  case s.kind
  of skDraw, skHighlight:
    let w = if s.kind == skHighlight: sw * 2.5 + 4 else: sw
    if distToLine(p, s.inkPoints) <= tol + w: return hitEdge
    if s.closed and s.fill != bfNone and inside(p, s.inkPoints): return hitFilled
  of skLine:
    if distToLine(p, s.inkPoints) <= tol + sw: return hitEdge
  of skArrow:
    if distToLine(p, b.arrowPath(s)) <= tol + sw: return hitEdge
    if s.text.len > 0:
      let m = b.arrowMiddle(s)
      if hypot(m.x - x, m.y - y) <= fontSizes[s.size]: return hitFilled
  of skGeo:
    let ol = s.pageOutline
    if distToLine(p, ol, true) <= tol + sw: return hitEdge
    if inside(p, ol):
      return (if s.fill != bfNone or s.text.len > 0: hitFilled else: hitHollow)
  of skText, skNote, skImage:
    if inside(p, s.pageOutline) or distToLine(p, s.pageOutline, true) <= tol: return hitFilled
  of skFrame:
    let ol = s.pageOutline
    if distToLine(p, ol, true) <= tol + 2: return hitEdge
    let lb: Box = (s.x, s.y - 28, max(60.0, s.w), 28.0)
    if s.rot == 0 and lb.contains(x, y): return hitEdge
    if inside(p, ol): return hitHollow
  of skGroup: discard
  hitNone

proc topShapeAt*(b: Board; x, y, tol: float; skipLocked = true): int =
  ## The shape at a page point (its group if it is in one): the topmost on
  ## it, else the topmost hollow one round it; 0 none.
  var hollow = 0
  for i in countdown(b.page.shapes.high, 0):
    let s = b.page.shapes[i]
    if s.kind == skGroup or (skipLocked and s.locked): continue
    let h = b.hitTest(s, x, y, tol)
    if h in {hitEdge, hitFilled}:
      return (if s.parent != 0: s.parent else: s.id)
    if h == hitHollow and hollow == 0: hollow = (if s.parent != 0: s.parent else: s.id)
  hollow

proc shapesIn*(b: Board; box: Box; touching = false): seq[int] =
  ## The shapes inside a page box (or touching it); a group's members as their group.
  var seen: HashSet[int]
  for s in b.page.shapes:
    if s.kind == skGroup or s.locked: continue
    let bx = b.boundsOf(s)
    let ok = if touching: bx.overlaps(box)
             else: bx.x >= box.x and bx.y >= box.y and bx.x + bx.w <= box.x + box.w and
                   bx.y + bx.h <= box.y + box.h
    if ok:
      let id = if s.parent != 0: s.parent else: s.id
      if id notin seen:
        seen.incl id
        result.add id

proc members*(b: Board; ids: openArray[int]): seq[int] =
  ## `ids` with what their groups hold (the shapes that move with them).
  var seen: HashSet[int]
  var todo = @ids
  while todo.len > 0:
    let id = todo.pop()
    if id in seen: continue
    seen.incl id
    result.add id
    let s = b.find(id)
    if s != nil and s.kind == skGroup:
      for t in b.page.shapes:
        if t.parent == id: todo.add t.id

proc selectionBounds*(b: Board; ids: openArray[int]): Box =
  ## The page box round shapes `ids`.
  var any = false
  for id in ids:
    let s = b.find(id)
    if s == nil: continue
    let k = b.boundsOf(s[])
    result = if any: result.union(k) else: k
    any = true

# ---- moving, sizing, turning -----------------------------------------------------------------

proc moveBy*(s: var Shape; dx, dy: float) =
  ## Moves a shape (an arrow: its free ends).
  s.x += dx
  s.y += dy
  if s.kind == skArrow:
    if s.t0.bound == 0:
      s.t0.x += dx
      s.t0.y += dy
    if s.t1.bound == 0:
      s.t1.x += dx
      s.t1.y += dy

proc scaleAbout*(s: var Shape; ox, oy, sx, sy: float) =
  ## Sizes a shape about the page point (`ox`, `oy`) by `sx`, `sy`.
  let c = s.center
  let nc: V = (ox + (c.x - ox) * sx, oy + (c.y - oy) * sy)
  let ax = abs(sx)
  let ay = abs(sy)
  case s.kind
  of skArrow:
    for t in [addr s.t0, addr s.t1]:
      if t.bound == 0:
        t.x = ox + (t.x - ox) * sx
        t.y = oy + (t.y - oy) * sy
    s.bend *= sqrt(ax * ay) * (if sx * sy < 0: -1.0 else: 1.0)
  of skText:
    # (its letters, as much as it grew)
    let k = sqrt(ax * ay)
    s.scale = max(0.1, s.scale * k)
    s.w *= ax
    s.h *= ay
  else:
    let ow = s.w
    let oh = s.h
    s.w = max(1.0, ow * ax)
    s.h = max(1.0, oh * ay)
    if s.pts.len > 0:
      for p in s.pts.mitems:
        var x = p.x.float * (if ow > 0: s.w / ow else: 1.0)
        var y = p.y.float * (if oh > 0: s.h / oh else: 1.0)
        if sx < 0: x = s.w - x
        if sy < 0: y = s.h - y
        p.x = float32(x)
        p.y = float32(y)
  if sx < 0 and s.kind == skGeo: s.flipX = not s.flipX
  if sy < 0 and s.kind == skGeo: s.flipY = not s.flipY
  if sx * sy < 0 and s.kind != skArrow: s.rot = -s.rot
  if s.kind != skArrow:
    s.x = nc.x - s.w / 2
    s.y = nc.y - s.h / 2

proc rotateAbout*(s: var Shape; ox, oy, angle: float) =
  ## Turns a shape about the page point (`ox`, `oy`).
  let co = cos(angle)
  let si = sin(angle)
  proc turn(x, y: float): V = (ox + (x - ox) * co - (y - oy) * si, oy + (x - ox) * si + (y - oy) * co)
  if s.kind == skArrow:
    for t in [addr s.t0, addr s.t1]:
      if t.bound == 0:
        let p = turn(t.x, t.y)
        t.x = p.x
        t.y = p.y
    return
  let c = s.center
  let nc = turn(c.x, c.y)
  s.x = nc.x - s.w / 2
  s.y = nc.y - s.h / 2
  s.rot = floorMod(s.rot + angle + PI, 2 * PI) - PI

proc fitInk*(s: var Shape) =
  ## An ink or line shape's box made to fit its points (they keep their place).
  if s.pts.len == 0 or s.kind notin {skDraw, skHighlight, skLine}: return
  var x0, y0 = 1e30'f32
  var x1, y1 = -1e30'f32
  for p in s.pts:
    x0 = min(x0, p.x); y0 = min(y0, p.y); x1 = max(x1, p.x); y1 = max(y1, p.y)
  if s.rot == 0:
    for p in s.pts.mitems:
      p.x -= x0
      p.y -= y0
    s.x += x0.float
    s.y += y0.float
    s.w = max(1.0, float(x1 - x0))
    s.h = max(1.0, float(y1 - y0))

# ---- snapping ----------------------------------------------------------------------------------

type Guide* = tuple[x0, y0, x1, y1: float]
  ## A line to show where something snapped (page units).

proc snapBox*(b: Board; box: Box; skip: openArray[int]; tol: float): tuple[dx, dy: float; guides: seq[Guide]] =
  ## How far to move `box` so its edges or middle line up with another
  ## shape's (within `tol`), and the lines that show it.
  let sk = toHashSet(skip)
  var bestX = tol + 1
  var bestY = tol + 1
  let xs = [box.x, box.x + box.w / 2, box.x + box.w]
  let ys = [box.y, box.y + box.h / 2, box.y + box.h]
  var gx, gy: float
  var ox, oy: Box
  for s in b.page.shapes:
    if s.id in sk or s.kind == skGroup or (s.parent != 0 and s.parent in sk): continue
    let o = b.boundsOf(s)
    for tx in [o.x, o.x + o.w / 2, o.x + o.w]:
      for (i, x) in [(0, xs[0]), (1, xs[1]), (2, xs[2])]:
        let d = tx - x
        if abs(d) < abs(bestX):
          bestX = d
          gx = tx
          ox = o
    for ty in [o.y, o.y + o.h / 2, o.y + o.h]:
      for y in ys:
        let d = ty - y
        if abs(d) < abs(bestY):
          bestY = d
          gy = ty
          oy = o
  if abs(bestX) <= tol:
    result.dx = bestX
    let y0 = min(box.y, ox.y)
    let y1 = max(box.y + box.h, ox.y + ox.h)
    result.guides.add (gx, y0, gx, y1)
  if abs(bestY) <= tol:
    result.dy = bestY
    let x0 = min(box.x, oy.x)
    let x1 = max(box.x + box.w, oy.x + oy.w)
    result.guides.add (x0, gy, x1, gy)

# ---- making shapes -----------------------------------------------------------------------------

proc geoShape*(b: Board; g: GeoKind; x, y, w, h: float): Shape =
  ## A geometric shape in the box.
  result = b.newShape(skGeo, x, y, w, h)
  result.geo = g

proc textShape*(b: Board; x, y: float; text = ""): Shape =
  ## A text (as wide as its words) at a page point.
  result = b.newShape(skText, x, y, 10, 30)
  result.text = text
  result.autoSize = true
  result.align = baStart
  result.fitText()

proc noteShape*(b: Board; x, y: float; text = ""): Shape =
  ## A sticky note centered at a page point.
  result = b.newShape(skNote, x - 100, y - 100, 200, 200)
  result.color = bcYellow
  result.text = text

proc arrowShape*(b: Board; x0, y0, x1, y1: float): Shape =
  ## An arrow from one page point to another.
  result = b.newShape(skArrow, min(x0, x1), min(y0, y1), abs(x1 - x0), abs(y1 - y0))
  result.t0 = Terminal(x: x0, y: y0)
  result.t1 = Terminal(x: x1, y: y1)
  result.dash = bdDraw

# ---- groups ------------------------------------------------------------------------------------

proc groupShapes*(b: Board; ids: openArray[int]): int =
  ## Puts shapes `ids` in a group of their own; its id (0: fewer than two).
  var take: seq[int]
  for id in ids:
    let s = b.find(id)
    if s != nil and s.parent == 0: take.add id
  if take.len < 2: return 0
  var top = take[0]
  for i, s in b.page.shapes:
    if s.id in take: top = s.id
  var g = b.newShape(skGroup, 0, 0, 0, 0)
  let gid = b.addShape(g, above = top)
  for id in take:
    b.update(id, proc (s: var Shape) = s.parent = gid)
  gid

proc ungroupShapes*(b: Board; id: int): seq[int] =
  ## Takes group `id` apart; what was in it.
  let s = b.find(id)
  if s == nil or s.kind != skGroup: return
  for t in b.page.shapes:
    if t.parent == id: result.add t.id
  for k in result:
    b.update(k, proc (s: var Shape) = s.parent = 0)
  b.removeShape(id)

# ---- more than one shape ----------------------------------------------------------------

proc toJson*(s: Shape): JsonNode
  ## A shape as JSON, as a saved board keeps it (`shapeFrom` reads it back).
proc shapeFrom*(j: JsonNode): Shape
  ## A shape from its JSON (`toJson`); a field that is missing or unknown
  ## gets its default.
proc keepPictures(b: Board; s: var Shape; assets: JsonNode)

proc shapesOf*(b: Board; ids: openArray[int]): seq[Shape] =
  ## Shapes `ids` with what their groups hold, back to front.
  let want = toHashSet(b.members(ids))
  for s in b.page.shapes:
    if s.id in want: result.add s

proc moveShapes*(b: Board; ids: openArray[int]; dx, dy: float) =
  ## Moves shapes `ids` (and what their groups hold).
  for m in b.members(ids):
    b.update(m, proc (s: var Shape) = s.moveBy(dx, dy))

proc roughBounds*(shapes: openArray[Shape]): Box =
  ## The page box round shapes that need not be on a page (their boxes, an
  ## arrow's ends).
  var any = false
  for s in shapes:
    let k: Box =
      case s.kind
      of skGroup: continue
      of skArrow: boxOf([(s.t0.x, s.t0.y), (s.t1.x, s.t1.y)])
      else: boxOf(s.pageOutline)
    result = if any: result.union(k) else: k
    any = true

proc detached(b: Board; shapes: openArray[Shape]): seq[Shape] =
  ## (the shapes with their arrows' ends where they are drawn, letting go
  ## of the shapes not among them)
  var ids: HashSet[int]
  for s in shapes: ids.incl s.id
  for s in shapes:
    var t = s
    if t.kind == skArrow:
      let (p0, p1) = b.arrowEnds(s)
      t.t0.x = p0.x
      t.t0.y = p0.y
      t.t1.x = p1.x
      t.t1.y = p1.y
      if t.t0.bound notin ids: t.t0.bound = 0
      if t.t1.bound notin ids: t.t1.bound = 0
    result.add t

proc cloneShapes*(b: Board; shapes: openArray[Shape]; dx, dy: float): seq[int] =
  ## Puts copies of `shapes` on the page shown, moved by `dx`, `dy`: groups
  ## keep what they hold, arrows the shapes they hold among them (the others
  ## they let go of where they end). The new ids of the top ones.
  var idMap: Table[int, int]
  for s in shapes:
    inc b.nextId
    idMap[s.id] = b.nextId
  for s in b.detached(shapes):
    var t = s
    t.id = idMap[s.id]
    t.parent = idMap.getOrDefault(s.parent, 0)
    if t.t0.bound != 0: t.t0.bound = idMap[t.t0.bound]
    if t.t1.bound != 0: t.t1.bound = idMap[t.t1.bound]
    t.moveBy(dx, dy)
    t.ver = b.stamp
    b.touch(t.id)
    b.page.shapes.add t
    if t.parent == 0: result.add t.id
  inc b.ver

proc duplicate*(b: Board; ids: openArray[int]; dx = 16.0; dy = 16.0): seq[int] =
  ## Copies of shapes `ids`, a little down and right; their ids.
  b.cloneShapes(b.shapesOf(ids), dx, dy)

proc toClipboard*(b: Board; ids: openArray[int]): string =
  ## Shapes `ids` as text for the clipboard (`fromClipboard`), their
  ## pictures with them.
  var a = newJArray()
  var assets = newJObject()
  for s in b.shapesOf(ids):
    a.add s.toJson
    if s.image.startsWith("asset:") and s.image in b.assets and s.image notin assets:
      assets[s.image] = %encode(b.assets[s.image])
  $(%*{"format": "retro-board-clip", "shapes": a, "assets": assets})

proc fromClipboard*(b: Board; text: string): seq[Shape] =
  ## The shapes in clipboard text (none: not shapes); their pictures put
  ## among the board's.
  if not text.startsWith("{"): return
  try:
    let j = parseJson(text)
    if j{"format"}.getStr != "retro-board-clip": return
    for sj in j{"shapes"}.getElems:
      var s = shapeFrom(sj)
      b.keepPictures(s, j{"assets"})
      result.add s
  except CatchableError: result = @[]

proc pasteShapes*(b: Board; shapes: openArray[Shape]; x, y: float): seq[int] =
  ## Copies of `shapes` centered on the page point (`x`, `y`); their ids.
  let box = roughBounds(b.detached(shapes))
  b.cloneShapes(shapes, x - (box.x + box.w / 2), y - (box.y + box.h / 2))

proc alignShapes*(b: Board; ids: openArray[int]; how: string) =
  ## Lines shapes `ids` up with each other: "left", "center", "right",
  ## "top", "middle", "bottom".
  let box = b.selectionBounds(ids)
  for id in ids:
    let s = b.find(id)
    if s == nil: continue
    let k = b.boundsOf(s[])
    var dx, dy = 0.0
    case how
    of "left": dx = box.x - k.x
    of "center": dx = box.x + box.w / 2 - (k.x + k.w / 2)
    of "right": dx = box.x + box.w - (k.x + k.w)
    of "top": dy = box.y - k.y
    of "middle": dy = box.y + box.h / 2 - (k.y + k.h / 2)
    of "bottom": dy = box.y + box.h - (k.y + k.h)
    else: discard
    if dx != 0 or dy != 0: b.moveShapes([id], dx, dy)

proc distribute*(b: Board; ids: openArray[int]; horizontal: bool) =
  ## Spaces shapes `ids` evenly between the first and the last, across or
  ## down.
  var items: seq[tuple[c: float; id: int; k: Box]]
  for id in ids:
    let s = b.find(id)
    if s == nil: continue
    let k = b.boundsOf(s[])
    items.add ((if horizontal: k.x + k.w / 2 else: k.y + k.h / 2), id, k)
  if items.len < 3: return
  items.sort(proc (a, c: tuple[c: float; id: int; k: Box]): int = cmp(a.c, c.c))
  var room = 0.0
  for it in items: room += (if horizontal: it.k.w else: it.k.h)
  let first = items[0].k
  let last = items[^1].k
  let span = if horizontal: last.x + last.w - first.x else: last.y + last.h - first.y
  let gap = (span - room) / float(items.high)
  var at = if horizontal: first.x + first.w + gap else: first.y + first.h + gap
  for i in 1 ..< items.high:
    let k = items[i].k
    if horizontal:
      b.moveShapes([items[i].id], at - k.x, 0)
      at += k.w + gap
    else:
      b.moveShapes([items[i].id], 0, at - k.y)
      at += k.h + gap

proc flipShapes*(b: Board; ids: openArray[int]; horizontal: bool) =
  ## Mirrors shapes `ids` across their middle (left to right, or upside down).
  let box = b.selectionBounds(ids)
  let cx = box.x + box.w / 2
  let cy = box.y + box.h / 2
  for m in b.members(ids):
    b.update(m, proc (s: var Shape) =
      if horizontal: s.scaleAbout(cx, cy, -1, 1) else: s.scaleAbout(cx, cy, 1, -1))

proc contentsOf*(b: Board; frame: int): seq[int] =
  ## What is inside frame `frame` (wholly; a group's shapes as their group).
  let f = b.find(frame)
  if f == nil or f.kind != skFrame: return
  for id in b.shapesIn(boxOf(f[].pageOutline)):
    if id != frame: result.add id

proc addConnected*(b: Board; id: int; dx, dy: int): tuple[shape, arrow: int] =
  ## The next step of a flowchart: a shape like `id` (without its words)
  ## beside it -- right (`dx` 1), left, down (`dy` 1), up -- where there is
  ## room, and an arrow from it to the new one.
  let s = b.find(id)
  if s == nil or s.kind notin {skGeo, skNote, skText, skImage, skFrame}: return
  var t = s[]
  t.text = ""
  t.parent = 0
  t.link = ""
  if t.kind == skText:
    t = b.newShape(skGeo, t.x, t.y, max(120.0, t.w), max(70.0, t.h))
    t.color = s.color
  let gapX = max(60.0, t.w * 0.5)
  let gapY = max(60.0, t.h * 0.6)
  t.x = s.x + float(dx) * (s.w + gapX)
  t.y = s.y + float(dy) * (s.h + gapY)
  if dx != 0: t.y = s.y + s.h / 2 - t.h / 2
  if dy != 0: t.x = s.x + s.w / 2 - t.w / 2
  # (not on another: further along the side, in turn)
  var shifted = false
  for k in 0 ..< 24:
    let box: Box = (t.x - 10, t.y - 10, t.w + 20, t.h + 20)
    var free = true
    for o in b.page.shapes:
      if o.kind notin {skGroup, skArrow} and o.id != id and b.boundsOf(o).overlaps(box):
        free = false
        break
    if free: break
    shifted = true
    if dx != 0: t.y += t.h + gapY / 2 else: t.x += t.w + gapX / 2
  # (the arrow's look read first: `s` points into the page's shapes, which
  # move when the new one is added)
  let look = (color: s.color, dash: s.dash, size: s.size, roughness: s.roughness)
  let nid = b.addShape(t)
  var ar = b.arrowShape(0, 0, 0, 0)
  ar.color = look.color
  ar.dash = look.dash
  ar.size = look.size
  ar.roughness = look.roughness
  ar.elbow = shifted
  ar.t0 = Terminal(bound: id, nx: 0.5, ny: 0.5)
  ar.t1 = Terminal(bound: nid, nx: 0.5, ny: 0.5)
  (nid, b.addShape(ar))

proc findText*(b: Board; query: string): seq[tuple[page, id: int]] =
  ## The shapes whose words hold `query` (case aside), page by page.
  let q = unicode.toLower(query.strip)
  if q.len == 0: return
  for pi, p in b.pages:
    for s in p.shapes:
      if s.text.len > 0 and unicode.toLower(s.text).contains(q): result.add (pi, s.id)

# ---- files -------------------------------------------------------------------------------------

proc toJson*(s: Shape): JsonNode =
  ## (see the declaration above)
  result = %*{"id": s.id, "kind": $s.kind, "x": s.x, "y": s.y, "w": s.w, "h": s.h, "rot": s.rot,
              "color": $s.color, "fill": $s.fill, "dash": $s.dash, "size": $s.size, "font": $s.font,
              "align": $s.align, "valign": $s.valign, "opacity": s.opacity}
  if s.parent != 0: result["parent"] = %s.parent
  if s.kind == skGeo: result["geo"] = %($s.geo)
  if s.flipX: result["flipX"] = %true
  if s.flipY: result["flipY"] = %true
  if s.text.len > 0: result["text"] = %s.text
  if s.scale != 1: result["scale"] = %s.scale
  if s.autoSize: result["autoSize"] = %true
  if s.pts.len > 0:
    var a = newJArray()
    for p in s.pts:
      a.add %(round(p.x.float * 100) / 100)
      a.add %(round(p.y.float * 100) / 100)
      a.add %(round(p.p.float * 100) / 100)
    result["pts"] = a
  if s.isPen: result["isPen"] = %true
  if s.closed: result["closed"] = %true
  if s.spline: result["spline"] = %true
  if s.kind == skArrow:
    for (k, t) in [("start", s.t0), ("end", s.t1)]:
      result[k] = %*{"x": t.x, "y": t.y, "bound": t.bound, "nx": t.nx, "ny": t.ny, "precise": t.precise}
    result["bend"] = %s.bend
    result["headStart"] = %($s.head0)
    result["headEnd"] = %($s.head1)
  if s.locked: result["locked"] = %true
  if s.fillColor > 0: result["fillColor"] = %($s.fillOf)
  if s.roughness != 0: result["roughness"] = %s.roughness
  if s.round: result["round"] = %true
  if s.elbow: result["elbow"] = %true
  if s.link.len > 0: result["link"] = %s.link
  if s.image.len > 0:
    # (a key of the board's pictures; bytes of a shape made before them, as text)
    result["image"] = %(if s.image.startsWith("asset:"): s.image else: encode(s.image))

proc enumOf[T: enum](j: JsonNode; key: string; default: T): T =
  let v = j{key}.getStr
  for e in T:
    if $e == v: return e
  default

proc shapeFrom*(j: JsonNode): Shape =
  ## (see the declaration above)
  result.id = j{"id"}.getInt
  result.kind = enumOf(j, "kind", skGeo)
  result.x = j{"x"}.getFloat
  result.y = j{"y"}.getFloat
  result.w = j{"w"}.getFloat
  result.h = j{"h"}.getFloat
  result.rot = j{"rot"}.getFloat
  result.parent = j{"parent"}.getInt
  result.color = enumOf(j, "color", bcBlack)
  result.fill = enumOf(j, "fill", bfNone)
  result.dash = enumOf(j, "dash", bdDraw)
  result.size = enumOf(j, "size", bsM)
  result.font = enumOf(j, "font", bfnSans)
  result.align = enumOf(j, "align", baMiddle)
  result.valign = enumOf(j, "valign", baMiddle)
  result.opacity = j{"opacity"}.getFloat(1)
  result.geo = enumOf(j, "geo", gkRectangle)
  result.flipX = j{"flipX"}.getBool
  result.flipY = j{"flipY"}.getBool
  result.text = j{"text"}.getStr
  result.scale = j{"scale"}.getFloat(1)
  result.autoSize = j{"autoSize"}.getBool
  let a = j{"pts"}
  if a != nil and a.kind == JArray:
    var i = 0
    while i + 2 < a.len:
      result.pts.add (float32(a[i].getFloat), float32(a[i + 1].getFloat), float32(a[i + 2].getFloat))
      i += 3
  result.isPen = j{"isPen"}.getBool
  result.closed = j{"closed"}.getBool
  result.spline = j{"spline"}.getBool
  for (k, t) in [("start", addr result.t0), ("end", addr result.t1)]:
    let n = j{k}
    if n != nil:
      t[] = Terminal(x: n{"x"}.getFloat, y: n{"y"}.getFloat, bound: n{"bound"}.getInt, nx: n{"nx"}.getFloat,
                     ny: n{"ny"}.getFloat, precise: n{"precise"}.getBool)
  result.bend = j{"bend"}.getFloat
  result.head0 = enumOf(j, "headStart", ahNone)
  result.head1 = enumOf(j, "headEnd", ahArrow)
  result.locked = j{"locked"}.getBool
  if j{"fillColor"} != nil: result.fillColor = ord(enumOf(j, "fillColor", bcBlack)) + 1
  result.roughness = clamp(j{"roughness"}.getInt, -1, 1)
  result.round = j{"round"}.getBool
  result.elbow = j{"elbow"}.getBool
  result.link = j{"link"}.getStr
  result.image = j{"image"}.getStr      # (a key; or, from an older file, the bytes as base64)
  result.ver = 1

proc keepPictures(b: Board; s: var Shape; assets: JsonNode) =
  ## (a picture shape read: its bytes among the board's, by key)
  if s.image.len == 0: return
  if s.image.startsWith("asset:"):
    if s.image notin b.assets and assets != nil and assets{s.image} != nil:
      try: b.assets[s.image] = unbase64(assets{s.image}.getStr)
      except CatchableError: discard
  else:
    try: s.image = b.addAsset(unbase64(s.image))
    except CatchableError: s.image = ""

proc toJson*(b: Board): JsonNode =
  ## The whole board (its pages, their shapes and views) as JSON.
  result = %*{"format": "retro-board", "version": BoardFileVersion, "name": b.name, "cur": b.cur,
               "nextId": b.nextId}
  if b.paper != 0: result["paper"] = %b.paper
  var ps = newJArray()
  for p in b.pages:
    var ss = newJArray()
    for s in p.shapes: ss.add s.toJson
    ps.add %*{"id": p.id, "name": p.name, "camX": p.camX, "camY": p.camY, "zoom": p.zoom, "shapes": ss}
  result["pages"] = ps
  # (the pictures the pages show; not those only a step to undo would)
  var assets = newJObject()
  for p in b.pages:
    for s in p.shapes:
      if s.image.startsWith("asset:") and s.image notin assets and s.image in b.assets:
        assets[s.image] = %encode(b.assets[s.image])
  if assets.len > 0: result["assets"] = assets

proc boardFrom*(j: JsonNode): Board =
  ## A board saved with `toJson` (nil: not one).
  if j == nil or j.kind != JObject or j{"format"}.getStr != "retro-board": return nil
  result = Board(name: j{"name"}.getStr)
  let before = j{"version"}.getInt(1) < 2       # (smaller letters then: kept so)
  var maxId = 0
  for pj in j{"pages"}.getElems:
    let p = Page(id: pj{"id"}.getInt, name: pj{"name"}.getStr("Page"), camX: pj{"camX"}.getFloat,
                 camY: pj{"camY"}.getFloat, zoom: pj{"zoom"}.getFloat(1))
    if p.zoom <= 0: p.zoom = 1
    maxId = max(maxId, p.id)
    for sj in pj{"shapes"}.getElems:
      var s = shapeFrom(sj)
      if before and s.hasText:
        s.scale = (if s.scale > 0: s.scale else: 1.0) * oldFontSizes[s.size] / fontSizes[s.size]
      result.keepPictures(s, j{"assets"})
      maxId = max(maxId, s.id)
      p.shapes.add s
    result.pages.add p
  if result.pages.len == 0: result.pages.add Page(id: 1, name: "Page 1", zoom: 1)
  result.nextId = max(maxId, j{"nextId"}.getInt)
  result.cur = clamp(j{"cur"}.getInt, 0, result.pages.high)
  result.paper = clamp(j{"paper"}.getInt, 0, paperColors.high)

proc saveBoard*(b: Board; path: string) =
  ## Writes the board to `path` (JSON), safely (a part file first).
  let tmp = path & ".part"
  writeFile(tmp, $b.toJson)
  moveFile(tmp, path)
  b.path = path
  b.modified = false

proc loadBoard*(path: string): Board =
  ## A board from a file (nil: not one).
  try:
    result = boardFrom(parseJson(readFile(path)))
    if result != nil: result.path = path
  except CatchableError: result = nil

# ---- pictures of it ----------------------------------------------------------------------------

proc pictureOf*(b: Board; s: Shape): Bitmap =
  ## A picture shape's picture (nil: none or not readable).
  let data = b.assetOf(s.image)
  if data.len == 0: return nil
  try:
    if data.startsWith("\x89PNG"): return decodePng(data)
    if data.startsWith("\xFF\xD8"): return decodeJpeg(data)
    if data.startsWith("BM"): return decodeBmp(data)
  except CatchableError: result = nil

proc renderBitmap*(b: Board; ids: openArray[int]; scale = 1.0; background = true; padding = 32.0;
                   pictures: proc (s: Shape): Bitmap = nil; brief = false): Bitmap =
  ## Shapes `ids` (all of the page shown, when none) as a picture, `scale`
  ## pixels a page unit, on the canvas's color (or transparent), with
  ## `padding` round them. `pictures` gives a picture shape's picture.
  ## `brief`: shapes too small to read drawn in brief (`briefAt`): a
  ## page's small picture, fast.
  var list: seq[int]
  if ids.len == 0:
    for s in b.page.shapes:
      if s.kind != skGroup: list.add s.id
  else: list = b.members(ids)
  let want = toHashSet(list)
  var box = b.selectionBounds(list)
  if box.w <= 0 or box.h <= 0: box = (0.0, 0.0, 100.0, 100.0)
  box = (box.x - padding, box.y - padding, box.w + 2 * padding, box.h + 2 * padding)
  let w = clamp(int(ceil(box.w * scale)), 1, 8192)
  let h = clamp(int(ceil(box.h * scale)), 1, 8192)
  result = newBitmap(w, h, if background: b.paperOf else: 0'u32)
  let k = scale
  proc blend(dst: var uint32; c: uint32; cov: int) =
    let a = (int((c shr 24) and 255) * cov + 127) div 255
    if a == 0: return
    let da = int((dst shr 24) and 255)
    let oa = a + da * (255 - a) div 255
    if oa == 0: return
    proc ch(v: uint32; s: int): int = int((v shr s) and 255)
    let r = (ch(c, 16) * a + ch(dst, 16) * da * (255 - a) div 255) div oa
    let g = (ch(c, 8) * a + ch(dst, 8) * da * (255 - a) div 255) div oa
    let bl = (ch(c, 0) * a + ch(dst, 0) * da * (255 - a) div 255) div oa
    dst = (uint32(oa) shl 24) or (uint32(r) shl 16) or (uint32(g) shl 8) or uint32(bl)
  for s in b.page.shapes:
    if s.id notin want or s.kind == skGroup: continue
    if s.kind == skImage and s.image.len > 0:
      let pic = if pictures != nil: pictures(s) else: b.pictureOf(s)
      if pic != nil and pic.w > 0 and pic.h > 0:
        # (as it stands, turned: each pixel from the picture)
        let ol = s.pageOutline
        let bx = boxOf(ol)
        let x0 = max(0, int(floor((bx.x - box.x) * k)))
        let y0 = max(0, int(floor((bx.y - box.y) * k)))
        let x1 = min(w, int(ceil((bx.x + bx.w - box.x) * k)))
        let y1 = min(h, int(ceil((bx.y + bx.h - box.y) * k)))
        for yy in y0 ..< y1:
          for xx in x0 ..< x1:
            let lp = s.toLocal(box.x + (xx.float + 0.5) / k, box.y + (yy.float + 0.5) / k)
            if lp.x < 0 or lp.y < 0 or lp.x >= s.w or lp.y >= s.h: continue
            let px = clamp(int(lp.x / s.w * pic.w.float), 0, pic.w - 1)
            let py = clamp(int(lp.y / s.h * pic.h.float), 0, pic.h - 1)
            let c = pic.px[py * pic.w + px]
            blend(result.px[yy * w + xx], c.withAlpha(s.opacity), 255)
      continue
    for piece in b.drawingOf(s, brief and b.briefAt(s, k)).pieces:
      if piece.contours.len == 0: continue
      var pts: seq[V]
      for c in piece.contours:
        for p in c: pts.add (p[0], p[1])
      let pb = boxOf(pts)
      let x0 = max(0, int(floor((pb.x - box.x) * k)) - 1)
      let y0 = max(0, int(floor((pb.y - box.y) * k)) - 1)
      let x1 = min(w, int(ceil((pb.x + pb.w - box.x) * k)) + 2)
      let y1 = min(h, int(ceil((pb.y + pb.h - box.y) * k)) + 2)
      if x1 <= x0 or y1 <= y0: continue
      let rw = x1 - x0
      let rh = y1 - y0
      var r = newRaster(rw, rh)
      for c in piece.contours:
        if c.len < 3: continue
        for i in 0 ..< c.len:
          let a = c[i]
          let d = c[(i + 1) mod c.len]
          r.line(float32((a[0] - box.x) * k - x0.float), float32((a[1] - box.y) * k - y0.float),
                 float32((d[0] - box.x) * k - x0.float), float32((d[1] - box.y) * k - y0.float))
      let cov = r.coverage()
      for yy in 0 ..< rh:
        for xx in 0 ..< rw:
          let cv = int(cov[yy * rw + xx])
          if cv > 0: blend(result.px[(y0 + yy) * w + x0 + xx], piece.color, cv)
  result.changed()

proc svgColor(c: uint32): (string, float) =
  ("#" & toHex(int(c and 0xFFFFFF), 6).toLowerAscii, float((c shr 24) and 255) / 255)

proc toSvg*(b: Board; ids: openArray[int]; background = true; padding = 32.0): string =
  ## Shapes `ids` (all of the page shown, when none) as an SVG picture:
  ## their outlines (text too), pictures embedded.
  var list: seq[int]
  if ids.len == 0:
    for s in b.page.shapes:
      if s.kind != skGroup: list.add s.id
  else: list = b.members(ids)
  let want = toHashSet(list)
  var box = b.selectionBounds(list)
  if box.w <= 0 or box.h <= 0: box = (0.0, 0.0, 100.0, 100.0)
  box = (box.x - padding, box.y - padding, box.w + 2 * padding, box.h + 2 * padding)
  proc n(v: float): string = formatFloat(v, ffDecimal, 2).strip(leading = false, chars = {'0'}).strip(
    leading = false, chars = {'.'})
  result = "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" " &
           "width=\"" & n(box.w) & "\" height=\"" & n(box.h) & "\" viewBox=\"" & n(box.x) & " " & n(box.y) &
           " " & n(box.w) & " " & n(box.h) & "\">\n"
  if background:
    let (c, _) = svgColor(b.paperOf)
    result.add "<rect x=\"" & n(box.x) & "\" y=\"" & n(box.y) & "\" width=\"" & n(box.w) & "\" height=\"" &
               n(box.h) & "\" fill=\"" & c & "\"/>\n"
  for s in b.page.shapes:
    if s.id notin want or s.kind == skGroup: continue
    if s.kind == skImage and s.image.len > 0:
      let data = b.assetOf(s.image)
      let mime = if data.startsWith("\x89PNG"): "image/png" else: "image/jpeg"
      let c = s.center
      result.add "<image x=\"" & n(s.x) & "\" y=\"" & n(s.y) & "\" width=\"" & n(s.w) & "\" height=\"" & n(s.h) &
                 "\" opacity=\"" & n(s.opacity) & "\" transform=\"rotate(" & n(radToDeg(s.rot)) & " " & n(c.x) &
                 " " & n(c.y) & ")\" preserveAspectRatio=\"none\" xlink:href=\"data:" & mime & ";base64," &
                 encode(data) & "\"/>\n"
      continue
    for piece in b.drawingOf(s).pieces:
      var d = ""
      for c in piece.contours:
        if c.len < 3: continue
        d.add "M" & n(c[0][0]) & " " & n(c[0][1])
        for i in 1 ..< c.len: d.add "L" & n(c[i][0]) & " " & n(c[i][1])
        d.add "Z"
      if d.len == 0: continue
      let (col, a) = svgColor(piece.color)
      result.add "<path d=\"" & d & "\" fill=\"" & col & "\"" &
                 (if a < 0.999: " fill-opacity=\"" & n(a) & "\"" else: "") & " fill-rule=\"nonzero\"/>\n"
  result.add "</svg>\n"

proc exportList(b: Board; ids: openArray[int]; padding: float): (seq[int], Box) =
  var list: seq[int]
  if ids.len == 0:
    for s in b.page.shapes:
      if s.kind != skGroup: list.add s.id
  else: list = b.members(ids)
  var box = b.selectionBounds(list)
  if box.w <= 0 or box.h <= 0: box = (0.0, 0.0, 100.0, 100.0)
  (list, (box.x - padding, box.y - padding, box.w + 2 * padding, box.h + 2 * padding))

proc toPdf*(b: Board; ids: openArray[int]; background = true; padding = 32.0): string =
  ## Shapes `ids` (all of the page shown, when none) as a one-page PDF of
  ## their outlines (text too), a point a page unit (smaller when larger
  ## than PDF allows), pictures embedded.
  let (list, box) = b.exportList(ids, padding)
  let want = toHashSet(list)
  let k = min(1.0, 14000.0 / max(box.w, box.h))
  let d = newPdf(title = (if b.name.len > 0: b.name else: "Board"), creator = "Retro Board")
  let pg = d.addPage((box.w * k, box.h * k))
  proc col(c: uint32): Color =
    Color(r: uint8((c shr 16) and 255), g: uint8((c shr 8) and 255), b: uint8(c and 255), a: 255)
  if background:
    pg.fillColor(col(b.paperOf))
    pg.rect(0, 0, box.w * k, box.h * k)
    pg.fill()
  for s in b.page.shapes:
    if s.id notin want or s.kind == skGroup: continue
    if s.kind == skImage and s.image.len > 0:
      let x = (s.x - box.x) * k
      let y = (s.y - box.y) * k
      let data = b.assetOf(s.image)
      if data.startsWith("\xFF\xD8"):
        if pg.jpegImage(data, x, y, s.w * k, s.h * k): continue
      let pic = b.pictureOf(s)
      if pic != nil: pg.image(pic, x, y, s.w * k, s.h * k)
      continue
    for piece in b.drawingOf(s).pieces:
      if piece.contours.len == 0: continue
      pg.fillColor(col(piece.color))
      pg.opacity(float((piece.color shr 24) and 255) / 255)
      for c in piece.contours:
        if c.len < 3: continue
        pg.moveTo((c[0][0] - box.x) * k, (c[0][1] - box.y) * k)
        for i in 1 ..< c.len: pg.lineTo((c[i][0] - box.x) * k, (c[i][1] - box.y) * k)
        pg.closePath()
      pg.fill()
  pg.opacity(1)
  d.render()

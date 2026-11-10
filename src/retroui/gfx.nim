## The drawing layer.
##
## Widgets record small commands (fills, text, dots, images) into layers.
## `present` rasterizes them into one software framebuffer -- only the tiles
## whose commands changed -- and hands those to uirelays' `blitRGBA`: the
## same pixels on every platform, nothing drawn or sent when nothing
## changed.

import std/[tables, math, strutils, algorithm, hashes]
import std/unicode except strip   # (its strip cuts letters: docs/nim-bugs.md)
from std/os import getEnv, fileExists, removeFile, createDir, parentDir

when (defined(gcc) or defined(clang)) and not defined(retroSizeOnly):
  # (the loops over every pixel: compiled for speed even in an app built for
  # size, --opt:size -- they draw two to three times as fast so, for a few
  # kilobytes)
  {.localPassC: "-O3".}
from std/strutils import toLowerAscii, contains
import uirelays/[coords, screen]
import ttf, typeset, raster, parallel

proc hashF*(x: float): Hash {.inline.} =
  ## A float's hash from all its bits. (Nim's `hash(float)` keeps only the
  ## low 32 of them on a 32-bit system -- WebAssembly is one -- where 1.0,
  ## 1.5 and 2.0 hash alike: a cache keyed so would not see a new size.)
  hashWangYi1(cast[int64](x + 0.0))

export typeset.textIsRtl, typeset.strongDir, typeset.setRtlInterface

export coords.Rect, coords.rect, coords.Point, coords.point, coords.contains
export screen.Color, screen.color

const
  sansName = "FreeSans"
  serifName = "FreeSerif"
  monoName = "FreeMono"

type
  CmdKind = enum ckFill, ckDots, ckImage, ckSysText, ckLine, ckBitmap,
    ckVText, ckPath, ckPixIcon, ckAnts, ckTex, ckChecker
  Cmd = object
    kind: CmdKind
    bold: bool
    flags: uint8          ## vector text: TextStyle bits
    mag: int32            ## image magnification
    size: float32         ## vector text: size in ems of the UI's text
    h: uint64             ## what it draws, hashed (for partial redraws)
    color: uint32         ## 0x00RRGGBB
    r: Rect               ## fill rect, text origin, dots rect, image dst
    clip: Rect
    a, b: int32           ## text: arena range -- image: pixel offset, width

  Icon* = object
    ## A small picture, 0xAARRGGBB per pixel; alpha 0 is transparent. Or,
    ## when `glyph` is set, a character of the icon font (see `nerdicons`)
    ## drawn in `tint`, filling a `w` x `h` box at any scale.
    w*, h*: int          ## size in logical pixels
    px*: seq[uint32]     ## the pixels, row by row (empty for a glyph)
    glyph*: string       ## a character of the icon font (empty for a picture)
    tint*: Color         ## the glyph's color

  TextStyle* = object
    ## How text looks. The default is the UI's regular text.
    bold*, italic*, mono*, underline*, strike*: bool
    rtl*: bool           ## a right-to-left paragraph (else: from the text)
    size*: float32       ## times the UI's text size (0 or 1: the same)
    serif*: bool         ## in the serif font (FreeSerif), whatever the UI's

  UiFont* = enum
    ## The font of the UI's text (see `setUiFont`).
    ufSans = sansName          ## FreeSans, the default: GNU FreeFont's Helvetica-like sans
    ufSerif = serifName        ## FreeSerif: GNU FreeFont's Times-like serif
    ufMono = monoName          ## FreeMono: GNU FreeFont's Courier-like monospaced font
    ufFile = "Font File"       ## a font from a file (`setUiFontFile`): one of the user's,
                               ## or the app's own (-d:retroAppFont)

  Bitmap* = ref object
    ## A picture of any size (a photo, a thumbnail), 0xAARRGGBB per pixel.
    ## Drawn scaled at the screen's full resolution. Call `changed` after
    ## editing `px` (with the rectangle that changed, when it is a part:
    ## only that part of the screen is drawn again).
    w*, h*: int
    px*: seq[uint32]
    opaque*: bool        ## every pixel's alpha is 255 (drawn by copying)
    stamp: uint64        ## any change
    whole: uint64        ## the last change of all of it
    dirty: Rect          ## what changed since the screen last showed it

const MaxLayers* = 4
  ## Drawing layers (0 the window, then popups, menus, tooltips: `setLayer`).

var
  layers: array[MaxLayers, seq[Cmd]]
  curLayer: int
  arena: string
  imgArena: seq[uint32]
  pathArena: seq[float32]
  frameBitmaps: seq[Bitmap]
  bitmapStamps: int      ## (atomic: worker threads make bitmaps too)
  clipStack: seq[Rect]
  curClip: Rect
  fb: seq[uint32]
  fbMem: ptr UncheckedArray[uint32]   ## the frame's pixels: `fb`'s, or the
                                      ## window's own (`lockSurface`)
  fbSurface = false                   ## fbMem is the driver's buffer
  surfaceWanted = getEnv("RETRO_SURFACE") != "0"
    ## the window's own pixels used when the driver lends them
    ## ($RETRO_SURFACE=0: never -- to compare)
  fbW, fbH: int
  frameHash, shownHash: uint64
  clearColor: uint32
  pxScale* = 1      ## device pixels per logical pixel
  unitPx* = 1       ## device pixels per driver coordinate unit
  zoom* = 1         ## driver coordinate units per logical pixel
  sysFont: Font
  sysFontSize = 0
  textEm = 12'f32       ## the UI's text size: logical pixels per em
  uiFontSel = ufSans
    ## the UI's font
  FontH* = 15           ## height of a line of the UI's text, logical pixels
  FontAscent* = 12      ## from a line's top to its baseline
  textLut: array[256, uint8]
    ## small text's coverage made a little darker (as it always was)

when defined(windows) and not defined(retroFake):
  proc SystemParametersInfoW(action, param: uint32; pv: pointer; winIni: uint32): int32 {.
    stdcall, dynlib: "user32", importc.}

proc screenStripsBgr(): bool =
  ## The screen's color strips are blue, green, red from the left (Windows
  ## knows it from ClearType's setting; elsewhere red, green, blue).
  when defined(windows) and not defined(retroFake):
    var order: uint32 = 1
    result = SystemParametersInfoW(0x2012, 0, addr order, 0) != 0 and order == 0
  result = result or getEnv("RETRO_TEXT") == "sharp-bgr"

var
  subpixelSel = getEnv("RETRO_TEXT") in ["sharp", "sharp-bgr"]
    ## text in the color strips (`setSubpixelText`): off unless asked for
  lcdBgr = screenStripsBgr()

const MaskSlots = 8192
var
  maskKeys: array[MaskSlots, uint64]   ## rendered glyphs, direct mapped
  maskSlots: array[MaskSlots, Mask]

proc forgetGlyphs() =
  ## The rendered glyphs let go of (another size, font or kind of text:
  ## none of them is drawn again -- their memory is not kept either).
  for k in maskKeys.mitems: k = 0
  for m in maskSlots.mitems:
    if m.a.len > 0: m = Mask()

proc pack(c: Color): uint32 {.inline.} =
  (c.r.uint32 shl 16) or (c.g.uint32 shl 8) or c.b.uint32

proc mix(h: var uint64; x: uint64) {.inline.} =
  h = (h xor x) * 0x9E3779B97F4A7C15'u64
  h = h xor (h shr 29)

proc mixRect(h: var uint64; r: Rect) {.inline.} =
  mix(h, cast[uint64](r.x) xor (cast[uint64](r.y) shl 32))
  mix(h, cast[uint64](r.w) xor (cast[uint64](r.h) shl 32))

proc union*(a, b: Rect): Rect =
  ## The smallest rectangle holding both.
  if a.w <= 0 or a.h <= 0: return b
  if b.w <= 0 or b.h <= 0: return a
  let x0 = min(a.x, b.x)
  let y0 = min(a.y, b.y)
  rect(x0, y0, max(a.x + a.w, b.x + b.w) - x0, max(a.y + a.h, b.y + b.h) - y0)

proc intersect*(a, b: Rect): Rect =
  ## The part of `a` that is also in `b` (0 wide or high when they do not
  ## meet).
  let x0 = max(a.x, b.x)
  let y0 = max(a.y, b.y)
  let x1 = min(a.x + a.w, b.x + b.w)
  let y1 = min(a.y + a.h, b.y + b.h)
  rect(x0, y0, max(0, x1 - x0), max(0, y1 - y0))


proc intersects*(a, b: Rect): bool =
  ## `a` and `b` share some room (rectangles of no size share none).
  a.w > 0 and a.h > 0 and b.w > 0 and b.h > 0 and
    a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h

proc inset*(r: Rect; d: int): Rect =
  ## `r` shrunk by `d` on every side (never below 0 wide or high).
  rect(r.x + d, r.y + d, max(0, r.w - 2*d), max(0, r.h - 2*d))

# ---- Recording --------------------------------------------------------------

var
  layerStack: seq[tuple[layer: int, clip: Rect]]
  screenRect: Rect

proc beginDraw*(w, h: int; clear: Color) =
  ## Start a frame of `w` x `h` logical pixels.
  for l in layers.mitems: l.setLen(0)
  arena.setLen(0)
  imgArena.setLen(0)
  pathArena.setLen(0)
  frameBitmaps.setLen(0)
  clipStack.setLen(0)
  layerStack.setLen(0)
  curLayer = 0
  curClip = rect(0, 0, w, h)
  screenRect = curClip
  clearColor = pack(clear)
  frameHash = 0xcbf29ce484222325'u64
  mix(frameHash, clearColor)
  mix(frameHash, uint64(cast[uint32](textEm)) or (uint64(ord(uiFontSel)) shl 32))
  mixRect(frameHash, curClip)

proc setLayer*(n: int) = curLayer = clamp(n, 0, MaxLayers - 1)
  ## Draw on layer `n` from now on (clip kept; see `pushLayer`).

proc pushLayer*(n: int) =
  ## Draw on layer `n` (a popup, a dialog) until `popLayer`, unclipped by
  ## the widgets around: a drop-down may reach out of a panel.
  layerStack.add (curLayer, curClip)
  curLayer = clamp(n, 0, MaxLayers - 1)
  curClip = screenRect

proc popLayer*() =
  ## Back to the layer (and clip) before the matching `pushLayer`.
  if layerStack.len > 0:
    let t = layerStack.pop()
    curLayer = t.layer
    curClip = t.clip
  else:
    curLayer = 0
proc screenClip*(): Rect = screenRect
  ## What a pushed layer starts clipped to: the whole screen, or the box of
  ## a window drawn inside another (`windowBox`).
proc setScreenClip*(r: Rect) = screenRect = r
  ## The rectangle pushed layers are clipped to from now on (`screenClip`).
proc layer*(): int = curLayer
  ## The layer drawing goes to now.
proc clipRect*(): Rect = curClip
  ## The rectangle drawing is clipped to now.

proc pushClip*(r: Rect) =
  ## Clip drawing to `r` as well (inside the current clip) until `popClip`.
  clipStack.add curClip
  curClip = intersect(curClip, r)

proc resetClip*() =
  ## Back to the whole screen, forgetting every `pushClip`.
  clipStack.setLen(0)
  curClip = screenRect

proc popClip*() =
  ## Back to the clip before the matching `pushClip`.
  if clipStack.len > 0: curClip = clipStack.pop()

type DrawMark* = object
  ## Where the clip and layer stacks were (`drawMark`): what `drawRestore`
  ## goes back to when drawing stopped half way (a fault in a panel).
  clips, layers: int
  clip: Rect
  layer: int

proc drawMark*(): DrawMark =
  ## Where drawing is now (clips, layer): `drawRestore` goes back to it.
  DrawMark(clips: clipStack.len, layers: layerStack.len, clip: curClip, layer: curLayer)

proc drawRestore*(m: DrawMark) =
  ## The clips and layers pushed since `m` let go.
  if clipStack.len > m.clips: clipStack.setLen(m.clips)
  if layerStack.len > m.layers: layerStack.setLen(m.layers)
  curClip = m.clip
  curLayer = m.layer

proc cmdHash(c: Cmd): uint64 =
  result = 0x6a09e667f3bcc909'u64
  mix(result, uint64(ord(c.kind)) or (uint64(c.color) shl 8) or
      (uint64(c.mag) shl 40) or (uint64(c.bold) shl 48) or
      (uint64(c.flags) shl 56) or (uint64(cast[uint32](c.size)) shl 32))
  mixRect(result, c.r)
  mixRect(result, c.clip)

var
  mirrorW* = 0
    ## > 0: the frame is drawn mirrored -- right to left, as an Arabic
    ## interface -- in a screen this wide (logical pixels); set by `core`.
  noMirror: seq[int]           # (the regions drawn as they are, moved over: how far)

proc beginNoMirror*(area: Rect) =
  ## What is drawn from here to `endNoMirror` keeps its left and right (a
  ## picture and what is drawn over it, a text being edited): only moved to
  ## where `area` is in the mirrored frame.
  noMirror.add (if mirrorW > 0: mirrorW - 2 * area.x - area.w else: 0)

proc endNoMirror*() =
  ## Ends `beginNoMirror`.
  if noMirror.len > 0: noMirror.setLen(noMirror.len - 1)

proc mirrorRect(r: var Rect) {.inline.} =
  if noMirror.len > 0: r.x += noMirror[^1]
  else: r.x = mirrorW - r.x - r.w

proc mirrorCmd(c: var Cmd) =
  ## (a command drawn in the mirrored frame)
  case c.kind
  of ckLine:
    if noMirror.len > 0:
      c.r.x += noMirror[^1]
      c.r.w += noMirror[^1]           # (x2)
    else:
      c.r.x = mirrorW - 1 - c.r.x
      c.r.w = mirrorW - 1 - c.r.w
  of ckPath:
    let dx = if noMirror.len > 0: float32(noMirror[^1]) else: 0'f32
    var i = c.a.int
    while i < c.a.int + c.b.int and i < pathArena.len:
      let x = pathArena[i]
      if x == x:
        pathArena[i] = if noMirror.len > 0: x + dx else: float32(mirrorW) - x
      i += 2
    mirrorRect(c.r)
  of ckAnts:
    if noMirror.len > 0:
      c.r.x += noMirror[^1]
      if c.a.int < imgArena.len:
        imgArena[c.a.int] = cast[uint32](cast[int32](imgArena[c.a.int]) + int32(noMirror[^1] * max(1, pxScale)))
    else: mirrorRect(c.r)
  else: mirrorRect(c.r)
  if c.kind != ckFill and c.clip.w > 0: mirrorRect(c.clip)

proc add(c: Cmd) =
  var c = c
  if mirrorW > 0: mirrorCmd(c)
  c.h = cmdHash(c)
  mix(frameHash, c.h xor (uint64(curLayer) shl 61))
  layers[curLayer].add c

proc cmdMark*(): int =
  ## How many drawing commands the current layer has so far (to mark where
  ## a part of the frame starts and ends, see `reorderSpans`).
  layers[curLayer].len

proc reorderSpans*(spans: openArray[tuple[a, b: int]]; order: openArray[int]) =
  ## Overlapping windows: the commands of the current layer in `spans`
  ## (each `a ..< b`, in recording order, not overlapping) are drawn in
  ## `order` (indices into `spans`, the last on top), after whatever was
  ## drawn between them.
  if spans.len < 2 or order.len == 0: return
  let L = addr layers[curLayer]
  let a0 = spans[0].a
  let b1 = spans[^1].b
  if a0 < 0 or b1 > L[].len or a0 >= b1: return
  var inSpan = newSeq[bool](b1 - a0)
  for s in spans:
    if s.a < a0 or s.b > b1 or s.a > s.b: return
    for i in s.a ..< s.b: inSpan[i - a0] = true
  var outCmds = newSeqOfCap[Cmd](b1 - a0)
  for i in a0 ..< b1:
    if not inSpan[i - a0]: outCmds.add L[][i]
  for k in order:
    if k in 0 .. spans.high:
      for i in spans[k].a ..< spans[k].b: outCmds.add L[][i]
  if outCmds.len != b1 - a0: return               # (an order that drops or repeats)
  for i in 0 ..< outCmds.len: L[][a0 + i] = outCmds[i]

proc noteState*(v: uint64) =
  ## Mixes `v` into what tells this frame from the last (a change that is
  ## not in the drawing commands themselves, such as their order).
  mix(frameHash, v)

proc mixLast(v: uint64) {.inline.} =
  ## Content of the command just added (text, pixels) into its hash.
  mix(frameHash, v)
  mix(layers[curLayer][^1].h, v)

proc polygon*(pts: openArray[(float, float)]; c: Color)
  ## A filled polygon (any shape; where it crosses itself, it is filled).

proc fill*(r: Rect; c: Color) =
  ## A solid rectangle (see-through when the color's alpha is not 0 or
  ## 255: a selection's highlight over a picture).
  let rr = intersect(r, curClip)
  if rr.w > 0 and rr.h > 0:
    if c.a != 0 and c.a != 255:
      polygon([(rr.x.float, rr.y.float), ((rr.x + rr.w).float, rr.y.float),
               ((rr.x + rr.w).float, (rr.y + rr.h).float), (rr.x.float, (rr.y + rr.h).float)], c)
    else:
      add Cmd(kind: ckFill, color: pack(c), r: rr)

proc fill*(x, y, w, h: int; c: Color) {.inline.} = fill(rect(x, y, w, h), c)
  ## A solid rectangle at `x`, `y`, `w` x `h`.
proc hline*(x, y, w: int; c: Color) {.inline.} = fill(rect(x, y, w, 1), c)
  ## A horizontal line `w` pixels long.
proc vline*(x, y, h: int; c: Color) {.inline.} = fill(rect(x, y, 1, h), c)
  ## A vertical line `h` pixels long.

proc box*(r: Rect; c: Color; t = 1) =
  ## A rectangle outline `t` pixels thick, inside `r`.
  hline(r.x, r.y, r.w, c)
  hline(r.x, r.y + r.h - t, r.w, c)
  vline(r.x, r.y, r.h, c)
  vline(r.x + r.w - t, r.y, r.h, c)
  if t > 1: box(inset(r, 1), c, t - 1)

proc line*(x1, y1, x2, y2: int; c: Color) =
  ## A one-pixel line in any direction.
  let bb = rect(min(x1, x2), min(y1, y2), abs(x2 - x1) + 1, abs(y2 - y1) + 1)
  if intersect(bb, curClip).w > 0:
    add Cmd(kind: ckLine, color: pack(c), r: rect(x1, y1, x2, y2),
            clip: curClip)

proc dots*(r: Rect; c: Color) =
  ## The dotted focus rectangle.
  if intersect(r, curClip).w > 0:
    add Cmd(kind: ckDots, color: pack(c), r: r, clip: curClip)

proc checker*(r: Rect; c: Color) =
  ## Every other logical pixel of `r` in `c`, as a checkerboard (the 3.1
  ## dither of scroll bar tracks and pressed tool buttons).
  if r.w > 0 and r.h > 0 and intersect(r, curClip).w > 0:
    add Cmd(kind: ckDots, bold: true, color: pack(c), r: r, clip: curClip)

proc reserveFill*(): int =
  ## Reserve a fill whose rectangle is known only later (a popup's
  ## background, drawn before its items).
  result = layers[curLayer].len
  layers[curLayer].add Cmd(kind: ckFill)

proc patchFill*(i: int; r: Rect; c: Color) =
  ## Fills in the fill `i` from `reserveFill`: `r` in `c`.
  if i < 0 or i >= layers[curLayer].len: return
  var rr = intersect(r, curClip)
  if mirrorW > 0: mirrorRect(rr)
  layers[curLayer][i] = Cmd(kind: ckFill, color: pack(c), r: rr)
  layers[curLayer][i].h = cmdHash(layers[curLayer][i])
  mix(frameHash, layers[curLayer][i].h)

# ---- Text -------------------------------------------------------------------
#
# The UI's text is FreeSans (the default), FreeSerif or FreeMono -- GNU
# FreeFont, built in, each in its four styles -- or a font from a file;
# monospaced text is FreeMono, Arabic FreeSerif's where a face has none,
# icons the Nerd Fonts symbols. Glyphs are rendered at the screen's own
# resolution by the kit's TrueType engine (ttf.nim) -- gray, their heights
# on whole pixels at small sizes, their strokes as the font draws them (see
# `renderGlyph`; "Sharp" text in the screen's color strips is a choice) --
# and kept.

const
  deprecatedFont = "the kit's text fonts are GNU FreeFont now: FreeSans (ufSans), FreeSerif (ufSerif), " &
                   "FreeMono (ufMono)"
  ufW98* {.deprecated: deprecatedFont.} = ufSans          ## (MS W98 UI is gone: FreeSans)
  ufRetro* {.deprecated: deprecatedFont.} = ufSans        ## (Retro Sans is gone: FreeSans)
  ufSmooth* {.deprecated: deprecatedFont.} = ufSans       ## (DejaVu Sans is gone: FreeSans)
  ufOpenSans* {.deprecated: deprecatedFont.} = ufSans     ## (Open Sans is gone: FreeSans)
  ufKawkab* {.deprecated: deprecatedFont.} = ufMono       ## (Kawkab Mono is gone: FreeMono)
  ufFixedsys* {.deprecated: deprecatedFont.} = ufMono     ## (Fixedsys Excelsior is gone: FreeMono)

var hdTextOn = true
  ## pixel icons and small shapes at the screen's own resolution on HD
  ## screens (`setHdText`)
var fontGen = 0'u64
  ## (a new font from a file or of the system: its glyphs are not the
  ## glyphs kept for the face before, on the CPU or the GPU)

proc familyOf(f: UiFont): FaceId {.inline.} =
  case f
  of ufSans: fSans
  of ufSerif: fSerif
  of ufMono: fMono
  of ufFile: fUser

proc uiBase(): FaceId {.inline.} =
  ## The face of the UI's plain text.
  familyOf(uiFontSel)

proc lineK(): float32 = lineFactor(uiBase(), withGap = true) + 0.02
  ## (the UI's lines: the font's height with its line gap, as a font file's
  ## always were -- FreeSans 1.2 em -- and a little more)

proc setTextSize*(em: float) =
  ## The UI's text size in logical pixels per em (12 on desktops and
  ## tablets, 15 on phones: `core`'s `DesktopTextEm`, `TouchTextEm`).
  ## `FontH` and `FontAscent` follow.
  textEm = clamp(float32(em), 6, 96)
  let e = textEm
  FontH = max(8, int(round(e * lineK())))
  FontAscent = int(round((float32(FontH) - lineFactor(uiBase(), true) * e) / 2 +
                         ascentFactor(uiBase(), true) * e))
  forgetGlyphs()
  for i in 0 .. 255:
    textLut[i] = uint8(round(pow(i.float / 255, 1 / 1.2) * 255))

# (the bold of the UI and the icons unpacked on a thread meanwhile: the
# first frame finds them there)
unpackFacesSoon([styled(uiBase(), true, false), fIcons])
setTextSize(12)

proc textSize*(): float = textEm
  ## The UI's text size in logical pixels per em.

proc setUiFont*(f: UiFont) =
  ## The font of every app's text: `ufSans` (FreeSans, the default),
  ## `ufSerif` (FreeSerif), `ufMono` (FreeMono) -- GNU FreeFont, built in,
  ## with Arabic (FreeSerif's) -- or `ufFile` (a font file: `setUiFontFile`).
  ## Call it before `app` (or `startApp`) to choose an app's font, or at any
  ## time; `appearanceSettings` lets the user choose, `storeAppearance`
  ## keeps it. Monospaced text (code, hex) is FreeMono.
  if f == uiFontSel: return
  uiFontSel = f
  setTextSize(float(textEm))

proc uiFont*(): UiFont = uiFontSel
  ## The font of the UI's text (see `setUiFont`).

const builtinUiFonts*: seq[UiFont] = @[ufSans, ufSerif, ufMono]
  ## The fonts the kit carries, in the order a menu offers them (`$f` is a
  ## font's name; a font from a file, `ufFile`, is not among them).

proc setHdText*(on: bool) =
  ## Pixel icons and small shapes (check marks, arrows) on high-resolution
  ## screens and in large text: smoothed, at the screen's own resolution
  ## (`on`, the default), or each pixel of their art a block of whole
  ## screen pixels -- the look of a 1998 screen magnified.
  if on == hdTextOn: return
  hdTextOn = on
  setTextSize(float(textEm))

proc hdText*(): bool = hdTextOn
  ## See `setHdText`.

proc setUiFontFile*(regular: string; bold = ""; italic = ""; boldItalic = "") =
  ## A font of the user's as the UI's (TrueType bytes; `bold`, `italic`,
  ## `boldItalic`: its other styles, or "" to make them from the regular):
  ## `ufFile`. Raises `FontError` when it is not a font we read.
  setUserFont(regular, bold, italic, boldItalic)
  forgetGlyphs()
  inc fontGen
  uiFontSel = ufSans                     # (made to apply again)
  setUiFont(ufFile)

proc setPixelFont*(on: bool) {.deprecated: "the pixel fonts are gone: setUiFont(ufSans)".} =
  ## Old name: FreeSans either way.
  setUiFont(ufSans)

proc usesPixelFont*(): bool {.deprecated: "the pixel fonts are gone".} = false
  ## Always false: no pixel font is left.

proc style*(bold = false; italic = false; mono = false; size = 1.0;
            underline = false; strike = false; serif = false): TextStyle =
  ## A text style (`size` scales the UI font's size).
  TextStyle(bold: bold, italic: italic, mono: mono, size: size,
            underline: underline, strike: strike, serif: serif)

proc sizeOf(st: TextStyle): float32 {.inline.} =
  if st.size <= 0: 1 else: st.size

proc faceOf*(st: TextStyle): FaceId =
  ## The face text in style `st` is drawn in: the UI's font in its bold,
  ## italic or bold italic (the font's own -- FreeSans Oblique, not FreeSans
  ## slanted); FreeMono for `mono`, FreeSerif for `serif`.
  let fam = if st.mono: fMono
            elif st.serif: fSerif
            else: familyOf(uiFontSel)
  styled(fam, st.bold, st.italic)

proc emOf(st: TextStyle; f: FaceId): float32 {.inline.} =
  ## The size text in style `st` (face `f`) is drawn at, logical pixels per em.
  textEm * sizeOf(st)

proc flagsOf(st: TextStyle): uint8 =
  uint8(ord(st.bold)) or (uint8(ord(st.italic)) shl 1) or
    (uint8(ord(st.mono)) shl 2) or (uint8(ord(st.underline)) shl 3) or
    (uint8(ord(st.strike)) shl 4) or (uint8(ord(st.rtl)) shl 5) or (uint8(ord(st.serif)) shl 6)

proc styleOf(flags: uint8; size: float32): TextStyle =
  TextStyle(bold: (flags and 1) != 0, italic: (flags and 2) != 0,
            mono: (flags and 4) != 0, underline: (flags and 8) != 0,
            strike: (flags and 16) != 0, rtl: (flags and 32) != 0, serif: (flags and 64) != 0,
            size: size)

proc lineHeight*(st = TextStyle()): int =
  ## Height of a line of text in style `st`.
  let k = sizeOf(st)
  if k == 1: FontH
  else: max(4, int(round(emOf(st, uiBase()) * lineK())))

proc sysFontFor(): Font =
  let size = FontH * zoom
  if sysFontSize != size:
    if sysFontSize != 0: closeFont(sysFont)
    var fm = FontMetrics()
    sysFont = openFont("", size, fm)
    sysFontSize = size
  sysFont

# The platform's text as pictures (`renderText`): drawn into the frame in its
# place among the other drawing -- under a menu over it, on the GPU too --
# rather than by the system over the frame afterwards.

type SysRun = object
  w, h: int
  cover: seq[uint8]           ## how much of each pixel the letters cover

var
  runFont: Font               ## (the system font in device pixels, for `renderText`)
  runFontSize = 0
  sysRuns: Table[(string, int), SysRun]

proc sysRunsOn(): bool {.inline.} = fontRelays.renderText != nil
  ## The driver hands out text as pixels.

proc sysRunOf(s: string; make = true): ptr SysRun =
  ## `s` in the system font at this scale, as coverage (kept: the same text
  ## is drawn every frame); nil without `renderText`. Not `make`: only one
  ## made already (the rasterizing threads read; the driver is asked on the
  ## main thread, before them).
  if not sysRunsOn(): return nil
  let size = FontH * pxScale
  if not make:
    if runFontSize != size: return nil
    let key = (s, size)
    if key notin sysRuns: return nil
    return addr sysRuns[key]
  if runFontSize != size:
    if runFontSize != 0: closeFont(runFont)
    var fm = FontMetrics()
    runFont = openFont("", size, fm)
    runFontSize = size
    sysRuns.clear()
  let key = (s, size)
  if key notin sysRuns:
    if sysRuns.len >= 400: sysRuns.clear()
    var px: seq[uint32]
    # (in white: its alpha is the coverage, painted in any color after)
    let e = renderText(runFont, s, color(255, 255, 255), px)
    var r = SysRun(w: e.w, h: e.h)
    if e.w > 0 and e.h > 0 and px.len >= e.w * e.h:
      r.cover.setLen(e.w * e.h)
      for i in 0 ..< e.w * e.h: r.cover[i] = uint8(px[i] shr 24)
    else:
      r.w = 0
      r.h = 0
    sysRuns[key] = r
  addr sysRuns[key]

# ---- pixel icons in text ------------------------------------------------------
#
# Characters U+10F000 and up are pixel-art icons (see `pixelicons`): in any
# text -- a label, a tool button, a tab, a tree node -- they are drawn as
# color pictures, sharp at every scale (whole device pixels per art pixel),
# 16 x 16 art for small text and 32 x 32 art for big text.

const PixIconFirst* = 0x10F000
  ## The first character of the pixel icons.

var pixIcons: seq[tuple[small, big: Icon]]
var pixReady: seq[bool]          ## the icon is in `pixIcons` (else `pixSource` makes it)
var pixSource: proc (i: int): tuple[small, big: Icon] {.nimcall.}
var pixTwins: seq[tuple[glyph: string; color: uint32]]
var lineIconsOn = false
var lineInk = Color(r: 0, g: 0, b: 0, a: 255)

proc setPixelIcon*(i: int; small: sink Icon; big: sink Icon = Icon()) =
  ## Makes character `PixIconFirst + i` the icon `small` (16 x 16), with
  ## `big` (32 x 32) where text is large.
  if pixIcons.len <= i: pixIcons.setLen(i + 1)
  if pixReady.len <= i: pixReady.setLen(i + 1)
  pixIcons[i] = (small, big)
  pixReady[i] = true

proc setPixelIconSource*(count: int; load: proc (i: int): tuple[small, big: Icon] {.nimcall.}) =
  ## Pixel icons 0 ..< `count` made by `load` the first time they are drawn
  ## or measured: an app holds only the icons it shows (the toolkit's own
  ## set is made so). `setPixelIcon` still sets any of them at once.
  pixSource = load
  if pixIcons.len < count: pixIcons.setLen(count)
  if pixReady.len < pixIcons.len: pixReady.setLen(pixIcons.len)

proc loadPixIcon(idx: int) {.inline.} =
  ## (made on the UI thread -- measuring and preparing the frame come first
  ## -- so the threads that draw only read them)
  if idx < pixReady.len and not pixReady[idx] and pixSource != nil:
    pixIcons[idx] = pixSource(idx)
    pixReady[idx] = true

proc setPixelTwin*(i: int; glyph: string; color = 0'u32) =
  ## The line icon drawn for pixel icon `i` when `setLineIcons` is on: a
  ## glyph of the icon font (a Nerd Fonts symbol), in the text's color or
  ## its own (`color`, 0xRRGGBB; 0: the text's).
  if pixTwins.len <= i: pixTwins.setLen(i + 1)
  pixTwins[i] = (glyph, color)

proc setLineIcons*(on: bool; ink = Color(r: 0, g: 0, b: 0, a: 255)) =
  ## Pixel icons drawn as their line twins (`setPixelTwin`) -- crisp at any
  ## size, in the text's color (`ink` where no text color is given, the
  ## buttons' icons): what dark themes and OLED black use, where the pixel
  ## art's black outlines would not show.
  if on != lineIconsOn or ink != lineInk:
    lineIconsOn = on
    lineInk = ink

proc lineIcons*(): bool = lineIconsOn
  ## Whether pixel icons are drawn as line icons (see `setLineIcons`).

proc twinOf(idx: int): tuple[glyph: string; color: uint32] {.inline.} =
  if lineIconsOn and idx >= 0 and idx < pixTwins.len: pixTwins[idx] else: ("", 0'u32)

proc pixelIconChar*(i: int): string =
  ## The character of pixel icon `i` (UTF-8).
  $Rune(PixIconFirst + i)

proc hasPixIcons(s: string): bool {.inline.} =
  for i in 0 ..< s.len - 1:
    if s[i] == '\xF4' and s[i + 1] == '\x8F': return true

proc pixArt(idx, boxDev: int): tuple[big: bool; f, size: int] =
  ## Which art (16 or 32) and how many device pixels per art pixel, for a
  ## line `boxDev` device pixels high.
  if idx < 0 or idx >= pixIcons.len: return (false, 1, 16)
  loadPixIcon(idx)
  let bw = pixIcons[idx].big.w
  let sw = max(1, pixIcons[idx].small.w)
  # the detailed art when it is not much smaller than the room, else the
  # small art made bigger; always whole device pixels per art pixel
  let fb = if bw > 0: (boxDev + 4) div bw else: 0
  if fb >= 1: return (true, fb, bw * fb)
  let f = max(1, (boxDev + 4) div sw)
  (false, f, sw * f)

proc scale2x(px: openArray[uint32]; w, h: int): seq[uint32] =
  ## EPX / Scale2x: twice the size, the one-pixel steps of diagonals filled
  ## in (edges stay hard: no new colors).
  result = newSeq[uint32](w * h * 4)
  template at(x, y: int): uint32 = px[clamp(y, 0, h - 1) * w + clamp(x, 0, w - 1)]
  for y in 0 ..< h:
    for x in 0 ..< w:
      let p = at(x, y)
      let a = at(x, y - 1)
      let b = at(x + 1, y)
      let c = at(x - 1, y)
      let d = at(x, y + 1)
      let o = (2 * y) * (2 * w) + 2 * x
      result[o] = if c == a and c != d and a != b: a else: p
      result[o + 1] = if a == b and a != c and b != d: b else: p
      result[o + 2 * w] = if d == c and d != b and c != a: c else: p
      result[o + 2 * w + 1] = if b == d and b != a and d != c: d else: p

proc scale3x(px: openArray[uint32]; w, h: int): seq[uint32] =
  ## AdvMAME3x / Scale3x: three times the size, as Scale2x does it.
  result = newSeq[uint32](w * h * 9)
  template at(x, y: int): uint32 = px[clamp(y, 0, h - 1) * w + clamp(x, 0, w - 1)]
  let W3 = 3 * w
  for y in 0 ..< h:
    for x in 0 ..< w:
      let A = at(x - 1, y - 1)
      let B = at(x, y - 1)
      let C = at(x + 1, y - 1)
      let D = at(x - 1, y)
      let E = at(x, y)
      let F = at(x + 1, y)
      let G = at(x - 1, y + 1)
      let H = at(x, y + 1)
      let I = at(x + 1, y + 1)
      var e = [E, E, E, E, E, E, E, E, E]
      if B != H and D != F:
        e[0] = if D == B: D else: E
        e[1] = if (D == B and E != C) or (B == F and E != A): B else: E
        e[2] = if B == F: F else: E
        e[3] = if (D == B and E != G) or (D == H and E != A): D else: E
        e[5] = if (B == F and E != I) or (H == F and E != C): F else: E
        e[6] = if D == H: D else: E
        e[7] = if (D == H and E != I) or (H == F and E != G): H else: E
        e[8] = if H == F: F else: E
      let o = (3 * y) * W3 + 3 * x
      for k in 0 .. 8: result[o + (k div 3) * W3 + (k mod 3)] = e[k]

var hdArts: Table[uint64, Icon]

proc hdArt(ic: ptr Icon; idx: int; big: bool; f: int): tuple[ic: ptr Icon; f: int] =
  ## (HD) Pixel art magnified `f` times: by Scale2x, Scale3x or both as far
  ## as they go (smooth diagonals, hard edges), the rest by whole pixels.
  if not hdTextOn or f < 2 or ic.w <= 0 or ic.px.len < ic.w * ic.h: return (ic, f)
  let s = if f mod 4 == 0: 4 elif f mod 3 == 0: 3 else: 2
  if f mod s != 0: return (ic, f)
  let key = (uint64(idx) shl 8) or (uint64(ord(big)) shl 4) or uint64(s)
  if key notin hdArts:
    var px = ic.px
    var w = ic.w
    var h = ic.h
    if s == 3: px = scale3x(px, w, h)
    else:
      px = scale2x(px, w, h)
      if s == 4: px = scale2x(px, w * 2, h * 2)
    hdArts[key] = Icon(w: w * s, h: h * s, px: px)
  (addr hdArts[key], f div s)

proc pixIconAdvance(idx, lineH: int): int =
  let (_, _, size) = pixArt(idx, lineH * pxScale)
  (size + pxScale - 1) div pxScale + 1

iterator iconRuns(s: string): tuple[icon: int; a, b: int] =
  ## Pieces of `s`: a pixel icon (`icon` >= 0) or text `s[a ..< b]`.
  var i = 0
  var start = 0
  while i < s.len:
    if i + 3 < s.len and s[i] == '\xF4' and s[i + 1] == '\x8F':
      if i > start: yield (-1, start, i)
      let cp = ((ord(s[i]) and 0x07) shl 18) or ((ord(s[i + 1]) and 0x3F) shl 12) or
               ((ord(s[i + 2]) and 0x3F) shl 6) or (ord(s[i + 3]) and 0x3F)
      yield (cp - PixIconFirst, 0, 0)
      i += 4
      start = i
    else:
      inc i
  if start < s.len: yield (-1, start, s.len)

proc textWidth*(s: string; st: TextStyle): int
  ## Width of `s` in logical pixels.

proc iconTextWidth(s: string; st: TextStyle): int =
  let lh = lineHeight(st)
  for r in iconRuns(s):
    if r.icon >= 0: result += pixIconAdvance(r.icon, lh)
    else: result += textWidth(s[r.a ..< r.b], st)

proc textWidth*(s: string; st: TextStyle): int =
  ## Width of `s` in logical pixels.
  if s.len == 0: return 0
  if hasPixIcons(s): return iconTextWidth(s, st)
  let f = faceOf(st)
  if not plainAscii(s) and not hasGlyphs(s, f):
    return (measureText(sysFontFor(), s).w + zoom - 1) div zoom
  let em = widthEm(s, f, if st.rtl: 1 else: -1)
  int(ceil(em * emOf(st, f) - 0.01))

proc textWidth*(s: string; bold = false; mag = 1): int =
  ## Width of `s` in logical pixels.
  textWidth(s, TextStyle(bold: bold, size: float32(mag)))

proc text*(x, y: int; s: string; c: Color; st: TextStyle)
  ## Draw `s` in style `st`, the top-left corner of its line at `x`, `y`.

proc iconText(x, y: int; s: string; c: Color; st: TextStyle) =
  ## Text with pixel icons in it: the pieces one after the other. An icon
  ## in a gray color (disabled) is drawn embossed, as Windows did.
  let lh = lineHeight(st)
  let disabled = c.r == c.g and c.g == c.b and c.r in 96'u8 .. 176'u8
  var cx = x
  for r in iconRuns(s):
    if r.icon >= 0:
      let w = pixIconAdvance(r.icon, lh)
      let tw = twinOf(r.icon)
      if tw.glyph.len > 0:
        # (a line icon: the symbol in the text's color, as big as the line's
        # letters, in the pixel icon's room)
        let ist = TextStyle(size: st.size * 1.18, bold: false)
        let gw = textWidth(tw.glyph, ist)
        let col = if tw.color != 0 and not disabled: Color(r: uint8(tw.color shr 16), g: uint8(tw.color shr 8),
                                                           b: uint8(tw.color), a: 255)
                  else: c
        text(cx + (w - gw) div 2, y + (lh - lineHeight(ist)) div 2, tw.glyph, col, ist)
      elif intersect(rect(cx, y - 2, w, lh + 4), curClip).w > 0 and
         r.icon < pixIcons.len:
        add Cmd(kind: ckPixIcon, r: rect(cx, y, w - 1, lh), clip: curClip,
                a: r.icon.int32, flags: uint8(ord(disabled)))
        mixLast(uint64(r.icon) * 0x9E3779B97F4A7C15'u64 + uint64(ord(disabled)))
      cx += w
    else:
      let seg = s[r.a ..< r.b]
      text(cx, y, seg, c, st)
      cx += textWidth(seg, st)

proc text*(x, y: int; s: string; c: Color; st: TextStyle) =
  ## Draw `s` in style `st`, the top-left corner of its line at `x`, `y`.
  if s.len == 0: return
  if hasPixIcons(s):
    iconText(x, y, s, c, st)
    return
  let h = lineHeight(st)
  # (a line above or below the clip draws nothing: not measured, not kept --
  # the rows of a long page out of view)
  if y >= curClip.y + curClip.h or y + h <= curClip.y: return
  let w = textWidth(s, st)
  if intersect(rect(x, y, w, h), curClip).w == 0: return
  let a = arena.len
  arena.add s
  let kind = if plainAscii(s) or hasGlyphs(s, faceOf(st)): ckVText else: ckSysText
  add Cmd(kind: kind, color: pack(c), bold: st.bold, flags: flagsOf(st),
          size: sizeOf(st), r: rect(x, y, w, h), clip: curClip,
          a: a.int32, b: s.len.int32)
  var th = 0xcbf29ce484222325'u64
  for ch in s: th = (th xor ord(ch).uint64) * 0x100000001B3'u64
  mixLast(th)

proc text*(x, y: int; s: string; c: Color; bold = false; mag = 1) =
  ## Draw `s` with its top-left corner at `x`, `y` (transparent background).
  text(x, y, s, c, TextStyle(bold: bold, size: float32(mag)))

# ---- Shapes -----------------------------------------------------------------
#
# Filled outlines in logical coordinates (fractions allowed), anti-aliased
# at the screen's full resolution: circles stay round at any size.

proc beginPath(): int =
  result = pathArena.len

proc endPath(a: int; c: Color) =
  let n = pathArena.len - a
  if n < 6:
    pathArena.setLen(a)
    return
  var x0, y0 = 1e9'f32
  var x1, y1 = -1e9'f32
  # (the points hashed in the same pass, when `add` does not move them: a
  # mirrored frame's are hashed after)
  let fused = mirrorW <= 0
  var ph = 0x84222325'u64
  let hi = pathArena.high
  var i = a
  while i < pathArena.len:
    let x = pathArena[i]
    if x == x:                       # not the NaN that ends a contour
      x0 = min(x0, x); x1 = max(x1, x)
      y0 = min(y0, pathArena[i+1]); y1 = max(y1, pathArena[i+1])
    if fused:
      ph = (ph xor (uint64(cast[uint32](x)) xor
            (uint64(cast[uint32](pathArena[min(i + 1, hi)])) shl 32))) * 0x100000001B3'u64
    i += 2
  let bb = rect(int(floor(x0)), int(floor(y0)), int(ceil(x1)) - int(floor(x0)) + 1,
                int(ceil(y1)) - int(floor(y0)) + 1)
  if intersect(bb, curClip).w == 0:
    pathArena.setLen(a)
    return
  # (a color's alpha, when it is not 0 or 255: the shape see-through)
  let al = if c.a == 0 or c.a == 255: 0'u32 else: uint32(c.a)
  add Cmd(kind: ckPath, color: pack(c) or (al shl 24), r: bb, clip: curClip, a: a.int32,
          b: n.int32)
  if not fused:
    ph = 0x84222325'u64
    for k in countup(a, pathArena.high, 2):
      ph = (ph xor (uint64(cast[uint32](pathArena[k])) xor
            (uint64(cast[uint32](pathArena[min(k + 1, pathArena.high)])) shl 32))) *
           0x100000001B3'u64
  mixLast(ph)

proc pt(x, y: float) {.inline.} =
  pathArena.add float32(x)
  pathArena.add float32(y)

proc closeContour() {.inline.} =
  pathArena.add NaN
  pathArena.add NaN

proc polygon*(pts: openArray[(float, float)]; c: Color) =
  ## A filled polygon (any shape; where it crosses itself, it is filled).
  let a = beginPath()
  # (the arena made long enough once, the points written in)
  pathArena.setLen(a + 2 * pts.len + 2)
  for i in 0 ..< pts.len:
    pathArena[a + 2 * i] = float32(pts[i][0])
    pathArena[a + 2 * i + 1] = float32(pts[i][1])
  pathArena[a + 2 * pts.len] = NaN
  pathArena[a + 2 * pts.len + 1] = NaN
  endPath(a, c)

proc fillContours*(contours: openArray[seq[(float, float)]]; c: Color; ox = 0.0; oy = 0.0;
                   k = 1.0) =
  ## Filled outlines as one shape -- where they overlap, filled once (turned
  ## the same way they join; the other way, one cuts a hole in another) --
  ## each point (x, y) drawn at (x * `k` + `ox`, y * `k` + `oy`): a drawing
  ## kept in its own units, panned and zoomed.
  let a = beginPath()
  for cn in contours:
    if cn.len < 3: continue
    for (x, y) in cn: pt(x * k + ox, y * k + oy)
    closeContour()
  endPath(a, c)

var unitCircle: array[2, array[161, seq[(float, float)]]]
  ## the cosines and sines of a circle's `n` steps (one way round and the
  ## other), worked out once: discs are drawn in great numbers (a chart's
  ## points) every frame

proc circlePoints(cx, cy, r: float; reverse = false) =
  let n = clamp(int(r * float(pxScale) * 0.9) + 8, 8, 160)
  let rv = ord(reverse)
  if unitCircle[rv][n].len != n:
    var steps = newSeq[(float, float)](n)
    for i in 0 ..< n:
      let t = (if reverse: -1.0 else: 1.0) * 2 * PI * float(i) / float(n)
      steps[i] = (cos(t), sin(t))
    unitCircle[rv][n] = steps
  let o = pathArena.len
  pathArena.setLen(o + 2 * n + 2)
  let steps = addr unitCircle[rv][n]
  for i in 0 ..< n:
    pathArena[o + 2 * i] = float32(cx + r * steps[i][0])
    pathArena[o + 2 * i + 1] = float32(cy + r * steps[i][1])
  pathArena[o + 2 * n] = NaN
  pathArena[o + 2 * n + 1] = NaN

proc disc*(cx, cy, r: float; c: Color) =
  ## A filled circle centered at `cx`, `cy`.
  if r <= 0: return
  let a = beginPath()
  circlePoints(cx, cy, r)
  endPath(a, c)

proc ring*(cx, cy, r, width: float; c: Color) =
  ## A circle's outline, `width` thick, inside radius `r`.
  if r <= 0 or width <= 0: return
  let a = beginPath()
  circlePoints(cx, cy, r)
  if width < r: circlePoints(cx, cy, r - width, reverse = true)
  endPath(a, c)

proc thickLine*(x1, y1, x2, y2, width: float; c: Color) =
  ## A line `width` thick between two points (square ends).
  let dx = x2 - x1
  let dy = y2 - y1
  let l = sqrt(dx * dx + dy * dy)
  if l == 0: return
  let nx = -dy / l * width / 2
  let ny = dx / l * width / 2
  polygon([(x1 + nx, y1 + ny), (x2 + nx, y2 + ny), (x2 - nx, y2 - ny),
           (x1 - nx, y1 - ny)], c)

proc roundRect*(r: Rect; radius: float; c: Color) =
  ## A filled rectangle with rounded corners.
  let rad = min(radius, min(r.w, r.h) / 2)
  if rad <= 0.5:
    fill(r, c)
    return
  let a = beginPath()
  let n = clamp(int(rad * float(pxScale) * 0.5) + 3, 3, 40)
  let corners = [(float(r.x + r.w) - rad, float(r.y) + rad, -PI / 2),
                 (float(r.x + r.w) - rad, float(r.y + r.h) - rad, 0.0),
                 (float(r.x) + rad, float(r.y + r.h) - rad, PI / 2),
                 (float(r.x) + rad, float(r.y) + rad, PI)]
  for (cx, cy, a0) in corners:
    for i in 0 .. n:
      let t = a0 + PI / 2 * float(i) / float(n)
      pt(cx + rad * cos(t), cy + rad * sin(t))
  closeContour()
  endPath(a, c)

proc pieSlice*(cx, cy, r, a0, a1: float; c: Color) =
  ## A slice of a disc from angle `a0` to `a1` (radians, clockwise from
  ## the right, as the screen's y grows down).
  if r <= 0 or a1 <= a0: return
  let a = beginPath()
  pt(cx, cy)
  let n = clamp(int((a1 - a0) * r * float(pxScale) * 0.15) + 2, 2, 200)
  for i in 0 .. n:
    let t = a0 + (a1 - a0) * float(i) / float(n)
    pt(cx + r * cos(t), cy + r * sin(t))
  closeContour()
  endPath(a, c)

# ---- Images -----------------------------------------------------------------

proc glyphIcon*(glyph: string; tint: Color; size = 16): Icon =
  ## An icon drawn from the icon font: `glyphIcon(nfFolder, yellow)`.
  ## `size` is the box in logical pixels.
  Icon(w: size, h: size, glyph: glyph, tint: tint)

proc isPixelIcon*(glyph: string): bool {.inline.} =
  ## `glyph` is one of the pixel icons (see `pixelicons`).
  glyph.len == 4 and glyph[0] == '\xF4' and glyph[1] == '\x8F'

proc pixelIconAt*(r: Rect; glyph: string; disabled = false) =
  ## Draws the pixel icon `glyph` as big as fits in `r` (whole device
  ## pixels per art pixel), centered.
  if not isPixelIcon(glyph) or intersect(r, curClip).w == 0: return
  let idx = int(glyph.runeAt(0)) - PixIconFirst
  if idx < 0 or idx >= pixIcons.len: return
  let tw = twinOf(idx)
  if tw.glyph.len > 0:
    # (its line twin, filling the box, in the ink -- or its own color)
    let h = min(r.w, r.h)
    let st = TextStyle(size: float32(h) / textEm)
    let col = if disabled: Color(r: 128, g: 128, b: 128, a: 255)
              elif tw.color != 0: Color(r: uint8(tw.color shr 16), g: uint8(tw.color shr 8), b: uint8(tw.color),
                                        a: 255)
              else: lineInk
    text(r.x + (r.w - textWidth(tw.glyph, st)) div 2, r.y + (r.h - lineHeight(st)) div 2, tw.glyph, col, st)
    return
  add Cmd(kind: ckPixIcon, r: r, clip: curClip, a: idx.int32, flags: uint8(ord(disabled)))
  mixLast(uint64(idx) * 0x9E3779B97F4A7C15'u64 + uint64(ord(disabled)) +
          uint64(r.w) shl 20 + uint64(r.h) shl 40)

proc image*(x, y: int; ic: Icon; mag = 1) =
  ## Draw an icon at `x`, `y`, `mag` times as large.
  if isPixelIcon(ic.glyph):
    pixelIconAt(rect(x, y, ic.w * max(1, mag), ic.h * max(1, mag)), ic.glyph)
    return
  if ic.glyph.len > 0:
    let h = ic.h * max(1, mag)
    let st = TextStyle(size: float32(h) / textEm)
    let tw = textWidth(ic.glyph, st)
    # (a symbol asked for in black: in the ink with line icons -- a dark theme)
    let tint = if lineIconsOn and ic.tint.r == 0 and ic.tint.g == 0 and ic.tint.b == 0: lineInk else: ic.tint
    text(x + (ic.w * max(1, mag) - tw) div 2, y + (h - lineHeight(st)) div 2,
         ic.glyph, tint, st)
    return
  if ic.w <= 0 or ic.h <= 0 or ic.px.len < ic.w * ic.h: return
  let m = max(1, mag)
  let r = rect(x, y, ic.w * m, ic.h * m)
  if intersect(r, curClip).w == 0: return
  let a = imgArena.len
  imgArena.add ic.px
  add Cmd(kind: ckImage, r: r, clip: curClip, a: a.int32, b: ic.w.int32,
          mag: m.int32)
  var ih = 0x84222325'u64
  for p in ic.px: ih = (ih xor p.uint64) * 0x100000001B3'u64
  mixLast(ih)

proc newBitmap*(w, h: int; fill = 0'u32): Bitmap =
  ## A `w` x `h` bitmap with every pixel `fill` (ARGB; 0 is transparent).
  let stamp = uint64(atomicInc(bitmapStamps))
  result = Bitmap(w: max(0, w), h: max(0, h), stamp: stamp, whole: stamp)
  result.px = newSeq[uint32](result.w * result.h)
  if fill != 0:
    for p in result.px.mitems: p = fill
  result.opaque = (fill shr 24) == 255


# ---- more kinds of picture file ---------------------------------------------------------------

type PictureReader* = proc (path: string; maxW, maxH: int): Bitmap {.nimcall, gcsafe.}
  ## Reads the picture of a kind of file the toolkit does not know (a
  ## program's own documents: layered images, drawings), no larger than
  ## `maxW` x `maxH` -- or a smaller picture it holds; nil when it cannot.
  ## It runs on worker threads.

var pictureReaders: seq[tuple[ext: string; read: PictureReader]]

proc addPictureReader*(exts: openArray[string]; read: PictureReader) =
  ## Teaches `loadPicture` -- and so the file lists' pictures, the
  ## previews, Open dialogs -- to show files ending in `exts` (".psd"),
  ## read with `read`. Call it at the start, before pictures are asked for.
  for e in exts: pictureReaders.add (e.toLowerAscii, read)

proc pictureReaderFor*(path: string): PictureReader =
  ## The reader added for `path`'s kind (by its extension); nil: none.
  {.cast(gcsafe).}:
    let dot = path.rfind('.')
    if dot < 0 or pictureReaders.len == 0: return nil
    let e = path[dot .. ^1].toLowerAscii
    for (x, r) in pictureReaders:
      if x == e: return r

type PageReader* = proc (path: string; page, maxW, maxH: int): Bitmap {.nimcall, gcsafe.}
  ## Draws page `page` (from 0) of a document of many pages (a PDF), no
  ## larger than `maxW` x `maxH`; nil when it cannot.

var pageReaders: seq[tuple[ext: string; read: PageReader]]

proc addPageReader*(exts: openArray[string]; read: PageReader) =
  ## Teaches `pageAsync` to draw the pages of files ending in `exts`.
  for e in exts: pageReaders.add (e.toLowerAscii, read)

proc pageReaderFor*(path: string): PageReader =
  ## The page reader added for `path`'s kind; nil: none.
  {.cast(gcsafe).}:
    let dot = path.rfind('.')
    if dot < 0 or pageReaders.len == 0: return nil
    let e = path[dot .. ^1].toLowerAscii
    for (x, r) in pageReaders:
      if x == e: return r

proc changed*(b: Bitmap) =
  ## Tell the screen that `b.px` changed.
  b.stamp = uint64(atomicInc(bitmapStamps))
  b.whole = b.stamp
  b.dirty = rect(0, 0, 0, 0)

proc changed*(b: Bitmap; r: Rect) =
  ## Tell the screen that `r` (bitmap pixels) of `b.px` changed: only the
  ## part of the screen it is drawn on is drawn and sent again.
  let c = intersect(r, rect(0, 0, b.w, b.h))
  if c.w <= 0 or c.h <= 0: return
  b.stamp = uint64(atomicInc(bitmapStamps))
  b.dirty = union(b.dirty, c)

proc drawBitmap*(r: Rect; b: Bitmap) =
  ## Draw `b` stretched into `r`; the pixels are sampled at the screen's
  ## full resolution, so a photo stays sharp at any zoom.
  if b == nil or b.w <= 0 or b.h <= 0 or b.px.len < b.w * b.h or r.w <= 0 or
     r.h <= 0 or intersect(r, curClip).w == 0: return
  if b.stamp == 0: changed(b)
  frameBitmaps.add b
  add Cmd(kind: ckBitmap, r: r, clip: curClip, a: int32(frameBitmaps.high))
  # (the command is the same while only parts change: those parts are
  # drawn again, see `present`)
  mixLast(b.whole xor (cast[uint64](b) shl 1))
  mix(frameHash, b.stamp)

proc devBoxOf(d: Rect): Rect =
  ## The logical pixels device rectangle `d` touches.
  let s = max(1, pxScale)
  let x0 = floorDiv(d.x, s)
  let y0 = floorDiv(d.y, s)
  rect(x0, y0, floorDiv(d.x + d.w + s - 1, s) - x0, floorDiv(d.y + d.h + s - 1, s) - y0)

proc drawGpuImage*(key: uint64; dev: Rect; ver: int; smooth = false) =
  ## A picture sent with `gpuImage` drawn at `dev` (device pixels, any
  ## size: the GPU scales it, smoothly when `smooth`); `ver` changes with
  ## what it shows. Nothing when the CPU draws.
  let box = devBoxOf(dev)
  if dev.w <= 0 or dev.h <= 0 or intersect(box, curClip).w == 0: return
  let a = imgArena.len
  imgArena.add uint32(key and 0xFFFFFFFF'u64)
  imgArena.add uint32(key shr 32)
  for v in [dev.x, dev.y, dev.w, dev.h]: imgArena.add cast[uint32](int32(v))
  add Cmd(kind: ckTex, r: box, clip: curClip, a: a.int32, b: 6, flags: uint8(ord(smooth)))
  mixLast(key xor (uint64(ver) shl 20) xor uint64(dev.x) xor (uint64(dev.y) shl 16) xor
          (uint64(dev.w) shl 32) xor (uint64(dev.h) shl 48))

proc checkerAt*(dev: Rect; cell, ox, oy: int; c0, c1: Color) =
  ## A checkerboard over device rectangle `dev`: squares of `cell` device
  ## pixels from (`ox`, `oy`), `c0` on the even ones (what is under a
  ## see-through picture).
  let box = devBoxOf(dev)
  if dev.w <= 0 or dev.h <= 0 or intersect(box, curClip).w == 0: return
  let a = imgArena.len
  for v in [dev.x, dev.y, dev.x + dev.w, dev.y + dev.h, ox, oy]: imgArena.add cast[uint32](int32(v))
  imgArena.add pack(c0)
  imgArena.add pack(c1)
  add Cmd(kind: ckChecker, r: box, clip: curClip, a: a.int32, b: 8, mag: int32(max(1, cell)))
  mixLast(uint64(pack(c0)) xor (uint64(pack(c1)) shl 24) xor uint64(ox) shl 48 xor uint64(oy) shl 8 xor
          uint64(dev.x) xor uint64(dev.w) shl 16 xor uint64(dev.y) shl 32 xor uint64(dev.h) shl 40)

proc marchingAnts*(area: Rect; segs: openArray[array[4, int32]]; phase: int) =
  ## A selection's outline over a picture drawn in `area`: `segs` are
  ## horizontal and vertical runs (x0, y0, x1, y1; device pixels from the
  ## area's corner, x1/y1 past the end), dotted black and white, moving
  ## with `phase`. Only the parts of the screen they cross are drawn again
  ## as they march.
  let cl = intersect(area, curClip)
  if cl.w <= 0 or cl.h <= 0 or segs.len == 0: return
  # (the runs in pieces no taller than a band and no wider than a tile, so
  # each piece only touches the screen where it is)
  const PieceH = 32
  const PieceW = 256
  let ox = area.x * pxScale
  let oy = area.y * pxScale
  var pieces: Table[int64, seq[int32]]
  template put(x0, y0, x1, y1: int) =
    let key = (int64((oy + y0) div PieceH) shl 32) or int64((ox + x0) div PieceW)
    pieces.mgetOrPut(key, @[]).add [int32(x0), int32(y0), int32(x1), int32(y1)]
  for s in segs:
    if s[1] == s[3] - 1 or s[1] == s[3]:            # horizontal
      var x = int(s[0])
      let xe = int(s[2])
      while x < xe:
        let nx = min(xe, ((ox + x) div PieceW + 1) * PieceW - ox)
        put(x, int(s[1]), nx, int(s[1]) + 1)
        x = nx
    else:                                            # vertical
      var y = int(s[1])
      let ye = int(s[3])
      while y < ye:
        let ny = min(ye, ((oy + y) div PieceH + 1) * PieceH - oy)
        put(int(s[0]), y, int(s[0]) + 1, ny)
        y = ny
  for key, list in pieces:
    var bx0, by0 = high(int)
    var bx1, by1 = low(int)
    for i in countup(0, list.high, 4):
      bx0 = min(bx0, int(list[i])); by0 = min(by0, int(list[i + 1]))
      bx1 = max(bx1, int(list[i + 2])); by1 = max(by1, int(list[i + 3]))
    # (the box in logical pixels, a pixel larger than the device run)
    let s = max(1, pxScale)
    let box = rect(area.x + bx0 div s, area.y + by0 div s, (bx1 - bx0 + s - 1) div s + 1,
                   (by1 - by0 + s - 1) div s + 1)
    let a = imgArena.len
    imgArena.add cast[uint32](int32(ox))           # (the area's corner, device pixels)
    imgArena.add cast[uint32](int32(oy))
    for v in list: imgArena.add cast[uint32](v)
    add Cmd(kind: ckAnts, r: box, clip: cl, a: a.int32, b: int32(list.len), mag: int32(phase and 7))
    var h = 0xcbf29ce484222325'u64
    for v in list: h = (h xor uint64(cast[uint32](v))) * 0x100000001B3'u64
    mixLast(h xor uint64(phase and 7))

# ---- Rasterizing ------------------------------------------------------------
#
# Every index below is clipped to the framebuffer first, so the hot loops
# run without per-pixel bounds checks.

{.push boundChecks: off, overflowChecks: off.}

var bandClip {.threadvar.}: Rect
  ## the part of the framebuffer being drawn now (each thread its own)

proc devClip(r: Rect): Rect {.inline.} =
  intersect(rect(r.x * pxScale, r.y * pxScale, r.w * pxScale, r.h * pxScale),
            bandClip)

template fbPtr(): ptr UncheckedArray[uint32] =
  ## The framebuffer's pixels (a local pointer: loops over it vectorize,
  ## where the global would be loaded again for every pixel).
  fbMem

template blend(q, c: uint32; a: uint32): uint32 =
  ## `c` over `q` with alpha `a` (0..255), red and blue in one multiply,
  ## green in another; rounded like v div 255.
  let na = 255'u32 - a
  var rb = (c and 0xFF00FF'u32) * a + (q and 0xFF00FF'u32) * na + 0x800080'u32
  rb = ((rb + ((rb shr 8) and 0xFF00FF'u32)) shr 8) and 0xFF00FF'u32
  var gg = (c and 0xFF00'u32) * a + (q and 0xFF00'u32) * na + 0x8000'u32
  gg = ((gg + ((gg shr 8) and 0xFF00'u32)) shr 8) and 0xFF00'u32
  rb or gg

proc rfill(x, y, w, h: int; c: uint32; clip: Rect) {.inline.} =
  let x0 = max(x, clip.x)
  let y0 = max(y, clip.y)
  let x1 = min(x + w, clip.x + clip.w)
  let y1 = min(y + h, clip.y + clip.h)
  if x0 >= x1 or y0 >= y1: return
  let p = fbPtr()
  let stride = fbW
  for yy in y0 ..< y1:
    let row = yy * stride
    for xx in x0 ..< x1: p[row + xx] = c

type
  PrepGlyph = object
    x, y: int32          ## where the glyph's mask goes (device pixels)
    slot: int32          ## its mask: >= 0 in the cache, < 0 in `frameMasks`

var
  inParallel: bool       ## tiles being drawn on worker threads
  prepGlyphs: seq[PrepGlyph]
  prepSpans: seq[tuple[a, n, base: int32; emDev: float32]]
    ## a prepared text command's glyphs, by its `mag` - 1
  frameMasks: seq[Mask]  ## glyphs this frame needs that the cache had no room for
  slotFrame: array[MaskSlots, uint32]
  frameNo = 1'u32

proc rasterSysRun(c: Cmd; run: SysRun) =
  ## The platform's text (`sysRunOf`) blended into the frame, in its color.
  if run.w <= 0 or run.h <= 0: return
  let d = devClip(c.clip)
  let x0 = c.r.x * pxScale
  let y0 = c.r.y * pxScale + max(0, (c.r.h * pxScale - run.h) div 2)
  let r = intersect(rect(x0, y0, run.w, run.h), d)
  if r.w <= 0 or r.h <= 0: return
  let p = fbPtr()
  let cr = (c.color shr 16) and 255
  let cg = (c.color shr 8) and 255
  let cb = c.color and 255
  for y in r.y ..< r.y + r.h:
    let src = (y - y0) * run.w - x0
    let row = y * fbW
    for x in r.x ..< r.x + r.w:
      let a = uint32(run.cover[src + x])
      if a == 0: continue
      let o = p[row + x]
      if a == 255:
        p[row + x] = 0xFF000000'u32 or (cr shl 16) or (cg shl 8) or cb
        continue
      let ia = 255 - a
      let rr = (cr * a + ((o shr 16) and 255) * ia + 127) div 255
      let gg = (cg * a + ((o shr 8) and 255) * ia + 127) div 255
      let bb = (cb * a + (o and 255) * ia + 127) div 255
      p[row + x] = 0xFF000000'u32 or (rr shl 16) or (gg shl 8) or bb

proc lutFor(col: uint32; small: bool): ptr array[256, uint8] {.inline.} =
  ## Small text's coverage table (nil: as it is).
  if small: addr textLut else: nil

proc blendLcd(m: Mask; x0, y0: int; col: uint32; clip: Rect; lut: ptr array[256, uint8]) =
  ## A glyph in the screen's color strips (`m.lcd`): each of a pixel's red,
  ## green and blue mixed by its own coverage.
  let xa = max(x0, clip.x)
  let ya = max(y0, clip.y)
  let xb = min(x0 + m.w, clip.x + clip.w)
  let yb = min(y0 + m.h, clip.y + clip.h)
  if xa >= xb or ya >= yb: return
  if m.a.len < 3 * m.w * m.h or m.a.len == 0: return
  let fp = fbPtr()
  let mp = cast[ptr UncheckedArray[uint8]](unsafeAddr m.a[0])
  let cr = (col shr 16) and 255
  let cg = (col shr 8) and 255
  let cb = col and 255
  for y in ya ..< yb:
    let src = (y - y0) * m.w - x0
    let row = y * fbW
    for x in xa ..< xb:
      let i = 3 * (src + x)
      var ar = uint32(mp[i])
      var ag = uint32(mp[i + 1])
      var ab = uint32(mp[i + 2])
      if (ar or ag or ab) == 0: continue
      if lut != nil:
        ar = uint32(lut[ar]); ag = uint32(lut[ag]); ab = uint32(lut[ab])
      let o = fp[row + x]
      let rr = (cr * ar + ((o shr 16) and 255) * (255 - ar) + 127) div 255
      let gg = (cg * ag + ((o shr 8) and 255) * (255 - ag) + 127) div 255
      let bb = (cb * ab + (o and 255) * (255 - ab) + 127) div 255
      fp[row + x] = 0xFF000000'u32 or (rr shl 16) or (gg shl 8) or bb

proc blendMask(m: Mask; x0, y0: int; col: uint32; clip: Rect; lut: ptr array[256, uint8] = nil) =
  let xa = max(x0, clip.x)
  let ya = max(y0, clip.y)
  let xb = min(x0 + m.w, clip.x + clip.w)
  let yb = min(y0 + m.h, clip.y + clip.h)
  if xa >= xb or ya >= yb: return
  if m.a.len < m.w * m.h or m.a.len == 0: return
  let fp = fbPtr()
  let mp = cast[ptr UncheckedArray[uint8]](unsafeAddr m.a[0])
  for y in ya ..< yb:
    let src = (y - y0) * m.w - x0
    let row = y * fbW
    for x in xa ..< xb:
      var a = uint32(mp[src + x])
      if a == 0: continue
      if lut != nil: a = uint32(lut[a])
      if a >= 255: fp[row + x] = col
      else: fp[row + x] = blend(fp[row + x], col, a)

const LcdFilter = [0, 85, 86, 85, 0]
  ## (FreeType's light filter, near ClearType's: a strip's coverage shared
  ## with its neighbours, so that the letters do not show colored edges;
  ## they add up to 256)

proc lcdMask(m: Mask; bgr: bool): Mask =
  ## A glyph drawn three times as wide (a column per color strip) as a mask
  ## of red, green and blue coverage per pixel.
  if m.w <= 0 or m.h <= 0: return Mask(lcd: true)
  let s0 = m.left - 2                 # (the filter reaches two strips out)
  let s1 = m.left + m.w + 2
  let p0 = floorDiv(s0, 3)
  let p1 = -floorDiv(-s1, 3)
  let w = p1 - p0
  result = Mask(w: w, h: m.h, left: p0, top: m.top, lcd: true)
  result.a = newSeq[uint8](3 * w * m.h)
  for y in 0 ..< m.h:
    let srow = y * m.w
    let drow = y * w * 3
    for i in 0 ..< 3 * w:
      let sx = 3 * p0 + i - m.left
      var acc = 0
      for k in 0 .. 4:
        let j = sx + k - 2
        if j >= 0 and j < m.w: acc += LcdFilter[k] * int(m.a[srow + j])
      if acc == 0: continue
      let ch = i mod 3
      result.a[drow + 3 * (i div 3) + (if bgr: 2 - ch else: ch)] = uint8(min(255, (acc + 128) shr 8))

proc renderGlyph*(f: FaceId; gid: int; size: float32; dx = 0'f32; lcd = false): Mask =
  ## Glyph `gid` of face `f` at `size` device pixels per em, `dx` of a pixel
  ## to the right, as the screen draws it: its heights (baseline, x-height,
  ## caps) on whole pixels at small sizes, its strokes as the font has them
  ## (FreeMono's, thin, darkened there); a style the font lacks made
  ## bold or slanted from its regular. `lcd`: in the screen's color strips
  ## (`Mask.lcd`), its stems fitted to the pixels.
  let fx = fauxStyle(f)
  let fc = face(f)
  if lcd:
    return lcdMask(fc.render(gid, size, dx * 3, if fx.italic: 0.2 else: 0,
                             embolden = (if fx.bold: size * FauxBoldEm else: 0),
                             fitStems = true, bold = isBold(f), darken = fc.darkening(size),
                             xScale = 3), lcdBgr)
  # (gray: the heights on the pixels, the strokes as the font has them --
  # a stem a little over a pixel shows so, darker than one fitted to a pixel;
  # only FreeMono's thin strokes darkened)
  fc.render(gid, size, dx, if fx.italic: 0.2 else: 0,
            embolden = (if fx.bold: size * FauxBoldEm else: 0),
            bold = isBold(f), darken = (if regularOf(f) == fMono: fc.darkening(size) else: 0))

proc setSubpixelText*(on: bool) =
  ## Text drawn in the screen's color strips (red, green, blue: three times
  ## as sharp across, as Windows' ClearType draws: "Sharp" in
  ## `appearanceSettings`) or smooth in gray ("Smooth", the default on every
  ## platform; `$RETRO_TEXT` "sharp" turns it on at the start). Used only on
  ## screens of one device pixel per pixel (`pxScale` 1).
  if on == subpixelSel: return
  subpixelSel = on
  forgetGlyphs()
  inc fontGen

proc subpixelText*(): bool = subpixelSel
  ## See `setSubpixelText`.

proc systemSubpixelText*(): bool = false
  ## The default of `setSubpixelText`: off (gray text, everywhere).

proc subpixelNow*(): bool {.inline.} = subpixelSel and pxScale == 1
  ## Text drawn in the color strips at this moment (asked for, and the
  ## screen's pixels are not small).

proc prepMask(f: FaceId; gid: uint16; size: float32; phase: int): int32 =
  ## The rendered glyph, from a direct-mapped cache (one array look-up):
  ## its slot, or (when another glyph of this frame holds the slot) a copy
  ## of its own in `frameMasks` (-1, -2...). Not on worker threads.
  let sq = uint64(round(size * 4))
  let lcd = subpixelNow() and size <= 64
  let key = (uint64(gid) or (uint64(ord(f)) shl 16) or (uint64(phase) shl 24) or
             (uint64(ord(lcd)) shl 26) or
             (sq shl 27) or ((fontGen and 0x3FF) shl 50)) + 1
  let slot = int(((key * 0x9E3779B97F4A7C15'u64) shr 51) and (MaskSlots - 1))
  if maskKeys[slot] == key:
    slotFrame[slot] = frameNo
    return int32(slot)
  let m = renderGlyph(f, int(gid), size, float32(phase) / 4, lcd)
  if slotFrame[slot] == frameNo:
    frameMasks.add m
    return -int32(frameMasks.len)
  maskKeys[slot] = key
  maskSlots[slot] = m
  slotFrame[slot] = frameNo
  int32(slot)

template maskAt(i: int32): ptr Mask =
  (if i >= 0: addr maskSlots[i] else: addr frameMasks[-i - 1])

proc prepVText(c: var Cmd) =
  ## Where each glyph of vector text `c` goes and its mask, worked out on
  ## the main thread (shaping and the glyph cache are not shared); the
  ## drawing itself may then run on any thread.
  let st = styleOf(c.flags, c.size)
  let f = faceOf(st)
  let emDev = emOf(st, f) * float32(pxScale)
  let lineDev = float32(lineHeight(st) * pxScale)
  # (every style of a line on one baseline: the UI font's)
  let mf = uiBase()
  let base = c.r.y * pxScale + int(round((lineDev - lineFactor(mf, true) * emDev) / 2 +
                                         ascentFactor(mf, true) * emDev))
  let x0 = float32(c.r.x * pxScale)
  let a = prepGlyphs.len
  template one(g: PGlyph) =
    let gx = x0 + g.x * emDev
    var ix = int(floor(gx))
    var ph = int(round((gx - float32(ix)) * 4))
    if ph == 4:
      inc ix
      ph = 0
    let k = prepMask(g.face, g.gid, emDev, ph)
    let m = maskAt(k)
    if m.w > 0:
      let my = base - int(round(g.y * emDev)) + m.top
      prepGlyphs.add PrepGlyph(x: int32(ix + m.left), y: int32(my), slot: k)
  if not st.rtl and plainAscii(arena.toOpenArray(c.a, c.a + c.b - 1)):
    for g in asciiGlyphs(arena.toOpenArray(c.a, c.a + c.b - 1), f): one(g)
  else:
    # (the cached run read where it is: nothing in `one` shapes text)
    let run = shapeCached(arena[c.a ..< c.a + c.b], f, if st.rtl: 1 else: -1)
    for i in 0 ..< run.glyphs.len: one(run.glyphs[i])
  prepSpans.add (int32(a), int32(prepGlyphs.len - a), int32(base), emDev)
  c.mag = int32(prepSpans.len)

proc blitVText(c: Cmd) =
  ## Vector text `c`, prepared (`prepVText`), drawn.
  let clip = devClip(c.clip)
  if clip.w <= 0 or clip.h <= 0 or c.mag <= 0: return
  let sp = prepSpans[c.mag - 1]
  let lut = lutFor(c.color, sp.emDev < 20)
  let st = styleOf(c.flags, c.size)
  for i in sp.a ..< sp.a + sp.n:
    let g = prepGlyphs[i]
    let m = maskAt(g.slot)
    if m.lcd: blendLcd(m[], int(g.x), int(g.y), c.color, clip, lut)
    else: blendMask(m[], int(g.x), int(g.y), c.color, clip, lut)
  if st.underline or st.strike:
    let emDev = sp.emDev
    let base = int(sp.base)
    let t = max(1, int(round(emDev / 14)))
    let w = c.r.w * pxScale
    if st.underline:
      rfill(c.r.x * pxScale, base + max(1, int(round(emDev * 0.09))), w, t,
            c.color, clip)
    if st.strike:
      rfill(c.r.x * pxScale, base - int(round(emDev * 0.3)), w, t, c.color, clip)

proc rasterVText(c: Cmd) =
  if c.mag > 0: blitVText(c)
  elif inParallel: discard           # (not made ready: not in what is drawn)
  else:
    var cc = c
    prepVText(cc)
    blitVText(cc)

proc pathMaskInto(c: Cmd; clip: Rect; r: var Raster; m: var Mask) =
  ## Path command `c`'s coverage in device rectangle `clip` (its left edge
  ## a pixel left of `clip`'s), the color's alpha in it: into `m`, drawn
  ## with `r` (both keep their memory for the next shape).
  let s = float32(pxScale)
  let w = clip.w + 2
  r.reset(w, clip.h)
  let ox = float32(clip.x - 1)
  let oy = float32(clip.y)
  var i = c.a.int
  let e = c.a.int + c.b.int
  var fx, fy, px, py: float32
  var started = false
  while i + 1 < e:
    let x = pathArena[i]
    if x != x:
      if started: r.edge(px, py, fx, fy)
      started = false
    else:
      let dx = x * s - ox
      let dy = pathArena[i+1] * s - oy
      if started: r.edge(px, py, dx, dy)     # (cut at the sides: what is past them, on them)
      else:
        fx = dx
        fy = dy
        started = true
      px = dx
      py = dy
    i += 2
  if started: r.edge(px, py, fx, fy)
  m.w = w
  m.h = clip.h
  m.left = 0
  m.top = 0
  r.coverageInto(m.a)
  let al = c.color shr 24
  if al != 0:
    # see-through: the coverage times the alpha
    for v in m.a.mitems: v = uint8(uint32(v) * al div 255)

proc pathMask(c: Cmd; clip: Rect): Mask =
  ## Path command `c`'s coverage in device rectangle `clip` (`pathMaskInto`).
  var r: Raster
  pathMaskInto(c, clip, r, result)

var
  pathRaster {.threadvar.}: Raster
  pathCover {.threadvar.}: Mask
    ## (each drawing thread's, for one shape after another: a chart's
    ## thousands are not each given memory of their own)

proc rasterPath(c: Cmd) =
  let clip = intersect(devClip(c.clip), devClip(c.r))
  if clip.w <= 0 or clip.h <= 0: return
  if (clip.w + 2) * clip.h > 1 shl 18:
    # (a big one -- an overlay's -- not kept)
    let m = pathMask(c, clip)
    blendMask(m, clip.x - 1, clip.y, c.color and 0xFFFFFF'u32, clip)
    return
  pathMaskInto(c, clip, pathRaster, pathCover)
  blendMask(pathCover, clip.x - 1, clip.y, c.color and 0xFFFFFF'u32, clip)

proc rasterDots(c: Cmd) =
  let clip = devClip(c.clip)
  let r = c.r
  let s = pxScale
  if c.bold:                               # `checker`: the whole rectangle
    let cr = intersect(r, rect(clip.x div max(1, s), clip.y div max(1, s),
                               clip.w div max(1, s) + 2, clip.h div max(1, s) + 2))
    for y in cr.y ..< cr.y + cr.h:
      var x = cr.x + ((cr.x + y) and 1)
      while x < cr.x + cr.w:
        rfill(x * s, y * s, s, s, c.color, clip)
        x += 2
    return
  for i in 0 ..< r.w:
    if ((r.x + i + r.y) and 1) == 0:
      rfill((r.x + i) * s, r.y * s, s, s, c.color, clip)
    if ((r.x + i + r.y + r.h - 1) and 1) == 0:
      rfill((r.x + i) * s, (r.y + r.h - 1) * s, s, s, c.color, clip)
  for j in 1 ..< r.h - 1:
    if ((r.x + r.y + j) and 1) == 0:
      rfill(r.x * s, (r.y + j) * s, s, s, c.color, clip)
    if ((r.x + r.w - 1 + r.y + j) and 1) == 0:
      rfill((r.x + r.w - 1) * s, (r.y + j) * s, s, s, c.color, clip)

proc rasterLine(c: Cmd) =
  ## Bresenham, one logical pixel (a `pxScale` square) per step.
  let clip = devClip(c.clip)
  let s = pxScale
  var x = c.r.x
  var y = c.r.y
  let x2 = c.r.w
  let y2 = c.r.h
  let dx = abs(x2 - x)
  let dy = -abs(y2 - y)
  let sx = if x < x2: 1 else: -1
  let sy = if y < y2: 1 else: -1
  var err = dx + dy
  while true:
    rfill(x * s, y * s, s, s, c.color, clip)
    if x == x2 and y == y2: break
    let e2 = 2 * err
    if e2 >= dy:
      err += dy
      x += sx
    if e2 <= dx:
      err += dx
      y += sy

proc rasterImage(c: Cmd) =
  let clip = devClip(c.clip)
  let m = max(1, c.mag.int)
  let s = pxScale * m
  let w = c.b.int
  for j in 0 ..< c.r.h div m:
    for i in 0 ..< w:
      let p = imgArena[c.a.int + j * w + i]
      if (p shr 24) != 0:
        rfill(c.r.x * pxScale + i * s, c.r.y * pxScale + j * s, s, s,
              p and 0xFFFFFF'u32, clip)

proc prepPixIcon(c: Cmd) =
  ## (before the tiles are drawn on several threads: the magnified art of
  ## the icon made and kept, so the threads only read the cache)
  if c.a < 0 or c.a.int >= pixIcons.len: return
  let boxW = c.r.w * pxScale
  let boxH = c.r.h * pxScale
  let (big, f0, _) = pixArt(c.a.int, if c.r.w > c.r.h * 2: boxH else: min(boxW + 2 * pxScale, boxH))
  let ic0 = if big: addr pixIcons[c.a].big else: addr pixIcons[c.a].small
  if ic0.w <= 0 or ic0.px.len < ic0.w * ic0.h: return
  discard hdArt(ic0, c.a.int, big, f0)

proc rasterPixIcon(c: Cmd) =
  let clip = devClip(c.clip)
  if clip.w <= 0 or clip.h <= 0 or c.a < 0 or c.a.int >= pixIcons.len: return
  let boxW = c.r.w * pxScale
  let boxH = c.r.h * pxScale
  let (big, f0, size) = pixArt(c.a.int, if c.r.w > c.r.h * 2: boxH else: min(boxW + 2 * pxScale, boxH))
  let ic0 = if big: addr pixIcons[c.a].big else: addr pixIcons[c.a].small
  if ic0.w <= 0 or ic0.px.len < ic0.w * ic0.h: return
  let ox = c.r.x * pxScale + (boxW - size) div 2
  let oy = c.r.y * pxScale + (boxH - size) div 2
  let d0 = max(1, f0 div 2)
  let (ic, f) = hdArt(ic0, c.a.int, big, f0)
  if c.flags != 0:
    # disabled: the dark pixels embossed (white, then gray one pixel up-left)
    for pass in 0 .. 1:
      let d = if pass == 0: d0 else: 0
      let col = if pass == 0: 0xFFFFFF'u32 else: 0x808080'u32
      for j in 0 ..< ic.h:
        for i in 0 ..< ic.w:
          let p = ic.px[j * ic.w + i]
          if (p shr 24) == 0: continue
          let luma = ((p shr 16) and 0xFF) * 3 + ((p shr 8) and 0xFF) * 6 + (p and 0xFF)
          if luma < 1300:
            rfill(ox + i * f + d, oy + j * f + d, f, f, col, clip)
    return
  for j in 0 ..< ic.h:
    var i = 0
    while i < ic.w:
      let p = ic.px[j * ic.w + i]
      if (p shr 24) == 0:
        inc i
        continue
      # a run of the same color in one fill
      var e = i + 1
      while e < ic.w and ic.px[j * ic.w + e] == p: inc e
      rfill(ox + i * f, oy + j * f, (e - i) * f, f, p and 0xFFFFFF'u32, clip)
      i = e

var bitmapCols {.threadvar.}: seq[int32]

proc rasterBitmap(c: Cmd) =
  let bmp = unsafeAddr frameBitmaps[c.a]      # (no reference counted: any thread)
  template b: untyped = bmp[]
  let s = pxScale
  let dx = c.r.x * s
  let dy = c.r.y * s
  let dw = c.r.w * s
  let dh = c.r.h * s
  let cl = intersect(devClip(c.clip), rect(dx, dy, dw, dh))
  if cl.w <= 0 or cl.h <= 0 or b.px.len < b.w * b.h or b.w <= 0 or b.h <= 0: return
  let fp0 = fbPtr()
  if dw == b.w and dh == b.h and b.opaque:
    # one bitmap pixel to one screen pixel: rows copied
    for y in cl.y ..< cl.y + cl.h:
      copyMem(addr fp0[y * fbW + cl.x], unsafeAddr b.px[(y - dy) * b.w + (cl.x - dx)], cl.w * 4)
    return
  # the source column of each screen column, worked out once (in the
  # drawing thread's own table)
  bitmapCols.setLen(cl.w)
  template xs: untyped = bitmapCols
  for i in 0 ..< cl.w: xs[i] = int32((cl.x + i - dx) * b.w div dw)
  let fp = fbPtr()
  let bp = cast[ptr UncheckedArray[uint32]](unsafeAddr b.px[0])
  for y in cl.y ..< cl.y + cl.h:
    let src = ((y - dy) * b.h div dh) * b.w
    let row = y * fbW + cl.x
    for i in 0 ..< cl.w:
      let p = bp[src + int(xs[i])]
      let a = p shr 24
      if a == 255: fp[row + i] = p and 0xFFFFFF'u32
      elif a != 0: fp[row + i] = blend(fp[row + i], p, a)

proc rasterAnts(c: Cmd) =
  ## Dotted runs: black and white in fours, along x + y, moved by the phase.
  let clip = devClip(c.clip)
  if clip.w <= 0 or clip.h <= 0: return
  let ox = int(cast[int32](imgArena[c.a]))
  let oy = int(cast[int32](imgArena[c.a + 1]))
  let ph = int(c.mag)
  let fp = fbPtr()
  var i = c.a.int + 2
  let e = c.a.int + 2 + c.b.int
  while i + 3 < e:
    let x0 = int(cast[int32](imgArena[i]))
    let y0 = int(cast[int32](imgArena[i + 1]))
    let x1 = int(cast[int32](imgArena[i + 2]))
    let y1 = int(cast[int32](imgArena[i + 3]))
    for y in max(y0, clip.y - oy) ..< min(y1, clip.y + clip.h - oy):
      let row = (oy + y) * fbW + ox
      for x in max(x0, clip.x - ox) ..< min(x1, clip.x + clip.w - ox):
        fp[row + x] = if ((x + y + ph) and 7) < 4: 0'u32 else: 0xFFFFFF'u32
    i += 4

proc rasterChecker(c: Cmd) =
  let clip = intersect(devClip(c.clip), rect(int(cast[int32](imgArena[c.a])), int(cast[int32](imgArena[c.a + 1])),
    int(cast[int32](imgArena[c.a + 2])) - int(cast[int32](imgArena[c.a])),
    int(cast[int32](imgArena[c.a + 3])) - int(cast[int32](imgArena[c.a + 1]))))
  if clip.w <= 0 or clip.h <= 0: return
  let ox = int(cast[int32](imgArena[c.a + 4]))
  let oy = int(cast[int32](imgArena[c.a + 5]))
  let cell = max(1, c.mag.int)
  let c0 = imgArena[c.a + 6]
  let c1 = imgArena[c.a + 7]
  let fp = fbPtr()
  for y in clip.y ..< clip.y + clip.h:
    let ry = floorDiv(y - oy, cell)
    let row = y * fbW
    for x in clip.x ..< clip.x + clip.w:
      fp[row + x] = if ((floorDiv(x - ox, cell) + ry) and 1) == 0: c0 else: c1

proc drawOneSysText(c: Cmd; d: Rect) =
  let u = unitPx
  let bgp = fbMem[clamp((c.r.y * pxScale) * fbW + c.r.x * pxScale, 0, fbW * fbH - 1)]
  let bg = color(uint8(bgp shr 16), uint8(bgp shr 8), uint8(bgp))
  let fg = color(uint8(c.color shr 16), uint8(c.color shr 8), uint8(c.color))
  saveState()
  setClipRect(rect(d.x div u, d.y div u, d.w div u, d.h div u))
  discard drawText(sysFontFor(), c.r.x * zoom, c.r.y * zoom,
                   arena[c.a ..< c.a + c.b], fg, bg)
  restoreState()

proc drawSysTexts(runs: seq[Rect]) =
  ## Texts the platform draws (scripts the built-in fonts lack), over the
  ## parts just sent.
  for l in 0 ..< MaxLayers:
    for c in layers[l]:
      if c.kind != ckSysText: continue
      for r in runs:
        bandClip = r
        let d = devClip(c.clip)
        bandClip = rect(0, 0, fbW, fbH)
        if d.w > 0 and d.h > 0: drawOneSysText(c, d)

proc fallbackBlit(y0, y1: int) =
  ## For a surface that takes no pixels: the changed rows as runs of fills.
  for y in y0 ..< y1:
    var x = 0
    while x < fbW:
      let p = fbMem[y * fbW + x]
      var e = x + 1
      while e < fbW and fbMem[y * fbW + e] == p: inc e
      fillRect(rect(x, y, e - x, 1),
               color(uint8(p shr 16), uint8(p shr 8), uint8(p)))
      x = e

const BandH = 32
  ## The framebuffer is cut in tiles of `TileW` x `BandH` device pixels:
  ## only the tiles whose drawing commands changed are drawn again and sent
  ## to the screen.
const retroTileW {.intdefine.} = 64
const TileW = retroTileW
  ## (64: a lit button, a caret, a value that changed is drawn and sent as a
  ## few small tiles; `-d:retroTileW=128` or 256 for wider ones, to measure)

const ParallelMinPx = 96 * 1024
  ## Device pixels to draw again before the tiles are shared out among the
  ## cores: under it (a caret, a button lit up, a few rows) they are drawn
  ## on this thread -- waking the others costs more than drawing them.

var
  tileHash, shownTiles, tileSalt: seq[uint64]
  tilesX, tilesY: int
  scratch: seq[uint32]            ## a part of the framebuffer, rows together, for sending
  frameRuns: seq[Rect]            ## (the frame's tiles to draw, in runs: kept, as the rest
  bandItems: seq[Rect]            ## below, from frame to frame -- a frame takes no memory)
  bandSys: seq[bool]
  cmdDev: array[MaxLayers, seq[Rect]]
    ## each command's device box on the screen, worked out once a frame
    ## (`tileRuns`) for all that looks where commands are

proc cmdBox(c: Cmd): Rect =
  ## The logical rectangle command `c` can touch.
  case c.kind
  of ckFill: c.r
  of ckPixIcon:
    intersect(rect(c.r.x - 2, c.r.y - c.r.h div 2, c.r.w + 4, c.r.h * 2), c.clip)
  of ckVText, ckSysText:
    let m = c.r.h div 2 + 2
    intersect(rect(c.r.x - m, c.r.y - m, c.r.w + 2 * m, c.r.h + 2 * m), c.clip)
  of ckLine:
    intersect(rect(min(c.r.x, c.r.w), min(c.r.y, c.r.h), abs(c.r.w - c.r.x) + 1,
                   abs(c.r.h - c.r.y) + 1), c.clip)
  else: intersect(c.r, c.clip)

proc rasterCmd(c: Cmd): bool =
  ## One command drawn in `bandClip`; true for a system-font text (drawn
  ## by the system later).
  case c.kind
  of ckFill:
    rfill(c.r.x * pxScale, c.r.y * pxScale, c.r.w * pxScale,
          c.r.h * pxScale, c.color, bandClip)
  of ckVText: rasterVText(c)
  of ckPath: rasterPath(c)
  of ckDots: rasterDots(c)
  of ckImage: rasterImage(c)
  of ckPixIcon: rasterPixIcon(c)
  of ckBitmap: rasterBitmap(c)
  of ckLine: rasterLine(c)
  of ckAnts: rasterAnts(c)
  of ckChecker: rasterChecker(c)
  of ckTex: discard              # (the GPU's own pictures)
  of ckSysText:
    let run = sysRunOf(arena[c.a ..< c.a + c.b], make = false)
    if run == nil: return true     # (drawn by the system, over the frame)
    rasterSysRun(c, run[])

var
  bandCmds: seq[seq[uint32]]
    ## per row of tiles, the commands that reach into it (layer shl 28 or
    ## index), in the order they are drawn: a band looks only at its own
  bandWanted: seq[bool]           ## (the rows of tiles drawn this frame)

proc drawRegion(d: Rect; band: int): bool =
  ## Rasterizes the device rectangle `d` (in row of tiles `band`); true if
  ## a system-font text is there.
  bandClip = d
  let p = fbPtr()
  let cc = clearColor
  for y in d.y ..< d.y + d.h:
    let row = y * fbW
    for x in d.x ..< d.x + d.w: p[row + x] = cc
  for k in bandCmds[band]:
    let l = int(k shr 28)
    let i = int(k and 0xFFFFFFF'u32)
    let b = cmdDev[l][i]
    if b.y + b.h <= d.y or b.y >= d.y + d.h or b.x + b.w <= d.x or b.x >= d.x + d.w:
      continue
    if rasterCmd(layers[l][i]): result = true
  bandClip = rect(0, 0, fbW, fbH)

proc send(d: Rect) =
  ## The framebuffer's rectangle `d` (device pixels) to the screen, widened
  ## to whole driver units.
  let u = unitPx
  let x0 = (d.x div u) * u
  let y0 = (d.y div u) * u
  let x1 = min(fbW, ((d.x + d.w + u - 1) div u) * u)
  let y1 = min(fbH, ((d.y + d.h + u - 1) div u) * u)
  if x1 <= x0 or y1 <= y0: return
  let w = x1 - x0
  let h = y1 - y0
  if fbSurface:
    # (the window's own pixels: only told where they changed)
    surfaceRelays.presentSurface(rect(x0, y0, w, h))
    return
  var p: ptr UncheckedArray[uint32]
  if x0 == 0 and w == fbW:
    p = cast[ptr UncheckedArray[uint32]](addr fbMem[y0 * fbW])
  else:
    if scratch.len < w * h: scratch.setLen(w * h)
    for y in 0 ..< h:
      copyMem(addr scratch[y * w], addr fbMem[(y0 + y) * fbW + x0], w * 4)
    p = cast[ptr UncheckedArray[uint32]](addr scratch[0])
  let dst = rect(x0 div u, y0 div u, w div u, h div u)
  let ok = if u == 1: blitRGBA(p, w, h, dst) else: drawRGBA(p, w, h, dst)
  if not ok: fallbackBlit(y0, y1)

proc forgetShown(dr: Rect) =
  ## The tiles under `dr` (device pixels) drawn again by the next frame.
  if tilesX == 0 or dr.w <= 0 or dr.h <= 0: return
  for ty in max(0, dr.y div BandH) .. min(tilesY - 1, (dr.y + dr.h - 1) div BandH):
    for tx in max(0, dr.x div TileW) .. min(tilesX - 1, (dr.x + dr.w - 1) div TileW):
      shownTiles[ty * tilesX + tx] = 0

proc devBox(c: Cmd): Rect {.inline.} =
  let b = cmdBox(c)
  rect(b.x * pxScale, b.y * pxScale, b.w * pxScale, b.h * pxScale)

template eachTile(d: Rect; t: untyped; body: untyped) =
  ## The tiles device rectangle `d` touches.
  if d.w > 0 and d.h > 0:
    let tx0 = max(0, d.x div TileW)
    let tx1 = min(tilesX - 1, (d.x + d.w - 1) div TileW)
    for ty in max(0, d.y div BandH) .. min(tilesY - 1, (d.y + d.h - 1) div BandH):
      for tx in tx0 .. tx1:
        let t = ty * tilesX + tx
        body

proc tileRuns(force: var bool; result: var seq[Rect]) =
  ## The tiles whose drawing changed since the screen got them (all of them
  ## when `force`, or when the grid is made anew for another size: then
  ## `force` is set), in runs along each row of tiles, whole rows together,
  ## into `result`. Their hashes are left in `tileHash`, for `shownTiles`
  ## once shown. (The CPU draws only these tiles; the GPU, where it keeps
  ## the frame, too.)
  result.setLen(0)
  bandClip = rect(0, 0, fbW, fbH)
  let nx = (fbW + TileW - 1) div TileW
  let ny = (fbH + BandH - 1) div BandH
  if nx != tilesX or ny != tilesY:
    tilesX = nx
    tilesY = ny
    shownTiles = newSeq[uint64](nx * ny)
    tileSalt = newSeq[uint64](nx * ny)
    force = true
  let n = nx * ny
  # pictures that changed in part: only the tiles under that part differ
  # (kept in the tiles' salt, so the next frame does not draw them again)
  for l in 0 ..< MaxLayers:
    for c in layers[l]:
      if c.kind != ckBitmap: continue
      let b = frameBitmaps[c.a]
      if b.dirty.w <= 0 or b.stamp == b.whole: continue
      let s = pxScale
      let dx = c.r.x * s
      let dy = c.r.y * s
      let dw = c.r.w * s
      let dh = c.r.h * s
      let x0 = dx + b.dirty.x * dw div b.w - 1
      let x1 = dx + ((b.dirty.x + b.dirty.w) * dw + b.w - 1) div b.w + 1
      let y0 = dy + b.dirty.y * dh div b.h - 1
      let y1 = dy + ((b.dirty.y + b.dirty.h) * dh + b.h - 1) div b.h + 1
      let d = intersect(intersect(rect(x0, y0, x1 - x0, y1 - y0), devBox(c)), bandClip)
      eachTile(d, t):
        mix(tileSalt[t], b.stamp)
  tileHash.setLen(n)
  for t in 0 ..< n: tileHash[t] = (clearColor.uint64 * 31 + t.uint64) xor tileSalt[t]
  for l in 0 ..< MaxLayers:
    cmdDev[l].setLen(layers[l].len)
    for i in 0 ..< layers[l].len:
      let d = intersect(devBox(layers[l][i]), bandClip)
      cmdDev[l][i] = d
      let hh = layers[l][i].h xor (uint64(l) shl 61)
      eachTile(d, t):
        mix(tileHash[t], hh)
  # the tiles to draw, in runs along each row of tiles; whole rows together
  for ty in 0 ..< ny:
    var tx = 0
    while tx < nx:
      let t = ty * nx + tx
      if force or tileHash[t] != shownTiles[t]:
        var e = tx
        while e < nx and (force or tileHash[ty * nx + e] != shownTiles[ty * nx + e]): inc e
        let r = rect(tx * TileW, ty * BandH, min(fbW, e * TileW) - tx * TileW,
                     min(fbH, (ty + 1) * BandH) - ty * BandH)
        if result.len > 0 and r.x == 0 and r.w == fbW and result[^1].x == 0 and
           result[^1].w == fbW and result[^1].y + result[^1].h == r.y:
          result[^1].h += r.h
        else:
          result.add r
        tx = e
      else: inc tx

include gfxgpu

proc overlayNow*(r: Rect; body: proc ()) =
  ## What `body` draws, put at once over what is on the screen (in `r`,
  ## logical pixels) and shown -- in the middle of a frame, which is kept
  ## as it was: a box shown while the program works between frames. The
  ## next frame draws those rows again.
  if (fbMem == nil and not gpuOn) or fbW <= 0 or fbH <= 0: return
  var saved: array[MaxLayers, seq[Cmd]]
  for l in 0 ..< MaxLayers:
    saved[l] = move(layers[l])
    layers[l] = @[]
  let aLen = arena.len
  let iLen = imgArena.len
  let pLen = pathArena.len
  let bLen = frameBitmaps.len
  let sLayer = curLayer
  let sClip = curClip
  let sClips = clipStack
  let sLayers = layerStack
  let sHash = frameHash
  let sScreen = screenRect
  curLayer = 0
  screenRect = rect(0, 0, fbW div max(1, pxScale), fbH div max(1, pxScale))
  curClip = intersect(r, screenRect)
  clipStack.setLen(0)
  layerStack.setLen(0)
  try:
    body()
    let dr = intersect(rect(r.x * pxScale, r.y * pxScale, r.w * pxScale, r.h * pxScale),
                       rect(0, 0, fbW, fbH))
    if gpuOn:
      gpuOverlay(dr)
      shownHash = 0
    elif dr.w > 0 and dr.h > 0:
      bandClip = dr
      for c in layers[0]: discard rasterCmd(c)
      bandClip = rect(0, 0, fbW, fbH)
      send(dr)
      refresh()
      forgetShown(dr)
      shownHash = 0
  finally:
    for l in 0 ..< MaxLayers: layers[l] = move(saved[l])
    arena.setLen(aLen)
    imgArena.setLen(iLen)
    pathArena.setLen(pLen)
    frameBitmaps.setLen(bLen)
    curLayer = sLayer
    curClip = sClip
    clipStack = sClips
    layerStack = sLayers
    frameHash = sHash
    screenRect = sScreen

var drawingExtra = false
  ## (a window besides the program's own is drawn: no surface, no GPU)

type
  FrameState* = object
    ## Everything a frame's drawing keeps -- its commands, clips, layers --
    ## and its window's pixels and tiles: a window besides the program's own
    ## has one of its own, swapped in while it is drawn (`swapFrameState`).
    layers: array[MaxLayers, seq[Cmd]]
    arena: string
    imgArena: seq[uint32]
    pathArena: seq[float32]
    frameBitmaps: seq[Bitmap]
    clipStack: seq[Rect]
    layerStack: seq[tuple[layer: int, clip: Rect]]
    curLayer: int
    curClip, screenRect: Rect
    clearColor: uint32
    frameHash, shownHash: uint64
    mirrorW: int
    noMirror: seq[int]
    fb: seq[uint32]
    fbMem: ptr UncheckedArray[uint32]
    fbSurface: bool
    fbW, fbH: int
    tileHash, shownTiles, tileSalt: seq[uint64]
    tilesX, tilesY: int
    extra*: bool              ## another window's (no surface, no GPU)

proc swapFrameState*(s: var FrameState) =
  ## Puts `s`'s drawing in place of the one going on, and the one going on
  ## into `s` (nothing copied): a frame of another window, drawn in the
  ## middle of this one.
  for l in 0 ..< MaxLayers: swap(s.layers[l], layers[l])
  swap(s.arena, arena)
  swap(s.imgArena, imgArena)
  swap(s.pathArena, pathArena)
  swap(s.frameBitmaps, frameBitmaps)
  swap(s.clipStack, clipStack)
  swap(s.layerStack, layerStack)
  swap(s.curLayer, curLayer)
  swap(s.curClip, curClip)
  swap(s.screenRect, screenRect)
  swap(s.clearColor, clearColor)
  swap(s.frameHash, frameHash)
  swap(s.shownHash, shownHash)
  swap(s.mirrorW, mirrorW)
  swap(s.noMirror, noMirror)
  swap(s.fb, fb)
  swap(s.fbMem, fbMem)
  swap(s.fbSurface, fbSurface)
  swap(s.fbW, fbW)
  swap(s.fbH, fbH)
  swap(s.tileHash, tileHash)
  swap(s.shownTiles, shownTiles)
  swap(s.tileSalt, tileSalt)
  swap(s.tilesX, tilesX)
  swap(s.tilesY, tilesY)
  var e = drawingExtra
  swap(s.extra, e)
  drawingExtra = e
  # (the buffer of our own moved: its pointer follows it)
  if not fbSurface and fb.len > 0: fbMem = cast[ptr UncheckedArray[uint32]](addr fb[0])
  if not s.fbSurface and s.fb.len > 0: s.fbMem = cast[ptr UncheckedArray[uint32]](addr s.fb[0])

proc framePicture*(): Bitmap =
  ## The window's pixels as last drawn by the CPU (device pixels,
  ## 0xFFRRGGBB), for checks and screenshots the app takes of itself; nil
  ## while the GPU draws or before the first frame.
  if fbMem == nil or fbW <= 0 or fbH <= 0: return nil
  result = newBitmap(fbW, fbH)
  for i in 0 ..< fbW * fbH: result.px[i] = fbMem[i] or 0xFF000000'u32
  result.opaque = true

proc present*(devW, devH: int; force: bool): bool =
  ## Rasterize and show the frame. Nothing happens -- not even a driver
  ## call -- when the frame is the one already on screen; otherwise only
  ## the tiles that changed are drawn and sent.
  if not force and frameHash == shownHash and devW == fbW and devH == fbH:
    return false
  var force = force
  if devW != fbW or devH != fbH:
    fbW = max(1, devW)
    fbH = max(1, devH)
    force = true
  # with the GPU when there is one (tried once; the CPU's framebuffer is
  # then not needed)
  if not drawingExtra and not gpuTried and gpuWanted != gmCpu and gpuRelays.startGpu != nil:
    if startGpu():
      fb = @[]
      fbMem = nil
      fbSurface = false
  if gpuOn and not drawingExtra:
    if gpuRelays.gpuReady != nil and not gpuRelays.gpuReady():
      return false                  # (no surface now: in the background)
    var shown = false
    if gpuPresent(force, shown):
      shownHash = frameHash
      return shown
    # (the context was lost: the CPU draws from now on)
    stopGpu()
  # the window's own pixels when the driver lends them (nothing copied on
  # the way to the screen), else a buffer of our own
  let lent = if unitPx == 1 and surfaceRelays.lockSurface != nil and surfaceWanted and
                not drawingExtra:
               surfaceRelays.lockSurface(fbW, fbH)
             else: nil
  if lent != nil:
    if not fbSurface or lent != fbMem:
      force = true                    # (a new buffer: all of it drawn)
    fbMem = lent
    fbSurface = true
    if fb.len > 0: fb = @[]
  else:
    if fbSurface or fb.len != fbW * fbH:
      # (back from the GPU or the window's buffer: one of our own, all of
      # it drawn)
      fbSurface = false
      fb.setLen(fbW * fbH)
      tilesX = 0
      force = true
    fbMem = cast[ptr UncheckedArray[uint32]](addr fb[0])
  tileRuns(force, frameRuns)
  template runs: untyped = frameRuns
  let nx = tilesX
  let ny = tilesY
  let n = nx * ny
  for b in frameBitmaps: b.dirty = rect(0, 0, 0, 0)
  # texts made ready on this thread (shaping and the glyph cache are not
  # shared), then the tiles drawn -- on all the cores when they are many --
  # then sent
  inc frameNo
  prepGlyphs.setLen(0)
  prepSpans.setLen(0)
  frameMasks.setLen(0)
  if runs.len > 0:
    for l in 0 ..< MaxLayers:
      for i in 0 ..< layers[l].len:
        template c: untyped = layers[l][i]
        case c.kind
        of ckPixIcon, ckVText, ckSysText:
          # (only what is in the tiles drawn)
          let d = cmdDev[l][i]
          var inside = false
          for r in runs:
            if intersects(r, d):
              inside = true
              break
          if c.kind == ckVText:
            c.mag = 0
            if inside: prepVText(c)
          elif not inside: discard
          elif c.kind == ckPixIcon: prepPixIcon(c)
          elif sysRunsOn():
            # (the platform's text made into pixels here, on this thread)
            discard sysRunOf(arena[c.a ..< c.a + c.b])
        else: discard
  template items: untyped = bandItems
  items.setLen(0)
  var area = 0
  for r in runs:
    var y = r.y
    area += r.w * r.h
    while y < r.y + r.h:
      let h = min(BandH, r.y + r.h - y)
      items.add rect(r.x, y, r.w, h)
      y += h
  # the commands that reach into each row of tiles drawn, in order (a band
  # then goes through its own, not through every command of the frame)
  if items.len > 0:
    if bandCmds.len < ny: bandCmds.setLen(ny)
    if bandWanted.len < ny: bandWanted.setLen(ny)
    for ty in 0 ..< ny: bandWanted[ty] = false
    for it in items:
      bandWanted[it.y div BandH] = true
      bandCmds[it.y div BandH].setLen(0)
    for l in 0 ..< MaxLayers:
      for i in 0 ..< layers[l].len:
        let b = cmdDev[l][i]
        if b.w <= 0 or b.h <= 0: continue
        for ty in max(0, b.y div BandH) .. min(ny - 1, (b.y + b.h - 1) div BandH):
          if bandWanted[ty]: bandCmds[ty].add (uint32(l) shl 28) or uint32(i)
  template sys: untyped = bandSys
  sys.setLen(items.len)
  if items.len >= 2 and area >= ParallelMinPx and threadCount() > 1:
    inParallel = true
    # (the bands and their answers are globals: the closure holds nothing,
    # so it is not made anew for every frame)
    parallelFor(items.len, proc (lo, hi: int) =
      for i in lo ..< hi: bandSys[i] = drawRegion(bandItems[i], bandItems[i].y div BandH),
      keepAlive = false)
    inParallel = false
  else:
    for i in 0 ..< items.len: sys[i] = drawRegion(items[i], items[i].y div BandH)
  var hasSys = false
  for v in sys: hasSys = hasSys or v
  for r in runs: send(r)
  for t in 0 ..< n: shownTiles[t] = tileHash[t]
  if hasSys: drawSysTexts(runs)
  if runs.len > 0: refresh()
  shownHash = frameHash
  result = runs.len > 0

{.pop.}

proc dropDrawingCaches*() =
  ## What drawing keeps to be fast and can make again -- rendered glyphs,
  ## magnified icons, the system's text as pictures, buffers of the last
  ## frames -- let go of (the device short of memory, the app in the
  ## background). Between frames only.
  forgetGlyphs()
  frameMasks = @[]
  prepGlyphs = @[]
  prepSpans = @[]
  hdArts.clear()
  sysRuns.clear()
  scratch = @[]
  bandCmds = @[]
  bandItems = @[]
  bandSys = @[]
  frameRuns = @[]
  for l in 0 ..< MaxLayers: cmdDev[l] = @[]

proc stampOf*(b: Bitmap): uint64 =
  ## A number that changes whenever `changed(b)` is called (0 for nil):
  ## lets code that keeps a drawing (a canvas) tell when a picture it draws
  ## was edited.
  if b == nil: 0'u64 else: b.stamp

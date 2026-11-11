## Styled text, laid out and drawn as an image editor's type does: any
## TrueType font installed on the system, an app's own (`addFontDir`,
## `addFontData`) or the built-in GNU FreeFont (FreeSans, FreeSerif with its
## Arabic, FreeMono), per character the
## font, size, color, tracking, kerning, leading, baseline shift,
## horizontal and vertical scale, faux bold and italic, all caps and small
## caps, superscript and subscript, underline and strikethrough; per
## paragraph the alignment (and justification), indents and spacing; point
## text or text in a box (wrapped); right-to-left and Arabic text; warped
## text (Arc, Arch, Bulge, Flag, Wave, Fish, Rise, Fisheye, Inflate,
## Squeeze, Twist...) and text along a path.
##
## ```nim
## var t = newText("Hello", CharStyle(family: "FreeSans", size: 48, color: 0xFF000000'u32))
## t.x = 20; t.y = 80                   # the first baseline's start
## let px = t.renderText(400, 200)      # ARGB pixels, transparent around
## ```
##
## Positions are in pixels of the picture drawn on (y down).

import std/[math, os, strutils, tables, algorithm, json]
import std/unicode except strip   # (its strip cuts letters: docs/nim-bugs.md)
import ttf, typeset, raster, otshape, unpacking

const defaultFamily* = "FreeSans"
  ## The family of new text

# ---- fonts ------------------------------------------------------------------------------------------------

type
  FontEntry* = object
    ## A face the catalog knows: a style of a family.
    family*, style*: string    ## "FreeSerif", "Bold Italic"
    path*: string              ## its file ("" for a built-in face)
    index*: int                ## in a .ttc
    builtin*: FaceId           ## a built-in face: which (`path` "")
    weight*: int               ## 100 (thin) .. 900 (black); 400 regular, 700 bold
    italic*: bool              ## italic or oblique

var
  catalog: seq[FontEntry]
  scanned = false
  extraDirs: seq[string]
  loaded: Table[string, Face]
  unreadable: Table[string, string]   ## family -> why its file could not be read

var memFonts: seq[tuple[entry: FontEntry; ticket: int; face: Face]]
  ## (a packed one: unpacked on a thread from when it is offered, `unpacking`)
  ## Fonts an app (or a module) carries in itself (`addFontData`).

proc addFontData*(family, style: string; data: string; packed = false; weight = 400; italic = false) =
  ## Offers a font the program carries -- its bytes (`packed`: zlib
  ## compressed, as `staticRead` of a ".ttf.z", unpacked on a thread from
  ## now) -- as `family` / `style`, read the first time it is drawn. Again
  ## with the same family and style: nothing.
  for m in memFonts:
    if m.entry.family == family and m.entry.style == style: return
  memFonts.add (FontEntry(family: family, style: style, path: "<mem:" & $memFonts.len & ">", weight: weight,
                          italic: italic), (if packed: unpackSoon(data) else: -1),
                (if packed: nil else: parseFace(data)))
  if scanned: catalog.add memFonts[^1].entry

proc memFace(path: string): Face =
  ## (a carried font's face, unpacked the first time)
  let i = try: parseInt(path[5 ..< path.high]) except ValueError: -1
  if i < 0 or i >= memFonts.len: return face(fSans)
  if memFonts[i].face == nil:
    let s = unpacked(memFonts[i].ticket)
    memFonts[i].ticket = -1
    memFonts[i].face = if s.len > 0: parseFace(s) else: face(fSans)
  memFonts[i].face

proc builtinEntries(): seq[FontEntry] =
  ## GNU FreeFont, built in (FreeSerif with its Arabic, set by its OpenType
  ## tables), and the fonts the program carries.
  for fam in [fSans, fSerif, fMono]:
    let name = (case fam
                of fSans: "FreeSans"
                of fSerif: "FreeSerif"
                else: "FreeMono")
    for (id, st, wt, it) in [(fam, "Regular", 400, false), (styled(fam, true, false), "Bold", 700, false),
                             (styled(fam, false, true), (if fam == fSerif: "Italic" else: "Oblique"), 400, true),
                             (styled(fam, true, true), (if fam == fSerif: "Bold Italic" else: "Bold Oblique"),
                              700, true)]:
      result.add FontEntry(family: name, style: st, builtin: id, weight: wt, italic: it)
  for m in memFonts: result.add m.entry

const formerFonts = [("DejaVu Sans", "FreeSans"), ("DejaVu Sans Mono", "FreeMono"), ("Amiri", "FreeSerif"),
                     ("Retro Sans", "FreeSans"), ("MS W98 UI", "FreeSans"), ("Open Sans", "FreeSans"),
                     ("Kawkab Mono", "FreeMono"), ("Fixedsys Excelsior", "FreeMono")]
  ## the kit's fonts of before: a document that names one, where it is not
  ## installed, is drawn in the FreeFont that took its place

proc systemFontDirs*(): seq[string] =
  ## Where this system keeps its fonts.
  when defined(android):
    @["/system/fonts", "/product/fonts", "/system/product/fonts"]
  elif defined(windows):
    @[getEnv("WINDIR", "C:\\Windows") / "Fonts", getEnv("LOCALAPPDATA") / "Microsoft" / "Windows" / "Fonts"]
  elif defined(ios):
    @["/System/Library/Fonts"]
  elif defined(macosx):
    @["/System/Library/Fonts", "/System/Library/Fonts/Supplemental", "/Library/Fonts",
      getHomeDir() / "Library" / "Fonts"]
  else:
    # Linux and the BSDs: the system's first (a family found twice is the
    # first one's), XDG's data folders, the X11 fonts of OpenBSD (X11R6),
    # NetBSD (X11R7) and FreeBSD, Termux's own ($PREFIX); then the user's
    # ($XDG_DATA_HOME, ~/.fonts)
    var dirs = @["/usr/share/fonts", "/usr/local/share/fonts"]
    for d in getEnv("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(':'):
      if d.len > 0: dirs.add d / "fonts"
    dirs.add ["/usr/X11R6/lib/X11/fonts", "/usr/X11R7/lib/X11/fonts", "/usr/local/lib/X11/fonts"]
    let prefix = getEnv("PREFIX")
    if prefix.len > 0: dirs.add prefix / "share" / "fonts"
    dirs.add getEnv("XDG_DATA_HOME", getHomeDir() / ".local" / "share") / "fonts"
    dirs.add [getHomeDir() / ".local" / "share" / "fonts", getHomeDir() / ".fonts"]
    for d in dirs:
      let n = d.normalizedPath
      if n notin result: result.add n

proc addFontDir*(dir: string) =
  ## Fonts in `dir` (and below) are offered too (an app's own fonts).
  if dir notin extraDirs:
    extraDirs.add dir
    scanned = false

proc scanDirs(dirs: seq[string]): seq[FontEntry] =
  ## (the faces of the font files in `dirs` and below, the first of each
  ## family and style)
  var seen: Table[string, bool]
  for dir in dirs:
    if not dirExists(dir): continue
    for path in walkDirRec(dir):
      let ext = path.splitFile.ext.toLowerAscii
      if ext notin [".ttf", ".ttc"]: continue
      try:
        if getFileSize(path) > 40_000_000: continue
      except OSError: continue
      for fi in faceInfo(path):
        let key = fi.family & "/" & fi.style
        if seen.hasKey(key): continue
        seen[key] = true
        result.add FontEntry(family: fi.family, style: fi.style, path: path, index: fi.index,
                             weight: fi.weight, italic: fi.italic)

const ScanThreads = compileOption("threads") and not defined(js) and not defined(emscripten)
when ScanThreads:
  import std/[typedthreads, locks]
  var
    scanThread: Thread[seq[string]]
    scanLock: Lock
    scanFound: seq[FontEntry]          # (what the thread found, under the lock)
  initLock(scanLock)

  proc scanWork(dirs: seq[string]) {.thread.} =
    let found = scanDirs(dirs)
    {.cast(gcsafe).}:
      withLock scanLock: scanFound = found

var
  scanSoon = 0                         # 1: the folders being looked through on a thread
  scanSoonDirs: seq[string]            # ... these

proc scanFontsSoon*() =
  ## Starts looking through the font folders on a thread, now: for an app
  ## that will list the fonts there are (a font menu) to find them there
  ## when it does. (Fonts the program has itself never wait for it.)
  when ScanThreads:
    if scanned or scanSoon != 0: return
    scanSoonDirs = systemFontDirs() & extraDirs
    scanSoon = 1
    createThread(scanThread, scanWork, scanSoonDirs)

proc scanFonts*(force = false) =
  ## Looks through the font folders (once; again with `force`).
  if scanned and not force: return
  scanned = true
  if force:
    loaded.clear()                    # (files fetched or replaced since: read again)
    unreadable.clear()
  catalog = builtinEntries()
  var seen: Table[string, bool]
  for e in catalog: seen[e.family & "/" & e.style] = true
  let dirs = systemFontDirs() & extraDirs
  var found: seq[FontEntry]
  var left = dirs
  when ScanThreads:
    if scanSoon == 1:
      # (looked through on a thread already: what it found, and the folders
      # offered since, here)
      joinThread(scanThread)
      scanSoon = 0
      withLock scanLock: found = move scanFound
      if force: found.setLen(0)
      else:
        left.setLen(0)
        for d in dirs:
          if d notin scanSoonDirs: left.add d
  found.add scanDirs(left)
  for e in found:
    let key = e.family & "/" & e.style
    if seen.hasKey(key): continue
    seen[key] = true
    catalog.add e

var carriedList: seq[FontEntry]        # FreeFont and the fonts the program carries
var carriedFor = -1                    # ... made for this many carried fonts

proc carriedEntries(family: string): bool =
  ## (`family` is one the program has itself: found without looking through
  ## the font folders -- the faces it has are the ones they would give)
  if carriedFor != memFonts.len:
    carriedList = builtinEntries()
    carriedFor = memFonts.len
  for e in carriedList:
    if e.family == family: return true

proc fontFamilies*(): seq[string] =
  ## The families there are, the built-in ones first, the rest by name.
  scanFonts()
  var seen: Table[string, bool]
  var rest: seq[string]
  for e in catalog:
    if seen.hasKey(e.family): continue
    seen[e.family] = true
    if e.path.len == 0 or e.path.startsWith("<"): result.add e.family else: rest.add e.family
  rest.sort(proc (a, b: string): int = cmpIgnoreCase(a, b))
  result.add rest

proc fontStyles*(family: string): seq[string] =
  ## The styles of a family ("Regular", "Bold", "Italic"...), lighter first.
  let own = not scanned and carriedEntries(family)
  if not own: scanFonts()
  var es: seq[FontEntry]
  for e in (if own: carriedList else: catalog):
    if e.family == family: es.add e
  es.sort(proc (a, b: FontEntry): int =
    result = cmp(a.weight, b.weight)
    if result == 0: result = cmp(ord(a.italic), ord(b.italic)))
  for e in es: result.add e.style
  if result.len == 0: result = @["Regular"]

proc entryFace(e: FontEntry): Face =
  if e.path.len == 0: return face(e.builtin)
  if e.path.startsWith("<mem:"): return memFace(e.path)
  let key = e.path & "#" & $e.index
  if loaded.hasKey(key): return loaded[key]
  try:
    result = parseFace(readFile(e.path), e.index)
  except CatchableError, Defect:
    # (drawn in FreeSans instead -- and said: `fontProblem`)
    let x = getCurrentException()
    result = face(fSans)
    unreadable[e.family] = e.path.extractFilename & ": " & x.msg
  loaded[key] = result

proc fontProblem*(family: string): string =
  ## Why `family` is drawn in another font ("" when it is not): its file
  ## cannot be read, or it is not one of the fonts there are.
  scanFonts()
  var found = false
  for e in catalog:
    if e.family == family:
      found = true
      discard entryFace(e)
  if not found: return (if family.len == 0: "" else: family & " is not installed")
  unreadable.getOrDefault(family, "")

proc fontFace*(family, style: string): tuple[face: Face; fauxBold, fauxItalic: bool] =
  ## The face for a family and style; a style it lacks is made from the
  ## one it has (faux bold, faux italic); an unknown family is FreeSans (a
  ## font the kit had before, FreeFont's like of it: "Amiri" is FreeSerif).
  # (FreeFont and the fonts the program carries: found without looking
  # through the font folders)
  let own = not scanned and carriedEntries(family)
  if not own: scanFonts()
  let wantBold = style.toLowerAscii.contains("bold") or style.toLowerAscii.contains("black") or
                 style.toLowerAscii.contains("heavy")
  let wantItalic = style.toLowerAscii.contains("italic") or style.toLowerAscii.contains("oblique")
  var best = -1
  var bestScore = -1
  let list = if own: addr carriedList else: addr catalog
  for i, e in list[]:
    if e.family != family: continue
    if e.style == style: return (entryFace(e), false, false)
    var sc = 0
    if (e.weight >= 600) == wantBold: sc += 2
    if e.italic == wantItalic: sc += 3
    if e.weight == 400: inc sc
    if sc > bestScore:
      bestScore = sc
      best = i
  if best < 0:
    for (old, now) in formerFonts:
      if cmpIgnoreCase(family, old) == 0 and now != family: return fontFace(now, style)
    let id = styled(fSans, wantBold, wantItalic)
    return (face(id), fauxStyle(id).bold, fauxStyle(id).italic)
  let e = list[][best]
  (entryFace(e), wantBold and e.weight < 600, wantItalic and not e.italic)

# ---- styles -------------------------------------------------------------------------------------------------

type
  Script* = enum
    ## Characters on the line, raised and smaller, or lowered and smaller.
    scNormal = "Normal", scSuper = "Superscript", scSub = "Subscript"

  CharStyle* = object
    ## How characters look (the Character palette).
    family*: string            ## "" is FreeSans
    style*: string             ## "Regular", "Bold", "Italic"...
    size*: float32             ## pixels
    color*: uint32             ## ARGB
    tracking*: int             ## thousandths of an em between letters
    noKerning*: bool           ## the font's kerning not used
    leading*: float32          ## the distance of the lines (0: 120% of the size)
    baselineShift*: float32    ## pixels up
    hScale*, vScale*: float32  ## 0 or 1: as drawn (0.5: half as wide / tall)
    fauxBold*, fauxItalic*: bool  ## made bolder (its outline widened), slanted
    allCaps*, smallCaps*: bool    ## drawn in capitals; small letters as small capitals
    underline*, strike*: bool     ## a line under it, through it
    script*: Script            ## superscript or subscript
    digits*: int               ## 0 as typed, 1 Arabic-Indic (٠١٢), 2 Persian (۰۱۲)
    features*: string          ## OpenType features changed from the font's own, "+ss01 -liga dlig"
                               ## (the OpenType palette); "" as the font sets
    variation*: string         ## a variable font's axes, "wght=650 wdth=90" ("" its default)
    styleName*: string         ## the Character Style it has (Character Styles; "" none)

  TextAlign* = enum
    ## How a paragraph's lines stand: left, centered, right, or justified
    ## (both edges straight) with the last line left, centered, right or
    ## justified too.
    textLeft = "Left", textCenter = "Center", textRight = "Right", justifyLeft = "Justify Last Left",
    justifyCenter = "Justify Last Centered", justifyRight = "Justify Last Right",
    justifyAll = "Justify All"

  ParaStyle* = object
    ## How paragraphs are set (the Paragraph palette).
    align*: TextAlign          ## how its lines stand
    indentLeft*, indentRight*, indentFirst*: float32
      ## pixels in from the left, from the right, and the first line's more
    spaceBefore*, spaceAfter*: float32  ## pixels above and below a paragraph
    rtl*: int                  ## the direction: 0 from the text, 1 left to right, 2 right to left
                               ## (right to left: the alignment's Left is where lines start -- the
                               ## right -- and Right where they end, as Arabic is set)
    noKashida*: bool           ## justified Arabic lengthened at its spaces only -- not, as Arabic is
                               ## set, at its joins (tatweel) first (as `kashida` = kaNone)
    kashida*: KashidaLength    ## justified Arabic: how long its kashidas may be (Photoshop's
                               ## Insert Kashida)
    styleName*: string         ## the Paragraph Style it has (Paragraph Styles; "" none)

  KashidaLength* = enum
    ## How much justified Arabic is lengthened at its joins (tatweel) -- one
    ## join a word, where a scribe would put it -- before its spaces.
    kaMedium = "Medium", kaNone = "None", kaShort = "Short", kaLong = "Long", kaStylistic = "Stylistic"

  TextSpan* = object
    ## Text in one character style.
    text*: string              ## what it says (UTF-8; "\n" ends a paragraph)
    style*: CharStyle          ## how it looks

  WarpStyle* = enum
    ## The shape a text is bent into (Warp Text).
    wsNone = "None", wsArc = "Arc", wsArcLower = "Arc Lower", wsArcUpper = "Arc Upper", wsArch = "Arch",
    wsBulge = "Bulge", wsShellLower = "Shell Lower", wsShellUpper = "Shell Upper", wsFlag = "Flag",
    wsWave = "Wave", wsFish = "Fish", wsRise = "Rise", wsFisheye = "Fisheye", wsInflate = "Inflate",
    wsSqueeze = "Squeeze", wsTwist = "Twist"

  TextWarp* = object
    ## How a text is bent (Warp Text).
    style*: WarpStyle          ## the shape (`wsNone`: not bent)
    bend*: int                 ## -100..100
    hDistort*, vDistort*: int  ## -100..100
    vertical*: bool            ## bent up and down instead of across

  TextData* = object
    ## A text: what it says and how it is set and where.
    spans*: seq[TextSpan]      ## what it says, span by span
    para*: ParaStyle           ## how its paragraphs are set
    x*, y*: float32            ## point text: the first baseline's start (its end, or middle, by the
                               ## alignment); text in a box: the box's top left
    boxW*, boxH*: float32      ## > 0: text in a box (wrapped)
    warp*: TextWarp            ## how it is bent
    path*: seq[(float32, float32)]   ## text on a path: the path's points (a polyline)
    pathOffset*: float32       ## where along the path it starts
    antialias*: bool           ## (`newText` makes it true)
    vertical*: bool            ## vertical type: the lines run down, one after another to the left
                               ## (each set as across, turned a quarter clockwise round `x`, `y`:
                               ## Latin letters lie on their side, as Photoshop sets them)
    fit*: bool                 ## Dynamic Text: text in a box drawn as big as fills the box (its
                               ## sizes all scaled together; the box sized, the text follows)
    columns*: int              ## text in a box: in this many columns (0, 1: one), side by side;
                               ## what is more than the box holds is not drawn (`overflow`)
    gutter*: float32           ## ... the room between them (0: 12 pixels)
    clipOverflow*: bool        ## text in a box: what does not fit not drawn (it flows on into
                               ## another box -- `remainder`)

proc defaultStyle*(): CharStyle =
  ## The style of a new text: FreeSans Regular, 36 pixels, black.
  CharStyle(family: defaultFamily, style: "Regular", size: 36, color: 0xFF000000'u32, hScale: 1, vScale: 1)

proc newText*(s: string; style = defaultStyle(); x = 0'f32; y = 0'f32): TextData =
  ## A point text saying `s` in one style.
  TextData(spans: @[TextSpan(text: s, style: style)], x: x, y: y, antialias: true)

proc plainText*(t: TextData): string =
  ## What the text says.
  for s in t.spans: result.add s.text

proc runeLen*(t: TextData): int =
  ## How many characters the text has.
  for s in t.spans: result += s.text.runeLen

# ---- editing ----------------------------------------------------------------------------------------------

proc normalize(t: var TextData) =
  ## Empty spans out, neighbours of one style joined.
  var o: seq[TextSpan]
  for s in t.spans:
    if s.text.len == 0: continue
    if o.len > 0 and o[^1].style == s.style: o[^1].text.add s.text
    else: o.add s
  if o.len == 0 and t.spans.len > 0: o.add TextSpan(text: "", style: t.spans[0].style)
  t.spans = o

proc styleAt*(t: TextData; i: int): CharStyle =
  ## The style of character `i` (of the one before it at the end).
  if t.spans.len == 0: return defaultStyle()
  var at = 0
  for s in t.spans:
    let n = s.text.runeLen
    if i < at + n: return s.style
    at += n
  t.spans[^1].style

proc splitAt(t: var TextData; i: int) =
  ## A span boundary at character `i`.
  var at = 0
  for k in 0 ..< t.spans.len:
    let n = t.spans[k].text.runeLen
    if i > at and i < at + n:
      let r = t.spans[k].text.toRunes
      let a = $r[0 ..< i - at]
      let b = $r[i - at .. ^1]
      t.spans[k].text = a
      t.spans.insert(TextSpan(text: b, style: t.spans[k].style), k + 1)
      return
    at += n

proc insertText*(t: var TextData; i: int; s: string; style: CharStyle) =
  ## `s` put in at character `i` in `style`.
  if s.len == 0: return
  t.splitAt(i)
  var at = 0
  var k = 0
  while k < t.spans.len and at + t.spans[k].text.runeLen <= i:
    at += t.spans[k].text.runeLen
    inc k
  if t.spans.len == 0: t.spans.add TextSpan(text: "", style: style)
  if k > 0 and t.spans[k - 1].style == style: t.spans[k - 1].text.add s
  else: t.spans.insert(TextSpan(text: s, style: style), k)
  t.normalize()

proc deleteText*(t: var TextData; a, b: int) =
  ## Characters `a` ..< `b` taken out.
  if b <= a: return
  t.splitAt(a)
  t.splitAt(b)
  var at = 0
  var o: seq[TextSpan]
  for s in t.spans:
    let n = s.text.runeLen
    if not (at >= a and at + n <= b): o.add s
    at += n
  let first = if t.spans.len > 0: t.spans[0].style else: defaultStyle()
  t.spans = o
  if t.spans.len == 0: t.spans.add TextSpan(text: "", style: first)
  t.normalize()

proc restyle*(t: var TextData; a, b: int; change: proc (s: var CharStyle)) =
  ## The style of characters `a` ..< `b` changed by `change` (all of them
  ## when `a` = `b`).
  var (a, b) = (a, b)
  if b <= a:
    a = 0
    b = t.runeLen
  t.splitAt(a)
  t.splitAt(b)
  var at = 0
  for s in t.spans.mitems:
    let n = s.text.runeLen
    if at >= a and at + n <= b: change(s.style)
    at += n
  if t.runeLen == 0 and t.spans.len > 0: change(t.spans[0].style)
  t.normalize()

# ---- layout -----------------------------------------------------------------------------------------------

type
  LaidGlyph* = object
    ## A glyph laid out (`layoutText`): which, from which face, where and how.
    face*: Face                ## the face it is drawn from
    gid*: int                  ## its glyph in the face
    x*, y*: float32            ## the pen on the baseline
    size*: float32             ## pixels per em
    hScale*, vScale*: float32  ## its width and height scaled so
    embolden*, shear*: float32 ## faux bold (pixels the outline is widened), faux italic (the slant)
    color*: uint32             ## ARGB
    index*: int                ## the character it shows
    adv*: float32              ## how wide it is

  LaidLine* = object
    ## A line laid out.
    baseline*: float32         ## where its baseline is (y)
    ascent*, descent*: float32 ## how far its letters reach above and below it
    x0*, x1*: float32          ## where its letters begin and end
    first*, last*: int         ## its characters (`first` ..< `last`)
    rtl*: bool                 ## a right-to-left line

  Decoration* = object
    ## An underline or a strike: a bar from `x0` to `x1` at `y`, `thick` thick.
    x0*, x1*, y*, thick*: float32  ## where it runs and how thick it is (pixels)
    color*: uint32                 ## ARGB

  TextLayout* = object
    ## A text laid out (`layoutText`): its glyphs, lines and bars, ready to
    ## draw or to place a caret in.
    glyphs*: seq[LaidGlyph]        ## in the order they are drawn
    lines*: seq[LaidLine]          ## top to bottom
    decorations*: seq[Decoration]  ## its underlines and strikes
    caretX*: seq[float32]      ## per character (and the end): where the caret goes before it
    caretLine*: seq[int]       ## ... on which line
    x0*, y0*, x1*, y1*: float32    ## the bounds of the letters
    overflow*: int             ## text in a box, columns: the first character that did not fit
                               ## (it flows on into the next box); -1: all of it fits

  GlyphPart = object
    gid: int
    dx, dy, adv: float32       # (pixels: drawn so far from the pen, the pen moved on so far)

  CharInfo = object
    cp, shown: int             # the character, and what is drawn (joined form; -1 nothing)
    nominal: int               # (the character as typed, digits and caps made: what OpenType shapes)
    shaped: bool               # set by the font's OpenType tables: `parts` drawn, not `gid`
    parts: seq[GlyphPart]
    markDx, markDy: float32    # (a Thai mark: pixels from the pen, right and up)
    style: int                 # index into styles
    face: Face
    gid: int
    size, adv: float32
    space, newline: bool
    level: int8

proc effective(st: CharStyle): CharStyle =
  result = st
  if result.size <= 0: result.size = 12
  if result.hScale <= 0: result.hScale = 1
  if result.vScale <= 0: result.vScale = 1
  if result.family.len == 0: result.family = defaultFamily

proc pickGlyph(f: Face; cp: int): (Face, int) =
  if cp < 0: return (f, 0)
  let g = f.glyphOf(cp)
  if g != 0: return (f, g)
  for id in [fSans, arabicSource(false), fSerif, fIcons]:
    let ff = face(id)
    let gg = ff.glyphOf(cp)
    if gg != 0: return (ff, gg)
  (f, 0)

proc joiningType(cp: int): char =
  ## (Arabic joining: 'D' both sides, 'R' to the letter before only, 'U' none, 'T' a mark)
  if cp in 0x064B .. 0x065F or cp == 0x0670 or cp in 0x06D6 .. 0x06ED: return 'T'
  if cp == 0x0640: return 'D'                     # (the tatweel joins both ways)
  if cp in [0x0622, 0x0623, 0x0624, 0x0625, 0x0627, 0x0629, 0x062F, 0x0630, 0x0631, 0x0632, 0x0648, 0x0671,
            0x0672, 0x0673, 0x0675, 0x0676, 0x0677, 0x06C0, 0x06D2, 0x06D3] or cp in 0x0688 .. 0x0699 or
     cp in 0x06C3 .. 0x06CB or cp == 0x06CD or cp == 0x06CF: return 'R'
  if cp in [0x0626, 0x0628, 0x0649, 0x064A, 0x066E, 0x066F, 0x06C1, 0x06C2, 0x06CC, 0x06CE, 0x06D0, 0x06D1,
            0x06FF] or cp in 0x062A .. 0x062E or cp in 0x0633 .. 0x063A or cp in 0x0641 .. 0x0647 or
     cp in 0x0678 .. 0x0687 or cp in 0x069A .. 0x06BF or cp in 0x06FA .. 0x06FC: return 'D'
  'U'

proc kashidaRank(chars: seq[CharInfo]; k, e: int): int =
  ## (how good a place the join after letter `k` is for the word's kashida,
  ## by the rules of the scribes (Naskh), best first:
  ##   9  a tatweel typed there: lengthened first
  ##   8  after Seen, Sheen, Sad, Dad (سـ صـ): their bowl drawn out
  ##   7  before a final Heh, Teh Marbuta, Dal, Thal (ـه ـة ـد)
  ##   6  after Jeem, Hah, Khah (جـ حـ خـ), Ain, Ghain
  ##   5  after Tah, Zah (طـ ظـ); before a final Alef, Lam, Kaf, Gaf
  ##   4  before a final Reh, Zain, Waw
  ##   3  before a final Ain, Qaf, Feh, Yeh, Alef Maksura
  ##   1  any other join -- but never before a letter of the teeth (Beh,
  ##      Teh, Theh, Noon, Yeh) in the middle of a word: 0)
  let c = chars[k].cp
  var j = k + 1
  while j < e and joiningType(chars[j].cp) == 'T': inc j
  if j >= e: return 0
  let n = chars[j].cp
  # (is the next letter the word's last?)
  var after = j + 1
  while after < e and joiningType(chars[after].cp) == 'T': inc after
  let last = after >= e or chars[after].space or joiningType(chars[after].cp) in {'U', 'R'} and
             (after + 1 >= e or chars[after + 1].space)
  let final = after >= e or chars[after].space or joiningType(n) == 'R' or
              joiningType(chars[after].cp) == 'U'
  if c == 0x0640: return 9
  if c in [0x0633, 0x0634, 0x0635, 0x0636]: return 8                 # Seen, Sheen, Sad, Dad
  if final and n in [0x0647, 0x0629, 0x062F, 0x0630]: return 7      # Heh, Teh Marbuta, Dal, Thal
  if c in [0x062C, 0x062D, 0x062E, 0x0639, 0x063A]: return 6         # Jeem, Hah, Khah, Ain, Ghain
  if c in [0x0637, 0x0638]: return 5                                 # Tah, Zah
  if final and n in [0x0627, 0x0623, 0x0625, 0x0622, 0x0644, 0x0643, 0x06A9, 0x06AF]: return 5
  if final and n in [0x0631, 0x0632, 0x0648, 0x0698]: return 4
  if final and n in [0x0639, 0x063A, 0x0642, 0x0641, 0x064A, 0x0649, 0x06CC]: return 3
  if not final and n in [0x0628, 0x062A, 0x062B, 0x0646, 0x064A, 0x06CC, 0x067E]: return 0
  discard last
  1

proc clusterEnd(chars: seq[CharInfo]; k, e: int): int =
  ## (the last character of letter `k`'s cluster: it and the marks over or
  ## under it -- where its kashida goes, so the tashkeel stays on its letter)
  result = k
  while result + 1 < e and joiningType(chars[result + 1].cp) == 'T': inc result

proc joinsForward(chars: seq[CharInfo]; k, e: int): bool =
  ## (letter `k` joins the next letter -- a place for a kashida; not into
  ## lam-alef, which is one glyph)
  if joiningType(chars[k].cp) != 'D' or chars[k].shown < 0: return false
  var j = k + 1
  while j < e and joiningType(chars[j].cp) == 'T': inc j
  if j >= e: return false
  let n = chars[j]
  if n.shown < 0: return false                     # (joined into a ligature)
  if chars[k].cp == 0x0644 and n.cp in [0x0622, 0x0623, 0x0625, 0x0627]: return false
  joiningType(n.cp) in {'D', 'R'}

proc layoutPlain(t: TextData): TextLayout

proc sizesScaled*(t: TextData; k: float32): TextData =
  ## The text with its sizes (and leading, baseline shifts) times `k`, its
  ## place and box as they are.
  result = t
  for sp in result.spans.mitems:
    sp.style.size *= k
    sp.style.leading *= k
    sp.style.baselineShift *= k

proc fitScale*(t: TextData): float32 =
  ## Dynamic Text: how much the text's sizes are scaled to fill its box (1:
  ## not a fitted text).
  if not t.fit or t.boxW <= 0 or t.boxH <= 0 or t.path.len > 0 or t.spans.len == 0: return 1
  proc fits(k: float32): bool =
    let l = layoutPlain(t.sizesScaled(k))
    if l.lines.len == 0: return true
    for ln in l.lines:
      if ln.x1 - ln.x0 > t.boxW + 0.5: return false
    let last = l.lines[^1]
    last.baseline + last.descent <= t.y + t.boxH + 0.5
  var lo = 0.02'f32
  var hi = 50'f32
  if not fits(lo): return lo
  for _ in 0 ..< 18:
    let mid = sqrt(lo * hi)
    if fits(mid): lo = mid else: hi = mid
  lo

proc columnize(l: var TextLayout; t: TextData; colW, gutter: float32) =
  ## (the lines laid out a column wide moved into the columns side by side,
  ## each from the box's top; what does not fit the last one let go)
  let n = max(1, t.columns)
  let bottom = t.y + t.boxH + 0.5'f32
  var col = 0
  var yOff = 0'f32
  var inCol = 0
  var keep = l.lines.len
  var dxs = newSeq[float32](l.lines.len)
  var dys = newSeq[float32](l.lines.len)
  for i, ln in l.lines:
    if ln.baseline + ln.descent - yOff > bottom and inCol > 0:
      inc col
      inCol = 0
      if col >= n:
        keep = i
        break
      yOff = ln.baseline - ln.ascent - t.y
    if ln.baseline + ln.descent - yOff > bottom and col == n - 1 and inCol == 0 and i > 0:
      keep = i                    # (a line taller than the whole box: not drawn)
      break
    let rtl = ln.rtl
    let c = if rtl: n - 1 - col else: col      # (right to left: the first column at the right)
    dxs[i] = float32(c) * (colW + gutter)
    dys[i] = -yOff
    inc inCol
  l.overflow = if keep < l.lines.len: l.lines[keep].first else: -1
  # each character moved with its line
  let nch = l.caretX.len
  var cdx = newSeq[float32](nch)
  var cdy = newSeq[float32](nch)
  var gone = newSeq[bool](nch)
  for i, ln in l.lines:
    for k in ln.first .. min(ln.last, nch - 1):
      if i >= keep:
        gone[k] = true
      elif k < ln.last or k == nch - 1:
        cdx[k] = dxs[i]
        cdy[k] = dys[i]
  var gl: seq[LaidGlyph]
  for g in l.glyphs:
    let k = clamp(g.index, 0, nch - 1)
    if gone[k]: continue
    var h = g
    h.x += cdx[k]
    h.y += cdy[k]
    gl.add h
  l.glyphs = move gl
  var dec: seq[Decoration]
  for d in l.decorations:
    # (a decoration goes with the line it is under)
    var li = -1
    for i, ln in l.lines:
      if d.y >= ln.baseline - ln.ascent - 1 and d.y <= ln.baseline + ln.descent + ln.ascent:
        li = i
        break
    if li < 0 or li >= keep: continue
    var e = d
    e.x0 += dxs[li]
    e.x1 += dxs[li]
    e.y += dys[li]
    dec.add e
  l.decorations = move dec
  for k in 0 ..< nch:
    l.caretX[k] += cdx[k]
  if keep < l.lines.len: l.lines.setLen(keep)
  for i in 0 ..< l.lines.len:
    l.lines[i].baseline += dys[i]
    l.lines[i].x0 += dxs[i]
    l.lines[i].x1 += dxs[i]
  l.x0 = 1e9; l.y0 = 1e9; l.x1 = -1e9; l.y1 = -1e9
  for ln in l.lines:
    l.x0 = min(l.x0, ln.x0)
    l.x1 = max(l.x1, ln.x1)
    l.y0 = min(l.y0, ln.baseline - ln.ascent)
    l.y1 = max(l.y1, ln.baseline + ln.descent)
  if l.lines.len == 0:
    l.x0 = t.x; l.x1 = t.x; l.y0 = t.y; l.y1 = t.y

proc layoutText*(t: TextData): TextLayout =
  ## Where each glyph of the text goes (straight: warps and paths are made
  ## from this when drawn). Dynamic Text: as big as fills its box. In
  ## columns (`columns`), or kept in its box (`clipOverflow`): what does
  ## not fit is let go, `overflow` says from where.
  var u = t
  let cols = max(1, t.columns)
  let boxedCols = t.boxW > 0 and t.boxH > 0 and t.path.len == 0 and not t.vertical and
                  (cols > 1 or t.clipOverflow)
  let gutter = if t.gutter > 0: t.gutter else: 12'f32
  let colW = if boxedCols: max(8'f32, (t.boxW - gutter * float32(cols - 1)) / float32(cols)) else: t.boxW
  if boxedCols: u.boxW = colW
  result = if t.fit and t.boxW > 0 and t.boxH > 0 and t.path.len == 0: layoutPlain(u.sizesScaled(u.fitScale))
           else: layoutPlain(u)
  result.overflow = -1
  if boxedCols: result.columnize(t, colW, gutter)

proc remainder*(t: TextData; first: int): TextData =
  ## What is left of the text from character `first` on (what did not fit
  ## its box: it flows on into another), with its styles; the box, place
  ## and columns are the caller's to set.
  result = t
  result.spans = @[]
  var at = 0
  for sp in t.spans:
    let n = sp.text.runeLen
    if at + n <= first:
      at += n
      continue
    var piece = sp
    if first > at: piece.text = sp.text.runeSubStr(first - at)
    if piece.text.len > 0: result.spans.add piece
    at += n
  # (a new line it begins with: not a blank first line)
  if result.spans.len > 0 and result.spans[0].text.startsWith("\n"):
    result.spans[0].text = result.spans[0].text[1 .. ^1]

proc layoutPlain(t: TextData): TextLayout =
  var styles: seq[CharStyle]
  var faces: seq[tuple[face: Face; fauxBold, fauxItalic: bool]]
  var chars: seq[CharInfo]
  for sp in t.spans:
    let st = effective(sp.style)
    styles.add st
    var ff = fontFace(st.family, st.style)
    if st.variation.len > 0:
      # (a variable font at the axes chosen)
      var coords: seq[(string, float)]
      for w in strutils.splitWhitespace(st.variation):
        let p = w.split('=')
        if p.len == 2:
          try: coords.add (p[0], parseFloat(p[1])) except ValueError: discard
      if coords.len > 0 and ff.face.axes.len > 0: ff.face = ff.face.variation(coords)
    faces.add ff
    for r in sp.text.runes:
      chars.add CharInfo(cp: int(r), style: styles.high)
  let total = chars.len
  result.caretX = newSeq[float32](total + 1)
  result.caretLine = newSeq[int](total + 1)
  # paragraphs
  var paraStart = 0
  var penY = t.y
  let boxed = t.boxW > 0
  var firstLine = true
  var lineNo = 0
  while paraStart <= total:
    var paraEnd = paraStart
    while paraEnd < total and chars[paraEnd].cp != 10: inc paraEnd
    # the paragraph's characters: joined forms, bidi levels, glyphs, advances
    var s = ""
    for k in paraStart ..< paraEnd: s.add Rune(chars[k].cp).toUTF8
    let bi = bidiInfo(s, (if t.para.rtl == 1: 0 elif t.para.rtl == 2: 1 else: -1))
    let rtlPara = bi.rtlPara
    for k in paraStart ..< paraEnd:
      let c = addr chars[k]
      let j = k - paraStart
      c.shown = if j < bi.cps.len: bi.cps[j] else: c.cp
      c.level = if bi.levels.len > j: bi.levels[j] else: 0
      let st = styles[c.style]
      var size = st.size
      if st.script != scNormal: size *= 0.583
      if st.digits > 0 and c.cp >= ord('0') and c.cp <= ord('9'):
        c.shown = (if st.digits == 2: 0x06F0 else: 0x0660) + c.cp - ord('0')
      var shown = c.shown
      if shown >= 0 and (st.allCaps or st.smallCaps):
        let up = int(Rune(shown).toUpper)
        if st.smallCaps and up != shown and not st.allCaps: size *= 0.75
        shown = up
      c.shown = shown
      var nom = c.cp
      if st.digits > 0 and c.cp >= ord('0') and c.cp <= ord('9'):
        nom = (if st.digits == 2: 0x06F0 else: 0x0660) + c.cp - ord('0')
      if st.allCaps or st.smallCaps: nom = int(Rune(nom).toUpper)
      c.nominal = nom
      let (f, g) = pickGlyph(faces[c.style].face, shown)
      c.face = f
      c.gid = g
      c.size = size
      c.space = c.cp == 32 or c.cp == 9 or c.cp == 0x3000
      c.adv = if shown < 0: 0'f32
              else: float32(f.advance(g)) / float32(f.unitsPerEm) * size * st.hScale +
                    float32(st.tracking) / 1000 * st.size
      if c.cp == 9: c.adv = st.size * 2
    # OpenType: runs of one style and direction in a font with layout tables,
    # set as the font says -- its joined forms, ligatures, marks placed,
    # kerning, the features chosen (else the forms above, one a character)
    block shaping:
      var k = paraStart
      while k < paraEnd:
        let si = chars[k].style
        let fc = faces[si].face
        if fc == nil or not fc.hasLayout or chars[k].cp in [9, 10]:
          inc k
          continue
        let odd = chars[k].level and 1
        var e = k + 1
        while e < paraEnd and chars[e].style == si and (chars[e].level and 1) == odd and chars[e].cp notin [9, 10]:
          inc e
        # (all of it in the font: else as before, a character at a time; Thai
        # too, in a font that does not place its marks -- the kit's
        # FreeSerif --: they are placed below)
        var all = true
        var thai = false
        var cps = newSeq[int](e - k)
        for j in k ..< e:
          cps[j - k] = chars[j].nominal
          let cp = chars[j].nominal
          if cp >= 32 and cp notin [0x200C, 0x200D, 0x200E, 0x200F] and not fc.hasGlyph(cp): all = false
          if cp in 0x0E31 .. 0x0E4E and isMark(cp) and not fc.placesMark(fc.glyphOf(cp)): thai = true
        if thai: all = false
        if not all:
          k = e
          continue
        var feats: seq[Feature]
        for w in strutils.splitWhitespace(styles[si].features):
          if w.startsWith("-"): feats.add (w[1 .. ^1], false)
          elif w.startsWith("+"): feats.add (w[1 .. ^1], true)
          else: feats.add (w, true)
        if styles[si].noKerning: feats.add ("kern", false)     # (the font's kerning, GPOS's too, not used)
        let sh = try: shape(fc, cps, odd == 1, features = feats) except CatchableError: @[]
        if sh.len == 0:
          k = e
          continue
        let st = styles[si]
        for j in k ..< e:
          chars[j].shaped = true
          chars[j].face = fc
          chars[j].parts.setLen(0)
        let em = float32(fc.unitsPerEm)
        for g in sh:
          let j = k + clamp(g.cluster, 0, e - k - 1)
          let sc = chars[j].size / em
          chars[j].parts.add GlyphPart(gid: g.gid, dx: float32(g.xOff) * sc * st.hScale,
                                       dy: float32(g.yOff) * sc * st.vScale, adv: float32(g.xAdv) * sc * st.hScale)
        for j in k ..< e:
          var a = 0'f32
          for p in chars[j].parts: a += p.adv
          if chars[j].parts.len > 0: a += float32(st.tracking) / 1000 * st.size
          chars[j].adv = (if chars[j].cp == 9: st.size * 2 else: a)
          if chars[j].parts.len > 0: chars[j].gid = chars[j].parts[0].gid
        k = e
    # Thai vowels and tone marks a character at a time (the kit's FreeSerif
    # has no Thai tables): over and under their letter, stacked
    for k in paraStart + 1 ..< paraEnd:
      let c = addr chars[k]
      if c.shaped or c.cp notin 0x0E31 .. 0x0E4E or not isMark(c.cp) or c.shown < 0: continue
      var b = k - 1
      while b > paraStart and isMark(chars[b].cp): dec b
      if chars[b].shaped or chars[b].shown < 0 or isMark(chars[b].cp): continue
      var above = 0'f32
      for j in b + 1 ..< k:
        if chars[j].cp in 0x0E31 .. 0x0E4E and chars[j].cp notin 0x0E38 .. 0x0E3A and chars[j].size > 0:
          let jf = chars[j].face
          above = max(above, float32(jf.bounds(chars[j].gid).y1) / float32(jf.unitsPerEm) +
                             chars[j].markDy / chars[j].size)
      let p = thaiPlace(chars[b].cp, chars[b].face, chars[b].gid, c.cp, c.face, c.gid, above,
                        k + 1 < paraEnd and chars[k + 1].cp == 0x0E33)
      let st = styles[c.style]
      if p.left == p.left:
        var pen = 0'f32                     # (the letter's origin to this mark's pen)
        for j in b ..< k: pen += chars[j].adv
        c.markDx = min(0'f32, p.left * c.size * st.hScale - pen)
      c.markDy = p.y * c.size * st.vScale
    # kerning (left to right only)
    for k in paraStart + 1 ..< paraEnd:
      let a = chars[k - 1]
      let b = addr chars[k]
      if a.shaped or b.shaped: continue
      if a.face == b.face and a.style == b.style and not styles[b.style].noKerning and
         a.level == 0 and b.level == 0 and a.shown >= 0 and b.shown >= 0:
        chars[k - 1].adv += float32(a.face.kerning(a.gid, b.gid)) / float32(a.face.unitsPerEm) * a.size *
                            styles[a.style].hScale
    # lines: broken at spaces to fit the box
    let avail = if boxed: max(1'f32, t.boxW - t.para.indentLeft - t.para.indentRight) else: 1e9'f32
    var lines: seq[(int, int)]
    var ls = paraStart
    while true:
      var w = (if ls == paraStart: t.para.indentFirst else: 0'f32)
      var k = ls
      var lastBreak = -1
      while k < paraEnd:
        if chars[k].space: lastBreak = k
        if w + chars[k].adv > avail and k > ls and not chars[k].space:
          break
        w += chars[k].adv
        inc k
      if k >= paraEnd:
        lines.add (ls, paraEnd)
        break
      let cut = if lastBreak >= ls: lastBreak + 1 else: k
      lines.add (ls, cut)
      ls = cut
    if paraStart != 0: penY += t.para.spaceBefore
    for li, (a, b) in lines:
      var asc, desc, lead = 0'f32
      var any = false
      for k in a ..< b:
        let c = chars[k]
        let st = styles[c.style]
        let em = float32(c.face.unitsPerEm)
        asc = max(asc, float32(c.face.ascent) / em * c.size * st.vScale)
        desc = max(desc, -float32(c.face.descent) / em * c.size * st.vScale)
        lead = max(lead, if st.leading > 0: st.leading else: st.size * 1.2)
        any = true
      if not any:
        let st = styles[if a < total: chars[a].style elif total > 0: chars[total - 1].style else: 0]
        let size = if styles.len > 0: st.size else: 36'f32
        lead = if styles.len > 0 and st.leading > 0: st.leading else: size * 1.2
        asc = size * 0.93
        desc = size * 0.24
      # the first baseline: at y (point text) or under the box's top
      if firstLine:
        penY = if boxed: t.y + asc else: t.y
        firstLine = false
      else: penY += lead
      # the width (spaces at the end not counted)
      var e = b
      while e > a and (chars[e - 1].space or chars[e - 1].cp == 10): dec e
      var width = 0'f32
      for k in a ..< e: width += chars[k].adv
      let indent = t.para.indentLeft + (if a == paraStart: t.para.indentFirst else: 0'f32)
      let lastOfPara = li == lines.high
      let align = t.para.align
      var extraPerSpace = 0'f32
      var startX: float32
      let firstInd = if a == paraStart: t.para.indentFirst else: 0'f32
      # (right to left: the first line's indent is at the right, where lines start)
      let boxL = t.x + t.para.indentLeft + (if rtlPara: 0'f32 else: firstInd)
      let boxR = t.x + (if boxed: t.boxW - t.para.indentRight - (if rtlPara: firstInd else: 0'f32) else: 0'f32)
      let justify = boxed and (align == justifyAll or (align in {justifyLeft, justifyCenter, justifyRight} and
                                                        not lastOfPara))
      var spaces = 0
      if justify:
        for k in a ..< e:
          if chars[k].space: inc spaces
        if spaces > 0: extraPerSpace = max(0'f32, (avail - (indent - t.para.indentLeft) - width) / spaces.float32)
      # (justified Arabic: lengthened at its joins first, with tatweel -- one
      # join a word, the best place in it; as long as Insert Kashida lets)
      var kashidaAt = newSeq[float32](b - a)
      let kl = if t.para.noKashida: kaNone else: t.para.kashida
      if justify and rtlPara and kl != kaNone:
        var points: seq[int]
        var wbest = -1
        var wrank = 0
        for k in a ..< e:
          if chars[k].space:
            if wbest >= 0: points.add wbest
            wbest = -1
            wrank = 0
            continue
          if k < e - 1 and joinsForward(chars, k, e):
            let rk = kashidaRank(chars, k, e)
            # (the best place in the word; of equal ones, the last -- nearer
            # the word's end, as the scribes lengthen)
            if rk > 0 and (rk > wrank or (rk == wrank and rk <= 1)):
              wbest = k
              wrank = rk
        if wbest >= 0: points.add wbest
        if points.len > 0:
          let room = max(0'f32, avail - (indent - t.para.indentLeft) - width)
          let em = styles[chars[points[0]].style].size
          let most = case kl
                     of kaShort: 0.35'f32
                     of kaLong: 1.4'f32
                     of kaStylistic: 2.2'f32
                     else: 0.8'f32
          let share = if kl == kaStylistic: 0.95'f32 elif spaces == 0: 1'f32 else: 0.85'f32
          let each = min(room * share / points.len.float32, em * most)
          # (on the last of the letter's cluster: its tashkeel stays over it,
          # the tatweel drawn out after them)
          for k in points: kashidaAt[clusterEnd(chars, k, e) - a] = each
          let used = each * points.len.float32
          width += used
          extraPerSpace = if spaces > 0: max(0'f32, (room - used) / spaces.float32) else: 0'f32
      let lineW = width + extraPerSpace * spaces.float32
      var effAlign = if justify: textLeft
                     elif align == justifyLeft: textLeft
                     elif align == justifyCenter: textCenter
                     elif align == justifyRight: textRight
                     else: align
      if rtlPara:
        # (right to left: lines start at the right)
        effAlign = case effAlign
                   of textLeft: textRight
                   of textRight: textLeft
                   else: effAlign
      if boxed:
        startX = case effAlign
                 of textCenter: boxL + (boxR - boxL - lineW) / 2
                 of textRight: boxR - lineW
                 else: boxL
      else:
        startX = case effAlign
                 of textCenter: t.x - lineW / 2
                 of textRight: t.x - lineW - (if rtlPara: t.para.indentRight + firstInd else: 0'f32)
                 else: t.x + indent
      # the characters in the order shown
      var levels = newSeq[int8](b - a)
      for k in a ..< b: levels[k - a] = chars[k].level
      var order = visualOrderOf(levels)
      if order.len == 0:
        order = newSeq[int](b - a)
        for k in 0 ..< order.len: order[k] = k
      var x = startX
      for o in order:
        let k = a + o
        let c = chars[k]
        let st = styles[c.style]
        if c.cp == 10: continue
        var adv = c.adv
        if c.space and k < e: adv += extraPerSpace
        let kas = kashidaAt[k - a]
        adv += kas
        let rtlChar = (c.level and 1) == 1
        result.caretX[k] = if rtlChar: x + adv else: x
        result.caretLine[k] = lineNo
        if kas > 0:
          # the tatweel filling the join: at the letter's left (the next letter's side)
          let (tf, tg) = pickGlyph(c.face, 0x0640)
          let tadv = float32(tf.advance(tg)) / float32(tf.unitsPerEm) * c.size
          if tg != 0 and tadv > 0:
            result.glyphs.add LaidGlyph(face: tf, gid: tg, x: x - 0.4, y: penY - st.baselineShift, size: c.size,
                                        hScale: (kas + 0.8) / tadv * st.hScale / max(0.01'f32, st.hScale),
                                        vScale: st.vScale, color: st.color, index: k, adv: kas)
          x += kas
          adv -= kas
        if c.shaped:
          # (set by the font: each glyph where it says, from the pen)
          var y = penY - st.baselineShift
          if st.script == scSuper: y -= st.size * 0.333
          elif st.script == scSub: y += st.size * 0.15
          let fb = faces[c.style]
          var px = x
          for p in c.parts:
            if not c.space:
              result.glyphs.add LaidGlyph(face: c.face, gid: p.gid, x: px + p.dx, y: y - p.dy, size: c.size,
                                          hScale: st.hScale, vScale: st.vScale,
                                          embolden: (if st.fauxBold or fb.fauxBold: max(0.6'f32, c.size / 28) else: 0'f32),
                                          shear: (if st.fauxItalic or fb.fauxItalic: 0.21'f32 else: 0'f32),
                                          color: st.color, index: k, adv: p.adv)
            px += p.adv
        elif c.shown >= 0 and not c.space:
          var shown = c.shown
          if rtlChar: shown = mirrored(shown)
          let (f, g) = if shown != c.shown: pickGlyph(c.face, shown) else: (c.face, c.gid)
          var y = penY - st.baselineShift
          if st.script == scSuper: y -= st.size * 0.333
          elif st.script == scSub: y += st.size * 0.15
          let fb = faces[c.style]
          result.glyphs.add LaidGlyph(face: f, gid: g, x: x + c.markDx, y: y - c.markDy, size: c.size,
                                      hScale: st.hScale,
                                      vScale: st.vScale,
                                      embolden: (if st.fauxBold or fb.fauxBold: max(0.6'f32, c.size / 28) else: 0'f32),
                                      shear: (if st.fauxItalic or fb.fauxItalic: 0.21'f32 else: 0'f32),
                                      color: st.color, index: k, adv: adv)
        if (st.underline or st.strike) and k < e:
          let f = c.face
          let em = float32(f.unitsPerEm)
          let th = max(1'f32, float32(f.underlineThick) / em * c.size)
          if st.underline:
            let below = max(-float32(f.underlinePos) / em * c.size, c.size * 0.08'f32) + th / 2
            result.decorations.add Decoration(x0: x, x1: x + adv, y: penY + below, thick: th, color: st.color)
          if st.strike:
            result.decorations.add Decoration(x0: x, x1: x + adv, y: penY - c.size * 0.3, thick: th, color: st.color)
        x += adv
      result.lines.add LaidLine(baseline: penY, ascent: asc, descent: desc, x0: startX, x1: startX + lineW,
                                first: a, last: b, rtl: rtlPara)
      inc lineNo
    # the caret at the paragraph's end (before its new line, or the text's end)
    let ll = result.lines[^1]
    result.caretX[paraEnd] = if ll.rtl: ll.x0 else: ll.x1
    result.caretLine[paraEnd] = result.lines.high
    penY += t.para.spaceAfter
    if paraEnd >= total: break
    paraStart = paraEnd + 1
  # the bounds
  result.x0 = 1e9; result.y0 = 1e9; result.x1 = -1e9; result.y1 = -1e9
  for ln in result.lines:
    result.x0 = min(result.x0, ln.x0)
    result.x1 = max(result.x1, ln.x1)
    result.y0 = min(result.y0, ln.baseline - ln.ascent)
    result.y1 = max(result.y1, ln.baseline + ln.descent)
  if result.lines.len == 0:
    result.x0 = t.x; result.x1 = t.x; result.y0 = t.y; result.y1 = t.y

proc caretAt*(l: TextLayout; i: int): tuple[x, top, bottom: float32] =
  ## Where the caret before character `i` is drawn.
  if l.lines.len == 0: return (0'f32, 0'f32, 0'f32)
  let k = clamp(i, 0, l.caretX.high)
  let ln = l.lines[clamp(l.caretLine[k], 0, l.lines.high)]
  (l.caretX[k], ln.baseline - ln.ascent, ln.baseline + ln.descent)

proc charAt*(l: TextLayout; x, y: float32): int =
  ## The character a click at `x`, `y` puts the caret before.
  if l.lines.len == 0: return 0
  var li = 0
  var best = 1e9'f32
  for k, ln in l.lines:
    let d = if y < ln.baseline - ln.ascent: ln.baseline - ln.ascent - y
            elif y > ln.baseline + ln.descent: y - ln.baseline - ln.descent
            else: 0'f32
    if d < best:
      best = d
      li = k
  let ln = l.lines[li]
  result = ln.first
  var bd = 1e9'f32
  for k in ln.first .. min(ln.last, l.caretX.high):
    if k == ln.last and k < l.caretX.high and k > ln.first and l.caretLine[k] != li: continue
    let d = abs(l.caretX[k] - x)
    if d < bd:
      bd = d
      result = k

proc lineOf*(l: TextLayout; i: int): int =
  ## The line character `i` is on.
  if l.caretLine.len == 0: 0 else: l.caretLine[clamp(i, 0, l.caretLine.high)]

# ---- warps --------------------------------------------------------------------------------------------------

proc warpPoint*(w: TextWarp; u, v: float; aspect = 1.0): (float, float) =
  ## A point of the text's box (`u` across, `v` up, both -1..1) where the
  ## warp puts it; `aspect` is the box's height over its width.
  var u = u
  var v = v
  var aspect = aspect
  if w.vertical:
    swap(u, v)
    aspect = 1 / max(1e-6, aspect)
  let b = clamp(w.bend, -100, 100) / 100
  var x = u
  var y = v
  # (how far things bend up and down: more for long lines)
  let amp = clamp(0.6 / max(1e-6, aspect), 1.0, 3.0)
  case w.style
  of wsNone: discard
  of wsArc:
    if abs(b) > 0.001:
      # (in units of the half width: a half circle at 100%)
      let R = 1 / (abs(b) * PI / 2)
      let phi = u / R
      let sgn = if b > 0: 1.0 else: -1.0
      let r = R + v * aspect * sgn
      x = r * sin(phi)
      y = sgn * (r * cos(phi) - R) / aspect
  of wsArcLower:
    y = v + amp * b * (1 - u * u) * (1 - v) / 2 * 0.8
  of wsArcUpper:
    y = v + amp * b * (1 - u * u) * (1 + v) / 2 * 0.8
  of wsArch:
    y = v + amp * b * (1 - u * u) * 0.8
  of wsBulge:
    y = v * (1 + b * (1 - u * u) * 0.6)
  of wsShellLower:
    y = v + amp * b * u * u * (1 - v) / 2 * 0.8
  of wsShellUpper:
    y = v - amp * b * u * u * (1 + v) / 2 * 0.8
  of wsFlag:
    y = v + amp * b * 0.35 * sin(u * PI)
  of wsWave:
    y = v + amp * b * 0.35 * sin(u * PI * 1.5 + v * 0.6)
    x = u + b * 0.05 * cos(u * PI * 1.5)
  of wsFish:
    y = v * (1 + b * 0.6 * cos(u * PI / 2)) + b * 0.15 * u * v
  of wsRise:
    y = v + amp * b * 0.5 * sin(u * PI / 2)
  of wsFisheye:
    let r2 = min(1.0, (u * u + v * v) / 2)
    let k = 1 + b * (1 - r2) * 0.5
    x = u * k
    y = v * k
  of wsInflate:
    x = u * (1 + b * (1 - v * v) * 0.25)
    y = v * (1 + b * (1 - u * u) * 0.5)
  of wsSqueeze:
    x = u * (1 - b * (1 - v * v) * 0.3)
    y = v * (1 + b * (1 - u * u) * 0.3)
  of wsTwist:
    let a = b * u * PI / 3
    y = v * cos(a)
    x = u - v * sin(a) * 0.3
  # the perspective-like distortions
  let hd = clamp(w.hDistort, -100, 100) / 100
  let vd = clamp(w.vDistort, -100, 100) / 100
  if hd != 0: y *= 1 + hd * x * 0.5
  if vd != 0: x *= 1 + vd * y * 0.5
  if w.vertical: swap(x, y)
  (x, y)

# ---- drawing --------------------------------------------------------------------------------------------------

type PathPos = object
  pts: seq[(float32, float32)]
  acc: seq[float32]

proc pathPos(pts: seq[(float32, float32)]): PathPos =
  result.pts = pts
  result.acc = newSeq[float32](pts.len)
  for i in 1 ..< pts.len:
    result.acc[i] = result.acc[i - 1] + float32(hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]))

proc at(p: PathPos; s: float32): tuple[x, y, tx, ty: float32] =
  ## The point `s` along the path and its direction.
  if p.pts.len < 2: return (0'f32, 0'f32, 1'f32, 0'f32)
  var i = 1
  while i < p.pts.high and p.acc[i] < s: inc i
  let a = p.pts[i - 1]
  let b = p.pts[i]
  let l = max(1e-6'f32, p.acc[i] - p.acc[i - 1])
  let t = (s - p.acc[i - 1]) / l
  let dx = (b[0] - a[0]) / l
  let dy = (b[1] - a[1]) / l
  (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, dx, dy)

type DrawnBox* = tuple[x0, y0, x1, y1: int]
  ## The pixels a drawing touched (`x1`, `y1` past the last; empty when
  ## `x1` <= `x0`).

proc grow(b: var DrawnBox; x0, y0, x1, y1: int) =
  if x1 <= x0 or y1 <= y0: return
  if b.x1 <= b.x0: b = (x0, y0, x1, y1)
  else: b = (min(b.x0, x0), min(b.y0, y0), max(b.x1, x1), max(b.y1, y1))

proc fillPolys(px: var seq[uint32]; w, h: int; polys: seq[seq[(float32, float32)]]; color: uint32;
               embolden: float32; antialias: bool; box: var DrawnBox) =
  ## Closed polygons filled (nonzero, anti-aliased) in `color` over `px`
  ## (faux bold: widened by `embolden` pixels).
  var x0 = 1e9'f32
  var y0 = 1e9'f32
  var x1 = -1e9'f32
  var y1 = -1e9'f32
  for poly in polys:
    for (x, y) in poly:
      x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
  if x1 < x0: return
  let k = int(ceil(embolden))
  let kv = k div 2
  let ox = int(floor(x0)) - 1
  let oy = int(floor(y0)) - 1 - kv
  let rw = int(ceil(x1)) - ox + 2 + k
  let rh = int(ceil(y1)) - oy + 2
  if rw <= 0 or rh <= 0 or rw > 16384 or rh > 16384: return
  if ox + rw < 0 or oy + rh < 0 or ox >= w or oy >= h: return
  var r = newRaster(rw, rh)
  for poly in polys:
    for i in 0 ..< poly.len:
      let a = poly[i]
      let b = poly[(i + 1) mod poly.len]
      r.line(a[0] - ox.float32, a[1] - oy.float32, b[0] - ox.float32, b[1] - oy.float32)
  var cov = r.coverage()
  if k > 0:
    # (widened to the right and up: the letter's stems thicker)
    for y in 0 ..< rh:
      for x in countdown(rw - 1, 1):
        var m = cov[y * rw + x]
        for j in 1 .. min(k, x): m = max(m, cov[y * rw + x - j])
        cov[y * rw + x] = m
    if kv > 0:
      for x in 0 ..< rw:
        for y in 0 ..< rh - 1:
          var m = cov[y * rw + x]
          for j in 1 .. min(kv, rh - 1 - y): m = max(m, cov[(y + j) * rw + x])
          cov[y * rw + x] = m
  let ca = int(color shr 24)
  var bx0 = w
  var by0 = h
  var bx1 = -1
  var by1 = -1
  for y in 0 ..< rh:
    let yy = oy + y
    if yy < 0 or yy >= h: continue
    for x in 0 ..< rw:
      let xx = ox + x
      if xx < 0 or xx >= w: continue
      var a = int(cov[y * rw + x])
      if not antialias: a = if a >= 128: 255 else: 0
      if a == 0: continue
      a = a * ca div 255
      if a == 0: continue
      bx0 = min(bx0, xx); bx1 = max(bx1, xx); by0 = min(by0, yy); by1 = max(by1, yy)
      let i = yy * w + xx
      let d = px[i]
      let da = int(d shr 24)
      # (straight alpha, over)
      let oa = a + da * (255 - a) div 255
      if oa <= 0: continue
      template ch(sh: int): uint32 =
        uint32((int((color shr sh) and 255) * a + int((d shr sh) and 255) * da * (255 - a) div 255) div oa) shl sh
      px[i] = (uint32(oa) shl 24) or ch(16) or ch(8) or ch(0)
  box.grow(bx0, by0, bx1 + 1, by1 + 1)

var outlineCache: Table[(pointer, int, int), seq[seq[(float32, float32)]]]

proc outlineOf(f: Face; gid, steps: int): seq[seq[(float32, float32)]] =
  ## A glyph's contours (kept: text is drawn again on each key typed).
  let key = (cast[pointer](f), gid, steps)
  if outlineCache.hasKey(key): return outlineCache[key]
  if outlineCache.len > 6000: outlineCache.clear()
  result = f.contours(gid, steps)
  outlineCache[key] = result

proc glyphPolys(g: LaidGlyph; fine = false): seq[seq[(float32, float32)]] =
  ## The glyph's outline in picture pixels (y down), straight (`fine`:
  ## its curves in more pieces -- for print, at any size).
  let s = g.size / float32(g.face.unitsPerEm)
  let steps = if fine: clamp(int(g.size / 3), 6, 24) else: clamp(int(g.size / 10), 2, 10)
  for c in outlineOf(g.face, g.gid, steps):
    var poly = newSeqOfCap[(float32, float32)](c.len)
    for (fx, fy) in c:
      let ux = (fx + g.shear * fy) * s * g.hScale
      let uy = fy * s * g.vScale
      poly.add (g.x + ux, g.y - uy)
    result.add poly

proc onPath*(t: TextData): bool {.inline.} = t.path.len >= 2
  ## The text runs along a path.
proc warped*(t: TextData): bool {.inline.} = t.warp.style != wsNone and not t.onPath
  ## The text is warped (and not on a path).

proc pathLength*(t: TextData): float32 =
  ## How long the path the text runs along is.
  for i in 1 ..< t.path.len:
    result += float32(hypot(t.path[i][0] - t.path[i - 1][0], t.path[i][1] - t.path[i - 1][1]))

proc turned(t: TextData; x, y: float32): (float32, float32) {.inline.} =
  ## (vertical type: a point of the text set across, turned a quarter
  ## clockwise round its anchor)
  if not t.vertical: return (x, y)
  (t.x - (y - t.y), t.y + (x - t.x))

proc unturned(t: TextData; x, y: float32): (float32, float32) {.inline.} =
  if not t.vertical: return (x, y)
  (t.x + (y - t.y), t.y - (x - t.x))

proc placePoint*(t: TextData; l: TextLayout; x, y: float32): (float32, float32) =
  ## Where a point of the straight layout is drawn (warped, along the path,
  ## or turned for vertical type).
  if t.vertical and not t.onPath:
    if not t.warped: return t.turned(x, y)
    let cx = (l.x0 + l.x1) / 2
    let cy = (l.y0 + l.y1) / 2
    let hw = max(1'f32, (l.x1 - l.x0) / 2)
    let hh = max(1'f32, (l.y1 - l.y0) / 2)
    let (u, v) = t.warp.warpPoint(float((x - cx) / hw), float(-(y - cy) / hh), float(hh / hw))
    return t.turned(float32(cx + u * hw), float32(cy - v * hh))
  if t.onPath:
    if l.lines.len == 0: return (x, y)
    let pp = pathPos(t.path)
    let (px, py, tx, ty) = pp.at(t.pathOffset + (x - t.x))
    let ly = l.lines[0].baseline - y
    return (px + ly * ty, py - ly * tx)
  if not t.warped: return (x, y)
  let cx = (l.x0 + l.x1) / 2
  let cy = (l.y0 + l.y1) / 2
  let hw = max(1'f32, (l.x1 - l.x0) / 2)
  let hh = max(1'f32, (l.y1 - l.y0) / 2)
  let (u, v) = t.warp.warpPoint(float((x - cx) / hw), float(-(y - cy) / hh), float(hh / hw))
  (float32(cx + u * hw), float32(cy - v * hh))

type TextOutline* = object
  ## A piece of drawn text as outlines: closed polygons (picture pixels, y
  ## down) filled nonzero in `color`, widened by `embolden` (faux bold).
  polys*: seq[seq[(float32, float32)]]  ## the closed polygons
  color*: uint32                        ## ARGB
  embolden*: float32                    ## pixels to widen them by (0: none)

proc textOutlines*(t: TextData; layout: TextLayout; fine = false): seq[TextOutline] =
  ## The text as outlines, placed as it is drawn (on its path, warped,
  ## vertical): its glyphs, then its underlines and strike-throughs. `fine`:
  ## curves in more pieces (vectors for print).
  let l = layout
  let warped = t.warped
  let onPath = t.onPath
  let pp = if onPath: pathPos(t.path) else: PathPos()
  let total = if onPath: pp.acc[^1] else: 0'f32
  let base0 = if l.lines.len > 0: l.lines[0].baseline else: t.y
  for g in l.glyphs:
    var polys = glyphPolys(g, fine)
    if onPath:
      # the glyph turned to follow the path at its middle (gone past its ends)
      let s = t.pathOffset + (g.x - t.x) + g.adv / 2
      if s < 0 or s > total: continue
      let (px, py, tx, ty) = pp.at(s)
      for poly in polys.mitems:
        for p in poly.mitems:
          let lx = p[0] - (g.x + g.adv / 2)
          let ly = base0 - p[1]                # up from the first baseline
          p = (px + lx * tx + ly * ty, py + lx * ty - ly * tx)
    elif t.vertical and not warped:
      for poly in polys.mitems:
        for p in poly.mitems: p = t.turned(p[0], p[1])
    elif warped:
      # (long straight edges cut so they bend)
      var cut: seq[seq[(float32, float32)]]
      for poly in polys:
        var np: seq[(float32, float32)]
        for i in 0 ..< poly.len:
          let a = poly[i]
          let b = poly[(i + 1) mod poly.len]
          let n = max(1, int(hypot(b[0] - a[0], b[1] - a[1]) / 4))
          for k in 0 ..< n:
            let tt = k.float32 / n.float32
            np.add t.placePoint(l, a[0] + (b[0] - a[0]) * tt, a[1] + (b[1] - a[1]) * tt)
        cut.add np
      polys = cut
    result.add TextOutline(polys: polys, color: g.color, embolden: g.embolden)
  for dcr in l.decorations:
    if onPath: continue
    var poly: seq[(float32, float32)]
    let n = if warped: max(1, int((dcr.x1 - dcr.x0) / 4)) else: 1
    let top = dcr.y - dcr.thick / 2
    let bot = dcr.y + dcr.thick / 2
    for k in 0 .. n: poly.add t.placePoint(l, dcr.x0 + (dcr.x1 - dcr.x0) * k.float32 / n.float32, top)
    for k in countdown(n, 0): poly.add t.placePoint(l, dcr.x0 + (dcr.x1 - dcr.x0) * k.float32 / n.float32, bot)
    result.add TextOutline(polys: @[poly], color: dcr.color)

proc renderTextInto*(t: TextData; px: var seq[uint32]; w, h: int; layout: TextLayout): DrawnBox =
  ## The text drawn over `px` (`w` x `h`, straight ARGB); the pixels it
  ## touched.
  for o in textOutlines(t, layout):
    fillPolys(px, w, h, o.polys, o.color, o.embolden, t.antialias, result)

proc renderText*(t: TextData; w, h: int; layout: TextLayout): seq[uint32] =
  ## The text drawn on a transparent picture `w` x `h` (straight ARGB).
  result = newSeq[uint32](w * h)
  discard t.renderTextInto(result, w, h, layout)

proc renderText*(t: TextData; w, h: int): seq[uint32] =
  ## The text laid out and drawn on a transparent picture `w` x `h`.
  t.renderText(w, h, layoutText(t))

# ---- hit testing on what is drawn ---------------------------------------------------------------------------

proc caretLine*(t: TextData; l: TextLayout; i: int): tuple[x0, y0, x1, y1: float32] =
  ## The caret before character `i` as drawn: a line from its top to its
  ## bottom (slanted on warped text and on a path).
  let c = l.caretAt(i)
  let (ax, ay) = t.placePoint(l, c.x, c.top)
  let (bx, by) = t.placePoint(l, c.x, c.bottom)
  (ax, ay, bx, by)

proc charAtDrawn*(t: TextData; l: TextLayout; x, y: float32): int =
  ## The character a click at `x`, `y` (on the text as drawn) puts the
  ## caret before.
  if t.vertical and not t.warped and not t.onPath:
    let (ux, uy) = t.unturned(x, y)
    return l.charAt(ux, uy)
  if not t.warped and not t.onPath: return l.charAt(x, y)
  var best = 1e18'f32
  result = 0
  for i in 0 .. l.caretX.high:
    let c = l.caretAt(i)
    let (mx, my) = t.placePoint(l, c.x, (c.top + c.bottom) / 2)
    let d = (mx - x) * (mx - x) + (my - y) * (my - y)
    if d < best:
      best = d
      result = i

proc drawnBounds*(t: TextData; l: TextLayout): tuple[x0, y0, x1, y1: float32] =
  ## The box around the text as drawn (roughly, from its lines' corners and
  ## sides).
  if t.vertical and not t.warped and not t.onPath:
    var x0, y0 = 1e18'f32
    var x1, y1 = -1e18'f32
    for (px, py) in [(l.x0, l.y0), (l.x1, l.y0), (l.x1, l.y1), (l.x0, l.y1)]:
      let (qx, qy) = t.turned(px, py)
      x0 = min(x0, qx); y0 = min(y0, qy); x1 = max(x1, qx); y1 = max(y1, qy)
    return (x0, y0, x1, y1)
  if not t.warped and not t.onPath: return (l.x0, l.y0, l.x1, l.y1)
  result = (1e9'f32, 1e9'f32, -1e9'f32, -1e9'f32)
  for ln in l.lines:
    for k in 0 .. 16:
      let x = ln.x0 + (ln.x1 - ln.x0) * k.float32 / 16
      for y in [ln.baseline - ln.ascent, ln.baseline + ln.descent]:
        let (px, py) = t.placePoint(l, x, y)
        result = (min(result.x0, px), min(result.y0, py), max(result.x1, px), max(result.y1, py))
  if result.x1 < result.x0: result = (l.x0, l.y0, l.x1, l.y1)

# ---- moving the caret ---------------------------------------------------------------------------------------

proc isWordChar(cp: int): bool =
  cp >= int('0') and cp <= int('9') or cp >= int('A') and cp <= int('Z') or
    cp >= int('a') and cp <= int('z') or cp == int('_') or cp >= 0xC0

proc wordLeft*(t: TextData; i: int): int =
  ## The start of the word before character `i`.
  let r = t.plainText.toRunes
  var k = clamp(i, 0, r.len)
  while k > 0 and not isWordChar(int(r[k - 1])): dec k
  while k > 0 and isWordChar(int(r[k - 1])): dec k
  k

proc wordRight*(t: TextData; i: int): int =
  ## The end of the word at or after character `i`.
  let r = t.plainText.toRunes
  var k = clamp(i, 0, r.len)
  while k < r.len and not isWordChar(int(r[k])): inc k
  while k < r.len and isWordChar(int(r[k])): inc k
  k

proc lineStart*(l: TextLayout; i: int): int =
  ## The start of the line of character `i`.
  if l.lines.len == 0: return 0
  l.lines[clamp(l.lineOf(i), 0, l.lines.high)].first

proc lineEnd*(l: TextLayout; i: int; total: int): int =
  ## The end of the line of character `i` (before its new line, or its
  ## trailing space when it wraps).
  if l.lines.len == 0: return total
  let ln = l.lines[clamp(l.lineOf(i), 0, l.lines.high)]
  result = ln.last
  if result > ln.first and result <= total:
    let k = clamp(l.lineOf(i), 0, l.lines.high)
    if k < l.lines.high: result = max(ln.first, ln.last - 1)

proc lineMove*(l: TextLayout; i, by: int): int =
  ## The character above (`by` < 0) or below the caret at `i`.
  if l.lines.len == 0: return i
  let li = l.lineOf(i)
  let t = clamp(li + by, 0, l.lines.high)
  if t == li: return (if by < 0: l.lines[0].first else: l.caretX.high)
  let x = l.caretX[clamp(i, 0, l.caretX.high)]
  let ln = l.lines[t]
  l.charAt(x, ln.baseline)

# ---- changing it whole --------------------------------------------------------------------------------------

proc scaled*(t: TextData; k: float32): TextData =
  ## The text `k` times as big, its place too (Image Size).
  result = t
  result.x *= k; result.y *= k
  result.boxW *= k; result.boxH *= k
  result.pathOffset *= k
  for p in result.path.mitems: p = (p[0] * k, p[1] * k)
  result.para.indentLeft *= k; result.para.indentRight *= k; result.para.indentFirst *= k
  result.para.spaceBefore *= k; result.para.spaceAfter *= k
  for s in result.spans.mitems:
    s.style.size *= k
    s.style.leading *= k
    s.style.baselineShift *= k

proc moved*(t: TextData; dx, dy: float32): TextData =
  ## The text `dx`, `dy` further (Crop, Canvas Size, the Move tool).
  result = t
  result.x += dx; result.y += dy
  for p in result.path.mitems: p = (p[0] + dx, p[1] + dy)

proc layerName*(t: TextData): string =
  ## A layer's name from its text (its first words).
  result = ""         # (a value at once: see tools/writecheck.py)
  for r in t.plainText.runes:
    if result.runeLen >= 30: break
    result.add(if int(r) == 10 or int(r) == 9: " " else: r.toUTF8)
  result = result.strip
  if result.len == 0: result = "Text"

# ---- saving ------------------------------------------------------------------------------------------------

proc toJson*(st: CharStyle): JsonNode =
  ## A character style as JSON (what is at its default left out).
  result = %*{"family": st.family, "style": st.style, "size": st.size, "color": int64(st.color)}
  let d = CharStyle()
  if st.tracking != 0: result["tracking"] = %st.tracking
  if st.noKerning: result["noKerning"] = %true
  if st.leading != 0: result["leading"] = %st.leading
  if st.baselineShift != 0: result["baselineShift"] = %st.baselineShift
  if st.hScale != 0 and st.hScale != 1: result["hScale"] = %st.hScale
  if st.vScale != 0 and st.vScale != 1: result["vScale"] = %st.vScale
  for (name, v) in [("fauxBold", st.fauxBold), ("fauxItalic", st.fauxItalic), ("allCaps", st.allCaps),
                    ("smallCaps", st.smallCaps), ("underline", st.underline), ("strike", st.strike)]:
    if v: result[name] = %true
  if st.script != d.script: result["script"] = %($st.script)
  if st.digits != 0: result["digits"] = %st.digits
  if st.features.len > 0: result["features"] = %st.features
  if st.variation.len > 0: result["variation"] = %st.variation
  if st.styleName.len > 0: result["styleName"] = %st.styleName

proc getF(j: JsonNode; k: string; d = 0.0): float =
  if j != nil and j.hasKey(k) and j[k].kind in {JInt, JFloat}: j[k].getFloat else: d

proc getB(j: JsonNode; k: string): bool =
  j != nil and j.hasKey(k) and j[k].kind == JBool and j[k].getBool

proc getS(j: JsonNode; k: string; d = ""): string =
  if j != nil and j.hasKey(k) and j[k].kind == JString: j[k].getStr else: d

proc enumOf[T: enum](s: string; d: T): T =
  for e in T:
    if $e == s: return e
  d

proc charStyleFrom*(j: JsonNode): CharStyle =
  ## A character style from its JSON (`toJson`); what is missing keeps
  ## its default.
  result = defaultStyle()
  if j == nil or j.kind != JObject: return
  result.family = j.getS("family", result.family)
  result.style = j.getS("style", result.style)
  result.size = float32(j.getF("size", result.size))
  result.color = uint32(int64(j.getF("color", float(result.color))) and 0xFFFFFFFF'i64)
  result.tracking = int(j.getF("tracking"))
  result.noKerning = j.getB("noKerning")
  result.leading = float32(j.getF("leading"))
  result.baselineShift = float32(j.getF("baselineShift"))
  result.hScale = float32(j.getF("hScale", 1))
  result.vScale = float32(j.getF("vScale", 1))
  result.fauxBold = j.getB("fauxBold"); result.fauxItalic = j.getB("fauxItalic")
  result.allCaps = j.getB("allCaps"); result.smallCaps = j.getB("smallCaps")
  result.underline = j.getB("underline"); result.strike = j.getB("strike")
  result.script = enumOf(j.getS("script"), scNormal)
  result.digits = int(j.getF("digits"))
  result.features = j.getS("features")
  result.variation = j.getS("variation")
  result.styleName = j.getS("styleName")

proc toJson*(t: TextData): JsonNode =
  ## The text as JSON (saved in a document).
  var spans = newJArray()
  for s in t.spans: spans.add %*{"text": s.text, "style": s.style.toJson}
  result = %*{"spans": spans, "x": t.x, "y": t.y, "antialias": t.antialias,
              "para": {"align": $t.para.align, "indentLeft": t.para.indentLeft,
                       "indentRight": t.para.indentRight, "indentFirst": t.para.indentFirst,
                       "spaceBefore": t.para.spaceBefore, "spaceAfter": t.para.spaceAfter,
                       "rtl": t.para.rtl, "noKashida": t.para.noKashida, "kashida": $t.para.kashida}}
  if t.para.styleName.len > 0: result["para"]["styleName"] = %t.para.styleName
  if t.boxW > 0:
    result["boxW"] = %t.boxW
    result["boxH"] = %t.boxH
  if t.vertical: result["vertical"] = %true
  if t.fit: result["fit"] = %true
  if t.columns > 1: result["columns"] = %t.columns
  if t.gutter > 0: result["gutter"] = %t.gutter
  if t.clipOverflow: result["clipOverflow"] = %true
  if t.warp.style != wsNone:
    result["warp"] = %*{"style": $t.warp.style, "bend": t.warp.bend, "hDistort": t.warp.hDistort,
                        "vDistort": t.warp.vDistort, "vertical": t.warp.vertical}
  if t.path.len > 0:
    var p = newJArray()
    for (x, y) in t.path:
      p.add %x
      p.add %y
    result["path"] = p
    result["pathOffset"] = %t.pathOffset

proc textFrom*(j: JsonNode): TextData =
  ## A text saved with `toJson`.
  result.antialias = true
  if j == nil or j.kind != JObject: return
  if j.hasKey("spans") and j["spans"].kind == JArray:
    for s in j["spans"]:
      result.spans.add TextSpan(text: s.getS("text"), style: charStyleFrom(if s.hasKey("style"): s["style"] else: nil))
  if result.spans.len == 0: result.spans.add TextSpan(text: "", style: defaultStyle())
  result.x = float32(j.getF("x")); result.y = float32(j.getF("y"))
  result.antialias = not j.hasKey("antialias") or j.getB("antialias")
  result.boxW = float32(j.getF("boxW")); result.boxH = float32(j.getF("boxH"))
  result.vertical = j.getB("vertical")
  result.fit = j.getB("fit")
  result.columns = j{"columns"}.getInt(0)
  result.gutter = j{"gutter"}.getFloat(0).float32
  result.clipOverflow = j.getB("clipOverflow")
  if j.hasKey("para"):
    let p = j["para"]
    result.para.align = enumOf(p.getS("align"), textLeft)
    result.para.indentLeft = float32(p.getF("indentLeft"))
    result.para.indentRight = float32(p.getF("indentRight"))
    result.para.indentFirst = float32(p.getF("indentFirst"))
    result.para.spaceBefore = float32(p.getF("spaceBefore"))
    result.para.styleName = p.getS("styleName")
    result.para.spaceAfter = float32(p.getF("spaceAfter"))
    result.para.rtl = int(p.getF("rtl"))
    result.para.noKashida = p.getB("noKashida")
    result.para.kashida = enumOf(p.getS("kashida"), kaMedium)
  if j.hasKey("warp"):
    let w = j["warp"]
    result.warp = TextWarp(style: enumOf(w.getS("style"), wsNone), bend: int(w.getF("bend")),
                           hDistort: int(w.getF("hDistort")), vDistort: int(w.getF("vDistort")),
                           vertical: w.getB("vertical"))
  if j.hasKey("path") and j["path"].kind == JArray:
    let p = j["path"]
    var k = 0
    while k + 1 < p.len:
      result.path.add (float32(p[k].getFloat), float32(p[k + 1].getFloat))
      k += 2
    result.pathOffset = float32(j.getF("pathOffset"))

proc runeCount*(s: string): int =
  ## How many characters (not bytes) `s` holds.
  for c in s:
    if (ord(c) and 0xC0) != 0x80: inc result

proc textSlice*(t: TextData; a, b: int): string =
  ## Characters `a` ..< `b` of what the text says.
  let r = t.plainText.toRunes
  $r[clamp(a, 0, r.len) ..< clamp(b, 0, r.len)]

proc paraToJson*(p: ParaStyle): JsonNode =
  ## A paragraph style as JSON (Paragraph Styles kept in a document).
  %*{"align": $p.align, "indentLeft": p.indentLeft, "indentRight": p.indentRight,
     "indentFirst": p.indentFirst, "spaceBefore": p.spaceBefore, "spaceAfter": p.spaceAfter,
     "rtl": p.rtl, "noKashida": p.noKashida, "kashida": $p.kashida, "styleName": p.styleName}

proc paraFrom*(j: JsonNode): ParaStyle =
  ## A paragraph style from its JSON (`paraToJson`).
  if j == nil or j.kind != JObject: return
  result.align = enumOf(j.getS("align"), textLeft)
  result.indentLeft = float32(j.getF("indentLeft"))
  result.indentRight = float32(j.getF("indentRight"))
  result.indentFirst = float32(j.getF("indentFirst"))
  result.spaceBefore = float32(j.getF("spaceBefore"))
  result.spaceAfter = float32(j.getF("spaceAfter"))
  result.rtl = int(j.getF("rtl"))
  result.noKashida = j.getB("noKashida")
  result.kashida = enumOf(j.getS("kashida"), kaMedium)
  result.styleName = j.getS("styleName")

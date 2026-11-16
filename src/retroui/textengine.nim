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
import ttf, typeset, raster, otshape, unpacking, hyphenate

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

when compileOption("threads"):
  let engineThread = getThreadId()

proc typeWorker*(): bool {.inline.} =
  ## This is not the thread the type engine was started on (the one that
  ## draws) but a worker -- a picture decoded in the background. Text is
  ## set there too (`layoutText`, `textOutlines`), in the program's own
  ## three families alone: FreeSans, FreeSerif and FreeMono, each parsed
  ## again for that thread (faces are not shared between threads). The
  ## system's fonts and those an app carries are the first thread's:
  ## `fontFamilies`, `fontStyles`, `scanFonts` and `addFontData` are to be
  ## called there.
  when compileOption("threads"): getThreadId() != engineThread
  else: false

var workerFaces {.threadvar.}: Table[int, Face]
var outlineCache {.threadvar.}: Table[(pointer, int, int), seq[seq[(float32, float32)]]]
  # (each thread its own: a worker's faces are its own too)

when compileOption("threads"):
  var letGoAtEnd {.threadvar.}: bool

proc workerCaches() =
  ## (a worker's faces and glyph outlines let go when its thread ends: a
  ## thread's own variables are not)
  when compileOption("threads"):
    if letGoAtEnd or not typeWorker(): return
    letGoAtEnd = true
    onThreadDestruction(proc () {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        reset(workerFaces)
        reset(outlineCache))

proc ownFace(id: FaceId): Face =
  ## (a face of the program's for this thread: the one all drawing shares
  ## on the first, one parsed for the thread on a worker)
  if not typeWorker(): return face(id)
  if not workerFaces.hasKey(ord(id)):
    workerCaches()
    workerFaces[ord(id)] = threadFace(id)
  workerFaces[ord(id)]

var memFonts: seq[tuple[entry: FontEntry; ticket: int; face: Face]]
  ## (a packed one: unpacked on a thread from when it is offered, `unpacking`)
  ## Fonts an app (or a module) carries in itself (`addFontData`).

proc addFontData*(family, style: string; data: string; packed = false; weight = 400; italic = false) =
  ## Offers a font the program carries -- its bytes (`packed`: zlib or
  ## LZMA compressed, as `staticRead` of a ".ttf.z", unpacked on a thread
  ## from now) -- as `family` / `style`, read the first time it is drawn. Again
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

proc fontFileOf*(family, style: string): string =
  ## The file a family's style is read from ("" built in, or not found) -- File > Package
  ## copies it.
  scanFonts()
  var any = ""
  for e in catalog:
    if e.family != family or e.path.len == 0 or e.path.startsWith("<"): continue
    if e.style == style: return e.path
    if any.len == 0: any = e.path
  any

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
  if typeWorker():
    # (on a worker thread: the program's own families, a face of the thread's own)
    let low = family.toLowerAscii
    let sl = style.toLowerAscii
    let base = if "serif" in low and "sans" notin low: fSerif elif "mono" in low: fMono else: fSans
    let id = styled(base, "bold" in sl or "black" in sl or "heavy" in sl, "italic" in sl or "oblique" in sl)
    return (ownFace(id), fauxStyle(id).bold, fauxStyle(id).italic)
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

  ScriptFont* = object
    ## A font of its own for the letters of one script in a text -- its
    ## Arabic, or its Latin (English) -- and the spaces, digits and marks
    ## between them: as Arabic and English are set together.
    family*: string            ## "" the text's own font
    style*: string             ## "" the text's own style ("Bold", "Regular"...)
    scale*: float32            ## its size times this (0: 1) -- an Arabic font often wants 110 %
    shift*: float32            ## its baseline raised by so many pixels (negative: lowered)
    color*: uint32             ## its color, ARGB (0: the text's)
    tracking*: int             ## more (less) room between its letters, thousandths of an em

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
    wordSpace*: int            ## thousandths of an em more (less: negative) between words
    markColor*: uint32         ## the marks over and under letters (Arabic tashkeel, accents set
                               ## as marks) in a color of their own, ARGB (0: the letters')
    markRaise*: float32        ## ... raised by this many pixels from where the font puts them
                               ## (negative: lowered)
    noMarks*: bool             ## ... not drawn (Arabic without its tashkeel)
    styleName*: string         ## the Character Style it has (Character Styles; "" none)
    arabicFont*: ScriptFont    ## its Arabic letters in a font of their own ("" family: the text's)
    latinFont*: ScriptFont     ## its Latin (English) letters in a font of their own
    para*: int                 ## the format of the paragraph it is in: 0 the text's own (`para`),
                               ## else `TextData.paraFmts[para - 1]` (a paragraph's first letter says)
    link*: string              ## a hyperlink: a web or mail address ("https://...", "mailto:..."),
                               ## "#name" a destination's, "page:N" the book's page N; "=name": the
                               ## text is the destination "name" (cross-references go to it)

  NumberStyle* = enum
    ## How numbers are written: a list's, a book's page numbers.
    nsDigits = "1, 2, 3", nsArabicIndic = "١, ٢, ٣", nsPersian = "۱, ۲, ۳", nsRomanLower = "i, ii, iii",
    nsRomanUpper = "I, II, III", nsLetterLower = "a, b, c", nsLetterUpper = "A, B, C", nsAbjad = "أ, ب, ج"
  ListKind* = enum
    ## A list's marks.
    lkNone = "None", lkBullet = "Bullets", lkNumber = "Numbers"
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
    list*: ListKind            ## text in a box as a list: a mark before every paragraph, its lines
                               ## standing in from it (at the right for right-to-left text)
    listMark*: string          ## `lkBullet`: the mark -- any letters the font has: "–", "▪", "◆",
                               ## "★", "✓" ("": a bullet, "•")
    listNumbers*: NumberStyle  ## `lkNumber`: how its numbers are written (digits, Arabic-Indic,
                               ## Persian, Roman, letters, abjad)
    listStart*: int            ## ... its first number (0: 1)
    listSuffix*: string        ## ... what follows a number: ")", "-" ("": a period)
    listColor*: uint32         ## the marks' color, ARGB (0: the text's)
    listIndent*: float32       ## how far the text stands in from the marks' edge, in pixels (0:
                               ## by the type's size)
    dropLines*: int            ## text in a box: a drop cap -- its first letters as tall as so many
                               ## lines (2 and more), the lines beside them standing in (0: none)
    dropChars*: int            ## ... how many letters (0: one)
    hyphenate*: bool           ## text in a box: an English word that does not fit at a line's end
                               ## broken where it may be, with a hyphen (`retroui/hyphenate`)
    gridAlign*: bool           ## its lines on the page's baseline grid (a paragraph style that says
                               ## so: whoever applies it sets the text's `gridStep`, `gridStart`)
    composer*: Composer        ## how its lines are broken (the Paragraph Composer weighs the whole
                               ## paragraph: even spacing, fewer rivers; the Single-line, a line at a time)
    wordSpacing*: array[3, int16]   ## justified: its spaces' least, wanted and most widths, % of their
                                    ## own ([0, 0, 0]: 80, 100, 133, as the layout program sets them)
    letterSpacing*: array[3, int16] ## ... room between its letters, least, wanted, most, % of a space
    glyphScaling*: array[3, int16]  ## ... its letters made narrower or wider, % ([0, 0, 0]: 100, 100, 100)
    keepWithNext*: int         ## so many lines of the next paragraph in the same column as its end
    keepTogether*: bool        ## all its lines in one column
    keepStart*, keepEnd*: int  ## at least so many lines at its start (orphans) and its end (widows)
                               ## together in a column (0: one)
    startAt*: ParaStart        ## where it starts: anywhere, the next column, the next frame or page
    spanAll*: bool             ## text in columns: it goes across them all (a heading over them)
    splitColumns*: int         ## split into so many columns of its own within its column (2 and more)
    nextStyle*: string         ## the Paragraph Style a paragraph typed after it takes ("" its own)
    nested*: seq[NestedStyle]  ## character styles through the start of it, one after another
    grepStyles*: seq[GrepStyle]  ## character styles wherever a pattern matches in it

  Composer* = enum
    ## How a paragraph's lines are broken.
    cpAuto = "Auto",                   ## the Paragraph Composer for justified text, else Single-line
    cpParagraph = "Paragraph Composer", ## the whole paragraph weighed: its spaces as even as they can be
    cpSingle = "Single-line Composer"   ## a line at a time, as many words as fit

  ParaStart* = enum
    ## Where a paragraph starts (Keep Options).
    psAnywhere = "Anywhere", psNextColumn = "In Next Column", psNextFrame = "In Next Frame",
    psNextPage = "On Next Page"

  NestedUnit* = enum
    ## How far a nested style goes.
    nuWords = "Words", nuChars = "Characters", nuSentences = "Sentences", nuUpTo = "Up To"

  NestedStyle* = object
    ## A character style through the start of a paragraph (Drop Caps and Nested Styles): `count`
    ## words, characters, sentences -- or up to the `count`th `upTo` (`through`: it too).
    name*: string               ## the character style's name ("": [None], the text as it is up to there)
    look*: CharStyle            ## ... how it looks
    count*: int                 ## (0: 1)
    unit*: NestedUnit
    upTo*: string               ## `nuUpTo`: the character
    through*: bool

  GrepStyle* = object
    ## A character style wherever `pattern` (a GREP pattern: `retroui/textsearch`) matches.
    name*: string               ## the character style's name ("": none, the pattern does nothing)
    look*: CharStyle
    pattern*: string

  VertJust* = enum
    ## Where a box's lines are put up and down (Text Frame Options).
    vjTop = "Top", vjCenter = "Center", vjBottom = "Bottom", vjJustify = "Justify"

  KashidaLength* = enum
    ## How much justified Arabic is lengthened at its joins (tatweel) -- one
    ## join a word, where a scribe would put it -- before its spaces.
    kaMedium = "Medium", kaNone = "None", kaShort = "Short", kaLong = "Long", kaStylistic = "Stylistic"

  NoteKind* = enum
    ## Where a text's notes are set.
    nkFootnotes = "Footnotes",   ## at the foot of the box their references are in
    nkEndnotes = "Endnotes"      ## after the text's end, under a heading

  Footnote* = object
    ## A note: its reference in the text is the character `noteMark(id)`.
    id*: int                     ## (1..65533)
    text*: string                ## what it says ("\n": a paragraph of it)

  NoteOptions* = object
    ## How a text's notes are numbered and set (Footnote Options).
    kind*: NoteKind
    numbers*: NumberStyle        ## 1, 2, 3; ١, ٢, ٣; i, ii; a, b; أ, ب, ج
    start*: int                  ## the first number (0: 1)
    prefix*, suffix*: string     ## round the reference in the text ("[", "]")
    separator*: string           ## between a note's number and its text ("": ". ")
    scale*: float32              ## the notes' size, a share of the text's (0: 0.8)
    refScale*: float32           ## the reference's size, a share of its text's (0: 0.6), raised
    noRule*: bool                ## no line above the footnotes
    ruleWidth*: float32          ## the line's thickness, pixels (0: 1)
    ruleLength*: float32         ## its length, a share of the box's width (0: 0.33)
    ruleColor*: uint32           ## its color, ARGB (0: the text's)
    gap*: float32                ## the room above the notes, pixels (0: half the text's size)
    heading*: string             ## the endnotes' heading ("": "Notes", "الحواشي" for Arabic)

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

  TextAutoSize* = enum
    ## How a text box follows its text (Text Frame Options > Auto-Size, as the layout program's).
    asOff = "Off", asHeight = "Height Only", asWidth = "Width Only", asBoth = "Height and Width",
    asProportional = "Height and Width (Keep Proportions)"

  TextWarp* = object
    ## How a text is bent (Warp Text).
    style*: WarpStyle          ## the shape (`wsNone`: not bent)
    bend*: int                 ## -100..100
    hDistort*, vDistort*: int  ## -100..100
    vertical*: bool            ## bent up and down instead of across

  TableStyle* = object
    ## Text in a box as a table: each paragraph a row, tabs between its
    ## cells, each cell's text set in its column; the look of a theme
    ## (`tableThemes`) or one's own.
    on*: bool                  ## the text is a table
    headerRows*: int           ## the first rows a header
    headerFill*: uint32        ## ... their fill, ARGB (0: none)
    headerColor*: uint32       ## ... their text's color (0: as typed)
    headerBold*: bool          ## ... their text made bold (faux bold where the font has none)
    bodyColor*: uint32         ## the other rows' text color (0: as typed)
    fill*: uint32              ## the rows' fill (0: none)
    altFill*: uint32           ## every other row's (0: as `fill`): stripes
    border*: uint32            ## the lines' color (0: no lines)
    borderW*: float32          ## ... their width in pixels (0: 1)
    inner*: bool               ## lines between all the cells (else round the table and under the header)
    rowLines*: bool            ## lines between the rows only (with `inner` false)
    pad*: float32              ## room inside a cell, pixels (0: a third of the type's size)
    widths*: seq[float32]      ## the columns' widths, as parts of the box (empty: even)
    numbersRight*: bool        ## a cell that is a number set at its right
    theme*: string             ## the theme it came from ("" its own)

  TextHole* = tuple[x0, y0, x1, y1: float32]
    ## A rectangle a text's lines keep out of (`TextData.holes`).

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
    gridStep*, gridStart*: float32  ## text in a box: its baselines on a grid of lines `gridStep`
                               ## apart from `gridStart` (y) -- each line on the next one down
                               ## (Align to Baseline Grid; 0: as the leading puts them)
    table*: TableStyle         ## text in a box: a table (each paragraph a row, tabs between cells)
    notes*: seq[Footnote]      ## its footnotes or endnotes, in the order of their references
                               ## (`insertNote`, `tidyNotes`); a box it flows on into keeps them all
    noteOpts*: NoteOptions     ## how they are numbered and set
    autoSize*: TextAutoSize    ## text in a box: the box made as big as its text (`autoSized`)...
    autoRef*: int              ## ... from this point of it, staying where it is: 0 top left, 1 top
                               ## middle, 2 top right, 3 left middle ... 8 bottom right
    paraFmts*: seq[ParaStyle]  ## the paragraphs' formats other than `para` (`CharStyle.para`)
    tailFmt*: int              ## an empty paragraph at the end: its format's number, as
                               ## `CharStyle.para`, + 1 (0: the paragraph before's)
    inset*: array[4, float32]  ## text in a box: room kept inside it, top, right, bottom, left (Inset
                               ## Spacing)
    vjust*: VertJust           ## ... where its lines stand up and down
    balance*: bool             ## ... its columns made as even as they can be
    spanW: float32             # (laid out in columns: the box's whole width, for a paragraph across them)
    holes*: seq[TextHole]      ## text in a box: places its lines keep out of (what the text is
                               ## wrapped round: `x`, `y`'s own coordinates). A line takes the
                               ## widest room a hole leaves it, and goes under the hole when
                               ## that is too little. Not kept with the text: whoever lays it
                               ## out says what is in its way then

proc roman(n: int): string =
  const parts = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"), (50, "l"),
                 (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
  var n = n
  for (v, s) in parts:
    while n >= v:
      result.add s
      n -= v

proc formatNumber*(n: int; style: NumberStyle): string =
  ## A page number written in a style: 7 is "7", "٧", "vii", "g"... (Roman
  ## numerals and letters from 1 on; below 1, and Roman above 3999: digits.)
  const abjad = ["أ", "ب", "ج", "د", "ه", "و", "ز", "ح", "ط", "ي", "ك", "ل", "م", "ن", "س", "ع", "ف", "ص",
                 "ق", "ر", "ش", "ت", "ث", "خ", "ذ", "ض", "ظ", "غ"]
  # (what counts from 1 -- and Roman numerals, to 3999 -- written as digits past that)
  let asDigits = style in {nsRomanLower, nsRomanUpper, nsLetterLower, nsLetterUpper, nsAbjad} and
                 (n < 1 or (style in {nsRomanLower, nsRomanUpper} and n > 3999))
  case (if asDigits: nsDigits else: style)
  of nsDigits: result = $n
  of nsArabicIndic, nsPersian:
    let zero = if style == nsPersian: 0x06F0 else: 0x0660
    for c in $n:
      if c in '0' .. '9':
        let cp = zero + ord(c) - ord('0')
        result.add char(0xC0 or (cp shr 6))
        result.add char(0x80 or (cp and 0x3F))
      else: result.add c
  of nsRomanLower: result = roman(n)
  of nsRomanUpper: result = roman(n).toUpperAscii
  of nsLetterLower, nsLetterUpper:
    var k = n
    while k > 0:
      dec k
      result.insert($char(ord(if style == nsLetterUpper: 'A' else: 'a') + k mod 26), 0)
      k = k div 26
  of nsAbjad:
    # (past the 28 letters: the letter again, as often as it has come round)
    for _ in 0 .. (n - 1) div 28: result.add abjad[(n - 1) mod 28]

const shapingOwn = ["init", "medi", "med2", "fina", "fin2", "fin3", "isol", "rlig", "ccmp", "locl", "mark", "mkmk",
                    "kern", "curs", "rvrn", "frac", "numr", "dnom", "abvm", "blwm", "dist", "rtlm", "ltrm", "rtla",
                    "ltra", "rclt", "aalt", "size", "vert", "vrt2", "vkrn", "valt", "vhal", "vpal"]
  ## (what a script needs to be set at all, and what is not a choice of shapes)

proc alternatesFor*(text: string; st: CharStyle): seq[tuple[tag, name: string; on: bool]] =
  ## The choices a font gives for how `text` (a word, a few letters) is
  ## shaped: its OpenType features that draw it with other glyphs than
  ## with them off -- stylistic sets, swashes, alternate and historical
  ## forms, ligatures (Arabic: the other shapes of its letters and their
  ## joins) -- each with its tag ("ss02"), the name the font gives it (or
  ## the tag) and whether `st` has it on (as `CharStyle.features`, or by
  ## the font's own default). To have one, add "+tag" to the style's
  ## `features`; "-tag" to be without it. Empty for a font without
  ## OpenType tables.
  let face = fontFace(st.family, st.style).face
  if face == nil or not face.hasLayout: return
  var cps: seq[int]
  var rtl = false
  for r in text.runes:
    cps.add int(r)
    if int(r) in 0x0590 .. 0x08FF or int(r) in 0xFB1D .. 0xFDFF or int(r) in 0xFE70 .. 0xFEFF: rtl = true
  if cps.len == 0: return
  var asked: seq[Feature]
  for w in strutils.splitWhitespace(st.features):
    if w.startsWith("-"): asked.add (w[1 .. ^1], false)
    elif w.startsWith("+"): asked.add (w[1 .. ^1], true)
    else: asked.add (w, true)
  proc gids(feats: openArray[Feature]): seq[int] =
    try:
      for g in shape(face, cps, rtl, features = feats): result.add g.gid
    except CatchableError: discard
  for tag in face.featureTags:
    if tag in shapingOwn: continue
    let withIt = gids([(tag, true)])
    let without = gids([(tag, false)])
    if withIt == without or withIt.len == 0: continue
    # (on: as the style asks, else as the font shapes by itself)
    var on = gids([]) == withIt
    for (t, v) in asked:
      if t == tag: on = v
    let name = face.featureName(tag)
    result.add (tag, (if name.len > 0: name else: tag), on)

proc defaultStyle*(): CharStyle =
  ## The style of a new text: FreeSans Regular, 36 pixels, black.
  CharStyle(family: defaultFamily, style: "Regular", size: 36, color: 0xFF000000'u32, hScale: 1, vScale: 1)

const DefaultFeatures* = ["liga", "clig", "calt", "kern"]
  ## The OpenType features on when a style's `features` do not say: the
  ## font's standard and contextual ligatures, contextual alternates and
  ## kerning. Those a script needs -- Arabic's joined forms and its
  ## required ligatures (lam + alef: `rlig`), marks placed -- are always on.

proc featureOn*(features, tag: string): bool =
  ## Whether OpenType feature `tag` is on in a style's list ("+ss01
  ## -liga"): as the list says, else as `DefaultFeatures`.
  result = tag in DefaultFeatures
  for w in strutils.splitWhitespace(features):
    if w == "+" & tag or w == tag: result = true
    elif w == "-" & tag: result = false

proc withFeature*(features, tag: string; on: bool): string =
  ## The list with `tag` on or off (left out when that is its default).
  var ws: seq[string]
  for w in strutils.splitWhitespace(features):
    if w notin ["+" & tag, "-" & tag, tag]: ws.add w
  if on != (tag in DefaultFeatures): ws.add (if on: "+" else: "-") & tag
  ws.join(" ")

proc ligaturesOn*(s: CharStyle): bool = featureOn(s.features, "liga")
  ## Ligatures (the Character panel's): the font's standard ligatures --
  ## fi, fl; an Arabic font's optional ones -- are on.

proc withLigatures*(features: string; on: bool): string =
  ## The list with the standard and contextual ligatures (`liga`, `clig`)
  ## on or off. Arabic's required ligatures stay.
  withFeature(withFeature(features, "liga", on), "clig", on)

const OpenTypeMenu* = [("Discretionary Ligatures", "dlig"), ("Fractions", "frac"), ("Ordinal", "ordn"),
                       ("Swash", "swsh"), ("Titling Alternates", "titl"), ("Contextual Alternates", "calt"),
                       ("All Small Caps", "c2sc"), ("Slashed Zero", "zero"), ("Superscript", "sups"),
                       ("Subscript", "subs"), ("Oldstyle Figures", "onum"), ("Tabular Figures", "tnum"),
                       ("Stylistic Alternates", "salt"), ("Historical Forms", "hist")]
  ## The OpenType features a layout program's Character panel names in its
  ## OpenType menu, and their tags (a font without one shows it in [brackets]).

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

proc fmtOf*(t: TextData; k: int): ParaStyle =
  ## The paragraph format `CharStyle.para` `k` names (0: the text's own, `para`).
  if k > 0 and k <= t.paraFmts.len: t.paraFmts[k - 1] else: t.para

proc evenParas(t: var TextData)
proc tidyParaFmts(t: var TextData)

proc insertText*(t: var TextData; i: int; s: string; style: CharStyle) =
  ## `s` put in at character `i` in `style` -- in the format of the paragraph it goes into (new
  ## paragraphs it starts too: `setParaFmt` to change them).
  if s.len == 0: return
  var style = style
  if t.paraFmts.len > 0:
    let r = t.plainText.toRunes
    let at = clamp(i, 0, r.len)
    style.para = if at < r.len and (at == 0 or int(r[at - 1]) == 10): t.styleAt(at).para
                 elif at > 0 and at == r.len and int(r[at - 1]) == 10 and t.tailFmt > 0: t.tailFmt - 1
                 elif at > 0: t.styleAt(at - 1).para
                 else: 0
    if at == r.len: t.tailFmt = 0           # (the paragraph at the end has letters now)
  else: style.para = 0
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
  t.evenParas()

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
  t.evenParas()
  t.tidyParaFmts()

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

proc evenParas(t: var TextData) =
  ## (every character of a paragraph in its first one's format -- as the layout program keeps
  ## them when paragraphs are joined or split)
  var cur = 0
  var atStart = true
  var odd = false
  for sp in t.spans:
    for c in sp.text:
      if atStart:
        cur = sp.style.para
        atStart = false
      elif sp.style.para != cur:
        odd = true
      if c == '\n': atStart = true
  if not odd: return
  var o: seq[TextSpan]
  atStart = true
  for sp in t.spans:
    var piece = ""
    for c in sp.text:
      if atStart:
        if piece.len > 0:
          var st = sp.style
          st.para = cur
          o.add TextSpan(text: piece, style: st)
          piece = ""
        cur = sp.style.para
        atStart = false
      piece.add c
      if c == '\n': atStart = true
    if piece.len > 0:
      var st = sp.style
      st.para = cur
      o.add TextSpan(text: piece, style: st)
  if o.len > 0: t.spans = o
  t.normalize()

proc paraBounds*(t: TextData; pos: int): tuple[a, b: int] =
  ## The paragraph character `pos` is in: from its first character to its end (the "\n" that
  ## ends it, or the text's end).
  let r = t.plainText.toRunes
  let p = clamp(pos, 0, r.len)
  var a = p
  while a > 0 and int(r[a - 1]) != 10: dec a
  var b = p
  while b < r.len and int(r[b]) != 10: inc b
  (a, b)

proc paraFmtAt*(t: TextData; pos: int): ParaStyle =
  ## The format of the paragraph character `pos` is in (`para`, or one of `paraFmts`).
  let (a, b) = t.paraBounds(pos)
  let k = if a < b or a < t.runeLen: t.styleAt(a).para
          elif a > 0: (if t.tailFmt > 0: t.tailFmt - 1 else: t.styleAt(a - 1).para)
          else: 0
  if k > 0 and k <= t.paraFmts.len: t.paraFmts[k - 1] else: t.para

proc tidyParaFmts(t: var TextData) =
  ## (formats no paragraph has let go, the rest numbered again; the first paragraph's the text's
  ## own -- what the whole text keeps, a list, a drop cap, is its)
  if t.paraFmts.len == 0:
    t.tailFmt = 0
    return
  let nf = t.paraFmts.len
  proc fmtNo(k: int): int = (if k in 1 .. nf: k else: 0)
  var used: seq[int]                   # (the formats in the paragraphs' order, each once)
  var atStart = true
  var any = false
  for sp in t.spans:
    for c in sp.text:
      any = true
      if atStart:
        let k = fmtNo(sp.style.para)
        if k notin used: used.add k
        atStart = false
      if c == '\n': atStart = true
  if t.tailFmt > 0:
    if atStart and any:
      let k = fmtNo(t.tailFmt - 1)
      if k notin used: used.add k
    else: t.tailFmt = 0
  if used.len == 0: used.add 0
  let first = t.fmtOf(used[0])
  var map = newSeq[int](nf + 1)
  var kept: seq[ParaStyle]
  for k in used:
    let f = t.fmtOf(k)
    if f == first: map[k] = 0
    else:
      let q = kept.find(f)
      if q >= 0: map[k] = q + 1
      else:
        kept.add f
        map[k] = kept.len
  t.para = first
  t.paraFmts = kept
  for sp in t.spans.mitems: sp.style.para = map[fmtNo(sp.style.para)]
  if t.tailFmt > 0: t.tailFmt = map[fmtNo(t.tailFmt - 1)] + 1
  if t.tailFmt == 1 and t.paraFmts.len == 0: t.tailFmt = 0
  t.normalize()

proc setParaFmt*(t: var TextData; a, b: int; p: ParaStyle) =
  ## The paragraphs characters `a` .. `b` are in (the one `a` is in when `a` = `b`) set in format
  ## `p` -- as the Paragraph panel does with paragraphs selected; all of them: the text's own.
  let n = t.runeLen
  let (a0, _) = t.paraBounds(min(a, b))
  let (_, b1) = t.paraBounds(max(a, b))
  if a0 == 0 and b1 >= n:
    t.para = p
    t.paraFmts.setLen(0)
    t.tailFmt = 0
    for sp in t.spans.mitems: sp.style.para = 0
    t.normalize()
    return
  var k = 0
  if p != t.para:
    k = t.paraFmts.find(p) + 1
    if k == 0:
      t.paraFmts.add p
      k = t.paraFmts.len
  if a0 >= n:
    # (an empty paragraph at the end: its format kept for what is typed in it)
    t.tailFmt = k + 1
    t.tidyParaFmts()
    return
  let kk = k
  t.restyle(a0, min(n, b1 + 1), proc (s: var CharStyle) = s.para = kk)
  t.tidyParaFmts()

proc linkRuns*(t: TextData): seq[tuple[a, b: int; link: string]] =
  ## The text's hyperlinks and destinations, as characters `a` ..< `b` and their `CharStyle.link`
  ## (neighbours with the same one joined).
  var at = 0
  for sp in t.spans:
    let n = sp.text.runeLen
    if sp.style.link.len > 0:
      if result.len > 0 and result[^1].b == at and result[^1].link == sp.style.link: result[^1].b = at + n
      else: result.add (at, at + n, sp.style.link)
    at += n

proc changeParas*(t: var TextData; a, b: int; change: proc (p: var ParaStyle)) =
  ## Each paragraph characters `a` .. `b` are in changed by `change` (its own format: paragraphs
  ## in different ones keep what else they have); `a` = 0, `b` = `runeLen`: all of them.
  let r = t.plainText.toRunes
  var starts: seq[int]
  let (a0, _) = t.paraBounds(min(a, b))
  let (_, b1) = t.paraBounds(max(a, b))
  var k = a0
  starts.add a0
  while k < b1:
    if int(r[k]) == 10 and k + 1 <= b1: starts.add k + 1
    inc k
  if starts.len > 0 and starts[^1] >= r.len and starts.len > 1 and r.len > 0:
    starts.setLen(starts.len - 1)          # (an empty last paragraph: the one before's format)
  if starts.len == 1 or (a0 == 0 and b1 >= r.len and t.paraFmts.len == 0):
    if a0 == 0 and b1 >= r.len:
      # (one format for all of it: the text's own)
      if t.paraFmts.len == 0:
        change(t.para)
        return
    var f = t.paraFmtAt(a0)
    change(f)
    t.setParaFmt(a0, a0, f)
    return
  var fmts: seq[ParaStyle]
  for st in starts:
    var f = t.paraFmtAt(st)
    change(f)
    fmts.add f
  for q, st in starts: t.setParaFmt(st, st, fmts[q])

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
    para*: int                 ## the paragraph it is in (0 the first)

  Decoration* = object
    ## An underline or a strike: a bar from `x0` to `x1` at `y`, `thick` thick.
    x0*, x1*, y*, thick*: float32  ## where it runs and how thick it is (pixels)
    color*: uint32                 ## ARGB

  TextLayout* = object
    ## A text laid out (`layoutText`): its glyphs, lines and bars, ready to
    ## draw or to place a caret in.
    glyphs*: seq[LaidGlyph]        ## in the order they are drawn
    lines*: seq[LaidLine]          ## top to bottom
    decorations*: seq[Decoration]  ## its underlines and strikes (a table's lines too)
    backs*: seq[Decoration]        ## what is drawn under the letters: a table's fills
    caretX*: seq[float32]      ## per character (and the end): where the caret goes before it
    caretLine*: seq[int]       ## ... on which line
    x0*, y0*, x1*, y1*: float32    ## the bounds of the letters
    overflow*: int             ## text in a box, columns: the first character that did not fit
                               ## (it flows on into the next box); -1: all of it fits
    paras*: seq[ParaStyle]     ## each paragraph's format (`LaidLine.para` says which a line is in)

  GlyphPart = object
    gid: int
    mark: bool                 # (a mark over or under its letter)
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
    let ff = ownFace(id)
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

proc freeRooms(holes: seq[TextHole]; ya, yb, bx0, bx1, least: float32): seq[tuple[x0, x1: float32]] =
  ## (the rooms between `bx0` and `bx1` that the holes leave a line lying
  ## from `ya` down to `yb`, from left to right: those `least` wide or more)
  var cuts: seq[(float32, float32)]
  for h in holes:
    if h.y0 < yb and h.y1 > ya and h.x1 > bx0 and h.x0 < bx1: cuts.add (max(bx0, h.x0), min(bx1, h.x1))
  if cuts.len == 0: return @[(bx0, bx1)]
  cuts.sort(proc (p, q: (float32, float32)): int = cmp(p[0], q[0]))
  var at = bx0
  for (c0, c1) in cuts:
    if c0 - at >= least: result.add (at, c0)
    at = max(at, c1)
  if bx1 - at >= least: result.add (at, bx1)

proc layoutPlain(t: TextData): TextLayout
proc dropCapped(t: TextData): TextLayout
proc tableLaid(t: TextData): TextLayout

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

proc columnize(l: var TextLayout; t: TextData; colW, gutter: float32; starts: var seq[float32]) =
  ## (the lines laid out a column wide moved into the columns side by side,
  ## each from the box's top; what does not fit the last one let go.
  ## `starts`: how far down the one long column each column began. As the
  ## layout programs set columns: a paragraph's Keep Options -- its lines
  ## together, so many at its start and its end, with the next one, in the
  ## next column or frame -- a paragraph across them all (the columns over
  ## it balanced), one split in columns of its own, Balance Columns, and
  ## the box's Vertical Justification)
  let n = max(1, t.columns)
  var colStarts = newSeq[float32](n)
  for c in 1 ..< n: colStarts[c] = -1
  let lines = l.lines
  let paras = l.paras
  let bottom = t.y + t.boxH + 0.5'f32
  let nl = lines.len
  var keep = nl
  var dxs = newSeq[float32](nl)
  var dys = newSeq[float32](nl)
  var colOf = newSeq[int](nl)
  # the paragraphs' lines
  let np = max(paras.len, (if nl > 0: lines[^1].para + 1 else: 0))
  var pfirst = newSeq[int](np)
  var plast = newSeq[int](np)
  for p in 0 ..< np:
    pfirst[p] = -1
    plast[p] = -1
  for i, ln in lines:
    let p = clamp(ln.para, 0, np - 1)
    if pfirst[p] < 0: pfirst[p] = i
    plast[p] = i
  proc fmt(p: int): ParaStyle = (if p >= 0 and p < paras.len: paras[p] else: t.para)
  # (a paragraph split in columns of its own: its lines side by side in its column -- each line's
  # place in the one long column then, and how far across)
  var vshift = newSeq[float32](nl)
  var vdx = newSeq[float32](nl)
  var lift = 0'f32
  for p in 0 ..< np:
    if pfirst[p] < 0: continue
    for i in pfirst[p] .. plast[p]: vshift[i] = -lift
    let k = fmt(p).splitColumns
    if k >= 2 and plast[p] > pfirst[p]:
      let m = plast[p] - pfirst[p] + 1
      let rows = (m + k - 1) div k
      let subW = max(8'f32, (colW - gutter * float32(k - 1)) / float32(k))
      let top0 = lines[pfirst[p]].baseline - lines[pfirst[p]].ascent
      var tallest = 0'f32
      for q in 0 ..< m:
        let i = pfirst[p] + q
        let s = q div rows
        let first = pfirst[p] + s * rows
        let ln = lines[i]
        # (each sub-column from the paragraph's top)
        let up = (lines[first].baseline - lines[first].ascent) - top0
        vshift[i] = -lift - up
        vdx[i] = float32(s) * (subW + gutter)
        tallest = max(tallest, ln.baseline + ln.descent - up - top0)
      let whole = lines[plast[p]].baseline + lines[plast[p]].descent - top0
      lift += max(0'f32, whole - tallest)
  proc vtop(i: int): float32 = lines[i].baseline - lines[i].ascent + vshift[i]
  proc vbot(i: int): float32 = lines[i].baseline + lines[i].descent + vshift[i]
  proc paraOf(i: int): int = clamp(lines[i].para, 0, np - 1)
  proc gapBefore(i: int): float32 =
    ## (the room over line `i` in the one long column: from the box's top, or the line before)
    if i == 0: vtop(0) - t.y else: max(0'f32, vtop(i) - vbot(i - 1))
  proc kept(j: int): int =
    ## (where the column breaks for line `j`, by its paragraph's Keep Lines Together)
    let p = paraOf(j)
    let pp = fmt(p)
    result = j
    if pp.keepTogether or pp.splitColumns >= 2: return pfirst[p]
    if plast[p] - j + 1 < max(1, pp.keepEnd): result = max(pfirst[p], plast[p] - max(1, pp.keepEnd) + 1)
    if result - pfirst[p] < max(1, pp.keepStart): result = pfirst[p]
  proc breakBefore(j, colStart: int): int =
    ## (where the column breaks when line `j` does not fit: the paragraphs' Keep Options)
    var b = kept(j)
    # (the end of the paragraph before kept with so many lines of this one: it goes along)
    for _ in 0 ..< 16:
      let pb = paraOf(b)
      if pb == 0 or plast[pb - 1] < 0: break
      let w = fmt(pb - 1).keepWithNext
      if w <= 0 or b - pfirst[pb] >= w: break
      let nb = kept(plast[pb - 1])
      if nb <= colStart: break
      b = nb
    if b <= colStart: j else: b
  # the bands: runs of lines in columns, a paragraph across them between
  var bandTop = t.y
  var i = 0
  block placing:
    while i < nl:
      let p = paraOf(i)
      if fmt(p).spanAll and n > 1:
        # a paragraph across all the columns: under the band before, the next band under it
        let shift = bandTop + gapBefore(i) - vtop(i)
        var bot = bandTop
        for j in i .. plast[p]:
          if vbot(j) + shift > bottom:
            keep = j
            break placing
          dxs[j] = 0
          dys[j] = shift + vshift[j]
          colOf[j] = -1
          bot = max(bot, vbot(j) + shift)
        bandTop = bot
        i = plast[p] + 1
        continue
      var runEnd = i
      while runEnd < nl and not (fmt(paraOf(runEnd)).spanAll and n > 1): inc runEnd
      let balanced = n > 1 and (runEnd < nl or t.balance)
      var ends = newSeq[float32](n)
      var stopAt = -1
      proc place(h: float32; real: bool): bool =
        ## (the lines `i` ..< `runEnd` in columns `h` tall: false when they do not all fit;
        ## where they go when `real`)
        var col = 0
        var colStart = i
        var yOff = vtop(i) - bandTop - gapBefore(i)
        var j = i
        for c in 0 ..< n: ends[c] = 0
        stopAt = -1
        while j < runEnd:
          let pj = paraOf(j)
          let st = fmt(pj).startAt
          let forced = j == pfirst[pj] and j > colStart and st != psAnywhere
          if forced and st in {psNextFrame, psNextPage}:
            stopAt = j                            # (on in the next frame: the rest overset here)
            return true
          if forced or (vbot(j) - yOff > bandTop + h + 0.5'f32 and j > colStart):
            let b = if forced: j else: breakBefore(j, colStart)
            inc col
            if col >= n:
              stopAt = b
              return false
            colStart = b
            yOff = vtop(b) - bandTop
            if real and colStarts[col] < 0: colStarts[col] = bandTop + yOff - t.y
            j = b
            continue
          if vbot(j) - yOff > bottom and col == n - 1 and j == colStart:
            stopAt = j                            # (a line taller than the whole box: overset)
            return false
          if real:
            let rtl = lines[j].rtl
            let c = if rtl: n - 1 - col else: col   # (right to left: the first column at the right)
            dxs[j] = float32(c) * (colW + gutter) + (if rtl: -vdx[j] else: vdx[j])
            dys[j] = vshift[j] - yOff
            colOf[j] = col
          ends[col] = max(ends[col], vbot(j) - yOff)
          inc j
        true
      var h = t.y + t.boxH - bandTop
      if balanced and place(h, false):
        # (as short as they all still fit: the columns even)
        var lo = 0'f32
        var hi = h
        for _ in 0 ..< 18:
          let mid = (lo + hi) / 2
          if place(mid, false): hi = mid else: lo = mid
        h = hi + 0.01'f32
      let fits = place(h, true)
      if stopAt >= 0:
        keep = stopAt
        break placing
      if not fits:
        keep = runEnd
        break placing
      for c in 0 ..< n: bandTop = max(bandTop, ends[c])
      i = runEnd
  if colStarts[0] < 0: colStarts[0] = 0
  starts = colStarts
  # Vertical Justification: each column's lines moved down (center, bottom) or spread (justify)
  if t.vjust != vjTop and keep > 0:
    for c in 0 ..< n:
      var idx: seq[int]
      var used = -1e9'f32
      for j in 0 ..< keep:
        if colOf[j] == c:
          idx.add j
          used = max(used, lines[j].baseline + lines[j].descent + dys[j])
      if idx.len == 0: continue
      let room = t.y + t.boxH - used
      if room <= 0: continue
      case t.vjust
      of vjCenter:
        for j in idx: dys[j] += room / 2
      of vjBottom:
        for j in idx: dys[j] += room
      of vjJustify:
        if idx.len > 1:
          for q, j in idx: dys[j] += room * float32(q) / float32(idx.len - 1)
      else: discard
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

proc holedColumns(t, single: TextData; cols: int; colW, gutter: float32): TextLayout =
  ## Holes and columns: a hole is in a column's way where that column lies
  ## in the one long column the lines are broken in -- known once the
  ## columns are made. Laid out without the holes first, then with them,
  ## until the columns begin where they were taken to.
  var u = single
  u.holes = @[]
  var lay = layoutPlain(u)
  lay.overflow = -1
  var starts: seq[float32]
  var probe = lay
  probe.columnize(t, colW, gutter, starts)
  let rtl = lay.lines.len > 0 and lay.lines[0].rtl
  for pass in 0 ..< 5:
    for c in 1 ..< cols:
      if starts[c] < 0: starts[c] = starts[c - 1] + t.boxH       # (a column not reached yet)
    u.holes = @[]
    for c in 0 ..< cols:
      let vc = if rtl: cols - 1 - c else: c                    # (where the column is, from the left)
      let cx0 = t.x + float32(vc) * (colW + gutter)
      for h in t.holes:
        let x0 = max(h.x0, cx0)
        let x1 = min(h.x1, cx0 + colW)
        let y0 = max(h.y0, t.y)
        let y1 = min(h.y1, t.y + t.boxH)
        if x1 > x0 and y1 > y0:
          u.holes.add (x0 - float32(vc) * (colW + gutter), y0 + starts[c],
                       x1 - float32(vc) * (colW + gutter), y1 + starts[c])
    lay = layoutPlain(u)
    lay.overflow = -1
    var again: seq[float32]
    probe = lay
    probe.columnize(t, colW, gutter, again)
    var same = true
    for c in 0 ..< cols:
      if again[c] >= 0 and abs(again[c] - starts[c]) > 0.5: same = false
    starts = again
    if same: break
  probe

# ---- footnotes and endnotes -------------------------------------------------------------------------------

const NoteBase = 0xF0000
  # (a note's reference: one character of the Supplementary Private Use Area-A, its id after this)

proc noteMark*(id: int): string =
  ## The character that stands for note `id` in the text: its number is shown there.
  $Rune(NoteBase + clamp(id, 1, 65533))

proc isNoteMark*(cp: int): bool {.inline.} = cp > NoteBase and cp < NoteBase + 65534
  ## Character `cp` is a note's reference.

proc noteMarks*(t: TextData): seq[tuple[at, id: int]] =
  ## The notes' references in the text: before which character, which note.
  var i = 0
  for sp in t.spans:
    for r in sp.text.runes:
      if isNoteMark(int(r)): result.add (i, int(r) - NoteBase)
      inc i

proc tidyNotes*(t: var TextData) =
  ## The notes put in the order of their references; a note whose reference is gone goes too,
  ## a reference without a note gets an empty one. (After the text was edited; never on a
  ## `remainder`: it keeps the notes of the boxes before it.)
  var byId: Table[int, string]
  for n in t.notes: byId[n.id] = n.text
  var notes: seq[Footnote]
  var seen: seq[int]
  for (at, id) in t.noteMarks:
    if id in seen: continue
    seen.add id
    notes.add Footnote(id: id, text: byId.getOrDefault(id))
  t.notes = notes

proc insertNote*(t: var TextData; at: int; text = ""): int =
  ## A new note saying `text`, its reference put before character `at` (in the style of the
  ## character before it); its id (0: no room for one more).
  var id = 1
  for n in t.notes: id = max(id, n.id + 1)
  for (_, k) in t.noteMarks: id = max(id, k + 1)
  if id > 65533: return 0
  var i = 0
  var done = false
  for s in t.spans.mitems:
    let n = s.text.runeLen
    if at <= i + n:
      let off = max(0, at - i)
      let b = if off >= n: s.text.len else: s.text.runeOffset(off)
      s.text.insert(noteMark(id), b)
      done = true
      break
    i += n
  if not done:
    if t.spans.len == 0: t.spans.add TextSpan(text: "", style: defaultStyle())
    t.spans[^1].text.add noteMark(id)
  t.notes.add Footnote(id: id, text: text)
  t.tidyNotes()
  id

const AnchorBase = 0x100000
  # (an anchored object's place in the text: one character of the Supplementary Private Use
  # Area-B, its id after this -- laid out as nothing)

proc anchorMark*(id: int): string =
  ## The character that marks where anchored object `id` is in the text (it takes no room).
  $Rune(AnchorBase + clamp(id, 1, 65533))

proc isAnchorMark*(cp: int): bool {.inline.} = cp > AnchorBase and cp < AnchorBase + 65534
  ## Character `cp` is an anchored object's place.

proc anchorMarks*(t: TextData): seq[tuple[at, id: int]] =
  ## The anchored objects' places in the text: at which character, which anchor.
  var i = 0
  for sp in t.spans:
    for r in sp.text.runes:
      if isAnchorMark(int(r)): result.add (i, int(r) - AnchorBase)
      inc i

proc insertAnchor*(t: var TextData; at: int): int =
  ## A new anchor put before character `at`; its id (0: no room for one more).
  var id = 1
  for (_, k) in t.anchorMarks: id = max(id, k + 1)
  if id > 65533: return 0
  var i = 0
  for s in t.spans.mitems:
    let n = s.text.runeLen
    if at <= i + n:
      let off = max(0, at - i)
      s.text.insert(anchorMark(id), if off >= n: s.text.len else: s.text.runeOffset(off))
      return id
    i += n
  if t.spans.len == 0: t.spans.add TextSpan(text: "", style: defaultStyle())
  t.spans[^1].text.add anchorMark(id)
  id

proc noteNumber*(t: TextData; id: int): string =
  ## Note `id`'s number as it is written: its place among the notes, counted from
  ## `noteOpts.start`, in `noteOpts.numbers`.
  var k = -1
  for i, n in t.notes:
    if n.id == id:
      k = i
      break
  if k < 0: return "?"
  formatNumber((if t.noteOpts.start > 0: t.noteOpts.start else: 1) + k, t.noteOpts.numbers)

proc noteHeading*(t: TextData): string =
  ## The endnotes' heading: `noteOpts.heading`, else "Notes" -- "الحواشي" for an Arabic text.
  if t.noteOpts.heading.len > 0: return t.noteOpts.heading
  for sp in t.spans:
    for r in sp.text.runes:
      let c = int(r)
      if c in 0x0600 .. 0x06FF: return "الحواشي"
      if c in int('A') .. int('Z') or c in int('a') .. int('z'): return "Notes"
  "Notes"

proc refStyle(st: CharStyle; o: NoteOptions): CharStyle =
  ## (a reference's number: smaller, raised)
  result = st
  let k = if o.refScale > 0: o.refScale else: 0.6'f32
  result.baselineShift = st.baselineShift + st.size * 0.36
  result.size = st.size * k
  result.underline = false
  result.strike = false

proc noteStyle(t: TextData): CharStyle =
  ## (the notes' own style: the text's first, smaller)
  result = if t.spans.len > 0: t.spans[0].style else: defaultStyle()
  result.size = result.size * (if t.noteOpts.scale > 0: t.noteOpts.scale else: 0.8'f32)
  result.baselineShift = 0
  result.underline = false
  result.strike = false

proc noteSpans(t: TextData; ids: seq[int]): seq[TextSpan] =
  ## (the notes `ids`, a paragraph each: the number, then what it says)
  let ns = t.noteStyle
  let sep = if t.noteOpts.separator.len > 0: t.noteOpts.separator else: ". "
  for q, id in ids:
    var text = ""
    for n in t.notes:
      if n.id == id: text = n.text
    result.add TextSpan(text: (if q > 0: "\n" else: "") & t.noteNumber(id) & sep, style: ns)
    if text.len > 0: result.add TextSpan(text: text, style: ns)

proc expandRefs(t: TextData): tuple[u: TextData; map: seq[int]; refs: seq[tuple[at, id: int]]] =
  ## (the references written as their numbers; `map`: each character of `u` -> the one of `t`
  ## it shows, and the end; `refs`: where each number begins in `u`)
  result.u = t
  result.u.spans = @[]
  result.u.notes = @[]
  var i = 0
  for sp in t.spans:
    var piece = ""
    for r in sp.text.runes:
      let cp = int(r)
      if isAnchorMark(cp):
        discard                      # (an anchor: no room, nothing drawn -- its place the next letter's)
      elif isNoteMark(cp) and t.notes.len > 0:
        if piece.len > 0:
          result.u.spans.add TextSpan(text: piece, style: sp.style)
          piece = ""
        let num = t.noteOpts.prefix & t.noteNumber(cp - NoteBase) & t.noteOpts.suffix
        result.refs.add (result.map.len, cp - NoteBase)
        result.u.spans.add TextSpan(text: num, style: refStyle(sp.style, t.noteOpts))
        for _ in 0 ..< max(1, num.runeLen): result.map.add i
      else:
        piece.add $r
        result.map.add i
      inc i
    if piece.len > 0: result.u.spans.add TextSpan(text: piece, style: sp.style)
  result.map.add i

proc remapLayout(lay: var TextLayout; map: seq[int]) =
  ## (a layout of the text with its numbers made the text's own again: each glyph's character,
  ## the caret's places, the lines; what is past the text -- the notes -- is no character's)
  let mainEnd = map.high
  let n = map[^1]
  for g in lay.glyphs.mitems:
    g.index = if g.index < 0 or g.index >= mainEnd: -1 else: map[g.index]
  if lay.caretX.len > 0:
    var cx = newSeq[float32](n + 1)
    var cl = newSeq[int](n + 1)
    var seen = newSeq[bool](n + 1)
    for j in 0 ..< min(mainEnd, lay.caretX.len):
      let i = map[j]
      if not seen[i]:
        seen[i] = true
        cx[i] = lay.caretX[j]
        cl[i] = lay.caretLine[min(j, lay.caretLine.high)]
    let e = min(mainEnd, lay.caretX.high)
    cx[n] = lay.caretX[e]
    cl[n] = lay.caretLine[min(e, lay.caretLine.high)]
    # (a character not laid out -- an anchor --: where the next one is)
    for i in countdown(n - 1, 0):
      if not seen[i]:
        cx[i] = cx[i + 1]
        cl[i] = cl[i + 1]
    lay.caretX = cx
    lay.caretLine = cl
  var lines: seq[LaidLine]
  for ln in lay.lines:
    if ln.first >= mainEnd and lines.len > 0: continue     # (a note's line)
    var l2 = ln
    l2.first = map[min(ln.first, mainEnd)]
    l2.last = if ln.last >= mainEnd: n else: map[ln.last]
    lines.add l2
  lay.lines = lines
  if lay.overflow >= 0: lay.overflow = if lay.overflow >= mainEnd: -1 else: map[lay.overflow]

proc notesAsText*(t: TextData): TextData =
  ## The text with its notes as plain text: the references' numbers in it (smaller, raised),
  ## the notes after it, a paragraph each -- for what has no notes of its own (a PSD's type, an
  ## SVG's text).
  if t.notes.len == 0: return t
  let (u, _, _) = expandRefs(t)
  result = u
  result.spans.add TextSpan(text: "\n", style: t.noteStyle)
  if t.noteOpts.kind == nkEndnotes:
    var hs = if t.spans.len > 0: t.spans[0].style else: defaultStyle()
    hs.fauxBold = true
    result.spans.add TextSpan(text: t.noteHeading & "\n",
                              style: hs)
  var ids: seq[int]
  for n in t.notes: ids.add n.id
  result.spans.add t.noteSpans(ids)

proc layoutText*(t: TextData): TextLayout

proc notesLaid(t: TextData): TextLayout =
  ## (a text with notes: the references' numbers in it; footnotes at the foot of its box --
  ## the text kept above them, the notes of the references that are in the box, under a line;
  ## endnotes, and the notes of text not in a box, after it)
  var (u, map, refs) = expandRefs(t)
  if t.notes.len == 0:
    # (anchors only: the text without them, the caret's places theirs too)
    result = layoutText(u)
    remapLayout(result, map)
    return
  let o = t.noteOpts
  let base = if t.spans.len > 0: t.spans[0].style else: defaultStyle()
  if o.kind == nkEndnotes or t.boxW <= 0 or t.boxH <= 0:
    var ids: seq[int]
    for n in t.notes: ids.add n.id
    let gapLine = TextSpan(text: "\n", style: t.noteStyle)
    u.spans.add gapLine
    if o.kind == nkEndnotes:
      var hs = base
      hs.fauxBold = true
      u.spans.add TextSpan(text: t.noteHeading & "\n", style: hs)
    u.spans.add t.noteSpans(ids)
    result = layoutText(u)
    remapLayout(result, map)
    return
  let gap = if o.gap > 0: o.gap else: base.size * 0.5
  var reserve = 0'f32
  var blk: TextLayout
  var blkH = 0'f32
  for round in 0 ..< 8:
    var m = u
    m.boxH = max(1'f32, t.boxH - reserve)
    m.clipOverflow = true
    result = layoutText(m)
    let upTo = if result.overflow >= 0: result.overflow else: map.high
    var ids: seq[int]
    for (at, id) in refs:
      if at < upTo and id notin ids: ids.add id
    if ids.len == 0:
      blk = TextLayout()
      blkH = 0
      break
    var nt = newText("", t.noteStyle, t.x, 0)
    nt.spans = t.noteSpans(ids)
    nt.boxW = t.boxW
    nt.boxH = 1e6
    nt.para.rtl = t.para.rtl
    nt.para.align = t.para.align
    if nt.para.align == justifyAll: nt.para.align = justifyLeft
    blk = layoutText(nt)
    blkH = if blk.lines.len > 0: blk.lines[^1].baseline + blk.lines[^1].descent else: 0'f32
    let need = blkH + gap
    if need <= reserve + 0.5 or reserve >= t.boxH * 0.9: break
    reserve = min(need, t.boxH * 0.9)
  if blkH > 0:
    let top = t.y + t.boxH - blkH
    for g in blk.glyphs:
      var g2 = g
      g2.y += top
      g2.index = -1
      if g2.y - g2.size * 0.8 >= t.y: result.glyphs.add g2       # (a note taller than the box: cut)
    for dcr in blk.decorations:
      var d2 = dcr
      d2.y += top
      result.decorations.add d2
    if not o.noRule:
      let rtl = (t.para.rtl == 2) or (t.para.rtl == 0 and blk.lines.len > 0 and blk.lines[0].rtl)
      let len = t.boxW * (if o.ruleLength > 0: o.ruleLength else: 0.33'f32)
      let x0 = if rtl: t.x + t.boxW - len else: t.x
      result.decorations.add Decoration(x0: x0, x1: x0 + len, y: top - gap * 0.5,
                                        thick: (if o.ruleWidth > 0: o.ruleWidth else: 1'f32),
                                        color: (if o.ruleColor != 0: o.ruleColor else: base.color))
    result.y1 = max(result.y1, t.y + t.boxH)
    result.x0 = min(result.x0, t.x)
    result.x1 = max(result.x1, t.x + t.boxW)
  remapLayout(result, map)

proc layoutText*(t: TextData): TextLayout =
  ## Where each glyph of the text goes (straight: warps and paths are made
  ## from this when drawn). Dynamic Text: as big as fills its box. Text in
  ## a box, in its columns (`columns`): what does not fit is overset, not
  ## drawn -- `overflow` says from where. Notes: their
  ## references' numbers in the text, footnotes at the foot of the box
  ## (endnotes after the text), the text kept above them.
  if t.path.len == 0:
    for sp in t.spans:
      for r in sp.text.runes:
        let c = int(r)
        if (isNoteMark(c) and t.notes.len > 0) or isAnchorMark(c): return notesLaid(t)
  var t = t
  if t.boxW > 0 and t.path.len == 0 and (t.inset[0] != 0 or t.inset[1] != 0 or t.inset[2] != 0 or
                                         t.inset[3] != 0):
    # (Inset Spacing: the text kept so far in from the box's sides)
    t.x += t.inset[3]
    t.boxW = max(4'f32, t.boxW - t.inset[1] - t.inset[3])
    t.y += t.inset[0]
    if t.boxH > 0: t.boxH = max(4'f32, t.boxH - t.inset[0] - t.inset[2])
    t.inset = [0'f32, 0, 0, 0]
  var u = t
  let cols = max(1, t.columns)
  # (text in a box keeps to it, as the layout programs have it: what does not fit is overset --
  # not drawn, `overflow` says from where -- a line too tall for the box too)
  let boxedCols = t.boxW > 0 and t.boxH > 0 and t.path.len == 0 and not t.vertical and not t.table.on
  let gutter = if t.gutter > 0: t.gutter else: 12'f32
  let colW = if boxedCols: max(8'f32, (t.boxW - gutter * float32(cols - 1)) / float32(cols)) else: t.boxW
  if boxedCols:
    u.boxW = colW
    u.spanW = t.boxW
  var starts: seq[float32]
  if boxedCols and cols > 1 and t.holes.len > 0: return holedColumns(t, u, cols, colW, gutter)
  result = if t.fit and t.boxW > 0 and t.boxH > 0 and t.path.len == 0: layoutPlain(u.sizesScaled(u.fitScale))
           else: layoutPlain(u)
  result.overflow = -1
  if boxedCols: result.columnize(t, colW, gutter, starts)

proc fitsBox(t: TextData; w, h: float32): bool =
  var u = t
  u.boxW = w
  u.boxH = h
  layoutText(u).overflow < 0

proc autoSized*(t: TextData): TextData =
  ## Text in a box with Auto-Size: the box as big as its text needs -- taller or shorter (Height
  ## Only), as wide as its longest line (Width Only: its lines broken only where they end), both,
  ## or both kept in proportion -- the point `autoRef` names staying where it is. `t` itself when
  ## it has none (or is not in a box, on a path, vertical, Dynamic Text).
  result = t
  if t.autoSize == asOff or t.boxW <= 0 or t.boxH <= 0 or t.path.len > 0 or t.vertical or t.fit or
     t.table.on:
    return
  var w = t.boxW
  var h = t.boxH
  let cols = max(1, t.columns)
  if t.autoSize in {asWidth, asBoth}:
    # (as wide as the longest line, laid out with room to spare)
    var u = t
    u.boxW = 1e5
    u.boxH = 1e6
    u.columns = 1
    u.holes = @[]
    let lay = layoutText(u)
    var widest = 0'f32
    for ln in lay.lines: widest = max(widest, ln.x1 - ln.x0)
    if lay.lines.len > 0:
      let gutter = if t.gutter > 0: t.gutter else: 12'f32
      w = (widest + t.para.indentLeft + t.para.indentRight + max(0'f32, t.para.indentFirst) + 1) *
          float32(cols) + gutter * float32(cols - 1) + t.inset[1] + t.inset[3]
      w = max(w, 4)
  if t.autoSize in {asHeight, asBoth}:
    if cols == 1 and t.notes.len == 0:
      var u = t
      u.boxW = w
      u.boxH = 1e6
      let lay = layoutText(u)
      if lay.lines.len > 0:
        var bottom = t.y
        for ln in lay.lines: bottom = max(bottom, ln.baseline + ln.descent)
        h = max(4'f32, bottom - t.y + 1 + t.inset[2])
    else:
      # (columns share it, notes at its foot: as short as all of it still fits)
      var lo = 4'f32
      var hi = max(t.boxH, 8'f32)
      while not fitsBox(t, w, hi) and hi < 1e5: hi *= 2
      for k in 0 ..< 16:
        let mid = (lo + hi) / 2
        if fitsBox(t, w, mid): hi = mid else: lo = mid
      h = hi + 1
  if t.autoSize == asProportional:
    # (both, in the box's proportion: the smallest that holds it)
    let k0 = t.boxH / max(1'f32, t.boxW)
    var lo = 0.05'f32
    var hi = 1'f32
    while not fitsBox(t, t.boxW * hi, t.boxH * hi) and hi < 64: hi *= 2
    for k in 0 ..< 16:
      let mid = (lo + hi) / 2
      if fitsBox(t, t.boxW * mid, t.boxH * mid): hi = mid else: lo = mid
    w = t.boxW * hi
    h = w * k0
  let col = t.autoRef mod 3
  let row = t.autoRef div 3
  result.x = t.x - (w - t.boxW) * float32(col) / 2
  result.y = t.y - (h - t.boxH) * float32(row) / 2
  result.boxW = w
  result.boxH = h

proc anchorPlaces*(t: TextData; lay: TextLayout): seq[tuple[id: int; x, y: float32; shown: bool]] =
  ## Where each anchor of the text is, laid out as `lay`: at its line's baseline, where the
  ## caret before it goes (`shown` false: past what the box holds).
  for (at, id) in t.anchorMarks:
    if at >= lay.caretX.len or lay.lines.len == 0: continue
    let li = clamp(lay.caretLine[at], 0, lay.lines.high)
    result.add (id, lay.caretX[at], lay.lines[li].baseline, lay.overflow < 0 or at < lay.overflow)

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
  if first > 0: result.para.dropLines = 0         # (the drop cap is the first paragraph's)
  # (a new line it begins with: not a blank first line)
  if result.spans.len > 0 and result.spans[0].text.startsWith("\n"):
    result.spans[0].text = result.spans[0].text[1 .. ^1]

proc listMarks(t: TextData; lay: var TextLayout; rtl: bool) =
  ## (a list's marks, each set where its paragraph's first line starts: on that line's
  ## baseline, at the edge the text stands in from)
  var cps: seq[int]
  for s in t.spans:
    for r in s.text.runes: cps.add int(r)
  var n = (if t.para.listStart > 0: t.para.listStart else: 1) - 1
  for k in 0 ..< lay.lines.len:
    let a = lay.lines[k].first
    # (a paragraph's first line, of a paragraph that says something)
    if a >= cps.len or cps[a] == 10 or (a > 0 and cps[a - 1] != 10): continue
    inc n
    var st = t.styleAt(a)
    if t.para.listColor != 0: st.color = t.para.listColor
    st.baselineShift = 0
    st.underline = false
    st.strike = false
    let mark = if t.para.list == lkBullet: (if t.para.listMark.len > 0: t.para.listMark else: "•")
               else: formatNumber(n, t.para.listNumbers) & (if t.para.listSuffix.len > 0: t.para.listSuffix else: ".")
    var mt = newText(mark, st, 0, 0)
    mt.para.rtl = if rtl: 2 else: 1
    let ml = layoutPlain(mt)
    let x = if rtl: t.x + t.boxW - t.para.indentRight - (ml.x1 - ml.x0) else: t.x + t.para.indentLeft
    for g in ml.glyphs:
      var g2 = g
      g2.x += x - ml.x0
      g2.y += lay.lines[k].baseline
      g2.index = a
      lay.glyphs.add g2

proc scriptOf(c: int): int =
  ## (1 Arabic, 2 Latin, 0 neither: spaces, digits, signs -- they go with the letters about them)
  if c in 0x0600 .. 0x06FF or c in 0x0750 .. 0x077F or c in 0x08A0 .. 0x08FF or c in 0xFB50 .. 0xFDFF or
     c in 0xFE70 .. 0xFEFF: 1
  elif c in int('A') .. int('Z') or c in int('a') .. int('z') or c in 0xC0 .. 0x24F or c in 0x1E00 .. 0x1EFF: 2
  else: 0

proc withScriptFont(st: CharStyle; f: ScriptFont): CharStyle =
  result = st
  if f.family.len > 0: result.family = f.family
  if f.style.len > 0: result.style = f.style
  elif f.family.len > 0 and fontStyles(f.family).find(st.style) < 0: result.style = "Regular"
  if f.scale > 0 and f.scale != 1:
    result.size *= f.scale
    if result.leading > 0: discard              # (the line's distance stays the text's)
  result.baselineShift += f.shift
  if f.color != 0: result.color = f.color
  result.tracking += f.tracking
  result.arabicFont = ScriptFont()
  result.latinFont = ScriptFont()

proc scriptFontsApplied*(t: TextData): TextData =
  ## The text with its spans cut where its script changes, each Arabic and
  ## each Latin run in the font its style names for it (`arabicFont`,
  ## `latinFont`), the spaces and digits with the letters before them: as
  ## it is drawn -- for a program that knows one font a run (a PSD, IDML).
  result = t
  result.spans = @[]
  var last = 0
  for sp in t.spans:
    if sp.style.arabicFont == ScriptFont() and sp.style.latinFont == ScriptFont():
      result.spans.add sp
      continue
    # (the script of each character: a neutral one takes the one before it, else the one after)
    var rs: seq[Rune]
    var sc: seq[int]
    for r in sp.text.runes:
      rs.add r
      sc.add scriptOf(int(r))
    var prev = last
    for i in 0 ..< sc.len:
      if sc[i] == 0: sc[i] = prev else: prev = sc[i]
    var next = 0
    for i in countdown(sc.high, 0):
      if sc[i] == 0: sc[i] = next else: next = sc[i]
    if sc.len > 0: last = sc[^1]
    var i = 0
    while i < rs.len:
      var j = i
      while j < rs.len and sc[j] == sc[i]: inc j
      var piece = ""
      for k in i ..< j: piece.add rs[k]
      let st = case sc[i]
               of 1: sp.style.withScriptFont(sp.style.arabicFont)
               of 2: sp.style.withScriptFont(sp.style.latinFont)
               else: sp.style
      result.spans.add TextSpan(text: piece, style: st)
      i = j

var grepHook*: proc (pattern: string; cps: seq[int]): seq[(int, int)] {.nimcall.}
  ## Where a GREP pattern matches in a paragraph's characters (set by `retroui/textsearch`: GREP
  ## styles are found with it).

proc charStylesIn(cps: seq[int]; pp: ParaStyle): seq[tuple[a, b: int; look: CharStyle]] =
  ## (where a paragraph's nested styles reach, one after another from its start, then where its
  ## GREP styles match -- each a run of characters and the look it takes)
  var at = 0
  for ns in pp.nested:
    if at >= cps.len: break
    let count = max(1, ns.count)
    var e = at
    case ns.unit
    of nuChars: e = min(cps.len, at + count)
    of nuWords:
      var words = 0
      while e < cps.len and words < count:
        while e < cps.len and cps[e] in [32, 9]: inc e
        while e < cps.len and cps[e] notin [32, 9]: inc e
        inc words
    of nuSentences:
      var n = 0
      while e < cps.len and n < count:
        if cps[e] in [int('.'), int('!'), int('?'), 0x061F, 0x06D4]:
          inc n
          inc e
          while e < cps.len and cps[e] in [32, 9]: inc e
        else: inc e
    of nuUpTo:
      let target = if ns.upTo.len > 0: int(ns.upTo.runeAt(0)) else: 9
      var n = 0
      while e < cps.len:
        if cps[e] == target:
          inc n
          if n >= count:
            if ns.through: inc e
            break
        inc e
    if e > at and ns.name.len > 0: result.add (at, e, ns.look)   # ([None]: as the text is, up to there)
    at = e
  if grepHook != nil:
    for g in pp.grepStyles:
      if g.pattern.len == 0 or g.name.len == 0: continue
      for (a, b) in grepHook(g.pattern, cps):
        if b > a: result.add (a, b, g.look)

proc layoutPlain(t: TextData): TextLayout =
  for sp in t.spans:
    if sp.style.arabicFont != ScriptFont() or sp.style.latinFont != ScriptFont():
      return layoutPlain(scriptFontsApplied(t))
  if t.table.on and t.boxW > 0 and t.path.len == 0 and not t.vertical and t.spans.len > 0:
    return tableLaid(t)
  if t.para.dropLines >= 2 and t.para.list == lkNone and t.boxW > 0 and t.path.len == 0 and not t.vertical and
     t.spans.len > 0:
    return dropCapped(t)
  if t.para.list != lkNone and t.boxW > 0 and t.path.len == 0 and t.spans.len > 0:
    # a list: the text set standing in from one edge, then a mark before each paragraph
    var rtl = t.para.rtl == 2
    if t.para.rtl == 0:
      block strong:
        for s in t.spans:
          for r in s.text.runes:
            let c = int(r)
            if c in 0x0590 .. 0x08FF or c in 0xFB1D .. 0xFDFF or c in 0xFE70 .. 0xFEFF:
              rtl = true
              break strong
            if c in int('A') .. int('Z') or c in int('a') .. int('z') or c in 0xC0 .. 0x24F: break strong
    var u = t
    u.para.list = lkNone
    let room = if t.para.listIndent > 0: t.para.listIndent else: max(8'f32, t.spans[0].style.size * 1.7)
    if rtl: u.para.indentRight += room else: u.para.indentLeft += room
    result = layoutPlain(u)
    listMarks(t, result, rtl)
    return
  var styles: seq[CharStyle]
  var faces: seq[tuple[face: Face; fauxBold, fauxItalic: bool]]
  var chars: seq[CharInfo]
  var spanFmt: seq[int]          # (each span's paragraph format)
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
    spanFmt.add sp.style.para
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
  var paraNo = 0
  let spanW = if t.spanW > 0: t.spanW else: t.boxW
  while paraStart <= total:
    var paraEnd = paraStart
    while paraEnd < total and chars[paraEnd].cp != 10: inc paraEnd
    # (its format: its first letter's -- an empty paragraph's, its end's)
    let fmtAt = if paraStart < total: chars[paraStart].style elif total > 0: chars[total - 1].style else: -1
    var pp = if fmtAt >= 0 and fmtAt < spanFmt.len: t.fmtOf(spanFmt[fmtAt]) else: t.para
    if pp.styleName.len == 0 and fmtAt < 0: pp = t.para
    if paraStart >= total and total > 0 and t.tailFmt > 0: pp = t.fmtOf(t.tailFmt - 1)
    result.paras.add pp
    # (a paragraph across the columns: broken at the box's whole width; one split in columns of
    # its own: at theirs)
    let gutterW = if t.gutter > 0: t.gutter else: 12'f32
    let ownW = if pp.spanAll and t.columns > 1: spanW
               elif pp.splitColumns >= 2 and t.boxW > 0:
                 max(8'f32, (t.boxW - gutterW * float32(pp.splitColumns - 1)) / float32(pp.splitColumns))
               else: t.boxW
    # (its nested styles, then its GREP styles: the letters they reach take their looks)
    if (pp.nested.len > 0 or pp.grepStyles.len > 0) and paraEnd > paraStart:
      var cps = newSeq[int](paraEnd - paraStart)
      for k in paraStart ..< paraEnd: cps[k - paraStart] = chars[k].cp
      proc styleWith(look: CharStyle): int =
        var st = effective(look)
        st.para = 0
        for i, o in styles:
          if o == st: return i
        styles.add st
        var ff = fontFace(st.family, st.style)
        faces.add ff
        spanFmt.add 0
        styles.high
      for (a, b, look) in charStylesIn(cps, pp):
        let si = styleWith(look)
        for k in paraStart + a ..< paraStart + b: chars[k].style = si
    # the paragraph's characters: joined forms, bidi levels, glyphs, advances
    var s = ""
    for k in paraStart ..< paraEnd: s.add Rune(chars[k].cp).toUTF8
    let bi = bidiInfo(s, (if pp.rtl == 1: 0 elif pp.rtl == 2: 1 else: -1))
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
                    float32(st.tracking) / 1000 * st.size +
                    (if c.space: float32(st.wordSpace) / 1000 * st.size else: 0'f32)
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
          chars[j].parts.add GlyphPart(gid: g.gid,
                                       mark: fc.placesMark(g.gid) or
                                             (g.xAdv == 0 and j + 1 < e and isMark(chars[j + 1].cp)),
                                       dx: float32(g.xOff) * sc * st.hScale,
                                       dy: float32(g.yOff) * sc * st.vScale, adv: float32(g.xAdv) * sc * st.hScale)
        for j in k ..< e:
          var a = 0'f32
          for p in chars[j].parts: a += p.adv
          if chars[j].parts.len > 0:
            a += float32(st.tracking) / 1000 * st.size
            if chars[j].space: a += float32(st.wordSpace) / 1000 * st.size
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
    # (Justification: the spaces as wide as Word Spacing's "desired" says)
    let wsMin = if pp.wordSpacing == [0'i16, 0, 0]: 80'f32 else: float32(pp.wordSpacing[0])
    let wsDes = if pp.wordSpacing == [0'i16, 0, 0]: 100'f32 else: max(1'f32, float32(pp.wordSpacing[1]))
    let wsMax = if pp.wordSpacing == [0'i16, 0, 0]: 133'f32 else: float32(pp.wordSpacing[2])
    if wsDes != 100:
      for k in paraStart ..< paraEnd:
        if chars[k].space and chars[k].cp != 9: chars[k].adv *= wsDes / 100
    # lines: broken at spaces to fit the box
    let avail = if boxed: max(1'f32, ownW - pp.indentLeft - pp.indentRight) else: 1e9'f32
    # (round holes: each line broken when it is known where it lies, and how much room the
    # holes leave it there)
    let holed = boxed and t.holes.len > 0
    proc hyphenAdv(k: int): float32 =
      ## (a hyphen's width after character `k`, in its font)
      let c = chars[k]
      let (f, g) = pickGlyph(c.face, 0x2D)
      if g == 0: c.size * 0.33'f32
      else: float32(f.advance(g)) / float32(f.unitsPerEm) * c.size * styles[c.style].hScale
    template breakLine(ls: int; room: float32; whole = false): int =
      ## (where the line that starts at `ls` ends, `room` wide; `whole`:
      ## nothing of it when not a word of it fits; Hyphenate: the word that
      ## does not fit broken where it may be, a hyphen after it -- `hyphenAt`)
      var w = (if ls == paraStart: pp.indentFirst else: 0'f32)
      var k = ls
      var lastBreak = -1
      var wAtWord = w
      while k < paraEnd:
        if chars[k].space:
          lastBreak = k
          wAtWord = w + chars[k].adv
        if w + chars[k].adv > room and k > ls and not chars[k].space:
          break
        w += chars[k].adv
        inc k
      var cut = (if k >= paraEnd: paraEnd elif lastBreak >= ls: lastBreak + 1 elif whole: ls else: k)
      if pp.hyphenate and boxed and k < paraEnd and not rtlPara:
        # (the word at the break: its letters, a place in it that fits with a hyphen)
        let ws = if lastBreak >= ls: lastBreak + 1 else: ls
        var we = ws
        var word = ""
        while we < paraEnd and not chars[we].space and chars[we].cp != 10:
          let cp = chars[we].cp
          if cp < 128: word.add char(cp) else: word.add '?'
          inc we
        # (the word's letters without what is round them: "word," "(word")
        var w0 = 0
        var w1 = word.len
        while w0 < w1 and word[w0] notin {'a' .. 'z', 'A' .. 'Z'}: inc w0
        while w1 > w0 and word[w1 - 1] notin {'a' .. 'z', 'A' .. 'Z'}: dec w1
        if w1 - w0 >= 5:
          let pts = hyphenPoints(word[w0 ..< w1])
          var best = -1
          for p in pts:
            let at = ws + w0 + p
            var ww = (if lastBreak >= ls: wAtWord else: (if ls == paraStart: pp.indentFirst else: 0'f32))
            for q in ws ..< at: ww += chars[q].adv
            if ww + hyphenAdv(at - 1) <= room and at > ls: best = at
          if best > 0:
            cut = best
            hyphenAt[cut] = true
      cut
    var hyphenAt = newSeq[bool](paraEnd + 1)
    var lines: seq[(int, int)]
    var ls = paraStart
    let justified = pp.align in {justifyLeft, justifyCenter, justifyRight, justifyAll}
    let composed = boxed and not holed and paraEnd - paraStart > 1 and
                   (pp.composer == cpParagraph or (pp.composer == cpAuto and justified))
    if composed:
      # the Paragraph Composer: every way of breaking the paragraph weighed at once (Knuth and
      # Plass's): each line's spaces as near the wanted width as they can be, the lines alike,
      # few hyphens -- for Arabic, its kashidas counted as room too
      let kashidaRoom = rtlPara and not pp.noKashida and pp.kashida != kaNone
      var cands = @[(paraStart, false)]
      var k = paraStart
      while k < paraEnd:
        if chars[k].space:
          while k < paraEnd and chars[k].space: inc k
          if k < paraEnd: cands.add (k, false)
          continue
        # (a word: where it may be hyphenated)
        var we = k
        var word = ""
        while we < paraEnd and not chars[we].space:
          let cp = chars[we].cp
          if cp < 128: word.add char(cp) else: word.add '?'
          inc we
        if pp.hyphenate and not rtlPara:
          var w0 = 0
          var w1 = word.len
          while w0 < w1 and word[w0] notin {'a' .. 'z', 'A' .. 'Z'}: inc w0
          while w1 > w0 and word[w1 - 1] notin {'a' .. 'z', 'A' .. 'Z'}: dec w1
          if w1 - w0 >= 5:
            for hp in hyphenPoints(word[w0 ..< w1]): cands.add (k + w0 + hp, true)
        k = we
      cands.add (paraEnd, false)
      let nc = cands.len
      # (running sums: widths, the spaces' stretch and shrink, words)
      let n = paraEnd - paraStart
      var pw = newSeq[float32](n + 1)
      var pst = newSeq[float32](n + 1)
      var psh = newSeq[float32](n + 1)
      var pwd = newSeq[int](n + 1)
      for i in 0 ..< n:
        let c = chars[paraStart + i]
        pw[i + 1] = pw[i] + c.adv
        pst[i + 1] = pst[i]
        psh[i + 1] = psh[i]
        pwd[i + 1] = pwd[i]
        if c.space and c.cp != 9:
          pst[i + 1] += c.adv * max(0'f32, wsMax - wsDes) / wsDes
          psh[i + 1] += c.adv * max(0'f32, wsDes - wsMin) / wsDes
          inc pwd[i + 1]
      let em = if chars.len > paraStart: chars[paraStart].size else: 12'f32
      var best = newSeq[float](nc)
      var prev = newSeq[int](nc)
      var hyph = newSeq[bool](nc)
      for i in 1 ..< nc: best[i] = Inf
      for i in 0 ..< nc: hyph[i] = cands[i][1]
      for tol in [3.0, 12.0, 1e9]:
        for j in 1 ..< nc:
          best[j] = Inf
          prev[j] = -1
          let (bj, hj) = cands[j]
          # (the line ends before the spaces it was broken at)
          var e = bj
          while e > paraStart and chars[e - 1].space: dec e
          for i in countdown(j - 1, 0):
            if best[i] == Inf: continue
            let a0 = cands[i][0]
            if a0 >= e and bj < paraEnd: continue
            let first = a0 == paraStart
            var natural = pw[e - paraStart] - pw[a0 - paraStart] + (if first: pp.indentFirst else: 0'f32)
            if hj: natural += hyphenAdv(bj - 1)
            var stretch = pst[e - paraStart] - pst[a0 - paraStart]
            let shrink = psh[e - paraStart] - psh[a0 - paraStart]
            if kashidaRoom: stretch += em * 0.8'f32 * float32(pwd[e - paraStart] - pwd[a0 - paraStart] + 1)
            if natural - shrink > avail + 0.01: break       # (longer still from further back)
            let last = bj >= paraEnd
            var r = 0.0
            if natural < avail:
              r = if last and pp.align != justifyAll: 0.0
                  elif stretch > 1e-6: float(avail - natural) / stretch
                  else: (if justified: 50.0 else: float(avail - natural) / max(1'f32, avail) * 10)
            elif natural > avail: r = if shrink > 1e-6: float(avail - natural) / shrink else: -1e9
            if r < -1 or r > tol: continue
            var dm = (10 + 100 * pow(abs(r), 3)) ^ 2
            if hj: dm += 2500
            if hj and hyph[i]: dm += 3000                    # (two hyphens running)
            if best[i] + dm < best[j]:
              best[j] = best[i] + dm
              prev[j] = i
        if best[nc - 1] < Inf: break
      if best[nc - 1] < Inf:
        var path: seq[int]
        var j = nc - 1
        while j > 0:
          path.add j
          j = prev[j]
          if j < 0: break
        if j == 0:
          var a0 = paraStart
          for q in countdown(path.high, 0):
            let (bj, hj) = cands[path[q]]
            lines.add (a0, bj)
            if hj: hyphenAt[bj] = true
            a0 = bj
    if not holed and lines.len == 0:
      while true:
        let cut = breakLine(ls, avail)
        lines.add (ls, cut)
        if cut >= paraEnd: break
        ls = cut
    if paraStart != 0: penY += pp.spaceBefore
    var li = -1
    var segs: seq[tuple[x0, x1: float32]]     # (the rooms left of the line being filled, beside holes)
    while true:
      inc li
      var a, b: int
      var winL, winR, jump = 0'f32
      var sameBand = false                    # (it lies beside the line before it: a hole between them)
      if not holed:
        if li >= lines.len: break
        (a, b) = lines[li]
      else:
        if li > 0 and ls >= paraEnd: break
        # (where the line will lie, by its first letter: the room the holes leave it there;
        # too little, it goes down a line at a time until it has room)
        let st0 = if styles.len > 0: styles[if ls < total: chars[ls].style elif total > 0: chars[total - 1].style else: 0]
                  else: CharStyle()
        let size0 = if styles.len > 0: st0.size else: 36'f32
        let lead0 = max(1'f32, if styles.len > 0 and st0.leading > 0: st0.leading else: size0 * 1.2)
        let asc0 = size0 * 0.93'f32
        let desc0 = size0 * 0.24'f32
        let bx0 = t.x + pp.indentLeft
        let bx1 = t.x + ownW - pp.indentRight
        let least = min(bx1 - bx0, max(24'f32, size0 * 2))
        var y = 0'f32
        var haveY = false
        a = ls
        b = ls
        sameBand = segs.len > 0
        for attempt in 0 ..< 4000:
          if segs.len == 0:
            # (a line further down: the first, or the one before had no room for a word)
            if not haveY:
              y = if firstLine: t.y + asc0 else: penY + lead0
              haveY = true
            else:
              y += lead0
              jump += lead0
            sameBand = false
            segs = freeRooms(t.holes, y - asc0, y + desc0, bx0, bx1, least)
            if rtlPara: segs.reverse()
            if segs.len == 0: continue
          let seg = segs[0]
          segs.delete(0)
          winL = max(0'f32, seg.x0 - bx0)
          winR = max(0'f32, bx1 - seg.x1)
          # (beside a hole a word is not broken to fit: it goes to the next room)
          b = breakLine(ls, max(1'f32, avail - winL - winR), seg.x1 - seg.x0 < bx1 - bx0 - 0.5)
          if b > ls or ls >= paraEnd: break
        if b <= ls and ls < paraEnd:
          winL = 0
          winR = 0
          b = breakLine(ls, avail)
        ls = b
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
        # (a text of no spans at all has no style either: a box that takes what did not
        # fit another, when all of it fit)
        let st = if styles.len > 0: styles[if a < total: chars[a].style elif total > 0: chars[total - 1].style else: 0]
                 else: CharStyle()
        let size = if styles.len > 0: st.size else: 36'f32
        lead = if styles.len > 0 and st.leading > 0: st.leading else: size * 1.2
        asc = size * 0.93
        desc = size * 0.24
      # the first baseline: at y (point text) or under the box's top
      if sameBand: discard                  # (on the baseline of the line it lies beside)
      elif firstLine:
        penY = (if boxed: t.y + asc else: t.y) + jump
        firstLine = false
      else: penY += lead + jump             # (`jump`: moved down past a hole)
      if boxed and t.gridStep >= 2 and not sameBand:
        # (on the baseline grid: down to its next line)
        penY = t.gridStart + ceil((penY - t.gridStart - 0.01'f32) / t.gridStep) * t.gridStep
      # the width (spaces at the end not counted)
      var e = b
      while e > a and (chars[e - 1].space or chars[e - 1].cp == 10): dec e
      var width = 0'f32
      for k in a ..< e: width += chars[k].adv
      let hyphenated = b > a and b < hyphenAt.len and hyphenAt[b] and e == b
      if hyphenated: width += hyphenAdv(b - 1)
      let indent = pp.indentLeft + (if a == paraStart: pp.indentFirst else: 0'f32)
      let lastOfPara = if holed: b >= paraEnd else: li == lines.high
      let align = pp.align
      var extraPerSpace = 0'f32
      var startX: float32
      let firstInd = if a == paraStart: pp.indentFirst else: 0'f32
      # (right to left: the first line's indent is at the right, where lines start)
      let boxL = t.x + pp.indentLeft + (if rtlPara: 0'f32 else: firstInd) + winL
      let boxR = t.x + (if boxed: ownW - pp.indentRight - (if rtlPara: firstInd else: 0'f32) else: 0'f32) - winR
      let avail = avail - winL - winR       # (the room a hole leaves this line)
      let justify = boxed and (align == justifyAll or (align in {justifyLeft, justifyCenter, justifyRight} and
                                                        not lastOfPara))
      var spaces = 0
      var extraPerLetter = 0'f32
      var gScale = 1'f32
      if justify:
        var spaceW = 0'f32
        var letters = 0
        for k in a ..< e:
          if chars[k].space:
            inc spaces
            spaceW += chars[k].adv
          elif chars[k].cp != 10: inc letters
        let need = avail - (indent - pp.indentLeft) - width
        if spaces > 0:
          # (the spaces first, as far as Word Spacing's most -- less, as far as its least)
          let most = spaceW * max(0'f32, wsMax - wsDes) / wsDes
          let least = -spaceW * max(0'f32, wsDes - wsMin) / wsDes
          var fromSpaces = clamp(need, least, max(most, 0'f32))
          var left = need - fromSpaces
          if left > 0.01 and letters > 1:
            # (then between the letters, as far as Letter Spacing's most: % of a space)
            let lsMax = float32(pp.letterSpacing[2]) / 100 * (spaceW / spaces.float32)
            if lsMax > 0:
              extraPerLetter = min(left / float32(letters - 1), lsMax)
              left -= extraPerLetter * float32(letters - 1)
          if left > 0.01 and pp.glyphScaling[2] > 100:
            # (then the letters a little wider, as far as Glyph Scaling's most)
            let gmax = float32(pp.glyphScaling[2]) / 100
            var lw = 0'f32
            for k in a ..< e:
              if not chars[k].space and chars[k].cp != 10: lw += chars[k].adv
            if lw > 0:
              gScale = min(gmax, 1 + left / lw)
              left -= lw * (gScale - 1)
          if left > 0.01: fromSpaces += left      # (what is left: the spaces take it, past their most)
          extraPerSpace = fromSpaces / spaces.float32
          width += extraPerLetter * float32(max(0, letters - 1))
          if gScale != 1:
            for k in a ..< e:
              if not chars[k].space and chars[k].cp != 10: width += chars[k].adv * (gScale - 1)
      # (justified Arabic: lengthened at its joins first, with tatweel -- one
      # join a word, the best place in it; as long as Insert Kashida lets)
      var kashidaAt = newSeq[float32](b - a)
      let kl = if pp.noKashida: kaNone else: pp.kashida
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
          let room = max(0'f32, avail - (indent - pp.indentLeft) - width)
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
                 of textRight: t.x - lineW - (if rtlPara: pp.indentRight + firstInd else: 0'f32)
                 else: t.x + indent
      # the characters in the order shown
      var levels = newSeq[int8](b - a)
      for k in a ..< b: levels[k - a] = chars[k].level
      var order = visualOrderOf(levels)
      if order.len == 0:
        order = newSeq[int](b - a)
        for k in 0 ..< order.len: order[k] = k
      var x = startX
      # (right to left: the space the line was broken at is shown at its left end -- before
      # its letters, which start where the line does: the space hangs out of it there)
      for o in order:
        if a + o < e: break
        if chars[a + o].cp != 10: x -= chars[a + o].adv
      for o in order:
        let k = a + o
        let c = chars[k]
        let st = styles[c.style]
        if c.cp == 10: continue
        var adv = c.adv
        if c.space and k < e: adv += extraPerSpace
        elif gScale != 1 and k < e: adv *= gScale
        if not c.space and k < e - 1: adv += extraPerLetter
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
          let gs = if c.space: 1'f32 else: gScale
          for p in c.parts:
            if not c.space and not (p.mark and st.noMarks):
              result.glyphs.add LaidGlyph(face: c.face, gid: p.gid, x: px + p.dx * gs,
                                          y: y - p.dy - (if p.mark: st.markRaise else: 0'f32), size: c.size,
                                          hScale: st.hScale * gs, vScale: st.vScale,
                                          embolden: (if st.fauxBold or fb.fauxBold: max(0.6'f32, c.size / 28) else: 0'f32),
                                          shear: (if st.fauxItalic or fb.fauxItalic: 0.21'f32 else: 0'f32),
                                          color: (if p.mark and st.markColor != 0: st.markColor else: st.color),
                                          index: k, adv: p.adv * gs)
            px += p.adv * gs
        elif c.shown >= 0 and not c.space and not (st.noMarks and isMark(c.cp)):
          var shown = c.shown
          if rtlChar: shown = mirrored(shown)
          let (f, g) = if shown != c.shown: pickGlyph(c.face, shown) else: (c.face, c.gid)
          var y = penY - st.baselineShift
          if st.script == scSuper: y -= st.size * 0.333
          elif st.script == scSub: y += st.size * 0.15
          let fb = faces[c.style]
          let mk = isMark(c.cp)
          result.glyphs.add LaidGlyph(face: f, gid: g, x: x + c.markDx,
                                      y: y - c.markDy - (if mk: st.markRaise else: 0'f32), size: c.size,
                                      hScale: st.hScale * gScale,
                                      vScale: st.vScale,
                                      embolden: (if st.fauxBold or fb.fauxBold: max(0.6'f32, c.size / 28) else: 0'f32),
                                      shear: (if st.fauxItalic or fb.fauxItalic: 0.21'f32 else: 0'f32),
                                      color: (if mk and st.markColor != 0: st.markColor else: st.color),
                                      index: k, adv: adv)
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
      if hyphenated:
        # (the word broken here: its hyphen after it)
        let c = chars[b - 1]
        let st = styles[c.style]
        let (hf, hg) = pickGlyph(c.face, 0x2D)
        if hg != 0:
          result.glyphs.add LaidGlyph(face: hf, gid: hg, x: x, y: penY - st.baselineShift, size: c.size,
                                      hScale: st.hScale, vScale: st.vScale, color: st.color, index: b - 1,
                                      adv: hyphenAdv(b - 1))
      result.lines.add LaidLine(baseline: penY, ascent: asc, descent: desc, x0: startX, x1: startX + lineW,
                                first: a, last: b, rtl: rtlPara, para: paraNo)
      inc lineNo
    # the caret at the paragraph's end (before its new line, or the text's end)
    let ll = result.lines[^1]
    result.caretX[paraEnd] = if ll.rtl: ll.x0 else: ll.x1
    result.caretLine[paraEnd] = result.lines.high
    penY += pp.spaceAfter
    inc paraNo
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
  var bestX = 1e9'f32
  for k, ln in l.lines:
    let d = if y < ln.baseline - ln.ascent: ln.baseline - ln.ascent - y
            elif y > ln.baseline + ln.descent: y - ln.baseline - ln.descent
            else: 0'f32
    # (lines side by side -- a table's cells, beside a hole: the one under x)
    let dx = if x < ln.x0: ln.x0 - x elif x > ln.x1: x - ln.x1 else: 0'f32
    if d < best - 0.01 or (abs(d - best) <= 0.01 and dx < bestX):
      best = d
      bestX = dx
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

proc outlineOf(f: Face; gid, steps: int): seq[seq[(float32, float32)]] =
  ## A glyph's contours (kept: text is drawn again on each key typed).
  let key = (cast[pointer](f), gid, steps)
  if outlineCache.hasKey(key): return outlineCache[key]
  if outlineCache.len > 6000: outlineCache.clear()
  workerCaches()
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
  for dcr in l.backs:
    # (a table's fills, under its letters)
    let poly = @[(dcr.x0, dcr.y - dcr.thick / 2), (dcr.x1, dcr.y - dcr.thick / 2),
                 (dcr.x1, dcr.y + dcr.thick / 2), (dcr.x0, dcr.y + dcr.thick / 2)]
    result.add TextOutline(polys: @[poly], color: dcr.color)
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

proc inkTop(s: string; st: CharStyle): float32 =
  ## (how far the letters of `s` reach above their baseline)
  let t = newText(s, st, 0, 0)
  var top = 0'f32
  for o in textOutlines(t, layoutPlain(t)):
    for poly in o.polys:
      for p in poly: top = min(top, p[1])
  -top

proc dropCapped(t: TextData): TextLayout =
  ## (a drop cap: the first paragraph's first letters as tall as `dropLines` lines -- from the
  ## first line's capitals to the last one's baseline -- and the lines beside them standing in
  ## from them, at the right for right-to-left text)
  var u = t
  u.para.dropLines = 0
  result = layoutPlain(u)
  var cps: seq[int]
  for sp in t.spans:
    for r in sp.text.runes:
      cps.add int(r)
      if cps.len > 20: break
  var n = min(max(1, t.para.dropChars), cps.len)
  for k in 0 ..< n:
    if cps[k] == 10:
      n = k
      break
  if n == 0 or result.lines.len == 0 or cps[0] == 32: return
  let lines = clamp(t.para.dropLines, 2, 20)
  let b0 = result.lines[0].baseline
  let lead = if result.lines.len > 1: result.lines[1].baseline - b0
             else: (let s0 = t.styleAt(0); if s0.leading > 0: s0.leading else: max(1'f32, s0.size) * 1.2)
  let bN = b0 + lead * float32(lines - 1)
  let rtl = result.lines[0].rtl
  var st = t.styleAt(0)
  st.underline = false
  st.strike = false
  st.baselineShift = 0
  st.script = scNormal
  var dropS = ""
  for k in 0 ..< n: dropS.add Rune(cps[k])
  let capBody = inkTop("H", st)
  let ink1 = inkTop(dropS, st)
  if ink1 <= 0 or capBody <= 0: return
  let size = clamp(st.size * (bN - b0 + capBody) / ink1, st.size, st.size * 30)
  var big = st
  big.size = size
  big.leading = 0
  var dt = newText(dropS, big, 0, 0)
  dt.para.rtl = if rtl: 2 else: 1
  let ml = layoutPlain(dt)
  if ml.lines.len == 0: return
  let w = ml.x1 - ml.x0
  let gap = max(2'f32, st.size * 0.3)
  let bx0 = t.x + t.para.indentLeft
  let bx1 = t.x + t.boxW - t.para.indentRight
  let top = b0 - result.lines[0].ascent - 1
  # (the letters kept in the text, as wide as nothing; the lines keeping out of where they are drawn)
  var v = u
  v.splitAt(n)
  var at = 0
  for sp in v.spans.mitems:
    if at < n:
      sp.style.hScale = 0.0001
      sp.style.tracking = 0
      sp.style.underline = false
      sp.style.strike = false
    at += sp.text.runeLen
  let hole: TextHole = if rtl: (x0: bx1 - w - gap, y0: top, x1: bx1 + 1, y1: bN + 1)
                       else: (x0: bx0 - 1, y0: top, x1: bx0 + w + gap, y1: bN + 1)
  v.holes.add hole
  var lay = layoutPlain(v)
  var kept: seq[LaidGlyph]
  for g in lay.glyphs:
    if g.index >= n: kept.add g
  let dx = if rtl: bx1 - ml.x1 else: bx0 - ml.x0
  for g in ml.glyphs:
    var g2 = g
    g2.x += dx
    g2.y += bN
    kept.add g2
  lay.glyphs = move kept
  lay.x0 = min(lay.x0, ml.x0 + dx)
  lay.x1 = max(lay.x1, ml.x1 + dx)
  lay.y0 = min(lay.y0, bN - (ml.lines[0].ascent))
  result = lay


# ---- tables --------------------------------------------------------------------------------------------------

proc tableTheme*(name: string): TableStyle =
  ## A table's look by its theme's name (`tableThemes`); "" or one not
  ## known: lines round every cell, nothing filled.
  result = TableStyle(on: true, headerRows: 1, headerBold: true, border: 0xFF333333'u32, borderW: 1,
                      inner: true, theme: name)
  case name
  of "Striped Blue":
    result.headerFill = 0xFF1F4E79'u32
    result.headerColor = 0xFFFFFFFF'u32
    result.altFill = 0xFFDDEBF7'u32
    result.border = 0xFF9DC3E6'u32
    result.inner = false
    result.rowLines = true
  of "Dark Header":
    result.headerFill = 0xFF222222'u32
    result.headerColor = 0xFFFFFFFF'u32
    result.border = 0xFFBBBBBB'u32
  of "Minimal":
    result.border = 0xFF999999'u32
    result.inner = false
    result.rowLines = true
  of "Warm Paper":
    result.headerFill = 0xFFE9C46A'u32
    result.headerColor = 0xFF264653'u32
    result.fill = 0xFFFFF8E7'u32
    result.altFill = 0xFFF4E9CF'u32
    result.border = 0xFFC9A66B'u32
  of "Green Ledger":
    result.headerFill = 0xFF2A9D8F'u32
    result.headerColor = 0xFFFFFFFF'u32
    result.altFill = 0xFFE3F4F1'u32
    result.border = 0xFF2A9D8F'u32
    result.inner = false
    result.rowLines = true
    result.numbersRight = true
  of "Gold":
    result.headerFill = 0xFF8C6D1F'u32
    result.headerColor = 0xFFFFF4D6'u32
    result.fill = 0xFFFFFBF0'u32
    result.border = 0xFFC8A951'u32
    result.borderW = 1.5
  of "Red Accent":
    result.headerFill = 0xFFC0392B'u32
    result.headerColor = 0xFFFFFFFF'u32
    result.altFill = 0xFFFBEAE8'u32
    result.border = 0
    result.inner = false
  of "Night":
    result.headerFill = 0xFF0B132B'u32
    result.headerColor = 0xFF5BC0BE'u32
    result.fill = 0xFF1C2541'u32
    result.altFill = 0xFF3A506B'u32
    result.border = 0xFF5BC0BE'u32
    result.bodyColor = 0xFFE8EEF5'u32
  else:
    result.theme = if name.len > 0: "Plain Grid" else: ""

const tableThemes* = ["Plain Grid", "Striped Blue", "Dark Header", "Minimal", "Warm Paper", "Green Ledger",
                      "Gold", "Red Accent", "Night"]
  ## The themes a table can have (`tableTheme`).

proc cellOf(t: TextData; a, b: int): TextData =
  ## (characters `a` ..< `b` of the text, with their styles, as a text of its own)
  result = t
  result.spans = @[]
  var at = 0
  for sp in t.spans:
    let n = sp.text.runeLen
    let lo = max(a, at)
    let hi = min(b, at + n)
    if hi > lo: result.spans.add TextSpan(text: sp.text.runeSubStr(lo - at, hi - lo), style: sp.style)
    at += n
  if result.spans.len == 0: result.spans.add TextSpan(text: "", style: t.styleAt(a))

proc looksNumeric*(t: TextData): bool =
  ## A table's cell that says a number: digits (Arabic-Indic too), with signs, separators, a
  ## currency or % -- set at its right when the table says so.
  var digits = 0
  for sp in t.spans:
    for r in sp.text.runes:
      let c = int(r)
      if c in int('0') .. int('9') or c in 0x0660 .. 0x0669 or c in 0x06F0 .. 0x06F9: inc digits
      elif c in [int(' '), int(','), int('.'), int('-'), int('+'), int('%'), int('$'), 0x066B, 0x066C,
                 0x20AC, 0x00A3, 0x00A5]: discard
      else: return false
  digits > 0

proc tableLaid(t: TextData): TextLayout =
  ## (a table: each paragraph a row, tabs between cells, each cell's text laid out in its
  ## column; the rows as tall as their tallest cell; fills under the letters, lines over)
  var cps: seq[int]
  for sp in t.spans:
    for r in sp.text.runes: cps.add int(r)
  let total = cps.len
  var rows: seq[seq[(int, int)]]
  var cur: seq[(int, int)]
  var cs = 0
  for i in 0 .. total:
    if i == total or cps[i] == 10 or cps[i] == 9:
      cur.add (cs, i)
      cs = i + 1
      if i == total or cps[i] == 10:
        rows.add cur
        cur = @[]
  # (a text ending with a new line: no empty row after it)
  if rows.len > 1 and total > 0 and cps[^1] == 10 and rows[^1].len == 1: rows.setLen(rows.len - 1)
  var ncol = 1
  for r in rows: ncol = max(ncol, r.len)
  let ts = t.table
  let st0 = effective(t.styleAt(0))
  let pad = if ts.pad > 0: ts.pad else: max(2'f32, st0.size / 3)
  let bw = if ts.borderW > 0: ts.borderW else: 1'f32
  # (right to left: the first column at the right)
  var rtl = t.para.rtl == 2
  if t.para.rtl == 0:
    block strong:
      for c in cps:
        if c in 0x0590 .. 0x08FF or c in 0xFB1D .. 0xFDFF or c in 0xFE70 .. 0xFEFF:
          rtl = true
          break strong
        if c in int('A') .. int('Z') or c in int('a') .. int('z') or c in 0xC0 .. 0x24F: break strong
  var parts = newSeq[float32](ncol)
  var sum = 0'f32
  for c in 0 ..< ncol:
    parts[c] = if c < ts.widths.len and ts.widths[c] > 0: ts.widths[c] else: 0'f32
    sum += parts[c]
  var known = 0
  for p in parts:
    if p > 0: inc known
  let avg = if known > 0: sum / known.float32 else: 1'f32
  sum = 0
  for p in parts.mitems:
    if p <= 0: p = avg
    sum += p
  let tx0 = t.x + t.para.indentLeft
  let tw = max(8'f32, t.boxW - t.para.indentLeft - t.para.indentRight)
  var colX = newSeq[float32](ncol + 1)
  colX[0] = tx0
  for c in 0 ..< ncol: colX[c + 1] = colX[c] + tw * parts[c] / sum
  result.caretX = newSeq[float32](total + 1)
  result.caretLine = newSeq[int](total + 1)
  result.overflow = -1
  var y = t.y
  var rowYs = @[y]
  for r, row in rows:
    let header = r < ts.headerRows
    var lays: seq[(TextLayout, int, int)]
    var rowH = st0.size * 1.2'f32 + 2 * pad
    for c in 0 ..< row.len:
      let (a, b) = row[c]
      var u = cellOf(t, a, b)
      u.table = TableStyle()
      u.para.dropLines = 0
      u.para.list = lkNone
      u.holes = @[]
      u.columns = 1
      u.fit = false
      u.clipOverflow = false
      u.gridStep = 0
      u.para.indentLeft = 0
      u.para.indentRight = 0
      u.para.spaceBefore = 0
      u.para.spaceAfter = 0
      if header:
        for sp in u.spans.mitems:
          if ts.headerColor != 0: sp.style.color = ts.headerColor
          if ts.headerBold: sp.style.fauxBold = true
      elif ts.bodyColor != 0:
        for sp in u.spans.mitems: sp.style.color = ts.bodyColor
      if rtl: u.para.rtl = 2                  # (every cell right to left: its numbers too)
      let vc = if rtl: ncol - 1 - c else: c
      u.x = colX[vc] + pad
      u.y = y + pad
      u.boxW = max(4'f32, colX[vc + 1] - colX[vc] - 2 * pad)
      u.boxH = 1e6
      if ts.numbersRight and not header and looksNumeric(u): u.para.align = (if rtl: textLeft else: textRight)
      let l = layoutPlain(u)
      if l.lines.len > 0: rowH = max(rowH, l.y1 - y + pad)
      lays.add (l, a, b)
    let f = if header and ts.headerFill != 0: ts.headerFill
            elif ts.altFill != 0 and (r - ts.headerRows) mod 2 == 1: ts.altFill
            else: ts.fill
    if f != 0:
      result.backs.add Decoration(x0: colX[0], x1: colX[ncol], y: y + rowH / 2, thick: rowH, color: f)
    for (l, a, b) in lays:
      let base = result.lines.len
      for g in l.glyphs:
        var g2 = g
        g2.index += a
        result.glyphs.add g2
      for d in l.decorations: result.decorations.add d
      for ln in l.lines:
        var l2 = ln
        l2.first += a
        l2.last += a
        result.lines.add l2
      for k in 0 .. b - a:
        if k < l.caretX.len:
          result.caretX[a + k] = l.caretX[k]
          result.caretLine[a + k] = base + (if k < l.caretLine.len: l.caretLine[k] else: 0)
    y += rowH
    rowYs.add y
  # the lines: round the table, under the header, between the rows or all the cells
  if ts.border != 0:
    proc hline(res: var TextLayout; yy: float32) =
      res.decorations.add Decoration(x0: colX[0] - bw / 2, x1: colX[ncol] + bw / 2, y: yy, thick: bw,
                                     color: ts.border)
    proc vline(res: var TextLayout; xx: float32) =
      res.decorations.add Decoration(x0: xx - bw / 2, x1: xx + bw / 2, y: (rowYs[0] + rowYs[^1]) / 2,
                                     thick: rowYs[^1] - rowYs[0] + bw, color: ts.border)
    result.hline(rowYs[0])
    result.hline(rowYs[^1])
    for k in 1 ..< rowYs.high:
      if ts.inner or ts.rowLines or k == ts.headerRows: result.hline(rowYs[k])
    if ts.inner or not ts.rowLines:
      result.vline(colX[0])
      result.vline(colX[ncol])
    if ts.inner:
      for c in 1 ..< ncol: result.vline(colX[c])
  result.x0 = colX[0]
  result.x1 = colX[ncol]
  result.y0 = t.y
  result.y1 = y
  if result.lines.len == 0:
    result.lines.add LaidLine(baseline: t.y + st0.size, ascent: st0.size, descent: st0.size / 4,
                              x0: colX[0], x1: colX[0])

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
  if st.wordSpace != 0: result["wordSpace"] = %st.wordSpace
  if st.markColor != 0: result["markColor"] = %int64(st.markColor)
  if st.markRaise != 0: result["markRaise"] = %st.markRaise
  if st.noMarks: result["noMarks"] = %true
  for (k, f) in [("arabicFont", st.arabicFont), ("latinFont", st.latinFont)]:
    if f != ScriptFont():
      result[k] = %*{"family": f.family, "style": f.style, "scale": f.scale, "shift": f.shift,
                     "color": int64(f.color), "tracking": f.tracking}
  if st.variation.len > 0: result["variation"] = %st.variation
  if st.styleName.len > 0: result["styleName"] = %st.styleName
  if st.para != 0: result["para"] = %st.para
  if st.link.len > 0: result["link"] = %st.link

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
  result.wordSpace = clamp(int(j.getF("wordSpace")), -1000, 10_000)
  result.markColor = uint32(int64(j.getF("markColor")) and 0xFFFFFFFF'i64)
  result.markRaise = float32(j.getF("markRaise"))
  result.noMarks = j.getB("noMarks")
  result.variation = j.getS("variation")
  result.styleName = j.getS("styleName")
  result.para = clamp(int(j.getF("para")), 0, 100_000)
  result.link = j.getS("link")
  if result.link.len > 4096: result.link.setLen(0)
  for (k, f) in [("arabicFont", addr result.arabicFont), ("latinFont", addr result.latinFont)]:
    if j.hasKey(k) and j[k].kind == JObject:
      let o = j[k]
      f[] = ScriptFont(family: o.getS("family"), style: o.getS("style"),
                       scale: clamp(float32(o.getF("scale")), 0, 10), shift: clamp(float32(o.getF("shift")), -1000, 1000),
                       color: uint32(int64(o.getF("color")) and 0xFFFFFFFF'i64),
                       tracking: clamp(int(o.getF("tracking")), -1000, 10_000))

proc listToJson(p: ParaStyle; j: JsonNode)
proc dropToJson(p: ParaStyle; j: JsonNode)
proc tableToJson(ts: TableStyle): JsonNode
proc tableFrom(j: JsonNode): TableStyle
proc listFrom(p: var ParaStyle; j: JsonNode)
proc paraToJson*(p: ParaStyle): JsonNode
proc paraFrom*(j: JsonNode): ParaStyle

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
  listToJson(t.para, result["para"])
  dropToJson(t.para, result["para"])
  if t.boxW > 0:
    result["boxW"] = %t.boxW
    result["boxH"] = %t.boxH
  if t.vertical: result["vertical"] = %true
  if t.fit: result["fit"] = %true
  if t.columns > 1: result["columns"] = %t.columns
  if t.gutter > 0: result["gutter"] = %t.gutter
  if t.clipOverflow: result["clipOverflow"] = %true
  if t.paraFmts.len > 0:
    var a = newJArray()
    for f in t.paraFmts: a.add paraToJson(f)
    result["paraFmts"] = a
  if t.tailFmt > 0: result["tailFmt"] = %t.tailFmt
  if t.inset != [0'f32, 0, 0, 0]: result["inset"] = %[t.inset[0], t.inset[1], t.inset[2], t.inset[3]]
  if t.vjust != vjTop: result["vjust"] = %($t.vjust)
  if t.balance: result["balance"] = %true
  if t.autoSize != asOff:
    result["autoSize"] = %($t.autoSize)
    result["autoRef"] = %t.autoRef
  if t.table.on: result["table"] = tableToJson(t.table)
  if t.notes.len > 0:
    var ns = newJArray()
    for n in t.notes: ns.add %*{"id": n.id, "text": n.text}
    result["notes"] = ns
    let o = t.noteOpts
    result["noteOpts"] = %*{"kind": $o.kind, "numbers": $o.numbers, "start": o.start, "prefix": o.prefix,
                            "suffix": o.suffix, "separator": o.separator, "scale": o.scale,
                            "refScale": o.refScale, "noRule": o.noRule, "ruleWidth": o.ruleWidth,
                            "ruleLength": o.ruleLength, "ruleColor": o.ruleColor, "gap": o.gap,
                            "heading": o.heading}
  if t.gridStep > 0:
    result["gridStep"] = %t.gridStep
    result["gridStart"] = %t.gridStart
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
    for s in j{"spans"}.getElems:
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
  for f in j{"paraFmts"}.getElems:
    if result.paraFmts.len >= 100_000: break
    result.paraFmts.add paraFrom(f)
  let ins = j{"inset"}
  if ins != nil and ins.kind == JArray and ins.len == 4:
    for q in 0 .. 3: result.inset[q] = clamp(float32(ins[q].getFloat), 0, 10_000)
  result.tailFmt = clamp(int(j.getF("tailFmt")), 0, result.paraFmts.len + 1)
  result.vjust = enumOf(j.getS("vjust"), vjTop)
  result.balance = j.getB("balance")
  for a in TextAutoSize:
    if j{"autoSize"}.getStr == $a: result.autoSize = a
  result.autoRef = clamp(j{"autoRef"}.getInt(0), 0, 8)
  result.gridStep = clamp(float32(j.getF("gridStep")), 0, 10_000)
  if j.hasKey("table"): result.table = tableFrom(j["table"])
  result.gridStart = clamp(float32(j.getF("gridStart")), -100_000, 100_000)
  for nj in j{"notes"}.getElems:
    if result.notes.len >= 65533: break
    let id = nj{"id"}.getInt(0)
    if id in 1 .. 65533: result.notes.add Footnote(id: id, text: nj{"text"}.getStr)
  if j.hasKey("noteOpts") and j["noteOpts"].kind == JObject:
    let o = j["noteOpts"]
    template en(T: typedesc; k: string; v: untyped) =
      for e in T:
        if $e == o{k}.getStr: v = e
    en(NoteKind, "kind", result.noteOpts.kind)
    en(NumberStyle, "numbers", result.noteOpts.numbers)
    result.noteOpts.start = clamp(o{"start"}.getInt(0), 0, 100_000)
    result.noteOpts.prefix = o{"prefix"}.getStr
    result.noteOpts.suffix = o{"suffix"}.getStr
    result.noteOpts.separator = o{"separator"}.getStr
    result.noteOpts.scale = clamp(float32(o.getF("scale")), 0, 4)
    result.noteOpts.refScale = clamp(float32(o.getF("refScale")), 0, 4)
    result.noteOpts.noRule = o{"noRule"}.getBool
    result.noteOpts.ruleWidth = clamp(float32(o.getF("ruleWidth")), 0, 100)
    result.noteOpts.ruleLength = clamp(float32(o.getF("ruleLength")), 0, 1)
    result.noteOpts.ruleColor = uint32(clamp(o{"ruleColor"}.getBiggestInt(0), 0, 0xFFFFFFFF'i64))
    result.noteOpts.gap = clamp(float32(o.getF("gap")), 0, 10_000)
    result.noteOpts.heading = o{"heading"}.getStr
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
    listFrom(result.para, p)
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

proc listToJson(p: ParaStyle; j: JsonNode) =
  ## (a list's settings into a paragraph's JSON: there only for a list)
  if p.list == lkNone: return
  j["list"] = %ord(p.list)
  if p.listMark.len > 0: j["listMark"] = %p.listMark
  if p.listNumbers != nsDigits: j["listNumbers"] = %ord(p.listNumbers)
  if p.listStart != 0: j["listStart"] = %p.listStart
  if p.listSuffix.len > 0: j["listSuffix"] = %p.listSuffix
  if p.listColor != 0: j["listColor"] = %int64(p.listColor)
  if p.listIndent != 0: j["listIndent"] = %p.listIndent

proc tableToJson(ts: TableStyle): JsonNode =
  result = %*{"headerRows": ts.headerRows, "headerFill": int64(ts.headerFill),
              "headerColor": int64(ts.headerColor), "headerBold": ts.headerBold, "fill": int64(ts.fill),
              "bodyColor": int64(ts.bodyColor),
              "altFill": int64(ts.altFill), "border": int64(ts.border), "borderW": ts.borderW,
              "inner": ts.inner, "rowLines": ts.rowLines, "pad": ts.pad, "numbersRight": ts.numbersRight,
              "theme": ts.theme}
  var ws = newJArray()
  for w in ts.widths: ws.add %w
  result["widths"] = ws

proc tableFrom(j: JsonNode): TableStyle =
  if j == nil or j.kind != JObject: return
  template c(k: string): uint32 = uint32(int64(j.getF(k)) and 0xFFFFFFFF'i64)
  result = TableStyle(on: true, headerRows: clamp(int(j.getF("headerRows")), 0, 100), headerFill: c("headerFill"),
                      headerColor: c("headerColor"), headerBold: j.getB("headerBold"), fill: c("fill"),
                      bodyColor: c("bodyColor"),
                      altFill: c("altFill"), border: c("border"), borderW: clamp(float32(j.getF("borderW")), 0, 100),
                      inner: j.getB("inner"), rowLines: j.getB("rowLines"),
                      pad: clamp(float32(j.getF("pad")), 0, 1000), numbersRight: j.getB("numbersRight"),
                      theme: j.getS("theme"))
  if j.hasKey("widths") and j["widths"].kind == JArray:
    for w in j["widths"].elems:
      if result.widths.len < 200 and w.kind in {JInt, JFloat}: result.widths.add clamp(float32(w.getFloat), 0, 1000)

proc composeToJson(p: ParaStyle; j: JsonNode) =
  ## (the composer, justification, keep options, columns, next style, nested and GREP styles:
  ## there only when they are not their defaults)
  if p.composer != cpAuto: j["composer"] = %($p.composer)
  for (k, a) in [("wordSpacing", p.wordSpacing), ("letterSpacing", p.letterSpacing),
                 ("glyphScaling", p.glyphScaling)]:
    if a != [0'i16, 0, 0]: j[k] = %[int(a[0]), int(a[1]), int(a[2])]
  if p.keepWithNext > 0: j["keepWithNext"] = %p.keepWithNext
  if p.keepTogether: j["keepTogether"] = %true
  if p.keepStart > 0: j["keepStart"] = %p.keepStart
  if p.keepEnd > 0: j["keepEnd"] = %p.keepEnd
  if p.startAt != psAnywhere: j["startAt"] = %($p.startAt)
  if p.spanAll: j["spanAll"] = %true
  if p.splitColumns >= 2: j["splitColumns"] = %p.splitColumns
  if p.nextStyle.len > 0: j["nextStyle"] = %p.nextStyle
  if p.nested.len > 0:
    var a = newJArray()
    for n in p.nested:
      a.add %*{"name": n.name, "look": n.look.toJson, "count": n.count, "unit": $n.unit, "upTo": n.upTo,
               "through": n.through}
    j["nested"] = a
  if p.grepStyles.len > 0:
    var a = newJArray()
    for g in p.grepStyles: a.add %*{"name": g.name, "look": g.look.toJson, "pattern": g.pattern}
    j["grep"] = a

proc composeFrom(p: var ParaStyle; j: JsonNode) =
  p.composer = enumOf(j.getS("composer"), cpAuto)
  for (k, a) in [("wordSpacing", addr p.wordSpacing), ("letterSpacing", addr p.letterSpacing),
                 ("glyphScaling", addr p.glyphScaling)]:
    let e = j{k}
    if e != nil and e.kind == JArray and e.len == 3:
      for q in 0 .. 2: a[][q] = int16(clamp(e[q].getInt(0), -1000, 1000))
  p.keepWithNext = clamp(int(j.getF("keepWithNext")), 0, 50)
  p.keepTogether = j.getB("keepTogether")
  p.keepStart = clamp(int(j.getF("keepStart")), 0, 50)
  p.keepEnd = clamp(int(j.getF("keepEnd")), 0, 50)
  p.startAt = enumOf(j.getS("startAt"), psAnywhere)
  p.spanAll = j.getB("spanAll")
  p.splitColumns = clamp(int(j.getF("splitColumns")), 0, 20)
  p.nextStyle = j.getS("nextStyle")
  for n in j{"nested"}.getElems:
    if p.nested.len >= 50: break
    p.nested.add NestedStyle(name: n.getS("name"), look: charStyleFrom(n{"look"}),
                             count: clamp(int(n.getF("count")), 0, 10_000), unit: enumOf(n.getS("unit"), nuWords),
                             upTo: n.getS("upTo"), through: n.getB("through"))
  for g in j{"grep"}.getElems:
    if p.grepStyles.len >= 50: break
    p.grepStyles.add GrepStyle(name: g.getS("name"), look: charStyleFrom(g{"look"}), pattern: g.getS("pattern"))

proc dropToJson(p: ParaStyle; j: JsonNode) =
  if p.hyphenate: j["hyphenate"] = %true
  if p.gridAlign: j["gridAlign"] = %true
  composeToJson(p, j)
  if p.dropLines < 2: return
  j["dropLines"] = %p.dropLines
  if p.dropChars > 1: j["dropChars"] = %p.dropChars

proc listFrom(p: var ParaStyle; j: JsonNode) =
  p.list = ListKind(clamp(int(j.getF("list")), 0, ord(high(ListKind))))
  p.listMark = j.getS("listMark")
  if p.listMark.len > 64: p.listMark.setLen(0)
  p.listNumbers = NumberStyle(clamp(int(j.getF("listNumbers")), 0, ord(high(NumberStyle))))
  p.listStart = clamp(int(j.getF("listStart")), 0, 1_000_000)
  p.listSuffix = j.getS("listSuffix")
  if p.listSuffix.len > 16: p.listSuffix.setLen(0)
  p.listColor = uint32(int64(j.getF("listColor")) and 0xFFFFFFFF'i64)
  p.listIndent = clamp(float32(j.getF("listIndent")), 0, 4000)
  p.dropLines = clamp(int(j.getF("dropLines")), 0, 20)
  p.dropChars = clamp(int(j.getF("dropChars")), 0, 20)
  p.hyphenate = j{"hyphenate"}.getBool
  p.gridAlign = j{"gridAlign"}.getBool
  composeFrom(p, j)

proc paraToJson*(p: ParaStyle): JsonNode =
  ## A paragraph style as JSON (Paragraph Styles kept in a document).
  result = %*{"align": $p.align, "indentLeft": p.indentLeft, "indentRight": p.indentRight,
              "indentFirst": p.indentFirst, "spaceBefore": p.spaceBefore, "spaceAfter": p.spaceAfter,
              "rtl": p.rtl, "noKashida": p.noKashida, "kashida": $p.kashida, "styleName": p.styleName}
  listToJson(p, result)
  dropToJson(p, result)

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
  listFrom(result, j)

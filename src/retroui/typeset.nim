## Text layout: the fonts, Arabic letter joining, right-to-left text and
## the icon font.
##
## Every string is turned into a `Run`: glyphs from the faces, in visual
## order, with their positions in em units (so one run serves every size).
## Arabic letters take their joined forms (and lam + alef its ligature),
## mixed Arabic/Latin lines follow the Unicode bidirectional algorithm
## (paragraph direction from the first strong letter), and characters a
## face lacks come from the others: Arabic from FreeSerif (its bold for
## bold text), symbols from the regular of the family, then FreeSans and
## FreeSerif, icons from the Nerd Fonts symbols.
##
## The faces are GNU FreeFont -- FreeSans, FreeSerif and FreeMono, each in
## its regular, bold, italic (oblique) and bold italic -- built into every
## app (`tools/genfreefont.py` cuts them down), and a font from a file
## (`fUser`). A style a font does not have is made from its regular
## (`fauxStyle`).

import std/[tables, unicode, locks, algorithm]
import ttf, arabicdata, codec

type
  FaceId* = enum
    fSans, fSansBold, fSansItalic, fSansBoldItalic,       ## FreeSans (Oblique, Bold Oblique)
    fSerif, fSerifBold, fSerifItalic, fSerifBoldItalic,   ## FreeSerif
    fMono, fMonoBold, fMonoItalic, fMonoBoldItalic,       ## FreeMono (Oblique, Bold Oblique)
    fUser, fUserBold, fUserItalic, fUserBoldItalic,       ## a font from a file (`setUserFont`)
    fIcons                                                ## the icons (Nerd Fonts symbols)

  PGlyph* = object
    ## A shaped glyph: from which face, which glyph, where.
    face*: FaceId            ## the face it comes from (a fallback's for a missing letter)
    gid*: uint16             ## its glyph number in that face
    x*, y*: float32          ## em units from the run's start; y is up

  Run* = object
    glyphs*: seq[PGlyph]
    width*: float32          ## em units
    missing*: bool           ## a character no face has
    rtl*: bool               ## the text reads right to left

const
  faceFiles: array[fSans .. fMonoBoldItalic, string] = [
    "FreeSans", "FreeSansBold", "FreeSansOblique", "FreeSansBoldOblique",
    "FreeSerif", "FreeSerifBold", "FreeSerifItalic", "FreeSerifBoldItalic",
    "FreeMono", "FreeMonoBold", "FreeMonoOblique", "FreeMonoBoldOblique"]
  iconsPacked = staticRead("fonts/Icons.ttf.z")
  IconCell = 1.25'f32        ## icons sit centered in cells this many ems wide
  FauxBoldEm* = 1'f32 / 24   ## a style made bold: its strokes this much thicker, its letters wider
  TabStops = 4               ## a tab is this many spaces wide

when defined(wasm):
  # (a web page: the fonts are files beside the page, fetched when a face
  # is first used -- a PDF, the canvas's text; the page's own text is the
  # browser's -- so an app's WebAssembly does not carry their 0.94 MB)
  proc packedFont(id: FaceId): string =
    try: readFile("/kit/fonts/" & faceFiles[id] & ".ttf.z")
    except IOError, OSError: ""
else:
  const retroFonts {.strdefine.} = "all"
    ## Which faces are built into the program (`-d:retroFonts=...`):
    ## "all" (the twelve: 0.94 MB), "sans" (FreeSans's four: 0.23 MB),
    ## "ui" (FreeSans and its bold: 0.13 MB), "none". The others are read
    ## from `fonts/` beside the program (or $RETRO_FONTS) when they are
    ## there -- the .ttf.z files of src/retroui/fonts -- else drawn with
    ## FreeSans in the same style. Arabic comes from FreeSerif: an app in
    ## Arabic keeps "all", or FreeSerif's files beside it.
  const builtin: set[FaceId] =
    when retroFonts == "all": {fSans .. fMonoBoldItalic}
    elif retroFonts == "sans": {fSans .. fSansBoldItalic}
    elif retroFonts == "ui": {fSans, fSansBold}
    elif retroFonts == "none": {}
    else: {.error: "retroFonts: all, sans, ui or none (not " & retroFonts & ")".}

  proc packedAt(id: FaceId): string {.compileTime.} =
    if id in builtin: staticRead("fonts/" & faceFiles[id] & ".ttf.z") else: ""

  const
    fontPacked: array[fSans .. fMonoBoldItalic, string] =
      # the fonts, zlib-compressed (tools/genfreefont.py): 1.6 MB of TrueType
      # take 0.94 MB in every app, and a face is unpacked when it is first used
      [packedAt(fSans), packedAt(fSansBold), packedAt(fSansItalic), packedAt(fSansBoldItalic),
       packedAt(fSerif), packedAt(fSerifBold), packedAt(fSerifItalic), packedAt(fSerifBoldItalic),
       packedAt(fMono), packedAt(fMonoBold), packedAt(fMonoItalic), packedAt(fMonoBoldItalic)]

  when builtin == {fSans .. fMonoBoldItalic}:
    proc packedFont(id: FaceId): string = fontPacked[id]
  else:
    import std/os

    proc packedFont(id: FaceId): string =
      ## (a face left out: its file beside the program, else FreeSans's
      ## face of the same style, else FreeSans)
      if id in builtin: return fontPacked[id]
      for dir in [getEnv("RETRO_FONTS"), getAppDir() / "fonts", getAppDir() / ".." / "share" / "retroui" / "fonts"]:
        if dir.len == 0: continue
        let f = dir / faceFiles[id] & ".ttf.z"
        if fileExists(f):
          try: return readFile(f)
          except IOError, OSError: discard
      let same = FaceId(ord(id) mod 4)                    # (FreeSans in this style)
      if id != same: return packedFont(same)
      if id != fSans: return packedFont(fSans)
      ""
var
  fontFiles: array[FaceId, string]          # unpacked or read, kept for the app's life
  faces: array[FaceId, Face]
  given: array[FaceId, string]              # fonts handed over (`setUserFont`)
  resolved: array[FaceId, bool]             # where a face's font comes from: worked out
  standIn: array[FaceId, FaceId]            # ... or another face (itself: none)
  faux: array[FaceId, tuple[bold, italic: bool]]  # ... made bold or slanted from it
  asciiAdv: array[FaceId, array[128, float32]]
  asciiKern: array[FaceId, seq[float32]]   ## 96 x 96 pairs of 32..127, in ems
  runCache, rtlCache: array[FaceId, Table[string, Run]]
  joinsArabic: array[FaceId, int8]          # the face has Arabic's joined forms: 1 yes, 0 no, -1 not known
  chains: array[FaceId, seq[FaceId]]        # the faces characters are looked for in (`chainOf`)
  boldExtra: array[FaceId, float32]         # a faux bold's extra advance, in ems

var unpackLock: Lock
initLock(unpackLock)

proc regularOf*(id: FaceId): FaceId {.inline.} =
  ## The regular of face `id`'s family.
  if id == fIcons: fIcons else: FaceId(ord(id) and not 3)

proc isBold*(id: FaceId): bool {.inline.} =
  ## A bold face.
  id != fIcons and (ord(id) and 1) != 0

proc isItalic*(id: FaceId): bool {.inline.} =
  ## An italic (or oblique) face.
  id != fIcons and (ord(id) and 2) != 0

proc styled*(id: FaceId; bold, italic: bool): FaceId {.inline.} =
  ## The face of `id`'s family in that style.
  if id == fIcons: fIcons
  else: FaceId(ord(regularOf(id)) + ord(bold) + 2 * ord(italic))

proc builtinFace*(id: FaceId): bool {.inline.} =
  ## Face `id` is one of the program's own (FreeFont, the icons).
  id == fIcons or id <= fMonoBoldItalic

proc lastResort(id: FaceId): FaceId =
  ## (a face with no font of its own, none of its family either: drawn as)
  styled(fSans, isBold(id), isItalic(id))

proc resolve(id: FaceId) =
  ## Where face `id`'s font comes from: its own bytes (built in, handed
  ## over) or another face's (`standIn`, made bold or slanted from it when
  ## it is the family's regular).
  if resolved[id]: return
  resolved[id] = true
  standIn[id] = id
  faux[id] = (false, false)
  if builtinFace(id) or given[id].len > 0: return
  let bold = isBold(id)
  let italic = isItalic(id)
  let reg = regularOf(id)
  if given[reg].len == 0:
    standIn[id] = lastResort(id)          # (no font from a file: FreeSans)
  elif bold and italic and given[styled(reg, true, false)].len > 0:
    # (a bold italic the font lacks: from its bold)
    standIn[id] = styled(reg, true, false)
    faux[id] = (false, true)
  else:
    standIn[id] = reg
    faux[id] = (bold, italic)

proc load(id: FaceId) =
  ## Face `id`'s font bytes into `fontFiles` (a stand-in's: none).
  if fontFiles[id].len > 0: return
  resolve(id)
  if standIn[id] != id: return
  if id == fIcons or builtinFace(id):
    let packed = if id == fIcons: iconsPacked else: packedFont(id)
    let b = zlibDecompress(packed.toOpenArrayByte(0, packed.high))
    var s = newString(b.len)
    if b.len > 0: copyMem(addr s[0], unsafeAddr b[0], b.len)
    fontFiles[id] = move s
  elif given[id].len > 0:
    fontFiles[id] = given[id]

proc dataOf(id: FaceId): FaceId =
  ## The face whose font file face `id` is drawn from.
  result = id
  for _ in 0 .. 8:
    load(result)
    if standIn[result] == result: return
    result = standIn[result]

proc fauxStyle*(id: FaceId): tuple[bold, italic: bool] =
  ## Face `id` is made from another (its family has no such style): to be
  ## drawn emboldened, slanted, or both.
  var x = id
  for _ in 0 .. 8:
    resolve(x)
    result.bold = result.bold or faux[x].bold
    result.italic = result.italic or faux[x].italic
    if standIn[x] == x: return
    # (a stand-in from another family: its own style is the one asked for)
    if regularOf(standIn[x]) != regularOf(x): return
    x = standIn[x]

proc faceBytes*(id: FaceId): string =
  ## The font file of face `id`, a copy: for a worker thread to parse a face
  ## of its own (faces are not shared between threads; see `threadFace`).
  {.cast(gcsafe).}:
    withLock unpackLock:
      result = fontFiles[dataOf(id)]

proc threadFace*(id: FaceId): Face =
  ## Face `id` parsed anew, for a worker thread.
  {.cast(gcsafe).}:
    result = parseFace(faceBytes(id))

proc face*(id: FaceId): Face =
  ## The parsed face `id` (parsed on first use).
  if faces[id] == nil:
    let d = dataOf(id)
    if d != id:
      # (drawn from another face's file: that face, shared; made bold, its
      # letters a little wider, as FreeType makes them)
      faces[id] = face(d)
      asciiAdv[id] = asciiAdv[d]
      asciiKern[id] = asciiKern[d]
      boldExtra[id] = if fauxStyle(id).bold and not fauxStyle(d).bold: FauxBoldEm else: 0
      if boldExtra[id] > 0:
        for c in 32 .. 126: asciiAdv[id][c] += boldExtra[id]
      return faces[id]
    faces[id] = parseFace(fontFiles[id])
    let f = faces[id]
    let em = float32(f.unitsPerEm)
    for c in 32 .. 126:
      asciiAdv[id][c] = float32(f.advance(f.glyphOf(c))) / em
    asciiAdv[id][9] = asciiAdv[id][32] * TabStops
    asciiKern[id] = newSeq[float32](96 * 96)
    for a in 32 .. 126:
      let ga = f.glyphOf(a)
      if ga == 0: continue
      for b in 32 .. 126:
        let k = f.kerning(ga, f.glyphOf(b))
        if k != 0: asciiKern[id][(a - 32) * 96 + b - 32] = float32(k) / em
  faces[id]

proc fontName*(id: FaceId): string =
  ## The family of the font face `id` is drawn in ("FreeSans", "Segoe UI").
  face(id).family

proc forgetFaces(ids: openArray[FaceId]) =
  for id in ids:
    faces[id] = nil
    fontFiles[id] = ""
    resolved[id] = false
    joinsArabic[id] = -1
  for id in FaceId:
    # (a face drawn from one of them is worked out again too)
    if faces[id] != nil and resolved[id] and standIn[id] != id and standIn[id] in ids:
      faces[id] = nil
      resolved[id] = false
    runCache[id].clear()
    rtlCache[id].clear()
    chains[id] = @[]

for id in FaceId: joinsArabic[id] = -1

proc setUserFont*(regular: string; bold = ""; italic = ""; boldItalic = "") =
  ## The font from a file (TrueType bytes; `bold`, `italic`, `boldItalic`:
  ## its other styles, when it has them -- a style not given is made from
  ## the regular): the faces `fUser` .. `fUserBoldItalic`. Raises
  ## `FontError` when one is not a TrueType font we read.
  let f = parseFace(regular)
  if f == nil or f.unitsPerEm <= 0 or f.glyphOf(ord('A')) == 0: raise newException(FontError, "not a font we read")
  for (s, what) in [(bold, "the bold"), (italic, "the italic"), (boldItalic, "the bold italic")]:
    if s.len > 0:
      let b = parseFace(s)
      if b == nil or b.unitsPerEm <= 0: raise newException(FontError, what & " is not a font we read")
  given[fUser] = regular
  given[fUserBold] = bold
  given[fUserItalic] = italic
  given[fUserBoldItalic] = boldItalic
  forgetFaces([fUser, fUserBold, fUserItalic, fUserBoldItalic])

proc hasUserFont*(): bool = given[fUser].len > 0
  ## A font from a file was given (`setUserFont`).

proc lineFactor*(id: FaceId; withGap = false): float32 =
  ## Height of a line of face `id`, in ems: ascent + descent, and with its
  ## line gap for a font not built in or when `withGap` (the UI's lines).
  let f = face(id)
  let gap = if withGap or not builtinFace(dataOf(id)): max(0, f.lineGap) else: 0
  float32(f.ascent - f.descent + gap) / float32(f.unitsPerEm)

proc ascentFactor*(id: FaceId; withGap = false): float32 =
  ## Height of face `id` above the baseline, in ems: with half its line gap
  ## for a font not built in or when `withGap` (the UI's lines).
  let f = face(id)
  let gap = if withGap or not builtinFace(dataOf(id)): max(0, f.lineGap) else: 0
  float32(f.ascent + gap div 2) / float32(f.unitsPerEm)

proc lineFactor*(): float32 = lineFactor(fSans)
  ## Height of a line of FreeSans, in ems (ascent + descent).

proc ascentFactor*(): float32 = ascentFactor(fSans)
  ## Height of FreeSans above the baseline, in ems.

proc advanceFactor*(id: FaceId): float32 =
  ## A monospaced face's advance, in ems (0: not monospaced).
  let f = face(id)
  let g = f.glyphOf(ord('0'))
  if g == 0: return 0
  let a = f.advance(g)
  if a == f.advance(f.glyphOf(ord('i'))) and a == f.advance(f.glyphOf(ord('M'))):
    float32(a) / float32(f.unitsPerEm)
  else: 0

# ---- character classes ----------------------------------------------------------------

proc isMark*(cp: int): bool =
  ## A combining mark (drawn over or under the letter before it).
  case cp
  of 0x0300..0x036F, 0x0483..0x0489, 0x0591..0x05BD, 0x05BF, 0x05C1, 0x05C2,
     0x05C4, 0x05C5, 0x05C7, 0x0610..0x061A, 0x064B..0x065F, 0x0670,
     0x06D6..0x06DC, 0x06DF..0x06E4, 0x06E7, 0x06E8, 0x06EA..0x06ED, 0x0711,
     0x0730..0x074A, 0x07A6..0x07B0, 0x07EB..0x07F3, 0x07FD, 0x0816..0x0819,
     0x081B..0x0823, 0x0825..0x0827, 0x0829..0x082D, 0x0859..0x085B,
     0x0897..0x089F, 0x08CA..0x08E1, 0x08E3..0x08FF,
     0x1AB0..0x1AFF, 0x1DC0..0x1DFF, 0x20D0..0x20FF, 0xFE00..0xFE0F,
     0xFE20..0xFE2F: true
  else: false

proc isInvisible(cp: int): bool =
  ## A character with no glyph: a control, a joiner, a direction mark or
  ## embedding, a variation selector.
  if cp < 0x80: return cp < 32 and cp != 9 or cp == 0x7F
  case cp
  of 0x80..0x9F, 0xAD, 0x061C, 0x180E, 0x200B..0x200F, 0x2028..0x202E,
     0x2060..0x206F, 0xFE00..0xFE0F, 0xFEFF, 0xFFF0..0xFFF8, 0xE0000..0xE0FFF: true
  else: false

type BidiClass = enum
  bL, bR, bAL, bEN, bAN, bES, bET, bCS, bNSM, bWS, bON,
  bB, bS, bBN,                                  # paragraph, segment separators; boundary neutral
  bLRE, bRLE, bLRO, bRLO, bPDF, bLRI, bRLI, bFSI, bPDI   # the explicit controls

const
  latinBidi = block:
    # (the classes of U+0000 .. U+00FF)
    var t: array[256, BidiClass]
    for c in 0 .. 255:
      t[c] =
        case c
        of 0x30..0x39, 0xB2, 0xB3, 0xB9: bEN
        of 0x2B, 0x2D: bES
        of 0x23..0x25, 0xA2..0xA5, 0xB0, 0xB1: bET
        of 0x2C, 0x2E, 0x2F, 0x3A, 0xA0: bCS
        of 0x0A, 0x0D, 0x1C..0x1E, 0x85: bB
        of 0x09, 0x0B, 0x1F: bS
        of 0x0C, 0x20: bWS
        of 0x00..0x08, 0x0E..0x1B, 0x7F..0x84, 0x86..0x9F, 0xAD: bBN
        of 0x41..0x5A, 0x61..0x7A, 0xAA, 0xB5, 0xBA, 0xC0..0xD6, 0xD8..0xF6, 0xF8..0xFF: bL
        else: bON
    t
  removedBidi = {bBN, bLRE, bRLE, bLRO, bRLO, bPDF}   # (left out of the levels: X9)
  isolateBidi = {bLRI, bRLI, bFSI}
  MaxDepth = 125'i8                                 # (the deepest embedding: BD2)

proc bidiClass(cp: int): BidiClass =
  ## The bidirectional class of `cp` (UAX #9; the scripts and symbols text
  ## is written in -- what is not listed reads left to right).
  if cp < 0x100: return latinBidi[cp]
  if cp < 0x0590:
    return case cp
      of 0x0300..0x036F, 0x0483..0x0489: bNSM
      of 0x02B9, 0x02BA, 0x02C2..0x02CF, 0x02D2..0x02DF, 0x02E5..0x02ED, 0x02EF..0x02FF,
         0x0374, 0x0375, 0x037E, 0x0384, 0x0385, 0x0387, 0x03F6, 0x058A, 0x058D, 0x058E: bON
      of 0x058F: bET
      else: bL
  if cp < 0x0900:
    # Hebrew, Arabic, Syriac, Thaana, NKo, Samaritan, Mandaic
    if isMark(cp): return bNSM
    return case cp
      of 0x0600..0x0605, 0x0660..0x0669, 0x066B, 0x066C, 0x06DD, 0x0890, 0x0891, 0x08E2: bAN
      of 0x06F0..0x06F9: bEN
      of 0x0609, 0x060A, 0x066A: bET
      of 0x060C: bCS
      of 0x0606, 0x0607, 0x060E, 0x060F, 0x06DE, 0x06E9, 0x07F6..0x07F9: bON
      of 0x0590..0x05FF, 0x07C0..0x07F5, 0x07FA..0x085F: bR
      else: bAL
  if cp < 0x2000:
    return case cp
      of 0x1AB0..0x1AFF, 0x1DC0..0x1DFF: bNSM
      of 0x09F2, 0x09F3, 0x09FB, 0x0AF1, 0x0BF9, 0x0E3F, 0x17DB: bET
      of 0x0BF3..0x0BF8, 0x0BFA, 0x0C78..0x0C7E, 0x0F3A..0x0F3D, 0x1390..0x1399, 0x1400,
         0x169B, 0x169C, 0x17F0..0x17F9, 0x1800..0x180A, 0x1940, 0x1944, 0x1945,
         0x19DE..0x19FF, 0x1FBD, 0x1FBF..0x1FC1, 0x1FCD..0x1FCF, 0x1FDD..0x1FDF,
         0x1FED..0x1FEF, 0x1FFD, 0x1FFE: bON
      of 0x1680: bWS
      of 0x180E: bBN
      else: bL
  if cp < 0x3000:
    return case cp
      of 0x2000..0x200A, 0x2028, 0x205F: bWS
      of 0x200B..0x200D, 0x2060..0x2065, 0x206A..0x206F: bBN
      of 0x200E: bL
      of 0x200F: bR
      of 0x2029: bB
      of 0x202A: bLRE
      of 0x202B: bRLE
      of 0x202C: bPDF
      of 0x202D: bLRO
      of 0x202E: bRLO
      of 0x2066: bLRI
      of 0x2067: bRLI
      of 0x2068: bFSI
      of 0x2069: bPDI
      of 0x202F, 0x2044: bCS
      of 0x2030..0x2034, 0x20A0..0x20CF, 0x212E, 0x2213: bET
      of 0x2070, 0x2074..0x2079, 0x2080..0x2089, 0x2488..0x249B: bEN
      of 0x207A, 0x207B, 0x208A, 0x208B, 0x2212: bES
      of 0x20D0..0x20FF: bNSM
      of 0x2010..0x2027, 0x2035..0x2043, 0x2045..0x205E, 0x207C..0x207E, 0x208C..0x208E,
         0x2100, 0x2101, 0x2103..0x2106, 0x2108, 0x2109, 0x2114, 0x2116..0x2118,
         0x211E..0x2123, 0x2125, 0x2127, 0x2129, 0x213A, 0x213B, 0x2140..0x2144,
         0x214A..0x214D, 0x2150..0x215F, 0x2189..0x2211, 0x2214..0x2335,
         0x237B..0x2394, 0x2396..0x2487, 0x24EA..0x26AB, 0x26AD..0x27FF,
         0x2900..0x2B73, 0x2B76..0x2BFF, 0x2CE5..0x2CEA, 0x2CF9..0x2CFF,
         0x2E00..0x2FFF: bON
      else: bL
  if cp < 0xFB1D:
    return case cp
      of 0x3000: bWS
      of 0x302A..0x302D, 0x3099, 0x309A, 0xA66F..0xA672, 0xA674..0xA67D, 0xA69E, 0xA69F: bNSM
      of 0x3001..0x3004, 0x3008..0x3020, 0x3030, 0x3036, 0x3037, 0x303D..0x303F,
         0x309B, 0x309C, 0x30A0, 0x30FB, 0x31C0..0x31EF, 0x321D, 0x321E,
         0x3250..0x325F, 0x327C..0x327E, 0x32B1..0x32BF, 0x32CC..0x32CF,
         0x3377..0x337A, 0x33DE, 0x33DF, 0x33FF, 0x4DC0..0x4DFF, 0xA490..0xA4C6,
         0xA60D..0xA60F, 0xA673, 0xA67E, 0xA67F, 0xA700..0xA721, 0xA788, 0xA828..0xA82B,
         0xA874..0xA877, 0xAB6A, 0xAB6B: bON
      of 0xA838, 0xA839: bET
      else: bL
  if cp < 0x10000:
    return case cp
      of 0xFB1E, 0xFE00..0xFE0F, 0xFE20..0xFE2F: bNSM
      of 0xFB29, 0xFE62, 0xFE63, 0xFF0B, 0xFF0D: bES
      of 0xFB1D, 0xFB1F..0xFB28, 0xFB2A..0xFB4F: bR
      of 0xFD3E..0xFD4F, 0xFDCF, 0xFDFD..0xFDFF, 0xFE10..0xFE19, 0xFE30..0xFE4F, 0xFE51,
         0xFE54, 0xFE56..0xFE5E, 0xFE60, 0xFE61, 0xFE64..0xFE68, 0xFE6B, 0xFF01, 0xFF02,
         0xFF06..0xFF0A, 0xFF1B..0xFF20, 0xFF3B..0xFF40, 0xFF5B..0xFF65, 0xFFE2..0xFFE4,
         0xFFE8..0xFFEE, 0xFFF9..0xFFFD: bON
      of 0xFDD0..0xFDEF, 0xFEFF, 0xFFF0..0xFFF8, 0xFFFE, 0xFFFF: bBN
      of 0xFB50..0xFD3D, 0xFD50..0xFDCE, 0xFDF0..0xFDFC, 0xFE70..0xFEFE: bAL
      of 0xFE50, 0xFE52, 0xFE55, 0xFF0C, 0xFF0E, 0xFF0F, 0xFF1A: bCS
      of 0xFE5F, 0xFE69, 0xFE6A, 0xFF03..0xFF05, 0xFFE0, 0xFFE1, 0xFFE5, 0xFFE6: bET
      of 0xFF10..0xFF19: bEN
      else: bL
  case cp
  of 0x10D00..0x10D23, 0x10D28..0x10D2F, 0x10D3A..0x10D3F, 0x10EC0..0x10EFF,
     0x10F30..0x10F6F, 0x1EC70..0x1ECBF, 0x1ED00..0x1ED4F, 0x1EE00..0x1EEEF,
     0x1EEF2..0x1EEFF: bAL
  of 0x10D30..0x10D39, 0x10E60..0x10E7E: bAN
  of 0x10800..0x10CFF, 0x10D40..0x10E5F, 0x10E7F..0x10EBF, 0x10F00..0x10F2F,
     0x10F70..0x10FFF, 0x1E800..0x1EC6F, 0x1ECC0..0x1ECFF, 0x1ED50..0x1EDFF,
     0x1EF00..0x1EFFF: bR
  of 0x10D24..0x10D27, 0xE0100..0xE01EF: bNSM
  of 0x1F000..0x1F0FF, 0x1F10B..0x1F10F, 0x1F12F, 0x1F16A..0x1F16F, 0x1F1AD,
     0x1F260..0x1F265, 0x1F300..0x1FBCA, 0x1EEF0, 0x1EEF1: bON
  of 0x1F100..0x1F10A, 0x1FBF0..0x1FBF9, 0x1D7CE..0x1D7FF: bEN
  of 0xE0000..0xE00FF, 0xE01F0..0xE0FFF, 0x1BCA0..0x1BCA3, 0x1D173..0x1D17A: bBN
  else: bL

proc scanText(cps: openArray[int]): tuple[arabic, rtl, bidi: bool] =
  ## What a line needs: Arabic joining, (it has) right-to-left letters, the
  ## bidi algorithm (levels other than 0: right-to-left letters, Arabic
  ## numbers, explicit controls).
  for c in cps:
    if c < 0x0590: continue
    if c in 0x0600..0x06FF or c in 0x0750..0x077F: result.arabic = true
    case bidiClass(c)
    of bR, bAL:
      result.rtl = true
      result.bidi = true
    of bAN, bLRE .. bPDI: result.bidi = true
    else: discard

var rtlInterface = false   # (`setRtlInterface`)
var visualCache: Table[string, seq[tuple[cp: int; rtl: bool]]]

proc textIsRtl*(s: string): bool =
  ## Whether `s` reads right to left: its first letter is Arabic or Hebrew
  ## (or a right-to-left mark), what is inside isolates (U+2066..2069) left
  ## out -- the paragraph direction of UAX #9 (P2, P3).
  var depth = 0
  for r in s.runes:
    case bidiClass(int(r))
    of bL: (if depth == 0: return false)
    of bR, bAL: (if depth == 0: return true)
    of bLRI, bRLI, bFSI: inc depth
    of bPDI: (if depth > 0: dec depth)
    else: discard
  false

proc strongDir*(s: string): int =
  ## The direction of `s` from its first strong character (isolates left
  ## out): 0 left to right, 1 right to left, 2 a number, -1 none
  ## (punctuation, spaces).
  var depth = 0
  for r in s.runes:
    case bidiClass(int(r))
    of bL: (if depth == 0: return 0)
    of bR, bAL: (if depth == 0: return 1)
    of bEN, bAN: (if depth == 0: return 2)
    of bLRI, bRLI, bFSI: inc depth
    of bPDI: (if depth > 0: dec depth)
    else: discard
  -1

const
  mirrorNext = [  # (characters whose mirror image is the next one: "(" ")", "≤" "≥")
    0x0028, 0x0F3A, 0x0F3C, 0x169B, 0x2039, 0x2045, 0x207D, 0x208D, 0x223C, 0x2252, 0x2254,
    0x2264, 0x2266, 0x2268, 0x226A, 0x226E, 0x2270, 0x2272, 0x2274, 0x2276, 0x2278, 0x227A,
    0x227C, 0x227E, 0x2280, 0x2282, 0x2284, 0x2286, 0x2288, 0x228A, 0x228F, 0x2291, 0x22A2,
    0x22B0, 0x22B2, 0x22B4, 0x22B6, 0x22C9, 0x22CB, 0x22D0, 0x22D6, 0x22D8, 0x22DA, 0x22DC,
    0x22DE, 0x22E0, 0x22E2, 0x22E4, 0x22E6, 0x22E8, 0x22EA, 0x22EC, 0x22F0, 0x2308, 0x230A,
    0x2329, 0x2768, 0x276A, 0x276C, 0x276E, 0x2770, 0x2772, 0x2774, 0x27C3, 0x27C5, 0x27C8,
    0x27D5, 0x27DD, 0x27E2, 0x27E4, 0x27E6, 0x27E8, 0x27EA, 0x27EC, 0x27EE, 0x2983, 0x2985,
    0x2987, 0x2989, 0x298B, 0x298E, 0x2991, 0x2993, 0x2995, 0x2997, 0x29A4, 0x29A8, 0x29AA,
    0x29AC, 0x29AE, 0x29C0, 0x29C4, 0x29CF, 0x29D1, 0x29D4, 0x29D8, 0x29DA, 0x29E8, 0x29F8,
    0x29FC, 0x2A2B, 0x2A2D, 0x2A34, 0x2A3C, 0x2A64, 0x2A79, 0x2A7B, 0x2A7D, 0x2A7F, 0x2A81,
    0x2A83, 0x2A85, 0x2A87, 0x2A89, 0x2A8B, 0x2A8D, 0x2A8F, 0x2A91, 0x2A93, 0x2A95, 0x2A97,
    0x2A99, 0x2A9B, 0x2A9D, 0x2A9F, 0x2AA1, 0x2AA6, 0x2AA8, 0x2AAA, 0x2AAC, 0x2AAF, 0x2AB1,
    0x2AB3, 0x2AB5, 0x2AB7, 0x2AB9, 0x2ABB, 0x2ABD, 0x2ABF, 0x2AC1, 0x2AC3, 0x2AC5, 0x2AC7,
    0x2AC9, 0x2ACB, 0x2ACD, 0x2ACF, 0x2AD1, 0x2AD3, 0x2AD5, 0x2AEC, 0x2AF7, 0x2AF9, 0x2E02,
    0x2E04, 0x2E09, 0x2E0C, 0x2E1C, 0x2E20, 0x2E22, 0x2E24, 0x2E26, 0x2E28, 0x2E55, 0x2E57,
    0x2E59, 0x2E5B, 0x2E62, 0x3008, 0x300A, 0x300C, 0x300E, 0x3010, 0x3014, 0x3016, 0x3018,
    0x301A, 0xFE59, 0xFE5B, 0xFE5D, 0xFE64, 0xFF08, 0xFF5F, 0xFF62, 0x1DB03, 0x1DB05, 0x1DB08]
  mirrorPairs = [  # (the other pairs)
    (0x003C, 0x003E), (0x005B, 0x005D), (0x007B, 0x007D), (0x00AB, 0x00BB), (0x2208, 0x220B),
    (0x2209, 0x220C), (0x220A, 0x220D), (0x2215, 0x29F5), (0x221D, 0x1DB10), (0x221F, 0x2BFE),
    (0x2220, 0x29A3), (0x2221, 0x299B), (0x2222, 0x29A0), (0x2224, 0x2AEE), (0x2243, 0x22CD),
    (0x2245, 0x224C), (0x2298, 0x29B8), (0x22A6, 0x2ADE), (0x22A8, 0x2AE4), (0x22A9, 0x2AE3),
    (0x22AB, 0x2AE5), (0x22B8, 0x27DC), (0x22F2, 0x22FA), (0x22F3, 0x22FB), (0x22F4, 0x22FC),
    (0x22F6, 0x22FD), (0x22F7, 0x22FE), (0x27CB, 0x27CD), (0x298D, 0x2990), (0xFF1C, 0xFF1E),
    (0xFF3B, 0xFF3D), (0xFF5B, 0xFF5D)]
  mirrorTable = block:
    # (character, its mirror image) by character: Unicode's BidiMirroring.txt
    var t: seq[(int32, int32)]
    for c in mirrorNext:
      t.add (int32(c), int32(c + 1))
      t.add (int32(c + 1), int32(c))
    for (a, b) in mirrorPairs:
      t.add (int32(a), int32(b))
      t.add (int32(b), int32(a))
    t.sort(proc (x, y: (int32, int32)): int = cmp(x[0], y[0]))
    t

proc mirror(cp: int): int =
  case cp
  of ord('('): ord(')')
  of ord(')'): ord('(')
  of ord('['): ord(']')
  of ord(']'): ord('[')
  of ord('{'): ord('}')
  of ord('}'): ord('{')
  of ord('<'): ord('>')
  of ord('>'): ord('<')
  elif cp < 0xAB: cp
  else:
    var lo = 0
    var hi = mirrorTable.high
    while lo <= hi:
      let m = (lo + hi) shr 1
      let c = int(mirrorTable[m][0])
      if c == cp: return int(mirrorTable[m][1])
      if c < cp: lo = m + 1 else: hi = m - 1
    cp

proc isOpenBracket(cp: int): bool =
  ## (an opening paired bracket: BidiBrackets.txt; its closing one is its
  ## mirror image)
  case cp
  of 0x28, 0x5B, 0x7B, 0x0F3A, 0x0F3C, 0x169B, 0x2045, 0x207D, 0x208D, 0x2308, 0x230A,
     0x2329, 0x2768, 0x276A, 0x276C, 0x276E, 0x2770, 0x2772, 0x2774, 0x27C5, 0x27E6,
     0x27E8, 0x27EA, 0x27EC, 0x27EE, 0x2983, 0x2985, 0x2987, 0x2989, 0x298B, 0x298D,
     0x298F, 0x2991, 0x2993, 0x2995, 0x2997, 0x29D8, 0x29DA, 0x29FC, 0x2E22, 0x2E24,
     0x2E26, 0x2E28, 0x2E55, 0x2E57, 0x2E59, 0x2E5B, 0x2E62, 0x3008, 0x300A, 0x300C,
     0x300E, 0x3010, 0x3014, 0x3016, 0x3018, 0x301A, 0xFE59, 0xFE5B, 0xFE5D, 0xFF08,
     0xFF3B, 0xFF5B, 0xFF5F, 0xFF62: true
  else: false

# ---- Arabic joining ---------------------------------------------------------------------

var formsOf: Table[int, array[4, uint16]]
var lamAlefOf: Table[int, (uint16, uint16)]
var isolatedOf: Table[int, int]     ## an isolated presentation form -> its letter

proc initArabic() =
  if formsOf.len > 0: return
  for (k, v) in arabicForms:
    formsOf[int(k)] = v
    if v[0] != 0: isolatedOf[int(v[0])] = int(k)
  for (k, iso, fin) in lamAlef: lamAlefOf[int(k)] = (iso, fin)

type Joining = enum jNone, jRight, jDual, jTransparent

proc joining(cp: int): Joining =
  ## How `cp` joins (Unicode's ArabicShaping.txt): the zero width joiner and
  ## tatweel join both sides, the zero width non-joiner and the isolates
  ## break the join, marks and the other invisible controls (direction
  ## marks, embeddings, the word joiner) let it through.
  if isMark(cp): return jTransparent
  case cp
  of 0x0640, 0x200D: return jDual
  of 0x200C, 0x2066..0x2069, 0x202F, 0x180E: return jNone
  of 0xAD, 0x061C, 0x200B, 0x200E, 0x200F, 0x202A..0x202E, 0x2060..0x2064,
     0x206A..0x206F, 0xFEFF: return jTransparent
  else: discard
  let v = formsOf.getOrDefault(cp, [0'u16, 0, 0, 0])
  if v[2] != 0 or v[3] != 0: jDual
  elif v[1] != 0: jRight
  else: jNone

proc joinsAt*(s: string; i: int): bool =
  ## Whether the letters on either side of byte `i` of `s` are joined (one
  ## Arabic word): a piece of the text cut there and drawn on its own keeps
  ## its letters' joined forms with a zero width joiner (U+200D) at the cut.
  if i <= 0 or i >= s.len: return false
  initArabic()
  var k = i
  var before = jNone
  while k > 0:
    var p = k - 1
    while p > 0 and (ord(s[p]) and 0xC0) == 0x80: dec p
    k = p
    let jt = joining(int(s.runeAt(p)))
    if jt != jTransparent:
      before = jt
      break
  if before != jDual: return false
  var q = i
  while q < s.len:
    let r = s.runeAt(q)
    let jt = joining(int(r))
    if jt != jTransparent: return jt in {jRight, jDual}
    q += r.size
  false

proc arabicSource*(bold: bool): FaceId =
  ## The face Arabic letters come from when the text's face has none:
  ## FreeSerif (its bold for bold text).
  if bold: fSerifBold else: fSerif

proc shapeArabic(cps: var seq[int]) =
  ## Replaces the Arabic letters of `cps` (logical order) by their joined
  ## presentation forms; a letter swallowed by a ligature becomes -1.
  initArabic()
  let n = cps.len
  var jt = newSeq[Joining](n)
  for i in 0 ..< n: jt[i] = joining(cps[i])
  var outp = cps
  for i in 0 ..< n:
    if jt[i] notin {jRight, jDual} or cps[i] < 0: continue
    var p = i - 1
    while p >= 0 and (jt[p] == jTransparent or cps[p] < 0): dec p
    var q = i + 1
    while q < n and jt[q] == jTransparent: inc q
    if q >= n: q = -1
    let joinsPrev = p >= 0 and jt[p] == jDual
    var joinsNext = q >= 0 and jt[i] == jDual and jt[q] in {jRight, jDual}
    if cps[i] == 0x0644 and q >= 0 and lamAlefOf.hasKey(cps[q]):
      let (iso, fin) = lamAlefOf[cps[q]]
      outp[i] = int(if joinsPrev: fin else: iso)
      outp[q] = -1
      cps[q] = -1
      jt[q] = jNone
      continue
    # (tatweel and the zero width joiner join, but have no forms of their own)
    let v = formsOf.getOrDefault(cps[i], [0'u16, 0, 0, 0])
    let slot = if joinsPrev and joinsNext: 3
               elif joinsPrev: 1
               elif joinsNext: 2
               else: 0
    var f = int(v[slot])
    if f == 0 and slot == 3: f = int(v[1])      # no medial: use final
    if f == 0 and slot == 2: f = int(v[0])
    if f == 0: f = int(v[0])
    if f != 0 and face(arabicSource(false)).hasGlyph(f):
      outp[i] = f
  cps = outp

# ---- bidi -----------------------------------------------------------------------------------

proc firstStrong(t: openArray[BidiClass]; a: int): int =
  ## P2, P3 for the isolate starting at `a`: the direction of its first
  ## strong character up to its matching PDI (0 left to right, 1 right to
  ## left, -1 none), isolates inside it left out.
  var depth = 0
  for i in a ..< t.len:
    case t[i]
    of bL: (if depth == 0: return 0)
    of bR, bAL: (if depth == 0: return 1)
    of bLRI, bRLI, bFSI: inc depth
    of bPDI:
      if depth == 0: return -1
      dec depth
    of bB: return -1
    else: discard
  -1

proc strongOf(c: BidiClass): BidiClass {.inline.} =
  ## (the direction a resolved class counts as for N0 .. N2: numbers as R)
  case c
  of bL: bL
  of bR, bAL, bEN, bAN: bR
  else: bON

proc resolveSequence(t: var seq[BidiClass]; lv: var seq[int8]; sq: openArray[int];
                     cps: openArray[int]; xt: openArray[BidiClass]; sos, eos: BidiClass) =
  ## W1 .. I2 for one isolating run sequence (the characters `sq`, at one
  ## level): numbers, separators, brackets and neutrals resolved, then the
  ## levels raised. `xt`: the classes before W1 (N0's marks).
  let m = sq.len
  let level = lv[sq[0]]
  let e = if (level and 1) == 1: bR else: bL
  # W1: marks take the class before them (after an isolate's control: neutral)
  var prev = sos
  for k in 0 ..< m:
    let i = sq[k]
    if t[i] == bNSM: t[i] = prev
    else: prev = if t[i] in {bLRI, bRLI, bFSI, bPDI}: bON else: t[i]
  # W2, W3: numbers after Arabic letters are Arabic numbers; AL is R
  var strong = sos
  for i in sq:
    case t[i]
    of bL, bR: strong = t[i]
    of bAL:
      strong = bAL
      t[i] = bR
    of bEN:
      if strong == bAL: t[i] = bAN
    else: discard
  # W4: one separator between two numbers of the same kind joins them
  for k in 1 ..< m - 1:
    let (a, i, b) = (t[sq[k-1]], t[sq[k]], t[sq[k+1]])
    if i == bES and a == bEN and b == bEN: t[sq[k]] = bEN
    elif i == bCS and a == b and a in {bEN, bAN}: t[sq[k]] = a
  # W5: terminators next to European numbers ("50%", "$3")
  var k = 0
  while k < m:
    if t[sq[k]] == bET:
      var j = k
      while j < m and t[sq[j]] == bET: inc j
      if (k > 0 and t[sq[k-1]] == bEN) or (j < m and t[sq[j]] == bEN):
        for x in k ..< j: t[sq[x]] = bEN
      k = j
    else: inc k
  # W6, W7: the other separators are neutral; European numbers after
  # Latin text are Latin
  strong = sos
  for i in sq:
    case t[i]
    of bES, bET, bCS: t[i] = bON
    of bL, bR: strong = t[i]
    of bEN:
      if strong == bL: t[i] = bL
    else: discard
  # N0: a pair of brackets takes the direction of what it encloses (or,
  # enclosing only the other direction, of what comes before it)
  var pairs: seq[(int, int)]
  var stack: seq[(int, int)]                # (where, the closing bracket wanted)
  for k in 0 ..< m:
    let i = sq[k]
    if t[i] != bON or cps[i] < 0: continue
    var c = cps[i]
    if isOpenBracket(c):
      if stack.len == 63: break
      stack.add (k, mirror(c))
    else:
      if c == 0x232A: c = 0x3009            # (canonically the same bracket)
      var s = stack.high
      while s >= 0 and stack[s][1] != c and
            not (stack[s][1] == 0x232A and c == 0x3009): dec s
      if s >= 0:
        pairs.add (stack[s][0], k)
        stack.setLen(s)
  if pairs.len > 1: pairs.sort(proc (x, y: (int, int)): int = cmp(x[0], y[0]))
  for (a, b) in pairs:
    var inside = bON
    for x in a + 1 ..< b:
      let d = strongOf(t[sq[x]])
      if d == e:
        inside = e
        break
      if d != bON: inside = d
    if inside == bON: continue
    var d = e
    if inside != e:
      d = sos
      for x in countdown(a - 1, 0):
        let c = strongOf(t[sq[x]])
        if c != bON:
          d = c
          break
    for p in [a, b]:
      t[sq[p]] = d
      var x = p + 1
      while x < m and xt[sq[x]] == bNSM:
        t[sq[x]] = d
        inc x
  # N1, N2: neutrals between two of the same direction take it, the
  # others the embedding's
  k = 0
  while k < m:
    if t[sq[k]] in {bB, bS, bWS, bON, bLRI, bRLI, bFSI, bPDI}:
      var j = k
      while j < m and t[sq[j]] in {bB, bS, bWS, bON, bLRI, bRLI, bFSI, bPDI}: inc j
      let before = if k == 0: sos else: strongOf(t[sq[k-1]])
      let after = if j >= m: eos else: strongOf(t[sq[j]])
      let d = if before == after: before else: e
      for x in k ..< j: t[sq[x]] = d
      k = j
    else: inc k
  # I1, I2
  for i in sq:
    if e == bL:
      if t[i] == bR: lv[i] = level + 1
      elif t[i] in {bEN, bAN}: lv[i] = level + 2
    elif t[i] in {bL, bEN, bAN}: lv[i] = level + 1

proc bidiLevels(cps: seq[int]; rtlPara: bool): seq[int8] =
  ## Embedding levels of one paragraph (or line), by the Unicode
  ## bidirectional algorithm (UAX #9): explicit embeddings, overrides and
  ## isolates, numbers, brackets, neutrals, the white space at the end. A
  ## character the algorithm leaves out (a joiner, an embedding's control)
  ## takes the level before it. `-1` in `cps` (a letter joined into the
  ## one before) is a mark.
  let n = cps.len
  var t = newSeq[BidiClass](n)
  var explicit = false
  for i in 0 ..< n:
    t[i] = if cps[i] < 0: bNSM else: bidiClass(cps[i])
    if t[i] >= bLRE: explicit = true
  let orig = t
  let para = int8(ord(rtlPara))
  var leftOut = explicit                    # (joiners, controls to place)
  result = newSeq[int8](n)
  template dirOf(l: int8): BidiClass = (if (l and 1) == 1: bR else: bL)
  if not explicit:
    # (no embeddings nor isolates, as nearly all text: one sequence at the
    # paragraph's level)
    var sq = newSeqOfCap[int](n)
    for i in 0 ..< n:
      result[i] = para
      if t[i] != bBN: sq.add i
    if sq.len > 0: resolveSequence(t, result, sq, cps, orig, dirOf(para), dirOf(para))
    leftOut = sq.len < n
  else:
    # BD9: the matching PDI of each isolate initiator (and back)
    var match = newSeq[int](n)
    var open: seq[int]
    for i in 0 ..< n:
      match[i] = -1
      case t[i]
      of bLRI, bRLI, bFSI: open.add i
      of bPDI:
        if open.len > 0:
          let j = open.pop
          match[j] = i
          match[i] = j
      of bB: open.setLen(0)
      else: discard
    # X1 .. X8: the levels of the embeddings, overrides and isolates
    var stack = @[(level: para, over: bON, isolate: false)]
    var overIso, overEmb, validIso = 0
    for i in 0 ..< n:
      let c = t[i]
      let top = stack[^1]
      result[i] = top.level
      case c
      of bRLE, bLRE, bRLO, bLRO, bRLI, bLRI, bFSI:
        let iso = c in isolateBidi
        if iso and top.over != bON: t[i] = top.over
        let rtl = c in {bRLE, bRLO, bRLI} or (c == bFSI and firstStrong(t, i + 1) == 1)
        let nl = if rtl: (top.level + 1) or 1 else: (top.level + 2) and not 1'i8
        if nl <= MaxDepth and overIso == 0 and overEmb == 0:
          if iso: inc validIso
          stack.add (level: nl, over: (if c == bRLO: bR elif c == bLRO: bL else: bON), isolate: iso)
        elif iso: inc overIso
        elif overIso == 0: inc overEmb
      of bPDI:
        if overIso > 0: dec overIso
        elif validIso > 0:
          overEmb = 0
          while not stack[^1].isolate: stack.setLen(stack.len - 1)
          stack.setLen(stack.len - 1)
          dec validIso
        result[i] = stack[^1].level
        if stack[^1].over != bON: t[i] = stack[^1].over
      of bPDF:
        if overIso > 0: discard
        elif overEmb > 0: dec overEmb
        elif not top.isolate and stack.len >= 2: stack.setLen(stack.len - 1)
      of bB:
        result[i] = para
        stack.setLen(1)
        overIso = 0
        overEmb = 0
        validIso = 0
      of bBN: discard
      else:
        if top.over != bON: t[i] = top.over
    let xt = t
    # X9, X10: level runs (the left-out characters skipped), chained across
    # isolates into isolating run sequences
    var kept = newSeqOfCap[int](n)
    for i in 0 ..< n:
      if orig[i] notin removedBidi: kept.add i
    var sqs: seq[seq[int]]
    var waiting: Table[int, int]            # a matching PDI -> its sequence
    var r = 0
    while r < kept.len:
      var q = r + 1
      while q < kept.len and result[kept[q]] == result[kept[r]]: inc q
      let first = kept[r]
      var s = -1
      if orig[first] == bPDI and match[first] >= 0: s = waiting.getOrDefault(first, -1)
      if s < 0:
        s = sqs.len
        sqs.add @[]
      for x in r ..< q: sqs[s].add kept[x]
      let last = kept[q - 1]
      if orig[last] in isolateBidi and match[last] >= 0: waiting[match[last]] = s
      r = q
    # the level before and after each sequence (sos, eos)
    var at = newSeq[int](n)                 # character -> where in `kept`
    for x, i in kept: at[i] = x
    let xl = result
    for sq in sqs:
      let level = xl[sq[0]]
      let ia = at[sq[0]]
      let before = if ia > 0: xl[kept[ia - 1]] else: para
      let ib = at[sq[^1]]
      let after = if ib + 1 < kept.len and orig[sq[^1]] notin isolateBidi: xl[kept[ib + 1]]
                  else: para
      resolveSequence(t, result, sq, cps, xt, dirOf(max(level, before)), dirOf(max(level, after)))
  if leftOut:
    # (a left-out character -- a joiner, an embedding's control: the level
    # before it, so it stays with its word)
    for i in 0 ..< n:
      if orig[i] in removedBidi: result[i] = if i > 0: result[i - 1] else: para
  # L1: separators, and the white space before them and at the end of the
  # line, at the paragraph's level
  var trailing = true
  for i in countdown(n - 1, 0):
    case orig[i]
    of bS, bB:
      result[i] = para
      trailing = true
    of bWS, bBN, bLRE .. bPDI:
      if trailing: result[i] = para
    else: trailing = false

proc visualOrder(levels: seq[int8]): seq[int] =
  ## L2: reverse every run at each level from the highest down to 1.
  let n = levels.len
  result = newSeq[int](n)
  for i in 0 ..< n: result[i] = i
  var hi = 0'i8
  for l in levels: hi = max(hi, l)
  var lvl = hi
  while lvl >= 1:
    var i = 0
    while i < n:
      if levels[result[i]] >= lvl:
        var j = i
        while j < n and levels[result[j]] >= lvl: inc j
        var a = i
        var b = j - 1
        while a < b:
          swap(result[a], result[b])
          inc a
          dec b
        i = j
      else: inc i
    dec lvl

# ---- for laying out styled text -----------------------------------------------------------------

proc bidiInfo*(s: string; rtl = -1): tuple[cps: seq[int]; levels: seq[int8]; rtlPara: bool] =
  ## The characters of `s` (one paragraph, by rune) ready to lay out with
  ## styles: Arabic letters in their joined forms (-1 for a character
  ## joined into another, or invisible), and each one's bidirectional level
  ## (odd: right to left; empty when all is left to right). Show a line's
  ## characters in `visualOrderOf(levels[line])`, mirrored (`mirrored`)
  ## where the level is odd.
  for r in s.runes: result.cps.add int(r)
  let sc = scanText(result.cps)
  if sc.arabic: shapeArabic(result.cps)
  result.rtlPara = if rtl >= 0: rtl == 1 else: textIsRtl(s)
  if sc.bidi or result.rtlPara:
    result.levels = bidiLevels(result.cps, result.rtlPara)
  for c in result.cps.mitems:
    if c >= 0 and isInvisible(c): c = -1

proc visualOrderOf*(levels: openArray[int8]): seq[int] =
  ## The order to show characters with these bidi levels in (their indexes).
  if levels.len == 0: return
  visualOrder(@levels)

proc mirrored*(cp: int): int = mirror(cp)
  ## The mirror image of a bracket (shown in a right-to-left run).

# ---- the characters in the order they are shown ------------------------------------------------

proc visualCodepoints*(s: string): seq[tuple[cp: int; rtl: bool]] =
  ## The characters of `s` (one line) in the order they are shown, Arabic
  ## letters in their joined forms, brackets mirrored in right-to-left runs,
  ## invisible controls left out -- for drawing with a font of one's own (a
  ## bitmap font, a system's text call that does no shaping). `rtl`:
  ## the character is in a right-to-left run (its marks come before it).
  visualCache.withValue(s, v):
    return v[]
  var cps: seq[int]
  for r in s.runes: cps.add int(r)
  let sc = scanText(cps)
  if sc.arabic: shapeArabic(cps)
  let rtlPara = textIsRtl(s) or (rtlInterface and sc.rtl)
  var levels: seq[int8]
  var order: seq[int]
  if sc.bidi or rtlPara:
    levels = bidiLevels(cps, rtlPara)
    order = visualOrder(levels)
  else:
    order = newSeq[int](cps.len)
    for i in 0 ..< cps.len: order[i] = i
  for li in order:
    var cp = cps[li]
    if cp < 0 or isInvisible(cp): continue
    let odd = levels.len > 0 and (levels[li] and 1) == 1
    if odd: cp = mirror(cp)
    result.add (cp, odd)
  if visualCache.len > 2000: visualCache.clear()
  visualCache[s] = result

# ---- runs ---------------------------------------------------------------------------------

proc chainOf(base: FaceId): lent seq[FaceId] =
  ## The faces a character is looked for in, text in face `base`: the face,
  ## its upright, the family's regular (symbols are only there), FreeSans
  ## and FreeSerif in the same style, then their regulars, FreeMono, the
  ## icons.
  if chains[base].len == 0:
    var c: seq[FaceId]
    template add(f: FaceId) =
      if f notin c: c.add f
    let b = isBold(base)
    let i = isItalic(base)
    add base
    add styled(base, b, false)
    add regularOf(base)
    for fam in [fSans, fSerif]:
      add styled(fam, b, i)
      add styled(fam, b, false)
    add fSans
    add fSerif
    add fMono
    add fIcons
    chains[base] = c
  chains[base]

proc isArabic(cp: int): bool {.inline.} =
  cp in 0x0600 .. 0x06FF or cp in 0x0750 .. 0x077F or cp in 0x08A0 .. 0x08FF or
    cp in 0xFB50 .. 0xFDFF or cp in 0xFE70 .. 0xFEFF

proc hasArabicForms(id: FaceId): bool =
  ## Face `id` has the Arabic letters and their joined forms (the ones the
  ## kit draws joined text with).
  if joinsArabic[id] < 0:
    let f = face(id)
    joinsArabic[id] = int8(ord(f.hasGlyph(0x0628) and f.hasGlyph(0xFE91) and f.hasGlyph(0xFEDF)))
  joinsArabic[id] == 1

proc glyphIn(id: FaceId; cp: int): int {.inline.} =
  ## Character `cp` in face `id` (0: none): a font that has the joined
  ## forms of Arabic letters but not the isolated ones -- the letter itself
  ## is its isolated form -- gives its letter.
  result = face(id).glyphOf(cp)
  if result == 0 and cp in 0xFE70 .. 0xFEFF:
    initArabic()
    let letter = isolatedOf.getOrDefault(cp, 0)
    if letter != 0: result = face(id).glyphOf(letter)

proc pick(base: FaceId; cp: int): (FaceId, int) =
  if (cp in 0xE000 .. 0xF8FF or cp in 0xF0000 .. 0xFFFFD) and base != fIcons:
    # (the private use area is the icons': a font's own glyphs there do
    # not stand in for them)
    let g = face(fIcons).glyphOf(cp)
    if g != 0: return (fIcons, g)
  if isArabic(cp) and not isMark(cp) and cp != 0x0640 and cp notin 0x0660 .. 0x066D and
     cp notin [0x060C, 0x061B, 0x061F]:
    # Arabic letters: from the text's own face when it joins them, else
    # from the Arabic face -- FreeSerif, bold or not -- never from another
    # style of the family (FreeMono's Arabic is its regular's only), and
    # all of a word from one font
    for id in [base, arabicSource(isBold(base)), arabicSource(false)]:
      if hasArabicForms(id):
        let g = glyphIn(id, cp)
        if g != 0: return (id, g)
  for id in chainOf(base):
    let g = glyphIn(id, cp)
    if g != 0: return (id, g)
  (base, 0)

proc isAscii(s: string): bool =
  for c in s:
    if ord(c) < 32 or ord(c) > 126: return false
  true

proc em(id: FaceId): float32 {.inline.} = float32(face(id).unitsPerEm)

template parsed(id: FaceId) =
  ## (face `id` parsed, its tables filled: without taking a reference to
  ## it -- `face` hands out one, counted, on every call)
  if faces[id] == nil: discard face(id)

proc asciiWidth(s: string; base: FaceId): float32 =
  parsed(base)
  let kern = addr asciiKern[base]
  var prev = -1
  for c in s:
    let k = ord(c) - 32
    result += asciiAdv[base][ord(c)]
    if prev >= 0: result += kern[][prev * 96 + k]
    prev = k

proc build(s: string; base: FaceId; rtl: int): Run =
  ## `rtl`: -1 from the text, 0 left to right, 1 right to left.
  var cps: seq[int]
  for r in s.runes: cps.add int(r)
  let sc = scanText(cps)
  if sc.arabic: shapeArabic(cps)
  result.rtl = if rtl >= 0: rtl == 1 else: textIsRtl(s) or (rtlInterface and sc.rtl)
  var order: seq[int]
  var levels: seq[int8]
  if sc.bidi or result.rtl:
    levels = bidiLevels(cps, result.rtl)
    order = visualOrder(levels)
  else:
    order = newSeq[int](cps.len)
    for i in 0 ..< cps.len: order[i] = i
  # glyphs in visual order
  var at = newSeq[int](cps.len)          # logical index -> glyph index
  for i in 0 ..< at.len: at[i] = -1
  var x = 0'f32
  var prevFace = fIcons
  var prevGid = 0
  for li in order:
    var cp = cps[li]
    if cp < 0 or isInvisible(cp): continue
    if levels.len > 0 and (levels[li] and 1) == 1: cp = mirror(cp)
    if cp == 9:
      let (fid, g) = pick(base, 32)
      result.glyphs.add PGlyph(face: fid, gid: uint16(g), x: x)
      x += asciiAdv[fid][32] * TabStops
      prevGid = 0
      continue
    var (fid, g) = pick(base, cp)
    if g == 0:
      result.missing = true
      (fid, g) = (base, 0)
    let f = face(fid)
    var adv = float32(f.advance(g)) / em(fid) + boldExtra[fid]
    var gx = x
    if fid == fIcons:
      gx += (IconCell - adv) / 2
      adv = IconCell
    elif fid == prevFace and prevGid != 0:
      let k = float32(f.kerning(prevGid, g)) / em(fid)
      gx += k
      x += k
    at[li] = result.glyphs.len
    result.glyphs.add PGlyph(face: fid, gid: uint16(g), x: gx)
    x += adv
    if not isMark(cp):
      prevFace = fid
      prevGid = g
  result.width = x
  # marks without a positioning table: centered on their letter, and
  # lifted (or lowered) clear of it
  for li in 0 ..< cps.len:
    if cps[li] < 0 or not isMark(cps[li]) or at[li] < 0: continue
    var b = li - 1
    while b >= 0 and (cps[b] < 0 or isMark(cps[b])): dec b
    if b < 0 or at[b] < 0: continue
    let mg = addr result.glyphs[at[li]]
    let bg = result.glyphs[at[b]]
    let mf = face(mg.face)
    let bf = face(bg.face)
    let m = mf.bounds(int(mg.gid))
    let bb = bf.bounds(int(bg.gid))
    if m.x1 <= m.x0: continue
    let units = em(mg.face)
    mg.x = bg.x + (float32(bb.x0 + bb.x1) - float32(m.x0 + m.x1)) / 2 / units
    let gap = 0.06'f32 * units
    if m.y0 > 0:                          # above
      let lift = float32(bb.y1) + gap - float32(m.y0)
      if lift > 0: mg.y = lift / units
    elif m.y1 < 0:                        # below
      let drop = float32(m.y1) - (float32(bb.y0) - gap)
      if drop > 0: mg.y = -drop / units

proc setRtlInterface*(on: bool) =
  ## A right-to-left interface (Arabic, `setUiLanguage`): a line that mixes
  ## right-to-left letters with others reads right to left ("1.0 GB متاحة
  ## من 252 GB" in its order), as the interface does; a line without them
  ## (a file's name) keeps the direction of its first letter. Off: every
  ## line follows its first letter.
  if on == rtlInterface: return
  rtlInterface = on
  visualCache.clear()
  for id in FaceId:
    runCache[id].clear()
    rtlCache[id].clear()

proc shownRtl*(s: string): bool =
  ## Whether line `s`, drawn on its own (`shape` with `rtl` -1), reads right
  ## to left: its first strong letter, or in a right-to-left interface any
  ## right-to-left letter in it. A text box places its caret by it.
  if textIsRtl(s): return true
  if not rtlInterface: return false
  for r in s.runes:
    if bidiClass(int(r)) in {bR, bAL}: return true

proc plainLetters*(s: string): string =
  ## `s` with Arabic presentation forms (the joined shapes some programs
  ## store, text copied from an old PDF) turned back into the letters they
  ## show: "ﻣﺮﺣﺒﺎ" -> "مرحبا", "ﻻ" -> "لا". Text is kept in its letters;
  ## the kit joins them when it draws them.
  var any = false
  for r in s.runes:
    if int(r) in 0xFB50 .. 0xFDFF or int(r) in 0xFE70 .. 0xFEFC:
      any = true
      break
  if not any: return s
  initArabic()
  var back {.global.}: Table[int, string]
  if back.len == 0:
    for (k, v) in arabicForms:
      for f in v:
        if f != 0: back[int(f)] = $Rune(int(k))
    for (k, iso, fin) in lamAlef:
      back[int(iso)] = "\u0644" & $Rune(int(k))
      back[int(fin)] = "\u0644" & $Rune(int(k))
  for r in s.runes:
    let t = back.getOrDefault(int(r), "")
    if t.len > 0: result.add t else: result.add r

proc shapeCached*(s: string; base = fSans; rtl = -1): ptr Run =
  ## `shape`, the run kept in the cache itself rather than a copy of it --
  ## for reading at once (its width, its glyphs): it stays valid only until
  ## the next string is shaped. `rtl` 1 or -1 (0 is never kept: see `shape`).
  let cache = if rtl == 1: addr rtlCache[base] else: addr runCache[base]
  if cache[].len > 4000: cache[].clear()
  cache[].withValue(s, r):
    return r
  cache[][s] = build(s, base, rtl)
  addr cache[][s]

proc shape*(s: string; base = fSans; rtl = -1): Run =
  ## The glyphs of `s` (one line) in `base`'s style; `rtl` 1 makes it a
  ## right-to-left paragraph, 0 left-to-right, -1 (the default) follows
  ## its first letter. Cached: the same string costs a table lookup the
  ## next time.
  if rtl == 0:
    return build(s, base, rtl)
  shapeCached(s, base, rtl)[]

proc widthEm*(s: string; base = fSans; rtl = -1): float32 =
  ## Width of `s` in ems.
  if s.len == 0: return 0
  parsed(base)
  if isAscii(s) and rtl != 1: asciiWidth(s, base)
  elif rtl == 0: build(s, base, rtl).width
  else: shapeCached(s, base, rtl).width

iterator asciiGlyphs*(s: openArray[char]; base: FaceId): PGlyph =
  ## The glyphs of a plain ASCII string, without building a run.
  let f = face(base)
  let kern = addr asciiKern[base]
  var x = 0'f32
  var prev = -1
  for c in s:
    let k = ord(c) - 32
    if prev >= 0: x += kern[][prev * 96 + k]
    yield PGlyph(face: base, gid: uint16(f.glyphOf(ord(c))), x: x)
    x += asciiAdv[base][ord(c)]
    prev = k

proc plainAscii*(s: openArray[char]): bool =
  ## Every character of `s` is printable ASCII (no control characters).
  for c in s:
    if ord(c) < 32 or ord(c) > 126: return false
  true

proc hasGlyphs*(s: string; base = fSans): bool =
  ## Whether the built-in faces draw every character of `s`.
  if isAscii(s): true else: not shapeCached(s, base).missing

proc fontData*(id: FaceId): lent string =
  ## The bytes of the TrueType file of face `id` (FreeSans, FreeSerif,
  ## FreeMono, the icons, a font file: a face of a .ttc as a file of its
  ## own) -- for code that embeds the glyphs elsewhere (`retroui/pdf`
  ## puts their outlines into PDF files). The same bytes the screen uses:
  ## nothing is copied.
  fontFiles[dataOf(id)]

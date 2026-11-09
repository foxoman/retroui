## Photoshop documents, .psd and .psb (the big ones), read and written in
## plain Nim.
##
## Read: every color mode (bitmap, grayscale, indexed, RGB, CMYK,
## multichannel, duotone, Lab), 1, 8, 16 and 32 bits a channel, raw, RLE
## and ZIP data (with and without prediction), the merged picture, and the
## layers -- their pixels, masks, blend modes, opacity and fill, visibility,
## clipping, groups, type layers (their pixels, what they say, their type
## tool data: transform, text descriptor, EngineData, warp), placed layers
## (Smart Objects: their place, size and id, and the files embedded for
## them), fill and adjustment layers, layer effects (as action
## descriptors, `PsdValue`).
## Written: 8 bits in RGB, grayscale or CMYK, the layers RLE-coded with
## their masks, names (in Unicode), blend modes, opacity and fill, simple
## adjustment layers, more additional information given by the caller
## (type and placed layers), the embedded files of Smart Objects, and the
## merged picture.
##
## The layers can also be had as a TIFF keeps them (tag 37724, "Adobe
## Photoshop Document Data Block"): `tiffLayerBlock`, `readTiffLayers`.
##
## Type layers keep their styled text in EngineData, a text of their own
## (`parseEngineData`, `engineDataText`).
##
## .. code-block:: nim
##   let doc = readPsd(readFile("poster.psd"))
##   for L in doc.layers: echo L.name, " ", L.blend, " ", L.w, "x", L.h
##   writeFile("copy.psd", writePsd(doc))

import std/[strutils, math, tables, unicode]
import codec, busy, photoinks

type
  PsdError* = object of CatchableError
    ## Not a Photoshop document, or a damaged one.

  PsdColorMode* = enum
    ## A document's color mode, by the number the file gives it.
    pmBitmap = 0, pmGray = 1, pmIndexed = 2, pmRGB = 3, pmCMYK = 4, pmMultichannel = 7, pmDuotone = 8,
    pmLab = 9

  PsdKind* = enum
    ## The kind of value in an action descriptor.
    pkNone, pkLong, pkDouble, pkUnit, pkBool, pkText, pkEnum, pkObject, pkList, pkClass, pkRaw

  PsdValue* = ref object
    ## A value of an action descriptor (what Photoshop keeps its effects,
    ## text and fill layers in).
    case kind*: PsdKind         ## which of the fields below holds the value
    of pkLong: i*: int          ## an integer
    of pkDouble: f*: float      ## a real number
    of pkUnit:
      unit*: string             ## "#Pxl", "#Prc", "#Ang", "#Pnt"...
      uf*: float                ## ... the number in that unit
    of pkBool: b*: bool         ## a boolean
    of pkText: s*: string       ## a text (UTF-8)
    of pkEnum:
      etype*, evalue*: string   ## an enumerated value: its type and the value ("BlnM", "Mltp")
    of pkObject:
      cls*: string              ## an object's class ("Grdn", "RGBC")
      items*: seq[(string, PsdValue)]  ## ... its keys and values, in order
    of pkList:
      list*: seq[PsdValue]      ## a list's values
      floatUnit*: string        ## (a list of numbers in one unit, 'UnFl': the unit; written so)
    of pkClass: className*: string  ## a class reference
    of pkRaw: raw*: string      ## raw data ('tdta'), as it is
    of pkNone: discard

  PsdSection* = enum
    ## A layer, or the start or end of a group.
    psLayer, psGroupOpen, psGroupClosed, psGroupEnd

  PsdMask* = object
    ## A layer's mask: its rectangle and gray values (255 shows), what is
    ## outside it.
    x*, y*, w*, h*: int         ## its rectangle on the canvas
    px*: seq[uint8]             ## w x h gray values
    outside*: int               ## 0 or 255
    disabled*: bool             ## turned off (kept, not used)
    density*: int               ## Properties: how much it hides, 0..255 (255: all of it)
    feather*: float             ## ... softened by so many pixels

  PsdKnot* = object
    ## A point of a path with its two direction handles (canvas pixels).
    pre*, anchor*, post*: (float, float)  ## the handle before, the point, the handle after

  PsdSubpath* = object
    ## A subpath of a vector mask.
    knots*: seq[PsdKnot]        ## its points, in order
    closed*: bool               ## its last point joins its first
    operation*: int             ## 0 exclude, 1 add, 2 subtract, 3 intersect; -1 with the one before

  PsdLayer* = object
    ## A layer as the file has it (or a group's start or end: `section`).
    name*: string               ## its name (UTF-8)
    x*, y*, w*, h*: int         ## its rectangle on the canvas
    px*: seq[uint32]            ## w x h, 0xAARRGGBB (straight)
    opacity*: int               ## 0..255
    fill*: int                  ## Fill Opacity 0..255
    blend*: string              ## the blend mode's key: "norm", "mul ", "scrn"...
    visible*: bool              ## shown
    clipping*: bool             ## clipped to the layer under it
    protectAlpha*: bool         ## Lock Transparent Pixels
    hasMask*: bool              ## it has a layer mask (`mask`)
    mask*: PsdMask              ## its layer mask
    section*: PsdSection        ## a layer, or where a group starts or ends
    text*: string               ## a type layer: what it says
    effects*: PsdValue          ## its layer effects (lfx2), or nil
    adjustment*: string         ## an adjustment or fill layer's key ("levl", "SoCo"...), "" none
    adjustData*: string         ## ... its data
    adjustDesc*: PsdValue       ## ... as a descriptor, when it is one
    vectorMask*: seq[PsdSubpath]   ## its vector mask (a shape layer's outline)
    hasVectorMask*: bool        ## it has one
    vectorInvert*, vectorDisabled*, vectorFillAll*: bool
      ## the vector mask inverted, turned off, or showing all where it has no path
    vectorDensity*: int         ## the vector mask's density, 0..255 (0: not given: all)
    vectorFeather*: float       ## ... softened by so many pixels
    strokeDesc*: PsdValue       ## a shape's stroke (vstk)
    px16*: seq[uint16]          ## a 16-bit file's layer: its pixels at 16 bits, R G B A for each
                                ## (w x h x 4; gray files: the gray three times); empty else
    ranges*: seq[array[4, int]] ## Blend If: this layer's then the ones under's range, for gray then
                                ## each channel (black, black's split, white's split, white)
    extra*: seq[(string, string)]  ## (writing) more additional information: key, data
    textTransform*: array[6, float]  ## a type layer: its transform (xx, xy, yx, yy, tx, ty)
    textDesc*: PsdValue         ## ... its text descriptor ('TxLr': "Txt ", "EngineData" (raw), bounds...)
    textWarp*: PsdValue         ## ... its warp ('warp': warpStyle, warpValue...)
    placedId*: string           ## a placed layer (Smart Object): the id of the file it shows
                                ## (`PsdDoc.linked`), "" not one
    placedTransform*: array[8, float]  ## ... where the file's corners are (x, y of top left, top
                                       ## right, bottom right, bottom left)
    smartDesc*: PsdValue        ## ... its Smart Object descriptor ('SoLd': Idnt, Trnf, "Sz  "...)

  PsdLinkedFile* = object
    ## A file embedded in the document for its Smart Objects.
    id*: string                 ## (a GUID: what placed layers name it by)
    name*: string               ## its file name ("photo.png")
    fileType*: string           ## 4 letters: "png ", "JPEG", "8BPB" (.psb), "8BPS"...
    data*: string               ## the file's bytes

  PsdDoc* = object
    ## A Photoshop document as the file has it (`readPsd`, `writePsd`).
    w*, h*: int                 ## its size in pixels
    depth*: int                 ## of the file (8, 16, 32; 1 for bitmap)
    mode*: PsdColorMode         ## its color mode
    dpi*: float                 ## pixels per inch
    big*: bool                  ## .psb
    layers*: seq[PsdLayer]      ## bottom first
    composite*: seq[uint32]     ## the merged picture (w x h), when the file has one
    composite16*: seq[uint16]   ## ... at 16 bits (R G B A), when it is a 16-bit file (and writing one)
    palette*: seq[uint32]       ## Indexed Color
    cmykComposite*: seq[uint8]  ## CMYK files: the merged picture's ink, 4 bytes a pixel (255 full)
    globalAngle*: int           ## the global light's angle (degrees)
    globalAltitude*: int        ## ... and its altitude (degrees)
    icc*: string                ## its color profile (ICC), "" none
    linked*: seq[PsdLinkedFile] ## the files its Smart Objects show (embedded: 'lnk2')

proc fail(msg: string) {.noreturn.} = raise newException(PsdError, msg)

# ---- reading bytes ------------------------------------------------------------------------------------

type Reader = object
  s: ptr UncheckedArray[char]
  len: int
  pos: int
  le: bool                      # little-endian (a TIFF in Intel order keeps its layers so): the
                                # numbers' bytes and the 4-letter keys the other way round

proc need(r: Reader; n: int) {.inline.} =
  if n < 0 or r.pos + n > r.len: fail("the document ends too soon")

proc u8(r: var Reader): int =
  r.need(1)
  result = ord(r.s[r.pos])
  inc r.pos

proc u16(r: var Reader): int =
  r.need(2)
  result = if r.le: (ord(r.s[r.pos + 1]) shl 8) or ord(r.s[r.pos])
           else: (ord(r.s[r.pos]) shl 8) or ord(r.s[r.pos + 1])
  r.pos += 2

proc i16(r: var Reader): int =
  let v = r.u16
  if v >= 0x8000: v - 0x10000 else: v

proc u32(r: var Reader): int =
  r.need(4)
  result = if r.le: (ord(r.s[r.pos + 3]) shl 24) or (ord(r.s[r.pos + 2]) shl 16) or (ord(r.s[r.pos + 1]) shl 8) or
                    ord(r.s[r.pos])
           else: (ord(r.s[r.pos]) shl 24) or (ord(r.s[r.pos + 1]) shl 16) or (ord(r.s[r.pos + 2]) shl 8) or
                 ord(r.s[r.pos + 3])
  r.pos += 4

proc i32(r: var Reader): int =
  int(cast[int32](uint32(int64(r.u32) and 0xFFFF_FFFF'i64)))

proc u64(r: var Reader): int =
  var hi = r.u32
  var lo = r.u32
  if r.le: swap(hi, lo)
  if hi > 0x7FFF_FFFF: fail("a length too big")
  when sizeof(int) < 8:
    if hi != 0: fail("a length too big")
    lo
  else:
    (hi shl 32) or lo

proc len(r: var Reader; big: bool): int =
  ## A length: 8 bytes in .psb, 4 in .psd.
  if big: r.u64 else: r.u32

proc f64(r: var Reader): float =
  var hi = uint64(r.u32)
  var lo = uint64(r.u32)
  if r.le: swap(hi, lo)
  cast[float]((hi shl 32) or lo)

proc f32(r: var Reader): float =
  float(cast[float32](uint32(r.u32)))

proc bytes(r: var Reader; n: int): string =
  r.need(n)
  result = newString(n)
  if n > 0: copyMem(addr result[0], addr r.s[r.pos], n)
  r.pos += n

proc key4(r: var Reader): string =
  result = r.bytes(4)
  if r.le: result = result[3] & result[2] & result[1] & result[0]

proc skip(r: var Reader; n: int) =
  r.need(n)
  r.pos += n

proc unicodeStr(r: var Reader): string =
  ## A length (in UTF-16 units) and the UTF-16 big-endian text.
  let n = r.u32
  if n < 0 or n > 1_000_000: fail("a damaged text")
  var i = 0
  while i < n:
    var c = r.u16
    inc i
    if c >= 0xD800 and c < 0xDC00 and i < n:
      let lo = r.u16
      inc i
      c = 0x10000 + ((c - 0xD800) shl 10) + (lo - 0xDC00)
    if c != 0: result.add Rune(c).toUTF8

proc pascal(r: var Reader; pad: int): string =
  ## A Pascal string, its whole (length byte too) padded to `pad`.
  let n = r.u8
  result = r.bytes(n)
  var total = n + 1
  while total mod pad != 0:
    r.skip(1)
    inc total

# ---- action descriptors -------------------------------------------------------------------------------

proc idOf(r: var Reader): string =
  ## A key or class id: a length and its letters, or (length 0) 4 letters.
  let n = r.u32
  if n == 0: r.key4() else: r.bytes(n)

proc descriptor(r: var Reader): PsdValue

proc valueOf(r: var Reader; t: string): PsdValue =
  case t
  of "long": PsdValue(kind: pkLong, i: r.i32)
  of "comp":
    let hi = r.i32
    let lo = r.u32
    PsdValue(kind: pkLong, i: int(clamp(int64(hi) * 0x1_0000_0000'i64 + (int64(lo) and 0xFFFF_FFFF'i64),
                                       int64(low(int)), int64(high(int)))))
  of "doub": PsdValue(kind: pkDouble, f: r.f64)
  of "UntF":
    let u = r.key4()
    PsdValue(kind: pkUnit, unit: u, uf: r.f64)
  of "bool": PsdValue(kind: pkBool, b: r.u8 != 0)
  of "TEXT": PsdValue(kind: pkText, s: r.unicodeStr)
  of "enum":
    let ty = r.idOf
    PsdValue(kind: pkEnum, etype: ty, evalue: r.idOf)
  of "Objc", "GlbO": r.descriptor
  of "VlLs":
    let n = r.u32
    if n > 100_000: fail("a damaged list")
    var v = PsdValue(kind: pkList)
    for _ in 0 ..< n:
      let tt = r.key4()
      v.list.add r.valueOf(tt)
    v
  of "type", "GlbC":
    discard r.unicodeStr
    PsdValue(kind: pkClass, className: r.idOf)
  of "alis", "tdta", "Pth ":
    let n = r.u32
    PsdValue(kind: pkRaw, raw: r.bytes(n))
  of "UnFl":
    let u = r.key4()
    let n = r.u32
    if n > 1_000_000: fail("a damaged list")
    var v = PsdValue(kind: pkList, floatUnit: u)
    for _ in 0 ..< n: v.list.add PsdValue(kind: pkUnit, unit: u, uf: r.f64)
    v
  of "obj ":
    # a reference: its items (kinds of their own)
    let n = r.u32
    if n > 10_000: fail("a damaged reference")
    for _ in 0 ..< n:
      let k = r.key4()
      case k
      of "prop":
        discard r.unicodeStr; discard r.idOf; discard r.idOf
      of "Clss":
        discard r.unicodeStr; discard r.idOf
      of "Enmr":
        discard r.unicodeStr; discard r.idOf; discard r.idOf; discard r.idOf
      of "rele":
        discard r.unicodeStr; discard r.idOf; discard r.u32
      of "Idnt", "indx": discard r.u32
      of "name":
        discard r.unicodeStr; discard r.idOf; discard r.unicodeStr
      else: fail("an unknown reference")
    PsdValue(kind: pkNone)
  of "ObAr":
    # an object array (a warp's mesh points...): read as one object whose
    # items are the lists ("Hrzn": its numbers, "Vrtc": ...)
    discard r.u32                         # (version, 16)
    discard r.unicodeStr
    var v = PsdValue(kind: pkObject, cls: r.idOf)
    let n = r.u32
    if n > 100_000: fail("a damaged object array")
    for _ in 0 ..< n:
      let k = r.idOf
      let tt = r.key4()
      v.items.add (k, r.valueOf(tt))
    v
  else: fail("an unknown descriptor value '" & t & "'")

proc descriptor(r: var Reader): PsdValue =
  discard r.unicodeStr
  result = PsdValue(kind: pkObject, cls: r.idOf)
  let n = r.u32
  if n > 100_000: fail("a damaged descriptor")
  for _ in 0 ..< n:
    let k = r.idOf
    let t = r.key4()
    result.items.add (k, r.valueOf(t))

proc `[]`*(v: PsdValue; key: string): PsdValue =
  ## An item of a descriptor (nil when there is none).
  if v == nil or v.kind != pkObject: return nil
  for (k, x) in v.items:
    if k == key: return x

proc num*(v: PsdValue; d = 0.0): float =
  ## A number, whatever kind it is (`d` when it is none).
  if v == nil: return d
  case v.kind
  of pkLong: v.i.float
  of pkDouble: v.f
  of pkUnit: v.uf
  of pkBool: (if v.b: 1.0 else: 0.0)
  else: d

proc flag*(v: PsdValue; d = false): bool =
  ## A boolean (`d` when it is none).
  if v == nil or v.kind != pkBool: d else: v.b

proc enumValue*(v: PsdValue): string =
  ## An enumerated value's name ("" when it is none).
  if v == nil or v.kind != pkEnum: "" else: v.evalue

proc labToRgb*(L, a, b: float): (int, int, int)
  ## CIE Lab (D50, as Photoshop keeps it) to sRGB.

proc rgbOf*(v: PsdValue): uint32 =
  ## A color item ("RGBC" with Rd, Grn, Bl; or gray, CMYK, Lab, HSB
  ## roughly) as 0xFFRRGGBB.
  if v == nil or v.kind != pkObject: return 0xFF000000'u32
  template c255(x: float): uint32 = uint32(clamp(int(round(x)), 0, 255))
  case v.cls
  of "RGBC":
    let r = v["Rd  "].num
    let g = v["Grn "].num
    let b = v["Bl  "].num
    0xFF000000'u32 or (c255(r) shl 16) or (c255(g) shl 8) or c255(b)
  of "Grsc":
    let g = 255 - v["Gry "].num * 2.55
    0xFF000000'u32 or (c255(g) shl 16) or (c255(g) shl 8) or c255(g)
  of "LbCl":
    let (r, g, b) = labToRgb(v["Lmnc"].num, v["A   "].num, v["B   "].num)
    0xFF000000'u32 or (c255(r.float) shl 16) or (c255(g.float) shl 8) or c255(b.float)
  of "HSBC":
    let h = v["H   "].num / 60
    let sa = v["Strt"].num / 100
    let br = v["Brgh"].num / 100 * 255
    let i = int(floor(h)) mod 6
    let f = h - floor(h)
    let p = br * (1 - sa)
    let q = br * (1 - sa * f)
    let t = br * (1 - sa * (1 - f))
    let (r, g, b) = case i
                    of 0: (br, t, p)
                    of 1: (q, br, p)
                    of 2: (p, br, t)
                    of 3: (p, q, br)
                    of 4: (t, p, br)
                    else: (br, p, q)
    0xFF000000'u32 or (c255(r) shl 16) or (c255(g) shl 8) or c255(b)
  of "CMYC":
    printed(int(round(v["Cyn "].num * 2.55)), int(round(v["Mgnt"].num * 2.55)), int(round(v["Ylw "].num * 2.55)),
            int(round(v["Blck"].num * 2.55)))
  else: 0xFF000000'u32

# ---- EngineData: a type layer's styled text ------------------------------------------------------------

type
  EngineKind* = enum
    ## The kind of value in EngineData.
    ekNull, ekBool, ekNum, ekText, ekName, ekList, ekDict

  EngineValue* = ref object
    ## A value of EngineData, the text (PostScript-like: `<< /Key value >>`,
    ## `[ ]`, `(text)`) in which Photoshop keeps a type layer's characters,
    ## runs of styles and paragraphs, fonts.
    case kind*: EngineKind      ## which of the fields below holds the value
    of ekBool: b*: bool         ## a boolean
    of ekNum:
      n*: float                 ## a number
      isInt*: bool              ## written without a decimal point
    of ekText, ekName: s*: string   ## a text (UTF-8), a name (without its "/")
    of ekList: items*: seq[EngineValue]  ## a list's values
    of ekDict: keys*: seq[(string, EngineValue)]  ## a dictionary's keys and values, in order
    of ekNull: discard

proc `[]`*(v: EngineValue; key: string): EngineValue =
  ## An item of a dictionary (nil when there is none).
  if v == nil or v.kind != ekDict: return nil
  for (k, x) in v.keys:
    if k == key: return x

proc `[]`*(v: EngineValue; i: int): EngineValue =
  ## An item of a list (nil when there is none).
  if v == nil or v.kind != ekList or i < 0 or i >= v.items.len: nil else: v.items[i]

proc `[]=`*(v: EngineValue; key: string; x: EngineValue) =
  ## Sets an item of a dictionary (added at its end when it is new).
  if v == nil or v.kind != ekDict: return
  for e in v.keys.mitems:
    if e[0] == key:
      e[1] = x
      return
  v.keys.add (key, x)

proc num*(v: EngineValue; d = 0.0): float =
  ## A number (`d` when it is none; true is 1).
  if v == nil: d
  elif v.kind == ekNum: v.n
  elif v.kind == ekBool: (if v.b: 1.0 else: 0.0)
  else: d

proc flag*(v: EngineValue; d = false): bool =
  ## A boolean (`d` when it is none).
  if v == nil or v.kind != ekBool: d else: v.b

proc text*(v: EngineValue): string =
  ## A text or a name ("" when it is none).
  if v == nil or v.kind notin {ekText, ekName}: "" else: v.s

proc len*(v: EngineValue): int =
  ## How many items a list or a dictionary has.
  if v == nil: 0
  elif v.kind == ekList: v.items.len
  elif v.kind == ekDict: v.keys.len
  else: 0

proc eInt*(i: int): EngineValue = EngineValue(kind: ekNum, n: i.float, isInt: true)
  ## A whole number.
proc eFloat*(f: float): EngineValue = EngineValue(kind: ekNum, n: f)
  ## A number written with its decimals.
proc eBool*(b: bool): EngineValue = EngineValue(kind: ekBool, b: b)
  ## A boolean.
proc eText*(s: string): EngineValue = EngineValue(kind: ekText, s: s)
  ## A text (written in UTF-16).
proc eList*(items: varargs[EngineValue]): EngineValue = EngineValue(kind: ekList, items: @items)
  ## A list.
proc eFloats*(fs: varargs[float]): EngineValue =
  ## A list of numbers written with their decimals.
  result = EngineValue(kind: ekList)
  for f in fs: result.items.add eFloat(f)
proc eDict*(keys: varargs[(string, EngineValue)]): EngineValue = EngineValue(kind: ekDict, keys: @keys)
  ## A dictionary, its keys in this order.

proc parseEngineData*(data: string): EngineValue =
  ## EngineData (a type layer's 'EngineData' bytes) as values: its texts
  ## (UTF-16, their "(", ")" and "\" escaped) made UTF-8. Raises `PsdError`
  ## when it is damaged.
  var i = 0
  var n = data.len
  while n > 0 and data[n - 1] == '\0': dec n
  proc white(c: char): bool = c in {' ', '\t', '\r', '\n'}
  proc skipWhite() =
    while i < n and white(data[i]): inc i
  proc textByte(): int =
    var c = ord(data[i])
    inc i
    if c == 92 and i < n:                  # (\: the next byte as it is)
      c = ord(data[i])
      inc i
    c
  proc readText(): string =
    # (after its "(")
    if i + 1 < n and data[i] == '\xFE' and data[i + 1] == '\xFF':
      i += 2
      var units: seq[int]
      while i < n and data[i] != ')':
        let hi = textByte()
        if i >= n: break
        let lo = textByte()
        units.add (hi shl 8) or lo
      inc i
      var k = 0
      while k < units.len:
        var c = units[k]
        inc k
        if c >= 0xD800 and c < 0xDC00 and k < units.len and units[k] >= 0xDC00 and units[k] < 0xE000:
          c = 0x10000 + ((c - 0xD800) shl 10) + (units[k] - 0xDC00)
          inc k
        result.add Rune(c).toUTF8
    else:
      while i < n and data[i] != ')': result.add char(textByte())
      inc i
  var stack: seq[EngineValue]
  var keys: seq[string]                    # (each dictionary's key waiting for its value; "" none)
  var root: EngineValue
  proc put(v: EngineValue) =
    if stack.len == 0:
      if root == nil: root = v
      return
    let top = stack[^1]
    if top.kind == ekList: top.items.add v
    elif keys[^1].len > 0:
      top.keys.add (keys[^1], v)
      keys[^1] = ""
  proc open(v: EngineValue) =
    if root == nil and stack.len == 0: root = v
    else: put(v)
    stack.add v
    keys.add ""
  skipWhite()
  while i < n:
    let c = data[i]
    if c == '<' and i + 1 < n and data[i + 1] == '<':
      i += 2
      open(EngineValue(kind: ekDict))
    elif c == '>' and i + 1 < n and data[i + 1] == '>':
      i += 2
      if stack.len == 0: fail("damaged EngineData")
      discard stack.pop()
      discard keys.pop()
    elif c == '/':
      inc i
      let st = i
      while i < n and not white(data[i]) and data[i] notin {'/', '(', '[', ']', '<', '>'}: inc i
      let name = data[st ..< i]
      if stack.len == 0: open(EngineValue(kind: ekDict))
      let top = stack[^1]
      if top.kind == ekDict and keys[^1].len == 0: keys[^1] = name
      else: put(EngineValue(kind: ekName, s: name))
    elif c == '(':
      inc i
      put(EngineValue(kind: ekText, s: readText()))
    elif c == '[':
      inc i
      open(EngineValue(kind: ekList))
    elif c == ']':
      inc i
      if stack.len == 0 or stack[^1].kind != ekList: fail("damaged EngineData")
      discard stack.pop()
      discard keys.pop()
    elif c in {'0' .. '9', '.', '-'}:
      let st = i
      while i < n and data[i] in {'0' .. '9', '.', '-', 'e', 'E', '+'}: inc i
      let s = data[st ..< i]
      let f = try: parseFloat(s) except ValueError: 0.0
      put(EngineValue(kind: ekNum, n: f, isInt: '.' notin s))
    elif data.continuesWith("true", i):
      i += 4
      put(eBool(true))
    elif data.continuesWith("false", i):
      i += 5
      put(eBool(false))
    elif data.continuesWith("null", i):
      i += 4
      put(EngineValue(kind: ekNull))
    else: inc i                            # (what is not known: passed over)
    skipWhite()
  if root == nil: fail("empty EngineData")
  root

proc engineNumber(v: EngineValue): string =
  ## A number as Photoshop writes it ("12", "30.0", ".5", "-.25").
  var f = v.n
  if f != f or f == Inf or f == NegInf: f = 0
  if v.isInt and f == round(f) and abs(f) < 1e15: return $int(f)
  result = formatFloat(f, ffDecimal, 5)
  while result.len > 2 and result[^1] == '0' and result[^2] != '.': result.setLen(result.len - 1)
  if result.startsWith("0.") and result.len > 2 and result[2 .. ^1] != "0": result = result[1 .. ^1]
  elif result.startsWith("-0.") and result.len > 3: result = "-" & result[2 .. ^1]
  if result == "-.0" or result == "-0.0": result = "0.0"

proc engineDataText*(v: EngineValue): string =
  ## Values as EngineData (as Photoshop writes it: tabs, a key a line,
  ## texts in UTF-16 with their "(", ")", "\" bytes escaped).
  var o = "\n\n"
  proc indent(d: int) =
    for _ in 0 ..< d: o.add '\t'
  proc textOf(s: string) =
    o.add "(\xFE\xFF"
    proc b(x: int) =
      if x in [0x28, 0x29, 0x5C]: o.add '\\'
      o.add char(x)
    for r in s.runes:
      var c = int(r)
      if c >= 0x10000:
        c -= 0x10000
        let hi = 0xD800 + (c shr 10)
        let lo = 0xDC00 + (c and 0x3FF)
        b(hi shr 8); b(hi and 255); b(lo shr 8); b(lo and 255)
      else:
        b(c shr 8); b(c and 255)
    o.add ')'
  proc value(x: EngineValue; d: int; inKey: bool) =
    template pre() =
      if inKey: o.add ' ' else: indent(d)
    if x == nil or x.kind == ekNull:
      pre(); o.add "null"
      return
    case x.kind
    of ekBool:
      pre(); o.add(if x.b: "true" else: "false")
    of ekNum:
      pre(); o.add engineNumber(x)
    of ekText:
      pre(); textOf(x.s)
    of ekName:
      pre(); o.add '/'; o.add x.s
    of ekList:
      pre()
      var plain = true
      for it in x.items:
        if it == nil or it.kind != ekNum: plain = false
      if plain:
        o.add '['
        for it in x.items:
          o.add ' '
          o.add engineNumber(it)
        o.add " ]"
      else:
        o.add "[\n"
        for it in x.items:
          value(it, d, false)
          o.add '\n'
        indent(d)
        o.add ']'
    of ekDict:
      if inKey: o.add '\n'
      indent(d)
      o.add "<<\n"
      for (k, it) in x.keys:
        indent(d + 1)
        o.add '/'
        o.add k
        value(it, d + 1, true)
        o.add '\n'
      indent(d)
      o.add ">>"
    of ekNull: discard
  value(v, 0, false)
  o

# ---- channel data ---------------------------------------------------------------------------------------

proc unpack(src: ptr UncheckedArray[char]; srcLen: int; o: var seq[byte]; at, n: int): int =
  ## PackBits: `n` bytes into `o` from `at`; the bytes of `src` read.
  var i = 0
  var k = 0
  while k < n and i < srcLen:
    let c = ord(src[i])
    inc i
    if c < 128:
      let run = c + 1
      for j in 0 ..< run:
        if k < n and i < srcLen: o[at + k] = byte(src[i])
        inc k
        inc i
    elif c > 128:
      let run = 257 - c
      let v = if i < srcLen: byte(src[i]) else: 0'u8
      inc i
      for j in 0 ..< run:
        if k < n: o[at + k] = v
        inc k
  i

proc to8(raw: seq[byte]; w, h, depth: int; alpha: bool): seq[byte] =
  ## Samples of 1, 16 or 32 bits as bytes (32: linear light, made sRGB-like
  ## unless it is an alpha).
  case depth
  of 8: result = raw
  of 16:
    result = newSeq[byte](w * h)
    for i in 0 ..< min(w * h, raw.len div 2):
      let v = (int(raw[2 * i]) shl 8) or int(raw[2 * i + 1])
      result[i] = byte((v * 255 + 32767) div 65535)
  of 32:
    result = newSeq[byte](w * h)
    for i in 0 ..< min(w * h, raw.len div 4):
      let bits = (uint32(raw[4 * i]) shl 24) or (uint32(raw[4 * i + 1]) shl 16) or
                 (uint32(raw[4 * i + 2]) shl 8) or uint32(raw[4 * i + 3])
      var f = float(cast[float32](bits))
      if f != f: f = 0
      f = clamp(f, 0.0, 1.0)
      if not alpha: f = pow(f, 1 / 2.2)
      result[i] = byte(round(f * 255))
  of 1:
    result = newSeq[byte](w * h)
    let rowB = (w + 7) div 8
    for y in 0 ..< h:
      for x in 0 ..< w:
        let b = if y * rowB + x div 8 < raw.len: int(raw[y * rowB + x div 8]) else: 0
        result[y * w + x] = if ((b shr (7 - (x and 7))) and 1) != 0: 0'u8 else: 255'u8
  else: fail("a depth of " & $depth & " bits is not read")

proc rowBytes(w, depth: int): int =
  if depth == 1: (w + 7) div 8 else: w * depth div 8

proc unpredict(raw: var seq[byte]; w, h, depth: int) =
  ## ZIP with prediction: each sample was stored less the one to its left.
  case depth
  of 8:
    for y in 0 ..< h:
      for x in 1 ..< w: raw[y * w + x] = raw[y * w + x] + raw[y * w + x - 1]
  of 16:
    for y in 0 ..< h:
      var prev = 0
      for x in 0 ..< w:
        let i = 2 * (y * w + x)
        if i + 1 >= raw.len: break
        let v = ((int(raw[i]) shl 8) or int(raw[i + 1])) + prev
        let v2 = v and 0xFFFF
        raw[i] = byte(v2 shr 8)
        raw[i + 1] = byte(v2 and 255)
        prev = v2
  of 32:
    # the bytes of each row: delta coded, the four bytes of each float in
    # planes of their own
    var row = newSeq[byte](w * 4)
    for y in 0 ..< h:
      let at = y * w * 4
      if at + w * 4 > raw.len: break
      for x in 1 ..< w * 4: raw[at + x] = raw[at + x] + raw[at + x - 1]
      for x in 0 ..< w:
        for k in 0 .. 3: row[x * 4 + k] = raw[at + k * w + x]
      copyMem(addr raw[at], addr row[0], w * 4)
  else: discard

proc channelRaw(r: var Reader; comp, w, h, depth: int; big: bool; dataEnd: int): seq[byte] =
  ## One channel's samples of a layer at the file's depth (16 bits: two
  ## bytes each, big-endian): `comp` read already.
  let rb = rowBytes(w, depth)
  if w > 300_000 or h > 300_000 or rb * h > 1_500_000_000: fail("a layer too big")
  var raw = newSeq[byte](rb * h)
  case comp
  of 0:
    let n = min(rb * h, dataEnd - r.pos)
    if n > 0: copyMem(addr raw[0], addr r.s[r.pos], n)
    r.pos += max(0, n)
  of 1:
    var counts = newSeq[int](h)
    for y in 0 ..< h: counts[y] = if big: r.u32 else: r.u16
    for y in 0 ..< h:
      let n = counts[y]
      if r.pos + n > r.len: fail("damaged layer data")
      discard unpack(cast[ptr UncheckedArray[char]](addr r.s[r.pos]), n, raw, y * rb, rb)
      r.pos += n
  of 2, 3:
    let n = dataEnd - r.pos
    if n < 0: fail("damaged layer data")
    var z = newSeq[byte](n)
    if n > 0: copyMem(addr z[0], addr r.s[r.pos], n)
    r.pos += n
    let un = try: zlibDecompress(z, rb * h + 1024)
             except CatchableError: fail("damaged ZIP data")
    for i in 0 ..< min(un.len, raw.len): raw[i] = un[i]
    if comp == 3: unpredict(raw, w, h, depth)
  else: fail("an unknown compression")
  raw

proc channelData(r: var Reader; comp, w, h, depth: int; big: bool; dataEnd: int; alpha: bool): seq[byte] =
  ## One channel's samples (as bytes) of a layer: `comp` read already.
  let raw = r.channelRaw(comp, w, h, depth, big, dataEnd)
  if depth == 8: raw else: to8(raw, w, h, depth, alpha)

# ---- colors ---------------------------------------------------------------------------------------------

proc labToRgb*(L, a, b: float): (int, int, int) =
  ## CIE Lab (D50, as Photoshop keeps it) to sRGB.
  let fy = (L + 16) / 116
  let fx = fy + a / 500
  let fz = fy - b / 200
  proc finv(t: float): float = (if t > 6 / 29: t * t * t else: 3 * (6 / 29) * (6 / 29) * (t - 4 / 29))
  let X = 0.9642 * finv(fx)
  let Y = 1.0 * finv(fy)
  let Z = 0.8251 * finv(fz)
  # (Bradford D50 -> sRGB D65 in one matrix)
  let rl = 3.1338561 * X - 1.6168667 * Y - 0.4906146 * Z
  let gl = -0.9787684 * X + 1.9161415 * Y + 0.0334540 * Z
  let bl = 0.0719453 * X - 0.2289914 * Y + 1.4052427 * Z
  proc gam(v: float): int =
    let c = clamp(v, 0.0, 1.0)
    int(round((if c <= 0.0031308: 12.92 * c else: 1.055 * pow(c, 1 / 2.4) - 0.055) * 255))
  (gam(rl), gam(gl), gam(bl))

proc rgbToLab*(r, g, b: int): (float, float, float) =
  ## sRGB to CIE Lab (D50).
  proc lin(v: int): float =
    let c = v / 255
    if c <= 0.04045: c / 12.92 else: pow((c + 0.055) / 1.055, 2.4)
  let rl = lin(r)
  let gl = lin(g)
  let bl = lin(b)
  let X = 0.4360747 * rl + 0.3850649 * gl + 0.1430804 * bl
  let Y = 0.2225045 * rl + 0.7168786 * gl + 0.0606169 * bl
  let Z = 0.0139322 * rl + 0.0971045 * gl + 0.7141733 * bl
  proc f(t: float): float = (if t > 216 / 24389: pow(t, 1 / 3) else: (24389 / 27 * t + 16) / 116)
  let fx = f(X / 0.9642)
  let fy = f(Y)
  let fz = f(Z / 0.8251)
  (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))

proc pixelsOf(mode: PsdColorMode; chans: seq[seq[byte]]; alpha: seq[byte]; n: int;
              palette: seq[uint32]): seq[uint32] =
  ## Channels of a mode to 0xAARRGGBB.
  result = newSeq[uint32](n)
  template ch(k, i: int): int = (if k < chans.len and i < chans[k].len: int(chans[k][i]) else: 0)
  for i in 0 ..< n:
    let a = if alpha.len > 0: int(alpha[i]) else: 255
    var r, g, b: int
    case mode
    of pmRGB:
      r = ch(0, i); g = ch(1, i); b = ch(2, i)
    of pmGray, pmDuotone, pmBitmap:
      r = ch(0, i); g = r; b = r
    of pmIndexed:
      let p = if ch(0, i) < palette.len: palette[ch(0, i)] else: 0xFF000000'u32
      r = int((p shr 16) and 255); g = int((p shr 8) and 255); b = int(p and 255)
    of pmCMYK:
      # (stored as 255 - ink)
      let v = printedFast(255 - ch(0, i), 255 - ch(1, i), 255 - ch(2, i), 255 - ch(3, i))
      r = int((v shr 16) and 255); g = int((v shr 8) and 255); b = int(v and 255)
    of pmLab:
      (r, g, b) = labToRgb(ch(0, i) * 100 / 255, float(ch(1, i) - 128), float(ch(2, i) - 128))
    of pmMultichannel:
      if chans.len >= 3:
        # (taken as cyan, magenta, yellow inks, stored as 255 - ink)
        r = ch(0, i); g = ch(1, i); b = ch(2, i)
      else:
        r = ch(0, i); g = r; b = r
    result[i] = (uint32(a) shl 24) or (uint32(clamp(r, 0, 255)) shl 16) or (uint32(clamp(g, 0, 255)) shl 8) or
                uint32(clamp(b, 0, 255))

# ---- the layers ---------------------------------------------------------------------------------------

const bigKeys = ["LMsk", "Lr16", "Lr32", "Layr", "Mt16", "Mt32", "Mtrn", "Alph", "FMsk", "lnk2", "FEid", "FXid",
                 "PxSD", "lnk3", "lnkE", "cinf", "pths", "extd", "extn", "FELS", "artd"]
  ## (the keys whose lengths take 8 bytes in a .psb; "8B64" says so too)

proc colorChannels(mode: PsdColorMode): int =
  case mode
  of pmRGB, pmLab: 3
  of pmCMYK: 4
  else: 1

proc readLayers(r: var Reader; doc: var PsdDoc; infoEnd: int) =
  ## The layer info: the records, then each layer's channels.
  let big = doc.big
  var count = r.i16
  if count < 0: count = -count
  if count > 10_000: fail("too many layers")
  type ChanInfo = tuple[id, len: int]
  var chans = newSeq[seq[ChanInfo]](count)
  var layers = newSeq[PsdLayer](count)
  var realMasks = newSeq[PsdMask](count)
  for li in 0 ..< count:
    var L = PsdLayer(visible: true, opacity: 255, fill: 255, blend: "norm")
    let top = r.i32
    let left = r.i32
    let bottom = r.i32
    let right = r.i32
    L.x = left
    L.y = top
    L.w = max(0, right - left)
    L.h = max(0, bottom - top)
    if L.w.int64 * L.h.int64 > 1_000_000_000: fail("a layer too big")
    let nc = r.u16
    if nc > 56: fail("too many channels")
    for _ in 0 ..< nc:
      let id = r.i16
      chans[li].add (id, r.len(big))
    if r.key4() notin ["8BIM", "8B64"]: fail("a damaged layer record")
    L.blend = r.key4()
    L.opacity = r.u8
    L.clipping = r.u8 != 0
    let flags = r.u8
    L.protectAlpha = (flags and 1) != 0
    L.visible = (flags and 2) == 0
    discard r.u8
    let extra = r.u32
    let extraEnd = r.pos + extra
    if extraEnd > r.len: fail("a damaged layer record")
    # the mask
    let maskLen = r.u32
    let maskEnd = r.pos + maskLen
    var maskFlags = 0
    if maskLen >= 18:
      let mt = r.i32
      let ml = r.i32
      let mb = r.i32
      let mr = r.i32
      L.mask.x = ml
      L.mask.y = mt
      L.mask.w = max(0, mr - ml)
      L.mask.h = max(0, mb - mt)
      L.mask.outside = r.u8
      let mf = r.u8
      L.mask.disabled = (mf and 2) != 0
      L.mask.density = 255
      maskFlags = mf
    var hasRealChan = false
    for (id, _) in chans[li]:
      if id == -3: hasRealChan = true
    if maskLen >= 36 and hasRealChan:
      # (with a vector mask too: the "real" mask, its own rectangle)
      let rf = r.u8
      let rbg = r.u8
      let mt = r.i32
      let ml = r.i32
      let mb = r.i32
      let mr = r.i32
      realMasks[li] = PsdMask(x: ml, y: mt, w: max(0, mr - ml), h: max(0, mb - mt), outside: rbg,
                              disabled: (rf and 2) != 0, density: 255)
    if (maskFlags and 0x10) != 0 and r.pos + 1 <= maskEnd:
      # the mask's Properties: density and feather (of the mask, of the vector mask)
      let pf = r.u8
      if (pf and 1) != 0 and r.pos + 1 <= maskEnd: L.mask.density = int(r.u8)
      if (pf and 2) != 0 and r.pos + 8 <= maskEnd: L.mask.feather = r.f64
      if (pf and 4) != 0 and r.pos + 1 <= maskEnd: L.vectorDensity = int(r.u8)
      if (pf and 8) != 0 and r.pos + 8 <= maskEnd: L.vectorFeather = r.f64
    r.pos = maskEnd
    # blending ranges
    let br = r.u32
    let brEnd = r.pos + int(br)
    while r.pos + 4 <= brEnd:
      L.ranges.add [int(r.u8), int(r.u8), int(r.u8), int(r.u8)]
    r.pos = brEnd
    L.name = r.pascal(4)
    # additional information
    while r.pos + 12 <= extraEnd:
      let sig = r.key4()
      if sig notin ["8BIM", "8B64"]: break
      let key = r.key4()
      let n = if big and (key in bigKeys or sig == "8B64"): r.u64 else: r.u32
      let at = r.pos
      if at + n > extraEnd: break
      try:
        case key
        of "luni":
          let nm = r.unicodeStr
          if nm.len > 0: L.name = nm
        of "lsct", "lsdk":
          let t = r.u32
          L.section = case t
                      of 1: psGroupOpen
                      of 2: psGroupClosed
                      of 3: psGroupEnd
                      else: psLayer
          if n >= 12 and r.key4() == "8BIM":
            L.blend = r.key4()                # (a group's own blend mode: "pass" through)
        of "iOpa": L.fill = r.u8
        of "TySh":
          discard r.u16                     # version
          for k in 0 .. 5: L.textTransform[k] = r.f64
          discard r.u16                     # text version
          discard r.u32                     # descriptor version
          let d = r.descriptor
          L.textDesc = d
          let t = d["Txt "]
          if t != nil and t.kind == pkText: L.text = t.s.replace("\r", "\n")
          if L.text.len == 0: L.text = " "
          try:
            discard r.u16                   # warp version
            discard r.u32                   # descriptor version
            L.textWarp = r.descriptor
          except PsdError: discard
        of "PlLd", "plLd":
          if r.key4() == "plcL":
            discard r.u32                   # version
            L.placedId = r.pascal(1)
            discard r.u32; discard r.u32    # page, pages
            discard r.u32                   # anti-alias
            discard r.u32                   # its kind (2: pixels)
            for k in 0 .. 7: L.placedTransform[k] = r.f64
        of "SoLd":
          if r.key4() == "soLD":
            discard r.u32                   # version
            discard r.u32                   # descriptor version
            L.smartDesc = r.descriptor
            let id = L.smartDesc["Idnt"]
            if id != nil and id.kind == pkText and id.s.len > 0: L.placedId = id.s
        of "lfx2":
          discard r.u32                     # object effects version
          discard r.u32                     # descriptor version
          L.effects = r.descriptor
        of "vmsk", "vsms":
          discard r.u32                     # version
          let vf = r.u32
          L.hasVectorMask = true
          L.vectorInvert = (vf and 1) != 0
          L.vectorDisabled = (vf and 4) != 0
          let stop = at + n
          var cur = -1
          while r.pos + 26 <= stop:
            let sel = r.u16
            let rec = r.pos
            case sel
            of 0, 3:
              let count = r.u16
              let op = r.i16
              discard count
              L.vectorMask.add PsdSubpath(closed: sel == 0, operation: op)
              cur = L.vectorMask.high
            of 1, 2, 4, 5:
              if cur >= 0:
                var pts: array[3, (float, float)]
                for k in 0 .. 2:
                  let vy = r.i32 / 16777216
                  let vx = r.i32 / 16777216
                  pts[k] = (vx * doc.w.float, vy * doc.h.float)
                L.vectorMask[cur].knots.add PsdKnot(pre: pts[0], anchor: pts[1], post: pts[2])
            of 8: L.vectorFillAll = r.u16 != 0
            else: discard
            r.pos = rec + 24
        of "vscg":
          L.adjustment = r.key4()
          discard r.u32
          L.adjustDesc = r.descriptor
        of "vstk":
          discard r.u32
          L.strokeDesc = r.descriptor
        of "SoCo", "GdFl", "PtFl", "brit", "levl", "curv", "expA", "vibA", "hue ", "hue2", "blnc", "blwh",
           "phfl", "mixr", "clrL", "nvrt", "post", "thrs", "grdm", "selc":
          L.adjustment = key
          L.adjustData = r.bytes(n)
          if key in ["SoCo", "GdFl", "PtFl", "vibA", "blwh", "phfl"]:
            var rr = Reader(s: cast[ptr UncheckedArray[char]](addr L.adjustData[0]), len: L.adjustData.len)
            try:
              discard rr.u32               # descriptor version
              L.adjustDesc = rr.descriptor
            except PsdError: discard
        else: discard
      except PsdError: discard
      r.pos = at + n
    r.pos = extraEnd
    layers[li] = L
  # the channels' pixels
  for li in 0 ..< count:
    var L = addr layers[li]
    let nColor = colorChannels(doc.mode)
    var colors = newSeq[seq[byte]](nColor)
    var alpha: seq[byte]
    var colors16 = newSeq[seq[byte]](nColor)
    var alpha16: seq[byte]
    var hasReal = false
    for (id, clen) in chans[li]:
      let start = r.pos
      let stop = start + clen
      if stop > r.len: fail("damaged layer data")
      if clen < 2:
        r.pos = stop
        continue
      let comp = r.u16
      var w = L.w
      var h = L.h
      if id == -2:
        w = L.mask.w
        h = L.mask.h
      elif id == -3:
        w = realMasks[li].w
        h = realMasks[li].h
      if w * h > 0:
        let raw = r.channelRaw(comp, w, h, doc.depth, big, stop)
        if doc.depth == 16 and (id == -1 or (id >= 0 and id < nColor)) and raw.len == w * h * 2:
          if id == -1: alpha16 = raw else: colors16[id] = raw
        let data = if doc.depth == 8: raw else: to8(raw, w, h, doc.depth, id < 0)
        if id >= 0 and id < nColor: colors[id] = data
        elif id == -1: alpha = data
        elif id == -2 and L.mask.w > 0:
          L.hasMask = true
          L.mask.px = data
        elif id == -3 and realMasks[li].w > 0:
          realMasks[li].px = data
          hasReal = true
      r.pos = stop
    if hasReal:
      # (the pixel mask; the vector mask is drawn from its outline)
      L.mask = realMasks[li]
      L.hasMask = true
    if L.w * L.h > 0:
      if alpha.len == 0 and L.adjustment.len == 0:
        alpha = newSeq[byte](L.w * L.h)
        for v in alpha.mitems: v = 255
      L.px = pixelsOf(doc.mode, colors, alpha, L.w * L.h, doc.palette)
      # (a 16-bit RGB or gray layer: its pixels at 16 bits too)
      let n = L.w * L.h
      if doc.depth == 16 and doc.mode in {pmRGB, pmGray} and L.adjustment.len == 0:
        var ok = true
        for c in 0 ..< nColor:
          if colors16[c].len != n * 2: ok = false
        if ok:
          L.px16 = newSeq[uint16](n * 4)
          template s16(b: seq[byte]; i: int): uint16 = (uint16(b[2 * i]) shl 8) or uint16(b[2 * i + 1])
          for i in 0 ..< n:
            for c in 0 .. 2: L.px16[4 * i + c] = s16(colors16[min(c, nColor - 1)], i)
            L.px16[4 * i + 3] = if alpha16.len == n * 2: s16(alpha16, i) else: 65535'u16
    busyTick()
  doc.layers = layers
  r.pos = infoEnd

proc readLinked(r: var Reader; stop: int): seq[PsdLinkedFile] =
  ## The files embedded for Smart Objects ('lnk2', 'lnk3', 'lnkD'): each a
  ## length, 'liFD' (the file in it), 'liFE' (a file outside) or 'liFA'.
  while r.pos + 8 <= stop:
    let size = r.u64
    let start = r.pos
    if size <= 0 or start + size > stop: break
    try:
      let kind = r.key4()
      let version = r.u32
      var f = PsdLinkedFile(id: r.pascal(1))
      f.name = r.unicodeStr
      f.fileType = r.key4()
      discard r.key4()                      # its creator
      let dataSize = r.u64
      if r.u8 != 0:
        discard r.u32
        discard r.descriptor                # (how it was opened)
      if kind == "liFE":
        discard r.u32
        discard r.descriptor                # (where it is)
        if version > 3:
          r.skip(4 + 4 + 8)                 # (when it was changed)
        discard r.u64
      if kind == "liFD" and dataSize >= 0 and r.pos + dataSize <= start + size:
        f.data = r.bytes(dataSize)
      if f.data.len > 0: result.add f
    except PsdError: discard
    var n = size
    while n mod 4 != 0: inc n
    r.pos = min(stop, start + n)

proc readPsd*(data: string): PsdDoc =
  ## A Photoshop document (.psd or .psb). Raises `PsdError`.
  if data.len < 26 or data[0 .. 3] != "8BPS": fail("not a PSD document")
  var r = Reader(s: cast[ptr UncheckedArray[char]](unsafeAddr data[0]), len: data.len)
  r.pos = 4
  let version = r.u16
  if version notin [1, 2]: fail("an unknown PSD version")
  result.big = version == 2
  let big = result.big
  r.skip(6)
  let nch = r.u16
  result.h = r.u32
  result.w = r.u32
  result.depth = r.u16
  let mode = r.u16
  result.mode = case mode
    of 0: pmBitmap
    of 1: pmGray
    of 2: pmIndexed
    of 3: pmRGB
    of 4: pmCMYK
    of 7: pmMultichannel
    of 8: pmDuotone
    of 9: pmLab
    else: fail("an unknown color mode")
  if result.w <= 0 or result.h <= 0 or result.w > 300_000 or result.h > 300_000: fail("a bad size")
  if result.depth notin [1, 8, 16, 32]: fail("a bad depth")
  result.dpi = 72
  result.globalAngle = 120
  result.globalAltitude = 30
  # the color mode's data: a palette
  let cmLen = r.u32
  let cmAt = r.pos
  if result.mode == pmIndexed and cmLen >= 768:
    for i in 0 ..< 256:
      result.palette.add 0xFF000000'u32 or (uint32(ord(data[cmAt + i])) shl 16) or
                         (uint32(ord(data[cmAt + 256 + i])) shl 8) or uint32(ord(data[cmAt + 512 + i]))
  r.pos = cmAt + cmLen
  # the image resources: the resolution
  let resLen = r.u32
  let resEnd = r.pos + resLen
  while r.pos + 12 <= resEnd:
    if r.key4() != "8BIM": break
    let id = r.u16
    discard r.pascal(2)
    let n = r.u32
    let at = r.pos
    if id == 0x03ED and n >= 16:
      let hres = r.u32
      result.dpi = hres / 65536
    elif id == 0x040D and n >= 4: result.globalAngle = r.i32
    elif id == 0x0419 and n >= 4: result.globalAltitude = r.i32
    elif id == 0x040F and n > 128 and at + n <= data.len: result.icc = data[at ..< at + n]
    r.pos = at + n + (n and 1)
  r.pos = resEnd
  # the layers and masks
  let lmLen = r.len(big)
  let lmEnd = r.pos + lmLen
  if lmEnd > data.len: fail("damaged layers")
  if lmLen > 0:
    let liLen = r.len(big)
    let liEnd = r.pos + liLen
    if liLen > 0: r.readLayers(result, liEnd)
    r.pos = liEnd
    # the global mask, then more information (16 and 32-bit layers are here)
    if r.pos + 4 <= lmEnd:
      let gm = r.u32
      r.pos = min(lmEnd, r.pos + gm)
    while r.pos + 12 <= lmEnd:
      let sig = r.key4()
      if sig notin ["8BIM", "8B64"]: break
      let key = r.key4()
      let n = if big and (key in bigKeys or sig == "8B64"): r.u64 else: r.u32
      let at = r.pos
      if key in ["Lr16", "Lr32", "Layr"] and result.layers.len == 0 and n > 0:
        r.readLayers(result, at + n)
      elif key in ["lnk2", "lnk3", "lnkD"] and at + n <= lmEnd:
        result.linked.add r.readLinked(at + n)
      r.pos = at + n
      while (r.pos - at) mod 4 != 0 and r.pos < lmEnd: inc r.pos
  r.pos = lmEnd
  # the merged picture
  if r.pos + 2 <= data.len:
    try:
      let comp = r.u16
      let w = result.w
      let h = result.h
      let n = min(nch, 56)
      var planes = newSeq[seq[byte]](n)
      var raws = newSeq[seq[byte]](n)            # (16 bits: the samples as they are)
      let rb = rowBytes(w, result.depth)
      if comp == 1:
        var counts = newSeq[int](n * h)
        for i in 0 ..< n * h: counts[i] = if big: r.u32 else: r.u16
        var k = 0
        for c in 0 ..< n:
          var raw = newSeq[byte](rb * h)
          for y in 0 ..< h:
            let m = counts[k]
            inc k
            if r.pos + m > data.len: fail("damaged merged picture")
            discard unpack(cast[ptr UncheckedArray[char]](addr r.s[r.pos]), m, raw, y * rb, rb)
            r.pos += m
          planes[c] = if result.depth == 8: raw else: to8(raw, w, h, result.depth, c >= colorChannels(result.mode))
          if result.depth == 16: raws[c] = raw
          busyTick()
      elif comp == 0:
        for c in 0 ..< n:
          var raw = newSeq[byte](rb * h)
          let m = min(rb * h, data.len - r.pos)
          if m > 0: copyMem(addr raw[0], addr r.s[r.pos], m)
          r.pos += max(0, m)
          planes[c] = if result.depth == 8: raw else: to8(raw, w, h, result.depth, c >= colorChannels(result.mode))
          if result.depth == 16: raws[c] = raw
      elif comp in [2, 3]:
        var z = newSeq[byte](data.len - r.pos)
        if z.len > 0: copyMem(addr z[0], addr r.s[r.pos], z.len)
        let un = zlibDecompress(z, rb * h * n + 1024)
        for c in 0 ..< n:
          var raw = newSeq[byte](rb * h)
          for i in 0 ..< rb * h:
            if c * rb * h + i < un.len: raw[i] = un[c * rb * h + i]
          if comp == 3: unpredict(raw, w, h, result.depth)
          planes[c] = if result.depth == 8: raw else: to8(raw, w, h, result.depth, c >= colorChannels(result.mode))
          if result.depth == 16: raws[c] = raw
      let nColor = colorChannels(result.mode)
      var alpha: seq[byte]
      # (an alpha channel after the colors: the merged picture's
      # transparency when there are layers; else not shown)
      if planes.len > nColor and result.layers.len > 0: alpha = planes[nColor]
      result.composite = pixelsOf(result.mode, planes[0 ..< min(planes.len, nColor)], alpha, w * h, result.palette)
      if result.depth == 16 and result.mode in {pmRGB, pmGray} and raws.len >= nColor:
        var ok = true
        for c in 0 ..< nColor:
          if raws[c].len != w * h * 2: ok = false
        if ok:
          let a16 = if planes.len > nColor and result.layers.len > 0 and raws[nColor].len == w * h * 2: raws[nColor] else: @[]
          result.composite16 = newSeq[uint16](w * h * 4)
          template s16(b: seq[byte]; i: int): uint16 = (uint16(b[2 * i]) shl 8) or uint16(b[2 * i + 1])
          for i in 0 ..< w * h:
            for c in 0 .. 2: result.composite16[4 * i + c] = s16(raws[min(c, nColor - 1)], i)
            result.composite16[4 * i + 3] = if a16.len > 0: s16(a16, i) else: 65535'u16
      if result.mode == pmCMYK and planes.len >= 4:
        result.cmykComposite = newSeq[uint8](w * h * 4)
        for i in 0 ..< w * h:
          for c in 0 .. 3: result.cmykComposite[i * 4 + c] = 255'u8 - planes[c][i]
    except CatchableError:
      if result.layers.len == 0: raise
      result.composite = @[]

# ---- writing ---------------------------------------------------------------------------------------------

proc be16(o: var string; v: int) =
  o.add char((v shr 8) and 255)
  o.add char(v and 255)

proc be32(o: var string; v: int) =
  o.add char((v shr 24) and 255); o.add char((v shr 16) and 255)
  o.add char((v shr 8) and 255); o.add char(v and 255)

proc setBe32(o: var string; at, v: int) =
  o[at] = char((v shr 24) and 255); o[at + 1] = char((v shr 16) and 255)
  o[at + 2] = char((v shr 8) and 255); o[at + 3] = char(v and 255)

proc packRow(src: openArray[byte]; o: var string) =
  ## PackBits of one row.
  var i = 0
  let n = src.len
  while i < n:
    # a run of one byte?
    var run = 1
    while i + run < n and run < 128 and src[i + run] == src[i]: inc run
    if run >= 3:
      o.add char(257 - run)
      o.add char(src[i])
      i += run
    else:
      var lit = 0
      var j = i
      while j < n and lit < 128:
        if j + 2 < n and src[j] == src[j + 1] and src[j] == src[j + 2]: break
        inc j
        inc lit
      o.add char(lit - 1)
      for k in i ..< i + lit: o.add char(src[k])
      i += lit

proc rleChannel(plane: openArray[byte]; w, h: int; o: var string; big = false) =
  ## A layer's channel: RLE, its row counts first (4 bytes each in a .psb).
  o.be16(1)
  let countsAt = o.len
  for _ in 0 ..< h:
    if big: o.be32(0) else: o.be16(0)
  for y in 0 ..< h:
    let before = o.len
    if w > 0: packRow(plane.toOpenArray(y * w, y * w + w - 1), o)
    let n = o.len - before
    if big: o.setBe32(countsAt + 4 * y, n)
    else:
      o[countsAt + 2 * y] = char((n shr 8) and 255)
      o[countsAt + 2 * y + 1] = char(n and 255)

proc rawChannel16(vals: openArray[uint16]; o: var string) =
  ## A 16-bit channel, raw (its compression 0, then the samples).
  o.be16(0)
  for v in vals:
    o.add char((v shr 8) and 255)
    o.add char(v and 255)

proc plane16(px: openArray[uint32]; px16: openArray[uint16]; c, n: int): seq[uint16] =
  ## Channel `c` (0..2 color, 3 alpha) at 16 bits: from the 16-bit pixels
  ## when there are, else the 8-bit ones made 16 (times 257: exact).
  result = newSeq[uint16](n)
  if px16.len == n * 4:
    for i in 0 ..< n: result[i] = px16[4 * i + c]
  elif px.len == n:
    let sh = if c == 3: 24 else: 16 - 8 * c
    for i in 0 ..< n: result[i] = uint16((px[i] shr sh) and 255) * 257

proc utf16be(s: string): string =
  for r in s.runes:
    var c = int(r)
    if c >= 0x10000:
      c -= 0x10000
      result.be16(0xD800 + (c shr 10))
      result.be16(0xDC00 + (c and 0x3FF))
    else: result.be16(c)

proc planesOf(mode: PsdColorMode; px: openArray[uint32]; cmyk: openArray[uint8]): seq[seq[byte]] =
  ## The color channels of pixels, as a file of `mode` keeps them.
  let n = px.len
  case mode
  of pmGray:
    result = @[newSeq[byte](n)]
    for i, p in px:
      result[0][i] = byte((int((p shr 16) and 255) * 299 + int((p shr 8) and 255) * 587 + int(p and 255) * 114 + 500) div 1000)
  of pmCMYK:
    result = @[newSeq[byte](n), newSeq[byte](n), newSeq[byte](n), newSeq[byte](n)]
    for i, p in px:
      if cmyk.len == n * 4:
        for c in 0 .. 3: result[c][i] = 255'u8 - cmyk[i * 4 + c]
      else:
        # (separated as the printing setup says)
        let v = inkOf(p)
        for c in 0 .. 3: result[c][i] = 255'u8 - v[c]
  else:
    result = @[newSeq[byte](n), newSeq[byte](n), newSeq[byte](n)]
    for i, p in px:
      result[0][i] = byte((p shr 16) and 255)
      result[1][i] = byte((p shr 8) and 255)
      result[2][i] = byte(p and 255)

proc beF64(o: var string; v: float) =
  let u = cast[uint64](v)
  for k in countdown(7, 0): o.add char((u shr (k * 8)) and 255)

proc wId(o: var string; id: string) =
  if id.len == 4:
    o.be32(0)
    o.add id
  else:
    o.be32(id.len)
    o.add id

proc wUni(o: var string; s: string) =
  let u = utf16be(s)
  o.be32(u.len div 2 + 1)
  o.add u
  o.add "\0\0"

proc writeBody(o: var string; v: PsdValue)

proc writeValue(o: var string; v: PsdValue) =
  case v.kind
  of pkLong:
    o.add "long"
    o.be32(v.i)                  # (be32 writes the low 32 bits)
  of pkDouble:
    o.add "doub"
    o.beF64(v.f)
  of pkUnit:
    o.add "UntF"
    o.add (v.unit & "    ")[0 .. 3]
    o.beF64(v.uf)
  of pkBool:
    o.add "bool"
    o.add char(ord(v.b))
  of pkText:
    o.add "TEXT"
    o.wUni(v.s)
  of pkEnum:
    o.add "enum"
    o.wId(v.etype)
    o.wId(v.evalue)
  of pkObject:
    o.add "Objc"
    o.writeBody(v)
  of pkList:
    if v.floatUnit.len > 0:
      o.add "UnFl"
      o.add (v.floatUnit & "    ")[0 .. 3]
      o.be32(v.list.len)
      for x in v.list: o.beF64(x.num)
    else:
      o.add "VlLs"
      o.be32(v.list.len)
      for x in v.list: o.writeValue(x)
  of pkClass:
    o.add "type"
    o.wUni("")
    o.wId(v.className)
  of pkRaw:
    o.add "tdta"
    o.be32(v.raw.len)
    o.add v.raw
  of pkNone:
    o.add "long"
    o.be32(0)

proc writeBody(o: var string; v: PsdValue) =
  o.wUni("")
  o.wId(v.cls)
  o.be32(v.items.len)
  for (k, x) in v.items:
    o.wId(k)
    o.writeValue(x)

proc readDescriptor*(data: string; at = 0): PsdValue =
  ## The action descriptor at `at` in `data` (just after its version, 16):
  ## what Photoshop's gradients (.grd), styles (.asl) and presets keep.
  ## Raises `PsdError` when it is damaged.
  if at < 0 or at >= data.len: fail("no descriptor there")
  var r = Reader(s: cast[ptr UncheckedArray[char]](unsafeAddr data[0]), len: data.len, pos: at)
  r.descriptor

proc descriptorData*(v: PsdValue): string =
  ## An action descriptor as Photoshop writes it (with its version, 16).
  result.be32(16)
  result.writeBody(v)

proc psdObj*(cls: string; items: varargs[(string, PsdValue)]): PsdValue =
  ## A descriptor of class `cls` with `items`.
  PsdValue(kind: pkObject, cls: cls, items: @items)
proc psdNum*(f: float): PsdValue = PsdValue(kind: pkDouble, f: f)
  ## A number (a double).
proc psdLong*(i: int): PsdValue = PsdValue(kind: pkLong, i: i)
  ## A whole number (a long).
proc psdUnit*(unit: string; f: float): PsdValue = PsdValue(kind: pkUnit, unit: unit, uf: f)
  ## A number in a unit ("#Pxl", "#Prc", "#Ang"...).
proc psdBool*(b: bool): PsdValue = PsdValue(kind: pkBool, b: b)
  ## A boolean.
proc psdText*(s: string): PsdValue = PsdValue(kind: pkText, s: s)
  ## A text.
proc psdEnum*(t, v: string): PsdValue = PsdValue(kind: pkEnum, etype: t, evalue: v)
  ## An enumerated value `v` of type `t`.
proc psdList*(items: varargs[PsdValue]): PsdValue = PsdValue(kind: pkList, list: @items)
  ## A list of `items`.
proc psdRgb*(c: uint32): PsdValue =
  ## A color (0xRRGGBB) as Photoshop keeps it.
  psdObj("RGBC", ("Rd  ", psdNum(float((c shr 16) and 255))), ("Grn ", psdNum(float((c shr 8) and 255))),
         ("Bl  ", psdNum(float(c and 255))))

proc typeToolData*(transform: array[6, float]; text, warp: PsdValue): string =
  ## A type layer's 'TySh' (type tool object setting): its transform, its
  ## text descriptor ('TxLr', holding "Txt " and EngineData), its warp
  ## descriptor ('warp').
  result.be16(1)
  for v in transform: result.beF64(v)
  result.be16(50)
  result.add descriptorData(text)
  result.be16(1)
  result.add descriptorData(warp)
  for _ in 0 .. 3: result.be32(0)             # (left, top, right, bottom: not used)

proc placedLayerData*(id: string; corners: array[8, float]; warp: PsdValue): string =
  ## A placed layer's 'PlLd': the id of the file it shows, where its
  ## corners are (x, y of top left, top right, bottom right, bottom left),
  ## its warp descriptor.
  result.add "plcL"
  result.be32(3)
  let s = if id.len > 255: id[0 ..< 255] else: id
  result.add char(s.len)
  result.add s
  result.be32(1)                              # page
  result.be32(1)                              # pages
  result.be32(16)                             # anti-alias
  result.be32(2)                              # pixels
  for v in corners: result.beF64(v)
  result.be32(0)                              # warp version
  result.add descriptorData(warp)

proc smartObjectData*(desc: PsdValue): string =
  ## A Smart Object's 'SoLd': its descriptor (Idnt, Trnf, "Sz  "...).
  result.add "soLD"
  result.be32(4)
  result.add descriptorData(desc)

proc vectorMaskData*(subs: seq[PsdSubpath]; w, h: int; invert = false; fillAll = false): string =
  ## A vector mask ('vmsk') of the subpaths (in canvas pixels).
  result.be32(3)
  result.be32(ord(invert))
  # the path fill rule record, the initial fill rule
  result.be16(6)
  result.add repeat('\0', 24)
  result.be16(8)
  result.be16(ord(fillAll))
  result.add repeat('\0', 22)
  proc fix(v: float; size: int): int =
    # (be32 writes the low 32 bits: they are kept, in an int of any size)
    let f = clamp(round(v / max(1, size).float * 16777216.0), -2147483648.0 * 2, 2147483647.0 * 2)
    int(cast[int32](uint32(int64(f) and 0xFFFFFFFF'i64)))
  for sp in subs:
    result.be16(if sp.closed: 0 else: 3)
    result.be16(sp.knots.len)
    result.be16(sp.operation and 0xFFFF)
    result.be16(1)
    result.be32(0)
    result.be32(0)
    result.add repeat('\0', 10)
    for k in sp.knots:
      result.be16(if sp.closed: 1 else: 4)
      for pt in [k.pre, k.anchor, k.post]:
        result.be32(fix(pt[1], h))
        result.be32(fix(pt[0], w))

proc layerInfo(doc: PsdDoc; mode: PsdColorMode; big, deep, transparent: bool): string =
  ## The layer info (without its length): how many layers, their records,
  ## then their channels -- padded to an even length.
  var o = ""
  let nColor = colorChannels(mode)
  proc writeLen(o: var string; v: int) =
    if big:
      o.be32(0)
      o.be32(v)
    else: o.be32(v)
  o.be16(if transparent: -doc.layers.len and 0xFFFF else: doc.layers.len)
  # (the records, then the channels: the channels' lengths are filled in after)
  var lenAts: seq[seq[int]]
  for L in doc.layers:
    o.be32(L.y); o.be32(L.x); o.be32(L.y + L.h); o.be32(L.x + L.w)
    let hasPx = L.px.len == L.w * L.h and L.w * L.h > 0
    var ids: seq[int]
    if L.adjustment.len == 0 or hasPx:
      ids.add -1
      for c in 0 ..< nColor: ids.add c
    if L.hasMask and L.mask.w * L.mask.h > 0: ids.add -2
    o.be16(ids.len)
    var ats: seq[int]
    for id in ids:
      o.be16(id and 0xFFFF)
      ats.add o.len
      o.writeLen(0)
    lenAts.add ats
    o.add "8BIM"
    o.add (if L.blend.len == 4: L.blend else: "norm")
    o.add char(clamp(L.opacity, 0, 255))
    o.add char(ord(L.clipping))
    o.add char((if L.visible: 0 else: 2) or ord(L.protectAlpha))
    o.add '\0'
    let extraAt = o.len
    o.be32(0)
    let extraStart = o.len
    if L.hasMask and L.mask.w * L.mask.h > 0:
      o.be32(20)
      o.be32(L.mask.y); o.be32(L.mask.x); o.be32(L.mask.y + L.mask.h); o.be32(L.mask.x + L.mask.w)
      o.add char(L.mask.outside)
      o.add char(if L.mask.disabled: 2 else: 0)
      o.add "\0\0"
    else: o.be32(0)
    o.be32(L.ranges.len * 4)                 # blending ranges
    for rg in L.ranges:
      for v in rg: o.add char(clamp(v, 0, 255))
    var nm = ""
    for c in L.name:
      if nm.len >= 255: break
      nm.add(if ord(c) < 128: c else: '?')
    o.add char(nm.len)
    o.add nm
    var total = nm.len + 1
    while total mod 4 != 0:
      o.add '\0'
      inc total
    # its name in Unicode, its fill, its section, its adjustment
    var u = ""
    let name16 = utf16be(L.name)
    u.be32(name16.len div 2)
    u.add name16
    while u.len mod 4 != 0: u.add '\0'
    o.add "8BIMluni"
    o.be32(u.len)
    o.add u
    if L.fill != 255:
      o.add "8BIMiOpa"
      o.be32(4)
      o.add char(clamp(L.fill, 0, 255))
      o.add "\0\0\0"
    if L.section != psLayer:
      o.add "8BIMlsct"
      o.be32(12)
      o.be32(case L.section
             of psGroupOpen: 1
             of psGroupClosed: 2
             of psGroupEnd: 3
             else: 0)
      o.add "8BIM"
      o.add (if L.blend.len == 4: L.blend else: "pass")
    if L.adjustment.len == 4 and (L.adjustData.len > 0 or L.adjustment == "nvrt"):
      o.add "8BIM"
      o.add L.adjustment
      var dat = L.adjustData
      while dat.len mod 4 != 0: dat.add '\0'
      o.be32(dat.len)
      o.add dat
    for (key, data) in L.extra:
      if key.len != 4: continue
      o.add "8BIM"
      o.add key
      var dat = data
      while dat.len mod 4 != 0: dat.add '\0'
      if big and key in bigKeys: o.writeLen(dat.len) else: o.be32(dat.len)
      o.add dat
    o.setBe32(extraAt, o.len - extraStart)
  for li, L in doc.layers:
    let hasPx = L.px.len == L.w * L.h and L.w * L.h > 0
    var k = 0
    template channel(body: untyped) =
      let st = o.len
      body
      let n = o.len - st
      let at = lenAts[li][k]
      if big:
        o.setBe32(at, 0)
        o.setBe32(at + 4, n)
      else: o.setBe32(at, n)
      inc k
    if deep and (L.adjustment.len == 0 or hasPx):
      let n = L.w * L.h
      let px = if hasPx: L.px else: newSeq[uint32](n)
      channel: rawChannel16(plane16(px, L.px16, 3, n), o)
      for c in 0 ..< nColor:
        if mode == pmGray:
          # (gray: the luma of the colors, at 16 bits)
          let r = plane16(px, L.px16, 0, n)
          let g = plane16(px, L.px16, 1, n)
          let b = plane16(px, L.px16, 2, n)
          var y = newSeq[uint16](n)
          for i in 0 ..< n: y[i] = uint16((299 * r[i].int + 587 * g[i].int + 114 * b[i].int) div 1000)
          channel: rawChannel16(y, o)
        else:
          channel: rawChannel16(plane16(px, L.px16, c, n), o)
    elif L.adjustment.len == 0 or hasPx:
      var a = newSeq[byte](L.w * L.h)
      if hasPx:
        for i, p in L.px: a[i] = byte(p shr 24)
      channel: rleChannel(a, L.w, L.h, o, big)
      let planes = planesOf(mode, (if hasPx: L.px else: newSeq[uint32](L.w * L.h)), [])
      for c in 0 ..< nColor:
        channel: rleChannel(planes[c], L.w, L.h, o, big)
    if L.hasMask and L.mask.w * L.mask.h > 0:
      if deep:
        var m = newSeq[uint16](L.mask.px.len)
        for i, v in L.mask.px: m[i] = uint16(v) * 257
        channel: rawChannel16(m, o)
      else:
        channel: rleChannel(L.mask.px, L.mask.w, L.mask.h, o, big)
    busyTick()
  if o.len mod 2 == 1: o.add '\0'
  o

proc linkedData*(files: openArray[PsdLinkedFile]): string =
  ## The files embedded for Smart Objects as 'lnk2' keeps them (each
  ## 'liFD', version 2: its id, name, type and bytes; padded to 4).
  for f in files:
    let sizeAt = result.len
    result.be32(0)
    result.be32(0)
    let start = result.len
    result.add "liFD"
    result.be32(2)
    let id = if f.id.len > 255: f.id[0 ..< 255] else: f.id
    result.add char(id.len)
    result.add id
    result.wUni(f.name)
    result.add (f.fileType & "    ")[0 .. 3]
    result.add "\0\0\0\0"                    # (its creator)
    result.be32(0)
    result.be32(f.data.len)
    result.add '\0'                          # (no descriptor of how it was opened)
    result.add f.data
    result.setBe32(sizeAt + 4, result.len - start)
    while (result.len - start) mod 4 != 0: result.add '\0'

proc writePsd*(doc: PsdDoc): string =
  ## `doc` as a Photoshop document (8 bits; RGB, grayscale or CMYK as its
  ## `mode` says; .psb when it is bigger than 30000 pixels across or down
  ## or `big`). Its layers' pixels are RLE-coded; the merged picture is
  ## `composite` (made by the caller).
  let big = doc.big or doc.w > 30000 or doc.h > 30000
  let mode = if doc.mode in {pmGray, pmCMYK}: doc.mode else: pmRGB
  let nColor = colorChannels(mode)
  var transparent = false
  for p in doc.composite:
    if (p shr 24) != 255:
      transparent = true
      break
  var o = "8BPS"
  o.be16(if big: 2 else: 1)
  o.add "\0\0\0\0\0\0"
  o.be16(nColor + ord(transparent))
  o.be32(doc.h)
  o.be32(doc.w)
  let deep = doc.depth == 16 and mode in {pmRGB, pmGray}      # (16 bits a channel)
  o.be16(if deep: 16 else: 8)
  o.be16(ord(mode))
  o.be32(0)                                  # color mode data
  # the image resources: the resolution
  var res = ""
  res.add "8BIM"
  res.be16(0x03ED)
  res.add "\0\0"
  res.be32(16)
  let dpiFix = int(round(max(1.0, doc.dpi) * 65536))
  res.be32(dpiFix); res.be16(1); res.be16(1)
  res.be32(dpiFix); res.be16(1); res.be16(1)
  if doc.icc.len > 0:
    # (its color profile)
    res.add "8BIM"
    res.be16(0x040F)
    res.add "\0\0"
    res.be32(doc.icc.len)
    res.add doc.icc
    if (doc.icc.len and 1) == 1: res.add '\0'
  o.be32(res.len)
  o.add res
  proc writeLen(o: var string; v: int) =
    if big:
      o.be32(0)
      o.be32(v)
    else: o.be32(v)
  # the layers
  let lmAt = o.len
  o.writeLen(0)
  let li = layerInfo(doc, mode, big, deep, transparent)
  o.writeLen(li.len)
  o.add li
  o.be32(0)                                  # the global mask
  if doc.linked.len > 0:
    # the files its Smart Objects show
    let ld = linkedData(doc.linked)
    o.add "8BIMlnk2"
    o.writeLen(ld.len)
    o.add ld
  let lmLen = o.len - (lmAt + (if big: 8 else: 4))
  if big:
    o.setBe32(lmAt, 0)
    o.setBe32(lmAt + 4, lmLen)
  else: o.setBe32(lmAt, lmLen)
  # the merged picture, RLE-coded: all the row counts, then the rows
  let w = doc.w
  let h = doc.h
  var comp = doc.composite
  if comp.len != w * h: comp = newSeq[uint32](w * h)
  var alphaPlane: seq[byte]
  if transparent:
    # (as Photoshop keeps it: the colors matted on white, the alpha beside)
    alphaPlane = newSeq[byte](w * h)
    for i, p in comp.mpairs:
      let a = int(p shr 24)
      alphaPlane[i] = byte(a)
      if a < 255:
        template m(sh: int): uint32 = uint32((int((p shr sh) and 255) * a + 255 * (255 - a) + 127) div 255) shl sh
        p = (p and 0xFF000000'u32) or m(16) or m(8) or m(0)
  if deep:
    # (16 bits: raw, each channel in turn; matted on white as the 8-bit one)
    o.be16(0)
    let n = w * h
    for c in 0 ..< nColor + ord(transparent):
      var v = if c == nColor: plane16(doc.composite, doc.composite16, 3, n)
              elif mode == pmGray:
                block:
                  let r = plane16(comp, doc.composite16, 0, n)
                  let g = plane16(comp, doc.composite16, 1, n)
                  let b = plane16(comp, doc.composite16, 2, n)
                  var y = newSeq[uint16](n)
                  for i in 0 ..< n: y[i] = uint16((299 * r[i].int + 587 * g[i].int + 114 * b[i].int) div 1000)
                  y
              else: plane16(comp, doc.composite16, c, n)
      if c < nColor and transparent and doc.composite16.len == n * 4:
        for i in 0 ..< n:
          let a = doc.composite16[4 * i + 3].int
          v[i] = uint16((uint64(v[i]) * uint64(a) + 65535'u64 * uint64(65535 - a)) div 65535)
      for x in v:
        o.add char((x shr 8) and 255)
        o.add char(x and 255)
      busyTick()
    return o
  var planes = planesOf(mode, comp, doc.cmykComposite)
  if transparent: planes.add alphaPlane
  o.be16(1)
  let countsAt = o.len
  for _ in 0 ..< planes.len * h:
    if big: o.be32(0) else: o.be16(0)
  var k = 0
  for plane in planes:
    for y in 0 ..< h:
      let before = o.len
      packRow(plane.toOpenArray(y * w, y * w + w - 1), o)
      let n = o.len - before
      if big: o.setBe32(countsAt + 4 * k, n)
      else:
        o[countsAt + 2 * k] = char((n shr 8) and 255)
        o[countsAt + 2 * k + 1] = char(n and 255)
      inc k
    busyTick()
  o

# ---- layers in a TIFF ---------------------------------------------------------------------------------

const tiffBlockHead* = "Adobe Photoshop Document Data Block\0"
  ## How the layers a TIFF keeps (its tag 37724, ImageSourceData) start.

proc tiffLayerBlock*(doc: PsdDoc): string =
  ## `doc`'s layers as a TIFF keeps them in its tag 37724 (ImageSourceData):
  ## "Adobe Photoshop Document Data Block", then 'Layr' (the layer info, 8
  ## bits, as in a .psd) and, when it has Smart Objects, 'lnk2' (their
  ## files). Big-endian ("8BIM"): for a TIFF in Motorola order ("MM").
  let mode = if doc.mode in {pmGray, pmCMYK}: doc.mode else: pmRGB
  var transparent = false
  for p in doc.composite:
    if (p shr 24) != 255:
      transparent = true
      break
  result = tiffBlockHead
  var li = layerInfo(doc, mode, false, false, transparent)
  while li.len mod 4 != 0: li.add '\0'
  result.add "8BIMLayr"
  result.be32(li.len)
  result.add li
  if doc.linked.len > 0:
    let ld = linkedData(doc.linked)
    result.add "8BIMlnk2"
    result.be32(ld.len)
    result.add ld

proc readTiffLayers*(data: string; w, h: int; mode = pmRGB; littleEndian = false): PsdDoc =
  ## The layers of a TIFF (its tag 37724's bytes, `data`) as a document
  ## `w` x `h` in `mode` (the TIFF's) -- no merged picture: the TIFF's own
  ## picture is that. A TIFF in Intel order (`littleEndian`) keeps them
  ## little-endian, its keys the other way round ("MIB8", "ryaL").
  ## Raises `PsdError` when there are none or they are damaged.
  if not data.startsWith(tiffBlockHead): fail("no PSD layers in the TIFF")
  result = PsdDoc(w: w, h: h, depth: 8, mode: mode, dpi: 72, globalAngle: 120, globalAltitude: 30)
  var r = Reader(s: cast[ptr UncheckedArray[char]](unsafeAddr data[0]), len: data.len, pos: tiffBlockHead.len,
                 le: littleEndian)
  var found = false
  while r.pos + 12 <= data.len:
    let sig = r.key4()
    if sig notin ["8BIM", "8B64"]: break
    let key = r.key4()
    let n = r.u32
    let at = r.pos
    if n < 0 or at + n > data.len: break
    case key
    of "Layr", "Lr16", "Lr32":
      if not found and n > 0:
        result.depth = if key == "Lr16": 16 elif key == "Lr32": 32 else: 8
        r.readLayers(result, at + n)
        found = true
    of "lnk2", "lnk3", "lnkD": result.linked.add r.readLinked(at + n)
    else: discard
    r.pos = at + n
    # (padding, if any, before the next block's signature)
    var k = 0
    while k < 4 and r.pos + 4 <= data.len and data[r.pos ..< r.pos + 4] notin ["8BIM", "MIB8", "8B64", "46B8"]:
      inc r.pos
      inc k
  if not found: fail("no PSD layers in the TIFF")

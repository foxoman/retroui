## Color profiles (ICC): read from the pictures that carry one (JPEG, PNG,
## TIFF, Photoshop), the common ones built in (sRGB, Adobe RGB (1998),
## Display P3, ProPhoto RGB, Gray Gamma 2.2), pixels converted between
## them, and profiles written into the files saved.
##
## Profiles of the matrix-and-curves kind (RGB and gray: nearly all of
## those in photos) are converted here (`convertPixels`). The others --
## printers' CMYK profiles, profiles with color tables -- are read here too
## (their tables: lut8, lut16, lutAtoB, lutBtoA) and converted with
## `retroui/icclut`. Use it to show a photo's colors as they were meant (its
## profile to the screen's sRGB) and to keep a profile in a saved file.
##
## ```nim
## let p = parseIcc(iccFromJpeg(data))
## if p.usable and not p.isSrgbLike: convertPixels(px, p, srgbProfile())
## echo parseIcc(readFile("press.icc")).a2b[1].kind      # "mft2"
## ```

import std/[math, strutils]
import codec

type
  IccCurve* = object
    ## A tone curve: a gamma, a table, or a parametric curve.
    kind*: int                  ## 0 gamma, 1 table, 2 parametric
    gamma*: float               ## (gamma) the exponent
    table*: seq[float]          ## 0..1
    params*: seq[float]         ## g, a, b, c, d, e, f (ICC parametric curve types 0..4)
    fn*: int                    ## (parametric) the ICC function type, 0..4

  IccStageKind* = enum
    ## What an `IccStage` is.
    iccCurves                   ## a curve for each channel
    iccMatrix                   ## a matrix, and an offset for each row
    iccGrid                     ## a grid of colors, read between (the CLUT)

  IccStage* = object
    ## A step of a color table.
    kind*: IccStageKind         ## what the step is (the fields marked so are its)
    curves*: seq[IccCurve]      ## (curves) one for each channel
    matrix*: seq[float]         ## (matrix) rows x cols, row by row, then one offset per row
    rows*, cols*: int           ## (matrix) its size: channels out, in
    grid*: seq[int]             ## (grid) points along each input, the first input slowest
    outputs*: int               ## (grid) values at each point
    table*: seq[float32]        ## (grid) the values, 0..1

  IccLut* = object
    ## A color table of a profile (A2B0 .. B2A2) as the steps it takes, in
    ## order. Its values are 0..1: Lab and XYZ as the ICC encodes them in
    ## the table's kind (lut16 keeps Lab the version 2 way).
    kind*: string               ## "mft1" (lut8), "mft2" (lut16), "mAB ", "mBA "; "" when there is none
    inputs*, outputs*: int      ## channels in, out
    stages*: seq[IccStage]      ## the steps, in the order they are taken

  IccProfile* = object
    ## A color profile.
    name*: string               ## its description ("Display P3")
    data*: string               ## the profile's bytes (as read, or made)
    colorSpace*: string         ## "RGB ", "GRAY", "CMYK", "Lab "...
    usable*: bool               ## of the matrix-and-curves kind: pixels can be converted
    toXyz*: array[9, float]     ## RGB (linear) to XYZ (D50), row by row
    trc*: array[3, IccCurve]    ## the curves (gray: the first)
    pcs*: string                ## the space it connects through: "XYZ " or "Lab "
    deviceClass*: string        ## "mntr" screen, "prtr" printer, "scnr" input, "spac", "abst", "link"
    description*: string        ## its description as written in it (desc, mluc; "" when none)
    version*: int               ## its version as the header has it (0x02100000: 2.1, 0x04300000: 4.3)
    mediaWhite*: array[3, float] ## its white (wtpt, XYZ): a printer's paper; D50 when it has none
    mediaBlack*: array[3, float] ## its black (bkpt, XYZ) when it has one
    a2b*: array[3, IccLut]      ## its tables to the PCS: A2B0 perceptual, A2B1 colorimetric, A2B2 saturation
    b2a*: array[3, IccLut]      ## and from it: B2A0, B2A1, B2A2

# ---- curves -----------------------------------------------------------------------------------------------

proc eval*(c: IccCurve; x: float): float =
  ## The linear light for the value `x` (0..1).
  let x = clamp(x, 0.0, 1.0)
  case c.kind
  of 0: pow(x, c.gamma)
  of 1:
    let n = c.table.len
    if n == 0: return x
    if n == 1: return c.table[0]
    let f = x * float(n - 1)
    let i = min(n - 2, int(f))
    c.table[i] + (c.table[i + 1] - c.table[i]) * (f - i.float)
  else:
    let p = c.params
    template P(i: int): float = (if i < p.len: p[i] else: 0.0)
    let g = P(0)
    case c.fn
    of 0: pow(x, g)
    of 1:
      if x >= -P(2) / max(1e-12, P(1)): pow(P(1) * x + P(2), g) else: 0.0
    of 2:
      if x >= -P(2) / max(1e-12, P(1)): pow(P(1) * x + P(2), g) + P(3) else: P(3)
    of 3:
      if x >= P(4): pow(P(1) * x + P(2), g) else: P(3) * x
    else:
      if x >= P(4): pow(P(1) * x + P(2), g) + P(5) else: P(3) * x + P(6)

proc gammaCurve*(g: float): IccCurve = IccCurve(kind: 0, gamma: g)
  ## A plain gamma curve.

proc srgbCurve*(): IccCurve =
  ## sRGB's curve (its exact parametric form).
  IccCurve(kind: 2, fn: 3, params: @[2.4, 1 / 1.055, 0.055 / 1.055, 1 / 12.92, 0.04045])

proc prophotoCurve*(): IccCurve =
  ## ProPhoto RGB's curve (gamma 1.8, straight near black).
  IccCurve(kind: 2, fn: 3, params: @[1.8, 1.0, 0.0, 1 / 16.0, 1 / 32.0])

# ---- matrices ------------------------------------------------------------------------------------------------

proc mul(a, b: array[9, float]): array[9, float] =
  for r in 0 .. 2:
    for c in 0 .. 2:
      result[r * 3 + c] = a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c]

proc inv(m: array[9, float]): array[9, float] =
  let (a, b, c, d, e, f, g, h, i) = (m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8])
  let A = e * i - f * h
  let B = -(d * i - f * g)
  let C = d * h - e * g
  let det = a * A + b * B + c * C
  if abs(det) < 1e-15: return [1.0, 0, 0, 0, 1, 0, 0, 0, 1]
  let k = 1 / det
  [A * k, -(b * i - c * h) * k, (b * f - c * e) * k,
   B * k, (a * i - c * g) * k, -(a * f - c * d) * k,
   C * k, -(a * h - b * g) * k, (a * e - b * d) * k]

proc primariesToXyz(xr, yr, xg, yg, xb, yb, xw, yw: float): array[9, float] =
  ## RGB to XYZ for primaries and white (chromaticities), adapted to D50
  ## (Bradford), as ICC profiles keep it.
  proc xyz(x, y: float): array[3, float] = [x / y, 1.0, (1 - x - y) / y]
  let r = xyz(xr, yr)
  let g = xyz(xg, yg)
  let b = xyz(xb, yb)
  let w = xyz(xw, yw)
  let m = [r[0], g[0], b[0], r[1], g[1], b[1], r[2], g[2], b[2]]
  let mi = inv(m)
  let s = [mi[0] * w[0] + mi[1] * w[1] + mi[2] * w[2], mi[3] * w[0] + mi[4] * w[1] + mi[5] * w[2],
           mi[6] * w[0] + mi[7] * w[1] + mi[8] * w[2]]
  var toXyz = [m[0] * s[0], m[1] * s[1], m[2] * s[2], m[3] * s[0], m[4] * s[1], m[5] * s[2],
               m[6] * s[0], m[7] * s[1], m[8] * s[2]]
  # (Bradford from this white to D50)
  const brad = [0.8951, 0.2664, -0.1614, -0.7502, 1.7135, 0.0367, 0.0389, -0.0685, 1.0296]
  let d50 = [0.9642, 1.0, 0.8249]
  let cw = [brad[0] * w[0] + brad[1] * w[1] + brad[2] * w[2], brad[3] * w[0] + brad[4] * w[1] + brad[5] * w[2],
            brad[6] * w[0] + brad[7] * w[1] + brad[8] * w[2]]
  let cd = [brad[0] * d50[0] + brad[1] * d50[1] + brad[2] * d50[2],
            brad[3] * d50[0] + brad[4] * d50[1] + brad[5] * d50[2],
            brad[6] * d50[0] + brad[7] * d50[1] + brad[8] * d50[2]]
  let scale = [cd[0] / cw[0], 0.0, 0.0, 0.0, cd[1] / cw[1], 0.0, 0.0, 0.0, cd[2] / cw[2]]
  let adapt = mul(inv(brad), mul(scale, brad))
  mul(adapt, toXyz)

# ---- the profiles built in -----------------------------------------------------------------------------------

proc iccBytes*(p: IccProfile): string
  ## A version 2 profile of `p` (matrix and curves, or gray).

proc builtIn(name: string; m: array[9, float]; c: IccCurve; gray = false): IccProfile =
  result = IccProfile(name: name, colorSpace: if gray: "GRAY" else: "RGB ", usable: true, toXyz: m,
                      pcs: "XYZ ", deviceClass: "mntr", description: name, version: 0x02100000,
                      mediaWhite: [0.9642, 1.0, 0.8249])
  for k in 0 .. 2: result.trc[k] = c
  result.data = iccBytes(result)

proc srgbProfile*(): IccProfile =
  ## sRGB IEC61966-2.1: the working space (what the screen shows).
  builtIn("sRGB IEC61966-2.1", primariesToXyz(0.64, 0.33, 0.30, 0.60, 0.15, 0.06, 0.3127, 0.3290), srgbCurve())

proc adobeRgbProfile*(): IccProfile =
  ## Adobe RGB (1998): a wider gamut than sRGB (gamma about 2.2).
  builtIn("Adobe RGB (1998)", primariesToXyz(0.64, 0.33, 0.21, 0.71, 0.15, 0.06, 0.3127, 0.3290),
          gammaCurve(563 / 256))

proc displayP3Profile*(): IccProfile =
  ## Display P3: the gamut of wide-color screens, with sRGB's curve.
  builtIn("Display P3", primariesToXyz(0.680, 0.320, 0.265, 0.690, 0.150, 0.060, 0.3127, 0.3290), srgbCurve())

proc prophotoProfile*(): IccProfile =
  ## ProPhoto RGB: a very wide gamut (D50 white, gamma 1.8).
  builtIn("ProPhoto RGB", primariesToXyz(0.7347, 0.2653, 0.1596, 0.8404, 0.0366, 0.0001, 0.3457, 0.3585),
          prophotoCurve())

proc grayProfile*(): IccProfile =
  ## Gray Gamma 2.2: for grayscale images.
  builtIn("Gray Gamma 2.2", [0.9642, 0, 0, 1.0, 0, 0, 0.8249, 0, 0], gammaCurve(2.2), gray = true)

const builtInProfileNames* = ["sRGB IEC61966-2.1", "Adobe RGB (1998)", "Display P3", "ProPhoto RGB"]
  ## The RGB profiles there are to assign or convert to.

proc builtInProfile*(name: string): IccProfile =
  ## The built-in profile called `name` (sRGB for a name it does not know).
  case name
  of "Adobe RGB (1998)": adobeRgbProfile()
  of "Display P3": displayP3Profile()
  of "ProPhoto RGB": prophotoProfile()
  of "Gray Gamma 2.2": grayProfile()
  else: srgbProfile()

# ---- reading -------------------------------------------------------------------------------------------------

proc u32(s: string; at: int): int =
  if at < 0 or at + 4 > s.len: return 0
  (ord(s[at]) shl 24) or (ord(s[at + 1]) shl 16) or (ord(s[at + 2]) shl 8) or ord(s[at + 3])

proc u16(s: string; at: int): int =
  if at < 0 or at + 2 > s.len: return 0
  (ord(s[at]) shl 8) or ord(s[at + 1])

proc s15(s: string; at: int): float =
  float(cast[int32](uint32(int64(u32(s, at)) and 0xFFFF_FFFF'i64))) / 65536

proc parseCurve(s: string; at, size: int): IccCurve =
  let sig = s[at ..< min(s.len, at + 4)]
  if sig == "curv":
    let n = u32(s, at + 8)
    if n == 0: return gammaCurve(1)
    if n == 1: return gammaCurve(u16(s, at + 12).float / 256)
    result = IccCurve(kind: 1)
    for i in 0 ..< min(n, 65536):
      result.table.add u16(s, at + 12 + 2 * i).float / 65535
  elif sig == "para":
    let fn = u16(s, at + 8)
    let count = [1, 3, 4, 5, 7][clamp(fn, 0, 4)]
    result = IccCurve(kind: 2, fn: clamp(fn, 0, 4))
    for i in 0 ..< count: result.params.add s15(s, at + 12 + 4 * i)
  else:
    result = gammaCurve(2.2)

proc textOf(s: string; at, size: int): string =
  let sig = s[at ..< min(s.len, at + 4)]
  if sig == "desc":
    let n = u32(s, at + 8)
    if n > 0 and at + 12 + n <= s.len: return s[at + 12 ..< at + 12 + n].strip(chars = {'\0', ' '})
  elif sig == "mluc":
    let recs = u32(s, at + 8)
    if recs > 0:
      let len = u32(s, at + 20)
      let off = u32(s, at + 24)
      var t = ""
      var i = at + off
      while i + 1 < at + off + len and i + 1 < s.len:
        let c = u16(s, i)
        if c > 0 and c < 128: t.add char(c)
        elif c >= 128: t.add '?'
        i += 2
      return t.strip(chars = {'\0', ' '})
  elif sig == "text":
    return s[at + 8 ..< min(s.len, at + size)].strip(chars = {'\0', ' '})
  ""

# ---- color tables -------------------------------------------------------------------------------------------

const maxLutValues = 1 shl 24     # (more values than a table may have: a damaged one)

proc curveAt(s: string; at: int): (IccCurve, int) =
  ## A curve inside a table (curv or para) and the bytes it takes (0: none there).
  if at < 0 or at + 12 > s.len: return (gammaCurve(1), 0)
  let sig = s[at ..< at + 4]
  if sig == "curv":
    let n = u32(s, at + 8)
    if at + 12 + 2 * n > s.len: return (gammaCurve(1), 0)
    (parseCurve(s, at, 0), 12 + 2 * n)
  elif sig == "para":
    let fn = u16(s, at + 8)
    if fn > 4: return (gammaCurve(1), 0)
    (parseCurve(s, at, 0), 12 + 4 * [1, 3, 4, 5, 7][fn])
  else:
    (gammaCurve(1), 0)

proc curveSet(s: string; at, n: int; ok: var bool): IccStage =
  ## `n` curves one after the other (each on 4 bytes), as lutAtoB has them.
  result = IccStage(kind: iccCurves)
  var p = at
  for i in 0 ..< n:
    let (c, len) = curveAt(s, p)
    if len == 0: ok = false
    result.curves.add c
    p = (p + len + 3) and not 3

proc tableCurves(s: string; at, n, entries, bytes: int): IccStage =
  ## `n` curves as tables of `entries` values each (lut8, lut16).
  result = IccStage(kind: iccCurves)
  for i in 0 ..< n:
    if entries < 2:
      result.curves.add gammaCurve(1)     # (none: straight, as littlecms takes it)
      continue
    var c = IccCurve(kind: 1, table: newSeq[float](entries))
    let base = at + i * entries * bytes
    for j in 0 ..< entries:
      c.table[j] = if bytes == 1: ord(s[base + j]).float / 255 else: u16(s, base + 2 * j).float / 65535
    result.curves.add c

proc gridStage(s: string; at: int; grid: seq[int]; outputs, bytes: int; ok: var bool): IccStage =
  ## A grid of colors (`bytes` 1 or 2 per value) starting at `at`.
  result = IccStage(kind: iccGrid, grid: grid, outputs: outputs)
  var total = outputs
  for g in grid:
    if g < 2 or total > maxLutValues div g:
      ok = false
      return
    total *= g
  if at < 0 or at + total * bytes > s.len:
    ok = false
    return
  result.table = newSeq[float32](total)
  if bytes == 1:
    for i in 0 ..< total: result.table[i] = float32(ord(s[at + i]).float / 255)
  else:
    for i in 0 ..< total:
      result.table[i] = float32(((ord(s[at + 2 * i]) shl 8) or ord(s[at + 2 * i + 1])).float / 65535)

proc parseLut*(s: string; at, size: int): IccLut =
  ## The color table at `at` in a profile's bytes: lut8, lut16, lutAtoB or
  ## lutBtoA (its `kind` is "" when it is none of them, or damaged).
  if at < 0 or at + 32 > s.len: return
  let sig = s[at ..< at + 4]
  let ni = ord(s[at + 8])
  let no = ord(s[at + 9])
  if ni < 1 or ni > 8 or no < 1 or no > 8: return
  var ok = true
  var lut = IccLut(kind: sig, inputs: ni, outputs: no)
  case sig
  of "mft1", "mft2":
    let g = ord(s[at + 10])
    let bytes = if sig == "mft1": 1 else: 2
    let inN = if bytes == 1: 256 else: u16(s, at + 48)
    let outN = if bytes == 1: 256 else: u16(s, at + 50)
    if g < 2 or inN > 0x7FFF or outN > 0x7FFF: return
    var m = newSeq[float](12)
    var identity = true
    for i in 0 .. 8:
      m[i] = s15(s, at + 12 + 4 * i)
      if abs(m[i] - (if i mod 4 == 0: 1.0 else: 0.0)) >= 1 / 65535: identity = false
    # (the matrix: used with 3 inputs, as littlecms does)
    if ni == 3 and not identity:
      lut.stages.add IccStage(kind: iccMatrix, matrix: m, rows: 3, cols: 3)
    let p = at + (if bytes == 1: 48 else: 52)
    if p + ni * inN * bytes > s.len: return
    lut.stages.add tableCurves(s, p, ni, inN, bytes)
    var gr = newSeq[int](ni)
    for i in 0 ..< ni: gr[i] = g
    let clutAt = p + ni * inN * bytes
    let grid = gridStage(s, clutAt, gr, no, bytes, ok)
    if not ok: return
    lut.stages.add grid
    let outAt = clutAt + grid.table.len * bytes
    if outAt + no * outN * bytes > s.len: return
    lut.stages.add tableCurves(s, outAt, no, outN, bytes)
  of "mAB ", "mBA ":
    let offB = u32(s, at + 12)
    let offMat = u32(s, at + 16)
    let offM = u32(s, at + 20)
    let offC = u32(s, at + 24)
    let offA = u32(s, at + 28)
    let atob = sig == "mAB "
    template matrixStage(): IccStage =
      var m = newSeq[float](12)
      for i in 0 ..< 12: m[i] = s15(s, at + offMat + 4 * i)
      if at + offMat + 48 > s.len: ok = false
      IccStage(kind: iccMatrix, matrix: m, rows: 3, cols: 3)
    template gridOf(nIn, nOut: int): IccStage =
      var gr = newSeq[int](nIn)
      for i in 0 ..< nIn: gr[i] = ord(s[min(s.len - 1, at + offC + i)])
      let prec = ord(s[min(s.len - 1, at + offC + 16)])
      if prec notin [1, 2]: ok = false
      gridStage(s, at + offC + 20, gr, nOut, prec, ok)
    if atob:
      # A curves, grid, M curves, matrix, B curves
      if offA != 0: lut.stages.add curveSet(s, at + offA, ni, ok)
      if offC != 0: lut.stages.add gridOf(ni, no)
      if offM != 0: lut.stages.add curveSet(s, at + offM, no, ok)
      if offMat != 0: lut.stages.add matrixStage()
      if offB != 0: lut.stages.add curveSet(s, at + offB, no, ok)
    else:
      # B curves, matrix, M curves, grid, A curves
      if offB != 0: lut.stages.add curveSet(s, at + offB, ni, ok)
      if offMat != 0: lut.stages.add matrixStage()
      if offM != 0: lut.stages.add curveSet(s, at + offM, ni, ok)
      if offC != 0: lut.stages.add gridOf(ni, no)
      if offA != 0: lut.stages.add curveSet(s, at + offA, no, ok)
    if offC == 0 and ni != no: ok = false
  else:
    return
  if ok: result = lut

proc parseIcc*(data: string): IccProfile =
  ## A profile from its bytes (not usable when it is damaged or not of the
  ## matrix-and-curves kind; its tables, when it has some, in `a2b`, `b2a`).
  result.data = data
  if data.len < 132 or data[36 ..< 40] != "acsp": return
  result.colorSpace = data[16 ..< 20]
  result.version = u32(data, 8)
  result.deviceClass = data[12 ..< 16]
  result.pcs = data[20 ..< 24]
  result.mediaWhite = [0.9642, 1.0, 0.8249]
  let n = u32(data, 128)
  var tags: seq[(string, int, int)]
  for i in 0 ..< min(n, 200):
    let at = 132 + 12 * i
    if at + 12 > data.len: break
    let off = u32(data, at + 4)
    let size = u32(data, at + 8)
    if off < 0 or size < 0 or off + size > data.len: continue
    tags.add (data[at ..< at + 4], off, size)
  proc find(sig: string): (int, int) =
    for (t, o, s) in tags:
      if t == sig: return (o, s)
    (-1, 0)
  let (d, ds) = find("desc")
  if d >= 0: result.name = textOf(data, d, ds)
  result.description = result.name
  if result.name.len == 0: result.name = "Embedded profile"
  for (sig, k) in [("wtpt", 0), ("bkpt", 1)]:
    let (o, _) = find(sig)
    if o >= 0 and o + 20 <= data.len and data[o ..< o + 4] == "XYZ ":
      let v = [s15(data, o + 8), s15(data, o + 12), s15(data, o + 16)]
      if k == 0: result.mediaWhite = v else: result.mediaBlack = v
  for i in 0 .. 2:
    let (a, asz) = find("A2B" & $i)
    if a >= 0: result.a2b[i] = parseLut(data, a, asz)
    let (b, bsz) = find("B2A" & $i)
    if b >= 0: result.b2a[i] = parseLut(data, b, bsz)
  if result.colorSpace == "RGB ":
    var ok = true
    for k, sig in ["rXYZ", "gXYZ", "bXYZ"]:
      let (o, _) = find(sig)
      if o < 0: ok = false; break
      result.toXyz[k] = s15(data, o + 8)
      result.toXyz[3 + k] = s15(data, o + 12)
      result.toXyz[6 + k] = s15(data, o + 16)
    for k, sig in ["rTRC", "gTRC", "bTRC"]:
      let (o, sz) = find(sig)
      if o < 0: ok = false; break
      result.trc[k] = parseCurve(data, o, sz)
    result.usable = ok
  elif result.colorSpace == "GRAY":
    let (o, sz) = find("kTRC")
    if o >= 0:
      result.trc[0] = parseCurve(data, o, sz)
      result.trc[1] = result.trc[0]
      result.trc[2] = result.trc[0]
      result.toXyz = [0.9642, 0, 0, 1.0, 0, 0, 0.8249, 0, 0]
      result.usable = true

proc isSrgbLike*(p: IccProfile): bool =
  ## Close enough to sRGB that its pixels need no change.
  if not p.usable or p.colorSpace != "RGB ": return false
  let s = srgbProfile()
  for k in 0 .. 8:
    if abs(p.toXyz[k] - s.toXyz[k]) > 0.004: return false
  for k in 0 .. 2:
    for x in [0.02, 0.1, 0.25, 0.5, 0.75, 0.95]:
      if abs(p.trc[k].eval(x) - s.trc[0].eval(x)) > 0.004: return false
  true

# ---- where pictures keep them ---------------------------------------------------------------------------------

proc iccFromJpeg*(data: string): string =
  ## The profile in a JPEG's APP2 segments ("" when there is none).
  if data.len < 4 or data[0] != '\xFF' or data[1] != '\xD8': return
  var parts: seq[(int, string)]
  var p = 2
  while p + 4 <= data.len:
    if data[p] != '\xFF': break
    let m = ord(data[p + 1])
    if m == 0xD8 or m in 0xD0 .. 0xD7 or m == 0x01:
      p += 2
      continue
    if m == 0xDA or m == 0xD9: break
    let len = u16(data, p + 2)
    if len < 2 or p + 2 + len > data.len: break
    if m == 0xE2 and len > 16 and data[p + 4 ..< p + 16] == "ICC_PROFILE\0":
      parts.add (ord(data[p + 16]), data[p + 18 ..< p + 2 + len])
    p += 2 + len
  for k in 1 .. parts.len:
    for (no, s) in parts:
      if no == k: result.add s

proc iccFromPng*(data: string): string =
  ## The profile in a PNG's iCCP chunk.
  var p = 8
  while p + 12 <= data.len:
    let n = u32(data, p)
    if n < 0 or p + 12 + n > data.len: break
    let kind = data[p + 4 ..< p + 8]
    if kind == "iCCP":
      let body = data[p + 8 ..< p + 8 + n]
      let z = body.find('\0')
      if z < 0 or z + 2 > body.len: return
      try:
        let raw = zlibDecompress(body.toOpenArrayByte(z + 2, body.high), 16 shl 20)
        result = newString(raw.len)
        if raw.len > 0: copyMem(addr result[0], unsafeAddr raw[0], raw.len)
      except CatchableError: result = ""
      return
    if kind == "IDAT" or kind == "IEND": return
    p += 12 + n

proc iccFromTiff*(data: string): string =
  ## The profile in a TIFF's first directory (tag 34675).
  if data.len < 8: return
  let le = data[0] == 'I'
  proc r16(at: int): int =
    if at < 0 or at + 2 > data.len: return 0
    if le: ord(data[at]) or (ord(data[at + 1]) shl 8) else: (ord(data[at]) shl 8) or ord(data[at + 1])
  proc r32(at: int): int =
    if at < 0 or at + 4 > data.len: return 0
    if le: ord(data[at]) or (ord(data[at + 1]) shl 8) or (ord(data[at + 2]) shl 16) or (ord(data[at + 3]) shl 24)
    else: (ord(data[at]) shl 24) or (ord(data[at + 1]) shl 16) or (ord(data[at + 2]) shl 8) or ord(data[at + 3])
  let ifd = r32(4)
  let n = r16(ifd)
  for i in 0 ..< min(n, 500):
    let e = ifd + 2 + 12 * i
    if r16(e) == 34675:
      let cnt = r32(e + 4)
      let off = r32(e + 8)
      if cnt > 0 and off >= 0 and off + cnt <= data.len: return data[off ..< off + cnt]

# ---- converting ---------------------------------------------------------------------------------------------

proc conversion*(src, dst: IccProfile): tuple[lin: array[3, seq[float32]]; m: array[9, float];
                                             enc: array[3, seq[uint8]]] =
  ## What converting pixels from `src` to `dst` takes: a table to linear
  ## light for each of src's 256 values, a matrix, a table back for 4096
  ## levels of light.
  for k in 0 .. 2:
    result.lin[k] = newSeq[float32](256)
    for v in 0 .. 255: result.lin[k][v] = float32(src.trc[k].eval(v / 255))
  result.m = mul(inv(dst.toXyz), src.toXyz)
  for k in 0 .. 2:
    # (the curve turned round: for each level of light the value that gives it)
    result.enc[k] = newSeq[uint8](4096)
    var v = 0
    for i in 0 ..< 4096:
      let want = i / 4095
      while v < 255 and dst.trc[k].eval((v.float + 0.5) / 255) < want: inc v
      result.enc[k][i] = uint8(v)

proc convertPixels*(px: var seq[uint32]; src, dst: IccProfile) =
  ## The pixels (in `src`'s colors) made into `dst`'s: the same colors as
  ## near as can be.
  if not src.usable or not dst.usable: return
  let c = conversion(src, dst)
  let grayDst = dst.colorSpace == "GRAY"
  let graySrc = src.colorSpace == "GRAY"
  for p in px.mitems:
    let a = p and 0xFF000000'u32
    var r = c.lin[0][int((p shr 16) and 255)].float
    var g = c.lin[1][int((p shr 8) and 255)].float
    var b = c.lin[2][int(p and 255)].float
    if graySrc:
      g = r
      b = r
    var x, y, z: float
    if grayDst:
      # (the light: Y of src)
      let yy = src.toXyz[3] * r + src.toXyz[4] * g + src.toXyz[5] * b
      x = yy; y = yy; z = yy
    else:
      x = c.m[0] * r + c.m[1] * g + c.m[2] * b
      y = c.m[3] * r + c.m[4] * g + c.m[5] * b
      z = c.m[6] * r + c.m[7] * g + c.m[8] * b
    let ri = int(clamp(x, 0.0, 1.0) * 4095 + 0.5)
    let gi = int(clamp(y, 0.0, 1.0) * 4095 + 0.5)
    let bi = int(clamp(z, 0.0, 1.0) * 4095 + 0.5)
    p = a or (uint32(c.enc[0][ri]) shl 16) or (uint32(c.enc[1][gi]) shl 8) or uint32(c.enc[2][bi])

# ---- writing -----------------------------------------------------------------------------------------------

proc be32(v: int): string =
  result = newString(4)
  result[0] = char((v shr 24) and 255); result[1] = char((v shr 16) and 255)
  result[2] = char((v shr 8) and 255); result[3] = char(v and 255)

proc be16(v: int): string =
  result = newString(2)
  result[0] = char((v shr 8) and 255); result[1] = char(v and 255)

proc fixed(v: float): string =
  be32(int(round(v * 65536)))      # (be32 writes the low 32 bits: two's complement)

proc iccBytes*(p: IccProfile): string =
  ## A version 2 profile of `p` (matrix and curves, or gray).
  var tags: seq[(string, string)]
  var desc = "desc" & be32(0) & be32(p.name.len + 1) & p.name & "\0"
  desc.add be32(0) & be32(0)                      # (no Unicode)
  desc.add be16(0) & "\0" & newString(67)         # (no ScriptCode)
  tags.add ("desc", desc)
  tags.add ("cprt", "text" & be32(0) & "No copyright, use freely\0")
  tags.add ("wtpt", "XYZ " & be32(0) & fixed(0.9642) & fixed(1.0) & fixed(0.8249))
  proc curve(c: IccCurve): string =
    case c.kind
    of 0:
      result = "curv" & be32(0) & be32(1) & be16(int(round(c.gamma * 256)))
    else:
      # (a table: what version 2 has for every curve)
      result = "curv" & be32(0) & be32(1024)
      for i in 0 ..< 1024: result.add be16(int(round(clamp(c.eval(i / 1023), 0.0, 1.0) * 65535)))
    while result.len mod 4 != 0: result.add '\0'
  if p.colorSpace == "GRAY":
    tags.add ("kTRC", curve(p.trc[0]))
  else:
    for k, sig in ["rXYZ", "gXYZ", "bXYZ"]:
      tags.add (sig, "XYZ " & be32(0) & fixed(p.toXyz[k]) & fixed(p.toXyz[3 + k]) & fixed(p.toXyz[6 + k]))
    let c0 = curve(p.trc[0])
    for sig in ["rTRC", "gTRC", "bTRC"]: tags.add (sig, c0)
  # the table of tags, then their data (each on 4 bytes)
  var body = ""
  var table = be32(tags.len)
  let start = 128 + 4 + 12 * tags.len
  for (sig, data) in tags:
    var d = data
    while d.len mod 4 != 0: d.add '\0'
    table.add sig & be32(start + body.len) & be32(data.len)
    body.add d
  let size = start + body.len
  var head = be32(size) & "none" & be32(0x02100000) & "mntr" &
             (if p.colorSpace == "GRAY": "GRAY" else: "RGB ") & "XYZ " & newString(12) & "acsp" &
             "APPL" & be32(0) & "none" & "none" & be32(0) & be32(0) & be32(0) &
             fixed(0.9642) & fixed(1.0) & fixed(0.8249) & "none"
  while head.len < 128: head.add '\0'
  head & table & body

proc embedInJpeg*(jpeg, icc: string): string =
  ## A JPEG with the profile in APP2 segments (after its first segments).
  if icc.len == 0 or jpeg.len < 4 or jpeg[0 .. 1] != "\xFF\xD8": return jpeg
  var at = 2
  # (after JFIF and EXIF)
  while at + 4 <= jpeg.len and jpeg[at] == '\xFF' and ord(jpeg[at + 1]) in [0xE0, 0xE1]:
    at += 2 + u16(jpeg, at + 2)
  var segs = ""
  let most = 65519
  let n = (icc.len + most - 1) div most
  for k in 0 ..< n:
    let part = icc[k * most ..< min(icc.len, (k + 1) * most)]
    segs.add "\xFF\xE2" & be16(2 + 14 + part.len) & "ICC_PROFILE\0" & char(k + 1) & char(n) & part
  jpeg[0 ..< at] & segs & jpeg[at .. ^1]

proc crc32(s: string): uint32 =
  var c = 0xFFFFFFFF'u32
  for ch in s:
    c = c xor uint32(ord(ch))
    for _ in 0 .. 7:
      c = if (c and 1) != 0: (c shr 1) xor 0xEDB88320'u32 else: c shr 1
  not c

proc embedInPng*(png, icc: string; name = "ICC Profile"): string =
  ## A PNG with the profile in an iCCP chunk (after its header).
  if icc.len == 0 or png.len < 33 or png[12 ..< 16] != "IHDR": return png
  let z = zlibCompress(icc.toOpenArrayByte(0, icc.high))
  var zs = newString(z.len)
  if z.len > 0: copyMem(addr zs[0], unsafeAddr z[0], z.len)
  let nm = name[0 ..< min(79, name.len)]
  let body = "iCCP" & nm & "\0\0" & zs
  let crc = crc32(body)
  # (the CRC's bytes as they are: an int of 32 bits does not hold one)
  let chunk = be32(body.len - 4) & body & char((crc shr 24) and 255) & char((crc shr 16) and 255) &
              char((crc shr 8) and 255) & char(crc and 255)
  let at = 8 + 12 + u32(png, 8)
  png[0 ..< at] & chunk & png[at .. ^1]

const GridN* = 33
  ## The display table's grid (33 x 33 x 33, read between).

proc displayTable*(icc: string): seq[uint32] =
  ## The colors of a profile as sRGB shows them, on a grid (r, g, b each
  ## 0..32): to show a picture in another profile as it looks. Empty when
  ## the profile cannot be used.
  let p = parseIcc(icc)
  if not p.usable: return
  var px = newSeq[uint32](GridN * GridN * GridN)
  for ri in 0 ..< GridN:
    for gi in 0 ..< GridN:
      for bi in 0 ..< GridN:
        let r = (ri * 255 + (GridN - 1) div 2) div (GridN - 1)
        let g = (gi * 255 + (GridN - 1) div 2) div (GridN - 1)
        let b = (bi * 255 + (GridN - 1) div 2) div (GridN - 1)
        px[(ri * GridN + gi) * GridN + bi] = 0xFF000000'u32 or (uint32(r) shl 16) or (uint32(g) shl 8) or uint32(b)
  convertPixels(px, p, srgbProfile())
  for v in px.mitems: v = v and 0xFFFFFF'u32
  px

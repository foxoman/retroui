## Colors as they print and as they are seen: printing inks (CMYK) with a
## model of how cyan, magenta, yellow and black on paper mix (Neugebauer's,
## with dot gain and black generation, the ink limit) -- or with a press's
## ICC profile (FOGRA39, GRACoL...) when one is set -- Lab, and duotones (a
## gray image printed in one to four inks). Used by `retroui/photo` for the
## CMYK, Lab and Duotone modes, Proof Colors and the gamut warning.
##
## ```nim
## let ink = inkOf(0xFF3366CC'u32)          # C, M, Y, K, 0..255
## let looks = printed(ink)                  # what it looks like printed
## echo inGamut(0xFF0000FF'u32)              # pure blue: false
## setInkProfile(readFile("press.icc"))      # the inks from the press's profile
## let icc = inkModelProfile(inkSetup)       # the built-in model as a profile (PDF/X)
## ```

import std/[math, locks]
import parallel, iccprofile, icclut, simd

export RenderingIntent

type
  Ink* = array[4, uint8]
    ## Cyan, magenta, yellow, black: 0 none .. 255 full.

  BlackGeneration* = enum
    ## How much of the dark is printed with black ink instead of cyan,
    ## magenta and yellow (Photoshop's Black Generation): none .. as much as
    ## can be.
    bgNone = "None", bgLight = "Light", bgMedium = "Medium", bgHeavy = "Heavy", bgMaximum = "Maximum"

  InkSetup* = object
    ## How the image will print (File > Color Settings).
    dotGain*: int               ## % at the middle tones (20: 50 % becomes 70 %)
    black*: BlackGeneration     ## how much black ink replaces the others
    inkLimit*: int              ## the most ink on paper, % (300)
    blackLimit*: int            ## the most black, % (100)

  DuotoneInk* = object
    ## An ink of a duotone and how much of it each gray takes.
    name*: string               ## its name ("PANTONE 286 C", "Black")
    color*: uint32              ## what it looks like on paper (0xFFRRGGBB)
    gamma*: float               ## its curve: 1 straight, < 1 more ink, > 1 less

const defaultInks* = InkSetup(dotGain: 20, black: bgMedium, inkLimit: 300, blackLimit: 100)
  ## Photoshop's usual setup: 20 % dot gain, medium black, 300 % ink, 100 % black.

var inkSetup* = defaultInks
  ## The setup used (change it with `setInks`).

var
  inkIcc: string                 # the press profile the inks come from ("": the model)
  inkIccName: string
  inkProf: IccProfile
  inkIntent = riRelative
  inkBpc = true
  inkPaper = false
  inkGen = 0                     # one more at each change of profile: the tables see it
  toPrinted: IccTransform        # (with a profile) its CMYK to sRGB, as it prints

# ---- light ------------------------------------------------------------------------------------------------

var toLinear: array[256, float32]

for i in 0 .. 255:
  let c = i / 255
  toLinear[i] = float32(if c <= 0.04045: c / 12.92 else: pow((c + 0.055) / 1.055, 2.4))

proc fromLinear(v: float): int {.inline.} =
  let c = clamp(v, 0.0, 1.0)
  let s = if c <= 0.0031308: c * 12.92 else: 1.055 * pow(c, 1 / 2.4) - 0.055
  int(round(s * 255))

# ---- the inks on paper ---------------------------------------------------------------------------------------

const
  # what paper and the inks and their overprints look like (sRGB): white,
  # C, M, Y, C+M, C+Y, M+Y, C+M+Y; and black alone
  primaries: array[8, (int, int, int)] = [(255, 255, 255), (0, 158, 224), (226, 0, 122), (255, 241, 0),
                                          (46, 49, 145), (0, 152, 70), (237, 28, 36), (54, 48, 50)]
  blackInk = (35, 31, 32)

var primLin: array[8, array[3, float]]
for i, p in primaries:
  primLin[i] = [toLinear[p[0]].float, toLinear[p[1]].float, toLinear[p[2]].float]
let blackLin = [toLinear[blackInk[0]].float, toLinear[blackInk[1]].float, toLinear[blackInk[2]].float]

proc gained(t: float; gain: int): float {.inline.} =
  ## An ink's dot as it lands on paper (bigger by the dot gain).
  clamp(t + gain.float / 100 * 4 * t * (1 - t), 0.0, 1.0)

proc printedLinear(c, m, y, k: float; gain: int): array[3, float] =
  ## The color (linear light) of inks `c`, `m`, `y`, `k` (0..1) on paper.
  let c = gained(c, gain)
  let m = gained(m, gain)
  let y = gained(y, gain)
  let k = gained(k, gain)
  let w = [(1 - c) * (1 - m) * (1 - y), c * (1 - m) * (1 - y), (1 - c) * m * (1 - y), (1 - c) * (1 - m) * y,
           c * m * (1 - y), c * (1 - m) * y, (1 - c) * m * y, c * m * y]
  for ch in 0 .. 2:
    var v = 0.0
    for i in 0 .. 7: v += w[i] * primLin[i][ch]
    result[ch] = v * (1 - k * (1 - blackLin[ch]))

proc printed*(c, m, y, k: int): uint32 =
  ## What inks `c`, `m`, `y`, `k` (0..255) look like printed (0xFFRRGGBB).
  if inkIcc.len > 0: return toPrinted.cmykToRgb(c, m, y, k)
  let v = printedLinear(c / 255, m / 255, y / 255, k / 255, inkSetup.dotGain)
  0xFF000000'u32 or (uint32(fromLinear(v[0])) shl 16) or (uint32(fromLinear(v[1])) shl 8) or
    uint32(fromLinear(v[2]))

proc printed*(ink: Ink): uint32 = printed(ink[0].int, ink[1].int, ink[2].int, ink[3].int)
  ## What the inks `ink` (as `inkOf` gives them) look like printed.

const M4 = 17
var
  printTable: seq[uint32]       # 17^4 inks -> colors
  printSetup: InkSetup
  printGen = -1

proc printedFast*(c, m, y, k: int): uint32 =
  ## `printed`, read from a table (for whole pictures of inks).
  if printTable.len != M4 * M4 * M4 * M4 or printSetup != inkSetup or printGen != inkGen:
    printGen = inkGen
    printTable = newSeq[uint32](M4 * M4 * M4 * M4)
    for ci in 0 ..< M4:
      for mi in 0 ..< M4:
        for yi in 0 ..< M4:
          for ki in 0 ..< M4:
            printTable[((ci * M4 + mi) * M4 + yi) * M4 + ki] =
              printed(ci * 255 div (M4 - 1), mi * 255 div (M4 - 1), yi * 255 div (M4 - 1), ki * 255 div (M4 - 1))
    printSetup = inkSetup
  let v = [clamp(c, 0, 255) * (M4 - 1), clamp(m, 0, 255) * (M4 - 1), clamp(y, 0, 255) * (M4 - 1),
           clamp(k, 0, 255) * (M4 - 1)]
  var i0: array[4, int]
  var f: array[4, float]
  for j in 0 .. 3:
    i0[j] = min(v[j] div 255, M4 - 2)
    f[j] = (v[j] - i0[j] * 255) / 255
  var acc = [0.0, 0.0, 0.0]
  for corner in 0 .. 15:
    var w = 1.0
    var idx = 0
    for j in 0 .. 3:
      let bit = (corner shr j) and 1
      w *= (if bit == 1: f[j] else: 1 - f[j])
      idx = idx * M4 + i0[j] + bit
    if w <= 0: continue
    let q = printTable[idx]
    acc[0] += float((q shr 16) and 255) * w
    acc[1] += float((q shr 8) and 255) * w
    acc[2] += float(q and 255) * w
  0xFF000000'u32 or (uint32(clamp(int(acc[0] + 0.5), 0, 255)) shl 16) or
    (uint32(clamp(int(acc[1] + 0.5), 0, 255)) shl 8) or uint32(clamp(int(acc[2] + 0.5), 0, 255))

proc blackFor(r, g, b: float; how: BlackGeneration): float =
  ## How much black a color (0..1, sRGB) takes.
  let k0 = 1 - max(r, max(g, b))
  case how
  of bgNone: 0.0
  of bgLight: max(0.0, (k0 - 0.4) / 0.6) * 0.9
  of bgMedium: pow(max(0.0, (k0 - 0.15) / 0.85), 1.25) * 0.95
  of bgHeavy: max(0.0, (k0 - 0.05) / 0.95)
  of bgMaximum: k0

proc solveInkWith(t, enc: array[3, float]; k: float; s: InkSetup): (array[4, float], float) =
  ## The inks (0..1) with black `k` that print nearest to the color (its
  ## light `t`, its sRGB values `enc`, 0..1) and how far off they are: cyan,
  ## magenta and yellow found by Gauss-Newton steps, within the ink limit.
  # (a start: the naive inks)
  let kk = max(1e-3, 1 - k)
  var x = [clamp((1 - enc[0] - k) / kk, 0.0, 1.0), clamp((1 - enc[1] - k) / kk, 0.0, 1.0),
           clamp((1 - enc[2] - k) / kk, 0.0, 1.0)]
  proc err(x: array[3, float]): array[3, float] =
    let p = printedLinear(x[0], x[1], x[2], k, s.dotGain)
    for ch in 0 .. 2: result[ch] = pow(max(p[ch], 0.0), 1 / 2.2) - pow(t[ch], 1 / 2.2)
  for _ in 0 ..< 12:
    let e = err(x)
    if abs(e[0]) + abs(e[1]) + abs(e[2]) < 1e-4: break
    var j: array[3, array[3, float]]          # d err[row] / d x[col]
    const h = 1e-3
    for col in 0 .. 2:
      var x2 = x
      x2[col] = if x[col] + h <= 1: x[col] + h else: x[col] - h
      let e2 = err(x2)
      let dx = x2[col] - x[col]
      for row in 0 .. 2: j[row][col] = (e2[row] - e[row]) / dx
    # (J^T J + lambda I) d = -J^T e
    var a: array[3, array[3, float]]
    var rhs: array[3, float]
    for i in 0 .. 2:
      for jj in 0 .. 2:
        var v = 0.0
        for row in 0 .. 2: v += j[row][i] * j[row][jj]
        a[i][jj] = v + (if i == jj: 1e-4 else: 0.0)
      var v = 0.0
      for row in 0 .. 2: v += j[row][i] * e[row]
      rhs[i] = -v
    # Cramer
    proc det(m: array[3, array[3, float]]): float =
      m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
        m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
    let dd = det(a)
    if abs(dd) < 1e-18: break
    var step: array[3, float]
    for col in 0 .. 2:
      var m2 = a
      for row in 0 .. 2: m2[row][col] = rhs[row]
      step[col] = det(m2) / dd
    for i in 0 .. 2: x[i] = clamp(x[i] + clamp(step[i], -0.5, 0.5), 0.0, 1.0)
  # the ink limit
  let total = x[0] + x[1] + x[2] + k
  let lim = s.inkLimit / 100
  if total > lim and x[0] + x[1] + x[2] > 0:
    let f = max(0.0, (lim - k) / (x[0] + x[1] + x[2]))
    for i in 0 .. 2: x[i] *= f
  let e = err(x)
  ([x[0], x[1], x[2], k], abs(e[0]) + abs(e[1]) + abs(e[2]))

proc solveInk(t, enc: array[3, float]; s: InkSetup): array[4, float] =
  ## The inks (0..1) that print nearest to the color (light `t`, sRGB
  ## `enc`): black as the setup generates it -- less when the other inks
  ## cannot then reach the color.
  let k0 = min(blackFor(enc[0], enc[1], enc[2], s.black), s.blackLimit / 100)
  var (best, err) = solveInkWith(t, enc, k0, s)
  if err > 0.012 and k0 > 0:
    for f in [0.66, 0.33, 0.0]:
      let (x, e2) = solveInkWith(t, enc, k0 * f, s)
      if e2 < err - 0.004:
        best = x
        err = e2
  best

proc solveInk(r, g, b: int): array[4, float] =
  ## `solveInk` for an sRGB color (0..255 each) with the setup in use.
  solveInk([toLinear[r].float, toLinear[g].float, toLinear[b].float], [r / 255, g / 255, b / 255], inkSetup)

# ---- tables -------------------------------------------------------------------------------------------------

const N* = 33
  ## The tables' grid: 33 x 33 x 33 colors (read between).

var
  inkTable: seq[uint32]          # C, M, Y, K packed (C highest)
  proofTable: seq[uint32]        # the color as it prints
  tableSetup: InkSetup
  tableGen = -1
  gamutTable: seq[uint32]        # (with a profile) the colors there and back, colorimetric
  gamutGen = -1
  tablesReady, gamutReady: bool  # (atomic: the tables made, safe to read from any thread)
  tablesLock: Lock               # (one thread makes them; the others wait)

initLock(tablesLock)

proc printedTable(inks: seq[uint32]; back: IccTransform): seq[uint32] =
  ## The colors the inks of a table print (through the profile).
  result = newSeq[uint32](inks.len)
  let src = cast[ptr UncheckedArray[uint32]](unsafeAddr inks[0])
  let dst = cast[ptr UncheckedArray[uint32]](addr result[0])
  let t = unsafeAddr back
  parallelFor(N, proc (lo, hi: int) =
    for i in lo * N * N ..< hi * N * N:
      let v = src[i]
      dst[i] = cmykToRgb(t[], int(v shr 24), int((v shr 16) and 255), int((v shr 8) and 255), int(v and 255))
  , keepAlive = false)

proc makeTables() =
  ## (36 000 colors separated: on all the cores -- a quarter of a second
  ## alone, the first time the Info palette or a proof shows inks; with a
  ## profile, some 20 ms)
  if inkIcc.len > 0:
    let t = rgbToCmykGrid(srgbProfile(), inkProf, inkIntent, inkBpc, N)
    let pt = printedTable(t, toPrinted)
    inkTable = t
    proofTable = pt
    tableSetup = inkSetup
    tableGen = inkGen
    return
  var newInks = newSeq[uint32](N * N * N)
  var newProofs = newSeq[uint32](N * N * N)
  let inks = cast[ptr UncheckedArray[uint32]](addr newInks[0])
  let proofs = cast[ptr UncheckedArray[uint32]](addr newProofs[0])
  parallelFor(N, proc (lo, hi: int) =
    for ri in lo ..< hi:
      for gi in 0 ..< N:
        for bi in 0 ..< N:
          let r = (ri * 255 + (N - 1) div 2) div (N - 1)
          let g = (gi * 255 + (N - 1) div 2) div (N - 1)
          let b = (bi * 255 + (N - 1) div 2) div (N - 1)
          let x = solveInk(r, g, b)
          let c = uint32(round(x[0] * 255))
          let m = uint32(round(x[1] * 255))
          let y = uint32(round(x[2] * 255))
          let k = uint32(round(x[3] * 255))
          let i = (ri * N + gi) * N + bi
          inks[i] = (c shl 24) or (m shl 16) or (y shl 8) or k
          proofs[i] = printed(c.int, m.int, y.int, k.int)
  , keepAlive = false)
  inkTable = move(newInks)
  proofTable = move(newProofs)
  tableSetup = inkSetup
  tableGen = inkGen

proc tablesFit(): bool {.inline.} =
  atomicLoadN(addr tablesReady, ATOMIC_ACQUIRE) and tableGen == inkGen and tableSetup == inkSetup

proc ensureTables() {.inline.} =
  # (made by one thread, read by all: the colors of a picture separated on
  # all the cores asked for them at once -- each made them over the others'
  # and freed tables still read)
  if tablesFit(): return
  withLock tablesLock:
    if not tablesFit():
      atomicStoreN(addr tablesReady, false, ATOMIC_RELEASE)
      makeTables()
      atomicStoreN(addr tablesReady, true, ATOMIC_RELEASE)

proc setInks*(s: InkSetup) =
  ## Another printing setup (the tables are made again when next used).
  inkSetup = s

proc setInkProfile*(icc: string; intent = riRelative; bpc = true; simulatePaper = false): bool {.discardable.} =
  ## The inks from a press's ICC profile (CMYK, with tables: FOGRA39,
  ## GRACoL...) instead of the built-in model: colors separated with
  ## `intent` and black point compensation (`bpc`), and shown as they print
  ## (relative colorimetric: the paper white; absolute when `simulatePaper`,
  ## the paper's own color). "" goes back to the built-in model. False (and
  ## nothing changed) when the profile cannot be used so.
  if icc.len == 0:
    if inkIcc.len > 0:
      inkIcc = ""
      inkIccName = ""
      inkProf = IccProfile()
      toPrinted = IccTransform()
      inc inkGen
    return true
  let p = parseIcc(icc)
  if p.colorSpace != "CMYK": return false
  let srgb = srgbProfile()
  let fwd = newTransform(srgb, p, intent, bpc)
  let back = newTransform(p, srgb, if simulatePaper: riAbsolute else: riRelative)
  if not fwd.ok or not back.ok: return false
  inkIcc = icc
  inkIccName = if p.description.len > 0: p.description else: p.name
  inkProf = p
  inkIntent = intent
  inkBpc = bpc
  inkPaper = simulatePaper
  toPrinted = back
  inc inkGen
  true

proc inkProfile*(): string =
  ## The bytes of the press profile the inks come from ("": the built-in model).
  inkIcc

proc inkProfileName*(): string =
  ## Its name (its description), "" with the built-in model.
  inkIccName

{.push boundChecks: off, overflowChecks: off.}

proc lookup(t: ptr UncheckedArray[uint32]; p: uint32): uint32 {.inline.} =
  ## A table read between its grid colors (each byte apart).
  when simdOn:
    lutInk(t, N, p)
  else:
    const n = N - 1
    let r = int((p shr 16) and 255) * n
    let g = int((p shr 8) and 255) * n
    let b = int(p and 255) * n
    let ri = min(r div 255, n - 1)
    let gi = min(g div 255, n - 1)
    let bi = min(b div 255, n - 1)
    let rf = r - ri * 255
    let gf = g - gi * 255
    let bf = b - bi * 255
    let i000 = (ri * N + gi) * N + bi
    var o = 0'u32
    for sh in [24, 16, 8, 0]:
      template v(i: int): int = int((t[i] shr sh) and 255)
      let c00 = v(i000) * (255 - bf) + v(i000 + 1) * bf
      let c01 = v(i000 + N) * (255 - bf) + v(i000 + N + 1) * bf
      let c10 = v(i000 + N * N) * (255 - bf) + v(i000 + N * N + 1) * bf
      let c11 = v(i000 + N * N + N) * (255 - bf) + v(i000 + N * N + N + 1) * bf
      let c0 = c00 * (255 - gf) + c01 * gf
      let c1 = c10 * (255 - gf) + c11 * gf
      let c = (c0 div 255 * (255 - rf) + c1 div 255 * rf + 255 * 127) div (255 * 255)
      o = o or (uint32(clamp(c, 0, 255)) shl sh)
    o

{.pop.}

proc inkOf*(p: uint32): Ink =
  ## The inks that print a color (its alpha left out).
  ensureTables()
  let v = lookup(cast[ptr UncheckedArray[uint32]](addr inkTable[0]), p)
  [uint8(v shr 24), uint8((v shr 16) and 255), uint8((v shr 8) and 255), uint8(v and 255)]

proc proofOf*(p: uint32): uint32 =
  ## A color as it prints (its alpha kept).
  ensureTables()
  let v = lookup(cast[ptr UncheckedArray[uint32]](addr proofTable[0]), p)
  (v and 0xFFFFFF'u32) or (p and 0xFF000000'u32)

proc proofTablePtr*(): ptr UncheckedArray[uint32] =
  ## The table of `proofOf` (for drawing many pixels: `lookupProof`).
  ensureTables()
  cast[ptr UncheckedArray[uint32]](addr proofTable[0])

proc lookupProof*(t: ptr UncheckedArray[uint32]; p: uint32): uint32 {.inline.} =
  ## `proofOf` through the table `proofTablePtr` gave (its alpha kept).
  (lookup(t, p) and 0xFFFFFF'u32) or (p and 0xFF000000'u32)

proc gamutDistance*(p: uint32): int =
  ## How far a color is from what can be printed (0..255). With a profile:
  ## from the color taken to the inks and back colorimetrically (relative,
  ## without black point compensation), whatever the intent.
  var q: uint32
  if inkIcc.len > 0 and (inkIntent != riRelative or inkBpc or inkPaper):
    if not (atomicLoadN(addr gamutReady, ATOMIC_ACQUIRE) and gamutGen == inkGen):
      withLock tablesLock:
        if not (atomicLoadN(addr gamutReady, ATOMIC_ACQUIRE) and gamutGen == inkGen):
          atomicStoreN(addr gamutReady, false, ATOMIC_RELEASE)
          let srgb = srgbProfile()
          gamutTable = printedTable(rgbToCmykGrid(srgb, inkProf, riRelative, false, N),
                                    newTransform(inkProf, srgb, riRelative))
          gamutGen = inkGen
          atomicStoreN(addr gamutReady, true, ATOMIC_RELEASE)
    q = lookup(cast[ptr UncheckedArray[uint32]](addr gamutTable[0]), p)
  else:
    q = proofOf(p)
  max(abs(int((p shr 16) and 255) - int((q shr 16) and 255)),
      max(abs(int((p shr 8) and 255) - int((q shr 8) and 255)), abs(int(p and 255) - int(q and 255))))

proc inGamut*(p: uint32; tolerance = 12): bool =
  ## Whether a color can be printed (near enough).
  gamutDistance(p) <= tolerance

proc fromInk*(ink: Ink; alpha = 255): uint32 =
  ## The color of inks as it shows on the screen.
  (printed(ink) and 0xFFFFFF'u32) or (uint32(alpha) shl 24)

# ---- the model as a profile ----------------------------------------------------------------------------------------

proc encodeSrgb(c: float): float =
  if c <= 0.0031308: c * 12.92 else: 1.055 * pow(c, 1 / 2.4) - 0.055

proc modelLab(c, m, y, k: float; toXyz: array[9, float]): array[3, float] =
  ## Lab (as lut16 has it) of inks already grown by the dot gain.
  let v = printedLinear(c, m, y, k, 0)
  let lab = xyzToLabD50([toXyz[0] * v[0] + toXyz[1] * v[1] + toXyz[2] * v[2],
                         toXyz[3] * v[0] + toXyz[4] * v[1] + toXyz[5] * v[2],
                         toXyz[6] * v[0] + toXyz[7] * v[1] + toXyz[8] * v[2]])
  lut16Lab(lab[0], lab[1], lab[2])

proc modelInk(lab: array[3, float]; toRgb: array[9, float]; inks: ptr UncheckedArray[uint32]): array[4, float] =
  ## The inks for a Lab color (as lut16 has it): those of the nearest sRGB
  ## color, read between the table of inks as `inkOf` reads it.
  # (out of sRGB's colors: each channel kept to 0..1 -- of the ways tried,
  # the one nearest to `inkOf` once read between)
  let L = labOfLut16(lab)
  let xyz = labToXyzD50(L[0], L[1], L[2])
  var p: array[3, float]
  for ch in 0 .. 2:
    let t = toRgb[ch * 3] * xyz[0] + toRgb[ch * 3 + 1] * xyz[1] + toRgb[ch * 3 + 2] * xyz[2]
    p[ch] = encodeSrgb(clamp(t, 0.0, 1.0)) * float(N - 1)
  var i0: array[3, int]
  var f: array[3, float]
  for ch in 0 .. 2:
    i0[ch] = min(int(p[ch]), N - 2)
    f[ch] = p[ch] - i0[ch].float
  for corner in 0 .. 7:
    var w = 1.0
    var idx = 0
    for ch in 0 .. 2:
      let bit = (corner shr (2 - ch)) and 1
      w *= (if bit == 1: f[ch] else: 1 - f[ch])
      idx = idx * N + i0[ch] + bit
    if w == 0: continue
    let v = inks[idx]
    result[0] += float(v shr 24) / 255 * w
    result[1] += float((v shr 16) and 255) / 255 * w
    result[2] += float((v shr 8) and 255) / 255 * w
    result[3] += float(v and 255) / 255 * w
  for ch in 0 .. 3: result[ch] = clamp(result[ch], 0.0, 1.0)

proc modelInkTable(s: InkSetup): seq[uint32] =
  ## The built-in model's table of inks (as `inkOf` has it) for setup `s`.
  result = newSeq[uint32](N * N * N)
  let inks = cast[ptr UncheckedArray[uint32]](addr result[0])
  parallelFor(N, proc (lo, hi: int) =
    for ri in lo ..< hi:
      for gi in 0 ..< N:
        for bi in 0 ..< N:
          let r = (ri * 255 + (N - 1) div 2) div (N - 1)
          let g = (gi * 255 + (N - 1) div 2) div (N - 1)
          let b = (bi * 255 + (N - 1) div 2) div (N - 1)
          let x = solveInk([toLinear[r].float, toLinear[g].float, toLinear[b].float], [r / 255, g / 255, b / 255], s)
          inks[(ri * N + gi) * N + bi] = (uint32(round(x[0] * 255)) shl 24) or (uint32(round(x[1] * 255)) shl 16) or
                                         (uint32(round(x[2] * 255)) shl 8) or uint32(round(x[3] * 255))
  , keepAlive = false)

proc modelProfile(s: InkSetup; name: string; gridIn, gridOut: int; shape: float): string =
  ## (`inkModelProfile`: `gridIn` points a side for CMYK to Lab, `gridOut`
  ## for Lab to CMYK, the CMYK points `shape` closer where the ink is heavy)
  let srgb = srgbProfile()
  let toXyz = srgb.toXyz
  # CMYK to Lab: the dot gain in the curves, the inks' mix in the grid (its
  # points closer together where there is much ink: darker, faster changing)
  var curves = newSeq[seq[float]](4)
  for ch in 0 .. 3:
    for j in 0 .. 255: curves[ch].add 1 - pow(1 - gained(j / 255, s.dotGain), 1 / shape)
  var at = newSeq[float](gridIn)
  for j in 0 ..< gridIn: at[j] = 1 - pow(1 - j / (gridIn - 1), shape)
  var a2b = newSeq[float](gridIn * gridIn * gridIn * gridIn * 3)
  var i = 0
  for ci in 0 ..< gridIn:
    for mi in 0 ..< gridIn:
      for yi in 0 ..< gridIn:
        for ki in 0 ..< gridIn:
          let lab = modelLab(at[ci], at[mi], at[yi], at[ki], toXyz)
          for v in lab:
            a2b[i] = v
            inc i
  # Lab to CMYK: the inks of the nearest sRGB color, as `inkOf` has them
  var toRgb: array[9, float]
  block:
    let (a, b, c, d, e, f, g, h, k) = (toXyz[0], toXyz[1], toXyz[2], toXyz[3], toXyz[4], toXyz[5], toXyz[6],
                                       toXyz[7], toXyz[8])
    let det = a * (e * k - f * h) - b * (d * k - f * g) + c * (d * h - e * g)
    toRgb = [(e * k - f * h) / det, (c * h - b * k) / det, (b * f - c * e) / det,
             (f * g - d * k) / det, (a * k - c * g) / det, (c * d - a * f) / det,
             (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]
  # (the model's table of inks: the one in use when it is for `s`)
  var table: seq[uint32]
  if inkIcc.len == 0 and s == inkSetup:
    ensureTables()
    table = inkTable
  else:
    table = modelInkTable(s)
  let inks = cast[ptr UncheckedArray[uint32]](addr table[0])
  var b2a = newSeq[float](gridOut * gridOut * gridOut * 4)
  for li in 0 ..< gridOut:
    for ai in 0 ..< gridOut:
      for bi in 0 ..< gridOut:
        let x = modelInk([li / (gridOut - 1), ai / (gridOut - 1), bi / (gridOut - 1)], toRgb, inks)
        let o = ((li * gridOut + ai) * gridOut + bi) * 4
        for ch in 0 .. 3: b2a[o + ch] = x[ch]
  let toLab = lut16Tag(4, 3, gridIn, a2b, curves)
  let toInk = lut16Tag(3, 4, gridOut, b2a)
  profileBytes("prtr", "CMYK", "Lab ", [
    ("desc", descTag(name)),
    ("cprt", textTag("No copyright, use freely")),
    ("wtpt", xyzTag([0.9642, 1.0, 0.8249])),
    ("A2B0", toLab), ("A2B1", toLab), ("A2B2", toLab),
    ("B2A0", toInk), ("B2A1", toInk), ("B2A2", toInk)])

proc inkModelProfile*(s: InkSetup; name = "Retro Photo Ink Model"): string =
  ## The built-in ink model with setup `s` as a printer profile (ICC version
  ## 2, class prtr: CMYK, PCS Lab, white paper; A2B0..2 and B2A0..2 as lut16,
  ## the same table for every intent; desc, cprt, wtpt), for a PDF/X output
  ## intent when no press profile is set. Some 210 KB; made in some 10 ms
  ## (more the first time, or for another setup than the one in use).
  modelProfile(s, name, 11, 25, 2.0)

# ---- Lab --------------------------------------------------------------------------------------------------

proc labOf*(p: uint32): (float, float, float) =
  ## CIE Lab (D50) of a color: L 0..100, a and b about -128..127.
  let r = toLinear[(p shr 16) and 255].float
  let g = toLinear[(p shr 8) and 255].float
  let b = toLinear[p and 255].float
  # sRGB to XYZ (D50, Bradford)
  let x = 0.4360747 * r + 0.3850649 * g + 0.1430804 * b
  let y = 0.2225045 * r + 0.7168786 * g + 0.0606169 * b
  let z = 0.0139322 * r + 0.0971045 * g + 0.7141733 * b
  proc f(t: float): float = (if t > 0.008856: cbrt(t) else: 7.787 * t + 16 / 116)
  let fx = f(x / 0.96422)
  let fy = f(y)
  let fz = f(z / 0.82521)
  (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))

proc fromLab*(L, a, b: float; alpha = 255): uint32 =
  ## The color of a Lab value (out of the screen's colors: the nearest).
  let fy = (L + 16) / 116
  let fx = fy + a / 500
  let fz = fy - b / 200
  proc fi(t: float): float = (if t * t * t > 0.008856: t * t * t else: (t - 16 / 116) / 7.787)
  let x = fi(fx) * 0.96422
  let y = fi(fy)
  let z = fi(fz) * 0.82521
  let r = 3.1338561 * x - 1.6168667 * y - 0.4906146 * z
  let g = -0.9787684 * x + 1.9161415 * y + 0.0334540 * z
  let bb = 0.0719453 * x - 0.2289914 * y + 1.4052427 * z
  (uint32(alpha) shl 24) or (uint32(fromLinear(r)) shl 16) or (uint32(fromLinear(g)) shl 8) or
    uint32(fromLinear(bb))

proc labBytes*(p: uint32): array[3, int] =
  ## Lab as the bytes of its channels: L 0..255, a and b 0..255 (128 none).
  let (L, a, b) = labOf(p)
  [clamp(int(round(L * 2.55)), 0, 255), clamp(int(round(a)) + 128, 0, 255), clamp(int(round(b)) + 128, 0, 255)]

proc fromLabBytes*(v: array[3, int]; alpha = 255): uint32 =
  ## The color of Lab channel bytes (as `labBytes` gives them).
  fromLab(v[0].float / 2.55, float(v[1] - 128), float(v[2] - 128), alpha)

# ---- duotones ---------------------------------------------------------------------------------------------

proc defaultDuotone*(n: int): seq[DuotoneInk] =
  ## Inks to start with: black, then a warm brown, a blue gray, a gold.
  let all = [DuotoneInk(name: "Black", color: 0xFF231F20'u32, gamma: 1.0),
             DuotoneInk(name: "PANTONE 478", color: 0xFF8C4A3C'u32, gamma: 1.6),
             DuotoneInk(name: "PANTONE 549", color: 0xFF6FA1B4'u32, gamma: 2.2),
             DuotoneInk(name: "PANTONE 871", color: 0xFFB59A57'u32, gamma: 2.6)]
  for i in 0 ..< clamp(n, 1, 4): result.add all[i]

proc duotoneTable*(inks: openArray[DuotoneInk]): array[256, uint32] =
  ## What each gray (0 black .. 255 white) looks like printed in the inks.
  for g in 0 .. 255:
    let t0 = 1 - g / 255                          # how dark: how much ink
    var v = [1.0, 1.0, 1.0]
    for ink in inks:
      let t = pow(t0, max(0.05, ink.gamma))
      let c = [toLinear[(ink.color shr 16) and 255].float, toLinear[(ink.color shr 8) and 255].float,
               toLinear[ink.color and 255].float]
      for ch in 0 .. 2: v[ch] *= 1 - t * (1 - c[ch])
    result[g] = 0xFF000000'u32 or (uint32(fromLinear(v[0])) shl 16) or (uint32(fromLinear(v[1])) shl 8) or
                uint32(fromLinear(v[2]))

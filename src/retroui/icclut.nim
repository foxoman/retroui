## Profiles at work with their color tables: colors converted between any
## two profiles -- RGB, CMYK, gray or Lab; of the matrix-and-curves kind or
## with tables (lut8, lut16, lutAtoB, lutBtoA, as `parseIcc` reads them) --
## with the four rendering intents and black point compensation, worked out
## the way littlecms 2.19 works them out (its steps, its black points; the
## tests compare); grids of a conversion for whole pictures; and profiles
## with tables written (`lut16Tag`, `profileBytes`), for a printer's inks.
## Not read: the floating point tables (D2Bx, B2Dx, which littlecms prefers
## when a profile has them), device links, named colors. Use it for
## printing and proofing (CMYK, soft proofs); `retroui/iccprofile` alone
## converts between the RGB profiles of photos.
##
## ```nim
## let press = parseIcc(readFile("press.icc"))         # a printer's CMYK profile
## let toInks = newTransform(srgbProfile(), press, riRelative, bpc = true)
## echo toInks.rgbToCmyk(0xFF3366CC'u32)               # C, M, Y, K: 0..255
## let shown = newTransform(press, srgbProfile(), riRelative)
## echo shown.cmykToRgb(0, 255, 255, 0).toHex          # how red ink prints
## let grid = rgbToCmykGrid(srgbProfile(), press, riRelative, true, 33)
## ```

import std/math
import iccprofile, parallel

type
  RenderingIntent* = enum
    ## What becomes of colors one profile has and the other has not.
    riPerceptual = "Perceptual"            ## all squeezed in, the way the profile's maker chose
    riRelative = "Relative Colorimetric"   ## kept, white to white; the others to the nearest
    riSaturation = "Saturation"            ## vivid (charts)
    riAbsolute = "Absolute Colorimetric"   ## kept, with the paper's own white

const
  d50 = [0.9642, 1.0, 0.8249]
  maxXyz = 1.0 + 32767.0 / 32768.0      # (XYZ written 0..1 in tables and conversions: up to this)
  v2ToV4 = 65535.0 / 65280.0            # (Lab of lut16 tables, the version 2 way, to version 4's)
  perceptualBlack = [0.00336, 0.0034731, 0.00287]
  maxCh = 8
  zero3 = [0.0, 0.0, 0.0]
  identity9 = [1.0, 0, 0, 0, 1, 0, 0, 0, 1]

type
  OpKind = enum
    opCurves, opInvCurves, opMatrix, opGrid, opLabToXyz, opXyzToLab, opScale

  Op = object
    kind: OpKind
    n, m: int                           # channels in, out
    curves: seq[IccCurve]
    inv: seq[seq[float]]                # (turned round) a table's: 4096 values; empty: by formula
    mat: seq[float]                     # m x n, row by row, then m offsets
    grid, stride: array[maxCh, int]
    tri: bool                           # (3 inputs) trilinear, not tetrahedral
    table: seq[float32]
    k: float

  IccTransform* = object
    ## A conversion of colors from one profile to another (`newTransform`).
    inputs*, outputs*: int              ## channels in and out: 3 RGB and Lab, 4 CMYK, 1 gray
    ok*: bool                           ## made (false: a profile cannot be used so)
    ops: seq[Op]

# ---- Lab and XYZ ----------------------------------------------------------------------------------------------

proc fLab(t: float): float {.inline.} =
  const lim = (24.0 / 116.0) * (24.0 / 116.0) * (24.0 / 116.0)
  if t <= lim: 841.0 / 108.0 * t + 16.0 / 116.0 else: cbrt(t)

proc fLabInv(t: float): float {.inline.} =
  if t <= 24.0 / 116.0: 108.0 / 841.0 * (t - 16.0 / 116.0) else: t * t * t

proc xyzToLabD50*(xyz: array[3, float]): array[3, float] =
  ## CIE Lab of an XYZ color (white D50, Y 0..1): L 0..100, a and b.
  let fx = fLab(xyz[0] / d50[0])
  let fy = fLab(xyz[1] / d50[1])
  let fz = fLab(xyz[2] / d50[2])
  [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)]

proc labToXyzD50*(L, a, b: float): array[3, float] =
  ## XYZ (white D50) of a CIE Lab color.
  let y = (L + 16) / 116
  [fLabInv(y + 0.002 * a) * d50[0], fLabInv(y) * d50[1], fLabInv(y - 0.005 * b) * d50[2]]

proc lut16Lab*(L, a, b: float): array[3, float] =
  ## Lab as a lut16 table has it (the version 2 way), each 0..1.
  [L * 652.80 / 65535, (a + 128) * 256 / 65535, (b + 128) * 256 / 65535]

proc labOfLut16*(v: array[3, float]): array[3, float] =
  ## Lab (L, a, b) of the values in a lut16 table (`lut16Lab` turned round).
  [v[0] * 65535 / 652.80, v[1] * 65535 / 256 - 128, v[2] * 65535 / 256 - 128]

# ---- steps --------------------------------------------------------------------------------------------------

proc clamp01(v: float): float {.inline.} =
  if v > 0.0: (if v < 1.0: v else: 1.0) else: 0.0

proc sat16(d: float): float {.inline.} =
  ## 0..65535 rounded and kept in (littlecms' _cmsQuickSaturateWord).
  let d = d + 0.5
  if d <= 0: 0.0 elif d >= 65535: 65535.0 else: floor(d)

proc curveValue(c: IccCurve; x: float): float =
  ## A curve's value; formulas as littlecms has them (not kept to 0..1:
  ## the steps after do that).
  if c.kind == 1: return c.eval(clamp01(x))
  if c.kind == 0:
    if x < 0: return (if abs(c.gamma - 1) < 1e-4: x else: 0.0)
    return pow(x, c.gamma)
  let p = c.params
  template P(i: int): float = (if i < p.len: p[i] else: 0.0)
  let g = P(0)
  case c.fn
  of 0:
    if x < 0: (if abs(g - 1) < 1e-4: x else: 0.0) else: pow(x, g)
  of 1:
    if abs(P(1)) < 1e-4: return 0.0
    if x >= -P(2) / P(1):
      let e = P(1) * x + P(2)
      if e > 0: pow(e, g) else: 0.0
    else: 0.0
  of 2:
    if abs(P(1)) < 1e-4: return 0.0
    if x >= max(0.0, -P(2) / P(1)):
      let e = P(1) * x + P(2)
      if e > 0: pow(e, g) + P(3) else: 0.0
    else: P(3)
  of 3:
    if x >= P(4):
      let e = P(1) * x + P(2)
      if e > 0: pow(e, g) else: 0.0
    else: x * P(3)
  else:
    if x >= P(4):
      let e = P(1) * x + P(2)
      if e > 0: pow(e, g) + P(5) else: P(5)
    else: x * P(3) + P(6)

proc reversedTable(c: IccCurve): seq[float] =
  ## A table curve turned round, as littlecms turns it (4096 values, 0..1).
  let n = c.table.len
  var t = newSeq[float](n)
  for i in 0 ..< n: t[i] = round(clamp01(c.table[i]) * 65535)
  let ascending = not (t[0] > t[n - 1])
  result = newSeq[float](4096)
  var a, b = 0.0
  for i in 0 ..< 4096:
    let y = i.float * 65535 / 4095
    # (the piece of the table y is in: from the top when it rises)
    var j = -1
    if t[0] < t[n - 1]:
      for q in countdown(n - 2, 0):
        if (t[q] <= t[q + 1] and y >= t[q] and y <= t[q + 1]) or
           (t[q + 1] < t[q] and y >= t[q + 1] and y <= t[q]):
          j = q
          break
    else:
      for q in 0 .. n - 2:
        if (t[q] <= t[q + 1] and y >= t[q] and y <= t[q + 1]) or
           (t[q + 1] < t[q] and y >= t[q + 1] and y <= t[q]):
          j = q
          break
    if j >= 0:
      let x1 = t[j]
      let x2 = t[j + 1]
      let y1 = j.float * 65535 / float(n - 1)
      let y2 = (j + 1).float * 65535 / float(n - 1)
      if x1 == x2:
        result[i] = sat16(if ascending: y2 else: y1) / 65535
        continue
      a = (y2 - y1) / (x2 - x1)
      b = y2 - a * x2
    result[i] = sat16(a * y + b) / 65535

proc invValue(c: IccCurve; tab: seq[float]; y: float): float =
  ## The value a curve takes to `y` (the inverse formulas littlecms has).
  let y = clamp01(y)
  if tab.len >= 2:
    let f = y * float(tab.len - 1)
    let i = min(tab.len - 2, int(f))
    return tab[i] + (tab[i + 1] - tab[i]) * (f - i.float)
  case c.kind
  of 0:
    result = if abs(c.gamma) < 1e-4: 0.0 else: pow(y, 1 / c.gamma)
  of 1:
    result = y
  else:
    let p = c.params
    template P(i: int): float = (if i < p.len: p[i] else: 0.0)
    let g = P(0)
    let flat = abs(g) < 1e-4 or abs(P(1)) < 1e-4
    case c.fn
    of 0:
      result = if abs(g) < 1e-4: 0.0 else: pow(y, 1 / g)
    of 1:
      result = if flat: 0.0 else: max(0.0, (pow(y, 1 / g) - P(2)) / P(1))
    of 2:
      result = if flat: 0.0
               elif y >= P(3): (if y - P(3) > 0: (pow(y - P(3), 1 / g) - P(2)) / P(1) else: 0.0)
               else: -P(2) / P(1)
    of 3:
      let e = P(1) * P(4) + P(2)
      let disc = if e < 0: 0.0 else: pow(e, g)
      result = if y >= disc: (if flat: 0.0 else: (pow(y, 1 / g) - P(2)) / P(1))
               elif abs(P(3)) < 1e-4: 0.0
               else: y / P(3)
    else:
      let disc = P(3) * P(4) + P(6)
      result = if y >= disc: (if y - P(5) < 0 or flat: 0.0 else: (pow(y - P(5), 1 / g) - P(2)) / P(1))
               elif abs(P(3)) < 1e-4: 0.0
               else: (y - P(6)) / P(3)
  result = clamp01(result)

{.push boundChecks: off, overflowChecks: off.}

proc tetra(op: Op; v: array[maxCh, float]; d, base: int; o: var array[maxCh, float]) =
  ## Three inputs (dimensions d, d+1, d+2) read between: tetrahedral, or
  ## trilinear when `op.tri`.
  let t = cast[ptr UncheckedArray[float32]](unsafeAddr op.table[0])
  let px = v[d] * float(op.grid[d] - 1)
  let py = v[d + 1] * float(op.grid[d + 1] - 1)
  let pz = v[d + 2] * float(op.grid[d + 2] - 1)
  let x0 = int(px)
  let y0 = int(py)
  let z0 = int(pz)
  let rx = px - x0.float
  let ry = py - y0.float
  let rz = pz - z0.float
  let X0 = base + x0 * op.stride[d]
  let X1 = X0 + (if v[d] >= 1.0: 0 else: op.stride[d])
  let Y0 = y0 * op.stride[d + 1]
  let Y1 = Y0 + (if v[d + 1] >= 1.0: 0 else: op.stride[d + 1])
  let Z0 = z0 * op.stride[d + 2]
  let Z1 = Z0 + (if v[d + 2] >= 1.0: 0 else: op.stride[d + 2])
  for oc in 0 ..< op.m:
    template D(a, b, c: int): float = float(t[a + b + c + oc])
    if op.tri:
      let dx00 = D(X0, Y0, Z0) + (D(X1, Y0, Z0) - D(X0, Y0, Z0)) * rx
      let dx01 = D(X0, Y0, Z1) + (D(X1, Y0, Z1) - D(X0, Y0, Z1)) * rx
      let dx10 = D(X0, Y1, Z0) + (D(X1, Y1, Z0) - D(X0, Y1, Z0)) * rx
      let dx11 = D(X0, Y1, Z1) + (D(X1, Y1, Z1) - D(X0, Y1, Z1)) * rx
      let dxy0 = dx00 + (dx10 - dx00) * ry
      let dxy1 = dx01 + (dx11 - dx01) * ry
      o[oc] = dxy0 + (dxy1 - dxy0) * rz
      continue
    let c0 = D(X0, Y0, Z0)
    var c1, c2, c3: float
    if rx >= ry and ry >= rz:
      c1 = D(X1, Y0, Z0) - c0
      c2 = D(X1, Y1, Z0) - D(X1, Y0, Z0)
      c3 = D(X1, Y1, Z1) - D(X1, Y1, Z0)
    elif rx >= rz and rz >= ry:
      c1 = D(X1, Y0, Z0) - c0
      c2 = D(X1, Y1, Z1) - D(X1, Y0, Z1)
      c3 = D(X1, Y0, Z1) - D(X1, Y0, Z0)
    elif rz >= rx and rx >= ry:
      c1 = D(X1, Y0, Z1) - D(X0, Y0, Z1)
      c2 = D(X1, Y1, Z1) - D(X1, Y0, Z1)
      c3 = D(X0, Y0, Z1) - c0
    elif ry >= rx and rx >= rz:
      c1 = D(X1, Y1, Z0) - D(X0, Y1, Z0)
      c2 = D(X0, Y1, Z0) - c0
      c3 = D(X1, Y1, Z1) - D(X1, Y1, Z0)
    elif ry >= rz and rz >= rx:
      c1 = D(X1, Y1, Z1) - D(X0, Y1, Z1)
      c2 = D(X0, Y1, Z0) - c0
      c3 = D(X0, Y1, Z1) - D(X0, Y1, Z0)
    elif rz >= ry and ry >= rx:
      c1 = D(X1, Y1, Z1) - D(X0, Y1, Z1)
      c2 = D(X0, Y1, Z1) - D(X0, Y0, Z1)
      c3 = D(X0, Y0, Z1) - c0
    o[oc] = c0 + c1 * rx + c2 * ry + c3 * rz

proc gridAt(op: Op; v: array[maxCh, float]; d, base: int; o: var array[maxCh, float]) =
  ## The grid read between at `v` (inputs from dimension `d` on), as
  ## littlecms reads it: one or two inputs (bi)linear, three tetrahedral,
  ## more linear along the first between the rest.
  let t = cast[ptr UncheckedArray[float32]](unsafeAddr op.table[0])
  case op.n - d
  of 1:
    let px = v[d] * float(op.grid[d] - 1)
    let x0 = int(px)
    let rx = px - x0.float
    let X0 = base + x0 * op.stride[d]
    let X1 = X0 + (if v[d] >= 1.0: 0 else: op.stride[d])
    for oc in 0 ..< op.m:
      o[oc] = float(t[X0 + oc]) + (float(t[X1 + oc]) - float(t[X0 + oc])) * rx
  of 2:
    let px = v[d] * float(op.grid[d] - 1)
    let py = v[d + 1] * float(op.grid[d + 1] - 1)
    let x0 = int(px)
    let y0 = int(py)
    let fx = px - x0.float
    let fy = py - y0.float
    let X0 = base + x0 * op.stride[d]
    let X1 = X0 + (if v[d] >= 1.0: 0 else: op.stride[d])
    let Y0 = y0 * op.stride[d + 1]
    let Y1 = Y0 + (if v[d + 1] >= 1.0: 0 else: op.stride[d + 1])
    for oc in 0 ..< op.m:
      let d00 = float(t[X0 + Y0 + oc])
      let d01 = float(t[X0 + Y1 + oc])
      let d10 = float(t[X1 + Y0 + oc])
      let d11 = float(t[X1 + Y1 + oc])
      let dx0 = d00 + (d10 - d00) * fx
      let dx1 = d01 + (d11 - d01) * fx
      o[oc] = dx0 + (dx1 - dx0) * fy
  of 3:
    tetra(op, v, d, base, o)
  else:
    let pk = v[d] * float(op.grid[d] - 1)
    let k0 = int(pk)
    let rest = pk - k0.float
    let K0 = base + k0 * op.stride[d]
    let K1 = K0 + (if v[d] >= 1.0: 0 else: op.stride[d])
    var a, b: array[maxCh, float]
    gridAt(op, v, d + 1, K0, a)
    gridAt(op, v, d + 1, K1, b)
    for oc in 0 ..< op.m: o[oc] = a[oc] + (b[oc] - a[oc]) * rest

{.pop.}

proc run(ops: seq[Op]; v: var array[maxCh, float]) =
  ## The steps, one after the other, on the values `v`.
  var o: array[maxCh, float]
  for op in ops:
    case op.kind
    of opCurves:
      for i in 0 ..< op.n: v[i] = curveValue(op.curves[i], v[i])
    of opInvCurves:
      for i in 0 ..< op.n: v[i] = invValue(op.curves[i], op.inv[i], v[i])
    of opMatrix:
      let n = op.n
      for r in 0 ..< op.m:
        var s = op.mat[op.m * n + r]
        for c in 0 ..< n: s += op.mat[r * n + c] * v[c]
        o[r] = s
      for r in 0 ..< op.m: v[r] = o[r]
    of opGrid:
      for i in 0 ..< op.n:
        v[i] = if v[i] < 1e-9 or v[i] != v[i]: 0.0 elif v[i] > 1.0: 1.0 else: v[i]
      gridAt(op, v, 0, 0, o)
      for r in 0 ..< op.m: v[r] = o[r]
    of opLabToXyz:
      let xyz = labToXyzD50(v[0] * 100, v[1] * 255 - 128, v[2] * 255 - 128)
      for i in 0 .. 2: v[i] = xyz[i] / maxXyz
    of opXyzToLab:
      let lab = xyzToLabD50([v[0] * maxXyz, v[1] * maxXyz, v[2] * maxXyz])
      v[0] = lab[0] / 100
      v[1] = (lab[1] + 128) / 255
      v[2] = (lab[2] + 128) / 255
    of opScale:
      for i in 0 .. 2: v[i] *= op.k

# ---- a profile's steps ------------------------------------------------------------------------------------------

proc channelsOf(space: string): int =
  case space
  of "GRAY": 1
  of "RGB ", "Lab ", "CMY ": 3
  of "CMYK": 4
  else: 0

proc scaleOp(k: float): Op = Op(kind: opScale, n: 3, m: 3, k: k)

proc matrixOp(m: openArray[float]; rows, cols: int; off: openArray[float] = []): Op =
  result = Op(kind: opMatrix, n: cols, m: rows, mat: newSeq[float](rows * cols + rows))
  for i in 0 ..< rows * cols: result.mat[i] = m[i]
  for i in 0 ..< min(rows, off.len): result.mat[rows * cols + i] = off[i]

proc inv3(m: array[9, float]): array[9, float] =
  let (a, b, c, d, e, f, g, h, i) = (m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8])
  let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
  if abs(det) < 1e-15: return identity9
  let k = 1 / det
  [(e * i - f * h) * k, (c * h - b * i) * k, (b * f - c * e) * k,
   (f * g - d * i) * k, (a * i - c * g) * k, (c * d - a * f) * k,
   (d * h - e * g) * k, (b * g - a * h) * k, (a * e - b * d) * k]

proc addLut(ops: var seq[Op]; lut: IccLut; tri: bool) =
  for st in lut.stages:
    case st.kind
    of iccCurves:
      ops.add Op(kind: opCurves, n: st.curves.len, m: st.curves.len, curves: st.curves)
    of iccMatrix:
      ops.add matrixOp(st.matrix, st.rows, st.cols, st.matrix[st.rows * st.cols .. ^1])
    of iccGrid:
      var op = Op(kind: opGrid, n: st.grid.len, m: st.outputs, table: st.table, tri: tri)
      for i in 0 ..< op.n: op.grid[i] = st.grid[i]
      op.stride[op.n - 1] = st.outputs
      for i in countdown(op.n - 2, 0): op.stride[i] = op.stride[i + 1] * op.grid[i + 1]
      ops.add op

proc lutIndex(luts: array[3, IccLut]; intent: RenderingIntent): int =
  ## The table for an intent (A2B1 for absolute colorimetric), or the
  ## perceptual one when there is none for it (-1: none at all).
  let i = [0, 1, 2, 1][ord(intent)]
  if luts[i].kind.len > 0: i elif luts[0].kind.len > 0: 0 else: -1

proc isMatrixShaper(p: IccProfile): bool = p.usable and p.colorSpace in ["RGB ", "GRAY"]

proc hasTable(p: IccProfile; intent: RenderingIntent; asInput: bool): bool =
  let i = [0, 1, 2, 1][ord(intent)]
  (if asInput: p.a2b[i].kind else: p.b2a[i].kind).len > 0

proc supports(p: IccProfile; intent: RenderingIntent; asInput: bool): bool =
  p.hasTable(intent, asInput) or p.isMatrixShaper

proc inputOps(p: IccProfile; intent: RenderingIntent; ops: var seq[Op]): bool =
  ## The steps from the profile's colors to its PCS (0..1 each; Lab the
  ## version 4 way), as littlecms takes them.
  let nCh = channelsOf(p.colorSpace)
  if nCh == 0 or p.pcs notin ["XYZ ", "Lab "]: return false
  let i = lutIndex(p.a2b, intent)
  if i >= 0:
    if p.a2b[i].inputs != nCh or p.a2b[i].outputs != 3: return false
    let legacy = p.a2b[i].kind == "mft2" and p.pcs == "Lab "
    if legacy and p.colorSpace == "Lab ": ops.add scaleOp(1 / v2ToV4)
    ops.addLut(p.a2b[i], false)
    if legacy: ops.add scaleOp(v2ToV4)
    return true
  if p.colorSpace == "GRAY" and p.usable:
    if p.pcs == "Lab ":
      let mid = 32896.0 / 65535
      ops.add matrixOp([1.0, 1, 1], 3, 1)
      ops.add Op(kind: opCurves, n: 3, m: 3,
                 curves: @[p.trc[0], IccCurve(kind: 1, table: @[mid, mid]), IccCurve(kind: 1, table: @[mid, mid])])
    else:
      ops.add Op(kind: opCurves, n: 1, m: 1, curves: @[p.trc[0]])
      ops.add matrixOp([d50[0] / maxXyz, d50[1] / maxXyz, d50[2] / maxXyz], 3, 1)
    return true
  if p.colorSpace == "RGB " and p.usable:
    ops.add Op(kind: opCurves, n: 3, m: 3, curves: @[p.trc[0], p.trc[1], p.trc[2]])
    var m: array[9, float]
    for k in 0 .. 8: m[k] = p.toXyz[k] / maxXyz
    ops.add matrixOp(m, 3, 3)
    if p.pcs == "Lab ": ops.add Op(kind: opXyzToLab, n: 3, m: 3)
    return true
  false

proc invCurvesOp(cs: seq[IccCurve]): Op =
  result = Op(kind: opInvCurves, n: cs.len, m: cs.len, curves: cs)
  for c in cs:
    result.inv.add(if c.kind == 1 and c.table.len >= 2: reversedTable(c) else: @[])

proc outputOps(p: IccProfile; intent: RenderingIntent; ops: var seq[Op]): bool =
  ## The steps from the profile's PCS to its colors.
  let nCh = channelsOf(p.colorSpace)
  if nCh == 0 or p.pcs notin ["XYZ ", "Lab "]: return false
  let i = lutIndex(p.b2a, intent)
  if i >= 0:
    if p.b2a[i].inputs != 3 or p.b2a[i].outputs != nCh: return false
    let legacy = p.b2a[i].kind == "mft2" and p.pcs == "Lab "
    if legacy: ops.add scaleOp(1 / v2ToV4)
    # (from Lab, littlecms reads the grid trilinear)
    ops.addLut(p.b2a[i], p.pcs == "Lab ")
    if legacy and p.colorSpace == "Lab ": ops.add scaleOp(v2ToV4)
    return true
  if p.colorSpace == "GRAY" and p.usable:
    if p.pcs == "Lab ": ops.add matrixOp([1.0, 0, 0], 1, 3)
    else: ops.add matrixOp([0.0, maxXyz * d50[1], 0], 1, 3)
    ops.add invCurvesOp(@[p.trc[0]])
    return true
  if p.colorSpace == "RGB " and p.usable:
    if p.pcs == "Lab ": ops.add Op(kind: opLabToXyz, n: 3, m: 3)
    var m = inv3(p.toXyz)
    for k in 0 .. 8: m[k] *= maxXyz
    ops.add matrixOp(m, 3, 3)
    ops.add invCurvesOp(@[p.trc[0], p.trc[1], p.trc[2]])
    return true
  false

proc addConversion(ops: var seq[Op]; inPcs, outPcs: string; m: array[9, float]; off: array[3, float]) =
  ## From one PCS to the other, through the matrix and offset (XYZ).
  var diff = 0.0
  for k in 0 .. 8: diff += abs(m[k] - identity9[k])
  for k in 0 .. 2: diff += abs(off[k])
  let empty = diff < 0.002
  if inPcs == "XYZ ":
    if not empty: ops.add matrixOp(m, 3, 3, off)
    if outPcs == "Lab ": ops.add Op(kind: opXyzToLab, n: 3, m: 3)
  elif outPcs == "XYZ ":
    ops.add Op(kind: opLabToXyz, n: 3, m: 3)
    if not empty: ops.add matrixOp(m, 3, 3, off)
  elif not empty:
    ops.add Op(kind: opLabToXyz, n: 3, m: 3)
    ops.add matrixOp(m, 3, 3, off)
    ops.add Op(kind: opXyzToLab, n: 3, m: 3)

# ---- black points ----------------------------------------------------------------------------------------------

proc labNorm(lab: array[3, float]): array[maxCh, float] =
  result[0] = lab[0] / 100
  result[1] = (lab[1] + 128) / 255
  result[2] = (lab[2] + 128) / 255

proc detectDestinationBlackPoint*(p: IccProfile; intent: RenderingIntent): (bool, array[3, float])
  ## The black point of a profile colors are converted to (XYZ): for
  ## printers with tables, from a round trip of grays and a curve fitted to
  ## it, as littlecms does (Adobe's way, cmsDetectDestinationBlackPoint).
  ## False (and black) when the profile or `intent` has none to compensate
  ## (device links, absolute colorimetric).

proc bpcMatrix(bin, bout: array[3, float]; m: var array[9, float]; off: var array[3, float]) =
  ## Black point compensation: m * bin + off = bout, m * D50 + off = D50
  ## (the offset as a conversion has it).
  if bin == bout: return
  for k in 0 .. 2:
    let t = bin[k] - d50[k]
    m[k * 4] = (bout[k] - d50[k]) / t
    off[k] = -d50[k] * (bout[k] - bin[k]) / t / maxXyz

proc roundTrip(p: IccProfile; intent: RenderingIntent; ops: var seq[Op]): bool =
  ## Lab to the profile's colors (`intent`) and back (colorimetric). (Into
  ## a version 4 profile perceptual and saturation take black point
  ## compensation, from Lab's black: littlecms does so here too.)
  var m = identity9
  var off = zero3
  if intent in {riPerceptual, riSaturation} and p.version >= 0x04000000:
    bpcMatrix(zero3, detectDestinationBlackPoint(p, intent)[1], m, off)
  ops.addConversion("Lab ", p.pcs, m, off)
  if not outputOps(p, intent, ops): return false
  if not inputOps(p, riRelative, ops): return false
  ops.addConversion(p.pcs, "Lab ", identity9, zero3)
  true

proc darkerColorant(p: IccProfile; intent: RenderingIntent): (bool, array[3, float]) =
  ## The black point as the profile's darkest colorant shows it.
  if not p.supports(intent, true): return (false, zero3)
  var v: array[maxCh, float]
  case p.colorSpace
  of "RGB ", "GRAY": discard
  of "CMYK":
    for i in 0 .. 3: v[i] = 1.0
  of "CMY ":
    for i in 0 .. 2: v[i] = 1.0
  of "Lab ":
    v[1] = 32896.0 / 65535
    v[2] = 32896.0 / 65535
  else: return (false, zero3)
  var ops: seq[Op]
  if not inputOps(p, intent, ops): return (false, zero3)
  ops.addConversion(p.pcs, "Lab ", identity9, zero3)
  run(ops, v)
  # (littlecms 2.19 keeps its a and b; later versions make it gray)
  var L = v[0] * 100
  if L > 95 or L < 0: L = 0 elif L > 50: L = 50
  (true, labToXyzD50(L, v[1] * 255 - 128, v[2] * 255 - 128))

proc blackThroughPerceptual(p: IccProfile): (bool, array[3, float]) =
  ## The black point of a CMYK printer: black Lab there (perceptual) and back.
  if not p.supports(riPerceptual, true): return (true, zero3)
  var ops: seq[Op]
  if not roundTrip(p, riPerceptual, ops): return (false, zero3)
  var v = labNorm(zero3)
  run(ops, v)
  let L = min(v[0] * 100, 50.0)
  (true, labToXyzD50(L, 0, 0))

proc detectBlackPoint*(p: IccProfile; intent: RenderingIntent): (bool, array[3, float]) =
  ## The darkest the profile's colors go (XYZ), for `intent`: worked out as
  ## littlecms does (cmsDetectBlackPoint). False (and black) when it cannot
  ## be told.
  if p.deviceClass in ["link", "abst", "nmcl"] or intent == riAbsolute: return (false, zero3)
  if p.version >= 0x04000000 and intent in {riPerceptual, riSaturation}:
    if p.isMatrixShaper: return darkerColorant(p, riRelative)
    return (true, perceptualBlack)
  if intent == riRelative and p.deviceClass == "prtr" and p.colorSpace in ["CMYK", "CMY "]:
    return blackThroughPerceptual(p)
  darkerColorant(p, intent)

proc fitQuadraticRoot(x, y: openArray[float]): float =
  ## Where the least squares parabola through the points meets 0 (littlecms').
  let n = x.len
  if n < 4: return 0
  var sx, sx2, sx3, sx4, sy, syx, syx2 = 0.0
  for i in 0 ..< n:
    let xn = x[i]
    let yn = y[i]
    sx += xn
    sx2 += xn * xn
    sx3 += xn * xn * xn
    sx4 += xn * xn * xn * xn
    sy += yn
    syx += yn * xn
    syx2 += yn * xn * xn
  let m = [n.float, sx, sx2, sx, sx2, sx3, sx2, sx3, sx4]
  let det = m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) +
            m[2] * (m[3] * m[7] - m[4] * m[6])
  if abs(det) < 0.0001: return 0
  let mi = inv3(m)
  let c = mi[0] * sy + mi[1] * syx + mi[2] * syx2
  let b = mi[3] * sy + mi[4] * syx + mi[5] * syx2
  let a = mi[6] * sy + mi[7] * syx + mi[8] * syx2
  if abs(a) < 1e-10:
    if abs(b) < 1e-10: return 0
    return max(0.0, min(50.0, -c / b))
  let d = b * b - 4 * a * c
  if d <= 0: return 0
  max(0.0, min(50.0, (-b + sqrt(d)) / (2 * a)))

proc detectDestinationBlackPoint*(p: IccProfile; intent: RenderingIntent): (bool, array[3, float]) =
  ## The black point of a profile colors are converted to (XYZ): for
  ## printers with tables, from a round trip of grays and a curve fitted to
  ## it, as littlecms does (Adobe's way, cmsDetectDestinationBlackPoint).
  if p.deviceClass in ["link", "abst", "nmcl"] or intent == riAbsolute: return (false, zero3)
  if p.version >= 0x04000000 and intent in {riPerceptual, riSaturation}:
    if p.isMatrixShaper: return darkerColorant(p, riRelative)
    return (true, perceptualBlack)
  if not p.hasTable(intent, false) or p.colorSpace notin ["GRAY", "RGB ", "CMYK", "CMY "]:
    return detectBlackPoint(p, intent)
  var initial = zero3
  if intent == riRelative:
    let (ok, xyz) = detectBlackPoint(p, intent)
    if not ok: return (false, zero3)
    initial = xyzToLabD50(xyz)
  var ops: seq[Op]
  if not roundTrip(p, intent, ops): return (false, zero3)
  var inRamp, outRamp: array[256, float]
  for l in 0 .. 255:
    let L = l.float * 100 / 255
    var v = labNorm([L, clamp(initial[1], -50.0, 50.0), clamp(initial[2], -50.0, 50.0)])
    run(ops, v)
    inRamp[l] = L
    outRamp[l] = v[0] * 100
  for l in countdown(254, 1): outRamp[l] = min(outRamp[l], outRamp[l + 1])
  if not (outRamp[0] < outRamp[255]): return (false, zero3)
  let minL = outRamp[0]
  let maxL = outRamp[255]
  if intent == riRelative:
    var straight = true
    for l in 0 .. 255:
      if not (inRamp[l] <= minL + 0.2 * (maxL - minL) or abs(inRamp[l] - outRamp[l]) < 4.0):
        straight = false
    if straight: return (true, labToXyzD50(initial[0], initial[1], initial[2]))
  let (lo, hi) = if intent == riRelative: (0.1, 0.5) else: (0.03, 0.25)
  var xs, ys: seq[float]
  for l in 0 .. 255:
    let f = (outRamp[l] - minL) / (maxL - minL)
    if f >= lo and f < hi:
      xs.add inRamp[l]
      ys.add f
  if xs.len < 3: return (false, zero3)
  let L = max(0.0, fitQuadraticRoot(xs, ys))
  (true, labToXyzD50(L, initial[1], initial[2]))

# ---- transforms ------------------------------------------------------------------------------------------------

proc whiteOf(p: IccProfile): array[3, float] =
  ## The white absolute colorimetric keeps (as littlecms reads it: D50 for
  ## version 2 screens and profiles without one).
  if p.version < 0x04000000 and p.deviceClass == "mntr": return d50
  if p.mediaWhite[0] <= 0 or p.mediaWhite[1] <= 0 or p.mediaWhite[2] <= 0: return d50
  p.mediaWhite

proc conversion(src, dst: IccProfile; intent: RenderingIntent; bpc: bool): (array[9, float], array[3, float]) =
  ## The matrix and offset between the two PCS (XYZ, 0..1 as `maxXyz`):
  ## the whites' ratio for absolute colorimetric; black point compensation.
  var m = identity9
  var off = zero3
  if intent == riAbsolute:
    let wi = whiteOf(src)
    let wo = whiteOf(dst)
    m = [wi[0] / wo[0], 0, 0, 0, wi[1] / wo[1], 0, 0, 0, wi[2] / wo[2]]
  elif bpc:
    bpcMatrix(detectBlackPoint(src, intent)[1], detectDestinationBlackPoint(dst, intent)[1], m, off)
  (m, off)

proc newTransform*(src, dst: IccProfile; intent = riPerceptual; bpc = false): IccTransform =
  ## Colors of `src` made into `dst`'s: through each profile's table for
  ## `intent` (A2B1/B2A1 for absolute colorimetric; the perceptual ones when
  ## a profile has none for it; else its matrix and curves), with black
  ## point compensation when `bpc` -- as littlecms does it: always for
  ## perceptual and saturation into a version 4 profile, never for absolute
  ## colorimetric. `ok` is false when a profile cannot be used so.
  result.inputs = channelsOf(src.colorSpace)
  result.outputs = channelsOf(dst.colorSpace)
  if result.inputs == 0 or result.outputs == 0: return
  var ops: seq[Op]
  if not inputOps(src, intent, ops): return
  var useBpc = bpc and intent != riAbsolute
  if intent in {riPerceptual, riSaturation} and dst.version >= 0x04000000: useBpc = true
  let (m, off) = conversion(src, dst, intent, useBpc)
  ops.addConversion(src.pcs, dst.pcs, m, off)
  if not outputOps(dst, intent, ops): return
  result.ops = ops
  result.ok = true

proc canConvert*(p: IccProfile; asInput = true): bool =
  ## Whether the profile's colors can be converted (from them, or into them
  ## when not `asInput`) by a transform.
  var ops: seq[Op]
  if asInput: inputOps(p, riPerceptual, ops) else: outputOps(p, riPerceptual, ops)

proc transform*(t: IccTransform; src: openArray[float]; dst: var openArray[float]) =
  ## One color converted: `src` (`t.inputs` values) to `dst` (`t.outputs`),
  ## each 0..1 (CMYK: how much ink; Lab: L / 100, (a + 128) / 255,
  ## (b + 128) / 255).
  var v: array[maxCh, float]
  for i in 0 ..< min(src.len, t.inputs): v[i] = src[i]
  run(t.ops, v)
  for i in 0 ..< min(dst.len, t.outputs): dst[i] = clamp01(v[i])

proc to8(v: float): int {.inline.} =
  ## 0..1 as 0..255, the way littlecms makes 8 bits from its 16.
  int((int64(sat16(v * 65535)) * 65281 + 8388608) shr 24)

proc transform8*(t: IccTransform; src: openArray[int]; dst: var openArray[int]) =
  ## One color converted with 8 bits a channel (0..255 in and out, as
  ## littlecms rounds them).
  var v: array[maxCh, float]
  for i in 0 ..< min(src.len, t.inputs): v[i] = clamp(src[i], 0, 255) / 255
  run(t.ops, v)
  for i in 0 ..< min(dst.len, t.outputs): dst[i] = to8(v[i])

proc rgbToCmyk*(t: IccTransform; p: uint32): array[4, uint8] =
  ## The inks (C, M, Y, K 0..255) for a color 0xAARRGGBB, through an RGB to
  ## CMYK transform.
  if not t.ok: return
  var v: array[maxCh, float]
  v[0] = float((p shr 16) and 255) / 255
  v[1] = float((p shr 8) and 255) / 255
  v[2] = float(p and 255) / 255
  run(t.ops, v)
  [uint8(to8(v[0])), uint8(to8(v[1])), uint8(to8(v[2])), uint8(to8(v[3]))]

proc cmykToRgb*(t: IccTransform; c, m, y, k: int): uint32 =
  ## The color (0xFFRRGGBB) of inks `c`, `m`, `y`, `k` (0..255), through a
  ## CMYK to RGB transform.
  if not t.ok: return 0xFF000000'u32
  var v: array[maxCh, float]
  v[0] = clamp(c, 0, 255) / 255
  v[1] = clamp(m, 0, 255) / 255
  v[2] = clamp(y, 0, 255) / 255
  v[3] = clamp(k, 0, 255) / 255
  run(t.ops, v)
  0xFF000000'u32 or (uint32(to8(v[0])) shl 16) or (uint32(to8(v[1])) shl 8) or uint32(to8(v[2]))

# ---- grids ---------------------------------------------------------------------------------------------------

proc inkAt(t: IccTransform; r, g, b: int): uint32 =
  let ink = t.rgbToCmyk((uint32(r) shl 16) or (uint32(g) shl 8) or uint32(b))
  (uint32(ink[0]) shl 24) or (uint32(ink[1]) shl 16) or (uint32(ink[2]) shl 8) or uint32(ink[3])

proc rgbToCmykGrid*(rgb, cmyk: IccProfile; intent = riRelative; bpc = false; n = 33): seq[uint32] =
  ## The inks of an n x n x n grid of RGB colors, as `retroui/photoinks`
  ## keeps them: index (r * n + g) * n + b for the colors
  ## (i * 255 + (n - 1) div 2) div (n - 1); C, M, Y, K packed highest first
  ## (0..255 each). Empty when the profiles cannot be used.
  let t = newTransform(rgb, cmyk, intent, bpc)
  if not t.ok or t.inputs != 3 or t.outputs != 4 or n < 2: return
  result = newSeq[uint32](n * n * n)
  let dst = cast[ptr UncheckedArray[uint32]](addr result[0])
  let tp = addr t
  parallelFor(n, proc (lo, hi: int) =
    for ri in lo ..< hi:
      for gi in 0 ..< n:
        for bi in 0 ..< n:
          dst[(ri * n + gi) * n + bi] = inkAt(tp[], (ri * 255 + (n - 1) div 2) div (n - 1),
                                              (gi * 255 + (n - 1) div 2) div (n - 1),
                                              (bi * 255 + (n - 1) div 2) div (n - 1))
  , keepAlive = false)

proc cmykToRgbGrid*(cmyk, rgb: IccProfile; intent = riRelative; bpc = false; n = 17): seq[uint32] =
  ## The colors (0xFFRRGGBB) of an n x n x n x n grid of inks: index
  ## ((c * n + m) * n + y) * n + k for the inks i * 255 div (n - 1). Empty
  ## when the profiles cannot be used.
  let t = newTransform(cmyk, rgb, intent, bpc)
  if not t.ok or t.inputs != 4 or t.outputs != 3 or n < 2: return
  result = newSeq[uint32](n * n * n * n)
  let dst = cast[ptr UncheckedArray[uint32]](addr result[0])
  let tp = addr t
  parallelFor(n, proc (lo, hi: int) =
    for ci in lo ..< hi:
      for mi in 0 ..< n:
        for yi in 0 ..< n:
          for ki in 0 ..< n:
            dst[((ci * n + mi) * n + yi) * n + ki] = cmykToRgb(tp[], ci * 255 div (n - 1), mi * 255 div (n - 1),
                                                               yi * 255 div (n - 1), ki * 255 div (n - 1))
  , keepAlive = false)

# ---- writing profiles with tables ---------------------------------------------------------------------------------

proc be32(v: int): string =
  result = newString(4)
  result[0] = char((v shr 24) and 255)
  result[1] = char((v shr 16) and 255)
  result[2] = char((v shr 8) and 255)
  result[3] = char(v and 255)

proc be16(v: int): string =
  result = newString(2)
  result[0] = char((v shr 8) and 255)
  result[1] = char(v and 255)

proc s15(v: float): string =
  be32(int(round(v * 65536)))      # (be32 writes the low 32 bits: two's complement)

proc u16of(v: float): string = be16(int(round(clamp01(v) * 65535)))

proc xyzTag*(xyz: array[3, float]): string =
  ## An XYZType tag (wtpt, bkpt...).
  "XYZ " & be32(0) & s15(xyz[0]) & s15(xyz[1]) & s15(xyz[2])

proc textTag*(s: string): string =
  ## A textType tag (cprt in version 2).
  "text" & be32(0) & s & "\0"

proc descTag*(s: string): string =
  ## A textDescriptionType tag (desc in version 2).
  result = "desc" & be32(0) & be32(s.len + 1) & s & "\0"
  result.add be32(0) & be32(0)                    # (no Unicode)
  result.add be16(0) & "\0" & newString(67)       # (no ScriptCode)

proc lut16Tag*(inputs, outputs, grid: int; values: openArray[float];
               inTables: openArray[seq[float]] = []; outTables: openArray[seq[float]] = []): string =
  ## A lut16Type tag (mft2): curves for the inputs as tables (0..1; none:
  ## straight), a grid of `grid` points along each input with `outputs`
  ## values (0..1) at each -- the first input slowest -- then curves for
  ## the outputs. Lab is written the version 2 way (`lut16Lab`).
  result = "mft2" & be32(0) & char(inputs) & char(outputs) & char(grid) & '\0'
  for i in 0 .. 8: result.add s15(if i mod 4 == 0: 1.0 else: 0.0)
  let inN = if inTables.len == inputs: inTables[0].len else: 2
  let outN = if outTables.len == outputs: outTables[0].len else: 2
  result.add be16(inN) & be16(outN)
  for i in 0 ..< inputs:
    for j in 0 ..< inN:
      result.add u16of(if inTables.len == inputs: inTables[i][j] else: j.float)
  for v in values: result.add u16of(v)
  for i in 0 ..< outputs:
    for j in 0 ..< outN:
      result.add u16of(if outTables.len == outputs: outTables[i][j] else: j.float)

proc profileBytes*(deviceClass, colorSpace, pcs: string; tags: openArray[(string, string)];
                   version = 0x02100000; intent = 0): string =
  ## A whole profile: its header (D50; dated 2026-01-01) and its tags, each
  ## as (signature, data); tags with the same data share it.
  var table = be32(tags.len)
  var body = ""
  let start = 128 + 4 + 12 * tags.len
  var placed: seq[(int, int)]                     # (tag, where its data is)
  for i, (sig, data) in tags:
    var at = -1
    for (j, o) in placed:
      if tags[j][1] == data:
        at = o
        break
    if at < 0:
      at = start + body.len
      body.add data
      while body.len mod 4 != 0: body.add '\0'
      placed.add (i, at)
    table.add sig[0 ..< 4] & be32(at) & be32(data.len)
  var head = be32(start + body.len) & be32(0) & be32(version) & deviceClass[0 ..< 4] & colorSpace[0 ..< 4] &
             pcs[0 ..< 4] & be16(2026) & be16(1) & be16(1) & be16(0) & be16(0) & be16(0) & "acsp" & be32(0) &
             be32(0) & be32(0) & be32(0) & be32(0) & be32(0) & be32(intent) & s15(d50[0]) & s15(d50[1]) &
             s15(d50[2]) & be32(0)
  while head.len < 128: head.add '\0'
  head & table & body

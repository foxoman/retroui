## Procedural Texture (the Affinity filter): a picture made, or changed, by formulas -- one for each
## of red, green, blue and alpha, and one shared value (`v`) worked out first -- in plain numbers
## (0..1 the channels), with where the pixel is, its colors, four sliders and functions of noise,
## cells and waves. Clouds, wood, marble, stripes, a vignette, halftone dots... are a few formulas
## each (`texturePresets`).
##
## ```nim
## let f = TextureFormula(name: "Rings", v: "frac(rad * p0)", r: "v", g: "v * R", b: "B",
##                        params: [("Rings", 8.0, 1.0, 40.0), ("", 0, 0, 0), ("", 0, 0, 0), ("", 0, 0, 0)])
## let fn = proceduralTexture(f)            # a filter of retroui/photofx
## ```
##
## What a formula can use:
## - where the pixel is: `x`, `y` (pixels from the corner of the part filtered), `w`, `h` (its size),
##   `rx`, `ry` (0..1 across it), `cx`, `cy` (-1..1 from its middle, as square as it is wide), `rad`
##   (how far from the middle: 1 at the nearer edge), `ang` (round the middle: -pi..pi)
## - its colors: `R`, `G`, `B`, `A` (0..1), `L` its lightness; the shared value `v`
## - the sliders `p0`..`p3`; `pi`, `e`
## - `+ - * / % ^`, `< > <= >= == !=`, `&& || !`, `a ? b : c`
## - `sin cos tan asin acos atan atan2 abs sign floor ceil round frac sqrt exp log pow min max
##   clamp(v, lo, hi) sat(v) mix(a, b, t) step(edge, v) smoothstep(a, b, v)`
## - `noise(x, y)` (smooth noise, 0..1), `fbm(x, y, octaves)` (noise of noise: clouds), `cells(x, y)`
##   (how far to the nearest of points scattered one to a square: cells, 0..1), `rnd(x, y)` (a
##   number that looks random for each place, 0..1), `wave(v)` (0..1 and back, smoothly)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[math, strutils]
import gfx, photofx, parallel

type
  TextureFormula* = object
    ## A procedural texture: its name, the formulas of the shared value and of red, green, blue and
    ## alpha ("" a channel unchanged; `v` "" none), and its four sliders.
    name*: string
    v*, r*, g*, b*, a*: string
    params*: array[4, tuple[name: string; value, lo, hi: float]]  ## ("" name: not shown)

  TextureError* = object of ValueError
    ## A formula that cannot be read (its message says what and where).

  Op = enum
    opConst, opVar, opNeg, opNot, opAdd, opSub, opMul, opDiv, opMod, opPow,
    opLt, opGt, opLe, opGe, opEq, opNe, opJmpFalse, opJmp, opAndJ, opOrJ, opBool, opCall

  Fn = enum
    fSin, fCos, fTan, fAsin, fAcos, fAtan, fAtan2, fAbs, fSign, fFloor, fCeil, fRound, fFrac, fSqrt,
    fExp, fLog, fPow, fMin, fMax, fClamp, fSat, fMix, fStep, fSmooth, fNoise, fFbm, fCells, fRnd, fWave

  Ins = object
    op: Op
    k: float
    arg, n: int

  Formula = object
    ins: seq[Ins]
    empty: bool

  Vr = enum
    vX, vY, vW, vH, vRX, vRY, vCX, vCY, vRad, vAng, vR, vG, vB, vA, vL, vV, vP0, vP1, vP2, vP3

const
  varNames: array[Vr, string] = ["x", "y", "w", "h", "rx", "ry", "cx", "cy", "rad", "ang", "R", "G", "B",
                                 "A", "L", "v", "p0", "p1", "p2", "p3"]
  fnNames: array[Fn, string] = ["sin", "cos", "tan", "asin", "acos", "atan", "atan2", "abs", "sign", "floor",
                                "ceil", "round", "frac", "sqrt", "exp", "log", "pow", "min", "max", "clamp",
                                "sat", "mix", "step", "smoothstep", "noise", "fbm", "cells", "rnd", "wave"]
  fnArgs: array[Fn, Slice[int]] = [1..1, 1..1, 1..1, 1..1, 1..1, 1..1, 2..2, 1..1, 1..1, 1..1, 1..1, 1..1,
                                   1..1, 1..1, 1..1, 1..1, 2..2, 2..2, 2..2, 3..3, 1..1, 3..3, 2..2, 3..3,
                                   2..3, 3..4, 2..3, 2..3, 1..1]

# ---- reading a formula --------------------------------------------------------------------------------------

type Parser = object
  s: string
  i: int
  f: Formula

proc fail(p: Parser; msg: string) {.noreturn.} =
  raise newException(TextureError, msg & " (at " & $(p.i + 1) & ")")

proc skip(p: var Parser) =
  while p.i < p.s.len and p.s[p.i] in Whitespace: inc p.i

proc take(p: var Parser; t: string): bool =
  p.skip
  if p.s.continuesWith(t, p.i):
    p.i += t.len
    return true

proc emit(p: var Parser; op: Op; k = 0.0; arg = 0; n = 0): int {.discardable.} =
  p.f.ins.add Ins(op: op, k: k, arg: arg, n: n)
  p.f.ins.high

proc expr(p: var Parser)

proc primary(p: var Parser) =
  p.skip
  if p.i >= p.s.len: p.fail("a value is missing")
  let c = p.s[p.i]
  if c in {'0'..'9', '.'}:
    let st = p.i
    while p.i < p.s.len and p.s[p.i] in {'0'..'9', '.'}: inc p.i
    if p.i < p.s.len and p.s[p.i] in {'e', 'E'} and p.i + 1 < p.s.len and p.s[p.i + 1] in {'0'..'9', '-', '+'}:
      inc p.i
      if p.s[p.i] in {'-', '+'}: inc p.i
      while p.i < p.s.len and p.s[p.i] in {'0'..'9'}: inc p.i
    let v = try: parseFloat(p.s[st ..< p.i]) except ValueError: p.fail("not a number: " & p.s[st ..< p.i])
    p.emit(opConst, v)
  elif c == '(':
    inc p.i
    p.expr
    if not p.take(")"): p.fail("a ')' is missing")
  elif c in IdentStartChars:
    let st = p.i
    while p.i < p.s.len and p.s[p.i] in IdentChars: inc p.i
    let name = p.s[st ..< p.i]
    if p.take("("):
      var fn = -1
      for f in Fn:
        if fnNames[f] == name: fn = ord(f)
      if fn < 0: p.fail("no function is called " & name)
      var n = 0
      if not p.take(")"):
        while true:
          p.expr
          inc n
          if p.take(")"): break
          if not p.take(","): p.fail("a ',' or ')' is missing in " & name & "(...)")
      if n notin fnArgs[Fn(fn)]: p.fail(name & " takes " & $fnArgs[Fn(fn)].a &
                                        (if fnArgs[Fn(fn)].b != fnArgs[Fn(fn)].a: " to " & $fnArgs[Fn(fn)].b else: "") &
                                        " values, not " & $n)
      p.emit(opCall, arg = fn, n = n)
    else:
      case name
      of "pi": p.emit(opConst, PI)
      of "e": p.emit(opConst, E)
      else:
        var v = -1
        for x in Vr:
          if varNames[x] == name: v = ord(x)
        if v < 0: p.fail("no value is called " & name)
        p.emit(opVar, arg = v)
  else: p.fail("'" & $c & "' cannot be here")

proc unary(p: var Parser) =
  if p.take("-"):
    p.unary
    p.emit(opNeg)
  elif p.take("+"): p.unary
  elif p.take("!"):
    p.unary
    p.emit(opNot)
  else:
    p.primary
    if p.take("^"):              # (right to left: 2^3^2 is 2^9)
      p.unary
      p.emit(opPow)

proc binary(p: var Parser; level: int) =
  const levels = [@["||"], @["&&"], @["==", "!="], @["<=", ">=", "<", ">"], @["+", "-"], @["*", "/", "%"]]
  if level >= levels.len:
    p.unary
    return
  p.binary(level + 1)
  while true:
    var found = ""
    p.skip
    for t in levels[level]:
      if p.s.continuesWith(t, p.i) and not (t in ["<", ">"] and p.s.continuesWith(t & "=", p.i)):
        found = t
        break
    if found.len == 0: return
    p.i += found.len
    case found
    of "||", "&&":
      let j = p.emit(if found == "||": opOrJ else: opAndJ)
      p.binary(level + 1)
      p.emit(opBool)
      p.f.ins[j].arg = p.f.ins.len
    else:
      p.binary(level + 1)
      p.emit(case found
             of "+": opAdd
             of "-": opSub
             of "*": opMul
             of "/": opDiv
             of "%": opMod
             of "<": opLt
             of ">": opGt
             of "<=": opLe
             of ">=": opGe
             of "==": opEq
             else: opNe)

proc expr(p: var Parser) =
  p.binary(0)
  if p.take("?"):
    let jf = p.emit(opJmpFalse)
    p.expr
    let j = p.emit(opJmp)
    if not p.take(":"): p.fail("a ':' is missing after '?'")
    p.f.ins[jf].arg = p.f.ins.len
    p.expr
    p.f.ins[j].arg = p.f.ins.len

proc compile(s: string): Formula =
  if s.strip.len == 0: return Formula(empty: true)
  var p = Parser(s: s)
  p.expr
  p.skip
  if p.i < p.s.len: p.fail("'" & p.s[p.i ..< min(p.s.len, p.i + 8)] & "' is not understood")
  p.f

proc textureError*(formula: string): string =
  ## What is wrong with `formula` ("" nothing).
  try:
    discard compile(formula)
    ""
  except TextureError as e: e.msg

# ---- noise ------------------------------------------------------------------------------------------------

proc hash2(x, y: int32; seed: int32): uint32 {.inline.} =
  var h = uint32(x) * 0x8DA6B343'u32 xor uint32(y) * 0xD8163841'u32 xor uint32(seed) * 0xCB1AB31F'u32
  h = (h xor (h shr 13)) * 0x5BD1E995'u32
  h xor (h shr 15)

proc rnd2(x, y: float; seed = 0.0): float =
  float(hash2(int32(floor(x)), int32(floor(y)), int32(seed)) and 0xFFFFFF) / float(0xFFFFFF)

proc grad(ix, iy: int32; seed: int32; dx, dy: float): float {.inline.} =
  let a = float(hash2(ix, iy, seed) and 0xFFFF) / 65536 * 2 * PI
  cos(a) * dx + sin(a) * dy

proc perlin(x, y: float; seed = 0.0): float =
  ## (gradient noise: 0..1, smooth, 0.5 on the grid's corners)
  let (fx, fy) = (floor(x), floor(y))
  let (ix, iy) = (int32(fx), int32(fy))
  let (dx, dy) = (x - fx, y - fy)
  let s = int32(seed)
  let u = dx * dx * dx * (dx * (dx * 6 - 15) + 10)
  let v = dy * dy * dy * (dy * (dy * 6 - 15) + 10)
  let n00 = grad(ix, iy, s, dx, dy)
  let n10 = grad(ix + 1, iy, s, dx - 1, dy)
  let n01 = grad(ix, iy + 1, s, dx, dy - 1)
  let n11 = grad(ix + 1, iy + 1, s, dx - 1, dy - 1)
  let n = (n00 + (n10 - n00) * u) + ((n01 + (n11 - n01) * u) - (n00 + (n10 - n00) * u)) * v
  clamp(0.5 + n * 0.7071, 0, 1)

proc fbm(x, y, octaves: float; seed = 0.0): float =
  var amp = 0.5
  var f = 1.0
  var total = 0.0
  var norm = 0.0
  for o in 0 ..< clamp(int(octaves), 1, 12):
    total += amp * perlin(x * f, y * f, seed + float(o * 17))
    norm += amp
    amp *= 0.5
    f *= 2
  total / norm

proc cells(x, y: float; seed = 0.0): float =
  ## (Worley: how far to the nearest point, one scattered in each square; 0 at a point, about 1 far)
  let (ix, iy) = (int32(floor(x)), int32(floor(y)))
  var best = 9.0
  for oy in -1'i32 .. 1:
    for ox in -1'i32 .. 1:
      let h = hash2(ix + ox, iy + oy, int32(seed) + 99)
      let px = float(ix + ox) + float(h and 0xFFFF) / 65536
      let py = float(iy + oy) + float((h shr 16) and 0xFFFF) / 65536
      best = min(best, (px - x) * (px - x) + (py - y) * (py - y))
  min(1.0, sqrt(best))

# ---- running ----------------------------------------------------------------------------------------------

proc call(f: Fn; a: openArray[float]): float =
  case f
  of fSin: sin(a[0])
  of fCos: cos(a[0])
  of fTan: tan(a[0])
  of fAsin: arcsin(clamp(a[0], -1, 1))
  of fAcos: arccos(clamp(a[0], -1, 1))
  of fAtan: arctan(a[0])
  of fAtan2: arctan2(a[0], a[1])
  of fAbs: abs(a[0])
  of fSign: (if a[0] > 0: 1.0 elif a[0] < 0: -1.0 else: 0.0)
  of fFloor: floor(a[0])
  of fCeil: ceil(a[0])
  of fRound: round(a[0])
  of fFrac: a[0] - floor(a[0])
  of fSqrt: sqrt(max(0.0, a[0]))
  of fExp: exp(min(a[0], 80.0))
  of fLog: (if a[0] > 0: ln(a[0]) else: -80.0)
  of fPow: (if a[0] < 0 and a[1] != floor(a[1]): 0.0 else: pow(a[0], a[1]))
  of fMin: min(a[0], a[1])
  of fMax: max(a[0], a[1])
  of fClamp: clamp(a[0], min(a[1], a[2]), max(a[1], a[2]))
  of fSat: clamp(a[0], 0, 1)
  of fMix: a[0] + (a[1] - a[0]) * a[2]
  of fStep: (if a[1] >= a[0]: 1.0 else: 0.0)
  of fSmooth:
    let t = if a[1] == a[0]: (if a[2] >= a[1]: 1.0 else: 0.0) else: clamp((a[2] - a[0]) / (a[1] - a[0]), 0, 1)
    t * t * (3 - 2 * t)
  of fNoise: perlin(a[0], a[1], if a.len > 2: a[2] else: 0.0)
  of fFbm: fbm(a[0], a[1], a[2], if a.len > 3: a[3] else: 0.0)
  of fCells: cells(a[0], a[1], if a.len > 2: a[2] else: 0.0)
  of fRnd: rnd2(a[0], a[1], if a.len > 2: a[2] else: 0.0)
  of fWave: 0.5 - 0.5 * cos(a[0] * 2 * PI)

proc run(f: Formula; vars: array[Vr, float]; stack: var seq[float]): float =
  stack.setLen(0)
  var pc = 0
  var args: array[4, float]
  while pc < f.ins.len:
    let ins = f.ins[pc]
    inc pc
    case ins.op
    of opConst: stack.add ins.k
    of opVar: stack.add vars[Vr(ins.arg)]
    of opNeg: stack[^1] = -stack[^1]
    of opNot: stack[^1] = (if stack[^1] == 0: 1.0 else: 0.0)
    of opBool: stack[^1] = (if stack[^1] != 0: 1.0 else: 0.0)
    of opJmpFalse:
      let c = stack.pop
      if c == 0: pc = ins.arg
    of opJmp: pc = ins.arg
    of opAndJ:
      if stack[^1] == 0: pc = ins.arg
      else: discard stack.pop
    of opOrJ:
      if stack[^1] != 0:
        stack[^1] = 1
        pc = ins.arg
      else: discard stack.pop
    of opCall:
      for k in countdown(ins.n - 1, 0): args[k] = stack.pop
      stack.add call(Fn(ins.arg), args.toOpenArray(0, ins.n - 1))
    else:
      let b = stack.pop
      let a = stack[^1]
      stack[^1] = case ins.op
                  of opAdd: a + b
                  of opSub: a - b
                  of opMul: a * b
                  of opDiv: (if b == 0: 0.0 else: a / b)
                  of opMod: (if b == 0: 0.0 else: a - b * floor(a / b))
                  of opPow: (if a < 0 and b != floor(b): 0.0 else: pow(a, b))
                  of opLt: float(a < b)
                  of opGt: float(a > b)
                  of opLe: float(a <= b)
                  of opGe: float(a >= b)
                  of opEq: float(a == b)
                  else: float(a != b)
  if stack.len == 0: 0.0 else: stack[^1]

proc proceduralTexture*(t: TextureFormula; values: openArray[float] = []): FilterFn =
  ## The texture as a filter of `retroui/photofx`, its sliders at `values` (left out: each one's
  ## `value`). Raises `TextureError` for a formula that cannot be read.
  let fv = compile(t.v)
  let fs = [compile(t.r), compile(t.g), compile(t.b), compile(t.a)]
  var ps: array[4, float]
  for k in 0 .. 3: ps[k] = if k < values.len: values[k] else: t.params[k].value
  proc apply(src: Img; inner: Rect): Img =
    var o = src
    let w = inner.w
    let h = inner.h
    if w <= 0 or h <= 0: return o
    let sp = cast[ptr UncheckedArray[uint32]](unsafeAddr src.px[0])
    let dp = cast[ptr UncheckedArray[uint32]](addr o.px[0])
    let sw = src.w
    let (ox, oy) = (inner.x, inner.y)
    let half = min(w, h).float / 2
    let fvp = unsafeAddr fv
    let fsp = unsafeAddr fs
    parallelChunks(h, lo, hi):
      var vars: array[Vr, float]
      var stack = newSeqOfCap[float](32)
      vars[vW] = w.float
      vars[vH] = h.float
      vars[vP0] = ps[0]; vars[vP1] = ps[1]; vars[vP2] = ps[2]; vars[vP3] = ps[3]
      for y in lo ..< hi:
        for x in 0 ..< w:
          let i = (y + oy) * sw + (x + ox)
          let p = sp[i]
          let (r, g, b, a) = (float((p shr 16) and 255) / 255, float((p shr 8) and 255) / 255,
                              float(p and 255) / 255, float(p shr 24) / 255)
          vars[vX] = x.float
          vars[vY] = y.float
          vars[vRX] = (x.float + 0.5) / w.float
          vars[vRY] = (y.float + 0.5) / h.float
          vars[vCX] = (x.float + 0.5 - w.float / 2) / half
          vars[vCY] = (y.float + 0.5 - h.float / 2) / half
          vars[vRad] = sqrt(vars[vCX] * vars[vCX] + vars[vCY] * vars[vCY])
          vars[vAng] = arctan2(vars[vCY], vars[vCX])
          vars[vR] = r; vars[vG] = g; vars[vB] = b; vars[vA] = a
          vars[vL] = 0.299 * r + 0.587 * g + 0.114 * b
          vars[vV] = if fvp[].empty: 0.0 else: run(fvp[], vars, stack)
          var c = [r, g, b, a]
          for k in 0 .. 3:
            if not fsp[][k].empty:
              let val = run(fsp[][k], vars, stack)
              c[k] = if val.isNaN: 0.0 else: clamp(val, 0, 1)
          dp[i] = (uint32(c[3] * 255 + 0.5) shl 24) or (uint32(c[0] * 255 + 0.5) shl 16) or
                  (uint32(c[1] * 255 + 0.5) shl 8) or uint32(c[2] * 255 + 0.5)
    o
  apply

proc tf(name, v, r, g, b: string; a = ""; params: openArray[(string, float, float, float)] = []): TextureFormula =
  result = TextureFormula(name: name, v: v, r: r, g: g, b: b, a: a)
  for k, (n, val, lo, hi) in params: result.params[k] = (n, val, lo, hi)

let texturePresets* = @[
  tf("Clouds", "fbm(rx * p0, ry * p0 * h / w, 6, p1)", "mix(0.35, 1, v)", "mix(0.55, 1, v)", "1", "",
     [("Scale", 5.0, 1.0, 30.0), ("Seed", 1.0, 0.0, 99.0)]),
  tf("Wood", "frac(rad * p0 + noise(cx * 3, cy * 3) * p1)", "mix(0.42, 0.72, wave(v))", "mix(0.24, 0.47, wave(v))",
     "mix(0.10, 0.24, wave(v))", "", [("Rings", 12.0, 2.0, 60.0), ("Grain", 2.0, 0.0, 8.0)]),
  tf("Marble", "wave((cx + fbm(rx * 4, ry * 4, 5) * p0) * p1)", "mix(0.55, 0.96, v)", "mix(0.56, 0.96, v)",
     "mix(0.60, 0.98, v)", "", [("Veins", 2.0, 0.0, 6.0), ("Bands", 3.0, 1.0, 12.0)]),
  tf("Stripes", "step(0.5, frac((rx * cos(p1 * pi / 180) + ry * h / w * sin(p1 * pi / 180)) * p0))",
     "mix(R, v, p2)", "mix(G, v, p2)", "mix(B, v, p2)", "",
     [("Stripes", 10.0, 1.0, 100.0), ("Angle", 45.0, 0.0, 180.0), ("Strength", 1.0, 0.0, 1.0)]),
  tf("Checkerboard", "(floor(x / p0) + floor(y / p0)) % 2", "mix(R, v, p1)", "mix(G, v, p1)", "mix(B, v, p1)", "",
     [("Square", 32.0, 2.0, 400.0), ("Strength", 1.0, 0.0, 1.0)]),
  tf("Vignette", "1 - p0 * smoothstep(p1, 1.45, rad)", "R * v", "G * v", "B * v", "",
     [("Amount", 0.7, 0.0, 1.0), ("Starts at", 0.5, 0.0, 1.4)]),
  tf("Halftone Dots",
     "step(sqrt((frac(x / p0) - 0.5) ^ 2 + (frac(y / p0) - 0.5) ^ 2), (1 - L) * 0.72)",
     "1 - v", "1 - v", "1 - v", "", [("Dot", 8.0, 3.0, 60.0)]),
  tf("Ripples", "wave(rad * p0 - p1)", "R * (1 - p2 + 2 * p2 * v)", "G * (1 - p2 + 2 * p2 * v)",
     "B * (1 - p2 + 2 * p2 * v)", "", [("Rings", 12.0, 1.0, 60.0), ("Phase", 0.0, 0.0, 1.0), ("Strength", 0.25, 0.0, 1.0)]),
  tf("Film Grain", "rnd(x, y, p1) - 0.5", "R + v * p0", "G + v * p0", "B + v * p0", "",
     [("Amount", 0.12, 0.0, 1.0), ("Seed", 1.0, 0.0, 99.0)]),
  tf("Sun Rays", "wave(ang / (2 * pi) * p0) * smoothstep(1.6, 0, rad)", "mix(R, 1, v * p1)", "mix(G, 0.95, v * p1)",
     "mix(B, 0.8, v * p1)", "", [("Rays", 16.0, 3.0, 64.0), ("Strength", 0.5, 0.0, 1.0)]),
  tf("Cells", "cells(rx * p0, ry * p0 * h / w, p1)", "mix(0.15, 0.95, v)", "mix(0.2, 0.9, v)", "mix(0.35, 0.85, v)", "",
     [("Cells", 10.0, 2.0, 60.0), ("Seed", 1.0, 0.0, 99.0)]),
  tf("Duotone", "L", "mix(0.10, 1.0, v)", "mix(0.12, 0.78, v)", "mix(0.35, 0.30, v)", "",
     [])]

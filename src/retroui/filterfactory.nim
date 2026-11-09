## Filter Factory: filters written as four small formulas -- one for the
## red, green, blue and alpha of each pixel -- in the language of Adobe's
## Filter Factory of 1994: whole numbers, the pixel's channels (`r`, `g`,
## `b`, `a`, `c`), where it is (`x`, `y`, `X`, `Y`, `d`, `m`), eight sliders
## (`ctl(0)`..`ctl(7)`, `val(n, lo, hi)`), other pixels (`src`, `rad`) and
## functions (`sin`, `cos`, `sqr`, `mix`, `scl`, `rnd`...). A filter made
## so is a plug-in: kept as a small file and listed in the Filter menu.
##
## .. code-block:: nim
##   let f = compileFilter(FactoryFilter(name: "Sepia",
##             r: "i + ctl(0) / 4", g: "i", b: "i - ctl(0) / 4", a: "a"))
##   let fn = f.filterFn([64, 0, 0, 0, 0, 0, 0, 0])

import std/[math, strutils, json, os]
import gfx, photofx, parallel

type
  FactoryFilter* = object
    ## A Filter Factory filter: its name, where it is listed, its sliders and
    ## the formulas of its four channels.
    name*: string               ## its name in the Filter menu
    category*: string           ## the submenu of Filter > Plug-ins it is in
    author*, about*: string     ## who wrote it, and a line about what it does
    sliders*: array[8, string]  ## the sliders' names ("" not shown)
    values*: array[8, int]      ## ... where they start (0..255)
    r*, g*, b*, a*: string      ## the formulas of red, green, blue and alpha ("": the channel unchanged)

  FactoryError* = object of ValueError
    ## A formula that cannot be read (its message says where).

  Op = enum
    opConst, opVar, opNeg, opNot, opBitNot,
    opAdd, opSub, opMul, opDiv, opMod, opShl, opShr, opLt, opGt, opLe, opGe, opEq, opNe,
    opAnd, opXor, opOr,
    opJmpFalse, opJmp, opJmpFalseKeep, opJmpTrueKeep, opBool, opPop,
    opCall

  Fn = enum
    fnCtl, fnVal, fnMin, fnMax, fnAbs, fnAdd, fnSub, fnDif, fnMix, fnScl, fnSqr, fnSin, fnCos, fnTan,
    fnRnd, fnSrc, fnRad, fnC2d, fnC2m, fnR2x, fnR2y, fnGet, fnPut, fnMap, fnCnv

  Ins = object
    op: Op
    arg: int                    # the constant, the variable, the jump, the function
    n: int                      # the arguments of a call

  Code* = object
    ## A formula compiled (`compileFormula`): what runs for each pixel.
    ins: seq[Ins]
    identity: int               # the formula is just this channel (-1 not)

  CompiledFilter* = object
    ## A filter ready to run.
    f*: FactoryFilter           ## the filter it was compiled from
    code: array[4, Code]

  V = enum
    vR, vG, vB, vA, vC, vI, vU, vV, vX, vY, vXX, vYY, vZ, vZZ, vD, vDD, vM, vMM

const varNames: array[V, string] = ["r", "g", "b", "a", "c", "i", "u", "v", "x", "y", "X", "Y", "z", "Z",
                                    "d", "D", "m", "M"]
const fnNames: array[Fn, (string, int)] = [("ctl", 1), ("val", 3), ("min", 2), ("max", 2), ("abs", 1), ("add", 3),
                                           ("sub", 3), ("dif", 2), ("mix", 4), ("scl", 5), ("sqr", 1), ("sin", 1),
                                           ("cos", 1), ("tan", 1), ("rnd", 2), ("src", 3), ("rad", 3), ("c2d", 2),
                                           ("c2m", 2), ("r2x", 2), ("r2y", 2), ("get", 1), ("put", 2),
                                           ("map", 2), ("cnv", 10)]

# ---- reading a formula -----------------------------------------------------------------------------------

type Parser = object
  s: string
  pos: int
  code: seq[Ins]
  constants: seq[string]         # (the named constants: rmax, dmin...)

proc fail(p: Parser; msg: string) {.noreturn.} =
  raise newException(FactoryError, msg & " (at " & $(p.pos + 1) & ")")

proc skipSpace(p: var Parser) =
  while p.pos < p.s.len and p.s[p.pos] in {' ', '\t', '\n', '\r'}: inc p.pos

proc peek(p: var Parser; t: string): bool =
  p.skipSpace()
  p.s.continuesWith(t, p.pos)

proc take(p: var Parser; t: string): bool =
  if p.peek(t):
    p.pos += t.len
    return true

proc emit(p: var Parser; op: Op; arg = 0; n = 0): int {.discardable.} =
  p.code.add Ins(op: op, arg: arg, n: n)
  p.code.high

proc expr(p: var Parser)

proc primary(p: var Parser) =
  p.skipSpace()
  if p.pos >= p.s.len: p.fail("a value is missing")
  let ch = p.s[p.pos]
  if ch in {'0' .. '9'}:
    var v = 0
    if p.s.continuesWith("0x", p.pos) or p.s.continuesWith("0X", p.pos):
      p.pos += 2
      while p.pos < p.s.len and p.s[p.pos] in HexDigits:
        v = v * 16 + parseHexInt($p.s[p.pos])
        inc p.pos
    else:
      while p.pos < p.s.len and p.s[p.pos] in {'0' .. '9'}:
        v = v * 10 + ord(p.s[p.pos]) - ord('0')
        if v > 1_000_000_000: p.fail("a number too big")
        inc p.pos
    p.emit(opConst, v)
  elif ch == '(':
    inc p.pos
    p.expr()
    if not p.take(")"): p.fail("a ')' is missing")
  elif ch in {'a' .. 'z', 'A' .. 'Z', '_'}:
    let start = p.pos
    while p.pos < p.s.len and p.s[p.pos] in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}: inc p.pos
    let name = p.s[start ..< p.pos]
    if p.peek("("):
      discard p.take("(")
      var fnk = -1
      for k, (n, _) in fnNames:
        if n == name: fnk = ord(k)
      if fnk < 0: p.fail("no function '" & name & "'")
      var n = 0
      if not p.peek(")"):
        while true:
          p.expr()
          inc n
          if not p.take(","): break
      if not p.take(")"): p.fail("a ')' is missing after the arguments of " & name)
      let want = fnNames[Fn(fnk)][1]
      if n != want: p.fail(name & " takes " & $want & " values, not " & $n)
      p.emit(opCall, fnk, n)
    else:
      case name
      of "rmax", "gmax", "bmax", "amax", "cmax", "imax", "zmax": p.emit(opConst, 255)
      of "rmin", "gmin", "bmin", "amin", "cmin", "imin", "dmin", "mmin", "zmin": p.emit(opConst, 0)
      of "umax", "vmax": p.emit(opConst, 136)
      of "umin", "vmin": p.emit(opConst, -136)
      of "dmax": p.emit(opConst, 1024)
      else:
        var vk = -1
        for k, n in varNames:
          if n == name: vk = ord(k)
        if vk < 0: p.fail("no value '" & name & "'")
        p.emit(opVar, vk)
  else: p.fail("'" & $ch & "' is not expected here")

proc unary(p: var Parser) =
  if p.take("-"):
    p.unary()
    p.emit(opNeg)
  elif p.take("+"): p.unary()
  elif p.peek("!") and not p.peek("!="):
    discard p.take("!")
    p.unary()
    p.emit(opNot)
  elif p.take("~"):
    p.unary()
    p.emit(opBitNot)
  else: p.primary()

proc binary(p: var Parser; level: int) =
  # levels: 0 ||, 1 &&, 2 |, 3 ^, 4 &, 5 == !=, 6 < > <= >=, 7 << >>, 8 + -, 9 * / %
  if level > 9:
    p.unary()
    return
  if level == 0:
    p.binary(1)
    while p.peek("||"):
      discard p.take("||")
      let j = p.emit(opJmpTrueKeep)
      p.emit(opPop)
      p.binary(1)
      p.emit(opBool)
      p.code[j].arg = p.code.len
    return
  if level == 1:
    p.binary(2)
    while p.peek("&&"):
      discard p.take("&&")
      let j = p.emit(opJmpFalseKeep)
      p.emit(opPop)
      p.binary(2)
      p.emit(opBool)
      p.code[j].arg = p.code.len
    return
  p.binary(level + 1)
  while true:
    var op: Op
    var found = false
    template tryOp(t: string; o: Op; notFollowed = "") =
      if not found and p.peek(t) and (notFollowed.len == 0 or not p.s.continuesWith(notFollowed, p.pos + t.len)):
        if not (t in ["|", "&"] and p.s.continuesWith(t & t, p.pos)) and
           not (t in ["<", ">"] and (p.s.continuesWith(t & t, p.pos) or p.s.continuesWith(t & "=", p.pos))):
          p.pos += t.len
          op = o
          found = true
    case level
    of 2: tryOp("|", opOr)
    of 3: tryOp("^", opXor)
    of 4: tryOp("&", opAnd)
    of 5:
      tryOp("==", opEq)
      tryOp("!=", opNe)
    of 6:
      tryOp("<=", opLe)
      tryOp(">=", opGe)
      tryOp("<", opLt)
      tryOp(">", opGt)
    of 7:
      tryOp("<<", opShl)
      tryOp(">>", opShr)
    of 8:
      tryOp("+", opAdd)
      tryOp("-", opSub)
    else:
      tryOp("*", opMul)
      tryOp("/", opDiv)
      tryOp("%", opMod)
    if not found: break
    p.binary(level + 1)
    p.emit(op)

proc conditional(p: var Parser) =
  p.binary(0)
  if p.take("?"):
    let jf = p.emit(opJmpFalse)
    p.conditional()
    let je = p.emit(opJmp)
    if not p.take(":"): p.fail("a ':' is missing")
    p.code[jf].arg = p.code.len
    p.conditional()
    p.code[je].arg = p.code.len

proc expr(p: var Parser) =
  p.conditional()

proc compileFormula*(s: string): Code =
  ## A formula made ready to run. Raises `FactoryError` when it cannot be
  ## read.
  var p = Parser(s: s)
  if s.strip.len == 0: p.fail("the formula is empty")
  p.expr()
  p.skipSpace()
  if p.pos < p.s.len: p.fail("'" & p.s[p.pos ..< min(p.s.len, p.pos + 8)] & "' is not understood")
  result.ins = p.code
  result.identity = -1
  if p.code.len == 1 and p.code[0].op == opVar and p.code[0].arg in 0 .. 4:
    result.identity = p.code[0].arg

# ---- running it -------------------------------------------------------------------------------------------

type Ctx = object
  vars: array[V, int]
  ctl: array[8, int]
  src: ptr UncheckedArray[uint32]
  sw, sh, ox, oy: int            # the source picture, where the part starts in it
  cells: array[256, int]
  rng: uint32

proc chanOf(p: uint32; z: int): int {.inline.} =
  case z
  of 0: int((p shr 16) and 255)
  of 1: int((p shr 8) and 255)
  of 2: int(p and 255)
  else: int(p shr 24)

proc sample(c: var Ctx; x, y, z: int): int {.inline.} =
  let xx = clamp(x + c.ox, 0, c.sw - 1)
  let yy = clamp(y + c.oy, 0, c.sh - 1)
  chanOf(c.src[yy * c.sw + xx], clamp(z, 0, 3))

proc fsin(x: int): int {.inline.} = int(round(sin(x.float * 2 * PI / 1024) * 512))
proc fcos(x: int): int {.inline.} = int(round(cos(x.float * 2 * PI / 1024) * 512))

{.push overflowChecks: off, rangeChecks: off.}

proc run(code: Code; c: var Ctx): int =
  var stack: array[64, int]
  var sp = 0
  var pc = 0
  let n = code.ins.len
  while pc < n:
    let ins = code.ins[pc]
    inc pc
    case ins.op
    of opConst:
      stack[sp] = ins.arg
      inc sp
    of opVar:
      stack[sp] = c.vars[V(ins.arg)]
      inc sp
    of opNeg: stack[sp - 1] = -stack[sp - 1]
    of opNot: stack[sp - 1] = ord(stack[sp - 1] == 0)
    of opBitNot: stack[sp - 1] = not stack[sp - 1]
    of opAdd .. opOr:
      let b = stack[sp - 1]
      let a = stack[sp - 2]
      dec sp
      stack[sp - 1] =
        case ins.op
        of opAdd: a + b
        of opSub: a - b
        of opMul: a * b
        of opDiv: (if b == 0: 0 else: a div b)
        of opMod: (if b == 0: 0 else: a mod b)
        of opShl: (if b < 0 or b > 62: 0 else: a shl b)
        of opShr: (if b < 0 or b > 62: 0 else: a shr b)
        of opLt: ord(a < b)
        of opGt: ord(a > b)
        of opLe: ord(a <= b)
        of opGe: ord(a >= b)
        of opEq: ord(a == b)
        of opNe: ord(a != b)
        of opAnd: a and b
        of opXor: a xor b
        else: a or b
    of opJmpFalse:
      dec sp
      if stack[sp] == 0: pc = ins.arg
    of opJmp: pc = ins.arg
    of opJmpFalseKeep:
      if stack[sp - 1] == 0:
        stack[sp - 1] = 0
        pc = ins.arg
    of opJmpTrueKeep:
      if stack[sp - 1] != 0:
        stack[sp - 1] = 1
        pc = ins.arg
    of opBool: stack[sp - 1] = ord(stack[sp - 1] != 0)
    of opPop: dec sp
    of opCall:
      let k = ins.n
      sp -= k
      template A(i: int): int = stack[sp + i]
      var v = 0
      case Fn(ins.arg)
      of fnCtl: v = c.ctl[clamp(A(0), 0, 7)]
      of fnVal: v = c.ctl[clamp(A(0), 0, 7)] * (A(2) - A(1)) div 255 + A(1)
      of fnMap: v = c.ctl[clamp(A(0) * 2 + int(A(1) > 127), 0, 7)]
      of fnMin: v = min(A(0), A(1))
      of fnMax: v = max(A(0), A(1))
      of fnAbs: v = abs(A(0))
      of fnAdd: v = min(A(0) + A(1), A(2))
      of fnSub: v = max(A(0) - A(1), A(2))
      of fnDif: v = abs(A(0) - A(1))
      of fnMix: v = (if A(3) == 0: 0 else: (A(0) * A(2) + A(1) * (A(3) - A(2))) div A(3))
      of fnScl: v = (if A(2) == A(1): A(3) else: A(3) + (A(0) - A(1)) * (A(4) - A(3)) div (A(2) - A(1)))
      of fnSqr: v = (if A(0) <= 0: 0 else: int(sqrt(A(0).float)))
      of fnSin: v = fsin(A(0))
      of fnCos: v = fcos(A(0))
      of fnTan:
        let t = tan(A(0).float * 2 * PI / 1024) * 1024
        v = if abs(t) > 1e9: 0 else: int(t)
      of fnRnd:
        c.rng = c.rng * 1664525'u32 + 1013904223'u32
        let lo = min(A(0), A(1))
        let hi = max(A(0), A(1))
        v = lo + int((c.rng shr 8) mod uint32(hi - lo + 1))
      of fnSrc: v = c.sample(A(0), A(1), A(2))
      of fnRad:
        let a = A(0).float * 2 * PI / 1024
        let x = int(round(cos(a) * A(1).float)) + c.vars[vXX] div 2
        let y = int(round(sin(a) * A(1).float)) + c.vars[vYY] div 2
        v = c.sample(x, y, A(2))
      of fnC2d: v = int(round(arctan2(A(1).float, A(0).float) * 512 / PI))
      of fnC2m: v = int(sqrt(float(A(0) * A(0) + A(1) * A(1))))
      of fnR2x: v = int(round(cos(A(0).float * 2 * PI / 1024) * A(1).float))
      of fnR2y: v = int(round(sin(A(0).float * 2 * PI / 1024) * A(1).float))
      of fnGet: v = c.cells[A(0) and 255]
      of fnPut:
        c.cells[A(1) and 255] = A(0)
        v = A(0)
      of fnCnv:
        # a 3 x 3 convolution of the channel: m11..m33, divisor
        var acc = 0
        var k2 = 0
        for dy in -1 .. 1:
          for dx in -1 .. 1:
            acc += A(k2) * c.sample(c.vars[vX] + dx, c.vars[vY] + dy, c.vars[vZ])
            inc k2
        v = if A(9) == 0: acc else: acc div A(9)
      stack[sp] = v
      inc sp
    if sp >= 60: return 0
  if sp > 0: stack[sp - 1] else: 0

{.pop.}

proc compileFilter*(f: FactoryFilter): CompiledFilter =
  ## The filter made ready to run. Raises `FactoryError` (naming the channel)
  ## when a formula cannot be read.
  result.f = f
  for k, (name, s) in [("R", f.r), ("G", f.g), ("B", f.b), ("A", f.a)]:
    try: result.code[k] = compileFormula(if s.strip.len == 0: ["r", "g", "b", "a"][k] else: s)
    except FactoryError as e: raise newException(FactoryError, name & ": " & e.msg)

proc filterFn*(cf: CompiledFilter; ctl: openArray[int]): FilterFn =
  ## The filter with its sliders at `ctl` (0..255), as a filter of
  ## `retroui/photofx` (its x, y, X, Y: within the part filtered).
  var ctls: array[8, int]
  for i in 0 ..< min(8, ctl.len): ctls[i] = clamp(ctl[i], 0, 255)
  let code = cf.code
  result = proc (src: Img; inner: Rect): Img =
    var o = src
    let w = inner.w
    let h = inner.h
    if w <= 0 or h <= 0: return
    let sp = cast[ptr UncheckedArray[uint32]](unsafeAddr src.px[0])
    let dp = cast[ptr UncheckedArray[uint32]](addr o.px[0])
    let sw = src.w
    let sh = src.h
    let ox = inner.x
    let oy = inner.y
    let codeP = unsafeAddr code
    let maxM = int(sqrt(float(w * w + h * h)) / 2)
    parallelChunks(h, lo, hi):
      var c = Ctx(ctl: ctls, src: sp, sw: sw, sh: sh, ox: ox, oy: oy)
      c.rng = uint32((lo * 40503 + 12345) and 0x7FFF_FFFF)
      c.vars[vXX] = w
      c.vars[vYY] = h
      c.vars[vZZ] = 4
      c.vars[vDD] = 1024
      c.vars[vMM] = maxM
      for y in lo ..< hi:
        for x in 0 ..< w:
          let i = (y + oy) * sw + (x + ox)
          let p = sp[i]
          let r = int((p shr 16) and 255)
          let g = int((p shr 8) and 255)
          let b = int(p and 255)
          let a = int(p shr 24)
          c.vars[vR] = r; c.vars[vG] = g; c.vars[vB] = b; c.vars[vA] = a
          c.vars[vI] = (r * 299 + g * 587 + b * 114) div 1000
          c.vars[vU] = (b - c.vars[vI]) * 492 div 1000
          c.vars[vV] = (r - c.vars[vI]) * 877 div 1000
          c.vars[vX] = x
          c.vars[vY] = y
          let dx = x - w div 2
          let dy = y - h div 2
          c.vars[vD] = int(round(arctan2(dy.float, dx.float) * 512 / PI))
          c.vars[vM] = int(sqrt(float(dx * dx + dy * dy)))
          var outc: array[4, int]
          for z in 0 .. 3:
            let cd = codeP[][z]
            if cd.identity >= 0:
              outc[z] = c.vars[V(cd.identity)]
              if cd.identity == 4: outc[z] = chanOf(p, z)
            else:
              c.vars[vZ] = z
              c.vars[vC] = chanOf(p, z)
              outc[z] = run(cd, c)
          dp[i] = (uint32(clamp(outc[3], 0, 255)) shl 24) or (uint32(clamp(outc[0], 0, 255)) shl 16) or
                  (uint32(clamp(outc[1], 0, 255)) shl 8) or uint32(clamp(outc[2], 0, 255))
    o

# ---- plug-in files ----------------------------------------------------------------------------------------

proc toJson*(f: FactoryFilter): JsonNode =
  ## The filter as JSON (a plug-in file's contents; see `filterFrom`).
  var sl = newJArray()
  for i in 0 .. 7:
    if f.sliders[i].len > 0: sl.add %*{"n": i, "name": f.sliders[i], "value": f.values[i]}
  %*{"format": "Retro Photo Filter Factory", "version": 1, "name": f.name, "category": f.category,
     "author": f.author, "about": f.about, "sliders": sl, "r": f.r, "g": f.g, "b": f.b, "a": f.a}

proc filterFrom*(j: JsonNode): FactoryFilter =
  ## A filter saved with `toJson` (a plug-in file's contents).
  if j == nil or j.kind != JObject: raise newException(FactoryError, "not a Filter Factory filter")
  result.name = j{"name"}.getStr("Untitled").strip
  if result.name.len == 0: result.name = "Untitled"
  result.category = j{"category"}.getStr("Filter Factory").strip
  if result.category.len == 0: result.category = "Filter Factory"
  result.author = j{"author"}.getStr
  result.about = j{"about"}.getStr
  for s in j{"sliders"}.getElems:
    let n = s{"n"}.getInt(-1)
    if n in 0 .. 7:
      result.sliders[n] = s{"name"}.getStr
      result.values[n] = clamp(s{"value"}.getInt(0), 0, 255)
  result.r = j{"r"}.getStr("r")
  result.g = j{"g"}.getStr("g")
  result.b = j{"b"}.getStr("b")
  result.a = j{"a"}.getStr("a")

const pluginExt* = ".rpf"
  ## The ending of plug-in files.

proc savePlugin*(f: FactoryFilter; dir: string): string =
  ## Writes the filter as a plug-in file in `dir`; its path.
  createDir(dir)
  var base = ""
  for ch in f.name:
    if ch.isAlphaNumeric or ch in {' ', '-', '_'}: base.add ch
  if base.strip.len == 0: base = "filter"
  result = dir / base.strip & pluginExt
  writeFile(result, pretty(f.toJson))

proc loadPlugins*(dir: string): seq[FactoryFilter] =
  ## The plug-ins in `dir` (the ones that cannot be read are left out).
  if not dirExists(dir): return
  for kind, path in walkDir(dir):
    if kind != pcFile or not path.endsWith(pluginExt): continue
    try:
      let f = filterFrom(parseJson(readFile(path)))
      discard compileFilter(f)
      result.add f
    except CatchableError: discard

proc builtInPlugins*(): seq[FactoryFilter] =
  ## The plug-ins that come with it (made with Filter Factory).
  proc ff(name, cat, about: string; sliders: openArray[(string, int)]; r, g, b: string; a = "a"): FactoryFilter =
    result = FactoryFilter(name: name, category: cat, author: "Retro Photo", about: about, r: r, g: g, b: b, a: a)
    for i, (n, v) in sliders:
      result.sliders[i] = n
      result.values[i] = v
  @[
    ff("Sepia Tone", "Color", "An old photograph's brown.", [("Warmth", 80), ("Fade", 30)],
       "scl(i + ctl(0) / 3, 0, 255 + ctl(0) / 3, ctl(1) / 2, 255)", "scl(i + ctl(0) / 8, 0, 255 + ctl(0) / 8, ctl(1) / 2, 245)",
       "scl(i - ctl(0) / 6, 0, 255, ctl(1) / 2, 215)"),
    ff("Channel Swap", "Color", "The red, green and blue change places.", [("Order", 0)],
       "ctl(0) < 85 ? g : ctl(0) < 170 ? b : r", "ctl(0) < 85 ? b : ctl(0) < 170 ? r : g",
       "ctl(0) < 85 ? r : ctl(0) < 170 ? g : b"),
    ff("Duotone Glow", "Color", "The lights in one color, the shadows in another.", [("Light Red", 255), ("Light Blue", 120), ("Shadow Red", 30)],
       "mix(ctl(0), ctl(2), i, 255)", "mix(i, i / 3, i, 255)", "mix(ctl(1), 90, i, 255)"),
    ff("Psychedelic", "Color", "Colors wrapped round and round.", [("Cycles", 3), ("Shift", 0)],
       "(r * (ctl(0) + 1) + ctl(1)) % 256", "(g * (ctl(0) + 1) + ctl(1) * 2) % 256", "(b * (ctl(0) + 1) + ctl(1) * 3) % 256"),
    ff("Ripples", "Distort", "Water rings from the middle.", [("Height", 6), ("Spacing", 40)],
       "rad(d, m + sin(m * 1024 / (ctl(1) + 4)) * ctl(0) / 512, z)", "rad(d, m + sin(m * 1024 / (ctl(1) + 4)) * ctl(0) / 512, z)",
       "rad(d, m + sin(m * 1024 / (ctl(1) + 4)) * ctl(0) / 512, z)", "rad(d, m + sin(m * 1024 / (ctl(1) + 4)) * ctl(0) / 512, z)"),
    ff("Kaleidoscope", "Distort", "The picture turned into mirrored wedges.", [("Wedges", 6)],
       "rad(abs(((d + 1024) % (1024 / (ctl(0) / 2 + 2))) - 512 / (ctl(0) / 2 + 2)), m, z)",
       "rad(abs(((d + 1024) % (1024 / (ctl(0) / 2 + 2))) - 512 / (ctl(0) / 2 + 2)), m, z)",
       "rad(abs(((d + 1024) % (1024 / (ctl(0) / 2 + 2))) - 512 / (ctl(0) / 2 + 2)), m, z)",
       "rad(abs(((d + 1024) % (1024 / (ctl(0) / 2 + 2))) - 512 / (ctl(0) / 2 + 2)), m, z)"),
    ff("Mirror Tiles", "Distort", "Mirrored tiles of the picture.", [("Across", 2), ("Down", 2)],
       "src(abs((x * (ctl(0) + 1)) % (2 * X) - X), abs((y * (ctl(1) + 1)) % (2 * Y) - Y), z)",
       "src(abs((x * (ctl(0) + 1)) % (2 * X) - X), abs((y * (ctl(1) + 1)) % (2 * Y) - Y), z)",
       "src(abs((x * (ctl(0) + 1)) % (2 * X) - X), abs((y * (ctl(1) + 1)) % (2 * Y) - Y), z)",
       "src(abs((x * (ctl(0) + 1)) % (2 * X) - X), abs((y * (ctl(1) + 1)) % (2 * Y) - Y), z)"),
    ff("Pixel Blocks", "Stylize", "Big square pixels.", [("Size", 12)],
       "src(x - x % (ctl(0) + 2), y - y % (ctl(0) + 2), z)", "src(x - x % (ctl(0) + 2), y - y % (ctl(0) + 2), z)",
       "src(x - x % (ctl(0) + 2), y - y % (ctl(0) + 2), z)", "src(x - x % (ctl(0) + 2), y - y % (ctl(0) + 2), z)"),
    ff("Vignette", "Stylize", "Darker toward the corners.", [("Amount", 140), ("Size", 120)],
       "c * (255 - max(0, (m * 255 / M - ctl(1)) * ctl(0) / 255)) / 255",
       "c * (255 - max(0, (m * 255 / M - ctl(1)) * ctl(0) / 255)) / 255",
       "c * (255 - max(0, (m * 255 / M - ctl(1)) * ctl(0) / 255)) / 255"),
    ff("Scan Lines", "Stylize", "The lines of an old screen.", [("Darkness", 90), ("Spacing", 3)],
       "y % (ctl(1) / 2 + 2) == 0 ? c * (255 - ctl(0)) / 255 : c",
       "y % (ctl(1) / 2 + 2) == 0 ? c * (255 - ctl(0)) / 255 : c",
       "y % (ctl(1) / 2 + 2) == 0 ? c * (255 - ctl(0)) / 255 : c"),
    ff("Emboss Relief", "Stylize", "A gray relief, lit from the top left.", [("Depth", 2)],
       "128 + (cnv(-1, -1, 0, -1, 0, 1, 0, 1, 1, 1) * (ctl(0) + 1)) / 2",
       "128 + (cnv(-1, -1, 0, -1, 0, 1, 0, 1, 1, 1) * (ctl(0) + 1)) / 2",
       "128 + (cnv(-1, -1, 0, -1, 0, 1, 0, 1, 1, 1) * (ctl(0) + 1)) / 2"),
    ff("Noise Grain", "Noise", "Film grain.", [("Amount", 40)],
       "c + rnd(-ctl(0), ctl(0)) / 2", "c + rnd(-ctl(0), ctl(0)) / 2", "c + rnd(-ctl(0), ctl(0)) / 2")]

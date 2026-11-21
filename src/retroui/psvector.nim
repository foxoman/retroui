## PostScript's drawing read as vectors: a small interpreter of the language -- its stack,
## dictionaries, procedures, arithmetic, loops and conditions -- enough for the EPS files
## drawing programs write (their procedures for moveto, lineto, curveto and the rest defined
## at the top), its paths filled and stroked becoming shapes in their colors (gray, RGB,
## CMYK), widths and dashes, through the transformations; text, pictures and clipping left out.
##
## ```nim
## let pic = psShapes(readFile("logo.eps"))
## for s in pic.shapes: discard d.addShapeLayer(s)
## ```
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, math, tables]
import photo, photoshapes

type
  PsError* = object of CatchableError

  PsKind = enum pkNull, pkNum, pkBool, pkName, pkLit, pkStr, pkArr, pkProc, pkDict, pkMark, pkOp

  PsObj = ref object
    case kind: PsKind
    of pkNum: n: float
    of pkBool: b: bool
    of pkName, pkLit, pkStr, pkOp: s: string
    of pkArr, pkProc: a: seq[PsObj]
    of pkDict: d: TableRef[string, PsObj]
    else: discard

  GState = object
    ctm: array[6, float]
    color: uint32
    width: float
    cap, join: int
    dash: seq[float]

  Interp = object
    stack: seq[PsObj]
    dicts: seq[TableRef[string, PsObj]]
    gs: GState
    saved: seq[GState]
    path: Path
    curX, curY: float          # (the current point, in user space)
    hasPoint: bool
    shapes: seq[ShapeData]
    steps: int
    stop: bool

const MaxSteps = 20_000_000

proc num(v: float): PsObj = PsObj(kind: pkNum, n: v)
proc boolean(v: bool): PsObj = PsObj(kind: pkBool, b: v)

# ---- reading the program -----------------------------------------------------------------------------------

proc parse(src: string; i: var int; depth = 0): seq[PsObj] =
  ## (the objects of `src` from `i` to its end -- or to the `}` of the procedure being read)
  if depth > 200: raise newException(PsError, "too deep")
  while i < src.len:
    let c = src[i]
    case c
    of ' ', '\t', '\r', '\n', '\f', '\0': inc i
    of '%':
      while i < src.len and src[i] notin {'\n', '\r'}: inc i
    of '{':
      inc i
      result.add PsObj(kind: pkProc, a: parse(src, i, depth + 1))
    of '}':
      inc i
      if depth > 0: return
    of '[', ']':
      result.add PsObj(kind: pkName, s: $c)
      inc i
    of '(':
      # (a string: nested parentheses kept, escapes read)
      inc i
      var s = ""
      var lvl = 1
      while i < src.len:
        let ch = src[i]
        if ch == '\\' and i + 1 < src.len:
          let n = src[i + 1]
          case n
          of 'n': s.add '\n'
          of 'r': s.add '\r'
          of 't': s.add '\t'
          of '0' .. '7':
            var v = 0
            var k = 0
            while k < 3 and i + 1 + k < src.len and src[i + 1 + k] in {'0' .. '7'}:
              v = v * 8 + ord(src[i + 1 + k]) - ord('0')
              inc k
            s.add char(v and 255)
            i += k - 1
          of '\n': discard
          else: s.add n
          i += 2
          continue
        if ch == '(': inc lvl
        elif ch == ')':
          dec lvl
          if lvl == 0:
            inc i
            break
        s.add ch
        inc i
      result.add PsObj(kind: pkStr, s: s)
    of '<':
      if i + 1 < src.len and src[i + 1] == '<':
        result.add PsObj(kind: pkName, s: "<<")
        i += 2
      elif i + 1 < src.len and src[i + 1] == '~':
        # (ASCII85: skipped, as a string)
        let e = src.find("~>", i)
        i = if e < 0: src.len else: e + 2
        result.add PsObj(kind: pkStr, s: "")
      else:
        inc i
        var hex = ""
        while i < src.len and src[i] != '>':
          if src[i] in HexDigits: hex.add src[i]
          inc i
        inc i
        if hex.len mod 2 == 1: hex.add '0'
        var s = ""
        for k in countup(0, hex.len - 2, 2): s.add char(parseHexInt(hex[k .. k + 1]))
        result.add PsObj(kind: pkStr, s: s)
    of '>':
      if i + 1 < src.len and src[i + 1] == '>':
        result.add PsObj(kind: pkName, s: ">>")
        i += 2
      else: inc i
    of '/':
      inc i
      let lit = i < src.len and src[i] == '/'      # (//name: the name looked up now, as a literal here)
      if lit: inc i
      var s = ""
      while i < src.len and src[i] notin {' ', '\t', '\r', '\n', '\f', '(', ')', '<', '>', '[', ']', '{', '}', '/', '%'}:
        s.add src[i]
        inc i
      result.add PsObj(kind: pkLit, s: s)
    else:
      var s = ""
      while i < src.len and src[i] notin {' ', '\t', '\r', '\n', '\f', '(', ')', '<', '>', '[', ']', '{', '}', '/', '%'}:
        s.add src[i]
        inc i
      if s.len == 0:
        inc i
        continue
      var v = 0.0
      var isNum = false
      if s[0] in {'0' .. '9', '-', '+', '.'}:
        let hashAt = s.find('#')
        if hashAt > 0:
          # (a number in a base: 16#FF)
          let base = try: parseInt(s[0 ..< hashAt]) except ValueError: 0
          if base in 2 .. 36:
            var acc = 0
            isNum = true
            for ch in s[hashAt + 1 .. ^1].toLowerAscii:
              let dv = if ch in {'0' .. '9'}: ord(ch) - ord('0') elif ch in {'a' .. 'z'}: ord(ch) - ord('a') + 10 else: 99
              if dv >= base:
                isNum = false
                break
              acc = acc * base + dv
            v = acc.float
        else:
          try:
            v = parseFloat(s)
            isNum = true
          except ValueError: isNum = false
      if isNum: result.add num(v)
      elif s == "true": result.add boolean(true)
      elif s == "false": result.add boolean(false)
      else: result.add PsObj(kind: pkName, s: s)

# ---- the interpreter ----------------------------------------------------------------------------------------

proc pop(it: var Interp): PsObj =
  if it.stack.len == 0: raise newException(PsError, "stack underflow")
  it.stack.pop

proc popNum(it: var Interp): float =
  let o = it.pop
  if o.kind == pkNum: o.n
  elif o.kind == pkBool: (if o.b: 1.0 else: 0.0)
  else: raise newException(PsError, "a number was wanted")

proc push(it: var Interp; o: PsObj) =
  if it.stack.len > 100_000: raise newException(PsError, "stack overflow")
  it.stack.add o

proc lookup(it: Interp; name: string): PsObj =
  for k in countdown(it.dicts.high, 0):
    let d = it.dicts[k]
    if d.hasKey(name): return d[name]
  nil

proc toDevice(it: Interp; x, y: float): (float, float) =
  let m = it.gs.ctm
  (m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5])

proc concat(it: var Interp; a, b, c, d, e, f: float) =
  let m = it.gs.ctm
  it.gs.ctm = [a * m[0] + b * m[2], a * m[1] + b * m[3], c * m[0] + d * m[2], c * m[1] + d * m[3],
               e * m[0] + f * m[2] + m[4], e * m[1] + f * m[3] + m[5]]

proc pointTo(it: var Interp; x, y: float; newSub: bool) =
  let (dx, dy) = it.toDevice(x, y)
  if newSub or it.path.subs.len == 0 or not it.hasPoint: it.path.subs.add SubPath()
  it.path.subs[^1].pts.add PathPoint(p: (dx, dy), inH: (dx, dy), outH: (dx, dy))
  it.curX = x
  it.curY = y
  it.hasPoint = true

proc curveTo(it: var Interp; x1, y1, x2, y2, x3, y3: float) =
  if not it.hasPoint: it.pointTo(x1, y1, true)
  let (a, b) = it.toDevice(x1, y1)
  let (c, d) = it.toDevice(x2, y2)
  let (e, f) = it.toDevice(x3, y3)
  it.path.subs[^1].pts[^1].outH = (a, b)
  it.path.subs[^1].pts.add PathPoint(p: (e, f), inH: (c, d), outH: (e, f))
  it.curX = x3
  it.curY = y3

proc arcTo(it: var Interp; cx, cy, r, a0, a1: float; neg: bool) =
  ## (an arc as Bezier pieces of at most a quarter turn; a line to its start first)
  var s = degToRad(a0)
  var e = degToRad(a1)
  if neg:
    while e > s: e -= 2 * PI
  else:
    while e < s: e += 2 * PI
  let sx = cx + r * cos(s)
  let sy = cy + r * sin(s)
  it.pointTo(sx, sy, not it.hasPoint)
  let n = max(1, int(ceil(abs(e - s) / (PI / 2) - 1e-9)))
  let step = (e - s) / n.float
  for k in 0 ..< n:
    let t0 = s + step * k.float
    let t1 = t0 + step
    let h = 4 / 3 * tan((t1 - t0) / 4)
    let (c0, s0) = (cos(t0), sin(t0))
    let (c1, s1) = (cos(t1), sin(t1))
    it.curveTo(cx + r * (c0 - h * s0), cy + r * (s0 + h * c0), cx + r * (c1 + h * s1), cy + r * (s1 - h * c1),
               cx + r * c1, cy + r * s1)

proc paint(it: var Interp; fill: bool; evenOdd = false) =
  var p = it.path
  it.path = Path()
  it.hasPoint = false
  var any = false
  for sp in p.subs:
    if sp.pts.len >= 2: any = true
  if not any: return
  var s = ShapeData(kind: "Path", path: p)
  # (all its pieces one part: filled by their winding, holes and all)
  for k in 1 ..< s.path.subs.len: s.path.subs[k].joined = true
  if fill:
    for sp in s.path.subs.mitems: sp.closed = true
    s.fill = solidPaint(it.gs.color)
  else:
    let m = it.gs.ctm
    let k = sqrt(abs(m[0] * m[3] - m[1] * m[2]))
    s.stroke = solidPaint(it.gs.color)
    s.strokeWidth = max(0.5, it.gs.width * k)
    s.align = saCenter
    s.cap = [lcButt, lcRound, lcSquare][clamp(it.gs.cap, 0, 2)]
    s.join = [ljMiter, ljRound, ljBevel][clamp(it.gs.join, 0, 2)]
    if it.gs.dash.len > 0 and s.strokeWidth > 0:
      for v in it.gs.dash: s.dashes.add max(0.0, v * k / s.strokeWidth)
  it.shapes.add s

proc rgb(r, g, b: float): uint32 =
  0xFF000000'u32 or (uint32(clamp(int(round(r * 255)), 0, 255)) shl 16) or
    (uint32(clamp(int(round(g * 255)), 0, 255)) shl 8) or uint32(clamp(int(round(b * 255)), 0, 255))

proc exec(it: var Interp; o: PsObj; depth = 0)

proc execProc(it: var Interp; p: PsObj; depth: int) =
  if p.kind == pkProc:
    for x in p.a:
      if it.stop: return
      it.exec(x, depth + 1)
  else: it.exec(p, depth + 1)

type ExitLoop = object of CatchableError

proc op(it: var Interp; name: string; depth: int): bool =
  ## (an operator of the language; false: not one known)
  result = true
  case name
  # stack
  of "pop": discard it.pop
  of "exch":
    let b = it.pop
    let a = it.pop
    it.push b
    it.push a
  of "dup":
    let a = it.pop
    it.push a
    it.push a
  of "copy":
    let n = int(it.popNum)
    if n < 0 or n > it.stack.len: raise newException(PsError, "copy")
    let s = it.stack.len - n
    for k in 0 ..< n: it.push it.stack[s + k]
  of "index":
    let n = int(it.popNum)
    if n < 0 or n >= it.stack.len: raise newException(PsError, "index")
    it.push it.stack[it.stack.high - n]
  of "roll":
    let j = int(it.popNum)
    let n = int(it.popNum)
    if n < 0 or n > it.stack.len: raise newException(PsError, "roll")
    if n > 0:
      let s = it.stack.len - n
      var part = it.stack[s .. ^1]
      let jj = ((j mod n) + n) mod n
      for k in 0 ..< n: it.stack[s + (k + jj) mod n] = part[k]
  of "clear": it.stack.setLen(0)
  of "count": it.push num(it.stack.len.float)
  of "mark", "[", "<<": it.push PsObj(kind: pkMark)
  of "cleartomark":
    while it.stack.len > 0 and it.stack[^1].kind != pkMark: discard it.stack.pop
    if it.stack.len > 0: discard it.stack.pop
  of "counttomark":
    var k = it.stack.high
    while k >= 0 and it.stack[k].kind != pkMark: dec k
    it.push num(float(it.stack.high - k))
  of "]":
    var a: seq[PsObj]
    while it.stack.len > 0 and it.stack[^1].kind != pkMark: a.insert(it.stack.pop, 0)
    if it.stack.len > 0: discard it.stack.pop
    it.push PsObj(kind: pkArr, a: a)
  of ">>":
    var items: seq[PsObj]
    while it.stack.len > 0 and it.stack[^1].kind != pkMark: items.insert(it.stack.pop, 0)
    if it.stack.len > 0: discard it.stack.pop
    let d = newTable[string, PsObj]()
    for k in countup(0, items.len - 2, 2):
      let key = items[k]
      if key.kind in {pkLit, pkName, pkStr}: d[key.s] = items[k + 1]
    it.push PsObj(kind: pkDict, d: d)
  # arithmetic
  of "add", "sub", "mul", "div", "idiv", "mod", "atan", "exp", "max", "min":
    let b = it.popNum
    let a = it.popNum
    var t = radToDeg(arctan2(a, b))
    if t < 0: t += 360
    it.push num(case name
                of "add": a + b
                of "sub": a - b
                of "mul": a * b
                of "div": (if b == 0: 0.0 else: a / b)
                of "idiv": (if int(b) == 0: 0.0 else: float(int(a) div int(b)))
                of "mod": (if int(b) == 0: 0.0 else: float(int(a) mod int(b)))
                of "atan": t
                of "exp": pow(a, b)
                of "max": max(a, b)
                else: min(a, b))
  of "neg", "abs", "sqrt", "sin", "cos", "round", "floor", "ceiling", "truncate", "cvi", "cvr", "ln", "log":
    let a = it.popNum
    it.push num(case name
                of "neg": -a
                of "abs": abs(a)
                of "sqrt": sqrt(max(0.0, a))
                of "sin": sin(degToRad(a))
                of "cos": cos(degToRad(a))
                of "round": floor(a + 0.5)
                of "floor": floor(a)
                of "ceiling": ceil(a)
                of "truncate", "cvi": trunc(a)
                of "ln": (if a > 0: ln(a) else: 0.0)
                of "log": (if a > 0: log10(a) else: 0.0)
                else: a)
  # comparison and logic
  of "eq", "ne":
    let b = it.pop
    let a = it.pop
    var same = a.kind == b.kind
    if same:
      case a.kind
      of pkNum: same = a.n == b.n
      of pkBool: same = a.b == b.b
      of pkName, pkLit, pkStr, pkOp: same = a.s == b.s
      else: same = a == b
    elif a.kind in {pkName, pkLit, pkStr} and b.kind in {pkName, pkLit, pkStr}: same = a.s == b.s
    it.push boolean(if name == "eq": same else: not same)
  of "gt", "ge", "lt", "le":
    let b = it.popNum
    let a = it.popNum
    it.push boolean(case name
                    of "gt": a > b
                    of "ge": a >= b
                    of "lt": a < b
                    else: a <= b)
  of "and", "or", "xor":
    let b = it.pop
    let a = it.pop
    if a.kind == pkBool and b.kind == pkBool:
      it.push boolean(case name
                      of "and": a.b and b.b
                      of "or": a.b or b.b
                      else: a.b xor b.b)
    else:
      let x = int(if a.kind == pkNum: a.n else: 0)
      let y = int(if b.kind == pkNum: b.n else: 0)
      it.push num(float(case name
                        of "and": x and y
                        of "or": x or y
                        else: x xor y))
  of "not":
    let a = it.pop
    it.push(if a.kind == pkBool: boolean(not a.b) else: num(float(not int(a.n))))
  # control
  of "if":
    let p = it.pop
    let c = it.pop
    if c.kind == pkBool and c.b: it.execProc(p, depth)
  of "ifelse":
    let p2 = it.pop
    let p1 = it.pop
    let c = it.pop
    it.execProc(if c.kind == pkBool and c.b: p1 else: p2, depth)
  of "exec":
    let p = it.pop
    it.execProc(p, depth)
  of "repeat":
    let p = it.pop
    let n = int(it.popNum)
    try:
      for _ in 0 ..< min(n, 1_000_000):
        if it.stop: break
        it.execProc(p, depth)
    except ExitLoop: discard
  of "for":
    let p = it.pop
    let lim = it.popNum
    let inc0 = it.popNum
    var v = it.popNum
    var k = 0
    try:
      while (inc0 > 0 and v <= lim + 1e-9) or (inc0 < 0 and v >= lim - 1e-9):
        if it.stop or k > 1_000_000: break
        it.push num(v)
        it.execProc(p, depth)
        v += inc0
        inc k
    except ExitLoop: discard
  of "loop":
    let p = it.pop
    var k = 0
    try:
      while not it.stop and k < 1_000_000:
        it.execProc(p, depth)
        inc k
    except ExitLoop: discard
  of "exit": raise newException(ExitLoop, "exit")
  of "forall":
    let p = it.pop
    let a = it.pop
    try:
      case a.kind
      of pkArr, pkProc:
        for x in a.a:
          it.push x
          it.execProc(p, depth)
      of pkDict:
        for k, v in a.d:
          it.push PsObj(kind: pkLit, s: k)
          it.push v
          it.execProc(p, depth)
      of pkStr:
        for ch in a.s:
          it.push num(ord(ch).float)
          it.execProc(p, depth)
      else: discard
    except ExitLoop: discard
  of "stopped":
    let p = it.pop
    try:
      it.execProc(p, depth)
      it.push boolean(false)
    except PsError: it.push boolean(true)
  of "stop", "quit": it.stop = true
  # dictionaries and names
  of "dict":
    discard it.popNum
    it.push PsObj(kind: pkDict, d: newTable[string, PsObj]())
  of "begin":
    let d = it.pop
    if d.kind == pkDict: it.dicts.add d.d
  of "end":
    if it.dicts.len > 2: discard it.dicts.pop
  of "def":
    let v = it.pop
    let k = it.pop
    if k.kind in {pkLit, pkName, pkStr}: it.dicts[^1][k.s] = v
  of "load":
    let k = it.pop
    let v = it.lookup(k.s)
    it.push(if v == nil: PsObj(kind: pkNull) else: v)
  of "where":
    let k = it.pop
    var found = false
    for j in countdown(it.dicts.high, 0):
      if it.dicts[j].hasKey(k.s):
        it.push PsObj(kind: pkDict, d: it.dicts[j])
        it.push boolean(true)
        found = true
        break
    if not found: it.push boolean(false)
  of "known":
    let k = it.pop
    let d = it.pop
    it.push boolean(d.kind == pkDict and d.d.hasKey(k.s))
  of "get":
    let k = it.pop
    let c = it.pop
    case c.kind
    of pkDict: it.push c.d.getOrDefault(k.s, PsObj(kind: pkNull))
    of pkArr, pkProc:
      let i = int(k.n)
      it.push(if i >= 0 and i < c.a.len: c.a[i] else: PsObj(kind: pkNull))
    of pkStr:
      let i = int(k.n)
      it.push num(if i >= 0 and i < c.s.len: ord(c.s[i]).float else: 0.0)
    else: it.push PsObj(kind: pkNull)
  of "put":
    let v = it.pop
    let k = it.pop
    let c = it.pop
    case c.kind
    of pkDict: c.d[k.s] = v
    of pkArr, pkProc:
      let i = int(k.n)
      if i >= 0 and i < c.a.len: c.a[i] = v
    else: discard
  of "currentdict": it.push PsObj(kind: pkDict, d: it.dicts[^1])
  of "userdict", "globaldict", "statusdict", "systemdict", "errordict":
    it.push PsObj(kind: pkDict, d: it.dicts[min(1, it.dicts.high)])
  of "array":
    let n = clamp(int(it.popNum), 0, 100_000)
    it.push PsObj(kind: pkArr, a: newSeq[PsObj](n))
    for x in it.stack[^1].a.mitems: x = PsObj(kind: pkNull)
  of "length":
    let a = it.pop
    it.push num(case a.kind
                of pkArr, pkProc: a.a.len.float
                of pkStr, pkName, pkLit: a.s.len.float
                of pkDict: a.d.len.float
                else: 0.0)
  of "aload":
    let a = it.pop
    if a.kind in {pkArr, pkProc}:
      for x in a.a: it.push x
    it.push a
  of "astore":
    let a = it.pop
    if a.kind == pkArr:
      for k in countdown(a.a.high, 0): a.a[k] = it.pop
    it.push a
  of "string":
    let n = clamp(int(it.popNum), 0, 1_000_000)
    it.push PsObj(kind: pkStr, s: repeat('\0', n))
  of "cvx":
    let a = it.pop
    it.push(case a.kind
            of pkArr: PsObj(kind: pkProc, a: a.a)
            of pkLit: PsObj(kind: pkName, s: a.s)
            else: a)
  of "cvlit":
    let a = it.pop
    it.push(case a.kind
            of pkProc: PsObj(kind: pkArr, a: a.a)
            of pkName: PsObj(kind: pkLit, s: a.s)
            else: a)
  of "xcheck":
    let a = it.pop
    it.push boolean(a.kind in {pkProc, pkName, pkOp})
  of "type":
    let a = it.pop
    it.push PsObj(kind: pkName, s: case a.kind
                                   of pkNum: "realtype"
                                   of pkBool: "booleantype"
                                   of pkName, pkLit: "nametype"
                                   of pkStr: "stringtype"
                                   of pkArr, pkProc: "arraytype"
                                   of pkDict: "dicttype"
                                   of pkMark: "marktype"
                                   of pkOp: "operatortype"
                                   else: "nulltype")
  of "cvs", "cvn":
    if name == "cvs": discard it.pop
    let a = it.pop
    it.push(if name == "cvn": PsObj(kind: pkLit, s: a.s) else: PsObj(kind: pkStr, s: (if a.kind == pkNum: $a.n else: a.s)))
  of "bind", "readonly", "executeonly", "noaccess": discard
  of "null": it.push PsObj(kind: pkNull)
  of "save":
    it.saved.add it.gs
    it.push PsObj(kind: pkNull)
  of "restore":
    discard it.pop
    if it.saved.len > 0: it.gs = it.saved.pop
  # the graphics state
  of "gsave": it.saved.add it.gs
  of "grestore":
    if it.saved.len > 0: it.gs = it.saved.pop
  of "grestoreall", "initgraphics":
    if it.saved.len > 0:
      it.gs = it.saved[0]
      it.saved.setLen(0)
  of "translate":
    let ty = it.popNum
    let tx = it.popNum
    it.concat(1, 0, 0, 1, tx, ty)
  of "scale":
    let sy = it.popNum
    let sx = it.popNum
    it.concat(sx, 0, 0, sy, 0, 0)
  of "rotate":
    let a = degToRad(it.popNum)
    it.concat(cos(a), sin(a), -sin(a), cos(a), 0, 0)
  of "concat":
    let m = it.pop
    if m.kind in {pkArr, pkProc} and m.a.len == 6:
      var v: array[6, float]
      for k in 0 .. 5: v[k] = (if m.a[k].kind == pkNum: m.a[k].n else: 0.0)
      it.concat(v[0], v[1], v[2], v[3], v[4], v[5])
  of "matrix":
    it.push PsObj(kind: pkArr, a: @[num(1), num(0), num(0), num(1), num(0), num(0)])
  of "currentmatrix":
    let m = it.pop
    if m.kind == pkArr and m.a.len == 6:
      for k in 0 .. 5: m.a[k] = num(it.gs.ctm[k])
    it.push m
  of "setmatrix":
    let m = it.pop
    if m.kind in {pkArr, pkProc} and m.a.len == 6:
      for k in 0 .. 5: it.gs.ctm[k] = (if m.a[k].kind == pkNum: m.a[k].n else: 0.0)
  of "setlinewidth": it.gs.width = it.popNum
  of "setlinecap": it.gs.cap = int(it.popNum)
  of "setlinejoin": it.gs.join = int(it.popNum)
  of "setmiterlimit", "setflat", "setstrokeadjust", "setoverprint", "setsmoothness": discard it.pop
  of "setdash":
    discard it.pop
    let a = it.pop
    it.gs.dash.setLen(0)
    if a.kind in {pkArr, pkProc}:
      for x in a.a:
        if x.kind == pkNum: it.gs.dash.add x.n
  of "setgray":
    let g = it.popNum
    it.gs.color = rgb(g, g, g)
  of "setrgbcolor":
    let b = it.popNum
    let g = it.popNum
    let r = it.popNum
    it.gs.color = rgb(r, g, b)
  of "setcmykcolor":
    let k = it.popNum
    let y = it.popNum
    let m = it.popNum
    let c = it.popNum
    it.gs.color = rgb((1 - c) * (1 - k), (1 - m) * (1 - k), (1 - y) * (1 - k))
  of "sethsbcolor":
    let v = it.popNum
    let s = it.popNum
    let h = it.popNum * 6
    let f = h - floor(h)
    let (p, q, t) = (v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f)))
    it.gs.color = case int(floor(h)) mod 6
                  of 0: rgb(v, t, p)
                  of 1: rgb(q, v, p)
                  of 2: rgb(p, v, t)
                  of 3: rgb(p, q, v)
                  of 4: rgb(t, p, v)
                  else: rgb(v, p, q)
  of "setcolorspace": discard it.pop
  of "setcolor":
    # (what the stack holds: one gray, three RGB or four CMYK, above any mark)
    var vs: seq[float]
    while it.stack.len > 0 and it.stack[^1].kind == pkNum and vs.len < 4: vs.insert(it.stack.pop.n, 0)
    case vs.len
    of 1: it.gs.color = rgb(vs[0], vs[0], vs[0])
    of 3: it.gs.color = rgb(vs[0], vs[1], vs[2])
    of 4: it.gs.color = rgb((1 - vs[0]) * (1 - vs[3]), (1 - vs[1]) * (1 - vs[3]), (1 - vs[2]) * (1 - vs[3]))
    else: discard
  # paths
  of "newpath":
    it.path = Path()
    it.hasPoint = false
  of "moveto":
    let y = it.popNum
    let x = it.popNum
    it.pointTo(x, y, true)
  of "rmoveto":
    let dy = it.popNum
    let dx = it.popNum
    it.pointTo(it.curX + dx, it.curY + dy, true)
  of "lineto":
    let y = it.popNum
    let x = it.popNum
    it.pointTo(x, y, false)
  of "rlineto":
    let dy = it.popNum
    let dx = it.popNum
    it.pointTo(it.curX + dx, it.curY + dy, false)
  of "curveto":
    let y3 = it.popNum
    let x3 = it.popNum
    let y2 = it.popNum
    let x2 = it.popNum
    let y1 = it.popNum
    let x1 = it.popNum
    it.curveTo(x1, y1, x2, y2, x3, y3)
  of "rcurveto":
    let y3 = it.popNum
    let x3 = it.popNum
    let y2 = it.popNum
    let x2 = it.popNum
    let y1 = it.popNum
    let x1 = it.popNum
    let (ox, oy) = (it.curX, it.curY)
    it.curveTo(ox + x1, oy + y1, ox + x2, oy + y2, ox + x3, oy + y3)
  of "closepath":
    if it.path.subs.len > 0:
      it.path.subs[^1].closed = true
      if it.path.subs[^1].pts.len > 0:
        # (the current point back where the piece began)
        let m = it.gs.ctm
        let (px, py) = it.path.subs[^1].pts[0].p
        let det = m[0] * m[3] - m[1] * m[2]
        if abs(det) > 1e-12:
          let x = px - m[4]
          let y = py - m[5]
          it.curX = (m[3] * x - m[2] * y) / det
          it.curY = (-m[1] * x + m[0] * y) / det
  of "arc", "arcn":
    let a1 = it.popNum
    let a0 = it.popNum
    let r = it.popNum
    let cy = it.popNum
    let cx = it.popNum
    it.arcTo(cx, cy, r, a0, a1, name == "arcn")
  of "rectfill", "rectstroke", "rectclip":
    let o = it.pop
    var rects: seq[array[4, float]]
    if o.kind in {pkArr, pkProc}:
      var k = 0
      while k + 3 < o.a.len:
        rects.add [o.a[k].n, o.a[k + 1].n, o.a[k + 2].n, o.a[k + 3].n]
        k += 4
    else:
      let h = if o.kind == pkNum: o.n else: 0.0
      let w = it.popNum
      let y = it.popNum
      let x = it.popNum
      rects.add [x, y, w, h]
    if name == "rectclip": return
    let saved = it.path
    it.path = Path()
    for r in rects:
      it.pointTo(r[0], r[1], true)
      it.pointTo(r[0] + r[2], r[1], false)
      it.pointTo(r[0] + r[2], r[1] + r[3], false)
      it.pointTo(r[0], r[1] + r[3], false)
      it.path.subs[^1].closed = true
    it.paint(name == "rectfill")
    it.path = saved
  of "fill", "eofill": it.paint(true, name == "eofill")
  of "stroke": it.paint(false)
  of "clip", "eoclip", "initclip", "clippath": discard
  of "currentpoint":
    it.push num(it.curX)
    it.push num(it.curY)
  of "showpage", "copypage", "erasepage": discard
  # text and pictures: their operands taken, nothing drawn
  of "findfont", "scalefont", "makefont", "definefont", "selectfont", "setfont", "currentfont":
    case name
    of "findfont":
      discard it.pop
      it.push PsObj(kind: pkDict, d: newTable[string, PsObj]())
    of "scalefont", "makefont": discard it.pop
    of "selectfont":
      discard it.pop
      discard it.pop
    of "setfont": discard it.pop
    of "definefont":
      let f = it.pop
      discard it.pop
      it.push f
    else: it.push PsObj(kind: pkDict, d: newTable[string, PsObj]())
  of "show": discard it.pop
  of "ashow":
    discard it.pop
    discard it.pop
    discard it.pop
  of "widthshow", "kshow", "xshow", "yshow", "xyshow", "glyphshow", "awidthshow":
    let n = case name
            of "widthshow": 4
            of "awidthshow": 6
            else: 2
    for _ in 0 ..< n: discard it.pop
  of "stringwidth":
    discard it.pop
    it.push num(0)
    it.push num(0)
  of "image", "imagemask", "colorimage":
    # (a picture: its operands taken; one with its data after it in the file is not skipped)
    if it.stack.len > 0 and it.stack[^1].kind == pkDict: discard it.pop
    else:
      let n = if name == "colorimage": 7 else: 5
      for _ in 0 ..< min(n, it.stack.len): discard it.pop
  of "currentfile", "flushfile", "readstring", "readhexstring", "filter", "closefile":
    discard
  of "print", "==", "=":
    discard it.pop
  of "pstack", "flush", "echo": discard
  of "vmstatus":
    it.push num(0)
    it.push num(0)
    it.push num(1e9)
  of "languagelevel": it.push num(2)
  of "product", "version": it.push PsObj(kind: pkStr, s: "Retro Atelier")
  of "setpagedevice", "setcolortransfer", "settransfer", "setscreen", "sethalftone", "setblackgeneration",
     "setundercolorremoval", "setglobal", "setpacking", "setcolorrendering", "setshared":
    discard it.pop
  of "currentpacking", "currentglobal", "currentshared": it.push boolean(false)
  of "currentlinewidth": it.push num(it.gs.width)
  of "currentgray": it.push num(0)
  of "currentrgbcolor":
    let c = it.gs.color
    it.push num(float((c shr 16) and 255) / 255)
    it.push num(float((c shr 8) and 255) / 255)
    it.push num(float(c and 255) / 255)
  else: result = false

proc exec(it: var Interp; o: PsObj; depth = 0) =
  inc it.steps
  if it.steps > MaxSteps: raise newException(PsError, "too long a program")
  if depth > 400: raise newException(PsError, "too deep")
  if it.stop: return
  case o.kind
  of pkName:
    let v = it.lookup(o.s)
    if v != nil:
      if v.kind == pkProc: it.execProc(v, depth)
      elif v.kind == pkOp: discard it.op(v.s, depth)
      elif v.kind == pkName: it.exec(v, depth + 1)
      else: it.push v
    elif not it.op(o.s, depth):
      discard               # (an operator not known: nothing, as a reader that skips what it cannot draw)
  of pkLit: it.push PsObj(kind: pkLit, s: o.s)
  else: it.push o

proc psShapes*(data: string): tuple[x0, y0, x1, y1: float; shapes: seq[ShapeData]] =
  ## What an EPS or PostScript file draws as shapes, in its own points (y up), with its
  ## bounding box (`%%BoundingBox`, else what it draws). Raises `PsError` on a program it
  ## cannot read; a program that draws nothing gives no shapes.
  var src = data
  if data.len > 30 and data[0 .. 3] == "\xC5\xD0\xD3\xC6":
    # (a DOS EPS: its PostScript part)
    proc le32(at: int): int =
      ord(data[at]) or (ord(data[at + 1]) shl 8) or (ord(data[at + 2]) shl 16) or (ord(data[at + 3]) shl 24)
    let at = le32(4)
    let n = le32(8)
    if at + n <= data.len: src = data[at ..< at + n]
  # (pictures' data after "image" -- binary or hex -- would read as a program: their
  # %%BeginData ... %%EndData and %%BeginBinary parts taken out)
  for (a, b) in [("%%BeginData", "%%EndData"), ("%%BeginBinary", "%%EndBinary"), ("%%BeginPreview", "%%EndPreview")]:
    while true:
      let i = src.find(a)
      if i < 0: break
      let j = src.find(b, i)
      if j < 0:
        src = src[0 ..< i]
        break
      src = src[0 ..< i] & src[j + b.len .. ^1]
  var bb = (0.0, 0.0, 0.0, 0.0)
  var haveBox = false
  for key in ["%%HiResBoundingBox:", "%%BoundingBox:"]:
    let i = src.find(key)
    if i >= 0 and not haveBox:
      let e = src.find('\n', i)
      let parts = src[i + key.len ..< (if e < 0: src.len else: e)].strip.splitWhitespace
      if parts.len >= 4:
        try:
          bb = (parseFloat(parts[0]), parseFloat(parts[1]), parseFloat(parts[2]), parseFloat(parts[3]))
          haveBox = bb[2] > bb[0] and bb[3] > bb[1]
        except ValueError: discard
  var it = Interp(gs: GState(ctm: [1.0, 0, 0, 1, 0, 0], color: 0xFF000000'u32, width: 1))
  it.dicts = @[newTable[string, PsObj](), newTable[string, PsObj]()]
  var i = 0
  let prog = parse(src, i)
  var errors = 0
  for o in prog:
    if it.stop: break
    try: it.exec(o)
    except ExitLoop: discard
    except PsError as e:
      # (an error: that part let go, the rest read on -- as a reader that draws what it can)
      inc errors
      if errors > 2000 or e.msg in ["too long a program", "too deep"]:
        if it.shapes.len == 0: raise
        break
  result.shapes = it.shapes
  if haveBox:
    (result.x0, result.y0, result.x1, result.y1) = bb
  else:
    var x0, y0 = 1e300
    var x1, y1 = -1e300
    for s in it.shapes:
      let b = pathBounds(s.path)
      x0 = min(x0, b[0]); y0 = min(y0, b[1]); x1 = max(x1, b[2]); y1 = max(y1, b[3])
    if x1 > x0: (result.x0, result.y0, result.x1, result.y1) = (x0, y0, x1, y1)

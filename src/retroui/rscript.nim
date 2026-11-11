## Retro Script: a small, safe scripting language that reads like
## JavaScript, so a user who knows Photoshop's scripting feels at home.
## Photoshop's plug-ins (.8bf) can't run on Android; scripts can.
##
## A script is read once (`compile`) and run by an interpreter (`Vm`) that
## keeps the globals. The host -- the app -- gives the script its world:
## functions (`defineFn`), plain objects (`defineObject`) and live objects
## whose properties and methods are the host's own procs (`hostObject`).
## A script can touch nothing else: no files, no OS, no network.
##
## ```nim
## let vm = newVm(proc (s: string) = echo s)       # print() and console.log()
## vm.defineFn("alert", proc (args: seq[Value]): Value =
##   echo "ALERT ", args[0].toStr
##   undefinedValue())
## var opacity = 100.0
## let layer = hostObject(
##   get = proc (key: string): Value =
##     if key == "opacity": toValue(opacity) else: undefinedValue(),
##   set = proc (key: string; v: Value): bool =
##     result = key == "opacity"
##     if result: opacity = v.toNum,
##   call = proc (key: string; args: seq[Value]): Value =
##     if key == "fill": echo "filled"
##     undefinedValue())
## vm.defineObject("app", {"activeLayer": layer, "name": toValue("Retro Photo")})
## discard vm.run(compile("""
##   const l = app.activeLayer
##   l.opacity = l.opacity / 2
##   l.fill()
##   console.log(`${app.name}: opacity ${l.opacity}`)
## """))
## ```
##
## The language
## ============
##
## What JavaScript has and Retro Script has too: `let` `const` `var`;
## numbers (64-bit floats), strings ('…', "…" and templates `…${x}…`),
## `true` `false` `null` `undefined`; arrays and objects (their keys keep
## the order they were made in) with `.` and `[]`; functions with default
## and rest parameters, arrow functions, closures and recursion; `this` in
## methods called as `obj.f()`, `arguments`, `f.call`, `f.apply`, `f.bind`;
## destructuring (`let [a, b] = …`, `const {x, y = 0} = …`, also in
## parameters, `for … of` and assignments); spread `...` in calls, arrays
## and objects; `if`, `while`, `do … while`, `for (;;)`, `for … of`,
## `for … in`, labels, `break`, `continue`, `return`, `switch`,
## `try`/`catch`/`finally`, `throw`; every operator (`?.`, `??`, `**`,
## `>>>`, `&&=` …), `typeof`, `delete`, `in`, `instanceof`; `print(...)`
## and `console.log(...)`.
##
## Built in: the string methods (`length slice substring substr indexOf
## lastIndexOf includes startsWith endsWith split trim trimStart trimEnd
## toUpperCase toLowerCase replace replaceAll padStart padEnd repeat charAt
## charCodeAt codePointAt at concat localeCompare`), `String.fromCharCode`;
## the array methods (`length push pop shift unshift slice splice concat
## join indexOf lastIndexOf includes reverse sort map filter reduce
## reduceRight forEach find findIndex findLast findLastIndex some every fill
## flat flatMap at`), `Array.isArray Array.from Array.of`; `Object.keys
## values entries assign fromEntries`, `obj.hasOwnProperty(k)`; `Math`
## (with a generator that can be seeded: `seedRandom`), `Number`,
## `parseInt`, `parseFloat`, `isNaN`, `isFinite`, `n.toFixed(d)`,
## `n.toPrecision(p)`, `n.toString(radix)`; `JSON.stringify` (with an
## indent) and `JSON.parse`; `Error` (and `TypeError`, `RangeError`, …)
## with `message` and `name`; `Date.now()`.
##
## Not there: regular expressions, classes, prototypes (`new F()` on a
## script function makes a plain object for `this`; nothing is inherited),
## getters and setters, generators, `async`/`await`, `Map`/`Set`, `Symbol`,
## `Date` objects, `eval`, modules, tagged templates, BigInt. With no
## prototypes, `in` and `hasOwnProperty` see only an object's own keys, and
## an Error's `name` and `message` are ordinary keys. Keys keep the order
## they were made in (JavaScript puts integer keys first). Arrays have no
## holes (a hole reads as `undefined`) and take no named properties. A host
## object doesn't list its keys (`Object.keys` gives `[]`). `console.log`
## writes arrays and objects as `[1, "a"]` and `{a: 1}`.
##
## Strings are UTF-8 inside, and `length`, indexes and `charCodeAt` count
## Unicode code points, not UTF-16 units ("é".length is 1, so is
## "😀".length). Assigning to a name never declared makes a global, as in
## old (sloppy) JavaScript; reading one is a ReferenceError. `run` gives the
## value of the last expression statement, as `eval` does.
##
## Safety: every statement and call costs a step and a run stops with a
## `ScriptError` ("the script ran too long") when its budget is spent;
## `cancel` stops it from outside. Calls nest at most `maxDepth` deep (and
## within `maxNativeStack` bytes of the machine's stack), strings and arrays
## stay under `maxStringLen` and `maxArrayLen`. A script catches its own
## errors with `try`, but never the budget or a cancel. `Date.now()` reads
## the clock; nothing else reaches outside.
##
## How it runs: the parser makes a tree, then a resolver gives every
## variable its place -- a slot in the function's frame, or a slot in a
## small environment when a closure keeps it -- so running a script never
## looks a local name up by its spelling. Globals are found once per node.

import std/[math, strutils, tables, algorithm, random]
from std/unicode import nil
from std/times import epochTime

{.push overflowChecks: off.}

# ---- types ---------------------------------------------------------------------------------------------

type
  ValueKind* = enum
    ## What a script value is.
    vkUndefined, vkNull, vkBool, vkNum, vkStr, vkArray, vkObject, vkFunction, vkHost

  MethodId = enum
    mNone = "", mLength = "length",
    mSlice = "slice", mSubstring = "substring", mSubstr = "substr", mIndexOf = "indexOf",
    mLastIndexOf = "lastIndexOf", mIncludes = "includes", mStartsWith = "startsWith",
    mEndsWith = "endsWith", mSplit = "split", mTrim = "trim", mTrimStart = "trimStart",
    mTrimEnd = "trimEnd", mToUpperCase = "toUpperCase", mToLowerCase = "toLowerCase",
    mReplace = "replace", mReplaceAll = "replaceAll", mPadStart = "padStart", mPadEnd = "padEnd",
    mRepeat = "repeat", mCharAt = "charAt", mCharCodeAt = "charCodeAt",
    mCodePointAt = "codePointAt", mAt = "at", mConcat = "concat", mLocaleCompare = "localeCompare",
    mToString = "toString", mValueOf = "valueOf",
    mPush = "push", mPop = "pop", mShift = "shift", mUnshift = "unshift", mSplice = "splice",
    mJoin = "join", mReverse = "reverse", mSort = "sort", mMap = "map", mFilter = "filter",
    mReduce = "reduce", mReduceRight = "reduceRight", mForEach = "forEach", mFind = "find",
    mFindIndex = "findIndex", mFindLast = "findLast", mFindLastIndex = "findLastIndex",
    mSome = "some", mEvery = "every", mFill = "fill", mFlat = "flat", mFlatMap = "flatMap",
    mToFixed = "toFixed", mToPrecision = "toPrecision", mHasOwnProperty = "hasOwnProperty",
    mCall = "call", mApply = "apply", mBind = "bind"

  NodeKind = enum
    nkEmpty, nkConst, nkTemplate, nkIdent, nkLocal, nkEnvVar, nkGlobal,
    nkArray, nkObject, nkProp, nkSpread, nkHole, nkFunc,
    nkMember, nkIndex, nkCall, nkNew, nkOptChain,
    nkNeg, nkPos, nkNot, nkBitNot, nkTypeof, nkVoid, nkDelete,
    nkAdd, nkSub, nkMul, nkDiv, nkMod, nkPow, nkEq, nkNe, nkSeq, nkSne,
    nkLt, nkLe, nkGt, nkGe, nkBitAnd, nkBitOr, nkBitXor, nkShl, nkShr, nkUShr,
    nkIn, nkInstanceof, nkAnd, nkOr, nkNullish, nkCond, nkAssign, nkIncDec, nkComma,
    nkArrayPat, nkObjPat, nkPatProp, nkRest, nkDefault,
    nkExprStmt, nkDecl, nkDeclItem, nkFuncDecl, nkBlock, nkIf, nkWhile, nkDoWhile,
    nkFor, nkForOf, nkForIn, nkBreak, nkContinue, nkReturn, nkThrow, nkTry,
    nkSwitch, nkCase, nkLabeled

  NodeFlag = enum
    nfOptional, nfInOpt, nfPrefix, nfConst, nfVar, nfDeclare, nfParen

  Completion = enum
    cNormal, cBreak, cContinue, cReturn

  HostFn* = proc (args: seq[Value]): Value {.closure.}
    ## A host function: the script's arguments in, a value out. A Nim
    ## exception it raises (other than `ScriptError`) becomes a script
    ## `Error` with the same message, which the script may catch.
  HostGet* = proc (key: string): Value {.closure.}
    ## A host object's reading of `o.key` (`hostObject`).
  HostSet* = proc (key: string; v: Value): bool {.closure.}
    ## A host object's `o.key = v`; false: the script gets a TypeError.
  HostCall* = proc (key: string; args: seq[Value]): Value {.closure.}
    ## A host object's `o.key(args)`.

  StrObj = object
    s: string
    ascii: int8                # -1 not known yet, 0 no, 1 yes
    offs: seq[int32]           # where each code point starts (and the end), for text that isn't ASCII
  Str = ref StrObj

  ArrObj = object
    items: seq[Value]
  Arr = ref ArrObj

  ErrInfo = ref object
    file: string
    line, col: int
    stack: seq[string]

  ObjObj = object
    keys: seq[string]
    vals: seq[Value]
    index: Table[string, int]  # kept once there are more than 8 keys
    err: ErrInfo               # an Error object: where it was made
    ctor: Fn                   # made by `new F()`
  Obj = ref ObjObj

  NativeProc = proc (vm: Vm; this: Value; base, argc: int; site: Node): Value {.nimcall.}

  FnKind = enum
    fkScript, fkNative, fkHost, fkBound, fkBoundFn

  FnObj = object
    name: string
    props: Obj                 # a function's own members (String.fromCharCode)
    case kind: FnKind
    of fkScript:
      proto: Proto
      env: Env
    of fkNative:
      native: NativeProc
    of fkHost:
      host: HostFn
    of fkBound:
      recv: Value
      meth: MethodId
    of fkBoundFn:
      target: Value
      boundThis: Value
      boundArgs: seq[Value]
  Fn = ref FnObj

  HostObj = object
    get: HostGet
    set: HostSet
    call: HostCall
    data: RootRef
  Host = ref HostObj

  Value* = object
    ## A script value. Make one with `toValue` (or `undefinedValue`,
    ## `nullValue`, `newArrayValue`, `newObjectValue`, `hostObject`); read it
    ## with `kind`, `toNum`, `toStr`, `toBool`, `len`, `[]`, `items`, `keys`.
    case kind*: ValueKind      ## what it is: undefined, null, a boolean, a number, a string...
    of vkUndefined, vkNull: discard
    of vkBool: bval: bool
    of vkNum: nval: float64
    of vkStr: sval: Str
    of vkArray: aval: Arr
    of vkObject: oval: Obj
    of vkFunction: fval: Fn
    of vkHost: hval: Host

  Env = ref object
    parent: Env
    vals: seq[Value]

  Proto {.acyclic.} = ref object
    name, file: string
    line, col: int
    isArrow, selfNamed, simple: bool
    rawParams: seq[Node]
    nparams: int
    params: seq[Node]          # per parameter: nil (the argument is already in its slot) or a binding
    rest, thisTarget, selfTarget, argsTarget: Node
    body: Node                 # a block, or
    exprBody: Node             # an arrow's expression
    nregs, envSize: int

  Node {.acyclic.} = ref object
    kind: NodeKind
    flags: set[NodeFlag]
    meth: MethodId
    op: NodeKind
    line, col: int32
    slot, hops, envSize, gslot: int32
    gvm: int
    a, b, c, d: Node
    list: seq[Node]
    labels: seq[string]
    name: string
    val: Value
    proto: Proto

  CallRec = object
    proto {.cursor.}: Proto
    site {.cursor.}: Node

  Script* = ref object
    ## A compiled program; run it on any number of `Vm`s, any number of times.
    name*: string              ## the name given to `compile` (in error messages)
    main: Proto

  Vm* = ref object
    ## An interpreter: its globals, its stack and its limits.
    id: int
    stack: seq[Value]
    bp, sp: int
    env: Env
    retVal: Value
    label: string
    gnames: Table[string, int]
    gvals: seq[Value]
    gconst: seq[bool]
    calls: seq[CallRec]
    depth: int
    left: int
    cancelled: bool
    running: int
    stackBase: int
    optShort: bool
    topDepth: int
    completion: Value
    output: proc (s: string) {.closure.}
    rng: Rand
    maxDepth*: int        ## how deep calls may nest, the script's top level counted (default 1000;
                          ## 150 in a debug build, where Nim itself allows 2000 nested calls)
    maxStringLen*: int    ## the longest string, in bytes (default 16 MiB)
    maxArrayLen*: int     ## the longest array, and the most keys an object holds (default 4 Mi)
    maxNativeStack*: int  ## machine stack the interpreter may use, in bytes (default 2 MiB: run
                          ## scripts on a thread with more than that; a script call takes 1 to 4 KiB)
    stepBudget*: int      ## steps for a `call` made from outside a run (default 50 M)

  ScriptError* = object of CatchableError
    ## A script that could not be read, or that stopped on an error.
    ## `msg` reads "name:line:column: TypeError: x is not a function".
    file*: string         ## the script's name
    line*, column*: int   ## where (1-based; the column counts characters)
    message*: string      ## the error without its place ("TypeError: x is not a function")
    stack*: seq[string]   ## the calls it was in, innermost first ("at f (script:3:5)")
    value*: Value         ## what was thrown
    fatal*: bool          ## out of steps or cancelled: a script cannot catch it

  JsonCycle = object of CatchableError

const
  debugFrames = compileOption("stacktrace")  # a debug build allows Nim 2000 nested calls
  maxNesting = when debugFrames: 100 else: 256  # how deep the parser lets brackets and statements nest
  maxTreeDepth = when debugFrames: 600 else: 1000  # how deep a tree may be (a + a + a … is deep too)
  defaultMaxDepth = when debugFrames: 150 else: 1000
  strMethods = {mSlice .. mValueOf}
  arrMethods = {mSlice, mIndexOf, mLastIndexOf, mIncludes, mAt, mConcat, mToString, mValueOf,
                mPush .. mFlatMap}
  numMethods = {mToString, mValueOf, mToFixed, mToPrecision}
  objMethods = {mToString, mValueOf, mHasOwnProperty}
  fnMethods = {mCall, mApply, mBind, mToString}

let methodTable = block:
  var t = initTable[string, MethodId]()
  for m in MethodId:
    if m != mNone: t[$m] = m
  t

proc methodOf(name: string): MethodId =
  {.cast(gcsafe).}:
    result = methodTable.getOrDefault(name, mNone)

var vmCount = 0

# ---- values ----------------------------------------------------------------------------------------------

template undef(): Value = Value(kind: vkUndefined)
template nullV(): Value = Value(kind: vkNull)
template boolV(x: bool): Value = Value(kind: vkBool, bval: x)
template numV(x: float64): Value = Value(kind: vkNum, nval: x)

proc strV(s: sink string): Value {.inline.} = Value(kind: vkStr, sval: Str(s: s, ascii: -1))
proc arrV(items: sink seq[Value]): Value {.inline.} = Value(kind: vkArray, aval: Arr(items: items))
proc objV(o: Obj): Value {.inline.} = Value(kind: vkObject, oval: o)

proc find(o: Obj; key: string): int =
  if o.keys.len <= 8:
    for i in 0 ..< o.keys.len:
      if o.keys[i] == key: return i
    -1
  else:
    o.index.getOrDefault(key, -1)

proc put(o: Obj; key: string; v: sink Value) =
  let i = o.find(key)
  if i >= 0:
    o.vals[i] = v
    return
  o.keys.add key
  o.vals.add v
  if o.keys.len > 8:
    if o.index.len == 0:
      for j, k in o.keys: o.index[k] = j
    else:
      o.index[key] = o.keys.len - 1

proc del(o: Obj; key: string): bool =
  let i = o.find(key)
  if i < 0: return false
  o.keys.delete(i)
  o.vals.delete(i)
  o.index.clear()
  if o.keys.len > 8:
    for j, k in o.keys: o.index[k] = j
  true

proc getProp(o: Obj; key: string): Value =
  let i = o.find(key)
  if i >= 0: o.vals[i] else: undef()

# ---- text --------------------------------------------------------------------------------------------------

proc isAscii(st: Str): bool =
  if st.ascii < 0:
    st.ascii = 1
    for ch in st.s:
      if ord(ch) >= 128:
        st.ascii = 0
        break
  st.ascii == 1

proc cpBytes(s: string; i: int): int =
  ## The bytes of the code point at `i` (1 for a broken one).
  let c = ord(s[i])
  let n = if c < 0x80: 1 elif c < 0xC0: 1 elif c < 0xE0: 2 elif c < 0xF0: 3 elif c < 0xF8: 4 else: 1
  if i + n > s.len: return 1
  for k in 1 ..< n:
    if (ord(s[i + k]) and 0xC0) != 0x80: return 1
  n

proc decodeAt(s: string; i: int): int =
  let n = cpBytes(s, i)
  let c = ord(s[i])
  case n
  of 1: c
  of 2: ((c and 0x1F) shl 6) or (ord(s[i + 1]) and 0x3F)
  of 3: ((c and 0x0F) shl 12) or ((ord(s[i + 1]) and 0x3F) shl 6) or (ord(s[i + 2]) and 0x3F)
  else: ((c and 0x07) shl 18) or ((ord(s[i + 1]) and 0x3F) shl 12) or
        ((ord(s[i + 2]) and 0x3F) shl 6) or (ord(s[i + 3]) and 0x3F)

proc encodeCp(cp: int): string =
  var c = cp
  if c < 0 or c > 0x10FFFF or (c >= 0xD800 and c <= 0xDFFF): c = 0xFFFD
  unicode.toUTF8(unicode.Rune(c))

proc offsets(st: Str) =
  if st.offs.len == 0:
    var i = 0
    while i < st.s.len:
      st.offs.add int32(i)
      i += cpBytes(st.s, i)
    st.offs.add int32(st.s.len)

proc cpCount(st: Str): int =
  if st.isAscii: return st.s.len
  st.offsets
  st.offs.len - 1

proc cpByte(st: Str; i: int): int =
  ## Where code point `i` (0 .. count) starts.
  if st.isAscii: return i
  st.offsets
  st.offs[i]

proc cpSlice(st: Str; i, j: int): string =
  if i >= j: return ""
  st.s[st.cpByte(i) ..< st.cpByte(j)]

proc cpOfByte(st: Str; b: int): int =
  if st.isAscii: return b
  st.offsets
  lowerBound(st.offs, int32(b))

proc hasNonAscii(s: string): bool =
  for ch in s:
    if ord(ch) >= 128: return true
  false

# ---- numbers -------------------------------------------------------------------------------------------------

proc numToStr*(x: float64): string =
  ## A number written as JavaScript writes it (1, 0.1, 1e+21, 1.5e-7, NaN).
  if x != x: return "NaN"
  if x == Inf: return "Infinity"
  if x == -Inf: return "-Infinity"
  if x == 0: return "0"
  if abs(x) < 9007199254740992.0 and x == trunc(x): return $int64(x)
  var s = $x
  var neg = false
  if s[0] == '-':
    neg = true
    s = s[1 .. ^1]
  var digits = ""
  var point = -1
  var i = 0
  while i < s.len and s[i] != 'e':
    if s[i] == '.': point = digits.len
    else: digits.add s[i]
    inc i
  if point < 0: point = digits.len
  var e10 = 0
  if i < s.len: e10 = parseInt(s[i + 1 .. ^1])
  var lead = 0
  while lead < digits.len - 1 and digits[lead] == '0': inc lead
  digits = digits[lead .. ^1]
  point -= lead
  while digits.len > 1 and digits[^1] == '0': digits.setLen(digits.len - 1)
  let k = digits.len
  let n = point + e10
  var r = ""
  if k <= n and n <= 21:
    r = digits & repeat('0', n - k)
  elif 0 < n and n <= 21:
    r = digits[0 ..< n] & "." & digits[n .. ^1]
  elif -6 < n and n <= 0:
    r = "0." & repeat('0', -n) & digits
  else:
    let e = n - 1
    r = digits[0 .. 0]
    if k > 1: r.add "." & digits[1 .. ^1]
    r.add "e" & (if e >= 0: "+" else: "-") & $abs(e)
  if neg: "-" & r else: r

const jsSpace = {' ', '\t', '\n', '\r', '\v', '\f'}

proc hexVal(c: char): int =
  case c
  of '0' .. '9': ord(c) - ord('0')
  of 'a' .. 'z': ord(c) - ord('a') + 10
  of 'A' .. 'Z': ord(c) - ord('A') + 10
  else: 99

proc decimalPrefix(t: string; i: int): int =
  ## How long the decimal number at `i` is (0 when there is none).
  var j = i
  if j < t.len and t[j] in {'+', '-'}: inc j
  if t.continuesWith("Infinity", j): return j + 8 - i
  var digits = 0
  while j < t.len and t[j] in Digits: inc j; inc digits
  if j < t.len and t[j] == '.':
    inc j
    while j < t.len and t[j] in Digits: inc j; inc digits
  if digits == 0: return 0
  if j < t.len and t[j] in {'e', 'E'}:
    var k = j + 1
    if k < t.len and t[k] in {'+', '-'}: inc k
    if k < t.len and t[k] in Digits:
      while k < t.len and t[k] in Digits: inc k
      j = k
  j - i

proc parseDecimal(t: string): float64 =
  if t.endsWith("Infinity"): return (if t[0] == '-': -Inf else: Inf)
  var u = t
  if u[^1] == '.': u.add '0'
  try: parseFloat(u) except ValueError: NaN

proc strToNum(s: string): float64 =
  let t = s.strip(chars = jsSpace)
  if t.len == 0: return 0.0
  if t.len > 2 and t[0] == '0' and t[1] in {'x', 'X', 'b', 'B', 'o', 'O'}:
    let radix = if t[1] in {'x', 'X'}: 16 elif t[1] in {'b', 'B'}: 2 else: 8
    var v = 0.0
    for k in 2 ..< t.len:
      let d = hexVal(t[k])
      if d >= radix: return NaN
      v = v * float(radix) + float(d)
    return v
  let n = decimalPrefix(t, 0)
  if n != t.len: return NaN
  parseDecimal(t)

proc toInt32(x: float64): int32 =
  if x != x or x == Inf or x == -Inf: return 0
  if x >= -2147483648.0 and x <= 2147483647.0: return int32(x)
  var m = trunc(x) mod 4294967296.0
  if m < 0: m += 4294967296.0
  cast[int32](uint32(m))

proc toUint32(x: float64): uint32 = cast[uint32](toInt32(x))

proc toInteger(x: float64): float64 {.inline.} =
  if x != x: 0.0 else: trunc(x)

proc clampInt(x: float64; lo, hi: int): int =
  if x != x or x <= float(lo): lo
  elif x >= float(hi): hi
  else: int(x)

proc jsPow(x, y: float64): float64 =
  if y != y: return NaN
  if abs(x) == 1 and (y == Inf or y == -Inf): return NaN
  pow(x, y)

proc jsCbrt(x: float64): float64 =
  result = cbrt(x)
  let r = round(result)
  if r * r * r == x: result = r

proc jsRound(x: float64): float64 =
  if x != x or x == Inf or x == -Inf: return x
  let f = floor(x)
  result = if x - f >= 0.5: f + 1 else: f
  if result == 0 and (x < 0 or signbit(x)): result = -0.0

proc exactDigits(ax: float64): (string, int) =
  ## Every decimal digit of a finite number above 0, and how many of them
  ## come before the point (a double is an integer times a power of two, so
  ## its decimal expansion ends).
  let bits = cast[uint64](ax)
  var mant = bits and ((1'u64 shl 52) - 1)
  let ex = int((bits shr 52) and 0x7FF)
  if ex != 0: mant = mant or (1'u64 shl 52)
  let e2 = (if ex == 0: 1 else: ex) - 1075
  var limbs = @[mant mod 1_000_000_000'u64, (mant div 1_000_000_000'u64) mod 1_000_000_000'u64,
                mant div 1_000_000_000_000_000_000'u64]
  proc mulSmall(limbs: var seq[uint64]; k: uint64) =
    var carry = 0'u64
    for i in 0 ..< limbs.len:
      let v = limbs[i] * k + carry
      limbs[i] = v mod 1_000_000_000'u64
      carry = v div 1_000_000_000'u64
    while carry > 0:
      limbs.add carry mod 1_000_000_000'u64
      carry = carry div 1_000_000_000'u64
  var frac = 0
  if e2 > 0:
    var left = e2
    while left > 0:
      let k = min(left, 29)
      limbs.mulSmall(1'u64 shl k)
      left -= k
  else:
    frac = -e2
    var left = frac
    while left > 0:
      let k = min(left, 12)
      var f = 1'u64
      for _ in 0 ..< k: f *= 5
      limbs.mulSmall(f)
      left -= k
  while limbs.len > 1 and limbs[^1] == 0: limbs.setLen(limbs.len - 1)
  var digits = $limbs[^1]
  for i in countdown(limbs.len - 2, 0):
    let part = $limbs[i]
    digits.add repeat('0', 9 - part.len)
    digits.add part
  (digits, digits.len - frac)

proc roundDigits(digits: var string; next: char): bool =
  ## Rounds a digit string half up by the digit after it; true when it grew
  ## a digit (999 → 1000).
  if next < '5': return false
  var i = digits.len - 1
  while i >= 0:
    if digits[i] == '9':
      digits[i] = '0'
      dec i
    else:
      digits[i] = char(ord(digits[i]) + 1)
      return false
  digits = "1" & digits
  true

proc toFixedStr(x: float64; d: int): string =
  ## `x.toFixed(d)`: ties round up, as JavaScript's do (printf rounds them to even).
  let ax = abs(x)
  var digits = ""
  var intLen = 1
  if ax == 0:
    digits = "0"
  else:
    (digits, intLen) = exactDigits(ax)
    if intLen <= 0:
      digits = repeat('0', 1 - intLen) & digits
      intLen = 1
  let want = intLen + d
  if digits.len < want + 1: digits.add repeat('0', want + 1 - digits.len)
  var keep = digits[0 ..< want]
  if roundDigits(keep, digits[want]): inc intLen
  result = if x < 0: "-" else: ""
  result.add keep[0 ..< intLen]
  if d > 0:
    result.add '.'
    result.add keep[intLen .. ^1]

proc toPrecisionStr(x: float64; p: int): string =
  let ax = abs(x)
  var digits = "0"
  var e = 0
  if ax != 0:
    var intLen: int
    (digits, intLen) = exactDigits(ax)
    e = intLen - 1
  if digits.len < p + 1: digits.add repeat('0', p + 1 - digits.len)
  var keep = digits[0 ..< p]
  if ax != 0 and roundDigits(keep, digits[p]):
    keep.setLen(p)
    inc e
  result = if x < 0: "-" else: ""
  if e < -6 or e >= p:
    result.add keep[0]
    if p > 1: result.add "." & keep[1 .. ^1]
    result.add "e" & (if e >= 0: "+" else: "-") & $abs(e)
  elif e >= 0:
    result.add keep[0 .. e]
    if p - 1 > e: result.add "." & keep[e + 1 .. ^1]
  else:
    result.add "0." & repeat('0', -e - 1) & keep

proc numToRadix(x: float64; radix: int): string =
  if x != x: return "NaN"
  if x == Inf: return "Infinity"
  if x == -Inf: return "-Infinity"
  const digitChars = "0123456789abcdefghijklmnopqrstuvwxyz"
  var v = abs(x)
  var ip = floor(v)
  var fp = v - ip
  var s = ""
  if ip == 0: s = "0"
  while ip >= 1:
    let d = int(ip mod float(radix))
    s.add digitChars[d]
    ip = floor(ip / float(radix))
  var r = ""
  for k in countdown(s.len - 1, 0): r.add s[k]
  if fp > 0:
    r.add '.'
    var k = 0
    while fp > 0 and k < 52:
      fp *= float(radix)
      let d = int(floor(fp))
      r.add digitChars[d]
      fp -= float(d)
      inc k
  if x < 0: "-" & r else: r

# ---- conversions -------------------------------------------------------------------------------------------

proc toStr*(v: Value): string
  ## The value as a string, as JavaScript's `String(v)`.
proc inspect*(v: Value): string
  ## The value as `console.log` shows it: `[1, 2]`, `{a: 1, b: "x"}`.

proc toNum*(v: Value): float64 =
  ## The value as a number, as JavaScript's `Number(v)`.
  case v.kind
  of vkNum: v.nval
  of vkUndefined: NaN
  of vkNull: 0.0
  of vkBool: (if v.bval: 1.0 else: 0.0)
  of vkStr: strToNum(v.sval.s)
  of vkArray: strToNum(toStr(v))
  else: NaN

proc toBool*(v: Value): bool =
  ## Whether the value is "truthy".
  case v.kind
  of vkUndefined, vkNull: false
  of vkBool: v.bval
  of vkNum: v.nval != 0 and v.nval == v.nval
  of vkStr: v.sval.s.len > 0
  else: true

proc isNull*(v: Value): bool =
  ## `null` or `undefined`.
  v.kind <= vkNull

proc joinInto(a: Arr; sep: string; s: var string; seen: var seq[pointer])

proc errorText(o: Obj): string =
  let name = toStr(o.getProp("name"))
  let msg = o.getProp("message")
  let m = if msg.kind == vkUndefined: "" else: toStr(msg)
  if m.len == 0: name elif name.len == 0: m else: name & ": " & m

proc toStr*(v: Value): string =
  ## The value as a string, as JavaScript's `String(v)`.
  case v.kind
  of vkUndefined: "undefined"
  of vkNull: "null"
  of vkBool: (if v.bval: "true" else: "false")
  of vkNum: numToStr(v.nval)
  of vkStr: v.sval.s
  of vkArray:
    var s = ""
    var seen: seq[pointer]
    joinInto(v.aval, ",", s, seen)
    s
  of vkObject: (if v.oval.err != nil: errorText(v.oval) else: "[object Object]")
  of vkFunction: "function " & v.fval.name & "() { [code] }"
  of vkHost: "[object Host]"

proc joinInto(a: Arr; sep: string; s: var string; seen: var seq[pointer]) =
  let p = cast[pointer](a)
  if p in seen or seen.len > 200: return
  seen.add p
  for i, it in a.items:
    if i > 0: s.add sep
    case it.kind
    of vkUndefined, vkNull: discard
    of vkStr: s.add it.sval.s
    of vkArray: joinInto(it.aval, ",", s, seen)
    else: s.add toStr(it)
  discard seen.pop

proc typeName(v: Value): string =
  case v.kind
  of vkUndefined: "undefined"
  of vkNull, vkArray, vkObject, vkHost: "object"
  of vkBool: "boolean"
  of vkNum: "number"
  of vkStr: "string"
  of vkFunction: "function"

proc strictEq(a, b: Value): bool =
  if a.kind != b.kind: return false
  case a.kind
  of vkUndefined, vkNull: true
  of vkBool: a.bval == b.bval
  of vkNum: a.nval == b.nval
  of vkStr: a.sval == b.sval or a.sval.s == b.sval.s
  of vkArray: a.aval == b.aval
  of vkObject: a.oval == b.oval
  of vkFunction: a.fval == b.fval
  of vkHost: a.hval == b.hval

proc sameValueZero(a, b: Value): bool =
  if a.kind == vkNum and b.kind == vkNum and a.nval != a.nval and b.nval != b.nval: return true
  strictEq(a, b)

proc toPrim(v: Value): Value =
  if v.kind in {vkArray, vkObject, vkFunction, vkHost}: strV(toStr(v)) else: v

proc looseEq(a, b: Value): bool =
  if a.kind == b.kind: return strictEq(a, b)
  if a.kind <= vkNull and b.kind <= vkNull: return true
  if a.kind <= vkNull or b.kind <= vkNull: return false
  if a.kind == vkNum and b.kind == vkStr: return a.nval == toNum(b)
  if a.kind == vkStr and b.kind == vkNum: return toNum(a) == b.nval
  if a.kind == vkBool: return looseEq(numV(toNum(a)), b)
  if b.kind == vkBool: return looseEq(a, numV(toNum(b)))
  if a.kind in {vkArray, vkObject} and b.kind in {vkNum, vkStr}: return looseEq(toPrim(a), b)
  if b.kind in {vkArray, vkObject} and a.kind in {vkNum, vkStr}: return looseEq(a, toPrim(b))
  false

proc lessThan(a, b: Value; orEqual: bool): bool =
  let pa = toPrim(a)
  let pb = toPrim(b)
  if pa.kind == vkStr and pb.kind == vkStr:
    let c = cmp(pa.sval.s, pb.sval.s)
    return if orEqual: c <= 0 else: c < 0
  let x = toNum(pa)
  let y = toNum(pb)
  if orEqual: x <= y else: x < y

proc propKey(v: Value): string =
  case v.kind
  of vkStr: v.sval.s
  of vkNum: numToStr(v.nval)
  else: toStr(v)

proc indexKey(key: string): int =
  ## The array index a key names, or -1.
  if key.len == 0 or key.len > 9: return -1
  if key.len > 1 and key[0] == '0': return -1
  result = 0
  for ch in key:
    if ch notin Digits: return -1
    result = result * 10 + (ord(ch) - ord('0'))

# ---- printing and JSON ----------------------------------------------------------------------------------------

proc jsonQuote(s: string; dst: var string) =
  dst.add '"'
  for ch in s:
    case ch
    of '"': dst.add "\\\""
    of '\\': dst.add "\\\\"
    of '\n': dst.add "\\n"
    of '\r': dst.add "\\r"
    of '\t': dst.add "\\t"
    of '\b': dst.add "\\b"
    of '\f': dst.add "\\f"
    of '\0' .. '\7', '\v', '\14' .. '\31':
      dst.add "\\u00"
      dst.add toHex(ord(ch), 2).toLowerAscii
    else: dst.add ch
  dst.add '"'

proc isIdentKey(k: string): bool =
  if k.len == 0 or k[0] in Digits: return false
  for ch in k:
    if ch notin IdentChars and ch != '$': return false
  true

proc inspectInto(v: Value; s: var string; depth: int; seen: var seq[pointer]; top: bool) =
  case v.kind
  of vkStr:
    if top: s.add v.sval.s else: jsonQuote(v.sval.s, s)
  of vkArray:
    let p = cast[pointer](v.aval)
    if p in seen: s.add "[Circular]"; return
    if depth > 4: s.add "[Array]"; return
    seen.add p
    s.add '['
    for i, it in v.aval.items:
      if i > 0: s.add ", "
      if i >= 100:
        s.add "... " & $(v.aval.items.len - 100) & " more items"
        break
      inspectInto(it, s, depth + 1, seen, false)
    s.add ']'
    discard seen.pop
  of vkObject:
    let o = v.oval
    if o.err != nil: s.add errorText(o); return
    let p = cast[pointer](o)
    if p in seen: s.add "[Circular]"; return
    if depth > 4: s.add "[Object]"; return
    if o.keys.len == 0: s.add "{}"; return
    seen.add p
    s.add '{'
    for i, k in o.keys:
      if i > 0: s.add ", "
      if i >= 100:
        s.add "... " & $(o.keys.len - 100) & " more"
        break
      if isIdentKey(k): s.add k else: jsonQuote(k, s)
      s.add ": "
      inspectInto(o.vals[i], s, depth + 1, seen, false)
    s.add '}'
    discard seen.pop
  of vkFunction:
    s.add(if v.fval.name.len > 0: "[Function: " & v.fval.name & "]" else: "[Function (anonymous)]")
  of vkHost: s.add "[Host]"
  of vkNum:
    if v.nval == 0 and signbit(v.nval): s.add "-0" else: s.add numToStr(v.nval)
  else: s.add toStr(v)

proc inspect*(v: Value): string =
  ## The value as `console.log` shows it: `[1, 2]`, `{a: 1, b: "x"}`.
  var seen: seq[pointer]
  inspectInto(v, result, 0, seen, true)

proc jsonInto(v: Value; s: var string; indent, cur: string; seen: var seq[pointer]): bool =
  case v.kind
  of vkNull: s.add "null"
  of vkBool: s.add(if v.bval: "true" else: "false")
  of vkNum:
    if v.nval != v.nval or v.nval == Inf or v.nval == -Inf: s.add "null"
    else: s.add numToStr(v.nval)
  of vkStr: jsonQuote(v.sval.s, s)
  of vkArray:
    let p = cast[pointer](v.aval)
    if p in seen: raise newException(JsonCycle, "Converting circular structure to JSON")
    if seen.len > 1000: raise newException(JsonCycle, "JSON nesting is too deep")
    if v.aval.items.len == 0: s.add "[]"; return true
    seen.add p
    let inner = cur & indent
    s.add '['
    for i, it in v.aval.items:
      if i > 0: s.add ','
      if indent.len > 0: s.add '\n'; s.add inner
      if not jsonInto(it, s, indent, inner, seen): s.add "null"
    if indent.len > 0: s.add '\n'; s.add cur
    s.add ']'
    discard seen.pop
  of vkObject:
    let o = v.oval
    let p = cast[pointer](o)
    if p in seen: raise newException(JsonCycle, "Converting circular structure to JSON")
    if seen.len > 1000: raise newException(JsonCycle, "JSON nesting is too deep")
    seen.add p
    let inner = cur & indent
    s.add '{'
    var n = 0
    for i, k in o.keys:
      if o.vals[i].kind in {vkUndefined, vkFunction, vkHost}: continue
      if n > 0: s.add ','
      if indent.len > 0: s.add '\n'; s.add inner
      jsonQuote(k, s)
      s.add(if indent.len > 0: ": " else: ":")
      discard jsonInto(o.vals[i], s, indent, inner, seen)
      inc n
    if n > 0 and indent.len > 0: s.add '\n'; s.add cur
    s.add '}'
    discard seen.pop
  of vkUndefined, vkFunction, vkHost: return false
  true

proc toJson*(v: Value; indent = ""): string =
  ## The value as JSON text (`JSON.stringify`); "" for undefined.
  ## Raises `ValueError` on a structure that holds itself.
  var seen: seq[pointer]
  try:
    if not jsonInto(v, result, indent, "", seen): result = ""
  except JsonCycle as e:
    raise newException(ValueError, e.msg)

proc parseJsonValue(s: string; i: var int; depth: int): Value =
  template fail(msg: string) = raise newException(ValueError, msg)
  template ws() =
    while i < s.len and s[i] in {' ', '\t', '\n', '\r'}: inc i
  template unexpected() =
    if i >= s.len: fail("Unexpected end of JSON input")
    else: fail("Unexpected token " & s[i] & " in JSON at position " & $i)
  if depth > 512: fail("JSON nesting is too deep")
  ws()
  if i >= s.len: unexpected()
  case s[i]
  of '{':
    inc i
    let o = Obj()
    ws()
    if i < s.len and s[i] == '}':
      inc i
      return objV(o)
    while true:
      ws()
      if i >= s.len or s[i] != '"': unexpected()
      let k = parseJsonValue(s, i, depth + 1)
      ws()
      if i >= s.len or s[i] != ':': unexpected()
      inc i
      o.put(k.sval.s, parseJsonValue(s, i, depth + 1))
      ws()
      if i < s.len and s[i] == ',': inc i
      elif i < s.len and s[i] == '}': inc i; break
      else: unexpected()
    objV(o)
  of '[':
    inc i
    var items: seq[Value]
    ws()
    if i < s.len and s[i] == ']':
      inc i
      return arrV(items)
    while true:
      items.add parseJsonValue(s, i, depth + 1)
      ws()
      if i < s.len and s[i] == ',': inc i
      elif i < s.len and s[i] == ']': inc i; break
      else: unexpected()
    arrV(items)
  of '"':
    inc i
    var r = ""
    while true:
      if i >= s.len: fail("Unterminated string in JSON at position " & $i)
      let c = s[i]
      if c == '"': inc i; break
      if ord(c) < 0x20: unexpected()
      if c == '\\':
        inc i
        if i >= s.len: unexpected()
        let e = s[i]
        inc i
        case e
        of '"': r.add '"'
        of '\\': r.add '\\'
        of '/': r.add '/'
        of 'b': r.add '\b'
        of 'f': r.add '\f'
        of 'n': r.add '\n'
        of 'r': r.add '\r'
        of 't': r.add '\t'
        of 'u':
          var cp = 0
          for _ in 0 ..< 4:
            if i >= s.len or hexVal(s[i]) > 15: fail("Bad Unicode escape in JSON at position " & $i)
            cp = cp * 16 + hexVal(s[i])
            inc i
          if cp >= 0xD800 and cp <= 0xDBFF and i + 5 < s.len and s[i] == '\\' and s[i + 1] == 'u':
            var lo = 0
            var ok = true
            for k in 2 .. 5:
              let h = hexVal(s[i + k])
              if h > 15: ok = false
              lo = lo * 16 + h
            if ok and lo >= 0xDC00 and lo <= 0xDFFF:
              cp = 0x10000 + ((cp - 0xD800) shl 10) + (lo - 0xDC00)
              i += 6
          r.add encodeCp(cp)
        else:
          dec i
          unexpected()
      else:
        r.add c
        inc i
    strV(r)
  of 't':
    if s.continuesWith("true", i): i += 4; return boolV(true)
    unexpected()
  of 'f':
    if s.continuesWith("false", i): i += 5; return boolV(false)
    unexpected()
  of 'n':
    if s.continuesWith("null", i): i += 4; return nullV()
    unexpected()
  of '-', '0' .. '9':
    let a = i
    if s[i] == '-': inc i
    if i < s.len and s[i] == '0': inc i
    elif i < s.len and s[i] in Digits:
      while i < s.len and s[i] in Digits: inc i
    else: unexpected()
    if i < s.len and s[i] == '.':
      inc i
      if i >= s.len or s[i] notin Digits: unexpected()
      while i < s.len and s[i] in Digits: inc i
    if i < s.len and s[i] in {'e', 'E'}:
      inc i
      if i < s.len and s[i] in {'+', '-'}: inc i
      if i >= s.len or s[i] notin Digits: unexpected()
      while i < s.len and s[i] in Digits: inc i
    numV(parseDecimal(s[a ..< i]))
  else:
    unexpected()

proc parseJson*(s: string): Value =
  ## JSON text as a value (`JSON.parse`); raises `ValueError` on bad JSON.
  var i = 0
  result = parseJsonValue(s, i, 0)
  while i < s.len and s[i] in {' ', '\t', '\n', '\r'}: inc i
  if i < s.len: raise newException(ValueError, "Unexpected token " & s[i] & " in JSON at position " & $i)

# ---- lexer ----------------------------------------------------------------------------------------------------

type
  TokKind = enum
    tkEof = "end of input", tkIdent = "identifier", tkNum = "number", tkStr = "string",
    tkTemplate = "template",
    tkLParen = "(", tkRParen = ")", tkLBrace = "{", tkRBrace = "}", tkLBracket = "[", tkRBracket = "]",
    tkSemi = ";", tkComma = ",", tkDot = ".", tkQDot = "?.", tkEllipsis = "...", tkQuestion = "?",
    tkColon = ":", tkArrow = "=>",
    tkPlus = "+", tkMinus = "-", tkStar = "*", tkSlash = "/", tkPercent = "%", tkPow = "**",
    tkEq = "==", tkNe = "!=", tkSeq = "===", tkSne = "!==", tkLt = "<", tkLe = "<=", tkGt = ">",
    tkGe = ">=", tkAndAnd = "&&", tkOrOr = "||", tkNullish = "??", tkNot = "!", tkTilde = "~",
    tkAmp = "&", tkPipe = "|", tkCaret = "^", tkShl = "<<", tkShr = ">>", tkUShr = ">>>",
    tkInc = "++", tkDec = "--",
    tkAssign = "=", tkAddAs = "+=", tkSubAs = "-=", tkMulAs = "*=", tkDivAs = "/=", tkModAs = "%=",
    tkPowAs = "**=", tkShlAs = "<<=", tkShrAs = ">>=", tkUShrAs = ">>>=", tkAndAs = "&=",
    tkOrAs = "|=", tkXorAs = "^=", tkLAndAs = "&&=", tkLOrAs = "||=", tkNullAs = "??="

  TplPart = object
    isExpr: bool
    s: string
    a, b, line, col: int

  Token = object
    kind: TokKind
    text: string
    num: float64
    parts: seq[TplPart]
    line, col: int
    nl: bool

const punctText = block:
  var t: array[TokKind, string]
  for k in TokKind: t[k] = $k
  t

proc newScriptError(file: string; line, col: int; text: string; v: Value;
                    stack: seq[string] = @[]; fatal = false): ref ScriptError =
  result = newException(ScriptError, file & ":" & $line & ":" & $col & ": " & text)
  result.file = file
  result.line = line
  result.column = col
  result.message = text
  result.value = v
  result.stack = stack
  result.fatal = fatal

proc syntaxErrorValue(msg: string): Value =
  let o = Obj()
  o.put("name", strV("SyntaxError"))
  o.put("message", strV(msg))
  objV(o)

proc synErr(file: string; line, col: int; msg: string) {.noreturn.} =
  raise newScriptError(file, line, col, "SyntaxError: " & msg, syntaxErrorValue(msg))

proc findClose(src: string; start, stop: int): int

proc skipTpl(src: string; i: var int; stop: int): bool =
  inc i
  while i < stop:
    case src[i]
    of '\\': i += 2
    of '`':
      inc i
      return true
    of '$':
      if i + 1 < stop and src[i + 1] == '{':
        let e = findClose(src, i + 2, stop)
        if e < 0: return false
        i = e + 1
      else: inc i
    else: inc i
  false

proc findClose(src: string; start, stop: int): int =
  ## Where the `}` that closes a template's `${` is.
  var i = start
  var depth = 0
  while i < stop:
    case src[i]
    of '{':
      inc depth
      inc i
    of '}':
      if depth == 0: return i
      dec depth
      inc i
    of '"', '\'':
      let q = src[i]
      inc i
      while i < stop and src[i] != q and src[i] != '\n':
        if src[i] == '\\': inc i
        inc i
      inc i
    of '`':
      if not skipTpl(src, i, stop): return -1
    of '/':
      if i + 1 < stop and src[i + 1] == '/':
        while i < stop and src[i] != '\n': inc i
      elif i + 1 < stop and src[i + 1] == '*':
        i += 2
        while i + 1 < stop and not (src[i] == '*' and src[i + 1] == '/'): inc i
        i += 2
      else: inc i
    else: inc i
  -1

proc lexRange(src: string; start, stop, line0, col0: int; file: string): seq[Token] =
  var i = start
  var line = line0
  var col = col0
  var nl = false
  template ch(k = 0): char = (if i + k < stop: src[i + k] else: '\0')
  template adv() =
    if src[i] == '\n':
      inc line
      col = 1
      inc i
    else:
      inc i
      if i >= stop or (ord(src[i]) and 0xC0) != 0x80: inc col
  template fail(msg: string) = synErr(file, line, col, msg)
  template readEscape(dst: var string) =
    adv()
    if i >= stop: fail("Unterminated string")
    let e = src[i]
    case e
    of 'n': dst.add '\n'; adv()
    of 't': dst.add '\t'; adv()
    of 'r': dst.add '\r'; adv()
    of 'b': dst.add '\b'; adv()
    of 'f': dst.add '\f'; adv()
    of 'v': dst.add '\v'; adv()
    of '0':
      if ch(1) in Digits: fail("Octal escape sequences are not allowed")
      dst.add '\0'
      adv()
    of 'x':
      adv()
      if hexVal(ch()) > 15 or hexVal(ch(1)) > 15: fail("Invalid hexadecimal escape sequence")
      dst.add encodeCp(hexVal(ch()) * 16 + hexVal(ch(1)))
      adv(); adv()
    of 'u':
      adv()
      var cp = 0
      if ch() == '{':
        adv()
        var n = 0
        while ch() != '}':
          if hexVal(ch()) > 15 or n > 6: fail("Invalid Unicode escape sequence")
          cp = cp * 16 + hexVal(ch())
          inc n
          adv()
        if n == 0: fail("Invalid Unicode escape sequence")
        adv()
      else:
        for _ in 0 ..< 4:
          if hexVal(ch()) > 15: fail("Invalid Unicode escape sequence")
          cp = cp * 16 + hexVal(ch())
          adv()
        if cp >= 0xD800 and cp <= 0xDBFF and ch() == '\\' and ch(1) == 'u':
          var lo = 0
          var ok = true
          for k in 2 .. 5:
            let h = hexVal(ch(k))
            if h > 15: ok = false
            lo = lo * 16 + h
          if ok and lo >= 0xDC00 and lo <= 0xDFFF:
            cp = 0x10000 + ((cp - 0xD800) shl 10) + (lo - 0xDC00)
            for _ in 0 ..< 6: adv()
      dst.add encodeCp(cp)
    of '\n': adv()
    of '\r':
      adv()
      if ch() == '\n': adv()
    else:
      let a = i
      adv()
      while i < stop and (ord(src[i]) and 0xC0) == 0x80: adv()
      dst.add src[a ..< i]
  if start == 0 and stop >= 2 and src[0] == '#' and src[1] == '!':
    while i < stop and src[i] != '\n': adv()
  while true:
    while i < stop:
      let c = src[i]
      if c == '\n':
        nl = true
        adv()
      elif c in {' ', '\t', '\r', '\v', '\f'}: adv()
      elif c == '/' and ch(1) == '/':
        while i < stop and src[i] != '\n': adv()
      elif c == '/' and ch(1) == '*':
        let l0 = line
        let c0 = col
        adv(); adv()
        while i < stop and not (src[i] == '*' and ch(1) == '/'):
          if src[i] == '\n': nl = true
          adv()
        if i >= stop: synErr(file, l0, c0, "Unterminated comment")
        adv(); adv()
      elif c == '\xC2' and ch(1) == '\xA0':
        adv(); adv()
      elif c == '\xEF' and ch(1) == '\xBB' and ch(2) == '\xBF':
        adv(); adv(); adv()
      else: break
    var t = Token(line: line, col: col, nl: nl)
    nl = false
    if i >= stop:
      t.kind = tkEof
      result.add t
      break
    let c = src[i]
    if c in IdentStartChars or c == '$' or ord(c) >= 0x80:
      let a = i
      while i < stop and (src[i] in IdentChars or src[i] == '$' or ord(src[i]) >= 0x80): adv()
      t.kind = tkIdent
      t.text = src[a ..< i]
    elif c in Digits or (c == '.' and ch(1) in Digits):
      var v = 0.0
      if c == '0' and ch(1) in {'x', 'X', 'b', 'B', 'o', 'O'}:
        let radix = if ch(1) in {'x', 'X'}: 16 elif ch(1) in {'b', 'B'}: 2 else: 8
        adv(); adv()
        var any = false
        while i < stop:
          if src[i] == '_':
            adv()
            continue
          let d = hexVal(src[i])
          if d >= radix: break
          v = v * float(radix) + float(d)
          any = true
          adv()
        if not any: fail("Invalid number")
      else:
        var txt = ""
        while i < stop and (src[i] in Digits or src[i] == '_'):
          if src[i] != '_': txt.add src[i]
          adv()
        if ch() == '.':
          txt.add '.'
          adv()
          while i < stop and (src[i] in Digits or src[i] == '_'):
            if src[i] != '_': txt.add src[i]
            adv()
        if ch() in {'e', 'E'} and (ch(1) in Digits or (ch(1) in {'+', '-'} and ch(2) in Digits)):
          txt.add 'e'
          adv()
          if ch() in {'+', '-'}:
            txt.add ch()
            adv()
          while i < stop and src[i] in Digits:
            txt.add src[i]
            adv()
        if txt[0] == '.': txt = "0" & txt
        v = parseDecimal(txt)
      if i < stop and (src[i] in IdentChars or src[i] == '$'): fail("Invalid or unexpected token")
      t.kind = tkNum
      t.num = v
    elif c == '"' or c == '\'':
      adv()
      var s = ""
      while true:
        if i >= stop or src[i] == '\n': fail("Unterminated string")
        let d = src[i]
        if d == c:
          adv()
          break
        if d == '\\': readEscape(s)
        else:
          s.add d
          adv()
      t.kind = tkStr
      t.text = s
    elif c == '`':
      adv()
      var cur = ""
      while true:
        if i >= stop: synErr(file, t.line, t.col, "Unterminated template literal")
        let d = src[i]
        if d == '`':
          adv()
          break
        elif d == '\\': readEscape(cur)
        elif d == '$' and ch(1) == '{':
          t.parts.add TplPart(s: cur)
          cur = ""
          adv(); adv()
          let el = line
          let ec = col
          let a = i
          let e = findClose(src, i, stop)
          if e < 0: synErr(file, t.line, t.col, "Unterminated template literal")
          while i < e: adv()
          t.parts.add TplPart(isExpr: true, a: a, b: e, line: el, col: ec)
          adv()
        elif d == '\r': adv()
        else:
          cur.add d
          adv()
      t.parts.add TplPart(s: cur)
      t.kind = tkTemplate
    else:
      var best = tkEof
      var bestLen = 0
      for k in tkLParen .. tkNullAs:
        let L = punctText[k].len
        if L > bestLen and i + L <= stop:
          var ok = true
          for j in 0 ..< L:
            if src[i + j] != punctText[k][j]:
              ok = false
              break
          if ok:
            best = k
            bestLen = L
      if bestLen == 0: fail("Invalid or unexpected token")
      if best == tkQDot and ch(2) in Digits:
        best = tkQuestion
        bestLen = 1
      for _ in 0 ..< bestLen: adv()
      t.kind = best
    result.add t

# ---- parser ---------------------------------------------------------------------------------------------------

const reservedWords = ["break", "case", "catch", "class", "const", "continue", "debugger", "default",
  "delete", "do", "else", "export", "extends", "finally", "for", "function", "if", "import", "in",
  "instanceof", "new", "return", "super", "switch", "this", "throw", "try", "typeof", "var", "void",
  "while", "with", "yield", "let", "null", "true", "false", "enum", "await"]

proc isReserved(s: string): bool = s in reservedWords

type
  SrcRef = ref object
    s: string
  Parser = object
    toks: seq[Token]
    p: int
    src: SrcRef
    file: string
    depth, loops, switches: int
    labels: seq[(string, bool)]   # the labels around, and whether each labels a loop

template tok(ps: Parser): untyped = ps.toks[ps.p]

proc peekTok(ps: Parser; k = 1): lent Token = ps.toks[min(ps.p + k, ps.toks.len - 1)]
proc next(ps: var Parser) =
  if ps.p < ps.toks.len - 1: inc ps.p
proc isWord(t: Token; w: string): bool = t.kind == tkIdent and t.text == w

proc errAt(ps: Parser; t: Token; msg: string) {.noreturn.} = synErr(ps.file, t.line, t.col, msg)

proc unexpected(ps: Parser) {.noreturn.} =
  let t = ps.tok
  case t.kind
  of tkEof: ps.errAt(t, "Unexpected end of input")
  of tkIdent: ps.errAt(t, "Unexpected " & (if isReserved(t.text): "token '" else: "identifier '") & t.text & "'")
  of tkNum: ps.errAt(t, "Unexpected number")
  of tkStr: ps.errAt(t, "Unexpected string")
  of tkTemplate: ps.errAt(t, "Unexpected template string")
  else: ps.errAt(t, "Unexpected token '" & punctText[t.kind] & "'")

proc expect(ps: var Parser; k: TokKind) =
  if ps.tok.kind != k:
    let t = ps.tok
    let found = case t.kind
      of tkEof: "the end of the script"
      of tkIdent: "'" & t.text & "'"
      of tkNum: "a number"
      of tkStr: "a string"
      of tkTemplate: "a template"
      else: "'" & punctText[t.kind] & "'"
    ps.errAt(t, "Expected '" & punctText[k] & "' but found " & found)
  ps.next

proc mk(kind: NodeKind; t: Token): Node =
  Node(kind: kind, line: int32(t.line), col: int32(t.col))

proc mkAt(kind: NodeKind; n: Node): Node =
  Node(kind: kind, line: n.line, col: n.col)

proc parseStatement(ps: var Parser): Node
proc parseExpr(ps: var Parser): Node
proc parseAssign(ps: var Parser): Node
proc parseUnary(ps: var Parser): Node
proc parseBlock(ps: var Parser): Node
proc parseBindingTarget(ps: var Parser): Node

proc nameFunction(f: Node; name: string) =
  if f != nil and f.kind == nkFunc and f.proto.name.len == 0: f.proto.name = name

proc parseParams(ps: var Parser): seq[Node] =
  ps.expect(tkLParen)
  while ps.tok.kind != tkRParen:
    if ps.tok.kind == tkEllipsis:
      let t = ps.tok
      ps.next
      let r = mk(nkRest, t)
      r.a = ps.parseBindingTarget()
      result.add r
      if ps.tok.kind != tkRParen: ps.errAt(ps.tok, "A rest parameter must be last")
      break
    let t = ps.tok
    let target = ps.parseBindingTarget()
    if ps.tok.kind == tkAssign:
      ps.next
      let d = mk(nkDefault, t)
      d.a = target
      d.b = ps.parseAssign()
      result.add d
    else:
      result.add target
    if ps.tok.kind == tkComma: ps.next
    elif ps.tok.kind != tkRParen: ps.unexpected()
  ps.next

proc parseFnBody(ps: var Parser): Node =
  let loops = ps.loops
  let switches = ps.switches
  let labels = ps.labels
  ps.loops = 0
  ps.switches = 0
  ps.labels = @[]
  result = ps.parseBlock()
  ps.loops = loops
  ps.switches = switches
  ps.labels = labels

proc parseFunction(ps: var Parser; isExpr: bool): Node =
  let t = ps.tok
  ps.next
  if ps.tok.kind == tkStar: ps.errAt(ps.tok, "Generator functions are not supported")
  var name = ""
  let nt = ps.tok
  if nt.kind == tkIdent and not isReserved(nt.text):
    name = nt.text
    ps.next
  elif not isExpr:
    ps.unexpected()
  let pr = Proto(name: name, file: ps.file, line: t.line, col: t.col, selfNamed: isExpr and name.len > 0)
  pr.rawParams = ps.parseParams()
  pr.body = ps.parseFnBody()
  if isExpr:
    result = mk(nkFunc, t)
  else:
    result = mk(nkFuncDecl, t)
    result.a = mk(nkIdent, nt)
    result.a.name = name
  result.proto = pr

proc parseArrow(ps: var Parser): Node =
  let t = ps.tok
  let pr = Proto(isArrow: true, file: ps.file, line: t.line, col: t.col)
  if ps.tok.kind == tkIdent:
    let id = mk(nkIdent, t)
    id.name = t.text
    pr.rawParams = @[id]
    ps.next
  else:
    pr.rawParams = ps.parseParams()
  if ps.tok.kind != tkArrow: ps.unexpected()
  ps.next
  if ps.tok.kind == tkLBrace:
    pr.body = ps.parseFnBody()
  else:
    let loops = ps.loops
    let switches = ps.switches
    ps.loops = 0
    ps.switches = 0
    pr.exprBody = ps.parseAssign()
    ps.loops = loops
    ps.switches = switches
  result = mk(nkFunc, t)
  result.proto = pr

proc arrowAhead(ps: Parser): bool =
  var k = ps.p
  var depth = 0
  while k < ps.toks.len:
    case ps.toks[k].kind
    of tkLParen, tkLBracket, tkLBrace: inc depth
    of tkRParen, tkRBracket, tkRBrace:
      dec depth
      if depth == 0: return k + 1 < ps.toks.len and ps.toks[k + 1].kind == tkArrow
    of tkEof: return false
    else: discard
    inc k
  false

proc parseArgs(ps: var Parser): seq[Node] =
  ps.next
  while ps.tok.kind != tkRParen:
    if ps.tok.kind == tkEllipsis:
      let t = ps.tok
      ps.next
      let s = mk(nkSpread, t)
      s.a = ps.parseAssign()
      result.add s
    else:
      result.add ps.parseAssign()
    if ps.tok.kind == tkComma: ps.next
    elif ps.tok.kind != tkRParen: ps.unexpected()
  ps.next

proc parseTemplate(ps: var Parser; t: Token): Node =
  if t.parts.len == 1:
    result = mk(nkConst, t)
    result.val = strV(t.parts[0].s)
    return
  result = mk(nkTemplate, t)
  for part in t.parts:
    if part.isExpr:
      var sub = Parser(toks: lexRange(ps.src.s, part.a, part.b, part.line, part.col, ps.file),
                       src: ps.src, file: ps.file, depth: ps.depth + 1)
      if sub.tok.kind == tkEof: synErr(ps.file, part.line, part.col, "Empty expression in a template")
      let e = sub.parseExpr()
      if sub.tok.kind != tkEof: sub.unexpected()
      result.list.add e
    elif part.s.len > 0:
      let c = mk(nkConst, t)
      c.val = strV(part.s)
      result.list.add c

proc memberNode(ps: var Parser; e: Node; inOpt, optional: bool): Node =
  let nt = ps.tok
  if nt.kind != tkIdent: ps.unexpected()
  ps.next
  result = mk(nkMember, nt)
  result.a = e
  result.name = nt.text
  result.meth = methodOf(nt.text)
  if inOpt: result.flags.incl nfInOpt
  if optional: result.flags.incl nfOptional

proc parseObjectLit(ps: var Parser): Node =
  let t = ps.tok
  ps.next
  result = mk(nkObject, t)
  while ps.tok.kind != tkRBrace:
    let kt = ps.tok
    if kt.kind == tkEllipsis:
      ps.next
      let s = mk(nkSpread, kt)
      s.a = ps.parseAssign()
      result.list.add s
    else:
      let p = mk(nkProp, kt)
      var shorthand = false
      case kt.kind
      of tkIdent:
        if (kt.text == "get" or kt.text == "set") and
            ps.peekTok.kind notin {tkColon, tkLParen, tkComma, tkRBrace, tkAssign}:
          ps.errAt(kt, "Getters and setters are not supported")
        p.name = kt.text
        shorthand = not isReserved(kt.text)
        ps.next
      of tkStr:
        p.name = kt.text
        ps.next
      of tkNum:
        p.name = numToStr(kt.num)
        ps.next
      of tkLBracket:
        ps.next
        p.a = ps.parseAssign()
        ps.expect(tkRBracket)
      of tkStar: ps.errAt(kt, "Generator functions are not supported")
      else: ps.unexpected()
      case ps.tok.kind
      of tkColon:
        ps.next
        p.b = ps.parseAssign()
        if p.a == nil: nameFunction(p.b, p.name)
      of tkLParen:
        let pr = Proto(name: p.name, file: ps.file, line: kt.line, col: kt.col)
        pr.rawParams = ps.parseParams()
        pr.body = ps.parseFnBody()
        let f = mk(nkFunc, kt)
        f.proto = pr
        p.b = f
      of tkComma, tkRBrace:
        if not shorthand: ps.unexpected()
        let id = mk(nkIdent, kt)
        id.name = p.name
        p.b = id
      of tkAssign:
        if not shorthand: ps.unexpected()
        ps.next
        let id = mk(nkIdent, kt)
        id.name = p.name
        let d = mk(nkAssign, kt)
        d.a = id
        d.b = ps.parseAssign()
        d.op = nkEmpty
        p.b = d
      else: ps.unexpected()
      result.list.add p
    if ps.tok.kind == tkComma: ps.next
    elif ps.tok.kind != tkRBrace: ps.unexpected()
  ps.next

proc parsePrimary(ps: var Parser): Node =
  let t = ps.tok
  case t.kind
  of tkNum:
    ps.next
    result = mk(nkConst, t)
    result.val = numV(t.num)
  of tkStr:
    ps.next
    result = mk(nkConst, t)
    result.val = strV(t.text)
  of tkTemplate:
    ps.next
    result = ps.parseTemplate(t)
  of tkLParen:
    ps.next
    result = ps.parseExpr()
    ps.expect(tkRParen)
    result.flags.incl nfParen
  of tkLBracket:
    ps.next
    result = mk(nkArray, t)
    while ps.tok.kind != tkRBracket:
      if ps.tok.kind == tkComma:
        result.list.add mk(nkHole, ps.tok)
        ps.next
        continue
      if ps.tok.kind == tkEllipsis:
        let st = ps.tok
        ps.next
        let s = mk(nkSpread, st)
        s.a = ps.parseAssign()
        result.list.add s
      else:
        result.list.add ps.parseAssign()
      if ps.tok.kind == tkComma: ps.next
      elif ps.tok.kind != tkRBracket: ps.unexpected()
    ps.next
  of tkLBrace:
    result = ps.parseObjectLit()
  of tkSlash, tkDivAs:
    ps.errAt(t, "Regular expressions are not supported")
  of tkIdent:
    case t.text
    of "function": result = ps.parseFunction(isExpr = true)
    of "true", "false":
      ps.next
      result = mk(nkConst, t)
      result.val = boolV(t.text == "true")
    of "null":
      ps.next
      result = mk(nkConst, t)
      result.val = nullV()
    of "this":
      ps.next
      result = mk(nkIdent, t)
      result.name = "this"
    of "class": ps.errAt(t, "Classes are not supported")
    of "async": ps.errAt(t, "async functions are not supported")
    else:
      if isReserved(t.text): ps.unexpected()
      ps.next
      result = mk(nkIdent, t)
      result.name = t.text
  else:
    ps.unexpected()

proc parseNew(ps: var Parser): Node =
  let t = ps.tok
  ps.next
  if ps.tok.kind == tkDot: ps.errAt(ps.tok, "new.target is not supported")
  var callee = if ps.tok.isWord("new"): ps.parseNew() else: ps.parsePrimary()
  while true:
    if ps.tok.kind == tkDot:
      ps.next
      callee = ps.memberNode(callee, false, false)
    elif ps.tok.kind == tkLBracket:
      let bt = ps.tok
      ps.next
      let n = mk(nkIndex, bt)
      n.a = callee
      n.b = ps.parseExpr()
      ps.expect(tkRBracket)
      callee = n
    else: break
  result = mk(nkNew, t)
  result.a = callee
  if ps.tok.kind == tkLParen: result.list = ps.parseArgs()

proc parseCallMember(ps: var Parser): Node =
  var e = if ps.tok.isWord("new"): ps.parseNew() else: ps.parsePrimary()
  var inOpt = false
  while true:
    let t = ps.tok
    case t.kind
    of tkDot:
      ps.next
      e = ps.memberNode(e, inOpt, false)
    of tkQDot:
      ps.next
      inOpt = true
      if ps.tok.kind == tkLParen:
        let n = mkAt(nkCall, e)
        n.a = e
        n.list = ps.parseArgs()
        n.flags = {nfOptional, nfInOpt}
        e = n
      elif ps.tok.kind == tkLBracket:
        ps.next
        let n = mk(nkIndex, t)
        n.a = e
        n.b = ps.parseExpr()
        ps.expect(tkRBracket)
        n.flags = {nfOptional, nfInOpt}
        e = n
      else:
        e = ps.memberNode(e, true, true)
    of tkLBracket:
      ps.next
      let n = mk(nkIndex, t)
      n.a = e
      n.b = ps.parseExpr()
      ps.expect(tkRBracket)
      if inOpt: n.flags.incl nfInOpt
      e = n
    of tkLParen:
      let n = mkAt(nkCall, e)
      n.a = e
      n.list = ps.parseArgs()
      if inOpt: n.flags.incl nfInOpt
      e = n
    of tkTemplate:
      ps.errAt(t, "Tagged templates are not supported")
    else: break
  if inOpt:
    let w = mkAt(nkOptChain, e)
    w.a = e
    e = w
  e

proc parsePostfix(ps: var Parser): Node =
  result = ps.parseCallMember()
  let t = ps.tok
  if t.kind in {tkInc, tkDec} and not t.nl:
    if result.kind notin {nkIdent, nkMember, nkIndex}:
      ps.errAt(t, "Invalid left-hand side expression in postfix operation")
    ps.next
    let n = mkAt(nkIncDec, result)
    n.a = result
    n.slot = (if t.kind == tkInc: 1 else: -1)
    result = n

proc parseUnary(ps: var Parser): Node =
  inc ps.depth
  if ps.depth > maxNesting: ps.errAt(ps.tok, "The script is nested too deeply")
  let t = ps.tok
  case t.kind
  of tkNot, tkMinus, tkPlus, tkTilde:
    ps.next
    let a = ps.parseUnary()
    if t.kind == tkMinus and a.kind == nkConst and a.val.kind == vkNum and nfParen notin a.flags:
      a.val = numV(-a.val.nval)
      a.line = int32(t.line)
      a.col = int32(t.col)
      result = a
    else:
      result = mk((if t.kind == tkNot: nkNot elif t.kind == tkMinus: nkNeg elif t.kind == tkPlus: nkPos else: nkBitNot), t)
      result.a = a
  of tkInc, tkDec:
    ps.next
    let a = ps.parseUnary()
    if a.kind notin {nkIdent, nkMember, nkIndex}:
      ps.errAt(t, "Invalid left-hand side expression in prefix operation")
    result = mk(nkIncDec, t)
    result.a = a
    result.flags.incl nfPrefix
    result.slot = (if t.kind == tkInc: 1 else: -1)
  of tkIdent:
    case t.text
    of "typeof", "void", "delete":
      ps.next
      result = mk((if t.text == "typeof": nkTypeof elif t.text == "void": nkVoid else: nkDelete), t)
      result.a = ps.parseUnary()
    of "await": ps.errAt(t, "await is not supported")
    else: result = ps.parsePostfix()
  else:
    result = ps.parsePostfix()
  dec ps.depth

proc binInfo(t: Token): (int, NodeKind) =
  case t.kind
  of tkNullish: (1, nkNullish)
  of tkOrOr: (2, nkOr)
  of tkAndAnd: (3, nkAnd)
  of tkPipe: (4, nkBitOr)
  of tkCaret: (5, nkBitXor)
  of tkAmp: (6, nkBitAnd)
  of tkEq: (7, nkEq)
  of tkNe: (7, nkNe)
  of tkSeq: (7, nkSeq)
  of tkSne: (7, nkSne)
  of tkLt: (8, nkLt)
  of tkLe: (8, nkLe)
  of tkGt: (8, nkGt)
  of tkGe: (8, nkGe)
  of tkIdent:
    if t.text == "in": (8, nkIn)
    elif t.text == "instanceof": (8, nkInstanceof)
    else: (0, nkEmpty)
  of tkShl: (9, nkShl)
  of tkShr: (9, nkShr)
  of tkUShr: (9, nkUShr)
  of tkPlus: (10, nkAdd)
  of tkMinus: (10, nkSub)
  of tkStar: (11, nkMul)
  of tkSlash: (11, nkDiv)
  of tkPercent: (11, nkMod)
  of tkPow: (12, nkPow)
  else: (0, nkEmpty)

proc parseBinary(ps: var Parser; minPrec: int): Node =
  result = ps.parseUnary()
  while true:
    let (prec, kind) = binInfo(ps.tok)
    if prec == 0 or prec < minPrec: break
    let t = ps.tok
    ps.next
    let rhs = if kind == nkPow: ps.parseBinary(prec) else: ps.parseBinary(prec + 1)
    let n = mk(kind, t)
    n.a = result
    n.b = rhs
    result = n

proc parseConditional(ps: var Parser): Node =
  result = ps.parseBinary(1)
  if ps.tok.kind == tkQuestion:
    let t = ps.tok
    ps.next
    let n = mk(nkCond, t)
    n.a = result
    n.b = ps.parseAssign()
    ps.expect(tkColon)
    n.c = ps.parseAssign()
    result = n

proc toPattern(ps: Parser; n: Node): Node =
  case n.kind
  of nkIdent, nkMember, nkIndex: n
  of nkArray:
    let r = mkAt(nkArrayPat, n)
    for i, e in n.list:
      case e.kind
      of nkHole: r.list.add e
      of nkSpread:
        if i != n.list.len - 1: synErr(ps.file, e.line, e.col, "A rest element must be last")
        let x = mkAt(nkRest, e)
        x.a = ps.toPattern(e.a)
        r.list.add x
      else: r.list.add ps.toPattern(e)
    r
  of nkObject:
    let r = mkAt(nkObjPat, n)
    for p in n.list:
      if p.kind == nkSpread:
        let x = mkAt(nkRest, p)
        x.a = ps.toPattern(p.a)
        r.list.add x
      else:
        let q = mkAt(nkPatProp, p)
        q.name = p.name
        q.a = p.a
        q.b = ps.toPattern(p.b)
        r.list.add q
    r
  of nkAssign:
    if n.op != nkEmpty: synErr(ps.file, n.line, n.col, "Invalid destructuring assignment target")
    let d = mkAt(nkDefault, n)
    d.a = ps.toPattern(n.a)
    d.b = n.b
    d
  else:
    synErr(ps.file, n.line, n.col, "Invalid destructuring assignment target")

proc assignOp(k: TokKind): NodeKind =
  case k
  of tkAddAs: nkAdd
  of tkSubAs: nkSub
  of tkMulAs: nkMul
  of tkDivAs: nkDiv
  of tkModAs: nkMod
  of tkPowAs: nkPow
  of tkShlAs: nkShl
  of tkShrAs: nkShr
  of tkUShrAs: nkUShr
  of tkAndAs: nkBitAnd
  of tkOrAs: nkBitOr
  of tkXorAs: nkBitXor
  of tkLAndAs: nkAnd
  of tkLOrAs: nkOr
  of tkNullAs: nkNullish
  else: nkEmpty

proc parseAssign(ps: var Parser): Node =
  let t = ps.tok
  if t.kind == tkIdent and ps.peekTok.kind == tkArrow and not isReserved(t.text): return ps.parseArrow()
  if t.kind == tkLParen and ps.arrowAhead(): return ps.parseArrow()
  if t.isWord("async") and (ps.peekTok.isWord("function") or ps.peekTok.kind == tkLParen):
    ps.errAt(t, "async functions are not supported")
  let left = ps.parseConditional()
  let opTok = ps.tok
  if opTok.kind in {tkAssign .. tkNullAs}:
    var target = left
    if opTok.kind == tkAssign and left.kind in {nkArray, nkObject} and nfParen notin left.flags:
      target = ps.toPattern(left)
    elif left.kind notin {nkIdent, nkMember, nkIndex}:
      ps.errAt(t, "Invalid left-hand side in assignment")
    ps.next
    let n = mkAt(nkAssign, left)
    n.a = target
    n.b = ps.parseAssign()
    n.op = assignOp(opTok.kind)
    if target.kind == nkIdent: nameFunction(n.b, target.name)
    return n
  left

proc parseExpr(ps: var Parser): Node =
  let first = ps.parseAssign()
  if ps.tok.kind != tkComma: return first
  result = mkAt(nkComma, first)
  result.list.add first
  while ps.tok.kind == tkComma:
    ps.next
    result.list.add ps.parseAssign()

proc parseBindingTarget(ps: var Parser): Node =
  let t = ps.tok
  case t.kind
  of tkIdent:
    if isReserved(t.text): ps.unexpected()
    ps.next
    result = mk(nkIdent, t)
    result.name = t.text
  of tkLBracket:
    ps.next
    result = mk(nkArrayPat, t)
    while ps.tok.kind != tkRBracket:
      if ps.tok.kind == tkComma:
        result.list.add mk(nkHole, ps.tok)
        ps.next
        continue
      if ps.tok.kind == tkEllipsis:
        let rt = ps.tok
        ps.next
        let r = mk(nkRest, rt)
        r.a = ps.parseBindingTarget()
        result.list.add r
        if ps.tok.kind != tkRBracket: ps.errAt(ps.tok, "A rest element must be last")
        break
      let et = ps.tok
      var e = ps.parseBindingTarget()
      if ps.tok.kind == tkAssign:
        ps.next
        let d = mk(nkDefault, et)
        d.a = e
        d.b = ps.parseAssign()
        e = d
      result.list.add e
      if ps.tok.kind == tkComma: ps.next
      elif ps.tok.kind != tkRBracket: ps.unexpected()
    ps.next
  of tkLBrace:
    ps.next
    result = mk(nkObjPat, t)
    while ps.tok.kind != tkRBrace:
      let kt = ps.tok
      if kt.kind == tkEllipsis:
        ps.next
        let r = mk(nkRest, kt)
        r.a = ps.parseBindingTarget()
        result.list.add r
        if ps.tok.kind != tkRBrace: ps.errAt(ps.tok, "A rest element must be last")
        break
      let p = mk(nkPatProp, kt)
      var short = false
      case kt.kind
      of tkIdent:
        p.name = kt.text
        short = not isReserved(kt.text)
        ps.next
      of tkStr:
        p.name = kt.text
        ps.next
      of tkNum:
        p.name = numToStr(kt.num)
        ps.next
      of tkLBracket:
        ps.next
        p.a = ps.parseAssign()
        ps.expect(tkRBracket)
      else: ps.unexpected()
      var target: Node = nil
      if ps.tok.kind == tkColon:
        ps.next
        target = ps.parseBindingTarget()
      elif short:
        target = mk(nkIdent, kt)
        target.name = p.name
      else: ps.unexpected()
      if ps.tok.kind == tkAssign:
        ps.next
        let d = mk(nkDefault, kt)
        d.a = target
        d.b = ps.parseAssign()
        target = d
      p.b = target
      result.list.add p
      if ps.tok.kind == tkComma: ps.next
      elif ps.tok.kind != tkRBrace: ps.unexpected()
    ps.next
  else:
    ps.unexpected()

proc consumeSemi(ps: var Parser) =
  if ps.tok.kind == tkSemi: ps.next
  elif ps.tok.kind in {tkRBrace, tkEof} or ps.tok.nl: discard
  else: ps.unexpected()

proc declFlags(word: string): set[NodeFlag] =
  case word
  of "const": {nfConst}
  of "var": {nfVar}
  else: {}

proc parseDeclItems(ps: var Parser; n: Node; first: Node = nil) =
  var target = first
  while true:
    if target == nil: target = ps.parseBindingTarget()
    let item = mkAt(nkDeclItem, target)
    item.a = target
    if ps.tok.kind == tkAssign:
      ps.next
      item.b = ps.parseAssign()
      if target.kind == nkIdent: nameFunction(item.b, target.name)
    elif nfConst in n.flags:
      ps.errAt(ps.tok, "Missing initializer in const declaration")
    elif target.kind != nkIdent:
      ps.errAt(ps.tok, "Missing initializer in destructuring declaration")
    n.list.add item
    target = nil
    if ps.tok.kind == tkComma: ps.next
    else: break

proc parseSubStatement(ps: var Parser): Node =
  ## The body of an if, a loop or a label: a declaration there needs braces.
  let t = ps.tok
  if t.kind == tkIdent and (t.text in ["let", "const", "function", "class"] and
      not (t.text == "let" and ps.peekTok.kind notin {tkIdent, tkLBracket, tkLBrace})):
    ps.errAt(t, "A declaration here needs braces: { " & t.text & " ... }")
  ps.parseStatement()

proc parseLoopBody(ps: var Parser): Node =
  inc ps.loops
  result = ps.parseSubStatement()
  dec ps.loops

proc parseFor(ps: var Parser): Node =
  let t = ps.tok
  ps.next
  if ps.tok.isWord("await"): ps.errAt(ps.tok, "for await is not supported")
  ps.expect(tkLParen)
  var init: Node = nil
  template forEachLoop(head: Node) =
    let isOf = ps.tok.text == "of"
    ps.next
    let n = mk((if isOf: nkForOf else: nkForIn), t)
    n.a = head
    n.b = if isOf: ps.parseAssign() else: ps.parseExpr()
    ps.expect(tkRParen)
    n.d = ps.parseLoopBody()
    return n
  let w = ps.tok
  if w.kind == tkIdent and w.text in ["let", "const", "var"]:
    ps.next
    let decl = mk(nkDecl, w)
    decl.flags = declFlags(w.text)
    let target = ps.parseBindingTarget()
    if ps.tok.isWord("of") or ps.tok.isWord("in"):
      let item = mkAt(nkDeclItem, target)
      item.a = target
      decl.list.add item
      forEachLoop(decl)
    ps.parseDeclItems(decl, target)
    init = decl
  elif w.kind == tkSemi:
    discard
  else:
    if w.kind == tkIdent and (ps.peekTok.isWord("of") or ps.peekTok.isWord("in")) and not isReserved(w.text):
      ps.next
      let id = mk(nkIdent, w)
      id.name = w.text
      forEachLoop(id)
    let e = ps.parseExpr()
    if ps.tok.isWord("of"):
      forEachLoop(ps.toPattern(e))
    let st = mkAt(nkExprStmt, e)
    st.a = e
    init = st
  ps.expect(tkSemi)
  result = mk(nkFor, t)
  result.a = init
  if ps.tok.kind != tkSemi: result.b = ps.parseExpr()
  ps.expect(tkSemi)
  if ps.tok.kind != tkRParen: result.c = ps.parseExpr()
  ps.expect(tkRParen)
  result.d = ps.parseLoopBody()

proc parseBlock(ps: var Parser): Node =
  let t = ps.tok
  ps.expect(tkLBrace)
  result = mk(nkBlock, t)
  while ps.tok.kind != tkRBrace:
    if ps.tok.kind == tkEof: ps.unexpected()
    result.list.add ps.parseStatement()
  ps.next

proc parseStatement(ps: var Parser): Node =
  result = nil         # (a value at once: see tools/writecheck.py)
  inc ps.depth
  if ps.depth > maxNesting: ps.errAt(ps.tok, "The script is nested too deeply")
  let t = ps.tok
  block parsed:
    case t.kind
    of tkLBrace:
      result = ps.parseBlock()
      break parsed
    of tkSemi:
      ps.next
      result = mk(nkEmpty, t)
      break parsed
    of tkIdent:
      case t.text
      of "let", "const", "var":
        ps.next
        result = mk(nkDecl, t)
        result.flags = declFlags(t.text)
        ps.parseDeclItems(result)
        ps.consumeSemi()
        break parsed
      of "function":
        result = ps.parseFunction(isExpr = false)
        break parsed
      of "if":
        ps.next
        ps.expect(tkLParen)
        result = mk(nkIf, t)
        result.a = ps.parseExpr()
        ps.expect(tkRParen)
        result.b = ps.parseSubStatement()
        if ps.tok.isWord("else"):
          ps.next
          result.c = ps.parseSubStatement()
        break parsed
      of "for":
        result = ps.parseFor()
        break parsed
      of "while":
        ps.next
        ps.expect(tkLParen)
        result = mk(nkWhile, t)
        result.a = ps.parseExpr()
        ps.expect(tkRParen)
        result.b = ps.parseLoopBody()
        break parsed
      of "do":
        ps.next
        result = mk(nkDoWhile, t)
        result.b = ps.parseLoopBody()
        if not ps.tok.isWord("while"): ps.unexpected()
        ps.next
        ps.expect(tkLParen)
        result.a = ps.parseExpr()
        ps.expect(tkRParen)
        if ps.tok.kind == tkSemi: ps.next
        break parsed
      of "return":
        ps.next
        result = mk(nkReturn, t)
        if ps.tok.kind notin {tkSemi, tkRBrace, tkEof} and not ps.tok.nl:
          result.a = ps.parseExpr()
        ps.consumeSemi()
        break parsed
      of "break", "continue":
        ps.next
        result = mk((if t.text == "break": nkBreak else: nkContinue), t)
        if ps.tok.kind == tkIdent and not ps.tok.nl and not isReserved(ps.tok.text):
          result.name = ps.tok.text
          var known, loop = false
          for (l, isLoop) in ps.labels:
            if l == result.name:
              known = true
              loop = isLoop
          if not known: ps.errAt(ps.tok, "Undefined label '" & result.name & "'")
          if t.text == "continue" and not loop:
            ps.errAt(ps.tok, "Illegal continue statement: '" & result.name & "' does not denote a loop")
          ps.next
        elif t.text == "break" and ps.loops == 0 and ps.switches == 0:
          ps.errAt(t, "Illegal break statement")
        elif t.text == "continue" and ps.loops == 0:
          ps.errAt(t, "Illegal continue statement: no surrounding loop")
        ps.consumeSemi()
        break parsed
      of "throw":
        ps.next
        if ps.tok.nl: ps.errAt(ps.tok, "Illegal newline after throw")
        result = mk(nkThrow, t)
        result.a = ps.parseExpr()
        ps.consumeSemi()
        break parsed
      of "try":
        ps.next
        result = mk(nkTry, t)
        result.a = ps.parseBlock()
        if ps.tok.isWord("catch"):
          ps.next
          if ps.tok.kind == tkLParen:
            ps.next
            result.c = ps.parseBindingTarget()
            ps.expect(tkRParen)
          result.b = ps.parseBlock()
        if ps.tok.isWord("finally"):
          ps.next
          result.d = ps.parseBlock()
        if result.b == nil and result.d == nil: ps.errAt(ps.tok, "Missing catch or finally after try")
        break parsed
      of "switch":
        ps.next
        ps.expect(tkLParen)
        result = mk(nkSwitch, t)
        result.a = ps.parseExpr()
        ps.expect(tkRParen)
        ps.expect(tkLBrace)
        inc ps.switches
        var hasDefault = false
        while ps.tok.kind != tkRBrace:
          let ct = ps.tok
          let cs = mk(nkCase, ct)
          if ct.isWord("case"):
            ps.next
            cs.a = ps.parseExpr()
          elif ct.isWord("default"):
            if hasDefault: ps.errAt(ct, "More than one default clause in switch statement")
            hasDefault = true
            ps.next
          else: ps.unexpected()
          ps.expect(tkColon)
          while ps.tok.kind != tkRBrace and not ps.tok.isWord("case") and not ps.tok.isWord("default"):
            if ps.tok.kind == tkEof: ps.unexpected()
            cs.list.add ps.parseStatement()
          result.list.add cs
        ps.next
        dec ps.switches
        break parsed
      of "debugger":
        ps.next
        ps.consumeSemi()
        result = mk(nkEmpty, t)
        break parsed
      of "class": ps.errAt(t, "Classes are not supported")
      of "import", "export": ps.errAt(t, "Modules are not supported")
      else:
        if ps.peekTok.kind == tkColon and not isReserved(t.text):
          ps.next
          ps.next
          let nt = ps.tok
          ps.labels.add (t.text, nt.kind == tkIdent and nt.text in ["for", "while", "do"])
          result = mk(nkLabeled, t)
          result.name = t.text
          result.a = ps.parseSubStatement()
          discard ps.labels.pop
          if result.a.kind in {nkWhile, nkDoWhile, nkFor, nkForOf, nkForIn}:
            result.a.labels.add t.text
          break parsed
    else: discard
    let e = ps.parseExpr()
    ps.consumeSemi()
    result = mkAt(nkExprStmt, e)
    result.a = e
  dec ps.depth

# ---- resolver: every variable to its slot ---------------------------------------------------------------------

type
  DeclKind = enum
    dLet, dConst, dVar, dParam, dFunc, dThis, dSelf
  CFunc = ref object
    nregs: int
  CScope = ref object
    parent: CScope
    fn: CFunc
    vars: seq[CVar]
    names: Table[string, CVar]
    isGlobal: bool
    envSize: int
  CVar = ref object
    name: string
    kind: DeclKind
    captured, used: bool
    fixed, slot: int
    scope: CScope
  RefRec = object
    node: Node
    scope: CScope
    v: CVar
  FnRec = object
    proto: Proto
    fn: CFunc
    scope: CScope
    thisVar, selfVar, argsVar: CVar
    thisNode, selfNode, argsNode: Node
  Resolver = object
    file: string
    scope: CScope
    fn: CFunc
    depth: int
    scopes: seq[CScope]
    refs: seq[RefRec]
    fns: seq[FnRec]
    envNodes: seq[(Node, CScope)]

proc rerr(r: Resolver; n: Node; msg: string) {.noreturn.} =
  synErr(r.file, int(n.line), int(n.col), msg)

proc pushScope(r: var Resolver): CScope =
  result = CScope(parent: r.scope, fn: r.fn)
  r.scopes.add result
  r.scope = result

proc declare(r: var Resolver; sc: CScope; name: string; kind: DeclKind; n: Node): CVar =
  if sc.isGlobal: return nil
  let old = sc.names.getOrDefault(name)
  if old != nil:
    if kind in {dLet, dConst} or old.kind in {dLet, dConst}:
      r.rerr(n, "Identifier '" & name & "' has already been declared")
    if kind == dFunc: old.kind = dFunc
    return old
  result = CVar(name: name, kind: kind, fixed: -1, slot: -1, scope: sc)
  sc.vars.add result
  sc.names[name] = result

proc declarePattern(r: var Resolver; sc: CScope; t: Node; kind: DeclKind) =
  case t.kind
  of nkIdent: discard r.declare(sc, t.name, kind, t)
  of nkArrayPat:
    for e in t.list: r.declarePattern(sc, e, kind)
  of nkObjPat:
    for p in t.list: r.declarePattern(sc, (if p.kind == nkPatProp: p.b else: p.a), kind)
  of nkDefault, nkRest: r.declarePattern(sc, t.a, kind)
  else: discard

proc hoistLexical(r: var Resolver; sc: CScope; list: openArray[Node]) =
  for s in list:
    case s.kind
    of nkDecl:
      if nfVar notin s.flags:
        let k = if nfConst in s.flags: dConst else: dLet
        for it in s.list: r.declarePattern(sc, it.a, k)
    of nkFuncDecl: discard r.declare(sc, s.a.name, dFunc, s)
    else: discard

proc hoistVars(r: var Resolver; sc: CScope; n: Node) =
  if n == nil: return
  case n.kind
  of nkDecl:
    if nfVar in n.flags:
      for it in n.list: r.declarePattern(sc, it.a, dVar)
  of nkBlock:
    for s in n.list: r.hoistVars(sc, s)
  of nkIf:
    r.hoistVars(sc, n.b)
    r.hoistVars(sc, n.c)
  of nkWhile, nkDoWhile, nkLabeled:
    r.hoistVars(sc, n.a)
    r.hoistVars(sc, n.b)
  of nkFor, nkForOf, nkForIn:
    r.hoistVars(sc, n.a)
    r.hoistVars(sc, n.d)
  of nkTry:
    r.hoistVars(sc, n.a)
    r.hoistVars(sc, n.b)
    r.hoistVars(sc, n.d)
  of nkSwitch:
    for cs in n.list:
      for s in cs.list: r.hoistVars(sc, s)
  else: discard

proc lookup(r: Resolver; name: string): CVar =
  var s = r.scope
  while s != nil and not s.isGlobal:
    let v = s.names.getOrDefault(name)
    if v != nil: return v
    s = s.parent
  nil

proc addRef(r: var Resolver; n: Node; v: CVar) =
  v.used = true
  if v.scope.fn != r.fn: v.captured = true
  r.refs.add RefRec(node: n, scope: r.scope, v: v)

proc resolve(r: var Resolver; n: Node)
proc resolveFunc(r: var Resolver; p: Proto)

proc resolveIdent(r: var Resolver; n: Node) =
  let v = r.lookup(n.name)
  if v != nil:
    r.addRef(n, v)
    return
  case n.name
  of "this", "undefined":
    n.kind = nkConst
    n.val = undef()
  of "NaN":
    n.kind = nkConst
    n.val = numV(NaN)
  of "Infinity":
    n.kind = nkConst
    n.val = numV(Inf)
  else:
    n.kind = nkGlobal

proc resolveTarget(r: var Resolver; n: Node) =
  case n.kind
  of nkIdent:
    let v = r.lookup(n.name)
    if v != nil:
      if v.kind == dConst: r.rerr(n, "Assignment to constant variable '" & n.name & "'")
      if v.kind == dThis: r.rerr(n, "Invalid assignment target")
      r.addRef(n, v)
    elif n.name == "this":
      r.rerr(n, "Invalid assignment target")
    else:
      n.kind = nkGlobal
  of nkMember: r.resolve(n.a)
  of nkIndex:
    r.resolve(n.a)
    r.resolve(n.b)
  of nkArrayPat:
    for e in n.list: r.resolveTarget(e)
  of nkObjPat:
    for p in n.list:
      if p.kind == nkPatProp:
        r.resolve(p.a)
        r.resolveTarget(p.b)
      else:
        r.resolveTarget(p.a)
  of nkDefault:
    r.resolveTarget(n.a)
    r.resolve(n.b)
  of nkRest: r.resolveTarget(n.a)
  of nkHole: discard
  else: r.rerr(n, "Invalid assignment target")

proc resolveDeclTarget(r: var Resolver; n: Node; kind: DeclKind) =
  case n.kind
  of nkIdent:
    let v = r.lookup(n.name)
    if v != nil:
      r.addRef(n, v)
    else:
      n.kind = nkGlobal
      n.flags.incl nfDeclare
      if kind == dConst: n.flags.incl nfConst
  of nkArrayPat:
    for e in n.list: r.resolveDeclTarget(e, kind)
  of nkObjPat:
    for p in n.list:
      if p.kind == nkPatProp:
        r.resolve(p.a)
        r.resolveDeclTarget(p.b, kind)
      else:
        r.resolveDeclTarget(p.a, kind)
  of nkDefault:
    r.resolveDeclTarget(n.a, kind)
    r.resolve(n.b)
  of nkRest: r.resolveDeclTarget(n.a, kind)
  else: discard

proc funcsFirst(n: Node) =
  var fs, others: seq[Node]
  for s in n.list:
    if s.kind == nkFuncDecl: fs.add s else: others.add s
  if fs.len > 0: n.list = fs & others

proc declKindOf(n: Node): DeclKind =
  if nfConst in n.flags: dConst elif nfVar in n.flags: dVar else: dLet

proc resolve(r: var Resolver; n: Node) =
  if n == nil: return
  inc r.depth
  if r.depth > maxTreeDepth: r.rerr(n, "The script is nested too deeply")
  case n.kind
  of nkConst, nkHole, nkEmpty, nkBreak, nkContinue, nkLocal, nkEnvVar, nkGlobal: discard
  of nkIdent: r.resolveIdent(n)
  of nkFunc: r.resolveFunc(n.proto)
  of nkAssign, nkIncDec:
    r.resolveTarget(n.a)
    r.resolve(n.b)
  of nkProp:
    r.resolve(n.a)
    r.resolve(n.b)
  of nkBlock:
    let saved = r.scope
    let sc = r.pushScope()
    r.hoistLexical(sc, n.list)
    for s in n.list: r.resolve(s)
    r.scope = saved
    r.envNodes.add (n, sc)
    funcsFirst(n)
  of nkDecl:
    let k = declKindOf(n)
    for it in n.list:
      r.resolve(it.b)
      r.resolveDeclTarget(it.a, k)
  of nkFuncDecl:
    r.resolveFunc(n.proto)
    r.resolveDeclTarget(n.a, dFunc)
  of nkFor:
    let saved = r.scope
    let sc = r.pushScope()
    if n.a != nil and n.a.kind == nkDecl: r.hoistLexical(sc, [n.a])
    r.resolve(n.a)
    r.resolve(n.b)
    r.resolve(n.c)
    r.resolve(n.d)
    r.scope = saved
    r.envNodes.add (n, sc)
  of nkForOf, nkForIn:
    r.resolve(n.b)
    let saved = r.scope
    let sc = r.pushScope()
    if n.a.kind == nkDecl:
      r.hoistLexical(sc, [n.a])
      r.resolveDeclTarget(n.a.list[0].a, declKindOf(n.a))
    else:
      r.resolveTarget(n.a)
    r.resolve(n.d)
    r.scope = saved
    r.envNodes.add (n, sc)
  of nkSwitch:
    r.resolve(n.a)
    let saved = r.scope
    let sc = r.pushScope()
    for cs in n.list: r.hoistLexical(sc, cs.list)
    for cs in n.list:
      r.resolve(cs.a)
      for s in cs.list: r.resolve(s)
    r.scope = saved
    r.envNodes.add (n, sc)
  of nkTry:
    r.resolve(n.a)
    if n.b != nil:
      let saved = r.scope
      let sc = r.pushScope()
      if n.c != nil:
        r.declarePattern(sc, n.c, dLet)
        r.resolveDeclTarget(n.c, dLet)
      r.hoistLexical(sc, n.b.list)
      for s in n.b.list: r.resolve(s)
      funcsFirst(n.b)
      r.scope = saved
      r.envNodes.add (n.b, sc)
    r.resolve(n.d)
  else:
    r.resolve(n.a)
    r.resolve(n.b)
    r.resolve(n.c)
    r.resolve(n.d)
    for x in n.list: r.resolve(x)
  dec r.depth

proc resolveFunc(r: var Resolver; p: Proto) =
  let savedScope = r.scope
  let savedFn = r.fn
  let f = CFunc()
  r.fn = f
  let sc = r.pushScope()
  var np = 0
  for rp in p.rawParams:
    if rp.kind != nkRest: inc np
  p.nparams = np
  f.nregs = np
  var idx = 0
  for rp in p.rawParams:
    let target = if rp.kind in {nkRest, nkDefault}: rp.a else: rp
    r.declarePattern(sc, target, dParam)
    if rp.kind != nkRest:
      if target.kind == nkIdent: sc.names[target.name].fixed = idx
      inc idx
  var rec = FnRec(proto: p, fn: f, scope: sc)
  if not p.isArrow:
    rec.thisVar = r.declare(sc, "this", dThis, nil)
    rec.thisNode = Node(kind: nkIdent, name: "this", line: int32(p.line), col: int32(p.col))
  if p.selfNamed and sc.names.getOrDefault(p.name) == nil:
    rec.selfVar = r.declare(sc, p.name, dSelf, nil)
    rec.selfNode = Node(kind: nkIdent, name: p.name, line: int32(p.line), col: int32(p.col))
  if not p.isArrow and sc.names.getOrDefault("arguments") == nil:
    rec.argsVar = r.declare(sc, "arguments", dSelf, nil)
    rec.argsNode = Node(kind: nkIdent, name: "arguments", line: int32(p.line), col: int32(p.col))
  if p.body != nil:
    r.hoistVars(sc, p.body)
    r.hoistLexical(sc, p.body.list)
  p.params = newSeq[Node](np)
  idx = 0
  for rp in p.rawParams:
    case rp.kind
    of nkRest:
      r.resolveDeclTarget(rp.a, dParam)
      p.rest = rp.a
    of nkDefault:
      r.resolveDeclTarget(rp.a, dParam)
      r.resolve(rp.b)
      p.params[idx] = rp
      inc idx
    else:
      r.resolveDeclTarget(rp, dParam)
      let d = mkAt(nkDefault, rp)
      d.a = rp
      p.params[idx] = d
      inc idx
  if rec.thisVar != nil: r.refs.add RefRec(node: rec.thisNode, scope: sc, v: rec.thisVar)
  if rec.selfVar != nil: r.refs.add RefRec(node: rec.selfNode, scope: sc, v: rec.selfVar)
  if rec.argsVar != nil: r.refs.add RefRec(node: rec.argsNode, scope: sc, v: rec.argsVar)
  if p.body != nil:
    for s in p.body.list: r.resolve(s)
    funcsFirst(p.body)
  else:
    r.resolve(p.exprBody)
  r.fns.add rec
  r.scope = savedScope
  r.fn = savedFn

proc finish(r: var Resolver) =
  for sc in r.scopes:
    var e = 0
    for v in sc.vars:
      if v.kind in {dThis, dSelf} and not v.used: continue
      if v.captured:
        v.slot = e
        inc e
      elif v.fixed >= 0:
        v.slot = v.fixed
      else:
        v.slot = sc.fn.nregs
        inc sc.fn.nregs
    sc.envSize = e
  for rr in r.refs:
    let n = rr.node
    let v = rr.v
    if v.captured:
      var hops = 0
      var s = rr.scope
      while s != v.scope:
        if s.envSize > 0: inc hops
        s = s.parent
      n.kind = nkEnvVar
      n.hops = int32(hops)
    else:
      n.kind = nkLocal
    n.slot = int32(v.slot)
  for (node, sc) in r.envNodes: node.envSize = int32(sc.envSize)
  for rec in r.fns:
    let p = rec.proto
    p.nregs = rec.fn.nregs
    p.envSize = rec.scope.envSize
    if rec.thisVar != nil and rec.thisVar.used: p.thisTarget = rec.thisNode
    if rec.selfVar != nil and rec.selfVar.used: p.selfTarget = rec.selfNode
    if rec.argsVar != nil and rec.argsVar.used: p.argsTarget = rec.argsNode
    var simple = p.rest == nil and p.thisTarget == nil and p.selfTarget == nil and p.argsTarget == nil
    for i in 0 ..< p.params.len:
      let d = p.params[i]
      if d.b == nil and d.a.kind == nkLocal and d.a.slot == i: p.params[i] = nil
      else: simple = false
    p.simple = simple

proc compile*(src: string; name = "script"): Script =
  ## Reads a script. Raises `ScriptError` (a SyntaxError, with its line and
  ## column) when it can't.
  var ps = Parser(toks: lexRange(src, 0, src.len, 1, 1, name), src: SrcRef(s: src), file: name)
  let prog = Node(kind: nkBlock, line: 1, col: 1)
  while ps.tok.kind != tkEof: prog.list.add ps.parseStatement()
  var top = initTable[string, bool]()
  proc checkTop(t: Node; lexical: bool) =
    case t.kind
    of nkIdent:
      if t.name in top and (lexical or top[t.name]):
        synErr(name, int(t.line), int(t.col), "Identifier '" & t.name & "' has already been declared")
      top[t.name] = lexical or top.getOrDefault(t.name)
    of nkArrayPat, nkObjPat:
      for e in t.list: checkTop((if e.kind == nkPatProp: e.b else: e), lexical)
    of nkDefault, nkRest: checkTop(t.a, lexical)
    else: discard
  for st in prog.list:
    if st.kind == nkDecl:
      for it in st.list: checkTop(it.a, nfVar notin st.flags)
    elif st.kind == nkFuncDecl:
      checkTop(st.a, false)
  var r = Resolver(file: name)
  let main = Proto(name: "<main>", file: name, line: 1, col: 1, body: prog)
  let f = CFunc()
  r.fn = f
  let g = CScope(fn: f, isGlobal: true)
  r.scopes.add g
  r.scope = g
  for s in prog.list: r.resolve(s)
  funcsFirst(prog)
  r.fns.add FnRec(proto: main, fn: f, scope: g)
  r.finish()
  Script(name: name, main: main)

# ---- the interpreter: errors and limits --------------------------------------------------------------------------

proc curFile(vm: Vm): string =
  if vm.depth > 0: vm.calls[vm.depth - 1].proto.file else: "script"

proc captureStack(vm: Vm; n: Node): seq[string] =
  var line = if n != nil: int(n.line) else: 0
  var col = if n != nil: int(n.col) else: 0
  var i = vm.depth - 1
  while i >= 0:
    if result.len >= 10:
      result.add "..."
      break
    let p = vm.calls[i].proto
    let nm = if p.name.len > 0: p.name else: "<anonymous>"
    result.add "at " & nm & " (" & p.file & ":" & $line & ":" & $col & ")"
    let site = vm.calls[i].site
    if site != nil:
      line = int(site.line)
      col = int(site.col)
    else:
      line = 0
      col = 0
    dec i

proc makeError(vm: Vm; name, msg: string; n: Node): Value =
  let o = Obj()
  o.put("name", strV(name))
  o.put("message", strV(msg))
  o.err = ErrInfo(file: vm.curFile, line: (if n != nil: int(n.line) else: 0),
                  col: (if n != nil: int(n.col) else: 0), stack: vm.captureStack(n))
  objV(o)

proc raiseValue(vm: Vm; v: Value; n: Node) {.noreturn.} =
  if v.kind == vkObject and v.oval.err != nil:
    let e = v.oval.err
    raise newScriptError(e.file, e.line, e.col, errorText(v.oval), v, e.stack)
  raise newScriptError(vm.curFile, (if n != nil: int(n.line) else: 0), (if n != nil: int(n.col) else: 0),
                       "Uncaught " & inspect(v), v, vm.captureStack(n))

proc throwErr(vm: Vm; n: Node; name, msg: string) {.noreturn.} =
  vm.raiseValue(vm.makeError(name, msg, n), n)

proc typeErr(vm: Vm; n: Node; msg: string) {.noreturn.} = vm.throwErr(n, "TypeError", msg)
proc rangeErr(vm: Vm; n: Node; msg: string) {.noreturn.} = vm.throwErr(n, "RangeError", msg)

proc stopScript(vm: Vm; n: Node) {.noreturn.} =
  let msg = if atomicLoadN(addr vm.cancelled, ATOMIC_RELAXED): "the script was cancelled"
            else: "the script ran too long"
  raise newScriptError(vm.curFile, (if n != nil: int(n.line) else: 0), (if n != nil: int(n.col) else: 0),
                       msg, strV(msg), vm.captureStack(n), fatal = true)

template step(vm: Vm; n: Node) =
  dec vm.left
  if vm.left < 0 or atomicLoadN(addr vm.cancelled, ATOMIC_RELAXED): stopScript(vm, n)

proc charge(vm: Vm; work: int; n: Node) =
  vm.left -= work shr 4
  if vm.left < 0: stopScript(vm, n)

proc checkStr(vm: Vm; L: int; n: Node) {.inline.} =
  if L > vm.maxStringLen: vm.rangeErr(n, "Invalid string length")

proc checkArr(vm: Vm; L: int; n: Node) {.inline.} =
  if L > vm.maxArrayLen: vm.rangeErr(n, "Invalid array length")

proc describe(n: Node): string =
  if n == nil: return "value"
  case n.kind
  of nkIdent, nkLocal, nkEnvVar, nkGlobal: n.name
  of nkMember: describe(n.a) & "." & n.name
  of nkIndex: describe(n.a) & "[...]"
  of nkCall: describe(n.a) & "(...)"
  of nkOptChain: describe(n.a)
  of nkConst: inspect(n.val)
  else: "expression"

template hostGuard(vm: Vm; n: Node; body: untyped) =
  try:
    body
  except ScriptError:
    raise
  except CatchableError as e:
    vm.throwErr(n, "Error", e.msg)

proc push(vm: Vm; v: sink Value) {.inline.} =
  if vm.sp >= vm.stack.len: vm.stack.setLen(max(256, vm.stack.len * 2))
  vm.stack[vm.sp] = v
  inc vm.sp

proc defineSlot(vm: Vm; name: string): int =
  result = vm.gnames.getOrDefault(name, -1)
  if result < 0:
    result = vm.gvals.len
    vm.gnames[name] = result
    vm.gvals.add undef()
    vm.gconst.add false

proc globalSlot(vm: Vm; n: Node): int {.inline.} =
  if n.gvm == vm.id: return int(n.gslot)
  result = vm.gnames.getOrDefault(n.name, -1)
  if result < 0: vm.throwErr(n, "ReferenceError", n.name & " is not defined")
  n.gvm = vm.id
  n.gslot = int32(result)

proc assignGlobal(vm: Vm; n: Node; v: Value) =
  var i: int
  if n.gvm == vm.id:
    i = int(n.gslot)
  else:
    i = vm.defineSlot(n.name)
    n.gvm = vm.id
    n.gslot = int32(i)
  if vm.gconst[i]: vm.typeErr(n, "Assignment to constant variable '" & n.name & "'")
  vm.gvals[i] = v

# ---- the interpreter: properties --------------------------------------------------------------------------------

proc eval(vm: Vm; n: Node): Value
proc exec(vm: Vm; n: Node): Completion
proc callValue(vm: Vm; f: Value; this: Value; base, argc: int; site: Node): Value
proc callMethod(vm: Vm; recv: Value; m: MethodId; base, argc: int; n: Node): Value

proc boundMethod(v: Value; m: MethodId): Value =
  Value(kind: vkFunction, fval: Fn(kind: fkBound, name: $m, recv: v, meth: m))

proc kindWord(v: Value): string = (if v.kind == vkNull: "null" else: "undefined")

proc getMember(vm: Vm; v: Value; key: string; n: Node): Value =
  case v.kind
  of vkObject: result = v.oval.getProp(key)
  of vkArray:
    if key == "length": result = numV(float(v.aval.items.len)); return
    let i = indexKey(key)
    if i >= 0: result = (if i < v.aval.items.len: v.aval.items[i] else: undef()); return
    let m = methodOf(key)
    if m in arrMethods: result = boundMethod(v, m)
  of vkStr:
    if key == "length": result = numV(float(v.sval.cpCount)); return
    let i = indexKey(key)
    if i >= 0: result = (if i < v.sval.cpCount: strV(v.sval.cpSlice(i, i + 1)) else: undef()); return
    let m = methodOf(key)
    if m in strMethods: result = boundMethod(v, m)
  of vkNum:
    let m = methodOf(key)
    if m in numMethods: result = boundMethod(v, m)
  of vkBool:
    let m = methodOf(key)
    if m in {mToString, mValueOf}: result = boundMethod(v, m)
  of vkFunction:
    let f = v.fval
    if f.props != nil:
      let i = f.props.find(key)
      if i >= 0: result = f.props.vals[i]; return
    if key == "name": result = strV(f.name)
    elif key == "length": result = numV(float(if f.kind == fkScript: f.proto.nparams else: 0))
    else:
      let m = methodOf(key)
      if m in fnMethods: result = boundMethod(v, m)
  of vkHost:
    if v.hval.get == nil: result = undef(); return
    vm.hostGuard(n):
      result = v.hval.get(key)
  of vkUndefined, vkNull:
    vm.typeErr(n, "Cannot read properties of " & kindWord(v) & " (reading '" & key & "')")

proc getIndex(vm: Vm; o, k: Value; n: Node): Value =
  if k.kind == vkNum:
    if o.kind == vkArray:
      let x = k.nval
      if x >= 0 and x < float(o.aval.items.len) and x == trunc(x): return o.aval.items[int(x)]
      if x == trunc(x): return undef()
    elif o.kind == vkStr:
      let x = k.nval
      let L = o.sval.cpCount
      if x >= 0 and x < float(L) and x == trunc(x):
        let i = int(x)
        return strV(o.sval.cpSlice(i, i + 1))
  vm.getMember(o, propKey(k), n)

proc setArrayIndex(vm: Vm; a: Arr; x: float64; v: Value; n: Node) =
  if x >= 0 and x == trunc(x) and x < float(high(int32)):
    let i = int(x)
    if i < a.items.len:
      a.items[i] = v
    else:
      vm.checkArr(i + 1, n)
      vm.charge(i - a.items.len, n)
      a.items.setLen(i + 1)
      a.items[i] = v
  else:
    vm.rangeErr(n, "Invalid array index " & numToStr(x))

proc setLength(vm: Vm; a: Arr; v: Value; n: Node) =
  let x = toNum(v)
  if x != x or x < 0 or x != trunc(x): vm.rangeErr(n, "Invalid array length")
  vm.checkArr(clampInt(x, 0, high(int32)), n)
  let L = int(x)
  if L > a.items.len: vm.charge(L - a.items.len, n)
  a.items.setLen(L)

proc setMember(vm: Vm; o: Value; key: string; v: Value; n: Node) =
  case o.kind
  of vkObject:
    if o.oval.keys.len >= vm.maxArrayLen and o.oval.find(key) < 0:
      vm.rangeErr(n, "Too many properties")
    o.oval.put(key, v)
  of vkArray:
    if key == "length": vm.setLength(o.aval, v, n)
    else:
      let i = indexKey(key)
      if i >= 0: vm.setArrayIndex(o.aval, float(i), v, n)
      else: vm.typeErr(n, "Cannot add property '" & key & "' to an array")
  of vkHost:
    var ok = false
    if o.hval.set != nil:
      vm.hostGuard(n):
        ok = o.hval.set(key, v)
    if not ok: vm.typeErr(n, "Cannot set property '" & key & "' of " & describe(n.a))
  of vkFunction:
    if o.fval.props == nil: o.fval.props = Obj()
    o.fval.props.put(key, v)
  of vkUndefined, vkNull:
    vm.typeErr(n, "Cannot set properties of " & kindWord(o) & " (setting '" & key & "')")
  else: discard

proc setIndex(vm: Vm; o, k, v: Value; n: Node) =
  if o.kind == vkArray and k.kind == vkNum: vm.setArrayIndex(o.aval, k.nval, v, n)
  else: vm.setMember(o, propKey(k), v, n)

proc ownKeys(v: Value): seq[string] =
  case v.kind
  of vkObject: v.oval.keys
  of vkArray:
    var r = newSeq[string](v.aval.items.len)
    for i in 0 ..< r.len: r[i] = $i
    r
  of vkStr:
    var r = newSeq[string](v.sval.cpCount)
    for i in 0 ..< r.len: r[i] = $i
    r
  of vkFunction: (if v.fval.props != nil: v.fval.props.keys else: @[])
  else: @[]

proc hasKey(vm: Vm; o: Value; key: string; n: Node): bool =
  case o.kind
  of vkObject: o.oval.find(key) >= 0
  of vkArray:
    let i = indexKey(key)
    key == "length" or (i >= 0 and i < o.aval.items.len)
  of vkFunction: o.fval.props != nil and o.fval.props.find(key) >= 0
  of vkHost: vm.getMember(o, key, n).kind != vkUndefined
  else: vm.typeErr(n, "Cannot use 'in' operator to search for '" & key & "' in " & toStr(o))

proc deleteKey(vm: Vm; o: Value; key: string; n: Node): bool =
  case o.kind
  of vkObject: discard o.oval.del(key)
  of vkArray:
    let i = indexKey(key)
    if i >= 0 and i < o.aval.items.len: o.aval.items[i] = undef()
    elif key == "length": return false
  of vkFunction:
    if o.fval.props != nil: discard o.fval.props.del(key)
  of vkHost: return false
  of vkUndefined, vkNull:
    vm.typeErr(n, "Cannot convert " & kindWord(o) & " to object")
  else: discard
  true

# ---- the interpreter: operators ---------------------------------------------------------------------------------

proc addValues(vm: Vm; a, b: Value; n: Node): Value =
  let pa = toPrim(a)
  let pb = toPrim(b)
  if pa.kind == vkStr or pb.kind == vkStr:
    let sa = if pa.kind == vkStr: pa.sval.s else: toStr(pa)
    let sb = if pb.kind == vkStr: pb.sval.s else: toStr(pb)
    vm.checkStr(sa.len + sb.len, n)
    var r = newStringOfCap(sa.len + sb.len)
    r.add sa
    r.add sb
    strV(r)
  else:
    numV(toNum(pa) + toNum(pb))

proc binop(vm: Vm; op: NodeKind; a, b: Value; n: Node): Value =
  template x(): float64 = (if a.kind == vkNum: a.nval else: toNum(a))
  template y(): float64 = (if b.kind == vkNum: b.nval else: toNum(b))
  case op
  of nkAdd:
    if a.kind == vkNum and b.kind == vkNum: numV(a.nval + b.nval) else: vm.addValues(a, b, n)
  of nkSub: numV(x - y)
  of nkMul: numV(x * y)
  of nkDiv: numV(x / y)
  of nkMod: numV(x mod y)
  of nkPow: numV(jsPow(x, y))
  of nkBitAnd: numV(float(toInt32(x) and toInt32(y)))
  of nkBitOr: numV(float(toInt32(x) or toInt32(y)))
  of nkBitXor: numV(float(toInt32(x) xor toInt32(y)))
  of nkShl: numV(float(cast[int32](toUint32(x) shl (toUint32(y) and 31))))
  of nkShr: numV(float(ashr(toInt32(x), int(toUint32(y) and 31))))
  of nkUShr: numV(float(toUint32(x) shr (toUint32(y) and 31)))
  else: undef()

proc instanceOf(vm: Vm; a, b: Value; n: Node): bool =
  if b.kind != vkFunction: vm.typeErr(n, "Right-hand side of 'instanceof' is not callable")
  let f = b.fval
  if f.kind == fkScript: return a.kind == vkObject and a.oval.ctor == f
  case f.name
  of "Error": a.kind == vkObject and a.oval.err != nil
  of "TypeError", "RangeError", "SyntaxError", "ReferenceError", "EvalError", "URIError":
    a.kind == vkObject and a.oval.err != nil and toStr(a.oval.getProp("name")) == f.name
  of "Array": a.kind == vkArray
  of "Object": a.kind in {vkArray, vkObject, vkFunction}
  of "Function": a.kind == vkFunction
  else: false

# ---- the interpreter: calls ---------------------------------------------------------------------------------------

proc pushArgs(vm: Vm; args: seq[Node]) =
  for a in args:
    if a.kind == nkSpread:
      let v = eval(vm, a.a)
      case v.kind
      of vkArray:
        vm.checkArr(v.aval.items.len, a)
        for x in v.aval.items: vm.push(x)
      of vkStr:
        let st = v.sval
        var b = 0
        while b < st.s.len:
          let l = cpBytes(st.s, b)
          vm.push(strV(st.s[b ..< b + l]))
          b += l
      else: vm.typeErr(a, describe(a.a) & " is not iterable")
    else:
      vm.push(eval(vm, a))

proc bindTarget(vm: Vm; t: Node; v: Value)

proc restOf(vm: Vm; p: Proto; base, argc: int): Value {.noinline.} =
  var items: seq[Value]
  for i in p.nparams ..< argc: items.add vm.stack[base + i]
  arrV(items)

proc bindParams(vm: Vm; fn: Fn; this: Value; argc: int; rest: sink Value) {.noinline.} =
  let p = fn.proto
  if p.argsTarget != nil:
    var all: seq[Value]
    for i in 0 ..< min(argc, p.nparams): all.add vm.stack[vm.bp + i]
    if rest.kind == vkArray: all.add rest.aval.items
    vm.bindTarget(p.argsTarget, arrV(all))
  if p.thisTarget != nil: vm.bindTarget(p.thisTarget, this)
  if p.selfTarget != nil: vm.bindTarget(p.selfTarget, Value(kind: vkFunction, fval: fn))
  for i in 0 ..< p.nparams:
    let d = p.params[i]
    if d != nil:
      let v = vm.stack[vm.bp + i]
      if d.b != nil and v.kind == vkUndefined: vm.bindTarget(d.a, eval(vm, d.b))
      else: vm.bindTarget(d.a, v)
  if p.rest != nil: vm.bindTarget(p.rest, rest)

proc callScript(vm: Vm; fn: Fn; this: Value; base, argc: int; site: Node): Value =
  let p {.cursor.} = fn.proto
  step(vm, site)
  var marker = 0
  if vm.depth >= vm.maxDepth or abs(vm.stackBase - cast[int](addr marker)) > vm.maxNativeStack:
    vm.sp = base
    vm.rangeErr(site, "Maximum call stack size exceeded")
  if p.rest != nil or p.argsTarget != nil:
    result = vm.restOf(p, base, argc)   # held here until the frame is ready
  let top = base + max(argc, p.nregs)
  if top > vm.stack.len: vm.stack.setLen(max(top + 64, vm.stack.len * 2))
  for i in min(argc, p.nparams) ..< max(argc, p.nregs): vm.stack[base + i] = undef()
  let oldBp = vm.bp
  var oldEnv = vm.env
  vm.bp = base
  vm.sp = base + p.nregs
  if p.envSize > 0: vm.env = Env(parent: fn.env, vals: newSeq[Value](p.envSize))
  elif vm.env != fn.env: vm.env = fn.env
  if vm.depth >= vm.calls.len: vm.calls.setLen(max(32, vm.calls.len * 2))
  vm.calls[vm.depth] = CallRec(proto: p, site: site)
  inc vm.depth
  if not p.simple: vm.bindParams(fn, this, argc, move(result))
  if p.exprBody != nil:
    result = eval(vm, p.exprBody)
  else:
    for s in p.body.list:
      if exec(vm, s) == cReturn:
        result = move(vm.retVal)
        break
  dec vm.depth
  vm.bp = oldBp
  vm.sp = base
  if vm.env != oldEnv: vm.env = move(oldEnv)

proc callValue(vm: Vm; f: Value; this: Value; base, argc: int; site: Node): Value =
  if f.kind != vkFunction:
    vm.sp = base
    let what = if site != nil and site.kind in {nkCall, nkNew}: describe(site.a) else: inspect(f)
    vm.typeErr(site, what & " is not a function")
  let fn = f.fval
  case fn.kind
  of fkScript:
    result = vm.callScript(fn, this, base, argc, site)
  of fkNative:
    result = fn.native(vm, this, base, argc, site)
    vm.sp = base
  of fkHost:
    var args = newSeq[Value](argc)
    for i in 0 ..< argc: args[i] = vm.stack[base + i]
    vm.sp = base
    vm.hostGuard(site):
      result = fn.host(args)
  of fkBound:
    result = vm.callMethod(fn.recv, fn.meth, base, argc, site)
  of fkBoundFn:
    let nb = vm.sp
    for a in fn.boundArgs: vm.push(a)
    for i in 0 ..< argc:
      let v = vm.stack[base + i]
      vm.push(v)
    result = vm.callValue(fn.target, fn.boundThis, nb, vm.sp - nb, site)
    vm.sp = base

proc callBack(vm: Vm; f: Value; a, b, c: Value; argc: int; site: Node): Value =
  let base = vm.sp
  vm.push(a)
  if argc > 1: vm.push(b)
  if argc > 2: vm.push(c)
  vm.callValue(f, undef(), base, argc, site)

proc callMethodArgs(vm: Vm; recv: Value; m: MethodId; n: Node): Value =
  let base = vm.sp
  vm.pushArgs(n.list)
  vm.callMethod(recv, m, base, vm.sp - base, n)

proc evalCall(vm: Vm; n: Node): Value =
  let c = n.a
  var fnv, this: Value
  case c.kind
  of nkMember:
    this = eval(vm, c.a)
    if nfInOpt in c.flags and vm.optShort: return undef()
    case this.kind
    of vkObject:
      let i = this.oval.find(c.name)
      if i >= 0: fnv = this.oval.vals[i]
      elif c.meth in objMethods: return vm.callMethodArgs(this, c.meth, n)
    of vkArray, vkStr, vkNum, vkBool:
      if c.meth != mNone: return vm.callMethodArgs(this, c.meth, n)
    of vkHost:
      let h = this.hval
      if h.call != nil:
        let base = vm.sp
        vm.pushArgs(n.list)
        var args = newSeq[Value](vm.sp - base)
        for i in 0 ..< args.len: args[i] = vm.stack[base + i]
        vm.sp = base
        vm.hostGuard(n):
          result = h.call(c.name, args)
        return
      fnv = vm.getMember(this, c.name, c)
    of vkFunction:
      let f = this.fval
      if c.meth in fnMethods and (f.props == nil or f.props.find(c.name) < 0):
        result = vm.callMethodArgs(this, c.meth, n); return
      fnv = vm.getMember(this, c.name, c)
    of vkUndefined, vkNull:
      if nfOptional in c.flags:
        vm.optShort = true
        result = undef(); return
      vm.typeErr(c, "Cannot read properties of " & kindWord(this) & " (reading '" & c.name & "')")
  of nkIndex:
    this = eval(vm, c.a)
    if nfInOpt in c.flags and vm.optShort: result = undef(); return
    if this.kind <= vkNull and nfOptional in c.flags:
      vm.optShort = true
      result = undef(); return
    let k = eval(vm, c.b)
    if this.kind == vkHost and this.hval.call != nil:
      let key = propKey(k)
      let base = vm.sp
      vm.pushArgs(n.list)
      var args = newSeq[Value](vm.sp - base)
      for i in 0 ..< args.len: args[i] = vm.stack[base + i]
      vm.sp = base
      vm.hostGuard(n):
        result = this.hval.call(key, args)
      return
    fnv = vm.getIndex(this, k, c)
  else:
    fnv = eval(vm, c)
    if nfInOpt in c.flags and vm.optShort: result = undef(); return
  if nfOptional in n.flags and fnv.kind <= vkNull:
    vm.optShort = true
    result = undef(); return
  let base = vm.sp
  vm.pushArgs(n.list)
  vm.callValue(fnv, this, base, vm.sp - base, n)

proc evalNew(vm: Vm; n: Node): Value =
  let callee = eval(vm, n.a)
  let base = vm.sp
  vm.pushArgs(n.list)
  let argc = vm.sp - base
  if callee.kind != vkFunction or callee.fval.kind == fkBound or
      (callee.fval.kind == fkScript and callee.fval.proto.isArrow):
    vm.sp = base
    vm.typeErr(n, describe(n.a) & " is not a constructor")
  let f = callee.fval
  if f.kind == fkScript:
    let thisV = objV(Obj(ctor: f))
    let r = vm.callScript(f, thisV, base, argc, n)
    if r.kind in {vkObject, vkArray, vkFunction, vkHost}: r else: thisV
  else:
    vm.callValue(callee, undef(), base, argc, n)

# ---- the interpreter: numbers without making values ------------------------------------------------------

proc peekNum(vm: Vm; n: Node; x: var float64): bool {.inline.} =
  ## A local, global or constant that holds a number, read without a copy.
  case n.kind
  of nkLocal:
    let p = addr vm.stack[vm.bp + n.slot]
    if p.kind == vkNum:
      x = p.nval
      return true
  of nkConst:
    if n.val.kind == vkNum:
      x = n.val.nval
      return true
  of nkGlobal:
    let p = addr vm.gvals[vm.globalSlot(n)]
    if p.kind == vkNum:
      x = p.nval
      return true
  else: discard
  false

proc evalNumSlow(vm: Vm; n: Node): float64 {.noinline.} =
  let v = eval(vm, n)
  if v.kind == vkNum: v.nval else: toNum(v)

proc evalNum(vm: Vm; n: Node): float64 =
  ## An operand of an operator that wants a number (- * / % and the like).
  case n.kind
  of nkLocal, nkConst, nkGlobal:
    if not peekNum(vm, n, result): result = vm.evalNumSlow(n)
  of nkSub: result = evalNum(vm, n.a) - evalNum(vm, n.b)
  of nkMul: result = evalNum(vm, n.a) * evalNum(vm, n.b)
  of nkDiv: result = evalNum(vm, n.a) / evalNum(vm, n.b)
  of nkMod: result = evalNum(vm, n.a) mod evalNum(vm, n.b)
  of nkNeg: result = -evalNum(vm, n.a)
  else: result = vm.evalNumSlow(n)

proc cmpNum(k: NodeKind; x, y: float64): bool {.inline.} =
  case k
  of nkLt: x < y
  of nkLe: x <= y
  of nkGt: x > y
  else: x >= y

proc cmpVal(k: NodeKind; a, b: Value): bool =
  case k
  of nkLt: lessThan(a, b, false)
  of nkLe: lessThan(a, b, true)
  of nkGt: lessThan(b, a, false)
  else: lessThan(b, a, true)

proc compareSlow(vm: Vm; n: Node): bool {.noinline.} =
  let a = eval(vm, n.a)
  let b = eval(vm, n.b)
  if a.kind == vkNum and b.kind == vkNum: cmpNum(n.kind, a.nval, b.nval) else: cmpVal(n.kind, a, b)

proc evalCompare(vm: Vm; n: Node): bool =
  var x, y: float64
  if peekNum(vm, n.a, x) and peekNum(vm, n.b, y): cmpNum(n.kind, x, y)
  else: vm.compareSlow(n)

proc equalitySlow(vm: Vm; n: Node): bool {.noinline.} =
  let a = eval(vm, n.a)
  let b = eval(vm, n.b)
  if n.kind in {nkSeq, nkSne}: strictEq(a, b) else: looseEq(a, b)

proc evalEquality(vm: Vm; n: Node): bool =
  var x, y: float64
  result = if peekNum(vm, n.a, x) and peekNum(vm, n.b, y): x == y else: vm.equalitySlow(n)
  if n.kind in {nkNe, nkSne}: result = not result

proc evalCond(vm: Vm; n: Node): bool =
  ## An expression's truth, for if, loops and ?: (no value made for comparisons).
  case n.kind
  of nkLt, nkLe, nkGt, nkGe: vm.evalCompare(n)
  of nkEq, nkNe, nkSeq, nkSne: vm.evalEquality(n)
  of nkNot: not vm.evalCond(n.a)
  of nkAnd: vm.evalCond(n.a) and vm.evalCond(n.b)
  of nkOr: vm.evalCond(n.a) or vm.evalCond(n.b)
  else: toBool(eval(vm, n))

# ---- the interpreter: assignment ---------------------------------------------------------------------------------

proc envAt(vm: Vm; hops: int32): Env {.inline.} =
  result = vm.env
  for _ in 1 .. hops: result = result.parent

proc bindTarget(vm: Vm; t: Node; v: Value) =
  case t.kind
  of nkLocal: vm.stack[vm.bp + t.slot] = v
  of nkEnvVar: vm.envAt(t.hops).vals[t.slot] = v
  of nkGlobal:
    if nfDeclare in t.flags:
      var i: int
      if t.gvm == vm.id: i = int(t.gslot)
      else:
        i = vm.defineSlot(t.name)
        t.gvm = vm.id
        t.gslot = int32(i)
      vm.gvals[i] = v
      vm.gconst[i] = nfConst in t.flags
    else:
      vm.assignGlobal(t, v)
  of nkMember:
    let o = eval(vm, t.a)
    vm.setMember(o, t.name, v, t)
  of nkIndex:
    let o = eval(vm, t.a)
    let k = eval(vm, t.b)
    vm.setIndex(o, k, v, t)
  of nkDefault:
    if v.kind == vkUndefined: vm.bindTarget(t.a, eval(vm, t.b))
    else: vm.bindTarget(t.a, v)
  of nkArrayPat:
    case v.kind
    of vkArray:
      let a = v.aval
      for i, e in t.list:
        case e.kind
        of nkHole: discard
        of nkRest: vm.bindTarget(e.a, arrV(if i < a.items.len: a.items[i .. ^1] else: @[]))
        else: vm.bindTarget(e, (if i < a.items.len: a.items[i] else: undef()))
    of vkStr:
      let st = v.sval
      let L = st.cpCount
      for i, e in t.list:
        case e.kind
        of nkHole: discard
        of nkRest:
          var items: seq[Value]
          for k in i ..< L: items.add strV(st.cpSlice(k, k + 1))
          vm.bindTarget(e.a, arrV(items))
        else: vm.bindTarget(e, (if i < L: strV(st.cpSlice(i, i + 1)) else: undef()))
    else:
      vm.typeErr(t, inspect(v) & " is not iterable")
  of nkObjPat:
    if v.kind <= vkNull: vm.typeErr(t, "Cannot destructure '" & kindWord(v) & "' as it is " & kindWord(v) & ".")
    var used: seq[string]
    for p in t.list:
      if p.kind == nkRest:
        let o = Obj()
        for k in ownKeys(v):
          if k notin used: o.put(k, vm.getMember(v, k, p))
        vm.bindTarget(p.a, objV(o))
      else:
        let key = if p.a != nil: propKey(eval(vm, p.a)) else: p.name
        used.add key
        vm.bindTarget(p.b, vm.getMember(v, key, p))
  else:
    vm.typeErr(t, "Invalid assignment target")

type LRef = object
  t {.cursor.}: Node
  obj, key: Value

proc makeRef(vm: Vm; t: Node): LRef =
  result.t = t
  case t.kind
  of nkMember: result.obj = eval(vm, t.a)
  of nkIndex:
    result.obj = eval(vm, t.a)
    result.key = eval(vm, t.b)
  else: discard

proc getRef(vm: Vm; r: LRef): Value =
  let t = r.t
  case t.kind
  of nkLocal: vm.stack[vm.bp + t.slot]
  of nkEnvVar: vm.envAt(t.hops).vals[t.slot]
  of nkGlobal: vm.gvals[vm.globalSlot(t)]
  of nkMember: vm.getMember(r.obj, t.name, t)
  of nkIndex: vm.getIndex(r.obj, r.key, t)
  else: undef()

proc setRef(vm: Vm; r: LRef; v: Value) =
  let t = r.t
  case t.kind
  of nkLocal: vm.stack[vm.bp + t.slot] = v
  of nkEnvVar: vm.envAt(t.hops).vals[t.slot] = v
  of nkGlobal: vm.assignGlobal(t, v)
  of nkMember: vm.setMember(r.obj, t.name, v, t)
  of nkIndex: vm.setIndex(r.obj, r.key, v, t)
  else: discard

proc slotAddr(vm: Vm; t: Node): ptr Value =
  case t.kind
  of nkLocal: addr vm.stack[vm.bp + t.slot]
  of nkEnvVar: addr vm.envAt(t.hops).vals[t.slot]
  else:
    let i = vm.globalSlot(t)
    if vm.gconst[i]: vm.typeErr(t, "Assignment to constant variable '" & t.name & "'")
    addr vm.gvals[i]

proc compoundSlow(vm: Vm; n: Node; cur: Value; rhs: sink Value): Value {.noinline.} =
  result = vm.binop(n.op, cur, rhs, n)
  vm.setRef(vm.makeRef(n.a), result)

proc assignOther(vm: Vm; n: Node): Value {.noinline.} =
  let t = n.a
  case t.kind
  of nkMember:
    let o = eval(vm, t.a)
    result = eval(vm, n.b)
    vm.setMember(o, t.name, result, t)
  of nkIndex:
    let o = eval(vm, t.a)
    let k = eval(vm, t.b)
    result = eval(vm, n.b)
    vm.setIndex(o, k, result, t)
  else:
    result = eval(vm, n.b)
    vm.bindTarget(t, result)

proc assignCompound(vm: Vm; n: Node): Value {.noinline.} =
  let t = n.a
  let op = n.op
  let r = vm.makeRef(t)
  var cur = vm.getRef(r)
  if op in {nkAnd, nkOr, nkNullish}:
    let keep = case op
      of nkAnd: not toBool(cur)
      of nkOr: toBool(cur)
      else: cur.kind > vkNull
    if keep: return cur
    result = eval(vm, n.b)
    vm.setRef(r, result)
    return
  let rhs = eval(vm, n.b)
  if op == nkAdd and cur.kind == vkStr and rhs.kind in {vkUndefined .. vkStr} and
      t.kind in {nkLocal, nkEnvVar, nkGlobal}:
    # s += x: when nothing else holds the string, grow it where it is
    let p = vm.slotAddr(t)
    if p[].kind == vkStr and p[].sval == cur.sval:
      cur = undef()
      if isUniqueRef(p[].sval):
        let st = p[].sval
        if rhs.kind == vkStr:
          vm.checkStr(st.s.len + rhs.sval.s.len, n)
          if st.ascii == 1 and rhs.sval.s.hasNonAscii: st.ascii = 0
          st.s.add rhs.sval.s
        else:
          let add = toStr(rhs)
          vm.checkStr(st.s.len + add.len, n)
          st.s.add add
        st.offs.setLen(0)
        result = p[]; return
      cur = p[]
  result = vm.binop(op, cur, rhs, n)
  vm.setRef(r, result)

proc evalAssign(vm: Vm; n: Node): Value =
  let t {.cursor.} = n.a
  let op = n.op
  if op == nkEmpty:
    case t.kind
    of nkLocal:
      result = eval(vm, n.b)
      vm.stack[vm.bp + t.slot] = result
    of nkEnvVar:
      result = eval(vm, n.b)
      vm.envAt(t.hops).vals[t.slot] = result
    of nkGlobal:
      result = eval(vm, n.b)
      vm.assignGlobal(t, result)
    else:
      result = vm.assignOther(n)
    return
  if op in {nkAdd, nkSub, nkMul, nkDiv, nkMod} and t.kind in {nkLocal, nkGlobal}:
    var old: float64
    if peekNum(vm, t, old):
      var x: float64
      if op == nkAdd:
        result = eval(vm, n.b)
        if result.kind != vkNum: result = vm.compoundSlow(n, numV(old), move(result)); return
        x = old + result.nval
      else:
        let y = vm.evalNum(n.b)
        x = case op
          of nkSub: old - y
          of nkMul: old * y
          of nkDiv: old / y
          else: old mod y
      let p = vm.slotAddr(t)
      if p.kind == vkNum: p.nval = x
      else: p[] = numV(x)
      if result.kind == vkNum: result.nval = x
      else: result = numV(x)
      return
  vm.assignCompound(n)

proc incDecRef(vm: Vm; n: Node): Value {.noinline.} =
  let r = vm.makeRef(n.a)
  let old = toNum(vm.getRef(r))
  let nv = old + float(n.slot)
  vm.setRef(r, numV(nv))
  numV(if nfPrefix in n.flags: nv else: old)

proc evalIncDec(vm: Vm; n: Node): Value {.inline.} =
  let t {.cursor.} = n.a
  if t.kind == nkLocal:
    let i = vm.bp + t.slot
    if vm.stack[i].kind == vkNum:
      let old = vm.stack[i].nval
      let nv = old + float(n.slot)
      vm.stack[i].nval = nv
      return numV(if nfPrefix in n.flags: nv else: old)
  vm.incDecRef(n)

# ---- the interpreter: expressions ---------------------------------------------------------------------------------

proc spreadInto(vm: Vm; dst: var seq[Value]; v: Value; n: Node) =
  case v.kind
  of vkArray:
    vm.checkArr(dst.len + v.aval.items.len, n)
    dst.add v.aval.items
  of vkStr:
    let st = v.sval
    var b = 0
    while b < st.s.len:
      let l = cpBytes(st.s, b)
      dst.add strV(st.s[b ..< b + l])
      b += l
  else: vm.typeErr(n, describe(n.a) & " is not iterable")

proc eval(vm: Vm; n: Node): Value =
  template num(v: Value): float64 = (if v.kind == vkNum: v.nval else: toNum(v))
  case n.kind
  of nkConst: result = n.val
  of nkLocal: result = vm.stack[vm.bp + n.slot]
  of nkEnvVar: result = vm.envAt(n.hops).vals[n.slot]
  of nkGlobal: result = vm.gvals[vm.globalSlot(n)]
  of nkTemplate:
    var s = ""
    for p in n.list:
      let v = eval(vm, p)
      if v.kind == vkStr: s.add v.sval.s else: s.add toStr(v)
      vm.checkStr(s.len, n)
    result = strV(s)
  of nkArray:
    var items = newSeqOfCap[Value](n.list.len)
    for e in n.list:
      case e.kind
      of nkHole: items.add undef()
      of nkSpread: vm.spreadInto(items, eval(vm, e.a), e)
      else: items.add eval(vm, e)
    result = arrV(items)
  of nkObject:
    let o = Obj()
    for p in n.list:
      if p.kind == nkSpread:
        let v = eval(vm, p.a)
        case v.kind
        of vkObject:
          for i, k in v.oval.keys: o.put(k, v.oval.vals[i])
        of vkArray, vkStr:
          for k in ownKeys(v): o.put(k, vm.getMember(v, k, p))
        else: discard
      else:
        let key = if p.a != nil: propKey(eval(vm, p.a)) else: p.name
        o.put(key, eval(vm, p.b))
    result = objV(o)
  of nkFunc:
    result = Value(kind: vkFunction, fval: Fn(kind: fkScript, name: n.proto.name, proto: n.proto, env: vm.env))
  of nkMember:
    let o = eval(vm, n.a)
    if nfInOpt in n.flags and vm.optShort: result = undef(); return
    case o.kind
    of vkObject: result = o.oval.getProp(n.name)
    of vkArray:
      if n.meth == mLength: result = numV(float(o.aval.items.len))
      else: result = vm.getMember(o, n.name, n)
    of vkUndefined, vkNull:
      if nfOptional in n.flags:
        vm.optShort = true
        result = undef(); return
      result = vm.getMember(o, n.name, n)
    else: result = vm.getMember(o, n.name, n)
  of nkIndex:
    let o = eval(vm, n.a)
    if nfInOpt in n.flags and vm.optShort: result = undef(); return
    if o.kind <= vkNull and nfOptional in n.flags:
      vm.optShort = true
      result = undef(); return
    let k = eval(vm, n.b)
    result = vm.getIndex(o, k, n)
  of nkCall: result = vm.evalCall(n)
  of nkNew: result = vm.evalNew(n)
  of nkOptChain:
    result = eval(vm, n.a)
    vm.optShort = false
  of nkNeg: result = numV(-vm.evalNum(n.a))
  of nkPos:
    let a = eval(vm, n.a)
    result = numV(num(a))
  of nkNot: result = boolV(not vm.evalCond(n.a))
  of nkBitNot:
    let a = eval(vm, n.a)
    result = numV(float(not toInt32(num(a))))
  of nkTypeof:
    if n.a.kind == nkGlobal and n.a.gvm != vm.id and not vm.gnames.hasKey(n.a.name):
      result = strV("undefined")
    else:
      result = strV(typeName(eval(vm, n.a)))
  of nkVoid:
    discard eval(vm, n.a)
    result = undef()
  of nkDelete:
    let t = n.a
    case t.kind
    of nkMember:
      let o = eval(vm, t.a)
      result = boolV(vm.deleteKey(o, t.name, t))
    of nkIndex:
      let o = eval(vm, t.a)
      let k = eval(vm, t.b)
      result = boolV(vm.deleteKey(o, propKey(k), t))
    else:
      discard eval(vm, t)
      result = boolV(true)
  of nkAdd:
    var x, y: float64
    if peekNum(vm, n.a, x) and peekNum(vm, n.b, y):
      result = numV(x + y)
    else:
      let a = eval(vm, n.a)
      let b = eval(vm, n.b)
      if a.kind == vkNum and b.kind == vkNum: result = numV(a.nval + b.nval)
      else: result = vm.addValues(a, b, n)
  of nkSub, nkMul, nkDiv, nkMod: result = numV(vm.evalNum(n))
  of nkPow, nkBitAnd, nkBitOr, nkBitXor, nkShl, nkShr, nkUShr:
    let a = eval(vm, n.a)
    let b = eval(vm, n.b)
    result = vm.binop(n.kind, a, b, n)
  of nkEq, nkNe, nkSeq, nkSne: result = boolV(vm.evalEquality(n))
  of nkLt, nkLe, nkGt, nkGe: result = boolV(vm.evalCompare(n))
  of nkIn:
    let a = eval(vm, n.a)
    let b = eval(vm, n.b)
    result = boolV(vm.hasKey(b, propKey(a), n))
  of nkInstanceof:
    let a = eval(vm, n.a)
    let b = eval(vm, n.b)
    result = boolV(vm.instanceOf(a, b, n))
  of nkAnd:
    result = eval(vm, n.a)
    if toBool(result): result = eval(vm, n.b)
  of nkOr:
    result = eval(vm, n.a)
    if not toBool(result): result = eval(vm, n.b)
  of nkNullish:
    result = eval(vm, n.a)
    if result.kind <= vkNull: result = eval(vm, n.b)
  of nkCond:
    if vm.evalCond(n.a): result = eval(vm, n.b)
    else: result = eval(vm, n.c)
  of nkAssign: result = vm.evalAssign(n)
  of nkIncDec: result = vm.evalIncDec(n)
  of nkComma:
    for i, e in n.list:
      if i < n.list.len - 1: discard eval(vm, e)
      else: result = eval(vm, e)
  else:
    vm.throwErr(n, "SyntaxError", "Unexpected " & $n.kind)

# ---- the interpreter: statements ----------------------------------------------------------------------------------

proc evalDiscard(vm: Vm; n: Node) =
  ## An expression whose value nobody wants (`i++;`, `s += x;`).
  if n.kind == nkIncDec and n.a.kind == nkLocal:
    let i = vm.bp + n.a.slot
    if vm.stack[i].kind == vkNum:
      vm.stack[i].nval = vm.stack[i].nval + float(n.slot)
      return
  discard eval(vm, n)

proc ownsLabel(vm: Vm; n: Node): bool {.inline.} =
  if vm.label.len == 0 or vm.label in n.labels:
    vm.label = ""
    true
  else:
    false

proc execList(vm: Vm; list: seq[Node]): Completion =
  for s in list:
    let c = exec(vm, s)
    if c != cNormal: return c
  cNormal

proc execForOf(vm: Vm; n: Node): Completion =
  let it = eval(vm, n.b)
  let target = if n.a.kind == nkDecl: n.a.list[0].a else: n.a
  let saved = vm.env
  let es = n.envSize
  template body(item: Value) =
    if es > 0: vm.env = Env(parent: saved, vals: newSeq[Value](es))
    vm.bindTarget(target, item)
    let c = exec(vm, n.d)
    if c != cNormal:
      if c == cBreak and vm.ownsLabel(n): break
      elif c == cContinue and vm.ownsLabel(n): discard
      else:
        vm.env = saved
        return c
  if n.kind == nkForOf:
    case it.kind
    of vkArray:
      let a = it.aval
      var i = 0
      while i < a.items.len:
        let item = a.items[i]
        inc i
        body(item)
    of vkStr:
      let st = it.sval
      var b = 0
      while b < st.s.len:
        let l = cpBytes(st.s, b)
        let item = strV(st.s[b ..< b + l])
        b += l
        body(item)
    else: vm.typeErr(n.b, describe(n.b) & " is not iterable")
  else:
    let keys = ownKeys(it)
    for k in keys:
      body(strV(k))
  vm.env = saved

proc execTry(vm: Vm; n: Node): Completion =
  let sBp = vm.bp
  let sSp = vm.sp
  let sEnv = vm.env
  let sDepth = vm.depth
  template restore() =
    vm.bp = sBp
    vm.sp = sSp
    vm.env = sEnv
    vm.depth = sDepth
    vm.optShort = false
    vm.label = ""
  var pending: ref ScriptError = nil
  try:
    if n.b != nil:
      try:
        result = exec(vm, n.a)
      except ScriptError as e:
        if e.fatal: raise
        restore()
        let b = n.b
        if b.envSize > 0: vm.env = Env(parent: sEnv, vals: newSeq[Value](b.envSize))
        if n.c != nil: vm.bindTarget(n.c, e.value)
        result = vm.execList(b.list)
        vm.env = sEnv
    else:
      result = exec(vm, n.a)
  except ScriptError as e:
    if e.fatal or n.d == nil: raise
    restore()
    pending = e
  if n.d != nil:
    let savedRet = vm.retVal
    let savedLabel = vm.label
    let fc = exec(vm, n.d)
    if fc != cNormal: result = fc; return
    vm.retVal = savedRet
    vm.label = savedLabel
    if pending != nil: raise pending

proc execSwitch(vm: Vm; n: Node): Completion =
  let d = eval(vm, n.a)
  let saved = vm.env
  if n.envSize > 0: vm.env = Env(parent: saved, vals: newSeq[Value](n.envSize))
  var start = -1
  for i, cs in n.list:
    if cs.a != nil and strictEq(d, eval(vm, cs.a)):
      start = i
      break
  if start < 0:
    for i, cs in n.list:
      if cs.a == nil:
        start = i
        break
  if start >= 0:
    for i in start ..< n.list.len:
      let c = vm.execList(n.list[i].list)
      if c != cNormal:
        if c == cBreak and vm.label.len == 0: break
        vm.env = saved
        return c
  vm.env = saved

proc execDecl(vm: Vm; n: Node) {.noinline.} =
  for it in n.list:
    if it.b != nil:
      var v = eval(vm, it.b)   # first: it may grow the stack
      if it.a.kind == nkLocal: vm.stack[vm.bp + it.a.slot] = move(v)
      else: vm.bindTarget(it.a, v)
    elif nfVar in n.flags:
      if it.a.kind == nkGlobal and nfDeclare in it.a.flags:
        discard vm.defineSlot(it.a.name)
    else:
      vm.bindTarget(it.a, undef())

proc execFuncDecl(vm: Vm; n: Node) {.noinline.} =
  vm.bindTarget(n.a, Value(kind: vkFunction, fval: Fn(kind: fkScript, name: n.proto.name, proto: n.proto,
                                                      env: vm.env)))

proc execBlockEnv(vm: Vm; n: Node): Completion {.noinline.} =
  let saved = vm.env
  vm.env = Env(parent: saved, vals: newSeq[Value](n.envSize))
  result = vm.execList(n.list)
  vm.env = saved

proc execReturn(vm: Vm; n: Node) {.noinline.} =
  if n.a != nil: vm.retVal = eval(vm, n.a)
  else: vm.retVal = undef()

proc execThrow(vm: Vm; n: Node) {.noinline.} =
  let v = eval(vm, n.a)
  vm.raiseValue(v, n)

proc execFor(vm: Vm; n: Node): Completion {.noinline.} =
  let saved = vm.env
  let es = n.envSize
  if es > 0: vm.env = Env(parent: saved, vals: newSeq[Value](es))
  if n.a != nil: discard exec(vm, n.a)
  while true:
    if n.b != nil and not vm.evalCond(n.b): break
    let c = exec(vm, n.d)
    if c != cNormal:
      if c == cBreak and vm.ownsLabel(n): break
      elif c == cContinue and vm.ownsLabel(n): discard
      else:
        vm.env = saved
        return c
    if es > 0: vm.env = Env(parent: saved, vals: vm.env.vals)
    if n.c != nil: vm.evalDiscard(n.c)
  vm.env = saved

proc exec(vm: Vm; n: Node): Completion =
  step(vm, n)
  case n.kind
  of nkExprStmt:
    if vm.depth == vm.topDepth: vm.completion = eval(vm, n.a)
    else: vm.evalDiscard(n.a)
  of nkDecl: vm.execDecl(n)
  of nkFuncDecl: vm.execFuncDecl(n)
  of nkBlock:
    if n.envSize > 0: result = vm.execBlockEnv(n)
    else: result = vm.execList(n.list)
  of nkEmpty: discard
  of nkIf:
    if vm.evalCond(n.a): result = exec(vm, n.b)
    elif n.c != nil: result = exec(vm, n.c)
  of nkWhile:
    while vm.evalCond(n.a):
      let c = exec(vm, n.b)
      if c != cNormal:
        if c == cBreak and vm.ownsLabel(n): break
        elif c == cContinue and vm.ownsLabel(n): continue
        else: result = c; return
  of nkDoWhile:
    while true:
      let c = exec(vm, n.b)
      if c != cNormal:
        if c == cBreak and vm.ownsLabel(n): break
        elif c == cContinue and vm.ownsLabel(n): discard
        else: result = c; return
      if not vm.evalCond(n.a): break
  of nkFor: result = vm.execFor(n)
  of nkForOf, nkForIn: result = vm.execForOf(n)
  of nkBreak:
    vm.label = n.name
    result = cBreak
  of nkContinue:
    vm.label = n.name
    result = cContinue
  of nkReturn:
    vm.execReturn(n)
    result = cReturn
  of nkThrow: vm.execThrow(n)
  of nkTry: result = vm.execTry(n)
  of nkSwitch: result = vm.execSwitch(n)
  of nkLabeled:
    result = exec(vm, n.a)
    if result == cBreak and vm.label == n.name:
      vm.label = ""
      result = cNormal
  else:
    discard eval(vm, n)

# ---- built-in methods -----------------------------------------------------------------------------------------------

template A(i: int): Value {.dirty.} =
  (if i < argc: vm.stack[base + i] else: Value(kind: vkUndefined))

proc relIdx(v: Value; len, dflt: int): int =
  if v.kind == vkUndefined: return dflt
  let x = toInteger(toNum(v))
  if x < 0: clampInt(float(len) + x, 0, len) else: clampInt(x, 0, len)

proc requireFn(vm: Vm; v: Value; n: Node) =
  if v.kind != vkFunction: vm.typeErr(n, inspect(v) & " is not a function")

proc applyReplacement(vm: Vm; rep: Value; matched: string; pos: int; whole: Value; n: Node): string =
  if rep.kind == vkFunction:
    return toStr(vm.callBack(rep, strV(matched), numV(float(pos)), whole, 3, n))
  let r = toStr(rep)
  var i = 0
  while i < r.len:
    if r[i] == '$' and i + 1 < r.len and r[i + 1] == '$':
      result.add '$'
      i += 2
    elif r[i] == '$' and i + 1 < r.len and r[i + 1] == '&':
      result.add matched
      i += 2
    else:
      result.add r[i]
      inc i

proc strMethod(vm: Vm; this: Value; m: MethodId; base, argc: int; n: Node): Value =
  let st = this.sval
  let s = st.s
  case m
  of mCharAt, mAt:
    let L = st.cpCount
    var i = toInteger(toNum(A(0)))
    if m == mAt and i < 0: i += float(L)
    if i < 0 or i >= float(L): return (if m == mAt: undef() else: strV(""))
    let k = int(i)
    strV(st.cpSlice(k, k + 1))
  of mCharCodeAt, mCodePointAt:
    let L = st.cpCount
    let i = toInteger(toNum(A(0)))
    if i < 0 or i >= float(L): return (if m == mCharCodeAt: numV(NaN) else: undef())
    numV(float(decodeAt(s, st.cpByte(int(i)))))
  of mSlice:
    let L = st.cpCount
    strV(st.cpSlice(relIdx(A(0), L, 0), relIdx(A(1), L, L)))
  of mSubstring:
    let L = st.cpCount
    var i = clampInt(toInteger(toNum(A(0))), 0, L)
    var j = if A(1).kind == vkUndefined: L else: clampInt(toInteger(toNum(A(1))), 0, L)
    if i > j: swap(i, j)
    strV(st.cpSlice(i, j))
  of mSubstr:
    let L = st.cpCount
    let i = relIdx(A(0), L, 0)
    let n2 = if A(1).kind == vkUndefined: L - i else: clampInt(toInteger(toNum(A(1))), 0, L - i)
    strV(st.cpSlice(i, i + n2))
  of mIndexOf, mIncludes:
    let sub = toStr(A(0))
    let L = st.cpCount
    let fromCp = clampInt(toInteger(toNum(A(1))), 0, L)
    let r = s.find(sub, st.cpByte(fromCp))
    if m == mIncludes: boolV(r >= 0)
    else: numV(float(if r < 0: -1 else: st.cpOfByte(r)))
  of mLastIndexOf:
    let sub = toStr(A(0))
    let L = st.cpCount
    let x = toNum(A(1))
    let fromCp = if x != x: L else: clampInt(toInteger(x), 0, L)
    let last = min(s.len - 1, st.cpByte(fromCp) + sub.len - 1)
    let r = if sub.len == 0: st.cpByte(fromCp) else: s.rfind(sub, 0, last)
    numV(float(if r < 0: -1 else: st.cpOfByte(r)))
  of mStartsWith:
    let sub = toStr(A(0))
    let L = st.cpCount
    let p = clampInt(toInteger(toNum(A(1))), 0, L)
    boolV(s.continuesWith(sub, st.cpByte(p)))
  of mEndsWith:
    let sub = toStr(A(0))
    let L = st.cpCount
    let e = if A(1).kind == vkUndefined: L else: clampInt(toInteger(toNum(A(1))), 0, L)
    let eb = st.cpByte(e)
    boolV(eb >= sub.len and s.continuesWith(sub, eb - sub.len))
  of mSplit:
    let limit = if A(1).kind == vkUndefined: high(int) else: clampInt(toNum(A(1)), 0, high(int32))
    var parts: seq[Value]
    if A(0).kind == vkUndefined:
      parts.add strV(s)
    else:
      let sep = toStr(A(0))
      vm.charge(s.len, n)
      if sep.len == 0:
        var b = 0
        while b < s.len and parts.len < limit:
          let l = cpBytes(s, b)
          parts.add strV(s[b ..< b + l])
          b += l
      else:
        for part in s.split(sep):
          if parts.len >= limit: break
          parts.add strV(part)
    if parts.len > limit: parts.setLen(limit)
    arrV(parts)
  of mTrim: strV(s.strip(chars = jsSpace))
  of mTrimStart: strV(s.strip(leading = true, trailing = false, chars = jsSpace))
  of mTrimEnd: strV(s.strip(leading = false, trailing = true, chars = jsSpace))
  of mToUpperCase: strV(if st.isAscii: s.toUpperAscii else: unicode.toUpper(s))
  of mToLowerCase: strV(if st.isAscii: s.toLowerAscii else: unicode.toLower(s))
  of mReplace, mReplaceAll:
    let pat = toStr(A(0))
    let rep = A(1)
    vm.charge(s.len, n)
    var r = ""
    var i = 0
    var any = false
    while i <= s.len:
      let k = if pat.len == 0 and any: -1 else: s.find(pat, i)
      if k < 0: break
      r.add s[i ..< k]
      r.add vm.applyReplacement(rep, pat, st.cpOfByte(k), this, n)
      vm.checkStr(r.len, n)
      any = true
      i = k + pat.len
      if m == mReplace: break
      if pat.len == 0:
        if i >= s.len: break
        let l = cpBytes(s, i)
        r.add s[i ..< i + l]
        i += l
        let k2 = i
        r.add vm.applyReplacement(rep, pat, st.cpOfByte(k2), this, n)
    if i < s.len: r.add s[i .. ^1]
    if not any: return this
    strV(r)
  of mPadStart, mPadEnd:
    let target = clampInt(toInteger(toNum(A(0))), 0, high(int32))
    let L = st.cpCount
    let fill = if A(1).kind == vkUndefined: " " else: toStr(A(1))
    if target <= L or fill.len == 0: return this
    let fs = Str(s: fill, ascii: -1)
    let fl = fs.cpCount
    let need = target - L
    vm.checkStr(s.len + need * 4, n)
    var pad = ""
    for k in 0 ..< need div fl: pad.add fill
    pad.add fs.cpSlice(0, need mod fl)
    strV(if m == mPadStart: pad & s else: s & pad)
  of mRepeat:
    let x = toInteger(toNum(A(0)))
    if x < 0 or x == Inf: vm.rangeErr(n, "Invalid count value: " & numToStr(x))
    if s.len == 0 or x == 0: return strV("")
    if x * float(s.len) > float(vm.maxStringLen): vm.rangeErr(n, "Invalid string length")
    let k = int(x)
    vm.charge(k * s.len, n)
    strV(s.repeat(k))
  of mConcat:
    var r = s
    for i in 0 ..< argc:
      r.add toStr(A(i))
      vm.checkStr(r.len, n)
    strV(r)
  of mLocaleCompare:
    let c = cmp(s, toStr(A(0)))
    numV(float(if c < 0: -1 elif c > 0: 1 else: 0))
  of mToString, mValueOf: this
  else: vm.typeErr(n, describe(n.a) & " is not a function")

proc arrMethod(vm: Vm; this: Value; m: MethodId; base, argc: int; n: Node): Value =
  let a = this.aval
  case m
  of mPush:
    vm.checkArr(a.items.len + argc, n)
    for i in 0 ..< argc: a.items.add A(i)
    numV(float(a.items.len))
  of mPop:
    if a.items.len == 0: undef() else: a.items.pop()
  of mShift:
    if a.items.len == 0: return undef()
    vm.charge(a.items.len, n)
    let first = a.items[0]
    a.items.delete(0)
    first
  of mUnshift:
    vm.checkArr(a.items.len + argc, n)
    vm.charge(a.items.len, n)
    var front = newSeq[Value](argc)
    for i in 0 ..< argc: front[i] = A(i)
    a.items = front & a.items
    numV(float(a.items.len))
  of mSlice:
    let L = a.items.len
    let i = relIdx(A(0), L, 0)
    let j = relIdx(A(1), L, L)
    vm.charge(j - i, n)
    arrV(if i < j: a.items[i ..< j] else: @[])
  of mSplice:
    let L = a.items.len
    let start = relIdx(A(0), L, 0)
    let dc = if argc == 0: 0
             elif argc == 1: L - start
             else: clampInt(toInteger(toNum(A(1))), 0, L - start)
    let adds = max(0, argc - 2)
    vm.checkArr(L - dc + adds, n)
    vm.charge(L, n)
    let removed = a.items[start ..< start + dc]
    var items = newSeqOfCap[Value](L - dc + adds)
    for i in 0 ..< start: items.add a.items[i]
    for i in 0 ..< adds: items.add A(i + 2)
    for i in start + dc ..< L: items.add a.items[i]
    a.items = items
    arrV(removed)
  of mConcat:
    var items = a.items
    for i in 0 ..< argc:
      let v = A(i)
      if v.kind == vkArray: items.add v.aval.items else: items.add v
      vm.checkArr(items.len, n)
    vm.charge(items.len, n)
    arrV(items)
  of mJoin, mToString:
    let sep = if m == mToString or A(0).kind == vkUndefined: "," else: toStr(A(0))
    var s = ""
    var seen: seq[pointer]
    joinInto(a, sep, s, seen)
    vm.checkStr(s.len, n)
    vm.charge(s.len, n)
    strV(s)
  of mIndexOf, mLastIndexOf, mIncludes:
    let L = a.items.len
    let x = A(0)
    if m == mLastIndexOf:
      var i = L - 1
      if argc > 1:
        let k = toInteger(toNum(A(1)))
        i = if k < 0: clampInt(float(L) + k, -1, L - 1) else: clampInt(k, -1, L - 1)
      while i >= 0:
        if strictEq(a.items[i], x): return numV(float(i))
        dec i
      return numV(-1)
    var i = relIdx(A(1), L, 0)
    while i < a.items.len:
      if (if m == mIncludes: sameValueZero(a.items[i], x) else: strictEq(a.items[i], x)):
        return (if m == mIncludes: boolV(true) else: numV(float(i)))
      inc i
    if m == mIncludes: boolV(false) else: numV(-1)
  of mReverse:
    a.items.reverse()
    this
  of mSort:
    let f = A(0)
    if f.kind notin {vkUndefined, vkFunction}:
      vm.typeErr(n, "The comparison function must be either a function or undefined")
    var defined, undefs: seq[Value]
    for it in a.items:
      if it.kind == vkUndefined: undefs.add it else: defined.add it
    vm.charge(a.items.len * 8, n)
    if f.kind == vkFunction:
      defined.sort(proc (x, y: Value): int =
        let r = toNum(vm.callBack(f, x, y, undef(), 2, n))
        if r < 0: -1 elif r > 0: 1 else: 0)
    else:
      var keyed = newSeq[(string, Value)](defined.len)
      for i, it in defined: keyed[i] = (toStr(it), it)
      keyed.sort(proc (x, y: (string, Value)): int = cmp(x[0], y[0]))
      for i in 0 ..< keyed.len: defined[i] = keyed[i][1]
    defined.add undefs
    a.items = defined
    this
  of mMap, mFilter, mForEach, mFind, mFindIndex, mSome, mEvery, mFlatMap:
    let f = A(0)
    vm.requireFn(f, n)
    var res: seq[Value]
    var i = 0
    while i < a.items.len:
      let item = a.items[i]
      let r = vm.callBack(f, item, numV(float(i)), this, 3, n)
      case m
      of mMap: res.add r
      of mFlatMap:
        if r.kind == vkArray: res.add r.aval.items else: res.add r
        vm.checkArr(res.len, n)
      of mFilter:
        if toBool(r): res.add item
      of mFind:
        if toBool(r): return item
      of mFindIndex:
        if toBool(r): return numV(float(i))
      of mSome:
        if toBool(r): return boolV(true)
      of mEvery:
        if not toBool(r): return boolV(false)
      else: discard
      inc i
    case m
    of mMap, mFilter, mFlatMap: arrV(res)
    of mFind: undef()
    of mFindIndex: numV(-1)
    of mSome: boolV(false)
    of mEvery: boolV(true)
    else: undef()
  of mFindLast, mFindLastIndex:
    let f = A(0)
    vm.requireFn(f, n)
    var i = a.items.len - 1
    while i >= 0:
      if i < a.items.len:
        let item = a.items[i]
        if toBool(vm.callBack(f, item, numV(float(i)), this, 3, n)):
          return (if m == mFindLast: item else: numV(float(i)))
      dec i
    if m == mFindLast: undef() else: numV(-1)
  of mReduce, mReduceRight:
    let f = A(0)
    vm.requireFn(f, n)
    let L = a.items.len
    var i = if m == mReduce: 0 else: L - 1
    let dir = if m == mReduce: 1 else: -1
    var acc: Value
    if argc >= 2:
      acc = A(1)
    else:
      if L == 0: vm.typeErr(n, "Reduce of empty array with no initial value")
      acc = a.items[i]
      i += dir
    while i >= 0 and i < a.items.len:
      let base2 = vm.sp
      vm.push(acc)
      vm.push(a.items[i])
      vm.push(numV(float(i)))
      vm.push(this)
      acc = vm.callValue(f, undef(), base2, 4, n)
      i += dir
    acc
  of mFill:
    let L = a.items.len
    let i = relIdx(A(1), L, 0)
    let j = relIdx(A(2), L, L)
    vm.charge(j - i, n)
    for k in i ..< j: a.items[k] = A(0)
    this
  of mFlat:
    let depth = if A(0).kind == vkUndefined: 1 else: clampInt(toInteger(toNum(A(0))), 0, 100)
    var res: seq[Value]
    proc flatten(vm: Vm; src: seq[Value]; d: int; res: var seq[Value]; n: Node) =
      for it in src:
        if it.kind == vkArray and d > 0: flatten(vm, it.aval.items, d - 1, res, n)
        else: res.add it
        vm.checkArr(res.len, n)
    flatten(vm, a.items, depth, res, n)
    vm.charge(res.len, n)
    arrV(res)
  of mAt:
    let L = a.items.len
    var i = toInteger(toNum(A(0)))
    if i < 0: i += float(L)
    if i < 0 or i >= float(L): undef() else: a.items[int(i)]
  of mValueOf: this
  else: vm.typeErr(n, describe(n.a) & " is not a function")

proc numMethod(vm: Vm; this: Value; m: MethodId; base, argc: int; n: Node): Value =
  var x = this.nval
  case m
  of mToFixed:
    let d = toInteger(toNum(A(0)))
    if d < 0 or d > 100: vm.rangeErr(n, "toFixed() digits argument must be between 0 and 100")
    if x != x: return strV("NaN")
    if abs(x) >= 1e21: return strV(numToStr(x))
    if x == 0: x = 0.0
    strV(toFixedStr(x, int(d)))
  of mToPrecision:
    if A(0).kind == vkUndefined: return strV(numToStr(x))
    let p = toInteger(toNum(A(0)))
    if p < 1 or p > 100: vm.rangeErr(n, "toPrecision() argument must be between 1 and 100")
    if x != x or x == Inf or x == -Inf: return strV(numToStr(x))
    if x == 0: x = 0.0
    strV(toPrecisionStr(x, int(p)))
  of mToString:
    let r = if A(0).kind == vkUndefined: 10 else: int(clampInt(toInteger(toNum(A(0))), 0, 100))
    if r < 2 or r > 36: vm.rangeErr(n, "toString() radix must be between 2 and 36")
    strV(if r == 10: numToStr(x) else: numToRadix(x, r))
  of mValueOf: this
  else: vm.typeErr(n, describe(n.a) & " is not a function")

proc callMethod(vm: Vm; recv: Value; m: MethodId; base, argc: int; n: Node): Value =
  case recv.kind
  of vkStr:
    if m notin strMethods or m == mLength: vm.typeErr(n, describe(if n != nil: n.a else: nil) & " is not a function")
    result = vm.strMethod(recv, m, base, argc, n)
  of vkArray:
    if m notin arrMethods: vm.typeErr(n, describe(if n != nil: n.a else: nil) & " is not a function")
    result = vm.arrMethod(recv, m, base, argc, n)
  of vkNum:
    if m notin numMethods: vm.typeErr(n, describe(if n != nil: n.a else: nil) & " is not a function")
    result = vm.numMethod(recv, m, base, argc, n)
  of vkBool:
    case m
    of mToString: result = strV(toStr(recv))
    of mValueOf: result = recv
    else: vm.typeErr(n, describe(if n != nil: n.a else: nil) & " is not a function")
  of vkFunction:
    let f = recv.fval
    case m
    of mCall:
      result = vm.callValue(recv, A(0), base + min(argc, 1), max(argc - 1, 0), n)
    of mApply:
      let nb = vm.sp
      let args = A(1)
      if args.kind == vkArray:
        vm.checkArr(args.aval.items.len, n)
        for x in args.aval.items: vm.push(x)
      elif args.kind > vkNull: vm.typeErr(n, "The second argument of apply must be an array")
      result = vm.callValue(recv, A(0), nb, vm.sp - nb, n)
    of mBind:
      var bound: seq[Value]
      for i in 1 ..< argc: bound.add A(i)
      result = Value(kind: vkFunction, fval: Fn(kind: fkBoundFn, name: "bound " & f.name, target: recv,
                                                boundThis: A(0), boundArgs: bound))
    of mToString: result = strV(toStr(recv))
    else: vm.typeErr(n, describe(if n != nil: n.a else: nil) & " is not a function")
  of vkObject:
    case m
    of mHasOwnProperty: result = boolV(recv.oval.find(propKey(A(0))) >= 0)
    of mToString: result = strV(toStr(recv))
    of mValueOf: result = recv
    else: vm.typeErr(n, describe(if n != nil: n.a else: nil) & " is not a function")
  else:
    vm.typeErr(n, describe(if n != nil: n.a else: nil) & " is not a function")
  vm.sp = base

# ---- globals ------------------------------------------------------------------------------------------------------

template nat(body: untyped): NativeProc =
  proc (vm {.inject.}: Vm; this {.inject.}: Value; base {.inject.}, argc {.inject.}: int;
        site {.inject.}: Node): Value {.nimcall.} =
    body

proc nativeV(name: string; p: NativeProc; props: Obj = nil): Value =
  Value(kind: vkFunction, fval: Fn(kind: fkNative, name: name, native: p, props: props))

proc emit(vm: Vm; s: string; n: Node) =
  if vm.output == nil:
    echo s
  else:
    vm.hostGuard(n):
      vm.output(s)

proc setGlobal*(vm: Vm; name: string; v: Value) =
  ## Sets (or makes) a global variable.
  let i = vm.defineSlot(name)
  vm.gvals[i] = v
  vm.gconst[i] = false

proc getGlobal*(vm: Vm; name: string): Value =
  ## A global variable (a function the script made, say), or undefined.
  let i = vm.gnames.getOrDefault(name, -1)
  if i < 0: undef() else: vm.gvals[i]

proc arrayFrom(vm: Vm; v: Value; n: Node): seq[Value] =
  case v.kind
  of vkArray: v.aval.items
  of vkStr:
    var r: seq[Value]
    let st = v.sval
    var b = 0
    while b < st.s.len:
      let l = cpBytes(st.s, b)
      r.add strV(st.s[b ..< b + l])
      b += l
    r
  of vkObject:
    let L = clampInt(toInteger(toNum(v.oval.getProp("length"))), 0, high(int32))
    vm.checkArr(L, n)
    var r = newSeq[Value](L)
    for i in 0 ..< L: r[i] = v.oval.getProp($i)
    r
  else: @[]

template errCtor(nm: string): NativeProc =
  nat:
    let msg = if argc > 0 and vm.stack[base].kind != vkUndefined: toStr(vm.stack[base]) else: ""
    vm.makeError(nm, msg, site)

proc setupGlobals(vm: Vm) =
  let printFn = nat:
    var s = ""
    for i in 0 ..< argc:
      if i > 0: s.add ' '
      let v = vm.stack[base + i]
      if v.kind == vkStr: s.add v.sval.s else: s.add inspect(v)
    vm.emit(s, site)
    undef()
  vm.setGlobal("print", nativeV("print", printFn))
  let console = Obj()
  for nm in ["log", "info", "warn", "error", "debug"]: console.put(nm, nativeV(nm, printFn))
  vm.setGlobal("console", objV(console))

  let mathO = Obj()
  template m1(nm: string; f: untyped) =
    mathO.put(nm, nativeV(nm, nat(numV(f(toNum(A(0)))))))
  m1("abs", abs)
  m1("floor", floor)
  m1("ceil", ceil)
  m1("round", jsRound)
  m1("sqrt", sqrt)
  m1("cbrt", jsCbrt)
  m1("sin", sin)
  m1("cos", cos)
  m1("tan", tan)
  m1("asin", arcsin)
  m1("acos", arccos)
  m1("atan", arctan)
  m1("sinh", sinh)
  m1("cosh", cosh)
  m1("tanh", tanh)
  m1("log", ln)
  m1("log2", log2)
  m1("log10", log10)
  m1("exp", exp)
  m1("trunc", trunc)
  m1("sign", proc (x: float64): float64 = (if x > 0: 1.0 elif x < 0: -1.0 else: x))
  mathO.put("atan2", nativeV("atan2", nat(numV(arctan2(toNum(A(0)), toNum(A(1)))))))
  mathO.put("pow", nativeV("pow", nat(numV(jsPow(toNum(A(0)), toNum(A(1)))))))
  mathO.put("min", nativeV("min", nat do:
    var r = Inf
    for i in 0 ..< argc:
      let x = toNum(vm.stack[base + i])
      if x != x: return numV(NaN)
      if x < r or (x == 0 and r == 0 and signbit(x)): r = x
    numV(r)))
  mathO.put("max", nativeV("max", nat do:
    var r = -Inf
    for i in 0 ..< argc:
      let x = toNum(vm.stack[base + i])
      if x != x: return numV(NaN)
      if x > r or (x == 0 and r == 0 and not signbit(x)): r = x
    numV(r)))
  mathO.put("hypot", nativeV("hypot", nat do:
    var s = 0.0
    var inf = false
    var nan = false
    for i in 0 ..< argc:
      let x = abs(toNum(vm.stack[base + i]))
      if x == Inf: inf = true
      elif x != x: nan = true
      else: s += x * x
    numV(if inf: Inf elif nan: NaN else: sqrt(s))))
  mathO.put("random", nativeV("random", nat(numV(float(vm.rng.next() shr 11) * (1.0 / 9007199254740992.0)))))
  mathO.put("PI", numV(PI))
  mathO.put("E", numV(E))
  mathO.put("LN2", numV(ln(2.0)))
  mathO.put("LN10", numV(ln(10.0)))
  mathO.put("LOG2E", numV(1 / ln(2.0)))
  mathO.put("LOG10E", numV(1 / ln(10.0)))
  mathO.put("SQRT2", numV(sqrt(2.0)))
  mathO.put("SQRT1_2", numV(sqrt(0.5)))
  vm.setGlobal("Math", objV(mathO))

  let jsonO = Obj()
  jsonO.put("stringify", nativeV("stringify", nat do:
    var indent = ""
    let sp = A(2)
    if sp.kind == vkNum: indent = repeat(' ', clampInt(toInteger(sp.nval), 0, 10))
    elif sp.kind == vkStr: indent = sp.sval.s[0 ..< min(10, sp.sval.s.len)]
    var s = ""
    var seen: seq[pointer]
    try:
      if not jsonInto(A(0), s, indent, "", seen): return undef()
    except JsonCycle as e:
      vm.typeErr(site, e.msg)
    vm.checkStr(s.len, site)
    vm.charge(s.len, site)
    strV(s)))
  jsonO.put("parse", nativeV("parse", nat do:
    let text = toStr(A(0))
    vm.charge(text.len, site)
    try:
      parseJson(text)
    except ValueError as e:
      vm.throwErr(site, "SyntaxError", e.msg)))
  vm.setGlobal("JSON", objV(jsonO))

  let objectO = Obj()
  objectO.put("keys", nativeV("keys", nat do:
    if A(0).kind <= vkNull: vm.typeErr(site, "Cannot convert undefined or null to object")
    var r: seq[Value]
    for k in ownKeys(A(0)): r.add strV(k)
    arrV(r)))
  objectO.put("values", nativeV("values", nat do:
    let o = A(0)
    if o.kind <= vkNull: vm.typeErr(site, "Cannot convert undefined or null to object")
    var r: seq[Value]
    for k in ownKeys(o): r.add vm.getMember(o, k, site)
    arrV(r)))
  objectO.put("entries", nativeV("entries", nat do:
    let o = A(0)
    if o.kind <= vkNull: vm.typeErr(site, "Cannot convert undefined or null to object")
    var r: seq[Value]
    for k in ownKeys(o): r.add arrV(@[strV(k), vm.getMember(o, k, site)])
    arrV(r)))
  objectO.put("assign", nativeV("assign", nat do:
    let t = A(0)
    if t.kind <= vkNull: vm.typeErr(site, "Cannot convert undefined or null to object")
    for i in 1 ..< argc:
      let src = A(i)
      for k in ownKeys(src): vm.setMember(t, k, vm.getMember(src, k, site), site)
    t))
  objectO.put("fromEntries", nativeV("fromEntries", nat do:
    let o = Obj()
    for e in vm.arrayFrom(A(0), site):
      if e.kind != vkArray: vm.typeErr(site, "Iterator value " & inspect(e) & " is not an entry object")
      o.put(propKey(if e.aval.items.len > 0: e.aval.items[0] else: undef()),
            if e.aval.items.len > 1: e.aval.items[1] else: undef())
    objV(o)))
  let objectFn = nat do:
    if A(0).kind in {vkObject, vkArray, vkFunction, vkHost}: A(0) else: objV(Obj())
  vm.setGlobal("Object", nativeV("Object", objectFn, objectO))

  let arrayO = Obj()
  arrayO.put("isArray", nativeV("isArray", nat(boolV(A(0).kind == vkArray))))
  arrayO.put("of", nativeV("of", nat do:
    var r = newSeq[Value](argc)
    for i in 0 ..< argc: r[i] = A(i)
    arrV(r)))
  arrayO.put("from", nativeV("from", nat do:
    var r = vm.arrayFrom(A(0), site)
    let f = A(1)
    if f.kind != vkUndefined:
      vm.requireFn(f, site)
      for i in 0 ..< r.len: r[i] = vm.callBack(f, r[i], numV(float(i)), undef(), 2, site)
    arrV(r)))
  let arrayFn = nat do:
    if argc == 1 and A(0).kind == vkNum:
      let x = A(0).nval
      if x < 0 or x != trunc(x): vm.rangeErr(site, "Invalid array length")
      vm.checkArr(clampInt(x, 0, high(int32)), site)
      vm.charge(int(x), site)
      return arrV(newSeq[Value](int(x)))
    var r = newSeq[Value](argc)
    for i in 0 ..< argc: r[i] = A(i)
    arrV(r)
  vm.setGlobal("Array", nativeV("Array", arrayFn, arrayO))

  let stringO = Obj()
  let fromCp = nat do:
    var s = ""
    for i in 0 ..< argc:
      s.add encodeCp(clampInt(toInteger(toNum(A(i))), -1, 0x110000))
    strV(s)
  stringO.put("fromCharCode", nativeV("fromCharCode", fromCp))
  stringO.put("fromCodePoint", nativeV("fromCodePoint", fromCp))
  vm.setGlobal("String", nativeV("String", nat(strV(if argc == 0: "" else: toStr(A(0)))), stringO))
  vm.setGlobal("Boolean", nativeV("Boolean", nat(boolV(toBool(A(0))))))

  let parseIntFn = nat do:
    let s = toStr(A(0)).strip(chars = jsSpace)
    var radix = clampInt(toInteger(toNum(A(1))), -1, 37)
    var i = 0
    var neg = false
    if i < s.len and s[i] in {'+', '-'}:
      neg = s[i] == '-'
      inc i
    if radix == 0 or radix == 16:
      if i + 1 < s.len and s[i] == '0' and s[i + 1] in {'x', 'X'}:
        i += 2
        radix = 16
    if radix == 0: radix = 10
    if radix < 2 or radix > 36: return numV(NaN)
    var v = 0.0
    var any = false
    while i < s.len:
      let d = hexVal(s[i])
      if d >= radix: break
      v = v * float(radix) + float(d)
      any = true
      inc i
    if not any: numV(NaN) else: numV(if neg: -v else: v)
  let parseFloatFn = nat do:
    let s = toStr(A(0)).strip(leading = true, trailing = false, chars = jsSpace)
    let n = decimalPrefix(s, 0)
    if n == 0: numV(NaN) else: numV(parseDecimal(s[0 ..< n]))
  let isNaNFn = nat(boolV(toNum(A(0)) != toNum(A(0))))
  let isFiniteFn = nat do:
    let x = toNum(A(0))
    boolV(x == x and x != Inf and x != -Inf)
  vm.setGlobal("parseInt", nativeV("parseInt", parseIntFn))
  vm.setGlobal("parseFloat", nativeV("parseFloat", parseFloatFn))
  vm.setGlobal("isNaN", nativeV("isNaN", isNaNFn))
  vm.setGlobal("isFinite", nativeV("isFinite", isFiniteFn))
  let numberO = Obj()
  numberO.put("parseInt", nativeV("parseInt", parseIntFn))
  numberO.put("parseFloat", nativeV("parseFloat", parseFloatFn))
  numberO.put("isNaN", nativeV("isNaN", nat(boolV(A(0).kind == vkNum and A(0).nval != A(0).nval))))
  numberO.put("isFinite", nativeV("isFinite", nat do:
    boolV(A(0).kind == vkNum and A(0).nval == A(0).nval and abs(A(0).nval) != Inf)))
  numberO.put("isInteger", nativeV("isInteger", nat do:
    boolV(A(0).kind == vkNum and abs(A(0).nval) != Inf and A(0).nval == trunc(A(0).nval))))
  numberO.put("isSafeInteger", nativeV("isSafeInteger", nat do:
    boolV(A(0).kind == vkNum and A(0).nval == trunc(A(0).nval) and abs(A(0).nval) <= 9007199254740991.0)))
  numberO.put("MAX_SAFE_INTEGER", numV(9007199254740991.0))
  numberO.put("MIN_SAFE_INTEGER", numV(-9007199254740991.0))
  numberO.put("EPSILON", numV(pow(2.0, -52.0)))
  numberO.put("MAX_VALUE", numV(1.7976931348623157e308))
  numberO.put("MIN_VALUE", numV(5e-324))
  numberO.put("POSITIVE_INFINITY", numV(Inf))
  numberO.put("NEGATIVE_INFINITY", numV(-Inf))
  numberO.put("NaN", numV(NaN))
  vm.setGlobal("Number", nativeV("Number", nat(numV(if argc == 0: 0.0 else: toNum(A(0)))), numberO))

  vm.setGlobal("Error", nativeV("Error", errCtor("Error")))
  vm.setGlobal("TypeError", nativeV("TypeError", errCtor("TypeError")))
  vm.setGlobal("RangeError", nativeV("RangeError", errCtor("RangeError")))
  vm.setGlobal("SyntaxError", nativeV("SyntaxError", errCtor("SyntaxError")))
  vm.setGlobal("ReferenceError", nativeV("ReferenceError", errCtor("ReferenceError")))
  vm.setGlobal("Function", nativeV("Function", nat(vm.typeErr(site, "Function() is not supported"))))

  let dateO = Obj()
  dateO.put("now", nativeV("now", nat(numV(floor(epochTime() * 1000)))))
  vm.setGlobal("Date", objV(dateO))

# ---- the host's side ----------------------------------------------------------------------------------------------

proc newVm*(output: proc (s: string) {.closure.} = nil): Vm =
  ## A new interpreter with the built-in globals. `print` and `console.log`
  ## write to `output` (to stdout when nil).
  inc vmCount
  result = Vm(id: vmCount, output: output, maxDepth: defaultMaxDepth, maxStringLen: 16 shl 20,
              maxArrayLen: 4 shl 20, maxNativeStack: 2 shl 20, stepBudget: 50_000_000,
              rng: initRand(int64(epochTime() * 1e6) xor 0x5DEECE66D))
  result.setupGlobals()

proc seedRandom*(vm: Vm; seed: int64) =
  ## Makes `Math.random()` give the same numbers again.
  vm.rng = initRand(seed)

proc cancel*(vm: Vm) =
  ## Stops the running script at its next step, with a `ScriptError`
  ## ("the script was cancelled") that the script cannot catch. Call it from
  ## a host function, a UI callback, or another thread holding the `Vm`.
  atomicStoreN(addr vm.cancelled, true, ATOMIC_RELAXED)

proc defineFn*(vm: Vm; name: string; fn: HostFn) =
  ## A global function that runs `fn`.
  vm.setGlobal(name, Value(kind: vkFunction, fval: Fn(kind: fkHost, name: name, host: fn)))

proc newObjectValue*(members: openArray[(string, Value)] = []): Value =
  ## A plain object with these members, in this order.
  let o = Obj()
  for (k, v) in members: o.put(k, v)
  objV(o)

proc defineObject*(vm: Vm; name: string; members: openArray[(string, Value)]) =
  ## A global object (`app`, say) with these members; a member made with
  ## `toValue(proc ...)` is a method.
  vm.setGlobal(name, newObjectValue(members))

proc hostObject*(get: HostGet; set: HostSet = nil; call: HostCall = nil; data: RootRef = nil): Value =
  ## A live object: reading `o.key` asks `get`, `o.key = v` asks `set`
  ## (false: the script gets a TypeError), and `o.key(args)` asks `call`
  ## (when `call` is nil, the method is what `get` gives). `data` is the
  ## host's own, for knowing the object again (`hostData`) when a script
  ## hands it back. Two values are the same object (`===`) only when they
  ## come from the same `hostObject` call.
  Value(kind: vkHost, hval: Host(get: get, set: set, call: call, data: data))

proc hostData*(v: Value): RootRef =
  ## The `data` of a host object; nil for any other value.
  if v.kind == vkHost: v.hval.data else: nil

proc leave(vm: Vm) =
  dec vm.running
  if vm.running == 0:
    for i in 0 ..< vm.stack.len:
      if vm.stack[i].kind > vkNum: vm.stack[i] = undef()
    vm.retVal = undef()
    vm.env = nil

proc enter(vm: Vm; budget: int; marker: pointer) =
  if vm.running == 0:
    vm.left = budget
    atomicStoreN(addr vm.cancelled, false, ATOMIC_RELAXED)
    vm.stackBase = cast[int](marker)
    vm.sp = 0
    vm.bp = 0
    vm.depth = 0
    vm.env = nil
    vm.optShort = false
    vm.label = ""
    vm.topDepth = -1
  inc vm.running

proc run*(vm: Vm; s: Script; maxSteps = 50_000_000): Value =
  ## Runs a script and gives the value of its top-level `return`, or else
  ## the value of the last expression statement it ran at its top level (as
  ## JavaScript's `eval` does: `x = 2; x * 3` gives 6). Raises `ScriptError` with
  ## the message, line, column and calls of an error the script didn't
  ## catch. `maxSteps` bounds the work (a run inside a running script
  ## shares the outer budget).
  var marker = 0
  vm.enter(maxSteps, addr marker)
  let sBp = vm.bp
  let sSp = vm.sp
  let sEnv = vm.env
  let sDepth = vm.depth
  let sTop = vm.topDepth
  var sCompletion = move(vm.completion)
  try:
    let p = s.main
    let base = vm.sp
    if base + p.nregs > vm.stack.len: vm.stack.setLen(max(base + p.nregs + 64, vm.stack.len * 2))
    for i in 0 ..< p.nregs: vm.stack[base + i] = undef()
    vm.bp = base
    vm.sp = base + p.nregs
    vm.env = nil
    if vm.depth >= vm.calls.len: vm.calls.setLen(max(32, vm.calls.len * 2))
    vm.calls[vm.depth] = CallRec(proto: p, site: nil)
    inc vm.depth
    vm.topDepth = vm.depth
    vm.completion = undef()
    var returned = false
    for st in p.body.list:
      let c = exec(vm, st)
      if c == cReturn:
        result = move(vm.retVal)
        returned = true
        break
      elif c != cNormal: break
    if not returned: result = move(vm.completion)
  finally:
    vm.bp = sBp
    vm.sp = sSp
    vm.env = sEnv
    vm.depth = sDepth
    vm.topDepth = sTop
    vm.completion = move(sCompletion)
    vm.leave()

proc call*(vm: Vm; fn: Value; args: seq[Value]): Value =
  ## Calls a script function (a callback the script gave the host, or one
  ## found with `getGlobal`). Outside a run it gets `stepBudget` steps.
  var marker = 0
  vm.enter(vm.stepBudget, addr marker)
  let sBp = vm.bp
  let sSp = vm.sp
  let sEnv = vm.env
  let sDepth = vm.depth
  let sTop = vm.topDepth
  vm.topDepth = -1
  try:
    let base = vm.sp
    for a in args: vm.push(a)
    result = vm.callValue(fn, undef(), base, args.len, nil)
  finally:
    vm.bp = sBp
    vm.sp = sSp
    vm.env = sEnv
    vm.depth = sDepth
    vm.topDepth = sTop
    vm.leave()

# ---- values for the host ------------------------------------------------------------------------------------------

proc undefinedValue*(): Value = undef()
  ## `undefined`.
proc nullValue*(): Value = nullV()
  ## `null`.
proc toValue*(x: float): Value = numV(x)
  ## A number.
proc toValue*(x: int): Value = numV(float(x))
  ## A number.
proc toValue*(x: string): Value = strV(x)
  ## A string.
proc toValue*(x: bool): Value = boolV(x)
  ## `true` or `false`.
proc toValue*(x: seq[Value]): Value = arrV(x)
  ## An array.
proc toValue*(x: openArray[(string, Value)]): Value = newObjectValue(x)
  ## An object.
proc toValue*(fn: HostFn): Value = Value(kind: vkFunction, fval: Fn(kind: fkHost, host: fn))
  ## A function that runs `fn`.
proc newArrayValue*(items: seq[Value] = @[]): Value = arrV(items)
  ## An array.

proc toInt*(v: Value): int =
  ## The value as a whole number (truncated; NaN is 0).
  clampInt(toInteger(toNum(v)), low(int32), high(int32))

proc len*(v: Value): int =
  ## How many items an array has, characters a string has, keys an object has.
  case v.kind
  of vkArray: v.aval.items.len
  of vkStr: v.sval.cpCount
  of vkObject: v.oval.keys.len
  else: 0

proc `[]`*(v: Value; i: int): Value =
  ## An array's item (undefined past its end).
  if v.kind == vkArray and i >= 0 and i < v.aval.items.len: v.aval.items[i] else: undef()

proc `[]`*(v: Value; key: string): Value =
  ## An object's member (undefined when it has none).
  case v.kind
  of vkObject: v.oval.getProp(key)
  of vkHost: (if v.hval.get != nil: v.hval.get(key) else: undef())
  of vkFunction: (if v.fval.props != nil: v.fval.props.getProp(key) else: undef())
  else: undef()

proc `[]=`*(v: Value; key: string; x: Value) =
  ## Sets an object's member.
  if v.kind == vkObject: v.oval.put(key, x)

proc `[]=`*(v: Value; i: int; x: Value) =
  ## Sets an array's item, growing it when needed.
  if v.kind == vkArray and i >= 0:
    if i >= v.aval.items.len: v.aval.items.setLen(i + 1)
    v.aval.items[i] = x

proc add*(v: Value; x: Value) =
  ## Adds an item to the end of an array.
  if v.kind == vkArray: v.aval.items.add x

iterator items*(v: Value): Value =
  ## An array's items.
  if v.kind == vkArray:
    var i = 0
    while i < v.aval.items.len:
      yield v.aval.items[i]
      inc i

iterator keys*(v: Value): string =
  ## An object's keys, in order.
  for k in ownKeys(v): yield k

iterator pairs*(v: Value): (string, Value) =
  ## An object's keys and values, in order.
  if v.kind == vkObject:
    let o = v.oval
    var i = 0
    while i < o.keys.len:
      yield (o.keys[i], o.vals[i])
      inc i

proc `==`*(a, b: Value): bool = strictEq(a, b)
  ## Same as the script's `===`.

proc `$`*(v: Value): string = toStr(v)
  ## Same as the script's `String(v)`.

{.pop.}

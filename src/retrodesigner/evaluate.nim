## Retro Designer's drawing of a page: the page's items drawn with the real
## controls, in a window of its own inside the designer (`windowBox`),
## taking no input (`inert`), each item's place on the screen kept for the
## designer to select it. A control's arguments are read from the file:
## what is written out (a text, a number, a list, an enum's value) is used,
## what code works out is left to the control's default. The variables the
## controls change are cells with the values of their `var` lines.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[tables, strutils]
import compiler/[ast, idents]
import retroui
import source, registry, values, model

type
  Eval* = object
    design*: Design
    cells*: Table[string, VarCell]       ## the variables, by name (as Nim reads names)
    failed*: seq[tuple[line: int; msg: string]]   ## controls that could not be drawn
    lastFailed: seq[tuple[line: int; msg: string]]
    focus*: Item                         ## the item chosen in the designer: the dialog,
                                         ## menu, tab or arm it is in is shown
    overlay*: Item                       ## the dialog or menu shown over the page now
    depth: int                           ## (procs drawn inside procs)
    live: bool                           ## (the preview: drawn as the app draws it)
    repeat: bool                         ## (a loop's second round on: places add up)

proc key(name: string): string = nimIdentNormalize(name)

proc exampleSize(name: string): tuple[w, h: int] =
  for x in widgetBox:
    if x.name == name: return (x.w, x.h)
  (160, 40)

# ---- values -------------------------------------------------------------------------------------

proc valueOf*(e: var Eval; n: PNode): Value
proc cellFor*(e: var Eval; n: PNode): VarCell

proc literal(e: var Eval; n: PNode): Value =
  case n.kind
  of nkStrLit, nkRStrLit, nkTripleStrLit: Value(kind: vkStr, s: n.strVal)
  of nkCharLit: Value(kind: vkStr, s: $char(n.intVal))
  of nkIntLit .. nkUInt64Lit:
    # (on a 32-bit system a number past an int's: its low 32 bits, as a color is)
    when sizeof(int) == 8: Value(kind: vkInt, i: int(n.intVal))
    else: Value(kind: vkInt, i: int(cast[int32](uint32(n.intVal and 0xFFFFFFFF'i64))))
  of nkFloatLit .. nkFloat128Lit: Value(kind: vkFloat, f: n.floatVal)
  else: Value()

proc valueOf*(e: var Eval; n: PNode): Value =
  ## What expression `n` is while designing (vkNone: code works it out).
  if n == nil: return Value()
  case n.kind
  of nkStrLit, nkRStrLit, nkTripleStrLit, nkCharLit, nkIntLit .. nkUInt64Lit,
     nkFloatLit .. nkFloat128Lit:
    e.literal(n)
  of nkIdent:
    let nm = n.ident.s
    if nm == "true": return Value(kind: vkBool, b: true)
    if nm == "false": return Value(kind: vkBool, b: false)
    if e.cells.hasKey(key(nm)):
      let c = e.cells[key(nm)]
      case c.kind
      of vkStr: return Value(kind: vkStr, s: c.s)
      of vkInt: return Value(kind: vkInt, i: c.i)
      of vkFloat: return Value(kind: vkFloat, f: c.f)
      of vkBool: return Value(kind: vkBool, b: c.b)
      of vkStrs: return Value(kind: vkStrs, ss: c.ss)
      of vkInts: return Value(kind: vkInts, ii: c.ii)
      of vkIdent: return Value(kind: vkIdent, s: c.s)
      else: discard
      let vi = e.design.varOf(nm)
      let init = if vi >= 0: e.design.vars[vi].init else: ""
      # (the cell as the kind its starting value is)
      if c.ss.len > 0: return Value(kind: vkStrs, ss: c.ss)
      if c.ii.len > 0: return Value(kind: vkInts, ii: c.ii)
      if init.startsWith("\"") or c.s.len > 0: return Value(kind: vkStr, s: c.s)
      if init in ["true", "false"]: return Value(kind: vkBool, b: c.b)
      if '.' in init and init.len > 0 and init[0] in {'0'..'9', '-'}: return Value(kind: vkFloat, f: c.f)
      if init.len > 0 and init[0] in {'0'..'9', '-'}: return Value(kind: vkInt, i: c.i)
      # (nothing tells what it holds: not known)
      return Value()
    case nm
    of "Gap": return Value(kind: vkInt, i: Gap)
    of "Pad": return Value(kind: vkInt, i: Pad)
    of "CtrlH": return Value(kind: vkInt, i: CtrlH)
    of "EditH": return Value(kind: vkInt, i: EditH)
    of "ItemH": return Value(kind: vkInt, i: ItemH)
    of "FontH": return Value(kind: vkInt, i: FontH)
    else: discard
    if stringConsts.hasKey(nm): return Value(kind: vkStr, s: stringConsts[nm])
    if intConsts.hasKey(nm): return Value(kind: vkInt, i: intConsts[nm])
    Value(kind: vkIdent, s: nm)
  of nkPrefix:
    if n.len == 2 and n[0].kind == nkIdent:
      let v = e.valueOf(n[1])
      case n[0].ident.s
      of "-":
        if v.kind == vkInt: return Value(kind: vkInt, i: -v.i)
        if v.kind == vkFloat: return Value(kind: vkFloat, f: -v.f)
      of "@": return v
      of "not":
        if v.kind == vkBool: return Value(kind: vkBool, b: not v.b)
      of "$":
        if v.kind == vkInt: return Value(kind: vkStr, s: $v.i)
        if v.kind == vkFloat: return Value(kind: vkStr, s: $v.f)
        if v.kind == vkStr: return v
      else: discard
    Value()
  of nkBracket:
    var ss: seq[string]
    var ii: seq[int]
    var allS = true
    var allI = true
    for c in n:
      let v = e.valueOf(c)
      if v.kind == vkStr: ss.add v.s else: allS = false
      if v.kind == vkInt: ii.add v.i else: allI = false
    if n.len == 0: return Value(kind: vkStrs)
    if allS: return Value(kind: vkStrs, ss: ss)
    if allI: return Value(kind: vkInts, ii: ii)
    Value()
  of nkCurly:
    var names: seq[string]
    for c in n:
      if c.kind == nkIdent: names.add c.ident.s
    Value(kind: vkSet, ss: names)
  of nkInfix:
    if n.len == 3 and n[0].kind == nkIdent:
      let op = n[0].ident.s
      let a = e.valueOf(n[1])
      let b = e.valueOf(n[2])
      case op
      of "&":
        if a.kind == vkStr and b.kind == vkStr: return Value(kind: vkStr, s: a.s & b.s)
        if a.kind == vkStr: return Value(kind: vkStr, s: a.s & "...")
        if b.kind == vkStr: return Value(kind: vkStr, s: "..." & b.s)
      of "+", "-", "*", "div":
        if a.kind == vkInt and b.kind == vkInt:
          return Value(kind: vkInt, i: (case op
                                        of "+": a.i + b.i
                                        of "-": a.i - b.i
                                        of "*": a.i * b.i
                                        else: (if b.i != 0: a.i div b.i else: 0)))
      of "==", "!=":
        if a.kind != vkNone and a.kind == b.kind:
          let same = $a == $b
          return Value(kind: vkBool, b: (if op == "==": same else: not same))
        if a.kind == vkInt and b.kind == vkIdent: return Value()
      of "and", "or":
        if a.kind == vkBool and b.kind == vkBool:
          return Value(kind: vkBool, b: (if op == "and": a.b and b.b else: a.b or b.b))
      of "<", "<=", ">", ">=":
        if a.kind == vkInt and b.kind == vkInt:
          return Value(kind: vkBool, b: (case op
                                         of "<": a.i < b.i
                                         of "<=": a.i <= b.i
                                         of ">": a.i > b.i
                                         else: a.i >= b.i))
      else: discard
    Value()
  of nkCall, nkCommand:
    let c = n.callee
    let args = n.args
    case c
    of "tr", "dp", "int", "float", "string", "uint8":
      if args.len == 1:
        let v = e.valueOf(args[0])
        if c == "float" and v.kind == vkInt: return Value(kind: vkFloat, f: float(v.i))
        return v
    of "color", "rgb", "rgba":
      var xs: seq[int]
      for a in args:
        let v = e.valueOf(a)
        if v.kind == vkInt: xs.add v.i
        else: return Value()
      if xs.len >= 3:
        let u = proc (x: int): uint8 = uint8(clamp(x, 0, 255))
        return Value(kind: vkColor, c: color(u(xs[0]), u(xs[1]), u(xs[2]), u(if xs.len > 3: xs[3] else: 255)))
    of "rect":
      var xs: seq[int]
      for a in args:
        let v = e.valueOf(a)
        if v.kind == vkInt: xs.add v.i else: return Value()
      if xs.len == 4: return Value(kind: vkRect, r: rect(xs[0], xs[1], xs[2], xs[3]))
    of "defined": return Value(kind: vkBool, b: false)
    # (the layout's own measures: asked where the control is drawn, as the app would)
    of "available": return Value(kind: vkInt, i: available())
    of "remainingH": return Value(kind: vkInt, i: remainingH())
    of "textWidth":
      if args.len == 1:
        let v = e.valueOf(args[0])
        if v.kind == vkStr: return Value(kind: vkInt, i: textWidth(v.s))
    of "platformName": return Value(kind: vkStr, s: platformName())
    of "max", "min":
      if args.len == 2:
        let a = e.valueOf(args[0])
        let b = e.valueOf(args[1])
        if a.kind == vkInt and b.kind == vkInt:
          return Value(kind: vkInt, i: (if c == "max": max(a.i, b.i) else: min(a.i, b.i)))
    else: discard
    Value()
  of nkPar, nkStmtListExpr:
    if n.len == 1: return e.valueOf(n[0])
    Value()
  of nkIfExpr, nkIfStmt:
    # (the arm whose condition holds; not known: the first, to show something)
    var first = Value()
    for k, br in n:
      if br.len == 0: continue
      let v = e.valueOf(br[^1])
      if k == 0: first = v
      if br.kind in {nkElse, nkElseExpr}: return v
      let c = e.valueOf(br[0])
      if c.kind == vkBool and c.b: return v
      if c.kind != vkBool: return first
    first
  of nkExprEqExpr: e.valueOf(n[1])
  of nkDotExpr:
    let t = e.design.src.textOf(n)
    if t == "ui.w": return Value(kind: vkInt, i: ui.w)
    if t == "ui.h": return Value(kind: vkInt, i: ui.h)
    if e.cells.hasKey(key(t)):
      let c = e.cells[key(t)]
      case c.kind
      of vkInt: return Value(kind: vkInt, i: c.i)
      of vkFloat: return Value(kind: vkFloat, f: c.f)
      of vkBool: return Value(kind: vkBool, b: c.b)
      of vkStrs: return Value(kind: vkStrs, ss: c.ss)
      of vkInts: return Value(kind: vkInts, ii: c.ii)
      of vkIdent: return Value(kind: vkIdent, s: c.s)
      else:
        if c.s.len > 0: return Value(kind: vkStr, s: c.s)
    Value()
  else: Value()

proc inside*(it, outer: Item): bool =
  ## `it` is `outer` or in it.
  var p = it
  while p != nil:
    if p == outer: return true
    p = p.parent
  false

proc initValue(e: var Eval; init: PNode): Value =
  ## A variable's starting value. A call the designer cannot work out
  ## (`settings.getInt("width", 170)`) gives its last plain argument: the
  ## default such calls take.
  result = e.valueOf(init)
  if result.kind == vkNone and init.kind in {nkCall, nkCommand}:
    for k in countdown(init.len - 1, 1):
      let a = if init[k].kind == nkExprEqExpr: init[k][1] else: init[k]
      let v = e.literal(a)
      if v.kind != vkNone: result = v; return
      if a.kind == nkIdent and a.ident.s in ["true", "false"]:
        result = Value(kind: vkBool, b: a.ident.s == "true"); return

proc setCell(c: VarCell; v: Value) =
  if v.kind != vkNone: c.kind = v.kind
  case v.kind
  of vkStr, vkIdent: c.s = v.s
  of vkInt: c.i = v.i
  of vkFloat: c.f = v.f
  of vkBool: c.b = v.b
  of vkStrs: c.ss = v.ss
  of vkInts: c.ii = v.ii
  else: discard

proc cellFor*(e: var Eval; n: PNode): VarCell =
  ## The variable `n` names (a cell, made with its starting value).
  let t = if n.kind == nkIdent: n.ident.s else: e.design.src.textOf(n)
  let k = key(t)
  if e.cells.hasKey(k): return e.cells[k]
  result = VarCell(name: t)
  e.cells[k] = result

proc resetCells*(e: var Eval) =
  ## Every variable back to the value its `var` line gives it.
  e.cells.clear()
  let d = e.design
  for v in d.vars:
    if v.init.len == 0 or v.node == nil: continue
    let c = VarCell(name: v.name)
    c.setCell(e.initValue(v.node[^1]))
    e.cells[key(v.name)] = c

proc initEval*(d: Design): Eval =
  result.design = d
  result.resetCells()

# ---- matching a call to the control's parameters --------------------------------------------------

proc fits(v: Value; p: Param): int =
  ## How well a value fits a parameter: 2 yes, 0 not known, -3 no.
  if v.kind == vkNone: return 0
  case p.kind
  of kStr: (if v.kind == vkStr: 2 else: -3)
  of kInt: (if v.kind == vkInt: 2 elif v.kind == vkFloat: 1 else: -3)
  of kFloat: (if v.kind in {vkFloat, vkInt}: 2 else: -3)
  of kBool: (if v.kind == vkBool: 2 else: -3)
  of kStrs: (if v.kind == vkStrs: 2 elif v.kind == vkStr: 1 else: -3)
  of kInts, kFloats: (if v.kind == vkInts: 2 elif v.kind == vkInt: 1 else: -3)
  of kColor: (if v.kind == vkColor: 2 else: -3)
  of kRect: (if v.kind == vkRect: 2 else: -3)
  of kEnum:
    if v.kind == vkIdent and enumValues.hasKey(p.typ) and v.s in enumValues[p.typ]: 3
    else: -3
  of kSet: (if v.kind == vkSet: 2 else: -3)
  of kNone: (if v.kind == vkIdent: 0 else: -1)
  else: 0

proc paramIndex*(params: seq[Param]; name: string): int =
  for i, p in params:
    if cmpIgnoreStyle(p.name, name) == 0: return i
  -1

proc argsFor*(e: var Eval; call: PNode; params: seq[Param]): tuple[ok: bool; a: Args; score: int] =
  ## The call's arguments put to the parameters (and how well they fit).
  var a = Args(vals: newSeq[Value](params.len), cells: newSeq[VarCell](params.len))
  var score = 0
  var pi = 0
  for arg in call.args:
    var k: int
    var x: PNode
    if arg.kind == nkExprEqExpr and arg[0].kind == nkIdent:
      k = params.paramIndex(arg[0].ident.s)
      if k < 0: return (false, a, -100)
      x = arg[1]
    else:
      k = pi
      inc pi
      if k >= params.len:
        # (varargs: the rest go into the last parameter)
        if params.len > 0 and params[^1].typ.startsWith("varargs") and a.vals[^1].kind == vkStrs:
          let v = e.valueOf(arg)
          a.vals[^1].ss.add(if v.kind == vkStr: v.s else: "...")
          continue
        return (false, a, -100)
      x = arg
      if params[k].typ.startsWith("varargs"):
        let v = e.valueOf(x)
        a.vals[k] = Value(kind: vkStrs, ss: @[(if v.kind == vkStr: v.s else: "...")])
        score += 2
        continue
    let p = params[k]
    if p.kind in {kVStr, kVInt, kVFloat, kVBool, kVStrs, kVInts}:
      if x.kind in {nkIdent, nkDotExpr, nkBracketExpr}:
        let c = e.cellFor(x)
        if c.kind == vkNone:
          # (what it holds, as the control takes it)
          c.kind = case p.kind
                   of kVStr: vkStr
                   of kVInt: vkInt
                   of kVFloat: vkFloat
                   of kVBool: vkBool
                   of kVStrs: vkStrs
                   else: vkInts
        a.cells[k] = c
        score += 2
      else: score -= 3
    else:
      let v = e.valueOf(x)
      let f = fits(v, p)
      score += f
      if f > 0 or p.kind == kNone: a.vals[k] = v
  # (a parameter with no default and nothing for it: a worse fit)
  for i, p in params:
    if p.default.len == 0 and not a.given(i) and (i >= a.cells.len or a.cells[i] == nil):
      score -= 1
  (true, a, score)

# ---- drawing -----------------------------------------------------------------------------------

proc unionRect(a, b: Rect): Rect =
  if a.w <= 0 or a.h <= 0: return b
  if b.w <= 0 or b.h <= 0: return a
  let x0 = min(a.x, b.x)
  let y0 = min(a.y, b.y)
  rect(x0, y0, max(a.x + a.w, b.x + b.w) - x0, max(a.y + a.h, b.y + b.h) - y0)

proc dashed*(r: Rect; c: Color) =
  ## A dotted frame (what the designer draws for what it cannot).
  var x = r.x
  while x < r.x + r.w:
    fill(rect(x, r.y, min(3, r.x + r.w - x), 1), c)
    fill(rect(x, r.y + r.h - 1, min(3, r.x + r.w - x), 1), c)
    x += 6
  var y = r.y
  while y < r.y + r.h:
    fill(rect(r.x, y, 1, min(3, r.y + r.h - y)), c)
    fill(rect(r.x + r.w - 1, y, 1, min(3, r.y + r.h - y)), c)
    y += 6

proc box(e: var Eval; it: Item; caption: string; w = 0; h = 0) =
  ## A box where the designer cannot draw what the file has.
  let ww = if w > 0: min(w, max(dp(60), available())) else: max(dp(60), available())
  let hh = if h > 0: h else: ItemH + dp(10)
  let r = place(ww, hh)
  fill(r, mixColor(ui.theme.window, ui.theme.face, 0.5))
  dashed(r, ui.theme.shadow)
  pushClip(r)
  text(r.x + dp(6), r.y + (r.h - FontH) div 2, caption, ui.theme.gray)
  popClip()

proc drawItems*(e: var Eval; items: seq[Item])

proc condOf(e: var Eval; arm: Item): int =
  ## An arm's condition: 1 true, 0 false, -1 not known.
  let n = arm.node
  case n.kind
  of nkElse, nkElseExpr: 1
  of nkElifBranch, nkElifExpr:
    let v = e.valueOf(n[0])
    if v.kind == vkBool: (if v.b: 1 else: 0) else: -1
  of nkOfBranch:
    let st = arm.parent.node
    if st.kind != nkCaseStmt or st.len == 0: return -1
    let sel = e.valueOf(st[0])
    if sel.kind == vkNone: return -1
    for k in 0 ..< n.len - 1:
      let v = e.valueOf(n[k])
      if v.kind == sel.kind and $v == $sel: return 1
      if sel.kind == vkIdent and n[k].kind == nkIdent and cmpIgnoreStyle(n[k].ident.s, sel.s) == 0:
        return 1
    0
  else: 1

proc armShown*(e: var Eval; it: Item): int =
  ## The arm of a branch that is drawn: the one chosen in the designer,
  ## else the first that is not known to be false (as the program would
  ## go: an `else` only after the others are false).
  if e.focus != nil:
    for i, arm in it.kids:
      if e.focus.inside(arm): return i
  if it.shown >= 0 and it.shown < it.kids.len: return it.shown
  for i, arm in it.kids:
    if e.condOf(arm) != 0: return i
  -1

proc callControl(e: var Eval; it: Item) =
  if not controls.hasKey(it.name):
    e.box(it, it.name)
    return
  let ctl = controls[it.name]
  var best = -1
  var bestScore = low(int)
  var bestArgs: Args
  for i, ov in ctl.overloads:
    if ov.call == nil: continue
    let (ok, a, score) = e.argsFor(it.call, ov.params)
    if ok and score > bestScore:
      best = i
      bestScore = score
      bestArgs = a
  if best < 0:
    let (w, h) = exampleSize(it.name)
    e.box(it, it.name, dp(w), min(dp(h), dp(120)))
    return
  try:
    discard ctl.overloads[best].call(bestArgs)
  except Exception as ex:
    e.failed.add (it.line, it.name & ": " & ex.msg)
    e.box(it, it.name & " (" & ex.msg & ")")

proc bodyProc(e: ptr Eval; kids: seq[Item]): proc () {.closure.} =
  ## (a body of a block: its own closure -- one made in a loop would share
  ##  the loop's last `kids`)
  result = proc () = e[].drawItems(kids)

proc drawProc(e: var Eval; it: Item; pg: Page) =
  ## A call of one of the file's procs that draw: its controls drawn here,
  ## its parameters given the call's values while they are.
  let p = pg.node
  var saved: seq[tuple[k: string; had: bool; c: VarCell]]
  if p.len > 3 and p[3].kind == nkFormalParams:
    var names: seq[string]
    var defaults: seq[PNode]
    for k in 1 ..< p[3].len:
      let defs = p[3][k]
      if defs.kind != nkIdentDefs: continue
      for j in 0 ..< defs.len - 2:
        if defs[j].kind == nkIdent:
          names.add defs[j].ident.s
          defaults.add defs[^1]
    var vals = newSeq[PNode](names.len)
    var pi = 0
    for a in it.call.args:
      if a.kind == nkExprEqExpr and a[0].kind == nkIdent:
        for j, nm in names:
          if cmpIgnoreStyle(nm, a[0].ident.s) == 0: vals[j] = a[1]
      elif pi < vals.len:
        vals[pi] = a
        inc pi
    for j, nm in names:
      let k = key(nm)
      saved.add (k, e.cells.hasKey(k), e.cells.getOrDefault(k))
      let x = if vals[j] != nil: vals[j] elif defaults[j].kind != nkEmpty: defaults[j] else: nil
      let c = VarCell(name: nm)
      if x != nil:
        # (a variable passed: the same cell, so a `var` parameter changes it)
        if x.kind == nkIdent and e.cells.hasKey(key(x.ident.s)) and x.ident.s notin ["true", "false"]:
          e.cells[k] = e.cells[key(x.ident.s)]
          continue
        c.setCell(e.valueOf(x))
      e.cells[k] = c
  inc e.depth
  try:
    e.drawItems(pg.root.kids)
  finally:
    dec e.depth
    for (k, had, c) in saved:
      if had: e.cells[k] = c else: e.cells.del k

proc loopValues(e: var Eval; n: PNode): seq[Value] =
  ## What a `for` goes over, when the designer can tell (a list written out,
  ## a range of numbers, a variable holding a list); else nothing.
  if n.kind == nkInfix and n.len == 3 and n[0].kind == nkIdent and n[0].ident.s in ["..", "..<"]:
    let a = e.valueOf(n[1])
    let b = e.valueOf(n[2])
    if a.kind == vkInt and b.kind == vkInt:
      let last = if n[0].ident.s == "..": b.i else: b.i - 1
      for i in a.i .. min(last, a.i + 49): result.add Value(kind: vkInt, i: i)
    return
  let x = if n.kind in {nkCall, nkCommand} and n.callee in ["items", "pairs", "mitems", "mpairs"] and
             n.len == 2: n[1] else: n
  let v = e.valueOf(x)
  case v.kind
  of vkStrs:
    for t in v.ss: result.add Value(kind: vkStr, s: t)
  of vkInts:
    for i in v.ii: result.add Value(kind: vkInt, i: i)
  of vkStr:
    for ch in v.s: result.add Value(kind: vkStr, s: $ch)
  else: discard
  if result.len > 50: result.setLen(50)

proc drawLoop(e: var Eval; it: Item) =
  ## A `for` that draws: its body drawn for each value (once, when the
  ## designer cannot tell the values).
  let n = it.node
  var names: seq[string]
  for k in 0 ..< n.len - 2:
    if n[k].kind == nkIdent: names.add n[k].ident.s
    elif n[k].kind == nkVarTuple:
      for j in 0 ..< n[k].len:
        if n[k][j].kind == nkIdent: names.add n[k][j].ident.s
  let vals = e.loopValues(n[^2])
  var saved: seq[tuple[k: string; had: bool; c: VarCell]]
  for nm in names:
    let k = key(nm)
    saved.add (k, e.cells.hasKey(k), e.cells.getOrDefault(k))
  let wasRepeat = e.repeat
  try:
    if vals.len == 0:
      for nm in names: e.cells[key(nm)] = VarCell(name: nm)
      e.drawItems(it.kids)
    for i, v in vals:
      if names.len >= 2:
        let ci = VarCell(name: names[0])
        ci.setCell(Value(kind: vkInt, i: i))
        e.cells[key(names[0])] = ci
      if names.len >= 1:
        let cv = VarCell(name: names[^1])
        cv.setCell(v)
        e.cells[key(names[^1])] = cv
      e.repeat = wasRepeat or i > 0
      e.drawItems(it.kids)
  finally:
    e.repeat = wasRepeat
    for (k, had, c) in saved:
      if had: e.cells[k] = c else: e.cells.del k

proc callBlock(e: var Eval; it: Item) =
  let bs = blocks[it.name]
  var best = -1
  var bestScore = low(int)
  var bestArgs: Args
  for i, b in bs:
    if b.bodies != max(1, it.bodies.len): continue
    let (ok, a, score) = e.argsFor(it.call, b.params)
    if ok and score > bestScore:
      best = i
      bestScore = score
      bestArgs = a
  if best < 0:
    for i, b in bs:
      let (ok, a, score) = e.argsFor(it.call, b.params)
      if ok and score > bestScore:
        best = i
        bestScore = score
        bestArgs = a
  if best < 0:
    e.box(it, it.name)
    return
  var bodies: seq[proc () {.closure.}]
  for k in 0 ..< bs[best].bodies:
    bodies.add bodyProc(addr e, if k < it.bodies.len: it.bodies[k] else: @[])
  # (the item chosen in the designer is in it: a dialog, a branch, an
  #  expander open -- the variable that opens it true while it is drawn)
  let focused = e.focus != nil and e.focus.inside(it)
  var opened: seq[tuple[c: VarCell; was: Value]]
  if focused:
    for k, p in bs[best].params:
      if p.name notin ["open", "show", "shown", "visible", "expanded"]: continue
      if p.kind == kVBool and bestArgs.cells[k] != nil:
        let c = bestArgs.cells[k]
        opened.add (c, Value(kind: c.kind, b: c.b))
        c.kind = vkBool
        c.b = true
      elif p.kind == kBool:
        bestArgs.vals[k] = Value(kind: vkBool, b: true)
    if it.name in ["dialog", "wizard"]: e.overlay = it
  # (a menu of the menu bar with the chosen item in it: shown open)
  var menuShown: MenuShown
  var showing = false
  if it.name == "menubar" and e.focus != nil:
    var path: seq[string]
    for m in it.kids.items:
      if m.kind == ikBlock and m.name == "menu" and e.focus.inside(m):
        let ps = m.call.positional
        let t = if ps.len > 0: e.valueOf(ps[0]) else: Value()
        if t.kind != vkStr: break
        path.add t.s
        e.overlay = m
        for x in m.walk:
          if x.kind == ikBlock and x.name == "submenu" and e.focus.inside(x):
            let ps2 = x.call.positional
            let t2 = if ps2.len > 0: e.valueOf(ps2[0]) else: Value()
            if t2.kind == vkStr: path.add t2.s
            break
        break
    if path.len > 0:
      menuShown = showMenu(path)
      showing = true
  try:
    bs[best].run(bestArgs, bodies)
  except Exception as ex:
    e.failed.add (it.line, it.name & ": " & ex.msg)
  finally:
    if showing: hideMenu(menuShown)
    for (c, was) in opened:
      c.kind = was.kind
      c.b = was.b

proc drawItem(e: var Eval; it: Item) =
  let outer = ui.placed
  let before = if e.repeat and it.drawn: it.rect else: rect(0, 0, 0, 0)
  ui.placed = rect(0, 0, 0, 0)
  it.drawn = true
  case it.kind
  of ikControl, ikEvent, ikValue:
    e.callControl(it)
    # (drawn as nothing -- a label of an empty text --: a dotted place, to
    #  see and choose it; not in the preview)
    let r = ui.placed
    if not e.live and r.h > 0 and r.w < dp(6):
      let shown = rect(r.x, r.y, dp(48), max(r.h, FontH))
      dashed(shown, ui.theme.gray)
      ui.placed = shown
  of ikBlock:
    if blocks.hasKey(it.name): e.callBlock(it)
    else: e.box(it, it.name)
  of ikBranch:
    let k = e.armShown(it)
    if k >= 0:
      let arm = it.kids[k]
      let o2 = ui.placed
      ui.placed = rect(0, 0, 0, 0)
      arm.drawn = true
      e.drawItems(arm.kids)
      arm.rect = ui.placed
      ui.placed = unionRect(o2, arm.rect)
  of ikBox:
    if it.call != nil and e.design.uiProcs.hasKey(it.name) and e.depth < 4:
      e.drawProc(it, e.design.uiProcs[it.name])
    elif it.node.kind == nkForStmt and it.kids.len > 0:
      e.drawLoop(it)
    else:
      e.box(it, e.design.label(it))
  of ikArm:
    e.drawItems(it.kids)
  of ikCode:
    it.drawn = false
    # (a variable set in the page's code: its cell gets the value)
    if it.node.kind in {nkVarSection, nkLetSection}:
      for def in it.node:
        if def.kind == nkIdentDefs and def.len >= 3 and def[0].kind == nkIdent:
          let k = key(def[0].ident.s)
          if not e.cells.hasKey(k):
            let c = VarCell(name: def[0].ident.s)
            c.setCell(e.initValue(def[^1]))
            e.cells[k] = c
  it.rect = unionRect(before, ui.placed)
  ui.placed = unionRect(outer, it.rect)

proc drawItems*(e: var Eval; items: seq[Item]) =
  for it in items:
    if not e.repeat: it.drawn = false
    e.drawItem(it)

proc clearDrawn(it: Item) =
  for x in it.walk:
    x.drawn = false
    x.rect = rect(0, 0, 0, 0)

proc focusCells(e: var Eval) =
  ## The variables that choose what is shown, set so that the chosen item
  ## is: the tab it is on (`case tab of 2:`), the arm of an `if mode == 1:`.
  if e.focus == nil: return
  var a = e.focus
  while a != nil:
    let p = a.parent
    if a.kind == ikArm and p != nil and p.kind == ikBranch:
      let n = a.node
      let st = p.node
      if n.kind == nkOfBranch and st.kind == nkCaseStmt and st.len > 0 and
         st[0].kind in {nkIdent, nkDotExpr} and n.len > 1:
        let v = e.valueOf(n[0])
        if v.kind in {vkInt, vkStr, vkIdent}: e.cellFor(st[0]).setCell(v)
      elif n.kind in {nkElifBranch, nkElifExpr} and n.len > 0:
        let c = n[0]
        if c.kind == nkIdent and c.ident.s notin ["true", "false"]:
          e.cellFor(c).setCell(Value(kind: vkBool, b: true))
        elif c.kind == nkPrefix and c.len == 2 and c[0].kind == nkIdent and c[0].ident.s == "not" and
             c[1].kind == nkIdent:
          e.cellFor(c[1]).setCell(Value(kind: vkBool, b: false))
        elif c.kind == nkInfix and c.len == 3 and c[0].kind == nkIdent and c[0].ident.s == "==" and
             c[1].kind in {nkIdent, nkDotExpr}:
          let v = e.valueOf(c[2])
          if v.kind in {vkInt, vkStr, vkIdent, vkBool}: e.cellFor(c[1]).setCell(v)
    a = p

proc drawPage*(e: var Eval; pg: Page; r: Rect; live = false) =
  ## The page drawn at `r` as a window of its own, its controls without
  ## input (`live`: with it -- the preview, where they work); every item's
  ## place kept.
  if pg == nil or pg.root == nil: return
  pg.root.clearDrawn()
  e.failed.setLen(0)
  e.overlay = nil
  # (a window's own variables, made before its loop: their starting values)
  for st in pg.setup:
    if st.kind notin {nkVarSection, nkLetSection}: continue
    for def in st:
      if def.kind != nkIdentDefs or def.len < 3 or def[^1].kind == nkEmpty: continue
      for j in 0 ..< def.len - 2:
        if def[j].kind == nkIdent and not e.cells.hasKey(key(def[j].ident.s)):
          let c = VarCell(name: def[j].ident.s)
          c.setCell(e.initValue(def[^1]))
          e.cells[key(def[j].ident.s)] = c
  e.focusCells()
  fill(r, ui.theme.window)
  let wasMeasuring = ui.measuring
  ui.measuring = true
  pushId("retro-designer-page")
  e.live = live
  # (a proc of menu items -- a menu's content kept apart --: drawn as a menu
  #  of a menu bar, open, its title the proc's name)
  var asMenu = false
  if pg.kind == pgProc:
    for it in pg.root.walk:
      if it.kind in {ikControl, ikEvent, ikBlock} and
         it.name in ["menuItem", "menuSeparator", "submenu"]:
        var p = it.parent
        var inMenu = false
        while p != nil:
          if p.kind == ikBlock and p.name in ["menu", "submenu", "popupMenu", "contextMenu",
                                              "menubar"]: inMenu = true
          p = p.parent
        if not inMenu: asMenu = true
  template content() =
    ui.placed = rect(0, 0, 0, 0)
    if asMenu:
      let shown = showMenu([pg.title])
      menubar:
        menu pg.title:
          e.drawItems(pg.root.kids)
      hideMenu(shown)
    else:
      e.drawItems(pg.root.kids)
    pg.root.rect = r
  if live:
    windowBox(r): content()
  else:
    inert:
      windowBox(r): content()
  popId()
  ui.measuring = wasMeasuring

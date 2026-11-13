## Typed calls from a page to the app: `webBind` makes a Nim proc a function
## the app's own pages call -- `retro.call("add", 2, 3)` in their scripts, a
## promise -- with its arguments and its answer as JSON (`std/jsonutils`:
## objects by their fields, enums by their names, `Option` as null). A proc
## that raises rejects the promise with an Error named "CallError". A proc
## that takes a `WebCall` answers by itself, now or later, or streams values
## (`send`, `finish`: the page's `retro.stream`). `webClientTs` writes the
## TypeScript the pages are checked with: every bound proc with its types.
##
## .. code-block:: nim
##   import retroui, retroui/webbind
##   type Note = object
##     title, text: string
##   var notes: seq[Note]
##   proc addNote(n: Note): int =
##     ## Keeps a note; how many there are now.
##     notes.add n
##     notes.len
##   proc listNotes(): seq[Note] = notes
##   webBind addNote
##   webBind listNotes
##   writeFile("web/app.ts", webClientTs())   # (in a build step)
##
##   // in the page (the app's own: its HTML, a file, `webAppUrl`)
##   const n = await retro.call("addNote", {title: "A", text: "..."})
##
## Only the app's own pages may call (and a site `webTrust` names); never a
## frame. Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[json, jsonutils, macros, strutils, options, typetraits]
import htmlview

export json, jsonutils, htmlview.WebCall, htmlview.webHandle

var bound: seq[tuple[name, ts: string]]   # (the client's lines, by name)

const
  FromOpts* = Joptions(allowExtraKeys: true, allowMissingKeys: true)
    ## (how a page's JSON becomes Nim: fields it leaves out keep their zero)
  ToOpts* = ToJsonOptions(enumMode: joptEnumString, jsonNodeMode: joptJsonNodeAsRef)
    ## (enums by their names)

proc argOf*(c: WebCall; i: int): JsonNode =
  ## The page's `i`th argument (nil: not given).
  if c.args != nil and c.args.kind == JArray and i < c.args.len: c.args[i] else: nil

proc noteBound*(name, ts: string) =
  ## (a function in the TypeScript client: `webBind` does it)
  for b in bound.mitems:
    if b.name == name:
      b.ts = ts
      return
  bound.add (name, ts)

proc tsName(n: NimNode): string = ($n).strip(chars = {'`'})

proc tsOf*[T](t: typedesc[T]; depth: static int = 0): string =
  ## A Nim type as TypeScript's, as `std/jsonutils` writes it.
  when depth > 6: "unknown"
  elif T is JsonNode: "unknown"
  elif T is Option: tsOf(typeof(default(T).get), depth + 1) & " | null"
  elif T is string | cstring | char: "string"
  elif T is bool: "boolean"
  elif T is enum:
    var parts: seq[string]
    for x in T: parts.add escapeJson($x)
    parts.join(" | ")
  elif T is SomeNumber: "number"
  elif T is seq | array | set: "Array<" & tsOf(typeof(default(T).items), depth + 1) & ">"
  elif compiles(default(T).pairs) and compiles(default(T).values) and T isnot tuple and
       T isnot object:
    "Record<string, " & tsOf(typeof(default(T).values), depth + 1) & ">"
  elif T is tuple:
    var parts: seq[string]
    when isNamedTuple(T):
      for name, v in fieldPairs(default(T)): parts.add name & ": " & tsOf(typeof(v), depth + 1)
      "{ " & parts.join("; ") & " }"
    else:
      for v in fields(default(T)): parts.add tsOf(typeof(v), depth + 1)
      "[" & parts.join(", ") & "]"
  elif T is object:
    var parts: seq[string]
    for name, v in fieldPairs(default(T)): parts.add name & ": " & tsOf(typeof(v), depth + 1)
    "{ " & parts.join("; ") & " }"
  elif T is ref: tsOf(typeof(default(T)[]), depth + 1) & " | null"
  elif T is distinct: tsOf(distinctBase(T), depth + 1)
  else: "unknown"

macro webBind*(p: typed; name: static string = ""): untyped =
  ## Makes the proc `p` a function the app's pages call (`retro.call`) by
  ## its name (or `name`), and puts it in the TypeScript client
  ## (`webClientTs`). Its parameters come from the page's arguments in
  ## order -- one left out takes its default -- and what it returns is the
  ## answer. A parameter of type `WebCall`: the proc answers by itself.
  let sym = if p.kind in {nnkClosedSymChoice, nnkOpenSymChoice}: p[0] else: p
  if sym.kind != nnkSym: error("webBind wants a proc", p)
  let fname = if name.len > 0: name else: tsName(sym)
  let impl = sym.getImpl
  let typed = sym.getTypeImpl[0]          # (the parameters with their types)
  # (each parameter: its name, its type, its default -- defaults are in the
  # proc's own declaration)
  var ps: seq[tuple[name: string; ty, def: NimNode]]
  for d in typed[1 .. ^1]:
    for k in 0 ..< d.len - 2: ps.add (tsName(d[k]), d[^2], newEmptyNode())
  var at = 0
  for d in impl[3][1 .. ^1]:
    for k in 0 ..< d.len - 2:
      if at < ps.len: ps[at].def = d[^1]
      inc at
  let c = genSym(nskParam, "c")
  var call = newCall(sym)
  var body = newStmtList()
  var line = newLit("")                  # (the arguments' TypeScript: made at run time)
  proc add(e: NimNode) = line = infix(line, "&", e)
  proc docOf(n: NimNode): string =
    ## (the doc comment the body starts with: inside `result = ...` when
    ## the body is an expression)
    case n.kind
    of nnkCommentStmt: n.strVal
    of nnkStmtList, nnkStmtListExpr: (if n.len > 0: docOf(n[0]) else: "")
    of nnkAsgn: docOf(n[1])
    else: ""
  let doc = docOf(impl[6])
  var manual = false
  var jsArgs: seq[string]
  for i, (pn, ty, def) in ps:
    if ty.kind == nnkSym and tsName(ty) == "WebCall":
      manual = true
      call.add c
      continue
    let v = genSym(nskVar, pn)
    let idx = newLit(jsArgs.len)
    let missing = "the argument \"" & pn & "\" is missing"
    let ifMissing =
      if def.kind != nnkEmpty: newAssignment(v, def)
      else: quote do: raise newException(ValueError, `missing`)
    body.add quote do:
      var `v`: `ty`
      block:
        let j = argOf(`c`, `idx`)
        if j == nil: `ifMissing`
        else: fromJson(`v`, j, FromOpts)
    call.add v
    add newLit((if jsArgs.len > 0: ", " else: "") & pn & (if def.kind != nnkEmpty: "?" else: "") & ": ")
    add newCall(bindSym"tsOf", newCall(ident"typeof", ty))
    jsArgs.add pn
  let ret = typed[0]
  let void = ret.kind == nnkEmpty or (ret.kind == nnkSym and tsName(ret) == "void")
  if manual:
    body.add call
  elif void:
    body.add call
    body.add newCall(bindSym"reply", c)
  else:
    body.add newCall(bindSym"reply", c, newCall(bindSym"toJson", call, bindSym"ToOpts"))
  let q = escapeJson(fname)
  if manual:
    line = newLit((if doc.len > 0: "  /** " & doc.replace("*/", "* /").replace("\n", "\n   * ") & " */\n"
                   else: "") &
      "  " & fname & ": (args: unknown[] = [], onValue?: (value: unknown) => void): " &
      "Promise<unknown> =>\n    onValue ? window.retro.stream(" & q & ", args, onValue) : " &
      "window.retro.call(" & q & ", ...args),")
  else:
    let retTs = if void: newLit("null") else: newCall(bindSym"tsOf", newCall(ident"typeof", ret))
    # "  name: (" & args & "): Promise<R> =>\n    window.retro.call(...) as Promise<R>,"
    var head = newLit("  " & fname & ": (")
    if doc.len > 0:
      head = newLit("  /** " & doc.replace("*/", "* /").replace("\n", "\n   * ") & " */\n  " & fname & ": (")
    let args = line
    let rt = genSym(nskLet, "rt")
    let mid = newLit("> =>\n    window.retro.call(" & q &
                     (if jsArgs.len > 0: ", " & jsArgs.join(", ") else: "") & ") as Promise<")
    line = quote do:
      block:
        let `rt` = `retTs`
        `head` & `args` & "): Promise<" & `rt` & `mid` & `rt` & ">,"
  let handler = newProc(params = [newEmptyNode(), newIdentDefs(c, bindSym"WebCall")],
                        body = body, procType = nnkLambda)
  result = newStmtList(
    newCall(bindSym"webHandle", newLit(fname), handler),
    newCall(bindSym"noteBound", newLit(fname), line))

proc webClientTs*(): string =
  ## The TypeScript of the functions the app's pages call (`webBind`), and
  ## of `window.retro`: a module the pages import (`import { app } from
  ## "./app"`; `await app.addNote(note)`).
  result = "// The app's functions for its pages: made by Retro Nim UI (webClientTs).\n" &
    "export interface RetroBridge {\n" &
    "  post(message: string): void;\n" &
    "  call(name: string, ...args: unknown[]): Promise<unknown>;\n" &
    "  stream(name: string, args: unknown[], onValue: (value: unknown) => void): Promise<unknown>;\n" &
    "  on(event: string, f: (value: unknown) => void): () => void;\n" &
    "}\n" &
    "declare global { interface Window { retro: RetroBridge } }\n\n" &
    "/** A function of the app failed: its message, and which one it was. */\n" &
    "export function isCallError(e: unknown): e is Error & { method: string } {\n" &
    "  return e instanceof Error && e.name === \"CallError\";\n}\n\n" &
    "export const app = {\n"
  for b in bound: result.add b.ts & "\n"
  result.add "};\n"

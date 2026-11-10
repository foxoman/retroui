## Retro Designer: the visual designer of Retro Nim UI. It opens an
## ordinary .nim file and shows its windows drawn live with the real
## controls; you drop controls from the Widget Box, drag them, put them in
## rows and groups, change their properties, add the events they run -- and
## the designer writes each change into the same file, touching only what
## changed. No form files, no generated code, no code editor: your editor
## opens at the right line when you want to write code, and the designer
## takes the file back when the editor closes.
##
##   retrokit designer [app.nim]        (it builds the designer once, then runs it)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils, tables, osproc, sequtils, math, algorithm]
import compiler/[ast, idents]
import retroui
import source, registry, values, model, evaluate, lock

const
  SettingsName = "retrodesigner"
  NewFileText = """import retroui

var name = ""

app "Untitled", 480, 320:
  label "&Name:"
  edit name
  row:
    if button("&OK", isDefault = true):
      discard
"""
  RowLike = ["row", "rowPx", "toolbar", "statusRow", "adaptive", "kpiRow", "menubar"]
  Looks = ["Normal", "Touch screen", "Dark", "Right to left"]

type
  Undo = tuple[text: string; line: int]
  Target = object
    ok: bool
    list, owner: PNode
    index: int
    bar: Rect
  DragKind = enum dkNone, dkPress, dkMove

var
  filePath = ""
  src: Src
  design: Design
  ev: Eval
  pageIdx = 0
  sel: seq[Item]
  hoverItem: Item
  undos, redos: seq[Undo]
  dirty = false
  hold: Hold
  readOnly = false                 # another designer has the file
  editorProc: Process
  inEditor = false
  status = "Ready"
  settings: Settings
  # the panes
  leftW = 210
  midW = 600
  treeH = 220
  rightTab = 0
  look = 0
  previewOn = false
  # Widget Box
  boxSearch = ""
  boxSel = ""
  boxOpen: Table[string, bool]
  placing = -1                     # the Widget Box example being placed (-1 none)
  boxPress: tuple[name, title: string; x, y: int]   # (a press on an entry: dragged, it is a drag)
  # Object Tree
  treeLines: seq[string]
  treeItems: seq[Item]
  treeSel = -1
  # Property Editor
  props: seq[Prop]
  propSel = 0
  propMap: seq[tuple[param: int; kind: string]]   # what each property line is
  propsFor: Item
  propsText = ""                    # (the file's text the properties were made for)
  ovParams: seq[Param]
  varProps: seq[Prop]
  varSel = 0
  varsText = ""
  renameTo = ""
  # dialogs
  openDlg, saveDlg, aboutOpen, askSave, settingsOpen: bool
  dlgPath = ""
  afterSave: proc ()
  editorCmd = ""
  # the surface
  pageRect: Rect
  drag: tuple[kind: DragKind; item: Item; x, y: int]
  onSurface = false                # the window being designed was clicked last: its keys
  target: Target
  # what screen readers and drivers know of the page (`accessKeep`)
  namesOn = false                  # View > Names and Tab Order
  pageNodes: seq[AccessNode]       # the page's nodes, as the last frame drew them
  pageStops: seq[uint32]           # ... and its stops of Tab, in order
  nameAsk = false                  # the Name It dialog
  nameText = ""
  nameFor: Item

# ---- the file ----------------------------------------------------------------------------------

proc page(): Page =
  if design == nil or design.pages.len == 0: nil
  else: design.pages[clamp(pageIdx, 0, design.pages.high)]

proc selLine(): int =
  if sel.len > 0: sel[0].line else: -1

proc selectLine(line: int) =
  sel.setLen(0)
  let pg = page()
  if pg == nil or line < 0: return
  let it = pg.itemAtLine(line)
  if it != nil: sel.add it

proc load(s: Src; selLineAfter = -1) =
  src = s
  design = readDesign(src)
  let cells = ev.cells
  ev = initEval(design)
  # (the values the designer was showing stay: a tab chosen, a check ticked)
  for k, c in cells:
    if not ev.cells.hasKey(k): ev.cells[k] = c
  if design.pages.len > 0: pageIdx = clamp(pageIdx, 0, design.pages.high)
  propsText = ""
  varsText = ""
  selectLine(selLineAfter)

proc firstDiffLine(a, b: string): int =
  let la = a.split('\n')
  let lb = b.split('\n')
  for i in 0 ..< min(la.len, lb.len):
    if la[i] != lb[i]: return i + 1
  min(la.len, lb.len) + 1

proc change(newText: string; line = -2) =
  ## The file changed by the designer: read again, kept if it parses.
  if readOnly or inEditor:
    status = "The file is not the designer's now"
    return
  let s2 = parseSrc(newText)
  if not s2.ok:
    status = "Not done: the file would not read (line " & $s2.errors[0].line & ": " &
             s2.errors[0].msg & ")"
    return
  undos.add (src.text, selLine())
  if undos.len > 200: undos.delete(0)
  redos.setLen(0)
  let l = if line == -2: firstDiffLine(src.text, newText) else: line
  load(s2, l)
  dirty = true

proc tryChange(f: proc (): string; line = -2) =
  try: change(f(), line)
  except DesignError as e: status = "Not done: " & e.msg

proc noteRecent(path: string) =
  var r = settings.getOrDefault("recent").split('\t').filterIt(it.len > 0 and it != path)
  r.insert(path, 0)
  if r.len > 8: r.setLen(8)
  settings["recent"] = r.join("\t")
  discard saveSettings(SettingsName, settings)

proc openFile(path: string) =
  ## `path` read and shown; the designer holds it (if no other designer does).
  let full = path.absolutePath
  var text: string
  try: text = readFile(full)
  except IOError as e:
    status = "Cannot read " & full & ": " & e.msg
    return
  hold.release()
  filePath = full
  hold = take(full)
  readOnly = not hold.held and hold.by.len > 0
  undos.setLen(0)
  redos.setLen(0)
  dirty = false
  pageIdx = 0
  load(parseSrc(text))
  if not src.ok:
    status = "The file does not read (line " & $src.errors[0].line & "): " & src.errors[0].msg
  elif readOnly:
    status = hold.by & " has this file: shown, not changed"
  else:
    status = $design.pages.len & " page" & (if design.pages.len == 1: "" else: "s") & " in " &
             full.extractFilename
  noteRecent(full)
  setTitle(full.extractFilename & " - Retro Designer")

proc newFile() =
  hold.release()
  filePath = ""
  readOnly = false
  undos.setLen(0)
  redos.setLen(0)
  dirty = true
  pageIdx = 0
  load(parseSrc(NewFileText))
  setTitle("Untitled - Retro Designer")
  status = "A new window: drop controls on it, then save it"

proc writeFileNow(path: string): bool =
  try:
    if hold.held and hold.path == path: hold.writeHeld(src.text)
    else: writeFile(path, src.text)
    dirty = false
    status = "Saved " & path.extractFilename
    true
  except CatchableError as e:
    status = "Not saved: " & e.msg
    false

proc save(then: proc () = nil) =
  if filePath.len == 0:
    dlgPath = "app.nim"
    saveDlg = true
    afterSave = then
    return
  if writeFileNow(filePath) and then != nil: then()

proc saveAs(path: string) =
  let full = path.absolutePath
  hold.release()
  filePath = full
  if not writeFileNow(full): return
  hold = take(full)
  readOnly = false
  noteRecent(full)
  setTitle(full.extractFilename & " - Retro Designer")
  if afterSave != nil:
    let f = afterSave
    afterSave = nil
    f()

proc whenSaved(f: proc ()) =
  ## `f` after the changes are saved (or asked about).
  if dirty and src.text.len > 0:
    afterSave = f
    askSave = true
  else: f()

# ---- the editor ---------------------------------------------------------------------------------

proc editCode(line: int) =
  ## The file given to your editor at `line`; the designer waits for it.
  if filePath.len == 0:
    save(proc () = editCode(line))
    return
  if dirty and not writeFileNow(filePath): return
  let cmd = if editorCmd.len > 0: editorCmd else: defaultEditor()
  hold.release()
  editorProc = startEditor(cmd, filePath, line)
  if editorProc == nil:
    hold = take(filePath)
    status = "The editor did not start: " & cmd & " (Edit > Settings)"
    return
  inEditor = true
  status = "In your editor -- close it there to design again"

proc takeBack() =
  ## The file back from the editor: held again and read again.
  if editorProc != nil:
    editorProc.close()
    editorProc = nil
  inEditor = false
  hold = take(filePath)
  readOnly = not hold.held and hold.by.len > 0
  let keep = selLine()
  try:
    let s2 = parseSrc(readFile(filePath))
    if s2.text != src.text:
      undos.add (src.text, keep)
      redos.setLen(0)
    load(s2, keep)
    dirty = false
    status = if src.ok: "Back from the editor" else:
             "Back from the editor; the file does not read (line " & $src.errors[0].line & ")"
  except IOError as e:
    status = "Cannot read the file: " & e.msg

proc watchEditor() =
  if inEditor and editorProc != nil and not editorProc.running: takeBack()

# ---- items and the Widget Box ------------------------------------------------------------------

proc parentList(it: Item): tuple[list, owner: PNode] =
  ## The body an item is in, and its owner.
  if it.parent == nil: return (nil, nil)
  let p = it.parent
  if p.kind == ikBlock:
    for b in p.bodies:
      if it in b:
        let k = p.bodies.find(b)
        var bs: seq[PNode]
        for i in 1 ..< p.call.len:
          if p.call[i].kind == nkStmtList: bs.add p.call[i]
          elif p.call[i].kind == nkDo and p.call[i].len > 0: bs.add p.call[i][^1]
        if k < bs.len: return (bs[k], p.call)
    return (p.body, p.call)
  if p.kind == ikArm: return (p.body, p.node)
  (it.list, it.owner)

proc renameIn(code: string; old, new: string): string =
  ## Name `old` made `new` in `code` (names only: not in strings, not a
  ## field after a dot, not an argument's or a field's label -- `f(old = 1)`,
  ## `T(old: 1)`).
  var k = 0
  var depth = 0
  while k < code.len:
    let c = code[k]
    if c in {'a'..'z', 'A'..'Z', '_'}:
      let e = tokenEnd(code, k)
      let word = code[k ..< e]
      var p = k - 1
      while p >= 0 and code[p] == ' ': dec p
      var n = e
      while n < code.len and code[n] == ' ': inc n
      let field = p >= 0 and code[p] == '.'
      let labelled = depth > 0 and n < code.len and
                     (code[n] == ':' or (code[n] == '=' and (n + 1 >= code.len or code[n + 1] != '=')))
      if word == old and not field and not labelled: result.add new else: result.add word
      k = e
    elif c in {'(', '[', '{'}:
      inc depth
      result.add c
      inc k
    elif c in {')', ']', '}'}:
      depth = max(0, depth - 1)
      result.add c
      inc k
    elif c == '"' or c == '\'' or c == '#':
      let e = if c == '#': skipTrivia(code, k, false) else: tokenEnd(code, k)
      result.add code[k ..< max(e, k + 1)]
      k = max(e, k + 1)
    else:
      result.add c
      inc k

proc declsAt(): int =
  ## The line where new variables go: after the last top-level `var`, `let`
  ## or `const` before the first page, else after the imports.
  var line = 1
  let firstPage = if design.pages.len > 0: src.lineOfNode(design.pages[0].node) else: high(int)
  for st in src.tree:
    let l = src.lineOfNode(st)
    if l >= firstPage: break
    if st.kind in {nkVarSection, nkLetSection, nkConstSection, nkImportStmt, nkFromStmt,
                   nkIncludeStmt}:
      line = src.stmtLines(st, false).last + 1
  line

proc exampleCode(ex: Example): tuple[code, decls: string] =
  ## The example's code with its variables -- its own, and those its code
  ## makes (`let r = place(...)`) -- named so that they are new here.
  var code = ex.code
  var decls = ex.decls
  var taken: seq[string]
  for part in [decls, code]:
    if part.len == 0: continue
    let ds = parseSrc(part)
    for st in ds.tree:
      if st.kind notin {nkVarSection, nkLetSection, nkConstSection}: continue
      for def in st:
        if def.len == 0: continue
        var nm = def[0]
        if nm.kind == nkPragmaExpr: nm = nm[0]
        if nm.kind == nkPostfix: nm = nm[1]
        if nm.kind != nkIdent: continue
        let old = nm.ident.s
        let fresh = src.freeName(old, taken)
        taken.add fresh
        if fresh != old:
          code = renameIn(code, old, fresh)
          decls = renameIn(decls, old, fresh)
  (code, decls)

proc withImports(text: string; mods: seq[string]): tuple[text: string; added: int] =
  ## `text` importing `mods` too (each one it does not import yet, after
  ## its last import).
  result.text = text
  for m in mods:
    let s2 = parseSrc(result.text)
    if not s2.ok: return
    var has = false
    var after = 1
    let leaf = m.split('/')[^1]
    for st in s2.tree:
      if st.kind in {nkImportStmt, nkFromStmt}:
        after = s2.stmtLines(st, false).last + 1
        # (`import os`, `import std/os`, `import std/[os, strutils]`)
        for w in s2.textOf(st).split({' ', ',', '[', ']', '/', '\n', '\t'}):
          if w == leaf: has = true
    if not has:
      result.text = s2.insertLinesAt(after, "import " & m)
      inc result.added

proc insertExample(ex: Example; t: Target) =
  ## The example put at the target, its variables with the file's, the
  ## modules it needs imported.
  if not t.ok: return
  let (code, decls) = exampleCode(ex)
  var text: string
  try:
    text = src.insertAt(t.list, t.owner, t.index, code)
  except DesignError as e:
    status = "Not done: " & e.msg
    return
  var line = -2
  if decls.strip.len > 0:
    let s2 = parseSrc(text)
    if not s2.ok:
      status = "Not done: the example would not read here"
      return
    let at = block:
      let d2 = readDesign(s2)
      var l = 1
      let firstPage = if d2.pages.len > 0: s2.lineOfNode(d2.pages[0].node) else: high(int)
      for st in s2.tree:
        let ln = s2.lineOfNode(st)
        if ln >= firstPage: break
        if st.kind in {nkVarSection, nkLetSection, nkConstSection, nkImportStmt, nkFromStmt,
                       nkIncludeStmt}:
          l = s2.stmtLines(st, false).last + 1
      l
    text = s2.insertLinesAt(at, decls)
    line = firstDiffLine(s2.text, text) + decls.strip.count('\n') + 1
    let shift = decls.strip.count('\n') + 1
    let first = firstDiffLine(src.text, s2.text)
    line = if first >= at: first + shift else: first
  if ex.imports.len > 0:
    let (t2, added) = withImports(text, ex.imports)
    if added > 0:
      if line == -2: line = firstDiffLine(src.text, text)
      text = t2
      line += added
  change(text, line)
  status = "Added " & ex.title

proc horizontal(it: Item): bool = it != nil and it.kind == ikBlock and it.name in RowLike

proc containerOf(it: Item): bool =
  it.kind == ikArm or (it.kind == ikBlock and it.bodies.len > 0)

proc bodyItems(it: Item; k = 0): seq[Item] =
  if it.kind == ikBlock:
    (if k < it.bodies.len: it.bodies[k] else: @[])
  else: it.kids

proc bodyNode(it: Item; k = 0): tuple[list, owner: PNode] =
  if it.kind == ikArm: return (it.body, it.node)
  var bs: seq[PNode]
  for i in 1 ..< it.call.len:
    if it.call[i].kind == nkStmtList: bs.add it.call[i]
    elif it.call[i].kind == nkDo and it.call[i].len > 0: bs.add it.call[i][^1]
  if k < bs.len: (bs[k], it.call) else: (it.body, it.call)

proc area(r: Rect): int = max(0, r.w) * max(0, r.h)

proc onOverlay(x, y: int): Item =
  ## The dialog or menu shown over the page, when the point is on it.
  let ov = ev.overlay
  if ov != nil and ov.drawn and ov.rect.contains(point(x, y)): ov else: nil

proc itemAt(x, y: int): Item =
  ## The innermost item drawn at a point (on a dialog or menu shown over
  ## the page: one of its items).
  let pg = page()
  if pg == nil: return nil
  let ov = onOverlay(x, y)
  var best: Item = nil
  for it in pg.root.walk:
    if it == pg.root or not it.drawn or it.kind in {ikCode, ikArm, ikBranch}: continue
    if it.rect.w <= 0 or not it.rect.contains(point(x, y)): continue
    if ov != nil and not it.inside(ov): continue
    if best == nil or it.rect.area <= best.rect.area: best = it
  best

proc targetAt(x, y: int; moving: Item = nil): Target =
  ## Where a control dropped at a point goes: the container under it, the
  ## place among what is in it.
  let pg = page()
  if pg == nil: return
  var cont = pg.root
  var bodyK = 0
  let ov = onOverlay(x, y)
  for it in pg.root.walk:
    if it == pg.root or not it.drawn or not it.containerOf: continue
    if ov != nil and not it.inside(ov): continue
    if moving != nil:
      var inside = false
      var p = it
      while p != nil:
        if p == moving: inside = true
        p = p.parent
      if inside: continue
    if it.rect.w <= 0 or not it.rect.contains(point(x, y)): continue
    if cont == pg.root or it.rect.area <= cont.rect.area: cont = it
  # (a block with two bodies: the side the pointer is on)
  if cont.kind == ikBlock and cont.bodies.len > 1:
    var bestD = high(int)
    for k, b in cont.bodies:
      var u = rect(0, 0, 0, 0)
      for it in b:
        if it.drawn and it.rect.w > 0:
          u = if u.w == 0: it.rect else: rect(min(u.x, it.rect.x), min(u.y, it.rect.y),
              max(u.x + u.w, it.rect.x + it.rect.w) - min(u.x, it.rect.x),
              max(u.y + u.h, it.rect.y + it.rect.h) - min(u.y, it.rect.y))
      let cx = u.x + u.w div 2
      let d = if u.w == 0: high(int) - 1 else: abs(x - cx)
      if d < bestD:
        bestD = d
        bodyK = k
  let (list, owner) = if cont == pg.root: (pg.body, pg.node) else: cont.bodyNode(bodyK)
  if list == nil: return
  let kids = (if cont == pg.root: pg.root.kids else: cont.bodyItems(bodyK)).filterIt(
    it.drawn and it.rect.w > 0 and it.kind != ikCode)
  let stmtsOf = list.stmts
  let hor = cont.horizontal
  var idx = kids.len
  for i, k in kids:
    let before = if hor: x < k.rect.x + k.rect.w div 2 else: y < k.rect.y + k.rect.h div 2
    if before:
      idx = i
      break
  result.ok = true
  result.list = list
  result.owner = owner
  # (the place among the statements: before the kid, else after the last)
  if idx < kids.len:
    result.index = max(0, stmtsOf.find(kids[idx].node))
  elif kids.len > 0:
    result.index = stmtsOf.find(kids[^1].node) + 1
  else:
    result.index = stmtsOf.len
  # where the line is drawn
  let c = if cont == pg.root: pageRect else: cont.rect
  if kids.len == 0:
    result.bar = rect(c.x + 2, c.y + 2, max(4, c.w - 4), 2)
  elif hor:
    let r = if idx < kids.len: kids[idx].rect else: kids[^1].rect
    let bx = if idx < kids.len: r.x - 2 else: r.x + r.w + 1
    result.bar = rect(bx, r.y, 2, max(4, r.h))
  else:
    let r = if idx < kids.len: kids[idx].rect else: kids[^1].rect
    let by = if idx < kids.len: r.y - 2 else: r.y + r.h + 1
    result.bar = rect(c.x + 2, by, max(4, c.w - 4), 2)

# ---- the commands -----------------------------------------------------------------------------

proc deleteSel() =
  if sel.len == 0: return
  let it = sel[0]
  if it == page().root: return
  let (list, _) = it.parentList
  let line = it.line
  tryChange(proc (): string = src.deleteStmt(it.node, list), line)
  status = "Deleted"

proc copySel(): string =
  if sel.len == 0: return ""
  try:
    var t = ""
    for it in sel: t.add src.stmtText(it.node)
    t
  except DesignError: ""

proc pasteCode(code: string) =
  if code.strip.len == 0: return
  let check = parseSrc(code)
  if not check.ok:
    status = "The clipboard holds no code to paste"
    return
  let pg = page()
  if pg == nil: return
  var t: Target
  if sel.len > 0 and sel[0] != pg.root:
    let it = sel[^1]
    let (list, owner) = it.parentList
    t = Target(ok: true, list: list, owner: owner, index: list.stmts.find(it.node) + 1)
  else:
    t = Target(ok: true, list: pg.body, owner: pg.node, index: pg.body.stmts.len)
  tryChange(proc (): string = src.insertAt(t.list, t.owner, t.index, code))

proc moveBy(d: int) =
  ## The selection one place up (-1) or down (+1) among its neighbours.
  if sel.len == 0: return
  let it = sel[0]
  let (list, owner) = it.parentList
  if list == nil: return
  let ss = list.stmts
  let i = ss.find(it.node)
  if i < 0: return
  let j = i + d
  if j < 0 or j >= ss.len:
    status = "It is at the " & (if d < 0: "top" else: "bottom") & " already"
    return
  let to = if d < 0: j else: j + 1
  try:
    let t = src.moveStmt(it.node, list, list, owner, to)
    # (the line it goes to: where the neighbour was, or after it)
    let other = src.stmtLines(ss[j])
    let mine = src.stmtLines(it.node)
    let n = mine.last - mine.first + 1
    let nl = if d < 0: other.first + (it.line - mine.first)
             else: other.last - n + 1 + (it.line - mine.first)
    change(t, nl)
  except DesignError as e: status = "Not done: " & e.msg

proc wrapSel(header: string) =
  if sel.len == 0: return
  let (list, _) = sel[0].parentList
  if list == nil: return
  let ss = list.stmts
  var idx: seq[int]
  for it in sel:
    let (l2, _) = it.parentList
    if l2 != list:
      status = "Choose controls side by side in one place"
      return
    idx.add ss.find(it.node)
  idx.sort()
  for k in 1 ..< idx.len:
    if idx[k] != idx[k - 1] + 1:
      status = "Choose controls that follow each other"
      return
  var nodes: seq[PNode]
  for k in idx: nodes.add ss[k]
  let first = src.stmtLines(nodes[0]).first
  tryChange(proc (): string = src.wrapStmts(nodes, header), first)

proc unwrapSel() =
  if sel.len == 0 or not sel[0].containerOf or sel[0].kind == ikArm:
    status = "Choose a row, a column or a group to take its controls out"
    return
  let it = sel[0]
  tryChange(proc (): string = src.unwrap(it.node), it.line)

proc returnsBool(it: Item): bool =
  if it == nil or not controls.hasKey(it.name): return false
  for ov in controls[it.name].overloads:
    if ov.returns == "bool": return true

proc eventName(name: string): string =
  case name
  of "button", "toolButton", "menuItem", "linkButton", "buttonAt", "iconButton", "link",
     "leaf", "picButton": "Clicked"
  of "checkbox", "radio", "toggle", "switch", "edit", "editArea", "combo", "comboEdit",
     "listbox", "slider", "spin", "intEdit", "numberEdit", "datePicker", "maskedEdit",
     "colorPicker", "segmented": "Changed"
  else: "Chosen"

proc eventCode(it: Item) =
  ## The selected control's event: made if it has none, then your editor
  ## at its code.
  if it == nil: return
  if it.kind == ikEvent:
    let body = it.body
    let l = if body != nil and body.stmts.len > 0: src.lineOfNode(body.stmts[0]) else: it.line
    editCode(l)
    return
  if it.kind != ikControl or not it.returnsBool:
    status = "This control has no event to add"
    return
  let line = it.line
  try:
    change(src.makeEvent(it.node, it.call), line)
    status = "Added the " & eventName(it.name) & " event: Edit Code to write what it does"
  except DesignError as e: status = "Not done: " & e.msg

proc doUndo() =
  if undos.len == 0 or inEditor or readOnly: return
  let u = undos.pop()
  redos.add (src.text, selLine())
  load(parseSrc(u.text), u.line)
  dirty = true

proc doRedo() =
  if redos.len == 0 or inEditor or readOnly: return
  let r = redos.pop()
  undos.add (src.text, selLine())
  load(parseSrc(r.text), r.line)
  dirty = true

# ---- the properties -----------------------------------------------------------------------------

proc literalText(n: PNode): tuple[lit: bool; text: string] =
  ## An argument as the inspector shows it: a value written out, else its code.
  if n == nil: return (true, "")
  case n.kind
  of nkStrLit, nkRStrLit, nkTripleStrLit: (true, n.strVal)
  of nkIntLit .. nkUInt64Lit: (true, $n.intVal)
  of nkFloatLit .. nkFloat128Lit: (true, $n.floatVal)
  of nkIdent: (true, n.ident.s)
  of nkPrefix:
    if n.len == 2 and n[0].kind == nkIdent and n[0].ident.s == "-" and
       n[1].kind in {nkIntLit .. nkFloat128Lit}:
      (true, "-" & src.textOf(n[1]))
    else: (false, src.textOf(n))
  of nkBracket:
    var parts: seq[string]
    for c in n:
      if c.kind in {nkStrLit, nkRStrLit, nkTripleStrLit}: parts.add c.strVal
      elif c.kind in {nkIntLit .. nkUInt64Lit}: parts.add $c.intVal
      else: return (false, src.textOf(n))
    (true, parts.join(", "))
  of nkCurly:
    var parts: seq[string]
    for c in n: parts.add src.textOf(c)
    (true, parts.join(", "))
  else: (false, src.textOf(n))

proc chosenOverload(it: Item): seq[Param] =
  if it.kind == ikBlock and blocks.hasKey(it.name):
    var best = -1
    var bestScore = low(int)
    for i, b in blocks[it.name]:
      let (ok, _, score) = ev.argsFor(it.call, b.params)
      if ok and score > bestScore:
        best = i
        bestScore = score
    if best >= 0: return blocks[it.name][best].params
  elif controls.hasKey(it.name):
    var best = -1
    var bestScore = low(int)
    for i, ov in controls[it.name].overloads:
      let (ok, _, score) = ev.argsFor(it.call, ov.params)
      if ok and score > bestScore:
        best = i
        bestScore = score
    if best >= 0: return controls[it.name].overloads[best].params

proc argNode(it: Item; params: seq[Param]; i: int): PNode =
  let named = it.call.namedArg(params[i].name)
  if named != nil: return named
  # (positional: the i-th one that is not named)
  let pos = it.call.positional
  if i < pos.len: return pos[i]
  nil

proc buildProps(it: Item) =
  props.setLen(0)
  propMap.setLen(0)
  ovParams = @[]
  propsFor = it
  propsText = src.text
  if it == nil or it.call == nil: return
  let params = it.chosenOverload
  ovParams = params
  let cat = it.name
  let doc = (if controls.hasKey(it.name): controls[it.name].doc
             elif blocks.hasKey(it.name) and blocks[it.name].len > 0: blocks[it.name][0].doc
             else: "")
  for i, p in params:
    let a = it.argNode(params, i)
    let valNode = if a != nil and a.kind == nkExprEqExpr: a[1] else: a
    let (lit, txt) = literalText(valNode)
    let given = valNode != nil
    let shown = if not given: p.default.strip(chars = {'"'}) elif lit: txt else: "= " & txt
    let help = p.name & ": " & (if p.typ.len > 0: p.typ else: "?") &
               (if p.default.len > 0: " = " & p.default else: "") &
               (if not given: " (not set)" else: "") &
               (if i == 0 and doc.len > 0: " -- " & doc else: "")
    let nm = (if given: "" else: "  ") & p.name
    var pr: Prop
    case p.kind
    of kBool:
      if lit or not given: pr = boolProp(nm, shown == "true", cat, help)
      else: pr = textProp(nm, shown, cat, help)
    of kInt:
      if lit or not given:
        var n = 0
        try: n = parseInt(shown) except ValueError: discard
        pr = intProp(nm, n, cat, help)
      else: pr = textProp(nm, shown, cat, help)
    of kFloat:
      if lit or not given:
        var f = 0.0
        try: f = parseFloat(shown) except ValueError: discard
        pr = numberProp(nm, f, 2, cat, help)
      else: pr = textProp(nm, shown, cat, help)
    of kEnum:
      let vals = enumValues.getOrDefault(p.typ)
      let k = vals.find(shown)
      if vals.len > 0 and (k >= 0 or not given): pr = choiceProp(nm, vals, max(0, k), cat, help)
      else: pr = textProp(nm, shown, cat, help)
    of kNone:
      pr = infoProp(nm, (if given: shown else: "(" & p.typ & ")"), cat, help)
    of kStr:
      # (one of the kit's pictures or symbols by name -- pxOpen, nfSave --:
      #  chosen among the others of its kind)
      if given and valNode.kind == nkIdent and stringConsts.hasKey(txt) and txt.len > 2:
        var vals: seq[string]
        for k in stringConsts.keys:
          if k.len > 2 and k[0 .. 1] == txt[0 .. 1] and k[2] in {'A'..'Z'}: vals.add k
        vals.sort()
        pr = choiceProp(nm, vals, max(0, vals.find(txt)), cat, help)
      else: pr = textProp(nm, shown, cat, help)
    else:
      pr = textProp(nm, shown, cat, help)
    props.add pr
    propMap.add (i, $p.kind)
  # the variable a control changes, and where it starts
  for i, p in params:
    if p.kind in {kVStr, kVInt, kVFloat, kVBool, kVStrs, kVInts}:
      let a = it.argNode(params, i)
      let v = if a != nil and a.kind == nkExprEqExpr: a[1] else: a
      if v != nil and v.kind == nkIdent:
        let vi = design.varOf(v.ident.s)
        if vi >= 0:
          props.add textProp(design.vars[vi].name & " starts as", design.vars[vi].init,
                             "Variable", "The value the variable has when the app starts (its var line)")
          propMap.add (-1 - vi, "var")
  props.add infoProp("Line", $it.line, "Code", "Where it is in the file")
  propMap.add (-1000, "")
  if it.kind == ikEvent:
    props.add infoProp("Event", eventName(it.name) & ": code under it", "Code",
                       "Edit Code (Enter) opens your editor there")
    propMap.add (-1000, "")

proc valueFor(p: Param; pr: Prop): tuple[ok: bool; code: string] =
  ## The Nim text for what was typed or chosen in the property.
  if pr.kind == pkText:
    let t = pr.text
    if t.startsWith("= "): return (true, t[2 .. ^1])
    case p.kind
    of kStr: return (true, nimLit(t))
    of kStrs:
      var parts: seq[string]
      for x in t.split(','):
        if x.strip.len > 0: parts.add nimLit(x.strip)
      return (true, "[" & parts.join(", ") & "]")
    of kInts, kFloats: return (true, "[" & t & "]")
    of kSet: return (true, "{" & t & "}")
    of kVStr, kVInt, kVFloat, kVBool, kVStrs, kVInts:
      let nm = t.strip
      if nm.len == 0 or nm[0] notin {'a'..'z', 'A'..'Z', '_'} or
         not nm.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '_', '.', '[', ']'}):
        return (false, "")
      return (true, nm)
    of kColor, kRect, kEnum, kInt, kFloat, kBool: return (true, t)
    else: return (true, t)
  case pr.kind
  of pkBool: (true, $pr.on)
  of pkInt: (true, $pr.n)
  of pkNumber: (true, formatFloat(pr.num, ffDecimal, pr.decimals))
  of pkChoice: (true, pr.choices[clamp(pr.n, 0, pr.choices.high)])
  of pkColor: (true, "color(" & $pr.color.r & ", " & $pr.color.g & ", " & $pr.color.b & ")")
  else: (false, "")

proc ensureVar(name: string; p: Param): string =
  ## The text with `var name = ...` added when the file has no such name.
  if design.varOf(name) >= 0 or '.' in name or '[' in name: return src.text
  let init = case p.kind
             of kVStr: "\"\""
             of kVInt: "0"
             of kVFloat: "0.0"
             of kVBool: "false"
             of kVStrs: "newSeq[string]()"
             of kVInts: "newSeq[int]()"
             else: "0"
  src.insertLinesAt(declsAt(), "var " & name & " = " & init)

proc propChanged(k: int) =
  let it = propsFor
  if it == nil or k < 0 or k >= propMap.len: return
  let (pi, _) = propMap[k]
  if pi <= -1000: return
  if pi < 0:
    # a variable's starting value
    let vi = -1 - pi
    if vi >= design.vars.len: return
    let v = design.vars[vi]
    let init = v.node[^1]
    let t = props[k].text
    tryChange(proc (): string = apply(src.text, [(src.startOff(init), src.endOff(init), t)]), it.line)
    return
  let p = ovParams[pi]
  let (ok, code) = valueFor(p, props[k])
  if not ok:
    status = "Not a name: " & props[k].text
    return
  let line = it.line
  if p.kind in {kVStr, kVInt, kVFloat, kVBool, kVStrs, kVInts}:
    # (the variable named: made when the file has none)
    try:
      let t1 = src.setArg(it.call, pi, p.name, code, it.argNode(ovParams, pi))
      let s1 = parseSrc(t1)
      let d1 = readDesign(s1)
      if d1.varOf(code) < 0 and '.' notin code and '[' notin code:
        let oldSrc = src
        let oldDesign = design
        src = s1
        design = d1
        let t2 = ensureVar(code, p)
        src = oldSrc
        design = oldDesign
        change(t2, line + 1)
      else: change(t1, line)
    except DesignError as e: status = "Not done: " & e.msg
    return
  # (back to the default: the argument taken out, when it is named or last)
  let a = it.argNode(ovParams, pi)
  if a != nil and p.default.len > 0 and code == p.default:
    let pos = it.call.positional
    if a.kind == nkExprEqExpr or (pos.len > 0 and pos[^1] == a and it.call.args[^1] == a):
      tryChange(proc (): string = src.removeArg(it.call, a), line)
      return
  tryChange(proc (): string = src.setArg(it.call, pi, p.name, code, a), line)

proc resetProp(k: int) =
  let it = propsFor
  if it == nil or k < 0 or k >= propMap.len: return
  let (pi, _) = propMap[k]
  if pi < 0: return
  let a = it.argNode(ovParams, pi)
  if a == nil:
    status = "It is not set"
    return
  let p = ovParams[pi]
  let pos = it.call.positional
  if p.default.len == 0:
    status = p.name & " has no default: it must be given"
    return
  if a.kind != nkExprEqExpr and not (pos.len > 0 and pos[^1] == a and it.call.args[^1] == a):
    tryChange(proc (): string = src.setArg(it.call, pi, p.name, p.default, a), it.line)
    return
  tryChange(proc (): string = src.removeArg(it.call, a), it.line)

proc buildVarProps() =
  varProps.setLen(0)
  varsText = src.text
  for v in design.vars:
    if v.init.len == 0: continue
    let kind = if v.isConst: "const" elif v.isLet: "let" else: "var"
    varProps.add textProp(v.name, v.init, kind,
                          kind & " " & v.name & (if v.typ.len > 0: ": " & v.typ else: "") &
                          " (line " & $v.line & ") -- the value it starts with")

# ---- the Object Tree ---------------------------------------------------------------------------

proc buildTree() =
  treeLines.setLen(0)
  treeItems.setLen(0)
  let pg = page()
  if pg == nil: return
  proc add(it: Item; depth: int) =
    if it.kind == ikCode: return
    let mark = case it.kind
               of ikEvent: "* "
               of ikBox: "~ "
               of ikArm: (if it.parent != nil and ev.armShown(it.parent) >= 0 and
                              it.parent.kids[ev.armShown(it.parent)] == it: "> " else: "  ")
               else: ""
    treeLines.add repeat("    ", depth) & mark & design.label(it)
    treeItems.add it
    if it.kind == ikBlock and it.bodies.len > 1:
      for k, b in it.bodies:
        treeLines.add repeat("    ", depth + 1) & (if k == 0: "(first side)" else: "(second side)")
        treeItems.add it
        for x in b: add(x, depth + 2)
    else:
      for x in it.kids: add(x, depth + 1)
  treeLines.add pg.title & "  (" & $pg.kind & ")"
  treeItems.add pg.root
  for x in pg.root.kids: add(x, 1)

# ---- drawing the surface ------------------------------------------------------------------------

proc applyLook(k: int; body: proc ()) =
  ## The page drawn in a look of its own (only the page).
  let theme = ui.theme
  let sizes = ui.sizes
  let rtl = ui.rtl
  case k
  of 1: ui.sizes = csTouch
  of 2:
    for t in builtinThemes:
      if t.name == "Dark": ui.theme = t.theme
  of 3: ui.rtl = true
  else: discard
  try: body()
  finally:
    ui.theme = theme
    ui.sizes = sizes
    ui.rtl = rtl

proc frameAround(r: Rect; title: string) =
  ## A 3.1 window frame round the page, its title bar.
  let th = ui.theme
  let tb = rect(r.x, r.y - dp(20), r.w, dp(20))
  fill(rect(r.x - 4, tb.y - 4, r.w + 8, r.h + tb.h + 8), th.face)
  fill(rect(r.x - 5, tb.y - 5, r.w + 10, 1), th.frame)
  fill(rect(r.x - 5, r.y + r.h + 4, r.w + 10, 1), th.frame)
  fill(rect(r.x - 5, tb.y - 5, 1, r.h + tb.h + 10), th.frame)
  fill(rect(r.x + r.w + 4, tb.y - 5, 1, r.h + tb.h + 10), th.frame)
  fill(tb, th.select)
  let tw = textWidth(title)
  text(tb.x + (tb.w - tw) div 2, tb.y + (tb.h - FontH) div 2, title, th.selectText)
  # the size grip (drag it: the page's size)
  let g = rect(r.x + r.w - dp(10), r.y + r.h - dp(10), dp(10), dp(10))
  for k in 1 .. 3:
    let o = k * dp(3)
    line(g.x + g.w - o, g.y + g.h - 1, g.x + g.w - 1, g.y + g.h - o, th.shadow)

proc outlineRect(r: Rect; c: Color; t = 1) =
  fill(rect(r.x - t, r.y - t, r.w + 2 * t, t), c)
  fill(rect(r.x - t, r.y + r.h, r.w + 2 * t, t), c)
  fill(rect(r.x - t, r.y, t, r.h), c)
  fill(rect(r.x + r.w, r.y, t, r.h), c)

var sizing: tuple[on: bool; w0, h0, x0, y0: int]

proc writeSize(pg: Page; w, h: int) =
  if pg.sizeCall == nil: return
  let ints = block:
    var xs: seq[PNode]
    for a in pg.sizeCall.args:
      let x = if a.kind == nkExprEqExpr: a[1] else: a
      if x.kind in {nkIntLit .. nkUInt64Lit}: xs.add x
    xs
  if ints.len < 2: return
  let line = -1
  change(apply(src.text, [(src.startOff(ints[0]), src.endOff(ints[0]), $w),
                          (src.startOff(ints[1]), src.endOff(ints[1]), $h)]), line)

const Unnamed = {arButton, arToggleButton, arCheckBox, arRadioButton, arTextField, arTextArea,
                 arPasswordField, arComboBox, arList, arSlider, arSpinButton, arLink, arTable, arTree}
  ## (the roles a screen reader must be told the name of)

proc nodeRect(n: AccessNode): Rect =
  ## (a node's place on the designer's window: the reader's device pixels
  ## back to the designer's, a right-to-left look mirrored back)
  let z = max(1, zoom)
  result = rect(n.x div z, n.y div z, n.w div z, n.h div z)
  if look == 3: result.x = ui.w - result.x - result.w

proc nodeOf(it: Item): int =
  ## The page's node of control `it` (-1 none): the biggest one inside it
  ## that is a control, else the biggest one.
  result = -1
  if it == nil or not it.drawn or it.rect.w <= 0: return
  let outer = rect(it.rect.x - 2, it.rect.y - 2, it.rect.w + 4, it.rect.h + 4)
  var best = -1
  var bestControl = false
  for i, n in pageNodes:
    if n.role in {arWindow, arPane, arGroup}: continue
    let r = nodeRect(n)
    if r.w <= 0 or r.h <= 0 or not outer.contains(point(r.x, r.y)) or
       not outer.contains(point(r.x + r.w - 1, r.y + r.h - 1)): continue
    let control = n.role in Unnamed
    if best < 0 or (control and not bestControl) or
       (control == bestControl and r.w * r.h > nodeRect(pageNodes[best]).w * nodeRect(pageNodes[best]).h):
      best = i
      bestControl = control
  result = best

proc stopsOf(nodes: seq[AccessNode]): seq[uint32] =
  ## The stops of Tab of a page drawn without input (the designer's): its
  ## controls in the order they are drawn -- a list, a table, a tree one
  ## stop, not what is in them; not a tool bar's buttons, a menu's items,
  ## nor what is disabled.
  for i, n in nodes:
    if n.role notin Unnamed or asDisabled in n.states: continue
    var inside = false
    for j in countdown(i - 1, 0):
      let m = nodes[j]
      if m.role in {arList, arTable, arTree, arToolBar, arMenu, arMenuBar, arTabList} and
         n.x >= m.x and n.y >= m.y and n.x + n.w <= m.x + m.w and n.y + n.h <= m.y + m.h:
        inside = true
        break
    if not inside: result.add n.id

proc unnamedCount(): int =
  for n in pageNodes:
    if n.role in Unnamed and n.name.strip.len == 0: inc result

proc readAs(n: AccessNode): string =
  ## (a node as a screen reader and the driver know it: its role, its name)
  roleWord(n.role) & (if n.name.len > 0: " \"" & n.name & "\"" else: " (no name)")

proc namesOverlay() =
  ## The page's stops of Tab numbered in their order, and the controls a
  ## screen reader cannot name -- no label before them, no `accessName` --
  ## outlined in red.
  let th = ui.theme
  let red = color(220, 30, 30)
  for n in pageNodes:
    if n.role in Unnamed and n.name.strip.len == 0:
      let r = nodeRect(n)
      dashed(rect(r.x - 1, r.y - 1, r.w + 2, r.h + 2), red)
      dashed(r, red)
  for i, id in pageStops:
    for n in pageNodes:
      if n.id != id: continue
      let r = nodeRect(n)
      let tag = $(i + 1)
      let bw = textWidth(tag, style(size = 0.85)) + dp(6)
      let b = rect(r.x - dp(2), r.y - dp(2), bw, FontH - dp(1))
      fill(b, if n.name.strip.len == 0 and n.role in Unnamed: red else: th.select)
      text(b.x + dp(3), b.y, tag, th.selectText, style(size = 0.85))
      break

proc suggestedName(it: Item): string =
  ## (a name for a control from its variable: `userName` -> "User name")
  if it == nil or it.call == nil: return ""
  for a in it.call.args:
    if a.kind == nkIdent:
      let s = a.ident.s
      var words = ""
      for i, ch in s:
        if i > 0 and ch.isUpperAscii: words.add ' '
        words.add(if i == 0: ch.toUpperAscii else: ch.toLowerAscii)
      return words
  ""

proc nameIt(it: Item; name: string) =
  ## `accessName "..."` put before control `it`: what screen readers and
  ## drivers know it by.
  if it == nil or name.strip.len == 0: return
  let (list, owner) = it.parentList
  if list == nil: return
  let at = list.stmts.find(it.node)
  if at < 0: return
  let line = it.line
  tryChange((proc (): string = src.insertAt(list, owner, at, "accessName " & nimLit(name.strip))), line + 1)
  status = "Named \"" & name.strip & "\" (accessName, line " & $line & ")"

proc surface() =
  let pg = page()
  let th = ui.theme
  if pg == nil:
    label(if src != nil and not src.ok: "The file does not read: line " & $src.errors[0].line &
            " -- " & src.errors[0].msg else: "This file has no window to design: no `app` block, " &
            "no `while beginFrame()` window, no proc that draws controls.")
    return
  let w = dp(pg.w)
  let h = dp(pg.h)
  let margin = dp(28)
  let whole = place(w + 2 * margin, h + 2 * margin + dp(20), fill = false)
  fill(whole, mixColor(th.face, th.shadow, 0.35))
  pageRect = rect(whole.x + margin, whole.y + margin + dp(20), w, h)
  frameAround(pageRect, pg.title)
  ev.focus = if sel.len > 0: sel[0] else: nil
  let a0 = accessTree.len
  let s0 = tabStops().len           # (none while the page takes no input: then from its nodes)
  applyLook(look, proc () = ev.drawPage(pg, pageRect))
  # (what a screen reader and a driver know of it: its nodes, its stops of Tab)
  pageNodes = if accessTree.len > a0: accessTree[a0 ..< accessTree.len] else: @[]
  pageStops.setLen(0)
  let stops = tabStops()
  for i in s0 ..< stops.len: pageStops.add uint32(stops[i])
  if pageStops.len == 0: pageStops = stopsOf(pageNodes)
  if namesOn and not inEditor and not readOnly: namesOverlay()
  if inEditor or readOnly:
    # (greyed: the file is the editor's, or another designer's)
    for y in countup(pageRect.y, pageRect.y + pageRect.h, 3):
      fill(rect(pageRect.x, y, pageRect.w, 1), mixColor(th.window, th.shadow, 0.6))
    let msg = if inEditor: "In your editor -- close it there to design again"
              else: hold.by & " has this file"
    let mw = textWidth(msg) + dp(20)
    let mr = rect(pageRect.x + (pageRect.w - mw) div 2, pageRect.y + pageRect.h div 2 - dp(14), mw, dp(28))
    fill(mr, th.window)
    outlineRect(mr, th.frame)
    text(mr.x + dp(10), mr.y + (mr.h - FontH) div 2, msg, th.text)
    return
  # hover, selection (over a dialog or menu shown on the page: on its layer)
  let over = mouseIn(pageRect)
  hoverItem = if over: itemAt(ui.mx, ui.my) else: nil
  let lay = if ev.overlay == nil: -1
            elif ev.overlay.name == "menu": LayerPopup
            else: LayerDialog
  let clip = clipRect()
  if lay >= 0:
    pushLayer(lay)
    pushClip(clip)
  defer:
    if lay >= 0:
      popClip()
      popLayer()
  if hoverItem != nil and (sel.len == 0 or hoverItem notin sel):
    outlineRect(hoverItem.rect, mixColor(th.select, th.window, 0.4))
  for it in sel:
    if it.drawn and it.rect.w > 0:
      outlineRect(it.rect, th.select, 2)
      # (no tag in an open menu: it would cover the rows; the status bar says it)
      if ev.overlay != nil and ev.overlay.name == "menu" and it != ev.overlay: continue
      let tag = design.label(it).split("  ")[0] & "  line " & $it.line
      let tw = textWidth(tag) + dp(8)
      let tr = rect(it.rect.x, max(pageRect.y - dp(18), it.rect.y - FontH - dp(6)), tw, FontH + dp(4))
      fill(tr, th.select)
      text(tr.x + dp(4), tr.y + dp(2), tag, th.selectText)
  # the page's size grip
  let grip = rect(pageRect.x + pageRect.w - dp(12), pageRect.y + pageRect.h - dp(12), dp(14), dp(14))
  if ui.pressed and mouseIn(grip) and pg.sizeCall != nil:
    sizing = (true, pg.w, pg.h, ui.mx, ui.my)
  if sizing.on:
    if ui.mouseDown:
      pg.w = max(160, sizing.w0 + int(round(float(ui.mx - sizing.x0) / ui.k)))
      pg.h = max(100, sizing.h0 + int(round(float(ui.my - sizing.y0) / ui.k)))
      ui.redraw = true
    else:
      sizing.on = false
      writeSize(pg, pg.w, pg.h)
    return
  # a control from the Widget Box: dropped (dragged) or placed (chosen, then a click)
  let drop = dropTarget(pageRect, "retro-widget")
  if drop != dsNone:
    target = targetAt(ui.mx, ui.my)
    fill(target.bar, th.select)
    if drop == dsDropped and ui.drag.items.len > 0:
      let nm = ui.drag.items[0]
      for x in widgetBox:
        if x.name == nm:
          insertExample(x, target)
          break
    return
  if placing >= 0 and over:
    target = targetAt(ui.mx, ui.my)
    fill(target.bar, th.select)
    if ui.pressed:
      insertExample(widgetBox[placing], target)
      if CtrlPressed notin ui.mods: placing = -1
    return
  # press, drag to move, click to choose
  if ui.pressed: onSurface = over
  if ui.pressed and over:
    ui.focus = 0
    let it = hoverItem
    drag = (dkPress, it, ui.mx, ui.my)
    if it == nil:
      sel = @[pg.root]
    elif CtrlPressed in ui.mods and sel.len > 0 and sel[0] != pg.root:
      if it in sel: sel.keepItIf(it != it) else: sel.add it
    elif it notin sel:
      sel = @[it]
    if ui.clicks >= 2 and it != nil: eventCode(it)
  if drag.kind == dkPress and ui.mouseDown and drag.item != nil and
     abs(ui.mx - drag.x) + abs(ui.my - drag.y) > dp(6):
    drag.kind = dkMove
  if drag.kind == dkMove:
    target = targetAt(ui.mx, ui.my, drag.item)
    fill(target.bar, th.select)
    ui.redraw = true
    if not ui.mouseDown:
      let it = drag.item
      drag.kind = dkNone
      let (fl, _) = it.parentList
      try:
        let oldLines = src.stmtLines(it.node)
        let t = src.moveStmt(it.node, fl, target.list, target.owner, target.index)
        # (where it went: where it was put, counted in the new text)
        let ss = target.list.stmts
        var at = if target.index < ss.len: src.stmtLines(ss[target.index]).first
                 elif ss.len > 0: src.stmtLines(ss[^1]).last + 1 else: oldLines.first
        if at > oldLines.last: at -= oldLines.last - oldLines.first + 1
        change(t, at + (it.line - oldLines.first))
        status = "Moved"
      except DesignError as e: status = "Not moved: " & e.msg
  elif not ui.mouseDown and drag.kind != dkNone:
    drag.kind = dkNone

# ---- the panes --------------------------------------------------------------------------------

proc widgetBoxPane() =
  label "Widget Box", bold = true
  edit boxSearch
  var parts: seq[string]
  for x in widgetBox:
    if x.part notin parts: parts.add x.part
  let q = boxSearch.strip.toLowerAscii
  tree(boxSel, max(4, (remainingH() - 4 * FontH - dp(16)) div ItemH)):
    for p in parts:
      var open = boxOpen.getOrDefault(p, q.len > 0)
      if q.len > 0: open = true
      var any = false
      for x in widgetBox:
        if x.part == p and (q.len == 0 or q in x.title.toLowerAscii or q in x.name.toLowerAscii):
          any = true
      if not any: continue
      branch p, open:
        for i, x in widgetBox:
          if x.part != p: continue
          if q.len > 0 and q notin x.title.toLowerAscii and q notin x.name.toLowerAscii: continue
          if leaf(x.title, id = x.name):
            placing = i
            status = "Click on the window where " & x.title & " goes (Esc: not now)"
          # (dragged out of the box: a drag onto the window)
          if ui.pressed and hover(ui.lastRect): boxPress = (x.name, x.title, ui.mx, ui.my)
      boxOpen[p] = open
  # (what the chosen one is)
  let chosen = boxSel.split('/')
  var about = "Choose a control, then click on the window where it goes -- or drag it there."
  for x in widgetBox:
    if chosen.len == 2 and x.title == chosen[1] and x.part == chosen[0]: about = x.about
  label about.replace("`", "")
  if boxPress.name.len > 0:
    if not ui.mouseDown: boxPress.name = ""
    elif not dragging() and abs(ui.mx - boxPress.x) + abs(ui.my - boxPress.y) > dp(8):
      startDrag("retro-widget", [boxPress.name], boxPress.title)
      boxPress.name = ""

proc treePane() =
  label "Object Tree", bold = true
  let pg = page()
  if pg == nil: return
  buildTree()
  var k = -1
  if sel.len > 0:
    k = treeItems.find(sel[0])
  let before = k
  if listbox(treeLines, k, rows = -1) or k != before:
    if k >= 0 and k < treeItems.len:
      let it = treeItems[k]
      if it.kind == ikArm and it.parent != nil:
        it.parent.shown = it.parent.kids.find(it)
        # (an arm `if x == N`: the variable set so the page shows it)
        let n = it.node
        if n.kind in {nkElifBranch, nkElifExpr} and n.len > 0 and n[0].kind == nkInfix and
           n[0].len == 3 and n[0][1].kind == nkIdent and n[0][2].kind in {nkIntLit .. nkUInt64Lit}:
          let c = ev.cellFor(n[0][1])
          c.i = int(n[0][2].intVal)
          c.kind = vkInt
      sel = @[it]

proc propertiesPane() =
  let it = if sel.len > 0: sel[0] else: nil
  if it == nil or it.call == nil:
    label "Choose a control on the window."
    return
  # (what screen readers and drivers know it by)
  let k0 = nodeOf(it)
  if k0 >= 0:
    let n = pageNodes[k0]
    row([-1, 0, 0]):
      label("Read as: " & readAs(n),
            color = if n.role in Unnamed and n.name.strip.len == 0: color(200, 30, 30) else: ui.theme.text)
      if n.role in Unnamed and n.name.strip.len == 0:
        if button("&Name It...", enabled = not readOnly and not inEditor):
          nameFor = it
          nameText = suggestedName(it)
          nameAsk = true
      elif n.name.len > 0:
        if button("Driver Command"):
          let cmd = "click " & nimLit(n.name) & " --role " & roleWord(n.role)
          putClipboardText(cmd)
          status = "Copied: retrokit drive PORT " & cmd
        tooltip "The command that clicks it, for `retrokit drive` (the app run with RETRO_DRIVE=PORT)"
  if it != propsFor or propsText != src.text: buildProps(it)
  if props.len == 0:
    label "It has nothing to set."
    return
  let k = propertyGrid(props, propSel, height = remainingH() - EditH - 3 * Gap, key = "designer-props")
  if k >= 0: propChanged(k)
  row:
    if button("&Reset", enabled = propSel >= 0 and propSel < propMap.len and propMap[propSel].param >= 0):
      resetProp(propSel)
    if button("Edit &Code", enabled = it.kind in {ikEvent, ikControl, ikValue, ikBlock}):
      editCode(it.line)

proc eventsPane() =
  let it = if sel.len > 0: sel[0] else: nil
  if it == nil or it.call == nil:
    label "Choose a control on the window."
    return
  label it.name, bold = true
  if it.kind == ikEvent:
    label eventName(it.name) & ": it runs the code under it."
    let body = it.body
    if body != nil:
      var n = 0
      for st in body.stmts:
        label "  " & src.lineText(src.lineOfNode(st)).strip
        inc n
        if n >= 6:
          label "  ..."
          break
    if button("Edit &Code", isDefault = true): eventCode(it)
  elif it.kind == ikControl and it.returnsBool:
    label "No code runs when it is " & eventName(it.name).toLowerAscii & "."
    if button("Add the " & eventName(it.name) & " &Event", isDefault = true): eventCode(it)
  else:
    label "This control has no event."

proc variablesPane() =
  if varsText != src.text: buildVarProps()
  if varProps.len == 0:
    label "The file has no variables yet."
    return
  let k = propertyGrid(varProps, varSel, height = remainingH() - EditH - 3 * Gap, key = "designer-vars")
  if k >= 0:
    var n = -1
    for v in design.vars:
      if v.init.len == 0: continue
      inc n
      if n == k:
        let init = v.node[^1]
        let t = varProps[k].text
        tryChange(proc (): string = apply(src.text, [(src.startOff(init), src.endOff(init), t)]))
        break
  row([-1, 0]):
    edit renameTo
    if button("Re&name", enabled = varSel >= 0 and varSel < varProps.len and renameTo.strip.len > 0):
      let old = varProps[varSel].name
      let nw = renameTo.strip
      let was = src.text
      tryChange(proc (): string = src.renameIdent(old, nw))
      if src.text != was: status = "Renamed " & old & " to " & nw
      renameTo = ""

# ---- keys -------------------------------------------------------------------------------------

proc ctrl(k: KeyCode): bool = CtrlPressed in ui.mods and ui.key == k and not ui.keyUsed

proc keys() =
  # (commands of the whole window first; then, unless a box takes the typing,
  # the ones of the window being designed)
  if ctrl(KeyS):
    ui.keyUsed = true
    save()
    return
  elif ctrl(KeyO):
    ui.keyUsed = true
    whenSaved(proc () = (dlgPath = ""; openDlg = true))
    return
  elif ctrl(KeyN):
    ui.keyUsed = true
    whenSaved(newFile)
    return
  elif keyHit(KeyF5):
    previewOn = not previewOn
    return
  if previewOn:
    # (the preview's controls have the keys; Esc ends it)
    if keyHit(KeyEsc): previewOn = false
    return
  if ui.takesText and not onSurface: return
  if ctrl(KeyZ):
    ui.keyUsed = true
    if ShiftPressed in ui.mods: doRedo() else: doUndo()
  elif ctrl(KeyY):
    ui.keyUsed = true
    doRedo()
  elif ctrl(KeyC):
    ui.keyUsed = true
    let t = copySel()
    if t.len > 0: putClipboardText(t)
  elif ctrl(KeyX):
    ui.keyUsed = true
    let t = copySel()
    if t.len > 0:
      putClipboardText(t)
      deleteSel()
  elif ctrl(KeyV):
    ui.keyUsed = true
    pasteCode(getClipboardText())
  elif ctrl(KeyD):
    ui.keyUsed = true
    let t = copySel()
    if t.len > 0: pasteCode(t)
  elif ctrl(KeyR):
    ui.keyUsed = true
    wrapSel("row:")
  elif ctrl(KeyG):
    ui.keyUsed = true
    wrapSel("group \"Group\":")
  elif AltPressed in ui.mods and ui.key == KeyUp:
    ui.keyUsed = true
    moveBy(-1)
  elif AltPressed in ui.mods and ui.key == KeyDown:
    ui.keyUsed = true
    moveBy(1)
  elif keyHit(KeyDelete):
    deleteSel()
  elif keyHit(KeyEsc):
    if previewOn: previewOn = false
    elif placing >= 0:
      placing = -1
      status = "Ready"
    elif sel.len > 0 and sel[0].parent != nil:
      var p = sel[0].parent
      while p != nil and p.kind == ikArm and p.parent != nil: p = p.parent
      sel = @[p]
  elif keyHit(KeyEnter):
    if sel.len > 0: eventCode(sel[0])

# ---- the window -------------------------------------------------------------------------------

type View = tuple[page: int; item: Item; name: string]

proc views(): seq[View] =
  ## What the Page list offers: the pages, and under each its dialogs (a
  ## dialog is designed shown over its page).
  if design == nil: return
  for i, p in design.pages:
    result.add (i, Item(nil), p.title & "  (" & $p.kind & ")")
    for x in p.root.walk:
      if x.kind == ikBlock and x.name in ["dialog", "wizard"]:
        let ps = x.call.positional
        let t = if ps.len > 1: ev.valueOf(ps[1]) else: Value()
        result.add (i, x, "      " & (if t.kind == vkStr: t.s.replace("&", "") else: x.name & " at line " & $x.line) &
                          "  (" & x.name & ")")

proc viewNow(vs: seq[View]): int =
  ## The view shown now: the dialog the chosen item is in, else the page.
  result = -1
  for i, v in vs:
    if v.page != pageIdx: continue
    if v.item == nil:
      if result < 0: result = i
    elif sel.len > 0 and sel[0].inside(v.item): result = i

proc chooseView(v: View) =
  if v.page != pageIdx: sel.setLen(0)
  pageIdx = v.page
  if v.item != nil: sel = @[v.item]
  elif sel.len > 0 and sel[0] != nil:
    # (back to the page: off the dialog)
    for x in design.pages[pageIdx].root.walk:
      if x.kind == ikBlock and x.name in ["dialog", "wizard"] and sel[0].inside(x):
        sel.setLen(0)
        break

proc main() =
  initRegistry()
  # (a web view in the design is drawn the kit's way: the system's engine
  #  would be a window of its own over the designer)
  webEngine = weKit
  settings = loadSettings(SettingsName)
  editorCmd = settings.getOrDefault("editor")
  namesOn = settings.getOrDefault("names") == "true"
  accessKeep = true                    # (the page's names and stops of Tab: `pageNodes`)
  # (the panes as they were left)
  try:
    leftW = parseInt(settings.getOrDefault("leftW", $leftW))
    midW = parseInt(settings.getOrDefault("midW", $midW))
    treeH = parseInt(settings.getOrDefault("treeH", $treeH))
  except ValueError: discard
  var args: seq[string]
  for a in commandLineParams():
    if not a.startsWith("-"): args.add a
  if args.len > 0:
    if not fileExists(args[0]):
      try: writeFile(args[0], NewFileText) except IOError: discard
    openFile(args[0])
  else: newFile()
  var recent: seq[string]
  app "Retro Designer", 1180, 760:
    watchEditor()
    if inEditor: wakeIn(400)
    if closeRequested():
      if dirty:
        cancelClose()
        afterSave = proc () = quitApp()
        askSave = true
    recent = settings.getOrDefault("recent").split('\t').filterIt(it.len > 0)
    menubar:
      menu "&File":
        if menuItem("&New", "Ctrl+N"): whenSaved(newFile)
        if menuItem("&Open...", "Ctrl+O"): whenSaved(proc () = (dlgPath = ""; openDlg = true))
        if menuItem("&Save", "Ctrl+S", enabled = not readOnly and not inEditor): save()
        if menuItem("Save &As...", enabled = not inEditor):
          dlgPath = filePath
          saveDlg = true
        if menuItem("&Reload", enabled = filePath.len > 0 and not inEditor):
          whenSaved(proc () = openFile(filePath))
        if recent.len > 0:
          menuSeparator()
          for i, r in recent:
            if menuItem("&" & $(i + 1) & " " & r.extractFilename):
              let p = r
              whenSaved(proc () = openFile(p))
        menuSeparator()
        if menuItem("E&xit"): requestClose()
      menu "&Edit":
        if menuItem("&Undo", "Ctrl+Z", enabled = undos.len > 0): doUndo()
        if menuItem("&Redo", "Ctrl+Y", enabled = redos.len > 0): doRedo()
        menuSeparator()
        if menuItem("Cu&t", "Ctrl+X", enabled = sel.len > 0):
          let t = copySel()
          if t.len > 0:
            putClipboardText(t)
            deleteSel()
        if menuItem("&Copy", "Ctrl+C", enabled = sel.len > 0):
          let t = copySel()
          if t.len > 0: putClipboardText(t)
        if menuItem("&Paste", "Ctrl+V"): pasteCode(getClipboardText())
        if menuItem("D&uplicate", "Ctrl+D", enabled = sel.len > 0):
          let t = copySel()
          if t.len > 0: pasteCode(t)
        if menuItem("&Delete", "Del", enabled = sel.len > 0): deleteSel()
        menuSeparator()
        if menuItem("Edit &Code", "Enter", enabled = sel.len > 0): eventCode(sel[0])
        if menuItem("Se&ttings..."): settingsOpen = true
      menu "&Layout":
        if menuItem("Put in a &Row", "Ctrl+R", enabled = sel.len > 0): wrapSel("row:")
        if menuItem("Put in a &Column", enabled = sel.len > 0): wrapSel("col:")
        if menuItem("Put in a &Group", "Ctrl+G", enabled = sel.len > 0): wrapSel("group \"Group\":")
        if menuItem("Put in a &Panel", enabled = sel.len > 0): wrapSel("panel:")
        if menuItem("Put in a C&ard", enabled = sel.len > 0): wrapSel("card \"Card\":")
        if menuItem("Put in a &Form", enabled = sel.len > 0): wrapSel("form 0:")
        menuSeparator()
        if menuItem("&Take Out of Its Container", enabled = sel.len > 0): unwrapSel()
        menuSeparator()
        if menuItem("Move &Up", "Alt+Up", enabled = sel.len > 0): moveBy(-1)
        if menuItem("Move &Down", "Alt+Down", enabled = sel.len > 0): moveBy(1)
      menu "&View":
        for i, l in Looks:
          if menuItem("&" & l, checked = look == i): look = i
        menuSeparator()
        if menuItem("&Names and Tab Order", checked = namesOn):
          namesOn = not namesOn
          settings["names"] = $namesOn
          discard saveSettings(SettingsName, settings)
          if namesOn:
            let n = unnamedCount()
            status = (if n == 0: "Every control has a name" else: $n & " controls have no name (red)") &
                     "; " & $pageStops.len & " stops of Tab, numbered"
        if menuItem("&Preview", "F5", checked = previewOn): previewOn = not previewOn
        let vs = views()
        if vs.len > 1:
          menuSeparator()
          let now = viewNow(vs)
          for i, v in vs:
            if menuItem(v.name.strip, checked = now == i): chooseView(v)
      menu "&Help":
        if menuItem("&About Retro Designer..."): aboutOpen = true
    toolbar:
      if toolButton(pxNew, "New"): whenSaved(newFile)
      if toolButton(pxOpen, "Open"): whenSaved(proc () = (dlgPath = ""; openDlg = true))
      if toolButton(pxSave, "Save", enabled = not readOnly and not inEditor): save()
      toolSeparator()
      if toolButton(pxUndo, "Undo", enabled = undos.len > 0): doUndo()
      if toolButton(pxRedo, "Redo", enabled = redos.len > 0): doRedo()
      toolSeparator()
      if toolButton(pxCut, "Cut", enabled = sel.len > 0):
        let t = copySel()
        if t.len > 0:
          putClipboardText(t)
          deleteSel()
      if toolButton(pxCopy, "Copy", enabled = sel.len > 0):
        let t = copySel()
        if t.len > 0: putClipboardText(t)
      if toolButton(pxPaste, "Paste"): pasteCode(getClipboardText())
      if toolButton(pxDelete, "Delete", enabled = sel.len > 0): deleteSel()
      toolSeparator()
      if toolButton("Row", "Put in a row (Ctrl+R)", enabled = sel.len > 0): wrapSel("row:")
      if toolButton("Group", "Put in a group (Ctrl+G)", enabled = sel.len > 0): wrapSel("group \"Group\":")
      toolSeparator()
      if toolButton("Preview", "The window as it will be (F5)", down = previewOn): previewOn = not previewOn
      if toolButton("Edit Code", "Your editor at this control's code (Enter)", enabled = sel.len > 0):
        eventCode(sel[0])
    let sl = if sel.len > 0 and sel[0].line > 0: sel[0].name & "  line " & $sel[0].line else: ""
    statusbar(status, sl,
              (if filePath.len > 0: filePath.extractFilename else: "Untitled") & (if dirty: " *" else: ""))
    if previewOn:
      let pg = page()
      if pg != nil:
        row:
          label "Preview: " & pg.title & " -- its controls work, its code does not run"
          spring()
          label "Look:"
          combo(Looks, look, w = 160)
          if button("&Close Preview"): previewOn = false
        scrollPanel(-1):
          let margin = dp(28)
          let whole = place(dp(pg.w) + 2 * margin, dp(pg.h) + 2 * margin + dp(20), fill = false)
          fill(whole, mixColor(ui.theme.face, ui.theme.shadow, 0.35))
          let r = rect(whole.x + margin, whole.y + margin + dp(20), dp(pg.w), dp(pg.h))
          frameAround(r, pg.title)
          ev.focus = nil
          applyLook(look, proc () = ev.drawPage(pg, r, live = true))
    else:
      split(leftW, -1):
        widgetBoxPane()
      do:
        split(midW, -1):
          row([0, -1, 0, 0]):
            label "&Page:"
            if design.pages.len > 0:
              let vs = views()
              var k = viewNow(vs)
              let before = k
              combo(vs.mapIt(it.name), k)
              if k != before and k >= 0: chooseView(vs[k])
            else: label "(none)"
            label "Look:"
            combo(Looks, look, w = 130)
          scrollPanel(-1):
            surface()
        do:
          vsplit(treeH, -1):
            treePane()
          do:
            tabs(rightTab, ["Properties", "Events", "Variables"]):
              case rightTab
              of 0: propertiesPane()
              of 1: eventsPane()
              else: variablesPane()
    # (the designer's keys: after the panes, which take theirs first)
    if not (openDlg or saveDlg or askSave or settingsOpen or aboutOpen or nameAsk): keys()
    # the dialogs
    if fileDialog(openDlg, dlgPath, fmOpen, ["Nim Files (*.nim)", "All Files (*.*)"], "Open"):
      openFile(dlgPath)
    if fileDialog(saveDlg, dlgPath, fmSave, ["Nim Files (*.nim)", "All Files (*.*)"], "Save As"):
      saveAs(dlgPath)
    dialog(askSave, "Retro Designer", 380):
      label "Save the changes to " & (if filePath.len > 0: filePath.extractFilename else: "Untitled") & "?"
      case buttonRow(["&Save", "Do&n't Save", "Cancel"])
      of 1:
        askSave = false
        let f = afterSave
        afterSave = nil
        save(f)
      of 2:
        askSave = false
        dirty = false
        let f = afterSave
        afterSave = nil
        if f != nil: f()
      of 3:
        askSave = false
        afterSave = nil
      else: discard
    dialog(nameAsk, "Name It", 420):
      label "The name screen readers and drivers know it by:"
      edit nameText
      label("Written before it as accessName \"...\" (a label just before it names it too).",
            color = ui.theme.gray)
      case buttonRow(["OK", "Cancel"])
      of 1:
        nameAsk = false
        nameIt(nameFor, nameText)
      of 2: nameAsk = false
      else: discard
    dialog(settingsOpen, "Settings", 480):
      label "Your &editor ({file} and {line} are put in; empty: found by itself):"
      edit editorCmd
      label "Now: " & (if editorCmd.len > 0: editorCmd else: defaultEditor())
      case buttonRow(["OK", "Cancel"])
      of 1:
        settings["editor"] = editorCmd
        discard saveSettings(SettingsName, settings)
        settingsOpen = false
      of 2:
        editorCmd = settings.getOrDefault("editor")
        settingsOpen = false
      else: discard
    aboutBox(aboutOpen, "Retro Designer", RetroVersion,
             ["The visual designer of Retro Nim UI: your .nim file drawn as its windows, " &
              "changed by dragging and setting properties, written back as Nim.",
              "Developed by Sultan Al Isaiee (@foxoman) -- www.foxoman.net",
              "MIT licence"], glyph = pxWindow)
  hold.release()
  settings["leftW"] = $leftW
  settings["midW"] = $midW
  settings["treeH"] = $treeH
  discard saveSettings(SettingsName, settings)

when isMainModule and not defined(retroDesignerTest):   # (tests/test_designer includes it)
  try: main()
  finally: hold.release()             # (even when something went wrong)

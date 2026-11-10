## Retro Designer without a window: what it knows of the controls, every
## example app read and drawn, each kind of change it makes kept as Nim that
## reads, every control of the Widget Box dropped into one app that then
## compiles, and its hold on the file (the lock, the read-only rights).
## The toolkit's parts the designer stands on are tested too: `windowBox`,
## `inert`, `showMenu`, `notePlaced`.
##
##   nim c -r tests/test_designer.nim        (`nimble test` runs it)
##
## It needs Nim's compiler sources (tests/test_designer.nims finds them).

import std/[os, strutils, osproc, sequtils, tables]
when not defined(windows): import std/posix
import harness
include ../src/retrodesigner/retrodesigner

var failures = 0

proc expect(cond: bool; what: string) =
  if not cond:
    inc failures
    echo "  FAILED: ", what

let root = currentSourcePath().parentDir.parentDir
let tmp = getTempDir() / ("retro-designer-test-" & $getCurrentProcessId())
createDir(tmp)

proc nimCheck(file: string): tuple[ok: bool; text: string] =
  let (o, code) = execCmdEx("nim check --hints:off --warnings:off --path:" &
                            quoteShell(root / "src") & " " & quoteShell(file))
  (code == 0, o)

var drawing: proc ()
harness.view = proc () =
  if drawing != nil: drawing()
fakeDriver()
startApp("test_designer", W, H)
run(2)

# ---- the toolkit's parts ------------------------------------------------------------------------

block windowBoxAndInert:
  # a dialog drawn in an inert window box: shown, but the window's input
  # stays its own (the next frame's input layer is still the base)
  var open = true
  var placed: Rect
  var menuDrawn = false
  drawing = proc () =
    ui.measuring = true
    ui.placed = rect(0, 0, 0, 0)
    inert:
      windowBox(rect(100, 50, 300, 200)):
        let shown = showMenu(["&File"])
        menubar:
          menu "&File":
            menuDrawn = true
            discard menuItem("&Open")
        hideMenu(shown)
        label "In the box"
        dialog open, "Box dialog", 200:
          label "Inside"
    placed = ui.placed
    ui.measuring = false
  run(3)
  expect(ui.inputLayer == LayerBase, "a dialog in `inert` does not take the window's input")
  expect(ui.popup == 0, "showMenu / hideMenu leave no menu open")
  expect(menuDrawn, "showMenu opens the menu for the menu bar drawn next")
  expect(placed.x >= 100 and placed.y >= 50 and placed.x + placed.w <= 400 and
         placed.y + placed.h <= 250, "what a window box draws stays in its box: " & $placed)
  drawing = nil
  run()

# ---- the registry -------------------------------------------------------------------------------

initRegistry()
block registryFilled:
  expect(controls.len >= 150, "the controls known: " & $controls.len)
  for b in ["row", "col", "group", "dialog", "menu", "menubar", "toolbar", "split", "vsplit",
            "tabs", "form", "field", "tree", "branch"]:
    expect(blocks.hasKey(b), "a block the designer draws: " & b)
  expect(widgetBox.len >= 100, "the Widget Box: " & $widgetBox.len)
  for x in widgetBox:
    expect(x.code.strip.len > 0, "an example with code: " & x.name)

# ---- every example app read, drawn, and each of its controls taken out ---------------------------

proc drawAll(d: Design; e: var Eval): int =
  ## Every page drawn; how many items were drawn.
  let ep = addr e
  for page in d.pages:
    let pg = page
    let r = rect(0, 0, min(W, pg.w), min(H, pg.h))
    var ex = ""
    drawing = proc () =
      try: ep[].drawPage(pg, r)
      except Exception as x: ex = x.msg
    run(2)
    expect(ex.len == 0, pg.title & " drawn without an error: " & ex)
    for it in pg.root.walk:
      if it.drawn: inc result
  drawing = nil

block examplesRead:
  var files = 0
  for f in walkFiles(root / "examples" / "*.nim"):
    inc files
    let s = parseSrc(readFile(f))
    expect(s.ok, f.extractFilename & " reads")
    if not s.ok: continue
    let d = readDesign(s)
    var e = initEval(d)
    let n = drawAll(d, e)
    expect(d.pages.len == 0 or n > 0, f.extractFilename & ": something drawn")
    # each control and block taken out: the file still reads
    var tried = 0
    for pg in d.pages:
      for it in pg.root.walk:
        if it == pg.root or it.kind in {ikCode, ikArm} or it.list == nil: continue
        inc tried
        try:
          let t = s.deleteStmt(it.node, (if it.parent != nil and it.parent.kind == ikArm: it.parent.body
                                        else: it.list))
          expect(parseSrc(t).ok, f.extractFilename & " line " & $it.line & " deleted: still reads")
        except DesignError: discard
        if tried > 400: break
  expect(files >= 10, "the example apps found: " & $files)

# ---- a design session: every Widget Box control dropped into one app ----------------------------

let sessionFile = tmp / "session.nim"
writeFile(sessionFile, NewFileText)
openFile(sessionFile)

block holdsTheFile:
  expect(hold.held, "the designer holds the file it opened")
  expect(fileExists(lockPath(sessionFile)), "the lock beside it")
  when not defined(windows):
    expect((getFilePermissions(sessionFile) * {fpUserWrite}).len == 0,
           "held: the file is read-only for other programs")

proc atEnd(): Target =
  let pg = page()
  Target(ok: true, list: pg.body, owner: pg.node, index: pg.body.stmts.len)

block everyExample:
  for x in widgetBox:
    status = ""
    insertExample(x, atEnd())
    expect(status.startsWith("Added"), "inserted " & x.name & " (" & x.title & "): " & status)
  save()
  expect(not dirty, "saved")
  let (ok, text) = nimCheck(sessionFile)
  expect(ok, "every Widget Box example together compiles:\n" & text.splitLines.filterIt(
    "Error" in it).join("\n"))
  # and it is drawn
  var e = initEval(design)
  discard drawAll(design, e)

# ---- each kind of change --------------------------------------------------------------------------

proc findItem(name: string; kinds = {ikControl, ikEvent, ikBlock, ikValue}): Item =
  for it in page().root.walk:
    if it.kind in kinds and it.name == name: return it

block changes:
  writeFile(tmp / "plain.nim", NewFileText)
  openFile(tmp / "plain.nim")
  let before = src.text
  # an event added to a control that returns true when used
  sel = @[findItem("edit")]
  expect(sel[0] != nil, "the template's edit box")
  let lbl = findItem("label")
  # two side by side put in a group, then taken out again
  sel = @[lbl, findItem("edit")]
  wrapSel("group \"Who\":")
  expect("group \"Who\":" in src.text and src.ok, "put in a group")
  let g = findItem("group")
  expect(g != nil and g.kids.len == 2, "the group holds both")
  sel = @[g]
  unwrapSel()
  expect("group" notin src.text and src.ok, "taken out of the group")
  # moved down and back up
  sel = @[findItem("label")]
  let at = src.text.find("label")
  moveBy(1)
  expect(src.ok and src.text.find("label") > at, "moved down: " & status)
  sel = @[findItem("label")]
  moveBy(-1)
  expect(src.text.find("label") == at, "moved back up")
  # copied and pasted: two of it
  sel = @[findItem("label")]
  pasteCode(copySel())
  expect(src.text.count("label \"&Name:\"") == 2, "duplicated")
  sel = @[findItem("label")]
  deleteSel()
  expect(src.text.count("label \"&Name:\"") == 1, "deleted")
  # a property set: the label's text
  sel = @[findItem("label")]
  buildProps(sel[0])
  var k = -1
  for i, p in props:
    if p.name == "s" or p.name == "text": k = i
  expect(k >= 0, "the label's text among its properties")
  if k >= 0:
    props[k].text = "&Your name:"
    propChanged(k)
    expect("label \"&Your name:\"" in src.text, "a property written into the file")
  # an event: the button's is there; a checkbox gets one
  insertExample(widgetBox.filterIt(it.name == "checkbox")[0], atEnd())
  let cb = findItem("checkbox")
  expect(cb != nil, "a checkbox dropped")
  if cb != nil:
    sel = @[cb]
    eventCode(cb)
    expect(findItem("checkbox", {ikEvent}) != nil, "its event added")
  # a variable renamed everywhere
  let t2 = src.renameIdent("name", "fullName")
  change(t2)
  expect("var fullName" in src.text and "edit fullName" in src.text, "a variable renamed")
  # undone back to the start, then redone
  while undos.len > 0: doUndo()
  expect(src.text == before, "undone to the file as it was opened")
  doRedo()
  expect(src.text != before, "redone")
  save()
  let (ok, text) = nimCheck(tmp / "plain.nim")
  expect(ok, "the changed file compiles:\n" & text)

block renameKeepsFields:
  # a variable renamed: not a field of the same name, not an argument's
  # label, not a proc's own parameter of that name
  let s = parseSrc("type P = object\n  name: string\nvar name = \"\"\nlet p = P(name: name)\n" &
                   "echo p.name, name\nproc f(name = 1) = echo name\nf(name = 2)\n")
  expect(s.renameIdent("name", "fullName") ==
         "type P = object\n  name: string\nvar fullName = \"\"\nlet p = P(name: fullName)\n" &
         "echo p.name, fullName\nproc f(name = 1) = echo name\nf(name = 2)\n", "renamed as a name only")

block refusesWhatDoesNotRead:
  let t = src.text
  change(t & "\n  label (\n")
  expect(src.text == t and status.startsWith("Not done"), "a change that would not read is refused")

# ---- names and the keyboard -----------------------------------------------------------------------

block namesAndTabOrder:
  # what screen readers and drivers know of the page: its stops of Tab,
  # the control they cannot name, and Name It writing its name
  writeFile(tmp / "names.nim", "import retroui\n\nvar who = \"\"\nvar code = \"\"\n\n" &
            "app \"Names\", 300, 200:\n  label \"Name:\"\n  edit who\n  edit code\n" &
            "  if button(\"OK\"): discard\n")
  openFile(tmp / "names.nim")
  accessKeep = true
  namesOn = true
  drawing = proc () = surface()
  run(3)
  expect(pageStops.len == 3, "three stops of Tab: " & $pageStops.len)
  expect(unnamedCount() == 1, "one control without a name: " & $unnamedCount())
  let named = findItem("edit")
  expect(named != nil and nodeOf(named) >= 0 and readAs(pageNodes[nodeOf(named)]) == "textField \"Name:\"",
         "read as its label names it")
  var second: Item
  for it in page().root.walk:
    if it.kind == ikControl and it.name == "edit" and it != named: second = it
  expect(second != nil and nodeOf(second) >= 0 and pageNodes[nodeOf(second)].name.len == 0,
         "the second box has no name")
  expect(suggestedName(second) == "Code", "a name from its variable: " & suggestedName(second))
  nameIt(second, "Code")
  expect("  accessName \"Code\"\n  edit code" in src.text, "named before it:\n" & src.text)
  run(3)
  expect(unnamedCount() == 0, "named now")
  # the order Tab goes: the third stop dragged first -- one tabIndex written
  # (the stops by their names: the page drawn anew after a change has new ids)
  proc stopNames(): seq[string] =
    for id in pageStops:
      for n in pageNodes:
        if n.id == id: result.add n.name
  proc idsOf(names: seq[string]): seq[uint32] =
    for nm in names:
      for n in pageNodes:
        if n.name == nm and n.id in pageStops: result.add n.id
  expect(stopNames() == @["Name:", "Code", "OK"], "as drawn: " & $stopNames())
  writeTabOrder(idsOf(@["OK", "Name:", "Code"]))
  expect("  tabIndex 1\n  if button(\"OK\")" in src.text, "the OK button first:\n" & src.text)
  expect(src.text.count("tabIndex") == 1, "one tabIndex is enough:\n" & src.text)
  run(3)
  expect(stopNames() == @["OK", "Name:", "Code"], "numbered so: " & $stopNames())
  # the second box first: its tabIndex, the one there was taken away
  writeTabOrder(idsOf(@["Code", "Name:", "OK"]))
  run(3)
  expect(stopNames() == @["Code", "Name:", "OK"], "numbered again: " & $stopNames())
  expect(src.text.count("tabIndex") == 1 and "tabIndex 1\n  edit code" in src.text,
         "Code first, then the others as drawn:\n" & src.text)
  writeTabOrder(idsOf(@["OK", "Code", "Name:"]))
  run(3)
  expect(stopNames() == @["OK", "Code", "Name:"] and src.text.count("tabIndex") == 2,
         "two written when two are out of their place:\n" & src.text)
  # back as drawn: none left
  writeTabOrder(idsOf(@["Name:", "Code", "OK"]))
  expect("tabIndex" notin src.text, "as drawn, no tabIndex:\n" & src.text)
  run(3)
  # the window as a driver's test: found by name, Tab checked
  let t = driverTest()
  expect("wait \"Name:\" --role textField --timeout 10000" in t and
         "find \"OK\" --role button" in t, "found by name:\n" & t)
  expect("focus \"Name:\" --role textField\nkey Tab\nfocused \"Code\" --role textField\n" &
         "key Tab\nfocused \"OK\" --role button" in t, "Tab checked:\n" & t)
  drawing = nil
  namesOn = false
  accessKeep = false

# ---- the lock -------------------------------------------------------------------------------------

block lockHandoff:
  let f = tmp / "plain.nim"
  hold.release()
  expect(not fileExists(lockPath(f)), "let go: no lock")
  expect((getFilePermissions(f) * {fpUserWrite}).len > 0, "let go: writable again")
  when not defined(windows):
    # another designer that is running holds it: shown, not changed
    let other = posix.getppid()
    writeFile(lockPath(f), "pid=" & $other & "\nhost=" & hostName() & "\nmode=420\n")
    var h = take(f)
    expect(not h.held and h.by.len > 0, "held by another designer: " & h.by)
    # one that is gone left its lock: taken over
    writeFile(lockPath(f), "pid=999999\nhost=" & hostName() & "\nmode=420\n")
    h = take(f)
    expect(h.held, "a lock left by a designer that is gone is taken over")
    h.release()
    expect(not fileExists(lockPath(f)), "and let go again")

if failures > 0:
  quit "test_designer: " & $failures & " failed (its files kept in " & tmp & ")", 1
removeDir(tmp)
echo "test_designer: all passed"

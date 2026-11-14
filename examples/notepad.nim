## A Notepad in the manner of Windows 3.1: open and save files, cut, copy,
## paste, select all, the time and date (F5), find (Ctrl+F, F3), print to a
## PDF (Ctrl+P), a status bar and a "Save changes?" box on exit.
## nim c -r examples/notepad.nim
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils, times]
from retroui/system import sharedIn
import retroui
import retroui/report

var
  text = "Welcome to Retro Notepad.\n\nOpen a text file with File > Open, or type here.\n"
  saved = text
  path = ""
  askExit = false
  askNew = false
  showAbout = false
  openDlg = false
  saveDlg = false
  pdfDlg = false
  picked = ""
  status = ""
  finder = FindState()

proc docName(): string = (if path.len > 0: path.extractFilename else: "(Untitled)")

var editorId: Id
  ## The text area's id (from the frame before): its caret and selection
  ## live in `state(editorId)`.

proc editor(): Id = editorId

proc selection(): (int, int) =
  let st = state(editor())
  (min(st.caret, st.anchor), max(st.caret, st.anchor))

proc select(a, b: int) =
  var st = state(editor())
  st.anchor = clamp(a, 0, text.len)
  st.caret = clamp(b, 0, text.len)
  state(editor()) = st
  ui.focus = editor()
  ui.redraw = true

proc replaceSelection(s: string) =
  let (a, b) = selection()
  text = text[0 ..< a] & s & text[b .. ^1]
  select(a + s.len, a + s.len)

proc saveTo(p: string): bool =
  try:
    writeFile(p, text)
    path = p
    saved = text
    status = "Saved " & p.extractFilename
    true
  except IOError, OSError:
    status = "Could not save " & p
    false

proc save(): bool =
  if path.len == 0:
    saveDlg = true
    false
  else: saveTo(path)

proc printToPdf(p: string) =
  ## The text on A4 pages, in FreeMono, as a PDF.
  var dest = p
  if dest.splitFile.ext.toLowerAscii != ".pdf": dest &= ".pdf"
  try:
    var doc = newReport(docName(), page = A4)
    doc.footer("", "{page} / {pages}", "")
    for line in text.splitLines:
      if line.strip.len == 0: doc.space(6)
      else: doc.paragraph([span(line, mono = true)], size = 10)
    doc.savePdf(dest)
    status = "Printed to " & dest.extractFilename
  except CatchableError as e:
    status = "Could not print: " & e.msg

proc load(p: string) =
  try:
    text = readFile(p).replace("\r\n", "\n")
    saved = text
    path = p
    status = ""
    select(0, 0)
  except IOError, OSError:
    status = "Could not open " & p

proc findNext(backwards = false) =
  if finder.what.len == 0:
    finder.open = true
    return
  let (a, b) = selection()
  let at = findIn(text, finder.what, (if backwards: a else: b), finder.matchCase,
                  finder.wholeWord, backwards = backwards)
  if at < 0: status = "Cannot find \"" & finder.what & "\""
  else:
    status = ""
    select(at, at + finder.what.len)

app "Notepad", 620, 420:
  # (a text or a file shared from another app -- Android's share sheet: a
  # file opened; a text a document of its own, or put at the caret when
  # this one has changes)
  let came = sharedIn()
  if came.files.len > 0: load(came.files[0])
  elif came.text.len > 0:
    if text == saved:
      text = came.text
      saved = ""
      path = ""
      select(0, 0)
    else: replaceSelection(came.text)
  let wanted = "Notepad - " & docName()
  if ui.title != wanted: setTitle(wanted)
  if closeRequested() and text != saved:
    cancelClose()
    askExit = true

  menubar:
    menu "&File":
      if menuItem("&New"):
        if text != saved: askNew = true
        else:
          text = ""
          saved = ""
          path = ""
      if menuItem("&Open...", "Ctrl+O"): openDlg = true
      if menuItem("&Save", "Ctrl+S"): discard save()
      if menuItem("Save &As..."): saveDlg = true
      menuSeparator()
      if menuItem("&Print to PDF...", "Ctrl+P"):
        picked = (if path.len > 0: path.changeFileExt(".pdf") else: "Untitled.pdf")
        pdfDlg = true
      menuSeparator()
      if menuItem("E&xit"):
        if text != saved: askExit = true else: quitApp()
    menu "&Edit":
      let (a, b) = selection()
      if menuItem("Cu&t", "Ctrl+X", enabled = b > a):
        putClipboardText(text[a ..< b])
        replaceSelection("")
      if menuItem("&Copy", "Ctrl+C", enabled = b > a): putClipboardText(text[a ..< b])
      if menuItem("&Paste", "Ctrl+V"): replaceSelection(getClipboardText())
      if menuItem("De&lete", "Del", enabled = b > a): replaceSelection("")
      menuSeparator()
      if menuItem("Select &All"): select(0, text.len)
      if menuItem("Time/&Date", "F5"): replaceSelection(now().format("HH:mm dd/MM/yyyy"))
    menu "&Search":
      if menuItem("&Find...", "Ctrl+F"): finder.open = true
      if menuItem("Find &Next", "F3"): findNext()
    menu "&Help":
      if menuItem("&About Notepad..."): showAbout = true

  # the keys of the menus that the text area does not handle itself
  if canInput() and not ui.keyUsed:
    let ctrl = CtrlPressed in ui.mods
    if ctrl and ui.key == KeyS:
      ui.keyUsed = true
      discard save()
    elif ctrl and ui.key == KeyO:
      ui.keyUsed = true
      openDlg = true
    elif ctrl and ui.key == KeyF:
      ui.keyUsed = true
      finder.open = true
    elif ui.key == KeyF3:
      ui.keyUsed = true
      findNext(ShiftPressed in ui.mods)
    elif ui.key == KeyF5:
      ui.keyUsed = true
      replaceSelection(now().format("HH:mm dd/MM/yyyy"))

  statusbar(if status.len > 0: status elif text == saved: "Saved" else: "Modified",
            $text.countLines & " lines", $text.len & " bytes")
  let fe = findBar(finder)
  if fe.next: findNext()
  if fe.prev: findNext(backwards = true)
  editArea text, lines = -1
  editorId = ui.lastId

  if hotkeyPressed("Ctrl+O"): openDlg = true
  if hotkeyPressed("Ctrl+S"): discard save()
  if hotkeyPressed("Ctrl+P"):
    picked = (if path.len > 0: path.changeFileExt(".pdf") else: "Untitled.pdf")
    pdfDlg = true
  if filePicker(openDlg, picked, fmOpen, ["*.txt", "*.md", "*.nim", "*.ini", "*.csv", "*"],
                "Open"):
    load(picked)
  if filePicker(saveDlg, picked, fmSave, ["*.txt"], "Save As"):
    discard saveTo(picked)
  if filePicker(pdfDlg, picked, fmSave, ["*.pdf"], "Print to PDF"):
    printToPdf(picked)

  case msgBox(askExit, "Notepad", "The text in " & docName() &
              " has changed.\n\nSave the changes?",
              ["&Yes", "&No", "Cancel"], miWarning)
  of 1:
    if save(): quitApp()
  of 2: quitApp()
  else: discard

  case msgBox(askNew, "Notepad", "The text in " & docName() &
              " has changed.\n\nStart a new one without saving?",
              ["&Yes", "&No"], miQuestion)
  of 1:
    text = ""
    saved = ""
    path = ""
  else: discard

  aboutBox(showAbout, "Notepad", RetroVersion,
           ["A small text editor made with Retro Nim UI."],
           tagline = "A small text editor", glyph = pxText)

## Retro Report -- the desktop app of the Retro UI Interface Guidelines (docs/hig.md): a small
## report editor that does what the guidelines ask of a program on a desktop, each rule with the
## call it takes. Read it beside them.
##
## - one copy running: started again, the first comes forward (`singleInstance`)
## - a menu bar of every command, with access keys and shortcuts; what an item does in the status
##   bar while it is lit (`hint`), the item a double click does in bold (`isDefault`)
## - a tool bar of the frequent commands, in groups, each with its tooltip
## - Undo and Redo of every change, named by what they undo (`UndoStack`)
## - help: What's This? (Shift+F1, Help menu) and F1 on the controls that need a word (`helpText`)
## - the report's properties in a property sheet: OK, Cancel, Apply, and a check box that says
##   "some are" (`propertySheet`, `CheckState`)
## - a tip at the start with "Don't show this again"; "Save changes?" before work is lost
##   (`closeGuard`)
## - in the Glass look the glass effect's tool bar groups, menus and buttons by themselves
##
##   nim c -r examples/higdesk.nim
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils]
import retroui, retroui/device

type
  Section = object
    name: string
    body: string
    inSummary: bool     ## (its first lines in the report's summary)
  Report = object
    title, author: string
    summaryLines: int   ## (how many lines of each section the summary takes)
    sections: seq[Section]

if not singleInstance("retroreport"): quit 0     # (the first copy comes forward instead)

var
  report = Report(title: "Annual Report", author: "Sultan", summaryLines: 2, sections: @[
    Section(name: "Introduction", inSummary: true,
            body: "A year of steady work: three new shops, the old one made new."),
    Section(name: "Sales", inSummary: false,
            body: "Sales grew by a fifth, the most in the second half."),
    Section(name: "Outlook", inSummary: true,
            body: "Two more shops next year, and the web shop.")])
  sel = 0
  history: UndoStack
  path = ""
  status = ""
  showStatusBar = true
  tipOpen = not restoreState("report.tipdone", false)
  tipDone = false
  aboutOpen = false
  saveDlg = false
  closeAfterSave = false  # (Save chosen as the window closed, the file still to be named)
  picked = ""
  # the property sheet works on copies, put in the report on OK and Apply
  propsOpen = false
  propsPage = 0
  propsChanged = false
  pTitle, pAuthor: string
  pSummary: CheckState
  pLines: int
  moreOpen = false

proc docName(): string =
  if path.len > 0: path.extractFilename.changeFileExt("") else: report.title

proc saveTo(p: string): bool =
  try:
    saveNif(p, report)
    path = p
    history.markClean()
    status = "Saved " & p.extractFilename
    true
  except CatchableError:
    status = "Could not save " & p.extractFilename & ": choose another folder"
    false

proc save(): bool =
  if path.len > 0: return saveTo(path)
  picked = report.title & ".report"
  saveDlg = true
  false                   # (not saved yet: the dialog asks where)

proc change(label: string; edit: proc ()) =
  ## (a change to the report, kept for Undo under its name)
  let before = report
  edit()
  history.record(label, report, before)

proc fillSheet() =
  pTitle = report.title
  pAuthor = report.author
  var each: seq[bool]
  for s in report.sections: each.add s.inSummary
  pSummary = mixedOf(each)
  pLines = report.summaryLines
  propsChanged = false

proc applySheet() =
  change("Properties") do ():
    report.title = pTitle
    report.author = pAuthor
    report.summaryLines = pLines
    if pSummary != csMixed:
      for s in report.sections.mitems: s.inSummary = pSummary == csOn

app "Retro Report", 720, 480:
  let wanted = docName() & (if history.changed: "*" else: "") & " - Retro Report"
  if ui.title != wanted: setTitle(wanted)

  menubar:
    menu "&File":
      if menuItem("&Save", "Ctrl+S", hint = "Saves the report"): discard save()
      if menuItem("Save &As...", hint = "Saves the report under another name"):
        picked = docName() & ".report"
        saveDlg = true
      menuSeparator()
      if menuItem("P&roperties...", hint = "The report's title, author and summary"):
        fillSheet()
        propsOpen = true
      menuSeparator()
      if menuItem("E&xit", hint = "Closes Retro Report"): requestClose()
    menu "&Edit":
      undoMenuItems(history)
      menuSeparator()
      if menuItem("&Add Section", "Ctrl+Enter", hint = "A new section after this one"):
        change("Add Section") do ():
          report.sections.insert(Section(name: "New Section"), sel + 1)
        inc sel
      if menuItem("&Delete Section", enabled = report.sections.len > 1,
                  hint = if report.sections.len > 1: "Takes this section out of the report"
                         else: "A report keeps one section at least"):
        change("Delete Section") do ():
          report.sections.delete(sel)
        sel = min(sel, report.sections.high)
    menu "&View":
      if menuItem("&Status Bar", checked = showStatusBar, hint = "Shows or hides the status bar"):
        showStatusBar = not showStatusBar
    menu "&Help":
      if menuItem("&What's This?", "Shift+F1", hint = "Click a control to see what it is for"):
        startHelpMode()
      menuSeparator()
      if menuItem("&About Retro Report", hint = "The program's version and its maker"):
        aboutOpen = true

  toolbar:
    if toolButton(nfSave, "Save (Ctrl+S)"): discard save()
    toolSeparator()
    if toolButton(nfUndo, "Undo", enabled = history.canUndo): history.undo()
    if toolButton(nfRedo, "Redo", enabled = history.canRedo): history.redo()
    toolSeparator()
    if toolButton(nfPlus, "Add Section (Ctrl+Enter)"):
      change("Add Section") do ():
        report.sections.insert(Section(name: "New Section"), sel + 1)
      inc sel
    if toolButton(nfInfo, "Properties"):
      fillSheet()
      propsOpen = true

  if showStatusBar:
    let hint = menuHint()
    statusbar(if hint.len > 0: hint
              elif status.len > 0: status
              elif history.changed: "Modified" else: "Ready",
              $report.sections.len & " sections")

  row([200, -1]):
    col:
      label "&Sections:"
      var names: seq[string]
      for s in report.sections: names.add s.name
      if listbox(names, sel, rows = -1): status = ""
      helpText "The report's sections, in order. Choose one to edit it on the right."
    col:
      form 90:
        field "&Name:":
          var name = report.sections[sel].name
          if edit(name):
            change("Rename") do (): report.sections[sel].name = name
        field "":
          var inSummary = report.sections[sel].inSummary
          if checkbox("In the s&ummary", inSummary):
            change("Summary") do (): report.sections[sel].inSummary = inSummary
          helpText "Its first lines go in the summary at the top of the printed report."
      var body = report.sections[sel].body
      if editArea(body, lines = -1):
        let before = report
        report.sections[sel].body = body
        history.record("Typing", report, before, merge = "typing" & $sel)

  undoKeys(history)
  if hotkeyPressed("Ctrl+S"): discard save()
  if hotkeyPressed("Ctrl+Enter"):
    change("Add Section") do ():
      report.sections.insert(Section(name: "New Section"), sel + 1)
    inc sel

  let answer = propertySheet(propsOpen, report.title & " Properties", propsPage,
                             ["General", "Summary"], 420, propsChanged):
    case propsPage
    of 0:
      form 80:
        field "&Title:":
          if edit(pTitle): propsChanged = true
        field "&Author:":
          if edit(pAuthor): propsChanged = true
    else:
      # (the sections differ: the box says so, mixed, until it is clicked)
      if checkbox("&All sections in the summary", pSummary): propsChanged = true
      helpText "On: every section's first lines in the summary; off: none. Mixed: as each " &
               "section says."
      unfoldButton("&Options", moreOpen)
      if moreOpen:
        row:
          label "&Lines of each:"
          if spin(pLines, 1, 5, w = 60): propsChanged = true
  if answer in {saOk, saApply}: applySheet()

  if filePicker(saveDlg, picked, fmSave, ["*.report"], "Save As"):
    if saveTo(picked) and closeAfterSave: quitApp()
  if not saveDlg: closeAfterSave = false    # (the dialog cancelled: the window stays)

  discard msgBox(tipOpen, "Retro Report", "Choose a section on the left to edit it. " &
                 "Shift+F1 and a click on a control says what it is for.", ["OK"], miInfo, tipDone)
  if tipDone: keepState("report.tipdone", tipDone)

  aboutBox(aboutOpen, "Retro Report", "1.0",
           ["The desktop app of the Retro UI Interface Guidelines."])

  closeGuard(history.changed, docName()) do () -> bool:
    closeAfterSave = true                  # (no file yet: closed once it is named and saved)
    save()

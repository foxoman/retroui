#> key(KeyF, {AltPressed})
#> shot("04-notepad--step2")
import std/os
import retroui

var text = ""
var path = ""
var opening, saving = false

app "Notepad", 380, 220:
  menubar:
    menu "&File":
      if menuItem("&New", "Ctrl+N"): (text = ""; path = "")
      if menuItem("&Open...", "Ctrl+O"): opening = true
      if menuItem("&Save", "Ctrl+S"): saving = true
      menuSeparator()
      if menuItem("E&xit"): quitApp()
  if hotkeyPressed("Ctrl+O"): opening = true        # a menu's shortcut is only its label:
  if hotkeyPressed("Ctrl+S"): saving = true         # the keys are read here
  editArea text, lines = -1
  if filePicker(opening, path, patterns = ["*.txt"]):
    text = readFile(path)
  if filePicker(saving, path, mode = fmSave, patterns = ["*.txt"]):
    writeFile(path, text)
  setTitle(if path.len > 0: path.extractFilename & " - Notepad" else: "Notepad")

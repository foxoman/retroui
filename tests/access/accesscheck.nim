## A small window for the screen readers' check on each system
## (tests/access/windows.ps1: UI Automation reads its controls and presses
## its button): a button, a check box, a text box. A press of the button
## is written to $RETRO_ACCESS_OUT ("pressed"); it ends after a minute.

import std/[os, times]
import retroui

var
  checked = true
  name = "Retro"
  presses = 0
let started = epochTime()
let outFile = getEnv("RETRO_ACCESS_OUT", "access.txt")

app "Access Check", 360, 220:
  wakeIn(200)
  label "A window for screen readers"
  if button("Press me"):
    inc presses
    writeFile(outFile, "pressed " & $presses)
  checkbox "Keep it", checked
  edit name
  if epochTime() - started > 60: quitApp()

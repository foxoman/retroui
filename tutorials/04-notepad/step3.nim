#> closeWindow()
#> shot("04-notepad--step3")
import retroui

var text = "A letter I have not saved"
var saved = ""                       # the text as it was last saved
var asking = false

app "Notepad", 380, 200:
  if closeRequested() and text != saved:   # the close box, Alt+F4, the phone's Back
    cancelClose()
    asking = true
  editArea text, lines = -1
  case msgBox(asking, "Notepad", "Save the changes?", ["&Save", "Do&n't Save", "Cancel"], miQuestion)
  of 1:
    saved = text                     # (write the file here)
    quitApp()
  of 2: quitApp()
  else: discard

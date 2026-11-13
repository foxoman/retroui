#> clickMark(0)
#> key(KeyEnd)
#> typeText(" 2026")
#> key(KeyE, {AltPressed})
#> shot("f-undo")
import retroui

var title = "Quarterly report"
var history: UndoStack

app "Report", 320, 130:
  menubar:
    menu "&Edit": undoMenuItems(history)     # "Undo Typing"; grayed when nothing
  let before = title
  if edit(title):                            # changed this frame: recorded
    history.record("Typing", title, before, merge = "title")
  mark "title"
  undoKeys(history)                          # Ctrl+Z, Ctrl+Y
  label(if history.changed: "Not saved" else: "Saved")

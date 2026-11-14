#> shot("04-notepad--step1")
import retroui

var text = "Shopping:\n- dates\n- coffee\n"

app "Notepad", 360, 200:
  editArea text, lines = -1          # -1: all the room left

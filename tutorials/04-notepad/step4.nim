#> shot("04-notepad--step4")
import std/strutils
import retroui

var text = "One line\nTwo lines\nThree lines, and more words"

app "Notepad", 380, 200:
  statusbar("Ready", $text.countLines & " lines", $text.splitWhitespace.len & " words")
  editArea text, lines = -1

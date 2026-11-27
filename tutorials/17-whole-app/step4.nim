#> phone(320, 520)
#> clickMark(0, 0.92, 0.5)
#> frames(4)
#> clickMark(0)
#> typeText("Drill plan")
#> key(KeyEnter)
#> typeText("The third floor at ten.")
#> shot("17-whole-app--step4")
import std/strutils
import retroui

var notes: seq[string]
var open = -1

uiLook = lookGloss

proc titleOf(n: string): string =
  for line in n.splitLines:
    if line.strip.len > 0: return line.strip
  "New Note"

app "Notes", 320, 520, GlossLight:
  if open < 0:
    if navBar("Notes", action = "New") == npAction:
      notes.add ""
      open = notes.high
    mark "new"
    tableGroup "":
      for i, n in notes:
        if tableRow(titleOf(n), "", taChevron, key = $i).clicked: open = i
  else:
    if navBar(titleOf(notes[open]), back = "Notes") == npBack or backPressed():
      cancelClose()
      open = -1
    else:
      editArea(notes[open], lines = -1)   # the rest of the page
      mark "text"

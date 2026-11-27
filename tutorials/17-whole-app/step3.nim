#> phone(320, 440)
#> clickMark(0, 0.92, 0.5)
#> frames(4)
#> clickMark(1, 0.08, 0.5)
#> shot("17-whole-app--step3")
import retroui

var tasks = @["Call the bank", "Book the hall", "Send the plan", "Buy dates"]
var editing = false

uiLook = lookGloss

app "Tasks", 320, 440, GlossLight:
  if navBar("Tasks", action = if editing: "Done" else: "Edit", done = editing) == npAction:
    editing = not editing
  mark "edit"
  tableGroup "":
    var e: RowEdit
    for i, t in tasks:
      if editing:
        let x = editRow(t, i)          # its minus, then Delete; its grip, dragged
        if x.kind != reNone: e = x
      else: discard tableRow(t)
      if i == 1: mark "second"
    case e.kind                        # the list changed after the rows were drawn
    of reDelete: tasks.delete(e.index)
    of reMove:
      let t = tasks[e.index]
      tasks.delete(e.index)
      tasks.insert(t, e.to)
    of reNone: discard

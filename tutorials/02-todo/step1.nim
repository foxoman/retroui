#> clickMark(0)
#> typeText("Buy dates")
#> key(KeyEnter)
#> typeText("Call the bank")
#> key(KeyEnter)
#> shot("02-todo--step1")
import retroui

var tasks: seq[string]
var newTask = ""
var sel = 0

app "To do", 320, 220:
  row([-1, 0]):
    edit newTask
    mark "new"
    if button("&Add", isDefault = true) and newTask.len > 0:
      tasks.add newTask
      newTask = ""
  listbox(tasks, sel, rows = 6)

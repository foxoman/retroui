#> clickMark(0)
#> typeText("Buy dates")
#> key(KeyEnter)
#> typeText("Call the bank")
#> key(KeyEnter)
#> typeText("Pay the rent")
#> key(KeyEnter)
#> clickMark(1, 0.1, 0.1)
#> shot("02-todo--step2")
import retroui

var tasks: seq[string]
var done: seq[bool]                   # a check box for each task
var newTask = ""

app "To do", 320, 240:
  row([-1, 0]):
    edit newTask
    mark "new"
    if button("&Add", isDefault = true) and newTask.len > 0:
      tasks.add newTask
      done.add false
      newTask = ""
  checkList(tasks, done, rows = 6)
  mark "list"
  row:
    if button("&Clear done", enabled = true in done):
      for i in countdown(tasks.high, 0):
        if done[i]:
          tasks.delete(i)
          done.delete(i)
    spring()
    var left = 0
    for d in done:
      if not d: inc left
    label $left & " left"

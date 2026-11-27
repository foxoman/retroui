#> phone(320, 520)
#> clickMark(0)
#> typeText("Call the bank")
#> key(KeyEnter)
#> typeText("Book the hall")
#> key(KeyEnter)
#> typeText("Send the plan")
#> key(KeyEnter)
#> clickMark(1, 0.08, 0.5)
#> shot("17-whole-app--step1")
import std/[json, os]
import retroui

type Task = object
  title: string
  done: bool

var tasks: seq[Task]
var newTitle = ""

proc save() =                        # the app's own folder, on every system
  createDir(dataDir("MyTasks"))
  writeFile(dataDir("MyTasks") / "tasks.json", $(%tasks))

uiLook = lookGloss                   # the phone look of its time

app "Tasks", 320, 520, GlossLight:
  discard navBar("Tasks")
  row([-1, 0]):
    edit(newTitle, hint = "New task")
    mark "new"
    if button("Add") or keyHit(KeyEnter):
      if newTitle.len > 0:
        tasks.add Task(title: newTitle)
        newTitle = ""
        save()
  tableGroup "":
    for i, t in tasks.mpairs:
      let h = checkRow(t.title, t.done, key = $i)   # a tap on its circle ticks it
      if i == 0: mark "first"
      if h.toggled: save()

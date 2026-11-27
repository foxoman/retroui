#> phone(320, 560)
#> clickMark(0)
#> frames(4)
#> clickMark(0, 0.88, 0.5)
#> frames(4)
#> shot("17-whole-app--step2")
import retroui

type Task = object
  title: string
  done: bool
  hasDay: bool
  day: Date
  priority: int

var tasks = @[Task(title: "Call the bank"), Task(title: "Book the hall")]
var tab = 0
var open = -1                         # the task whose page is shown (-1: the list)

uiLook = lookGloss

app "Tasks", 320, 560, GlossLight:
  discard bottomNav([(nfCheck, "Tasks"), (nfFileText, "Notes")], tab)
  if open < 0:
    discard navBar("Tasks")
    tableGroup "":
      for i, t in tasks.mpairs:
        if checkRow(t.title, t.done, accessory = taChevron, key = $i).clicked: open = i
        if i == 0: mark "first"
  else:
    template t: untyped = tasks[open]
    if navBar("Task", back = "Tasks") == npBack or backPressed():   # its Back, the phone's
      cancelClose()
      open = -1
    else:
      edit t.title
      tableGroup "Due":
        if tableSwitch("On a Day", t.hasDay, glyph = nfCalendar): t.day = today()
        mark "on a day"
      if t.hasDay: dateWheels(t.day)
      segmented(["None", "Low", "Medium", "High"], t.priority)

## Tests of Retro Tasks (examples/tasks): tasks in lists -- their order, done or not, late or
## not, their day written --, the lists made by themselves, notes (their titles, pinned first),
## the search, the reminders raised once, the file kept and read back; then the app worked by
## taps: a check ticked, a task opened and its day set, a list's Edit (a task dragged, one
## deleted), a note written, the phone's Back -- every page drawn in every look.

import std/[os, times, json]
import retroui
import retroui/business
import ../examples/tasks/[model, screens]
import harness

let home = getTempDir() / "retro-tasks-test"
removeDir(home)
createDir(home)
putEnv("HOME", home)
putEnv("XDG_DATA_HOME", home / ".local" / "share")
putEnv("RETRO_TOUCH", "1")                # (a phone: its Back, finger-sized rows)

var passed = 0
template check(cond: bool; what: string) =
  doAssert cond, what
  inc passed
  echo "  ok   ", what

# ---- the data -----------------------------------------------------------------------------------

loadStore()
check store.lists.len == 2 and store.tasks.len == 0, "the first time: two lists, no tasks"
let a = newTask("  Call the bank  ", "Reminders")
let b = newTask("Book the hall", "Reminders")
let c = newTask("Send the plan", "Reminders")
let d = newTask("Dates", "Shopping")
check store.tasks[find(a)].title == "Call the bank", "a task's title, its spaces cut"
check inList("Reminders").len == 3 and inList("Shopping").len == 1, "tasks in their lists"
store.tasks[find(a)].due = today()
store.tasks[find(b)].due = today().addDays(3)
store.tasks[find(c)].due = today().addDays(-1)
store.tasks[find(d)].flagged = true
check overdue(store.tasks[find(c)]) and not overdue(store.tasks[find(a)]), "yesterday's late, today's not"
check dueText(store.tasks[find(a)]) == "Today" and dueText(store.tasks[find(c)]) == "Yesterday", "its day written"
store.tasks[find(a)].dueTime = 9 * 60 + 5
check dueText(store.tasks[find(a)]) == "Today 9:05", "... with its time"
check smart(slToday).len == 2 and smart(slUpcoming).len == 1 and smart(slFlagged).len == 1, "Today, Upcoming, Flagged"
setDone(c, true)
check smart(slCompleted).len == 1 and inList("Reminders").len == 2 and inList("Reminders", withDone = true).len == 3,
      "done: in Completed, out of its list"
moveInList("Reminders", 1, 0)
check store.tasks[inList("Reminders")[0]].id == b, "put in order: the second first"
# notes
let n1 = newNote("Drill plan\n\nThe third floor at ten.\nTell the desk.")
let n2 = newNote("")
check noteTitle(store.notes[findNote(n1)]) == "Drill plan" and noteTitle(store.notes[findNote(n2)]) == "New Note",
      "a note's title: its first line"
check notePreview(store.notes[findNote(n1)]) == "The third floor at ten. Tell the desk.", "its preview: the lines after"
store.notes[findNote(n1)].pinned = true
store.notes[findNote(n2)].updated = epochTime() + 10
check store.notes[sortedNotes()[0]].id == n1, "pinned first, though the other changed later"
check searchTasks("hall").len == 1 and searchNotes("desk").len == 1 and searchTasks("").len == 0, "the search"
# reminders: once
store.tasks[find(a)].remind = true
store.tasks[find(a)].dueTime = 0
check dueReminders(epochTime()).len == 1, "a reminder due"
discard raiseReminders()
check store.tasks[find(a)].reminded and dueReminders(epochTime()).len == 0, "raised once"
# kept and read back
saveStore()
let kept = store
store = Store()
loadStore()
check store.tasks.len == 4 and store.notes.len == 2 and store.tasks[find(c)].done and
      store.notes[findNote(n1)].pinned and store.tasks[find(a)].dueTime == 0 and store.nextId == kept.nextId,
      "kept in its file, read back the same"
check parseJson(readFile(storePath()))["version"].getInt == 1, "a file with its version"

# ---- the app, by taps --------------------------------------------------------------------------

fakeDriver()
startApp("tasks", W, H)
splitAt = 100_000                         # (a phone first: the pages one over another)
uiLook = lookGloss
ui.theme = GlossLight
var rows: seq[Rect]
view = proc () =
  tasksView()
run(3)
push("list:Reminders")
run(3)
# (a row's check tapped: the task done; the rest of the row: its page)
let first = store.tasks[inList("Reminders")[0]]
let before = inList("Reminders").len
var r: Rect
view = proc () =
  tableGroup(""):
    taskRows(inList("Reminders", withDone = true), "x")
    r = ui.lastRect
run(2)
let firstRow = rect(r.x, r.y - (inList("Reminders", withDone = true).len - 1) * r.h, r.w, r.h)
click(firstRow, dx = 22, dy = r.h div 2)
check store.tasks[find(first.id)].done and inList("Reminders").len == before - 1, "its check tapped: done"
run(2)
let all = inList("Reminders", withDone = true)
let k = all.find(find(first.id))         # (done: it went down, among the done ones)
click(rect(r.x, r.y - (all.len - 1 - k) * r.h, r.w, r.h), dx = 22, dy = r.h div 2)
check not store.tasks[find(first.id)].done, "tapped again where it went: not done"
run(2)
click(firstRow, dx = r.w div 2, dy = r.h div 2)
check page() == "task:" & $first.id, "the rest of the row: its page"
back()
view = proc () =
  tasksView()
run(2)
# (Edit: a task deleted with Delete on the focused row)
editing = true
run(3)
proc reddish(p: uint32): bool =
  let (rr, gg, bb) = (int((p shr 16) and 255), int((p shr 8) and 255), int(p and 255))
  rr > 150 and gg < 90 and bb < 100
# (a row's red minus, then the red Delete that comes at the row's end)
var minus = (-1, -1)
for y in 40 ..< H:
  if minus[0] >= 0: break
  for x in 0 ..< 80:
    if reddish(px(x, y)):
      minus = (x + 4, y + 6)
      break
check minus[0] >= 0, "Edit: the rows' red minus"
click(rect(minus[0], minus[1], 1, 1), dx = 0, dy = 0)
run(2)
var del = -1
for x in countdown(W - 1, W div 2):
  if reddish(px(x, minus[1])):
    del = x - 6
    break
check del > 0, "its Delete at the row's end"
click(rect(del, minus[1], 1, 1), dx = 0, dy = 0)
run(3)
check inList("Reminders").len == before - 1, "Delete: the task deleted (" & $inList("Reminders").len & ")"
editing = false
# (a task's page: its day on the wheels, its title)
push("task:" & $b)
run(3)
check page() == "task:" & $b, "a task's page"
# (the phone's Back: back a page)
key(KeyEsc)
run(3)
check page() == "list:Reminders" and appRunning(), "the phone's Back: a page back, the app still on"
back()
# (every page, every look)
for look in [lookClassic, lookGlass, lookMatte, lookGloss]:
  uiLook = look
  ui.theme = lookSchemes(look).light
  for t in 0 .. 3:
    tab = t
    run(2)
  tab = 0
  for p in ["list:Reminders", "smart:Today", "smart:Upcoming", "smart:Flagged", "smart:Completed",
            "task:" & $a]:
    stacks[0] = @["home", p]
    run(2)
  editing = true
  stacks[0] = @["home", "list:Reminders"]
  run(2)
  editing = false
  tab = 1
  stacks[1] = @["notes", "note:" & $n1]
  run(2)
  tab = 2
  query = "plan"
  run(2)
  query = ""
check true, "every page drawn in every look"
# ---- a tablet: the lists down the left, the page chosen beside them -----------------------------
splitAt = 600
uiLook = lookGloss
ui.theme = GlossLight
tab = 0
stacks[0] = @["home"]
run(3)
check stacks[0].len == 2 and stacks[0][1] == "list:" & store.lists[0].name,
      "a tablet: the first list beside the lists, by itself"
# (a list tapped on the left: its page beside it, in place -- not over it)
var shopRow = -1
for y in countup(60, H - 60, 2):
  if shopRow >= 0: break
  # (the left column's rows: a tap on each, until Shopping is beside them)
  click(rect(40, y, 1, 1), dx = 0, dy = 0)
  run(1)
  if page() == "list:Shopping": shopRow = y
check shopRow >= 0 and stacks[0] == @["home", "list:Shopping"], "Shopping tapped on the left: beside it, in place"
key(KeyEsc)
run(3)
check not appRunning() and stacks[0].len == 2,
      "the phone's Back with a list beside the lists: nothing to go back to, the app closes"
ui.running = true
for look in [lookClassic, lookGlass, lookMatte, lookGloss]:
  uiLook = look
  ui.theme = lookSchemes(look).light
  for t in 0 .. 3:
    tab = t
    stacks[t] = @[stacks[t][0]]
    run(2)
  tab = 0
  stacks[0] = @["home", "list:Reminders", "task:" & $a]
  run(2)
check true, "a tablet's pages drawn in every look"
uiLook = lookClassic
ui.theme = Classic
removeDir(home)
echo "tasks: ", passed, " ok"

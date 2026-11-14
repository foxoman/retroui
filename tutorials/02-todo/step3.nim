#> shot("02-todo--step3")
import std/[os, strutils]
import retroui

let file = dataDir("TodoTutorial") / "tasks.txt"   # a folder only this app writes to

var tasks: seq[string] = @[]
var done: seq[string] = @[]
if fileExists(file):                               # read once, when the app starts
  for line in readFile(file).splitLines:
    if line.len > 2:
      done.add line[0 .. 0]
      tasks.add line[2 .. ^1]
if tasks.len == 0:
  tasks = @["Buy dates", "Call the bank"]
  done = @["0", "0"]
var checks: seq[bool]
for d in done: checks.add d == "1"
var newTask = ""

proc save() =
  var text = ""
  for i, t in tasks: text.add (if checks[i]: "1 " else: "0 ") & t & "\n"
  writeFile(file, text)

app "To do", 320, 240:
  row([-1, 0]):
    edit newTask
    if button("&Add", isDefault = true) and newTask.len > 0:
      tasks.add newTask
      checks.add false
      newTask = ""
      save()                                       # saved when it changes
  if checkList(tasks, checks, rows = 6): save()
  if button("&Clear done", enabled = true in checks):
    for i in countdown(tasks.high, 0):
      if checks[i]:
        tasks.delete(i)
        checks.delete(i)
    save()

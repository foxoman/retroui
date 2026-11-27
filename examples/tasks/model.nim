## Retro Tasks' data, without a window: tasks in lists -- their due day and time, a reminder, a
## priority, a flag, notes, done or not, their order --, the lists made by themselves (Today,
## Upcoming, Flagged, Completed), notes (pinned ones first), a search through both; all kept in
## one JSON file in the app's folder, written a moment after a change. The reminders that are
## due: raised by the window, and by the background check while the app is closed (Android).

import std/[json, os, strutils, times, algorithm]
import retroui/[business, notify, core]
import retroui/uirelays/services

type
  Priority* = enum
    prNone = "None", prLow = "Low", prMedium = "Medium", prHigh = "High"
  Task* = object
    id*: int
    title*, notes*: string
    list*: string                ## the list it is in
    due*: Date                   ## its day (year 0: none)
    dueTime*: int                ## minutes after midnight (-1: the whole day)
    remind*: bool                ## a notification when it is due
    reminded*: bool              ## (it was raised)
    priority*: Priority
    flagged*: bool
    done*: bool
    doneAt*: float
    created*: float
    order*: int                  ## its place in its list
  Note* = object
    id*: int
    text*: string                ## its first line is its title
    pinned*: bool
    created*, updated*: float
  TaskList* = object
    name*: string
    tint*: int                   ## (one of `ListTints`)
  SmartList* = enum
    slToday = "Today", slUpcoming = "Upcoming", slFlagged = "Flagged", slCompleted = "Completed"
  Store* = object
    tasks*: seq[Task]
    notes*: seq[Note]
    lists*: seq[TaskList]
    nextId*: int
    showDone*: bool              ## a list shows its done tasks too
    reminders*: bool             ## reminders raised (and checked while the app is closed)
    badge*: bool                 ## the app's icon counts what is due today

const
  AppKey* = "RetroTasks"
  ListTints* = [(36, 110, 220), (236, 140, 20), (30, 160, 90), (220, 50, 60), (150, 90, 210),
                (128, 128, 136)]

var store*: Store
var dirtyAt = 0.0                ## (when it changed: written a moment after)

proc storePath*(): string = dataDir(AppKey) / "tasks.json"

proc noDate*(): Date = Date()
proc hasDue*(t: Task): bool = t.due.year > 0

# ---- kept: one JSON file --------------------------------------------------------------------------

proc toJson(d: Date): JsonNode = %*[d.year, d.month, d.day]
proc dateOf(j: JsonNode): Date =
  if j != nil and j.kind == JArray and j.len == 3: Date(year: j[0].getInt, month: j[1].getInt, day: j[2].getInt)
  else: Date()

proc toJson*(s: Store): JsonNode =
  var ts = newJArray()
  for t in s.tasks:
    ts.add %*{"id": t.id, "title": t.title, "notes": t.notes, "list": t.list, "due": toJson(t.due),
              "time": t.dueTime, "remind": t.remind, "reminded": t.reminded, "priority": ord(t.priority),
              "flag": t.flagged, "done": t.done, "doneAt": t.doneAt, "created": t.created, "order": t.order}
  var ns = newJArray()
  for n in s.notes:
    ns.add %*{"id": n.id, "text": n.text, "pinned": n.pinned, "created": n.created, "updated": n.updated}
  var ls = newJArray()
  for l in s.lists: ls.add %*{"name": l.name, "tint": l.tint}
  %*{"version": 1, "tasks": ts, "notes": ns, "lists": ls, "next": s.nextId, "showDone": s.showDone,
     "reminders": s.reminders, "badge": s.badge}

proc storeOf*(j: JsonNode): Store =
  result.nextId = max(1, j{"next"}.getInt(1))
  result.showDone = j{"showDone"}.getBool(false)
  result.reminders = j{"reminders"}.getBool(true)
  result.badge = j{"badge"}.getBool(true)
  for l in j{"lists"}.getElems: result.lists.add TaskList(name: l{"name"}.getStr, tint: l{"tint"}.getInt)
  for t in j{"tasks"}.getElems:
    result.tasks.add Task(id: t{"id"}.getInt, title: t{"title"}.getStr, notes: t{"notes"}.getStr,
                          list: t{"list"}.getStr, due: dateOf(t{"due"}), dueTime: t{"time"}.getInt(-1),
                          remind: t{"remind"}.getBool, reminded: t{"reminded"}.getBool,
                          priority: Priority(clamp(t{"priority"}.getInt, 0, 3)), flagged: t{"flag"}.getBool,
                          done: t{"done"}.getBool, doneAt: t{"doneAt"}.getFloat,
                          created: t{"created"}.getFloat, order: t{"order"}.getInt)
  for n in j{"notes"}.getElems:
    result.notes.add Note(id: n{"id"}.getInt, text: n{"text"}.getStr, pinned: n{"pinned"}.getBool,
                          created: n{"created"}.getFloat, updated: n{"updated"}.getFloat)

proc firstStore*(): Store =
  ## (the first time: two lists, a task or two to show how it goes)
  result = Store(nextId: 1, reminders: true, badge: true,
                 lists: @[TaskList(name: "Reminders", tint: 0), TaskList(name: "Shopping", tint: 2)])

proc loadStore*() =
  ## The tasks and notes as they were kept (the first time: an empty start).
  try: store = storeOf(parseJson(readFile(storePath())))
  except CatchableError: store = firstStore()
  if store.lists.len == 0: store.lists.add TaskList(name: "Reminders")

proc saveStore*() =
  try:
    createDir(dataDir(AppKey))
    let tmp = storePath() & ".new"
    writeFile(tmp, $toJson(store))
    moveFile(tmp, storePath())
  except CatchableError: discard
  dirtyAt = 0

proc touched*() =
  ## (something changed: written in a moment)
  if dirtyAt == 0: dirtyAt = epochTime()

proc saveSoon*() =
  ## Every frame: written two seconds after the last change.
  if dirtyAt > 0 and epochTime() - dirtyAt > 2: saveStore()
  elif dirtyAt > 0: wakeIn(2100)

# ---- tasks ----------------------------------------------------------------------------------------

proc find*(id: int): int =
  for i, t in store.tasks:
    if t.id == id: return i
  -1

proc newTask*(title, list: string): int =
  ## A task at the end of `list`; its id.
  var last = -1
  for t in store.tasks:
    if t.list == list: last = max(last, t.order)
  result = store.nextId
  inc store.nextId
  store.tasks.add Task(id: result, title: title.strip, list: list, dueTime: -1, created: epochTime(),
                       order: last + 1)
  touched()

proc setDone*(id: int; done: bool) =
  let i = find(id)
  if i < 0: return
  store.tasks[i].done = done
  store.tasks[i].doneAt = if done: epochTime() else: 0.0
  touched()

proc deleteTask*(id: int) =
  let i = find(id)
  if i >= 0:
    store.tasks.delete(i)
    touched()

proc dueAt*(t: Task): float =
  ## When it is due (seconds since 1970, local time; the whole day: 9 in the morning).
  if not t.hasDue: return 0
  let mins = if t.dueTime >= 0: t.dueTime else: 9 * 60
  try:
    dateTime(t.due.year, Month(t.due.month), MonthdayRange(t.due.day), mins div 60, mins mod 60, 0, 0,
             local()).toTime.toUnixFloat
  except CatchableError: 0.0

proc todayDate*(): Date = today()

proc overdue*(t: Task): bool =
  ## Not done, and its day (or its time) has gone.
  if t.done or not t.hasDue: return false
  if t.dueTime < 0: dayNumber(t.due) < dayNumber(todayDate())
  else: dueAt(t) < epochTime()

proc dueText*(t: Task): string =
  ## ("Today", "Tomorrow 9:30", "Mon 3 Dec", "" none)
  if not t.hasDue: return ""
  let n = dayNumber(t.due) - dayNumber(todayDate())
  result = case n
    of 0: "Today"
    of 1: "Tomorrow"
    of -1: "Yesterday"
    else:
      ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][weekday(t.due) mod 7] & " " & $t.due.day & " " &
        ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][clamp(t.due.month, 1, 12) - 1]
  if t.dueTime >= 0: result.add " " & $(t.dueTime div 60) & ":" & align($(t.dueTime mod 60), 2, '0')

proc inList*(list: string; withDone = false): seq[int] =
  ## The tasks of a list, in their order (done ones last, when asked for).
  for i, t in store.tasks:
    if t.list == list and (withDone or not t.done): result.add i
  result.sort(proc (a, b: int): int =
    result = cmp(store.tasks[a].done, store.tasks[b].done)
    if result == 0: result = cmp(store.tasks[a].order, store.tasks[b].order))

proc smart*(k: SmartList): seq[int] =
  ## The tasks of a list made by itself: Today (due today or late), Upcoming (a day ahead, by
  ## day), Flagged, Completed (the last done first).
  let t0 = dayNumber(todayDate())
  for i, t in store.tasks:
    case k
    of slToday: (if not t.done and t.hasDue and dayNumber(t.due) <= t0: result.add i)
    of slUpcoming: (if not t.done and t.hasDue and dayNumber(t.due) > t0: result.add i)
    of slFlagged: (if not t.done and t.flagged: result.add i)
    of slCompleted: (if t.done: result.add i)
  case k
  of slCompleted: result.sort(proc (a, b: int): int = cmp(store.tasks[b].doneAt, store.tasks[a].doneAt))
  of slToday, slUpcoming: result.sort(proc (a, b: int): int = cmp(dueAt(store.tasks[a]), dueAt(store.tasks[b])))
  else: discard

proc moveInList*(list: string; src, dst: int) =
  ## The task at `src` of the list (as `inList` gives it) put at `dst`.
  let idx = inList(list)
  if src < 0 or src >= idx.len or dst < 0 or dst >= idx.len or src == dst: return
  var order = idx
  let x = order[src]
  order.delete(src)
  order.insert(x, dst)
  for k, i in order: store.tasks[i].order = k
  touched()

proc renameList*(old, name: string) =
  for l in store.lists.mitems:
    if l.name == old: l.name = name
  for t in store.tasks.mitems:
    if t.list == old: t.list = name
  touched()

proc deleteList*(name: string) =
  ## The list and its tasks.
  var i = 0
  while i < store.tasks.len:
    if store.tasks[i].list == name: store.tasks.delete(i) else: inc i
  for k, l in store.lists:
    if l.name == name:
      store.lists.delete(k)
      break
  touched()

# ---- notes ----------------------------------------------------------------------------------------

proc newNote*(text = ""): int =
  result = store.nextId
  inc store.nextId
  let now = epochTime()
  store.notes.add Note(id: result, text: text, created: now, updated: now)
  touched()

proc findNote*(id: int): int =
  for i, n in store.notes:
    if n.id == id: return i
  -1

proc noteTitle*(n: Note): string =
  ## (its first line that has words: its title; "New Note" while it has none)
  for ln in n.text.splitLines:
    if ln.strip.len > 0: return ln.strip
  "New Note"

proc notePreview*(n: Note): string =
  ## (what follows its title, on one line)
  var seen = false
  for ln in n.text.splitLines:
    if ln.strip.len == 0: continue
    if not seen:
      seen = true
      continue
    result.add (if result.len > 0: " " else: "") & ln.strip
    if result.len > 80: break

proc sortedNotes*(): seq[int] =
  ## Pinned first, then the last changed first.
  for i in 0 ..< store.notes.len: result.add i
  result.sort(proc (a, b: int): int =
    result = cmp(store.notes[b].pinned, store.notes[a].pinned)
    if result == 0: result = cmp(store.notes[b].updated, store.notes[a].updated))

proc whenText*(t: float): string =
  ## ("10:42" today, "Yesterday", "3 Dec")
  if t <= 0: return ""
  let d = fromUnixFloat(t).local
  let n = now()
  if d.year == n.year and d.yearday == n.yearday: d.format("H:mm")
  elif d.year == n.year and d.yearday == n.yearday - 1: "Yesterday"
  else: d.format("d MMM")

# ---- search ----------------------------------------------------------------------------------------

proc searchTasks*(q: string): seq[int] =
  let w = q.strip.toLowerAscii
  if w.len == 0: return
  for i, t in store.tasks:
    if w in t.title.toLowerAscii or w in t.notes.toLowerAscii or w in t.list.toLowerAscii: result.add i

proc searchNotes*(q: string): seq[int] =
  let w = q.strip.toLowerAscii
  if w.len == 0: return
  for i, n in store.notes:
    if w in n.text.toLowerAscii: result.add i

# ---- reminders ------------------------------------------------------------------------------------

proc dueReminders*(now: float): seq[int] =
  ## The tasks whose reminder is due and not raised yet.
  for i, t in store.tasks:
    if t.remind and not t.reminded and not t.done and t.hasDue and dueAt(t) <= now: result.add i

proc raiseReminders*(): int =
  ## Each due reminder as a notification of the system (once); how many.
  if not store.reminders: return 0
  for i in dueReminders(epochTime()):
    let t = store.tasks[i]
    discard notify(t.title, (if t.notes.len > 0: t.notes else: t.list & ": " & dueText(t)), app = "Retro Tasks",
                   tag = "task" & $t.id)
    store.tasks[i].reminded = true
    inc result
  if result > 0: touched()

proc dueTodayCount*(): int =
  smart(slToday).len

proc backgroundCheck*() {.nimcall, gcsafe.} =
  ## (while the app is closed: the file read, its reminders raised, the icon's count, kept)
  {.cast(gcsafe).}:
    loadStore()
    if raiseReminders() > 0: saveStore()
    if store.badge: setBadge(dueTodayCount())

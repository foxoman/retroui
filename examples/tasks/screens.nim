## Retro Tasks' screens: Tasks (the lists made by themselves, your lists, a list's tasks -- ticked
## off with their round checks, put in order in Edit --, a task's page: its day and time on wheels,
## a reminder, a flag, a priority, notes), Notes (on lined paper in Gloss), Search through both,
## Settings. A tab bar and pages with a navigation bar on a phone; on a tablet or a computer the
## tab's first page in a column down the left -- the lists, the notes, the search, the settings
## -- and the page chosen beside it, under its own bar. (examples/tasks.nim opens the window;
## tests/test_tasks.nim works it.)

import std/[strutils, times]
import retroui
import retroui/[notify, bgcheck]
import model

const TasksVersion* = "1.0.1"

var
  tab* = 0                               ## Tasks, Notes, Search, Settings
  stacks*: array[4, seq[string]] = [@["home"], @["notes"], @["search"], @["settings"]]
  editing* = false                       ## a list's Edit: its tasks put in order, taken out
  newTitle* = ""                         ## (a list's field for a new task)
  query* = ""
  listOpen, newListOpen, deleteListOpen, aboutOpen*, moveOpen = false
  newListName = ""
  movingId = 0                           ## (the task whose list is being chosen)
  message* = ""
  splitAt* = 600                         ## the width (design pixels) from which the pages sit
                                         ## beside the tab's first one: a tablet's, a computer's
  drawingLeft = false                    ## (the left column is being drawn: a row tapped there
                                         ## puts its page beside it, instead of over it)

proc split*(): bool =
  ## A tablet or a computer: the tab's first page down the left, the page chosen beside it.
  float(ui.w) / max(0.1, ui.k) >= float(splitAt)

proc page*(): string = stacks[tab][^1]
proc dropEmpty(p: string) =
  ## (a note left empty: not kept)
  if p.startsWith("note:"):
    let i = findNote(parseInt(p[5 .. ^1]))
    if i >= 0 and store.notes[i].text.strip.len == 0:
      store.notes.delete(i)
      touched()

proc push*(p: string) =
  if drawingLeft and split():
    # (beside the list, in place of what was there)
    for old in stacks[tab][1 .. ^1]:
      if old != p: dropEmpty(old)
    stacks[tab] = @[stacks[tab][0], p]
  else: stacks[tab].add p
  editing = false

proc chosen(p: string): bool =
  ## (a row of the left column whose page is shown beside it: drawn chosen)
  split() and stacks[tab].len > 1 and stacks[tab][1] == p
proc back*() =
  if stacks[tab].len > 1:
    let leaving = stacks[tab].pop()
    editing = false
    dropEmpty(leaving)

proc arg(): string =
  let p = page()
  let c = p.find(':')
  if c < 0: "" else: p[c + 1 .. ^1]

proc tintOf(list: string): Color =
  for l in store.lists:
    if l.name == list:
      let (r, g, b) = ListTints[clamp(l.tint, 0, ListTints.high)]
      return color(uint8(r), uint8(g), uint8(b))
  color(36, 110, 220)

# ---- tasks ----------------------------------------------------------------------------------------

proc taskRows*(idx: openArray[int]; key: string; showList = false) =
  ## (tasks with their round checks: a tap on the check ticks it, on the row opens it)
  for i in idx:
    var t = store.tasks[i]
    var done = t.done
    let h = checkRow(t.title, done, detail = dueText(t), subtitle = (if showList: t.list else: ""),
                     accessory = taChevron, flagged = t.flagged,
                     detailColor = if overdue(t): color(220, 40, 40) else: Color(), key = key & $t.id)
    if h.toggled: setDone(t.id, done)
    elif h.clicked: push("task:" & $t.id)

proc homePage() =
  tableGroup(""):
    let glyphs = [nfCalendar, nfClock, nfFlag, nfCheck]
    let tints = [color(36, 110, 220), color(220, 50, 60), color(255, 149, 0), color(128, 128, 136)]
    for k in SmartList:
      let n = smart(k).len
      if tableRow($k, if n > 0: $n else: "", taChevron, glyph = glyphs[ord(k)], tint = tints[ord(k)],
                  key = "s" & $k, selected = chosen("smart:" & $k)).clicked: push("smart:" & $k)
  tableGroup("My Lists"):
    for l in store.lists:
      let n = inList(l.name).len
      if tableRow(l.name, if n > 0: $n else: "", taChevron, glyph = nfListUl, tint = tintOf(l.name),
                  key = "l" & l.name, selected = chosen("list:" & l.name)).clicked: push("list:" & l.name)
    if tableButton("Add List..."):
      newListName = ""
      newListOpen = true

proc addField(list: string) =
  ## (a new task's field at the top of a list: Enter or Add puts it in)
  var go = false
  row([-1, 0]):
    if edit(newTitle, hint = "New task"): discard
    if keyHit(KeyEnter) and newTitle.strip.len > 0: go = true
    if button("Add", nfPlus, enabled = newTitle.strip.len > 0): go = true
  if go:
    discard newTask(newTitle, list)
    newTitle = ""

proc listPage(list: string) =
  addField(list)
  let idx = inList(list)
  if idx.len == 0 and not store.showDone:
    emptyState(nfCheck, "Nothing to do", detail = "Type a task above and press Add.")
  elif editing:
    var e: RowEdit
    tableGroup("", "Drag a task by its grip to put it elsewhere; its minus deletes it."):
      for n, i in idx:
        let t = store.tasks[i]
        let x = editRow(t.title, n, detail = dueText(t), key = "e" & $t.id)
        if x.kind != reNone: e = x
    case e.kind
    of reDelete: deleteTask(store.tasks[idx[e.index]].id)
    of reMove: moveInList(list, e.index, e.to)
    of reNone: discard
  else:
    tableGroup(""):
      taskRows(idx, "t")
    if store.showDone:
      var done: seq[int]
      for i in inList(list, withDone = true):
        if store.tasks[i].done: done.add i
      if done.len > 0:
        tableGroup("Completed"):
          taskRows(done, "d")
  tableGroup(""):
    if tableButton(if store.showDone: "Hide Completed" else: "Show Completed"):
      store.showDone = not store.showDone
      touched()
    if tableButton("Delete List...", destructive = true): deleteListOpen = true

proc smartPage(k: SmartList) =
  let idx = smart(k)
  if idx.len == 0:
    emptyState(nfCheck, case k
      of slToday: "Nothing due today"
      of slUpcoming: "Nothing coming up"
      of slFlagged: "Nothing flagged"
      of slCompleted: "Nothing done yet")
    return
  if k == slUpcoming:
    # (by day: a group each)
    var day = Date()
    var group: seq[int]
    proc flush() =
      if group.len > 0:
        tableGroup(dueText(Task(due: day, dueTime: -1))):
          taskRows(group, "u" & $day.day, showList = true)
        group.setLen(0)
    for i in idx:
      let t = store.tasks[i]
      if t.due != day:
        flush()
        day = t.due
      group.add i
    flush()
  else:
    tableGroup(""):
      taskRows(idx, "s", showList = true)
    if k == slCompleted:
      tableGroup(""):
        if tableButton("Clear Completed", destructive = true):
          var i = 0
          while i < store.tasks.len:
            if store.tasks[i].done: store.tasks.delete(i) else: inc i
          touched()

proc taskPage(id: int) =
  let i = find(id)
  if i < 0:
    emptyState(nfCheck, "This task is gone")
    return
  template t: untyped = store.tasks[i]
  if edit(t.title, hint = "Title"): touched()
  tableGroup(""):
    var done = t.done
    if tableSwitch("Done", done, glyph = nfCheck, tint = color(30, 160, 90)): setDone(id, done)
    var flag = t.flagged
    if tableSwitch("Flagged", flag, glyph = nfFlag, tint = color(255, 149, 0)):
      t.flagged = flag
      touched()
    if tableRow("List", t.list, taChevron, glyph = nfListUl, tint = tintOf(t.list)).clicked:
      movingId = id
      moveOpen = true
  tableGroup("Due"):
    var has = t.hasDue
    if tableSwitch("On a Day", has, glyph = nfCalendar, tint = color(36, 110, 220)):
      t.due = if has: todayDate() else: noDate()
      t.reminded = false
      touched()
    if has:
      var timed = t.dueTime >= 0
      if tableSwitch("At a Time", timed, glyph = nfClock, tint = color(220, 50, 60)):
        t.dueTime = if timed: 9 * 60 else: -1
        t.reminded = false
        touched()
      var remind = t.remind
      if tableSwitch("Remind Me", remind, glyph = nfBell, tint = color(150, 90, 210)):
        t.remind = remind
        t.reminded = false
        touched()
  if t.hasDue:
    var d = t.due
    if dateWheels(d, years = 2000 .. 2100):
      t.due = d
      t.reminded = false
      touched()
    if t.dueTime >= 0:
      var h = t.dueTime div 60
      var m = t.dueTime mod 60
      if timeWheels(h, m, minuteStep = 5):
        t.dueTime = h * 60 + m
        t.reminded = false
        touched()
  label("Priority", bold = true)
  var p = ord(t.priority)
  if segmented(["None", "Low", "Medium", "High"], p):
    t.priority = Priority(p)
    touched()
  label("Notes", bold = true)
  if editArea(t.notes, lines = 4): touched()
  tableGroup(""):
    if tableButton("Delete Task", destructive = true):
      deleteTask(id)
      back()

# ---- notes ----------------------------------------------------------------------------------------

proc notesPage() =
  let idx = sortedNotes()
  if idx.len == 0:
    emptyState(nfFileText, "No notes", detail = "New Note, at the top, starts one.")
    return
  tableGroup(""):
    for i in idx:
      let n = store.notes[i]
      if tableRow(noteTitle(n), whenText(n.updated), taChevron, subtitle = notePreview(n),
                  glyph = (if n.pinned: nfThumbtack else: " "), tint = color(236, 140, 20),
                  key = "n" & $n.id, selected = chosen("note:" & $n.id)).clicked: push("note:" & $n.id)

proc notePage(id: int) =
  let i = findNote(id)
  if i < 0:
    emptyState(nfFileText, "This note is gone")
    return
  let n = store.notes[i]
  label(whenText(n.updated) & (if n.pinned: " -- pinned" else: ""), color = ui.theme.gray)
  if editArea(store.notes[i].text, lines = -1):
    store.notes[i].updated = epochTime()
    touched()

# ---- search ---------------------------------------------------------------------------------------

proc searchPage() =
  discard searchBar(query, "Tasks and notes")
  if query.strip.len == 0:
    emptyState(nfSearch, "Search", detail = "Your tasks and notes, by their words.")
    return
  let ts = searchTasks(query)
  let ns = searchNotes(query)
  if ts.len == 0 and ns.len == 0:
    emptyState(nfSearch, "Nothing found")
    return
  if ts.len > 0:
    tableGroup("Tasks"):
      taskRows(ts, "q", showList = true)
  if ns.len > 0:
    tableGroup("Notes"):
      for i in ns:
        let n = store.notes[i]
        if tableRow(noteTitle(n), whenText(n.updated), taChevron, subtitle = notePreview(n),
                    key = "qn" & $n.id).clicked:
          tab = 1
          stacks[1] = @["notes", "note:" & $n.id]

# ---- settings -------------------------------------------------------------------------------------

proc settingsPage() =
  tableGroup("Tasks", "Reminders come as the phone's notifications, also while the app is closed."):
    if tableSwitch("Show Completed", store.showDone, glyph = nfCheck, tint = color(30, 160, 90)): touched()
    if tableSwitch("Reminders", store.reminders, glyph = nfBell, tint = color(150, 90, 210)):
      touched()
      discard scheduleBackgroundCheck(if store.reminders: 15 else: 0)
    if tableSwitch("Count on the Icon", store.badge, glyph = nfInfo, tint = color(220, 50, 60)):
      touched()
      if not store.badge: setBadge(0)
  tableGroup(""):
    if tableRow("Appearance", "", taChevron, glyph = nfPalette, tint = color(150, 90, 210),
                selected = chosen("appearance")).clicked:
      push("appearance")
    if tableRow("About Retro Tasks", "", taChevron, glyph = nfInfo, tint = color(128, 128, 136)).clicked:
      aboutOpen = true
  let open = store.tasks.len - smart(slCompleted).len
  label($open & " to do, " & $smart(slCompleted).len & " done, " & $store.notes.len & " notes",
        color = ui.theme.gray)

# ---- the window -----------------------------------------------------------------------------------

proc title(): string =
  let p = page()
  if p == "home": "Tasks"
  elif p == "notes": "Notes"
  elif p == "search": "Search"
  elif p == "settings": "Settings"
  elif p == "appearance": "Appearance"
  elif p.startsWith("list:") or p.startsWith("smart:"): arg()
  elif p.startsWith("task:"): "Task"
  elif p.startsWith("note:"):
    let i = findNote(parseInt(arg()))
    if i >= 0: noteTitle(store.notes[i]) else: "Note"
  else: ""

proc backLabel(): string =
  if stacks[tab].len < 2: return ""
  let up = stacks[tab][^2]
  if up == "home": "Tasks"
  elif up.startsWith("list:") or up.startsWith("smart:"): up[up.find(':') + 1 .. ^1]
  elif up == "notes": "Notes"
  elif up == "settings": "Settings"
  else: "Back"

proc actionLabel(): string =
  let p = page()
  if p.startsWith("list:"): (if editing: "Done" else: "Edit")
  elif p == "notes": "New"
  elif p.startsWith("note:"):
    let i = findNote(parseInt(arg()))
    if i >= 0 and store.notes[i].pinned: "Unpin" else: "Pin"
  else: ""

proc doAction() =
  let p = page()
  if p.startsWith("list:"): editing = not editing
  elif p == "notes": push("note:" & $newNote())
  elif p.startsWith("note:"):
    let i = findNote(parseInt(arg()))
    if i >= 0:
      store.notes[i].pinned = not store.notes[i].pinned
      touched()

proc body() =
  let p = page()
  if p == "home": homePage()
  elif p.startsWith("list:"): listPage(arg())
  elif p.startsWith("smart:"):
    for k in SmartList:
      if $k == arg(): smartPage(k)
  elif p.startsWith("task:"): taskPage(parseInt(arg()))
  elif p == "notes": notesPage()
  elif p.startsWith("note:"): notePage(parseInt(arg()))
  elif p == "search": searchPage()
  elif p == "settings": settingsPage()
  elif p == "appearance": discard appearanceSettings()

proc dialogs() =
  if newListOpen and inputBox(newListOpen, "New List", "Its name:", newListName) == 1:
    let n = newListName.strip
    var taken = false
    for l in store.lists:
      if l.name == n: taken = true
    if n.len > 0 and not taken:
      store.lists.add TaskList(name: n, tint: store.lists.len mod ListTints.len)
      touched()
      push("list:" & n)
    elif taken: message = "There is a list " & n & " already"
  if alertBox(deleteListOpen, "Delete \"" & arg() & "\"?", "Its tasks are deleted with it.",
              ["Cancel", "Delete"], cancel = 0) == 1:
    deleteList(arg())
    back()
  var names: seq[string]
  for l in store.lists: names.add l.name
  let k = actionSheet(moveOpen, "Move to", names)
  if k >= 0:
    let i = find(movingId)
    if i >= 0:
      store.tasks[i].list = names[k]
      store.tasks[i].order = high(int) div 2
      touched()
  aboutBox(aboutOpen, "Retro Tasks", TasksVersion,
           ["Tasks in lists, with their days, reminders and flags, and notes beside them -- " &
            "kept on this device."],
           tagline = "Tasks and notes", glyph = pxApp)

proc firstPage(): string =
  ## (a tablet's page beside the left column when none was chosen: the first list, the newest
  ## note)
  case tab
  of 0: (if store.lists.len > 0: "list:" & store.lists[0].name else: "smart:Today")
  of 1:
    let idx = sortedNotes()
    if idx.len > 0: "note:" & $store.notes[idx[0]].id else: ""
  of 3: "appearance"
  else: ""

proc splitView() =
  ## A tablet's or a computer's: the tab's first page in a column down the left under its bar,
  ## the page chosen beside it under its own -- as tablets showed them then.
  if stacks[tab].len == 1:
    let f = firstPage()
    if f.len > 0: stacks[tab].add f
  let top = ui.barY
  let h = ui.bottom - top
  let x0 = ui.winX + ui.safe.left
  let w = ui.w - ui.safe.left - ui.safe.right
  let mw = min(dp(340), w * 2 div 5)
  # the left: the tab's first page
  pushFrame(rect(x0, top, mw, h))
  let root = stacks[tab][0]
  let rootTitle = case root
                  of "home": "Tasks"
                  of "notes": "Notes"
                  of "search": "Search"
                  else: "Settings"
  if navBar(rootTitle, action = (if root == "notes": "New" else: "")) == npAction:
    stacks[tab] = @[root, "note:" & $newNote()]
  beginPanel(-1, "tasks:left:" & $tab, plain = true)
  let (fx, _) = layoutOrigin()
  pushFrame(rect(fx + dp(8), layoutY() + dp(4), layoutWidth() - dp(16), 0))
  drawingLeft = true
  case root
  of "home": homePage()
  of "notes": notesPage()
  of "search": searchPage()
  else: settingsPage()
  drawingLeft = false
  discard place(0, popFrame() + dp(12))
  endPanel()
  discard popFrame()
  vline(x0 + mw, top, h, if glossLook() or lumaOfColor(ui.theme.window) < 128: color(0, 0, 0)
                         else: mixColor(ui.theme.window, ui.theme.text, 0.2))
  # beside it: the page chosen, under its own bar (Back only past its first page)
  pushFrame(rect(x0 + mw + 1, top, w - mw - 1, h))
  if stacks[tab].len > 1:
    let backTo = if stacks[tab].len > 2: backLabel() else: ""
    case navBar(title(), back = backTo, action = actionLabel(), done = editing)
    of npBack: back()
    of npAction: doAction()
    of npNone: discard
    beginPanel(-1, "tasks:right:" & $tab & ":" & page(), plain = true)
    let (rx, _) = layoutOrigin()
    let rw = layoutWidth()
    let cw = min(rw - 2 * dp(24), dp(640))
    pushFrame(rect(rx + (rw - cw) div 2, layoutY() + dp(4), cw, 0))
    body()
    discard place(0, popFrame() + dp(12))
    endPanel()
  else:
    discard navBar("")
    emptyState(nfCheck, if tab == 2: "Search" else: "Nothing chosen",
               detail = if tab == 2: "A task or a note found, on the left, opens here." else: "")
  discard popFrame()

proc tasksView*() =
  ## The whole window, every frame.
  saveSoon()
  if epochTime().int mod 30 == 0 or ui.frameNo < 3:
    if raiseReminders() > 0: message = "A task is due"
  if store.badge: setBadge(dueTodayCount())
  # (the phone's Back: a page back, the app closed only from a tab's first page)
  if backPressed() and stacks[tab].len > (if split(): 2 else: 1):
    cancelClose()
    back()
  let before = tab
  discard bottomNav([(nfCheck, "Tasks"), (nfFileText, "Notes"), (nfSearch, "Search"), (nfCog, "Settings")], tab)
  if tab != before: editing = false
  if CtrlPressed in ui.mods and ui.key == KeyN and not ui.keyUsed and canInput():
    ui.keyUsed = true
    if tab == 1: push("note:" & $newNote())
  if split(): splitView()
  else:
    case navBar(title(), back = backLabel(), action = actionLabel(), done = editing)
    of npBack: back()
    of npAction: doAction()
    of npNone: discard
    beginPanel(-1, "tasks:" & $tab & ":" & page(), plain = true)
    let (fx, _) = layoutOrigin()
    pushFrame(rect(fx, layoutY() + dp(4), layoutWidth(), 0))
    body()
    discard place(0, popFrame() + dp(12))
    endPanel()
  dialogs()
  if message.len > 0:
    toast(message)
    message = ""
  # (a minute on: what is due raised)
  wakeIn(30_000)

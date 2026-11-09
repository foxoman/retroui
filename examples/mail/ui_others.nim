# Retro Mail: Calendar (events made, changed and deleted, with attendees and
# Teams or Google Meet, as the new Outlook does), People, To Do and Notes.
# Included by examples/mail.nim.
#
# Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

var
  calDay: Date
  calMode = amWeek
  appts: seq[Appointment]
  apptEv: seq[int]               ## each entry's event: an index in calEvs
  apptDay: seq[Date]             ## the day each entry is on (a whole-day event has one a day)
  calEvs: seq[Event]
  apptsVer = -1
  apptsFrom = 0.0
  calSel = 0                     ## the event picked (its id in the store)
  calMoving = -1                 ## the entry being dragged: changed once it is let go
  # the event window
  evOpen = false
  evAcct = 0                     ## the calendar: an index in calAccounts()
  evId = ""                      ## the event's id ("" a new one)
  evSeries = ""                  ## one event of a series: the series' id
  evStart0 = 0.0                 ## (when that event starts)
  evWhole = 0                    ## a change to it: 0 that event, 1 the whole series
  evMine = true                  ## the account organizes it (else only the reminder is its own)
  evOrganizer = ""
  evJoin = ""                    ## its online meeting
  evWas: EventDraft              ## as it was opened: only what changed is sent
  evTitle, evWhere, evPeople, evNotes: string
  evFrom, evTo: Date
  evFromTime, evToTime: string
  evAllDay, evOnline: bool
  evRepeat = 0                   ## a Repeat; 5: as its series repeats now (a way not made here)
  evReminder = 15
  evSaving = false               ## waiting for the sync thread's answer
  evError = ""
  evAskDelete = false
  evNth = 0                      ## (each opening's controls start afresh)
  peopleFilter = ""
  peopleSel = 0
  peopleRows: seq[tuple[email, name: string; uses: int; saved: bool]]
  peopleVer = -1
  pName, pMail, pPhone, pCompany, pNotes: string
  pLoaded = ""
  taskText = ""
  noteSel = 0
  noteTitle, noteBody: string
  noteId = 0
  noteLoaded = -1
  peopleW = 420
  notesW = 260

proc toDate(t: float): Date =
  let d = fromUnixFloat(t).local
  date(d.year, ord(d.month), d.monthday)

proc minuteOf(t: float): int =
  let d = fromUnixFloat(t).local
  d.hour * 60 + d.minute

proc atMinute(d: Date; minute: int): float =
  ## `minute` minutes into day `d` (1440: the next midnight), local time.
  let dd = d.addDays(minute div 1440)
  let m = minute mod 1440
  dateTime(dd.year, Month(dd.month), dd.day, m div 60, m mod 60, 0, 0, local()).toTime.toUnixFloat

proc loadAppts() =
  if calDay.year == 0: calDay = today()
  let d0 = dateTime(calDay.year, Month(calDay.month), 1, 0, 0, 0, 0, local()).toTime.toUnixFloat
  if apptsVer == dataVer and apptsFrom == d0: return
  if calMoving >= 0: return                  # (not while an entry is being dragged)
  apptsVer = dataVer
  apptsFrom = d0
  appts.setLen(0)
  apptEv.setLen(0)
  apptDay.setLen(0)
  calEvs = store0.events(d0 - 7 * 86400, d0 + 45 * 86400)
  let palette = [rgb(0, 99, 177), rgb(0, 128, 0), rgb(122, 59, 160), rgb(200, 100, 0)]
  for n, e in calEvs:
    var k = 0
    for i, a in accountsC:
      if a.id == e.account: k = i
    if e.allDay:
      var d = toDate(e.start + 7200)
      while atMinute(d, 0) < e.finish - 7200:
        appts.add Appointment(title: e.title, day: d, allDay: true, color: palette[k mod 4])
        apptEv.add n
        apptDay.add d
        d = d.addDays(1)
    else:
      appts.add Appointment(title: e.title & (if e.location.len > 0: " (" & e.location & ")" else: ""),
                            day: toDate(e.start), start: minuteOf(e.start),
                            finish: (if toDate(e.finish) == toDate(e.start): minuteOf(e.finish) else: 1440),
                            color: palette[k mod 4])
      apptEv.add n
      apptDay.add toDate(e.start)

# ---- the event window ------------------------------------------------------------------------

const reminderChoices = [(-1, "None"), (0, "When it starts"), (5, "5 minutes before"),
                         (10, "10 minutes before"), (15, "15 minutes before"), (30, "30 minutes before"),
                         (60, "1 hour before"), (120, "2 hours before"), (1440, "1 day before"),
                         (10080, "1 week before")]

let halfHours = (0 ..< 48).toSeq.mapIt(align($(it div 2), 2, '0') & (if it mod 2 == 0: ":00" else: ":30"))

proc calAccounts(): seq[Account] =
  ## The accounts with a calendar (not Local Folders, not IMAP's).
  for a in accountsC:
    if not isLocal(a) and a.kind != akImap: result.add a

proc clockText(t: float): string = fromUnixFloat(t).local.format("HH:mm")

proc clockOf(s: string): int =
  ## "9", "9:30", "09.30", "930" as minutes after midnight; -1 not a time.
  let t = s.strip.replace('.', ':')
  var h, m = 0
  try:
    if ':' in t:
      let p = t.split(':')
      h = parseInt(p[0].strip)
      m = parseInt(p[1].strip)
    elif t.len in [3, 4]:
      h = parseInt(t[0 ..< t.len - 2])
      m = parseInt(t[^2 .. ^1])
    else: h = parseInt(t)
  except ValueError: return -1
  if h notin 0 .. 23 or m notin 0 .. 59: return -1
  h * 60 + m

proc eventWhen(e: Event): string =
  let a = fromUnixFloat(e.start).local
  let b = fromUnixFloat(e.finish).local
  if e.allDay:
    result = a.format("dddd d MMMM yyyy")
    if e.finish - e.start > 86400 * 1.5:
      result.add " - " & fromUnixFloat(e.finish - 7200).local.format("dddd d MMMM")
  else:
    result = a.format("ddd d MMM yyyy, HH:mm") & " - " &
             (if a.yearday == b.yearday and a.year == b.year: b.format("HH:mm") else: b.format("ddd d MMM HH:mm"))

proc answerText(response: string): string =
  ## An attendee's answer, as Graph or Google says it.
  case response
  of "accepted": " (accepted)"
  of "tentativelyAccepted", "tentative": " (tentative)"
  of "declined": " (declined)"
  else: ""

proc repeatNames(d: Date): seq[string] =
  const days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
  if not d.valid: return @["Never", "Every day", "Every week", "Every month", "Every year", "As it repeats now"]
  @["Never", "Every day", "Every week on " & days[weekday(d)], "Every month on day " & $d.day,
    "Every year on " & $d.day & " " & monthNames[d.month - 1], "As it repeats now"]

proc showDraft(d: EventDraft) =
  ## The window's fields from a draft.
  evTitle = d.title
  evWhere = d.location
  evNotes = d.description
  evPeople = d.attendees.join(", ")
  evAllDay = d.allDay
  evOnline = d.online
  evFrom = toDate(d.start + (if d.allDay: 7200 else: 0))
  if d.allDay:
    evTo = toDate(max(d.finish - 7200, d.start + 7200))     # (the last day)
    evFromTime = "09:00"
    evToTime = "09:30"
  else:
    evTo = toDate(d.finish)
    evFromTime = clockText(d.start)
    evToTime = clockText(d.finish)
  evRepeat = ord(d.repeat)
  evReminder = d.reminder

proc draftShown(): tuple[d: EventDraft; error: string] =
  ## The draft the window's fields make ("error": what is wrong with them).
  var d = EventDraft(title: evTitle.strip, location: evWhere.strip, description: evNotes.strip,
                     allDay: evAllDay, online: evOnline, reminder: evReminder)
  for a in parseAddresses(evPeople):
    if '@' in a.email: d.attendees.add(if a.name.len > 0: a.name & " <" & a.email & ">" else: a.email)
  d.repeat = if evRepeat in 0 .. ord(Repeat.high): Repeat(evRepeat) else: evWas.repeat
  if evAllDay:
    d.start = atMinute(evFrom, 0)
    d.finish = atMinute(evTo, 1440)
    if evTo < evFrom: return (d, "The event ends before it starts.")
  else:
    let a = clockOf(evFromTime)
    let b = clockOf(evToTime)
    if a < 0: return (d, "\"" & evFromTime & "\" is not a time (9:30, 14:00).")
    if b < 0: return (d, "\"" & evToTime & "\" is not a time (9:30, 14:00).")
    d.start = atMinute(evFrom, a)
    d.finish = atMinute(evTo, b)
    if d.finish < d.start: return (d, "The event ends before it starts.")
  (d, "")

proc openEventWindow() =
  evSaving = false
  evError = ""
  evAskDelete = false
  evOpen = true
  inc evNth

proc newEvent(start: float; allDay = false; title = ""; people: seq[string] = @[]; account = 0) =
  ## The event window for a new event at `start` (half an hour; that whole
  ## day), in `account`'s calendar (0: the one used last).
  let accs = calAccounts()
  if accs.len == 0:
    status = "Add an account first: its calendar is where the event goes"
    return
  evAcct = accs.mapIt(it.id).find(account)
  if evAcct < 0: evAcct = clamp(prefInt("calAccount", 0), 0, accs.high)
  evId = ""
  evSeries = ""
  evStart0 = 0
  evWhole = 0
  evMine = true
  evOrganizer = ""
  evJoin = ""
  evWas = EventDraft(reminder: 15)
  showDraft(EventDraft(title: title, start: start, finish: start + (if allDay: 86400.0 else: 1800.0),
                       allDay: allDay, attendees: people, reminder: (if allDay: -1 else: 15)))
  openEventWindow()

proc nextHalfHour(): float =
  let n = now()
  atMinute(today(), (n.hour * 60 + n.minute) div 30 * 30 + 30)

proc newEventNow() =
  ## New Event: the next half hour today, nine o'clock on another day.
  if calDay.year == 0 or calDay == today(): newEvent(nextHalfHour())
  else: newEvent(atMinute(calDay, 9 * 60))

proc openEvent(e: Event) =
  ## The event window for an event of the calendar.
  let k = calAccounts().mapIt(it.id).find(e.account)
  if k < 0: return
  evAcct = k
  evId = e.remoteId
  evSeries = e.series
  evStart0 = e.start
  evWhole = 0
  evMine = e.mine
  evOrganizer = e.organizer
  evJoin = e.joinUrl
  evWas = draftOf(e)
  showDraft(evWas)
  if e.repeat == "custom": evRepeat = 5
  openEventWindow()

proc newMeetingFrom(m: Msg) =
  ## Message, New Meeting: the sender and the others the message went to
  ## invited, its subject the title (Outlook's Reply with Meeting).
  var mine: seq[string]
  for a in accountsC: mine.add a.email.toLowerAscii
  var people, seen: seq[string]
  for a in @[MailAddress(name: m.fromName, email: m.fromEmail)] & parseAddresses(m.toList & ", " & m.ccList):
    let k = a.email.strip.toLowerAscii
    if '@' notin k or k in mine or k in seen: continue
    seen.add k
    people.add(if a.name.len > 0 and a.name != a.email: a.name & " <" & a.email & ">" else: a.email)
  var title = m.subject.strip
  var cut = true
  while cut:
    cut = false
    for p in ["re:", "fw:", "fwd:", "aw:", "رد:"]:
      if title.toLowerAscii.startsWith(p):
        title = title[p.len .. ^1].strip
        cut = true
  newEvent(nextHalfHour(), title = title, people = people, account = m.account)

proc saveEvent() =
  ## Save: the new event or what changed goes to the sync thread (the
  ## window closes with its answer).
  let (d, err) = draftShown()
  if err.len > 0:
    evError = err
    return
  let accs = calAccounts()
  if evAcct notin 0 ..< accs.len: return
  let acc = accs[evAcct]
  if evId.len == 0:
    prefs.put("calAccount", evAcct)
    link.cmds.send(SyncCmd(kind: scEventNew, id: acc.id, text: $(%*{"draft": toJson(d)})))
  else:
    var parts = changedParts(evWas, d)
    if not evMine: parts = parts * {dpReminder}       # (the organizer's meeting: the reminder is ours)
    let whole = evSeries.len > 0 and evWhole == 1
    if evSeries.len > 0 and not whole: parts.excl dpRepeat
    if parts.len == 0:
      evOpen = false
      return
    link.cmds.send(SyncCmd(kind: scEventChange, id: acc.id,
                           text: $(%*{"event": (if whole: evSeries else: evId), "draft": toJson(d),
                                      "parts": toJson(parts), "occurrence": (if whole: evStart0 else: 0.0)})))
  evSaving = true
  evError = ""
  status = "Saving \"" & (if d.title.len > 0: d.title else: "Untitled") & "\"..."

proc moveEntry(i: int) =
  ## An entry dragged to another day or time: its event changed so (that
  ## one event of a series).
  if i notin 0 ..< appts.len or i >= apptEv.len: return
  let e = calEvs[apptEv[i]]
  let a = appts[i]
  if not e.mine:
    status = "Only " & (if e.organizer.len > 0: e.organizer else: "the organizer") & " can move this meeting"
    apptsVer = -1                            # (back where it was)
    return
  let was = draftOf(e)
  var d = was
  if e.allDay:
    let days = dayNumber(a.day) - dayNumber(apptDay[i])
    d.start = atMinute(toDate(e.start + 7200).addDays(days), 0)
    d.finish = atMinute(toDate(e.finish - 7200).addDays(days), 1440)
  else:
    d.start = atMinute(a.day, a.start)
    d.finish = if a.finish < 1440 or toDate(e.finish) == toDate(e.start): atMinute(a.day, a.finish)
               else: d.start + (e.finish - e.start)
  let parts = changedParts(was, d)
  if parts.len == 0: return
  link.cmds.send(SyncCmd(kind: scEventChange, id: e.account,
                         text: $(%*{"event": e.remoteId, "draft": toJson(d), "parts": toJson(parts)})))
  status = "Moving \"" & e.title & "\"..."

proc eventAnswer(ev: SyncEvent) =
  ## The sync thread's answer to a new event, a change or a delete.
  let j = try: parseJson(ev.text) except CatchableError: newJObject()
  let waiting = evSaving
  evSaving = false
  apptsVer = -1
  if j.hasKey("error"):
    if waiting and evOpen: evError = j{"error"}.getStr
    status = "The calendar: " & j{"error"}.getStr
    changed()
    return
  let invited = parseAddresses(evPeople).len > 0
  status = case ev.count
           of 0: "Saved" & (if waiting and invited: "; the invitations went out" else: "")
           of 1: "Saved" & (if waiting and invited and evMine: "; the attendees were told" else: "")
           else: "Deleted"
  if ev.count < 2 and waiting and evOnline and evMine and j{"joinUrl"}.getStr.len == 0 and
     account(ev.id).kind == akGraph:
    status.add " (no Teams meeting: " & account(ev.id).email & " has no Teams)"
  if ev.count == 2: calSel = 0
  if waiting: evOpen = false
  changed()

proc eventDialog() =
  ## The event window, as 3.1 drew a dialog: title, start and end, all day,
  ## where, who (invited by the service), the online meeting, repeat,
  ## reminder, notes; Save, Delete, Cancel.
  if not evOpen: return
  let accs = calAccounts()
  if accs.len == 0:
    evOpen = false
    return
  evAcct = clamp(evAcct, 0, accs.high)
  let acc = accs[evAcct]
  let editable = evMine and not evSaving
  let meeting = evPeople.strip.len > 0 or not evMine
  dialog evOpen, (if evTitle.strip.len > 0: evTitle.strip else: "Untitled") &
                 (if meeting: " - Meeting" else: " - Event"), dp(580):
    pushId("event" & $evNth)
    form dp(96):
      if accs.len > 1:
        field "&Calendar:":
          block:
            var i = evAcct
            if combo(accs.mapIt(it.email), i, enabled = evId.len == 0 and not evSaving): evAcct = i
      if not evMine:
        field "Organizer:": label evOrganizer
      field "&Title:": edit(evTitle, enabled = editable)
      let fromWas = evFrom
      let fromTimeWas = evFromTime
      field "St&art:":
        row:
          datePicker(evFrom, enabled = editable)
          if not evAllDay: comboEdit(evFromTime, halfHours, w = dp(90), enabled = editable)
      if evFrom != fromWas or evFromTime != fromTimeWas:
        # the end moves with the start (the length stays)
        if evAllDay: evTo = evTo.addDays(dayNumber(evFrom) - dayNumber(fromWas))
        else:
          let a0 = clockOf(fromTimeWas)
          let a1 = clockOf(evFromTime)
          let b = clockOf(evToTime)
          if a0 >= 0 and a1 >= 0 and b >= 0:
            let f = atMinute(evTo, b) + (atMinute(evFrom, a1) - atMinute(fromWas, a0))
            evTo = toDate(f)
            evToTime = clockText(f)
      field "&End:":
        row:
          datePicker(evTo, enabled = editable)
          if not evAllDay: comboEdit(evToTime, halfHours, w = dp(90), enabled = editable)
    row:
      space dp(96)
      checkbox("All da&y", evAllDay, enabled = editable)
      checkbox(if acc.kind == akGraph: "Teams meetin&g" else: "&Google Meet", evOnline, enabled = editable)
    form dp(96):
      field "&Location:": edit(evWhere, enabled = editable)
      field "&Invite:": edit(evPeople, enabled = editable)
    if editable: suggestions(evPeople)
    form dp(96):
      field "&Repeat:":
        let names = repeatNames(evFrom)
        combo(if evRepeat == 5: names else: names[0 .. 4], evRepeat, w = dp(260),
              enabled = editable and (evSeries.len == 0 or evWhole == 1))
      field "Re&minder:":
        var labels = reminderChoices.mapIt(it[1])
        var k = reminderChoices.mapIt(it[0]).find(evReminder)
        if k < 0:
          labels.add $evReminder & " minutes before"
          k = labels.high
        if combo(labels, k, w = dp(200), enabled = not evSaving) and k < reminderChoices.len:
          evReminder = reminderChoices[k][0]
    if evSeries.len > 0:
      row:
        space dp(96)
        radio("&Only this event", evWhole, 0, enabled = not evSaving)
        radio("The &whole series", evWhole, 1, enabled = not evSaving)
    label "&Notes:"
    editArea(evNotes, lines = 5, enabled = editable)
    if evJoin.len > 0:
      row:
        label (if acc.kind == akGraph: "Teams meeting:" else: "Google Meet:"), bold = true
        if button("&Join", pxVideo): discard openUrl(evJoin)
        label fit(evJoin, max(dp(40), available())), color = ui.theme.gray
    if not evMine:
      paragraph "A meeting " & (if evOrganizer.len > 0: evOrganizer else: "someone else") &
                " organizes: only its reminder is yours to change.", color = ui.theme.gray
    if evSaving:
      row:
        spinner()
        label "Saving...", color = ui.theme.gray
    if evError.len > 0: paragraph evError, color = rgb(200, 0, 0)
    row:
      if evId.len > 0 and button("&Delete", pxDelete, enabled = not evSaving): evAskDelete = true
      space available() - 2 * (dp(84) + Gap) + Gap
      if button("&Save", isDefault = true, w = dp(84), enabled = not evSaving): saveEvent()
      if button("Cancel", w = dp(84)): evOpen = false
    popId()
  # Delete asks first
  let whole = evSeries.len > 0 and evWhole == 1
  let what = if whole: "the whole series" elif evSeries.len > 0: "this event of the series" else: "this event"
  let cancelling = evMine and evWas.attendees.len > 0
  let msg = if cancelling: "Cancel " & what & "? The attendees get a cancellation."
            elif not evMine: "Delete " & what & " from your calendar? (" &
                             (if evOrganizer.len > 0: evOrganizer else: "The organizer") & " is not told.)"
            else: "Delete " & what & "?"
  case msgBox(evAskDelete, "Delete", msg,
              (if cancelling: @["&Send Cancellation", "Don't Cancel"] else: @["&Delete", "Cancel"]), miQuestion)
  of 1:
    if evAcct in 0 ..< accs.len:
      link.cmds.send(SyncCmd(kind: scEventDelete, id: accs[evAcct].id,
                             text: $(%*{"event": (if whole: evSeries else: evId), "cancel": cancelling})))
      evSaving = true
      status = (if cancelling: "Cancelling \"" else: "Deleting \"") & evWas.title & "\"..."
  else: discard

proc eventDetails() =
  ## The event picked in the calendar: when, where, who; Join and Open.
  var e = Event()
  for x in calEvs:
    if x.id == calSel: e = x
  if e.id == 0: return
  space()
  group (if e.attendees.len > 0 or not e.mine: "Meeting" else: "Event"):
    label fit(if e.title.len > 0: e.title else: "Untitled", available()), bold = true
    label fit(eventWhen(e), available())
    if e.location.len > 0: label fit(e.location, available()), color = ui.theme.gray
    if e.repeat.len > 0 or e.series.len > 0:
      label (case e.repeat
             of "daily": "Every day"
             of "weekly": "Every week"
             of "monthly": "Every month"
             of "yearly": "Every year"
             else: "Repeats"), color = ui.theme.gray
    if not e.mine and e.organizer.len > 0:
      label fit("Organizer: " & e.organizer, available()), color = ui.theme.gray
    for i, a in e.attendees:
      if i == 8:
        label "and " & $(e.attendees.len - 8) & " more", color = ui.theme.gray
        break
      label fit((if a.name.len > 0: a.name else: a.email) & answerText(a.response), available())
    row:
      if e.joinUrl.len > 0 and button("&Join", pxVideo): discard openUrl(e.joinUrl)
      if button("&Open..."): openEvent(e)

proc agendaActs(ev: AgendaEvent) =
  ## What was done in the agenda: an event picked (opened with a double
  ## click, a tap), a new one on an empty time (the same), an entry dragged.
  if ev.opened and ev.item in 0 ..< apptEv.len:
    let e = calEvs[apptEv[ev.item]]
    calSel = e.id
    if ui.clicks >= 2 or finger() or isCompact(): openEvent(e)
  elif ev.added and (ui.clicks >= 2 or finger() or not ui.released):
    newEvent(atMinute(ev.addDay, max(ev.addMinute, 0)), allDay = ev.addMinute < 0)
  if ev.moved and ev.item in 0 ..< appts.len: calMoving = ev.item
  if calMoving >= 0 and not ui.mouseDown:
    let i = calMoving
    calMoving = -1
    moveEntry(i)

proc calendarView() =
  loadAppts()
  if isCompact():
    row:
      if button("&New Event", pxNew, enabled = calAccounts().len > 0): newEventNow()
    agendaActs(agendaView(appts, calDay, calMode, height = -1, key = "cal"))
    return
  split(treeW, -1):
    calendar(calDay)
    space()
    label "Calendars", bold = true
    for i, a in accountsC:
      if not isLocal(a):
        label a.email, color = [rgb(0, 99, 177), rgb(0, 128, 0), rgb(122, 59, 160), rgb(200, 100, 0)][i mod 4]
    eventDetails()
    space()
    paragraph "A double click on a time makes an event there, on an event opens it; drag one to move it.",
              color = ui.theme.gray
    if link("Open Outlook on the web"): discard openUrl("https://outlook.office.com/calendar/")
    if link("Open Google Calendar"): discard openUrl("https://calendar.google.com/")
  do:
    agendaActs(agendaView(appts, calDay, calMode, height = -1, key = "cal"))

proc peopleView() =
  if peopleVer != dataVer:
    peopleVer = dataVer
    peopleRows = store0.contacts(peopleFilter, 2000)
  split(peopleW, -1):
    row:
      if searchBox(peopleFilter, "Find people"):
        peopleVer = -1
    var data: seq[seq[string]]
    for p in peopleRows: data.add @[p.name, p.email, $p.uses]
    var cols = @[column("Name", 150), column("E-mail", 180), numberColumn("Messages", 70)]
    let ev = grid(cols, data, peopleSel, height = -1)
    if ev.activated and peopleSel in 0 ..< peopleRows.len:
      let p = peopleRows[peopleSel]
      openCompose("new", to = (if p.name.len > 0: p.name & " <" & p.email & ">" else: p.email))
  do:
    if peopleSel in 0 ..< peopleRows.len and pLoaded != peopleRows[peopleSel].email:
      let p = peopleRows[peopleSel]
      pLoaded = p.email
      let d = store0.contactDetails(p.email)
      pName = d.name
      pMail = p.email
      pPhone = d.phone
      pCompany = d.company
      pNotes = d.notes
    panel(-1):
      label "Contact", bold = true
      form dp(90):
        field "&Name:": edit pName
        field "&E-mail:": edit pMail
        field "&Phone:": edit pPhone
        field "&Company:": edit pCompany
      label "Notes:"
      editArea(pNotes, lines = 4)
      row:
        if button("&Save", isDefault = true, enabled = '@' in pMail):
          store0.saveContact(pMail, pName, pPhone, pCompany, pNotes)
          peopleVer = -1
          status = "Saved " & pMail
        if button("&New Message", pxMail, enabled = '@' in pMail):
          openCompose("new", to = (if pName.len > 0: pName & " <" & pMail & ">" else: pMail))
        if button("Ne&w Contact"):
          pName = ""
          pMail = ""
          pPhone = ""
          pCompany = ""
          pNotes = ""
          pLoaded = "-"
        if button("&Delete", enabled = pMail.len > 0):
          store0.deleteContact(pMail)
          peopleVer = -1
      if pMail.len > 0:
        space()
        label "Recent mail with " & (if pName.len > 0: pName else: pMail), bold = true
        var args = @[toDbValue("%" & pMail & "%"), toDbValue("%" & pMail & "%")]
        for m in store0.whereMessages("from_email LIKE ? OR to_list LIKE ?", args, 8):
          if link(shortDate(m.date) & "  " & fit(m.subject, dp(320))):
            query = "from:" & pMail
            view = vMail
            changed()

proc todoView() =
  panel(-1):
    label "To Do", bold = true
    row([-1, dp(90)]):
      edit taskText
      if button("&Add", isDefault = true, enabled = taskText.strip.len > 0):
        discard store0.addTask(taskText.strip)
        taskText = ""
    space()
    for t in store0.tasks():
      row([-1, dp(30)]):
        var done = t.done
        if checkbox(t.title, done): store0.setTaskDone(t.id, done)
        if toolButton(pxDelete, "Delete"): store0.deleteTask(t.id)
    space()
    label "Flagged mail", bold = true
    var none: seq[DbValue]
    let flagged = store0.whereMessages("flagged = 1", none, 50)
    if flagged.len == 0: label "Nothing flagged", color = ui.theme.gray
    for m in flagged:
      row([dp(110), -1]):
        label shortDate(m.date), color = ui.theme.gray
        if link(fit(who(m) & ": " & m.subject, available())):
          goPlace(Place(kind: plFlagged))

proc notesView() =
  let ns = store0.notes()
  split(notesW, -1):
    if button("&New Note", pxNote):
      noteId = store0.saveNote(0, "New note", "")
      noteLoaded = -1
      noteSel = 0
    var names: seq[string]
    for n in ns: names.add(if n.title.len > 0: n.title else: "(untitled)")
    listbox(names, noteSel, rows = -1)
  do:
    if noteSel in 0 ..< ns.len and noteLoaded != ns[noteSel].id:
      noteLoaded = ns[noteSel].id
      noteId = ns[noteSel].id
      noteTitle = ns[noteSel].title
      noteBody = ns[noteSel].body
    if ns.len == 0:
      label "No notes yet.", color = ui.theme.gray
    else:
      var ch = edit(noteTitle)
      if editArea(noteBody, lines = -1): ch = true
      if ch: discard store0.saveNote(noteId, noteTitle, noteBody)
      if button("&Delete Note"):
        store0.deleteNote(noteId)
        noteLoaded = -1

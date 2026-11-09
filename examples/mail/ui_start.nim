# Retro Mail: the start page, as Outlook Express had one, and the My Day
# pane. Included by examples/mail.nim.
#
# Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

const tips = [
  "Swipe a message to the right to archive it, to the left to delete it (on a touch " &
    "screen). Choose what each swipe does in Tools, Options, Swipe.",
  "Type tag:Finance in the search box to see everything with that tag, in every folder " &
    "and every account. from:, to:, has:attachment, is:unread, before:2026-01-01 work too.",
  "Searching looks through every message kept here, without the network, in a blink. " &
    "\"Search the server\" goes further back.",
  "Pin a message to keep it at the top of the list; snooze one to hide it until later.",
  "Ctrl+N writes a message, Ctrl+R replies, Ctrl+F forwards, Del deletes, Backspace " &
    "archives, Insert flags, Ctrl+T tags it.",
  "Pictures from the web are not shown until you ask: a picture can tell the sender " &
    "when you opened the message.",
  "Choose a signature for new messages and another for replies, for each account: " &
    "Tools, Options, Signatures."]

var tipAt = 0
var dayPick: Date

proc startLink(px, title, detail: string; strong = false): bool =
  row([dp(44), -1]):
    image(pixelIcon(px, big = true))
    col:
      if strong:
        result = link(title)
        label detail, color = ui.theme.gray
      else:
        result = link(title)
        if detail.len > 0: label detail, color = ui.theme.gray

proc todayEvents(): seq[Event] =
  let n = now()
  let t0 = dateTime(n.year, n.month, n.monthday, 0, 0, 0, 0, local()).toTime.toUnixFloat
  store0.events(t0, t0 + 86400)

proc startPage() =
  let first = accountsC.len == 0
  panel(-1):
    let r = place(available(), dp(66), fill = true)
    fill(r, rgb(0, 0, 128))
    for i in 0 ..< 40:
      fill(rect(r.x + r.w - (i + 1) * r.w div 80, r.y, r.w div 80 + 1, r.h), rgb(0, i * 2, 128 + i))
    let big = pixelIcon(pxMail, big = true)
    image(r.x + dp(12), r.y + (r.h - 2 * big.h) div 2, big, 2)
    let st = style(size = 2.0, bold = true)
    text(r.x + dp(92), r.y + dp(8), appName, rgb(255, 255, 255), st)
    let who0 = if accountsC.len > 0 and accountsC[0].name.len > 0: accountsC[0].name else: ""
    if who0.len > 0:
      text(r.x + dp(94), r.y + dp(10) + lineHeight(st), "for " & who0, rgb(200, 220, 255),
           style(italic = true))
    space(dp(10))
    let wide = available() > dp(700)
    row([-1, (if wide: dp(300) else: 0)]):
      col:
        label "E-mail", bold = true
        if first:
          if startLink(pxMail, "Set up a Mail account...",
                       "Microsoft 365, Outlook.com, Gmail -- signed in in your browser", true):
            openWizard()
        else:
          var unread = 0
          for fs in foldersC.values:
            for f in fs:
              if f.role == "inbox": unread += f.unread
          let msg = if unread == 0: "There are no unread messages in your Inbox"
                    elif unread == 1: "There is 1 unread message in your Inbox"
                    else: "There are " & $unread & " unread messages in your Inbox"
          if startLink(pxInbox, msg, $store0.messageCount() & " messages kept here for reading offline", true):
            treeSel = "fav:inbox"
            goPlace(Place(kind: plAllInbox))
          if startLink(pxMail, "Create a new Mail message", "Ctrl+N"): openCompose("new")
          let flagged = int store0.value("SELECT count(*) FROM messages WHERE flagged = 1").num
          let snoozed = int store0.value("SELECT count(*) FROM messages WHERE snooze > ?", epochTime()).num
          if startLink(pxStar, $flagged & " flagged, " & $snoozed & " snoozed", "Favorites"):
            goPlace(Place(kind: plFlagged))
          let drafts = store0.drafts()
          if drafts.len > 0:
            if startLink(pxDocument, $drafts.len & " unsent draft" & (if drafts.len > 1: "s" else: ""),
                         "Open the newest"):
              openDraft(drafts[0].id, drafts[0].data)
        space()
        label "Calendar", bold = true
        if first:
          discard startLink(pxCalendar, "Your calendar comes with your account", "")
        else:
          let evs = todayEvents()
          var next = ""
          for e in evs:
            if e.finish > epochTime():
              next = "Next: " & e.title & (if e.allDay: "" else: " at " & fromUnixFloat(e.start).local.format("HH:mm"))
              break
          if startLink(pxCalendar, "Today: " & $evs.len & (if evs.len == 1: " event" else: " events"),
                       next):
            view = vCalendar
        space()
        label "Contacts", bold = true
        if startLink(pxUser, "Open the Address Book...", "Ctrl+Shift+B"): view = vPeople
        if startLink(pxCheck, "To Do", $store0.tasks().countIt(not it.done) & " things to do"):
          view = vTodo
        if not first:
          space()
          label "Accounts", bold = true
          for a in accountsC:
            let state = if a.state == "signin": "sign in again"
                        elif a.state.len > 0: a.state
                        else: (case a.kind
                               of akGmail: "Gmail"
                               of akImap: "IMAP"
                               of akGraph: "Microsoft 365") & ", in step"
            if startLink(pxGlobe, a.email, state):
              if a.state == "signin": signInAgain(a)
              else:
                optTab = 1
                optOpen = true
          if link("Add another account..."): openWizard()
      if wide:
        col:
          group "Tip of the day":
            paragraph tips[tipAt mod tips.len]
            row:
              if button("< Previous"): tipAt = (tipAt + tips.len - 1) mod tips.len
              if button("Next >"): tipAt = (tipAt + 1) mod tips.len
    space()
    var go = prefBool("startInbox", false)
    if checkbox("When Retro Mail starts, go directly to my Inbox", go):
      prefs.put("startInbox", go)
      savePrefs()
    space()
    label credit, color = ui.theme.gray

proc myDayPane() =
  panel(-1):
    label "My Day", bold = true
    if dayPick.year == 0: dayPick = today()
    calendar(dayPick)
    space()
    let d0 = dateTime(dayPick.year, Month(dayPick.month), dayPick.day, 0, 0, 0, 0, local()).toTime.toUnixFloat
    let evs = store0.events(d0, d0 + 86400)
    label (if dayPick == today(): "Today" else: fromUnixFloat(d0).local.format("dddd d MMMM")),
          bold = true
    if evs.len == 0: label "Nothing planned", color = ui.theme.gray
    for e in evs:
      row([dp(46), -1]):
        label (if e.allDay: "All day" else: fromUnixFloat(e.start).local.format("HH:mm")),
              color = ui.theme.gray
        label fit(e.title, available())
    space()
    label "To Do", bold = true
    var n = 0
    for t in store0.tasks():
      if t.done or n >= 6: continue
      inc n
      var done = false
      if checkbox(fit(t.title, available() - dp(24)), done):
        store0.setTaskDone(t.id, true)
    if n == 0: label "All done", color = ui.theme.gray
    let snoozed = int store0.value("SELECT count(*) FROM messages WHERE snooze > ?", epochTime()).num
    if snoozed > 0:
      space()
      if link($snoozed & " snoozed"): goPlace(Place(kind: plSnoozed))

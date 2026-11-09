## Retro Mail's calendar against the stand-in services (tests/mailmock.py):
## events made with attendees (who get the invitations from the service),
## Teams and Google Meet meetings, changes (only what changed, one event or
## the whole series), deletes (a cancellation), series and whole days as
## each service wants them, time zones; then the same through the sync
## thread and the store.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, osproc, json, strutils, times, net, exitprocs, sequtils]
import retroui/[http, db, oauth, secrets]
import ../examples/mail/[store, calendar, sync]

proc freePort(): int =
  let s = newSocket()
  s.bindAddr(Port(0), "127.0.0.1")
  result = int s.getLocalAddr()[1]
  s.close()

let port = freePort()
let base = "http://127.0.0.1:" & $port
let home = getTempDir() / "retro-calendar-test-" & $getCurrentProcessId()
removeDir(home)
createDir(home)
putEnv("RETRO_MAIL_HOME", home)
putEnv("RETRO_SECRETS_DIR", home / "secrets")
putEnv("RETRO_MAIL_GRAPH", base & "/v1.0")
putEnv("RETRO_MAIL_GMAIL", base)
putEnv("RETRO_MAIL_GCAL", base & "/calendar/v3")
putEnv("RETRO_MAIL_MSLOGIN", base & "/ms")
putEnv("RETRO_MAIL_GAUTH", base & "/g/auth")
putEnv("RETRO_MAIL_GTOKEN", base & "/g/token")

let mock = startProcess("python3", args = [currentSourcePath().parentDir / "mailmock.py", $port],
                        options = {poUsePath, poParentStreams})
proc stopAtExit(p: Process) =
  # (the exit proc keeps its own reference: the program's globals, `mock`
  # too, are freed before the exit procs run)
  addExitProc(proc () = p.terminate())
stopAtExit(mock)
for i in 0 .. 50:
  if httpRequest("GET", base & "/test/state").status == 200: break
  sleep(100)

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

proc calState(): JsonNode = parseJson(httpRequest("GET", base & "/test/calendar").body)

proc lastReq(service: string): JsonNode =
  ## The last calendar request the service got.
  result = newJObject()
  for r in calState()["log"]:
    if r["service"].getStr == service: result = r

proc tokenFrom(url: string): string =
  let r = httpRequest("POST", url, [("Content-Type", "application/x-www-form-urlencoded")],
                      formEncode({"grant_type": "refresh_token", "refresh_token": "rt-test",
                                  "client_id": "test"}))
  parseJson(r.body){"access_token"}.getStr

proc utcT(y, mo, d, h, mi: int): float =
  dateTime(y, Month(mo), d, h, mi, 0, 0, utc()).toTime.toUnixFloat

proc localT(y, mo, d, h, mi: int): float =
  dateTime(y, Month(mo), d, h, mi, 0, 0, local()).toTime.toUnixFloat

proc localDay(y, mo, d: int): float = localT(y, mo, d, 0, 0)

proc wallLocal(t: float): string = fromUnixFloat(t).local.format("yyyy-MM-dd'T'HH:mm:ss")

proc find(evs: seq[Event]; id: string): Event =
  for e in evs:
    if e.remoteId == id: return e

let mtok = tokenFrom(base & "/ms/organizations/oauth2/v2.0/token")
let gtok = tokenFrom(base & "/g/token")
let msA = Account(id: 1, kind: akGraph, email: "sultan@contoso.com", name: "Sultan Al Isaiee")
let gmA = Account(id: 2, kind: akGmail, email: "foxoman@gmail.example", name: "Sultan")
let dev = deviceZone()
let devZone = if dev.len > 0: dev else: "UTC"
let span = (utcT(2026, 10, 1, 0, 0), utcT(2027, 3, 1, 0, 0))

# ---- what is sent: the shapes -------------------------------------------------------------------

echo "the device's zone"
check dev.len > 0 and (dev == "UTC" or '/' in dev), "known here: " & dev

echo "Graph's shapes"
let muscat = EventDraft(title: "Photo app review", start: utcT(2026, 11, 10, 6, 0),
                        finish: utcT(2026, 11, 10, 7, 30), timeZone: "Asia/Muscat", reminder: 15)
var gj = graphEventJson(muscat)
check gj["start"] == %*{"dateTime": "2026-11-10T10:00:00", "timeZone": "Asia/Muscat"} and
      gj["end"] == %*{"dateTime": "2026-11-10T11:30:00", "timeZone": "Asia/Muscat"} and
      not gj["isAllDay"].getBool, "a time in a named zone: its wall clock"
var win = muscat
win.timeZone = "Arabian Standard Time"
check graphEventJson(win)["start"] == %*{"dateTime": "2026-11-10T10:00:00", "timeZone": "Arabian Standard Time"},
      "a Windows zone name"
var paris = muscat
paris.timeZone = "Europe/Paris"
paris.start = utcT(2026, 7, 15, 7, 0)
paris.finish = utcT(2026, 7, 15, 8, 0)
check graphEventJson(paris)["start"]["dateTime"].getStr == "2026-07-15T09:00:00", "summer time (Paris, July)"
var nowhere = muscat
nowhere.timeZone = "Nowhere/Land"
check graphEventJson(nowhere)["start"] == %*{"dateTime": "2026-11-10T06:00:00", "timeZone": "UTC"},
      "a zone not known: UTC"
var here = muscat
here.timeZone = ""
check graphEventJson(here)["start"] == %*{"dateTime": wallLocal(muscat.start), "timeZone": devZone},
      "no zone: the device's"
let day = EventDraft(title: "National Day", start: localDay(2026, 11, 18), finish: localDay(2026, 11, 20),
                     allDay: true, reminder: -1)
gj = graphEventJson(day)
check gj["isAllDay"].getBool and gj["start"]["dateTime"].getStr == "2026-11-18T00:00:00" and
      gj["end"]["dateTime"].getStr == "2026-11-20T00:00:00" and
      gj["start"]["timeZone"] == gj["end"]["timeZone"], "whole days: midnights, the end the day after"
check not gj["isReminderOn"].getBool and gj{"reminderMinutesBeforeStart"} == nil, "no reminder"
var weekly = muscat
weekly.repeat = rpWeekly
check graphEventJson(weekly)["recurrence"] ==
      %*{"pattern": {"interval": 1, "type": "weekly", "daysOfWeek": ["tuesday"], "firstDayOfWeek": "sunday"},
         "range": {"type": "noEnd", "startDate": "2026-11-10", "recurrenceTimeZone": "Asia/Muscat"}},
      "weekly: the day of the week"
var late = weekly
late.start = utcT(2026, 11, 10, 21, 0)         # (Wednesday 01:00 in Muscat)
late.finish = late.start + 1800
check graphEventJson(late)["recurrence"]["pattern"]["daysOfWeek"] == %["wednesday"] and
      graphEventJson(late)["recurrence"]["range"]["startDate"].getStr == "2026-11-11",
      "the day of the week in the event's zone, not UTC's"
var monthly = muscat
monthly.repeat = rpMonthly
var yearly = muscat
yearly.repeat = rpYearly
var daily = muscat
daily.repeat = rpDaily
check graphEventJson(monthly)["recurrence"]["pattern"] == %*{"interval": 1, "type": "absoluteMonthly", "dayOfMonth": 10} and
      graphEventJson(yearly)["recurrence"]["pattern"] ==
        %*{"interval": 1, "type": "absoluteYearly", "dayOfMonth": 10, "month": 11} and
      graphEventJson(daily)["recurrence"]["pattern"] == %*{"interval": 1, "type": "daily"},
      "monthly, yearly, daily"
check graphEventJson(muscat)["recurrence"].kind == JNull, "no repeat: null"
var meeting = muscat
meeting.online = true
meeting.attendees = @["Ahmed Al Rawahi <ahmed@contoso.com>, muna@contoso.com", "AHMED@contoso.com"]
gj = graphEventJson(meeting)
check gj["isOnlineMeeting"].getBool and gj["onlineMeetingProvider"].getStr == "teamsForBusiness",
      "a Teams meeting"
check graphEventJson(meeting, teams = false){"isOnlineMeeting"} == nil, "no Teams for the account: none asked for"
check gj["attendees"] == %*[{"emailAddress": {"address": "ahmed@contoso.com", "name": "Ahmed Al Rawahi"}, "type": "required"},
                            {"emailAddress": {"address": "muna@contoso.com", "name": "muna@contoso.com"}, "type": "required"}],
      "attendees: each once, required"
check toSeq(graphEventJson(meeting, {dpTitle, dpLocation}).keys) == @["subject", "location"], "only the parts asked for"

echo "Google's shapes"
var gg = googleEventJson(muscat)
check gg["start"] == %*{"dateTime": "2026-11-10T10:00:00", "timeZone": "Asia/Muscat"} and
      gg["summary"].getStr == "Photo app review" and gg{"recurrence"} == nil, "a time in a named zone"
check googleEventJson(win)["start"]["timeZone"].getStr == "Asia/Dubai" and
      googleEventJson(nowhere)["start"] == %*{"dateTime": "2026-11-10T06:00:00Z", "timeZone": "UTC"},
      "a Windows name as IANA's (Google takes no other); a zone not known: UTC"
gg = googleEventJson(day)
check gg["start"] == %*{"date": "2026-11-18"} and gg["end"] == %*{"date": "2026-11-20"} and
      gg["reminders"] == %*{"useDefault": false, "overrides": []}, "whole days: dates; no reminder"
gg = googleEventJson(day, {dpTime}, patch = true)
check gg["start"] == %*{"date": "2026-11-18", "dateTime": nil, "timeZone": nil}, "a change to whole days clears the time"
check googleEventJson(weekly)["recurrence"] == %["RRULE:FREQ=WEEKLY"] and
      googleEventJson(muscat, {dpRepeat}, patch = true)["recurrence"] == newJArray() and
      googleEventJson(weekly, {dpRepeat}, patch = true).hasKey("start"), "RRULE; none in a change; a repeat goes with its times"
gg = googleEventJson(meeting, requestId = "req-1")
check gg["conferenceData"] == %*{"createRequest": {"requestId": "req-1", "conferenceSolutionKey": {"type": "hangoutsMeet"}}} and
      gg["attendees"] == %*[{"email": "ahmed@contoso.com", "displayName": "Ahmed Al Rawahi"}, {"email": "muna@contoso.com"}] and
      gg["reminders"]["overrides"] == %*[{"method": "popup", "minutes": 15}], "a Google Meet, attendees, a reminder"
var off = meeting
off.online = false
check googleEventJson(off, {dpOnline}, patch = true)["conferenceData"].kind == JNull, "the Meet taken away"

echo "what changed"
var moved = meeting
moved.start += 3600
moved.attendees = @["muna@contoso.com", "Ahmed <AHMED@CONTOSO.COM>"]
check changedParts(meeting, moved) == {dpTime}, "the same attendees in another order and case: only the time"
moved.attendees.add "sara@contoso.com"
moved.description = "Agenda"
moved.repeat = rpWeekly
check changedParts(meeting, moved) == {dpTime, dpAttendees, dpDescription, dpRepeat}, "and more"
check draftFromJson(toJson(moved)) == moved and partsFromJson(toJson({dpTitle, dpOnline})) == {dpTitle, dpOnline} and
      partsFromJson(nil) == AllParts, "through the sync thread as JSON"
check graphRepeat(%*{"pattern": {"type": "weekly", "interval": 2, "daysOfWeek": ["monday"]}}) == "custom" and
      graphRepeat(%*{"pattern": {"type": "relativeMonthly", "interval": 1}}) == "custom" and
      graphRepeat(%*{"pattern": {"type": "absoluteYearly", "interval": 1}}) == "yearly" and graphRepeat(nil) == "",
      "Graph's patterns read"
check googleRepeat(%["RRULE:FREQ=WEEKLY;BYDAY=TU"]) == "weekly" and
      googleRepeat(%["RRULE:FREQ=MONTHLY;BYDAY=2TU"]) == "custom" and
      googleRepeat(%["RRULE:FREQ=DAILY;COUNT=5"]) == "custom" and googleRepeat(%["EXDATE:20261117"]) == "",
      "Google's rules read"
var bad = muscat
bad.finish = bad.start - 60
var refused = false
try: discard createEvent(msA, mtok, bad)
except ValueError: refused = true
check refused and calState()["log"].len == 0, "an event that ends before it starts: refused here, nothing sent"

# ---- Microsoft 365 ------------------------------------------------------------------------------

echo "Microsoft 365"
var m1 = meeting
m1.timeZone = ""
m1.location = "Room 2"
m1.description = "Bring the test images.\nAnd the RAW ones."
m1.reminder = 30
let id1 = createEvent(msA, mtok, m1)
var req = lastReq("graph")
check id1.startsWith("ev-new-") and req["op"].getStr == "create", "made: its id"
check req["body"]["attendees"].len == 2 and req["body"]["isOnlineMeeting"].getBool and
      req["body"]["body"] == %*{"contentType": "text", "content": m1.description} and
      req["body"]["reminderMinutesBeforeStart"].getInt == 30 and req["body"]["start"]["timeZone"].getStr == devZone,
      "the POST: attendees, Teams, the notes as text, the reminder, the device's zone"
var evs = calendarEvents(msA, mtok, span[0], span[1])
var e1 = evs.find(id1)
check e1.title == "Photo app review" and e1.start == m1.start and e1.finish == m1.finish and not e1.allDay and
      e1.location == "Room 2", "read back: title, times, place"
check e1.mine and e1.organizer == "" and e1.attendees.len == 2 and e1.attendees[0].email == "ahmed@contoso.com" and
      e1.attendees[0].name == "Ahmed Al Rawahi" and e1.attendees[0].response == "none", "the account organizes it; who is invited"
check e1.joinUrl.startsWith("https://teams.microsoft.example/") and e1.reminder == 30 and e1.notes == m1.description,
      "the Teams link, the reminder, the notes"
let d1 = draftOf(e1)
check d1.online and d1.attendees == @["Ahmed Al Rawahi <ahmed@contoso.com>", "muna@contoso.com"] and
      changedParts(d1, m1) == {}, "as the window opens it: nothing changed"
let seed = evs.find("e1")
check seed.title == "Photo app with Ahmed" and seed.reminder == 15 and seed.location == "Room 2",
      "an event made elsewhere still read"

discard httpRequest("POST", base & "/test/calendar", body = """{"teams": false}""")
let id2 = createEvent(msA, mtok, m1)
check lastReq("graph")["body"]{"isOnlineMeeting"} == nil and
      calendarEvents(msA, mtok, span[0], span[1]).find(id2).joinUrl == "",
      "an account without Teams: the event made without an online meeting"
discard httpRequest("POST", base & "/test/calendar", body = """{"teams": true}""")

var ch = d1
ch.title = "Photo app review (moved)"
ch.start += 3600
ch.finish += 3600
ch.reminder = 5
updateEvent(msA, mtok, id1, ch, changedParts(d1, ch))
req = lastReq("graph")
check req["op"].getStr == "update" and req["id"].getStr == id1 and
      toSeq(req["body"].keys) == @["subject", "isAllDay", "start", "end", "isReminderOn", "reminderMinutesBeforeStart"],
      "a change: only what changed (the PATCH)"
e1 = calendarEvents(msA, mtok, span[0], span[1]).find(id1)
check e1.title == ch.title and e1.start == ch.start and e1.reminder == 5 and e1.attendees.len == 2, "read back"

let dayId = createEvent(msA, mtok, day)
let dayEv = calendarEvents(msA, mtok, span[0], span[1]).find(dayId)
check dayEv.allDay and dayEv.start == localDay(2026, 11, 18) and dayEv.finish == localDay(2026, 11, 20) and
      dayEv.reminder == -1, "whole days: made and read back on their days"

var series = muscat
series.timeZone = ""
series.title = "Weekly sync"
series.repeat = rpWeekly
let sid = createEvent(msA, mtok, series)
check lastReq("graph")["body"]["recurrence"]["pattern"]["type"].getStr == "weekly", "a series made"
evs = calendarEvents(msA, mtok, span[0], span[1])
let occ = evs.filterIt(it.series == sid)
check occ.len == 3 and occ.allIt(it.repeat == "weekly") and occ[1].start == series.start + 7 * 86400,
      "its events, each with the series' id and pattern (a $batch)"
var one = draftOf(occ[1])
one.title = "Weekly sync (this one in Room 5)"
updateEvent(msA, mtok, occ[1].remoteId, one, {dpTitle})
check lastReq("graph")["id"].getStr == occ[1].remoteId and lastReq("graph")["body"] == %*{"subject": one.title},
      "one event of the series changed"
evs = calendarEvents(msA, mtok, span[0], span[1])
check evs.find(occ[1].remoteId).title == one.title and evs.find(occ[2].remoteId).title == "Weekly sync",
      "only that one"
var all = draftOf(occ[2])
all.start += 1800
all.finish += 1800
updateEvent(msA, mtok, sid, all, {dpTime}, occurrence = occ[2].start)
req = lastReq("graph")
check req["id"].getStr == sid and req["body"]["start"]["dateTime"].getStr == wallLocal(series.start + 1800),
      "the whole series from its third event: moved half an hour from its own first day"
check calendarEvents(msA, mtok, span[0], span[1]).find(occ[2].remoteId).start == occ[2].start + 1800,
      "every event of it moved"
var noRepeat = draftOf(occ[0])
noRepeat.repeat = rpNone
updateEvent(msA, mtok, sid, noRepeat, {dpRepeat}, occurrence = occ[0].start)
check lastReq("graph")["body"]["recurrence"].kind == JNull and
      calendarEvents(msA, mtok, span[0], span[1]).filterIt(it.series == sid).len == 0,
      "the repeat taken away: one event again"

deleteEvent(msA, mtok, id1, cancel = true, comment = "Sorry, moved to next week")
req = lastReq("graph")
check req["op"].getStr == "cancel" and req["body"]["comment"].getStr == "Sorry, moved to next week" and
      calendarEvents(msA, mtok, span[0], span[1]).find(id1).remoteId == "",
      "a meeting called off: the cancellation, with a word"
deleteEvent(msA, mtok, "e1", cancel = true)
let ops = calState()["log"].getElems.filterIt(it["id"].getStr == "e1").mapIt(it["op"].getStr)
check ops == @["cancel", "delete"], "someone else's: only taken out (Graph refuses the cancellation)"
deleteEvent(msA, mtok, id1)
check true, "an event already gone: not an error"

# ---- Google -------------------------------------------------------------------------------------

echo "Google"
var g1 = meeting
g1.timeZone = ""
g1.location = "Jebel Shams"
g1.description = "Water, maps."
g1.reminder = 30
let gid1 = createEvent(gmA, gtok, g1)
req = lastReq("google")
check gid1.startsWith("gev") and req["query"] == %*{"sendUpdates": "all", "conferenceDataVersion": "1"},
      "made with sendUpdates=all (the invitations) and conferenceDataVersion=1"
check req["body"]["conferenceData"]["createRequest"]["conferenceSolutionKey"]["type"].getStr == "hangoutsMeet" and
      req["body"]["conferenceData"]["createRequest"]["requestId"].getStr.len > 8 and
      req["body"]["start"]["timeZone"].getStr == devZone and req["body"]["attendees"].len == 2,
      "the insert: a Meet asked for, the device's zone, the attendees"
evs = calendarEvents(gmA, gtok, span[0], span[1])
var ge = evs.find(gid1)
check ge.title == g1.title and ge.start == g1.start and ge.finish == g1.finish and ge.location == "Jebel Shams" and
      ge.notes == "Water, maps." and ge.reminder == 30, "read back"
check ge.mine and ge.attendees.len == 2 and ge.attendees[1].email == "muna@contoso.com" and
      ge.attendees[1].response == "needsAction" and ge.joinUrl == "https://meet.google.example/" & gid1,
      "who is invited, the Meet's link"
check evs.find("ge1").reminder == 10, "an event with the calendar's default reminder"
var gplain = g1
gplain.online = false
discard createEvent(gmA, gtok, gplain)
check lastReq("google")["query"] == %*{"sendUpdates": "all"} and lastReq("google")["body"]{"conferenceData"} == nil,
      "no Meet: no conferenceDataVersion"

var gch = draftOf(ge)
gch.location = "Jebel Akhdar"
gch.online = false
updateEvent(gmA, gtok, gid1, gch, changedParts(draftOf(ge), gch))
req = lastReq("google")
check req["op"].getStr == "update" and req["query"] == %*{"sendUpdates": "all", "conferenceDataVersion": "1"} and
      req["body"] == %*{"location": "Jebel Akhdar", "conferenceData": nil}, "a change: the place, the Meet taken away"
ge = calendarEvents(gmA, gtok, span[0], span[1]).find(gid1)
check ge.location == "Jebel Akhdar" and ge.joinUrl == "", "read back"
var toDay = draftOf(ge)
toDay.allDay = true
toDay.start = localDay(2026, 11, 12)
toDay.finish = localDay(2026, 11, 13)
updateEvent(gmA, gtok, gid1, toDay, {dpTime})
ge = calendarEvents(gmA, gtok, span[0], span[1]).find(gid1)
check ge.allDay and ge.start == localDay(2026, 11, 12) and ge.finish == localDay(2026, 11, 13),
      "a time made a whole day"

let gday = createEvent(gmA, gtok, day)
check lastReq("google")["body"]["start"] == %*{"date": "2026-11-18"}, "whole days made as dates"
check calendarEvents(gmA, gtok, span[0], span[1]).find(gday).start == localDay(2026, 11, 18), "and read back"

var gser = series
gser.title = "Family dinner"
gser.repeat = rpMonthly
gser.timeZone = "Europe/Paris"
let gsid = createEvent(gmA, gtok, gser)
check lastReq("google")["body"]["recurrence"] == %["RRULE:FREQ=MONTHLY"] and
      lastReq("google")["body"]["start"] == %*{"dateTime": "2026-11-10T07:00:00", "timeZone": "Europe/Paris"},
      "a series, in another zone"
evs = calendarEvents(gmA, gtok, span[0], span[1])
let ginst = evs.filterIt(it.series == gsid)
check ginst.len == 3 and ginst.allIt(it.repeat == "monthly") and ginst[0].start == gser.start,
      "its instances (singleEvents), each with the series' pattern"
var gone1 = draftOf(ginst[1])
gone1.title = "Family dinner at Khalid's"
updateEvent(gmA, gtok, ginst[1].remoteId, gone1, {dpTitle})
check lastReq("google")["id"].getStr == ginst[1].remoteId and lastReq("google")["body"] == %*{"summary": gone1.title},
      "one instance changed"
var gall = draftOf(ginst[2])
gall.start += 3600
gall.finish += 3600
gall.timeZone = "Europe/Paris"
updateEvent(gmA, gtok, gsid, gall, {dpTime}, occurrence = ginst[2].start)
req = lastReq("google")
check req["id"].getStr == gsid and req["body"]["start"]["dateTime"].getStr == "2026-11-10T08:00:00",
      "the whole series moved from its third event"
evs = calendarEvents(gmA, gtok, span[0], span[1])
check evs.find(ginst[1].remoteId).remoteId == "" and evs.filterIt(it.series == gsid).len == 3,
      "(its instances move with it)"

deleteEvent(gmA, gtok, gsid, cancel = true)
check lastReq("google")["query"] == %*{"sendUpdates": "all"} and
      calendarEvents(gmA, gtok, span[0], span[1]).filterIt(it.series == gsid).len == 0,
      "a series called off: sendUpdates=all"
deleteEvent(gmA, gtok, gday, cancel = false)
check lastReq("google")["query"] == %*{"sendUpdates": "none"}, "taken out without telling anyone: sendUpdates=none"
deleteEvent(gmA, gtok, gday)
check true, "an event already gone: not an error"

# ---- through the sync thread and the store ------------------------------------------------------

echo "the store"
let old = openDb(home / "old.db")
old.exec("CREATE TABLE events(id INTEGER PRIMARY KEY, account INTEGER, remote_id TEXT, title TEXT, " &
         "start REAL, finish REAL, all_day INTEGER DEFAULT 0, location TEXT DEFAULT '', UNIQUE(account, remote_id))")
old.exec("INSERT INTO events(account, remote_id, title, start, finish) VALUES(1, 'x', 'Old', 10, 20)")
old.close()
let migrated = openStore(home / "old.db")
let olds = migrated.events(0, 100)
check olds.len == 1 and olds[0].title == "Old" and olds[0].reminder == 15 and olds[0].mine and
      olds[0].attendees.len == 0, "a store from before: the new columns added"
migrated.close()

let store0 = openStore()
let msId = store0.addAccount(akGraph, "sultan@contoso.com", "Sultan Al Isaiee", "client-ms", "organizations")
let gmId = store0.addAccount(akGmail, "foxoman@gmail.example", "Sultan", "client-g", "")
for (id, tok) in [(msId, mtok), (gmId, gtok)]:
  discard saveSecret(secretApp, tokenKey(id), $(%OAuthTokens(accessToken: tok, refreshToken: "rt-test",
                                                             expiresAt: epochTime() + 3000)))
discard saveSecret(secretApp, secretKey(gmId), "secret-xyz")
var link: SyncLink
link.cmds.open()
link.events.open()
link.dbPath = mailDir() / "mail.db"
var th: Thread[ptr SyncLink]
createThread(th, syncMain, addr link)

proc waitFor(what: SyncEventKind; secs = 30.0): SyncEvent =
  let t0 = epochTime()
  while epochTime() - t0 < secs:
    let (ok, ev) = link.events.tryRecv()
    if ok:
      if ev.kind == seError: echo "    (error) ", ev.text
      if ev.kind == what: return ev
    else: sleep(20)
  SyncEvent(kind: seStatus, text: "timeout")

let t0 = epochTime()
while epochTime() - t0 < 30 and store0.eventByRemote(gmId, "ge1").id == 0: sleep(100)
check store0.eventByRemote(msId, "e1").id == 0 and store0.eventByRemote(gmId, "ge1").reminder == 10,
      "the first sync: the calendars kept (e1 was taken out above)"
var s1 = meeting
s1.timeZone = ""
s1.start = localT(2026, 11, 20, 9, 0)
s1.finish = localT(2026, 11, 20, 10, 0)
link.cmds.send(SyncCmd(kind: scEventNew, id: msId, text: $(%*{"draft": toJson(s1)})))
var ans = waitFor(seEvent)
var aj = parseJson(ans.text)
let sNew = aj{"event"}.getStr
check ans.id == msId and ans.count == 0 and sNew.len > 0 and aj{"joinUrl"}.getStr.len > 0 and not aj.hasKey("error"),
      "a new event: the answer, with its Teams link"
let stored = store0.eventByRemote(msId, sNew)
check stored.title == s1.title and stored.start == s1.start and stored.attendees.len == 2 and stored.mine and
      stored.joinUrl == aj{"joinUrl"}.getStr, "in the store at once (the calendar read again)"
var s2 = draftOf(stored)
s2.title = "Photo app review, round 2"
link.cmds.send(SyncCmd(kind: scEventChange, id: msId,
                       text: $(%*{"event": sNew, "draft": toJson(s2), "parts": toJson(changedParts(draftOf(stored), s2))})))
ans = waitFor(seEvent)
check ans.count == 1 and not parseJson(ans.text).hasKey("error") and
      store0.eventByRemote(msId, sNew).title == s2.title, "changed"
link.cmds.send(SyncCmd(kind: scEventDelete, id: msId, text: $(%*{"event": sNew, "cancel": true})))
ans = waitFor(seEvent)
check ans.count == 2 and store0.eventByRemote(msId, sNew).id == 0 and lastReq("graph")["op"].getStr == "cancel",
      "called off: gone from the store"
link.cmds.send(SyncCmd(kind: scEventNew, id: gmId, text: $(%*{"draft": toJson(day)})))
ans = waitFor(seEvent)
let gNew = store0.eventByRemote(gmId, parseJson(ans.text){"event"}.getStr)
check gNew.allDay and gNew.start == localDay(2026, 11, 18) and gNew.finish == localDay(2026, 11, 20),
      "Gmail: a whole-day event through the thread"
link.cmds.send(SyncCmd(kind: scEventNew, id: gmId, text: $(%*{"draft": toJson(bad)})))
ans = waitFor(seEvent)
check "before it starts" in parseJson(ans.text){"error"}.getStr, "what cannot be: the error, back to the window"
link.cmds.send(SyncCmd(kind: scEventChange, id: gmId,
                       text: $(%*{"event": "gev-nope", "draft": toJson(s2), "parts": toJson({dpTitle})})))
ans = waitFor(seEvent)
check parseJson(ans.text){"error"}.getStr.len > 0, "an event no longer there: the service's error"

link.cmds.send(SyncCmd(kind: scQuit))
joinThread(th)
store0.close()
removeDir(home)
if failures > 0:
  echo failures, " failed"
  quit 1
echo "all passed"

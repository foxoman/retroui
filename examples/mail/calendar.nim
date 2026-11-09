## Retro Mail: the calendars of both services -- their events read (who is
## invited, the online meeting's link, the series an event belongs to) and
## events made, changed and deleted, as the new Outlook does: with
## attendees, who get the invitation (the changes, the cancellation) from
## the service itself. Microsoft 365 and Outlook.com: Microsoft Graph's
## /me/events (a Teams meeting where the account has Teams). Gmail: Google
## Calendar's primary calendar, with sendUpdates=all (a Google Meet).
##
## Times go as the wall-clock time of the device's zone with its name, as
## Outlook and Google Calendar write them (a series then keeps its hour
## through summer time); UTC when the zone cannot be told.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[json, strutils, times, os, sysrand, tables, algorithm]
import retroui/[http, mime]
import api, store, ical

type
  Repeat* = enum
    rpNone = "none", rpDaily = "daily", rpWeekly = "weekly", rpMonthly = "monthly",
    rpYearly = "yearly"
  EventDraft* = object
    ## An event as the window makes or changes it.
    title*: string
    start*, finish*: float     ## epoch seconds; all day: local midnights, `finish` the day after the last
    allDay*: bool
    location*: string
    description*: string       ## plain text
    attendees*: seq[string]    ## addresses: "Name <a@b>" or "a@b"
    reminder*: int             ## minutes before it starts; -1 none
    online*: bool              ## with an online meeting: Teams, Google Meet
    repeat*: Repeat            ## (every day, week, month or year from its start; no end)
    timeZone*: string          ## an IANA or Windows zone name; "" the device's
  DraftPart* = enum
    ## What of an event a change sends (the rest stays as the service has it).
    dpTitle = "title", dpTime = "time", dpLocation = "location",
    dpDescription = "description", dpAttendees = "attendees", dpReminder = "reminder",
    dpOnline = "online", dpRepeat = "repeat"

const AllParts* = {dpTitle .. dpRepeat}

# ---- the device's time zone ----------------------------------------------------------------

when defined(windows):
  type DynZone = object               # DYNAMIC_TIME_ZONE_INFORMATION
    bias: int32
    standardName: array[32, uint16]
    standardDate: array[8, uint16]
    standardBias: int32
    daylightName: array[32, uint16]
    daylightDate: array[8, uint16]
    daylightBias: int32
    keyName: array[128, uint16]
    dynamicDisabled: uint8
  proc getDynamicTimeZoneInformation(z: ptr DynZone): uint32
    {.stdcall, dynlib: "kernel32", importc: "GetDynamicTimeZoneInformation".}
elif defined(android):
  proc systemPropertyGet(name, value: cstring): cint
    {.importc: "__system_property_get", header: "<sys/system_properties.h>".}

proc deviceZone*(): string =
  ## The device's time zone: an IANA name ("Asia/Muscat"), on Windows its
  ## own ("Arabian Standard Time"); "" when it cannot be told.
  let tz = getEnv("TZ").strip(chars = {':', ' '})
  if tz.len > 0 and tz[0] in Letters and tz.allCharsInSet(Letters + Digits + {'/', '_', '-', '+'}):
    return tz
  when defined(windows):
    var z: DynZone
    if getDynamicTimeZoneInformation(addr z) != 0xFFFF_FFFF'u32:
      for c in z.keyName:
        if c == 0: break
        if c < 128: result.add char(c)
  elif defined(android):
    var buf: array[96, char]
    if systemPropertyGet("persist.sys.timezone", cast[cstring](addr buf[0])) > 0:
      result = $cast[cstring](addr buf[0])
  else:
    try:
      let s = readFile("/etc/timezone").strip
      if '/' in s: result = s; return
    except IOError, OSError: discard
    try:
      let target = expandSymlink("/etc/localtime")
      let k = target.find("zoneinfo/")
      if k >= 0: result = target[k + 9 .. ^1]; return
    except OSError: discard

proc wallOf(t: float; zone: string): tuple[stamp, zone: string] =
  ## Instant `t` as the wall-clock time of `zone` ("" the device's), as the
  ## services write it: ("2026-11-10T10:00:00", "Asia/Muscat"); in UTC when
  ## the zone is not known here.
  const f = "yyyy-MM-dd'T'HH:mm:ss"
  let dev = deviceZone()
  let z = if zone.len > 0: zone else: dev
  if z.len > 0:
    if z == dev: return (fromUnixFloat(t).local.format(f), z)
    let (off, known) = zoneOffset(z, t)
    if known: return (fromUnixFloat(t + float(off)).utc.format(f), z)
  (fromUnixFloat(t).utc.format(f), "UTC")

# Windows' names of the zones (what Windows calls the device's) as IANA's,
# which Google Calendar wants
const windowsZones = {
  "arabian standard time": "Asia/Dubai", "arab standard time": "Asia/Riyadh",
  "arabic standard time": "Asia/Baghdad", "iran standard time": "Asia/Tehran",
  "afghanistan standard time": "Asia/Kabul", "pakistan standard time": "Asia/Karachi",
  "west asia standard time": "Asia/Tashkent", "india standard time": "Asia/Kolkata",
  "sri lanka standard time": "Asia/Colombo", "nepal standard time": "Asia/Kathmandu",
  "bangladesh standard time": "Asia/Dhaka", "se asia standard time": "Asia/Bangkok",
  "singapore standard time": "Asia/Singapore", "china standard time": "Asia/Shanghai",
  "taipei standard time": "Asia/Taipei", "tokyo standard time": "Asia/Tokyo",
  "korea standard time": "Asia/Seoul", "w. australia standard time": "Australia/Perth",
  "aus eastern standard time": "Australia/Sydney", "new zealand standard time": "Pacific/Auckland",
  "caucasus standard time": "Asia/Yerevan", "azerbaijan standard time": "Asia/Baku",
  "georgian standard time": "Asia/Tbilisi", "israel standard time": "Asia/Jerusalem",
  "jordan standard time": "Asia/Amman", "syria standard time": "Asia/Damascus",
  "middle east standard time": "Asia/Beirut", "egypt standard time": "Africa/Cairo",
  "e. africa standard time": "Africa/Nairobi", "south africa standard time": "Africa/Johannesburg",
  "w. central africa standard time": "Africa/Lagos", "morocco standard time": "Africa/Casablanca",
  "turkey standard time": "Europe/Istanbul", "russian standard time": "Europe/Moscow",
  "gmt standard time": "Europe/London", "greenwich standard time": "Atlantic/Reykjavik",
  "w. europe standard time": "Europe/Berlin", "romance standard time": "Europe/Paris",
  "central europe standard time": "Europe/Budapest", "central european standard time": "Europe/Warsaw",
  "gtb standard time": "Europe/Bucharest", "fle standard time": "Europe/Kiev",
  "eastern standard time": "America/New_York", "central standard time": "America/Chicago",
  "mountain standard time": "America/Denver", "us mountain standard time": "America/Phoenix",
  "pacific standard time": "America/Los_Angeles", "atlantic standard time": "America/Halifax",
  "e. south america standard time": "America/Sao_Paulo", "hawaiian standard time": "Pacific/Honolulu",
  "coordinated universal time": "UTC", "utc": "UTC"}.toTable

proc googleWall(t: float; zone: string): tuple[stamp, zone: string] =
  ## As `wallOf`, with an IANA name (Google Calendar takes no other): a
  ## Windows name as its IANA one, else the time in UTC.
  result = wallOf(t, zone)
  if '/' notin result.zone and result.zone != "UTC":
    let iana = windowsZones.getOrDefault(result.zone.toLowerAscii)
    if iana.len > 0: result.zone = iana
    else: result = wallOf(t, "UTC")

proc dayOf(t: float): string =
  ## The day a local midnight starts ("2026-11-18"; give or take a summer hour).
  fromUnixFloat(t + 7200).local.format("yyyy-MM-dd")

proc startDay(e: EventDraft): tuple[y, m, d: int] =
  ## The day the event starts on, in its zone.
  let s = if e.allDay: dayOf(e.start) else: wallOf(e.start, e.timeZone).stamp
  (parseInt(s[0 .. 3]), parseInt(s[5 .. 6]), parseInt(s[8 .. 9]))

# ---- what is sent --------------------------------------------------------------------------

proc attendeesOf*(e: EventDraft): seq[MailAddress] =
  ## The draft's attendees, each once.
  var seen: seq[string]
  for a in parseAddresses(e.attendees.join(", ")):
    let k = a.email.strip.toLowerAscii
    if '@' notin k or k in seen: continue
    seen.add k
    result.add MailAddress(name: a.name.strip, email: a.email.strip)

proc checked(e: EventDraft): EventDraft =
  result = e
  if e.start <= 0: raise newException(ValueError, "the event has no start")
  if e.finish < e.start: raise newException(ValueError, "the event ends before it starts")
  if e.allDay and e.finish < e.start + 3600: result.finish = e.start + 86400

const dayNames = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

proc graphRecurrence*(e: EventDraft): JsonNode =
  ## The draft's repeat as Graph's patternedRecurrence (null for none).
  if e.repeat == rpNone: return newJNull()
  let (y, m, d) = startDay(e)
  var p = %*{"interval": 1}
  case e.repeat
  of rpDaily: p["type"] = %"daily"
  of rpWeekly:
    p["type"] = %"weekly"
    p["daysOfWeek"] = %[dayNames[ord(getDayOfWeek(MonthdayRange(d), Month(m), y))]]
    p["firstDayOfWeek"] = %"sunday"
  of rpMonthly:
    p["type"] = %"absoluteMonthly"
    p["dayOfMonth"] = %d
  of rpYearly:
    p["type"] = %"absoluteYearly"
    p["dayOfMonth"] = %d
    p["month"] = %m
  of rpNone: discard
  %*{"pattern": p, "range": {"type": "noEnd", "startDate": align($y, 4, '0') & "-" &
     align($m, 2, '0') & "-" & align($d, 2, '0'),
     "recurrenceTimeZone": wallOf(e.start, e.timeZone).zone}}

proc graphEventJson*(e: EventDraft; parts = AllParts; teams = true): JsonNode =
  ## The draft as a Graph event: only `parts`. `teams`: the account has
  ## Teams meetings (else none is asked for).
  result = newJObject()
  if dpTitle in parts: result["subject"] = %e.title
  if dpTime in parts:
    result["isAllDay"] = %e.allDay
    if e.allDay:
      let z = wallOf(e.start, e.timeZone).zone
      result["start"] = %*{"dateTime": dayOf(e.start) & "T00:00:00", "timeZone": z}
      result["end"] = %*{"dateTime": dayOf(max(e.finish, e.start + 86400)) & "T00:00:00", "timeZone": z}
    else:
      let s = wallOf(e.start, e.timeZone)
      let f = wallOf(max(e.finish, e.start), e.timeZone)
      result["start"] = %*{"dateTime": s.stamp, "timeZone": s.zone}
      result["end"] = %*{"dateTime": f.stamp, "timeZone": f.zone}
  if dpLocation in parts: result["location"] = %*{"displayName": e.location}
  if dpDescription in parts: result["body"] = %*{"contentType": "text", "content": e.description}
  if dpAttendees in parts:
    var list = newJArray()
    for a in attendeesOf(e):
      list.add %*{"emailAddress": {"address": a.email, "name": (if a.name.len > 0: a.name else: a.email)},
                  "type": "required"}
    result["attendees"] = list
  if dpReminder in parts:
    result["isReminderOn"] = %(e.reminder >= 0)
    if e.reminder >= 0: result["reminderMinutesBeforeStart"] = %e.reminder
  if dpOnline in parts:
    if e.online and teams:
      result["isOnlineMeeting"] = %true
      result["onlineMeetingProvider"] = %"teamsForBusiness"
    elif not e.online:
      result["isOnlineMeeting"] = %false
  if dpRepeat in parts: result["recurrence"] = graphRecurrence(e)

proc googleEventJson*(e: EventDraft; parts = AllParts; requestId = ""; patch = false): JsonNode =
  ## The draft as a Google Calendar event: only `parts` (a repeat goes with
  ## the times: Google expands a series in its start's zone). `patch`: a
  ## change, where what is no longer wanted is sent as null.
  result = newJObject()
  if dpTitle in parts: result["summary"] = %e.title
  if dpTime in parts or dpRepeat in parts:
    if e.allDay:
      for (key, t) in [("start", e.start), ("end", max(e.finish, e.start + 86400))]:
        result[key] = %*{"date": dayOf(t)}
        if patch: (result[key]["dateTime"] = newJNull(); result[key]["timeZone"] = newJNull())
    else:
      for (key, t) in [("start", e.start), ("end", max(e.finish, e.start))]:
        let w = googleWall(t, e.timeZone)
        result[key] = %*{"dateTime": w.stamp & (if w.zone == "UTC": "Z" else: ""), "timeZone": w.zone}
        if patch: result[key]["date"] = newJNull()
  if dpLocation in parts: result["location"] = %e.location
  if dpDescription in parts: result["description"] = %e.description
  if dpAttendees in parts:
    var list = newJArray()
    for a in attendeesOf(e):
      var x = %*{"email": a.email}
      if a.name.len > 0: x["displayName"] = %a.name
      list.add x
    result["attendees"] = list
  if dpReminder in parts:
    var o = newJArray()
    if e.reminder >= 0: o.add %*{"method": "popup", "minutes": e.reminder}
    result["reminders"] = %*{"useDefault": false, "overrides": o}
  if dpOnline in parts:
    if e.online:
      result["conferenceData"] = %*{"createRequest": {"requestId": requestId,
                                    "conferenceSolutionKey": {"type": "hangoutsMeet"}}}
    elif patch: result["conferenceData"] = newJNull()
  if dpRepeat in parts and (patch or e.repeat != rpNone):
    result["recurrence"] = if e.repeat == rpNone: newJArray()
                           else: %["RRULE:FREQ=" & toUpperAscii($e.repeat)]

# ---- what is read --------------------------------------------------------------------------

proc textOfHtml(s: string): string =
  ## A description written as HTML (Google Calendar's own) as text.
  if "</" notin s and "<br" notin s.toLowerAscii: return s
  var i = 0
  while i < s.len:
    if s[i] == '<':
      let e = s.find('>', i)
      if e < 0: (result.add s[i .. ^1]; break)
      let tag = s[i + 1 ..< e].strip.toLowerAscii
      if tag.startsWith("br") or tag in ["/p", "/div", "/li", "/tr"]: result.add '\n'
      i = e + 1
    else:
      result.add s[i]
      inc i
  result = result.multiReplace(("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                               ("&#39;", "'"), ("&amp;", "&")).strip

proc person(name, email: string): string =
  if name.len > 0 and name != email and email.len > 0: name & " <" & email & ">"
  elif email.len > 0: email
  else: name

proc graphRepeat*(rec: JsonNode): string =
  ## A Graph recurrence as the store keeps it: "daily", "weekly", "monthly",
  ## "yearly"; "custom" for what the window cannot make (every other week,
  ## the second Tuesday...); "" none.
  if rec == nil or rec.kind != JObject: return ""
  let p = rec{"pattern"}
  if p{"interval"}.getInt(1) != 1: return "custom"
  case p{"type"}.getStr
  of "daily": "daily"
  of "weekly": (if p{"daysOfWeek"}.getElems.len <= 1: "weekly" else: "custom")
  of "absoluteMonthly": "monthly"
  of "absoluteYearly": "yearly"
  of "": ""
  else: "custom"

proc googleRepeat*(rec: JsonNode): string =
  ## Google's recurrence (["RRULE:FREQ=WEEKLY;..."]) as the store keeps it.
  for r in rec.getElems:
    let s = r.getStr.toUpperAscii
    if not s.startsWith("RRULE:"): continue
    var freq = ""
    var plain = true
    for part in s[6 .. ^1].split(';'):
      let kv = part.split('=', 1)
      if kv.len < 2: continue
      case kv[0]
      of "FREQ": freq = kv[1]
      of "INTERVAL": (if kv[1] != "1": plain = false)
      of "BYDAY", "BYSETPOS": (if freq != "WEEKLY" or ',' in kv[1]: plain = false)
      of "WKST", "BYMONTHDAY", "BYMONTH": discard
      else: plain = false              # (COUNT, UNTIL: it ends)
    if freq in ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"]:
      return if plain: freq.toLowerAscii else: "custom"
    return "custom"

proc graphEvent*(j: JsonNode; account: int; me = ""): Event =
  ## A Graph event (its times in UTC: Prefer outlook.timezone="UTC") as
  ## the store keeps it.
  result = Event(account: account, remoteId: j{"id"}.getStr, title: j{"subject"}.getStr,
                 location: j{"location"}{"displayName"}.getStr, allDay: j{"isAllDay"}.getBool)
  for (key, field) in [("start", addr result.start), ("end", addr result.finish)]:
    let d = j{key}
    if d != nil and d.kind == JObject:
      field[] = if result.allDay: localMidnight(parseStamp(d{"dateTime"}.getStr))
                else: zoneToUtc(d{"dateTime"}.getStr, d{"timeZone"}.getStr("UTC"))
  let org = j{"organizer"}{"emailAddress"}
  result.mine = j{"isOrganizer"}.getBool(org == nil or cmpIgnoreCase(org{"address"}.getStr, me) == 0)
  if not result.mine: result.organizer = person(org{"name"}.getStr, org{"address"}.getStr)
  for a in j{"attendees"}.getElems:
    let email = a{"emailAddress"}{"address"}.getStr
    if email.len == 0 or cmpIgnoreCase(email, me) == 0: continue
    result.attendees.add (a{"emailAddress"}{"name"}.getStr, email, a{"status"}{"response"}.getStr)
  result.joinUrl = j{"onlineMeeting"}{"joinUrl"}.getStr
  if result.joinUrl.len == 0: result.joinUrl = j{"onlineMeetingUrl"}.getStr
  let body = j{"body"}{"content"}.getStr
  result.notes = if j{"body"}{"contentType"}.getStr.toLowerAscii == "html": textOfHtml(body) else: body.strip
  result.reminder = if j{"isReminderOn"}.getBool(true): j{"reminderMinutesBeforeStart"}.getInt(15) else: -1
  result.series = j{"seriesMasterId"}.getStr
  if j{"type"}.getStr == "seriesMaster": result.repeat = graphRepeat(j{"recurrence"})

proc googleEvent*(j: JsonNode; account: int; me = ""; defaultReminder = 10): Event =
  ## A Google Calendar event as the store keeps it (`defaultReminder`: the
  ## calendar's own, for an event that keeps it).
  result = Event(account: account, remoteId: j{"id"}.getStr, title: j{"summary"}.getStr,
                 location: j{"location"}.getStr)
  if j{"start"}{"date"} != nil:
    result.allDay = true
    result.start = localMidnight(parseStamp(j{"start"}{"date"}.getStr))
    result.finish = localMidnight(parseStamp(j{"end"}{"date"}.getStr))
  else:
    result.start = parseIso(j{"start"}{"dateTime"}.getStr)
    result.finish = parseIso(j{"end"}{"dateTime"}.getStr)
  let org = j{"organizer"}
  result.mine = org == nil or org{"self"}.getBool or cmpIgnoreCase(org{"email"}.getStr, me) == 0
  if not result.mine: result.organizer = person(org{"displayName"}.getStr, org{"email"}.getStr)
  for a in j{"attendees"}.getElems:
    let email = a{"email"}.getStr
    if a{"self"}.getBool or email.len == 0 or cmpIgnoreCase(email, me) == 0: continue
    if a{"organizer"}.getBool and not result.mine: continue     # (named as the organizer)
    result.attendees.add (a{"displayName"}.getStr, email, a{"responseStatus"}.getStr)
  result.joinUrl = j{"hangoutLink"}.getStr
  if result.joinUrl.len == 0:
    for p in j{"conferenceData"}{"entryPoints"}.getElems:
      if p{"entryPointType"}.getStr == "video":
        result.joinUrl = p{"uri"}.getStr
        break
  result.notes = textOfHtml(j{"description"}.getStr)
  let rem = j{"reminders"}
  if rem == nil or rem{"useDefault"}.getBool(true): result.reminder = defaultReminder
  else:
    result.reminder = -1
    for o in rem{"overrides"}.getElems:
      if o{"method"}.getStr("popup") == "popup" and (result.reminder < 0 or o{"minutes"}.getInt < result.reminder):
        result.reminder = o{"minutes"}.getInt
  result.series = j{"recurringEventId"}.getStr
  if j{"recurrence"} != nil: result.repeat = googleRepeat(j{"recurrence"})

proc draftOf*(e: Event): EventDraft =
  ## A stored event as the window changes it.
  result = EventDraft(title: e.title, start: e.start, finish: e.finish, allDay: e.allDay,
                      location: e.location, description: e.notes, reminder: e.reminder,
                      online: e.joinUrl.len > 0)
  for a in e.attendees: result.attendees.add person(a.name, a.email)
  for r in Repeat:
    if $r == e.repeat: result.repeat = r

proc changedParts*(was, now: EventDraft): set[DraftPart] =
  ## What a change made to an event (what is to be sent).
  if was.title != now.title: result.incl dpTitle
  if was.start != now.start or was.finish != now.finish or was.allDay != now.allDay:
    result.incl dpTime
  if was.location != now.location: result.incl dpLocation
  if was.description.replace("\r\n", "\n").strip != now.description.replace("\r\n", "\n").strip:
    result.incl dpDescription
  var a, b: seq[string]
  for x in attendeesOf(was): a.add x.email.toLowerAscii
  for x in attendeesOf(now): b.add x.email.toLowerAscii
  if sorted(a) != sorted(b): result.incl dpAttendees
  if was.reminder != now.reminder: result.incl dpReminder
  if was.online != now.online: result.incl dpOnline
  if was.repeat != now.repeat: result.incl dpRepeat

# ---- through the sync thread: as JSON -------------------------------------------------------

proc toJson*(e: EventDraft): JsonNode =
  %*{"title": e.title, "start": e.start, "finish": e.finish, "allDay": e.allDay,
     "location": e.location, "description": e.description, "attendees": e.attendees,
     "reminder": e.reminder, "online": e.online, "repeat": $e.repeat, "timeZone": e.timeZone}

proc draftFromJson*(j: JsonNode): EventDraft =
  if j == nil or j.kind != JObject: return EventDraft(reminder: -1)
  result = EventDraft(title: j{"title"}.getStr, start: j{"start"}.getFloat, finish: j{"finish"}.getFloat,
                      allDay: j{"allDay"}.getBool, location: j{"location"}.getStr,
                      description: j{"description"}.getStr, reminder: j{"reminder"}.getInt(-1),
                      online: j{"online"}.getBool, timeZone: j{"timeZone"}.getStr)
  for a in j{"attendees"}.getElems: result.attendees.add a.getStr
  for r in Repeat:
    if $r == j{"repeat"}.getStr: result.repeat = r

proc toJson*(parts: set[DraftPart]): JsonNode =
  result = newJArray()
  for p in parts: result.add %($p)

proc partsFromJson*(j: JsonNode): set[DraftPart] =
  if j == nil or j.kind != JArray: return AllParts
  for x in j:
    for p in DraftPart:
      if $p == x.getStr: result.incl p

# ---- the calls -----------------------------------------------------------------------------

const graphSelect = "id,subject,start,end,isAllDay,location,organizer,isOrganizer,attendees," &
  "isOnlineMeeting,onlineMeeting,onlineMeetingUrl,body,isReminderOn,reminderMinutesBeforeStart," &
  "type,seriesMasterId,recurrence"
const graphPrefer = ("Prefer", "outlook.timezone=\"UTC\", outlook.body-content-type=\"text\"")

proc gcalEvents(id = ""): string =
  gcalBase() & "/calendars/primary/events" & (if id.len > 0: "/" & id else: "")

proc requestId(): string =
  var r: array[12, byte]
  discard urandom(r)
  result = "retro-"
  for x in r: result.add toHex(int(x), 2).toLowerAscii

proc teamsAllowed(token: string): bool =
  ## The account can have Teams meetings (Microsoft 365 for work or school).
  try:
    let j = callJson("GET", graphBase() & "/me/calendar?$select=allowedOnlineMeetingProviders", token,
                     what = "the calendar")
    for p in j{"allowedOnlineMeetingProviders"}.getElems:
      if p.getStr == "teamsForBusiness": return true
  except ApiError: discard

proc graphSeries(token: string; ids: seq[string]): Table[string, string] =
  ## The patterns of these series (20 to a $batch request).
  var i = 0
  while i < ids.len:
    var batch = %*{"requests": []}
    for k in i ..< min(i + 20, ids.len):
      batch["requests"].add %*{"id": $k, "method": "GET",
                               "url": "/me/events/" & ids[k] & "?$select=id,recurrence"}
    let r = callJson("POST", graphBase() & "/$batch", token, batch, what = "the series")
    for resp in r{"responses"}.getElems:
      if resp{"status"}.getInt == 200:
        result[resp{"body"}{"id"}.getStr] = graphRepeat(resp{"body"}{"recurrence"})
    i += 20

proc calendarEvents*(acc: Account; token: string; fromT, toT: float): seq[Event] =
  ## The account's events between `fromT` and `toT`, each event of a
  ## series on its own (with the series' id and pattern).
  case acc.kind
  of akGraph:
    var next = graphBase() & "/me/calendarView?startDateTime=" & isoTime(fromT) & "&endDateTime=" &
               isoTime(toT) & "&$select=" & graphSelect & "&$top=200"
    var pages = 0
    while next.len > 0 and pages < 10:
      inc pages
      let j = callJson("GET", next, token, extra = [graphPrefer], what = "the calendar")
      for e in j{"value"}.getElems: result.add graphEvent(e, acc.id, acc.email)
      next = j{"@odata.nextLink"}.getStr
    var ids: seq[string]
    for e in result:
      if e.series.len > 0 and e.series notin ids: ids.add e.series
    if ids.len > 0:
      try:
        let pats = graphSeries(token, ids)
        for e in result.mitems: e.repeat = pats.getOrDefault(e.series, e.repeat)
      except ApiError: discard
  of akGmail:
    var page = ""
    var defaultReminder = 10
    for n in 0 ..< 10:
      var u = gcalEvents() & "?singleEvents=true&orderBy=startTime&maxResults=250&timeMin=" &
              urlEncode(isoTime(fromT)) & "&timeMax=" & urlEncode(isoTime(toT))
      if page.len > 0: u.add "&pageToken=" & page
      let j = callJson("GET", u, token, what = "the calendar")
      for d in j{"defaultReminders"}.getElems:
        if d{"method"}.getStr == "popup": defaultReminder = d{"minutes"}.getInt(defaultReminder)
      for e in j{"items"}.getElems:
        if e{"status"}.getStr == "cancelled": continue
        result.add googleEvent(e, acc.id, acc.email, defaultReminder)
      page = j{"nextPageToken"}.getStr
      if page.len == 0: break
    var pats = initTable[string, string]()
    for e in result.mitems:
      if e.series.len == 0: continue
      if not pats.hasKey(e.series) and pats.len < 40:
        pats[e.series] = ""
        try:
          let m = callJson("GET", gcalEvents(e.series) & "?fields=id,recurrence", token, what = "the series")
          pats[e.series] = googleRepeat(m{"recurrence"})
        except ApiError: discard
      e.repeat = pats.getOrDefault(e.series)

proc eventTimes(acc: Account; token, id: string): tuple[start, finish: float] =
  ## When event `id` (a series: its first) starts and ends.
  let e = case acc.kind
          of akGraph:
            graphEvent(callJson("GET", graphBase() & "/me/events/" & id & "?$select=start,end,isAllDay",
                                token, extra = [graphPrefer], what = "the series"), acc.id)
          of akGmail:
            googleEvent(callJson("GET", gcalEvents(id), token, what = "the series"), acc.id)
  (e.start, e.finish)

proc createEvent*(acc: Account; token: string; e: EventDraft): string =
  ## Puts a new event in the account's calendar; its id. The attendees get
  ## the invitation from the service. Raises ValueError for times that do
  ## not make an event, ApiError when the service refuses.
  let e = checked(e)
  case acc.kind
  of akGraph:
    let body = graphEventJson(e, AllParts, teams = e.online and teamsAllowed(token))
    callJson("POST", graphBase() & "/me/events", token, body, what = "the new event"){"id"}.getStr
  of akGmail:
    let body = googleEventJson(e, AllParts, requestId())
    callJson("POST", gcalEvents() & "?sendUpdates=all" & (if e.online: "&conferenceDataVersion=1" else: ""),
             token, body, what = "the new event"){"id"}.getStr

proc updateEvent*(acc: Account; token, id: string; e: EventDraft; parts = AllParts;
                  occurrence = 0.0) =
  ## Changes event `id`: only `parts` of it are sent (the rest stays as the
  ## service has it); the attendees hear of it from the service.
  ## `occurrence`: `id` is a series, changed from one of its events, which
  ## started then -- the series' times move by as much as that one's did.
  if parts.len == 0: return
  var e = checked(e)
  if occurrence > 0 and (dpTime in parts or dpRepeat in parts):
    let s = eventTimes(acc, token, id)
    let length = e.finish - e.start
    e.start = s.start + (e.start - occurrence)
    e.finish = e.start + length
  case acc.kind
  of akGraph:
    let teams = dpOnline in parts and e.online and teamsAllowed(token)
    discard callJson("PATCH", graphBase() & "/me/events/" & id, token, graphEventJson(e, parts, teams),
                     what = "the event")
  of akGmail:
    discard callJson("PATCH", gcalEvents(id) & "?sendUpdates=all" &
                     (if dpOnline in parts: "&conferenceDataVersion=1" else: ""), token,
                     googleEventJson(e, parts, requestId(), patch = true), what = "the event")

proc deleteEvent*(acc: Account; token, id: string; cancel = true; comment = "") =
  ## Takes event `id` out of the calendar. `cancel`: a meeting the account
  ## organizes, called off -- its attendees get the cancellation (with
  ## `comment`, Microsoft 365). An event already gone is not an error.
  case acc.kind
  of akGraph:
    var r = if cancel: call("POST", graphBase() & "/me/events/" & id & "/cancel", token,
                            $(%*{"comment": comment}))
            else: call("DELETE", graphBase() & "/me/events/" & id, token)
    if cancel and r.status in [400, 403]:          # (not the organizer's: only taken out)
      r = call("DELETE", graphBase() & "/me/events/" & id, token)
    if not r.ok and r.status != 404: fail(r, "the delete")
  of akGmail:
    let r = call("DELETE", gcalEvents(id) & "?sendUpdates=" & (if cancel: "all" else: "none"), token)
    if not r.ok and r.status notin [404, 410]: fail(r, "the delete")

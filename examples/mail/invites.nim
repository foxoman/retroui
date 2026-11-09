## Retro Mail: meeting invitations in mail -- what a message invites to
## (when, where, who asks) and the answer to it. Microsoft 365 and
## Outlook.com: the event the invitation put in the calendar (Graph's
## eventMessage), answered through the calendar. Gmail: the message's
## iCalendar part (METHOD:REQUEST), answered with an iCalendar REPLY mailed
## to the organizer (iMIP, RFC 6047).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[json, strutils, times, sysrand, base64]
import retroui/[http, mime]
import api, store, gmail, ical, imapsync

type
  InviteKind* = enum
    ikNone        ## not about a meeting
    ikRequest     ## an invitation (or a change to one) to answer
    ikCancel      ## the meeting was called off
    ikReply       ## someone's answer to a meeting the account organizes
  InviteAnswer* = enum
    iaNone = "none"            ## not answered (yet)
    iaAccept = "accepted"
    iaTentative = "tentative"
    iaDecline = "declined"
  Invite* = object
    kind*: InviteKind
    uid*: string               ## the meeting's iCalendar UID
    eventId*: string           ## Graph: its event in the calendar (the answer goes there)
    sequence*: int             ## its revision (SEQUENCE)
    title*, location*, description*: string
    start*, finish*: float     ## epoch seconds; whole days: local midnights, the end exclusive
    allDay*, recurring*: bool
    recurrenceId*: string      ## one occurrence of a series: its RECURRENCE-ID in UTC (or a DATE)
    organizerName*, organizerEmail*: string
    attendeeName*, attendeeEmail*: string  ## the account among the attendees ("" not listed)
    answer*: InviteAnswer      ## what the account answered so far
    rsvp*: bool                ## an answer is asked for
    replyName*, replyEmail*: string        ## ikReply: who answered
    replyAnswer*: InviteAnswer             ## ikReply: what
    threadId*, msgId*, subject*: string    ## the message's (the answer goes in its thread)

proc answerOf(partstat: string): InviteAnswer =
  case partstat.strip.toUpperAscii
  of "ACCEPTED": iaAccept
  of "TENTATIVE": iaTentative
  of "DECLINED": iaDecline
  else: iaNone

proc partstat(a: InviteAnswer): string =
  case a
  of iaAccept: "ACCEPTED"
  of iaTentative: "TENTATIVE"
  of iaDecline: "DECLINED"
  of iaNone: "NEEDS-ACTION"

# ---- iCalendar -----------------------------------------------------------------------------

proc parseInvite*(ics: string; me: string; methodHint = ""): Invite =
  ## The invitation in an iCalendar text, as seen by address `me`. ikNone
  ## when it is not one (no VEVENT, METHOD:PUBLISH...). `methodHint`: the
  ## method the MIME part's Content-Type names, for a text without METHOD.
  let root = parseIcal(ics)
  let cal = root.child("VCALENDAR")
  if cal.isNil: return
  var meth = cal.prop("METHOD").value.strip.toUpperAscii
  if meth.len == 0: meth = methodHint.strip.toUpperAscii
  let evs = cal.children("VEVENT")
  if evs.len == 0: return
  var ev = evs[0]
  for e in evs:                        # (the series itself before one occurrence of it)
    if e.prop("RECURRENCE-ID").name.len == 0:
      ev = e
      break
  result.kind = case meth
                of "REQUEST", "ADD": ikRequest
                of "CANCEL": ikCancel
                of "REPLY": ikReply
                else: ikNone
  if result.kind == ikNone: return
  result.uid = ev.prop("UID").value.strip
  result.sequence = (try: parseInt(ev.prop("SEQUENCE").value.strip) except ValueError: 0)
  result.title = ev.text("SUMMARY")
  result.location = ev.text("LOCATION")
  result.description = ev.text("DESCRIPTION")
  result.recurring = ev.prop("RRULE").name.len > 0
  let (s, allDay) = timeOf(cal, ev.prop("DTSTART"))
  result.start = s
  result.allDay = allDay
  let dtend = ev.prop("DTEND")
  if dtend.name.len > 0:
    result.finish = timeOf(cal, dtend).t
  elif ev.prop("DURATION").name.len > 0:
    result.finish = s + durationSecs(ev.prop("DURATION").value)
  else:
    result.finish = if allDay: s + 86400 else: s
  let rid = ev.prop("RECURRENCE-ID")
  if rid.name.len > 0:
    let (rt, rDay) = timeOf(cal, rid)
    result.recurrenceId = if rDay: dateStamp(rt) else: utcStamp(rt)
  let org = ev.prop("ORGANIZER")
  result.organizerEmail = mailto(org.value)
  result.organizerName = org.param("CN")
  let mine = me.strip.toLowerAscii
  let atts = ev.props("ATTENDEE")
  for a in atts:
    let email = mailto(a.value)
    if mine.len > 0 and email.toLowerAscii == mine:
      result.attendeeEmail = email
      result.attendeeName = a.param("CN")
      result.answer = answerOf(a.param("PARTSTAT"))
      result.rsvp = a.param("RSVP").toUpperAscii == "TRUE"
  if result.kind == ikReply and atts.len > 0:
    result.replyEmail = mailto(atts[0].value)
    result.replyName = atts[0].param("CN")
    result.replyAnswer = answerOf(atts[0].param("PARTSTAT"))
  if result.kind == ikRequest and ev.prop("STATUS").value.strip.toUpperAscii == "CANCELLED":
    result.kind = ikCancel

proc replyIcs*(inv: Invite; answer: InviteAnswer; myName, myEmail: string; comment = "";
               now = 0.0): string =
  ## The iCalendar REPLY (RFC 5546 3.2.3) answering `inv` for `myEmail`:
  ## the same UID and SEQUENCE, the account's ATTENDEE with its PARTSTAT.
  let t = if now == 0: epochTime() else: now
  let who = if inv.attendeeEmail.len > 0: inv.attendeeEmail else: myEmail
  let cn = if myName.len > 0: myName else: inv.attendeeName
  var lines = @["BEGIN:VCALENDAR", "PRODID:-//foxoman.net//Retro Mail//EN", "VERSION:2.0",
                "CALSCALE:GREGORIAN", "METHOD:REPLY", "BEGIN:VEVENT", "UID:" & inv.uid]
  if inv.recurrenceId.len > 0:
    lines.add(if inv.recurrenceId.len == 8: "RECURRENCE-ID;VALUE=DATE:" & inv.recurrenceId
              else: "RECURRENCE-ID:" & inv.recurrenceId)
  lines.add "SEQUENCE:" & $inv.sequence
  lines.add "DTSTAMP:" & utcStamp(t)
  if inv.start > 0:
    if inv.allDay:
      lines.add "DTSTART;VALUE=DATE:" & dateStamp(inv.start)
      lines.add "DTEND;VALUE=DATE:" & dateStamp(max(inv.finish, inv.start + 86400))
    else:
      lines.add "DTSTART:" & utcStamp(inv.start)
      lines.add "DTEND:" & utcStamp(max(inv.finish, inv.start))
  if inv.title.len > 0: lines.add "SUMMARY:" & escapeText(inv.title)
  lines.add "ORGANIZER" & (if inv.organizerName.len > 0: ";CN=" & paramValue(inv.organizerName) else: "") &
            ":mailto:" & inv.organizerEmail
  lines.add "ATTENDEE;PARTSTAT=" & partstat(answer) & (if cn.len > 0: ";CN=" & paramValue(cn) else: "") &
            ":mailto:" & who
  if comment.strip.len > 0: lines.add "COMMENT:" & escapeText(comment.strip)
  lines.add ["END:VEVENT", "END:VCALENDAR"]
  for l in lines: result.add foldLine(l)

proc mimePart(contentType, text: string): string =
  ## A text part: 7bit when it is short-lined ASCII, else base64.
  var plain = true
  for l in text.split('\n'):
    if l.len > 76: (plain = false; break)
  for c in text:
    if ord(c) > 126 or (ord(c) < 32 and c notin {'\r', '\n', '\t'}): (plain = false; break)
  result = "Content-Type: " & contentType & "\r\n"
  if plain:
    result.add "Content-Transfer-Encoding: 7bit\r\n\r\n"
    result.add text.replace("\r\n", "\n").replace("\n", "\r\n")
  else:
    result.add "Content-Transfer-Encoding: base64\r\n\r\n"
    let b = encode(text)
    var i = 0
    while i < b.len:
      result.add b[i ..< min(i + 76, b.len)] & "\r\n"
      i += 76

proc replyMail*(inv: Invite; answer: InviteAnswer; me: MailAddress; comment = ""; now = 0.0): string =
  ## The message that carries the REPLY to the organizer: a line of text
  ## and the text/calendar (method=REPLY) as multipart/alternative.
  let t = if now == 0: epochTime() else: now
  let verb = case answer
             of iaAccept: ("Accepted: ", "accepted")
             of iaTentative: ("Tentative: ", "tentatively accepted")
             else: ("Declined: ", "declined")
  var text = (if me.name.len > 0: me.name else: me.email) & " has " & verb[1] & " this invitation."
  if comment.strip.len > 0: text.add "\n\n" & comment.strip
  # (buildMail writes the headers -- encoded words, dates, ids -- but a part
  # of its own carries no Content-Type parameters such as method=REPLY)
  let head = buildMail(OutMail(fromAddr: me, to: @[MailAddress(name: inv.organizerName,
                               email: inv.organizerEmail)], subject: verb[0] & inv.title,
                               text: "-", inReplyTo: inv.msgId, references: inv.msgId, date: t))
  const mv = "\r\nMIME-Version: 1.0\r\n"
  let k = head.find(mv)
  result = head[0 ..< k + mv.len]
  var r: array[12, byte]
  discard urandom(r)
  var b = "=_retro_ical_"
  for x in r: b.add toHex(int(x), 2).toLowerAscii
  result.add "Content-Type: multipart/alternative; boundary=\"" & b & "\"\r\n\r\n"
  result.add "--" & b & "\r\n" & mimePart("text/plain; charset=utf-8", text) & "\r\n"
  result.add "--" & b & "\r\n" &
             mimePart("text/calendar; charset=utf-8; method=REPLY", replyIcs(inv, answer, me.name, me.email, comment, t)) &
             "\r\n"
  result.add "--" & b & "--\r\n"

# ---- Microsoft Graph -------------------------------------------------------------------------

proc graphTime(j: JsonNode; allDay: bool): float =
  let dt = j{"dateTime"}.getStr
  if allDay:
    localMidnight(parseStamp(dt))
  else:
    zoneToUtc(dt, j{"timeZone"}.getStr("UTC"))

proc graphAnswer(response: string): InviteAnswer =
  case response
  of "accepted": iaAccept
  of "tentativelyAccepted": iaTentative
  of "declined": iaDecline
  else: iaNone

proc graphInvite*(j: JsonNode): Invite =
  ## The invitation of a Graph message read with
  ## `$expand=microsoft.graph.eventMessage/event`; ikNone for other mail.
  let mt = j{"meetingMessageType"}.getStr
  result.kind = case mt
                of "meetingRequest": ikRequest
                of "meetingCancelled": ikCancel
                of "meetingAccepted", "meetingTenativelyAccepted", "meetingTentativelyAccepted",
                   "meetingDeclined": ikReply
                else: ikNone
  if result.kind == ikNone: return
  result.msgId = j{"internetMessageId"}.getStr
  result.threadId = j{"conversationId"}.getStr
  result.subject = j{"subject"}.getStr
  let ev = j{"event"}
  if ev != nil and ev.kind == JObject:
    result.eventId = ev{"id"}.getStr
    result.uid = ev{"iCalUId"}.getStr
    result.title = ev{"subject"}.getStr
    result.allDay = ev{"isAllDay"}.getBool
    result.start = graphTime(ev{"start"}, result.allDay)
    result.finish = graphTime(ev{"end"}, result.allDay)
    result.location = ev{"location"}{"displayName"}.getStr
    result.organizerName = ev{"organizer"}{"emailAddress"}{"name"}.getStr
    result.organizerEmail = ev{"organizer"}{"emailAddress"}{"address"}.getStr
    result.answer = graphAnswer(ev{"responseStatus"}{"response"}.getStr)
    result.rsvp = ev{"responseRequested"}.getBool(true)
    result.recurring = ev{"type"}.getStr in ["seriesMaster", "occurrence"] or
                       (ev{"recurrence"} != nil and ev{"recurrence"}.kind == JObject)
    result.description = ev{"bodyPreview"}.getStr
    if ev{"isCancelled"}.getBool and result.kind == ikRequest: result.kind = ikCancel
  else:
    # (no event: what the message itself says)
    result.title = j{"subject"}.getStr
    result.allDay = j{"isAllDay"}.getBool
    if j{"startDateTime"} != nil: result.start = graphTime(j{"startDateTime"}, result.allDay)
    if j{"endDateTime"} != nil: result.finish = graphTime(j{"endDateTime"}, result.allDay)
    result.location = j{"location"}{"displayName"}.getStr
    result.organizerName = j{"from"}{"emailAddress"}{"name"}.getStr
    result.organizerEmail = j{"from"}{"emailAddress"}{"address"}.getStr
  if result.kind == ikReply:
    result.replyName = j{"from"}{"emailAddress"}{"name"}.getStr
    result.replyEmail = j{"from"}{"emailAddress"}{"address"}.getStr
    result.replyAnswer = case mt
                         of "meetingAccepted": iaAccept
                         of "meetingDeclined": iaDecline
                         else: iaTentative

# ---- Gmail -------------------------------------------------------------------------------

proc headerOf(part: JsonNode; name: string): string =
  for h in part{"headers"}.getElems:
    if cmpIgnoreCase(h{"name"}.getStr, name) == 0: return h{"value"}.getStr

proc gmailInvite*(token, remoteId: string; j: JsonNode; me: string): Invite =
  ## The invitation in a Gmail message (format=full): its text/calendar
  ## part (or an .ics file), fetched when it is kept apart; ikNone when it
  ## has none.
  var best: JsonNode = nil
  var bestRank = 0
  proc walk(p: JsonNode; best: var JsonNode; bestRank: var int) =
    if p == nil: return
    let mt = p{"mimeType"}.getStr.toLowerAscii
    if mt.startsWith("multipart/"):
      for c in p{"parts"}.getElems: walk(c, best, bestRank)
      return
    let ct = headerOf(p, "content-type").toLowerAscii
    let rank = if mt == "text/calendar" and "method=" in ct: 3
               elif mt == "text/calendar": 2
               elif mt == "application/ics" or p{"filename"}.getStr.toLowerAscii.endsWith(".ics"): 1
               else: 0
    if rank > bestRank:
      best = p
      bestRank = rank
  walk(j{"payload"}, best, bestRank)
  if best == nil: return
  var data = ""
  let body = best{"body"}
  if body{"data"}.getStr.len > 0: data = base64UrlDecode(body{"data"}.getStr)
  elif body{"attachmentId"}.getStr.len > 0:
    data = gmailAttachment(token, remoteId, body{"attachmentId"}.getStr)
  if data.len == 0: return
  let ct = headerOf(best, "content-type")
  let params = parseMime("Content-Type: " & ct & "\r\n\r\n")
  let charset = params.param("charset")
  result = parseInvite(toUtf8(data, if charset.len > 0: charset else: "utf-8"), me, params.param("method"))
  if result.kind == ikNone: return
  result.threadId = j{"threadId"}.getStr
  result.msgId = headerOf(j{"payload"}, "message-id").strip
  result.subject = decodeWords(headerOf(j{"payload"}, "subject"))

# ---- the calls ---------------------------------------------------------------------------

proc inviteOf*(acc: Account; token: string; m: Msg): Invite =
  ## The invitation message `m` carries; kind ikNone when it carries none.
  case acc.kind
  of akGraph:
    let r = call("GET", graphBase() & "/me/messages/" & m.remoteId &
                 "?$expand=microsoft.graph.eventMessage/event", token,
                 extra = [("Prefer", "outlook.timezone=\"UTC\"")])
    if r.status == 400: return            # (not an event message)
    if not r.ok: fail(r, "the invitation")
    let j = try: parseJson(r.body) except CatchableError: newJObject()
    result = graphInvite(j)
  of akGmail:
    let j = callJson("GET", gmailBase() & "/gmail/v1/users/me/messages/" & m.remoteId &
                     "?format=full", token, what = "the invitation")
    result = gmailInvite(token, m.remoteId, j, acc.email)
  of akImap:
    let ics = calendarPart(imapRaw(acc, token, m.remoteId))
    if ics.len == 0: return
    result = parseInvite(ics, acc.email)
  if result.kind == ikNone: return
  if result.threadId.len == 0: result.threadId = m.thread
  if result.msgId.len == 0: result.msgId = m.msgId
  if result.subject.len == 0: result.subject = m.subject

proc respondInvite*(acc: Account; token: string; inv: Invite; answer: InviteAnswer;
                    comment = ""; sendReply = true) =
  ## Answers an invitation (`sendReply` false: without telling the
  ## organizer). Graph: the calendar's event is accepted, tentatively
  ## accepted or declined. Gmail: an iCalendar REPLY goes to the organizer
  ## in the invitation's thread (without `sendReply` nothing goes: the
  ## organizer's calendar is where the answer is kept). Raises ValueError
  ## for no answer or what cannot be answered, ApiError when the service
  ## refuses.
  if answer == iaNone: raise newException(ValueError, "no answer chosen")
  if inv.kind != ikRequest: raise newException(ValueError, "this is not an invitation to answer")
  case acc.kind
  of akGraph:
    if inv.eventId.len == 0: raise newException(ValueError, "the meeting is not in the calendar")
    let action = case answer
                 of iaAccept: "accept"
                 of iaTentative: "tentativelyAccept"
                 else: "decline"
    discard callJson("POST", graphBase() & "/me/events/" & inv.eventId & "/" & action, token,
                     %*{"comment": comment, "sendResponse": sendReply}, what = "the answer")
  of akGmail:
    if not sendReply: return
    if inv.organizerEmail.len == 0: raise newException(ValueError, "the invitation names no organizer")
    gmailSend(token, replyMail(inv, answer, MailAddress(name: acc.name, email: acc.email), comment),
              inv.threadId)
  of akImap:
    if not sendReply: return
    if inv.organizerEmail.len == 0: raise newException(ValueError, "the invitation names no organizer")
    let raw = replyMail(inv, answer, MailAddress(name: acc.name, email: acc.email), comment)
    discard smtpSendRaw(acc, token, [inv.organizerEmail], raw)
    try: appendSent(acc, token, raw)
    except CatchableError: discard

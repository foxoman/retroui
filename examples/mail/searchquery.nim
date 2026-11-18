## Retro Mail: what was typed in the search box -- words, and from: to:
## subject: has:attachment is:unread is:flagged before: after: -- said the
## way each server's own search wants it (IMAP's SEARCH, Gmail's q,
## Microsoft Graph's $search, JMAP's filter, Exchange's AQS), so a search
## on the server finds what the same search finds here.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, times, json]

type
  SearchQuery* = object
    words*: seq[string]
    froms*, tos*, subjects*: seq[string]
    attachment*, unread*, read*, flagged*: bool
    before*, after*: float      ## epoch seconds (0: none)

proc quoteWord(s: string): string =
  if s.len > 0 and s[0] == '"' and s[^1] == '"': s[1 .. ^2] else: s

proc parseQuery*(q: string): SearchQuery =
  ## The search box's words and operators (the same as the search here).
  for raw in q.splitWhitespace:
    let k = raw.find(':')
    let key = if k > 0: raw[0 ..< k].toLowerAscii else: ""
    let val = quoteWord(if k > 0: raw[k + 1 .. ^1] else: raw)
    case key
    of "from": result.froms.add val
    of "to", "cc": result.tos.add val
    of "subject": result.subjects.add val
    of "has":
      if val.toLowerAscii.startsWith("att"): result.attachment = true
    of "is":
      case val.toLowerAscii
      of "unread": result.unread = true
      of "read": result.read = true
      of "flagged", "starred": result.flagged = true
      else: discard
    of "before", "after":
      try:
        let t = parse(val, "yyyy-MM-dd", local()).toTime.toUnixFloat
        if key == "before": result.before = t else: result.after = t
      except CatchableError: result.words.add val
    of "tag", "in": discard            # (this app's own: not the server's)
    else: result.words.add val

proc imapQuoted(s: string): string = "\"" & s.multiReplace(("\\", "\\\\"), ("\"", "\\\"")) & "\""

proc imapCriteria*(q: SearchQuery): string =
  ## IMAP's SEARCH criteria (RFC 9051): FROM "x" SUBJECT "y" UNSEEN TEXT "z".
  var parts: seq[string]
  for f in q.froms: parts.add "FROM " & imapQuoted(f)
  for t in q.tos: parts.add "OR TO " & imapQuoted(t) & " CC " & imapQuoted(t)
  for s in q.subjects: parts.add "SUBJECT " & imapQuoted(s)
  if q.unread: parts.add "UNSEEN"
  if q.read: parts.add "SEEN"
  if q.flagged: parts.add "FLAGGED"
  # (IMAP's dates are days, as typed)
  if q.before > 0: parts.add "BEFORE " & fromUnixFloat(q.before).local.format("d-MMM-yyyy")
  if q.after > 0: parts.add "SINCE " & fromUnixFloat(q.after).local.format("d-MMM-yyyy")
  for w in q.words: parts.add "TEXT " & imapQuoted(w)
  if q.attachment and parts.len == 0: parts.add "HEADER Content-Type \"multipart/mixed\""
  if parts.len == 0: "ALL" else: parts.join(" ")

proc gmailQ*(q: SearchQuery): string =
  ## Gmail's search (its q): much like this box's own.
  var parts: seq[string]
  for f in q.froms: parts.add "from:" & f
  for t in q.tos: parts.add "to:" & t
  for s in q.subjects: parts.add "subject:" & s
  if q.attachment: parts.add "has:attachment"
  if q.unread: parts.add "is:unread"
  if q.read: parts.add "is:read"
  if q.flagged: parts.add "is:starred"
  if q.before > 0: parts.add "before:" & fromUnixFloat(q.before).local.format("yyyy/MM/dd")
  if q.after > 0: parts.add "after:" & fromUnixFloat(q.after).local.format("yyyy/MM/dd")
  for w in q.words: parts.add (if ' ' in w: "\"" & w & "\"" else: w)
  parts.join(" ")

proc graphKql*(q: SearchQuery): string =
  ## Microsoft Graph's $search (KQL): from:x AND subject:y AND words.
  var parts: seq[string]
  for f in q.froms: parts.add "from:" & f
  for t in q.tos: parts.add "to:" & t
  for s in q.subjects: parts.add "subject:" & s
  if q.attachment: parts.add "hasAttachments:true"
  if q.before > 0: parts.add "received<" & fromUnixFloat(q.before).local.format("yyyy-MM-dd")
  if q.after > 0: parts.add "received>=" & fromUnixFloat(q.after).local.format("yyyy-MM-dd")
  for w in q.words: parts.add w
  parts.join(" AND ")

proc jmapFilter*(q: SearchQuery): JsonNode =
  ## JMAP's Email/query filter (RFC 8621): one condition, all of it to match.
  result = newJObject()
  if q.froms.len > 0: result["from"] = %q.froms.join(" ")
  if q.tos.len > 0: result["to"] = %q.tos.join(" ")
  if q.subjects.len > 0: result["subject"] = %q.subjects.join(" ")
  if q.words.len > 0: result["text"] = %q.words.join(" ")
  if q.attachment: result["hasAttachment"] = %true
  if q.unread: result["notKeyword"] = %"$seen"
  if q.read: result["hasKeyword"] = %"$seen"
  if q.flagged: result["hasKeyword"] = %"$flagged"
  if q.before > 0: result["before"] = %utc(fromUnixFloat(q.before)).format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  if q.after > 0: result["after"] = %utc(fromUnixFloat(q.after)).format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc ewsQuery*(q: SearchQuery): string =
  ## Exchange's AQS: from:x subject:y hasattachment:true words.
  var parts: seq[string]
  for f in q.froms: parts.add "from:" & f
  for t in q.tos: parts.add "to:" & t
  for s in q.subjects: parts.add "subject:" & s
  if q.attachment: parts.add "hasattachment:true"
  if q.unread: parts.add "isread:false"
  if q.flagged: parts.add "isflagged:true"
  if q.before > 0: parts.add "received<" & fromUnixFloat(q.before).local.format("yyyy-MM-dd")
  if q.after > 0: parts.add "received>=" & fromUnixFloat(q.after).local.format("yyyy-MM-dd")
  for w in q.words: parts.add w
  parts.join(" ")

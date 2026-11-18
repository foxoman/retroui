## Gmail through the Gmail API: labels (folders and tags), messages (a
## full sync, then history), bodies, attachments, changes, sending, server
## search. (Google Calendar: calendar.nim.)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[json, strutils, times, tables, os]
import retroui/[http, mime]
import api, store

const
  gmailScopes* = ["openid", "email", "profile", "https://www.googleapis.com/auth/gmail.modify",
                  "https://www.googleapis.com/auth/gmail.settings.basic",
                  "https://www.googleapis.com/auth/calendar.events"]
  metaHeaders = ["From", "To", "Cc", "Subject", "Date", "Message-ID", "In-Reply-To", "References"]
  systemFolders* = [("INBOX", "Inbox", "inbox"), ("DRAFT", "Drafts", "drafts"),
                    ("SENT", "Sent Mail", "sent"), ("ARCHIVE", "All Mail", "archive"),
                    ("SPAM", "Spam", "junk"), ("TRASH", "Trash", "trash")]
  ## (ARCHIVE is not a Gmail label: mail without INBOX, SENT, DRAFT, SPAM or TRASH)

type
  GmailBody* = object
    html*, text*, toList*, ccList*: string
    unsub*, unsubPost*: string   ## List-Unsubscribe and List-Unsubscribe-Post (a newsletter's)
    atts*: seq[tuple[remoteId, name, mime, cid: string; size: int; inline: bool; data: string; hasData: bool]]
    headers*: seq[(string, string)]   ## all its header fields, top first (who it is from: retroui/mailauth)
  GmailLabel* = object
    id*, name*, kind*, color*: string
    unread*, total*: int

proc api(path: string): string = gmailBase() & "/gmail/v1/users/me" & path

proc unescapeHtml(s: string): string =
  s.multiReplace(("&#39;", "'"), ("&quot;", "\""), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                 ("&nbsp;", " "))

proc roleOf*(labels: openArray[string]): string =
  ## Where a message with these labels is shown (its folder's remote id).
  if "TRASH" in labels: "TRASH"
  elif "SPAM" in labels: "SPAM"
  elif "INBOX" in labels: "INBOX"
  elif "DRAFT" in labels: "DRAFT"
  elif "SENT" in labels: "SENT"
  else: "ARCHIVE"

proc gmailProfile*(token: string): tuple[email, history: string] =
  let j = callJson("GET", api("/profile"), token, what = "your profile")
  (j{"emailAddress"}.getStr, j{"historyId"}.getStr)

proc gmailLabels*(token: string): seq[GmailLabel] =
  let j = callJson("GET", api("/labels"), token, what = "the labels")
  for l in j{"labels"}.getElems:
    var g = GmailLabel(id: l{"id"}.getStr, name: l{"name"}.getStr, kind: l{"type"}.getStr,
                       color: l{"color"}{"backgroundColor"}.getStr)
    result.add g

proc labelCounts*(token, id: string): tuple[unread, total: int] =
  let j = callJson("GET", api("/labels/" & id), token, what = "a label")
  (j{"messagesUnread"}.getInt, j{"messagesTotal"}.getInt)

proc parseMeta*(j: JsonNode; account: int; me: string;
                labelNames: Table[string, string]): tuple[msg: Msg; folderRemote: string] =
  ## A message's metadata (format=metadata or full) as the store keeps it.
  var m = Msg(account: account, remoteId: j{"id"}.getStr, thread: j{"threadId"}.getStr)
  var labels: seq[string]
  for l in j{"labelIds"}.getElems: labels.add l.getStr
  m.labels = labels.join(" ")
  m.unread = "UNREAD" in labels
  m.flagged = "STARRED" in labels
  m.draft = "DRAFT" in labels
  m.focused = true
  for l in labels:
    if l.startsWith("CATEGORY_") and l != "CATEGORY_PERSONAL": m.focused = false
    elif labelNames.hasKey(l): m.tags.add labelNames[l]
  m.snippet = unescapeHtml(j{"snippet"}.getStr)
  m.size = j{"sizeEstimate"}.getInt
  m.date = (try: parseFloat(j{"internalDate"}.getStr("0")) / 1000 except ValueError: 0.0)
  for h in j{"payload"}{"headers"}.getElems:
    let v = h{"value"}.getStr
    case h{"name"}.getStr.toLowerAscii
    of "from":
      let a = parseAddresses(v)
      if a.len > 0:
        m.fromName = a[0].name
        m.fromEmail = a[0].email
    of "to": m.toList = decodeWords(v)
    of "cc": m.ccList = decodeWords(v)
    of "subject": m.subject = decodeWords(v)
    of "message-id": m.msgId = v.strip
    of "in-reply-to": m.inReplyTo = v.strip
    of "references": m.refs = v.strip
    else: discard
  if m.thread.len == 0: m.thread = m.remoteId
  m.mine = me.len > 0 and m.fromEmail.toLowerAscii == me.toLowerAscii
  (m, roleOf(labels))

proc gmailListIds*(token, q: string; maxTotal = 5000; labelId = ""): seq[string] =
  ## The ids of the messages `q` finds, newest first.
  var page = ""
  while result.len < maxTotal:
    var u = api("/messages?maxResults=500&includeSpamTrash=true&q=" & urlEncode(q))
    if labelId.len > 0: u.add "&labelIds=" & labelId
    if page.len > 0: u.add "&pageToken=" & page
    let j = callJson("GET", u, token, what = "the message list")
    for m in j{"messages"}.getElems: result.add m{"id"}.getStr
    page = j{"nextPageToken"}.getStr
    if page.len == 0: break

proc batchGet*(token: string; paths: seq[string]): seq[JsonNode] =
  ## Several GETs in one request (Gmail's batch endpoint); the answers in
  ## order, nil for those that failed.
  result = newSeq[JsonNode](paths.len)
  if paths.len == 0: return
  let b = "retro_batch_" & $int(epochTime() * 1000)
  var body = ""
  for i, p in paths:
    body.add "--" & b & "\r\nContent-Type: application/http\r\nContent-ID: <i" & $i & ">\r\n\r\n"
    body.add "GET " & p & "\r\n\r\n"
  body.add "--" & b & "--\r\n"
  let r = call("POST", gmailBase() & "/batch/gmail/v1", token, body,
               contentType = "multipart/mixed; boundary=" & b, timeout = 120)
  if not r.ok: fail(r, "the messages")
  var boundary = ""
  let ct = r.header("content-type")
  let k = ct.find("boundary=")
  if k >= 0:
    boundary = ct[k + 9 .. ^1].strip(chars = {'"', ' '})
    let semi = boundary.find(';')
    if semi >= 0: boundary.setLen(semi)
  if boundary.len == 0: return
  for part in r.body.split("--" & boundary):
    let p = part.strip
    if p.len == 0 or p == "--": continue
    var idx = -1
    let ci = p.find("Content-ID:")
    if ci >= 0:
      let line = p[ci .. ^1].splitLines()[0]
      let s = line.find("response-i")
      if s >= 0:
        var e = s + 10
        while e < line.len and line[e].isDigit: inc e
        idx = try: parseInt(line[s + 10 ..< e]) except ValueError: -1
    let http = p.find("HTTP/1.1 ")
    if http < 0 or idx < 0 or idx >= paths.len: continue
    let status = try: parseInt(p[http + 9 .. http + 11]) except ValueError: 0
    let jstart = p.find('{', http)
    if status == 200 and jstart >= 0:
      try: result[idx] = parseJson(p[jstart .. p.rfind('}')])
      except CatchableError: discard

proc gmailMetadata*(token: string; ids: seq[string]): seq[JsonNode] =
  ## Metadata of many messages (50 per batch request).
  var q = "?format=metadata"
  for h in metaHeaders: q.add "&metadataHeaders=" & h
  var i = 0
  while i < ids.len:
    var paths: seq[string]
    for k in i ..< min(i + 50, ids.len): paths.add "/gmail/v1/users/me/messages/" & ids[k] & q
    for j in batchGet(token, paths):
      if j != nil: result.add j
    i += 50
    if i < ids.len: sleep(150)          # (Gmail's per-second quota)

proc gmailHistory*(token, startId: string): tuple[changed, deleted: seq[string]; latest: string] =
  ## What changed since `startId`. Raises ApiError 404 when it is too old
  ## (then the caller syncs from the start).
  var page = ""
  result.latest = startId
  var seen = initTable[string, bool]()
  while true:
    var u = api("/history?maxResults=500&startHistoryId=" & startId)
    if page.len > 0: u.add "&pageToken=" & page
    let j = callJson("GET", u, token, what = "the changes")
    for h in j{"history"}.getElems:
      for key in ["messagesAdded", "labelsAdded", "labelsRemoved"]:
        for e in h{key}.getElems:
          let id = e{"message"}{"id"}.getStr
          if id.len > 0 and not seen.hasKey(id):
            seen[id] = true
            result.changed.add id
      for e in h{"messagesDeleted"}.getElems:
        result.deleted.add e{"message"}{"id"}.getStr
    if j{"historyId"}.getStr.len > 0: result.latest = j{"historyId"}.getStr
    page = j{"nextPageToken"}.getStr
    if page.len == 0: break

proc headerOf(part: JsonNode; name: string): string =
  for h in part{"headers"}.getElems:
    if h{"name"}.getStr.toLowerAscii == name: return h{"value"}.getStr

proc charsetOf(part: JsonNode): string =
  let ct = headerOf(part, "content-type")
  let k = ct.toLowerAscii.find("charset=")
  if k < 0: return "utf-8"
  result = ct[k + 8 .. ^1].strip(chars = {'"', ' ', '\''})
  let semi = result.find(';')
  if semi >= 0: result = result[0 ..< semi].strip(chars = {'"', ' '})

proc gmailBody*(token, remoteId: string): GmailBody =
  ## A message's HTML (or text), recipients and attachments (small inline
  ## pictures with their bytes).
  let j = callJson("GET", api("/messages/" & remoteId & "?format=full"), token,
                   what = "the message")
  result.toList = decodeWords(headerOf(j{"payload"}, "to"))
  result.ccList = decodeWords(headerOf(j{"payload"}, "cc"))
  result.unsub = headerOf(j{"payload"}, "list-unsubscribe").strip
  result.unsubPost = headerOf(j{"payload"}, "list-unsubscribe-post").strip
  for h in j{"payload"}{"headers"}.getElems: result.headers.add (h{"name"}.getStr, h{"value"}.getStr)
  var htmls, texts: seq[string]
  proc walk(p: JsonNode; res: var GmailBody; htmls, texts: var seq[string]) =
    if p == nil: return
    let mt = p{"mimeType"}.getStr.toLowerAscii
    let fname = p{"filename"}.getStr
    let disp = headerOf(p, "content-disposition").toLowerAscii
    let cid = headerOf(p, "content-id").strip(chars = {'<', '>', ' '})
    let body = p{"body"}
    if mt.startsWith("multipart/"):
      for c in p{"parts"}.getElems: walk(c, res, htmls, texts)
    elif fname.len == 0 and not disp.startsWith("attachment") and mt in ["text/html", "text/plain"]:
      let raw = base64UrlDecode(body{"data"}.getStr)
      let s = toUtf8(raw, charsetOf(p))
      if mt == "text/html": htmls.add s else: texts.add s
    else:
      let size = body{"size"}.getInt
      var data = ""
      var has = false
      if body{"data"}.getStr.len > 0:
        data = base64UrlDecode(body{"data"}.getStr)
        has = true
      elif cid.len > 0 and size < 3_000_000 and body{"attachmentId"}.getStr.len > 0:
        try:
          let a = callJson("GET", api("/messages/" & remoteId & "/attachments/" &
                           body{"attachmentId"}.getStr), token, what = "a picture")
          data = base64UrlDecode(a{"data"}.getStr)
          has = true
        except ApiError: discard
      let name = if fname.len > 0: decodeWords(fname) else: (if cid.len > 0: cid else: "attachment")
      res.atts.add (remoteId: body{"attachmentId"}.getStr(p{"partId"}.getStr), name: name,
                    mime: mt, cid: cid, size: size, inline: cid.len > 0 and not disp.startsWith("attachment"),
                    data: data, hasData: has)
  walk(j{"payload"}, result, htmls, texts)
  result.html = htmls.join("\n")
  result.text = texts.join("\n")

proc gmailAttachment*(token, remoteMsg, attId: string): string =
  let j = callJson("GET", api("/messages/" & remoteMsg & "/attachments/" & attId), token,
                   what = "the attachment")
  base64UrlDecode(j{"data"}.getStr)

proc gmailModify*(token, remoteId: string; add, remove: openArray[string]) =
  var a = newJArray()
  var r = newJArray()
  for x in add: a.add %x
  for x in remove: r.add %x
  discard callJson("POST", api("/messages/" & remoteId & "/modify"), token,
                   %*{"addLabelIds": a, "removeLabelIds": r}, what = "the change")

proc gmailTrash*(token, remoteId: string) =
  discard callJson("POST", api("/messages/" & remoteId & "/trash"), token, newJObject(),
                   what = "the delete")

proc gmailUntrash*(token, remoteId: string) =
  discard callJson("POST", api("/messages/" & remoteId & "/untrash"), token, newJObject(),
                   what = "the undelete")

proc gmailCreateLabel*(token, name, color: string): string =
  ## A new user label (a tag); its id. Gmail allows only its own palette of
  ## colors: without one when it refuses.
  var body = %*{"name": name, "labelListVisibility": "labelShow",
                "messageListVisibility": "show"}
  if color.len > 0: body["color"] = %*{"backgroundColor": color, "textColor": "#ffffff"}
  var r = call("POST", api("/labels"), token, $body)
  if not r.ok and color.len > 0:
    body.delete("color")
    r = call("POST", api("/labels"), token, $body)
  if r.status == 409:
    for l in gmailLabels(token):
      if l.name.toLowerAscii == name.toLowerAscii: return l.id
  if not r.ok: fail(r, "the new label")
  parseJson(r.body){"id"}.getStr

proc gmailSend*(token, raw, threadId: string) =
  ## Sends a whole message (RFC 5322 bytes), in its thread for a reply.
  let b = "retro_send_" & $int(epochTime() * 1000)
  var body = "--" & b & "\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n"
  body.add $(if threadId.len > 0: %*{"threadId": threadId} else: newJObject())
  body.add "\r\n--" & b & "\r\nContent-Type: message/rfc822\r\n\r\n" & raw & "\r\n--" & b & "--\r\n"
  let r = call("POST", gmailBase() & "/upload/gmail/v1/users/me/messages/send?uploadType=multipart",
               token, body, contentType = "multipart/related; boundary=" & b, timeout = 600)
  if not r.ok: fail(r, "sending")

proc buildRaw*(d: JsonNode; me: MailAddress): string =
  ## The RFC 5322 message for what the compose window made.
  proc addrs(j: JsonNode): seq[MailAddress] =
    for a in j.getElems: result.add MailAddress(name: a{"name"}.getStr, email: a{"email"}.getStr)
  var m = OutMail(fromAddr: me, to: addrs(d{"to"}), cc: addrs(d{"cc"}), bcc: addrs(d{"bcc"}),
                  subject: d{"subject"}.getStr, html: d{"html"}.getStr, text: d{"text"}.getStr,
                  inReplyTo: d{"inReplyTo"}.getStr, references: d{"references"}.getStr)
  if d{"important"}.getBool: m.extraHeaders.add ("Importance", "high")
  for a in d{"attachments"}.getElems:
    let path = a{"path"}.getStr
    if not fileExists(path): continue
    m.attachments.add MailAttachment(filename: a{"name"}.getStr(extractFilename(path)),
                                     contentType: a{"mime"}.getStr("application/octet-stream"),
                                     contentId: a{"cid"}.getStr, data: readFile(path),
                                     inline: a{"cid"}.getStr.len > 0)
  buildMail(m)

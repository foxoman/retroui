## Microsoft 365 and Outlook.com mail through Microsoft Graph: folders,
## messages (delta sync), bodies, attachments, changes, sending (as replies
## the server threads), categories (tags), server search. (The calendar:
## calendar.nim.)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[json, strutils, times, base64, os, tables]
import retroui/http
import api, store

const
  graphScopes* = ["offline_access", "openid", "profile", "email", "User.Read",
                  "Mail.ReadWrite", "Mail.Send", "MailboxSettings.ReadWrite", "Calendars.ReadWrite"]
  msgSelect = "id,conversationId,subject,from,toRecipients,ccRecipients,receivedDateTime," &
    "isRead,flag,importance,hasAttachments,categories,bodyPreview,inferenceClassification," &
    "parentFolderId,internetMessageId,isDraft"
  wellKnown = [("inbox", "inbox"), ("drafts", "drafts"), ("sentitems", "sent"),
               ("deleteditems", "trash"), ("archive", "archive"), ("junkemail", "junk"),
               ("outbox", "outbox")]

type
  GraphItem* = object
    msg*: Msg
    folderRemote*: string
    removed*: bool
  GraphBody* = object
    html*, toList*, ccList*, msgId*: string
    unsub*, unsubPost*: string   ## List-Unsubscribe and List-Unsubscribe-Post (a newsletter's)
    atts*: seq[tuple[remoteId, name, mime, cid: string; size: int; inline: bool; data: string; hasData: bool]]

proc url(path: string): string = graphBase() & path

proc addrList(j: JsonNode): string =
  if j == nil or j.kind != JArray: return ""
  var parts: seq[string]
  for r in j:
    let n = r{"emailAddress"}{"name"}.getStr
    let a = r{"emailAddress"}{"address"}.getStr
    parts.add(if n.len > 0 and n != a: n & " <" & a & ">" else: a)
  parts.join(", ")

proc recipients*(list: JsonNode): JsonNode =
  ## [{name, email}] as Graph's recipients.
  result = newJArray()
  if list == nil: return
  for a in list:
    result.add %*{"emailAddress": {"name": a{"name"}.getStr, "address": a{"email"}.getStr}}

proc graphMe*(token: string): tuple[email, name: string] =
  let j = callJson("GET", url("/me?$select=displayName,mail,userPrincipalName"), token,
                   what = "your profile")
  result.name = j{"displayName"}.getStr
  result.email = j{"mail"}.getStr
  if result.email.len == 0: result.email = j{"userPrincipalName"}.getStr

proc parseMessage*(j: JsonNode; account: int; me: string): GraphItem =
  if j{"@removed"} != nil:
    return GraphItem(removed: true, msg: Msg(remoteId: j{"id"}.getStr))
  var m = Msg(account: account, remoteId: j{"id"}.getStr)
  m.thread = j{"conversationId"}.getStr
  if m.thread.len == 0: m.thread = m.remoteId
  m.subject = j{"subject"}.getStr
  m.fromName = j{"from"}{"emailAddress"}{"name"}.getStr
  m.fromEmail = j{"from"}{"emailAddress"}{"address"}.getStr
  m.toList = addrList(j{"toRecipients"})
  m.ccList = addrList(j{"ccRecipients"})
  m.date = parseIso(j{"receivedDateTime"}.getStr)
  m.snippet = j{"bodyPreview"}.getStr.replace("\r", " ").replace("\n", " ")
  if m.snippet.len > 300: m.snippet.setLen(300)
  m.unread = not j{"isRead"}.getBool(true)
  m.flagged = j{"flag"}{"flagStatus"}.getStr == "flagged"
  m.important = j{"importance"}.getStr == "high"
  m.hasAtt = j{"hasAttachments"}.getBool
  m.focused = j{"inferenceClassification"}.getStr != "other"
  m.draft = j{"isDraft"}.getBool
  m.msgId = j{"internetMessageId"}.getStr
  if "eventMessage" in j{"@odata.type"}.getStr: m.labels = "meeting"   # (an invitation, an answer)
  for c in j{"categories"}.getElems: m.tags.add c.getStr
  m.mine = me.len > 0 and m.fromEmail.toLowerAscii == me.toLowerAscii
  GraphItem(msg: m, folderRemote: j{"parentFolderId"}.getStr)

proc graphFolders*(token: string): seq[tuple[remoteId, name, role, parent: string; unread, total: int]] =
  ## Every mail folder (sub-folders too, a few levels down).
  var roles = initTable[string, string]()
  var batch = %*{"requests": []}
  for i, (name, role) in wellKnown:
    batch["requests"].add %*{"id": $i, "method": "GET", "url": "/me/mailFolders/" & name & "?$select=id"}
  try:
    let r = callJson("POST", url("/$batch"), token, batch, what = "the folders")
    for resp in r{"responses"}.getElems:
      let i = try: parseInt(resp{"id"}.getStr) except ValueError: -1
      if i >= 0 and i < wellKnown.len and resp{"status"}.getInt == 200:
        roles[resp{"body"}{"id"}.getStr] = wellKnown[i][1]
  except ApiError: discard
  proc walk(path: string; depth: int; res: var seq[tuple[remoteId, name, role, parent: string; unread, total: int]]) =
    var next = url(path)
    var pages = 0
    while next.len > 0 and pages < 20:
      inc pages
      let j = callJson("GET", next, token, what = "the folders")
      for f in j{"value"}.getElems:
        let id = f{"id"}.getStr
        res.add (id, f{"displayName"}.getStr, roles.getOrDefault(id, ""),
                 f{"parentFolderId"}.getStr, f{"unreadItemCount"}.getInt, f{"totalItemCount"}.getInt)
        if f{"childFolderCount"}.getInt > 0 and depth < 4:
          walk("/me/mailFolders/" & id & "/childFolders?$top=100&$select=id,displayName," &
               "parentFolderId,unreadItemCount,totalItemCount,childFolderCount", depth + 1, res)
      next = j{"@odata.nextLink"}.getStr
  walk("/me/mailFolders?$top=100&$select=id,displayName,parentFolderId,unreadItemCount," &
       "totalItemCount,childFolderCount", 0, result)

proc graphDelta*(token, folderRemote, deltaLink: string; sinceDays: int; account: int;
                 me: string; maxPages = 30): tuple[items: seq[GraphItem]; next: string; done: bool] =
  ## The folder's changes since `deltaLink` (all of the last `sinceDays`
  ## days when empty). `next`: where to go on next time; `done` false when
  ## more pages are waiting (the caller comes back for them).
  var link = deltaLink
  if link.len == 0:
    let since = isoTime(epochTime() - float(max(sinceDays, 1)) * 86400)
    link = url("/me/mailFolders/" & folderRemote & "/messages/delta?$select=" & msgSelect &
               "&$filter=receivedDateTime+ge+" & since)
  var pages = 0
  while pages < maxPages:
    inc pages
    let j = callJson("GET", link, token, extra = [("Prefer", "odata.maxpagesize=100")], what = "the messages")
    for it in j{"value"}.getElems:
      result.items.add parseMessage(it, account, me)
    if j{"@odata.deltaLink"} != nil:
      result = (result.items, j{"@odata.deltaLink"}.getStr, true); return
    link = j{"@odata.nextLink"}.getStr
    if link.len == 0: result = (result.items, "", true); return
  (result.items, link, false)

proc graphBody*(token, remoteId: string): GraphBody =
  ## A message's HTML, its recipients and its attachments (inline pictures
  ## with their bytes).
  let j = callJson("GET", url("/me/messages/" & remoteId &
                   "?$select=body,toRecipients,ccRecipients,internetMessageId,hasAttachments," &
                   "internetMessageHeaders"),
                   token, extra = [("Prefer", "outlook.body-content-type=\"html\"")],
                   what = "the message")
  result.html = j{"body"}{"content"}.getStr
  if j{"body"}{"contentType"}.getStr.toLowerAscii == "text":
    result.html = "<pre>" & result.html.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;")) & "</pre>"
  result.toList = addrList(j{"toRecipients"})
  result.ccList = addrList(j{"ccRecipients"})
  result.msgId = j{"internetMessageId"}.getStr
  for h in j{"internetMessageHeaders"}.getElems:
    case h{"name"}.getStr.toLowerAscii
    of "list-unsubscribe": result.unsub = h{"value"}.getStr.strip
    of "list-unsubscribe-post": result.unsubPost = h{"value"}.getStr.strip
    else: discard
  if j{"hasAttachments"}.getBool or "cid:" in result.html:
    let a = callJson("GET", url("/me/messages/" & remoteId &
                     "/attachments?$select=id,name,contentType,size,isInline"), token,
                     what = "the attachments")
    for at in a{"value"}.getElems:
      var e = (remoteId: at{"id"}.getStr, name: at{"name"}.getStr, mime: at{"contentType"}.getStr,
               cid: "", size: at{"size"}.getInt, inline: at{"isInline"}.getBool, data: "",
               hasData: false)
      let isFile = at{"@odata.type"}.getStr.endsWith("fileAttachment") or at{"@odata.type"} == nil
      if isFile and (e.inline or "cid:" in result.html) and e.size < 3_000_000:
        try:
          let full = callJson("GET", url("/me/messages/" & remoteId & "/attachments/" & e.remoteId),
                              token, what = "a picture")
          e.cid = full{"contentId"}.getStr.strip(chars = {'<', '>'})
          let b = full{"contentBytes"}.getStr
          if b.len > 0:
            e.data = decode(b)
            e.hasData = true
          if e.cid.len > 0 and ("cid:" & e.cid) in result.html: e.inline = true
        except ApiError, ValueError: discard
      result.atts.add e

proc graphAttachment*(token, remoteMsg, remoteAtt: string): string =
  ## An attachment's bytes.
  let r = call("GET", url("/me/messages/" & remoteMsg & "/attachments/" & remoteAtt & "/$value"),
               token, timeout = 300)
  if not r.ok: fail(r, "the attachment")
  r.body

proc graphPatch*(token, remoteId: string; body: JsonNode) =
  discard callJson("PATCH", url("/me/messages/" & remoteId), token, body, what = "the change")

proc graphMove*(token, remoteId, destRemote: string): string =
  ## Moves a message; its new id (Graph gives a moved message a new one).
  let j = callJson("POST", url("/me/messages/" & remoteId & "/move"), token,
                   %*{"destinationId": destRemote}, what = "the move")
  j{"id"}.getStr

proc graphDeleteForever*(token, remoteId: string) =
  let r = call("DELETE", url("/me/messages/" & remoteId), token)
  if not r.ok and r.status != 404: fail(r, "the delete")

proc graphCategories*(token: string): seq[tuple[name, color: string]] =
  let j = callJson("GET", url("/me/outlook/masterCategories"), token, what = "the categories")
  for c in j{"value"}.getElems:
    result.add (c{"displayName"}.getStr, c{"color"}.getStr)

proc graphAddCategory*(token, name, preset: string) =
  let r = call("POST", url("/me/outlook/masterCategories"), token,
               $(%*{"displayName": name, "color": preset}))
  if not r.ok and r.status != 409: fail(r, "the new category")

proc graphSearch*(token, query: string; account: int; me: string): seq[GraphItem] =
  ## Messages the server finds (for mail older than what is kept here).
  let q = "\"" & query.replace("\"", " ") & "\""
  let j = callJson("GET", url("/me/messages?$search=" & urlEncode(q) & "&$top=50&$select=" &
                   msgSelect), token, what = "the search")
  for it in j{"value"}.getElems:
    result.add parseMessage(it, account, me)

proc uploadLarge(token, draft, path, name, mime: string) =
  ## An attachment over 3 MB, in pieces through an upload session.
  let size = getFileSize(path)
  let s = callJson("POST", url("/me/messages/" & draft & "/attachments/createUploadSession"), token,
                   %*{"AttachmentItem": {"attachmentType": "file", "name": name, "size": size,
                      "contentType": mime}}, what = "the upload")
  let up = s{"uploadUrl"}.getStr
  if up.len == 0: raise newException(ApiError, "the upload: no address came")
  var f = open(path)
  defer: f.close()
  const chunk = 320 * 1024 * 12          # (a multiple of 320 KB, as Graph wants)
  var pos = 0'i64
  var buf = newString(chunk)
  while pos < size:
    let n = f.readBuffer(buf[0].addr, chunk)
    if n <= 0: break
    let r = httpRequest("PUT", up, [("Content-Range", "bytes " & $pos & "-" & $(pos + n - 1) &
                        "/" & $size), ("Content-Type", "application/octet-stream")],
                        buf[0 ..< n], timeoutSec = 300)
    if not r.ok: fail(r, "the upload")
    pos += n

proc graphSend*(token: string; d: JsonNode) =
  ## Sends what the compose window made: a new message, or a reply / reply
  ## to all / forward of `d.replyTo` (so the server keeps the thread).
  let mode = d{"mode"}.getStr("new")
  let body = %*{"subject": d{"subject"}.getStr,
                "body": {"contentType": "HTML", "content": d{"html"}.getStr},
                "toRecipients": recipients(d{"to"}), "ccRecipients": recipients(d{"cc"}),
                "bccRecipients": recipients(d{"bcc"})}
  if d{"important"}.getBool: body["importance"] = %"high"
  var draft = ""
  let rid = d{"replyTo"}.getStr
  if mode != "new" and rid.len > 0:
    let action = case mode
                 of "replyAll": "createReplyAll"
                 of "forward": "createForward"
                 else: "createReply"
    let j = callJson("POST", url("/me/messages/" & rid & "/" & action), token, newJObject(),
                     what = "the reply")
    draft = j{"id"}.getStr
    graphPatch(token, draft, body)
  else:
    let j = callJson("POST", url("/me/messages"), token, body, what = "the message")
    draft = j{"id"}.getStr
  if draft.len == 0: raise newException(ApiError, "the message: no draft came back")
  try:
    for a in d{"attachments"}.getElems:
      let path = a{"path"}.getStr
      if not fileExists(path): continue
      let name = a{"name"}.getStr(extractFilename(path))
      let mime = a{"mime"}.getStr("application/octet-stream")
      if getFileSize(path) <= 3_000_000:
        var att = %*{"@odata.type": "#microsoft.graph.fileAttachment", "name": name,
                     "contentType": mime, "contentBytes": encode(readFile(path))}
        if a{"cid"}.getStr.len > 0:
          att["isInline"] = %true
          att["contentId"] = %a{"cid"}.getStr
        discard callJson("POST", url("/me/messages/" & draft & "/attachments"), token, att,
                         what = "an attachment")
      else:
        uploadLarge(token, draft, path, name, mime)
    discard callJson("POST", url("/me/messages/" & draft & "/send"), token, newJObject(),
                     what = "sending")
  except ApiError as e:
    if e.status in 400 .. 499 and e.status notin [401, 408, 429]:
      try: graphDeleteForever(token, draft) except ApiError: discard
    raise

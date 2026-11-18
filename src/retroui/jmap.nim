## JMAP (RFC 8620 and 8621): mail over HTTPS and JSON -- Fastmail's, and
## any server that speaks it (Stalwart, Cyrus, Apache James). One request
## carries many method calls; the server says what changed since a state
## it gave (no folder by folder walking); a message's source is one
## download; sending is an upload, an import into Sent and a submission.
##
## .. code-block:: nim
##   import retroui/jmap
##   let s = jmapConnect("https://api.fastmail.com/jmap/session", jmapBearer(apiToken))
##   for b in s.mailboxes(): echo b.name, " ", b.role, " ", b.unread
##   let q = s.queryEmails(%*{"inMailbox": inboxId}, limit = 50)
##   for e in s.getEmails(q.ids): echo e["subject"].getStr
##   let raw = s.download(e["blobId"].getStr)        # the whole message
##   s.setKeyword(id, "$seen", true)
##   let ch = s.emailChanges(state)                  # what changed since
##   s.sendRaw(raw, "me@example.com", @["you@example.org"], sentId)
##
## `JmapError` carries the server's words (an HTTP error, or a method's
## error: its type and description). Every call blocks: run them on a
## thread of their own.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[json, strutils, base64, uri]
import http

type
  JmapError* = object of IOError
    ## The server refused (`status`: its HTTP status; 0 none came) or a
    ## method failed (`kind`: "invalidArguments", "notFound", ...).
    status*: int
    kind*: string
  JmapSession* = object
    ## A signed-in session (`jmapConnect`).
    apiUrl*, downloadUrl*, uploadUrl*: string
    account*: string            ## the mail account's id
    submission*: string         ## the account sending is done for ("" none)
    username*: string
    maxCalls*: int              ## method calls in one request, at most
    auth: string
    timeoutSec: int
  JmapMailbox* = object
    id*, name*, parentId*, role*: string   ## role: inbox, sent, drafts, trash, junk, archive... ("" none)
    total*, unread*: int

const
  usingMail = ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail",
               "urn:ietf:params:jmap:submission"]
  emailProps* = ["id", "blobId", "threadId", "mailboxIds", "keywords", "size", "receivedAt",
                 "messageId", "inReplyTo", "references", "from", "to", "cc", "subject",
                 "preview", "hasAttachment"]
    ## (what `getEmails` asks for by default: all a message list shows)

proc jmapFail(msg: string; status = 0; kind = "") {.noreturn.} =
  var e = newException(JmapError, msg)
  e.status = status
  e.kind = kind
  raise e

proc jmapBearer*(token: string): string = "Bearer " & token
  ## An Authorization of an API token or OAuth access token.
proc jmapBasic*(user, password: string): string = "Basic " & encode(user & ":" & password)
  ## An Authorization of a user name and password.

proc request(s: JmapSession; meth, url: string; body = ""; ctype = "application/json"): HttpResponse =
  var headers = @[("Authorization", s.auth), ("Accept", "application/json")]
  if body.len > 0 or meth == "POST": headers.add ("Content-Type", ctype)
  result = httpRequest(meth, url, headers, body, timeoutSec = s.timeoutSec)
  if result.status == 0: jmapFail("no answer: " & result.error)
  if result.status == 401 or result.status == 403:
    jmapFail("the server refused the sign-in (" & $result.status & ")", result.status)
  if not result.ok:
    var why = result.body.strip
    try:
      let j = parseJson(result.body)
      why = j{"detail"}.getStr(j{"title"}.getStr(j{"type"}.getStr(why)))
    except CatchableError: discard
    jmapFail("the server answered " & $result.status & (if why.len > 0 and why.len < 300: ": " & why else: ""),
             result.status)

proc jmapConnect*(url, auth: string; timeoutSec = 30): JmapSession =
  ## Signs in: `url` is the session's ("https://api.fastmail.com/jmap/session")
  ## or the server's ("https://mail.example.com": its /.well-known/jmap is
  ## asked); `auth` is `jmapBearer(token)` or `jmapBasic(user, password)`.
  var u = url.strip
  if not u.startsWith("http"): u = "https://" & u
  if not ("/jmap" in u or ".well-known" in u):
    u = u.strip(leading = false, chars = {'/'}) & "/.well-known/jmap"
  result = JmapSession(auth: auth, timeoutSec: timeoutSec, maxCalls: 16)
  let r = result.request("GET", u)
  var j: JsonNode
  try: j = parseJson(r.body)
  except CatchableError: jmapFail("not a JMAP server: " & u)
  result.apiUrl = j{"apiUrl"}.getStr
  result.downloadUrl = j{"downloadUrl"}.getStr
  result.uploadUrl = j{"uploadUrl"}.getStr
  result.username = j{"username"}.getStr
  result.account = j{"primaryAccounts"}{"urn:ietf:params:jmap:mail"}.getStr
  result.submission = j{"primaryAccounts"}{"urn:ietf:params:jmap:submission"}.getStr
  let mc = j{"capabilities"}{"urn:ietf:params:jmap:core"}{"maxCallsInRequest"}.getInt(16)
  result.maxCalls = max(1, mc)
  if result.apiUrl.len == 0 or result.account.len == 0: jmapFail("this JMAP server has no mail account")
  # (relative URLs: of the session's own address)
  let base = parseUri(u)
  for f in [addr result.apiUrl, addr result.downloadUrl, addr result.uploadUrl]:
    if f[].startsWith("/"): f[] = $base.scheme & "://" & base.hostname &
                                   (if base.port.len > 0: ":" & base.port else: "") & f[]

proc call*(s: JmapSession; calls: JsonNode): JsonNode =
  ## Sends method calls -- `[["Email/get", {...}, "0"], ...]` -- and gives
  ## back their responses in the same order (each `[name, result, id]`).
  ## Raises `JmapError` on the first that failed.
  let req = %*{"using": usingMail, "methodCalls": calls}
  let r = s.request("POST", s.apiUrl, $req)
  let j = try: parseJson(r.body) except CatchableError: jmapFail("the server's answer is not JSON")
  result = j{"methodResponses"}
  if result == nil or result.kind != JArray: jmapFail("the server's answer has no responses")
  for m in result.getElems:
    if m.len >= 2 and m[0].getStr == "error":
      let t = m[1]{"type"}.getStr("serverFail")
      jmapFail(t & (if m[1]{"description"}.getStr.len > 0: ": " & m[1]{"description"}.getStr else: ""),
               200, t)

proc call1(s: JmapSession; name: string; args: JsonNode): JsonNode =
  var a = args
  a["accountId"] = %s.account
  s.call(%*[[name, a, "0"]])[0][1]

proc mailboxes*(s: JmapSession): seq[JmapMailbox] =
  ## The account's mailboxes (its folders).
  let r = s.call1("Mailbox/get", %*{"ids": nil})
  for b in r{"list"}.getElems:
    result.add JmapMailbox(id: b{"id"}.getStr, name: b{"name"}.getStr, parentId: b{"parentId"}.getStr,
                           role: b{"role"}.getStr.toLowerAscii, total: b{"totalEmails"}.getInt,
                           unread: b{"unreadEmails"}.getInt)

proc mailboxState*(s: JmapSession): string =
  ## The mailboxes' state now (for `mailboxChanges`).
  s.call1("Mailbox/get", %*{"ids": []}){"state"}.getStr

proc queryEmails*(s: JmapSession; filter: JsonNode; limit = 100; position = 0;
                  newestFirst = true): tuple[ids: seq[string]; total: int] =
  ## The ids of the messages `filter` matches ({"inMailbox": id, "after":
  ## "2026-11-01T00:00:00Z"}, {"text": "invoice"}), newest first.
  let r = s.call1("Email/query", %*{"filter": filter, "position": position, "limit": limit,
                  "calculateTotal": true,
                  "sort": [{"property": "receivedAt", "isAscending": not newestFirst}]})
  for i in r{"ids"}.getElems: result.ids.add i.getStr
  result.total = r{"total"}.getInt(result.ids.len)

proc getEmails*(s: JmapSession; ids: openArray[string]; properties: openArray[string] = emailProps;
                bodies = false): seq[JsonNode] =
  ## The messages' properties (with `bodies`, their text and HTML too:
  ## "bodyValues", "htmlBody", "textBody", "attachments").
  if ids.len == 0: return
  var props = @properties
  var args = %*{"ids": ids}
  if bodies:
    props.add ["bodyValues", "htmlBody", "textBody", "attachments"]
    args["fetchHTMLBodyValues"] = %true
    args["fetchTextBodyValues"] = %true
    args["maxBodyValueBytes"] = %(2 * 1024 * 1024)
  args["properties"] = %props
  for e in s.call1("Email/get", args){"list"}.getElems: result.add e

proc emailState*(s: JmapSession): string =
  ## The messages' state now (for `emailChanges`).
  s.call1("Email/get", %*{"ids": []}){"state"}.getStr

proc emailChanges*(s: JmapSession; since: string; maxChanges = 500):
    tuple[created, updated, destroyed: seq[string]; newState: string; more: bool] =
  ## What changed since state `since`: messages new, changed (flags,
  ## mailboxes), gone. `more`: ask again from `newState` for the rest.
  ## Raises `JmapError` with kind "cannotCalculateChanges" when `since` is
  ## too old (then start over).
  let r = s.call1("Email/changes", %*{"sinceState": since, "maxChanges": maxChanges})
  for i in r{"created"}.getElems: result.created.add i.getStr
  for i in r{"updated"}.getElems: result.updated.add i.getStr
  for i in r{"destroyed"}.getElems: result.destroyed.add i.getStr
  result.newState = r{"newState"}.getStr
  result.more = r{"hasMoreChanges"}.getBool

proc setEmails*(s: JmapSession; update: JsonNode = nil; destroy: openArray[string] = []): JsonNode =
  ## Email/set: `update` {id: {patch}}, `destroy` [ids]. Raises when one
  ## was not done.
  var args = newJObject()
  if update != nil: args["update"] = update
  if destroy.len > 0: args["destroy"] = %destroy
  result = s.call1("Email/set", args)
  for key in ["notUpdated", "notDestroyed", "notCreated"]:
    let n = result{key}
    if n != nil and n.kind == JObject and n.len > 0:
      for id, e in n.pairs:
        jmapFail(e{"type"}.getStr("refused") & ": " & e{"description"}.getStr, 200, e{"type"}.getStr)

proc setKeyword*(s: JmapSession; id, keyword: string; on: bool) =
  ## A keyword set or cleared: "$seen" (read), "$flagged", "$answered", or a
  ## tag of one's own.
  discard s.setEmails(%*{id: {"keywords/" & keyword: (if on: %true else: newJNull())}})

proc setMailboxes*(s: JmapSession; id: string; mailboxIds: openArray[string]) =
  ## Message `id` in these mailboxes only (a move).
  var m = newJObject()
  for b in mailboxIds: m[b] = %true
  discard s.setEmails(%*{id: {"mailboxIds": m}})

proc destroyEmails*(s: JmapSession; ids: openArray[string]) =
  ## Deleted for good.
  discard s.setEmails(destroy = ids)

proc expand(t, accountId, blobId, name, mime: string): string =
  t.multiReplace(("{accountId}", encodeUrl(accountId)), ("{blobId}", encodeUrl(blobId)),
                 ("{name}", encodeUrl(name)), ("{type}", encodeUrl(mime)))

proc download*(s: JmapSession; blobId: string; name = "message.eml"; mime = "message/rfc822"): string =
  ## A blob's bytes: a message's whole source (its "blobId"), an attachment.
  s.request("GET", expand(s.downloadUrl, s.account, blobId, name, mime)).body

proc upload*(s: JmapSession; data: string; mime = "message/rfc822"): string =
  ## Uploads bytes; their blobId.
  let r = s.request("POST", expand(s.uploadUrl, s.account, "", "", mime), data, mime)
  try: parseJson(r.body){"blobId"}.getStr except CatchableError: ""

proc importEmail*(s: JmapSession; blobId: string; mailboxIds: openArray[string];
                  keywords: openArray[string] = []): string =
  ## A message uploaded (`upload`) put in mailboxes; its id.
  var mb = newJObject()
  for b in mailboxIds: mb[b] = %true
  var kw = newJObject()
  for k in keywords: kw[k] = %true
  let r = s.call1("Email/import", %*{"emails": {"m": {"blobId": blobId, "mailboxIds": mb, "keywords": kw}}})
  let c = r{"created"}{"m"}
  if c == nil:
    let e = r{"notCreated"}{"m"}
    jmapFail("the message was not taken: " & e{"type"}.getStr & " " & e{"description"}.getStr)
  c{"id"}.getStr

proc identities*(s: JmapSession): seq[tuple[id, name, email: string]] =
  ## Who the account may send as.
  var a = %*{"ids": nil, "accountId": (if s.submission.len > 0: s.submission else: s.account)}
  let r = s.call(%*[["Identity/get", a, "0"]])[0][1]
  for i in r{"list"}.getElems:
    result.add (i{"id"}.getStr, i{"name"}.getStr, i{"email"}.getStr)

proc sendRaw*(s: JmapSession; raw, fromAddr: string; rcpts: openArray[string]; sentMailbox: string;
              draftsMailbox = "") =
  ## Sends message `raw` (RFC 5322, as `retroui/mime` makes it) to `rcpts`:
  ## uploaded, kept in Sent (`sentMailbox`, read), submitted from the
  ## identity of `fromAddr`.
  var ident = ""
  for i in s.identities():
    if i.email.toLowerAscii == fromAddr.toLowerAscii or ident.len == 0: ident = i.id
  if ident.len == 0: jmapFail("this account may not send (it has no identity)")
  let blob = s.upload(raw)
  if blob.len == 0: jmapFail("the message could not be uploaded")
  let keep = if draftsMailbox.len > 0: draftsMailbox else: sentMailbox
  let id = s.importEmail(blob, [keep], ["$seen"])
  var rc = newJArray()
  for r in rcpts: rc.add %*{"email": r}
  var onSuccess = newJObject()
  if draftsMailbox.len > 0 and sentMailbox.len > 0:
    onSuccess["#s"] = %*{("mailboxIds/" & draftsMailbox): nil, ("mailboxIds/" & sentMailbox): true,
                         "keywords/$draft": nil}
  let acct = if s.submission.len > 0: s.submission else: s.account
  let calls = %*[["EmailSubmission/set", {"accountId": acct,
                  "create": {"s": {"emailId": id, "identityId": ident,
                                   "envelope": {"mailFrom": {"email": fromAddr}, "rcptTo": rc}}},
                  "onSuccessUpdateEmail": onSuccess}, "0"]]
  let r = s.call(calls)[0][1]
  let nc = r{"notCreated"}{"s"}
  if nc != nil:
    jmapFail("the message was not sent: " & nc{"type"}.getStr & " " & nc{"description"}.getStr, 200,
             nc{"type"}.getStr)

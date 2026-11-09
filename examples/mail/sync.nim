## Retro Mail's sync thread: it keeps the store in step with the servers
## (new mail, changes made elsewhere), sends what waits in the queue
## (changes made here, mail to send), fetches bodies and attachments when
## the window asks, and keeps the sign-in tokens fresh. The window talks to
## it through two channels and never waits for the network.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[json, strutils, times, tables, os, hashes, sets, sequtils, uri, locks, algorithm]
import retroui/[db, http, oauth, secrets, mime, imap, netconn]
import api, store, graph, gmail, appids, sigfind, invites, autoreply, assist, rules, forward, importer,
       calendar, imapsync

const secretApp* = "RetroMail"

type
  SyncCmdKind* = enum
    scWake        ## changes were queued: send them now
    scSyncNow     ## Send and Receive (F5)
    scBody        ## fetch message `id`'s body
    scAttachment  ## fetch attachment `id`'s bytes
    scSearch      ## search the servers for `text`
    scAccounts    ## accounts were added or removed
    scSettings    ## `count`: minutes between checks
    scSignatures  ## read account `id`'s signatures from its service
    scInvite      ## message `id`: is it a meeting invitation (and what)?
    scRespond     ## answer the invitation in message `id`: `text` {"answer", "comment", "send"}
    scGetAutoReply  ## account `id`'s automatic replies
    scSetAutoReply  ## account `id`'s automatic replies set to `text` (JSON)
    scAssist      ## the assistant: `text` {"kind": "summary" | "translate", "id": message, "to": language}
    scRaw         ## message `id`'s whole source: `count` 0 to forward it attached, 1 saved at `text`,
                  ## 2 to read (its Properties, its source)
    scUnsubscribe ## leave the list message `id` came from (List-Unsubscribe)
    scEventNew    ## a new event in account `id`'s calendar: `text` {"draft"}
    scEventChange ## event `text`.event changed: {"event", "draft", "parts", "occurrence"}
    scEventDelete ## event `text`.event deleted: {"event", "cancel", "comment"}
    scQuit
  SyncCmd* = object
    kind*: SyncCmdKind
    id*, count*: int
    text*: string
  SyncEventKind* = enum
    seChanged     ## the store changed: read it again
    seStatus      ## `text`: what it is doing ("" when done)
    seError       ## `text` went wrong (for `id`'s account)
    seSignIn      ## account `id` must sign in again
    seBody        ## message `id`'s body is here (or failed)
    seAttachment  ## attachment `id`'s bytes are here (`text`: an error)
    seNewMail     ## `count` new messages; `text` the newest's sender and subject
    seSearch      ## the server search is done: `ids`
    seSent        ## a message went (`text` its subject)
    seSignature   ## account `id`'s signatures: `text` {"new": html, "reply": html}
    seInvite      ## message `id`'s invitation: `text` its JSON ({"error"} when it failed)
    seAutoReply   ## account `id`'s automatic replies: `text` JSON (`count` 1: saved)
    seAssist      ## the assistant's answer: `text` {"kind", "id", "text"} or {"error"}
    seRaw         ## message `id`'s source: `text` the file, `count` as asked ({"error"})
    seUnsub       ## message `id`'s list left: `text` {"how": "post"|"mail"|"open", "url"} or {"error"}
    seEvent       ## account `id`'s event made (`count` 0), changed (1), deleted (2): `text`
                  ## {"event", "joinUrl"} or {"error"}
  SyncEvent* = object
    kind*: SyncEventKind
    id*, count*: int
    text*: string
    ids*: seq[int]
  SyncLink* = object
    cmds*: Channel[SyncCmd]
    events*: Channel[SyncEvent]
    dbPath*: string

proc tokenKey*(account: int): string = "acct-" & $account
proc secretKey*(account: int): string = "acct-" & $account & "-secret"

proc providerFor*(acc: Account; clientSecret = ""): OAuthProvider {.gcsafe.} =
  ## The sign-in service of an account (addresses changeable for tests).
  case acc.kind
  of akGraph:
    let tenant = if acc.tenant.len > 0: acc.tenant else: "common"
    result = microsoftProvider(acc.clientId, tenant, graphScopes)
    let base = getEnv("RETRO_MAIL_MSLOGIN")
    if base.len > 0:
      result.authUrl = base & "/" & tenant & "/oauth2/v2.0/authorize"
      result.tokenUrl = base & "/" & tenant & "/oauth2/v2.0/token"
  of akGmail:
    var secret = if clientSecret.len > 0: clientSecret
                 else: loadSecret(secretApp, secretKey(acc.id))
    if secret.len == 0 and acc.clientId == googleAppId: secret = googleAppSecret
    result = googleProvider(acc.clientId, secret, gmailScopes)
    result.authUrl = gAuthUrl()
    result.tokenUrl = gTokenUrl()
  of akImap: discard                    # (a password, no sign-in service)

proc plainOf*(html: string): string =
  ## Rough text of HTML, for the search index.
  var inTag = false
  var skip = false
  var i = 0
  while i < html.len:
    let c = html[i]
    if c == '<':
      let rest = html.substr(i, i + 8).toLowerAscii
      if rest.startsWith("<style") or rest.startsWith("<script") or rest.startsWith("<head"): skip = true
      elif rest.startsWith("</style") or rest.startsWith("</script") or rest.startsWith("</head"): skip = false
      if rest.startsWith("<br") or rest.startsWith("<p") or rest.startsWith("<div") or
         rest.startsWith("<tr") or rest.startsWith("<li"):
        result.add '\n'
      inTag = true
    elif c == '>': inTag = false
    elif not inTag and not skip: result.add c
    inc i
  result = result.multiReplace(("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                               ("&quot;", "\""), ("&#39;", "'"))

proc textToHtml*(text: string): string =
  ## A plain-text mail as simple HTML: paragraphs, line breaks, links.
  proc esc(s: string): string = s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"))
  proc linkify(s: string): string =
    var i = 0
    while i < s.len:
      let k = s.find("http", i)
      if k < 0 or not (s.continuesWith("http://", k) or s.continuesWith("https://", k)):
        result.add s[i .. ^1]
        break
      result.add s[i ..< k]
      var e = k
      while e < s.len and s[e] notin {' ', '\t', '\n', '\r', '<', '>', '"'}: inc e
      let u = s[k ..< e]
      result.add "<a href=\"" & u & "\">" & u & "</a>"
      i = e
  result = "<div>"
  for para in text.replace("\r\n", "\n").split("\n\n"):
    var lines: seq[string]
    for l in para.split('\n'):
      let q = l.startsWith(">")
      lines.add (if q: "<span style=\"color:#555\">" & linkify(esc(l)) & "</span>" else: linkify(esc(l)))
    result.add "<p>" & lines.join("<br>") & "</p>"
  result.add "</div>"

# ---- the thread ------------------------------------------------------------------------

type
  Worker = object
    link: ptr SyncLink
    db: Db
    tokens: Table[int, OAuthTokens]
    lastFull: Table[int, float]
    lastFolders: Table[int, float]
    lastCal: Table[int, float]
    interval: float
    newest: Table[int, float]       ## per account: the newest inbox mail seen
    later: seq[SyncCmd]             ## commands put off while syncing
    fresh: seq[string]              ## the remote ids of mail that just came (for the rules)
    imaps: Table[int, ImapClient]   ## IMAP accounts: the connection of each, kept open

proc send(w: var Worker; ev: SyncEvent) = w.link.events.send(ev)
proc status(w: var Worker; s: string) = w.send(SyncEvent(kind: seStatus, text: s))
proc applyRules(w: var Worker; acc: Account; ids: seq[int])

# ---- new mail nobody was told about yet --------------------------------------------------
# The sync notes what it fetched; whoever tells (the window, or a background
# check while the window sleeps) takes it, so it is told once.

var unannouncedLock: Lock
initLock(unannouncedLock)

proc unannouncedPath(): string = mailDir() / "unannounced.json"

proc addUnannounced(count: int; latest: string) =
  withLock unannouncedLock:
    var n = 0
    try: n = parseJson(readFile(unannouncedPath())){"count"}.getInt
    except CatchableError: discard
    try: writeFile(unannouncedPath(), $(%*{"count": n + count, "latest": latest}))
    except CatchableError: discard

proc takeUnannounced*(): tuple[count: int; latest: string] =
  ## The new mail fetched since it was last taken (how many, the newest's
  ## sender and subject), and forgotten: the one who takes it tells it.
  withLock unannouncedLock:
    try:
      let j = parseJson(readFile(unannouncedPath()))
      result = (j{"count"}.getInt, j{"latest"}.getStr)
    except CatchableError: discard
    try: removeFile(unannouncedPath())
    except CatchableError: discard

proc token(w: var Worker; acc: Account): string =
  ## A fresh access token, or "" (then the account has to sign in again).
  ## An IMAP account's: its password ("" when it was refused: typed again).
  if acc.kind == akImap:
    if acc.state == "signin" or w.db.account(acc.id).state == "signin": return ""
    let pw = imapPassword(acc)
    if pw.len == 0:
      w.db.setAccountState(acc.id, "signin")
      w.send(SyncEvent(kind: seSignIn, id: acc.id))
    return pw
  if not w.tokens.hasKey(acc.id):
    let s = loadSecret(secretApp, tokenKey(acc.id))
    if s.len == 0:
      w.db.setAccountState(acc.id, "signin")
      w.send(SyncEvent(kind: seSignIn, id: acc.id))
      return ""
    try: w.tokens[acc.id] = toTokens(parseJson(s))
    except CatchableError:
      w.send(SyncEvent(kind: seSignIn, id: acc.id))
      return ""
  var t = w.tokens[acc.id]
  let before = t.accessToken
  let err = providerFor(acc).ensureFresh(t)
  if err.len > 0:
    if t.accessToken.len == 0 or "invalid_grant" in err or "expired" in err.toLowerAscii or
       "revoked" in err.toLowerAscii:
      w.db.setAccountState(acc.id, "signin")
      w.send(SyncEvent(kind: seSignIn, id: acc.id, text: err))
      w.tokens.del acc.id
      return ""
    w.db.setAccountState(acc.id, err)
    return ""
  if t.accessToken != before:
    discard saveSecret(secretApp, tokenKey(acc.id), $(%t))
  w.tokens[acc.id] = t
  t.accessToken

proc forget(w: var Worker; acc: int) =
  ## The token was refused: refresh it before the next call.
  if w.tokens.hasKey(acc):
    var t = w.tokens[acc]
    t.expiresAt = 0
    w.tokens[acc] = t

proc pending(w: var Worker): seq[SyncCmd] =
  result = move w.later
  while true:
    let (ok, c) = w.link.cmds.tryRecv()
    if not ok: break
    result.add c

# ---- IMAP accounts: one connection each, kept open --------------------------------------------

proc imapOf(w: var Worker; acc: Account; pw: string): ImapClient =
  ## The account's connection (made and signed in the first time).
  if w.imaps.hasKey(acc.id): return w.imaps[acc.id]
  let s = serversOf(acc)
  w.status("Connecting to " & s.imapHost & "...")
  let c = imapConnect(s.imapHost, s.imapPort, s.imapSec, timeoutSec = 60, insecure = s.insecure)
  try:
    c.login(s.imapUser, pw)
  except CatchableError:
    c.close()
    raise
  c.enable("CONDSTORE")
  w.imaps[acc.id] = c
  c

proc dropImap(w: var Worker; acc: int) =
  if w.imaps.hasKey(acc):
    w.imaps[acc].close()
    w.imaps.del acc

template withImap(w: var Worker; acc: Account; pw: string; c, body: untyped) =
  ## (`body` on the account's connection, once more on a new one when the
  ## old one broke -- a server closes one left alone; errors as ApiError)
  for attempt in 0 .. 1:
    try:
      let c {.inject.} = w.imapOf(acc, pw)
      body
      break
    except NetError as e:
      w.dropImap(acc.id)
      if attempt == 1: raise imapError(e)
    except ImapError as e:
      let ae = imapError(e)
      if ae.status == 401:
        w.dropImap(acc.id)
        w.db.setAccountState(acc.id, "signin")       # (the password, typed again)
        w.send(SyncEvent(kind: seSignIn, id: acc.id, text: e.msg))
      raise ae

proc selectIn(c: ImapClient; folder: string): ImapBox {.discardable.} =
  ## (the folder selected, unless it is already)
  if c.selected != folder: result = c.select(folder)

const NoSelect = "{\"noselect\":true}"


# ---- bodies and attachments ------------------------------------------------------------

proc fetchBody(w: var Worker; id: int) =
  let m = w.db.message(id)
  if m.id == 0: return
  let acc = w.db.account(m.account)
  let tok = w.token(acc)
  if tok.len == 0:
    w.send(SyncEvent(kind: seBody, id: id, text: "sign in to read it"))
    return
  try:
    case acc.kind
    of akGraph:
      let b = graphBody(tok, m.remoteId)
      w.db.transaction:
        w.db.setBody(id, b.html, plainOf(b.html))
        w.db.setDetails(id, b.toList, b.ccList, b.msgId, m.inReplyTo, m.refs)
        if b.unsub.len > 0: w.db.setUnsub(id, b.unsub, b.unsubPost)
        for a in b.atts:
          discard w.db.addAttachment(id, a.remoteId, a.name, a.mime, a.size, a.cid, a.inline,
                                     a.data, a.hasData)
    of akGmail:
      let b = gmailBody(tok, m.remoteId)
      let html = if b.html.len > 0: b.html else: textToHtml(b.text)
      let text = if b.text.len > 0: b.text else: plainOf(b.html)
      w.db.transaction:
        w.db.setBody(id, html, text)
        w.db.setDetails(id, b.toList, b.ccList, "", m.inReplyTo, m.refs)
        if b.unsub.len > 0: w.db.setUnsub(id, b.unsub, b.unsubPost)
        for a in b.atts:
          discard w.db.addAttachment(id, a.remoteId, a.name, a.mime, a.size, a.cid, a.inline,
                                     a.data, a.hasData)
    of akImap:
      let (folder, uid) = splitRemote(m.remoteId)
      var raw = ""
      w.withImap(acc, tok, c):
        c.selectIn(folder)
        raw = c.fetchMessage(uid)
      storeImapBody(w.db, id, raw, textToHtml)
    w.send(SyncEvent(kind: seBody, id: id))
  except ApiError as e:
    if e.status == 401: w.forget(acc.id)
    if e.status == 404: w.db.setBodyState(id, 3)
    w.send(SyncEvent(kind: seBody, id: id, text: e.msg))
  except CatchableError as e:
    w.send(SyncEvent(kind: seBody, id: id, text: e.msg))

proc fetchAttachment(w: var Worker; id: int) =
  let r = w.db.one("SELECT message, remote_id FROM atts WHERE id = ?", id)
  if r.len == 0: return
  let m = w.db.message(int r[0].num)
  let acc = w.db.account(m.account)
  let tok = w.token(acc)
  if tok.len == 0:
    w.send(SyncEvent(kind: seAttachment, id: id, text: "sign in first"))
    return
  try:
    let data = case acc.kind
               of akGraph: graphAttachment(tok, m.remoteId, r[1].str)
               of akGmail: gmailAttachment(tok, m.remoteId, r[1].str)
               of akImap: ""             # (the body brought them all: fetched again below)
    if acc.kind == akImap:
      w.fetchBody(m.id)
      w.send(SyncEvent(kind: seAttachment, id: id))
      return
    w.db.setAttachmentData(id, data)
    w.send(SyncEvent(kind: seAttachment, id: id))
  except CatchableError as e:
    w.send(SyncEvent(kind: seAttachment, id: id, text: e.msg))

# ---- the queue of changes ----------------------------------------------------------------

const gmailColors = ["#4a86e8", "#16a766", "#cc3a21", "#ffad47", "#a479e2", "#2da2bb",
                     "#e07798", "#666666", "#fad165", "#3c78d8"]
const graphPresets = [("#e81123", "preset0"), ("#ff8c00", "preset1"), ("#8b4513", "preset2"),
                      ("#ffd700", "preset3"), ("#00a300", "preset4"), ("#008080", "preset5"),
                      ("#808000", "preset6"), ("#0063b1", "preset7"), ("#7a3ba0", "preset8"),
                      ("#c30052", "preset9"), ("#5d8aa8", "preset10"), ("#36454f", "preset11"),
                      ("#808080", "preset12"), ("#404040", "preset13"), ("#000000", "preset14")]

proc presetColor*(preset: string): string =
  ## An Outlook category's color.
  for (c, p) in graphPresets:
    if p == preset: return c
  case preset
  of "preset15": "#8b0000"
  of "preset16": "#cc5500"
  of "preset17": "#654321"
  of "preset18": "#b8860b"
  of "preset19": "#006400"
  of "preset20": "#004d4d"
  of "preset21": "#556b2f"
  of "preset22": "#00008b"
  of "preset23": "#4b0082"
  of "preset24": "#800020"
  else: ""

proc hexDist(a, b: string): int =
  if a.len < 7 or b.len < 7: return 1 shl 20
  for k in [1, 3, 5]:
    let x = try: fromHex[int](a[k .. k + 1]) except ValueError: 0
    let y = try: fromHex[int](b[k .. k + 1]) except ValueError: 0
    result += (x - y) * (x - y)

proc nearestPreset(color: string): string =
  result = "preset7"
  var best = 1 shl 30
  for (c, p) in graphPresets:
    let d = hexDist(color.toLowerAscii, c)
    if d < best:
      best = d
      result = p

proc nearestGmail(color: string): string =
  result = gmailColors[0]
  var best = 1 shl 30
  for c in gmailColors:
    let d = hexDist(color.toLowerAscii, c)
    if d < best:
      best = d
      result = c

proc gmailLabelIds(w: var Worker; acc: Account; tok: string; names: seq[string]): seq[string] =
  for n in names:
    var t = w.db.tagOf(acc.id, n)
    if t.remoteId.len == 0:
      let id = gmailCreateLabel(tok, n, nearestGmail(t.color))
      w.db.upsertTag(acc.id, n, t.color, id)
      t.remoteId = id
    result.add t.remoteId

proc gmailFolderLabels(role: string): tuple[add, remove: seq[string]] =
  case role
  of "inbox": (@["INBOX"], @["SPAM", "TRASH"])
  of "junk": (@["SPAM"], @["INBOX"])
  of "archive": (@[], @["INBOX", "SPAM"])
  else: (@[], @[])

proc imapAction(w: var Worker; acc: Account; pw: string; a: Action; m: Msg) =
  ## A change made here, on the server.
  let d = a.data
  let (folder, uid) = splitRemote(m.remoteId)
  case a.kind
  of "read", "flag":
    if uid == 0: return
    let flag = if a.kind == "read": "\\Seen" else: "\\Flagged"
    let on = if a.kind == "read": not d{"unread"}.getBool else: d{"flagged"}.getBool
    w.withImap(acc, pw, c):
      c.selectIn(folder)
      if on: c.addFlags([uid], [flag]) else: c.removeFlags([uid], [flag])
  of "tags":
    if uid == 0: return
    var add, remove: seq[string]
    for t in d{"tags"}.getElems: add.add keywordOf(t.getStr)
    for t in d{"removed"}.getElems: remove.add keywordsOf(t.getStr)
    w.withImap(acc, pw, c):
      c.selectIn(folder)
      if remove.len > 0: c.removeFlags([uid], remove)
      if add.len > 0: c.addFlags([uid], add)
  of "move":
    if uid == 0: return
    let dest = w.db.folder(d{"folder"}.getInt)
    let src = w.db.folder(m.folder)
    w.withImap(acc, pw, c):
      c.selectIn(folder)
      if dest.role == "trash" and src.role == "trash":
        c.deleteForever([uid])
        if m.id > 0: w.db.deleteMessage(m.id)
      elif dest.remoteId.len > 0 and dest.remoteId != folder:
        let moved = c.move([uid], dest.remoteId)
        if m.id > 0:
          if moved.len == 1:
            w.db.exec("UPDATE messages SET remote_id = ?, folder = ? WHERE id = ?",
                      imapRemote(dest.remoteId, moved[0]), dest.id, m.id)
          else: w.db.deleteMessage(m.id)        # (the next sync brings it, in its new folder)
  of "newtag":
    w.db.upsertTag(acc.id, d{"name"}.getStr, d{"color"}.getStr, keywordOf(d{"name"}.getStr))
  of "send":
    let s = serversOf(acc)
    let raw = buildRaw(d, MailAddress(name: acc.name, email: acc.email))
    var rcpts: seq[string]
    for r in d{"to"}.getElems & d{"cc"}.getElems & d{"bcc"}.getElems:
      let e = r{"email"}.getStr.strip
      if e.len > 0: rcpts.add e
    let refused = smtpSendRaw(acc, pw, rcpts, raw)
    if refused.len > 0: w.send(SyncEvent(kind: seError, id: acc.id, text: refused))
    # a copy into Sent (where the service does not keep one itself)
    if not savesSentItself(s):
      let sent = w.db.folderByRole(acc.id, "sent")
      if sent.id > 0:
        try:
          w.withImap(acc, pw, c):
            discard c.append(sent.remoteId, raw, ["\\Seen"])
        except CatchableError as e:
          w.send(SyncEvent(kind: seError, id: acc.id, text: "Sent, but not kept in Sent: " & e.msg))
    # (an answer: the message answered is marked so)
    if d{"mode"}.getStr in ["reply", "replyAll"]:
      let (of0, ou) = splitRemote(d{"replyTo"}.getStr)
      if ou > 0:
        try:
          w.withImap(acc, pw, c):
            c.selectIn(of0)
            c.addFlags([ou], ["\\Answered"])
        except CatchableError: discard
  else: discard

proc runAction(w: var Worker; acc: Account; tok: string; a: Action) =
  let d = a.data
  let id = d{"id"}.getInt
  var m = if id > 0: w.db.message(id) else: Msg()
  let remote = if m.remoteId.len > 0: m.remoteId else: d{"remote"}.getStr
  if acc.kind == akImap:
    w.imapAction(acc, tok, a, m)
    if a.kind == "send":
      for at in d{"attachments"}.getElems:
        if at{"copy"}.getBool:
          try: removeFile(at{"path"}.getStr) except OSError: discard
      for r in d{"to"}.getElems & d{"cc"}.getElems:
        w.db.noteContact(r{"email"}.getStr, r{"name"}.getStr, epochTime())
      w.send(SyncEvent(kind: seSent, text: d{"subject"}.getStr))
    return
  case a.kind
  of "read":
    let unread = d{"unread"}.getBool
    case acc.kind
    of akGraph: graphPatch(tok, remote, %*{"isRead": not unread})
    of akGmail:
      if unread: gmailModify(tok, remote, ["UNREAD"], [])
      else: gmailModify(tok, remote, [], ["UNREAD"])
    of akImap: discard
  of "flag":
    let on = d{"flagged"}.getBool
    case acc.kind
    of akGraph: graphPatch(tok, remote, %*{"flag": {"flagStatus": (if on: "flagged" else: "notFlagged")}})
    of akGmail:
      if on: gmailModify(tok, remote, ["STARRED"], [])
      else: gmailModify(tok, remote, [], ["STARRED"])
    of akImap: discard
  of "tags":
    var names: seq[string]
    for t in d{"tags"}.getElems: names.add t.getStr
    case acc.kind
    of akGraph:
      for n in names:
        let t = w.db.tagOf(acc.id, n)
        if t.remoteId.len == 0:
          graphAddCategory(tok, n, nearestPreset(t.color))
          w.db.upsertTag(acc.id, n, t.color, n)
      graphPatch(tok, remote, %*{"categories": names})
    of akGmail:
      var removed: seq[string]
      for t in d{"removed"}.getElems: removed.add t.getStr
      let addIds = w.gmailLabelIds(acc, tok, names)
      var remIds: seq[string]
      for n in removed:
        let t = w.db.tagOf(acc.id, n)
        if t.remoteId.len > 0: remIds.add t.remoteId
      gmailModify(tok, remote, addIds, remIds)
    of akImap: discard
  of "move":
    let dest = w.db.folder(d{"folder"}.getInt)
    case acc.kind
    of akGraph:
      if dest.role == "trash" and m.folder > 0 and w.db.folder(m.folder).role == "trash":
        graphDeleteForever(tok, remote)
        if id > 0: w.db.deleteMessage(id)
      else:
        let newId = graphMove(tok, remote, dest.remoteId)
        if newId.len > 0 and id > 0:
          w.db.exec("UPDATE messages SET remote_id = ? WHERE id = ?", newId, id)
    of akGmail:
      if dest.role == "trash": gmailTrash(tok, remote)
      else:
        if m.folder > 0 and w.db.folder(m.folder).role == "trash": gmailUntrash(tok, remote)
        let (add, rem) = gmailFolderLabels(dest.role)
        if add.len + rem.len > 0: gmailModify(tok, remote, add, rem)
    of akImap: discard
  of "newtag":
    let name = d{"name"}.getStr
    let color = d{"color"}.getStr
    case acc.kind
    of akGraph:
      graphAddCategory(tok, name, nearestPreset(color))
      w.db.upsertTag(acc.id, name, color, name)
    of akGmail:
      let lid = gmailCreateLabel(tok, name, nearestGmail(color))
      w.db.upsertTag(acc.id, name, color, lid)
    of akImap: discard
  of "send":
    case acc.kind
    of akGraph: graphSend(tok, d)
    of akGmail:
      let raw = buildRaw(d, MailAddress(name: acc.name, email: acc.email))
      gmailSend(tok, raw, d{"threadId"}.getStr)
    of akImap: discard
    for at in d{"attachments"}.getElems:
      if at{"copy"}.getBool:
        try: removeFile(at{"path"}.getStr) except OSError: discard
    for r in d{"to"}.getElems & d{"cc"}.getElems:
      w.db.noteContact(r{"email"}.getStr, r{"name"}.getStr, epochTime())
    w.send(SyncEvent(kind: seSent, text: d{"subject"}.getStr))
  else: discard

proc runActions(w: var Worker; acc: Account): bool =
  ## Sends the account's queued changes; true when something was done.
  let due = w.db.dueActions(acc.id)
  if due.len == 0: return
  if acc.clientId == "local":
    # (Local Folders: the change was all there was to do)
    for a in due: w.db.doneAction(a.id)
    return
  let tok = w.token(acc)
  if tok.len == 0: return
  for a in due:
    if a.kind == "send": w.status("Sending \"" & a.data{"subject"}.getStr & "\"...")
    try:
      w.runAction(acc, tok, a)
      w.db.doneAction(a.id)
      result = true
    except ApiError as e:
      if e.status == 401:
        w.forget(acc.id)
        w.db.retryAction(a.id, 5)
        break
      elif e.status == 0 or e.status == 429 or e.status >= 500 or e.status == 408:
        let wait = if e.retryAfter > 0: e.retryAfter else: min(600.0, 10.0 * float(1 shl min(a.tries, 6)))
        w.db.retryAction(a.id, wait)
        if e.status == 0: break           # (offline: the rest waits too)
      else:
        w.db.failAction(a.id, e.msg)
        w.send(SyncEvent(kind: seError, id: acc.id, text: e.msg))
    except CatchableError as e:
      w.db.failAction(a.id, e.msg)
      w.send(SyncEvent(kind: seError, id: acc.id, text: e.msg))
  w.status("")

# ---- syncing ---------------------------------------------------------------------------

proc noteNew(w: var Worker; acc: Account; m: Msg; folderRole: string; count: var int;
             latest: var string) =
  if folderRole != "inbox" or not m.unread or m.mine: return
  let seen = w.newest.getOrDefault(acc.id, -1.0)
  if seen < 0: return                    # (the first sync: nothing is "new")
  if m.date > seen:
    inc count
    latest = (if m.fromName.len > 0: m.fromName else: m.fromEmail) & ": " & m.subject
    w.fresh.add m.remoteId               # (the rules look at it once it is stored)

proc markNewest(w: var Worker; acc: Account) =
  let v = w.db.value("SELECT max(date) FROM messages m JOIN folders f ON f.id = m.folder " &
                     "WHERE m.account = ? AND f.role = 'inbox'", acc.id)
  w.newest[acc.id] = (if v.isNull: -1.0 else: v.flt)

proc syncGraph(w: var Worker; acc: Account; tok: string; count: var int; latest: var string) =
  let me = acc.email
  if epochTime() - w.lastFolders.getOrDefault(acc.id, 0) > 1800:
    w.status("Checking folders of " & acc.email & "...")
    let fs = graphFolders(tok)
    var keep: HashSet[string]
    w.db.transaction:
      for f in fs:
        keep.incl f.remoteId
        discard w.db.upsertFolder(acc.id, f.remoteId, f.name, f.role, f.parent, f.unread, f.total)
      for f in w.db.folders(acc.id):
        if f.remoteId notin keep:
          for r in w.db.all("SELECT id FROM messages WHERE folder = ?", f.id):
            w.db.deleteMessage(int r[0].num)
          w.db.exec("DELETE FROM folders WHERE id = ?", f.id)
    try:
      let cats = graphCategories(tok)
      w.db.transaction:
        for c in cats: w.db.upsertTag(acc.id, c.name, presetColor(c.color), c.name)
    except ApiError: discard
    w.lastFolders[acc.id] = epochTime()
  for f in w.db.folders(acc.id):
    if f.role == "outbox": continue
    var delta = f.delta
    for round in 0 ..< 20:
      w.status("Downloading " & f.name & " of " & acc.email & "...")
      var res: tuple[items: seq[GraphItem]; next: string; done: bool]
      try:
        res = graphDelta(tok, f.remoteId, delta, acc.syncDays, acc.id, me)
      except ApiError as e:
        if e.status in [400, 404, 410]:
          w.db.setFolderDelta(f.id, "")        # (an expired delta: start again next time)
          break
        raise
      w.db.transaction:
        for it in res.items:
          if it.removed:
            w.db.deleteByRemote(acc.id, it.msg.remoteId)
            continue
          var m = it.msg
          let fr = if it.folderRemote.len > 0: w.db.folderByRemote(acc.id, it.folderRemote) else: f
          m.folder = if fr.id > 0: fr.id else: f.id
          w.noteNew(acc, m, (if fr.id > 0: fr.role else: f.role), count, latest)
          discard w.db.upsertMessage(m)
          w.db.noteContact(m.fromEmail, m.fromName, m.date)
        w.db.setFolderDelta(f.id, res.next)
      if res.items.len > 0: w.send(SyncEvent(kind: seChanged))
      if res.done or res.next.len == 0: break
      delta = res.next
      for c in w.pending():          # (the window may want a body meanwhile)
        case c.kind
        of scBody: w.fetchBody(c.id)
        of scAttachment: w.fetchAttachment(c.id)
        of scQuit:
          w.later.add c
          return
        else: w.later.add c
  w.db.recount(acc.id)

proc syncGmail(w: var Worker; acc: Account; tok: string; count: var int; latest: var string) =
  var names = initTable[string, string]()
  if epochTime() - w.lastFolders.getOrDefault(acc.id, 0) > 1800 or acc.history.len == 0:
    w.status("Checking labels of " & acc.email & "...")
    let labels = gmailLabels(tok)
    w.db.transaction:
      for (rid, name, role) in systemFolders:
        discard w.db.upsertFolder(acc.id, rid, name, role, "")
      for l in labels:
        if l.kind == "user":
          w.db.upsertTag(acc.id, l.name, l.color, l.id)
    w.lastFolders[acc.id] = epochTime()
  for t in w.db.tags(acc.id):
    if t.remoteId.len > 0: names[t.remoteId] = t.name
  proc store(w: var Worker; metas: seq[JsonNode]; count: var int; latest: var string) =
    w.db.transaction:
      for j in metas:
        let (m0, fr) = parseMeta(j, acc.id, acc.email, names)
        var m = m0
        let f = w.db.folderByRemote(acc.id, fr)
        m.folder = f.id
        w.noteNew(acc, m, f.role, count, latest)
        discard w.db.upsertMessage(m)
        w.db.noteContact(m.fromEmail, m.fromName, m.date)
  if acc.history.len == 0:
    w.status("Listing the mail of " & acc.email & "...")
    let (_, hist) = gmailProfile(tok)
    let ids = gmailListIds(tok, "newer_than:" & $max(acc.syncDays, 1) & "d", 20000)
    var i = 0
    while i < ids.len:
      w.status("Downloading " & acc.email & ": " & $i & " of " & $ids.len & "...")
      let chunk = ids[i ..< min(i + 200, ids.len)]
      w.store(gmailMetadata(tok, chunk), count, latest)
      w.send(SyncEvent(kind: seChanged))
      i += 200
      for c in w.pending():
        case c.kind
        of scBody: w.fetchBody(c.id)
        of scAttachment: w.fetchAttachment(c.id)
        of scQuit:
          w.later.add c
          return
        else: w.later.add c
    w.db.setHistory(acc.id, hist)
  else:
    var ch: tuple[changed, deleted: seq[string]; latest: string]
    try:
      ch = gmailHistory(tok, acc.history)
    except ApiError as e:
      if e.status == 404:
        w.db.setHistory(acc.id, "")
        return
      raise
    if ch.deleted.len > 0:
      w.db.transaction:
        for d in ch.deleted: w.db.deleteByRemote(acc.id, d)
    if ch.changed.len > 0:
      w.status("Downloading " & $ch.changed.len & " changes of " & acc.email & "...")
      let metas = gmailMetadata(tok, ch.changed)
      w.store(metas, count, latest)
      # messages history reported but gone (deleted for good meanwhile)
      var got: HashSet[string]
      for j in metas: got.incl j{"id"}.getStr
      w.db.transaction:
        for id in ch.changed:
          if id notin got: w.db.deleteByRemote(acc.id, id)
    w.db.setHistory(acc.id, ch.latest)
    if ch.changed.len + ch.deleted.len > 0: w.send(SyncEvent(kind: seChanged))
  w.db.recount(acc.id)

proc syncImap(w: var Worker; acc: Account; pw: string; count: var int; latest: var string) =
  w.withImap(acc, pw, c):
    if epochTime() - w.lastFolders.getOrDefault(acc.id, 0) > 1800 or w.db.folders(acc.id).len == 0:
      w.status("Checking folders of " & acc.email & "...")
      let tree = folderTree(c.listFolders())
      var keep: HashSet[string]
      w.db.transaction:
        for f in tree:
          keep.incl f.raw
          let id = w.db.upsertFolder(acc.id, f.raw, f.name, f.role, f.parent)
          # (a folder of folders only: never selected)
          let was = w.db.folder(id).delta
          if not f.selectable: w.db.setFolderDelta(id, NoSelect)
          elif was == NoSelect: w.db.setFolderDelta(id, "")
        for f in w.db.folders(acc.id):
          if f.remoteId notin keep:
            for r in w.db.all("SELECT id FROM messages WHERE folder = ?", f.id):
              w.db.deleteMessage(int r[0].num)
            w.db.exec("DELETE FROM folders WHERE id = ?", f.id)
      w.lastFolders[acc.id] = epochTime()
    # the Inbox first, then Sent, Drafts, the rest
    var fs = w.db.folders(acc.id)
    proc order(f: Folder): int =
      case f.role
      of "inbox": 0
      of "sent": 1
      of "drafts": 2
      of "": 3
      else: 4
    fs.sort(proc (a, b: Folder): int = cmp(order(a), order(b)))
    for f in fs:
      if f.delta == NoSelect: continue                       # (a folder of folders)
      w.status("Downloading " & f.name & " of " & acc.email & "...")
      let box = c.select(f.remoteId)
      var st = try: parseJson(f.delta) except CatchableError: newJObject()
      if st.kind != JObject: st = newJObject()
      if st{"v"}.getBiggestInt(0) != box.uidValidity:
        # (new UIDs: the folder is read again)
        for r in w.db.all("SELECT id FROM messages WHERE folder = ?", f.id):
          w.db.deleteMessage(int r[0].num)
        st = %*{"v": box.uidValidity, "next": 0, "modseq": 0}
      # what is kept here of this folder, by UID
      var local = initTable[int64, int]()
      for r in w.db.all("SELECT id, remote_id FROM messages WHERE folder = ?", f.id):
        let (_, uid) = splitRemote(r[1].str)
        if uid > 0: local[uid] = int r[0].num
      # gone from the server
      let onServer = c.uidSearch("ALL")
      var there = initHashSet[int64]()
      for u in onServer: there.incl u
      w.db.transaction:
        for uid, id in local:
          if uid notin there: w.db.deleteMessage(id)
      # new: after the last one seen (the first time, the days kept)
      let next = st{"next"}.getBiggestInt(0)
      var fresh: seq[int64]
      if next <= 0:
        let since = epochTime() - float(max(acc.syncDays, 1)) * 86400
        fresh = c.uidSearch("SINCE " & imapDate(since))
      else:
        for u in onServer:
          if u >= next and not local.hasKey(u): fresh.add u
      fresh.reverse()                                        # (the newest first)
      var i = 0
      while i < fresh.len:
        let part = fresh[i ..< min(i + 200, fresh.len)]
        let hs = c.fetchHeaders(part)
        w.db.transaction:
          for im in hs:
            let m = msgOfImap(acc, f, im)
            w.noteNew(acc, m, f.role, count, latest)
            discard w.db.upsertMessage(m)
            w.db.noteContact(m.fromEmail, m.fromName, m.date)
        w.send(SyncEvent(kind: seChanged))
        i += 200
        for cm in w.pending():                     # (the window may want a body meanwhile)
          case cm.kind
          of scBody: w.fetchBody(cm.id)
          of scAttachment: w.fetchAttachment(cm.id)
          of scQuit:
            w.later.add cm
            return
          else: w.later.add cm
        if c.selected != f.remoteId: discard c.select(f.remoteId)
      # flags changed elsewhere (only what changed, where the server counts changes)
      let modseq = st{"modseq"}.getBiggestInt(0)
      if local.len > 0 and (modseq == 0 or box.highestModSeq == 0 or box.highestModSeq > modseq):
        var known: seq[int64]
        for uid in local.keys:
          if uid in there: known.add uid
        let changed = c.fetchFlags(known, changedSince = (if box.highestModSeq > 0: modseq else: 0))
        if changed.len > 0:
          w.db.transaction:
            for im in changed:
              let id = local.getOrDefault(im.uid)
              if id == 0: continue
              var unread = true
              var flagged = false
              var tags: seq[string]
              for fl in im.flags:
                case fl.toLowerAscii
                of "\\seen": unread = false
                of "\\flagged": flagged = true
                else:
                  if not fl.startsWith("\\") and not (fl.startsWith("$") and not fl.toLowerAscii.startsWith("$label")):
                    tags.add tagOfKeyword(fl)
              # (a change made here, not sent yet, stays)
              var waiting = false
              for r in w.db.rows("SELECT 1 FROM actions WHERE error = '' AND " &
                                 "json_extract(data, '$.id') = ?", id):
                waiting = true
              if waiting: continue
              w.db.setFlags(id, unread = ord(unread), flagged = ord(flagged))
              w.db.setTags(id, tags)
          w.send(SyncEvent(kind: seChanged))
      st["next"] = %box.uidNext
      st["modseq"] = %box.highestModSeq
      w.db.setFolderDelta(f.id, $st)
  w.db.recount(acc.id)


proc syncCalendar(w: var Worker; acc: Account; tok: string) =
  let fromT = epochTime() - 31 * 86400
  let toT = epochTime() + 92 * 86400
  let evs = calendarEvents(acc, tok, fromT, toT)
  w.db.transaction:
    w.db.clearEvents(acc.id, fromT, toT)
    for e in evs: w.db.upsertEvent(e)
  w.lastCal[acc.id] = epochTime()

proc prefetch(w: var Worker; acc: Account; n = 25) =
  ## Bodies of the newest messages, so they open at once (and offline).
  for r in w.db.all("SELECT id FROM messages WHERE account = ? AND body_state = 0 " &
                    "ORDER BY date DESC LIMIT ?", acc.id, n):
    if w.link.cmds.peek() > 0: break
    w.fetchBody(int r[0].num)

proc syncAccount(w: var Worker; acc: Account) =
  for attempt in 0 .. 1:
    let tok = w.token(acc)
    if tok.len == 0: return
    var count = 0
    var latest = ""
    try:
      if acc.state.len > 0: w.db.setAccountState(acc.id, "")
      if not w.newest.hasKey(acc.id): w.markNewest(acc)
      w.fresh.setLen(0)
      case acc.kind
      of akGraph: w.syncGraph(acc, tok, count, latest)
      of akGmail: w.syncGmail(w.db.account(acc.id), tok, count, latest)
      of akImap: w.syncImap(acc, tok, count, latest)
      if w.fresh.len > 0:
        var ids: seq[int]
        for r in w.fresh:
          let m = w.db.messageByRemote(acc.id, r)
          if m.id > 0: ids.add m.id
        w.applyRules(acc, ids)
        w.fresh.setLen(0)
      w.markNewest(acc)
      if acc.kind != akImap and epochTime() - w.lastCal.getOrDefault(acc.id, 0) > 900:
        try: w.syncCalendar(acc, tok)
        except ApiError: discard         # (no calendar permission: mail still works)
      w.prefetch(acc)
      w.lastFull[acc.id] = epochTime()
      if count > 0:
        addUnannounced(count, latest)
        w.send(SyncEvent(kind: seNewMail, id: acc.id, count: count, text: latest))
      w.send(SyncEvent(kind: seChanged))
      return
    except ApiError as e:
      if e.status == 401 and attempt == 0:
        w.forget(acc.id)                 # (refused: a fresh token, once more)
        continue
      w.db.setAccountState(acc.id, e.msg)
      w.send(SyncEvent(kind: seError, id: acc.id, text: e.msg))
    except CatchableError as e:
      w.db.setAccountState(acc.id, e.msg)
      w.send(SyncEvent(kind: seError, id: acc.id, text: e.msg))
    w.send(SyncEvent(kind: seChanged))
    return

proc search(w: var Worker; q: string) =
  var ids: seq[int]
  for acc in w.db.accounts():
    let tok = w.token(acc)
    if tok.len == 0: continue
    try:
      case acc.kind
      of akGraph:
        for it in graphSearch(tok, q, acc.id, acc.email):
          var m = it.msg
          let f = w.db.folderByRemote(acc.id, it.folderRemote)
          if f.id == 0: continue
          m.folder = f.id
          ids.add w.db.upsertMessage(m)
      of akGmail:
        var names = initTable[string, string]()
        for t in w.db.tags(acc.id):
          if t.remoteId.len > 0: names[t.remoteId] = t.name
        let found = gmailListIds(tok, q, 100)
        for j in gmailMetadata(tok, found):
          let (m0, fr) = parseMeta(j, acc.id, acc.email, names)
          var m = m0
          m.folder = w.db.folderByRemote(acc.id, fr).id
          ids.add w.db.upsertMessage(m)
      of akImap:
        # (the Inbox and Sent on the server: what is older than the days kept here)
        w.withImap(acc, tok, c):
          for role in ["inbox", "sent"]:
            let f = w.db.folderByRole(acc.id, role)
            if f.id == 0: continue
            discard c.select(f.remoteId)
            var found = c.uidSearch("TEXT " & quoted(q))
            if found.len > 100: found = found[^100 .. ^1]
            for im in c.fetchHeaders(found):
              ids.add w.db.upsertMessage(msgOfImap(acc, f, im))
    except CatchableError as e:
      w.send(SyncEvent(kind: seError, id: acc.id, text: e.msg))
  w.send(SyncEvent(kind: seSearch, ids: ids, text: q))

proc fetchSignatures(w: var Worker; id: int) =
  ## The signatures the account has on the web, for the window to keep.
  let acc = w.db.account(id)
  if acc.id == 0 or acc.clientId == "local": return
  let tok = w.token(acc)
  if tok.len == 0: return
  try:
    var newHtml, replyHtml: string
    case acc.kind
    of akGmail:
      newHtml = gmailSignature(tok, acc.email)
      replyHtml = newHtml
    of akGraph:
      (newHtml, replyHtml) = graphSignatures(tok, acc.email)
    of akImap: return                     # (IMAP keeps no signature)
    w.send(SyncEvent(kind: seSignature, id: id, text: $(%*{"new": newHtml, "reply": replyHtml})))
  except CatchableError as e:
    w.send(SyncEvent(kind: seSignature, id: id, text: $(%*{"error": e.msg})))

proc inviteJson(inv: Invite): JsonNode =
  %*{"kind": $inv.kind, "title": inv.title, "location": inv.location, "start": inv.start,
     "finish": inv.finish, "allDay": inv.allDay, "recurring": inv.recurring,
     "organizer": (if inv.organizerName.len > 0: inv.organizerName else: inv.organizerEmail),
     "answer": $inv.answer, "rsvp": inv.rsvp,
     "replyName": (if inv.replyName.len > 0: inv.replyName else: inv.replyEmail),
     "replyAnswer": $inv.replyAnswer}

proc invite(w: var Worker; c: SyncCmd) =
  ## A meeting invitation in a message: what it is, or the answer sent.
  let m = w.db.message(c.id)
  let acc = w.db.account(m.account)
  if m.id == 0 or acc.id == 0: return
  let tok = w.token(acc)
  if tok.len == 0: return
  try:
    var inv = inviteOf(acc, tok, m)
    if c.kind == scRespond and inv.kind == ikRequest:
      let j = try: parseJson(c.text) except CatchableError: newJObject()
      let answer = case j{"answer"}.getStr
                   of "accepted": iaAccept
                   of "tentative": iaTentative
                   else: iaDecline
      respondInvite(acc, tok, inv, answer, j{"comment"}.getStr, j{"send"}.getBool(true))
      inv.answer = answer
      if acc.kind == akGraph or answer != iaDecline:
        w.lastCal[acc.id] = 0                 # (the calendar shows it next time)
    w.send(SyncEvent(kind: seInvite, id: c.id, text: $inviteJson(inv)))
  except CatchableError as e:
    w.send(SyncEvent(kind: seInvite, id: c.id, text: $(%*{"error": e.msg})))

proc autoReply(w: var Worker; c: SyncCmd) =
  ## Out of office: read or set the account's automatic replies.
  let acc = w.db.account(c.id)
  if acc.id == 0: return
  let tok = w.token(acc)
  if tok.len == 0: return
  try:
    if c.kind == scSetAutoReply:
      let j = parseJson(c.text)
      let r = AutoReply(enabled: j{"enabled"}.getBool, scheduled: j{"scheduled"}.getBool,
                        start: j{"start"}.getFloat, finish: j{"finish"}.getFloat,
                        subject: j{"subject"}.getStr, internalHtml: j{"internalHtml"}.getStr,
                        externalHtml: j{"externalHtml"}.getStr,
                        externalAudience: j{"externalAudience"}.getStr("all"))
      setAutoReply(acc, tok, r)
    let r = getAutoReply(acc, tok)
    w.send(SyncEvent(kind: seAutoReply, id: c.id, count: ord(c.kind == scSetAutoReply),
                     text: $(%*{"enabled": r.enabled, "scheduled": r.scheduled, "start": r.start,
                                "finish": r.finish, "subject": r.subject,
                                "internalHtml": r.internalHtml, "externalHtml": r.externalHtml,
                                "externalAudience": r.externalAudience})))
  except CatchableError as e:
    var msg = e.msg
    if e of ref ApiError and (ref ApiError)(e).status in [401, 403]:
      msg = "Retro Mail may not do this yet: Tools, Accounts, Sign In Again, and allow it"
    w.send(SyncEvent(kind: seAutoReply, id: c.id, text: $(%*{"error": msg})))

proc assistant(w: var Worker; c: SyncCmd) =
  ## Summarize or translate, with the user's own key (Options, Assistant).
  let j = try: parseJson(c.text) except CatchableError: newJObject()
  let kind = j{"kind"}.getStr
  let id = j{"id"}.getInt
  let key = loadSecret(secretApp, "ai-key")
  let model = j{"model"}.getStr("claude-haiku-5-5")
  try:
    if key.len == 0: raise newException(ValueError, "no key: Tools, Options, Assistant takes it")
    let m = w.db.message(id)
    var text = ""
    case kind
    of "summary":
      var thread: seq[tuple[sender, date, text: string]]
      let ms = w.db.threadMessages(m.account, m.thread)
      for k in countdown(ms.high, 0):
        let x = ms[k]
        let body = if x.text.len > 0: x.text else: plainOf(x.html)
        thread.add ((if x.fromName.len > 0: x.fromName else: x.fromEmail),
                    fromUnixFloat(x.date).local.format("yyyy-MM-dd HH:mm"),
                    (if body.len > 0: body else: x.snippet))
      text = summarize(key, model, thread, j{"to"}.getStr, w.db.account(m.account).name)
    else:
      let body = if m.text.len > 0: m.text else: plainOf(m.html)
      text = translate(key, model, if body.len > 0: body else: m.snippet, j{"to"}.getStr("English"))
    w.send(SyncEvent(kind: seAssist, id: id, text: $(%*{"kind": kind, "id": id, "text": text})))
  except CatchableError as e:
    w.send(SyncEvent(kind: seAssist, id: id, text: $(%*{"kind": kind, "id": id, "error": e.msg})))

proc rawOf(w: var Worker; c: SyncCmd) =
  ## A message's whole source: to forward it attached (`count` 0), saved
  ## where asked (1), or to be read in its Properties (2).
  let m = w.db.message(c.id)
  let acc = w.db.account(m.account)
  if m.id == 0 or acc.id == 0: return
  try:
    var data = ""
    if acc.clientId == localClient:          # (Local Folders: written out from what is kept)
      data = rawOf(w.db, m, MailAddress(name: acc.name, email: acc.email))
    else:
      let tok = w.token(acc)
      if tok.len == 0: raise newException(IOError, "sign in to " & acc.email & " again")
      data = rawMessage(acc, tok, m.remoteId)
    let path = case c.count
      of 1: c.text
      of 2: mailDir() / "outbox" / ("source-" & $m.id & ".eml")
      else: mailDir() / "outbox" / "fwd" / ("fwd-" & $m.id & "-" & $int(epochTime() * 1000) & ".eml")
    createDir(path.parentDir)
    writeFile(path, data)
    w.send(SyncEvent(kind: seRaw, id: c.id, count: c.count, text: path))
  except CatchableError as e:
    w.send(SyncEvent(kind: seRaw, id: c.id, count: c.count, text: $(%*{"error": e.msg})))

proc unsubscribe(w: var Worker; id: int) =
  ## Leaves a mailing list the way its List-Unsubscribe header says: one
  ## click (RFC 8058: a POST, nothing for the user to do), else a message to
  ## its address, else its page (the window opens it in the browser).
  let (header, post) = w.db.unsubOf(id)
  let m = w.db.message(id)
  var https, mailto = ""
  for part in header.split(','):
    let u = part.strip.strip(chars = {'<', '>', ' '})
    let low = u.toLowerAscii
    if (low.startsWith("https://") or low.startsWith("http://127.0.0.1")) and https.len == 0: https = u
    elif u.toLowerAscii.startsWith("mailto:") and mailto.len == 0: mailto = u
  try:
    if https.len > 0 and "one-click" in post.toLowerAscii:
      let r = httpRequest("POST", https, [("Content-Type", "application/x-www-form-urlencoded")],
                          "List-Unsubscribe=One-Click", timeoutSec = 20)
      if not r.ok: raise newException(IOError, "the list answered " & $r.status)
      w.send(SyncEvent(kind: seUnsub, id: id, text: $(%*{"how": "post", "url": https})))
    elif mailto.len > 0:
      let q = mailto[7 .. ^1]
      let k = q.find('?')
      let address = decodeUrl(if k >= 0: q[0 ..< k] else: q)
      var subject = "unsubscribe"
      var body = "unsubscribe"
      if k >= 0:
        for kv in q[k + 1 .. ^1].split('&'):
          let e = kv.find('=')
          if e > 0:
            case kv[0 ..< e].toLowerAscii
            of "subject": subject = decodeUrl(kv[e + 1 .. ^1])
            of "body": body = decodeUrl(kv[e + 1 .. ^1])
            else: discard
      discard w.db.queueAction(m.account, "send", %*{"mode": "new", "to": [{"name": "", "email": address}],
        "cc": [], "bcc": [], "subject": subject, "html": "<p>" & body & "</p>", "text": body,
        "attachments": []})
      w.send(SyncEvent(kind: seUnsub, id: id, text: $(%*{"how": "mail", "url": address})))
    elif https.len > 0:
      w.send(SyncEvent(kind: seUnsub, id: id, text: $(%*{"how": "open", "url": https})))
    else:
      w.send(SyncEvent(kind: seUnsub, id: id, text: $(%*{"error": "this message says no way to leave its list"})))
  except CatchableError as e:
    if https.len > 0:
      w.send(SyncEvent(kind: seUnsub, id: id, text: $(%*{"how": "open", "url": https, "error": e.msg})))
    else:
      w.send(SyncEvent(kind: seUnsub, id: id, text: $(%*{"error": e.msg})))

proc eventChange(w: var Worker; c: SyncCmd) =
  ## The window's new event, change or delete in account `c.id`'s calendar
  ## (the attendees told by the service); then the calendar read again.
  let acc = w.db.account(c.id)
  if acc.id == 0: return
  let j = try: parseJson(c.text) except CatchableError: newJObject()
  let what = case c.kind
             of scEventNew: 0
             of scEventChange: 1
             else: 2
  var rid = j{"event"}.getStr
  try:
    let tok = w.token(acc)
    if tok.len == 0: raise newException(ValueError, acc.email & " must sign in again first")
    case c.kind
    of scEventNew: rid = createEvent(acc, tok, draftFromJson(j{"draft"}))
    of scEventChange:
      updateEvent(acc, tok, rid, draftFromJson(j{"draft"}), partsFromJson(j{"parts"}),
                  j{"occurrence"}.getFloat)
    else:
      deleteEvent(acc, tok, rid, j{"cancel"}.getBool, j{"comment"}.getStr)
      w.db.removeEvent(acc.id, rid)
    try: w.syncCalendar(acc, tok)
    except CatchableError: w.lastCal[acc.id] = 0      # (read with the next check)
    w.send(SyncEvent(kind: seEvent, id: acc.id, count: what,
                     text: $(%*{"event": rid, "joinUrl": w.db.eventByRemote(acc.id, rid).joinUrl})))
  except CatchableError as e:
    var msg = e.msg
    if e of ref ApiError:
      let st = (ref ApiError)(e).status
      if st == 401: w.forget(acc.id)
      if st == 403: msg = "Retro Mail may not change this calendar yet: Tools, Accounts, Sign In Again, and allow it"
    w.send(SyncEvent(kind: seEvent, id: acc.id, count: what, text: $(%*{"event": rid, "error": msg})))

proc applyRules(w: var Worker; acc: Account; ids: seq[int]) =
  ## The message rules on mail that just came: tags, read, flag, pin, a
  ## folder, the trash -- here at once, on the server through the queue.
  let js = w.db.rulesJson()
  if js.len == 0 or ids.len == 0: return
  let rs = try: rulesFromJson(parseJson(js)) except CatchableError: @[]
  if rs.len == 0: return
  w.db.transaction:
    for id in ids:
      let m = w.db.message(id)
      if m.id == 0: continue
      let r = ruleActions(rs, m)
      if r.matched.len == 0: continue
      template q(kind: string; data: JsonNode) =
        var d = data
        d["id"] = %m.id
        d["remote"] = %m.remoteId
        discard w.db.queueAction(m.account, kind, d)
      if r.markRead and m.unread:
        w.db.setFlags(m.id, unread = 0)
        q("read", %*{"unread": false})
      if r.flag and not m.flagged:
        w.db.setFlags(m.id, flagged = 1)
        q("flag", %*{"flagged": true})
      if r.pin: w.db.setPinned(m.id, true)
      if r.tags.len > 0:
        var ts = m.tags
        for t in r.tags:
          if not ts.anyIt(it.toLowerAscii == t.toLowerAscii): ts.add t
        if ts.len != m.tags.len:
          for t in r.tags:
            if w.db.tagOf(m.account, t).id == 0: w.db.upsertTag(m.account, t, "", "")
          w.db.setTags(m.id, ts)
          q("tags", %*{"tags": ts, "removed": newJArray()})
      var dest = Folder()
      if r.delete: dest = w.db.folderByRole(m.account, "trash")
      elif r.moveTo.len > 0:
        dest = w.db.folderByRole(m.account, r.moveTo)
        if dest.id == 0: dest = w.db.folderByRemote(m.account, r.moveTo)
      if dest.id > 0 and dest.id != m.folder:
        q("move", %*{"folder": dest.id})
        w.db.moveLocal(m.id, dest.id)
  w.db.recount(acc.id)

proc syncOnce*(dbPath: string): tuple[count: int; latest: string] =
  ## One pass without the window -- the changes waiting here sent, new mail
  ## fetched -- for a check made while the app is closed (Android's
  ## background check): how many messages came that nobody was told about
  ## (also those the app's own sync fetched while its window slept), and the
  ## newest's sender and subject.
  var link: SyncLink
  link.cmds.open()
  link.events.open()
  link.dbPath = dbPath
  var w = Worker(link: addr link, interval: 60)
  try:
    w.db = openStore(dbPath)
    for a in w.db.accounts():
      if a.clientId == "local": continue
      discard w.runActions(a)
      w.markNewest(a)
      w.syncAccount(a)
    w.db.close()
  except CatchableError: discard
  while true:
    let (ok, _) = link.events.tryRecv()
    if not ok: break
  result = takeUnannounced()
  link.cmds.close()
  link.events.close()

proc syncMain*(link: ptr SyncLink) {.thread.} =
  ## The sync thread's body.
  {.gcsafe.}:
    var w = Worker(link: link, interval: 60)
    try:
      w.db = openStore(link.dbPath)
    except CatchableError as e:
      link.events.send(SyncEvent(kind: seError, text: "the store: " & e.msg))
      return
    var force = true
    var running = true
    var lastActions = 0.0
    while running:
      var wantSync = force
      force = false
      for c in w.pending():
        case c.kind
        of scQuit: running = false
        of scSyncNow, scAccounts:
          wantSync = true
          if c.kind == scAccounts: w.tokens.clear()
          for k in w.lastFolders.mvalues: k = 0
          for k in w.lastCal.mvalues: k = 0
        of scWake: lastActions = 0
        of scBody: w.fetchBody(c.id)
        of scAttachment: w.fetchAttachment(c.id)
        of scSearch: w.search(c.text)
        of scSettings: w.interval = float(max(1, c.count) * 60)
        of scSignatures: w.fetchSignatures(c.id)
        of scInvite, scRespond: w.invite(c)
        of scGetAutoReply, scSetAutoReply: w.autoReply(c)
        of scAssist: w.assistant(c)
        of scRaw: w.rawOf(c)
        of scUnsubscribe: w.unsubscribe(c.id)
        of scEventNew, scEventChange, scEventDelete: w.eventChange(c)
      if not running: break
      let accs = w.db.accounts()
      # changes made here go out first (every few seconds while there are some)
      if epochTime() - lastActions > 3:
        var did = false
        for a in accs:
          if w.runActions(a): did = true
        if did: w.send(SyncEvent(kind: seChanged))
        lastActions = epochTime()
      for a in accs:
        if a.clientId == "local": continue        # (Local Folders: nothing to fetch)
        if wantSync or epochTime() - w.lastFull.getOrDefault(a.id, 0) > w.interval:
          w.syncAccount(a)
          w.status("")
          if w.link.cmds.peek() > 0: break
      # sleep a little, waking for commands
      for i in 0 ..< 10:
        if w.link.cmds.peek() > 0: break
        sleep(100)
    w.db.close()

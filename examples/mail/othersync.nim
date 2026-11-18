## Retro Mail's POP3, JMAP and Exchange (EWS) accounts: what the sync
## thread does for them (examples/mail/sync.nim calls it) -- their folders
## and messages kept in step, a message's whole source, the changes made
## here on the server, sending, the server's search -- and the check the
## Add Account Wizard makes. Their servers are kept in `Account.server`
## (JSON: {"pop": ..., "smtp": ...}, {"jmap": ...}, {"ews": ...}), the
## password or token with the account's sign-in (retroui/secrets).
##
## POP3 has only the Inbox on the server: the other folders are kept here
## (Sent, Drafts, Trash), a message is downloaded once, and it stays on the
## server unless the account says otherwise (`leave`: false), or until it
## is deleted here (`deleteWithLocal`).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[json, strutils, times, sets, tables, algorithm, sequtils]
import retroui/[db, mime, pop3, jmap, ews, netconn]
import api, store, imapsync
from gmail import buildRaw

var toHtml*: proc (text: string): string {.nimcall, gcsafe.}
  ## (how a plain message becomes the HTML the window shows: sync.nim's textToHtml)

proc buildRawFor(d: JsonNode; acc: Account): string =
  buildRaw(d, MailAddress(name: acc.name, email: acc.email))

proc guardSmtp(acc: Account; pw: string; rcpts: seq[string]; raw: string): string =
  smtpSendRaw(acc, pw, rcpts, raw)

proc checkSmtp(acc: Account; pw: string): string = imapsync.checkSmtp(acc, pw)

type
  OnNew* = proc (m: Msg; role: string) {.closure.}
    ## (a message that came: for the new-mail count and the rules)
  OnChanged* = proc () {.closure.}

proc protoError*(e: ref CatchableError): ref ApiError =
  ## POP3's, JMAP's and EWS's errors as the sync thread treats the
  ## services': 0 (no connection), 401 (the password), 400.
  result = newException(ApiError, e.msg)
  if e of ref NetError: result.status = 0
  elif e of ref Pop3Error:
    let m = e.msg.toUpperAscii
    result.status = if "[AUTH]" in m or "PASSWORD" in m or "LOGIN" in m or "CREDENTIALS" in m: 401
                    elif "[IN-USE]" in m or "[SYS/TEMP]" in m: 503
                    else: 400
  elif e of ref JmapError:
    let s = (ref JmapError)(e).status
    result.status = if s in [401, 403]: 401 elif s == 0: 0 elif s >= 500 or s == 429: 503 else: 400
  elif e of ref EwsError:
    let x = (ref EwsError)(e)
    result.status = if x.status == 401: 401 elif x.status == 0: 0
                    elif x.code in ["ErrorServerBusy", "ErrorTimeoutExpired"]: 503
                    elif x.code == "ErrorItemNotFound": 404
                    else: 400
  elif e of ref ApiError: result.status = (ref ApiError)(e).status
  else: result.status = 400

template guard(body: untyped) =
  try: body
  except ApiError: raise
  except CatchableError as e: raise protoError(e)

proc msgOfRaw*(acc: Account; f: Folder; remoteId, raw: string; size = 0; date = 0.0): Msg =
  ## A message as the store keeps it, from its header fields (as
  ## imapsync's msgOfImap).
  let h = parseMime(raw)
  result = Msg(account: acc.id, folder: f.id, remoteId: remoteId)
  result.subject = h.decodedHeader("Subject")
  let fr = parseAddresses(h.header("From"))
  if fr.len > 0:
    result.fromName = fr[0].name
    result.fromEmail = fr[0].email
  result.toList = h.decodedHeader("To")
  result.ccList = h.decodedHeader("Cc")
  result.msgId = h.header("Message-ID").strip
  result.inReplyTo = h.header("In-Reply-To").strip
  result.refs = h.header("References").strip
  let first = result.refs.splitWhitespace()
  result.thread = if first.len > 0: first[0] elif result.inReplyTo.len > 0: result.inReplyTo
                  elif result.msgId.len > 0: result.msgId else: remoteId
  result.date = parseMailDate(h.header("Date"))
  if result.date <= 0 or result.date > epochTime() + 2 * 86400: result.date = (if date > 0: date else: epochTime())
  result.size = if size > 0: size else: raw.len
  result.unread = true
  result.hasAtt = h.header("Content-Type").toLowerAscii.startsWith("multipart/mixed")
  let imp = h.header("Importance").strip.toLowerAscii
  let prio = h.header("X-Priority").strip
  result.important = imp == "high" or prio.startsWith("1") or prio.startsWith("2")
  result.focused = true
  result.mine = acc.email.len > 0 and result.fromEmail.toLowerAscii == acc.email.toLowerAscii
  if f.role == "drafts": result.draft = true

proc toList(j: JsonNode): string =
  var parts: seq[string]
  for a in j.getElems:
    let name = a{"name"}.getStr
    let email = a{"email"}.getStr
    parts.add(if name.len > 0 and name != email: name & " <" & email & ">" else: email)
  parts.join(", ")

proc rcptsOf(d: JsonNode): seq[string] =
  for r in d{"to"}.getElems & d{"cc"}.getElems & d{"bcc"}.getElems:
    let e = r{"email"}.getStr.strip
    if e.len > 0: result.add e

proc otherJson(acc: Account): JsonNode =
  result = try: parseJson(acc.server) except CatchableError: newJObject()
  if result.kind != JObject: result = newJObject()

# ---- POP3 ---------------------------------------------------------------------------------

proc popOf(acc: Account; pw: string): Pop3Client =
  let j = otherJson(acc){"pop"}
  let c = pop3Connect(j{"host"}.getStr, j{"port"}.getInt(995), parseSecurity(j{"security"}.getStr("tls")),
                      timeoutSec = 60, insecure = otherJson(acc){"insecure"}.getBool)
  try: c.login(j{"user"}.getStr(acc.email), pw)
  except CatchableError:
    c.close()
    raise
  c

proc popFolders*(db: Db; acc: Account) =
  ## (the folders of a POP3 account: the server's Inbox, the rest kept here)
  for (remote, name, role) in [("INBOX", "Inbox", "inbox"), ("local:sent", "Sent", "sent"),
                               ("local:drafts", "Drafts", "drafts"), ("local:trash", "Trash", "trash"),
                               ("local:junk", "Junk", "junk")]:
    if db.folderByRemote(acc.id, remote).id == 0: discard db.upsertFolder(acc.id, remote, name, role, "")

proc keepRaw(db: Db; id: int; raw: string) =
  ## (a POP3 message's source, kept: the server may not keep it)
  db.exec("CREATE TABLE IF NOT EXISTS popraw(message INTEGER PRIMARY KEY, raw BLOB)")
  db.exec("INSERT OR REPLACE INTO popraw(message, raw) VALUES(?, ?)", id, blob(raw))

proc popKept*(db: Db; acc: Account; remoteId: string): string =
  ## A POP3 message's source as it was downloaded ("" not kept).
  db.exec("CREATE TABLE IF NOT EXISTS popraw(message INTEGER PRIMARY KEY, raw BLOB)")
  let m = db.messageByRemote(acc.id, remoteId)
  if m.id == 0: return ""
  let v = db.value("SELECT raw FROM popraw WHERE message = ?", m.id)
  if v.isNull: "" else: v.str

proc popSeen(db: Db; account: int): HashSet[string] =
  db.exec("CREATE TABLE IF NOT EXISTS popseen(account INTEGER, uid TEXT, PRIMARY KEY(account, uid))")
  for r in db.rows("SELECT uid FROM popseen WHERE account = ?", account): result.incl r[0].str

proc popSync*(db: Db; acc: Account; pw: string; onNew: OnNew; changed: OnChanged) =
  ## New mail from the server's Inbox: each message downloaded once (its
  ## whole source: POP3 has nothing less), then left there or deleted.
  guard:
    popFolders(db, acc)
    let inbox = db.folderByRole(acc.id, "inbox")
    let leave = otherJson(acc){"leave"}.getBool(true)
    var seen = popSeen(db, acc.id)
    let c = popOf(acc, pw)
    try:
      let ids = c.uidl()
      let sizes = block:
        var t = initTable[int, int]()
        for (n, s) in c.list(): t[n] = s
        t
      let since = epochTime() - float(max(acc.syncDays, 1)) * 86400
      let first = seen.len == 0
      var fresh = 0
      var older = 0
      proc markSeen(uid: string) =
        db.exec("INSERT OR IGNORE INTO popseen(account, uid) VALUES(?, ?)", acc.id, uid)
      for i in countdown(ids.high, 0):       # (the newest first)
        let (num, uid) = ids[i]
        if uid in seen: continue
        if first:
          # (the first time, only the days kept: told by its header, not downloaded;
          # after twenty older ones in a row, the rest -- older still -- are left)
          let d = if older >= 20: 1.0 else: parseMailDate(parseMime(c.top(num, 0)).header("Date"))
          if d > 0 and d < since:
            inc older
            markSeen(uid)
            seen.incl uid
            continue
          older = 0
        let raw = c.retr(num)
        let m0 = msgOfRaw(acc, inbox, "pop:" & uid, raw, sizes.getOrDefault(num))
        var id = 0
        db.transaction:
          markSeen(uid)
          id = db.upsertMessage(m0)
          keepRaw(db, id, raw)
          db.noteContact(m0.fromEmail, m0.fromName, m0.date)
        storeImapBody(db, id, raw, toHtml)    # (outside: its sender's check may ask DNS)
        onNew(m0, "inbox")
        seen.incl uid
        inc fresh
        if not leave: c.dele(num)
        if fresh mod 25 == 0: changed()
      c.quit()
    except CatchableError:
      c.close()
      raise
    db.recount(acc.id)

proc popDelete*(acc: Account; pw: string; uids: openArray[string]) =
  ## Deleted from the server too (the account's `deleteWithLocal`).
  if uids.len == 0: return
  guard:
    let c = popOf(acc, pw)
    try:
      let want = block:
        var s = initHashSet[string]()
        for u in uids: s.incl u
        s
      for (num, uid) in c.uidl():
        if uid in want: c.dele(num)
      c.quit()
    except CatchableError:
      c.close()
      raise

proc popRawServer*(acc: Account; pw, remoteId: string): string =
  ## A POP3 message's source downloaded again ("" when it is no longer on the server).
  if not remoteId.startsWith("pop:"): return ""
  let uid = remoteId[4 .. ^1]
  guard:
    let c = popOf(acc, pw)
    try:
      for (num, u) in c.uidl():
        if u == uid:
          result = c.retr(num)
          break
      c.quit()
    except CatchableError:
      c.close()
      raise

# ---- JMAP ---------------------------------------------------------------------------------

proc jmapOf*(acc: Account; pw: string): JmapSession =
  let j = otherJson(acc){"jmap"}
  let user = j{"user"}.getStr
  let auth = if j{"auth"}.getStr == "basic" or user.len > 0: jmapBasic((if user.len > 0: user else: acc.email), pw)
             else: jmapBearer(pw)
  guard: result = jmapConnect(j{"url"}.getStr, auth)

proc jmapMsg(acc: Account; db: Db; e: JsonNode; boxes: Table[string, Folder]): Msg =
  var folder = Folder()
  for b, _ in e{"mailboxIds"}.pairs:
    if b in boxes:
      let f = boxes[b]
      # (in two mailboxes -- a tag-like one and the Inbox -- the Inbox's)
      if folder.id == 0 or f.role == "inbox": folder = f
  result = Msg(account: acc.id, folder: folder.id, remoteId: e{"id"}.getStr)
  result.subject = e{"subject"}.getStr
  let fr = e{"from"}
  if fr != nil and fr.len > 0:
    result.fromName = fr[0]{"name"}.getStr
    result.fromEmail = fr[0]{"email"}.getStr
  result.toList = toList(e{"to"})
  result.ccList = toList(e{"cc"})
  proc firstOf(j: JsonNode): string =
    if j != nil and j.kind == JArray and j.len > 0: "<" & j[0].getStr & ">" else: ""
  proc allOf(j: JsonNode): string =
    if j == nil or j.kind != JArray: return ""
    var parts: seq[string]
    for x in j.getElems: parts.add "<" & x.getStr & ">"
    parts.join(" ")
  result.msgId = firstOf(e{"messageId"})
  result.inReplyTo = firstOf(e{"inReplyTo"})
  result.refs = allOf(e{"references"})
  result.thread = e{"threadId"}.getStr
  try: result.date = parse(e{"receivedAt"}.getStr[0 ..< 19], "yyyy-MM-dd'T'HH:mm:ss", utc()).toTime.toUnixFloat
  except CatchableError: result.date = epochTime()
  result.size = e{"size"}.getInt
  result.snippet = e{"preview"}.getStr
  let kw = e{"keywords"}
  result.unread = kw{"$seen"} == nil
  result.flagged = kw{"$flagged"} != nil
  result.draft = kw{"$draft"} != nil
  if kw != nil:
    for k, _ in kw.pairs:
      if not k.startsWith("$"): result.tags.add tagOfKeyword(k)
  result.hasAtt = e{"hasAttachment"}.getBool
  result.focused = true
  result.mine = acc.email.len > 0 and result.fromEmail.toLowerAscii == acc.email.toLowerAscii

proc jmapFolders(db: Db; acc: Account; s: JmapSession): Table[string, Folder] =
  let boxes = s.mailboxes()
  var keep: HashSet[string]
  db.transaction:
    for b in boxes:
      keep.incl b.id
      let role = if b.role == "spam": "junk" else: b.role
      discard db.upsertFolder(acc.id, b.id, b.name, role, b.parentId, b.unread, b.total)
    for f in db.folders(acc.id):
      if f.remoteId notin keep:
        for r in db.all("SELECT id FROM messages WHERE folder = ?", f.id): db.deleteMessage(int r[0].num)
        db.exec("DELETE FROM folders WHERE id = ?", f.id)
  for f in db.folders(acc.id): result[f.remoteId] = f

proc jmapSync*(db: Db; acc: Account; pw: string; onNew: OnNew; changed: OnChanged) =
  ## The mailboxes, then what changed since the state kept (`Account.history`);
  ## the first time, each mailbox's mail of the days kept.
  guard:
    let s = jmapOf(acc, pw)
    let boxes = jmapFolders(db, acc, s)
    var since = acc.history
    proc store(ids: seq[string]; fresh: bool) =
      var i = 0
      while i < ids.len:
        let es = s.getEmails(ids[i ..< min(ids.len, i + 100)])
        db.transaction:
          for e in es:
            let m = jmapMsg(acc, db, e, boxes)
            if m.folder == 0: continue
            let had = db.messageByRemote(acc.id, m.remoteId).id > 0
            discard db.upsertMessage(m)
            if not had:
              db.noteContact(m.fromEmail, m.fromName, m.date)
              if fresh:
                var role = ""
                for f in boxes.values:
                  if f.id == m.folder: role = f.role
                onNew(m, role)
        changed()
        i += 100
    if since.len > 0:
      try:
        while true:
          let ch = s.emailChanges(since)
          store(ch.created & ch.updated, true)
          db.transaction:
            for d in ch.destroyed: db.deleteByRemote(acc.id, d)
          since = ch.newState
          db.setHistory(acc.id, since)
          if not ch.more: break
      except JmapError as e:
        if e.kind != "cannotCalculateChanges": raise
        since = ""                         # (too old: read again)
    if since.len == 0:
      let state = s.emailState()
      let after = utc(fromUnixFloat(epochTime() - float(max(acc.syncDays, 1)) * 86400)).format("yyyy-MM-dd'T'HH:mm:ss'Z'")
      var fs = toSeq(boxes.values)
      fs.sort(proc (a, b: Folder): int = cmp(ord(a.role != "inbox"), ord(b.role != "inbox")))
      for f in fs:
        let q = s.queryEmails(%*{"inMailbox": f.remoteId, "after": after}, limit = 1000)
        store(q.ids, false)
      db.setHistory(acc.id, state)
    db.recount(acc.id)

proc jmapRaw*(acc: Account; pw, remoteId: string): string =
  ## A message's whole source.
  guard:
    let s = jmapOf(acc, pw)
    let es = s.getEmails([remoteId], ["blobId"])
    if es.len == 0: raise (ref ApiError)(msg: "the message is gone", status: 404)
    result = s.download(es[0]{"blobId"}.getStr)

proc jmapSendRaw*(acc: Account; pw, raw: string; rcpts: openArray[string]) =
  ## A message made elsewhere (an invitation's answer) sent, kept in Sent.
  guard:
    let s = jmapOf(acc, pw)
    var sent = ""
    for b in s.mailboxes():
      if b.role == "sent": sent = b.id
    s.sendRaw(raw, acc.email, rcpts, sent)

proc jmapAction*(db: Db; acc: Account; pw: string; a: Action; m: Msg) =
  ## A change made here, on the server.
  let d = a.data
  guard:
    let s = jmapOf(acc, pw)
    case a.kind
    of "read": s.setKeyword(m.remoteId, "$seen", not d{"unread"}.getBool)
    of "flag": s.setKeyword(m.remoteId, "$flagged", d{"flagged"}.getBool)
    of "tags":
      var patch = newJObject()
      for t in d{"tags"}.getElems: patch["keywords/" & keywordOf(t.getStr)] = %true
      for t in d{"removed"}.getElems: patch["keywords/" & keywordOf(t.getStr)] = newJNull()
      if patch.len > 0: discard s.setEmails(%*{m.remoteId: patch})
    of "move":
      let dest = db.folder(d{"folder"}.getInt)
      let src = db.folder(m.folder)
      if dest.role == "trash" and src.role == "trash":
        s.destroyEmails([m.remoteId])
        if m.id > 0: db.deleteMessage(m.id)
      elif dest.remoteId.len > 0:
        s.setMailboxes(m.remoteId, [dest.remoteId])
    of "newtag":
      db.upsertTag(acc.id, d{"name"}.getStr, d{"color"}.getStr, keywordOf(d{"name"}.getStr))
    of "send":
      let raw = buildRawFor(d, acc)
      let sent = db.folderByRole(acc.id, "sent")
      s.sendRaw(raw, acc.email, rcptsOf(d), sent.remoteId)
      if d{"mode"}.getStr in ["reply", "replyAll"] and d{"replyTo"}.getStr.len > 0:
        try: s.setKeyword(d{"replyTo"}.getStr, "$answered", true)
        except CatchableError: discard
    else: discard

proc jmapSearch*(db: Db; acc: Account; pw: string; filter: JsonNode): seq[int] =
  ## The server's search (all mailboxes; `filter` as searchquery's
  ## jmapFilter makes it): the messages found, kept here.
  guard:
    let s = jmapOf(acc, pw)
    var boxes = initTable[string, Folder]()
    for f in db.folders(acc.id): boxes[f.remoteId] = f
    let ids = s.queryEmails(filter, limit = 100).ids
    for e in s.getEmails(ids):
      let m = jmapMsg(acc, db, e, boxes)
      if m.folder > 0: result.add db.upsertMessage(m)

# ---- Exchange (EWS) -----------------------------------------------------------------------

proc ewsOf*(acc: Account; pw: string): EwsClient =
  let j = otherJson(acc){"ews"}
  guard: result = ewsConnect(j{"url"}.getStr, j{"user"}.getStr(acc.email), pw,
                             insecure = otherJson(acc){"insecure"}.getBool)

proc ewsMsg(acc: Account; f: Folder; it: EwsItem): Msg =
  result = Msg(account: acc.id, folder: f.id, remoteId: it.id)
  result.subject = it.subject
  result.fromName = it.fromName
  result.fromEmail = it.fromEmail
  result.toList = it.toList
  result.ccList = it.ccList
  result.date = if it.received > 0: it.received else: epochTime()
  result.size = it.size
  result.snippet = it.preview
  result.unread = not it.read
  result.flagged = it.flagged
  result.important = it.important
  result.hasAtt = it.hasAttachments
  result.tags = it.categories
  result.msgId = it.messageId
  result.inReplyTo = it.inReplyTo
  result.refs = it.references
  result.thread = if it.conversation.len > 0: it.conversation else: it.id
  result.focused = true
  result.mine = acc.email.len > 0 and it.fromEmail.toLowerAscii == acc.email.toLowerAscii
  result.draft = f.role == "drafts"

proc ewsSync*(db: Db; acc: Account; pw: string; onNew: OnNew; changed: OnChanged) =
  ## The folders, then each one's changes since its state kept
  ## (`Folder.delta`); the first time, the mail of the days kept.
  guard:
    let c = ewsOf(acc, pw)
    try:
      let fs = c.folders()
      var keep: HashSet[string]
      db.transaction:
        for f in fs:
          keep.incl f.id
          discard db.upsertFolder(acc.id, f.id, f.name, f.role, f.parentId, f.unread, f.total)
        for f in db.folders(acc.id):
          if f.remoteId notin keep:
            for r in db.all("SELECT id FROM messages WHERE folder = ?", f.id): db.deleteMessage(int r[0].num)
            db.exec("DELETE FROM folders WHERE id = ?", f.id)
      let since = epochTime() - float(max(acc.syncDays, 1)) * 86400
      var folders = db.folders(acc.id)
      folders.sort(proc (a, b: Folder): int = cmp(ord(a.role != "inbox"), ord(b.role != "inbox")))
      for f in folders:
        var state = f.delta
        let first = state.len == 0
        while true:
          let ch = c.syncItems(f.remoteId, state, max = 200)
          var wanted: seq[string]
          for id in ch.changed: wanted.add id
          let items = c.getItems(wanted)
          db.transaction:
            for it in items:
              let m = ewsMsg(acc, f, it)
              if first and m.date < since: continue          # (older than the days kept)
              let had = db.messageByRemote(acc.id, m.remoteId).id > 0
              discard db.upsertMessage(m)
              if not had:
                db.noteContact(m.fromEmail, m.fromName, m.date)
                if not first: onNew(m, f.role)
            for id in ch.deleted: db.deleteByRemote(acc.id, id)
            for (id, read) in ch.readChanged:
              let m = db.messageByRemote(acc.id, id)
              if m.id > 0: db.setFlags(m.id, unread = ord(not read))
          state = ch.state
          db.setFolderDelta(f.id, state)
          if items.len > 0 or ch.deleted.len > 0 or ch.readChanged.len > 0: changed()
          if ch.done or state.len == 0: break
    finally:
      c.close()
    db.recount(acc.id)

proc ewsRaw*(acc: Account; pw, remoteId: string): string =
  ## A message's whole source.
  guard:
    let c = ewsOf(acc, pw)
    try: result = c.mimeOf(remoteId)
    finally: c.close()

proc ewsSendRaw*(acc: Account; pw, raw: string) =
  ## A message made elsewhere (an invitation's answer) sent, kept in Sent Items.
  guard:
    let c = ewsOf(acc, pw)
    try: c.sendMime(raw)
    finally: c.close()

proc ewsAction*(db: Db; acc: Account; pw: string; a: Action; m: Msg) =
  ## A change made here, on the server.
  let d = a.data
  guard:
    let c = ewsOf(acc, pw)
    try:
      case a.kind
      of "read": c.setRead(m.remoteId, not d{"unread"}.getBool)
      of "flag": c.setFlag(m.remoteId, d{"flagged"}.getBool)
      of "tags":
        let now = db.message(m.id)
        var tags: seq[string] = @[]
        if now.id > 0: tags = now.tags
        else:
          for t in d{"tags"}.getElems: tags.add t.getStr
        c.setCategories(m.remoteId, tags)
      of "move":
        let dest = db.folder(d{"folder"}.getInt)
        let src = db.folder(m.folder)
        if dest.role == "trash" and src.role == "trash":
          c.deleteItems([m.remoteId], forever = true)
          if m.id > 0: db.deleteMessage(m.id)
        elif dest.remoteId.len > 0:
          let ids = c.moveItems([m.remoteId], dest.remoteId)
          if m.id > 0 and ids.len == 1 and ids[0].len > 0:
            db.exec("UPDATE messages SET remote_id = ?, folder = ? WHERE id = ?", ids[0], dest.id, m.id)
      of "newtag":
        db.upsertTag(acc.id, d{"name"}.getStr, d{"color"}.getStr, d{"name"}.getStr)
      of "send": c.sendMime(buildRawFor(d, acc))
      else: discard
    finally:
      c.close()

proc ewsSearch*(db: Db; acc: Account; pw, q: string): seq[int] =
  ## The server's search (the Inbox and Sent Items).
  guard:
    let c = ewsOf(acc, pw)
    try:
      for role in ["inbox", "sent"]:
        let f = db.folderByRole(acc.id, role)
        if f.id == 0: continue
        for it in c.getItems(c.findItems(f.remoteId, q)):
          result.add db.upsertMessage(ewsMsg(acc, f, it))
    finally:
      c.close()

# ---- the POP3 account's changes, and sending --------------------------------------------

proc popAction*(db: Db; acc: Account; pw: string; a: Action; m: Msg) =
  ## A change made here: kept here (POP3 knows no flags or folders), but a
  ## message deleted here is deleted on the server too (`deleteWithLocal`),
  ## and mail is sent through SMTP, a copy kept in Sent.
  let d = a.data
  case a.kind
  of "move":
    let dest = db.folder(d{"folder"}.getInt)
    let src = db.folder(m.folder)
    if dest.role == "trash" and src.role == "trash":
      if otherJson(acc){"deleteWithLocal"}.getBool(true) and m.remoteId.startsWith("pop:"):
        popDelete(acc, pw, [m.remoteId[4 .. ^1]])
      if m.id > 0:
        db.exec("CREATE TABLE IF NOT EXISTS popraw(message INTEGER PRIMARY KEY, raw BLOB)")
        db.exec("DELETE FROM popraw WHERE message = ?", m.id)
        db.deleteMessage(m.id)
  of "newtag":
    db.upsertTag(acc.id, d{"name"}.getStr, d{"color"}.getStr, d{"name"}.getStr)
  of "send":
    let raw = buildRawFor(d, acc)
    let refused = guardSmtp(acc, pw, rcptsOf(d), raw)
    if refused.len > 0: raise (ref ApiError)(msg: refused, status: 400)
    popFolders(db, acc)
    let sent = db.folderByRole(acc.id, "sent")
    var m = msgOfRaw(acc, sent, "local:sent:" & $epochTime() & ":" & $raw.len, raw)
    m.unread = false
    m.mine = true
    let id = db.upsertMessage(m)
    storeImapBody(db, id, raw, toHtml)
    keepRaw(db, id, raw)
  else: discard

proc checkOtherAccount*(acc: Account; pw: string): string =
  ## Signs in once (and, for POP3, to the SMTP server too): "" when it
  ## worked, else what went wrong (for the Add Account Wizard).
  try:
    case acc.kind
    of akPop:
      let c = popOf(acc, pw)
      discard c.stat()
      c.quit()
      let s = serversOf(acc)
      if s.smtpHost.len == 0: return "No outgoing (SMTP) server."
      let r = checkSmtp(acc, pw)
      if r.len > 0: return "The outgoing server (" & s.smtpHost & "): " & r
    of akJmap: discard jmapOf(acc, pw).mailboxes()
    of akEws:
      let c = ewsOf(acc, pw)
      c.close()
    else: discard
  except CatchableError as e:
    return (case acc.kind
            of akPop: "The incoming server (" & otherJson(acc){"pop"}{"host"}.getStr & "): "
            of akJmap: "The JMAP server: "
            else: "The Exchange server: ") & e.msg
  ""

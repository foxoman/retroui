## Retro Mail's IMAP accounts: any provider's mail through IMAP (reading,
## folders, flags, moves) and SMTP (sending), with a password -- what the
## sync thread does for them (examples/mail/sync.nim calls it), and the
## account's servers as kept in the store (`Account.server`, JSON).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[json, strutils, times, sets, sequtils]
import retroui/[db, imap, smtp, netconn, mime, secrets]
import api, store

type
  ImapServers* = object
    imapHost*, smtpHost*, imapUser*, smtpUser*: string
    imapPort*, smtpPort*: int
    imapSec*, smtpSec*: Security
    insecure*: bool               ## a certificate of its own taken (a home server)

proc parseSecurity*(s: string): Security =
  case s.toLowerAscii
  of "starttls": secStartTls
  of "none", "plain": secNone
  else: secTls

proc serversOf*(acc: Account): ImapServers =
  ## The account's IMAP and SMTP servers.
  let j = try: parseJson(acc.server) except CatchableError: newJObject()
  let i = j{"imap"}
  let s = j{"smtp"}
  result.imapHost = i{"host"}.getStr
  result.imapPort = i{"port"}.getInt(993)
  result.imapSec = parseSecurity(i{"security"}.getStr("tls"))
  result.imapUser = i{"user"}.getStr(acc.email)
  result.smtpHost = s{"host"}.getStr(result.imapHost)
  result.smtpPort = s{"port"}.getInt(465)
  result.smtpSec = parseSecurity(s{"security"}.getStr("tls"))
  result.smtpUser = s{"user"}.getStr(result.imapUser)
  result.insecure = j{"insecure"}.getBool

proc serverJson*(s: ImapServers): string =
  ## (as `Account.server` keeps them)
  $(%*{"imap": {"host": s.imapHost, "port": s.imapPort, "security": $s.imapSec, "user": s.imapUser},
       "smtp": {"host": s.smtpHost, "port": s.smtpPort, "security": $s.smtpSec, "user": s.smtpUser},
       "insecure": s.insecure})

proc imapRemote*(folderRaw: string; uid: int64): string = folderRaw & "\n" & $uid
  ## (a message's id in the store: its folder's name and its UID there)

proc splitRemote*(remote: string): tuple[folder: string; uid: int64] =
  let k = remote.rfind('\n')
  if k < 0: return ("", 0)
  (remote[0 ..< k], (try: parseBiggestInt(remote[k + 1 .. ^1]) except ValueError: 0'i64))

const labelNames = [("$label1", "Important"), ("$label2", "Work"), ("$label3", "Personal"),
                    ("$label4", "To Do"), ("$label5", "Later")]
  ## (Thunderbird's own five tags)

proc tagOfKeyword*(k: string): string =
  for (a, b) in labelNames:
    if a == k.toLowerAscii: return b
  k

proc keywordOf*(tag: string): string =
  ## A tag as an IMAP keyword (an atom: no spaces, no ( ) { " \ % * ]).
  for c in tag:
    if c in {' ', '(', ')', '{', '"', '\\', '%', '*', ']', '['} or ord(c) < 0x20 or ord(c) >= 0x7F:
      result.add '_'
    else: result.add c

proc keywordsOf*(tag: string): seq[string] =
  ## The keywords a tag may be on the server: its own, and Thunderbird's
  ## for its five ("$label2" for Work).
  result.add keywordOf(tag)
  for (a, b) in labelNames:
    if b == tag: result.add a

proc systemKeyword(k: string): bool =
  ## (the server's and other programs' own markers, not tags)
  let l = k.toLowerAscii
  l.startsWith("\\") or (l.startsWith("$") and not l.startsWith("$label")) or
    l in ["nonjunk", "junk", "notjunk", "forwarded", "redirected"]

proc msgOfImap*(acc: Account; f: Folder; im: ImapMessage): Msg =
  ## A message as the store keeps it, from its header fields and flags.
  let h = parseMime(im.header & "\r\n")
  result = Msg(account: acc.id, folder: f.id, remoteId: imapRemote(f.remoteId, im.uid))
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
                  elif result.msgId.len > 0: result.msgId else: result.remoteId
  result.date = parseMailDate(h.header("Date"))
  if result.date <= 0 or result.date > epochTime() + 2 * 86400 or im.date > 0 and
     abs(result.date - im.date) > 30 * 86400:
    result.date = im.date              # (no date, or a wrong one: when the server got it)
  result.size = im.size
  result.unread = "\\seen" notin im.flags.mapIt(it.toLowerAscii)
  for fl in im.flags:
    let l = fl.toLowerAscii
    if l == "\\flagged": result.flagged = true
    elif l == "\\draft": result.draft = true
    elif not systemKeyword(fl): result.tags.add tagOfKeyword(fl)
  if f.role == "drafts": result.draft = true
  let ct = h.header("Content-Type").toLowerAscii
  result.hasAtt = ct.startsWith("multipart/mixed")
  let imp = h.header("Importance").strip.toLowerAscii
  let prio = h.header("X-Priority").strip
  result.important = imp == "high" or prio.startsWith("1") or prio.startsWith("2")
  result.focused = true
  result.mine = acc.email.len > 0 and result.fromEmail.toLowerAscii == acc.email.toLowerAscii
  result.labels = im.flags.join(" ")

proc storeImapBody*(db: Db; id: int; raw: string;
                    textToHtml: proc (text: string): string {.nimcall, gcsafe.}) =
  ## A message's whole source, fetched: its body (`textToHtml` makes a plain
  ## one HTML, as the window shows it), its attachments, the headers the
  ## list did not have, a few words for the list.
  let root = parseMime(raw)
  let (html0, text) = bodies(root)
  let html = if html0.len > 0: html0 else: textToHtml(text)
  let atts = attachments(root)
  var snip = ""
  let plain = if text.len > 0: text else: html
  var inTag = false
  for c in plain:
    if c == '<': inTag = true
    elif c == '>': inTag = false
    elif not inTag:
      snip.add(if c in {'\r', '\n', '\t'}: ' ' else: c)
      if snip.len > 400: break
  db.transaction:
    db.setBody(id, html, text)
    db.exec("UPDATE messages SET snippet = ?, size = ? WHERE id = ?",
            snip.splitWhitespace().join(" "), raw.len, id)
    db.setDetails(id, root.decodedHeader("To"), root.decodedHeader("Cc"),
                  root.header("Message-ID").strip, root.header("In-Reply-To").strip,
                  root.header("References").strip)
    let unsub = root.header("List-Unsubscribe").strip
    if unsub.len > 0: db.setUnsub(id, unsub, root.header("List-Unsubscribe-Post").strip)
    var any = false
    for i, a in atts:
      # (an attachment already listed keeps its id: the window may be waiting for it)
      let old = db.value("SELECT id FROM atts WHERE message = ? AND remote_id = ?", id, "a" & $i)
      if old.isNull:
        discard db.addAttachment(id, "a" & $i, a.filename, a.contentType, a.data.len, a.contentId,
                                 a.inline, a.data, true)
      else: db.setAttachmentData(int old.num, a.data)
      if not a.inline: any = true
    db.exec("UPDATE messages SET has_att = ? WHERE id = ?", any, id)

proc folderTree*(fs: seq[ImapFolder]): seq[tuple[raw, name, role, parent: string; selectable: bool]] =
  ## The server's folders as the store's: each with its own name (the last
  ## part) and its parent's raw name.
  var raws = initHashSet[string]()
  for f in fs: raws.incl f.raw
  for f in fs:
    var name = f.name
    var parent = ""
    if f.delimiter != '\0' and f.role != "inbox":
      let k = f.raw.rfind(f.delimiter)
      if k > 0 and f.raw[0 ..< k] in raws:
        parent = f.raw[0 ..< k]
        let kn = f.name.rfind(f.delimiter)
        if kn >= 0: name = f.name[kn + 1 .. ^1]
    let noSel = f.flags.anyIt(it.toLowerAscii in ["\\noselect", "\\nonexistent"])
    result.add (f.raw, name, f.role, parent, not noSel and f.role notin ["all", "flagged"])

proc imapError*(e: ref CatchableError): ref ApiError =
  ## IMAP's and SMTP's errors as the sync thread treats the services': 0
  ## (no connection: tried again later), 401 (the password), 503 (for now),
  ## 400 (for good).
  result = newException(ApiError, e.msg)
  if e of ref NetError: result.status = 0
  elif e of ref SmtpError:
    let c = (ref SmtpError)(e).code
    result.status = if c == 535 or c == 534 or c == 530: 401
                    elif c >= 400 and c < 500: 503
                    elif c == 0: 0
                    else: 400
  elif e of ref ImapError:
    let m = e.msg.toUpperAscii
    result.status = if "[AUTHENTICATIONFAILED]" in m or "[AUTHORIZATIONFAILED]" in m or
                       "INVALID CREDENTIALS" in m or "LOGIN FAILED" in m: 401
                    elif "[UNAVAILABLE]" in m or "[INUSE]" in m or "[LIMIT]" in m: 503
                    else: 400
  else: result.status = 400

proc savesSentItself*(s: ImapServers): bool =
  ## The service puts what its SMTP sent into Sent by itself (Gmail,
  ## Microsoft 365, Outlook.com): no copy is appended.
  let h = s.smtpHost.toLowerAscii
  h.endsWith("gmail.com") or h.endsWith("googlemail.com") or h.endsWith("office365.com") or
    h.endsWith("outlook.com")

# ---- one call on a connection of its own (the window's threads, the invitations) ----------------

proc imapPassword*(acc: Account): string =
  ## The account's password, as kept (encrypted) with its sign-in.
  try: parseJson(loadSecret("RetroMail", "acct-" & $acc.id)){"password"}.getStr
  except CatchableError: ""

proc imapRaw*(acc: Account; pw, remoteId: string): string =
  ## A message's whole source, on a connection made for it. Raises ApiError.
  let s = serversOf(acc)
  let (folder, uid) = splitRemote(remoteId)
  var c: ImapClient
  try:
    c = imapConnect(s.imapHost, s.imapPort, s.imapSec, timeoutSec = 60, insecure = s.insecure)
    c.login(s.imapUser, pw)
    discard c.select(folder, readOnly = true)
    result = c.fetchMessage(uid)
    c.logout()
  except CatchableError as e:
    if c != nil: c.close()
    raise imapError(e)

proc smtpSendRaw*(acc: Account; pw: string; rcpts: openArray[string]; raw: string): string =
  ## Sends a whole message through the account's SMTP server; "" when it
  ## went to all, else which were refused (it went to the others). Raises
  ## ApiError when it did not go.
  let s = serversOf(acc)
  var sc: SmtpClient
  try:
    sc = smtpConnect(s.smtpHost, s.smtpPort, s.smtpSec, timeoutSec = 120, insecure = s.insecure)
    sc.login(s.smtpUser, pw)
    sc.sendMail(acc.email, rcpts, raw)
    sc.quit()
  except SmtpError as e:
    if sc != nil: sc.quit()
    if e.code == 250: return e.msg
    raise imapError(e)
  except CatchableError as e:
    if sc != nil: sc.quit()
    raise imapError(e)

proc appendSent*(acc: Account; pw, raw: string) =
  ## A copy of what was sent into Sent (unless the service keeps one itself).
  let s = serversOf(acc)
  if savesSentItself(s): return
  var c: ImapClient
  try:
    c = imapConnect(s.imapHost, s.imapPort, s.imapSec, timeoutSec = 60, insecure = s.insecure)
    c.login(s.imapUser, pw)
    for f in c.listFolders():
      if f.role == "sent":
        discard c.append(f.raw, raw, ["\\Seen"])
        break
    c.logout()
  except CatchableError as e:
    if c != nil: c.close()
    raise imapError(e)

proc calendarPart*(raw: string): string =
  ## The invitation a message carries (its text/calendar part, or an .ics
  ## file): "" when none.
  var best = ""
  var bestRank = 0
  proc walk(p: MimePart; best: var string; bestRank: var int) =
    if p.contentType.startsWith("multipart/"):
      for c in p.parts: walk(c, best, bestRank)
      return
    var hasMethod = false
    for (k, v) in p.params:
      if k == "method": hasMethod = true
    let rank = if p.contentType == "text/calendar" and hasMethod: 3
               elif p.contentType == "text/calendar": 2
               elif p.contentType == "application/ics" or p.filename.toLowerAscii.endsWith(".ics"): 1
               else: 0
    if rank > bestRank:
      best = p.body
      bestRank = rank
  walk(parseMime(raw), best, bestRank)
  best

proc checkImapAccount*(acc: Account; pw: string): string =
  ## Signs in to the IMAP and the SMTP server once: "" when both took the
  ## password, else what went wrong (for the Add Account Wizard).
  let s = serversOf(acc)
  if s.imapHost.len == 0: return "No incoming (IMAP) server."
  if s.smtpHost.len == 0: return "No outgoing (SMTP) server."
  var c: ImapClient
  try:
    c = imapConnect(s.imapHost, s.imapPort, s.imapSec, timeoutSec = 30, insecure = s.insecure)
    c.login(s.imapUser, pw)
    discard c.listFolders()
    c.logout()
  except CatchableError as e:
    if c != nil: c.close()
    return "The incoming server (" & s.imapHost & "): " & e.msg
  var sc: SmtpClient
  try:
    sc = smtpConnect(s.smtpHost, s.smtpPort, s.smtpSec, timeoutSec = 30, insecure = s.insecure)
    sc.login(s.smtpUser, pw)
    sc.quit()
  except CatchableError as e:
    if sc != nil: sc.quit()
    return "The outgoing server (" & s.smtpHost & "): " & e.msg
  ""

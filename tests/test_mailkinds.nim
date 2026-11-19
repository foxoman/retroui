## Mail accounts beyond IMAP: POP3 (retroui/pop3), JMAP (retroui/jmap)
## and Exchange's EWS (retroui/ews, signed in with NTLM: retroui/ntlm),
## against servers of the test's own (tests/protomock.py); then Retro
## Mail with an account of each: the first sync, a body, changes made
## here reaching the server, sending, new mail, a server search.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, osproc, strutils, json, times, exitprocs, streams, tables]
import retroui/[pop3, jmap, ews, ntlm, http, mime, netconn, secrets, db]
import ../examples/mail/[store, sync, othersync, searchquery]

let home = getTempDir() / "retro-mailkinds-" & $getCurrentProcessId()
removeDir(home)
createDir(home)
putEnv("RETRO_MAIL_HOME", home)
putEnv("RETRO_SECRETS_DIR", home / "secrets")

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

let python = if findExe("python3").len > 0: "python3" else: "python"
let mock = startProcess(python, args = [currentSourcePath().parentDir / "protomock.py"], options = {poUsePath})
proc stopAtExit(p: Process) =
  # (the exit proc keeps its own reference: the program's globals, `mock`
  # too, are freed before the exit procs run)
  addExitProc(proc () = p.terminate())
stopAtExit(mock)
let ports = mock.outputStream.readLine.splitWhitespace
let popPort = parseInt(ports[0])
let jmapUrl = "http://127.0.0.1:" & ports[1]
let ewsUrl = "http://127.0.0.1:" & ports[2] & "/EWS/Exchange.asmx"

proc state(url: string): JsonNode = parseJson(httpRequest("GET", url & "/admin/state").body)

echo "NTLM's pieces (MS-NLMP's own example)"
proc hex(s: string): string =
  for c in s: result.add toHex(ord(c), 2).toLowerAscii
proc unhex(s: string): string =
  var i = 0
  while i < s.len:
    result.add char(parseHexInt(s[i .. i + 1]))
    i += 2
check hex(md4("abc")) == "a448017aaf21d8525fc10ae87aa6729d", "MD4"
check hex(md5("abc")) == "900150983cd24fb0d6963f7d28e17f72", "MD5"
check hex(hmacMd5("key", "The quick brown fox jumps over the lazy dog")) == "80070713463e7749b90c2dc24911e275",
      "HMAC-MD5"
check hex(ntowfv2("User", "Domain", "Password")) == "0c868a403bfd7a93a3001ef22ef02e3f", "NTOWFv2"
let r = ntlmv2Response("User", "Domain", "Password", unhex("0123456789abcdef"), unhex("aaaaaaaaaaaaaaaa"),
                       unhex("02000c0044006f006d00610069006e0001000c0053006500720076006500720000000000"), 0)
check hex(r.nt[0 ..< 16]) == "68cd0ab851e51c96aabc927bebef6a1c", "the NTLMv2 proof"
check hex(r.lm) == "86c35097ac9cec102554764a57cccc19aaaaaaaaaaaaaaaa", "the LMv2 answer"

echo "POP3"
block:
  var refused = ""
  try:
    let bad = pop3Connect("127.0.0.1", popPort, secNone)
    bad.login("me@example.test", "wrong")
  except Pop3Error as e: refused = e.msg
  check "wrong" in refused, "a wrong password, with the server's words: " & refused
  let c = pop3Connect("127.0.0.1", popPort, secNone)
  c.login("me@example.test", "secret")
  check c.has("UIDL") and c.has("TOP"), "what it can (CAPA)"
  check c.stat().count == 3, "three messages wait"
  let ids = c.uidl()
  check ids.len == 3 and ids[1].uid == "u1", "their lasting ids (UIDL)"
  check "Subject: Hello from POP" in c.top(2) and "Salam!" notin c.top(2), "a header alone (TOP)"
  let whole = c.retr(2)
  check parseMime(whole).decodedHeader("Subject") == "Hello from POP" and "Salam!" in whole, "a whole message"
  c.dele(2)
  c.rset()
  c.quit()
  let c2 = pop3Connect("127.0.0.1", popPort, secNone)
  c2.login("me@example.test", "secret")
  check c2.stat().count == 3, "RSET took the deletion back"
  c2.quit()

echo "JMAP"
block:
  var refused = 0
  try: discard jmapConnect(jmapUrl, jmapBearer("wrong"))
  except JmapError as e: refused = e.status
  check refused == 401, "a wrong token is refused"
  let s = jmapConnect(jmapUrl, jmapBearer("token-123"))
  check s.account == "A1" and s.apiUrl.startsWith("http://127.0.0.1"), "the session (.well-known/jmap)"
  let boxes = s.mailboxes()
  var inbox = ""
  for b in boxes:
    if b.role == "inbox": inbox = b.id
  check boxes.len == 4 and inbox == "mb-in", "the mailboxes and what they are for"
  let q = s.queryEmails(%*{"inMailbox": inbox})
  check q.ids == @["e2", "e1"], "the Inbox's messages, newest first: " & $q.ids
  let es = s.getEmails(q.ids)
  check es.len == 2 and es[1]{"subject"}.getStr == "JMAP hello" and es[1]{"keywords"}{"$flagged"}.getBool,
        "their fields"
  let st0 = s.emailState()
  let raw = s.download(es[1]{"blobId"}.getStr)
  check "Hello over JMAP." in raw, "a message's source (download)"
  s.setKeyword("e1", "$seen", true)
  s.setMailboxes("e1", ["mb-work"])
  let ch = s.emailChanges(st0)
  check ch.updated == @["e1"] and ch.created.len == 0, "what changed since (Email/changes)"
  s.sendRaw(buildMail(OutMail(fromAddr: MailAddress(name: "Me", email: "me@example.test"),
                              to: @[MailAddress(email: "sara@example.test")], subject: "Over JMAP",
                              text: "Hi")), "me@example.test", @["sara@example.test"], "mb-sent")
  let jst = state(jmapUrl)
  check jst["sent"].len == 1 and jst["sent"][0]["subject"].getStr == "Over JMAP" and
        jst["sent"][0]["rcpt"][0].getStr == "sara@example.test", "sent (uploaded, imported, submitted)"
  check s.queryEmails(%*{"text": "plan"}).ids.len == 0 and s.queryEmails(%*{"text": "work"}).ids.len == 1,
        "a search on the server"

echo "Exchange (EWS), signed in with NTLM"
block:
  var refused = 0
  try: discard ewsConnect(ewsUrl, "EXAMPLE\\me", "wrong")
  except EwsError as e: refused = e.status
  check refused == 401, "a wrong password is refused"
  let c = ewsConnect(ewsUrl, "EXAMPLE\\me", "secret")
  let fs = c.folders()
  var inbox, proj = ""
  for f in fs:
    if f.role == "inbox": inbox = f.id
    if f.name == "Projects": proj = f.parentId
  check fs.len == 6 and inbox == "f-in" and proj == "f-in", "the folders, what they are for, which is in which"
  let ch = c.syncItems(inbox, "")
  check ch.changed.len == 2 and ch.done and ch.state.len > 0, "the Inbox, the first time (SyncFolderItems)"
  let items = c.getItems(ch.changed)
  check items.len == 2 and items[0].subject == "Exchange hello" and items[0].flagged and not items[0].read and
        items[0].fromEmail == "nasser@example.test" and items[0].received > 0, "their fields (GetItem)"
  check "From the Exchange." in c.mimeOf("i1"), "a message's source (MIME)"
  c.setRead("i1", true)
  c.setFlag("i1", false)
  c.setCategories("i1", ["Retro", "Blue"])
  let ch2 = c.syncItems(inbox, ch.state)
  check ch2.readChanged.len == 1 and ch2.readChanged[0].read and ch2.changed.len >= 1, "what changed since"
  let moved = c.moveItems(["i2"], "deleteditems")
  check moved.len == 1 and moved[0].len > 0, "moved to Deleted Items"
  c.sendMime(buildMail(OutMail(fromAddr: MailAddress(email: "me@example.test"),
                               to: @[MailAddress(email: "omar@example.test")], subject: "Over EWS", text: "Hi")))
  let est = state(ewsUrl[0 ..< ewsUrl.find("/EWS")])
  check est["sent"].len == 1 and est["sent"][0]["subject"].getStr == "Over EWS", "sent, a copy in Sent Items"
  check c.findItems("inbox", "exchange").len == 1, "a search on the server (QueryString)"
  check est["items"]["i1"]["categories"].len == 2, "categories set"
  c.close()

echo "Retro Mail with a POP3, a JMAP and an Exchange account"
let store0 = openStore()
let smtpFake = %*{"host": "127.0.0.1", "port": 1, "security": "none", "user": "me@example.test"}
let popId = store0.addAccount(akPop, "me@example.test", "Me", "pop3", "", 30,
  server = $(%*{"pop": {"host": "127.0.0.1", "port": popPort, "security": "none", "user": "me@example.test"},
                "smtp": smtpFake, "leave": true, "deleteWithLocal": true}))
let jmId = store0.addAccount(akJmap, "me@example.test", "Me", "jmap", "", 30,
  server = $(%*{"jmap": {"url": jmapUrl, "auth": "bearer"}}))
let ewId = store0.addAccount(akEws, "me@example.test", "Me", "ews", "", 30,
  server = $(%*{"ews": {"url": ewsUrl, "user": "EXAMPLE\\me"}}))
for (id, pw) in [(popId, "secret"), (jmId, "token-123"), (ewId, "secret")]:
  discard saveSecret(secretApp, tokenKey(id), $(%*{"password": pw}))
check checkOtherAccount(store0.account(jmId), "token-123") == "" and
      checkOtherAccount(store0.account(ewId), "secret") == "" and
      "wrong" in checkOtherAccount(store0.account(popId), "nope"), "the wizard's check"
discard syncOnce(mailDir() / "mail.db")
for (id, name) in [(popId, "POP3"), (jmId, "JMAP"), (ewId, "Exchange")]:
  let a = store0.account(id)
  check a.state == "", name & ": synced (" & a.state & ")"
proc subjects(acc: int; role: string): seq[string] =
  let f = store0.folderByRole(acc, role)
  for m in store0.folderMessages(f.id): result.add m.subject
let popIn = subjects(popId, "inbox")
check popIn.len == 2 and "Hello from POP" in popIn and store0.folderByRole(popId, "sent").id > 0 and
      store0.folderByRole(popId, "trash").id > 0,
      "POP3: the Inbox of the days kept (one of long ago left, by its header), and folders kept here: " & $popIn
let pm = store0.messageByRemote(popId, "pop:u1")
check pm.bodyState == 2 and "Salam!" in store0.message(pm.id).text, "POP3: the body came with it"
let jmIn = subjects(jmId, "inbox")
check jmIn == @["Read already"], "JMAP: the Inbox: " & $jmIn
let jm = store0.messageByRemote(jmId, "e1")
check jm.id > 0 and jm.flagged and store0.folder(jm.folder).name == "Work",
      "JMAP: one moved to Work (above), flagged"
let ewIn = subjects(ewId, "inbox")
check "Exchange hello" in ewIn, "Exchange: the Inbox: " & $ewIn
check store0.folders(ewId).len == 6, "Exchange: its folders"
# bodies, through the sync thread's own way
var link: SyncLink
link.cmds.open()
link.events.open()
link.dbPath = mailDir() / "mail.db"
var th: Thread[ptr SyncLink]
createThread(th, syncMain, addr link)
link.cmds.send(SyncCmd(kind: scSettings, count: 60))
let em = store0.messageByRemote(ewId, store0.folderMessages(store0.folderByRole(ewId, "inbox").id)[0].remoteId)
let jmsg = store0.messageByRemote(jmId, "e2")
link.cmds.send(SyncCmd(kind: scBody, id: em.id))
link.cmds.send(SyncCmd(kind: scBody, id: jmsg.id))
let t0 = epochTime()
while epochTime() - t0 < 15:
  if store0.message(em.id).bodyState == 2 and store0.message(jmsg.id).bodyState == 2: break
  sleep(100)
check store0.message(em.id).bodyState == 2 and store0.message(em.id).text.len > 0, "Exchange: a body (MIME)"
check "Old news." in store0.message(jmsg.id).text, "JMAP: a body (its source downloaded)"
link.cmds.send(SyncCmd(kind: scQuit))
joinThread(th)
# changes made here
let ewHello = block:
  var x = Msg()
  for m in store0.folderMessages(store0.folderByRole(ewId, "inbox").id):
    if m.subject == "Exchange hello": x = m
  x
discard store0.queueAction(ewId, "read", %*{"id": ewHello.id, "unread": false})
discard store0.queueAction(ewId, "flag", %*{"id": ewHello.id, "flagged": false})
discard store0.queueAction(jmId, "read", %*{"id": store0.messageByRemote(jmId, "e1").id, "unread": false})
discard store0.queueAction(jmId, "send", %*{"mode": "new", "to": [{"name": "Sara", "email": "sara@example.test"}],
  "cc": [], "bcc": [{"name": "", "email": "secret@example.test"}], "subject": "From Retro Mail over JMAP",
  "text": "Hi", "html": "<p>Hi</p>", "attachments": []})
discard store0.queueAction(ewId, "send", %*{"mode": "new", "to": [{"name": "Omar", "email": "omar@example.test"}],
  "cc": [], "bcc": [], "subject": "From Retro Mail over EWS", "text": "Hi", "html": "<p>Hi</p>", "attachments": []})
let trash = store0.folderByRole(ewId, "trash")
let plan = block:
  var x = Msg()
  for f in store0.folders(ewId):
    for m in store0.folderMessages(f.id):
      if m.subject == "Plan": x = m
  x
discard store0.queueAction(ewId, "move", %*{"id": plan.id, "folder": trash.id})
discard syncOnce(mailDir() / "mail.db")
let est = state(ewsUrl[0 ..< ewsUrl.find("/EWS")])
var inDel, readFl = false
for k, v in est["items"].pairs:
  if v["subject"].getStr == "Exchange hello": readFl = v["read"].getBool and not v["flagged"].getBool
  if v["subject"].getStr == "Plan": inDel = v["folder"].getStr == "f-del"
check readFl, "Exchange: read and unflagged on the server"
check plan.id > 0 and inDel and store0.message(plan.id).folder == trash.id, "Exchange: moved to Deleted Items"
var sentE = false
for x in est["sent"].getElems:
  if x["subject"].getStr == "From Retro Mail over EWS": sentE = true
check sentE, "Exchange: sent"
let jst2 = state(jmapUrl)
var sentJ = false
for x in jst2["sent"].getElems:
  if x["subject"].getStr == "From Retro Mail over JMAP" and "secret@example.test" in $x["rcpt"]: sentJ = true
check sentJ, "JMAP: sent (to the Bcc too)"
check jst2["emails"]["e1"]["keywords"].hasKey("$seen"), "JMAP: read on the server"
# new mail
discard httpRequest("GET", jmapUrl & "/admin/newmail")
discard httpRequest("GET", ewsUrl[0 ..< ewsUrl.find("/EWS")] & "/admin/newmail")
block:
  let s = netOpen("127.0.0.1", popPort)
  discard s.readLine()
  s.write("ADMIN NEWMAIL\r\nQUIT\r\n")
  discard s.readLine()
  s.close()
let r2 = syncOnce(mailDir() / "mail.db")
check "POP news" in subjects(popId, "inbox") and "JMAP news" in subjects(jmId, "inbox") and
      "EWS news" in subjects(ewId, "inbox"), "new mail on all three: " & $subjects(popId, "inbox") & $subjects(jmId, "inbox") & $subjects(ewId, "inbox")
check r2.count == 3, "told as new: " & $r2

# a POP3 message deleted here: on the server too
let popTrash = store0.folderByRole(popId, "trash")
let pm1 = store0.messageByRemote(popId, "pop:u1")
store0.moveLocal(pm1.id, popTrash.id)
discard store0.queueAction(popId, "move", %*{"id": pm1.id, "folder": popTrash.id})
discard syncOnce(mailDir() / "mail.db")
let pc = pop3Connect("127.0.0.1", popPort, secNone)
pc.login("me@example.test", "secret")
var stillThere = false
for (n, u) in pc.uidl():
  if u == "u1": stillThere = true
pc.quit()
check not stillThere and store0.messageByRemote(popId, "pop:u1").id == 0,
      "POP3: deleted from the Trash here, gone from the server"
check "POP news" in subjects(popId, "inbox") and subjects(popId, "inbox").len == 2,
      "and not downloaded again"

echo "a search said each server's way"
let sq = parseQuery("from:sara subject:report has:attachment is:unread invoice after:2026-11-01")
check imapCriteria(sq).startsWith("FROM \"sara\" SUBJECT \"report\" UNSEEN SINCE 1-Nov-2026") and
      imapCriteria(sq).endsWith("TEXT \"invoice\""), "IMAP: " & imapCriteria(sq)
check gmailQ(sq) == "from:sara subject:report has:attachment is:unread after:2026/11/01 invoice", "Gmail: " & gmailQ(sq)
check graphKql(sq) == "from:sara AND subject:report AND hasAttachments:true AND received>=2026-11-01 AND invoice",
      "Graph: " & graphKql(sq)
let jf = jmapFilter(sq)
check jf["from"].getStr == "sara" and jf["text"].getStr == "invoice" and jf["notKeyword"].getStr == "$seen" and
      jf["hasAttachment"].getBool, "JMAP: " & $jf
check ewsQuery(sq).startsWith("from:sara subject:report hasattachment:true isread:false"), "Exchange: " & ewsQuery(sq)
check imapCriteria(parseQuery("")) == "ALL" and parseQuery("tag:Work in:inbox hello").words == @["hello"],
      "nothing typed; this app's own operators left to it"
proc subjectsOf(ids: seq[int]): seq[string] =
  for id in ids: result.add store0.message(id).subject
let js = subjectsOf(jmapSearch(store0, store0.account(jmId), "token-123", jmapFilter(parseQuery("news"))))
check "JMAP news" in js and "Read already" in js, "JMAP: the server's search, kept here: " & $js
let es = subjectsOf(ewsSearch(store0, store0.account(ewId), "secret", ewsQuery(parseQuery("hello"))))
check "Exchange hello" in es, "Exchange: the server's search, kept here: " & $es

store0.close()
removeDir(home)
if failures > 0:
  echo failures, " failed"
  quit 1
echo "test_mailkinds: all passed"

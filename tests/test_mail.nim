## Retro Mail's engine against a stand-in for Microsoft Graph, the Gmail
## API and both sign-ins (tests/mailmock.py): signing in in the "browser",
## the first sync, bodies and pictures, changes made here reaching the
## server, sending (new, reply, big attachment), new mail, expired tokens.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, osproc, json, strutils, times, net, sequtils, exitprocs, tables]
import retroui/[db, http, oauth, secrets]
import ../examples/mail/[store, sync, sigfind]

proc freePort(): int =
  let s = newSocket()
  s.bindAddr(Port(0), "127.0.0.1")
  result = int s.getLocalAddr()[1]
  s.close()

let port = freePort()
let base = "http://127.0.0.1:" & $port
let home = getTempDir() / "retro-mail-test-" & $getCurrentProcessId()
removeDir(home)
createDir(home)
putEnv("RETRO_MAIL_HOME", home)
putEnv("RETRO_SECRETS_DIR", home / "secrets")
putEnv("RETRO_MAIL_GRAPH", base & "/v1.0")
putEnv("RETRO_MAIL_GMAIL", base)
putEnv("RETRO_MAIL_GCAL", base & "/calendar/v3")
putEnv("RETRO_MAIL_MSLOGIN", base & "/ms")
putEnv("RETRO_MAIL_GAUTH", base & "/g/auth")
putEnv("RETRO_MAIL_GTOKEN", base & "/g/token")

let mock = startProcess("python3", args = [currentSourcePath().parentDir / "mailmock.py", $port],
                        options = {poUsePath, poParentStreams})
proc stopAtExit(p: Process) =
  # (the exit proc keeps its own reference: the program's globals, `mock`
  # too, are freed before the exit procs run)
  addExitProc(proc () = p.terminate())
stopAtExit(mock)
for i in 0 .. 50:
  if httpRequest("GET", base & "/test/state").status == 200: break
  sleep(100)

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

proc mockState(): JsonNode =
  let r = httpRequest("GET", base & "/test/state", timeoutSec = 30)
  if r.status != 200: echo "    (mock state: ", r.status, " ", r.error, " ", r.body.substr(0, 200), ")"
  parseJson(r.body)

proc browser(url: string) {.gcsafe.} =
  ## The browser's part: the sign-in page sends it on to the loopback address.
  proc go(u: string) {.thread.} =
    let r = httpRequest("GET", u, followRedirects = false)
    let loc = r.header("location")
    if loc.len > 0: discard httpRequest("GET", loc)
  var t: Thread[string]
  createThread(t, go, url)
  joinThread(t)

proc signIn(acc: Account; secret = ""): OAuthTokens =
  let f = beginSignIn(providerFor(acc, secret), "", browser)
  let t0 = epochTime()
  while f.state == osWaiting and epochTime() - t0 < 20: sleep(50)
  if f.state != osDone: echo "    sign-in: ", f.error
  f.tokens

echo "sign in"
let store0 = openStore()
var ms = Account(kind: akGraph, clientId: "11111111-2222-3333-4444-555555555555", tenant: "organizations")
let mt = signIn(ms)
check mt.accessToken.len > 0 and mt.refreshToken.len > 0, "Microsoft: a token through the browser flow"
var gg = Account(kind: akGmail, clientId: "123-abc.apps.googleusercontent.example")
let gt = signIn(gg, "secret-xyz")
check gt.accessToken.len > 0, "Google: a token through the browser flow (with the client secret)"
check claims(gt){"email"}.getStr == "foxoman@gmail.example", "the id token's email"
ms.id = store0.addAccount(akGraph, "sultan@contoso.com", "Sultan Al Isaiee", ms.clientId, ms.tenant)
gg.id = store0.addAccount(akGmail, "foxoman@gmail.example", "Sultan", gg.clientId, "")
check saveSecret(secretApp, tokenKey(ms.id), $(%mt)), "token kept"
discard saveSecret(secretApp, tokenKey(gg.id), $(%gt))
discard saveSecret(secretApp, secretKey(gg.id), "secret-xyz")

var link: SyncLink
link.cmds.open()
link.events.open()
link.dbPath = mailDir() / "mail.db"
var th: Thread[ptr SyncLink]
createThread(th, syncMain, addr link)

proc waitFor(what: SyncEventKind; secs = 20.0; id = -1): SyncEvent =
  let t0 = epochTime()
  while epochTime() - t0 < secs:
    let (ok, ev) = link.events.tryRecv()
    if ok:
      if ev.kind == seError: echo "    (error) ", ev.text
      if ev.kind == what and (id < 0 or ev.id == id): return ev
    else: sleep(20)
  SyncEvent(kind: seStatus, text: "timeout")

proc count(sql: string; args: varargs[DbValue, toDbValue]): int = int store0.value(sql, @args).num

echo "first sync"
let t0 = epochTime()
while epochTime() - t0 < 30 and (count("SELECT count(*) FROM messages WHERE account = ?", gg.id) < 3 or
                                  count("SELECT count(*) FROM messages WHERE account = ?", ms.id) < 6 or
                                  count("SELECT count(*) FROM events") < 2):
  discard link.events.tryRecv()
  sleep(100)
echo "  (", formatFloat(epochTime() - t0, ffDecimal, 2), " s)"
check count("SELECT count(*) FROM messages WHERE account = ?", ms.id) == 6, "Graph: 6 messages (nextLink pages followed)"
check store0.folderByRole(ms.id, "inbox").id > 0 and store0.folderByRole(ms.id, "sent").id > 0, "Graph: well-known folders"
check store0.folderByRemote(ms.id, "f-proj-retro").name == "Retro", "Graph: a sub-folder"
check store0.tagOf(ms.id, "Finance").color.len > 0, "Graph: categories as tags with colors"
let m4 = store0.messageByRemote(ms.id, "m4")
check m4.tags == @["Finance"] and m4.hasAtt, "Graph: a message's tags and attachment mark"
check not store0.messageByRemote(ms.id, "m3").focused, "Graph: Focused / Other"
check store0.threadMessages(ms.id, "c1").len == 2, "Graph: a thread across Inbox and Sent Items"
check count("SELECT count(*) FROM messages WHERE account = ?", gg.id) == 3, "Gmail: 3 messages (batch metadata)"
let g3 = store0.messageByRemote(gg.id, "g3")
check g3.subject == "عرض خاص", "Gmail: an encoded-word subject decoded"
check g3.tags == @["Family"] and not g3.focused, "Gmail: user labels as tags, Promotions under Other"
check store0.folder(store0.messageByRemote(gg.id, "g2").folder).role == "sent", "Gmail: SENT as Sent Mail"
check store0.threadMessages(gg.id, "t1").len == 2, "Gmail: a thread"
check count("SELECT count(*) FROM events") >= 2, "both calendars read"
check store0.value("SELECT count(*) FROM mfts WHERE mfts MATCH ?", ftsQuery("Twelve", fold = true)).num == 1, "search index answers (snippets)"

echo "bodies"
let m3 = store0.messageByRemote(ms.id, "m3")
link.cmds.send(SyncCmd(kind: scBody, id: m3.id))
discard waitFor(seBody, id = m3.id)
let m3b = store0.message(m3.id)
check m3b.bodyState == 2 and "Retro Weekly" in m3b.html, "Graph: a body"
check store0.cidData(m3.id).hasKey("logo1"), "Graph: an inline picture kept by its Content-ID"
let g1 = store0.messageByRemote(gg.id, "g1")
link.cmds.send(SyncCmd(kind: scBody, id: g1.id))
discard waitFor(seBody, id = g1.id)
check "Jebel Shams" in store0.message(g1.id).html, "Gmail: a body (format=full)"
let atts = store0.attachments(g1.id)
check atts.len == 1 and atts[0].name == "shams.jpg", "Gmail: its attachment listed"
link.cmds.send(SyncCmd(kind: scAttachment, id: atts[0].id))
discard waitFor(seAttachment, id = atts[0].id)
check store0.attachmentData(atts[0].id).len == 4, "Gmail: an attachment downloaded"
check store0.value("SELECT count(*) FROM mfts WHERE mfts MATCH ?", ftsQuery("Jebel", fold = true)).num == 1, "a body is searchable"

echo "changes made here"
let m1 = store0.messageByRemote(ms.id, "m1")
discard store0.queueAction(ms.id, "read", %*{"id": m1.id, "unread": false})
discard store0.queueAction(ms.id, "flag", %*{"id": m1.id, "flagged": true})
discard store0.queueAction(ms.id, "tags", %*{"id": m1.id, "tags": ["Retro", "Waiting"], "removed": []})
store0.upsertTag(ms.id, "Waiting", "#ff8c00", "")
discard store0.queueAction(ms.id, "move", %*{"id": m4.id, "folder": store0.folderByRole(ms.id, "archive").id})
discard store0.queueAction(gg.id, "flag", %*{"id": g1.id, "flagged": true})
discard store0.queueAction(gg.id, "tags", %*{"id": g1.id, "tags": ["Family", "Trips"], "removed": []})
discard store0.queueAction(gg.id, "move", %*{"id": g3.id, "folder": store0.folderByRole(gg.id, "trash").id})
link.cmds.send(SyncCmd(kind: scWake))
let t1 = epochTime()
while store0.actionsWaiting() > 0 and epochTime() - t1 < 20: sleep(100)
check store0.actionsWaiting() == 0 and store0.failedActions().len == 0, "the queue went out"
for f in store0.failedActions(): echo "    ", f.kind, ": ", f.error
let st = mockState()
let gm1 = st["graph"]["messages"]["m1"]
check gm1["isRead"].getBool and gm1["flag"]["flagStatus"].getStr == "flagged", "Graph: read and flagged"
check gm1["categories"].getElems.mapIt(it.getStr) == @["Retro", "Waiting"], "Graph: categories set"
var cats: seq[string]
for c in st["graph"]["categories"]: cats.add c["displayName"].getStr
check "Waiting" in cats, "Graph: a new category made for a new tag"
check st["graph"]["messages"]{"m4"} == nil, "Graph: moved (a new id)"
let moved = store0.message(m4.id)
check moved.remoteId != "m4" and st["graph"]["messages"]{moved.remoteId}{"parentFolderId"}.getStr == "f-archive",
      "Graph: the new id kept here"
let gl = st["gmail"]["messages"]["g1"]["labelIds"].getElems.mapIt(it.getStr)
check "STARRED" in gl, "Gmail: starred"
var trips = ""
for l in st["gmail"]["labels"]:
  if l["name"].getStr == "Trips": trips = l["id"].getStr
check trips.len > 0 and trips in gl, "Gmail: a new label made and put on"
check "TRASH" in st["gmail"]["messages"]["g3"]["labelIds"].getElems.mapIt(it.getStr), "Gmail: trashed"

echo "sending"
let small = home / "note.txt"
writeFile(small, "hello")
let big = home / "big.bin"
writeFile(big, newString(4_500_000))
discard store0.queueAction(ms.id, "send", %*{"mode": "new", "to": [{"name": "Ahmed", "email": "ahmed@contoso.com"}],
  "cc": [], "bcc": [], "subject": "Test new", "html": "<p>Hi</p>", "text": "Hi",
  "attachments": [{"path": small, "name": "note.txt", "mime": "text/plain"},
                  {"path": big, "name": "big.bin", "mime": "application/octet-stream"}]})
discard store0.queueAction(ms.id, "send", %*{"mode": "reply", "replyTo": "m1",
  "to": [{"name": "Ahmed", "email": "ahmed@contoso.com"}], "cc": [], "bcc": [],
  "subject": "Re: Meeting about the Photo app", "html": "<p>Done</p>", "text": "Done", "attachments": []})
discard store0.queueAction(gg.id, "send", %*{"mode": "reply", "threadId": "t1", "inReplyTo": "<g1@mail.gmail.example>",
  "references": "<g1@mail.gmail.example>", "to": [{"name": "Khalid", "email": "khalid@example.om"}],
  "cc": [], "bcc": [], "subject": "Re: Photos from the weekend", "html": "<p>شكرا</p>", "text": "شكرا",
  "attachments": [{"path": small, "name": "note.txt", "mime": "text/plain"}]})
link.cmds.send(SyncCmd(kind: scWake))
let t2 = epochTime()
while store0.actionsWaiting() > 0 and epochTime() - t2 < 30: sleep(100)
for f in store0.failedActions(): echo "    ", f.kind, ": ", f.error
let st2 = mockState()
let sent = st2["graph"]["sent"].getElems
check sent.len == 2, "Graph: two messages sent"
if sent.len == 2:
  let names = sent[0]["attachments"].getElems.mapIt(it["name"].getStr)
  check "note.txt" in names and "big.bin" in names, "Graph: a small attachment and a 4.5 MB one (upload session)"
  check sent[1]{"_replyOf"}.getStr == "m1", "Graph: the reply made with createReply (threaded by the server)"
let gsent = st2["gmail"]["sent"].getElems
check gsent.len == 1 and gsent[0]["threadId"].getStr == "t1", "Gmail: sent in its thread"
if gsent.len == 1:
  check gsent[0]["in_reply_to"].getStr == "<g1@mail.gmail.example>", "Gmail: In-Reply-To set"
  check "note.txt" in gsent[0]["attachments"].getElems.mapIt(it.getStr), "Gmail: the attachment in the raw message"

echo "signatures from the web"
link.cmds.send(SyncCmd(kind: scSignatures, id: gg.id))
let gs = parseJson(waitFor(seSignature, id = gg.id).text)
check "www.foxoman.net" in gs{"new"}.getStr and "alias" notin gs{"new"}.getStr,
      "Gmail: the address's own signature from its settings"
link.cmds.send(SyncCmd(kind: scSignatures, id: ms.id))
let mss = parseJson(waitFor(seSignature, id = ms.id).text)
check "Retro Nim UI" in mss{"reply"}.getStr and "Ahmed" notin mss{"reply"}.getStr,
      "Outlook: the signature of a sent reply, not the quoted one"
check mss{"new"}.getStr == mss{"reply"}.getStr, "Outlook: one signature for both when only replies were sent"
check signatureIn("<p>Hi</p><div id=\"Signature\"><div><p>A</p></div><p>B</p></div><p>after</p>") ==
      "<div id=\"Signature\"><div><p>A</p></div><p>B</p></div>", "a nested signature element taken whole"
check signatureIn("<p>Hi</p><p class=MsoNormal><a name=\"_MailAutoSig\"></a>Sultan<br>Muscat</p>" &
                  "<div style=\"border:none;border-top:solid #E1E1E1 1.0pt\"><p>From: X</p></div>") ==
      "<p class=MsoNormal><a name=\"_MailAutoSig\"></a>Sultan<br>Muscat</p>", "Outlook for Windows' bookmark"
check signatureIn("<p>Hi</p><div id=\"ms-outlook-mobile-signature\">Get Outlook for Android</div>") == "",
      "Outlook mobile's advertisement is not a signature"
check signatureIn("<div id=\"Signature\"><img src=\"cid:logo@x\"><p>S</p></div>") ==
      "<div id=\"Signature\"><p>S</p></div>", "pictures kept inside the sent message dropped"
check isReply("RE: x", "") and isReply("رد: مرحبا", "") and not isReply("Hello", "<p>x</p>"), "replies told apart"

echo "newsletters: unsubscribe"
let (uh, up) = store0.unsubOf(m3.id)
check "/unsub/m3" in uh and "One-Click" in up, "Graph: List-Unsubscribe kept with the body"
link.cmds.send(SyncCmd(kind: scUnsubscribe, id: m3.id))
let ue = parseJson(waitFor(seUnsub, id = m3.id).text)
check ue{"how"}.getStr == "post", "one click: the list told by a POST"
check mockState(){"unsubs"}.getElems.anyIt(it{"body"}.getStr == "List-Unsubscribe=One-Click"),
      "the POST says List-Unsubscribe=One-Click (RFC 8058)"
link.cmds.send(SyncCmd(kind: scBody, id: g3.id))
discard waitFor(seBody, id = g3.id)
link.cmds.send(SyncCmd(kind: scUnsubscribe, id: g3.id))
let ge = parseJson(waitFor(seUnsub, id = g3.id).text)
check ge{"how"}.getStr == "mail" and ge{"url"}.getStr == "unsubscribe@shop.example",
      "Gmail: a list with only an address left by a message to it"
check count("SELECT count(*) FROM actions WHERE kind = 'send' AND data LIKE '%unsubscribe@shop.example%'") > 0 or
      "unsubscribe@shop.example" in $mockState()["gmail"]["sent"], "the message to the list's address goes out"

echo "a message's source (File, Properties)"
link.cmds.send(SyncCmd(kind: scRaw, id: m3.id, count: 2))
let src = waitFor(seRaw, id = m3.id).text
check fileExists(src) and "Subject:" in readFile(src), "the whole source, from the server, to read"

echo "changes made here stay until they reach the server"
let g1m = store0.message(g1.id)
let aid = store0.queueAction(gg.id, "tags", %*{"id": g1.id, "tags": ["Family"]}, due = epochTime() + 3600)
store0.setTags(g1.id, @["Family"])
var server = g1m
server.tags = @[]
discard store0.upsertMessage(server)
check store0.message(g1.id).tags == @["Family"], "a tag waiting to go out is not undone by the server's older view"
store0.doneAction(aid)
discard store0.upsertMessage(server)
check store0.message(g1.id).tags.len == 0, "the server's view counts again once nothing waits"

echo "new mail, expired tokens"
discard httpRequest("POST", base & "/test/expire")
discard httpRequest("POST", base & "/test/newmail")
link.cmds.send(SyncCmd(kind: scSyncNow))
let ev = waitFor(seNewMail, 30)
check ev.kind == seNewMail and ev.count >= 1, "new mail noticed (after refreshing an expired token)"
var refreshed = false
for l in mockState()["log"]:
  if l.getStr.endsWith("/token"): refreshed = true
check refreshed, "the refresh token was used"
let told = takeUnannounced()
check told.count >= 1 and told.latest.len > 0 and takeUnannounced().count == 0,
      "new mail is told once (the window, or a background check while it sleeps)"

echo "a check without the window (Android's background job)"
discard httpRequest("POST", base & "/test/newmail")
let once = syncOnce(home / "mail.db")
check once.count >= 1, "syncOnce: the new message fetched and counted"

link.cmds.send(SyncCmd(kind: scQuit))
joinThread(th)
store0.close()
removeDir(home)
if failures > 0:
  echo failures, " failed"
  quit 1
echo "all passed"

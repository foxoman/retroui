## IMAP and SMTP (retroui/imap, retroui/smtp, retroui/netconn) against a
## small server of their own (tests/imapmock.py): signing in, the folders
## and what they are for, searching, fetching, flags, moving, appending,
## sending -- plain, with STARTTLS and with TLS (a certificate made here,
## when openssl is there); where an address's servers are
## (retroui/mailsetup); and Retro Mail's engine with an IMAP account: the
## first sync, a body, changes made here reaching the server, sending
## (#2 on GitHub).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, osproc, json, strutils, times, net, exitprocs, tables]
import retroui/[imap, smtp, netconn, mailsetup, mime, secrets]
import ../examples/mail/[store, sync, imapsync]

proc freePort(): int =
  let s = newSocket()
  s.bindAddr(Port(0), "127.0.0.1")
  result = int s.getLocalAddr()[1]
  s.close()

let imapPort = freePort()
let smtpPort = freePort()
let tlsPort = freePort()
let home = getTempDir() / "retro-imap-test-" & $getCurrentProcessId()
removeDir(home)
createDir(home)
putEnv("RETRO_MAIL_HOME", home)
putEnv("RETRO_SECRETS_DIR", home / "secrets")

# a certificate of its own, for TLS (when openssl is there)
let cert = home / "cert.pem"
let key = home / "key.pem"
let haveTls = findExe("openssl").len > 0 and
  execCmd("openssl req -x509 -newkey rsa:2048 -nodes -keyout " & quoteShell(key) & " -out " &
          quoteShell(cert) & " -days 2 -subj /CN=localhost -addext subjectAltName=DNS:localhost" &
          " > /dev/null 2>&1") == 0
var args = @[currentSourcePath().parentDir / "imapmock.py", $imapPort, $smtpPort]
if haveTls: args.add [cert, key, $tlsPort]
let python = if findExe("python3").len > 0: "python3" else: "python"   # (Windows: python)
let mock = startProcess(python, args = args, options = {poUsePath, poParentStreams})
proc stopAtExit(p: Process) =
  addExitProc(proc () = p.terminate())
stopAtExit(mock)
for i in 0 .. 50:
  try:
    let s = newSocket()
    s.connect("127.0.0.1", Port(imapPort))
    s.close()
    break
  except OSError: sleep(100)

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

proc mockState(): JsonNode =
  ## (the server's state: its own ADMIN command)
  let c = imapConnect("127.0.0.1", imapPort, secNone)
  let a = c.command("ADMIN STATE")
  c.logout()
  parseJson(a[0]["ADMIN ".len .. ^1])

echo "folder names"
check decodeFolderName("Entw&APw-rfe") == "Entwürfe", "modified UTF-7 read"
check encodeFolderName("Entwürfe") == "Entw&APw-rfe", "and written"
check decodeFolderName(encodeFolderName("الوارد & المرسل")) == "الوارد & المرسل", "Arabic, and an &"
check uidSet([1'i64, 2, 3, 7, 9, 10]) == "1:3,7,9:10", "a UID set"
check abs(parseInternalDate("17-Jul-1996 02:44:25 -0700") - 837596665.0) < 1, "INTERNALDATE"

echo "signing in"
var c = imapConnect("127.0.0.1", imapPort, secNone)
check c.has("UIDPLUS") and c.has("MOVE"), "the greeting's capabilities"
try:
  c.login("me@example.test", "wrong")
  check false, "a wrong password is refused"
except ImapError as e:
  check "wrong" in e.msg, "a wrong password is refused, with the server's words: " & e.msg
c.login("me@example.test", "secret")
check true, "signed in"

echo "folders"
let fs = c.listFolders()
var roles = initTable[string, string]()
for f in fs: roles[f.name] = f.role
check fs[0].role == "inbox" and fs[0].name == "Inbox", "Inbox first"
check roles.getOrDefault("Sent") == "sent" and roles.getOrDefault("Trash") == "trash" and
      roles.getOrDefault("Junk") == "junk" and roles.getOrDefault("Archive") == "archive" and
      roles.getOrDefault("Drafts") == "drafts", "what each is for (special use)"
check roles.hasKey("Entwürfe") and roles.getOrDefault("Work") == "", "the others, names decoded"

echo "messages"
let box = c.select("INBOX")
check box.exists == 4 and box.uidValidity > 0 and box.uidNext == 5, "INBOX selected: " & $box
let all = c.uidSearch("ALL")
check all == @[1'i64, 2, 3, 4], "SEARCH ALL"
let recent = c.uidSearch("SINCE " & imapDate(epochTime() - 30 * 86400))
check recent == @[1'i64, 2, 3], "SEARCH SINCE: " & $recent
let hs = c.fetchHeaders(recent)
check hs.len == 3, "three headers"
var byUid = initTable[int64, ImapMessage]()
for m in hs: byUid[m.uid] = m
let h3 = parseMime(byUid[3].header)
check h3.decodedHeader("Subject") == "مرحبا", "a subject in UTF-8 words"
check "\\Flagged" in byUid[3].flags and "Work" in byUid[3].flags, "flags and keywords"
check "\\Seen" in byUid[2].flags and byUid[1].flags.len == 0, "read and unread"
check byUid[1].size > 100 and byUid[1].date > 0, "size and date"
let raw = c.fetchMessage(1)
check "Salam, how are you?" in raw, "a whole message"
c.addFlags([1'i64], ["\\Seen", "\\Flagged"])
c.removeFlags([1'i64], ["\\Flagged"])
let f1 = c.fetchFlags([1'i64])
check f1.len == 1 and "\\Seen" in f1[0].flags and "\\Flagged" notin f1[0].flags, "flags set and cleared"
let since = c.fetchFlags(all, changedSince = box.highestModSeq)
check since.len == 1 and since[0].uid == 1, "only what changed (CONDSTORE)"
let moved = c.move([4'i64], "Archive")
check moved.len == 1, "moved, its new UID told: " & $moved
check c.uidSearch("ALL") == @[1'i64, 2, 3], "gone from the Inbox"
let copied = c.copy([2'i64], "Work")
check copied.len == 1, "copied"
let appended = c.append("Sent", "From: me@example.test\r\nSubject: Kept\r\n\r\nA copy.\r\n", ["\\Seen"])
check appended > 0, "appended into Sent"
c.deleteForever([2'i64])
check c.uidSearch("ALL") == @[1'i64, 3], "deleted for good"
check c.uidSearch("TEXT \"marhaba\"") == @[3'i64], "SEARCH TEXT"
c.createFolder(encodeFolderName("Projects/Retro"))
check c.listFolders().len == fs.len + 1, "a folder made"
let st = c.status("Archive")
check st.messages == 1 and st.uidValidity > 0, "STATUS"
c.logout()

echo "sending"
let mail = "From: Me <me@example.test>\r\nTo: Ali <ali@example.test>\r\nSubject: Test\r\n\r\n" &
           "Line one\r\n.hidden dot\r\nend\n"     # (a line that starts with a dot; a bare LF)
check smtpSend("127.0.0.1", smtpPort, secNone, "me@example.test", "secret", "me@example.test",
               ["ali@example.test"], mail) == "", "sent"
var stt = mockState()
check stt["_sent"].len == 1 and ".hidden dot" in stt["_sent"][0].getStr and
      "RCPT ali@example.test" in stt["_sent"][0].getStr, "the server has it, its dot kept"
let partly = smtpSend("127.0.0.1", smtpPort, secNone, "me@example.test", "secret", "me@example.test",
                      ["ali@example.test", "ghost@nowhere.test"], mail)
check partly.startsWith("sent, but not to ghost@nowhere.test"), "one recipient refused: " & partly
let bad = smtpSend("127.0.0.1", smtpPort, secNone, "me@example.test", "nope", "me@example.test",
                   ["ali@example.test"], mail)
check "wrong" in bad, "a wrong password: " & bad

if haveTls:
  echo "TLS"
  # (the certificate is its own: insecure, or trusted through SSL_CERT_FILE on Linux)
  let t = imapConnect("localhost", tlsPort, secTls, insecure = true)
  t.login("me@example.test", "secret")
  check t.listFolders().len > 0, "IMAP over TLS"
  t.logout()
  let s = imapConnect("localhost", imapPort, secStartTls, insecure = true)
  s.login("me@example.test", "secret")
  check s.select("INBOX").exists == 2, "IMAP with STARTTLS"
  s.logout()
  check smtpSend("localhost", smtpPort, secStartTls, "me@example.test", "secret", "me@example.test",
                 ["ali@example.test"], mail, insecure = true) == "", "SMTP with STARTTLS"
  try:
    let n = imapConnect("localhost", tlsPort, secTls)
    n.close()
    check false, "a certificate nobody vouches for is refused"
  except NetError as e:
    check true, "a certificate nobody vouches for is refused: " & e.msg

echo "where the servers are"
let g = findMailServers("someone@gmail.com")
check g.found and g.imap.host == "imap.gmail.com" and g.smtp.port == 465, "Gmail, known"
let xml = """<?xml version="1.0"?>
<clientConfig version="1.1"><emailProvider id="example.test">
  <incomingServer type="pop3"><hostname>pop.example.test</hostname><port>995</port>
    <socketType>SSL</socketType><username>%EMAILADDRESS%</username></incomingServer>
  <incomingServer type="imap"><hostname>imap.example.test</hostname><port>143</port>
    <socketType>STARTTLS</socketType><username>%EMAILLOCALPART%</username>
    <authentication>password-cleartext</authentication></incomingServer>
  <incomingServer type="imap"><hostname>imap.example.test</hostname><port>993</port>
    <socketType>SSL</socketType><username>%EMAILLOCALPART%</username>
    <authentication>password-cleartext</authentication></incomingServer>
  <outgoingServer type="smtp"><hostname>smtp.example.test</hostname><port>587</port>
    <socketType>STARTTLS</socketType><username>%EMAILADDRESS%</username>
    <authentication>password-cleartext</authentication></outgoingServer>
</emailProvider></clientConfig>"""
let a = parseAutoconfig(xml, "sultan@example.test")
check a.found and a.imap.port == 993 and a.imap.security == secTls and a.imap.user == "sultan",
      "an autoconfig file: IMAP over TLS first, the user name filled"
check a.smtp.host == "smtp.example.test" and a.smtp.security == secStartTls and
      a.smtp.user == "sultan@example.test", "its SMTP"

echo "Retro Mail with an IMAP account"
let store0 = openStore()
let server = %*{"imap": {"host": "127.0.0.1", "port": imapPort, "security": "none", "user": "me@example.test"},
                "smtp": {"host": "127.0.0.1", "port": smtpPort, "security": "none", "user": "me@example.test"}}
# (the Add Account Wizard's check: both servers signed in to once)
let probe = Account(email: "me@example.test", server: $server)
check checkImapAccount(probe, "secret") == "", "the wizard's check: both servers take the password"
let refused = checkImapAccount(probe, "wrong")
check refused.startsWith("The incoming server (127.0.0.1):") and "wrong" in refused,
      "a wrong password, said for the server that refused it: " & refused
let accId = store0.addAccount(akImap, "me@example.test", "Me", "", "", 30, server = $server)
discard saveSecret(secretApp, tokenKey(accId), $(%*{"password": "secret"}))
let r1 = syncOnce(mailDir() / "mail.db")
check r1.count >= 0, "synced"
let inboxF = store0.folderByRole(accId, "inbox")
let ms = store0.folderMessages(inboxF.id)
check inboxF.id > 0 and ms.len == 2, "the Inbox's messages (within 30 days): " & $ms.len
check store0.folderByRole(accId, "sent").id > 0 and store0.folderByRole(accId, "trash").id > 0,
      "Sent and Trash"
var omar = Msg()
for m in ms:
  if m.fromEmail == "omar@example.test": omar = m
check omar.subject == "مرحبا" and omar.flagged and "Work" in omar.tags and omar.important,
      "a message: its subject, flag, keyword as a tag, importance"
check omar.unread, "unread (no \\Seen)"
# changes made here
discard store0.queueAction(accId, "read", %*{"id": omar.id, "unread": false})
discard store0.queueAction(accId, "flag", %*{"id": omar.id, "flagged": false})
discard store0.queueAction(accId, "tags", %*{"id": omar.id, "tags": ["Retro"], "removed": ["Work"]})
discard store0.queueAction(accId, "send", %*{"mode": "new", "to": [{"name": "Sara", "email": "sara@example.test"}],
                                            "subject": "From Retro Mail", "text": "Hello Sara", "html": "<p>Hello Sara</p>"})
discard syncOnce(mailDir() / "mail.db")
stt = mockState()
var srv3 = stt["INBOX"]["3"]
var fl: seq[string]
for f in srv3["flags"].getElems: fl.add f.getStr
check "\\Seen" in fl and "\\Flagged" notin fl, "read and unflagged on the server: " & $fl
check "Retro" in fl and "Work" notin fl, "the tags as keywords"
var sentHere = false
for s in stt["_sent"].getElems:
  if "From Retro Mail" in s.getStr and "RCPT sara@example.test" in s.getStr: sentHere = true
check sentHere, "sent through SMTP"
var inSent = false
for k, v in stt["Sent"].pairs:
  if v["subject"].getStr == "From Retro Mail": inSent = true
check inSent, "a copy in Sent"
# a body, then a move to Trash
discard store0.queueAction(accId, "move", %*{"id": omar.id, "folder": store0.folderByRole(accId, "trash").id})
discard syncOnce(mailDir() / "mail.db")
stt = mockState()
check not stt["INBOX"].hasKey("3"), "moved out of the Inbox"
var inTrash = false
for k, v in stt["Trash"].pairs:
  if v["subject"].getStr.contains("2YXYsdit2KjYpw") or v["subject"].getStr == "مرحبا": inTrash = true
check inTrash, "into the Trash"
# new mail
let ad = imapConnect("127.0.0.1", imapPort, secNone)
discard ad.command("ADMIN NEWMAIL")
ad.logout()
let r2 = syncOnce(mailDir() / "mail.db")
check r2.count == 1 and "Brand new" in r2.latest, "new mail told: " & $r2

removeDir(home)
if failures > 0:
  echo failures, " failed"
  quit(1)
echo "imap tests passed"

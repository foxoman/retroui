## Retro Mail's store, timed: what a mail program is felt by -- the store
## opened, a folder of 3,000 shown, a search over 50,000 messages (words and
## operators), headers stored as a sync brings them, a message's body read
## from its source -- encrypted (as it is by default) and not, with the
## memory it took.
##
##   nim c -d:release -d:useMalloc -r tools/mailbench.nim [messages]
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, times, monotimes, strutils, random, sysrand, json]
import retroui/[db, mime]
import ../examples/mail/[store, imapsync]

proc ms(t: Duration): string = formatFloat(t.inMicroseconds.float / 1000, ffDecimal, 1) & " ms"

proc rss(): string =
  try:
    for l in lines("/proc/self/status"):
      if l.startsWith("VmRSS:"): return l[6 .. ^1].strip
  except IOError: discard
  "?"

let n = if paramCount() > 0: parseInt(paramStr(1)) else: 50_000
let dir = getTempDir() / "retro-mailbench"
removeDir(dir)
createDir(dir)
putEnv("RETRO_SECRETS_DIR", dir / "secrets")
randomize(7)
const words = ["invoice", "meeting", "report", "project", "travel", "budget", "family", "photos",
               "contract", "review", "lunch", "school", "flight", "hotel", "دفعة", "اجتماع", "تقرير"]
proc sentence(k: int): string =
  for i in 0 ..< k:
    if i > 0: result.add ' '
    result.add words[rand(words.high)]

for encrypted in [true, false]:
  storeEncrypt = encrypted
  let path = dir / (if encrypted: "sealed.db" else: "plain.db")
  echo (if encrypted: "encrypted" else: "not encrypted"), ", ", n, " messages"
  var t0 = getMonoTime()
  var s = openStore(path)
  let acc = s.addAccount(akImap, "me@example.test", "Me", "", "", 90)
  let inbox = s.upsertFolder(acc, "INBOX", "Inbox", "inbox", "")
  let other = s.upsertFolder(acc, "Archive", "Archive", "archive", "")
  echo "  made:               ", ms(getMonoTime() - t0)
  t0 = getMonoTime()
  var i = 0
  while i < n:
    s.transaction:
      for k in 0 ..< 500:
        if i >= n: break
        var m = Msg(account: acc, folder: (if i mod 10 < 7: inbox else: other), remoteId: "r" & $i,
                    subject: sentence(4), fromName: "Person " & $(i mod 300),
                    fromEmail: "p" & $(i mod 300) & "@example.test", toList: "me@example.test",
                    date: epochTime() - float(i) * 60, size: 4000, snippet: sentence(20),
                    unread: i mod 4 == 0, focused: true)
        m.thread = m.remoteId
        discard s.upsertMessage(m)
        inc i
  let dt = getMonoTime() - t0
  echo "  headers stored:     ", formatFloat(float(n) / (dt.inMicroseconds.float / 1e6), ffDecimal, 0),
       " a second (", ms(dt), ")"
  s.close()
  t0 = getMonoTime()
  s = openStore(path)
  discard s.accounts()
  echo "  opened again:       ", ms(getMonoTime() - t0)
  t0 = getMonoTime()
  let shown = s.folderMessages(inbox)
  echo "  a folder (", shown.len, "):     ", ms(getMonoTime() - t0)
  t0 = getMonoTime()
  let shown2 = s.folderMessages(inbox)
  echo "  ... again (cached): ", ms(getMonoTime() - t0), " (", shown2.len, ")"
  t0 = getMonoTime()
  var hits = 0
  for r in s.rows("SELECT rowid FROM mfts WHERE mfts MATCH ? LIMIT 1000", ftsQuery("invoice budget")): inc hits
  echo "  a search (words):   ", ms(getMonoTime() - t0), " (", hits, " found)"
  t0 = getMonoTime()
  let ops = s.whereMessages("from_email LIKE ? AND unread = 1", @[toDbValue("%p8@%")])
  echo "  a search (from: is:unread): ", ms(getMonoTime() - t0), " (", ops.len, " found)"
  # a message's body, from its source
  var raw = buildMail(OutMail(fromAddr: MailAddress(email: "a@example.test"),
                              to: @[MailAddress(email: "me@example.test")], subject: "Big one",
                              text: sentence(2000), html: "<p>" & sentence(4000) & "</p>",
                              attachments: @[MailAttachment(filename: "a.pdf", data: urandom(2_000_000).join(""))]))
  let id = s.messageByRemote(acc, "r1").id
  t0 = getMonoTime()
  storeImapBody(s, id, raw, proc (t: string): string = "<pre>" & t & "</pre>")
  echo "  a 2.8 MB message's body and attachment stored: ", ms(getMonoTime() - t0)
  echo "  memory:             ", rss()
  echo "  file:               ", getFileSize(path) div 1_000_000, " MB"
  s.close()
removeDir(dir)
